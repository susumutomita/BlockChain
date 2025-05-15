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

// PUSH0のテスト
test "EVM PUSH0 operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // バイトコード:
    // PUSH0,                          // 0をプッシュ
    // PUSH1 0x00, MSTORE,             // メモリに保存
    // PUSH1 0x20, PUSH1 0x00, RETURN  // 戻り値を返す
    const bytecode = [_]u8{
        0x5F, // PUSH0
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

    // 結果が0になっていることを確認
    try std.testing.expect(value.hi == 0);
    try std.testing.expect(value.lo == 0);
}

// JUMPのテスト
test "EVM JUMP operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // バイトコード:
    // PUSH1 0x0A, JUMP,              // 0x0Aにジャンプ
    // PUSH1 0x2A,                     // 42をプッシュ（スキップされる）
    // PUSH1 0x00, MSTORE,             // メモリに保存（スキップされる）
    // PUSH1 0x20, PUSH1 0x00, RETURN, // 戻り値を返す（スキップされる）
    // JUMPDEST,                       // ジャンプ先（0x0A）
    // PUSH1 0x37,                     // 55をプッシュ
    // PUSH1 0x00, MSTORE,             // メモリに保存
    // PUSH1 0x20, PUSH1 0x00, RETURN  // 戻り値を返す
    const bytecode = [_]u8{
        0x60, 0x0A, // PUSH1 10（ジャンプ先）
        0x56, // JUMP
        0x60, 0x2A, // PUSH1 42（スキップされる）
        0x60, 0x00, // PUSH1 0（スキップされる）
        0x52, // MSTORE（スキップされる）
        0x60, 0x20, // PUSH1 32（スキップされる）
        0x60, 0x00, // PUSH1 0（スキップされる）
        0xf3, // RETURN（スキップされる）
        0x5B, // JUMPDEST（ジャンプ先）
        0x60, 0x37, // PUSH1 55
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

    // 結果が55（ジャンプ先の値）になっていることを確認
    try std.testing.expect(value.hi == 0);
    try std.testing.expect(value.lo == 55);
}

// CALLDATASIZEのテスト
test "EVM CALLDATASIZE operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // バイトコード:
    // CALLDATASIZE,                  // コールデータサイズを取得
    // PUSH1 0x00, MSTORE,             // メモリに保存
    // PUSH1 0x20, PUSH1 0x00, RETURN  // 戻り値を返す
    const bytecode = [_]u8{
        0x36, // CALLDATASIZE
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    // テスト用コールデータ（8バイト）
    const calldata = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
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

    // 結果が8（コールデータのサイズ）になっていることを確認
    try std.testing.expect(value.hi == 0);
    try std.testing.expect(value.lo == 8);
}

// ビット演算（AND, OR, XOR, NOT）のテスト
test "EVM bitwise operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // ANDテスト: 0x0F & 0x33 = 0x03
    const bytecode_and = [_]u8{
        0x60, 0x0F, // PUSH1 0x0F
        0x60, 0x33, // PUSH1 0x33
        0x16, // AND
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const result_and = try evm.execute(allocator, &bytecode_and, &[_]u8{}, 100000);
    defer allocator.free(result_and);

    var value_and = EVMu256{ .hi = 0, .lo = 0 };
    if (result_and.len >= 32) {
        for (0..16) |i| {
            const byte_val = result_and[i];
            value_and.hi |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
        for (0..16) |i| {
            const byte_val = result_and[i + 16];
            value_and.lo |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
    }

    // 結果が0x03（0x0F & 0x33）になっていることを確認
    try std.testing.expect(value_and.hi == 0);
    try std.testing.expect(value_and.lo == 0x03);

    // ORテスト: 0x0F | 0x33 = 0x3F
    const bytecode_or = [_]u8{
        0x60, 0x0F, // PUSH1 0x0F
        0x60, 0x33, // PUSH1 0x33
        0x17, // OR
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const result_or = try evm.execute(allocator, &bytecode_or, &[_]u8{}, 100000);
    defer allocator.free(result_or);

    var value_or = EVMu256{ .hi = 0, .lo = 0 };
    if (result_or.len >= 32) {
        for (0..16) |i| {
            const byte_val = result_or[i];
            value_or.hi |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
        for (0..16) |i| {
            const byte_val = result_or[i + 16];
            value_or.lo |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
    }

    // 結果が0x3F（0x0F | 0x33）になっていることを確認
    try std.testing.expect(value_or.hi == 0);
    try std.testing.expect(value_or.lo == 0x3F);

    // XORテスト: 0x0F ^ 0x33 = 0x3C
    const bytecode_xor = [_]u8{
        0x60, 0x0F, // PUSH1 0x0F
        0x60, 0x33, // PUSH1 0x33
        0x18, // XOR
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const result_xor = try evm.execute(allocator, &bytecode_xor, &[_]u8{}, 100000);
    defer allocator.free(result_xor);

    var value_xor = EVMu256{ .hi = 0, .lo = 0 };
    if (result_xor.len >= 32) {
        for (0..16) |i| {
            const byte_val = result_xor[i];
            value_xor.hi |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
        for (0..16) |i| {
            const byte_val = result_xor[i + 16];
            value_xor.lo |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
    }

    // 結果が0x3C（0x0F ^ 0x33）になっていることを確認
    try std.testing.expect(value_xor.hi == 0);
    try std.testing.expect(value_xor.lo == 0x3C);

    // NOTテスト: ~0x0F = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF0
    const bytecode_not = [_]u8{
        0x60, 0x0F, // PUSH1 0x0F
        0x19, // NOT
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const result_not = try evm.execute(allocator, &bytecode_not, &[_]u8{}, 100000);
    defer allocator.free(result_not);

    var value_not = EVMu256{ .hi = 0, .lo = 0 };
    if (result_not.len >= 32) {
        for (0..16) |i| {
            const byte_val = result_not[i];
            value_not.hi |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
        for (0..16) |i| {
            const byte_val = result_not[i + 16];
            value_not.lo |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
    }

    // 結果が~0x0Fになっていることを確認
    try std.testing.expect(value_not.hi == 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF);
    try std.testing.expect(value_not.lo == 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF0);
}
