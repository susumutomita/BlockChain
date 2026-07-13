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
    const index_bytes = utils.toBytes(u32, block.index);
    hasher.update(&index_bytes);
    // タイムスタンプ (u64) をバイト列に変換して追加
    const timestamp_bytes = utils.toBytes(u64, block.timestamp);
    hasher.update(&timestamp_bytes);
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
pub fn addBlock(new_block: types.Block) bool {
    if (!verifyBlockPow(&new_block)) {
        std.log.warn("Received block fails PoW check. Rejecting it.", .{});
        return false;
    }
    chain_store.append(new_block) catch return false;
    std.log.info("Added new block index={d}, nonce={d}, hash={x:0>2}", .{ new_block.index, new_block.nonce, new_block.hash });
    return true;
}

pub fn sendBlock(block: types.Block, remote_addr: std.net.Address) !void {
    const json_data = parser.serializeBlock(block) catch |err| {
        std.debug.print("Serialize error: {any}\n", .{err});
        return err;
    };
    defer std.heap.page_allocator.free(json_data);

    var socket = try std.net.tcpConnectToAddress(remote_addr);
    defer socket.close();

    var writer = socket.writer();
    try writer.writeAll("BLOCK:");
    try writer.writeAll(json_data);
    try writer.writeAll("\n");
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
    fn handleMessage(message: []const u8) void {
        std.log.info("[Received complete message] {s}", .{message});

        if (!std.mem.startsWith(u8, message, "BLOCK:")) {
            std.log.info("Unknown message: {s}", .{message});
            return;
        }

        var new_block = parser.parseBlockJson(message[6..]) catch |err| {
            std.log.err("Failed parseBlockJson: {any}", .{err});
            return;
        };
        if (!addBlock(new_block)) parser.deinitParsedBlock(&new_block);
    }

    pub fn run(conn: std.net.Server.Connection) !void {
        defer conn.stream.close();
        std.log.info("Accepted: {any}", .{conn.address});

        var reader = conn.stream.reader();
        var buf: [4096]u8 = undefined;
        var buffered: usize = 0;

        while (true) {
            const n = try reader.read(buf[buffered..]);
            if (n == 0) {
                std.log.info("Peer {any} disconnected.", .{conn.address});
                break;
            }

            buffered += n;
            var consumed: usize = 0;
            while (std.mem.indexOfScalarPos(u8, buf[0..buffered], consumed, '\n')) |newline| {
                const message = std.mem.trimRight(u8, buf[consumed..newline], "\r");
                handleMessage(message);
                consumed = newline + 1;
            }

            if (consumed > 0) {
                const remaining = buffered - consumed;
                std.mem.copyForwards(u8, buf[0..remaining], buf[consumed..buffered]);
                buffered = remaining;
            }

            if (buffered == buf.len) {
                std.log.err("Message too long; rejecting connection from {any}", .{conn.address});
                break;
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
        defer lastBlock.transactions.deinit();
        clientSendLoop(peer, &lastBlock) catch unreachable;
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
        defer std.heap.page_allocator.free(block_json);

        try writer.writeAll("BLOCK:");
        try writer.writeAll(block_json);
        try writer.writeAll("\n");
        lastBlock.transactions.deinit();
        lastBlock.* = new_block;
    }
}

test "tampered block is rejected without changing chain height" {
    chain_store.clearRetainingCapacity();
    defer chain_store.clearRetainingCapacity();

    var genesis = try createTestGenesisBlock(std.testing.allocator);
    defer genesis.transactions.deinit();

    var block = createBlock("valid", genesis);
    defer block.transactions.deinit();
    mineBlock(&block, DIFFICULTY);
    block.data = "tampered";

    try std.testing.expect(!addBlock(block));
    try std.testing.expectEqual(@as(usize, 0), chain_store.items.len);
}
