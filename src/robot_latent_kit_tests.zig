//! robot_latent_kit_tests - the kit's and the resident data's tests, in a file of their own.
//!
//! WHY THEY LIVE HERE. A test needs a CONCRETE kernel module, which means importing
//! `gpu/zn_mlp.zig` by path - and every page builds that same file as its own module. A file that
//! imports it cannot also belong to the `zimr` module a page imports, or Zig rightly refuses: one
//! file, two modules. Kept apart, the kit itself can be part of the engine, which is how
//! `robot_ppo_track` and its tests are arranged too.
//!
//! Everything here is checked against a CPU twin on identical inputs - that is what lets the backend
//! underneath change (a native SPIR-V one, one day) without these tests changing at all.

const std = @import("std");
const report = @import("test_report.zig");
const zn = @import("zn");
const zrl = @import("zrl");
const kit_mlp = @import("kit_mlp.zig");
const bmpc_kit = @import("robot_bmpc_kit.zig");
const zm = @import("zm");
const vec = zm.vec;
const float64 = zm.float64;
const rbt = @import("robot");
const track = @import("robot_track.zig");
const dance = @import("robot_dance.zig");
const latent = @import("robot_latent.zig");
const compute_host = @import("compute_host.zig");
const kit_mod = @import("robot_latent_kit.zig");
const zn_mlp = @import("gpu/zn_mlp.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Random = std.Random;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const Tensor = zn.Tensor(f32);
const Graph = zn.Graph(f32);
const Var = zn.Var;
const float = zm.float;
const expect = std.testing.expect;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const LatentKit = kit_mod.LatentKit;
const Resident = kit_mod.Resident;
const Start = kit_mod.Start;

/// The model's eight parameter tensors, random at a sensible scale - in `packWeights`' order: the
/// first layer's three blocks (features, reference, action) and its bias, then layers two and three.
fn randomParams(
    owned: Allocator,
    random: Random,
    f: u32,
    r: u32,
    a: u32,
    h: u32,
) ![8]Tensor {
    const shapes = [8][2]usize{
        .{ f, h }, .{ r, h }, .{ a, h }, .{ 1, h }, // first layer
        .{ h, h }, .{ 1, h }, .{ h, f }, .{ 1, f }, // second and third
    };
    var params: [8]Tensor = undefined;
    for (&params, shapes) |*p, shape| {
        p.* = try Tensor.alloc(owned, &shape);
        const deviation: f32 = @sqrt(1.0 / float(shape[0]));
        for (p.data) |*w| {
            w.* = deviation * random.floatNorm(f32);
        }
    }
    return params;
}

/// Random inputs where the caller stages them: block 0 in full, and every later block's reference
/// and action columns - the z columns of blocks 1 and on are the kit's to fill.
fn stageInputs(kit: anytype, staging: []f32, random: Random) void {
    @memset(staging, 0.0);
    for (0..kit.steps + 1) |step| {
        const base: usize = kit.blockX(@intCast(step));
        for (0..kit.rows) |row| {
            const start: usize = if (step == 0) 0 else kit.features;
            for (start..kit.width) |c| {
                staging[base + row * kit.width + c] = random.floatNorm(f32);
            }
        }
    }
}

test "robot_latent_kit: the kit's rollout matches the CPU model's own step" {
    // The CPU model's step (`robot_st.stepWith`, the very code it trains with) against the kit's
    // rollout, same weights, same inputs, the real feature sizes, 8 steps - each step feeding the
    // next, so a wrong offset anywhere compounds rather than hides.
    const gpa: Allocator = testing_allocator;
    var arena: ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    const f: u32 = 291;
    const r: u32 = 70;
    const a: u32 = 35;
    const h: u32 = 32;
    const rows: u32 = 4;
    const steps: u32 = 8;
    var rng: Random.DefaultPrng = .init(11);
    const random: Random = rng.random();

    const params: [8]Tensor = try randomParams(owned, random, f, r, a, h);

    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const kit: LatentKit(zn_mlp) = try .init(&host, f, r, a, h, rows, steps, 0, 0);
    host.element_count = kit.total + kit.param_count;
    const packed_weights: []f32 = try owned.alloc(f32, kit.param_count);
    kit.packWeights(params, packed_weights);
    host.upload(.params, packed_weights);

    // Inputs: block 0 in full, and every block's reference and action columns.
    const staging: []f32 = try owned.alloc(f32, kit.total);
    stageInputs(kit, staging, random);
    host.upload(.acts, staging);
    kit.forward();
    const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;

    // The CPU model, row by row, on the same inputs.
    const z: []f32 = try owned.alloc(f32, f);
    const hidden1: []f32 = try owned.alloc(f32, h);
    const hidden2: []f32 = try owned.alloc(f32, h);
    var worst: f32 = 0.0;
    for (0..rows) |row| {
        @memcpy(z, staging[kit.blockX(0) + row * kit.width ..][0..f]);
        for (0..steps) |step| {
            const block: usize = kit.blockX(@intCast(step)) + row * kit.width;
            latent.stepWith(params, hidden1, hidden2, z, staging[block + f ..][0..r], staging[block + f + r ..][0..a]);
            const kit_z: []const f32 = acts[kit.blockZ(@intCast(step + 1)) + row * f ..][0..f];
            for (z, kit_z) |cpu, gpu| {
                worst = @max(worst, @abs(cpu - gpu));
            }
        }
    }
    report.print("\n  kit rollout vs CPU step, 8 steps, 291 features: worst difference {e}\n", .{worst});
    try expect(worst <= 1.0e-5);
}

/// `count` columns from `first` of a strided block, as a rows x count tensor.
fn blockTensor(
    owned: Allocator,
    source: []const f32,
    base: u32,
    rows: u32,
    stride: u32,
    first: u32,
    count: u32,
) !Tensor {
    const t: Tensor = try .alloc(owned, &.{ rows, count });
    for (0..rows) |row| {
        @memcpy(t.data[row * count ..][0..count], source[base + row * stride + first ..][0..count]);
    }
    return t;
}

/// The kit's backward pass against zimrnum's graph of the CPU model, for rows with `lead` columns
/// in front of the world model's slice.
fn gradientsMatch(lead: u32) !void {
    // The kit's backward pass against zimrnum's graph of the CPU model - built from the model's own
    // `step`, with its own loss (the mean over steps of each step's MSE). The kit's loss is the SUM,
    // so kit = steps x CPU, weight for weight: the factor is part of what is checked, not waved off.
    const gpa: Allocator = testing_allocator;
    var arena: ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    const f: u32 = 291;
    const r: u32 = 70;
    const a: u32 = 35;
    const h: u32 = 32;
    const rows: u32 = 4;
    const steps: u32 = 8;
    var rng: Random.DefaultPrng = .init(23);
    const random: Random = rng.random();
    const params: [8]Tensor = try randomParams(owned, random, f, r, a, h);

    // The kit: forward, then backward, on staged inputs and targets.
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const kit: LatentKit(zn_mlp) = try .init(&host, f, r, a, h, rows, steps, lead, 0);
    host.element_count = @max(kit.total, @max(kit.dtotal, kit.param_count));
    const packed_weights: []f32 = try owned.alloc(f32, kit.param_count);
    kit.packWeights(params, packed_weights);
    host.upload(.params, packed_weights);
    const staging: []f32 = try owned.alloc(f32, kit.total);
    stageInputs(kit, staging, random);
    for (1..steps + 1) |step| {
        for (staging[kit.blockT(@intCast(step))..][0 .. rows * f]) |*t| {
            t.* = random.floatNorm(f32);
        }
    }
    host.upload(.acts, staging);
    kit.forward();
    kit.backward();
    const kit_grads: []const f32 = host.readLatest(.grads) orelse return error.NoReadback;

    // zimrnum: the CPU model's graph on the same batch.
    var graph: Graph = .init(owned);
    const g: *Graph = &graph;
    var vars: [8]Var = undefined;
    for (&vars, params) |*v, p| {
        v.* = try g.parameter(p);
    }
    const ones_t: Tensor = try .alloc(owned, &.{ rows, 1 });
    @memset(ones_t.data, 1.0);
    const ones: Var = try g.constant(ones_t);
    var z: Var = try g.constant(try blockTensor(owned, staging, kit.blockX(0), rows, kit.width, kit.lead, f));
    var total: ?Var = null;
    for (0..steps) |step| {
        const k: u32 = @intCast(step);
        const block: u32 = kit.blockX(k);
        const ref: Var = try g.constant(try blockTensor(owned, staging, block, rows, kit.width, kit.lead + f, r));
        const act: Var = try g.constant(try blockTensor(owned, staging, block, rows, kit.width, kit.lead + f + r, a));
        const target: Var = try g.constant(try blockTensor(owned, staging, kit.blockT(k + 1), rows, f, 0, f));
        z = try latent.LatentWorld.step(g, vars, z, ref, act, ones);
        const term: Var = try g.mseLoss(z, target);
        total = if (total) |t| try g.add(t, term) else term;
    }
    const loss: Var = try g.scale(total.?, 1.0 / float(steps));
    try g.backward(loss);

    var worst: f32 = 0.0;
    var largest: f32 = 0.0;
    var at: usize = 0;
    for (vars) |v| {
        const cpu: Tensor = try g.gradOf(v);
        for (cpu.data) |grad| {
            const expected: f32 = float(steps) * grad;
            worst = @max(worst, @abs(kit_grads[at] - expected));
            largest = @max(largest, @abs(expected));
            at += 1;
        }
    }
    try expect(at == kit.param_count);
    report.print("\n  kit gradients vs zimrnum (lead {d}), {d} weights: " ++
        "worst difference {e} (largest gradient {e})\n", .{
        lead,
        at,
        worst,
        largest,
    });
    try expect(worst <= 1.0e-4 * largest);
}

test "robot_latent_kit: every gradient of the rollout matches zimrnum's autodiff" {
    try gradientsMatch(0);
}

test "robot_latent_kit: and with goal columns in front, where the two widths differ" {
    // With a lead the row's stride and the world model's input width differ, and the backward
    // pass's input-gradient block is laid out by the narrower one - the mix-up that lead 0 (where
    // they are equal) cannot catch.
    try gradientsMatch(291);
}

test "robot_latent_kit: the change in units of the typical change - the same model as its last layer scaled" {
    // A world model predicting each feature's change in units of its typical change (mean + spread x output) is the
    // world model whose last layer is that scaling folded in: each output column of W3 times the feature's spread, its
    // bias times the spread plus the mean. Kit A runs with planted statistics; kit B, without them, with the folded
    // weights. Their rollouts must predict the same states; their gradients must be the same in layers 1 and 2, and in
    // layer 3 A's must be B's times each feature's spread - the chain rule through the scaling, which `changeGradient`
    // applies.
    const gpa: Allocator = testing_allocator;
    var arena: ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    const f: u32 = 291;
    const r: u32 = 70;
    const a: u32 = 35;
    const h: u32 = 32;
    const rows: u32 = 4;
    const steps: u32 = 8;
    var rng: Random.DefaultPrng = .init(29);
    const random: Random = rng.random();
    const params: [8]Tensor = try randomParams(owned, random, f, r, a, h);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    var kit: LatentKit(zn_mlp) = try .init(&host, f, r, a, h, rows, steps, 0, 0);
    // The statistics after the kit's own activations.
    const increments_at: u32 = kit.total;
    host.element_count = @max(kit.total + 2 * f, @max(kit.dtotal, kit.param_count));
    const weights: []f32 = try owned.alloc(f32, kit.param_count);
    kit.packWeights(params, weights);
    const staging: []f32 = try owned.alloc(f32, kit.total + 2 * f);
    stageInputs(kit, staging[0..kit.total], random);
    for (1..steps + 1) |step| {
        for (staging[kit.blockT(@intCast(step))..][0 .. rows * f]) |*t| {
            t.* = random.floatNorm(f32);
        }
    }
    const change_means: []f32 = staging[increments_at..][0..f];
    const change_spreads: []f32 = staging[increments_at + f ..][0..f];
    for (change_means, change_spreads) |*mean, *spread| {
        mean.* = 0.05 * random.floatNorm(f32);
        spread.* = 0.1 + random.float(f32);
    }
    // Kit A: the statistics on, the weights as they are.
    kit.increments_at = increments_at;
    host.upload(.params, weights);
    host.upload(.acts, staging);
    kit.forward();
    kit.backward();
    const state_floats: usize = steps * rows * f;
    const scaled_acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    const scaled_states: []f32 = try owned.dupe(f32, scaled_acts[kit.z_at..][0..state_floats]);
    const scaled_grads: []const f32 = host.readLatest(.grads) orelse return error.NoReadback;
    const scaled_gradients: []f32 = try owned.dupe(f32, scaled_grads[0..kit.param_count]);
    // Kit B: no statistics, the scaling folded into the last layer - W3 [hidden][feature], then b3.
    kit.increments_at = null;
    const folded: []f32 = try owned.dupe(f32, weights);
    for (0..h) |unit| {
        for (0..f) |feature| {
            folded[kit.w3 + unit * f + feature] *= change_spreads[feature];
        }
    }
    for (0..f) |feature| {
        const bias_at: usize = kit.w3 + h * f + feature;
        folded[bias_at] = folded[bias_at] * change_spreads[feature] + change_means[feature];
    }
    host.upload(.params, folded);
    host.upload(.acts, staging);
    kit.forward();
    kit.backward();
    const folded_acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    const folded_states: []const f32 = folded_acts[kit.z_at..][0..state_floats];
    const folded_grads: []const f32 = host.readLatest(.grads) orelse return error.NoReadback;
    const folded_gradients: []const f32 = folded_grads[0..kit.param_count];
    for (scaled_states, folded_states) |scaled, plain| {
        try expectApproxEqAbs(plain, scaled, 1e-4 * @max(1.0, @abs(plain)));
    }
    for (0..kit.param_count) |at| {
        const in_last_layer: bool = at >= kit.w3;
        const feature: usize = if (in_last_layer) (at - kit.w3) % f else 0;
        const scale: f32 = if (in_last_layer) change_spreads[feature] else 1.0;
        const expected: f32 = folded_gradients[at] * scale;
        try expectApproxEqAbs(expected, scaled_gradients[at], 1e-3 * @max(1.0, @abs(expected)));
    }
}

test "robot_latent_kit: every region is checked against its own buffer - the phone fits, eight times it does not" {
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    // The plan's phone configuration - 32 rows, width 256, 8 steps, ~470k floats of activations -
    // fits the enlarged activation buffer.
    const phone: LatentKit(zn_mlp) = try .init(&host, 291, 70, 35, 256, 32, 8, 0, 0);
    try expect(phone.total <= zn_mlp.acts_len);
    // Eight times the rows overflows it - about 3.8M floats of activations, past the activation
    // buffer's 2.1M - and is refused by name.
    const too_big = LatentKit(zn_mlp).init(&host, 291, 70, 35, 256, 256, 8, 0, 0);
    try expectError(error.KitActivationsTooSmall, too_big);
}

fn randomTensor(owned: Allocator, random: Random, rows: u32, cols: u32) !Tensor {
    const t: Tensor = try .alloc(owned, &.{ rows, cols });
    for (t.data) |*x| {
        x.* = random.floatNorm(f32);
    }
    return t;
}

test "robot_latent_kit: Adam on the kit takes the CPU model's step" {
    // The optimiser alone: the kit and the CPU model's AdamSet given IDENTICAL gradients (the real
    // gradients of the rollout's loss, from zimrnum) for three steps, so the moments and the bias
    // corrections at t = 1, 2, 3 are all exercised. Identical gradients because the gradients are
    // already checked, and because rounding-level differences in them can flip the SIGN of Adam's
    // first step for a weight whose gradient is near zero - which would test the gradients again,
    // badly, rather than the optimiser.
    const gpa: Allocator = testing_allocator;
    var arena: ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    const f: u32 = 291;
    const r: u32 = 70;
    const a: u32 = 35;
    const h: u32 = 32;
    const rows: u32 = 4;
    const steps: u32 = 4;
    var rng: Random.DefaultPrng = .init(31);
    const random: Random = rng.random();
    const params: [8]Tensor = try randomParams(owned, random, f, r, a, h);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const kit: LatentKit(zn_mlp) = try .init(&host, f, r, a, h, rows, steps, 0, 0);
    host.element_count = kit.param_count;
    const packed_weights: []f32 = try owned.alloc(f32, kit.param_count);
    kit.packWeights(params, packed_weights);
    host.upload(.params, packed_weights);
    const zeros: []f32 = try owned.alloc(f32, kit.param_count);
    @memset(zeros, 0.0);
    host.upload(.adam_m, zeros);
    host.upload(.adam_v, zeros);

    // Realistic gradients: the CPU model's loss on a random batch, through zimrnum.
    var graph: Graph = .init(owned);
    const g: *Graph = &graph;
    var vars: [8]Var = undefined;
    for (&vars, params) |*v, p| {
        v.* = try g.parameter(p);
    }
    const ones_t: Tensor = try .alloc(owned, &.{ rows, 1 });
    @memset(ones_t.data, 1.0);
    const ones: Var = try g.constant(ones_t);
    var z: Var = try g.constant(try randomTensor(owned, random, rows, f));
    var total: ?Var = null;
    for (0..steps) |_| {
        const ref: Var = try g.constant(try randomTensor(owned, random, rows, r));
        const act: Var = try g.constant(try randomTensor(owned, random, rows, a));
        z = try latent.LatentWorld.step(g, vars, z, ref, act, ones);
        const term: Var = try g.mseLoss(z, try g.constant(try randomTensor(owned, random, rows, f)));
        total = if (total) |t| try g.add(t, term) else term;
    }
    try g.backward(try g.scale(total.?, 1.0 / float(steps)));
    const packed_grads: []f32 = try owned.alloc(f32, kit.param_count);
    var at: usize = 0;
    for (vars) |v| {
        const grad: Tensor = try g.gradOf(v);
        @memcpy(packed_grads[at..][0..grad.data.len], grad.data);
        at += grad.data.len;
    }
    host.upload(.grads, packed_grads);

    // Three steps each: the kit's Adam, and zimrnum's `adamStep` - the very call the CPU model's
    // AdamSet makes per tensor (called directly, so this file need not import robot_gym and run its
    // tests too).
    var moments: [8]Tensor = undefined;
    var velocities: [8]Tensor = undefined;
    for (&moments, &velocities, params) |*m, *v, p| {
        m.* = try Tensor.alloc(owned, p.shape[0..p.rank]);
        v.* = try Tensor.alloc(owned, p.shape[0..p.rank]);
        @memset(m.data, 0.0);
        @memset(v.data, 0.0);
    }
    for (1..4) |t| {
        kit.adamStep(1.0e-3, @intCast(t), 1.0);
        for (params, vars, moments, velocities) |p, v, m, vel| {
            try zn.adamStep(f32, p, p, try g.gradOf(v), m, vel, .{ .rate = 1.0e-3 }, t);
        }
    }
    const kit_weights: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
    kit.packWeights(params, packed_weights);
    var worst: f32 = 0.0;
    for (kit_weights[0..kit.param_count], packed_weights) |gpu, cpu| {
        worst = @max(worst, @abs(gpu - cpu));
    }
    report.print("\n  kit Adam vs AdamSet, 3 steps, {d} weights: worst difference {e}\n", .{
        kit.param_count,
        worst,
    });
    // Three steps of rate 1e-3 move a weight up to ~3e-3; a wrong beta or bias correction would be
    // off by ~1e-4. Different rounding of the corrections is ~1e-9.
    try expect(worst <= 1.0e-6);
}

test "robot_latent_kit: the resident tables and ring hold exactly what the CPU would compute" {
    // A real fleet on the baked get-up clip (no retargeting: fast), stepped 40 times with the ring
    // appended after every step; then the kit's buffer read back and held against features computed
    // independently, by the same functions, for records and frames across the live range. BITWISE:
    // the same code on the same numbers - what this checks is the ADDRESSING (slots, rows, lockstep),
    // which is where a bug in resident data would hide.
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io: Io = threaded.io();
    const codecs = @import("codecs.zig");
    const mjcf = @import("mjcf.zig");
    const robot_mjcf = @import("robot_mjcf.zig");
    const xml: []const u8 = @embedFile("tests/fixtures/robot/humanoid_flex2.xml");
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, xml, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var options: rbt.Options = .{
        .timestep = 1.0 / 60.0,
        .gravity = vec(0, 0, -9.81),
        .max_contacts = 256,
    };
    options.solver.algorithm = .newton;
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, options);
    defer imported.deinit();
    const m: *rbt.Model = &imported.model;
    const baked: []u8 = blk: {
        var file: Io.File = Io.Dir.cwd().openFile(io, "examples/getup_train/getup.zclip", .{}) catch
            return error.SkipZigTest;
        defer file.close(io);
        const info: Io.File.Stat = try file.stat(io);
        const bytes: []u8 = try gpa.alloc(u8, info.size);
        _ = try file.readPositionalAll(io, bytes, 0);
        break :blk bytes;
    };
    defer gpa.free(baked);
    var clip: dance.Clip = try .fromBytes(gpa, baked);
    defer clip.deinit();
    const fleet: *track.Fleet = try .init(gpa, m, &.{&clip}, .{ .envs = 4, .capacity = 32 });
    defer fleet.deinit();

    var host: compute_host.Compute(zn_mlp) = .initCpu();
    var resident: Resident(zn_mlp) = try .init(gpa, &host, fleet, 1000, 4, 2);
    defer resident.deinit();
    host.element_count = resident.end;
    resident.uploadTables(fleet);
    const actions: []f32 = try gpa.alloc(f32, 4 * track.actionSize(m));
    defer gpa.free(actions);
    for (actions, 0..) |*action, i| {
        action.* = 0.01 * float(i % 7);
    }
    for (0..40) |_| {
        _ = fleet.step(actions);
        resident.appendLatest(fleet);
    }
    const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;

    var state: track.State = try .init(gpa, m.nbody);
    defer state.deinit(gpa);
    var data: rbt.Data = try .init(gpa, m);
    defer data.deinit();
    const expected: []f32 = try gpa.alloc(f32, resident.row);
    defer gpa.free(expected);
    // The ring: every character, every index still live (the last 32 of 40).
    var checked: usize = 0;
    for (0..4) |env| {
        var index: u64 = 8;
        while (index < 40) : (index += 1) {
            const at: u32 = resident.recordAt(env, index);
            fleet.stateAt(env, index, &data, &state);
            track.local(state, fleet.root, expected[0..resident.features]);
            try expect(eql(f32, expected[0..resident.features], acts[at..][0..resident.features]));
            const action: []const f32 = acts[at + resident.features ..][0..resident.actions];
            try expect(eql(f32, fleet.replay.actionAt(env, index), action));
            const frame: u32 = fleet.replay.frameAt(env, index);
            try expect(acts[at + resident.features + resident.actions] == float(frame));
            checked += 1;
        }
    }
    // The table: frames across the clip.
    for ([_]usize{ 0, 1, 150, 299 }) |frame| {
        const at: u32 = resident.rowAt(0, frame);
        fleet.referenceStateInto(&clip, @intCast(frame), &data, &state);
        track.local(state, fleet.root, expected[0..resident.features]);
        track.encodeTargets(m, clip.pose(frame)[clip.nq - m.nq ..], expected[resident.features..]);
        try expect(eql(f32, expected, acts[at..][0..resident.row]));
    }
    try expect(checked == 4 * 32);
}

