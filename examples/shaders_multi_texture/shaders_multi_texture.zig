// examples/shaders_multi_texture.zig - one fragment shader, three textures.
// MERGES raylib's `shaders_simple_mask` and `shaders_multi_sample2d`, because
// they are the same shader wearing two hats: sample two sources, produce a blend
// factor, mix. Only the factor differs —
//
//   MASK     the blend factor is a third texture's luminance. Here the mask is
//            LIVE (a radial gradient that follows your finger), which is strictly
//            more convincing than raylib's static mask image: you can see the two
//            sources swap under the spotlight as you drag it.
//   DIVIDER  the blend factor is a position along x — a wipe between the two
//            sources at a draggable split. That is multi_sample2d.
//
// All three textures are RENDER TEXTURES generated at runtime (no assets):
//   A  a live scene — bouncing discs on a dark field
//   B  a procedural checkerboard
//   M  the mask — a radial gradient drawn at the pointer
//
// ENGINE WORK this drove: `effects2d.Host` previously bound exactly ONE source
// texture. It now takes `HostOptions{ .textures = N }` and binds N of them —
// texture at @group(1) binding 2i, its sampler at 2i+1, which is precisely the
// layout the shader DSL generates for N `Sampler2D` fields (verified against the
// PBR shader's WGSL before writing a line of it).
//
// Leak-clean (`.memory = .managed`): three render textures + the effect host are
// released in deinit.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const shading_vs_wgsl = @embedFile("deferred_shading_vs.wgsl");
const mask_fs_wgsl = @embedFile("effect_mask_fs.wgsl");

const fx = z.effect_shaders;
const MaskUbo = @FieldType(fx.mask_fs.Io, "u");

const Color = zm.Color;
const c = Color;
const Vec2 = zm.Vec2;
const float = zm.float;
const clamp = zm.clamp;

const disc_count: usize = 6;

const Mode = enum { mask, divider };

const Disc = struct {
    pos: Vec2,
    vel: Vec2,
    radius: f32,
    color: Color,
};

const State = struct {
    gpa: Allocator,
    ui_host: z.UiHost,
    font: z.Font,
    ui_font: z.Font,

    fx_host: z.effects2d.Host,
    effect: z.effects2d.Effect,
    sampler: z.wgpu.SamplerHandle,

    rt_a: z.RenderTexture = .{}, // live scene
    rt_b: z.RenderTexture = .{}, // checkerboard
    rt_mask: z.RenderTexture = .{}, // radial gradient at the pointer
    rt_out: z.RenderTexture = .{}, // the blended result

    mode: Mode = .mask,
    divider: f32 = 0.5,
    softness: f32 = 0.01,
    mask_radius: f32 = 170.0,
    mask_at: Vec2 = .{ 0, 0 },
    mask_set: bool = false,

    discs: [disc_count]Disc = undefined,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const device: z.wgpu.DeviceHandle = f.gpu.device;

    const sampler: z.wgpu.SamplerHandle = z.wgpu.createSampler(device, .{
        .mag_filter_linear = true,
        .min_filter_linear = true,
        .address_mode = .clamp_to_edge,
    });

    // THREE sources — the reason effects2d grew a texture count.
    var fx_host: z.effects2d.Host = try z.effects2d.Host.init(
        gpa,
        f.gl,
        shading_vs_wgsl,
        .{ .textures = 3 },
    );
    const effect: z.effects2d.Effect = try fx_host.load(
        gpa,
        device,
        mask_fs_wgsl,
        @sizeOf(MaskUbo),
        "fx_mask",
    );

    var prng: std.Random.DefaultPrng = .init(0xB14D_E5A1);
    const rnd: std.Random = prng.random();
    var discs: [disc_count]Disc = undefined;
    const palette = [disc_count]Color{
        .{ .r = 245, .g = 120, .b = 90, .a = 255 },
        .{ .r = 90, .g = 200, .b = 245, .a = 255 },
        .{ .r = 250, .g = 210, .b = 100, .a = 255 },
        .{ .r = 160, .g = 240, .b = 150, .a = 255 },
        .{ .r = 220, .g = 130, .b = 240, .a = 255 },
        .{ .r = 120, .g = 150, .b = 250, .a = 255 },
    };
    for (&discs, 0..) |*d, i| {
        d.* = .{
            .pos = .{ 80.0 + rnd.float(f32) * 560.0, 90.0 + rnd.float(f32) * 260.0 },
            .vel = .{ (rnd.float(f32) - 0.5) * 190.0, (rnd.float(f32) - 0.5) * 190.0 },
            .radius = 22.0 + rnd.float(f32) * 26.0,
            .color = palette[i],
        };
    }

    const ui_font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 16);

    s.* = .{
        .gpa = gpa,
        .ui_font = ui_font,
        .ui_host = z.UiHost.init(gpa, ui_font),
        .font = font,
        .fx_host = fx_host,
        .effect = effect,
        .sampler = sampler,
        .discs = discs,
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.unloadFont(gpa, s.ui_font);
    s.rt_a.deinit();
    s.rt_b.deinit();
    s.rt_mask.deinit();
    s.rt_out.deinit();
    s.effect.deinit();
    s.fx_host.deinit();
    z.wgpu.destroySampler(s.sampler);
    s.ui_host.deinit();
}

