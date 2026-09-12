//! ============================================================================
//! render_server.zig — the signaling server, packaged to deploy on a host
//! ============================================================================
//!
//! This is the deploy-friendly twin of tools/signal_server.zig. It does the
//! exact same WebSocket signaling relay (rooms + JOIN/SIGNAL/WELCOME/JOINED/
//! LEFT/FROM — see that file's header for the full protocol and design notes),
//! but it adds ONE thing: it also serves the net_ws_smoke standalone page over
//! plain HTTP. That means a single deployment does everything:
//!
//!   * Open https://<your-app>/ in a browser  -> you get the demo page.
//!   * The page connects back to wss://<same host>/ -> same origin, so there's
//!     nothing to type and no mixed-content problem (an https page is only
//!     allowed to open a secure wss:// socket, and here it's the same host).
//!   * Open the URL in a second tab -> the two tabs discover each other.
//!
//! Deploy notes:
//!   * Hosts like Render terminate TLS at their edge and forward plain traffic
//!     (including the WebSocket upgrade) to this process on the port given by
//!     the PORT environment variable. We read PORT and listen on 0.0.0.0, which
//!     is exactly what the platform expects. Locally, PORT defaults to 7777.
//!   * A plain HTTP GET (a browser hitting "/", or a platform health check)
//!     gets the page back with a 200, so health checks pass too.
//!
//! Both demo pages are baked into the binary with @embedFile, so the whole
//! server is a single self-contained executable — copy it onto a host and run
//! it, no other files needed. (Rebuild the pages with `zig build
//! net-rtc-smoke-standalone net-ws-smoke-standalone -Dmode=release` and copy
//! the results to
//! tools/standalone.html to refresh what's served.)
//!
//! Build a portable static Linux binary (runs on essentially any x86-64 Linux
//! or in a scratch/alpine container, no libc needed):
//!   zig build-exe tools/render_server.zig -target x86_64-linux-musl \
//!       -O ReleaseFast -femit-bin=render_server
//! ============================================================================

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const ascii = std.ascii;
const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;

// The demo page, baked right into the binary. This is the build output of
// `zig build net-ws-smoke-standalone`, copied to tools/standalone.html.
// Two demo pages, baked into the binary. `/` and `/rtc` serve the WebRTC test;
// `/ws` serves the WebSocket-signaling test. A WebSocket upgrade works from
// either page (the relay ignores the request path), so both pages talk to this
// same server over the same wss:// endpoint.
// Three demo pages, baked into the binary. `/` serves the shared-cursors demo
// (the main event); `/rtc` serves the 2-peer WebRTC diagnostic; `/ws` serves
// the WebSocket-signaling test. A WebSocket upgrade works from any page (the
// relay ignores the request path), so all three talk to this same server over
// the same wss:// endpoint.
const cursors_html = @embedFile("standalone_cursors.html");
const rtc_html = @embedFile("standalone_rtc.html");
const ws_html = @embedFile("standalone_ws.html");

const magic_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"; // per RFC 6455
const default_port = "7777";
const max_message_bytes: usize = 16 * 1024;
const read_buffer_bytes: usize = max_message_bytes + 4096;
const room_cap: usize = 8; // max peers per room — matches net_core's max_peers (the mesh cap)

const Peer = struct {
    id: u32,
    room: [64]u8 = undefined,
    room_len: usize = 0,
    stream: net.Stream,
    alive: bool = true,

    fn roomName(self: *const Peer) []const u8 {
        return self.room[0..self.room_len];
    }
    fn setRoom(self: *Peer, name: []const u8) void {
        const n: usize = @min(name.len, self.room.len);
        @memcpy(self.room[0..n], name[0..n]);
        self.room_len = n;
    }
};

const Registry = struct {
    mutex: Io.Mutex = .init,
    gpa: Allocator,
    peers: std.ArrayList(*Peer) = .empty,
    next_id: u32 = 1,
};

var registry: Registry = undefined; // lint:off module-var: server-wide peer registry, guarded by the async mutex

const Opcode = struct {
    const text: u8 = 0x1;
    const close: u8 = 0x8;
    const ping: u8 = 0x9;
    const pong: u8 = 0xA;
};

const Frame = struct { opcode: u8, len: usize };

// ---- WebSocket framing (identical to signal_server.zig; see there for the
// full byte-by-byte explanation of the frame layout and masking) ------------

