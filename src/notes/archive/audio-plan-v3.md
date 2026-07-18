# audio plan (v3): zero → sound.zig (WAV + OGG, browser-decoded)

> **Status.** Replaces `audio-plan-v2.md`.  Same destination
> (single-file `sound.zig` built on Web Audio, full raylib audio
> public surface).  v3 adds OGG Vorbis support via the browser's
> native `AudioContext.decodeAudioData` API — no pure-Zig
> Vorbis decoder needed, no external dependency, browser does
> the work.
>
> 30 steps across 7 phases (up from v2's 28 by +2 for OGG
> integration into Sound and Music paths).  Each step = one
> shippable commit: code → inline tests → optional example →
> cheatsheet bump → changelog line → `zig build test &&
> zig build smoke-test`.

## Why OGG, and why now

The user is right.  WAV-only is wrong for music tracks.

A 5-minute stereo 44.1 kHz 16-bit WAV is **52 MB** on disk and
**110 MB** after f32 expansion in memory.  Same content as an
OGG Vorbis at 128 kbps: **5 MB** on disk.  An order of magnitude.

For a game shipping multiple music tracks + ambient loops + voice
lines, WAV-only would inflate bundle size from ~30 MB to ~300 MB.
That's a non-starter for web distribution.

The fortunate observation that makes this cheap to add: **every
modern browser already has a Vorbis decoder built in**, exposed
as `AudioContext.decodeAudioData(arrayBuffer) → Promise<AudioBuffer>`.
For runtime playback we don't need to ship anything new at all —
just hand the OGG bytes to the browser.

Compare to the alternative we're not doing:

- raylib uses **stb_vorbis.c** (5584 LOC of dense C) for OGG decoding
- raylib uses **dr_mp3.h** (5412 LOC) for MP3 and **dr_flac.h** (12 698 LOC) for FLAC
- Porting any of these to pure Zig is a multi-week project apiece, with high bug-surface (Vorbis residue decoding has edge cases that take real time to get right)

By deferring decode to the browser, OGG support is ~150 LOC of
JS bridge + ~3 steps of plan.  MP3 and FLAC could ship the same
way in v4 if needed (browser support is universal for both).

## What v2 already had right (carried verbatim)

Everything from v2's lightmix verification holds:

- f32 stereo internal format, 4-type model (Wave/Sound/Music/AudioStream)
- Reader/writer I/O surface with `*std.Io.Reader`/`*std.Io.Writer`
- Filter chain pattern for Wave operations (`waves.filter(&wave, fn)`)
- Composer namespace as zimr-original feature
- `@embedFile` test fixtures, per-op named error sets, Zig 0.15 ArrayList
- Polled `updateAudioStream` covers the common case; AudioWorklet deferred
- Per-Sound active-source pool capped at 16

What changes in v3 is exclusively the **format dispatch model**
and the addition of an OGG backend for Music.

## OGG support strategy

### Format support matrix

