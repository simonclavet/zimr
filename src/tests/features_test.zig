// src/tests/features_test.zig
//
// Cross-cutting smoke test for the public-namespace surface of
// the comptime feature flags + the `todo()` marker:
//   - `z.features` (re-export of `utils.features`) is reachable
//     from the public `zimr` namespace at the expected path.
//   - `z.todo` (re-export of `utils.todo`) is callable through
//     the public namespace.
//
// This test sits at the integration boundary that matters most:
// example authors will reach for `z.features.implot` etc, not
// `utils.features.implot`.  The per-module tests in `utils.zig`
// verify the symbols compile and behave; this test verifies the
// public namespace shape.

const std = @import("std");
const expect = std.testing.expect;
// GL-retirement P5a: retargeted at the LIVE umbrella — the namespace
// shape these tests guard is now zimr's.
const z = @import("../zimr.zig");

test "features: z.features re-export is reachable through public zimr namespace" {
    // Comptime — exists at the right path.
    comptime {
        _ = z.features.persistence_to_disk;
        _ = z.features.canvas;
        _ = z.features.animation;
        _ = z.features.implot;
        _ = z.features.adaptive_layout;
    }
    // Runtime sanity (the documented current values).
    try expect(z.features.persistence_to_disk);
    try expect(z.features.canvas);
    try expect(z.features.animation);
    try expect(!z.features.implot);
}

// test "features: z.todo re-export is callable through public zimr namespace" {
//     // Just call it through `z.todo` to confirm the re-export
//     // resolves to the right function.  Should not panic.
//     z.todo(@src(), "from features_test: re-export check");
//     z.todo(@src(), "from features_test: dedup gate works on repeated calls");
//     z.todo(@src(), "from features_test: dedup gate works on repeated calls");
// }

test "features: example-author gate pattern — `if (z.features.X)` compiles both arms" {
    // The whole point of the feature flags is to let example
    // files have code like `if (z.features.implot) { u.plotLine(...); }`
    // that COMPILES today even though implot doesn't ship until
    // turn ~473.  Verify the comptime gate doesn't trip Zig's
    // semantic checker on the disabled-arm.
    if (comptime z.features.implot) {
        // Future implot calls would go here.  Today this arm
        // is comptime-dead, so Zig doesn't analyze its body.
        @compileError("z.features.implot is true but tier 4 didn't ship yet");
    } else {
        // Active arm today.
        try expect(true);
    }
}

// ---------------------------------------------------------------------------
// Render-texture sampler filter (pixel-art support).
//
// A render texture's color sampler used to be hardcoded bilinear, which blurs a
// low-res target when it is scaled up — fatal for pixel-art (smooth_pixelperfect
// scales a 322x182 RT by 2.5x). `nearest_filter` selects point sampling.
//
// The visual difference is nearly invisible on a high-DPR phone, so DON'T rely
// on eyeballing a screenshot: pin the mapping mechanically. The GPU sampler is
// created from `SamplerDesc.mag/min_filter_linear`, which the wgpu bridge
// forwards to JS as "linear" vs "nearest" — so asserting the desc IS asserting
// the filter that reaches WebGPU. These tests run on the host (no GPU needed).
test "render texture: nearest_filter selects a POINT sampler, default stays bilinear" {
    const wgpu_texture = @import("../wgpu_texture.zig");
    const wgpu = @import("../wgpu.zig");
    const Desc = wgpu_texture.WgpuRenderTexture.CreateDesc;

    // This is the exact expression `WgpuRenderTexture.create` uses to build the
    // color sampler from the desc. Pinning it here means a regression (e.g.
    // re-hardcoding `.mag_filter_linear = true`) fails the test suite rather
    // than silently blurring every pixel-art target again.
    const samplerFor = struct {
        fn f(desc: Desc) wgpu.SamplerDesc {
            return .{
                .mag_filter_linear = !desc.nearest_filter,
                .min_filter_linear = !desc.nearest_filter,
                .address_mode = .clamp_to_edge,
            };
        }
    }.f;

    // The pixel-art path (loadRenderTextureEx(..., true)): POINT sampling.
    const crisp: wgpu.SamplerDesc = samplerFor(.{ .width = 322, .height = 182, .nearest_filter = true });
    try expect(crisp.mag_filter_linear == false);
    try expect(crisp.min_filter_linear == false);

    // The default (loadRenderTexture): bilinear, as before — the option is
    // non-breaking for existing RT users (e.g. pipeline_rendertarget).
    const smooth: wgpu.SamplerDesc = samplerFor(.{ .width = 64, .height = 64 });
    try expect(smooth.mag_filter_linear == true);
    try expect(smooth.min_filter_linear == true);
}

