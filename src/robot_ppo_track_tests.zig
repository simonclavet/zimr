//! robot_ppo_track's tests, kept OUT of the zimr module.
//!
//! The same rule as the GPU kit's other proofs (see `robot_tests.zig`): these tests import
//! `gpu/zn_mlp.zig` by path, and a page that trains on the GPU imports that same file as a module of
//! its own - which Zig refuses, a file belonging to two modules. So the trainer lives in the zimr
//! module where pages can reach it, and its proofs live here, reachable only from the test root.
//!
//! Training chunks run from here too: `zig build zn-robot_ppo_track_tests -Dtrain-chunk
//! -Dtest-filter="robot_ppo_track: train chunk - the get-up"`.

const std = @import("std");
const zm = @import("zm");
const float64 = zm.float64;
const rbt = @import("robot.zig");
const track = @import("robot_track.zig");
const dance = @import("robot_dance.zig");
const ppo_track = @import("robot_ppo_track.zig");
const compute_host = @import("compute_host.zig");
const codecs = @import("codecs.zig");
const mjcf = @import("mjcf.zig");
const robot_mjcf = @import("robot_mjcf.zig");
const zn_mlp = @import("gpu/zn_mlp.zig");
/// Geno, the robot built from its character - for the model-free baseline on it (S2b).
const geno = @import("robot_geno.zig");

const Allocator = std.mem.Allocator;
const Host = compute_host.Compute(zn_mlp);
const Trainer = ppo_track.Trainer;
const Options = ppo_track.Options;
const Stats = ppo_track.Stats;
const getup_first = ppo_track.getup_first;
const walk_first = ppo_track.walk_first;
const window_frames = ppo_track.window_frames;
const float = zm.float;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const bufPrint = std.fmt.bufPrint;

const flex2_xml: []const u8 = @embedFile("tests/fixtures/robot/humanoid_flex2.xml");

/// Everything a training run needs, built once.
const Setup = struct {
    doc: codecs.xml.Document,
    robot: mjcf.Robot,
    imported: robot_mjcf.Imported,
    clip: dance.Clip,

    fn init(
        setup: *Setup,
        gpa: Allocator,
        io: std.Io,
        path: []const u8,
        first: usize,
    ) !void {
        // whole-init-first: the whole struct first - defaults applied, every field named.
        setup.* = .{
            .doc = undefined,
            .robot = undefined,
            .imported = undefined,
            .clip = undefined,
        };
        setup.doc = try codecs.xml.parse(gpa, flex2_xml, null);
        errdefer setup.doc.deinit();
        setup.robot = try mjcf.readRobot(gpa, &setup.doc);
        errdefer setup.robot.deinit();
        var options: rbt.Options = .{ .timestep = 1.0 / 60.0, .gravity = zm.vec(0, 0, -9.81), .max_contacts = 256 };
        options.solver.algorithm = .newton;
        setup.imported = try robot_mjcf.build(gpa, &setup.robot, options);
        errdefer setup.imported.deinit();
        const m: *rbt.Model = &setup.imported.model;
        var whole: dance.Clip = try loadClip(gpa, io, m, setup.imported.names, path, 18.0);
        defer whole.deinit();
        setup.clip = try whole.window(first, window_frames);
        errdefer setup.clip.deinit();
        var scratch: rbt.Data = try rbt.Data.init(gpa, m);
        defer scratch.deinit();
        _ = try track.liftPerFrame(gpa, m, &setup.clip, &scratch, 3.0);
    }

    fn deinit(setup: *Setup) void {
        setup.clip.deinit();
        setup.imported.deinit();
        setup.robot.deinit();
        setup.doc.deinit();
    }
};

