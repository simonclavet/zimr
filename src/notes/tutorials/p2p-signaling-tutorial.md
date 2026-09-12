# Building P2P Multiplayer in zimr — Part 1: The Signaling Server

This is a from-scratch walkthrough of the first piece of zimr's peer-to-peer
multiplayer: a small WebSocket **signaling server** written in pure Zig on the
0.17 `Io` model. It covers *why* we need it, *what* every part does, the two
protocols involved (WebSocket + a sliver of WebRTC), the new async I/O API, the
concurrency design, and the one nasty bug that ate an afternoon. It ends with a
detailed plan for the next three layers.

The code lives in `tools/signal_server.zig`. Everything here matches that file.

---

## 1. The big picture: why peer-to-peer, and four layers

The goal is dead-simple multiplayer: you host a game, you get a short room name
like `brave-otter-42`, you send it to a friend, they type it in, and now you're
playing together. No accounts, no matchmaking service, no dedicated game server
you have to run and pay for.

The key design decision is **peer-to-peer**: once two players are connected,
their game data (positions, inputs, events) flows **directly** between their two
machines. It never passes through a server. That's cheaper (no server bandwidth
per game), lower-latency (one hop instead of two), and it fits zimr's whole
"own the stack, no useless middlemen" philosophy.

But browsers can't just open a raw socket to another browser. The web platform's
answer is **WebRTC** — a browser-to-browser connection with encrypted, ordered-
or-unordered data channels. WebRTC is what actually carries our game data. The
catch (see the next section) is that two browsers need to exchange a little setup
information *before* they can form that direct connection, and they need a
mutually-reachable middleman to do it. That middleman is this server.

So the whole system is four layers, built bottom-up:

| Layer | What it is | Where it lives | Status |
|------:|------------|----------------|--------|
| **L0** | Signaling/discovery server (a tiny WebSocket relay: rooms + message passing, no game logic) | `tools/signal_server.zig` | ✅ **done — this doc** |
| **L1** | Zig client "bridge": drives the browser's `WebSocket` + `RTCPeerConnection` from wasm | `src/bridge.zig` | ⏭ next |
| **L2** | `src/net.zig` session layer: `hostRoom` / `joinRoom` / `broadcast` / `poll`, room-name generation | `src/net.zig` | later |
| **L3** | A 2D demo: every player's mouse cursor + clicks, shared live | `examples/` | later |

This document is **L0**. It's the foundation everything else sits on, and it's
the only part that runs *outside* the browser — it's a normal native binary you
run on some machine both players can reach (localhost while developing, a cheap
VPS later).

---

## 2. What "signaling" actually is (and why WebRTC can't skip it)

Here's the chicken-and-egg problem WebRTC has. Two browsers, A and B, want a
direct connection. But:

- Neither knows the other's IP address or which ports are open.
- Both are probably behind NAT (home routers), so their "address" as seen from
  the outside isn't the address they see locally.
- They need to agree on encryption keys and codecs before any data flows.

WebRTC solves the *connection* part with two mechanisms:

- **SDP (Session Description Protocol)** — a big blob of text describing "here's
  what I support, here's my crypto fingerprint, here's how to reach my media."
  One side makes an **offer**, the other makes an **answer**.
- **ICE candidates** — a list of "here are network paths you might reach me on,"
  discovered with the help of **STUN** servers (which just tell a browser its
  own public address). WebRTC tries the candidates until one connects, punching
  through NAT along the way.

But here's the thing: **WebRTC has no way to deliver the offer, answer, or ICE
candidates to the other peer.** That's not its job. It hands *you* the blobs and
says "get these to the other side somehow, I don't care how." Getting them to the
other side is **signaling**, and it needs a channel both peers can already reach.

That's the entire purpose of this server. A joins a room, B joins the same room,
and when A's browser produces an SDP offer, A sends it to the server addressed to
B, and the server relays it to B. B produces an answer, sends it back through the
server to A. They trade ICE candidates the same way. Once ICE finds a working
path, the direct WebRTC connection is live — and the server is done. It never
sees another byte.

**The server treats SDP and ICE as completely opaque.** It never parses them.
To this server they're just text with an addressee. That's why the wire protocol
(below) puts the raw blob *last* and never tries to tokenize past it — SDP is
full of spaces and newlines, and we just pass it through untouched.

