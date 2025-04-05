const std = @import("std");

pub const ChainError = error{
    InvalidHexLength,
    InvalidHexChar,
    InvalidFormat,
};

// Transaction 構造体
// ブロックチェーン上の「取引」を表現します。
pub const Transaction = struct {
    sender: []const u8, // 送信者のアドレスまたは識別子(文字列)
    receiver: []const u8, // 受信者のアドレスまたは識別子(文字列)
    amount: u64, // 取引金額(符号なし64ビット整数)
};

// Block 構造体
// ブロックチェーン上の「ブロック」を表現します。
pub const Block = struct {
    index: u32, // ブロック番号(0から始まる連番)
    timestamp: u64, // ブロック生成時のUNIXタイムスタンプ
    prev_hash: [32]u8, // 前のブロックのハッシュ(32バイト固定)
    transactions: std.ArrayList(Transaction), // ブロック内の複数の取引を保持する動的配列
    nonce: u64, // Proof of Work (PoW) 採掘用のnonce値
    data: []const u8, // 任意の追加データ(文字列など)
    hash: [32]u8, // このブロックのSHA-256ハッシュ(32バイト固定)
};
