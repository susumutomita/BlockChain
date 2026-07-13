//! EVMデータ構造定義
//!
//! このモジュールはEthereum Virtual Machine (EVM)の実行に必要な
//! データ構造を定義します。スマートコントラクト実行環境に
//! 必要なスタック、メモリ、ストレージなどの構造体を含みます。

const std = @import("std");

/// 256ビット整数型（EVMの基本データ型）
/// u128の2つの要素で256ビットを表現
pub const EVMu256 = struct {
    hi: u128,
    lo: u128,

    pub fn zero() EVMu256 {
        return .{ .hi = 0, .lo = 0 };
    }

    pub fn one() EVMu256 {
        return .{ .hi = 0, .lo = 1 };
    }

    pub fn fromU64(value: u64) EVMu256 {
        return .{ .hi = 0, .lo = value };
    }

    pub fn add(self: EVMu256, other: EVMu256) EVMu256 {
        var result = EVMu256{ .hi = self.hi, .lo = self.lo };
        var overflow: u1 = 0;
        result.lo, overflow = @addWithOverflow(result.lo, other.lo);
        result.hi = result.hi +% other.hi +% @as(u128, overflow);
        return result;
    }

    pub fn sub(self: EVMu256, other: EVMu256) EVMu256 {
        var result = EVMu256{ .hi = self.hi, .lo = self.lo };
        var underflow: u1 = 0;
        result.lo, underflow = @subWithOverflow(result.lo, other.lo);
        result.hi = result.hi -% other.hi -% @as(u128, underflow);
        return result;
    }

    pub fn mul(self: EVMu256, other: EVMu256) EVMu256 {
        const lhs = (@as(u256, self.hi) << 128) | @as(u256, self.lo);
        const rhs = (@as(u256, other.hi) << 128) | @as(u256, other.lo);
        const product = lhs *% rhs;
        return .{
            .hi = @truncate(product >> 128),
            .lo = @truncate(product),
        };
    }

    pub fn eql(self: EVMu256, other: EVMu256) bool {
        return self.hi == other.hi and self.lo == other.lo;
    }

    pub fn eq(self: EVMu256, other: EVMu256) bool {
        return self.eql(other);
    }

    pub fn isZero(self: EVMu256) bool {
        return self.hi == 0 and self.lo == 0;
    }

    pub fn toBytes(self: EVMu256) [32]u8 {
        var bytes: [32]u8 = undefined;
        for (0..16) |i| {
            const shift = @as(u7, @intCast((15 - i) * 8));
            bytes[i] = @truncate(self.hi >> shift);
            bytes[i + 16] = @truncate(self.lo >> shift);
        }
        return bytes;
    }

    pub fn fromBytes(input: []const u8) EVMu256 {
        const bytes = input[input.len - @min(input.len, 32) ..];
        const offset = 32 - bytes.len;
        var result = EVMu256.zero();

        for (bytes, 0..) |byte, i| {
            const pos = offset + i;
            if (pos < 16) {
                const shift = @as(u7, @intCast((15 - pos) * 8));
                result.hi |= @as(u128, byte) << shift;
            } else {
                const shift = @as(u7, @intCast((31 - pos) * 8));
                result.lo |= @as(u128, byte) << shift;
            }
        }
        return result;
    }

    pub fn format(
        self: EVMu256,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (fmt.len == 0 or fmt[0] == 'd') {
            if (self.hi == 0) {
                try std.fmt.formatInt(self.lo, 10, .lower, options, writer);
            } else {
                try writer.writeAll("0x");
                try std.fmt.formatInt(self.hi, 16, .lower, .{}, writer);
                try writer.writeByte('_');
                try std.fmt.formatInt(self.lo, 16, .lower, .{}, writer);
            }
        } else if (fmt[0] == 'x' or fmt[0] == 'X') {
            const case: std.fmt.Case = if (fmt[0] == 'X') .upper else .lower;
            try writer.writeAll("0x");
            if (self.hi != 0) {
                try std.fmt.formatInt(self.hi, 16, case, .{ .fill = '0', .width = 32 }, writer);
            }
            try std.fmt.formatInt(self.lo, 16, case, .{ .fill = '0', .width = 32 }, writer);
        } else {
            try writer.writeAll("0x");
            if (self.hi != 0) {
                try std.fmt.formatInt(self.hi, 16, .lower, .{}, writer);
                try writer.writeByte('_');
            }
            try std.fmt.formatInt(self.lo, 16, .lower, .{}, writer);
        }
    }
};

