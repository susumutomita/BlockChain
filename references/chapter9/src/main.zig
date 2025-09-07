//! ブロックチェーンアプリケーション エントリーポイント
//!
//! このファイルはブロックチェーンアプリケーションのメインエントリーポイントです。
//! コマンドライン引数の処理、ブロックチェーンの初期化、
//! ネットワーキングとユーザー操作用のスレッドの起動を行います。
//! また、適合性テストを実行するためのサポートも提供します。
//! EVMのバイトコード実行もサポートします。

const std = @import("std");
const blockchain = @import("blockchain.zig");
const types = @import("types.zig");
const parser = @import("parser.zig");
const p2p = @import("p2p.zig");
const evm = @import("evm.zig");
const evm_types = @import("evm_types.zig");
const utils = @import("utils.zig");

// グローバル変数で保存しておく（p2p.zigから使用）
pub var global_call_pending: bool = false;
pub var global_contract_address: []const u8 = "";
pub var global_evm_input: []const u8 = undefined;
pub var global_gas_limit: usize = 0;
pub var global_allocator: std.mem.Allocator = undefined;
pub var global_sender_address: []const u8 = "";

/// アプリケーションエントリーポイント
///
/// コマンドライン引数を解析し、P2Pネットワークをセットアップし、
/// リスナーとユーザー操作用のバックグラウンドスレッドを起動して
/// ブロックチェーンアプリケーションを初期化します。
/// また、適合性テストの実行もサポートします。
///
/// コマンドライン形式:
///   実行ファイル <ポート> [ピアアドレス...]
///   実行ファイル --listen <ポート> [--connect <ホスト:ポート>...]
///   実行ファイル --conformance <テスト名> [--update]
///   実行ファイル --evm <バイトコードHEX> [--input <入力データHEX>] [--gas <ガス上限>]
///   実行ファイル --deploy <バイトコードHEX> <コントラクトアドレス> [--gas <ガス上限>] [--sender <送信者アドレス>]
///   実行ファイル --call <コントラクトアドレス> <入力データHEX> [--gas <ガス上限>] [--sender <送信者アドレス>]
///   実行ファイル --analyze <バイトコードHEX>
///
/// 引数:
///     <ポート>: このノードが待ち受けるポート番号
///     [ピア...]: オプションの既知ピアアドレスのリスト（"ホスト:ポート"形式）
///     --listen <ポート>: このノードが待ち受けるポート番号
///     --connect <ホスト:ポート>: オプションの既知ピアアドレス
///     --conformance <テスト名>: 指定された適合性テストを実行
///     --update: 適合性テスト実行時にゴールデンファイルを更新
///     --evm <バイトコードHEX>: 実行するEVMバイトコード（16進数形式）
///     --input <入力データHEX>: EVMコントラクトへの入力データ（16進数形式）
///     --deploy <バイトコードHEX>: デプロイするコントラクトのバイトコード
///     --call <コントラクトアドレス>: 呼び出すコントラクトのアドレス
///     --gas <ガス上限>: EVMバイトコード実行時のガス上限（デフォルト: 1000000）
///     --sender <送信者アドレス>: トランザクション送信者のアドレス
///
/// 戻り値:
///     void - 関数は無期限に実行されるか、エラーが発生するまで実行
pub fn main() !void {
    // アロケータの初期化
    const gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 2) {
        std.log.err("使用法: {s} <ポート> [ピアアドレス...]", .{args[0]});
        std.log.err("または: {s} --listen <ポート> [--connect <ホスト:ポート>...]", .{args[0]});
        std.log.err("       {s} --conformance <テスト名> [--update]", .{args[0]});
        std.log.err("       {s} --evm <バイトコードHEX> [--input <入力データHEX>] [--gas <ガス上限>]", .{args[0]});
        std.log.err("       {s} --deploy <バイトコードHEX> <コントラクトアドレス> [--gas <ガス上限>] [--sender <送信者アドレス>]", .{args[0]});
        std.log.err("       {s} --call <コントラクトアドレス> <入力データHEX> [--gas <ガス上限>] [--sender <送信者アドレス>]", .{args[0]});
        std.log.err("       {s} --analyze <バイトコードHEX>", .{args[0]});
        return;
    }

    // EVMモード変数
    var evm_mode = false;
    var evm_bytecode: []const u8 = "";
    var evm_input: []const u8 = "";
    var evm_gas_limit: usize = 1000000; // デフォルトガス上限

    // ネットワークEVMトランザクションモード
    var deploy_mode = false;
    var call_mode = false;
    var contract_address: []const u8 = "";
    var sender_address: []const u8 = "0x0000000000000000000000000000000000000000"; // デフォルト送信者アドレス

    var self_port: u16 = 0;
    var known_peers = std.ArrayList([]const u8).init(gpa);
    defer known_peers.deinit();

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--listen")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--listen フラグの後にポート番号が必要です", .{});
                return;
            }
            self_port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--connect")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--connect フラグの後にホスト:ポートが必要です", .{});
                return;
            }
            try known_peers.append(args[i]);
        } else if (std.mem.eql(u8, arg, "--evm")) {
            evm_mode = true;
            i += 1;
            if (i >= args.len) {
                std.log.err("--evm フラグの後にバイトコードが必要です", .{});
                return;
            }
            evm_bytecode = args[i];
        } else if (std.mem.eql(u8, arg, "--input")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--input フラグの後に入力データが必要です", .{});
                return;
            }
            evm_input = args[i];
        } else if (std.mem.eql(u8, arg, "--deploy")) {
            deploy_mode = true;
            i += 1;
            if (i >= args.len) {
                std.log.err("--deploy フラグの後にバイトコードが必要です", .{});
                return;
            }
            evm_bytecode = args[i];

            // コントラクトアドレスも必要
            i += 1;
            if (i >= args.len) {
                std.log.err("--deploy フラグの後にコントラクトアドレスも指定する必要があります", .{});
                return;
            }
            contract_address = args[i];
        } else if (std.mem.eql(u8, arg, "--call")) {
            call_mode = true;
            i += 1;
            if (i >= args.len) {
                std.log.err("--call フラグの後にコントラクトアドレスが必要です", .{});
                return;
            }
            contract_address = args[i];

            // 入力データも必要
            i += 1;
            if (i >= args.len) {
                std.log.err("--call フラグの後に入力データも指定する必要があります", .{});
                return;
            }
            evm_input = args[i];
        } else if (std.mem.eql(u8, arg, "--gas")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--gas フラグの後にガス上限が必要です", .{});
                return;
            }
            evm_gas_limit = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--sender")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--sender フラグの後に送信者アドレスが必要です", .{});
                return;
            }
            sender_address = args[i];
        } else if (std.mem.eql(u8, arg, "--analyze")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--analyze フラグの後にバイトコードが必要です", .{});
                return;
            }
            // バイトコード解析機能を実行
            try test_evm_bytecode_analysis(gpa, args[i]);
            return;
        } else if (self_port == 0 and !evm_mode and !deploy_mode and !call_mode) {
            // 従来の方式（最初の引数はポート番号）
            self_port = try std.fmt.parseInt(u16, arg, 10);
        } else if (!evm_mode and !deploy_mode and !call_mode) {
            // 従来の方式（追加の引数はピアアドレス）
            try known_peers.append(arg);
        }
    }

    // 送信者アドレスをグローバル変数に設定
    global_sender_address = sender_address;

    // EVMモードの場合はEVMを実行して終了する
    if (evm_mode) {
        try runEvm(gpa, evm_bytecode, evm_input, evm_gas_limit);
        return;
    }

    if (self_port == 0 and !deploy_mode and !call_mode) {
        std.log.err("ポート番号が指定されていません。--listen フラグまたは最初の引数として指定してください。", .{});
        return;
    }

    // 初期ブロックチェーン状態の表示
    blockchain.printChainState();

    // 着信接続用のリスナースレッドを開始
    _ = try std.Thread.spawn(.{}, p2p.listenLoop, .{self_port});

    // すべての既知のピアに接続
    for (known_peers.items) |spec| {
        const peer_addr = try p2p.resolveHostPort(spec);
        _ = try std.Thread.spawn(.{}, p2p.connectToPeer, .{peer_addr});
    }

    // インタラクティブなテキスト入力スレッドを開始
    _ = try std.Thread.spawn(.{}, p2p.textInputLoop, .{});

    // コントラクトデプロイモード
    if (deploy_mode) {
        try deployContract(gpa, evm_bytecode, contract_address, evm_gas_limit, sender_address);
        // デプロイは即時終了せず、そのままネットワークノードとして動作する
    }

    // コントラクト呼び出しモード
    if (call_mode) {
        try callContract(gpa, contract_address, evm_input, evm_gas_limit, sender_address);
        // 呼び出しも即時終了せず、そのままネットワークノードとして動作する
    }

    // メインスレッドを生かし続ける
    while (true) std.time.sleep(60 * std.time.ns_per_s);
}

