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
    hasher.update(utils.toBytes(u32, block.index));
    hasher.update(utils.toBytes(u64, block.timestamp));
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
pub fn addBlock(new_block: types.Block) void {
    if (!verifyBlockPow(&new_block)) {
        std.log.err("Received block fails PoW check. Rejecting it.", .{});
        return;
    }
    chain_store.append(new_block) catch {};
    std.log.info("Added new block index={d}, nonce={d}, hash={x}", .{ new_block.index, new_block.nonce, new_block.hash });
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
/// 提供されたチェーンが現在のチェーンより長い場合、ローカルのブロックチェーンを
/// 置き換えます。これは「最長チェーン」コンセンサスルールを実装しています。
///
/// 引数:
///     blocks: ブロックチェーンを表すブロックの配列
///
/// エラー:
///     ブロック追加時にアロケーターエラーが発生する可能性あり
///
/// 注意:
///     これはブロックチェーンのコンセンサスとP2P同期の重要な部分です
pub fn syncChain(blocks: []types.Block) !void {
    if (blocks.len == 0) return;

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
    if (index >= chain_store.items.len) return null;
    return chain_store.items[index];
}

/// デバッグ用に現在のブロックチェーン状態を出力する
///
/// チェーンの高さと最新ブロックに関する情報をログに記録します
pub fn printChainState() void {
    std.log.info("Current chain state:", .{});
    std.log.info("- Height: {d} blocks", .{chain_store.items.len});

    if (chain_store.items.len > 0) {
        const latest = chain_store.items[chain_store.items.len - 1];
        std.log.info("- Latest block: index={d}, hash={x}", .{ latest.index, latest.hash });
    } else {
        std.log.info("- No blocks in chain", .{});
    }
}
