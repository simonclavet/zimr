# audio plan (v1): zero → sound.zig (WAV-only)

> **Status.** Greenfield port of raylib's audio module to a single
> `sound.zig` file in zimr.  Web-first design built on the Web
> Audio API.  WAV-only (no OGG/MP3/FLAC/QOA/XM/MOD).  Scope
> deliberately matches raylib's full audio public surface so the
> migration story for callers is "rename and go".
>
> 30 steps across 7 phases.  Each step = one shippable commit:
> code → inline tests → optional example → cheatsheet bump →
> changelog line → `zig build test && zig build smoke-test`.

## What raylib's audio actually is

Read end-to-end:

- `raudio.c`  — 2963 LOC.  Public API (~50 fns), per-Sound mixer, AudioStream callback dispatch, Music context with format-switched ctxData (we drop this).
- `external/miniaudio.h` — 95 844 LOC.  Cross-platform device backend.  **Replaced wholesale by Web Audio.**  We never touch a line of it.
- `external/dr_wav.h` — 9 105 LOC.  WAV parser.  **Replaced by ~150 LOC of pure Zig.**  WAV's RIFF/fmt/data chunk layout is genuinely small.

Raylib's pipeline (Linux/Win/Mac):

```
miniaudio  →  device callback (audio thread)
                ↓
        for each AudioBuffer:    (volume / pitch / pan / converter)
                ↓
              master mixer  →  HW DAC
```

Our pipeline (web, equivalent):

```
WebAudio AudioContext    (browser-managed device + thread)
                ↓
        for each AudioBufferSourceNode:    (GainNode + StereoPannerNode + playbackRate)
                ↓
            master GainNode  →  AudioContext.destination
```

The mapping is one-to-one.  Pitch becomes `playbackRate`, pan
becomes `StereoPannerNode`, volume becomes `GainNode`, master
volume is a single `GainNode` before `destination`.  Web Audio
runs the mixer thread for us — no AudioWorklet needed for v1.

## Hard rules

