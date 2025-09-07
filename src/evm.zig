//! Ethereum Virtual Machine (EVM) 実装
//!
//! このモジュールはEthereumのスマートコントラクト実行環境であるEVMを
//! 簡易的に実装します。EVMバイトコードを解析・実行し、スタックベースの
//! 仮想マシンとして動作します。

const std = @import("std");
const logger = @import("logger.zig");
const evm_types = @import("evm_types.zig");
const evm_debug = @import("evm_debug.zig");
// u256型を別名で使用して衝突を回避
const EVMu256 = evm_types.EVMu256;
const EvmContext = evm_types.EvmContext;

/// EVMオペコード定義
pub const Opcode = struct {
    // 終了・リバート系
    pub const STOP = 0x00;
    pub const RETURN = 0xF3;
    pub const REVERT = 0xFD;
    pub const INVALID = 0xFE;

    // スタック操作・算術命令
    pub const ADD = 0x01;
    pub const MUL = 0x02;
    pub const SUB = 0x03;
    pub const DIV = 0x04;
    pub const SDIV = 0x05;
    pub const MOD = 0x06;
    pub const SMOD = 0x07;
    pub const ADDMOD = 0x08;
    pub const MULMOD = 0x09;
    pub const EXP = 0x0A;
    pub const LT = 0x10;
    pub const GT = 0x11;
    pub const SLT = 0x12;
    pub const SGT = 0x13;
    pub const EQ = 0x14;
    pub const ISZERO = 0x15;
    pub const AND = 0x16;
    pub const OR = 0x17;
    pub const XOR = 0x18;
    pub const NOT = 0x19;

    // ビットシフト操作
    pub const SHL = 0x1B; // 論理左シフト
    pub const SHR = 0x1C; // 論理右シフト
    pub const SAR = 0x1D; // 算術右シフト

    pub const POP = 0x50;

    // メモリ操作
    pub const MLOAD = 0x51;
    pub const MSTORE = 0x52;
    pub const MSTORE8 = 0x53;

    // ストレージ操作
    pub const SLOAD = 0x54;
    pub const SSTORE = 0x55;

    // 制御フロー
    pub const JUMP = 0x56;
    pub const JUMPI = 0x57;
    pub const PC = 0x58;
    pub const JUMPDEST = 0x5B;

    // PUSHシリーズ (PUSH0-PUSH32)
    pub const PUSH0 = 0x5F; // 定数0をスタックに積む (Solidity 0.8.24で追加)
    pub const PUSH1 = 0x60;
    // 他のPUSH命令も順次増えていく (0x61-0x7F)

    // DUPシリーズ (DUP1-DUP16)
    pub const DUP1 = 0x80;
    // 他のDUP命令も順次増えていく (0x81-0x8F)

    // SWAPシリーズ (SWAP1-SWAP16)
    pub const SWAP1 = 0x90;
    // 他のSWAP命令も順次増えていく (0x91-0x9F)

    // 呼び出しデータ関連
    pub const CALLDATALOAD = 0x35;
    pub const CALLDATASIZE = 0x36;
    pub const CALLDATACOPY = 0x37;

    // コード関連
    pub const CODESIZE = 0x38;
    pub const CODECOPY = 0x39;

    // 戻りデータ関連
    pub const RETURNDATASIZE = 0x3D;
    pub const RETURNDATACOPY = 0x3E;

    // コントラクト関連
    pub const CALLVALUE = 0x34; // 呼び出し時の送金額
};

/// エラー型定義
pub const EVMError = error{
    OutOfGas,
    StackOverflow,
    StackUnderflow,
    InvalidJump,
    InvalidOpcode,
    MemoryOutOfBounds,
    Revert,
};

/// EVMバイトコードを実行する
///
/// 引数:
///     allocator: メモリアロケータ
///     code: EVMバイトコード
///     calldata: コントラクト呼び出し時の引数データ
///     gas_limit: 実行時のガス上限
///
/// 戻り値:
///     []const u8: 実行結果のバイト列
///
/// エラー:
///     様々なEVM実行エラー
pub fn execute(allocator: std.mem.Allocator, code: []const u8, calldata: []const u8, gas_limit: usize) ![]const u8 {
    // EVMコンテキストの初期化
    var context = EvmContext.init(allocator, code, calldata);
    // ガスリミット設定
    context.gas = gas_limit;
    defer context.deinit();

    // メインの実行ループ
    while (context.pc < context.code.len and !context.stopped) {
        executeStep(&context) catch |err| {
            // エラー発生時に詳細な診断情報を表示
            if (err == EVMError.InvalidOpcode) {
                const opcode = context.code[context.pc];
                std.log.err("無効なオペコードエラー: 0x{x:0>2} (10進: {d}) at PC={d}", .{ opcode, opcode, context.pc });

                // 現在のオペコードとその周囲を逆アセンブルして表示
                var asmDump = std.ArrayList(u8).init(allocator);
                defer asmDump.deinit();

                // 逆アセンブル結果を取得
                evm_debug.disassembleContext(&context, asmDump.writer()) catch |disasmErr| {
                    std.log.err("逆アセンブル失敗: {any}", .{disasmErr});
                };

                std.log.err("コード逆アセンブル:\n{s}", .{asmDump.items});

                // コード周辺のバイトコードを16進数で表示
                const startIdx = if (context.pc > 10) context.pc - 10 else 0;
                const endIdx = if (context.pc + 10 < context.code.len) context.pc + 10 else context.code.len;
                var hexDump = std.ArrayList(u8).init(allocator);
                defer hexDump.deinit();

                for (startIdx..endIdx) |i| {
                    if (i == context.pc) {
                        // 問題のオペコードを強調表示
                        _ = hexDump.writer().print("[0x{x:0>2}] ", .{context.code[i]}) catch {};
                    } else {
                        _ = hexDump.writer().print("0x{x:0>2} ", .{context.code[i]}) catch {};
                    }
                }

                std.log.err("コードコンテキスト(Hex): {s}", .{hexDump.items});

                // エラーの詳細情報も表示
                if (context.error_msg != null) {
                    std.log.err("エラー詳細: {s}", .{context.error_msg.?});
                }
            } else {
                std.log.err("EVM実行エラー: {any} at PC={d}", .{ err, context.pc });
            }
            return err;
        };
    }

    // 戻り値をコピーして返す
    const result = try allocator.alloc(u8, context.returndata.items.len);
    @memcpy(result, context.returndata.items);
    return result;
}

/// EVMバイトコードを実行し、エラーが発生した場合に詳細情報を返す
///
/// 引数:
///     allocator: メモリアロケータ
///     code: EVMバイトコード
///     calldata: コントラクト呼び出し時の引数データ
///     gas_limit: 実行時のガス上限
///
/// 戻り値:
///     EvmExecutionResult構造体: 実行結果とエラー情報を含む
///
pub const EvmExecutionResult = struct {
    /// 実行が成功したかどうか
    success: bool,
    /// 実行結果のデータ（成功時のみ有効）
    data: []const u8,
    /// エラーメッセージ（失敗時のみ有効）
    error_message: ?[]const u8,
    /// エラーの種類
    error_type: ?EVMError,
    /// プログラムカウンタ（失敗した位置）
    error_pc: ?usize,
};

pub fn executeWithErrorInfo(allocator: std.mem.Allocator, code: []const u8, calldata: []const u8, gas_limit: usize) EvmExecutionResult {
    // EVMコンテキストの初期化
    var context = EvmContext.init(allocator, code, calldata);
    context.gas = gas_limit;
    defer context.deinit();

    var result = EvmExecutionResult{
        .success = false,
        .data = &[_]u8{},
        .error_message = null,
        .error_type = null,
        .error_pc = null,
    };

    // メインの実行ループ
    while (context.pc < context.code.len and !context.stopped) {
        executeStep(&context) catch |err| {
            // エラーの詳細情報を格納
            result.error_type = switch (err) {
                EVMError.OutOfGas => EVMError.OutOfGas,
                EVMError.StackOverflow => EVMError.StackOverflow,
                EVMError.StackUnderflow => EVMError.StackUnderflow,
                EVMError.InvalidJump => EVMError.InvalidJump,
                EVMError.InvalidOpcode => EVMError.InvalidOpcode,
                EVMError.MemoryOutOfBounds => EVMError.MemoryOutOfBounds,
                EVMError.Revert => EVMError.Revert,
                else => EVMError.InvalidOpcode, // エラーの種類が不明な場合はInvalidOpcodeを返す
            };
            result.error_pc = context.pc;

            if (context.error_msg != null) {
                result.error_message = allocator.dupe(u8, context.error_msg.?) catch null;
            } else {
                // Zig 0.14: エラー名を `{s}` で整形し "error." 接頭辞を避ける
                const err_name = @errorName(err);
                const errMsg = std.fmt.allocPrint(allocator, "EVM実行エラー: {s} at PC={d}", .{ err_name, context.pc }) catch "Unknown error";
                result.error_message = errMsg;
            }

            return result;
        };
    }

    // 成功時は結果をコピーして返す
    result.success = true;
    result.data = allocator.dupe(u8, context.returndata.items) catch &[_]u8{};

    return result;
}

