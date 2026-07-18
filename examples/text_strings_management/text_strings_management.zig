//! text_strings_management — raylib's [text] strings-management sample, reimagined
//! as a hands-on playground for the string ops themselves.
//!
//! raylib's version demos TextSubtext / TextSplit / TextJoin by turning a
//! sentence into draggable "text particles" you slice and glue. We keep that
//! spirit but lean into what's fun on a phone: every word is a chip you can drag
//! with a finger, and the two gestures ARE the two headline operations —
//!
//!   * TAP a chip            -> SHATTER it into one chip per character  (a split)
//!   * DROP a chip onto       -> GLUE the two chips into one, text joined (a join)
//!     another chip
//!
//! The HUD rebuilds the whole sentence live by joining every chip left-to-right,
//! so you can watch the string come apart and go back together. No engine feature
//! needed — just text, rects, and touch; the "string library" is plain Zig slices.
const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Color = zm.Color;
const float = zm.float;
const co = @import("example_common");

const atkinson = @embedFile("atkinson_mono_ttf");

const font_size: f32 = 28;
const chip_h: f32 = font_size + 20;
const pad_x: f32 = 16; // horizontal breathing room inside a chip
const max_chips: usize = 64; // a short sentence shattered to characters fits
const tap_slop: f32 = 8; // finger travel under this counts as a tap, not a drag

// Colors, pulled out so the draw calls stay short and readable.
const bg: Color = .{ .r = 17, .g = 24, .b = 39, .a = 255 };
const ink: Color = .{ .r = 15, .g = 23, .b = 42, .a = 255 }; // chip label on bright chip
const title_col: Color = .{ .r = 235, .g = 240, .b = 250, .a = 255 };
const sub_col: Color = .{ .r = 148, .g = 163, .b = 184, .a = 255 };
const hud_bg: Color = .{ .r = 12, .g = 17, .b = 28, .a = 235 };
const hud_col: Color = .{ .r = 203, .g = 213, .b = 225, .a = 255 };
const shadow: Color = .{ .r = 0, .g = 0, .b = 0, .a = 90 };

const palette = [_]Color{
    .{ .r = 56, .g = 189, .b = 248, .a = 255 }, // sky
    .{ .r = 251, .g = 146, .b = 60, .a = 255 }, // orange
    .{ .r = 163, .g = 230, .b = 53, .a = 255 }, // lime
    .{ .r = 244, .g = 114, .b = 182, .a = 255 }, // pink
    .{ .r = 168, .g = 132, .b = 247, .a = 255 }, // violet
    .{ .r = 45, .g = 212, .b = 191, .a = 255 }, // teal
};

const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

/// One draggable piece of text. `pos` is the chip's CENTER; the on-screen rect is
/// derived each frame from the measured text width so a chip hugs its letters.
const Chip = struct {
    buf: [96]u8 = undefined,
    len: usize = 0,
    pos: Vec2 = .{ 0, 0 },
    vel: Vec2 = .{ 0, 0 },
    tint: usize = 0,

    fn text(self: *const Chip) []const u8 {
        return self.buf[0..self.len];
    }
    fn setText(self: *Chip, s: []const u8) void {
        const n: usize = @min(s.len, self.buf.len);
        @memcpy(self.buf[0..n], s[0..n]);
        self.len = n;
    }
};

const State = struct {
    font: z.Font,
    chips: [max_chips]Chip = undefined,
    count: usize = 0,
    grabbed: ?usize = null,
    grab_offset: Vec2 = .{ 0, 0 }, // finger-to-chip-center offset, set on grab
    press: Vec2 = .{ 0, 0 }, // where the current press started (for tap vs drag)
    laid_out: bool = false, // seed the row once, when we first know the viewport
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson, font_size) };
}

// ---- chip helpers ----------------------------------------------------------

fn chipWidth(s: *State, ch: *const Chip) f32 {
    return z.measureText(s.font, ch.text(), font_size)[0] + pad_x * 2;
}

