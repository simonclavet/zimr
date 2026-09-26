//! rl_humanoid - PPO learning humanoid locomotion, live in the browser.
//!
//! `robot_gym.HumanoidEnv` (MuJoCo's humanoid, 21 hinges, a real floor, 60 Hz physics, a 30 Hz
//! policy) trained by `robot_gym.PpoTrainer` (zimrnum's PPO: a 64-64 Gaussian policy whose actions
//! are POSE OFFSETS on the standing pose, tracked by the implicit-spring controller). The page runs
//! the training environment itself and draws its humanoid, so what you watch is the rollout as it
//! is collected - episodes end at a fall, and a better policy falls later.
//!
//! Each frame collects a slice of environment steps; once 2,048 are in, each frame runs ONE epoch
//! of the update, so the page stays responsive. Physics and learning both run on the CPU (wasm)
//! here; the GPU learners live in `robot_track_resident` (see rl_track_plan.md). The panel's
//! samples/s is the number that plan's arithmetic wants from a real device.
//!
//! Standard wgpu example contract: a `pub const app: z.AppSpec(State)`.

const std = @import("std");
const common = @import("example_common");
pub const panic = std.debug.FullPanic(common.reportPanic);
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const rbt = z.robot;
const gym = z.robot_gym;
const ui = z.ui;
const Vec = zm.Vec;
const Quat = zm.Quat;
const Mat = zm.Mat;
const Color = zm.Color;
const Camera3D = zm.Camera3D;
const vec = zm.vec;
const rotate = zm.rotate;
const qmul = zm.qmul;
const mulMat = zm.mulMat;
const translation = zm.translation;
const scaling = zm.scaling;
const quatToMat = zm.quatToMat;
const identity = zm.identity;
const zUpToYUp = zm.zUpToYUp;
const assertUnreachable = zm.assertUnreachable;
const float = zm.float;
const float64 = zm.float64;
const clamp = zm.clamp;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

/// The frame time to hold: 30 fps. Training gets what drawing and the browser leave of it -
/// the budget adapts every frame, because a fixed 25 ms plus drawing ran a phone at 22 fps.
/// Training runs in slices - 8 environment steps, or one minibatch of the update - until the
/// budget is spent, so no frame waits on a whole epoch (~270 ms on a phone).
const target_frame_ms: f64 = 1000.0 / 30.0;
const min_budget_ms: f64 = 4.0;
const max_budget_ms: f64 = 25.0;
/// Environment steps per collection slice.
const collect_slice: usize = 8;
/// The watched policy runs in REAL time: one policy step per 1/30 s of wall clock.
const policy_dt: f32 = 1.0 / 30.0;
/// Mean episode lengths kept for the panel's history.
const history_len: usize = 12;
const bg: Color = .{ .r = 18, .g = 14, .b = 16, .a = 255 };
const body_col: Color = .{ .r = 240, .g = 150, .b = 70, .a = 255 };

const State = struct {
    gpa: Allocator,
    env: *gym.HumanoidEnv,
    trainer: *gym.PpoTrainer,
    font: z.Font,
    ui_host: z.UiHost,
    cam: z.OrbitCamera,
    cylinder: z.Mesh,
    sphere: z.Mesh,
    transform: [1]Mat,
    paused: bool,
    /// Samples/s over a one-second window of wall time.
    window_time: f32,
    window_steps: usize,
    samples_per_second: f32,
    /// Wall time of the update in progress, and of the last finished one.
    update_time: f32,
    last_update_time: f32,
    /// When the update in progress started, in ms (`z.wgpu.nowMs`).
    update_started_ms: f64,
    /// Training time spent last frame, and frames per second over the window.
    train_ms: f64,
    /// This frame's training budget (adapted toward `target_frame_ms`), and the running totals
    /// behind the samples/s readout: every sample over all the time spent training, updates in.
    budget_ms: f64,
    total_steps: u64,
    total_train_ms: f64,
    window_frames: u32,
    fps: f32,
    /// A second environment running the CURRENT policy's mean action, in real time: the
    /// result, as opposed to the training rollout (fast-forward, with exploration noise).
    watch_env: *gym.HumanoidEnv,
    watch_obs: []f32,
    watch_act: []f32,
    watch_accumulator: f32,
    watch_seed: u64,
    watch_steps: u32,
    watch_start_x: f32,
    last_watch_steps: u32,
    last_watch_distance: f32,
    /// Draw the training rollout instead of the watched policy.
    show_training: bool,
    history: [history_len]f32,
    history_count: usize,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.gpa = gpa;
    s.env = try gym.HumanoidEnv.init(gpa, @embedFile("humanoid.xml"), .{});
    s.trainer = try gym.PpoTrainer.init(gpa, s.env, .{});
    s.watch_env = try gym.HumanoidEnv.init(gpa, @embedFile("humanoid.xml"), .{});
    s.watch_obs = try gpa.alloc(f32, s.watch_env.observationSize());
    s.watch_act = try gpa.alloc(f32, s.watch_env.actionSize());
    s.watch_seed = 1;
    try s.watch_env.reset(s.watch_seed, s.watch_obs);
    s.watch_accumulator = 0;
    s.watch_steps = 0;
    s.watch_start_x = s.watch_env.data.pos[0];
    s.last_watch_steps = 0;
    s.last_watch_distance = 0;
    s.show_training = false;
    s.update_started_ms = 0;
    s.train_ms = 0;
    s.budget_ms = max_budget_ms;
    s.total_steps = 0;
    s.total_train_ms = 0;
    s.window_frames = 0;
    s.fps = 0;
    s.font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.ui_host = z.UiHost.init(gpa, s.font);
    s.cam = z.OrbitCamera.init(vec(0, 0.6, 0), 4.2);
    s.cylinder = try z.genMeshCylinder(gpa, 1.0, 1.0, 16, 2);
    s.sphere = try z.genMeshSphere(gpa, 1.0, 10, 8);
    s.transform = .{identity()};
    s.paused = false;
    s.window_time = 0;
    s.window_steps = 0;
    s.samples_per_second = 0;
    s.update_time = 0;
    s.last_update_time = 0;
    s.history = @splat(0);
    s.history_count = 0;
}

