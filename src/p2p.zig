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

/// 未送信のブロックを格納する待機キュー
/// ピアが接続されていない場合に一時的にブロックを保存します
pub var pending_blocks = std.ArrayList(types.Block).init(std.heap.page_allocator);
pub var pending_evm_txs = std.ArrayList([]const u8).init(std.heap.page_allocator);

var peer_list_mutex = std.Thread.Mutex{};
var pending_mutex = std.Thread.Mutex{};
// 改行までのTCP frameとfull-chain応答を直列化する専用mutex。
// blockchain/peer/pendingの状態mutexを保持したまま取得してはいけない。
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

fn queuePendingBlock(block: types.Block) !void {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    try pending_blocks.append(block);
}

fn queuePendingEvmTx(payload: []const u8) !void {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    try pending_evm_txs.append(payload);
}

fn takePendingBlocks() ![]types.Block {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    const snapshot = try std.heap.page_allocator.dupe(types.Block, pending_blocks.items);
    pending_blocks.clearRetainingCapacity();
    return snapshot;
}

fn takePendingEvmTxs() ![][]const u8 {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    const snapshot = try std.heap.page_allocator.dupe([]const u8, pending_evm_txs.items);
    pending_evm_txs.clearRetainingCapacity();
    return snapshot;
}

fn flushPending(peer: types.Peer) !void {
    // queue mutexを解放してからTCP frame lockを取る。
    const blocks = try takePendingBlocks();
    defer std.heap.page_allocator.free(blocks);
    if (blocks.len > 0) {
        std.log.info("Flushing {d} pending blocks to new peer {any}", .{ blocks.len, peer.address });
    }
    for (blocks) |block| {
        sendBlock(peer, block) catch |err| {
            std.log.err("Failed to flush queued block index={d}: {any}", .{ block.index, err });
        };
    }

    const evm_payloads = try takePendingEvmTxs();
    defer std.heap.page_allocator.free(evm_payloads);
    if (evm_payloads.len > 0) {
        std.log.info("Flushing {d} pending EVM transactions to new peer {any}", .{ evm_payloads.len, peer.address });
    }
    for (evm_payloads) |payload| {
        sendEvmTx(peer.stream.writer(), peer.address, payload) catch |err| {
            std.log.err("Failed to flush queued EVM transaction: {any}", .{err});
        };
        std.heap.page_allocator.free(payload);
    }
}

/// 1つの改行区切りP2Pフレームとして受信できる最大サイズ。
/// Solidityのcreation bytecodeとruntime bytecodeを含むデプロイブロックは
/// 4 KiBを超えるため、学習用コントラクトを余裕を持って同期できる64 KiBとする。
pub const MAX_FRAME_BYTES: usize = 64 * 1024;

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
        try flushPending(peer);

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
        try flushPending(peer);

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
/// ピアが存在しない場合、ブロックは将来の送信のために待機キューに追加されます。
///
/// 引数:
///     blk: ブロードキャストするブロック
///     from_peer: ブロードキャストから除外するオプションのソースピア
pub fn broadcastBlock(blk: types.Block, from_peer: ?types.Peer) void {
    const payload = parser.serializeBlock(blk) catch return;
    defer std.heap.page_allocator.free(payload);
    var sent = false;
    var available_peers: usize = 0;

    const peers = copyPeerSnapshot() catch |err| {
        std.log.err("Failed to snapshot peers for block broadcast: {any}", .{err});
        if (from_peer == null) queuePendingBlock(blk) catch {};
        return;
    };
    defer std.heap.page_allocator.free(peers);

    for (peers) |peer| {
        // 指定された場合、送信元のピアをスキップ
        if (from_peer) |sender| {
            if (peer.address.getPort() == sender.address.getPort()) continue;
        }

        available_peers += 1;
        writeBlockFrame(peer, payload) catch |err| {
            std.log.err("Error broadcasting to peer {any}: {any}", .{ peer.address, err });
            continue;
        };
        sent = true;
    }

    // ローカル生成ブロックだけを再送キューへ入れる。
    // 受信ブロックを送信元以外へ中継できない場合は、同期との二重配信を避ける。
    if (from_peer == null and (available_peers == 0 or !sent)) {
        queuePendingBlock(blk) catch |err| {
            std.log.err("Error adding block to pending queue: {any}", .{err});
            return;
        };
        std.log.warn("No peers yet - queueing block index={d}", .{blk.index});
    }
}

