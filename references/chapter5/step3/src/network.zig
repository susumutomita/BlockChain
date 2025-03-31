const std = @import("std");
const types = @import("types.zig");
const hash = @import("hash.zig");
pub const json = @import("json.zig");

pub const Peer = struct {
    address: std.net.Address,
    stream: std.net.Stream,
};

//--------------------------------------
// 簡易チェイン管理用: ブロック配列
//--------------------------------------
var chain_store = std.ArrayList(types.Block).init(std.heap.page_allocator);

// addBlock: 受け取ったブロックをチェインに追加（検証付き）
pub fn addBlock(new_block: types.Block) void {
    if (!hash.verifyBlockPow(&new_block)) {
        std.log.err("Received block fails PoW check. Rejecting it.", .{});
        return;
    }
    chain_store.append(new_block) catch {};
    std.log.info("Added new block index={d}, nonce={d}, hash={x}", .{ new_block.index, new_block.nonce, new_block.hash });
}

pub fn sendBlock(block: types.Block, remote_addr: std.net.Address) !void {
    const json_data = json.serializeBlock(block) catch |err| {
        std.debug.print("Serialize error: {any}\n", .{err});
        return err;
    };
    var socket = try std.net.tcpConnectToAddress(remote_addr);
    var writer = socket.writer();
    try writer.writeAll("BLOCK:" ++ json_data);
}

/// createBlock: 新しいブロックを生成
pub fn createBlock(input: []const u8, prevBlock: types.Block) types.Block {
    return types.Block{
        .index = prevBlock.index + 1,
        .timestamp = @intCast(std.time.timestamp()),
        .prev_hash = prevBlock.hash,
        .transactions = std.ArrayList(types.Transaction).init(std.heap.page_allocator),
        .nonce = 0,
        .data = input,
        .hash = [_]u8{0} ** 32,
    };
}

/// createTestGenesisBlock: テスト用のジェネシスブロックを生成
pub fn createTestGenesisBlock(allocator: std.mem.Allocator) !types.Block {
    var genesis = types.Block{
        .index = 0,
        .timestamp = 1672531200,
        .prev_hash = [_]u8{0} ** 32,
        .transactions = std.ArrayList(types.Transaction).init(allocator),
        .nonce = 0,
        .data = "Hello, Zig Blockchain!",
        .hash = [_]u8{0} ** 32,
    };
    try genesis.transactions.append(types.Transaction{ .sender = "Alice", .receiver = "Bob", .amount = 100 });
    hash.mineBlock(&genesis, hash.DIFFICULTY);
    return genesis;
}

//--------------------------------------
// メッセージ受信処理: ConnHandler
//--------------------------------------
pub const ConnHandler = struct {
    pub fn run(conn: std.net.Server.Connection) !void {
        defer conn.stream.close();
        std.log.info("Accepted: {any}", .{conn.address});

        var reader = conn.stream.reader();
        var buf: [256]u8 = undefined;

        while (true) {
            const n = try reader.read(&buf);
            if (n == 0) {
                std.log.info("Peer {any} disconnected.", .{conn.address});
                break;
            }
            const msg_slice = buf[0..n];
            std.log.info("[Received] {s}", .{msg_slice});

            // 簡易メッセージ解析
            if (std.mem.startsWith(u8, msg_slice, "BLOCK:")) {
                // "BLOCK:" の後ろを取り出してJSONパースする
                const json_part = msg_slice[6..];
                const new_block = json.parseBlockJson(json_part) catch |err| {
                    std.log.err("Failed parseBlockJson: {any}", .{err});
                    continue;
                };
                // チェインに追加
                addBlock(new_block);
            } else {
                // それ以外はログだけ
                std.log.info("Unknown message: {s}", .{msg_slice});
            }
        }
    }
};

//--------------------------------------
// クライアント処理
//--------------------------------------
pub const ClientHandler = struct {
    pub fn run(peer: Peer) !void {
        // クライアントはローカルに Genesis ブロックを保持（本来はサーバーから同期する）
        var lastBlock = try createTestGenesisBlock(std.heap.page_allocator);
        clientSendLoop(peer, &lastBlock) catch unreachable;
    }
};

fn clientSendLoop(peer: Peer, lastBlock: *types.Block) !void {
    var stdin = std.io.getStdIn();
    var reader = stdin.reader();
    var line_buffer: [256]u8 = undefined;
    while (true) {
        std.debug.print("Enter message for new block: ", .{});
        const maybe_line = try reader.readUntilDelimiterOrEof(line_buffer[0..], '\n');
        if (maybe_line == null) break;
        const user_input = maybe_line.?;
        var new_block = createBlock(user_input, lastBlock.*);
        hash.mineBlock(&new_block, hash.DIFFICULTY);
        var writer = peer.stream.writer();
        const block_json = json.serializeBlock(new_block) catch unreachable;
        // 必要なサイズのバッファを用意して "BLOCK:" と block_json を連結する
        var buf = try std.heap.page_allocator.alloc(u8, "BLOCK:".len + block_json.len);
        defer std.heap.page_allocator.free(buf);

        // バッファに連結
        @memcpy(buf[0.."BLOCK:".len], "BLOCK:");
        @memcpy(buf["BLOCK:".len..], block_json);

        // 1回の書き出しで送信
        try writer.writeAll(buf);
        lastBlock.* = new_block;
    }
}
