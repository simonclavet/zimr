//! ============================================================================
//! signal_server.zig - a tiny WebSocket "signaling" server for zimr multiplayer
//! ============================================================================
//!
//! WHAT THIS IS FOR
//! ----------------
//! zimr games are peer-to-peer: once two players are connected, their game data
//! flows DIRECTLY between their machines (via WebRTC data channels), never
//! through a server. But there's a chicken-and-egg problem: before two browsers
//! can talk directly, they have to exchange a little bit of connection info
//! first - "here's my network address, here's the encryption I speak, here are
//! the routes you can reach me on." That exchange is called SIGNALING, and it
//! needs a middleman that both peers can reach. That's all this server is.
//!
//! Think of it like two people who want to have a private phone call but don't
//! know each other's numbers yet. They both call a shared switchboard, the
//! switchboard passes their numbers back and forth, and once they've dialed each
//! other directly they hang up on the switchboard. This server is the
//! switchboard. It never sees a single frame of gameplay.
//!
//! Concretely, the thing peers exchange through here is WebRTC's SDP (Session
//! Description Protocol) offers/answers and ICE candidates. We don't parse any
//! of it - to us it's just opaque text we shuttle from one peer to another.
//!
//! ROOMS
//! -----
//! Peers find each other by ROOM NAME. A host makes up a room name (later we'll
//! auto-generate friendly ones like "brave-otter-42"), tells a friend, the
//! friend types it in, and now they're in the same room and can see each other.
//! A room is just "all the peers who sent us the same JOIN name."
//!
//! THE WIRE PROTOCOL
//! -----------------
//! We talk WebSocket (so browsers can connect with the built-in `WebSocket`
//! object). Every WebSocket text frame is exactly one message. Each message is
//! space-separated: a verb, then some fields, then possibly a big opaque "rest"
//! that can itself contain spaces AND newlines (SDP has both), which is why the
//! raw data always goes LAST and we never try to tokenize past it.
//!
//!   client -> server:
//!       JOIN <room>                     "put me in this room"
//!       SIGNAL <to-peer-id> <raw...>    "relay this blob to that peer"
//!
//!   server -> client:
//!       WELCOME <your-id> <peer-ids...> "you're in; here's who's already here"
//!       JOINED <new-peer-id>            "someone new just joined your room"
//!       LEFT <peer-id>                  "someone in your room disconnected"
//!       FROM <from-peer-id> <raw...>    "peer X sent you this blob"
//!
//! Every peer gets a small integer id (1, 2, 3, ...) the moment it connects.
//! Peers address each other by that id when they SIGNAL.
//!
//! HOW TO RUN IT
//! -------------
//!   zig build signal-server -- --port=7777
//! (--port is optional; without it the PORT environment variable decides, then 7777 - hosting platforms set PORT,
//! and this keeps working there. Before std's cli parser was vendored, PORT was the only way in, because
//! the new std doesn't ship command-line arg parsing in this build.)
//!
//! WHY THE NEW `Io` MODEL
//! ----------------------
//! We're on Zig 0.17 master, and in this build the old blocking sockets
//! (std.net, the posix socket calls, std.Thread.Mutex) are gone. Networking now
//! lives behind the new `Io` interface: you get an `Io` handle and do everything
//! through it - listen, accept, read, write - and concurrency is "green threads"
//! (`io.async`) rather than OS threads. This server is built entirely on that.
//!
//! THE CONCURRENCY DESIGN (short version)
//! --------------------------------------
//! One `io.async` task per connection. All of them share one `Registry`. The
//! only rule we need for correctness: writes to a socket must not interleave. We
//! get that with a SINGLE async `Io.Mutex` that every write takes. It's an
//! *async* mutex, so it's safe to hold across an `await` (a socket write is an
//! await) - waiters suspend instead of spinning. Reads don't take the lock at
//! all: each connection reads only its own socket, and reading + writing the
//! same socket at once is fine (TCP is full-duplex). See the big note down by
//! `main` for the one gotcha that cost an afternoon.
//! ============================================================================

