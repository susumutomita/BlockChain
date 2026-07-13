const std = @import("std");

/// ノード情報を表す構造体
/// - address: 相手ノードのIPアドレスとポート
/// - stream: 接続済みのTCPストリーム
const Peer = struct {
    address: std.net.Address,
    stream: std.net.Stream,
};

/// ピアリスト
/// ここでは最大10ノードまで接続する簡易実装
const MAX_PEERS = 10;
var peers: [MAX_PEERS]?Peer = [_]?Peer{null ** MAX_PEERS};

/// 受信を処理するスレッド関数 (スレッドに渡すためにstruct + run関数を定義)
const ConnHandler = struct {
    fn handleMessage(conn: std.net.Server.Connection, message: []const u8) !void {
        if (!std.mem.startsWith(u8, message, "MSG:")) {
            std.log.warn("Unknown message from {any}: {s}", .{ conn.address, message });
            return;
        }

        const payload = message[4..];
        std.log.info("[Received from {any}] {s}", .{ conn.address, payload });

        var writer = conn.stream.writer();
        try writer.writeAll("ACK:");
        try writer.writeAll(payload);
        try writer.writeAll("\n");
        std.log.info("[Sent to {any}] ACK:{s}", .{ conn.address, payload });
    }

    fn run(conn: std.net.Server.Connection) !void {
        defer conn.stream.close(); // 接続が終わったらクローズ
        var reader = conn.stream.reader();

        std.log.info("Accepted a new connection from {any}", .{conn.address});
        var buf: [4096]u8 = undefined;
        var buffered: usize = 0;

        while (true) {
            const n = try reader.read(buf[buffered..]);
            if (n == 0) {
                std.log.info("Peer {any} disconnected.", .{conn.address});
                break;
            }

            buffered += n;
            var consumed: usize = 0;
            while (std.mem.indexOfScalarPos(u8, buf[0..buffered], consumed, '\n')) |newline| {
                const message = std.mem.trimRight(u8, buf[consumed..newline], "\r");
                try handleMessage(conn, message);
                consumed = newline + 1;
            }

            if (consumed > 0) {
                const remaining = buffered - consumed;
                std.mem.copyForwards(u8, buf[0..remaining], buf[consumed..buffered]);
                buffered = remaining;
            }

            if (buffered == buf.len) {
                std.log.warn("Message too long from {any}; closing connection", .{conn.address});
                break;
            }
        }
    }
};