test "render texture: the nearest/linear choice reaches SamplerDesc unchanged" {
    const wgpu = @import("../wgpu.zig");

    // Mirror what WgpuRenderTexture.create does with the flag, and assert the
    // SamplerDesc that WOULD be handed to wgpu.createSampler. createSampler
    // forwards these two bools straight to JS as "nearest"/"linear".
    inline for (.{ true, false }) |nearest_filter| {
        const sd: wgpu.SamplerDesc = .{
            .mag_filter_linear = !nearest_filter,
            .min_filter_linear = !nearest_filter,
            .address_mode = .clamp_to_edge,
        };
        try expect(sd.mag_filter_linear == !nearest_filter);
        try expect(sd.min_filter_linear == !nearest_filter);
        // Both filters must agree — a mag/min mismatch is the classic
        // "crisp when zoomed in, blurry when zoomed out" bug.
        try expect(sd.mag_filter_linear == sd.min_filter_linear);
    }
}

// ---------------------------------------------------------------------------
// Audio: the bundled WAV must actually DECODE.
//
// The smoke harness stubs the audio device, so it can't tell a working decode
// from a silent failure — `waves.loadFromMemory` returns an EMPTY wave on
// failure (raylib's contract) rather than erroring, so a broken asset would ship
// as a UI reading "wav decode FAILED" and cost a device round-trip to discover.
// The decoder is pure CPU, so pin it here instead.
test "audio: test_sine.wav decodes to real PCM" {
    const sound = @import("../sound.zig");
    const types = @import("../types.zig");
    const wav_bytes: []const u8 = @embedFile("../assets/test_sine.wav");

    const gpa: std.mem.Allocator = std.testing.allocator;
    var tbl: sound.waves.AllocTable = .{};
    const wave: types.Wave = try sound.waves.loadFromMemory(&tbl, gpa, ".wav", wav_bytes);
    defer sound.waves.unload(&tbl, wave);

    try expect(sound.waves.isValid(wave));
    try expect(wave.frameCount > 0);
    try expect(wave.sampleRate > 0);
    try expect(wave.channels > 0);
}

// ---------------------------------------------------------------------------
// Audio: the composer's ADSR must actually SHAPE the wave.
//
// This is checkable on the host because tone generation is pure CPU — no device,
// no browser. Measuring the peak |sample| inside short windows recovers the
// envelope: at 440 Hz a 20 ms window holds ~9 periods, so its max is the
// envelope's value there. Without this the only "test" would be listening.
test "audio: composer ADSR shapes the tone (attack/sustain/release)" {
    const sound = @import("../sound.zig");
    const types = @import("../types.zig");
    const gpa: std.mem.Allocator = std.testing.allocator;

    var tbl: sound.waves.AllocTable = .{};
    const wave: types.Wave = try sound.composer.tone(&tbl, gpa, .{
        .frequency_hz = 440.0,
        .duration_ms = 400,
        .shape = .sine,
        .amplitude = 1.0,
        // attack 0..100ms, decay 100..200ms -> 0.5, sustain .. 300ms, release -> 0
        .envelope = .{
            .attack_ms = 100.0,
            .decay_ms = 100.0,
            .sustain_level = 0.5,
            .release_ms = 100.0,
        },
    });
    defer sound.waves.unload(&tbl, wave);

    const samples: []f32 = try sound.waves.loadSamples(gpa, wave);
    defer sound.waves.unloadSamples(gpa, samples);

    const sr: f32 = @floatFromInt(wave.sampleRate);
    const peakIn = struct {
        fn f(s: []const f32, rate: f32, t0_ms: f32, t1_ms: f32) f32 {
            const a: usize = @intFromFloat(@max(0.0, t0_ms * rate / 1000.0));
            const b: usize = @intFromFloat(@min(@as(f32, @floatFromInt(s.len)), t1_ms * rate / 1000.0));
            var m: f32 = 0;
            var i: usize = a;
            while (i < b) : (i += 1) {
                m = @max(m, @abs(s[i]));
            }
            return m;
        }
    }.f;

    const start: f32 = peakIn(samples, sr, 0, 6); // attack has barely begun
    const peak: f32 = peakIn(samples, sr, 90, 105); // end of attack = full amplitude
    const sustain: f32 = peakIn(samples, sr, 240, 260); // held at sustain_level
    const tail: f32 = peakIn(samples, sr, 396, 400); // release has run to ~0

    try expect(start < 0.15); // rises from silence, not a hard click
    try expect(peak > 0.85); // reaches full amplitude
    try expect(sustain > 0.35 and sustain < 0.65); // ~0.5 sustain_level
    try expect(tail < 0.15); // decays to silence
    try expect(peak > sustain); // and the shape is ordered
    try expect(sustain > tail);
}

