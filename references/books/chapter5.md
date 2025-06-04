---
title: "リファクタリングとファイル分割"
free: true
---

本章では、前章までに作成してきたPoW付きブロックチェインのコードをリファクタリングし、複数ファイルへと分割します。1つのmain.zigにすべての処理を詰め込んでいると、コード量が増えるにつれ可読性が落ち、保守も難しくなっていきます。そこで**「ブロックチェインの中核ロジック」と「メイン関数(アプリの入り口)」**を分離し、今後の拡張を見据えたコード構成に整えておきます。

### 分割の方針

1. データ型定義
   1. ブロックチェインに関わる基本的な型（Transaction, Blockなど）を宣言
2. エラー定義
   1. 使い回す共通エラーを集約
3. ユーティリティ関数
   1. toBytesU64などの単純ヘルパー関数
   2. 文字列操作、hexエンコード/デコードなど、ブロックチェイン本体以外にも使い回せる関数
4. debugLogなどのログ周り
5. ブロックチェインの本体
   1. calculateHashやmineBlock, meetsDifficulty, verifyBlockなどのブロックチェイン固有ロジックを実装
   2. 将来的にブロックチェインの同期ロジックを入れる場合もこのファイルに含める、など
6. エントリポイント
   1. すべてのファイルを @import(...) して組み合わせ、アプリ起動
   2. コマンドライン処理（--listen 8080等）や、ブロック生成・出力などの「全体の流れ」を書く

#### ファイル分割

以下は、今お持ちのファイルを参考にした配置例です。

```tree
src/
├── main.zig          # アプリの入り口 (pub fn main() !void)
├── types.zig         # Transaction, Blockなど基本構造体
├── errors.zig        # ChainError など共通エラー
├── utils.zig         # truncateU64ToU8, debugLog などユーティリティ
├── logger.zig        # (必要に応じて) debugLog などのログ専用
└── blockchain.zig    # PoWロジック、calculateHash, mineBlock, etc.
```

## データ型定義の実装

```types.zig
const std = @import("std");

//------------------------------------------------------------------------------
// データ構造
//------------------------------------------------------------------------------
pub const Transaction = struct {
    sender: []const u8,
    receiver: []const u8,
    amount: u64,
};

pub const Block = struct {
    index: u32,
    timestamp: u64,
    prev_hash: [32]u8,
    transactions: std.ArrayList(Transaction),
    nonce: u64,
    data: []const u8,
    hash: [32]u8,
};
```

## エラー定義の実装

```errors.zig
pub const ChainError = error{
    InvalidHexLength,
    InvalidHexChar,
    InvalidFormat,
};
```

## ユーティリティ関数の実装

```utils.zig
const std = @import("std");
const ChainError = @import("errors.zig").ChainError;

//------------------------------------------------------------------------------
// ヘルパー関数
//------------------------------------------------------------------------------

pub fn truncateU32ToU8(x: u32) u8 {
    if (x > 0xff) @panic("u32 out of u8 range");
    return @truncate(x);
}

pub fn truncateU64ToU8(x: u64) u8 {
    if (x > 0xff) @panic("u64 out of u8 range");
    return @truncate(x);
}

pub fn toBytesU32(value: u32) [4]u8 {
    var buf: [4]u8 = undefined;
    buf[0] = truncateU32ToU8(value & 0xff);
    buf[1] = truncateU32ToU8((value >> 8) & 0xff);
    buf[2] = truncateU32ToU8((value >> 16) & 0xff);
    buf[3] = truncateU32ToU8((value >> 24) & 0xff);
    return buf;
}

pub fn toBytesU64(value: u64) [8]u8 {
    var buf: [8]u8 = undefined;
    buf[0] = truncateU64ToU8(value & 0xff);
    buf[1] = truncateU64ToU8((value >> 8) & 0xff);
    buf[2] = truncateU64ToU8((value >> 16) & 0xff);
    buf[3] = truncateU64ToU8((value >> 24) & 0xff);
    buf[4] = truncateU64ToU8((value >> 32) & 0xff);
    buf[5] = truncateU64ToU8((value >> 40) & 0xff);
    buf[6] = truncateU64ToU8((value >> 48) & 0xff);
    buf[7] = truncateU64ToU8((value >> 56) & 0xff);
    return buf;
}

// publicにする: main.zigから呼べるようにする
pub fn toBytes(comptime T: type, value: T) []const u8 {
    if (T == u32) {
        return toBytesU32(@as(u32, value))[0..];
    } else if (T == u64) {
        return toBytesU64(@as(u64, value))[0..];
    } else {
        const bytes: [@sizeOf(T)]u8 = @bitCast(value);
        return bytes[0..];
    }
}
```

