//! Ethereum Virtual Machine (EVM) 実装
//!
//! EVMバイトコードを解析・実行する学習用スタックマシンです。

const std = @import("std");
const evm_types = @import("evm_types.zig");
const EVMu256 = evm_types.EVMu256;
const EvmContext = evm_types.EvmContext;

pub const Opcode = struct {
    pub const STOP = 0x00;
    pub const RETURN = 0xF3;
    pub const REVERT = 0xFD;

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
    pub const SHL = 0x1B;
    pub const SHR = 0x1C;
    pub const SAR = 0x1D;
    pub const POP = 0x50;

    pub const MLOAD = 0x51;
    pub const MSTORE = 0x52;
    pub const MSTORE8 = 0x53;
    pub const SLOAD = 0x54;
    pub const SSTORE = 0x55;

    pub const JUMP = 0x56;
    pub const JUMPI = 0x57;
    pub const PC = 0x58;
    pub const PUSH0 = 0x5F;
    pub const JUMPDEST = 0x5B;
    pub const PUSH1 = 0x60;
    pub const DUP1 = 0x80;
    pub const SWAP1 = 0x90;

    pub const CALLVALUE = 0x34;
    pub const CALLDATALOAD = 0x35;
    pub const CALLDATASIZE = 0x36;
    pub const CALLDATACOPY = 0x37;
    pub const CODESIZE = 0x38;
    pub const CODECOPY = 0x39;
    pub const RETURNDATASIZE = 0x3D;
    pub const RETURNDATACOPY = 0x3E;
};

pub const EVMError = error{
    OutOfGas,
    StackOverflow,
    StackUnderflow,
    InvalidJump,
    InvalidOpcode,
    MemoryOutOfBounds,
    Revert,
};

pub fn execute(
    allocator: std.mem.Allocator,
    code: []const u8,
    calldata: []const u8,
    gas_limit: usize,
) ![]const u8 {
    var context = EvmContext.init(allocator, code, calldata);
    context.gas = gas_limit;
    defer context.deinit();

    while (context.pc < context.code.len and !context.stopped) {
        try executeStep(&context);
    }

    const result = try allocator.alloc(u8, context.returndata.items.len);
    @memcpy(result, context.returndata.items);
    return result;
}

/// EVM実行の成功可否に加え、失敗した命令位置とエラー種別を返す。
pub const EvmExecutionResult = struct {
    success: bool,
    data: []const u8,
    error_message: ?[]const u8,
    error_type: ?EVMError,
    error_pc: ?usize,
};

pub fn executeWithErrorInfo(
    allocator: std.mem.Allocator,
    code: []const u8,
    calldata: []const u8,
    gas_limit: usize,
) EvmExecutionResult {
    var context = EvmContext.init(allocator, code, calldata);
    context.gas = gas_limit;
    defer context.deinit();

    var result = EvmExecutionResult{
        .success = false,
        .data = &[_]u8{},
        .error_message = null,
        .error_type = null,
        .error_pc = null,
    };

    while (context.pc < context.code.len and !context.stopped) {
        executeStep(&context) catch |err| {
            result.error_type = switch (err) {
                EVMError.OutOfGas => EVMError.OutOfGas,
                EVMError.StackOverflow => EVMError.StackOverflow,
                EVMError.StackUnderflow => EVMError.StackUnderflow,
                EVMError.InvalidJump => EVMError.InvalidJump,
                EVMError.InvalidOpcode => EVMError.InvalidOpcode,
                EVMError.MemoryOutOfBounds => EVMError.MemoryOutOfBounds,
                EVMError.Revert => EVMError.Revert,
                else => EVMError.InvalidOpcode,
            };
            result.error_pc = context.pc;
            if (context.error_msg) |message| {
                result.error_message = allocator.dupe(u8, message) catch null;
            } else {
                result.error_message = std.fmt.allocPrint(
                    allocator,
                    "EVM実行エラー: {s} at PC={d}",
                    .{ @errorName(err), context.pc },
                ) catch null;
            }
            return result;
        };
    }

    result.data = allocator.dupe(u8, context.returndata.items) catch return result;
    result.success = true;
    return result;
}

