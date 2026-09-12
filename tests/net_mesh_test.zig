//! Headless test of the P2P session layer's mesh brain (src/net_core.zig),
//! with NO browser. We bind net_core's transport-agnostic Session to an
//! in-process fake of the WebSocket signaling + WebRTC data channels, spin up
//! several Sessions, pump their poll() loops, and assert the whole negotiation
//! actually works: peers discover each other, channels open, messages flow both
//! ways across a real mesh, and leaving is noticed.
//!
//! The fake reproduces the signaling server's relay exactly (assign an id on
//! JOIN, send WELCOME/JOINED, relay SIGNAL->FROM, LEFT on close) and simulates
//! linked peer connections: an offer carries the source pc's id, so when the
//! far side feeds it to setRemote the two mock pcs get wired together, both
//! fire channel-open, and from then on send() on one drops a data event into
//! the other's queue.
//!
//! Run: zig test net_mesh_test.zig   (net_core imports only std, so no graph)

const std = @import("std");
const core = @import("src/net_core.zig");
const typed = @import("src/net_typed.zig");

// ------------------------------------------------------------------ transports

const msg_cap = 512; // mock SDP/ICE/control messages are tiny
const max_sock = 16;
const max_pc = 32;
const q_cap = 64;

const WsState = enum(u8) { connecting, open, closed };
const RtcEventKind = enum(u8) { none, local_offer, local_answer, local_ice, channel_open, data, state };
const RtcEvent = struct { kind: RtcEventKind, channel: u8, payload: []const u8 };

const Msg = struct {
    buf: [msg_cap]u8,
    len: usize,
};

// A queued RTC event (payload copied in).
const Ev = struct {
    kind: RtcEventKind,
    channel: u8,
    buf: [msg_cap]u8,
    len: usize,
};

const MockSocket = struct {
    used: bool,
    id: u32, // 0 until JOIN assigns one
    room: [64]u8,
    room_len: usize,
    inbox: [q_cap]Msg,
    head: usize,
    count: usize,
};

const MockPc = struct {
    used: bool,
    linked: u32, // peer pc handle (0 = not yet linked)
    events: [q_cap]Ev,
    head: usize,
    count: usize,
};

var g_sockets: [max_sock]MockSocket = undefined;
var g_pcs: [max_pc]MockPc = undefined;
var g_next_id: u32 = 1;

fn resetMocks() void {
    var i: usize = 0;
    while (i < max_sock) : (i += 1) {
        g_sockets[i] = .{ .used = false, .id = 0, .room = undefined, .room_len = 0, .inbox = undefined, .head = 0, .count = 0 };
    }
    i = 0;
    while (i < max_pc) : (i += 1) {
        g_pcs[i] = .{ .used = false, .linked = 0, .events = undefined, .head = 0, .count = 0 };
    }
    g_next_id = 1;
}

fn sockEnqueue(sock: *MockSocket, text: []const u8) void {
    if (sock.count >= q_cap) return;
    const slot: usize = (sock.head + sock.count) % q_cap;
    const n: usize = @min(text.len, msg_cap);
    @memcpy(sock.inbox[slot].buf[0..n], text[0..n]);
    sock.inbox[slot].len = n;
    sock.count += 1;
}

fn pcEnqueue(pc: *MockPc, kind: RtcEventKind, channel: u8, payload: []const u8) void {
    if (pc.count >= q_cap) return;
    const slot: usize = (pc.head + pc.count) % q_cap;
    const n: usize = @min(payload.len, msg_cap);
    @memcpy(pc.events[slot].buf[0..n], payload[0..n]);
    pc.events[slot].len = n;
    pc.events[slot].kind = kind;
    pc.events[slot].channel = channel;
    pc.count += 1;
}

fn firstToken(s: []const u8) []const u8 {
    const sp: usize = std.mem.indexOfScalar(u8, s, ' ') orelse return s;
    return s[0..sp];
}

// Pull N out of a "...pc=N" string.
fn parsePc(s: []const u8) u32 {
    const at: usize = std.mem.indexOf(u8, s, "pc=") orelse return 0;
    const tail: []const u8 = s[at + 3 ..];
    const tok: []const u8 = firstToken(tail);
    return std.fmt.parseInt(u32, tok, 10) catch 0;
}

