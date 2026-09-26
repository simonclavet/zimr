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
const zm = @import("zm");
const rbt = @import("robot.zig");
const track = @import("robot_track.zig");
const dance = @import("robot_dance.zig");
const latent = @import("robot_latent.zig");
const compute_host = @import("compute_host.zig");
const kit_mod = @import("robot_latent_kit.zig");
const zn_mlp = @import("gpu/zn_mlp.zig");

const Allocator = std.mem.Allocator;
const Tensor = zn.Tensor(f32);
const Graph = zn.Graph(f32);
const Var = zn.Var;
const float = zm.float;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const LatentKit = kit_mod.LatentKit;
const Resident = kit_mod.Resident;
const Start = kit_mod.Start;

test "robot_latent_kit: the kit's rollout matches the CPU model's own step" {
    // The CPU model's step (`robot_st.stepWith`, the very code it trains with) against the kit's
    // rollout, same weights, same inputs, the real feature sizes, 8 steps - each step feeding the
    // next, so a wrong offset anywhere compounds rather than hides.
    const gpa: Allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    const f: u32 = 291;
    const r: u32 = 70;
    const a: u32 = 35;
    const h: u32 = 32;
    const rows: u32 = 4;
    const steps: u32 = 8;
    var rng: std.Random.DefaultPrng = .init(11);
    const random: std.Random = rng.random();

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

test "robot_latent_kit: every gradient of the rollout matches zimrnum's autodiff" {
    try gradientsMatch(0);
}

test "robot_latent_kit: and with goal columns in front, where the two widths differ" {
    // With a lead the row's stride and the world model's input width differ, and the backward
    // pass's input-gradient block is laid out by the narrower one - the mix-up that lead 0 (where
    // they are equal) cannot catch.
    try gradientsMatch(291);
}

/// The kit's backward pass against zimrnum's graph of the CPU model, for rows with `lead` columns
/// in front of the world model's slice.
fn gradientsMatch(lead: u32) !void {
    // The kit's backward pass against zimrnum's graph of the CPU model - built from the model's own
    // `step`, with its own loss (the mean over steps of each step's MSE). The kit's loss is the SUM,
    // so kit = steps x CPU, weight for weight: the factor is part of what is checked, not waved off.
    const gpa: Allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    const f: u32 = 291;
    const r: u32 = 70;
    const a: u32 = 35;
    const h: u32 = 32;
    const rows: u32 = 4;
    const steps: u32 = 8;
    var rng: std.Random.DefaultPrng = .init(23);
    const random: std.Random = rng.random();
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
    const ones_t: Tensor = try Tensor.alloc(owned, &.{ rows, 1 });
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

/// The model's eight parameter tensors, random at a sensible scale - in `packWeights`' order: the
/// first layer's three blocks (features, reference, action) and its bias, then layers two and three.
fn randomParams(
    owned: Allocator,
    random: std.Random,
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
fn stageInputs(kit: anytype, staging: []f32, random: std.Random) void {
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
    const t: Tensor = try Tensor.alloc(owned, &.{ rows, count });
    for (0..rows) |row| {
        @memcpy(t.data[row * count ..][0..count], source[base + row * stride + first ..][0..count]);
    }
    return t;
}

test "robot_latent_kit: every region is checked against its own buffer - the phone fits, four times it does not" {
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    // The plan's phone configuration - 32 rows, width 256, 8 steps, ~470k floats of activations -
    // fits the enlarged activation buffer.
    const phone: LatentKit(zn_mlp) = try .init(&host, 291, 70, 35, 256, 32, 8, 0, 0);
    try expect(phone.total <= zn_mlp.acts_len);
    // Four times the rows overflows it (~1.9M of activations is fine, but its gradients - dZ for
    // every step - are past the gradient buffer's 262k), and is refused by name.
    const too_big = LatentKit(zn_mlp).init(&host, 291, 70, 35, 256, 128, 8, 0, 0);
    try expectError(error.KitTooSmall, too_big);
}

test "robot_latent_kit: Adam on the kit takes the CPU model's step" {
    // The optimiser alone: the kit and the CPU model's AdamSet given IDENTICAL gradients (the real
    // gradients of the rollout's loss, from zimrnum) for three steps, so the moments and the bias
    // corrections at t = 1, 2, 3 are all exercised. Identical gradients because the gradients are
    // already checked, and because rounding-level differences in them can flip the SIGN of Adam's
    // first step for a weight whose gradient is near zero - which would test the gradients again,
    // badly, rather than the optimiser.
    const gpa: Allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    const f: u32 = 291;
    const r: u32 = 70;
    const a: u32 = 35;
    const h: u32 = 32;
    const rows: u32 = 4;
    const steps: u32 = 4;
    var rng: std.Random.DefaultPrng = .init(31);
    const random: std.Random = rng.random();
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
    const ones_t: Tensor = try Tensor.alloc(owned, &.{ rows, 1 });
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

fn randomTensor(owned: Allocator, random: std.Random, rows: u32, cols: u32) !Tensor {
    const t: Tensor = try Tensor.alloc(owned, &.{ rows, cols });
    for (t.data) |*x| {
        x.* = random.floatNorm(f32);
    }
    return t;
}

test "robot_latent_kit: the resident tables and ring hold exactly what the CPU would compute" {
    // A real fleet on the baked get-up clip (no retargeting: fast), stepped 40 times with the ring
    // appended after every step; then the kit's buffer read back and held against features computed
    // independently, by the same functions, for records and frames across the live range. BITWISE:
    // the same code on the same numbers - what this checks is the ADDRESSING (slots, rows, lockstep),
    // which is where a bug in resident data would hide.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
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
        .gravity = zm.vec(0, 0, -9.81),
        .max_contacts = 256,
    };
    options.solver.algorithm = .newton;
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, options);
    defer imported.deinit();
    const m: *rbt.Model = &imported.model;
    const baked: []u8 = blk: {
        var file: std.Io.File = std.Io.Dir.cwd().openFile(io, "examples/getup_train/getup.zclip", .{}) catch
            return error.SkipZigTest;
        defer file.close(io);
        const info: std.Io.File.Stat = try file.stat(io);
        const bytes: []u8 = try gpa.alloc(u8, info.size);
        _ = try file.readPositionalAll(io, bytes, 0);
        break :blk bytes;
    };
    defer gpa.free(baked);
    var clip: dance.Clip = try dance.Clip.fromBytes(gpa, baked);
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

    var state: track.State = try track.State.init(gpa, m.nbody);
    defer state.deinit(gpa);
    var data: rbt.Data = try rbt.Data.init(gpa, m);
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
            try expect(std.mem.eql(f32, expected[0..resident.features], acts[at..][0..resident.features]));
            const action: []const f32 = acts[at + resident.features ..][0..resident.actions];
            try expect(std.mem.eql(f32, fleet.replay.actionAt(env, index), action));
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
        try expect(std.mem.eql(f32, expected, acts[at..][0..resident.row]));
    }
    try expect(checked == 4 * 32);
}

test "robot_latent_kit: the gather assembles on the GPU exactly the windows the CPU would" {
    // The resident ring and tables of a real fleet (the baked get-up), a normaliser, and windows the
    // CPU replay sampled; the kit's blocks read back and held against the CPU's own code - features
    // by `local`, normalised by `Normalizer.toNormal`, references by `encodeTargets`, actions from the
    // replay. BITWISE: the kernel normalises with the CPU's operations in the CPU's order.
    const gpa: Allocator = std.testing.allocator;
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
    var rng: std.Random.DefaultPrng = .init(3);
    var starts: [4]Start = undefined;
    for (&starts) |*start| {
        const window: track.Replay.Window = fleet.replay.sampleWindow(rng.random(), steps) orelse return error.NoData;
        start.* = .{ .env = @intCast(window.env), .index = window.first };
    }
    resident.stageStarts(&starts, 0, steps);
    resident.gather(kit, 0);
    const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;

    var state: track.State = try track.State.init(gpa, m.nbody);
    defer state.deinit(gpa);
    var data: rbt.Data = try rbt.Data.init(gpa, m);
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
            try expect(std.mem.eql(f32, expected[0..setup.features], acts[z_at..][0..setup.features]));
            if (step < steps) {
                const block: usize = kit.blockX(@intCast(step)) + row * kit.width;
                // The pose the servo aimed at during this step: the next frame, clamped.
                const next: usize = @as(usize, fleet.replay.frameAt(start.env, index)) + 1;
                const frame: usize = @min(next, setup.clip.frame_count - 1);
                const pose: []const f32 = setup.clip.pose(frame)[setup.clip.nq - m.nq ..];
                track.encodeTargets(m, pose, expected[0..setup.references]);
                const ref: []const f32 = acts[block + setup.features ..][0..setup.references];
                try expect(std.mem.eql(f32, expected[0..setup.references], ref));
                const action: []const f32 = acts[block + setup.features + setup.references ..][0..setup.actions];
                try expect(std.mem.eql(f32, fleet.replay.actionAt(start.env, index), action));
            }
        }
    }
}

