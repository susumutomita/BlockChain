const std = @import("std");

pub fn main() !void {
    // ノードB: ノードA（localhost:8080）へ接続しメッセージ送信
    const remote_addr = try std.net.Address.resolveIp("127.0.0.1", 8080);
    var socket = try std.net.tcpConnectToAddress(remote_addr); // 接続 ([Zig Common Tasks](https://renatoathaydes.github.io/zig-common-tasks/#:~:text=pub%20fn%20main%28%29%20%21void%20,%7D))
    defer socket.close();

    const message = "Hello from NodeB\n";
    const writer = socket.writer();
    std.log.info("ノードB: 送信メッセージ: {s}", .{message});
    try writer.writeAll(message);
    std.log.info("ノードB: メッセージの送信が完了しました", .{});
}
