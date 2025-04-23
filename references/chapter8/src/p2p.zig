const std = @import("std");
const blockchain = @import("blockchain.zig");
const types = @import("types.zig");
const parser = @import("parser.zig");

// ピアリスト：現在接続中のピアを管理
pub var peer_list = std.ArrayList(types.Peer).init(std.heap.page_allocator);

/// startListeningServer:
/// 指定されたポートでリスニングサーバーを開始し、新しい接続を受け入れます。
/// 引数:
///   - port: リッスンするポート番号
pub fn startListeningServer(port: u16) !void {
    var addr = try std.net.Address.resolveIp("0.0.0.0", port);
    var listener = try addr.listen(.{});
    defer listener.deinit();

    std.log.info("Listening on 0.0.0.0:{d}", .{port});

    while (true) {
        const conn = try listener.accept();
        const peer = types.Peer{ .address = conn.address, .stream = conn.stream };
        try peer_list.append(peer);
        std.log.info("Accepted connection from: {any}", .{conn.address});

        // 各ピア接続ごとに通信処理用のスレッドを起動
        _ = try std.Thread.spawn(.{}, handlePeerCommunication, .{peer});
    }
}

/// initiatePeerConnection:
/// 指定されたアドレスにピア接続を試み、成功したら通信を開始します。
/// 接続に失敗した場合は一定時間後に再試行します。
/// 引数:
///   - addr: 接続先ピアのアドレス
pub fn initiatePeerConnection(addr: std.net.Address) !void {
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
        try requestChainSync(peer);

        // ピアとの通信ループを開始
        handlePeerCommunication(peer) catch |e| {
            std.log.err("Peer communication error: {any}", .{e});
        };
    }
}

/// requestChainSync:
/// ピアにブロックチェーンの同期要求を送信します。
/// 引数:
///   - peer: 同期要求を送信するピア
fn requestChainSync(peer: types.Peer) !void {
    try peer.stream.writer().writeAll("GET_CHAIN\n");
    std.log.info("Requested chain sync from {any}", .{peer.address});
}

/// handlePeerCommunication:
/// ピアとの通信を処理する継続的なループです。
/// メッセージの受信と解析、適切な処理を行います。
/// 引数:
///   - peer: 通信するピア
fn handlePeerCommunication(peer: types.Peer) !void {
    defer {
        removePeerFromList(peer);
        peer.stream.close();
    }

    var reader = peer.stream.reader();
    var message_buffer: [4096]u8 = undefined;
    var buffer_used: usize = 0;

    while (true) {
        const bytes_read = try reader.read(message_buffer[buffer_used..]);
        if (bytes_read == 0) break;  // 接続終了

        buffer_used += bytes_read;
        var process_start: usize = 0;

        // バッファ内の完全なメッセージを処理
        while (process_start < buffer_used) {
            // メッセージ終端（改行）を探索
            var message_end: ?usize = null;
            var i: usize = process_start;
            while (i < buffer_used) : (i += 1) {
                if (message_buffer[i] == '\n') {
                    message_end = i;
                    break;
                }
            }

            if (message_end) |end_pos| {
                // 完全なメッセージを処理
                const message = message_buffer[process_start..end_pos];
                try processReceivedMessage(message, peer);
                process_start = end_pos + 1;
            } else {
                // まだ完全なメッセージを受信していない
                break;
            }
        }

        // 処理済みのメッセージをバッファから削除
        if (process_start > 0) {
            if (process_start < buffer_used) {
                std.mem.copyForwards(u8, &message_buffer, message_buffer[process_start..buffer_used]);
            }
            buffer_used -= process_start;
        }

        // バッファが一杯だがメッセージが完結しない場合はエラー
        if (buffer_used == message_buffer.len) {
            std.log.err("Message too long, buffer full from peer {any}", .{peer.address});
            break;
        }
    }

    std.log.info("Peer {any} disconnected.", .{peer.address});
}

