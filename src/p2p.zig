//! ピアツーピアネットワーキングモジュール
//!
//! このモジュールはブロックチェーンアプリケーションのピアツーピアネットワーク層を実装します。
//! 他のノードとの接続確立、着信接続の待ち受け、ノード間の通信プロトコルの
//! 処理機能を提供します。このモジュールはネットワーク全体にブロックチェーンデータを
//! ブロードキャストし、同期することを可能にします。

const std = @import("std");
const types = @import("types.zig");
const parser = @import("parser.zig");
const blockchain = @import("blockchain.zig"); // トップレベルでblockchainをインポート
const utils = @import("utils.zig"); // すでに関数内で使用されているので追加
const main = @import("main.zig"); // Add this to access global variables

/// 接続済みピアのグローバルリスト
/// ネットワーク内の他のノードへのアクティブな接続を維持します
pub var peer_list = std.ArrayList(types.Peer).init(std.heap.page_allocator);

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
        try peer_list.append(peer);
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
        try peer_list.append(peer);

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

    for (peer_list.items) |peer| {
        // 指定された場合、送信元のピアをスキップ
        if (from_peer) |sender| {
            if (peer.address.getPort() == sender.address.getPort()) continue;
        }

        var writer = peer.stream.writer();
        _ = writer.writeAll("BLOCK:") catch |err| {
            std.log.err("Error broadcasting to peer {any}: {any}", .{ peer.address, err });
            continue;
        };
        _ = writer.writeAll(payload) catch |err| {
            std.log.err("Error broadcasting to peer {any}: {any}", .{ peer.address, err });
            continue;
        };
        _ = writer.writeAll("\n") catch |err| {
            std.log.err("Error broadcasting to peer {any}: {any}", .{ peer.address, err });
            continue;
        };
    }
}