/// 単一のEVM命令を実行
fn executeStep(context: *EvmContext) !void {
    // 現在のオペコードを取得
    const opcode = context.code[context.pc];

    // 詳細デバッグ: 特定のPC位置での実行状況をログ
    if (context.pc >= 20 and context.pc <= 50) {
        std.log.info("DEBUG: PC={d}, opcode=0x{x:0>2}, stack_depth={d}", .{ context.pc, opcode, context.stack.depth() });
    }

    // ガス消費（シンプル版 - 本来は命令ごとに異なる）
    if (context.gas < 1) {
        context.error_msg = "Out of gas";
        return EVMError.OutOfGas;
    }
    context.gas -= 1;

    // オペコードを解釈して実行
    switch (opcode) {
        Opcode.STOP => {
            context.stopped = true;
        },

        Opcode.ADD => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const a = try context.stack.pop();
            const b = try context.stack.pop();
            try context.stack.push(a.add(b));
            context.pc += 1;
        },

        Opcode.POP => {
            // POP: スタックトップの値を削除
            if (context.stack.depth() < 1) return EVMError.StackUnderflow;
            _ = try context.stack.pop(); // 値を捨てる
            context.pc += 1;
        },

        Opcode.MUL => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const a = try context.stack.pop();
            const b = try context.stack.pop();
            try context.stack.push(a.mul(b));
            context.pc += 1;
        },

        Opcode.SUB => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const a = try context.stack.pop();
            const b = try context.stack.pop();
            try context.stack.push(a.sub(b));
            context.pc += 1;
        },

        Opcode.DIV => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const a = try context.stack.pop();
            const b = try context.stack.pop();
            // 0除算の場合は0を返す
            if (b.hi == 0 and b.lo == 0) {
                try context.stack.push(EVMu256.zero());
            } else {
                // 簡易版ではu64の範囲のみサポート
                if (a.hi == 0 and b.hi == 0) {
                    const result = EVMu256.fromU64(@intCast(a.lo / b.lo));
                    try context.stack.push(result);
                } else {
                    // 本来はより複雑な処理が必要
                    try context.stack.push(EVMu256.zero());
                }
            }
            context.pc += 1;
        },

        Opcode.MOD => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const a = try context.stack.pop();
            const b = try context.stack.pop();
            // 0除算の場合は0を返す
            if (b.hi == 0 and b.lo == 0) {
                try context.stack.push(EVMu256.zero());
            } else {
                // 簡易版ではu64の範囲のみサポート
                if (a.hi == 0 and b.hi == 0) {
                    const result = EVMu256.fromU64(@intCast(a.lo % b.lo));
                    try context.stack.push(result);
                } else {
                    // 本来はより複雑な処理が必要
                    try context.stack.push(EVMu256.zero());
                }
            }
            context.pc += 1;
        },

        // PUSH1: 1バイトをスタックにプッシュ
        Opcode.PUSH1 => {
            if (context.pc + 1 >= context.code.len) return EVMError.InvalidOpcode;
            const value = EVMu256.fromU64(context.code[context.pc + 1]);
            try context.stack.push(value);
            context.pc += 2; // オペコード＋データで2バイト進む
        },

        // DUP1: スタックトップの値を複製
        Opcode.DUP1 => {
            if (context.stack.depth() < 1) return EVMError.StackUnderflow;
            const value = context.stack.data[context.stack.sp - 1];
            try context.stack.push(value);
            context.pc += 1;
        },

        // SWAP1: スタックトップと2番目の要素を交換
        Opcode.SWAP1 => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const a = context.stack.data[context.stack.sp - 1];
            const b = context.stack.data[context.stack.sp - 2];
            context.stack.data[context.stack.sp - 1] = b;
            context.stack.data[context.stack.sp - 2] = a;
            context.pc += 1;
        },

        Opcode.MLOAD => {
            if (context.stack.depth() < 1) return EVMError.StackUnderflow;
            const offset = try context.stack.pop();
            // 現在はu64範囲のみサポート
            if (offset.hi != 0) return EVMError.MemoryOutOfBounds;
            const value = try context.memory.load32(@intCast(offset.lo));
            try context.stack.push(value);
            context.pc += 1;
        },

        Opcode.MSTORE => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const offset = try context.stack.pop();
            const value = try context.stack.pop();
            // 現在はu64範囲のみサポート
            if (offset.hi != 0) return EVMError.MemoryOutOfBounds;
            try context.memory.store32(@intCast(offset.lo), value);
            context.pc += 1;
        },

        Opcode.SLOAD => {
            if (context.stack.depth() < 1) return EVMError.StackUnderflow;
            const key = try context.stack.pop();
            const value = context.storage.load(key);
            try context.stack.push(value);
            context.pc += 1;
        },

        Opcode.SSTORE => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const key = try context.stack.pop();
            const value = try context.stack.pop();
            try context.storage.store(key, value);
            context.pc += 1;
        },

        Opcode.CALLDATALOAD => {
            if (context.stack.depth() < 1) return EVMError.StackUnderflow;
            const offset = try context.stack.pop();
            if (offset.hi != 0) return EVMError.MemoryOutOfBounds;

            var result = EVMu256.zero();
            const off = @as(usize, @intCast(offset.lo));

            std.log.info("CALLDATALOAD: offset={d}, calldata.len={d}", .{ off, context.calldata.len });

            // calldataから32バイトをロード（範囲外は0埋め）
            for (0..32) |i| {
                const byte_pos = off + i;
                if (byte_pos < context.calldata.len) {
                    const byte_val = context.calldata[byte_pos];
                    if (i < 16) {
                        // 上位16バイト
                        result.hi |= @as(u128, byte_val) << @intCast((15 - i) * 8);
                    } else {
                        // 下位16バイト
                        result.lo |= @as(u128, byte_val) << @intCast((31 - i) * 8);
                    }
                }
            }

            // オフセット0の場合（関数セレクター読み込み）の詳細ログ
            if (off == 0) {
                std.log.info("CALLDATALOAD: Loading function selector from calldata", .{});
                if (context.calldata.len >= 4) {
                    const selector = (@as(u32, context.calldata[0]) << 24) |
                        (@as(u32, context.calldata[1]) << 16) |
                        (@as(u32, context.calldata[2]) << 8) |
                        @as(u32, context.calldata[3]);
                    std.log.info("CALLDATALOAD: First 4 bytes (function selector): 0x{x:0>8}", .{selector});
                }
                std.log.info("CALLDATALOAD: Full calldata: {any}", .{context.calldata});
            }

            std.log.info("CALLDATALOAD: Result - hi: 0x{x:0>32}, lo: 0x{x:0>32}", .{ result.hi, result.lo });

            try context.stack.push(result);
            context.pc += 1;
        },

        Opcode.RETURN => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const offset = try context.stack.pop();
            const length = try context.stack.pop();

            // 現在はu64範囲のみサポート
            if (offset.hi != 0 or length.hi != 0) return EVMError.MemoryOutOfBounds;

            const off = @as(usize, @intCast(offset.lo));
            const len = @as(usize, @intCast(length.lo));

            try context.memory.ensureSize(off + len);
            if (len > 0) {
                try context.returndata.resize(len);
                for (0..len) |i| {
                    if (off + i < context.memory.data.items.len) {
                        context.returndata.items[i] = context.memory.data.items[off + i];
                    } else {
                        context.returndata.items[i] = 0;
                    }
                }
            }

            context.stopped = true;
        },

        Opcode.RETURNDATASIZE => {
            // スタックに直前の呼び出し戻りデータのサイズを積む
            // 簡易実装では常に0を返す
            try context.stack.push(EVMu256.zero());
            context.pc += 1;
        },

        Opcode.EQ => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const a = try context.stack.pop();
            const b = try context.stack.pop();

            // 関数セレクター比較の場合をログ出力
            if ((a.hi == 0 and a.lo <= 0xFFFFFFFF) or (b.hi == 0 and b.lo <= 0xFFFFFFFF)) {
                std.log.info("EQ: Comparing values (possibly function selector)", .{});
                std.log.info("EQ: a = hi: 0x{x:0>32}, lo: 0x{x:0>32} (as u32: 0x{x:0>8})", .{ a.hi, a.lo, @as(u32, @intCast(a.lo & 0xFFFFFFFF)) });
                std.log.info("EQ: b = hi: 0x{x:0>32}, lo: 0x{x:0>32} (as u32: 0x{x:0>8})", .{ b.hi, b.lo, @as(u32, @intCast(b.lo & 0xFFFFFFFF)) });
            }

            // 等価比較: 両方の値が完全に一致する場合は1、それ以外は0
            const is_equal = a.hi == b.hi and a.lo == b.lo;
            if (is_equal) {
                std.log.info("EQ: Values are EQUAL, pushing 1", .{});
                try context.stack.push(EVMu256.fromU64(1));
            } else {
                std.log.info("EQ: Values are NOT EQUAL, pushing 0", .{});
                try context.stack.push(EVMu256.zero());
            }
            context.pc += 1;
        },

        Opcode.LT => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            // EVM仕様: LT はスタックの先頭から a, 次に b を取り出し、a < b なら1
            const a = try context.stack.pop(); // top-of-stack
            const b = try context.stack.pop(); // next

            std.log.info("LT: Comparing a < b", .{});
            std.log.info("LT: a = hi: 0x{x:0>32}, lo: 0x{x:0>32} (decimal: {d})", .{ a.hi, a.lo, a.lo });
            std.log.info("LT: b = hi: 0x{x:0>32}, lo: 0x{x:0>32} (decimal: {d})", .{ b.hi, b.lo, b.lo });

            var result: u64 = 0;
            if (a.hi < b.hi) {
                result = 1;
            } else if (a.hi == b.hi and a.lo < b.lo) {
                result = 1;
            }

            std.log.info("LT: Final result = {d}", .{result});
            try context.stack.push(EVMu256.fromU64(result));
            context.pc += 1;
        },

        Opcode.GT => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            // EVM仕様: GT は a > b なら1
            const a = try context.stack.pop();
            const b = try context.stack.pop();

            var result: u64 = 0;
            if (a.hi > b.hi) {
                result = 1;
            } else if (a.hi == b.hi and a.lo > b.lo) {
                result = 1;
            }

            try context.stack.push(EVMu256.fromU64(result));
            context.pc += 1;
        },

        Opcode.SLT => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const a = try context.stack.pop();
            const b = try context.stack.pop();

            // 簡易実装: 符号は考慮せず a < b を無符号比較で近似
            var result: u64 = 0;
            if (a.hi < b.hi) {
                result = 1;
            } else if (a.hi == b.hi and a.lo < b.lo) {
                result = 1;
            }

            try context.stack.push(EVMu256.fromU64(result));
            context.pc += 1;
        },

        Opcode.ISZERO => {
            if (context.stack.depth() < 1) return EVMError.StackUnderflow;
            const x = try context.stack.pop();

            // ゼロ判定: 値が0なら1、それ以外は0
            if (x.hi == 0 and x.lo == 0) {
                try context.stack.push(EVMu256.fromU64(1));
            } else {
                try context.stack.push(EVMu256.zero());
            }
            context.pc += 1;
        },

        Opcode.JUMPDEST => {
            // ジャンプ先マーカー: 何もせず次の命令へ
            context.pc += 1;
        },

        Opcode.SHL => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            // EVM仕様: スタック順序は [shift, value]
            const shift = try context.stack.pop();
            const value = try context.stack.pop();

            // シフト量が256以上の場合は結果は0
            if (shift.hi > 0 or shift.lo >= 256) {
                try context.stack.push(EVMu256.zero());
            } else {
                const shift_amount = @as(u8, @intCast(shift.lo));

                // 単純化した論理左シフトの実装
                if (shift_amount == 0) {
                    // シフトなし - 元の値を返す
                    try context.stack.push(value);
                } else if (shift_amount < 64) {
                    // 64ビット未満のシフト
                    const result = EVMu256{
                        .hi = (value.hi << @intCast(shift_amount)) | (value.lo >> @intCast(64 - shift_amount)),
                        .lo = value.lo << @intCast(shift_amount),
                    };
                    try context.stack.push(result);
                } else if (shift_amount < 128) {
                    // 64-127ビットのシフト - loの値がhiに移動
                    const result = EVMu256{
                        .hi = value.lo << @intCast(shift_amount - 64),
                        .lo = 0,
                    };
                    try context.stack.push(result);
                } else if (shift_amount < 256) {
                    // 128-255ビットのシフト - すべて0
                    try context.stack.push(EVMu256.zero());
                } else {
                    // 256ビット以上のシフト - すべて0
                    try context.stack.push(EVMu256.zero());
                }
            }
            context.pc += 1;
        },

        Opcode.SHR => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            // EVM仕様: スタック順序は [shift, value]
            const shift = try context.stack.pop();
            const value = try context.stack.pop();

            // 関数セレクター抽出の場合（224ビットシフト）をログ出力
            if (shift.lo == 224) {
                std.log.info("SHR: Function selector extraction detected (224-bit shift)", .{});
                std.log.info("SHR: Input value - hi: 0x{x:0>32}, lo: 0x{x:0>32}", .{ value.hi, value.lo });
            }

            // シフト量が256以上の場合は結果は0
            if (shift.hi > 0 or shift.lo >= 256) {
                try context.stack.push(EVMu256.zero());
            } else {
                const shift_amount = @as(u8, @intCast(shift.lo));
                var result = EVMu256{ .hi = value.hi, .lo = value.lo };

                // 論理右シフト実装
                if (shift_amount == 0) {
                    // シフト量が0の場合は値をそのまま返す
                } else if (shift_amount < 64) {
                    // 64ビット未満のシフト - シフト量を適切な型に変換
                    const shift_u7 = @as(u7, @intCast(shift_amount)); // u7 can represent 0-127
                    const complement_u6 = @as(u6, @intCast(64 - shift_amount)); // u6 can represent 0-63
                    result.lo = (value.lo >> shift_u7) | (value.hi << complement_u6);
                    result.hi = value.hi >> shift_u7;
                } else if (shift_amount < 128) {
                    // 64-127ビットのシフト
                    const adjusted_shift = @as(u7, @intCast(shift_amount - 64));
                    result.lo = value.hi >> adjusted_shift;
                    result.hi = 0;
                } else if (shift_amount < 256) {
                    // 128-255ビットのシフト: value.hiの一部をresult.loに移す
                    const high_shift = @as(u7, @intCast(shift_amount - 128));
                    result.lo = value.hi >> high_shift;
                    result.hi = 0;
                } else {
                    // 256ビット以上のシフト（全ビット消える）
                    result.lo = 0;
                    result.hi = 0;
                }

                // 関数セレクター抽出の場合の結果をログ出力
                if (shift.lo == 224) {
                    std.log.info("SHR: Result after 224-bit shift - hi: 0x{x:0>32}, lo: 0x{x:0>32}", .{ result.hi, result.lo });
                    if (result.lo <= 0xFFFFFFFF) {
                        std.log.info("SHR: Extracted function selector: 0x{x:0>8}", .{@as(u32, @intCast(result.lo))});
                    }
                }

                try context.stack.push(result);
            }
            context.pc += 1;
        },

        Opcode.SAR => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            // EVM仕様: スタック順序は [shift, value]
            const shift = try context.stack.pop();
            const value = try context.stack.pop();

            // シフト量が256以上の場合の処理
            if (shift.hi > 0 or shift.lo >= 256) {
                // 最上位ビットが1（負数）の場合、すべてのビットが1になる（算術シフトの特性）
                if (value.hi & (1 << 127) != 0) {
                    try context.stack.push(EVMu256{ .hi = std.math.maxInt(u128), .lo = std.math.maxInt(u128) });
                } else {
                    try context.stack.push(EVMu256.zero());
                }
            } else {
                const shift_amount = @as(u8, @intCast(shift.lo));
                var result = EVMu256{ .hi = value.hi, .lo = value.lo };

                // 最上位ビットを記録（符号ビット）
                const sign_bit = (value.hi & (1 << 127)) != 0;

                // 算術右シフト実装
                if (shift_amount == 0) {
                    // シフト量が0の場合は値をそのまま返す
                } else if (shift_amount < 64) {
                    // 64ビット未満のシフト
                    const shift_u7 = @as(u7, @intCast(shift_amount));
                    const complement_u6 = @as(u6, @intCast(64 - shift_amount));
                    result.lo = (value.lo >> shift_u7) | (value.hi << complement_u6);

                    // 符号拡張：符号が負の場合、上位ビットを1で埋める
                    if (sign_bit) {
                        // 最上位部分を右シフトし、最上位ビットを1で埋める
                        const mask = ~@as(u128, 0) << @as(u7, @intCast(127 - shift_amount));
                        result.hi = (value.hi >> shift_u7) | mask;
                    } else {
                        // 通常の論理右シフト
                        result.hi = value.hi >> shift_u7;
                    }
                } else if (shift_amount < 128) {
                    // 64-127ビットのシフト
                    const adjusted_shift = @as(u7, @intCast(shift_amount - 64));
                    result.lo = value.hi >> adjusted_shift;

                    // 符号拡張：負数の場合はすべてのビットを1に
                    if (sign_bit) {
                        result.hi = std.math.maxInt(u128);
                    } else {
                        result.hi = 0;
                    }
                } else {
                    // 128ビット以上のシフト
                    // 符号拡張：負数の場合はすべてのビットを1に
                    if (sign_bit) {
                        result.lo = std.math.maxInt(u128);
                        result.hi = std.math.maxInt(u128);
                    } else {
                        result.lo = 0;
                        result.hi = 0;
                    }
                }

                try context.stack.push(result);
            }
            context.pc += 1;
        },

        Opcode.JUMP => {
            if (context.stack.depth() < 1) return EVMError.StackUnderflow;
            const dest = try context.stack.pop();

            // ジャンプ先は現在u64範囲のみサポート
            if (dest.hi != 0) return EVMError.InvalidJump;

            const jump_dest = @as(usize, @intCast(dest.lo));

            // ジャンプ先が有効なJUMPDESTかチェック
            if (jump_dest >= context.code.len) return EVMError.InvalidJump;
            if (context.code[jump_dest] != Opcode.JUMPDEST) return EVMError.InvalidJump;

            context.pc = jump_dest;
        },

        Opcode.JUMPI => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            // EVM仕様: スタック順序は [destination, condition]
            const dest = try context.stack.pop();
            const condition = try context.stack.pop();

            std.log.info("JUMPI: PC={d}, destination=0x{x}, condition=0x{x} (hi=0x{x}, lo=0x{x})", .{ context.pc, dest.lo, condition.lo, condition.hi, condition.lo });

            // 条件付きジャンプ: 条件が0でない場合にジャンプ
            if (condition.hi != 0 or condition.lo != 0) {
                std.log.info("JUMPI: Condition is TRUE, jumping to 0x{x}", .{dest.lo});
                // ジャンプ先は現在u64範囲のみサポート
                if (dest.hi != 0) return EVMError.InvalidJump;

                const jump_dest = @as(usize, @intCast(dest.lo));

                // ジャンプ先が有効なJUMPDESTかチェック
                if (jump_dest >= context.code.len) return EVMError.InvalidJump;
                if (context.code[jump_dest] != Opcode.JUMPDEST) return EVMError.InvalidJump;

                context.pc = jump_dest;
            } else {
                std.log.info("JUMPI: Condition is FALSE, continuing to next instruction (PC={})", .{context.pc + 1});
                // 条件が0の場合は次の命令へ
                context.pc += 1;
            }
        },

        Opcode.CODESIZE => {
            // 現在の実行バイトコードのサイズをスタックにプッシュ
            try context.stack.push(EVMu256.fromU64(context.code.len));
            context.pc += 1;
        },

        // CALLDATACOPY(dst_offset, data_offset, length)
        // メモリにcalldataの一部をコピーする
        Opcode.CALLDATACOPY => {
            if (context.stack.depth() < 3) return EVMError.StackUnderflow;

            // スタックの順序に注意: まずメモリオフセット、次にデータオフセット、最後に長さ
            const mem_offset = try context.stack.pop();
            const data_offset = try context.stack.pop();
            const length = try context.stack.pop();

            // 現在はu64範囲のみサポート
            if (mem_offset.hi != 0 or data_offset.hi != 0 or length.hi != 0) return EVMError.MemoryOutOfBounds;

            const mem_off = @as(usize, @intCast(mem_offset.lo));
            const data_off = @as(usize, @intCast(data_offset.lo));
            const len = @as(usize, @intCast(length.lo));

            // メモリサイズを確保
            try context.memory.ensureSize(mem_off + len);

            // calldata からメモリへコピー（範囲外は0で埋める）
            for (0..len) |i| {
                if (data_off + i < context.calldata.len) {
                    context.memory.data.items[mem_off + i] = context.calldata[data_off + i];
                } else {
                    context.memory.data.items[mem_off + i] = 0;
                }
            }

            context.pc += 1;
        },

        Opcode.CODECOPY => {
            if (context.stack.depth() < 3) return EVMError.StackUnderflow;
            const mem_offset = try context.stack.pop();
            const code_offset = try context.stack.pop();
            const length = try context.stack.pop();

            // 現在はu64範囲のみサポート
            if (mem_offset.hi != 0 or code_offset.hi != 0 or length.hi != 0) return EVMError.MemoryOutOfBounds;

            const mem_off = @as(usize, @intCast(mem_offset.lo));
            const code_off = @as(usize, @intCast(code_offset.lo));
            const len = @as(usize, @intCast(length.lo));

            // メモリサイズ確保
            try context.memory.ensureSize(mem_off + len);

            // コードをメモリにコピー
            for (0..len) |i| {
                if (code_off + i < context.code.len) {
                    context.memory.data.items[mem_off + i] = context.code[code_off + i];
                } else {
                    // コード範囲外は0埋め
                    context.memory.data.items[mem_off + i] = 0;
                }
            }

            context.pc += 1;
        },

        Opcode.REVERT => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const offset = try context.stack.pop();
            const length = try context.stack.pop();

            // REVERT時の詳細情報をログ出力
            std.log.err("REVERT executed at PC={d}", .{context.pc});
            std.log.err("REVERT parameters - offset: {d}, length: {d}", .{ offset.lo, length.lo });

            // スタックの内容を表示
            std.log.err("Stack depth at REVERT: {d}", .{context.stack.depth()});
            if (context.stack.depth() > 0) {
                std.log.err("Stack contents (last 5 entries):", .{});
                const start_idx = if (context.stack.depth() >= 5) context.stack.depth() - 5 else 0;
                for (start_idx..context.stack.depth()) |i| {
                    const value = context.stack.data[context.stack.sp - 1 - (context.stack.depth() - 1 - i)];
                    std.log.err("  [{}]: hi=0x{x:0>32}, lo=0x{x:0>32}", .{ i, value.hi, value.lo });
                }
            }

            // 周辺コードの逆アセンブル
            const start_pc = if (context.pc >= 10) context.pc - 10 else 0;
            const end_pc = if (context.pc + 10 < context.code.len) context.pc + 10 else context.code.len;
            std.log.err("Code context around PC={d}:", .{context.pc});
            for (start_pc..end_pc) |pc| {
                const opcode_val = context.code[pc];
                if (pc == context.pc) {
                    std.log.err("  PC={d}: [0x{x:0>2}] <-- REVERT HERE", .{ pc, opcode_val });
                } else {
                    std.log.err("  PC={d}: 0x{x:0>2}", .{ pc, opcode_val });
                }
            }

            // 現在はu64範囲のみサポート
            if (offset.hi != 0 or length.hi != 0) return EVMError.MemoryOutOfBounds;

            const off = @as(usize, @intCast(offset.lo));
            const len = @as(usize, @intCast(length.lo));

            // メモリからリバートデータを取得
            try context.memory.ensureSize(off + len);
            if (len > 0) {
                try context.returndata.resize(len);
                for (0..len) |i| {
                    if (off + i < context.memory.data.items.len) {
                        context.returndata.items[i] = context.memory.data.items[off + i];
                    } else {
                        context.returndata.items[i] = 0;
                    }
                }

                // リバートデータも表示
                std.log.err("REVERT data ({d} bytes): {any}", .{ len, context.returndata.items });
            } else {
                std.log.err("REVERT with no data", .{});
            }

            context.stopped = true;
            return EVMError.Revert;
        },

        Opcode.CALLDATASIZE => {
            // 呼び出しデータのサイズをスタックにプッシュ
            std.log.info("CALLDATASIZE: calldata.len={d}, actual_bytes: {any}", .{ context.calldata.len, context.calldata });
            const size_value = EVMu256.fromU64(context.calldata.len);
            std.log.info("CALLDATASIZE: Pushing size value - hi: 0x{x:0>32}, lo: 0x{x:0>32}", .{ size_value.hi, size_value.lo });
            try context.stack.push(size_value);
            context.pc += 1;
        },

        Opcode.CALLVALUE => {
            // 簡易実装: 常に0を返す
            try context.stack.push(EVMu256.zero());
            context.pc += 1;
        },

        Opcode.PUSH0 => {
            // PUSH0: スタックに0をプッシュ (EIP-3855で追加)
            try context.stack.push(EVMu256.zero());
            context.pc += 1;
        },

        Opcode.AND => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const a = try context.stack.pop();
            const b = try context.stack.pop();

            // ビット単位のAND演算
            const result = EVMu256{
                .hi = a.hi & b.hi,
                .lo = a.lo & b.lo,
            };

            try context.stack.push(result);
            context.pc += 1;
        },

        Opcode.OR => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const a = try context.stack.pop();
            const b = try context.stack.pop();

            // ビット単位のOR演算
            const result = EVMu256{
                .hi = a.hi | b.hi,
                .lo = a.lo | b.lo,
            };

            try context.stack.push(result);
            context.pc += 1;
        },

        Opcode.XOR => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const a = try context.stack.pop();
            const b = try context.stack.pop();

            // ビット単位のXOR演算
            const result = EVMu256{
                .hi = a.hi ^ b.hi,
                .lo = a.lo ^ b.lo,
            };

            try context.stack.push(result);
            context.pc += 1;
        },

        Opcode.NOT => {
            if (context.stack.depth() < 1) return EVMError.StackUnderflow;
            const a = try context.stack.pop();

            // ビット単位のNOT演算
            const result = EVMu256{
                .hi = ~a.hi,
                .lo = ~a.lo,
            };

            try context.stack.push(result);
            context.pc += 1;
        },

        else => {
            // DUP1-DUP16 (0x80-0x8F)の実装
            if (opcode >= 0x80 and opcode <= 0x8F) {
                const dup_index = opcode - 0x7F; // DUP1=1, DUP2=2, ...
                if (context.stack.depth() < dup_index) return EVMError.StackUnderflow;

                // stack[sp - dup_index]をコピー
                const value = context.stack.data[context.stack.sp - dup_index];
                try context.stack.push(value);
                context.pc += 1;
            }
            // SWAP1-SWAP16 (0x90-0x9F)の実装
            else if (opcode >= 0x90 and opcode <= 0x9F) {
                const swap_index = opcode - 0x8F; // SWAP1=1, SWAP2=2, ...
                if (context.stack.depth() < swap_index + 1) return EVMError.StackUnderflow;

                // stack[sp-1]とstack[sp-1-swap_index]を交換
                const temp = context.stack.data[context.stack.sp - 1];
                context.stack.data[context.stack.sp - 1] = context.stack.data[context.stack.sp - 1 - swap_index];
                context.stack.data[context.stack.sp - 1 - swap_index] = temp;
                context.pc += 1;
            }
            // PUSH0-PUSH32 (0x5F-0x7F)の実装
            else if (opcode >= 0x5F and opcode <= 0x7F) {
                const push_bytes = opcode - 0x5F; // PUSH0は0バイト、PUSH1は1バイト...

                if (push_bytes == 0) {
                    // PUSH0: スタックに0をプッシュ
                    try context.stack.push(EVMu256.zero());
                    context.pc += 1;
                } else {
                    // PUSH1-PUSH32: 指定バイト数を読み取り
                    // コード範囲チェック
                    if (context.pc + push_bytes + 1 > context.code.len) {
                        context.error_msg = "コード範囲外のPUSH操作";
                        return EVMError.InvalidOpcode;
                    }

                    // push_bytes バイトを読み取り、256ビット値に変換（ビッグエンディアン）
                    var value = EVMu256.zero();
                    for (0..push_bytes) |i| {
                        const byte = context.code[context.pc + 1 + i];
                        if (push_bytes <= 16) {
                            // 16バイト以下の場合はloに格納
                            const shift_amount = @as(u7, @intCast(8 * (push_bytes - 1 - i)));
                            value.lo |= @as(u128, byte) << shift_amount;
                        } else {
                            // 16バイト超の場合、最初の16バイトはhiに、残りはloに
                            if (i < (push_bytes - 16)) {
                                const shift_amount = @as(u7, @intCast(8 * (push_bytes - 17 - i)));
                                value.hi |= @as(u128, byte) << shift_amount;
                            } else {
                                const shift_amount = @as(u7, @intCast(8 * (push_bytes - 1 - i)));
                                value.lo |= @as(u128, byte) << shift_amount;
                            }
                        }
                    }

                    try context.stack.push(value);
                    context.pc += push_bytes + 1; // オペコード + push_bytesバイトをスキップ
                }
            } else {
                // 詳細なエラーログ出力
                const opcodeHex = std.fmt.allocPrint(std.heap.page_allocator, "0x{x:0>2}", .{opcode}) catch "Unknown";

                // オペコードの説明を取得
                const opcodeDescription = switch (opcode) {
                    0x0F => "古いオペコード(removed)",
                    0x1E, 0x1F => "未使用のオペコード(unused)",
                    0x21 => "おそらくLOG0~LOG4(0xA0~0xA4)",
                    0x5C...0x5E => "PUSHX,DUP,SWAP周辺のオペコード",
                    0xA5...0xEF => "未使用の範囲(0xA5-0xEF)",
                    0xF6...0xF9 => "システムオペコード周辺の未割り当て",
                    0xFB...0xFC => "STATICCALL/REVERT周辺の未割り当て",
                    0xFE => "INVALID/ABORT専用オペコード",
                    else => "未知のオペコード",
                };

                const errorMsg = std.fmt.allocPrint(std.heap.page_allocator, "未実装または無効なオペコード: {s} (PC: {d}, 説明: {s})", .{ opcodeHex, context.pc, opcodeDescription }) catch "Unknown opcode error";

                std.log.err("EVMエラー: {s}", .{errorMsg});

                // コード周辺のコンテキストを表示（デバッグに役立つ）
                const startIdx = if (context.pc > 10) context.pc - 10 else 0;
                const endIdx = if (context.pc + 10 < context.code.len) context.pc + 10 else context.code.len;

                var hexDump = std.ArrayList(u8).init(std.heap.page_allocator);
                defer hexDump.deinit();

                for (startIdx..endIdx) |i| {
                    if (i == context.pc) {
                        // 問題のオペコードをマークする
                        _ = hexDump.writer().print("[0x{x:0>2}] ", .{context.code[i]}) catch {};
                    } else {
                        _ = hexDump.writer().print("0x{x:0>2} ", .{context.code[i]}) catch {};
                    }
                }

                std.log.err("コードコンテキスト: {s}", .{hexDump.items});

                // エラーメッセージに実行中のコントラクトのサイズも追加する
                const sizeInfo = std.fmt.allocPrint(std.heap.page_allocator, "{s} (コード長: {d}バイト)", .{ errorMsg, context.code.len }) catch errorMsg;
                context.error_msg = sizeInfo;
                return EVMError.InvalidOpcode;
            }
        },
    }
}

