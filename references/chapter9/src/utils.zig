//! ユーティリティ関数モジュール
//!
//! このモジュールはブロックチェーンアプリケーションのための様々なユーティリティ関数を提供し、
//! 主に暗号化操作やデータシリアル化に必要な型変換とバイト操作に焦点を当てています。

const std = @import("std");

//------------------------------------------------------------------------------
// 変換ヘルパー関数
//------------------------------------------------------------------------------

/// u32値をオーバーフローをチェックしながらu8に変換する
///
/// この関数はu32をu8に安全に変換し、値がu8で表現可能な最大値を
/// 超える場合にパニックします。
///
/// 引数:
///     x: 切り捨てるu32値
///
/// 戻り値:
///     u8: 切り捨てられた値
///
/// パニック:
///     入力値が0xFF（255）より大きい場合
pub fn truncateU32ToU8(x: u32) u8 {
    if (x > 0xff) @panic("u32 out of u8 range");
    return @truncate(x);
}

/// u64値をオーバーフローをチェックしながらu8に変換する
///
/// この関数はu64をu8に安全に変換し、値がu8で表現可能な最大値を
/// 超える場合にパニックします。
///
/// 引数:
///     x: 切り捨てるu64値
///
/// 戻り値:
///     u8: 切り捨てられた値
///
/// パニック:
///     入力値が0xFF（255）より大きい場合
pub fn truncateU64ToU8(x: u64) u8 {
    if (x > 0xff) @panic("u64 out of u8 range");
    return @truncate(x);
}

/// u32値をリトルエンディアン順の4バイト配列に変換する
///
/// 32ビット符号なし整数をそのバイト表現に変換します。
/// 最下位バイトはインデックス0に配置されます。
///
/// 引数:
///     value: 変換するu32値
///
/// 戻り値:
///     [4]u8: 値のリトルエンディアン表現を含むバイト配列
pub fn toBytesU32(value: u32) [4]u8 {
    var buf: [4]u8 = undefined;
    buf[0] = truncateU32ToU8(value & 0xff);
    buf[1] = truncateU32ToU8((value >> 8) & 0xff);
    buf[2] = truncateU32ToU8((value >> 16) & 0xff);
    buf[3] = truncateU32ToU8((value >> 24) & 0xff);
    return buf;
}

/// u64値をリトルエンディアン順の8バイト配列に変換する
///
/// 64ビット符号なし整数をそのバイト表現に変換します。
/// 最下位バイトはインデックス0に配置されます。
///
/// 引数:
///     value: 変換するu64値
///
/// 戻り値:
///     [8]u8: 値のリトルエンディアン表現を含むバイト配列
pub fn toBytesU64(value: u64) [8]u8 {
    var buf: [8]u8 = undefined;
    buf[0] = truncateU64ToU8(value & 0xff);
    buf[1] = truncateU64ToU8((value >> 8) & 0xff);
    buf[2] = truncateU64ToU8((value >> 16) & 0xff);
    buf[3] = truncateU64ToU8((value >> 24) & 0xff);
    buf[4] = truncateU64ToU8((value >> 32) & 0xff);
    buf[5] = truncateU64ToU8((value >> 40) & 0xff);
    buf[6] = truncateU64ToU8((value >> 48) & 0xff);
    buf[7] = truncateU64ToU8((value >> 56) & 0xff);
    return buf;
}

/// 任意の型をそのバイト表現に変換する汎用関数
///
/// この関数は、異なる型の値をそれらのバイト表現に変換する汎用的な方法を提供します。
/// 入力型に基づいて、適切な特殊化された関数にディスパッチします。
///
/// 引数:
///     T: 変換する値の型（推論される）
///     value: バイトに変換する値
///
/// 戻り値:
///     []const u8: 値を表すバイトのスライス
///
/// 注意:
///     u32とu64以外の型の場合、この関数は値をバイトに変換するために@bitCastを使用します。
pub fn toBytes(comptime T: type, value: T) []const u8 {
    if (T == u32) {
        return toBytesU32(@as(u32, value))[0..];
    } else if (T == u64) {
        return toBytesU64(@as(u64, value))[0..];
    } else {
        const bytes: [@sizeOf(T)]u8 = @bitCast(value);
        return bytes[0..];
    }
}
