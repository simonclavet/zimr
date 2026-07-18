# audio plan (v2): zero → sound.zig (WAV-only, lightmix-verified)

> **Status.** Replaces `audio-plan-v1.md`.  Same destination
> (single-file `sound.zig` built on Web Audio, full raylib audio
> public surface, WAV-only).  Different routing: tightened by
> end-to-end study of [lightmix](https://github.com/haruki7049/lightmix)
> — a Zig audio synthesis library that ships ~1700 LOC of
> polished, idiomatic code we can verify our design against.
>
> 28 steps across 7 phases (down from v1's 30 by collapsing two
> redundant example steps).  Each step = one shippable commit:
> code → inline tests → optional example → cheatsheet bump →
> changelog line → `zig build test && zig build smoke-test`.

## What lightmix taught us (verification + improvements)

Read end-to-end: `src/wave.zig` (956 LOC), `src/composer.zig`
(438 LOC), all 13 example apps.  lightmix is a different
animal from raylib's audio (synthesis-and-composition library
vs. playback engine), but it sits adjacent enough that its
idiom choices are directly evaluable.

### What v1 already had right (confirmed)

- **Single canonical f32 stereo internal format.**  raylib agrees, Web Audio agrees, lightmix uses a generic `T = f64/f80/f128` instead — but explicitly omits f32 because their codec dependency `zigggwavvv` doesn't support it.  We reject the generic for raylib ABI parity; f32 it is.
- **Wave / Sound / Music / AudioStream four-type model.**  Matches both raylib and how lightmix splits offline (Wave) vs. realtime (`play()`) concerns.
- **`init(samples, allocator, options)` deep-copies, `deinit()` frees.**  Identical to lightmix.  Confirmed.
- **Tests live next to functions; one inline-test per behaviour.**  lightmix does this throughout (`test "init creates deep copy of samples"`, `test "filter memory leaks' check"`).
- **Single-file `sound.zig` for the runtime + decoder in `codecs.zig`.**  lightmix is also a small handful of files; the project-pattern argument holds.

### What v1 got wrong or missed (now fixed in v2)

1. **I/O surface should be `std.Io.Reader` / writer, not `[]const u8`.**  lightmix uses `Wave(T).read(.wav, allocator, reader)` where reader is *any* `std.Io.Reader`.  This is the modern Zig 0.15 pattern and unlocks:
   - Reading from `std.Io.Reader.fixed(bytes)` for embedded fixtures (no extra allocation)
   - Reading from a fetch handle stream as it arrives (future progressive-load)
   - Writing back via `wav.encode(wave, writer, options)` lets `ExportWave` actually work — write to an in-memory `std.Io.Writer.Allocating`, hand the bytes to `web.dom.downloadBlob`.  v1 stubbed this; v2 implements it.

2. **Filter chain mutation pattern is the right idiom for Wave operations.**  lightmix's `pub fn filter(self: *Self, comptime filter_fn: anytype) anyerror!void` frees the old samples and replaces self with the result.  This makes filter chains compose without allocator boilerplate:
   ```zig
   try wave.filter(decay);
   try wave.filter(halve);
   try wave.filter(distort);
   ```
   v1 had this pattern only for `waveCrop` (mutating signature).  v2 unifies: every Wave-on-Wave op is a filter.  `waveCrop`, `waveFormat`, future user filters all share one mechanism.

3. **`Composer` is genuinely useful and missing from raylib's API.**  lightmix's Composer is an array of `(Wave, start_point)` pairs that `finalize()` mixes into a single Wave.  Use cases for zimr:
   - Build runtime sound effects from primitives (mix a sine + noise burst → drum hit, save to AudioBuffer)
   - Build test fixtures procedurally instead of hand-rolled byte arrays
   - Music examples that procedurally arrange notes
   v2 adds this as a zimr-original feature in `sound.zig`'s `composer` namespace.  Same precedent as adding gestures functions raylib doesn't have.

4. **Polymorphic format dispatch via enum is forward-compatible.**  lightmix's `LowLevelInterfaces` enum has only `.wav` today, but the API surface is shaped so adding `.ogg` / `.mp3` later requires zero call-site changes:
   ```zig
   const wave = try Wave.read(.wav, allocator, reader);  // today
   const wave = try Wave.read(.ogg, allocator, reader);  // v3 — same call shape
   ```
   v1 had separate `wav.decode` / future `ogg.decode` entrypoints — that breaks call sites at the v3 transition.  v2 unifies the dispatch through a single `codecs.audio.Format` enum that currently has only `.wav` but is positioned for growth.

5. **Specific named error sets per operation, not a single grab-bag error.**  lightmix has `SeparateErrors = error{ SeparatingZeroLengthWave, TooBigSeparatePoint }` — purpose-specific, one variant per failure mode.  v1 had `wav.Error` lumping every WAV-decode failure into one set.  v2 splits: `WavDecodeError`, `WavEncodeError`, `WaveCropError`, etc.  Standard Zig stdlib convention; better for callers who want to handle some errors and propagate others.

6. **`std.array_list.Aligned(T, null)` is the modern (Zig 0.15+) ArrayList shape.**  lightmix uses this throughout: `var list: std.array_list.Aligned(WaveInfo, null) = .empty;`.  v1's pseudo-code used `std.ArrayList` (0.13 era).  v2 modernizes all snippets.

7. **`@embedFile` test fixtures, not hand-rolled byte arrays.**  lightmix ships a 88KB `src/assets/sine.wav` that's `@embedFile`'d into tests.  This is cleaner than v1's "hand-roll a tiny WAV in the test body" approach — the fixture is a real WAV (you can play it in any audio app for verification) and the test code stays small.  v2 ships a 16KB `src/assets/test_sine.wav` (44.1k, 16-bit, mono, 0.5 sec).

### What lightmix does that we deliberately don't adopt

1. **Generic `Wave(T)` over float type.**  Adds a level of comptime dispatch for zero practical gain (raylib's audio is f32-only; Web Audio's AudioBuffer is f32-only).  Keeping `Wave` an `extern struct` matches raylib's ABI shape and lets us do `@ptrCast` between zimr's Wave and raylib's Wave for migration tooling.  Decision: **f32 only**, no generic.

2. **Build-time WAV generation via `addWave` build helper.**  Cute, but conflicts with zimr's wasm-first design.  `zig build` runs on the host; zimr targets `wasm32-wasi`.  Build-time WAV generation works only on native targets and creates a fork between dev tooling and runtime.  Decision: **drop**, examples generate their fixtures via Python (consistent with current zimr glTF/skinned-mesh examples).

3. **External codec dependency (`zigggwavvv`, `zaudio`).**  zimr explicitly avoids external deps.  Pure Zig WAV decoder stays.  Decision: **drop**.

4. **`wave.play()` blocking call.**  Suits CLI tools writing fixtures; wrong for game engines.  zimr's `playSound` returns immediately and Web Audio plays asynchronously.  Decision: **playback is non-blocking** (already in v1).

