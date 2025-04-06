const std = @import("std");
const crypto = std.crypto.hash;
const Sha256 = crypto.sha2.Sha256;
const types = @import("types.zig");
const logger = @import("logger.zig");
const utils = @import("utils.zig");

//------------------------------------------------------------------------------
// ハッシュ計算とPoWマイニング
//------------------------------------------------------------------------------

pub fn calculateHash(block: *const types.Block) [32]u8 {
    var hasher = Sha256.init(.{});

    // index
    hasher.update(utils.toBytes(u32, block.index));
    // timestamp
    hasher.update(utils.toBytes(u64, block.timestamp));
    // nonce
    hasher.update(utils.toBytes(u64, block.nonce));
    // prev_hash
    hasher.update(&block.prev_hash);

    // transactions
    for (block.transactions.items) |tx| {
        hasher.update(tx.sender);
        hasher.update(tx.receiver);
        hasher.update(utils.toBytes(u64, tx.amount));
    }

    // data
    hasher.update(block.data);

    const result = hasher.finalResult();
    return result;
}

pub fn meetsDifficulty(hash: [32]u8, difficulty: u8) bool {
    const limit = if (difficulty <= 32) difficulty else 32;
    for (hash[0..limit]) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

pub fn mineBlock(block: *types.Block, difficulty: u8) void {
    while (true) {
        const new_hash = calculateHash(block);
        logger.debugLog("Hash: {x}\n", .{new_hash});
        if (meetsDifficulty(new_hash, difficulty)) {
            block.hash = new_hash;
            break;
        }
        block.nonce += 1;
    }
}
