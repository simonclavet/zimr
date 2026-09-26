// examples/text_inline_styling.zig - inline styling markers inside a string.
// Ports raylib's `text_inline_styling`: the text carries its own formatting via
// `[ ]` tags, so one string can change color mid-sentence without the caller
// splitting it up.
//
//   [cRRGGBBAA]  set FOREGROUND color
//   [bRRGGBBAA]  set BACKGROUND color (a filled rect behind the glyphs)
//   [r]          reset to the base style
//
// Tag colors are multiplied by the BASE color's alpha, so fading the whole
// string fades its styled spans with it (raylib does the same).
//
// The renderer walks the string, splits it into STYLED RUNS at each tag, and
// draws run by run: `z.measureText` gives each run's exact width, which both
// advances the pen and sizes the background rect. Measuring (rather than
// assuming a monospace advance) is what keeps backgrounds flush with their text
// and makes `measureStyled` agree with what is actually drawn.
//
// Leak-clean (`.memory = .managed`): the UiHost is deinit'd; atlases are
// engine-owned.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");

// Atkinson Hyperlegible Mono - the Braille Institute's legibility font.
// Distinct letterforms (slashed zero, unambiguous I/l/1), and a deliberate
// break from raylib's look. Latin-only content, so its cmap is plenty:
// ASCII + Latin-1 accented in full. (It has NO Cyrillic and almost no Greek,
// which is why the Unicode examples stay on RobotoMono.)
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const Color = zm.Color;
const c = Color;
const Vec2 = zm.Vec2;
const bufPrint = std.fmt.bufPrint;

const text_size: f32 = 20.0;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    ui_font: z.Font,
    rng: std.Random.DefaultPrng,
    rand_col: Color = .{ .r = 230, .g = 41, .b = 55, .a = 255 },
    line_buf: [96]u8 = undefined,
    fade: f32 = 255.0, // base alpha - proves tag colors inherit it
};

/// Parse 8 hex digits (RRGGBBAA). Returns null on anything malformed, so a typo
/// in a tag degrades to "draw the tag literally" rather than a wrong color.
fn parseHex8(s: []const u8) ?Color {
    if (s.len != 8) {
        return null;
    }
    const v: u32 = std.fmt.parseInt(u32, s, 16) catch return null;
    return .{
        .r = @intCast((v >> 24) & 0xFF),
        .g = @intCast((v >> 16) & 0xFF),
        .b = @intCast((v >> 8) & 0xFF),
        .a = @intCast(v & 0xFF),
    };
}

/// Scale a tag color's alpha by the base alpha (raylib's rule).
fn withBaseAlpha(col: Color, base: Color) Color {
    const a: u32 = (@as(u32, col.a) * @as(u32, base.a)) / 255;
    return .{ .r = col.r, .g = col.g, .b = col.b, .a = @intCast(a) };
}

const Style = struct {
    fg: Color,
    bg: ?Color = null,
};

/// Draw one run of plain text in the current style, advancing the pen.
/// The background (if any) is sized by the run's MEASURED width, so it hugs the
/// glyphs exactly.
fn drawRun(
    gl: *z.WgpuGl,
    font: *z.Font,
    run: []const u8,
    pen: *f32,
    y: f32,
    st: Style,
) void {
    if (run.len == 0) {
        return;
    }
    const w: f32 = z.measureText(font.*, run, text_size)[0];
    if (st.bg) |bg| {
        gl.rect(.{ .x = pen.*, .y = y, .width = w, .height = text_size }, .{ .color = bg });
    }
    gl.text(.{ pen.*, y }, run, .{ .size = text_size, .color = st.fg, .font = font });
    pen.* += w;
}

/// Walk `text`, applying `[c..]` / `[b..]` / `[r]` tags and drawing the runs
/// between them. `emit = false` measures only (the shared walk keeps
/// measurement and drawing from ever disagreeing).
fn walkStyled(
    gl: ?*z.WgpuGl,
    font: *z.Font,
    text: []const u8,
    pos: Vec2,
    base: Color,
    emit: bool,
) f32 {
    var pen: f32 = pos[0];
    var st: Style = .{ .fg = base, .bg = null };
    var i: usize = 0;
    var run_start: usize = 0;

    while (i < text.len) {
        if (text[i] != '[') {
            i += 1;
            continue;
        }
        const close: usize = std.mem.indexOfScalarPos(u8, text, i, ']') orelse break;
        const tag: []const u8 = text[i + 1 .. close];

        // A malformed tag is not a tag - leave it in the text as literal chars.
        var consumed: bool = false;
        if (tag.len == 1 and tag[0] == 'r') {
            if (emit) {
                if (gl) |g| {
                    drawRun(g, font, text[run_start..i], &pen, pos[1], st);
                }
            } else {
                pen += z.measureText(font.*, text[run_start..i], text_size)[0];
            }
            st = .{ .fg = base, .bg = null };
            consumed = true;
        } else if (tag.len == 9 and (tag[0] == 'c' or tag[0] == 'b')) {
            if (parseHex8(tag[1..9])) |col| {
                if (emit) {
                    if (gl) |g| {
                        drawRun(g, font, text[run_start..i], &pen, pos[1], st);
                    }
                } else {
                    pen += z.measureText(font.*, text[run_start..i], text_size)[0];
                }
                const tinted: Color = withBaseAlpha(col, base);
                if (tag[0] == 'c') {
                    st.fg = tinted;
                } else {
                    st.bg = tinted;
                }
                consumed = true;
            }
        }
        if (!consumed) {
            i += 1;
            continue;
        }
        i = close + 1;
        run_start = i;
    }

    // The tail after the last tag.
    if (emit) {
        if (gl) |g| {
            drawRun(g, font, text[run_start..], &pen, pos[1], st);
        }
    } else {
        pen += z.measureText(font.*, text[run_start..], text_size)[0];
    }
    return pen - pos[0];
}

