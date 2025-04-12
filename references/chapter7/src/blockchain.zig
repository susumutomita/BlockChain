const std = @import("std");
const crypto = std.crypto.hash;
const Sha256 = crypto.sha2.Sha256;
const types = @import("types.zig");
const logger = @import("logger.zig");
const utils = @import("utils.zig");
const chainError = @import("errors.zig").ChainError;
const parser = @import("parser.zig");
const DIFFICULTY: u8 = 2;
var chain_store = std.ArrayList(types.Block).init(std.heap.page_allocator);

//------------------------------------------------------------------------------
// ハッシュ計算とマイニング処理
//------------------------------------------------------------------------------
//
// calculateHash 関数では、ブロック内の各フィールドを連結して
// SHA-256 のハッシュを計算します。
// mineBlock 関数は、nonce をインクリメントしながら
// meetsDifficulty による難易度チェックをパスするハッシュを探します。

/// calculateHash:
/// 指定されたブロックの各フィールドをバイト列に変換し、
/// その連結結果から SHA-256 ハッシュを計算して返す関数。
pub fn calculateHash(block: *const types.Block) [32]u8 {
    var hasher = Sha256.init(.{});

    // nonce の値をバイト列に変換(8バイト)し、デバッグ用に出力
    const nonce_bytes = utils.toBytesU64(block.nonce);
    logger.debugLog("nonce bytes: ", .{});
    if (comptime logger.debug_logging) {
        for (nonce_bytes) |byte| {
            std.debug.print("{x:0>2},", .{byte});
        }
        std.debug.print("\n", .{});
    }

    // ブロック番号 (u32) をバイト列に変換して追加
    hasher.update(utils.toBytes(u32, block.index));
    // タイムスタンプ (u64) をバイト列に変換して追加
    hasher.update(utils.toBytes(u64, block.timestamp));
    // nonce のバイト列を追加
    hasher.update(nonce_bytes[0..]);
    // 前ブロックのハッシュ(32バイト)を追加
    hasher.update(&block.prev_hash);

    // すべてのトランザクションについて、各フィールドを追加
    for (block.transactions.items) |tx| {
        hasher.update(tx.sender);
        hasher.update(tx.receiver);
        const amount_bytes = utils.toBytesU64(tx.amount);
        hasher.update(&amount_bytes);
    }
    // 追加データをハッシュに追加
    hasher.update(block.data);

    // 最終的なハッシュ値を計算
    const hash = hasher.finalResult();
    logger.debugLog("nonce: {d}, hash: {x}\n", .{ block.nonce, hash });
    return hash;
}

