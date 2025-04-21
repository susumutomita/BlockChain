const std = @import("std");
const blockchain = @import("blockchain.zig");
const types = @import("types.zig");
const parser = @import("parser.zig");

// ピアリスト：現在接続中のピアを管理
pub var peer_list = std.ArrayList(types.Peer).init(std.heap.page_allocator);

/// リスニングソケットを開始し、接続を受け付ける無限ループ
pub fn listenLoop(port: u16) !void {
    var addr = try std.net.Address.resolveIp("0.0.0.0", port);
    var listener = try addr.listen(.{});
    defer listener.deinit();

    std.log.info("listen 0.0.0.0:{d}", .{port});

    while (true) {
        const conn = try listener.accept();
        const peer = types.Peer{ .address = conn.address, .stream = conn.stream };
        try peer_list.append(peer);
        std.log.info("Accepted connection from: {any}", .{conn.address});

        // 各ピア接続ごとに通信処理用のスレッドを起動
        _ = try std.Thread.spawn(.{}, peerCommunicationLoop, .{peer});
    }
}

/// 指定されたアドレスに接続し、通信を確立する
/// 接続に失敗した場合は一定時間後に再試行する
pub fn connectToPeer(addr: std.net.Address) !void {
    while (true) {
        const sock = std.net.tcpConnectToAddress(addr) catch |err| {
            std.log.warn("Connection failed to {any}: {any}", .{addr, err});
            std.time.sleep(5 * std.time.ns_per_s); // 5秒待機してから再接続
            continue;
        };

        std.log.info("Connected to peer: {any}", .{addr});
        const peer = types.Peer{ .address = addr, .stream = sock };
        try peer_list.append(peer);

        // 新規接続したピアにチェーン同期要求を送信
        try requestChain(peer);

        // ピアとの通信ループを開始
        peerCommunicationLoop(peer) catch |e| {
            std.log.err("Peer communication error: {any}", .{e});
        };
    }
}

/// チェーン同期要求を送信
fn requestChain(peer: types.Peer) !void {
    try peer.stream.writer().writeAll("GET_CHAIN\n");
    std.log.info("Requested chain from {any}", .{peer.address});
}

/// ピアとの通信ループ。メッセージの受信と適切な処理を行う。
fn peerCommunicationLoop(peer: types.Peer) !void {
    defer {
        removePeerFromList(peer);
        peer.stream.close();
    }

    var reader = peer.stream.reader();
    var buf: [4096]u8 = undefined;  // 十分な大きさのバッファ
    var total_bytes: usize = 0;

    while (true) {
        const n = try reader.read(buf[total_bytes..]);
        if (n == 0) break;  // 接続終了

        total_bytes += n;
        var search_start: usize = 0;

        // バッファ内の完全なメッセージを処理
        while (search_start < total_bytes) {
            // メッセージ終端（改行）を探索
            var newline_pos: ?usize = null;
            var i: usize = search_start;
            while (i < total_bytes) : (i += 1) {
                if (buf[i] == '\n') {
                    newline_pos = i;
                    break;
                }
            }

            if (newline_pos) |pos| {
                // 完全なメッセージが見つかった場合の処理
                const msg = buf[search_start..pos];
                try handleMessage(msg, peer);
                search_start = pos + 1;
            } else {
                // まだ完全なメッセージを受信していない
                break;
            }
        }

        // 処理済みのメッセージをバッファから削除
        if (search_start > 0) {
            if (search_start < total_bytes) {
                std.mem.copyForwards(u8, &buf, buf[search_start..total_bytes]);
            }
            total_bytes -= search_start;
        }

        // バッファが一杯だがメッセージが完結しない場合はエラー
        if (total_bytes == buf.len) {
            std.log.err("Message too long, buffer full from peer {any}", .{peer.address});
            break;
        }
    }

    std.log.info("Peer {any} disconnected.", .{peer.address});
}

/// 受信したメッセージの種類に応じた処理を行う
fn handleMessage(msg: []const u8, from_peer: types.Peer) !void {
    if (std.mem.startsWith(u8, msg, "BLOCK:")) {
        // BLOCKメッセージの処理
        const blk = parser.parseBlockJson(msg[6..]) catch |err| {
            std.log.err("Error parsing block from {any}: {any}", .{from_peer.address, err});
            return;
        };

        // ブロックをチェーンに追加
        blockchain.addBlock(blk);

        // 他のピアにブロードキャスト
        broadcastBlock(blk, from_peer);
    } else if (std.mem.startsWith(u8, msg, "GET_CHAIN")) {
        // GET_CHAINメッセージの処理
        std.log.info("Received GET_CHAIN from {any}", .{from_peer.address});
        try sendFullChain(from_peer);
    } else {
        // 不明なメッセージの場合
        std.log.info("Unknown message from {any}: {s}", .{from_peer.address, msg});
    }
}

/// 全てのピア（送信元を除く）にブロックをブロードキャストする
pub fn broadcastBlock(blk: types.Block, from_peer: ?types.Peer) void {
    const payload = parser.serializeBlock(blk) catch return;

    for (peer_list.items) |peer| {
        // 送信元ピアにはブロードキャストしない
        if (from_peer) |sender| {
            if (peer.address.getPort() == sender.address.getPort()) continue;
        }

        var writer = peer.stream.writer();
        _ = writer.writeAll("BLOCK:") catch |err| {
            std.log.err("Error broadcasting to peer {any}: {any}", .{peer.address, err});
            continue;
        };
        _ = writer.writeAll(payload) catch |err| {
            std.log.err("Error broadcasting to peer {any}: {any}", .{peer.address, err});
            continue;
        };
        _ = writer.writeAll("\n") catch |err| {
            std.log.err("Error broadcasting to peer {any}: {any}", .{peer.address, err});
            continue;
        };
    }
}

/// ピアにチェーン全体を送信
pub fn sendFullChain(peer: types.Peer) !void {
    std.log.info("Sending full chain (height={d}) to {any}",
                 .{blockchain.chain_store.items.len, peer.address});

    var writer = peer.stream.writer();

    for (blockchain.chain_store.items) |block| {
        const block_json = try parser.serializeBlock(block);
        try writer.writeAll("BLOCK:");
        try writer.writeAll(block_json);
        try writer.writeAll("\n"); // メッセージフレーミングのための改行
    }
}

/// ピアリストからピアを削除
fn removePeerFromList(target: types.Peer) void {
    var i: usize = 0;
    while (i < peer_list.items.len) : (i += 1) {
        if (peer_list.items[i].address.getPort() == target.address.getPort()) {
            _ = peer_list.orderedRemove(i);
            break;
        }
    }
}

/// テキスト入力からブロックを生成し、ブロードキャストする対話的なループ
pub fn textInputLoop() !void {
    var reader = std.io.getStdIn().reader();
    var buf: [256]u8 = undefined;

    while (true) {
        std.debug.print("msg> ", .{});
        const maybe_line = reader.readUntilDelimiterOrEof(buf[0..], '\n') catch null;

        if (maybe_line) |line| {
            // 最新のブロックを取得、またはジェネシスブロックを作成
            const last_block = if (blockchain.chain_store.items.len == 0)
                try blockchain.createTestGenesisBlock(std.heap.page_allocator)
            else
                blockchain.chain_store.items[blockchain.chain_store.items.len - 1];

            // 新しいブロックを作成
            var new_block = blockchain.createBlock(line, last_block);
            blockchain.mineBlock(&new_block, 2); // 難易度2でマイニング
            blockchain.addBlock(new_block);

            // 作成したブロックをブロードキャスト
            broadcastBlock(new_block, null);
        } else break;
    }
}
