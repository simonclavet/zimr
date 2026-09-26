//! textures_npatch_drawing — nine-slice (9-patch) panel drawing. A procedurally
//! generated UI panel is sliced into 9 regions (4 fixed 16 px corners, 4 edges,
//! 1 center) sized by the mouse; corners stay fixed while edges + center stretch.
//! Ports raylib's `textures_npatch_drawing` (procedural panel instead of the
//! resources/ninepatch_button.png asset). The 9-patch goes through the unified
//! `sink.image` path with `.npatch` set — one 2D drawing surface, no separate call.
//!
//! Leak-clean (`.memory = .managed`): the Sprite's Image copy is freed in `deinit`;
//! its GPU texture + the font atlas are engine-owned (freed by resetRegistry).

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const Color = zm.Color;
const c = Color;
const clamp = zm.clamp;

const screen_w = 800;
const screen_h = 450;
const patch_px: usize = 64;
const border_px: f32 = 16.0;

const State = struct {
    sprite: z.Sprite,
    font: z.Font,
};

/// Build a 64×64 UI-panel nine-patch in RGBA: a gold frame with a dark outer
/// line and a bright accent dot in each corner, over a translucent blue fill.
/// The distinct corner dots make the 9-slice obvious — they never distort while
/// the edges + center stretch.
fn makeNinePatch(gpa: Allocator) !z.Image {
    const w: usize = patch_px;
    const h: usize = patch_px;
    const px: []u8 = try gpa.alloc(u8, w * h * 4);
    const b: usize = 16;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const ex: usize = @min(x, w - 1 - x);
            const ey: usize = @min(y, h - 1 - y);
            const edge: usize = @min(ex, ey);
            var col: Color = .{ .r = 30, .g = 40, .b = 80, .a = 210 }; // fill
            if (edge < b) {
                col = if (edge < 2)
                    Color{ .r = 40, .g = 34, .b = 60, .a = 255 } // outer line
                else
                    Color{ .r = 230, .g = 190, .b = 90, .a = 255 }; // gold frame
                if (ex < b and ey < b) {
                    const cx: f32 = if (x < b) 7.0 else @floatFromInt(w - 8);
                    const cy: f32 = if (y < b) 7.0 else @floatFromInt(h - 8);
                    const dx: f32 = float(x) - cx;
                    const dy: f32 = float(y) - cy;
                    if (dx * dx + dy * dy < 16.0) {
                        col = .{ .r = 250, .g = 240, .b = 200, .a = 255 }; // accent dot
                    }
                }
            }
            const i: usize = (y * w + x) * 4;
            px[i + 0] = col.r;
            px[i + 1] = col.g;
            px[i + 2] = col.b;
            px[i + 3] = col.a;
        }
    }
    return .{
        .data = px.ptr,
        .width = @intCast(w),
        .height = @intCast(h),
        .mipmaps = 1,
        .format = @backingInt(z.PixelFormat.uncompressed_r8g8b8a8),
    };
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const img: z.Image = try makeNinePatch(gpa);
    // A Sprite owns a copy of the pixels; sink.image uploads + caches the GPU
    // texture lazily on first draw and binds it by id for the 9-patch.
    const sprite: z.Sprite = try z.Sprite.fromImage(gpa, img);
    z.unloadImage(gpa, img);
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20);
    s.* = .{ .sprite = sprite, .font = font };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.sprite.deinit(gpa);
}

fn update(f: *z.Frame, s: *State) void {
    const mouse: zm.Vec2 = z.getMousePosition(f.input);
    const ox: f32 = 120.0;
    const oy: f32 = 110.0;
    const dw: f32 = clamp(mouse[0] - ox, 40.0, 560.0);
    const dh: f32 = clamp(mouse[1] - oy, 40.0, 300.0);

    const info: z.NPatchInfo = .{
        .source = .{ .x = 0, .y = 0, .width = @floatFromInt(patch_px), .height = @floatFromInt(patch_px) },
        .left = @intFromFloat(border_px),
        .top = @intFromFloat(border_px),
        .right = @intFromFloat(border_px),
        .bottom = @intFromFloat(border_px),
        .layout = 0, // NPATCH_NINE_PATCH
    };
    const dest: z.Rectangle = .{ .x = ox, .y = oy, .width = dw, .height = dh };
    f.gl.image(dest, s.sprite, .{ .npatch = info });

    f.gl.text(
        .{ 24, 24 },
        "Move the mouse: resize the 9-patch panel",
        .{ .size = 20, .color = c.raywhite, .font = &s.font },
    );
    f.gl.text(
        .{ 24, 50 },
        "Corners stay fixed, edges + center stretch",
        .{ .size = 18, .color = .{ .r = 170, .g = 175, .b = 200, .a = 255 }, .font = &s.font },
    );
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - textures N-patch drawing",
            .width = screen_w,
            .height = screen_h,
            .clear = .{ .r = 20.0 / 255.0, .g = 22.0 / 255.0, .b = 30.0 / 255.0, .a = 1.0 },
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
