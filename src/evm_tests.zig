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

// SimpleAdder コントラクトのテスト
test "EVM SimpleAdder contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // SimpleAdder コントラクトのデプロイコード
    // PUSH0, CODECOPY, PUSH0, RETURN などを含む
    const deploy_bytecode = [_]u8{
        // デプロイ部分
        0x61, 0x00, 0x2C, // PUSH2 0x002C (コントラクトコードの長さ)
        0x61, 0x00, 0x0A, // PUSH2 0x000A (コントラクトコードのオフセット)
        0x5F,             // PUSH0 (メモリ先頭アドレス)
        0x39,             // CODECOPY (コードをメモリへコピー)
        0x5F,             // PUSH0 (オフセット)
        0xF3,             // RETURN (メモリ上のコードを返す)

        // コントラクト本体コード (add関数を含む)
        0x36,             // CALLDATASIZE (入力データ長を取得)
        0x60, 0x04,       // PUSH1 0x04
        0x10,             // LT (データ長 < 4 バイトか)
        0x61, 0x00, 0x28, // PUSH2 0x0028 (条件成立時のジャンプ先)
        0x57,             // JUMPI (条件付きジャンプ)
        0x60, 0x00,       // PUSH1 0x00
        0x35,             // CALLDATALOAD (データ読み出し)
        0x60, 0xE0,       // PUSH1 0xE0
        0x1C,             // SHR (シフト演算で関数シグネチャ抽出)
        0x63, 0x77, 0x16, 0x02, 0xF7, // PUSH4 0x771602F7 (add関数のシグネチャ)
        0x14,             // EQ (シグネチャ一致比較)
        0x15,             // ISZERO (一致しなければ真)
        0x61, 0x00, 0x28, // PUSH2 0x0028 (ジャンプ先)
        0x57,             // JUMPI (一致しない場合のフォールバックへジャンプ)
        0x60, 0x04,       // PUSH1 0x04
        0x35,             // CALLDATALOAD (第1引数読み取り)
        0x60, 0x24,       // PUSH1 0x24
        0x35,             // CALLDATALOAD (第2引数読み取り)
        0x01,             // ADD (加算演算)
        0x60, 0x00,       // PUSH1 0x00
        0x52,             // MSTORE (結果をメモリに書き込み)
        0x60, 0x20,       // PUSH1 0x20
        0x60, 0x00,       // PUSH1 0x00
        0xF3,             // RETURN (結果32バイトを返却)
        0x5B,             // JUMPDEST (フォールバック処理のラベル)
        0x5F,             // PUSH0 (offset=0)
        0x5F,             // PUSH0 (length=0)
        0xFD,             // REVERT (データなしでリバート)
    };

    // デプロイ実行
    const deploy_result = try evm.execute(allocator, &deploy_bytecode, &[_]u8{}, 1000000);
    defer allocator.free(deploy_result);

    // デプロイ結果からコントラクトコードを取得
    const contract_code = deploy_result;

    // add(1, 2)の呼び出しデータを作成
    // 関数シグネチャ + 引数
    const calldata = [_]u8{
        // 関数シグネチャ: add(uint256,uint256) = 0x771602f7
        0x77, 0x16, 0x02, 0xf7,
        // 第1引数: 1 (32バイトにパディング)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        // 第2引数: 2 (32バイトにパディング)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
    };

    // コントラクト実行
    const result = try evm.execute(allocator, contract_code, &calldata, 1000000);
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

    // 結果が3（1+2）になっていることを確認
    try std.testing.expect(value.hi == 0);
    try std.testing.expect(value.lo == 3);
}

// PUSH0 オペコードのテスト
test "EVM PUSH0 operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // バイトコード:
    // PUSH0,         // 0をスタックにプッシュ
    // PUSH1 0x00, MSTORE,
    // PUSH1 0x20, PUSH1 0x00, RETURN
    const bytecode = [_]u8{
        0x5F, // PUSH0
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
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
// ビット演算のテスト (AND, OR, XOR, NOT)
test "EVM bitwise operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // AND演算のテスト
    const bytecode_and = [_]u8{
        0x60, 0x0F, // PUSH1 15 (0x0F)
        0x60, 0x33, // PUSH1 51 (0x33)
        0x16, // AND (0x33 & 0x0F = 0x03)
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
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

    // 結果が3 (0x33 & 0x0F = 0x03) になっていることを確認
    try std.testing.expect(value_and.hi == 0);
    try std.testing.expect(value_and.lo == 3);

    // OR演算のテスト
    const bytecode_or = [_]u8{
        0x60, 0x0F, // PUSH1 15 (0x0F)
        0x60, 0x30, // PUSH1 48 (0x30)
        0x17, // OR (0x30 | 0x0F = 0x3F)
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
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

    // 結果が63 (0x30 | 0x0F = 0x3F) になっていることを確認
    try std.testing.expect(value_or.hi == 0);
    try std.testing.expect(value_or.lo == 63);
}

// SAR（算術右シフト）のテスト
test "EVM SAR operation - positive value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

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