/// A real fleet on the baked get-up clip, for the resident-data tests: no retargeting, so fast.
pub const FleetSetup = struct {
    gpa: Allocator,
    doc: @import("codecs.zig").xml.Document,
    robot: @import("mjcf.zig").Robot,
    imported: @import("robot_mjcf.zig").Imported,
    clip: dance.Clip,
    fleet: *track.Fleet,
    features: u32,
    references: u32,
    actions: u32,
    actions_buffer: []f32,

    pub fn init(self: *FleetSetup, gpa: Allocator) !void {
        return self.initFrom(gpa, "examples/getup_train/getup.zclip");
    }

    /// Everything built here is released again if a later step fails - including the skip when the
    /// baked clip is missing, which would otherwise leak the robot and fail the test on leaks
    /// instead of skipping it.
    fn initFrom(self: *FleetSetup, gpa: Allocator, clip_path: []const u8) !void {
        const codecs = @import("codecs.zig");
        const mjcf = @import("mjcf.zig");
        const robot_mjcf = @import("robot_mjcf.zig");
        var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
        defer threaded.deinit();
        const io: std.Io = threaded.io();
        // whole-init-first: the whole struct first - defaults applied, every field named.
        self.* = .{
            .gpa = undefined,
            .doc = undefined,
            .robot = undefined,
            .imported = undefined,
            .clip = undefined,
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
            .gravity = zm.vec(0, 0, -9.81),
            .max_contacts = 256,
        };
        options.solver.algorithm = .newton;
        self.imported = try robot_mjcf.build(gpa, &self.robot, options);
        errdefer self.imported.deinit();
        const m: *rbt.Model = &self.imported.model;
        var file: std.Io.File = std.Io.Dir.cwd().openFile(io, clip_path, .{}) catch
            return error.SkipZigTest;
        defer file.close(io);
        const info: std.Io.File.Stat = try file.stat(io);
        const baked: []u8 = try gpa.alloc(u8, info.size);
        defer gpa.free(baked);
        _ = try file.readPositionalAll(io, baked, 0);
        self.clip = try dance.Clip.fromBytes(gpa, baked);
        errdefer self.clip.deinit();
        self.fleet = try .init(gpa, m, &.{&self.clip}, .{ .envs = 4, .capacity = 32 });
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
        self.clip.deinit();
        self.imported.deinit();
        self.robot.deinit();
        self.doc.deinit();
    }
};

