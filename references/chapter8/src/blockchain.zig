//! ブロックチェーンコア実装モジュール
//!
//! このモジュールはブロック作成、マイニング、検証、チェーン管理などの
//! コアブロックチェーン機能を実装しています。ブロックハッシュの計算、
//! プルーフオブワークによる新しいブロックのマイニング、ブロックチェーン状態の
//! 維持のための関数を提供します。

const std = @import("std");
const crypto = std.crypto.hash;
const Sha256 = crypto.sha2.Sha256;
const types = @import("types.zig");
const logger = @import("logger.zig");
const utils = @import("utils.zig");
const chainError = @import("errors.zig").ChainError;
const parser = @import("parser.zig");

/// プルーフオブワークマイニングの難易度設定
/// 有効なブロックハッシュに必要な先頭のゼロバイト数を表します
const DIFFICULTY: u8 = 2;

/// メインブロックチェーンデータストレージ
/// 完全なブロックチェーンをBlock構造体の動的配列として格納します
pub var chain_store = std.ArrayList(types.Block).init(std.heap.page_allocator);

/// ブロック追加の判定結果。呼び出し側は`added`のときだけ再伝播します。
pub const AddBlockResult = enum {
    added,
    duplicate,
    invalid_pow,
    invalid_link,
    out_of_memory,
};

var chain_store_mutex = std.Thread.Mutex{};

//------------------------------------------------------------------------------
// ハッシュ計算とマイニング関数
//------------------------------------------------------------------------------

/// ブロックの暗号学的ハッシュを計算する
///
/// すべての関連フィールド（インデックス、タイムスタンプ、ノンス、
/// 前のハッシュ、トランザクション、データ）をバイトシーケンスに
/// 連結してハッシュすることにより、ブロックの内容のSHA-256ハッシュを計算します。
///
/// 引数:
///     block: ハッシュ化するBlock構造体へのポインタ
///
/// 戻り値:
///     [32]u8: ブロックの32バイトのSHA-256ハッシュ
pub fn calculateHash(block: *const types.Block) [32]u8 {
    var hasher = Sha256.init(.{});

    // ノンスをバイト配列に変換し、デバッグ用にログ出力
    const nonce_bytes = utils.toBytesU64(block.nonce);
    logger.debugLog("nonce bytes: ", .{});
    if (comptime logger.debug_logging) {
        for (nonce_bytes) |byte| {
            std.debug.print("{x:0>2},", .{byte});
        }
        std.debug.print("\n", .{});
    }

    // ハッシュ計算にブロックフィールドを順番に追加
    const index_bytes = utils.toBytes(u32, block.index);
    const timestamp_bytes = utils.toBytes(u64, block.timestamp);
    hasher.update(&index_bytes);
    hasher.update(&timestamp_bytes);
    hasher.update(nonce_bytes[0..]);
    hasher.update(&block.prev_hash);

    // すべてのトランザクションデータをハッシュに追加
    for (block.transactions.items) |tx| {
        hasher.update(tx.sender);
        hasher.update(tx.receiver);
        const amount_bytes = utils.toBytesU64(tx.amount);
        hasher.update(&amount_bytes);
    }

    // 追加のデータフィールドをハッシュに追加
    hasher.update(block.data);

    // ハッシュを確定して返す
    const hash = hasher.finalResult();
    logger.debugLog("nonce: {d}, hash: {x}\n", .{ block.nonce, hash });
    return hash;
}