## ログ周りの実装

```logger.zig
const std = @import("std");

pub const debug_logging = false;

/// debugLog:
/// デバッグログを出力するためのヘルパー関数です。
/// ※ debug_logging が true の場合のみ std.debug.print を呼び出します。
pub fn debugLog(comptime format: []const u8, args: anytype) void {
    if (comptime debug_logging) {
        std.debug.print(format, args);
    }
}
```

## ブロックチェインの本体の実装

```blockchain.zig
const std = @import("std");
const crypto = std.crypto.hash;
const Sha256 = crypto.sha2.Sha256;
const types = @import("types.zig");
const logger = @import("logger.zig");
const utils = @import("utils.zig");

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
pub fn calculateHash(block: *const types.Block) [32]u8 {
    var hasher = Sha256.init(.{});

    // nonce の値をバイト列に変換(8バイト)し、デバッグ用に出力
    const nonce_bytes = utils.toBytesU64(block.nonce);
    logger.debugLog("nonce bytes: ", .{});
    if (comptime logger.debug_logging) {
        for (nonce_bytes) |byte| {
            std.debug.print("{x:0>2},", .{byte});
        }
        std.debug.print("\n", .{});
    }

    // ブロック番号 (u32) をバイト列に変換して追加
    hasher.update(utils.toBytes(u32, block.index));
    // タイムスタンプ (u64) をバイト列に変換して追加
    hasher.update(utils.toBytes(u64, block.timestamp));
    // nonce のバイト列を追加
    hasher.update(nonce_bytes[0..]);
    // 前ブロックのハッシュ(32バイト)を追加
    hasher.update(&block.prev_hash);

    // すべてのトランザクションについて、各フィールドを追加
    for (block.transactions.items) |tx| {
        hasher.update(tx.sender);
        hasher.update(tx.receiver);
        const amount_bytes = utils.toBytesU64(tx.amount);
        hasher.update(&amount_bytes);
    }
    // 追加データをハッシュに追加
    hasher.update(block.data);

    // 最終的なハッシュ値を計算
    const hash = hasher.finalResult();
    logger.debugLog("nonce: {d}, hash: {x}\n", .{ block.nonce, hash });
    return hash;
}

/// meetsDifficulty:
/// ハッシュ値の先頭 'difficulty' バイトがすべて 0 であれば true を返す。
pub fn meetsDifficulty(hash: [32]u8, difficulty: u8) bool {
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
pub fn mineBlock(block: *types.Block, difficulty: u8) void {
    while (true) {
        const new_hash = calculateHash(block);
        if (meetsDifficulty(new_hash, difficulty)) {
            block.hash = new_hash;
            break;
        }
        block.nonce += 1;
    }
}

```

## エントリポイントの実装

