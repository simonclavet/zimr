//! lint:alias net_core
//! src/net.zig - the P2P session layer. This is the friendly front door to the
//! whole multiplayer stack: you call `connect(url, room)`, then each frame you
//! drain `poll()` for events (peers joining/leaving, messages) and use
//! `broadcast()` / `sendTo()` to talk. Everything underneath - the WebSocket
//! signaling handshake and the WebRTC offer/answer/ICE dance - is handled for
//! you, for every peer in the room.
//!
//! It runs a FULL MESH: one direct WebRTC connection per peer, so with N people
//! there are N-1 connections from your machine. That's the right shape for the
//! "invite a few friends to a local game" use case (small N); it is NOT built
//! for hundreds of players.
//!
//! Two channels per connection, matching the game's needs:
//!   - channel 0 "cursor": unreliable + unordered (fire-and-forget state like a
//!     mouse position - dropping one is fine, the next one supersedes it).
//!   - channel 1 "clicks": reliable + ordered (events you can't afford to lose).
//!
//! The offerer convention (who sends the SDP offer) avoids "glare" (both sides
//! offering at once): the LOWER peer id always offers to the HIGHER. Since the
//! signaling server hands out ids in increasing order, that just means: you
//! offer to anyone who JOINs after you, and you answer anyone already present
//! when you arrive. `poll` computes this from the ids, so it's automatic.
//!
//! Native builds are a graceful no-op: ws/rtc are wasm-only and stub out, so a
//! headless smoke test runs the UI without any real networking.

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const indexOfScalar = std.mem.indexOfScalar;
const eql = std.mem.eql;
const parseInt = std.fmt.parseInt;
const startsWith = std.mem.startsWith;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;
const trim = std.mem.trim;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const indexOf = std.mem.indexOf;
const readInt = std.mem.readInt;
const writeInt = std.mem.writeInt;

/// Friends-only scale. One connection per peer; this caps the mesh size.
pub const max_peers = 8;

const sdp_cap = 16384; // SDP offers/answers run a few KB; ICE candidates are tiny
const cq_cap = max_peers * 2 + 8; // control events queued between poll() calls
const reconnect_cooldown = 30; // poll-calls between reconnect attempts (~0.5s @ 60fps)

pub const ChannelRef = struct { peer: u32, channel: u8 };

/// The browser's RTCPeerConnection.connectionState, plus our own states, boiled
/// down. `failed` is where the direct connection gave up - the session then
/// falls back to relaying this peer through the server and reports `relayed`.
/// `closed` is terminal (the peer is dropped). `disconnected` is often transient
/// (it can recover to `connected`), so we surface it but keep the peer.
pub const ConnState = enum(u8) { connecting, connected, disconnected, failed, closed, relayed, other };

pub const PeerState = struct { peer: u32, state: ConnState };

pub const Message = struct { peer: u32, channel: u8, bytes: []const u8 };

/// What `poll` hands back to the game. `message.bytes` points into the buffer
/// you passed to `poll`, so it's only valid until your next `poll` call - copy
/// it out if you need to keep it.
pub const Event = union(enum) {
    /// The server assigned us this peer id (arrives once, right after connect).
    joined_as: u32,
    /// We've started negotiating with this peer (a connection is being set up).
    peer_joined: u32,
    /// A data channel to a peer just opened and is ready to send/receive on.
    channel_open: ChannelRef,
    /// A peer's WebRTC connection changed state (connecting -> connected, or
    /// failed / disconnected). Purely informational - the session handles the
    /// terminal cases itself (see below) - but handy for showing status.
    peer_state: PeerState,
    /// Bytes arrived from a peer on one of the channels.
    message: Message,
    /// A peer disconnected; their connection is gone. Fires both when the server
    /// tells us they left AND when their connection fails/closes on our end.
    peer_left: u32,
    /// The room's host changed to this peer id. The host is simply the
    /// lowest-id (longest-present) peer, recomputed as peers come and go - useful
    /// if your game wants one authority. Check `isHost()` for whether it's you.
    host_changed: u32,
    /// The room is full (already at `max_peers`); the server turned us away. The
    /// session stops here - try `connect()` with a different room.
    room_full,
};

const ControlKind = enum { joined_as, peer_joined, peer_state, channel_open, peer_left, host_changed, room_full };
// `channel` doubles as the ConnState value for peer_state events (both fit u8).
const ControlEvent = struct { kind: ControlKind, peer: u32, channel: u8 };

// A tiny fixed ring buffer for the small "control" events. Data messages are
// NOT queued here (they carry bytes) - they're returned straight out of poll.
const ControlQueue = struct {
    items: [cq_cap]ControlEvent,
    head: usize,
    count: usize,
    dropped: u32, // bumped if we ever overflow (debugging aid; shouldn't happen)

    fn init() ControlQueue {
        return .{ .items = undefined, .head = 0, .count = 0, .dropped = 0 };
    }

    fn push(self: *ControlQueue, ev: ControlEvent) void {
        if (self.count >= cq_cap) {
            self.dropped += 1;
            return;
        }
        const slot: usize = (self.head + self.count) % cq_cap;
        self.items[slot] = ev;
        self.count += 1;
    }

    fn pop(self: *ControlQueue) ?ControlEvent {
        if (self.count == 0) {
            return null;
        }
        const ev: ControlEvent = self.items[self.head];
        self.head = (self.head + 1) % cq_cap;
        self.count -= 1;
        return ev;
    }
};

// Map the browser's connectionState string (or one of our "*-error" markers) to
// a ConnState. Negotiation errors count as `failed` so the peer gets cleaned up.
fn parseConnState(s: []const u8) ConnState {
    if (startsWith(u8, s, "remote-error") or startsWith(u8, s, "offer-error")) {
        return .failed;
    }
    if (eql(u8, s, "connecting")) {
        return .connecting;
    }
    if (eql(u8, s, "connected")) {
        return .connected;
    }
    if (eql(u8, s, "disconnected")) {
        return .disconnected;
    }
    if (eql(u8, s, "failed")) {
        return .failed;
    }
    if (eql(u8, s, "closed")) {
        return .closed;
    }
    return .other;
}

const Split = struct { tok: []const u8, rest: []const u8 };

// Split "tok rest" on the first space. rest is "" when there's no space.
fn splitFirst(s: []const u8) Split {
    const sp: usize = indexOfScalar(u8, s, ' ') orelse return .{ .tok = s, .rest = "" };
    return .{ .tok = s[0..sp], .rest = s[sp + 1 ..] };
}

