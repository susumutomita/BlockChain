---
title: "Zigを用いたP2Pブロックチェインの実装"
free: true
---

## ノード間のブロック共有

前章でP2Pがどのように動作するのかを理解し、ノード間でのメッセージ交換ができるようになりました。分散型のブロックチェインを構築するには、複数のノード間でブロック情報を共有する仕組みが不可欠です。これまでにローカルにブロックチェインを構築できましたが、このままでは各ノードが別々のチェインを持つだけで、ネットワーク全体で一貫した台帳を保つことができません。そのためここからは、ブロックチェインのデータをネットワーク全体で共有する仕組みを実装します。ノードが新しいブロックを生成した際、それを他のノードに伝え、全体で同じブロックチェインを維持することが重要です。このステップでは、ブロックのやり取りをするためのメッセージフォーマットを定義し、ノード間でブロックを共有する仕組みを構築します。

ポイントを整理すると、ネットワーク対応により以下が可能になります。

- ブロックの伝播: あるノードで生成（マイニング）されたブロックをネットワーク内の他ノードへ配信し、全ノードのブロックチェインを同期させる。これによりPoWで得たブロックにネットワーク上の意味を持たせます。
- RPCによる操作: 外部からノードへトランザクションを送信したり、マイニングを指示したりするリモート呼び出しを提供する。ユーザや他のノードがネットワーク経由でsendTransactionやmineといった操作をできるようにします。

以上の仕組みにより、複数ノードが協調して1つのブロックチェインネットワークを形成します。

### ブロックを共有する必要性とネットワーク同期

ブロックチェインは分散ネットワーク上の各ノードでデータを同期し、全員が最新のチェインを共有することで成り立っています。もし新しいブロックを生成したノードだけがそれを保持し、他のノードに知らせなければ、ノードごとに異なるブロックチェインが存在してしまい整合性が失われます。例えば、ノードAがPoWに成功してブロックを追加しても、それをノードBやCが知らなければ、ノードBやCの台帳は更新されず古いままです。そこでネットワーク通信によって「新しいブロックができたよ」と他のノードに伝え、ブロックを受け渡す仕組みが必要になります。

では、なぜネットワーク越しにブロックを共有する必要があるのでしょうか。主な理由は次のとおりです。

1. 全ノードで最新状態を保持するため – どれか1つのノードが新ブロックを追加したら、全員がそれを取り入れなければ台帳が食い違ってしまいます。共有することで全ノードが最新のブロックチェインを維持できます。
2. 合意形成（コンセンサス）の基盤 – ブロックチェインでは分散したノードが単一の正しいチェインに合意する必要があります。他ノードとブロック情報を交換し、お互いに検証することで、不正なブロックの排除や最長チェインへの合意が可能になります。
3. ネットワークの信頼性向上 – ブロックを複製・共有しておけば、あるノードがダウンしても他のノードがチェインのコピーを持っているため、ネットワーク全体として台帳を損失しません。

このように、新規ブロックの共有はブロックチェインネットワークの根幹と言えます。そのためにはノード間の通信が不可欠です。単一のプログラム内で完結していたこれまでの処理を、今度はノード同士が通信してデータをやり取りする形に拡張していきましょう。

## RPC的アプローチによるブロック伝播の方針

ノード間でブロックを共有する方法はいくつか考えられますが、ここではシンプルな擬似RPC（Remote Procedure Call）の仕組みで実装します。各ノードは自分自身をサーバーとして他ノードからのリクエストを受け付け、決められた処理（ブロックの送受信など）を行います。同時に、他ノードに対してクライアントとしてリクエストを送り、必要な情報を取得します。全ノードが対等（ピアツーピア）にお互いへ問い合わせ合うことで、ネットワーク全体の同期を図ることができます。

本章で実装する具体的な機能は次のとおりです。

- ブロックの伝播: あるノードで新しいブロックが生成（マイニング）されたら、そのブロックをネットワーク内の他ノードへ配信し、全ノードのチェインを最新状態に同期させます。これによりPoWで得たブロックにネットワーク上の意味を持たせます。
- RPCによる操作: 外部からノードへリクエストを送り、特定の操作をリモート実行できるようにします。たとえばユーザや他ノードがネットワーク経由でトランザクション送信やマイニング指示（sendTransactionやmineといった操作）を行えるインタフェースを提供します。

以上の仕組みにより、複数ノードが協調して1つのブロックチェインネットワークを形成します。
今回の実装ではまずブロック伝播にフォーカスし、簡易的な方法で「複数ノードでブロックを共有する」ことを実現します。高度なフォーク処理やピア探索などは後続章で扱う予定ですが、まずは基本となるブロック共有の流れを押さえましょう。

## ネットワーク接続相手（Peer）を表す構造体の定義

まず、ノード間通信における接続相手（ピア）の情報を保持する構造体を用意します。各ピアのIPアドレスとTCPストリームを保持し、送受信処理で使い回せるようにします。types.zigに以下のような構造体を追加します。

```types.zig
pub const Peer = struct {
    address: std.net.Address,
    stream: std.net.Stream,
};
```

このPeer構造体は単にネットワーク接続相手を表すための入れ物です。各ノードは通信する相手ノードのAddress（IPとポート）と、その接続に対応するStream（ソケットストリーム）をペアで保持します。こうしておくことで、後述する送受信処理において、どの相手に対して通信しているかを管理しやすくなります。

## サーバーモード：受信スレッドを追加

次に、ノードをサーバーとして動作させ、他ノードからの接続を受け入れてメッセージを処理する仕組みを実装します。基本的な流れは**listen()待ち受け→accept()接続受理→新規スレッドで受信処理を開始**という手順です。