/// EVMアドレスクラス（20バイト/160ビットのEthereumアドレス）
pub const EVMAddress = struct {
    data: [20]u8,

    pub fn zero() EVMAddress {
        return .{ .data = [_]u8{0} ** 20 };
    }

    pub fn fromBytes(bytes: []const u8) !EVMAddress {
        if (bytes.len != 20) return error.InvalidAddressLength;
        var addr = EVMAddress{ .data = undefined };
        @memcpy(&addr.data, bytes);
        return addr;
    }

    pub fn fromHexString(hex_str: []const u8) !EVMAddress {
        var offset: usize = 0;
        if (hex_str.len >= 2 and hex_str[0] == '0' and (hex_str[1] == 'x' or hex_str[1] == 'X')) {
            offset = 2;
        }
        if (hex_str.len - offset != 40) return error.InvalidAddressLength;

        var addr = EVMAddress{ .data = undefined };
        var i: usize = 0;
        while (i < 20) : (i += 1) {
            const high = try std.fmt.charToDigit(hex_str[offset + i * 2], 16);
            const low = try std.fmt.charToDigit(hex_str[offset + i * 2 + 1], 16);
            addr.data[i] = @as(u8, high << 4) | @as(u8, low);
        }
        return addr;
    }

    pub fn toHexString(self: EVMAddress, allocator: std.mem.Allocator) ![]u8 {
        const result = try allocator.alloc(u8, 42);
        result[0] = '0';
        result[1] = 'x';
        for (self.data, 0..) |byte, i| {
            result[2 + i * 2] = std.fmt.digitToChar(byte >> 4, .lower);
            result[2 + i * 2 + 1] = std.fmt.digitToChar(byte & 0xF, .lower);
        }
        return result;
    }

    pub fn fromEVMu256(value: EVMu256) EVMAddress {
        const bytes = value.toBytes();
        var addr = EVMAddress{ .data = undefined };
        @memcpy(&addr.data, bytes[12..32]);
        return addr;
    }

    pub fn eql(self: EVMAddress, other: EVMAddress) bool {
        return std.mem.eql(u8, &self.data, &other.data);
    }

    pub fn toChecksumAddress(self: EVMAddress, allocator: std.mem.Allocator) ![]u8 {
        return self.toHexString(allocator);
    }
};

/// EVMスタック（1024要素まで格納可能）
pub const EvmStack = struct {
    data: [1024]EVMu256,
    sp: usize,

    pub fn init() EvmStack {
        return .{ .data = undefined, .sp = 0 };
    }

    pub fn push(self: *EvmStack, value: EVMu256) !void {
        if (self.sp >= 1024) return error.StackOverflow;
        self.data[self.sp] = value;
        self.sp += 1;
    }

    pub fn pop(self: *EvmStack) !EVMu256 {
        if (self.sp == 0) return error.StackUnderflow;
        self.sp -= 1;
        return self.data[self.sp];
    }

    pub fn depth(self: *const EvmStack) usize {
        return self.sp;
    }

    pub fn dup(self: *EvmStack, n: usize) !void {
        if (n == 0 or self.sp < n) return error.StackUnderflow;
        try self.push(self.data[self.sp - n]);
    }

    pub fn swap(self: *EvmStack, n: usize) !void {
        if (n == 0 or self.sp < n + 1) return error.StackUnderflow;
        const top = self.sp - 1;
        const other = self.sp - n - 1;
        const value = self.data[top];
        self.data[top] = self.data[other];
        self.data[other] = value;
    }
};

/// EVMメモリ（動的に拡張可能なバイト配列）
pub const EvmMemory = struct {
    data: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) EvmMemory {
        return .{ .data = std.ArrayList(u8).init(allocator) };
    }

    pub fn ensureSize(self: *EvmMemory, size: usize) !void {
        if (size > self.data.items.len) {
            const old_len = self.data.items.len;
            const new_size = ((size + 31) / 32) * 32;
            try self.data.resize(new_size);
            @memset(self.data.items[old_len..new_size], 0);
        }
    }

    pub fn load32(self: *EvmMemory, offset: usize) !EVMu256 {
        try self.ensureSize(offset + 32);
        return EVMu256.fromBytes(self.data.items[offset .. offset + 32]);
    }

    pub fn store32(self: *EvmMemory, offset: usize, value: EVMu256) !void {
        try self.ensureSize(offset + 32);
        const bytes = value.toBytes();
        @memcpy(self.data.items[offset .. offset + 32], &bytes);
    }

    pub fn deinit(self: *EvmMemory) void {
        self.data.deinit();
    }
};

