---
title: "第9章-2: 基本的なオペコードの実装"
free: true
---

## 基本的なEVMオペコードを実装する

前章でEVMの基本的なデータ構造を実装しました。本章では、これらを使って実際のオペコード（命令）を実装し、簡単なプログラムを実行できるようにします。

## オペコードとは

EVMのオペコードは1バイト（8ビット）で表現される命令です。各オペコードは特定の操作を実行します：

```
オペコード | 値   | 説明                          | スタック変化
---------|------|-------------------------------|----------------
STOP     | 0x00 | 実行を停止                      |
ADD      | 0x01 | 2つの値を加算                   | a, b → (a+b)
MUL      | 0x02 | 2つの値を乗算                   | a, b → (a*b)
PUSH1    | 0x60 | 1バイトをスタックにプッシュ      | → value
DUP1     | 0x80 | スタックトップを複製            | a → a, a
SWAP1    | 0x90 | スタックの上位2つを入れ替え      | a, b → b, a
```

## 実行コンテキストの定義

まず、EVM実行時の状態を管理する構造体を定義します：

```zig
/// EVM実行コンテキスト
pub const EvmContext = struct {
    stack: EvmStack,
    memory: EvmMemory,
    storage: EvmStorage,
    pc: usize,                      // プログラムカウンタ
    code: []const u8,               // 実行するバイトコード
    gas_remaining: usize,           // 残りガス
    stopped: bool,                  // 実行停止フラグ
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, code: []const u8, gas_limit: usize) EvmContext {
        return EvmContext{
            .stack = EvmStack.init(),
            .memory = EvmMemory.init(allocator),
            .storage = EvmStorage.init(allocator),
            .pc = 0,
            .code = code,
            .gas_remaining = gas_limit,
            .stopped = false,
            .allocator = allocator,
        };
    }
};
```

## 基本的なオペコードの実装

### 1. STOP（0x00）- 実行を停止

最も単純なオペコードです：

```zig
Opcode.STOP => {
    ctx.stopped = true;
},
```

### 2. ADD（0x01）- 加算

スタックから2つの値を取り出し、加算結果をプッシュ：

```zig
Opcode.ADD => {
    const b = try ctx.stack.pop();
    const a = try ctx.stack.pop();
    try ctx.stack.push(a.add(b));
},
```

### 3. PUSH1（0x60）- 1バイトをプッシュ

次のバイトを読み取ってスタックにプッシュ：

```zig
Opcode.PUSH1 => {
    ctx.pc += 1;
    if (ctx.pc >= ctx.code.len) {
        return error.OutOfBounds;
    }

    const value = EVMu256.fromU64(ctx.code[ctx.pc]);
    try ctx.stack.push(value);
},
```

## 実行エンジンの実装

オペコードを順次実行するメインループ：

```zig
/// EVMバイトコードを実行
pub fn execute(ctx: *EvmContext) !void {
    while (ctx.pc < ctx.code.len and !ctx.stopped) {
        const opcode = ctx.code[ctx.pc];

        // ガス消費
        const gas_cost = getGasCost(opcode);
        try consumeGas(ctx, gas_cost);

        // オペコード実行
        try executeOpcode(ctx, opcode);

        // プログラムカウンタを進める
        ctx.pc += 1;
    }
}
```

## 簡単なプログラムの実行例

### 例1: 5 + 3を計算

バイトコード：
```
0x60 0x05  // PUSH1 5
0x60 0x03  // PUSH1 3
0x01       // ADD
0x00       // STOP
```

実行の流れ：
1. `PUSH1 5`: スタックに5をプッシュ → [5]
2. `PUSH1 3`: スタックに3をプッシュ → [5, 3]
3. `ADD`: 5と3を加算 → [8]
4. `STOP`: 実行停止

### 例2: (2 + 3) × 4を計算

バイトコード：
```
0x60 0x02  // PUSH1 2
0x60 0x03  // PUSH1 3
0x01       // ADD
0x60 0x04  // PUSH1 4
0x02       // MUL
0x00       // STOP
```

## テストの実装