特に受信処理では、受け取ったデータがブロック情報かどうかを判別し、ブロックであればチェインに取り込みます。簡易的なプロトコルとして、メッセージが"BLOCK:"で始まる場合にその後ろの部分をブロックのJSONデータとみなすことにします。それ以外のメッセージは現時点では特に意味を持たないものとして無視します。

### 接続受信ハンドラの作成

まず、サーバーが受理した各接続ごとに新しいスレッドで動作する受信ハンドラを実装します。以下のConnHandler構造体は接続を処理するスレッドのエントリポイントを持ち、クライアントから届いたメッセージを読み取って適切に対応します。

```blockchain.zig
//--------------------------------------
// メッセージ受信処理: ConnHandler
//--------------------------------------
pub const ConnHandler = struct {
    pub fn run(conn: std.net.Server.Connection) !void {
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
                const new_block = parser.parseBlockJson(json_part) catch |err| {
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
```

上記コードでは、ConnHandler.run関数が新しい接続ごとにスレッド内で呼び出され、無限ループでデータを受信し続けます。ポイントをまとめると以下になります。

- 接続の受理とログ: listener.accept()で得られたconn（接続）が渡され、スレッド開始時にAccepted: とログ出力します。defer conn.stream.close();により関数終了時（接続終了時）にソケットを閉じます。
- 受信ループ: reader.read(&buf)でクライアントからのデータを読み取ります。n == 0なら接続相手が切断したと判断してループを抜けます。
- メッセージ判別: 受信したデータをmsg_sliceに格納し、"BLOCK:"で始まるかをstd.mem.startsWithでチェックします。もし"BLOCK:"で始まれば、その6バイト後ろ（msg_slice[6..]）を取り出し、それをブロック情報のJSON文字列とみなします。
- ブロックJSONの解析: parser.parseBlockJson(json_part)を呼び出してJSON文字列をパースし、新しいブロック構造体new_blockを生成します。この際にエラーが起きた場合（JSON形式が不正など）はログにエラー内容を出力し、そのメッセージは飛ばします（continueで次の受信ループへ）。
- ブロックの追加: パースに成功した場合はaddBlock(new_block)を呼び出し、受け取ったブロックを自ノードのブロックチェインに取り込みます（addBlockの実装は後述します）。
- その他のメッセージ: 先頭が"BLOCK:"でない場合（現時点ではブロックデータ以外のメッセージ）は、とりあえず内容をUnknown messageとしてログに表示するだけにしています。

現状では、受信するコマンドは"BLOCK:"のみを想定しており、それ以外の文字列は特に処理していません（将来的にトランザクション送信要求など別のコマンドを追加する余地があります）。このようにサーバーノード側では、新しい接続ごとにスレッドを立ち上げ、ブロックメッセージが届いたら即座にパースしてチェインを更新するという流れを実現しています。

### ブロックデータのシリアライズとパース処理

上記のConnHandler内では、受信したJSON文字列をparser.parseBlockJson関数でブロック構造体に変換していました。このparseBlockJsonを含むパーサーモジュールを実装します。
また、ネットワークでブロックをやり取りするためには、ブロック構造体をJSON文字列に変換するシリアライズ処理も必要です。そこで、ここでは以下の機能を実装します。

- ハッシュ値のエンコード/デコード: ブロックのhashやprev_hashは32バイトのバイナリデータ（SHA-256）なので、そのままではJSONに含められません。そこでバイナリを16進文字列に変換・復元する関数を用意します（例: バイト列{0×1A, 0×2B}→文字列"1a2b"）。
- トランザクション配列のJSON変換: ブロック内のトランザクション一覧（transactions）をJSON文字列にシリアライズする関数を作ります。逆にJSONからトランザクション配列を構築する処理も行います。
- ブロック全体のシリアライズ: ブロック構造体→JSON文字列への変換関数を実装します。
- ブロックJSONのパース: JSON文字列→ブロック構造体への変換関数（parseBlockJson）を実装します。

それでは、parser.zigにこれらの関数群を実装していきます。まずはヘルパーとなる16進変換とトランザクション配列のシリアライズ関数です。

```parser.zig
const std = @import("std");
const crypto = std.crypto.hash;
const Sha256 = crypto.sha2.Sha256;
const types = @import("types.zig");
const logger = @import("logger.zig");
const utils = @import("utils.zig");
const chainError = @import("errors.zig").ChainError;
const DIFFICULTY: u8 = 2;
var chain_store = std.ArrayList(types.Block).init(std.heap.page_allocator);

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

fn parseHexDigit(c: u8) !u8 {
    switch (c) {
        '0'...'9' => return c - '0',
        'a'...'f' => return 10 + (c - 'a'),
        'A'...'F' => return 10 + (c - 'A'),
        else => return error.InvalidHexChar,
    }
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
```

上記コードの概要は以下のとおりです。

- hexEncode: 与えられたバイトスライスをヒープ上に確保したバッファへ16進文字列としてエンコードし、その文字列スライスを返します。例えば[0×0F, 0×A0]が入力なら"0fa0"という文字列を返すイメージです。
- hexDecode: 16進文字列を元のバイナリデータにデコードします。2文字で1バイトを表すので、文字列長が奇数の場合はInvalidHexLengthエラーになります。各文字をparseHexDigitで4ビットの値に変換し、2つ組み合わせて1バイトにしています。戻り値は実際に書き込んだバイト数です（＝src.len / 2になるはず）。
- parseHexDigit: 1文字の16進文字を4ビット相当の数値に変換します。0-9は0〜9、a-f/A-Fは10〜15にマップし、それ以外はInvalidHexCharエラーを返します。
- serializeTransactions: ブロック内のtransactions（トランザクション配列）をJSONの文字列にシリアライズします。トランザクションが空の場合は空配列[]の文字列を返します。トランザクションがある場合は各要素JSONオブジェクト文字列に変換し、カンマ区切りで[...]の中に並べます。std.fmt.allocPrintZを使ってフォーマット済み文字列を取得し、それをリストに追加しています。

