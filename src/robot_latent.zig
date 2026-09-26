//! robot_latent - SuperTrack's world model and policy on the CPU: the reference the resident
//! (GPU) version is measured against, and where the algorithm is easiest to read.
//!
//! Two things live here, in the order they are used:
//!
//!   1. **The latent world model** (`LatentWorld`, `WorldOptions`): a learned step in a space of its
//!      own - `z' = z + Net(z, reference, action)` - trained through multi-step rollouts. It predicts
//!      where a character WILL BE rather than the forces that take it there, which is what holds it
//!      together over dozens of steps where a model of accelerations falls apart (D15).
//!   2. **The learner** (`Learner`, `LearnerOptions`): SuperTrack's loop - collect, train the world
//!      model, then train the policy THROUGH the frozen model, by backpropagation through its rollout.
//!
//! One file because they are one system: the learner owns a world model, trains it, and trains its
//! policy through it. The GPU version in `robot_latent_kit.zig` follows the same order, and every
//! kernel there is checked against the code here on identical inputs.

const std = @import("std");
const report = @import("test_report.zig");
const zm = @import("zm");
const zn = @import("zn");
const rbt = @import("robot.zig");
const track = @import("robot_track.zig");
const dance = @import("robot_dance.zig");
const gym = @import("robot_gym.zig");

const Allocator = std.mem.Allocator;
const Var = zn.Var;
const Graph = zn.Graph(f32);
const Tensor = zn.Tensor(f32);
const float = zm.float;

pub const WorldOptions = struct {
    hidden: usize = 256,
    /// How many steps each training window is rolled out for - T6d's trustworthy horizon.
    steps: usize = 8,
    /// Windows per training step.
    batch: usize = 32,
    rate: f32 = 1.0e-3,
    seed: u64 = 1,
};

/// Per-feature mean and spread, fixed once from data: the space the model lives in.
pub const Normalizer = struct {
    mean: []f32,
    spread: []f32,

    pub fn toNormal(self: Normalizer, raw: []const f32, out: []f32) void {
        for (out, raw, self.mean, self.spread) |*o, r, mu, sigma| {
            o.* = (r - mu) / sigma;
        }
    }

    pub fn toRaw(self: Normalizer, normal: []const f32, out: []f32) void {
        for (out, normal, self.mean, self.spread) |*o, n, mu, sigma| {
            o.* = n * sigma + mu;
        }
    }
};

