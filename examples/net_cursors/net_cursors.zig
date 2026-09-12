//! net_cursors — the payoff demo: a shared 2D canvas where everyone in the room
//! sees everyone else's mouse cursor moving in real time, and clicks send a
//! ripple that all peers see. This is the "invite friends to a local game"
//! goal in its simplest form.
//!
//! It's built entirely on `z.net.Session` (the L2 layer), so it's also the
//! reference for how to use it:
//!   - `session.connect(url, room)` to join (host generates a shareable room
//!     name; others type it in).
//!   - each frame, `session.broadcast(channel, bytes)` your cursor, and drain
//!     `session.poll(&buf)` for peers joining/leaving and their messages.
//!
//! Wire format is deliberately tiny: a cursor or click is two f32s (normalized
//! [0,1] so it maps correctly regardless of each peer's window size), 8 bytes.
//! Cursors go on channel 0 (unreliable — a dropped position is instantly
//! replaced by the next); clicks go on channel 1 (reliable — never dropped).
//!
//! Native builds render the UI but do no networking (ws/rtc are wasm-only), so
//! the headless smoke test exercises the whole thing harmlessly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const net = z.net;
const ui = z.ui_real;

const Vec2 = zm.Vec2;
const Color = zm.Color;
const bufPrint = std.fmt.bufPrint;
const clamp01 = zm.clamp01;

const chan_cursor = 0; // unreliable, unordered
const chan_click = 1; // reliable, ordered
const ripple_life = 0.8; // seconds
const ripple_max_r = 46.0; // px at end of life
const max_ripples = 24;

// A peer's latest cursor position (normalized), tracked from their messages.
const PeerView = struct {
    id: u32,
    nx: f32,
    ny: f32,
    active: bool,
    has_pos: bool,
};

const Ripple = struct {
    nx: f32,
    ny: f32,
    age: f32,
    color: Color,
    active: bool,
};

// A friendly, distinct colour per peer (indexed by id).
const peer_colors = [_]Color{
    .{ .r = 239, .g = 71, .b = 111, .a = 255 },
    .{ .r = 255, .g = 209, .b = 102, .a = 255 },
    .{ .r = 6, .g = 214, .b = 160, .a = 255 },
    .{ .r = 17, .g = 138, .b = 178, .a = 255 },
    .{ .r = 131, .g = 56, .b = 236, .a = 255 },
    .{ .r = 251, .g = 133, .b = 0, .a = 255 },
    .{ .r = 58, .g = 134, .b = 255, .a = 255 },
    .{ .r = 131, .g = 197, .b = 190, .a = 255 },
};

fn peerColor(id: u32) Color {
    return peer_colors[id % peer_colors.len];
}

fn withAlpha(c: Color, a: u8) Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
}

// A cursor/click position is two f32s. WASM is little-endian everywhere, so a
// raw bit copy is a fine, tiny wire format between browsers.
fn packVec2(nx: f32, ny: f32) [8]u8 {
    const v: [2]f32 = .{ nx, ny };
    return @bitCast(v);
}

fn unpackVec2(bytes: []const u8) ?[2]f32 {
    if (bytes.len < 8) {
        return null;
    }
    var tmp: [8]u8 = undefined;
    @memcpy(&tmp, bytes[0..8]);
    return @as([2]f32, @bitCast(tmp));
}

const State = struct {
    gpa: Allocator,
    font: z.Font,
    ui_host: z.UiHost,

    session: net.Session,
    url_buf: [256]u8,
    url_len: usize,
    room_buf: [64]u8,
    room_len: usize,

    peers: [net.max_peers]PeerView,
    ripples: [max_ripples]Ripple,
    my_nx: f32,
    my_ny: f32,

    poll_buf: [512]u8, // receives message bytes from session.poll (msgs are 8B)
};

fn peerView(s: *State, id: u32) ?*PeerView {
    var i: usize = 0;
    while (i < s.peers.len) : (i += 1) {
        if (s.peers[i].active and s.peers[i].id == id) {
            return &s.peers[i];
        }
    }
    return null;
}

fn addPeerView(s: *State, id: u32) void {
    if (peerView(s, id) != null) {
        return;
    }
    var i: usize = 0;
    while (i < s.peers.len) : (i += 1) {
        if (!s.peers[i].active) {
            s.peers[i] = .{ .id = id, .nx = 0.5, .ny = 0.5, .active = true, .has_pos = false };
            return;
        }
    }
}