次に、ブロック全体をシリアライズ・パースする関数を実装します。先ほどのヘルパーを活用して、Block構造体<->JSONの変換をします。

```parser.zig
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
    std.log.debug("parseBlockJson start", .{});
    const block_allocator = std.heap.page_allocator;
    std.log.debug("parseBlockJson start parsed", .{});
    const parsed = try std.json.parseFromSlice(std.json.Value, block_allocator, json_slice, .{});
    std.log.debug("parseBlockJson end parsed", .{});
    defer parsed.deinit();
    const root_value = parsed.value;

    const obj = switch (root_value) {
        .object => |o| o,
        else => return chainError.InvalidFormat,
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
    std.log.debug("parseBlockJson start parser", .{});
    // index の読み込み
    if (obj.get("index")) |idx_val| {
        const idx_num: i64 = switch (idx_val) {
            .integer => idx_val.integer,
            .float => @as(i64, @intFromFloat(idx_val.float)),
            else => return error.InvalidFormat,
        };
        if (idx_num < 0 or idx_num > @as(i64, std.math.maxInt(u32))) {
            return error.InvalidFormat;
        }
        b.index = @intCast(idx_num);
    }

    // timestamp の読み込み
    if (obj.get("timestamp")) |ts_val| {
        const ts_num: i64 = switch (ts_val) {
            .integer => if (ts_val.integer < 0) return error.InvalidFormat else ts_val.integer,
            .float => @intFromFloat(ts_val.float),
            else => return error.InvalidFormat,
        };
        b.timestamp = @intCast(ts_num);
    }

    // nonce の読み込み
    if (obj.get("nonce")) |nonce_val| {
        const nonce_num: i64 = switch (nonce_val) {
            .integer => nonce_val.integer,
            .float => @intFromFloat(nonce_val.float),
            else => return error.InvalidFormat,
        };
        if (nonce_num < 0 or nonce_num > @as(f64, std.math.maxInt(u64))) {
            return error.InvalidFormat;
        }
        b.nonce = @intCast(nonce_num);
    }

    // prev_hash の読み込み（追加）
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

    // hash の読み込み
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

    // 5) data の読み込み（追加）
    if (obj.get("data")) |data_val| {
        const data_str = switch (data_val) {
            .string => data_val.string,
            else => return error.InvalidFormat,
        };
        b.data = try block_allocator.dupe(u8, data_str);
    }

    if (obj.get("transactions")) |tx_val| {
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
    std.log.debug("Block info: index={d}, timestamp={d}, prev_hash={any}, transactions={any} nonce={d}, data={s}, hash={any} ", .{ b.index, b.timestamp, b.prev_hash, b.transactions, b.nonce, b.data, b.hash });
    std.log.debug("parseBlockJson end", .{});
    return b;
}
```

serializeBlockでは、ブロック構造体内の各フィールドを文字列化してから、JSONフォーマットの文字列を組み立てています。具体的にはhashとprev_hashはhexEncodeで16進文字列にし、transactionsはserializeTransactionsでJSON文字列化します。それらをstd.fmt.allocPrintZでフォーマット文字列に埋め込んでいます。最後に確保したバッファを解放しつつ完成したJSON文字列を返しています。

parseBlockJsonは、逆にJSON文字列からブロック構造体を作る処理です。std.json.parseFromSliceを使って一旦汎用のstd.json.Value（JSON値）にパースし、それを期待する各フィールドに読み替えています。主な処理の流れは以下の通りです。

- JSONのトップレベルがオブジェクトかチェックし、オブジェクトなら各キーにアクセスします。トップレベルがオブジェクト以外（配列や値単体）ならフォーマット不正としてエラーにします。
- 新しいブロックBを初期化します。このときb.dataに仮で"P2P Received Block"という文字列を入れています。
- index, nonce等について、それぞれJSONオブジェクト中の該当フィールドを取得し、型に応じてブロックのフィールドに数値をセットします。例えばindexはJSON上整数か浮動小数なら数値を取り出し、負数や範囲外ならエラーとします。
- prev_hashとhashについては、JSONでは16進文字列として渡されているので、一旦文字列を取り出してからhexDecodeでバイナリに戻します。それを長さ32の配列にコピーしてb.prev_hashおよびb.hashに設定します。長さが32バイトでなければフォーマット不正です。
- dataは文字列として取得し、その内容をそのままb.dataに複製します（block_allocator.dupeでヒープにコピー）。通常、データフィールドはブロック生成者が自由に入れるものなので、ここでは送信側が埋めた値をそのまま使います。
- transactionsは少し入り組んでいます。送信元（シリアライズ側）の実装によっては、JSON内でトランザクション配列が直接配列として埋め込まれる場合と、文字列としてエンコードされている場合があります。今回serializeTransactionsでは常に配列リテラル文字列（例えば[]や[{"sender":...}]という文字列）を生成しています。serializeBlockでそれをそのまま埋め込んでいるため、受信側でtransactionsフィールドはJSON上配列そのものになっています。そのため、まず.arrayの場合を処理しています。
- .arrayの場合: 配列要素を順に取り出し、それぞれがオブジェクトであることを確認してからsender, receiver, amountフィールドを取り出します。文字列と数値に適切にキャストし、types.Transaction構造体を作ってブロックのb.transactionsリストに追加しています。全要素処理後に配列が空の場合や要素が不正な場合も考慮し、エラーなら即座に返しています。
- .stringの場合: 文字列で与えられた場合、一度中の文字列を再度std.json.parseFromSliceでパースする必要があります。上記コードでは.stringの場合にそれを試みています。ただし、このシナリオは本実装では発生しないため、「未実装」とコメントしてerror.InvalidFormatを返すようにしています。

