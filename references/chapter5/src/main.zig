// main.zig

const std = @import("std");
const types = @import("types.zig");
const blockchain = @import("blockchain.zig");

//------------------------------------------------------------------------------
// メイン処理およびテスト実行
//------------------------------------------------------------------------------
//
// main 関数では、以下の手順を実行しています：
// 1. ジェネシスブロック(最初のブロック)を初期化。
// 2. 取引リスト(トランザクション)の初期化と追加。
// 3. ブロックのハッシュを計算し、指定難易度に到達するまで nonce を探索(採掘)。
// 4. 最終的なブロック情報を標準出力に表示。
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().writer();

    // 1. ジェネシスブロックを作成
    //    (細かい値は適宜変更)
    var genesis_block = types.Block{
        .index = 0,
        .timestamp = 1672531200,
        .prev_hash = [_]u8{0} ** 32,
        .transactions = std.ArrayList(types.Transaction).init(allocator),
        .nonce = 0,
        .data = "Hello, Zig Blockchain!",
        .hash = [_]u8{0} ** 32,
    };
    defer genesis_block.transactions.deinit();

    // 2. 適当なトランザクションを追加
    try genesis_block.transactions.append(types.Transaction{
        .sender = "Alice",
        .receiver = "Bob",
        .amount = 100,
    });
    try genesis_block.transactions.append(types.Transaction{
        .sender = "Charlie",
        .receiver = "Dave",
        .amount = 50,
    });

    // 3. 初期ハッシュを計算
    genesis_block.hash = blockchain.calculateHash(&genesis_block);
    // 4. マイニング(難易度=1)
    try stdout.print("Start Minig: {d}\n", .{genesis_block.index});
    blockchain.mineBlock(&genesis_block, 1);

    // 5. 結果を表示
    try stdout.print("Block index: {d}\n", .{genesis_block.index});
    try stdout.print("Timestamp  : {d}\n", .{genesis_block.timestamp});
    try stdout.print("Nonce      : {d}\n", .{genesis_block.nonce});
    try stdout.print("Data       : {s}\n", .{genesis_block.data});
    for (genesis_block.transactions.items) |tx| {
        try stdout.print("- Tx: {s} -> {s} : {d}\n", .{ tx.sender, tx.receiver, tx.amount });
    }
    try stdout.print("Hash       : ", .{});
    for (genesis_block.hash) |byte| {
        try stdout.print("{x}", .{byte});
    }
    try stdout.print("\n", .{});
}
