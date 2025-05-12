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
///     --gas <ガス上限>: EVMバイトコード実行時のガス上限（デフォルト: 1000000）
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
        return;
    }

    // EVMモード変数
    var evm_mode = false;
    var evm_bytecode: []const u8 = "";
    var evm_input: []const u8 = "";
    var evm_gas_limit: usize = 1000000; // デフォルトガス上限

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
        } else if (std.mem.eql(u8, arg, "--gas")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--gas フラグの後にガス上限が必要です", .{});
                return;
            }
            evm_gas_limit = try std.fmt.parseInt(usize, args[i], 10);
        } else if (self_port == 0 and !evm_mode) {
            // 従来の方式（最初の引数はポート番号）
            self_port = try std.fmt.parseInt(u16, arg, 10);
        } else if (!evm_mode) {
            // 従来の方式（追加の引数はピアアドレス）
            try known_peers.append(arg);
        }
    }

    // EVMモードの場合はEVMを実行して終了する
    if (evm_mode) {
        try runEvm(gpa, evm_bytecode, evm_input, evm_gas_limit);
        return;
    }

    if (self_port == 0) {
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