The analogy that makes it click: two people want a private phone call but don't
have each other's numbers. They both call a shared switchboard. The switchboard
relays their numbers. Once they've dialed each other directly, they hang up on
the switchboard. **We are the switchboard.**

---

## 3. Zig 0.17's new `Io` model (because `std.net` is gone)

We're on Zig `0.17.0-dev` (master). In this build, the networking stack has been
rewritten and the old blocking APIs — `std.net`, the raw posix `socket`/`bind`/
`listen`/`accept` calls, even `std.Thread.Mutex` — are **not present**. If you
reach for them, they don't exist. This surprised us; the fix is to use the new
`Io` interface, which is where all I/O now lives.

The mental model:

- You get an **`Io`** handle. Everything — listening, accepting, reading,
  writing, sleeping, locking — goes *through* it. `Io` is an interface (a vtable);
  the actual implementation is a "backend" (we use `std.Io.Threaded`).
- Concurrency is **green threads** via `io.async(fn, args)`. It looks like
  spawning a thread, but the backend decides whether that's a real OS thread, a
  fiber, or an inline call. You write straight-line blocking-looking code, and
  the runtime handles the async underneath.
- Blocking operations (a socket read with no data yet) **suspend the green
  thread** rather than blocking an OS thread — *if* the pool has room. (Hold that
  thought; it's the whole of §7.)

### The API surface we actually use

Program entry point changed. `main` receives a `std.process.Init`:

```zig
pub fn main(init: std.process.Init) !void {
    const io: Io = init.io;                       // the I/O handle
    const port = init.environ_map.get("PORT");    // env vars (args aren't in this build)
    const alloc = init.arena.allocator();         // a process-lifetime arena
}
```

Networking, all under `std.Io.net`:

```zig
const net = std.Io.net;
const addr: net.IpAddress = try .parseIp4("0.0.0.0", port);
var server: net.Server = try addr.listen(io, .{ .reuse_address = true });
const stream: net.Stream = try server.accept(io);   // one client connection
stream.close(io);
```

Reading and writing go through generic buffered `Io.Reader` / `Io.Writer`:

```zig
var sr: net.Stream.Reader = stream.reader(io, buffer);  // buffer is []u8 you own
const r: *Io.Reader = &sr.interface;
const bytes: []u8 = try r.take(n);   // exactly n bytes, fills+awaits as needed
try r.fillMore();                    // pull in more; awaits
const view: []u8 = r.buffered();     // peek what's buffered right now

var sw: net.Stream.Writer = stream.writer(io, &.{});  // &.{} = unbuffered
try sw.interface.writeAll(bytes);
try sw.interface.flush();            // REQUIRED — writeAll may buffer
```

Two `take()` gotchas worth burning into memory:

1. **The slice `take(n)` returns is only valid until your next read.** It points
   into the reader's internal buffer, which the next read may shuffle. Copy out
   anything you still need *immediately*.
2. **`take(n)` awaits.** It fills the buffer until `n` bytes exist, suspending
   the green thread meanwhile. It only errors (`EndOfStream`) when the peer
   actually closes with fewer than `n` bytes left. So a plain idle socket does
   *not* error — it just parks. (We proved this in isolation while debugging.)

Async + locking:

```zig
_ = io.async(handleConnection, .{ io, stream });   // fire-and-forget green thread

var m: Io.Mutex = .init;   // an ASYNC mutex
m.lockUncancelable(io);    // or: try m.lock(io)
defer m.unlock(io);
```

The async mutex is the star of §6. Unlike a spinlock, it's **safe to hold across
an await** — waiters *suspend* instead of busy-spinning, so you can hold it while
you do a socket write (which awaits) without deadlocking a cooperative scheduler.

### The backend

`init.io`'s backend is `std.Io.Threaded`, which runs green tasks on a pool of OS
worker threads and uses blocking syscalls per task. You can also build your own
`Threaded` with custom options — which we do, for the reason in §7.

---

## 4. The WebSocket protocol, from scratch

Browsers can't speak raw TCP, but they *can* speak **WebSocket** via the built-in
`WebSocket` object. So the signaling channel is WebSocket, and this server
implements just enough of RFC 6455 to serve it. There are two halves: a one-time
HTTP handshake, then a simple binary framing for messages.

### 4.1 The handshake

A WebSocket connection is born as an ordinary HTTP `GET` with upgrade headers:

```
GET / HTTP/1.1
Host: example.com
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
Sec-WebSocket-Version: 13
```

The server must prove it genuinely speaks WebSocket (not just an HTTP server that
happened to 200 the request). It does this by taking the client's random
`Sec-WebSocket-Key`, appending a fixed magic GUID from the spec, hashing with
SHA-1, base64-ing the result, and echoing it back:

```
Sec-WebSocket-Accept = base64( sha1( key ++ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" ) )
```

Reply with `101 Switching Protocols` and that accept header, and the handshake is
done. Both sides stop speaking HTTP and start exchanging frames. In our code:

```zig
fn computeAccept(key: []const u8, out: []u8) []const u8 {
    var hasher: std.crypto.hash.Sha1 = .init(.{});
    hasher.update(key);
    hasher.update(magic_guid);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}
```

The handshake reader loop pulls bytes until it sees the blank line `\r\n\r\n`
that ends the headers, extracts the key (case-insensitively — HTTP header names
aren't case-sensitive), writes the 101 response, **flushes** (forgetting this
was a bug — the browser never saw the reply), and consumes the head so the reader
is positioned at the first frame.

### 4.2 The frame format

After the handshake, messages travel as frames. The RFC 6455 layout, which
`readFrame` decodes byte by byte:

```
 byte 0:  FIN(1) RSV(3) OPCODE(4)      we read only OPCODE (the low 4 bits)
 byte 1:  MASK(1) LEN7(7)              top bit = "is masked", low 7 = length

 if LEN7 == 126:  next 2 bytes = real length (16-bit, big-endian)
 if LEN7 == 127:  next 8 bytes = real length (64-bit, big-endian)
 otherwise:       LEN7 itself (0..125) is the length

 if MASK == 1:    next 4 bytes = masking key
 then:            <length> bytes of payload
```

The opcode tells us the frame type. We care about four:

```zig
const Opcode = struct {
    const text: u8 = 0x1;   // a UTF-8 text message  <- our protocol
    const close: u8 = 0x8;  // "I'm closing"
    const ping: u8 = 0x9;   // keep-alive probe
    const pong: u8 = 0xA;   // keep-alive reply
};
```

We answer `ping` with `pong` (so browsers and proxies keep the connection alive),
treat `close` as "peer's leaving," and ignore everything that isn't `text`.

### 4.3 Masking

Here's a rule that trips everyone up: **frames a client sends are always masked;
frames a server sends must never be masked.** Masking XORs every payload byte
with a 4-byte key that cycles `0,1,2,3,0,1,2,3,…`. It exists to defeat certain
cache-poisoning proxy attacks, not for security. So:

- Inbound (client → us): the MASK bit is set, we read the 4-byte key, and XOR
  the payload back to plaintext.
- Outbound (us → client): we never set the MASK bit and send the payload as-is.

```zig
// unmask inbound, in place
if (masked) {
    for (out[0..len], 0..) |*byte, i| {
        byte.* ^= mask[i % 4];
    }
}
```

That's the whole of WebSocket for our needs. No fragmentation handling (our
messages are small and single-frame), no extensions, no compression.

