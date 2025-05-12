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

/// 16進数文字列をバイト配列に変換する
///
/// 引数:
///     allocator: メモリアロケータ
///     hex_str: 16進数文字列（"0x"プレフィックス付きでも可）
///
/// 戻り値:
///     []const u8: 変換されたバイト配列
///     エラー: 無効な16進数文字列の場合
pub fn hexToBytes(allocator: std.mem.Allocator, hex_str: []const u8) ![]const u8 {
    // 16進数文字列の先頭に0xがある場合は取り除く
    const hex = if (std.mem.startsWith(u8, hex_str, "0x"))
        hex_str[2..]
    else
        hex_str;

    // 奇数長の場合は先頭に0を追加して偶数長にする
    var padded_hex: []const u8 = hex;
    var padded_allocated = false;

    if (hex.len % 2 != 0) {
        var padded_buffer = try allocator.alloc(u8, hex.len + 1);
        padded_buffer[0] = '0';
        @memcpy(padded_buffer[1..], hex);
        padded_hex = padded_buffer;
        padded_allocated = true;
    }
    defer if (padded_allocated) allocator.free(padded_hex);

    // 16進数文字列をバイト配列に変換
    const result = try allocator.alloc(u8, padded_hex.len / 2);
    errdefer allocator.free(result);

    var i: usize = 0;
    while (i < result.len) : (i += 1) {
        const high = try std.fmt.charToDigit(padded_hex[i * 2], 16);
        const low = try std.fmt.charToDigit(padded_hex[i * 2 + 1], 16);
        result[i] = @as(u8, @intCast(high)) * 16 + @as(u8, @intCast(low));
    }

    return result;
}

/// バイト配列を16進数文字列に変換する
///
/// 引数:
///     allocator: メモリアロケータ
///     bytes: 変換するバイト配列
///
/// 戻り値:
///     []const u8: 変換された16進数文字列
pub fn bytesToHex(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const hex_chars = "0123456789abcdef";
    const hex = try allocator.alloc(u8, bytes.len * 2);
    errdefer allocator.free(hex);

    for (bytes, 0..) |b, i| {
        hex[i * 2] = hex_chars[b >> 4];
        hex[i * 2 + 1] = hex_chars[b & 0xF];
    }

    return hex;
}

/// "0x"プレフィックス付きの16進数文字列を生成する
///
/// 引数:
///     allocator: メモリアロケータ
///     bytes: 変換するバイト配列
///
/// 戻り値:
///     []const u8: "0x"プレフィックス付きの16進数文字列
pub fn bytesToHexWithPrefix(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const hex = try bytesToHex(allocator, bytes);
    defer allocator.free(hex);

    const result = try std.mem.concat(allocator, u8, &[_][]const u8{ "0x", hex });
    return result;
}