以上でパースが完了し、最後に構造体Bを返しています。長い関数でしたが、要するに受信したブロックJSON文字列を解析し、各フィールドを検証しつつブロック構造体に詰め直す処理を行っています。

補足: 現段階では、先頭が"BLOCK:"のメッセージしか処理しておらず、それ以外はすべて「不明なメッセージ」として無視しています。今後もし "TX:" や "GETBLOCKS" など新たなコマンドを増やしたい場合は、ConnHandler.run内の判定を拡張します。具体的には、それぞれに対応する処理（トランザクション追加処理やチェイン要求処理など）を実装していくことになります。

作成したパーサー機能を使用するために、サーバー側（blockchain.zigなど）でparser.zigをインポートするのを忘れないでください。例えばファイルの上部で以下のように宣言します。

作成したパーサーを呼び出すために、parser.zigをインポートします。

```blockchain.zig
const parser = @import("parser.zig");
```

### クライアントモード：ブロック送信処理の実装

次に、ノードをクライアントとして動作させ、既存のネットワークに接続してブロックを送信する処理を実装します。クライアントノードは他ノードに接続し、自身でブロックを生成して送信する役割を担います（マイナーに相当する動きです）。ここでは、ユーザがコンソールに入力したデータを使って新規ブロックを作り、ネットワーク越しに送信する流れを作ります。

#### 接続＆送信用スレッドの作成

サーバーモードと同様、クライアントノードもスレッドを用いて送信処理を並行して行います。--connectモードでプログラムを起動した際には、指定した相手に対してTCP接続を確立し、以下の2つの動作をします。

- ユーザ入力の送信ループ: 新規スレッド上で、ユーザがコンソールに入力したテキストを取得し、それを元にブロックを作成して相手ノードへ送信します。
- 受信ループ: メインスレッド上で、接続からのデータを受信し、サーバーモード同様にメッセージを解析して処理します（こちらは後でmain関数内で記述します）。

まずは、クライアントの送信用スレッド（ClientHandler）と、ユーザ入力を処理するループ（clientSendLoop）を実装します。

```blockchain.zig
//--------------------------------------
// クライアント処理
//--------------------------------------
pub const ClientHandler = struct {
    pub fn run(peer: types.Peer) !void {
        // クライアントはローカルに Genesis ブロックを保持（本来はサーバーから同期する）
        var lastBlock = try createTestGenesisBlock(std.heap.page_allocator);
        clientSendLoop(peer, &lastBlock) catch unreachable;
    }
};

fn clientSendLoop(peer: types.Peer, lastBlock: *types.Block) !void {
    var stdin = std.io.getStdIn();
    var reader = stdin.reader();
    var line_buffer: [256]u8 = undefined;
    while (true) {
        std.debug.print("Enter message for new block: ", .{});
        const maybe_line = try reader.readUntilDelimiterOrEof(line_buffer[0..], '\n');
        if (maybe_line == null) break;
        const user_input = maybe_line.?;
        var new_block = createBlock(user_input, lastBlock.*);
        mineBlock(&new_block, DIFFICULTY);
        var writer = peer.stream.writer();
        const block_json = parser.serializeBlock(new_block) catch unreachable;
        // 必要なサイズのバッファを用意して "BLOCK:" と block_json を連結する
        var buf = try std.heap.page_allocator.alloc(u8, "BLOCK:".len + block_json.len);
        defer std.heap.page_allocator.free(buf);

        // バッファに連結
        @memcpy(buf[0.."BLOCK:".len], "BLOCK:");
        @memcpy(buf["BLOCK:".len..], block_json);

        // 1回の書き出しで送信
        try writer.writeAll(buf);
        lastBlock.* = new_block;
    }
}
```

ClientHandler.runは、--connectモードで接続が確立した際に新規スレッドで呼ばれます。内部でまずcreateTestGenesisBlockを呼んでジェネシスブロックを1つ作成し、lastBlockとして保持します。本来であればサーバー側から最新ブロックをもらって同期すべきですが、簡易実装のため各クライアントはローカルにジェネシスブロックを持つところから始めています。その後、clientSendLoopを呼び出してユーザ入力の処理に入ります。

clientSendLoopではコンソール入力から1行ずつテキストを読み取り、それをブロックに仕立てて送信する処理を無限ループで行います。

- 入力待ちと取得: readUntilDelimiterOrEofを使って標準入力から改行区切りで1行を読み取ります。ユーザが何も入力せずEOF（Ctrl+Dなど）を送った場合はmaybe_line == nullとなり、ループを終了します。
- ブロックの生成と採掘: createBlock(user_input, lastBlock.*)で、直前のブロックを前ブロックとし、入力文字列をデータとした新規ブロックを生成します。次にmineBlock(&new_block, DIFFICULTY)を呼んで、新ブロックのProof of Work計算をします。mineBlock関数は前章までに実装済みで、ブロックのhashフィールドを埋め、ナンスを適切な値に更新する処理です。
- メッセージの組み立て: 新たに生成・採掘したブロックをシリアライズし、ネットワーク送信用のメッセージを作ります。まずparser.serializeBlock(new_block)でブロックをJSON文字列block_jsonに変換します。そして"BLOCK:"プレフィックスを付与したバッファbufを確保し、先頭に"BLOCK:"、続いてblock_jsonの内容をコピーします。
- 送信: 準備したメッセージバッファをwriter.writeAll(buf)で一度に書き込みます。これで接続先（サーバーノード）にブロックデータが送信されます。ログにも送信したブロックのインデックスと送信先アドレスを出力しておきます。
- ブロック履歴の更新: 送信済みのnew_blockをlastBlockに保存し、次回ブロック生成時の「前のブロック」として使います。これにより、ユーザが続けて何度も入力すると、チェインがローカルでも繋がっていくようになります。

このクライアント送信ループにより、ユーザからの入力をトリガーとしてブロックが次々と作られ、ネットワークに流れていく仕組みができました。