---

## 5. The server, piece by piece

### 5.1 Rooms and peers

A **peer** is one connected client:

```zig
const Peer = struct {
    id: u32,                     // 1, 2, 3, ... assigned on connect
    room: [64]u8 = undefined,    // room name, inline (no allocation)
    room_len: usize = 0,
    stream: net.Stream,          // the socket
    alive: bool = true,          // flipped false when a write to it fails
};
```

The room name is a fixed 64-byte inline buffer rather than an allocated slice —
room names are short, and inlining means one less thing to alloc/free per peer.
`alive` is a soft-delete flag: the instant a write to a peer fails, we mark it
dead, and its own read loop tears it down on the next lap.

A **room** isn't a data structure at all — it's just "every peer whose
`roomName()` matches." To broadcast to a room, we scan the peer list and match on
the name. For a friends-only server with a handful of peers, a linear scan is
completely fine.

All peers live in one shared **registry**:

```zig
const Registry = struct {
    mutex: Io.Mutex = .init,             // guards everything + serializes writes
    gpa: Allocator,
    peers: std.ArrayList(*Peer) = .empty,
    next_id: u32 = 1,
};
var registry: Registry = undefined;      // the one global (guarded by the mutex)
```

### 5.2 The message protocol

Every WebSocket text frame is exactly one message. Messages are space-separated:
a verb, some fields, then possibly a big opaque "rest" that can contain spaces
and newlines (SDP does), so the raw data is always last and we never tokenize
past it.