/// A real fleet on the baked get-up clip, for the resident-data tests: no retargeting, so fast.
pub const FleetSetup = struct {
    gpa: Allocator,
    doc: @import("codecs.zig").xml.Document,
    robot: @import("mjcf.zig").Robot,
    imported: @import("robot_mjcf.zig").Imported,
    clip: dance.Clip,
    /// A second clip, for a fleet of two (`initTwoClips`).
    second_clip: ?dance.Clip = null,
    fleet: *track.Fleet,
    features: u32,
    references: u32,
    actions: u32,
    actions_buffer: []f32,

    pub fn init(self: *FleetSetup, gpa: Allocator) !void {
        return self.initFrom(gpa, "examples/getup_train/getup.zclip");
    }

    /// The same robot on TWO clips - the get-up pages' get-up and their dance - each character keeping one
    /// (`track.ClipAssignment.by_character`): character i on clip i mod 2.
    pub fn initTwoClips(self: *FleetSetup, gpa: Allocator) !void {
        try self.initFrom(gpa, "examples/getup_train/getup.zclip");
        errdefer self.deinit();
        var threaded: Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        const io: Io = threaded.io();
        var file: Io.File = Io.Dir.cwd().openFile(io, "examples/getup_train/dance.zclip", .{}) catch
            return error.SkipZigTest;
        defer file.close(io);
        const info: Io.File.Stat = try file.stat(io);
        const baked: []u8 = try gpa.alloc(u8, info.size);
        defer gpa.free(baked);
        _ = try file.readPositionalAll(io, baked, 0);
        self.second_clip = try dance.Clip.fromBytes(gpa, baked);
        // A fleet of both, replacing the one-clip fleet.
        self.fleet.deinit();
        const m: *rbt.Model = &self.imported.model;
        self.fleet = try track.Fleet.init(gpa, m, &.{ &self.clip, &self.second_clip.? }, .{
            .envs = 4,
            .capacity = 32,
            .clip_assignment = .by_character,
        });
    }

    /// Everything built here is released again if a later step fails - including the skip when the
    /// baked clip is missing, which would otherwise leak the robot and fail the test on leaks
    /// instead of skipping it.
    fn initFrom(self: *FleetSetup, gpa: Allocator, clip_path: []const u8) !void {
        const codecs = @import("codecs.zig");
        const mjcf = @import("mjcf.zig");
        const robot_mjcf = @import("robot_mjcf.zig");
        var threaded: Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        const io: Io = threaded.io();
        // whole-init-first: the whole struct first - defaults applied, every field named.
        self.* = .{
            .gpa = undefined,
            .doc = undefined,
            .robot = undefined,
            .imported = undefined,
            .clip = undefined,
            .second_clip = null,
            .fleet = undefined,
            .features = undefined,
            .references = undefined,
            .actions = undefined,
            .actions_buffer = undefined,
        };
        self.gpa = gpa;
        self.doc = try codecs.xml.parse(gpa, @embedFile("tests/fixtures/robot/humanoid_flex2.xml"), null);
        errdefer self.doc.deinit();
        self.robot = try mjcf.readRobot(gpa, &self.doc);
        errdefer self.robot.deinit();
        var options: rbt.Options = .{
            .timestep = 1.0 / 60.0,
            .gravity = vec(0, 0, -9.81),
            .max_contacts = 256,
        };
        options.solver.algorithm = .newton;
        self.imported = try robot_mjcf.build(gpa, &self.robot, options);
        errdefer self.imported.deinit();
        const m: *rbt.Model = &self.imported.model;
        var file: Io.File = Io.Dir.cwd().openFile(io, clip_path, .{}) catch
            return error.SkipZigTest;
        defer file.close(io);
        const info: Io.File.Stat = try file.stat(io);
        const baked: []u8 = try gpa.alloc(u8, info.size);
        defer gpa.free(baked);
        _ = try file.readPositionalAll(io, baked, 0);
        self.clip = try dance.Clip.fromBytes(gpa, baked);
        errdefer self.clip.deinit();
        self.fleet = try track.Fleet.init(gpa, m, &.{&self.clip}, .{ .envs = 4, .capacity = 32 });
        errdefer self.fleet.deinit();
        self.features = @intCast(track.localSize(m.nbody));
        self.references = @intCast(track.targetSize(m));
        self.actions = @intCast(track.actionSize(m));
        self.actions_buffer = try gpa.alloc(f32, 4 * self.actions);
        for (self.actions_buffer, 0..) |*action, i| {
            action.* = 0.01 * float(i % 7);
        }
    }

    pub fn deinit(self: *FleetSetup) void {
        self.gpa.free(self.actions_buffer);
        self.fleet.deinit();
        if (self.second_clip) |*second| {
            second.deinit();
        }
        self.clip.deinit();
        self.imported.deinit();
        self.robot.deinit();
        self.doc.deinit();
    }
};

test "robot_latent_kit: the gather assembles on the GPU exactly the windows the CPU would" {
    // The resident ring and tables of a real fleet (the baked get-up), a normaliser, and windows the
    // CPU replay sampled; the kit's blocks read back and held against the CPU's own code - features
    // by `local`, normalised by `Normalizer.toNormal`, references by `encodeTargets`, actions from the
    // replay. BITWISE: the kernel normalises with the CPU's operations in the CPU's order.
    const gpa: Allocator = testing_allocator;
    var setup: FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const m: *const rbt.Model = fleet.m;
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const rows: u32 = 4;
    const steps: u32 = 4;
    const kit: LatentKit(zn_mlp) =
        try .init(&host, setup.features, setup.references, setup.actions, 16, rows, steps, 0, 0);
    var resident: Resident(zn_mlp) = try .init(gpa, &host, fleet, kit.total, rows, 2);
    defer resident.deinit();
    host.element_count = resident.end;
    resident.uploadTables(fleet);
    for (0..40) |_| {
        _ = fleet.step(setup.actions_buffer);
        resident.appendLatest(fleet);
    }
    // A normaliser with a different mean and spread for every feature, so a wrong index shows.
    const mean: []f32 = try gpa.alloc(f32, setup.features);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, setup.features);
    defer gpa.free(spread);
    for (mean, spread, 0..) |*mu, *sigma, c| {
        mu.* = 0.01 * float(c % 13) - 0.05;
        sigma.* = 0.5 + 0.03 * float(c % 17);
    }
    const norm: latent.Normalizer = .{ .mean = mean, .spread = spread };
    resident.uploadNormalizer(norm);
    var rng: Random.DefaultPrng = .init(3);
    var starts: [4]Start = undefined;
    for (&starts) |*start| {
        const window: track.Replay.Window = fleet.replay.sampleWindow(rng.random(), steps) orelse return error.NoData;
        start.* = .{ .env = @intCast(window.env), .index = window.first };
    }
    resident.stageStarts(&starts, 0, steps);
    resident.gather(kit, 0);
    const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;

    var state: track.State = try .init(gpa, m.nbody);
    defer state.deinit(gpa);
    var data: rbt.Data = try .init(gpa, m);
    defer data.deinit();
    const raw: []f32 = try gpa.alloc(f32, setup.features);
    defer gpa.free(raw);
    const expected: []f32 = try gpa.alloc(f32, @max(setup.features, setup.references));
    defer gpa.free(expected);
    for (starts, 0..) |start, row| {
        for (0..steps + 1) |step| {
            const index: u64 = start.index + step;
            fleet.stateAt(start.env, index, &data, &state);
            track.local(state, fleet.root, raw);
            norm.toNormal(raw, expected[0..setup.features]);
            const z_at: usize = if (step == 0)
                kit.blockX(0) + row * kit.width
            else
                kit.blockT(@intCast(step)) + row * setup.features;
            try expect(eql(f32, expected[0..setup.features], acts[z_at..][0..setup.features]));
            if (step < steps) {
                const block: usize = kit.blockX(@intCast(step)) + row * kit.width;
                // The pose the servo aimed at during this step: the next frame, clamped.
                const next: usize = @as(usize, fleet.replay.frameAt(start.env, index)) + 1;
                const frame: usize = @min(next, setup.clip.frame_count - 1);
                const pose: []const f32 = setup.clip.pose(frame)[setup.clip.nq - m.nq ..];
                track.encodeTargets(m, pose, expected[0..setup.references]);
                const ref: []const f32 = acts[block + setup.features ..][0..setup.references];
                try expect(eql(f32, expected[0..setup.references], ref));
                const action: []const f32 = acts[block + setup.features + setup.references ..][0..setup.actions];
                try expect(eql(f32, fleet.replay.actionAt(start.env, index), action));
            }
        }
    }
}

test "robot_latent_kit: trained on gathered windows, the kit follows the CPU model step for step" {
    // The whole resident training step - gather, rollout, backward, Adam - against the CPU model's
    // own `trainOn`, from the same starting weights and normaliser, on the SAME windows every step,
    // for 60 steps. Compared by the LOSS each reports before its update: weights compared after an
    // Adam step would flag the rare weight whose near-zero gradient rounds to the other sign, which
    // tests rounding, not training. Both must also descend - judged by the mean of the last ten
    // steps against the first ten, because each step's loss is on a different batch of only eight
    // windows, and because a model that starts as "nothing changes" (a near-zero output layer, which
    // Adam's first steps move by more than its own size) rises before it falls.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var setup: FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const rows: u32 = 8;
    const steps: u32 = 8;
    const hidden: u32 = 32;
    // WITH a policy in the kit (it has goal columns, and weights beside the world model's): the world
    // model must still train on the RECORDED actions. Trained through the acting rollout instead, it
    // would learn the simulator's outcomes for actions the simulator never took, and these losses would
    // part company with the CPU model's at once.
    var kit: LatentKit(zn_mlp) = try .init(
        &host,
        setup.features,
        setup.references,
        setup.actions,
        hidden,
        rows,
        steps,
        setup.features,
        16,
    );
    // A stats block just past the networks' weights: the world model's loss for the log beside the page's.
    kit.stats_at = kit.param_count + kit.policy_count;
    var resident: Resident(zn_mlp) = try .init(gpa, &host, fleet, kit.total, rows, 2);
    defer resident.deinit();
    host.element_count = resident.end;
    resident.uploadTables(fleet);
    for (0..60) |_| {
        _ = fleet.step(setup.actions_buffer);
        resident.appendLatest(fleet);
    }
    // The CPU model on the same data; its normaliser and its starting weights go to the kit.
    const world: *latent.LatentWorld = try .init(gpa, fleet, .{ .hidden = hidden, .steps = steps, .batch = rows });
    defer world.deinit(gpa);
    resident.uploadNormalizer(world.norm);
    const packed_weights: []f32 = try gpa.alloc(f32, kit.param_count);
    defer gpa.free(packed_weights);
    kit.packWeights(world.params, packed_weights);
    host.upload(.params, packed_weights);
    @memset(packed_weights, 0.0);
    host.upload(.adam_m, packed_weights);
    host.upload(.adam_v, packed_weights);

    var rng: Random.DefaultPrng = .init(17);
    var windows: [rows]track.Replay.Window = undefined;
    var starts: [rows]Start = undefined;
    var worst: f32 = 0.0;
    var first: [2]f32 = .{ 0.0, 0.0 };
    var last: [2]f32 = .{ 0.0, 0.0 };
    for (1..61) |t| {
        for (&windows, &starts) |*window, *start| {
            window.* = fleet.replay.sampleWindow(rng.random(), steps) orelse return error.NoData;
            start.* = .{ .env = @intCast(window.env), .index = window.first };
        }
        const cpu: f32 = try world.trainOn(fleet, &windows);
        resident.stageStarts(&starts, 0, steps);
        resident.gather(kit, 0);
        kit.forwardRecorded();
        if (t == 1) {
            // The recorded rollout leaves every row's action columns as the gather wrote them: the
            // action the simulator took at that step.
            const staged: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
            const at: usize = kit.blockX(0) + kit.lead + kit.features + kit.references;
            const taken: []const f32 = fleet.replay.actionAt(starts[0].env, starts[0].index);
            try expect(eql(f32, taken, staged[at..][0..kit.actions]));
        }
        kit.loss();
        const gpu: f32 = (host.readLatest(.loss) orelse return error.NoReadback)[0];
        // The log's number is the page's: the same arithmetic on the same predictions and targets.
        kit.recordWorldModelLoss();
        const stats_params: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
        try expectEqual(gpu, stats_params[kit.stats_at.? + kit_mod.DeviceStats.slot("world_model_loss")]);
        kit.backward();
        kit.adamStep(1.0e-3, @intCast(t), float(steps));
        worst = @max(worst, @abs(gpu - cpu) / cpu);
        if (t <= 10) {
            first[0] += cpu / 10.0;
            first[1] += gpu / 10.0;
        } else if (t > 50) {
            last[0] += cpu / 10.0;
            last[1] += gpu / 10.0;
        }
    }
    report.print("\n  gathered training, 60 steps (means of the first and last ten): CPU {d:.4} -> {d:.4}, " ++
        "kit {d:.4} -> {d:.4}, worst relative gap {e}\n", .{
        first[0],
        last[0],
        first[1],
        last[1],
        worst,
    });
    try expect(worst < 1.0e-3);
    try expect(last[0] < first[0] and last[1] < first[1]);
}

