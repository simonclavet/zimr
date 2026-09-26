//! textures_mouse_painting - port of raylib [textures] example.
//! Paint onto a persistent render-texture canvas with the mouse and pick from a
//! color palette. The canvas ACCUMULATES: the paint pass reopens it with a null
//! clear (LOAD), so strokes build up frame to frame. Offscreen-first: the paint
//! pass runs before the screen opens (tile-based-GPU safe).
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Vec2 = zm.Vec2;
const Color = zm.Color;

const palette = [_]Color{
    .{ .r = 230, .g = 41, .b = 55, .a = 255 },
    .{ .r = 255, .g = 161, .b = 0, .a = 255 },
    .{ .r = 253, .g = 249, .b = 0, .a = 255 },
    .{ .r = 0, .g = 228, .b = 48, .a = 255 },
    .{ .r = 0, .g = 121, .b = 241, .a = 255 },
    .{ .r = 200, .g = 122, .b = 255, .a = 255 },
    .{ .r = 255, .g = 109, .b = 194, .a = 255 },
    .{ .r = 127, .g = 106, .b = 79, .a = 255 },
    .{ .r = 20, .g = 20, .b = 24, .a = 255 },
    .{ .r = 245, .g = 245, .b = 245, .a = 255 },
};
const num_colors: usize = palette.len;
const swatch: f32 = 42.0;
const pal_top: f32 = 10.0;
const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

const State = struct {
    canvas: z.RenderTexture = .{},
    selected: usize = 0,
    brush: f32 = 20.0,
};

fn deinit(gpa: Allocator, s: *State) void {
    _ = gpa;
    s.canvas.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    _ = gpa;
    _ = f;
    s.* = .{};
}

fn update(f: *z.Frame, s: *State) void {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();

    // Lazily create the canvas at window size and clear it once to off-white.
    if (s.canvas.color == .invalid) {
        s.canvas = z.loadRenderTexture(f.gl, @trunc(w), @trunc(h));
        z.beginTextureMode(f.gl, s.canvas, .{ .r = 245, .g = 245, .b = 245, .a = 255 });
        z.endTextureMode(f.gl);
    }

    const mp: Vec2 = z.getMousePosition(f.input);
    const pal_h: f32 = swatch + pal_top * 2.0;

    // Palette hit-test + selection.
    var over_palette: bool = false;
    var i: usize = 0;
    while (i < num_colors) : (i += 1) {
        const sx: f32 = 10.0 + float(i) * (swatch + 6.0);
        if (mp[0] >= sx and mp[0] <= sx + swatch and mp[1] >= pal_top and mp[1] <= pal_top + swatch) {
            over_palette = true;
            if (z.isMouseButtonPressed(f.input, .left)) {
                s.selected = i;
            }
        }
    }

    // Paint into the canvas (offscreen, LOAD) while dragging below the palette.
    if (z.isMouseButtonDown(f.input, .left) and !over_palette and mp[1] > pal_h) {
        z.beginTextureMode(f.gl, s.canvas, null);
        f.gl.circle(mp, s.brush, .{ .color = palette[s.selected], .segments = 16 });
        z.endTextureMode(f.gl);
    }

    // SCREEN PASS: composite canvas, then palette + brush preview on top.
    z.beginDrawing(f.gl);
    z.clearViewport(f, .{ .r = 20, .g = 22, .b = 30, .a = 255 });
    f.gl.texture(.{ .x = 0, .y = 0, .width = w, .height = h }, s.canvas.asTexture(), .{ .tint = white });

    i = 0;
    while (i < num_colors) : (i += 1) {
        const sx: f32 = 10.0 + float(i) * (swatch + 6.0);
        f.gl.rect(.{ .x = sx, .y = pal_top, .width = swatch, .height = swatch }, .{ .color = palette[i] });
        if (i == s.selected) {
            f.gl.rect(
                .{ .x = sx - 2.0, .y = pal_top - 2.0, .width = swatch + 4.0, .height = swatch + 4.0 },
                .{ .color = white, .outline = 1.0 },
            );
        }
    }

    if (mp[1] > pal_h) {
        f.gl.circle(mp, s.brush, .{ .color = palette[s.selected], .outline = 1 });
    }

    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{ .window = .{
        .title = "zimr - WebGPU - textures mouse painting",
        .width = 800,
        .height = 450,
        .scale_mode = .responsive,
    } },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
    .manages_own_frame = true,
};
