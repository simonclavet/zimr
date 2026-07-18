// examples/colors_palette.zig - interactive grid of raylib's 21
// named colour constants.
// Port of raylib's `examples/shapes/shapes_colors_palette.c` (★2,
// ~105 LOC).  Each colour gets a 100×100 swatch in a 7×3 grid;
// hovering reveals the colour name and a darker bottom strip.
// Holding SPACE reveals all labels at once.
// What this exercises:
//   - `z.colors.Color` namespace - the static raylib palette is
//     exposed as `Color.maroon`, `Color.gold`, etc. (see
//     `src/types.zig`'s field list).
//   - `z.drawRectangleRec` and `drawRectangleLinesThick` for
//     filled vs outlined swatches.
//   - Per-swatch hover state via the rectangle-point overlap test
//     (this maps to raylib's `CheckCollisionPointRec`; zimr's
//     equivalent is the small math helper at the bottom).
//   - `Color.fade(c, alpha)` - the standard "transparency"
//     operation; in raylib it's the `Fade()` macro.  In zimr it's
//     a method on `Color`.  Same multiplier semantics.
// Controls:
//   Hover    swatch fades and reveals the colour name in its bottom strip
//   SPACE    reveal every label at once

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;
const Vec2 = zm.Vec2;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const screen_w: i32 = 800;
const screen_h: i32 = 450;
const swatch_size: f32 = 100.0;
const gap: f32 = 10.0;
const cols: usize = 7;
const rows: usize = 3;
const total: usize = cols * rows;

const c = Color;

// The 21 named raylib colours in the order raylib's example uses
// them.  Order matters for the grid layout below.
const palette = [total]Color{
    c.darkgray,  c.maroon, c.orange, c.darkgreen, c.darkblue, c.darkpurple, c.darkbrown,
    c.gray,      c.red,    c.gold,   c.lime,      c.blue,     c.violet,     c.brown,
    c.lightgray, c.pink,   c.yellow, c.green,     c.skyblue,  c.purple,     c.beige,
};

const names = [total][]const u8{
    "DARKGRAY",  "MAROON", "ORANGE", "DARKGREEN", "DARKBLUE", "DARKPURPLE", "DARKBROWN",
    "GRAY",      "RED",    "GOLD",   "LIME",      "BLUE",     "VIOLET",     "BROWN",
    "LIGHTGRAY", "PINK",   "YELLOW", "GREEN",     "SKYBLUE",  "PURPLE",     "BEIGE",
};

const State = struct {
    /// Owned shapes-texture state.  Default-init points at rlgl's
    /// internal 1x1 white pixel (texture id=1) - no upload needed.
    /// Owned default-font cache.  Populated by `z.loadFontFromTtfBytes`
    /// in `initState` below.
    font: z.Font,
    frame_count: usize = 0,
    /// Bitmask of "this swatch is being hovered" - set during the
    /// hover pass each frame.  Could fit in a single u32 but the
    /// bool array reads cleaner in the draw loop.
    hover: [total]bool = @splat(false),
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 32);
    s.* = .{ .font = font };
}

/// Point-in-rectangle hit test.  Closed on min, open on max
/// (matches raylib's `CheckCollisionPointRec`).
fn pointInRect(p: Vec2, r: z.Rectangle) bool {
    return p[0] >= r.x and p[0] <= (r.x + r.width) and
        p[1] >= r.y and p[1] <= (r.y + r.height);
}

/// Compute the rectangle for swatch index `i` in the 7×3 grid.
fn swatchRect(i: usize) z.Rectangle {
    const col: f32 = float(i % cols);
    const row: f32 = float(i / cols);
    return .{
        .x = 20.0 + (swatch_size + gap) * col,
        .y = 80.0 + (swatch_size + gap) * row,
        .width = swatch_size,
        .height = swatch_size,
    };
}

fn update(f: *z.Frame, state: *State) void {
    state.frame_count += 1;
    const mp: Vec2 = z.getMousePosition(f.input);
    const mouse: Vec2 = .{ mp[0], mp[1] };

    // ---- Hit-test every swatch ------------------------------------------
    for (0..total) |i| {
        state.hover[i] = pointInRect(mouse, swatchRect(i));
    }

    const reveal_all: bool = z.isKeyDown(f.input, .space);

    // ---- Render -----------------------------------------------------------
    z.clearViewport(f, c.raywhite);

    f.gl.text(.{ 28, 42 }, "raylib colors palette", .{ .size = 20, .color = c.black, .font = &state.font });
    f.gl.text(
        .{ screen_w - 180, screen_h - 40 },
        "press SPACE to see all colors",
        .{ .size = 10, .color = c.gray, .font = &state.font },
    );

    for (0..total) |i| {
        const rect: z.Rectangle = swatchRect(i);
        const fill: Color = if (state.hover[i]) palette[i].fade(0.6) else palette[i];

        f.gl.rect(rect, .{ .color = fill });

        // Show label if either reveal-all is on or the swatch is hovered.
        if (reveal_all or state.hover[i]) {
            // Dark strip behind the label (raylib uses a black bar
            // at the bottom of the swatch).
            f.gl.rect(
                .{ .x = rect.x, .y = rect.y + rect.height - 26, .width = rect.width, .height = 20.0 },
                .{ .color = c.black },
            );
            // Border around the entire swatch in faded black.
            f.gl.rect(
                .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height },
                .{ .color = c.black.fade(0.3), .outline = 6 },
            );

            // Name aligned to the right inside the dark strip,
            // coloured with the swatch's own colour so it reads
            // against black.
            const label_w: f32 = z.measureText(state.font, names[i], 10)[0];
            const tx: f32 = rect.x + rect.width - label_w - 12;
            const ty: f32 = rect.y + rect.height - 20;
            f.gl.text(.{ tx, ty }, names[i], .{ .size = 10, .color = palette[i], .font = &state.font });
        }
    }
    z.endDrawing(f.gl);
}

/// User-owned framework integration point.  See `examples/basic.zig`
/// for the canonical comment block; this declaration is the
/// AppBridge pattern's required convention.
/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - colors palette",
            .width = screen_w,
            .height = screen_h,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