test "robot_latent_kit: goal columns in front of every row, and the world model still reads only its slice" {
    // Rows of `[goal | z | reference | action]`, the goal columns full of random numbers the world
    // model must never see. Its rollout must still match the CPU model's step BITWISE - which it can
    // only do if every layer reads exactly its slice of the strided row. (The backward pass, whose
    // input-gradient block is narrower than the row, is checked with a lead in `gradientsMatch`.)
    const gpa: Allocator = testing_allocator;
    var arena: ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    const f: u32 = 291;
    const r: u32 = 70;
    const a: u32 = 35;
    const h: u32 = 32;
    const rows: u32 = 4;
    const steps: u32 = 8;
    var rng: Random.DefaultPrng = .init(41);
    const random: Random = rng.random();
    const params: [8]Tensor = try randomParams(owned, random, f, r, a, h);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const kit: LatentKit(zn_mlp) = try .init(&host, f, r, a, h, rows, steps, f, 0);
    try expect(kit.width == f + kit.inputs);
    host.element_count = kit.total + kit.param_count;
    const packed_weights: []f32 = try owned.alloc(f32, kit.param_count);
    kit.packWeights(params, packed_weights);
    host.upload(.params, packed_weights);
    // Every row's goal columns random; block 0's state; every block's reference and action.
    const staging: []f32 = try owned.alloc(f32, kit.total);
    @memset(staging, 0.0);
    for (0..steps + 1) |step| {
        const base: usize = kit.blockX(@intCast(step));
        for (0..rows) |row| {
            for (0..kit.width) |c| {
                const state_column: bool = c >= kit.lead and c < kit.lead + f;
                if (step == 0 or !state_column) {
                    staging[base + row * kit.width + c] = random.floatNorm(f32);
                }
            }
        }
    }
    host.upload(.acts, staging);
    kit.forward();
    const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    const z: []f32 = try owned.alloc(f32, f);
    const hidden1: []f32 = try owned.alloc(f32, h);
    const hidden2: []f32 = try owned.alloc(f32, h);
    var worst: f32 = 0.0;
    for (0..rows) |row| {
        @memcpy(z, staging[kit.blockX(0) + row * kit.width + kit.lead ..][0..f]);
        for (0..steps) |step| {
            const slice: usize = kit.blockX(@intCast(step)) + row * kit.width + kit.lead;
            latent.stepWith(params, hidden1, hidden2, z, staging[slice + f ..][0..r], staging[slice + f + r ..][0..a]);
            const kit_z: []const f32 = acts[kit.blockZ(@intCast(step + 1)) + row * f ..][0..f];
            for (z, kit_z) |cpu, gpu| {
                worst = @max(worst, @abs(cpu - gpu));
            }
            // And the join wrote the next row's state columns, not its goal columns.
            const next_goal: []const f32 = acts[kit.blockX(@intCast(step + 1)) + row * kit.width ..][0..kit.lead];
            const staged_goal: []const f32 = staging[kit.blockX(@intCast(step + 1)) + row * kit.width ..][0..kit.lead];
            try expect(eql(f32, staged_goal, next_goal));
        }
    }
    try expect(worst == 0.0);
}

test "robot_latent_kit: the gather fills each row's goal, and the goal block, from the tables" {
    // With a lead, every row starts with the reference's features at its step's frame, normalised,
    // and the contiguous goal block holds the same for steps 1..steps - against the CPU learner's
    // own recipe (`referenceStateInto`, `local`, `toNormal`), BITWISE. And the world model's slice
    // must be exactly what it is without a lead.
    const gpa: Allocator = testing_allocator;
    var setup: FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const m: *const rbt.Model = fleet.m;
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const rows: u32 = 4;
    const steps: u32 = 4;
    const f: u32 = setup.features;
    const kit: LatentKit(zn_mlp) =
        try .init(&host, f, setup.references, setup.actions, 16, rows, steps, f, 0);
    var resident: Resident(zn_mlp) = try .init(gpa, &host, fleet, kit.total, rows, 2);
    defer resident.deinit();
    host.element_count = resident.end;
    resident.uploadTables(fleet);
    for (0..40) |_| {
        _ = fleet.step(setup.actions_buffer);
        resident.appendLatest(fleet);
    }
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    for (mean, spread, 0..) |*mu, *sigma, c| {
        mu.* = 0.02 * float(c % 11) - 0.1;
        sigma.* = 0.7 + 0.05 * float(c % 19);
    }
    const norm: latent.Normalizer = .{ .mean = mean, .spread = spread };
    resident.uploadNormalizer(norm);
    var rng: Random.DefaultPrng = .init(9);
    var starts: [4]Start = undefined;
    for (&starts) |*start| {
        const window: track.Replay.Window = fleet.replay.sampleWindow(rng.random(), steps) orelse return error.NoData;
        start.* = .{ .env = @intCast(window.env), .index = window.first };
    }
    resident.stageStarts(&starts, 0, steps);
    resident.gather(kit, 0);
    const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;

    var state: track.State = try .init(gpa, m.nbody);
    defer state.deinit(gpa);
    var data: rbt.Data = try .init(gpa, m);
    defer data.deinit();
    const raw: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(raw);
    const expected: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(expected);
    for (starts, 0..) |start, row| {
        for (0..steps + 1) |step| {
            const index: u64 = start.index + step;
            // The goal: the reference at this record's frame, as the CPU learner computes it.
            fleet.referenceStateInto(&setup.clip, fleet.replay.frameAt(start.env, index), &data, &state);
            track.local(state, fleet.root, raw);
            norm.toNormal(raw, expected);
            // A record's goal is where the PREVIOUS step was going: that step's row, and its target.
            if (step > 0) {
                const in_row: []const f32 = acts[kit.blockX(@intCast(step - 1)) + row * kit.width ..][0..f];
                try expect(eql(f32, expected, in_row));
                const in_block: []const f32 = acts[kit.blockG(@intCast(step)) + row * f ..][0..f];
                try expect(eql(f32, expected, in_block));
            }
            // The world model's slice is unmoved by the lead: its state (step 0) and its target.
            fleet.stateAt(start.env, index, &data, &state);
            track.local(state, fleet.root, raw);
            norm.toNormal(raw, expected);
            const z_at: usize = if (step == 0)
                kit.blockX(0) + row * kit.width + kit.lead
            else
                kit.blockT(@intCast(step)) + row * f;
            try expect(eql(f32, expected, acts[z_at..][0..f]));
        }
    }
}

test "robot_latent_kit: a missing baked clip skips the resident tests cleanly, leaking nothing" {
    // The error path the setup had no errdefers for: the robot is built, then the clip is not
    // found. It must come back as a skip with everything released - the testing allocator fails
    // this test on any leak.
    var setup: FleetSetup = undefined;
    try expectError(error.SkipZigTest, setup.initFrom(testing_allocator, "no/such/clip.zclip"));
}

test "robot_latent_kit: the exploration noise is centred, has unit spread, and is not correlated" {
    // 40,000 draws over rows, columns and steps: mean near 0, variance near 1, neighbouring columns
    // uncorrelated, and bounded where Irwin-Hall says (+-2 sqrt 3). A hash that mixed badly would show
    // up here as a biased mean or a correlation between neighbours.
    var sum: f64 = 0.0;
    var squares: f64 = 0.0;
    var neighbours: f64 = 0.0;
    var largest: f32 = 0.0;
    var count: usize = 0;
    for (0..40) |step| {
        const seed: u32 = zn_mlp.latStepSeed(7, @intCast(step));
        for (0..50) |row| {
            var previous: f32 = zn_mlp.latNoise(seed, @intCast(row), 0);
            for (1..21) |column| {
                const x: f32 = zn_mlp.latNoise(seed, @intCast(row), @intCast(column));
                sum += x;
                squares += @as(f64, x) * x;
                neighbours += @as(f64, x) * previous;
                largest = @max(largest, @abs(x));
                previous = x;
                count += 1;
            }
        }
    }
    const n: f64 = @floatFromInt(count);
    const mean: f64 = sum / n;
    const variance: f64 = squares / n - mean * mean;
    const correlation: f64 = neighbours / n;
    try expect(@abs(mean) < 0.03 and @abs(variance - 1.0) < 0.05 and @abs(correlation) < 0.03);
    try expect(largest <= 3.4641017);
}

test "robot_latent_kit: the policy acts in the rollout, and the kit follows the CPU learner" {
    // A policy choosing every step's action, the world model predicting the consequence, 8 steps -
    // against the CPU learner's own `policyWith` feeding the CPU model's `stepWith`. Not bitwise: the
    // CPU sums the policy's state and goal terms interleaved, the kit goal block then state block.
    const gpa: Allocator = testing_allocator;
    var arena: ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    const f: u32 = 291;
    const r: u32 = 70;
    const a: u32 = 35;
    const h: u32 = 32;
    const hp: u32 = 32;
    const rows: u32 = 4;
    const steps: u32 = 8;
    var rng: Random.DefaultPrng = .init(53);
    const random: Random = rng.random();
    const world: [8]Tensor = try randomParams(owned, random, f, r, a, h);
    const policy_shapes = [7][2]usize{
        .{ f, hp }, .{ f, hp }, .{ 1, hp }, // first layer: state, goal, bias
        .{ hp, hp }, .{ 1, hp }, .{ hp, a }, .{ 1, a }, // second layer, and the raw action
    };
    var policy: [7]Tensor = undefined;
    for (&policy, policy_shapes) |*p, shape| {
        p.* = try Tensor.alloc(owned, &shape);
        const deviation: f32 = @sqrt(1.0 / float(shape[0]));
        for (p.data) |*w| {
            w.* = deviation * random.floatNorm(f32);
        }
    }
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    var kit: LatentKit(zn_mlp) = try .init(&host, f, r, a, h, rows, steps, f, hp);
    kit.action_scale = 0.3;
    kit.sigma = 0.3;
    kit.seed = 1234;
    host.element_count = kit.total + kit.param_count + kit.policy_count;
    const packed_world: []f32 = try owned.alloc(f32, kit.param_count);
    kit.packWeights(world, packed_world);
    host.upload(.params, packed_world);
    const packed_policy: []f32 = try owned.alloc(f32, kit.policy_count);
    kit.packPolicy(policy, packed_policy);
    host.uploadAt(.params, kit.p_at, packed_policy);
    // Every row's goal and reference; block 0's state. (Actions: the policy's to write.)
    const staging: []f32 = try owned.alloc(f32, kit.total);
    @memset(staging, 0.0);
    for (0..steps + 1) |step| {
        const base: usize = kit.blockX(@intCast(step));
        for (0..rows) |row| {
            for (0..f + f + r) |c| {
                const state_column: bool = c >= f and c < 2 * f;
                if (step == 0 or !state_column) {
                    staging[base + row * kit.width + c] = random.floatNorm(f32);
                }
            }
        }
    }
    host.upload(.acts, staging);
    kit.forward();
    const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;

    const z: []f32 = try owned.alloc(f32, f);
    const action: []f32 = try owned.alloc(f32, a);
    const world_hidden: [2][]f32 = .{ try owned.alloc(f32, h), try owned.alloc(f32, h) };
    const policy_hidden: [2][]f32 = .{ try owned.alloc(f32, hp), try owned.alloc(f32, hp) };
    var worst_state: f32 = 0.0;
    var worst_action: f32 = 0.0;
    for (0..rows) |row| {
        @memcpy(z, staging[kit.blockX(0) + row * kit.width + f ..][0..f]);
        for (0..steps) |step| {
            const at: usize = kit.blockX(@intCast(step)) + row * kit.width;
            const goal: []const f32 = staging[at..][0..f];
            // The kit's policy is the seven-tensor one: it does not see what it applies (plan A1; the
            // kit catches up in Stage G), so the CPU side is handed no applied action either.
            latent.policyWith(policy, policy_hidden[0], policy_hidden[1], z, goal, null, action);
            // The noise, from the kit's own function (the kernel's), then the scale.
            const step_seed: u32 = zn_mlp.latStepSeed(1234, @intCast(step));
            for (action, 0..) |*x, j| {
                x.* = 0.3 * (x.* + 0.3 * zn_mlp.latNoise(step_seed, @intCast(row), @intCast(j)));
            }
            for (action, acts[at + 2 * f + r ..][0..a]) |cpu, gpu| {
                worst_action = @max(worst_action, @abs(cpu - gpu));
            }
            latent.stepWith(world, world_hidden[0], world_hidden[1], z, staging[at + 2 * f ..][0..r], action);
            for (z, acts[kit.blockZ(@intCast(step + 1)) + row * f ..][0..f]) |cpu, gpu| {
                worst_state = @max(worst_state, @abs(cpu - gpu));
            }
        }
    }
    report.print("\n  policy in the rollout, 8 steps: worst action difference {e}, worst state {e}\n", .{
        worst_action,
        worst_state,
    });
    try expect(worst_action <= 1.0e-5 and worst_state <= 1.0e-4);
}

test "robot_latent_kit: the policy's gradients through the frozen world model match zimrnum" {
    // The policy's loss - distance from the goal at every step, plus the action price - backpropagated
    // through a FIXED world model, against zimrnum's graph built from the CPU learner's own
    // `policyOnGraph` and the CPU model's own `step`, the same noise drawn from the kit's hash. The
    // kit's loss is the SUM over steps: every policy gradient must be `steps` times the CPU's.
    const gpa: Allocator = testing_allocator;
    var arena: ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    const f: u32 = 291;
    const r: u32 = 70;
    const a: u32 = 35;
    const h: u32 = 32;
    const hp: u32 = 32;
    const rows: u32 = 4;
    const steps: u32 = 8;
    const scale: f32 = 0.3;
    const sigma: f32 = 0.3;
    const price: f32 = 0.1;
    // And the smoothness price (CAPS), so its kernel path - each step's action pulled toward its neighbours -
    // is checked against autodiff too.
    const smooth: f32 = 0.3;
    const seed: u32 = 99;
    var rng: Random.DefaultPrng = .init(61);
    const random: Random = rng.random();
    const world: [8]Tensor = try randomParams(owned, random, f, r, a, h);
    const policy_shapes = [7][2]usize{
        .{ f, hp }, .{ f, hp }, .{ 1, hp }, // first layer: state, goal, bias
        .{ hp, hp }, .{ 1, hp }, .{ hp, a }, .{ 1, a }, // second layer, and the raw action
    };
    var policy: [7]Tensor = undefined;
    for (&policy, policy_shapes) |*p, shape| {
        p.* = try Tensor.alloc(owned, &shape);
        const deviation: f32 = @sqrt(1.0 / float(shape[0]));
        for (p.data) |*w| {
            w.* = deviation * random.floatNorm(f32);
        }
    }
    // Goals for steps 0..steps, a start, references: the same numbers for the kit and the graph.
    var goals: [steps + 1]Tensor = undefined;
    for (&goals) |*goal| {
        goal.* = try randomTensor(owned, random, rows, f);
    }
    const start: Tensor = try randomTensor(owned, random, rows, f);
    var refs: [steps]Tensor = undefined;
    for (&refs) |*ref| {
        ref.* = try randomTensor(owned, random, rows, r);
    }

    // The kit.
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    var kit: LatentKit(zn_mlp) = try .init(&host, f, r, a, h, rows, steps, f, hp);
    kit.action_scale = scale;
    kit.sigma = sigma;
    kit.seed = seed;
    kit.w_action = price;
    kit.w_smooth = smooth;
    host.element_count = @max(kit.total, @max(kit.dtotal, kit.param_count + kit.policy_count));
    const packed_world: []f32 = try owned.alloc(f32, kit.param_count);
    kit.packWeights(world, packed_world);
    host.upload(.params, packed_world);
    const packed_policy: []f32 = try owned.alloc(f32, kit.policy_count);
    kit.packPolicy(policy, packed_policy);
    host.uploadAt(.params, kit.p_at, packed_policy);
    const staging: []f32 = try owned.alloc(f32, kit.total);
    @memset(staging, 0.0);
    for (0..steps) |step| {
        for (0..rows) |row| {
            const at: usize = kit.blockX(@intCast(step)) + row * kit.width;
            @memcpy(staging[at..][0..f], goals[step].data[row * f ..][0..f]);
            @memcpy(staging[at + 2 * f ..][0..r], refs[step].data[row * r ..][0..r]);
            if (step == 0) {
                @memcpy(staging[at + f ..][0..f], start.data[row * f ..][0..f]);
            }
        }
    }
    for (1..steps + 1) |step| {
        @memcpy(staging[kit.blockG(@intCast(step))..][0 .. rows * f], goals[step].data);
    }
    host.upload(.acts, staging);
    kit.forward();
    kit.policyBackward();
    const grads: []const f32 = host.readLatest(.grads) orelse return error.NoReadback;

    // zimrnum: the CPU learner's loss on the same numbers.
    var graph: Graph = .init(owned);
    const g: *Graph = &graph;
    var policy_vars: [7]Var = undefined;
    for (&policy_vars, policy) |*v, p| {
        v.* = try g.parameter(p);
    }
    var world_vars: [8]Var = undefined;
    for (&world_vars, world) |*v, p| {
        v.* = try g.parameter(p);
    }
    const ones_t: Tensor = try .alloc(owned, &.{ rows, 1 });
    @memset(ones_t.data, 1.0);
    const ones: Var = try g.constant(ones_t);
    const zeros_t: Tensor = try .alloc(owned, &.{ rows, a });
    @memset(zeros_t.data, 0.0);
    const no_action: Var = try g.constant(zeros_t);
    var z: Var = try g.constant(start);
    var total: ?Var = null;
    var previous: ?Var = null;
    for (0..steps) |step| {
        const noise_t: Tensor = try .alloc(owned, &.{ rows, a });
        const step_seed: u32 = zn_mlp.latStepSeed(seed, @intCast(step));
        for (0..rows) |row| {
            for (0..a) |j| {
                noise_t.data[row * a + j] = zn_mlp.latNoise(step_seed, @intCast(row), @intCast(j));
            }
        }
        const goal: Var = try g.constant(goals[step]);
        const raw: Var = try latent.Learner.policyOnGraph(g, policy_vars, z, goal, null, ones);
        const noisy: Var = try g.add(raw, try g.scale(try g.constant(noise_t), sigma));
        const action: Var = try g.scale(noisy, scale);
        z = try latent.LatentWorld.step(g, world_vars, z, try g.constant(refs[step]), action, ones);
        var term: Var = try g.mseLoss(z, try g.constant(goals[step + 1]));
        term = try g.add(term, try g.scale(try g.mseLoss(raw, no_action), price));
        if (previous) |before| {
            const jump: Var = try g.add(raw, try g.scale(before, -1.0));
            term = try g.add(term, try g.scale(try g.mseLoss(jump, no_action), smooth));
        }
        previous = raw;
        total = if (total) |t| try g.add(t, term) else term;
    }
    try g.backward(try g.scale(total.?, 1.0 / float(steps)));

    // Compare in the kit's packing order: goal block, state block, then the rest.
    var worst: f32 = 0.0;
    var largest: f32 = 0.0;
    var at: usize = kit.p_at;
    for ([_]usize{ 1, 0, 2, 3, 4, 5, 6 }) |i| {
        const cpu: Tensor = try g.gradOf(policy_vars[i]);
        for (cpu.data) |grad| {
            const expected: f32 = float(steps) * grad;
            worst = @max(worst, @abs(grads[at] - expected));
            largest = @max(largest, @abs(expected));
            at += 1;
        }
    }
    try expect(at == kit.p_at + kit.policy_count);
    report.print("\n  policy gradients vs zimrnum, {d} weights: worst difference {e} (largest {e})\n", .{
        kit.policy_count,
        worst,
        largest,
    });
    try expect(worst <= 1.0e-4 * largest);
}