/// EVMストレージ（本章では1回の実行中だけ保持するキー/バリューストア）
pub const EvmStorage = struct {
    data: std.AutoHashMap(EVMu256, EVMu256),

    pub fn init(allocator: std.mem.Allocator) EvmStorage {
        return .{ .data = std.AutoHashMap(EVMu256, EVMu256).init(allocator) };
    }

    pub fn load(self: *EvmStorage, key: EVMu256) EVMu256 {
        return self.data.get(key) orelse EVMu256.zero();
    }

    pub fn store(self: *EvmStorage, key: EVMu256, value: EVMu256) !void {
        try self.data.put(key, value);
    }

    pub fn deinit(self: *EvmStorage) void {
        self.data.deinit();
    }
};

/// EVM実行コンテキスト（実行状態を保持）
pub const EvmContext = struct {
    pc: usize,
    gas: usize,
    code: []const u8,
    calldata: []const u8,
    returndata: std.ArrayList(u8),
    stack: EvmStack,
    memory: EvmMemory,
    storage: EvmStorage,
    depth: u8,
    stopped: bool,
    error_msg: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, code: []const u8, calldata: []const u8) EvmContext {
        return .{
            .pc = 0,
            .gas = 10_000_000,
            .code = code,
            .calldata = calldata,
            .returndata = std.ArrayList(u8).init(allocator),
            .stack = EvmStack.init(),
            .memory = EvmMemory.init(allocator),
            .storage = EvmStorage.init(allocator),
            .depth = 0,
            .stopped = false,
            .error_msg = null,
        };
    }

    pub fn deinit(self: *EvmContext) void {
        self.returndata.deinit();
        self.memory.deinit();
        self.storage.deinit();
    }
};

test "EvmStack operations" {
    var stack = EvmStack.init();
    try std.testing.expectEqual(@as(usize, 0), stack.depth());

    try stack.push(EVMu256.fromU64(10));
    try stack.push(EVMu256.fromU64(20));
    try std.testing.expectEqual(@as(usize, 2), stack.depth());

    try stack.dup(2);
    try std.testing.expect((try stack.pop()).eql(EVMu256.fromU64(10)));
    try stack.swap(1);
    try std.testing.expect((try stack.pop()).eql(EVMu256.fromU64(10)));
    try std.testing.expect((try stack.pop()).eql(EVMu256.fromU64(20)));
    try std.testing.expectError(error.StackUnderflow, stack.pop());

    for (0..1024) |i| try stack.push(EVMu256.fromU64(@intCast(i)));
    try std.testing.expectError(error.StackOverflow, stack.push(EVMu256.fromU64(1025)));
}

test "EvmMemory operations" {
    var memory = EvmMemory.init(std.testing.allocator);
    defer memory.deinit();

    const value = EVMu256{
        .hi = 0x0123456789abcdef_fedcba9876543210,
        .lo = 0x0011223344556677_8899aabbccddeeff,
    };
    try memory.store32(0, value);
    try std.testing.expect((try memory.load32(0)).eql(value));
    try std.testing.expectEqual(@as(usize, 32), memory.data.items.len);

    const unwritten = try memory.load32(100);
    try std.testing.expect(unwritten.eql(EVMu256.zero()));
    try std.testing.expectEqual(@as(usize, 160), memory.data.items.len);
}

test "EvmStorage operations" {
    var storage = EvmStorage.init(std.testing.allocator);
    defer storage.deinit();

    const key1 = EVMu256.fromU64(1);
    const key2 = EVMu256.fromU64(2);
    try std.testing.expect(storage.load(key1).eql(EVMu256.zero()));
    try storage.store(key1, EVMu256.fromU64(100));
    try storage.store(key2, EVMu256.fromU64(200));
    try std.testing.expect(storage.load(key1).eql(EVMu256.fromU64(100)));
    try std.testing.expect(storage.load(key2).eql(EVMu256.fromU64(200)));
    try storage.store(key1, EVMu256.fromU64(300));
    try std.testing.expect(storage.load(key1).eql(EVMu256.fromU64(300)));
}

test "EvmContext initialization" {
    const code = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01 };
    const calldata = [_]u8{ 0xaa, 0xbb };
    var context = EvmContext.init(std.testing.allocator, &code, &calldata);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.pc);
    try std.testing.expectEqual(@as(u8, 0), context.depth);
    try std.testing.expect(!context.stopped);
    try std.testing.expect(context.error_msg == null);
    try std.testing.expectEqualSlices(u8, &code, context.code);
    try std.testing.expectEqualSlices(u8, &calldata, context.calldata);
    try std.testing.expectEqual(@as(usize, 0), context.stack.depth());
    try std.testing.expectEqual(@as(usize, 0), context.memory.data.items.len);
    try std.testing.expectEqual(@as(usize, 0), context.returndata.items.len);
}