test "robot_latent_kit: trained on gathered windows, the kit follows the CPU model step for step" {
    // The whole resident training step - gather, rollout, backward, Adam - against the CPU model's
    // own `trainOn`, from the same starting weights and normaliser, on the SAME windows every step,
    // for 60 steps. Compared by the LOSS each reports before its update: weights compared after an
    // Adam step would flag the rare weight whose near-zero gradient rounds to the other sign, which
    // tests rounding, not training. Both must also descend - judged by the mean of the last ten
    // steps against the first ten, because each step's loss is on a different batch of only eight
    // windows, and because a model that starts as "nothing changes" (a near-zero output layer, which
    // Adam's first steps move by more than its own size) rises before it falls.
    const gpa: Allocator = std.testing.allocator;
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
    const kit: LatentKit(zn_mlp) = try .init(
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

    var rng: std.Random.DefaultPrng = .init(17);
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
            try expect(std.mem.eql(f32, taken, staged[at..][0..kit.actions]));
        }
        kit.loss();
        const gpu: f32 = (host.readLatest(.loss) orelse return error.NoReadback)[0];
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
    const gpa: Allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    const f: u32 = 291;
    const r: u32 = 70;
    const a: u32 = 35;
    const h: u32 = 32;
    const rows: u32 = 4;
    const steps: u32 = 8;
    var rng: std.Random.DefaultPrng = .init(41);
    const random: std.Random = rng.random();
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
            try expect(std.mem.eql(f32, staged_goal, next_goal));
        }
    }
    try expect(worst == 0.0);
}

