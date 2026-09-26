//! shader_effects - raylib's 2D texture-shader examples, gathered into
//! one live gallery.
//!
//! Covers four of their `shaders_*` demos with one FS file each:
//!
//!   grade    -> `shaders_color_correction` (and, at saturation -1,
//!              `shaders_texture_grayscale` for free)
//!   waves    -> `shaders_texture_waves`
//!   outline  -> `shaders_texture_outline`
//!   palette  -> `shaders_palette_switch`
//!
//! Where raylib filters a static PNG, the gallery filters a LIVE scene:
//! bouncing balls, spinning slabs and a big label drawn by the 2D
//! renderer into an offscreen texture every frame (on a TRANSPARENT
//! clear - the outline effect keys on alpha).  The effect pass is a
//! fullscreen quad through `deferred_shading_vs` - reused yet again -
//! with the chosen effect FS, into a second texture that's blitted to
//! screen.  Sliders are contextual per effect; the palette has a few
//! tables to cycle, which IS the raylib demo.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");

const Color = zm.Color;
const Vec2 = zm.Vec2;
const clamp = zm.clamp;
const float = zm.float;

const fx = z.effect_shaders;

pub var zimr_app: z.App = .{};

const shading_vs_wgsl = @embedFile("deferred_shading_vs.wgsl");
const grade_fs_wgsl = @embedFile("effect_grade_fs.wgsl");
const wave_fs_wgsl = @embedFile("effect_wave_fs.wgsl");
const outline_fs_wgsl = @embedFile("effect_outline_fs.wgsl");
const palette_fs_wgsl = @embedFile("effect_palette_fs.wgsl");
const spotlight_fs_wgsl = @embedFile("effect_spotlight_fs.wgsl");
const tiling_fs_wgsl = @embedFile("effect_tiling_fs.wgsl");
const sieve_fs_wgsl = @embedFile("effect_sieve_fs.wgsl");
const ascii_fs_wgsl = @embedFile("effect_ascii_fs.wgsl");
const cubes_fs_wgsl = @embedFile("effect_cubes_fs.wgsl");
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const GradeUbo = @FieldType(fx.grade_fs.Io, "u");
const WaveUbo = @FieldType(fx.wave_fs.Io, "u");
const OutlineUbo = @FieldType(fx.outline_fs.Io, "u");
const PaletteUbo = @FieldType(fx.palette_fs.Io, "u");
const SpotlightUbo = @FieldType(fx.spotlight_fs.Io, "u");
const TilingUbo = @FieldType(fx.tiling_fs.Io, "u");
const SieveUbo = @FieldType(fx.sieve_fs.Io, "u");
const AsciiUbo = @FieldType(fx.ascii_fs.Io, "u");
const CubesUbo = @FieldType(fx.cubes_fs.Io, "u");

const Mode = enum { source, grade, waves, outline, palette, spotlight, tiling, sieve, ascii, cubes };

const mode_count: usize = std.enums.values(Mode).len;

/// Step through the effects, wrapping. `dir` is +1 / -1.
fn cycleMode(m: Mode, dir: i32) Mode {
    const n: i32 = @intCast(mode_count);
    const i: i32 = @intCast(@backingInt(m));
    const next: i32 = @mod(i + dir + n, n);
    return @fromBackingInt(@intCast(@as(u32, @intCast(next))));
}

const bg_clear: Color = .{ .r = 28, .g = 27, .b = 34, .a = 255 };
const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