const std = @import("std");
const cli = @import("cli");
const Io = std.Io;
// The WebSocket protocol - its frames and its opening handshake - shared with the other server and the engine's
// native client (`net_core.websocket`).
const websocket = @import("net_core").websocket;
const Opcode = websocket.Opcode;
const Frame = websocket.Frame;
const readFrame = websocket.readFrame;
const findHeaderValue = websocket.findHeaderValue;
const computeAccept = websocket.computeAccept;
const indexOfScalar = std.mem.indexOfScalar;
const parseInt = std.fmt.parseInt;
const net = Io.net; // the new Io-based networking: IpAddress, Server, Stream
const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;
const ArrayList = std.ArrayList;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;

const default_port = "7777";

// Signaling messages are tiny - an SDP offer is a couple KB, an ICE candidate
// is a few hundred bytes. 16 KB is comfortably roomy. If a peer ever tries to
// send something bigger than this we just drop that frame (see readFrame).
const max_message_bytes: usize = 16 * 1024;

// The read buffer needs to hold a whole message PLUS its frame header and mask,
// with a little slack. (WebSocket headers are at most 14 bytes, but 4 KB of
// slack costs nothing and keeps us clear of edge cases.)
const read_buffer_bytes: usize = max_message_bytes + 4096;

// The most peers we let into one room. This matches the mesh cap on the client
// (net_core's max_peers): if we let a 9th peer in, the others' full-mesh caps
// would reject it and the room would desync, so we turn it away with FULL.
const room_cap: usize = 8;

// ----------------------------------------------------------------------------
// Peer - one connected client.
// ----------------------------------------------------------------------------
// We keep the room name inline as a fixed 64-byte buffer instead of an allocated
// slice. Room names are short, and a fixed buffer means one less thing to
// allocate and free per peer. `room_len` says how many of those 64 bytes are
// actually the name.
const Peer = struct {
    id: u32,
    room: [64]u8 = undefined,
    room_len: usize = 0,
    stream: net.Stream, // the peer's socket
    // `alive` flips to false the instant a write to this peer fails. The peer's
    // own read loop notices it's dead on its next lap and tears the peer down.
    alive: bool = true,

    // The slice view of whatever's actually in the room buffer.
    fn roomName(self: *const Peer) []const u8 {
        return self.room[0..self.room_len];
    }

    // Copy a room name in, clamped so an over-long name can't overflow the 64
    // bytes (it'd just get truncated - fine for our purposes).
    fn setRoom(self: *Peer, name: []const u8) void {
        const n: usize = @min(name.len, self.room.len);
        @memcpy(self.room[0..n], name[0..n]);
        self.room_len = n;
    }
};

// ----------------------------------------------------------------------------
// Registry - the one piece of shared state across all connection tasks.
// ----------------------------------------------------------------------------
// Every connected peer lives in `peers`. `next_id` hands out the 1,2,3,... ids.
// `mutex` guards all of it AND serializes every socket write (see the module
// header). It's an async Io.Mutex, which is the whole trick that lets us hold
// the lock across the awaits that socket writes perform.
const Registry = struct {
    mutex: Io.Mutex = .init,
    gpa: Allocator,
    peers: ArrayList(*Peer) = .empty,
    next_id: u32 = 1,
};

// This is a mutable module-level global on purpose: there is exactly one
// registry for the whole server, and every connection task reaches it here.
// (The lint normally frowns on mutable globals; this is the legit exception.)
var registry: Registry = undefined; // lint:off module-var: server-wide peer registry, guarded by the async mutex

