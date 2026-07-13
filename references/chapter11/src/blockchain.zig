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
const utils = @import("utils.zig");
const parser = @import("parser.zig");

/// プルーフオブワークマイニングの難易度設定
/// 有効なブロックハッシュに必要な先頭のゼロバイト数を表します
const DIFFICULTY: u8 = 2;

/// メインブロックチェーンデータストレージ
/// 完全なブロックチェーンをBlock構造体の動的配列として格納します
pub var chain_store = std.ArrayList(types.Block).init(std.heap.page_allocator);

/// EVMコントラクトストレージ - アドレスからコントラクトコードへのマッピング
pub var contract_storage = std.StringHashMap([]const u8).init(std.heap.page_allocator);

/// チェーン本体とコントラクト状態は必ず同じロックで読み書きする。
/// これにより、P2P受信・ローカル入力・同期処理が並行しても、両状態の
/// 組み合わせが途中の状態として観測されない。
var state_mutex: std.Thread.Mutex = .{};

/// コントラクト状態を反復する呼び出し元向けの読み取り専用snapshot。
pub const ContractSnapshotEntry = struct {
    address: []const u8,
    code: []const u8,
};

/// ブロック追加の判定結果。`.added` のときだけチェーンとEVM状態が更新される。
pub const AddBlockResult = enum {
    added,
    duplicate,
    invalid_pow,
    invalid_index,
    invalid_prev_hash,
    invalid_genesis,
    storage_error,
};

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

    // 可変長フィールドの単純連結による曖昧性を避けるため、
    // バージョンタグ、件数、長さ、nullマーカーを含む正規形をハッシュする。
    hasher.update("ZIG_BLOCK_V2");

    // ノンスをバイト配列に変換
    const nonce_bytes = utils.toBytesU64(block.nonce);

    // ハッシュ計算にブロックフィールドを順番に追加
    const index_bytes = utils.toBytesU32(block.index);
    const timestamp_bytes = utils.toBytesU64(block.timestamp);
    hasher.update(&index_bytes);
    hasher.update(&timestamp_bytes);
    hasher.update(nonce_bytes[0..]);
    hasher.update(&block.prev_hash);

    // すべてのトランザクションデータをハッシュに追加
    hashLength(&hasher, block.transactions.items.len);
    for (block.transactions.items) |tx| {
        hashTransactionFields(&hasher, &tx, true);
    }

    // 追加のデータフィールドをハッシュに追加
    hashBytes(&hasher, block.data);
    hashContracts(&hasher, block.contracts);

    // ハッシュを確定して返す
    return hasher.finalResult();
}

/// トランザクションのハッシュを計算する
///
/// トランザクションの送信者、受信者、金額、タイプ、EVMデータなどを含めて
/// SHA-256ハッシュを計算します。
///
/// 引数:
///     tx: ハッシュを計算するトランザクション
///
/// 戻り値:
///     [32]u8: トランザクションの32バイトのSHA-256ハッシュ
pub fn calculateTransactionHash(tx: *const types.Transaction) [32]u8 {
    var hasher = Sha256.init(.{});

    hasher.update("ZIG_TX_V2");
    // id はこのハッシュ自身から導出されるため対象外。それ以外は
    // block hash 内のトランザクション符号化と同じ規則を使う。
    hashTransactionFields(&hasher, tx, false);

    return hasher.finalResult();
}

fn hashTransactionFields(hasher: *Sha256, tx: *const types.Transaction, include_id: bool) void {
    hashBytes(hasher, tx.sender);
    hashBytes(hasher, tx.receiver);

    const amount_bytes = utils.toBytesU64(tx.amount);
    const gas_limit_bytes = utils.toBytesU64(@intCast(tx.gas_limit));
    const gas_price_bytes = utils.toBytesU64(tx.gas_price);
    hasher.update(&amount_bytes);
    hasher.update(&[_]u8{tx.tx_type});
    hasher.update(&gas_limit_bytes);
    hasher.update(&gas_price_bytes);
    if (include_id) hasher.update(&tx.id);

    if (tx.evm_data) |evm_data| {
        hasher.update(&[_]u8{1});
        hashBytes(hasher, evm_data);
    } else {
        hasher.update(&[_]u8{0});
    }
}

