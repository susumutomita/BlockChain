const std = @import("std");
const types = @import("types.zig");

/// hexEncode: バイト列を16進数文字列に変換
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

/// hexDecode: 16進文字列をバイナリへ (返り値: 実際に変換できたバイト数)
pub fn hexDecode(src: []const u8, dst: *[256]u8) !usize {
    if (src.len % 2 != 0) return types.ChainError.InvalidHexLength;
    var i: usize = 0;
    while (i < src.len) : (i += 2) {
        const hi = parseHexDigit(src[i]) catch return types.ChainError.InvalidHexChar;
        const lo = parseHexDigit(src[i + 1]) catch return types.ChainError.InvalidHexChar;
        dst[i / 2] = (hi << 4) | lo;
    }
    return src.len / 2;
}

fn parseHexDigit(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => 10 + (c - 'a'),
        'A'...'F' => 10 + (c - 'A'),
        else => types.ChainError.InvalidHexChar,
    };
}

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
        const tx_json = try std.fmt.allocPrintZ(allocator, "{{\"sender\":\"{s}\",\"receiver\":\"{s}\",\"amount\":{d}}}", .{ tx.sender, tx.receiver, tx.amount });
        defer allocator.free(tx_json);
        try list.appendSlice(tx_json);
    }

    try list.appendSlice("]");
    return list.toOwnedSlice();
}

pub fn serializeBlock(block: types.Block) ![]const u8 {
    const allocator = std.heap.page_allocator;
    const hash_str = hexEncode(block.hash[0..], allocator) catch unreachable;
    const prev_hash_str = hexEncode(block.prev_hash[0..], allocator) catch unreachable;
    const tx_str = try serializeTransactions(block.transactions, allocator);
    const json = try std.fmt.allocPrintZ(allocator, "{{\"index\":{d},\"timestamp\":{d},\"nonce\":{d},\"data\":\"{s}\",\"prev_hash\":\"{s}\",\"hash\":\"{s}\",\"transactions\":{s}}}", .{ block.index, block.timestamp, block.nonce, block.data, prev_hash_str, hash_str, tx_str });
    allocator.free(hash_str);
    allocator.free(prev_hash_str);
    allocator.free(tx_str);
    return json;
}

pub fn parseBlockJson(json_slice: []const u8) !types.Block {
    const block_allocator = std.heap.page_allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, block_allocator, json_slice, .{});
    defer parsed.deinit();
    const root_value = parsed.value;

    const obj = switch (root_value) {
        .object => |o| o,
        else => return types.ChainError.InvalidFormat,
    };

    var b = types.Block{
        .index = 0,
        .timestamp = 0,
        .prev_hash = [_]u8{0} ** 32,
        .transactions = std.ArrayList(types.Transaction).init(block_allocator),
        .nonce = 0,
        .data = "P2P Received Block",
        .hash = [_]u8{0} ** 32,
    };

    // index の読み込み
    if (obj.get("index")) |idx_val| {
        const idx_num: i64 = switch (idx_val) {
            .integer => idx_val.integer,
            .float => @as(i64, @intFromFloat(idx_val.float)),
            else => return types.ChainError.InvalidFormat,
        };
        if (idx_num < 0 or idx_num > @as(i64, std.math.maxInt(u32))) {
            return types.ChainError.InvalidFormat;
        }
        b.index = @intCast(idx_num);
    }

    // timestamp の読み込み
    if (obj.get("timestamp")) |ts_val| {
        const ts_num: i64 = switch (ts_val) {
            .integer => if (ts_val.integer < 0) return types.ChainError.InvalidFormat else ts_val.integer,
            .float => @intFromFloat(ts_val.float),
            else => return types.ChainError.InvalidFormat,
        };
        b.timestamp = @intCast(ts_num);
    }

    // nonce の読み込み
    if (obj.get("nonce")) |nonce_val| {
        const nonce_num: i64 = switch (nonce_val) {
            .integer => nonce_val.integer,
            .float => @intFromFloat(nonce_val.float),
            else => return types.ChainError.InvalidFormat,
        };
        if (nonce_num < 0 or nonce_num > @as(f64, std.math.maxInt(u64))) {
            return types.ChainError.InvalidFormat;
        }
        b.nonce = @intCast(nonce_num);
    }

    // prev_hash の読み込み
    if (obj.get("prev_hash")) |ph_val| {
        const ph_str = switch (ph_val) {
            .string => ph_val.string,
            else => return types.ChainError.InvalidFormat,
        };
        var ph_buf: [256]u8 = undefined;
        const ph_len = try hexDecode(ph_str, &ph_buf);
        if (ph_len != 32) return types.ChainError.InvalidFormat;
        var tmp_ph: [32]u8 = undefined;
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            tmp_ph[i] = ph_buf[i];
        }
        b.prev_hash = tmp_ph;
    }

    // hash の読み込み
    if (obj.get("hash")) |hash_val| {
        const hash_str = switch (hash_val) {
            .string => hash_val.string,
            else => return types.ChainError.InvalidFormat,
        };
        var long_buf: [256]u8 = undefined;
        const actual_len = try hexDecode(hash_str, &long_buf);
        if (actual_len != 32) return types.ChainError.InvalidFormat;
        var tmp_hash: [32]u8 = undefined;
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            tmp_hash[i] = long_buf[i];
        }
        b.hash = tmp_hash;
    }

    // data の読み込み
    if (obj.get("data")) |data_val| {
        const data_str = switch (data_val) {
            .string => data_val.string,
            else => return types.ChainError.InvalidFormat,
        };
        b.data = try block_allocator.dupe(u8, data_str);
    }

    // transactions の読み込み
    if (obj.get("transactions")) |tx_val| {
        std.log.info("Found transactions field: {any}", .{tx_val});
        const tx_items = blk: {
            if (tx_val == .array) {
                std.log.info("Transactions field is directly an array.", .{});
                break :blk tx_val.array.items;
            } else if (tx_val == .string) {
                std.log.info("Transactions field is a string. Value: {s}", .{tx_val.string});
                const tx_parsed = try std.json.parseFromSlice(std.json.Value, block_allocator, tx_val.string, .{});
                defer tx_parsed.deinit();
                if (tx_parsed.value == .array) {
                    break :blk tx_parsed.value.array.items;
                }
            }
            return types.ChainError.InvalidFormat;
        };

        const tx_slice = tx_items;
        for (tx_slice, 0..) |elem, idx| {
            std.log.info("Processing transaction element {d}: {any}", .{ idx, elem });
            const tx_obj = switch (elem) {
                .object => |o| o,
                else => {
                    std.log.err("Transaction element {d} is not an object.", .{idx});
                    return types.ChainError.InvalidFormat;
                },
            };
            const sender = switch (tx_obj.get("sender") orelse {
                std.log.err("Transaction element {d}: missing 'sender' field.", .{idx});
                return types.ChainError.InvalidFormat;
            }) {
                .string => |s| s,
                else => {
                    std.log.err("Transaction element {d}: 'sender' field is not a string.", .{idx});
                    return types.ChainError.InvalidFormat;
                },
            };
            const sender_copy = try block_allocator.dupe(u8, sender);

            const receiver = switch (tx_obj.get("receiver") orelse {
                std.log.err("Transaction element {d}: missing 'receiver' field.", .{idx});
                return types.ChainError.InvalidFormat;
            }) {
                .string => |s| s,
                else => {
                    std.log.err("Transaction element {d}: 'receiver' field is not a string.", .{idx});
                    return types.ChainError.InvalidFormat;
                },
            };
            const receiver_copy = try block_allocator.dupe(u8, receiver);

            const amount: u64 = switch (tx_obj.get("amount") orelse {
                std.log.err("Transaction element {d}: missing 'amount' field.", .{idx});
                return types.ChainError.InvalidFormat;
            }) {
                .integer => |val| if (val < 0) return types.ChainError.InvalidFormat else @intCast(val),
                .float => |val| if (val < 0) return types.ChainError.InvalidFormat else @intFromFloat(val),
                else => {
                    std.log.err("Transaction element {d}: 'amount' field is neither integer nor float.", .{idx});
                    return types.ChainError.InvalidFormat;
                },
            };
            std.log.info("Transaction element {d}: Parsed amount = {d}", .{ idx, amount });
            try b.transactions.append(types.Transaction{
                .sender = sender_copy,
                .receiver = receiver_copy,
                .amount = amount,
            });
        }
    }

    return b;
}

