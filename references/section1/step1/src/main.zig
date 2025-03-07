const std = @import("std");

/// ブロックチェインの1ブロックを表す構造体
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

pub fn main() !void {
    // 出力用ライター
    const stdout = std.io.getStdOut().writer();

    // ブロックのサンプルインスタンスを作成
    const sample_block = Block{
        .index = 1,
        .timestamp = 1672531200, // 例: 適当なUNIXタイム
        .prev_hash = [_]u8{0} ** 32, // とりあえず0で埋める
        .data = "Hello, Zig Blockchain!", // 文字列をバイト列として扱う
        .hash = [_]u8{0} ** 32, // まだハッシュ値計算はしない
    };

    // 作成したブロックの情報を表示
    try stdout.print("Block index: {d}\n", .{sample_block.index});
    try stdout.print("Timestamp  : {d}\n", .{sample_block.timestamp});
    try stdout.print("Data       : {s}\n", .{sample_block.data});
}
