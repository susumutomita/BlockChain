---
title: "Zigで簡易EVMバイトコードエンジンを実装する"
free: true
---

## Zigで簡易EVMバイトコードエンジンを実装し、Solidityスマートコントラクトを実行する

この章では、**Zig**プログラミング言語を用いてEthereum Virtual Machine (EVM)を実装します。

**目標:**

- EVMの基本構造（スタック・メモリ・ストレージ）を理解する
- Zigでスタックベースの仮想マシンを構築する
- 実際のSolidityコントラクトを実行する

## EVMとは

Ethereumブロックチェイン上でスマートコントラクトを実行するための仮想マシンです。イーサリアムの各ノードはEVMを内部に持ち、ブロック内の取引に含まれるスマートコントラクトのコードをEVM上で実行することで、結果として世界状態（ワールドステート）を更新します。EVMは256ビット長のWord（32バイト）を基本単位とする**スタックマシン**であり、プログラム（バイトコード）を順次読み取り実行していきます。スマートコントラクトのコードは**バイトコード**（機械語に相当）でブロックチェイン上に保存され、EVMがこれを解釈・実行します。

```mermaid
graph TD
    subgraph "EVMの構造"
        PC[プログラムカウンタ<br/>PC]
        Code[バイトコード<br/>0x60 0x80...]
        Stack[スタック<br/>LIFO構造<br/>最大1024要素]
        Memory[メモリ<br/>一時的な領域]
        Storage[ストレージ<br/>永続的な領域]
        Gas[ガスカウンタ]
    end
    
    Code -->|命令読み込み| PC
    PC -->|オペコード実行| Stack
    Stack <--> Memory
    Stack <--> Storage
    PC --> Gas
    
    style Stack fill:#f9f,stroke:#333,stroke-width:2px
    style Storage fill:#9ff,stroke:#333,stroke-width:2px
```