/// The WebSocket protocol (RFC 6455) on the wire - its frames and its opening handshake - shared by the multiplayer
/// servers (`tools/signal_server.zig`, `tools/render_server.zig`) and the engine's native client (`native_websocket`).
/// In the browser the page's own WebSocket speaks it; everywhere else, this does.
pub const websocket = struct {
    const Io = std.Io;

    /// The protocol's fixed GUID: a server proves it speaks WebSocket by hashing the client's key with it
    /// (`computeAccept`).
    pub const magic_guid: []const u8 = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

    /// What a frame carries, in the low four bits of its first byte. A message's first frame says text or binary, and
    /// its later frames - when it is sent in parts - say continuation. The control frames come whole and may arrive
    /// between a message's parts: close ends the connection; ping asks for a pong carrying the same bytes, which keeps
    /// the connection, and the proxies on its way, alive. The other values are reserved: a frame with one breaks the
    /// protocol.
    pub const Opcode = enum(u4) {
        continuation = 0x0,
        text = 0x1,
        binary = 0x2,
        close = 0x8,
        ping = 0x9,
        pong = 0xA,
        _,
    };

    /// The status a close frame carries when a connection ends as intended.
    pub const normal_closure: u16 = 1000;

    /// A frame read off the wire: its opcode, whether it ends its message (FIN), and its payload's length.
    pub const Frame = struct {
        opcode: Opcode,
        is_final: bool,
        payload_len: usize,
    };

    /// Reads one frame, its payload into `out`, unmasked when it came masked. The layout, byte by byte:
    ///
    ///   byte 0:  FIN(1) RSV(3) OPCODE(4)      FIN: the message ends with this frame
    ///   byte 1:  MASK(1) LEN7(7)              MASK: the payload is masked; LEN7: its length
    ///   then, if LEN7 is 126: two more bytes, the real length (big-endian); if 127: eight more
    ///   then, if MASK: the four bytes of the masking key
    ///   then the payload, each byte XOR the key's byte at its position modulo 4, if MASK
    ///
    /// A client masks every frame it sends and a server none, so a server finds masks and a client none; this reads
    /// both. The few header bytes come out of the reader's buffer; the payload goes straight into `out`
    /// (`readSliceAll`), so a frame may be longer than the reader's buffer. The length is read in 64 bits, whatever the
    /// target's `usize`; a frame longer than `out` is refused (`error.MessageTooLarge`) rather than written past it.
    pub fn readFrame(reader: *Io.Reader, out: []u8) !Frame {
        const header: *[2]u8 = try reader.takeArray(2);
        const first_byte: u8 = header[0];
        const second_byte: u8 = header[1];
        const opcode: Opcode = @fromBackingInt(@intCast(@as(u4, @truncate(first_byte))));
        const is_final: bool = first_byte & 0x80 != 0;
        const is_masked: bool = second_byte & 0x80 != 0;
        const short_length: u7 = @truncate(second_byte);
        const payload_length: u64 = switch (short_length) {
            126 => readInt(u16, try reader.takeArray(2), .big),
            127 => readInt(u64, try reader.takeArray(8), .big),
            else => short_length,
        };
        if (payload_length > out.len) {
            return error.MessageTooLarge;
        }
        const payload_len: usize = @intCast(payload_length);
        const mask: ?[4]u8 = if (is_masked) (try reader.takeArray(4)).* else null;
        try reader.readSliceAll(out[0..payload_len]);
        if (mask) |key| {
            applyMask(key, 0, out[0..payload_len]);
        }
        return .{ .opcode = opcode, .is_final = is_final, .payload_len = payload_len };
    }

    /// Masks `bytes` in place with `key` - or unmasks them, the same operation: each byte XOR the key's byte at its
    /// position in the payload modulo 4, `payload_offset` being the position of the first of `bytes`.
    fn applyMask(key: [4]u8, payload_offset: usize, bytes: []u8) void {
        for (bytes, payload_offset..) |*byte, payload_position| {
            byte.* ^= key[payload_position % 4];
        }
    }

    /// Writes one whole message as a single frame, FIN set: the header - 2, 4 or 10 bytes by the payload's length,
    /// then the 4 bytes of `mask` when there is one - and the payload. A client masks every frame with a fresh random
    /// `mask` (the protocol requires it of clients, so that a proxy reading the bytes cannot mistake them for a request
    /// of its own); a server masks none (`null`). The payload is masked through a small buffer rather than in place, so
    /// the caller's bytes stay as they were. The writer is flushed: an `Io` writer buffers, and a frame left in the
    /// buffer never reaches the other end - to send several frames in one write, buffer them (`bufferFrame`) and
    /// flush once.
    pub fn writeFrame(
        writer: *Io.Writer,
        opcode: Opcode,
        payload: []const u8,
        mask: ?[4]u8,
    ) Io.Writer.Error!void {
        try bufferFrame(writer, opcode, payload, mask);
        try writer.flush();
    }

    /// Writes one frame into `writer`, as `writeFrame` does, without flushing: its bytes stay in the writer's buffer
    /// for as long as it has room, so frames buffered together leave in one write when the writer is flushed.
    pub fn bufferFrame(
        writer: *Io.Writer,
        opcode: Opcode,
        payload: []const u8,
        mask: ?[4]u8,
    ) Io.Writer.Error!void {
        var header: [14]u8 = undefined;
        header[0] = 0x80 | @as(u8, @backingInt(opcode));
        const mask_bit: u8 = if (mask != null) 0x80 else 0;
        const payload_length: u64 = payload.len;
        var header_len: usize = 2;
        if (payload_length < 126) {
            header[1] = mask_bit | @as(u8, @intCast(payload_length));
        } else if (payload_length <= 0xFFFF) {
            header[1] = mask_bit | 126;
            writeInt(u16, header[2..4], @intCast(payload_length), .big);
            header_len = 4;
        } else {
            header[1] = mask_bit | 127;
            writeInt(u64, header[2..10], payload_length, .big);
            header_len = 10;
        }
        if (mask) |key| {
            @memcpy(header[header_len..][0..4], &key);
            header_len += 4;
        }
        try writer.writeAll(header[0..header_len]);
        if (mask) |key| {
            var chunk: [512]u8 = undefined;
            var payload_offset: usize = 0;
            while (payload_offset < payload.len) {
                const chunk_len: usize = @min(chunk.len, payload.len - payload_offset);
                @memcpy(chunk[0..chunk_len], payload[payload_offset..][0..chunk_len]);
                applyMask(key, payload_offset, chunk[0..chunk_len]);
                try writer.writeAll(chunk[0..chunk_len]);
                payload_offset += chunk_len;
            }
        } else {
            try writer.writeAll(payload);
        }
    }

    /// Fills `reader` until its buffered bytes hold a whole HTTP head - the request or the answer that opens a
    /// connection - which ends at its first blank line ("\r\n\r\n"). Returns the head's length, the blank line
    /// included, with the head still buffered for reading (`reader.buffered()`); the caller takes it out once done.
    /// Null when the other end closed first, or when the head fills the reader's buffer without ending - reading on
    /// would need room the buffer does not have.
    pub fn readHead(reader: *Io.Reader) ?usize {
        while (true) {
            const buffered: []const u8 = reader.buffered();
            if (indexOf(u8, buffered, "\r\n\r\n")) |blank_line| {
                return blank_line + 4;
            }
            const has_room: bool = buffered.len < reader.buffer.len;
            if (!has_room) {
                return null;
            }
            reader.fill(buffered.len + 1) catch return null;
        }
    }

    /// One header's value in an HTTP head, its name matched regardless of case, as HTTP header names are; null when
    /// the head has no such header.
    pub fn findHeaderValue(head: []const u8, name_lower: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        while (lines.next()) |line| {
            const colon: usize = indexOfScalar(u8, line, ':') orelse continue;
            const name: []const u8 = trim(u8, line[0..colon], " \t");
            if (std.ascii.eqlIgnoreCase(name, name_lower)) {
                return trim(u8, line[colon + 1 ..], " \t");
            }
        }
        return null;
    }

    /// The `Sec-WebSocket-Accept` value for a client's `Sec-WebSocket-Key`: base64 of the SHA-1 of the key followed by
    /// `magic_guid`. A server sends it in its answer; a client computes it too, and trusts the connection only when the
    /// server's matches. Writes it into `out` (28 bytes) and returns the slice used.
    pub fn computeAccept(key: []const u8, out: []u8) []const u8 {
        var hasher: std.crypto.hash.Sha1 = .init(.{});
        hasher.update(key);
        hasher.update(magic_guid);
        var digest: [20]u8 = undefined;
        hasher.final(&digest);
        return std.base64.standard.Encoder.encode(out, &digest);
    }
};