/// The palette tables the palette effect cycles through - recoloring by
/// table swap is the whole point of raylib's `shaders_palette_switch`.
const palette_count: usize = 3;
const palettes: [palette_count][8][4]f32 = .{
    // Game Boy greens, darkest to lightest.
    .{
        .{ 0.06, 0.22, 0.06, 1 }, .{ 0.19, 0.38, 0.19, 1 },
        .{ 0.30, 0.51, 0.30, 1 }, .{ 0.42, 0.65, 0.30, 1 },
        .{ 0.55, 0.75, 0.35, 1 }, .{ 0.67, 0.84, 0.45, 1 },
        .{ 0.78, 0.91, 0.56, 1 }, .{ 0.88, 0.97, 0.68, 1 },
    },
    // Sunset: ember to gold.
    .{
        .{ 0.13, 0.05, 0.25, 1 }, .{ 0.29, 0.07, 0.35, 1 },
        .{ 0.48, 0.10, 0.36, 1 }, .{ 0.68, 0.16, 0.30, 1 },
        .{ 0.85, 0.28, 0.22, 1 }, .{ 0.95, 0.45, 0.18, 1 },
        .{ 1.00, 0.65, 0.25, 1 }, .{ 1.00, 0.85, 0.45, 1 },
    },
    // Ice: near-black blue to white.
    .{
        .{ 0.04, 0.06, 0.12, 1 }, .{ 0.09, 0.14, 0.26, 1 },
        .{ 0.15, 0.25, 0.42, 1 }, .{ 0.24, 0.40, 0.60, 1 },
        .{ 0.37, 0.57, 0.76, 1 }, .{ 0.55, 0.73, 0.88, 1 },
        .{ 0.75, 0.87, 0.96, 1 }, .{ 0.93, 0.97, 1.00, 1 },
    },
};

const State = struct {
    gpa: Allocator,

    /// Keyed BY THE MODE ENUM, not by a parallel index. Adding an effect used to
    /// mean editing four things in lockstep - the array, its length, the
    /// `switch (mode) => index` map, and the ubo writes - and any one of them
    /// could silently drift. An EnumArray makes the mapping total and checked:
    /// a new Mode member that nobody initialises is a COMPILE error, not a
    /// wrong-pipeline-at-runtime.
    fx: std.EnumArray(Mode, z.effects2d.Effect),
    fx_host: z.effects2d.Host,
    ascii_cell: f32 = 9.0,
    ascii_mix: f32 = 0.55,
    cubes_div: f32 = 5.0,
    cubes_fill: f32 = 0.216,
    src_sampler: z.wgpu.SamplerHandle,

    rt_src: z.RenderTexture, // the live scene (transparent clear)
    rt_out: z.RenderTexture, // the filtered result

    ui_host: z.UiHost,
    font: z.Font,

    mode: Mode = .waves,
    // grade knobs ([-1,1]; raylib's /100 pre-applied)
    contrast: f32 = 0.15,
    brightness: f32 = 0.0,
    saturation: f32 = 0.2,
    // wave knobs (raylib defaults 25/5/8)
    wave_amp: f32 = 5.0,
    wave_freq: f32 = 25.0,
    // outline knobs
    outline_px: f32 = 3.0,
    // palette knobs
    palette_ix: usize = 0,
    palette_colors: f32 = 8.0,
    // spotlight knobs (radii in source px; darkness = bleed outside spots)
    spot_radius: f32 = 170.0,
    spot_dark: f32 = 0.12,
    // The hero spot chases the last pointer position (backing px).
    spot_pos: Vec2 = .{ 300, 300 },
    // tiling knob (source repeats per axis)
    tiling_n: f32 = 3.0,
    // sieve knob (grid = scale x scale integers)
    sieve_scale: f32 = 220.0,

    cam_pad: f32 = 0, // reserved

    balls: [5]Ball,
};

const Ball = struct {
    pos: Vec2,
    vel: Vec2,
    radius: f32,
    color: Color,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    for (s.fx.values) |e| {
        e.deinit();
    }
    s.fx_host.deinit();
    z.wgpu.destroySampler(s.src_sampler);
    s.rt_src.deinit();
    s.rt_out.deinit();
    s.ui_host.deinit();
}

