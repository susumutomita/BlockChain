# CLAUDE.md - プロジェクトガイドライン

## プロジェクト概要

このプロジェクトは、Zig言語を使用してブロックチェインを構築することを目的としています。
対応する本が出版され、Zigの学習とブロックチェイン技術の理解を深めることを目指しています。
[Zig言語で学ぶブロックチェイン](https://github.com/susumutomita/zenn-article/books/zig-blockchain)が対象となる本の原稿です。

## 開発環境とルール

### Zigのコーディング規約

- **エラーハンドリング**: `try`や`catch`を使用してエラーを適切に処理する。
- **コンパイル時の計算**: `comptime`を活用して効率的なコードを記述する。
- **命名規則**:
  - 変数名: `camelCase`（例: `calculateHash`）
  - 型名: `PascalCase`（例: `BlockHeader`）
  - 定数: `UPPER_SNAKE_CASE`（例: `MAX_BLOCK_SIZE`）

### ビルドとテスト

- **テストの実行**: `zig build test`
- **ビルド**: `zig build`
- **CI/CD**: GitHub Actionsを使用し、Zig 0.14.0で動作確認。

### ディレクトリ構成

- `src/`: ソースコード
  - `main.zig`: メインエントリポイント
  - `blockchain.zig`: ブロックチェーンのロジック
  - `evm.zig`: EVM（Ethereum Virtual Machine）の実装
  - `p2p.zig`: P2Pネットワークの実装
- `contract/`: Solidityのスマートコントラクト
- `references/`: [Zig言語で学ぶブロックチェイン](https://github.com/susumutomita/zenn-article/books/zig-blockchain)の各章で完成したコード、ステップバイステップで構築できるようにしてあります。
- `design/`: 設計資料

### EVMの詳細

- EVMの命令セットについては、`design/evm/opcodes.md`を参照。
- デバッグ用のファイル: `evm_debug.zig`と`p2p_debug.zig`

### Docker環境

- `docker-compose.yml`を使用してコンテナ化された環境を構築可能。
- テストやビルドもDocker内で実行可能。