const mock_ws = struct {
    pub const Handle = u32;
    pub const State = WsState;

    pub fn open(url: []const u8) Handle {
        _ = url;
        var i: usize = 0;
        while (i < max_sock) : (i += 1) {
            if (!g_sockets[i].used) {
                g_sockets[i] = .{ .used = true, .id = 0, .room = undefined, .room_len = 0, .inbox = undefined, .head = 0, .count = 0 };
                return @intCast(i + 1);
            }
        }
        return 0;
    }

    pub fn state(h: Handle) State {
        if (h == 0 or !g_sockets[h - 1].used) return .closed;
        return .open; // mock sockets are open immediately
    }

    pub fn send(h: Handle, bytes: []const u8) void {
        if (h == 0 or !g_sockets[h - 1].used) return;
        const me: *MockSocket = &g_sockets[h - 1];
        if (std.mem.startsWith(u8, bytes, "JOIN ")) {
            const room: []const u8 = bytes[5..];
            const rn: usize = @min(room.len, me.room.len);
            @memcpy(me.room[0..rn], room[0..rn]);
            me.room_len = rn;
            // Room cap: count others already in this room (our id is still 0, so
            // the `id != 0` filter skips us). Full -> turn us away with FULL.
            var occ: usize = 0;
            var oc: usize = 0;
            while (oc < max_sock) : (oc += 1) {
                const other: *MockSocket = &g_sockets[oc];
                if (other.used and other.id != 0 and sameRoom(me, other)) {
                    occ += 1;
                }
            }
            if (occ >= core.max_peers) {
                sockEnqueue(me, "FULL");
                return;
            }
            me.id = g_next_id;
            g_next_id += 1;
            // WELCOME <my id> <existing peer ids in this room>
            var wbuf: [msg_cap]u8 = undefined;
            var wlen: usize = 0;
            const whead: []const u8 = std.fmt.bufPrint(wbuf[wlen..], "WELCOME {d}", .{me.id}) catch return;
            wlen += whead.len;
            var j: usize = 0;
            while (j < max_sock) : (j += 1) {
                const other: *MockSocket = &g_sockets[j];
                if (other.used and other.id != 0 and other.id != me.id and sameRoom(me, other)) {
                    const part: []const u8 = std.fmt.bufPrint(wbuf[wlen..], " {d}", .{other.id}) catch break;
                    wlen += part.len;
                }
            }
            sockEnqueue(me, wbuf[0..wlen]);
            // JOINED <my id> to everyone already here
            var jbuf: [msg_cap]u8 = undefined;
            const joined: []const u8 = std.fmt.bufPrint(&jbuf, "JOINED {d}", .{me.id}) catch return;
            j = 0;
            while (j < max_sock) : (j += 1) {
                const other: *MockSocket = &g_sockets[j];
                if (other.used and other.id != 0 and other.id != me.id and sameRoom(me, other)) {
                    sockEnqueue(other, joined);
                }
            }
        } else if (std.mem.startsWith(u8, bytes, "SIGNAL ")) {
            const rest: []const u8 = bytes[7..];
            const to_tok: []const u8 = firstToken(rest);
            const to: u32 = std.fmt.parseInt(u32, to_tok, 10) catch return;
            const raw: []const u8 = rest[to_tok.len + 1 ..];
            var fbuf: [msg_cap]u8 = undefined;
            const from_msg: []const u8 = std.fmt.bufPrint(&fbuf, "FROM {d} {s}", .{ me.id, raw }) catch return;
            var j: usize = 0;
            while (j < max_sock) : (j += 1) {
                if (g_sockets[j].used and g_sockets[j].id == to) {
                    sockEnqueue(&g_sockets[j], from_msg);
                }
            }
        } else if (std.mem.startsWith(u8, bytes, "RELAY ")) {
            const rrest: []const u8 = bytes[6..];
            const rto_tok: []const u8 = firstToken(rrest);
            const rto: u32 = std.fmt.parseInt(u32, rto_tok, 10) catch return;
            const rraw: []const u8 = rrest[rto_tok.len + 1 ..];
            var rbuf: [msg_cap]u8 = undefined;
            const relayed: []const u8 = std.fmt.bufPrint(&rbuf, "RELAYED {d} {s}", .{ me.id, rraw }) catch return;
            var k: usize = 0;
            while (k < max_sock) : (k += 1) {
                if (g_sockets[k].used and g_sockets[k].id == rto) {
                    sockEnqueue(&g_sockets[k], relayed);
                }
            }
        }
    }

    pub fn poll(h: Handle, out: []u8) ?[]const u8 {
        if (h == 0 or !g_sockets[h - 1].used) return null;
        const me: *MockSocket = &g_sockets[h - 1];
        if (me.count == 0) return null;
        const m: Msg = me.inbox[me.head];
        me.head = (me.head + 1) % q_cap;
        me.count -= 1;
        const n: usize = @min(m.len, out.len);
        @memcpy(out[0..n], m.buf[0..n]);
        return out[0..n];
    }

    pub fn close(h: Handle) void {
        if (h == 0 or !g_sockets[h - 1].used) return;
        const me: *MockSocket = &g_sockets[h - 1];
        var lbuf: [msg_cap]u8 = undefined;
        const left: []const u8 = std.fmt.bufPrint(&lbuf, "LEFT {d}", .{me.id}) catch "";
        var j: usize = 0;
        while (j < max_sock) : (j += 1) {
            const other: *MockSocket = &g_sockets[j];
            if (other.used and other.id != 0 and other.id != me.id and sameRoom(me, other)) {
                sockEnqueue(other, left);
            }
        }
        me.used = false;
    }
};

