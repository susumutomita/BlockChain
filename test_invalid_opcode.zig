const std = @import("std");
const evm = @import("evm.zig");
const EVMu256 = @import("evm_types.zig").EVMu256;

pub fn main() !void {
    // アロケータ初期化
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 無効なオペコードを含むテストバイトコード
    const invalid_bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x01, // ADD (通常操作)
        0xA1, // 無効なオペコード (0xA1)
        0x60, 0x00, // PUSH1 0 (到達されない)
    };

    // 詳細エラー情報付きで実行
    const result = evm.executeWithErrorInfo(allocator, &invalid_bytecode, &[_]u8{}, 100000);
    defer if (result.data.len > 0) allocator.free(result.data);
    defer if (result.error_message != null) allocator.free(result.error_message.?);

    // 結果を出力
    std.debug.print("実行成功: {}\n", .{result.success});

    if (!result.success) {
        std.debug.print("エラータイプ: {any}\n", .{result.error_type});
        std.debug.print("エラー位置(PC): {?d}\n", .{result.error_pc});
        std.debug.print("エラーメッセージ: {s}\n", .{result.error_message orelse "メッセージなし"});
    } else {
        std.debug.print("実行結果データ長: {d} バイト\n", .{result.data.len});
        // データの16進数表示（最大32バイトまで）
        const display_len = @min(32, result.data.len);
        for (0..display_len) |i| {
            std.debug.print("{x:0>2} ", .{result.data[i]});
        }
        std.debug.print("\n", .{});
    }
}
