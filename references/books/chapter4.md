---
title: "簡単なPoW(Proof of Work)の実装"
free: true
---


## ステップ1: 簡単なPoW(Proof of Work)の実装

次に、ブロックチェインの**Proof of Work (PoW)** をシンプルに再現してみます。PoWはブロックチェイン(特にビットコイン)で採用されている**合意形成アルゴリズム**で、不正防止のために計算作業(=仕事, Work)を課す仕組みです。

**PoWの仕組み**: ブロックにナンス値(`nonce`)と呼ばれる余分な数値を付加し、その`nonce`を色々変えながらブロック全体のハッシュ値を計算します。
ナンスはNumber Used Onceの略で、一度しか使わない数値という意味です。

特定の条件(例えば「ハッシュ値の先頭nビットが0になる」など)を満たす`nonce`を見つけるまで、試行錯誤でハッシュ計算を繰り返す作業がPoWです。 ([Understanding Proof of Work in Blockchain - DEV Community](https://dev.to/blessedtechnologist/understanding-proof-of-work-in-blockchain-l2k#:~:text=difficult%20to%20solve%20but%20straightforward,000000abc))。

この条件を満たすハッシュ値を見つけるには運試し的に大量の計算をする必要がありますが、**一度条件を満たしたブロックが見つかればその検証(ハッシュを再計算して条件を満たすか確認)は非常に容易**です。つまり、「解くのは難しいが答え合わせは簡単」なパズルを各ブロックに課しているわけです。

**難易度 (difficulty)**: 条件の厳しさは「ハッシュ値の先頭に何個の0が並ぶか」などで表現され、必要な先頭の0が多いほど計算量(難易度)が指数関数的に増大します。
 ([Understanding Proof of Work in Blockchain - DEV Community](https://dev.to/blessedtechnologist/understanding-proof-of-work-in-blockchain-l2k#:~:text=Difficulty%20is%20quantified%20by%20the,increases%20the%20computational%20effort%20needed))。

 ネットワーク全体のマイニング速度に応じて、この難易度は適宜調整されるようになっています。ビットコインでは約2週間ごとにブロック生成速度が10分/blockになるよう難易度調整。

それでは、このPoWのアイデアを使って、ブロックに**マイニング(nonce探し)**の処理を追加しましょう。

### nonceフィールドの追加

Block構造体に`nonce`(ナンス)を追加します。

```zig
const Block = struct {
    index: u32,
    timestamp: u64,
    prev_hash: [32]u8,
    transactions: std.ArrayList(Transaction),
    data: []const u8, // (必要に応じて省略可能)
    nonce: u64, // PoW用のnonce
    hash: [32]u8,
};
```

ブロックのハッシュ計算時に、この`nonce`も入力データに含めるよう`calculateHash`関数を修正しておきます。

```zig
fn calculateHash(block: *const Block) [32]u8 {
    var hasher = Sha256.init(.{});

    // index と timestamp
    hasher.update(toBytes(u32, block.index));
    hasher.update(toBytes(u64, block.timestamp));

    // 前のブロックのハッシュ
    hasher.update(block.prev_hash[0..]);

    // ここで nonce を加える
    hasher.update(toBytes(u64, block.nonce));

    // トランザクションの各要素をまとめてハッシュ
    for (block.transactions.items) |tx| {
        hasher.update(tx.sender);
        hasher.update(tx.receiver);
        hasher.update(toBytes(u64, tx.amount));
    }

    // 既存コードとの互換を保つため、data もハッシュに含める
    hasher.update(block.data);

    return hasher.finalResult();
}
```

コード全体は以下のようになります。

```zig
const std = @import("std");
const crypto = std.crypto.hash;
const Sha256 = crypto.sha2.Sha256;

/// トランザクションの構造体
/// 送信者(sender), 受信者(receiver), 金額(amount) の3つだけを持つ。
const Transaction = struct {
    sender: []const u8,
    receiver: []const u8,
    amount: u64,
    // 本来は署名やトランザクションIDなどの要素が必要
};

/// ブロックの構造体
/// - index: ブロック番号
/// - timestamp: 作成時刻
/// - prev_hash: 前ブロックのハッシュ(32バイト)
/// - transactions: 動的配列を使って複数のトランザクションを保持
/// - nonce: PoW用のnonce
/// - data: 既存コードとの互換を保つために残す(省略可)
/// - hash: このブロックのSHA-256ハッシュ(32バイト)
const Block = struct {
    index: u32,
    timestamp: u64,
    prev_hash: [32]u8,
    transactions: std.ArrayList(Transaction),
    data: []const u8, // (必要に応じて省略可能)
    nonce: u64, // PoW用のnonce
    hash: [32]u8,
};

/// toBytes関数は、任意の型Tの値をそのメモリ表現に基づく固定長のバイト配列に再解釈し、
/// その全要素を含むスライス([]const u8)として返します。
fn toBytes(comptime T: type, value: T) []const u8 {
    // 左辺で返り値の型を [@sizeOf(T)]u8 として指定する
    const bytes: [@sizeOf(T)]u8 = @bitCast(value);
    // 固定長配列を全体スライスとして返す
    return bytes[0..@sizeOf(T)];
}

/// calculateHash関数
/// ブロックの各フィールドを順番にハッシュ計算へ渡し、最終的なSHA-256ハッシュを得る。
fn calculateHash(block: *const Block) [32]u8 {
    var hasher = Sha256.init(.{});

    // indexとtimestampをバイト列へ変換
    hasher.update(toBytes(u32, block.index));
    hasher.update(toBytes(u64, block.timestamp));

    // 前のブロックのハッシュは配列→スライスで渡す
    hasher.update(block.prev_hash[0..]);

    // ブロックに保持されているトランザクション一覧をまとめてハッシュ
    for (block.transactions.items) |tx| {
        hasher.update(tx.sender);
        hasher.update(tx.receiver);
        hasher.update(toBytes(u64, tx.amount));
    }

    // 既存コードとの互換を保つため、dataもハッシュに含める
    hasher.update(block.data);

    return hasher.finalResult();
}

/// main関数:ブロックの初期化、ハッシュ計算、及び結果の出力を行います。
pub fn main() !void {
    // メモリ割り当て用アロケータを用意(ページアロケータを簡易使用)
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().writer();

    // ジェネシスブロック(最初のブロック)を作成
    var genesis_block = Block{
        .index = 0,
        .timestamp = 1672531200,
        .prev_hash = [_]u8{0} ** 32, // 前ブロックが無いので全0にする
        // アロケータの初期化は後で行うため、いったんundefinedに
        .transactions = undefined,
        .data = "Hello, Zig Blockchain!",
        .nonce = 0, //nonceフィールドを初期化(0から始める)
        .hash = [_]u8{0} ** 32,
    };

    // transactionsフィールドを動的配列として初期化
    genesis_block.transactions = std.ArrayList(Transaction).init(allocator);
    defer genesis_block.transactions.deinit();

    // トランザクションを2件追加
    try genesis_block.transactions.append(Transaction{
        .sender = "Alice",
        .receiver = "Bob",
        .amount = 100,
    });
    try genesis_block.transactions.append(Transaction{
        .sender = "Charlie",
        .receiver = "Dave",
        .amount = 50,
    });
    // calculateHash()でブロックの全フィールドからハッシュを計算し、hashフィールドに保存する
    genesis_block.hash = calculateHash(&genesis_block);

    // 結果を出力
    try stdout.print("Block index: {d}\n", .{genesis_block.index});
    try stdout.print("Timestamp  : {d}\n", .{genesis_block.timestamp});
    try stdout.print("Nonce      : {d}\n", .{genesis_block.nonce});
    try stdout.print("Data       : {s}\n", .{genesis_block.data});
    try stdout.print("Transactions:\n", .{});
    for (genesis_block.transactions.items) |tx| {
        try stdout.print("  {s} -> {s} : {d}\n", .{ tx.sender, tx.receiver, tx.amount });
    }
    try stdout.print("Hash       : ", .{}); // ← ここはプレースホルダなし、引数なし
    // 32バイトのハッシュを1バイトずつ16進数で出力
    for (genesis_block.hash) |byte| {
        try stdout.print("{x}", .{byte});
    }
    try stdout.print("\n", .{});
}
```

実行してみると以下のようにnonceが0から始まっていることが確認できます。現状のコードでは、nonceを追加してハッシュ計算に含めるだけです。マイニング(nonceを変えながら特定条件を満たすまで試行錯誤する処理)をまだ実装していないので、nonce=0がずっと使われているだけになります。ただし、ハッシュ計算時にnonceも投入しているので、後ほどマイニングを実装したときにnonceを変化させるとハッシュ値も変化するようになっています。

```bash
❯ zig build run
Block index: 0
Timestamp  : 1672531200
Nonce      : 0
Data       : Hello, Zig Blockchain!
Transactions:
  Alice -> Bob : 100
  Charlie -> Dave : 50
Hash       : d7928f7e56537c9e97ce858e7c8fbc211c2336f32b32d8edc707cdda271142b
```

もしくはdocker composeで実行できます。

```bash
❯ docker compose up
[+] Running 4/4
 ✔ Network step4_default  Created                                                                0.1s
 ✔ Container node3        Created                                                                0.1s
 ✔ Container node1        Created                                                                0.1s
 ✔ Container node2        Created                                                                0.1s
Attaching to node1, node2, node3
node2  | Block index: 0
node2  | Timestamp  : 1672531200
node2  | Nonce      : 0
node2  | Data       : Hello, Zig Blockchain!
node2  | Transactions:
node2  |   Alice -> Bob : 100
node2  |   Charlie -> Dave : 50
node2  | Hash       : e8393c1fc14302185d8357b9c906b72595c4c1a72b834f89491faf214cfe7
node2 exited with code 0
node1  | Block index: 0
node1  | Timestamp  : 1672531200
node1  | Nonce      : 0
node1  | Data       : Hello, Zig Blockchain!
node1  | Transactions:
node1  |   Alice -> Bob : 100
node1  |   Charlie -> Dave : 50
node1  | Hash       : e8393c1fc14302185d8357b9c906b72595c4c1a72b834f89491faf214cfe7
node3  | Block index: 0
node3  | Timestamp  : 1672531200
node3  | Nonce      : 0
node3  | Data       : Hello, Zig Blockchain!
node3  | Transactions:
node3  |   Alice -> Bob : 100
node3  |   Charlie -> Dave : 50
node3  | Hash       : e8393c1fc14302185d8357b9c906b72595c4c1a72b834f89491faf214cfe7
node1 exited with code 0
node3 exited with code 0
```

### マイニング(nonceの探索)

今のコード状態では、nonceを増やす処理は無いので、いつ見てもnonce=0です。
次に、実際のPoWマイニングを簡単に再現するには以下のような関数を導入します。
マイニングでは、`nonce`の値を0から始めて1ずつ増やしながら繰り返しハッシュを計算し、条件に合致するハッシュが出るまでループします。
条件とは今回は簡単のため「ハッシュ値の先頭のバイトが一定数0であること」と定義しましょう。例えば難易度を`difficulty = 2`とした場合、「ハッシュ値配列の先頭2バイトが0×00であること」とします。
(これは16進数で「0000....」と始まるハッシュという意味で、先頭16ビットがゼロという条件です)。

#### ステップ2: マイニング関数の追加

ブロックの**PoWマイニング**を実装するには、以下の2つの関数を用意します。

1. **`meetsDifficulty(hash: [32]u8, difficulty: u8) bool`**
   - ハッシュ配列の先頭 `difficulty` バイトがすべて `0x00` かを確認する関数。
   - 先頭Nバイトが0なら「条件を満たした」と判断し、`true`を返します。
   - 例えば `difficulty = 2`なら、`hash[0] == 0`かつ`hash[1] == 0`であればOK(=先頭16ビットが0)。

2. **`mineBlock(block: *Block, difficulty: u8) void`**
   - 無限ループの中で`calculateHash`を呼び出し、`meetsDifficulty`で合格か判定。
   - 見つからなければ`block.nonce += 1;`で`nonce`を増やし、再びハッシュ計算を繰り返す。
   - 条件を満たせば`block.hash`に最終ハッシュを設定し、ループを抜ける。

```zig
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
```

- `difficulty` は先頭に何バイト `0x00` が並んでいれば良いかを指定します。
- `difficulty = 2` でも場合によっては何万回とハッシュ計算が繰り返されるため、テスト時は**値を小さめ**にするのがおすすめです。

`meetsDifficulty`はハッシュ配列の先頭から指定バイト数をチェックし、すべて`0x00`ならtrueを返す関数です。`mineBlock`では無限ループの中で`calculateHash`を呼び出し、難易度条件を満たしたらループを抜けます。見つからなければ`nonce`を増やして再度ハッシュ計算、という流れです。

難易度`difficulty`は調整可能ですが、大きな値にすると探索に非常に時間がかかるため、ローカルで試す場合は小さな値に留めましょう(例えば1や2程度)。`difficulty = 2`でも場合によっては数万回以上のループが必要になることがあります。PoWは計算量をわざと大きくすることで、ブロック生成にコストを課す仕組みだということを念頭に置いてください。

以上で、ブロックに対してPoWを行いハッシュ値の条件を満たすようにする「マイニング」処理が完成しました。これにより、新しいブロックを正式にチェインに繋げることができます。改ざんしようとする者は、このPoWを再度解かなければならないため、改ざんのコストも非常に高くなります。

### マイニング処理の追加

toBytes関数も見直します。以下のように変換関数を追加して、u32やu64の値をリトルエンディアンのバイト列に変換するヘルパー関数を用意します。

```zig
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
```

ハッシュ値の計算に、nonceの値をバイト列に変換して追加する処理を追加します。また、デバッグログを出力するための`debugLog`関数も追加します。

```zig
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
```

---

## 全体コード例

これまでのコードに加え、`mineBlock`を呼び出して実際にマイニングを行う例を下記に示します。

```zig
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
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().writer();

    // ジェネシスブロックの初期化
    var genesis_block = Block{
        .index = 0,
        .timestamp = 1672531200, // 例: 2023-01-01 00:00:00 UTC
        .prev_hash = [_]u8{0} ** 32, // 前ブロックがないので全て 0
        .transactions = undefined, // 後で初期化するため一旦 undefined
        .data = "Hello, Zig Blockchain!", // ブロックに付随する任意データ
        .nonce = 0, // nonce は 0 から開始
        .hash = [_]u8{0} ** 32, // 初期状態ではハッシュは全0
    };

    // トランザクションリストの初期化
    genesis_block.transactions = std.ArrayList(Transaction).init(allocator);
    defer genesis_block.transactions.deinit();

    // 例として 2 件のトランザクションを追加
    try genesis_block.transactions.append(Transaction{
        .sender = "Alice",
        .receiver = "Bob",
        .amount = 100,
    });
    try genesis_block.transactions.append(Transaction{
        .sender = "Charlie",
        .receiver = "Dave",
        .amount = 50,
    });

    // ブロックの初期ハッシュを計算
    genesis_block.hash = calculateHash(&genesis_block);
    // 難易度 1(先頭1バイトが 0)になるまで nonce を探索する
    mineBlock(&genesis_block, 1);

    // 結果を標準出力に表示
    try stdout.print("Block index: {d}\n", .{genesis_block.index});
    try stdout.print("Timestamp  : {d}\n", .{genesis_block.timestamp});
    try stdout.print("Nonce      : {d}\n", .{genesis_block.nonce});
    try stdout.print("Data       : {s}\n", .{genesis_block.data});
    try stdout.print("Transactions:\n", .{});
    for (genesis_block.transactions.items) |tx| {
        try stdout.print("  {s} -> {s} : {d}\n", .{ tx.sender, tx.receiver, tx.amount });
    }
    try stdout.print("Hash       : ", .{});
    for (genesis_block.hash) |byte| {
        try stdout.print("{x}", .{byte});
    }
    try stdout.print("\n", .{});
}
```

---

## 実行結果

実行すると、`nonce`が0から始まり、**ハッシュが先頭2バイト「00 00」になるまで**試行します。見つかればそこで終了し、`nonce`が大きな値になることもあります。

```bash
❯ zig build run
Block index: 0
Timestamp  : 1672531200
Nonce      : 49954
Data       : Hello, Zig Blockchain!
Transactions:
  Alice -> Bob : 100
  Charlie -> Dave : 50
Hash       : 001da5a39756df66c7bd9f6db2d2cbbaff48b779ccf25569bac9a997c13d
```

もしくはdocker composeで実行できます。

```bash
❯ docker compose up
[+] Running 4/4
 ✔ Network step4-2_default  Created                                                              0.1s
 ✔ Container node3          Created                                                              0.0s
 ✔ Container node2          Created                                                              0.1s
 ✔ Container node1          Created                                                              0.0s
Attaching to node1, node2, node3
node2  | Block index: 0
node2  | Timestamp  : 1672531200
node2  | Nonce      : 51858
node2  | Data       : Hello, Zig Blockchain!
node2  | Transactions:
node2  |   Alice -> Bob : 100
node2  |   Charlie -> Dave : 50
node2  | Hash       : 00c081305c640b6ab5216a3ed6c5bf61d1e4690f981e2c8da905ff866eba7
node1  | Block index: 0
node1  | Timestamp  : 1672531200
node1  | Nonce      : 51858
node1  | Data       : Hello, Zig Blockchain!
node1  | Transactions:
node1  |   Alice -> Bob : 100
node1  |   Charlie -> Dave : 50
node1  | Hash       : 00c081305c640b6ab5216a3ed6c5bf61d1e4690f981e2c8da905ff866eba7
node3  | Block index: 0
node3  | Timestamp  : 1672531200
node3  | Nonce      : 51858
node3  | Data       : Hello, Zig Blockchain!
node3  | Transactions:
node3  |   Alice -> Bob : 100
node3  |   Charlie -> Dave : 50
node3  | Hash       : 00c081305c640b6ab5216a3ed6c5bf61d1e4690f981e2c8da905ff866eba7
node2 exited with code 0
node1 exited with code 0
node3 exited with code 0
```

- ビットコインでは**先頭の0ビット**を難易度として扱い、だいたい毎回10分で見つかるぐらいに調整しています。
- この例のようにバイト単位で先頭2バイトを0にするだけでも、運が悪いと何十万,何百万回と試行することがあり得ます。
- 難易度を1や2程度にしておけば比較的すぐにハッシュが見つかるはずです。

---

## まとめ

- **`nonce`を0から増やす**ことで、ブロックのハッシュ値が大きく変化します。
- 先頭数バイトが0になる(または先頭Nビットが0)などの**難易度設定**に合致したら**ループ終了**。これが簡単なPoWの仕組みです。
- 一度見つかったブロックを改ざんしようとすると、`nonce`を再度見つけ直さなければならないため、改ざんコストが跳ね上がります。

これで**マイニング**の基本(nonce探索ループ)が完成しました。難易度を変化させれば、探索にかかる試行回数も変動します。これを**複数のブロック**に適用し、前のブロックのハッシュを`prev_hash`に設定しながら連結すれば、いよいよ「チェイン」としての改ざん耐性を試せるようになります。

### ステップ3: テストコードを書く

Zigには組み込みのテスト機能があり、`test "名前"`ブロックの中にテストコードを書くことができます ([ArrayList | zig.guide](https://zig.guide/standard-library/arraylist/#:~:text=test%20,World))。テストブロック内では`std.testing.expect`マクロを使って式が期待通りの結果かチェックできます ([ArrayList | zig.guide](https://zig.guide/standard-library/arraylist/#:~:text=test%20,World))。ブロックチェインの動作検証として、一例として「ブロックが改ざんを検出できること」をテストしてみます。

```zig
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
```

このテストでは、最初にAliceからBobへ100の送金トランザクションを含むブロックを作り、そのブロックのハッシュを求めています。次にブロック内の取引金額を100から200に改ざんし、再度ハッシュを計算します。`std.testing.expect(... == false)`によって、改ざん前後でハッシュが一致しない(つまり改ざんを検出できる)ことを検証しています。実行時にこの期待が満たされない場合(もし改ざんしてもハッシュが変わらなかった場合など)はテストが失敗し、エラーが報告されます。

テストコードは、ファイル内に記述して`zig test ファイル名.zig`で実行できます。`zig build test`を使えばビルドシステム経由でプロジェクト内のすべてのテストを実行できます。上記テストを走らせて**パスすれば、ブロックの改ざん検知ロジックが正しく機能している**ことになります。

コード全体は以下のようになります。

```zig
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
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().writer();

    // ジェネシスブロックの初期化
    var genesis_block = Block{
        .index = 0,
        .timestamp = 1672531200, // 例: 2023-01-01 00:00:00 UTC
        .prev_hash = [_]u8{0} ** 32, // 前ブロックがないので全て 0
        .transactions = undefined, // 後で初期化するため一旦 undefined
        .data = "Hello, Zig Blockchain!", // ブロックに付随する任意データ
        .nonce = 0, // nonce は 0 から開始
        .hash = [_]u8{0} ** 32, // 初期状態ではハッシュは全0
    };

    // トランザクションリストの初期化
    genesis_block.transactions = std.ArrayList(Transaction).init(allocator);
    defer genesis_block.transactions.deinit();

    // 例として 2 件のトランザクションを追加
    try genesis_block.transactions.append(Transaction{
        .sender = "Alice",
        .receiver = "Bob",
        .amount = 100,
    });
    try genesis_block.transactions.append(Transaction{
        .sender = "Charlie",
        .receiver = "Dave",
        .amount = 50,
    });

    // ブロックの初期ハッシュを計算
    genesis_block.hash = calculateHash(&genesis_block);
    // 難易度 1(先頭1バイトが 0)になるまで nonce を探索する
    mineBlock(&genesis_block, 1);

    // 結果を標準出力に表示
    try stdout.print("Block index: {d}\n", .{genesis_block.index});
    try stdout.print("Timestamp  : {d}\n", .{genesis_block.timestamp});
    try stdout.print("Nonce      : {d}\n", .{genesis_block.nonce});
    try stdout.print("Data       : {s}\n", .{genesis_block.data});
    try stdout.print("Transactions:\n", .{});
    for (genesis_block.transactions.items) |tx| {
        try stdout.print("  {s} -> {s} : {d}\n", .{ tx.sender, tx.receiver, tx.amount });
    }
    try stdout.print("Hash       : ", .{});
    for (genesis_block.hash) |byte| {
        try stdout.print("{x}", .{byte});
    }
    try stdout.print("\n", .{});
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
```

## おわりに

本チャプターでは、Zigを用いてブロックチェインの最も基本的な部分を実装しました。**ブロック構造の定義**から始まり、**トランザクションの取り扱い**、**ハッシュによるブロックの連結**、そして**Proof of Workによるマイニング**まで、一通りの流れを体験できたはずです。完成したプログラムはシンプルながら、ブロックチェインの改ざん耐性やワークロード証明の仕組みを備えています。

実際のブロックチェインシステムでは、この他にも様々な要素があります。

- **ピアツーピアネットワーク**による分散ノード間の通信
- **トランザクションのデジタル署名と検証**
- **コンセンサスアルゴリズムの調整**
- **ブロックサイズや報酬の管理**

などです。