// Writes one whole message to a peer as a frame (`websocket.writeFrame`; a server's frames are never masked). Every
// caller holds the registry mutex, so two tasks never interleave their frames on one socket. The frame gathers in
// the writer's buffer and leaves in one write - a header written alone would hold its payload back until the peer
// acknowledged it, tens of milliseconds a message - and the shared writeFrame flushes before returning.
fn writeFrame(io: Io, stream: net.Stream, opcode: Opcode, payload: []const u8) !void {
    var write_buffer: [4096]u8 = undefined;
    var writer: net.Stream.Writer = stream.writer(io, &write_buffer);
    try websocket.writeFrame(&writer.interface, opcode, payload, null);
}

// Convenience: send a text message to one peer. If the write fails (peer's
// socket is broken), we don't propagate an error - we just mark the peer dead
// and let its own read loop clean it up on the next lap. This keeps every
// caller from having to think about "what if that peer just vanished."
fn sendText(io: Io, peer: *Peer, text: []const u8) void {
    writeFrame(io, peer.stream, Opcode.text, text) catch {
        peer.alive = false;
    };
}

// ----------------------------------------------------------------------------
// The HTTP -> WebSocket upgrade handshake.
// ----------------------------------------------------------------------------
// A WebSocket connection starts life as an ordinary HTTP GET with some special
// headers. The browser sends a random "Sec-WebSocket-Key," and we must reply
// with "Sec-WebSocket-Accept" = base64(sha1(key ++ websocket.magic_guid)). That proves to
// the browser we really do speak WebSocket, and after our "101 Switching
// Protocols" reply, both sides stop speaking HTTP and start exchanging frames.

// Do the whole handshake on a freshly-accepted connection. Returns true if we
// successfully upgraded to WebSocket, false if the request was malformed or the
// peer hung up early. After this returns true, `reader` is positioned exactly at
// the first WebSocket frame.
fn handshake(io: Io, reader: *Io.Reader, stream: net.Stream) !bool {
    // Read until the blank line ("\r\n\r\n") that ends the HTTP headers
    // (`websocket.readHead`, shared with the engine's native client); a peer that
    // closes before finishing the request is turned away. The full request head is
    // everything up to and including the blank line.
    const head_end: usize = websocket.readHead(reader) orelse return false;
    const head_all: []const u8 = reader.buffered();

    // Find the key the browser sent. No key => not a real WebSocket request.
    const key: []const u8 = findHeaderValue(head_all[0..head_end], "sec-websocket-key") orelse return false;

    // Build and send the "101 Switching Protocols" response with our accept.
    var accept_buf: [40]u8 = undefined;
    const accept: []const u8 = computeAccept(key, &accept_buf);
    var response_buf: [256]u8 = undefined;
    const response: []const u8 = try bufPrint(&response_buf, "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: {s}\r\n\r\n", .{accept});
    var writer: net.Stream.Writer = stream.writer(io, &.{});
    try writer.interface.writeAll(response);
    try writer.interface.flush(); // <- without this the browser never sees the reply

    // Consume the HTTP head out of the reader so the next read starts on the
    // first WebSocket frame. (Anything the peer pipelined after the head stays
    // buffered and is read normally.)
    _ = try reader.take(head_end);
    return true;
}

// ----------------------------------------------------------------------------
// Handling each kind of client message.
// ----------------------------------------------------------------------------

