// Debug logging utility for p2p.zig
// このファイルをインポートするとp2p.zigの関数に行番号付きロギングを追加します

const std = @import("std");

/// ログメッセージにファイル名と行番号を追加するヘルパー関数
pub fn logWithLocation(
    comptime level: std.log.Level,
    comptime message: []const u8,
    args: anytype,
    file: []const u8,
    line: u32,
) void {
    std.log.defaultLog(
        level,
        "[{s}:{d}] " ++ message,
        .{file, line} ++ args,
    );
}

/// ログメッセージに行番号を追加するマクロ
pub fn debugLog(
    comptime level: std.log.Level,
    comptime format: []const u8,
    args: anytype,
) void {
    const src = @src();
    logWithLocation(level, format, args, src.file, src.line);
}

/// EVMトランザクション処理の詳細なロギングヘルパー
pub fn logEvmTxProcessing(msg_type: []const u8, step: []const u8, details: anytype) void {
    const src = @src();
    std.log.info("[EVM_TX][{s}][行:{d}] {s}: {any}", .{msg_type, src.line, step, details});
}

/// パース処理のロギング
pub fn logParsing(stage: []const u8, details: anytype) void {
    const src = @src();
    std.log.info("[解析][行:{d}] {s}: {any}", .{src.line, stage, details});
}

/// シリアライズ処理のロギング
pub fn logSerializing(stage: []const u8, details: anytype) void {
    const src = @src();
    std.log.info("[シリアライズ][行:{d}] {s}: {any}", .{src.line, stage, details});
}

/// エラーロギング（行番号付き）
pub fn logError(msg: []const u8, err: anytype) void {
    const src = @src();
    std.log.err("[エラー][行:{d}] {s}: {any}", .{src.line, msg, err});
}

/// 入力データのログ
pub fn logData(name: []const u8, data: []const u8) void {
    if (data.len < 256) {
        // 短いデータは全て表示
        std.log.debug("[データ] {s}: {s}", .{name, data});
    } else {
        // 長いデータは先頭と末尾のみ表示
        std.log.debug("[データ] {s}: 長さ={d}バイト, 先頭={s}...", .{name, data.len, data[0..32]});
    }
}
