//! logo_raylib_anim — the framed-square logo, assembled live by a little state machine: a box
//! blinks, the top+left bars grow, then the bottom+right bars close the frame, the letters type in
//! one by one, and the whole thing fades out before looping. Rebadged "zimr" and inverted for the
//! dark theme. Auto-loops; tap to replay immediately (raylib uses the R key).
//! From raylib shapes_logo_raylib_anim.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const co = @import("example_common");

const clamp = zm.clamp;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const word = "zimr";
const letter_step = 0.18; // seconds between letters
const fade_hold = 0.6; // pause after the last letter before fading
const fade_time = 1.0; // fade-out duration
const grow_time = 0.55; // per-pair bar-grow duration

const st_blink = 0;
const st_grow1 = 1;
const st_grow2 = 2;
const st_letters = 3;
const st_replay = 4;

const State = struct {
    font: z.Font,
    state: u8 = st_blink,
    t: f32 = 0,
    letters: usize = 0,
    alpha: f32 = 1,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

fn reset(s: *State) void {
    s.state = st_blink;
    s.t = 0;
    s.letters = 0;
    s.alpha = 1;
}

fn lerpf(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn fade(a: f32) Color {
    const base: Color = co.palette.ink;
    const al: u8 = @round(clamp(a, 0.0, 1.0) * 255.0);
    return .{ .r = base.r, .g = base.g, .b = base.b, .a = al };
}

fn update(f: *z.Frame, s: *State) void {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const dt: f32 = f.time.delta_time;
    z.clearViewport(f, co.palette.bg);

    const tapped: bool = z.isMouseButtonReleased(f.input, .left);
    if (tapped) {
        reset(s);
    }
    s.t += dt;

    // --- state machine ---
    switch (s.state) {
        st_blink => if (s.t > 1.2) {
            s.state = st_grow1;
            s.t = 0;
        },
        st_grow1 => if (s.t >= grow_time) {
            s.state = st_grow2;
            s.t = 0;
        },
        st_grow2 => if (s.t >= grow_time) {
            s.state = st_letters;
            s.t = 0;
        },
        st_letters => {
            const idx: usize = @floor(s.t / letter_step);
            s.letters = @min(idx, word.len);
            const fade_start: f32 = @as(f32, word.len) * letter_step + fade_hold;
            if (s.t > fade_start) {
                s.alpha = clamp(1.0 - (s.t - fade_start) / fade_time, 0.0, 1.0);
                if (s.alpha <= 0.0) {
                    s.state = st_replay;
                    s.t = 0;
                }
            }
        },
        else => if (s.t > 0.8) {
            reset(s);
        },
    }

    drawLogo(f, s, w, h);
    co.caption(f.gl, s.font, "logo animation - tap to replay");
    z.endDrawing(f.gl);
}

fn drawLogo(f: *z.Frame, s: *State, w: f32, h: f32) void {
    const size: f32 = @min(w, h) * 0.52;
    const thick: f32 = size * 0.0625;
    const lx: f32 = w * 0.5 - size * 0.5;
    const ly: f32 = h * 0.5 - size * 0.5;
    const gl = f.gl;

    switch (s.state) {
        st_blink => {
            // blink the seed box on/off
            if (@mod(@floor(s.t / 0.22), 2.0) == 0) {
                gl.rect(.{ .x = lx, .y = ly, .width = thick, .height = thick }, .{ .color = co.palette.ink });
            }
        },
        st_grow1 => {
            const p: f32 = clamp(s.t / grow_time, 0.0, 1.0);
            const grow: f32 = lerpf(thick, size, p);
            gl.rect(.{ .x = lx, .y = ly, .width = grow, .height = thick }, .{ .color = co.palette.ink }); // top
            gl.rect(.{ .x = lx, .y = ly, .width = thick, .height = grow }, .{ .color = co.palette.ink }); // left
        },
        st_grow2 => {
            const p: f32 = clamp(s.t / grow_time, 0.0, 1.0);
            const grow: f32 = lerpf(thick, size, p);
            gl.rect(.{ .x = lx, .y = ly, .width = size, .height = thick }, .{ .color = co.palette.ink }); // top
            gl.rect(.{ .x = lx, .y = ly, .width = thick, .height = size }, .{ .color = co.palette.ink }); // left
            gl.rect(
                .{ .x = lx + size - thick, .y = ly, .width = thick, .height = grow },
                .{ .color = co.palette.ink },
            ); // right
            gl.rect(
                .{ .x = lx, .y = ly + size - thick, .width = grow, .height = thick },
                .{ .color = co.palette.ink },
            ); // bottom
        },
        st_letters => {
            const c: Color = fade(s.alpha);
            // top + bottom full width; left + right inset so corners don't double-blend on fade
            gl.rect(.{ .x = lx, .y = ly, .width = size, .height = thick }, .{ .color = c });
            gl.rect(.{ .x = lx, .y = ly + size - thick, .width = size, .height = thick }, .{ .color = c });
            gl.rect(.{ .x = lx, .y = ly + thick, .width = thick, .height = size - 2.0 * thick }, .{ .color = c });
            gl.rect(
                .{ .x = lx + size - thick, .y = ly + thick, .width = thick, .height = size - 2.0 * thick },
                .{ .color = c },
            );
            // letters typed in so far
            const shown: []const u8 = word[0..s.letters];
            const word_size: f32 = size * 0.2;
            const dim: Vec2 = z.measureText(s.font, word, word_size);
            gl.text(
                .{ w * 0.5 - dim[0] * 0.5, h * 0.5 + size * 0.5 - dim[1] - thick },
                shown,
                .{ .size = word_size, .color = fade(s.alpha), .font = &s.font },
            );
        },
        else => {
            const msg: []const u8 = "tap to replay";
            const ms: f32 = size * 0.12;
            const dim: Vec2 = z.measureText(s.font, msg, ms);
            gl.text(
                .{ w * 0.5 - dim[0] * 0.5, h * 0.5 - dim[1] * 0.5 },
                msg,
                .{ .size = ms, .color = co.palette.ink_dim, .font = &s.font },
            );
        },
    }
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - logo anim",
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