/// What every effect pipeline shares: the layout holes, the quad VS,
/// the quad vertex layout.
fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const device: z.wgpu.DeviceHandle = f.gpu.device;

    // Linear sampling: the waves effect reads BETWEEN texels on purpose.
    const src_sampler: z.wgpu.SamplerHandle = z.wgpu.createSampler(device, .{
        .mag_filter_linear = true,
        .min_filter_linear = true,
        .address_mode = .clamp_to_edge,
    });

    // The engine owns the quad, the layouts and the binding contract now; this
    // example only says WHICH fragment shaders it wants.
    var fx_host: z.effects2d.Host = try z.effects2d.Host.init(gpa, f.gl, shading_vs_wgsl, .{});

    // EnumArray: every Mode must be given an effect, and the compiler checks it.
    // `.source` is the passthrough (no effect runs), so it gets the empty default.
    var fx_table: std.EnumArray(Mode, z.effects2d.Effect) = .initFill(.{});
    fx_table.set(.grade, try fx_host.load(gpa, device, grade_fs_wgsl, @sizeOf(GradeUbo), "fx_grade"));
    fx_table.set(.waves, try fx_host.load(gpa, device, wave_fs_wgsl, @sizeOf(WaveUbo), "fx_wave"));
    fx_table.set(.outline, try fx_host.load(gpa, device, outline_fs_wgsl, @sizeOf(OutlineUbo), "fx_outline"));
    fx_table.set(.palette, try fx_host.load(gpa, device, palette_fs_wgsl, @sizeOf(PaletteUbo), "fx_palette"));
    fx_table.set(.spotlight, try fx_host.load(gpa, device, spotlight_fs_wgsl, @sizeOf(SpotlightUbo), "fx_spot"));
    fx_table.set(.tiling, try fx_host.load(gpa, device, tiling_fs_wgsl, @sizeOf(TilingUbo), "fx_tiling"));
    fx_table.set(.sieve, try fx_host.load(gpa, device, sieve_fs_wgsl, @sizeOf(SieveUbo), "fx_sieve"));
    fx_table.set(.ascii, try fx_host.load(gpa, device, ascii_fs_wgsl, @sizeOf(AsciiUbo), "fx_ascii"));
    fx_table.set(.cubes, try fx_host.load(gpa, device, cubes_fs_wgsl, @sizeOf(CubesUbo), "fx_cubes"));

    // A seeded scatter of bouncing balls, phone-friendly sizes.
    var balls: [5]Ball = undefined;
    const ball_colors = [5]Color{
        .{ .r = 255, .g = 120, .b = 90, .a = 255 },
        .{ .r = 110, .g = 200, .b = 255, .a = 255 },
        .{ .r = 150, .g = 235, .b = 120, .a = 255 },
        .{ .r = 255, .g = 210, .b = 90, .a = 255 },
        .{ .r = 220, .g = 140, .b = 255, .a = 255 },
    };
    for (&balls, ball_colors, 0..) |*b, c, i| {
        const fi: f32 = float(i);
        b.* = .{
            .pos = .{ 120 + fi * 130, 140 + fi * 60 },
            .vel = .{ 90 + fi * 25, 70 + fi * 17 },
            .radius = 34 + fi * 7,
            .color = c,
        };
    }

    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.* = .{
        .gpa = gpa,
        .fx = fx_table,
        .fx_host = fx_host,
        .src_sampler = src_sampler,
        .rt_src = .{},
        .rt_out = .{},
        .ui_host = z.UiHost.init(gpa, font),
        .font = font,
        .balls = balls,
    };
}

fn ensureTargets(f: *z.Frame, s: *State) void {
    const backing: z.wgpu.SurfaceSize = z.wgpu.getSurfaceSize(f.gpu.surface);
    const bw: u32 = @max(backing.width, 1);
    const bh: u32 = @max(backing.height, 1);
    if (s.rt_src.color != .invalid and s.rt_src.width == bw and s.rt_src.height == bh) {
        return;
    }
    if (s.rt_src.color != .invalid) {
        z.unloadRenderTexture(f.gl, &s.rt_src);
        z.unloadRenderTexture(f.gl, &s.rt_out);
    }
    s.rt_src = z.loadRenderTexture(f.gl, @intCast(bw), @intCast(bh));
    s.rt_out = z.loadRenderTexture(f.gl, @intCast(bw), @intCast(bh));

    // Re-point every effect at the new source. `setSource` destroys the previous
    // bind group; the hand-rolled version this replaced leaked one per resize.
    s.fx_host.setSource(
        s.gpa,
        f.gpu.device,
        s.rt_src.asTexture().view,
        s.src_sampler,
    ) catch return;
}

