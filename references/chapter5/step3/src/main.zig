const std = @import("std");
const crypto = std.crypto.hash;
const Sha256 = crypto.sha2.Sha256;

//------------------------------------------------------------------------------
// デバッグ出力関連
//------------------------------------------------------------------------------
//
// このフラグが true であれば、デバッグ用のログ出力を行います。
// コンパイル時に最適化されるため、false に設定されている場合、
// debugLog 関数は実行コードから除去されます。
const debug_logging = false;

/// debugLog:
/// デバッグログを出力するためのヘルパー関数です。
/// ※ debug_logging が true の場合のみ std.debug.print を呼び出します。
fn debugLog(comptime format: []const u8, args: anytype) void {
    if (comptime debug_logging) {
        std.debug.print(format, args);
    }
}

//------------------------------------------------------------------------------
// データ構造定義
//------------------------------------------------------------------------------

// Transaction 構造体
// ブロックチェーン上の「取引」を表現します。
// 送信者、受信者、取引金額の３要素のみ保持します。
const Transaction = struct {
    sender: []const u8, // 送信者のアドレスまたは識別子(文字列)
    receiver: []const u8, // 受信者のアドレスまたは識別子(文字列)
    amount: u64, // 取引金額(符号なし64ビット整数)
};

// Block 構造体
// ブロックチェーン上の「ブロック」を表現します。
// ブロック番号、生成時刻、前ブロックのハッシュ、取引リスト、PoW用の nonce、
// 追加データ、そして最終的なブロックハッシュを保持します。
const Block = struct {
    index: u32, // ブロック番号(0から始まる連番)
    timestamp: u64, // ブロック生成時のUNIXタイムスタンプ
    prev_hash: [32]u8, // 前のブロックのハッシュ(32バイト固定)
    transactions: std.ArrayList(Transaction), // ブロック内の複数の取引を保持する動的配列
    nonce: u64, // Proof of Work (PoW) 採掘用のnonce値
    data: []const u8, // 任意の追加データ(文字列など)
    hash: [32]u8, // このブロックのSHA-256ハッシュ(32バイト固定)
};

//------------------------------------------------------------------------------
// バイト変換ヘルパー関数
//------------------------------------------------------------------------------
//
// ここでは数値型 (u32, u64) をリトルエンディアンのバイト配列に変換します。
// また、値がu8の範囲を超えた場合はパニックします。

/// truncateU32ToU8:
/// u32 の値を u8 に変換(値が 0xff を超えるとエラー)
fn truncateU32ToU8(x: u32) u8 {
    if (x > 0xff) {
        @panic("u32 value out of u8 range");
    }
    return @truncate(x);
}

/// truncateU64ToU8:
/// u64 の値を u8 に変換(値が 0xff を超えるとエラー)
fn truncateU64ToU8(x: u64) u8 {
    if (x > 0xff) {
        @panic("u64 value out of u8 range");
    }
    return @truncate(x);
}

/// toBytesU32:
/// u32 の値をリトルエンディアンの 4 バイト配列に変換して返す。
fn toBytesU32(value: u32) [4]u8 {
    var bytes: [4]u8 = undefined;
    bytes[0] = truncateU32ToU8(value & 0xff);
    bytes[1] = truncateU32ToU8((value >> 8) & 0xff);
    bytes[2] = truncateU32ToU8((value >> 16) & 0xff);
    bytes[3] = truncateU32ToU8((value >> 24) & 0xff);
    return bytes;
}

/// toBytesU64:
/// u64 の値をリトルエンディアンの 8 バイト配列に変換して返す。
fn toBytesU64(value: u64) [8]u8 {
    var bytes: [8]u8 = undefined;
    bytes[0] = truncateU64ToU8(value & 0xff);
    bytes[1] = truncateU64ToU8((value >> 8) & 0xff);
    bytes[2] = truncateU64ToU8((value >> 16) & 0xff);
    bytes[3] = truncateU64ToU8((value >> 24) & 0xff);
    bytes[4] = truncateU64ToU8((value >> 32) & 0xff);
    bytes[5] = truncateU64ToU8((value >> 40) & 0xff);
    bytes[6] = truncateU64ToU8((value >> 48) & 0xff);
    bytes[7] = truncateU64ToU8((value >> 56) & 0xff);
    return bytes;
}

