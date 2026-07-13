//! 第9章: EVMの基本データ型である256ビット整数を動かす。

const std = @import("std");
const EVMu256 = @import("chapter9_lib").EVMu256;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    const a = EVMu256.fromU64(100);
    const b = EVMu256.fromU64(50);
    const sum = a.add(b);
    const difference = a.sub(b);
    const round_trip = EVMu256.fromBytes(&sum.toBytes());

    try stdout.print("100 + 50 = {d}\n", .{sum.lo});
    try stdout.print("100 - 50 = {d}\n", .{difference.lo});
    try stdout.print("sum round-trip: hi={d}, lo={d}\n", .{ round_trip.hi, round_trip.lo });
    try stdout.print("a == b: {}\n", .{a.eq(b)});
    try stdout.print("zero.isZero(): {}\n", .{EVMu256.zero().isZero()});
}

test "chapter 9 EVMu256 demo calculations" {
    const a = EVMu256.fromU64(100);
    const b = EVMu256.fromU64(50);

    try std.testing.expectEqual(@as(u128, 150), a.add(b).lo);
    try std.testing.expectEqual(@as(u128, 50), a.sub(b).lo);
}
