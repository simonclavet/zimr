//! lint:alias net
//! ============================================================================
//! zimr networking -- peer-to-peer multiplayer for the browser, all in Zig
//! ============================================================================
//!
//! This is the front door (`z.net`) to zimr's multiplayer stack. If you're
//! writing a networked game this file is the whole API you need; the rest of
//! this comment explains what's underneath so it isn't a black box.
//!
//!
//! -- WHAT IT'S FOR -----------------------------------------------------------
//!
//! The goal is small, friendly multiplayer: you're making a game and you want a
//! few friends to jump in. One player hosts and gets a short, shareable room
//! name ("brave-otter-42"); anyone who types that name is instantly in the same
//! shared world. That's it -- no accounts, no lobbies, no matchmaking service.
//!
//! It is genuinely PEER-TO-PEER: once players are connected their game data
//! travels directly browser-to-browser. A server is used only to introduce
//! peers to each other; it never sees or relays the game itself (except as a
//! fallback for players who can't connect directly -- see "staying connected").
//! And like the rest of zimr both ends are pure Zig: there is no hand-written
//! JavaScript anywhere, and the little introduction server is a native Zig
//! program too.
//!
//!
//! -- THE BIG PICTURE: FOUR LAYERS --------------------------------------------
//!
//!   Browser A  (your game)                     Browser B  (a friend)
//!   +--------------------------+               +--------------------------+
//!   |  game  (net_cursors...)  |  <- L3        |  game                    |
//!   |  net.zig  (this file)    |  <- L2        |  net.zig                 |
//!   |  net_core.zig  (mesh)    |               |  net_core.zig            |
//!   |  web.zig  ws + rtc       |  <- L1        |  web.zig  ws + rtc       |
//!   +------------+-------------+               +-------------+------------+
//!                |                                           |
//!                |    WebRTC data channel                    |
//!                |    <=========  direct P2P  =========>     |   << game data
//!                |                                           |
//!                |    WebSocket        +------------------+  |
//!                +-------------------->|  L0  signaling   |<-+   << handshake
//!                                      |  render_server   |         only
//!                                      +------------------+
//!
//!   L0  Signaling server -- a tiny WebSocket server (tools/signal_server.zig,
//!       deployed as tools/render_server.zig). Groups connections by room name
//!       and relays the connection handshake between peers. Holds no game state.
//!
//!   L1  The client bridge -- web.zig's `ws` and `rtc`: thin, poll-based Zig
//!       wrappers over the browser's WebSocket and RTCPeerConnection. The JS that
//!       touches those APIs is generated from bridge.zig by zimr's own Zig->JS
//!       transpiler; its event handlers only push into a queue the wasm drains
//!       each frame, so nothing ever calls back into wasm.
//!
//!   L2  The session layer -- net_core.zig (the mesh brain) + this file. Turns
//!       "a socket and some peer connections" into "join a room, get events,
//!       send messages". Home of the full mesh, the handshake choreography, and
//!       all the reliability logic.
//!
//!   L3  Your game -- calls the API below. net_cursors is the reference: every
//!       player's mouse cursor on a shared canvas, with click ripples.
//!
//!
//! -- THE TECHNOLOGY ----------------------------------------------------------
//!
//! Browser peer-to-peer means WebRTC DataChannels: a direct, low-latency link
//! between two browsers. Each channel can be reliable+ordered (like TCP) or
//! unreliable+unordered (like UDP), which is exactly the choice a game wants.
//!
//! Two peers can't just find each other, though. Before a direct link exists
//! they must swap a little connection info -- an SDP "offer"/"answer" describing
//! the session, and a stream of ICE "candidates" (possible network routes). That
//! swap is what the L0 server relays. Discovering your own public route through a
//! NAT uses a STUN server (we use Google's free public one). A TURN relay (for
//! networks so locked down that even STUN fails) is replaced here by our own
//! server-relay fallback (below), so there is no third-party TURN.
//!
//!
//! -- HOW A CONNECTION HAPPENS -------------------------------------------------
//!
//! Say A is already in a room and B joins:
//!
//!   1. A called connect(url, "brave-otter-42"): opened a WebSocket and sent
//!      `JOIN brave-otter-42`. The server replied `WELCOME 1` (A is peer 1,
//!      nobody else here). A waits.
//!   2. B calls connect(url, "brave-otter-42"): sends `JOIN`. The server gives B
//!      id 2, replies `WELCOME 2 1` (you're 2, peer 1 is already here), and tells
//!      A `JOINED 2`.
//!   3. They negotiate a direct connection, choreographed to avoid "glare" (both
//!      offering at once): the LOWER id offers to the HIGHER. Ids only increase,
//!      so the rule is just "offer to whoever joins after you, answer whoever was
//!      already here." A (1) offers to B (2):
//!        - A makes an SDP offer, sends `SIGNAL 2 offer <sdp>`; the server hands
//!          it to B as `FROM 1 offer <sdp>`.
//!        - B answers: `SIGNAL 1 answer <sdp>` -> A gets `FROM 2 answer <sdp>`.
//!        - Both dribble ICE candidates the same way (`SIGNAL ... ice ...`).
//!   4. Once enough candidates are exchanged the DataChannels open and A<->B is a
//!      direct link. The server is now out of the loop for those two.
//!   5. A third peer joining repeats this against everyone already present -- that
//!      is the full mesh: everyone holds a direct connection to everyone else.
//!
//! You never write any of the handshake yourself. Draining poll() each frame,
//! you simply get `peer_joined`, then `channel_open`, then `message`s.
//!
//!
//! -- THE SIGNALING PROTOCOL ---------------------------------------------------
//!
//! Every message is one WebSocket text frame, "VERB args...", the tail left
//! opaque (SDP has spaces and newlines). Client -> server:
//!     JOIN   <room>                 join / create a room
//!     SIGNAL <to-id> <raw...>       relay handshake data to one peer
//!     RELAY  <to-id> <ch> <b64...>  relay GAME data to one peer (fallback)
//! Server -> client:
//!     WELCOME <your-id> [ids...]    you're in; here's who else is here
//!     JOINED  <id>                  a newcomer arrived
//!     LEFT    <id>                  someone left
//!     FROM    <from-id> <raw...>    a SIGNAL relayed to you
//!     RELAYED <from-id> <ch> <b64>  a RELAY relayed to you
//!     FULL                          the room is at capacity; you were turned away
//! The server assigns ids from an increasing counter, so a WELCOME's existing ids
//! are always lower than yours and a JOINED id is always higher -- which is what
//! makes the "lower offers to higher" rule work with no coordination.
//!
//!
//! -- THE TWO CHANNELS ---------------------------------------------------------
//!
//! Every peer connection opens two DataChannels; you pick which to send on:
//!     channel 0   unreliable + unordered. For fire-and-forget state that's
//!                 superseded constantly, like a cursor position: dropping one is
//!                 fine, the next one replaces it.
//!     channel 1   reliable + ordered. For events you can't lose, like a click or
//!                 a game action.
//!
//!
//! -- STAYING CONNECTED (the hard part) ----------------------------------------
//!
//! Real networks are messy, so the session layer handles the ugly cases so your
//! game doesn't have to:
//!
//!   * Connection state -- each peer's WebRTC connection reports its state
//!     (connecting -> connected, or disconnected / failed). You get these as
//!     `peer_state` events; the session acts on the terminal ones itself.
//!
//!   * Relay fallback -- if a direct connection can't be established (strict or
//!     symmetric NATs, some corporate/mobile firewalls -- the case a TURN server
//!     normally handles), that peer is NOT dropped. Its traffic transparently
//!     falls back to relaying through the signaling server (base64-framed so
//!     binary survives the text channel) and you're told `peer_state = relayed`.
//!     Same broadcast()/sendTo() API; it just keeps working. Direct is always
//!     preferred; relay only starts when the direct path gives up.
//!
//!   * Reconnection -- if the signaling socket itself drops (the free server went
//!     to sleep during a lull, a phone changed networks), the session reopens it
//!     on its own and rebuilds the mesh; you see the peers leave and rejoin.
//!     (Caveat: you come back with a NEW id, so to others you're a new peer --
//!     stable identity across reconnects is a future addition.)
//!
//!   * Room cap -- a room holds at most `max_peers` (8) players, matching the
//!     mesh size. A 9th joiner is turned away with `room_full` rather than
//!     silently breaking everyone's mesh.
//!
//!   * Host election -- the lowest-id (longest-present) peer is designated the
//!     "host", recomputed as peers come and go, so everyone agrees on one
//!     authority with no vote. Purely optional: check isHost() / hostId() / the
//!     `host_changed` event if your game wants one authoritative peer; ignore it
//!     entirely (like the cursor demo) if every peer owns its own state.
//!
//!
//! -- THE API (this file) ------------------------------------------------------
//!
//! Embed a `Session` in your app state (all fixed buffers -- no allocator), then:
//!
//!     session.connect(url, room);        // open + join (auto-reconnects)
//!     session.disconnect();              // leave + stop
//!
//!     // each frame, drain events:
//!     while (session.poll(&buf)) |ev| switch (ev) {
//!         .joined_as    => |id|  {},  // the server gave US this id
//!         .peer_joined  => |id|  {},  // negotiating with a new peer
//!         .channel_open => |ref| {},  // ref.peer / ref.channel now usable
//!         .peer_state   => |st|  {},  // st.peer connecting/connected/relayed/...
//!         .message      => |m|   {},  // m.peer, m.channel, m.bytes (until next poll)
//!         .peer_left    => |id|  {},  // gone (left, failed, or during reconnect)
//!         .host_changed => |id|  {},  // the host is now this peer
//!         .room_full    =>       {},  // rejected; try another room
//!     };
//!
//!     session.broadcast(channel, bytes);        // to everyone
//!     session.sendTo(peer_id, channel, bytes);  // to one peer
//!
//!     session.myId();  session.isReady();  session.isActive();
//!     session.isHost();  session.hostId();
//!
//! `net.generateRoomName(seed, buf)` builds the shareable "brave-otter-42" name.
//!
//!
//! -- TYPED MESSAGES -----------------------------------------------------------
//!
//! broadcast/sendTo move raw bytes. For structured game messages `net.typed`
//! (net_typed.zig) frames a message as [1-byte tag][z.serialize'd struct], so you
//! send `Cursor{ .x=.., .y=.. }` instead of hand-packing bytes and can carry
//! several message kinds on one connection. See net_typed.zig for the API.
//!
//!
//! -- WHERE THE CODE LIVES -----------------------------------------------------
//!
//!   net.zig        this file -- the public API, bound to the browser transports
//!   net_core.zig   the whole mesh brain, TRANSPORT-AGNOSTIC and std-only: the
//!                  peer table, handshake choreography, relay, reconnect,
//!                  room-full handling, host election, room-name generator. It
//!                  takes the ws/rtc transports as comptime parameters, so this
//!                  file binds it to the real browser ones and the test binds it
//!                  to an in-process fake.
//!   net_typed.zig  the typed-message helper (tag + z.serialize)
//!   web.zig        ws + rtc -- the browser transport wrappers (L1)
//!   bridge.zig     the host functions those wrappers call, compiled to JS
//!   tools/signal_server.zig   the signaling server (L0), teaching version
//!   tools/render_server.zig   the deploy build (server + demo pages baked in)
//!
//!
//! -- HOW IT'S TESTED ----------------------------------------------------------
//!
//! Because net_core.zig is transport-agnostic and std-only, the ENTIRE session
//! brain is tested with no browser: net_mesh_test.zig binds it to an in-process
//! fake of the signaling server + WebRTC, spins up several sessions, and asserts
//! the real behavior -- peers connect, a mesh forms, messages flow both ways,
//! peers leave, connections fail over to relay, dropped sockets reconnect, typed
//! messages round-trip, full rooms reject, the host migrates. Run it with
//! `zig test net_mesh_test.zig`. What that CAN'T cover is real-browser WebRTC
//! (actual NAT traversal, real data channels) and rendering -- those need a real
//! two-tab / two-device test.
//!
//!
//! -- LIMITATIONS / NOT DONE ---------------------------------------------------
//!
//!   * Friends-scale only: a full mesh is N-1 connections per peer, so `max_peers`
//!     is small (8). Not built for hundreds of players.
//!   * A reconnecting peer returns with a new id (no stable-identity rejoin token).
//!   * No per-connection rate limiting on the public server yet.
//!   * STUN only for direct connections (the relay fallback covers the rest).
//! ============================================================================

