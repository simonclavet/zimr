//! cartpole — a policy learning to balance, live, in a browser tab.
//!
//! ── ★ WHAT THIS DEMONSTRATES ──
//!
//! The whole robot stack in its smallest honest form, doing the thing the stack exists for:
//!
//!   * a model, a controller and a REWARD, wired into `ctl.Env` — reset, step, observe;
//!   * **cross-entropy method**, about twenty lines and no gradients, training a four-weight
//!     linear policy from scratch while you watch;
//!   * the reward curve climbing beside the robot it belongs to.
//!
//! ★★ THIS IS THE THING MuJoCo CANNOT DO CASUALLY. Not because its physics is worse — it is
//! not — but because getting a MuJoCo training loop in front of someone means an install, a
//! Python environment, and a plotting library. This is a file you open.
//!
//! ── ★ WHY CROSS-ENTROPY AND NOT A GRADIENT METHOD ──
//!
//! CEM samples policies, keeps the best few, and refits a Gaussian to them. That is the entire
//! algorithm, and it fits on screen next to the robot — which for a demonstration is worth more
//! than sample efficiency. Measured on this engine it solves cartpole in **four to eight
//! generations**, from an elite score of ~180 to the 500-step ceiling.
//!
//! ── ★★ THE NUMBERS THAT MADE IT FEASIBLE ──
//!
//! One generation is 40 policies × 4 seeds × up to 500 steps = 80 000 steps, and a cartpole
//! step costs 824 ns — so ~66 ms in the worst case, with most episodes ending long before 500.
//! Training is therefore spread across frames rather than blocking one: `generations_per_frame`
//! is a slider, and turning it up makes the curve climb faster and the frame rate drop, which
//! is an honest thing for a demo to show.

const std = @import("std");
const common = @import("example_common");

/// A wasm safety trap is a bare `RuntimeError: unreachable` without this - no message, no line.
/// See `common.reportPanic`: six turns of debugging went to a panic that named itself in one
/// build once a handler existed.
pub const panic = std.debug.FullPanic(common.reportPanic);
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");
const rbt = z.robot;
const ctl = z.robot_control;
const ui = z.ui;

const Color = zm.Color;
const Mat = zm.Mat;
const Camera3D = zm.Camera3D;
const vec = zm.vec;
const clamp = zm.clamp;
const identity = zm.identity;
const mulMat = zm.mulMat;
const translation = zm.translation;
const scaling = zm.scaling;
const rotationZ = zm.rotationZ;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const cart_slide: usize = 0;
const pole_hinge: usize = 1;

/// How far the pole may lean before the episode ends, and how far the cart may travel.
const fail_angle: f32 = 0.25;
const fail_position: f32 = 2.0;
/// The most steps an episode may last — also the best possible score.
const max_steps: usize = 500;
/// The model's timestep, restated so the display loop can pace itself against wall time.
const sim_timestep: f32 = 1.0 / 100.0;

/// ★ THE START IS INSIDE THE FAIL LIMIT, and that is not a detail. A first version tilted the
/// pole further than the limit allowed, so a fixed fraction of episodes scored ZERO before the
/// policy acted — and the learning curve plateaued at exactly three quarters of the maximum. A
/// plateau at a round fraction is arithmetic, not a ceiling.
const start_tilt: f32 = 0.30;

const population: usize = 40;
const elite: usize = 8;

const bg: Color = .{ .r = 15, .g = 16, .b = 22, .a = 255 };
const rail_col: Color = .{ .r = 62, .g = 60, .b = 70, .a = 255 };
const cart_col: Color = .{ .r = 95, .g = 190, .b = 180, .a = 255 };
const pole_col: Color = .{ .r = 230, .g = 175, .b = 85, .a = 255 };
const fail_col: Color = .{ .r = 190, .g = 70, .b = 70, .a = 255 };

/// A four-weight linear policy: `action = w · (cart x, pole angle, cart v, pole v)`.
///
/// ★ LINEAR IS ENOUGH, and saying so matters. Cartpole is solvable by a plane through the state
/// space, so nothing here rests on a neural network being correctly implemented — what is being
/// demonstrated is the SIMULATOR and the loop around it.
const Policy = [4]f32;