/// toBytes:
/// 任意の型 T の値をそのメモリ表現に基づいてバイト列(スライス)に変換する。
/// u32, u64 の場合は専用の関数を呼び出し、それ以外は @bitCast で固定長配列に変換します。
fn toBytes(comptime T: type, value: T) []const u8 {
    if (T == u32) {
        return toBytesU32(@as(u32, value))[0..];
    } else if (T == u64) {
        return toBytesU64(@as(u64, value))[0..];
    } else {
        const bytes: [@sizeOf(T)]u8 = @bitCast(value);
        return bytes[0..];
    }
}

//------------------------------------------------------------------------------
// ハッシュ計算とマイニング処理
//------------------------------------------------------------------------------
//
// calculateHash 関数では、ブロック内の各フィールドを連結して
// SHA-256 のハッシュを計算します。
// mineBlock 関数は、nonce をインクリメントしながら
// meetsDifficulty による難易度チェックをパスするハッシュを探します。

/// calculateHash:
/// 指定されたブロックの各フィールドをバイト列に変換し、
/// その連結結果から SHA-256 ハッシュを計算して返す関数。
fn calculateHash(block: *const Block) [32]u8 {
    var hasher = Sha256.init(.{});

    // nonce の値をバイト列に変換(8バイト)し、デバッグ用に出力
    const nonce_bytes = toBytesU64(block.nonce);
    debugLog("nonce bytes: ", .{});
    if (comptime debug_logging) {
        for (nonce_bytes) |byte| {
            std.debug.print("{x:0>2},", .{byte});
        }
        std.debug.print("\n", .{});
    }

    // ブロック番号 (u32) をバイト列に変換して追加
    hasher.update(toBytes(u32, block.index));
    // タイムスタンプ (u64) をバイト列に変換して追加
    hasher.update(toBytes(u64, block.timestamp));
    // nonce のバイト列を追加
    hasher.update(nonce_bytes[0..]);
    // 前ブロックのハッシュ(32バイト)を追加
    hasher.update(&block.prev_hash);

    // すべてのトランザクションについて、各フィールドを追加
    for (block.transactions.items) |tx| {
        hasher.update(tx.sender);
        hasher.update(tx.receiver);
        const amount_bytes = toBytesU64(tx.amount);
        hasher.update(&amount_bytes);
    }
    // 追加データをハッシュに追加
    hasher.update(block.data);

    // 最終的なハッシュ値を計算
    const hash = hasher.finalResult();
    debugLog("nonce: {d}, hash: {x}\n", .{ block.nonce, hash });
    return hash;
}