fn logicalShiftLeft(value: EVMu256, shift: EVMu256) EVMu256 {
    if (shift.hi != 0 or shift.lo >= 256) return EVMu256.zero();
    const amount: u8 = @intCast(shift.lo);
    if (amount == 0) return value;
    if (amount < 128) {
        const right: u7 = @intCast(128 - amount);
        const left: u7 = @intCast(amount);
        return .{
            .hi = (value.hi << left) | (value.lo >> right),
            .lo = value.lo << left,
        };
    }
    if (amount == 128) return .{ .hi = value.lo, .lo = 0 };
    const left: u7 = @intCast(amount - 128);
    return .{ .hi = value.lo << left, .lo = 0 };
}

fn logicalShiftRight(value: EVMu256, shift: EVMu256) EVMu256 {
    if (shift.hi != 0 or shift.lo >= 256) return EVMu256.zero();
    const amount: u8 = @intCast(shift.lo);
    if (amount == 0) return value;
    if (amount < 128) {
        const right: u7 = @intCast(amount);
        const left: u7 = @intCast(128 - amount);
        return .{
            .hi = value.hi >> right,
            .lo = (value.lo >> right) | (value.hi << left),
        };
    }
    if (amount == 128) return .{ .hi = 0, .lo = value.hi };
    const right: u7 = @intCast(amount - 128);
    return .{ .hi = 0, .lo = value.hi >> right };
}

fn arithmeticShiftRight(value: EVMu256, shift: EVMu256) EVMu256 {
    const negative = (value.hi & (@as(u128, 1) << 127)) != 0;
    const fill: u128 = if (negative) std.math.maxInt(u128) else 0;
    if (shift.hi != 0 or shift.lo >= 256) return .{ .hi = fill, .lo = fill };

    const amount: u8 = @intCast(shift.lo);
    if (amount == 0) return value;
    if (amount < 128) {
        const right: u7 = @intCast(amount);
        const left: u7 = @intCast(128 - amount);
        const sign_mask: u128 = if (negative)
            @as(u128, std.math.maxInt(u128)) << left
        else
            0;
        return .{
            .hi = (value.hi >> right) | sign_mask,
            .lo = (value.lo >> right) | (value.hi << left),
        };
    }
    if (amount == 128) return .{ .hi = fill, .lo = value.hi };

    const right: u7 = @intCast(amount - 128);
    const left: u7 = @intCast(256 - @as(u16, amount));
    const sign_mask: u128 = if (negative)
        @as(u128, std.math.maxInt(u128)) << left
    else
        0;
    return .{
        .hi = fill,
        .lo = (value.hi >> right) | sign_mask,
    };
}