/// (Re)allocate the four targets and re-point the shader's three inputs at them.
fn ensureTargets(f: *z.Frame, s: *State) void {
    const backing: z.wgpu.SurfaceSize = z.wgpu.getSurfaceSize(f.gpu.surface);
    const bw: u32 = @max(backing.width, 1);
    const bh: u32 = @max(backing.height, 1);
    if (s.rt_a.color != .invalid and s.rt_a.width == bw and s.rt_a.height == bh) {
        return;
    }
    if (s.rt_a.color != .invalid) {
        z.unloadRenderTexture(f.gl, &s.rt_a);
        z.unloadRenderTexture(f.gl, &s.rt_b);
        z.unloadRenderTexture(f.gl, &s.rt_mask);
        z.unloadRenderTexture(f.gl, &s.rt_out);
    }
    s.rt_a = z.loadRenderTexture(f.gl, @intCast(bw), @intCast(bh));
    s.rt_b = z.loadRenderTexture(f.gl, @intCast(bw), @intCast(bh));
    s.rt_mask = z.loadRenderTexture(f.gl, @intCast(bw), @intCast(bh));
    s.rt_out = z.loadRenderTexture(f.gl, @intCast(bw), @intCast(bh));

    // The order here IS the shader's slot order: tex_a, tex_b, tex_mask.
    s.fx_host.setSources(
        s.gpa,
        f.gpu.device,
        &.{
            s.rt_a.asTexture().view,
            s.rt_b.asTexture().view,
            s.rt_mask.asTexture().view,
        },
        s.sampler,
    ) catch return;
}

/// Source A — bouncing discs.
fn drawSceneA(f: *z.Frame, s: *State, dt: f32) void {
    const w: f32 = float(s.rt_a.width);
    const h: f32 = float(s.rt_a.height);
    for (&s.discs) |*d| {
        d.pos += d.vel * @as(Vec2, @splat(dt));
        if (d.pos[0] < d.radius or d.pos[0] > w - d.radius) {
            d.vel[0] = -d.vel[0];
            d.pos[0] = clamp(d.pos[0], d.radius, w - d.radius);
        }
        if (d.pos[1] < d.radius or d.pos[1] > h - d.radius) {
            d.vel[1] = -d.vel[1];
            d.pos[1] = clamp(d.pos[1], d.radius, h - d.radius);
        }
    }
    z.beginTextureMode(f.gl, s.rt_a, .{ .r = 18, .g = 20, .b = 30, .a = 255 });
    for (s.discs) |d| {
        f.gl.circle(d.pos, d.radius, .{ .color = d.color });
    }
    z.endTextureMode(f.gl);
}