test "robot_ppo_track: an untrained policy is the servo, and the wiring says so" {
    // THE WIRING'S KNOWN ANSWER. A policy with no exploration whose output layer starts near zero
    // asks for almost nothing, so the trainer's rollout must look like the servo alone: episodes of
    // about the same length. A wiring mistake - an observation from the wrong environment, a reward
    // credited to the wrong decision, a filter never reset - shows up here as episodes that are
    // much shorter than doing nothing at all.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var setup: Setup = undefined;
    setup.init(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", walk_first) catch return error.SkipZigTest;
    defer setup.deinit();
    const m: *rbt.Model = &setup.imported.model;
    const clips = [_]*const dance.Clip{&setup.clip};

    var host: Host = .initCpu();
    const trainer: *Trainer(zn_mlp) = try .init(gpa, &host, m, setup.imported.names, &clips, .{
        .envs = 8,
        .horizon = 32,
        .initial_log_std = -20.0, // no exploration: the policy's mean, which starts near zero
    });
    defer trainer.deinit();
    const first: Stats = try trainer.iterate();

    // The same fleet with the action left at exactly zero, for the same number of physics steps.
    const servo: *track.Fleet = try .init(gpa, m, &clips, .{ .envs = 8, .capacity = 16, .seed = 1 });
    defer servo.deinit();
    const zero: []f32 = try gpa.alloc(f32, 8 * track.actionSize(m));
    defer gpa.free(zero);
    @memset(zero, 0.0);
    for (0..32 * 2) |_| {
        _ = servo.step(zero);
    }
    const servo_mean: f32 = float(8 * 32 * 2) / float(@max(servo.episodes, 1));
    const trainer_mean: f32 = float(8 * 32 * 2) / float(@max(first.episodes, 1));
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  wiring: untrained policy {d:.1} frames an episode ({d} ended, reward {d:.3}); " ++
        "servo alone {d:.1} ({d} ended)\n", .{
        trainer_mean,
        first.episodes,
        first.mean_reward,
        servo_mean,
        servo.episodes,
    });
    try expect(first.mean_reward > 0.3 and first.mean_reward <= 1.0);
    try expect(trainer_mean > 0.7 * servo_mean and trainer_mean < 1.4 * servo_mean);
    // And a second iteration runs on the updated weights without anything going non-finite.
    const second: Stats = try trainer.iterate();
    try expect(zm.isFinite(second.mean_reward));

    // THE CONTROL. Matching the servo exactly is also what a policy DISCONNECTED from the character
    // would do, so the same trainer with real exploration must track measurably worse - which it
    // can only do if its actions reach the joints.
    const noisy: *Trainer(zn_mlp) = try .init(gpa, &host, m, setup.imported.names, &clips, .{
        .envs = 8,
        .horizon = 32,
        .initial_log_std = 0.5, // exp(0.5) = 1.6: far more than a policy would ever want
    });
    defer noisy.deinit();
    const shaken: Stats = try noisy.iterate();
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("  control: with exploration at 1.6, reward {d:.3} against {d:.3} untrained\n", .{
        shaken.mean_reward,
        first.mean_reward,
    });
    try expect(shaken.mean_reward < first.mean_reward - 0.01);
}

test "robot_ppo_track: a checkpoint carries a run on exactly" {
    // Save after some training, load into a trainer built from a DIFFERENT seed, and the two must
    // be the same learner: the same weights to the bit, the same optimiser state, the same count of
    // experience - and so the same answer to the same question.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    var setup: Setup = undefined;
    setup.init(gpa, io, "assets/lafan1/walk1_subject2.bvh", walk_first) catch return error.SkipZigTest;
    defer setup.deinit();
    const m: *rbt.Model = &setup.imported.model;
    const clips = [_]*const dance.Clip{&setup.clip};
    const path: []const u8 = "train/test_roundtrip.ckpt";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var host_a: Host = .initCpu();
    const original: *Trainer(zn_mlp) = try .init(gpa, &host_a, m, setup.imported.names, &clips, .{
        .envs = 4,
        .horizon = 64,
    });
    defer original.deinit();
    _ = try original.iterate();
    try original.save(io, path);

    var host_b: Host = .initCpu();
    const resumed: *Trainer(zn_mlp) = try .init(gpa, &host_b, m, setup.imported.names, &clips, .{
        .envs = 4,
        .horizon = 64,
        .seed = 99,
    });
    defer resumed.deinit();
    try expect(try resumed.load(io, path));

    for (original.ppo.cpu_params, resumed.ppo.cpu_params) |a, b| {
        try expect(a == b);
    }
    try expect(original.ppo.adam_step == resumed.ppo.adam_step and original.ppo.adam_step > 0);
    try expect(original.decisions == resumed.decisions and original.iterations == resumed.iterations);
    // (The device-side moments are checked against the exported BYTES in the test below: on the
    // CPU twin two hosts share one set of buffers, so comparing host A's with host B's would
    // compare a buffer with itself - which is what this test used to do, and pass.)
    const probe: []f32 = try gpa.alloc(f32, original.n_obs);
    defer gpa.free(probe);
    for (probe, 0..) |*x, k| {
        x.* = @sin(float(k));
    }
    try expect(original.ppo.value(probe) == resumed.ppo.value(probe));
    // And a file that is not a checkpoint says so, rather than being read as one.
    try expect(!(try resumed.load(io, "train/does_not_exist.ckpt")));
}

