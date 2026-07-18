// examples/easings_ball.zig - three-stage ball animation that
// showcases the elastic and cubic easing curves.
// Port of raylib's `examples/shapes/shapes_easings_ball.c` (★2,
// ~116 LOC).  Plays three eased animations back-to-back:
//   Stage 0 - ball slides in from off-screen left, easing OUT.
//             Curve: elasticOut (overshoots then settles).
//             Duration: 120 frames (~2s at 60fps).
//   Stage 1 - ball radius grows from 20 → 520, easing IN.
//             Curve: elasticIn (pulls back before the launch).
//             Duration: 200 frames.
//   Stage 2 - ball fades from RED to transparent against a GREEN
//             background reveal, easing OUT.
//             Curve: cubicOut.
//             Duration: 200 frames.
//   Stage 3 - done; ENTER replays from stage 0.
// What this exercises:
//   - `z.easeElasticOut` / `elasticIn` / `cubicOut` - three
//     of the curves from the new `src/easings.zig` module.
//   - The "frames-counter" idiom: each stage runs for N frames of
//     a known total D, with t01 = frames/D in [0,1].
//   - A small state machine that advances on completion of each
//     stage and pauses on the final stage waiting for input.
// Why dt-scaled framesCounter vs raw frame count?  raylib's
// original just increments framesCounter once per loop iteration.
// We do the same but with `f.time.delta_time * 60` so that the
// stages take the same wall-clock time regardless of frame rate.
// Controls:
//   ENTER  - when on stage 3 (done), replay from the start
//   R      - reset the current stage's progress without changing stage

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");
const clamp = zm.clamp;
const float = zm.float;

const screen_w: i32 = 800;
const screen_h: i32 = 450;

// Each stage's frame budget.  Numbers from raylib's source; kept
// the same so the visual timing matches the original 1:1.
const stage0_duration: f32 = 120;
const stage1_duration: f32 = 200;
const stage2_duration: f32 = 200;

// raylib's named palette aliased once so the example body reads
// like the source.
const c = Color;

const State = struct {
    /// Owned shapes-texture state. id=1 → rlgl's internal 1x1 white pixel.
    /// Owned default-font cache. Populated by `loadFontFromTtfBytes` below.
    font: z.Font,
    ui_host: z.UiHost,
    frame_count: usize = 0,
    /// Which stage of the animation is currently playing (0..3).
    stage: u8 = 0,
    /// Progress within the current stage, in scaled frames.  Each
    /// stage compares this to its own `stageN_duration` constant.
    progress: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, roboto_mono_ttf, 32);
    s.* = .{ .font = font, .ui_host = z.UiHost.init(gpa, font) };
}

fn update(f: *z.Frame, state: *State) void {
    state.frame_count += 1;

    // dt-scaled frame counter so timing is rate-independent.
    const dt: f32 = @floatCast(f.time.delta_time);
    const tick: f32 = dt * 60.0;

    // ---- Input -----------------------------------------------------------
    if (z.isKeyPressed(f.input, .r)) {
        state.progress = 0;
    }
    if (state.stage == 3 and z.isKeyPressed(f.input, .enter)) {
        // Replay from the top.
        state.* = .{ .frame_count = state.frame_count, .font = state.font, .ui_host = state.ui_host };
    }

    // ---- State machine --------------------------------------------------
    // Each stage advances `progress` by one tick per frame, then
    // checks for completion.  We compute the eased value for the
    // current stage and store it in the locals below for the
    // render pass.
    var ball_x: f32 = -100;
    var ball_radius: f32 = 20;
    var ball_alpha: f32 = 0; // 0 = opaque, 1 = transparent
    var show_green_bg: bool = false;

    switch (state.stage) {
        0 => {
            // Slide in from x = -100 to x = (screen_w/2 + 100 - 100) = screen_w/2,
            // i.e. travel "screen_w/2 + 100" pixels in 120 frames.
            // raylib's 4-arg form: Ease(t, b=-100, c=screen_w/2+100, d=120).
            // [0,1] form: ball_x = b + ease(t/d) * c.
            state.progress += tick;
            const t01: f32 = clamp(state.progress / stage0_duration, 0, 1);
            const eased: f32 = z.easeElasticOut(t01);
            ball_x = -100.0 + eased * (float(screen_w) / 2.0 + 100.0);
            if (state.progress >= stage0_duration) {
                state.progress = 0;
                state.stage = 1;
            }
        },
        1 => {
            // Radius grows from 20 to 520 over 200 frames.
            state.progress += tick;
            const t01: f32 = clamp(state.progress / stage1_duration, 0, 1);
            const eased: f32 = z.easeElasticIn(t01);
            ball_x = float(screen_w) / 2.0;
            ball_radius = 20.0 + eased * 500.0;
            if (state.progress >= stage1_duration) {
                state.progress = 0;
                state.stage = 2;
            }
        },
        2 => {
            // Alpha-fades the ball away while the green background
            // is revealed underneath.
            state.progress += tick;
            const t01: f32 = clamp(state.progress / stage2_duration, 0, 1);
            ball_alpha = z.easeCubicOut(t01);
            ball_x = float(screen_w) / 2.0;
            ball_radius = 520;
            show_green_bg = true;
            if (state.progress >= stage2_duration) {
                state.progress = 0;
                state.stage = 3;
            }
        },
        3 => {
            // Done - hold the final frame.  ball_x/radius/alpha are
            // already at their end-of-stage-2 values from the
            // previous frame; we just need to keep showing them.
            ball_x = float(screen_w) / 2.0;
            ball_radius = 520;
            ball_alpha = 1.0;
            show_green_bg = true;
        },
        else => unreachable,
    }

    // ---- Render ----------------------------------------------------------
    z.clearViewport(f, c.raywhite);

    if (show_green_bg) {
        f.gl.rect(.{ .x = 0, .y = 0, .width = float(screen_w), .height = float(screen_h) }, .{ .color = c.green });
    }

    // Ball is RED with alpha = 1 - ball_alpha (so 0 = opaque, 1 = invisible).
    const fill_alpha: f32 = 1.0 - ball_alpha;
    const ball_color: Color = c.red.fade(fill_alpha);
    f.gl.circle(.{ ball_x, 200 }, ball_radius, .{ .color = ball_color, .segments = 16 });

    if (state.stage == 3) {
        f.gl.text(
            .{ 240, 200 },
            "PRESS [ENTER] TO PLAY AGAIN!",
            .{ .size = 20, .color = c.black, .font = &state.font },
        );
    }

    // Touch control: a replay button (phones have no Enter key). The R/Enter
    // keyboard shortcuts still work on desktop.
    const ui: z.ui_real.Ui = state.ui_host.begin(f);
    if (ui.window("Easings", .{ .initial_pos = .{ 14, 14 }, .initial_size = .{ 160, 70 } })) |w| {
        defer w.close();
        if (ui.button("replay", .{})) {
            state.stage = 0;
            state.progress = 0;
            state.frame_count = 0;
        }
    }
    state.ui_host.render(f);

    z.endDrawing(f.gl);
}

/// User-owned framework integration point.  See `examples/basic.zig`
/// for the canonical comment block; this declaration is the
/// AppBridge pattern's required convention.
/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - easings ball",
            .width = screen_w,
            .height = screen_h,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
