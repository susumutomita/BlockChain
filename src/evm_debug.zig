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
            Opcode.REVERT => try writer.print("REVERT", .{}),

            // Comparison and logic operations
            Opcode.LT => try writer.print("LT", .{}),
            Opcode.GT => try writer.print("GT", .{}),
            Opcode.SLT => try writer.print("SLT", .{}),
            Opcode.EQ => try writer.print("EQ", .{}),
            Opcode.ISZERO => try writer.print("ISZERO", .{}),

            Opcode.POP => try writer.print("POP", .{}),
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
        Opcode.REVERT => "実行を停止し、状態変更を巻き戻し、メモリからのデータを返す",
        Opcode.LT => "符号なし未満比較（b < a の場合1、そうでなければ0）",
        Opcode.GT => "符号なし超過比較（b > a の場合1、そうでなければ0）",
        Opcode.SLT => "符号付き未満比較（b < a の場合1、そうでなければ0）",
        Opcode.EQ => "等価比較（a == b の場合1、そうでなければ0）",
        Opcode.ISZERO => "ゼロ判定（a == 0 の場合1、そうでなければ0）",
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
        0x0F => "無効（Solidity 0.8.x系で使用される新しいオペコード。Londonフォークで導入された命令の可能性）",
        0x1E, 0x1F => "無効（未使用の予約領域）",
        0x21 => "無効（おそらくLOG0～LOG4(0xA0～0xA4)関連）",
        0x5F => "無効（PUSH0命令 - Solidity 0.8.7以降、London EVM以降で導入）",
        0x5C...0x5E => "無効（PUSH/DUP/SWAP命令群の周辺の未割り当て領域）",
        0xA5...0xEF => "無効（使用されていない広い範囲）",
        0xF0 => "無効（CREATE2命令 - Constantinopleフォークで導入された命令、未実装）",
        0xF5 => "無効（CREATE2命令 - Constantinopleフォークで導入された命令、未実装）",
        0xFA => "無効（STATICCALL命令 - Byzantiumフォークで導入された命令、未実装）",
        0xFD => "無効（REVERT命令 - Byzantiumフォークで導入された命令、未実装）",
        0xF6...0xF9 => "無効（システムオペコード周辺の未割り当て）",
        0xFB...0xFC => "無効（STATICCALL/REVERT周辺の未割り当て）",
        0xFE => "無効（INVALID/ABORT専用オペコード - assert失敗やrevertなど）",

        else => if (opcode >= 0x60 and opcode <= 0x7F)
            "PUSH命令のオーバーフロー（コード終端を超えている可能性）"
        else if (opcode >= 0xA0 and opcode <= 0xA4)
            "LOGx命令（イベント発行）の使用 - 実装されていない可能性"
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

    // コード先頭の特徴に基づくSolidityバージョン分析
    if (code.len > 32) {
        // Solidityバージョン別の特徴的なパターンをチェック
        if (code[0] == 0x60 and code[1] == 0x80 and code[2] == 0x60 and code[3] == 0x40) {
            // 標準的なSolidityパターン（メモリレイアウト初期化）を検出

            // パターン1: Solidity 0.8.x系
            if (error_pc < 20 and opcode == 0x0F) {
                if (error_pc > 8 and error_pc < 15 and code[error_pc - 1] == 0x61) {
                    return "Solidity 0.8.x系のバイトコード（London/Berlin EVM対応）です。このEVMではPUSH0命令(0x5F)や新しいDUP/SWAP命令をサポートしていません。Solidity 0.7.x以下を使用するか、コンパイラオプションで古いEVMバージョンを指定してください。";
                }
                return "Solidity 0.8.x系のバイトコードと思われます。このEVMでは対応していない命令（0x0F）があります。";
            }

            // パターン2: Solidity 0.6.x-0.7.x系
            if (error_pc > 30 and error_pc < 60 and (opcode == 0xF0 or opcode == 0xF5)) {
                return "Solidity 0.6.x-0.7.x系のバイトコードのようです。このEVMでは対応していない命令があります。";
            }
        }
    }

    // 特殊なパターンチェック - Solidity固有の問題を検出
    if (opcode == 0x0F and error_pc == 10 and code.len > 20) {
        if (code[9] == 0x61 and code[11] == 0x57) { // 0x61 0x0F 0x57 パターン
            return "Solidity 0.8.x系のバイトコードで、対応していないEVMバージョン用にコンパイルされた可能性があります。このEVMではPUSH0命令(0x5F)とDUP/SWAPの拡張命令をサポートしていません。";
        }
    }

    // オペコードの種類に応じた解析
    return switch (opcode) {
        0x0F => "このオペコード(0x0F)はSolidity 0.8.x系のコンパイラから生成されたバイトコードによく見られるエラーです。Solidity 0.7.x以下を使うか、EVMの実装をアップグレードする必要があります。",
        0x5F => "PUSH0命令です。この命令はLondon EVM以降で導入され、Solidity 0.8.7以降で使用されます。古いEVMバージョンを使用するにはSolidity 0.8.6以下を使うか、--evm-version=berlin などのオプションを使用してください。",
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

/// コードの特定位置の周囲をhexdumpとして見やすく表示する
///
/// 引数:
///     code: 表示するバイトコード
///     highlight_pos: ハイライト表示する位置（PC）
///     context_size: 前後に表示する範囲のサイズ
///     writer: 出力先
///
/// 戻り値:
///     表示処理のエラー結果
pub fn hexdumpCodeContext(code: []const u8, highlight_pos: usize, context_size: usize, writer: anytype) !void {
    const start_pos = if (highlight_pos > context_size) highlight_pos - context_size else 0;
    const end_pos = if (highlight_pos + context_size < code.len) highlight_pos + context_size else code.len;

    // ヘッダー行（位置インデックス）を表示
    try writer.print("         ", .{});
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        try writer.print(" {X:1}", .{i});
    }
    try writer.print("\n", .{});

    // セパレータ
    try writer.print("        +", .{});
    i = 0;
    while (i < 16) : (i += 1) {
        try writer.print("--", .{});
    }
    try writer.print("+\n", .{});

    // 各行を表示
    var line_start: usize = start_pos - (start_pos % 16);
    while (line_start < end_pos) : (line_start += 16) {
        // アドレス表示
        try writer.print("0x{x:0>4}: |", .{line_start});

        // バイト表示（16進数）
        i = 0;
        while (i < 16) : (i += 1) {
            const pos = line_start + i;
            if (pos < start_pos or pos >= end_pos) {
                try writer.print("  ", .{});
            } else if (pos == highlight_pos) {
                // ハイライト位置は強調表示
                try writer.print("\x1b[31m{x:0>2}\x1b[0m", .{code[pos]});
            } else {
                try writer.print("{x:0>2}", .{code[pos]});
            }
            try writer.print(" ", .{});
        }

        // 文字表示（ASCII）
        try writer.print("|", .{});
        i = 0;
        while (i < 16) : (i += 1) {
            const pos = line_start + i;
            if (pos < start_pos or pos >= end_pos) {
                try writer.print(" ", .{});
            } else if (pos == highlight_pos) {
                // ハイライト位置は強調表示
                const c = if (code[pos] >= 32 and code[pos] < 127) @as(u8, code[pos]) else '.';
                try writer.print("\x1b[31m{c}\x1b[0m", .{c});
            } else {
                const c = if (code[pos] >= 32 and code[pos] < 127) @as(u8, code[pos]) else '.';
                try writer.print("{c}", .{c});
            }
        }
        try writer.print("|\n", .{});
    }

    // セパレータ
    try writer.print("        +", .{});
    i = 0;
    while (i < 16) : (i += 1) {
        try writer.print("--", .{});
    }
    try writer.print("+\n", .{});
}

