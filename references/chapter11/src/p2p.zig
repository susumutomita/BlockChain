//! ピアツーピアネットワーキングモジュール
//!
//! このモジュールはブロックチェーンアプリケーションのピアツーピアネットワーク層を実装します。
//! 他のノードとの接続確立、着信接続の待ち受け、ノード間の通信プロトコルの
//! 処理機能を提供します。このモジュールはネットワーク全体にブロックチェーンデータを
//! ブロードキャストし、同期することを可能にします。

const std = @import("std");
const blockchain = @import("blockchain.zig");
const types = @import("types.zig");
const parser = @import("parser.zig");

/// 接続済みピアのグローバルリスト
/// ネットワーク内の他のノードへのアクティブな接続を維持します
pub var peer_list = std.ArrayList(types.Peer).init(std.heap.page_allocator);
var peer_list_mutex = std.Thread.Mutex{};
// TCPの1フレーム（改行まで）を分割書き込みしても、別threadのframeと混ざらない。
// chain/peerのmutexとは分離し、状態snapshotを取得してからこのmutexを取る。
var frame_write_mutex = std.Thread.Mutex{};

fn addPeer(peer: types.Peer) !void {
    peer_list_mutex.lock();
    defer peer_list_mutex.unlock();
    try peer_list.append(peer);
}

fn copyPeerSnapshot() ![]types.Peer {
    peer_list_mutex.lock();
    defer peer_list_mutex.unlock();
    return std.heap.page_allocator.dupe(types.Peer, peer_list.items);
}

fn writeBlockFrame(peer: types.Peer, payload: []const u8) !void {
    frame_write_mutex.lock();
    defer frame_write_mutex.unlock();
    var writer = peer.stream.writer();
    try writer.writeAll("BLOCK:");
    try writer.writeAll(payload);
    try writer.writeAll("\n");
}

/// リッスンソケットを開始し、着信接続を受け入れる
///
/// 指定されたポートで着信接続を待機するTCPサーバーを作成します。
/// 新しい接続ごとに、専用の通信スレッドを生成します。
///
/// 引数:
///     port: リッスンするポート番号
///
/// 注意:
///     この関数は独自のスレッドで無期限に実行されます
pub fn listenLoop(port: u16) !void {
    var addr = try std.net.Address.resolveIp("0.0.0.0", port);
    var listener = try addr.listen(.{});
    defer listener.deinit();

    std.log.info("listen 0.0.0.0:{d}", .{port});

    while (true) {
        const conn = try listener.accept();
        const peer = types.Peer{ .address = conn.address, .stream = conn.stream };
        try addPeer(peer);
        std.log.info("Accepted connection from: {any}", .{conn.address});

        // ピアとの通信を処理するスレッドを生成
        _ = try std.Thread.spawn(.{}, peerCommunicationLoop, .{peer});
    }
}

/// 指定されたピアアドレスに接続する
///
/// 指定されたアドレスで別のノードとの接続を確立しようとします。
/// 接続に失敗した場合、遅延後に再試行します。接続が確立されると、
/// チェーン同期をリクエストします。
///
/// 引数:
///     addr: 接続するピアのネットワークアドレス
///
/// 注意:
///     この関数は独自のスレッドで無期限に実行され、再接続を処理します
pub fn connectToPeer(addr: std.net.Address) !void {
    while (true) {
        const sock = std.net.tcpConnectToAddress(addr) catch |err| {
            std.log.warn("Connection failed to {any}: {any}", .{ addr, err });
            std.time.sleep(5 * std.time.ns_per_s); // 5秒待機してから再試行
            continue;
        };

        std.log.info("Connected to peer: {any}", .{addr});
        const peer = types.Peer{ .address = addr, .stream = sock };
        try addPeer(peer);

        // 新しく接続されたピアからチェーン同期をリクエスト
        try requestChain(peer);

        // ピアとの通信ループを開始
        peerCommunicationLoop(peer) catch |e| {
            std.log.err("Peer communication error: {any}", .{e});
        };
    }
}

/// ピアからブロックチェーンデータをリクエストする
///
/// ピアのブロックチェーンデータをリクエストするためにGET_CHAINメッセージを送信します。
///
/// 引数:
///     peer: チェーンをリクエストするピア
///
/// エラー:
///     ストリーム書き込みエラー
fn requestChain(peer: types.Peer) !void {
    frame_write_mutex.lock();
    defer frame_write_mutex.unlock();
    try peer.stream.writer().writeAll("GET_CHAIN\n");
    std.log.info("Requested chain from {any}", .{peer.address});
}