fn sameRoom(a: *const MockSocket, b: *const MockSocket) bool {
    if (a.room_len != b.room_len) return false;
    return std.mem.eql(u8, a.room[0..a.room_len], b.room[0..b.room_len]);
}

const mock_rtc = struct {
    pub const Handle = u32;
    pub const Event = RtcEvent;
    pub const EventKind = RtcEventKind;

    pub fn create() Handle {
        var i: usize = 0;
        while (i < max_pc) : (i += 1) {
            if (!g_pcs[i].used) {
                g_pcs[i] = .{ .used = true, .linked = 0, .events = undefined, .head = 0, .count = 0 };
                return @intCast(i + 1);
            }
        }
        return 0;
    }

    pub fn createOffer(h: Handle) void {
        if (h == 0 or !g_pcs[h - 1].used) return;
        var ob: [msg_cap]u8 = undefined;
        const offer: []const u8 = std.fmt.bufPrint(&ob, "SDP:offer:pc={d}", .{h}) catch return;
        pcEnqueue(&g_pcs[h - 1], .local_offer, 0, offer);
        var ib: [msg_cap]u8 = undefined;
        const ice: []const u8 = std.fmt.bufPrint(&ib, "ICE:pc={d}", .{h}) catch return;
        pcEnqueue(&g_pcs[h - 1], .local_ice, 0, ice);
    }

    pub fn setRemote(h: Handle, is_offer: bool, sdp: []const u8) void {
        if (h == 0 or !g_pcs[h - 1].used) return;
        const me: *MockPc = &g_pcs[h - 1];
        if (me.linked != 0) return; // already wired (e.g. offerer getting the answer)
        const src: u32 = parsePc(sdp);
        if (src == 0 or src > max_pc or !g_pcs[src - 1].used) return;
        // Wire the two pcs together, both ways, and open both channels on each.
        me.linked = src;
        g_pcs[src - 1].linked = h;
        pcEnqueue(me, .channel_open, 0, "");
        pcEnqueue(me, .channel_open, 1, "");
        pcEnqueue(&g_pcs[src - 1], .channel_open, 0, "");
        pcEnqueue(&g_pcs[src - 1], .channel_open, 1, "");
        if (is_offer) {
            var ab: [msg_cap]u8 = undefined;
            const ans: []const u8 = std.fmt.bufPrint(&ab, "SDP:answer:pc={d}", .{h}) catch return;
            pcEnqueue(me, .local_answer, 0, ans);
            var ib: [msg_cap]u8 = undefined;
            const ice: []const u8 = std.fmt.bufPrint(&ib, "ICE:pc={d}", .{h}) catch return;
            pcEnqueue(me, .local_ice, 0, ice);
        }
    }

    pub fn addIce(h: Handle, cand: []const u8) void {
        _ = h;
        _ = cand; // linkage is via the SDP in this mock; ICE is just accepted
    }

    pub fn send(h: Handle, channel: u8, bytes: []const u8) void {
        if (h == 0 or !g_pcs[h - 1].used) return;
        const me: *MockPc = &g_pcs[h - 1];
        if (me.linked == 0 or me.linked > max_pc) return;
        pcEnqueue(&g_pcs[me.linked - 1], .data, channel, bytes);
    }

    pub fn poll(h: Handle, out: []u8) ?Event {
        if (h == 0 or !g_pcs[h - 1].used) return null;
        const me: *MockPc = &g_pcs[h - 1];
        if (me.count == 0) return null;
        const e: Ev = me.events[me.head];
        me.head = (me.head + 1) % q_cap;
        me.count -= 1;
        const n: usize = @min(e.len, out.len);
        @memcpy(out[0..n], e.buf[0..n]);
        return .{ .kind = e.kind, .channel = e.channel, .payload = out[0..n] };
    }

    pub fn close(h: Handle) void {
        if (h == 0 or h > max_pc) return;
        g_pcs[h - 1].used = false;
    }
};