fn removePeerView(s: *State, id: u32) void {
    if (peerView(s, id)) |p| {
        p.active = false;
    }
}

fn spawnRipple(s: *State, nx: f32, ny: f32, color: Color) void {
    var i: usize = 0;
    var oldest: usize = 0;
    var oldest_age: f32 = -1.0;
    while (i < s.ripples.len) : (i += 1) {
        if (!s.ripples[i].active) {
            s.ripples[i] = .{ .nx = nx, .ny = ny, .age = 0.0, .color = color, .active = true };
            return;
        }
        if (s.ripples[i].age > oldest_age) {
            oldest_age = s.ripples[i].age;
            oldest = i;
        }
    }
    // All slots busy — recycle the oldest.
    s.ripples[oldest] = .{ .nx = nx, .ny = ny, .age = 0.0, .color = color, .active = true };
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 20);
    s.* = .{
        .gpa = gpa,
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
        .session = net.Session.init(),
        .url_buf = undefined,
        .url_len = 0,
        .room_buf = undefined,
        .room_len = 0,
        .peers = undefined,
        .ripples = undefined,
        .my_nx = 0.5,
        .my_ny = 0.5,
        .poll_buf = undefined,
    };
    var i: usize = 0;
    while (i < s.peers.len) : (i += 1) {
        s.peers[i] = .{ .id = 0, .nx = 0, .ny = 0, .active = false, .has_pos = false };
    }
    i = 0;
    while (i < s.ripples.len) : (i += 1) {
        s.ripples[i] = .{ .nx = 0, .ny = 0, .age = 0, .color = peer_colors[0], .active = false };
    }
    const origin: []const u8 = z.web.ws.originUrl(&s.url_buf);
    s.url_len = origin.len;
}

