//! ピアツーピアネットワーキングモジュール
//!
//! このモジュールはブロックチェーンアプリケーションのピアツーピアネットワーク層を実装します。
//! 他のノードとの接続確立、着信接続の待ち受け、ノード間の通信プロトコルの
//! 処理機能を提供します。このモジュールはネットワーク全体にブロックチェーンデータを
//! ブロードキャストし、同期することを可能にします。
//!
//! P2Pネットワークの基本概念：
//! - ピア（Peer）: ネットワーク内の各ノード（参加者）
//! - ブロードキャスト: 全ピアへのメッセージ送信
//! - 同期: ノード間でブロックチェーンの状態を一致させる
//! - 非中央集権: 特権的なサーバーが存在しない

const std = @import("std");
const types = @import("types.zig");
const parser = @import("parser.zig");
const blockchain = @import("blockchain.zig"); // トップレベルでblockchainをインポート
const utils = @import("utils.zig"); // すでに関数内で使用されているので追加
const main = @import("main.zig"); // Add this to access global variables
const logger = @import("logger.zig"); // デバッグログ用

/// 接続済みピアのグローバルリスト
/// ネットワーク内の他のノードへのアクティブな接続を維持します
/// 
/// なぜグローバル変数を使うのか：
/// - 複数のスレッドから同じピアリストにアクセスする必要がある
/// - 新規接続時に既存のピアを参照できる
/// - シンプルな実装で理解しやすい
pub var peer_list = std.ArrayList(types.Peer).init(std.heap.page_allocator);

/// 未送信のブロックを格納する待機キュー
/// ピアが接続されていない場合に一時的にブロックを保存します
/// 
/// なぜ待機キューが必要なのか：
/// - ノード起動直後はピアが接続されていない可能性がある
/// - 重要なブロックやトランザクションを失わないため
/// - ピア接続時に自動的に送信される
pub var pending_blocks = std.ArrayList(types.Block).init(std.heap.page_allocator);
pub var pending_evm_txs = std.ArrayList([]const u8).init(std.heap.page_allocator);