fn chipRect(s: *State, ch: *const Chip) Rect {
    const w: f32 = chipWidth(s, ch);
    return .{ .x = ch.pos[0] - w * 0.5, .y = ch.pos[1] - chip_h * 0.5, .w = w, .h = chip_h };
}

fn addChip(s: *State, text: []const u8, pos: Vec2) void {
    if (s.count >= max_chips) {
        return;
    }
    var ch: Chip = .{ .pos = pos, .tint = s.count % palette.len };
    ch.setText(text);
    s.chips[s.count] = ch;
    s.count += 1;
}

fn resetRect(vw: f32) Rect {
    return .{ .x = vw - 92 - 16, .y = 16, .w = 92, .h = 40 };
}

/// The sentence, split on spaces into a centered row of word-chips. This is the
/// "reset" state and the first-frame seed.
fn layout(s: *State, vw: f32, vh: f32) void {
    s.count = 0;
    s.grabbed = null;
    const sentence: []const u8 = "strings are just bytes you can rearrange";
    var total: f32 = 0;
    var it = std.mem.tokenizeScalar(u8, sentence, ' ');
    while (it.next()) |word| {
        total += z.measureText(s.font, word, font_size)[0] + pad_x * 2 + 12;
    }
    var x: f32 = (vw - total) * 0.5 + pad_x;
    it = std.mem.tokenizeScalar(u8, sentence, ' ');
    while (it.next()) |word| {
        const w: f32 = z.measureText(s.font, word, font_size)[0] + pad_x * 2;
        addChip(s, word, .{ x + w * 0.5, vh * 0.42 });
        x += w + 12;
    }
}

/// SPLIT: replace chip `idx` with one chip per character, fanned outward from
/// where it stood. Spaces are dropped so you get pure letters to play with.
fn shatter(s: *State, idx: usize) void {
    const src: Chip = s.chips[idx];
    s.chips[idx] = s.chips[s.count - 1]; // swap-remove the source
    s.count -= 1;
    var i: usize = 0;
    for (src.text()) |byte| {
        if (byte == ' ') {
            continue;
        }
        const a: f32 = float(i) * 0.9;
        const one = [_]u8{byte};
        addChip(s, &one, .{ src.pos[0] + @cos(a) * 6, src.pos[1] + @sin(a) * 6 });
        if (s.count > 0) {
            s.chips[s.count - 1].vel = .{ @cos(a) * 220, @sin(a) * 220 - 60 };
        }
        i += 1;
    }
}

/// JOIN: fold chip `b`'s text onto chip `a` (a space between) and drop `b`.
fn glue(s: *State, a: usize, b: usize) void {
    var joined: [96]u8 = undefined;
    const merged: []const u8 = bufPrint(&joined, "{s} {s}", .{ s.chips[a].text(), s.chips[b].text() }) catch return;
    s.chips[a].setText(merged);
    s.chips[b] = s.chips[s.count - 1];
    s.count -= 1;
}

fn pointInRect(p: Vec2, r: Rect) bool {
    return p[0] >= r.x and p[0] <= r.x + r.w and p[1] >= r.y and p[1] <= r.y + r.h;
}

/// Topmost chip under the pointer, or null. Later chips draw on top, so we scan
/// back-to-front to grab the one you can actually see.
fn chipAt(s: *State, p: Vec2) ?usize {
    var i: usize = s.count;
    while (i > 0) {
        i -= 1;
        if (pointInRect(p, chipRect(s, &s.chips[i]))) {
            return i;
        }
    }
    return null;
}

/// A chip (other than `gi`) whose rect overlaps `gi`'s — the glue target.
fn overlapTarget(s: *State, gi: usize) ?usize {
    const g: Rect = chipRect(s, &s.chips[gi]);
    var i: usize = 0;
    while (i < s.count) : (i += 1) {
        if (i == gi) {
            continue;
        }
        const r: Rect = chipRect(s, &s.chips[i]);
        const hit: bool = g.x < r.x + r.w and g.x + g.w > r.x and g.y < r.y + r.h and g.y + g.h > r.y;
        if (hit) {
            return i;
        }
    }
    return null;
}