EVMには、実行時に使用されるいくつかの主要なデータ領域があります。[Ethereum Yellow Paper](https://ethereum.github.io/yellowpaper/paper.pdf)。

- **ストレージ (Storage)**: 各コントラクト（アカウント）に紐づく永続的な**キー値ストア**です。256ビットのキーと値のマッピングで表現され、トランザクション間で保存されます ([スマートコントラクトの紹介](https://docs.soliditylang.org/ja/latest/introduction-to-smart-contracts.html#))。コントラクトの状態変数はこのストレージに格納され、ブロックチェイン上の状態の一部として永続化されます。ストレージへの書き込み・読み出しはガスコストが高く、他のコントラクトのストレージには直接アクセスできません。

- **メモリ (Memory)**: コントラクト実行中のみ有効な一時的なメモリ空間です。呼び出しごとにリセットされ、バイトアドレスでアクセス可能な1次元の配列として扱われます。読み書きは基本的に32バイト幅単位で行われ、必要に応じて末尾に向かって拡張されます（拡張にはガスコストが伴います）。計算中の一時データや後述する戻り値の一時格納に利用されます。

- **スタック (Stack)**: EVMの算術演算やオペコードのオペランド受け渡しに使われるLIFOスタックです。最大で1024要素の深さがあり、各要素は256ビットの値です。EVMはレジスタを持たず、全ての計算はスタック上で行われます。通常、オペコードはスタックの最上位要素（トップ）から必要な数の項目をPOPし、計算結果を再びスタックにPUSHします。スタックの深い位置に直接アクセスはできず、`DUP`（トップ16個までの要素を複製）や`SWAP`（トップと下位の一部を交換）命令で間接的に操作します。スタックオーバーフロー（積みすぎ）やスタックアンダーフローは実行失敗を招きます。

上記の他にも、**プログラムカウンタ (PC)** や**ガス (Gas)** といった要素があります。プログラムカウンタは現在実行中のバイトコードの位置を指し示すものです。EVMは**命令ポインタ**であるPCを開始時に0とセットし、各オペコードの実行後に進めていきます。条件付きジャンプ命令などによりPCを書き換えることで、ループや条件分岐も実現します。

**ガス**とは、EVM上でコードを実行する際に必要となる手数料単位です。各オペコード毎に「この命令で必要なガス量」が定められています。また、スマートコントラクトを呼び出すトランザクションには上限となるガス量（ガスリミット）が指定されます。EVMは命令のたびに消費ガスを積算し、ガスリミットを超えると**アウトオブガス**となり実行が停止（通常は巻き戻し）されます。ガスは無限ループや過度な計算を防ぐ仕組みです。

EVMの命令（オペコード）は1バイト長で表現され、例えば`0x01`はADD（加算）、`0x60`はPUSH（スタックへ即値を積む）といったように定義されています。スマートコントラクトのバイトコード実行は常にコードの先頭（PC=0）から開始され、`STOP (0x00)`命令に到達するか実行が中断されるまで、命令を順次取り出して解釈・実行していきます。PUSH系命令だけは直後のバイト列をオペランド（値）として持つため可変長ですが、その他の命令は固定1バイトで、スタックから値を取り出し結果をスタックに戻すという挙動をとります。

以上がEVMの基本的な仕組みです。Ethereumクライアント（例：GethやNethermindなど）には各々EVM実装が内蔵されていますが、全てEthereumの公式仕様（イエローペーパー）に従う必要があります。このチュートリアルでは、このEVMの一部機能をZigで再現し、簡単なスマートコントラクトのバイトコードを実行してみます。

### EVMオペコードの例

EVMで使用される主要なオペコードをいくつか見てみましょう：

```
オペコード | 値   | 説明                          | スタック変化
---------|------|-------------------------------|----------------
STOP     | 0x00 | 実行を停止                      | 
ADD      | 0x01 | 2つの値を加算                   | a, b → (a+b)
MUL      | 0x02 | 2つの値を乗算                   | a, b → (a*b)
PUSH1    | 0x60 | 1バイトをスタックにプッシュ      | → value
DUP1     | 0x80 | スタックトップを複製            | a → a, a
SWAP1    | 0x90 | スタックの上位2つを入れ替え      | a, b → b, a
MSTORE   | 0x52 | メモリに32バイト保存            | offset, value →
SSTORE   | 0x55 | ストレージに保存                | key, value →
RETURN   | 0xF3 | 値を返して終了                  | offset, length →
```

## ZigでEVMを実装する準備

開発環境の準備をします。

**Solidityコンパイラの準備:** Solidityのスマートコントラクトをバイトコードにコンパイルできるように、Solidity公式のコマンドラインコンパイラ`solc`を用意します。Solidityの開発環境が既にある場合はsolcコマンドが使えるはずです。インストールされていない場合、Ethereum公式サイトや各種ドキュメントに従ってインストールしてください（例：macOSならHomebrewで`brew install solidity`）。

Solidityコンパイラ`solc`を使うと、Solidityコードから各種出力を得ることができます ([Using the Compiler](https://docs.soliditylang.org/en/latest/using-the-compiler.html))。バイトコード（EVMが実行するバイナリ）を取得するには、以下のように`--bin`オプションを指定します。

まず、コンパイルするSolidityコードを用意します。以下のような簡単なコントラクトを`contract/SimpleAdder.sol`というファイル名で保存します。

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Adder {
    function add(uint256 a, uint256 b) public pure returns (uint256) {
        return a + b;
    }
}
```

次に、コントラクトをコンパイルしてバイトコードを取得します。以下のコマンドを実行してください。

```bash
solc --bin --abi contract/SimpleAdder.sol
```

それぞれのオプションの意味は以下の通りです。

- `--bin`: バイトコードを出力します。
- `--abi`: コントラクトのABI（Application Binary Interface）を出力します。ABIはコントラクトの関数やイベントのインタフェースを定義したものです。

上記コマンドを実行すると、コンパイル結果としてバイトコードとABI（Application Binary Interface）が表示されます。バイトコードは`0x`で始まる16進数の文字列で、EVMが実行する命令列です。
ABIは、コントラクトの関数やイベントのインタフェースを定義したものです。ABIは、コントラクトの関数を呼び出す際に必要な情報を提供します。具体的には、関数名、引数の型、戻り値の型などが含まれます。
EVMアセンブリコードは、EVMが実行する命令の一覧を示しています。これにより、EVMがどのようにバイトコードを解釈しているかを理解する手助けになります。

```bash
solc --bin  --abi contract/SimpleAdder.sol

======= contract/SimpleAdder.sol:Adder =======
Binary:
608060405234801561000f575f80fd5b506101a58061001d5f395ff3fe608060405234801561000f575f80fd5b5060043610610029575f3560e01c8063771602f71461002d575b5f80fd5b610047600480360381019061004291906100a9565b61005d565b60405161005491906100f6565b60405180910390f35b5f818361006a919061013c565b905092915050565b5f80fd5b5f819050919050565b61008881610076565b8114610092575f80fd5b50565b5f813590506100a38161007f565b92915050565b5f80604083850312156100bf576100be610072565b5b5f6100cc85828601610095565b92505060206100dd85828601610095565b9150509250929050565b6100f081610076565b82525050565b5f6020820190506101095f8301846100e7565b92915050565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52601160045260245ffd5b5f61014682610076565b915061015183610076565b92508282019050808211156101695761016861010f565b5b9291505056fea2646970667358221220e478f9e62b837b6d95fa3abbc3c7eb6c02d17eb28b14607d07eb892ef9992db964736f6c63430008180033
Contract JSON ABI
[{"inputs":[{"internalType":"uint256","name":"a","type":"uint256"},{"internalType":"uint256","name":"b","type":"uint256"}],"name":"add","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"pure","type":"function"}]
```

`-o`オプションで出力先ディレクトリを指定すれば、コンパイル結果をファイルとして保存も可能です。

## 簡易EVMの実装

それでは、ZigでEVMのコアとなるバイトコード実行エンジンを実装してみましょう。EVMはスタックマシンですので、スタックやメモリ、ストレージを管理しつつ、バイトコード中のオペコードを読み取って解釈・実行するループを作ることになります。

### データ構造の定義

まず、EVMの実行に必要なデータを用意します。スタック、メモリ、ストレージ、プログラムカウンタ、ガスなどです。今回は各コンポーネントを明確に分離し、オブジェクト指向的な設計で実装します。

- **256ビット整数型 (u256)**: EVMの基本データ型です。Zigには組み込みの256ビット整数型がないため、2つの128ビット整数（上位128ビットと下位128ビット）を組み合わせた独自の構造体として実装します。加算・減算などの演算メソッドも提供します。
- **スタック (EvmStack)**: 固定長配列（サイズ1024）で表現し、各要素を`u256`型とします。スタックポインタ（現在のスタック高さ）を別途管理し、プッシュ/ポップ操作を提供します。
- **メモリ (EvmMemory)**: 動的に拡張可能な`std.ArrayList(u8)`で表現します。32バイト単位でデータを読み書きするメソッドを提供し、必要に応じてサイズを拡張します。
- **ストレージ (EvmStorage)**: コントラクトの永続的なキー/値ストアです。シンプルな実装として、`std.AutoHashMap(u256, u256)`を使用し、キーと値の組を保持します。
- **実行コンテキスト (EvmContext)**: 上記のコンポーネントをまとめ、プログラムカウンタ、残りガス量、実行中のコード、呼び出しデータなどを含む実行環境を表現します。
- **プログラムカウンタ (PC)**: 現在の命令位置を示すインデックスです。`usize`型（符号なしサイズ型）で0からバイトコード長-1まで動きます。
- **ガス**: 残り実行可能ガスを示すカウンタです。`usize`または十分大きい整数型で扱います。処理するごとに各命令のガス消費量を差し引き、0未満になったらアウトオブガスです。
- **その他**: 戻り値を格納する一時バッファや、実行終了フラグなどもあると便利です。例えば`RETURN`命令があった場合に、どのデータを返すかを記録しておきます。

では、これらを踏まえてZigコードを書いていきます。

まず、Zigプロジェクトのディレクトリ構成を整理します。

```
src/
  main.zig       # メインプログラム
  evm.zig        # EVM実行エンジン
  evm_types.zig  # EVMで使用する型定義
  evm_debug.zig  # デバッグ用の表示関数
```

### `evm_types.zig` - 型定義

```zig
//! EVM型定義モジュール
//! EVMで使用する基本的なデータ型を定義します。

const std = @import("std");
const crypto = std.crypto.hash;
const Keccak256 = crypto.sha3.Keccak256;

/// EVM用の256ビット整数型
/// EVMは256ビット長のWordを基本単位とするため、この型を使用します。
pub const EVMu256 = struct {
    hi: u128, // 上位128ビット
    lo: u128, // 下位128ビット

    /// ゼロ値を返す
    pub fn zero() EVMu256 {
        return EVMu256{ .hi = 0, .lo = 0 };
    }

    /// 64ビット整数から変換
    pub fn fromU64(value: u64) EVMu256 {
        return EVMu256{ .hi = 0, .lo = value };
    }

    /// 加算
    pub fn add(self: EVMu256, other: EVMu256) EVMu256 {
        const result_lo = self.lo +% other.lo;
        const carry = if (result_lo < self.lo) 1 else 0;
        const result_hi = self.hi +% other.hi +% carry;
        return EVMu256{ .hi = result_hi, .lo = result_lo };
    }

    /// 乗算（簡易版）
    pub fn mul(self: EVMu256, other: EVMu256) EVMu256 {
        // 完全な256ビット乗算は複雑なため、簡易版として実装
        // 両方の上位ビットが0の場合のみ正確
        if (self.hi == 0 and other.hi == 0) {
            const result = @as(u256, self.lo) * @as(u256, other.lo);
            return EVMu256{
                .hi = @truncate(result >> 128),
                .lo = @truncate(result),
            };
        }
        // それ以外は簡易的に処理
        return EVMu256{
            .hi = 0,
            .lo = self.lo *% other.lo,
        };
    }

    /// バイト配列への変換（ビッグエンディアン）
    pub fn toBytes(self: EVMu256) [32]u8 {
        var bytes: [32]u8 = undefined;
        // 上位128ビットをバイト配列に変換
        for (0..16) |i| {
            bytes[i] = @truncate((self.hi >> @as(u7, @intCast((15 - i) * 8))));
        }
        // 下位128ビットをバイト配列に変換
        for (0..16) |i| {
            bytes[i + 16] = @truncate((self.lo >> @as(u7, @intCast((15 - i) * 8))));
        }
        return bytes;
    }

    /// バイト配列からの変換（ビッグエンディアン）
    pub fn fromBytes(bytes: []const u8) EVMu256 {
        var hi: u128 = 0;
        var lo: u128 = 0;

        const len = @min(bytes.len, 32);
        const offset = if (len < 32) 32 - len else 0;

        for (bytes, 0..) |byte, i| {
            const pos = offset + i;
            if (pos < 16) {
                hi |= @as(u128, byte) << @as(u7, @intCast((15 - pos) * 8));
            } else if (pos < 32) {
                lo |= @as(u128, byte) << @as(u7, @intCast((31 - pos) * 8));
            }
        }

        return EVMu256{ .hi = hi, .lo = lo };
    }
};

/// EVMアドレス（20バイト）
pub const EVMAddress = struct {
    data: [20]u8,

    pub fn zero() EVMAddress {
        return EVMAddress{ .data = [_]u8{0} ** 20 };
    }

    pub fn fromHexString(hex: []const u8) !EVMAddress {
        var addr = EVMAddress.zero();
        const start_idx = if (std.mem.startsWith(u8, hex, "0x")) 2 else 0;
        const hex_data = hex[start_idx..];

        if (hex_data.len != 40) return error.InvalidAddressLength;

        for (0..20) |i| {
            const byte_str = hex_data[i * 2 .. (i + 1) * 2];
            addr.data[i] = try std.fmt.parseInt(u8, byte_str, 16);
        }

        return addr;
    }
};

/// EVMスタック（最大1024要素）
pub const EvmStack = struct {
    data: [1024]EVMu256,
    top: usize,

    pub fn init() EvmStack {
        return EvmStack{
            .data = undefined,
            .top = 0,
        };
    }

    pub fn push(self: *EvmStack, value: EVMu256) !void {
        if (self.top >= 1024) return error.StackOverflow;
        self.data[self.top] = value;
        self.top += 1;
    }

    pub fn pop(self: *EvmStack) !EVMu256 {
        if (self.top == 0) return error.StackUnderflow;
        self.top -= 1;
        return self.data[self.top];
    }

    pub fn depth(self: *const EvmStack) usize {
        return self.top;
    }
};

/// EVMメモリ（動的拡張可能）
pub const EvmMemory = struct {
    data: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) EvmMemory {
        return EvmMemory{
            .data = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *EvmMemory) void {
        self.data.deinit();
    }

    pub fn store(self: *EvmMemory, offset: usize, value: EVMu256) !void {
        const end_offset = offset + 32;
        
        // メモリを必要に応じて拡張
        if (end_offset > self.data.items.len) {
            try self.data.resize(end_offset);
        }

        const bytes = value.toBytes();
        @memcpy(self.data.items[offset..end_offset], &bytes);
    }

    pub fn load(self: *const EvmMemory, offset: usize) EVMu256 {
        const end_offset = offset + 32;
        
        if (end_offset <= self.data.items.len) {
            return EVMu256.fromBytes(self.data.items[offset..end_offset]);
        } else {
            // 範囲外の場合は0を返す
            return EVMu256.zero();
        }
    }
};

/// EVMストレージ（永続的なキー・値ストア）
pub const EvmStorage = struct {
    data: std.AutoHashMap(EVMu256, EVMu256),

    pub fn init(allocator: std.mem.Allocator) EvmStorage {
        return EvmStorage{
            .data = std.AutoHashMap(EVMu256, EVMu256).init(allocator),
        };
    }

    pub fn deinit(self: *EvmStorage) void {
        self.data.deinit();
    }

    pub fn store(self: *EvmStorage, key: EVMu256, value: EVMu256) !void {
        try self.data.put(key, value);
    }

    pub fn load(self: *const EvmStorage, key: EVMu256) EVMu256 {
        return self.data.get(key) orelse EVMu256.zero();
    }
};

/// EVM実行コンテキスト
pub const EvmContext = struct {
    stack: EvmStack,
    memory: EvmMemory,
    storage: EvmStorage,
    pc: usize,                      // プログラムカウンタ
    code: []const u8,               // 実行するバイトコード
    calldata: []const u8,           // 呼び出しデータ
    gas_remaining: usize,           // 残りガス
    return_data: ?[]const u8,       // 戻り値データ
    stopped: bool,                  // 実行停止フラグ
    reverted: bool,                 // リバートフラグ
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, code: []const u8, calldata: []const u8, gas_limit: usize) EvmContext {
        return EvmContext{
            .stack = EvmStack.init(),
            .memory = EvmMemory.init(allocator),
            .storage = EvmStorage.init(allocator),
            .pc = 0,
            .code = code,
            .calldata = calldata,
            .gas_remaining = gas_limit,
            .return_data = null,
            .stopped = false,
            .reverted = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EvmContext) void {
        self.memory.deinit();
        self.storage.deinit();
    }
};
```

### `evm.zig` - EVM実行エンジン

```zig
//! Ethereum Virtual Machine (EVM) 実装
//!
//! このモジュールはEthereumのスマートコントラクト実行環境であるEVMを
//! 簡易的に実装します。EVMバイトコードを解析・実行し、スタックベースの
//! 仮想マシンとして動作します。

const std = @import("std");
const logger = @import("logger.zig");
const evm_types = @import("evm_types.zig");
const evm_debug = @import("evm_debug.zig");
// u256型を別名で使用して衝突を回避
const EVMu256 = evm_types.EVMu256;
const EvmContext = evm_types.EvmContext;

/// EVMオペコード定義
pub const Opcode = struct {
    // 終了・リバート系
    pub const STOP = 0x00;
    pub const RETURN = 0xF3;
    pub const REVERT = 0xFD;
    pub const INVALID = 0xFE;

    // スタック操作・算術命令
    pub const ADD = 0x01;
    pub const MUL = 0x02;
    pub const SUB = 0x03;
    pub const DIV = 0x04;
    pub const SDIV = 0x05;
    pub const MOD = 0x06;
    pub const SMOD = 0x07;
    pub const ADDMOD = 0x08;
    pub const MULMOD = 0x09;
    pub const EXP = 0x0A;
    pub const LT = 0x10;
    pub const GT = 0x11;
    pub const SLT = 0x12;
    pub const SGT = 0x13;
    pub const EQ = 0x14;
    pub const ISZERO = 0x15;
    pub const AND = 0x16;
    pub const OR = 0x17;
    pub const XOR = 0x18;
    pub const NOT = 0x19;

    // ビットシフト操作
    pub const SHL = 0x1B; // 論理左シフト
    pub const SHR = 0x1C; // 論理右シフト
    pub const SAR = 0x1D; // 算術右シフト

    pub const POP = 0x50;

    // メモリ操作
    pub const MLOAD = 0x51;
    pub const MSTORE = 0x52;
    pub const MSTORE8 = 0x53;

    // ストレージ操作
    pub const SLOAD = 0x54;
    pub const SSTORE = 0x55;

    // 制御フロー
    pub const JUMP = 0x56;
    pub const JUMPI = 0x57;
    pub const PC = 0x58;
    pub const JUMPDEST = 0x5B;

    // PUSHシリーズ (PUSH0-PUSH32)
    pub const PUSH0 = 0x5F; // 定数0をスタックに積む (Solidity 0.8.24で追加)
    pub const PUSH1 = 0x60;
    // 他のPUSH命令も順次増えていく (0x61-0x7F)

    // DUPシリーズ (DUP1-DUP16)
    pub const DUP1 = 0x80;
    // 他のDUP命令も順次増えていく (0x81-0x8F)

    // SWAPシリーズ (SWAP1-SWAP16)
    pub const SWAP1 = 0x90;
    // 他のSWAP命令も順次増えていく (0x91-0x9F)

    // 呼び出しデータ関連
    pub const CALLDATALOAD = 0x35;
    pub const CALLDATASIZE = 0x36;
    pub const CALLDATACOPY = 0x37;

    // コード関連
    pub const CODESIZE = 0x38;
    pub const CODECOPY = 0x39;

    // 戻りデータ関連
    pub const RETURNDATASIZE = 0x3D;
    pub const RETURNDATACOPY = 0x3E;

    // コントラクト関連
    pub const CALLVALUE = 0x34; // 呼び出し時の送金額
};

/// エラー型定義
pub const EVMError = error{
    OutOfGas,
    StackOverflow,
    StackUnderflow,
    InvalidJumpDestination,
    InvalidOpcode,
    OutOfBounds,
    InvalidInstruction,
    StorageError,
    MemoryError,
    CallDataError,
};

/// ガス料金定義（簡易版）
pub const GasCost = struct {
    pub const G_ZERO = 0;
    pub const G_BASE = 2;
    pub const G_VERYLOW = 3;
    pub const G_LOW = 5;
    pub const G_MID = 8;
    pub const G_HIGH = 10;
    pub const G_JUMPDEST = 1;
    pub const G_SSET = 20000;
    pub const G_SRESET = 5000;
};

/// オペコードのガス料金を取得
fn getGasCost(opcode: u8) usize {
    return switch (opcode) {
        Opcode.STOP, Opcode.RETURN => GasCost.G_ZERO,
        Opcode.ADD, Opcode.SUB, Opcode.LT, Opcode.GT, Opcode.EQ, Opcode.ISZERO => GasCost.G_VERYLOW,
        Opcode.MUL, Opcode.DIV => GasCost.G_LOW,
        Opcode.JUMPDEST => GasCost.G_JUMPDEST,
        Opcode.SSTORE => GasCost.G_SSET, // 簡易版：常に新規書き込みと仮定
        Opcode.SLOAD => GasCost.G_SRESET,
        Opcode.PUSH1...Opcode.PUSH1 + 31 => GasCost.G_VERYLOW,
        Opcode.DUP1...Opcode.DUP1 + 15 => GasCost.G_VERYLOW,
        Opcode.SWAP1...Opcode.SWAP1 + 15 => GasCost.G_VERYLOW,
        Opcode.MSTORE, Opcode.MLOAD => GasCost.G_VERYLOW,
        Opcode.JUMP, Opcode.JUMPI => GasCost.G_MID,
        Opcode.PC => GasCost.G_BASE,
        Opcode.POP => GasCost.G_BASE,
        Opcode.PUSH0 => GasCost.G_BASE,
        else => GasCost.G_BASE,
    };
}

/// ガスを消費
fn consumeGas(ctx: *EvmContext, amount: usize) !void {
    if (ctx.gas_remaining < amount) {
        return EVMError.OutOfGas;
    }
    ctx.gas_remaining -= amount;
}

/// EVMバイトコードを実行
pub fn execute(ctx: *EvmContext) !void {
    while (ctx.pc < ctx.code.len and !ctx.stopped) {
        const opcode = ctx.code[ctx.pc];
        
        // ガス消費
        const gas_cost = getGasCost(opcode);
        try consumeGas(ctx, gas_cost);

        // デバッグ出力
        logger.log(.debug, "PC: {d}, Opcode: 0x{x:0>2}, Gas: {d}", .{ ctx.pc, opcode, ctx.gas_remaining });

        // オペコード実行
        try executeOpcode(ctx, opcode);
        
        // プログラムカウンタを進める（JUMPやJUMPI以外）
        if (opcode != Opcode.JUMP and opcode != Opcode.JUMPI) {
            ctx.pc += 1;
        }
    }
}

/// 単一のオペコードを実行
fn executeOpcode(ctx: *EvmContext, opcode: u8) !void {
    switch (opcode) {
        Opcode.STOP => {
            ctx.stopped = true;
        },
        
        Opcode.ADD => {
            const b = try ctx.stack.pop();
            const a = try ctx.stack.pop();
            try ctx.stack.push(a.add(b));
        },
        
        Opcode.MUL => {
            const b = try ctx.stack.pop();
            const a = try ctx.stack.pop();
            try ctx.stack.push(a.mul(b));
        },
        
        Opcode.SUB => {
            const b = try ctx.stack.pop();
            const a = try ctx.stack.pop();
            // 簡易版：アンダーフローは許容（ラップアラウンド）
            const result_lo = a.lo -% b.lo;
            const borrow = if (a.lo < b.lo) 1 else 0;
            const result_hi = a.hi -% b.hi -% borrow;
            try ctx.stack.push(EVMu256{ .hi = result_hi, .lo = result_lo });
        },
        
        Opcode.LT => {
            const b = try ctx.stack.pop();
            const a = try ctx.stack.pop();
            const result = if (a.hi < b.hi or (a.hi == b.hi and a.lo < b.lo)) 
                EVMu256.fromU64(1) 
            else 
                EVMu256.zero();
            try ctx.stack.push(result);
        },
        
        Opcode.GT => {
            const b = try ctx.stack.pop();
            const a = try ctx.stack.pop();
            const result = if (a.hi > b.hi or (a.hi == b.hi and a.lo > b.lo)) 
                EVMu256.fromU64(1) 
            else 
                EVMu256.zero();
            try ctx.stack.push(result);
        },
        
        Opcode.EQ => {
            const b = try ctx.stack.pop();
            const a = try ctx.stack.pop();
            const result = if (a.hi == b.hi and a.lo == b.lo) 
                EVMu256.fromU64(1) 
            else 
                EVMu256.zero();
            try ctx.stack.push(result);
        },
        
        Opcode.ISZERO => {
            const a = try ctx.stack.pop();
            const result = if (a.hi == 0 and a.lo == 0) 
                EVMu256.fromU64(1) 
            else 
                EVMu256.zero();
            try ctx.stack.push(result);
        },
        
        Opcode.POP => {
            _ = try ctx.stack.pop();
        },
        
        Opcode.MSTORE => {
            const offset = try ctx.stack.pop();
            const value = try ctx.stack.pop();
            // 簡易版：offsetの下位64ビットのみ使用
            try ctx.memory.store(@intCast(offset.lo), value);
        },
        
        Opcode.MLOAD => {
            const offset = try ctx.stack.pop();
            // 簡易版：offsetの下位64ビットのみ使用
            const value = ctx.memory.load(@intCast(offset.lo));
            try ctx.stack.push(value);
        },
        
        Opcode.SSTORE => {
            const key = try ctx.stack.pop();
            const value = try ctx.stack.pop();
            try ctx.storage.store(key, value);
        },
        
        Opcode.SLOAD => {
            const key = try ctx.stack.pop();
            const value = ctx.storage.load(key);
            try ctx.stack.push(value);
        },
        
        Opcode.JUMP => {
            const dest = try ctx.stack.pop();
            // 簡易版：destの下位64ビットのみ使用
            const jump_pc = @as(usize, @intCast(dest.lo));
            
            // ジャンプ先の検証
            if (jump_pc >= ctx.code.len) {
                return EVMError.InvalidJumpDestination;
            }
            if (ctx.code[jump_pc] != Opcode.JUMPDEST) {
                return EVMError.InvalidJumpDestination;
            }
            
            ctx.pc = jump_pc;
        },
        
        Opcode.JUMPI => {
            const dest = try ctx.stack.pop();
            const condition = try ctx.stack.pop();
            
            // 条件が真（非ゼロ）の場合のみジャンプ
            if (condition.hi != 0 or condition.lo != 0) {
                const jump_pc = @as(usize, @intCast(dest.lo));
                
                if (jump_pc >= ctx.code.len) {
                    return EVMError.InvalidJumpDestination;
                }
                if (ctx.code[jump_pc] != Opcode.JUMPDEST) {
                    return EVMError.InvalidJumpDestination;
                }
                
                ctx.pc = jump_pc;
            } else {
                ctx.pc += 1;
            }
        },
        
        Opcode.PC => {
            try ctx.stack.push(EVMu256.fromU64(@intCast(ctx.pc)));
        },
        
        Opcode.JUMPDEST => {
            // ジャンプ先マーカー（何もしない）
        },
        
        Opcode.PUSH0 => {
            try ctx.stack.push(EVMu256.zero());
        },
        
        Opcode.PUSH1...Opcode.PUSH1 + 31 => {
            const n = opcode - Opcode.PUSH1 + 1;
            ctx.pc += 1;
            
            if (ctx.pc + n > ctx.code.len) {
                return EVMError.OutOfBounds;
            }
            
            const bytes = ctx.code[ctx.pc..ctx.pc + n];
            const value = EVMu256.fromBytes(bytes);
            try ctx.stack.push(value);
            
            ctx.pc += n - 1;
        },
        
        Opcode.DUP1...Opcode.DUP1 + 15 => {
            const n = opcode - Opcode.DUP1 + 1;
            if (ctx.stack.depth() < n) {
                return EVMError.StackUnderflow;
            }
            const value = ctx.stack.data[ctx.stack.top - n];
            try ctx.stack.push(value);
        },
        
        Opcode.SWAP1...Opcode.SWAP1 + 15 => {
            const n = opcode - Opcode.SWAP1 + 1;
            if (ctx.stack.depth() < n + 1) {
                return EVMError.StackUnderflow;
            }
            const temp = ctx.stack.data[ctx.stack.top - 1];
            ctx.stack.data[ctx.stack.top - 1] = ctx.stack.data[ctx.stack.top - n - 1];
            ctx.stack.data[ctx.stack.top - n - 1] = temp;
        },
        
        Opcode.RETURN => {
            const offset = try ctx.stack.pop();
            const length = try ctx.stack.pop();
            
            // 簡易版：offset/lengthの下位64ビットのみ使用
            const mem_offset = @as(usize, @intCast(offset.lo));
            const mem_length = @as(usize, @intCast(length.lo));
            
            if (mem_offset + mem_length <= ctx.memory.data.items.len) {
                ctx.return_data = ctx.memory.data.items[mem_offset..mem_offset + mem_length];
            }
            
            ctx.stopped = true;
        },
        
        Opcode.CALLDATALOAD => {
            const offset = try ctx.stack.pop();
            const offset_usize = @as(usize, @intCast(offset.lo));
            
            var bytes: [32]u8 = [_]u8{0} ** 32;
            const available = if (offset_usize < ctx.calldata.len) 
                @min(32, ctx.calldata.len - offset_usize) 
            else 
                0;
            
            if (available > 0) {
                @memcpy(bytes[0..available], ctx.calldata[offset_usize..offset_usize + available]);
            }
            
            try ctx.stack.push(EVMu256.fromBytes(&bytes));
        },
        
        Opcode.CALLDATASIZE => {
            try ctx.stack.push(EVMu256.fromU64(@intCast(ctx.calldata.len)));
        },
        
        else => {
            logger.log(.err, "Unknown opcode: 0x{x:0>2}", .{opcode});
            return EVMError.InvalidOpcode;
        },
    }
}

/// 簡単なテスト
test "EVM basic operations" {
    const allocator = std.testing.allocator;
    
    // PUSH1 0x05, PUSH1 0x03, ADD というバイトコード
    const code = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01 };
    const calldata = [_]u8{};
    
    var ctx = EvmContext.init(allocator, &code, &calldata, 1000000);
    defer ctx.deinit();
    
    try execute(&ctx);
    
    // スタックトップが8（5+3）であることを確認
    const result = try ctx.stack.pop();
    try std.testing.expectEqual(@as(u128, 8), result.lo);
    try std.testing.expectEqual(@as(u128, 0), result.hi);
}

test "EVM multiplication" {
    const allocator = std.testing.allocator;
    
    // PUSH1 0x04, PUSH1 0x03, MUL というバイトコード
    const code = [_]u8{ 0x60, 0x04, 0x60, 0x03, 0x02 };
    const calldata = [_]u8{};
    
    var ctx = EvmContext.init(allocator, &code, &calldata, 1000000);
    defer ctx.deinit();
    
    try execute(&ctx);
    
    // スタックトップが12（4*3）であることを確認
    const result = try ctx.stack.pop();
    try std.testing.expectEqual(@as(u128, 12), result.lo);
    try std.testing.expectEqual(@as(u128, 0), result.hi);
}

test "EVM storage operations" {
    const allocator = std.testing.allocator;
    
    // PUSH1 0x42 (value), PUSH1 0x01 (key), SSTORE, PUSH1 0x01 (key), SLOAD
    const code = [_]u8{ 0x60, 0x42, 0x60, 0x01, 0x55, 0x60, 0x01, 0x54 };
    const calldata = [_]u8{};
    
    var ctx = EvmContext.init(allocator, &code, &calldata, 1000000);
    defer ctx.deinit();
    
    try execute(&ctx);
    
    // スタックトップが0x42であることを確認
    const result = try ctx.stack.pop();
    try std.testing.expectEqual(@as(u128, 0x42), result.lo);
    try std.testing.expectEqual(@as(u128, 0), result.hi);
}
```

## 実際のSolidityコントラクトを実行する

では、実際にSolidityでコンパイルしたバイトコードを実行してみましょう。先ほどの`SimpleAdder`コントラクトをデプロイして、`add`関数を呼び出します。

```zig
// main.zig
const std = @import("std");
const evm = @import("evm.zig");
const evm_types = @import("evm_types.zig");
const evm_debug = @import("evm_debug.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    // SimpleAdderコントラクトのランタイムバイトコード（デプロイ後のコード）
    // これは実際のSolidityコンパイル結果から抽出したもの
    const runtime_code = try std.fmt.hexToBytes(allocator, 
        "608060405234801561000f575f80fd5b5060043610610029575f3560e01c8063771602f71461002d575b5f80fd5b610047600480360381019061004291906100a9565b61005d565b60405161005491906100f6565b60405180910390f35b5f818361006a919061013c565b905092915050565b5f80fd5b5f819050919050565b61008881610076565b8114610092575f80fd5b50565b5f813590506100a38161007f565b92915050565b5f80604083850312156100bf576100be610072565b5b5f6100cc85828601610095565b92505060206100dd85828601610095565b9150509250929050565b6100f081610076565b82525050565b5f6020820190506101095f8301846100e7565b92915050565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52601160045260245ffd5b5f61014682610076565b915061015183610076565b92508282019050808211156101695761016861010f565b5b9291505056fea2646970667358221220e478f9e62b837b6d95fa3abbc3c7eb6c02d17eb28b14607d07eb892ef9992db964736f6c63430008180033"
    );
    defer allocator.free(runtime_code);
    
    // add(5, 3)を呼び出すためのcalldata
    // 0x771602f7 = add関数のセレクタ（Keccak256("add(uint256,uint256)")の最初の4バイト）
    // 0x0000000000000000000000000000000000000000000000000000000000000005 = 5
    // 0x0000000000000000000000000000000000000000000000000000000000000003 = 3
    const calldata = try std.fmt.hexToBytes(allocator,
        "771602f7" ++
        "0000000000000000000000000000000000000000000000000000000000000005" ++
        "0000000000000000000000000000000000000000000000000000000000000003"
    );
    defer allocator.free(calldata);
    
    // EVM実行
    var ctx = evm_types.EvmContext.init(allocator, runtime_code, calldata, 3000000);
    defer ctx.deinit();
    
    std.debug.print("Executing SimpleAdder.add(5, 3)...\n", .{});
    
    try evm.execute(&ctx);
    
    if (ctx.return_data) |data| {
        std.debug.print("Execution completed. Return data: ", .{});
        for (data) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("\n", .{});
        
        // 戻り値をu256として解釈
        if (data.len == 32) {
            const result = evm_types.EVMu256.fromBytes(data);
            std.debug.print("Result: {d}\n", .{result.lo});
        }
    } else {
        std.debug.print("Execution completed with no return data.\n", .{});
    }
    
    std.debug.print("Gas used: {d}\n", .{3000000 - ctx.gas_remaining});
}
```

## まとめ

この章では、ZigでEVMの基本的な実装を行いました。実装した主な機能：

1. **256ビット整数演算**: EVMの基本データ型であるu256を実装
2. **スタック操作**: PUSH、POP、DUP、SWAPなどの基本操作
3. **算術演算**: ADD、MUL、SUB、LT、GT、EQなど
4. **メモリ操作**: MSTORE、MLOADによる一時データの読み書き
5. **ストレージ操作**: SSTORE、SLOADによる永続データの読み書き
6. **制御フロー**: JUMP、JUMPI、JUMPDESTによる条件分岐
7. **関数呼び出し**: CALLDATALOADによる引数の読み取り、RETURNによる戻り値

これらの機能により、簡単なSolidityスマートコントラクトを実行できるようになりました。

実際のEthereumのEVMはさらに多くの機能を持っています：
- CREATE、CREATE2によるコントラクト作成
- CALL、DELEGATECALL、STATICCALLによる外部呼び出し
- SELFDESTRUCT、LOGなどの特殊命令
- より厳密なガス計算とメモリ管理

しかし、この簡易実装でもEVMの基本的な動作原理を理解し、スマートコントラクトがどのように実行されるかを学ぶことができました。

## 参考資料

- [Ethereum Yellow Paper](https://ethereum.github.io/yellowpaper/paper.pdf)
- [EVM Opcodes](https://www.evm.codes/)
- [Solidity Documentation](https://docs.soliditylang.org/)
- [go-ethereum EVM実装](https://github.com/ethereum/go-ethereum/tree/master/core/vm)

## 演習課題

1. **DIV命令の実装**: 除算命令を実装してみましょう。ゼロ除算の場合は0を返すようにします。
2. **AND/OR/XOR命令**: ビット演算命令を実装してみましょう。
3. **CODECOPY命令**: 実行中のコードをメモリにコピーする命令を実装してみましょう。
4. **より複雑なコントラクト**: カウンターやトークンなど、状態を持つコントラクトを実行してみましょう。

これらの演習を通じて、EVMの理解をさらに深めることができます。