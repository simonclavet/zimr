//! net_rtc_smoke — the WebRTC half of zimr P2P: two browser tabs open a DIRECT
//! peer-to-peer data-channel connection, using the signaling server only for
//! discovery and the SDP/ICE handshake. Once connected, the game data would
//! flow browser-to-browser with no server in the middle.
//!
//! Scope: 2 peers / one connection (a full mesh is layer L2's job). This is the
//! orchestration that L2's net.zig will generalize.
//!
//! Everything is driven by draining ws.poll + rtc.poll each frame:
//!   1. Connect to the signaling server, JOIN a room.
//!   2. Learn peers: WELCOME lists who's already here; JOINED announces arrivals.
//!   3. Offerer convention (avoids "glare" where both offer at once): the LOWER
//!      peer id offers to the HIGHER. So on JOINED (a higher id) we offer; on
//!      WELCOME (existing, lower ids) we create the connection and await theirs.
//!   4. Ferry the handshake over the relay: our rtc events (offer/answer/ICE)
//!      go out as `SIGNAL <peer> <kind> <data>`; the peer's come back as
//!      `FROM <peer> <kind> <data>` and feed rtc.setRemote / rtc.addIce.
//!   5. When a channel opens we greet on the reliable channel, and show whatever
//!      arrives. Lots of on-screen logging so failures are diagnosable.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const ui = z.ui_real;
const ws = z.web.ws;
const rtc = z.web.rtc;

const bufPrint = std.fmt.bufPrint;

const default_room = "zimr-rtc-demo";
const max_log = 14;
const sdp_cap = 16384; // SDP offers/answers run a few KB; ICE is tiny

const State = struct {
    gpa: Allocator,
    font: z.Font,
    ui_host: z.UiHost,

    url_buf: [256]u8,
    url_len: usize,
    room_buf: [64]u8,
    room_len: usize,

    sock: ws.Handle, // signaling socket, 0 = not connected
    joined: bool,
    my_id: u32,

    peer_id: u32, // the other peer (0 = none yet; this is a 2-peer demo)
    pc: rtc.Handle, // the RTC connection (0 = none)
    is_offerer: bool,
    chan_open: [2]bool, // channel 0 = cursor, 1 = clicks
    rtc_state: [24]u8, // last connection-state text
    rtc_state_len: usize,

    log: [max_log][192]u8,
    log_len: [max_log]usize,
    log_n: usize,

    ws_buf: [sdp_cap]u8, // ws.poll inbound (must hold FROM + SDP)
    rtc_buf: [sdp_cap]u8, // rtc.poll output (must hold SDP)
    send_buf: [sdp_cap]u8, // building outbound SIGNAL messages
};

const Split = struct { tok: []const u8, rest: []const u8 };

// Split "tok rest" on the first space. rest is "" when there's no space.
fn splitFirst(s: []const u8) Split {
    const sp: usize = std.mem.indexOfScalar(u8, s, ' ') orelse return .{ .tok = s, .rest = "" };
    return .{ .tok = s[0..sp], .rest = s[sp + 1 ..] };
}

fn onoff(b: bool) []const u8 {
    return if (b) "OPEN" else "-";
}

fn pushLog(s: *State, msg: []const u8) void {
    const slot: usize = s.log_n % max_log;
    const n: usize = @min(msg.len, s.log[slot].len);
    @memcpy(s.log[slot][0..n], msg[0..n]);
    s.log_len[slot] = n;
    s.log_n += 1;
}

fn logf(s: *State, comptime fmt: []const u8, args: anytype) void {
    var b: [192]u8 = undefined;
    const m: []const u8 = bufPrint(&b, fmt, args) catch b[0..0];
    pushLog(s, m);
}

fn setRtcState(s: *State, text: []const u8) void {
    const n: usize = @min(text.len, s.rtc_state.len);
    @memcpy(s.rtc_state[0..n], text[0..n]);
    s.rtc_state_len = n;
}

// Begin a connection to `peer`; remember whether we're the offerer.
fn startPeer(s: *State, peer: u32, offerer: bool) void {
    if (s.pc != 0) {
        return; // 2-peer demo: we already have a connection
    }
    s.peer_id = peer;
    s.is_offerer = offerer;
    s.chan_open = .{ false, false };
    s.rtc_state_len = 0;
    s.pc = rtc.create();
    if (offerer) {
        rtc.createOffer(s.pc);
        logf(s, "peer {d} joined; I offer (I'm {d})", .{ peer, s.my_id });
    } else {
        logf(s, "peer {d} present; awaiting offer (I'm {d})", .{ peer, s.my_id });
    }
}