/// meetsDifficulty:
/// ハッシュ値の先頭 'difficulty' バイトがすべて 0 であれば true を返す。
fn meetsDifficulty(hash: [32]u8, difficulty: u8) bool {
    // difficulty が 32 を超える場合は 32 に丸める
    const limit = if (difficulty <= 32) difficulty else 32;
    for (hash[0..limit]) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

/// mineBlock:
/// 指定された難易度を満たすハッシュが得られるまで、
/// nonce の値を増やしながらハッシュ計算を繰り返す関数。
fn mineBlock(block: *Block, difficulty: u8) void {
    while (true) {
        const new_hash = calculateHash(block);
        if (meetsDifficulty(new_hash, difficulty)) {
            block.hash = new_hash;
            break;
        }
        block.nonce += 1;
    }
}

//--------------------------------------
// P2P用ピア構造体
//--------------------------------------
const Peer = struct {
    address: std.net.Address,
    stream: std.net.Stream,
};

//--------------------------------------
// 簡易チェイン管理用: ブロック配列
//--------------------------------------
var chain_store = std.ArrayList(Block).init(std.heap.page_allocator);

// addBlock: 受け取ったブロックをチェインに追加（本当は検証なども入れる）
fn addBlock(new_block: Block) void {
    // ここでは単純に末尾へ追加
    // (実際は既存チェインと整合性をとるための検証/フォーク処理などが必要)
    chain_store.append(new_block) catch {};
    std.log.info("Added new block index={d}, nonce={d}, hash={x}", .{ new_block.index, new_block.nonce, new_block.hash });
}

//--------------------------------------
// メッセージ受信処理: ConnHandler
//--------------------------------------
const ConnHandler = struct {
    fn run(conn: std.net.Server.Connection) !void {
        defer conn.stream.close();
        std.log.info("Accepted: {any}", .{conn.address});

        var reader = conn.stream.reader();
        var buf: [256]u8 = undefined;

        while (true) {
            const n = try reader.read(&buf);
            if (n == 0) {
                std.log.info("Peer {any} disconnected.", .{conn.address});
                break;
            }
            const msg_slice = buf[0..n];
            std.log.info("[Received] {s}", .{msg_slice});

            // 簡易メッセージ解析
            if (std.mem.startsWith(u8, msg_slice, "BLOCK:")) {
                // "BLOCK:" の後ろを取り出してJSONパースする
                const json_part = msg_slice[6..];
                const new_block = parseBlockJson(json_part) catch |err| {
                    std.log.err("Failed parseBlockJson: {any}", .{err});
                    continue;
                };
                // チェインに追加
                addBlock(new_block);
            } else {
                // それ以外はログだけ
                std.log.info("Unknown message: {s}", .{msg_slice});
            }
        }
    }
};

//--------------------------------------
// クライアント送信用スレッド
//--------------------------------------
const SendHandler = struct {
    fn run(peer: Peer) !void {
        defer peer.stream.close();
        std.log.info("Connected to peer {any}", .{peer.address});

        var stdin_file = std.io.getStdIn();
        const reader = stdin_file.reader();
        var line_buffer: [256]u8 = undefined;

        while (true) {
            std.debug.print("Type message (Ctrl+D to quit): ", .{});
            const maybe_line = try reader.readUntilDelimiterOrEof(line_buffer[0..], '\n');
            if (maybe_line == null) {
                std.log.info("EOF -> Stop sending loop.", .{});
                break;
            }
            const line_slice = maybe_line.?;
            var writer = peer.stream.writer();
            try writer.writeAll(line_slice);
        }
    }
};

//--------------------------------------
// ブロックJSONパース (簡易実装例)
//--------------------------------------
fn parseBlockJson(json_slice: []const u8) !Block {
    // 本格的な JSON デコードは std.json を使いますが、
    // ここではデモ用に「index,nonce,hash」しか取り出さない簡易版にしています。
    // 実際には transactions や prev_hash などもしっかりパースしてください。

    // 例： "{"index":0,"timestamp":1672531200,"nonce":42,...}"
    // 実装例では適当なパースや固定値で作成しているだけです
    // 学習目的であればここを工夫してみましょう。

    // ダミーで new_block を返す
    const block_allocator = std.heap.page_allocator;
    var new_block = Block{
        .index = 9999999,
        .timestamp = std.time.posixTime() catch 0, // 適当な値
        .prev_hash = [_]u8{0} ** 32,
        .transactions = std.ArrayList(Transaction).init(block_allocator),
        .nonce = 0,
        .data = "Received Block",
        .hash = [_]u8{0} ** 32,
    };

    // TODO: ちゃんとした JSON 解析で fill するのが本来の処理
    // ここでは簡易的に index=2, nonce=555 などの例
    // (実際にはregexや std.json を使って取り出す)
    if (std.mem.containsAtLeast(u8, json_slice, "nonce")) {
        new_block.nonce = 555;
    }
    if (std.mem.containsAtLeast(u8, json_slice, "index")) {
        new_block.index = 2;
    }
    // 受信後にハッシュも再計算(実際には送られてきた hash と比較したりもする)
    new_block.hash = calculateHash(&new_block);

    return new_block;
}

//--------------------------------------
// main 関数
//--------------------------------------
pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const args = std.process.argsAlloc(gpa) catch |err| {
        std.log.err("arg parse fail: {any}", .{err});
        return;
    };
    defer std.process.argsFree(gpa, args);

    if (args.len < 3) {
        std.log.info("Usage:\n {s} --listen <port>\n or\n {s} --connect <host:port>\n", .{ args[0], args[0] });
        return;
    }

    // -----------------------
    // 事前にジェネシスブロックを作って chain_store に追加
    // -----------------------
    var genesis = Block{
        .index = 0,
        .timestamp = 1672531200,
        .prev_hash = [_]u8{0} ** 32,
        .transactions = std.ArrayList(Transaction).init(std.heap.page_allocator),
        .nonce = 0,
        .data = "Hello, Zig Blockchain!",
        .hash = [_]u8{0} ** 32,
    };
    // 例として1つトランザクションを追加
    genesis.transactions.append(Transaction{ .sender = "Alice", .receiver = "Bob", .amount = 100 }) catch {};
    // 採掘して追加
    mineBlock(&genesis, 1);
    chain_store.append(genesis) catch {};
    std.log.info("Initialized chain with genesis block index=0", .{});

    const mode = args[1];
    if (std.mem.eql(u8, mode, "--listen")) {
        //-----------------------------
        // サーバーモード
        //-----------------------------
        const port_str = args[2];
        const port_num = std.fmt.parseInt(u16, port_str, 10) catch {
            std.log.err("Invalid port: {s}", .{port_str});
            return;
        };
        var address = try std.net.Address.resolveIp("0.0.0.0", port_num);
        var listener = try address.listen(.{});
        defer listener.deinit();

        std.log.info("Listening on 0.0.0.0:{d}", .{port_num});
        while (true) {
            const conn = try listener.accept();
            _ = try std.Thread.spawn(.{}, ConnHandler.run, .{conn});
        }
    } else if (std.mem.eql(u8, mode, "--connect")) {
        //-----------------------------
        // クライアントモード
        //-----------------------------
        const hostport = args[2];
        var tokenizer = std.mem.tokenizeScalar(u8, hostport, ':');
        const host_str = tokenizer.next() orelse {
            std.log.err("Please specify <host:port>", .{});
            return;
        };
        const port_str = tokenizer.next() orelse {
            std.log.err("No port after ':'", .{});
            return;
        };
        if (tokenizer.next() != null) {
            std.log.err("Too many ':' in {s}", .{hostport});
            return;
        }
        const port_num = std.fmt.parseInt(u16, port_str, 10) catch {
            std.log.err("Invalid port: {s}", .{port_str});
            return;
        };
        std.log.info("Connecting to {s}:{d}...", .{ host_str, port_num });

        const remote_addr = try std.net.Address.resolveIp(host_str, port_num);
        var socket = try std.net.tcpConnectToAddress(remote_addr);
        // クライアントでは送信専用スレッドを起動
        const peer = Peer{ .address = remote_addr, .stream = socket };
        _ = try std.Thread.spawn(.{}, SendHandler.run, .{peer});

        // メインスレッドで受信
        var reader = socket.reader();
        var buf: [256]u8 = undefined;
        while (true) {
            const n = try reader.read(&buf);
            if (n == 0) {
                std.log.info("Server disconnected.", .{});
                break;
            }
            const msg_slice = buf[0..n];
            std.log.info("[Recv] {s}", .{msg_slice});

            if (std.mem.startsWith(u8, msg_slice, "BLOCK:")) {
                const json_part = msg_slice[6..];
                const new_block = parseBlockJson(json_part) catch |err| {
                    std.log.err("parseBlockJson err: {any}", .{err});
                    continue;
                };
                addBlock(new_block);
            } else {
                std.log.info("Unknown msg: {s}", .{msg_slice});
            }
        }
    } else {
        std.log.err("Invalid mode: {s}", .{mode});
    }
}