```
client -> server:
    JOIN <room>                     put me in this room
    SIGNAL <to-peer-id> <raw...>    relay this blob to that peer

server -> client:
    WELCOME <your-id> <peer-ids...> you're in; here's who's already here
    JOINED <new-peer-id>            someone new joined your room
    LEFT <peer-id>                  someone in your room disconnected
    FROM <from-peer-id> <raw...>    peer X sent you this blob
```

The flow for two peers A and B:

1. A connects, sends `JOIN game`. Server: A is alone, replies `WELCOME 1`.
2. B connects, sends `JOIN game`. Server replies `WELCOME 2 1` (B sees A), and
   sends A a `JOINED 2`.
3. A's browser makes a WebRTC offer, A sends `SIGNAL 2 <offer>`. Server relays
   `FROM 1 <offer>` to B.
4. B answers, sends `SIGNAL 1 <answer>`. Server relays `FROM 2 <answer>` to A.
5. They trade ICE candidates the same way. WebRTC connects directly.
6. A disconnects → server sends B a `LEFT 1`.

That's exactly what the passing end-to-end test exercises, newlines-in-the-blob
and all.

### 5.3 Reading and writing frames

`readFrame` (§4.2) decodes the header, honors the 126/127 length escapes, copies
the header/mask bytes out immediately (because `take()` views are transient),
copies the payload into the caller's buffer, and unmasks in place. It guards the
output buffer — an over-large frame is refused with `error.MessageTooLarge`
rather than smashing memory.

`writeFrame` is the mirror, minus masking. It builds the 2/4/10-byte header,
writes it, writes the payload, and **flushes**. `sendText` wraps it so callers
don't have to handle "what if that peer just vanished" — a failed write simply
marks the peer dead:

```zig
fn sendText(io: Io, peer: *Peer, text: []const u8) void {
    writeFrame(io, peer.stream, Opcode.text, text) catch {
        peer.alive = false;
    };
}
```

### 5.4 The connection lifecycle

Each connection is one `io.async` green thread running `handleConnection`:

1. Allocate the read + message buffers **on the heap** (green-thread stacks are
   modest; keeping ~36 KB of buffers off the stack matters when many connections
   are live).
2. Wrap the socket in a buffered reader.
3. Do the WebSocket handshake; bail on failure.
4. Create the peer, assign it the next id (the *only* step that needs the lock
   here — two connections could grab ids simultaneously).
5. `defer cleanupPeer(...)` so no matter how the loop exits, the peer is removed
   from the registry, its room is told it `LEFT`, and it's freed.
6. Loop: read a frame, dispatch on the verb (`JOIN` / `SIGNAL`), answer pings,
   stop on close/EOF.

`handleJoin`, `handleSignal`, and `cleanupPeer` each take the registry mutex for
their duration. That's the subject of the next section.

---

## 6. Concurrency: one async mutex, and why it's safe across a write

The whole concurrency design rests on one invariant:

> **Two tasks must never be halfway through writing to the *same* socket at
> once.** Their frames would interleave into garbage.

Everything else is either naturally safe or falls out of protecting that.

Our solution is minimal: **a single async `Io.Mutex` that every socket write
takes.** `handleJoin`, `handleSignal`, and `cleanupPeer` all lock it, do their
reads-of-the-registry and their writes-to-sockets, and unlock. Because it's one
lock for all writes, no two writes to any socket can overlap.

The subtle part: those functions **hold the lock across the socket writes**, and
a socket write is an `await`. With an ordinary spinlock in a cooperative
scheduler, that's an instant deadlock — the holder suspends mid-write, another
task tries to lock, spins forever (never yielding), and the holder never resumes.

An **async mutex** fixes exactly this: a task that can't get the lock **suspends**
(and lets the scheduler run the holder) instead of spinning. So holding it across
an await is fine and intended. The only cost is that broadcasts are serialized
server-wide — one at a time. For a friends-only discovery server, that's free.

Two more things fall out of holding the lock across the whole operation:

- **The peer list can't change mid-broadcast.** Since `handleJoin` /
  `cleanupPeer` also mutate the list under the same lock, iterating it during a
  broadcast is safe — no realloc-under-your-feet, no shifting indices.
