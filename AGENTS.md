# Repository Guidelines

これはZigで作るブロックチェーンのリポジトリです。


## Project Structure & Module Organization
- `src/`: Zig sources — core modules (`blockchain.zig`, `p2p.zig`, `evm.zig`, `types.zig`), app entry (`main.zig`), library root/tests (`root.zig`).
- `docs/`: Generated artifacts for docs/demo (HTML/JS/WASM).
- `contract/`: Example Solidity contracts used in EVM experiments.
- `design/`, `references/`: Design notes and learning materials.
- `zig-out/`: Build outputs; do not commit artifacts.
- `.github/workflows/`: CI for Zig build/tests and code review aides.

## Build, Test, and Development Commands
- Build: `zig build` — compiles library and executable.
- Run: `zig build run -- --listen 8000 [--connect host:port]` — starts a node.
- Tests: `zig build test` — runs inline Zig tests (CI uses Zig 0.14.0).
- Format: `zig fmt .` (or `zig fmt --check .` in CI/pre-commit).
- Docker (optional): `docker compose up -d` then `docker exec -it node2 sh` to interact. If you change binary name/flags, update `docker-compose.yml` accordingly.
 - Enable hooks: `git config core.hooksPath .githooks` (pre-commit enforces `zig fmt --check`).

## `references/` = 書籍の章・段階別「正解コード」（重要）
このリポジトリは書籍「Zig言語で学ぶブロックチェイン」(別リポジトリ `zenn-article/books/zig-blockchain`) と対になっており、`references/` に各章・各段階の完成コードが入っています。エージェントは作業前にこの対応を理解すること。

- 構成: `chapter2/ chapter3/(step1-5) chapter4/(step1-3) chapter5/ chapter6/(step1-2, nodeA/nodeB) chapter7/ chapter8/ chapter9/ EVMchapter/`。各ディレクトリは**自己完結**で `build.zig` を持ち、多くが専用の `Dockerfile`/`docker-compose.yml` 付き（`CMD ["zig","build","run"]`）。
- `EVMchapter/src/` は最終 `src/` と**ほぼ同一**（EVM章＝書籍 ch9-14 の正解は最終 src と同じ）。
- `references/books/` は本の**旧ドラフト**（`chapter9_new.md` 等）。権威は `zenn-article/books/zig-blockchain/`。
- **章番号はオフセットする**: 参照の番号は書籍の章番号と一致しない（例: `references/chapter3/step4`・`step4-2` が書籍 ch4 の2ブロックに対応、`references/chapter5` が書籍 ch5）。対応は各 `main.zig` の genesis(data/transactions/difficulty) と書籍のログを突き合わせて確定すること。
- 難易度は `mineBlock(&block, N)` の N（先頭 N バイトが 0 になるまで採掘）。書籍本文の「先頭 N バイト00」と一致させる。

### 書籍のログを実出力に再生成する手順
1. 対象章の参照でハッシュ表示が `{x}` なら `{x:0>2}` に直す（`{x}` は0埋めされず64桁未満になる）。
2. docker で決定的な実値を得る（ホストの `.zig-cache` 混入を避けるためマウント無しで）:
   `cd references/chapterX[/stepY] && docker build -t t . && docker run --rm t`
3. 出力の `Nonce`/`Hash`/`Timestamp` を書籍の該当ログにそのまま反映（手でパディングしない）。

## macOS でのビルド注意（zig 0.14.0）
- macOS 26 系ではネイティブの `zig build`/`zig test` が libSystem スタブ未対応でリンク失敗する。回避は OS バージョンを完全指定でピン: `zig test src/<file>.zig -target aarch64-macos.15.0.0`（生成物は macOS 26 でも実行可）。
- `zig build` はビルドランナー自体が native リンクのため当該環境では不可 → **docker（Alpine, linux/amd64）を使う**。
- 補足: ルート`build.zig`は全13個の`src/*.zig`を個別のテストルートとして登録する。CIの`zig build test`はEVM、P2P、型のファイル内テストも実行する。macOSで単一ファイルを確認する場合は`zig test src/<file>.zig -target aarch64-macos.15.0.0`を使う。

## Coding Style & Naming Conventions
- Formatter: Always run `zig fmt` before committing.
- Indentation: 4 spaces; no tabs.
- Names: Types `PascalCase`; functions/variables/file names `snake_case` (matches current codebase).
- Modules: Keep focused responsibilities; prefer small, composable helpers in `utils.zig`.

## Testing Guidelines
- Use Zig’s built-in tests: `test "description" { ... }` near the code they cover.
- Aggregation: `src/root.zig` pulls tests via `std.testing.refAllDeclsRecursive`.
- Scope: Add tests for new EVM opcodes, P2P message handlers, and blockchain rules (PoW, validation).
- Run locally with `zig build test`; ensure determinism (no network/time dependencies in unit tests).

## Commit & Pull Request Guidelines
- Commits: Short, imperative subject; include scope (e.g., `evm:`), reference issues (`#123`). Existing history sometimes uses emoji/JP tags — either is fine if consistent.
- PRs: Describe what/why, link issues, include CLI logs or screenshots for behavioral changes, note config updates (ports/flags). Require green CI and formatting clean.

## Security & Configuration Tips
- Education-only code; do not expose nodes to untrusted networks or handle real assets.
- Validate CLI inputs; avoid panics in network paths; log clearly via `std.log`.
- If changing ports/flags, update `README.md` and examples.