test "parseBlockJson: ブロック全体をパース" {
    const block_json_text = "{\"index\": 10,\n\"timestamp\": 1672531201,\n\"nonce\": 42,\n\"prev_hash\": \"00000000000000000000000000000000000000000000000000000000000000ff\",\n\"hash\": \"00000000000000000000000000000000000000000000000000000000000000aa\",\n\"data\": \"Sample Block\",\n\"transactions\": [\n  { \"sender\": \"Alice\", \"receiver\": \"Bob\", \"amount\": 100 }\n]}";

    const block = try parseBlockJson(block_json_text);
    defer block.transactions.deinit();
    try std.testing.expectEqual(@as(u32, 10), block.index);
    try std.testing.expectEqual(@as(u64, 1672531201), block.timestamp);
    try std.testing.expectEqual(@as(u64, 42), block.nonce);
    try std.testing.expectEqualStrings("Sample Block", block.data);
    try std.testing.expectEqual(@as(usize, 1), block.transactions.items.len);
    try std.testing.expectEqualStrings("Alice", block.transactions.items[0].sender);
}

test "parseBlockJson: フィールド省略 (index, timestampなし) でもエラーにならない" {
    // Replace triple-quoted string with regular string using \n for newlines
    const block_json_text =
        "{\n" ++
        "  \"data\": \"No index or timestamp\",\n" ++
        "  \"transactions\": []\n" ++
        "}\n";
    const block = try parseBlockJson(block_json_text);
    defer block.transactions.deinit();

    // index=0, timestamp=0 で初期値のまま
    try std.testing.expectEqual(@as(u32, 0), block.index);
    try std.testing.expectEqual(@as(u64, 0), block.timestamp);
    try std.testing.expectEqualStrings("No index or timestamp", block.data);
}

test "serializeBlock & parseBlockJson: 相互変換" {
    const allocator = std.testing.allocator;

    // テスト用のBlockを生成
    var block = types.Block{
        .index = 5,
        .timestamp = 1234567890,
        .prev_hash = [_]u8{0} ** 32,
        .transactions = std.ArrayList(types.Transaction).init(allocator),
        .nonce = 999,
        .data = "Hello, Test!",
        .hash = [_]u8{0xaa} ** 32, // 全て0xaa
    };
    defer block.transactions.deinit();
    // 1トランザクション追加
    try block.transactions.append(types.Transaction{
        .sender = "X",
        .receiver = "Y",
        .amount = 55,
    });

    // JSON化
    const json_text = try serializeBlock(block);
    // 逆に parseBlockJson して復元
    const b2 = try parseBlockJson(json_text);
    defer b2.transactions.deinit();

    // フィールド一致を確認
    try std.testing.expectEqual(block.index, b2.index);
    try std.testing.expectEqual(block.timestamp, b2.timestamp);
    try std.testing.expectEqualStrings(block.data, b2.data);
    try std.testing.expectEqual(@as(usize, 1), b2.transactions.items.len);
    try std.testing.expectEqualStrings("X", b2.transactions.items[0].sender);
}