/// The live source: bouncing balls, two spinning slabs, a big label -
/// drawn on a TRANSPARENT clear so the outline effect has alpha to bite.
fn drawSourceScene(f: *z.Frame, s: *State, t: f32, dt: f32) void {
    const w: f32 = float(s.rt_src.width);
    const h: f32 = float(s.rt_src.height);

    for (&s.balls) |*b| {
        b.pos += b.vel * @as(Vec2, @splat(dt));
        if (b.pos[0] < b.radius or b.pos[0] > w - b.radius) {
            b.vel[0] = -b.vel[0];
            b.pos[0] = clamp(b.pos[0], b.radius, w - b.radius);
        }
        if (b.pos[1] < b.radius or b.pos[1] > h - b.radius) {
            b.vel[1] = -b.vel[1];
            b.pos[1] = clamp(b.pos[1], b.radius, h - b.radius);
        }
    }

    // Clear to TRANSPARENT - the outline effect keys on the alpha channel.
    z.beginTextureMode(f.gl, s.rt_src, .{ .r = 0, .g = 0, .b = 0, .a = 0 });

    for (&s.balls) |*b| {
        f.gl.circle(b.pos, b.radius, .{ .color = b.color, .segments = 40 });
    }
    const slab: Color = .{ .r = 245, .g = 245, .b = 250, .a = 255 };
    f.gl.rectRotated(
        .{ .x = w * 0.30, .y = h * 0.62, .width = w * 0.24, .height = 26 },
        .{ w * 0.12, 13 },
        t * 0.7,
        .{ .color = slab },
    );
    f.gl.rectRotated(
        .{ .x = w * 0.72, .y = h * 0.30, .width = w * 0.20, .height = 22 },
        .{ w * 0.10, 11 },
        -t * 0.95,
        .{ .color = slab },
    );
    f.gl.text(.{ w * 0.5 - 70, h * 0.5 - 20 }, "zimr", .{ .size = 56, .color = white, .font = &s.font });

    z.endTextureMode(f.gl);
}

fn writeEffectUbos(f: *z.Frame, s: *State, t: f32) void {
    const w: f32 = float(s.rt_src.width);
    const h: f32 = float(s.rt_src.height);
    const q: z.wgpu.QueueHandle = f.gpu.queue;

    var grade: GradeUbo = .{ .params = .{ s.contrast, s.brightness, s.saturation, 0 } };
    z.wgpu.queueWriteBuffer(q, s.fx.get(.grade).ubo, 0, std.mem.asBytes(&grade));

    var wave: WaveUbo = .{
        .drive = .{ t, s.wave_freq, s.wave_freq, 0 },
        .motion = .{ s.wave_amp, s.wave_amp, 8, 8 },
        .size = .{ w, h, 0, 0 },
    };
    z.wgpu.queueWriteBuffer(q, s.fx.get(.waves).ubo, 0, std.mem.asBytes(&wave));

    var outline: OutlineUbo = .{
        .outline_color = .{ 1.0, 0.42, 0.1, 1 },
        .params = .{ s.outline_px, w, h, 0 },
    };
    z.wgpu.queueWriteBuffer(q, s.fx.get(.outline).ubo, 0, std.mem.asBytes(&outline));

    var spot: SpotlightUbo = .{
        .spots = .{
            .{ s.spot_pos[0], s.spot_pos[1], s.spot_radius * 0.35, s.spot_radius },
            .{ s.balls[0].pos[0], s.balls[0].pos[1], s.spot_radius * 0.22, s.spot_radius * 0.62 },
            .{ s.balls[2].pos[0], s.balls[2].pos[1], s.spot_radius * 0.22, s.spot_radius * 0.62 },
        },
        .params = .{ s.spot_dark, w, h, 0 },
    };
    z.wgpu.queueWriteBuffer(q, s.fx.get(.spotlight).ubo, 0, std.mem.asBytes(&spot));

    var pal: PaletteUbo = .{
        .palette = undefined,
        .params = .{ s.palette_colors, 0, 0, 0 },
    };
    for (palettes[s.palette_ix], &pal.palette) |src, *dst| {
        dst.* = src;
    }
    z.wgpu.queueWriteBuffer(q, s.fx.get(.palette).ubo, 0, std.mem.asBytes(&pal));

    var tiling: TilingUbo = .{ .tiling = .{ s.tiling_n, s.tiling_n, 0, 0 } };
    z.wgpu.queueWriteBuffer(q, s.fx.get(.tiling).ubo, 0, std.mem.asBytes(&tiling));

    var sieve: SieveUbo = .{ .params = .{ s.sieve_scale, 0, 0, 0 } };
    z.wgpu.queueWriteBuffer(q, s.fx.get(.sieve).ubo, 0, std.mem.asBytes(&sieve));

    // The ASCII cell grid is defined in PIXELS, so the shader must be told the
    // live canvas size - derive it from the UV and it would stretch with aspect.
    var ascii: AsciiUbo = .{
        .params = .{ s.ascii_cell, s.ascii_mix, 0, 0 },
        .resolution = .{ f.window.widthf(), f.window.heightf(), 0, 0 },
    };
    z.wgpu.queueWriteBuffer(q, s.fx.get(.ascii).ubo, 0, std.mem.asBytes(&ascii));

    // Purely procedural - it never samples the scene, it just needs the clock.
    var cubes: CubesUbo = .{ .params = .{ t, s.cubes_div, s.cubes_fill, 0 } };
    z.wgpu.queueWriteBuffer(q, s.fx.get(.cubes).ubo, 0, std.mem.asBytes(&cubes));
}

