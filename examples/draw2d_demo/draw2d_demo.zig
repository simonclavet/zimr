//! draw2d_demo — exercises the unified draw2d IMMEDIATE surface on the GPU
//! backend: `sink.rect` (fill + outline), `sink.circle`, and `sink.image` with a
//! Sprite (which uploads + caches its GPU residency on first draw). See
//! notes/drawing_api.md.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");

const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const Color = zm.Color;
const c = Color;

const screen_w = 800;
const screen_h = 450;

const State = struct {
    sprite: z.Sprite,
    font: z.Font,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const img: z.Image = try z.genImageChecked(
        gpa,
        64,
        64,
        8,
        8,
        .{ .r = 40, .g = 52, .b = 120, .a = 255 },
        .{ .r = 230, .g = 205, .b = 90, .a = 255 },
    );
    const sprite: z.Sprite = try z.Sprite.fromImage(gpa, img);
    z.unloadImage(gpa, img); // Sprite owns its own copy
    const font: z.Font = try z.loadFont(f, gpa, roboto_mono_ttf, 24);
    s.* = .{ .sprite = sprite, .font = font };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.sprite.deinit(gpa); // GPU residency is engine-owned (freed by resetRegistry)
}

fn update(f: *z.Frame, s: *State) void {
    // shapes (no texture)
    f.gl.rect(.{ .x = 40, .y = 40, .width = 200, .height = 120 }, .{ .color = c.gold });
    f.gl.rect(.{ .x = 40, .y = 180, .width = 200, .height = 120 }, .{ .color = c.red, .outline = 6 });
    f.gl.circle(.{ 120, 370 }, 44, .{ .color = .{ .r = 80, .g = 200, .b = 140, .a = 255 } });
    f.gl.circle(.{ 210, 370 }, 40, .{ .color = c.orange, .outline = 8 }); // ring

    // gap primitives (new emit geometry): rotated / rounded / gradient
    f.gl.rectRotated(
        .{ .x = 600, .y = 60, .width = 90, .height = 60 },
        .{ 45, 30 },
        0.5,
        .{ .color = c.blue },
    );
    f.gl.rectRoundedXYWH(560, 150, 130, 56, 0.6, 8, .{ .color = c.maroon });
    f.gl.triangleGradient(.{ 585, 245 }, .{ 705, 245 }, .{ 645, 305 }, c.red, c.lime, c.blue);
    f.gl.line(.{ 40, 320 }, .{ 250, 420 }, .{ .color = c.raywhite, .thickness = 5 });
    f.gl.text(.{ 40, 300 }, "draw2d text: one call, any sink", .{
        .size = 22,
        .color = c.raywhite,
        .font = &s.font,
    });

    // image via Sprite: whole, a source sub-rect, and tinted
    f.gl.image(.{ .x = 300, .y = 40, .width = 220, .height = 220 }, s.sprite, .{});
    f.gl.imageXYWH(560, 40, 200, 200, s.sprite, .{
        .source = .{ .x = 0, .y = 0, .width = 32, .height = 32 },
    });
    f.gl.image(.{ .x = 300, .y = 300, .width = 460, .height = 100 }, s.sprite, .{
        .tint = .{ .r = 255, .g = 170, .b = 170, .a = 255 },
    });
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - draw2d immediate surface",
            .width = screen_w,
            .height = screen_h,
            .clear = .{ .r = 0.08, .g = 0.09, .b = 0.11, .a = 1.0 },
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
