const std = @import("std");
const evm = @import("evm.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x01, // ADD
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const result = try evm.execute(allocator, &bytecode, &.{}, 100_000);
    defer allocator.free(result);
    if (result.len != 32) return error.UnexpectedReturnLength;

    const stdout = std.io.getStdOut().writer();
    try stdout.print("EVM result: 5 + 3 = {d}\n", .{result[31]});
}
