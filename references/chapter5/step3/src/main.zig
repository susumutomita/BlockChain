const std = @import("std");
const types = @import("types.zig");
const network = @import("network.zig");
const json = @import("json.zig");

//--------------------------------------
// main 関数
//--------------------------------------
pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 3) {
        std.log.info("Usage:\n {s} --listen <port>\n or\n {s} --connect <host:port>\n", .{ args[0], args[0] });
        return;
    }

    const mode = args[1];
    if (std.mem.eql(u8, mode, "--listen")) {
        // サーバーモード
        const port_str = args[2];
        const port_num = try std.fmt.parseInt(u16, port_str, 10);
        var address = try std.net.Address.resolveIp("0.0.0.0", port_num);
        var listener = try address.listen(.{});
        defer listener.deinit();
        std.log.info("Listening on 0.0.0.0:{d}", .{port_num});
        while (true) {
            const conn = try listener.accept();
            _ = try std.Thread.spawn(.{}, network.ConnHandler.run, .{conn});
        }
    } else if (std.mem.eql(u8, mode, "--connect")) {
        // クライアントモード
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
        const remote_addr = try std.net.Address.resolveIp(host_str, port_num);
        var socket = try std.net.tcpConnectToAddress(remote_addr);
        const peer = network.Peer{
            .address = remote_addr,
            .stream = socket,
        };
        _ = try std.Thread.spawn(.{}, network.ClientHandler.run, .{peer});
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
                const new_block = try json.parseBlockJson(json_part);
                network.addBlock(new_block);
            } else {
                std.log.info("Unknown msg: {s}", .{msg_slice});
            }
        }
    } else {
        std.log.err("Invalid mode: {s}", .{mode});
    }
}

//------------------------------------------------------------------------------
// テストコード
//------------------------------------------------------------------------------

test "トランザクション作成のテスト" {
    const tx = types.Transaction{
        .sender = "Alice",
        .receiver = "Bob",
        .amount = 50,
    };
    try std.testing.expectEqualStrings("Alice", tx.sender);
    try std.testing.expectEqualStrings("Bob", tx.receiver);
    try std.testing.expectEqual(@as(u64, 50), tx.amount);
}

test "ブロック作成のテスト" {
    const allocator = std.testing.allocator;
    var block = try network.createTestGenesisBlock(allocator);
    defer block.transactions.deinit();

    try std.testing.expectEqual(@as(u32, 0), block.index);
    try std.testing.expectEqual(@as(u64, 1672531200), block.timestamp);
    try std.testing.expectEqualStrings("Hello, Zig Blockchain!", block.data);
}
