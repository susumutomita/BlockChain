const std = @import("std");
const crypto = std.crypto.hash;
const Sha256 = crypto.sha2.Sha256;

/// トランザクションの構造体
/// 送信者(sender), 受信者(receiver), 金額(amount) の3つだけを持つ。
const Transaction = struct {
    sender: []const u8,
    receiver: []const u8,
    amount: u64,
    // 本来は署名やトランザクションIDなどの要素が必要
};

/// ブロックの構造体
/// - index: ブロック番号
/// - timestamp: 作成時刻
/// - prev_hash: 前ブロックのハッシュ（32バイト）
/// - transactions: 動的配列を使って複数のトランザクションを保持
/// - nonce: PoW用のnonce
/// - data: 既存コードとの互換を保つために残す(省略可)
/// - hash: このブロックのSHA-256ハッシュ(32バイト)
const Block = struct {
    index: u32,
    timestamp: u64,
    prev_hash: [32]u8,
    transactions: std.ArrayList(Transaction),
    data: []const u8, // (必要に応じて省略可能)
    nonce: u64, // PoW用のnonce
    hash: [32]u8,
};

/// toBytes関数は、任意の型Tの値をそのメモリ表現に基づく固定長のバイト配列に再解釈し、
/// その全要素を含むスライス([]const u8)として返します。
fn toBytes(comptime T: type, value: T) []const u8 {
    // 左辺で返り値の型を [@sizeOf(T)]u8 として指定する
    const bytes: [@sizeOf(T)]u8 = @bitCast(value);
    // 固定長配列を全体スライスとして返す
    return bytes[0..@sizeOf(T)];
}

/// calculateHash関数
/// ブロックの各フィールドを順番にハッシュ計算へ渡し、最終的なSHA-256ハッシュを得る。
fn calculateHash(block: *const Block) [32]u8 {
    var hasher = Sha256.init(.{});

    // indexとtimestampをバイト列へ変換
    hasher.update(toBytes(u32, block.index));
    hasher.update(toBytes(u64, block.timestamp));

    // 前のブロックのハッシュは配列→スライスで渡す
    hasher.update(block.prev_hash[0..]);

    // ブロックに保持されているトランザクション一覧をまとめてハッシュ
    for (block.transactions.items) |tx| {
        hasher.update(tx.sender);
        hasher.update(tx.receiver);
        hasher.update(toBytes(u64, tx.amount));
    }

    // 既存コードとの互換を保つため、dataもハッシュに含める
    hasher.update(block.data);

    return hasher.finalResult();
}

/// main関数：ブロックの初期化、ハッシュ計算、及び結果の出力を行います。
pub fn main() !void {
    // メモリ割り当て用アロケータを用意（ページアロケータを簡易使用）
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().writer();

    // ジェネシスブロック(最初のブロック)を作成
    var genesis_block = Block{
        .index = 0,
        .timestamp = 1672531200,
        .prev_hash = [_]u8{0} ** 32, // 前ブロックが無いので全0にする
        // アロケータの初期化は後で行うため、いったんundefinedに
        .transactions = undefined,
        .data = "Hello, Zig Blockchain!",
        .nonce = 0, //nonceフィールドを初期化(0から始める)
        .hash = [_]u8{0} ** 32,
    };

    // transactionsフィールドを動的配列として初期化
    genesis_block.transactions = std.ArrayList(Transaction).init(allocator);
    defer genesis_block.transactions.deinit();

    // トランザクションを2件追加
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
    // calculateHash()でブロックの全フィールドからハッシュを計算し、hashフィールドに保存する
    genesis_block.hash = calculateHash(&genesis_block);

    // 結果を出力
    try stdout.print("Block index: {d}\n", .{genesis_block.index});
    try stdout.print("Timestamp  : {d}\n", .{genesis_block.timestamp});
    try stdout.print("Nonce      : {d}\n", .{genesis_block.nonce});
    try stdout.print("Data       : {s}\n", .{genesis_block.data});
    try stdout.print("Transactions:\n", .{});
    for (genesis_block.transactions.items) |tx| {
        try stdout.print("  {s} -> {s} : {d}\n", .{ tx.sender, tx.receiver, tx.amount });
    }
    try stdout.print("Hash       : ", .{}); // ← ここはプレースホルダなし、引数なし
    // 32バイトのハッシュを1バイトずつ16進数で出力
    for (genesis_block.hash) |byte| {
        try stdout.print("{x}", .{byte});
    }
    try stdout.print("\n", .{});
}
