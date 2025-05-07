# EVM (Ethereum Virtual Machine) アーキテクチャ設計

## 1. 概要

このドキュメントでは、ブロックチェーンプロジェクトにスマートコントラクト機能を追加するためのEVM（Ethereum Virtual Machine）実装の設計について説明します。EVMはスタックベースの仮想マシンであり、バイトコード形式のスマートコントラクトを実行します。

## 2. 設計目標

- **Ethereum互換性**: Ethereum Yellow Paperに準拠したEVM仕様の実装
- **効率性**: 限られたリソース内での効率的な実行
- **拡張性**: 将来のEIPsやアップグレードに対応できる設計
- **統合性**: 既存のブロックチェーン実装と統合が容易な設計

## 3. コアコンポーネント

### 3.1 データ型

#### 3.1.1 256ビット整数型 (EVMu256)

EVMはすべての計算において256ビット整数を基本型として使用します。Zigには標準で256ビット整数型が提供されていないため、カスタム実装を行います：

```zig
pub const EVMu256 = struct {
    hi: u128, // 上位128ビット
    lo: u128, // 下位128ビット

    // 基本的な演算メソッド
    pub fn add(self: EVMu256, other: EVMu256) EVMu256 { ... }
    pub fn sub(self: EVMu256, other: EVMu256) EVMu256 { ... }
    pub fn mul(self: EVMu256, other: EVMu256) EVMu256 { ... }
    // 他の必要な演算...
};
```

### 3.2 実行環境

#### 3.2.1 スタック

EVMはスタックベースの仮想マシンであり、最大深さ1024の固定サイズスタックを使用します：

```zig
pub const EvmStack = struct {
    data: [1024]EVMu256,
    sp: usize, // スタックポインタ

    pub fn push(self: *EvmStack, value: EVMu256) !void { ... }
    pub fn pop(self: *EvmStack) !EVMu256 { ... }
};
```

#### 3.2.2 メモリ

EVMメモリは実行中に動的に拡張可能なバイト配列として実装：

```zig
pub const EvmMemory = struct {
    data: std.ArrayList(u8),

    pub fn load32(self: *EvmMemory, offset: usize) !EVMu256 { ... }
    pub fn store32(self: *EvmMemory, offset: usize, value: EVMu256) !void { ... }
};
```

#### 3.2.3 ストレージ

コントラクトの状態を永続的に保存するためのキー/値ストア：

```zig
pub const EvmStorage = struct {
    data: std.AutoHashMap(EVMu256, EVMu256),

    pub fn load(self: *EvmStorage, key: EVMu256) EVMu256 { ... }
    pub fn store(self: *EvmStorage, key: EVMu256, value: EVMu256) !void { ... }
};
```

#### 3.2.4 実行コンテキスト

実行状態を管理する構造体：

```zig
pub const EvmContext = struct {
    pc: usize,                    // プログラムカウンタ
    gas: usize,                   // 残りガス量
    code: []const u8,             // 実行中のバイトコード
    calldata: []const u8,         // 呼び出しデータ
    returndata: std.ArrayList(u8), // 戻り値データ
    stack: EvmStack,              // スタック
    memory: EvmMemory,            // メモリ
    storage: EvmStorage,          // ストレージ
    depth: u8,                    // 呼び出し深度
    stopped: bool,                // 実行終了フラグ
    error_msg: ?[]const u8,       // エラーメッセージ
};
```

### 3.3 命令セット

EVMは多数の命令（オペコード）をサポートしており、以下のカテゴリに分類されます：

