const std = @import("std");
const crypto = std.crypto.hash;
const Sha256 = crypto.sha2.Sha256;

/// ブロックチェーンの1ブロックを表す構造体
/// - index: ブロック番号（u32）
/// - timestamp: ブロック生成時のタイムスタンプ（u64）
/// - prev_hash: 前ブロックのハッシュ（32バイトの固定長配列）
/// - data: ブロックに含まれるデータ（可変長スライス）
/// - hash: このブロックのハッシュ（SHA-256の結果、32バイト固定長配列）
const Block = struct {
    index: u32,
    timestamp: u64,
    prev_hash: [32]u8,
    data: []const u8,
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

/// calculateHash関数は、ブロックの各フィールドからバイト列を生成し、
/// それらを順次ハッシュ計算コンテキストに入力して最終的なSHA-256ハッシュを得る関数です。
fn calculateHash(block: *const Block) [32]u8 {
    // SHA-256のハッシュ計算コンテキストを初期化する
    var hasher = Sha256.init(.{});

    // ブロックのindex (u32) をバイト列に変換してハッシュに追加
    hasher.update(toBytes(u32, block.index));

    // ブロックのtimestamp (u64) をバイト列に変換してハッシュに追加
    hasher.update(toBytes(u64, block.timestamp));

    // 前ブロックのハッシュ（固定長配列）は既にスライスになっているのでそのまま追加
    hasher.update(block.prev_hash[0..]);

    // ブロック内のデータ（可変長スライス）もそのまま追加
    hasher.update(block.data);

    // これまでの入力からSHA-256ハッシュを計算して返す（32バイト配列）
    return hasher.finalResult();
}

/// main関数：ブロックの初期化、ハッシュ計算、及び結果の出力を行います。
pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    // genesis_block（最初のブロック）を作成
    var genesis_block = Block{
        .index = 0,
        .timestamp = 1672531200, // 例としてUnixタイムスタンプを指定
        .prev_hash = [_]u8{0} ** 32, // 初回は前ブロックのハッシュは全0
        .data = "Hello, Zig Blockchain!",
        .hash = [_]u8{0} ** 32, // 初期値は全0。後で計算結果で上書きする
    };

    // calculateHash()でブロックの全フィールドからハッシュを計算し、hashフィールドに保存する
    genesis_block.hash = calculateHash(&genesis_block);

    // 結果を出力
    try stdout.print("Block index: {d}\n", .{genesis_block.index});
    try stdout.print("Timestamp  : {d}\n", .{genesis_block.timestamp});
    try stdout.print("Data       : {s}\n", .{genesis_block.data});
    try stdout.print("Hash       : ", .{});
    // 32バイトのハッシュを1バイトずつ16進数（小文字）で出力する
    for (genesis_block.hash) |byte| {
        try stdout.print("{x}", .{byte});
    }
    try stdout.print("\n", .{});
}