fn readFrame(reader: *Io.Reader, out: []u8) !Frame {
    const header: []u8 = try reader.take(2);
    const byte0: u8 = header[0];
    const byte1: u8 = header[1];
    const opcode: u8 = byte0 & 0x0F;
    const masked: bool = (byte1 & 0x80) != 0;
    var len: usize = byte1 & 0x7F;
    if (len == 126) {
        const ext: []u8 = try reader.take(2);
        len = (@as(usize, ext[0]) << 8) | ext[1];
    } else if (len == 127) {
        const ext: []u8 = try reader.take(8);
        len = 0;
        for (ext) |b| {
            len = (len << 8) | b;
        }
    }
    if (len > out.len) {
        return error.MessageTooLarge;
    }
    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        const m: []u8 = try reader.take(4);
        mask = m[0..4].*;
    }
    if (len > 0) {
        const payload: []u8 = try reader.take(len);
        @memcpy(out[0..len], payload);
    }
    if (masked) {
        for (out[0..len], 0..) |*byte, i| {
            byte.* ^= mask[i % 4];
        }
    }
    return .{ .opcode = opcode, .len = len };
}

fn writeFrame(io: Io, stream: net.Stream, opcode: u8, payload: []const u8) !void {
    var header: [10]u8 = undefined;
    var header_len: usize = 0;
    header[0] = 0x80 | opcode;
    if (payload.len < 126) {
        header[1] = @intCast(payload.len);
        header_len = 2;
    } else if (payload.len < 65536) {
        header[1] = 126;
        header[2] = @intCast((payload.len >> 8) & 0xFF);
        header[3] = @intCast(payload.len & 0xFF);
        header_len = 4;
    } else {
        header[1] = 127;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            header[2 + i] = @intCast((payload.len >> @intCast((7 - i) * 8)) & 0xFF);
        }
        header_len = 10;
    }
    var writer: net.Stream.Writer = stream.writer(io, &.{});
    try writer.interface.writeAll(header[0..header_len]);
    if (payload.len > 0) {
        try writer.interface.writeAll(payload);
    }
    try writer.interface.flush();
}

fn sendText(io: Io, peer: *Peer, text: []const u8) void {
    writeFrame(io, peer.stream, Opcode.text, text) catch {
        peer.alive = false;
    };
}

// ---- HTTP: read the request head, and serve the page -----------------------

fn findHeaderValue(head: []const u8, name_lower: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        const colon: usize = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name: []const u8 = std.mem.trim(u8, line[0..colon], " \t");
        if (ascii.eqlIgnoreCase(name, name_lower)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

fn computeAccept(key: []const u8, out: []u8) []const u8 {
    var hasher: std.crypto.hash.Sha1 = .init(.{});
    hasher.update(key);
    hasher.update(magic_guid);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}

// Pull bytes until we've seen the blank line that ends the HTTP head. Returns
// false if the peer closed before finishing it.
fn readHttpHead(reader: *Io.Reader) bool {
    while (std.mem.indexOf(u8, reader.buffered(), "\r\n\r\n") == null) {
        const before: usize = reader.buffered().len;
        reader.fillMore() catch return false;
        if (reader.buffered().len == before) {
            return false;
        }
    }
    return true;
}

// Serve the embedded demo page (also what health checks get). Sends a proper
// Content-Length so the browser knows when the 2 MB body is done, then closes.
fn serveHttp(io: Io, stream: net.Stream, html: []const u8) !void {
    var header_buf: [256]u8 = undefined;
    const header: []const u8 = try bufPrint(&header_buf, "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/html; charset=utf-8\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n\r\n", .{html.len});
    var writer: net.Stream.Writer = stream.writer(io, &.{});
    try writer.interface.writeAll(header);
    try writer.interface.writeAll(html);
    try writer.interface.flush();
}

// Pull the request path out of the HTTP head's first line ("GET /path HTTP/1.1").
fn requestPath(head: []const u8) []const u8 {
    const line_end: usize = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    const line: []const u8 = head[0..line_end];
    const sp1: usize = std.mem.indexOfScalar(u8, line, ' ') orelse return "/";
    const rest: []const u8 = line[sp1 + 1 ..];
    const sp2: usize = std.mem.indexOfScalar(u8, rest, ' ') orelse return rest;
    return rest[0..sp2];
}

// Map a request path to a page: /ws -> signaling test, /rtc -> WebRTC test,
// everything else (including "/") -> the shared-cursors demo.
fn choosePage(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "/ws")) {
        return ws_html;
    }
    if (std.mem.startsWith(u8, path, "/rtc")) {
        return rtc_html;
    }
    return cursors_html;
}

