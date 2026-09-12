# zimr P2P — the shared-cursors demo

Your signaling server is already live on Render. This new `render_server` now
serves **three** pages from the same deployment:

- `https://your-app.onrender.com/`     -> **shared cursors** (the real demo)
- `https://your-app.onrender.com/rtc`  -> 2-peer WebRTC diagnostic (detailed log)
- `https://your-app.onrender.com/ws`   -> WebSocket signaling test

All three use the same server over the same `wss://` address.

## 1. Update your deployment
Replace **`render_server`** in your GitHub repo (same filename, commit) -> Render
auto-deploys. The `Dockerfile` is unchanged, so `render_server` is the only file
to re-upload. Wait for **Live** and the log line:
`[signal] listening on 0.0.0.0:10000 (serving page + signaling)`

## 2. The shared-cursors demo — two tabs
1. Open your Render URL. You'll see **"Shared cursors"** with the server URL
   pre-filled. In tab 1, tap **Host a new room**.
   - The panel now shows a room name like **`room: brave-otter-42`**. That's the
     name to share.
2. Open the **same URL in a second tab**. Type that room name into **Room name**
   and tap **Join room**.

Within a second or two, **both tabs should show two cursors** — your own (a white
ring) and the other tab's (a coloured arrow labelled `peer N`), moving in real
time. **Click anywhere** to send a ripple that the other tab sees. That cursor
motion and those ripples are travelling **directly between the two tabs** over
WebRTC; the server only introduced them.

This is the whole goal in miniature: one person hosts, shares a room name, and
anyone who types it is instantly in the same shared space. On two real devices
(your phone + a friend's) it works the same way over the internet.

## 3. If the cursors don't show up
Use the diagnostic page to see where it breaks. Open **`/rtc`** in two tabs and
tap **Connect** in each — it runs the same peer-to-peer handshake but prints a
detailed step-by-step log:

```
sent offer (1234B) ... got answer (1156B) ... rtc state: connecting
channel 0 open ... channel 1 open ... rtc state: connected
```

- If `/rtc` reaches **`rtc state: connected`** with both channels open, the P2P
  layer is fine and anything wrong is in the cursor demo itself — tell me and
  I'll dig in.
- If `/rtc` stalls, the last log line says which step didn't finish (offer sent
  but no answer? stuck on `connecting`? a `remote-error:` / `offer-error:` line
  with the browser's own message?). Copy both tabs' logs and send them over —
  that points straight at the fix.
- `/ws` is the lowest level: two tabs, Connect, and you should see `WELCOME` /
  `JOINED` — confirms the signaling server itself is healthy.

## What's under the hood now
The cursor demo is built on a new session layer (`net.zig`) that handles the
whole thing for you: it joins a room, opens a direct connection to **every** peer
(a full mesh, so more than two can join), and gives the game a simple stream of
"peer joined / peer left / message" events. The cursor demo is ~380 lines on top
of that; adding more real-time games from here is mostly gameplay, not plumbing.

The session layer is hardened well beyond the demo's needs: a dropped connection
falls back to relaying through the server, a dropped signaling socket reconnects
on its own, rooms are capped at 8 players (a 9th is turned away rather than
silently breaking the mesh), there's a built-in host election if a game wants one
authority, and structured messages can be sent as typed `z.serialize`'d structs.
All of that is covered by an automated headless test suite (17 cases).

> Free-tier note: Render sleeps after ~15 min idle; the first Connect after that
> waits ~30-60s while it wakes. New in this build: if the connection drops
> mid-session (the server sleeps during a lull, or a phone switches networks),
> the demo now reconnects on its own and rebuilds the session — no refresh
> needed. Peers briefly disappear and come back a moment later.
>
> Networks: connections use Google's public STUN to go peer-to-peer directly.
> New in this build: if two peers can't reach each other directly (strict NATs,
> some corporate/mobile firewalls), their traffic now automatically falls back to
> relaying through this same server instead of failing — so those sessions still
> work, with no TURN server and nothing to configure. Direct connections are
> still preferred; the relay only kicks in when the direct one gives up.