### ブロック生成とチェイン更新の補助関数

次に、新しく受信したブロックをチェインに取り込む処理や、ブロックを作成する関数群を実装・確認します。サーバー側で受信したブロックをaddBlockする際、ブロックの検証（PoWが正しいかなど）を行う必要があります。また、クライアント側でも新規ブロック生成時にチェイン情報を更新できるようにしておきます。

以下の関数を実装または確認します。

- verifyBlockPow: 受け取ったブロックが正しく採掘されたもの（ハッシュが内容に一致し、難易度を満たす）か検証します。
- addBlock: ブロックを受信した際、自ノードのブロックチェインに追加する処理です。不正ブロックは弾きます。
- sendBlock: 任意のブロックを指定したアドレスのノードに直接送信する関数です（今回はあまり使いませんが、外部からブロックをプッシュする用途などを想定しています）。
- createBlock: 入力データと直前のブロックから、新しいブロック構造体を作成します（ハッシュ計算前の雛形生成）
- createTestGenesisBlock: テスト用に最初のブロック（ジェネシスブロック）を作成します。

```blockchain.zig
const DIFFICULTY: u8 = 2;
var chain_store = std.ArrayList(types.Block).init(std.heap.page_allocator);

/// verifyBlockPow:
/// ブロックのProof of Work検証を行う関数
pub fn verifyBlockPow(b: *const types.Block) bool {
    // 1) `calculateHash(b)` → meetsDifficulty
    const recalculated = calculateHash(b);
    if (!std.mem.eql(u8, recalculated[0..], b.hash[0..])) {
        return false; // hashフィールドと再計算が一致しない
    }
    if (!meetsDifficulty(recalculated, DIFFICULTY)) {
        return false; // PoWが難易度を満たしていない
    }
    return true;
}

// addBlock: 受け取ったブロックをチェインに追加（検証付き）
pub fn addBlock(new_block: types.Block) void {
    if (!verifyBlockPow(&new_block)) {
        std.log.err("Received block fails PoW check. Rejecting it.", .{});
        return;
    }
    chain_store.append(new_block) catch {};
    std.log.info("Added new block index={d}, nonce={d}, hash={x}", .{ new_block.index, new_block.nonce, new_block.hash });
}

pub fn sendBlock(block: types.Block, remote_addr: std.net.Address) !void {
    const json_data = parser.serializeBlock(block) catch |err| {
        std.debug.print("Serialize error: {any}\n", .{err});
        return err;
    };
    var socket = try std.net.tcpConnectToAddress(remote_addr);
    var writer = socket.writer();
    try writer.writeAll("BLOCK:" ++ json_data);
}

/// createBlock: 新しいブロックを生成
pub fn createBlock(input: []const u8, prevBlock: types.Block) types.Block {
    return types.Block{
        .index = prevBlock.index + 1,
        .timestamp = @intCast(std.time.timestamp()),
        .prev_hash = prevBlock.hash,
        .transactions = std.ArrayList(types.Transaction).init(std.heap.page_allocator),
        .nonce = 0,
        .data = input,
        .hash = [_]u8{0} ** 32,
    };
}

/// createTestGenesisBlock: テスト用のジェネシスブロックを生成
pub fn createTestGenesisBlock(allocator: std.mem.Allocator) !types.Block {
    var genesis = types.Block{
        .index = 0,
        .timestamp = 1672531200,
        .prev_hash = [_]u8{0} ** 32,
        .transactions = std.ArrayList(types.Transaction).init(allocator),
        .nonce = 0,
        .data = "Hello, Zig Blockchain!",
        .hash = [_]u8{0} ** 32,
    };
    try genesis.transactions.append(types.Transaction{ .sender = "Alice", .receiver = "Bob", .amount = 100 });
    mineBlock(&genesis, DIFFICULTY);
    return genesis;
}
```

各関数の説明は以下の通りです。

- verifyBlockPow: ブロックが正当かチェックする関数です。calculateHash(b)でブロック全体からハッシュ値を再計算し、ブロックに記録されているb.hashと一致するか確認します。一致しなければ内容が改ざんされている可能性があるのでfalseを返します。さらにmeetsDifficulty(recalculated, DIFFICULTY)でこのハッシュが難易度条件を満たすかをチェックし、満たしていなければfalseを返します。両方クリアした場合のみtrue（検証OK）となります。
- addBlock: 受信した新規ブロックnew_blockを自ノードのチェインストレージ（ここではchain_storeというArrayList）に追加します。追加前にverifyBlockPowでPoW検証をします。もし、不正なブロックならログにエラーを出して追加処理を終了します。問題なければchain_store.append(new_block)でチェインの末尾に加え、ログにブロックが追加された旨（インデックスやナンス、ハッシュの一部）を出力します。
- sendBlock: 手元にあるblockを、指定したremote_addr（IPアドレスとポート）へ送信するユーティリティ関数です。内部ではstd.net.tcpConnectToAddress(remote_addr)で直接ソケット接続し、"BLOCK:" ++ json_dataという文字列を1回で書き込んで送っています。json_dataはparser.serializeBlockで得たブロックJSONです。この関数はサーバー側から他のノードにブロックをプッシュ通知したい場合などに使えるでしょう。ただし本章のメインの流れでは、クライアント側からサーバーへ送る方式をとっているため直接は使用していません。
- createBlock: 新しいBlock構造体を作ります。prevBlockを引数に取り、そこからindex（前ブロックのindex+1）とprev_hash（前ブロックのハッシュ）を継承します。dataには引数inputをそのまま使います。transactionsリストは空で初期化し、nonceは0、hashもとりあえずゼロクリアした32バイトの配列で作っています。返り値はまだハッシュ計算やPoWを行っていないブロックの雛形です。
- createTestGenesisBlock: テスト用のジェネシスブロックを生成します。index=0、prev_hashは0埋め32バイト、任意のデータ、そしてサンプルで1件のトランザクションを入れています。最後にmineBlockで難易度2のPoWを実行し、適切なnonceとhashを計算してからジェネシスブロックを完成させています。この関数は主にClientHandler開始時に呼び出し、各クライアントに初期ブロックを持たせる目的で使っています。