test "robot_latent_kit: the gather fills each row's goal, and the goal block, from the tables" {
    // With a lead, every row starts with the reference's features at its step's frame, normalised,
    // and the contiguous goal block holds the same for steps 1..steps - against the CPU learner's
    // own recipe (`referenceStateInto`, `local`, `toNormal`), BITWISE. And the world model's slice
    // must be exactly what it is without a lead.
    const gpa: Allocator = std.testing.allocator;
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
    var rng: std.Random.DefaultPrng = .init(9);
    var starts: [4]Start = undefined;
    for (&starts) |*start| {
        const window: track.Replay.Window = fleet.replay.sampleWindow(rng.random(), steps) orelse return error.NoData;
        start.* = .{ .env = @intCast(window.env), .index = window.first };
    }
    resident.stageStarts(&starts, 0, steps);
    resident.gather(kit, 0);
    const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;

    var state: track.State = try track.State.init(gpa, m.nbody);
    defer state.deinit(gpa);
    var data: rbt.Data = try rbt.Data.init(gpa, m);
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
                try expect(std.mem.eql(f32, expected, in_row));
                const in_block: []const f32 = acts[kit.blockG(@intCast(step)) + row * f ..][0..f];
                try expect(std.mem.eql(f32, expected, in_block));
            }
            // The world model's slice is unmoved by the lead: its state (step 0) and its target.
            fleet.stateAt(start.env, index, &data, &state);
            track.local(state, fleet.root, raw);
            norm.toNormal(raw, expected);
            const z_at: usize = if (step == 0)
                kit.blockX(0) + row * kit.width + kit.lead
            else
                kit.blockT(@intCast(step)) + row * f;
            try expect(std.mem.eql(f32, expected, acts[z_at..][0..f]));
        }
    }
}

test "robot_latent_kit: a missing baked clip skips the resident tests cleanly, leaking nothing" {
    // The error path the setup had no errdefers for: the robot is built, then the clip is not
    // found. It must come back as a skip with everything released - the testing allocator fails
    // this test on any leak.
    var setup: FleetSetup = undefined;
    try expectError(error.SkipZigTest, setup.initFrom(std.testing.allocator, "no/such/clip.zclip"));
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
    const gpa: Allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    const f: u32 = 291;
    const r: u32 = 70;
    const a: u32 = 35;
    const h: u32 = 32;
    const hp: u32 = 32;
    const rows: u32 = 4;
    const steps: u32 = 8;
    var rng: std.Random.DefaultPrng = .init(53);
    const random: std.Random = rng.random();
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
            latent.policyWith(policy, policy_hidden[0], policy_hidden[1], z, goal, action);
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
    const gpa: Allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
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
    var rng: std.Random.DefaultPrng = .init(61);
    const random: std.Random = rng.random();
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
    const ones_t: Tensor = try Tensor.alloc(owned, &.{ rows, 1 });
    @memset(ones_t.data, 1.0);
    const ones: Var = try g.constant(ones_t);
    const zeros_t: Tensor = try Tensor.alloc(owned, &.{ rows, a });
    @memset(zeros_t.data, 0.0);
    const no_action: Var = try g.constant(zeros_t);
    var z: Var = try g.constant(start);
    var total: ?Var = null;
    var previous: ?Var = null;
    for (0..steps) |step| {
        const noise_t: Tensor = try Tensor.alloc(owned, &.{ rows, a });
        const step_seed: u32 = zn_mlp.latStepSeed(seed, @intCast(step));
        for (0..rows) |row| {
            for (0..a) |j| {
                noise_t.data[row * a + j] = zn_mlp.latNoise(step_seed, @intCast(row), @intCast(j));
            }
        }
        const raw: Var = try latent.Learner.policyOnGraph(g, policy_vars, z, try g.constant(goals[step]), ones);
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
    const gpa: Allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const owned: Allocator = arena.allocator();
    const f: u32 = 291;
    const r: u32 = 70;
    const a: u32 = 35;
    const h: u32 = 16;
    const hp: u32 = 16;
    var rng: std.Random.DefaultPrng = .init(71);
    const random: std.Random = rng.random();
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
    try expect(std.mem.eql(f32, world_before, after[0..kit.param_count]));
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
    const gpa: Allocator = std.testing.allocator;
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

    var rng: std.Random.DefaultPrng = .init(29);
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
    const gpa: Allocator = std.testing.allocator;
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
    var rng: std.Random.DefaultPrng = .init(4);
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

    var state: track.State = try track.State.init(gpa, fleet.m.nbody);
    defer state.deinit(gpa);
    var data: rbt.Data = try rbt.Data.init(gpa, fleet.m);
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
            try expect(std.mem.eql(f32, expected, staged));
        }
    }
}