/// EVMバイトコードの逆アセンブル（デバッグ用）
pub fn disassemble(code: []const u8, writer: anytype) !void {
    var pc: usize = 0;
    while (pc < code.len) {
        const opcode = code[pc];
        try writer.print("0x{x:0>4}: ", .{pc});

        switch (opcode) {
            Opcode.STOP => try writer.print("STOP", .{}),
            Opcode.ADD => try writer.print("ADD", .{}),
            Opcode.MUL => try writer.print("MUL", .{}),
            Opcode.SUB => try writer.print("SUB", .{}),
            Opcode.DIV => try writer.print("DIV", .{}),
            Opcode.SHL => try writer.print("SHL", .{}),
            Opcode.SHR => try writer.print("SHR", .{}),
            Opcode.SAR => try writer.print("SAR", .{}),
            Opcode.POP => try writer.print("POP", .{}),
            Opcode.MLOAD => try writer.print("MLOAD", .{}),
            Opcode.CODESIZE => try writer.print("CODESIZE", .{}),
            Opcode.CODECOPY => try writer.print("CODECOPY", .{}),
            Opcode.MSTORE => try writer.print("MSTORE", .{}),
            Opcode.SLOAD => try writer.print("SLOAD", .{}),
            Opcode.SSTORE => try writer.print("SSTORE", .{}),
            Opcode.JUMP => try writer.print("JUMP", .{}),
            Opcode.JUMPI => try writer.print("JUMPI", .{}),
            Opcode.JUMPDEST => try writer.print("JUMPDEST", .{}),
            Opcode.RETURN => try writer.print("RETURN", .{}),
            Opcode.REVERT => try writer.print("REVERT", .{}),
            Opcode.INVALID => try writer.print("INVALID", .{}),

            // Comparison operations
            Opcode.LT => try writer.print("LT", .{}),
            Opcode.GT => try writer.print("GT", .{}),
            Opcode.SLT => try writer.print("SLT", .{}),
            Opcode.EQ => try writer.print("EQ", .{}),
            Opcode.ISZERO => try writer.print("ISZERO", .{}),

            // Missing opcodes that were showing as UNKNOWN
            Opcode.MOD => try writer.print("MOD", .{}),
            Opcode.CALLDATACOPY => try writer.print("CALLDATACOPY", .{}),

            Opcode.PUSH0 => try writer.print("PUSH0", .{}),
            Opcode.PUSH1 => {
                if (pc + 1 < code.len) {
                    const value = code[pc + 1];
                    try writer.print("PUSH1 0x{x:0>2}", .{value});
                    pc += 1;
                } else {
                    try writer.print("PUSH1 <データ不足>", .{});
                }
            },

            Opcode.DUP1 => try writer.print("DUP1", .{}),
            Opcode.SWAP1 => try writer.print("SWAP1", .{}),
            Opcode.CALLDATALOAD => try writer.print("CALLDATALOAD", .{}),
            Opcode.CALLDATASIZE => try writer.print("CALLDATASIZE", .{}),
            Opcode.CALLVALUE => try writer.print("CALLVALUE", .{}),
            Opcode.AND => try writer.print("AND", .{}),
            Opcode.OR => try writer.print("OR", .{}),
            Opcode.XOR => try writer.print("XOR", .{}),
            Opcode.NOT => try writer.print("NOT", .{}),

            else => {
                if (opcode >= 0x60 and opcode <= 0x7F) {
                    // PUSH1-PUSH32
                    const push_bytes = opcode - 0x5F;
                    if (pc + push_bytes < code.len) {
                        try writer.print("PUSH{d} 0x", .{push_bytes});
                        for (0..push_bytes) |i| {
                            try writer.print("{x:0>2}", .{code[pc + 1 + i]});
                        }
                        pc += push_bytes;
                    } else {
                        try writer.print("PUSH{d} <データ不足>", .{push_bytes});
                        pc = code.len;
                    }
                } else if (opcode >= 0x80 and opcode <= 0x8F) {
                    // DUP1-DUP16
                    try writer.print("DUP{d}", .{opcode - 0x7F});
                } else if (opcode >= 0x90 and opcode <= 0x9F) {
                    // SWAP1-SWAP16
                    try writer.print("SWAP{d}", .{opcode - 0x8F});
                } else {
                    // その他の未実装オペコード
                    try writer.print("UNKNOWN 0x{x:0>2}", .{opcode});
                }
            },
        }

        try writer.print("\n", .{});
        pc += 1;
    }
}