/// EVMバイトコードからSolidityコンパイラのバージョンを推測する
///
/// 引数:
///     code: 分析対象のバイトコード
///
/// 戻り値:
///     コンパイラバージョンと推定理由を含む文字列
pub fn guessSolidityVersion(code: []const u8) []const u8 {
    if (code.len < 32) {
        return "バイトコードが小さすぎて分析できません";
    }

    // バージョン検出のためのパターン分析
    // 1. メモリセットアップパターン (0x60 0x80 0x60 0x40) はほぼすべてのSolidityバージョンで共通
    if (code[0] == 0x60 and code[1] == 0x80 and code[2] == 0x60 and code[3] == 0x40) {
        // Londonフォーク以降のバイトコードパターン
        if (codeContainsOpcode(code, 0x5F)) {
            return "Solidity 0.8.7以降（London EVM、PUSH0オペコードを使用）";
        }

        // 0.8.xシリーズのパターン
        if (codeContainsOpcode(code[0..32], 0x0F)) {
            return "Solidity 0.8.x系（Londonフォーク以前）";
        }

        // STATICCALL、RETURNDATASIZE、REVERTなどの命令の存在確認
        if (codeContainsOpcode(code, 0xFA) or codeContainsOpcode(code, 0xFD)) {
            return "Solidity 0.4.22 - 0.7.x系（Byzantiumフォーク以降）";
        }

        // CREATE2命令の確認
        if (codeContainsOpcode(code, 0xF5)) {
            return "Solidity 0.5.0 - 0.7.x系（Constantinopleフォーク以降）";
        }
    }

    return "バージョン識別できません（古いSolidityか、手書きアセンブリの可能性）";
}