```zig
test "EVM basic operations" {
    const allocator = std.testing.allocator;

    // PUSH1 0x05, PUSH1 0x03, ADD というバイトコード
    const code = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01 };

    var ctx = EvmContext.init(allocator, &code, 1000000);
    defer ctx.deinit();

    try execute(&ctx);

    // スタックトップが8（5+3）であることを確認
    const result = try ctx.stack.pop();
    try std.testing.expectEqual(@as(u128, 8), result.lo);
}
```

## DUPとSWAP命令

### DUP1（0x80）- スタックトップを複製

```zig
Opcode.DUP1 => {
    const n = 1; // DUP1は1番目の要素を複製
    if (ctx.stack.depth() < n) {
        return error.StackUnderflow;
    }
    const value = ctx.stack.data[ctx.stack.top - n];
    try ctx.stack.push(value);
},
```

### SWAP1（0x90）- 上位2要素を交換

```zig
Opcode.SWAP1 => {
    const n = 1; // SWAP1は1番目と交換
    if (ctx.stack.depth() < n + 1) {
        return error.StackUnderflow;
    }
    const temp = ctx.stack.data[ctx.stack.top - 1];
    ctx.stack.data[ctx.stack.top - 1] = ctx.stack.data[ctx.stack.top - n - 1];
    ctx.stack.data[ctx.stack.top - n - 1] = temp;
},
```

## メモリ操作

### MSTORE（0x52）- メモリに保存

```zig
Opcode.MSTORE => {
    const offset = try ctx.stack.pop();
    const value = try ctx.stack.pop();
    // offsetの下位64ビットを使用
    try ctx.memory.store(@intCast(offset.lo), value);
},
```

### MLOAD（0x51）- メモリから読み込み

```zig
Opcode.MLOAD => {
    const offset = try ctx.stack.pop();
    const value = ctx.memory.load(@intCast(offset.lo));
    try ctx.stack.push(value);
},
```

## ガス計算

各オペコードには実行コストがあります：

```zig
/// オペコードのガス料金を取得
fn getGasCost(opcode: u8) usize {
    return switch (opcode) {
        Opcode.STOP => 0,
        Opcode.ADD, Opcode.SUB => 3,
        Opcode.MUL, Opcode.DIV => 5,
        Opcode.PUSH1 => 3,
        Opcode.DUP1 => 3,
        Opcode.SWAP1 => 3,
        Opcode.MSTORE, Opcode.MLOAD => 3,
        else => 1,
    };
}

/// ガスを消費
fn consumeGas(ctx: *EvmContext, amount: usize) !void {
    if (ctx.gas_remaining < amount) {
        return error.OutOfGas;
    }
    ctx.gas_remaining -= amount;
}
```

## デバッグ機能

実行過程を可視化するデバッグ関数：

```zig
/// スタックの状態を表示
pub fn printStack(ctx: *const EvmContext) void {
    std.debug.print("Stack (depth={}): ", .{ctx.stack.depth()});
    for (0..ctx.stack.top) |i| {
        const value = ctx.stack.data[i];
        std.debug.print("{} ", .{value.lo});
    }
    std.debug.print("\n", .{});
}

/// 実行状態を表示
pub fn printExecutionState(ctx: *const EvmContext, opcode: u8) void {
    std.debug.print("PC: {}, Opcode: 0x{x:0>2}, Gas: {}\n", .{
        ctx.pc,
        opcode,
        ctx.gas_remaining,
    });
    printStack(ctx);
}
```

## まとめ

本章では、EVMの基本的なオペコードを実装し、簡単な計算プログラムを実行できるようになりました。実装した主な機能：

1. **算術演算**: ADD、MUL、SUB
2. **スタック操作**: PUSH、DUP、SWAP
3. **メモリ操作**: MSTORE、MLOAD
4. **実行制御**: STOP
5. **ガス計算**: 各命令のコスト管理

次章では、より高度な機能（制御フロー、関数呼び出し、ストレージ操作）を実装し、実際のSolidityコントラクトを実行できるようにします。

## 演習問題

1. **SUB（減算）とDIV（除算）** オペコードを実装してみましょう
2. **PUSH2〜PUSH32** の可変長PUSH命令を実装してみましょう
3. **比較演算子（LT、GT、EQ）** を実装してみましょう
4. スタックの状態を視覚的に表示するデバッグツールを作ってみましょう

これらの演習を通じて、EVMの命令セットへの理解を深めましょう。