/// ソース以外のすべてのピアにブロックをブロードキャストする
///
/// ブロックをシリアル化し、接続されているすべてのピアに送信します。
/// オプションで、送信元のピアを除外することができます。
///
/// 引数:
///     blk: ブロードキャストするブロック
///     from_peer: ブロードキャストから除外するオプションのソースピア
pub fn broadcastBlock(blk: types.Block, from_peer: ?types.Peer) void {
    const payload = parser.serializeBlock(blk) catch return;
    defer std.heap.page_allocator.free(payload);

    const peers = copyPeerSnapshot() catch |err| {
        std.log.err("Failed to snapshot peers for broadcast: {any}", .{err});
        return;
    };
    defer std.heap.page_allocator.free(peers);

    for (peers) |peer| {
        // 指定された場合、送信元のピアをスキップ
        if (from_peer) |sender| {
            if (peer.address.getPort() == sender.address.getPort()) continue;
        }

        writeBlockFrame(peer, payload) catch |err| {
            std.log.err("Error broadcasting to peer {any}: {any}", .{ peer.address, err });
            continue;
        };
    }
}

/// 完全なブロックチェーンをピアに送信する
///
/// ローカルチェーン内のすべてのブロックをシリアル化し、
/// 適切なメッセージフレーミングで1つずつ指定されたピアに送信します。
///
/// 引数:
///     peer: チェーンを送信するピア
///
/// エラー:
///     シリアル化またはネットワークエラー
pub fn sendFullChain(peer: types.Peer) !void {
    const chain = try blockchain.copyChainSnapshot(std.heap.page_allocator);
    defer std.heap.page_allocator.free(chain);
    std.log.info("Sending full chain (height={d}) to {any}", .{ chain.len, peer.address });

    frame_write_mutex.lock();
    defer frame_write_mutex.unlock();
    var writer = peer.stream.writer();

    for (chain) |block| {
        {
            const block_json = try parser.serializeBlock(block);
            defer std.heap.page_allocator.free(block_json);
            try writer.writeAll("BLOCK:");
            try writer.writeAll(block_json);
            try writer.writeAll("\n"); // メッセージフレーミングのための改行
        }
    }
}

/// ピアリストからピアを削除する
///
/// 切断された場合に、グローバルピアリストからピアを検索して削除します。
///
/// 引数:
///     target: 削除するピア
fn removePeerFromList(target: types.Peer) void {
    peer_list_mutex.lock();
    defer peer_list_mutex.unlock();

    var i: usize = 0;
    while (i < peer_list.items.len) : (i += 1) {
        if (peer_list.items[i].address.getPort() == target.address.getPort()) {
            _ = peer_list.orderedRemove(i);
            break;
        }
    }
}

/// 種類に基づいて受信メッセージを処理する
///
/// BLOCKやGET_CHAINメッセージなど、ピアからの異なるメッセージタイプを
/// 解析して処理します。
///
/// 引数:
///     msg: 改行区切りのない、メッセージの内容
///     from_peer: メッセージを送信したピア
///
/// エラー:
///     解析エラーまたは処理エラー
fn handleMessage(msg: []const u8, from_peer: types.Peer) !void {
    if (std.mem.startsWith(u8, msg, "BLOCK:")) {
        // BLOCKメッセージを処理
        var blk = parser.parseBlockJson(msg[6..]) catch |err| {
            std.log.err("Error parsing block from {any}: {any}", .{ from_peer.address, err });
            return;
        };

        // 新規かつ正しく連結したブロックだけを追加・再伝播する。
        // 重複や改ざんブロックを再送しないことでゴシップの循環を止める。
        if (blockchain.addBlock(blk) == .added) {
            broadcastBlock(blk, from_peer);
        } else {
            parser.deinitParsedBlock(&blk);
        }
    } else if (std.mem.startsWith(u8, msg, "GET_CHAIN")) {
        // GET_CHAINメッセージを処理
        std.log.info("Received GET_CHAIN from {any}", .{from_peer.address});
        try sendFullChain(from_peer);
    } else {
        // 不明なメッセージを処理
        std.log.info("Unknown message from {any}: {s}", .{ from_peer.address, msg });
    }
}

/// ユーザー入力からブロックを作成してブロードキャストするインタラクティブループ
///
/// コンソールからテキスト入力を読み取り、それからブロックを作成し、
/// マイニングして、ネットワークにブロードキャストします。
///
/// 注意:
///     この関数は独自のスレッドで無期限に実行されます
fn createMinedInputBlock(line: []const u8, last_block: types.Block) !types.Block {
    // readUntilDelimiterOrEofが返すsliceは次の入力で上書きされる。
    // 採掘済みchainが入力バッファの寿命に依存しないよう、block自身が保持する。
    const owned_line = try std.heap.page_allocator.dupe(u8, line);
    errdefer std.heap.page_allocator.free(owned_line);

    var new_block = blockchain.createBlock(owned_line, last_block);
    blockchain.mineBlock(&new_block, 2);
    return new_block;
}