/// A WebSocket client for native platforms, over `std.Io`'s sockets and the protocol above (`websocket`): what the
/// browser's WebSocket is to a page, with the browser's model, so the code above it is the same on every platform. A
/// socket opened returns at once and connects in the background; its state reads connecting, open or closed;
/// messages sent are queued and return at once; received messages wait in a queue the app drains each frame (`poll`).
/// Addresses are `ws://` or `wss://`, then `host[:port][/path][?query]`; a `wss://` connection is encrypted with TLS
/// and trusts the servers the system trusts (its root certificates, loaded once).
///
/// Each socket runs as a task of `std.Io`'s (`io.concurrent`): it connects, makes the opening handshake, then reads
/// frames, blocked in each read until bytes arrive - no polling, so an idle socket costs nothing - while a second
/// task writes. The writing task sleeps until there is something to write (`has_writing_to_do`), then writes all of
/// it - the messages queued, a pong owed, a goodbye - into one buffer, sent in one write: two frames written apart
/// would leave the second waiting on the other end's acknowledgement of the first (Nagle's algorithm against delayed
/// acknowledgements, tens of milliseconds a message). Only the writing task writes, so frames never interleave; the
/// reading task hands it the pongs it owes. The app's thread and the socket's tasks share only the state and the
/// queues, behind one lock held briefly. On a TLS connection the two tasks also take turns with the TLS client
/// (`Connection.tls_lock`): reading it can change the keys writing uses - when the server asks for a key update - so
/// a read and a write must never overlap. The writing task holds the turn for a pass; the reading task waits for the
/// encrypted bytes to arrive without it, then holds it to read one frame.
///
/// Closing is graceful, then forced, and never waits on the app's thread. `close` asks the writing task to say
/// goodbye - a close frame - and shut the connection down. That ends the reading: at once where shutting a connection
/// down wakes a read blocked on it, and otherwise when the server answers the goodbye by closing its side, as a
/// server must. A closing task gives the socket a second to end so, then cancels its tasks, which `std.Io` does even
/// to a read or a write blocked in the system (on Windows by cancelling the thread's synchronous I/O, elsewhere by a
/// signal) - so a connect that hangs, or a server that stalls, holds a closed socket a second at most. The closing
/// task then frees it.
pub const native_websocket = struct {
    const Io = std.Io;

    /// A socket's handle: its slot's index plus one, so that 0 is no socket.
    pub const Handle = u32;

    /// A socket's state, with the values of the browser module's (`web.ws.State`).
    pub const State = enum(i32) {
        connecting = 0,
        open = 1,
        closed = 2,
    };

    /// The memory sockets and their messages live in, shared by the app's thread and the sockets' tasks.
    const heap: Allocator = std.heap.smp_allocator;

    /// The most sockets open at once.
    const socket_capacity: usize = 8;
    /// The most messages waiting in either of a socket's queues - sent, or received - beyond which more are dropped
    /// until the other side catches up.
    const queued_message_capacity: usize = 256;
    /// The longest message read, whole or gathered from its parts.
    const largest_message: usize = 1 << 20;
    /// The longest address accepted.
    const url_room: usize = 512;
    /// The reader's own buffer. The handshake's answer must fit in it (`websocket.readHead`); frames need not, their
    /// payloads being read straight into the frame buffer.
    const read_buffer_room: usize = 16 * 1024;
    /// The writer's buffer, which gathers the frames of one pass - and each frame's header with its payload - into
    /// as few writes as it holds (see the module's description).
    const write_buffer_room: usize = 16 * 1024;
    /// A ping's payload, which its pong carries back, is at most this long: a control frame's limit.
    const control_payload_room: usize = 125;
    /// How long a closed socket has to say goodbye and end before its tasks are cancelled. (Connecting has no limit of
    /// its own: this std's connect does not take a timeout yet. A connect that hangs lasts the system's own limit -
    /// or, when the app closes the socket, this long.)
    const goodbye_timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } };

    /// One socket, shared by the app's thread and its tasks: its lock guards the state, the queues and the pong owed;
    /// its events wake the writing task, and tell the closing task the socket has ended.
    const Socket = struct {
        state_lock: Io.Mutex = .init,
        state: State = .connecting,
        url_bytes: [url_room]u8 = undefined,
        url_byte_count: usize = 0,
        /// Messages the app sent, waiting for the writing task, oldest first.
        outgoing_messages: ArrayList([]u8) = .empty,
        received_messages: ArrayList([]u8) = .empty,
        /// The pong the reading task owes the other end, for the writing task to send.
        pong_payload: [control_payload_room]u8 = undefined,
        pong_payload_len: usize = 0,
        owes_pong: bool = false,
        /// The app closed the socket: the writing task says goodbye and shuts the connection down.
        is_closed_by_app: bool = false,
        /// Set whenever there is something to write, or the app closed the socket: wakes the writing task.
        has_writing_to_do: Io.Event = .unset,
        /// Set when the socket's task has ended: the closing task waits on it before freeing the socket.
        has_ended: Io.Event = .unset,
        /// The socket's task, which the closing task cancels when the socket has not ended in time.
        task: Io.Future(void) = undefined,

        fn url(socket: *const Socket) []const u8 {
            return socket.url_bytes[0..socket.url_byte_count];
        }
    };

    // lint:off module-var: the sockets the app has open, found by their handles from frame to frame
    var sockets: [socket_capacity]?*Socket = @splat(null);
    // lint:off module-var: the I/O the sockets connect, read and write with, made at the first `open`
    var threaded_io: std.Io.Threaded = undefined;
    // lint:off module-var: whether `threaded_io` has been made
    var has_io: bool = false;
    // lint:off module-var: the closing tasks, which nobody awaits: each frees its socket and ends
    var closing_tasks: Io.Group = .init;
    // lint:off module-var: the system's root certificates, which `wss://` servers are checked against - loaded once
    var certificates: std.crypto.Certificate.Bundle = .empty;
    // lint:off module-var: the lock the TLS client takes to read the certificates, as its options require
    var certificates_read_lock: Io.RwLock = .init;
    // lint:off module-var: whether `certificates` has been loaded, and the lock the first secure sockets load it under
    var has_certificates: bool = false;
    // lint:off module-var: (see `has_certificates`)
    var certificates_load_lock: Io.Mutex = .init;

    /// Loads the system's root certificates on the first secure connection; later ones find them loaded. Returns
    /// whether they are.
    fn loadCertificates(io: Io) bool {
        certificates_load_lock.lockUncancelable(io);
        defer certificates_load_lock.unlock(io);
        if (!has_certificates) {
            // lint:off own-clock: a certificate's validity is judged against the wall clock
            certificates.rescan(heap, io, Io.Timestamp.now(io, .real)) catch return false;
            has_certificates = true;
        }
        return true;
    }

    /// A socket's connection, plain or secure: the stream, its own reader and writer, and - for `wss://` - the TLS
    /// client, which decrypts what the stream's reader receives and encrypts what goes to its writer. Messages are
    /// read and written through `messageReader` and `messageWriter`, whichever the connection is. The TLS client
    /// keeps pointers to the stream's reader and writer, so a connection is made in place (`connect`) and never moved.
    const Connection = struct {
        stream: Io.net.Stream,
        stream_reader: Io.net.Stream.Reader,
        stream_writer: Io.net.Stream.Writer,
        tls_client: ?std.crypto.tls.Client,
        /// The turn the reading and writing tasks take with the TLS client (see the module's description).
        tls_lock: Io.Mutex,
        buffers: []u8,

        /// Connects `connection` to `address`, encrypting when the address is secure. Returns whether it connected:
        /// false when connecting fails, or the TLS handshake - the server's certificate checked against the system's.
        fn connect(connection: *Connection, io: Io, address: Address) bool {
            const host_name: Io.net.HostName = Io.net.HostName.init(address.host) catch return false;
            const stream: Io.net.Stream = host_name.connect(io, address.port, .{ .mode = .stream }) catch return false;
            // The stream's reader and writer hold whole TLS records when the connection is secure: at least
            // `min_buffer_len` each, as the TLS client asserts; the TLS client's own two buffers hold plaintext.
            const record_room: usize = std.crypto.tls.Client.min_buffer_len;
            const stream_buffer_len: usize = @max(read_buffer_room, record_room);
            const buffers: []u8 = heap.alloc(u8, 2 * stream_buffer_len + read_buffer_room + write_buffer_room) catch {
                stream.close(io);
                return false;
            };
            connection.* = .{
                .stream = stream,
                .stream_reader = stream.reader(io, buffers[0..stream_buffer_len]),
                .stream_writer = stream.writer(io, buffers[stream_buffer_len..][0..stream_buffer_len]),
                .tls_client = null,
                .tls_lock = .init,
                .buffers = buffers,
            };
            if (!address.is_secure) {
                return true;
            }
            if (!loadCertificates(io)) {
                connection.close(io);
                return false;
            }
            const plaintext_buffers: []u8 = buffers[2 * stream_buffer_len ..];
            var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
            io.random(&entropy);
            const tls_options: std.crypto.tls.Client.Options = .{
                .host = .{ .explicit = address.host },
                .ca = .{ .bundle = .{
                    .gpa = heap,
                    .io = io,
                    .lock = &certificates_read_lock,
                    .bundle = &certificates,
                } },
                .read_buffer = plaintext_buffers[0..read_buffer_room],
                .write_buffer = plaintext_buffers[read_buffer_room..][0..write_buffer_room],
                .entropy = &entropy,
                // lint:off own-clock: the TLS handshake checks certificates against the wall clock
                .realtime_now = Io.Timestamp.now(io, .real),
            };
            const stream_input: *Io.Reader = &connection.stream_reader.interface;
            const stream_output: *Io.Writer = &connection.stream_writer.interface;
            connection.tls_client = std.crypto.tls.Client.init(stream_input, stream_output, tls_options) catch {
                connection.close(io);
                return false;
            };
            return true;
        }

        fn close(connection: *Connection, io: Io) void {
            connection.stream.close(io);
            heap.free(connection.buffers);
        }

        fn isSecure(connection: *const Connection) bool {
            return connection.tls_client != null;
        }

        /// The reader messages arrive through: the TLS client's, decrypting, or the stream's.
        fn messageReader(connection: *Connection) *Io.Reader {
            if (connection.tls_client) |*tls_client| {
                return &tls_client.reader;
            }
            return &connection.stream_reader.interface;
        }

        /// The writer messages leave through: the TLS client's, encrypting, or the stream's.
        fn messageWriter(connection: *Connection) *Io.Writer {
            if (connection.tls_client) |*tls_client| {
                return &tls_client.writer;
            }
            return &connection.stream_writer.interface;
        }

        /// Sends what the message writer holds. The TLS client's flush only encrypts its plaintext into the stream
        /// writer's buffer, so the stream writer is flushed after it.
        fn flush(connection: *Connection) Io.Writer.Error!void {
            if (connection.tls_client) |*tls_client| {
                try tls_client.writer.flush();
            }
            try connection.stream_writer.interface.flush();
        }

        /// On a TLS connection, waits - outside the TLS client's turn - until the stream has received bytes the TLS
        /// client has not yet read, so that the reading task takes its turn only to read, never to wait. Plain
        /// connections, and secure ones with plaintext already decrypted, return at once.
        fn waitForEncryptedBytes(connection: *Connection) Io.Reader.Error!void {
            const tls_client: *std.crypto.tls.Client = if (connection.tls_client) |*client| client else return;
            if (tls_client.reader.buffered().len > 0) {
                return;
            }
            const stream_input: *Io.Reader = &connection.stream_reader.interface;
            if (stream_input.buffered().len == 0) {
                try stream_input.fill(1);
            }
        }
    };

    /// Makes the sockets' I/O on the first `open` - on the app's thread, before any socket's task starts.
    fn startIo() void {
        if (!has_io) {
            threaded_io = std.Io.Threaded.init(heap, .{});
            has_io = true;
        }
    }

    /// The sockets' I/O. Every caller has found a live socket first, so the first `open` has made it.
    fn socketIo() Io {
        return threaded_io.io();
    }

    /// Where a WebSocket address leads: whether it is secure (`wss://`), the host - a name, or an IP address, an IPv6
    /// one without the brackets it is written in - the port (443 for `wss://` and 80 for `ws://` unless given), and the
    /// request's target, a path and any query (`/` unless given).
    const Address = struct {
        is_secure: bool,
        host: []const u8,
        port: u16,
        target: []const u8,
    };

    /// The parts of a `ws://` or `wss://` address; null for one that is neither, or that names no host.
    fn parseAddress(url: []const u8) ?Address {
        const is_secure: bool = startsWith(u8, url, "wss://");
        const is_plain: bool = startsWith(u8, url, "ws://");
        if (!is_secure and !is_plain) {
            return null;
        }
        const scheme_len: usize = if (is_secure) "wss://".len else "ws://".len;
        const after_scheme: []const u8 = url[scheme_len..];
        // The host and port end where the target begins: at its path's '/' or, with no path, its query's '?'.
        const target_start: usize = std.mem.indexOfAny(u8, after_scheme, "/?") orelse after_scheme.len;
        const authority: []const u8 = after_scheme[0..target_start];
        const target: []const u8 = if (target_start < after_scheme.len) after_scheme[target_start..] else "/";
        var host: []const u8 = authority;
        var port_text: ?[]const u8 = null;
        if (startsWith(u8, authority, "[")) {
            const closing_bracket: usize = indexOfScalar(u8, authority, ']') orelse return null;
            host = authority[1..closing_bracket];
            const after_bracket: []const u8 = authority[closing_bracket + 1 ..];
            if (after_bracket.len > 0) {
                if (after_bracket[0] != ':') {
                    return null;
                }
                port_text = after_bracket[1..];
            }
        } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
            host = authority[0..colon];
            port_text = authority[colon + 1 ..];
        }
        const default_port: u16 = if (is_secure) 443 else 80;
        const port: u16 = if (port_text) |text| parseInt(u16, text, 10) catch return null else default_port;
        if (host.len == 0) {
            return null;
        }
        return .{ .is_secure = is_secure, .host = host, .port = port, .target = target };
    }

    /// The socket a handle names, while it is open in the app's view.
    fn socketOf(handle: Handle) ?*Socket {
        if (handle == 0 or handle > socket_capacity) {
            return null;
        }
        return sockets[handle - 1];
    }

    /// Opens a socket to `url` and returns its handle at once; it connects in the background (`state`). 0 - no
    /// socket, its state closed - when the address is not a WebSocket one, is longer than `url_room`, every slot is
    /// taken, or no task can be started.
    pub fn open(url: []const u8) Handle {
        const is_usable_address: bool = url.len <= url_room and parseAddress(url) != null;
        if (!is_usable_address) {
            return 0;
        }
        const free_slot: usize = for (sockets, 0..) |socket, slot_index| {
            if (socket == null) {
                break slot_index;
            }
        } else return 0;
        startIo();
        const io: Io = socketIo();
        const socket: *Socket = heap.create(Socket) catch return 0;
        socket.* = .{};
        @memcpy(socket.url_bytes[0..url.len], url);
        socket.url_byte_count = url.len;
        socket.task = io.concurrent(runSocket, .{socket}) catch {
            heap.destroy(socket);
            return 0;
        };
        sockets[free_slot] = socket;
        return @intCast(free_slot + 1);
    }

    /// The socket's state; a handle no longer open reads closed.
    pub fn state(handle: Handle) State {
        const socket: *Socket = socketOf(handle) orelse return .closed;
        const io: Io = socketIo();
        socket.state_lock.lockUncancelable(io);
        defer socket.state_lock.unlock(io);
        return socket.state;
    }

    /// Queues `bytes` as a text message for the writing task, and returns at once; dropped when the socket is not
    /// open, when the queue is full, or when memory runs out.
    pub fn send(handle: Handle, bytes: []const u8) void {
        const socket: *Socket = socketOf(handle) orelse return;
        const io: Io = socketIo();
        const copy: []u8 = heap.dupe(u8, bytes) catch return;
        socket.state_lock.lockUncancelable(io);
        const has_room: bool = socket.outgoing_messages.items.len < queued_message_capacity;
        const is_queued: bool = socket.state == .open and has_room;
        if (is_queued) {
            socket.outgoing_messages.append(heap, copy) catch {
                socket.state_lock.unlock(io);
                heap.free(copy);
                return;
            };
        }
        socket.state_lock.unlock(io);
        if (!is_queued) {
            heap.free(copy);
            return;
        }
        socket.has_writing_to_do.set(io);
    }

    /// The oldest received message, copied into `out`, as a slice of it; null when none waits. A message longer than
    /// `out` is dropped, and null returned, as the browser module's `poll` does - which ends a loop draining the
    /// queue; the next message waits for the next call.
    pub fn poll(handle: Handle, out: []u8) ?[]const u8 {
        const socket: *Socket = socketOf(handle) orelse return null;
        const io: Io = socketIo();
        socket.state_lock.lockUncancelable(io);
        defer socket.state_lock.unlock(io);
        if (socket.received_messages.items.len == 0) {
            return null;
        }
        const message: []u8 = socket.received_messages.orderedRemove(0);
        defer heap.free(message);
        if (message.len > out.len) {
            return null;
        }
        @memcpy(out[0..message.len], message);
        return out[0..message.len];
    }

    /// Closes the socket and frees its handle at once; safe on a handle already closed. The writing task says goodbye
    /// and shuts the connection down; a closing task frees the socket once it has ended - or, a second on, cancels it
    /// (see the module's description). Without a task to spare, the closing happens here.
    pub fn close(handle: Handle) void {
        const socket: *Socket = socketOf(handle) orelse return;
        sockets[handle - 1] = null;
        const io: Io = socketIo();
        socket.state_lock.lockUncancelable(io);
        socket.is_closed_by_app = true;
        socket.state = .closed;
        socket.state_lock.unlock(io);
        socket.has_writing_to_do.set(io);
        closing_tasks.concurrent(io, finishClosing, .{socket}) catch finishClosing(socket);
    }

    /// The closing task: waits for the socket to end after its goodbye, cancels its tasks when it has not ended in
    /// time, and frees it.
    fn finishClosing(socket: *Socket) void {
        const io: Io = socketIo();
        // A socket that has not ended in time is cancelled next, as is one whose closing task is cancelled.
        socket.has_ended.waitTimeout(io, goodbye_timeout) catch |err| switch (err) {
            error.Timeout, error.Canceled => {},
        };
        socket.task.cancel(io);
        freeSocket(socket);
    }

    fn freeSocket(socket: *Socket) void {
        for (socket.outgoing_messages.items) |message| {
            heap.free(message);
        }
        socket.outgoing_messages.deinit(heap);
        for (socket.received_messages.items) |message| {
            heap.free(message);
        }
        socket.received_messages.deinit(heap);
        heap.destroy(socket);
    }

    /// A socket's task: connects - encrypting for `wss://` - makes the opening handshake, starts the writing task,
    /// reads until the connection ends, then stops the writing task and marks the socket ended (`endSocket`).
    fn runSocket(socket: *Socket) void {
        const io: Io = socketIo();
        defer endSocket(io, socket);
        const address: Address = parseAddress(socket.url()) orelse return;
        var connection: Connection = undefined;
        if (!connection.connect(io, address)) {
            return;
        }
        defer connection.close(io);
        if (!makeOpeningHandshake(io, &connection, address)) {
            return;
        }
        if (!markOpen(io, socket)) {
            return;
        }
        var writing: Io.Future(void) = io.concurrent(writeUntilGoodbye, .{ socket, &connection }) catch return;
        const is_closed_by_server: bool = readUntilEnd(io, socket, &connection);
        if (is_closed_by_server) {
            // The writing task echoes the server's close frame, then ends.
            writing.await(io);
        } else {
            writing.cancel(io);
        }
    }

    /// The socket is open, after its handshake - unless the app closed it meanwhile. Returns whether it is.
    fn markOpen(io: Io, socket: *Socket) bool {
        socket.state_lock.lockUncancelable(io);
        defer socket.state_lock.unlock(io);
        if (socket.is_closed_by_app) {
            return false;
        }
        socket.state = .open;
        return true;
    }

    /// The end of a socket's task: the socket reads closed, and the closing task - when the app closes it - learns it
    /// has ended.
    fn endSocket(io: Io, socket: *Socket) void {
        socket.state_lock.lockUncancelable(io);
        socket.state = .closed;
        socket.state_lock.unlock(io);
        socket.has_ended.set(io);
    }

    /// The opening handshake, from the client's side: an HTTP request asking to switch to WebSocket, carrying a key of
    /// 16 random bytes in base64, and the server's answer checked (`isAcceptedAnswer`). The answer is taken out of the
    /// reader, so the next read starts on the first frame. Returns whether the server accepted.
    fn makeOpeningHandshake(io: Io, connection: *Connection, address: Address) bool {
        var key_bytes: [16]u8 = undefined;
        io.random(&key_bytes);
        var key_text: [24]u8 = undefined;
        const key: []const u8 = std.base64.standard.Encoder.encode(&key_text, &key_bytes);
        // A request's target begins with '/', even when the address gives only a query; an IPv6 host is written in
        // brackets in the Host header, as in the address.
        const target_prefix: []const u8 = if (address.target[0] == '/') "" else "/";
        const is_ipv6_host: bool = indexOfScalar(u8, address.host, ':') != null;
        const host_open: []const u8 = if (is_ipv6_host) "[" else "";
        const host_close: []const u8 = if (is_ipv6_host) "]" else "";
        var request_bytes: [url_room + 256]u8 = undefined;
        const request: []const u8 = bufPrint(&request_bytes, "GET {s}{s} HTTP/1.1\r\n" ++
            "Host: {s}{s}{s}:{d}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n\r\n", .{
            target_prefix, address.target, host_open, address.host, host_close, address.port, key,
        }) catch return false;
        connection.messageWriter().writeAll(request) catch return false;
        connection.flush() catch return false;
        const reader: *Io.Reader = connection.messageReader();
        const head_len: usize = websocket.readHead(reader) orelse return false;
        const is_accepted: bool = isAcceptedAnswer(reader.buffered()[0..head_len], key);
        reader.toss(head_len);
        return is_accepted;
    }

    /// Whether a server's answer to the opening handshake accepts it, as RFC 6455 has a client check: the status
    /// `101 Switching Protocols`, `Upgrade: websocket`, a `Connection` naming `upgrade`, and the accept value of the
    /// client's `key` - which only a server speaking WebSocket computes.
    fn isAcceptedAnswer(head: []const u8, key: []const u8) bool {
        const is_switching: bool = startsWith(u8, head, "HTTP/1.1 101");
        const upgrade: []const u8 = websocket.findHeaderValue(head, "upgrade") orelse "";
        const connection: []const u8 = websocket.findHeaderValue(head, "connection") orelse "";
        const answered_accept: []const u8 = websocket.findHeaderValue(head, "sec-websocket-accept") orelse "";
        var expected_accept_text: [28]u8 = undefined;
        const expected_accept: []const u8 = websocket.computeAccept(key, &expected_accept_text);
        const is_upgrade: bool = std.ascii.eqlIgnoreCase(upgrade, "websocket");
        const is_connection_upgrade: bool = std.ascii.findIgnoreCase(connection, "upgrade") != null;
        const is_accept_right: bool = eql(u8, answered_accept, expected_accept);
        return is_switching and is_upgrade and is_connection_upgrade and is_accept_right;
    }

    /// What a frame read means to the client (`MessageGatherer.take`).
    const FrameMeaning = union(enum) {
        /// A whole message: a frame of its own, or the last of a message's parts, the earlier ones gathered.
        message: []const u8,
        /// A ping, to answer with a pong carrying its bytes.
        ping: []const u8,
        /// The other end closing, with its status, when it gave one.
        close: []const u8,
        /// Nothing complete yet - a message's part before its last - or a pong.
        nothing,
        /// A frame that breaks the protocol: a continuation with no message begun, a message begun inside another,
        /// a message past `largest_message`, or a reserved opcode. The connection ends.
        broken,
    };

    /// Gathers the parts of messages sent in several frames into whole messages, and tells what each frame means.
    const MessageGatherer = struct {
        parts: ArrayList(u8) = .empty,
        is_gathering: bool = false,

        fn deinit(gatherer: *MessageGatherer) void {
            gatherer.parts.deinit(heap);
        }

        /// What `frame`, with its payload `payload`, means. A message's bytes hold until the next call.
        fn take(
            gatherer: *MessageGatherer,
            frame: websocket.Frame,
            payload: []const u8,
        ) Allocator.Error!FrameMeaning {
            switch (frame.opcode) {
                .text, .binary => {
                    if (gatherer.is_gathering) {
                        return .broken;
                    }
                    if (frame.is_final) {
                        return .{ .message = payload };
                    }
                    gatherer.parts.clearRetainingCapacity();
                    try gatherer.parts.appendSlice(heap, payload);
                    gatherer.is_gathering = true;
                    return .nothing;
                },
                .continuation => {
                    if (!gatherer.is_gathering) {
                        return .broken;
                    }
                    try gatherer.parts.appendSlice(heap, payload);
                    if (gatherer.parts.items.len > largest_message) {
                        return .broken;
                    }
                    if (!frame.is_final) {
                        return .nothing;
                    }
                    gatherer.is_gathering = false;
                    return .{ .message = gatherer.parts.items };
                },
                .ping => return .{ .ping = payload },
                .close => return .{ .close = payload },
                .pong => return .nothing,
                _ => return .broken,
            }
        }
    };

    /// The reading task's part: reads frames until the connection ends - blocked in each read until bytes arrive.
    /// Whole messages join the received queue; a ping's pong is handed to the writing task. Returns whether the end
    /// was the server's close frame, which the writing task then echoes (`says_goodbye`); any other end - the app's
    /// goodbye having shut the connection down, a frame that breaks the protocol, a broken connection, a cancelling -
    /// returns false.
    fn readUntilEnd(io: Io, socket: *Socket, connection: *Connection) bool {
        const frame_buffer: []u8 = heap.alloc(u8, largest_message) catch return false;
        defer heap.free(frame_buffer);
        var gatherer: MessageGatherer = .{};
        defer gatherer.deinit();
        while (true) {
            connection.waitForEncryptedBytes() catch return false;
            const frame: websocket.Frame = readFrameInTurn(io, connection, frame_buffer) catch return false;
            const payload: []const u8 = frame_buffer[0..frame.payload_len];
            const meaning: FrameMeaning = gatherer.take(frame, payload) catch return false;
            switch (meaning) {
                .message => |message| enqueueReceivedMessage(io, socket, message),
                .ping => |ping_payload| owePong(io, socket, ping_payload),
                .close => {
                    socket.state_lock.lockUncancelable(io);
                    socket.is_closed_by_app = true;
                    socket.state_lock.unlock(io);
                    socket.has_writing_to_do.set(io);
                    return true;
                },
                .nothing => {},
                .broken => return false,
            }
        }
    }

    /// Reads one frame through the connection, holding the TLS client's turn on a secure one.
    fn readFrameInTurn(
        io: Io,
        connection: *Connection,
        frame_buffer: []u8,
    ) !websocket.Frame {
        const is_secure: bool = connection.isSecure();
        if (is_secure) {
            try connection.tls_lock.lock(io);
        }
        defer if (is_secure) {
            connection.tls_lock.unlock(io);
        };
        return websocket.readFrame(connection.messageReader(), frame_buffer);
    }

    /// Adds a copy of a received message to the socket's queue; dropped when the queue is full or memory runs out.
    fn enqueueReceivedMessage(io: Io, socket: *Socket, message: []const u8) void {
        const copy: []u8 = heap.dupe(u8, message) catch return;
        socket.state_lock.lockUncancelable(io);
        defer socket.state_lock.unlock(io);
        const has_room: bool = socket.received_messages.items.len < queued_message_capacity;
        if (!has_room) {
            heap.free(copy);
            return;
        }
        socket.received_messages.append(heap, copy) catch heap.free(copy);
    }

    /// Hands the writing task the pong a ping asks for, with the ping's payload; a pong still unsent is replaced, as
    /// only the latest ping's needs an answer.
    fn owePong(io: Io, socket: *Socket, ping_payload: []const u8) void {
        const kept_len: usize = @min(ping_payload.len, control_payload_room);
        socket.state_lock.lockUncancelable(io);
        @memcpy(socket.pong_payload[0..kept_len], ping_payload[0..kept_len]);
        socket.pong_payload_len = kept_len;
        socket.owes_pong = true;
        socket.state_lock.unlock(io);
        socket.has_writing_to_do.set(io);
    }

    /// What the writing task takes to write in one pass, under the socket's lock: the messages queued, the pong owed,
    /// and whether to say goodbye.
    const WritingWork = struct {
        messages: ArrayList([]u8),
        pong_payload: [control_payload_room]u8,
        pong_payload_len: usize,
        owes_pong: bool,
        says_goodbye: bool,

        /// Nothing to write - the event was set for work an earlier pass already took.
        fn isEmpty(work: *const WritingWork) bool {
            return work.messages.items.len == 0 and !work.owes_pong and !work.says_goodbye;
        }
    };

    fn takeWritingWork(io: Io, socket: *Socket) WritingWork {
        socket.state_lock.lockUncancelable(io);
        defer socket.state_lock.unlock(io);
        const work: WritingWork = .{
            .messages = socket.outgoing_messages,
            .pong_payload = socket.pong_payload,
            .pong_payload_len = socket.pong_payload_len,
            .owes_pong = socket.owes_pong,
            .says_goodbye = socket.is_closed_by_app,
        };
        socket.outgoing_messages = .empty;
        socket.owes_pong = false;
        return work;
    }

    /// The writing task: sleeps until there is something to write, then writes all of it in one pass - the pong
    /// owed, the queued messages, and a goodbye when the socket is closing - through the message writer, flushed
    /// once, in the TLS client's turn on a secure connection. After a goodbye it ends a TLS session politely
    /// (close_notify), shuts the connection down, which ends the reading, and ends. The event is reset before the work
    /// is taken, so work that arrives meanwhile sets it again and is never missed.
    fn writeUntilGoodbye(socket: *Socket, connection: *Connection) void {
        const io: Io = socketIo();
        while (true) {
            socket.has_writing_to_do.wait(io) catch return;
            socket.has_writing_to_do.reset();
            var work: WritingWork = takeWritingWork(io, socket);
            defer work.messages.deinit(heap);
            defer for (work.messages.items) |message| {
                heap.free(message);
            };
            if (work.isEmpty()) {
                continue;
            }
            writePass(io, connection, &work) catch return;
            if (work.says_goodbye) {
                // lint:off catch-suppression: a connection already ended cannot be shut down, and needs not be
                connection.stream.shutdown(io, .both) catch {};
                return;
            }
        }
    }

    /// One pass of the writing task, in the TLS client's turn on a secure connection.
    fn writePass(io: Io, connection: *Connection, work: *const WritingWork) !void {
        const is_secure: bool = connection.isSecure();
        if (is_secure) {
            try connection.tls_lock.lock(io);
        }
        defer if (is_secure) {
            connection.tls_lock.unlock(io);
        };
        const writer: *Io.Writer = connection.messageWriter();
        if (work.owes_pong) {
            try bufferClientFrame(io, writer, .pong, work.pong_payload[0..work.pong_payload_len]);
        }
        for (work.messages.items) |message| {
            try bufferClientFrame(io, writer, .text, message);
        }
        if (work.says_goodbye) {
            var status: [2]u8 = undefined;
            writeInt(u16, &status, websocket.normal_closure, .big);
            try bufferClientFrame(io, writer, .close, &status);
            if (connection.tls_client) |*tls_client| {
                // The TLS session ends politely: `end` encrypts what is buffered, then the close_notify alert, which
                // must be the last record - so only the stream's writer is flushed after it.
                try tls_client.end();
                try connection.stream_writer.interface.flush();
                return;
            }
        }
        try connection.flush();
    }

    /// Adds one frame from the client to the writer's buffer, unflushed: masked, with a fresh random key, as every
    /// client frame must be.
    fn bufferClientFrame(
        io: Io,
        writer: *Io.Writer,
        opcode: websocket.Opcode,
        payload: []const u8,
    ) Io.Writer.Error!void {
        var mask: [4]u8 = undefined;
        io.random(&mask);
        try websocket.bufferFrame(writer, opcode, payload, mask);
    }
};

