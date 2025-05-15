const std = @import("std");
const evm = @import("evm.zig");
const EVMu256 = @import("evm_types.zig").EVMu256;

// SHL（論理左シフト）のテスト
test "EVM SHL operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // バイトコード:
    // PUSH1 0x02, PUSH1 0x10, SHL,    // 0x10 << 2 = 0x40
    // PUSH1 0x00, MSTORE,             // 結果をメモリに保存
    // PUSH1 0x20, PUSH1 0x00, RETURN  // 戻り値を返す
    const bytecode = [_]u8{
        0x60, 0x02, // PUSH1 2
        0x60, 0x10, // PUSH1 16 (0x10)
        0x1B, // SHL
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const calldata = [_]u8{};
    const result = try evm.execute(allocator, &bytecode, &calldata, 100000);
    defer allocator.free(result);

    // 結果をEVMu256形式で解釈
    var value = EVMu256{ .hi = 0, .lo = 0 };
    if (result.len >= 32) {
        // 上位16バイトを解析
        for (0..16) |i| {
            const byte_val = result[i];
            value.hi |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }

        // 下位16バイトを解析
        for (0..16) |i| {
            const byte_val = result[i + 16];
            value.lo |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
    }

    // 結果が64（16 << 2）になっていることを確認
    try std.testing.expect(value.hi == 0);
    try std.testing.expect(value.lo == 64);
}

// SAR（算術右シフト）のテスト
test "EVM SAR operation - positive value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // バイトコード (正の値のテスト):
    // PUSH1 0x02, PUSH1 0x10, SAR,    // 0x10 >> 2 = 0x04 (符号拡張なし)
    // PUSH1 0x00, MSTORE,             // 結果をメモリに保存
    // PUSH1 0x20, PUSH1 0x00, RETURN  // 戻り値を返す
    const bytecode = [_]u8{
        0x60, 0x02, // PUSH1 2
        0x60, 0x10, // PUSH1 16 (0x10)
        0x1D, // SAR
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const calldata = [_]u8{};
    const result = try evm.execute(allocator, &bytecode, &calldata, 100000);
    defer allocator.free(result);

    // 結果をEVMu256形式で解釈
    var value = EVMu256{ .hi = 0, .lo = 0 };
    if (result.len >= 32) {
        // 上位16バイトを解析
        for (0..16) |i| {
            const byte_val = result[i];
            value.hi |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }

        // 下位16バイトを解析
        for (0..16) |i| {
            const byte_val = result[i + 16];
            value.lo |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
    }

    // 結果が4（16 >> 2, 符号拡張なし）になっていることを確認
    try std.testing.expect(value.hi == 0);
    try std.testing.expect(value.lo == 4);
}

// SAR（算術右シフト）の負の値のテスト
test "EVM SAR operation - negative value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 最上位ビットが1の値 (0x80...0)を作成し、SARでシフト
    const bytecode = [_]u8{
        0x7F, // PUSH32
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x80...
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // ...
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // ...
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // ...0
        0x60, 0x02, // PUSH1 2
        0x1D, // SAR
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const calldata = [_]u8{};
    const result = try evm.execute(allocator, &bytecode, &calldata, 100000);
    defer allocator.free(result);

    // 結果をEVMu256形式で解釈
    var value = EVMu256{ .hi = 0, .lo = 0 };
    if (result.len >= 32) {
        // 上位16バイトを解析
        for (0..16) |i| {
            const byte_val = result[i];
            value.hi |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }

        // 下位16バイトを解析
        for (0..16) |i| {
            const byte_val = result[i + 16];
            value.lo |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
    }

    // 結果が右シフト2かつ符号拡張されていることを確認
    // 最上位ビットとその次の2ビットが1であることを確認 (0xE0...)
    try std.testing.expect(value.hi & (0xE0 << 120) == (0xE0 << 120));
    try std.testing.expect(value.lo == 0);
}

// CODESIZE オペコードのテスト
test "EVM CODESIZE operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // バイトコード:
    // CODESIZE,     // プログラムサイズを取得
    // PUSH1 0x00, MSTORE,
    // PUSH1 0x20, PUSH1 0x00, RETURN
    const bytecode = [_]u8{
        0x38, // CODESIZE
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const calldata = [_]u8{};
    const result = try evm.execute(allocator, &bytecode, &calldata, 100000);
    defer allocator.free(result);

    // 結果をEVMu256形式で解釈
    var value = EVMu256{ .hi = 0, .lo = 0 };
    if (result.len >= 32) {
        // 上位16バイトを解析
        for (0..16) |i| {
            const byte_val = result[i];
            value.hi |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }

        // 下位16バイトを解析
        for (0..16) |i| {
            const byte_val = result[i + 16];
            value.lo |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
    }

    // バイトコードの長さが8であることを確認
    try std.testing.expect(value.hi == 0);
    try std.testing.expect(value.lo == bytecode.len);
}