// ---- signaling handlers (identical to signal_server.zig) -------------------

fn handleJoin(io: Io, peer: *Peer, room: []const u8) !void {
    peer.setRoom(room);
    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);

    // Room cap: count who's already here. If the room is full, turn this peer
    // away with FULL rather than letting it join a mesh that can't hold it.
    var occupancy: usize = 0;
    for (registry.peers.items) |other| {
        if (other.alive and std.mem.eql(u8, other.roomName(), room)) {
            occupancy += 1;
        }
    }
    if (occupancy >= room_cap) {
        sendText(io, peer, "FULL");
        return;
    }

    var welcome_buf: [1024]u8 = undefined;
    var used: usize = (try bufPrint(&welcome_buf, "WELCOME {d}", .{peer.id})).len;
    for (registry.peers.items) |other| {
        if (other.alive and std.mem.eql(u8, other.roomName(), room)) {
            const chunk: []u8 = bufPrint(welcome_buf[used..], " {d}", .{other.id}) catch break;
            used += chunk.len;
        }
    }

    var joined_buf: [32]u8 = undefined;
    const joined: []const u8 = try bufPrint(&joined_buf, "JOINED {d}", .{peer.id});
    for (registry.peers.items) |other| {
        if (other.alive and std.mem.eql(u8, other.roomName(), room)) {
            sendText(io, other, joined);
        }
    }

    try registry.peers.append(registry.gpa, peer);
    sendText(io, peer, welcome_buf[0..used]);
}

fn handleSignal(io: Io, peer: *Peer, rest: []const u8) !void {
    const space: usize = std.mem.indexOfScalar(u8, rest, ' ') orelse return;
    const to_id: u32 = std.fmt.parseInt(u32, rest[0..space], 10) catch return;
    const data: []const u8 = rest[space + 1 ..];

    const out: []u8 = try registry.gpa.alloc(u8, 32 + data.len);
    defer registry.gpa.free(out);
    const prefix: []const u8 = try bufPrint(out, "FROM {d} ", .{peer.id});
    @memcpy(out[prefix.len .. prefix.len + data.len], data);
    const message: []const u8 = out[0 .. prefix.len + data.len];

    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);
    for (registry.peers.items) |other| {
        if (other.alive and other.id == to_id and std.mem.eql(u8, other.roomName(), peer.roomName())) {
            sendText(io, other, message);
            break;
        }
    }
}

// Relay game DATA between two peers whose direct P2P connection failed — the
// server-relay fallback. Identical to handleSignal but with a RELAYED prefix;
// the tail ("<channel> <base64-payload>") is passed through opaquely. This is
// what lets peers behind strict NATs still play, with no TURN server.
fn handleRelay(io: Io, peer: *Peer, rest: []const u8) !void {
    const space: usize = std.mem.indexOfScalar(u8, rest, ' ') orelse return;
    const to_id: u32 = std.fmt.parseInt(u32, rest[0..space], 10) catch return;
    const data: []const u8 = rest[space + 1 ..];

    const out: []u8 = try registry.gpa.alloc(u8, 32 + data.len);
    defer registry.gpa.free(out);
    const prefix: []const u8 = try bufPrint(out, "RELAYED {d} ", .{peer.id});
    @memcpy(out[prefix.len .. prefix.len + data.len], data);
    const message: []const u8 = out[0 .. prefix.len + data.len];

    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);
    for (registry.peers.items) |other| {
        if (other.alive and other.id == to_id and std.mem.eql(u8, other.roomName(), peer.roomName())) {
            sendText(io, other, message);
            break;
        }
    }
}

fn cleanupPeer(io: Io, peer: *Peer) void {
    registry.mutex.lockUncancelable(io);
    for (registry.peers.items, 0..) |p, i| {
        if (p == peer) {
            _ = registry.peers.swapRemove(i);
            break;
        }
    }
    if (peer.room_len > 0) {
        var left_buf: [32]u8 = undefined;
        const left: []const u8 = bufPrint(&left_buf, "LEFT {d}", .{peer.id}) catch "LEFT 0";
        for (registry.peers.items) |other| {
            if (other.alive and std.mem.eql(u8, other.roomName(), peer.roomName())) {
                sendText(io, other, left);
            }
        }
    }
    registry.mutex.unlock(io);
    registry.gpa.destroy(peer);
}