/// `Net(WsT, RtcT)` binds the session layer to a pair of transports. Both the
/// real browser transports (src/net.zig) and the in-process mock (the mesh test)
/// go through this. Everything inside is transport-agnostic - it only ever calls
/// the `ws`/`rtc` APIs, and this file imports neither.
pub fn Net(comptime WsT: type, comptime RtcT: type) type {
    return struct {
        const ws = WsT;
        const rtc = RtcT;

        /// One remote participant and our connection to them.
        const Peer = struct {
            id: u32,
            pc: rtc.Handle,
            chan_open: [2]bool,
            active: bool,
            /// True once the direct connection failed and we fell back to
            /// relaying this peer's traffic through the signaling server.
            relay: bool,
        };

        /// A multiplayer session. Embed one in your app State (it holds fixed
        /// buffers, so no allocator needed), call `connect`, then `poll` each frame.
        pub const Session = struct {
            sock: ws.Handle, // signaling socket (0 = not connected)
            joined: bool, // have we sent JOIN yet?
            my_id: u32, // our peer id (0 = not yet assigned)

            room_buf: [64]u8,
            room_len: usize,

            peers: [max_peers]Peer,
            peer_count: usize,

            control: ControlQueue,

            ws_buf: [sdp_cap]u8, // ws.poll inbound (must hold FROM + SDP)
            rtc_buf: [sdp_cap]u8, // rtc.poll output (must hold SDP)
            send_buf: [sdp_cap]u8, // building outbound SIGNAL messages

            url_buf: [256]u8, // remembered so we can reconnect to the same server
            url_len: usize,
            want_connected: bool, // true from connect() until disconnect()
            reconnect_wait: u32, // poll-calls left before the next reconnect attempt
            host_id: u32, // lowest active id (incl us) = the room host; 0 = unknown

            pub fn init() Session {
                return .{
                    .sock = 0,
                    .joined = false,
                    .my_id = 0,
                    .room_buf = undefined,
                    .room_len = 0,
                    .peers = undefined,
                    .peer_count = 0,
                    .control = ControlQueue.init(),
                    .ws_buf = undefined,
                    .rtc_buf = undefined,
                    .send_buf = undefined,
                    .url_buf = undefined,
                    .url_len = 0,
                    .want_connected = false,
                    .reconnect_wait = 0,
                    .host_id = 0,
                };
            }

            /// Connect to the signaling server and join `room`. Tears down any
            /// existing session first. JOIN is sent automatically once the socket
            /// opens, and if the socket later drops we reconnect to this same url.
            pub fn connect(self: *Session, url: []const u8, room: []const u8) void {
                self.disconnect();
                const un: usize = @min(url.len, self.url_buf.len);
                @memcpy(self.url_buf[0..un], url[0..un]);
                self.url_len = un;
                const n: usize = @min(room.len, self.room_buf.len);
                @memcpy(self.room_buf[0..n], room[0..n]);
                self.room_len = n;
                self.want_connected = true;
                self.reconnect_wait = 0;
                self.sock = ws.open(self.url_buf[0..self.url_len]);
                self.joined = false;
                self.my_id = 0;
            }

            /// Close every connection and the signaling socket, and stop trying to
            /// reconnect. Safe to call any time.
            pub fn disconnect(self: *Session) void {
                self.want_connected = false;
                var i: usize = 0;
                while (i < self.peer_count) : (i += 1) {
                    if (self.peers[i].active and self.peers[i].pc != 0) {
                        rtc.close(self.peers[i].pc);
                    }
                }
                self.peer_count = 0;
                if (self.sock != 0) {
                    ws.close(self.sock);
                    self.sock = 0;
                }
                self.joined = false;
                self.control = ControlQueue.init();
            }

            // The signaling socket dropped (Render slept, network changed, ...). Our
            // peers are effectively gone until we re-handshake, so close those
            // connections, tell the game they left, and schedule a reconnect. We
            // come back with a fresh id and rebuild the mesh from the new WELCOME.
            fn dropForReconnect(self: *Session) void {
                var i: usize = 0;
                while (i < self.peer_count) : (i += 1) {
                    if (self.peers[i].active) {
                        if (self.peers[i].pc != 0) {
                            rtc.close(self.peers[i].pc);
                        }
                        self.control.push(.{ .kind = .peer_left, .peer = self.peers[i].id, .channel = 0 });
                        self.peers[i].active = false;
                    }
                }
                self.peer_count = 0;
                if (self.sock != 0) {
                    ws.close(self.sock);
                    self.sock = 0;
                }
                self.joined = false;
                self.my_id = 0;
                self.reconnect_wait = reconnect_cooldown;
            }

            /// Our peer id, or 0 before the server has assigned one.
            pub fn myId(self: *const Session) u32 {
                return self.my_id;
            }

            /// True once we're connected and the server has given us an id.
            pub fn isReady(self: *const Session) bool {
                return self.sock != 0 and self.my_id != 0;
            }

            /// True from connect() until disconnect() - including during the brief
            /// gap while we're reconnecting after a dropped socket.
            pub fn isActive(self: *const Session) bool {
                return self.want_connected;
            }

            /// The current host's peer id (the lowest-id peer in the room), or 0
            /// if we don't know yet. The host is a deterministic choice everyone
            /// agrees on - useful if your game wants a single authority.
            pub fn hostId(self: *const Session) u32 {
                return self.host_id;
            }

            /// True if WE are the host (the lowest-id peer in the room right now).
            pub fn isHost(self: *const Session) bool {
                return self.my_id != 0 and self.my_id == self.host_id;
            }

            // -- sending ------------------------------------------------------------

            /// Send bytes to every peer whose given channel is open.
            pub fn broadcast(self: *Session, channel: u8, bytes: []const u8) void {
                if (channel >= 2) {
                    return;
                }
                var i: usize = 0;
                while (i < self.peer_count) : (i += 1) {
                    const peer: *Peer = &self.peers[i];
                    if (!peer.active) {
                        continue;
                    }
                    if (peer.relay) {
                        self.relaySend(peer.id, channel, bytes);
                    } else if (peer.chan_open[channel]) {
                        rtc.send(peer.pc, channel, bytes);
                    }
                }
            }

            /// Send bytes to a single peer on a channel (no-op if unknown or not open).
            pub fn sendTo(
                self: *Session,
                peer_id: u32,
                channel: u8,
                bytes: []const u8,
            ) void {
                if (channel >= 2) {
                    return;
                }
                if (self.findPeer(peer_id)) |peer| {
                    if (peer.relay) {
                        self.relaySend(peer.id, channel, bytes);
                    } else if (peer.chan_open[channel]) {
                        rtc.send(peer.pc, channel, bytes);
                    }
                }
            }

            // -- the pump -----------------------------------------------------------

            /// Advance the session and return the next event, or null when there's
            /// nothing left this frame. Drive it in a loop each frame:
            ///     while (session.poll(&buf)) |ev| switch (ev) { ... }
            /// `buf` receives the bytes for `message` events (valid until the next
            /// poll). Size it to your largest expected message.
            pub fn poll(self: *Session, out: []u8) ?Event {
                // If the socket dropped but we still want to be connected, tear
                // down and schedule a reopen; then (re)open once the cooldown ends.
                if (self.want_connected and self.sock != 0 and ws.state(self.sock) == .closed) {
                    self.dropForReconnect();
                }
                if (self.want_connected and self.sock == 0) {
                    if (self.reconnect_wait > 0) {
                        self.reconnect_wait -= 1;
                    } else {
                        self.sock = ws.open(self.url_buf[0..self.url_len]);
                        self.joined = false;
                    }
                }

                // Keep the host up to date with the current membership.
                self.recomputeHost();

                // Send JOIN the moment the socket is open (once).
                if (self.sock != 0 and !self.joined and ws.state(self.sock) == .open) {
                    var jb: [96]u8 = undefined;
                    const room: []const u8 = self.room_buf[0..self.room_len];
                    const jmsg: []const u8 = bufPrint(&jb, "JOIN {s}", .{room}) catch "JOIN room";
                    ws.send(self.sock, jmsg);
                    self.joined = true;
                }

                // 1. Anything already queued?
                if (self.control.pop()) |ce| {
                    return controlToEvent(ce);
                }

                // 2. Drain signaling. Most messages enqueue control events or
                //    drive negotiation; a RELAYED frame carries game data from a
                //    relayed peer, so it's decoded and returned straight out.
                if (self.sock != 0) {
                    while (ws.poll(self.sock, &self.ws_buf)) |m| {
                        if (startsWith(u8, m, "RELAYED ")) {
                            if (decodeRelayed(m, out)) |msg| {
                                return msg;
                            }
                        } else {
                            self.handleSignaling(m);
                        }
                    }
                }
                if (self.control.pop()) |ce| {
                    return controlToEvent(ce);
                }

                // 3. Drain each peer's RTC events. Negotiation is relayed out over
                //    signaling; channel-opens queue a control event; data is returned
                //    straight to the caller (bytes copied into `out`).
                var i: usize = 0;
                while (i < self.peer_count) : (i += 1) {
                    const peer: *Peer = &self.peers[i];
                    if (!peer.active or peer.pc == 0) {
                        continue;
                    }
                    while (rtc.poll(peer.pc, &self.rtc_buf)) |rev| {
                        switch (rev.kind) {
                            .local_offer => self.signal(peer.id, "offer", rev.payload),
                            .local_answer => self.signal(peer.id, "answer", rev.payload),
                            .local_ice => self.signal(peer.id, "ice", rev.payload),
                            .channel_open => {
                                if (rev.channel < 2) {
                                    peer.chan_open[rev.channel] = true;
                                }
                                self.control.push(.{
                                    .kind = .channel_open,
                                    .peer = peer.id,
                                    .channel = rev.channel,
                                });
                            },
                            .data => {
                                const n: usize = @min(rev.payload.len, out.len);
                                @memcpy(out[0..n], rev.payload[0..n]);
                                return .{ .message = .{
                                    .peer = peer.id,
                                    .channel = rev.channel,
                                    .bytes = out[0..n],
                                } };
                            },
                            .state => {
                                const cs: ConnState = parseConnState(rev.payload);
                                if (cs == .failed) {
                                    // Direct connection gave up. Rather than drop the peer, fall back to relaying
                                    // it through the signaling server.
                                    self.switchToRelay(peer);
                                } else if (cs == .closed) {
                                    // Deliberately torn down - drop the peer.
                                    self.removePeer(peer.id);
                                } else {
                                    self.control.push(.{
                                        .kind = .peer_state,
                                        .peer = peer.id,
                                        .channel = @backingInt(cs),
                                    });
                                }
                            },
                            .none => {},
                        }
                    }
                }

                // 4. Control events queued during the RTC drain (channel-opens).
                if (self.control.pop()) |ce| {
                    return controlToEvent(ce);
                }
                return null;
            }

            // -- internals ----------------------------------------------------------

            fn controlToEvent(ce: ControlEvent) Event {
                return switch (ce.kind) {
                    .joined_as => .{ .joined_as = ce.peer },
                    .peer_joined => .{ .peer_joined = ce.peer },
                    .peer_left => .{ .peer_left = ce.peer },
                    .peer_state => .{ .peer_state = .{
                        .peer = ce.peer,
                        .state = @fromBackingInt(@intCast(ce.channel)),
                    } },
                    .channel_open => .{ .channel_open = .{ .peer = ce.peer, .channel = ce.channel } },
                    .host_changed => .{ .host_changed = ce.peer },
                    .room_full => .room_full,
                };
            }

            // The host is the lowest-id peer in the room, counting us. Recompute
            // it and, if it changed, queue a host_changed event. Everyone runs the
            // same rule over the same membership, so they agree without any vote.
            fn recomputeHost(self: *Session) void {
                var lowest: u32 = 0;
                if (self.my_id != 0) {
                    lowest = self.my_id;
                }
                var i: usize = 0;
                while (i < self.peer_count) : (i += 1) {
                    const p: Peer = self.peers[i];
                    if (p.active and (lowest == 0 or p.id < lowest)) {
                        lowest = p.id;
                    }
                }
                if (lowest != self.host_id) {
                    self.host_id = lowest;
                    if (lowest != 0) {
                        self.control.push(.{ .kind = .host_changed, .peer = lowest, .channel = 0 });
                    }
                }
            }

            fn findPeer(self: *Session, id: u32) ?*Peer {
                var i: usize = 0;
                while (i < self.peer_count) : (i += 1) {
                    if (self.peers[i].active and self.peers[i].id == id) {
                        return &self.peers[i];
                    }
                }
                return null;
            }

            // Add a peer and start negotiating. `offerer` = we send the SDP offer;
            // otherwise we create the connection and wait for theirs. Returns null if
            // the mesh is full or the peer already exists.
            fn addPeer(self: *Session, id: u32, offerer: bool) ?*Peer {
                if (self.findPeer(id)) |existing| {
                    return existing;
                }
                // Prefer an inactive slot; else grow the table.
                var slot: ?usize = null;
                var i: usize = 0;
                while (i < self.peer_count) : (i += 1) {
                    if (!self.peers[i].active) {
                        slot = i;
                        break;
                    }
                }
                if (slot == null) {
                    if (self.peer_count >= max_peers) {
                        return null; // mesh full
                    }
                    slot = self.peer_count;
                    self.peer_count += 1;
                }
                const p: *Peer = &self.peers[slot.?];
                // A transport that cannot make direct connections - WebRTC exists only in the browser - relays every
                // peer through the server from the start, and tells the peer so (`relay`): a peer that can make
                // direct connections would otherwise wait for one that never comes - offering, with no answer, or
                // waiting for an offer never made.
                const direct_connection: rtc.Handle = rtc.create();
                const relays_from_start: bool = direct_connection == 0;
                p.* = .{
                    .id = id,
                    .pc = direct_connection,
                    .chan_open = .{ false, false },
                    .active = true,
                    .relay = false,
                };
                if (offerer and !relays_from_start) {
                    rtc.createOffer(p.pc);
                }
                self.control.push(.{ .kind = .peer_joined, .peer = id, .channel = 0 });
                if (relays_from_start) {
                    self.switchToRelay(p);
                    self.signal(id, "relay", "-");
                }
                return p;
            }

            fn removePeer(self: *Session, id: u32) void {
                if (self.findPeer(id)) |p| {
                    if (p.pc != 0) {
                        rtc.close(p.pc);
                    }
                    p.active = false;
                    p.pc = 0;
                    self.control.push(.{ .kind = .peer_left, .peer = id, .channel = 0 });
                }
            }

            fn handleSignaling(self: *Session, msg: []const u8) void {
                if (startsWith(u8, msg, "FULL")) {
                    // The room is full; the server turned us away. Stop here - tear
                    // down (without clearing the queue, so room_full survives) so we
                    // don't keep trying to rejoin a room that has no space.
                    self.want_connected = false;
                    if (self.sock != 0) {
                        ws.close(self.sock);
                        self.sock = 0;
                    }
                    self.joined = false;
                    self.control.push(.{ .kind = .room_full, .peer = 0, .channel = 0 });
                } else if (startsWith(u8, msg, "WELCOME ")) {
                    // WELCOME <my_id> [existing ids...]. Everyone already here joined
                    // before us (lower ids), so by convention they offer to us.
                    var rest: []const u8 = msg[8..];
                    const first: Split = splitFirst(rest);
                    self.my_id = parseInt(u32, first.tok, 10) catch 0;
                    self.control.push(.{ .kind = .joined_as, .peer = self.my_id, .channel = 0 });
                    rest = first.rest;
                    while (rest.len > 0) {
                        const s: Split = splitFirst(rest);
                        const id: u32 = parseInt(u32, s.tok, 10) catch 0;
                        if (id != 0) {
                            _ = self.addPeer(id, self.my_id < id);
                        }
                        rest = s.rest;
                    }
                } else if (startsWith(u8, msg, "JOINED ")) {
                    // A newcomer (higher id) - we offer to them.
                    const id: u32 = parseInt(u32, splitFirst(msg[7..]).tok, 10) catch 0;
                    if (id != 0) {
                        _ = self.addPeer(id, self.my_id < id);
                    }
                } else if (startsWith(u8, msg, "LEFT ")) {
                    const id: u32 = parseInt(u32, splitFirst(msg[5..]).tok, 10) catch 0;
                    self.removePeer(id);
                } else if (startsWith(u8, msg, "FROM ")) {
                    // FROM <from> <kind> <data> - the peer's half of the handshake.
                    const a: Split = splitFirst(msg[5..]); // from id
                    const from: u32 = parseInt(u32, a.tok, 10) catch 0;
                    const b: Split = splitFirst(a.rest); // kind
                    const kind: []const u8 = b.tok;
                    const data: []const u8 = b.rest;
                    // An offer - or a peer's saying it relays - may arrive from a peer we haven't added yet
                    // (ordering); adopt it as the answerer so the connection can proceed.
                    var peer: ?*Peer = self.findPeer(from);
                    const adopts_peer: bool = eql(u8, kind, "offer") or eql(u8, kind, "relay");
                    if (peer == null and adopts_peer) {
                        peer = self.addPeer(from, false);
                    }
                    if (peer) |p| {
                        if (eql(u8, kind, "relay")) {
                            // The peer cannot make direct connections: relay it at once.
                            self.switchToRelay(p);
                        } else if (eql(u8, kind, "offer")) {
                            rtc.setRemote(p.pc, true, data);
                        } else if (eql(u8, kind, "answer")) {
                            rtc.setRemote(p.pc, false, data);
                        } else if (eql(u8, kind, "ice")) {
                            rtc.addIce(p.pc, data);
                        }
                    }
                }
            }

            /// Switches a peer to relaying through the signaling server: its direct connection, if it has one, is
            /// closed, and the game is told (`relayed`), once. Done when a direct connection fails, when this side
            /// cannot make one, and when the peer says it cannot (`relay`).
            fn switchToRelay(self: *Session, peer: *Peer) void {
                if (peer.pc != 0) {
                    rtc.close(peer.pc);
                    peer.pc = 0;
                }
                if (peer.relay) {
                    return;
                }
                peer.relay = true;
                self.control.push(.{
                    .kind = .peer_state,
                    .peer = peer.id,
                    .channel = @backingInt(ConnState.relayed),
                });
            }

            fn signal(
                self: *Session,
                peer_id: u32,
                kind: []const u8,
                data: []const u8,
            ) void {
                const msg: []const u8 = bufPrint(&self.send_buf, "SIGNAL {d} {s} {s}", .{ peer_id, kind, data }) catch {
                    return; // over buffer; the SDP was implausibly large
                };
                ws.send(self.sock, msg);
            }

            // Relay a peer's game data through the signaling server - the fallback
            // when the direct connection failed. The payload is base64'd so binary
            // game bytes survive the text-based signaling channel intact.
            fn relaySend(
                self: *Session,
                peer_id: u32,
                channel: u8,
                bytes: []const u8,
            ) void {
                const prefix: []const u8 = bufPrint(
                    &self.send_buf,
                    "RELAY {d} {d} ",
                    .{ peer_id, channel },
                ) catch return;
                const need: usize = @divCeil(bytes.len, 3) * 4; // base64 (padded) length
                if (prefix.len + need > self.send_buf.len) {
                    return; // too large to relay
                }
                const enc = std.base64.standard.Encoder;
                const dest: []u8 = self.send_buf[prefix.len .. prefix.len + need];
                _ = enc.encode(dest, bytes);
                ws.send(self.sock, self.send_buf[0 .. prefix.len + need]);
            }

            // Decode a "RELAYED <from> <channel> <base64>" frame into `out` and
            // hand it back as a normal message event.
            fn decodeRelayed(m: []const u8, out: []u8) ?Event {
                const after: []const u8 = m["RELAYED ".len..];
                const a: Split = splitFirst(after); // from id
                const from: u32 = parseInt(u32, a.tok, 10) catch return null;
                const b: Split = splitFirst(a.rest); // channel
                const ch_num: u32 = parseInt(u32, b.tok, 10) catch return null;
                const b64: []const u8 = b.rest;
                const dec = std.base64.standard.Decoder;
                const need: usize = dec.calcSizeForSlice(b64) catch return null;
                if (need > out.len) {
                    return null;
                }
                dec.decode(out[0..need], b64) catch return null;
                return .{ .message = .{ .peer = from, .channel = @intCast(ch_num), .bytes = out[0..need] } };
            }
        };
    };
}