test "robot_latent_kit: Adam moves only the policy's weights, and takes zimrnum's step" {
    // The policy's weights against zimrnum's `adamStep` on identical gradients, three steps (moments
    // and bias corrections at t = 1, 2, 3). And the world model's weights and optimiser state must not
    // move by a bit - its gradient region is filled with NON-zero numbers, so a step that strayed out
    // of the policy's region would change them.
    const gpa: Allocator = testing_allocator;
    var arena: ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    const f: u32 = 291;
    const r: u32 = 70;
    const a: u32 = 35;
    const h: u32 = 16;
    const hp: u32 = 16;
    var rng: Random.DefaultPrng = .init(71);
    const random: Random = rng.random();
    const world: [8]Tensor = try randomParams(owned, random, f, r, a, h);
    const policy_shapes = [7][2]usize{
        .{ f, hp }, .{ f, hp }, .{ 1, hp }, // first layer: state, goal, bias
        .{ hp, hp }, .{ 1, hp }, .{ hp, a }, .{ 1, a }, // second layer, and the raw action
    };
    var policy: [7]Tensor = undefined;
    var grads: [7]Tensor = undefined;
    for (&policy, &grads, policy_shapes) |*p, *g, shape| {
        p.* = try Tensor.alloc(owned, &shape);
        g.* = try Tensor.alloc(owned, &shape);
        for (p.data, g.data) |*w, *d| {
            w.* = 0.1 * random.floatNorm(f32);
            d.* = random.floatNorm(f32);
        }
    }
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const kit: LatentKit(zn_mlp) = try .init(&host, f, r, a, h, 2, 2, f, hp);
    const total: u32 = kit.param_count + kit.policy_count;
    host.element_count = total;
    const buffer: []f32 = try owned.alloc(f32, total);
    kit.packWeights(world, buffer[0..kit.param_count]);
    kit.packPolicy(policy, buffer[kit.p_at..]);
    host.upload(.params, buffer);
    const world_before: []f32 = try owned.dupe(f32, buffer[0..kit.param_count]);
    // Gradients: non-zero in the world model's region too, as bait; the policy's in its own order.
    for (buffer[0..kit.param_count]) |*d| {
        d.* = random.floatNorm(f32);
    }
    kit.packPolicy(grads, buffer[kit.p_at..]);
    host.upload(.grads, buffer);
    @memset(buffer, 0.0);
    host.upload(.adam_m, buffer);
    host.upload(.adam_v, buffer);

    var moments: [7]Tensor = undefined;
    var velocities: [7]Tensor = undefined;
    for (&moments, &velocities, policy) |*m, *v, p| {
        m.* = try Tensor.alloc(owned, p.shape[0..p.rank]);
        v.* = try Tensor.alloc(owned, p.shape[0..p.rank]);
        @memset(m.data, 0.0);
        @memset(v.data, 0.0);
    }
    for (1..4) |t| {
        kit.adamPolicy(1.0e-3, @intCast(t), 1.0);
        for (policy, grads, moments, velocities) |p, g, m, v| {
            try zn.adamStep(f32, p, p, g, m, v, .{ .rate = 1.0e-3 }, t);
        }
    }
    const after: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
    try expect(eql(f32, world_before, after[0..kit.param_count]));
    const first_moment: []const f32 = host.readLatest(.adam_m) orelse return error.NoReadback;
    const second_moment: []const f32 = host.readLatest(.adam_v) orelse return error.NoReadback;
    for (first_moment[0..kit.param_count], second_moment[0..kit.param_count]) |m, v| {
        try expect(m == 0.0 and v == 0.0);
    }
    const expected: []f32 = try owned.alloc(f32, kit.policy_count);
    kit.packPolicy(policy, expected);
    var worst: f32 = 0.0;
    for (expected, after[kit.p_at..][0..kit.policy_count]) |cpu, gpu| {
        worst = @max(worst, @abs(cpu - gpu));
    }
    report.print("\n  policy Adam vs zimrnum, 3 steps, {d} weights: worst {e}; world model untouched\n", .{
        kit.policy_count,
        worst,
    });
    try expect(worst <= 1.0e-6);
}

/// The kit's noise, as a function the CPU learner can be handed: step seeds from the update, exactly
/// as the kit's `policyStep` mixes them.
fn hashedNoise(update: u32, step: u32, row: u32, action: u32) f32 {
    return zn_mlp.latNoise(zn_mlp.latStepSeed(update, step), row, action);
}

test "robot_latent_kit: the policy trained on gathered windows follows the CPU learner step for step" {
    // The whole resident policy update - gather, rollout with the policy acting, backward through the
    // fixed world model, Adam on the policy alone - against the CPU learner's own `trainPolicyOn`: the
    // same weights, normaliser and world model, the SAME windows and the SAME noise (the kit's hash,
    // handed to the learner), 30 updates, compared by the loss each sees before updating. The world
    // model is not trained here, so a mismatch in the policy cannot hide behind the world model's.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var setup: FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const f: u32 = setup.features;
    const a: u32 = setup.actions;
    const rows: u32 = 8;
    const steps: u32 = 8;
    const h: u32 = 32;
    const hp: u32 = 32;
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    var kit: LatentKit(zn_mlp) = try .init(&host, f, setup.references, a, h, rows, steps, f, hp);
    var resident: Resident(zn_mlp) = try .init(gpa, &host, fleet, kit.total, rows, 2);
    defer resident.deinit();
    host.element_count = @max(resident.end, @max(kit.dtotal, kit.param_count + kit.policy_count));
    resident.uploadTables(fleet);
    for (0..60) |_| {
        _ = fleet.step(setup.actions_buffer);
        resident.appendLatest(fleet);
    }
    const learner: *latent.Learner = try .init(gpa, fleet, .{
        .hidden = hp,
        .window = steps,
        .batch = rows,
        .noise = hashedNoise,
        .world = .{ .hidden = h, .steps = steps, .batch = rows },
    });
    defer learner.deinit();
    kit.sigma = learner.options.sigma;
    kit.w_action = learner.options.w_action;
    resident.uploadNormalizer(learner.world.norm);
    const weights: []f32 = try gpa.alloc(f32, kit.param_count + kit.policy_count);
    defer gpa.free(weights);
    kit.packWeights(learner.world.params, weights[0..kit.param_count]);
    kit.packPolicy(learner.params, weights[kit.p_at..]);
    host.upload(.params, weights);
    @memset(weights, 0.0);
    host.upload(.adam_m, weights);
    host.upload(.adam_v, weights);

    var rng: Random.DefaultPrng = .init(29);
    var windows: [rows]track.Replay.Window = undefined;
    var starts: [rows]Start = undefined;
    var worst: f32 = 0.0;
    var first: f32 = 0.0;
    var last: f32 = 0.0;
    for (1..31) |t| {
        for (&windows, &starts) |*window, *start| {
            window.* = fleet.replay.sampleWindow(rng.random(), steps) orelse return error.NoData;
            start.* = .{ .env = @intCast(window.env), .index = window.first };
        }
        // The kit's noise seed is the learner's update count before this update.
        kit.seed = learner.updates;
        const cpu: f32 = try learner.trainPolicyOn(&windows);
        resident.stageStarts(&starts, 0, steps);
        resident.gather(kit, 0);
        kit.forward();
        // The loss the kit is about to descend, as the learner defines it: distance from the goal,
        // plus the price times the mean squared raw action - both means over every step.
        const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
        const tracked: []const f32 = acts[kit.z_at..][0 .. steps * rows * f];
        const goals: []const f32 = acts[kit.g_at..][0 .. steps * rows * f];
        var tracking: f64 = 0.0;
        for (tracked, goals) |z, g| {
            tracking += @as(f64, z - g) * (z - g);
        }
        var price: f64 = 0.0;
        for (acts[kit.raw_at..][0 .. steps * rows * a]) |x| {
            price += @as(f64, x) * x;
        }
        const tracking_mean: f64 = tracking / float(steps * rows * f);
        const gpu_loss: f64 = tracking_mean + learner.options.w_action * price / float(steps * rows * a);
        const gpu: f32 = @floatCast(gpu_loss);
        kit.policyBackward();
        kit.adamPolicy(learner.options.rate, @intCast(t), float(steps));
        worst = @max(worst, @abs(gpu - cpu) / cpu);
        if (t == 1) {
            first = cpu;
        }
        last = cpu;
    }
    report.print("\n  policy on gathered windows, 30 updates: CPU loss {d:.4} -> {d:.4}, " ++
        "worst relative gap to the kit {e}\n", .{
        first,
        last,
        worst,
    });
    try expect(worst < 1.0e-3);
}

test "robot_latent_kit: two updates in one frame keep their own windows" {
    // What the start slots are for. In a frame every upload lands before any of the frame's work runs,
    // so two updates staging their windows to the same place would both gather the second one's. Staged
    // to their own slots - both uploads first, as a frame would - each gather finds its own.
    const gpa: Allocator = testing_allocator;
    var setup: FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const rows: u32 = 4;
    const steps: u32 = 4;
    const f: u32 = setup.features;
    const kit: LatentKit(zn_mlp) =
        try .init(&host, f, setup.references, setup.actions, 16, rows, steps, 0, 0);
    var resident: Resident(zn_mlp) = try .init(gpa, &host, fleet, kit.total, rows, 2);
    defer resident.deinit();
    host.element_count = resident.end;
    resident.uploadTables(fleet);
    for (0..40) |_| {
        _ = fleet.step(setup.actions_buffer);
        resident.appendLatest(fleet);
    }
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    resident.uploadNormalizer(.{ .mean = mean, .spread = spread });
    var rng: Random.DefaultPrng = .init(4);
    var first_batch: [rows]Start = undefined;
    var second_batch: [rows]Start = undefined;
    for (&first_batch, &second_batch) |*a, *b| {
        const one: track.Replay.Window = fleet.replay.sampleWindow(rng.random(), steps) orelse return error.NoData;
        const two: track.Replay.Window = fleet.replay.sampleWindow(rng.random(), steps) orelse return error.NoData;
        a.* = .{ .env = @intCast(one.env), .index = one.first };
        b.* = .{ .env = @intCast(two.env), .index = two.first };
    }
    // Both updates' starts staged first - a frame's uploads all land before its work.
    resident.stageStarts(&first_batch, 0, steps);
    resident.stageStarts(&second_batch, 1, steps);

    var state: track.State = try .init(gpa, fleet.m.nbody);
    defer state.deinit(gpa);
    var data: rbt.Data = try .init(gpa, fleet.m);
    defer data.deinit();
    const expected: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(expected);
    for ([_]u32{ 0, 1 }, [_][]const Start{ &first_batch, &second_batch }) |slot, batch| {
        resident.gather(kit, slot);
        const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
        for (batch, 0..) |start, row| {
            fleet.stateAt(start.env, start.index, &data, &state);
            track.local(state, fleet.root, expected);
            const staged: []const f32 = acts[kit.blockX(0) + row * kit.width ..][0..f];
            try expect(eql(f32, expected, staged));
        }
    }
}

/// The flow tests' small rollout: 8 features, 4 references, 3 actions, 2 rows, 3 steps, the goals in front; a world
/// model and a policy (8 hidden units) of random weights; and a flow actor (8 hidden units, 4 Euler steps) correcting
/// the policy in `synergy_count` synergies - fitted to random actions - from a noise of `noise_scale`. The host's copy
/// of every parameter and of the rollout's inputs is kept, so a test can upload them again and run the same rollout
/// another way. The kit's `flow_actor` is left unset: each test chooses whether the flow acts.
const FlowRollout = struct {
    const features: u32 = 8;
    const references: u32 = 4;
    const actions: u32 = 3;
    const hidden: u32 = 8;
    const policy_hidden: u32 = 8;
    const rows: u32 = 2;
    const steps: u32 = 3;

    kit: LatentKit(zn_mlp),
    actor: kit_mod.FlowActor(zn_mlp),
    flow: zrl.FlowPolicy(f32),
    /// The host's copy of every parameter - the world model's, the policy's, the flow's, the synergies - and of the
    /// rollout's inputs: every row's goal and reference, block 0's state, the goal blocks.
    params: []f32,
    zero_moments: []f32,
    staging: []f32,

    fn init(
        owned: Allocator,
        host: *compute_host.Compute(zn_mlp),
        seed: u64,
        synergy_count: u32,
        noise_scale: f32,
        flow_at_rest: bool,
        distillation_rows: u32,
        fpo_settings: kit_mod.FlowActor(zn_mlp).FpoSettings,
    ) !FlowRollout {
        var generator: Random.DefaultPrng = .init(seed);
        const random: Random = generator.random();
        const f: u32 = features;
        const world: [8]Tensor = try randomParams(owned, random, f, references, actions, hidden);
        var kit: LatentKit(zn_mlp) = try .init(host, f, references, actions, hidden, rows, steps, f, policy_hidden);
        kit.sigma = 0.3;
        kit.seed = 9;
        const flow_options: zrl.FlowPolicy(f32).Options = .{
            .euler_steps = 4,
            .noise_scale = noise_scale,
            .starts_at_zero_velocity = flow_at_rest,
        };
        const flow_hidden: []const usize = &.{8};
        const flow: zrl.FlowPolicy(f32) =
            try .init(owned, zn.Rng.init(@intCast(seed + 1)), 2 * f, synergy_count, flow_hidden, flow_options);
        var layout: kit_mlp.KitLayout = .{
            .acts_floats = kit.total,
            .params_floats = kit.p_at + kit.policy_count,
            .dacts_floats = kit.dtotal,
        };
        const actor: kit_mod.FlowActor(zn_mlp) = try .init(
            owned,
            &layout,
            flow.velocity,
            2 * f,
            actions,
            synergy_count,
            noise_scale,
            rows,
            steps,
            .{ .euler_steps = 4 },
            .{},
            distillation_rows,
            1,
            fpo_settings,
        );
        // A stats block after everything, as a learner keeps one (`kit_mod.DeviceStats`).
        kit.stats_at = layout.reserveParams(kit_mod.DeviceStats.floats);
        layout.requireFitsKit(zn_mlp);
        host.element_count = layout.largestBuffer();
        // Every parameter: the world model's, the policy's (random, scaled to its widths), the flow's, the synergies
        // (fitted to twenty random actions).
        const params: []f32 = try owned.alloc(f32, layout.params_floats);
        @memset(params, 0);
        kit.packWeights(world, params[0..kit.param_count]);
        for (params[kit.p_at..][0..kit.policy_count]) |*weight| {
            weight.* = 0.3 * random.floatNorm(f32);
        }
        actor.flow.network.writeParams(flow.velocity, params);
        var fitted_actions: [20 * actions]f32 = undefined;
        for (&fitted_actions) |*value| {
            value.* = random.floatNorm(f32);
        }
        const fitted: Tensor = try .fromSlice(&fitted_actions, &.{ 20, actions });
        const synergies: zrl.ActionSynergies(f32) = try .fit(owned, fitted, synergy_count);
        const synergies_at: u32 = actor.correction.synergies_at;
        @memcpy(params[synergies_at..][0 .. synergy_count * actions], synergies.directions.data);
        const zero_moments: []f32 = try owned.alloc(f32, layout.params_floats);
        @memset(zero_moments, 0);
        // The rollout's inputs.
        const staging: []f32 = try owned.alloc(f32, layout.acts_floats);
        @memset(staging, 0.0);
        for (0..steps + 1) |step| {
            const base: usize = kit.blockX(@intCast(step));
            for (0..rows) |row| {
                for (0..f + f + references) |c| {
                    const state_column: bool = c >= f and c < 2 * f;
                    if (step == 0 or !state_column) {
                        staging[base + row * kit.width + c] = random.floatNorm(f32);
                    }
                }
            }
            if (step > 0) {
                for (staging[kit.blockG(@intCast(step))..][0 .. rows * f]) |*goal_value| {
                    goal_value.* = random.floatNorm(f32);
                }
            }
        }
        const rollout: FlowRollout = .{
            .kit = kit,
            .actor = actor,
            .flow = flow,
            .params = params,
            .zero_moments = zero_moments,
            .staging = staging,
        };
        return rollout;
    }

    /// Every parameter, zero moments and the rollout's inputs onto `host` - the same start for every run.
    fn upload(rollout: FlowRollout, host: *compute_host.Compute(zn_mlp)) void {
        host.upload(.params, rollout.params);
        host.upload(.adam_m, rollout.zero_moments);
        host.upload(.adam_v, rollout.zero_moments);
        host.upload(.acts, rollout.staging);
    }

    /// Step k's action columns of every row, from `acts`.
    fn stepActions(
        rollout: FlowRollout,
        acts: []const f32,
        k: u32,
        row: usize,
    ) []const f32 {
        const kit: LatentKit(zn_mlp) = rollout.kit;
        const action_column: usize = kit.lead + kit.features + kit.references;
        return acts[kit.blockX(k) + row * kit.width + action_column ..][0..actions];
    }
};

