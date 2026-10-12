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
const vec = zm.vec;
const zn = @import("zn");
const rbt = @import("robot.zig");
const track = @import("robot_track.zig");
const dance = @import("robot_dance.zig");
const gym = @import("robot_gym.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Random = std.Random;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const Var = zn.Var;
const Graph = zn.Graph(f32);
const Tensor = zn.Tensor(f32);
const float = zm.float;
const nan = zm.nan;
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
    var data: rbt.Data = try .init(owned, m);
    defer data.deinit();
    var state: track.State = try .init(owned, m.nbody);
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

/// Mean and spread of every feature over everything the replay holds, spreads floored so a feature
/// that never moves does not divide by nothing. The caller owns the two slices it comes back with.
///
/// Public because the GPU learner needs the same statistics without building a CPU world model to get
/// them. The paper measures them from the reference clips instead: `measureClipNormalizer`.
pub fn measureNormalizer(owned: Allocator, fleet: *track.Fleet) !Normalizer {
    var data: rbt.Data = try .init(owned, fleet.m);
    defer data.deinit();
    var state: track.State = try .init(owned, fleet.m.nbody);
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

fn filled(
    owned: Allocator,
    shape: []const usize,
    value: f32,
) !Tensor {
    const t: Tensor = try .alloc(owned, shape);
    @memset(t.data, value);
    return t;
}

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

pub const LatentWorld = struct {
    arena: ArenaAllocator,
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
    rng: Random.DefaultPrng,
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
        self.arena = ArenaAllocator.init(gpa);
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
        self.rng = Random.DefaultPrng.init(options.seed);
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
        const random: Random = self.rng.random();
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
        self.graph = Graph.init(owned);
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
        self.adam = try gym.AdamSet.init(owned, &self.params);
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
        const random: Random = self.rng.random();
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

pub fn measurePoseDrift(
    gpa: Allocator,
    model: *LatentWorld,
    fleet: *track.Fleet,
    draws: usize,
    steps: usize,
    random: Random,
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

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

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
    /// THE POLICY SEES WHAT IT IS APPLYING (plan A1). With the filter on, the same ask means different things from
    /// different places: asking for 1.0 while 0.9 is applied is a nudge, the same 1.0 from rest is a shove - so what
    /// to ask depends on what is already being applied, and a policy that cannot see it is blind to half of its own
    /// control state (DReCon's observation carries it). On: the action being applied BEFORE a decision - the
    /// filter's state, what `decideInto`'s slot holds, rest when an episode opens - is a third input to the first
    /// layer, read by a block of its own (`applied_block`, actions x hidden) that starts at ZERO, so the policy starts
    /// out exactly as the one that cannot see it and learns to read the input as the gradient arrives. In raw action
    /// units, like the policy's output - no normaliser. Off: the seven tensors of before, which the GPU kit mirrors.
    sees_applied: bool = false,
    /// TEMPORAL SMOOTHNESS (CAPS: Mysore et al., 2021): the penalty on how far the policy's action moves from one
    /// step of a window to the next, `w_smooth * |a_k - a_(k-1)|^2`. A policy trained through a world model can
    /// learn outputs that swing wildly with small changes of state - on a character, every freedom lurching each
    /// frame, a body that looks like it is exploding. Zero (off) by default.
    w_smooth: f32 = 0.0,
    /// TWO WORLD MODELS (plan I1b - Simon's idea). A second model is trained on the same replay from a different
    /// initialisation (and, through its own random stream, on different batches), and the policy's rollouts step
    /// through the AVERAGE of the two. Where the data pins them down the two agree; where the policy wanders off
    /// the data nothing pins them, so they drift apart - which makes their disagreement a map of exactly where the
    /// model cannot be trusted, and that is where a policy exploits it (B1's exploitation ~100). Off: one model,
    /// the learner exactly as before.
    twin_world: bool = false,
    /// The price on the twins' disagreement at every step of a rollout, `w_disagree * |z1 - z2|^2` (per feature,
    /// like the tracking term): a policy pays for steering where the two models part ways, so the gradient pulls it
    /// back toward states they agree on, and it knocks nothing the models know well - where they agree it costs
    /// nothing at all. Needs `twin_world`.
    w_disagree: f32 = 0.0,
    /// The twin's seed. Null: the first model's plus one. The first model's own seed makes an exact copy - two
    /// identical models, which agree to the bit: a test's known answer.
    twin_seed: ?u64 = null,
    seed: u64 = 1,
    /// Where the noise inside the training rollouts comes from: the learner's own random stream by
    /// default; given a function, `noise(update, step, row, action)`. That is how a GPU version, drawing
    /// its noise from a hash (the kit's `latNoise`), is compared with this one step for step.
    noise: ?*const fn (update: u32, step: u32, row: u32, action: u32) f32 = null,
    world: WorldOptions = .{},

    /// What is wrong with these options, or null when nothing is: ONE definition of a learner's valid settings.
    /// `Learner.init` asserts it, and a tool that takes settings from outside (the bench) refuses with it, in words,
    /// before building anything - because a stripped assert that only logs lets a bad setting RUN: a filter of 0
    /// freezes every action at rest, and the run then reads exactly like the servo alone, as if the change did
    /// nothing. Written as `!(x > lo)` so a NaN fails too.
    pub fn problem(self: LearnerOptions) ?[]const u8 {
        if (!(self.filter > 0.0 and self.filter <= 1.0)) {
            return "the filter is not in (0, 1]";
        }
        if (self.decide_every < 1) {
            return "decide_every is under 1";
        }
        if (!(self.sigma >= 0.0)) {
            return "sigma is negative";
        }
        if (!(self.w_disagree >= 0.0)) {
            return "w_disagree is negative";
        }
        if (self.w_disagree > 0.0 and !self.twin_world) {
            return "w_disagree prices a disagreement, and without twin_world there is only one model";
        }
        const sized: bool = self.hidden > 0 and self.window > 0 and self.batch > 0;
        const world_sized: bool = self.world.hidden > 0 and self.world.steps > 0 and self.world.batch > 0;
        if (!sized or !world_sized) {
            return "a width, window or batch is zero";
        }
        return null;
    }
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

/// What the policy is applying, for one character (A1): the first layer's block for it (actions x hidden) and the
/// action itself. One value, so the row form cannot be handed one without the other either.
pub const AppliedRow = struct {
    weights: Tensor,
    action: []const f32,
};

/// The policy's raw action for one character, from its parameters alone - the body of
/// `Learner.policyRow`, free-standing so the GPU's version is checked against the very code the CPU
/// learner acts with. The first layer sums the state and goal terms INTERLEAVED, one input index at a
/// time; the kit's stacked layer sums the goal block and then the state block, so the two agree to
/// rounding, not to the bit. `applied` (A1): the action being applied, through its own block - summed
/// after the state and goal, so without it this is exactly the same sum, stopped one loop earlier.
pub fn policyWith(
    params: [7]Tensor,
    hidden1: []f32,
    hidden2: []f32,
    z: []const f32,
    goal: []const f32,
    applied: ?AppliedRow,
    out: []f32,
) void {
    const h: usize = hidden1.len;
    const actions: usize = out.len;
    const p = params;
    if (applied) |seen| {
        const one_per_action: bool = seen.action.len == actions;
        const block_fits: bool = seen.weights.data.len == actions * h;
        assertf(one_per_action and block_fits, @src(), "applied block of {d} for {d} numbers; want {d} x {d}", .{
            seen.weights.data.len,
            seen.action.len,
            actions,
            h,
        });
    }
    for (0..h) |j| {
        var sum: f32 = p[2].data[j];
        for (z, goal, 0..) |x, y, i| {
            sum += x * p[0].data[i * h + j] + y * p[1].data[i * h + j];
        }
        if (applied) |seen| {
            for (seen.action, 0..) |x, i| {
                sum += x * seen.weights.data[i * h + j];
            }
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

pub const Learner = struct {
    arena: ArenaAllocator,
    gpa: Allocator,
    options: LearnerOptions,
    fleet: *track.Fleet,
    world: *LatentWorld,
    features: usize,
    references: usize,
    actions: usize,
    /// The policy: [features of the character, features of the reference] -> hidden -> hidden ->
    /// raw action. The first layer split in two (the concat-free trick again). With `sees_applied`,
    /// the first layer reads a third input through `applied_block`; these seven stay exactly the
    /// layout the GPU kit mirrors either way.
    params: [7]Tensor,
    /// Plan A1: the first layer's block for the action being applied, with everything that trains it
    /// - or null, when the policy does not see that action (`LearnerOptions.sees_applied`).
    applied_block: ?AppliedBlock,
    graph: Graph,
    vars: [7]Var,
    world_vars: [8]Var,
    /// The second world model (plan I1b), or null. Trained beside the first (`trainWorld`), stepped beside it in
    /// every rollout - on the graph through `twin_vars`, row by row through `modelStepRow` - the two averaged.
    twin: ?*LatentWorld,
    twin_vars: [8]Var,
    /// Scratch for stepping the twin row by row (empty without one).
    z_twin: []f32,
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
    rng: Random.DefaultPrng,
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
        // Settings refused when they are nonsense rather than quietly bent (`LearnerOptions.problem`, the one
        // definition): a filter of 0 would freeze every action at rest - the policy could never move the character,
        // and nothing would say so.
        const why: []const u8 = options.problem() orelse "";
        assertf(why.len == 0, @src(), "learner options refused: {s} (filter {d}, decide_every {d})", .{
            why,
            options.filter,
            options.decide_every,
        });
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
            .applied_block = undefined,
            .graph = undefined,
            .vars = undefined,
            .world_vars = undefined,
            .twin = undefined,
            .twin_vars = undefined,
            .z_twin = undefined,
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
        self.arena = ArenaAllocator.init(gpa);
        errdefer self.arena.deinit();
        const owned: Allocator = self.arena.allocator();
        const m: *rbt.Model = fleet.m;
        self.gpa = gpa;
        self.options = options;
        self.fleet = fleet;
        self.world = try LatentWorld.init(gpa, fleet, options.world);
        errdefer self.world.deinit(gpa);
        // The twin (I1b): the same options but its seed. Its normaliser is measured from the same replay, so the two
        // speak the same normalised units - which is what makes their average and their distance mean anything.
        self.twin = null;
        if (options.twin_world) {
            var twin_options: WorldOptions = options.world;
            twin_options.seed = options.twin_seed orelse options.world.seed +% 1;
            self.twin = try LatentWorld.init(gpa, fleet, twin_options);
        }
        errdefer if (self.twin) |twin| twin.deinit(gpa);
        const f: usize = self.world.features;
        const r: usize = self.world.references;
        const a: usize = self.world.actions;
        const h: usize = options.hidden;
        self.features = f;
        self.references = r;
        self.actions = a;
        self.rng = Random.DefaultPrng.init(options.seed);
        // Set here, not by a field default: the learner is made by `gpa.create`, whose memory is
        // uninitialised - a default on the field would never be applied.
        self.updates = 0;
        self.state = try track.State.init(owned, m.nbody);
        self.reference = try track.State.init(owned, m.nbody);
        self.ref_data = try rbt.Data.init(owned, m);
        self.raw = try owned.alloc(f32, f);
        self.z_sim = try owned.alloc(f32, f);
        self.z_ref = try owned.alloc(f32, f);
        self.z_twin = try owned.alloc(f32, if (self.twin != null) f else 0);
        self.out = try owned.alloc(f32, a);
        self.hidden1 = try owned.alloc(f32, h);
        self.hidden2 = try owned.alloc(f32, h);
        self.fleet_actions = try owned.alloc(f32, fleet.options.envs * a);
        // Each character's slot starts as what it was LAST APPLYING - its replay's newest record, when it is mid-
        // episode (a warm-up drove it before this learner existed) - and at rest otherwise, as every episode opens.
        // Never left undefined: before this learner writes a slot once, it is held on a clock's odd steps, blended
        // into by the filter, and read by a policy that sees what it applies. From the replay, too, so a window's
        // starting state (`appliedBefore`) and what collection really applied agree at the hand-over.
        for (0..fleet.options.envs) |env| {
            const slot: []f32 = self.fleet_actions[env * a ..][0..a];
            const written: u64 = fleet.replay.written[env];
            const mid_episode: bool = fleet.steps[env] > 0 and written > 0;
            if (mid_episode) {
                @memcpy(slot, fleet.replay.actionAt(env, written - 1));
            } else {
                @memset(slot, 0.0);
            }
        }

        // The policy's parameters: Xavier for the tanh layers, and a near-zero output layer, so an
        // untrained policy is the servo alone - the same starting point PPO's residual policy has.
        const random: Random = self.rng.random();
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
        self.graph = Graph.init(owned);
        self.graph.useScratchAllocator(gpa);
        const g: *Graph = &self.graph;
        for (&self.vars, self.params) |*v, p| {
            v.* = try g.parameter(p);
        }
        for (&self.world_vars, self.world.params) |*v, p| {
            v.* = try g.parameter(p);
        }
        if (self.twin) |twin| {
            for (&self.twin_vars, twin.params) |*v, p| {
                v.* = try g.parameter(p);
            }
        }
        // A1's block, when the policy sees what it applies: ZERO, so the policy starts exactly as the one that
        // cannot see it - and made after the seven, from no random numbers at all, so the seven (and the random
        // stream behind them) come out bit for bit as a learner without the option makes them.
        self.applied_block = null;
        if (options.sees_applied) {
            const weights: Tensor = try filled(owned, &.{ a, h }, 0.0);
            self.applied_block = .{
                .weights = weights,
                .on_graph = try g.parameter(weights),
                .adam = try gym.AdamSet.init(owned, &.{weights}),
            };
        }
        const ones: Var = try g.constant(try filled(owned, &.{ b, 1 }, 1.0));
        const no_action: Var = try g.constant(try filled(owned, &.{ b, a }, 0.0));
        // The twins' gap is priced against zero - made only when it is priced, so no other graph changes by a node.
        const pricing_gap: bool = self.twin != null and options.w_disagree > 0.0;
        const no_gap: ?Var = if (pricing_gap) try g.constant(try filled(owned, &.{ b, f }, 0.0)) else null;
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
            // A1: when it sees what it is applying, that is `applied` as it stands BEFORE this decision - the
            // filter's state the decision is about to be blended into. A Var like any other, so the gradient also
            // runs back through it to the earlier decisions that made it.
            const seen: ?AppliedInput = if (self.applied_block) |block|
                .{ .weights = block.on_graph, .action = applied }
            else
                null;
            const raw: Var = if (deciding)
                try policyOnGraph(g, self.vars, z, self.goals[k + 1], seen, ones)
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
            const predicted: Var = try LatentWorld.step(g, self.world_vars, z, self.refs[k], applied, ones);
            // With a twin (I1b): both models step from the SAME state and the rollout continues from their average;
            // their gap is priced when `w_disagree` is on. The gap is written `p + (-o)` so its gradient reaches BOTH
            // predictions - `mseLoss` gives none to its target, so `mseLoss(p, o)` would only ever pull one of them.
            var disagreement: ?Var = null;
            if (self.twin != null) {
                const other: Var = try LatentWorld.step(g, self.twin_vars, z, self.refs[k], applied, ones);
                z = try g.scale(try g.add(predicted, other), 0.5);
                if (no_gap) |zero| {
                    const gap: Var = try g.add(predicted, try g.scale(other, -1.0));
                    disagreement = try g.scale(try g.mseLoss(gap, zero), options.w_disagree);
                }
            } else {
                z = predicted;
            }
            var term: Var = try g.mseLoss(z, self.goals[k + 1]);
            // The twins' disagreement is priced on EVERY step, held or not: it is about where the state has gone,
            // and a held action steers it as much as a fresh one.
            if (disagreement) |price| {
                term = try g.add(term, price);
            }
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
        self.adam = try gym.AdamSet.init(owned, &self.params);
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
        if (self.twin) |twin| {
            twin.deinit(gpa);
        }
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// One step of the model the policy trains through, row by row: the world model's - or, with a twin (I1b), the
    /// AVERAGE of the two, stepped from the same state (`(p + o) * 0.5`, the graph's order to the bit). Every
    /// row-by-row rollout goes through here - `modelLoss`, `diagnose` - so the yardsticks measure the model the
    /// policy is actually trained against.
    pub fn modelStepRow(
        self: *Learner,
        z: []f32,
        ref: []const f32,
        action: []const f32,
    ) void {
        if (self.twin) |twin| {
            @memcpy(self.z_twin, z);
            twin.stepRow(self.z_twin, ref, action);
            self.world.stepRow(z, ref, action);
            for (z, self.z_twin) |*x, y| {
                x.* = (x.* + y) * 0.5;
            }
            return;
        }
        self.world.stepRow(z, ref, action);
    }

    /// One training step of every world model - the first, and the twin when there is one (each on its own
    /// batches, from its own stream). The loss is the first model's, or the pair's mean. Null until the replay can
    /// supply windows.
    pub fn trainWorld(self: *Learner, fleet: *track.Fleet) !?f32 {
        const first: f32 = (try self.world.trainStep(fleet)) orelse return null;
        const twin: *LatentWorld = self.twin orelse return first;
        const second: f32 = (try twin.trainStep(fleet)) orelse return first;
        return (first + second) * 0.5;
    }

    /// Plan A1: the first layer's block for the action being applied (actions x hidden), its Var on the training
    /// graph, and its own Adam moments. One optional value, so the block never exists without what trains it - and
    /// the seven tensors' Adam, which the GPU kit mirrors, stays exactly what it was.
    const AppliedBlock = struct {
        weights: Tensor,
        on_graph: Var,
        adam: gym.AdamSet,
    };

    /// What the policy is applying, on a graph (A1): the first layer's block for it, and the action itself. One
    /// value, so a graph cannot be handed the input without the weights that read it, or the other way round.
    pub const AppliedInput = struct {
        weights: Var,
        action: Var,
    };

    /// ONE Adam step on everything the policy trains, from the gradients on `g`: the seven layers, then A1's block
    /// when there is one. `layers` and `block_on_graph` are those tensors' Vars on `g` - the training graph's or the
    /// cloning graph's. Every policy update comes through here, so the block cannot be left out of one, and its
    /// Adam counts steps in lockstep with the seven's (the two sets are then one Adam, split by tensor).
    fn stepAdam(
        self: *Learner,
        g: *Graph,
        layers: [7]Var,
        block_on_graph: ?Var,
    ) !void {
        try self.adam.apply(g, &self.params, &layers, self.options.rate);
        if (self.applied_block) |*block| {
            assertf(block_on_graph != null, @src(), "the policy sees what it applies, but this graph has no Var " ++
                "for the block that reads it", .{});
            try block.adam.apply(g, &.{block.weights}, &.{block_on_graph.?}, self.options.rate);
        }
        self.updates += 1;
    }

    const Clone = struct {
        graph: Graph,
        vars: [7]Var,
        /// A1: the block's Var on this graph and, per row, the action applied before the recorded step - when the
        /// policy sees it, so a cloned policy is the same function the learner acts with.
        applied: ?AppliedInput,
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
        // Cloning regresses the policy's RAW output on the RECORDED action. That is the same quantity only when
        // every recorded step is a decision (no clock) and nothing blends a decision into what was already applied
        // (no filter). With either, a record holds a held or a blended action, and the policy would learn to ask
        // for what the filter delivers - asked again, it would deliver something else.
        const records_are_raw: bool = self.options.filter == 1.0 and self.options.decide_every == 1;
        if (!records_are_raw) {
            return error.CloningNeedsRawActions;
        }
        // A policy that sees what it applies is told, for each step, what was applied before it: refuse a step
        // for which the replay cannot say - checked before anything is written into the graph.
        if (self.applied_block != null) {
            for (steps) |step| {
                if (!appliedKnown(self.fleet, step.env, step.index)) {
                    return error.UnknownAppliedAction;
                }
            }
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
            // A1: what was being applied when the step was recorded - the replay's action before it, or rest on an
            // episode's first step - exactly what the policy would have been told there (known: checked above).
            if (c.applied) |seen| {
                const applied_row: []f32 = g.valueOf(seen.action).data[row * a ..][0..a];
                const known: bool = appliedBefore(self.fleet, step.env, step.index, applied_row);
                assertf(known, @src(), "cloning step {d} of env {d}: applied action unknown", .{
                    step.index,
                    step.env,
                });
            }
        }
        try g.recompute();
        try g.backward(c.loss);
        try self.stepAdam(g, c.vars, if (c.applied) |seen| seen.weights else null);
        return g.valueOf(c.loss).data[0];
    }

    fn buildClone(self: *Learner) !void {
        const owned: Allocator = self.arena.allocator();
        const b: usize = self.options.batch;
        const f: usize = self.features;
        const a: usize = self.actions;
        var c: Clone = .{
            .graph = Graph.init(owned),
            .vars = undefined,
            .applied = null,
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
        // A1: the block's weights on this graph too (the same tensor - the one Adam steps), and the input it reads.
        if (self.applied_block) |block| {
            c.applied = .{
                .weights = try g.parameter(block.weights),
                .action = try g.constant(try filled(owned, &.{ b, a }, 0.0)),
            };
        }
        const raw: Var = try policyOnGraph(g, c.vars, c.z, c.goal, c.applied, ones);
        c.loss = try g.mseLoss(raw, c.target);
        self.clone = c;
    }

    /// The policy on a graph: [state, goal] -> raw action - and, when `applied` is given (A1), the action being
    /// applied as a third input, through its own block of the first layer. Public so the GPU version's gradients
    /// can be checked against a graph built from this very function.
    pub fn policyOnGraph(
        g: *Graph,
        v: [7]Var,
        z: Var,
        goal: Var,
        applied: ?AppliedInput,
        ones: Var,
    ) !Var {
        var into: Var = try g.add(
            try g.add(try g.matmul(z, v[0]), try g.matmul(goal, v[1])),
            try g.matmul(ones, v[2]),
        );
        if (applied) |seen| {
            into = try g.add(into, try g.matmul(seen.action, seen.weights));
        }
        const h1: Var = try g.tanh(into);
        const h2: Var = try g.tanh(try g.add(try g.matmul(h1, v[3]), try g.matmul(ones, v[4])));
        return g.add(try g.matmul(h2, v[5]), try g.matmul(ones, v[6]));
    }

    /// The policy's raw output for one character, outside the graph. `applied` is what the character is applying
    /// before this decision; the policy reads it only when it sees it (A1) - callers always pass it, so none of them
    /// has to know which policy this is.
    fn policyRow(
        self: *Learner,
        z: []const f32,
        goal: []const f32,
        applied: []const f32,
        out: []f32,
    ) void {
        const seen: ?AppliedRow = if (self.applied_block) |block|
            .{ .weights = block.weights, .action = applied }
        else
            null;
        policyWith(self.params, self.hidden1, self.hidden2, z, goal, seen, out);
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
    /// has been applying, and will apply until the next decision; from REST at an episode's first step. When the
    /// policy sees what it applies (A1), `slot` as it stands is also its third input. Collecting, the judge and
    /// `diagnose` all decide through here, so they cannot disagree about what a decision is.
    fn decideInto(
        self: *Learner,
        fleet: *track.Fleet,
        env: usize,
        noise_scale: f32,
        slot: []f32,
    ) void {
        // An episode opens from rest - reset BEFORE the policy reads the slot, so it is told it is applying nothing
        // rather than whatever the last episode left there.
        if (fleet.steps[env] == 0) {
            @memset(slot, 0.0);
        }
        self.liveFeaturesOf(fleet, env);
        self.policyRow(self.z_sim, self.z_ref, slot, self.out);
        // No draw at all when there is no noise: judging must not consume the training's random stream, or a judged
        // run would train differently afterwards.
        if (noise_scale != 0.0) {
            const random: Random = self.rng.random();
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
        track.filterAction(self.options.filter, self.out, slot);
    }

    /// Whether the replay can say what was being APPLIED just before record `first` of `env` (`appliedBefore`):
    /// always on an episode's first step (rest), otherwise only while the step before it is still in the ring. Never
    /// for a record that is not a step of a rollout (`Replay.append`).
    fn appliedKnown(fleet: *const track.Fleet, env: usize, first: u64) bool {
        const replay: track.Replay = fleet.replay;
        const episode_step: u32 = replay.episodeStepAt(env, first) orelse return false;
        if (episode_step == 0) {
            return true;
        }
        const oldest: u64 = replay.written[env] -| @as(u64, @intCast(replay.capacity));
        return first > 0 and first - 1 >= oldest;
    }

    /// What was being APPLIED just before record `first` of `env` - the filter's state a training window or a cloned
    /// step starts from (F6), and what a policy that sees it is told (A1) - into `out`; false when it is unknown:
    ///   * REST on an episode's first step: every episode opens from rest (`decideInto` resets the slot);
    ///   * otherwise the action recorded ONE STEP EARLIER - across a shove too, which ends a segment but not an
    ///     episode, so the controller's filter carries straight through it;
    ///   * UNKNOWN when that step has left the ring (a window starting at the oldest record of a full ring), or the
    ///     record is not a step of a rollout at all. The state was real and is gone: rest would be a guess that
    ///     looks like an answer, so `out` gets NaN - loud if anything reads it - and the caller draws another
    ///     window (`drawWindow`) or refuses.
    fn appliedBefore(fleet: *const track.Fleet, env: usize, first: u64, out: []f32) bool {
        if (!appliedKnown(fleet, env, first)) {
            @memset(out, nan(f32));
            return false;
        }
        const replay: track.Replay = fleet.replay;
        if (replay.episodeStepAt(env, first).? == 0) {
            @memset(out, 0.0);
        } else {
            @memcpy(out, replay.actionAt(env, first - 1));
        }
        return true;
    }

    /// Whether a window's starting filter state changes anything: a filter blends the first decision into it, and a
    /// policy that sees what it applies reads it. With neither, the first decision replaces it whole (a window
    /// always opens on a decision), so an unknown start costs nothing.
    fn startStateMatters(self: *const Learner) bool {
        return self.options.filter < 1.0 or self.applied_block != null;
    }

    /// A window for the policy: `Replay.sampleWindow`'s, drawn again while its starting filter state is unknown and
    /// matters (`appliedKnown`, `startStateMatters`) - a window starting at the oldest record of a full ring, about
    /// one draw in `capacity`. Null when nothing long enough is recorded yet, as `sampleWindow`. With no filter and a
    /// blind policy it IS `sampleWindow`, draw for draw.
    pub fn drawWindow(
        self: *Learner,
        random: Random,
        steps: usize,
    ) ?track.Replay.Window {
        const fleet: *track.Fleet = self.fleet;
        for (0..64) |_| {
            const window: track.Replay.Window = fleet.replay.sampleWindow(random, steps) orelse return null;
            const usable: bool = !self.startStateMatters() or appliedKnown(fleet, window.env, window.first);
            if (usable) {
                return window;
            }
        }
        return null;
    }

    /// A window's starting filter state into `out`: `appliedBefore`, and where that is unknown - allowed only where
    /// it cannot matter (asserted) - rest, a value that then changes nothing.
    fn startStateInto(
        self: *const Learner,
        window: track.Replay.Window,
        out: []f32,
    ) void {
        if (appliedBefore(self.fleet, window.env, window.first, out)) {
            return;
        }
        assertf(!self.startStateMatters(), @src(), "the window at record {d} of env {d} starts from an applied " ++
            "action that is unknown, and this learner reads it - draw windows with `drawWindow`", .{
            window.first,
            window.env,
        });
        @memset(out, 0.0);
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
        const random: Random = self.rng.random();
        // Sample and fill row by row, in that order: filling draws the rollout's noise from the same
        // random stream, so drawing every window first would reorder the draws - and silently change
        // every result measured with this learner.
        for (0..self.options.batch) |row| {
            const window: track.Replay.Window = self.drawWindow(random, self.options.window) orelse return null;
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
        // Every window checked BEFORE any is filled: a refusal must not leave half a batch in the graph.
        for (windows) |window| {
            const usable: bool = !self.startStateMatters() or appliedKnown(self.fleet, window.env, window.first);
            if (!usable) {
                return error.UnknownAppliedAction;
            }
        }
        const random: Random = self.rng.random();
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
        random: Random,
    ) void {
        const g: *Graph = &self.graph;
        const f: usize = self.features;
        const r: usize = self.references;
        const a: usize = self.actions;
        const fleet: *track.Fleet = self.fleet;
        self.world.featuresAt(fleet, window.env, window.first, g.valueOf(self.start).data[row * f ..][0..f]);
        self.startStateInto(window, g.valueOf(self.applied_start).data[row * a ..][0..a]);
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
        try self.stepAdam(g, self.vars, if (self.applied_block) |block| block.on_graph else null);
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
        var rng: Random.DefaultPrng = .init(seed);
        const random: Random = rng.random();
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
            const window: track.Replay.Window = self.drawWindow(random, horizon) orelse continue;
            self.world.featuresAt(fleet, window.env, window.first, z);
            self.startStateInto(window, applied);
            for (0..horizon) |k| {
                const index: u64 = window.first + k;
                // The next goal: what the policy aims at, and what this step is scored against.
                self.goalAt(window.env, index + 1, goal);
                if (use_policy) {
                    // The clock (F4e): a decision every `decide_every` steps of the window, held in between -
                    // blended into what was applied by the filter (F6).
                    if (k % @max(self.options.decide_every, 1) == 0) {
                        self.policyRow(z, goal, applied, action);
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
                self.modelStepRow(z, ref, applied);
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
                self.modelStepRow(z_c, ref, no_action);
                self.modelStepRow(z_d, ref, actions_b[(s * horizon + k) * a ..][0..a]);
                // The model's own closed loop keeps the clock too: a decision every `decide_every` steps from the
                // start (the judge's fleet starts every episode at step 0), held in between.
                if (k % @max(self.options.decide_every, 1) == 0) {
                    self.policyRow(z_e, goal, applied_e, action);
                    track.filterAction(self.options.filter, action, applied_e);
                }
                self.modelStepRow(z_e, ref, applied_e);
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

// -------- Tests: the learner --------

const codecs = @import("codecs.zig");
const mjcf = @import("mjcf.zig");
const robot_mjcf = @import("robot_mjcf.zig");

const flex2_xml: []const u8 = @embedFile("tests/fixtures/robot/humanoid_flex2.xml");

// Both tests are MEASUREMENTS as much as checks, sized to run in about a minute each: 8 characters,
// networks 64 wide, batches of 16, a few hundred updates. They assert only what that budget can
// honestly show - the mechanism works and its gain carries - not how far training can go; the GPU
// version, with a real budget, answers that.

fn readFile(gpa: Allocator, io: Io, path: []const u8) ![]u8 {
    var file: Io.File = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const info: Io.File.Stat = try file.stat(io);
    const bytes: []u8 = try gpa.alloc(u8, info.size);
    errdefer gpa.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);
    return bytes;
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

    fn init(self: *WalkSetup, gpa: Allocator, io: Io, envs: usize) !void {
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
            .gravity = vec(0, 0, -9.81),
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
        self.fleet = try track.Fleet.init(gpa, &self.imported.model, &.{&self.walk}, fleet_options);
        errdefer self.fleet.deinit();
        // A first helping of data - wide enough (0.1 of the authority) that the world model sees what an
        // action DOES - for its normaliser and first steps.
        const noise: []f32 = try gpa.alloc(f32, envs * track.actionSize(&self.imported.model));
        defer gpa.free(noise);
        var rng: Random.DefaultPrng = .init(5);
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
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
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
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
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
    // The real-simulator judge is for the table alone - nothing below asserts on it - so it runs only when the table
    // is asked for. Judging touches no training state (`decideInto` draws nothing at zero noise), so the losses
    // asserted below are the same either way.
    const servo: ?f32 = if (report.requested()) try learner.judge(300, 99, true) else null;
    const policy: ?f32 = if (report.requested()) try learner.judge(300, 99, false) else null;
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

test "robot_latent: diagnose - a silent policy exploits nothing, the numbers repeat, training untouched" {
    // Plan F2's known answers. With every policy weight zero the policy's action is exactly zero, so the real
    // rollouts with and without it are the same trajectory, and so are the model's: the model promises nothing,
    // the simulator delivers nothing - exploitation EXACTLY 0, and following the policy's actions is following
    // zero. Two diagnoses are identical; a live policy's real rollout differs from the servo's; and diagnosing
    // borrows only scratch - the learner's own fleet is where it was.
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
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
    try expect(eql(u32, fleet.frame, frames_before));
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
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
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
    try expect(eql(f32, norm.mean, again.mean) and eql(f32, norm.spread, again.spread));

    const f: usize = track.localSize(m.nbody);
    var data: rbt.Data = try .init(gpa, m);
    defer data.deinit();
    var state: track.State = try .init(gpa, m.nbody);
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
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
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
                try expect(eql(f32, now, then));
                held_checked += 1;
            } else if (!eql(f32, now, then)) {
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

/// What the parity test varies: A1's input, and the twin world model with its price.
const Variation = struct {
    sees_applied: bool = false,
    twin: bool = false,
    w_disagree: f32 = 0.0,
};

/// Fills a weight tensor with values large enough that its input visibly moves the policy's output - A1's block
/// (the learner starts it at zero) or the output layer (0.01 of Xavier at the start). A test's plant.
fn plantBlock(weights: Tensor, seed: u64) void {
    var rng: Random.DefaultPrng = .init(seed);
    for (weights.data) |*w| {
        w.* = 0.5 * rng.random().floatNorm(f32);
    }
}

/// Plan F6's known answer, and A1's second. With noise off, the policy's training loss - built with tensors, the
/// filter written as `filter * asked + (1 - filter) * applied` inside the graph - equals the same rollout done row by
/// row outside it: `policyRow` at each decision, `track.filterAction`, the world model's `stepRow`, from the replay's
/// action before the window (`appliedBefore`). Held steps (decide_every 2), the starting state, and every term of the
/// loss - the state error each step, the action's price each decision - are in it, and so is the action APPLIED at
/// every step, compared directly: through the loss alone, a wrong action barely registers. The output layer is
/// planted for the same reason - at its starting 0.01 scale every action is tiny, and so is any mistake in one. With
/// `sees_applied` the rows hand each decision the applied action as it stands before it, and the block is planted
/// too: at its starting zero the equality would hold for a graph that never fed the input at all. With `twin` the
/// rows step both world models from the same state, go on from their average, and add the squared gap `w_disagree`
/// prices - where the graph does all three.
fn expectGraphEqualsRows(variation: Variation) !void {
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
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
        .sees_applied = variation.sees_applied,
        .twin_world = variation.twin,
        .w_disagree = variation.w_disagree,
        .world = .{ .hidden = 16, .steps = steps, .batch = batch },
    });
    defer learner.deinit();
    // Filtered, noisy actions into the replay - so windows start from a filter that is not at rest.
    learner.act(80, 1.0);
    // Then weights under which every input moves the action (see above).
    plantBlock(learner.params[5], 2);
    if (learner.applied_block) |block| {
        plantBlock(block.weights, 3);
    }

    var prng: Random.DefaultPrng = .init(99);
    var windows: [batch]track.Replay.Window = undefined;
    for (&windows) |*window| {
        window.* = learner.drawWindow(prng.random(), steps) orelse return error.SkipZigTest;
    }
    const f: usize = learner.features;
    const a: usize = learner.actions;
    const r: usize = learner.references;
    const z: []f32 = try gpa.alloc(f32, batch * f);
    defer gpa.free(z);
    const applied: []f32 = try gpa.alloc(f32, batch * a);
    defer gpa.free(applied);
    // The rows' applied action after each step, to hold against the graph's `step_actions`.
    const applied_at: []f32 = try gpa.alloc(f32, steps * batch * a);
    defer gpa.free(applied_at);
    const asked: []f32 = try gpa.alloc(f32, a);
    defer gpa.free(asked);
    const goal: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(goal);
    const ref: []f32 = try gpa.alloc(f32, r);
    defer gpa.free(ref);
    // The twin's prediction, row by row (I1b).
    const z_other: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(z_other);
    var any_filter_state: bool = false;
    for (windows, 0..) |window, row| {
        learner.world.featuresAt(fleet, window.env, window.first, z[row * f ..][0..f]);
        try expect(Learner.appliedBefore(fleet, window.env, window.first, applied[row * a ..][0..a]));
        for (applied[row * a ..][0..a]) |value| {
            any_filter_state = any_filter_state or value != 0.0;
        }
    }
    try expect(any_filter_state);
    if (variation.sees_applied) {
        // The knob reaches: told rest instead of what it applies, the first decision is a different one. Not bit for
        // bit the same is the whole test - the function is deterministic and only that input differs (and the
        // untrained output layer is small, so the difference is too).
        const told_rest: []f32 = try gpa.alloc(f32, a);
        defer gpa.free(told_rest);
        const no_action: []f32 = try gpa.alloc(f32, a);
        defer gpa.free(no_action);
        @memset(no_action, 0.0);
        learner.goalAt(windows[0].env, windows[0].first + 1, goal);
        learner.policyRow(z[0..f], goal, applied[0..a], asked);
        learner.policyRow(z[0..f], goal, no_action, told_rest);
        try expect(!eql(f32, asked, told_rest));
    }
    // Row by row, BEFORE the graph's update touches the weights.
    var expected: f64 = 0.0;
    for (0..steps) |k| {
        const deciding: bool = k % 2 == 0;
        var state_error: f64 = 0.0;
        var action_size: f64 = 0.0;
        var gap_squared: f64 = 0.0;
        for (windows, 0..) |window, row| {
            const z_row: []f32 = z[row * f ..][0..f];
            const applied_row: []f32 = applied[row * a ..][0..a];
            learner.goalAt(window.env, window.first + k + 1, goal);
            if (deciding) {
                // The applied action as it stands before the decision: what A1's policy is told.
                learner.policyRow(z_row, goal, applied_row, asked);
                track.filterAction(0.2, asked, applied_row);
                for (asked) |x| {
                    action_size += @as(f64, x) * x;
                }
            }
            @memcpy(applied_at[(k * batch + row) * a ..][0..a], applied_row);
            learner.world.referenceAt(fleet, window.env, window.first + k, ref);
            if (variation.twin) {
                // Both models from the same state; the rollout goes on from their average, `(p + o) * 0.5` - the
                // graph's order - and the squared gap is what `w_disagree` prices.
                @memcpy(z_other, z_row);
                learner.twin.?.stepRow(z_other, ref, applied_row);
                learner.world.stepRow(z_row, ref, applied_row);
                for (z_row, z_other) |*x, y| {
                    gap_squared += (@as(f64, x.*) - y) * (@as(f64, x.*) - y);
                    x.* = (x.* + y) * 0.5;
                }
            } else {
                learner.world.stepRow(z_row, ref, applied_row);
            }
            for (z_row, goal) |x, y| {
                state_error += (@as(f64, x) - y) * (@as(f64, x) - y);
            }
        }
        expected += state_error / float(batch * f);
        expected += variation.w_disagree * gap_squared / float(batch * f);
        if (deciding) {
            expected += learner.options.w_action * action_size / float(batch * a);
        }
    }
    expected /= float(steps);
    const graphs: f32 = try learner.trainPolicyOn(&windows);
    try expect(@abs(graphs - expected) <= 1.0e-5 * @max(1.0, @abs(expected)));
    // The forward pass's values are still on the graph (the update wrote only the weights). The two sum a layer in
    // different orders, so to rounding, not to the bit.
    for (learner.step_actions, 0..) |on_graph, k| {
        const graph_rows: []const f32 = learner.graph.valueOf(on_graph).data;
        for (graph_rows, applied_at[k * batch * a ..][0 .. batch * a]) |x, y| {
            try expect(@abs(x - y) <= 1.0e-5 * @max(1.0, @abs(y)));
        }
    }
}

test "robot_latent: the filter in the training graph equals the same rollout done row by row" {
    try expectGraphEqualsRows(.{});
}

test "robot_latent: A1 - seeing what it applies, the training graph still equals the rows" {
    try expectGraphEqualsRows(.{ .sees_applied = true });
}

test "robot_latent: twin world models - the graph equals the rows, their average and the price on their gap" {
    try expectGraphEqualsRows(.{ .twin = true, .w_disagree = 0.7 });
    // With A1's input too: the ingredients compose, step for step.
    try expectGraphEqualsRows(.{ .twin = true, .w_disagree = 0.7, .sees_applied = true });
}

test "robot_latent: a twin from the SAME seed changes nothing, to the bit" {
    // Two identical models average to themselves and disagree by exactly zero, so a learner with such a twin -
    // and a price on the gap - must give the loss a learner without one gives, bit for bit. What the known answer
    // catches: a twin wired to the wrong weights, an average that is not an average, a price on something that
    // is not the gap.
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var setup: WalkSetup = undefined;
    setup.init(gpa, threaded.io(), 3) catch return error.SkipZigTest;
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const steps: usize = 6;
    const batch: usize = 3;
    const base: LearnerOptions = .{
        .hidden = 16,
        .window = steps,
        .batch = batch,
        .sigma = 0.0,
        .world = .{ .hidden = 16, .steps = steps, .batch = batch },
    };
    var twinned: LearnerOptions = base;
    twinned.twin_world = true;
    twinned.twin_seed = base.world.seed;
    twinned.w_disagree = 1.0;
    // Both built before either acts, so both measure the same replay for their normalisers.
    const alone: *Learner = try .init(gpa, fleet, base);
    defer alone.deinit();
    const paired: *Learner = try .init(gpa, fleet, twinned);
    defer paired.deinit();
    plantBlock(alone.params[5], 2);
    plantBlock(paired.params[5], 2);
    var prng: Random.DefaultPrng = .init(7);
    var windows: [batch]track.Replay.Window = undefined;
    for (&windows) |*window| {
        window.* = alone.drawWindow(prng.random(), steps) orelse return error.SkipZigTest;
    }
    const lone_loss: f32 = try alone.trainPolicyOn(&windows);
    const pair_loss: f32 = try paired.trainPolicyOn(&windows);
    try expectEqual(lone_loss, pair_loss);
    // And the one definition of valid settings refuses a price with nothing to compare.
    var unpaired: LearnerOptions = base;
    unpaired.w_disagree = 1.0;
    try expect(unpaired.problem() != null);
}

test "robot_latent: A1 - at its starting zero the block is invisible: the same actions, the same first update" {
    // Plan A1's first known answer. The block starts at ZERO and is made from no random numbers, so a learner with
    // `sees_applied` starts as the learner without it: the same seven tensors, the same raw action whatever it is
    // told it applies, and the same first update - its loss, and all seven tensors after it, exactly (at zero the
    // block adds exact zeros forward, and sends exact zeros back to the decisions that made the applied action).
    // Only the block moves: windows start from an applied action that is not rest, so it gets a gradient.
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var setup: WalkSetup = undefined;
    setup.init(gpa, threaded.io(), 3) catch return error.SkipZigTest;
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const options: LearnerOptions = .{
        .hidden = 16,
        .window = 4,
        .batch = 3,
        .decide_every = 2,
        .filter = 0.2,
        .world = .{ .hidden = 16, .steps = 4, .batch = 3 },
    };
    const blind: *Learner = try .init(gpa, fleet, options);
    defer blind.deinit();
    var seeing_options: LearnerOptions = options;
    seeing_options.sees_applied = true;
    const seeing: *Learner = try .init(gpa, fleet, seeing_options);
    defer seeing.deinit();
    try expect(blind.applied_block == null and seeing.applied_block != null);
    for (blind.params, seeing.params) |x, y| {
        try expect(eql(f32, x.data, y.data));
    }

    // The same raw action, told something far from rest.
    const f: usize = blind.features;
    const a: usize = blind.actions;
    const z: []f32 = try gpa.alloc(f32, 2 * f + 3 * a);
    defer gpa.free(z);
    const goal: []f32 = z[f..][0..f];
    const applied: []f32 = z[2 * f ..][0..a];
    const out_blind: []f32 = z[2 * f + a ..][0..a];
    const out_seeing: []f32 = z[2 * f + 2 * a ..][0..a];
    blind.world.featuresAt(fleet, 0, 40, z[0..f]);
    blind.goalAt(0, 41, goal);
    for (applied, 0..) |*x, i| {
        x.* = 0.8 * (float(i % 7) / 3.0 - 1.0);
    }
    blind.policyRow(z[0..f], goal, applied, out_blind);
    seeing.policyRow(z[0..f], goal, applied, out_seeing);
    try expect(eql(f32, out_blind, out_seeing));

    // The same first update, on the same windows (neither learner has drawn from its random stream since `init`,
    // so the rollouts' noise is the same too).
    var prng: Random.DefaultPrng = .init(17);
    var windows: [3]track.Replay.Window = undefined;
    for (&windows) |*window| {
        window.* = blind.drawWindow(prng.random(), 4) orelse return error.SkipZigTest;
    }
    const loss_blind: f32 = try blind.trainPolicyOn(&windows);
    const loss_seeing: f32 = try seeing.trainPolicyOn(&windows);
    try expect(loss_blind == loss_seeing);
    for (blind.params, seeing.params) |x, y| {
        try expect(eql(f32, x.data, y.data));
    }
    var block_moved: bool = false;
    for (seeing.applied_block.?.weights.data) |w| {
        block_moved = block_moved or w != 0.0;
    }
    try expect(block_moved);
}

test "robot_latent: A1 - a decision reads the action its slot is applying, and rest when an episode opens" {
    // Plan A1's third known answer, through the judge's actor: `decideInto` - the one definition of a decision,
    // shared by collecting, the judge and `diagnose` - hands the policy the slot's value. Planted on a step past the
    // episode's first, the decision is exactly the policy's answer for the PLANTED value, blended into it - and NOT
    // what a decision that ignored the slot (told rest) would have blended, so the equality is not vacuous. On an
    // episode's FIRST step the slot is reset before the policy reads it: whatever was planted, it is told rest.
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var setup: WalkSetup = undefined;
    setup.init(gpa, threaded.io(), 3) catch return error.SkipZigTest;
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const learner: *Learner = try .init(gpa, fleet, .{
        .hidden = 16,
        .window = 4,
        .batch = 2,
        .filter = 0.2,
        .sees_applied = true,
        .world = .{ .hidden = 16, .steps = 4, .batch = 2 },
    });
    defer learner.deinit();
    plantBlock(learner.applied_block.?.weights, 5);
    const a: usize = learner.actions;
    const clip: *const dance.Clip = fleet.clips[0];
    const starts = [_]usize{ 10, 90 };
    const actor: track.Actor = learner.judgeActor();
    const plants: []f32 = try gpa.alloc(f32, 3 * starts.len * a);
    defer gpa.free(plants);
    const plant: []f32 = plants[0 .. starts.len * a];
    const expected: []f32 = plants[starts.len * a ..][0 .. starts.len * a];
    const decided: []f32 = plants[2 * starts.len * a ..][0 .. starts.len * a];
    for (plant, 0..) |*p, i| {
        p.* = 0.7 * (float(i % 5) / 2.0 - 1.0);
    }
    const scratch: []f32 = try gpa.alloc(f32, 3 * a + starts.len * a);
    defer gpa.free(scratch);
    const asked: []f32 = scratch[0..a];
    const asked_from_rest: []f32 = scratch[a..][0..a];
    const no_action: []f32 = scratch[2 * a ..][0..a];
    const ignoring: []f32 = scratch[3 * a ..][0 .. starts.len * a];
    @memset(no_action, 0.0);

    // Past the first step: the policy's answer for the planted value, blended into it.
    var judging: track.Judging = try .init(gpa, fleet.m, clip, fleet.options, &starts);
    defer judging.deinit();
    _ = judging.advance(actor, 1);
    try expect(judging.fleet.steps[0] == 1 and judging.fleet.steps[1] == 1);
    for (0..starts.len) |s| {
        learner.liveFeaturesOf(judging.fleet, s);
        learner.policyRow(learner.z_sim, learner.z_ref, plant[s * a ..][0..a], asked);
        learner.policyRow(learner.z_sim, learner.z_ref, no_action, asked_from_rest);
        @memcpy(expected[s * a ..][0..a], plant[s * a ..][0..a]);
        track.filterAction(0.2, asked, expected[s * a ..][0..a]);
        @memcpy(ignoring[s * a ..][0..a], plant[s * a ..][0..a]);
        track.filterAction(0.2, asked_from_rest, ignoring[s * a ..][0..a]);
    }
    @memcpy(decided, plant);
    actor.act(actor.context, judging.fleet, decided);
    try expect(eql(f32, decided, expected));
    try expect(!eql(f32, decided, ignoring));

    // An episode's first step: planted garbage, and the policy is told rest.
    var opening: track.Judging = try .init(gpa, fleet.m, clip, fleet.options, &starts);
    defer opening.deinit();
    try expect(opening.fleet.steps[0] == 0 and opening.fleet.steps[1] == 0);
    for (0..starts.len) |s| {
        learner.liveFeaturesOf(opening.fleet, s);
        learner.policyRow(learner.z_sim, learner.z_ref, no_action, asked);
        @memset(expected[s * a ..][0..a], 0.0);
        track.filterAction(0.2, asked, expected[s * a ..][0..a]);
    }
    @memcpy(decided, plant);
    actor.act(actor.context, opening.fleet, decided);
    try expect(eql(f32, decided, expected));
}

test "robot_latent: A1 - cloning hands the policy the applied action too" {
    // `cloneStep` trains THE policy on recorded states, so it must be the function the learner acts with: with
    // `sees_applied`, each recorded step's input includes the action applied before it (`appliedBefore` - rest on an
    // episode's first step). Known answer, the block planted so the input matters: the cloning loss equals the same
    // mean squared error computed row by row with `policyRow`. No filter and no clock: cloning refuses both (its
    // records must be raw decisions - see the test after this one).
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var setup: WalkSetup = undefined;
    setup.init(gpa, threaded.io(), 3) catch return error.SkipZigTest;
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const batch: usize = 3;
    const learner: *Learner = try .init(gpa, fleet, .{
        .hidden = 16,
        .window = 4,
        .batch = batch,
        .sees_applied = true,
        .world = .{ .hidden = 16, .steps = 4, .batch = batch },
    });
    defer learner.deinit();
    plantBlock(learner.applied_block.?.weights, 7);
    const steps = [batch]Learner.Step{
        .{ .env = 0, .index = 20 },
        .{ .env = 1, .index = 57 },
        .{ .env = 2, .index = 101 },
    };
    const f: usize = learner.features;
    const a: usize = learner.actions;
    const buffers: []f32 = try gpa.alloc(f32, 2 * f + 2 * a);
    defer gpa.free(buffers);
    const z: []f32 = buffers[0..f];
    const goal: []f32 = buffers[f..][0..f];
    const applied: []f32 = buffers[2 * f ..][0..a];
    const asked: []f32 = buffers[2 * f + a ..][0..a];
    var expected: f64 = 0.0;
    var any_applied: bool = false;
    for (steps) |step| {
        learner.world.featuresAt(fleet, step.env, step.index, z);
        learner.goalAt(step.env, step.index + 1, goal);
        try expect(Learner.appliedBefore(fleet, step.env, step.index, applied));
        for (applied) |x| {
            any_applied = any_applied or x != 0.0;
        }
        learner.policyRow(z, goal, applied, asked);
        for (asked, fleet.replay.actionAt(step.env, step.index)) |x, target| {
            expected += (@as(f64, x) - target) * (@as(f64, x) - target);
        }
    }
    try expect(any_applied);
    expected /= float(batch * a);
    const cloned: f32 = try learner.cloneStep(&steps);
    try expect(@abs(cloned - expected) <= 1.0e-5 * @max(1.0, @abs(expected)));
}

test "robot_latent: what the replay says was applied before a record is what collection applied - shoves, the ring" {
    // The filter's starting state for every training window and cloned step comes from the replay
    // (`appliedBefore`). The known answer is COLLECTION ITSELF: before each step, the slot every character is about
    // to decide from - rest on an episode's first step, where `decideInto` resets it. Recorded with SHOVES (a shove
    // ends a segment but not an episode, and the controller's filter carries straight through it - the old segment
    // rule said rest there), with short episodes so restarts happen, and long enough to wrap the ring. Every record
    // still in the ring must agree - except the oldest one of a wrapped ring, whose predecessor is gone: that one must
    // be reported UNKNOWN, never guessed, and training must refuse a window that starts there. And the HAND-OVER: a
    // learner taking over a fleet mid-episode starts its slots from what the fleet was applying, so the first record
    // agrees too. The run must contain shoves, restarts and an unknown, or it proves nothing about them.
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var setup: WalkSetup = undefined;
    setup.init(gpa, threaded.io(), 3) catch return error.SkipZigTest;
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    fleet.options.shove_every = 7;
    fleet.options.max_steps = 50;
    const learner: *Learner = try .init(gpa, fleet, .{
        .hidden = 16,
        .window = 4,
        .batch = 2,
        .decide_every = 2,
        .filter = 0.2,
        .sees_applied = true,
        .world = .{ .hidden = 16, .steps = 4, .batch = 2 },
    });
    defer learner.deinit();
    const envs: usize = fleet.options.envs;
    const a: usize = learner.actions;
    const capacity: usize = fleet.replay.capacity;
    // What collection was about to decide from, per ring slot - indexed like the replay, so a later record
    // overwrites an earlier one exactly where the replay's own ring does.
    const expected: []f32 = try gpa.alloc(f32, envs * capacity * a + a);
    defer gpa.free(expected);
    const told: []f32 = expected[envs * capacity * a ..][0..a];
    for (0..capacity + 23) |iteration| {
        for (0..envs) |env| {
            const index: u64 = fleet.replay.written[env];
            const ring_slot: usize = env * capacity + @as(usize, @intCast(index % capacity));
            const into: []f32 = expected[ring_slot * a ..][0..a];
            if (fleet.steps[env] == 0) {
                @memset(into, 0.0);
            } else {
                @memcpy(into, learner.fleet_actions[env * a ..][0..a]);
            }
        }
        learner.act(1, 1.0);
        // The HAND-OVER: the fleet was mid-episode, driven by WalkSetup's warm-up before this learner existed, so its
        // first record must say the learner's slot started from what the warm-up was applying. Checked now, before
        // the ring overwrites it.
        if (iteration == 0) {
            for (0..envs) |env| {
                const index: u64 = fleet.replay.written[env] - 1;
                const ring_slot: usize = env * capacity + @as(usize, @intCast(index % capacity));
                try expect(Learner.appliedBefore(fleet, env, index, told));
                try expect(eql(f32, told, expected[ring_slot * a ..][0..a]));
            }
        }
    }

    var shoves: usize = 0;
    var restarts: usize = 0;
    var unknown: usize = 0;
    var unknown_env: usize = 0;
    for (0..envs) |env| {
        const written: u64 = fleet.replay.written[env];
        const oldest: u64 = written -| @as(u64, @intCast(capacity));
        var index: u64 = oldest;
        while (index < written) : (index += 1) {
            if (!Learner.appliedBefore(fleet, env, index, told)) {
                // Only ever the oldest record, and only when it is not an episode's first step.
                try expect(index == oldest and oldest > 0);
                unknown += 1;
                unknown_env = env;
                continue;
            }
            const ring_slot: usize = env * capacity + @as(usize, @intCast(index % capacity));
            try expect(eql(f32, told, expected[ring_slot * a ..][0..a]));
            const opens_episode: bool = fleet.replay.episodeStepAt(env, index).? == 0;
            restarts += @intFromBool(opens_episode);
            const new_segment: bool = index > oldest and
                fleet.replay.segmentAt(env, index) != fleet.replay.segmentAt(env, index - 1);
            shoves += @intFromBool(new_segment and !opens_episode);
        }
    }
    try expect(shoves > 0 and restarts > 0 and unknown > 0);

    // Training refuses a window starting where the replay cannot say - before it writes anything.
    const unknown_start: u64 = fleet.replay.written[unknown_env] - capacity;
    var prng: Random.DefaultPrng = .init(3);
    const fine: track.Replay.Window = learner.drawWindow(prng.random(), 4) orelse return error.SkipZigTest;
    const windows = [2]track.Replay.Window{ fine, .{ .env = unknown_env, .first = unknown_start, .steps = 4 } };
    try expectError(error.UnknownAppliedAction, learner.trainPolicyOn(&windows));
    // And the learner's own draws never start there: a thousand of them, every start known.
    for (0..1000) |_| {
        const drawn: track.Replay.Window = learner.drawWindow(prng.random(), 4) orelse return error.SkipZigTest;
        try expect(Learner.appliedKnown(fleet, drawn.env, drawn.first));
    }
}

test "robot_latent: cloning refuses records that are not raw decisions - a filter or a clock" {
    // `cloneStep` regresses the policy's raw output on the RECORDED action. Behind a filter a record is a blend, and
    // under a clock half the records are held steps - neither is what the policy asked for, so a learner with
    // either refuses to clone rather than teach the policy to ask for what the filter delivers.
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var setup: WalkSetup = undefined;
    setup.init(gpa, threaded.io(), 2) catch return error.SkipZigTest;
    defer setup.deinit();
    const steps = [2]Learner.Step{ .{ .env = 0, .index = 20 }, .{ .env = 1, .index = 30 } };
    const settings = [2]struct { filter: f32, decide_every: u32 }{
        .{ .filter = 0.2, .decide_every = 1 },
        .{ .filter = 1.0, .decide_every = 2 },
    };
    for (settings) |setting| {
        const learner: *Learner = try .init(gpa, setup.fleet, .{
            .hidden = 16,
            .window = 4,
            .batch = 2,
            .filter = setting.filter,
            .decide_every = setting.decide_every,
            .world = .{ .hidden = 16, .steps = 4, .batch = 2 },
        });
        defer learner.deinit();
        try expectError(error.CloningNeedsRawActions, learner.cloneStep(&steps));
    }
}