/// リッスンソケットを開始し、着信接続を受け入れる
///
/// 指定されたポートで着信接続を待機するTCPサーバーを作成します。
/// 新しい接続ごとに、専用の通信スレッドを生成します。
///
/// ネットワーク接続の流れ：
/// 1. TCPソケットを作成し、指定ポートでリッスン開始
/// 2. 新規接続を待機（ブロッキング）
/// 3. 接続が来たらピアリストに追加
/// 4. 待機中のデータがあれば新規ピアに送信
/// 5. 専用スレッドで通信処理を開始
///
/// 引数:
///     port: リッスンするポート番号
///
/// 注意:
///     この関数は独自のスレッドで無期限に実行されます
pub fn listenLoop(port: u16) !void {
    // ステップ1: ソケットアドレスを作成（0.0.0.0 = 全インターフェースで待機）
    var addr = try std.net.Address.resolveIp("0.0.0.0", port);
    
    // ステップ2: TCPリスナーを作成
    var listener = try addr.listen(.{});
    defer listener.deinit(); // 関数終了時に自動的にリソースを解放

    std.log.info("P2Pネットワークをポート {d} で待機中...", .{port});

    // ステップ3: 無限ループで接続を待機
    while (true) {
        // 新しい接続を受け入れる（ブロッキング）
        const conn = try listener.accept();
        const peer = types.Peer{ .address = conn.address, .stream = conn.stream };
        
        // ピアリストに追加
        try peer_list.append(peer);
        std.log.info("新規ピア接続: {any} (現在のピア数: {d})", .{ conn.address, peer_list.items.len });

        // 待機中のブロックを新しいピアに送信
        if (pending_blocks.items.len > 0) {
            std.log.info("Flushing {d} pending blocks to new peer {any}", .{ pending_blocks.items.len, conn.address });
            for (pending_blocks.items) |blk| {
                sendBlock(peer, blk) catch |err| {
                    std.log.err("Failed to flush queued block index={d}: {any}", .{ blk.index, err });
                };
            }
            pending_blocks.clearRetainingCapacity();
        }

        // 待機中のEVMトランザクションを新しいピアに送信
        if (pending_evm_txs.items.len > 0) {
            std.log.info("Flushing {d} pending EVM transactions to new peer {any}", .{ pending_evm_txs.items.len, conn.address });
            for (pending_evm_txs.items) |payload| {
                sendEvmTx(peer, payload) catch |err| {
                    std.log.err("Failed to flush queued EVM transaction: {any}", .{err});
                    // エラーが発生しても次のペイロードへ
                };
            }
            pending_evm_txs.clearRetainingCapacity();
        }

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
/// 接続プロセス：
/// 1. TCP接続を試行
/// 2. 失敗した場合は5秒待って再試行（ネットワークの一時的な問題に対処）
/// 3. 成功したらピアリストに追加
/// 4. 待機中のデータを送信
/// 5. チェーン同期をリクエスト
///
/// なぜ再接続を行うのか：
/// - ネットワークは不安定で一時的な障害が発生する
/// - ピアがまだ起動していない可能性がある
/// - 接続を維持することでネットワークの堅牢性を向上
///
/// 引数:
///     addr: 接続するピアのネットワークアドレス
///
/// 注意:
///     この関数は独自のスレッドで無期限に実行され、再接続を処理します
pub fn connectToPeer(addr: std.net.Address) !void {
    // 再接続の待機時間（秒）
    const RECONNECT_DELAY_SECONDS = 5;
    
    while (true) {
        // ステップ1: TCP接続を試行
        const sock = std.net.tcpConnectToAddress(addr) catch |err| {
            std.log.warn("ピア接続失敗 {any}: {any} - {d}秒後に再試行", .{ addr, err, RECONNECT_DELAY_SECONDS });
            std.time.sleep(RECONNECT_DELAY_SECONDS * std.time.ns_per_s);
            continue;
        };

        std.log.info("ピア接続成功: {any}", .{addr});
        const peer = types.Peer{ .address = addr, .stream = sock };
        
        // ステップ2: ピアリストに追加
        try peer_list.append(peer);

        // 待機中のブロックを新しいピアに送信
        if (pending_blocks.items.len > 0) {
            std.log.info("Flushing {d} pending blocks to new peer {any}", .{ pending_blocks.items.len, addr });
            for (pending_blocks.items) |blk| {
                sendBlock(peer, blk) catch |err| {
                    std.log.err("Failed to flush queued block index={d}: {any}", .{ blk.index, err });
                };
            }
            pending_blocks.clearRetainingCapacity();
        }

        // 待機中のEVMトランザクションを新しいピアに送信
        if (pending_evm_txs.items.len > 0) {
            std.log.info("Flushing {d} pending EVM transactions to new peer {any}", .{ pending_evm_txs.items.len, addr });
            for (pending_evm_txs.items) |payload| {
                sendEvmTx(peer, payload) catch |err| {
                    std.log.err("Failed to flush queued EVM transaction: {any}", .{err});
                    // エラーが発生しても次のペイロードへ
                };
            }
            pending_evm_txs.clearRetainingCapacity();
        }

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
/// ピアが存在しない場合、ブロックは将来の送信のために待機キューに追加されます。
///
/// ブロードキャストの仕組み：
/// 1. ブロックをJSON形式にシリアル化
/// 2. 接続されているすべてのピアに送信
/// 3. 送信元のピアは除外（無限ループ防止）
/// 4. 送信失敗時は待機キューに保存
///
/// なぜブロードキャストが重要なのか：
/// - ネットワーク全体でブロックチェーンの同期を保つ
/// - 新しいブロックを即座に全ノードに伝播
/// - 分散システムの一貫性を維持
///
/// 引数:
///     blk: ブロードキャストするブロック
///     from_peer: ブロードキャストから除外するオプションのソースピア
pub fn broadcastBlock(blk: types.Block, from_peer: ?types.Peer) void {
    // ステップ1: ブロックをJSON形式にシリアル化
    const payload = parser.serializeBlock(blk) catch {
        std.log.err("ブロックのシリアル化に失敗しました", .{});
        return;
    };
    
    var sent = false;
    var available_peers: usize = 0;

    // ステップ2: すべてのピアに送信を試行
    for (peer_list.items) |peer| {
        // 送信元のピアはスキップ（エコーバック防止）
        if (from_peer) |sender| {
            if (peer.address.getPort() == sender.address.getPort()) {
                logger.debugLog("送信元ピアをスキップ: {any}\n", .{peer.address});
                continue;
            }
        }

        available_peers += 1;
        var writer = peer.stream.writer();
        var send_success = true;

        // 各部分を個別に送信し、エラーがあればcatchする
        writer.writeAll("BLOCK:") catch |err| {
            std.log.err("Error broadcasting to peer {any}: {any}", .{ peer.address, err });
            send_success = false;
            continue;
        };

        if (send_success) {
            writer.writeAll(payload) catch |err| {
                std.log.err("Error broadcasting to peer {any}: {any}", .{ peer.address, err });
                send_success = false;
                continue;
            };
        }

        if (send_success) {
            writer.writeAll("\n") catch |err| {
                std.log.err("Error broadcasting to peer {any}: {any}", .{ peer.address, err });
                send_success = false;
                continue;
            };
        }

        if (send_success) sent = true;
    }

    // 送信先のピアがないか、すべての送信が失敗した場合、キューに追加
    if (available_peers == 0 or !sent) {
        pending_blocks.append(blk) catch |err| {
            std.log.err("Error adding block to pending queue: {any}", .{err});
            return;
        };
        std.log.warn("No peers yet - queueing block index={d}", .{blk.index});
    }

    // 送信先のピアがないか、すべての送信が失敗した場合、キューに追加
    if (available_peers == 0 or !sent) {
        pending_blocks.append(blk) catch |err| {
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
    var writer = peer.stream.writer();
    try writer.writeAll("BLOCK:");
    try writer.writeAll(payload);
    try writer.writeAll("\n");
    std.log.info("Sent block index={d} to {any}", .{ blk.index, peer.address });
}

/// 指定されたピアにEVMトランザクションを送信する
///
/// 引数:
///     peer: EVMトランザクションを送信するピア
///     payload: 送信するEVMトランザクションのペイロード
///
/// エラー:
///     ストリーム書き込みエラー
fn sendEvmTx(peer: types.Peer, payload: []const u8) !void {
    var writer = peer.stream.writer();
    writer.writeAll("EVM_TX:") catch |err| {
        std.log.err("Error sending EVM_TX to peer {any}: {any}", .{ peer.address, err });
        return err;
    };
    writer.writeAll(payload) catch |err| {
        std.log.err("Error sending EVM_TX payload to peer {any}: {any}", .{ peer.address, err });
        return err;
    };
    writer.writeAll("\n") catch |err| {
        std.log.err("Error sending newline after EVM_TX to peer {any}: {any}", .{ peer.address, err });
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
    const peer_count = peer_list.items.len;
    std.log.info("接続済みピア数: {d}", .{peer_count});

    for (peer_list.items, 0..) |peer, idx| {
        std.log.info("ピア {d}/{d} にEVMトランザクションを送信 [行:{d}]: {}", .{ idx + 1, peer_count, @src().line, peer.address });
        sendEvmTx(peer, payload) catch |err| {
            std.log.err("Error broadcasting EVM_TX to peer {any}: {any} (at 行:{d})", .{ peer.address, err, @src().line });
            continue; // エラーが発生しても次のピアへ
        };
        std.log.info("ピア {d}/{d} への送信成功", .{ idx + 1, peer_count });
        sent = true;
    }

    if (!sent) {
        try pending_evm_txs.append(try allocator.dupe(u8, payload));
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
    std.log.info("Sending full chain (height={d}) to {any}", .{ blockchain.chain_store.items.len, peer.address });

    // チェーン送信前に現在のコントラクト状態をログに出力
    var contract_count: usize = 0;
    var contract_it = blockchain.contract_storage.iterator();
    while (contract_it.next()) |entry| {
        contract_count += 1;
        std.log.info("Contract in storage before chain sync: address={s}, code_length={d}", .{ entry.key_ptr.*, entry.value_ptr.*.len });
    }
    std.log.info("Current contract storage has {d} contracts", .{contract_count});

    // チェーン内の各ブロックのコントラクト情報をチェック
    for (blockchain.chain_store.items) |block| {
        if (block.contracts) |contracts| {
            std.log.info("Block {d} contains {d} contracts to be sent", .{ block.index, contracts.count() });
        }
    }

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

/// BLOCKメッセージを処理する
///
/// 新しいブロックを受信し、検証してチェーンに追加し、
/// 他のピアにブロードキャストします。
fn handleBlockMessage(msg: []const u8, from_peer: types.Peer) !void {
    // JSONからブロックをパース
    const blk = parser.parseBlockJson(msg) catch |err| {
        std.log.err("ブロックのパースエラー from {any}: {any}", .{ from_peer.address, err });
        return;
    };

    // コントラクト情報をログ出力
    if (blk.contracts) |contracts| {
        std.log.info("受信ブロックに{d}個のコントラクトが含まれています", .{contracts.count()});
        var contract_it = contracts.iterator();
        while (contract_it.next()) |entry| {
            std.log.info("コントラクト: アドレス={s}, コード長={d}バイト", 
                .{ entry.key_ptr.*, entry.value_ptr.*.len });
        }
    }

    // チェーンにブロックを追加
    blockchain.addBlock(blk);

    // 他のピアにブロードキャスト（送信元を除く）
    broadcastBlock(blk, from_peer);
}

/// EVMトランザクションメッセージを処理する
///
/// EVMトランザクションを受信し、実行して結果をログに記録します。
fn handleEvmTxMessage(msg: []const u8, from_peer: types.Peer) !void {
    const payload = msg;
    std.log.debug("EVMトランザクション受信: {d}バイト", .{payload.len});

    // EVMトランザクションをパース
    var evm_tx = parser.parseTransactionJson(payload) catch |err| {
        std.log.err("EVMトランザクションのパースエラー from {any}: {any}", .{ from_peer.address, err });
        return;
    };
    
    std.log.info("トランザクション詳細: タイプ={d}, 送信者={s}, 受信者={s}", 
        .{ evm_tx.tx_type, evm_tx.sender, evm_tx.receiver });

    // EVMトランザクションを処理
    const result = blockchain.processEvmTransaction(&evm_tx) catch |err| {
        std.log.err("EVMトランザクション処理エラー from {any}: {any}", .{ from_peer.address, err });
        return;
    };

    // 処理結果をログに出力
    blockchain.logEvmResult(&evm_tx, result) catch |err| {
        std.log.err("EVMResult ログ出力エラー: {any}", .{err});
    };
}

/// 種類に基づいて受信メッセージを処理する
///
/// BLOCKやGET_CHAINメッセージなど、ピアからの異なるメッセージタイプを
/// 解析して処理します。
///
/// メッセージタイプ：
/// - "BLOCK:": 新しいブロックの受信
/// - "GET_CHAIN": ブロックチェーン全体のリクエスト
/// - "CHAIN_SYNC_COMPLETE": チェーン同期完了の通知
/// - "EVM_TX:": EVMトランザクションの受信
///
/// 処理フロー：
/// 1. メッセージのプレフィックスを確認
/// 2. 対応するハンドラーを呼び出し
/// 3. エラーがあればログに記録
///
/// 引数:
///     msg: 改行区切りのない、メッセージの内容
///     from_peer: メッセージを送信したピア
///
/// エラー:
///     解析エラーまたは処理エラー
fn handleMessage(msg: []const u8, from_peer: types.Peer) !void {
    if (std.mem.startsWith(u8, msg, "BLOCK:")) {
        // BLOCKメッセージを処理（6文字のプレフィックスをスキップ）
        try handleBlockMessage(msg[6..], from_peer);
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
            std.log.info("Contract in storage after sync: address={s}, code_length={d}", .{ entry.key_ptr.*, entry.value_ptr.*.len });
        }
        std.log.info("Current contract storage has {d} contracts", .{contract_count});

        // チェーン内の全ブロックを検査してコントラクトを探す（デバッグ用）
        for (blockchain.chain_store.items) |block| {
            if (block.contracts) |contracts| {
                std.log.info("Block {d} contains {d} contracts", .{ block.index, contracts.count() });
                var block_contract_it = contracts.iterator();
                while (block_contract_it.next()) |entry| {
                    std.log.info("Block {d} has contract: address={s}, code_length={d}", .{ block.index, entry.key_ptr.*, entry.value_ptr.*.len });
                }
            }
        }

        // コントラクト呼び出しがペンディングの場合、実行する
        if (main.global_call_pending) {
            std.log.info("Executing pending contract call to {s}", .{main.global_contract_address});

            // チェーン内の全ブロックを検査して特定のコントラクトを探す
            std.log.info("Searching for contract at address {s} in all blocks...", .{main.global_contract_address});
            var found_in_block = false;
            for (blockchain.chain_store.items) |block| {
                if (block.contracts) |contracts| {
                    if (contracts.get(main.global_contract_address)) |code| {
                        std.log.info("Contract found in block {d}, but might not be in storage. Code length: {d}", .{ block.index, code.len });
                        found_in_block = true;

                        // コントラクトコードが見つかったら、明示的にストレージに追加
                        blockchain.contract_storage.put(main.global_contract_address, code) catch |err| {
                            std.log.err("Failed to add contract to storage: {any}", .{err});
                        };
                    }
                }
            }

            if (!found_in_block) {
                std.log.warn("Contract not found in any blocks. Chain may not include the deployment block.", .{});
            }

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
        // EVMトランザクションメッセージを処理（7文字のプレフィックスをスキップ）
        try handleEvmTxMessage(msg["EVM_TX:".len..], from_peer);
        
        // 注意: 受信したトランザクションは再ブロードキャストしない
        // 理由: 無限ループを防止するため
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
/// 処理フロー：
/// 1. ストリームからデータを読み取る
/// 2. 改行で区切られたメッセージを探す
/// 3. 完全なメッセージがあれば処理
/// 4. 不完全なメッセージはバッファに保持
/// 5. 接続が切れるまで繰り返す
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

    // メッセージ受信バッファのサイズ（4KB）
    // 大きすぎるとメモリを無駄にし、小さすぎると大きなメッセージが処理できない
    const MESSAGE_BUFFER_SIZE = 4096;
    
    var reader = peer.stream.reader();
    var buf: [MESSAGE_BUFFER_SIZE]u8 = undefined;
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

test "EVM transaction queuing and flushing" {
    const allocator = std.testing.allocator;

    // Ensure clean state before test by clearing and freeing any existing items
    peer_list.clearRetainingCapacity(); // Does not free items
    while (pending_evm_txs.items.len > 0) {
        allocator.free(pending_evm_txs.pop());
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
    if (tx1.evm_data) |d| allocator.free(d); // Free original evm_data

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

    // Create a mock writer
    var mock_writer_instance = MockStreamWriter{ .buffer = &mock_stream_data_buffer };

    // Create a mock stream source. Reader is not used by sendEvmTx.
    const mock_stream_source = std.io.StreamSource{
        .reader = undefined, // Not used by sendEvmTx
        .writer = .{ .context = &mock_writer_instance, .writeFn = MockStreamWriter.write },
    };

    const mock_peer = types.Peer{
        .address = try std.net.Address.parseIp("127.0.0.1", 8080), // Dummy address
        .stream = mock_stream_source,
    };
    try peer_list.append(mock_peer);

    // Manually call the flushing logic (as in listenLoop/connectToPeer)
    std.log.info("Test: Flushing {d} pending EVM transactions to new mock peer", .{pending_evm_txs.items.len});
    for (pending_evm_txs.items) |payload_to_flush| {
        try sendEvmTx(mock_peer, payload_to_flush);
    }

    // The actual code uses pending_evm_txs.clearRetainingCapacity() which doesn't free items.
    // Items are freed because they are allocator.dupe'd into the queue.
    // So, here we must free them manually as they are popped.
    while (pending_evm_txs.items.len > 0) {
        allocator.free(pending_evm_txs.pop());
    }
    pending_evm_txs.clearRetainingCapacity(); // Match the main code's behavior

    // Assertions after flushing:
    // 1. Assert that pending_evm_txs is now empty
    try std.testing.expectEqual(@as(usize, 0), pending_evm_txs.items.len);

    // 2. Assert that the mock stream associated with mock_peer received the data for tx1
    var expected_sent_data_to_peer = std.ArrayList(u8).init(allocator);
    defer expected_sent_data_to_peer.deinit();
    try expected_sent_data_to_peer.writer().print("EVM_TX:{s}\n", .{expected_payload_tx1});

    try std.testing.expect(std.mem.eql(u8, expected_sent_data_to_peer.items, mock_stream_data_buffer.items));

    // Clean up peer_list
    _ = peer_list.pop(); // Remove mock_peer
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
    if (tx2.evm_data) |d| allocator.free(d);

    // 2. Serialize tx2
    const payload = try parser.serializeTransaction(allocator, tx2);
    defer allocator.free(payload);

    // 3. Parse the payload
    const parsed_tx = try parser.parseTransactionJson(payload);
    // Defer freeing fields of parsed_tx
    defer allocator.free(parsed_tx.sender);
    defer allocator.free(parsed_tx.receiver);
    if (parsed_tx.evm_data) |d| allocator.free(d);

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