test "robot_ppo_track: a sliced batch, and weights that travel as bytes" {
    // What a phone page depends on, in one place. It collects a few decisions a frame rather than
    // a whole batch at once - which must change NOTHING about what is learned. And its weights
    // leave as a downloaded file and come back as an uploaded one - which must carry the run on
    // exactly, and refuse, by name, a file that is not weights or is weights for another network.
    //
    // ONE LIVE TRAINER AT A TIME, on purpose. The kit's CPU twin keeps its buffers in module
    // globals - that is how the same kernels compile to WGSL, where storage buffers ARE globals -
    // so two hosts in one process share one set of buffers. Interleaving two trainers here would
    // have each overwrite the other's weights; comparing two hosts' device buffers would compare a
    // buffer with itself. Each trainer below starts after the last has finished, and device-side
    // numbers are compared against the exported BYTES, which cannot alias anything.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var setup: Setup = undefined;
    setup.init(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", walk_first) catch return error.SkipZigTest;
    defer setup.deinit();
    const m: *rbt.Model = &setup.imported.model;
    const clips = [_]*const dance.Clip{&setup.clip};
    const small: Options = .{ .envs = 4, .horizon = 64 };
    var host: Host = .initCpu();

    // Whole batches first, and what they learned.
    const whole_params: []f32 = blk: {
        const whole: *Trainer(zn_mlp) = try .init(gpa, &host, m, setup.imported.names, &clips, small);
        defer whole.deinit();
        for (0..2) |_| {
            _ = try whole.iterate();
        }
        break :blk try gpa.dupe(f32, whole.ppo.cpu_params);
    };
    defer gpa.free(whole_params);

    // Then the same run collected three decisions at a time: the same weights, to the bit.
    const sliced: *Trainer(zn_mlp) = try .init(gpa, &host, m, setup.imported.names, &clips, small);
    defer sliced.deinit();
    for (0..2) |_| {
        while (!sliced.collect(3)) {}
        _ = try sliced.learn();
    }
    for (whole_params, sliced.ppo.cpu_params) |a, b| {
        try expect(a == b);
    }

    // Out as bytes. Keep what the sliced trainer acts with - its own copy, not the shared buffers.
    const bytes: []u8 = try sliced.exportWeights(gpa);
    defer gpa.free(bytes);
    const acting: []f32 = try gpa.dupe(f32, sliced.ppo.cpu_params);
    defer gpa.free(acting);
    const probe: []f32 = try gpa.alloc(f32, sliced.n_obs);
    defer gpa.free(probe);
    for (probe, 0..) |*x, k| {
        x.* = @cos(float(k) * 0.37);
    }
    const mean_saved: []f32 = try gpa.alloc(f32, sliced.subset.dofs);
    defer gpa.free(mean_saved);
    sliced.ppo.actMean(probe, mean_saved);
    const value_saved: f32 = sliced.ppo.value(probe);

    // Into a trainer from another seed - whose own initialisation overwrites the shared buffers
    // first, so everything it ends up with came through the bytes.
    var other_options: Options = small;
    other_options.seed = 77;
    const other: *Trainer(zn_mlp) = try .init(gpa, &host, m, setup.imported.names, &clips, other_options);
    defer other.deinit();
    try other.importWeights(bytes);
    for (acting, other.ppo.cpu_params) |a, b| {
        try expect(a == b);
    }
    const mean_loaded: []f32 = try gpa.alloc(f32, other.subset.dofs);
    defer gpa.free(mean_loaded);
    other.ppo.actMean(probe, mean_loaded);
    for (mean_saved, mean_loaded) |a, b| {
        try expect(a == b);
    }
    try expect(value_saved == other.ppo.value(probe));
    try expect(other.iterations == 2 and other.ppo.adam_step == sliced.ppo.adam_step);
    // The optimiser's moments made it to the device, as the file had them.
    const count: usize = other.ppo.param_count;
    const header_size: usize = bytes.len - 3 * count * @sizeOf(f32);
    const moment_bytes: []const u8 = bytes[header_size + count * @sizeOf(f32) ..][0 .. count * @sizeOf(f32)];
    const device_moment: []const f32 = host.readLatest(.adam_m).?;
    try expect(std.mem.eql(u8, moment_bytes, std.mem.sliceAsBytes(device_moment[0..count])));

    // Refused, by name: bytes that are not weights, and weights for a network of another width.
    try expectError(error.NotAWeightsFile, other.importWeights("not weights at all"));
    try expectError(error.NotAWeightsFile, other.importWeights(bytes[0 .. bytes.len - 4]));
    var wide_options: Options = small;
    wide_options.hidden = 32;
    const wide: *Trainer(zn_mlp) = try .init(gpa, &host, m, setup.imported.names, &clips, wide_options);
    defer wide.deinit();
    try expectError(error.WeightsShape, wide.importWeights(bytes));

    // The normaliser travels with the weights - a network trained on normalised inputs is a
    // different network without its statistics - and a file and a trainer that disagree about
    // normalising are refused, not half-read.
    var normed_options: Options = small;
    normed_options.normalize = true;
    const normed_bytes: []u8 = blk: {
        const normed: *Trainer(zn_mlp) = try .init(gpa, &host, m, setup.imported.names, &clips, normed_options);
        defer normed.deinit();
        _ = try normed.iterate();
        try expect(normed.obs_count > 0);
        break :blk try normed.exportWeights(gpa);
    };
    defer gpa.free(normed_bytes);
    normed_options.seed = 5;
    const reloaded: *Trainer(zn_mlp) = try .init(gpa, &host, m, setup.imported.names, &clips, normed_options);
    defer reloaded.deinit();
    try reloaded.importWeights(normed_bytes);
    try expect(reloaded.obs_count == 4 * 64);
    var spread: f64 = 0.0;
    for (reloaded.obs_m2) |m2| {
        spread += m2;
    }
    try expect(spread > 0.0);
    try expectError(error.WeightsShape, other.importWeights(normed_bytes));
}

/// One chunk of a long training run: resume, learn for `seconds`, save, and append the learning
/// curve to a CSV beside the checkpoint so the run's history survives every restart.
fn trainChunk(clip_path: []const u8, first: usize, name: []const u8, seconds: f32) !void {
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    var setup: Setup = undefined;
    try setup.init(gpa, io, clip_path, first);
    defer setup.deinit();
    const m: *rbt.Model = &setup.imported.model;
    const clips = [_]*const dance.Clip{&setup.clip};
    var host: Host = .initCpu();
    const trainer: *Trainer(zn_mlp) = try .init(gpa, &host, m, setup.imported.names, &clips, .{});
    defer trainer.deinit();

    var checkpoint_buffer: [256]u8 = undefined;
    const checkpoint: []const u8 = try bufPrint(&checkpoint_buffer, "train/{s}.ckpt", .{name});
    var curve_buffer: [256]u8 = undefined;
    const curve_path: []const u8 = try bufPrint(&curve_buffer, "train/{s}.csv", .{name});
    const resumed: bool = try trainer.load(io, checkpoint);

    var curve: std.ArrayList(u8) = .empty;
    defer curve.deinit(gpa);
    if (std.Io.Dir.cwd().openFile(io, curve_path, .{})) |file| {
        defer file.close(io);
        const info: std.Io.File.Stat = try file.stat(io);
        try curve.resize(gpa, info.size);
        _ = try file.readPositionalAll(io, curve.items, 0);
    } else |_| {
        try curve.appendSlice(gpa, "iteration,decisions,steps,mean_reward,episodes,mean_episode\n");
    }

    const started: std.Io.Timestamp = std.Io.Clock.now(.awake, io);
    var last: Stats = undefined;
    var ran: usize = 0;
    while (true) {
        const elapsed: i96 = std.Io.Clock.now(.awake, io).nanoseconds - started.nanoseconds;
        if (@as(f32, @floatFromInt(@divTrunc(elapsed, 1_000_000))) > seconds * 1000.0) {
            break;
        }
        last = try trainer.iterate();
        ran += 1;
        var line: [160]u8 = undefined;
        try curve.appendSlice(gpa, try bufPrint(&line, "{d},{d},{d},{d:.4},{d},{d:.2}\n", .{
            trainer.iterations,
            last.decisions,
            last.steps,
            last.mean_reward,
            last.episodes,
            last.mean_episode,
        }));
    }
    try trainer.save(io, checkpoint);
    // Judged, not trained: the mean action against the servo alone, same length of experience.
    const judged: Stats = try trainer.evaluate(300, false);
    const servo: Stats = try trainer.evaluate(300, true);
    // lint:off debug-print: the chunk's report; training chunks only run on the host, on request
    std.debug.print("\n  {s} JUDGED (mean action, 300 decisions x {d} envs): {d:.1} frames an episode, " ++
        "{d} ended, reward {d:.3} | servo alone: {d:.1} frames, {d} ended, reward {d:.3}\n", .{
        name,
        trainer.options.envs,
        judged.mean_episode,
        judged.episodes,
        judged.mean_reward,
        servo.mean_episode,
        servo.episodes,
        servo.mean_reward,
    });
    {
        const file: std.Io.File = try std.Io.Dir.cwd().createFile(io, curve_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, curve.items);
    }
    // lint:off debug-print: the chunk's report; training chunks only run on the host, on request
    std.debug.print("\n  {s}: {s}, {d} iterations this chunk, {d} in all ({d} physics steps); " ++
        "last: reward {d:.3}, {d} episodes ended, {d:.1} frames each\n", .{
        name,
        if (resumed) "resumed" else "started fresh",
        ran,
        trainer.iterations,
        trainer.steps,
        last.mean_reward,
        last.episodes,
        last.mean_episode,
    });
}

test "robot_ppo_track: train chunk - the get-up" {
    const options = @import("build_options");
    const enabled: bool = comptime @hasDecl(options, "train_chunk") and options.train_chunk;
    if (!enabled) {
        return error.SkipZigTest;
    }
    try trainChunk("assets/lafan1/fallAndGetUp2_subject2.bvh", getup_first, "ppo_getup", 180.0);
}

test "robot_ppo_track: train chunk - the walk control" {
    const options = @import("build_options");
    const enabled: bool = comptime @hasDecl(options, "train_chunk") and options.train_chunk;
    if (!enabled) {
        return error.SkipZigTest;
    }
    try trainChunk("assets/lafan1/walk1_subject2.bvh", walk_first, "ppo_walk", 180.0);
}

/// A clip retargeted onto this model and filtered.
fn loadClip(
    gpa: Allocator,
    io: std.Io,
    m: *rbt.Model,
    names: []const []const u8,
    path: []const u8,
    seconds: f32,
) !dance.Clip {
    const capture_bytes: []u8 = try readAll(gpa, io, path);
    defer gpa.free(capture_bytes);
    const rest_bytes: []u8 = try readAll(gpa, io, "assets/lafan1/Geno_stance.bvh");
    defer gpa.free(rest_bytes);
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, capture_bytes, null);
    defer capture.deinit();
    var rest: codecs.bvh.Data = try codecs.bvh.parse(gpa, rest_bytes, null);
    defer rest.deinit();
    var raw: dance.Clip = try dance.retargetClip(gpa, m, names, &capture, &rest, .{ .seconds = seconds });
    defer raw.deinit();
    return raw.smoothed(m, 5.0);
}

