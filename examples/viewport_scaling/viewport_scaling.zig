// examples/viewport_scaling.zig - render at a FIXED virtual resolution, then
// letterbox it into whatever window/screen you actually get.
// Ports raylib's core `window_scale_letterbox` / viewport-scaling idea: the game
// renders into a 640x360 render texture (its "design resolution"), and each frame
// that texture is scaled by the LARGEST factor that still fits the real window,
// centred, with black bars filling the remainder. Aspect ratio is always
// preserved, so the layout never stretches. Mouse coordinates are mapped BACK
// through the same transform, so hit-testing works in virtual coordinates on any
// screen size.
//
// This is the manual, in-app version of the engine's `.scale_mode = .fit` (which
// does the same letterboxing at the window level). Doing it by hand is what
// raylib's sample teaches - and it's what you need when only PART of the app is
// a fixed-resolution viewport.
//
// What this exercises:
//   - `z.loadRenderTextureEx(..., nearest_filter)` + beginTextureMode/endTextureMode.
//   - Aspect-preserving fit math + the inverse mapping for input.
//
// Leak-clean (`.memory = .managed`): the RT is freed in `deinit`; the font atlas
// is engine-owned.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const Color = zm.Color;
const c = Color;
const Vec2 = zm.Vec2;
const bufPrint = std.fmt.bufPrint;

// The FIXED design resolution everything is authored against.
const virt_w: i32 = 640;
const virt_h: i32 = 360;
const virt_wf: f32 = 640.0;
const virt_hf: f32 = 360.0;

/// How the virtual viewport maps onto the real window: uniform scale + centring
/// offset. One value drives BOTH the draw (virtual -> screen) and the input
/// mapping (screen -> virtual), so they can never disagree.
const Fit = struct {
    scale: f32,
    off_x: f32,
    off_y: f32,

    fn compute(win_w: f32, win_h: f32) Fit {
        // Largest scale that fits BOTH axes = preserve aspect, never crop.
        const s: f32 = @min(win_w / virt_wf, win_h / virt_hf);
        return .{
            .scale = s,
            .off_x = (win_w - virt_wf * s) * 0.5,
            .off_y = (win_h - virt_hf * s) * 0.5,
        };
    }

    /// Screen (window) point -> virtual point. The exact inverse of the draw
    /// transform, so a click lands where the user sees it.
    fn toVirtual(self: Fit, p: Vec2) Vec2 {
        return .{
            (p[0] - self.off_x) / self.scale,
            (p[1] - self.off_y) / self.scale,
        };
    }
};

const State = struct {
    rt: z.RenderTexture,
    font: z.Font,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    // nearest: the virtual viewport is scaled by an arbitrary (often fractional)
    // factor, and point sampling keeps the edges honest rather than mushy.
    const rt: z.RenderTexture = z.loadRenderTextureEx(f.gl, virt_w, virt_h, true);
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20);
    s.* = .{ .rt = rt, .font = font };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.rt.deinit();
}

/// The "game", authored entirely in 640x360 virtual coordinates. It never knows
/// what the real window size is.
fn drawGame(gl: *z.WgpuGl, font: *z.Font, mouse_virt: Vec2, t: f32) void {
    // Border + corner markers prove the virtual viewport is fully visible and
    // never cropped, whatever the window aspect.
    gl.rect(.{ .x = 0, .y = 0, .width = virt_wf, .height = virt_hf }, .{ .color = c.darkgray, .outline = 4 });
    const corner: f32 = 26;
    gl.rect(.{ .x = 0, .y = 0, .width = corner, .height = corner }, .{ .color = c.red });
    gl.rect(.{ .x = virt_wf - corner, .y = 0, .width = corner, .height = corner }, .{ .color = c.lime });
    gl.rect(.{ .x = 0, .y = virt_hf - corner, .width = corner, .height = corner }, .{ .color = c.blue });
    gl.rect(.{ .x = virt_wf - corner, .y = virt_hf - corner, .width = corner, .height = corner }, .{ .color = c.gold });

    // A grid so scaling is obvious.
    var gx: f32 = 40;
    while (gx < virt_wf) : (gx += 40) {
        gl.line(.{ gx, 0 }, .{ gx, virt_hf }, .{ .color = .{ .r = 220, .g = 220, .b = 228, .a = 255 } });
    }
    var gy: f32 = 40;
    while (gy < virt_hf) : (gy += 40) {
        gl.line(.{ 0, gy }, .{ virt_wf, gy }, .{ .color = .{ .r = 220, .g = 220, .b = 228, .a = 255 } });
    }

    // A bouncing ball in virtual space.
    const bx: f32 = virt_wf * 0.5 + @sin(t * 0.9) * (virt_wf * 0.35);
    const by: f32 = virt_hf * 0.5 + @cos(t * 1.3) * (virt_hf * 0.28);
    gl.circle(.{ bx, by }, 22, .{ .color = c.maroon });

    gl.text(
        .{ 40, 40 },
        "640x360 virtual viewport",
        .{ .size = 22, .color = c.darkgray, .font = font },
    );

    // Crosshair at the mapped mouse position - the proof that screen->virtual
    // input mapping is correct. It should sit exactly under the real cursor.
    const mx: f32 = mouse_virt[0];
    const my: f32 = mouse_virt[1];
    gl.line(.{ mx - 14, my }, .{ mx + 14, my }, .{ .color = c.darkblue, .thickness = 2 });
    gl.line(.{ mx, my - 14 }, .{ mx, my + 14 }, .{ .color = c.darkblue, .thickness = 2 });
    gl.circle(.{ mx, my }, 6, .{ .color = c.darkblue, .outline = 2 });
}

fn update(f: *z.Frame, s: *State) void {
    const win_w: f32 = f.window.widthf();
    const win_h: f32 = f.window.heightf();
    const fit: Fit = .compute(win_w, win_h);

    // Map the real cursor into virtual coordinates BEFORE drawing the game, so
    // the game only ever deals in its own 640x360 space.
    const mouse_virt: Vec2 = fit.toVirtual(z.getMousePosition(f.input));

    // --- the game renders into its fixed-resolution target ---
    z.beginTextureMode(f.gl, s.rt, .{ .r = 245, .g = 245, .b = 245, .a = 255 });
    drawGame(f.gl, &s.font, mouse_virt, f.time.time);
    z.endTextureMode(f.gl);

    // --- letterbox: scale up as far as fits, centre, black bars around it ---
    z.clearViewport(f, c.black);
    const dest: z.Rectangle = .{
        .x = fit.off_x,
        .y = fit.off_y,
        .width = virt_wf * fit.scale,
        .height = virt_hf * fit.scale,
    };
    f.gl.texture(dest, s.rt.asTexture(), .{});

    // HUD drawn in REAL screen space (outside the viewport), showing the fit.
    var buf: [96]u8 = undefined;
    const hud: []const u8 = bufPrint(
        &buf,
        "window {d:.0}x{d:.0}  scale {d:.2}x  bars {d:.0},{d:.0}",
        .{ win_w, win_h, fit.scale, fit.off_x, fit.off_y },
    ) catch "?";
    f.gl.text(.{ 10, 10 }, hud, .{ .size = 16, .color = c.raywhite, .font = &s.font });

    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - core - viewport scaling (letterbox)",
            .width = 800,
            .height = 450,
            // RESPONSIVE on purpose: the window is the REAL device size, so the
            // letterbox math has something to solve. (`.fit` would do this same
            // job at the engine level - this example does it by hand.)
            .scale_mode = .responsive,
            .clear = .{ .r = 0, .g = 0, .b = 0, .a = 1.0 },
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