// Simulate every live peer connection failing (as if ICE gave up). Each linked
// pc gets a "failed" connectionState event, which net_core surfaces + acts on.
fn mockFailAll() void {
    var i: usize = 0;
    while (i < max_pc) : (i += 1) {
        if (g_pcs[i].used and g_pcs[i].linked != 0) {
            pcEnqueue(&g_pcs[i], .state, 0, "failed");
        }
    }
}

// Simulate the signaling socket dropping: the server notices and tells the room
// (LEFT), and the socket is gone so the owner's client sees state == closed.
fn mockDropSocket(h: u32) void {
    if (h == 0 or h > max_sock or !g_sockets[h - 1].used) return;
    const me: *MockSocket = &g_sockets[h - 1];
    var lbuf: [msg_cap]u8 = undefined;
    const left: []const u8 = std.fmt.bufPrint(&lbuf, "LEFT {d}", .{me.id}) catch "";
    var j: usize = 0;
    while (j < max_sock) : (j += 1) {
        const other: *MockSocket = &g_sockets[j];
        if (other.used and other.id != 0 and other.id != me.id and sameRoom(me, other)) {
            sockEnqueue(other, left);
        }
    }
    me.used = false;
}

const TestSession = core.Net(mock_ws, mock_rtc).Session;

// ------------------------------------------------------------------ event log

const RecKind = enum { joined_as, peer_joined, peer_state, channel_open, message, peer_left, host_changed, room_full };
const Rec = struct {
    kind: RecKind,
    peer: u32,
    channel: u8,
    data: [64]u8,
    data_len: usize,
};