fn hashLength(hasher: *Sha256, len: usize) void {
    const len_bytes = utils.toBytesU64(@intCast(len));
    hasher.update(&len_bytes);
}

fn hashBytes(hasher: *Sha256, bytes: []const u8) void {
    hashLength(hasher, bytes.len);
    hasher.update(bytes);
}

/// HashMapの反復順は未規定なので、毎回「直前より大きい最小キー」を選び、
/// アドレスの辞書順でコントラクトを正規化する。学習実装では件数が少ないため、
/// 割り当てを伴わないO(n^2)走査を選ぶ。
fn hashContracts(hasher: *Sha256, maybe_contracts: ?std.StringHashMap([]const u8)) void {
    const contracts = maybe_contracts orelse {
        hasher.update(&[_]u8{0});
        return;
    };
    hasher.update(&[_]u8{1});
    hashLength(hasher, contracts.count());

    var previous_key: ?[]const u8 = null;
    var emitted: usize = 0;
    while (emitted < contracts.count()) : (emitted += 1) {
        var candidate: ?[]const u8 = null;
        var it = contracts.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (previous_key) |previous| {
                if (std.mem.order(u8, previous, key) != .lt) continue;
            }
            if (candidate == null or std.mem.order(u8, key, candidate.?) == .lt) {
                candidate = key;
            }
        }

        const key = candidate orelse unreachable;
        hashBytes(hasher, key);
        hashBytes(hasher, contracts.get(key).?);
        previous_key = key;
    }
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
        std.log.warn("Block hash mismatch: stored={s}, recalculated={s}", .{
            std.fmt.bytesToHex(b.hash, .lower),
            std.fmt.bytesToHex(recalculated, .lower),
        });
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
    state_mutex.lock();
    defer state_mutex.unlock();

    // 内容、PoW、チェーン上の位置をすべて検証し終えるまで、
    // contract_storage と chain_store には一切触れない。
    if (!verifyBlockPow(&new_block)) {
        std.log.warn("Received block fails hash/PoW check. Rejecting it.", .{});
        return .invalid_pow;
    }

    for (chain_store.items) |existing_block| {
        if (std.mem.eql(u8, &existing_block.hash, &new_block.hash)) {
            std.log.info("Block already exists; ignoring duplicate index={d}, hash={x}", .{ new_block.index, new_block.hash });
            return .duplicate;
        }
    }

    if (chain_store.items.len == 0) {
        if (new_block.index != 0) {
            std.log.warn("First block must have index 0, got {d}", .{new_block.index});
            return .invalid_index;
        }
        if (!isZeroHash(new_block.prev_hash)) {
            std.log.warn("Genesis block must have an all-zero prev_hash", .{});
            return .invalid_prev_hash;
        }
        if (!isDeterministicGenesis(&new_block)) {
            std.log.warn("First block does not match the deterministic genesis policy", .{});
            return .invalid_genesis;
        }
    } else {
        const tip = &chain_store.items[chain_store.items.len - 1];
        const expected_index = tip.index + 1;
        if (new_block.index != expected_index) {
            std.log.warn("Unexpected block index: expected={d}, got={d}", .{ expected_index, new_block.index });
            return .invalid_index;
        }
        if (!std.mem.eql(u8, &tip.hash, &new_block.prev_hash)) {
            std.log.warn("Block prev_hash does not match the current tip", .{});
            return .invalid_prev_hash;
        }
    }

    std.log.info("Adding block to chain: index={d}, hash={x}", .{ new_block.index, new_block.hash });

    // 追加領域を先に確保する。確保失敗時はEVM状態を変更しない。
    chain_store.ensureUnusedCapacity(1) catch |err| {
        std.log.err("Failed to reserve chain storage: {any}", .{err});
        return .storage_error;
    };

    // EVM状態は一時mapへ構築し、全処理が成功した場合だけ差し替える。
    // これにより.addedはchainとEVM状態の両方が更新されたことを表す。
    const next_contract_storage = cloneContractStorageWithBlock(&contract_storage, new_block) catch |err| {
        std.log.warn("Failed to prepare contract state: {any}", .{err});
        return .storage_error;
    };
    contract_storage.deinit();
    contract_storage = next_contract_storage;
    chain_store.appendAssumeCapacity(new_block);
    std.log.info("Added new block index={d}, nonce={d}, hash={x}", .{ new_block.index, new_block.nonce, new_block.hash });

    // state_mutexを保持したまま公開関数を呼ぶと自己deadlockするため、
    // ロック取得済みの内部関数を使う。
    printChainStateLocked();
    return .added;
}

