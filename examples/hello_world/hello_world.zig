// examples/hello_world.zig - the simplest possible text demo.
// Just renders "Hello, World!" with the default font on a plain
// background.  No UI, no widgets, no animation.  Built to isolate
// the font-default migration: if text shows here, the font is
// working; if not, the migration is broken and the bug is in the
// load/bake/draw path, not in any UI layer above.

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const float = zm.float;

const State = struct {
    font: z.Font,
};

/// User-owned framework integration point.  See `examples/basic.zig`
/// for the canonical comment block; this declaration is the
/// AppBridge pattern's required convention.
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 32);
    s.* = .{ .font = font };
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, .{ .r = 30, .g = 30, .b = 40, .a = 255 });

    // Responsive coord space - these update on resize / rotation
    // and the runtime's per-frame ortho reset keeps draw coords
    // 1:1 with CSS pixels.  See zimr.zig per-frame size block.
    const sw: f32 = f.window.widthf();
    const sh: f32 = f.window.heightf();
    const cx: f32 = sw / 2;
    const cy: f32 = sh / 2;

    const white: Color = .{ .r = 240, .g = 240, .b = 240, .a = 255 };
    const dim: Color = .{ .r = 140, .g = 140, .b = 150, .a = 255 };
    const accent: Color = .{ .r = 96, .g = 165, .b = 250, .a = 255 };

    // Concentric rectangles centred in the canvas.  Smallest
    // dimension caps their size so they stay square-ish on any
    // aspect ratio (phone portrait, phone landscape, desktop wide).
    const min_dim: f32 = @min(sw, sh);
    var i: i32 = 1;
    while (i <= 4) : (i += 1) {
        const half: f32 = min_dim * float(i) / 12.0;
        const rec: z.Rectangle = .{
            .x = cx - half,
            .y = cy - half,
            .width = 2 * half,
            .height = 2 * half,
        };
        f.gl.rect(
            .{ .x = rec.x, .y = rec.y, .width = rec.width, .height = rec.height },
            .{ .color = accent, .outline = 2 },
        );
    }

    f.gl.text(.{ cx - 90, cy - 18 }, "Hello, World!", .{ .size = 32, .color = white, .font = &s.font });

    var dim_buf: [64]u8 = undefined;
    const dim_text: []const u8 = bufPrint(
        &dim_buf,
        "viewport: {d} x {d} CSS px",
        .{ sw, sh },
    ) catch "viewport: ?";
    f.gl.text(.{ cx - 110, cy + 30 }, dim_text, .{ .size = 14, .color = dim, .font = &s.font });

    f.gl.text(
        .{ 16, sh - 24 },
        "rotate the phone or resize the window",
        .{ .size = 12, .color = dim, .font = &s.font },
    );
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - hello_world",
            .width = 480,
            .height = 200,
            // Logical coordinate space tracks the canvas's CSS
            // pixels - runtime resets `rlOrtho` each frame so
            // draw coords are 1:1 with `f.window.screen_width`.
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