// JOIN: record the peer's room, tell everyone already in that room that someone
// new arrived, then tell the newcomer who's already here.
//
// We take the registry mutex for the whole thing. Note we hold it across the
// socket writes (sendText -> writeFrame -> await). That's fine and deliberate:
// it's an async mutex, so holding it across an await just suspends other
// waiters, and it guarantees the peer list can't change mid-broadcast and that
// no two broadcasts interleave on a socket. The cost is that broadcasts are
// serialized server-wide, which for a friends-only discovery server is nothing.
fn handleJoin(io: Io, peer: *Peer, room: []const u8) !void {
    peer.setRoom(room);
    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);

    // Room cap: count who's already in this room. If it's full, turn the newcomer
    // away with FULL instead of letting it join a mesh that can't hold it.
    var occupancy: usize = 0;
    for (registry.peers.items) |other| {
        if (other.alive and eql(u8, other.roomName(), room)) {
            occupancy += 1;
        }
    }
    if (occupancy >= room_cap) {
        sendText(io, peer, "FULL");
        return;
    }

    // Build "WELCOME <me> <everyone already in the room>" into a stack buffer.
    var welcome_buf: [1024]u8 = undefined;
    var used: usize = (try bufPrint(&welcome_buf, "WELCOME {d}", .{peer.id})).len;
    for (registry.peers.items) |other| {
        if (other.alive and eql(u8, other.roomName(), room)) {
            // If we somehow overflow 1024 bytes of peer ids, just stop adding -
            // the welcome is still valid, merely truncated.
            const chunk: []u8 = bufPrint(welcome_buf[used..], " {d}", .{other.id}) catch break;
            used += chunk.len;
        }
    }

    // Announce the newcomer to everyone already in the room.
    var joined_buf: [32]u8 = undefined;
    const joined: []const u8 = try bufPrint(&joined_buf, "JOINED {d}", .{peer.id});
    for (registry.peers.items) |other| {
        if (other.alive and eql(u8, other.roomName(), room)) {
            sendText(io, other, joined);
        }
    }

    // Add the newcomer to the registry, THEN send it its welcome. (Order matters
    // only in that we don't want the newcomer listing itself in its own
    // welcome - so we append after building the list above.)
    try registry.peers.append(registry.gpa, peer);
    sendText(io, peer, welcome_buf[0..used]);
}

// SIGNAL <to-id> <raw...>: relay an opaque blob from this peer to one other peer
// in the same room. This is the actual WebRTC handshake traffic passing through.
fn handleSignal(io: Io, peer: *Peer, rest: []const u8) !void {
    // Split off just the first token (the destination id); everything after the
    // first space is the raw payload, spaces/newlines and all.
    const space: usize = indexOfScalar(u8, rest, ' ') orelse return;
    const to_id: u32 = parseInt(u32, rest[0..space], 10) catch return;
    const data: []const u8 = rest[space + 1 ..];

    // Reframe it as "FROM <sender-id> <raw...>". The blob can be a few KB, so we
    // allocate a buffer big enough for the prefix plus the data.
    const out: []u8 = try registry.gpa.alloc(u8, 32 + data.len);
    defer registry.gpa.free(out);
    const prefix: []const u8 = try bufPrint(out, "FROM {d} ", .{peer.id});
    @memcpy(out[prefix.len .. prefix.len + data.len], data);
    const message: []const u8 = out[0 .. prefix.len + data.len];

    // Deliver to the one matching peer in the same room. We check the room too
    // so a peer can't signal someone in a different room by guessing their id.
    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);
    for (registry.peers.items) |other| {
        if (other.alive and other.id == to_id and eql(u8, other.roomName(), peer.roomName())) {
            sendText(io, other, message);
            break;
        }
    }
}

// The DATA relay - the fallback path when two peers can't reach each other
// directly (strict NATs, symmetric firewalls). A client whose WebRTC connection
// failed sends "RELAY <to> <channel> <base64-payload>"; we reframe it as
// "RELAYED <from> <channel> <base64-payload>" and hand it to the target, exactly
// like handleSignal does for the handshake. The payload is opaque to us - we
// only need the destination id. This keeps every session playable with no TURN
// server, at the cost of routing those peers' packets through here.
fn handleRelay(io: Io, peer: *Peer, rest: []const u8) !void {
    const space: usize = indexOfScalar(u8, rest, ' ') orelse return;
    const to_id: u32 = parseInt(u32, rest[0..space], 10) catch return;
    const data: []const u8 = rest[space + 1 ..];

    const out: []u8 = try registry.gpa.alloc(u8, 32 + data.len);
    defer registry.gpa.free(out);
    const prefix: []const u8 = try bufPrint(out, "RELAYED {d} ", .{peer.id});
    @memcpy(out[prefix.len .. prefix.len + data.len], data);
    const message: []const u8 = out[0 .. prefix.len + data.len];

    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);
    for (registry.peers.items) |other| {
        if (other.alive and other.id == to_id and eql(u8, other.roomName(), peer.roomName())) {
            sendText(io, other, message);
            break;
        }
    }
}