const Log = struct {
    recs: [256]Rec,
    count: usize,

    fn init() Log {
        return .{ .recs = undefined, .count = 0 };
    }

    fn add(self: *Log, ev: core.Event) void {
        if (self.count >= self.recs.len) return;
        var r: Rec = .{ .kind = .joined_as, .peer = 0, .channel = 0, .data = undefined, .data_len = 0 };
        switch (ev) {
            .joined_as => |id| {
                r.kind = .joined_as;
                r.peer = id;
            },
            .peer_joined => |id| {
                r.kind = .peer_joined;
                r.peer = id;
            },
            .peer_state => |ps| {
                r.kind = .peer_state;
                r.peer = ps.peer;
                r.channel = @intFromEnum(ps.state);
            },
            .channel_open => |c| {
                r.kind = .channel_open;
                r.peer = c.peer;
                r.channel = c.channel;
            },
            .peer_left => |id| {
                r.kind = .peer_left;
                r.peer = id;
            },
            .host_changed => |id| {
                r.kind = .host_changed;
                r.peer = id;
            },
            .room_full => {
                r.kind = .room_full;
            },
            .message => |m| {
                r.kind = .message;
                r.peer = m.peer;
                r.channel = m.channel;
                const n: usize = @min(m.bytes.len, r.data.len);
                @memcpy(r.data[0..n], m.bytes[0..n]);
                r.data_len = n;
            },
        }
        self.recs[self.count] = r;
        self.count += 1;
    }

    fn has(self: *const Log, kind: RecKind, peer: u32) bool {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.recs[i].kind == kind and self.recs[i].peer == peer) return true;
        }
        return false;
    }

    fn hasState(self: *const Log, peer: u32, state: core.ConnState) bool {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const r: Rec = self.recs[i];
            if (r.kind == .peer_state and r.peer == peer and r.channel == @intFromEnum(state)) return true;
        }
        return false;
    }

    fn hasChannel(self: *const Log, peer: u32, channel: u8) bool {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const r: Rec = self.recs[i];
            if (r.kind == .channel_open and r.peer == peer and r.channel == channel) return true;
        }
        return false;
    }

    fn message(self: *const Log, peer: u32, channel: u8) ?[]const u8 {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const r: *const Rec = &self.recs[i];
            if (r.kind == .message and r.peer == peer and r.channel == channel) {
                return r.data[0..r.data_len];
            }
        }
        return null;
    }
};

fn pump(sessions: []const *TestSession, logs: []Log, rounds: usize) void {
    var r: usize = 0;
    while (r < rounds) : (r += 1) {
        var i: usize = 0;
        while (i < sessions.len) : (i += 1) {
            var buf: [1024]u8 = undefined;
            while (sessions[i].poll(&buf)) |ev| {
                logs[i].add(ev);
            }
        }
    }
}

fn expect(ok: bool) !void {
    if (!ok) return error.MeshAssertFailed;
}

// ------------------------------------------------------------------ the tests

test "two peers connect, channels open, messages flow both ways" {
    resetMocks();
    var a: TestSession = TestSession.init();
    var b: TestSession = TestSession.init();
    a.connect("mock://server", "room-x");
    b.connect("mock://server", "room-x");

    var sessions = [_]*TestSession{ &a, &b };
    var logs = [_]Log{ Log.init(), Log.init() };
    pump(&sessions, &logs, 24);

    // A is peer 1, B is peer 2 (ids handed out in join order).
    try expect(logs[0].has(.joined_as, 1));
    try expect(logs[1].has(.joined_as, 2));
    // Each sees the other as a peer.
    try expect(logs[0].has(.peer_joined, 2));
    try expect(logs[1].has(.peer_joined, 1));
    // Both channels open on both sides.
    try expect(logs[0].hasChannel(2, 0) and logs[0].hasChannel(2, 1));
    try expect(logs[1].hasChannel(1, 0) and logs[1].hasChannel(1, 1));

    // A broadcasts on the reliable channel; B receives it.
    a.broadcast(1, "hi-from-a");
    // B broadcasts on the unreliable channel; A receives it.
    b.broadcast(0, "hi-from-b");
    pump(&sessions, &logs, 8);

    const at_b: ?[]const u8 = logs[1].message(1, 1);
    try expect(at_b != null);
    try expect(std.mem.eql(u8, at_b.?, "hi-from-a"));
    const at_a: ?[]const u8 = logs[0].message(2, 0);
    try expect(at_a != null);
    try expect(std.mem.eql(u8, at_a.?, "hi-from-b"));
}