//------------------------------------------------------------------------------
// テストコード
//------------------------------------------------------------------------------
//
// 以下の test ブロックは、各関数の動作を検証するための単体テストです。
// Zig の標準ライブラリ std.testing を使ってテストが実行されます。

/// ブロックを初期化するヘルパー関数(テスト用)
fn createTestBlock(allocator: std.mem.Allocator) !Block {
    var block = Block{
        .index = 0,
        .timestamp = 1672531200,
        .prev_hash = [_]u8{0} ** 32,
        .transactions = std.ArrayList(Transaction).init(allocator),
        .data = "Test Block",
        .nonce = 0,
        .hash = [_]u8{0} ** 32,
    };

    try block.transactions.append(Transaction{
        .sender = "TestSender",
        .receiver = "TestReceiver",
        .amount = 100,
    });

    return block;
}

test "トランザクション作成のテスト" {
    const tx = Transaction{
        .sender = "Alice",
        .receiver = "Bob",
        .amount = 50,
    };
    try std.testing.expectEqualStrings("Alice", tx.sender);
    try std.testing.expectEqualStrings("Bob", tx.receiver);
    try std.testing.expectEqual(@as(u64, 50), tx.amount);
}

test "ブロック作成のテスト" {
    const allocator = std.testing.allocator;
    var block = try createTestBlock(allocator);
    defer block.transactions.deinit();

    try std.testing.expectEqual(@as(u32, 0), block.index);
    try std.testing.expectEqual(@as(u64, 1672531200), block.timestamp);
    try std.testing.expectEqualStrings("Test Block", block.data);
}

