const std = @import("std");
const types = @import("types.zig");
const blockchain = @import("blockchain.zig");
const logger = @import("logger.zig");
const utils = @import("utils.zig");
const parser = @import("parser.zig");

// グローバルピアリスト
var peer_list = types.PeerList.init();

// 既知のシードノード（初期接続先）
const SEED_NODES = [_][]const u8{
    "127.0.0.1:8001",
    "127.0.0.1:8002",
    "127.0.0.1:8003",
};

//------------------------------------------------------------------------------
// P2Pネットワーク処理
//------------------------------------------------------------------------------

// 他のピアへメッセージを送信
pub fn broadcastMessage(message: []const u8, allocator: std.mem.Allocator) !void {
    var connected_peers = try peer_list.getConnectedPeers(allocator);
    defer connected_peers.deinit();

    for (connected_peers.items) |peer| {
        var writer = peer.stream.writer();
        _ = writer.write(message) catch |err| {
            std.log.err("Failed to broadcast to peer {any}: {any}", .{ peer.address, err });
            peer_list.markDisconnected(peer.address);
            continue;
        };
    }
    std.log.info("Broadcasted message to {d} peers", .{connected_peers.items.len});
}

// 新しいブロックが生成されたときに全ピアに配信
pub fn broadcastBlock(block: types.Block, allocator: std.mem.Allocator) !void {
    const block_json = try parser.serializeBlock(block);
    defer allocator.free(block_json);

    // "BLOCK:" プレフィックスを付けて送信
    var message = try std.fmt.allocPrint(allocator, "BLOCK:{s}\n", .{block_json});
    defer allocator.free(message);

    try broadcastMessage(message, allocator);
}

// 切断されたピアへの再接続を試みる
fn tryReconnectPeers(allocator: std.mem.Allocator) !void {
    var candidates = try peer_list.getReconnectCandidates(allocator);
    defer candidates.deinit();

    for (candidates.items) |address| {
        std.log.info("Attempting to reconnect to peer {any}", .{address});
        
        // 接続処理
        const socket = std.net.tcpConnectToAddress(address) catch |err| {
            std.log.err("Failed to reconnect to {any}: {any}", .{ address, err });
            continue;
        };
        
        const peer = types.Peer{
            .address = address,
            .stream = socket,
        };
        
        _ = peer_list.addConnectedPeer(peer);
        
        // クライアントハンドラーを起動
        _ = try std.Thread.spawn(.{}, blockchain.ClientHandler.run, .{peer});
    }
}

// サーバーとして接続を受け付けるメインループ
fn serverLoop(port: u16) !void {
    var address = try std.net.Address.resolveIp("0.0.0.0", port);
    var listener = try address.listen(.{});
    defer listener.deinit();

    std.log.info("P2P node listening on 0.0.0.0:{d}", .{port});

    while (true) {
        const conn = try listener.accept();
        std.log.info("Accepted connection from {any}", .{conn.address});

        // ピアリストに追加
        const peer = types.Peer{
            .address = conn.address,
            .stream = conn.stream,
        };
        
        _ = peer_list.addConnectedPeer(peer);
        
        // サーバーハンドラーをスレッド実行
        _ = try std.Thread.spawn(.{}, blockchain.ConnHandler.run, .{conn});
    }
}

// シードノードへの初期接続を試みる
fn connectToSeedNodes(allocator: std.mem.Allocator) !void {
    for (SEED_NODES) |node_str| {
        // ホスト名とポートをパース
        var parts = std.mem.split(u8, node_str, ":");
        const host = parts.next() orelse continue;
        const port_str = parts.next() orelse continue;
        const port = std.fmt.parseInt(u16, port_str, 10) catch continue;
        
        // 自分自身のポートと同じなら接続しない
        const self_port_str = std.process.getEnvVarOwned(allocator, "NODE_PORT") catch "0";
        defer allocator.free(self_port_str);
        const self_port = std.fmt.parseInt(u16, self_port_str, 10) catch 0;
        if (self_port == port) continue;
        
        // アドレス解決して接続
        std.log.info("Connecting to seed node {s}:{d}", .{ host, port });
        const address = std.net.Address.resolveIp(host, port) catch |err| {
            std.log.err("Failed to resolve seed node {s}:{d}: {any}", .{ host, port, err });
            continue;
        };
        
        // ピアリストにアドレスだけ追加（接続は後ほど試みる）
        _ = peer_list.addPeerAddress(address);
    }
}

// 定期的なピア管理タスクを実行
fn peerMaintenanceTask() !void {
    const allocator = std.heap.page_allocator;
    
    while (true) {
        // 30秒待機
        std.time.sleep(30 * std.time.ns_per_s);
        
        // 再接続処理
        tryReconnectPeers(allocator) catch |err| {
            std.log.err("Error in peer reconnection: {any}", .{err});
        };
    }
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    // コマンドライン引数の処理
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    if (args.len < 2) {
        std.log.info("Usage: {s} <port>", .{args[0]});
        return;
    }
    
    const port_str = args[1];
    const port = try std.fmt.parseInt(u16, port_str, 10);
    
    // 環境変数にポートを設定
    try std.process.setEnvVar("NODE_PORT", port_str);
    
    // シードノードへの接続を試みる
    try connectToSeedNodes(allocator);
    
    // ピア管理タスクを起動
    _ = try std.Thread.spawn(.{}, peerMaintenanceTask, .{});
    
    // サーバーループを起動（このスレッドはブロックされる）
    try serverLoop(port);
}