// Tear a peer down when its connection ends: pull it out of the registry, tell
// its room it left, and free it. All under the mutex so no broadcast is
// iterating the list while we mutate it, and so nobody can be mid-write to this
// peer's socket while we free it.
fn cleanupPeer(io: Io, peer: *Peer) void {
    registry.mutex.lockUncancelable(io);

    // Remove from the peer list. swapRemove is O(1) and order doesn't matter to
    // us. After this, no future broadcast will find this peer.
    for (registry.peers.items, 0..) |p, i| {
        if (p == peer) {
            _ = registry.peers.swapRemove(i);
            break;
        }
    }

    // Announce the departure to whoever's left in the room (only if the peer had
    // actually joined a room - a peer that connected but never sent JOIN has no
    // room to notify).
    if (peer.room_len > 0) {
        var left_buf: [32]u8 = undefined;
        const left: []const u8 = bufPrint(&left_buf, "LEFT {d}", .{peer.id}) catch "LEFT 0";
        for (registry.peers.items) |other| {
            if (other.alive and eql(u8, other.roomName(), peer.roomName())) {
                sendText(io, other, left);
            }
        }
    }

    registry.mutex.unlock(io);

    // Safe to free now: it's out of the list and the mutex is released. Nobody
    // else can reach this pointer anymore.
    registry.gpa.destroy(peer);
}

// ----------------------------------------------------------------------------
// One connection, start to finish. This runs as its own io.async green thread.
// ----------------------------------------------------------------------------
fn handleConnection(io: Io, stream: net.Stream) void {
    defer stream.close(io);

    // Heap-allocate the read + message buffers rather than putting ~36 KB on the
    // stack. Green threads have modest stacks, so keeping big buffers off the
    // stack matters when many connections are live at once.
    const read_buf: []u8 = registry.gpa.alloc(u8, read_buffer_bytes) catch return;
    defer registry.gpa.free(read_buf);
    const msg_buf: []u8 = registry.gpa.alloc(u8, max_message_bytes) catch return;
    defer registry.gpa.free(msg_buf);

    // Wrap the socket in a buffered reader. `stream_reader` owns the buffer
    // state; `reader` is the generic Io.Reader interface we actually call.
    var stream_reader: net.Stream.Reader = stream.reader(io, read_buf);
    const reader: *Io.Reader = &stream_reader.interface;

    // Upgrade HTTP -> WebSocket. If it fails, just drop the connection.
    const ok: bool = handshake(io, reader, stream) catch return;
    if (!ok) {
        return;
    }

    // Create the peer and hand it the next id. Only the id assignment needs the
    // lock (two connections could be grabbing ids at the same moment).
    const peer: *Peer = registry.gpa.create(Peer) catch return;
    peer.* = .{ .id = 0, .stream = stream };
    registry.mutex.lockUncancelable(io);
    peer.id = registry.next_id;
    registry.next_id += 1;
    registry.mutex.unlock(io);

    // No matter how we exit the loop below, this runs and cleans the peer up.
    defer cleanupPeer(io, peer);

    std.log.info("[signal] peer {d} connected", .{peer.id});

    // The read loop: pull one frame at a time and act on it. This is where the
    // task spends almost all its life - parked in readFrame, awaiting the next
    // message. Because it's a green thread awaiting an async read, it costs us
    // nothing while idle (given a properly-sized async pool - see main).
    while (peer.alive) {
        const frame: Frame = readFrame(reader, msg_buf) catch break; // EndOfStream = peer left

        if (frame.opcode == Opcode.close) {
            break; // peer politely asked to close
        }
        if (frame.opcode == Opcode.ping) {
            // Keep-alive: answer pings with a pong echoing the payload.
            writeFrame(io, stream, Opcode.pong, msg_buf[0..frame.payload_len]) catch break;
            continue;
        }
        if (frame.opcode != Opcode.text) {
            continue; // ignore anything that isn't a text message
        }

        // Dispatch on the verb at the front of the message.
        const message: []const u8 = msg_buf[0..frame.payload_len];
        if (startsWith(u8, message, "JOIN ")) {
            handleJoin(io, peer, message[5..]) catch break;
        } else if (startsWith(u8, message, "SIGNAL ")) {
            handleSignal(io, peer, message[7..]) catch break;
        } else if (startsWith(u8, message, "RELAY ")) {
            handleRelay(io, peer, message[6..]) catch break;
        }
        // Unknown verbs are silently ignored - be liberal in what you accept.
    }

    std.log.info("[signal] peer {d} disconnected", .{peer.id});
}