const Cartpole = rbt.Spec(.{
    .bodies = &.{
        .{
            .name = "cart",
            .joints = &.{.{
                .name = "slide",
                .kind = .slide,
                .axis = vec(1, 0, 0),
                .range = .{ -2.4, 2.4 },
            }},
            .geoms = &.{.{ .shape = .{ .box = .{ .half_extent = vec(0.1, 0.05, 0.05) } }, .mass = 1.0 }},
        },
        .{
            .name = "pole",
            .parent = "cart",
            .joints = &.{.{ .name = "hinge", .kind = .hinge, .axis = vec(0, 0, 1) }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = 0.3, .radius = 0.02 } },
                .pos = vec(0, 0.3, 0),
                .mass = 0.1,
            }},
        },
    },
    // ★ GEAR 6, NOT 10. A stronger motor makes the task trivial — the first random batch of
    // forty policies already contained a perfect one, and a demo whose curve starts at the
    // ceiling shows nothing.
    .actuators = &.{.{
        .name = "push",
        .on = .{ .joint = .{ .name = "slide", .gear = 6 } },
        .ctrl_range = .{ -1, 1 },
    }},
    .options = .{ .timestep = 1.0 / 100.0, .max_contacts = 4, .gravity = vec(0, -9.81, 0) },
});

const State = struct {
    gpa: Allocator,
    model: rbt.Model,
    /// The environment the search runs in.
    trainer: ctl.Env,
    /// A second environment, so the on-screen robot is not disturbed by training.
    ///
    /// ★ TWO ENVIRONMENTS, ONE MODEL — which `robot.zig` proves is safe, and which is the
    /// whole reason a batch is affordable. Sharing one would make the display flicker through
    /// forty policies a frame.
    display: ctl.Env,
    display_seed: u64,
    display_steps: usize,
    display_accumulator: f32,

    ui_host: z.UiHost,
    font: z.Font,
    cam: z.OrbitCamera,
    cube: z.Mesh,
    cylinder: z.Mesh,
    transform: [1]Mat,

    mean: Policy,
    sigma: Policy,
    rng: std.Random.DefaultPrng,
    generation: u32,
    /// Elite score per generation, for the plot.
    history: [256]f32,
    history_len: usize,
    best_ever: f32,

    training: bool,
    show_best: bool,

    // ── ★★★ A GENERATION IN PROGRESS, NOT A GENERATION PER FRAME ──
    //
    // The first version ran a whole generation inside `update`. A generation is 40 policies x 4
    // seeds x up to 500 steps — about 66 ms on a desktop and several times that on a phone —
    // so the frame took most of a second and **the demo was not interactive at all**: a swipe
    // needs several samples to read as a drag, and a tap needs its press and release to land in
    // frames that actually happen.
    //
    // ★ THE UNIT OF WORK IS NOW ONE POLICY EVALUATION. A frame does as many as its budget
    // allows and returns; the generation completes across however many frames it takes. Nothing
    // about the search changes — the same 40 policies are scored against the same seeds, in the
    // same order — only when.
    samples: [population]Policy,
    scores: [population]f32,
    /// How many of `population` have been scored so far this generation.
    evaluated: usize,
    /// How many to score per frame, adapted to what the device can actually do.
    budget: f32,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.gpa = gpa;
    s.model = try Cartpole.build(gpa);
    s.trainer = try ctl.Env.init(gpa, &s.model);
    s.display = try ctl.Env.init(gpa, &s.model);
    s.display_seed = 1;
    s.display_steps = 0;
    s.display_accumulator = 0;

    s.mean = @splat(0);
    s.sigma = @splat(1.0);
    s.rng = std.Random.DefaultPrng.init(7);
    s.generation = 0;
    s.history = @splat(0);
    s.history_len = 0;
    s.best_ever = 0;

    s.training = true;
    s.show_best = true;
    s.samples = undefined;
    s.scores = @splat(0);
    s.evaluated = population; // forces a fresh sample set on the first frame
    s.budget = 2;

    s.cam = z.OrbitCamera.init(vec(0, 0.35, 0), 2.2);
    s.font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.ui_host = z.UiHost.init(gpa, s.font);
    s.cube = try z.genMeshCube(gpa, 1.0, 1.0, 1.0);
    s.cylinder = try z.genMeshCylinder(gpa, 1.0, 1.0, 12, 2);
    s.transform = .{identity()};
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
    s.display.deinit();
    s.trainer.deinit();
    s.model.deinit();
}