/// EVMバイトコードを実行する
fn runEvm(allocator: std.mem.Allocator, bytecode_hex: []const u8, input_hex: []const u8, gas_limit: usize) !void {
    std.log.info("EVMバイトコードを実行しています...", .{});

    // 16進数文字列をバイト配列に変換
    const bytecode = try utils.hexToBytes(allocator, bytecode_hex);
    defer allocator.free(bytecode);

    const input_data = try utils.hexToBytes(allocator, input_hex);
    defer allocator.free(input_data);

    std.log.info("バイトコード: {any}", .{bytecode});
    std.log.info("入力データ: {any}", .{input_data});
    std.log.info("ガス上限: {d}", .{gas_limit});

    // バイトコードを逆アセンブルして表示（デバッグ用）
    const stdout = std.io.getStdOut().writer();
    try stdout.print("\n=== EVMバイトコード逆アセンブル ===\n", .{});
    try evm.disassemble(bytecode, stdout);
    try stdout.print("\n==============================\n\n", .{});

    // EVMを実行
    const result = try evm.execute(allocator, bytecode, input_data, gas_limit);
    defer allocator.free(result);

    // 結果の表示
    const hex_result = try utils.bytesToHexWithPrefix(allocator, result);
    defer allocator.free(hex_result);
    std.log.info("実行結果(hex): {s}", .{hex_result});

    // 結果を整数として解釈して表示（存在する場合）
    if (result.len >= 32) {
        var value = evm_types.EVMu256{ .hi = 0, .lo = 0 };

        // 上位16バイトを解析
        for (0..16) |j| {
            const byte_val = result[j];
            value.hi |= @as(u128, byte_val) << @as(u7, @intCast((15 - j) * 8));
        }

        // 下位16バイトを解析
        for (0..16) |j| {
            const byte_val = result[j + 16];
            value.lo |= @as(u128, byte_val) << @as(u7, @intCast((15 - j) * 8));
        }

        // カスタム型のフォーマット関数を使用するため、{} または {x}を使う
        std.log.info("結果(u256): {} (0x{x})", .{ value, value });
    }
}

