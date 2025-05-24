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
const evm_debug = @import("evm_debug.zig");

/// プルーフオブワークマイニングの難易度設定
/// 有効なブロックハッシュに必要な先頭のゼロバイト数を表します
const DIFFICULTY: u8 = 2;

/// メインブロックチェーンデータストレージ
/// 完全なブロックチェーンをBlock構造体の動的配列として格納します
pub var chain_store = std.ArrayList(types.Block).init(std.heap.page_allocator);

/// EVMコントラクトストレージ - アドレスからコントラクトコードへのマッピング
pub var contract_storage = std.StringHashMap([]const u8).init(std.heap.page_allocator);

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

    hasher.update(tx.sender);
    hasher.update(tx.receiver);

    const amount_bytes = utils.toBytesU64(tx.amount);
    hasher.update(&amount_bytes);

    hasher.update(&[_]u8{tx.tx_type});

    const gas_limit_bytes = utils.toBytes(usize, tx.gas_limit);
    const gas_price_bytes = utils.toBytesU64(tx.gas_price);
    hasher.update(gas_limit_bytes[0..]);
    hasher.update(gas_price_bytes[0..]);

    if (tx.evm_data) |data| {
        hasher.update(data);
    }

    return hasher.finalResult();
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

    std.log.info("Adding block to chain: index={d}, hash={x}", .{ new_block.index, new_block.hash });

    // ブロックに含まれるコントラクトがあれば、コントラクトストレージに追加
    if (new_block.contracts) |contracts| {
        std.log.info("Block contains {d} contracts to process", .{contracts.count()});
        var it = contracts.iterator();
        var contract_count: usize = 0;
        while (it.next()) |entry| {
            const address = entry.key_ptr.*;
            const code = entry.value_ptr.*;
            contract_count += 1;

            // 既存のコントラクトを上書きしないように注意
            if (!contract_storage.contains(address)) {
                contract_storage.put(address, code) catch |err| {
                    std.log.err("Failed to store contract at address: {s}, error: {any}", .{ address, err });
                    continue;
                };
                std.log.info("Loaded contract at address: {s} from synchronized block, code length: {d} bytes", .{ address, code.len });
            }
        }
        std.log.info("Processed {d} contracts from received block", .{contract_count});
    }

    // トランザクションにコントラクトデプロイが含まれているか確認
    for (new_block.transactions.items) |tx| {
        if (tx.tx_type == 1) { // コントラクトデプロイトランザクション
            std.log.info("Found contract deploy transaction in block for address: {s}", .{tx.receiver});

            // コントラクトがまだ保存されていないかつ、evm_dataがある場合
            if (!contract_storage.contains(tx.receiver) and tx.evm_data != null) {
                // ローカルで再実行して結果を保存
                const allocator = std.heap.page_allocator;
                const evm_data = tx.evm_data.?;
                const calldata = "";

                const result = @import("evm.zig").execute(allocator, evm_data, calldata, tx.gas_limit) catch |err| {
                    std.log.err("Failed to re-execute contract deployment: {any}", .{err});
                    continue;
                };

                // 結果をコントラクトストレージに保存
                contract_storage.put(tx.receiver, result) catch |err| {
                    std.log.err("Failed to store contract result: {any}", .{err});
                };
                std.log.info("Re-executed and stored contract at address: {s}, code length: {d} bytes", .{ tx.receiver, result.len });
            }
        }
    }

    chain_store.append(new_block) catch {};
    std.log.info("Added new block index={d}, nonce={d}, hash={x}", .{ new_block.index, new_block.nonce, new_block.hash });

    // 新しいブロックを追加した後にチェーン全体を表示
    printChainState();
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
        std.log.info("Synchronizing chain with {d} blocks (current chain has {d} blocks)", .{ blocks.len, chain_store.items.len });

        // コントラクトストレージの状態をログに出力（同期前）
        var contract_count_before: usize = 0;
        var it_before = contract_storage.iterator();
        while (it_before.next()) |_| {
            contract_count_before += 1;
        }
        std.log.info("Contract storage before sync: {d} contracts", .{contract_count_before});

        // 現在のチェーンをクリア
        chain_store.clearRetainingCapacity();

        // 新しいチェーンからブロックをコピーし、各ブロックのコントラクトを処理
        for (blocks) |block| {
            // ブロックをチェーンに追加
            try chain_store.append(block);
            std.log.info("Added block {d} to chain during sync", .{block.index});

            // ブロックに含まれるコントラクトを処理（addBlockと同様の処理）
            if (block.contracts) |contracts| {
                std.log.info("Block {d} contains {d} contracts map entries", .{ block.index, contracts.count() });
                var it = contracts.iterator();
                var contract_count: usize = 0;

                // 全てのアドレスをログに出力（同期前）
                var addresses = std.ArrayList([]const u8).init(std.heap.page_allocator);
                defer addresses.deinit();

                while (it.next()) |entry| {
                    const address = entry.key_ptr.*;
                    try addresses.append(address);
                }

                const addresses_str = utils.joinStrings(std.heap.page_allocator, addresses.items, ", ") catch "";
                defer std.heap.page_allocator.free(addresses_str);
                std.log.info("Block {d} contains contracts at addresses: {s}", .{ block.index, addresses_str });

                // 改めてイテレータを初期化して処理
                it = contracts.iterator();
                while (it.next()) |entry| {
                    const address = entry.key_ptr.*;
                    const code = entry.value_ptr.*;
                    contract_count += 1;

                    // すべてのコントラクトを強制的に更新 - 同期中は常に上書き
                    contract_storage.put(address, code) catch |err| {
                        std.log.err("Failed to store contract at address: {s}, error: {any}", .{ address, err });
                        continue;
                    };
                    std.log.info("Loaded contract at address: {s} from synchronized block, code length: {d} bytes", .{ address, code.len });
                }
                std.log.info("Processed {d} contracts from block {d}", .{ contract_count, block.index });
            }

            // トランザクションにコントラクトデプロイが含まれているか確認
            for (block.transactions.items) |tx| {
                if (tx.tx_type == 1) { // コントラクトデプロイトランザクション
                    std.log.info("Found contract deploy transaction in block {d} for address: {s}", .{ block.index, tx.receiver });

                    // コントラクトがまだ保存されていないかつ、evm_dataがある場合
                    if (!contract_storage.contains(tx.receiver) and tx.evm_data != null) {
                        // ローカルで再実行して結果を保存
                        const allocator = std.heap.page_allocator;
                        const evm_data = tx.evm_data.?;
                        const calldata = "";

                        const result = @import("evm.zig").execute(allocator, evm_data, calldata, tx.gas_limit) catch |err| {
                            std.log.err("Failed to re-execute contract deployment: {any}", .{err});
                            continue;
                        };

                        // 結果をコントラクトストレージに保存
                        contract_storage.put(tx.receiver, result) catch |err| {
                            std.log.err("Failed to store contract result: {any}", .{err});
                        };
                        std.log.info("Re-executed and stored contract at address: {s}, code length: {d} bytes", .{ tx.receiver, result.len });
                    }
                }
            }
        }

        // コントラクトストレージの状態をログに出力（同期後）
        var contract_count_after: usize = 0;
        var it_after = contract_storage.iterator();
        while (it_after.next()) |entry| {
            contract_count_after += 1;
            std.log.info("Contract in storage after sync: address={s}, code_length={d}", .{ entry.key_ptr.*, entry.value_ptr.*.len });
        }
        std.log.info("Contract storage after sync: {d} contracts", .{contract_count_after});

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
/// チェーンの高さと各ブロックの詳細情報を見やすい形式で表示します
pub fn printChainState() void {
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

/// EVMトランザクションを処理し、その結果をブロックチェーンに追加する
///
/// 引数:
///     tx: 処理するトランザクション
///
/// 戻り値:
///     実行結果のバイト配列またはエラー
pub fn processEvmTransaction(tx: *types.Transaction) ![]const u8 {
    // トランザクション識別子を生成（まだ設定されていない場合）
    if (std.mem.eql(u8, &tx.id, &[_]u8{0} ** 32)) {
        tx.id = calculateTransactionHash(tx);
    }

    // EVMデータが存在することを確認
    const evm_data = tx.evm_data orelse return error.NoEvmData;

    const allocator = std.heap.page_allocator;

    var result: []const u8 = "";
    var contract_deployed = false;

    switch (tx.tx_type) {
        // コントラクトデプロイの場合
        1 => {
            std.log.info("スマートコントラクトをデプロイしています: 送信者={s}, ガス上限={d}", .{ tx.sender, tx.gas_limit });

            // EVMバイトコードを実行
            const calldata = "";
            result = try @import("evm.zig").execute(allocator, evm_data, calldata, tx.gas_limit);

            // 返されたランタイムコードを保存（デプロイ時の実行結果がランタイムコード）
            try contract_storage.put(tx.receiver, result);
            contract_deployed = true;

            std.log.info("コントラクトが正常にデプロイされました: アドレス={s}, コード長={d}バイト", .{ tx.receiver, result.len });

            // メモリはすでに使われているため、明示的に捨てる必要はない
        },

        // コントラクト呼び出しの場合
        2 => {
            std.log.info("スマートコントラクトを呼び出しています: アドレス={s}, 送信者={s}, ガス上限={d}", .{ tx.receiver, tx.sender, tx.gas_limit });

            // コントラクトコードを取得
            const contract_code = contract_storage.get(tx.receiver) orelse {
                std.log.err("コントラクトが見つかりません: アドレス={s}", .{tx.receiver});
                return error.ContractNotFound;
            };

            // EVMを実行
            result = try @import("evm.zig").execute(allocator, contract_code, evm_data, tx.gas_limit);

            std.log.info("コントラクト呼び出しが完了しました: 結果長={d}バイト", .{result.len});
        },

        // その他のトランザクションタイプ（通常の送金など）
        else => {
            std.log.info("EVMトランザクションではありません: タイプ={d}", .{tx.tx_type});
            return error.NotEvmTransaction;
        },
    }

    // コントラクトがデプロイされた場合、P2P同期のために特別なトランザクションを含むブロックを作成
    if (contract_deployed) {
        // トランザクションを含む新しいブロックを作成
        const last_block = if (chain_store.items.len > 0) chain_store.items[chain_store.items.len - 1] else try createTestGenesisBlock(allocator);
        var new_block = createBlock("Contract Deployment", last_block);

        // トランザクションを追加（元のバイトコードを含む）
        try new_block.transactions.append(tx.*);

        // コントラクトストレージも追加 - ランタイムコードをブロックに含める
        var contracts = std.StringHashMap([]const u8).init(allocator);
        try contracts.put(tx.receiver, result);
        new_block.contracts = contracts;

        // ブロックをマイニングして追加
        mineBlock(&new_block, DIFFICULTY);

        std.log.info("コントラクトデプロイブロック作成開始: アドレス={s}, トランザクション数={d}, コントラクト数={d}", .{ tx.receiver, new_block.transactions.items.len, contracts.count() });

        // ブロックに追加する前にダンプして確認
        if (contracts.get(tx.receiver)) |code| {
            std.log.info("contracts内コード長: {d}bytes", .{code.len});
        } else {
            std.log.err("contracts内にコードがない", .{});
        }

        // ブロックを追加
        addBlock(new_block);

        // 新しいブロックをピアにブロードキャスト
        @import("p2p.zig").broadcastBlock(new_block, null);

        std.log.info("コントラクトデプロイブロックを作成しました: address={s}", .{tx.receiver});
    }

    return result;
}

/// EVMトランザクションの実行結果をログに記録
pub fn logEvmResult(tx: *const types.Transaction, result: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const hex_result = try std.fmt.allocPrint(allocator, "0x{s}", .{try @import("utils.zig").bytesToHex(allocator, result)});
    defer allocator.free(hex_result);

    std.log.info("EVM実行結果: TxID={s}, 結果={s}", .{ try std.fmt.allocPrint(allocator, "{x}", .{tx.id}), hex_result });

    if (result.len >= 32) {
        var value = @import("evm_types.zig").EVMu256{ .hi = 0, .lo = 0 };

        for (0..16) |j| {
            const byte_val = result[j];
            value.hi |= @as(u128, byte_val) << @intCast((15 - j) * 8);
        }
        for (0..16) |j| {
            const byte_val = result[j + 16];
            value.lo |= @as(u128, byte_val) << @intCast((15 - j) * 8);
        }

        std.log.info("EVM実行結果(u256): {}", .{value});
    }
}

/// EVMトランザクションを実行し、詳細なエラー情報を含めて処理する
///
/// 引数:
///     tx: 処理するトランザクション
///
/// 戻り値:
///     実行結果またはエラー
pub fn processEvmTransactionWithErrorDetails(tx: *types.Transaction) ![]const u8 {
    // トランザクション識別子を生成（まだ設定されていない場合）
    if (std.mem.eql(u8, &tx.id, &[_]u8{0} ** 32)) {
        tx.id = calculateTransactionHash(tx);
    }

    // EVMデータが存在することを確認
    const evm_data = tx.evm_data orelse return error.NoEvmData;

    const allocator = std.heap.page_allocator;
    var result: []const u8 = "";

    switch (tx.tx_type) {
        // コントラクトデプロイの場合
        1 => {
            std.log.info("スマートコントラクトをデプロイしています: 送信者={s}, ガス上限={d}", .{ tx.sender, tx.gas_limit });

            // EVMバイトコードを詳細エラー情報付きで実行
            const calldata = "";
            const evm_result = @import("evm.zig").executeWithErrorInfo(allocator, evm_data, calldata, tx.gas_limit);

            if (!evm_result.success) {
                // 詳細なエラー情報を表示
                if (evm_result.error_message) |msg| {
                    std.log.err("コントラクトデプロイエラー: {s}", .{msg});
                }
                if (evm_result.error_type) |err_type| {
                    std.log.err("エラータイプ: {any}, PC: {any}", .{ err_type, evm_result.error_pc orelse 0 });
                }

                // オペコードの16進数表示と詳細情報
                if (evm_result.error_pc) |pc| {
                    if (pc < evm_data.len) {
                        const invalid_opcode = evm_data[pc];
                        std.log.err("無効なオペコード (16進): 0x{x:0>2}, (10進): {d}", .{ invalid_opcode, invalid_opcode });

                        // デバッグモジュールの関数を使用して詳細情報を表示
                        const opcode_desc = evm_debug.getInvalidOpcodeDetail(invalid_opcode);
                        const error_analysis = evm_debug.analyzeErrorCause(evm_data, pc);

                        std.log.err("オペコード詳細: {s}", .{opcode_desc});
                        std.log.err("エラー分析: {s}", .{error_analysis});

                        // 詳細なバイトコード表示（Hexdump形式）
                        var hexdump_buffer = std.ArrayList(u8).init(allocator);
                        defer hexdump_buffer.deinit();

                        evm_debug.hexdumpCodeContext(evm_data, pc, 16, hexdump_buffer.writer()) catch {};
                        std.log.err("バイトコード詳細表示:\n{s}", .{hexdump_buffer.items});

                        // Solidityバージョン推測
                        const version_info = evm_debug.guessSolidityVersion(evm_data);
                        std.log.err("推定コンパイラ: {s}", .{version_info});

                        // Solidityバージョン固有のエラー解決策を提示
                        if (invalid_opcode == 0x0F) {
                            std.log.err("解決策: このコントラクトはSolidity 0.8.x系でコンパイルされた可能性が高いです。", .{});
                            std.log.err("        1. Solidity 0.7.x以下を使用してコントラクトを再コンパイルする", .{});
                            std.log.err("        2. または、EVMの実装を拡張して0x0F, 0x5F等の新しいオペコードをサポートする", .{});
                            std.log.err("        3. または、--evm-version=berlin などのコンパイラオプションを使用する", .{});
                        } else if (invalid_opcode == 0xFE) {
                            std.log.err("解決策: このコードはassert()が失敗したか、故意にrevertされています。コントラクトのロジックを確認してください。", .{});
                        }
                    }
                }

                return error.EvmExecutionFailed;
            }

            result = evm_result.data;

            // 返されたランタイムコードを保存（デプロイ時の実行結果がランタイムコード）
            try contract_storage.put(tx.receiver, result);

            std.log.info("コントラクトが正常にデプロイされました: アドレス={s}, コード長={d}バイト", .{ tx.receiver, result.len });
        },

        // コントラクト呼び出しの場合
        2 => {
            std.log.info("スマートコントラクトを呼び出しています: アドレス={s}, 送信者={s}, ガス上限={d}", .{ tx.receiver, tx.sender, tx.gas_limit });

            // コントラクトコードを取得
            const contract_code = contract_storage.get(tx.receiver) orelse {
                std.log.err("コントラクトが見つかりません: アドレス={s}", .{tx.receiver});
                return error.ContractNotFound;
            };

            // EVMを詳細エラー情報付きで実行
            const evm_result = @import("evm.zig").executeWithErrorInfo(allocator, contract_code, evm_data, tx.gas_limit);

            if (!evm_result.success) {
                // 詳細なエラー情報を表示
                if (evm_result.error_message) |msg| {
                    std.log.err("コントラクト呼び出しエラー: {s}", .{msg});
                }
                if (evm_result.error_type) |err_type| {
                    std.log.err("エラータイプ: {any}, PC: {any}", .{ err_type, evm_result.error_pc orelse 0 });
                }

                // オペコードの16進数表示と詳細情報
                if (evm_result.error_pc) |pc| {
                    if (pc < contract_code.len) {
                        const invalid_opcode = contract_code[pc];
                        std.log.err("無効なオペコード (16進): 0x{x:0>2}, (10進): {d}", .{ invalid_opcode, invalid_opcode });

                        // デバッグモジュールの関数を使用して詳細情報を表示
                        const opcode_desc = evm_debug.getInvalidOpcodeDetail(invalid_opcode);
                        const error_analysis = evm_debug.analyzeErrorCause(contract_code, pc);

                        std.log.err("オペコード詳細: {s}", .{opcode_desc});
                        std.log.err("エラー分析: {s}", .{error_analysis});

                        // 詳細なバイトコード表示（Hexdump形式）
                        var hexdump_buffer = std.ArrayList(u8).init(allocator);
                        defer hexdump_buffer.deinit();

                        evm_debug.hexdumpCodeContext(contract_code, pc, 16, hexdump_buffer.writer()) catch {};
                        std.log.err("バイトコード詳細表示:\n{s}", .{hexdump_buffer.items});

                        // Solidityバージョン推測
                        const version_info = evm_debug.guessSolidityVersion(contract_code);
                        std.log.err("推定コンパイラ: {s}", .{version_info});

                        // 関数セレクタの解析（呼び出しデータの先頭4バイトに基づく関数識別）
                        if (evm_data.len >= 4) {
                            hexdump_buffer.clearRetainingCapacity();
                            evm_debug.analyzeFunctionSelector(evm_data, hexdump_buffer.writer()) catch {};
                            std.log.err("関数呼び出し解析:\n{s}", .{hexdump_buffer.items});
                        }

                        // 関数呼び出し時の特定エラーパターンに対する特別な対応
                        if (invalid_opcode == 0x0F) {
                            std.log.err("解決策: このコントラクトはSolidity 0.8.x系でコンパイルされた可能性が高いです。", .{});
                            std.log.err("        1. Solidity 0.7.x以下を使用してコントラクトを再コンパイルする", .{});
                            std.log.err("        2. または、EVMの実装を拡張して0x0F, 0x5F等の新しいオペコードをサポートする", .{});
                            std.log.err("        3. または、--evm-version=berlin などのコンパイラオプションを使用する", .{});
                        } else if (invalid_opcode == 0xFE) {
                            std.log.err("解決策: このコードはassert()が失敗したか、故意にrevertされています。コントラクトのロジックを確認してください。", .{});
                        }
                    }
                }

                return error.EvmExecutionFailed;
            }

            result = evm_result.data;
            std.log.info("コントラクト呼び出しが完了しました: 結果長={d}バイト", .{result.len});
        },

        // その他のトランザクションタイプ（通常の送金など）
        else => {
            std.log.info("EVMトランザクションではありません: タイプ={d}", .{tx.tx_type});
            return error.NotEvmTransaction;
        },
    }

    return result;
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
