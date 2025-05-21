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
    if (src.len % 2 != 0) return chainError.InvalidHexLength;
    var i: usize = 0;
    while (i < src.len) : (i += 2) {
        const hi = parseHexDigit(src[i]) catch return chainError.InvalidHexChar;
        const lo = parseHexDigit(src[i + 1]) catch return chainError.InvalidHexChar;
        dst[i / 2] = (hi << 4) | lo;
    }
    return src.len / 2;
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

        // 基本的なトランザクション情報を含むJSONを作成
        const tx_json_base = try std.fmt.allocPrintZ(allocator, "{{\"sender\":\"{s}\",\"receiver\":\"{s}\",\"amount\":{d},\"tx_type\":{d},\"gas_limit\":{d},\"gas_price\":{d}", .{ tx.sender, tx.receiver, tx.amount, tx.tx_type, tx.gas_limit, tx.gas_price });
        defer allocator.free(tx_json_base);

        // EVMデータがある場合は追加
        if (tx.evm_data) |evm_data| {
            // EVMデータを16進数に変換
            const evm_data_hex = try utils.bytesToHex(allocator, evm_data);
            defer allocator.free(evm_data_hex);

            // EVMデータを含む完全なJSONを作成
            const tx_json_full = try std.fmt.allocPrintZ(allocator, "{s},\"evm_data\":\"{s}\"}}", .{ tx_json_base, evm_data_hex });
            defer allocator.free(tx_json_full);
            try list.appendSlice(tx_json_full);
        } else {
            // EVMデータがない場合は基本情報のみ
            const tx_json_no_evm = try std.fmt.allocPrintZ(allocator, "{s}}}", .{tx_json_base});
            defer allocator.free(tx_json_no_evm);
            try list.appendSlice(tx_json_no_evm);
        }
    }

    try list.appendSlice("]");
    return list.toOwnedSlice();
}

/// ブロック構造体をJSON文字列にシリアライズする
///
/// 与えられたブロック構造体からブロックチェーンのP2P通信に
/// 使用できるJSON文字列を生成します。
///
/// 引数:
///     block: シリアライズするブロック
///
/// 戻り値:
///     []const u8: 割り当てられたJSON文字列（呼び出し元がメモリを所有）
///
/// エラー:
///     割り当てまたはフォーマットエラー
pub fn serializeBlock(block: types.Block) ![]const u8 {
    // 文字列の構築に使用されるアロケータ
    const allocator = std.heap.page_allocator;

    // トランザクションを文字列に変換
    const tx_json = try serializeTransactions(block.transactions, allocator);
    defer allocator.free(tx_json);

    // コントラクト情報をシリアライズ
    var contracts_json: []const u8 = "null";
    defer {
        if (!std.mem.eql(u8, contracts_json, "null")) {
            allocator.free(contracts_json);
        }
    }

    if (block.contracts) |contracts| {
        if (contracts.count() > 0) {
            var contracts_list = std.ArrayList(u8).init(allocator);
            errdefer contracts_list.deinit();

            try contracts_list.appendSlice("{");

            var it = contracts.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) {
                    try contracts_list.appendSlice(",");
                }
                first = false;

                const addr = entry.key_ptr.*;
                const code = entry.value_ptr.*;

                // コントラクトアドレスと16進エンコードされたコードをJSON形式で出力
                const code_hex = try utils.bytesToHex(allocator, code);
                defer allocator.free(code_hex);

                try contracts_list.appendSlice("\"");
                try contracts_list.appendSlice(addr);
                try contracts_list.appendSlice("\":\"");
                try contracts_list.appendSlice(code_hex);
                try contracts_list.appendSlice("\"");
            }

            try contracts_list.appendSlice("}");
            contracts_json = try contracts_list.toOwnedSlice();
        }
    }

    const hash_str = std.fmt.bytesToHex(block.hash, .lower);
    const prev_hash_str = std.fmt.bytesToHex(block.prev_hash, .lower);
    return std.fmt.allocPrint(allocator, "{{" ++
        "\"index\":{d}," ++
        "\"timestamp\":{d}," ++
        "\"prev_hash\":\"{s}\"," ++
        "\"transactions\":{s}," ++
        "\"nonce\":{d}," ++
        "\"data\":\"{s}\"," ++
        "\"hash\":\"{s}\"," ++
        "\"contracts\":{s}" ++
        "}}", .{
        block.index,
        block.timestamp,
        prev_hash_str,
        tx_json,
        block.nonce,
        std.mem.trim(u8, block.data, "\n"),
        hash_str,
        contracts_json,
    });
}

