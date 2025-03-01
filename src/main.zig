const std = @import("std");
const crypto = std.crypto.hash;
const Sha256 = crypto.sha2.Sha256;

/// トランザクションの構造体
/// 送信者(sender), 受信者(receiver), 金額(amount) の3つだけを持つ。
const Transaction = struct {
    sender: []const u8,
    receiver: []const u8,
    amount: u64,
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
    nonce: u64,
    data: []const u8,
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

/// toBytes関数は、任意の型Tの値をそのメモリ表現に基づく固定長のバイト配列に再解釈し、
/// その全要素を含むスライス([]const u8)として返します。
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

/// calculateHash関数
/// ブロックの各フィールドを順番にハッシュ計算へ渡し、最終的なSHA-256ハッシュを得る。
fn calculateHash(block: *const Block) [32]u8 {
    var hasher = Sha256.init(.{});

    // indexとtimestampをバイト列へ変換
    hasher.update(toBytes(u32, block.index));
    hasher.update(toBytes(u64, block.timestamp));

    // 前のブロックのハッシュは配列→スライスで渡す
    hasher.update(block.prev_hash[0..]);
    hasher.update(toBytes(u64, block.nonce));
    for (block.transactions.items) |tx| {
        hasher.update(tx.sender);
        hasher.update(tx.receiver);
        hasher.update(toBytes(u64, tx.amount));
    }

    // 既存コードとの互換を保つため、dataもハッシュに含める
    hasher.update(block.data);

    return hasher.finalResult();
}

fn meetsDifficulty(hash: [32]u8, difficulty: u8) bool {
    // 難易度チェック：先頭 difficulty バイトがすべて 0 であれば成功
    const limit = if (difficulty <= 32) difficulty else 32;
    for (hash[0..limit]) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

fn mineBlock(block: *Block, difficulty: u8) void {
    while (true) {
        const new_hash = calculateHash(block);
        if (meetsDifficulty(new_hash, difficulty)) {
            block.hash = new_hash;
            break;
        }
        block.nonce += 1;
    }
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
        .transactions = undefined, // アロケータの初期化は後で行うため、いったんundefinedに
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
    // 難易度 1：先頭1バイトが 0 であるかをチェック
    mineBlock(&genesis_block, 1);

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
