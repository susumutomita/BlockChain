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
