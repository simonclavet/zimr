// examples/scissor_test.zig - hardware scissor-rectangle clipping.
// Port of raylib's `examples/core/core_scissor_test.c`. A box follows your
// finger; while the test is ON, a full-screen red fill and a line of text are
// clipped to that box by the GPU scissor — not by any per-primitive masking.
//
// Toggling is a UI BUTTON (not the S key) so it's testable by tapping on a
// phone; the S key still works if there's a hardware keyboard.
//
// Two things this example gets right that are easy to get wrong:
//
//   1. SUBMIT THE UI BEFORE ASKING IF IT OWNS THE POINTER. `wantCaptureMouse`
//      hit-tests the windows submitted THIS frame, so calling it before the
//      window is declared always returns false — and the box would then jump to
//      your finger while you were tapping a button, dragging the scene out from
//      under the UI.
//
//   2. THE BOX FOLLOWS THE FINGER; THE SCISSOR RECT IS WHAT GETS CLAMPED. WebGPU
//      requires the scissor rect to lie inside the render area (outside it, the
//      containment assert in wgpu_app fires and the command buffer is rejected).
//      The naive fix — clamp the BOX so it never leaves the window — confines the
//      box's CENTRE to [half_box, w - half_box], which on a narrow phone screen
//      strands the box far to the right of where you actually touched. So the box
//      tracks the finger exactly, and the rect handed to the GPU is the
//      INTERSECTION of the box with the window.
//
// Leak-clean (`.memory = .managed`): the UiHost is deinit'd; the atlas is
// engine-owned.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const Color = zm.Color;
const c = Color;
const clamp = zm.clamp;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    ui_font: z.Font,
    scissor_on: bool = true,
    box: z.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const ui_font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20);
    s.* = .{ .ui_host = z.UiHost.init(gpa, ui_font), .font = font, .ui_font = ui_font };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.unloadFont(gpa, s.ui_font);
    s.ui_host.deinit();
}

fn update(f: *z.Frame, s: *State) void {
    const sw: f32 = f.window.widthf();
    const sh: f32 = f.window.heightf();
    // Sized off the LIVE window, so the box is sane on a phone and on desktop.
    const box_size: f32 = @min(sw, sh) * 0.5;

    if (z.isKeyPressed(f.input, .s)) { // hardware keyboard, if there is one
        s.scissor_on = !s.scissor_on;
    }

    z.clearViewport(f, c.raywhite);

    const u: z.ui_real.Ui = s.ui_host.begin(f);

    // (1) SUBMIT the UI first — `wantCaptureMouse` hit-tests this frame's
    // windows, so querying it before they exist would always say "not mine".
    // Submitting early does NOT change draw order: ui_host.render(f) still
    // composites the UI last, on top of the scene.
    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ sw - 16.0, 130 }, .{});
    if (u.window("Scissor test", .{})) |w| {
        defer w.close();
        u.text("Drag below the panel to move the box.", .{});
        u.separator();
        const label: []const u8 = if (s.scissor_on) "Scissor: ON (tap to disable)" else "Scissor: OFF (tap to enable)";
        if (u.button(label, .{})) {
            s.scissor_on = !s.scissor_on;
        }
        u.text("box {d:.0},{d:.0}  window {d:.0}x{d:.0}", .{ s.box.x, s.box.y, sw, sh });
    }

    // (2) The box is centred EXACTLY on the finger — no clamping here, or it
    // would lag to one side near the screen edges. Frozen while the pointer is
    // over the UI, so tapping a button doesn't drag the box along with it.
    if (!u.wantCaptureMouse()) {
        const p: zm.Vec2 = z.getMousePosition(f.input);
        s.box = .{
            .x = p[0] - box_size * 0.5,
            .y = p[1] - box_size * 0.5,
            .width = box_size,
            .height = box_size,
        };
    } else {
        s.box.width = box_size; // keep in sync if the window resized
        s.box.height = box_size;
    }

    // The GPU scissor rect = box ∩ window. This is the ONLY thing that needs
    // clamping, and clamping it here keeps WebGPU's containment rule satisfied.
    const x0: f32 = clamp(s.box.x, 0.0, sw);
    const y0: f32 = clamp(s.box.y, 0.0, sh);
    const x1: f32 = clamp(s.box.x + s.box.width, 0.0, sw);
    const y1: f32 = clamp(s.box.y + s.box.height, 0.0, sh);
    const clip_w: f32 = x1 - x0;
    const clip_h: f32 = y1 - y0;

    // One screen-filling draw + a line of text: with the scissor active only the
    // slice inside the box is rasterised. If the box is entirely off-window the
    // intersection is empty — then NOTHING is drawn, which is what "clipped to an
    // empty region" actually means (drawing it unclipped would be a lie).
    if (!s.scissor_on) {
        drawClipped(f, s, sw, sh);
    } else if (clip_w > 0.0 and clip_h > 0.0) {
        z.beginScissorMode(f.gl, x0, y0, clip_w, clip_h);
        drawClipped(f, s, sw, sh);
        z.endScissorMode(f.gl);
    }

    // Drawn OUTSIDE the scissor, so the outline is always fully visible — it
    // shows where the box IS, even where its contents are clipped away.
    f.gl.rect(s.box, .{ .color = c.black, .outline = 2 });

    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

fn drawClipped(f: *z.Frame, s: *State, sw: f32, sh: f32) void {
    f.gl.rect(.{ .x = 0, .y = 0, .width = sw, .height = sh }, .{ .color = c.red });
    f.gl.text(
        .{ 20, sh * 0.55 },
        "Clipped by the GPU scissor",
        .{ .size = 20, .color = c.raywhite, .font = &s.font },
    );
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - core - scissor test",
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