fn executeStep(context: *EvmContext) !void {
    const opcode = context.code[context.pc];
    if (context.gas < 1) {
        context.error_msg = "Out of gas";
        return EVMError.OutOfGas;
    }
    context.gas -= 1;

    switch (opcode) {
        Opcode.STOP => context.stopped = true,
        Opcode.ADD => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const a = try context.stack.pop();
            const b = try context.stack.pop();
            try context.stack.push(a.add(b));
            context.pc += 1;
        },
        Opcode.MUL => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const a = try context.stack.pop();
            const b = try context.stack.pop();
            try context.stack.push(a.mul(b));
            context.pc += 1;
        },
        Opcode.SUB => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const a = try context.stack.pop();
            const b = try context.stack.pop();
            try context.stack.push(a.sub(b));
            context.pc += 1;
        },
        Opcode.DIV => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const a = try context.stack.pop();
            const b = try context.stack.pop();
            if (b.hi == 0 and b.lo == 0) {
                try context.stack.push(EVMu256.zero());
            } else if (a.hi == 0 and b.hi == 0) {
                try context.stack.push(EVMu256.fromU64(@intCast(a.lo / b.lo)));
            } else {
                try context.stack.push(EVMu256.zero());
            }
            context.pc += 1;
        },
        Opcode.MOD => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const a = try context.stack.pop();
            const b = try context.stack.pop();
            if (b.hi == 0 and b.lo == 0) {
                try context.stack.push(EVMu256.zero());
            } else if (a.hi == 0 and b.hi == 0) {
                try context.stack.push(EVMu256.fromU64(@intCast(a.lo % b.lo)));
            } else {
                try context.stack.push(EVMu256.zero());
            }
            context.pc += 1;
        },
        Opcode.PUSH1 => {
            if (context.pc + 1 >= context.code.len) return EVMError.InvalidOpcode;
            try context.stack.push(EVMu256.fromU64(context.code[context.pc + 1]));
            context.pc += 2;
        },
        Opcode.DUP1 => {
            if (context.stack.depth() < 1) return EVMError.StackUnderflow;
            try context.stack.push(context.stack.data[context.stack.sp - 1]);
            context.pc += 1;
        },
        Opcode.SWAP1 => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const a = context.stack.data[context.stack.sp - 1];
            const b = context.stack.data[context.stack.sp - 2];
            context.stack.data[context.stack.sp - 1] = b;
            context.stack.data[context.stack.sp - 2] = a;
            context.pc += 1;
        },
        Opcode.POP => {
            if (context.stack.depth() < 1) return EVMError.StackUnderflow;
            _ = try context.stack.pop();
            context.pc += 1;
        },
        Opcode.MLOAD => {
            if (context.stack.depth() < 1) return EVMError.StackUnderflow;
            const offset = try context.stack.pop();
            if (offset.hi != 0) return EVMError.MemoryOutOfBounds;
            try context.stack.push(try context.memory.load32(@intCast(offset.lo)));
            context.pc += 1;
        },
        Opcode.MSTORE => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const offset = try context.stack.pop();
            const value = try context.stack.pop();
            if (offset.hi != 0) return EVMError.MemoryOutOfBounds;
            try context.memory.store32(@intCast(offset.lo), value);
            context.pc += 1;
        },
        Opcode.SLOAD => {
            if (context.stack.depth() < 1) return EVMError.StackUnderflow;
            try context.stack.push(context.storage.load(try context.stack.pop()));
            context.pc += 1;
        },
        Opcode.SSTORE => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const key = try context.stack.pop();
            const value = try context.stack.pop();
            try context.storage.store(key, value);
            context.pc += 1;
        },
        Opcode.CALLDATALOAD => {
            if (context.stack.depth() < 1) return EVMError.StackUnderflow;
            const offset = try context.stack.pop();
            if (offset.hi != 0) return EVMError.MemoryOutOfBounds;
            var result = EVMu256.zero();
            const off = @as(usize, @intCast(offset.lo));
            for (0..32) |i| {
                const byte_pos = off + i;
                if (byte_pos < context.calldata.len) {
                    const byte_val = context.calldata[byte_pos];
                    if (i < 16) {
                        result.hi |= @as(u128, byte_val) << @intCast((15 - i) * 8);
                    } else {
                        result.lo |= @as(u128, byte_val) << @intCast((31 - i) * 8);
                    }
                }
            }
            try context.stack.push(result);
            context.pc += 1;
        },
        Opcode.CALLDATASIZE => {
            try context.stack.push(EVMu256.fromU64(@intCast(context.calldata.len)));
            context.pc += 1;
        },
        Opcode.CALLDATACOPY => {
            if (context.stack.depth() < 3) return EVMError.StackUnderflow;
            const mem_offset = try context.stack.pop();
            const data_offset = try context.stack.pop();
            const length = try context.stack.pop();
            if (mem_offset.hi != 0 or data_offset.hi != 0 or length.hi != 0) return EVMError.MemoryOutOfBounds;
            const mem_off = @as(usize, @intCast(mem_offset.lo));
            const data_off = @as(usize, @intCast(data_offset.lo));
            const len = @as(usize, @intCast(length.lo));
            try context.memory.ensureSize(mem_off + len);
            for (0..len) |i| {
                context.memory.data.items[mem_off + i] = if (data_off + i < context.calldata.len)
                    context.calldata[data_off + i]
                else
                    0;
            }
            context.pc += 1;
        },
        Opcode.CODESIZE => {
            try context.stack.push(EVMu256.fromU64(@intCast(context.code.len)));
            context.pc += 1;
        },
        Opcode.CODECOPY => {
            if (context.stack.depth() < 3) return EVMError.StackUnderflow;
            const mem_offset = try context.stack.pop();
            const code_offset = try context.stack.pop();
            const length = try context.stack.pop();
            if (mem_offset.hi != 0 or code_offset.hi != 0 or length.hi != 0) return EVMError.MemoryOutOfBounds;
            const mem_off = @as(usize, @intCast(mem_offset.lo));
            const code_off = @as(usize, @intCast(code_offset.lo));
            const len = @as(usize, @intCast(length.lo));
            try context.memory.ensureSize(mem_off + len);
            for (0..len) |i| {
                context.memory.data.items[mem_off + i] = if (code_off + i < context.code.len)
                    context.code[code_off + i]
                else
                    0;
            }
            context.pc += 1;
        },
        Opcode.RETURNDATASIZE, Opcode.CALLVALUE => {
            try context.stack.push(EVMu256.zero());
            context.pc += 1;
        },
        Opcode.EQ => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const a = try context.stack.pop();
            const b = try context.stack.pop();
            try context.stack.push(EVMu256.fromU64(if (a.eql(b)) 1 else 0));
            context.pc += 1;
        },
        Opcode.LT => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const a = try context.stack.pop();
            const b = try context.stack.pop();
            const value: u64 = if (a.hi < b.hi or (a.hi == b.hi and a.lo < b.lo)) 1 else 0;
            try context.stack.push(EVMu256.fromU64(value));
            context.pc += 1;
        },
        Opcode.GT => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const a = try context.stack.pop();
            const b = try context.stack.pop();
            const value: u64 = if (a.hi > b.hi or (a.hi == b.hi and a.lo > b.lo)) 1 else 0;
            try context.stack.push(EVMu256.fromU64(value));
            context.pc += 1;
        },
        Opcode.ISZERO => {
            if (context.stack.depth() < 1) return EVMError.StackUnderflow;
            const value: u64 = if ((try context.stack.pop()).isZero()) 1 else 0;
            try context.stack.push(EVMu256.fromU64(value));
            context.pc += 1;
        },
        Opcode.AND => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const a = try context.stack.pop();
            const b = try context.stack.pop();
            try context.stack.push(.{ .hi = a.hi & b.hi, .lo = a.lo & b.lo });
            context.pc += 1;
        },
        Opcode.OR => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const a = try context.stack.pop();
            const b = try context.stack.pop();
            try context.stack.push(.{ .hi = a.hi | b.hi, .lo = a.lo | b.lo });
            context.pc += 1;
        },
        Opcode.XOR => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const a = try context.stack.pop();
            const b = try context.stack.pop();
            try context.stack.push(.{ .hi = a.hi ^ b.hi, .lo = a.lo ^ b.lo });
            context.pc += 1;
        },
        Opcode.NOT => {
            if (context.stack.depth() < 1) return EVMError.StackUnderflow;
            const a = try context.stack.pop();
            try context.stack.push(.{ .hi = ~a.hi, .lo = ~a.lo });
            context.pc += 1;
        },
        Opcode.SHL => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const shift = try context.stack.pop();
            const value = try context.stack.pop();
            try context.stack.push(logicalShiftLeft(value, shift));
            context.pc += 1;
        },
        Opcode.SHR => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const shift = try context.stack.pop();
            const value = try context.stack.pop();
            try context.stack.push(logicalShiftRight(value, shift));
            context.pc += 1;
        },
        Opcode.SAR => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const shift = try context.stack.pop();
            const value = try context.stack.pop();
            try context.stack.push(arithmeticShiftRight(value, shift));
            context.pc += 1;
        },
        Opcode.JUMPDEST => context.pc += 1,
        Opcode.JUMP => {
            if (context.stack.depth() < 1) return EVMError.StackUnderflow;
            const dest = try context.stack.pop();
            if (dest.hi != 0) return EVMError.InvalidJump;
            const jump_dest = @as(usize, @intCast(dest.lo));
            if (jump_dest >= context.code.len or context.code[jump_dest] != Opcode.JUMPDEST) return EVMError.InvalidJump;
            context.pc = jump_dest;
        },
        Opcode.JUMPI => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const dest = try context.stack.pop();
            const condition = try context.stack.pop();
            if (!condition.isZero()) {
                if (dest.hi != 0) return EVMError.InvalidJump;
                const jump_dest = @as(usize, @intCast(dest.lo));
                if (jump_dest >= context.code.len or context.code[jump_dest] != Opcode.JUMPDEST) return EVMError.InvalidJump;
                context.pc = jump_dest;
            } else {
                context.pc += 1;
            }
        },
        Opcode.RETURN => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            const offset = try context.stack.pop();
            const length = try context.stack.pop();
            if (offset.hi != 0 or length.hi != 0) return EVMError.MemoryOutOfBounds;
            const off = @as(usize, @intCast(offset.lo));
            const len = @as(usize, @intCast(length.lo));
            try context.memory.ensureSize(off + len);
            if (len > 0) {
                try context.returndata.resize(len);
                for (0..len) |i| context.returndata.items[i] = context.memory.data.items[off + i];
            }
            context.stopped = true;
        },
        Opcode.REVERT => {
            if (context.stack.depth() < 2) return EVMError.StackUnderflow;
            context.stopped = true;
            return EVMError.Revert;
        },
        else => {
            if (opcode >= 0x5F and opcode <= 0x7F) {
                const push_bytes = opcode - 0x5F;
                var value = EVMu256.zero();
                if (context.pc + push_bytes + 1 > context.code.len) {
                    context.error_msg = "コード範囲外のPUSH操作";
                    return EVMError.InvalidOpcode;
                }
                for (0..push_bytes) |i| {
                    const byte = context.code[context.pc + 1 + i];
                    if (push_bytes <= 16) {
                        const shift = @as(u7, @intCast(8 * (push_bytes - 1 - i)));
                        value.lo |= @as(u128, byte) << shift;
                    } else if (i < push_bytes - 16) {
                        const shift = @as(u7, @intCast(8 * (push_bytes - 17 - i)));
                        value.hi |= @as(u128, byte) << shift;
                    } else {
                        const shift = @as(u7, @intCast(8 * (push_bytes - 1 - i)));
                        value.lo |= @as(u128, byte) << shift;
                    }
                }
                try context.stack.push(value);
                context.pc += push_bytes + 1;
            } else if (opcode >= 0x80 and opcode <= 0x8F) {
                const dup_index = opcode - 0x7F;
                if (context.stack.depth() < dup_index) return EVMError.StackUnderflow;
                try context.stack.push(context.stack.data[context.stack.sp - dup_index]);
                context.pc += 1;
            } else if (opcode >= 0x90 and opcode <= 0x9F) {
                const swap_index = opcode - 0x8F;
                if (context.stack.depth() < swap_index + 1) return EVMError.StackUnderflow;
                const top = context.stack.sp - 1;
                const other = context.stack.sp - 1 - swap_index;
                const temp = context.stack.data[top];
                context.stack.data[top] = context.stack.data[other];
                context.stack.data[other] = temp;
                context.pc += 1;
            } else {
                context.error_msg = "未実装または無効なオペコード";
                return EVMError.InvalidOpcode;
            }
        },
    }
}