/// Source B — a procedural checkerboard, drawn once per frame (cheap, and it keeps
/// the example free of any asset).
fn drawSceneB(f: *z.Frame, s: *State, t: f32) void {
    const w: f32 = float(s.rt_b.width);
    const h: f32 = float(s.rt_b.height);
    const cell: f32 = 46.0;
    z.beginTextureMode(f.gl, s.rt_b, .{ .r = 26, .g = 30, .b = 38, .a = 255 });
    var y: f32 = 0;
    var row: u32 = 0;
    while (y < h) : ({
        y += cell;
        row += 1;
    }) {
        var x: f32 = 0;
        var col: u32 = 0;
        while (x < w) : ({
            x += cell;
            col += 1;
        }) {
            if ((row + col) % 2 == 0) {
                continue;
            }
            // A slow hue drift, so it is obvious the second source is LIVE too and
            // not a frozen image.
            const k: f32 = @sin(t * 0.7 + float(row) * 0.35 + float(col) * 0.2) * 0.5 + 0.5;
            f.gl.rect(
                .{ .x = x, .y = y, .width = cell, .height = cell },
                .{ .color = .{
                    .r = @trunc(60.0 + 60.0 * k),
                    .g = @trunc(150.0 + 70.0 * k),
                    .b = @trunc(180.0 + 60.0 * k),
                    .a = 255,
                } },
            );
        }
    }
    z.endTextureMode(f.gl);
}

/// Source M — the mask. Black everywhere, a white radial gradient at the pointer.
/// The shader reads its LUMINANCE, so white = show B, black = show A.
fn drawMask(f: *z.Frame, s: *State) void {
    z.beginTextureMode(f.gl, s.rt_mask, c.black);
    f.gl.circleGradient(s.mask_at, s.mask_radius, c.white, c.black);
    z.endTextureMode(f.gl);
}

fn update(f: *z.Frame, s: *State) void {
    ensureTargets(f, s);

    const fw: f32 = f.window.widthf();
    const fh: f32 = f.window.heightf();
    const dt: f32 = f.time.delta_time;
    const t: f32 = f.time.time;

    const u: z.ui_real.Ui = s.ui_host.begin(f);

    if (!s.mask_set) {
        s.mask_at = .{ fw * 0.5, fh * 0.62 };
        s.mask_set = true;
    }
    if (!u.wantCaptureMouse() and z.isMouseButtonDown(f.input, .left)) {
        const p: Vec2 = z.getMousePosition(f.input);
        if (s.mode == .mask) {
            s.mask_at = p;
        } else {
            s.divider = clamp(p[0] / fw, 0.0, 1.0);
        }
    }

    // ---- the three sources -------------------------------------------------
    drawSceneA(f, s, dt);
    drawSceneB(f, s, t);
    drawMask(f, s);

    // ---- one shader, three textures ---------------------------------------
    var ubo: MaskUbo = .{ .params = .{
        if (s.mode == .mask) 0.0 else 1.0,
        s.divider,
        s.softness,
        0,
    } };
    s.effect.setValues(f.gpu.queue, &ubo);

    z.beginTextureModeRaw(f.gl, s.rt_out, c.black);
    z.effects2d.beginShaderMode(f.gl, &s.fx_host, s.effect);
    z.effects2d.drawFullscreen(f.gl);
    z.effects2d.endShaderMode(f.gl);
    z.endTextureModeRaw(f.gl);

    // ---- screen ------------------------------------------------------------
    z.beginDrawing(f.gl);
    z.clearViewport(f, c.black);
    f.gl.texture(
        .{ .x = 0, .y = 0, .width = fw, .height = fh },
        s.rt_out.asTexture(),
        .{},
    );

    if (s.mode == .divider) {
        // Draw the split so the wipe's position is legible, not guessed.
        const x: f32 = s.divider * fw;
        f.gl.line(.{ x, 0 }, .{ x, fh }, .{ .color = c.raywhite, .thickness = 2 });
    }

    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ fw - 16.0, 250 }, .{});
    if (u.window("Multi-texture shader", .{})) |w| {
        defer w.close();
        if (u.button("mask", .{})) {
            s.mode = .mask;
        }
        u.sameLine(.{});
        if (u.button("divider", .{})) {
            s.mode = .divider;
        }
        u.separator();
        switch (s.mode) {
            .mask => {
                u.text("Drag: move the reveal.", .{});
                _ = u.slider("radius", &s.mask_radius, .{ .min = 60, .max = 340, .fmt = "{d:.0}" });
            },
            .divider => {
                u.text("Drag: move the split.", .{});
                _ = u.slider("split", &s.divider, .{ .min = 0.0, .max = 1.0 });
                _ = u.slider("softness", &s.softness, .{ .min = 0.0, .max = 0.2 });
            },
        }
        u.text("3 textures, 1 fragment shader", .{});
    }

    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - shaders - multi-texture (mask + divider)",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
            .depth_format = null,
            .clear = .{ .r = 0, .g = 0, .b = 0, .a = 1.0 },
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