fn drawStyled(
    gl: *z.WgpuGl,
    font: *z.Font,
    text: []const u8,
    pos: Vec2,
    base: Color,
) void {
    _ = walkStyled(gl, font, text, pos, base, true);
}

fn measureStyled(font: *z.Font, text: []const u8, base: Color) f32 {
    return walkStyled(null, font, text, .{ 0, 0 }, base, false);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const ui_font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.* = .{
        .ui_font = ui_font,
        .ui_host = z.UiHost.init(gpa, ui_font),
        .font = font,
        .rng = .init(0xC0FFEE_1234),
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.unloadFont(gpa, s.ui_font);
    s.ui_host.deinit();
}

fn rollColor(s: *State) void {
    const r: std.Random = s.rng.random();
    s.rand_col = .{
        .r = r.intRangeAtMost(u8, 60, 255),
        .g = r.intRangeAtMost(u8, 60, 255),
        .b = r.intRangeAtMost(u8, 60, 255),
        .a = 255,
    };
}

fn update(f: *z.Frame, s: *State) void {
    const fw: f32 = f.window.widthf();

    z.clearViewport(f, c.raywhite);

    const u: z.ui_real.Ui = s.ui_host.begin(f);

    // Window is sized generously ON PURPOSE. `buttonImpl` bails via `itemAdd`
    // when a widget lands FULLY outside the window rect - a too-short window
    // silently produces a button that renders but never returns true. Long help
    // text WRAPS on a narrow phone, which is what pushes widgets out.
    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ fw - 16.0, 250 }, .{});
    if (u.window("Inline styling", .{})) |w| {
        defer w.close();
        u.text("[c..] fg  [b..] bg  [r] reset", .{});
        u.separator();
        if (u.button("Randomize color", .{})) {
            rollColor(s);
        }
        // Readout of the live state: if these numbers don't change when the
        // button is tapped, the button isn't firing (not the color pipeline).
        u.text("color: {d}, {d}, {d}", .{ s.rand_col.r, s.rand_col.g, s.rand_col.b });
        // Base alpha fades the WHOLE string - tag colors inherit it.
        _ = u.slider("base alpha", &s.fade, .{ .min = 40, .max = 255 });
    }

    // Unmissable swatch of the current random color, next to the line it tints.
    f.gl.rect(
        .{ .x = fw - 60.0, .y = 270, .width = 44, .height = 44 },
        .{ .color = s.rand_col },
    );

    const base: Color = .{ .r = 40, .g = 40, .b = 48, .a = @intFromFloat(s.fade) };
    var y: f32 = 280;

    drawStyled(
        f.gl,
        &s.font,
        "Changes the [cFF0000FF]foreground[r] color!",
        .{ 16, y },
        base,
    );
    y += 34;
    drawStyled(
        f.gl,
        &s.font,
        "Changes the [bFFDD00FF]background[r] color!",
        .{ 16, y },
        base,
    );
    y += 34;
    drawStyled(
        f.gl,
        &s.font,
        "[c00A040FF][bFFFFFFFF]Both at once[r] - then back to normal.",
        .{ 16, y },
        base,
    );
    y += 34;
    drawStyled(
        f.gl,
        &s.font,
        "Alpha is [cFF000088]relative to the base[r] color.",
        .{ 16, y },
        base,
    );
    y += 44;

    // Colors can be built at runtime - the tag is just text.
    const line: []const u8 = bufPrint(
        &s.line_buf,
        "Let's be [c{X:0>2}{X:0>2}{X:0>2}FF]CREATIVE[r] !!!",
        .{ s.rand_col.r, s.rand_col.g, s.rand_col.b },
    ) catch "?";
    drawStyled(f.gl, &s.font, line, .{ 16, y }, base);

    // measureStyled must agree with what was drawn: underline the line above at
    // its measured width. If the underline over/undershoots, the two walks have
    // diverged.
    const wline: f32 = measureStyled(&s.font, line, base);
    f.gl.rect(
        .{ .x = 16, .y = y + text_size + 4.0, .width = wline, .height = 2 },
        .{ .color = .{ .r = 150, .g = 150, .b = 160, .a = 255 } },
    );
    f.gl.text(
        .{ 16, y + 34.0 },
        "(underline = measureStyled width; tags excluded)",
        .{ .size = 15, .color = c.gray, .font = &s.font },
    );

    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - text - inline styling",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
            .depth_format = null,
            .clear = .{ .r = 245.0 / 255.0, .g = 245.0 / 255.0, .b = 245.0 / 255.0, .a = 1.0 },
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