pub fn disassemble(code: []const u8, writer: anytype) !void {
    var pc: usize = 0;
    while (pc < code.len) {
        const opcode = code[pc];
        try writer.print("0x{x:0>4}: ", .{pc});
        switch (opcode) {
            Opcode.STOP => try writer.print("STOP", .{}),
            Opcode.ADD => try writer.print("ADD", .{}),
            Opcode.MUL => try writer.print("MUL", .{}),
            Opcode.SUB => try writer.print("SUB", .{}),
            Opcode.DIV => try writer.print("DIV", .{}),
            Opcode.MLOAD => try writer.print("MLOAD", .{}),
            Opcode.MSTORE => try writer.print("MSTORE", .{}),
            Opcode.SLOAD => try writer.print("SLOAD", .{}),
            Opcode.SSTORE => try writer.print("SSTORE", .{}),
            Opcode.JUMP => try writer.print("JUMP", .{}),
            Opcode.JUMPI => try writer.print("JUMPI", .{}),
            Opcode.JUMPDEST => try writer.print("JUMPDEST", .{}),
            Opcode.RETURN => try writer.print("RETURN", .{}),
            Opcode.PUSH1 => {
                if (pc + 1 < code.len) {
                    try writer.print("PUSH1 0x{x:0>2}", .{code[pc + 1]});
                    pc += 1;
                } else {
                    try writer.print("PUSH1 <データ不足>", .{});
                }
            },
            Opcode.DUP1 => try writer.print("DUP1", .{}),
            Opcode.SWAP1 => try writer.print("SWAP1", .{}),
            Opcode.CALLDATALOAD => try writer.print("CALLDATALOAD", .{}),
            else => {
                if (opcode >= 0x60 and opcode <= 0x7F) {
                    const push_bytes = opcode - 0x5F;
                    if (pc + push_bytes < code.len) {
                        try writer.print("PUSH{d} ", .{push_bytes});
                        for (0..push_bytes) |i| try writer.print("0x{x:0>2}", .{code[pc + 1 + i]});
                        pc += push_bytes;
                    } else {
                        try writer.print("PUSH{d} <データ不足>", .{push_bytes});
                        pc = code.len;
                    }
                } else if (opcode >= 0x80 and opcode <= 0x8F) {
                    try writer.print("DUP{d}", .{opcode - 0x7F});
                } else if (opcode >= 0x90 and opcode <= 0x9F) {
                    try writer.print("SWAP{d}", .{opcode - 0x8F});
                } else {
                    try writer.print("UNKNOWN 0x{x:0>2}", .{opcode});
                }
            },
        }
        try writer.print("\n", .{});
        pc += 1;
    }
}

