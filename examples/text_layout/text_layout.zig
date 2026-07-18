//! text_layout — text rendering + measurement showcase on the wgpu
//! backend. A baked TTF atlas (Atkinson Mono) drives: a per-letter rainbow
//! heading (each glyph advanced by its measured width), a word-wrapped
//! paragraph (wrap point chosen with `measureText` per trial line), the same
//! sample drawn at several sizes from the one atlas, and a `measureText` demo
//! that boxes a string with its reported extent. Laid out against the live
//! canvas width (`.responsive`) so it reflows to whatever portrait box the
//! standalone gives it.
const std = @import("std");
const allocPrint = std.fmt.allocPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Color = zm.Color;

const co = @import("example_common");
const c = z.colors;
const int = zm.int;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const paragraph =
    "The quick brown fox jumps over the lazy dog. " ++
    "Pack my box with five dozen liquor jugs. " ++
    "How vexingly quick daft zebras jump!";

const rainbow = [_]Color{
    c.rose_400, c.amber_400, c.gold, c.emerald_400, c.sky_400, c.violet_400, c.pink_400,
};

const State = struct {
    font: z.Font,
    scratch: std.heap.ArenaAllocator,
    frame_count: usize = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.scratch.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 32),
        .scratch = std.heap.ArenaAllocator.init(gpa),
    };
}

/// Draw `text` with each glyph in the next rainbow colour, advancing x by the
/// glyph's measured width. Returns the x cursor after the last glyph.
fn drawRainbow(
    f: *z.Frame,
    font: z.Font,
    text: []const u8,
    x: f32,
    y: f32,
    size: f32,
) void {
    var cursor: f32 = x;
    for (text, 0..) |ch, i| {
        const one: [1]u8 = .{ch};
        const col: Color = if (ch == ' ') c.white else rainbow[i % rainbow.len];
        f.gl.text(.{ cursor, y }, &one, .{ .size = size, .color = col, .font = &font });
        cursor += z.measureText(font, &one, size)[0];
    }
}

/// Word-wrap `text` to `max_width`, drawing each line. Returns the y after the
/// last line. Wrap point is chosen by measuring each trial line.
fn drawWrapped(
    f: *z.Frame,
    font: z.Font,
    scratch: Allocator,
    text: []const u8,
    x: f32,
    y_start: f32,
    max_width: f32,
    size: f32,
    line_gap: f32,
) f32 {
    var y: f32 = y_start;
    var line_start: usize = 0;
    var last_space: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        const at_end: bool = i == text.len;
        if (!at_end and text[i] != ' ') {
            continue;
        }
        const trial: []const u8 = text[line_start..i];
        const w: f32 = z.measureText(font, trial, size)[0];
        if (w > max_width and last_space > line_start) {
            // Overflowed: emit up to the previous space, continue from there.
            const line: []const u8 = text[line_start..last_space];
            f.gl.text(.{ x, y }, line, .{ .size = size, .color = c.slate_100, .font = &font });
            y += size + line_gap;
            line_start = last_space + 1;
        }
        last_space = i;
        if (at_end) {
            const line: []const u8 = text[line_start..text.len];
            if (line.len > 0) {
                f.gl.text(.{ x, y }, line, .{ .size = size, .color = c.slate_100, .font = &font });
                y += size + line_gap;
            }
        }
    }
    _ = scratch;
    return y;
}

fn update(f: *z.Frame, state: *State) void {
    _ = state.scratch.reset(.retain_capacity);
    const a: Allocator = state.scratch.allocator();
    state.frame_count += 1;
    z.clearViewport(f, co.palette.bg);

    const font: z.Font = state.font;
    const margin: f32 = 16;
    const content_w: f32 = f.window.widthf() - margin * 2;

    // 1. Rainbow per-letter heading.
    drawRainbow(f, font, "ZIMR TEXT", margin, 16, 30);
    f.gl.text(.{ margin, 56 }, "rainbow per-letter heading", .{ .size = 13, .color = c.slate_400, .font = &font });

    // 2. Word-wrapped paragraph (wrap via measureText).
    f.gl.text(.{ margin, 92 }, "word wrap to canvas width:", .{ .size = 14, .color = c.sky_300, .font = &font });
    const after_para: f32 = drawWrapped(f, font, a, paragraph, margin, 116, content_w, 16, 5);

    // 3. Same sample at several sizes from one atlas.
    var y: f32 = after_para + 16;
    f.gl.text(.{ margin, y }, "one atlas, many sizes:", .{ .size = 14, .color = c.sky_300, .font = &font });
    y += 26;
    const sizes = [_]f32{ 12, 16, 20, 28 };
    for (sizes) |sz| {
        const label: []const u8 = allocPrint(a, "{d}px Aa Bb", .{int(u32, sz)}) catch "Aa";
        f.gl.text(.{ margin, y }, label, .{ .size = sz, .color = c.amber_300, .font = &font });
        y += sz + 8;
    }

    // 4. measureText demo: box a string with its reported extent.
    y += 12;
    f.gl.text(.{ margin, y }, "measureText extent:", .{ .size = 14, .color = c.sky_300, .font = &font });
    y += 26;
    const sample: []const u8 = "measure me!";
    const ext: Vec2 = z.measureText(font, sample, 22);
    f.gl.rect(
        .{ .x = margin - 2, .y = y - 2, .width = ext[0] + 4, .height = ext[1] + 4 },
        .{ .color = c.violet_400, .outline = 1.0 },
    );
    f.gl.text(.{ margin, y }, sample, .{ .size = 22, .color = c.violet_400, .font = &font });

    co.caption(f.gl, font, "text rendering + measureText word-wrap, multi-size from one TTF atlas");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - text layout",
            .width = 450,
            .height = 800,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
