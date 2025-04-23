const std = @import("std");
const crypto = std.crypto.hash;
const Sha256 = crypto.sha2.Sha256;
const types = @import("types.zig");
const logger = @import("logger.zig");
const utils = @import("utils.zig");
const chainError = @import("errors.zig").ChainError;
const parser = @import("parser.zig");
const DIFFICULTY: u8 = 2;

/// ブロックチェーンのメインデータストア
pub var chain_store = std.ArrayList(types.Block).init(std.heap.page_allocator);

//------------------------------------------------------------------------------
// ハッシュ計算とマイニング処理
//------------------------------------------------------------------------------
//
// calculateHash 関数では、ブロック内の各フィールドを連結して
// SHA-256 のハッシュを計算します。
// mineBlock 関数は、nonce をインクリメントしながら
// meetsDifficulty による難易度チェックをパスするハッシュを探します。

/// computeBlockHash:
/// ブロックの各フィールドをバイト列に変換し、SHA-256ハッシュを計算します。
/// 返値: ブロックのSHA-256ハッシュ値
pub fn computeBlockHash(block: *const types.Block) [32]u8 {
    var hasher = Sha256.init(.{});

    // ブロックのフィールドをハッシュ計算に追加
    const nonce_bytes = utils.toBytesU64(block.nonce);
    logger.debugLog("nonce bytes: ", .{});
    if (comptime logger.debug_logging) {
        for (nonce_bytes) |byte| {
            std.debug.print("{x:0>2},", .{byte});
        }
        std.debug.print("\n", .{});
    }

    // ブロックの基本情報をハッシュに追加
    hasher.update(utils.toBytes(u32, block.index));
    hasher.update(utils.toBytes(u64, block.timestamp));
    hasher.update(nonce_bytes[0..]);
    hasher.update(&block.prev_hash);

    // トランザクション情報をハッシュに追加
    for (block.transactions.items) |tx| {
        hasher.update(tx.sender);
        hasher.update(tx.receiver);
        const amount_bytes = utils.toBytesU64(tx.amount);
        hasher.update(&amount_bytes);
    }
    
    // 追加データをハッシュに追加
    hasher.update(block.data);

    // 最終的なハッシュ値を計算して返す
    const hash = hasher.finalResult();
    logger.debugLog("nonce: {d}, hash: {x}\n", .{ block.nonce, hash });
    return hash;
}

