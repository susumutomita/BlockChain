---
title: "PoS（Proof of Stake）の導入"
free: true
---

これまでの実装では、PoW（Proof of Work）を利用してブロックを生成し、競合を解決してきました。しかしPoWには高い計算コストが必要、環境負荷が大きい、といった課題があります。そこで本章では、より省電力なPoS（Proof of Stake）の概念を導入し、PoWと切り替えながら実行できるようにします。

## 1. コンセンサスアルゴリズムとは

ブロックチェインなどの分散型ネットワークでは、中央管理者が不在でも全ノードが取引の正当性に合意し、一貫した台帳を維持する必要があります。そのために各ノードが相互に取引を検証し合意してブロックをチェインに追加していく仕組みが **コンセンサスアルゴリズム** と呼ばれます。このメカニズムにより、不正な取引が記録されないようにネットワーク全体で信頼性を確保しています。 ([PoWとPoSの仕組みの違いは？ 採用する代表的な暗号資産も紹介 | CoinDesk JAPAN（コインデスク・ジャパン）](https://www.coindeskjapan.com/learn/pow-pos/))

現在代表的なコンセンサスアルゴリズムとして **PoW（Proof of Work）** と **PoS（Proof of Stake）** の2つが広く知られています。**PoW** は「仕事量の証明」という名の通り、**計算作業（ハッシュ計算）による証明**で合意を取る方式です。ビットコインを始め多くの初期ブロックチェインで採用されており、マイナー（採掘者）たちが **暗号学的パズル**（ハッシュ計算問題）の解答を競争します。一方で **PoS** は「保有量の証明」の名の通り、**暗号資産の保有量（ステーク）による証明**で合意を取る方式です。ブロック生成の権利を、各ノードが保有するコインの数量に比例した確率で割り当てる仕組みになっており、計算資源ではなく経済的な利害関係によってネットワークの合意形成を行います。
簡単に言えば、**PoWは計算力による競争、PoSはコイン保有量による抽選**でブロック提案者を決定します。以下では、Zig言語を用いてそれぞれのアルゴリズムを簡易実装し、動作の違いを確認してみます。

### セキュリティと消費電力の違い

PoWは非常に高いセキュリティを誇ります。理由はシンプルで、「ブロックチェインを書き換えるにはネットワーク全体の圧倒的な計算能力を支配する必要がある」ためです。攻撃者が仮に不正なブロックを作ろうとしても、正直なマイナー全員の合計よりも速くナンスを見つけ続けなければ追いつけません。つまり**ネットワークの計算力の過半数（51％以上）を支配**しなければ改ざんは極めて困難です。 ([PoWとPoSの違い - 国内最大手の暗号資産マイニング、ビットコイン、およびブロックチェインに関する情報提供メディアです](https://www.bfmedia.jp/proof-of-work-vs-proof-of-stake))。この性質によりPoWは**ビザンチン耐性**（一部のノードが不正でも全体の合意は崩れない性質）を実現し、ビットコインなどで10年以上に渡り堅牢性が実証されています。一方でデメリットとして**莫大な計算資源（電力）を消費**する点が挙げられます。これはブロックを生成するために世界中のマイナーが同じ計算を競争で繰り返すためです。
また、計算競争により取引処理速度（スループット）にも制限があります（ビットコインは約10分/block、数トランザクション/秒程度）。

PoSは**エネルギー効率に優れ、スループットの向上**も見込める方式です。ブロック生成においてハードウェア競争が無いため、消費電力は僅かで済みます。実際、EthereumがPoWからPoSに移行した際にはエネルギー消費が**99.95％削減**されたと報告されており、その差は非常に大きいです。また、ブロック提案者が即座に決まるため**ブロックタイムの短縮**や**トランザクション処理量の増加**が比較的容易です。
一方でセキュリティ面では「計算力」ではなく「経済力」に基づくため、異なる懸念も指摘されています。例えば、大量のコインを保有する資産家や取引所が検証者の多くを占めると権限の集中が起こりうる点です。PoSネットワークでは富の偏在がそのまま影響力の偏在につながる可能性があり、少数の大口保有者が意思決定を左右してしまうリスクがあります。ただしこの点については、後述するように経済的インセンティブ設計によって大口保有者が不正を働く動機を抑制する工夫がされています。

### 51％攻撃のリスクと対策

PoW,PoSどちらの方式でも理論上は「ネットワークの過半数を掌握した場合」に不正が可能になります。これを**51％攻撃**（多数派攻撃）と呼びます。PoWにおける51％攻撃は、ネットワーク全体の51％以上の計算能力（ハッシュレート）を単独で握ることで、不正なブロックを連続して生成しチェインを書き換える攻撃です。攻撃者は自分に都合の良い取引だけを承認し、過去の取引を改ざん（二重支払いなど）できてしまう可能性があります。もっとも、実際にこれを達成するのは非常に困難であり、ビットコインなどでは現実的ではないとされています。それでも歴史上、小規模なPoWネットワーク（例: ビットコインゴールドなど）が51％攻撃を受けた事例もあります。
PoSにおける51％攻撃は、ネットワーク上の51％以上のステーク(コイン)**を保有することを意味します。こちらも現実には容易ではありません。膨大な資金が必要である上、それだけの通貨を買い占めれば価格が高騰し、更に攻撃が発覚すれば通貨の信用失墜で価値暴落を招くため、攻撃者にはほとんどメリットがありません。また、PoSプロトコルでは悪意ある行為が検知された場合にステークを没収するペナルティ(例: スラッシング)を用意し、不正行為そのものを経済的に割に合わないように設計しています。

### 実際のブロックチェインでの採用例

現在の主要なブロックチェインプロジェクトにおけるPoWとPoSの採用状況を見てみます。

- ビットコイン (BTC) – 2009年に登場した世界初の暗号資産で、**コンセンサスアルゴリズムにPoWを採用**しています。大量のマイナーが世界中でハッシュ計算競争に参加することでそのセキュリティを維持しており、極めて分散化されたネットワークを構築しています。ただし前述のとおりエネルギー消費の大きさから環境への影響も指摘されています。
- イーサリアム (ETH) – ビットコインに次ぐ時価総額を持つブロックチェインプラットフォームです。当初はPoWベースでしたが、2022年9月の大型アップグレード「The Merge（マージ）」によって**PoSベースのコンセンサスアルゴリズム（Gasper）に移行**しました。これによりエネルギー消費を劇的に削減しつつ、将来的なスケーラビリティ向上（シャーディング等）に道を開いたとされています。Ethereumの移行はPoS方式が大規模ネットワークでも機能することを示す大きな事例となりました。
- **カルダノ (ADA)** – 代表的なPoS採用プロジェクトの1つです。学術的アプローチで開発されており、**Ouroboros**と呼ばれるPoSコンセンサスプロトコルを採用しています。Ouroborosは世界初の厳密なセキュリティ検証に基づくPoSプロトコルであり、高い安全性と持続可能性を両立することを目指しています。カルダノでは多数のステークプールにより分散運用が行われ、PoSならではの省電力性とスループットの高さを活かしています。

この他にも、**Litecoin**や**Monero**などビットコインの派生やプライバシー重視通貨はPoW方式を踏襲しています。一方で**Polkadot**（NPoSと呼ばれるPoS変種）や**Solana**、**Avalanche**、**Tezos**など新興のスマートコントラクトプラットフォームは軒並みPoS系のアルゴリズムを採用しています。以前は主流だったPoWですが、近年は環境負荷やスケーラビリティの理由から**コンセンサスアルゴリズムの主流はPoSに移行しつつある**と言えるでようか。

## PoSへの第一歩

Ethereumなど多くのプロジェクトが採用しているPoSでは、「トークンをステーク（預ける）している量に比例した確率」でブロック提案者（Validator）が選ばれる仕組みを持ちます。本章では以下のようなシンプルなPoSを実装します。

### ステーク（Stake）の記録

各ユーザが「どれだけのステークを持っているか」をチェインの状態として保持します（簡易版ではCLI操作で変更）。将来的にはスマートコントラクト上でステークを管理し、Validator登録や報酬計算、スラッシングなどもコントラクト内で完結させる予定です。

### 重み付き抽選でブロック提案者を選定

PoSモード時は、ネットワーク参加ノードの中で「所持ステークの合計に比例した確率」でランダムに1名が次のブロック提案権を得る仕組みを実装します。具体的には、全ノードのステーク量を合計し、その合計に基づいて確率ルーレットを作成、ランダムに1名を選定します。
選定されたノードがブロックを生成し、報酬として固定量を上乗せします。
この際、全ノードが同時にブロック生成を試みるため、選定されたノードだけがブロックを生成し、他のノードは待機状態を保つ仕組みです。
このように、PoSでは「計算リソースを使わずにブロック提案者を選ぶ」ことが可能です。これにより、PoWと比較してマイニングの計算負荷を軽減し、環境負荷を低減できます。

### スラッシング（Slashing）

PoSでは、悪意のある行動（ダブルサインや不正提案）を防ぐために「スラッシング」という仕組みがあります。スラッシングは、悪意のある行動をしたノードのステークを没収することで、ネットワークの安全性を確保します。今回は簡易版として、ダブルサイン時に全ステーク没収する形で実装します。
将来的には、EVM上のスマートコントラクトでスラッシングロジックを実装し、より高度なセキュリティを提供する予定です。

### 報酬分配

PoSでは、ブロック提案者に報酬を分配する仕組みがあります。今回はシンプル版として、成功裏にブロックを生成できた提案者に「固定報酬」を与える形で実装します。将来的には、報酬分配のロジックを高度化し、ネットワーク参加報酬やデポジット返却、インアクティブ時のペナルティなどを考慮した報酬分配を実装する予定です。

### PoWとの併用

PoWとPoSを併用することで、両者のメリットを享受しつつ、デメリットを軽減できます。具体的には、起動時にコマンドラインオプションでPoWかPoSかを選択できるようにし、必要に応じて切り替えられるようにします。
これにより、PoW、PoS両方の違いを理解できます。
具体的には、起動時のコマンドラインオプション（例：--posか--pow）でどちらを使うか指定できるようにします。

本章ではまずPoSを試験的に動かすところまでを実装しましょう。

⸻

## PoS用のデータ構造

PoSモードでは各アドレス（ユーザ）が「何Stake保有しているか」を管理する必要があります。ここではZig側のblockchain.zigに以下のように簡易的なグローバルマップを追加し、Stakeを記録します。将来的にEVM上のスマートコントラクトで管理する際には、この部分をスマコン呼び出しに置き換える想定です。

```blockchain.zig (抜粋)
pub var chain_store = std.ArrayList(types.Block).init(std.heap.page_allocator);

/// シンプルなステークマップ
/// address文字列 -> stake量
pub var stake_map = std.StringHashMap(u64).init(std.heap.page_allocator);


/// ステークを追加・変更する
///
/// 引数:
///     addr: ステークを保有するアドレス
///     amount: 新たに設定するステーク量
pub fn setStake(addr: []const u8, amount: u64) void {
    stake_map.put(addr, amount) catch {
        std.log.err("Failed to set stake for {s}", .{addr});
        return;
    };
    std.log.info("Stake updated: {s} = {d}", .{addr, amount});
}

/// addrが持つステーク量を取得する
pub fn getStake(addr: []const u8) u64 {
    return switch (stake_map.get(addr)) {
        .some => |v| v,
        .none => 0,
    };
}
```

ここでは**stake_mapを用意し、setStake関数で更新します。実際にステーク量を増減させるトランザクションを定義してもよいですが、まずはCLIコマンドで直接操作します。

⸻

### PoSロジック（シンプル版）

PoSモード時にブロック生成する際、次のようなフローを追加します。

1. 全アドレスのステーク量を合計
2. その合計を元に確率ルーレットを作り、ランダム抽選で1名を選定
3. 選定されたノードがブロックを生成し、報酬として固定量を上乗せ

ただし今回のサンプルでは、「どのノードがどのアドレスで参加しているか」を決め打ちまたはCLI入力とし、PoSモードかつ自ノードが当選者の場合だけブロック生成をします。
複数ノードが同時に動いている場合は、それぞれのノードが選ばれたかどうかを判定し、選ばれなければ待機状態を保つ仕組みです。

### pos.zig（PoSロジックモジュール）

以下のサンプルコードでは、runPosLoopというスレッドを新設し、PoSモード時に一定間隔で抽選→当選ノードがブロック生成→ブロードキャストを行う流れを示しています。

```zig
//! PoS(Proof of Stake)のシンプル実装モジュール

const std = @import("std");
const blockchain = @import("blockchain.zig");
const p2p = @import("p2p.zig");
const types = @import("types.zig");

pub const PosConfig = struct {
    pub const SelfAddrMaxLen = 64;

    /// このノードに対応するアドレス（ステークマップで検索される）
    self_address: [SelfAddrMaxLen]u8,
    /// 実際の長さ
    self_address_len: usize,
    /// ブロック生成間隔（秒）
    block_interval_sec: u64,
    /// ブロック生成時の固定報酬
    block_reward: u64,
};

/// PoSを実行するループ
///
/// 1. 一定間隔でタイマー待ち
/// 2. ステークに基づいてランダム抽選
/// 3. 当選者がブロックを作成してブロードキャスト
pub fn runPosLoop(cfg: PosConfig) !void {
    std.log.info("PoS loop started. SelfAddr={s}, Interval={d}s",
        .{
            cfg.self_address[0..cfg.self_address_len],
            cfg.block_interval_sec
        }
    );

    while (true) {
        std.time.sleep(cfg.block_interval_sec * std.time.ns_per_s);

        const total_stake = getTotalStake();
        if (total_stake == 0) {
            std.log.warn("No stake found. Skipping PoS block generation", .{});
            continue;
        }

        // 抽選
        const winner_addr = pickWinner(total_stake);
        if (std.mem.eql(u8, winner_addr, cfg.self_address[0..cfg.self_address_len])) {
            // 当選したらブロック生成
            createAndBroadcastBlock(cfg);
        } else {
            std.log.info("PoS: Not selected (Winner={s})", .{winner_addr});
        }
    }
}

/// 全アドレスのステーク合計を返す
fn getTotalStake() u64 {
    var sum: u64 = 0;
    var it = blockchain.stake_map.iterator();
    while (it.next()) |entry| {
        sum += entry.value;
    }
    std.log.info("Total stake calculated: {d}", .{sum});
    return sum;
}

/// ステーク量に応じたランダム抽選でwinnerのアドレスを返す
fn pickWinner(total_stake: u64) []const u8 {
    // 0..total_stake の範囲で乱数を1つ取る
    // ここでは std.rand.defaultOpenSeed などを用い、簡易的に実装
    var rnd = getRandomRange(total_stake);

    var it = blockchain.stake_map.iterator();
    while (it.next()) |entry| {
        if (rnd < entry.value) {
            return entry.key;
        } else {
            rnd -= entry.value;
        }
    }

    // 万が一合わなければ最後のアドレス
    // (理論上は合計が一致しているのでここまで来ない)
    return blockchain.stake_map.items[blockchain.stake_map.items.len - 1].key;
}

/// 指定された範囲(0..max-1)の乱数を返す
fn getRandomRange(max: u64) u64 {
    var seed = std.rand.defaultOpenSeed();
    var rndGen = std.rand.DefaultPrng.init(seed);
    return rndGen.uniform(u64) % max;
}

/// ブロックを生成してブロードキャストする
fn createAndBroadcastBlock(cfg: PosConfig) void {
    std.log.info("PoS: Winner! Generating block", .{});

    // チェインが空ならジェネシスブロックを作成
    const last_block = if (blockchain.chain_store.items.len == 0)
        blockchain.createTestGenesisBlock(std.heap.page_allocator) catch return
    else
        blockchain.chain_store.items[blockchain.chain_store.items.len - 1];

    // データ部分にPoSおよび報酬情報を入れる（デモ用）
    const data_str = "PoS block by " ++ cfg.self_address[0..cfg.self_address_len];

    var new_block = blockchain.createBlock(data_str, last_block);

    // 報酬としてトランザクションを追加(超簡略化)
    // senderを"POS_REWARD"、receiverをself_addressとしてTxを追加
    var reward_tx = types.Transaction{
        .sender = "POS_REWARD",
        .receiver = std.mem.cast([]const u8, cfg.self_address[0..cfg.self_address_len]),
        .amount = cfg.block_reward,
    };
    _ = new_block.transactions.append(reward_tx) catch {
        std.log.err("Failed to append reward tx", .{});
    };

    // PoW時のマイニングはスキップ
    // new_block = no hashing procedure (PoS)
    // 一応軽くハッシュだけ計算しておく（verify用）
    new_block.hash = blockchain.calculateHash(&new_block);

    // チェインにブロックを追加
    blockchain.addBlock(new_block);

    // 他のピアへ配信
    p2p.broadcastBlock(new_block, null);
}
```

この例ではPoWを一切回さず、ランダム当選したノードだけがcreateAndBroadcastBlock()を呼ぶ形です。実際にはPoSでもブロックハッシュは計算しますが、マイニングのような計算競争は行いません。

⸻

## PoSかPoWかを選択する

既存のmain.zigを修正し、起動時に--posフラグがあればPoSモード、なければPoWモードを使うようにします。加えて、PoSモードの場合はrunPosLoop()を別スレッドで起動して定期的にブロック生成を試みます。PoWモードの場合は従来どおりp2p.textInputLoop()でユーザが入力しマイニングを実行する流れを維持します。

```main.zig

const std = @import("std");
const p2p = @import("p2p.zig");
const pos = @import("pos.zig");
const blockchain = @import("blockchain.zig");

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    // コマンドライン解析
    if (args.len < 2) {
        std.log.err("Usage: {s} <port> [--pos] [--stake <addr> <amount>] [peers...]", .{ args[0] });
        return;
    }

    // ポート指定
    const self_port = try std.fmt.parseInt(u16, args[1], 10);
    var arg_index: usize = 2;
    var is_pos_mode = false;
    var pos_cfg = pos.PosConfig{
        .self_address_len = 0,
        .block_interval_sec = 10,
        .block_reward = 50,
    };
    // デフォルトのself_addressは"Node<port>"とする
    {
        const tmp_str = try std.fmt.allocPrint(gpa, "Node{}", .{self_port});
        defer std.heap.page_allocator.free(tmp_str);
        std.mem.copy(u8, &pos_cfg.self_address, tmp_str);
        pos_cfg.self_address_len = tmp_str.len;
    }

    // 追加オプションを解析
    while (arg_index < args.len) : (arg_index += 1) {
        const arg = args[arg_index];
        if (std.mem.eql(u8, arg, "--pos")) {
            is_pos_mode = true;
        } else if (std.mem.eql(u8, arg, "--stake") and arg_index + 2 < args.len) {
            // e.g. --stake Alice 100
            const addr = args[arg_index + 1];
            const amt_str = args[arg_index + 2];
            const amt = try std.fmt.parseInt(u64, amt_str, 10);
            blockchain.setStake(addr, amt);
            arg_index += 2;
        } else {
            // ピアかもしれない
            // 解析して接続
            const peer_addr = try p2p.resolveHostPort(arg);
            _ = try std.Thread.spawn(.{}, p2p.connectToPeer, .{peer_addr});
        }
    }

    // チェイン状態を表示
    blockchain.printChainState();

    // P2Pリスナー起動
    _ = try std.Thread.spawn(.{}, p2p.listenLoop, .{ self_port });

    // モード切り替え
    if (is_pos_mode) {
        std.log.info("Starting in PoS mode ...", .{});
        // PoSループを別スレッドで起動
        _ = try std.Thread.spawn(.{}, pos.runPosLoop, .{pos_cfg});
    } else {
        std.log.info("Starting in PoW mode ...", .{});
        // 従来のtextInputLoop: CLI入力ごとにマイニング
        _ = try std.Thread.spawn(.{}, p2p.textInputLoop, .{});
    }

    // メインスレッドを生かし続ける
    while (true) {
        std.time.sleep(60 * std.time.ns_per_s);
    }
}
```

使い方は以下のようになります。

```bash
# PoWモードで起動（従来どおりマイニング可能）
zig build run -- 8000
# PoSモードで起動（10秒間隔で抽選を行い、自ノードが当選ならブロック生成）
zig build run -- 8001 --pos
# ステーク操作
zig build run -- 8002 --pos --stake Alice 100 --stake Bob 200
```

複数ノードをPoSモードで起動すると、ノードごとのステークマップは独立しているため、本格的なネットワーク共通状態とは少し異なります。将来的にはオンチェインのステーク管理コントラクトやトランザクションを用いて、すべてのノードが同じステーク状態を共有する必要があります。今回はPoS導入の最初のステップとして、あくまで学習用のシンプル版です。

⸻

## 動作確認

### NodeA: PoWモード（ポート8000で起動）

```bash
zig build run -- 8000
```

### NodeB: PoSモード（ポート8001で起動、ステーク設定あり）

```bash
zig build run -- 8001 --pos --stake Node8001 150 127.0.0.1:8000
```

これによりPoWノード(8000)とPoSノード(8001)が同一ネットワーク上で稼働。NodeBはPoSループを回し、10秒間隔で抽選をします。
PoSノード(8001)で抽選に当選すると、ブロックが生成されNetworkにブロードキャストされます。NodeA(8000)のログを見るとinfo: Added new block ...が表示されるはずです。
一方、NodeA(8000)では手動CLI入力→マイニング→ブロック生成のフローが従来どおり行えます。どちらかが生成したブロックも相互に同期され、同じチェイン上に蓄積されていきます。

⸻

## 今後の拡張

今回のPoS実装は非常に簡略化したもので、以下のような本格機能は未対応です。

- ステークの真正性: 現状はCLIで--stakeオプションを指定するだけでいくらでもステークを設定可能。
- 実際にはコイン保有量と連動させる必要がある。将来的にはEVM上でステーキングコントラクトを介してロックした資金だけを有効ステークと認める仕組みが必要。
- 複数ノード間でのステーク共有: 各ノードがバラバラにstake_mapを持っているため、グローバルな合意が行われていない。実際にはトランザクションやブロックを通じて、正しい合意状態を維持する必要がある。
- スラッシング: ダブルサインや不正提案を検出した場合にステークを没収する等、PoSの安全保障策が未実装。
- 報酬ロジックの高度化: ブロック提案報酬の他に、ネットワーク参加報酬、デポジット返却、インアクティブ時のペナルティなど多数。

これらは次章以降やスマートコントラクト章で扱います。とりあえず本章では「PoWとPoSを切り替えて遊べる最小実装」を体験することが目的です。

⸻

### まとめ

本章では、PoW中心だったチェインにPoS(Proof of Stake) の概念を組み込みました。起動オプション--posでPoSモードに切り替え、シンプルなステークマップとランダム抽選によりブロック生成を進める仕組みです。

- PoS導入のメリット: 計算リソースの節約、環境負荷の軽減など
- 課題: 本格的なステーキング、スラッシング、報酬分配やEVMとの連携などやることは多い
- 今回は簡易版として、CLI操作でステークを設定し、PoSモードでブロック生成する仕組みを実装しました。
- 次章以降で本格的なPoS機能を実装していきます。
- スマートコントラクト章では、EVM上でのPoS実装し、より高度なセキュリティと機能を提供する予定です。