test "robot_latent_kit: a flow corrects the policy - at rest it adds nothing, moving it adds its decoded choice" {
    // The flow tests' rollout (`FlowRollout`), its policy random, its flow correcting it in two synergies of the three
    // actions. A flow at rest with no noise adds nothing: every action and every rolled state is the policy's alone. A
    // flow that moves, from a noise of 0.3, adds at the first step exactly its coefficients decoded through the
    // synergies, B^T c - and those coefficients are zimrrl's sampler's for that step's condition and noise.
    const gpa: Allocator = testing_allocator;
    var arena: ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    var rollout: FlowRollout = try .init(owned, &host, 61, 2, 0, true, 0, .{});
    const kit: *LatentKit(zn_mlp) = &rollout.kit;
    // 1. The policy alone.
    rollout.upload(&host);
    kit.forward();
    const acts_alone: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    const policy_alone: []const f32 = try owned.dupe(f32, acts_alone[0..kit.total]);
    // 2. A flow at rest, no noise: nothing added.
    kit.flow_actor = rollout.actor;
    rollout.upload(&host);
    kit.forward();
    const acts_at_rest: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    for (0..FlowRollout.steps) |step| {
        for (0..FlowRollout.rows) |row| {
            const k: u32 = @intCast(step);
            const action_alone: []const f32 = rollout.stepActions(policy_alone, k, row);
            try expectEqualSlices(f32, action_alone, rollout.stepActions(acts_at_rest, k, row));
        }
        const state_start: usize = kit.blockZ(@intCast(step + 1));
        const states_alone: []const f32 = policy_alone[state_start..][0 .. FlowRollout.rows * FlowRollout.features];
        const states_at_rest: []const f32 = acts_at_rest[state_start..][0 .. FlowRollout.rows * FlowRollout.features];
        try expectEqualSlices(f32, states_alone, states_at_rest);
    }
    // 3. A moving flow, a noise of 0.3: at the first step, the policy's action plus B^T c.
    const noise_scale: f32 = 0.3;
    const moving_options: zrl.FlowPolicy(f32).Options = .{
        .euler_steps = 4,
        .noise_scale = noise_scale,
        .starts_at_zero_velocity = false,
    };
    const condition_width: usize = 2 * FlowRollout.features;
    const moving: zrl.FlowPolicy(f32) = try .init(owned, zn.Rng.init(77), condition_width, 2, &.{8}, moving_options);
    rollout.actor.flow.network.writeParams(moving.velocity, rollout.params);
    kit.flow_actor.?.correction.noise_scale = noise_scale;
    rollout.upload(&host);
    kit.forward();
    const acts_moving: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    // The flow's noise at step 0: its own stream (`LatentKit.flowNoiseSeed`).
    const flow_stream_seed: u32 = zn_mlp.latStepSeed(kit.seed, FlowRollout.steps + 3);
    const step_seed: u32 = zn_mlp.latStepSeed(flow_stream_seed, 0);
    var graph: zn.Graph(f32) = .init(owned);
    const parameters: []const zn.Var = try moving.velocity.bind(&graph, .frozen, owned);
    const conditions: zn.Tensor(f32) = try .alloc(owned, &.{ FlowRollout.rows, condition_width });
    const noise: zn.Tensor(f32) = try .alloc(owned, &.{ FlowRollout.rows, 2 });
    for (0..FlowRollout.rows) |row| {
        const wide_row: []const f32 = acts_moving[kit.blockX(0) + row * kit.width ..][0..condition_width];
        @memcpy(conditions.data[row * condition_width ..][0..condition_width], wide_row);
        for (0..2) |synergy| {
            noise.data[row * 2 + synergy] = noise_scale * zn_mlp.latNoise(step_seed, @intCast(row), @intCast(synergy));
        }
    }
    const sampled: zn.Var = try moving.sample(owned, &graph, parameters, conditions, noise);
    const coefficients: []const f32 = graph.valueOf(sampled).data;
    const synergies_at: u32 = rollout.actor.correction.synergies_at;
    const synergies: []const f32 = rollout.params[synergies_at..][0 .. 2 * FlowRollout.actions];
    for (0..FlowRollout.rows) |row| {
        const with_flow: []const f32 = rollout.stepActions(acts_moving, 0, row);
        const without_flow: []const f32 = rollout.stepActions(policy_alone, 0, row);
        for (0..FlowRollout.actions) |action| {
            var decoded: f32 = 0;
            for (0..2) |synergy| {
                decoded += coefficients[row * 2 + synergy] * synergies[synergy * FlowRollout.actions + action];
            }
            try expectApproxEqAbs(decoded, with_flow[action] - without_flow[action], 1e-5);
        }
    }
}

test "robot_latent_kit: the flow takes the policy's gradient projected onto its synergies, and the policy its own" {
    // The flow tests' rollout, its flow at rest with no noise - so it rolls exactly as the policy alone. The backward
    // then gives the policy the very weight gradients it gets alone, and keeps, for the flow, step 0's raw-action
    // gradient projected onto the synergies, B g. One train step - the flow given a noise of its own - then moves both
    // the policy's weights and the flow's.
    const gpa: Allocator = testing_allocator;
    var arena: ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    var rollout: FlowRollout = try .init(owned, &host, 71, 2, 0, true, 0, .{});
    const kit: *LatentKit(zn_mlp) = &rollout.kit;
    const action_count: usize = FlowRollout.actions;
    const rows: usize = FlowRollout.rows;
    // 1. The policy alone: its weight gradients, and step 0's raw-action gradient.
    rollout.upload(&host);
    kit.forward();
    kit.policyBackward();
    const grads_alone: []const f32 = host.readLatest(.grads) orelse return error.NoReadback;
    const policy_gradients_alone: []const f32 = try owned.dupe(f32, grads_alone[kit.p_at..][0..kit.policy_count]);
    const dacts_alone: []const f32 = host.readLatest(.dacts) orelse return error.NoReadback;
    const raw_gradient: []const f32 = try owned.dupe(f32, dacts_alone[kit.draw_at..][0 .. rows * action_count]);
    // 2. With the flow at rest: the same policy gradients; the flow's share projected.
    kit.flow_actor = rollout.actor;
    rollout.upload(&host);
    kit.forward();
    kit.policyBackward();
    const grads_with_flow: []const f32 = host.readLatest(.grads) orelse return error.NoReadback;
    try expectEqualSlices(f32, policy_gradients_alone, grads_with_flow[kit.p_at..][0..kit.policy_count]);
    const acts_with_flow: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    const trainer: kit_mlp.KitFlow(zn_mlp).Trainer = rollout.actor.learning.?.trainer;
    const kept: []const f32 = acts_with_flow[trainer.cost_gradients_at..][0 .. rows * 2];
    const synergies_at: u32 = rollout.actor.correction.synergies_at;
    const synergies: []const f32 = rollout.params[synergies_at..][0 .. 2 * action_count];
    for (0..rows) |row| {
        for (0..2) |synergy| {
            var projected: f32 = 0;
            for (0..action_count) |action| {
                projected += synergies[synergy * action_count + action] * raw_gradient[row * action_count + action];
            }
            try expectApproxEqAbs(projected, kept[row * 2 + synergy], 1e-6);
        }
    }
    // 3. One train step: both the policy and the flow move, finite. With a noise of its own - FlowDPG's step floor
    // is the noise's length, so a flow at rest with none would have nothing to step by.
    kit.flow_actor.?.correction.noise_scale = 0.3;
    rollout.upload(&host);
    kit.policyTrainStep(3e-4, 1);
    const params_after: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
    const network = rollout.actor.flow.network;
    var policy_moved: usize = 0;
    var flow_moved: usize = 0;
    const policy_before: []const f32 = rollout.params[kit.p_at..][0..kit.policy_count];
    for (policy_before, params_after[kit.p_at..][0..kit.policy_count]) |before, after| {
        try expect(after == after and @abs(after) < 1e6);
        policy_moved += @intFromBool(before != after);
    }
    const flow_before: []const f32 = rollout.params[network.paramsStart()..network.paramsEnd()];
    for (flow_before, params_after[network.paramsStart()..network.paramsEnd()]) |before, after| {
        try expect(after == after and @abs(after) < 1e6);
        flow_moved += @intFromBool(before != after);
    }
    try expect(policy_moved > 0 and flow_moved > 0);
}

test "robot_latent_kit: the tracking planner scores a plan as the CPU model rolls and charges it" {
    // `TrackingScorer` at the real sizes - 291 features, 70 references, 35 actions - 2 states x 3 candidates, 4
    // steps, its kit placed after a training kit whose weights it reads (uploaded once, through the training kit).
    // Every candidate's score must be minus the sum of its steps' costs, the CPU model rolling the same start through
    // its own step (`latent.stepWith`) with the same references and actions, each step charged the mean squared
    // distance from that step's goal (the barrier off, no critic: the scorer's tail adds nothing).
    const gpa: Allocator = testing_allocator;
    var arena: ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    const f: u32 = 291;
    const r: u32 = 70;
    const a: u32 = 35;
    const h: u32 = 32;
    var rng: Random.DefaultPrng = .init(91);
    const random: Random = rng.random();
    const world: [8]Tensor = try randomParams(owned, random, f, r, a, h);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    // A policy of zero weights - its raw action exactly 0 - corrected in the identity basis: each candidate's
    // correction is exactly its action, so the CPU model's rollout on the candidates is the reference.
    const training_kit: LatentKit(zn_mlp) = try .init(&host, f, r, a, h, 4, 8, f, 8);
    var layout: kit_mlp.KitLayout = .{
        .acts_floats = training_kit.total,
        .params_floats = training_kit.p_at + training_kit.policy_count,
        .dacts_floats = training_kit.dtotal,
    };
    const synergies_at: u32 = layout.reserveParams(a * a);
    const Scorer: type = kit_mod.TrackingScorer(zn_mlp);
    const states: u32 = 2;
    const candidates: u32 = 3;
    const horizon: u32 = 4;
    const scorer: Scorer = try .init(owned, &layout, training_kit, null, synergies_at, .{
        .states = states,
        .candidates = candidates,
        .horizon = horizon,
    });
    layout.requireFitsKit(zn_mlp);
    host.element_count = layout.largestBuffer();
    const params: []f32 = try owned.alloc(f32, layout.params_floats);
    @memset(params, 0);
    training_kit.packWeights(world, params[0..training_kit.param_count]);
    for (0..a) |action| {
        params[synergies_at + action * a + action] = 1;
    }
    host.upload(.params, params);
    // The plans: two start states, the references and goals of four steps, six candidates' actions.
    const rows: u32 = states * candidates;
    const start_states: []f32 = try owned.alloc(f32, states * f);
    const references: []f32 = try owned.alloc(f32, horizon * states * r);
    const goals: []f32 = try owned.alloc(f32, horizon * states * f);
    const actions: []f32 = try owned.alloc(f32, horizon * rows * a);
    for (start_states) |*value| {
        value.* = random.floatNorm(f32);
    }
    for (references) |*value| {
        value.* = random.floatNorm(f32);
    }
    for (goals) |*value| {
        value.* = random.floatNorm(f32);
    }
    for (actions) |*value| {
        value.* = 0.5 * random.floatNorm(f32);
    }
    const host_acts: []f32 = try owned.alloc(f32, layout.acts_floats);
    @memset(host_acts, 0);
    scorer.writeInputs(host_acts, start_states, references, goals, actions);
    host.upload(.acts, host_acts);
    scorer.score(&host);
    const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    const kit_scores: []const f32 = acts[scorer.scores_at..][0..rows];
    // The CPU model, candidate by candidate.
    const z: []f32 = try owned.alloc(f32, f);
    const hidden1: []f32 = try owned.alloc(f32, h);
    const hidden2: []f32 = try owned.alloc(f32, h);
    var largest_relative_gap: f32 = 0;
    for (0..rows) |row| {
        const state: usize = row / candidates;
        @memcpy(z, start_states[state * f ..][0..f]);
        var plan_cost: f32 = 0;
        for (0..horizon) |step| {
            const reference: []const f32 = references[(step * states + state) * r ..][0..r];
            const action: []const f32 = actions[(step * rows + row) * a ..][0..a];
            latent.stepWith(world, hidden1, hidden2, z, reference, action);
            const goal: []const f32 = goals[(step * states + state) * f ..][0..f];
            var square_sum: f32 = 0;
            for (z, goal) |state_value, goal_value| {
                square_sum += (state_value - goal_value) * (state_value - goal_value);
            }
            plan_cost += square_sum / float(f);
        }
        const expected_score: f32 = -plan_cost;
        const relative_gap: f32 = @abs(kit_scores[row] - expected_score) / @max(@abs(expected_score), 1e-6);
        largest_relative_gap = @max(largest_relative_gap, relative_gap);
    }
    report.print("\n  tracking planner's scores vs the CPU model, 6 plans of 4 steps: largest relative gap {e}\n", .{
        largest_relative_gap,
    });
    try expect(largest_relative_gap <= 1e-5);
}

/// The cost the tracking planner charges, by the CPU model: `plan` [horizon][actions] rolled from `start` through the
/// model's own step, each step's mean squared distance from its goal summed.
fn cpuPlanCost(
    world: [8]Tensor,
    hidden1: []f32,
    hidden2: []f32,
    z: []f32,
    start: []const f32,
    references: []const f32,
    goals: []const f32,
    plan: []const f32,
    horizon: usize,
) f32 {
    const features: usize = start.len;
    const reference_width: usize = references.len / horizon;
    const action_width: usize = plan.len / horizon;
    @memcpy(z, start);
    var plan_cost: f32 = 0;
    for (0..horizon) |step| {
        const reference: []const f32 = references[step * reference_width ..][0..reference_width];
        const action: []const f32 = plan[step * action_width ..][0..action_width];
        latent.stepWith(world, hidden1, hidden2, z, reference, action);
        var square_sum: f32 = 0;
        for (z, goals[step * features ..][0..features]) |state_value, goal_value| {
            square_sum += (state_value - goal_value) * (state_value - goal_value);
        }
        plan_cost += square_sum / float(features);
    }
    return plan_cost;
}

test "robot_latent_kit: the tracking planner finds a plan whose cost is known to be zero" {
    // A known best plan: a hidden plan a* of 3 steps, and goals set to the states the CPU model reaches by it - so a*
    // costs exactly zero, and any plan reaching other states more. The planner, cold, 10 rounds of 256 candidates,
    // 32 elites: the plan it settles on (its Gaussian's mean after the last round) must cost a small share of what
    // doing nothing costs, and its first action must lie near a*'s - both measured by the CPU model.
    const gpa: Allocator = testing_allocator;
    var arena: ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    const f: u32 = 8;
    const r: u32 = 4;
    const a: u32 = 3;
    const h: u32 = 16;
    const horizon: u32 = 3;
    var rng: Random.DefaultPrng = .init(101);
    const random: Random = rng.random();
    const world: [8]Tensor = try randomParams(owned, random, f, r, a, h);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const training_kit: LatentKit(zn_mlp) = try .init(&host, f, r, a, h, 2, horizon, f, 8);
    var layout: kit_mlp.KitLayout = .{
        .acts_floats = training_kit.total,
        .params_floats = training_kit.p_at + training_kit.policy_count,
        .dacts_floats = training_kit.dtotal,
    };
    const Planner: type = kit_mod.TrackingPlanner(zn_mlp);
    const planner: Planner = try .init(owned, &layout, training_kit, null, null, .{
        .states = 1,
        .candidates = 256,
        .horizon = horizon,
    }, .{
        .policy_candidates = 0,
        .elites = 32,
        .temperature = 0.5,
        .min_spread = 0.05,
        .max_spread = 1.0,
        .rounds = 10,
    });
    layout.requireFitsKit(zn_mlp);
    host.element_count = layout.largestBuffer();
    // The world model's weights; the policy's stay zero, so a candidate's correction is exactly its action.
    const params: []f32 = try owned.alloc(f32, layout.params_floats);
    @memset(params, 0);
    training_kit.packWeights(world, params[0..training_kit.param_count]);
    planner.writeOwnSynergies(params);
    host.upload(.params, params);
    // The hidden plan, the start, the references, and the goals the hidden plan reaches.
    const hidden_plan: []f32 = try owned.alloc(f32, horizon * a);
    for (hidden_plan) |*value| {
        value.* = random.float(f32) - 0.5;
    }
    const start: []f32 = try owned.alloc(f32, f);
    for (start) |*value| {
        value.* = random.floatNorm(f32);
    }
    const references: []f32 = try owned.alloc(f32, horizon * r);
    for (references) |*value| {
        value.* = random.floatNorm(f32);
    }
    const goals: []f32 = try owned.alloc(f32, horizon * f);
    const z: []f32 = try owned.alloc(f32, f);
    const hidden1: []f32 = try owned.alloc(f32, h);
    const hidden2: []f32 = try owned.alloc(f32, h);
    @memcpy(z, start);
    for (0..horizon) |step| {
        latent.stepWith(world, hidden1, hidden2, z, references[step * r ..][0..r], hidden_plan[step * a ..][0..a]);
        @memcpy(goals[step * f ..][0..f], z);
    }
    // The planner's inputs: the start, references and goals; the candidates' actions are the search's to write.
    const host_acts: []f32 = try owned.alloc(f32, layout.acts_floats);
    @memset(host_acts, 0);
    const no_actions: []f32 = try owned.alloc(f32, horizon * planner.scorer.rowCount() * a);
    @memset(no_actions, 0);
    planner.scorer.writeInputs(host_acts, start, references, goals, no_actions);
    host.upload(.acts, host_acts);
    planner.decide(&host, 5, 1);
    const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    const settled_plan: []const f32 = acts[planner.mppi.mean_offset..][0 .. horizon * a];
    const doing_nothing: []f32 = try owned.alloc(f32, horizon * a);
    @memset(doing_nothing, 0);
    const settled_cost: f32 = cpuPlanCost(world, hidden1, hidden2, z, start, references, goals, settled_plan, horizon);
    const nothing_cost: f32 = cpuPlanCost(world, hidden1, hidden2, z, start, references, goals, doing_nothing, horizon);
    const hidden_cost: f32 = cpuPlanCost(world, hidden1, hidden2, z, start, references, goals, hidden_plan, horizon);
    var first_action_gap: f32 = 0;
    for (settled_plan[0..a], hidden_plan[0..a]) |settled, hidden| {
        first_action_gap = @max(first_action_gap, @abs(settled - hidden));
    }
    report.print("\n  tracking planner, a plan known to cost 0 ({e}): settled on {e}, doing nothing {e}; " ++
        "first action within {d:.3} of the hidden plan's\n", .{
        hidden_cost,
        settled_cost,
        nothing_cost,
        first_action_gap,
    });
    try expect(hidden_cost < 1e-10);
    try expect(settled_cost < 0.05 * nothing_cost);
    try expect(first_action_gap < 0.15);
}