// ---- room names -----------------------------------------------------------
//
// Human-shareable room names like "brave-otter-42": easy to read out loud or
// type on a phone. Deterministic given a seed, so the same seed always makes
// the same name (handy for tests); pass something varying (a timestamp, a frame
// count) for a fresh room. The seed is mixed first (splitmix64 finalizer) so
// even sequential seeds spread across the whole word space.

const adjectives = [_][]const u8{
    "brave", "calm",   "clever", "bold",   "bright", "swift",  "quiet", "sunny",
    "lucky", "merry",  "gentle", "jolly",  "keen",   "witty",  "eager", "fancy",
    "happy", "mighty", "nimble", "proud",  "shiny",  "spry",   "tidy",  "vivid",
    "warm",  "wise",   "zesty",  "cosmic", "golden", "silver", "royal", "wild",
};

const nouns = [_][]const u8{
    "otter", "falcon", "koala",  "panda", "tiger",  "eagle",  "wolf",  "fox",
    "lynx",  "moose",  "raven",  "heron", "badger", "beaver", "cobra", "dingo",
    "gecko", "ibis",   "jaguar", "kiwi",  "lemur",  "marmot", "newt",  "osprey",
    "puma",  "quokka", "robin",  "seal",  "toad",   "urchin", "viper", "wombat",
};