/// JSONからブロック構造体を解析する
///
/// JSON文字列からブロック構造体を作成して返します。
///
/// 引数:
///     json_str: 解析するJSON文字列
///
/// 戻り値:
///     types.Block: 解析されたブロック構造体
///
/// エラー:
///     入力が有効なJSON形式でない場合はエラー
pub fn parseBlockJson(json_str: []const u8) !types.Block {
    const allocator = std.heap.page_allocator;

    // JSONをパース
    var json_obj = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer json_obj.deinit();

    // JSONオブジェクトからBlock構造体を作成
    const b = parseBlockFromJsonObj(json_obj.value, allocator) catch |err| {
        std.log.err("Failed to parse block: {}", .{err});
        return err;
    };

    return b;
}

/// JSONオブジェクトからブロック構造体を解析する
///
/// 引数:
///     obj: 解析するJSONオブジェクト
///     block_allocator: ブロックデータ用のアロケータ
///
/// 戻り値:
///     types.Block: 解析されたブロック構造体
///
/// エラー:
///     JSONオブジェクトがブロック形式に準拠していない場合はエラー
fn parseBlockFromJsonObj(obj: std.json.Value, block_allocator: std.mem.Allocator) !types.Block {
    std.log.debug("parseBlockFromJsonObj start", .{});
    const array_obj = switch (obj) {
        .object => |o| o,
        else => return error.InvalidFormat,
    };

    // 必須フィールドの検証
    if (!array_obj.contains("index") or
        !array_obj.contains("timestamp") or
        !array_obj.contains("prev_hash") or
        !array_obj.contains("transactions") or
        !array_obj.contains("nonce") or
        !array_obj.contains("data") or
        !array_obj.contains("hash"))
    {
        return error.MissingFields;
    }

    // インデックスを取得
    const index = switch (array_obj.get("index").?) {
        .integer => |i| if (i < 0) return error.InvalidFormat else @as(u32, @intCast(i)),
        else => return error.InvalidFormat,
    };

    // タイムスタンプを取得
    const timestamp = switch (array_obj.get("timestamp").?) {
        .integer => |i| if (i < 0) return error.InvalidFormat else @as(u64, @intCast(i)),
        else => return error.InvalidFormat,
    };

    // 前のハッシュを取得
    const prev_hash_str = switch (array_obj.get("prev_hash").?) {
        .string => |s| s,
        else => return error.InvalidFormat,
    };
    var prev_hash: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&prev_hash, prev_hash_str);

    // ノンスを取得
    const nonce = switch (array_obj.get("nonce").?) {
        .integer => |i| if (i < 0) return error.InvalidFormat else @as(u64, @intCast(i)),
        else => return error.InvalidFormat,
    };

    // データを取得
    const data = switch (array_obj.get("data").?) {
        .string => |s| try block_allocator.dupe(u8, s),
        else => return error.InvalidFormat,
    };

    // ハッシュを取得
    const hash_str = switch (array_obj.get("hash").?) {
        .string => |s| s,
        else => return error.InvalidFormat,
    };
    var hash: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&hash, hash_str);

    // ブロック構造体の初期化
    var b = types.Block{
        .index = index,
        .timestamp = timestamp,
        .prev_hash = prev_hash,
        .transactions = std.ArrayList(types.Transaction).init(block_allocator),
        .nonce = nonce,
        .data = data,
        .hash = hash,
        .contracts = null,
    };
    std.log.debug("Block info: index={d}, timestamp={d}, prev_hash={any}, transactions=..., nonce={d}, data={s}, hash={any}", .{ b.index, b.timestamp, b.prev_hash, b.nonce, b.data, b.hash });

    // トランザクションの解析
    if (array_obj.get("transactions")) |tx_val| {
        switch (tx_val) {
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
                            .float => |val| if (val < 0) return error.InvalidFormat else @intFromFloat(val),
                            else => {
                                std.log.err("Transaction element {d}: 'amount' field is neither integer nor float.", .{idx});
                                return error.InvalidFormat;
                            },
                        };
                        std.log.info("Transaction element {d}: Parsed amount = {d}", .{ idx, amount });

                        // EVMデータの抽出（存在する場合）
                        var evm_data: ?[]const u8 = null;
                        var tx_type: u8 = 0;
                        var gas_limit: usize = 1000000;
                        var gas_price: u64 = 20000000000;

                        // tx_typeフィールドを解析（存在する場合）
                        if (tx_obj.get("tx_type")) |tx_type_val| {
                            tx_type = switch (tx_type_val) {
                                .integer => |val| if (val < 0 or val > 255) return error.InvalidFormat else @intCast(val),
                                else => {
                                    std.log.err("Transaction element {d}: 'tx_type' field is not an integer.", .{idx});
                                    return error.InvalidFormat;
                                },
                            };
                        }

                        // evm_dataフィールドを解析（存在する場合）
                        if (tx_obj.get("evm_data")) |evm_data_val| {
                            const evm_data_str = switch (evm_data_val) {
                                .string => |s| s,
                                else => {
                                    std.log.err("Transaction element {d}: 'evm_data' field is not a string.", .{idx});
                                    return error.InvalidFormat;
                                },
                            };

                            // "0x" プレフィックスを削除して16進数をバイトに変換
                            if (evm_data_str.len > 2 and std.mem.startsWith(u8, evm_data_str, "0x")) {
                                evm_data = try utils.hexToBytes(block_allocator, evm_data_str[2..]);
                            } else {
                                evm_data = try utils.hexToBytes(block_allocator, evm_data_str);
                            }
                        }

                        // gas_limitフィールドを解析（存在する場合）
                        if (tx_obj.get("gas_limit")) |gas_limit_val| {
                            gas_limit = switch (gas_limit_val) {
                                .integer => |val| if (val < 0) return error.InvalidFormat else @intCast(val),
                                else => {
                                    std.log.err("Transaction element {d}: 'gas_limit' field is not an integer.", .{idx});
                                    return error.InvalidFormat;
                                },
                            };
                        }

                        // gas_priceフィールドを解析（存在する場合）
                        if (tx_obj.get("gas_price")) |gas_price_val| {
                            gas_price = switch (gas_price_val) {
                                .integer => |val| if (val < 0) return error.InvalidFormat else @intCast(val),
                                else => {
                                    std.log.err("Transaction element {d}: 'gas_price' field is not an integer.", .{idx});
                                    return error.InvalidFormat;
                                },
                            };
                        }

                        // トランザクションをブロックに追加
                        try b.transactions.append(types.Transaction{
                            .sender = sender_copy,
                            .receiver = receiver_copy,
                            .amount = amount,
                            .tx_type = tx_type,
                            .evm_data = evm_data,
                            .gas_limit = gas_limit,
                            .gas_price = gas_price,
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
                            // 未実装：文字列からパースした配列の処理
                            return error.InvalidFormat;
                        }
                    },
                    else => return error.InvalidFormat,
                }
            },
            else => return error.InvalidFormat,
        }
    }

    // コントラクト情報の解析（存在する場合）
    if (array_obj.get("contracts")) |contracts_val| {
        std.log.info("Contracts field found in block, type: {s}", .{@tagName(contracts_val)});

        switch (contracts_val) {
            .null => {
                std.log.info("Contracts field is null - no contracts in this block", .{});
                // コントラクト情報なし
            },
            .object => |contracts_obj| {
                std.log.info("Processing contracts field with {d} entries", .{contracts_obj.count()});

                // 新しいコントラクトストレージを作成
                var contracts = std.StringHashMap([]const u8).init(block_allocator);

                // 各コントラクトを処理
                var it = contracts_obj.iterator();
                while (it.next()) |entry| {
                    const address = entry.key_ptr.*;
                    std.log.info("Found contract address in block: {s}", .{address});

                    const code_hex = switch (entry.value_ptr.*) {
                        .string => |s| s,
                        else => {
                            std.log.err("Contract code for address {s} is not a string", .{address});
                            continue;
                        },
                    };

                    // 16進数文字列をバイトに変換
                    const code = try utils.hexToBytes(block_allocator, code_hex);
                    try contracts.put(address, code);
                    std.log.info("Parsed contract at address: {s}, code length: {d} bytes", .{ address, code.len });
                }

                b.contracts = contracts;
            },
            else => {
                std.log.err("Contracts field is neither null nor an object", .{});
                // エラーは返さず、コントラクト情報なしとして扱う
            },
        }
    }

    std.log.debug("Block info: index={d}, timestamp={d}, prev_hash={any}, transactions={any} nonce={d}, data={s}, hash={any} ", .{ b.index, b.timestamp, b.prev_hash, b.transactions, b.nonce, b.data, b.hash });
    std.log.debug("parseBlockJson end", .{});
    return b;
}