/// バイトコード内に特定のオペコードが含まれているか確認
///
/// 引数:
///     code: 検索対象のバイトコード
///     opcode: 検索するオペコード
///
/// 戻り値:
///     bool: オペコードが見つかった場合はtrue
fn codeContainsOpcode(code: []const u8, opcode: u8) bool {
    var i: usize = 0;
    while (i < code.len) {
        if (code[i] == opcode) {
            return true;
        }

        // PUSHx命令の場合はデータ部分をスキップ
        if (code[i] >= 0x60 and code[i] <= 0x7F) {
            const skip = code[i] - 0x5F;
            i += skip;
        }
        i += 1;
    }
    return false;
}

/// バイトコード全体をより高度に逆アセンブルする関数
///
/// 引数:
///     code: 逆アセンブルするバイトコード
///     start_pc: 開始位置（オプション）
///     max_instructions: 表示する最大命令数（オプション）
///     writer: 出力先
///
/// 注意:
///     標準的なオペコードだけでなく、無効なオペコードも表示します
///     また、PUSHx命令のデータも正しく解析します
pub fn disassembleBytecode(code: []const u8, start_pc: ?usize, max_instructions: ?usize, writer: anytype) !void {
    const start = start_pc orelse 0;
    const max_inst = max_instructions orelse 1000; // デフォルトは1000命令まで

    var pc: usize = start;
    var inst_count: usize = 0;

    // ヘッダー表示
    try writer.print("オフセット | オペコード | 命令        | データ/説明\n", .{});
    try writer.print("----------+----------+------------+-----------------\n", .{});

    while (pc < code.len and inst_count < max_inst) : (inst_count += 1) {
        const opcode = code[pc];
        try writer.print("0x{x:0>4}    | 0x{x:0>2}     | ", .{ pc, opcode });

        pc += 1; // オペコードを処理

        // オペコードの種類に応じた処理
        switch (opcode) {
            // 標準的なオペコード（0引数）
            0x00 => try writer.print("STOP       |", .{}),
            0x01 => try writer.print("ADD        |", .{}),
            0x02 => try writer.print("MUL        |", .{}),
            0x03 => try writer.print("SUB        |", .{}),
            0x04 => try writer.print("DIV        |", .{}),
            0x05 => try writer.print("SDIV       |", .{}),
            0x06 => try writer.print("MOD        |", .{}),
            0x0a => try writer.print("EXP        |", .{}),
            0x10 => try writer.print("LT         |", .{}),
            0x11 => try writer.print("GT         |", .{}),
            0x12 => try writer.print("SLT        |", .{}),
            0x14 => try writer.print("EQ         |", .{}),
            0x15 => try writer.print("ISZERO     |", .{}),
            0x16 => try writer.print("AND        |", .{}),
            0x17 => try writer.print("OR         |", .{}),
            0x18 => try writer.print("XOR        |", .{}),
            0x19 => try writer.print("NOT        |", .{}),
            0x1a => try writer.print("BYTE       |", .{}),
            0x1b => try writer.print("SHL        |", .{}),
            0x1c => try writer.print("SHR        |", .{}),
            0x1d => try writer.print("SAR        |", .{}),
            0x20 => try writer.print("SHA3       |", .{}),
            0x30 => try writer.print("ADDRESS    |", .{}),
            0x31 => try writer.print("BALANCE    |", .{}),
            0x32 => try writer.print("ORIGIN     |", .{}),
            0x33 => try writer.print("CALLER     |", .{}),
            0x34 => try writer.print("CALLVALUE  |", .{}),
            0x35 => try writer.print("CALLDATALOAD |", .{}),
            0x36 => try writer.print("CALLDATASIZE |", .{}),
            0x37 => try writer.print("CALLDATACOPY |", .{}),
            0x38 => try writer.print("CODESIZE   |", .{}),
            0x39 => try writer.print("CODECOPY   |", .{}),
            0x3a => try writer.print("GASPRICE   |", .{}),
            0x3b => try writer.print("EXTCODESIZE |", .{}),
            0x3c => try writer.print("EXTCODECOPY |", .{}),
            0x3d => try writer.print("RETURNDATASIZE |", .{}),
            0x3e => try writer.print("RETURNDATACOPY |", .{}),
            0x40 => try writer.print("BLOCKHASH  |", .{}),
            0x41 => try writer.print("COINBASE   |", .{}),
            0x42 => try writer.print("TIMESTAMP  |", .{}),
            0x43 => try writer.print("NUMBER     |", .{}),
            0x44 => try writer.print("DIFFICULTY |", .{}),
            0x45 => try writer.print("GASLIMIT   |", .{}),
            0x50 => try writer.print("POP        |", .{}),
            0x51 => try writer.print("MLOAD      |", .{}),
            0x52 => try writer.print("MSTORE     |", .{}),
            0x53 => try writer.print("MSTORE8    |", .{}),
            0x54 => try writer.print("SLOAD      |", .{}),
            0x55 => try writer.print("SSTORE     |", .{}),
            0x56 => try writer.print("JUMP       |", .{}),
            0x57 => try writer.print("JUMPI      |", .{}),
            0x58 => try writer.print("PC         |", .{}),
            0x59 => try writer.print("MSIZE      |", .{}),
            0x5a => try writer.print("GAS        |", .{}),
            0x5b => try writer.print("JUMPDEST   |", .{}),
            0x5f => try writer.print("PUSH0      |", .{}),
            0xf0 => try writer.print("CREATE     |", .{}),
            0xf1 => try writer.print("CALL       |", .{}),
            0xf2 => try writer.print("CALLCODE   |", .{}),
            0xf3 => try writer.print("RETURN     |", .{}),
            0xf4 => try writer.print("DELEGATECALL |", .{}),
            0xf5 => try writer.print("CREATE2    |", .{}),
            0xfa => try writer.print("STATICCALL |", .{}),
            0xfd => try writer.print("REVERT     |", .{}),
            0xfe => try writer.print("INVALID    |", .{}),
            0xff => try writer.print("SELFDESTRUCT |", .{}),

            // PUSH1-PUSH32 (0x60-0x7F)
            0x60...0x7F => {
                const push_bytes = opcode - 0x5F;
                try writer.print("PUSH{d:<2}     | 0x", .{push_bytes});

                if (pc + push_bytes <= code.len) {
                    for (0..push_bytes) |i| {
                        try writer.print("{x:0>2}", .{code[pc + i]});
                    }
                    pc += push_bytes;
                } else {
                    try writer.print("インデックス範囲外", .{});
                    pc = code.len; // 終了
                }
            },

            // DUP1-DUP16 (0x80-0x8F)
            0x80...0x8F => try writer.print("DUP{d}       |", .{opcode - 0x7F}),

            // SWAP1-SWAP16 (0x90-0x9F)
            0x90...0x9F => try writer.print("SWAP{d}      |", .{opcode - 0x8F}),

            // LOG0-LOG4 (0xA0-0xA4)
            0xA0...0xA4 => try writer.print("LOG{d}       |", .{opcode - 0xA0}),

            // 無効または未知のオペコード
            else => {
                try writer.print("UNKNOWN    | 無効なオペコード", .{});
                if (opcode == 0x0F) {
                    try writer.print(" (Solidity 0.8.x系で使用)", .{});
                }
            },
        }

        try writer.print("\n", .{});
    }

    if (pc < code.len) {
        try writer.print("... 残り {d} バイト省略 ...\n", .{code.len - pc});
    }
}

