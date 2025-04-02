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

# プロジェクトの実行
zig run src/main.zig
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