fn handleConnection(io: Io, stream: net.Stream) void {
    defer stream.close(io);

    const read_buf: []u8 = registry.gpa.alloc(u8, read_buffer_bytes) catch return;
    defer registry.gpa.free(read_buf);
    const msg_buf: []u8 = registry.gpa.alloc(u8, max_message_bytes) catch return;
    defer registry.gpa.free(msg_buf);

    var stream_reader: net.Stream.Reader = stream.reader(io, read_buf);
    const reader: *Io.Reader = &stream_reader.interface;

    // Read the HTTP request head first — every connection starts as HTTP.
    if (!readHttpHead(reader)) {
        return;
    }
    const head_all: []const u8 = reader.buffered();
    const head_end: usize = (std.mem.indexOf(u8, head_all, "\r\n\r\n") orelse return) + 4;

    // Branch: a WebSocket upgrade (has the key) vs a plain page request.
    const key: ?[]const u8 = findHeaderValue(head_all[0..head_end], "sec-websocket-key");
    if (key == null) {
        // Plain GET (a browser opening a page, or a health check): pick the page
        // by path — /ws serves the signaling test, everything else the WebRTC one.
        const path: []const u8 = requestPath(head_all[0..head_end]);
        const html: []const u8 = choosePage(path);
        serveHttp(io, stream, html) catch {}; // lint:off catch-suppression: client errors are normal
        return;
    }

    // Finish the WebSocket handshake, then run the signaling relay loop.
    var accept_buf: [40]u8 = undefined;
    const accept: []const u8 = computeAccept(key.?, &accept_buf);
    var response_buf: [256]u8 = undefined;
    const response: []const u8 = bufPrint(&response_buf, "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: {s}\r\n\r\n", .{accept}) catch return;
    {
        var writer: net.Stream.Writer = stream.writer(io, &.{});
        writer.interface.writeAll(response) catch return;
        writer.interface.flush() catch return;
    }
    _ = reader.take(head_end) catch return; // consume the head; WS frames follow

    const peer: *Peer = registry.gpa.create(Peer) catch return;
    peer.* = .{ .id = 0, .stream = stream };
    registry.mutex.lockUncancelable(io);
    peer.id = registry.next_id;
    registry.next_id += 1;
    registry.mutex.unlock(io);
    defer cleanupPeer(io, peer);

    std.log.info("[signal] peer {d} connected", .{peer.id});

    while (peer.alive) {
        const frame: Frame = readFrame(reader, msg_buf) catch break;
        if (frame.opcode == Opcode.close) {
            break;
        }
        if (frame.opcode == Opcode.ping) {
            writeFrame(io, stream, Opcode.pong, msg_buf[0..frame.len]) catch break;
            continue;
        }
        if (frame.opcode != Opcode.text) {
            continue;
        }
        const message: []const u8 = msg_buf[0..frame.len];
        if (std.mem.startsWith(u8, message, "JOIN ")) {
            handleJoin(io, peer, message[5..]) catch break;
        } else if (std.mem.startsWith(u8, message, "SIGNAL ")) {
            handleSignal(io, peer, message[7..]) catch break;
        } else if (std.mem.startsWith(u8, message, "RELAY ")) {
            handleRelay(io, peer, message[6..]) catch break;
        }
    }
    std.log.info("[signal] peer {d} disconnected", .{peer.id});
}

pub fn main(init: std.process.Init) !void {
    const port_text: []const u8 = init.environ_map.get("PORT") orelse default_port;
    const port: u16 = try std.fmt.parseInt(u16, port_text, 10);
    registry = .{ .gpa = std.heap.smp_allocator };

    // See signal_server.zig for why we build our own pool (the default sizes it
    // to CPU-count-1, which is 0 on a single core and makes io.async run inline).
    var threaded: std.Io.Threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .async_limit = .limited(256) });
    const io: Io = threaded.io();

    const address: net.IpAddress = try .parseIp4("0.0.0.0", port);
    var server: net.Server = try address.listen(io, .{ .reuse_address = true });
    std.log.info("[signal] listening on 0.0.0.0:{d} (serving page + signaling)", .{port});

    while (true) {
        const stream: net.Stream = server.accept(io) catch continue;
        _ = io.async(handleConnection, .{ io, stream });
    }
}
