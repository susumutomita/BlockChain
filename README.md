<!-- textlint-enable ja-technical-writing/sentence-length -->
![GitHub last commit (by committer)](https://img.shields.io/github/last-commit/susumutomita/BlockChain)
![GitHub top language](https://img.shields.io/github/languages/top/susumutomita/BlockChain)
![GitHub pull requests](https://img.shields.io/github/issues-pr/susumutomita/BlockChain)
![GitHub code size in bytes](https://img.shields.io/github/languages/code-size/susumutomita/BlockChain)
![GitHub repo size](https://img.shields.io/github/repo-size/susumutomita/BlockChain)
[![Zig CI](https://github.com/susumutomita/BlockChain/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/susumutomita/BlockChain/actions/workflows/ci.yml)
<!-- textlint-enable ja-technical-writing/sentence-length -->

# Zig Simple Blockchain

シンプルなブロックチェーンの Zig 言語による実装です。
ブロックチェーンの基本的な概念を学ぶためのプロジェクトです。

## 機能

- ブロック生成
- トランザクション管理
- SHA-256 ハッシュ計算
- Proof of Work (PoW) マイニング
- デバッグログ機能

## 主要なコンポーネント

### ブロック (Block)

- インデックス番号
- タイムスタンプ
- 前ブロックのハッシュ
- トランザクションリスト
- Nonce値（マイニング用）
- データ
- 自身のハッシュ値

### トランザクション (Transaction)

- 送信者 (sender)
- 受信者 (receiver)
- 取引金額 (amount)

## ビルドと実行方法

```bash
# プロジェクトのビルド
zig build

# （P2Pノードとして起動する例）
zig build run -- --listen 9000
```

## デバッグモード

`src/main.zig` の先頭にある `debug_logging` 定数を変更することで、
デバッグ情報の出力を制御できます：

```zig
const debug_logging = true;  // デバッグ情報を出力
const debug_logging = false; // デバッグ情報を出力しない
```

## 学習ポイント

このプロジェクトでは以下の概念を学ぶことができます：

1. **ブロックチェーンの基本構造**
   - ブロックの連鎖
   - ハッシュによる連携
   - トランザクションの管理

2. **暗号技術の基礎**
   - SHA-256ハッシュ関数
   - Proof of Work (PoW)

3. **Zigプログラミング**
   - 構造体の定義と使用
   - メモリ管理
   - ジェネリックプログラミング
   - コンパイル時の最適化

## 今後の拡張案

- [ ] ブロックチェーンの永続化
- [ ] P2Pネットワーク機能
- [ ] 高度な暗号化機能
- [ ] WebAPI インターフェース
- [ ] ウォレット機能

## テスト実行

### 基本的なテスト実行

```bash
# テストを実行する
zig build test
```

## ライセンス

MIT License

## 貢献

プルリクエストや問題報告は歓迎します。
以下の手順で貢献できます：

1. このリポジトリをフォーク
2. 新しいブランチを作成
3. 変更をコミット
4. プルリクエストを送信

## EVM の使い方（SimpleAdder をデプロイ＆呼び出し）

以下は `references/chapter9/contract/SimpleAdder.sol`（Adder）を使った最短手順です。

### 前提
- Zig が入っている
- solc が入っている（`solc --version` で確認）
- このリポジトリ直下で実行

### 1) ビルド
```bash
zig build
```

### 2) コントラクトのバイトコード生成（creation bytecode）
```bash
mkdir -p /tmp/out
solc --bin references/chapter9/contract/SimpleAdder.sol -o /tmp/out --overwrite
# 生成物: /tmp/out/Adder.bin
```

### 3) 関数セレクタと引数エンコード（add(uint256,uint256) の例: 2 + 3）
```bash
SEL=$(solc --hashes references/chapter9/contract/SimpleAdder.sol | awk '/add\(uint256,uint256\)/{print $1}' | sed 's/://')
A=$(printf "%064x" 2)
B=$(printf "%064x" 3)
DATA=0x${SEL}${A}${B}
echo "$DATA"  # 先頭0xで、4+64+64=132桁のHEX
```

### 4-A) 1プロセスでデプロイ→コールを実行（簡単）
```bash
zig build run -- \
  --listen 9000 \
  --deploy $(cat /tmp/out/Adder.bin) 0x000000000000000000000000000000000000abcd \
  --call   0x000000000000000000000000000000000000abcd "$DATA" \
  --gas 3000000 \
  --sender 0x000000000000000000000000000000000000dead
```
注: 現状 `--gas` は単一値のため、最後に指定した値が両方（deploy/call）に適用されます。困らないよう十分大きめにしてください（例: 3000000）。

### 4-B) 2プロセスで接続して実行（deploy と call のガスを分けたい場合）
ターミナル1（デプロイ側）:
```bash
zig build run -- \
  --listen 9000 \
  --deploy $(cat /tmp/out/Adder.bin) 0x000000000000000000000000000000000000abcd \
  --gas 3000000 \
  --sender 0x000000000000000000000000000000000000dead
```

ターミナル2（コール側）:
```bash
zig build run -- \
  --listen 9001 --connect 127.0.0.1:9000 \
  --call 0x000000000000000000000000000000000000abcd "$DATA" \
  --gas 100000 \
  --sender 0x000000000000000000000000000000000000dead
```

### 5) 期待される結果
- ログに `実行結果(hex): 0x...0005` と表示（u256=5）

### 四則演算の呼び出し例（Adder.sol）
- add(10,11): 上の作り方で `A=10, B=11` にして `--call` 実行
- sub(10,3):
  ```bash
  SEL=$(solc --hashes references/chapter9/contract/SimpleAdder.sol | awk '/sub\(uint256,uint256\)/{print $1}' | sed 's/://')
  A=$(printf "%064x" 10); B=$(printf "%064x" 3); DATA=0x${SEL}${A}${B}
  zig build run -- --listen 9001 --connect 127.0.0.1:9000 --call 0x000000000000000000000000000000000000abcd "$DATA" --gas 100000 --sender 0x000000000000000000000000000000000000dead
  # 期待: 結果=7
  ```
- mul(6,7):
  ```bash
  SEL=$(solc --hashes references/chapter9/contract/SimpleAdder.sol | awk '/mul\(uint256,uint256\)/{print $1}' | sed 's/://')
  A=$(printf "%064x" 6); B=$(printf "%064x" 7); DATA=0x${SEL}${A}${B}
  zig build run -- --listen 9001 --connect 127.0.0.1:9000 --call 0x000000000000000000000000000000000000abcd "$DATA" --gas 100000 --sender 0x000000000000000000000000000000000000dead
  # 期待: 結果=42
  ```
- div(100,4):
  ```bash
  SEL=$(solc --hashes references/chapter9/contract/SimpleAdder.sol | awk '/div\(uint256,uint256\)/{print $1}' | sed 's/://')
  A=$(printf "%064x" 100); B=$(printf "%064x" 4); DATA=0x${SEL}${A}${B}
  zig build run -- --listen 9001 --connect 127.0.0.1:9000 --call 0x000000000000000000000000000000000000abcd "$DATA" --gas 100000 --sender 0x000000000000000000000000000000000000dead
  # 期待: 結果=25
  ```

注意: `sub` は `b <= a` を前提に `require` でアンダーフローを防ぎ、`div` は 0 除算を `require` で拒否します。条件を満たさない場合は REVERT になります。

### トラブルシューティング
- hexToBytes の `InvalidCharacter` エラー: `--call` 直後の入力データHEXが空です。`echo "$DATA"` で値を確認してください。
- `コントラクトがローカルに見つかりません` と出る: 別プロセスで動かしている場合は `--connect` でピア接続して同期するか、4-A のように1プロセスで実行してください。

## 注意事項

これは学習用のプロジェクトです。実運用は想定していません。