// シンプルなEVM実行テスト
test "Simple EVM execution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // シンプルなバイトコード: PUSH1 0x05, PUSH1 0x03, ADD, PUSH1 0x00, MSTORE, PUSH1 0x20, PUSH1 0x00, RETURN
    // 意味: 5 + 3 = 8 を計算し、メモリに格納して返す
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

    const calldata = [_]u8{};

    // EVMを実行し、戻り値を取得
    const result = try execute(allocator, &bytecode, &calldata, 100000);
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

    // 結果が8（5+3）になっていることを確認
    try std.testing.expect(value.hi == 0);
    try std.testing.expect(value.lo == 8);
}

// 乗算のテスト
test "EVM multiplication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // バイトコード: PUSH1 0x07, PUSH1 0x06, MUL, PUSH1 0x00, MSTORE, PUSH1 0x20, PUSH1 0x00, RETURN
    // 意味: 7 * 6 = 42 を計算し、メモリに格納して返す
    const bytecode = [_]u8{
        0x60, 0x07, // PUSH1 7
        0x60, 0x06, // PUSH1 6
        0x02, // MUL
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const calldata = [_]u8{};
    const result = try execute(allocator, &bytecode, &calldata, 100000);
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

    // 結果が42（7*6）になっていることを確認
    try std.testing.expect(value.hi == 0);
    try std.testing.expect(value.lo == 42);
}