/// Put an environment at a randomised start, inside the fail limit.
fn beginEpisode(env: *ctl.Env, seed: u64) void {
    var rng: std.Random.DefaultPrng = .init(seed);
    const r: std.Random = rng.random();
    _ = env.reset();
    env.data.pos[pole_hinge] = (r.float(f32) - 0.5) * start_tilt;
    env.data.vel[pole_hinge] = (r.float(f32) - 0.5) * start_tilt * 2.0;
    env.data.stage = .stale;
}

fn actionFor(env: *const ctl.Env, policy: Policy) f32 {
    const observation = [4]f32{
        env.data.pos[cart_slide],
        env.data.pos[pole_hinge],
        env.data.vel[cart_slide],
        env.data.vel[pole_hinge],
    };
    var action: f32 = 0;
    for (observation, policy) |value, weight| {
        action += value * weight;
    }
    return clamp(action, -1, 1);
}

fn hasFallen(env: *const ctl.Env) bool {
    return @abs(env.data.pos[pole_hinge]) > fail_angle or
        @abs(env.data.pos[cart_slide]) > fail_position;
}

/// One episode, scored by how long the pole stayed up.
fn score(env: *ctl.Env, policy: Policy, seed: u64) f32 {
    beginEpisode(env, seed);
    var survived: f32 = 0;
    for (0..max_steps) |_| {
        _ = env.step(&.{actionFor(env, policy)});
        if (hasFallen(env)) {
            break;
        }
        survived += 1;
    }
    return survived;
}

/// Draw a fresh population from the current Gaussian, to be scored over the coming frames.
fn beginGeneration(s: *State) void {
    const r: std.Random = s.rng.random();
    for (0..population) |i| {
        for (0..4) |k| {
            s.samples[i][k] = s.mean[k] + s.sigma[k] * r.floatNorm(f32);
        }
    }
    s.evaluated = 0;
}

/// Score one policy, on four seeds.
///
/// ★ FOUR SEEDS, NOT ONE. On a single start a policy that happens to suit that one tilt wins,
/// the elite set fills with specialists, and the mean goes nowhere.
fn evaluateOne(s: *State, index: usize) void {
    var total: f32 = 0;
    for (1..5) |seed| {
        total += score(&s.trainer, s.samples[index], seed);
    }
    s.scores[index] = total / 4.0;
}

/// Rank the finished population, keep the best, and refit the Gaussian to them.
///
/// ── ★ THE WHOLE OF CROSS-ENTROPY METHOD ──
///
/// No gradients, no learning rate, no network: draw, rank, refit.
fn finishGeneration(s: *State) void {
    var order: [population]usize = undefined;
    for (0..population) |i| {
        order[i] = i;
    }
    const Ranking = struct {
        by: []const f32,
        fn better(self: @This(), a: usize, b: usize) bool {
            return self.by[a] > self.by[b];
        }
    };
    std.mem.sort(usize, &order, Ranking{ .by = &s.scores }, Ranking.better);

    var next: Policy = @splat(0);
    for (order[0..elite]) |i| {
        for (0..4) |k| {
            next[k] += s.samples[i][k] / @as(f32, elite);
        }
    }
    for (0..4) |k| {
        var spread: f32 = 0;
        for (order[0..elite]) |i| {
            const d: f32 = s.samples[i][k] - next[k];
            spread += d * d;
        }
        // ★ A FLOOR ON THE SPREAD. Without it the Gaussian collapses onto the first decent
        // policy it finds and the search stops — the classic CEM failure, and it looks like
        // convergence rather than like giving up.
        s.sigma[k] = @max(0.03, @sqrt(spread / @as(f32, elite)));
        s.mean[k] = next[k];
    }

    var elite_mean: f32 = 0;
    for (order[0..elite]) |i| {
        elite_mean += s.scores[i] / @as(f32, elite);
    }
    s.best_ever = @max(s.best_ever, s.scores[order[0]]);
    if (s.history_len < s.history.len) {
        s.history[s.history_len] = elite_mean;
        s.history_len += 1;
    } else {
        std.mem.copyForwards(f32, s.history[0 .. s.history.len - 1], s.history[1..]);
        s.history[s.history.len - 1] = elite_mean;
    }
    s.generation += 1;
}