fn update(f: *z.Frame, s: *State) void {
    ensureTargets(f, s);
    const t: f32 = f.time.time;
    const dt: f32 = @min(f.time.delta_time, 0.05);
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);

    // ===== OFFSCREEN PASSES FIRST - tile-based-GPU safe: never tear down the
    // swapchain mid-frame. Uses s.* mode/slider state from the PREVIOUS frame
    // (a 1-frame lag, imperceptible at 60fps); the UI below updates it for the
    // next frame. This is why the app owns its own begin/endDrawing. =====
    drawSourceScene(f, s, t, dt);
    writeEffectUbos(f, s, t);
    if (s.mode != .source) {
        // raylib's shape: open the target, run the shader over the source, close.
        // No pipeline/bind-group/vertex-buffer bookkeeping in userland any more -
        // and no `mode -> index` map to keep in sync, because the EnumArray IS the
        // map.
        z.beginTextureModeRaw(f.gl, s.rt_out, .{ .r = 28, .g = 27, .b = 34, .a = 255 });
        z.effects2d.beginShaderMode(f.gl, &s.fx_host, s.fx.get(s.mode));
        z.effects2d.drawFullscreen(f.gl);
        z.effects2d.endShaderMode(f.gl);
        z.endTextureModeRaw(f.gl);
    }

    // ===== SCREEN PASS - opens exactly ONCE, after all offscreen work. =====
    z.beginDrawing(f.gl);
    z.clearViewport(f, bg_clear);
    const composited: z.WgpuRenderTexture = if (s.mode == .source) s.rt_src else s.rt_out;
    f.gl.texture(.{ .x = 0, .y = 0, .width = vw, .height = vh }, composited.asTexture(), .{ .tint = white });

    // ---- UI: effect picker + contextual knobs ----
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    //
    // A CYCLER, not a grid of buttons. The grid's height grew with every effect
    // added, and the newest one kept landing outside the window - where `itemAdd`
    // CLIPS it, so it still draws but can never be tapped. That has now bitten
    // twice (ascii, then cubes), and "budget more pixels per row" only postpones
    // it: the height of a grid is O(number of effects), so the bug comes back the
    // next time one is added.
    //
    // prev/next is O(1) in height. Reachability no longer depends on how many
    // effects exist, which is the actual invariant that kept breaking.
    const panel_w: f32 = @min(460, vw - 16);
    const panel_h: f32 = @min(280, vh - 16);
    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ panel_w, panel_h }, .{});
    if (u.window("effects", .{})) |win| {
        defer win.close();
        if (u.button("< prev", .{})) {
            s.mode = cycleMode(s.mode, -1);
        }
        u.sameLine(.{});
        if (u.button("next >", .{})) {
            s.mode = cycleMode(s.mode, 1);
        }
        u.sameLine(.{});
        u.text("{s}", .{@tagName(s.mode)});
        u.text("effect {d} of {d}", .{ @backingInt(s.mode) + 1, mode_count });
        u.separator();
        switch (s.mode) {
            .source => u.text("unfiltered scene", .{}),
            .grade => {
                _ = u.slider("contrast", &s.contrast, .{ .min = -1, .max = 1 });
                _ = u.slider("brightness", &s.brightness, .{ .min = -1, .max = 1 });
                _ = u.slider("saturation", &s.saturation, .{ .min = -1, .max = 1 });
            },
            .waves => {
                _ = u.slider("amplitude", &s.wave_amp, .{ .min = 0, .max = 20, .fmt = "{d:.1}" });
                _ = u.slider("frequency", &s.wave_freq, .{ .min = 5, .max = 60, .fmt = "{d:.0}" });
            },
            .outline => {
                _ = u.slider("width px", &s.outline_px, .{ .min = 1, .max = 8, .fmt = "{d:.0}" });
            },
            .palette => {
                _ = u.slider("colors", &s.palette_colors, .{ .min = 2, .max = 8, .fmt = "{d:.0}" });
                if (u.button("next palette", .{})) {
                    s.palette_ix = (s.palette_ix + 1) % palette_count;
                }
            },
            .spotlight => {
                _ = u.slider("radius", &s.spot_radius, .{ .min = 60, .max = 340, .fmt = "{d:.0}" });
                _ = u.slider("darkness", &s.spot_dark, .{ .min = 0.0, .max = 0.5 });
            },
            .tiling => {
                _ = u.slider("repeat", &s.tiling_n, .{ .min = 1, .max = 6, .fmt = "{d:.0}" });
            },
            .ascii => {
                _ = u.slider("cell px", &s.ascii_cell, .{ .min = 4, .max = 24, .fmt = "{d:.0}" });
                _ = u.slider("color mix", &s.ascii_mix, .{ .min = 0.0, .max = 1.0 });
            },
            .cubes => {
                u.text("procedural: samples nothing", .{});
                _ = u.slider("divisions", &s.cubes_div, .{ .min = 2, .max = 16, .fmt = "{d:.0}" });
                _ = u.slider("fill", &s.cubes_fill, .{ .min = 0.05, .max = 0.9 });
            },
            .sieve => {
                _ = u.slider("grid", &s.sieve_scale, .{ .min = 60, .max = 400, .fmt = "{d:.0}" });
            },
        }
    }

    // ---- hero spotlight chases the pointer (backing-pixel space) ----
    {
        const sx: f32 = float(s.rt_src.width) / vw;
        const sy: f32 = float(s.rt_src.height) / vh;
        const mp: Vec2 = z.getMousePosition(f.input);
        const target: Vec2 = if (u.wantCaptureMouse())
            Vec2{ // idle orbit while the pointer is busy with the panel
                float(s.rt_src.width) * (0.5 + 0.25 * @cos(t * 0.5)),
                float(s.rt_src.height) * (0.42 + 0.2 * @sin(t * 0.7)),
            }
        else
            Vec2{ mp[0] * sx, mp[1] * sy };
        const chase: f32 = @min(dt * 6.0, 1.0);
        s.spot_pos += (target - s.spot_pos) * @as(Vec2, @splat(chase));
    }

    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - 2D shader effects gallery",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
    // Owns its own begin/endDrawing so the source + effect render-textures are
    // built BEFORE the screen pass opens - no mid-frame swapchain teardown, so
    // no tile-based-GPU frame-feedback tiling.
    .manages_own_frame = true,
};