const web = @import("web.zig");
const net_core = @import("net_core.zig");

/// Friends-only scale. One connection per peer; this caps the mesh size.
pub const max_peers = net_core.max_peers;

/// The transport-agnostic session generator. Games don't need this — use
/// `Session` — but it's exposed so a custom transport (e.g. the mock used by
/// the mesh test) can bind the same logic to something other than the browser.
pub const Net = net_core.Net;

/// A multiplayer session over the real browser transports. Embed one in your
/// app State (it holds fixed buffers, so no allocator needed), call
/// `connect(url, room)`, then drive `poll(&buf)` each frame.
pub const Session = net_core.Net(web.ws, web.rtc).Session;

/// What `poll` hands back: joined_as / peer_joined / peer_state / channel_open /
/// message / peer_left. A `message`'s bytes are valid until the next `poll`.
pub const Event = net_core.Event;
pub const ChannelRef = net_core.ChannelRef;
pub const Message = net_core.Message;
pub const PeerState = net_core.PeerState;
pub const ConnState = net_core.ConnState;

/// Write a human-shareable room name like "brave-otter-42" into `out` (needs
/// ~24 bytes) and return the slice. Deterministic in `seed`; pass a timestamp
/// or frame count for a fresh room.
pub const generateRoomName = net_core.generateRoomName;

/// Typed-message helpers (tag + z.serialize) for structured game messages.
pub const typed = @import("net_typed.zig");