/// Write a room name like "brave-otter-42" into `out` and return the slice.
/// `out` needs ~24 bytes; longer names are truncated to fit.
pub fn generateRoomName(seed: u64, out: []u8) []const u8 {
    var x: u64 = seed;
    x ^= x >> 30;
    x *%= 0xbf58476d1ce4e5b9;
    x ^= x >> 27;
    x *%= 0x94d049bb133111eb;
    x ^= x >> 31;

    const adj: []const u8 = adjectives[@intCast(x % adjectives.len)];
    x /= adjectives.len;
    const noun: []const u8 = nouns[@intCast(x % nouns.len)];
    x /= nouns.len;
    const num: u64 = x % 100;

    const name: []const u8 = bufPrint(out, "{s}-{s}-{d:0>2}", .{ adj, noun, num }) catch out[0..0];
    return name;
}

test "websocket: the accept value for RFC 6455's example key is the RFC's" {
    var out: [28]u8 = undefined;
    const accept: []const u8 = websocket.computeAccept("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "websocket: a frame written, masked or not, short or extended, reads back as it was" {
    var long_payload: [300]u8 = undefined;
    for (&long_payload, 0..) |*byte, index| {
        byte.* = @intCast(index % 251);
    }
    const masks = [_]?[4]u8{ null, .{ 0x12, 0x34, 0x56, 0x78 } };
    const payloads = [_][]const u8{ "hello, frames", &long_payload };
    for (masks) |mask| {
        for (payloads) |payload| {
            var storage: [512]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&storage);
            try websocket.writeFrame(&writer, .binary, payload, mask);
            var reader: std.Io.Reader = .fixed(writer.buffered());
            var out: [512]u8 = undefined;
            const frame: websocket.Frame = try websocket.readFrame(&reader, &out);
            try expectEqual(websocket.Opcode.binary, frame.opcode);
            try expect(frame.is_final);
            try expectEqualSlices(u8, payload, out[0..frame.payload_len]);
        }
    }
}