fn readAll(gpa: Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file: std.Io.File = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const info: std.Io.File.Stat = try file.stat(io);
    const bytes: []u8 = try gpa.alloc(u8, info.size);
    errdefer gpa.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);
    return bytes;
}

test "robot_ppo_track: Geno holds the T-pose - the model-free baseline (S2b)" {
    // Model-free learning on Geno, with no world model anywhere: the existing PPO trainer, unchanged, on the
    // held T-pose, with Geno's servo and floor. If early training cannot trust a world model, something
    // model-free must carry it - this is the baseline any such learner (CrossQ, DroQ) has to beat, and the
    // check that model-free learning can hold Geno up at all. Judged over 1,200 steps, not 300 - a judge
    // that counts falls needs a long window to resolve anything.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    const model_text: []u8 = readAll(gpa, io, geno.model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    const bind_text: []u8 = try readAll(gpa, io, "src/tests/fixtures/robot/geno_bind.bvh");
    defer gpa.free(bind_text);
    const stance_text: []u8 = try readAll(gpa, io, "src/tests/fixtures/robot/geno_stance.bvh");
    defer gpa.free(stance_text);
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var build_options: rbt.Options = .{ .timestep = 1.0 / 60.0, .gravity = zm.vec(0, 0, -9.81), .max_contacts = 256 };
    build_options.solver.algorithm = .newton;
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, build_options);
    defer imported.deinit();
    var bind: geno.Posed = try geno.readPose(gpa, bind_text);
    defer bind.deinit(gpa);
    var stance: codecs.bvh.Data = try codecs.bvh.parse(gpa, stance_text, null);
    defer stance.deinit();
    var held: dance.Clip = try geno.heldClip(gpa, &imported, bind, stance, 10.0, 1.0 / 60.0);
    defer held.deinit();
    const clips = [_]*const dance.Clip{&held};
    var host: Host = .initCpu();
    const trainer: *Trainer(zn_mlp) = try .init(gpa, &host, &imported.model, imported.names, &clips, .{
        .gains = geno.servo_gains,
        .floor_friction = geno.floor_friction,
        .watched = &geno.drecon_watched,
        .actuated = &geno.drecon_actuated,
    });
    defer trainer.deinit();
    const budget_seconds: f32 = 100.0;
    const started: std.Io.Timestamp = std.Io.Clock.now(.awake, io);
    var iterations: usize = 0;
    var last: Stats = undefined;
    while (true) {
        const elapsed: i96 = std.Io.Clock.now(.awake, io).nanoseconds - started.nanoseconds;
        if (@as(f32, @floatFromInt(@divTrunc(elapsed, 1_000_000))) > budget_seconds * 1000.0) {
            break;
        }
        last = try trainer.iterate();
        iterations += 1;
    }
    const judged: Stats = try trainer.evaluate(1200, false);
    const servo: Stats = try trainer.evaluate(1200, true);
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  PPO on Geno's T-pose, {d:.0} s ({d} iterations, {d} steps): " ++
        "judged {d:.1} frames an episode " ++
        "({d} ended) | servo alone {d:.1} frames ({d} ended)\n", .{
        budget_seconds,
        iterations,
        last.steps,
        judged.mean_episode,
        judged.episodes,
        servo.mean_episode,
        servo.episodes,
    });
    try expect(judged.mean_episode == judged.mean_episode);
}