fn deinit(gpa: Allocator, s: *State) void {
    gpa.free(s.watch_act);
    gpa.free(s.watch_obs);
    s.watch_env.deinit();
    s.trainer.deinit();
    s.env.deinit();
    z.unloadMesh(gpa, s.cylinder);
    z.unloadMesh(gpa, s.sphere);
    s.ui_host.deinit();
    z.unloadFont(gpa, s.font);
}

/// Train for `training_budget_ms`: collection slices while the rollout fills, then one
/// minibatch of the update at a time, until the budget is spent.
fn train(s: *State) void {
    const start: f64 = z.wgpu.nowMs();
    while (z.wgpu.nowMs() - start < s.budget_ms) {
        if (!s.trainer.rolloutFull()) {
            const ran: usize = s.trainer.collect(collect_slice) catch |err| blk: {
                assertUnreachable(@src(), "collecting failed: {t}", .{err});
                break :blk 0;
            };
            s.window_steps += ran;
            s.total_steps += ran;
            if (s.trainer.rolloutFull()) {
                s.update_started_ms = z.wgpu.nowMs();
            }
            continue;
        }
        const finished: bool = s.trainer.updateSlice() catch |err| blk: {
            assertUnreachable(@src(), "the PPO update failed: {t}", .{err});
            break :blk false;
        };
        if (finished) {
            s.last_update_time = @floatCast((z.wgpu.nowMs() - s.update_started_ms) / 1000.0);
            if (s.history_count == history_len) {
                std.mem.copyForwards(f32, s.history[0 .. history_len - 1], s.history[1..]);
                s.history_count -= 1;
            }
            s.history[s.history_count] = s.trainer.last.mean_length;
            s.history_count += 1;
        }
    }
    s.train_ms = z.wgpu.nowMs() - start;
    s.total_train_ms += s.train_ms;
}

/// The watched policy: real time, the mean action, a fresh episode after every fall.
fn watch(f: *z.Frame, s: *State) void {
    s.watch_accumulator += @min(f.time.delta_time, 0.2);
    var steps: u32 = 0;
    while (s.watch_accumulator >= policy_dt and steps < 4) : (steps += 1) {
        s.watch_accumulator -= policy_dt;
        s.trainer.policyMean(s.watch_obs, s.watch_act);
        const result: gym.StepResult = s.watch_env.step(s.watch_act, s.watch_obs) catch |err| blk: {
            assertUnreachable(@src(), "the watched step failed: {t}", .{err});
            break :blk .{ .reward = 0, .terminated = true, .truncated = false };
        };
        s.watch_steps += 1;
        if (result.terminated or result.truncated) {
            s.last_watch_steps = s.watch_steps;
            s.last_watch_distance = s.watch_env.data.pos[0] - s.watch_start_x;
            s.watch_steps = 0;
            s.watch_seed += 1;
            s.watch_env.reset(s.watch_seed, s.watch_obs) catch |err| {
                assertUnreachable(@src(), "resetting the watched episode failed: {t}", .{err});
            };
            s.watch_start_x = s.watch_env.data.pos[0];
        }
    }
    if (steps == 4) {
        s.watch_accumulator = 0;
    }
}

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;
    // Steer the budget so the whole frame lands near 30 fps.
    const frame_ms: f64 = @as(f64, f.time.delta_time) * 1000.0;
    s.budget_ms = clamp(s.budget_ms + 0.2 * (target_frame_ms - frame_ms), min_budget_ms, max_budget_ms);
    if (!s.paused) {
        train(s);
    }
    watch(f, s);
    s.window_time += f.time.delta_time;
    s.window_frames += 1;
    if (s.window_time >= 1.0) {
        s.samples_per_second = if (s.total_train_ms > 0)
            @floatCast(float64(s.total_steps) / (s.total_train_ms / 1000.0))
        else
            0;
        s.fps = float(s.window_frames) / s.window_time;
        s.window_time = 0;
        s.window_steps = 0;
        s.window_frames = 0;
    }

    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(u, s, f.window.widthf(), f.window.heightf());

    z.clearViewport(f, bg);
    const cam: Camera3D = s.cam.update(f, captured, .{ .min_distance = 1.0, .max_distance = 12.0 });
    z.beginMode3D(gl, cam);
    z.drawGrid(gl, 24, 0.5);
    const shown: *const gym.HumanoidEnv = if (s.show_training) s.env else s.watch_env;
    const m: *const rbt.Model = &shown.imported.model;
    const d: *const rbt.Data = &shown.data;
    // Follow the character: it walks away from the origin as it learns.
    const follow: Vec = vec(-d.pos[0], -d.pos[1], 0);
    for (0..m.ngeom) |g| {
        const body: u32 = m.geom_body[g];
        drawGeom(s, gl, g, d.body_xpos[body] + follow, d.body_xrot[body], body_col);
    }
    z.endMode3D(gl);
}

