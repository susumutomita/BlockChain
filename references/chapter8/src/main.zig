const std = @import("std");
const blockchain = @import("blockchain.zig");
const types = @import("types.zig");
const parser = @import("parser.zig");

//------------------------------------------------------------------------------
// メイン処理およびテスト実行
//------------------------------------------------------------------------------
//
// main 関数では、以下の手順を実行しています：
// 1. ジェネシスブロック(最初のブロック)を初期化。
// 2. 取引リスト(トランザクション)の初期化と追加。
// 3. ブロックのハッシュを計算し、指定難易度に到達するまで nonce を探索(採掘)。
// 4. 最終的なブロック情報を標準出力に表示。
pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    // 引数: <port> [peer1] [peer2] ...
    if (args.len < 2) {
        std.log.err("Usage: {s} <port> [host:port]...", .{args[0]});
        return;
    }

    const self_port = try std.fmt.parseInt(u16, args[1], 10);
    const known_peers = args[2..]; // [][]u8

    // ----- リスナー起動 -----
    var addr = try std.net.Address.resolveIp("0.0.0.0", self_port);
    var listener = try addr.listen(.{});
    _ = try std.Thread.spawn(.{}, listenLoop, .{&listener});
    std.log.info("Listening on 0.0.0.0:{d}", .{self_port});

    for (known_peers) |peer_str| {
        const peer_addr = try resolveHostPort(peer_str);
        _ = try std.Thread.spawn(.{}, connectToPeer, .{peer_addr});
    }

    runMiningConsoleLoop();
}

/// Accept incoming connections and spawn peer handlers.
/// TODO: replace stub with real implementation.
fn listenLoop(listener: *std.net.Server) !void {
    defer listener.deinit();
    while (true) {
        const conn = try listener.accept();
        // For now, just close the socket to prove compilation.
        conn.stream.close();
    }
}

/// Dial to a remote peer and start the peer loop.
/// TODO: implement real peer communication.
fn connectToPeer(addr: std.net.Address) !void {
    var sock = try std.net.tcpConnectToAddress(addr);
    defer sock.close();
    // Placeholder: immediately return after connecting.
}

/// Parse "host:port" into std.net.Address.
/// Very small helper for early compilation.
fn resolveHostPort(spec: []const u8) !std.net.Address {
    var it = std.mem.tokenizeScalar(u8, spec, ':');
    const host = it.next() orelse return error.InvalidFormat;
    const port_str = it.next() orelse return error.InvalidFormat;
    const port = try std.fmt.parseInt(u16, port_str, 10);
    return std.net.Address.resolveIp(host, port);
}

/// Placeholder for the interactive mining loop.
/// TODO: implement actual user‑input mining logic.
fn runMiningConsoleLoop() void {
    // At this stage we only need a no‑op to satisfy the linker.
    // Insert real code later.
}