test "robot_ppo_track: D5 step 3 - PPO's policy cloned from the teacher, judged in the real simulator" {
    // D5.3 step 3, end to end: the teacher (sharp MPPI on DReCon's clock and filter) dances across the task's clip
    // and every decision it makes becomes a demonstration - DReCon's observation (the trainer's OWN fleet supplies
    // the reference states, so it is the trainer's observation by construction) and the raw action / 1.2. Then
    // `Trainer.clone` - the normaliser set from the demonstrations, PPO's own policy chain with the mean-square-error
    // gradient - and the trainer's own `evaluate` judges the clone against the servo alone.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const task: *geno.GenoTask = (try geno.GenoTask.init(gpa, threaded.io(), .dance_5_15)) orelse
        return error.SkipZigTest;
    defer task.deinit();
    const m: *rbt.Model = &task.imported.model;
    const clips = [_]*const dance.Clip{&task.clip};
    var host: Host = .initCpu();
    const trainer: *Trainer(zn_mlp) = try .init(gpa, &host, m, task.imported.names, &clips, .{
        .envs = 8,
        .gains = geno.servo_gains,
        .floor_friction = geno.floor_friction,
        .watched = &geno.drecon_watched,
        .actuated = &geno.drecon_actuated,
        .action_scale = geno.student_scale,
        .rest_on_floor = true,
        .normalize = true,
        .initial_log_std = -1.2,
        .max_episode_steps = 700,
    });
    defer trainer.deinit();

    var run: geno.ServoRun = undefined;
    try run.init(gpa, &task.imported, geno.floor_friction);
    defer run.deinit();
    var planner: geno.Planner = try .init(gpa, &run, &task.imported, geno.d5_teacher);
    defer planner.deinit();
    var recorder: geno.DemoRecorder = try .init(gpa, &task.imported, &planner);
    defer recorder.deinit();
    var demo: geno.Demo = recorder.newDemo();
    defer demo.deinit(gpa);
    var kept: usize = 0;
    var starts: usize = 0;
    var first_rows: std.ArrayList(usize) = .empty;
    defer first_rows.deinit(gpa);
    var from: usize = 0;
    // Every start twice: clean, and perturbed at D5.5's calibrated level (the teacher then demonstrates RECOVERIES).
    while (from + demo_cap < task.clip.frame_count) : (from += demo_stride) {
        for ([_]track.StartNoise{ .{}, geno.d5_start_noise }) |noise| {
            try first_rows.append(gpa, demo.rows());
            const seed: u64 = 1000 + starts;
            kept += try recorder.record(&planner, trainer.fleet, &task.clip, from, demo_cap, noise, seed, &demo);
            starts += 1;
        }
    }
    try first_rows.append(gpa, demo.rows());
    // HELD OUT: every fifth start's demonstrations are never cloned on - its error separates "the observation
    // cannot predict the teacher" (held-out error far above training's: lookahead is missing) from "it can, and
    // the clone drifts off the teacher's states" (held-out near training's: distribution shift - DAgger).
    var train_obs: std.ArrayList(f32) = .empty;
    defer train_obs.deinit(gpa);
    var train_labels: std.ArrayList(f32) = .empty;
    defer train_labels.deinit(gpa);
    var held_obs: std.ArrayList(f32) = .empty;
    defer held_obs.deinit(gpa);
    var held_labels: std.ArrayList(f32) = .empty;
    defer held_labels.deinit(gpa);
    for (0..starts) |start| {
        const lo: usize = first_rows.items[start];
        const hi: usize = first_rows.items[start + 1];
        const held: bool = start % 5 == 4;
        const obs_into: *std.ArrayList(f32) = if (held) &held_obs else &train_obs;
        const labels_into: *std.ArrayList(f32) = if (held) &held_labels else &train_labels;
        try obs_into.appendSlice(gpa, demo.observations.items[lo * demo.width .. hi * demo.width]);
        try labels_into.appendSlice(gpa, demo.labels.items[lo * demo.dofs .. hi * demo.dofs]);
    }
    const dofs: usize = demo.dofs;
    // Two trivial predictors on the held-out rows, for scale: always zero, and the TRAINING labels' mean.
    const train_mean: []f64 = try gpa.alloc(f64, dofs);
    defer gpa.free(train_mean);
    @memset(train_mean, 0.0);
    const train_rows: usize = train_labels.items.len / dofs;
    for (0..train_rows) |row| {
        for (train_mean, train_labels.items[row * dofs ..][0..dofs]) |*mean, value| {
            mean.* += value;
        }
    }
    for (train_mean) |*mean| {
        mean.* /= float64(train_rows);
    }
    var zero_error: f64 = 0.0;
    var mean_error: f64 = 0.0;
    const held_rows: usize = held_labels.items.len / dofs;
    for (0..held_rows) |row| {
        for (held_labels.items[row * dofs ..][0..dofs], train_mean) |value, mean| {
            zero_error += value * value;
            mean_error += (value - mean) * (value - mean);
        }
    }
    zero_error /= float64(held_rows * dofs);
    mean_error /= float64(held_rows * dofs);

    const servo: Stats = try trainer.evaluate(judged_decisions, true);
    // A LEARNING CURVE: held-out error at cumulative checkpoints - early checkpoints beating the constants while
    // later ones do not is overfitting.
    const checkpoints = [_]usize{ 25, 50, 100, 200, 500, 1000, 2000 };
    var curve: [checkpoints.len]f32 = undefined;
    var done_updates: usize = 0;
    var result: Trainer(zn_mlp).CloneResult = .{ .before = 0.0, .after = 0.0 };
    for (checkpoints, 0..) |checkpoint, c| {
        const chunk: Trainer(zn_mlp).CloneResult = try trainer.clone(
            train_obs.items,
            train_labels.items,
            checkpoint - done_updates,
            1 + c,
        );
        if (c == 0) {
            result.before = chunk.before;
        }
        result.after = chunk.after;
        done_updates = checkpoint;
        curve[c] = trainer.cloneError(held_obs.items, held_labels.items);
    }
    const held_error: f32 = curve[checkpoints.len - 1];
    // THE NORMALISER on 660 rows: dimensions whose spread is near its floor, and how often a normalised input is
    // pinned at +-5 - on training rows against held-out ones.
    var narrow: usize = 0;
    const count: f64 = float64(@max(trainer.obs_count, 1));
    for (trainer.obs_m2) |m2| {
        if (@sqrt(m2 / count) < 1.0e-3) {
            narrow += 1;
        }
    }
    var pinned: [2]usize = .{ 0, 0 };
    var inputs: [2]usize = .{ 0, 0 };
    for ([_][]const f32{ train_obs.items, held_obs.items }, 0..) |rows_of, which| {
        const width: usize = demo.width;
        var row: usize = 0;
        while (row * width < rows_of.len) : (row += 1) {
            const scratch: []f32 = trainer.obs_scratch[0..width];
            @memcpy(scratch, rows_of[row * width ..][0..width]);
            trainer.normalizeObservation(scratch);
            for (scratch) |z| {
                if (@abs(z) >= 5.0) {
                    pinned[which] += 1;
                }
            }
            inputs[which] += width;
        }
    }
    const cloned: Stats = try trainer.evaluate(judged_decisions, false);
    const servo_mttf: f64 = float64(servo.exposure) / float64(@max(servo.failures, 1));
    const clone_mttf: f64 = float64(cloned.exposure) / float64(@max(cloned.failures, 1));
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  D5 step 3: the teacher kept up {d} frames over {d} starts -> {d} demonstrations;\n" ++
        "  clone error {d:.4} -> {d:.4} over {d} minibatches;\n" ++
        "  judged ({d} decisions x 8): servo {d} failures, MTTF {d:.0} steps, reward {d:.3} | " ++
        "clone {d} failures, MTTF {d:.0} steps, reward {d:.3}\n", .{
        kept,
        starts,
        demo.rows(),
        result.before,
        result.after,
        clone_updates,
        judged_decisions,
        servo.failures,
        servo_mttf,
        servo.mean_reward,
        cloned.failures,
        clone_mttf,
        cloned.mean_reward,
    });
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("  held out ({d} of {d} starts, {d} rows): clone error {d:.4} (training {d:.4}); " ++
        "always-zero {d:.4}, training mean {d:.4}\n", .{
        starts / 5,
        starts,
        held_rows,
        held_error,
        result.after,
        zero_error,
        mean_error,
    });
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("  held-out error after", .{});
    for (checkpoints, curve) |checkpoint, value| {
        // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
        std.debug.print(" {d}: {d:.4}", .{ checkpoint, value });
    }
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  normaliser: {d} of {d} inputs spread under 1e-3; pinned at +-5: training {d:.2}%, held out " ++
        "{d:.2}%\n", .{
        narrow,
        demo.width,
        100.0 * float64(pinned[0]) / float64(@max(inputs[0], 1)),
        100.0 * float64(pinned[1]) / float64(@max(inputs[1], 1)),
    });
    try expect(result.after < result.before);
}