/// コントラクトをブロックチェーン上にデプロイする
fn deployContract(allocator: std.mem.Allocator, bytecode_hex: []const u8, contract_address: []const u8, gas_limit: usize, sender_address: []const u8) !void {
    std.log.info("コントラクトをブロックチェーンにデプロイしています...", .{});

    // 16進数文字列をバイト配列に変換
    const bytecode = try utils.hexToBytes(allocator, bytecode_hex);
    defer allocator.free(bytecode);

    std.log.info("バイトコード: 0x{s}", .{try utils.bytesToHex(allocator, bytecode)});
    std.log.info("デプロイ先アドレス: {s}", .{contract_address});
    std.log.info("送信者アドレス: {s}", .{sender_address});
    std.log.info("ガス上限: {d}", .{gas_limit});

    // トランザクションを作成
    const tx = types.Transaction{
        .sender = sender_address,
        .receiver = contract_address,
        .amount = 0,
        .tx_type = 1, // コントラクトデプロイ
        .evm_data = bytecode,
        .gas_limit = gas_limit,
        .gas_price = 10, // デフォルトのガス価格を設定
    };

    // P2Pネットワーク上でトランザクションをブロードキャスト
    try p2p.broadcastEvmTransaction(tx);
    std.log.info("デプロイトランザクションをブロードキャストしました", .{});

    // ローカルでもトランザクションを処理して即時デプロイする
    std.log.info("ローカルノードでコントラクトデプロイを実行しています...", .{});
    var tx_copy = tx; // トランザクションの可変コピーを作成
    const result = blockchain.processEvmTransactionWithErrorDetails(&tx_copy) catch |err| {
        // 詳細なエラー情報はprocessEvmTransactionWithErrorDetails内で出力されるため、
        // ここでは簡潔なエラーのみ表示
        std.log.err("ローカルでのデプロイ処理エラー: {any}", .{err});
        return;
    };

    // 実行結果を表示
    blockchain.logEvmResult(&tx_copy, result) catch |err| {
        std.log.err("結果ログ出力エラー: {any}", .{err});
    };

    std.log.info("ローカルノードでコントラクトデプロイ処理が完了しました", .{});
}

