//! ブロックチェーンの基本実装
//! このファイルは、シンプルなブロックチェーンの実装を通じて、
//! 以下の要素について学ぶことができます：
//! - ブロック構造
//! - トランザクション
//! - ハッシュ計算
//! - Proof of Work (PoW)

const std = @import("std");
const crypto = std.crypto.hash;
const Sha256 = crypto.sha2.Sha256;

//------------------------------------------------------------------------------
// デバッグ機能
//------------------------------------------------------------------------------

/// デバッグ出力の制御フラグ
/// true: デバッグ情報を出力する
/// false: デバッグ情報を出力しない（本番環境用）
const debug_logging = false;

/// デバッグ出力用のヘルパー関数
/// コンパイル時に最適化され、debug_logging = false の場合は
/// 実行コードから完全に除去される
fn debugLog(comptime format: []const u8, args: anytype) void {
    if (comptime debug_logging) {
        std.debug.print(format, args);
    }
}

//------------------------------------------------------------------------------
// 基本データ構造の定義
//------------------------------------------------------------------------------

/// トランザクションの構造体
/// ブロックチェーン上で行われる取引を表現する
const Transaction = struct {
    sender: []const u8, // 送信者のアドレス（文字列）
    receiver: []const u8, // 受信者のアドレス（文字列）
    amount: u64, // 取引金額（整数）
};

/// ブロックの構造体
/// ブロックチェーンの各ブロックを表現する
const Block = struct {
    index: u32, // ブロック番号（0から始まる連番）
    timestamp: u64, // ブロック生成時のUNIXタイムスタンプ
    prev_hash: [32]u8, // 前のブロックのハッシュ値
    transactions: std.ArrayList(Transaction), // このブロックに含まれる取引のリスト
    nonce: u64, // Proof of Work用の値
    data: []const u8, // 追加データ（オプション）
    hash: [32]u8, // このブロック自身のハッシュ値
};

//------------------------------------------------------------------------------
// バイト変換ヘルパー関数
//------------------------------------------------------------------------------

/// u32 から u8 への安全な変換
/// 値が u8 の範囲を超える場合はパニックする
fn truncateU32ToU8(x: u32) u8 {
    if (x > 0xff) {
        @panic("u32 value out of u8 range");
    }
    return @truncate(x);
}

/// u64 から u8 への安全な変換
/// 値が u8 の範囲を超える場合はパニックする
fn truncateU64ToU8(x: u64) u8 {
    if (x > 0xff) {
        @panic("u64 value out of u8 range");
    }
    return @truncate(x);
}

/// u32 値をリトルエンディアンの4バイト配列に変換して返す
fn toBytesU32(value: u32) [4]u8 {
    var bytes: [4]u8 = undefined;
    bytes[0] = truncateU32ToU8(value & 0xff);
    bytes[1] = truncateU32ToU8((value >> 8) & 0xff);
    bytes[2] = truncateU32ToU8((value >> 16) & 0xff);
    bytes[3] = truncateU32ToU8((value >> 24) & 0xff);
    return bytes;
}

/// u64 値をリトルエンディアンの8バイト配列に変換して返す
fn toBytesU64(value: u64) [8]u8 {
    var bytes: [8]u8 = undefined;
    bytes[0] = truncateU64ToU8(value & 0xff);
    bytes[1] = truncateU64ToU8((value >> 8) & 0xff);
    bytes[2] = truncateU64ToU8((value >> 16) & 0xff);
    bytes[3] = truncateU64ToU8((value >> 24) & 0xff);
    bytes[4] = truncateU64ToU8((value >> 32) & 0xff);
    bytes[5] = truncateU64ToU8((value >> 40) & 0xff);
    bytes[6] = truncateU64ToU8((value >> 48) & 0xff);
    bytes[7] = truncateU64ToU8((value >> 56) & 0xff);
    return bytes;
}

/// 任意の型の値をバイト列に変換する汎用関数
/// comptime: コンパイル時に型チェックと最適化が行われる
fn toBytes(comptime T: type, value: T) []const u8 {
    if (T == u32) {
        return toBytesU32(@as(u32, value))[0..];
    } else if (T == u64) {
        return toBytesU64(@as(u64, value))[0..];
    } else {
        const bytes: [@sizeOf(T)]u8 = @bitCast(value);
        return bytes[0..];
    }
}

//------------------------------------------------------------------------------
// ハッシュ計算と採掘（マイニング）機能
//------------------------------------------------------------------------------

/// ブロックのハッシュ値を計算する
/// 以下の要素を順番に連結してハッシュを計算：
/// - ブロック番号
/// - タイムスタンプ
/// - nonce値
/// - 前ブロックのハッシュ
/// - 全トランザクション
/// - 追加データ
fn calculateHash(block: *const Block) [32]u8 {
    var hasher = Sha256.init(.{});

    // nonceのバイト列を作成して確認（デバッグ用）
    const nonce_bytes = toBytesU64(block.nonce);
    debugLog("nonce bytes: ", .{});
    if (comptime debug_logging) {
        for (nonce_bytes) |byte| {
            std.debug.print("{x:0>2},", .{byte});
        }
        std.debug.print("\n", .{});
    }

    // 各フィールドをハッシュ計算に追加
    hasher.update(toBytes(u32, block.index));
    hasher.update(toBytes(u64, block.timestamp));
    hasher.update(&nonce_bytes);
    hasher.update(block.prev_hash[0..]);

    // すべてのトランザクションを処理
    for (block.transactions.items) |tx| {
        hasher.update(tx.sender);
        hasher.update(tx.receiver);
        hasher.update(toBytes(u64, tx.amount));
    }
    hasher.update(block.data);

    const hash = hasher.finalResult();
    debugLog("nonce: {d}, hash: {x}\n", .{ block.nonce, hash });
    return hash;
}

/// ハッシュ値が指定された難易度を満たすかチェック
/// difficulty: 先頭何バイトが0である必要があるか
fn meetsDifficulty(hash: [32]u8, difficulty: u8) bool {
    const limit = if (difficulty <= 32) difficulty else 32;
    for (hash[0..limit]) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

/// ブロックの採掘（マイニング）を行う
/// 指定された難易度を満たすハッシュ値が見つかるまでnonceを増やし続ける
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

//------------------------------------------------------------------------------
// メイン処理
//------------------------------------------------------------------------------

/// メイン関数
/// 1. ジェネシスブロック（最初のブロック）の作成
/// 2. トランザクションの追加
/// 3. ブロックの採掘
/// 4. 結果の表示
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
    // 難易度1：先頭1バイトが0ならOK
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