/// D5 step 3's budget: a teacher recording every `demo_stride` frames, up to `demo_cap` frames each; the clone's
/// minibatches; and how many decisions the judge watches (per character).
/// 10x the data (Sep 25): a start every 5 frames (was 20), each recorded clean AND perturbed.
const demo_stride: usize = 5;
const demo_cap: usize = 60;
const clone_updates: usize = 2000;
const judged_decisions: usize = 600;

test "robot_ppo_track: GAE - an episode CUT short is bootstrapped from where it ended; a lost one is not" {
    // Known answer: reward 1 a step, gamma 0.9, and a critic that is RIGHT - every value the worth of an endless
    // stream of 1s, 1 / (1 - 0.9) = 10 - so every TD error is zero. An episode cut short at its last step and
    // bootstrapped from the state it ended in (worth 10 too) must give advantages of exactly zero. Counted as a
    // death - the rule every end followed until Sep 26 - its last step's error is 1 - 10 = -9, leaking backward.
    const horizon: usize = 5;
    const rewards = [_]f32{ 1, 1, 1, 1, 1 };
    const values = [_]f32{ 10, 10, 10, 10, 10, 10 };
    const bootstrap = [_]f32{ 0, 0, 0, 0, 10 };
    var advantages: [5]f32 = undefined;
    var returns: [5]f32 = undefined;
    const cut = [_]ppo_track.EndKind{ .none, .none, .none, .none, .cut };
    ppo_track.gaeColumn(&rewards, &values, &cut, &bootstrap, horizon, 1, 0, 0.9, 0.95, &advantages, &returns);
    for (advantages, returns) |a, r| {
        try expect(@abs(a) < 1.0e-5 and @abs(r - 10.0) < 1.0e-5);
    }
    const lost = [_]ppo_track.EndKind{ .none, .none, .none, .none, .stop };
    ppo_track.gaeColumn(&rewards, &values, &lost, &bootstrap, horizon, 1, 0, 0.9, 0.95, &advantages, &returns);
    try expect(@abs(advantages[4] + 9.0) < 1.0e-5);
    try expect(@abs(advantages[3] - 0.9 * 0.95 * -9.0) < 1.0e-4);
    // The lambda-chain breaks at an end: a cut at step 2, then a new episode whose step 3 earns 2 - its surprise
    // must not reach back across the boundary.
    const rewards2 = [_]f32{ 1, 1, 1, 2, 1 };
    const boundary = [_]ppo_track.EndKind{ .none, .none, .cut, .none, .none };
    const bootstrap2 = [_]f32{ 0, 0, 10, 0, 0 };
    ppo_track.gaeColumn(&rewards2, &values, &boundary, &bootstrap2, horizon, 1, 0, 0.9, 0.95, &advantages, &returns);
    try expect(@abs(advantages[3] - 1.0) < 1.0e-5);
    try expect(@abs(advantages[2]) < 1.0e-5 and @abs(advantages[0]) < 1.0e-5);
}

