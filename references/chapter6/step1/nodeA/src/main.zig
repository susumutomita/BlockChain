const std = @import("std");

pub fn main() !void {
    // 1. サーバノードとしてソケットを開く (ポート8080で待ち受け)
    var server_addr = try std.net.Address.resolveIp("0.0.0.0", 8080);
    var listener = try server_addr.listen(.{}); // リッスン開始 ([how to set up a zig tcp server socket - Stack Overflow](https://stackoverflow.com/questions/78125709/how-to-set-up-a-zig-tcp-server-socket#:~:text=const%20addr%20%3D%20std.net.Address.initIp4%28.,listen))
    defer listener.deinit(); // プログラム終了時にクローズ

    std.log.info("ノードA: ポート8080で待機中...", .{});

    // 2. 新規接続を受け付ける
    const connection = try listener.accept();
    defer connection.stream.close(); // 接続ストリームをクローズ
    std.log.info("ノードA: 新しい接続を受け付けました: {any}", .{connection.address});

    // 3. 相手からのメッセージを読み取る
    const reader = connection.stream.reader();
    var buffer: [256]u8 = undefined;
    const bytes_read = try reader.readAll(&buffer);
    std.log.info("ノードA: 受信したメッセージ: {} バイト", .{bytes_read});

    // 受信したメッセージの内容を表示
    const message = buffer[0..bytes_read];
    std.log.info("ノードA: メッセージ内容: {s}", .{message});
}
