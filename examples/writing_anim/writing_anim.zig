//! writing_anim — a typewriter effect: a line of text is revealed one character at a
//! time with a blinking cursor, then it pauses and restarts. The reveal is just slicing the
//! message to its first N chars (N grows with time), no allocation; measureText places the
//! cursor exactly at the end of the revealed text. Ported from raylib text_writing_anim.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const co = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const message: []const u8 = "watch the words appear, one character at a time...";
const frames_per_char: usize = 6;
const hold_frames: usize = 120;

const State = struct {
    font: z.Font,
    counter: usize = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 28) };
}

fn update(f: *z.Frame, s: *State) void {
    s.counter += 1;
    const total: usize = message.len * frames_per_char;
    if (s.counter > total + hold_frames) {
        s.counter = 0;
    }
    const chars_shown: usize = @min(message.len, s.counter / frames_per_char);
    const t: f32 = f.time.time;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const ref_w: f32 = z.measureText(s.font, message, 28)[0];
    const size: f32 = @min(28.0, 28.0 * (w * 0.88) / ref_w);

    z.clearViewport(f, co.palette.bg);
    co.backdrop(f.gl, w, h);

    const full_w: f32 = z.measureText(s.font, message, size)[0];
    const tx: f32 = (w - full_w) * 0.5;
    const ty: f32 = h * 0.45;
    f.gl.text(.{ tx, ty }, message[0..chars_shown], .{ .size = size, .color = co.palette.ink, .font = &s.font });

    const shown_w: f32 = z.measureText(s.font, message[0..chars_shown], size)[0];
    const blink: bool = @mod(t, 1.0) < 0.5;
    if (chars_shown < message.len or blink) {
        f.gl.rect(.{ .x = tx + shown_w + 2, .y = ty, .width = 3, .height = size }, .{ .color = co.palette.accent });
    }

    co.caption(f.gl, s.font, "writing anim: typewriter reveal");
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - writing anim",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