- **No peer is freed while someone's writing to it.** `cleanupPeer` removes the
  peer from the list *and* frees it under the lock, so a broadcast (also under
  the lock) can never be mid-write to a socket that's about to be freed. No
  use-after-free.

What *doesn't* need the lock: **reads**. Each connection reads only its own
socket, so there's no cross-task contention on reads. And reading a socket while
another task writes to it is fine — TCP is **full-duplex**, the two directions
are independent. So the read loop runs lock-free, which is exactly what you want
since that's where every task spends ~all its time (parked, awaiting the next
message).

This is deliberately the *simple* correct design. A higher-throughput version
would use per-peer write locks plus a snapshot-and-refcount scheme so a slow peer
can't stall broadcasts to others — noted as a future refinement, unnecessary now.

---

## 7. The bug that cost an afternoon: `async_limit = 0`

The server compiled and the first peer worked perfectly. But the **second** peer
could never connect — its handshake hung forever. Here's the hunt, because the
lesson generalizes.

First, isolation. A stripped-down echo server proved that all the scary
suspects were innocent:

- Multiple reads on one connection across an idle gap? **Fine** — the read
  parked through the idle and resumed.
- A write between reads? **Fine.**
- The async mutex around writes? **Fine.**
- Three genuinely concurrent connections? **Fine** — all three handshook.

So the minimal server did everything the real one did, and worked. The one
difference that reproduced the failure: in the real flow, peer A **fully joins
and then sits idle** in its read loop *before* peer B connects. Concurrent joins
worked; **sequential** (A idles, then B arrives) failed.

That pointed straight at the scheduler, and the cause was brutal in hindsight.
The default `io` sizes its async worker pool to `cpu_count - 1`. **This sandbox
has one core**, so the pool size is **zero**. And the documented behavior when
the async pool is full (or zero) is not "queue the task" or "spawn a thread" —
it's **run the task inline, on the calling thread.**

The calling thread is the accept loop:

```zig
while (true) {
    const stream = server.accept(io) catch continue;
    _ = io.async(handleConnection, .{ io, stream });  // <- runs INLINE on 1 core
}
```

So on one core, `handleConnection(A)` ran *inline* — right there in the accept
loop. The moment A parked in its read loop waiting for A's next message, it took
the accept loop down with it. Frozen. `accept()` never ran again, so B's
connection sat unaccepted until it timed out. One idle client wedged the entire
server.

The fix is to build our own `Threaded` io with real pool headroom instead of
using `init.io`:

```zig
var threaded: std.Io.Threaded = std.Io.Threaded.init(
    std.heap.smp_allocator,
    .{ .async_limit = .limited(256) },   // 256 worker threads, not cpu_count-1
);
const io: Io = threaded.io();
```

Now each connection gets its own green thread and the accept loop stays free.
256 is far more than a friends-only server needs; the threads are almost always
parked on a socket, not burning CPU. After this one change, the full sequential
relay passed.

**The generalizable lesson:** with this `Io` model, `io.async` is not a promise
of concurrency — if the pool is exhausted it *degrades to synchronous inline
execution*. On constrained core counts you must size the pool yourself, or a
single long-lived task will silently serialize everything behind it.

(A second, dumber time-sink from the same afternoon: the test harness used
`pkill -f signal_server`, whose pattern matched the shell command *running the
pkill*, so it kept killing its own shell. Kill by PID, or match the exact process
name with `pkill -x`.)

---

## 8. Running and testing it

Run it (PORT optional, defaults to 7777):

```sh
PORT=7777 zig run tools/signal_server.zig
```

There's no browser in the dev sandbox, so we test with a tiny raw-WebSocket
client in Python — it does the handshake by hand and masks its frames (client
frames must be masked). The end-to-end scenario: A joins, B joins and sees A, A
is notified, B signals A with a blob containing spaces and newlines, A receives
it verbatim, A disconnects, B is told A left. All assertions pass:

```
A welcome: WELCOME 1
B welcome: WELCOME 2 1
A sees join: JOINED 2
A gets relay: 'FROM 2 sdp-offer with spaces\nand newlines'
B sees leave: LEFT 1

SIGNALING RELAY: PASS ✓
```

Verification bar for the server: `zig fmt --check` clean, lint 0 (tools are
linted too), compiles as a native binary, and the relay test passes.