test "robot_latent_kit: the tracking planner keeps the flow's own plan when it is the best there is" {
    // A flow whose first layer ignores its goal inputs, so its plan depends only on the start, the references and its
    // noise - correcting a policy of zero weights in synergies that are the actions themselves, so a plan's action is
    // exactly the flow's choice - and the goals set to the states its first plan reaches, computed on the host (the
    // flow's host sampler from the plan's own noise stream, the CPU model's step). That plan costs exactly zero. The
    // planner - 2 flow plans and 62 sampled candidates, 6 rounds - must keep it: its candidate holds the host's plan
    // (placed, never resampled), its score is the best of the last round and about zero, and it is the first elite.
    const gpa: Allocator = testing_allocator;
    var arena: ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    const f: u32 = 8;
    const r: u32 = 4;
    const a: u32 = 3;
    const h: u32 = 16;
    const horizon: u32 = 3;
    const plan_noise: f32 = 0.3;
    var rng: Random.DefaultPrng = .init(111);
    const random: Random = rng.random();
    const world: [8]Tensor = try randomParams(owned, random, f, r, a, h);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const policy_hidden: u32 = 8;
    const training_kit: LatentKit(zn_mlp) = try .init(&host, f, r, a, h, 2, horizon, f, policy_hidden);
    var layout: kit_mlp.KitLayout = .{
        .acts_floats = training_kit.total,
        .params_floats = training_kit.p_at + training_kit.policy_count,
        .dacts_floats = training_kit.dtotal,
    };
    // The flow, its first layer blind to the goal: the first `f` rows of its weights are zero.
    const Flow: type = zrl.FlowPolicy(f32);
    const hidden: []const usize = &.{8};
    const flow_options: Flow.Options = .{ .starts_at_zero_velocity = false, .noise_scale = plan_noise };
    const flow: Flow = try .init(owned, zn.Rng.init(29), 2 * f, a, hidden, flow_options);
    const flow_tensors: []const Tensor = (try flow.velocity.params(owned)).tensors;
    const first_hidden: usize = hidden[0];
    @memset(flow_tensors[0].data[0 .. f * first_hidden], 0);
    const KitFlow: type = kit_mlp.KitFlow(zn_mlp);
    const flow_actor: kit_mod.FlowActor(zn_mlp) =
        try .init(owned, &layout, flow.velocity, 2 * f, a, a, plan_noise, 2, horizon, .{}, .{}, 0, 0, .{});
    const kit_flow: KitFlow = flow_actor.flow;
    const Planner: type = kit_mod.TrackingPlanner(zn_mlp);
    const search_rounds: u32 = 6;
    const planner: Planner = try .init(owned, &layout, training_kit, null, flow_actor, .{
        .states = 1,
        .candidates = 64,
        .horizon = horizon,
    }, .{
        .policy_candidates = 2,
        .elites = 8,
        .temperature = 0.5,
        .min_spread = 0.05,
        .max_spread = 1.0,
        .rounds = search_rounds,
    });
    layout.requireFitsKit(zn_mlp);
    host.element_count = layout.largestBuffer();
    const params: []f32 = try owned.alloc(f32, layout.params_floats);
    @memset(params, 0);
    training_kit.packWeights(world, params[0..training_kit.param_count]);
    kit_flow.network.writeParams(flow.velocity, params);
    // The synergies: the actions themselves (the policy's weights stay zero).
    const synergies_at: u32 = flow_actor.correction.synergies_at;
    for (0..a) |synergy| {
        params[synergies_at + synergy * a + synergy] = 1;
    }
    host.upload(.params, params);
    // The flow's first plan on the host - plan row 0, its noise the plans' own stream (`LatentKit.flowNoiseSeed`,
    // under the plans' seed) - and the goals: where it leads.
    const decision_seed: u32 = 5;
    const plan_seed: u32 = zn_mlp.latStepSeed(decision_seed, search_rounds + 1);
    const flow_stream_seed: u32 = zn_mlp.latStepSeed(plan_seed, horizon + 3);
    const start: []f32 = try owned.alloc(f32, f);
    for (start) |*value| {
        value.* = random.floatNorm(f32);
    }
    const references: []f32 = try owned.alloc(f32, horizon * r);
    for (references) |*value| {
        value.* = random.floatNorm(f32);
    }
    const goals: []f32 = try owned.alloc(f32, horizon * f);
    const host_plan: []f32 = try owned.alloc(f32, horizon * a);
    const z: []f32 = try owned.alloc(f32, f);
    const hidden1: []f32 = try owned.alloc(f32, h);
    const hidden2: []f32 = try owned.alloc(f32, h);
    const condition: []f32 = try owned.alloc(f32, 2 * f);
    const step_noise: []f32 = try owned.alloc(f32, a);
    const input_scratch: []f32 = try owned.alloc(f32, kit_flow.wideRowWidth());
    const layer_scratch: []f32 = try owned.alloc(f32, 2 * kit_flow.network.widestOutput());
    const velocity_scratch: []f32 = try owned.alloc(f32, a);
    @memcpy(z, start);
    for (0..horizon) |step| {
        const step_seed: u32 = zn_mlp.latStepSeed(flow_stream_seed, @intCast(step));
        for (step_noise, 0..) |*noise_value, dimension| {
            noise_value.* = plan_noise * zn_mlp.latNoise(step_seed, 0, @intCast(dimension));
        }
        // The goal columns are ignored by this flow; the state is where the plan has reached.
        @memset(condition[0..f], 0);
        @memcpy(condition[f..], z);
        const step_action: []f32 = host_plan[step * a ..][0..a];
        kit_flow.sampleHost(params, condition, step_noise, input_scratch, layer_scratch, velocity_scratch, step_action);
        latent.stepWith(world, hidden1, hidden2, z, references[step * r ..][0..r], step_action);
        @memcpy(goals[step * f ..][0..f], z);
    }
    const host_acts: []f32 = try owned.alloc(f32, layout.acts_floats);
    @memset(host_acts, 0);
    try planner.writeInputs(owned, host_acts, start, references, goals);
    host.upload(.acts, host_acts);
    planner.decide(&host, decision_seed, 1);
    const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    // The plan was placed - the first candidate holds it, step by step.
    const shape: bmpc_kit.SearchShape = planner.scorer.searchShape();
    for (0..horizon) |step| {
        const candidate_action: []const f32 = acts[shape.candidateActionAt(@intCast(step), 0)..][0..a];
        for (candidate_action, host_plan[step * a ..][0..a]) |kit_value, host_value| {
            try expectApproxEqAbs(host_value, kit_value, 1e-5);
        }
    }
    // It was kept: the best score of the last round, about zero - and the first elite.
    const scores: []const f32 = acts[shape.scores_at..][0..shape.candidates];
    for (scores) |score| {
        try expect(scores[0] >= score);
    }
    try expect(scores[0] > -1e-4);
    const first_elite: f32 = acts[planner.mppi.elites_offset];
    try expectEqual(@as(f32, 0), first_elite);
}

test "robot_latent_kit: the tracking planner gathers every candidate's inputs from the reference table" {
    // A planner of 2 states x 3 candidates over 3 steps, and a reference table of 6 rows written into acts with a
    // normaliser. State 0 starts at row 1, state 1 at row 4 - its rows run past its clip's last row, 5, and must hold
    // there. Every candidate row's start state, references, goals (in its goal columns and its goal blocks) must be
    // the host's, to the bit.
    const gpa: Allocator = testing_allocator;
    var arena: ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    const f: u32 = 5;
    const r: u32 = 3;
    const a: u32 = 2;
    const h: u32 = 8;
    const horizon: u32 = 3;
    const states: u32 = 2;
    const candidates: u32 = 3;
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const training_kit: LatentKit(zn_mlp) = try .init(&host, f, r, a, h, 2, horizon, f, 8);
    var layout: kit_mlp.KitLayout = .{
        .acts_floats = training_kit.total,
        .params_floats = training_kit.p_at + training_kit.policy_count,
        .dacts_floats = training_kit.dtotal,
    };
    const Planner: type = kit_mod.TrackingPlanner(zn_mlp);
    const planner: Planner = try .init(owned, &layout, training_kit, null, null, .{
        .states = states,
        .candidates = candidates,
        .horizon = horizon,
    }, .{ .policy_candidates = 0, .elites = 2, .rounds = 1 });
    const table_rows: u32 = 6;
    const table_width: u32 = f + r;
    const table_at: u32 = layout.reserveActs(table_rows * table_width);
    const normaliser_at: u32 = layout.reserveActs(2 * f);
    layout.requireFitsKit(zn_mlp);
    host.element_count = layout.largestBuffer();
    const host_acts: []f32 = try owned.alloc(f32, layout.acts_floats);
    @memset(host_acts, 0);
    for (0..table_rows * table_width) |index| {
        host_acts[table_at + index] = @sin(0.37 * float(index) + 0.2);
    }
    for (0..f) |column| {
        host_acts[normaliser_at + column] = 0.1 * float(column);
        host_acts[normaliser_at + f + column] = 0.5 + 0.1 * float(column);
    }
    const start_rows = [states]u32{ 1, 4 };
    const last_row: u32 = table_rows - 1;
    for (0..states) |state| {
        const inputs_at: usize = planner.stateInputsAt(@intCast(state));
        for (0..f) |column| {
            host_acts[inputs_at + column] = 0.3 * float(state + 1) - 0.05 * float(column);
        }
        host_acts[inputs_at + f] = @floatFromInt(start_rows[state]);
        host_acts[inputs_at + f + 1] = @floatFromInt(last_row);
    }
    host.upload(.acts, host_acts);
    planner.gather(&host, table_at, normaliser_at);
    const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    const kit: LatentKit(zn_mlp) = planner.scorer.kit;
    for (0..states * candidates) |row| {
        const state: usize = row / candidates;
        const inputs_at: usize = planner.stateInputsAt(@intCast(state));
        // The start state, in step 0's state columns.
        const start_columns: []const f32 = acts[kit.blockX(0) + row * kit.width + kit.lead ..][0..f];
        try expectEqualSlices(f32, host_acts[inputs_at..][0..f], start_columns);
        for (0..horizon) |step| {
            // The reference of step k: table row (start + k), held at the last row.
            const reference_row: usize = @min(start_rows[state] + step, last_row);
            const expected_reference: []const f32 = host_acts[table_at + reference_row * table_width + f ..][0..r];
            const wide_row_at: usize = kit.blockX(@intCast(step)) + row * kit.width;
            const reference_columns: []const f32 = acts[wide_row_at + kit.lead + f ..][0..r];
            try expectEqualSlices(f32, expected_reference, reference_columns);
            // The goal after step k: table row (start + k + 1), normalised - in the goal columns and goal block.
            const goal_row: usize = @min(start_rows[state] + step + 1, last_row);
            for (0..f) |column| {
                const raw_goal: f32 = host_acts[table_at + goal_row * table_width + column];
                const mean: f32 = host_acts[normaliser_at + column];
                const spread: f32 = host_acts[normaliser_at + f + column];
                const expected_goal: f32 = (raw_goal - mean) / spread;
                try expectEqual(expected_goal, acts[kit.blockX(@intCast(step)) + row * kit.width + column]);
                try expectEqual(expected_goal, acts[kit.blockG(@intCast(step + 1)) + row * f + column]);
            }
        }
    }
}

test "robot_latent_kit: teacher 2 adds its gradient - nothing at weight 0, bit for bit, and a step at weight 1" {
    // The flow tests' rollout (`FlowRollout`) with a distillation batch of 8 rows: one policy update from the same
    // state, three ways. With no batch, and with a batch at weight 0, the flow's weights come out the same to the bit -
    // teacher 2 at weight 0 changes nothing. With the batch at weight 1 they come out different, and finite.
    const gpa: Allocator = testing_allocator;
    var arena: ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const synergy_count: u32 = 2;
    const distillation_rows: u32 = 8;
    var rollout: FlowRollout = try .init(owned, &host, 131, synergy_count, 0.3, false, distillation_rows, .{});
    const kit: *LatentKit(zn_mlp) = &rollout.kit;
    kit.flow_actor = rollout.actor;
    // The batch, in the rollout's inputs: its conditions and the coefficients the plans chose.
    var generator: Random.DefaultPrng = .init(132);
    const random: Random = generator.random();
    const distillation: kit_mod.FlowActor(zn_mlp).Distillation = rollout.actor.learning.?.distillation.?;
    const condition_floats: usize = distillation_rows * 2 * FlowRollout.features;
    for (rollout.staging[distillation.conditions_at..][0..condition_floats]) |*value| {
        value.* = random.floatNorm(f32);
    }
    for (rollout.staging[distillation.trainer.actions_at..][0 .. distillation_rows * synergy_count]) |*value| {
        value.* = 0.5 * random.floatNorm(f32);
    }
    const network = rollout.actor.flow.network;
    const Case = struct { has_batch: bool, weight: f32 };
    const cases = [3]Case{
        .{ .has_batch = false, .weight = 1 },
        .{ .has_batch = true, .weight = 0 },
        .{ .has_batch = true, .weight = 1 },
    };
    var trained: [3][]f32 = undefined;
    for (cases, &trained) |case, *case_params| {
        rollout.upload(&host);
        kit.flow_actor.?.learning.?.distillation.?.has_batch = case.has_batch;
        kit.flow_actor.?.learning.?.distillation.?.weight = case.weight;
        kit.policyTrainStep(3e-4, 1);
        const read: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
        case_params.* = try owned.dupe(f32, read[network.paramsStart()..network.paramsEnd()]);
    }
    try expectEqualSlices(f32, trained[0], trained[1]);
    var moved: usize = 0;
    for (trained[0], trained[2]) |without, with| {
        try expect(with == with and @abs(with) < 1e6);
        moved += @intFromBool(without != with);
    }
    try expect(moved > 0);
}

test "robot_latent_kit: given corrections roll as a flow's - zero is the policy alone, a flow's are its rollout" {
    // The flow tests' rollout (`FlowRollout`), its flow moving, from a noise of 0.3. Given corrections of all zeros
    // roll exactly as the policy alone. The coefficients the flow chose, given back to the kit in the flow's place,
    // roll exactly as the flow's own rollout did - every activation, action and state, to the bit: a plan made of a
    // flow's corrections is scored as the very rollout the flow made.
    const gpa: Allocator = testing_allocator;
    var arena: ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const synergy_count: u32 = 2;
    var rollout: FlowRollout = try .init(owned, &host, 81, synergy_count, 0.3, false, 0, .{});
    const kit: *LatentKit(zn_mlp) = &rollout.kit;
    const coefficients_at: u32 = rollout.actor.coefficients_at;
    const coefficient_floats: usize = FlowRollout.steps * FlowRollout.rows * synergy_count;
    const given: kit_mod.GivenCorrections = .{
        .coefficients_at = coefficients_at,
        .synergies_at = rollout.actor.correction.synergies_at,
        .synergy_count = synergy_count,
    };
    // 1. The policy alone.
    rollout.upload(&host);
    kit.forward();
    const acts_alone: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    const policy_alone: []const f32 = try owned.dupe(f32, acts_alone[0..kit.total]);
    // 2. Given corrections of all zeros (the staged inputs hold zeros there).
    kit.given_corrections = given;
    rollout.upload(&host);
    kit.forward();
    const acts_zero: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    try expectEqualSlices(f32, policy_alone, acts_zero[0..kit.total]);
    // 3. The flow's own rollout, and the coefficients it chose.
    kit.given_corrections = null;
    kit.flow_actor = rollout.actor;
    rollout.upload(&host);
    kit.forward();
    const flow_acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    const flow_rollout: []const f32 = try owned.dupe(f32, flow_acts[0..kit.total]);
    const chosen: []const f32 = try owned.dupe(f32, flow_acts[coefficients_at..][0..coefficient_floats]);
    try expect(!eql(f32, flow_rollout, policy_alone));
    // 4. Those coefficients given back, the flow set aside: the same rollout.
    kit.flow_actor = null;
    kit.given_corrections = given;
    rollout.upload(&host);
    host.uploadAt(.acts, coefficients_at, chosen);
    kit.forward();
    const acts_given: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    try expectEqualSlices(f32, flow_rollout, acts_given[0..kit.total]);
}