test "native_websocket: an address's host, port and target, with their defaults" {
    const full: native_websocket.Address = native_websocket.parseAddress("ws://example.org:7777/rooms?name=a").?;
    try expectEqualStrings("example.org", full.host);
    try expectEqual(@as(u16, 7777), full.port);
    try expectEqualStrings("/rooms?name=a", full.target);
    const bare: native_websocket.Address = native_websocket.parseAddress("ws://localhost").?;
    try expectEqual(@as(u16, 80), bare.port);
    try expectEqualStrings("/", bare.target);
    // A query with no path ends the host, rather than joining it.
    const query_only: native_websocket.Address = native_websocket.parseAddress("ws://localhost:8080?room=a").?;
    try expectEqualStrings("localhost", query_only.host);
    try expectEqualStrings("?room=a", query_only.target);
    // An IPv6 address loses its brackets, with or without a port.
    const ipv6: native_websocket.Address = native_websocket.parseAddress("ws://[::1]:7777/").?;
    try expectEqualStrings("::1", ipv6.host);
    try expectEqual(@as(u16, 7777), ipv6.port);
    try expectEqualStrings("::1", native_websocket.parseAddress("ws://[::1]").?.host);
    const secure: native_websocket.Address = native_websocket.parseAddress("wss://example.org/socket").?;
    try expect(secure.is_secure);
    try expectEqual(@as(u16, 443), secure.port);
    try expect(!full.is_secure);
    try expect(native_websocket.parseAddress("http://example.org") == null);
    try expect(native_websocket.parseAddress("ws://:80/") == null);
    try expect(native_websocket.parseAddress("ws://[::1]x") == null);
}

