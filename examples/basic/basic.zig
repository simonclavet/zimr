//! basic — the smallest end-to-end zimr WebGPU demo, the flagship the GL
//! `basic` is for the GL backend. On init it builds a 16×16 checker with
//! `genImageChecked` and uploads it (`loadTextureFromImage`). Each frame it
//! clears to a slowly-pulsing slate and pushes ONE textured triangle through
//! the rl-immediate path (`rlSetTexture` + `rlBegin(.triangles)` +
//! `rlColor4ub`/`rlTexCoord2f`/`rlVertex2f`): the default fragment shader does
//! `texel * vertexColor`, so the per-vertex tints colour the checker rather
//! than replace it. If you see the pulsing background AND a tinted-checker
//! triangle, the whole WebGPU path — texture upload + bind, the 2D pipeline,
//! the vertex accumulator, and the batch flush — is working.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const sinTurns = zm.sinTurns;
const float = zm.float;
const Color = zm.Color;

const common = @import("example_common");
const c = z.colors;

const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const State = struct {
    font: z.Font,
    checker: z.WgpuTexture,
    frame_count: usize = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.checker.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, roboto_mono_ttf, 24);
    // 16×16 checker, 4×4-pixel cells, sky-on-slate — same as GL `basic`.
    const img: z.Image = try z.genImageChecked(gpa, 16, 16, 4, 4, c.sky_400, c.slate_800);
    const checker: z.WgpuTexture = z.loadTextureFromImage(f.gl, img);
    z.unloadImage(gpa, img);
    s.* = .{ .font = font, .checker = checker };
}

inline fn lerpU8(a: u8, b: u8, t: f32) u8 {
    const af: f32 = float(a);
    const bf: f32 = float(b);
    return @trunc(af + t * (bf - af));
}

fn update(f: *z.Frame, state: *State) void {
    state.frame_count += 1;
    const t: f32 = f.time.time;

    // Slow pulse between two slates over a 4s period.
    // A QUARTER turn: the phase rises from 0.5 to 1 across the cycle.
    const phase: f32 = 0.5 + 0.5 * sinTurns(t * 0.25);
    const a: Color = c.slate_950;
    const b: Color = c.slate_800;
    const bg: Color = .{
        .r = lerpU8(a.r, b.r, phase),
        .g = lerpU8(a.g, b.g, phase),
        .b = lerpU8(a.b, b.b, phase),
        .a = 255,
    };
    z.clearViewport(f, bg);

    // One textured triangle: per-vertex tints multiply the checker.
    const cx: f32 = f.window.widthf() * 0.5;
    const cy: f32 = f.window.heightf() * 0.5;
    const r: f32 = 100;
    z.rlSetTexture(f.gl, state.checker);
    z.rlBegin(f.gl, .triangles);
    z.rlColor4ub(f.gl, c.sky_400.r, c.sky_400.g, c.sky_400.b, 255);
    z.rlTexCoord2f(f.gl, 0.5, 0);
    z.rlVertex2f(f.gl, cx, cy - r);
    z.rlColor4ub(f.gl, c.pink_500.r, c.pink_500.g, c.pink_500.b, 255);
    z.rlTexCoord2f(f.gl, 1, 1);
    z.rlVertex2f(f.gl, cx + r, cy + r);
    z.rlColor4ub(f.gl, c.amber_400.r, c.amber_400.g, c.amber_400.b, 255);
    z.rlTexCoord2f(f.gl, 0, 1);
    z.rlVertex2f(f.gl, cx - r, cy + r);
    z.rlEnd(f.gl);
    z.rlSetTexture(f.gl, .{});

    common.caption(f.gl, state.font, "basic - one tinted-checker triangle via the rl-immediate textured path");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - basic",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
