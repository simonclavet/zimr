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

/// Friends-only scale. One connection per peer; this caps the mesh size.
pub const max_peers = 8;

const sdp_cap = 16384; // SDP offers/answers run a few KB; ICE candidates are tiny
const cq_cap = max_peers * 2 + 8; // control events queued between poll() calls
const reconnect_cooldown = 30; // poll-calls between reconnect attempts (~0.5s @ 60fps)

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

pub const ChannelRef = struct { peer: u32, channel: u8 };
pub const Message = struct { peer: u32, channel: u8, bytes: []const u8 };
pub const PeerState = struct { peer: u32, state: ConnState };

/// The browser's RTCPeerConnection.connectionState, plus our own states, boiled
/// down. `failed` is where the direct connection gave up - the session then
/// falls back to relaying this peer through the server and reports `relayed`.
/// `closed` is terminal (the peer is dropped). `disconnected` is often transient
/// (it can recover to `connected`), so we surface it but keep the peer.
pub const ConnState = enum(u8) { connecting, connected, disconnected, failed, closed, relayed, other };

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
            pub fn sendTo(self: *Session, peer_id: u32, channel: u8, bytes: []const u8) void {
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
                        if (std.mem.startsWith(u8, m, "RELAYED ")) {
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
                                    // Direct connection gave up. Rather than drop
                                    // the peer, fall back to relaying it through
                                    // the signaling server. Close the dead pc and
                                    // report `relayed` so the game knows.
                                    rtc.close(peer.pc);
                                    peer.pc = 0;
                                    peer.relay = true;
                                    self.control.push(.{
                                        .kind = .peer_state,
                                        .peer = peer.id,
                                        .channel = @backingInt(ConnState.relayed),
                                    });
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
                p.* = .{ .id = id, .pc = rtc.create(), .chan_open = .{ false, false }, .active = true, .relay = false };
                if (offerer) {
                    rtc.createOffer(p.pc);
                }
                self.control.push(.{ .kind = .peer_joined, .peer = id, .channel = 0 });
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
                if (std.mem.startsWith(u8, msg, "FULL")) {
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
                } else if (std.mem.startsWith(u8, msg, "WELCOME ")) {
                    // WELCOME <my_id> [existing ids...]. Everyone already here joined
                    // before us (lower ids), so by convention they offer to us.
                    var rest: []const u8 = msg[8..];
                    const first: Split = splitFirst(rest);
                    self.my_id = std.fmt.parseInt(u32, first.tok, 10) catch 0;
                    self.control.push(.{ .kind = .joined_as, .peer = self.my_id, .channel = 0 });
                    rest = first.rest;
                    while (rest.len > 0) {
                        const s: Split = splitFirst(rest);
                        const id: u32 = std.fmt.parseInt(u32, s.tok, 10) catch 0;
                        if (id != 0) {
                            _ = self.addPeer(id, self.my_id < id);
                        }
                        rest = s.rest;
                    }
                } else if (std.mem.startsWith(u8, msg, "JOINED ")) {
                    // A newcomer (higher id) - we offer to them.
                    const id: u32 = std.fmt.parseInt(u32, splitFirst(msg[7..]).tok, 10) catch 0;
                    if (id != 0) {
                        _ = self.addPeer(id, self.my_id < id);
                    }
                } else if (std.mem.startsWith(u8, msg, "LEFT ")) {
                    const id: u32 = std.fmt.parseInt(u32, splitFirst(msg[5..]).tok, 10) catch 0;
                    self.removePeer(id);
                } else if (std.mem.startsWith(u8, msg, "FROM ")) {
                    // FROM <from> <kind> <data> - the peer's half of the handshake.
                    const a: Split = splitFirst(msg[5..]); // from id
                    const from: u32 = std.fmt.parseInt(u32, a.tok, 10) catch 0;
                    const b: Split = splitFirst(a.rest); // kind
                    const kind: []const u8 = b.tok;
                    const data: []const u8 = b.rest;
                    // An offer may arrive from a peer we haven't added yet (ordering);
                    // adopt them as the answerer so the connection can proceed.
                    var peer: ?*Peer = self.findPeer(from);
                    if (peer == null and std.mem.eql(u8, kind, "offer")) {
                        peer = self.addPeer(from, false);
                    }
                    if (peer) |p| {
                        if (std.mem.eql(u8, kind, "offer")) {
                            rtc.setRemote(p.pc, true, data);
                        } else if (std.mem.eql(u8, kind, "answer")) {
                            rtc.setRemote(p.pc, false, data);
                        } else if (std.mem.eql(u8, kind, "ice")) {
                            rtc.addIce(p.pc, data);
                        }
                    }
                }
            }

            fn signal(self: *Session, peer_id: u32, kind: []const u8, data: []const u8) void {
                const msg: []const u8 = bufPrint(&self.send_buf, "SIGNAL {d} {s} {s}", .{ peer_id, kind, data }) catch {
                    return; // over buffer; the SDP was implausibly large
                };
                ws.send(self.sock, msg);
            }

            // Relay a peer's game data through the signaling server - the fallback
            // when the direct connection failed. The payload is base64'd so binary
            // game bytes survive the text-based signaling channel intact.
            fn relaySend(self: *Session, peer_id: u32, channel: u8, bytes: []const u8) void {
                const prefix: []const u8 = bufPrint(
                    &self.send_buf,
                    "RELAY {d} {d} ",
                    .{ peer_id, channel },
                ) catch return;
                const need: usize = ((bytes.len + 2) / 3) * 4; // base64 (padded) length
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
                const from: u32 = std.fmt.parseInt(u32, a.tok, 10) catch return null;
                const b: Split = splitFirst(a.rest); // channel
                const ch_num: u32 = std.fmt.parseInt(u32, b.tok, 10) catch return null;
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

const Split = struct { tok: []const u8, rest: []const u8 };

// Split "tok rest" on the first space. rest is "" when there's no space.
fn splitFirst(s: []const u8) Split {
    const sp: usize = std.mem.indexOfScalar(u8, s, ' ') orelse return .{ .tok = s, .rest = "" };
    return .{ .tok = s[0..sp], .rest = s[sp + 1 ..] };
}

// Map the browser's connectionState string (or one of our "*-error" markers) to
// a ConnState. Negotiation errors count as `failed` so the peer gets cleaned up.
fn parseConnState(s: []const u8) ConnState {
    if (std.mem.startsWith(u8, s, "remote-error") or std.mem.startsWith(u8, s, "offer-error")) {
        return .failed;
    }
    if (std.mem.eql(u8, s, "connecting")) {
        return .connecting;
    }
    if (std.mem.eql(u8, s, "connected")) {
        return .connected;
    }
    if (std.mem.eql(u8, s, "disconnected")) {
        return .disconnected;
    }
    if (std.mem.eql(u8, s, "failed")) {
        return .failed;
    }
    if (std.mem.eql(u8, s, "closed")) {
        return .closed;
    }
    return .other;
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