// ストレージ操作のテスト
test "EVM storage operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // バイトコード:
    // PUSH1 0x2A, PUSH1 0x01, SSTORE, // キー1に42を保存
    // PUSH1 0x01, SLOAD,               // キー1の値をロード
    // PUSH1 0x00, MSTORE,              // メモリに保存
    // PUSH1 0x20, PUSH1 0x00, RETURN   // 戻り値を返す
    const bytecode = [_]u8{
        0x60, 0x2A, // PUSH1 42
        0x60, 0x01, // PUSH1 1
        0x55, // SSTORE
        0x60, 0x01, // PUSH1 1
        0x54, // SLOAD
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const calldata = [_]u8{};
    const result = try execute(allocator, &bytecode, &calldata, 100000);
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

    // 結果が42になっていることを確認
    try std.testing.expect(value.hi == 0);
    try std.testing.expect(value.lo == 42);
}

// 複数のオペコード実行テスト
test "EVM multiple operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // バイトコード:
    // PUSH1 0x0A, PUSH1 0x0B, ADD,    // 10 + 11 = 21
    // PUSH1 0x03, MUL,                // 21 * 3 = 63
    // PUSH1 0x02, SWAP1, DIV,         // 63 / 2 = 31 (スワップしてスタックを調整)
    // PUSH1 0x00, MSTORE,             // 結果をメモリに保存
    // PUSH1 0x20, PUSH1 0x00, RETURN  // 戻り値を返す
    const bytecode = [_]u8{
        0x60, 0x0A, // PUSH1 10
        0x60, 0x0B, // PUSH1 11
        0x01, // ADD
        0x60, 0x03, // PUSH1 3
        0x02, // MUL
        0x60, 0x02, // PUSH1 2
        0x90, // SWAP1
        0x04, // DIV
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const calldata = [_]u8{};
    const result = try execute(allocator, &bytecode, &calldata, 100000);
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

    // 結果が31（(10+11)*3/2）になっていることを確認
    try std.testing.expect(value.hi == 0);
    try std.testing.expect(value.lo == 31);
}