/// Gentle physics: nudge overlapping idle chips apart, coast on any velocity from
/// a shatter, and keep everything on screen. Alive, but damped enough to read.
fn settle(s: *State, vw: f32, vh: f32, dt: f32) void {
    var i: usize = 0;
    while (i < s.count) : (i += 1) {
        var j: usize = i + 1;
        while (j < s.count) : (j += 1) {
            if (s.grabbed == i or s.grabbed == j) {
                continue;
            }
            const dx: f32 = s.chips[i].pos[0] - s.chips[j].pos[0];
            const dy: f32 = s.chips[i].pos[1] - s.chips[j].pos[1];
            const min_x: f32 = (chipWidth(s, &s.chips[i]) + chipWidth(s, &s.chips[j])) * 0.5;
            if (@abs(dx) < min_x and @abs(dy) < chip_h) {
                const push: f32 = if (dx >= 0) 8 else -8;
                s.chips[i].vel[0] += push;
                s.chips[j].vel[0] -= push;
            }
        }
    }
    i = 0;
    while (i < s.count) : (i += 1) {
        if (s.grabbed == i) {
            continue;
        }
        s.chips[i].pos[0] += s.chips[i].vel[0] * dt;
        s.chips[i].pos[1] += s.chips[i].vel[1] * dt;
        s.chips[i].vel[0] *= 0.86;
        s.chips[i].vel[1] *= 0.86;
        const w: f32 = chipWidth(s, &s.chips[i]);
        s.chips[i].pos[0] = std.math.clamp(s.chips[i].pos[0], w * 0.5, vw - w * 0.5);
        s.chips[i].pos[1] = std.math.clamp(s.chips[i].pos[1], chip_h * 0.5 + 64, vh - chip_h * 0.5 - 96);
    }
}

// ---- update ----------------------------------------------------------------

fn update(f: *z.Frame, s: *State) void {
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    if (!s.laid_out) {
        layout(s, vw, vh);
        s.laid_out = true;
    }

    const ptr: Vec2 = z.getMousePosition(f.input);
    const pressed: bool = z.isMouseButtonPressed(f.input, .left);
    // Raw held-state + press origin — the phone-safe way (delta accumulation
    // jumps on touch because the pre-touch pointer is stale). Follow the finger
    // absolutely: chip.pos = finger - grab_offset. Same recipe as ui_phone_gestures.
    const down: bool = f.input.mouse.current_button[0] != 0;
    const press: Vec2 = f.input.mouse.press_position[0];
    const over_reset: bool = pointInRect(ptr, resetRect(vw));

    if (pressed and over_reset) {
        layout(s, vw, vh);
        drawScene(f, s, vw, vh);
        return;
    }
    if (pressed and !over_reset) {
        // Hit-test where the press LANDED, not the current pointer.
        s.grabbed = chipAt(s, press);
        s.press = press;
        if (s.grabbed) |gi| {
            s.grab_offset = .{ press[0] - s.chips[gi].pos[0], press[1] - s.chips[gi].pos[1] };
        }
    }
    if (down) {
        if (s.grabbed) |gi| {
            s.chips[gi].pos = .{ ptr[0] - s.grab_offset[0], ptr[1] - s.grab_offset[1] };
            s.chips[gi].vel = .{ 0, 0 };
        }
    } else if (s.grabbed) |gi| {
        // Released: a press that barely travelled is a tap (split); one that was
        // dragged onto a neighbour is a join.
        const dx: f32 = ptr[0] - s.press[0];
        const dy: f32 = ptr[1] - s.press[1];
        if (dx * dx + dy * dy <= tap_slop * tap_slop) {
            shatter(s, gi);
        } else if (overlapTarget(s, gi)) |ti| {
            glue(s, ti, gi);
        }
        s.grabbed = null;
    }

    settle(s, vw, vh, f.time.delta_time);
    drawScene(f, s, vw, vh);
}

