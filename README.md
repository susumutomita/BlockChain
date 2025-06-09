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
- P2Pネットワーク
- EVMスマートコントラクト実行

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

# プロジェクトの実行
zig run src/main.zig

# P2Pノードとして起動
zig build run -- --listen 8000
```

## スマートコントラクトのデプロイと実行

### 1. ノードの起動

3つのターミナルで以下のコマンドを実行します：

```bash
# ターミナル1: メインノード
zig build run -- --listen 8000

# ターミナル2: デプロイ用ノード
zig build run -- --listen 8001 --connect 127.0.0.1:8000

# ターミナル3: 呼び出し用ノード
zig build run -- --listen 8003 --connect 127.0.0.1:8000
```

### 2. スマートコントラクトのデプロイ

ターミナル2で以下のコマンドを実行：

```bash
# SimpleAdderコントラクトのデプロイ
zig build run -- --listen 8001 --connect 127.0.0.1:8000 --deploy 608060405234801561000f575f80fd5b506101a58061001d5f395ff3fe608060405234801561000f575f80fd5b5060043610610029575f3560e01c8063771602f71461002d575b5f80fd5b610047600480360381019061004291906100a9565b61005d565b60405161005491906100f6565b60405180910390f35b5f818361006a919061013c565b905092915050565b5f80fd5b5f819050919050565b61008881610076565b8114610092575f80fd5b50565b5f813590506100a38161007f565b92915050565b5f80604083850312156100bf576100be610072565b5b5f6100cc85828601610095565b92505060206100dd85828601610095565b9150509250929050565b6100f081610076565b82525050565b5f6020820190506101095f8301846100e7565b92915050565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52601160045260245ffd5b5f61014682610076565b915061015183610076565b92508282019050808211156101695761016861010f565b5b9291505056fea2646970667358221220a68ac5dd9c327ed13acd5c40d704310b02e930dac14bde8af9ca1738f4a0dad864736f6c63430008180033 0x1234 --gas 1000000
```

### 3. スマートコントラクトの呼び出し

ターミナル3で以下のコマンドを実行：

```bash
# add関数を呼び出し（1 + 5を計算）
zig build run -- --listen 8003 --connect 127.0.0.1:8000 --call 0x1234 771602f700000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000005 --gas 1000000
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

## テスト実行とカバレッジ測定

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

## 注意事項

これは学習用のプロジェクトです。
実際の運用環境での使用は想定していません。