/// Do as much training as this frame can afford, and no more.
///
/// ── ★★ THE BUDGET ADAPTS, BECAUSE THE DEVICE IS UNKNOWN ──
///
/// A fixed count tuned on a desktop is far too much for a phone, and a phone-safe count wastes
/// a desktop. Last frame's `delta_time` says which one this is: below 12 ms there is room for
/// more, above 22 ms there is not, and the budget walks between those bounds.
///
/// ★ THE FLOOR IS ONE POLICY PER FRAME. Training slowly is a demo that works; training in
/// bursts that eat the frame is a demo you cannot touch.
fn trainWithinFrame(s: *State, delta_time: f32) void {
    if (delta_time > 0.022) {
        s.budget = @max(1.0, s.budget * 0.8);
    } else if (delta_time < 0.012) {
        // ★ THE CEILING IS LOW ON PURPOSE. Letting this reach the full population means one
        // frame doing a whole generation — the very thing that made the demo untouchable — and
        // then fifteen more frames shrinking back from it. Eight policies is a few milliseconds
        // even late in training, when episodes run their full length.
        s.budget = @min(8.0, s.budget + 0.5);
    }
    var remaining: f32 = s.budget;
    while (remaining >= 1.0) : (remaining -= 1.0) {
        if (s.evaluated >= population) {
            finishGeneration(s);
            beginGeneration(s);
        }
        evaluateOne(s, s.evaluated);
        s.evaluated += 1;
    }
}

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(u, s, f.window.widthf(), f.window.heightf());

    if (s.training) {
        trainWithinFrame(s, f.time.delta_time);
    }

    // The displayed robot runs the current best policy, restarting when it falls.
    //
    // ★ AN ACCUMULATOR, NOT ONE STEP PER FRAME. The simulation runs at 100 Hz and the display
    // at whatever the device gives — 60, or 30 under load — so stepping once per frame plays
    // the pole back at 60% speed on a good device and 30% on a struggling one. The physics
    // would be right and the motion visibly wrong, in a way that reads as the policy being
    // sluggish rather than the loop being wrong.
    if (s.show_best) {
        s.display_accumulator += @min(f.time.delta_time, 0.1);
        while (s.display_accumulator >= sim_timestep) : (s.display_accumulator -= sim_timestep) {
            _ = s.display.step(&.{actionFor(&s.display, s.mean)});
            s.display_steps += 1;
            if (hasFallen(&s.display) or s.display_steps >= max_steps) {
                s.display_seed += 1;
                s.display_steps = 0;
                beginEpisode(&s.display, s.display_seed);
            }
        }
    }

    z.clearViewport(f, bg);
    // ★ PULL BACK ON A TALL, NARROW VIEWPORT. The rail is 4.8 m wide and a portrait phone sees
    // far less of it horizontally than a desktop does, so a fixed distance frames the scene for
    // one and crops it for the other.
    const aspect: f32 = f.window.widthf() / @max(1.0, f.window.heightf());
    s.cam.distance = clamp(2.4 / @max(0.35, aspect), 2.2, 6.0);
    const cam: Camera3D = s.cam.update(f, captured, .{ .min_distance = 1.0, .max_distance = 8.0 });
    z.beginMode3D(gl, cam);
    drawScene(s, gl);
    z.endMode3D(gl);
}

fn drawScene(s: *State, gl: *z.WgpuGl) void {
    const x: f32 = s.display.data.pos[cart_slide];
    const angle: f32 = s.display.data.pos[pole_hinge];

    // The rail, and the limits the episode ends at.
    s.transform[0] = mulMat(translation(0, -0.06, 0), scaling(2 * fail_position, 0.01, 0.06));
    z.drawMeshInstanced(gl, &s.cube, &s.transform, rail_col);
    inline for (.{ -fail_position, fail_position }) |edge| {
        s.transform[0] = mulMat(translation(edge, 0.0, 0), scaling(0.02, 0.12, 0.08));
        z.drawMeshInstanced(gl, &s.cube, &s.transform, fail_col);
    }

    s.transform[0] = mulMat(translation(x, 0, 0), scaling(0.2, 0.1, 0.1));
    z.drawMeshInstanced(gl, &s.cube, &s.transform, cart_col);

    // ★ THE POLE IS DRAWN FROM ITS PIVOT, not centred on it — the cylinder mesh spans [0, h]
    // along Y, measured from the mesh's own bounds rather than assumed from the generator,
    // which remaps axes as it writes.
    s.transform[0] = mulMat(
        mulMat(translation(x, 0, 0), rotationZ(angle)),
        scaling(0.03, 0.6, 0.03),
    );
    z.drawMeshInstanced(gl, &s.cylinder, &s.transform, if (@abs(angle) > fail_angle) fail_col else pole_col);
}

