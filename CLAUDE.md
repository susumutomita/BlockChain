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

### スマートコントラクトの動作確認について

次の3つのノードを立ち上げて、スマートコントラクトのデプロイと呼び出しを行います。

1. **ノード1**: ブロックチェーンのメインノード（ポート8000）
2. **ノード2**: スマートコントラクトのデプロイ用ノード（ポート8006）
3. **ノード3**: スマートコントラクトの呼び出し用ノード（ポート8003）

### スマートコントラクトのデプロイと呼び出し手順

以下のコマンドを順に実行します。

```bash
ノードの立ち上げ
zig build run -- --listen 8000
```

コントラクトのデプロイ

```bash
zig build run -- --listen 8006 --connect 127.0.0.1:8000 --deploy 6080604052348015600e575f80fd5b50606a80601a5f395ff3fe608060405260443610156010575f80fd5b5f3560e01c63771602f78103603057600435602435808201805f5260205ff35b5f80fdfea264697066735822122026f5e42c5ea9894eee19e05ade3a83d3703cc18538a07f258df3d93eabd2896764736f6c63430008180033 0x1234 --gas 1000000
```

コントラクトの呼び出し

```bash
zig build run -- --listen 8003 --connect 127.0.0.1:8001 --call 0x123456 771602f70000000000000000000000000000000000000000000000000000000000000001\
0000000000000000000000000000000000000000000000000000000000000005 --gas 1000000
```

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