test "three-peer full mesh: a broadcast reaches both others" {
    resetMocks();
    var a: TestSession = TestSession.init();
    var b: TestSession = TestSession.init();
    var c: TestSession = TestSession.init();
    a.connect("mock://s", "tri");
    b.connect("mock://s", "tri");
    c.connect("mock://s", "tri");

    var sessions = [_]*TestSession{ &a, &b, &c };
    var logs = [_]Log{ Log.init(), Log.init(), Log.init() };
    pump(&sessions, &logs, 40);

    // A(1) sees 2 and 3; B(2) sees 1 and 3; C(3) sees 1 and 2.
    try expect(logs[0].has(.peer_joined, 2) and logs[0].has(.peer_joined, 3));
    try expect(logs[1].has(.peer_joined, 1) and logs[1].has(.peer_joined, 3));
    try expect(logs[2].has(.peer_joined, 1) and logs[2].has(.peer_joined, 2));
    // Every pair has an open reliable channel.
    try expect(logs[0].hasChannel(2, 1) and logs[0].hasChannel(3, 1));
    try expect(logs[1].hasChannel(1, 1) and logs[1].hasChannel(3, 1));
    try expect(logs[2].hasChannel(1, 1) and logs[2].hasChannel(2, 1));

    // A broadcasts once; both B and C get it directly (mesh, not relayed).
    a.broadcast(1, "mesh-hello");
    pump(&sessions, &logs, 10);
    const at_b: ?[]const u8 = logs[1].message(1, 1);
    const at_c: ?[]const u8 = logs[2].message(1, 1);
    try expect(at_b != null and std.mem.eql(u8, at_b.?, "mesh-hello"));
    try expect(at_c != null and std.mem.eql(u8, at_c.?, "mesh-hello"));
}

test "a peer leaving is reported to the others" {
    resetMocks();
    var a: TestSession = TestSession.init();
    var b: TestSession = TestSession.init();
    a.connect("mock://s", "bye");
    b.connect("mock://s", "bye");
    var sessions = [_]*TestSession{ &a, &b };
    var logs = [_]Log{ Log.init(), Log.init() };
    pump(&sessions, &logs, 24);
    try expect(logs[0].has(.peer_joined, 2));

    // B leaves; A should be told.
    b.disconnect();
    pump(&sessions, &logs, 8);
    try expect(logs[0].has(.peer_left, 2));
}

test "a failed connection falls back to relaying through the server" {
    resetMocks();
    var a: TestSession = TestSession.init();
    var b: TestSession = TestSession.init();

    a.connect("mock://s", "fail");
    b.connect("mock://s", "fail");
    var sessions = [_]*TestSession{ &a, &b };
    var logs = [_]Log{ Log.init(), Log.init() };
    pump(&sessions, &logs, 24);
    try expect(logs[0].hasChannel(2, 1)); // direct connection first

    // Both direct connections fail (ICE gives up).
    mockFailAll();
    pump(&sessions, &logs, 8);

    // Peers are NOT dropped — each side switches that peer to relay mode.
    try expect(logs[0].hasState(2, .relayed));
    try expect(logs[1].hasState(1, .relayed));
    try expect(!logs[0].has(.peer_left, 2));
    try expect(!logs[1].has(.peer_left, 1));

    // And messages still flow — now bounced through the (mock) server relay.
    a.broadcast(1, "relayed-msg");
    pump(&sessions, &logs, 8);
    const at_b: ?[]const u8 = logs[1].message(1, 1);
    try expect(at_b != null and std.mem.eql(u8, at_b.?, "relayed-msg"));
}

test "reconnects and re-establishes peers after the signaling socket drops" {
    resetMocks();
    var a: TestSession = TestSession.init();
    var b: TestSession = TestSession.init();

    a.connect("mock://s", "recon");
    b.connect("mock://s", "recon");
    var sessions = [_]*TestSession{ &a, &b };
    var logs = [_]Log{ Log.init(), Log.init() };
    pump(&sessions, &logs, 24);
    try expect(logs[0].hasChannel(2, 1)); // connected directly first

    // A's signaling socket drops (server slept / network changed).
    mockDropSocket(a.sock);
    // Reconnecting needs the cooldown to elapse, then a fresh handshake.
    pump(&sessions, &logs, 120);

    // A is connected again with a FRESH id, and B saw A's old id leave.
    try expect(a.isReady());
    try expect(logs[1].has(.peer_left, 1)); // B dropped A's old id (1)
    const new_a: u32 = a.myId();
    try expect(new_a != 1);

    // Messages flow again over the re-established connection (from A's new id).
    a.broadcast(1, "back-online");
    pump(&sessions, &logs, 12);
    const at_b: ?[]const u8 = logs[1].message(new_a, 1);
    try expect(at_b != null and std.mem.eql(u8, at_b.?, "back-online"));
}