test "robot_ppo_track: episodes CUT by the step cap are bootstrapped from where they ended (end to end)" {
    // The GAE known answer checks the arithmetic; this checks the plumbing: a real fleet and a real trainer with a
    // step cap of 6 physics steps (3 decisions), so every episode is cut short inside one batch. The decisions
    // that ended must say CUT and carry a finite, non-zero value of the state they ended in - valued from the
    // fleet's capture, before the restart - and `learn` must run on them.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const task: *geno.GenoTask = (try geno.GenoTask.init(gpa, threaded.io(), .dance_5_15)) orelse
        return error.SkipZigTest;
    defer task.deinit();
    const m: *rbt.Model = &task.imported.model;
    const clips = [_]*const dance.Clip{&task.clip};
    var host: Host = .initCpu();
    const trainer: *Trainer(zn_mlp) = try .init(gpa, &host, m, task.imported.names, &clips, .{
        .envs = 2,
        .horizon = 8,
        .epochs = 1,
        .minibatch = 8,
        .gains = geno.servo_gains,
        .floor_friction = geno.floor_friction,
        .watched = &geno.drecon_watched,
        .actuated = &geno.drecon_actuated,
        .action_scale = geno.student_scale,
        .rest_on_floor = true,
        .normalize = true,
        .max_episode_steps = 6,
    });
    defer trainer.deinit();
    while (!trainer.collect(4)) {}
    var cut: usize = 0;
    var stopped: usize = 0;
    for (trainer.ends, trainer.bootstrap) |end, value| {
        switch (end) {
            .none => {},
            .stop => stopped += 1,
            .cut => {
                cut += 1;
                try expect(value == value and value != 0.0);
            },
        }
    }
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  cut episodes: {d} decisions ended CUT (bootstrapped), {d} STOPPED, of {d}\n", .{
        cut,
        stopped,
        trainer.ends.len,
    });
    try expect(cut >= 2);
    _ = try trainer.learn();
}