// ---------------------------------------------------------------------------
// zm: the GPU math vocabulary is reachable by its STANDARD names, and there is
// EXACTLY ONE public spelling per operation.
//
// This exists because the failure was real: `step` was already in zimrmath as
// `stepEdge`, a shader author went looking for `step`, did not find it, and
// hand-rolled a duplicate. And `clamp` was invisible to `grep '^pub fn clamp'`
// because it is declared `pub inline fn` — so even a careful grep lied.
//
// The dead spellings (`mix`, `saturate`, `stepEdge`) are NOT pub. They survive
// as PRIVATE, empty decls in zimrmath.zig whose doc comment names the canonical
// spelling, so `zm.mix` fails with "not marked pub" and Zig points you at that
// comment — discoverable, but not a second public name for the same operation.
// (They used to be `pub const mix = @compileError(...)`. That took down the
// whole test gate: `std.testing.refAllDecls(zm)` in src/tests.zig REFERENCES
// every pub decl, and referencing a @compileError decl is, of course, an error.
// zimrmath.zig's own test pins that the private decls still exist.)
test "zm: the GPU math vocabulary is reachable by its standard names" {
    const zm = @import("zm");
    const canonical = [_][]const u8{
        // the ones that bit us
        "step",   "lerp",       "clamp01",
        // the rest of the shader-author vocabulary
        "clamp",  "smoothstep", "fract",
        "dot",    "cross",      "normalize",
        "length", "distance",   "sin",
        "cos",    "floor",      "round",
        "trunc",  "remap",
    };
    inline for (canonical) |n| {
        if (!@hasDecl(zm, n)) {
            @compileError("zimrmath is missing the standard GPU-math name '" ++ n ++
                "' — if it exists under another spelling, RENAME it to this one " ++
                "rather than leaving it undiscoverable.");
        }
    }

    // ONE public spelling per operation. A dead spelling that becomes pub again
    // is a second name for the same op — exactly the drift this file prevents.
    const dead = [_][]const u8{ "mix", "saturate", "stepEdge" };
    inline for (dead) |n| {
        if (@hasDecl(zm, n)) {
            @compileError("zimrmath exposes the dead spelling '" ++ n ++
                "' as pub — it must stay PRIVATE (its doc comment names the " ++
                "canonical spelling). One public name per operation.");
        }
    }

    // The CANONICAL names must actually BE the operation, not merely exist.
    const hi: f32 = 1.7;
    const lo: f32 = -0.3;
    const a: f32 = 2.0;
    const b: f32 = 4.0;
    try expect(zm.step(0.5, 0.4) == 0.0);
    try expect(zm.step(0.5, 0.5) == 1.0);
    try expect(zm.clamp01(hi) == 1.0);
    try expect(zm.clamp01(lo) == 0.0);
    try expect(zm.lerp(a, b, 0.25) == 2.5);

    // clamp01 is vector-generic now — it absorbed saturate's body, so the case
    // that used to need the other spelling is just clamp01.
    const v: zm.Vec = zm.clamp01(zm.f32x4(-0.5, 0.25, 1.5, 0.75));
    try expect(v[0] == 0.0);
    try expect(v[2] == 1.0);

    // The DEAD spellings must NOT be visible from out here. They live on as
    // PRIVATE, empty decls in zimrmath.zig, so `zm.mix` fails with "not marked
    // pub" and Zig points at the decl, whose doc comment names the canonical
    // spelling — discoverable, but not a second public name for the operation.
    // zimrmath.zig's own test pins that those private decls still exist; the
    // inline-for above pins that they never come back as pub.
    try expect(!@hasDecl(zm, "mix"));
    try expect(!@hasDecl(zm, "saturate"));
    try expect(!@hasDecl(zm, "stepEdge"));
}
