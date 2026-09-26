// examples/easings_box.zig - five-stage box animation that
// chains elasticOut, bounceOut, quadOut, circOut and sineOut.
// Port of raylib's `examples/shapes/shapes_easings_box.c` (*2,
// ~142 LOC).  Each stage uses a different curve so the visual
// rhythm of the animation runs through a tour of the easing
// catalogue:
//   Stage 0 - box drops in from above; elasticOut (overshoots
//             past the centre then bounces back).  120 frames.
//   Stage 1 - box scales to a horizontal bar; bounceOut on both
//             width and height simultaneously.  120 frames.
//   Stage 2 - bar rotates 270 deg around its centre; quadOut (slow
//             deceleration into rest).  240 frames.
//   Stage 3 - bar's height grows to fill the screen; circOut
//             (sharp acceleration then easing to rest).  120 frames.
//   Stage 4 - whole rectangle fades out; sineOut (smooth alpha
//             ramp).  160 frames.
// What this exercises:
//   - Five easing curves used back-to-back, in a single switch.
//   - `z.drawRectangleRotated` for a centred + rotated draw.
//   - Stage timing kept exactly per raylib's source (no
//     compression or fitting; the demo's whole point is the
//     tour, so the lengths matter).
// Controls:
//   SPACE  - reset to stage 0 with default rect/rotation/alpha

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const pi = zm.pi;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const clamp = zm.clamp;

const screen_w: i32 = 800;
const screen_h: i32 = 450;
const screen_w_f: f32 = float(screen_w);
const screen_h_f: f32 = float(screen_h);

const stage0_duration: f32 = 120;
const stage1_duration: f32 = 120;
const stage2_duration: f32 = 240;
const stage3_duration: f32 = 120;
const stage4_duration: f32 = 160;

const c = Color;

const State = struct {
    /// Owned shapes-texture state. id=1 -> rlgl's internal 1x1 white pixel.
    /// Owned default-font cache. Populated by `loadFontFromTtfBytes` below.
    font: z.Font,
    frame_count: usize = 0,
    stage: u8 = 0,
    progress: f32 = 0,
    rect: z.Rectangle = .{
        .x = screen_w_f / 2.0,
        .y = -100,
        .width = 100,
        .height = 100,
    },
    rotation: f32 = 0,
    alpha: f32 = 1.0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 32);
    s.* = .{ .font = font };
}

fn update(f: *z.Frame, state: *State) void {
    state.frame_count += 1;
    const dt: f32 = @floatCast(f.time.delta_time);
    const tick: f32 = dt * 60.0;

    // Reset everything to stage 0 defaults.
    if (z.isKeyPressed(f.input, .space)) {
        state.stage = 0;
        state.progress = 0;
        state.rect = .{
            .x = screen_w_f / 2.0,
            .y = -100,
            .width = 100,
            .height = 100,
        };
        state.rotation = 0;
        state.alpha = 1.0;
    }

    // ---- State machine - advance progress, compute next frame's
    // animated values per stage.
    switch (state.stage) {
        0 => {
            // Drop in to screen-centre Y.  Travel: -100 -> screen_h/2,
            // i.e. change of (screen_h/2 + 100).
            state.progress += tick;
            const t01: f32 = clamp(state.progress / stage0_duration, 0, 1);
            const eased: f32 = z.easeElasticOut(t01);
            state.rect.y = -100.0 + eased * (screen_h_f / 2.0 + 100.0);
            if (state.progress >= stage0_duration) {
                state.progress = 0;
                state.stage = 1;
            }
        },
        1 => {
            // Scale to a flat bar.  Height shrinks 100 -> 10 (delta -90);
            // width grows 100 -> screen_w (delta screen_w).
            state.progress += tick;
            const t01: f32 = clamp(state.progress / stage1_duration, 0, 1);
            const eased: f32 = z.easeBounceOut(t01);
            state.rect.height = 100.0 + eased * (-90.0);
            state.rect.width = 100.0 + eased * screen_w_f;
            if (state.progress >= stage1_duration) {
                state.progress = 0;
                state.stage = 2;
            }
        },
        2 => {
            // Spin 270 deg around the rect's centre.
            state.progress += tick;
            const t01: f32 = clamp(state.progress / stage2_duration, 0, 1);
            state.rotation = z.easeQuadOut(t01) * (pi * 1.5);
            if (state.progress >= stage2_duration) {
                state.progress = 0;
                state.stage = 3;
            }
        },
        3 => {
            // Grow height from 10 -> 10 + screen_w (fills the screen
            // once rotated).
            state.progress += tick;
            const t01: f32 = clamp(state.progress / stage3_duration, 0, 1);
            const eased: f32 = z.easeCircOut(t01);
            state.rect.height = 10.0 + eased * screen_w_f;
            if (state.progress >= stage3_duration) {
                state.progress = 0;
                state.stage = 4;
            }
        },
        4 => {
            // Fade out - alpha goes 1.0 -> 0.0.
            state.progress += tick;
            const t01: f32 = clamp(state.progress / stage4_duration, 0, 1);
            state.alpha = 1.0 - z.easeSineOut(t01);
            if (state.progress >= stage4_duration) {
                state.progress = 0;
                state.stage = 5; // hold; SPACE resets
            }
        },
        else => {
            // Stage 5+: hold the final invisible-rect state.
        },
    }

    // ---- Render -----------------------------------------------------------
    z.clearViewport(f, c.raywhite);

    // Pivot at the rect's centre so rotation looks right.
    const origin: Vec2 = .{ state.rect.width / 2.0, state.rect.height / 2.0 };
    const tint: Color = c.black.fade(state.alpha);
    f.gl.rectRotated(state.rect, origin, state.rotation, .{ .color = tint });

    f.gl.text(
        .{ 10, screen_h - 25 },
        "PRESS [SPACE] TO RESET BOX ANIMATION!",
        .{ .size = 20, .color = c.lightgray, .font = &state.font },
    );
    z.endDrawing(f.gl);
}

/// User-owned framework integration point.  See `examples/basic.zig`
/// for the canonical comment block; this declaration is the
/// AppBridge pattern's required convention.
/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - easings box",
            .width = screen_w,
            .height = screen_h,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