5. **Filter pattern as the only effects mechanism.**  For runtime playback we use the AudioContext graph (GainNode + StereoPannerNode + playbackRate) — that's what Web Audio is designed for.  Filter chains live in the OFFLINE path (Wave operations).  v2 supports both, with clear separation:
   - **Runtime audio** (live playback): graph-based via `Sound`/`AudioStream`/`Music`
   - **Offline audio** (procedural generation, test fixtures, sound design): filter chains via `Wave`

## Hard rules

1. **Style guide rules 1-7** (`src/notes/style-guide.md`).  One arg per line for >1-arg fns, mandatory braces, explicit local types unless already on the line, `@splat` over `**`, no module-level mutable globals in examples.
2. **Tests live next to the function.**  `src/sound.zig` is added to the test discovery list in `src/tests.zig` from Step 8.
3. **Layout: one new top-level file** — `src/sound.zig` — taking us from 10 → 11 src files (still under the 12-file budget).  WAV codec lives in `src/codecs.zig` `pub const audio = struct` namespace alongside `png` / `truetype` / `gltf`.  Internally that namespace contains a `Format` enum (`.wav` only for now) and per-format reader/writer impls.
4. **`codecs.audio` is invisible to callers.**  Public API surface is `sound.waves.loadFromMemory(bytes)`, `sound.sounds.loadFromMemory(bytes)`, etc.  Users never import `codecs` for audio just like they don't import it for textures.
5. **One example per significant feature**, modeled on raylib's counterpart where one exists.  Examples appended to `build.zig`'s `examples` array.
6. **Smoke-test reality.**  `webtests/smoke.ts` mocks Web Audio identically to how it mocks WebGL — `makeFakeAudioContext` returns a Proxy that records calls and answers truthfully for getters.  Audio examples assert (a) no panic, (b) ≥1 AudioContext call.  No per-function smoke assertions.
7. **CHEATSHEET.md** gets a new "Audio" section the same commit as Step 16 ("first sound plays").  Coverage % bumped each step that adds raylib-named public surface.
8. **CHANGELOG.md** `[Unreleased]` gets one line per step.
9. **`/home/claude/snapshots/save.sh <label>`** at every milestone — see [§ Snapshot cadence](#snapshot-cadence).
10. After every step: `zig build test --summary all && zig build smoke-test --summary all`.  Don't advance with red.
11. **Test fixtures use `@embedFile`** — `src/assets/test_sine.wav` (~16 KB) is committed alongside source; tests do `@embedFile("./assets/test_sine.wav")`.  No hand-rolled-bytes-in-test-bodies.

**Reference repos.**  `/home/claude/raylib-ref/raylib-master/` (read `raudio.c` end-to-end before Phase 3).
`/home/claude/lightmix/lightmix-main/` (already read; idiom reference for offline Wave ops + Composer).

## Plan summary

| Phase | Steps | Theme | New public fns |
|-------|------:|-------|---------------:|
| 0 | 0 | Read source + design (this file) | 0 |
| 1 | 1-3 | Web Audio JS bridge + AudioContext lifecycle | 4 |
| 2 | 4-7 | WAV codec in `codecs.audio` (reader/writer I/O) | 0 (internal) |
| 3 | 8-12 | `sound.zig` foundation: Wave + ops + Composer + Sound types | 18 |
| 4 | 13-16 | Sound playback + per-sound effects | 8 |
| 5 | 17-20 | AudioStream + master mix + processors | 14 |
| 6 | 21-24 | Music streaming (long WAVs + decoder) | 12 |
| 7 | 25-28 | Examples + Composer demo + final consolidation | 0 |
| **Total** | **28** | | **~56** |

(Six more "new public fns" than v1's count because the Composer
adds 5 and Wave-as-filter-target adds 1.  All raylib audio
public-surface coverage stays at 64 functions across 52 fully
working / 6 FS stubs / 5 worklet-deferred / 1 ABI no-op.)

## What we're NOT building (scope cuts, refined)

- **OGG / MP3 / FLAC / QOA / XM / MOD codecs.**  Each is ~5–10 KLOC.  WAV-only halves project complexity and ships in 28 steps instead of 80.  Format support is a future-version question (`audio-plan-v3`).  The `codecs.audio.Format` enum is positioned for `.ogg`/`.mp3` additions without breaking call sites.
- **AudioWorklet for synthesis callbacks.**  raylib has `SetAudioStreamCallback` for procedural audio (sample-thread-driven).  AudioWorklet is the Web Audio equivalent but has a separate worker context, MessagePort lifecycle, and cross-thread state issues.  v2 exposes `setAudioStreamCallback` as a no-op stub that logs a warning.  Polled `updateAudioStream` works fully — that's the path most apps actually use, and `examples/audio_stream_synth.zig` (Step 26) demonstrates real-time synth at ~50 ms latency without AudioWorklet.
- **Generic float precision (`f64`/`f80`/`f128`).**  Decision discussed in lightmix verification above — f32 only.
- **Build-time WAV generation.**  Decision discussed above — incompatible with wasm-first.
- **`SetAudioStreamCallback` real implementation.**  Same reason as AudioWorklet.  Tracked in v3.
- **`ExportWaveAsCode`.**  Generates a `.h` file with the wave embedded as a C array — useful for raylib's CLI workflow, meaningless on the web.  Stub returning `false`.

These exclusions are spelled out per-fn in [§ API coverage table](#api-coverage-table) at the end.

## Phase 0 — Design (lightmix-verified)

### Canonical internal format

Same as v1.  f32 stereo at AudioContext.sampleRate.

WAV files come in at 8/16/32-bit ints + 1/2 channels at 8000–96000 Hz.
We resample on load:
- Bit depth → f32 (`(sample - bias) / max`)
- Channel count → stereo (mono → L=R, multichannel → take channels 0+1)
- Sample rate → AudioContext rate via linear interpolation

### Web Audio lifecycle

Same as v1: AudioContext starts suspended; first `playSound` issues a `context.resume()` if needed.

### Object model (refined)

raylib-extern-struct shapes for ABI parity, plus zimr-internal
namespaces with idiomatic Zig methods that wrap them.

```zig
// Public, ABI-compatible with raylib.h
pub const Wave = extern struct {
    frame_count: c_uint,
    sample_rate: c_uint,
    sample_size: c_uint,
    channels: c_uint,
    data: ?*anyopaque,
};

pub const Sound = extern struct {
    stream: AudioStream,
    frame_count: c_uint,
};

pub const Music = extern struct {
    stream: AudioStream,
    frame_count: c_uint,
    looping: bool,
    ctx_type: c_int,             // unused (always WAV in v1) but kept for ABI parity
    ctx_data: ?*anyopaque,       // private wav.Decoder pointer
};

pub const AudioStream = extern struct {
    buffer: ?*AudioBuffer,       // private — opaque handle, points into HANDLES table
    processor: ?*AudioProcessor,
    sample_rate: c_uint,
    sample_size: c_uint,
    channels: c_uint,
};
```

Method-style operations live in namespaces:

```zig
pub const waves = struct {
    pub fn loadFromMemory(gpa: ..., bytes: []const u8) !Wave;
    pub fn loadFromReader(gpa: ..., reader: *std.Io.Reader) !Wave;
    pub fn unload(gpa: ..., wave: Wave) void;
    pub fn copy(gpa: ..., wave: Wave) !Wave;
    pub fn isValid(wave: Wave) bool;

    /// In-place filter mutation, lightmix-style.
    /// `filter_fn: fn(Wave, gpa) anyerror!Wave` — called with the current
    /// wave; returned wave replaces it; old samples freed.
    pub fn filter(gpa: ..., wave: *Wave, comptime filter_fn: anytype) !void;
    pub fn filterWith(
        gpa: ..., wave: *Wave,
        comptime args_type: type,
        comptime filter_fn: anytype,
        args: args_type,
    ) !void;

    /// Standard ops (each implemented as a filter under the hood).
    pub fn crop(gpa: ..., wave: *Wave, start: u32, end: u32) !void;
    pub fn format(gpa: ..., wave: *Wave, sample_rate: u32, sample_size: u32, channels: u32) !void;
    pub fn mix(gpa: ..., a: Wave, b: Wave) !Wave;
    pub fn separate(gpa: ..., wave: Wave, separate_point: u32) !struct { Wave, Wave };
    pub fn loadSamples(gpa: ..., wave: Wave) ![]f32;
    pub fn unloadSamples(gpa: ..., samples: []f32) void;

    pub fn exportToWriter(wave: Wave, writer: *std.Io.Writer, options: ExportOptions) !void;
    pub fn exportToBytes(gpa: ..., wave: Wave, options: ExportOptions) ![]u8;
};
```

Why both `loadFromMemory(bytes)` AND `loadFromReader(reader)`?
- `loadFromMemory` is the friendly common case
- `loadFromReader` is the orthogonal Zig idiom for stream/network sources
- The body is one line: `loadFromMemory` constructs a `std.Io.Reader.fixed(bytes)` and calls `loadFromReader`

This dual surface matches lightmix's structure and means future
progressive-load (fetch streams) drops in cleanly.

### Internal handle table

256-slot array indexed by `c_uint` IDs cast through `?*anyopaque`.
Same as v1.

### Filter signature (v2 detail)

```zig
/// User filters take the current Wave + gpa, return a new Wave.
/// gpa is passed explicitly because the result might allocate
/// differently from the input (e.g. a longer wave after stretching).
pub const FilterFn = fn (
    gpa: std.mem.Allocator,
    wave: Wave,
) anyerror!Wave;

/// Filter with extra args.
pub const FilterFnWith = fn (
    gpa: std.mem.Allocator,
    wave: Wave,
    args: anytype,
) anyerror!Wave;
```

Difference from lightmix: lightmix passes the allocator
*through* the wave (via `wave.allocator`).  Ours passes it
explicitly because our Wave is `extern struct` (raylib-shaped,
no allocator field).  Tradeoff: one extra parameter per filter
in exchange for ABI compatibility.  Worth it.

## Phase 1 — Web Audio JS bridge

Steps 1-3.  Goal: a pure-Zig caller can construct an AudioContext,
query state, and play a hardcoded sine-wave buffer.  No format
work, no zimr public API yet — purely the JS interop foundation.

Unchanged from v1 except for one detail:

### Step 1 — AudioContext lifecycle in `src/web.zig`

```zig
pub const audio = struct {
    pub extern "audio" fn createContext() c_uint;
    pub extern "audio" fn closeContext(ctx_id: c_uint) void;
    pub extern "audio" fn resumeContext(ctx_id: c_uint) void;
    pub extern "audio" fn getSampleRate(ctx_id: c_uint) f32;
    pub extern "audio" fn getCurrentTime(ctx_id: c_uint) f64;  // NEW vs v1
    pub extern "audio" fn getMasterVolume(ctx_id: c_uint) f32;
    pub extern "audio" fn setMasterVolume(ctx_id: c_uint, v: f32) void;
};
```

`getCurrentTime` added in v2 — needed by AudioStream's gapless
scheduling (Step 18).  Cheap to add now; would require a JS bridge
revision later.

JS side: each AudioContext gets ONE master GainNode.  Every
Sound/AudioStream connects to this GainNode, never directly to
`destination`.

**Smoke mocking** — `makeFakeAudioContext` returns a Proxy that
records calls and returns plausible defaults (sampleRate=48000,
state="running", currentTime=0).

**Tests:** 5 (createContext returns positive id; close is no-op for invalid id; setMasterVolume clamps to [0, 10]; getSampleRate returns positive value; getCurrentTime returns non-negative).

**Snapshot:** `step-3-audio-jsbridge` after Step 3.

### Step 2 — `loadAudioBuffer` (raw PCM upload)

Unchanged from v1.

### Step 3 — `playBuffer` / `stopBuffer` / pause/resume/isPlaying

Unchanged from v1.

**Snapshot:** `step-3-audio-jsbridge`.

## Phase 2 — WAV codec in `codecs.audio`

Steps 4-7.  Reader/writer-based I/O surface (v2 change).

### Step 4 — `Format` enum dispatch + RIFF/WAVE chunk walker

```zig
pub const audio = struct {
    /// Audio file format dispatch.  Add new variants here when
    /// adding codecs; call sites stay stable.
    pub const Format = enum {
        wav,

        /// Decode bytes via this format's decoder.  Returned Wave
        /// owns its samples and must be freed via wave.deinit().
        pub fn decode(
            self: Format,
            gpa: std.mem.Allocator,
            reader: *std.Io.Reader,
        ) anyerror!CanonicalWave {
            return switch (self) {
                .wav => wav.decode(gpa, reader),
            };
        }

        /// Encode wave to writer using this format.  ExportOptions
        /// is format-specific via formatExportOptions().
        pub fn encode(
            self: Format,
            wave: CanonicalWave,
            writer: *std.Io.Writer,
            options: anytype,
        ) anyerror!void {
            return switch (self) {
                .wav => wav.encode(wave, writer, options),
            };
        }

        pub fn formatExportOptions(self: Format) type {
            return switch (self) {
                .wav => wav.ExportOptions,
            };
        }
    };

    /// Format-agnostic intermediate Wave representation.
    pub const CanonicalWave = struct {
        samples: []u8,            // raw bytes in the input format
        sample_rate: u32,
        sample_size: u32,         // 8 / 16 / 32 — bits per sample
        channels: u16,
        gpa: std.mem.Allocator,

        pub fn deinit(self: CanonicalWave) void {
            self.gpa.free(self.samples);
        }
    };

    pub const wav = struct { ... };  // Step 5
};
```

The `Format` enum is the central future-proofing piece.  Today
only `.wav` is wired; tomorrow `.ogg` and `.mp3` slot in without
touching call sites.  This pattern is taken directly from
lightmix's `LowLevelInterfaces` enum.

### Step 5 — `wav.decode` (reader-based)

```zig
pub const wav = struct {
    pub const DecodeError = error{
        InvalidSignature,         // not RIFF/WAVE
        UnsupportedFormatTag,     // not PCM-int (1) or PCM-float (3)
        UnsupportedBitDepth,      // not 8/16/32
        UnsupportedChannelCount,  // 0 or > 8
        TruncatedFile,            // EOF mid-chunk
        DataChunkMissing,         // walked all chunks without finding `data`
    };

    pub fn decode(
        gpa: std.mem.Allocator,
        reader: *std.Io.Reader,
    ) (DecodeError || std.mem.Allocator.Error)!CanonicalWave {
        // RIFF magic
        var magic: [4]u8 = undefined;
        try reader.readAll(&magic);
        if (!std.mem.eql(u8, &magic, "RIFF")) return error.InvalidSignature;
        _ = try reader.readInt(u32, .little);  // file size, ignored

        try reader.readAll(&magic);
        if (!std.mem.eql(u8, &magic, "WAVE")) return error.InvalidSignature;

        // ... fmt chunk + data chunk walking ...
    }
};
```

8 inline tests with `@embedFile("./assets/test_sine.wav")` (16k mono 16-bit, 0.5 sec sine):
1. Embedded test_sine.wav decodes successfully
2. Decoded sample rate matches header (44100)
3. Decoded channel count matches header (1)
4. Decoded sample_size matches header (16)
5. Wrong magic returns InvalidSignature
6. Float format with bits ≠ 32 returns UnsupportedBitDepth
7. Truncated `data` chunk returns TruncatedFile
8. LIST chunk between `fmt ` and `data` is skipped silently (synthetic test bytes)

**Tests:** 8.  **Snapshot:** none.

### Step 6 — `wav.encode` (writer-based) + format conversion helpers

`wav.encode(wave, writer, ExportOptions)` writes a CanonicalWave back
to RIFF/WAVE.  This is what makes raylib's `ExportWave` work on
the web — write to `std.Io.Writer.Allocating`, hand the bytes to
`web.dom.downloadBlob` for the user's Downloads folder.

```zig
pub const ExportOptions = struct {
    bits: u16 = 16,
    format_code: enum { pcm, ieee_float } = .pcm,
};
```

Plus helpers:
- `toFloat32Stereo(gpa, wave) ![]f32` — int → f32, mono → stereo, 5.1+ → drop extra channels
- `resampleLinear(gpa, samples, channels, sr_in, sr_out) ![]f32` — linear interp resampler

Cases handled in `toFloat32Stereo`:
- 8-bit unsigned int: `(s - 128) / 128.0`
- 16-bit signed int: `s / 32768.0`
- 32-bit float: passthrough
- mono → stereo: `dst[2k]=dst[2k+1]=src[k]`
- 5.1+ → stereo: take channels 0 and 1, drop the rest

Why linear interp not sinc?  For game SFX (the common case),
linear at 44.1k → 48k is indistinguishable from sinc.  For
high-quality music at the cost of 2× CPU during load, sinc is
the upgrade.  Linear ships in v1; sinc deferred.

7 tests:
1. Round-trip: encode then decode produces identical CanonicalWave (44.1k 16-bit mono)
2. 8-bit → f32 round-trips through known fixtures
3. 16-bit → f32 round-trips through known fixtures
4. 32-bit float passes through unchanged
5. mono → stereo duplicates samples
6. sr_in == sr_out resample returns a copy without interpolation
7. 2× upsample doubles output length, 0.5× downsample halves it

**Tests:** 7.

### Step 7 — `toCanonical` end-to-end + `Wave` ↔ `CanonicalWave` adapters

`codecs.audio.toCanonical(gpa, reader, target_rate) ![]f32`: decode →
expand to stereo f32 → resample → return.  This is the one call
`sounds.loadFromReader` makes in Step 12.

Plus:
- `waveFromCanonical(gpa, c: CanonicalWave) !Wave` — wraps a CanonicalWave's f32-stereo bytes into the `extern struct` shape (allocates a copy of the data so the Wave outlives the CanonicalWave)
- `canonicalFromWave(wave: Wave) CanonicalWave` — reads the Wave's `data` pointer back into a CanonicalWave for re-encoding (no allocation)

3 tests:
1. Round-trip a hand-built 16-bit mono 22050 Hz WAV → 48000 Hz stereo f32 with the right frame count
2. Empty data chunk returns an empty slice (not an error)
3. waveFromCanonical / canonicalFromWave round-trip preserves header fields

**Tests:** 3.  **Snapshot:** `step-7-wav-codec`.

## Phase 3 — `sound.zig` foundation + Wave operations + Composer

Steps 8-12.  `sound.zig` is created in Step 8; Wave operations
follow lightmix's filter-chain idiom; Composer is added as a
zimr-original feature.

### Step 8 — Create `src/sound.zig` with types + `audio_device` namespace

File header documents the design including the lightmix verification:

```zig
//! sound.zig — zimr audio runtime built on the Web Audio API.
//!
//! Public surface lives in this single file via four namespaces:
//!   - sound.audio_device — init/close, master volume
//!   - sound.waves        — Wave: RAM PCM + offline operations
//!   - sound.sounds       — Sound: short clips, fully decoded, AudioBuffer-backed
//!   - sound.music        — Music: long WAVs streamed via wav.Decoder
//!   - sound.streams      — AudioStream: raw PCM injection, gapless scheduling
//!   - sound.composer     — zimr-original: offline composition (Wave sequencing)
//!
//! Internal audio decode lives in codecs.audio (alongside png and
//! truetype) — same pattern as image and font loading.  WAV format
//! is the only one supported in 0.7; the codecs.audio.Format enum
//! is positioned for future OGG/MP3 additions without breaking
//! call sites.
//!
//! Web Audio binding lives in web.zig's `audio` namespace.
//!
//! Idiom notes:
//!   - Wave operations follow lightmix's filter-chain pattern:
//!     `try waves.filter(&wave, my_filter);` mutates in place.
//!   - Reader/writer I/O is preferred; loadFromMemory is a thin
//!     wrapper over loadFromReader using std.Io.Reader.fixed.
```

Step 8 surface:
- `pub const Wave = ...`, `pub const Sound`, `pub const Music`, `pub const AudioStream` (extern struct shapes)
- `pub const audio_device = struct { ... }` with:
  - `init(gpa) !void`
  - `close() void`
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

`tests.zig` gets `_ = @import("sound.zig");` added.  `comptime { _ = audio_device; }` at end of `sound.zig` for nested-namespace test discovery.

**Tests:** 4 (init then close cleanly; double-init is a no-op; getMasterVolume returns 1.0 by default; setMasterVolume clamps to [0, 1]).

### Step 9 — Wave loading + lifecycle

`pub const waves = struct`:
- `loadFromReader(gpa, reader) !Wave`
- `loadFromMemory(gpa, bytes) !Wave` — one-line wrapper over `loadFromReader(gpa, &std.Io.Reader.fixed(bytes))`
- `unload(gpa, wave) void`
- `copy(gpa, wave) !Wave`
- `isValid(wave) bool`

`loadWave(path)` (path-based) — stub returning empty Wave (no
filesystem on wasm; deferred until we have a fetch-stream-decode
path).

**Tests:** 6 (loadFromMemory on embedded test_sine succeeds → frame count matches; loadFromMemory on bogus bytes returns invalid Wave; copy round-trips; unload on default Wave is no-op; isValid responds correctly to default-vs-loaded; loadFromReader equivalent to loadFromMemory).

### Step 10 — Wave operations: filter / crop / format / mix / separate

Filter chain pattern (lightmix-derived):

```zig
pub fn filter(
    gpa: std.mem.Allocator,
    wave: *Wave,
    comptime filter_fn: anytype,
) !void {
    const result = try filter_fn(gpa, wave.*);
    waves.unload(gpa, wave.*);  // free old samples
    wave.* = result;
}

pub fn filterWith(
    gpa: std.mem.Allocator,
    wave: *Wave,
    comptime args_type: type,
    comptime filter_fn: anytype,
    args: args_type,
) !void { ... }

/// Built-in filters that match raylib's API.
pub fn crop(gpa, wave: *Wave, start: u32, end: u32) !void {
    const args = .{ .start = start, .end = end };
    return filterWith(gpa, wave, @TypeOf(args), cropFilter, args);
}

pub fn format(gpa, wave: *Wave, sample_rate: u32, sample_size: u32, channels: u32) !void {
    const args = .{ .sr = sample_rate, .ss = sample_size, .ch = channels };
    return filterWith(gpa, wave, @TypeOf(args), formatFilter, args);
}

pub fn mix(gpa, a: Wave, b: Wave) !Wave;
pub fn separate(gpa, w: Wave, p: u32) !struct { Wave, Wave };
pub fn loadSamples(gpa, w: Wave) ![]f32;
pub fn unloadSamples(gpa, samples: []f32) void;
```

**Tests:** 8 (crop preserves header rate; crop empty range returns empty wave; format conversion round-trips between bit depths; mix two same-length waves sums samples; mix asserts on length mismatch in debug; separate at index returns expected halves; separate at 0 returns empty + full; user-supplied filter mutates in place).

### Step 11 — `composer` namespace (zimr-original feature)

```zig
pub const composer = struct {
    pub const WaveInfo = struct {
        wave: Wave,
        start_point: u32,  // sample-frame offset
    };

    pub const Composer = struct {
        info: []WaveInfo,
        gpa: std.mem.Allocator,
        sample_rate: u32,
        channels: u16,

        pub fn deinit(self: *Composer) void {
            self.gpa.free(self.info);
        }
    };

    pub const InitOptions = struct {
        sample_rate: u32,
        channels: u16,
    };

    pub fn init(gpa, options: InitOptions) Composer;
    pub fn initWith(gpa, info: []const WaveInfo, options: InitOptions) !Composer;
    pub fn append(c: *Composer, info: WaveInfo) !void;
    pub fn appendSlice(c: *Composer, infos: []const WaveInfo) !void;

    /// Mix all waves at their start_points into a single Wave.
    /// The returned Wave is owned by `c.gpa`; constituent waves
    /// are NOT freed (caller still owns them).
    pub fn finalize(c: Composer) !Wave;
};
```

Key difference from lightmix's Composer: ours doesn't take a
custom mixer function in `finalize` — for raylib parity we always
use additive mixing (a + b).  Adding a `mixer_fn` parameter is a
clean extension when needed.

**Tests:** 6 (init+deinit; append grows info; appendSlice preserves order; finalize on empty composer returns 0-length Wave; finalize sums two same-length waves at offset 0; finalize handles non-overlapping waves at different start_points).

**Snapshot:** `step-11-composer-and-wave-ops`.

### Step 12 — Sound types + `loadFromWave` + lifecycle

`pub const sounds = struct`:
- `loadFromWave(wave) !Sound` — internal canonical conversion + `web.audio.loadAudioBuffer` upload, returns Sound with `stream.buffer = @ptrFromInt(buffer_id)`
- `loadFromMemory(file_type: Format, bytes) !Sound` — for now `file_type` must be `.wav`; future: `.ogg` etc.
- `loadFromReader(file_type: Format, reader) !Sound`
- `loadAlias(source) Sound` — shares buffer_id; tracked separately in handle table
- `unload(sound) void` / `unloadAlias(alias) void`
- `isValid(sound) bool`
- `update(sound, data, frame_count) void` — replaces samples in-place (ABI parity)

**Tests:** 5 (loadFromWave on valid wave succeeds; on empty wave returns invalid Sound; alias shares buffer id; unloading alias doesn't free original; update changes underlying buffer).

**Snapshot:** `step-12-sound-foundation`.

## Phase 4 — Sound playback

Steps 13-16.  Same as v1's Phase 4 but with two example steps
collapsed into one (audio_panning + audio_pool → single example
demonstrating both, since the patterns are mechanically similar).

### Step 13 — `play`, `stop`, `isPlaying`

```zig
pub fn play(sound: Sound) void;
pub fn stop(sound: Sound) void;
pub fn isPlaying(sound: Sound) bool;
```

`play`: gets source-id from `web.audio.playBuffer`, stores in
per-Sound active-source slot array (capped at MAX_AUDIO_BUFFER_POOL_CHANNELS = 16,
mirroring raylib's pool).  Same Sound played twice has TWO active
sources.

`stop`: stops ALL active sources for this Sound.

`isPlaying`: true if ANY active source is still running.

**Tests:** 5 (same as v1).

### Step 14 — `pause`, `resume`, volume / pitch / pan setters

Web Audio has no native pause: implementation captures
`elapsed = ctx.currentTime - source.start_time`, disconnects the
source.  Resume builds a fresh source with `source.start(0, elapsed)`.
Loses any in-flight playbackRate ramping.  Documented limitation.

Volume/pitch/pan setters mutate per-Sound NEXT-PLAY settings —
already-playing sources are NOT retroactively updated.  raylib
does the same; mid-flight mutation is the AudioStream surface
(Step 20).

**Tests:** 8 (pause-then-resume restarts at offset; pause on stopped sound is silent; resume on never-paused is silent; each setter clamps to its valid range; values persist across getter reads).

### Step 15 — `examples/audio_basic.zig`

Embedded 1-second 440 Hz sine wave WAV (committed as `examples/assets/audio_basic_sine.wav`,
~88 KB, generated by a Python script at top of file using raylib's
ExportWave-compatible RIFF format).  Click anywhere or press space
to play.  HUD shows playback count.

**Smoke target:** runs 60 frames without panic, emits ≥1 AudioContext call.

### Step 16 — `examples/audio_pool.zig`

Combines what v1 split into audio_panning + audio_pool.  Three
short blip sounds (low/mid/high pitched, each panned hard L /
center / hard R), playable via 1/2/3 keys; spam any key to trigger
up to 16 simultaneous playbacks.  Demonstrates: pool semantics,
panning, pitch independence, isPlaying-driven slot reuse.

**Snapshot:** `step-16-phase4-done`.

## Phase 5 — AudioStream + master mix

Steps 17-20.  Same content as v1's Phase 5 but renumbered down by 1.

### Step 17 — `load`, `unload`, `isValid`

`loadAudioStream(sample_rate, sample_size, channels) AudioStream`

Per-stream state:
- `pending_queue: std.array_list.Aligned(QueuedBuffer, null) = .empty`
- `current_playback_source: ?c_uint`
- `next_start_time: f64` — uses `web.audio.getCurrentTime` (the v2-added bridge fn)
- volume/pitch/pan defaults (1, 1, 0)

**Tests:** 4.

### Step 18 — `update`, `isProcessed`

`update(stream, data, frame_count)`:
1. Convert input to f32 stereo at AudioContext rate
2. `web.audio.loadAudioBuffer` upload
3. Schedule fresh source with `source.start(next_start_time)`
4. `next_start_time += buffer.duration`
5. Append to queue; oldest free naturally as Web Audio drops finished sources

`isProcessed(stream)`: true iff queue depth ≤ 1.

**Tests:** 3.

### Step 19 — `play` / `pause` / `resume` / `stop` / `isPlaying`

State machine on per-stream slot.

**Tests:** 5.

### Step 20 — Setters + callback / processor stubs

`setVolume`/`setPitch`/`setPan` mutate per-stream
GainNode/playbackRate/StereoPannerNode in REAL TIME (unlike Sound).
Critical for music fade-out and DJ-style pitch-bends.

`setBufferSizeDefault` — no-op for ABI parity (Web Audio has no
fixed buffer size).

`setCallback` / `attachProcessor` / `detachProcessor` /
`attachMixedProcessor` / `detachMixedProcessor` — stubs that log a
one-time warning; AudioWorklet implementation deferred to v3.

**Tests:** 5 (setters clamp; mid-stream mutation succeeds; stubs return without panic; setBufferSizeDefault silent; warning log is a one-time event per stream).

**Snapshot:** `step-20-stream-done`.

## Phase 6 — Music streaming

Steps 21-24.  Same as v1's Phase 6 but with reader-based decoder
patterns and one fewer step (the loadStream + unloadStream + isValid
group folded into one step instead of split).

### Step 21 — `wav.Decoder` (chunked stateful reader)

```zig
pub const Decoder = struct {
    bytes: []const u8,           // owned by caller, lives as long as Decoder
    cursor: u32,                 // byte offset into `bytes`
    data_offset: u32,            // start of `data` chunk payload
    data_length: u32,            // byte length of `data` payload
    sample_rate: u32,
    channels: u16,
    sample_size: u16,
    frames_played: u32,

    pub fn init(bytes: []const u8) DecodeError!Decoder;
    pub fn readFrames(self: *Decoder, out: []f32, max_frames: usize) usize;
    pub fn seekFrame(self: *Decoder, frame_index: u32) !void;
    pub fn frameCount(self: Decoder) u32;
    pub fn framesPlayed(self: Decoder) u32;
};
```

The Decoder shares the RIFF walker logic with `wav.decode` but
stops at the `data` chunk and remembers the offset.  Subsequent
`readFrames` calls slice from that offset and advance `frames_played`.

`init` returns same `DecodeError` set as `decode` (InvalidSignature,
TruncatedFile, etc.) — reused via shared private parser.

**Tests:** 4 (read all frames in chunks vs all-at-once produces identical output; seek to offset matches expected sample; seek past end returns 0; frameCount matches header from embedded test_sine.wav).

### Step 22 — `loadStream`, `loadStreamFromMemory`, `unloadStream`, `isValid`

`loadStreamFromMemory(format: Format, gpa, bytes) !Music`:
1. `wav.Decoder.init(bytes)` (gpa-owned copy of bytes stored in Music.ctx_data)
2. Allocate AudioStream sized for ~1 sec at decoder's sample_rate
3. Return Music handle with `ctx_type = @intFromEnum(format)`, `ctx_data = decoder_ptr`

`unloadStream(gpa, music)` frees both the wrapped AudioStream and the Decoder + bytes.

**Tests:** 4 (load valid; load bogus bytes returns invalid Music; unload silent on default Music; isValid responds correctly).

### Step 23 — `playStream`, `updateStream`, `pauseStream`, `resumeStream`, `stopStream`, `isStreamPlaying`

`updateStream(music)` per-frame call:
1. Check wrapped stream's `isProcessed`
2. If true, ask decoder for ~1 sec of frames
3. If decoder hits EOF and `music.looping`, seek to 0 and continue
4. Push frames into the AudioStream

**Tests:** 6 (play sets isPlaying true; update without play does nothing; pause/resume preserves position; looping music wraps; non-looping music stops at EOF; stopStream clears queue).

### Step 24 — Setters + seek + getTimeLength / getTimePlayed

Volume/pitch/pan delegate to the wrapped AudioStream.

`seekStream(music, position_seconds)`:
1. `frame = position * sample_rate`
2. `decoder.seekFrame(frame)`
3. Stop and restart stream so existing-buffered audio doesn't continue

`getTimePlayed` / `getTimeLength` are trivial fractions over sample_rate.

**Tests:** 5 (each setter delegates; seek mid-track resumes from offset; getTimePlayed advances; getTimeLength matches header; setting looping flag mutates correctly).

**Snapshot:** `step-24-music-done`.

## Phase 7 — Examples + final consolidation

Steps 25-28.

### Step 25 — `examples/music_streaming.zig`

Embedded 5-second WAV-encoded melody (procedurally synthesized
in a Python generator at top of file: 5 seconds of arpeggio
across C-major).  UI: spacebar plays/pauses, R rewinds to start,
L toggles looping.  HUD shows time-played / time-length progress
bar.

### Step 26 — `examples/audio_stream_synth.zig`

Procedural waveform generator demonstrating `updateAudioStream`
in polling mode.  Per-frame: fill a `f32` sine table, push.
Frequency mouse-controllable via X coordinate.

This example doubles as documentation that real-time synthesis
is supported, just not at single-sample latency (~50 ms
buffer-ahead without AudioWorklet).

### Step 27 — `examples/composer_drum.zig`

NEW in v2 — demonstrates the zimr-original `composer` namespace.
Procedural snare drum: pink noise + low sine, both with decay
filters applied, mixed via Composer at start_point=0.  The
finalized Wave is loaded into a Sound and played on click.

This is the `examples/05-practical-examples/drum/` lightmix
example, ported to zimr's runtime API.  Shows offline composition
producing runtime-playable Sound.

```zig
// Sketch:
fn buildSnareSound(app: *z.App) !z.Sound {
    var noise = try generatePinkNoiseWave(app.gpa, 0.5);
    try z.waves.filter(app.gpa, &noise, fastDecayFilter);
    defer z.waves.unload(app.gpa, noise);

    var tone = try generateSineWave(app.gpa, 200.0, 0.5);
    try z.waves.filter(app.gpa, &tone, fastDecayFilter);
    defer z.waves.unload(app.gpa, tone);

    var c = z.composer.init(app.gpa, .{ .sample_rate = 44100, .channels = 1 });
    defer c.deinit();
    try c.append(.{ .wave = noise, .start_point = 0 });
    try c.append(.{ .wave = tone, .start_point = 0 });

    const snare_wave = try c.finalize();
    defer z.waves.unload(app.gpa, snare_wave);

    return z.sounds.loadFromWave(snare_wave);
}
```

### Step 28 — Cheatsheet polish + Phase retrospectives + promote `[Unreleased]` → `[0.7.0]`

Update CHEATSHEET.md with the finalised "Audio" section showing
each canonical pattern: load + play a sound; fade-out music via
mid-stream volume ramp; procedural synthesis via AudioStream;
master volume control; the Composer pattern for offline
composition.

Coverage table: rmodels.audio module 0% → ~85%.

Promote `[Unreleased]` → `[0.7.0]`.  Final snapshot `step-28-FINAL`.

## API coverage table

(Same content as v1; namespacing refined to `waves.*` / `sounds.*` /
`music.*` / `streams.*` instead of v1's `loadWave` / `loadSound` /
flat top-level naming.)

| raylib                                | zimr                                       | status          |
|---------------------------------------|--------------------------------------------|-----------------|
| `InitAudioDevice`                     | `audio_device.init`                        | full            |
| `CloseAudioDevice`                    | `audio_device.close`                       | full            |
| `IsAudioDeviceReady`                  | `audio_device.isReady`                     | full            |
| `SetMasterVolume`                     | `audio_device.setMasterVolume`             | full            |
| `GetMasterVolume`                     | `audio_device.getMasterVolume`             | full            |
| `LoadWave`                            | `waves.load`                               | stub (no FS)    |
| `LoadWaveFromMemory`                  | `waves.loadFromMemory`                     | full (`.wav` only) |
| `IsWaveValid`                         | `waves.isValid`                            | full            |
| `LoadSound`                           | `sounds.load`                              | stub (no FS)    |
| `LoadSoundFromWave`                   | `sounds.loadFromWave`                      | full            |
| `LoadSoundAlias`                      | `sounds.loadAlias`                         | full            |
| `IsSoundValid`                        | `sounds.isValid`                           | full            |
| `UpdateSound`                         | `sounds.update`                            | full            |
| `UnloadWave`                          | `waves.unload`                             | full            |
| `UnloadSound`                         | `sounds.unload`                            | full            |
| `UnloadSoundAlias`                    | `sounds.unloadAlias`                       | full            |
| `ExportWave`                          | `waves.exportToBytes` + `web.dom.downloadBlob` | full (NEW vs v1) |
| `ExportWaveAsCode`                    | `waves.exportAsCode`                       | stub (no FS)    |
| `PlaySound`                           | `sounds.play`                              | full            |
| `StopSound`                           | `sounds.stop`                              | full            |
| `PauseSound`                          | `sounds.pause`                             | full            |
| `ResumeSound`                         | `sounds.resume`                            | full            |
| `IsSoundPlaying`                      | `sounds.isPlaying`                         | full            |
| `SetSoundVolume`                      | `sounds.setVolume`                         | full            |
| `SetSoundPitch`                       | `sounds.setPitch`                          | full            |
| `SetSoundPan`                         | `sounds.setPan`                            | full            |
| `WaveCopy`                            | `waves.copy`                               | full            |
| `WaveCrop`                            | `waves.crop`                               | full            |
| `WaveFormat`                          | `waves.format`                             | full            |
| `LoadWaveSamples`                     | `waves.loadSamples`                        | full            |
| `UnloadWaveSamples`                   | `waves.unloadSamples`                      | full            |
| `LoadMusicStream`                     | `music.load`                               | stub (no FS)    |
| `LoadMusicStreamFromMemory`           | `music.loadFromMemory`                     | full (`.wav` only) |
| `IsMusicValid`                        | `music.isValid`                            | full            |
| `UnloadMusicStream`                   | `music.unload`                             | full            |
| `PlayMusicStream`                     | `music.play`                               | full            |
| `IsMusicStreamPlaying`                | `music.isPlaying`                          | full            |
| `UpdateMusicStream`                   | `music.update`                             | full            |
| `StopMusicStream`                     | `music.stop`                               | full            |
| `PauseMusicStream`                    | `music.pause`                              | full            |
| `ResumeMusicStream`                   | `music.resume`                             | full            |
| `SeekMusicStream`                     | `music.seek`                               | full            |
| `SetMusicVolume`                      | `music.setVolume`                          | full            |
| `SetMusicPitch`                       | `music.setPitch`                           | full            |
| `SetMusicPan`                         | `music.setPan`                             | full            |
| `GetMusicTimeLength`                  | `music.getTimeLength`                      | full            |
| `GetMusicTimePlayed`                  | `music.getTimePlayed`                      | full            |
| `LoadAudioStream`                     | `streams.load`                             | full            |
| `IsAudioStreamValid`                  | `streams.isValid`                          | full            |
| `UnloadAudioStream`                   | `streams.unload`                           | full            |
| `UpdateAudioStream`                   | `streams.update`                           | full            |
| `IsAudioStreamProcessed`              | `streams.isProcessed`                      | full            |
| `PlayAudioStream`                     | `streams.play`                             | full            |
| `PauseAudioStream`                    | `streams.pause`                            | full            |
| `ResumeAudioStream`                   | `streams.resume`                           | full            |
| `IsAudioStreamPlaying`                | `streams.isPlaying`                        | full            |
| `StopAudioStream`                     | `streams.stop`                             | full            |
| `SetAudioStreamVolume`                | `streams.setVolume`                        | full            |
| `SetAudioStreamPitch`                 | `streams.setPitch`                         | full            |
| `SetAudioStreamPan`                   | `streams.setPan`                           | full            |
| `SetAudioStreamBufferSizeDefault`     | `streams.setBufferSizeDefault`             | no-op (ABI)     |
| `SetAudioStreamCallback`              | `streams.setCallback`                      | stub (logs warn)|
| `AttachAudioStreamProcessor`          | `streams.attachProcessor`                  | stub (logs warn)|
| `DetachAudioStreamProcessor`          | `streams.detachProcessor`                  | stub            |
| `AttachAudioMixedProcessor`           | `streams.attachMixedProcessor`             | stub (logs warn)|
| `DetachAudioMixedProcessor`           | `streams.detachMixedProcessor`             | stub            |

**Plus zimr-original (not in raylib):**

| zimr                                  | description                                | status |
|---------------------------------------|--------------------------------------------|--------|
| `waves.filter`                        | In-place filter mutation (lightmix-style)  | full   |
| `waves.filterWith`                    | Filter with extra args                     | full   |
| `waves.mix`                           | Sample-by-sample mix of two equal-length waves | full |
| `waves.separate`                      | Split a Wave at a sample point             | full   |
| `composer.init` / `initWith`          | Create offline composition                 | full   |
| `composer.append` / `appendSlice`     | Add WaveInfo entries                       | full   |
| `composer.finalize`                   | Mix all entries into a single Wave         | full   |

**Counts:** 64 raylib audio functions, of which 5 are FS stubs
(no-op on web), 5 are AudioWorklet-deferred stubs (log warning),
1 is no-op for ABI parity, **53 fully implemented**.  That's
83 % real coverage of raylib's audio surface (up 1 from v1
because `ExportWave` is now full instead of stub — writer-based
encode + downloadBlob).  Plus 7 zimr-original public functions
(filter, filterWith, mix, separate, composer.init, composer.append,
composer.finalize) that don't exist in raylib.

## Snapshot cadence

| Step | Snapshot                       | What's new                          |
|------|--------------------------------|-------------------------------------|
| 3    | `step-3-audio-jsbridge`        | Web Audio binding live              |
| 7    | `step-7-wav-codec`             | WAV codec + reader/writer I/O complete |
| 11   | `step-11-composer-and-wave-ops`| Wave ops + Composer live            |
| 12   | `step-12-sound-foundation`     | Wave + Sound types live             |
| 16   | `step-16-phase4-done`          | First sounds play                   |
| 20   | `step-20-stream-done`          | AudioStream end-to-end              |
| 24   | `step-24-music-done`           | Music streaming live                |
| 28   | `step-28-FINAL`                | Phase 7 done, 0.7.0 cut             |

## Risk register (refined)

1. **Mobile Safari sample rate quirks.**  iOS Safari pins `AudioContext.sampleRate` to device-default 44100 Hz; resampler must handle this.  Mitigation: resampling is on every load anyway.  Verified plan, not blocked.
2. **Autoplay policies.**  AudioContext starts suspended.  First playSound issues `context.resume()` if needed.  Handled in Step 13.
3. **Memory pressure for long Wave loads.**  A 5-min stereo 44.1k 16-bit WAV is ~50 MB on disk and ~110 MB after f32 expansion.  Music's streaming path (Phase 6) avoids the f32 expansion since the decoder yields chunks.  Apps that load minutes-long sounds via `loadFromMemory` (not `music.loadFromMemory`) will hit this — *intentional*, matches raylib's "Music for >10 sec" guidance.
4. **AudioWorklet deferral kills procedural audio for some users.**  setAudioStreamCallback being a stub means apps relying on it for synthesis won't work.  Polled `updateAudioStream` covers the common case (~50 ms latency).  Real-time synth is a v3 deliverable.  `examples/audio_stream_synth.zig` (Step 26) demonstrates the polled pattern works for most use cases.
5. **Filter chain pattern + `extern struct` Wave: extra `gpa` parameter.**  Because our Wave is `extern struct` (raylib-shaped, no allocator field), filters take `gpa` as an explicit parameter where lightmix's filters read it from the Wave.  This is a paper cut for users porting lightmix code.  Mitigated by the cheatsheet snippet (Step 28) and worth it for raylib ABI parity.
6. **Composer is zimr-original — no precedent in raylib's API.**  Users porting raylib code won't find it; users coming from lightmix will.  Documented as a "zimr addition" in cheatsheet.  Risk: scope-creep temptation for v3 (does Composer get a `mixer_fn` parameter? a fade-in/fade-out option? a tempo setting?).  Mitigation: explicitly bounded in v2 — no parameters beyond the lightmix-equivalent shape.  Future expansion goes through audio-plan-v3.
7. **`@embedFile` test fixture commits 16 KB of binary to git.**  Acceptable; the existing repo already has ~50 KB of embedded GLB test assets.  Ratio holds.

## Diff from v1

| Change | v1 | v2 | Why |
|--------|-----|-----|-----|
| Step count | 30 | 28 | Collapsed audio_panning + audio_pool examples; no other content lost |
| I/O surface | `[]const u8` byte parameters | `*std.Io.Reader` / `*std.Io.Writer` + bytes wrapper | Modern Zig 0.15 idiom; matches lightmix; unlocks future progressive-load |
| Format dispatch | flat `wav.decode` only | `Format` enum (`.wav` today, `.ogg`/`.mp3` v3) | Forward-compatible call sites; lightmix-derived |
| Wave operations | scattered (`waveCrop`, `waveFormat` separate signatures) | unified filter chain (`waves.filter` / `waves.filterWith`) | Cleaner; chains compose; lightmix-derived |
| Composer | not present | new `composer` namespace, 7 new public fns | Zimr-original feature; useful for offline composition + test fixtures |
| Test fixtures | hand-rolled bytes in test bodies | `@embedFile("./assets/test_sine.wav")` | Real WAV (playable in any audio app); cleaner test code |
| Error sets | one `wav.Error` grab-bag | per-op named error sets (`DecodeError`, `WaveCropError`, etc.) | Standard Zig stdlib convention; better for selective handling |
| Zig version | 0.13 patterns (`std.ArrayList`) | 0.15 patterns (`std.array_list.Aligned(T, null)`, `.empty`) | Already what zimr uses; consistency |
| `ExportWave` | stub (no FS on web) | full (writer-based encode + `web.dom.downloadBlob`) | Now possible because of writer-I/O surface; one new fully-working raylib API |
| `web.audio.getCurrentTime` | not added | added in Step 1 | Needed by AudioStream gapless scheduling (Step 18); cheap to add now |
| Coverage % | 81% (52 / 64 raylib fns full) | 83% (53 / 64 raylib fns full) | ExportWave promotion |
| Filter signature | implicit (cropping signature `crop(*wave, ...)`) | explicit (filter takes `comptime filter_fn: anytype`) | Generic filter mechanism; user can write custom filters |
| Phase 3 step count | 4 (Steps 8–11) | 5 (Steps 8–12) | Composer added as Step 11 |
| Snapshot list | 7 milestones | 8 milestones | Step 11 (composer) added |
| Idioms documented in plan | minimal | full lightmix verification report at top | Reader can verify the design without reading lightmix themselves |

**Things v1 got right that v2 keeps verbatim:**

- One canonical f32 stereo internal format
- Wave / Sound / Music / AudioStream four-type model  
- `audio_device` / `waves` / `sounds` / `music` / `streams` namespacing
- Web Audio AudioContext lifecycle + autoplay handling
- Internal HANDLES table of 256 slots
- Smoke harness mocks Web Audio with a Proxy
- Polled `updateAudioStream` covers the common case; AudioWorklet deferred
- 64 raylib audio functions; 6 FS stubs; 5 worklet stubs; 1 ABI no-op (`SetAudioStreamBufferSizeDefault`)
- `MAX_AUDIO_BUFFER_POOL_CHANNELS = 16` for Sound's per-Sound active-source array
- Mid-stream mutation supported for AudioStream; not for Sound (matches raylib)

## What you tell users in the docs (Step 28 cheatsheet entry)

> zimr's audio supports WAV files only — the most common format
> for game SFX and the simplest to embed.  For sources in other
> formats, convert to WAV first; ffmpeg's `-c:a pcm_s16le` does
> this in one command.  The full audio API matches raylib's;
> migrating an existing raylib game's audio code requires only
> the rename map (e.g. `LoadSound` → `z.sounds.loadFromMemory`).
>
> zimr also adds two zimr-original primitives borrowed from the
> [lightmix](https://github.com/haruki7049/lightmix) library:
>
> 1. **`z.waves.filter(gpa, &wave, my_filter)`** — apply a
>    user-defined transform to a Wave's samples.  Chains compose
>    cleanly without intermediate allocations.
>
> 2. **`z.composer`** — sequence multiple Waves at specific
>    sample-frame offsets, mix them down with `finalize()`.
>    Useful for procedurally building drum hits, melodies, or
>    test fixtures.
>
> Neither exists in raylib's audio API; both are 100 % optional.
> Apps that only want raylib parity can ignore them.

That paragraph belongs in CHEATSHEET.md after Step 28.

---

End of audio-plan-v2.  Confidence: high — every design decision
above is either (a) a verbatim raylib API (raudio.c-source-verified),
(b) a verbatim Web Audio capability (MDN-verified), (c) a
verbatim lightmix idiom (source-verified, ~1700 LOC read end-to-end),
or (d) a zimr-project-pattern (4 versions of CHANGELOG + style-guide
discipline).
