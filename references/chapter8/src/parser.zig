//! ブロックチェーンデータシリアル化・解析モジュール
//!
//! このモジュールはブロックチェーンデータ構造をJSONにシリアル化し、
//! JSONデータをブロックチェーン構造に解析する機能を提供します。
//! ハッシュなどのバイナリデータを16進文字列にエンコード・デコードし、
//! 不正な入力データに対する包括的なエラー処理を提供します。

const std = @import("std");
const crypto = std.crypto.hash;
const Sha256 = crypto.sha2.Sha256;
const types = @import("types.zig");
const logger = @import("logger.zig");
const utils = @import("utils.zig");
const chainError = @import("errors.zig").ChainError;

/// プルーフオブワークマイニングの難易度設定
const DIFFICULTY: u8 = 2;

/// ローカルチェーンストア（テスト目的）
var chain_store = std.ArrayList(types.Block).init(std.heap.page_allocator);

/// バイナリデータを16進文字列表現に変換する
///
/// バイトスライスを受け取り、各バイトを2桁の16進表現に変換します。
/// バイナリハッシュ値を人間が読める形式でJSON安全な文字列に
/// エンコードするために使用されます。
///
/// 引数:
///     slice: エンコードするバイナリデータ
///     allocator: 出力文字列用のメモリアロケータ
///
/// 戻り値:
///     []const u8: 割り当てられた16進文字列（呼び出し元がメモリを所有）
///
/// エラー:
///     提供されたアロケータからの割り当てエラー
pub fn hexEncode(slice: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var buf = try allocator.alloc(u8, slice.len * 2);
    var j: usize = 0;
    for (slice) |byte| {
        const high = byte >> 4;
        const low = byte & 0x0F;
        buf[j] = if (high < 10) '0' + high else 'a' + (high - 10);
        j += 1;
        buf[j] = if (low < 10) '0' + low else 'a' + (low - 10);
        j += 1;
    }
    return buf;
}

/// 16進文字列をバイナリデータに変換する
///
/// 16進文字列をバイナリデータにデコードします。16進文字の各ペアは
/// 出力の1バイトになります。入力が正しい形式かを検証します。
///
/// 引数:
///     src: ソースの16進文字列
///     dst: バイナリ出力用の宛先バッファ
///
/// 戻り値:
///     usize: デコードされたバイト数
///
/// エラー:
///     chainError.InvalidHexLength: 入力の長さが偶数でない場合
///     chainError.InvalidHexChar: 入力に16進文字以外が含まれる場合
fn hexDecode(src: []const u8, dst: *[256]u8) !usize {
    // 書き込みを始める前に入力全体が固定長バッファへ収まるか確認する。
    // P2P入力は信頼できないため、偶数長でも256バイトを超えるhexを
    // dstへ書くとprocessがpanicしてしまう。
    if (src.len % 2 != 0 or src.len / 2 > dst.len) return chainError.InvalidHexLength;
    var i: usize = 0;
    while (i < src.len) : (i += 2) {
        const hi = parseHexDigit(src[i]) catch return chainError.InvalidHexChar;
        const lo = parseHexDigit(src[i + 1]) catch return chainError.InvalidHexChar;
        dst[i / 2] = (hi << 4) | lo;
    }
    return src.len / 2;
}

test "hex decoder rejects input larger than its destination" {
    var destination: [256]u8 = undefined;
    const oversized = [_]u8{'0'} ** 514;
    try std.testing.expectError(chainError.InvalidHexLength, hexDecode(&oversized, &destination));
}

test "block parser rejects non-integer or out-of-range consensus numbers" {
    try std.testing.expectError(error.InvalidFormat, parseBlockJson("{\"index\":1.5}"));
    try std.testing.expectError(error.InvalidFormat, parseBlockJson("{\"index\":4294967296}"));
    try std.testing.expectError(error.InvalidFormat, parseBlockJson("{\"timestamp\":-1.5}"));
    try std.testing.expectError(error.InvalidFormat, parseBlockJson("{\"nonce\":1.5}"));
}

/// 単一の16進数字文字を解析する
///
/// 文字（'0'～'9'、'a'～'f'、'A'～'F'）をその数値（0～15）に変換します。
///
/// 引数:
///     c: 解析する文字
///
/// 戻り値:
///     u8: 数値（0～15）
///
/// エラー:
///     error.InvalidHexChar: 文字が有効な16進数字でない場合
fn parseHexDigit(c: u8) !u8 {
    switch (c) {
        '0'...'9' => return c - '0',
        'a'...'f' => return 10 + (c - 'a'),
        'A'...'F' => return 10 + (c - 'A'),
        else => return error.InvalidHexChar,
    }
}

fn deinitOwnedTransaction(allocator: std.mem.Allocator, tx: *types.Transaction) void {
    allocator.free(tx.sender);
    allocator.free(tx.receiver);
    tx.* = undefined;
}

