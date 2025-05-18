const std = @import("std");
const blockchain = @import("src/blockchain.zig");
const types = @import("src/types.zig");

pub fn main() !void {
    // Initialize test blockchain with various transaction types
    try setupTestBlockchain();

    // Display the chain state using our enhanced printChainState
    blockchain.printChainState();
}

fn setupTestBlockchain() !void {
    const allocator = std.heap.page_allocator;

    // Create a genesis block first
    var genesis_block = try blockchain.createTestGenesisBlock(allocator);

    // Add a simple transaction
    try genesis_block.transactions.append(types.Transaction{
        .sender = "Alice",
        .receiver = "Bob",
        .amount = 100,
        .tx_type = 0, // Regular transfer
        .evm_data = null,
        .gas_limit = 0,
        .gas_price = 0,
        .id = [_]u8{1} ** 32,
    });

    // Add the genesis block to the chain
    blockchain.mineBlock(&genesis_block, 1);
    blockchain.addBlock(genesis_block);

    // Create a second block with a contract deployment transaction
    const last_block = blockchain.chain_store.items[blockchain.chain_store.items.len - 1];
    var block2 = blockchain.createBlock("Block with contract", last_block);

    // Create bytecode for testing (simple bytecode)
    const test_bytecode = "608060405234801561001057600080fd5b50";
    var bytecode_array = [_]u8{0} ** 50;
    std.mem.copy(u8, &bytecode_array, test_bytecode);

    // Add a contract deployment transaction
    try block2.transactions.append(types.Transaction{
        .sender = "Charlie",
        .receiver = "Contract1",
        .amount = 0,
        .tx_type = 1, // Contract deployment
        .evm_data = &bytecode_array,
        .gas_limit = 100000,
        .gas_price = 20000000000,
        .id = [_]u8{2} ** 32,
    });

    // Add a contract call transaction
    try block2.transactions.append(types.Transaction{
        .sender = "Dave",
        .receiver = "Contract1",
        .amount = 50,
        .tx_type = 2, // Contract call
        .evm_data = &[_]u8{ 0xA9, 0x05, 0x9C, 0xBB }, // Example function selector
        .gas_limit = 50000,
        .gas_price = 20000000000,
        .id = [_]u8{3} ** 32,
    });

    // Mine and add block2
    blockchain.mineBlock(&block2, 1);
    blockchain.addBlock(block2);
}