// ---- draw ------------------------------------------------------------------

fn label(
    f: *z.Frame,
    s: *State,
    pos: Vec2,
    str: []const u8,
    size: f32,
    col: Color,
) void {
    f.gl.text(pos, str, .{ .size = size, .color = col, .font = &s.font });
}

fn drawScene(f: *z.Frame, s: *State, vw: f32, vh: f32) void {
    z.clearViewport(f, bg);
    label(f, s, .{ 20, 22 }, "String Playground", 22, title_col);
    label(f, s, .{ 20, 50 }, "tap a chip to shatter into letters . drag one onto another to glue", 15, sub_col);

    var i: usize = 0;
    while (i < s.count) : (i += 1) {
        const ch: *const Chip = &s.chips[i];
        const r: Rect = chipRect(s, ch);
        const lifted: bool = (s.grabbed == i);
        const oy: f32 = if (lifted) 6 else 3;
        f.gl.rect(.{ .x = r.x + 2, .y = r.y + oy, .width = r.w, .height = r.h }, .{ .color = shadow });
        f.gl.rect(.{ .x = r.x, .y = r.y, .width = r.w, .height = r.h }, .{ .color = palette[ch.tint] });
        const edge: Color = if (lifted)
            .{ .r = 255, .g = 255, .b = 255, .a = 255 }
        else
            .{ .r = 255, .g = 255, .b = 255, .a = 70 };
        f.gl.rect(.{ .x = r.x, .y = r.y, .width = r.w, .height = r.h }, .{ .color = edge, .outline = 1.5 });
        const tw: f32 = z.measureText(s.font, ch.text(), font_size)[0];
        label(f, s, .{ ch.pos[0] - tw * 0.5, ch.pos[1] - font_size * 0.5 }, ch.text(), font_size, ink);
    }

    const rr: Rect = resetRect(vw);
    const over: bool = pointInRect(z.getMousePosition(f.input), rr);
    const btn: Color = if (over)
        .{ .r = 71, .g = 85, .b = 105, .a = 255 }
    else
        .{ .r = 51, .g = 65, .b = 85, .a = 255 };
    f.gl.rect(.{ .x = rr.x, .y = rr.y, .width = rr.w, .height = rr.h }, .{ .color = btn });
    label(f, s, .{ rr.x + 20, rr.y + 11 }, "reset", 18, .{ .r = 226, .g = 232, .b = 240, .a = 255 });

    drawHud(f, s, vw, vh);
    co.caption(f.gl, s.font, "tap = split into letters, drag-and-drop = join - the two string ops as gestures");
}

/// Join every chip back into one sentence in visual (left-to-right) order and
/// show it live, so the string ops read as one evolving string.
fn drawHud(f: *z.Frame, s: *State, vw: f32, vh: f32) void {
    var order: [max_chips]usize = undefined;
    for (0..s.count) |k| {
        order[k] = k;
    }
    std.sort.pdq(usize, order[0..s.count], s, cmpByX);
    var joined: [1024]u8 = undefined;
    var w: usize = 0;
    for (order[0..s.count], 0..) |ci, n| {
        const t: []const u8 = s.chips[ci].text();
        if (n != 0 and w < joined.len) {
            joined[w] = ' ';
            w += 1;
        }
        const take: usize = @min(t.len, joined.len - w);
        @memcpy(joined[w .. w + take], t[0..take]);
        w += take;
    }
    var hud: [1100]u8 = undefined;
    const line: []const u8 = bufPrint(&hud, "{d} chips  |  {s}", .{ s.count, joined[0..w] }) catch joined[0..w];
    f.gl.rect(.{ .x = 0, .y = vh - 64, .width = vw, .height = 64 }, .{ .color = hud_bg });
    label(f, s, .{ 20, vh - 44 }, line, 17, hud_col);
}

fn cmpByX(s: *State, a: usize, b: usize) bool {
    return s.chips[a].pos[0] < s.chips[b].pos[0];
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - text - strings management (playground)",
            .width = 960,
            .height = 600,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