/// コントラクトを呼び出す
fn callContract(allocator: std.mem.Allocator, contract_address: []const u8, input_hex: []const u8, gas_limit: usize, sender_address: []const u8) !void {
    std.log.info("ブロックチェーン上のコントラクトを呼び出しています...", .{});

    // 16進数文字列をバイト配列に変換
    const input_data = try utils.hexToBytes(allocator, input_hex);

    // グローバル変数に設定して保存しておく
    global_contract_address = contract_address;
    global_evm_input = input_data; // Don't free this memory as we'll use it later
    global_gas_limit = gas_limit;
    global_allocator = allocator;
    global_sender_address = sender_address;
    global_call_pending = true;

    std.log.info("コントラクトアドレス: {s}", .{contract_address});
    std.log.info("送信者アドレス: {s}", .{sender_address});
    std.log.info("入力データ: 0x{s}", .{try utils.bytesToHex(allocator, input_data)});
    std.log.info("ガス上限: {d}", .{gas_limit});

    // トランザクションを作成
    const tx = types.Transaction{
        .sender = sender_address,
        .receiver = contract_address,
        .amount = 0,
        .tx_type = 2, // コントラクト呼び出し
        .evm_data = input_data,
        .gas_limit = gas_limit,
        .gas_price = 10, // デフォルトのガス価格を設定
    };

    // P2Pネットワーク上でトランザクションをブロードキャスト
    try p2p.broadcastEvmTransaction(tx);

    std.log.info("呼び出しトランザクションをブロードキャストしました", .{});

    // ブロードキャストと同時に、ローカルにもコントラクトがあるか確認
    if (blockchain.contract_storage.get(contract_address)) |_| {
        std.log.info("コントラクトがローカルに見つかりました: アドレス={s}", .{contract_address});

        // ローカルでトランザクションを実行（詳細なエラー情報付き）
        var tx_copy = tx; // Create a mutable copy of the transaction
        const result = blockchain.processEvmTransactionWithErrorDetails(&tx_copy) catch |err| {
            // 詳細なエラー情報はprocessEvmTransactionWithErrorDetails内で出力されるため、
            // ここでは簡潔なエラーのみ表示
            std.log.err("ローカルでのコントラクト呼び出しエラー: {any}", .{err});
            return;
        };

        // 実行結果を表示
        blockchain.logEvmResult(&tx_copy, result) catch |err| {
            std.log.err("結果ログ出力エラー: {any}", .{err});
        };

        // コールのフラグを下ろす（ローカル実行成功）
        global_call_pending = false;
    } else {
        std.log.info("コントラクトがローカルに見つかりません。チェーン同期後に実行します: アドレス={s}", .{contract_address});
        // global_call_pending はtrueのまま、チェーン同期後に実行される
    }
}

//------------------------------------------------------------------------------
// テスト
//------------------------------------------------------------------------------
test "トランザクションの初期化テスト" {
    const tx = types.Transaction{
        .sender = "Alice",
        .receiver = "Bob",
        .amount = 42,
    };
    try std.testing.expectEqualStrings("Alice", tx.sender);
    try std.testing.expectEqualStrings("Bob", tx.receiver);
    try std.testing.expectEqual(@as(u64, 42), tx.amount);
}

test "ブロックにトランザクションを追加" {
    var block = types.Block{
        .index = 0,
        .timestamp = 1234567890,
        .prev_hash = [_]u8{0} ** 32,
        .transactions = std.ArrayList(types.Transaction).init(std.testing.allocator),
        .nonce = 0,
        .data = "Test block",
        .hash = [_]u8{0} ** 32,
    };
    defer block.transactions.deinit();

    try block.transactions.append(types.Transaction{
        .sender = "Taro",
        .receiver = "Hanako",
        .amount = 100,
    });
    try std.testing.expectEqual(@as(usize, 1), block.transactions.items.len);
}

test "マイニングが先頭1バイト0のハッシュを生成できる" {
    var block = types.Block{
        .index = 0,
        .timestamp = 1672531200,
        .prev_hash = [_]u8{0} ** 32,
        .transactions = std.ArrayList(types.Transaction).init(std.testing.allocator),
        .nonce = 0,
        .data = "For Mining test",
        .hash = [_]u8{0} ** 32,
    };
    defer block.transactions.deinit();

    // 適当にトランザクションを追加
    try block.transactions.append(types.Transaction{ .sender = "A", .receiver = "B", .amount = 100 });

    // 初期ハッシュ
    block.hash = blockchain.calculateHash(&block);

    // 難易度1(先頭1バイトが0)を満たすまでマイニング
    blockchain.mineBlock(&block, 1);
    try std.testing.expectEqual(@as(u8, 0), block.hash[0]);
}

