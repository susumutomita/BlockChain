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

    // Add text input thread for interactive block creation
    _ = try std.Thread.spawn(.{}, textInputLoop, .{});

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
    var buf: [4096]u8 = undefined;  // Increased buffer size
    var total_bytes: usize = 0;

    while (true) {
        const n = try reader.read(buf[total_bytes..]);
        if (n == 0) break;  // Connection closed

        total_bytes += n;
        var search_start: usize = 0;

        // Process all complete messages in the buffer
        while (search_start < total_bytes) {
            // Look for newline as message terminator
            var newline_pos: ?usize = null;
            var i: usize = search_start;
            while (i < total_bytes) : (i += 1) {
                if (buf[i] == '\n') {
                    newline_pos = i;
                    break;
                }
            }

            // If we found a complete message
            if (newline_pos) |pos| {
                const msg = buf[search_start..pos];

                // Process the message
                if (std.mem.startsWith(u8, msg, "BLOCK:")) {
                    const blk = parser.parseBlockJson(msg[6..]) catch |err| {
                        std.log.err("Parse error: {any}", .{err});
                        search_start = pos + 1;
                        continue;
                    };
                    blockchain.addBlock(blk);
                    broadcastBlock(blk, peer);
                } else if (std.mem.startsWith(u8, msg, "GET_CHAIN")) {
                    std.log.info("Received GET_CHAIN from {any}", .{peer.address});
                    try sendChain(peer);
                } else {
                    std.log.info("Unknown message: {s}", .{msg});
                }

                search_start = pos + 1;
            } else {
                // We don't have a complete message yet
                break;
            }
        }

        // Compact the buffer if we've processed some messages
        if (search_start > 0) {
            if (search_start < total_bytes) {
                // Move remaining partial data to the beginning of buffer
                std.mem.copyForwards(u8, &buf, buf[search_start..total_bytes]);
            }
            total_bytes -= search_start;
        }

        // Buffer is full but no complete message - error condition
        if (total_bytes == buf.len) {
            std.log.err("Message too long, buffer full", .{});
            break;
        }
    }

    std.log.info("Peer {any} disconnected.", .{peer.address});
}

// ── broadcast ----------
fn broadcastBlock(blk: types.Block, from: ?types.Peer) void {
    const payload = parser.serializeBlock(blk) catch return;
    for (blockchain.peer_list.items) |p| {
        // Skip the sender peer if it exists
        if (from) |sender| {
            if (p.address.getPort() == sender.address.getPort()) continue;
        }

        var w = p.stream.writer();
        _ = w.writeAll("BLOCK:") catch {}; // ★ 別 write
        _ = w.writeAll(payload) catch {};
        _ = w.writeAll("\n") catch {}; // Add newline for message framing
    }
}

// ── chain sync ----------
fn sendChain(peer: types.Peer) !void {
    std.log.info("Sending full chain (height={d}) to {any}",
                 .{ blockchain.chain_store.items.len, peer.address });
    var w = peer.stream.writer();
    for (blockchain.chain_store.items) |b| {
        const j = try parser.serializeBlock(b);
        try w.writeAll("BLOCK:"); // ★
        try w.writeAll(j); // ★
        try w.writeAll("\n"); // Add newline for message framing
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

fn textInputLoop() !void {
    var r = std.io.getStdIn().reader();
    var buf: [256]u8 = undefined;
    while (true) {
        std.debug.print("msg> ", .{});
        const maybe = r.readUntilDelimiterOrEof(buf[0..], '\n') catch null;
        if (maybe) |line| {
            const last = if (blockchain.chain_store.items.len == 0)
                try blockchain.createTestGenesisBlock(std.heap.page_allocator)
            else
                blockchain.chain_store.items[blockchain.chain_store.items.len - 1];

            var blk = blockchain.createBlock(line, last);
            blockchain.mineBlock(&blk, 2);
            blockchain.addBlock(blk);
            broadcastBlock(blk, null);
        } else break;
    }
}