/// トランザクションをJSON文字列にシリアル化する
///
/// トランザクション構造体をネットワーク送信用のJSON文字列に変換します。
/// EVMトランザクション固有のフィールドも含まれます。
///
/// 引数:
///     tx: シリアル化するトランザクション
///
/// 戻り値:
///     []const u8: 割り当てられたJSON文字列（呼び出し元がメモリを解放する必要があります）
// This implementation has been moved to the new function below (at the end of the file).

/// JSON形式のトランザクション文字列を解析する
///
/// JSON形式のトランザクション文字列を解析して、トランザクション構造体に変換します。
/// EVM関連のフィールドにも対応しています。
///
/// 引数:
///     json_slice: 解析するJSON文字列
///
/// 戻り値:
///     types.Transaction: 解析されたトランザクション構造体
///
/// エラー:
///     様々な形式および解析エラー
pub fn parseTransactionJson(json_slice: []const u8) !types.Transaction {
    std.log.debug("parseTransactionJson start with: {s}", .{json_slice});
    const allocator = std.heap.page_allocator;

    // 入力文字列を前処理して有効なJSONにする
    const valid_json = try preprocessJsonInput(allocator, json_slice);
    defer allocator.free(valid_json);

    std.log.debug("After preprocessing: {s}", .{valid_json});

    // JSON文字列を汎用JSON値に解析
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, valid_json, .{}) catch |err| {
        std.log.err("JSON parse error: {any}", .{err});
        return err;
    };
    defer parsed.deinit();
    const root_value = parsed.value;

    // ルートがオブジェクトであることを確認
    const obj = switch (root_value) {
        .object => |o| o,
        else => {
            std.log.err("Root is not an object. Found: {any}", .{root_value});
            return chainError.InvalidFormat;
        },
    };

    // データオブジェクトの取得方法を改善
    // 「type」フィールドがある場合は特定の形式を想定（{"type": "evm_tx", "data": {...}}）
    // それ以外の場合は、データが直接ルートにあると想定
    const data_obj = if (obj.get("type")) |_| blk: {
        const data_val = obj.get("data") orelse {
            std.log.err("Expected 'data' field in transaction with 'type' field", .{});
            return chainError.InvalidFormat;
        };

        break :blk switch (data_val) {
            .object => |o| o,
            else => {
                std.log.err("'data' field is not an object", .{});
                return chainError.InvalidFormat;
            },
        };
    } else obj; // データが直接ルートにある場合

    // 基本フィールドを解析
    const sender = try parseStringField(data_obj, "sender", allocator);
    const receiver = try parseStringField(data_obj, "receiver", allocator);

    // 金額フィールドを解析
    const amount = try parseU64Field(data_obj, "amount");

    // EVMトランザクション固有のフィールドを解析
    var tx_type: u8 = 0;
    if (data_obj.get("tx_type")) |_| {
        tx_type = try parseU8Field(data_obj, "tx_type");
    }

    // ガス関連のフィールドを解析
    var gas_limit: usize = 1000000; // デフォルト値
    if (data_obj.get("gas_limit")) |_| {
        gas_limit = try parseUsizeField(data_obj, "gas_limit");
    }

    var gas_price: u64 = 10; // デフォルト値
    if (data_obj.get("gas_price")) |_| {
        gas_price = try parseU64Field(data_obj, "gas_price");
    }

    // EVM データを解析 (16進数文字列として格納されている)
    var evm_data: ?[]const u8 = null;
    if (data_obj.get("evm_data")) |evm_data_val| {
        const evm_data_str = switch (evm_data_val) {
            .string => evm_data_val.string,
            else => {
                std.log.err("'evm_data' field is not a string", .{});
                return error.InvalidFormat;
            },
        };

        // "0x" プレフィックスがあれば削除
        const hex_str = if (std.mem.startsWith(u8, evm_data_str, "0x"))
            evm_data_str[2..]
        else
            evm_data_str;

        // 16進数文字列をバイナリデータに変換
        evm_data = try utils.hexToBytes(allocator, hex_str);
    }

    std.log.info("Successfully parsed transaction: sender={s}, receiver={s}, tx_type={d}, gas={d}", .{ sender, receiver, tx_type, gas_limit });

    // トランザクション構造体を返す
    return types.Transaction{
        .sender = sender,
        .receiver = receiver,
        .amount = amount,
        .tx_type = tx_type,
        .evm_data = evm_data,
        .gas_limit = gas_limit,
        .gas_price = gas_price,
    };
}