fn deinit(gpa: Allocator, s: *State) void {
    s.session.disconnect();
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn hostRoom(s: *State) void {
    var name_buf: [32]u8 = undefined;
    const seed: u64 = @trunc(z.web.dom.epochMillis());
    const name: []const u8 = net.generateRoomName(seed, &name_buf);
    const n: usize = @min(name.len, s.room_buf.len);
    @memcpy(s.room_buf[0..n], name[0..n]);
    s.room_len = n;
    s.session.connect(s.url_buf[0..s.url_len], s.room_buf[0..s.room_len]);
}

fn joinRoom(s: *State) void {
    if (s.room_len == 0) {
        return;
    }
    s.session.connect(s.url_buf[0..s.url_len], s.room_buf[0..s.room_len]);
}

fn update(f: *z.Frame, s: *State) void {
    const dt: f32 = f.time.delta_time;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();

    // 1. Drain the session: peers joining/leaving and their cursor/click bytes.
    while (s.session.poll(&s.poll_buf)) |ev| {
        switch (ev) {
            .joined_as => {},
            .peer_joined => |id| addPeerView(s, id),
            .peer_state => {}, // terminal states also fire peer_left, handled below
            .channel_open => {},
            .peer_left => |id| removePeerView(s, id),
            .host_changed => {}, // cursors are peer-owned; no host needed here
            .room_full => {}, // (would show "room full"; unreachable at this demo's scale)
            .message => |m| {
                if (unpackVec2(m.bytes)) |pos| {
                    if (m.channel == chan_cursor) {
                        if (peerView(s, m.peer)) |p| {
                            p.nx = clamp01(pos[0]);
                            p.ny = clamp01(pos[1]);
                            p.has_pos = true;
                        }
                    } else if (m.channel == chan_click) {
                        spawnRipple(s, clamp01(pos[0]), clamp01(pos[1]), peerColor(m.peer));
                    }
                }
            },
        }
    }

    // 2. Send my own cursor + clicks (only once we're fully joined).
    if (s.session.isReady()) {
        const mouse: Vec2 = z.getMousePosition(f.input);
        s.my_nx = clamp01(mouse[0] / w);
        s.my_ny = clamp01(mouse[1] / h);
        const cur: [8]u8 = packVec2(s.my_nx, s.my_ny);
        s.session.broadcast(chan_cursor, &cur);
        if (z.isMouseButtonPressed(f.input, .left)) {
            const clk: [8]u8 = packVec2(s.my_nx, s.my_ny);
            s.session.broadcast(chan_click, &clk);
            spawnRipple(s, s.my_nx, s.my_ny, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
        }
    }

    // 3. Age ripples.
    var i: usize = 0;
    while (i < s.ripples.len) : (i += 1) {
        if (s.ripples[i].active) {
            s.ripples[i].age += dt;
            if (s.ripples[i].age >= ripple_life) {
                s.ripples[i].active = false;
            }
        }
    }

    // 4. Render the canvas.
    z.clearViewport(f, .{ .r = 15, .g = 17, .b = 24, .a = 255 });

    // ripples (expanding, fading rings)
    i = 0;
    while (i < s.ripples.len) : (i += 1) {
        const rp: Ripple = s.ripples[i];
        if (!rp.active) {
            continue;
        }
        const t: f32 = rp.age / ripple_life;
        const radius: f32 = 6.0 + t * ripple_max_r;
        const alpha_f: f32 = (1.0 - t) * 220.0;
        const alpha: u8 = @trunc(@max(0.0, alpha_f));
        const center: Vec2 = .{ rp.nx * w, rp.ny * h };
        f.gl.circle(center, radius, .{ .color = withAlpha(rp.color, alpha), .outline = 2.5, .segments = 32 });
    }

    // peer cursors
    i = 0;
    while (i < s.peers.len) : (i += 1) {
        const p: PeerView = s.peers[i];
        if (!p.active or !p.has_pos) {
            continue;
        }
        const col: Color = peerColor(p.id);
        const center: Vec2 = .{ p.nx * w, p.ny * h };
        drawCursor(f, center, col);
        var label: [24]u8 = undefined;
        const txt: []const u8 = bufPrint(&label, "peer {d}", .{p.id}) catch "peer";
        const label_pos: Vec2 = .{ center[0] + 12.0, center[1] - 6.0 };
        f.gl.text(label_pos, txt, .{ .size = 13, .color = col, .font = &s.font });
    }

    // my own cursor (a hollow ring so it reads as "me")
    if (s.session.isReady()) {
        const me: Vec2 = .{ s.my_nx * w, s.my_ny * h };
        const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 235 };
        f.gl.circle(me, 10.0, .{ .color = white, .outline = 2.0, .segments = 28 });
        f.gl.circle(me, 2.5, .{ .color = white, .segments = 12 });
    }

    // 5. UI overlay.
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    if (u.window("Shared cursors", .{
        .initial_pos = .{ 12, 12 },
        .initial_size = .{ 340, 250 },
    })) |win| {
        defer win.close();
        if (!s.session.isActive()) {
            u.text("Signaling server:", .{});
            _ = u.inputTextWithHint("Server URL", "wss://your-app.onrender.com", &s.url_buf, &s.url_len, .{});
            if (u.button("Host a new room", .{})) {
                hostRoom(s);
            }
            u.text("or join an existing room:", .{});
            _ = u.inputTextWithHint("Room name", "brave-otter-42", &s.room_buf, &s.room_len, .{});
            if (u.button("Join room", .{})) {
                joinRoom(s);
            }
        } else {
            u.text("room: {s}", .{s.room_buf[0..s.room_len]});
            if (s.session.isReady()) {
                u.text("you are peer {d}", .{s.session.myId()});
            } else {
                u.text("connecting...", .{});
            }
            u.text("peers connected: {d}", .{activePeers(s)});
            u.text("move your mouse; click to ripple", .{});
            if (u.button("Leave", .{})) {
                s.session.disconnect();
                clearPeers(s);
            }
        }
    }
}

fn activePeers(s: *State) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.peers.len) : (i += 1) {
        if (s.peers[i].active) {
            n += 1;
        }
    }
    return n;
}

fn clearPeers(s: *State) void {
    var i: usize = 0;
    while (i < s.peers.len) : (i += 1) {
        s.peers[i].active = false;
    }
}

// A simple arrow-ish cursor: a filled dot with a short tail line.
fn drawCursor(f: *z.Frame, center: Vec2, col: Color) void {
    const tail: Vec2 = .{ center[0] - 10.0, center[1] - 10.0 };
    f.gl.line(tail, center, .{ .color = withAlpha(col, 180), .thickness = 2.0 });
    f.gl.circle(center, 7.0, .{ .color = col, .segments = 20 });
    f.gl.circle(center, 3.0, .{ .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 }, .segments = 12 });
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - shared cursors",
            .width = 960,
            .height = 600,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .update = update,
    .deinit = deinit,
};