fn deinitOwnedBlock(allocator: std.mem.Allocator, block: *types.Block) void {
    for (block.transactions.items) |*tx| deinitOwnedTransaction(allocator, tx);
    block.transactions.deinit();
    allocator.free(block.data);
    block.* = undefined;
}

/// `parseBlockJson` が返したブロックをチェーンへ移譲しなかった場合に解放する。
pub fn deinitParsedBlock(block: *types.Block) void {
    deinitOwnedBlock(std.heap.page_allocator, block);
}

fn cloneOwnedTransaction(allocator: std.mem.Allocator, tx: types.Transaction) !types.Transaction {
    const sender = try allocator.dupe(u8, tx.sender);
    errdefer allocator.free(sender);
    const receiver = try allocator.dupe(u8, tx.receiver);
    errdefer allocator.free(receiver);
    return .{ .sender = sender, .receiver = receiver, .amount = tx.amount };
}

fn appendClonedTransaction(
    transactions: *std.ArrayList(types.Transaction),
    allocator: std.mem.Allocator,
    tx: types.Transaction,
) !void {
    var cloned = try cloneOwnedTransaction(allocator, tx);
    errdefer deinitOwnedTransaction(allocator, &cloned);
    try transactions.append(cloned);
}

fn cloneOwnedBlock(allocator: std.mem.Allocator, block: types.Block) !types.Block {
    var cloned = types.Block{
        .index = block.index,
        .timestamp = block.timestamp,
        .prev_hash = block.prev_hash,
        .transactions = std.ArrayList(types.Transaction).init(allocator),
        .nonce = block.nonce,
        .data = try allocator.dupe(u8, block.data),
        .hash = block.hash,
    };
    errdefer deinitOwnedBlock(allocator, &cloned);
    for (block.transactions.items) |tx| {
        try appendClonedTransaction(&cloned.transactions, allocator, tx);
    }
    return cloned;
}

/// トランザクションリストをJSON配列文字列にシリアル化する
///
/// トランザクション構造体のArrayListを、ネットワーク送信や保存のための
/// JSON配列文字列表現に変換します。
///
/// 引数:
///     transactions: トランザクション構造体のArrayList
///     allocator: 出力文字列用のメモリアロケータ
///
/// 戻り値:
///     []const u8: 割り当てられたJSON文字列（呼び出し元がメモリを所有）
///
/// エラー:
///     割り当てまたはフォーマットエラー
fn serializeTransactions(transactions: std.ArrayList(types.Transaction), allocator: std.mem.Allocator) ![]const u8 {
    if (transactions.items.len == 0) {
        return allocator.dupe(u8, "[]");
    }

    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();
    try list.appendSlice("[");

    for (transactions.items, 0..) |tx, i| {
        if (i > 0) {
            try list.appendSlice(",");
        }
        const sender_json = try std.json.stringifyAlloc(allocator, tx.sender, .{});
        defer allocator.free(sender_json);
        const receiver_json = try std.json.stringifyAlloc(allocator, tx.receiver, .{});
        defer allocator.free(receiver_json);
        const tx_json = try std.fmt.allocPrintZ(allocator, "{{\"sender\":{s},\"receiver\":{s},\"amount\":{d}}}", .{ sender_json, receiver_json, tx.amount });
        defer allocator.free(tx_json);
        try list.appendSlice(tx_json);
    }

    try list.appendSlice("]");
    return list.toOwnedSlice();
}

/// ブロック構造体をJSON文字列にシリアル化する
///
/// ブロック構造体をネットワーク送信や保存用のJSON文字列表現に変換します。
/// バイナリハッシュデータを16進文字列としてエンコードします。
///
/// 引数:
///     block: シリアル化するブロック構造体
///
/// 戻り値:
///     []const u8: 割り当てられたJSON文字列（呼び出し元がメモリを所有）
///
/// エラー:
///     割り当てまたはエンコードエラー
pub fn serializeBlock(block: types.Block) ![]const u8 {
    const allocator = std.heap.page_allocator;

    // バイナリハッシュを16進文字列に変換
    const hash_str = hexEncode(block.hash[0..], allocator) catch unreachable;
    const prev_hash_str = hexEncode(block.prev_hash[0..], allocator) catch unreachable;

    // トランザクション配列をシリアル化
    const tx_str = try serializeTransactions(block.transactions, allocator);

    // dataは利用者入力を含むため、引用符やバックスラッシュをJSON escapeする
    const data_json = try std.json.stringifyAlloc(allocator, block.data, .{});
    defer allocator.free(data_json);

    // すべてのフィールドをJSONオブジェクト文字列に結合
    const json = try std.fmt.allocPrintZ(allocator, "{{\"index\":{d},\"timestamp\":{d},\"nonce\":{d},\"data\":{s},\"prev_hash\":\"{s}\",\"hash\":\"{s}\",\"transactions\":{s}}}", .{ block.index, block.timestamp, block.nonce, data_json, prev_hash_str, hash_str, tx_str });

    // 一時的な割り当てを解放
    allocator.free(hash_str);
    allocator.free(prev_hash_str);
    allocator.free(tx_str);

    return json;
}