test "websocket: readHead finds the head's end, and leaves what follows buffered" {
    var reader: std.Io.Reader = .fixed("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n\x81\x02hi");
    const head_byte_count: usize = websocket.readHead(&reader).?;
    try expectEqual(@as(usize, 56), head_byte_count);
    reader.toss(head_byte_count);
    var out: [8]u8 = undefined;
    const frame: websocket.Frame = try websocket.readFrame(&reader, &out);
    try expectEqualStrings("hi", out[0..frame.payload_len]);
}

/// A reader over `bytes` whose own buffer is only `buffer` long, for the tests of frames and heads longer than it.
fn smallBufferReaderForTest(source: *std.Io.Reader, buffer: []u8) std.Io.Reader.Limited {
    return std.Io.Reader.Limited.init(source, .unlimited, buffer);
}

test "websocket: a frame longer than the reader's buffer is read whole" {
    var payload: [300]u8 = undefined;
    for (&payload, 0..) |*byte, index| {
        byte.* = @intCast(index % 251);
    }
    var storage: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try websocket.writeFrame(&writer, .binary, &payload, .{ 9, 8, 7, 6 });
    var source: std.Io.Reader = .fixed(writer.buffered());
    var small_buffer: [64]u8 = undefined;
    var limited: std.Io.Reader.Limited = smallBufferReaderForTest(&source, &small_buffer);
    var out: [512]u8 = undefined;
    const frame: websocket.Frame = try websocket.readFrame(&limited.interface, &out);
    try expectEqualSlices(u8, &payload, out[0..frame.payload_len]);
}

test "websocket: a head that fills the reader's buffer without ending is refused, not overrun" {
    const long_value: [200]u8 = @splat('a');
    const long_head: []const u8 = "HTTP/1.1 101 Switching Protocols\r\nX-Long: " ++ long_value ++ "\r\n\r\n";
    var source: std.Io.Reader = .fixed(long_head);
    var small_buffer: [64]u8 = undefined;
    var limited: std.Io.Reader.Limited = smallBufferReaderForTest(&source, &small_buffer);
    try expect(websocket.readHead(&limited.interface) == null);
}

test "native_websocket: the parts of a message are gathered, a ping between them, and broken orders refused" {
    var gatherer: native_websocket.MessageGatherer = .{};
    defer gatherer.deinit();
    const first_part: websocket.Frame = .{ .opcode = .text, .is_final = false, .payload_len = 4 };
    const ping: websocket.Frame = .{ .opcode = .ping, .is_final = true, .payload_len = 1 };
    const last_part: websocket.Frame = .{ .opcode = .continuation, .is_final = true, .payload_len = 6 };
    try expect((try gatherer.take(first_part, "hel")) == .nothing);
    try expectEqualStrings("p", (try gatherer.take(ping, "p")).ping);
    try expectEqualStrings("hello!", (try gatherer.take(last_part, "lo!")).message);
    // A continuation with no message begun, and a message begun inside another, break the protocol.
    try expect((try gatherer.take(last_part, "x")) == .broken);
    _ = try gatherer.take(first_part, "a");
    try expect((try gatherer.take(first_part, "b")) == .broken);
}

test "native_websocket: an answer is accepted only with the status, both upgrade headers, and the right accept" {
    const key: []const u8 = "dGhlIHNhbXBsZSBub25jZQ==";
    const accepted: []const u8 = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" ++
        "Connection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n";
    try expect(native_websocket.isAcceptedAnswer(accepted, key));
    const no_upgrade: []const u8 = "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n";
    try expect(!native_websocket.isAcceptedAnswer(no_upgrade, key));
    const wrong_accept: []const u8 = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" ++
        "Connection: Upgrade\r\nSec-WebSocket-Accept: AAAA\r\n\r\n";
    try expect(!native_websocket.isAcceptedAnswer(wrong_accept, key));
}