test "robot_latent_kit: the scorer rolls the policy closed loop - a candidate of zeros scores as the policy itself" {
    // A scorer over a policy of random weights: two states, three candidates each, four steps. The first candidate of
    // each state is all zeros, the others random corrections. Scored with its candidates, then again with the
    // corrections set aside - the policy alone - the zero candidates' scores are the same to the bit, and the others'
    // are not: a candidate is a correction around the policy, and zero is the policy itself.
    const gpa: Allocator = testing_allocator;
    var arena: ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    const f: u32 = 8;
    const r: u32 = 4;
    const a: u32 = 3;
    const h: u32 = 16;
    const policy_hidden: u32 = 8;
    var rng: Random.DefaultPrng = .init(151);
    const random: Random = rng.random();
    const world: [8]Tensor = try randomParams(owned, random, f, r, a, h);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const training_kit: LatentKit(zn_mlp) = try .init(&host, f, r, a, h, 2, 4, f, policy_hidden);
    var layout: kit_mlp.KitLayout = .{
        .acts_floats = training_kit.total,
        .params_floats = training_kit.p_at + training_kit.policy_count,
        .dacts_floats = training_kit.dtotal,
    };
    const synergies_at: u32 = layout.reserveParams(a * a);
    const states: u32 = 2;
    const candidates: u32 = 3;
    const horizon: u32 = 4;
    var scorer: kit_mod.TrackingScorer(zn_mlp) = try .init(owned, &layout, training_kit, null, synergies_at, .{
        .states = states,
        .candidates = candidates,
        .horizon = horizon,
    });
    layout.requireFitsKit(zn_mlp);
    host.element_count = layout.largestBuffer();
    // The world model's weights, the policy's random, the identity basis.
    const params: []f32 = try owned.alloc(f32, layout.params_floats);
    @memset(params, 0);
    training_kit.packWeights(world, params[0..training_kit.param_count]);
    for (params[training_kit.p_at..][0..training_kit.policy_count]) |*weight| {
        weight.* = 0.3 * random.floatNorm(f32);
    }
    for (0..a) |action| {
        params[synergies_at + action * a + action] = 1;
    }
    host.upload(.params, params);
    // The inputs: starts, references, goals; the candidates - each state's first all zeros.
    const rows: u32 = states * candidates;
    const start_states: []f32 = try owned.alloc(f32, states * f);
    const references: []f32 = try owned.alloc(f32, horizon * states * r);
    const goals: []f32 = try owned.alloc(f32, horizon * states * f);
    const corrections: []f32 = try owned.alloc(f32, horizon * rows * a);
    for (start_states) |*value| {
        value.* = random.floatNorm(f32);
    }
    for (references) |*value| {
        value.* = random.floatNorm(f32);
    }
    for (goals) |*value| {
        value.* = random.floatNorm(f32);
    }
    for (0..horizon) |step| {
        for (0..rows) |row| {
            const is_zero_candidate: bool = row % candidates == 0;
            for (corrections[(step * rows + row) * a ..][0..a]) |*value| {
                value.* = if (is_zero_candidate) 0 else 0.5 * random.floatNorm(f32);
            }
        }
    }
    const host_acts: []f32 = try owned.alloc(f32, layout.acts_floats);
    @memset(host_acts, 0);
    scorer.writeInputs(host_acts, start_states, references, goals, corrections);
    // Scored with the candidates.
    host.upload(.acts, host_acts);
    scorer.score(&host);
    const with_candidates: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    const scores: []const f32 = try owned.dupe(f32, with_candidates[scorer.scores_at..][0..rows]);
    // Scored as the policy alone.
    scorer.kit.given_corrections = null;
    host.upload(.acts, host_acts);
    scorer.score(&host);
    const alone: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    const policy_scores: []const f32 = alone[scorer.scores_at..][0..rows];
    for (0..rows) |row| {
        if (row % candidates == 0) {
            try expectEqual(policy_scores[row], scores[row]);
        } else {
            try expect(policy_scores[row] != scores[row]);
        }
    }
}

test "robot_latent_kit: teacher 3's advantage - each example's parts where the critic reads them, then A" {
    // Three examples of random features and coefficients, a critic of two heads with random weights. The packed goals
    // must hold exactly each example's own goal, then its goal; the packed states its state, then its next state.
    // Each advantage must be -c - gamma x (the heads' mean where the step led) + (their mean where it started),
    // recomputed on the host from the device's own costs and head values - and those means must differ, so that a
    // step's start and where it led cannot be mixed up unseen.
    const gpa: Allocator = testing_allocator;
    var arena: ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    const f: u32 = 8;
    const synergy_count: u32 = 3;
    const batch_rows: u32 = 3;
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const kit: LatentKit(zn_mlp) = try .init(&host, f, 4, synergy_count, 8, 2, 3, f, 8);
    var layout: kit_mlp.KitLayout = .{
        .acts_floats = kit.total,
        .params_floats = kit.p_at + kit.policy_count,
        .dacts_floats = kit.dtotal,
    };
    const Critic: type = kit_mod.LatentCritic(zn_mlp);
    const source: Critic.Source = .{
        .features = f,
        .rows = 2,
        .steps = 3,
        .states_at = 0,
        .goals_at = 0,
        .norm_at = 0,
        .barrier = .{},
        .barrier_head_column = 0,
        .barrier_up_column = 0,
    };
    const critic_params_start: u32 = layout.params_floats;
    const critic: Critic = try .init(owned, &layout, source, .{ .heads = 2, .hidden = 8 });
    var fpo: kit_mod.FlowActor(zn_mlp).Fpo = .init(&layout, batch_rows, f, synergy_count);
    try fpo.reserveAdvantage(owned, &layout, critic);
    layout.requireFitsKit(zn_mlp);
    host.element_count = layout.largestBuffer();
    var generator: Random.DefaultPrng = .init(171);
    const random: Random = generator.random();
    // The critic's weights, random.
    const params: []f32 = try owned.alloc(f32, layout.params_floats);
    @memset(params, 0);
    critic.writeParams(params);
    for (params[critic_params_start..]) |*weight| {
        weight.* = 0.3 * random.floatNorm(f32);
    }
    host.upload(.params, params);
    // The batch: [own goal | goal | state | coefficients | next state], random.
    const example_width: u32 = 4 * f + synergy_count;
    const host_acts: []f32 = try owned.alloc(f32, layout.acts_floats);
    @memset(host_acts, 0);
    const examples: []f32 = host_acts[fpo.examples_at..][0 .. batch_rows * example_width];
    for (examples) |*value| {
        value.* = random.floatNorm(f32);
    }
    const staged: []const f32 = try owned.dupe(f32, examples);
    host.upload(.acts, host_acts);
    kit.fpoAdvantages(fpo);
    const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    const advantage: kit_mod.FlowActor(zn_mlp).Fpo.Advantage = fpo.advantage.?;
    // The parts, where the critic and the cost read them.
    const half_floats: usize = batch_rows * f;
    for (0..batch_rows) |row| {
        const example: []const f32 = staged[row * example_width ..][0..example_width];
        const goals: []const f32 = acts[advantage.goals_at..][0 .. 2 * half_floats];
        const states: []const f32 = acts[advantage.states_at..][0 .. 2 * half_floats];
        try expectEqualSlices(f32, example[0..f], goals[row * f ..][0..f]);
        try expectEqualSlices(f32, example[f..][0..f], goals[half_floats + row * f ..][0..f]);
        try expectEqualSlices(f32, example[2 * f ..][0..f], states[row * f ..][0..f]);
        try expectEqualSlices(f32, example[3 * f + synergy_count ..][0..f], states[half_floats + row * f ..][0..f]);
    }
    // A, from the device's own costs and head values.
    const heads: usize = advantage.heads;
    const costs: []const f32 = acts[advantage.costs_at..][0..batch_rows];
    const values: []const f32 = acts[advantage.values_at..][0 .. heads * 2 * batch_rows];
    const advantages: []const f32 = acts[advantage.advantages_at..][0..batch_rows];
    var means_differ: bool = false;
    for (0..batch_rows) |row| {
        var this_sum: f32 = 0;
        var next_sum: f32 = 0;
        for (0..heads) |head| {
            this_sum += values[head * 2 * batch_rows + row];
            next_sum += values[head * 2 * batch_rows + batch_rows + row];
        }
        const this_mean: f32 = this_sum / float(heads);
        const next_mean: f32 = next_sum / float(heads);
        means_differ = means_differ or this_mean != next_mean;
        const expected: f32 = -costs[row] - advantage.discount * next_mean + this_mean;
        try expectApproxEqAbs(expected, advantages[row], 1e-5 * @max(1, @abs(expected)));
    }
    try expect(means_differ);
}

test "robot_latent_kit: teacher 3 adds its gradient - nothing at weight 0, bit for bit, and a step at its weight" {
    // The flow tests' rollout (`FlowRollout`) with teacher 3's batch of three examples of two draws, staged by hand:
    // each example's condition and coefficients in its draws' rows, their noise and times, old losses, normalised
    // advantages of both signs - so whatever the ratios, some example is on the active side of the clip. One policy
    // update from the same state, three ways: no batch, the batch at weight 0, the batch at weight 0.5. The first two
    // leave the flow's weights the same to the bit; the third moves them, finite.
    const gpa: Allocator = testing_allocator;
    var arena: ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const synergy_count: u32 = 2;
    const fpo_settings: kit_mod.FlowActor(zn_mlp).FpoSettings = .{ .rows = 3, .draws = 2, .weight = 0 };
    var rollout: FlowRollout = try .init(owned, &host, 141, synergy_count, 0.3, false, 0, fpo_settings);
    const kit: *LatentKit(zn_mlp) = &rollout.kit;
    kit.flow_actor = rollout.actor;
    const fpo: kit_mod.FlowActor(zn_mlp).Fpo = rollout.actor.learning.?.fpo.?;
    const update: kit_mod.FlowActor(zn_mlp).Fpo.Update = fpo.update.?;
    const trainer = update.trainer;
    // The batch, in the rollout's inputs.
    var generator: Random.DefaultPrng = .init(142);
    const random: Random = generator.random();
    const condition_width: usize = 2 * FlowRollout.features;
    const wide_width: usize = rollout.actor.flow.wideRowWidth();
    for (0..fpo.rows) |example| {
        var condition: [2 * FlowRollout.features]f32 = undefined;
        for (&condition) |*value| {
            value.* = random.floatNorm(f32);
        }
        var coefficients: [synergy_count]f32 = undefined;
        for (&coefficients) |*value| {
            value.* = 0.5 * random.floatNorm(f32);
        }
        for (0..update.draws) |draw| {
            const row: usize = example * update.draws + draw;
            @memcpy(rollout.staging[trainer.wide_rows_at + row * wide_width ..][0..condition_width], &condition);
            @memcpy(rollout.staging[trainer.actions_at + row * synergy_count ..][0..synergy_count], &coefficients);
        }
    }
    for (rollout.staging[trainer.noise_at..][0 .. trainer.rows * synergy_count]) |*value| {
        value.* = 0.3 * random.floatNorm(f32);
    }
    for (rollout.staging[trainer.times_at..][0..trainer.rows]) |*value| {
        value.* = random.float(f32);
    }
    const old_losses = [3]f32{ 0.4, 0.9, 0.2 };
    const advantages = [3]f32{ 1.2, -0.8, 0.3 };
    @memcpy(rollout.staging[update.old_losses_at..][0..3], &old_losses);
    @memcpy(rollout.staging[update.advantages_at..][0..3], &advantages);
    const network = rollout.actor.flow.network;
    const Case = struct { has_batch: bool, weight: f32 };
    const cases = [3]Case{
        .{ .has_batch = false, .weight = 0.5 },
        .{ .has_batch = true, .weight = 0 },
        .{ .has_batch = true, .weight = 0.5 },
    };
    var trained: [3][]f32 = undefined;
    for (cases, &trained) |case, *case_params| {
        rollout.upload(&host);
        kit.flow_actor.?.learning.?.fpo.?.has_batch = case.has_batch;
        kit.flow_actor.?.learning.?.fpo.?.weight = case.weight;
        kit.policyTrainStep(3e-4, 1);
        const read: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
        case_params.* = try owned.dupe(f32, read[network.paramsStart()..network.paramsEnd()]);
    }
    try expectEqualSlices(f32, trained[0], trained[1]);
    var moved: usize = 0;
    for (trained[0], trained[2]) |without, with| {
        try expect(with == with and @abs(with) < 1e6);
        moved += @intFromBool(without != with);
    }
    try expect(moved > 0);
    // The policy's tracking term for the log, from the last update: the rollout's states against the goals, as the
    // host works it out from the same buffers.
    const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    const numbers: usize = kit.steps * kit.rows * kit.features;
    var difference_squares: f32 = 0;
    for (acts[kit.z_at..][0..numbers], acts[kit.g_at..][0..numbers]) |state, goal| {
        difference_squares += (state - goal) * (state - goal);
    }
    const params_now: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
    const tracking_slot: u32 = kit.stats_at.? + kit_mod.DeviceStats.slot("policy_tracking_loss");
    try expectEqual(difference_squares / float(numbers), params_now[tracking_slot]);
}

test "robot_track: the pushes' schedule - none before its start, rate and speeds growing, full after" {
    // A fleet whose pushes start at hour 1 and reach full strength at hour 3: 20 a second at full, speeds from 0.5 to
    // 2.0 m/s. The share is 0 before the start, 1/2 at hour 2, 1 from hour 3 - and 1 throughout with no schedule. Told
    // hour 0.5 the fleet pushes nobody; told hour 2 it pushes at about half the full rate, every push inside
    // [0.5, 1.25]; told hour 4 it pushes at the full rate, some faster than hour 2 allowed.
    const gpa: Allocator = testing_allocator;
    var setup: FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const no_schedule: track.Pushes = .{ .rate_per_second = 1 };
    try expectEqual(@as(f32, 1), no_schedule.scheduleShare(0));
    const speed_min: f32 = 0.5;
    const speed_max: f32 = 2.0;
    const pushes: track.Pushes = .{
        .rate_per_second = 20,
        .speed_min = speed_min,
        .speed_max = speed_max,
        .start_hours = 1,
        .full_hours = 3,
    };
    try expectEqual(@as(f32, 0), pushes.scheduleShare(0.5));
    try expectEqual(@as(f32, 0.5), pushes.scheduleShare(2));
    try expectEqual(@as(f32, 1), pushes.scheduleShare(4));
    setup.fleet.deinit();
    const m: *rbt.Model = &setup.imported.model;
    setup.fleet = try track.Fleet.init(gpa, m, &.{&setup.clip}, .{ .envs = 4, .capacity = 32, .pushes = pushes });
    const fleet: *track.Fleet = setup.fleet;
    const steps: usize = 200;
    // The full rate's expected count over the steps: rate x dt per step per character.
    const full_expected: f32 = 20 * fleet.m.opt.timestep * float(steps * 4);
    const hours_told = [3]f32{ 0.5, 2, 4 };
    var counts: [3]u64 = undefined;
    var fastest: [3]f32 = undefined;
    for (hours_told, &counts, &fastest) |hours, *count, *fastest_mean| {
        fleet.training_hours = hours;
        const top: f32 = speed_min + (speed_max - speed_min) * pushes.scheduleShare(hours);
        const pushes_before: u64 = fleet.pushes_given;
        fastest_mean.* = 0;
        for (0..steps) |_| {
            const step_pushes_before: u64 = fleet.pushes_given;
            const speeds_before: f64 = fleet.push_speed_sum;
            _ = fleet.step(setup.actions_buffer);
            const step_pushes: u64 = fleet.pushes_given - step_pushes_before;
            if (step_pushes == 0) {
                continue;
            }
            const mean_speed: f32 = @floatCast((fleet.push_speed_sum - speeds_before) / float64(step_pushes));
            try expect(mean_speed >= speed_min and mean_speed <= top + 1e-5);
            fastest_mean.* = @max(fastest_mean.*, mean_speed);
        }
        count.* = fleet.pushes_given - pushes_before;
    }
    try expectEqual(@as(u64, 0), counts[0]);
    const half_count: f32 = @floatFromInt(counts[1]);
    try expect(half_count > 0.25 * full_expected and half_count < 0.75 * full_expected);
    const full_count: f32 = @floatFromInt(counts[2]);
    try expect(full_count > 0.75 * full_expected and full_count < 1.25 * full_expected);
    try expect(fastest[2] > speed_min + 0.5 * (speed_max - speed_min));
}

test "robot_latent_kit: the world model's window inside a longer kit - its update is the short kit's, to the bit" {
    // Two kits on the same fleet's data: one 8 steps long; one 32 - the policy's horizon - with its world model's
    // window set to 8. From the same weights, on windows from the same starts - the long kit's first 8 steps are the
    // short kit's whole windows - one world model update each: the same loss, and the same weights after it, number
    // for number. The world model's update in the long kit is the short kit's; only the policy imagines further.
    const gpa: Allocator = testing_allocator;
    var setup: FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    // A replay long enough for 32-step windows.
    setup.fleet.deinit();
    setup.fleet = try track.Fleet.init(gpa, &setup.imported.model, &.{&setup.clip}, .{ .envs = 4, .capacity = 128 });
    const fleet: *track.Fleet = setup.fleet;
    const rows: u32 = 4;
    const hidden: u32 = 16;
    const world_window: u32 = 8;
    const horizon: u32 = 32;
    var host_short: compute_host.Compute(zn_mlp) = .initCpu();
    var host_long: compute_host.Compute(zn_mlp) = .initCpu();
    const f: u32 = setup.features;
    const kit_short: LatentKit(zn_mlp) =
        try .init(&host_short, f, setup.references, setup.actions, hidden, rows, world_window, f, 16);
    var kit_long: LatentKit(zn_mlp) =
        try .init(&host_long, f, setup.references, setup.actions, hidden, rows, horizon, f, 16);
    kit_long.world_steps = world_window;
    var resident_short: Resident(zn_mlp) = try .init(gpa, &host_short, fleet, kit_short.total, rows, 2);
    defer resident_short.deinit();
    var resident_long: Resident(zn_mlp) = try .init(gpa, &host_long, fleet, kit_long.total, rows, 2);
    defer resident_long.deinit();
    host_short.element_count = resident_short.end;
    host_long.element_count = resident_long.end;
    resident_short.uploadTables(fleet);
    resident_long.uploadTables(fleet);
    for (0..80) |_| {
        _ = fleet.step(setup.actions_buffer);
        resident_short.appendLatest(fleet);
        resident_long.appendLatest(fleet);
    }
    // The same normaliser and starting weights in both; Adam's moments zeroed.
    const world: *latent.LatentWorld = try .init(gpa, fleet, .{
        .hidden = hidden,
        .steps = world_window,
        .batch = rows,
    });
    defer world.deinit(gpa);
    resident_short.uploadNormalizer(world.norm);
    resident_long.uploadNormalizer(world.norm);
    try expectEqual(kit_short.param_count, kit_long.param_count);
    try expectEqual(kit_short.w1, kit_long.w1);
    const packed_weights: []f32 = try gpa.alloc(f32, kit_short.param_count);
    defer gpa.free(packed_weights);
    kit_short.packWeights(world.params, packed_weights);
    host_short.upload(.params, packed_weights);
    host_long.upload(.params, packed_weights);
    @memset(packed_weights, 0.0);
    host_short.upload(.adam_m, packed_weights);
    host_short.upload(.adam_v, packed_weights);
    host_long.upload(.adam_m, packed_weights);
    host_long.upload(.adam_v, packed_weights);
    // Windows long enough for the long kit, from the same starts in both.
    var generator: Random.DefaultPrng = .init(23);
    var starts: [rows]Start = undefined;
    for (&starts) |*start| {
        const window: track.Replay.Window = fleet.replay.sampleWindow(generator.random(), horizon) orelse
            return error.NoData;
        start.* = .{ .env = @intCast(window.env), .index = window.first };
    }
    resident_short.stageStarts(&starts, 0, world_window);
    resident_short.gather(kit_short, 0);
    resident_long.stageStarts(&starts, 0, horizon);
    resident_long.gather(kit_long, 0);
    kit_short.forwardRecorded();
    kit_long.forwardRecorded();
    kit_short.loss();
    kit_long.loss();
    const loss_short: f32 = (host_short.readLatest(.loss) orelse return error.NoReadback)[0];
    const loss_long: f32 = (host_long.readLatest(.loss) orelse return error.NoReadback)[0];
    try expectEqual(loss_short, loss_long);
    kit_short.backward();
    kit_long.backward();
    kit_short.adamStep(1.0e-3, 1, float(kit_short.world_steps));
    kit_long.adamStep(1.0e-3, 1, float(kit_long.world_steps));
    const weights_short: []const f32 = host_short.readLatest(.params) orelse return error.NoReadback;
    const weights_long: []const f32 = host_long.readLatest(.params) orelse return error.NoReadback;
    const world_range_end: usize = kit_short.w1 + kit_short.param_count;
    const short_range: []const f32 = weights_short[kit_short.w1..world_range_end];
    const long_range: []const f32 = weights_long[kit_long.w1..world_range_end];
    try expectEqualSlices(f32, short_range, long_range);
    // And the update moved them: the comparison is not of two untouched copies.
    var moved: usize = 0;
    for (weights_short[kit_short.w1..world_range_end]) |weight| {
        moved += @intFromBool(weight != 0);
    }
    try expect(moved > 0);
}