1. **Style guide rules 1-7** (`src/notes/style-guide.md`).  One arg per line for >1-arg fns, mandatory braces, explicit local types unless already on the line, `@splat` over `**`, no module-level mutable globals in examples.
2. **Tests live next to the function.**  `src/sound.zig` is added to the test discovery list in `src/tests.zig` from Step 1.
3. **Layout: one new top-level file** — `src/sound.zig` — taking us from 10 → 11 src files (still under the 12-file budget).  WAV decoder lives in `src/codecs.zig` `pub const wav = struct` namespace alongside `png`/`truetype`/`gltf` — that's the project's pattern for codecs and breaking it would create a precedent we don't want.
4. **`codecs.wav` is invisible to callers.**  Public API surface is `sound.loadSound(bytes)`, `sound.loadSoundFromWave(wave)`, etc.  Users never import `codecs` for audio just like they don't import it for textures.
5. **One example per significant feature**, modeled on raylib's counterpart.  Examples appended to `build.zig`'s `examples` array.
6. **Smoke-test reality.**  Smoke harness mocks Web Audio identically to how it mocks WebGL — `webtests/smoke.ts` gets a `makeFakeAudioContext` Proxy that records calls and answers truthfully for getters.  Audio examples assert (a) no panic, (b) ≥1 AudioContext call (a stricter "got past init" check than the GL "≥100 calls" rule).
7. **CHEATSHEET.md** gets a new "Audio" section the same commit as Step 4 ("first sound plays").  Coverage % bumped each step that adds raylib-named public surface.
8. **CHANGELOG.md** `[Unreleased]` gets one line per step.
9. **`/home/claude/snapshots/save.sh <label>`** at every milestone — see [§ Snapshot cadence](#snapshot-cadence).
10. After every step: `zig build test --summary all && zig build smoke-test --summary all`.  Don't advance with red.

**Reference repo:** `/home/claude/raylib-ref/raylib-master/`.
Read `raudio.c` end-to-end before Phase 3.  The pipeline-locking
semantics (mutex around buffer-list mutation) translate into
"Web Audio's destination graph doesn't need locking, but our
internal Sound table does because PlaySound can fire from any
JS event handler" — easy to miss without reading the C.

## Plan summary

| Phase | Steps | Theme | New public fns |
|-------|------:|-------|---------------:|
| 0 | 0 | Read source + design notes (this file) | 0 |
| 1 | 1-3 | Web Audio JS bridge + AudioContext lifecycle | 4 |
| 2 | 4-7 | WAV decoder in `codecs.wav` | 0 (internal) |
| 3 | 8-11 | `sound.zig` foundation: Wave + Sound types, lifecycle | 12 |
| 4 | 12-17 | Sound playback + per-sound effects (volume/pitch/pan) | 8 |
| 5 | 18-22 | AudioStream + master mix + processors | 14 |
| 6 | 23-26 | Music streaming (long WAVs) | 12 |
| 7 | 27-30 | Examples + final consolidation | 0 |
| **Total** | **30** | | **~50** |

(The "~50" matches raylib's full audio API; the WAV-only
restriction reduces *what* `loadSound` accepts but not the count
of public functions.)

## What we're NOT building (and why)

- **OGG / MP3 / FLAC / QOA / XM / MOD codecs.**  Each is ~5–10 KLOC.  WAV-only halves the project's complexity and ships something useful in 30 steps instead of 80.  Format support is a future-version question (`audio-plan-v2`).
- **AudioWorklet for synthesis callbacks.**  raylib has `SetAudioStreamCallback` for procedural audio (the audio thread requests samples).  AudioWorklet is the Web Audio equivalent but has a separate worker context, MessagePort lifecycle, and cross-thread state issues.  We expose `setAudioStreamCallback` as a no-op stub that logs a warning so the API surface matches; the procedural-audio path comes later.  **Polled `updateAudioStream` works fully** — that's the path most apps actually use.
- **`SetAudioStreamCallback` real implementation.**  Same reason as above.
- **`ExportWave` / `ExportWaveAsCode`.**  Useful for raylib's CLI workflow; meaningless on the web (no filesystem).  Ported as no-op stubs that return `false` so the API surface matches.
- **Spatial audio (HRTF, distance attenuation, panner positioning beyond stereo).**  raylib doesn't have it either — only `SetSoundPan` for L/R balance.  StereoPannerNode covers what raylib offers.

These exclusions are spelled out per-fn in [§ API coverage table](#api-coverage-table) at the end.

## Phase 0 — Design

Already done by the time this file lands.  The conclusions:

### Canonical internal format

raylib internally normalises everything to **float-32 stereo at
device sample rate** before mixing.  Web Audio's `AudioBuffer`
*is* float-32 with channels-as-separate-arrays at the
`AudioContext.sampleRate`.  These match.  Concretely:

- Sample format: `f32`
- Channels: 2 (mono uploads get duplicated to L+R)
- Sample rate: whatever the AudioContext picked (typically 48000 on Chrome/Firefox desktop, 44100 elsewhere)

Wave files come in at 8/16/32-bit ints + 1/2 channels at 8000–96000 Hz.  We resample on load:

- Bit depth → f32 (`(sample - bias) / max`)
- Channel count → stereo (mono → L=R, multichannel → take channels 0+1)
- Sample rate → AudioContext rate via linear interpolation

Sample-rate conversion via linear interp loses high frequencies
above Nyquist/2 of the source rate; for game SFX this is fine.
Music tracks stored at 44.1k playing back at 48k will sound
identical to a casual listener.  If somebody complains we can
add a windowed-sinc upsampler later — known cleanup, not
blocking.

### Web Audio lifecycle gotcha

`AudioContext` **starts suspended** in every modern browser
(Chrome ≥ 71, Safari, Firefox).  Calling `createBufferSource()`
or `start()` on a suspended context emits no audio.  The
context resumes on the *first user gesture* (click, touchend,
keydown).

Our `initAudioDevice()` *creates* the context but does not
guarantee it's running.  The first call to a play function must
check `context.state` and, if suspended, attempt `context.resume()`.
The resume returns a promise — we ignore it (raylib's API is
sync; the worst case is the first play has 50ms of latency).

### Object model

```zig
pub const Wave = extern struct {
    frame_count: c_uint,         // total frames
    sample_rate: c_uint,         // Hz
    sample_size: c_uint,         // 8 / 16 / 32 — bits per sample
    channels: c_uint,            // 1 / 2 / ...
    data: ?*anyopaque,           // RAM PCM (gpa-owned)
};

pub const Sound = extern struct {
    stream: AudioStream,         // playback handle
    frame_count: c_uint,
};

pub const Music = extern struct {
    stream: AudioStream,
    frame_count: c_uint,
    looping: bool,
    ctx_type: c_int,             // unused (always WAV in v1) but kept for ABI parity
    ctx_data: ?*anyopaque,
};

pub const AudioStream = extern struct {
    buffer: ?*AudioBuffer,       // private — opaque handle, points into HANDLES table
    processor: ?*AudioProcessor,
    sample_rate: c_uint,
    sample_size: c_uint,
    channels: c_uint,
};
```

These match raylib's struct layouts byte-for-byte.  External
field names use raylib's lowerCamel for the public alias and
snake_case internally — mirrors how `Mesh`/`Model` already
straddle the boundary in `types.zig`.

### Internal handle table

Web Audio's nodes can't be C-pointer'd around without going
through `web.zig`.  Approach used elsewhere in zimr (e.g. fetch
handles): keep an internal slot table in `sound.zig` with stable
integer IDs, pass `*AudioBuffer` as a sentinel pointer that's
really an index cast to a pointer.

```zig
const HANDLES: SlotTable(InternalAudioState, 256) = .{};
```

256 simultaneous Sounds is comfortable for any game; raylib's
default is 16 channels of pool-multiplexed Sound playback.

## Phase 1 — Web Audio JS bridge

Steps 1-3.  Goal: a pure-Zig caller can construct an
AudioContext, query its state, and play a hardcoded sine-wave
buffer.  No format work, no zimr public API yet — purely the
JS interop foundation.

### Step 1 — AudioContext lifecycle in `src/web.zig`

Add `pub const audio = struct` namespace alongside `dom`/`gl`/`fetch`.

```zig
pub const audio = struct {
    pub extern "audio" fn createContext() c_uint;
    pub extern "audio" fn closeContext(ctx_id: c_uint) void;
    pub extern "audio" fn resumeContext(ctx_id: c_uint) void;
    pub extern "audio" fn getSampleRate(ctx_id: c_uint) f32;
    pub extern "audio" fn getMasterVolume(ctx_id: c_uint) f32;
    pub extern "audio" fn setMasterVolume(ctx_id: c_uint, v: f32) void;
};
```

JS side in `src/web/zimr.ts`:

```ts
audio: {
  ctxs: new Map<number, AudioContext>(),
  master_gains: new Map<number, GainNode>(),
  next_id: 1,
  createContext: (): number => {
    const ctx = new AudioContext();
    const gain = ctx.createGain();
    gain.connect(ctx.destination);
    const id = audio.next_id++;
    audio.ctxs.set(id, ctx);
    audio.master_gains.set(id, gain);
    return id;
  },
  // ...
},
```

Key design: each AudioContext gets ONE master GainNode between
itself and `destination`.  Every Sound/AudioStream connects to
this GainNode, never directly to `destination`.  Master volume
is `gainNode.gain.value`.

**Smoke mocking** — `webtests/smoke.ts` adds `makeFakeAudioContext`
returning a Proxy that records calls and returns plausible
defaults (sampleRate = 48000, state = "running").

**Tests:** 4 (createContext returns positive id; close is no-op for invalid id; setMasterVolume clamps to [0, 10]; getSampleRate returns positive value).

**Snapshot:** `step-3-audio-jsbridge` after Step 3.

### Step 2 — `loadAudioBuffer` (raw PCM upload)

```zig
pub extern "audio" fn loadAudioBuffer(
    ctx_id: c_uint,
    sample_rate: c_uint,
    channels: c_uint,
    frame_count: c_uint,
    data: [*]const f32,
    data_len: c_uint,
) c_uint;

pub extern "audio" fn unloadAudioBuffer(ctx_id: c_uint, buffer_id: c_uint) void;
```

JS side: `ctx.createBuffer(channels, frameCount, sampleRate)`,
copy the f32 data into each channel via `buffer.copyToChannel`.
Returns a numeric handle indexed into `audio.buffers: Map<number, AudioBuffer>`.

The data layout passed from Zig is **interleaved stereo**
(`L,R,L,R,...`) — Web Audio wants planar (one channel per
typed array).  JS deinterleaves on the boundary.  This adds
one allocation per buffer load but makes the Zig side simpler.

**Tests:** 2 (load happens; unload is silent on invalid id).

### Step 3 — `playBuffer` / `stopBuffer` with per-call params

```zig
pub extern "audio" fn playBuffer(
    ctx_id: c_uint,
    buffer_id: c_uint,
    volume: f32,
    pitch: f32,
    pan: f32,
    looping: u32,
) c_uint; // returns source-id (revocable handle for stopBuffer)

pub extern "audio" fn stopBuffer(ctx_id: c_uint, source_id: c_uint) void;
pub extern "audio" fn pauseBuffer(ctx_id: c_uint, source_id: c_uint) void;
pub extern "audio" fn resumeBuffer(ctx_id: c_uint, source_id: c_uint) void;
pub extern "audio" fn isBufferPlaying(ctx_id: c_uint, source_id: c_uint) u32;
```

JS side: build a graph per play:
```
AudioBufferSourceNode → GainNode → StereoPannerNode → masterGain
```

`source.playbackRate.value = pitch`, `source.loop = looping`,
`source.start(0)`.

**Note** AudioBufferSourceNode is one-shot.  Every call to
`playBuffer` makes a fresh source.  This is also why raylib's
`LoadSoundAlias` is degenerate on the web — every play is
implicitly an alias.  We expose `loadSoundAlias` returning a
copy of the input Sound; on the web it costs nothing.

For pause/resume: Web Audio doesn't have native pause on a
source.  We disconnect the source and remember its
`source.context.currentTime` offset; resume creates a fresh
source starting at the offset.  Real implementation goes in
Step 13 — Step 3 has only stop + isPlaying.

**Tests:** 3 (play returns positive id; stop on invalid id is silent; isPlaying returns 0 for nonexistent id).

**Snapshot:** `step-3-audio-jsbridge`.

## Phase 2 — WAV decoder in `codecs.wav`

Steps 4-7.  A 16-bit PCM stereo WAV parser is ~80 LOC.
Adding 8-bit + 32-bit float + mono → stereo expansion + sample
rate conversion brings us to ~300 LOC.  Lives in `codecs.zig`
alongside `png`/`truetype`/`gltf`.

### Step 4 — RIFF/WAVE chunk walker

```zig
pub const wav = struct {
    pub const Error = error{
        InvalidSignature, // not RIFF/WAVE
        UnsupportedFormat, // not PCM-int or PCM-float
        UnsupportedBitDepth, // not 8/16/32
        UnsupportedChannels, // 0 or > 8
        TruncatedFile,
        OutOfMemory,
    };

    /// Owned RAM PCM in raylib's Wave format (interleaved, native endianness).
    pub const Wave = struct {
        frame_count: u32,
        sample_rate: u32,
        sample_size: u32,
        channels: u32,
        data: []u8,

        pub fn deinit(self: Wave, gpa: std.mem.Allocator) void {
            gpa.free(self.data);
        }
    };

    pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!Wave;
};
```

Walker reads:
- `RIFF` magic + length (skip 4 bytes)
- `WAVE` magic
- `fmt ` chunk: format tag (1 = PCM, 3 = float), channels, sample rate, byte rate, block align, bits/sample
- `data` chunk: actual PCM bytes
- Other chunks (LIST, JUNK, etc.): skipped

8 inline tests with hand-built byte arrays:
1. Bare-minimum PCM 16-bit mono parses
2. Bare-minimum PCM 16-bit stereo parses
3. PCM 32-bit float parses
4. PCM 8-bit (unsigned biased) parses
5. Wrong magic returns InvalidSignature
6. Float format with bits ≠ 32 returns UnsupportedBitDepth
7. Truncated `data` chunk returns TruncatedFile
8. LIST chunk between `fmt ` and `data` is skipped silently

**Tests:** 8.  **Snapshot:** none.

### Step 5 — Format conversion: int → f32, mono → stereo

`codecs.wav.toFloat32Stereo(gpa, wave) ![]f32`

Always returns interleaved stereo f32 regardless of input.
Used in Step 8 by `loadSound`.

Cases:
- 8-bit unsigned int: `(s - 128) / 128.0`
- 16-bit signed int: `s / 32768.0`
- 32-bit float: passthrough
- mono → stereo: `dst[2k]=dst[2k+1]=src[k]`
- 5.1+ → stereo: take channels 0 and 1, drop the rest

3 inline tests covering the three input formats round-tripping
through known fixtures.

**Tests:** 3.

### Step 6 — Sample rate conversion: linear interp

`codecs.wav.resampleLinear(gpa, samples_in, channels, sr_in, sr_out) ![]f32`

Linear interpolation between adjacent input frames.  Output
length = `frame_count * sr_out / sr_in`.  Edge case: if
`sr_in == sr_out`, return a copy without interpolation.

Why linear and not a proper sinc kernel?  For game SFX (the
common case), linear at 44.1k → 48k is indistinguishable.  For
high-quality music at the cost of two CPU% during load, sinc is
the upgrade.  Linear ships in v1; sinc deferred.

3 tests:
1. sr_in == sr_out returns identical samples
2. 2× upsample doubles output length
3. 0.5× downsample halves output length

**Tests:** 3.

### Step 7 — End-to-end: `wav.decode` → `wav.toFloat32Stereo` → `resampleLinear`

`codecs.wav.toCanonical(gpa, wave_bytes, target_rate) ![]f32`

Convenience wrapper used by Step 8.  Decodes the bytes, expands
to stereo f32, resamples to `target_rate`, returns one big
`[]f32` ready to hand to `web.audio.loadAudioBuffer`.

2 tests:
1. Round-trip a hand-built 16-bit mono 22050 Hz WAV → 48000 Hz stereo f32 with the right frame count
2. Empty data chunk returns an empty slice (not an error)

**Tests:** 2.  **Snapshot:** `step-7-wav-decoder`.

## Phase 3 — `sound.zig` foundation

Steps 8-11.  This is when `sound.zig` is created and starts
filling in.

### Step 8 — Create `src/sound.zig` with types + InitAudioDevice/CloseAudioDevice

File header documents the design:

```zig
//! sound.zig — zimr audio runtime built on the Web Audio API.
//!
//! All audio public surface lives in this single file:
//!   - sound.audio_device  (init/close/master volume)
//!   - sound.waves         (Wave: RAM PCM)
//!   - sound.sounds        (Sound: short clips, fully decoded)
//!   - sound.music         (Music: streamed long WAVs)
//!   - sound.streams       (AudioStream: raw PCM injection)
//!
//! Internal audio decode lives in codecs.wav (alongside png and
//! truetype) — same pattern as image and font loading.
//!
//! Web Audio binding lives in web.zig's `audio` namespace.
```

Step 8 surface:
- `pub const Wave = ...` (re-export of `codecs.wav.Wave`)
- `pub const Sound`, `pub const Music`, `pub const AudioStream` (extern struct shapes)
- `pub const audio_device = struct { ... }` with:
  - `init(gpa) !void`  → calls `web.audio.createContext()` and stashes the id
  - `close() void` → calls `web.audio.closeContext`
  - `isReady() bool`
  - `getMasterVolume() f32` / `setMasterVolume(v) void`

Internal state:
```zig
const AudioDeviceState = struct {
    gpa: std.mem.Allocator = undefined,
    ctx_id: c_uint = 0,
    is_ready: bool = false,
};
var STATE: AudioDeviceState = .{};
```

`tests.zig` gets `_ = @import("sound.zig");` added.  `comptime { _ = audio_device; }` at end of `sound.zig` for nested-namespace discovery.

**Tests:** 4 (init then close cleanly; double-init is a no-op; getMasterVolume returns 1.0 by default; setMasterVolume clamps to [0, 1]).

### Step 9 — Wave loading: `loadWave`, `loadWaveFromMemory`, `unloadWave`, `isWaveValid`, `waveCopy`

Public fns in `sound.waves` namespace.  `loadWaveFromMemory(file_type, bytes)` is the wasm-friendly entry; `loadWave(path)` deferred since wasm has no filesystem (could route through fetch in a later refactor; for now stubbed to return an empty Wave).

`waveCopy(wave) Wave` — deep copy via `gpa.dupe(u8, wave.data)`.

**Tests:** 6 (load valid WAV → frame count matches; load wrong magic returns invalid Wave; copy round-trips; unloadWave on default-init Wave is no-op; isWaveValid responds correctly).

### Step 10 — Wave operations: `waveCrop`, `waveFormat`, `loadWaveSamples`, `unloadWaveSamples`

`waveCrop(*wave, start_frame, end_frame)` — in-place trim.

`waveFormat(*wave, sample_rate, sample_size, channels)` —
re-encode the Wave into different format params.  Internally
uses `codecs.wav.resampleLinear` for SR change, bit-depth
casting tables for size change, channel-mix matrix for channel
change.  Most expensive op in the file (~80 LOC).

`loadWaveSamples(wave) []f32` — convenience for users who want
to manipulate raw float samples.  Uses `codecs.wav.toFloat32Stereo`.

**Tests:** 5 (crop preserves header rate; format-conversion round-trips; loadWaveSamples returns correct length; cropping past the end clamps; cropping inverted range is a no-op).

### Step 11 — Sound types + `loadSoundFromWave` + `unloadSound` + `isSoundValid`

`loadSoundFromWave(wave) !Sound`:
1. Convert wave to canonical f32 stereo at AudioContext sample rate
2. Call `web.audio.loadAudioBuffer` to upload
3. Return Sound with `stream.buffer = @ptrFromInt(buffer_id)`

`loadSound(file_path)` — stub returning invalid Sound (no
filesystem on wasm).  `loadSoundFromMemory(file_type, bytes)`
is the real entry: `wav.decode → loadSoundFromWave → unloadWave`.

`loadSoundAlias(source) Sound` — returns a Sound sharing the
same `buffer_id`.  Tracked separately so unloadSoundAlias
doesn't free the underlying buffer.

**Tests:** 4 (loadSoundFromWave on valid wave succeeds; on empty wave fails; alias shares buffer id; unloading alias doesn't free original).

**Snapshot:** `step-11-sound-foundation`.

## Phase 4 — Sound playback

Steps 12-17.  This is the user-visible "audio works" milestone.
By Step 13 the first example plays a click sound.

### Step 12 — `playSound`, `stopSound`, `isSoundPlaying`

```zig
pub fn playSound(sound: Sound) void;
pub fn stopSound(sound: Sound) void;
pub fn isSoundPlaying(sound: Sound) bool;
```

`playSound`: gets the source-id from `web.audio.playBuffer`,
stores it in a per-Sound active-source slot (since AudioBufferSourceNode
is one-shot, the same Sound played twice has TWO active sources;
we keep an array of active source-ids per Sound, capped at
MAX_AUDIO_BUFFER_POOL_CHANNELS = 16, mirroring raylib's pool).

`stopSound`: stop ALL active sources for this Sound.

`isSoundPlaying`: returns true if ANY active source for this
Sound is still running (we ask JS via `isBufferPlaying`).

**Tests:** 5 (playSound on default Sound is a no-op; stopSound on never-played sound is silent; isSoundPlaying returns false for default Sound; double-play creates two sources; stopSound drops both).

### Step 13 — `pauseSound`, `resumeSound`

Trickier than play/stop because Web Audio sources don't
natively pause.  Implementation: on pause, record
`elapsed = ctx.currentTime - source.start_time`, then disconnect
the source.  On resume, build a fresh source with
`source.start(0, elapsed)` (offset within the buffer).

This loses any playbackRate ramping but games don't typically
ramp pitch through a pause anyway.  Documented limitation.

**Tests:** 3 (pause-then-resume restarts at offset; pause on stopped sound is silent; resume on never-paused is silent).

### Step 14 — `setSoundVolume`, `setSoundPitch`, `setSoundPan`

These mutate the per-Sound *next-play* settings.  Already-playing
sources are NOT retroactively updated — calling setSoundVolume
on a playing sound applies to the NEXT playSound only.

(Why?  raylib does the same — its pitch/pan settings live on
the Sound, are read at play time.  Re-routing the audio graph
mid-flight per setter call is more work than warranted by
typical game audio patterns.)

For *AudioStream* specifically, mid-flight mutation IS supported
since AudioStream represents a single long-lived source.  See
Step 19.

**Tests:** 6 (each setter clamps to its valid range; values persist across getSound* getters).

### Step 15 — `setSoundsEnabled` global mute

Not in raylib's API but a reasonable QoL addition.  Defer? —
no, drop it.  Master volume = 0 covers the use case.  Step
exists in the plan only to reduce the temptation to scope-creep
per-step.  Skipped, count of phase-4 steps: 5.

### Step 15 (renumbered) — `examples/audio_basic.zig`

Embedded 1-second 440 Hz sine wave WAV (hand-built in Python
generator at top of file, output as Zig byte array same pattern
as `gltf_simple_cube.zig`).  Click anywhere or press space to
play it.  HUD shows playback count.

**Smoke target:** runs 60 frames without panic, emits ≥1
AudioContext call.

**Snapshot:** `step-15-first-sound`.

### Step 16 — `examples/audio_panning.zig`

Three sounds (low/mid/high pitched sines), each panned hard L /
center / hard R.  Playable via 1/2/3 keys.  Demonstrates pan +
pitch independence.

### Step 17 — `examples/audio_pool.zig`

Rapid-fire firing-laser sound (50 ms blip).  Spam space to
trigger up to 16 simultaneous playbacks.  HUD shows active
source count, taking advantage of `isSoundPlaying`-driven slot
reuse.

**Snapshot:** `step-17-phase4-done` (Phase 4 milestone).

## Phase 5 — AudioStream + master mix

Steps 18-22.  AudioStream is the lower-level "raw PCM in,
playback out" surface.  Music and the procedural-audio path
both build on it.

### Step 18 — `loadAudioStream`, `unloadAudioStream`, `isAudioStreamValid`

`loadAudioStream(sample_rate, sample_size, channels) AudioStream`

Allocates an AudioStream slot but doesn't create any AudioBuffer
yet.  The caller will push frames via `updateAudioStream`.

Internal state per AudioStream slot:
- `pending_queue: std.ArrayListUnmanaged(QueuedBuffer)` — buffers waiting to play
- `current_playback_source: ?c_uint` — the JS source-id currently playing, if any
- `next_start_time: f64` — AudioContext.currentTime at which the next queued buffer should start (for gapless)
- `volume`, `pitch`, `pan` (all start at 1, 1, 0)

raylib uses a 2-buffer ping-pong; we use a queue of arbitrary
length because Web Audio's scheduling is per-source-with-start-time.
The caller's `IsAudioStreamProcessed()` returns true whenever
the queue has fewer than 2 buffers — same semantic, looser
implementation.

**Tests:** 4 (load returns valid stream; unload is silent on default stream; isAudioStreamValid responds correctly; double-unload is silent).

### Step 19 — `updateAudioStream`, `isAudioStreamProcessed`

`updateAudioStream(stream, data, frame_count)`:
1. Copy `data` (interleaved at the stream's sample_size/channels) into a fresh f32 stereo buffer at the AudioContext rate
2. `web.audio.loadAudioBuffer` to upload
3. Schedule a fresh AudioBufferSourceNode with `source.start(next_start_time)`
4. Update `next_start_time += buffer.duration`
5. Append to `pending_queue`; if queue length > 2, the oldest will free naturally as Web Audio drops finished sources

`isAudioStreamProcessed(stream)`: returns true if the JS side's
queue depth is ≤ 1 (caller has room for one more buffer's worth
of data).

**Tests:** 3 (update round-trips a small frame count; isAudioStreamProcessed starts true; consecutive updates fill the queue).

### Step 20 — `playAudioStream`, `pauseAudioStream`, `resumeAudioStream`, `stopAudioStream`, `isAudioStreamPlaying`

State machine on the per-stream slot.  `play` enables the
scheduled-source pipeline; `pause` schedules a stop on all
queued sources and remembers the offset; `stop` clears the
queue.

**Tests:** 5 (play→isPlaying true; stop→isPlaying false; pause + resume preserves played frames; double-play is silent; stop while not playing is silent).

### Step 21 — `setAudioStreamVolume`, `setAudioStreamPitch`, `setAudioStreamPan`, `setAudioStreamBufferSizeDefault`

Volume/pitch/pan mutate the per-stream GainNode/playbackRate/
StereoPannerNode in real-time (unlike Sound, which only takes
effect on next play).  This is critical for music fade-out and
DJ-style pitch-bends.

`setAudioStreamBufferSizeDefault(size)` — kept for ABI parity;
on Web Audio there's no fixed buffer size so this is a no-op.

**Tests:** 4 (each setter clamps; mid-stream mutation succeeds; setBufferSizeDefault is a silent no-op).

### Step 22 — `setAudioStreamCallback`, `attachAudioStreamProcessor`, `detachAudioStreamProcessor`, `attachAudioMixedProcessor`, `detachAudioMixedProcessor`

The callback / processor functions exist in raylib so apps can
synthesise / process audio at sample-thread granularity.  These
require AudioWorklet on the web, which is its own multi-step
project (separate worker, MessagePort, sample-thread state
sync).

For v1, these are **stubs that log a one-time warning**:
"setAudioStreamCallback / processor / mixed processor: AudioWorklet
support deferred to audio-plan-v2.  The function exists for ABI
compatibility but is currently a no-op."

This keeps the compile-time API surface complete for migration
purposes — apps that depend on these still link cleanly, they
just don't get the procedural audio they wanted.  Documented
limitation.

**Tests:** 1 (each stub returns without panicking — single
combined test).

**Snapshot:** `step-22-stream-done`.

## Phase 6 — Music streaming

Steps 23-26.  Music in raylib is a streamed audio source — for
formats like MP3, the decoder is fed chunks rather than the
whole file at once.  WAV-only changes the picture: we *could*
just `loadSound` the whole WAV.  Why have Music at all?

Two reasons:
1. **API parity** — apps written against raylib expect Music's
   `looping`, `seek`, `getTimePlayed`, `getTimeLength` semantics.
2. **Memory** — a 5-minute 44.1k stereo f32 WAV is ~110 MB
   in-memory.  Streaming reads keep peak memory ~1 MB.

The streaming implementation: Music wraps an AudioStream + a
local `wav.Decoder` cursor that reads chunks from the source
bytes.  `updateMusicStream` reads the next 1-second chunk,
decodes to canonical f32 stereo, pushes into the AudioStream.

### Step 23 — `wav.Decoder` chunked reader in `codecs.zig`

Stateful reader that keeps the file bytes + cursor.  Methods:
- `readFrames(out_samples: []f32, max_frames: usize) usize` — fill output, return frames actually read (less than max at EOF)
- `seekFrame(frame_index: u32) !void`
- `frameCount(): u32`
- `framesPlayed(): u32`

Decoder lives in `codecs.wav.Decoder`.  Uses the same RIFF
walker as `decode` but stops at the `data` chunk and remembers
the offset.  Subsequent `readFrames` calls slice from that
offset.

**Tests:** 4 (read all frames in chunks vs all-at-once produces identical output; seek to offset matches expected sample; seek past end returns 0; frameCount matches header).

### Step 24 — `loadMusicStream`, `loadMusicStreamFromMemory`, `unloadMusicStream`, `isMusicValid`

`loadMusicStreamFromMemory(file_type, bytes)`:
1. `wav.Decoder` over the bytes (kept alive in `Music.ctx_data`)
2. Allocate an AudioStream sized for ~1 sec of audio at the file's rate
3. Return a Music handle

The `ctx_data` field stores a pointer to the gpa-owned Decoder.
`unloadMusicStream` frees both the stream and the decoder.

**Tests:** 4 (load valid music; load bogus bytes returns invalid; unload is silent; isMusicValid responds correctly).

### Step 25 — `playMusicStream`, `updateMusicStream`, `stopMusicStream`, `pauseMusicStream`, `resumeMusicStream`, `isMusicStreamPlaying`

`updateMusicStream(music)` is the per-frame call.  Internally:
1. Check `audio_stream.isProcessed()`
2. If so, ask the decoder for `~1 sec` of frames
3. If decoder hits EOF and `music.looping`, seek to 0 and continue
4. Push frames into the AudioStream

`playMusicStream` calls `playAudioStream` on the wrapped stream.

**Tests:** 5 (play sets isPlaying true; update without play does nothing; pause/resume preserves position; looping music wraps; non-looping music stops at EOF).

### Step 26 — `setMusicVolume`, `setMusicPitch`, `setMusicPan`, `seekMusicStream`, `getMusicTimeLength`, `getMusicTimePlayed`

The volume/pitch/pan setters delegate to the underlying
AudioStream's setters (already implemented).

`seekMusicStream(music, position_in_seconds)`:
1. Convert seconds → frame index via decoder's sample rate
2. `decoder.seekFrame(frame)`
3. Stop and restart the audio stream so existing-buffered audio
   doesn't continue playing

`getMusicTimePlayed` / `getMusicTimeLength`: trivial fraction
of `decoder.framesPlayed()` / `decoder.frameCount()` over
sample rate.

**Tests:** 5 (each setter delegates correctly; seek mid-track resumes from offset; getTimePlayed advances during play; timeLength matches header).

**Snapshot:** `step-26-music-done`.

## Phase 7 — Examples + final consolidation

Steps 27-30.

### Step 27 — `examples/music_streaming.zig`

Embedded 5-second WAV-encoded melody (procedurally synthesised
in the Python generator at the top of the file: 5 seconds of
arpeggio across C-major).  UI: spacebar plays/pauses, R rewinds
to start, L toggles looping.  HUD shows time-played /
time-length progress bar.

### Step 28 — `examples/audio_stream_synth.zig`

Procedural waveform generator demonstrating `updateAudioStream`
in polling mode — a `f32` sine table is filled per frame and
pushed.  Frequency mouse-controllable via X coordinate.  Without
AudioWorklet this isn't *zero-latency* synthesis — there's a
~50ms buffer-ahead — but it's the right shape of API.

This example also serves as documentation that real-time
synthesis is supported, just not at single-sample latency.

### Step 29 — Cheatsheet polish + audio-coverage entries

Update CHEATSHEET.md with a finalised "Audio" section showing
each canonical pattern: load + play a sound, fade-out music
via mid-stream volume ramp, procedural synthesis via
AudioStream, master volume control.

Coverage table: rmodels.audio module 0% → ~85% (the missing
15% is callbacks/processors/non-WAV codecs/Export*).

### Step 30 — Phase 7 retrospective + promote `[Unreleased]` → `[0.7.0]`

Same pattern as v2: write the per-phase retrospective, the
campaign retrospective, then move the section header.  Cheatsheet
final coverage line bumped.  Snapshot `step-30-FINAL`.

## API coverage table

Every raylib audio function listed with its disposition.

| raylib                                | zimr                                     | status          |
|---------------------------------------|------------------------------------------|-----------------|
| `InitAudioDevice`                     | `audio_device.init`                      | full            |
| `CloseAudioDevice`                    | `audio_device.close`                     | full            |
| `IsAudioDeviceReady`                  | `audio_device.isReady`                   | full            |
| `SetMasterVolume`                     | `audio_device.setMasterVolume`           | full            |
| `GetMasterVolume`                     | `audio_device.getMasterVolume`           | full            |
| `LoadWave`                            | `waves.loadWave`                         | stub (no FS)    |
| `LoadWaveFromMemory`                  | `waves.loadWaveFromMemory`               | full (`.wav` only) |
| `IsWaveValid`                         | `waves.isValid`                          | full            |
| `LoadSound`                           | `sounds.loadSound`                       | stub (no FS)    |
| `LoadSoundFromWave`                   | `sounds.loadSoundFromWave`               | full            |
| `LoadSoundAlias`                      | `sounds.loadSoundAlias`                  | full            |
| `IsSoundValid`                        | `sounds.isValid`                         | full            |
| `UpdateSound`                         | `sounds.update`                          | full            |
| `UnloadWave`                          | `waves.unload`                           | full            |
| `UnloadSound`                         | `sounds.unload`                          | full            |
| `UnloadSoundAlias`                    | `sounds.unloadAlias`                     | full            |
| `ExportWave`                          | `waves.export`                           | stub (no FS)    |
| `ExportWaveAsCode`                    | `waves.exportAsCode`                     | stub (no FS)    |
| `PlaySound`                           | `sounds.play`                            | full            |
| `StopSound`                           | `sounds.stop`                            | full            |
| `PauseSound`                          | `sounds.pause`                           | full            |
| `ResumeSound`                         | `sounds.resume`                          | full            |
| `IsSoundPlaying`                      | `sounds.isPlaying`                       | full            |
| `SetSoundVolume`                      | `sounds.setVolume`                       | full            |
| `SetSoundPitch`                       | `sounds.setPitch`                        | full            |
| `SetSoundPan`                         | `sounds.setPan`                          | full            |
| `WaveCopy`                            | `waves.copy`                             | full            |
| `WaveCrop`                            | `waves.crop`                             | full            |
| `WaveFormat`                          | `waves.format`                           | full            |
| `LoadWaveSamples`                     | `waves.loadSamples`                      | full            |
| `UnloadWaveSamples`                   | `waves.unloadSamples`                    | full            |
| `LoadMusicStream`                     | `music.loadStream`                       | stub (no FS)    |
| `LoadMusicStreamFromMemory`           | `music.loadStreamFromMemory`             | full (`.wav` only) |
| `IsMusicValid`                        | `music.isValid`                          | full            |
| `UnloadMusicStream`                   | `music.unloadStream`                     | full            |
| `PlayMusicStream`                     | `music.playStream`                       | full            |
| `IsMusicStreamPlaying`                | `music.isStreamPlaying`                  | full            |
| `UpdateMusicStream`                   | `music.updateStream`                     | full            |
| `StopMusicStream`                     | `music.stopStream`                       | full            |
| `PauseMusicStream`                    | `music.pauseStream`                      | full            |
| `ResumeMusicStream`                   | `music.resumeStream`                     | full            |
| `SeekMusicStream`                     | `music.seekStream`                       | full            |
| `SetMusicVolume`                      | `music.setVolume`                        | full            |
| `SetMusicPitch`                       | `music.setPitch`                         | full            |
| `SetMusicPan`                         | `music.setPan`                           | full            |
| `GetMusicTimeLength`                  | `music.getTimeLength`                    | full            |
| `GetMusicTimePlayed`                  | `music.getTimePlayed`                    | full            |
| `LoadAudioStream`                     | `streams.load`                           | full            |
| `IsAudioStreamValid`                  | `streams.isValid`                        | full            |
| `UnloadAudioStream`                   | `streams.unload`                         | full            |
| `UpdateAudioStream`                   | `streams.update`                         | full            |
| `IsAudioStreamProcessed`              | `streams.isProcessed`                    | full            |
| `PlayAudioStream`                     | `streams.play`                           | full            |
| `PauseAudioStream`                    | `streams.pause`                          | full            |
| `ResumeAudioStream`                   | `streams.resume`                         | full            |
| `IsAudioStreamPlaying`                | `streams.isPlaying`                      | full            |
| `StopAudioStream`                     | `streams.stop`                           | full            |
| `SetAudioStreamVolume`                | `streams.setVolume`                      | full            |
| `SetAudioStreamPitch`                 | `streams.setPitch`                       | full            |
| `SetAudioStreamPan`                   | `streams.setPan`                         | full            |
| `SetAudioStreamBufferSizeDefault`     | `streams.setBufferSizeDefault`           | no-op (ABI)     |
| `SetAudioStreamCallback`              | `streams.setCallback`                    | stub (logs warn)|
| `AttachAudioStreamProcessor`          | `streams.attachProcessor`                | stub (logs warn)|
| `DetachAudioStreamProcessor`          | `streams.detachProcessor`                | stub            |
| `AttachAudioMixedProcessor`           | `streams.attachMixedProcessor`           | stub (logs warn)|
| `DetachAudioMixedProcessor`           | `streams.detachMixedProcessor`           | stub            |

**Counts:** 64 raylib audio functions, of which 6 are FS stubs
(no-op on web, return-invalid), 5 are AudioWorklet-deferred
stubs (log warning), 1 is no-op for ABI parity, **52 fully
implemented**.  That's 81 % real coverage of raylib's audio
surface.

## Snapshot cadence

| Step | Snapshot                       | What's new              |
|------|--------------------------------|-------------------------|
| 3    | `step-3-audio-jsbridge`        | Web Audio binding live  |
| 7    | `step-7-wav-decoder`           | WAV decoder complete    |
| 11   | `step-11-sound-foundation`     | Wave + Sound types live |
| 17   | `step-17-phase4-done`          | First sounds play       |
| 22   | `step-22-stream-done`          | AudioStream end-to-end  |
| 26   | `step-26-music-done`           | Music streaming live    |
| 30   | `step-30-FINAL`                | Phase 7 done, 0.7.0 cut |

## Risk register

1. **Mobile Safari sample rate quirks.**  iOS Safari pins `AudioContext.sampleRate` to the device-default 44100 Hz; our resampler must handle this.  Mitigation: resampling is on every load anyway; sample rate variation is just one more value the resampler handles correctly.  Verified plan, not blocked.
2. **Autoplay policies.**  AudioContext starts suspended.  First playSound must `context.resume()` if needed.  Handled in Step 12.
3. **Memory pressure for long Wave loads.**  A 5-minute stereo 44.1k 16-bit WAV is ~50 MB on disk and ~110 MB after our f32 expansion.  Music's streaming path (Phase 6) avoids the f32 expansion since the decoder yields chunks.  Apps that load minutes-long sounds via `loadSound` (not `loadMusic`) will hit this — *intentional*, matches raylib's "Music for >10 sec" guidance.
4. **AudioWorklet deferral kills procedural audio for some users.**  setAudioStreamCallback being a stub means apps relying on it for synthesis won't work.  The polled `updateAudioStream` path covers the common case (~50ms latency, fine for any non-instrument app).  Real-time synth is a v2 deliverable.
5. **Per-mesh smoke-test threshold (≥1 AudioContext call) is weaker than the GL one.**  Audio examples emit fewer cross-boundary calls than rendering examples.  Documented.

## Diff from "support all formats" version

Eliminated:
- 6 codec implementations (~25 KLOC of pure-Zig porting work)
- Music's `ctxType` switch (only WAV codepath)
- 30+ format-specific edge cases in audio_basic / music examples
- Any encoder-side concerns (Export*)

Kept:
- Full public API surface (52 of 64 fns fully working)
- All five user-visible objects (Wave/Sound/Music/AudioStream/AudioDevice)
- Volume / pitch / pan / master / pan / loop semantics
- Streaming Music (since long WAVs still need it for memory)
- Step structure that ports cleanly to a v2 plan adding codecs

If/when v2 lands, codec slots in `loadWaveFromMemory(file_type, bytes)`
already exist — `file_type == ".ogg"` currently returns invalid;
v2 just teaches that branch to call `codecs.ogg.decode`.

## What you tell users in the docs

> zimr's audio supports WAV files only — the most common format
> for game SFX and the simplest to embed.  For sources in other
> formats, convert to WAV first; ffmpeg's `-c:a pcm_s16le` does
> this in one command.  The full audio API matches raylib's;
> migrating an existing raylib game's audio code requires only
> the rename map (e.g. `LoadSound` → `z.sounds.loadSoundFromMemory`).

That paragraph belongs in CHEATSHEET.md after Step 29.