/// meetsDifficulty:
/// ハッシュ値の先頭 'difficulty' バイトがすべて 0 であれば true を返す。
pub fn meetsDifficulty(hash: [32]u8, difficulty: u8) bool {
    // difficulty が 32 を超える場合は 32 に丸める
    const limit = if (difficulty <= 32) difficulty else 32;
    for (hash[0..limit]) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

/// mineBlock:
/// 指定された難易度を満たすハッシュが得られるまで、
/// nonce の値を増やしながらハッシュ計算を繰り返す関数。
pub fn mineBlock(block: *types.Block, difficulty: u8) void {
    while (true) {
        const new_hash = calculateHash(block);
        if (meetsDifficulty(new_hash, difficulty)) {
            block.hash = new_hash;
            break;
        }
        block.nonce += 1;
    }
}

/// verifyBlockPow:
/// ブロックのProof of Work検証を行う関数
pub fn verifyBlockPow(b: *const types.Block) bool {
    // 1) `calculateHash(b)` → meetsDifficulty
    const recalculated = calculateHash(b);
    if (!std.mem.eql(u8, recalculated[0..], b.hash[0..])) {
        return false; // hashフィールドと再計算が一致しない
    }
    if (!meetsDifficulty(recalculated, DIFFICULTY)) {
        return false; // PoWが難易度を満たしていない
    }
    return true;
}

// addBlock: 受け取ったブロックをチェインに追加（検証付き）
pub fn addBlock(new_block: types.Block) void {
    if (!verifyBlockPow(&new_block)) {
        std.log.err("Received block fails PoW check. Rejecting it.", .{});
        return;
    }
    chain_store.append(new_block) catch {};
    std.log.info("Added new block index={d}, nonce={d}, hash={x}", .{ new_block.index, new_block.nonce, new_block.hash });
}

pub fn sendBlock(block: types.Block, remote_addr: std.net.Address) !void {
    const json_data = parser.serializeBlock(block) catch |err| {
        std.debug.print("Serialize error: {any}\n", .{err});
        return err;
    };
    var socket = try std.net.tcpConnectToAddress(remote_addr);
    var writer = socket.writer();
    try writer.writeAll("BLOCK:" ++ json_data);
}

/// createBlock: 新しいブロックを生成
pub fn createBlock(input: []const u8, prevBlock: types.Block) types.Block {
    return types.Block{
        .index = prevBlock.index + 1,
        .timestamp = @intCast(std.time.timestamp()),
        .prev_hash = prevBlock.hash,
        .transactions = std.ArrayList(types.Transaction).init(std.heap.page_allocator),
        .nonce = 0,
        .data = input,
        .hash = [_]u8{0} ** 32,
    };
}

/// createTestGenesisBlock: テスト用のジェネシスブロックを生成
pub fn createTestGenesisBlock(allocator: std.mem.Allocator) !types.Block {
    var genesis = types.Block{
        .index = 0,
        .timestamp = 1672531200,
        .prev_hash = [_]u8{0} ** 32,
        .transactions = std.ArrayList(types.Transaction).init(allocator),
        .nonce = 0,
        .data = "Hello, Zig Blockchain!",
        .hash = [_]u8{0} ** 32,
    };
    try genesis.transactions.append(types.Transaction{ .sender = "Alice", .receiver = "Bob", .amount = 100 });
    mineBlock(&genesis, DIFFICULTY);
    return genesis;
}

//--------------------------------------
// メッセージ受信処理: ConnHandler
//--------------------------------------
pub const ConnHandler = struct {
    pub fn run(conn: std.net.Server.Connection) !void {
        defer conn.stream.close();
        std.log.info("Accepted: {any}", .{conn.address});

        var reader = conn.stream.reader();
        var buf: [1024]u8 = undefined;

        while (true) {
            const n = try reader.read(&buf);
            if (n == 0) {
                std.log.info("Peer {any} disconnected.", .{conn.address});
                // 外部でピアリストが利用可能な場合は切断を通知する
                if (@hasDecl(@import("main"), "peer_list")) {
                    const main = @import("main");
                    main.peer_list.markDisconnected(conn.address);
                }
                break;
            }
            const msg_slice = buf[0..n];
            std.log.info("[Received] {s}", .{msg_slice});

            // 簡易メッセージ解析
            if (std.mem.startsWith(u8, msg_slice, "BLOCK:")) {
                // "BLOCK:" の後ろを取り出してJSONパースする
                const json_part = msg_slice[6..];
                const new_block = parser.parseBlockJson(json_part) catch |err| {
                    std.log.err("Failed parseBlockJson: {any}", .{err});
                    continue;
                };
                // チェインに追加
                addBlock(new_block);
                
                // メッセージを他のピアに伝播（外部のピアリストが利用可能な場合）
                if (@hasDecl(@import("main"), "broadcastMessage")) {
                    const main = @import("main");
                    _ = main.broadcastMessage(msg_slice, std.heap.page_allocator) catch {};
                }
            } else {
                // それ以外はログだけ
                std.log.info("Unknown message: {s}", .{msg_slice});
            }
        }
    }
};

//--------------------------------------
// クライアント処理
//--------------------------------------
pub const ClientHandler = struct {
    pub fn run(peer: types.Peer) !void {
        // クライアントはローカルに Genesis ブロックを保持（本来はサーバーから同期する）
        var lastBlock = try createTestGenesisBlock(std.heap.page_allocator);
        
        // ブロック送信ループはバックグラウンドで実行
        const thread = try std.Thread.spawn(.{}, clientSendLoop, .{ peer, &lastBlock });
        _ = thread;
        
        // メインスレッドでは受信処理
        var reader = peer.stream.reader();
        var buf: [1024]u8 = undefined;
        
        while (true) {
            const n = reader.read(&buf) catch |err| {
                std.log.err("Error reading from peer {any}: {any}", .{ peer.address, err });
                break;
            };
            
            if (n == 0) {
                std.log.info("Peer {any} disconnected", .{peer.address});
                break;
            }
            
            const msg_slice = buf[0..n];
            std.log.info("Received from peer {any}: {s}", .{ peer.address, msg_slice });
            
            // メッセージ解析
            if (std.mem.startsWith(u8, msg_slice, "BLOCK:")) {
                const json_part = msg_slice[6..];
                const new_block = parser.parseBlockJson(json_part) catch |err| {
                    std.log.err("Failed to parse block from peer {any}: {any}", .{ peer.address, err });
                    continue;
                };
                
                // ブロックチェーンに追加
                addBlock(new_block);
                lastBlock.* = new_block;
            }
        }
    }
};

fn clientSendLoop(peer: types.Peer, lastBlock: *types.Block) !void {
    var stdin = std.io.getStdIn();
    var reader = stdin.reader();
    var line_buffer: [256]u8 = undefined;
    while (true) {
        std.debug.print("Enter message for new block: ", .{});
        const maybe_line = try reader.readUntilDelimiterOrEof(line_buffer[0..], '\n');
        if (maybe_line == null) break;
        const user_input = maybe_line.?;
        var new_block = createBlock(user_input, lastBlock.*);
        mineBlock(&new_block, DIFFICULTY);
        var writer = peer.stream.writer();
        const block_json = parser.serializeBlock(new_block) catch unreachable;
        // 必要なサイズのバッファを用意して "BLOCK:" と block_json を連結する
        var buf = try std.heap.page_allocator.alloc(u8, "BLOCK:".len + block_json.len);
        defer std.heap.page_allocator.free(buf);

        // バッファに連結
        @memcpy(buf[0.."BLOCK:".len], "BLOCK:");
        @memcpy(buf["BLOCK:".len..], block_json);

        // 1回の書き出しで送信
        try writer.writeAll(buf);
        lastBlock.* = new_block;
    }
}
