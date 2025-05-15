const std = @import("std");
const evm_types = @import("evm_types.zig");
const EvmContext = evm_types.EvmContext;
const Opcode = @import("evm.zig").Opcode;

/// コンテキストの現在位置付近のオペコードを逆アセンブルするヘルパー関数
pub fn disassembleContext(context: *EvmContext, writer: anytype) !void {
    // PC前後の限定された範囲のオペコードを逆アセンブル
    const startPc = if (context.pc > 10) context.pc - 10 else 0;
    const endPc = if (context.pc + 10 < context.code.len) context.pc + 10 else context.code.len;
    var pc = startPc;

    while (pc < endPc) {
        const opcode = context.code[pc];
        if (pc == context.pc) {
            try writer.print("[0x{x:0>4}]: ", .{pc}); // 現在のPCをマーク
        } else {
            try writer.print("0x{x:0>4}: ", .{pc});
        }

        switch (opcode) {
            Opcode.STOP => try writer.print("STOP", .{}),
            Opcode.ADD => try writer.print("ADD", .{}),
            Opcode.MUL => try writer.print("MUL", .{}),
            Opcode.SUB => try writer.print("SUB", .{}),
            Opcode.DIV => try writer.print("DIV", .{}),
            Opcode.SHL => try writer.print("SHL", .{}),
            Opcode.SHR => try writer.print("SHR", .{}),
            Opcode.SAR => try writer.print("SAR", .{}),
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

            Opcode.PUSH0 => try writer.print("PUSH0", .{}),
            Opcode.PUSH1 => {
                if (pc + 1 < context.code.len) {
                    const value = context.code[pc + 1];
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
                    if (pc + push_bytes < context.code.len) {
                        try writer.print("PUSH{d} ", .{push_bytes});
                        for (0..push_bytes) |i| {
                            try writer.print("0x{x:0>2}", .{context.code[pc + 1 + i]});
                        }
                        pc += push_bytes;
                    } else {
                        try writer.print("PUSH{d} <データ不足>", .{push_bytes});
                        pc = context.code.len;
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

/// オペコードに関する説明を取得する
pub fn getOpcodeDescription(opcode: u8) []const u8 {
    return switch (opcode) {
        // 標準のオペコード
        Opcode.STOP => "実行を停止する",
        Opcode.ADD => "スタックから2つの値をポップし、加算結果をプッシュ",
        Opcode.MUL => "スタックから2つの値をポップし、乗算結果をプッシュ",
        Opcode.SUB => "スタックから2つの値をポップし、減算結果をプッシュ",
        Opcode.DIV => "スタックから2つの値をポップし、除算結果をプッシュ",
        Opcode.SHL => "左シフト演算",
        Opcode.SHR => "右シフト演算（論理）",
        Opcode.SAR => "右シフト演算（算術）",
        Opcode.MLOAD => "メモリから読み込み",
        Opcode.MSTORE => "メモリに書き込み",
        Opcode.SLOAD => "ストレージから読み込み",
        Opcode.SSTORE => "ストレージに書き込み",
        Opcode.JUMP => "無条件ジャンプ",
        Opcode.JUMPI => "条件付きジャンプ",
        Opcode.JUMPDEST => "ジャンプ先としての目印",
        Opcode.RETURN => "実行を停止し、メモリからのデータを返す",
        Opcode.PUSH0 => "スタックに0をプッシュ",
        Opcode.PUSH1 => "スタックに1バイトの値をプッシュ",
        Opcode.PUSH2 => "スタックに2バイトの値をプッシュ",

        // よく発生する不正なオペコード
        0x0F => "無効なオペコード（古いオペコード、削除済み）",
        0x1E, 0x1F => "無効なオペコード（未使用）",
        0x21 => "無効なオペコード（LOGx命令に近い範囲）",
        0x5C...0x5E => "無効なオペコード（PUSHx/DUP/SWAP周辺の未割り当て）",
        0xA5...0xEF => "無効なオペコード（未使用領域）",
        0xF6...0xF9 => "無効なオペコード（システム命令周辺の未割り当て）",
        0xFB...0xFC => "無効なオペコード（STATICCALL/REVERT周辺の未割り当て）",
        0xFE => "無効なオペコード（INVALID/ABORTオペコード）",

        else => "未知のオペコード",
    };
}

/// 無効なオペコードの詳細情報を取得
pub fn getInvalidOpcodeDetail(opcode: u8) []const u8 {
    return switch (opcode) {
        0x0F => "無効（古いオペコード、削除された命令）",
        0x1E, 0x1F => "無効（未使用の予約領域）",
        0x21 => "無効（おそらくLOG0～LOG4(0xA0～0xA4)関連）",
        0x5C...0x5E => "無効（PUSH/DUP/SWAP命令群の周辺の未割り当て領域）",
        0xA5...0xEF => "無効（使用されていない広い範囲）",
        0xF6...0xF9 => "無効（システムオペコード周辺の未割り当て）",
        0xFB...0xFC => "無効（STATICCALL/REVERT周辺の未割り当て）",
        0xFE => "無効（INVALID/ABORT専用オペコード）",

        else => if (opcode >= 0x60 and opcode <= 0x7F)
            "PUSH命令のオーバーフロー（コード終端を超えている可能性）"
        else
            "詳細な理由不明の無効なオペコード",
    };
}

/// EVMバイトコードをより詳細に解析してエラー原因を推測する
pub fn analyzeErrorCause(code: []const u8, error_pc: usize) []const u8 {
    if (error_pc >= code.len) {
        return "実行ポインタがコード終端を超えています。無限ループまたはジャンプエラーの可能性が高いです。";
    }

    const opcode = code[error_pc];

    // オペコードの種類に応じた解析
    return switch (opcode) {
        0x56, 0x57 => "JUMPまたはJUMPI命令：ジャンプ先が無効か、JUMPDESTでない可能性があります。",
        0x60...0x7F => blk: {
            // PUSHx命令のデータ不足チェック
            const push_bytes = opcode - 0x5F; // PUSH1(0x60)なら1, PUSH2(0x61)なら2...
            if (error_pc + push_bytes >= code.len) {
                break :blk "PUSH命令のデータが不足しています（コード終端を超えています）。";
            }
            break :blk "PUSH命令ですが、エラー原因は不明です。スタックオーバーフローの可能性があります。";
        },
        0xF0, 0xF5, 0xFA, 0xFD => "この命令はコントラクトのバージョン（solidity・compiler）が古いか、特殊な命令が必要な可能性があります。",
        0xFE => "明示的なINVALIDオペコード（abort()またはassert失敗の可能性）",

        else => "未知または未実装のオペコード",
    };
}