fn cloneContractStorageWithBlock(
    current: *std.StringHashMap([]const u8),
    new_block: types.Block,
) !std.StringHashMap([]const u8) {
    var next = std.StringHashMap([]const u8).init(std.heap.page_allocator);
    errdefer next.deinit();

    var current_it = current.iterator();
    while (current_it.next()) |entry| {
        try next.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    try applyBlockState(&next, new_block);
    return next;
}

fn applyBlockState(
    storage: *std.StringHashMap([]const u8),
    new_block: types.Block,
) !void {

    // ブロックに含まれるコントラクトがあれば、コントラクトストレージに追加
    if (new_block.contracts) |contracts| {
        std.log.info("Block contains {d} contracts to process", .{contracts.count()});
        var it = contracts.iterator();
        var contract_count: usize = 0;
        while (it.next()) |entry| {
            const address = entry.key_ptr.*;
            const code = entry.value_ptr.*;
            contract_count += 1;

            // 既存コードの有無にかかわらず **必ず** 上書きする
            try storage.put(address, code);
            std.log.info("Updated contract {s} (stored {d} bytes)", .{ address, code.len });
        }
        std.log.info("Processed {d} contracts from received block", .{contract_count});
    }

    // トランザクションにコントラクトデプロイが含まれているか確認
    for (new_block.transactions.items) |tx| {
        if (tx.tx_type == 1) { // コントラクトデプロイトランザクション
            std.log.info("Found contract deploy transaction in block for address: {s}", .{tx.receiver});

            // コントラクトがまだ保存されていないかつ、evm_dataがある場合
            if (!storage.contains(tx.receiver) and tx.evm_data != null) {
                // ローカルで再実行して結果を保存
                const allocator = std.heap.page_allocator;
                const evm_data = tx.evm_data.?;
                const calldata = "";

                const result = try @import("evm.zig").execute(allocator, evm_data, calldata, tx.gas_limit);
                errdefer allocator.free(result);

                // 結果をコントラクトストレージに保存
                try storage.put(tx.receiver, result);
                std.log.info("Re-executed and stored contract at address: {s}, code length: {d} bytes", .{ tx.receiver, result.len });
            }
        }
    }
}

fn isZeroHash(hash: [32]u8) bool {
    return std.mem.eql(u8, &hash, &([_]u8{0} ** 32));
}

/// 全ノードが同じジェネシスを選ぶよう、内容だけでなく
/// nonce 0から最初に見つかるPoW解まで一致させる。
fn isDeterministicGenesis(block: *const types.Block) bool {
    if (block.timestamp != 1_672_531_200 or
        !std.mem.eql(u8, block.data, "Hello, Zig Blockchain!") or
        block.transactions.items.len != 1)
    {
        return false;
    }

    const tx = block.transactions.items[0];
    if (!std.mem.eql(u8, tx.sender, "Alice") or
        !std.mem.eql(u8, tx.receiver, "Bob") or
        tx.amount != 100 or
        tx.tx_type != 0 or
        tx.evm_data != null or
        tx.gas_limit != 1_000_000 or
        tx.gas_price != 20_000_000_000 or
        !isZeroHash(tx.id))
    {
        return false;
    }
    // null と空mapはhash上で別の値になるため、決定的genesisでは
    // contractsを必ずnullに固定する。
    if (block.contracts != null) return false;

    var expected = block.*;
    expected.nonce = 0;
    expected.hash = [_]u8{0} ** 32;
    mineBlock(&expected, DIFFICULTY);
    return expected.nonce == block.nonce and std.mem.eql(u8, &expected.hash, &block.hash);
}

test "同じハッシュのブロックは重複追加しない" {
    chain_store.clearRetainingCapacity();
    defer chain_store.clearRetainingCapacity();

    const block = try createTestGenesisBlock(std.heap.page_allocator);
    try std.testing.expectEqual(AddBlockResult.added, addBlock(block));
    try std.testing.expectEqual(AddBlockResult.duplicate, addBlock(block));

    try std.testing.expectEqual(@as(usize, 1), chain_store.items.len);
}

test "deterministic genesis rejects a non-null empty contracts map" {
    chain_store.clearRetainingCapacity();
    contract_storage.clearRetainingCapacity();
    defer chain_store.clearRetainingCapacity();
    defer contract_storage.clearRetainingCapacity();

    var block = try createTestGenesisBlock(std.testing.allocator);
    defer block.transactions.deinit();
    var empty_contracts = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer empty_contracts.deinit();
    block.contracts = empty_contracts;
    block.nonce = 0;
    block.hash = [_]u8{0} ** 32;
    mineBlock(&block, DIFFICULTY);

    try std.testing.expectEqual(AddBlockResult.invalid_genesis, addBlock(block));
    try std.testing.expectEqual(@as(usize, 0), chain_store.items.len);
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
/// 提供されたチェーンが現在のチェーンより長く、候補全体の検証を通る場合だけ
/// ローカル状態を原子的に置き換える補助関数です。P2P受信経路からは呼ばれず、
/// 累積workによるフォーク選択を行うコンセンサス実装ではありません。
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

    state_mutex.lock();
    defer state_mutex.unlock();

    // 第11章では第8章の単純な長さ比較を保つ。置換前の全チェーン検証と
    // EVM状態の再構築は第12章で追加する。
    if (blocks.len > chain_store.items.len) {
        try chain_store.ensureTotalCapacity(blocks.len);
        chain_store.clearRetainingCapacity();
        for (blocks) |block| {
            chain_store.appendAssumeCapacity(block);
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
    state_mutex.lock();
    defer state_mutex.unlock();
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
    state_mutex.lock();
    defer state_mutex.unlock();
    if (index >= chain_store.items.len) return null;
    return chain_store.items[index];
}

/// 現在のtipを値コピーで取得する。
pub fn getChainTip() ?types.Block {
    state_mutex.lock();
    defer state_mutex.unlock();
    if (chain_store.items.len == 0) return null;
    return chain_store.items[chain_store.items.len - 1];
}

/// 送信中にArrayListの再確保が起きても反復子が無効にならないよう、
/// Block構造体の配列だけを呼び出し元allocatorへコピーする。
///
/// snapshotはshallow copyである。`.added` になったBlockのネストした
/// transactions/data/contractsはチェーンへ所有権が移り、実行中はimmutableかつ
/// 解放されない、という本実装の所有権規約により参照先は有効なままになる。
/// 呼び出し元は返された配列だけを `allocator.free` する。
pub fn copyChainSnapshot(allocator: std.mem.Allocator) ![]types.Block {
    state_mutex.lock();
    defer state_mutex.unlock();
    return allocator.dupe(types.Block, chain_store.items);
}

/// コントラクトコードを読み取る。返すsliceはaccepted blockが所有し、
/// 実行中はimmutableかつ解放されない。
pub fn getContractCode(address: []const u8) ?[]const u8 {
    state_mutex.lock();
    defer state_mutex.unlock();
    return contract_storage.get(address);
}

/// P2P同期で既存ブロックから復元した、寿命の安定したコードを登録する。
pub fn putContractCode(address: []const u8, code: []const u8) !void {
    state_mutex.lock();
    defer state_mutex.unlock();
    try contract_storage.put(address, code);
}

pub fn getContractCount() usize {
    state_mutex.lock();
    defer state_mutex.unlock();
    return contract_storage.count();
}

/// ロック外で安全に反復できる、読み取り専用のshallow snapshotを返す。
/// 呼び出し元は返された配列だけを `allocator.free` する。
pub fn copyContractSnapshot(allocator: std.mem.Allocator) ![]ContractSnapshotEntry {
    state_mutex.lock();
    defer state_mutex.unlock();

    const snapshot = try allocator.alloc(ContractSnapshotEntry, contract_storage.count());
    var index: usize = 0;
    var it = contract_storage.iterator();
    while (it.next()) |entry| : (index += 1) {
        snapshot[index] = .{
            .address = entry.key_ptr.*,
            .code = entry.value_ptr.*,
        };
    }
    return snapshot;
}

/// デバッグ用に現在のブロックチェーン状態を出力する
///
/// チェーンの高さと各ブロックの詳細情報を見やすい形式で表示します
pub fn printChainState() void {
    state_mutex.lock();
    defer state_mutex.unlock();
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

/// EVMトランザクションを実行し、詳細なエラー情報を含めて処理する
///
/// 引数:
///     tx: 処理するトランザクション
///
/// 戻り値:
///     実行結果またはエラー
pub fn processEvmTransactionWithErrorDetails(tx: *types.Transaction) ![]const u8 {
    if (std.mem.eql(u8, &tx.id, &[_]u8{0} ** 32)) {
        tx.id = calculateTransactionHash(tx);
    }

    const evm_data = tx.evm_data orelse return error.NoEvmData;
    const allocator = std.heap.page_allocator;
    var result: []const u8 = "";
    var contract_deployed = false;

    switch (tx.tx_type) {
        1 => {
            std.log.info("スマートコントラクトをデプロイしています: 送信者={s}, ガス上限={d}", .{ tx.sender, tx.gas_limit });
            const evm_result = @import("evm.zig").executeWithErrorInfo(allocator, evm_data, "", tx.gas_limit);
            if (!evm_result.success) {
                logEvmExecutionFailure(evm_result);
                return error.EvmExecutionFailed;
            }

            result = evm_result.data;
            contract_deployed = true;
            std.log.info("コントラクトが正常にデプロイされました: アドレス={s}, コード長={d}バイト", .{ tx.receiver, result.len });
        },
        2 => {
            std.log.info("スマートコントラクトを呼び出しています: アドレス={s}, 送信者={s}, ガス上限={d}", .{ tx.receiver, tx.sender, tx.gas_limit });
            const contract_code = getContractCode(tx.receiver) orelse {
                std.log.err("コントラクトが見つかりません: アドレス={s}", .{tx.receiver});
                return error.ContractNotFound;
            };

            const evm_result = @import("evm.zig").executeWithErrorInfo(allocator, contract_code, evm_data, tx.gas_limit);
            if (!evm_result.success) {
                logEvmExecutionFailure(evm_result);
                return error.EvmExecutionFailed;
            }

            result = evm_result.data;
            std.log.info("コントラクト呼び出しが完了しました: 結果長={d}バイト", .{result.len});
        },
        else => return error.NotEvmTransaction,
    }

    if (contract_deployed) {
        try recordContractDeployment(tx, result, allocator);
    }
    return result;
}

fn logEvmExecutionFailure(result: @import("evm.zig").EvmExecutionResult) void {
    if (result.error_message) |message| {
        std.log.err("EVM_EXECUTION_FAILED message={s}", .{message});
    }
    if (result.error_type) |error_type| {
        std.log.err("EVM_EXECUTION_FAILED type={any} pc={d}", .{ error_type, result.error_pc orelse 0 });
    }
}

/// デプロイ結果を所有権の独立したブロックへ記録し、ピアへ伝播する。
fn recordContractDeployment(tx: *const types.Transaction, runtime_code: []const u8, allocator: std.mem.Allocator) !void {
    if (getChainHeight() == 0) {
        const genesis = try createTestGenesisBlock(allocator);
        switch (addBlock(genesis)) {
            .added => @import("p2p.zig").broadcastBlock(genesis, null),
            // 別threadが同じ決定的genesisを先に追加した場合は続行できる。
            .duplicate => {},
            else => return error.GenesisRejected,
        }
    }

    const last_block = getChainTip() orelse return error.MissingGenesis;
    var new_block = createBlock("Contract Deployment", last_block);

    // CLIの入力バッファはdeployContract終了時に解放されるため、
    // チェインが保持するトランザクションは文字列とバイト列を複製する。
    var stored_tx = tx.*;
    stored_tx.sender = try allocator.dupe(u8, tx.sender);
    stored_tx.receiver = try allocator.dupe(u8, tx.receiver);
    stored_tx.evm_data = if (tx.evm_data) |data|
        try allocator.dupe(u8, data)
    else
        null;
    try new_block.transactions.append(stored_tx);

    var contracts = std.StringHashMap([]const u8).init(allocator);
    const stored_address = try allocator.dupe(u8, tx.receiver);
    try contracts.put(stored_address, runtime_code);
    new_block.contracts = contracts;

    mineBlock(&new_block, DIFFICULTY);
    if (addBlock(new_block) != .added) return error.DeploymentBlockRejected;
    @import("p2p.zig").broadcastBlock(new_block, null);

    std.log.info("コントラクトデプロイブロックを作成しました: address={s}, transactions={d}, contracts={d}", .{
        tx.receiver,
        new_block.transactions.items.len,
        contracts.count(),
    });
}

test "block hash commits EVM transaction payload and gas fields" {
    var evm_data = [_]u8{ 0x01, 0x02, 0x03 };
    var block = types.Block{
        .index = 1,
        .timestamp = 1672531201,
        .prev_hash = [_]u8{0} ** 32,
        .transactions = std.ArrayList(types.Transaction).init(std.testing.allocator),
        .nonce = 0,
        .data = "EVM transaction",
        .hash = [_]u8{0} ** 32,
        .contracts = null,
    };
    defer block.transactions.deinit();

    try block.transactions.append(.{
        .sender = "0xsender",
        .receiver = "0xreceiver",
        .amount = 0,
        .tx_type = 2,
        .evm_data = evm_data[0..],
        .gas_limit = 100_000,
        .gas_price = 10,
    });

    const original = calculateHash(&block);
    evm_data[0] ^= 0xff;
    const payload_tampered = calculateHash(&block);
    try std.testing.expect(!std.mem.eql(u8, original[0..], payload_tampered[0..]));

    evm_data[0] ^= 0xff;
    block.transactions.items[0].gas_limit += 1;
    const gas_tampered = calculateHash(&block);
    try std.testing.expect(!std.mem.eql(u8, original[0..], gas_tampered[0..]));
}

test "serialized EVM block preserves every hashed transaction field" {
    const evm_data = [_]u8{ 0xaa, 0xbb, 0xcc };
    var block = types.Block{
        .index = 1,
        .timestamp = 1672531202,
        .prev_hash = [_]u8{0} ** 32,
        .transactions = std.ArrayList(types.Transaction).init(std.testing.allocator),
        .nonce = 0,
        .data = "EVM round trip",
        .hash = [_]u8{0} ** 32,
        .contracts = null,
    };
    defer block.transactions.deinit();
    try block.transactions.append(.{
        .sender = "0xsender",
        .receiver = "0xreceiver",
        .amount = 7,
        .tx_type = 2,
        .evm_data = &evm_data,
        .gas_limit = 123_456,
        .gas_price = 99,
        .id = [_]u8{0x42} ** 32,
    });
    mineBlock(&block, DIFFICULTY);

    const json = try parser.serializeBlock(block);
    defer std.heap.page_allocator.free(json);
    var decoded = try parser.parseBlockJson(json);
    defer parser.deinitParsedBlock(&decoded);

    try std.testing.expect(verifyBlockPow(&decoded));
    try std.testing.expectEqualSlices(u8, &block.transactions.items[0].id, &decoded.transactions.items[0].id);
    try std.testing.expectEqualSlices(u8, block.transactions.items[0].evm_data.?, decoded.transactions.items[0].evm_data.?);
    try std.testing.expectEqual(block.transactions.items[0].gas_limit, decoded.transactions.items[0].gas_limit);
    try std.testing.expectEqual(block.transactions.items[0].gas_price, decoded.transactions.items[0].gas_price);
}

test "serialized block preserves a non-null empty contracts map" {
    var block = types.Block{
        .index = 1,
        .timestamp = 1_672_531_203,
        .prev_hash = [_]u8{0x11} ** 32,
        .transactions = std.ArrayList(types.Transaction).init(std.testing.allocator),
        .nonce = 0,
        .data = "empty contracts round trip",
        .hash = [_]u8{0} ** 32,
        .contracts = std.StringHashMap([]const u8).init(std.testing.allocator),
    };
    defer block.transactions.deinit();
    defer block.contracts.?.deinit();
    mineBlock(&block, DIFFICULTY);

    const json = try parser.serializeBlock(block);
    defer std.heap.page_allocator.free(json);
    var decoded = try parser.parseBlockJson(json);
    defer parser.deinitParsedBlock(&decoded);

    try std.testing.expect(decoded.contracts != null);
    try std.testing.expectEqual(@as(usize, 0), decoded.contracts.?.count());
    try std.testing.expect(verifyBlockPow(&decoded));
}

test "addBlock rejects wrong index and link before contract side effects" {
    chain_store.clearRetainingCapacity();
    contract_storage.clearRetainingCapacity();
    defer chain_store.clearRetainingCapacity();
    defer contract_storage.clearRetainingCapacity();

    const genesis = try createTestGenesisBlock(std.heap.page_allocator);
    try std.testing.expectEqual(AddBlockResult.added, addBlock(genesis));

    var malicious_contracts = std.StringHashMap([]const u8).init(std.heap.page_allocator);
    defer malicious_contracts.deinit();
    try malicious_contracts.put("0xevil", "must-not-be-stored");

    var wrong_index = createBlock("wrong index", genesis);
    defer wrong_index.transactions.deinit();
    wrong_index.index += 1;
    wrong_index.contracts = malicious_contracts;
    mineBlock(&wrong_index, DIFFICULTY);
    try std.testing.expectEqual(AddBlockResult.invalid_index, addBlock(wrong_index));
    try std.testing.expect(!contract_storage.contains("0xevil"));

    var wrong_link = createBlock("wrong link", genesis);
    defer wrong_link.transactions.deinit();
    wrong_link.prev_hash = [_]u8{0} ** 32;
    wrong_link.contracts = malicious_contracts;
    mineBlock(&wrong_link, DIFFICULTY);
    try std.testing.expectEqual(AddBlockResult.invalid_prev_hash, addBlock(wrong_link));
    try std.testing.expect(!contract_storage.contains("0xevil"));
    try std.testing.expectEqual(@as(usize, 1), chain_store.items.len);
}

test "addBlock leaves chain and contract state unchanged when EVM state application fails" {
    chain_store.clearRetainingCapacity();
    contract_storage.clearRetainingCapacity();
    defer chain_store.clearRetainingCapacity();
    defer contract_storage.clearRetainingCapacity();

    const genesis = try createTestGenesisBlock(std.heap.page_allocator);
    try std.testing.expectEqual(AddBlockResult.added, addBlock(genesis));

    var invalid_deploy = createBlock("invalid deployment", genesis);
    defer invalid_deploy.transactions.deinit();
    try invalid_deploy.transactions.append(.{
        .sender = "0xsender",
        .receiver = "0xinvalid",
        .amount = 0,
        .tx_type = 1,
        // PUSH1 0, PUSH1 0, REVERT: 型付き失敗だがテストrunnerの
        // error-log検出を発火させない。
        .evm_data = &[_]u8{ 0x60, 0x00, 0x60, 0x00, 0xfd },
        .gas_limit = 100_000,
        .gas_price = 10,
    });
    mineBlock(&invalid_deploy, DIFFICULTY);

    try std.testing.expectEqual(AddBlockResult.storage_error, addBlock(invalid_deploy));
    try std.testing.expectEqual(@as(usize, 1), chain_store.items.len);
    try std.testing.expect(!contract_storage.contains("0xinvalid"));
}

test "recordContractDeployment stores an owned transaction and runtime block" {
    chain_store.clearRetainingCapacity();
    contract_storage.clearRetainingCapacity();
    defer chain_store.clearRetainingCapacity();
    defer contract_storage.clearRetainingCapacity();

    const allocator = std.testing.allocator;
    const sender = try allocator.dupe(u8, "0xsender");
    defer allocator.free(sender);
    const receiver = try allocator.dupe(u8, "0xchapter11");
    defer allocator.free(receiver);

    // creation codeは末尾のSTOP 1バイトをruntime codeとして返す。
    const creation_template = [_]u8{
        0x60, 0x01, // PUSH1 runtime length
        0x60, 0x0c, // PUSH1 runtime offset
        0x60, 0x00, // PUSH1 memory offset
        0x39, // CODECOPY
        0x60, 0x01, // PUSH1 return length
        0x60, 0x00, // PUSH1 return offset
        0xf3, // RETURN
        0x00, // runtime: STOP
    };
    const creation = try allocator.dupe(u8, &creation_template);
    defer allocator.free(creation);

    var tx = types.Transaction{
        .sender = sender,
        .receiver = receiver,
        .amount = 0,
        .tx_type = 1,
        .evm_data = creation,
        .gas_limit = 100_000,
        .gas_price = 10,
    };
    const runtime = try processEvmTransactionWithErrorDetails(&tx);
    defer std.heap.page_allocator.free(runtime);

    try std.testing.expectEqualSlices(u8, &[_]u8{0x00}, runtime);
    try std.testing.expectEqual(@as(usize, 2), chain_store.items.len);
    const deployment = chain_store.items[1];
    try std.testing.expectEqual(@as(usize, 1), deployment.transactions.items.len);
    try std.testing.expectEqualStrings("0xsender", deployment.transactions.items[0].sender);
    try std.testing.expectEqualStrings("0xchapter11", deployment.transactions.items[0].receiver);
    try std.testing.expectEqualSlices(u8, &creation_template, deployment.transactions.items[0].evm_data.?);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x00}, contract_storage.get("0xchapter11").?);

    // 呼び出し側の一時バッファを変更しても、chain内の所有データは変わらない。
    sender[0] = 'X';
    receiver[0] = 'Y';
    creation[0] = 0xff;
    try std.testing.expectEqualStrings("0xsender", deployment.transactions.items[0].sender);
    try std.testing.expectEqualStrings("0xchapter11", deployment.transactions.items[0].receiver);
    try std.testing.expectEqual(@as(u8, 0x60), deployment.transactions.items[0].evm_data.?[0]);
}

test "EVM payload and deployed runtime tampering invalidate block PoW" {
    var evm_data = [_]u8{ 0x60, 0x01, 0x60, 0x02 };
    var runtime_code = [_]u8{ 0x60, 0x03, 0x60, 0x04 };
    var block = types.Block{
        .index = 1,
        .timestamp = 1_672_531_201,
        .prev_hash = [_]u8{0x22} ** 32,
        .transactions = std.ArrayList(types.Transaction).init(std.testing.allocator),
        .nonce = 0,
        .data = "Contract Deployment",
        .hash = [_]u8{0} ** 32,
        .contracts = std.StringHashMap([]const u8).init(std.testing.allocator),
    };
    defer block.transactions.deinit();
    defer block.contracts.?.deinit();
    try block.transactions.append(.{
        .sender = "0xsender",
        .receiver = "0xcontract",
        .amount = 0,
        .tx_type = 1,
        .evm_data = &evm_data,
        .gas_limit = 3_000_000,
        .gas_price = 10,
    });
    try block.contracts.?.put("0xcontract", &runtime_code);
    mineBlock(&block, DIFFICULTY);
    try std.testing.expect(verifyBlockPow(&block));

    evm_data[0] ^= 0xff;
    try std.testing.expect(!verifyBlockPow(&block));
    evm_data[0] ^= 0xff;
    try std.testing.expect(verifyBlockPow(&block));

    runtime_code[0] ^= 0xff;
    try std.testing.expect(!verifyBlockPow(&block));
}

test "transaction hashing separates variable-length fields and null EVM data" {
    const left = types.Transaction{ .sender = "ab", .receiver = "c", .amount = 1 };
    const right = types.Transaction{ .sender = "a", .receiver = "bc", .amount = 1 };
    const empty_data = [_]u8{};
    const empty = types.Transaction{ .sender = "ab", .receiver = "c", .amount = 1, .evm_data = &empty_data };

    const left_hash = calculateTransactionHash(&left);
    const right_hash = calculateTransactionHash(&right);
    const empty_hash = calculateTransactionHash(&empty);
    try std.testing.expect(!std.mem.eql(u8, &left_hash, &right_hash));
    try std.testing.expect(!std.mem.eql(u8, &left_hash, &empty_hash));
}