/// ハッシュが必要なプルーフオブワークの難易度を満たしているかチェックする
///
/// ハッシュが難易度パラメータで指定された必要な先頭ゼロバイト数を
/// 持っているかを検証します。
///
/// 引数:
///     hash: チェックする32バイトのハッシュ
///     difficulty: 必要な先頭ゼロバイト数（32を上限とする）
///
/// 戻り値:
///     bool: ハッシュが難易度要件を満たす場合はtrue、そうでなければfalse
pub fn meetsDifficulty(hash: [32]u8, difficulty: u8) bool {
    // 難易度を32バイト（256ビット）に制限
    const limit = if (difficulty <= 32) difficulty else 32;

    // 最初の 'limit' バイトがすべてゼロであることを確認
    for (hash[0..limit]) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

/// 有効なプルーフオブワークを見つけてブロックをマイニングする
///
/// 指定された難易度要件（先頭のゼロバイト）を満たすハッシュを
/// 見つけるまでブロックのノンス値を段階的に調整します。
///
/// 引数:
///     block: マイニングするBlock構造体へのポインタ（その場で変更される）
///     difficulty: ハッシュに必要な先頭ゼロバイト数
///
/// 注意:
///     この関数はブロックのノンスとハッシュフィールドを更新することでブロックを変更します
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

/// ブロックのプルーフオブワークを検証する
///
/// ブロックの保存されたハッシュが再計算されたハッシュと一致し、
/// ハッシュが必要な難易度レベルを満たしていることを確認します。
///
/// 引数:
///     b: 検証するBlock構造体へのポインタ
///
/// 戻り値:
///     bool: ブロックが有効なプルーフオブワークを持つ場合はtrue、そうでなければfalse
pub fn verifyBlockPow(b: *const types.Block) bool {
    // ハッシュを再計算し、保存されたハッシュと一致するか確認
    const recalculated = calculateHash(b);
    if (!std.mem.eql(u8, recalculated[0..], b.hash[0..])) {
        return false; // ハッシュフィールドが再計算されたハッシュと一致しない
    }

    // ハッシュが必要な難易度を満たしているか確認
    if (!meetsDifficulty(recalculated, DIFFICULTY)) {
        return false; // ハッシュが難易度要件を満たしていない
    }

    return true;
}

/// 検証済みブロックをブロックチェーンに追加する
///
/// チェーンに追加する前にブロックのプルーフオブワークを検証します。
/// 検証に失敗したブロックは拒否されます。
///
/// 引数:
///     new_block: チェーンに追加するBlock構造体
///
/// 注意:
///     この関数は成功または失敗のメッセージをログに記録します
pub fn addBlock(new_block: types.Block) AddBlockResult {
    chain_store_mutex.lock();
    defer chain_store_mutex.unlock();

    if (!verifyBlockPow(&new_block)) {
        std.log.warn("BLOCK_REJECTED reason=invalid_pow index={d}", .{new_block.index});
        return .invalid_pow;
    }

    for (chain_store.items) |known_block| {
        if (std.mem.eql(u8, known_block.hash[0..], new_block.hash[0..])) {
            std.log.info("BLOCK_REJECTED reason=duplicate index={d} hash={x:0>2}", .{ new_block.index, new_block.hash });
            return .duplicate;
        }
    }

    var expected_index: u32 = undefined;
    var expected_prev_hash: [32]u8 = undefined;
    if (chain_store.items.len == 0) {
        var genesis = createTestGenesisBlock(std.heap.page_allocator) catch {
            std.log.warn("BLOCK_REJECTED reason=genesis_allocation index={d}", .{new_block.index});
            return .out_of_memory;
        };
        defer genesis.transactions.deinit();
        expected_index = genesis.index + 1;
        expected_prev_hash = genesis.hash;
    } else {
        const tip = chain_store.items[chain_store.items.len - 1];
        expected_index = tip.index + 1;
        expected_prev_hash = tip.hash;
    }

    if (new_block.index != expected_index or
        !std.mem.eql(u8, new_block.prev_hash[0..], expected_prev_hash[0..]))
    {
        std.log.warn("BLOCK_REJECTED reason=invalid_link index={d} expected_index={d}", .{ new_block.index, expected_index });
        return .invalid_link;
    }

    chain_store.append(new_block) catch {
        std.log.warn("BLOCK_REJECTED reason=out_of_memory index={d}", .{new_block.index});
        return .out_of_memory;
    };
    std.log.info("Added new block index={d}, nonce={d}, hash={x:0>2}", .{ new_block.index, new_block.nonce, new_block.hash });

    // chain_store_mutexを保持しているため、再ロックしない内部版を使う。
    printChainStateLocked();
    return .added;
}

/// 前のブロックにリンクされた新しいブロックを作成する
///
/// 新しいブロックをデフォルト値で初期化し、そのインデックスを
/// 前のブロックよりも1つ多く設定し、prev_hashを介してリンクします。
///
/// 引数:
///     input: 新しいブロックに格納するデータ文字列
///     prevBlock: リンクする前のブロック
///
/// 戻り値:
///     types.Block: 未確定の新しいブロック（まだマイニングが必要）
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

/// テスト用のジェネシスブロックを作成する
///
/// ブロックチェーンの最初のブロックを事前定義された値で初期化し、
/// マイニングして有効なジェネシスブロックを生成します。
///
/// 引数:
///     allocator: トランザクションリストに使用するメモリアロケータ
///
/// 戻り値:
///     types.Block: マイニングされたジェネシスブロック
///
/// エラー:
///     トランザクション追加に失敗した場合のアロケータエラー
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

/// より長いチェーンとブロックチェーンを同期する
///
/// 提供されたチェーンが現在のチェーンより長い場合にローカル配列を
/// 置き換える、第8章時点の補助関数です。P2P受信経路からは呼ばれず、
/// 候補全体の検証やフォーク選択を行うコンセンサス実装ではありません。
///
/// 引数:
///     blocks: ブロックチェーンを表すブロックの配列
///
/// エラー:
///     ブロック追加時にアロケーターエラーが発生する可能性あり
///
/// 注意:
///     実通信のGET_CHAINはBLOCKを順にaddBlockするprefix追随です
pub fn syncChain(blocks: []types.Block) !void {
    if (blocks.len == 0) return;

    chain_store_mutex.lock();
    defer chain_store_mutex.unlock();

    // 受信したチェーンが現在のチェーンより長い場合のみ同期
    if (blocks.len > chain_store.items.len) {
        // 現在のチェーンをクリア
        chain_store.clearRetainingCapacity();

        // 新しいチェーンからブロックをコピー
        for (blocks) |block| {
            try chain_store.append(block);
        }

        std.log.info("Chain synchronized with {d} blocks", .{blocks.len});
    } else {
        std.log.info("Received chain ({d} blocks) is not longer than current chain ({d} blocks)", .{ blocks.len, chain_store.items.len });
    }
}

/// 現在のブロックチェーンの高さ（ブロック数）を取得する
///
/// 戻り値:
///     usize: ブロックチェーン内のブロック数
pub fn getChainHeight() usize {
    chain_store_mutex.lock();
    defer chain_store_mutex.unlock();
    return chain_store.items.len;
}

/// インデックスでブロックを取得する
///
/// 引数:
///     index: 取得するブロックのインデックス
///
/// 戻り値:
///     ?types.Block: 要求されたブロック、見つからない場合はnull
pub fn getBlock(index: usize) ?types.Block {
    chain_store_mutex.lock();
    defer chain_store_mutex.unlock();
    if (index >= chain_store.items.len) return null;
    return chain_store.items[index];
}

/// 現在のtipを値コピーで取得する。第8章では空チェーンのときnullを返し、
/// 呼び出し側が決定的genesisを直前ブロックとして使う。
pub fn getChainTip() ?types.Block {
    chain_store_mutex.lock();
    defer chain_store_mutex.unlock();
    if (chain_store.items.len == 0) return null;
    return chain_store.items[chain_store.items.len - 1];
}

/// P2P送信中のArrayList再確保を避けるため、Block構造体を値コピーする。
/// accepted blockのネストしたデータは実行中immutableかつ解放されないため、
/// shallow snapshotの参照先は有効である。呼び出し側は返却配列だけを解放する。
pub fn copyChainSnapshot(allocator: std.mem.Allocator) ![]types.Block {
    chain_store_mutex.lock();
    defer chain_store_mutex.unlock();
    return allocator.dupe(types.Block, chain_store.items);
}

/// デバッグ用に現在のブロックチェーン状態を出力する
///
/// チェーンの高さと各ブロックの詳細情報を見やすい形式で表示します
pub fn printChainState() void {
    chain_store_mutex.lock();
    defer chain_store_mutex.unlock();
    printChainStateLocked();
}

fn printChainStateLocked() void {
    std.log.info("Current chain state:", .{});
    std.log.info("- Height: {d} blocks", .{chain_store.items.len});

    if (chain_store.items.len == 0) {
        std.log.info("- No blocks in chain", .{});
        return;
    }

    // 各ブロックを詳細に表示
    for (chain_store.items) |block| {
        const hash_str = std.fmt.bytesToHex(block.hash, .lower);
        // 区切り線を表示
        std.debug.print("\n{s}\n", .{"---------------------------"});
        // ブロック情報を見やすく表示
        std.debug.print("Block index: {d}\n", .{block.index});
        std.debug.print("Timestamp  : {d}\n", .{block.timestamp});
        std.debug.print("Nonce      : {d}\n", .{block.nonce});
        std.debug.print("Data       : {s}\n", .{block.data});

        // トランザクション情報を表示
        std.debug.print("Transactions:\n", .{});
        if (block.transactions.items.len == 0) {
            std.debug.print("  (no transactions)\n", .{});
        } else {
            for (block.transactions.items) |tx| {
                std.debug.print("  {s} -> {s} : {d}\n", .{ tx.sender, tx.receiver, tx.amount });
            }
        }

        // ハッシュを表示
        std.debug.print("Hash       : {s}\n", .{hash_str[0..64]});
    }
    std.debug.print("\n{s}\n", .{"---------------------------"});
}

// ヘルパー関数: 文字列を指定回数繰り返す
fn times(comptime char: []const u8, n: usize) []const u8 {
    const static = struct {
        var buffer: [100]u8 = undefined;
    };
    var i: usize = 0;
    while (i < n and i < static.buffer.len) : (i += 1) {
        static.buffer[i] = char[0];
    }
    return static.buffer[0..i];
}

fn clearChainStoreForTest() void {
    for (chain_store.items) |*block| {
        block.transactions.deinit();
    }
    chain_store.clearRetainingCapacity();
}

test "addBlock rejects tampering duplicates and broken links" {
    clearChainStoreForTest();
    defer clearChainStoreForTest();

    var genesis = try createTestGenesisBlock(std.heap.page_allocator);
    defer genesis.transactions.deinit();

    var first = createBlock("first", genesis);
    mineBlock(&first, DIFFICULTY);
    try std.testing.expectEqual(AddBlockResult.added, addBlock(first));
    try std.testing.expectEqual(@as(usize, 1), getChainHeight());

    try std.testing.expectEqual(AddBlockResult.duplicate, addBlock(first));
    try std.testing.expectEqual(@as(usize, 1), getChainHeight());

    var tampered = first;
    tampered.data = "tampered";
    try std.testing.expectEqual(AddBlockResult.invalid_pow, addBlock(tampered));
    try std.testing.expectEqual(@as(usize, 1), getChainHeight());

    var broken_link = createBlock("broken", first);
    defer broken_link.transactions.deinit();
    broken_link.prev_hash = [_]u8{0} ** 32;
    mineBlock(&broken_link, DIFFICULTY);
    try std.testing.expectEqual(AddBlockResult.invalid_link, addBlock(broken_link));
    try std.testing.expectEqual(@as(usize, 1), getChainHeight());

    var second = createBlock("second", first);
    mineBlock(&second, DIFFICULTY);
    try std.testing.expectEqual(AddBlockResult.added, addBlock(second));
    try std.testing.expectEqual(@as(usize, 2), getChainHeight());
}