- **スタック操作**: PUSH, POP, DUP, SWAP
- **算術演算**: ADD, SUB, MUL, DIV, SDIV, MOD, ...
- **ビット操作**: AND, OR, XOR, NOT, SHL, SHR, ...
- **メモリ操作**: MLOAD, MSTORE, MSTORE8
- **ストレージ操作**: SLOAD, SSTORE
- **制御フロー**: JUMP, JUMPI, PC, JUMPDEST
- **環境情報**: ADDRESS, BALANCE, ORIGIN, CALLER, ...
- **ブロック情報**: BLOCKHASH, COINBASE, TIMESTAMP, NUMBER, ...
- **呼び出し操作**: CALL, CALLCODE, DELEGATECALL, STATICCALL, ...
- **ログ・システム**: LOG0, LOG1, LOG2, LOG3, LOG4
- **その他**: SHA3, RETURN, REVERT, SELFDESTRUCT, ...

### 3.4 ガス計算

EVMの各操作はガスを消費します。ガス計算は以下のように実装：

```zig
// ガス消費の例（実際の実装では各オペコードごとに異なるガス消費量を定義）
switch (opcode) {
    Opcode.ADD => context.gas -= 3,
    Opcode.MUL => context.gas -= 5,
    Opcode.SSTORE => context.gas -= 20000, // 新規格納時
    // 他の命令...
}
```

## 4. 実行フロー

EVMの実行フローは以下のとおりです：

1. **初期化**: コンテキスト（スタック、メモリ、ストレージ等）の初期化
2. **命令サイクル**:
   - プログラムカウンタ位置のオペコード読み取り
   - ガス消費計算と残量チェック
   - オペコードに応じた操作実行
   - 次の命令へ進む（または分岐）
3. **終了条件**:
   - STOP/RETURN/REVERT命令の実行
   - ガス不足
   - 実行エラー（スタックアンダーフローなど）

## 5. ブロックチェーンとの統合

EVMの実装は以下のようにブロックチェーンシステムと統合されます：

1. **トランザクション処理**:
   - スマートコントラクト作成/呼び出しトランザクションの識別
   - EVMインスタンスの初期化と実行
   - 状態変更の適用またはロールバック

2. **状態管理**:
   - コントラクトアカウント状態（コード、ストレージ）の管理
   - 世界状態（ワールドステート）への統合

3. **ガス管理**:
   - トランザクション実行前のガス支払い検証
   - 未使用ガスの返還メカニズム

## 6. セキュリティ考慮事項

- **実行隔離**: コントラクト間の適切な隔離
- **ガス制限**: 無限ループ等のDoS攻撃防止
- **呼び出し深度制限**: リエントランシー攻撃やスタックオーバーフローの防止
- **命令セットの制限**: 安全でない操作の制限

## 7. 将来の拡張性

- **新しいEIPs対応**: Ethereumの進化に合わせた拡張
- **最適化**: ホットパスの最適化、JITコンパイル等
- **ステートプルーフ**: Merkleパトリシアツリーなどの実装

## 8. コンポーネント関連図

```diagram
┌─────────────────┐
│  トランザクション処理 │
└────────┬────────┘
         │
         ▼
┌─────────────────┐     ┌─────────────────┐
│   EVM実行エンジン   │◄────┤   コントラクトコード  │
└────────┬────────┘     └─────────────────┘
         │
         ├─────────────┬─────────────┬─────────────┐
         │             │             │             │
         ▼             ▼             ▼             ▼
┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
│   スタック   │ │   メモリ    │ │  ストレージ  │ │   ガス計算  │
└─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘
```

## 9. 実装スケジュール

1. **フェーズ1**: 基本データ構造（u256, スタック、メモリ）の実装
2. **フェーズ2**: 基本的なオペコード（算術演算、メモリ操作）の実装
3. **フェーズ3**: ストレージとガス計算の実装
4. **フェーズ4**: 高度なオペコード（制御フロー、呼び出し）の実装
5. **フェーズ5**: ブロックチェーン状態との統合
6. **フェーズ6**: テストとバグ修正、最適化

## 10. 参考資料

- [Ethereum Yellow Paper](https://ethereum.github.io/yellowpaper/paper.pdf)
- [EVM Opcodes Reference](https://www.evm.codes/)
- [Ethereum's State Machine](https://ethereum.org/en/developers/docs/evm/)
