//! logo_raylib - the classic "framed square" logo, drawn entirely from primitives: a filled
//! square, a smaller filled square punched out of its middle to leave a thick border, and a word
//! centred inside. Rebadged for this engine ("zimr"), and on the dark theme it's a light frame on
//! the page colour. A gentle breathe keeps it alive. The point of the original survives: it is NOT
//! a texture, every pixel is a shape. From raylib shapes_logo_raylib.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const common = @import("example_common");

const sinRad = zm.sinRad;
const Vec2 = zm.Vec2;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const State = struct {
    font: z.Font,
    t: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

fn update(f: *z.Frame, s: *State) void {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    z.clearViewport(f, common.palette.bg);
    s.t += 0.016;

    // a gentle breathe so the static logo feels alive
    const breathe: f32 = 1.0 + 0.02 * sinRad(s.t * 1.4);
    const size: f32 = @min(w, h) * 0.52 * breathe;
    const border: f32 = size * 0.0625; // raylib's 16/256 ratio
    const inner: f32 = size - 2.0 * border;
    const cx: f32 = w * 0.5;
    const cy: f32 = h * 0.5;

    // outer fill, then punch the page colour back out -> a thick square frame
    f.gl.rect(
        .{ .x = cx - size * 0.5, .y = cy - size * 0.5, .width = size, .height = size },
        .{ .color = common.palette.ink },
    );
    f.gl.rect(
        .{ .x = cx - inner * 0.5, .y = cy - inner * 0.5, .width = inner, .height = inner },
        .{ .color = common.palette.bg },
    );

    // the word, centred horizontally and sat in the lower third like the original
    const word: []const u8 = "zimr";
    const word_size: f32 = size * 0.2;
    const word_dim: Vec2 = z.measureText(s.font, word, word_size);
    f.gl.text(
        .{ cx - word_dim[0] * 0.5, cy + inner * 0.5 - word_dim[1] - border },
        word,
        .{ .size = word_size, .color = common.palette.ink, .font = &s.font },
    );

    common.caption(f.gl, s.font, "this is NOT a texture - every pixel is a drawn shape");
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - logo",
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