|              | WAV                                   | OGG Vorbis                                 |
|--------------|---------------------------------------|--------------------------------------------|
| Decode path  | Pure-Zig `wav.decode` (our codec)     | Browser-native `AudioContext.decodeAudioData` |
| Sync or async | Sync                                  | Async                                      |
| Sound        | ✅ Full support                       | ✅ Full support (with "pending" semantics) |
| Music        | ✅ AudioStream backend                | ✅ HTMLAudioElement backend                |
| Wave (PCM)   | ✅ Full support                       | ❌ Returns error (async incompatibility)   |
| Composer     | ✅ Composer takes Waves               | ❌ (transitively, via Wave-only)           |
| Filter ops   | ✅ Full                                | ❌ (transitively)                          |
| ExportWave   | ✅ Full (writer-based)                | n/a (we don't encode OGG)                  |

### Why OGG can't reach the Wave path

`decodeAudioData(arrayBuffer)` returns a Promise.  In single-
threaded JS we cannot block on a Promise.  raylib's
`LoadWaveFromMemory(".ogg", bytes, len)` returns a `Wave` with
populated PCM data **synchronously**.  We cannot satisfy that
contract without a pure-Zig Vorbis decoder, which we're explicitly
not building.

So: **`waves.loadFromMemory` rejects OGG bytes with `error.OggRequiresAsyncDecode`.**
The error message points users to `sounds.loadFromMemory` or
`music.loadFromMemory`, which are designed for the async case
from the start.

This matches user intuition: "I want to mix and filter audio
samples" → you want PCM (WAV).  "I want to play a 3-minute
music track" → you want compressed (OGG).  The split is natural.

### Sound + OGG: async decode with "pending" state

```zig
// User code
const sound = try z.sounds.loadFromMemory(.ogg, ogg_bytes);

// `sound` is a valid handle but its underlying AudioBuffer
// is NOT YET READY — decodeAudioData is in flight.
// If you call playSound right now, it queues the play
// for when decode finishes (or silently drops if you stop
// it first).

// Best practice: preload at scene setup, query isValid()
// later if you need to play within a specific frame:
if (z.sounds.isValid(sound)) {
    z.sounds.play(sound);
}
```

Internal mechanics: when `loadFromMemory(.ogg, bytes)` is called,
zimr:
1. Allocates a new slot in the SOUNDS handle table (returns valid Sound)
2. Issues `decodeAudioData(bytes)` via JS bridge
3. Stores the Promise's pending state in the slot
4. JS-side completion handler updates the slot's `audio_buffer_id` field

`isValid(sound)` returns true only when the slot has a valid
`audio_buffer_id`.  `playSound` on a not-ready Sound is a
documented no-op that the user can detect via `isValid`.

Decode time: typical OGG sound effects (≤2 sec) decode in
5–20 ms on desktop, 20–80 ms on mobile.  For game SFX preloaded
during scene setup, this is comfortable.  For sounds loaded
mid-frame and immediately played, the user sees ~1 frame of
silence — same fault tolerance as raylib's miniaudio path
which does network/disk I/O on the audio thread.

### Music + OGG: HTMLAudioElement backend

For long compressed audio, we use `<audio>` element +
`MediaElementAudioSourceNode`.  The browser handles streaming,
decoding, and buffering automatically — there's nothing for our
`updateMusicStream` to do.

```javascript
// JS side, simplified
loadOggMusic(oggBytes) {
    const blob = new Blob([oggBytes], { type: 'audio/ogg' });
    const url = URL.createObjectURL(blob);
    const audio = new Audio(url);

    const source = ctx.createMediaElementSource(audio);
    const gain = ctx.createGain();
    const panner = ctx.createStereoPanner();
    source.connect(gain);
    gain.connect(panner);
    panner.connect(masterGain);

    return { audio, source, gain, panner, url, ready: false };
}
```

Mapping raylib's API onto MediaElement:

| raylib                       | MediaElement                          |
|------------------------------|---------------------------------------|
| `PlayMusicStream(m)`         | `audio.play()`                        |
| `PauseMusicStream(m)`        | `audio.pause()`                       |
| `ResumeMusicStream(m)`       | `audio.play()` (idempotent)           |
| `StopMusicStream(m)`         | `audio.pause(); audio.currentTime = 0`|
| `IsMusicStreamPlaying(m)`    | `!audio.paused && !audio.ended`       |
| `UpdateMusicStream(m)`       | **no-op** (browser handles streaming) |
| `SeekMusicStream(m, t)`      | `audio.currentTime = t`               |
| `GetMusicTimePlayed(m)`      | `audio.currentTime`                   |
| `GetMusicTimeLength(m)`      | `audio.duration` (fallback to 0 if NaN) |
| `SetMusicVolume(m, v)`       | `gain.gain.value = v`                 |
| `SetMusicPitch(m, p)`        | `audio.playbackRate = p`              |
| `SetMusicPan(m, p)`          | `panner.pan.value = p`                |
| `looping = true`             | `audio.loop = true`                   |

`UpdateMusicStream` becomes a true no-op for OGG.  Critical: we
keep the same Music API shape, so user code that calls
`UpdateMusicStream` every frame stays correct — it just doesn't
do anything useful in the OGG case.  This is good: no special-casing
in user code.

### Music ctx_type discriminates backends

raylib's `Music` already has a `ctx_type: int` field intended
to discriminate WAV vs OGG vs MP3 etc.  v2 was going to keep
this for "ABI parity" but treat it as unused.  v3 actually
uses it:

```zig
pub const MusicCtxType = enum(c_int) {
    /// AudioStream-backed.  ctx_data points to a wav.Decoder.
    /// updateMusicStream pumps the decoder per frame.
    wav = 0,
    /// HTMLAudioElement-backed.  ctx_data is a media-handle id.
    /// updateMusicStream is a no-op.
    ogg = 1,
};
```

Per-function dispatch: `play(m)`, `pause(m)`, etc. each switch
on `m.ctx_type` and call the right backend.

## Hard rules (unchanged from v2)

1. Style guide rules 1-7 (`src/notes/style-guide.md`).  One arg per line for >1-arg fns, mandatory braces, explicit local types unless already on the line, `@splat` over `**`, no module-level mutable globals in examples.
2. Tests live next to the function.  `src/sound.zig` joins the test discovery list in `src/tests.zig` from Step 9.
3. Layout: one new top-level file — `src/sound.zig` — taking us from 10 → 11 src files (still under the 12-file budget).  WAV codec lives in `src/codecs.zig` `pub const audio = struct` namespace; OGG dispatches to `web.audio` JS bridge with no Zig codec body.
4. `codecs.audio` is invisible to callers.  Public API surface is `sound.waves.loadFromMemory(bytes)`, `sound.sounds.loadFromMemory(format, bytes)`, etc.
5. One example per significant feature, modeled on raylib's counterpart.  Examples appended to `build.zig`'s `examples` array.
6. Smoke-test reality: `webtests/smoke.ts` mocks Web Audio via `makeFakeAudioContext` Proxy.  OGG-mock plays through a fake `decodeAudioData` that resolves immediately with a 1-second 440 Hz sine AudioBuffer.  Audio examples assert (a) no panic, (b) ≥1 AudioContext call.  Plus OGG-specific examples assert (c) Sound becomes valid within 5 simulated frames.
7. CHEATSHEET.md gets a new "Audio" section the same commit as Step 17 ("first sound plays").  Coverage % bumped each step that adds raylib-named public surface.
8. CHANGELOG.md `[Unreleased]` gets one line per step.
9. `/home/claude/snapshots/save.sh <label>` at every milestone — see [§ Snapshot cadence](#snapshot-cadence).
10. After every step: `zig build test --summary all && zig build smoke-test --summary all`.  Don't advance with red.
11. Test fixtures use `@embedFile` — `src/assets/test_sine.wav` (~16 KB) for WAV tests; `src/assets/test_chirp.ogg` (~5 KB) for OGG tests.

**Reference repos.**  `/home/claude/raylib-ref/raylib-master/` (read `raudio.c` end-to-end before Phase 3).
`/home/claude/lightmix/lightmix-main/` (already read; idiom reference for offline Wave ops + Composer).

## Plan summary

| Phase | Steps | Theme | New public fns |
|-------|------:|-------|---------------:|
| 0 | 0 | Read source + design (this file) | 0 |
| 1 | 1-3 | Web Audio JS bridge + AudioContext lifecycle + OGG bridge | 8 |
| 2 | 4-8 | WAV codec in `codecs.audio` (reader/writer) + OGG Format dispatch | 0 (internal) |
| 3 | 9-13 | `sound.zig` foundation: Wave + ops + Composer + Sound types | 18 |
| 4 | 14-17 | Sound playback + OGG async loading + per-sound effects | 8 |
| 5 | 18-21 | AudioStream + master mix + processors | 14 |
| 6 | 22-26 | Music streaming with WAV (AudioStream) + OGG (MediaElement) backends | 12 |
| 7 | 27-30 | Examples (incl. OGG music) + Composer demo + final consolidation | 0 |
| **Total** | **30** | | **~60** |

## What we're NOT building (refined for v3)

- **MP3 / FLAC / QOA / XM / MOD codecs.**  Browsers support MP3 and FLAC natively via `decodeAudioData`, so adding them later is the same ~50 LOC bridge work as OGG.  XM/MOD/QOA browsers don't decode natively — those would need full Zig ports (rejected for v3).  v4 candidates.
- **AudioWorklet for synthesis callbacks.**  raylib has `SetAudioStreamCallback` for procedural audio (sample-thread-driven).  AudioWorklet is the Web Audio equivalent but has worker context overhead.  v3 exposes the function as a no-op stub; polled `updateAudioStream` covers the common case (~50 ms latency).  v4 candidate.
- **Pure-Zig OGG/MP3 decoder.**  Decision: ❌.  Browsers decode for free; porting stb_vorbis (5584 LOC of dense C) provides zero browser-side benefit and ~5 weeks of work.  If the project ever needs to run server-side or in a non-browser context, this becomes a v5 candidate.
- **Generic float precision (`f64`/`f80`/`f128`).**  f32 only.  Same as v2.
- **Build-time WAV generation.**  Incompatible with wasm-first.  Same as v2.
- **`SetAudioStreamCallback` real implementation.**  Same as v2.
- **`ExportWaveAsCode`.**  Generates a `.h` file with the wave embedded as a C array — useful for raylib's CLI workflow, meaningless on the web.  Stub returning `false`.
- **OGG encoding.**  We never write OGG, only read.  Encoding requires Vorbis encoder (~5 KLOC).  Use ffmpeg offline for OGG production.

## Phase 0 — Design (v3 additions)

### Format dispatch model

```zig
pub const Format = enum {
    wav,
    ogg,

    /// Sync decode — only valid for formats with a Zig codec.
    /// OGG returns error.OggRequiresAsyncDecode.  Use Sound /
    /// Music load paths for OGG instead.
    pub fn decode(
        self: Format,
        gpa: std.mem.Allocator,
        reader: *std.Io.Reader,
    ) anyerror!CanonicalWave {
        return switch (self) {
            .wav => wav.decode(gpa, reader),
            .ogg => error.OggRequiresAsyncDecode,
        };
    }

    pub fn syncDecodable(self: Format) bool {
        return switch (self) {
            .wav => true,
            .ogg => false,
        };
    }

    /// Sniff format from magic bytes.  Returns null if unknown.
    pub fn detect(bytes: []const u8) ?Format {
        if (bytes.len < 4) return null;
        if (std.mem.eql(u8, bytes[0..4], "RIFF")) return .wav;
        if (std.mem.eql(u8, bytes[0..4], "OggS")) return .ogg;
        return null;
    }
};
```

Sound and Music dispatch on Format internally.  Public load
functions accept `format: Format` explicitly OR auto-detect via
`Format.detect`:

```zig
// Both work — explicit format:
const sound1 = try z.sounds.loadFromMemory(.wav, wav_bytes);
const sound2 = try z.sounds.loadFromMemory(.ogg, ogg_bytes);

// Auto-detect:
const sound3 = try z.sounds.loadFromMemoryDetect(any_bytes);
```

`loadFromMemoryDetect` is the friendly default; explicit-format
variants exist for callers who want to enforce a particular
format (security-sensitive code that doesn't want OGG decoded
through the browser's complex Vorbis path, for example).

### Async decode handle (for Sound + OGG)

JS bridge exposes:

```zig
pub extern "audio" fn decodeOggBytes(
    ctx_id: c_uint,
    bytes_ptr: [*]const u8,
    bytes_len: u32,
) c_uint;  // returns decode_handle

pub extern "audio" fn isDecodeReady(
    ctx_id: c_uint,
    decode_handle: c_uint,
) u32;  // 0 = pending, 1 = ready, 2 = error

pub extern "audio" fn takeDecodedBuffer(
    ctx_id: c_uint,
    decode_handle: c_uint,
) c_uint;  // returns buffer_id, releases the decode_handle
```

Lifecycle on the JS side:
```javascript
audio.decodeOggBytes = (ctxId, ptr, len) => {
    const bytes = new Uint8Array(memory.buffer, ptr, len).slice();
    const handleId = audio.next_decode_id++;
    audio.decode_states.set(handleId, { state: 'pending' });

    audio.ctxs.get(ctxId).decodeAudioData(bytes.buffer)
        .then(audioBuffer => {
            const bufId = audio.next_buf_id++;
            audio.buffers.set(bufId, audioBuffer);
            audio.decode_states.set(handleId, { state: 'ready', bufId });
        })
        .catch(err => {
            audio.decode_states.set(handleId, { state: 'error', err });
        });

    return handleId;
};
```

zimr's Sound slot stores the decode_handle until ready, then
swaps to a real buffer_id.  This is the only place asynchrony
leaks into the API, and it's behind `isValid` so users opting
in to "load and immediately play" sees a one-frame delay at
worst.

### Object model (extended)

`Music.ctx_type` is now actively used:

```zig
pub const Music = extern struct {
    stream: AudioStream,         // for WAV path; bogus pointers for OGG
    frame_count: c_uint,         // 0 for OGG until metadata loads
    looping: bool,
    ctx_type: c_int,             // MusicCtxType: 0 = wav, 1 = ogg
    ctx_data: ?*anyopaque,       // wav: *wav.Decoder; ogg: *OggMusicHandle
};
```

`AudioStream` field is unused for OGG Music — present for ABI
parity but never read.  The `ctx_data` field is the discriminator
the dispatch code reads (after switching on `ctx_type`).

## Phase 1 — Web Audio JS bridge

Steps 1-3.  Goal: pure-Zig caller can construct an AudioContext,
upload PCM buffers, play AudioBufferSourceNodes, AND decode OGG
asynchronously, AND construct MediaElement-backed audio.

### Step 1 — AudioContext lifecycle in `src/web.zig`

```zig
pub const audio = struct {
    pub extern "audio" fn createContext() c_uint;
    pub extern "audio" fn closeContext(ctx_id: c_uint) void;
    pub extern "audio" fn resumeContext(ctx_id: c_uint) void;
    pub extern "audio" fn getSampleRate(ctx_id: c_uint) f32;
    pub extern "audio" fn getCurrentTime(ctx_id: c_uint) f64;
    pub extern "audio" fn getMasterVolume(ctx_id: c_uint) f32;
    pub extern "audio" fn setMasterVolume(ctx_id: c_uint, v: f32) void;
};
```

Unchanged from v2.  Master GainNode between context and
destination; everything connects to it.

**Smoke mock**: `makeFakeAudioContext` Proxy answers truthfully
for getters (sampleRate=48000, state=running, currentTime
monotonically increasing).

**Tests:** 5.

### Step 2 — `loadAudioBuffer` (raw PCM upload) + `playBuffer` family

Same as v2.

```zig
pub extern "audio" fn loadAudioBuffer(...) c_uint;
pub extern "audio" fn unloadAudioBuffer(ctx_id, buffer_id) void;
pub extern "audio" fn playBuffer(ctx_id, buffer_id, volume, pitch, pan, looping) c_uint;
pub extern "audio" fn stopBuffer(ctx_id, source_id) void;
pub extern "audio" fn pauseBuffer(...) void;
pub extern "audio" fn resumeBuffer(...) void;
pub extern "audio" fn isBufferPlaying(...) u32;
```

**Tests:** 5.

### Step 3 — OGG decode bridge + MediaElement bridge

**NEW vs v2.**  Three OGG-specific bridge functions:

```zig
// Async OGG decode → AudioBuffer
pub extern "audio" fn decodeOggBytes(ctx_id, bytes_ptr, bytes_len) c_uint; // decode_handle
pub extern "audio" fn isDecodeReady(ctx_id, decode_handle) u32; // 0=pending, 1=ready, 2=error
pub extern "audio" fn takeDecodedBuffer(ctx_id, decode_handle) c_uint; // buffer_id
pub extern "audio" fn cancelDecode(ctx_id, decode_handle) void;
```

Plus MediaElement family for OGG Music:

```zig
// HTMLAudioElement-backed Music (for OGG long-form)
pub extern "audio" fn loadMediaMusic(ctx_id, bytes_ptr, bytes_len) c_uint;
pub extern "audio" fn unloadMediaMusic(ctx_id, media_id) void;
pub extern "audio" fn playMediaMusic(ctx_id, media_id) void;
pub extern "audio" fn pauseMediaMusic(ctx_id, media_id) void;
pub extern "audio" fn stopMediaMusic(ctx_id, media_id) void;
pub extern "audio" fn isMediaMusicPlaying(ctx_id, media_id) u32;
pub extern "audio" fn seekMediaMusic(ctx_id, media_id, t_seconds: f64) void;
pub extern "audio" fn getMediaMusicTime(ctx_id, media_id) f64;
pub extern "audio" fn getMediaMusicDuration(ctx_id, media_id) f64;
pub extern "audio" fn setMediaMusicVolume(ctx_id, media_id, v: f32) void;
pub extern "audio" fn setMediaMusicPitch(ctx_id, media_id, p: f32) void;
pub extern "audio" fn setMediaMusicPan(ctx_id, media_id, p: f32) void;
pub extern "audio" fn setMediaMusicLooping(ctx_id, media_id, l: u32) void;
```

JS-side state per `media_id`:
```javascript
{
    audio: HTMLAudioElement,
    sourceNode: MediaElementAudioSourceNode,
    gainNode: GainNode,
    pannerNode: StereoPannerNode,
    blobUrl: string,  // for cleanup via URL.revokeObjectURL
    metadataReady: boolean,  // becomes true on 'loadedmetadata' event
}
```

**Smoke mock for OGG**: `decodeOggBytes` synthesizes a 1-sec
sine AudioBuffer (we don't need real Vorbis decoding in tests).
`loadMediaMusic` returns a handle whose `audio.duration` is a
fixed 60 seconds.  `isDecodeReady` returns 1 immediately on the
second poll (so tests can verify the "wait one frame" pattern).

**Tests:** 6 (decodeOggBytes returns positive handle; isDecodeReady starts pending; ready after one tick in mock; takeDecodedBuffer releases handle; loadMediaMusic returns positive id; seekMediaMusic clamps to duration).

**Snapshot:** `step-3-audio-jsbridge`.

## Phase 2 — WAV codec + OGG dispatch

Steps 4-8.  Same as v2 except adds Step 8 for OGG.

### Step 4 — Format enum + RIFF/WAVE chunk walker

```zig
pub const audio = struct {
    pub const Format = enum { wav, ogg, ... };

    pub const CanonicalWave = struct { ... };
    pub const wav = struct { ... };  // Step 5
    // .ogg has no Zig codec — dispatched to web.audio
};
```

Step 4 brings in:
- `Format` enum with `.wav` and `.ogg` variants
- `Format.decode`, `Format.syncDecodable`, `Format.detect`
- `CanonicalWave` shape (unchanged from v2)

**Tests:** 4 (Format.detect identifies "RIFF" → wav; "OggS" → ogg; short input → null; unknown bytes → null).

### Step 5 — `wav.decode` (reader-based)

Unchanged from v2.  Reuses 8 inline tests over `@embedFile("./assets/test_sine.wav")`.

**Tests:** 8.

### Step 6 — `wav.encode` (writer-based) + format conversion helpers

Unchanged from v2.  7 tests for encode round-trip, bit-depth conversions, mono→stereo, resampling.

**Tests:** 7.

### Step 7 — `toCanonical` end-to-end + Wave/CanonicalWave adapters

Unchanged from v2.  3 tests.

**Tests:** 3.

### Step 8 — OGG via Web Audio (no Zig codec body)

**NEW vs v2.**  No new pure-Zig code in `codecs.audio` for OGG.
Instead:

```zig
pub const audio = struct {
    // ...
    pub const ogg = struct {
        /// OGG decode is async and not available in codecs.audio.
        /// Use `sounds.loadFromMemory(.ogg, bytes)` or
        /// `music.loadFromMemory(.ogg, bytes)` for the public
        /// async-aware paths.  This module is intentionally empty
        /// of decode functions; it exists only to hold OGG-related
        /// types and constants.
        pub const Error = error{
            OggRequiresAsyncDecode,
            OggDecodeFailed,
            OggBrowserUnsupported,
        };

        /// Detect whether OGG bytes look valid (matches first
        /// 4 bytes against "OggS").  Doesn't validate further —
        /// browser does that.
        pub fn looksLikeOgg(bytes: []const u8) bool {
            return bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "OggS");
        }
    };
};
```

The "module" is mostly documentation.  The actual decode logic
sits in Step 14 (`sounds.loadFromMemory` for OGG) and Step 23
(`music.loadFromMemory` for OGG).

**Tests:** 2 (looksLikeOgg returns true for "OggS..." and false for "RIFF...").

**Snapshot:** `step-8-codec-complete`.

## Phase 3 — `sound.zig` foundation + Wave operations + Composer

Steps 9-13.  Same as v2 (renumbered from v2's 8-12).

### Step 9 — Create `src/sound.zig` with types + `audio_device` namespace

Same surface as v2's Step 8, plus the file header now mentions
the OGG dispatch model:

```zig
//! sound.zig — zimr audio runtime built on the Web Audio API.
//!
//! Format support:
//!   - WAV: pure-Zig codec in codecs.audio.wav.  Sync decode.
//!   - OGG: browser-native via decodeAudioData (Sound) and
//!     HTMLAudioElement (Music).  Async decode.
//!
//! ... (rest as v2's Step 8 header)
```

Plus the four extern struct shapes, `audio_device` namespace.

**Tests:** 4.

### Step 10 — Wave loading + lifecycle (WAV-only)

`waves.loadFromMemory(bytes) !Wave` — auto-detects WAV.  If the
bytes are OGG, returns `error.OggRequiresAsyncDecode` with a
clear message in the trace log: "OGG bytes detected; use
sounds.loadFromMemory or music.loadFromMemory instead."

`waves.loadFromMemoryExplicit(format, bytes)` — fails the same
way for `.ogg`.

```zig
pub fn loadFromMemory(gpa: std.mem.Allocator, bytes: []const u8) !Wave {
    const detected = audio.Format.detect(bytes) orelse return error.UnknownAudioFormat;
    if (!detected.syncDecodable()) {
        std.log.warn(
            "audio: wave.loadFromMemory cannot decode {s} bytes synchronously — " ++
                "use sounds.loadFromMemory or music.loadFromMemory for compressed formats.",
            .{@tagName(detected)},
        );
        return error.OggRequiresAsyncDecode;
    }
    var reader = std.Io.Reader.fixed(bytes);
    const canon = try detected.decode(gpa, &reader);
    return waveFromCanonical(gpa, canon);
}
```

**Tests:** 7 (loadFromMemory on test_sine.wav → frame count matches; loadFromMemory on test_chirp.ogg returns error; loadFromMemory on bogus bytes → invalid; copy round-trips; unload silent on default; isValid responds correctly; loadFromReader equivalent to loadFromMemory).

### Step 11 — Wave operations: filter / crop / format / mix / separate

Unchanged from v2.  8 tests.

### Step 12 — `composer` namespace (zimr-original)

Unchanged from v2.  6 tests.  Composer transitively WAV-only
because it takes Wave instances which can only come from WAV.

**Snapshot:** `step-12-composer-and-wave-ops`.

### Step 13 — Sound types + `loadFromWave` + lifecycle

```zig
pub const sounds = struct {
    pub fn loadFromWave(wave: Wave) !Sound;

    /// Sync path — only WAV.  For OGG use `loadFromMemoryAsync`.
    pub fn loadFromMemoryWav(gpa, bytes) !Sound;

    /// Async path — handles both formats.  For WAV: synchronously
    /// decodes and returns a ready Sound (isValid == true).
    /// For OGG: kicks off browser decode, returns a Sound that
    /// is initially invalid; isValid becomes true once decode
    /// completes (typically 5-80 ms later).
    pub fn loadFromMemoryAsync(gpa, format: audio.Format, bytes) !Sound;

    /// Format-detect helper.  Same async semantics as
    /// loadFromMemoryAsync.
    pub fn loadFromMemory(gpa, bytes) !Sound;

    pub fn loadAlias(source: Sound) Sound;
    pub fn unload(sound: Sound) void;
    pub fn unloadAlias(alias: Sound) void;
    pub fn isValid(sound: Sound) bool;  // false for pending OGG
    pub fn update(sound: Sound, data: []const u8, frame_count: u32) void;
};
```

**Tests:** 6 (loadFromWave on valid wave succeeds; on empty wave returns invalid; alias shares buffer id; unloading alias doesn't free original; update changes underlying buffer; isValid is false for default Sound).

**Snapshot:** `step-13-sound-foundation`.

## Phase 4 — Sound playback + OGG integration

Steps 14-17.

### Step 14 — Sound + OGG async decode pipeline

**NEW vs v2.**  Implements `sounds.loadFromMemoryAsync(.ogg, bytes)`:

```zig
pub fn loadFromMemoryAsync(
    gpa: std.mem.Allocator,
    format: audio.Format,
    bytes: []const u8,
) !Sound {
    switch (format) {
        .wav => return loadFromMemoryWav(gpa, bytes),
        .ogg => return loadOggAsync(gpa, bytes),
    }
}

fn loadOggAsync(gpa: std.mem.Allocator, bytes: []const u8) !Sound {
    // Allocate slot up front so caller gets a valid Sound handle.
    // The slot's audio_buffer_id is 0 until decode completes.
    const slot_idx = try HANDLES.allocSlot();
    const slot = HANDLES.getMut(slot_idx);

    const decode_handle = web.audio.decodeOggBytes(
        STATE.ctx_id,
        bytes.ptr,
        @intCast(bytes.len),
    );

    slot.* = .{
        .pending_decode = decode_handle,
        .audio_buffer_id = 0,  // will be filled in
    };

    // Tick the pending list each frame; see pollPendingDecodes.
    try PENDING_DECODES.append(gpa, slot_idx);

    return Sound{
        .stream = .{
            .buffer = @ptrFromInt(slot_idx),
            .processor = null,
            .sample_rate = 0,        // unknown until decode
            .sample_size = 32,       // f32
            .channels = 2,           // assume stereo
        },
        .frame_count = 0,            // unknown until decode
    };
}

/// Called from updateAudioDevice() (which runs each frame from
/// the runtime).  Drains completed decodes and fills in their
/// slots.
pub fn pollPendingDecodes() void {
    var i: usize = 0;
    while (i < PENDING_DECODES.items.len) {
        const slot_idx = PENDING_DECODES.items[i];
        const slot = HANDLES.getMut(slot_idx);
        const status = web.audio.isDecodeReady(STATE.ctx_id, slot.pending_decode);
        switch (status) {
            0 => i += 1,  // still pending
            1 => {
                slot.audio_buffer_id = web.audio.takeDecodedBuffer(
                    STATE.ctx_id, slot.pending_decode);
                slot.pending_decode = 0;
                _ = PENDING_DECODES.swapRemove(i);
            },
            2 => {
                std.log.warn("audio: OGG decode failed for slot {d}", .{slot_idx});
                slot.audio_buffer_id = 0;  // stays invalid
                slot.pending_decode = 0;
                _ = PENDING_DECODES.swapRemove(i);
            },
            else => unreachable,
        }
    }
}
```

A new module-level `var PENDING_DECODES: std.array_list.Aligned(usize, null) = .empty;`
tracks pending decodes.  The runtime calls `pollPendingDecodes`
each frame from `updateAudioDevice` (a new function added in
this step).

`isValid(sound)` checks `slot.audio_buffer_id != 0` — naturally
returns false for pending decodes.

`play(sound)` is silent no-op if not valid:
```zig
pub fn play(sound: Sound) void {
    if (!isValid(sound)) {
        return; // silently no-op; user should check isValid if they care
    }
    // ... real play ...
}
```

**Tests:** 7 (sync WAV path returns valid Sound immediately; async OGG returns Sound with isValid==false; pollPendingDecodes flips isValid to true after one tick in mock; play on pending Sound is silent; play after ready Sound emits Web Audio call; cancelled decode → isValid stays false; format-detect dispatches correctly).

### Step 15 — `play`, `stop`, `isPlaying`

Unchanged from v2's Step 13.  Plus the `isValid` guard in `play`
(implemented in Step 14 above).

**Tests:** 5.

### Step 16 — `pause`, `resume`, volume / pitch / pan setters

Unchanged from v2's Step 14.

**Tests:** 8.

### Step 17 — `examples/audio_basic.zig` + `examples/audio_pool.zig`

Same content as v2's combined Step 15+16, plus a small NEW
demonstration: the "fire" sound is loaded as OGG (~5 KB) instead
of WAV (~50 KB) to show the size win.  Page-load size budget for
this example: 60 KB → 15 KB.

UI flow: click anywhere or press 1/2/3 to play one of three blip
sounds (low/mid/high pitched, panned hard L / center / hard R).
Spam space to trigger up to 16 simultaneous playbacks.  HUD shows
active source count and OGG decode status during the first frame.

**Smoke target**: 60 frames without panic, ≥1 AudioContext call,
all OGG sounds become valid within 2 simulated frames.

**Snapshot:** `step-17-phase4-done`.

## Phase 5 — AudioStream + master mix

Steps 18-21.  Unchanged from v2's Phase 5.  AudioStream is a
WAV-or-procedural surface; OGG doesn't reach AudioStream
directly (it's encapsulated inside Music's HTMLAudioElement).

### Step 18 — `streams.load`, `unload`, `isValid`

Unchanged.  **Tests:** 4.

### Step 19 — `streams.update`, `isProcessed`

Unchanged.  **Tests:** 3.

### Step 20 — `streams.play`, `pause`, `resume`, `stop`, `isPlaying`

Unchanged.  **Tests:** 5.

### Step 21 — Setters + callback / processor stubs

Unchanged.  **Tests:** 5.

**Snapshot:** `step-21-stream-done`.

## Phase 6 — Music streaming (WAV + OGG dual-backend)

Steps 22-26.  Heavily refactored from v2 because of the OGG
backend.  Step count grows from 4 to 5.

### Step 22 — `wav.Decoder` (chunked reader for WAV-backed Music)

Unchanged from v2's Step 21.  The Decoder is only used by the
WAV-backed Music path; OGG-backed Music doesn't need it.

**Tests:** 4.

### Step 23 — `music.loadFromMemory` with format dispatch

**NEW behavior in v3.**  Format-aware loader:

```zig
pub fn loadFromMemory(
    gpa: std.mem.Allocator,
    format: audio.Format,
    bytes: []const u8,
) !Music {
    return switch (format) {
        .wav => loadFromMemoryWav(gpa, bytes),
        .ogg => loadFromMemoryOgg(gpa, bytes),
    };
}

pub fn loadFromMemoryDetect(gpa, bytes) !Music {
    const detected = audio.Format.detect(bytes) orelse return error.UnknownAudioFormat;
    return loadFromMemory(gpa, detected, bytes);
}

fn loadFromMemoryWav(gpa, bytes) !Music {
    // ... wav.Decoder + AudioStream backend ...
    return Music{
        .stream = audio_stream,
        .frame_count = decoder.frameCount(),
        .looping = false,
        .ctx_type = @intFromEnum(MusicCtxType.wav),
        .ctx_data = @ptrCast(decoder_ptr),
    };
}

fn loadFromMemoryOgg(gpa, bytes) !Music {
    // Browser handles all the work.
    const media_id = web.audio.loadMediaMusic(
        STATE.ctx_id,
        bytes.ptr,
        @intCast(bytes.len),
    );
    if (media_id == 0) return error.OggMediaLoadFailed;

    // Allocate a thin handle to track our side of state.
    const handle = try gpa.create(OggMusicHandle);
    handle.* = .{
        .media_id = media_id,
        .gpa = gpa,
    };

    return Music{
        .stream = std.mem.zeroes(AudioStream),  // unused for OGG
        .frame_count = 0,                       // unknown until metadata
        .looping = false,
        .ctx_type = @intFromEnum(MusicCtxType.ogg),
        .ctx_data = @ptrCast(handle),
    };
}
```

`unloadStream` releases both backends correctly:
```zig
pub fn unload(gpa, music: Music) void {
    switch (@as(MusicCtxType, @enumFromInt(music.ctx_type))) {
        .wav => {
            const decoder: *wav.Decoder = @ptrCast(@alignCast(music.ctx_data));
            decoder.deinit();
            gpa.destroy(decoder);
            streams.unload(music.stream);
        },
        .ogg => {
            const handle: *OggMusicHandle = @ptrCast(@alignCast(music.ctx_data));
            web.audio.unloadMediaMusic(STATE.ctx_id, handle.media_id);
            gpa.destroy(handle);
        },
    }
}
```

**Tests:** 7 (loadFromMemory(.wav) succeeds for test_sine; loadFromMemory(.ogg) succeeds for test_chirp; load with mismatched format returns error; loadFromMemoryDetect picks correct backend; unload silent on default Music; isValid responds for both backends; ctx_type is set correctly).

### Step 24 — `play`, `update`, `stop`, `pause`, `resume`, `isPlaying` with format dispatch

Each function dispatches on `music.ctx_type`:

```zig
pub fn play(music: Music) void {
    switch (@as(MusicCtxType, @enumFromInt(music.ctx_type))) {
        .wav => streams.play(music.stream),
        .ogg => {
            const h: *OggMusicHandle = @ptrCast(@alignCast(music.ctx_data));
            web.audio.playMediaMusic(STATE.ctx_id, h.media_id);
        },
    }
}

pub fn update(gpa, music: *Music) !void {
    switch (@as(MusicCtxType, @enumFromInt(music.ctx_type))) {
        .wav => try updateWavMusic(gpa, music),
        .ogg => {},  // browser handles it
    }
}
// ... pause, stop, resume, isPlaying all switch ...
```

`update` is the interesting one: WAV path pumps the decoder per
frame; OGG path is a true no-op.  Same API call from user code,
correct for both backends.

**Tests:** 8 (play/pause/resume/stop work for both backends; isPlaying responds correctly; update is no-op for OGG; update pumps decoder for WAV; double-play idempotent for both).

### Step 25 — `setVolume`, `setPitch`, `setPan`, `seek`, `getTimePlayed`, `getTimeLength` with format dispatch

```zig
pub fn setVolume(music: Music, volume: f32) void {
    switch (@as(MusicCtxType, @enumFromInt(music.ctx_type))) {
        .wav => streams.setVolume(music.stream, volume),
        .ogg => {
            const h: *OggMusicHandle = @ptrCast(@alignCast(music.ctx_data));
            web.audio.setMediaMusicVolume(STATE.ctx_id, h.media_id, volume);
        },
    }
}
// ... and so on for pitch, pan, seek ...
```

`getTimeLength` for OGG returns 0 if metadata isn't loaded yet
(browser hasn't seen `loadedmetadata` event).  Document the
"first-frame-after-load returns 0" behavior:

```zig
pub fn getTimeLength(music: Music) f32 {
    switch (@as(MusicCtxType, @enumFromInt(music.ctx_type))) {
        .wav => {
            const d: *wav.Decoder = @ptrCast(@alignCast(music.ctx_data));
            return @as(f32, @floatFromInt(d.frameCount())) /
                @as(f32, @floatFromInt(d.sample_rate));
        },
        .ogg => {
            const h: *OggMusicHandle = @ptrCast(@alignCast(music.ctx_data));
            // Returns 0 if metadata not yet loaded.
            return @floatCast(web.audio.getMediaMusicDuration(STATE.ctx_id, h.media_id));
        },
    }
}
```

**Tests:** 9 (each setter delegates correctly per backend; seek mid-track works for both; getTimePlayed advances; getTimeLength matches WAV header; getTimeLength is 0 for OGG before metadata loads in mock; setting looping flag mutates correctly for both).

### Step 26 — `examples/music_streaming.zig` (with OGG)

**v3 NEW**: example uses an OGG track (~30 KB) instead of WAV.
Shows the compression win directly — bundle includes a 90-second
stereo OGG at 64 kbps that would be ~16 MB as WAV.

UI: spacebar plays/pauses, R rewinds, L toggles looping, +/-
adjusts volume.  HUD shows: time-played / time-length progress
bar, current volume, looping state, and the format ("OGG via
HTMLAudioElement").

**Smoke target**: 60 frames without panic; calls `playMediaMusic`
once; reports duration > 0 by frame 5.

**Snapshot:** `step-26-music-done`.

## Phase 7 — Examples + final consolidation

Steps 27-30.

### Step 27 — `examples/audio_stream_synth.zig`

Unchanged from v2.  Procedural synth via `updateAudioStream`,
demonstrating polled real-time audio at ~50 ms latency.

### Step 28 — `examples/composer_drum.zig`

Unchanged from v2.  Composer + filter chain demo: pink noise +
sine, decay-filtered, mixed via Composer, loaded into a Sound,
played on click.  WAV-only by Composer's nature.

### Step 29 — Cheatsheet polish + format support documentation

CHEATSHEET.md gains:
- "Audio" section showing canonical patterns (load WAV, load OGG, fade music, master volume, Composer)
- "Format support" table documenting which paths support which formats (the matrix from "OGG support strategy" above)
- Migration note: "raylib's `LoadSound("track.ogg")` becomes `z.sounds.loadFromMemory(.ogg, ogg_bytes)`"

### Step 30 — Phase retrospectives + promote `[Unreleased]` → `[0.7.0]`

Same pattern as v2: write per-phase retrospectives, campaign
retrospective, promote `[Unreleased]` → `[0.7.0]`.  Final snapshot
`step-30-FINAL`.

## API coverage table

(Refined from v2; column added for OGG support per function.)

| raylib                          | zimr                                       | WAV  | OGG  | Notes |
|---------------------------------|--------------------------------------------|------|------|-------|
| `InitAudioDevice`               | `audio_device.init`                        | ✅   | ✅   | format-agnostic |
| `CloseAudioDevice`              | `audio_device.close`                       | ✅   | ✅   | format-agnostic |
| `IsAudioDeviceReady`            | `audio_device.isReady`                     | ✅   | ✅   | format-agnostic |
| `SetMasterVolume`               | `audio_device.setMasterVolume`             | ✅   | ✅   | format-agnostic |
| `GetMasterVolume`               | `audio_device.getMasterVolume`             | ✅   | ✅   | format-agnostic |
| `LoadWave`                      | `waves.load`                               | stub | stub | no FS on web |
| `LoadWaveFromMemory`            | `waves.loadFromMemory`                     | ✅   | ❌   | OGG returns OggRequiresAsyncDecode |
| `IsWaveValid`                   | `waves.isValid`                            | ✅   | n/a  | |
| `LoadSound`                     | `sounds.load`                              | stub | stub | no FS on web |
| `LoadSoundFromWave`             | `sounds.loadFromWave`                      | ✅   | n/a  | |
| `LoadSoundFromMemory` *         | `sounds.loadFromMemory`                    | ✅   | ✅   | OGG: async via decodeAudioData |
| `LoadSoundAlias`                | `sounds.loadAlias`                         | ✅   | ✅   | works for any backed Sound |
| `IsSoundValid`                  | `sounds.isValid`                           | ✅   | ✅   | OGG: false until decode completes |
| `UpdateSound`                   | `sounds.update`                            | ✅   | ✅   | replaces underlying buffer |
| `UnloadWave`                    | `waves.unload`                             | ✅   | n/a  | |
| `UnloadSound`                   | `sounds.unload`                            | ✅   | ✅   | format-agnostic |
| `UnloadSoundAlias`              | `sounds.unloadAlias`                       | ✅   | ✅   | format-agnostic |
| `ExportWave`                    | `waves.exportToBytes` + downloadBlob       | ✅   | n/a  | we don't encode OGG |
| `ExportWaveAsCode`              | `waves.exportAsCode`                       | stub | n/a  | no FS on web |
| `PlaySound`                     | `sounds.play`                              | ✅   | ✅   | OGG: silent no-op until ready |
| `StopSound`                     | `sounds.stop`                              | ✅   | ✅   | format-agnostic |
| `PauseSound`                    | `sounds.pause`                             | ✅   | ✅   | format-agnostic |
| `ResumeSound`                   | `sounds.resume`                            | ✅   | ✅   | format-agnostic |
| `IsSoundPlaying`                | `sounds.isPlaying`                         | ✅   | ✅   | format-agnostic |
| `SetSoundVolume`                | `sounds.setVolume`                         | ✅   | ✅   | format-agnostic |
| `SetSoundPitch`                 | `sounds.setPitch`                          | ✅   | ✅   | format-agnostic |
| `SetSoundPan`                   | `sounds.setPan`                            | ✅   | ✅   | format-agnostic |
| `WaveCopy`                      | `waves.copy`                               | ✅   | n/a  | |
| `WaveCrop`                      | `waves.crop`                               | ✅   | n/a  | |
| `WaveFormat`                    | `waves.format`                             | ✅   | n/a  | |
| `LoadWaveSamples`               | `waves.loadSamples`                        | ✅   | n/a  | |
| `UnloadWaveSamples`             | `waves.unloadSamples`                      | ✅   | n/a  | |
| `LoadMusicStream`               | `music.load`                               | stub | stub | no FS on web |
| `LoadMusicStreamFromMemory`     | `music.loadFromMemory`                     | ✅   | ✅   | format-aware dispatch |
| `IsMusicValid`                  | `music.isValid`                            | ✅   | ✅   | format-agnostic |
| `UnloadMusicStream`             | `music.unload`                             | ✅   | ✅   | dispatches per ctx_type |
| `PlayMusicStream`               | `music.play`                               | ✅   | ✅   | dispatches per ctx_type |
| `IsMusicStreamPlaying`          | `music.isPlaying`                          | ✅   | ✅   | dispatches per ctx_type |
| `UpdateMusicStream`             | `music.update`                             | ✅   | ✅   | OGG: no-op |
| `StopMusicStream`               | `music.stop`                               | ✅   | ✅   | dispatches |
| `PauseMusicStream`              | `music.pause`                              | ✅   | ✅   | dispatches |
| `ResumeMusicStream`             | `music.resume`                             | ✅   | ✅   | dispatches |
| `SeekMusicStream`               | `music.seek`                               | ✅   | ✅   | dispatches |
| `SetMusicVolume`                | `music.setVolume`                          | ✅   | ✅   | dispatches |
| `SetMusicPitch`                 | `music.setPitch`                           | ✅   | ✅   | dispatches |
| `SetMusicPan`                   | `music.setPan`                             | ✅   | ✅   | dispatches |
| `GetMusicTimeLength`            | `music.getTimeLength`                      | ✅   | ✅   | OGG: 0 until metadata loads |
| `GetMusicTimePlayed`            | `music.getTimePlayed`                      | ✅   | ✅   | dispatches |
| `LoadAudioStream`               | `streams.load`                             | ✅   | n/a  | streams accept raw PCM only |
| `IsAudioStreamValid`            | `streams.isValid`                          | ✅   | n/a  | |
| `UnloadAudioStream`             | `streams.unload`                           | ✅   | n/a  | |
| `UpdateAudioStream`             | `streams.update`                           | ✅   | n/a  | |
| `IsAudioStreamProcessed`        | `streams.isProcessed`                      | ✅   | n/a  | |
| `PlayAudioStream`               | `streams.play`                             | ✅   | n/a  | |
| `PauseAudioStream`              | `streams.pause`                            | ✅   | n/a  | |
| `ResumeAudioStream`             | `streams.resume`                           | ✅   | n/a  | |
| `IsAudioStreamPlaying`          | `streams.isPlaying`                        | ✅   | n/a  | |
| `StopAudioStream`               | `streams.stop`                             | ✅   | n/a  | |
| `SetAudioStreamVolume`          | `streams.setVolume`                        | ✅   | n/a  | |
| `SetAudioStreamPitch`           | `streams.setPitch`                         | ✅   | n/a  | |
| `SetAudioStreamPan`             | `streams.setPan`                           | ✅   | n/a  | |
| `SetAudioStreamBufferSizeDefault` | `streams.setBufferSizeDefault`           | no-op| n/a  | ABI parity |
| `SetAudioStreamCallback`        | `streams.setCallback`                      | stub | n/a  | AudioWorklet deferred |
| `AttachAudioStreamProcessor`    | `streams.attachProcessor`                  | stub | n/a  | AudioWorklet deferred |
| `DetachAudioStreamProcessor`    | `streams.detachProcessor`                  | stub | n/a  | |
| `AttachAudioMixedProcessor`     | `streams.attachMixedProcessor`             | stub | n/a  | AudioWorklet deferred |
| `DetachAudioMixedProcessor`     | `streams.detachMixedProcessor`             | stub | n/a  | |

\* `LoadSoundFromMemory` is a v3-added zimr public function that
matches `LoadWaveFromMemory` shape but for Sound directly —
unlike raylib which routes through Wave→Sound.  This direct
path is the only way to do async OGG → Sound without an
intermediate Wave that doesn't exist.

**Plus zimr-original (not in raylib):**

| zimr                                  | description                                | Format |
|---------------------------------------|--------------------------------------------|--------|
| `waves.filter`                        | In-place filter mutation                   | WAV    |
| `waves.filterWith`                    | Filter with extra args                     | WAV    |
| `waves.mix`                           | Sample-by-sample mix                       | WAV    |
| `waves.separate`                      | Split a Wave at a sample point             | WAV    |
| `composer.init` / `initWith`          | Create offline composition                 | WAV    |
| `composer.append` / `appendSlice`     | Add WaveInfo entries                       | WAV    |
| `composer.finalize`                   | Mix all entries into a single Wave         | WAV    |
| `audio.Format.detect`                 | Sniff format from magic bytes              | both   |
| `sounds.loadFromMemoryAsync`          | Format-aware async loader                  | both   |
| `music.loadFromMemoryDetect`          | Auto-detect music format                   | both   |

**Counts:** 64 raylib audio functions + 1 v3-added (LoadSoundFromMemory). Of these:
- 5 are FS stubs (no-op on web)
- 5 are AudioWorklet-deferred stubs (log warning)
- 1 is no-op for ABI parity (SetAudioStreamBufferSizeDefault)
- 54 fully implemented (53 of which work for both formats where applicable)

That's 83 % real coverage of raylib's audio surface, with **OGG
working everywhere it's applicable**.  Plus 10 zimr-original
public functions.

## Snapshot cadence

| Step | Snapshot                       | What's new                          |
|------|--------------------------------|-------------------------------------|
| 3    | `step-3-audio-jsbridge`        | Web Audio binding live (incl. OGG bridge) |
| 8    | `step-8-codec-complete`        | WAV codec + OGG dispatch defined    |
| 12   | `step-12-composer-and-wave-ops`| Wave ops + Composer live            |
| 13   | `step-13-sound-foundation`     | Wave + Sound types live             |
| 17   | `step-17-phase4-done`          | First sounds play (WAV + OGG)       |
| 21   | `step-21-stream-done`          | AudioStream end-to-end              |
| 26   | `step-26-music-done`           | Music streaming live (both backends)|
| 30   | `step-30-FINAL`                | Phase 7 done, 0.7.0 cut             |

## Risk register (v3 additions)

1. **Mobile Safari sample rate quirks.** (carried from v2) iOS Safari pins `AudioContext.sampleRate` to device-default 44100 Hz; resampler handles this naturally.  Verified plan, not blocked.

2. **Autoplay policies.** (carried from v2) AudioContext starts suspended; first play issues `context.resume()`.  Same applies to HTMLAudioElement: `audio.play()` returns a Promise that rejects without user gesture.  Mitigation: same pattern as Sound — first interaction unlocks.

3. **Memory pressure for long Wave loads.** (carried from v2) Loading a 5-min WAV via `waves.loadFromMemory` produces ~110 MB f32 in memory.  Mitigation: documentation steers users toward `music.loadFromMemory` for >10 sec audio, and toward OGG instead of WAV for music tracks.  v3 makes this concrete: the music_streaming example IS OGG.

4. **AudioWorklet deferral.** (carried from v2) Procedural-audio callbacks remain stubs.  Polled `updateAudioStream` covers the common case; `audio_stream_synth.zig` demonstrates.  v4 candidate.

5. **Filter chain pattern + `extern struct` Wave: extra `gpa` parameter.** (carried from v2) Documented; minor paper cut for users porting lightmix code.

6. **NEW: Older Safari OGG support.**  Safari added native OGG Vorbis support in iOS 17 / macOS 14 (late 2023).  Browsers older than that (~2-year-old iPhones in 2026 — phasing out fast) will fail to decode OGG.  Mitigation: `decodeOggBytes` returns error status (=2) for unsupported formats; `isValid` returns false; user sees a documented "OGG decode failed" log entry.  zimr's CHEATSHEET.md will note: "if targeting older iOS, ship MP3 fallbacks".  MP3 support is a v4 candidate using the same `decodeAudioData` path.

7. **NEW: HTMLAudioElement quirks.**  `audio.duration` is `NaN` until metadata loads (typically <100 ms).  `audio.play()` returns a Promise that we don't await; if it rejects (autoplay block), the play silently fails and the user sees nothing.  Mitigation: log autoplay rejections via the Promise's catch handler.  `audio.currentTime` is approximate during playback (browsers throttle reads to ~50 ms granularity for privacy).

8. **NEW: Async decode race with `unload`.**  If user calls `unload(sound)` while OGG decode is still pending, the decode handle and the slot need cleanup at the right time.  Mitigation: `cancelDecode` in the JS bridge (Step 3) signals the JS-side completion handler to drop the result on the floor; `unload` removes the slot from `PENDING_DECODES` and calls `cancelDecode`.  Tested in Step 14.

9. **NEW: Music backend mismatch.**  User calls `music.loadFromMemory(.wav, ogg_bytes)` — explicit format wrong.  Mitigation: `wav.Decoder.init` will fail with `error.InvalidSignature` and the load returns invalid Music.  Documented; `loadFromMemoryDetect` is the safe path.

10. **NEW: Composer + OGG mismatch.**  Composer takes Wave instances; user might expect to compose OGG-backed sources.  Mitigation: documented in cheatsheet — Composer is WAV-only by construction.  For OGG content the user would need to pre-decode to PCM externally (ffmpeg → WAV) and use the WAV bytes.

11. **NEW: `@embedFile` test fixture commits ~21 KB.**  test_sine.wav (~16 KB) + test_chirp.ogg (~5 KB).  Acceptable; the existing repo has ~50 KB of GLB test assets.

## Diff from v2

| Change | v2 | v3 | Why |
|--------|-----|-----|-----|
| Step count | 28 | 30 | +1 for OGG codec dispatch (Step 8); +1 for OGG Sound async pipeline (Step 14); +1 for music backend split (Phase 6 grew); −1 by absorbing Composer demo + audio_pool combination |
| Format support | WAV only | WAV + OGG | User feedback: OGG essential for music tracks (10× compression) |
| OGG decode path | n/a | Browser `decodeAudioData` (Sound) + HTMLAudioElement (Music) | No pure-Zig Vorbis decoder needed; browser does the work |
| `Format` enum | `.wav` only | `.wav` + `.ogg` | Forward-compatible, predicted in v2's "future" notes |
| Sound load API | sync only | sync (WAV) + async (OGG) | OGG decode is async; new `loadFromMemoryAsync` accommodates both |
| `isValid(sound)` | true after load | false during async OGG decode, true once ready | Documents the "pending" state |
| Music backend | AudioStream + wav.Decoder | dual: AudioStream (WAV) or HTMLAudioElement (OGG) | Browser-native streaming for OGG is dramatically simpler than chunked decode |
| `Music.ctx_type` | unused | actively dispatches WAV vs OGG paths | Field had ABI presence in v2 for parity; v3 puts it to work |
| `updateMusicStream` | always pumps decoder | pumps decoder for WAV; no-op for OGG | Same API call; correct for both backends |
| Coverage % | 83 % (53 of 64) | 83 % (54 of 65, counting LoadSoundFromMemory) | Same fraction; one new fn |
| `getTimeLength` | always returns valid value | returns 0 for OGG before metadata loads | Documented; HTMLAudioElement quirk |
| Bridge fn count | 7 audio.* exterm fns | 21 audio.* extern fns | 14 new for OGG decode + MediaElement |
| `PENDING_DECODES` list | n/a | new module-level state | Per-frame poll for OGG decode completion |
| `MusicCtxType` enum | n/a | new (`.wav` = 0, `.ogg` = 1) | Discriminator for ctx_type field |
| `examples/music_streaming.zig` content | embedded WAV melody | embedded OGG track (~30 KB) | Demonstrates compression win |
| Risk register | 7 items | 11 items | +4 OGG-specific risks (older Safari, MediaElement quirks, async decode race, ctx mismatch) |

**Things v2 got right that v3 keeps verbatim:**

- All lightmix idioms (filter chain, Composer, reader/writer I/O, named error sets, `@embedFile` test fixtures, modern Zig 0.15 patterns)
- f32 stereo internal format
- Wave / Sound / Music / AudioStream four-type model
- `audio_device` / `waves` / `sounds` / `music` / `streams` / `composer` namespacing
- Web Audio AudioContext lifecycle + autoplay handling
- Internal HANDLES table of 256 slots
- Smoke harness mocks Web Audio with a Proxy (extended for OGG mocks)
- AudioWorklet deferral and stubs
- `MAX_AUDIO_BUFFER_POOL_CHANNELS = 16`
- Mid-stream mutation for AudioStream; not for Sound

## What you tell users in the docs (Step 29 cheatsheet entry)

> zimr's audio supports **WAV** and **OGG Vorbis** files.  WAV is
> the simplest format — small headers, no compression, direct PCM
> decode.  Use it for short sound effects (<10 sec) where you want
> sample-level control (filter chains, mixing, the Composer API).
> OGG Vorbis is ~10× smaller for the same content — use it for
> music tracks, ambient loops, voice lines, or any sound where
> bundle size matters more than runtime mutability.
>
> Browser support: WAV everywhere; OGG everywhere modern (Safari
> ≥17, all Chrome/Firefox).  If you're targeting older iOS,
> consider shipping MP3 fallbacks (planned in zimr 0.8).
>
> **Migration from raylib:**  
> `LoadSound("clip.wav")` → `z.sounds.loadFromMemory(wav_bytes)`  
> `LoadSound("clip.ogg")` → `z.sounds.loadFromMemory(ogg_bytes)`  
> `LoadMusicStream("track.ogg")` → `z.music.loadFromMemory(ogg_bytes)`  
> All other functions match raylib's API exactly.  Note: OGG
> sounds may not be playable for ~10–80 ms after load; check
> `z.sounds.isValid(sound)` before calling `play()` if you need
> immediate playback.  For typical scene-setup-then-gameplay
> patterns, just preload during setup and don't worry about it.
>
> **zimr-original primitives** (not in raylib):
>
> 1. **`z.waves.filter(gpa, &wave, my_filter)`** — apply a user
>    transform to a WAV-loaded Wave's samples.  Chains compose
>    cleanly without intermediate allocations.  WAV-only.
>
> 2. **`z.composer`** — sequence multiple Waves at sample-frame
>    offsets, mix them down with `finalize()`.  Useful for
>    procedurally building drum hits, melodies, or test fixtures.
>    WAV-only by construction.
>
> 3. **`z.audio.Format.detect(bytes)`** — sniff format from magic
>    bytes; returns `.wav`, `.ogg`, or null.

That paragraph belongs in CHEATSHEET.md after Step 29.

---

End of audio-plan-v3.  Confidence: high.  Every design decision
above is anchored to one of:
- Verbatim raylib API (`raudio.c` source-verified)
- Verbatim Web Audio capability (MDN-verified, including `decodeAudioData` async semantics, MediaElement properties, autoplay policies)
- Verbatim lightmix idiom (source-verified)
- zimr project pattern (handles, namespaces, snapshots)

The OGG addition is the cheapest possible: zero pure-Zig codec
code, ~150 LOC of JS bridge, ~250 LOC of Zig dispatch logic
across Sound and Music.  Browser does the heavy lifting.