pub fn textInputLoop() !void {
    var reader = std.io.getStdIn().reader();
    var buf: [256]u8 = undefined;

    while (true) {
        std.debug.print("msg> ", .{});
        const maybe_line = reader.readUntilDelimiterOrEof(buf[0..], '\n') catch null;

        if (maybe_line) |line| {
            // 第11章のaddBlockは決定的genesisも明示的に検証・保存する。
            if (blockchain.getChainHeight() == 0) {
                const genesis = try blockchain.createTestGenesisBlock(std.heap.page_allocator);
                if (blockchain.addBlock(genesis) == .added) {
                    broadcastBlock(genesis, null);
                }
            }
            const last_block = blockchain.getChainTip() orelse return error.MissingGenesis;

            // 新しいブロックを作成してマイニング
            var new_block = try createMinedInputBlock(line, last_block);
            if (blockchain.addBlock(new_block) == .added) {
                // 作成したブロックをブロードキャスト
                broadcastBlock(new_block, null);
            } else {
                new_block.transactions.deinit();
                std.heap.page_allocator.free(new_block.data);
            }
        } else break;
    }
}

/// ホスト:ポート文字列をネットワークアドレスに解決
///
/// "hostname:port"形式の文字列を受け取り、接続に使用できる
/// ネットワークアドレスに解決します。
///
/// 引数:
///     spec: "hostname:port"形式の文字列
///
/// 戻り値:
///     std.net.Address - 解決されたネットワークアドレス
///
/// エラー:
///     error.Invalid: 文字列フォーマットが無効な場合
///     std.net.Address.resolveIpからのその他のエラー
pub fn resolveHostPort(spec: []const u8) !std.net.Address {
    var it = std.mem.tokenizeScalar(u8, spec, ':');
    const host = it.next() orelse return error.Invalid;
    const port_s = it.next() orelse return error.Invalid;
    const port = try std.fmt.parseInt(u16, port_s, 10);

    // 特別なケース: localhostが指定された場合は直接127.0.0.1を使用
    if (std.mem.eql(u8, host, "localhost")) {
        return std.net.Address.parseIp("127.0.0.1", port) catch unreachable;
    }

    // まずIPアドレスとしてパースを試みる
    return std.net.Address.parseIp(host, port) catch |err| {
        if (err == error.InvalidIPAddressFormat) {
            // IPアドレスとして無効な場合は、ホスト名解決を試みる
            const list = try std.net.getAddressList(std.heap.page_allocator, host, port);
            defer list.deinit();

            // アドレスが見つからない場合はエラー
            if (list.addrs.len == 0) {
                return error.UnknownHostName;
            }

            // 最初のアドレスを返す
            return list.addrs[0];
        }
        return err;
    };
}

/// ピアとの通信を処理する
///
/// ピア接続から継続的に読み取り、メッセージを処理し、
/// 切断を処理します。
///
/// 引数:
///     peer: 通信するピア
///
/// 注意:
///     この関数は終了時に接続をクリーンアップします
fn peerCommunicationLoop(peer: types.Peer) !void {
    defer {
        removePeerFromList(peer);
        peer.stream.close();
    }

    var reader = peer.stream.reader();
    var buf: [4096]u8 = undefined; // 受信メッセージ用のバッファ
    var total_bytes: usize = 0;

    while (true) {
        const n = try reader.read(buf[total_bytes..]);
        if (n == 0) break; // 接続が閉じられた

        total_bytes += n;
        var search_start: usize = 0;

        // バッファ内の完全なメッセージを処理
        while (search_start < total_bytes) {
            // メッセージ区切り文字（改行）を探す
            var newline_pos: ?usize = null;
            var i: usize = search_start;
            while (i < total_bytes) : (i += 1) {
                if (buf[i] == '\n') {
                    newline_pos = i;
                    break;
                }
            }

            if (newline_pos) |pos| {
                // 完全なメッセージを処理
                const msg = buf[search_start..pos];
                try handleMessage(msg, peer);
                search_start = pos + 1;
            } else {
                // メッセージがまだ完全ではない
                break;
            }
        }

        // 処理済みメッセージをバッファから削除
        if (search_start > 0) {
            if (search_start < total_bytes) {
                std.mem.copyForwards(u8, &buf, buf[search_start..total_bytes]);
            }
            total_bytes -= search_start;
        }

        // バッファがいっぱいで完全なメッセージがない場合はエラー
        if (total_bytes == buf.len) {
            std.log.err("Message too long, buffer full from peer {any}", .{peer.address});
            break;
        }
    }

    std.log.info("Peer {any} disconnected.", .{peer.address});
}

test "locally mined block owns input after the source buffer is reused" {
    var source = [_]u8{ 'a', 'l', 'p', 'h', 'a' };
    var genesis = try blockchain.createTestGenesisBlock(std.testing.allocator);
    defer genesis.transactions.deinit();

    var block = try createMinedInputBlock(source[0..], genesis);
    defer block.transactions.deinit();
    defer std.heap.page_allocator.free(block.data);

    @memcpy(source[0..], "bravo");
    try std.testing.expectEqualStrings("alpha", block.data);
    try std.testing.expect(blockchain.verifyBlockPow(&block));
}