---

## 9. What's next

L0 is a native binary that shuttles opaque blobs between browsers. The next
three layers are all **in the browser**, driven from wasm.

### 9.1 L1 — the Zig client bridge (`src/bridge.zig`)

This is the meaty one. We need to drive two browser objects from Zig/wasm:

- the browser **`WebSocket`** (to talk to L0), and
- **`RTCPeerConnection`** + **`RTCDataChannel`** (the actual P2P link).

The hard constraint is the same one zimr's existing `fetch` bridge already
solves: **you cannot let JavaScript call back *into* wasm re-entrantly** while
wasm is mid-frame. So we don't use callbacks. We use the **handle + poll-per-
frame** pattern that `web.zig`'s `fetch` already uses (`js_fetch_start` /
`js_fetch_poll` / `js_fetch_data_ptr` / …):

1. Zig asks JS to start something (open a socket, create a peer connection) and
   gets back an integer **handle**.
2. JS event handlers (`onmessage`, `onicecandidate`, `ondatachannel`, …) do
   nothing but **push inbound events into a queue** keyed by that handle.
3. Once per frame, Zig **drains** the queue for each handle it owns. No
   re-entrancy: JS never calls into wasm; wasm pulls when it's ready.

The bridge will expose, roughly:

- `wsOpen(url) -> handle`, `wsSend(handle, bytes)`, `wsPoll(handle) -> ?message`,
  `wsClose(handle)`.
- `rtcCreate() -> handle`, `rtcCreateOffer(handle)`, `rtcSetRemote(handle, sdp)`,
  `rtcAddIce(handle, cand)`, `rtcSend(handle, channel, bytes)`,
  `rtcPoll(handle) -> ?event` (event = got-offer/answer/ice, channel-open,
  data-received, …).

STUN uses a free public server (e.g. Google's) so ICE can discover public
addresses; no TURN for v1 (we accept that some strict-NAT pairs won't connect
yet). Two data channels: one **unreliable/unordered** for high-rate state like
cursor position (drop is fine, latest wins), one **reliable/ordered** for events
like clicks.

The tricky bit to get right is the **offer/answer/ICE dance** expressed as
poll-driven state, mediated through L0's `SIGNAL`/`FROM`. Roughly: host creates
an offer → `SIGNAL`s it to the joiner via L0 → joiner sets it as remote, makes an
answer → `SIGNAL`s back → both sides feed ICE candidates to each other as they
trickle in → data channel opens.

### 9.2 L2 — the session layer (`src/net.zig`)

A flat, friendly Zig API on top of L1 that a game actually calls:

- `net.hostRoom() -> Room` — generates a room name, connects to L0, waits for
  joiners.
- `net.joinRoom(name) -> Room` — connects to L0, joins, dials the host.
- `room.broadcast(payload)` / `room.sendTo(peer, payload)` — over the data
  channels.
- `room.poll() -> ?Event` — per-frame inbound (peer joined/left, message
  received), same non-re-entrant pattern.

Room names are generated in pure Zig: an adjective + noun + number word list and
a small PRNG, producing `brave-otter-42`-style names that are easy to say out
loud. Payloads ride the comptime **`z.serialize`** protobuf-style serializer we
already built — a game struct in, bytes out, bytes in, struct out.

### 9.3 L3 — the 2D mouse-sharing demo

The first thing to actually see: a 2D world where every connected player's mouse
cursor shows up live, with a little ripple on each click. Host presses "host,"
gets a room name on screen; friend types it to join. Each peer **broadcasts its
own cursor** (unreliable channel) and **clicks** (reliable channel), and renders
everyone else's colored cursor + click ripples + a peer count. No authority, no
server-side state — each peer just paints what the others send. It's the smallest
thing that proves the whole stack end to end.

### 9.4 Beyond

Once the mouse demo works, the same machinery generalizes to real games. Natural
follow-ons: interpolation/prediction for smooth movement over jittery links, a
simple lockstep or state-sync option, and eventually **big-world chunk
streaming** (a chunk is a struct → `z.serialize` → bytes → send/load on demand),
which is the other direction we want to take zimr. But all of that sits on the
four layers above, and the first of those four — the switchboard — is done.

---

*Part 1 of a series. Code: `tools/signal_server.zig`. Next up: L1, the client
bridge in `src/bridge.zig`.*
