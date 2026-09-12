# P2P multiplayer for zimr — PLAN

> Goal (Simon): easy local games you invite friends to. Host generates a
> procedural room name, shares it; a friend types it and joins immediately.
> First test: a 2D world showing every player's mouse position + clicks.
> Constraint: the networking BRIDGE is all Zig (wasm-side driving JS, or
> transpiled). A lightweight server for DISCOVERY only — the game is P2P.
> Philosophy: no useless abstraction, flat files, programmer-centric.

## The technology
Browser peer-to-peer means **WebRTC DataChannels** — direct peer↔peer, low
latency, and each channel can be **reliable/ordered** (like TCP, for clicks) or
**unreliable/unordered** (like UDP, for high-frequency mouse position). WebRTC
needs two supporting pieces:
- **Signaling** — before two peers can connect directly they must swap a little
  connection info (SDP offer/answer + ICE candidates). That's what the
  lightweight discovery server relays. Once connected, the server is out of the
  data path.
- **STUN** — for NAT traversal (peers discovering how the internet sees them).
  Free public STUN servers exist (e.g. Google's). TURN (relay fallback for
  strict NATs) is a later add if some peers can't connect directly.

Colyseus (the reference) is the opposite model — a central Node server holds
authoritative state over WebSocket. Not what we want. But its **client API
ergonomics are worth stealing**: `joinOrCreate(room)` → a room object with
`send(type, payload)`, `onMessage(type, cb)`, and a separate `sendUnreliable`.
And where Colyseus has its own schema serializer, **we already have `z.serialize`**
— peer messages are just serialized structs.

## Architecture — four layers
**L0 · Discovery/signaling server (tiny, the only non-P2P piece).**
A small WebSocket server: connections grouped by room name; when a peer joins it
learns who's already there; it relays offer/answer/ICE between peers in the same
room. That's it — no game state, no game logic. ~150 lines. (Language = an open
choice, see below.)

**L1 · The Zig networking bridge (client, wasm-side, in bridge.zig).**
Zig driving the browser's WebSocket + RTCPeerConnection + RTCDataChannel through
the same Value-interop the fetch/persistence/audio bridges use. Follows the
fetch **handle + poll** pattern: JS event handlers buffer inbound signaling and
peer messages into a queue; the Zig side **drains the queue once per frame** (no
re-entrant calls into wasm). Raw extern surface kept minimal and flat.

**L2 · The room/session layer (Zig, a new flat `src/net.zig`).**
The friendly API the game uses:
- `net.hostRoom()` → generates + returns a room name, connects to signaling.
- `net.joinRoom(name)` → connects to signaling, dials the existing peers.
- `net.poll()` each frame → drains events: `peer_joined`, `peer_left`,
  `message{peer, channel, bytes}`.
- `net.broadcast(channel, bytes)` / `net.sendTo(peer, channel, bytes)`, with a
  reliable and an unreliable channel.
- Procedural room names: adjective-noun-number (e.g. `brave-otter-42`), a small
  word list + PRNG, pure Zig — easy to say and type.
- Payloads go through `z.serialize`.

**L3 · The mouse-sharing test (a 2D example).**
UI: "Host" (shows the shareable room name) or "Join" (type the name). Once
connected: broadcast my cursor (unreliable, every frame) + click events
(reliable); render every peer's colored cursor + a click ripple; show the peer
count. Proves the whole stack end to end.

## The flow
1. A clicks **Host** → name `brave-otter-42` generated → WS to signaling,
   registered in that room → name shown to share.
2. B types `brave-otter-42`, **Join** → WS to signaling → server replies "peer A
   is here" → B creates an RTCPeerConnection, sends an offer (relayed via
   signaling), A answers, ICE candidates trickle through → DataChannel opens →
   A↔B now direct.
3. More friends join → each new peer dials the existing ones.
4. Everyone broadcasts cursor + clicks over their DataChannels → everyone sees
   everyone.

## State model (for the mouse test)
No authority. Each peer OWNS its own state (cursor, clicks, colour) and
broadcasts it; each peer renders "my state + last-known state of every other
peer." Simplest correct P2P model for cursors — no prediction/rollback needed.
Authoritative or shared-state models can come later for actual gameplay.

## Open choices (ask one at a time)
1. **Topology** — full mesh (every peer↔every peer; simplest; best for a few
   friends) vs star/host-relay (one peer relays; scales further; but a host).
2. **Signaling server language** — Zig native (matches the all-Zig ethos, ~200
   lines, a small binary Simon owns) vs a minimal JS/Bun server (~50 lines,
   fastest to stand up). Either way it's discovery-only.
3. **Bridge event delivery** — poll-per-frame queue (matches fetch, no
   re-entrancy) vs JS→wasm callbacks. (Lean poll.)
4. **Channels** — expose reliable + unreliable explicitly (mouse=unreliable,
   clicks=reliable) vs one channel. (Lean both.)
5. **Room-name style** — adjective-noun-number vs short code (e.g. `4-7-2-9`) vs
   both.

---
## STATUS UPDATE (zimr904): L1 WebSocket half DONE
- **WebSocket client bridge is complete + verified.** Game-facing `z.web.ws` API in src/web.zig (open/state/send/poll/close, `State` enum, `Handle`) mirrors the `fetch` handle+poll shape. Host functions in src/bridge.zig (`jsWsOpen/State/Send/Poll/Close` in ZimrWgpu, registered in the "dom" namespace) manage each socket as a `{ws, q, st}` holder in the object table; onopen/onmessage/onclose/onerror are PURE JS closures (built via `new Function`) that only enqueue + flip state → no wasm re-entrancy, wasm drains by polling. Sends as TEXT frames (L0 server speaks text). Receives text→bytes / binary→Uint8Array.
- **Verified:** lint 0, fmt clean, runtime builds, `net-ws-smoke-standalone` rc=0, wasm genuinely imports js_ws_* (all 5), `verify_imports` PASS (all 77 imports provided), focused smoke PASS (census balanced). Browser behavior itself still needs eyeballs (open two tabs w/ signal_server running).
- **Example:** `examples/net_ws_smoke/` — connects to ws://localhost:7777, JOINs "zimr-demo", shows live WELCOME/JOINED/LEFT/FROM + a "send SIGNAL to peer 1" button. Testable in two browser tabs.
- **NEXT (L1 WebRTC half):** add RTCPeerConnection + RTCDataChannel host fns to bridge.zig (same handle-table + pure-JS-closure + poll pattern) + `z.web.rtc` in web.zig. Design: rtcCreate/createOffer/setRemote/addIce/send/poll(→event). STUN via Google public server, no TURN v1, two channels (unreliable cursor + reliable clicks). The offer/answer/ICE dance is poll-driven, mediated through L0's SIGNAL/FROM. THEN L2 src/net.zig session layer, THEN L3 mouse demo.
