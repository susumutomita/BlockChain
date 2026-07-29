English | [Japanese](README.ja.md)

![GitHub last commit (by committer)](https://img.shields.io/github/last-commit/susumutomita/BlockChain)
![GitHub top language](https://img.shields.io/github/languages/top/susumutomita/BlockChain)
![GitHub pull requests](https://img.shields.io/github/issues-pr/susumutomita/BlockChain)
![GitHub code size in bytes](https://img.shields.io/github/languages/code-size/susumutomita/BlockChain)
![GitHub repo size](https://img.shields.io/github/repo-size/susumutomita/BlockChain)
[![Zig CI](https://github.com/susumutomita/BlockChain/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/susumutomita/BlockChain/actions/workflows/ci.yml)

# Zig Simple Blockchain

A small blockchain, TCP-based peer-to-peer network, and learning-oriented Ethereum Virtual Machine implemented in Zig.

This repository is the executable companion to the book [Zig言語で学ぶブロックチェイン](https://zenn.dev/bull/books/zig-blockchain). An English edition, *Build a Blockchain and a Minimal EVM from Scratch in Zig*, is being prepared in [zenn-article issue #287](https://github.com/susumutomita/zenn-article/issues/287).

The project is designed for learning. It makes block hashing, Proof of Work, validation, propagation, synchronization, bytecode execution, and failure handling visible through runnable checkpoints and tests.

## What is included

- block and transaction data structures
- SHA-256 block hashing
- learning-oriented Proof-of-Work mining
- block, link, and Proof-of-Work validation
- TCP message framing and peer connections
- P2P block propagation and relay
- multi-peer chain synchronization
- a minimal EVM with 256-bit values, stack, memory, storage, execution context, and selected opcodes
- Solidity contract compilation, deployment, and function calls
- chapter snapshots, companion patches, reconstruction gates, and real multi-node acceptance tests

## Version and reproducibility

The book and all checked-in chapter snapshots are pinned to Zig `0.14.0`.

Use the supplied Docker environment when you need reproducible results, especially on macOS 26 or when your installed Zig version is newer.

```bash
docker build --build-arg ZIG_VERSION=0.14.0 -t zig-blockchain-book .
docker run --rm zig-blockchain-book zig build test
```

With a local Zig `0.14.0` installation:

```bash
zig fmt --check .
zig build test
zig build
```

## Start a node

```bash
zig build run -- --listen 9000
```

Start a second node and connect it to the first:

```bash
zig build run -- --listen 9001 --connect 127.0.0.1:9000
```

## Repository layout

```text
src/                         Evolving completed implementation
contract/                    Solidity example contract
references/                  Self-contained chapter and section snapshots
references/book-patches/     Complete patches used by Chapters 11 and 12
scripts/verify-book-code.sh  Format, build, and test book checkpoints
scripts/rebuild-book-code.sh Reconstruct Chapters 11 and 12 and detect drift
```

The root `src/` may advance through bug fixes and improvements. Use `references/` when reproducing a specific point in the book. Do not copy the current root implementation into an early checkpoint, because it may contain types and behavior that the chapter has not introduced yet.

## Verify the book checkpoints

Run every supported chapter and section gate:

```bash
sh scripts/verify-book-code.sh
```

Rebuild Chapters 11 and 12 from their documented starting points and public companion patches:

```bash
sh scripts/rebuild-book-code.sh
```

Include the one-node and two-node TCP/EVM acceptance scenarios:

```bash
BOOK_REBUILD_ACCEPTANCE=1 sh scripts/rebuild-book-code.sh
```

Run the completed EVM snapshot acceptance directly:

```bash
sh references/EVMchapter/scripts/acceptance.sh .
```

CI also runs the chapter 6 request/acknowledgment scenario, chapter 7 block transfer and tamper rejection, chapter 8 three-node convergence, exact chapter reconstruction, and completed EVM acceptance.

## Deploy and call the `SimpleAdder` contract

### Prerequisites

- Zig `0.14.0`, or the Docker workflow above
- the Solidity compiler `solc`
- commands executed from the repository root

### 1. Build the node

```bash
zig build
```

### 2. Compile the contract creation bytecode

```bash
mkdir -p /tmp/out
solc --bin contract/SimpleAdder.sol -o /tmp/out --overwrite
# Output: /tmp/out/Adder.bin
```

### 3. Encode `add(uint256,uint256)` for `2 + 3`

```bash
SEL=$(solc --hashes contract/SimpleAdder.sol | awk '/add\(uint256,uint256\)/{print $1}' | sed 's/://')
A=$(printf "%064x" 2)
B=$(printf "%064x" 3)
DATA=0x${SEL}${A}${B}
echo "$DATA"
```

The calldata begins with `0x`, followed by the four-byte function selector and two 32-byte ABI words.

### 4. Deploy and call in one process

```bash
zig build run -- \
  --listen 9000 \
  --deploy "$(cat /tmp/out/Adder.bin)" 0x000000000000000000000000000000000000abcd \
  --call   0x000000000000000000000000000000000000abcd "$DATA" \
  --gas 3000000 \
  --sender 0x000000000000000000000000000000000000dead
```

The current CLI has one `--gas` value. The last value applies to both deployment and the call, so use a limit that is large enough for both operations.

### 5. Deploy and call across two connected processes

Terminal 1, deployment node:

```bash
zig build run -- \
  --listen 9000 \
  --deploy "$(cat /tmp/out/Adder.bin)" 0x000000000000000000000000000000000000abcd \
  --gas 3000000 \
  --sender 0x000000000000000000000000000000000000dead
```

Terminal 2, calling node:

```bash
zig build run -- \
  --listen 9001 --connect 127.0.0.1:9000 \
  --call 0x000000000000000000000000000000000000abcd "$DATA" \
  --gas 100000 \
  --sender 0x000000000000000000000000000000000000dead
```

The expected 32-byte result ends in `05`, and the decoded unsigned 256-bit value is `5`.

### Troubleshooting

- `hexToBytes` reports `InvalidCharacter`: The hexadecimal argument after `--call` is empty or malformed. Check `echo "$DATA"`.
- The node reports that the contract is not available locally: Connect the processes with `--connect` and allow the deployment to synchronize, or use the one-process example.

## Debug logging

Change `debug_logging` in `src/logger.zig`:

```zig
const debug_logging = true;  // Enable debug output
const debug_logging = false; // Disable debug output
```

## Security and compatibility boundary

This is not a production blockchain and is not an Ethereum-compatible client.

The current learning node validates block content, hashes, Proof of Work, height, parent links, selected network frames, and the EVM subset used by the examples. It intentionally does not provide the complete security and consensus model required by a real public network.

Notable non-goals include:

- transaction signatures and authenticated sender derivation
- account nonces and replay protection
- balances and a complete deterministic account state transition
- cumulative-work fork choice and robust reorganization handling
- finality
- persistent chain and consensus state
- authenticated or encrypted peer transport
- complete EVM opcode, gas, precompile, and Ethereum state semantics

Do not use this project to hold assets, execute untrusted contracts, or operate a production network.

## Learning goals

The repository is intended to make the following concepts concrete:

1. Blockchain structure
   - hash-linked blocks
   - transactions and block contents
   - mining and validation
2. Distributed systems
   - TCP framing
   - peer discovery boundaries
   - propagation, relay, duplicate rejection, and synchronization
3. Zig systems programming
   - structs and modules
   - explicit allocation and ownership
   - error handling
   - concurrency and shared state
   - testing and build tooling
4. Virtual machines
   - 256-bit values
   - stack, memory, and storage
   - bytecode decoding and execution
   - Solidity ABI calldata

## Roadmap

- [ ] persistent blockchain storage
- [x] learning-oriented P2P networking
- [ ] transaction authentication and replay protection
- [ ] explicit consensus engine and fork-choice abstraction
- [ ] Web API
- [ ] learning-oriented wallet and key flow
- [ ] migration of the book and checkpoints to a newer Zig edition

## Contributing

Issues and pull requests are welcome.

1. Fork the repository.
2. Create a focused branch.
3. Add or update the nearest tests.
4. Run the relevant chapter and root gates.
5. Open a pull request that explains the behavior and learning impact.

Changes to a book checkpoint should keep the manuscript, snapshot, companion patch, and reconstruction gate aligned.

## License

MIT License