/// コントラクト呼び出しデータからファンクションセレクタを解析する
///
/// 引数:
///     calldata: 分析する呼び出しデータ
///     writer: 出力先ライター
///
/// 備考:
///     Solidityのコントラクト呼び出しは、最初の4バイトがkeccak256(関数シグネチャ)のハッシュの先頭4バイト
///     その後に引数が続く形式である。この関数はそれを解析して表示する。
pub fn analyzeFunctionSelector(calldata: []const u8, writer: anytype) !void {
    if (calldata.len < 4) {
        try writer.print("関数セレクタなし（データが短すぎます）\n", .{});
        return;
    }

    // 関数セレクタ（先頭4バイト）を表示
    try writer.print("関数セレクタ: 0x{x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{ calldata[0], calldata[1], calldata[2], calldata[3] });

    // 一般的な関数セレクタと照合
    const selector = (@as(u32, calldata[0]) << 24) | (@as(u32, calldata[1]) << 16) | (@as(u32, calldata[2]) << 8) | @as(u32, calldata[3]);

    // 一般的な関数シグネチャとセレクタの対応表
    const common_selectors = .{
        .{ 0x70a08231, "balanceOf(address)" },
        .{ 0xa9059cbb, "transfer(address,uint256)" },
        .{ 0x095ea7b3, "approve(address,uint256)" },
        .{ 0x23b872dd, "transferFrom(address,address,uint256)" },
        .{ 0xdd62ed3e, "allowance(address,address)" },
        .{ 0x313ce567, "decimals()" },
        .{ 0x06fdde03, "name()" },
        .{ 0x95d89b41, "symbol()" },
        .{ 0x18160ddd, "totalSupply()" },
        .{ 0x42966c68, "burn(uint256)" },
        .{ 0x40c10f19, "mint(address,uint256)" },
        .{ 0x79cc6790, "burnFrom(address,uint256)" },
        .{ 0x8da5cb5b, "owner()" },
        .{ 0x6352211e, "ownerOf(uint256)" },
        .{ 0xb88d4fde, "safeTransferFrom(address,address,uint256,bytes)" },
        .{ 0xf2fde38b, "transferOwnership(address)" },
        .{ 0x01ffc9a7, "supportsInterface(bytes4)" },
        .{ 0x3644e515, "DOMAIN_SEPARATOR()" },
        .{ 0x9d63848a, "nonces(address)" },
    };

    var found = false;
    inline for (common_selectors) |item| {
        if (item[0] == selector) {
            try writer.print("一致する関数シグネチャ: {s}\n", .{item[1]});
            found = true;
            break;
        }
    }

    if (!found) {
        try writer.print("一般的な関数シグネチャと一致しませんでした\n", .{});
    }

    // 引数データ（残りのバイト）を分析
    if (calldata.len > 4) {
        try writer.print("\n引数データ ({d} バイト):\n", .{calldata.len - 4});

        // 32バイト単位で表示（Solidityの引数は32バイト単位でパディングされる）
        var i: usize = 4;
        var arg_index: usize = 0;

        while (i + 32 <= calldata.len) : (i += 32) {
            try writer.print("引数 #{d}: ", .{arg_index});

            // 数値として解釈（先頭バイトが0でなければ大きな値）
            var is_zero = true;
            for (0..32) |j| {
                if (calldata[i + j] != 0) {
                    is_zero = false;
                    break;
                }
            }

            // 10進数とアドレス形式で表示
            try writer.print("0x", .{});
            for (0..32) |j| {
                try writer.print("{x:0>2}", .{calldata[i + j]});
            }

            // アドレスらしきパターンを検出
            var could_be_address = true;

            // 先頭12バイトが0で、残り20バイトに値がある場合はアドレスの可能性
            for (0..12) |j| {
                if (calldata[i + j] != 0) {
                    could_be_address = false;
                    break;
                }
            }

            var has_nonzero = false;
            for (12..32) |j| {
                if (calldata[i + j] != 0) {
                    has_nonzero = true;
                    break;
                }
            }

            if (could_be_address and has_nonzero) {
                try writer.print(" (可能性のあるアドレス: 0x", .{});
                for (12..32) |j| {
                    try writer.print("{x:0>2}", .{calldata[i + j]});
                }
                try writer.print(")", .{});
            }

            try writer.print("\n", .{});
            arg_index += 1;
        }

        // 残りのデータがある場合
        if (i < calldata.len) {
            try writer.print("残りのデータ: ", .{});
            while (i < calldata.len) : (i += 1) {
                try writer.print("{x:0>2}", .{calldata[i]});
            }
            try writer.print("\n", .{});
        }
    } else {
        try writer.print("引数データなし\n", .{});
    }
}