fn teardownPeer(s: *State) void {
    if (s.pc != 0) {
        rtc.close(s.pc);
        s.pc = 0;
    }
    s.peer_id = 0;
    s.chan_open = .{ false, false };
    s.rtc_state_len = 0;
}

// Relay a handshake message to our peer: "SIGNAL <peer> <kind> <data>".
fn signalPeer(s: *State, kind: []const u8, data: []const u8) void {
    const msg: []const u8 = bufPrint(&s.send_buf, "SIGNAL {d} {s} {s}", .{ s.peer_id, kind, data }) catch {
        logf(s, "signal too big ({s}, {d}B)", .{ kind, data.len });
        return;
    };
    ws.send(s.sock, msg);
}

fn handleWsMessage(s: *State, msg: []const u8) void {
    if (std.mem.startsWith(u8, msg, "WELCOME ")) {
        // WELCOME <my_id> [existing ids...]. Existing peers joined first (lower
        // ids), so by convention they offer to us — we create + wait.
        const a: Split = splitFirst(msg[8..]);
        s.my_id = std.fmt.parseInt(u32, a.tok, 10) catch 0;
        logf(s, "joined as peer {d}", .{s.my_id});
        if (a.rest.len > 0) {
            const b: Split = splitFirst(a.rest);
            const existing: u32 = std.fmt.parseInt(u32, b.tok, 10) catch 0;
            if (existing != 0) {
                startPeer(s, existing, false); // we answer
            }
        }
    } else if (std.mem.startsWith(u8, msg, "JOINED ")) {
        // A newcomer (higher id) — we offer.
        const id: u32 = std.fmt.parseInt(u32, splitFirst(msg[7..]).tok, 10) catch 0;
        if (id != 0) {
            startPeer(s, id, true); // we offer
        }
    } else if (std.mem.startsWith(u8, msg, "LEFT ")) {
        const id: u32 = std.fmt.parseInt(u32, splitFirst(msg[5..]).tok, 10) catch 0;
        if (id == s.peer_id) {
            logf(s, "peer {d} left", .{id});
            teardownPeer(s);
        }
    } else if (std.mem.startsWith(u8, msg, "FROM ")) {
        // FROM <from> <kind> <data> — the peer's half of the handshake.
        const a: Split = splitFirst(msg[5..]); // from id
        const b: Split = splitFirst(a.rest); // kind
        const kind: []const u8 = b.tok;
        const data: []const u8 = b.rest;
        if (s.pc == 0) {
            return;
        }
        if (std.mem.eql(u8, kind, "offer")) {
            rtc.setRemote(s.pc, true, data);
            logf(s, "got offer ({d}B), answering", .{data.len});
        } else if (std.mem.eql(u8, kind, "answer")) {
            rtc.setRemote(s.pc, false, data);
            logf(s, "got answer ({d}B)", .{data.len});
        } else if (std.mem.eql(u8, kind, "ice")) {
            rtc.addIce(s.pc, data);
        }
    }
}

fn handleRtcEvent(s: *State, ev: rtc.Event) void {
    switch (ev.kind) {
        .local_offer => {
            signalPeer(s, "offer", ev.payload);
            logf(s, "sent offer ({d}B)", .{ev.payload.len});
        },
        .local_answer => {
            signalPeer(s, "answer", ev.payload);
            logf(s, "sent answer ({d}B)", .{ev.payload.len});
        },
        .local_ice => {
            signalPeer(s, "ice", ev.payload);
        },
        .channel_open => {
            if (ev.channel < 2) {
                s.chan_open[ev.channel] = true;
            }
            logf(s, "channel {d} open", .{ev.channel});
            if (ev.channel == 1) {
                var g: [64]u8 = undefined;
                const greet: []const u8 = bufPrint(&g, "hello from peer {d}", .{s.my_id}) catch "hello";
                rtc.send(s.pc, 1, greet);
            }
        },
        .data => {
            logf(s, "peer[ch{d}]: {s}", .{ ev.channel, ev.payload });
        },
        .state => {
            setRtcState(s, ev.payload);
            logf(s, "rtc state: {s}", .{ev.payload});
        },
        .none => {},
    }
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 20);
    s.* = .{
        .gpa = gpa,
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
        .url_buf = undefined,
        .url_len = 0,
        .room_buf = undefined,
        .room_len = 0,
        .sock = 0,
        .joined = false,
        .my_id = 0,
        .peer_id = 0,
        .pc = 0,
        .is_offerer = false,
        .chan_open = .{ false, false },
        .rtc_state = undefined,
        .rtc_state_len = 0,
        .log = undefined,
        .log_len = @splat(0),
        .log_n = 0,
        .ws_buf = undefined,
        .rtc_buf = undefined,
        .send_buf = undefined,
    };
    const origin: []const u8 = ws.originUrl(&s.url_buf);
    s.url_len = origin.len;
    @memcpy(s.room_buf[0..default_room.len], default_room);
    s.room_len = default_room.len;
}