/// 単一のブロックを特定のピアに送信する
///
/// 引数:
///     peer: ブロックを送信するピア
///     blk: 送信するブロック
///
/// エラー:
///     シリアル化またはネットワークエラー
pub fn sendBlock(peer: types.Peer, blk: types.Block) !void {
    const payload = try parser.serializeBlock(blk);
    defer std.heap.page_allocator.free(payload);
    try writeBlockFrame(peer, payload);
    std.log.info("Sent block index={d} to {any}", .{ blk.index, peer.address });
}

fn writeBlockFrame(peer: types.Peer, payload: []const u8) !void {
    frame_write_mutex.lock();
    defer frame_write_mutex.unlock();
    var writer = peer.stream.writer();
    try writer.writeAll("BLOCK:");
    try writer.writeAll(payload);
    try writer.writeAll("\n");
}

/// 指定されたピアにEVMトランザクションを送信する
///
/// 引数:
///     peer: EVMトランザクションを送信するピア
///     payload: 送信するEVMトランザクションのペイロード
///
/// エラー:
///     ストリーム書き込みエラー
fn sendEvmTx(writer: anytype, address: std.net.Address, payload: []const u8) !void {
    frame_write_mutex.lock();
    defer frame_write_mutex.unlock();
    writer.writeAll("EVM_TX:") catch |err| {
        std.log.err("Error sending EVM_TX to peer {any}: {any}", .{ address, err });
        return err;
    };
    writer.writeAll(payload) catch |err| {
        std.log.err("Error sending EVM_TX payload to peer {any}: {any}", .{ address, err });
        return err;
    };
    writer.writeAll("\n") catch |err| {
        std.log.err("Error sending newline after EVM_TX to peer {any}: {any}", .{ address, err });
        return err;
    };
}

