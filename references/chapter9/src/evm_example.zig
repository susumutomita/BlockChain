const std = @import("std");
const EVMu256 = @import("evm_types.zig").EVMu256;

pub fn main() !void {
    // 2つの256ビット整数を作成
    const a = EVMu256.fromU64(100);
    const b = EVMu256.fromU64(50);

    // 加算: 100 + 50 = 150
    const sum = a.add(b);
    std.debug.print("100 + 50 = {}\n", .{sum.lo});

    // 減算: 100 - 50 = 50
    const diff = a.sub(b);
    std.debug.print("100 - 50 = {}\n", .{diff.lo});

    // 等価比較
    const is_equal = a.eq(b);
    std.debug.print("a == b: {}\n", .{is_equal});

    // ゼロチェック
    const zero = EVMu256.zero();
    std.debug.print("zero.isZero(): {}\n", .{zero.isZero()});
}
