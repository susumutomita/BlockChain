const std = @import("std");
const blockchain = @import("blockchain.zig");
const types = @import("types.zig");
const parser = @import("parser.zig");
const net = std.net;

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
    if (args.len < 3) {
        std.log.info("Usage:\n {s} --listen <port>\n or\n {s} --connect <host:port>\n or\n {s} --rpcListen <port>\n", .{ args[0], args[0], args[0] });
        return;
    }
    const mode = args[1];
    if (std.mem.eql(u8, mode, "--listen")) {
        const port_str = args[2];
        const port_num = try std.fmt.parseInt(u16, port_str, 10);
        var address = try std.net.Address.resolveIp("0.0.0.0", port_num);
        var listener = try address.listen(.{});
        defer listener.deinit();
        std.log.info("Listening on 0.0.0.0:{d}", .{port_num});
        while (true) {
            const conn = try listener.accept();
            _ = try std.Thread.spawn(.{}, blockchain.ConnHandler.run, .{conn});
        }
    } else if (std.mem.eql(u8, mode, "--connect")) {
        const hostport = args[2];
        var tokenizer = std.mem.tokenizeScalar(u8, hostport, ':');
        const host_str = tokenizer.next() orelse {
            std.log.err("Please specify <host:port>", .{});
            return;
        };
        const port_str = tokenizer.next() orelse {
            std.log.err("No port after ':'", .{});
            return;
        };
        if (tokenizer.next() != null) {
            std.log.err("Too many ':' in {s}", .{hostport});
            return;
        }
        const port_num = try std.fmt.parseInt(u16, port_str, 10);
        std.log.info("Connecting to {s}:{d}...", .{ host_str, port_num });

        // ホスト名を解決する (IPアドレスまたはホスト名の両方に対応)
        var remote_addr: net.Address = undefined;
        if (std.mem.indexOf(u8, host_str, ".") != null) {
            // IPアドレスと思われる場合は直接解決
            remote_addr = try net.Address.resolveIp(host_str, port_num);
        } else {
            // ホスト名の場合はDNS解決を使用
            var list = try net.getAddressList(gpa, host_str, port_num);
            defer list.deinit();

            if (list.addrs.len == 0) {
                std.log.err("Could not resolve hostname: {s}", .{host_str});
                return error.HostNotFound;
            }

            remote_addr = list.addrs[0];
        }

        var socket = try net.tcpConnectToAddress(remote_addr);
        const peer = types.Peer{
            .address = remote_addr,
            .stream = socket,
        };
        _ = try std.Thread.spawn(.{}, blockchain.ClientHandler.run, .{peer});
        var reader = socket.reader();
        var buf: [256]u8 = undefined;
        while (true) {
            const n = try reader.read(&buf);
            if (n == 0) {
                std.log.info("Server disconnected.", .{});
                break;
            }
            const msg_slice = buf[0..n];
            std.log.info("[Recv] {s}", .{msg_slice});
            if (std.mem.startsWith(u8, msg_slice, "BLOCK:")) {
                const json_part = msg_slice[6..];
                const new_block = try parser.parseBlockJson(json_part);
                blockchain.addBlock(new_block);
            } else {
                std.log.info("Unknown msg: {s}", .{msg_slice});
            }
        }
    }
}

//------------------------------------------------------------------------------
// テスト
//------------------------------------------------------------------------------
test "トランザクションの初期化テスト" {
    const tx = types.Transaction{
        .sender = "Alice",
        .receiver = "Bob",
        .amount = 42,
    };
    try std.testing.expectEqualStrings("Alice", tx.sender);
    try std.testing.expectEqualStrings("Bob", tx.receiver);
    try std.testing.expectEqual(@as(u64, 42), tx.amount);
}

test "ブロックにトランザクションを追加" {
    var block = types.Block{
        .index = 0,
        .timestamp = 1234567890,
        .prev_hash = [_]u8{0} ** 32,
        .transactions = std.ArrayList(types.Transaction).init(std.testing.allocator),
        .nonce = 0,
        .data = "Test block",
        .hash = [_]u8{0} ** 32,
    };
    defer block.transactions.deinit();

    try block.transactions.append(types.Transaction{
        .sender = "Taro",
        .receiver = "Hanako",
        .amount = 100,
    });
    try std.testing.expectEqual(@as(usize, 1), block.transactions.items.len);
}

test "マイニングが先頭1バイト0のハッシュを生成できる" {
    var block = types.Block{
        .index = 0,
        .timestamp = 1672531200,
        .prev_hash = [_]u8{0} ** 32,
        .transactions = std.ArrayList(types.Transaction).init(std.testing.allocator),
        .nonce = 0,
        .data = "For Mining test",
        .hash = [_]u8{0} ** 32,
    };
    defer block.transactions.deinit();

    // 適当にトランザクションを追加
    try block.transactions.append(types.Transaction{ .sender = "A", .receiver = "B", .amount = 100 });

    // 初期ハッシュ
    block.hash = blockchain.calculateHash(&block);

    // 難易度1(先頭1バイトが0)を満たすまでマイニング
    blockchain.mineBlock(&block, 1);
    try std.testing.expectEqual(@as(u8, 0), block.hash[0]);
}
