# CLAUDE.md - プロジェクトガイドライン

## プロジェクト概要

このプロジェクトは、Zig言語を使用してブロックチェインを構築することを目的としています。
対応する本が出版され、Zigの学習とブロックチェイン技術の理解を深めることを目指しています。
[Zig言語で学ぶブロックチェイン](https://github.com/susumutomita/zenn-article/books/zig-blockchain)が対象となる本の原稿です。
本と、対応するコードが矛盾なく、初学者にわかりやすく書くことが目標です。
出力は日本語で行ってください。

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
- `references/`: [Zig言語で学ぶブロックチェイン](https://github.com/susumutomita/zenn-article/books/zig-blockchain)の各章で完成したコード、ステップバイステップで構築できるようにしてあります。各Chapeter事に対応するコードが格納されています。また本の原稿もbooksディレクトリにコピーしてあります。例えばreferences/books/chapter9.mdに対応するコードが`references/chapter9/`に格納されています。また本の目的は、Zig言語でブロックチェインをゼロから作り上げる過程を通じてその仕組みへの理解を深め、最終的にEVM互換のチェインを自分で動かせるようになることです。堅苦しい教科書ではなく、手を動かしながら学べる工作キットのような感覚で楽しんでもらうです。
- `design/`: 設計資料

### EVMの詳細

- EVMの命令セットについては、`design/evm/opcodes.md`を参照。
- デバッグ用のファイル: `evm_debug.zig`と`p2p_debug.zig`

### Docker環境

- `docker-compose.yml`を使用してコンテナ化された環境を構築可能。
- テストやビルドもDocker内で実行可能。

# Claude Code Spec-Driven Development

This project implements Kiro-style Spec-Driven Development for Claude Code using hooks and slash commands.

## Project Context

### Project Steering
- Product overview: `.kiro/steering/product.md`
- Technology stack: `.kiro/steering/tech.md`
- Project structure: `.kiro/steering/structure.md`
- Custom steering docs for specialized contexts

### Active Specifications
- Current spec: Check `.kiro/specs/` for active specifications
- Use `/spec-status [feature-name]` to check progress

## Development Guidelines
- Think in English, but generate responses in Japanese (思考は英語、回答の生成は日本語で行うように)

## Spec-Driven Development Workflow

### Phase 0: Steering Generation (Recommended)

#### Kiro Steering (`.kiro/steering/`)
```
/steering-init          # Generate initial steering documents
/steering-update        # Update steering after changes
/steering-custom        # Create custom steering for specialized contexts
```

**Note**: For new features or empty projects, steering is recommended but not required. You can proceed directly to spec-requirements if needed.

### Phase 1: Specification Creation
```
/spec-init [feature-name]           # Initialize spec structure only
/spec-requirements [feature-name]   # Generate requirements → Review → Edit if needed
/spec-design [feature-name]         # Generate technical design → Review → Edit if needed
/spec-tasks [feature-name]          # Generate implementation tasks → Review → Edit if needed
```

### Phase 2: Progress Tracking
```
/spec-status [feature-name]         # Check current progress and phases
```

## Spec-Driven Development Workflow

Kiro's spec-driven development follows a strict **3-phase approval workflow**:

### Phase 1: Requirements Generation & Approval
1. **Generate**: `/spec-requirements [feature-name]` - Generate requirements document
2. **Review**: Human reviews `requirements.md` and edits if needed
3. **Approve**: Manually update `spec.json` to set `"requirements": true`

### Phase 2: Design Generation & Approval
1. **Generate**: `/spec-design [feature-name]` - Generate technical design (requires requirements approval)
2. **Review**: Human reviews `design.md` and edits if needed
3. **Approve**: Manually update `spec.json` to set `"design": true`

### Phase 3: Tasks Generation & Approval
1. **Generate**: `/spec-tasks [feature-name]` - Generate implementation tasks (requires design approval)
2. **Review**: Human reviews `tasks.md` and edits if needed
3. **Approve**: Manually update `spec.json` to set `"tasks": true`

### Implementation
Only after all three phases are approved can implementation begin.

**Key Principle**: Each phase requires explicit human approval before proceeding to the next phase, ensuring quality and accuracy throughout the development process.

## Development Rules

1. **Consider steering**: Run `/steering-init` before major development (optional for new features)
2. **Follow the 3-phase approval workflow**: Requirements → Design → Tasks → Implementation
3. **Manual approval required**: Each phase must be explicitly approved by human review
4. **No skipping phases**: Design requires approved requirements; Tasks require approved design
5. **Update task status**: Mark tasks as completed when working on them
6. **Keep steering current**: Run `/steering-update` after significant changes
7. **Check spec compliance**: Use `/spec-status` to verify alignment

## Automation

This project uses Claude Code hooks to:
- Automatically track task progress in tasks.md
- Check spec compliance
- Preserve context during compaction
- Detect steering drift

### Task Progress Tracking

When working on implementation:
1. **Manual tracking**: Update tasks.md checkboxes manually as you complete tasks
2. **Progress monitoring**: Use `/spec-status` to view current completion status
3. **TodoWrite integration**: Use TodoWrite tool to track active work items
4. **Status visibility**: Checkbox parsing shows completion percentage

## Getting Started

1. Initialize steering documents: `/steering-init`
2. Create your first spec: `/spec-init [your-feature-name]`
3. Follow the workflow through requirements, design, and tasks

## Kiro Steering Details

Kiro-style steering provides persistent project knowledge through markdown files:

### Core Steering Documents
- **product.md**: Product overview, features, use cases, value proposition
- **tech.md**: Architecture, tech stack, dev environment, commands, ports
- **structure.md**: Directory organization, code patterns, naming conventions

### Custom Steering
Create specialized steering documents for:
- API standards
- Testing approaches
- Code style guidelines
- Security policies
- Database conventions
- Performance standards
- Deployment workflows

### Inclusion Modes
- **Always Included**: Loaded in every interaction (default)
- **Conditional**: Loaded for specific file patterns (e.g., `"*.test.js"`)
- **Manual**: Loaded on-demand with `#filename` reference