以上の補助関数によって、ネットワーク越しに受け取ったブロックの検証・追加や、新規ブロックの生成・送信が適切に行われるようになりました。とくにverifyBlockPowとaddBlockによって、不正なブロック（PoW不一致など）がチェインに混入しないよう防いでいます。

## main関数の修正：サーバー/クライアントモードの起動

最後に、main関数を改良して、コマンドライン引数によってノードをサーバーモードかクライアントモードに切り替えます。具体的には以下の2つのオプションを受け付けます。

- --listen port: 指定ポートでサーバーノードとして待ち受けを開始します。
- --connect host:port: 指定ホスト・ポートへ接続するクライアントノードとして動作します。

これらの動作は、前述のConnHandlerやClientHandlerを組み合わせて実現します。修正後のmain関数は次のようになります。

```main.zig
const std = @import("std");
const blockchain = @import("blockchain.zig");
const types = @import("types.zig");
const parser = @import("parser.zig");
const net = std.net;

//------------------------------------------------------------------------------
// メイン処理およびテスト実行
//------------------------------------------------------------------------------
//
// main 関数では、以下の手順を実行しています：
// 1. ジェネシスブロック(最初のブロック)を初期化。
// 2. 取引リスト(トランザクション)の初期化と追加。
// 3. ブロックのハッシュを計算し、指定難易度に到達するまで nonce を探索(採掘)。
// 4. 最終的なブロック情報を標準出力に表示。
pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len < 3) {
        std.log.info("Usage:\n {s} --listen <port>\n or\n {s} --connect <host:port>\n or\n {s} --rpcListen <port>\n", .{ args[0], args[0], args[0] });
        return;
    }
    const mode = args[1];
    if (std.mem.eql(u8, mode, "--listen")) {
        const port_str = args[2];
        const port_num = try std.fmt.parseInt(u16, port_str, 10);
        var address = try std.net.Address.resolveIp("0.0.0.0", port_num);
        var listener = try address.listen(.{});
        defer listener.deinit();
        std.log.info("Listening on 0.0.0.0:{d}", .{port_num});
        while (true) {
            const conn = try listener.accept();
            _ = try std.Thread.spawn(.{}, blockchain.ConnHandler.run, .{conn});
        }
    } else if (std.mem.eql(u8, mode, "--connect")) {
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
        const port_num = try std.fmt.parseInt(u16, port_str, 10);
        std.log.info("Connecting to {s}:{d}...", .{ host_str, port_num });

        // ホスト名を解決する (IPアドレスまたはホスト名の両方に対応)
        var remote_addr: net.Address = undefined;
        if (std.mem.indexOf(u8, host_str, ".") != null) {
            // IPアドレスと思われる場合は直接解決
            remote_addr = try net.Address.resolveIp(host_str, port_num);
        } else {
            // ホスト名の場合はDNS解決を使用
            var list = try net.getAddressList(gpa, host_str, port_num);
            defer list.deinit();

            if (list.addrs.len == 0) {
                std.log.err("Could not resolve hostname: {s}", .{host_str});
                return error.HostNotFound;
            }

            remote_addr = list.addrs[0];
        }

        var socket = try net.tcpConnectToAddress(remote_addr);
        const peer = types.Peer{
            .address = remote_addr,
            .stream = socket,
        };
        _ = try std.Thread.spawn(.{}, blockchain.ClientHandler.run, .{peer});
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
                const new_block = try parser.parseBlockJson(json_part);
                blockchain.addBlock(new_block);
            } else {
                std.log.info("Unknown msg: {s}", .{msg_slice});
            }
        }
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
```

ポイント: クライアントモードでは送信処理と受信処理を分けて、送信は別スレッド(ClientHandler)で行います。受信はメインスレッドで同時並行に動かしています。これによって、ユーザが入力をしている間もサーバーからのメッセージを受け取ることが可能になります。

以上で、サーバー・クライアント両モードの動作がmain関数に組み込まれました。アプリケーションとして、起動時の引数によってP2Pノードとしての役割を変えられるようになっています。

## Dockerfileの修正

Dockerfileを修正して、サーバーモードとクライアントモードの両方を実行できるようにします。以下のように修正します。

```dockerfile
# ベースイメージに Alpine Linux を使用
FROM alpine:latest

# zig の公式バイナリをダウンロードするために必要なツールをインストール
# xz パッケージを追加して tar が .tar.xz を解凍できるようにする
RUN apk add --no-cache curl tar xz

# Zig のバージョンを指定可能にするビルド引数（デフォルトは 0.14.0）
ARG ZIG_VERSION=0.14.0
# ここでは x86_64 用のバイナリを使用する例です
ENV ZIG_DIST=zig-linux-x86_64-${ZIG_VERSION}
ENV ZIG_VERSION=${ZIG_VERSION}

# 指定された Zig のバージョンを公式サイトからダウンロードして解凍し、PATH に追加
RUN curl -LO https://ziglang.org/download/${ZIG_VERSION}/${ZIG_DIST}.tar.xz && \
  tar -xf ${ZIG_DIST}.tar.xz && \
  rm ${ZIG_DIST}.tar.xz
ENV PATH="/${ZIG_DIST}:${PATH}"

# 一般ユーザー appuser を作成し、作業用ディレクトリを設定
RUN addgroup -S appgroup && \
  adduser -S appuser -G appgroup && \
  mkdir -p /app && chown -R appuser:appgroup /app

# 作業ディレクトリを /app に設定
WORKDIR /app

# ホスト側のファイルをコンテナ内にコピーし、所有者を appuser に設定
COPY --chown=appuser:appgroup . .

# 一般ユーザーに切り替え
USER appuser

# コンテナ起動時に Zig ビルドシステムを使って run を実行
CMD ["zig", "build"]
```