const Emote = struct { kind: u32 = 0, x: f32 = 0, y: f32 = 0 };

test "typed messages round-trip a serialized struct over the mesh" {
    resetMocks();
    var a: TestSession = TestSession.init();
    var b: TestSession = TestSession.init();

    a.connect("mock://s", "typed");
    b.connect("mock://s", "typed");
    var sessions = [_]*TestSession{ &a, &b };
    var logs = [_]Log{ Log.init(), Log.init() };
    pump(&sessions, &logs, 24);
    try expect(logs[0].hasChannel(2, 1));

    // Send a structured, multi-field message (tag 7) — not hand-packed bytes.
    typed.broadcast(&a, 1, 7, Emote{ .kind = 3, .x = 1.5, .y = -2.25 });
    pump(&sessions, &logs, 8);

    const raw: ?[]const u8 = logs[1].message(1, 1); // from A (id 1), reliable channel
    try expect(raw != null);
    try expect(typed.tag(raw.?).? == 7);
    const decoded: Emote = try typed.decode(Emote, raw.?, std.heap.page_allocator);
    try expect(decoded.kind == 3);
    try expect(decoded.x == 1.5 and decoded.y == -2.25);
}

test "a full room turns away the extra peer" {
    resetMocks();
    const n = core.max_peers + 1;
    var sess: [n]TestSession = undefined;
    var logs: [n]Log = undefined;
    var ptrs: [n]*TestSession = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        sess[i] = TestSession.init();
        logs[i] = Log.init();
        ptrs[i] = &sess[i];
        sess[i].connect("mock://s", "packed");
    }
    pump(&ptrs, &logs, 60);

    // Exactly max_peers got in (each with a joined_as); the extra got room_full.
    var joined: usize = 0;
    i = 0;
    while (i < n) : (i += 1) {
        if (logs[i].has(.joined_as, @intCast(i + 1))) {
            joined += 1;
        }
    }
    try expect(joined == core.max_peers);
    try expect(logs[core.max_peers].has(.room_full, 0));
    try expect(!sess[core.max_peers].isActive()); // rejected -> stops trying
}

test "host is the lowest-id peer and migrates when it leaves" {
    resetMocks();
    var a: TestSession = TestSession.init();
    var b: TestSession = TestSession.init();
    var c: TestSession = TestSession.init();

    a.connect("mock://s", "host");
    b.connect("mock://s", "host");
    c.connect("mock://s", "host");
    var ptrs = [_]*TestSession{ &a, &b, &c };
    var logs = [_]Log{ Log.init(), Log.init(), Log.init() };
    pump(&ptrs, &logs, 40);

    // A (id 1) is the host, and everyone agrees on it.
    try expect(a.isHost());
    try expect(!b.isHost() and !c.isHost());
    try expect(a.hostId() == 1 and b.hostId() == 1 and c.hostId() == 1);
    try expect(logs[1].has(.host_changed, 1));

    // A leaves — the host migrates to the next lowest id (B = 2).
    a.disconnect();
    pump(&ptrs, &logs, 40);
    try expect(b.isHost());
    try expect(b.hostId() == 2 and c.hostId() == 2);
    try expect(logs[1].has(.host_changed, 2));
}

test "room names are valid, deterministic, and well-spread" {
    var buf: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;
    // deterministic
    const a: []const u8 = core.generateRoomName(12345, &buf);
    const b: []const u8 = core.generateRoomName(12345, &buf2);
    try expect(std.mem.eql(u8, a, b));
    // format: contains two dashes, ends in two digits
    var dashes: usize = 0;
    for (a) |ch| {
        if (ch == '-') dashes += 1;
    }
    try expect(dashes == 2);
    try expect(a[a.len - 1] >= '0' and a[a.len - 1] <= '9');
}