/// EVMバイトコード解析機能のテスト
///
/// 引数:
///     allocator: メモリアロケータ
///     bytecode_hex: テスト対象のバイトコード（16進数文字列）
///
/// 注意:
///     この関数はテスト用に作成されたもので、実際のブロックチェーン操作では使用されません。
pub fn test_evm_bytecode_analysis(allocator: std.mem.Allocator, bytecode_hex: []const u8) !void {
    const evm_debug = @import("evm_debug.zig");
    std.log.info("=== EVMバイトコード解析テスト ===", .{});
    std.log.info("バイトコード: {s}", .{bytecode_hex});

    // 16進文字列をバイナリに変換
    const bytecode = try @import("utils.zig").hexToBytes(allocator, bytecode_hex);
    defer allocator.free(bytecode);

    // バイトコードサイズの確認
    std.log.info("バイトコードサイズ: {d}バイト", .{bytecode.len});

    // Solidityバージョンの推測
    const version_info = evm_debug.guessSolidityVersion(bytecode);
    std.log.info("推定コンパイラバージョン: {s}", .{version_info});

    // バイトコードをHexdump形式で表示
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // 最初の32バイトを表示
    try evm_debug.hexdumpCodeContext(bytecode, 0, 32, buffer.writer());
    std.log.info("バイトコード（先頭部分）:\n{s}", .{buffer.items});
    buffer.clearRetainingCapacity();

    // 逆アセンブリ表示（先頭部分）
    std.log.info("\n=== バイトコード逆アセンブル（先頭部分）===", .{});
    try evm_debug.disassembleBytecode(bytecode, 0, 20, buffer.writer());
    std.log.info("\n{s}", .{buffer.items});
    buffer.clearRetainingCapacity();

    // デプロイコードとランタイムコードの境界を探す
    var constructor_end: usize = 0;
    var i: usize = 0;
    while (i < bytecode.len) : (i += 1) {
        if (i + 2 < bytecode.len and bytecode[i] == 0x60 and bytecode[i + 1] == 0x80 and i > 32 and bytecode[i - 1] != 0xf3) {
            constructor_end = i;
            break;
        }
    }

    if (constructor_end > 0) {
        std.log.info("\n=== コントラクト構造解析 ===", .{});
        std.log.info("コンストラクタコード長: {d}バイト", .{constructor_end});
        std.log.info("ランタイムコード長: {d}バイト", .{bytecode.len - constructor_end});

        // コンストラクタコードの終わり付近を表示
        if (constructor_end > 16) {
            std.log.info("\n=== コンストラクタ/ランタイム境界 ===", .{});
            try evm_debug.hexdumpCodeContext(bytecode, constructor_end - 8, 16, buffer.writer());
            std.log.info("\n{s}", .{buffer.items});
            buffer.clearRetainingCapacity();

            // 境界部分の逆アセンブリ
            std.log.info("\n=== 境界部分の逆アセンブル ===", .{});
            try evm_debug.disassembleBytecode(bytecode, constructor_end - 5, 10, buffer.writer());
            std.log.info("\n{s}", .{buffer.items});
            buffer.clearRetainingCapacity();
        }

        // ランタイムコードの先頭部分
        std.log.info("\n=== ランタイムコード（先頭部分）===", .{});
        try evm_debug.disassembleBytecode(bytecode, constructor_end, 15, buffer.writer());
        std.log.info("\n{s}", .{buffer.items});
        buffer.clearRetainingCapacity();
    } else {
        std.log.info("コンストラクタ/ランタイム境界が見つかりませんでした", .{});
    }

    // 潜在的なエラー原因を分析
    std.log.info("\n=== 潜在的なエラー分析 ===", .{});
    for ([_]usize{ 10, 32, 64 }) |pos| {
        if (pos < bytecode.len) {
            const opcode = bytecode[pos];
            const analysis = evm_debug.analyzeErrorCause(bytecode, pos);
            std.log.info("位置 {d} (0x{x:0>2}): {s}", .{ pos, opcode, analysis });
        }
    }

    std.log.info("\n=== 解析完了 ===", .{});
}
