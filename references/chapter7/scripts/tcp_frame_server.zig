const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 3) {
        std.log.err("usage: {s} <port> <block-json-file>", .{args[0]});
        return error.InvalidArguments;
    }

    const port = try std.fmt.parseInt(u16, args[1], 10);
    const file = try std.fs.cwd().openFile(args[2], .{});
    defer file.close();
    const file_contents = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(file_contents);
    const block_json = std.mem.trim(u8, file_contents, "\r\n");
    if (block_json.len == 0) return error.EmptyBlockJson;

    var address = try std.net.Address.resolveIp("0.0.0.0", port);
    var listener = try address.listen(.{});
    defer listener.deinit();
    std.log.info("TCP_FRAME_SERVER_READY port={d}", .{port});

    const connection = try listener.accept();
    defer connection.stream.close();
    var writer = connection.stream.writer();

    // 1つ目のフレームはprefixの途中で分割する。待機を入れ、受信側の
    // 最初のreadが「BLO」だけで戻る状態を意図的に作る。
    try writer.writeAll("BLO");
    std.time.sleep(250 * std.time.ns_per_ms);
    try writer.writeAll("CK:");
    try writer.writeAll(block_json);
    try writer.writeAll("\n");
    std.log.info("TCP_SPLIT_FRAME_SENT", .{});

    // 残り2フレームは1つのbufferに連結し、1回のwriteAllで送信する。
    var combined = std.ArrayList(u8).init(allocator);
    defer combined.deinit();
    try combined.writer().print("BLOCK:{s}\nBLOCK:{s}\n", .{ block_json, block_json });
    try writer.writeAll(combined.items);
    std.log.info("TCP_COALESCED_FRAMES_SENT", .{});
}