test "block JSON round trip escapes quoted text" {
    var transactions = std.ArrayList(types.Transaction).init(std.testing.allocator);
    defer transactions.deinit();
    try transactions.append(.{
        .sender = "Alice \\\"A\\\"",
        .receiver = "Bob\\\\B",
        .amount = 42,
    });
    const block = types.Block{
        .index = 1,
        .timestamp = 1_672_531_201,
        .prev_hash = [_]u8{0x11} ** 32,
        .transactions = transactions,
        .nonce = 7,
        .data = "say \\\"hello\\\" \\\\ path",
        .hash = [_]u8{0x22} ** 32,
    };

    const json = try serializeBlock(block);
    defer std.heap.page_allocator.free(json);
    var decoded = try parseBlockJson(json);
    defer deinitParsedBlock(&decoded);

    try std.testing.expectEqualStrings(block.data, decoded.data);
    try std.testing.expectEqualStrings(block.transactions.items[0].sender, decoded.transactions.items[0].sender);
    try std.testing.expectEqualStrings(block.transactions.items[0].receiver, decoded.transactions.items[0].receiver);
}

/// JSON文字列をブロック構造体に解析する
///
/// ブロックのJSON文字列表現をブロック構造体に戻します。
/// 16進エンコードされたハッシュデータのデコードを処理し、
/// 入力の構造を検証します。
///
/// 引数:
///     json_slice: 解析するJSON文字列
///
/// 戻り値:
///     types.Block: 解析されたブロック構造体
///
/// エラー:
///     様々な形式および解析エラー
///
/// 注意:
///     この関数はブロック内の文字列フィールド用にメモリを割り当てます。
///     ブロックが不要になった時点で、呼び出し元が解放する必要があります。
pub fn parseBlockJson(json_slice: []const u8) !types.Block {
    std.log.debug("parseBlockJson start", .{});
    const output_allocator = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(output_allocator);
    defer arena.deinit();
    const block_allocator = arena.allocator();

    // JSON文字列を汎用JSON値に解析
    std.log.debug("parseBlockJson start parsed", .{});
    const parsed = try std.json.parseFromSlice(std.json.Value, block_allocator, json_slice, .{});
    std.log.debug("parseBlockJson end parsed", .{});
    defer parsed.deinit();
    const root_value = parsed.value;

    // ルートがオブジェクトであることを確認
    const obj = switch (root_value) {
        .object => |o| o,
        else => return chainError.InvalidFormat,
    };

    // デフォルト値でブロックを初期化
    var b = types.Block{
        .index = 0,
        .timestamp = 0,
        .prev_hash = [_]u8{0} ** 32,
        .transactions = std.ArrayList(types.Transaction).init(block_allocator),
        .nonce = 0,
        .data = "P2P Received Block",
        .hash = [_]u8{0} ** 32,
    };

    std.log.debug("parseBlockJson start parser", .{});

    // indexフィールドを解析
    if (obj.get("index")) |idx_val| {
        const idx_num: i64 = switch (idx_val) {
            .integer => idx_val.integer,
            else => return error.InvalidFormat,
        };
        if (idx_num < 0 or idx_num > @as(i64, std.math.maxInt(u32))) {
            return error.InvalidFormat;
        }
        b.index = @intCast(idx_num);
    }

    // timestampフィールドを解析
    if (obj.get("timestamp")) |ts_val| {
        const ts_num: i64 = switch (ts_val) {
            .integer => if (ts_val.integer < 0) return error.InvalidFormat else ts_val.integer,
            else => return error.InvalidFormat,
        };
        b.timestamp = @intCast(ts_num);
    }

    // nonceフィールドを解析
    if (obj.get("nonce")) |nonce_val| {
        const nonce_num: i64 = switch (nonce_val) {
            .integer => nonce_val.integer,
            else => return error.InvalidFormat,
        };
        if (nonce_num < 0 or nonce_num > @as(f64, std.math.maxInt(u64))) {
            return error.InvalidFormat;
        }
        b.nonce = @intCast(nonce_num);
    }

    // prev_hashフィールドを解析（16進エンコード）
    if (obj.get("prev_hash")) |ph_val| {
        const ph_str = switch (ph_val) {
            .string => ph_val.string,
            else => return error.InvalidFormat,
        };
        var ph_buf: [256]u8 = undefined;
        const ph_len = try hexDecode(ph_str, &ph_buf);
        if (ph_len != 32) return error.InvalidFormat;
        var tmp_ph: [32]u8 = undefined;
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            tmp_ph[i] = ph_buf[i];
        }
        b.prev_hash = tmp_ph;
    }

    // hashフィールドを解析（16進エンコード）
    if (obj.get("hash")) |hash_val| {
        const hash_str = switch (hash_val) {
            .string => hash_val.string,
            else => return error.InvalidFormat,
        };
        var long_buf: [256]u8 = undefined;
        const actual_len = try hexDecode(hash_str, &long_buf);
        if (actual_len != 32) return error.InvalidFormat;
        var tmp_hash: [32]u8 = undefined;
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            tmp_hash[i] = long_buf[i];
        }
        b.hash = tmp_hash;
    }

    // dataフィールドを解析
    if (obj.get("data")) |data_val| {
        const data_str = switch (data_val) {
            .string => data_val.string,
            else => return error.InvalidFormat,
        };
        b.data = try block_allocator.dupe(u8, data_str);
    }

    // transactions配列を解析
    if (obj.get("transactions")) |tx_val| {
        switch (tx_val) {
            // トランザクションが直接JSON配列の場合の処理
            .array => {
                std.log.debug("Transactions field is directly an array. ", .{});
                const tx_items = tx_val.array.items;
                if (tx_items.len > 0) {
                    std.log.info("tx_items.len = {d}", .{tx_items.len});
                    for (tx_items, 0..tx_items.len) |elem, idx| {
                        std.log.info("Processing transaction element {d}", .{idx});
                        const tx_obj = switch (elem) {
                            .object => |o| o,
                            else => {
                                std.log.err("Transaction element {d} is not an object.", .{idx});
                                return error.InvalidFormat;
                            },
                        };

                        // senderフィールドを解析
                        const sender = switch (tx_obj.get("sender") orelse {
                            std.log.err("Transaction element {d}: missing 'sender' field.", .{idx});
                            return error.InvalidFormat;
                        }) {
                            .string => |s| s,
                            else => {
                                std.log.err("Transaction element {d}: 'sender' field is not a string.", .{idx});
                                return error.InvalidFormat;
                            },
                        };
                        const sender_copy = try block_allocator.dupe(u8, sender);

                        // receiverフィールドを解析
                        const receiver = switch (tx_obj.get("receiver") orelse {
                            std.log.err("Transaction element {d}: missing 'receiver' field.", .{idx});
                            return error.InvalidFormat;
                        }) {
                            .string => |s| s,
                            else => {
                                std.log.err("Transaction element {d}: 'receiver' field is not a string.", .{idx});
                                return error.InvalidFormat;
                            },
                        };
                        const receiver_copy = try block_allocator.dupe(u8, receiver);

                        // amountフィールドを解析
                        const amount: u64 = switch (tx_obj.get("amount") orelse {
                            std.log.err("Transaction element {d}: missing 'amount' field.", .{idx});
                            return error.InvalidFormat;
                        }) {
                            .integer => |val| if (val < 0) return error.InvalidFormat else @intCast(val),
                            else => {
                                std.log.err("Transaction element {d}: 'amount' field is not an integer.", .{idx});
                                return error.InvalidFormat;
                            },
                        };
                        std.log.info("Transaction element {d}: Parsed amount = {d}", .{ idx, amount });

                        // トランザクションをブロックに追加
                        try b.transactions.append(types.Transaction{
                            .sender = sender_copy,
                            .receiver = receiver_copy,
                            .amount = amount,
                        });
                    }
                    std.log.debug("Transactions field is directly an array. end", .{});
                }
                std.log.debug("Transactions field is directly an array. end transactions={any}", .{b.transactions});
            },
            // トランザクションがネストされたJSON文字列の場合の処理
            .string => {
                std.log.info("Transactions field is a string. Value: {s}", .{tx_val.string});
                const tx_parsed = try std.json.parseFromSlice(std.json.Value, block_allocator, tx_val.string, .{});
                defer tx_parsed.deinit();
                switch (tx_parsed.value) {
                    .array => {
                        const tx_items = tx_parsed.value.array.items;
                        if (tx_items.len > 0) {
                            // 未実装: 文字列から配列を解析
                            return error.InvalidFormat;
                        }
                    },
                    else => return error.InvalidFormat,
                }
            },
            else => return error.InvalidFormat,
        }
    }

    std.log.debug("Block info: index={d}, timestamp={d}, prev_hash={any}, transactions={any} nonce={d}, data={s}, hash={any} ", .{ b.index, b.timestamp, b.prev_hash, b.transactions, b.nonce, b.data, b.hash });
    std.log.debug("parseBlockJson end", .{});
    return cloneOwnedBlock(output_allocator, b);
}
