const std = @import("std");
const crypto = std.crypto.hash;
const Sha256 = crypto.sha2.Sha256;

const Block = struct {
    index: u32,
    timestamp: u64,
    prev_hash: [32]u8,
    data: []const u8,
    hash: [32]u8,
};

fn toBytes(comptime T: type, value: T) []const u8 {
    const bytes: [@sizeOf(T)]u8 = @bitCast(value);
    return bytes[0..@sizeOf(T)];
}

fn calculateHash(block: *const Block) [32]u8 {
    var hasher = Sha256.init(.{});
    hasher.update(toBytes(u32, block.index));
    hasher.update(toBytes(u64, block.timestamp));
    hasher.update(block.prev_hash[0..]);
    hasher.update(block.data);
    return hasher.finalResult();
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    var genesis_block = Block{
        .index = 0,
        .timestamp = 1672531200,
        .prev_hash = [_]u8{0} ** 32,
        .data = "Hello, Zig Blockchain!",
        .hash = [_]u8{0} ** 32,
    };

    genesis_block.hash = calculateHash(&genesis_block);

    try stdout.print("Block index: {d}\n", .{genesis_block.index});
    try stdout.print("Timestamp  : {d}\n", .{genesis_block.timestamp});
    try stdout.print("Data       : {s}\n", .{genesis_block.data});
    try stdout.print("Hash       : ", .{});
    for (genesis_block.hash) |byte| {
        try stdout.print("{x}", .{byte});
    }
    try stdout.print("\n", .{});
}