test "バイト変換のテスト" {
    // u32 の変換テスト
    const u32_value: u32 = 0x12345678;
    const u32_bytes = toBytesU32(u32_value);
    try std.testing.expectEqual(u32_bytes[0], 0x78);
    try std.testing.expectEqual(u32_bytes[1], 0x56);
    try std.testing.expectEqual(u32_bytes[2], 0x34);
    try std.testing.expectEqual(u32_bytes[3], 0x12);

    // u64 の変換テスト
    const u64_value: u64 = 0x1234567890ABCDEF;
    const u64_bytes = toBytesU64(u64_value);
    try std.testing.expectEqual(u64_bytes[0], 0xEF);
    try std.testing.expectEqual(u64_bytes[7], 0x12);
}

test "ハッシュ計算のテスト" {
    const allocator = std.testing.allocator;
    var block = try createTestBlock(allocator);
    defer block.transactions.deinit();

    const hash = calculateHash(&block);
    // ハッシュの長さが 32 バイトであることを確認
    try std.testing.expectEqual(@as(usize, 32), hash.len);
    // ハッシュが全て 0 でないことを確認
    var all_zeros = true;
    for (hash) |byte| {
        if (byte != 0) {
            all_zeros = false;
            break;
        }
    }
    try std.testing.expect(!all_zeros);
}

test "マイニングのテスト" {
    const allocator = std.testing.allocator;
    var block = try createTestBlock(allocator);
    defer block.transactions.deinit();

    // 難易度 1 で採掘し、先頭1バイトが 0 になることを期待
    mineBlock(&block, 1);
    try std.testing.expectEqual(@as(u8, 0), block.hash[0]);
}

test "難易度チェックのテスト" {
    var hash = [_]u8{0} ** 32;
    // 全て 0 の場合、どの難易度でも true を返す
    try std.testing.expect(meetsDifficulty(hash, 0));
    try std.testing.expect(meetsDifficulty(hash, 1));
    try std.testing.expect(meetsDifficulty(hash, 32));

    // 先頭バイトが 0 以外の場合、難易度 1 では false を返す
    hash[0] = 1;
    try std.testing.expect(!meetsDifficulty(hash, 1));
}

test "トランザクションリストのテスト" {
    const allocator = std.testing.allocator;
    var block = try createTestBlock(allocator);
    defer block.transactions.deinit();

    // 追加のトランザクションを追加
    try block.transactions.append(Transaction{
        .sender = "Carol",
        .receiver = "Dave",
        .amount = 75,
    });

    try std.testing.expectEqual(@as(usize, 2), block.transactions.items.len);
    try std.testing.expectEqualStrings("TestSender", block.transactions.items[0].sender);
    try std.testing.expectEqualStrings("Carol", block.transactions.items[1].sender);
}

test "ブロック改ざん検出テスト" {
    const allocator = std.testing.allocator;
    var block = try createTestBlock(allocator);
    defer block.transactions.deinit();

    // 通常のハッシュ
    const originalHash = calculateHash(&block);

    // 改ざん(トランザクションの金額を100->999に変える)
    block.transactions.items[0].amount = 999;
    const tamperedHash = calculateHash(&block);

    // 改ざん前後のハッシュが異なることを期待
    try std.testing.expect(!std.mem.eql(u8, originalHash[0..], tamperedHash[0..]));
}
