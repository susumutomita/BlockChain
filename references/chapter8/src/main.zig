const std = @import("std");
const blockchain = @import("blockchain.zig");
const types = @import("types.zig");
const parser = @import("parser.zig");
const p2p = @import("p2p.zig");

/// プログラムのエントリポイント
/// ブロックチェーンP2Pネットワークを初期化し、各種サービスを開始します。
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

    // リスナーサーバーを開始
    _ = try std.Thread.spawn(.{}, p2p.startListeningServer, .{self_port});

    // 既知のピアへの接続を開始
    for (known_peers) |peer_address| {
        const peer_addr = try resolveHostAndPort(peer_address);
        _ = try std.Thread.spawn(.{}, p2p.initiatePeerConnection, .{peer_addr});
    }

    // ユーザー入力処理スレッドを開始
    _ = try std.Thread.spawn(.{}, p2p.startTextInputProcessor, .{});

    // メインスレッドを維持
    while (true) std.time.sleep(60 * std.time.ns_per_s);
}

/// resolveHostAndPort:
/// ホスト名:ポート形式の文字列からネットワークアドレスを解決します。
/// 引数:
///   - address_spec: "hostname:port"形式の文字列
/// 返値: 解決されたネットワークアドレス
fn resolveHostAndPort(address_spec: []const u8) !std.net.Address {
    var it = std.mem.tokenizeScalar(u8, address_spec, ':');
    const host = it.next() orelse return error.InvalidAddressFormat;
    const port_str = it.next() orelse return error.InvalidAddressFormat;
    const port = try std.fmt.parseInt(u16, port_str, 10);
    return std.net.Address.resolveIp(host, port);
}
