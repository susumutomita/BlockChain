//! 第9章のライブラリ入口。
//!
//! このチェックポイントでは、EVM全体へ進む前に256ビット整数の表現と
//! 基本演算、ビッグエンディアンのバイト変換だけを扱う。

const std = @import("std");

pub const EVMu256 = @import("evm_types.zig").EVMu256;

test "EVMu256 addition carries into the high half" {
    const max_low = EVMu256{ .hi = 0, .lo = std.math.maxInt(u128) };
    const result = max_low.add(EVMu256.one());

    try std.testing.expectEqual(@as(u128, 1), result.hi);
    try std.testing.expectEqual(@as(u128, 0), result.lo);
}

test "EVMu256 byte conversion round-trips" {
    const value = EVMu256{
        .hi = 0x0123456789abcdef_fedcba9876543210,
        .lo = 0x0011223344556677_8899aabbccddeeff,
    };

    const bytes = value.toBytes();
    const decoded = EVMu256.fromBytes(&bytes);

    try std.testing.expect(decoded.eq(value));
}