// ----------------------------------------------------------------------------
// main - set up the io, bind the socket, and accept forever.
// ----------------------------------------------------------------------------
/// The command line (std's cli, `src/command_line.zig`).
const ServerArgs = struct {
    @"--port": ?u16 = null,
};

const server_cli: cli.Config(ServerArgs) = .{
    .prog = "zig build signal-server --",
    .description = "The WebSocket signaling server for zimr multiplayer: peers find each other through it.",
    .args = .{ .@"--port" = .{ .description = "where to listen; without it, the PORT variable, then 7777" } },
};

pub fn main(init: std.process.Init) !void {
    const args: ServerArgs = cli.args(&init, ServerArgs, server_cli);
    const port_text: []const u8 = init.environ_map.get("PORT") orelse default_port;
    const port: u16 = args.@"--port" orelse try parseInt(u16, port_text, 10);

    // smp_allocator is the thread-safe global allocator, which is what we want
    // since green threads may run across real OS threads in the pool.
    registry = .{ .gpa = std.heap.smp_allocator };

    // ========================================================================
    // THE GOTCHA THAT COST AN AFTERNOON - read this before touching the io.
    // ========================================================================
    // We build our OWN Io.Threaded here instead of using init.io. Why?
    //
    // The default io sizes its async thread pool to (CPU count - 1). On a
    // single-core machine that's ZERO. And when the async pool is full (or
    // zero-sized), `io.async` doesn't queue the task or spawn a thread - it runs
    // the task INLINE, right there on the calling thread.
    //
    // Our calling thread is the accept loop below. So with the default io on one
    // core, the very first connection's handleConnection would run inline, and
    // the moment it parked in its read loop waiting for a message, it would take
    // the accept loop down with it - frozen - and no second peer could ever
    // connect. (This is exactly the bug we hit: peer 1 joined fine, peer 2's
    // handshake hung forever.)
    //
    // Giving the pool real headroom (256 worker threads) means each connection
    // gets its own green thread and the accept loop stays free to keep
    // accepting. 256 is far more than a friends-only signaling server will ever
    // need; the threads are almost always parked on a socket, not burning CPU.
    // ========================================================================
    var threaded: Io.Threaded = .init(std.heap.smp_allocator, .{ .async_limit = .limited(256) });
    const io: Io = threaded.io();

    const address: net.IpAddress = try .parseIp4("0.0.0.0", port);
    var server: net.Server = try address.listen(io, .{ .reuse_address = true });
    std.log.info("[signal] listening on 0.0.0.0:{d}", .{port});

    // Accept forever. Each connection becomes its own green thread; the loop
    // itself just keeps grabbing the next one.
    while (true) {
        const stream: net.Stream = server.accept(io) catch continue;
        _ = io.async(handleConnection, .{ io, stream });
    }
}