test "robot_latent_kit: the policy's clipped optimiser with nothing to bound - the plain Adam's weights, to the bit" {
    // Two kits on the same fleet's data, from the same weights, on windows from the same starts: one steps its policy
    // with the kit's own Adam; the other through the clipped optimiser with the learner's default settings - no
    // length bound (the largest float, so the factor is exactly 1), no element bound, Adam's 0.999. After one policy
    // update, every policy weight the same: the clipped path is the plain one when it bounds nothing.
    const gpa: Allocator = testing_allocator;
    var setup: FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const rows: u32 = 4;
    const hidden: u32 = 16;
    const steps: u32 = 8;
    var host_plain: compute_host.Compute(zn_mlp) = .initCpu();
    var host_clipped: compute_host.Compute(zn_mlp) = .initCpu();
    const f: u32 = setup.features;
    const kit_plain: LatentKit(zn_mlp) =
        try .init(&host_plain, f, setup.references, setup.actions, hidden, rows, steps, f, 16);
    var kit_clipped: LatentKit(zn_mlp) =
        try .init(&host_clipped, f, setup.references, setup.actions, hidden, rows, steps, f, 16);
    var resident_plain: Resident(zn_mlp) = try .init(gpa, &host_plain, fleet, kit_plain.total, rows, 2);
    defer resident_plain.deinit();
    var resident_clipped: Resident(zn_mlp) = try .init(gpa, &host_clipped, fleet, kit_clipped.total, rows, 2);
    defer resident_clipped.deinit();
    var layout: kit_mlp.KitLayout = .{
        .acts_floats = resident_clipped.end,
        .params_floats = kit_clipped.p_at + kit_clipped.policy_count,
        .dacts_floats = kit_clipped.dtotal,
    };
    kit_clipped.policy_optimizer = kit_mlp.ClippedAdam.reserve(&layout, kit_clipped.p_at, kit_clipped.policy_count);
    kit_clipped.policy_optimizer_settings = .{
        .gradient_clip = zm.floatMax(f32),
        .element_clip = 0,
        .beta1 = LatentKit(zn_mlp).beta1,
        .beta2 = 0.999,
    };
    layout.requireFitsKit(zn_mlp);
    host_plain.element_count = resident_plain.end;
    host_clipped.element_count = resident_clipped.end;
    resident_plain.uploadTables(fleet);
    resident_clipped.uploadTables(fleet);
    for (0..24) |_| {
        _ = fleet.step(setup.actions_buffer);
        resident_plain.appendLatest(fleet);
        resident_clipped.appendLatest(fleet);
    }
    const world: *latent.LatentWorld = try .init(gpa, fleet, .{ .hidden = hidden, .steps = steps, .batch = rows });
    defer world.deinit(gpa);
    resident_plain.uploadNormalizer(world.norm);
    resident_clipped.uploadNormalizer(world.norm);
    // The same weights in both: the world model's, and a policy's from a fixed stream.
    const all_weights: []f32 = try gpa.alloc(f32, kit_plain.p_at + kit_plain.policy_count);
    defer gpa.free(all_weights);
    @memset(all_weights, 0);
    kit_plain.packWeights(world.params, all_weights[0..kit_plain.param_count]);
    var generator: Random.DefaultPrng = .init(41);
    for (all_weights[kit_plain.p_at..]) |*weight| {
        weight.* = 0.1 * generator.random().floatNorm(f32);
    }
    host_plain.upload(.params, all_weights);
    host_clipped.upload(.params, all_weights);
    const zero_moments: []f32 = try gpa.alloc(f32, all_weights.len);
    defer gpa.free(zero_moments);
    @memset(zero_moments, 0);
    host_plain.upload(.adam_m, zero_moments);
    host_plain.upload(.adam_v, zero_moments);
    host_clipped.upload(.adam_m, zero_moments);
    host_clipped.upload(.adam_v, zero_moments);
    var starts: [rows]Start = undefined;
    for (&starts) |*start| {
        const window: track.Replay.Window = fleet.replay.sampleWindow(generator.random(), steps) orelse
            return error.NoData;
        start.* = .{ .env = @intCast(window.env), .index = window.first };
    }
    resident_plain.stageStarts(&starts, 0, steps);
    resident_plain.gather(kit_plain, 0);
    resident_clipped.stageStarts(&starts, 0, steps);
    resident_clipped.gather(kit_clipped, 0);
    kit_plain.policyTrainStep(3.0e-4, 1);
    kit_clipped.policyTrainStep(3.0e-4, 1);
    const plain_params: []const f32 = host_plain.readLatest(.params) orelse return error.NoReadback;
    const clipped_params: []const f32 = host_clipped.readLatest(.params) orelse return error.NoReadback;
    const policy_end: usize = kit_plain.p_at + kit_plain.policy_count;
    try expectEqualSlices(f32, plain_params[kit_plain.p_at..policy_end], clipped_params[kit_clipped.p_at..policy_end]);
    var moved: usize = 0;
    for (plain_params[kit_plain.p_at..policy_end], all_weights[kit_plain.p_at..]) |after, before| {
        moved += @intFromBool(after != before);
    }
    try expect(moved > 0);
}

test "robot_track: the reset curriculum - starts drawn toward failing bins as its mixture says, the old draws without" {
    // The get-up pages' 5 s clip in bins of a second, at 60 Hz. One bin losing its reference once a second (a rate of
    // 1/60 per step), the others never: of 20,000 starts the uniform half lands in it 60 / 298 of the time, the hard
    // draws e^5 / (e^5 + 4) = 0.974 of theirs, and the long-run draws - weights accumulated from the hard draws'
    // shares, so the same shape - 0.974 of theirs: 0.5 x 0.201 + 0.4 x 0.974 + 0.1 x 0.974 = 0.588; each other bin
    // about a quarter of the rest. On the absolute scale, bins that differ by noise weigh nearly the same: the others
    // losing it once in a hundred seconds changes the share by under a hundredth. Without a curriculum the starts are
    // the old ones, draw for draw. And stepping a falling fleet gives its visited bins running failure rates, every
    // one within [0, 1].
    const gpa: Allocator = testing_allocator;
    var setup: FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const m: *rbt.Model = &setup.imported.model;
    // Without a curriculum: the old draw, one from the fleet's stream.
    const plain_fleet: *track.Fleet = setup.fleet;
    var same_stream: Random.DefaultPrng = .init(plain_fleet.options.seed);
    // The fleet's own stream has already drawn its first starts; follow it from here on both sides.
    same_stream.s = plain_fleet.rng.s;
    for (0..50) |_| {
        const expected: usize = 1 + same_stream.random().uintLessThan(usize, setup.clip.frame_count - 2);
        try expectEqual(expected, plain_fleet.drawStartFrame(0));
    }
    // With one.
    setup.fleet.deinit();
    setup.fleet = try track.Fleet.init(gpa, m, &.{&setup.clip}, .{
        .envs = 4,
        .capacity = 32,
        .curriculum = .{ .bin_seconds = 1.0 },
    });
    const fleet: *track.Fleet = setup.fleet;
    try expectEqual(@as(usize, 2), fleet.bins_start.len);
    const bin_count: usize = fleet.bins_start[1];
    try expectEqual(@as(usize, 5), bin_count);
    const frames_per_bin: usize = 60;
    @memset(fleet.bin_failure_rates, 0);
    @memset(fleet.bin_history_weights, 0);
    fleet.bin_failure_rates[2] = 1.0 / 60.0;
    var counts: [5]u32 = @splat(0);
    const draws: u32 = 20000;
    for (0..draws) |_| {
        const frame: usize = fleet.drawStartFrame(0);
        counts[@min(frame / frames_per_bin, 4)] += 1;
    }
    const hard_bin_share: f32 = float(counts[2]) / float(draws);
    try expectApproxEqAbs(@as(f32, 0.588), hard_bin_share, 0.02);
    for (counts, 0..) |count, bin| {
        if (bin == 2) {
            continue;
        }
        try expectApproxEqAbs((1 - 0.588) / 4.0, float(count) / float(draws), 0.02);
    }
    // Stepping a fleet that falls: the visited bins' rates, within [0, 1], some above 0.
    @memset(fleet.bin_failure_rates, 0);
    for (0..300) |_| {
        _ = fleet.step(setup.actions_buffer);
    }
    var failing_bins: usize = 0;
    for (fleet.bin_failure_rates) |rate| {
        try expect(rate >= 0 and rate <= 1);
        failing_bins += @intFromBool(rate > 0);
    }
    try expect(failing_bins > 0);
}

test "robot_track: the physics on four threads - the same characters as on one, to the bit" {
    // Two fleets of eight characters on the same clip and seed, stepped with the same random actions: one steps every
    // character's physics in one loop, the other in four tasks on a pool of threads. Every random draw stays on the
    // calling thread in the characters' order, and a character's step touches only its own data, world and bridge
    // and its task's scratch - so after 120 steps, restarts among them, every character's position and velocity and
    // every episode's end are the same in both, to the bit.
    const gpa: Allocator = testing_allocator;
    var setup: FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const m: *rbt.Model = &setup.imported.model;
    setup.fleet.deinit();
    setup.fleet = try track.Fleet.init(gpa, m, &.{&setup.clip}, .{ .envs = 8, .capacity = 32 });
    const one_thread: *track.Fleet = setup.fleet;
    const four_threads: *track.Fleet = try track.Fleet.init(gpa, m, &.{&setup.clip}, .{
        .envs = 8,
        .capacity = 32,
        .physics_threads = 4,
    });
    defer four_threads.deinit();
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    four_threads.physics_io = threaded.io();
    const action_count: usize = track.actionSize(m) * 8;
    const actions: []f32 = try gpa.alloc(f32, action_count);
    defer gpa.free(actions);
    var generator: Random.DefaultPrng = .init(77);
    var restarts: usize = 0;
    // And what makes the threads safe, checked on any machine: no step allocates from the fleet's shared arena, which
    // is not safe on two threads - each character's world, data and bridge allocate from an arena of their own.
    const shared_capacity_before: usize = four_threads.arena.queryCapacity();
    for (0..120) |_| {
        for (actions) |*action| {
            action.* = generator.random().float(f32) * 2 - 1;
        }
        _ = one_thread.step(actions);
        _ = four_threads.step(actions);
        for (0..8) |env| {
            try expectEqualSlices(f32, one_thread.data[env].pos, four_threads.data[env].pos);
            try expectEqualSlices(f32, one_thread.data[env].vel, four_threads.data[env].vel);
            try expectEqual(one_thread.dones[env], four_threads.dones[env]);
            try expectEqual(one_thread.failures[env], four_threads.failures[env]);
            restarts += @intFromBool(one_thread.dones[env]);
        }
    }
    try expect(restarts > 0);
    try expectEqual(shared_capacity_before, four_threads.arena.queryCapacity());
}

test "robot_track: a return - back on the reference, the episode goes on; never back, it ends with its aftermath" {
    // Two characters tracking with the servo, an aftermath of 60 steps and returns after 8 steps holding the
    // reference again. Both roots are moved a metre sideways - past the failure rule's 0.6 m - and both lose the
    // reference: two failures, two aftermaths, no episode ended. Then, before each step, character 0 is put back on its
    // reference: it holds it 8 steps in a row and has RETURNED - its episode goes on, the fleet counts one return of 8
    // steps. Character 1 is moved a metre off before each step: it never returns, and its episode ends on the step its
    // aftermath runs out, with no second failure counted.
    const gpa: Allocator = testing_allocator;
    var setup: FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    setup.fleet.deinit();
    const m: *rbt.Model = &setup.imported.model;
    const aftermath_steps: u32 = 60;
    const return_steps: u32 = 8;
    setup.fleet = try track.Fleet.init(gpa, m, &.{&setup.clip}, .{
        .envs = 2,
        .capacity = 64,
        .max_steps = 10_000,
        .aftermath_steps = aftermath_steps,
        .return_steps = return_steps,
    });
    const fleet: *track.Fleet = setup.fleet;
    const actions: []f32 = setup.actions_buffer[0 .. track.actionSize(m) * 2];
    @memset(actions, 0);
    for (0..4) |_| {
        _ = fleet.step(actions);
    }
    try expect(!fleet.failures[0] and !fleet.failures[1]);
    const root_len: usize = setup.clip.nq - m.nq;
    // Both off by a metre: lost.
    for (0..2) |env| {
        fleet.data[env].pos[0] += 1.0;
        fleet.data[env].stage = .stale;
    }
    _ = fleet.step(actions);
    try expect(fleet.failures[0] and fleet.failures[1]);
    try expect(!fleet.dones[0] and !fleet.dones[1]);
    var returned_at: ?u32 = null;
    var ended_at: ?u32 = null;
    var step_after_loss: u32 = 1;
    while (step_after_loss <= aftermath_steps) : (step_after_loss += 1) {
        // Character 0 onto its reference (until it has returned), character 1 a metre off it.
        const frame_of_0: usize = fleet.frame[0];
        if (returned_at == null) {
            @memcpy(fleet.data[0].pos, setup.clip.pose(frame_of_0)[root_len..]);
            @memset(fleet.data[0].vel, 0);
            fleet.data[0].stage = .stale;
        }
        const frame_of_1: usize = fleet.frame[1];
        @memcpy(fleet.data[1].pos, setup.clip.pose(frame_of_1)[root_len..]);
        fleet.data[1].pos[0] += 1.0;
        @memset(fleet.data[1].vel, 0);
        fleet.data[1].stage = .stale;
        _ = fleet.step(actions);
        try expect(!fleet.failures[0] and !fleet.failures[1]);
        if (fleet.returned[0]) {
            try expect(returned_at == null);
            returned_at = step_after_loss;
            try expect(!fleet.dones[0]);
        }
        try expect(!fleet.returned[1]);
        if (fleet.dones[1]) {
            ended_at = step_after_loss;
            break;
        }
    }
    try expectEqual(@as(?u32, return_steps), returned_at);
    try expectEqual(@as(?u32, aftermath_steps), ended_at);
    try expectEqual(@as(u64, 1), fleet.returns);
    try expectEqual(@as(u64, return_steps), fleet.return_steps_sum);
}

test "robot_track: windows inside returns, and starts in trouble" {
    // A fleet of falling characters (no actions) with an aftermath: windows drawn `after_loss` all start on a record
    // after a loss, those drawn `before_loss` never do. Then STARTS IN TROUBLE: with every start pushed and no
    // schedule, each of the fleet's first starts is pushed; with a schedule that has not begun, none is.
    const gpa: Allocator = testing_allocator;
    var setup: FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    setup.fleet.deinit();
    const m: *rbt.Model = &setup.imported.model;
    setup.fleet = try track.Fleet.init(gpa, m, &.{&setup.clip}, .{
        .envs = 4,
        .capacity = 256,
        .aftermath_steps = 40,
        .return_steps = 8,
    });
    const fleet: *track.Fleet = setup.fleet;
    for (0..240) |_| {
        _ = fleet.step(setup.actions_buffer);
    }
    var generator: Random.DefaultPrng = .init(11);
    var after_loss_drawn: usize = 0;
    for (0..64) |_| {
        if (fleet.replay.sampleWindowStarting(generator.random(), 8, .after_loss)) |window| {
            try expect(fleet.replay.afterLossAt(window.env, window.first));
            after_loss_drawn += 1;
        }
        if (fleet.replay.sampleWindowStarting(generator.random(), 8, .before_loss)) |window| {
            try expect(!fleet.replay.afterLossAt(window.env, window.first));
        }
    }
    try expect(after_loss_drawn > 0);
    // Starts in trouble: every start pushed, no schedule - the fleet's four first starts are four pushes.
    const in_trouble: *track.Fleet = try track.Fleet.init(gpa, m, &.{&setup.clip}, .{
        .envs = 4,
        .capacity = 32,
        .pushes = .{ .speed_min = 0.5, .speed_max = 2.0, .start_share = 1 },
    });
    defer in_trouble.deinit();
    try expectEqual(@as(u64, 4), in_trouble.pushes_given);
    try expectApproxEqAbs(@as(f64, 4 * 2.0), in_trouble.push_speed_sum, 1e-6);
    // A schedule that begins at hour 1, the fleet told nothing (hour 0): no start in trouble.
    const not_yet: *track.Fleet = try track.Fleet.init(gpa, m, &.{&setup.clip}, .{
        .envs = 4,
        .capacity = 32,
        .pushes = .{ .speed_min = 0.5, .speed_max = 2.0, .start_share = 1, .start_hours = 1, .full_hours = 3 },
    });
    defer not_yet.deinit();
    try expectEqual(@as(u64, 0), not_yet.pushes_given);
}