fn drawGeom(
    s: *State,
    gl: *z.WgpuGl,
    g: usize,
    body_pos: Vec,
    body_rot: Quat,
    tint: Color,
) void {
    const m: *const rbt.Model = &s.env.imported.model;
    const world_pos: Vec = body_pos + rotate(body_rot, m.geom_pos[g]);
    const world_rot: Mat = quatToMat(qmul(body_rot, m.geom_rot[g]));
    const place: Mat = mulMat(
        mulMat(zUpToYUp(), translation(world_pos[0], world_pos[1], world_pos[2])),
        world_rot,
    );
    switch (m.geom_shape[g]) {
        .sphere => |sph| {
            s.transform[0] = mulMat(place, scaling(sph.radius, sph.radius, sph.radius));
            z.drawMeshInstanced(gl, &s.sphere, &s.transform, tint);
        },
        .capsule => |cap| {
            s.transform[0] = mulMat(
                mulMat(place, translation(0, -cap.half_height, 0)),
                scaling(cap.radius, 2.0 * cap.half_height, cap.radius),
            );
            z.drawMeshInstanced(gl, &s.cylinder, &s.transform, tint);
            for ([_]f32{ -1.0, 1.0 }) |end| {
                s.transform[0] = mulMat(
                    mulMat(place, translation(0, end * cap.half_height, 0)),
                    scaling(cap.radius, cap.radius, cap.radius),
                );
                z.drawMeshInstanced(gl, &s.sphere, &s.transform, tint);
            }
        },
        else => {},
    }
}

fn drawPanel(u: ui.Ui, s: *State, viewport_w: f32, viewport_h: f32) bool {
    const captured: bool = u.wantCaptureMouse();
    const narrow: bool = ui.Ui.isNarrow(viewport_w);
    const panel_w: f32 = if (narrow) viewport_w - 16 else @min(470.0, viewport_w * 0.42);
    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ panel_w, @min(470.0, viewport_h * 0.62) }, .{});
    if (u.window("PPO: humanoid learning to walk", .{})) |window| {
        defer window.close();
        const t: *const gym.PpoTrainer = s.trainer;
        u.text("iteration {d}   samples {d}", .{ t.iteration, t.iteration * t.options.horizon + t.rollout.len });
        u.text("{d:.0} samples/s of training time (updates in)", .{s.samples_per_second});
        u.text("training {d:.0} of {d:.0} ms/frame   {d:.0} fps", .{ s.train_ms, s.budget_ms, s.fps });
        if (t.rolloutFull()) {
            u.text("updating: epoch {d} of {d}", .{ t.epoch + 1, t.options.epochs });
        } else {
            u.text("collecting: {d} / {d}", .{ t.rollout.len, t.options.horizon });
        }
        u.text("last update {d:.2} s", .{s.last_update_time});
        u.separator();
        u.text("THE RESULT: the current policy, real time,", .{});
        u.text("  no exploration noise ({s} shown)", .{if (s.show_training) "training rollout" else "it is"});
        u.text("  this episode {d} steps; last {d} steps, walked {d:.2} m", .{
            s.watch_steps,
            s.last_watch_steps,
            s.last_watch_distance,
        });
        _ = u.checkbox("show the training rollout instead", &s.show_training);
        u.separator();
        u.text("last iteration: {d} episodes", .{t.last.episodes});
        u.text("  mean length {d:.1} steps   return {d:.1}", .{ t.last.mean_length, t.last.mean_return });
        u.text("  (statue 37.6 steps, random 15)", .{});
        u.separator();
        u.text("mean episode length, oldest first:", .{});
        for (s.history[0..s.history_count], 0..) |length, i| {
            u.text("  {d:>2}: {d:>6.1}", .{ t.iteration - s.history_count + i + 1, length });
        }
        u.separator();
        _ = u.checkbox("pause", &s.paused);
    }
    return captured;
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - PPO learning to walk, live",
            .width = 900,
            .height = 680,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