## Dcoekr composeの修正

docker-compose.ymlを修正して、サーバーノードとクライアントノードの両方を起動できるようにします。以下のように修正します。

```yaml
# Docker Compose構成ファイル - ブロックチェーンノードネットワーク
#
# 使い方:
# 1. 起動: docker compose up -d
# 2. コンテナでコマンド実行: docker exec -it <container_name> <command>
#    例: docker exec -it node2 sh -c "./zig-out/bin/block_client node1 3000 'Hello'"
#
# 注意: 新しいコンテナを起動するには docker compose run ではなく docker exec を使用してください

# 共通設定
x-common-config: &common-config
  platform: linux/amd64
  volumes:
    - ./:/app
  build: .

services:
  node1:
    <<: *common-config
    container_name: node1
    ports:
      - "3001:3000"
    environment:
      - NODE_ID=1
    command: sh -c "./zig-out/bin/chapter7 --listen 3000"

  node2:
    <<: *common-config
    container_name: node2
    ports:
      - "3002:3000"
    environment:
      - NODE_ID=2
    tty: true
    stdin_open: true
    # 長時間実行するコマンドを追加してコンテナを停止させない
    command: sh -c "tail -f /dev/null"

  node3:
    <<: *common-config
    container_name: node3
    ports:
      - "3003:3000"
    environment:
      - NODE_ID=3
    tty: true
    stdin_open: true
    # 長時間実行するコマンドを追加してコンテナを停止させない
    command: sh -c "tail -f /dev/null"
```

## 動作確認

サーバノードを起動させる。

```bash
zig build run -- --listen 8080
```

クライアントノードを起動させる。

```bash
zig build run -- --connect 127.0.0.1:8080
```

コンソールが表示されたら、適当な文字列を入力して送信。サーバ側には[Received]<文字列> のログが出る。

ブロック送信テスト
クライアントのコンソールから```BLOCK:{"index":2,"nonce":777}```のメッセージを送ってみます。

```bash
❯ zig build run -- --connect 127.0.0.1:8081
info: Connecting to 127.0.0.1:8081...
Enter message for new block: hi
```

```bash
❯ zig build run -- --listen 8081
info: Listening on 0.0.0.0:8081
info: Accepted: 127.0.0.1:60237
info: [Received complete message] BLOCK:{"index":1,"timestamp":1743378871,"nonce":1924,"data":"hi","prev_hash":"000057e288a7d6752e2a3ac81d2a4e9ae04630224e960db236b1e540641e4a1d","hash":"0000a0c6192e846fb8b7499c67c67ecf703045255795457130a7b57b4490567e","transactions":[]}
debug: parseBlockJson start
debug: parseBlockJson start parsed
debug: parseBlockJson end parsed
debug: parseBlockJson start parser
debug: Transactions field is directly an array.
debug: Transactions field is directly an array. end transactions=array_list.ArrayListAligned(main.Transaction,null){ .items = {  }, .capacity = 0, .allocator = mem.Allocator{ .ptr = anyopaque@0, .vtable = mem.Allocator.VTable{ .alloc = fn (*anyopaque, usize, mem.Alignment, usize) ?[*]u8@1023f7dd4, .resize = fn (*anyopaque, []u8, mem.Alignment, usize, usize) bool@1023f832c, .remap = fn (*anyopaque, []u8, mem.Alignment, usize, usize) ?[*]u8@1023f8604, .free = fn (*anyopaque, []u8, mem.Alignment, usize) void@1023f8658 } } }
debug: Block info: index=1, timestamp=1743378871, prev_hash={ 0, 0, 87, 226, 136, 167, 214, 117, 46, 42, 58, 200, 29, 42, 78, 154, 224, 70, 48, 34, 78, 150, 13, 178, 54, 177, 229, 64, 100, 30, 74, 29 }, transactions=array_list.ArrayListAligned(main.Transaction,null){ .items = {  }, .capacity = 0, .allocator = mem.Allocator{ .ptr = anyopaque@0, .vtable = mem.Allocator.VTable{ .alloc = fn (*anyopaque, usize, mem.Alignment, usize) ?[*]u8@1023f7dd4, .resize = fn (*anyopaque, []u8, mem.Alignment, usize, usize) bool@1023f832c, .remap = fn (*anyopaque, []u8, mem.Alignment, usize, usize) ?[*]u8@1023f8604, .free = fn (*anyopaque, []u8, mem.Alignment, usize) void@1023f8658 } } } nonce=1924, data=hi, hash={ 0, 0, 160, 198, 25, 46, 132, 111, 184, 183, 73, 156, 103, 198, 126, 207, 112, 48, 69, 37, 87, 149, 69, 113, 48, 167, 181, 123, 68, 144, 86, 126 }
debug: parseBlockJson end
info: Added new block index=1, nonce=1924, hash={ 0, 0, a0, c6, 19, 2e, 84, 6f, b8, b7, 49, 9c, 67, c6, 7e, cf, 70, 30, 45, 25, 57, 95, 45, 71, 30, a7, b5, 7b, 44, 90, 56, 7e }
```

上記ログの意味を簡単に説明します。