//------------------------------------------------------------------------------
// マイニング処理
//------------------------------------------------------------------------------
/// validateHashDifficulty:
/// ハッシュ値が指定された難易度を満たしているかを検証します。
/// 難易度は先頭バイトの0の数で表されます。
/// 引数:
///   - hash: 検証するハッシュ値
///   - difficulty: 要求される難易度（0のバイト数）
/// 返値: 難易度条件を満たす場合はtrue、そうでない場合はfalse
pub fn validateHashDifficulty(hash: [32]u8, difficulty: u8) bool {
    // 難易度が32を超える場合は32に制限
    const limit = if (difficulty <= 32) difficulty else 32;
    
    // 先頭のlimitバイトが全て0かどうかを確認
    for (hash[0..limit]) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

//------------------------------------------------------------------------------
// マイニング処理
//------------------------------------------------------------------------------
/// mineBlockWithDifficulty:
/// 指定された難易度を満たすハッシュ値が見つかるまでブロックのnonceを調整します。
/// 引数:
///   - block: マイニングするブロック
///   - difficulty: 要求される難易度
pub fn mineBlockWithDifficulty(block: *types.Block, difficulty: u8) void {
    while (true) {
        const new_hash = computeBlockHash(block);
        if (validateHashDifficulty(new_hash, difficulty)) {
            block.hash = new_hash;
            break;
        }
        block.nonce += 1;
    }
}

/// verifyBlockProofOfWork:
/// ブロックのProof of Work（作業証明）が有効かどうかを検証します。
/// ハッシュの再計算と難易度の検証を行います。
/// 引数:
///   - b: 検証するブロック
/// 返値: 検証に成功した場合はtrue、失敗した場合はfalse
pub fn verifyBlockProofOfWork(b: *const types.Block) bool {
    const recalculated = computeBlockHash(b);
    if (!std.mem.eql(u8, recalculated[0..], b.hash[0..])) {
        return false; // 保存されているハッシュと再計算されたハッシュが一致しない
    }
    return validateHashDifficulty(recalculated, DIFFICULTY);
}

/// addValidatedBlock: 
/// PoW検証に合格したブロックをチェーンに追加します。
/// 引数:
///   - new_block: 追加するブロック
pub fn addValidatedBlock(new_block: types.Block) void {
    if (!verifyBlockProofOfWork(&new_block)) {
        std.log.err("Received block fails PoW verification. Rejecting.", .{});
        return;
    }
    chain_store.append(new_block) catch {};
    std.log.info("Added new block index={d}, nonce={d}, hash={x}", .{ new_block.index, new_block.nonce, new_block.hash });
}

/// createNewBlock: 
/// 前ブロックを基に新しいブロックを生成します。
/// 引数:
///   - input: ブロックに含めるデータ
///   - prevBlock: 前ブロック
/// 返値: 生成された新しいブロック
pub fn createNewBlock(input: []const u8, prevBlock: types.Block) types.Block {
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

/// ブロックチェーンの同期処理
/// 別のノードから複数ブロックを受け取った場合の同期処理
pub fn syncChain(blocks: []types.Block) !void {
    if (blocks.len == 0) return;

    // 受信したチェーンが自身より長い場合のみ同期
    if (blocks.len > chain_store.items.len) {
        // 自身のチェーンをクリア
        chain_store.clearRetainingCapacity();

        // 新しいチェーンをコピー
        for (blocks) |block| {
            try chain_store.append(block);
        }

        std.log.info("Chain synchronized with {d} blocks", .{blocks.len});
    } else {
        std.log.info("Received chain ({d} blocks) is not longer than current chain ({d} blocks)", .{ blocks.len, chain_store.items.len });
    }
}

/// 現在のチェーン高さを取得
pub fn getChainHeight() usize {
    return chain_store.items.len;
}

/// 指定インデックスのブロックを取得
pub fn getBlock(index: usize) ?types.Block {
    if (index >= chain_store.items.len) return null;
    return chain_store.items[index];
}

/// チェーンの現在の状態を表示（デバッグ用）
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

//------------------------------------------------------------------------------
// テスト関数
//------------------------------------------------------------------------------

test "calculateHash produces consistent result" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // テスト用のブロックを作成
    var block = types.Block{
        .index = 1,
        .timestamp = 1672531200,
        .prev_hash = [_]u8{0} ** 32,
        .transactions = std.ArrayList(types.Transaction).init(allocator),
        .nonce = 12345,
        .data = "Test Block",
        .hash = [_]u8{0} ** 32,
    };
    defer block.transactions.deinit();

    try block.transactions.append(types.Transaction{ .sender = "TestSender", .receiver = "TestReceiver", .amount = 50 });

    // 同じ入力で複数回ハッシュ計算を実行
    const hash1 = calculateHash(&block);
    const hash2 = calculateHash(&block);

    // 同じ入力からは同じハッシュが生成されることを確認
    try testing.expectEqual(hash1, hash2);
}

test "meetsDifficulty with various difficulties" {
    const testing = std.testing;

    // 先頭4バイトが0、5バイト目が0以外のハッシュを作成
    var hash1 = [_]u8{0} ** 32;
    hash1[4] = 1;

    // 難易度のチェック
    try testing.expect(meetsDifficulty(hash1, 0)); // 難易度0は常にtrue
    try testing.expect(meetsDifficulty(hash1, 1)); // 先頭1バイトが0
    try testing.expect(meetsDifficulty(hash1, 4)); // 先頭4バイトが0
    try testing.expect(!meetsDifficulty(hash1, 5)); // 先頭5バイトは全て0ではない

    // 全て0のハッシュでは最大難易度でもtrue
    const hash2 = [_]u8{0} ** 32;
    try testing.expect(meetsDifficulty(hash2, 32));

    // 33以上の難易度は32に丸められる
    try testing.expect(meetsDifficulty(hash2, 33));
}

test "mineBlock satisfies difficulty" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // テスト用のブロックを作成
    var block = types.Block{
        .index = 2,
        .timestamp = 1672531200,
        .prev_hash = [_]u8{0} ** 32,
        .transactions = std.ArrayList(types.Transaction).init(allocator),
        .nonce = 0,
        .data = "Mining Test",
        .hash = [_]u8{0} ** 32,
    };
    defer block.transactions.deinit();

    // 難易度を設定してマイニング
    const test_difficulty: u8 = 1; // テスト用に低い難易度を設定
    mineBlock(&block, test_difficulty);

    // マイニング後のハッシュが難易度を満たすことを確認
    try testing.expect(meetsDifficulty(block.hash, test_difficulty));
    // nonceが更新されていることを確認
    try testing.expect(block.nonce > 0);
}

