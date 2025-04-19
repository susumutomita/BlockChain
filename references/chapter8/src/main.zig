const std = @import("std");
const blockchain = @import("blockchain.zig");
const types = @import("types.zig");
const parser = @import("parser.zig");

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 2) {
        std.log.err("Usage: {s} <port> [peer...]", .{args[0]});
        return;
    }

    const self_port = try std.fmt.parseInt(u16, args[1], 10);
    const known_peers = args[2..];

    // ── リスナー起動 ───────────────────────
    var addr = try std.net.Address.resolveIp("0.0.0.0", self_port);
    var servo = try addr.listen(.{});
    std.log.info("listen 0.0.0.0:{d}", .{self_port});
    _ = try std.Thread.spawn(.{}, acceptLoop, .{&servo});

    // ── 既知ピアへ同時接続 ─────────────────
    for (known_peers) |spec| {
        const peer_addr = try resolveHostPort(spec);
        _ = try std.Thread.spawn(.{}, dialLoop, .{peer_addr});
    }

    // main スレッドを維持
    while (true) std.time.sleep(60 * std.time.ns_per_s); // ★ 0.14 は ns_per_s を使う  [oai_citation_attribution:1‡Welcome | zig.guide](https://zig.guide/standard-library/threads/)
}

// ---------- util ----------
fn resolveHostPort(spec: []const u8) !std.net.Address {
    var it = std.mem.tokenizeScalar(u8, spec, ':');
    const host = it.next() orelse return error.Invalid;
    const port_s = it.next() orelse return error.Invalid;
    const port = try std.fmt.parseInt(u16, port_s, 10);
    return std.net.Address.resolveIp(host, port);
}

// ---------- accept ----------
fn acceptLoop(listener: *std.net.Server) !void {
    defer listener.deinit();
    while (true) {
        const conn = try listener.accept();
        const peer = types.Peer{ .address = conn.address, .stream = conn.stream };
        try blockchain.peer_list.append(peer);
        _ = try std.Thread.spawn(.{}, peerLoop, .{peer});
    }
}

// ---------- dial (再接続付き) ----------
fn dialLoop(addr: std.net.Address) !void {
    while (true) {
        if (std.net.tcpConnectToAddress(addr)) |sock| { //  [oai_citation_attribution:2‡GitHub](https://github.com/cedrickchee/experiments/blob/master/zig/zig-by-example/tcp-connection.zig?utm_source=chatgpt.com)
            std.log.info("connected {any}", .{addr});
            const peer = types.Peer{ .address = addr, .stream = sock };
            try blockchain.peer_list.append(peer);
            try peer.stream.writer().writeAll("GET_CHAIN\n");
            peerLoop(peer) catch |e| std.log.err("{any}", .{e});
        } else |err| std.log.warn("dial fail: {any}", .{err});
        std.time.sleep(5 * std.time.ns_per_s);
    }
}

// ---------- peer I/O ----------
fn peerLoop(peer: types.Peer) !void {
    defer {
        removePeer(peer);
        peer.stream.close();
    }

    var reader = peer.stream.reader();
    var buf: [1024]u8 = undefined;

    while (true) {
        const n = try reader.read(&buf);
        if (n == 0) break;

        const msg = buf[0..n];

        if (std.mem.startsWith(u8, msg, "BLOCK:")) {
            const blk = try parser.parseBlockJson(msg[6..]);
            blockchain.addBlock(blk);
            broadcastBlock(blk, peer);
        } else if (std.mem.startsWith(u8, msg, "GET_CHAIN")) {
            try sendChain(peer);
        }
    }
}

// ── broadcast ----------
fn broadcastBlock(blk: types.Block, from: types.Peer) void {
    const payload = parser.serializeBlock(blk) catch return;
    for (blockchain.peer_list.items) |p| {
        // ★ getPort() で比較
        if (p.address.getPort() == from.address.getPort()) continue;
        var w = p.stream.writer();
        _ = w.writeAll("BLOCK:") catch {}; // ★ 別 write
        _ = w.writeAll(payload) catch {};
    }
}

// ── chain sync ----------
fn sendChain(peer: types.Peer) !void {
    var w = peer.stream.writer();
    for (blockchain.chain_store.items) |b| {
        const j = try parser.serializeBlock(b);
        try w.writeAll("BLOCK:"); // ★
        try w.writeAll(j); // ★
    }
}

// ── remove ----------
fn removePeer(target: types.Peer) void {
    var i: usize = 0;
    while (i < blockchain.peer_list.items.len) : (i += 1) {
        if (blockchain.peer_list.items[i].address.getPort() == target.address.getPort()) {
            _ = blockchain.peer_list.orderedRemove(i);
            break;
        }
    }
}