/// processReceivedMessage:
/// 受信したメッセージを種類に応じて適切に処理します。
/// 引数:
///   - msg: 受信したメッセージ
///   - from_peer: メッセージの送信元ピア
fn processReceivedMessage(msg: []const u8, from_peer: types.Peer) !void {
    if (std.mem.startsWith(u8, msg, "BLOCK:")) {
        // BLOCKメッセージの処理
        const block = parser.parseBlockJson(msg[6..]) catch |err| {
            std.log.err("Error parsing block from {any}: {any}", .{from_peer.address, err});
            return;
        };

        // ブロックをチェーンに追加
        blockchain.addValidatedBlock(block);

        // 他のピアにブロードキャスト
        broadcastBlockToNetwork(block, from_peer);
    } else if (std.mem.startsWith(u8, msg, "GET_CHAIN")) {
        // GET_CHAINメッセージの処理
        std.log.info("Received chain sync request from {any}", .{from_peer.address});
        try sendFullChainToPeer(from_peer);
    } else {
        // 不明なメッセージの場合
        std.log.info("Received unknown message from {any}: {s}", .{from_peer.address, msg});
    }
}

/// broadcastBlockToNetwork:
/// ブロックを全ての接続済みピア（送信元を除く）にブロードキャストします。
/// 引数:
///   - block: ブロードキャストするブロック
///   - from_peer: 元のブロック送信者（ループバックを防ぐため）
pub fn broadcastBlockToNetwork(block: types.Block, from_peer: ?types.Peer) void {
    const serialized_block = parser.serializeBlock(block) catch return;

    for (peer_list.items) |peer| {
        // 送信元ピアにはブロードキャストしない
        if (from_peer) |sender| {
            if (peer.address.getPort() == sender.address.getPort()) continue;
        }

        var writer = peer.stream.writer();
        _ = sendMessageToPeer(writer, "BLOCK:", serialized_block);
    }
}

/// ピアにメッセージを送信するヘルパー関数
fn sendMessageToPeer(writer: anytype, prefix: []const u8, content: []const u8) bool {
    return (writer.writeAll(prefix) catch return false) and
           (writer.writeAll(content) catch return false) and
           (writer.writeAll("\n") catch return false);
}

/// sendFullChainToPeer:
/// チェーン全体を指定されたピアに送信します。
/// 引数:
///   - peer: チェーンを送信するピア
pub fn sendFullChainToPeer(peer: types.Peer) !void {
    std.log.info("Sending full chain (height={d}) to {any}",
                 .{blockchain.chain_store.items.len, peer.address});

    var writer = peer.stream.writer();

    for (blockchain.chain_store.items) |block| {
        const block_json = try parser.serializeBlock(block);
        try writer.writeAll("BLOCK:");
        try writer.writeAll(block_json);
        try writer.writeAll("\n");
    }
}

/// removePeerFromList:
/// ピアリストから指定されたピアを削除します。
/// 引数:
///   - target: 削除するピア
fn removePeerFromList(target: types.Peer) void {
    var i: usize = 0;
    while (i < peer_list.items.len) : (i += 1) {
        if (peer_list.items[i].address.getPort() == target.address.getPort()) {
            _ = peer_list.orderedRemove(i);
            break;
        }
    }
}

/// startTextInputProcessor:
/// ユーザー入力からブロックを生成し、ネットワークに配信するループを開始します。
pub fn startTextInputProcessor() !void {
    var reader = std.io.getStdIn().reader();
    var input_buffer: [256]u8 = undefined;

    while (true) {
        std.debug.print("msg> ", .{});
        const input_line = reader.readUntilDelimiterOrEof(input_buffer[0..], '\n') catch null;

        if (input_line) |line| {
            // 最新のブロックを取得、またはジェネシスブロックを作成
            const last_block = if (blockchain.chain_store.items.len == 0)
                try blockchain.createTestGenesisBlock(std.heap.page_allocator)
            else
                blockchain.chain_store.items[blockchain.chain_store.items.len - 1];

            // 新しいブロックを作成
            var new_block = blockchain.createNewBlock(line, last_block);
            blockchain.mineBlockWithDifficulty(&new_block, 2); // 難易度2でマイニング
            blockchain.addValidatedBlock(new_block);

            // 作成したブロックをブロードキャスト
            broadcastBlockToNetwork(new_block, null);
        } else break;
    }
}