/// JSONの文字列を前処理して有効なJSON形式に変換する
/// 不完全なJSONの場合、必要な構文要素を追加する
fn preprocessJsonInput(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    // 先頭と末尾のホワイトスペースを削除
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);

    // 入力が完全なJSONオブジェクトかどうか確認
    const starts_with_brace = trimmed.len > 0 and trimmed[0] == '{';
    const ends_with_brace = trimmed.len > 0 and trimmed[trimmed.len - 1] == '}';

    if (starts_with_brace and ends_with_brace) {
        // すでに有効なJSONオブジェクトの形式なら、そのまま返す
        return allocator.dupe(u8, trimmed);
    }

    // コロンから始まるパターンは問題ないが、クォートから始まるパターンは括弧で囲む必要がある
    if (trimmed.len > 0 and trimmed[0] == '"') {
        const buffer = try std.fmt.allocPrint(allocator, "{{{s}}}", .{trimmed});
        return buffer;
    }

    // フォールバック：単純に括弧を追加
    const buffer = try std.fmt.allocPrint(allocator, "{{{s}}}", .{trimmed});
    return buffer;
}

/// JSONオブジェクトから文字列フィールドを解析
fn parseStringField(obj: std.json.ObjectMap, field_name: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const val = obj.get(field_name) orelse return error.MissingField;
    const str = switch (val) {
        .string => val.string,
        else => return error.InvalidFormat,
    };
    return try allocator.dupe(u8, str);
}