// SHR（論理右シフト）のテスト
test "EVM SHR operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // バイトコード:
    // PUSH1 0x10, PUSH1 0x02, SHR,    // 0x10 >> 2 = 0x04 （SHRは pop順序: shift, value）
    // PUSH1 0x00, MSTORE,             // 結果をメモリに保存
    // PUSH1 0x20, PUSH1 0x00, RETURN  // 戻り値を返す
    const bytecode = [_]u8{
        0x60, 0x10, // PUSH1 16 (0x10)
        0x60, 0x02, // PUSH1 2
        0x1C, // SHR
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const calldata = [_]u8{};
    const result = try execute(allocator, &bytecode, &calldata, 100000);
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

    // 結果が4（16 >> 2）になっていることを確認
    try std.testing.expect(value.hi == 0);
    try std.testing.expect(value.lo == 4);
}

// 比較演算（LT, EQ, ISZERO）のテスト
test "EVM comparison operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // バイトコード:
    // PUSH1 0x14, PUSH1 0x0A, LT,     // 10 < 20 = 1（LTは a<b なので a=10 を最後に積む）
    // PUSH1 0x00, MSTORE,             // 結果をメモリに保存
    // PUSH1 0x20, PUSH1 0x00, RETURN  // 戻り値を返す
    const bytecode_lt = [_]u8{
        0x60, 0x14, // PUSH1 20
        0x60, 0x0A, // PUSH1 10
        0x10, // LT
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    // LTテスト
    const result_lt = try execute(allocator, &bytecode_lt, &[_]u8{}, 100000);
    defer allocator.free(result_lt);

    var value_lt = EVMu256{ .hi = 0, .lo = 0 };
    if (result_lt.len >= 32) {
        for (0..16) |i| {
            const byte_val = result_lt[i];
            value_lt.hi |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
        for (0..16) |i| {
            const byte_val = result_lt[i + 16];
            value_lt.lo |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
    }

    // 結果が1（10 < 20は真）になっていることを確認
    try std.testing.expect(value_lt.hi == 0);
    try std.testing.expect(value_lt.lo == 1);

    // バイトコード:
    // PUSH1 0x0A, PUSH1 0x0A, EQ,     // 10 == 10 = 1
    // PUSH1 0x00, MSTORE,             // 結果をメモリに保存
    // PUSH1 0x20, PUSH1 0x00, RETURN  // 戻り値を返す
    const bytecode_eq = [_]u8{
        0x60, 0x0A, // PUSH1 10
        0x60, 0x0A, // PUSH1 10
        0x14, // EQ
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    // EQテスト
    const result_eq = try execute(allocator, &bytecode_eq, &[_]u8{}, 100000);
    defer allocator.free(result_eq);

    var value_eq = EVMu256{ .hi = 0, .lo = 0 };
    if (result_eq.len >= 32) {
        for (0..16) |i| {
            const byte_val = result_eq[i];
            value_eq.hi |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
        for (0..16) |i| {
            const byte_val = result_eq[i + 16];
            value_eq.lo |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
    }

    // 結果が1（10 == 10は真）になっていることを確認
    try std.testing.expect(value_eq.hi == 0);
    try std.testing.expect(value_eq.lo == 1);

    // バイトコード:
    // PUSH1 0x00, ISZERO,             // 0 == 0 ? 1 : 0 = 1
    // PUSH1 0x00, MSTORE,             // 結果をメモリに保存
    // PUSH1 0x20, PUSH1 0x00, RETURN  // 戻り値を返す
    const bytecode_iszero = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x15, // ISZERO
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    // ISZEROテスト
    const result_iszero = try execute(allocator, &bytecode_iszero, &[_]u8{}, 100000);
    defer allocator.free(result_iszero);

    var value_iszero = EVMu256{ .hi = 0, .lo = 0 };
    if (result_iszero.len >= 32) {
        for (0..16) |i| {
            const byte_val = result_iszero[i];
            value_iszero.hi |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
        for (0..16) |i| {
            const byte_val = result_iszero[i + 16];
            value_iszero.lo |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
    }

    // 結果が1（0はゼロ）になっていることを確認
    try std.testing.expect(value_iszero.hi == 0);
    try std.testing.expect(value_iszero.lo == 1);
}

// ジャンプ命令（JUMPI, JUMPDEST）のテスト
test "EVM jump operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // バイトコード:
    // PUSH1 0x01, PUSH1 0x0F, JUMPI,  // 条件が真なので0x0Fにジャンプ
    // PUSH1 0x2A,                     // 42をプッシュ（スキップされる）
    // PUSH1 0x00, MSTORE,             // メモリに保存（スキップされる）
    // PUSH1 0x20, PUSH1 0x00, RETURN, // 戻り値を返す（スキップされる）
    // JUMPDEST,                       // ジャンプ先（0x0A）
    // PUSH1 0x37,                     // 55をプッシュ
    // PUSH1 0x00, MSTORE,             // メモリに保存
    // PUSH1 0x20, PUSH1 0x00, RETURN  // 戻り値を返す
    const bytecode_jumpi_true = [_]u8{
        0x60, 0x01, // PUSH1 1（条件）
        0x60, 0x0F, // PUSH1 15（ジャンプ先）
        0x57, // JUMPI
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

    // 条件が真の場合のJUMPIテスト
    const result_jumpi_true = try execute(allocator, &bytecode_jumpi_true, &[_]u8{}, 100000);
    defer allocator.free(result_jumpi_true);

    var value_jumpi_true = EVMu256{ .hi = 0, .lo = 0 };
    if (result_jumpi_true.len >= 32) {
        for (0..16) |i| {
            const byte_val = result_jumpi_true[i];
            value_jumpi_true.hi |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
        for (0..16) |i| {
            const byte_val = result_jumpi_true[i + 16];
            value_jumpi_true.lo |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
    }

    // 結果が55（ジャンプ先の値）になっていることを確認
    try std.testing.expect(value_jumpi_true.hi == 0);
    try std.testing.expect(value_jumpi_true.lo == 55);

    // バイトコード:
    // PUSH1 0x00, PUSH1 0x0A, JUMPI,  // 条件が偽なのでジャンプしない
    // PUSH1 0x2A,                     // 42をプッシュ
    // PUSH1 0x00, MSTORE,             // メモリに保存
    // PUSH1 0x20, PUSH1 0x00, RETURN, // 戻り値を返す
    // JUMPDEST,                       // ジャンプ先（実行されない）
    // PUSH1 0x37,                     // 55をプッシュ（実行されない）
    // PUSH1 0x00, MSTORE,             // メモリに保存（実行されない）
    // PUSH1 0x20, PUSH1 0x00, RETURN  // 戻り値を返す（実行されない）
    const bytecode_jumpi_false = [_]u8{
        0x60, 0x00, // PUSH1 0（条件）
        0x60, 0x0A, // PUSH1 10（ジャンプ先）
        0x57, // JUMPI
        0x60, 0x2A, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
        0x5B, // JUMPDEST（ジャンプ先、実行されない）
        0x60, 0x37, // PUSH1 55（実行されない）
        0x60, 0x00, // PUSH1 0（実行されない）
        0x52, // MSTORE（実行されない）
        0x60, 0x20, // PUSH1 32（実行されない）
        0x60, 0x00, // PUSH1 0（実行されない）
        0xf3, // RETURN（実行されない）
    };

    // 条件が偽の場合のJUMPIテスト
    const result_jumpi_false = try execute(allocator, &bytecode_jumpi_false, &[_]u8{}, 100000);
    defer allocator.free(result_jumpi_false);

    var value_jumpi_false = EVMu256{ .hi = 0, .lo = 0 };
    if (result_jumpi_false.len >= 32) {
        for (0..16) |i| {
            const byte_val = result_jumpi_false[i];
            value_jumpi_false.hi |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
        for (0..16) |i| {
            const byte_val = result_jumpi_false[i + 16];
            value_jumpi_false.lo |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
    }

    // 結果が42（ジャンプしなかった場合の値）になっていることを確認
    try std.testing.expect(value_jumpi_false.hi == 0);
    try std.testing.expect(value_jumpi_false.lo == 42);
}

// PUSH2-PUSH32のテスト
test "EVM PUSH2-PUSH32 operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // バイトコード:
    // PUSH2 0x1234,                   // 0x1234をプッシュ
    // PUSH1 0x00, MSTORE,             // メモリに保存
    // PUSH1 0x20, PUSH1 0x00, RETURN  // 戻り値を返す
    const bytecode_push2 = [_]u8{
        0x61, 0x12, 0x34, // PUSH2 0x1234
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    // PUSH2テスト
    const result_push2 = try execute(allocator, &bytecode_push2, &[_]u8{}, 100000);
    defer allocator.free(result_push2);

    var value_push2 = EVMu256{ .hi = 0, .lo = 0 };
    if (result_push2.len >= 32) {
        for (0..16) |i| {
            const byte_val = result_push2[i];
            value_push2.hi |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
        for (0..16) |i| {
            const byte_val = result_push2[i + 16];
            value_push2.lo |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
    }

    // 結果が0x1234になっていることを確認
    try std.testing.expect(value_push2.hi == 0);
    try std.testing.expect(value_push2.lo == 0x1234);

    // バイトコード:
    // PUSH4 0x12345678,               // 0x12345678をプッシュ
    // PUSH1 0x00, MSTORE,             // メモリに保存
    // PUSH1 0x20, PUSH1 0x00, RETURN  // 戻り値を返す
    const bytecode_push4 = [_]u8{
        0x63, 0x12, 0x34, 0x56, 0x78, // PUSH4 0x12345678
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    // PUSH4テスト
    const result_push4 = try execute(allocator, &bytecode_push4, &[_]u8{}, 100000);
    defer allocator.free(result_push4);

    var value_push4 = EVMu256{ .hi = 0, .lo = 0 };
    if (result_push4.len >= 32) {
        for (0..16) |i| {
            const byte_val = result_push4[i];
            value_push4.hi |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
        for (0..16) |i| {
            const byte_val = result_push4[i + 16];
            value_push4.lo |= @as(u128, byte_val) << @as(u7, @intCast((15 - i) * 8));
        }
    }

    // 結果が0x12345678になっていることを確認
    try std.testing.expect(value_push4.hi == 0);
    try std.testing.expect(value_push4.lo == 0x12345678);
}

// CODECOPY操作のテスト
test "EVM CODECOPY operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // バイトコード:
    // PUSH1 0x04, PUSH1 0x00, PUSH1 0x00, CODECOPY, // 先頭4バイトをメモリにコピー
    // PUSH1 0x20, PUSH1 0x00, RETURN                // 戻り値を返す
    const bytecode = [_]u8{
        0x60, 0x04, // PUSH1 4（長さ）
        0x60, 0x00, // PUSH1 0（コード内オフセット）
        0x60, 0x00, // PUSH1 0（メモリオフセット）
        0x39, // CODECOPY
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const calldata = [_]u8{};
    const result = try execute(allocator, &bytecode, &calldata, 100000);
    defer allocator.free(result);

    // 返却バイト列の先頭4バイトが 60 04 60 00 になっていることを確認
    try std.testing.expect(result.len >= 4);
    try std.testing.expect(result[0] == 0x60);
    try std.testing.expect(result[1] == 0x04);
    try std.testing.expect(result[2] == 0x60);
    try std.testing.expect(result[3] == 0x00);
}

// REVERT操作のテスト
test "EVM REVERT operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // バイトコード:
    // PUSH1 0x20, PUSH1 0x00, REVERT  // リバート（32バイトのデータ）
    const bytecode = [_]u8{
        0x60, 0x20, // PUSH1 32（長さ）
        0x60, 0x00, // PUSH1 0（オフセット）
        0xFD, // REVERT
    };

    const calldata = [_]u8{};

    // REVERTはエラーを返すので、エラーを期待する
    const result = execute(allocator, &bytecode, &calldata, 100000);

    // REVERTエラーが返されることを確認
    try std.testing.expectError(EVMError.Revert, result);
}

// RETURNDATASIZEのテスト
test "EVM RETURNDATASIZE operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // バイトコード:
    // RETURNDATASIZE,                 // 戻りデータサイズを取得（簡易実装では常に0）
    // PUSH1 0x00, MSTORE,             // メモリに保存

    // PUSH1 0x20, PUSH1 0x00, RETURN  // 戻り値を返す
    const bytecode = [_]u8{
        0x3D, // RETURNDATASIZE
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const calldata = [_]u8{};
    const result = try execute(allocator, &bytecode, &calldata, 100000);
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

    // 結果が0になっていることを確認（簡易実装では常に0）
    try std.testing.expect(value.hi == 0);
    try std.testing.expect(value.lo == 0);
}

// エラー情報付き実行テスト
test "EVM execution with error info" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // バイトコード: PUSH1 0x01, JUMP (未定義のジャンプ先)
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x56, // JUMP
    };

    const calldata = [_]u8{};

    // スライスに変換
    const bytecode_slice = bytecode[0..];
    const calldata_slice = calldata[0..];

    // エラー情報付きでEVMを実行
    const result = executeWithErrorInfo(allocator, bytecode_slice, calldata_slice, 100000);

    // 実行が失敗し、エラー情報が設定されていることを確認
    try std.testing.expect(!result.success);
    try std.testing.expect(result.error_type != null);
    try std.testing.expect(result.error_type.? == EVMError.InvalidJump);
    try std.testing.expect(result.error_pc != null);
    try std.testing.expect(result.error_message != null);

    // エラーメッセージの内容を確認
    const errorMsg = try allocator.alloc(u8, result.error_message.?.len);
    @memcpy(errorMsg, result.error_message.?);
    try std.testing.expectEqualStrings("EVM実行エラー: InvalidJump at PC=2", errorMsg);

    // 後始末
    allocator.free(errorMsg);
}

// PUSH2 0x000fのエラーケースのテスト（issue #116の修正確認）
test "EVM PUSH2 with 0x000f value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // バイトコード: PUSH2 0x000f を使用したテスト（以前のバグケース）
    // PUSH2 0x000f, PUSH1 0x00, MSTORE, PUSH1 0x20, PUSH1 0x00, RETURN
    const bytecode = [_]u8{
        0x61, 0x00, 0x0f, // PUSH2 0x000f - 問題となっていたケース
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const calldata = [_]u8{};
    const result = try execute(allocator, &bytecode, &calldata, 100000);
    defer allocator.free(result);

    // 結果をEVMu256形式で解釈
    var value = EVMu256{ .hi = 0, .lo = 0 };
    if (result.len >= 32) {
        // 上位16バイトと下位16バイトを解析
        for (0..16) |i| {
            value.hi |= @as(u128, result[i]) << @as(u7, @intCast((15 - i) * 8));
            value.lo |= @as(u128, result[i + 16]) << @as(u7, @intCast((15 - i) * 8));
        }
    }

    // 結果が0x000fになっていることを確認
    try std.testing.expect(value.hi == 0);
    try std.testing.expect(value.lo == 0x000f);
}

// JUMPI命令のテスト（issue #116関連の修正確認）
test "EVM JUMPI with PUSH2 destination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // バイトコード: PUSH1 0x01, PUSH2 0x0008, JUMPI, PUSH1 0xff, JUMPDEST, PUSH1 0x42
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 0x01 (条件)
        0x61, 0x00, 0x08, // PUSH2 0x0008 (ジャンプ先 - JUMPDEST位置)
        0x57, // JUMPI (条件付きジャンプ)
        0x60, 0xff, // PUSH1 0xff (スキップされるはず)
        0x5b, // JUMPDEST (ジャンプ先) <- position 8
        0x60, 0x42, // PUSH1 0x42 (最終結果)
        0x60, 0x00, // PUSH1 0x00
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xf3, // RETURN
    };

    const calldata = [_]u8{};
    const result = try execute(allocator, &bytecode, &calldata, 100000);
    defer allocator.free(result);

    // 結果をEVMu256形式で解釈
    var value = EVMu256{ .hi = 0, .lo = 0 };
    if (result.len >= 32) {
        // 上位16バイトと下位16バイトを解析
        for (0..16) |i| {
            value.hi |= @as(u128, result[i]) << @as(u7, @intCast((15 - i) * 8));
            value.lo |= @as(u128, result[i + 16]) << @as(u7, @intCast((15 - i) * 8));
        }
    }

    // 結果が0x42になっていることを確認（JUMPIが正しく動作した場合）
    try std.testing.expect(value.hi == 0);
    try std.testing.expect(value.lo == 0x42);
}