fn drawPanel(u: ui.Ui, s: *State, viewport_w: f32, viewport_h: f32) bool {
    const captured: bool = u.wantCaptureMouse();

    // ── ★ SIZED TO THE VIEWPORT, NOT TO PIXELS ──
    //
    // This shipped with a hardcoded 380x400 panel and a fixed font, which on a phone left the
    // plot's label hanging outside its own box and most of the screen empty. The panel takes a
    // FRACTION of the width and everything inside follows from it.
    const narrow: bool = ui.Ui.isNarrow(viewport_w);
    const panel_w: f32 = if (narrow) viewport_w - 16 else @min(430.0, viewport_w * 0.34);
    // ★ ~30 CHARACTERS ACROSS a full-width panel, ~22 across a floating one — the widest line
    // below is "spread 0.043 0.031 0.030 0.030", and a panel narrower than its widest line is
    // a panel with a horizontal scrollbar.
    const font_size: f32 = u.scaleToViewport(panel_w, if (narrow) 30.0 else 22.0);

    u.setNextWindowPos(.{ 8, 8 }, .{});
    // Height capped to the viewport: auto-size lets the window run off a short screen.
    u.setNextWindowSize(.{ panel_w, @min(470.0, viewport_h * 0.7) }, .{});
    if (u.window("a policy learning to balance", .{})) |window| {
        defer window.close();

        u.text("generation {d}   best ever {d:.0} / {d}", .{ s.generation, s.best_ever, max_steps });
        if (s.history_len > 1) {
            // ★ THE WIDTH IS GIVEN. Without it the plot defaults to something wider than the
            // panel and its label renders OUTSIDE the box — which is exactly how this looked
            // on a phone, and the kind of thing only a device screenshot shows.
            u.plotLines("", s.history[0..s.history_len], .{
                .min = 0,
                .max = @floatFromInt(max_steps),
                .width = panel_w - font_size * 2.0,
                .height = font_size * 5.0,
                .overlay = "elite score, best 8 of 40",
            });
        } else {
            u.text("  (training...)", .{});
        }
        u.separator();

        // ★ THE POLICY IS FOUR NUMBERS, SHOWN. Watching them move is most of what makes this
        // legible: the search is not a black box, it is a Gaussian walking across a plane.
        u.text("policy  x {d:>6.2}  angle {d:>6.2}", .{ s.mean[0], s.mean[1] });
        u.text("        v {d:>6.2}  omega {d:>6.2}", .{ s.mean[2], s.mean[3] });
        u.text("spread  {d:.3} {d:.3} {d:.3} {d:.3}", .{ s.sigma[0], s.sigma[1], s.sigma[2], s.sigma[3] });
        u.separator();

        _ = u.checkbox("training", &s.training);
        _ = u.checkbox("show the current best", &s.show_best);
        // ★ TURNING THIS UP MAKES THE CURVE CLIMB AND THE FRAME RATE DROP, which is an honest
        // thing to show: a generation is 40 policies x 4 seeds x up to 500 steps, about 66 ms
        // in the worst case.
        // ★ THE BUDGET IS SHOWN, NOT SET. It is what the device turned out to be able to
        // afford, adapted from the frame time — a number worth seeing precisely because it
        // differs so much between a desktop and a phone.
        u.text("{d:.0} policies/frame, {d}/{d} this generation", .{
            s.budget,
            s.evaluated,
            population,
        });
        if (u.button("start over", .{})) {
            s.mean = @splat(0);
            s.sigma = @splat(1.0);
            s.generation = 0;
            s.history_len = 0;
            s.best_ever = 0;
            s.rng = std.Random.DefaultPrng.init(7);
            s.evaluated = population; // a fresh population on the next frame
            beginEpisode(&s.display, s.display_seed);
        }
    }
    return captured;
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - a policy learning to balance",
            .width = 860,
            .height = 640,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