test "verifyBlockPow validates correct blocks" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // 正当なブロックを作成
    var valid_block = types.Block{
        .index = 3,
        .timestamp = 1672531200,
        .prev_hash = [_]u8{0} ** 32,
        .transactions = std.ArrayList(types.Transaction).init(allocator),
        .nonce = 0,
        .data = "Valid Block",
        .hash = [_]u8{0} ** 32,
    };
    defer valid_block.transactions.deinit();

    // ブロックをマイニング
    mineBlock(&valid_block, DIFFICULTY);

    // 検証が成功することを確認
    try testing.expect(verifyBlockPow(&valid_block));

    // 不正なブロックを作成（ハッシュを改ざん）
    var invalid_block = valid_block;
    invalid_block.hash[0] = 0xFF; // ハッシュを変更

    // 検証が失敗することを確認
    try testing.expect(!verifyBlockPow(&invalid_block));
}

test "getChainHeight returns correct height" {
    const testing = std.testing;
    const allocator = std.heap.page_allocator;

    // 元々のチェーンを保持
    const original_chain = chain_store;

    // テスト用の新しいチェーンを作成
    chain_store = std.ArrayList(types.Block).init(allocator);
    defer chain_store.deinit();

    // 高さが0であることを確認
    try testing.expectEqual(@as(usize, 0), getChainHeight());

    // ブロックを追加
    const genesis = try createTestGenesisBlock(allocator);
    try chain_store.append(genesis);

    // 高さが1になることを確認
    try testing.expectEqual(@as(usize, 1), getChainHeight());

    // 元のチェーンを復元（テスト後の状態をクリーンに保つ）
    chain_store = original_chain;
}

test "getBlock returns correct block" {
    const testing = std.testing;
    const allocator = std.heap.page_allocator;

    // 元々のチェーンを保持
    const original_chain = chain_store;

    // テスト用の新しいチェーンを作成
    chain_store = std.ArrayList(types.Block).init(allocator);
    defer chain_store.deinit();

    // 存在しないブロックの取得は null を返す
    try testing.expectEqual(@as(?types.Block, null), getBlock(0));

    // ブロックを追加
    const genesis = try createTestGenesisBlock(allocator);
    try chain_store.append(genesis);

    // ブロックが正しく取得できることを確認
    const block = getBlock(0);
    try testing.expect(block != null);
    try testing.expectEqual(genesis.index, block.?.index);
    try testing.expectEqualSlices(u8, genesis.hash[0..], block.?.hash[0..]);

    // 元のチェーンを復元（テスト後の状態をクリーンに保つ）
    chain_store = original_chain;
}

test "syncChain synchronizes with longer chain" {
    const testing = std.testing;
    const allocator = std.heap.page_allocator;

    // 元々のチェーンを保持
    const original_chain = chain_store;

    // テスト用の新しいチェーンを作成
    chain_store = std.ArrayList(types.Block).init(allocator);
    defer chain_store.deinit();

    // テスト用の新しいチェーンを作成
    var test_blocks = std.ArrayList(types.Block).init(allocator);
    defer test_blocks.deinit();

    // より長いチェーンを作成
    const genesis = try createTestGenesisBlock(allocator);
    try test_blocks.append(genesis);

    var prev_block = genesis;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var new_block = createBlock("Test Block", prev_block);
        mineBlock(&new_block, DIFFICULTY);
        try test_blocks.append(new_block);
        prev_block = new_block;
    }

    // 同期を実行
    try syncChain(test_blocks.items);

    // チェーンが正しく同期されたことを確認
    try testing.expectEqual(test_blocks.items.len, chain_store.items.len);

    // 元のチェーンを復元（テスト後の状態をクリーンに保つ）
    chain_store = original_chain;
}

// createBlock関数のテスト
test "createBlock creates a valid next block" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // テスト用の前ブロックを作成
    var prev_block = types.Block{
        .index = 5,
        .timestamp = 1672531200,
        .prev_hash = [_]u8{1} ** 32,
        .transactions = std.ArrayList(types.Transaction).init(allocator),
        .nonce = 12345,
        .data = "Previous Block",
        .hash = [_]u8{2} ** 32,
    };
    defer prev_block.transactions.deinit();

    // 新しいブロックを作成
    const data = "New Block Data";
    const new_block = createBlock(data, prev_block);
    defer new_block.transactions.deinit();

    // 新しいブロックが正しく作成されていることを確認
    try testing.expectEqual(prev_block.index + 1, new_block.index);
    try testing.expectEqualSlices(u8, prev_block.hash[0..], new_block.prev_hash[0..]);
    try testing.expectEqualSlices(u8, data, new_block.data);
    try testing.expectEqual(@as(u64, 0), new_block.nonce);
}
