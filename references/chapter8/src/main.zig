const std = @import("std");
const blockchain = @import("blockchain.zig");
const types = @import("types.zig");
const parser = @import("parser.zig");
const p2p = @import("p2p.zig");

/// プログラムのエントリポイント
pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 2) {
        std.log.err("Usage: {s} <port> [peer...]", .{args[0]});
        return;
    }

    // コマンドライン引数からポートと既知のピアを取得
    const self_port = try std.fmt.parseInt(u16, args[1], 10);
    const known_peers = args[2..];

    // 起動時にブロックチェーンの状態を表示
    blockchain.printChainState();

    // リスナースレッドを開始
    _ = try std.Thread.spawn(.{}, p2p.listenLoop, .{self_port});

    // 既知のピアへの接続を開始
    for (known_peers) |spec| {
        const peer_addr = try resolveHostPort(spec);
        _ = try std.Thread.spawn(.{}, p2p.connectToPeer, .{peer_addr});
    }

    // インタラクティブなテキスト入力用スレッドを開始
    _ = try std.Thread.spawn(.{}, p2p.textInputLoop, .{});

    // メインスレッドを維持
    while (true) std.time.sleep(60 * std.time.ns_per_s);
}

/// ホスト名:ポート形式の文字列からアドレスを解決する
fn resolveHostPort(spec: []const u8) !std.net.Address {
    var it = std.mem.tokenizeScalar(u8, spec, ':');
    const host = it.next() orelse return error.Invalid;
    const port_s = it.next() orelse return error.Invalid;
    const port = try std.fmt.parseInt(u16, port_s, 10);
    return std.net.Address.resolveIp(host, port);
}