fn deinit(gpa: Allocator, s: *State) void {
    teardownPeer(s);
    if (s.sock != 0) {
        ws.close(s.sock);
    }
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn update(f: *z.Frame, s: *State) void {
    // 1. Drive signaling.
    if (s.sock != 0) {
        const st: ws.State = ws.state(s.sock);
        if (st == .open and !s.joined) {
            var jb: [96]u8 = undefined;
            const room: []const u8 = s.room_buf[0..s.room_len];
            const jmsg: []const u8 = bufPrint(&jb, "JOIN {s}", .{room}) catch "JOIN zimr-rtc-demo";
            ws.send(s.sock, jmsg);
            s.joined = true;
        }
        if (st == .open) {
            while (ws.poll(s.sock, &s.ws_buf)) |m| {
                handleWsMessage(s, m);
            }
        }
    }
    // 2. Drive the RTC connection.
    if (s.pc != 0) {
        while (rtc.poll(s.pc, &s.rtc_buf)) |ev| {
            handleRtcEvent(s, ev);
        }
    }

    z.clearViewport(f, .{ .r = 14, .g = 16, .b = 22, .a = 255 });
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    if (u.window("P2P WebRTC (2 peers)", .{
        .initial_pos = .{ 12, 12 },
        .initial_size = .{ 500, 500 },
    })) |w| {
        defer w.close();

        if (s.sock == 0) {
            u.text("Signaling server:", .{});
            _ = u.inputTextWithHint("Server URL", "wss://your-app.onrender.com", &s.url_buf, &s.url_len, .{});
            _ = u.inputTextWithHint("Room", "room name", &s.room_buf, &s.room_len, .{});
            if (u.button("Connect", .{})) {
                if (s.url_len > 0) {
                    s.sock = ws.open(s.url_buf[0..s.url_len]);
                    s.joined = false;
                    s.my_id = 0;
                }
            }
        } else {
            const st: ws.State = ws.state(s.sock);
            const st_txt: []const u8 = switch (st) {
                .connecting => "connecting",
                .open => "open",
                .closed => "closed",
            };
            u.text("signaling: {s}    my id: {d}", .{ st_txt, s.my_id });
            if (s.peer_id != 0) {
                const role: []const u8 = if (s.is_offerer) "offerer" else "answerer";
                u.text("peer: {d}    role: {s}", .{ s.peer_id, role });
                const rs: []const u8 = if (s.rtc_state_len > 0) s.rtc_state[0..s.rtc_state_len] else "negotiating";
                u.text("rtc: {s}", .{rs});
                u.text("ch0 cursor: {s}    ch1 clicks: {s}", .{ onoff(s.chan_open[0]), onoff(s.chan_open[1]) });
                if (s.chan_open[1]) {
                    if (u.button("Send ping on reliable channel", .{})) {
                        var mb: [64]u8 = undefined;
                        const m: []const u8 = bufPrint(&mb, "ping from {d}", .{s.my_id}) catch "ping";
                        rtc.send(s.pc, 1, m);
                        logf(s, "-> sent: {s}", .{m});
                    }
                }
            } else {
                u.text("waiting for another tab in room '{s}'...", .{s.room_buf[0..s.room_len]});
            }
            if (u.button("Disconnect", .{})) {
                teardownPeer(s);
                ws.close(s.sock);
                s.sock = 0;
                s.joined = false;
            }
        }

        u.text("--- log ---", .{});
        const total: usize = s.log_n;
        const start: usize = if (total > max_log) total - max_log else 0;
        var i: usize = start;
        while (i < total) : (i += 1) {
            const slot: usize = i % max_log;
            u.text("{s}", .{s.log[slot][0..s.log_len[slot]]});
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - p2p webrtc",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .update = update,
    .deinit = deinit,
};
