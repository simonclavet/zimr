//! net_ws_smoke - the WebSocket half of zimr's P2P signaling, running in a
//! browser. It connects to the L0 signaling server (tools/signal_server.zig or
//! its Render-deployable twin tools/render_server.zig), joins a room, and shows
//! the live protocol: WELCOME / JOINED / LEFT / FROM messages as they arrive.
//!
//! Two ways to use it:
//!   1. Served BY the signaling server (render_server.zig serves this page):
//!      the "Server URL" field is pre-filled with the page's own origin, so you
//!      just tap Connect. Open the page in two tabs and they discover each other.
//!   2. Hosted anywhere else: type your server's "wss://..." URL into the field
//!      first, then tap Connect.
//!
//! This drives `z.web.ws` end to end: originUrl -> open -> state -> send -> poll
//! -> close, all as a per-frame polling loop (wasm can't block on the network).
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const ui = z.ui_real;

const bufPrint = std.fmt.bufPrint;

const default_room = "zimr-demo";
const max_log = 12; // how many recent messages to keep on screen

const State = struct {
    gpa: Allocator,
    font: z.Font,
    ui_host: z.UiHost,

    // Editable fields (pre-filled in init). inputText owns a buffer + a length.
    url_buf: [256]u8,
    url_len: usize,
    room_buf: [64]u8,
    room_len: usize,

    sock: z.web.ws.Handle, // 0 = not connected
    joined: bool, // have we sent our JOIN on this connection yet?
    my_id: [16]u8, // our peer id, parsed out of WELCOME
    my_id_len: usize,

    // A small ring of recent messages so the panel shows live traffic.
    log: [max_log][192]u8,
    log_len: [max_log]usize,
    log_n: usize, // total messages seen; ring slot = log_n % max_log

    recv_buf: [8192]u8, // scratch we poll inbound frames into
};

fn pushLog(s: *State, msg: []const u8) void {
    const slot: usize = s.log_n % max_log;
    const n: usize = @min(msg.len, s.log[slot].len);
    @memcpy(s.log[slot][0..n], msg[0..n]);
    s.log_len[slot] = n;
    s.log_n += 1;
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
        .my_id = undefined,
        .my_id_len = 0,
        .log = undefined,
        .log_len = @splat(0),
        .log_n = 0,
        .recv_buf = undefined,
    };
    // Pre-fill the URL with this page's own origin (so a page served by the
    // signaling server just works), and the room with a shared default.
    const origin: []const u8 = z.web.ws.originUrl(&s.url_buf);
    s.url_len = origin.len;
    @memcpy(s.room_buf[0..default_room.len], default_room);
    s.room_len = default_room.len;
}

fn deinit(gpa: Allocator, s: *State) void {
    if (s.sock != 0) {
        z.web.ws.close(s.sock);
    }
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn update(f: *z.Frame, s: *State) void {
    // If we have a socket, drive it: join once open, then drain inbound.
    if (s.sock != 0) {
        const st: z.web.ws.State = z.web.ws.state(s.sock);
        if (st == .open and !s.joined) {
            var join_buf: [96]u8 = undefined;
            const room: []const u8 = s.room_buf[0..s.room_len];
            const jmsg: []const u8 = bufPrint(&join_buf, "JOIN {s}", .{room}) catch "JOIN zimr-demo";
            z.web.ws.send(s.sock, jmsg);
            s.joined = true;
            pushLog(s, jmsg);
        }
        if (st == .open) {
            while (z.web.ws.poll(s.sock, &s.recv_buf)) |msg| {
                pushLog(s, msg);
                if (std.mem.startsWith(u8, msg, "WELCOME ")) {
                    const rest: []const u8 = msg[8..];
                    const end: usize = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
                    const id: []const u8 = rest[0..end];
                    const n: usize = @min(id.len, s.my_id.len);
                    @memcpy(s.my_id[0..n], id[0..n]);
                    s.my_id_len = n;
                }
            }
        }
    }

    z.clearViewport(f, .{ .r = 16, .g = 18, .b = 24, .a = 255 });

    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    if (u.window("P2P signaling (WebSocket)", .{
        .initial_pos = .{ 12, 12 },
        .initial_size = .{ 460, 440 },
    })) |w| {
        defer w.close();

        if (s.sock == 0) {
            // Not connected: show the connect form.
            u.text("Signaling server to connect to:", .{});
            _ = u.inputTextWithHint("Server URL", "wss://your-app.onrender.com", &s.url_buf, &s.url_len, .{});
            _ = u.inputTextWithHint("Room", "room name", &s.room_buf, &s.room_len, .{});
            if (u.button("Connect", .{})) {
                if (s.url_len > 0) {
                    s.sock = z.web.ws.open(s.url_buf[0..s.url_len]);
                    s.joined = false;
                    s.my_id_len = 0;
                    pushLog(s, "-> connecting...");
                }
            }
        } else {
            // Connected: show status + controls.
            const st: z.web.ws.State = z.web.ws.state(s.sock);
            const state_text: []const u8 = switch (st) {
                .connecting => "connecting...",
                .open => "open",
                .closed => "closed (server unreachable or dropped)",
            };
            u.text("Server: {s}", .{s.url_buf[0..s.url_len]});
            u.text("State:  {s}", .{state_text});
            if (s.my_id_len > 0) {
                u.text("My peer id: {s}", .{s.my_id[0..s.my_id_len]});
            }
            u.text("Room:   {s}", .{s.room_buf[0..s.room_len]});

            if (u.button("Disconnect", .{})) {
                z.web.ws.close(s.sock);
                s.sock = 0;
                s.joined = false;
            }
            if (st == .open) {
                if (u.button("Send SIGNAL to peer 1", .{})) {
                    z.web.ws.send(s.sock, "SIGNAL 1 hello-from-a-tab");
                    pushLog(s, "-> SIGNAL 1 hello-from-a-tab");
                }
            }
        }

        u.text("--- recent messages ---", .{});
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
            .title = "zimr - p2p signaling (ws)",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .update = update,
    .deinit = deinit,
};
