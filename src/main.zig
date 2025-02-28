const std = @import("std");
const crypto = std.crypto.hash;
const Sha256 = crypto.sha2.Sha256;

const Transaction = struct {
    sender: []const u8,
    receiver: []const u8,
    amount: u64,
};

const Block = struct {
    index: u32,
    timestamp: u64,
    prev_hash: [32]u8,
    transactions: std.ArrayList(Transaction),
    data: []const u8,
    nonce: u64,
    hash: [32]u8,
};

/// u32 から u8 への安全な変換ヘルパー関数
fn truncateU32ToU8(x: u32) u8 {
    if (x > 0xff) {
        @panic("u32 value out of u8 range");
    }
    return @truncate(x);
}

/// u64 から u8 への安全な変換ヘルパー関数
fn truncateU64ToU8(x: u64) u8 {
    if (x > 0xff) {
        @panic("u64 value out of u8 range");
    }
    return @truncate(x);
}

/// u32 値をリトルエンディアンのバイト列に変換
fn toBytesU32(value: u32) []const u8 {
    var bytes: [4]u8 = undefined;
    bytes[0] = truncateU32ToU8(value & @as(u32, 0xff));
    bytes[1] = truncateU32ToU8((value >> 8) & @as(u32, 0xff));
    bytes[2] = truncateU32ToU8((value >> 16) & @as(u32, 0xff));
    bytes[3] = truncateU32ToU8((value >> 24) & @as(u32, 0xff));
    return &bytes;
}

/// u64 値をリトルエンディアンのバイト列に変換
fn toBytesU64(value: u64) []const u8 {
    var bytes: [8]u8 = undefined;
    bytes[0] = truncateU64ToU8(value & @as(u64, 0xff));
    bytes[1] = truncateU64ToU8((value >> 8) & @as(u64, 0xff));
    bytes[2] = truncateU64ToU8((value >> 16) & @as(u64, 0xff));
    bytes[3] = truncateU64ToU8((value >> 24) & @as(u64, 0xff));
    bytes[4] = truncateU64ToU8((value >> 32) & @as(u64, 0xff));
    bytes[5] = truncateU64ToU8((value >> 40) & @as(u64, 0xff));
    bytes[6] = truncateU64ToU8((value >> 48) & @as(u64, 0xff));
    bytes[7] = truncateU64ToU8((value >> 56) & @as(u64, 0xff));
    return &bytes;
}

/// ジェネリックな toBytes 関数
fn toBytes(comptime T: type, value: T) []const u8 {
    if (T == u32) {
        return toBytesU32(@as(u32, value));
    } else if (T == u64) {
        return toBytesU64(@as(u64, value));
    } else {
        const bytes: [@sizeOf(T)]u8 = @bitCast(value);
        return bytes[0..];
    }
}

fn calculateHash(block: *const Block) [32]u8 {
    var hasher = Sha256.init(.{});

    hasher.update(toBytes(u32, block.index));
    hasher.update(toBytes(u64, block.timestamp));
    hasher.update(block.prev_hash[0..]);
    hasher.update(toBytes(u64, block.nonce));
    for (block.transactions.items) |tx| {
        hasher.update(tx.sender);
        hasher.update(tx.receiver);
        hasher.update(toBytes(u64, tx.amount));
    }
    hasher.update(block.data);

    return hasher.finalResult();
}

fn meetsDifficulty(hash: [32]u8, difficulty: u8) bool {
    // 難易度チェック：先頭 difficulty バイトがすべて 0 であれば成功
    for (hash[0..difficulty]) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

fn mineBlock(block: *Block, difficulty: u8) void {
    while (true) {
        const new_hash = calculateHash(block);

        std.debug.print("Nonce: {d}, Hash: ", .{block.nonce});
        for (new_hash) |byte| {
            std.debug.print("{x}", .{byte});
        }
        std.debug.print("\n", .{});

        if (meetsDifficulty(new_hash, difficulty)) {
            block.hash = new_hash;
            break;
        }
        block.nonce += 1;
    }
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().writer();

    var genesis_block = Block{
        .index = 0,
        .timestamp = 1672531200,
        .prev_hash = [_]u8{0} ** 32,
        .transactions = undefined,
        .data = "Hello, Zig Blockchain!",
        .nonce = 0,
        .hash = [_]u8{0} ** 32,
    };

    genesis_block.transactions = std.ArrayList(Transaction).init(allocator);
    defer genesis_block.transactions.deinit();

    try genesis_block.transactions.append(Transaction{
        .sender = "Alice",
        .receiver = "Bob",
        .amount = 100,
    });
    try genesis_block.transactions.append(Transaction{
        .sender = "Charlie",
        .receiver = "Dave",
        .amount = 50,
    });

    genesis_block.hash = calculateHash(&genesis_block);
    // 難易度 1：先頭1バイトが 0 であるかをチェック
    mineBlock(&genesis_block, 2);

    try stdout.print("Block index: {d}\n", .{genesis_block.index});
    try stdout.print("Timestamp  : {d}\n", .{genesis_block.timestamp});
    try stdout.print("Nonce      : {d}\n", .{genesis_block.nonce});
    try stdout.print("Data       : {s}\n", .{genesis_block.data});
    try stdout.print("Transactions:\n", .{});
    for (genesis_block.transactions.items) |tx| {
        try stdout.print("  {s} -> {s} : {d}\n", .{ tx.sender, tx.receiver, tx.amount });
    }
    try stdout.print("Hash       : ", .{});
    for (genesis_block.hash) |byte| {
        try stdout.print("{x}", .{byte});
    }
    try stdout.print("\n", .{});
}