/// JSONオブジェクトから符号なし64ビット整数フィールドを解析
fn parseU64Field(obj: std.json.ObjectMap, field_name: []const u8) !u64 {
    const val = obj.get(field_name) orelse return error.MissingField;
    switch (val) {
        .integer => |i| {
            if (i < 0) return error.InvalidFormat;
            return @intCast(i);
        },
        .float => |f| {
            if (f < 0) return error.InvalidFormat;
            return @intFromFloat(f);
        },
        else => return error.InvalidFormat,
    }
}

/// JSONオブジェクトから符号なし8ビット整数フィールドを解析
fn parseU8Field(obj: std.json.ObjectMap, field_name: []const u8) !u8 {
    const val = obj.get(field_name) orelse return error.MissingField;
    switch (val) {
        .integer => |i| {
            if (i < 0 or i > 255) return error.InvalidFormat;
            return @intCast(i);
        },
        .float => |f| {
            if (f < 0 or f > 255) return error.InvalidFormat;
            return @intFromFloat(f);
        },
        else => return error.InvalidFormat,
    }
}

/// JSONオブジェクトからusize整数フィールドを解析
fn parseUsizeField(obj: std.json.ObjectMap, field_name: []const u8) !usize {
    const val = obj.get(field_name) orelse return error.MissingField;
    switch (val) {
        .integer => |i| {
            if (i < 0) return error.InvalidFormat;
            return @intCast(i);
        },
        .float => |f| {
            if (f < 0) return error.InvalidFormat;
            return @intFromFloat(f);
        },
        else => return error.InvalidFormat,
    }
}

/// トランザクション構造体をJSON文字列にシリアライズする
///
/// 与えられたトランザクション構造体からP2P通信に使用できるJSON文字列を生成します。
/// EVMデータは16進数文字列にエンコードされます。
///
/// 引数:
///     allocator: メモリアロケータ
///     tx: シリアライズするトランザクション
///
/// 戻り値:
///     []const u8: 割り当てられたJSON文字列（呼び出し元がメモリを所有）
///
/// エラー:
///     割り当てまたはフォーマットエラー
pub fn serializeTransaction(allocator: std.mem.Allocator, tx: types.Transaction) ![]const u8 {
    // 基本的なトランザクション情報を含むJSONを作成
    var json_obj = std.ArrayList(u8).init(allocator);
    errdefer json_obj.deinit();

    try json_obj.appendSlice("{");
    
    // 基本フィールドの追加
    try json_obj.writer().print("\"sender\":\"{s}\",", .{tx.sender});
    try json_obj.writer().print("\"receiver\":\"{s}\",", .{tx.receiver});
    try json_obj.writer().print("\"amount\":{d},", .{tx.amount});
    try json_obj.writer().print("\"tx_type\":{d},", .{tx.tx_type});
    try json_obj.writer().print("\"gas_limit\":{d},", .{tx.gas_limit});
    try json_obj.writer().print("\"gas_price\":{d}", .{tx.gas_price});

    // EVMデータがある場合は16進数にエンコードして追加
    if (tx.evm_data) |evm_data| {
        const evm_data_hex = try utils.bytesToHex(allocator, evm_data);
        defer allocator.free(evm_data_hex);
        try json_obj.writer().print(",\"evm_data\":\"{s}\"", .{evm_data_hex});
    }

    try json_obj.appendSlice("}");
    return json_obj.toOwnedSlice();
}