- Accepted: 127.0.0.1:60354はサーバーがクライアントからの接続を受け入れたことを表しています（ポート60354はクライアント側の一時ポートです）。
- ```[Received] BLOCK:{...}```の行で、クライアントから受信したメッセージの中身を表示しています。"data":"hello"となっており、確かにクライアントで入力した文字列がブロックに含まれていることが確認できます。また"index":1や計算された"hash":"0000..."なども表示されています。
- ```Added new block index=1, nonce=1924, hash={0,0,a0,c6...}```のログで、そのブロックがチェインに追加されたことが示されています。nonce=1924はPoW採掘で得られたナンス値であり、この値によってハッシュ先頭に0000が並ぶ難易度条件を確認しています。
- ブロックが共有されたことの確認: サーバーノードがブロックを受け取ってチェインに追加できたので、同じブロックがネットワークで共有されたことになります。必要に応じてサーバー側でチェインの状態を出力する関数（例: dumpChain()など）を作成し、ブロックが確かに追加されているか確認しても良いでしょう。

また、応用として手動でブロックメッセージを送信できます。例えばクライアントのコンソールで、```BLOCK:{"index":2,"nonce":777,"data":"manual",...}```のようにJSON文字列を入力します。そうすると、プログラムはそれをサーバーに送信します。サーバー側はプレフィックスによりブロックJSONだと判断してパースを試みます。実際の運用ではプログラム側が自動でブロックメッセージを生成しますが、開発・テスト中は色々なケースを試すこともできます。

Docker Composeを使って、複数のノードを立ち上げてみます。例えば、node1とnode2を起動し、node1からnode2に接続することで、P2Pネットワークの動作を確認できます。

```bash
docker compose up
[+] Running 3/3
 ✔ Container node1  Recreated                                                                                 0.0s
 ✔ Container node3  Recreated                                                                                 0.1s
 ✔ Container node2  Recreated                                                                                 0.1s
Attaching to node1, node2, node3
node1  | info: Listening on 0.0.0.0:3000
```

Node2に接続して、メッセージを送ります。

```bash
docker exec -it node2 sh -c "./zig-out/bin/chapter7 --connect node1:3000"
info: Connecting to node1:3000...
Enter message for new block: hi
```

すると、node1側に以下のようなログが出力されます。

```bash
node1  | info: Accepted: 172.18.0.4:46888
node1  | info: [Received] BLOCK:{"index":1,"timestamp":1746057682,"nonce":73344,"data":"hi","prev_hash":"0000d00f99225cd2adb3085631456a8ea362d233aa965cb48c0d8f8b488a9022","hash":"0000a3b631a2a32add03bb973470e24a85f2ff94601121d940d4be720176872f","transactions":[]}
node1  | debug: parseBlockJson start
node1  | debug: parseBlockJson start parsed
node1  | debug: parseBlockJson end parsed
node1  | debug: parseBlockJson start parser
node1  | debug: Transactions field is directly an array.
node1  | debug: Transactions field is directly an array. end transactions=array_list.ArrayListAligned(types.Transaction,null){ .items = {  }, .capacity = 0, .allocator = mem.Allocator{ .ptr = anyopaque@0, .vtable = mem.Allocator.VTable{ .alloc = fn (*anyopaque, usize, mem.Alignment, usize) ?[*]u8@1164a00, .resize = fn (*anyopaque, []u8, mem.Alignment, usize, usize) bool@1164fd0, .remap = fn (*anyopaque, []u8, mem.Alignment, usize, usize) ?[*]u8@1165200, .free = fn (*anyopaque, []u8, mem.Alignment, usize) void@1165250 } } }
node1  | debug: Block info: index=1, timestamp=1746057682, prev_hash={ 0, 0, 208, 15, 153, 34, 92, 210, 173, 179, 8, 86, 49, 69, 106, 142, 163, 98, 210, 51, 170, 150, 92, 180, 140, 13, 143, 139, 72, 138, 144, 34 }, transactions=array_list.ArrayListAligned(types.Transaction,null){ .items = {  }, .capacity = 0, .allocator = mem.Allocator{ .ptr = anyopaque@0, .vtable = mem.Allocator.VTable{ .alloc = fn (*anyopaque, usize, mem.Alignment, usize) ?[*]u8@1164a00, .resize = fn (*anyopaque, []u8, mem.Alignment, usize, usize) bool@1164fd0, .remap = fn (*anyopaque, []u8, mem.Alignment, usize, usize) ?[*]u8@1165200, .free = fn (*anyopaque, []u8, mem.Alignment, usize) void@1165250 } } } nonce=73344, data=hi, hash={ 0, 0, 163, 182, 49, 162, 163, 42, 221, 3, 187, 151, 52, 112, 226, 74, 133, 242, 255, 148, 96, 17, 33, 217, 64, 212, 190, 114, 1, 118, 135, 47 }
node1  | debug: parseBlockJson end
node1  | info: Added new block index=1, nonce=73344, hash={ 0, 0, a3, b6, 31, a2, a3, 2a, dd, 3, bb, 97, 34, 70, e2, 4a, 85, f2, ff, 94, 60, 11, 21, d9, 40, d4, be, 72, 1, 76, 87, 2f }
```

### まとめ

- 本章では、単体で動いていたブロックチェインプログラムに対し、TCPソケットを介した簡易P2P通信機能を導入しました。ノード間でブロックを共有する基本的な流れを実装し、あるノードで生成したブロックをネットワーク上の他ノードへ伝達できるようになりました。
- 具体的には、"BLOCK:" + JSONというシンプルなメッセージ形式でブロックデータを送受信し、受信側ではただちにそのJSONをパースして自身のチェインに追加する処理を確認しました。最低限のプロトコル実装ですが、「データの共有と同期」ができています。
- 実際のブロックチェインシステムでは、ここにさらに複雑な機能が加わります（フォーク発生時のチェイン選択アルゴリズム、データ改ざん防止のためのデジタル署名検証、新しいピアの探索と接続管理など）。しかしまずは今回実装したように複数ノードでブロックを共有し同期することが基盤となります。この基盤が正しく動作することで、次の段階でこれら発展的な機能を組み込むことが可能になります。