/// EVMトランザクションを他のノードに送信
///
/// 引数:
///     tx: 送信するEVMトランザクション
///
/// エラー:
///     送信に失敗した場合のエラー
pub fn broadcastEvmTransaction(tx: types.Transaction) !void {
    const allocator = std.heap.page_allocator;
    std.log.info(">> broadcastEvmTransaction[行:{d}]: tx_type={d}, evm_data.len={d}", .{ @src().line, tx.tx_type, if (tx.evm_data) |data| data.len else 0 });

    std.log.info("シリアライズ開始: serializeTransaction (行:{d})", .{@src().line + 1});
    const payload = try parser.serializeTransaction(allocator, tx);
    defer allocator.free(payload);
    std.log.info("シリアライズ完了: JSON長さ={d}バイト", .{payload.len});
    std.log.debug("生成されたJSONペイロード: {s}", .{payload});

    var sent = false;
    const peers = try copyPeerSnapshot();
    defer allocator.free(peers);
    const peer_count = peers.len;
    std.log.info("接続済みピア数: {d}", .{peer_count});

    for (peers, 0..) |peer, idx| {
        std.log.info("ピア {d}/{d} にEVMトランザクションを送信 [行:{d}]: {}", .{ idx + 1, peer_count, @src().line, peer.address });
        sendEvmTx(peer.stream.writer(), peer.address, payload) catch |err| {
            std.log.err("Error broadcasting EVM_TX to peer {any}: {any} (at 行:{d})", .{ peer.address, err, @src().line });
            continue; // エラーが発生しても次のピアへ
        };
        std.log.info("ピア {d}/{d} への送信成功", .{ idx + 1, peer_count });
        sent = true;
    }

    if (!sent) {
        const queued_payload = try allocator.dupe(u8, payload);
        errdefer allocator.free(queued_payload);
        try queuePendingEvmTx(queued_payload);
        std.log.warn("No peers available or sending failed for all peers. EVM_TX queued.", .{});
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
    // blockchain mutex内ではコピーだけ行い、送信lockとは重ねない。
    const chain = try blockchain.copyChainSnapshot(std.heap.page_allocator);
    defer std.heap.page_allocator.free(chain);
    const contract_snapshot = try blockchain.copyContractSnapshot(std.heap.page_allocator);
    defer std.heap.page_allocator.free(contract_snapshot);
    std.log.info("Sending full chain (height={d}) to {any}", .{ chain.len, peer.address });

    // チェーン送信前に現在のコントラクト状態をログに出力
    for (contract_snapshot) |entry| {
        std.log.info("Contract in storage before chain sync: address={s}, code_length={d}", .{ entry.address, entry.code.len });
    }
    std.log.info("Current contract storage has {d} contracts", .{contract_snapshot.len});

    // チェーン内の各ブロックのコントラクト情報をチェック
    for (chain) |block| {
        if (block.contracts) |contracts| {
            std.log.info("Block {d} contains {d} contracts to be sent", .{ block.index, contracts.count() });
        }
    }

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

        // コントラクト情報をログ出力
        if (blk.contracts) |contracts| {
            std.log.info("Received block contains {d} contracts", .{contracts.count()});
            var contract_it = contracts.iterator();
            while (contract_it.next()) |entry| {
                std.log.info("Block contains contract at address: {s}, code length: {d} bytes", .{ entry.key_ptr.*, entry.value_ptr.*.len });
            }
        }

        // 検証を通り、実際に追加できたブロックだけを中継する。
        const add_result = blockchain.addBlock(blk);
        if (add_result == .added) {
            broadcastBlock(blk, from_peer);
        } else {
            std.log.warn("Received block was not relayed: result={s}, index={d}", .{ @tagName(add_result), blk.index });
            parser.deinitParsedBlock(&blk);
        }
    } else if (std.mem.startsWith(u8, msg, "GET_CHAIN")) {
        // GET_CHAINメッセージを処理
        std.log.info("Received GET_CHAIN from {any}", .{from_peer.address});
        try sendFullChain(from_peer);
    } else if (std.mem.startsWith(u8, msg, "CHAIN_SYNC_COMPLETE")) {
        // チェーン同期の完了メッセージを処理
        std.log.info("Chain synchronization completed with peer {any}", .{from_peer.address});

        // コントラクトストレージの状態をログに出力（デバッグ用）
        const contract_snapshot = try blockchain.copyContractSnapshot(std.heap.page_allocator);
        defer std.heap.page_allocator.free(contract_snapshot);
        for (contract_snapshot) |entry| {
            std.log.info("Contract in storage after sync: address={s}, code_length={d}", .{ entry.address, entry.code.len });
        }
        std.log.info("Current contract storage has {d} contracts", .{contract_snapshot.len});

        // チェーン内の全ブロックを検査してコントラクトを探す（デバッグ用）
        const chain_snapshot = try blockchain.copyChainSnapshot(std.heap.page_allocator);
        defer std.heap.page_allocator.free(chain_snapshot);
        for (chain_snapshot) |block| {
            if (block.contracts) |contracts| {
                std.log.info("Block {d} contains {d} contracts", .{ block.index, contracts.count() });
                var block_contract_it = contracts.iterator();
                while (block_contract_it.next()) |entry| {
                    std.log.info("Block {d} has contract: address={s}, code_length={d}", .{ block.index, entry.key_ptr.*, entry.value_ptr.*.len });
                }
            }
        }

        // コントラクト呼び出しがペンディングの場合、実行する
        if (main.getPendingCall()) |pending_call| {
            // ここから先は1回取得したimmutable snapshotだけを使う。
            std.log.info("Executing pending contract call to {s}", .{pending_call.contract_address});

            // チェーン内の全ブロックを検査して特定のコントラクトを探す
            std.log.info("Searching for contract at address {s} in all blocks...", .{pending_call.contract_address});
            var found_in_block = false;
            for (chain_snapshot) |block| {
                if (block.contracts) |contracts| {
                    if (contracts.get(pending_call.contract_address)) |code| {
                        std.log.info("Contract found in block {d}, but might not be in storage. Code length: {d}", .{ block.index, code.len });
                        found_in_block = true;

                        // コントラクトコードが見つかったら、明示的にストレージに追加
                        blockchain.putContractCode(pending_call.contract_address, code) catch |err| {
                            std.log.err("Failed to add contract to storage: {any}", .{err});
                        };
                    }
                }
            }

            if (!found_in_block) {
                std.log.warn("Contract not found in any blocks. Chain may not include the deployment block.", .{});
            }

            // すでに同期されたチェーン上でコントラクトが存在するか確認
            if (blockchain.getContractCode(pending_call.contract_address)) |contract_code| {
                std.log.info("Contract found at address {s}, executing call... (contract code length: {d} bytes)", .{ pending_call.contract_address, contract_code.len });

                // トランザクションを作成
                var tx = types.Transaction{
                    .sender = pending_call.sender_address,
                    .receiver = pending_call.contract_address,
                    .amount = 0,
                    .tx_type = 2, // コントラクト呼び出し
                    .evm_data = pending_call.evm_input,
                    .gas_limit = pending_call.gas_limit,
                    .gas_price = 10, // デフォルトのガス価格を設定
                };

                // EVMトランザクションを直接処理
                const result = blockchain.processEvmTransaction(&tx) catch |err| {
                    std.log.err("Error executing contract call after chain sync: {any}", .{err});
                    main.clearPendingCall(pending_call);
                    return;
                };
                defer std.heap.page_allocator.free(result);

                // 処理結果をログに出力
                blockchain.logEvmResult(&tx, result) catch |err| {
                    std.log.err("Error logging EVM result: {any}", .{err});
                };

                main.clearPendingCall(pending_call);
                std.log.info("Contract call executed successfully after chain synchronization", .{});
            } else {
                // 見つからない場合は従来どおり保持し、次の同期完了で再試行する。
                std.log.warn("Contract not found at address {s} after chain sync", .{pending_call.contract_address});
            }
        }
    } else if (std.mem.startsWith(u8, msg, "EVM_TX:")) {
        std.log.info("<< handleMessage[行:{d}]: got EVM_TX message", .{@src().line});
        const payload = msg["EVM_TX:".len..];
        std.log.debug("<< raw payload[{d}バイト]: {s}", .{ payload.len, payload });

        // EVMトランザクションメッセージを処理
        std.log.info("解析開始: parseTransactionJson (行:{d})", .{@src().line + 1});
        var evm_tx = parser.parseTransactionJson(payload) catch |err| {
            std.log.err("Error parsing EVM transaction from {any}: {any} (at 行:{d})", .{ from_peer.address, err, @src().line });
            return;
        };
        defer parser.deinitParsedTransaction(&evm_tx);
        std.log.info("解析完了: トランザクションタイプ={d}, 送信者={s}, 受信者={s}", .{ evm_tx.tx_type, evm_tx.sender, evm_tx.receiver });

        // EVMトランザクションを処理
        std.log.info("処理開始: processEvmTransaction (行:{d})", .{@src().line + 1});
        const result = blockchain.processEvmTransaction(&evm_tx) catch |err| {
            std.log.err("Error processing EVM transaction from {any}: {any} (at 行:{d})", .{ from_peer.address, err, @src().line });
            return;
        };
        // デプロイ結果は新しいブロックのcontract codeとしてチェーンへ移譲される。
        // call結果だけはこのハンドラが所有する。
        defer if (evm_tx.tx_type != 1) std.heap.page_allocator.free(result);
        std.log.info("処理完了: EVMトランザクション処理結果", .{});

        // 処理結果をログに出力
        std.log.info("ログ出力開始: logEvmResult (行:{d})", .{@src().line + 1});
        blockchain.logEvmResult(&evm_tx, result) catch |err| {
            std.log.err("Error logging EVM result: {any} (at 行:{d})", .{ err, @src().line });
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
            // 空チェーンには決定的ジェネシスを先に追加・伝播する。
            if (blockchain.getChainHeight() == 0) {
                const genesis = try blockchain.createTestGenesisBlock(std.heap.page_allocator);
                if (blockchain.addBlock(genesis) == .added) {
                    broadcastBlock(genesis, null);
                } else {
                    return error.GenesisRejected;
                }
            }

            const last_block = blockchain.getChainTip() orelse return error.MissingGenesis;

            // 新しいブロックを作成してマイニング
            var new_block = try createMinedInputBlock(line, last_block);
            // 実際にローカルチェーンへ追加できた場合だけブロードキャストする。
            if (blockchain.addBlock(new_block) == .added) {
                broadcastBlock(new_block, null);
            } else {
                new_block.transactions.deinit();
                std.heap.page_allocator.free(new_block.data);
                std.log.warn("Locally mined block was rejected before broadcast", .{});
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
///     IP解析またはホスト名解決からのその他のエラー
pub fn resolveHostPort(spec: []const u8) !std.net.Address {
    var it = std.mem.tokenizeScalar(u8, spec, ':');
    const host = it.next() orelse return error.Invalid;
    const port_s = it.next() orelse return error.Invalid;
    if (it.next() != null) return error.Invalid;
    const port = try std.fmt.parseInt(u16, port_s, 10);

    return std.net.Address.parseIp(host, port) catch |err| {
        if (err != error.InvalidIPAddressFormat) return err;

        const list = try std.net.getAddressList(std.heap.page_allocator, host, port);
        defer list.deinit();
        if (list.addrs.len == 0) return error.UnknownHostName;
        return list.addrs[0];
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
    var buf: [MAX_FRAME_BYTES]u8 = undefined; // 受信メッセージ用のバッファ
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

// Helper struct for a mock stream writer that writes to an ArrayList(u8)
const MockStreamWriter = struct {
    buffer: *std.ArrayList(u8),

    pub fn write(self: @This(), bytes: []const u8) !usize {
        try self.buffer.appendSlice(bytes);
        return bytes.len;
    }

    pub fn writeAll(self: @This(), bytes: []const u8) !void {
        try self.buffer.appendSlice(bytes);
    }
};

test "block broadcast queues exactly once when no peer is available" {
    peer_list.clearRetainingCapacity();
    pending_blocks.clearRetainingCapacity();
    defer pending_blocks.clearRetainingCapacity();

    var transactions = std.ArrayList(types.Transaction).init(std.testing.allocator);
    defer transactions.deinit();

    const block = types.Block{
        .index = 1,
        .timestamp = 1_672_531_200,
        .prev_hash = [_]u8{0} ** 32,
        .transactions = transactions,
        .nonce = 0,
        .data = "queued once",
        .hash = [_]u8{0} ** 32,
    };

    broadcastBlock(block, null);

    try std.testing.expectEqual(@as(usize, 1), pending_blocks.items.len);
    try std.testing.expectEqual(block.index, pending_blocks.items[0].index);
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

test "relayed block is not queued when only the source peer exists" {
    peer_list.clearRetainingCapacity();
    pending_blocks.clearRetainingCapacity();
    defer pending_blocks.clearRetainingCapacity();

    var transactions = std.ArrayList(types.Transaction).init(std.testing.allocator);
    defer transactions.deinit();

    const block = types.Block{
        .index = 1,
        .timestamp = 1_672_531_200,
        .prev_hash = [_]u8{0} ** 32,
        .transactions = transactions,
        .nonce = 0,
        .data = "relayed",
        .hash = [_]u8{0} ** 32,
    };
    const source = types.Peer{
        .address = try std.net.Address.parseIp4("127.0.0.1", 9000),
        .stream = undefined,
    };

    broadcastBlock(block, source);

    try std.testing.expectEqual(@as(usize, 0), pending_blocks.items.len);
}

test "invalid received block is neither added nor relayed" {
    peer_list.clearRetainingCapacity();
    pending_blocks.clearRetainingCapacity();
    blockchain.chain_store.clearRetainingCapacity();
    defer pending_blocks.clearRetainingCapacity();
    defer blockchain.chain_store.clearRetainingCapacity();

    const genesis = try blockchain.createTestGenesisBlock(std.heap.page_allocator);
    defer genesis.transactions.deinit();
    try std.testing.expectEqual(blockchain.AddBlockResult.added, blockchain.addBlock(genesis));

    var tampered = blockchain.createBlock("before tamper", genesis);
    defer tampered.transactions.deinit();
    blockchain.mineBlock(&tampered, 2);
    tampered.data = "after tamper";

    const payload = try parser.serializeBlock(tampered);
    defer std.heap.page_allocator.free(payload);
    const message = try std.fmt.allocPrint(std.testing.allocator, "BLOCK:{s}", .{payload});
    defer std.testing.allocator.free(message);

    const source = types.Peer{
        .address = try std.net.Address.parseIp4("127.0.0.1", 9000),
        .stream = undefined,
    };
    try handleMessage(message, source);

    try std.testing.expectEqual(@as(usize, 1), blockchain.chain_store.items.len);
    try std.testing.expectEqual(@as(usize, 0), pending_blocks.items.len);
}

test "EVM transaction queuing and flushing" {
    const allocator = std.testing.allocator;

    // Ensure clean state before test by clearing and freeing any existing items
    peer_list.clearRetainingCapacity(); // Does not free items
    while (pending_evm_txs.pop()) |item| {
        std.heap.page_allocator.free(item);
    }
    try std.testing.expectEqual(@as(usize, 0), pending_evm_txs.items.len);

    // Create a sample transaction
    const sample_evm_data_bytes = try allocator.dupe(u8, "test_evm_data"); // Raw bytes
    // defer allocator.free(sample_evm_data_bytes); // Will be owned by tx1

    const tx1 = types.Transaction{
        .sender = try allocator.dupe(u8, "sender1_addr"),
        .receiver = try allocator.dupe(u8, "receiver1_addr"),
        .amount = 100,
        .tx_type = 1, // EVM Call
        .evm_data = sample_evm_data_bytes,
        .gas_limit = 21000,
        .gas_price = 10,
    };
    defer allocator.free(tx1.sender);
    defer allocator.free(tx1.receiver);
    defer if (tx1.evm_data) |d| allocator.free(d); // Free original evm_data after all uses

    // 1. Call broadcastEvmTransaction with no peers
    try broadcastEvmTransaction(tx1);

    // 2. Assert that peer_list is still empty
    try std.testing.expectEqual(@as(usize, 0), peer_list.items.len);

    // 3. Assert that pending_evm_txs now contains one item
    try std.testing.expectEqual(@as(usize, 1), pending_evm_txs.items.len);

    // 4. Verify the content of the item in pending_evm_txs
    const expected_payload_tx1 = try parser.serializeTransaction(allocator, tx1);
    defer allocator.free(expected_payload_tx1);
    try std.testing.expect(std.mem.eql(u8, expected_payload_tx1, pending_evm_txs.items[0]));

    // 5. Simulate a peer connecting
    var mock_stream_data_buffer = std.ArrayList(u8).init(allocator);
    defer mock_stream_data_buffer.deinit();

    // sendEvmTx accepts a writer directly so the test does not need a socket.
    const mock_writer_instance = MockStreamWriter{ .buffer = &mock_stream_data_buffer };
    const dummy_address = try std.net.Address.parseIp("127.0.0.1", 8080);

    std.log.info("Test: Flushing {d} pending EVM transactions to mock writer", .{pending_evm_txs.items.len});
    for (pending_evm_txs.items) |payload_to_flush| {
        try sendEvmTx(mock_writer_instance, dummy_address, payload_to_flush);
    }

    // 実装と同様、送信後にqueueが所有する複製payloadを解放する。
    while (pending_evm_txs.pop()) |item| {
        std.heap.page_allocator.free(item);
    }
    pending_evm_txs.clearRetainingCapacity();

    // Assertions after flushing:
    // 1. Assert that pending_evm_txs is now empty
    try std.testing.expectEqual(@as(usize, 0), pending_evm_txs.items.len);

    // 2. Assert that the mock stream associated with mock_peer received the data for tx1
    var expected_sent_data_to_peer = std.ArrayList(u8).init(allocator);
    defer expected_sent_data_to_peer.deinit();
    try expected_sent_data_to_peer.writer().print("EVM_TX:{s}\n", .{expected_payload_tx1});

    try std.testing.expect(std.mem.eql(u8, expected_sent_data_to_peer.items, mock_stream_data_buffer.items));
}

test "Solidity deployment block fits in one P2P frame" {
    const allocator = std.testing.allocator;

    // SimpleAdder.sol相当のcreation/runtime bytecodeを同じブロックへ保持すると、
    // JSONではそれぞれHEX化され、従来の4 KiB受信バッファを超える。
    const creation_code = [_]u8{0xab} ** 1300;
    const runtime_code = [_]u8{0xcd} ** 1300;

    var transactions = std.ArrayList(types.Transaction).init(allocator);
    defer transactions.deinit();
    try transactions.append(.{
        .sender = "0x000000000000000000000000000000000000dead",
        .receiver = "0x000000000000000000000000000000000000abcd",
        .amount = 0,
        .tx_type = 1,
        .evm_data = &creation_code,
        .gas_limit = 3_000_000,
        .gas_price = 10,
    });

    var contracts = std.StringHashMap([]const u8).init(allocator);
    defer contracts.deinit();
    try contracts.put("0x000000000000000000000000000000000000abcd", &runtime_code);

    const block = types.Block{
        .index = 1,
        .timestamp = 1_672_531_200,
        .prev_hash = [_]u8{0} ** 32,
        .transactions = transactions,
        .nonce = 0,
        .data = "Contract Deployment",
        .hash = [_]u8{0} ** 32,
        .contracts = contracts,
    };

    const payload = try parser.serializeBlock(block);
    defer std.heap.page_allocator.free(payload);

    const framed_len = "BLOCK:".len + payload.len + 1; // 末尾の改行を含む
    try std.testing.expect(framed_len > 4096);
    try std.testing.expect(framed_len <= MAX_FRAME_BYTES);
}

test "EVM transaction JSON format consistency (serialize/parse)" {
    const allocator = std.testing.allocator;

    // 1. Create tx2
    // Original evm_data should be raw bytes, not hex pre-encoded, as serializeTransaction will handle hex encoding.
    const original_evm_data_bytes = try allocator.dupe(u8, "raw_evm_data_payload");
    // defer allocator.free(original_evm_data_bytes); // Owned by tx2

    const tx2 = types.Transaction{
        .sender = try allocator.dupe(u8, "sender_addr_tx2"),
        .receiver = try allocator.dupe(u8, "receiver_addr_tx2"),
        .amount = 12345,
        .tx_type = 2, // EVM Deploy
        .evm_data = original_evm_data_bytes, // tx2 owns this now
        .gas_limit = 1000000,
        .gas_price = 20,
    };
    // Defer freeing fields of tx2
    defer allocator.free(tx2.sender);
    defer allocator.free(tx2.receiver);
    defer if (tx2.evm_data) |d| allocator.free(d);

    // 2. Serialize tx2
    const payload = try parser.serializeTransaction(allocator, tx2);
    defer allocator.free(payload);

    // 3. Parse the payload
    var parsed_tx = try parser.parseTransactionJson(payload);
    defer parser.deinitParsedTransaction(&parsed_tx);

    // 4. Assertions
    // Using expectEqualStrings for direct comparison. Assumes null termination or exact length match.
    try std.testing.expectEqualStrings(tx2.sender, parsed_tx.sender);
    try std.testing.expectEqualStrings(tx2.receiver, parsed_tx.receiver);
    try std.testing.expectEqual(tx2.amount, parsed_tx.amount);
    try std.testing.expectEqual(tx2.tx_type, parsed_tx.tx_type);
    try std.testing.expectEqual(tx2.gas_limit, parsed_tx.gas_limit);
    try std.testing.expectEqual(tx2.gas_price, parsed_tx.gas_price);

    // Compare evm_data: original raw bytes should match parsed (and decoded) raw bytes
    if (tx2.evm_data) |original_data| {
        try std.testing.expect(parsed_tx.evm_data != null);
        if (parsed_tx.evm_data) |parsed_data| {
            // parser.serializeTransaction hex-encodes evm_data.
            // parser.parseTransactionJson hex-decodes evm_data.
            // So, the original raw bytes in tx2.evm_data should match the raw bytes in parsed_tx.evm_data.
            try std.testing.expect(std.mem.eql(u8, original_data, parsed_data));
        }
    } else {
        try std.testing.expect(parsed_tx.evm_data == null);
    }
}