```main.zig
// main.zig

const std = @import("std");
const types = @import("types.zig");
const blockchain = @import("blockchain.zig");
const mem = std.testing.allocator;

//------------------------------------------------------------------------------
// メイン処理
//------------------------------------------------------------------------------
//
// main 関数では、以下の手順を実行しています：
// 1. ジェネシスブロック(最初のブロック)を初期化。
// 2. 取引リスト(トランザクション)の初期化と追加。
// 3. ブロックのハッシュを計算し、指定難易度に到達するまで nonce を探索(採掘)。
// 4. 最終的なブロック情報を標準出力に表示。
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().writer();

    // 1. ジェネシスブロックを作成
    //    (細かい値は適宜変更)
    var genesis_block = types.Block{
        .index = 0,
        .timestamp = 1672531200,
        .prev_hash = [_]u8{0} ** 32,
        .transactions = std.ArrayList(types.Transaction).init(allocator),
        .nonce = 0,
        .data = "Hello, Zig Blockchain!",
        .hash = [_]u8{0} ** 32,
    };
    defer genesis_block.transactions.deinit();

    // 2. 適当なトランザクションを追加
    try genesis_block.transactions.append(types.Transaction{
        .sender = "Alice",
        .receiver = "Bob",
        .amount = 100,
    });
    try genesis_block.transactions.append(types.Transaction{
        .sender = "Charlie",
        .receiver = "Dave",
        .amount = 50,
    });

    // 3. 初期ハッシュを計算
    genesis_block.hash = blockchain.calculateHash(&genesis_block);
    // 4. マイニング(難易度=1)
    blockchain.mineBlock(&genesis_block, 1);

    // 5. 結果を表示
    try stdout.print("Block index: {d}\n", .{genesis_block.index});
    try stdout.print("Timestamp  : {d}\n", .{genesis_block.timestamp});
    try stdout.print("Nonce      : {d}\n", .{genesis_block.nonce});
    try stdout.print("Data       : {s}\n", .{genesis_block.data});
    for (genesis_block.transactions.items) |tx| {
        try stdout.print("- Tx: {s} -> {s} : {d}\n", .{ tx.sender, tx.receiver, tx.amount });
    }
    try stdout.print("Hash       : ", .{});
    for (genesis_block.hash) |byte| {
        try stdout.print("{x}", .{byte});
    }
    try stdout.print("\n", .{});
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
        .transactions = std.ArrayList(types.Transaction).init(mem),
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
        .transactions = std.ArrayList(types.Transaction).init(mem),
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

## 動作確認

分割後のコードが正常に動作するか確認します。

```bash
❯ zig build run
Block index: 0
Timestamp  : 1672531200
Nonce      : 698
Data       : Hello, Zig Blockchain!
- Tx: Alice -> Bob : 100
- Tx: Charlie -> Dave : 50
Hash       : 01fc976b652c64979aa83734fc577e64b2afa48d92bb0d3fec7bd76c2f8db
```

もしくはdocker composeで実行できます。

```bash
❯ docker compose up
[+] Running 4/4
 ✔ Network chapter5_default  Created                                                     0.0s
 ✔ Container node2           Created                                                     0.1s
 ✔ Container node3           Created                                                     0.1s
 ✔ Container node1           Created                                                     0.1s
Attaching to node1, node2, node3
node3  | Block index: 0
node3  | Timestamp  : 1672531200
node3  | Nonce      : 96
node3  | Data       : Hello, Zig Blockchain!
node3  | - Tx: Alice -> Bob : 100
node3  | - Tx: Charlie -> Dave : 50
node3  | Hash       : 04bf9e5b025756adadbe4e6fe68eeebcfe2f7939e83fb57ba45f37f196a9a
node1  | Block index: 0
node1  | Timestamp  : 1672531200
node1  | Nonce      : 96
node1  | Data       : Hello, Zig Blockchain!
node1  | - Tx: Alice -> Bob : 100
node1  | - Tx: Charlie -> Dave : 50
node1  | Hash       : 04bf9e5b025756adadbe4e6fe68eeebcfe2f7939e83fb57ba45f37f196a9a
node2  | Block index: 0
node2  | Timestamp  : 1672531200
node2  | Nonce      : 96
node2  | Data       : Hello, Zig Blockchain!
node2  | - Tx: Alice -> Bob : 100
node2  | - Tx: Charlie -> Dave : 50
node2  | Hash       : 04bf9e5b025756adadbe4e6fe68eeebcfe2f7939e83fb57ba45f37f196a9a
node3 exited with code 0
node1 exited with code 0
node2 exited with code 0
```

また、テストも分割後のコードで実行できるか確認します。

```bash
❯ zig build test
```

## まとめと今後の拡張について

ファイル分割によって責務が明確化され、可読性・保守性が向上し、今後の拡張（ピアツーピア通信やウォレット機能など）を追加するときも、ファイル単位でレイヤー分けしやすくなります。
また、ビルドやテストの単位もファイル単位で行えるようになります。
これでPoWブロックチェインの基本コードを分割したリファクタリングが完了です。次章では、この分割された構造を活かしてP2P通信を導入し、複数ノード間でブロックをやりとりする仕組みを実装していきましょう。
