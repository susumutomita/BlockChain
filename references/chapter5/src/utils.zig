const std = @import("std");
const ChainError = @import("errors.zig").ChainError;

/// デバッグログフラグ
pub const debug_logging = false;

/// デバッグログ
pub fn debugLog(comptime format: []const u8, args: anytype) void {
    if (comptime debug_logging) {
        std.debug.print(format, args);
    }
}

//------------------------------------------------------------------------------
// ヘルパー関数
//------------------------------------------------------------------------------

pub fn truncateU32ToU8(x: u32) u8 {
    if (x > 0xff) @panic("u32 out of u8 range");
    return @truncate(x);
}

pub fn truncateU64ToU8(x: u64) u8 {
    if (x > 0xff) @panic("u64 out of u8 range");
    return @truncate(x);
}

pub fn toBytesU32(value: u32) [4]u8 {
    var buf: [4]u8 = undefined;
    buf[0] = truncateU32ToU8(value & 0xff);
    buf[1] = truncateU32ToU8((value >> 8) & 0xff);
    buf[2] = truncateU32ToU8((value >> 16) & 0xff);
    buf[3] = truncateU32ToU8((value >> 24) & 0xff);
    return buf;
}

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

// publicにする: main.zigから呼べるようにする
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