/// 相手への送信専用スレッド (クライアントとしての送信用)
/// ユーザーがコンソールに入力した文字列を送信する
const SendHandler = struct {
    fn run(peer: Peer) !void {
        // 読み取りはメインスレッドが担当するため、終了時は送信側だけを閉じる。
        defer std.posix.shutdown(peer.stream.handle, .send) catch {};
        std.log.info("Connected to peer {any}", .{peer.address});

        var stdin_file = std.io.getStdIn();
        const reader = stdin_file.reader();

        while (true) {
            std.log.info("Type message (Ctrl+D to exit): ", .{});
            var line_buffer: [256]u8 = undefined;
            const maybe_line = try reader.readUntilDelimiterOrEof(line_buffer[0..], '\n');
            if (maybe_line == null) {
                std.log.info("EOF reached. Exiting sending loop.", .{});
                break;
            }
            const line_slice = maybe_line.?; // オプショナルをアンラップして実際のスライスを取得

            // 書き込み(送信)
            var writer = peer.stream.writer();
            try writer.writeAll("MSG:");
            try writer.writeAll(line_slice);
            try writer.writeAll("\n");
            std.log.info("Message sent to {any}: {s}", .{ peer.address, line_slice });
        }
    }
};

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    // 簡易的な引数パース:
    // e.g.   --listen 8080      でサーバ
    //        --connect 127.0.0.1:8080   でクライアント
    const args = std.process.argsAlloc(gpa) catch |err| {
        std.log.err("Failed to allocate args: {any}", .{err});
        return;
    };
    defer std.process.argsFree(gpa, args);

    if (args.len < 3) {
        std.log.info("Usage:\n  {s} --listen <port>\nOR\n  {s} --connect <host:port>", .{ args[0], args[0] });
        return;
    }

    const mode = args[1];
    if (std.mem.eql(u8, mode, "--listen")) {
        // ============== サーバーモード ==============
        const port_string = args[2];
        const port_num = std.fmt.parseInt(u16, port_string, 10) catch {
            std.debug.print("Invalid port number: {s}\n", .{port_string});
            return;
        };
        // ソケットをバインドして listen
        var address = try std.net.Address.resolveIp("0.0.0.0", port_num);
        var listener = try address.listen(.{});
        defer listener.deinit();

        std.log.info("Listening on port {d}...", .{port_num});

        // acceptループ(同期的)
        while (true) {
            const connection = try listener.accept();
            // 受信処理を別スレッドで開始
            // Updated to use the new Thread.spawn API with config parameter
            _ = try std.Thread.spawn(.{}, ConnHandler.run, .{connection});
            // note: spawnしたスレッドはデタッチされる(自動的に終了時破棄)
        }
    } else if (std.mem.eql(u8, mode, "--connect")) {
        // ============== クライアントモード ==============
        const hostport = args[2];
        // e.g. hostport = "127.0.0.1:8080"
        var parse_it = std.mem.tokenizeScalar(u8, hostport, ':');
        const host_str = parse_it.next() orelse {
            std.log.err("Please specify host:port", .{});
            return;
        };
        const port_str = parse_it.next() orelse {
            std.log.err("Please specify port after :", .{});
            return;
        };
        if (parse_it.next() != null) {
            std.log.err("Too many ':' in address", .{});
            return;
        }
        const port_num = std.fmt.parseInt(u16, port_str, 10) catch {
            std.log.err("Invalid port: {s}", .{port_str});
            return;
        };

        std.log.info("Connecting to {s}:{d}...", .{ host_str, port_num });
        const remote_addr = try std.net.Address.resolveIp(host_str, port_num);
        var socket = try std.net.tcpConnectToAddress(remote_addr);
        defer socket.close();
        // 送信用のスレッドをspawn
        const peer = Peer{
            .address = remote_addr,
            .stream = socket,
        };
        // ノンブロッキングで送信ループ
        // Updated to use the new Thread.spawn API with config parameter
        _ = try std.Thread.spawn(.{}, SendHandler.run, .{peer});
        std.log.info("Launched send-loop thread. Now reading from peer {s}:{d}...", .{ host_str, port_num });

        // メインスレッドで受信ループ
        var reader = socket.reader();
        var buf: [4096]u8 = undefined;
        var buffered: usize = 0;

        while (true) {
            const n = try reader.read(buf[buffered..]);
            if (n == 0) {
                if (buffered > 0) {
                    std.log.warn("Ignoring unterminated message from {s}:{d}", .{ host_str, port_num });
                }
                std.log.info("Peer {s}:{d} disconnected.", .{ host_str, port_num });
                break;
            }

            buffered += n;
            var consumed: usize = 0;
            while (std.mem.indexOfScalarPos(u8, buf[0..buffered], consumed, '\n')) |newline| {
                const message = std.mem.trimRight(u8, buf[consumed..newline], "\r");
                std.log.info("[Received from {s}:{d}] {s}", .{ host_str, port_num, message });
                consumed = newline + 1;
            }

            if (consumed > 0) {
                const remaining = buffered - consumed;
                std.mem.copyForwards(u8, buf[0..remaining], buf[consumed..buffered]);
                buffered = remaining;
            }

            if (buffered == buf.len) {
                std.log.warn("Message too long from {s}:{d}; closing connection", .{ host_str, port_num });
                break;
            }
        }
    } else {
        std.log.err("Unsupported mode: {s}", .{mode});
        return;
    }
}
