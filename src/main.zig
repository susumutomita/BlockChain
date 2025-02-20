const std = @import("std");

// ブロック構造体の定義
const Block = struct {
    index: u32, // ブロック番号
    timestamp: u64, // 作成時刻（Unix時間など）
    prev_hash: [32]u8, // 前のブロックのハッシュ値（32バイト）
    data: []const u8, // ブロックに含めるデータ（今回はバイト列）
    hash: [32]u8, // このブロックのハッシュ値（32バイト）
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
