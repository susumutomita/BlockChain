const std = @import("std");

//------------------------------------------------------------------------------
// データ構造
//------------------------------------------------------------------------------
pub const Transaction = struct {
    sender: []const u8,
    receiver: []const u8,
    amount: u64,
};

pub const Block = struct {
    index: u32,
    timestamp: u64,
    prev_hash: [32]u8,
    transactions: std.ArrayList(Transaction),
    nonce: u64,
    data: []const u8,
    hash: [32]u8,
};

//------------------------------------------------------------------------------
// Peer 構造体
// ネットワーク上のピアを表現します。
// ピアは、アドレスとストリームを持ちます。
pub const Peer = struct {
    address: std.net.Address,
    stream: std.net.Stream,
};

//------------------------------------------------------------------------------
// ピア管理用の構造体と定数
//------------------------------------------------------------------------------
pub const MAX_PEERS = 10; // 最大接続ピア数
pub const PEER_RETRY_INTERVAL: u64 = 60; // 再接続間隔（秒）

// ピアの状態を表す列挙型
pub const PeerState = enum {
    Connected,    // 接続済み
    Disconnected, // 切断
    Connecting,   // 接続中
};

// ピア管理用の拡張構造体
pub const ManagedPeer = struct {
    peer: ?Peer,              // ピア情報（未接続時はnull）
    address: std.net.Address, // ピアのアドレス
    state: PeerState,         // 接続状態
    last_attempt: u64,        // 最後に接続を試みた時間（UNIX時間）
};

// ピアリスト：接続されたピアを管理
pub const PeerList = struct {
    peers: [MAX_PEERS]?ManagedPeer,
    mutex: std.Thread.Mutex,  // 複数スレッドからの同時アクセスを防ぐ

    pub fn init() PeerList {
        return PeerList{
            .peers = [_]?ManagedPeer{null} ** MAX_PEERS,
            .mutex = std.Thread.Mutex{},
        };
    }

    // 新しいピアを追加（アドレスのみ）
    pub fn addPeerAddress(self: *PeerList, address: std.net.Address) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        // 既に登録済みかチェック
        for (self.peers) |maybe_peer| {
            if (maybe_peer) |p| {
                if (p.address.eql(address)) {
                    return false; // 既に存在する
                }
            }
        }

        // 空きスロットを探して追加
        for (self.peers, 0..) |maybe_peer, idx| {
            if (maybe_peer == null) {
                self.peers[idx] = ManagedPeer{
                    .peer = null,
                    .address = address,
                    .state = .Disconnected,
                    .last_attempt = 0,
                };
                return true;
            }
        }
        return false; // 空きスロットなし
    }

    // 接続済みピアを追加
    pub fn addConnectedPeer(self: *PeerList, peer: Peer) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        // 既存のアドレスとマッチするか確認
        for (self.peers, 0..) |maybe_peer, idx| {
            if (maybe_peer) |p| {
                if (p.address.eql(peer.address)) {
                    // 既存のエントリを更新
                    self.peers[idx] = ManagedPeer{
                        .peer = peer,
                        .address = peer.address,
                        .state = .Connected,
                        .last_attempt = @intCast(std.time.timestamp()),
                    };
                    return true;
                }
            }
        }

        // 新規追加
        for (self.peers, 0..) |maybe_peer, idx| {
            if (maybe_peer == null) {
                self.peers[idx] = ManagedPeer{
                    .peer = peer,
                    .address = peer.address,
                    .state = .Connected,
                    .last_attempt = @intCast(std.time.timestamp()),
                };
                return true;
            }
        }
        return false; // 空きスロットなし
    }

    // ピアを切断状態に更新
    pub fn markDisconnected(self: *PeerList, address: std.net.Address) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.peers, 0..) |maybe_peer, idx| {
            if (maybe_peer) |p| {
                if (p.address.eql(address)) {
                    // 接続情報をクリアして切断状態に
                    self.peers[idx] = ManagedPeer{
                        .peer = null,
                        .address = address,
                        .state = .Disconnected,
                        .last_attempt = @intCast(std.time.timestamp()),
                    };
                    break;
                }
            }
        }
    }

    // 全ての接続済みピアを取得
    pub fn getConnectedPeers(self: *PeerList, allocator: std.mem.Allocator) !std.ArrayList(Peer) {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = std.ArrayList(Peer).init(allocator);
        for (self.peers) |maybe_peer| {
            if (maybe_peer) |p| {
                if (p.state == .Connected and p.peer != null) {
                    try result.append(p.peer.?);
                }
            }
        }
        return result;
    }

    // 切断されたピアで再接続すべきものを取得
    pub fn getReconnectCandidates(self: *PeerList, allocator: std.mem.Allocator) !std.ArrayList(std.net.Address) {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = @intCast(std.time.timestamp());
        var result = std.ArrayList(std.net.Address).init(allocator);

        for (self.peers) |maybe_peer| {
            if (maybe_peer) |p| {
                if (p.state == .Disconnected) {
                    // 最後の試行から一定時間経過していれば再接続候補
                    if (now - p.last_attempt > PEER_RETRY_INTERVAL) {
                        try result.append(p.address);
                    }
                }
            }
        }
        return result;
    }
};