pub const LatentWorld = struct {
    arena: std.heap.ArenaAllocator,
    m: *rbt.Model,
    options: WorldOptions,
    features: usize,
    references: usize,
    actions: usize,
    norm: Normalizer,
    /// The network's parameters, in the order `vars` and the optimiser see them.
    params: [8]Tensor,
    graph: Graph,
    vars: [8]Var,
    /// Inputs, rewritten every training step: the real first state, and per step the reference's
    /// encoded targets, the action taken, and the real state the step should reach.
    first: Var,
    refs: []Var,
    acts: []Var,
    targets: []Var,
    loss: Var,
    adam: gym.AdamSet,
    rng: std.Random.DefaultPrng,
    /// The windows of the current training step.
    windows: []track.Replay.Window,
    /// Scratch for building examples and running rows outside the graph.
    state: track.State,
    data: rbt.Data,
    raw: []f32,
    pose: []f32,
    hidden1: []f32,
    hidden2: []f32,

    /// Build the model and its training graph. The normaliser is measured from `fleet`'s replay,
    /// which must already hold data.
    pub fn init(
        gpa: Allocator,
        fleet: *track.Fleet,
        options: WorldOptions,
    ) !*LatentWorld {
        const self: *LatentWorld = try gpa.create(LatentWorld);
        errdefer gpa.destroy(self);
        // whole-init-first: the whole struct first - defaults applied, every field named.
        self.* = .{
            .arena = undefined,
            .m = undefined,
            .options = undefined,
            .features = undefined,
            .references = undefined,
            .actions = undefined,
            .norm = undefined,
            .params = undefined,
            .graph = undefined,
            .vars = undefined,
            .first = undefined,
            .refs = undefined,
            .acts = undefined,
            .targets = undefined,
            .loss = undefined,
            .adam = undefined,
            .rng = undefined,
            .windows = undefined,
            .state = undefined,
            .data = undefined,
            .raw = undefined,
            .pose = undefined,
            .hidden1 = undefined,
            .hidden2 = undefined,
        };
        self.arena = .init(gpa);
        errdefer self.arena.deinit();
        const owned: Allocator = self.arena.allocator();
        const m: *rbt.Model = fleet.m;
        const f: usize = track.localSize(m.nbody);
        const r: usize = track.targetSize(m);
        const a: usize = track.actionSize(m);
        const h: usize = options.hidden;
        self.m = m;
        self.options = options;
        self.features = f;
        self.references = r;
        self.actions = a;
        self.rng = .init(options.seed);
        self.state = try track.State.init(owned, m.nbody);
        self.data = try rbt.Data.init(owned, m);
        self.raw = try owned.alloc(f32, f);
        self.windows = try owned.alloc(track.Replay.Window, options.batch);
        self.pose = try owned.alloc(f32, m.nq);
        self.hidden1 = try owned.alloc(f32, h);
        self.hidden2 = try owned.alloc(f32, h);
        self.norm = try measureNormalizer(owned, fleet);

        // Parameters: Xavier for the tanh layers, and a near-zero output layer so the untrained
        // model is "nothing changes" - a residual model should start as the identity.
        const random: std.Random = self.rng.random();
        const shapes = [8][2]usize{
            .{ f, h }, .{ r, h }, .{ a, h }, .{ 1, h }, // first layer: features, reference, action, bias
            .{ h, h }, .{ 1, h }, // second layer
            .{ h, f }, .{ 1, f }, // the change in features
        };
        const fan_in = [8]usize{ f + r + a, f + r + a, f + r + a, 0, h, 0, h, 0 };
        for (&self.params, shapes, fan_in, 0..) |*p, shape, fan, i| {
            p.* = try Tensor.alloc(owned, &shape);
            if (fan == 0) {
                @memset(p.data, 0.0);
                continue;
            }
            const deviation: f32 = @sqrt(1.0 / float(fan)) * @as(f32, if (i == 6) 0.01 else 1.0);
            for (p.data) |*w| {
                w.* = deviation * random.floatNorm(f32);
            }
        }

        // The training graph, built once: a window of `steps` steps, rolled out on the model's own
        // predictions from the real first state.
        const b: usize = options.batch;
        self.graph = .init(owned);
        const g: *Graph = &self.graph;
        for (&self.vars, self.params) |*v, p| {
            v.* = try g.parameter(p);
        }
        const ones: Var = try g.constant(try filled(owned, &.{ b, 1 }, 1.0));
        self.first = try g.constant(try filled(owned, &.{ b, f }, 0.0));
        self.refs = try owned.alloc(Var, options.steps);
        self.acts = try owned.alloc(Var, options.steps);
        self.targets = try owned.alloc(Var, options.steps);
        var z: Var = self.first;
        var total: ?Var = null;
        for (0..options.steps) |k| {
            self.refs[k] = try g.constant(try filled(owned, &.{ b, r }, 0.0));
            self.acts[k] = try g.constant(try filled(owned, &.{ b, a }, 0.0));
            self.targets[k] = try g.constant(try filled(owned, &.{ b, f }, 0.0));
            z = try step(g, self.vars, z, self.refs[k], self.acts[k], ones);
            const term: Var = try g.mseLoss(z, self.targets[k]);
            total = if (total) |t| try g.add(t, term) else term;
        }
        self.loss = try g.scale(total.?, 1.0 / float(options.steps));
        self.adam = try .init(owned, &self.params);
        return self;
    }

    pub fn deinit(self: *LatentWorld, gpa: Allocator) void {
        self.data.deinit();
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// One step of the model on the graph: z + Net(z, ref, act). Public so a policy's graph can
    /// roll out through the same weights (`robot_track_st`).
    pub fn step(
        g: *Graph,
        v: [8]Var,
        z: Var,
        ref: Var,
        act: Var,
        ones: Var,
    ) !Var {
        const into: Var = try g.add(
            try g.add(try g.matmul(z, v[0]), try g.matmul(ref, v[1])),
            try g.add(try g.matmul(act, v[2]), try g.matmul(ones, v[3])),
        );
        const h1: Var = try g.tanh(into);
        const h2: Var = try g.tanh(try g.add(try g.matmul(h1, v[4]), try g.matmul(ones, v[5])));
        const delta: Var = try g.add(try g.matmul(h2, v[6]), try g.matmul(ones, v[7]));
        return g.add(z, delta);
    }

    /// One training step on `batch` windows drawn from the fleet's replay. Null if the replay
    /// cannot supply them yet.
    pub fn trainStep(self: *LatentWorld, fleet: *track.Fleet) !?f32 {
        // All the windows are drawn BEFORE any is filled in. Filling draws no random numbers, so the
        // sequence of draws is exactly what it was when drawing and filling were interleaved - every
        // test measured before the split (D15, T8d) still sees the same windows.
        const random: std.Random = self.rng.random();
        for (self.windows) |*window| {
            window.* = fleet.replay.sampleWindow(random, self.options.steps) orelse return null;
        }
        return try self.trainOn(fleet, self.windows);
    }

    /// One training step on the windows given - `batch` of them, each `steps` steps of the fleet's
    /// replay. Returns the loss before the update. Split from `trainStep` so another implementation
    /// (the GPU's) can be trained on exactly the same windows and compared step for step.
    pub fn trainOn(
        self: *LatentWorld,
        fleet: *track.Fleet,
        windows: []const track.Replay.Window,
    ) !f32 {
        if (windows.len != self.options.batch) {
            return error.WrongBatch;
        }
        const g: *Graph = &self.graph;
        const f: usize = self.features;
        const r: usize = self.references;
        const a: usize = self.actions;
        for (windows, 0..) |window, row| {
            self.featuresAt(fleet, window.env, window.first, g.valueOf(self.first).data[row * f ..][0..f]);
            for (0..self.options.steps) |k| {
                const index: u64 = window.first + k;
                self.referenceAt(fleet, window.env, index, g.valueOf(self.refs[k]).data[row * r ..][0..r]);
                const action: []const f32 = fleet.replay.actionAt(window.env, index);
                @memcpy(g.valueOf(self.acts[k]).data[row * a ..][0..a], action);
                self.featuresAt(fleet, window.env, index + 1, g.valueOf(self.targets[k]).data[row * f ..][0..f]);
            }
        }
        try g.recompute();
        try g.backward(self.loss);
        try self.adam.apply(g, &self.params, &self.vars, self.options.rate);
        return g.valueOf(self.loss).data[0];
    }

    /// A recorded state's features, normalised.
    pub fn featuresAt(
        self: *LatentWorld,
        fleet: *track.Fleet,
        env: usize,
        index: u64,
        out: []f32,
    ) void {
        fleet.stateAt(env, index, &self.data, &self.state);
        track.local(self.state, fleet.root, self.raw);
        self.norm.toNormal(self.raw, out);
    }

    /// The reference's encoded targets for a recorded step: its clip, at its frame. No action in
    /// it - the action is its own input.
    pub fn referenceAt(
        self: *LatentWorld,
        fleet: *track.Fleet,
        env: usize,
        index: u64,
        out: []f32,
    ) void {
        const clip: *const dance.Clip = fleet.clips[fleet.replay.clipAt(env, index)];
        // The pose the servo aimed at during this step: the NEXT frame, clamped exactly as the fleet's
        // `driveOnce` clamps it - the world model must see the target that was actually used.
        const frame: usize = @min(@as(usize, fleet.replay.frameAt(env, index)) + 1, clip.frame_count - 1);
        const root_len: usize = clip.nq - self.m.nq;
        track.encodeTargets(self.m, clip.pose(frame)[root_len..], out);
    }

    /// One step outside the graph, for rollouts: `z` becomes z + Net(z, ref, act), in place.
    pub fn stepRow(
        self: *LatentWorld,
        z: []f32,
        ref: []const f32,
        act: []const f32,
    ) void {
        stepWith(self.params, self.hidden1, self.hidden2, z, ref, act);
    }
};

/// One step of the model on one row, from its parameters alone: `z` becomes z + Net(z, ref, act),
/// in place. The body of `LatentWorld.stepRow`, free-standing so a GPU version can be checked
/// against the very code the CPU model trains with - not against a copy of it in a test. The sums
/// run bias first, then the features, the reference and the action in order: the same order the
/// kit's dense layer adds a stacked first layer's inputs, which is what makes the two comparable
/// to the last bit or nearly.
pub fn stepWith(
    params: [8]Tensor,
    hidden1: []f32,
    hidden2: []f32,
    z: []f32,
    ref: []const f32,
    act: []const f32,
) void {
    const h: usize = hidden1.len;
    const features: usize = z.len;
    const p = params;
    for (0..h) |j| {
        var sum: f32 = p[3].data[j];
        for (z, 0..) |x, i| {
            sum += x * p[0].data[i * h + j];
        }
        for (ref, 0..) |x, i| {
            sum += x * p[1].data[i * h + j];
        }
        for (act, 0..) |x, i| {
            sum += x * p[2].data[i * h + j];
        }
        hidden1[j] = zm.tanh(sum);
    }
    for (0..h) |j| {
        var sum: f32 = p[5].data[j];
        for (hidden1, 0..) |x, i| {
            sum += x * p[4].data[i * h + j];
        }
        hidden2[j] = zm.tanh(sum);
    }
    for (z, 0..) |*out, j| {
        var sum: f32 = p[7].data[j];
        for (hidden2, 0..) |x, i| {
            sum += x * p[6].data[i * features + j];
        }
        out.* += sum;
    }
}

/// How a rollout's pose drifts: the mean distance of every body from where the simulator had it,
/// in the ROOT's frame, after each step - the same quantity as `TrackingError.pose_position`, read
/// straight off the feature vector (its first entries are the bodies' positions in that frame).
pub const PoseDrift = struct {
    learned: []f32,
    /// Two baselines a model must beat: nothing changes, and the first real change held.
    persist: []f32,
    hold_first: []f32,
    windows: usize,

    pub fn deinit(self: PoseDrift, gpa: Allocator) void {
        gpa.free(self.learned);
        gpa.free(self.persist);
        gpa.free(self.hold_first);
    }
};

pub fn measurePoseDrift(
    gpa: Allocator,
    model: *LatentWorld,
    fleet: *track.Fleet,
    draws: usize,
    steps: usize,
    random: std.Random,
) !PoseDrift {
    const f: usize = model.features;
    const bodies: usize = model.m.nbody - 1;
    var drift: PoseDrift = .{
        .learned = try gpa.alloc(f32, steps),
        .persist = try gpa.alloc(f32, steps),
        .hold_first = try gpa.alloc(f32, steps),
        .windows = 0,
    };
    errdefer drift.deinit(gpa);
    @memset(drift.learned, 0.0);
    @memset(drift.persist, 0.0);
    @memset(drift.hold_first, 0.0);
    const buffers: []f32 = try gpa.alloc(f32, 6 * f + model.references);
    defer gpa.free(buffers);
    const z: []f32 = buffers[0..f];
    const start: []f32 = buffers[f..][0..f];
    const change: []f32 = buffers[2 * f ..][0..f];
    const truth: []f32 = buffers[3 * f ..][0..f];
    const raw_a: []f32 = buffers[4 * f ..][0..f];
    const raw_b: []f32 = buffers[5 * f ..][0..f];
    const ref: []f32 = buffers[6 * f ..][0..model.references];
    for (0..draws) |_| {
        const window: track.Replay.Window = fleet.replay.sampleWindow(random, steps) orelse continue;
        drift.windows += 1;
        model.featuresAt(fleet, window.env, window.first, start);
        model.featuresAt(fleet, window.env, window.first + 1, truth);
        for (change, truth, start) |*c, t, s| {
            c.* = t - s;
        }
        @memcpy(z, start);
        for (0..steps) |k| {
            const index: u64 = window.first + k;
            model.referenceAt(fleet, window.env, index, ref);
            model.stepRow(z, ref, fleet.replay.actionAt(window.env, index));
            model.featuresAt(fleet, window.env, index + 1, truth);
            model.norm.toRaw(truth, raw_a);
            // The model.
            model.norm.toRaw(z, raw_b);
            drift.learned[k] += poseError(raw_a, raw_b, bodies);
            // Nothing changes.
            model.norm.toRaw(start, raw_b);
            drift.persist[k] += poseError(raw_a, raw_b, bodies);
            // The first change, held.
            for (raw_b, start, change) |*o, s, c| {
                o.* = s + c * float(k + 1);
            }
            model.norm.toRaw(raw_b, raw_b);
            drift.hold_first[k] += poseError(raw_a, raw_b, bodies);
        }
    }
    const n: f32 = float(@max(drift.windows, 1));
    for (drift.learned, drift.persist, drift.hold_first) |*l, *p, *h| {
        l.* /= n;
        p.* /= n;
        h.* /= n;
    }
    return drift;
}

/// Mean over bodies of the distance between two feature vectors' body positions (raw units).
fn poseError(a: []const f32, b: []const f32, bodies: usize) f32 {
    var total: f32 = 0.0;
    for (0..bodies) |body| {
        const dx: f32 = a[body * 3] - b[body * 3];
        const dy: f32 = a[body * 3 + 1] - b[body * 3 + 1];
        const dz: f32 = a[body * 3 + 2] - b[body * 3 + 2];
        total += @sqrt(dx * dx + dy * dy + dz * dz);
    }
    return total / float(bodies);
}

/// Mean and spread of every feature over everything the replay holds, spreads floored so a feature
/// that never moves does not divide by nothing. The caller owns the two slices it comes back with.
///
/// Public because the GPU learner needs the same statistics without building a CPU world model to get
/// them, and because the paper measures them from the reference clips instead - the motion the
/// character is meant to follow - which this is the natural place to offer one day.
pub fn measureNormalizer(owned: Allocator, fleet: *track.Fleet) !Normalizer {
    var data: rbt.Data = try rbt.Data.init(owned, fleet.m);
    defer data.deinit();
    var state: track.State = try track.State.init(owned, fleet.m.nbody);
    defer state.deinit(owned);
    const raw: []f32 = try owned.alloc(f32, track.localSize(fleet.m.nbody));
    defer owned.free(raw);
    const f: usize = track.localSize(fleet.m.nbody);
    const mean: []f32 = try owned.alloc(f32, f);
    const spread: []f32 = try owned.alloc(f32, f);
    // Working sums, freed here: the mean and spread go back to the caller, these do not. (They went
    // unfreed while this only ever ran on an arena the world model frees wholesale - a page passing an
    // ordinary allocator is what made it visible.)
    const sum: []f64 = try owned.alloc(f64, f);
    defer owned.free(sum);
    const squares: []f64 = try owned.alloc(f64, f);
    defer owned.free(squares);
    @memset(sum, 0.0);
    @memset(squares, 0.0);
    var count: usize = 0;
    for (0..fleet.options.envs) |env| {
        const written: u64 = fleet.replay.written[env];
        const oldest: u64 = written -| @as(u64, @intCast(fleet.replay.capacity));
        var index: u64 = oldest;
        while (index < written) : (index += 1) {
            fleet.stateAt(env, index, &data, &state);
            track.local(state, fleet.root, raw);
            for (raw, sum, squares) |x, *s, *q| {
                s.* += x;
                q.* += @as(f64, x) * x;
            }
            count += 1;
        }
    }
    if (count == 0) {
        return error.NoData;
    }
    const n: f64 = @floatFromInt(count);
    for (mean, spread, sum, squares) |*mu, *sigma, s, q| {
        const average: f64 = s / n;
        mu.* = @floatCast(average);
        sigma.* = @floatCast(@max(@sqrt(@max(q / n - average * average, 0.0)), 1.0e-3));
    }
    return .{ .mean = mean, .spread = spread };
}

fn filled(
    owned: Allocator,
    shape: []const usize,
    value: f32,
) !Tensor {
    const t: Tensor = try Tensor.alloc(owned, shape);
    @memset(t.data, value);
    return t;
}

const expect = std.testing.expect;

pub const LearnerOptions = struct {
    hidden: usize = 256,
    /// How many steps the policy is rolled through the model for. The latent model drifts ~15 mm
    /// in 8 steps and ~31 mm in 32 (T8c), so long windows are affordable.
    window: usize = 16,
    batch: usize = 32,
    rate: f32 = 3.0e-4,
    /// Exploration noise, in units of the policy's raw output - in the real simulator while
    /// collecting, and inside every training rollout.
    sigma: f32 = 0.1,
    // (No action scale here. The policy's authority - radians of pose offset per unit of its output -
    // is the FLEET's `action_scale`, applied where an action becomes a PD target. A second scale here
    // once multiplied with it: 0.3 x 0.2, a fifth of the authority intended, found by holding this
    // code against the SuperTrack paper. One scale, owned by the one place that applies it.)
    /// The price on the size of the raw output, beside the tracking loss.
    w_action: f32 = 0.01,
    /// TEMPORAL SMOOTHNESS (CAPS: Mysore et al., 2021): the penalty on how far the policy's action moves from one
    /// step of a window to the next, `w_smooth * |a_k - a_(k-1)|^2`. A policy trained through a world model can
    /// learn outputs that swing wildly with small changes of state - on a character, every freedom lurching each
    /// frame, a body that looks like it is exploding. Zero (off) by default.
    w_smooth: f32 = 0.0,
    seed: u64 = 1,
    /// Where the noise inside the training rollouts comes from: the learner's own random stream by
    /// default; given a function, `noise(update, step, row, action)`. That is how a GPU version, drawing
    /// its noise from a hash (the kit's `latNoise`), is compared with this one step for step.
    noise: ?*const fn (update: u32, step: u32, row: u32, action: u32) f32 = null,
    world: WorldOptions = .{},
};

/// What `Learner.modelLoss` measures: the tracking loss inside the model, and the actions' size.
pub const InModel = struct {
    /// Mean squared distance from the reference, per feature, in normalised units.
    loss: f32,
    /// Mean absolute action, in radians of pose offset.
    action: f32,
};

pub const Learner = struct {
    arena: std.heap.ArenaAllocator,
    gpa: Allocator,
    options: LearnerOptions,
    fleet: *track.Fleet,
    world: *LatentWorld,
    features: usize,
    references: usize,
    actions: usize,
    /// The policy: [features of the character, features of the reference] -> hidden -> hidden ->
    /// raw action. The first layer split in two (the concat-free trick again).
    params: [7]Tensor,
    graph: Graph,
    vars: [7]Var,
    world_vars: [8]Var,
    start: Var,
    goals: []Var,
    refs: []Var,
    noise: []Var,
    loss: Var,
    adam: gym.AdamSet,
    rng: std.Random.DefaultPrng,
    /// Policy updates so far - which update's noise to draw, when `options.noise` is given.
    updates: u32,
    // Scratch for acting and for building windows.
    state: track.State,
    reference: track.State,
    ref_data: rbt.Data,
    raw: []f32,
    /// BEHAVIOUR CLONING (D4): a second, small graph - the policy alone on recorded steps, its output against
    /// a teacher's recorded action - over the SAME parameter tensors and stepped by the SAME Adam, so a cloned
    /// policy IS this learner's policy, ready to be fine-tuned through the world model. Built on first use.
    clone: ?Clone = null,
    z_sim: []f32,
    z_ref: []f32,
    out: []f32,
    hidden1: []f32,
    hidden2: []f32,
    fleet_actions: []f32,

    /// Build the learner on a fleet whose replay already holds some data (the world model's
    /// normaliser is measured from it).
    pub fn init(gpa: Allocator, fleet: *track.Fleet, options: LearnerOptions) !*Learner {
        const self: *Learner = try gpa.create(Learner);
        errdefer gpa.destroy(self);
        // whole-init-first: the whole struct first - defaults applied, every field named.
        self.* = .{
            .arena = undefined,
            .gpa = undefined,
            .options = undefined,
            .fleet = undefined,
            .world = undefined,
            .features = undefined,
            .references = undefined,
            .actions = undefined,
            .params = undefined,
            .graph = undefined,
            .vars = undefined,
            .world_vars = undefined,
            .start = undefined,
            .goals = undefined,
            .refs = undefined,
            .noise = undefined,
            .loss = undefined,
            .adam = undefined,
            .rng = undefined,
            .updates = undefined,
            .state = undefined,
            .reference = undefined,
            .ref_data = undefined,
            .raw = undefined,
            .z_sim = undefined,
            .z_ref = undefined,
            .out = undefined,
            .hidden1 = undefined,
            .hidden2 = undefined,
            .fleet_actions = undefined,
        };
        self.arena = .init(gpa);
        errdefer self.arena.deinit();
        const owned: Allocator = self.arena.allocator();
        const m: *rbt.Model = fleet.m;
        self.gpa = gpa;
        self.options = options;
        self.fleet = fleet;
        self.world = try LatentWorld.init(gpa, fleet, options.world);
        errdefer self.world.deinit(gpa);
        const f: usize = self.world.features;
        const r: usize = self.world.references;
        const a: usize = self.world.actions;
        const h: usize = options.hidden;
        self.features = f;
        self.references = r;
        self.actions = a;
        self.rng = .init(options.seed);
        // Set here, not by a field default: the learner is made by `gpa.create`, whose memory is
        // uninitialised - a default on the field would never be applied.
        self.updates = 0;
        self.state = try track.State.init(owned, m.nbody);
        self.reference = try track.State.init(owned, m.nbody);
        self.ref_data = try rbt.Data.init(owned, m);
        self.raw = try owned.alloc(f32, f);
        self.z_sim = try owned.alloc(f32, f);
        self.z_ref = try owned.alloc(f32, f);
        self.out = try owned.alloc(f32, a);
        self.hidden1 = try owned.alloc(f32, h);
        self.hidden2 = try owned.alloc(f32, h);
        self.fleet_actions = try owned.alloc(f32, fleet.options.envs * a);

        // The policy's parameters: Xavier for the tanh layers, and a near-zero output layer, so an
        // untrained policy is the servo alone - the same starting point PPO's residual policy has.
        const random: std.Random = self.rng.random();
        const shapes = [7][2]usize{
            .{ f, h }, .{ f, h }, .{ 1, h }, // first layer: the character, the reference, bias
            .{ h, h }, .{ 1, h }, // second layer
            .{ h, a }, .{ 1, a }, // the raw action
        };
        const fan_in = [7]usize{ 2 * f, 2 * f, 0, h, 0, h, 0 };
        for (&self.params, shapes, fan_in, 0..) |*p, shape, fan, i| {
            p.* = try Tensor.alloc(owned, &shape);
            if (fan == 0) {
                @memset(p.data, 0.0);
                continue;
            }
            const deviation: f32 = @sqrt(1.0 / float(fan)) * @as(f32, if (i == 5) 0.01 else 1.0);
            for (p.data) |*w| {
                w.* = deviation * random.floatNorm(f32);
            }
        }

        // The policy's graph: `window` steps, the policy acting on the model's predictions, the
        // model predicting the consequences - through the world model's OWN tensors.
        const b: usize = options.batch;
        const steps: usize = options.window;
        self.graph = .init(owned);
        self.graph.useScratchAllocator(gpa);
        const g: *Graph = &self.graph;
        for (&self.vars, self.params) |*v, p| {
            v.* = try g.parameter(p);
        }
        for (&self.world_vars, self.world.params) |*v, p| {
            v.* = try g.parameter(p);
        }
        const ones: Var = try g.constant(try filled(owned, &.{ b, 1 }, 1.0));
        const no_action: Var = try g.constant(try filled(owned, &.{ b, a }, 0.0));
        self.start = try g.constant(try filled(owned, &.{ b, f }, 0.0));
        self.goals = try owned.alloc(Var, steps + 1);
        self.refs = try owned.alloc(Var, steps);
        self.noise = try owned.alloc(Var, steps);
        for (self.goals) |*goal| {
            goal.* = try g.constant(try filled(owned, &.{ b, f }, 0.0));
        }
        var z: Var = self.start;
        var total: ?Var = null;
        var previous: ?Var = null;
        for (0..steps) |k| {
            self.refs[k] = try g.constant(try filled(owned, &.{ b, r }, 0.0));
            self.noise[k] = try g.constant(try filled(owned, &.{ b, a }, 0.0));
            // The policy sees where the reference is going - the goal this step is scored against
            // (SuperTrack's Local(K_{i+1})), not where it was.
            const raw: Var = try policyOnGraph(g, self.vars, z, self.goals[k + 1], ones);
            const noisy: Var = try g.add(raw, try g.scale(self.noise[k], options.sigma));
            // What the fleet records, and so what the world model learned from: the raw action plus
            // its noise, unscaled - the fleet scales it into a PD offset.
            const action: Var = noisy;
            z = try LatentWorld.step(g, self.world_vars, z, self.refs[k], action, ones);
            var term: Var = try g.mseLoss(z, self.goals[k + 1]);
            term = try g.add(term, try g.scale(try g.mseLoss(raw, no_action), options.w_action));
            if (options.w_smooth > 0.0) {
                if (previous) |before| {
                    // The DIFFERENCE is differentiated - `mseLoss` gives no gradient to its target, so
                    // `mseLoss(raw, before)` would pull each action toward the last and never the last toward
                    // it: the true gradient of |a_k - a_(k-1)|^2 reaches both (the GPU kit's too).
                    const jump: Var = try g.add(raw, try g.scale(before, -1.0));
                    term = try g.add(term, try g.scale(try g.mseLoss(jump, no_action), options.w_smooth));
                }
            }
            previous = raw;
            total = if (total) |t| try g.add(t, term) else term;
        }
        self.loss = try g.scale(total.?, 1.0 / float(steps));
        self.adam = try .init(owned, &self.params);
        return self;
    }

    pub fn deinit(self: *Learner) void {
        const gpa: Allocator = self.gpa;
        if (self.clone) |*c| {
            c.graph.deinitScratch();
        }
        self.graph.deinitScratch();
        self.ref_data.deinit();
        self.world.deinit(gpa);
        self.arena.deinit();
        gpa.destroy(self);
    }

    const Clone = struct {
        graph: Graph,
        vars: [7]Var,
        z: Var,
        goal: Var,
        target: Var,
        loss: Var,
    };

    /// A recorded step of the fleet's replay: which environment, and where in it - and, for a state recorded
    /// on its own (DAgger labels one state at a time), the clip frame its goal is at; otherwise the goal is
    /// the next record's frame.
    pub const Step = struct { env: usize, index: u64, goal_frame: ?u32 = null };

    /// One cloning update on `steps` (exactly `batch` of them): for each, the recorded state as the policy
    /// sees it (its features), the goal it is scored against at that step (the reference's NEXT frame, as in
    /// SuperTrack's own graph), and the action the teacher took there as the target - mean squared error,
    /// then Adam. Each step's index must have a successor in the same recording. Returns the loss.
    pub fn cloneStep(self: *Learner, steps: []const Step) !f32 {
        if (steps.len != self.options.batch) {
            return error.WrongBatch;
        }
        if (self.clone == null) {
            try self.buildClone();
        }
        const c: *Clone = &self.clone.?;
        const g: *Graph = &c.graph;
        const f: usize = self.features;
        const a: usize = self.actions;
        for (steps, 0..) |step, row| {
            self.world.featuresAt(self.fleet, step.env, step.index, g.valueOf(c.z).data[row * f ..][0..f]);
            const goal: []f32 = g.valueOf(c.goal).data[row * f ..][0..f];
            if (step.goal_frame) |frame| {
                self.goalOfFrame(self.fleet.replay.clipAt(step.env, step.index), frame, goal);
            } else {
                self.goalAt(step.env, step.index + 1, goal);
            }
            @memcpy(g.valueOf(c.target).data[row * a ..][0..a], self.fleet.replay.actionAt(step.env, step.index));
        }
        try g.recompute();
        try g.backward(c.loss);
        try self.adam.apply(g, &self.params, &c.vars, self.options.rate);
        self.updates += 1;
        return g.valueOf(c.loss).data[0];
    }

    fn buildClone(self: *Learner) !void {
        const owned: Allocator = self.arena.allocator();
        const b: usize = self.options.batch;
        const f: usize = self.features;
        const a: usize = self.actions;
        var c: Clone = .{
            .graph = .init(owned),
            .vars = undefined,
            .z = undefined,
            .goal = undefined,
            .target = undefined,
            .loss = undefined,
        };
        c.graph.useScratchAllocator(self.gpa);
        const g: *Graph = &c.graph;
        for (&c.vars, self.params) |*v, p| {
            v.* = try g.parameter(p);
        }
        const ones: Var = try g.constant(try filled(owned, &.{ b, 1 }, 1.0));
        c.z = try g.constant(try filled(owned, &.{ b, f }, 0.0));
        c.goal = try g.constant(try filled(owned, &.{ b, f }, 0.0));
        c.target = try g.constant(try filled(owned, &.{ b, a }, 0.0));
        const raw: Var = try policyOnGraph(g, c.vars, c.z, c.goal, ones);
        c.loss = try g.mseLoss(raw, c.target);
        self.clone = c;
    }

    /// The policy on a graph: [state, goal] -> raw action. Public so the GPU version's gradients can be
    /// checked against a graph built from this very function.
    pub fn policyOnGraph(
        g: *Graph,
        v: [7]Var,
        z: Var,
        goal: Var,
        ones: Var,
    ) !Var {
        const into: Var = try g.add(
            try g.add(try g.matmul(z, v[0]), try g.matmul(goal, v[1])),
            try g.matmul(ones, v[2]),
        );
        const h1: Var = try g.tanh(into);
        const h2: Var = try g.tanh(try g.add(try g.matmul(h1, v[3]), try g.matmul(ones, v[4])));
        return g.add(try g.matmul(h2, v[5]), try g.matmul(ones, v[6]));
    }

    /// The policy's raw output for one character, outside the graph.
    fn policyRow(self: *Learner, z: []const f32, goal: []const f32, out: []f32) void {
        policyWith(self.params, self.hidden1, self.hidden2, z, goal, out);
    }

    /// A character's live features and its reference's, both normalised.
    fn liveFeatures(self: *Learner, env: usize) void {
        const fleet: *track.Fleet = self.fleet;
        const m: *const rbt.Model = fleet.m;
        track.stateOf(m, &fleet.data[env], &self.state);
        track.local(self.state, fleet.root, self.raw);
        self.world.norm.toNormal(self.raw, self.z_sim);
        const clip: *const dance.Clip = fleet.clips[fleet.clip_of[env]];
        // Where the reference is going: the next frame (clamped inside), the step's own target.
        fleet.referenceStateInto(clip, fleet.frame[env] + 1, &self.ref_data, &self.reference);
        track.local(self.reference, fleet.root, self.raw);
        self.world.norm.toNormal(self.raw, self.z_ref);
    }

    /// `steps` physics steps of the fleet with the policy acting: its raw output plus
    /// `noise_scale * sigma` exploration noise, scaled to radians. Every step lands in the replay.
    pub fn act(self: *Learner, steps: usize, noise_scale: f32) void {
        const random: std.Random = self.rng.random();
        const a: usize = self.actions;
        for (0..steps) |_| {
            for (0..self.fleet.options.envs) |env| {
                self.liveFeatures(env);
                self.policyRow(self.z_sim, self.z_ref, self.out);
                for (self.fleet_actions[env * a ..][0..a], self.out) |*slot, o| {
                    // No draw at all when there is no noise: judging must not consume the
                    // training's random stream, or a judged run trains differently afterwards.
                    const spread: f32 = noise_scale * self.options.sigma;
                    const noisy: f32 = if (noise_scale == 0.0) o else o + spread * random.floatNorm(f32);
                    slot.* = noisy;
                }
            }
            _ = self.fleet.step(self.fleet_actions);
        }
    }

    /// The reference's normalised features at a recorded step's frame.
    fn goalAt(self: *Learner, env: usize, index: u64, out: []f32) void {
        const fleet: *track.Fleet = self.fleet;
        self.goalOfFrame(fleet.replay.clipAt(env, index), fleet.replay.frameAt(env, index), out);
    }

    /// The reference's normalised features at a clip's frame - all a goal depends on.
    fn goalOfFrame(self: *Learner, clip_index: u16, frame: u32, out: []f32) void {
        const fleet: *track.Fleet = self.fleet;
        const clip: *const dance.Clip = fleet.clips[clip_index];
        const at: u32 = @min(frame, @as(u32, @intCast(clip.frame_count - 1)));
        fleet.referenceStateInto(clip, at, &self.ref_data, &self.reference);
        track.local(self.reference, fleet.root, self.raw);
        self.world.norm.toNormal(self.raw, out);
    }

    /// One policy update on `batch` windows of the replay: start on the real recorded state,
    /// then roll the policy through the model. Null until the replay can supply the windows.
    pub fn trainPolicy(self: *Learner) !?f32 {
        const random: std.Random = self.rng.random();
        // Sample and fill row by row, in that order: filling draws the rollout's noise from the same
        // random stream, so drawing every window first would reorder the draws - and silently change
        // every result measured with this learner.
        for (0..self.options.batch) |row| {
            const window: track.Replay.Window =
                self.fleet.replay.sampleWindow(random, self.options.window) orelse return null;
            self.fillRow(row, window, random);
        }
        return try self.update();
    }

    /// One policy update on the windows given - `batch` of them, `window` steps each - rather than
    /// windows it samples: so another implementation (the GPU's) can train on exactly the same ones
    /// and be compared step for step. Returns the loss before the update.
    pub fn trainPolicyOn(self: *Learner, windows: []const track.Replay.Window) !f32 {
        if (windows.len != self.options.batch) {
            return error.WrongBatch;
        }
        const random: std.Random = self.rng.random();
        for (windows, 0..) |window, row| {
            self.fillRow(row, window, random);
        }
        return self.update();
    }

    /// One window into the graph's row `row`: the real first state, the goals (K_0 .. K_window), the
    /// references the servo aimed at, and the rollout's noise.
    fn fillRow(
        self: *Learner,
        row: usize,
        window: track.Replay.Window,
        random: std.Random,
    ) void {
        const g: *Graph = &self.graph;
        const f: usize = self.features;
        const r: usize = self.references;
        const a: usize = self.actions;
        const fleet: *track.Fleet = self.fleet;
        self.world.featuresAt(fleet, window.env, window.first, g.valueOf(self.start).data[row * f ..][0..f]);
        for (0..self.options.window + 1) |k| {
            const index: u64 = window.first + k;
            self.goalAt(window.env, index, g.valueOf(self.goals[k]).data[row * f ..][0..f]);
            if (k < self.options.window) {
                self.world.referenceAt(fleet, window.env, index, g.valueOf(self.refs[k]).data[row * r ..][0..r]);
                for (g.valueOf(self.noise[k]).data[row * a ..][0..a], 0..) |*eps, j| {
                    eps.* = if (self.options.noise) |noise|
                        noise(self.updates, @intCast(k), @intCast(row), @intCast(j))
                    else
                        random.floatNorm(f32);
                }
            }
        }
    }

    /// The update itself, on whatever the rows hold: forward, backward, Adam.
    fn update(self: *Learner) !f32 {
        const g: *Graph = &self.graph;
        try g.recompute();
        try g.backward(self.loss);
        try self.adam.apply(g, &self.params, &self.vars, self.options.rate);
        self.updates += 1;
        return g.valueOf(self.loss).data[0];
    }

    /// The tracking loss INSIDE the model, on `windows` fixed windows of the replay, with no noise:
    /// the policy acting, or (`use_policy` false) doing nothing. The diagnostic that splits a
    /// disappointing result in the real simulator in two: a policy that does not beat doing nothing
    /// even in the model has a broken mechanism; one that beats it in the model but not in reality
    /// is exploiting the model, or the model is wrong where the policy goes. Also reports the mean
    /// size of the actions, in radians. `horizon` is how many steps each window is judged over - it
    /// may exceed the training window, which is how a test asks whether a gain carries past it.
    pub fn modelLoss(
        self: *Learner,
        windows: usize,
        seed: u64,
        use_policy: bool,
        horizon: usize,
    ) InModel {
        var rng: std.Random.DefaultPrng = .init(seed);
        const random: std.Random = rng.random();
        const f: usize = self.features;
        const fleet: *track.Fleet = self.fleet;
        const buffers: []f32 = self.gpa.alloc(f32, 2 * f + self.references + self.actions) catch
            return .{ .loss = 0, .action = 0 };
        defer self.gpa.free(buffers);
        const z: []f32 = buffers[0..f];
        const goal: []f32 = buffers[f..][0..f];
        const ref: []f32 = buffers[2 * f ..][0..self.references];
        const action: []f32 = buffers[2 * f + self.references ..][0..self.actions];
        var total: f32 = 0.0;
        var magnitude: f32 = 0.0;
        var counted: usize = 0;
        for (0..windows) |_| {
            const window: track.Replay.Window = fleet.replay.sampleWindow(random, horizon) orelse continue;
            self.world.featuresAt(fleet, window.env, window.first, z);
            for (0..horizon) |k| {
                const index: u64 = window.first + k;
                // The next goal: what the policy aims at, and what this step is scored against.
                self.goalAt(window.env, index + 1, goal);
                if (use_policy) {
                    self.policyRow(z, goal, action);
                    // Reported in radians: the fleet's scale is what turns an action into an offset.
                    for (action) |a| {
                        magnitude += @abs(a) * fleet.options.action_scale;
                    }
                } else {
                    @memset(action, 0.0);
                }
                self.world.referenceAt(fleet, window.env, index, ref);
                self.world.stepRow(z, ref, action);
                var squared: f32 = 0.0;
                for (z, goal) |x, y| {
                    squared += (x - y) * (x - y);
                }
                total += squared / float(f);
                counted += 1;
            }
        }
        const n: f32 = float(@max(counted, 1));
        return .{ .loss = total / n, .action = magnitude / (n * float(self.actions)) };
    }

    /// Mean time to failure, in seconds, of the policy acting WITHOUT noise on a judge fleet built
    /// like the training one - or of the servo alone, when `servo_only`. Null if nothing failed.
    pub fn judge(self: *Learner, steps: usize, seed: u64, servo_only: bool) !?f32 {
        const trained: *track.Fleet = self.fleet;
        var options: track.Fleet.Options = trained.options;
        options.seed = seed;
        const judge_fleet: *track.Fleet = try .init(self.gpa, trained.m, trained.clips, options);
        defer judge_fleet.deinit();
        const saved: *track.Fleet = self.fleet;
        self.fleet = judge_fleet;
        defer self.fleet = saved;
        if (servo_only) {
            @memset(self.fleet_actions, 0.0);
            for (0..steps) |_| {
                _ = judge_fleet.step(self.fleet_actions);
            }
        } else {
            self.act(steps, 0.0);
        }
        if (judge_fleet.failed == 0) {
            return null;
        }
        return float(steps * judge_fleet.options.envs) / float(judge_fleet.failed) / 60.0;
    }
};

/// The policy's raw action for one character, from its parameters alone - the body of
/// `Learner.policyRow`, free-standing so the GPU's version is checked against the very code the CPU
/// learner acts with. The first layer sums the state and goal terms INTERLEAVED, one input index at a
/// time; the kit's stacked layer sums the goal block and then the state block, so the two agree to
/// rounding, not to the bit.
pub fn policyWith(
    params: [7]Tensor,
    hidden1: []f32,
    hidden2: []f32,
    z: []const f32,
    goal: []const f32,
    out: []f32,
) void {
    const h: usize = hidden1.len;
    const actions: usize = out.len;
    const p = params;
    for (0..h) |j| {
        var sum: f32 = p[2].data[j];
        for (z, goal, 0..) |x, y, i| {
            sum += x * p[0].data[i * h + j] + y * p[1].data[i * h + j];
        }
        hidden1[j] = zm.tanh(sum);
    }
    for (0..h) |j| {
        var sum: f32 = p[4].data[j];
        for (hidden1, 0..) |x, i| {
            sum += x * p[3].data[i * h + j];
        }
        hidden2[j] = zm.tanh(sum);
    }
    for (out, 0..) |*o, j| {
        var sum: f32 = p[6].data[j];
        for (hidden2, 0..) |x, i| {
            sum += x * p[5].data[i * actions + j];
        }
        o.* = sum;
    }
}

// -------- Tests: the learner --------

const codecs = @import("codecs.zig");
const mjcf = @import("mjcf.zig");
const robot_mjcf = @import("robot_mjcf.zig");

const flex2_xml: []const u8 = @embedFile("tests/fixtures/robot/humanoid_flex2.xml");

// Both tests are MEASUREMENTS as much as checks, sized to run in about a minute each: 8 characters,
// networks 64 wide, batches of 16, a few hundred updates. They assert only what that budget can
// honestly show - the mechanism works and its gain carries - not how far training can go; the GPU
// version, with a real budget, answers that.

test "robot_track_st: past the window - the policy's gain carries beyond what it trained on" {
    // Trained through 8-step windows, judged over 24 - three windows long - inside the model and
    // against doing nothing, with the world model trained first and then left alone, so only the
    // policy changes. ASSERTED: better than doing nothing at 24 steps, though the policy never saw more
    // than 8 steps of consequences - which is why this file does without SHAC's critic (see the header).
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var setup: WalkSetup = undefined;
    try setup.init(gpa, threaded.io(), 8);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const learner: *Learner = try .init(gpa, fleet, .{
        .hidden = 64,
        .window = 8,
        .batch = 16,
        .w_action = 0.1,
        .world = .{ .hidden = 64, .steps = 8, .batch = 16 },
    });
    defer learner.deinit();
    // The world model first; after this it is never trained again, so it stays fixed while the
    // policy learns through it.
    for (0..200) |_| {
        _ = (try learner.world.trainStep(fleet)) orelse return error.NoData;
    }
    for (0..60) |_| {
        _ = (try learner.trainPolicy()) orelse return error.NoData;
    }
    const nothing_8: f32 = learner.modelLoss(100, 11, false, 8).loss;
    const policy_8: f32 = learner.modelLoss(100, 11, true, 8).loss;
    const nothing_24: f32 = learner.modelLoss(100, 11, false, 24).loss;
    const policy_24: f32 = learner.modelLoss(100, 11, true, 24).loss;
    report.print("\n  past the window, in the model: 8 steps nothing {d:.3} policy {d:.3}; " ++
        "24 steps nothing {d:.3} policy {d:.3}\n", .{ nothing_8, policy_8, nothing_24, policy_24 });
    try expect(policy_24 < nothing_24);
}

test "robot_track_st: the policy learns through the model, and is judged in the simulator" {
    // T8d's mechanism, and an honest report of where it stands in reality.
    //
    // ASSERTED: on fixed held-out windows, with no noise, the trained policy tracks the reference
    // better than doing nothing - INSIDE the model. Deterministic, so a real check: it fails if
    // gradients do not flow from the tracking loss through the model into the policy.
    //
    // REPORTED, not asserted: the same policy against the servo alone in the REAL simulator, by mean
    // time to failure on a fresh fleet it never trained on. At this budget the difference is within
    // the noise either way - asserting it would be a coin toss dressed as a test.
    //
    // THE LESSON behind the world model being trained first: a policy trained through a model can only
    // be as right as the model. Trained alongside from scratch, on data whose actions barely vary, the
    // model cannot say what an action does, and the policy learns to exploit its mistakes.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var setup: WalkSetup = undefined;
    try setup.init(gpa, threaded.io(), 8);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const learner: *Learner = try .init(gpa, fleet, .{
        .hidden = 64,
        .window = 8,
        .batch = 16,
        .w_action = 0.1,
        .world = .{ .hidden = 64, .steps = 8, .batch = 16 },
    });
    defer learner.deinit();
    for (0..200) |_| {
        _ = (try learner.world.trainStep(fleet)) orelse return error.NoData;
    }
    // SuperTrack's loop, on a small budget: collect, train the world, train the policy.
    var first_policy_loss: f32 = 0.0;
    var last_policy_loss: f32 = 0.0;
    var world_loss: f32 = 0.0;
    const rounds: usize = 8;
    for (0..rounds) |round| {
        learner.act(32, 1.0);
        for (0..8) |_| {
            world_loss = (try learner.world.trainStep(fleet)) orelse return error.NoData;
        }
        for (0..8) |step| {
            const loss: f32 = (try learner.trainPolicy()) orelse return error.NoData;
            if (round == 0 and step == 0) {
                first_policy_loss = loss;
            }
            last_policy_loss = loss;
        }
    }
    const servo: ?f32 = try learner.judge(300, 99, true);
    const policy: ?f32 = try learner.judge(300, 99, false);
    const in_model_zero: InModel = learner.modelLoss(100, 7, false, 8);
    const in_model_policy: InModel = learner.modelLoss(100, 7, true, 8);
    report.print("\n  T8d (walk, {d} rounds): policy loss {d:.3} -> {d:.3}, world loss {d:.3}\n", .{
        rounds,
        first_policy_loss,
        last_policy_loss,
        world_loss,
    });
    report.print("  mean time to failure in the REAL simulator: servo {?d:.2} s, policy {?d:.2} s\n", .{
        servo,
        policy,
    });
    report.print("  tracking loss IN THE MODEL, same windows, no noise: nothing {d:.3}, policy {d:.3} " ++
        "(actions {d:.4} rad on average)\n", .{ in_model_zero.loss, in_model_policy.loss, in_model_policy.action });
    try expect(in_model_policy.loss < in_model_zero.loss);
}

/// The walk the SuperTrack tests train on, a fleet on it, and a first helping of data. The clip is
/// loaded BAKED (`zig build clip-bake`: retargeted, filtered and lifted exactly as these tests once did
/// at startup, so the same clip number for number) - a test spends its time learning, not on half a
/// minute of inverse kinematics.
const WalkSetup = struct {
    gpa: Allocator,
    doc: codecs.xml.Document,
    robot: mjcf.Robot,
    imported: robot_mjcf.Imported,
    walk: dance.Clip,
    fleet: *track.Fleet,

    fn init(self: *WalkSetup, gpa: Allocator, io: std.Io, envs: usize) !void {
        // whole-init-first: the whole struct first - defaults applied, every field named.
        self.* = .{
            .gpa = undefined,
            .doc = undefined,
            .robot = undefined,
            .imported = undefined,
            .walk = undefined,
            .fleet = undefined,
        };
        self.gpa = gpa;
        self.doc = try codecs.xml.parse(gpa, flex2_xml, null);
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
        const baked: []u8 = readFile(gpa, io, "assets/lafan1/walk1_subject2.zclip") catch return error.SkipZigTest;
        defer gpa.free(baked);
        self.walk = try dance.Clip.fromBytes(gpa, baked);
        errdefer self.walk.deinit();
        // The policy's authority: 0.3 rad of pose offset per unit of its output.
        const fleet_options: track.Fleet.Options = .{ .envs = envs, .capacity = 256, .action_scale = 0.3 };
        self.fleet = try .init(gpa, &self.imported.model, &.{&self.walk}, fleet_options);
        errdefer self.fleet.deinit();
        // A first helping of data - wide enough (0.1 of the authority) that the world model sees what an
        // action DOES - for its normaliser and first steps.
        const noise: []f32 = try gpa.alloc(f32, envs * track.actionSize(&self.imported.model));
        defer gpa.free(noise);
        var rng: std.Random.DefaultPrng = .init(5);
        for (0..150) |_| {
            for (noise) |*a| {
                a.* = 0.1 * rng.random().floatNorm(f32);
            }
            _ = self.fleet.step(noise);
        }
    }

    fn deinit(self: *WalkSetup) void {
        self.fleet.deinit();
        self.walk.deinit();
        self.imported.deinit();
        self.robot.deinit();
        self.doc.deinit();
    }
};

fn readFile(gpa: Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file: std.Io.File = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const info: std.Io.File.Stat = try file.stat(io);
    const bytes: []u8 = try gpa.alloc(u8, info.size);
    errdefer gpa.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);
    return bytes;
}