/// EVMトランザクションを他のノードに送信
///
/// 引数:
///     allocator: メモリアロケータ
///     tx: 送信するEVMトランザクション
///
/// エラー:
///     送信に失敗した場合のエラー
pub fn broadcastEvmTransaction(allocator: std.mem.Allocator, tx: types.Transaction) !void {
    std.log.info(">> broadcastEvmTransaction: tx_type={d}, evm_data.len={d}", .{ tx.tx_type, if (tx.evm_data) |data| data.len else 0 });
    // トランザクションJSONを作成
    var json_buffer = std.ArrayList(u8).init(allocator);
    defer json_buffer.deinit();

    // 完全なJSON構造を作成する - 確実に有効なJSONになるよう括弧で囲む
    try json_buffer.appendSlice("{");
    try json_buffer.appendSlice("\"type\": \"evm_tx\", \"data\": { ");
    try json_buffer.appendSlice("\"sender\": \"");
    try json_buffer.appendSlice(tx.sender);
    try json_buffer.appendSlice("\", \"receiver\": \"");
    try json_buffer.appendSlice(tx.receiver);
    try json_buffer.appendSlice("\", \"amount\": ");

    var amount_buf: [20]u8 = undefined;
    const amount_str = try std.fmt.bufPrint(&amount_buf, "{d}", .{tx.amount});
    try json_buffer.appendSlice(amount_str);

    // EVMトランザクション固有のフィールドを追加
    try json_buffer.appendSlice(", \"tx_type\": ");
    var type_buf: [2]u8 = undefined;
    const type_str = try std.fmt.bufPrint(&type_buf, "{d}", .{tx.tx_type});
    try json_buffer.appendSlice(type_str);

    // EVMデータを16進数で追加
    try json_buffer.appendSlice(", \"evm_data\": \"0x");
    if (tx.evm_data) |evm_data| {
        const hex_data = try utils.bytesToHex(allocator, evm_data);
        defer allocator.free(hex_data);
        try json_buffer.appendSlice(hex_data);
    }
    try json_buffer.appendSlice("\"");

    // ガス関連の情報を追加
    try json_buffer.appendSlice(", \"gas_limit\": ");
    var gas_buf: [20]u8 = undefined;
    const gas_str = try std.fmt.bufPrint(&gas_buf, "{d}", .{tx.gas_limit});
    try json_buffer.appendSlice(gas_str);

    try json_buffer.appendSlice(", \"gas_price\": ");
    var price_buf: [20]u8 = undefined;
    const price_str = try std.fmt.bufPrint(&price_buf, "{d}", .{tx.gas_price});
    try json_buffer.appendSlice(price_str);

    try json_buffer.appendSlice(" } }");

    // すべてのピアにメッセージを送信
    for (peer_list.items) |peer| {
        std.log.info("ピアにEVMトランザクションを送信: {}", .{peer.address});
        var w = peer.stream.writer();
        try w.writeAll("EVM_TX:");
        try w.writeAll(json_buffer.items); // 完全なJSON文字列として送信
        try w.writeAll("\n"); // メッセージ境界に改行
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
    std.log.info("Sending full chain (height={d}) to {any}", .{ blockchain.chain_store.items.len, peer.address });

    var writer = peer.stream.writer();

    for (blockchain.chain_store.items) |block| {
        const block_json = try parser.serializeBlock(block);
        try writer.writeAll("BLOCK:");
        try writer.writeAll(block_json);
        try writer.writeAll("\n"); // メッセージフレーミングのための改行
    }

    // チェーン送信の最後に同期完了のメッセージを送る
    try writer.writeAll("CHAIN_SYNC_COMPLETE\n");
}

/// ピアリストからピアを削除する
///
/// 切断された場合に、グローバルピアリストからピアを検索して削除します。
///
/// 引数:
///     target: 削除するピア
fn removePeerFromList(target: types.Peer) void {
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
        const blk = parser.parseBlockJson(msg[6..]) catch |err| {
            std.log.err("Error parsing block from {any}: {any}", .{ from_peer.address, err });
            return;
        };

        // チェーンにブロックを追加
        blockchain.addBlock(blk);

        // 他のピアにブロックをブロードキャスト
        broadcastBlock(blk, from_peer);
    } else if (std.mem.startsWith(u8, msg, "GET_CHAIN")) {
        // GET_CHAINメッセージを処理
        std.log.info("Received GET_CHAIN from {any}", .{from_peer.address});
        try sendFullChain(from_peer);
    } else if (std.mem.startsWith(u8, msg, "CHAIN_SYNC_COMPLETE")) {
        // チェーン同期の完了メッセージを処理
        std.log.info("Chain synchronization completed with peer {any}", .{from_peer.address});

        // コントラクトストレージの状態をログに出力（デバッグ用）
        var contract_count: usize = 0;
        var it = blockchain.contract_storage.iterator();
        while (it.next()) |entry| {
            contract_count += 1;
            std.log.debug("Contract in storage: address={s}, code_length={d}", .{ entry.key_ptr.*, entry.value_ptr.*.len });
        }
        std.log.info("Current contract storage has {d} contracts", .{contract_count});

        // コントラクト呼び出しがペンディングの場合、実行する
        if (main.global_call_pending) {
            std.log.info("Executing pending contract call to {s}", .{main.global_contract_address});

            // すでに同期されたチェーン上でコントラクトが存在するか確認
            if (blockchain.contract_storage.get(main.global_contract_address)) |contract_code| {
                std.log.info("Contract found at address {s}, executing call... (contract code length: {d} bytes)", .{ main.global_contract_address, contract_code.len });

                // トランザクションを作成
                var tx = types.Transaction{
                    .sender = main.global_sender_address, // 動的な送信者アドレスを使用
                    .receiver = main.global_contract_address,
                    .amount = 0,
                    .tx_type = 2, // コントラクト呼び出し
                    .evm_data = main.global_evm_input,
                    .gas_limit = main.global_gas_limit,
                    .gas_price = 10, // デフォルトのガス価格を設定
                };

                // EVMトランザクションを直接処理
                const result = blockchain.processEvmTransaction(&tx) catch |err| {
                    std.log.err("Error executing contract call after chain sync: {any}", .{err});
                    main.global_call_pending = false; // エラーでもフラグを下ろす
                    return;
                };

                // 処理結果をログに出力
                blockchain.logEvmResult(&tx, result) catch |err| {
                    std.log.err("Error logging EVM result: {any}", .{err});
                };

                // フラグを下ろす
                main.global_call_pending = false;
                std.log.info("Contract call executed successfully after chain synchronization", .{});
            } else {
                std.log.warn("Contract not found at address {s} after chain sync", .{main.global_contract_address});
            }
        }
    } else if (std.mem.startsWith(u8, msg, "EVM_TX:")) {
        std.log.info("<< handleMessage: got EVM_TX message", .{});
        std.log.debug("<< raw payload: {s}", .{msg[8..]});
        // EVMトランザクションメッセージを処理
        var evm_tx = parser.parseTransactionJson(msg[8..]) catch |err| {
            std.log.err("Error parsing EVM transaction from {any}: {any}", .{ from_peer.address, err });
            return;
        };

        // EVMトランザクションを処理
        const result = blockchain.processEvmTransaction(&evm_tx) catch |err| {
            std.log.err("Error processing EVM transaction from {any}: {any}", .{ from_peer.address, err });
            return;
        };

        // 処理結果をログに出力
        blockchain.logEvmResult(&evm_tx, result) catch |err| {
            std.log.err("Error logging EVM result: {any}", .{err});
        };

        // 受信したトランザクションは再ブロードキャストしない
        // 無限ループを防止するため
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
pub fn textInputLoop() !void {
    var reader = std.io.getStdIn().reader();
    var buf: [256]u8 = undefined;

    while (true) {
        std.debug.print("msg> ", .{});
        const maybe_line = reader.readUntilDelimiterOrEof(buf[0..], '\n') catch null;

        if (maybe_line) |line| {
            // チェーンが空の場合は最新のブロックを取得するか、ジェネシスを作成
            const last_block = if (blockchain.chain_store.items.len == 0)
                try blockchain.createTestGenesisBlock(std.heap.page_allocator)
            else
                blockchain.chain_store.items[blockchain.chain_store.items.len - 1];

            // 新しいブロックを作成してマイニング
            var new_block = blockchain.createBlock(line, last_block);
            blockchain.mineBlock(&new_block, 2); // 難易度2でマイニング
            blockchain.addBlock(new_block);

            // 作成したブロックをブロードキャスト
            broadcastBlock(new_block, null);
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
    return std.net.Address.resolveIp(host, port);
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