test "Simple EVM execution" {
    const bytecode = [_]u8{
        0x60, 0x05, 0x60, 0x03, 0x01,
        0x60, 0x00, 0x52, 0x60, 0x20,
        0x60, 0x00, 0xf3,
    };
    const result = try execute(std.testing.allocator, &bytecode, &.{}, 100_000);
    defer std.testing.allocator.free(result);
    try std.testing.expect(EVMu256.fromBytes(result).eql(EVMu256.fromU64(8)));
}

test "EVM multiplication" {
    const bytecode = [_]u8{
        0x60, 0x07, 0x60, 0x06, 0x02,
        0x60, 0x00, 0x52, 0x60, 0x20,
        0x60, 0x00, 0xf3,
    };
    const result = try execute(std.testing.allocator, &bytecode, &.{}, 100_000);
    defer std.testing.allocator.free(result);
    try std.testing.expect(EVMu256.fromBytes(result).eql(EVMu256.fromU64(42)));
}

test "EVM storage operations" {
    const bytecode = [_]u8{
        0x60, 0x2A, 0x60, 0x01, 0x55,
        0x60, 0x01, 0x54, 0x60, 0x00,
        0x52, 0x60, 0x20, 0x60, 0x00,
        0xf3,
    };
    const result = try execute(std.testing.allocator, &bytecode, &.{}, 100_000);
    defer std.testing.allocator.free(result);
    try std.testing.expect(EVMu256.fromBytes(result).eql(EVMu256.fromU64(42)));
}

