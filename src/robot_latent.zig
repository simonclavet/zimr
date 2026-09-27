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
const assertf = zm.assertf;

pub const WorldOptions = struct {
    hidden: usize = 256,
    /// How many steps each training window is rolled out for - T6d's trustworthy horizon.
    steps: usize = 8,
    /// Windows per training step.
    batch: usize = 32,
    rate: f32 = 1.0e-3,
    seed: u64 = 1,
    /// Measure the feature normaliser from the fleet's REFERENCE CLIPS (the paper's way, plan F4 -
    /// `measureClipNormalizer`) instead of from whatever the replay holds when the model is built (a few
    /// seconds of the servo falling). Off by default so earlier measurements reproduce; pages and the night
    /// turn it on.
    normalize_from_clips: bool = false,
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
        self.norm = if (options.normalize_from_clips)
            try measureClipNormalizer(owned, fleet.m, fleet.clips)
        else
            try measureNormalizer(owned, fleet);

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
        self.targetsOf(clip, fleet.replay.frameAt(env, index), out);
    }

    /// The encoded targets of a step that STARTS at `frame` of `clip` - the pose the servo aimed at during it:
    /// the NEXT frame, clamped exactly as the fleet's `driveOnce` clamps it (the world model must see the target
    /// that was actually used). For a recorded step (`referenceAt`) and a live one (`Learner.diagnose`) alike.
    pub fn targetsOf(
        self: *LatentWorld,
        clip: *const dance.Clip,
        frame: u32,
        out: []f32,
    ) void {
        const aimed: usize = @min(@as(usize, frame) + 1, clip.frame_count - 1);
        const root_len: usize = clip.nq - self.m.nq;
        track.encodeTargets(self.m, clip.pose(aimed)[root_len..], out);
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

/// Running first and second moments of the feature vectors, and the Normalizer they give - ONE definition of the
/// statistics (and of the spread's floor) for every way a normaliser is measured.
const Moments = struct {
    sum: []f64,
    squares: []f64,
    count: usize = 0,

    fn init(gpa: Allocator, features: usize) !Moments {
        const sum: []f64 = try gpa.alloc(f64, features);
        errdefer gpa.free(sum);
        const squares: []f64 = try gpa.alloc(f64, features);
        @memset(sum, 0.0);
        @memset(squares, 0.0);
        return .{ .sum = sum, .squares = squares };
    }

    fn deinit(self: *Moments, gpa: Allocator) void {
        gpa.free(self.squares);
        gpa.free(self.sum);
    }

    fn add(self: *Moments, raw: []const f32) void {
        for (raw, self.sum, self.squares) |x, *s, *q| {
            s.* += x;
            q.* += @as(f64, x) * x;
        }
        self.count += 1;
    }

    /// Mean and spread, spreads floored so a feature that never moves does not divide by nothing. The two slices
    /// are `owned`'s.
    fn normalizer(self: Moments, owned: Allocator) !Normalizer {
        if (self.count == 0) {
            return error.NoData;
        }
        const f: usize = self.sum.len;
        const mean: []f32 = try owned.alloc(f32, f);
        errdefer owned.free(mean);
        const spread: []f32 = try owned.alloc(f32, f);
        const n: f64 = @floatFromInt(self.count);
        for (mean, spread, self.sum, self.squares) |*mu, *sigma, s, q| {
            const average: f64 = s / n;
            mu.* = @floatCast(average);
            sigma.* = @floatCast(@max(@sqrt(@max(q / n - average * average, 0.0)), 1.0e-3));
        }
        return .{ .mean = mean, .spread = spread };
    }
};

/// Mean and spread of every feature over everything the replay holds, spreads floored so a feature
/// that never moves does not divide by nothing. The caller owns the two slices it comes back with.
///
/// Public because the GPU learner needs the same statistics without building a CPU world model to get
/// them. The paper measures them from the reference clips instead: `measureClipNormalizer`.
pub fn measureNormalizer(owned: Allocator, fleet: *track.Fleet) !Normalizer {
    var data: rbt.Data = try rbt.Data.init(owned, fleet.m);
    defer data.deinit();
    var state: track.State = try track.State.init(owned, fleet.m.nbody);
    defer state.deinit(owned);
    const f: usize = track.localSize(fleet.m.nbody);
    const raw: []f32 = try owned.alloc(f32, f);
    defer owned.free(raw);
    var moments: Moments = try .init(owned, f);
    defer moments.deinit(owned);
    for (0..fleet.options.envs) |env| {
        const written: u64 = fleet.replay.written[env];
        const oldest: u64 = written -| @as(u64, @intCast(fleet.replay.capacity));
        var index: u64 = oldest;
        while (index < written) : (index += 1) {
            fleet.stateAt(env, index, &data, &state);
            track.local(state, fleet.root, raw);
            moments.add(raw);
        }
    }
    return moments.normalizer(owned);
}

/// The normaliser the PAPER uses (plan F4): measured from the REFERENCE - every frame of every clip, posed exactly
/// as the fleet poses a reference (`robot_track.resetToFrame`: the pose, and the velocity by backward difference),
/// in the same local features. The motion the character is meant to be in, so a normalised feature says "how far
/// from typical dancing", not "from typical falling" - and it is fixed before the first step, whatever a warm-up
/// happened to do. The caller owns the two slices.
pub fn measureClipNormalizer(
    owned: Allocator,
    m: *rbt.Model,
    clips: []const *const dance.Clip,
) !Normalizer {
    var data: rbt.Data = try rbt.Data.init(owned, m);
    defer data.deinit();
    var state: track.State = try track.State.init(owned, m.nbody);
    defer state.deinit(owned);
    const f: usize = track.localSize(m.nbody);
    const raw: []f32 = try owned.alloc(f32, f);
    defer owned.free(raw);
    var moments: Moments = try .init(owned, f);
    defer moments.deinit(owned);
    const root: usize = track.rootBody(m);
    for (clips) |clip| {
        // Frame 0 has no frame before it to difference against; `resetToFrame` starts at 1 for the same reason.
        for (1..clip.frame_count) |frame| {
            track.resetToFrame(m, &data, clip, frame);
            track.stateOf(m, &data, &state);
            track.local(state, root, raw);
            moments.add(raw);
        }
    }
    return moments.normalizer(owned);
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
    /// THE POLICY'S CLOCK (plan F4e): a new decision every `decide_every` physics steps, held in between - 2 is 30 Hz
    /// at our 60 Hz physics (DReCon's k = 2; Simon's choice). Everywhere the policy acts - collecting (`act`), its
    /// training rollouts through the model, `modelLoss`, the judge (`judgeActor`), `diagnose` - decisions fall on the
    /// even steps of an episode, counted from its start. The world model stays per physics step: it learns from the
    /// action actually APPLIED each step, held or not, which is what the replay records. 1: every step (as before).
    decide_every: u32 = 1,
    /// SIMON'S FILTER (plan F6, `robot_track.filterAction`): each decision blended into the action already applied,
    /// `applied = filter * asked + (1 - filter) * applied` - DReCon's 0.2. Everywhere the policy acts, and inside the
    /// training rollouts through the model, where it is differentiated exactly: a decision's effect on every later
    /// step's applied action reaches its gradient. The world model learns from what was APPLIED - the filtered
    /// action the servo received, which is what the replay records. From rest at an episode's first step.
    /// 1: no filter (as before; the graph then has no filter ops at all).
    filter: f32 = 1.0,
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

/// Plan F2's numbers (`Learner.diagnose`), all mean squared distances per feature, in normalised units, averaged
/// over the steps compared.
pub const Diagnosis = struct {
    horizon: usize,
    compared_steps: usize = 0,
    /// Real tracking losses - zero action (a) and the policy (b).
    real_zero: f32 = 0.0,
    real_policy: f32 = 0.0,
    /// The tracking losses the WORLD MODEL predicts - zero action (c) and the policy acting on it (e).
    model_zero: f32 = 0.0,
    model_policy: f32 = 0.0,
    /// How far the model's open-loop rollout lands from the real one, on the policy's recorded actions (d vs b) and
    /// on zero action (c vs a).
    follow_error: f32 = 0.0,
    follow_error_zero: f32 = 0.0,

    /// TRUST: the model's error following where the policy really went, over the trivial predictor's ("it tracks
    /// the reference" - whose error on those same states IS their tracking loss). Under 1: the model knows
    /// something beyond "it tracks"; over 1: worse than assuming it does - a policy trained through it learns from
    /// fiction.
    pub fn trust(self: Diagnosis) f32 {
        return self.follow_error / @max(self.real_policy, 1.0e-9);
    }

    /// EXPLOITATION: what the model thinks the policy gains over doing nothing, minus what it really gains, as a
    /// share of the real zero-action loss. Near 0: the model's promises are kept. Positive: it over-promises - the
    /// policy found where the model is wrong in its favour.
    pub fn exploitation(self: Diagnosis) f32 {
        const promised: f32 = self.model_zero - self.model_policy;
        const delivered: f32 = self.real_zero - self.real_policy;
        return (promised - delivered) / @max(self.real_zero, 1.0e-9);
    }
};

fn meanSquare(x: []const f32, y: []const f32) f32 {
    var sum: f32 = 0.0;
    for (x, y) |u, v| {
        sum += (u - v) * (u - v);
    }
    return sum / float(x.len);
}

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
    /// The action each rollout step APPLIED - a decision's, or the one held from it (F4e); for tests and diagnostics.
    step_actions: []Var,
    /// Per row: the action applied on the replay step before the window - the filter's starting state (F6).
    applied_start: Var,
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
        // The action path's settings, refused when they are nonsense rather than quietly bent: a filter of 0 would
        // freeze every action at rest - the policy could never move the character, and nothing would say so.
        const filter: f32 = options.filter;
        assertf(filter > 0.0 and filter <= 1.0, @src(), "filter {d} is not in (0, 1]", .{filter});
        assertf(options.decide_every >= 1, @src(), "decide_every must be at least 1", .{});
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
            .step_actions = undefined,
            .applied_start = undefined,
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
        self.step_actions = try owned.alloc(Var, steps);
        self.applied_start = try g.constant(try filled(owned, &.{ b, a }, 0.0));
        var z: Var = self.start;
        var total: ?Var = null;
        var previous: ?Var = null;
        // What is being applied: the filter's state (F6), from the window's start; replaced at every decision.
        var applied: Var = self.applied_start;
        const every: usize = @max(options.decide_every, 1);
        for (0..steps) |k| {
            self.refs[k] = try g.constant(try filled(owned, &.{ b, r }, 0.0));
            self.noise[k] = try g.constant(try filled(owned, &.{ b, a }, 0.0));
            const deciding: bool = k % every == 0;
            // A DECISION: the policy sees where the reference is going - the goal this step is scored against
            // (SuperTrack's Local(K_{i+1})), not where it was. Between decisions the same noisy action is applied
            // again (the clock, F4e) - the same Var, so its gradient collects every step it acted on.
            const raw: Var = if (deciding)
                try policyOnGraph(g, self.vars, z, self.goals[k + 1], ones)
            else
                previous.?;
            // What the fleet records, and so what the world model learned from: the action APPLIED - the raw action
            // plus its noise, blended into what was applied by the filter (`robot_track.filterAction`, written with
            // tensors - through it a decision's gradient reaches every later step it still shapes), unscaled: the
            // fleet scales it into a PD offset. No filter ops at all when there is no filter.
            if (deciding) {
                const noisy: Var = try g.add(raw, try g.scale(self.noise[k], options.sigma));
                applied = if (options.filter == 1.0)
                    noisy
                else
                    try g.add(try g.scale(noisy, options.filter), try g.scale(applied, 1.0 - options.filter));
            }
            self.step_actions[k] = applied;
            z = try LatentWorld.step(g, self.world_vars, z, self.refs[k], applied, ones);
            var term: Var = try g.mseLoss(z, self.goals[k + 1]);
            // The penalties are on DECISIONS: a held step is not a second choice to price.
            if (!deciding) {
                total = if (total) |t| try g.add(t, term) else term;
                continue;
            }
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
        self.liveFeaturesOf(self.fleet, env);
    }

    /// The same for a character of ANY fleet on this model (a judge's). Left in `z_sim` and `z_ref`.
    fn liveFeaturesOf(self: *Learner, fleet: *track.Fleet, env: usize) void {
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
        const a: usize = self.actions;
        for (0..steps) |_| {
            for (0..self.fleet.options.envs) |env| {
                // Between decisions the last one is held: its slot is left as it is (noise and all).
                if (!self.decides(self.fleet, env)) {
                    continue;
                }
                self.decideInto(self.fleet, env, noise_scale, self.fleet_actions[env * a ..][0..a]);
            }
            _ = self.fleet.step(self.fleet_actions);
        }
    }

    /// ONE DECISION for `env` of `fleet` (the clock, F4e, says when): the policy's action for its live state, plus
    /// `noise_scale * sigma` exploration, blended by Simon's filter (F6) into `slot` - the action this environment
    /// has been applying, and will apply until the next decision; from REST at an episode's first step. Collecting,
    /// the judge and `diagnose` all decide through here, so they cannot disagree about what a decision is.
    fn decideInto(
        self: *Learner,
        fleet: *track.Fleet,
        env: usize,
        noise_scale: f32,
        slot: []f32,
    ) void {
        self.liveFeaturesOf(fleet, env);
        self.policyRow(self.z_sim, self.z_ref, self.out);
        // No draw at all when there is no noise: judging must not consume the training's random stream, or a judged
        // run would train differently afterwards.
        if (noise_scale != 0.0) {
            const random: std.Random = self.rng.random();
            const spread: f32 = noise_scale * self.options.sigma;
            for (self.out) |*o| {
                o.* += spread * random.floatNorm(f32);
            }
        }
        // Never a non-finite action into the physics: NaN targets make NaN bodies, never "terminated".
        for (self.out) |*o| {
            if (!(o.* == o.* and @abs(o.*) < 1.0e30)) {
                o.* = 0.0;
            }
        }
        if (fleet.steps[env] == 0) {
            @memset(slot, 0.0);
        }
        track.filterAction(self.options.filter, self.out, slot);
    }

    /// The action APPLIED on the step before `first` in `env`'s replay - the filter's state a training window starts
    /// from (F6) - or REST when that step is in another segment (a reset begins one; so does a shove, where DReCon's
    /// filter would not reset - the first night has none) or has already left the ring.
    fn appliedBefore(fleet: *const track.Fleet, env: usize, first: u64, out: []f32) void {
        const replay: track.Replay = fleet.replay;
        const oldest: u64 = replay.written[env] -| @as(u64, @intCast(replay.capacity));
        const before_in_ring: bool = first > 0 and first - 1 >= oldest;
        if (!before_in_ring or replay.segmentAt(env, first - 1) != replay.segmentAt(env, first)) {
            @memset(out, 0.0);
            return;
        }
        @memcpy(out, replay.actionAt(env, first - 1));
    }

    /// The reference's normalised features at a recorded step's frame.
    fn goalAt(self: *Learner, env: usize, index: u64, out: []f32) void {
        const fleet: *track.Fleet = self.fleet;
        self.goalOfFrame(fleet.replay.clipAt(env, index), fleet.replay.frameAt(env, index), out);
    }

    /// The reference's normalised features at a clip's frame - all a goal depends on.
    fn goalOfFrame(self: *Learner, clip_index: u16, frame: u32, out: []f32) void {
        self.goalOf(self.fleet, clip_index, frame, out);
    }

    /// The same for a clip of ANY fleet on this model - a judge's fleet holds one clip, whose index is not the
    /// training fleet's.
    fn goalOf(
        self: *Learner,
        fleet: *track.Fleet,
        clip_index: usize,
        frame: u32,
        out: []f32,
    ) void {
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
        appliedBefore(fleet, window.env, window.first, g.valueOf(self.applied_start).data[row * a ..][0..a]);
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
        const buffers: []f32 = self.gpa.alloc(f32, 2 * f + self.references + 2 * self.actions) catch
            return .{ .loss = 0, .action = 0 };
        defer self.gpa.free(buffers);
        const z: []f32 = buffers[0..f];
        const goal: []f32 = buffers[f..][0..f];
        const ref: []f32 = buffers[2 * f ..][0..self.references];
        const action: []f32 = buffers[2 * f + self.references ..][0..self.actions];
        // What the filter has been applying (F6) - from the replay's step before the window, as training starts it.
        const applied: []f32 = buffers[2 * f + self.references + self.actions ..][0..self.actions];
        var total: f32 = 0.0;
        var magnitude: f32 = 0.0;
        var counted: usize = 0;
        for (0..windows) |_| {
            const window: track.Replay.Window = fleet.replay.sampleWindow(random, horizon) orelse continue;
            self.world.featuresAt(fleet, window.env, window.first, z);
            appliedBefore(fleet, window.env, window.first, applied);
            for (0..horizon) |k| {
                const index: u64 = window.first + k;
                // The next goal: what the policy aims at, and what this step is scored against.
                self.goalAt(window.env, index + 1, goal);
                if (use_policy) {
                    // The clock (F4e): a decision every `decide_every` steps of the window, held in between -
                    // blended into what was applied by the filter (F6).
                    if (k % @max(self.options.decide_every, 1) == 0) {
                        self.policyRow(z, goal, action);
                        track.filterAction(self.options.filter, action, applied);
                    }
                    // Reported in radians: the fleet's scale is what turns an action into an offset.
                    for (applied) |a| {
                        magnitude += @abs(a) * fleet.options.action_scale;
                    }
                } else {
                    @memset(applied, 0.0);
                }
                self.world.referenceAt(fleet, window.env, index, ref);
                self.world.stepRow(z, ref, applied);
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

    /// The JUDGE's actor (plan F1) for the CPU learner: the policy's mean action - no exploration - for every
    /// character of the judge's fleet. Borrows only the learner's scratch (`z_sim`, `z_ref`, `out`): its own fleet,
    /// replay and random stream are untouched, so a judged run trains exactly as an unjudged one.
    pub fn judgeActor(self: *Learner) track.Actor {
        return .{ .context = self, .act = actOnJudgedFleet };
    }

    fn actOnJudgedFleet(context: *anyopaque, fleet: *track.Fleet, actions: []f32) void {
        const self: *Learner = @ptrCast(@alignCast(context));
        const a: usize = self.actions;
        for (0..fleet.options.envs) |env| {
            // Held between decisions: the judge keeps its action buffer from step to step, so leaving the slot
            // alone IS holding it.
            if (!self.decides(fleet, env)) {
                continue;
            }
            self.decideInto(fleet, env, 0.0, actions[env * a ..][0..a]);
        }
    }

    /// Whether `env` of `fleet` takes a new decision on the step about to be taken (F4e's clock): on the even steps of
    /// its episode, counted from its start - `steps` is 0 on an episode's first step, so every episode opens with one.
    fn decides(self: *const Learner, fleet: *const track.Fleet, env: usize) bool {
        return fleet.steps[env] % @max(self.options.decide_every, 1) == 0;
    }

    /// Plan F2: how far the world model can be TRUSTED where the policy goes, and how much the policy EXPLOITS it -
    /// measured on the judge's fixed starts over their first `horizon` steps, so the numbers are comparable from one
    /// evaluation to the next. Five rollouts from every start:
    ///
    ///     a  the real simulator, zero action          c  the world model, open loop, zero action
    ///     b  the real simulator, the policy acting    d  the world model, open loop, b's recorded actions
    ///                                                 e  the world model, closed loop, the policy acting on it
    ///
    /// Trust compares d with b - can the model follow where the policy ACTUALLY goes? - against the trivial
    /// predictor "it tracks the reference", whose error on b is b's own tracking loss. Exploitation compares what
    /// the model thinks the policy gains (c - e) with what it really gains (a - b). The judge's rollouts are new
    /// trajectories, never in the replay: held out by construction. Every start compares only the steps BOTH its
    /// real rollouts lived (a model never falls; a fallen character has nothing left to compare).
    pub fn diagnose(
        self: *Learner,
        clip: *const dance.Clip,
        starts: []const usize,
        horizon: usize,
    ) !Diagnosis {
        const f: usize = self.features;
        const a: usize = self.actions;
        const r: usize = self.references;
        const n: usize = starts.len;
        const options: track.Fleet.Options = self.fleet.options;
        var zero: track.Judging = try .init(self.gpa, self.fleet.m, clip, options, starts);
        defer zero.deinit();
        var acting: track.Judging = try .init(self.gpa, self.fleet.m, clip, options, starts);
        defer acting.deinit();

        // Per start: its first state, the real states after each step of a and b, b's actions, and how many
        // steps each real rollout lived.
        const first: []f32 = try self.gpa.alloc(f32, n * f);
        defer self.gpa.free(first);
        const states_a: []f32 = try self.gpa.alloc(f32, n * horizon * f);
        defer self.gpa.free(states_a);
        const states_b: []f32 = try self.gpa.alloc(f32, n * horizon * f);
        defer self.gpa.free(states_b);
        const actions_b: []f32 = try self.gpa.alloc(f32, n * horizon * a);
        defer self.gpa.free(actions_b);
        const lived: []usize = try self.gpa.alloc(usize, 2 * n);
        defer self.gpa.free(lived);
        @memset(lived, horizon);
        const ended: []bool = try self.gpa.alloc(bool, 2 * n);
        defer self.gpa.free(ended);
        @memset(ended, false);

        // The real rollouts, side by side. The policy acts on b's features; they are also what gets recorded, and
        // the next step's action is taken from them.
        for (0..n) |s| {
            self.liveFeaturesOf(acting.fleet, s);
            @memcpy(first[s * f ..][0..f], self.z_sim);
        }
        for (0..horizon) |k| {
            for (0..n) |s| {
                if (self.decides(acting.fleet, s)) {
                    self.decideInto(acting.fleet, s, 0.0, acting.actions[s * a ..][0..a]);
                }
                @memcpy(actions_b[(s * horizon + k) * a ..][0..a], acting.actions[s * a ..][0..a]);
            }
            _ = zero.fleet.step(zero.actions);
            _ = acting.fleet.step(acting.actions);
            for (0..n) |s| {
                const pairs = [_]struct { judging: *track.Judging, states: []f32, slot: usize }{
                    .{ .judging = &zero, .states = states_a, .slot = s },
                    .{ .judging = &acting, .states = states_b, .slot = n + s },
                };
                for (pairs) |pair| {
                    if (ended[pair.slot]) {
                        continue;
                    }
                    // An episode that ended on this step has ALREADY been restarted by the fleet: its live state
                    // is the next episode's start. So it lived k steps - this one is not compared.
                    if (pair.judging.fleet.dones[s]) {
                        ended[pair.slot] = true;
                        lived[pair.slot] = k;
                        continue;
                    }
                    self.liveFeaturesOf(pair.judging.fleet, s);
                    @memcpy(pair.states[(s * horizon + k) * f ..][0..f], self.z_sim);
                }
            }
        }

        // The model's rollouts, and every comparison, over the steps both real rollouts lived.
        const scratch: []f32 = try self.gpa.alloc(f32, 3 * f + f + r + 2 * a);
        defer self.gpa.free(scratch);
        const z_c: []f32 = scratch[0..f];
        const z_d: []f32 = scratch[f..][0..f];
        const z_e: []f32 = scratch[2 * f ..][0..f];
        const goal: []f32 = scratch[3 * f ..][0..f];
        const ref: []f32 = scratch[4 * f ..][0..r];
        const action: []f32 = scratch[4 * f + r ..][0..a];
        // The model's closed loop keeps the filter's state too (F6): what it has been applying.
        const applied_e: []f32 = scratch[4 * f + r + a ..][0..a];
        const no_action: []f32 = try self.gpa.alloc(f32, a);
        defer self.gpa.free(no_action);
        @memset(no_action, 0.0);
        var out: Diagnosis = .{ .horizon = horizon };
        for (starts, 0..) |start, s| {
            const steps: usize = @min(lived[s], lived[n + s]);
            @memcpy(z_c, first[s * f ..][0..f]);
            @memcpy(z_d, z_c);
            @memcpy(z_e, z_c);
            @memset(applied_e, 0.0); // every judged episode starts at its step 0: the filter at rest
            for (0..steps) |k| {
                const frame: u32 = @intCast(start + k);
                self.goalOf(zero.fleet, 0, frame + 1, goal);
                self.world.targetsOf(clip, frame, ref);
                self.world.stepRow(z_c, ref, no_action);
                self.world.stepRow(z_d, ref, actions_b[(s * horizon + k) * a ..][0..a]);
                // The model's own closed loop keeps the clock too: a decision every `decide_every` steps from the
                // start (the judge's fleet starts every episode at step 0), held in between.
                if (k % @max(self.options.decide_every, 1) == 0) {
                    self.policyRow(z_e, goal, action);
                    track.filterAction(self.options.filter, action, applied_e);
                }
                self.world.stepRow(z_e, ref, applied_e);
                const real_a: []const f32 = states_a[(s * horizon + k) * f ..][0..f];
                const real_b: []const f32 = states_b[(s * horizon + k) * f ..][0..f];
                out.real_zero += meanSquare(real_a, goal);
                out.real_policy += meanSquare(real_b, goal);
                out.model_zero += meanSquare(z_c, goal);
                out.model_policy += meanSquare(z_e, goal);
                out.follow_error += meanSquare(z_d, real_b);
                out.follow_error_zero += meanSquare(z_c, real_a);
            }
            out.compared_steps += steps;
        }
        const count: f32 = float(@max(out.compared_steps, 1));
        out.real_zero /= count;
        out.real_policy /= count;
        out.model_zero /= count;
        out.model_policy /= count;
        out.follow_error /= count;
        out.follow_error_zero /= count;
        return out;
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

test "robot_latent: diagnose - a silent policy exploits nothing, the numbers repeat, training untouched" {
    // Plan F2's known answers. With every policy weight zero the policy's action is exactly zero, so the real
    // rollouts with and without it are the same trajectory, and so are the model's: the model promises nothing,
    // the simulator delivers nothing - exploitation EXACTLY 0, and following the policy's actions is following
    // zero. Two diagnoses are identical; a live policy's real rollout differs from the servo's; and diagnosing
    // borrows only scratch - the learner's own fleet is where it was.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var setup: WalkSetup = undefined;
    setup.init(gpa, threaded.io(), 4) catch return error.SkipZigTest;
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const learner: *Learner = try .init(gpa, fleet, .{
        .hidden = 16,
        .window = 8,
        .batch = 4,
        .world = .{ .hidden = 16, .steps = 8, .batch = 4 },
    });
    defer learner.deinit();
    const clip: *const dance.Clip = fleet.clips[0];
    const starts: []usize = try track.evenStarts(gpa, clip, 120);
    defer gpa.free(starts);

    const frames_before: []u32 = try gpa.dupe(u32, fleet.frame);
    defer gpa.free(frames_before);
    const fleet_rng_before: @TypeOf(fleet.rng) = fleet.rng;
    const live: Diagnosis = try learner.diagnose(clip, starts, 16);
    const again: Diagnosis = try learner.diagnose(clip, starts, 16);
    try expect(std.meta.eql(live, again));
    try expect(live.compared_steps > 0);
    try expect(live.real_policy != live.real_zero); // a live policy acts
    try expect(std.mem.eql(u32, fleet.frame, frames_before));
    try expect(std.meta.eql(fleet.rng, fleet_rng_before));

    for (learner.params) |tensor| {
        @memset(tensor.data, 0.0);
    }
    const silent: Diagnosis = try learner.diagnose(clip, starts, 16);
    try expect(silent.real_policy == silent.real_zero);
    try expect(silent.model_policy == silent.model_zero);
    try expect(silent.follow_error == silent.follow_error_zero);
    try expect(silent.exploitation() == 0.0);
}

test "robot_latent: the clip's own normaliser makes its frames mean 0, spread 1" {
    // Plan F4's known answer, exact by definition: a normaliser measured from a clip's frames, applied to those same
    // frames, gives every feature mean 0 and variance 1 - except features that never move, whose spread is floored
    // (they come out exactly 0). Measured twice, it is identical: nothing in it depends on a fleet's history.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var setup: WalkSetup = undefined;
    setup.init(gpa, threaded.io(), 2) catch return error.SkipZigTest;
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const m: *rbt.Model = fleet.m;
    const norm: Normalizer = try measureClipNormalizer(gpa, m, fleet.clips);
    defer gpa.free(norm.mean);
    defer gpa.free(norm.spread);
    const again: Normalizer = try measureClipNormalizer(gpa, m, fleet.clips);
    defer gpa.free(again.mean);
    defer gpa.free(again.spread);
    try expect(std.mem.eql(f32, norm.mean, again.mean) and std.mem.eql(f32, norm.spread, again.spread));

    const f: usize = track.localSize(m.nbody);
    var data: rbt.Data = try rbt.Data.init(gpa, m);
    defer data.deinit();
    var state: track.State = try track.State.init(gpa, m.nbody);
    defer state.deinit(gpa);
    const raw: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(raw);
    const normal: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(normal);
    var moments: Moments = try .init(gpa, f);
    defer moments.deinit(gpa);
    const clip: *const dance.Clip = fleet.clips[0];
    for (1..clip.frame_count) |frame| {
        track.resetToFrame(m, &data, clip, frame);
        track.stateOf(m, &data, &state);
        track.local(state, track.rootBody(m), raw);
        norm.toNormal(raw, normal);
        moments.add(normal);
    }
    const count: f64 = @floatFromInt(moments.count);
    var checked: usize = 0;
    for (moments.sum, moments.squares, norm.spread) |s_sum, q, spread| {
        const mean: f64 = s_sum / count;
        const variance: f64 = q / count - mean * mean;
        try expect(@abs(mean) < 1.0e-3);
        if (spread > 1.0e-3) {
            try expect(@abs(variance - 1.0) < 1.0e-3);
            checked += 1;
        }
    }
    try expect(checked > f / 2);
}

test "robot_latent: the policy's clock - decide on even steps, hold on odd ones, everywhere it acts" {
    // Plan F4e's known answers, with decide_every = 2 (30 Hz at 60 Hz physics). Collecting: on a step that starts at
    // an odd step of its episode, every character's applied action is exactly the one before - noise included. The
    // training rollout: a held step applies the very same graph node as its decision (its gradient collects both
    // steps), and the next even step is a new one. The judge: asked on an odd step, the actor leaves the buffer as
    // it was - which is how the judge holds.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var setup: WalkSetup = undefined;
    setup.init(gpa, threaded.io(), 3) catch return error.SkipZigTest;
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const learner: *Learner = try .init(gpa, fleet, .{
        .hidden = 16,
        .window = 4,
        .batch = 2,
        .decide_every = 2,
        .world = .{ .hidden = 16, .steps = 4, .batch = 2 },
    });
    defer learner.deinit();

    // Collecting.
    const a: usize = learner.actions;
    const before: []f32 = try gpa.alloc(f32, learner.fleet_actions.len);
    defer gpa.free(before);
    const steps_before: []u32 = try gpa.alloc(u32, fleet.options.envs);
    defer gpa.free(steps_before);
    var held_checked: usize = 0;
    var decided_changed: usize = 0;
    for (0..24) |_| {
        @memcpy(before, learner.fleet_actions);
        @memcpy(steps_before, fleet.steps);
        learner.act(1, 1.0);
        for (0..fleet.options.envs) |env| {
            const now: []const f32 = learner.fleet_actions[env * a ..][0..a];
            const then: []const f32 = before[env * a ..][0..a];
            if (steps_before[env] % 2 == 1) {
                try expect(std.mem.eql(f32, now, then));
                held_checked += 1;
            } else if (!std.mem.eql(f32, now, then)) {
                decided_changed += 1;
            }
        }
    }
    try expect(held_checked > 0 and decided_changed > 0);

    // The training rollout's graph.
    try expect(learner.step_actions[1] == learner.step_actions[0]);
    try expect(learner.step_actions[3] == learner.step_actions[2]);
    try expect(learner.step_actions[2] != learner.step_actions[0]);

    // The judge's actor on an odd step.
    const clip: *const dance.Clip = fleet.clips[0];
    const starts = [_]usize{ 10, 90 };
    var judging: track.Judging = try .init(gpa, fleet.m, clip, fleet.options, &starts);
    defer judging.deinit();
    _ = judging.advance(learner.judgeActor(), 1); // one step taken: both episodes are at step 1 now
    try expect(judging.fleet.steps[0] == 1 and judging.fleet.steps[1] == 1);
    const poisoned: []f32 = try gpa.dupe(f32, judging.actions);
    defer gpa.free(poisoned);
    @memset(poisoned, 7.0);
    const actor: track.Actor = learner.judgeActor();
    actor.act(actor.context, judging.fleet, poisoned);
    for (poisoned) |value| {
        try expect(value == 7.0);
    }
}

test "robot_latent: the filter in the training graph equals the same rollout done row by row" {
    // Plan F6's known answer. With noise off, the policy's training loss - built with tensors, the filter written as
    // `filter * asked + (1 - filter) * applied` inside the graph - equals the same rollout done row by row outside
    // it: `policyRow` at each decision, `track.filterAction`, the world model's `stepRow`, from the replay's action
    // before the window (`appliedBefore`). Held steps (decide_every 2), the starting state, and every term of the
    // loss - the state error each step, the action's price each decision - are in it.
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var setup: WalkSetup = undefined;
    setup.init(gpa, threaded.io(), 3) catch return error.SkipZigTest;
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const steps: usize = 6;
    const batch: usize = 3;
    const learner: *Learner = try .init(gpa, fleet, .{
        .hidden = 16,
        .window = steps,
        .batch = batch,
        .sigma = 0.0,
        .decide_every = 2,
        .filter = 0.2,
        .world = .{ .hidden = 16, .steps = steps, .batch = batch },
    });
    defer learner.deinit();
    // Filtered, noisy actions into the replay - so windows start from a filter that is not at rest.
    learner.act(80, 1.0);

    var prng: std.Random.DefaultPrng = .init(99);
    var windows: [batch]track.Replay.Window = undefined;
    for (&windows) |*window| {
        window.* = fleet.replay.sampleWindow(prng.random(), steps) orelse return error.SkipZigTest;
    }
    const f: usize = learner.features;
    const a: usize = learner.actions;
    const r: usize = learner.references;
    const z: []f32 = try gpa.alloc(f32, batch * f);
    defer gpa.free(z);
    const applied: []f32 = try gpa.alloc(f32, batch * a);
    defer gpa.free(applied);
    const asked: []f32 = try gpa.alloc(f32, a);
    defer gpa.free(asked);
    const goal: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(goal);
    const ref: []f32 = try gpa.alloc(f32, r);
    defer gpa.free(ref);
    var any_filter_state: bool = false;
    for (windows, 0..) |window, row| {
        learner.world.featuresAt(fleet, window.env, window.first, z[row * f ..][0..f]);
        Learner.appliedBefore(fleet, window.env, window.first, applied[row * a ..][0..a]);
        for (applied[row * a ..][0..a]) |value| {
            any_filter_state = any_filter_state or value != 0.0;
        }
    }
    try expect(any_filter_state);
    // Row by row, BEFORE the graph's update touches the weights.
    var expected: f64 = 0.0;
    for (0..steps) |k| {
        const deciding: bool = k % 2 == 0;
        var state_error: f64 = 0.0;
        var action_size: f64 = 0.0;
        for (windows, 0..) |window, row| {
            const z_row: []f32 = z[row * f ..][0..f];
            const applied_row: []f32 = applied[row * a ..][0..a];
            learner.goalAt(window.env, window.first + k + 1, goal);
            if (deciding) {
                learner.policyRow(z_row, goal, asked);
                track.filterAction(0.2, asked, applied_row);
                for (asked) |x| {
                    action_size += @as(f64, x) * x;
                }
            }
            learner.world.referenceAt(fleet, window.env, window.first + k, ref);
            learner.world.stepRow(z_row, ref, applied_row);
            for (z_row, goal) |x, y| {
                state_error += (@as(f64, x) - y) * (@as(f64, x) - y);
            }
        }
        expected += state_error / float(batch * f);
        if (deciding) {
            expected += learner.options.w_action * action_size / float(batch * a);
        }
    }
    expected /= float(steps);
    const graphs: f32 = try learner.trainPolicyOn(&windows);
    try expect(@abs(graphs - expected) <= 1.0e-5 * @max(1.0, @abs(expected)));
}
