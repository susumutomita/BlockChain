const std = @import("std");

//------------------------------------------------------------------------------
// データ構造
//------------------------------------------------------------------------------
pub const Transaction = struct {
    sender: []const u8,
    receiver: []const u8,
    amount: u64,
};

pub const Block = struct {
    index: u32,
    timestamp: u64,
    prev_hash: [32]u8,
    transactions: std.ArrayList(Transaction),
    nonce: u64,
    data: []const u8,
    hash: [32]u8,
};