test "EVM multiple operations" {
    const bytecode = [_]u8{
        0x60, 0x0A, 0x60, 0x0B, 0x01,
        0x60, 0x03, 0x02, 0x60, 0x02,
        0x90, 0x04, 0x60, 0x00, 0x52,
        0x60, 0x20, 0x60, 0x00, 0xf3,
    };
    const result = try execute(std.testing.allocator, &bytecode, &.{}, 100_000);
    defer std.testing.allocator.free(result);
    try std.testing.expect(EVMu256.fromBytes(result).eql(EVMu256.fromU64(31)));
}

test "ABI calldataでadd関数を実行" {
    const marker = EVMu256{ .hi = 1, .lo = 2 };
    const high_bit = EVMu256{ .hi = @as(u128, 1) << 127, .lo = 0 };
    try std.testing.expect(logicalShiftRight(marker, EVMu256.zero()).eql(marker));
    try std.testing.expect(logicalShiftLeft(EVMu256.one(), EVMu256.fromU64(127)).eql(.{
        .hi = 0,
        .lo = @as(u128, 1) << 127,
    }));
    try std.testing.expect(logicalShiftRight(high_bit, EVMu256.fromU64(127)).eql(.{ .hi = 1, .lo = 0 }));
    try std.testing.expect(logicalShiftRight(marker, EVMu256.fromU64(128)).eql(.{ .hi = 0, .lo = 1 }));
    try std.testing.expect(logicalShiftLeft(marker, EVMu256.fromU64(128)).eql(.{ .hi = 2, .lo = 0 }));
    try std.testing.expect(logicalShiftRight(high_bit, EVMu256.fromU64(255)).eql(EVMu256.one()));
    try std.testing.expect(logicalShiftRight(marker, EVMu256.fromU64(256)).eql(EVMu256.zero()));

    const runtime_bytecode = [_]u8{
        0x60, 0x00, 0x35,
        0x60, 0xe0, 0x1c,
        0x63, 0x77, 0x16,
        0x02, 0xf7, 0x14,
        0x60, 0x10, 0x57,
        0x00, 0x5b, 0x60,
        0x04, 0x35, 0x60,
        0x24, 0x35, 0x01,
        0x60, 0x00, 0x52,
        0x60, 0x20, 0x60,
        0x00, 0xf3,
    };

    var calldata = [_]u8{0} ** 68;
    @memcpy(calldata[0..4], &[_]u8{ 0x77, 0x16, 0x02, 0xf7 });
    calldata[35] = 5;
    calldata[67] = 3;

    const result = try execute(std.testing.allocator, &runtime_bytecode, &calldata, 100_000);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 32), result.len);
    for (result[0..31]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectEqual(@as(u8, 8), result[31]);

    calldata[0] = 0;
    const rejected = try execute(std.testing.allocator, &runtime_bytecode, &calldata, 100_000);
    defer std.testing.allocator.free(rejected);
    try std.testing.expectEqual(@as(usize, 0), rejected.len);
}

test "EVM execution with error info" {
    const invalid_bytecode = [_]u8{0xfe};
    const result = executeWithErrorInfo(
        std.testing.allocator,
        &invalid_bytecode,
        &.{},
        100_000,
    );
    defer if (result.error_message) |message| std.testing.allocator.free(message);

    try std.testing.expect(!result.success);
    try std.testing.expectEqual(EVMError.InvalidOpcode, result.error_type.?);
    try std.testing.expectEqual(@as(usize, 0), result.error_pc.?);
    try std.testing.expect(result.error_message != null);
}
