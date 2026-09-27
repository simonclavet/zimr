//! robot_ppo_track - PPO on a residual tracking policy: DReCon's reinforcement-learning half, on
//! one clip.
//!
//! The reference drives the character through the servo; the policy watches six bodies and nudges
//! twenty-seven degrees of freedom; PPO decides which nudges were worth making. Everything below is
//! bookkeeping around three pieces that already have known answers: the fleet (characters on a
//! floor, with rewards and episode ends per environment), the controller (a filtered, held,
//! subset action that is exactly zero when asked for zero), and `GpuPpoOn` (the clipped-surrogate
//! update on the kit, acting on the CPU).
//!
//! **One step for PPO is one DECISION**, not one physics step. The policy is asked every
//! `decimation` physics steps (DReCon's k = 2) and its action held in between, so a transition is
//! "observe, decide, then live with it for two steps": the reward is the mean over those steps and
//! the transition is terminal if either of them ended the episode. Rewards earned after an episode
//! ended - on the fresh start that replaced it - are not credited to the decision that failed.
//!
//! **The advantage is GAE** (lambda 0.95, gamma 0.99) and it is normalised over each iteration's
//! batch before the update, which is what keeps one iteration's lucky or unlucky episodes from
//! setting the step size for all of them.

const std = @import("std");
const zm = @import("zm");
const rbt = @import("robot.zig");
const track = @import("robot_track.zig");
const policy = @import("robot_policy.zig");
const gym = @import("robot_gym.zig");
const dance = @import("robot_dance.zig");
const compute_host = @import("compute_host.zig");

const Allocator = std.mem.Allocator;
const clamp = zm.clamp;
const assertf = zm.assertf;
const float = zm.float;
const bufPrint = std.fmt.bufPrint;

/// Every evaluation starts its episodes from the same frames, whatever training has done to the
/// training fleet's random stream.
pub const evaluation_seed: u64 = 20260920;

pub const Options = struct {
    envs: u32 = 16,
    /// Decisions per environment per iteration: 16 x 64 = 1,024 transitions an update.
    horizon: u32 = 64,
    epochs: u32 = 4,
    gamma: f32 = 0.99,
    lambda: f32 = 0.95,
    /// What a clip running out means to the advantage (MimicKit's choice is the default: its "success" earns
    /// nothing and nothing follows, which keeps a character from idling toward the end). `.bootstrap` counts it
    /// as CUT SHORT instead - the critic's value of where it ended follows. The step cap is always a cut.
    clip_end: ClipEnd = .terminal,
    /// Both networks' width. DReCon used 128 for ten minutes of locomotion steered by a user; one
    /// short clip is a much smaller function, and their own Fig 8 has small networks learning
    /// FASTER early on.
    hidden: u32 = 48,
    minibatch: u32 = 256,
    learning_rate: f32 = 3.0e-4,
    /// Exploration: exp(-0.5) = 0.61 in action units, which the controller turns into about a
    /// tenth of a radian of target offset before its filter smooths it.
    initial_log_std: f32 = -0.5,
    /// Normalise observations by their running mean and variance (clipped at five deviations).
    /// Off by default so the known answers above stay exact; a page turns it on. Networks learn
    /// far faster from inputs near zero with unit spread - velocities in m/s next to angles in
    /// radians next to heights in metres are not that.
    normalize: bool = false,
    /// The root assist's schedule (see `Gains.assist`): this much at the first batch, fading
    /// linearly to zero over `assist_batches`. Zero, the default, is the real task throughout.
    assist_start: f32 = 0.0,
    assist_batches: u32 = 300,
    /// Episodes end here even while tracking is fine (physics steps). Long clips want it long: a cap
    /// shorter than the clip would end good episodes early, and counting those as anything but
    /// survival would make the clip look harder than it is.
    max_episode_steps: u32 = 600,
    /// Radians per unit of the policy's action - the fleet's own default (0.2) unless set. Passed to every
    /// fleet the trainer builds, so the scale a policy was trained under is the one it is judged under.
    action_scale: f32 = 0.2,
    /// The task (`robot_track.Task`: servo, floor, floor rest, reward, failure rule), handed WHOLE to every fleet
    /// the trainer builds - training and judging - so a policy is trained and judged by the same rules. The old
    /// robot's by default; Geno's is `robot_geno.tracking_task`.
    task: track.Task = .{},
    /// DReCon's watched and actuated bodies, in this robot's names (the old robot's by default; Geno's is
    /// `robot_geno.drecon_bodies`).
    bodies: policy.Bodies = .{},
    /// What this network is trained FOR - an opaque number the caller chooses (a clip, say). It
    /// travels in the weights file, and a file with another tag is refused: a get-up policy and a
    /// dance policy have identical shapes, so nothing else would notice the difference.
    tag: u32 = 0,
    decimation: u32 = 2,
    beta: f32 = 0.2,
    seed: u64 = 1,
};

/// How one iteration went.
pub const Stats = struct {
    /// Physics steps watched and failures among them (the reference LOST - not the clip ending).
    /// Their ratio is the mean time to failure, the number a tracker is judged by: it does not
    /// shrink with the clip, and a perfect tracker's has no limit.
    exposure: u64 = 0,
    failures: u32 = 0,
    /// The root assist this batch was collected under. Numbers with assist > 0 are not the task.
    assist: f32 = 0,
    /// Decisions and physics steps taken so far, over all environments.
    decisions: u64,
    steps: u64,
    /// Mean reward per physics step, this iteration.
    mean_reward: f32,
    /// Episodes that ended this iteration, and their mean length in physics steps (zero when none
    /// did - which, once a policy is good, is the goal).
    episodes: u32,
    mean_episode: f32,
};

/// A batch's running totals while it is collected.
const Batch = struct {
    exposure: u64 = 0,
    failures: u32 = 0,
    reward_sum: f32 = 0.0,
    reward_steps: u32 = 0,
    ended: u32 = 0,
    ended_length: u64 = 0,
};

/// What a clip running out means to the advantage (`Options.clip_end`).
pub const ClipEnd = enum { terminal, bootstrap };

/// How one decision's transition ended, for the advantage.
pub const EndKind = enum(u8) {
    /// The episode went on: the next decision's value follows.
    none,
    /// Nothing follows: the reference was lost (or a clip's end counted as final, `ClipEnd.terminal`).
    stop,
    /// Cut short - the step cap, or a clip's end counted as a cut: what follows is the critic's value of the
    /// state the episode ended IN (`bootstrap`), not of the fresh start that replaced it.
    cut,
};

/// GAE along one environment's column of a rollout: element t of every array sits at `t * stride + offset`;
/// `values` has one more row - the state after the last decision. Writes `advantages` and `returns`. The
/// lambda-chain always breaks at an episode's end; what the end is WORTH depends on how it ended. Pure, so
/// its known answers are tested directly.
pub fn gaeColumn(
    rewards: []const f32,
    values: []const f32,
    ends: []const EndKind,
    bootstrap: []const f32,
    horizon: usize,
    stride: usize,
    offset: usize,
    gamma: f32,
    lambda: f32,
    advantages: []f32,
    returns: []f32,
) void {
    var running: f32 = 0.0;
    var t: usize = horizon;
    while (t > 0) {
        t -= 1;
        const at: usize = t * stride + offset;
        const next: f32 = switch (ends[at]) {
            .none => values[(t + 1) * stride + offset],
            .stop => 0.0,
            .cut => bootstrap[at],
        };
        const delta: f32 = rewards[at] + gamma * next - values[at];
        const carry: f32 = if (ends[at] == .none) 1.0 else 0.0;
        running = delta + gamma * lambda * carry * running;
        advantages[at] = running;
        returns[at] = running + values[at];
    }
}

pub fn Trainer(comptime M: type) type {
    return struct {
        const Self = @This();
        const Ppo = gym.GpuPpoOn(M);

        gpa: Allocator,
        arena: std.heap.ArenaAllocator,
        m: *rbt.Model,
        /// The caller's body names (it owns them, like `m`) - kept for the judge's fleet, which resolves the
        /// task's contact exemptions by name (`robot_track.Task.contact_exempt`) the same way the training one does.
        body_names: []const []const u8,
        options: Options,
        fleet: *track.Fleet,
        subset: policy.Subset,
        controller: policy.Controller,
        ppo: Ppo,
        rng: std.Random.DefaultPrng,
        n_obs: usize,
        // The rollout, laid out [decision][environment].
        observations: []f32,
        raw: []f32,
        log_probs: []f32,
        rewards: []f32,
        dones: []bool,
        /// How each decision's transition ended (`EndKind`), and - where it was cut short - the critic's
        /// value of the state the episode ended in.
        ends: []EndKind,
        bootstrap: []f32,
        values: []f32,
        advantages: []f32,
        returns: []f32,
        order: []u32,
        // Scratch.
        sim_state: track.State,
        reference_state: track.State,
        probe: rbt.Data,
        /// The reference now and further ahead, for every observation this trainer builds (`policy.observeFrom`).
        views: policy.Views,
        applied: []f32,
        obs_scratch: []f32,
        /// The observation normaliser: a running mean and sum of squared deviations per input,
        /// in f64 - with a count in the millions, an f32 mean stops moving long before it is right.
        obs_mean: []f64,
        obs_m2: []f64,
        obs_count: u64 = 0,
        episode_steps: []u32,
        decisions: u64 = 0,
        steps: u64 = 0,
        iterations: u64 = 0,
        /// How far into the current batch collection has got, and its running totals.
        cursor: usize = 0,
        batch: Batch = .{},

        pub fn init(
            gpa: Allocator,
            pipe: *compute_host.Compute(M),
            m: *rbt.Model,
            body_names: []const []const u8,
            clips: []const *const dance.Clip,
            options: Options,
        ) !*Self {
            const self: *Self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            // whole-init-first: the whole struct first - defaults applied, every field named.
            self.* = .{
                .gpa = undefined,
                .arena = undefined,
                .m = undefined,
                .body_names = undefined,
                .options = undefined,
                .fleet = undefined,
                .subset = undefined,
                .controller = undefined,
                .ppo = undefined,
                .rng = undefined,
                .n_obs = undefined,
                .observations = undefined,
                .raw = undefined,
                .log_probs = undefined,
                .rewards = undefined,
                .dones = undefined,
                .views = undefined,
                .ends = undefined,
                .bootstrap = undefined,
                .values = undefined,
                .advantages = undefined,
                .returns = undefined,
                .order = undefined,
                .sim_state = undefined,
                .reference_state = undefined,
                .probe = undefined,
                .applied = undefined,
                .obs_scratch = undefined,
                .obs_mean = undefined,
                .obs_m2 = undefined,
                .episode_steps = undefined,
            };
            self.arena = .init(gpa);
            errdefer self.arena.deinit();
            const owned: Allocator = self.arena.allocator();
            const bodies: policy.Bodies = options.bodies;
            const subset: policy.Subset = try policy.subsetFor(owned, m, body_names, bodies.watched, bodies.actuated);
            const n_obs: usize = policy.observationSize(subset);
            const envs: usize = options.envs;
            const transitions: usize = options.horizon * envs;
            self.* = .{
                .gpa = gpa,
                .arena = self.arena,
                .m = m,
                .body_names = body_names,
                .options = options,
                .fleet = try track.Fleet.init(owned, m, clips, .{
                    .envs = envs,
                    .capacity = 16,
                    .seed = options.seed,
                    .max_steps = options.max_episode_steps,
                    .action_scale = options.action_scale,
                    .task = options.task,
                    .body_names = body_names,
                }),
                .subset = subset,
                .controller = try policy.Controller.init(owned, m, subset, envs, .{
                    .beta = options.beta,
                    .decimation = options.decimation,
                }),
                .ppo = try Ppo.init(owned, pipe, n_obs, subset.dofs, .{
                    .hidden = options.hidden,
                    .rows = options.minibatch,
                    .learning_rate = options.learning_rate,
                    .initial_log_std = options.initial_log_std,
                    .seed = options.seed,
                }),
                .rng = .init(options.seed ^ 0x9e3779b97f4a7c15),
                .n_obs = n_obs,
                .observations = try owned.alloc(f32, transitions * n_obs),
                .raw = try owned.alloc(f32, transitions * subset.dofs),
                .log_probs = try owned.alloc(f32, transitions),
                .rewards = try owned.alloc(f32, transitions),
                .dones = try owned.alloc(bool, transitions),
                .views = try policy.Views.init(owned, m),
                .ends = try owned.alloc(EndKind, transitions),
                .bootstrap = try owned.alloc(f32, transitions),
                .values = try owned.alloc(f32, transitions + envs),
                .advantages = try owned.alloc(f32, transitions),
                .returns = try owned.alloc(f32, transitions),
                .order = try owned.alloc(u32, transitions),
                .sim_state = try track.State.init(owned, m.nbody),
                .reference_state = try track.State.init(owned, m.nbody),
                .probe = try rbt.Data.init(owned, m),
                .applied = try owned.alloc(f32, envs * subset.dofs),
                .obs_scratch = try owned.alloc(f32, n_obs),
                .obs_mean = try owned.alloc(f64, n_obs),
                .obs_m2 = try owned.alloc(f64, n_obs),
                .episode_steps = try owned.alloc(u32, envs),
            };
            @memset(self.episode_steps, 0);
            @memset(self.obs_mean, 0.0);
            @memset(self.obs_m2, 0.0);
            self.fleet.options.task.gains.assist = options.assist_start;
            for (self.order, 0..) |*slot, i| {
                slot.* = @intCast(i);
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            const gpa: Allocator = self.gpa;
            self.fleet.deinit();
            self.probe.deinit();
            self.arena.deinit();
            gpa.destroy(self);
        }

        /// The weights file's first bytes: a file that is not one says so instead of being read
        /// as one. The digit is the format's version - bump it whenever the layout changes.
        const magic: [8]u8 = "ZPPOTRK4".*;

        /// Everything before the numbers. The network's SHAPE travels with it, so weights from a
        /// differently shaped network are refused by name rather than loaded as the first N
        /// numbers of something else.
        const Header = extern struct {
            magic: [8]u8,
            observations: u32,
            actions: u32,
            hidden: u32,
            param_count: u32,
            adam_step: u32,
            /// Bit 0: a normaliser follows the weights (the observation means and variances).
            flags: u32 = 0,
            /// What the network was trained for (`Options.tag`).
            tag: u32 = 0,
            reserved: u32 = 0,
            decisions: u64,
            steps: u64,
            iterations: u64,
            /// How many observations the normaliser has seen.
            obs_count: u64 = 0,
        };

        /// The weights as a file's worth of bytes: both networks, Adam's two moments and its step,
        /// and how much experience has gone in - enough to carry on training exactly, or just to
        /// act. The caller owns the result.
        ///
        /// This is what a page offers for download. On a GPU the numbers come from the latest
        /// readback, so they may be a frame behind the update in flight, which for a file saved by
        /// hand is nothing.
        pub fn exportWeights(self: *Self, gpa: Allocator) ![]u8 {
            const count: usize = self.ppo.param_count;
            const params: []const f32 = self.ppo.pipe.readLatest(.params) orelse return error.NoReadback;
            const moment1: []const f32 = self.ppo.pipe.readLatest(.adam_m) orelse return error.NoReadback;
            const moment2: []const f32 = self.ppo.pipe.readLatest(.adam_v) orelse return error.NoReadback;
            if (params.len < count or moment1.len < count or moment2.len < count) {
                return error.NoReadback;
            }
            const header: Header = .{
                .magic = magic,
                .observations = @intCast(self.n_obs),
                .actions = @intCast(self.subset.dofs),
                .hidden = self.options.hidden,
                .param_count = @intCast(count),
                .adam_step = self.ppo.adam_step,
                .decisions = self.decisions,
                .steps = self.steps,
                .iterations = self.iterations,
                .flags = if (self.options.normalize) 1 else 0,
                .tag = self.options.tag,
                .obs_count = self.obs_count,
            };
            // The normaliser rides after the weights: a network trained on normalised inputs,
            // loaded without the statistics that normalised them, is a different network.
            const normaliser: usize = if (self.options.normalize) 2 * self.n_obs else 0;
            const floats: usize = 3 * count + normaliser;
            const bytes: []u8 = try gpa.alloc(u8, @sizeOf(Header) + floats * @sizeOf(f32));
            @memcpy(bytes[0..@sizeOf(Header)], std.mem.asBytes(&header));
            var at: usize = @sizeOf(Header);
            for ([_][]const f32{ params[0..count], moment1[0..count], moment2[0..count] }) |part| {
                const raw: []const u8 = std.mem.sliceAsBytes(part);
                @memcpy(bytes[at..][0..raw.len], raw);
                at += raw.len;
            }
            if (self.options.normalize) {
                const n: f64 = @floatFromInt(@max(self.obs_count, 1));
                for (self.obs_mean) |mean| {
                    const value: f32 = @floatCast(mean);
                    @memcpy(bytes[at..][0..4], std.mem.asBytes(&value));
                    at += 4;
                }
                for (self.obs_m2) |m2| {
                    const value: f32 = @floatCast(m2 / n);
                    @memcpy(bytes[at..][0..4], std.mem.asBytes(&value));
                    at += 4;
                }
            }
            return bytes;
        }

        /// Carry on from weights someone saved - on this device or another - or fail saying why.
        pub fn importWeights(self: *Self, bytes: []const u8) !void {
            if (bytes.len < @sizeOf(Header)) {
                return error.NotAWeightsFile;
            }
            const header: Header = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
            if (!std.mem.eql(u8, &header.magic, &magic)) {
                return error.NotAWeightsFile;
            }
            const count: usize = self.ppo.param_count;
            if (header.observations != self.n_obs or header.actions != self.subset.dofs or
                header.hidden != self.options.hidden or header.param_count != count)
            {
                return error.WeightsShape;
            }
            if (header.tag != self.options.tag) {
                return error.WeightsForAnotherTask;
            }
            const has_normaliser: bool = header.flags & 1 != 0;
            // A file and a trainer must agree on normalising: inputs scaled one way and read the
            // other are exactly the silent mismatch the shape check exists to prevent.
            if (has_normaliser != self.options.normalize) {
                return error.WeightsShape;
            }
            const normaliser: usize = if (has_normaliser) 2 * self.n_obs else 0;
            if (bytes.len != @sizeOf(Header) + (3 * count + normaliser) * @sizeOf(f32)) {
                return error.NotAWeightsFile;
            }
            // Copied into aligned floats: the bytes came from a file and owe nothing to alignment.
            const values: []f32 = try self.gpa.alloc(f32, 3 * count);
            defer self.gpa.free(values);
            @memcpy(std.mem.sliceAsBytes(values), bytes[@sizeOf(Header)..][0 .. 3 * count * @sizeOf(f32)]);
            self.ppo.pipe.upload(.params, values[0..count]);
            self.ppo.pipe.upload(.adam_m, values[count .. 2 * count]);
            self.ppo.pipe.upload(.adam_v, values[2 * count .. 3 * count]);
            @memcpy(self.ppo.cpu_params, values[0..count]);
            self.ppo.adam_step = header.adam_step;
            self.decisions = header.decisions;
            self.steps = header.steps;
            self.iterations = header.iterations;
            if (has_normaliser) {
                const extra: []f32 = try self.gpa.alloc(f32, normaliser);
                defer self.gpa.free(extra);
                const start: usize = @sizeOf(Header) + 3 * count * @sizeOf(f32);
                @memcpy(std.mem.sliceAsBytes(extra), bytes[start..]);
                self.obs_count = header.obs_count;
                const n: f64 = @floatFromInt(@max(self.obs_count, 1));
                const means: []const f32 = extra[0..self.n_obs];
                const variances: []const f32 = extra[self.n_obs..];
                for (self.obs_mean, self.obs_m2, means, variances) |*mean, *m2, saved_mean, saved_var| {
                    mean.* = saved_mean;
                    m2.* = @as(f64, saved_var) * n;
                }
            }
            // A batch half-collected under the old weights would be judged against the new ones.
            self.cursor = 0;
            self.batch = .{};
        }

        /// The weights to a file, for runs on a machine with a disk. Written to a temporary name
        /// and renamed into place, so a run killed mid-write keeps its previous file intact.
        pub fn save(self: *Self, io: std.Io, path: []const u8) !void {
            const bytes: []u8 = try self.exportWeights(self.gpa);
            defer self.gpa.free(bytes);
            if (std.fs.path.dirname(path)) |dir| {
                try std.Io.Dir.cwd().createDirPath(io, dir);
            }
            var temp_buffer: [512]u8 = undefined;
            const temp: []const u8 = try bufPrint(&temp_buffer, "{s}.partial", .{path});
            {
                const file: std.Io.File = try std.Io.Dir.cwd().createFile(io, temp, .{});
                defer file.close(io);
                try file.writeStreamingAll(io, bytes);
            }
            try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), path, io);
        }

        /// And back. False when there is no file, which is how a run starts.
        pub fn load(self: *Self, io: std.Io, path: []const u8) !bool {
            const file: std.Io.File = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return err,
            };
            defer file.close(io);
            const info: std.Io.File.Stat = try file.stat(io);
            const bytes: []u8 = try self.gpa.alloc(u8, info.size);
            defer self.gpa.free(bytes);
            _ = try file.readPositionalAll(io, bytes, 0);
            try self.importWeights(bytes);
            return true;
        }

        /// One environment's observation, as the policy sees it now.
        /// Welford's running mean and variance, then the observation rescaled in place. `learn`
        /// is true while collecting (the statistics move) and false when judging or bootstrapping
        /// (they do not). A no-op unless `options.normalize`.
        /// An observation scaled as the policy sees it, without touching the statistics.
        pub fn normalizeObservation(self: *Self, obs: []f32) void {
            self.normalize(obs, false);
        }

        fn normalize(self: *Self, obs: []f32, learn_stats: bool) void {
            if (!self.options.normalize) {
                return;
            }
            if (learn_stats) {
                self.obs_count += 1;
                const n: f64 = @floatFromInt(self.obs_count);
                for (obs, self.obs_mean, self.obs_m2) |x, *mean, *m2| {
                    const delta: f64 = @as(f64, x) - mean.*;
                    mean.* += delta / n;
                    m2.* += delta * (@as(f64, x) - mean.*);
                }
            }
            const n: f64 = @floatFromInt(@max(self.obs_count, 1));
            for (obs, self.obs_mean, self.obs_m2) |*x, mean, m2| {
                const deviation: f64 = @sqrt(m2 / n + 1.0e-8);
                const z_score: f64 = (@as(f64, x.*) - mean) / deviation;
                x.* = @floatCast(@max(-5.0, @min(5.0, z_score)));
            }
        }

        /// The observation of the state an episode ENDED in (the fleet's capture, before its restart), with
        /// the filter as it stood - what a cut-short episode is bootstrapped from.
        fn observeTerminal(self: *Self, env: usize, out: []f32) void {
            const fleet: *track.Fleet = self.fleet;
            policy.observeFrom(
                self.m,
                self.subset,
                fleet,
                fleet.clips[fleet.terminal_clip[env]],
                fleet.terminal_frame[env],
                fleet.terminal[env],
                &self.views,
                self.controller.lastAction(env),
                out,
            );
        }

        fn observe(self: *Self, env: usize, out: []f32) void {
            const fleet: *track.Fleet = self.fleet;
            track.stateOf(self.m, &fleet.data[env], &self.sim_state);
            policy.observeFrom(
                self.m,
                self.subset,
                fleet,
                fleet.clips[fleet.clip_of[env]],
                fleet.frame[env],
                self.sim_state,
                &self.views,
                self.controller.lastAction(env),
                out,
            );
        }

        /// Collect a batch, work out the advantages, and update. Returns how it went.
        /// Fill up to `decisions` more decisions of the current batch, for every environment.
        /// True when the batch is full and `learn` should run.
        ///
        /// This is the unit a phone frame can afford: a few decisions, then back to drawing. The
        /// newest weights are picked up first - on a GPU the update's readback lands a frame or
        /// more after `learn` dispatched it, and until it does the policy acts on the weights it
        /// has, which is the lag PPO's clipped ratio is there to absorb.
        pub fn collect(self: *Self, decisions: usize) bool {
            _ = self.ppo.syncWeights();
            var taken: usize = 0;
            while (taken < decisions and self.cursor < self.options.horizon) : (taken += 1) {
                self.collectOne(self.cursor);
                self.cursor += 1;
            }
            return self.cursor >= self.options.horizon;
        }

        /// One decision for every environment, into row `t` of the batch.
        fn collectOne(self: *Self, t: usize) void {
            const envs: usize = self.options.envs;
            const dofs: usize = self.subset.dofs;
            const random: std.Random = self.rng.random();
            for (0..envs) |env| {
                const at: usize = t * envs + env;
                const obs: []f32 = self.observations[at * self.n_obs ..][0..self.n_obs];
                self.observe(env, obs);
                self.normalize(obs, true);
                const action: []f32 = self.raw[at * dofs ..][0..dofs];
                self.log_probs[at] = self.ppo.act(obs, action, random);
                self.values[at] = self.ppo.value(obs);
                // The log-probability is of the sample PPO drew; what reaches the character is
                // clamped to the range the controller expects.
                for (self.applied[env * dofs ..][0..dofs], action) |*applied, a| {
                    applied.* = clamp(a, -1.0, 1.0);
                }
                self.rewards[at] = 0.0;
                self.dones[at] = false;
                self.ends[at] = .none;
                self.bootstrap[at] = 0.0;
            }
            // Live with the decision for `decimation` physics steps.
            const hold: u32 = @max(self.options.decimation, 1);
            for (0..hold) |_| {
                const full: []const f32 = self.controller.apply(self.applied);
                _ = self.fleet.step(full);
                self.steps += envs;
                for (0..envs) |env| {
                    const at: usize = t * envs + env;
                    self.episode_steps[env] += 1;
                    self.batch.exposure += 1;
                    if (self.fleet.failures[env]) {
                        self.batch.failures += 1;
                    }
                    if (!self.dones[at]) {
                        self.rewards[at] += self.fleet.rewards[env] / float(hold);
                        self.batch.reward_sum += self.fleet.rewards[env];
                        self.batch.reward_steps += 1;
                    }
                    if (self.fleet.dones[env]) {
                        // How it ended, for the advantage - and, when it was cut short, what the state it
                        // ended in is worth, valued before the filter it acted through is forgotten.
                        if (!self.dones[at]) {
                            self.ends[at] = switch (self.fleet.ends[env]) {
                                .lost => .stop,
                                .cap => .cut,
                                .clip_end => if (self.options.clip_end == .bootstrap) .cut else .stop,
                            };
                            if (self.ends[at] == .cut) {
                                self.observeTerminal(env, self.obs_scratch);
                                self.normalize(self.obs_scratch, false);
                                self.bootstrap[at] = self.ppo.value(self.obs_scratch);
                            }
                        }
                        self.dones[at] = true;
                        self.controller.forget(env);
                        self.batch.ended += 1;
                        self.batch.ended_length += self.episode_steps[env];
                        self.episode_steps[env] = 0;
                    }
                }
            }
            self.decisions += envs;
        }

        /// The batch is full: bootstrap its last values, work out the advantages, and dispatch
        /// the update. Returns how the batch went and starts the next one.
        pub fn learn(self: *Self) !Stats {
            const envs: usize = self.options.envs;
            const horizon: usize = self.options.horizon;
            assertf(self.cursor >= horizon, @src(), "learn with {d} of {d} decisions collected", .{
                self.cursor,
                horizon,
            });
            // The value of where each environment ended up, to bootstrap the last decisions.
            for (0..envs) |env| {
                self.observe(env, self.obs_scratch);
                self.normalize(self.obs_scratch, false);
                self.values[horizon * envs + env] = self.ppo.value(self.obs_scratch);
            }

            self.computeAdvantages();
            try self.update(self.rng.random());
            _ = self.ppo.syncWeights();
            self.iterations += 1;

            const batch: Batch = self.batch;
            self.batch = .{};
            self.cursor = 0;
            const assist_now: f32 = self.fleet.options.task.gains.assist;
            // The next batch's helping hand: linearly down to nothing over `assist_batches`.
            const fade: f32 = float(self.iterations) / float(@max(self.options.assist_batches, 1));
            self.fleet.options.task.gains.assist = self.options.assist_start * @max(0.0, 1.0 - fade);
            return .{
                .exposure = batch.exposure,
                .failures = batch.failures,
                .assist = assist_now,
                .decisions = self.decisions,
                .steps = self.steps,
                .mean_reward = if (batch.reward_steps > 0) batch.reward_sum / float(batch.reward_steps) else 0.0,
                .episodes = batch.ended,
                .mean_episode = if (batch.ended > 0) float(batch.ended_length) / float(batch.ended) else 0.0,
            };
        }

        /// A whole batch in one call: `collect` until full, then `learn`. What a test or a
        /// chunk wants; a page calls the two halves itself, a slice per frame.
        pub fn iterate(self: *Self) !Stats {
            while (!self.collect(self.options.horizon)) {}
            return self.learn();
        }

        /// How the policy does when it is JUDGED: its mean action, no exploration, no learning -
        /// over `decisions` decisions per environment. With `servo_only` the action is exactly zero
        /// instead, which is the baseline every policy has to beat.
        ///
        /// **On fixed starts, in a fleet of its own.** Judging on the training fleet would continue
        /// its random stream, so every evaluation - and the policy and the servo within one - would
        /// start from different frames, and differences between them would be partly luck. Here
        /// both are judged on the same starts every time, which makes the servo's number a
        /// constant: if it ever changes between chunks, something other than the policy did.
        /// What cloning did: the mean square error between the policy's mean and the teacher's actions over
        /// every demonstration (per action number), before and after.
        pub const CloneResult = struct { before: f32, after: f32 };

        /// BEHAVIOUR CLONING (D5 step 3): teach the policy a teacher's decisions - before PPO, or between its
        /// updates. `observations`: rows x n_obs, RAW, exactly as `policy.observe` builds them (the teacher's
        /// filter state as the last action); `labels`: rows x n_act - the teacher's raw actions / the action
        /// scale, so in the policy's own units.
        ///
        /// First the normaliser: every demonstration goes through Welford, just as if PPO had collected it -
        /// so the clone learns on inputs scaled the way PPO will scale them, and PPO carries on updating the
        /// statistics from its own data afterwards. Then `updates` minibatches (`options.minibatch` rows drawn at
        /// random, each normalised by the same `normalize`) through `cloneMinibatch` - PPO's own policy chain,
        /// with the mean-square-error gradient in place of PPO's head, the log-std and value left alone.
        pub fn clone(
            self: *Self,
            observations: []const f32,
            labels: []const f32,
            updates: usize,
            seed: u64,
        ) !CloneResult {
            const n_obs: usize = self.n_obs;
            const n_act: usize = self.subset.dofs;
            const rows: usize = labels.len / n_act;
            assertf(
                observations.len == rows * n_obs and rows > 0,
                @src(),
                "clone: {d} observations for {d} labels of {d}",
                .{ observations.len, rows, n_act },
            );
            const scratch: []f32 = self.obs_scratch[0..n_obs];
            for (0..rows) |row| {
                @memcpy(scratch, observations[row * n_obs ..][0..n_obs]);
                self.normalize(scratch, true);
            }
            const before: f32 = self.cloneError(observations, labels);
            const batch: usize = self.options.minibatch;
            const x: []f32 = try self.gpa.alloc(f32, batch * n_obs);
            defer self.gpa.free(x);
            const y: []f32 = try self.gpa.alloc(f32, batch * n_act);
            defer self.gpa.free(y);
            var rng: std.Random.DefaultPrng = .init(seed);
            const random: std.Random = rng.random();
            for (0..updates) |_| {
                for (0..batch) |r| {
                    const row: usize = random.uintLessThan(usize, rows);
                    const into: []f32 = x[r * n_obs ..][0..n_obs];
                    @memcpy(into, observations[row * n_obs ..][0..n_obs]);
                    self.normalize(into, false);
                    @memcpy(y[r * n_act ..][0..n_act], labels[row * n_act ..][0..n_act]);
                }
                self.ppo.cloneMinibatch(x, y);
            }
            _ = self.ppo.syncWeights();
            return .{ .before = before, .after = self.cloneError(observations, labels) };
        }

        /// The mean square error, per action number, between the policy's mean and the labels - over every row,
        /// on the CPU copy of the weights.
        pub fn cloneError(self: *Self, observations: []const f32, labels: []const f32) f32 {
            const n_obs: usize = self.n_obs;
            const n_act: usize = self.subset.dofs;
            const rows: usize = labels.len / n_act;
            const scratch: []f32 = self.obs_scratch[0..n_obs];
            var total: f64 = 0.0;
            for (0..rows) |row| {
                @memcpy(scratch, observations[row * n_obs ..][0..n_obs]);
                self.normalize(scratch, false);
                for (self.ppo.meanOf(scratch), labels[row * n_act ..][0..n_act]) |mean, label| {
                    total += (mean - label) * (mean - label);
                }
            }
            return @floatCast(total / @as(f64, @floatFromInt(rows * n_act)));
        }

        pub fn evaluate(self: *Self, decisions: usize, servo_only: bool) !Stats {
            const envs: usize = self.options.envs;
            const dofs: usize = self.subset.dofs;
            const hold: u32 = @max(self.options.decimation, 1);
            const judge: *track.Fleet = try track.Fleet.init(self.gpa, self.m, self.fleet.clips, .{
                .envs = envs,
                .capacity = 16,
                .seed = evaluation_seed,
                .action_scale = self.options.action_scale,
                .task = self.options.task,
                .body_names = self.body_names,
            });
            defer judge.deinit();
            var controller: policy.Controller = try policy.Controller.init(self.gpa, self.m, self.subset, envs, .{
                .beta = self.options.beta,
                .decimation = self.options.decimation,
            });
            defer controller.deinit();
            const lengths: []u32 = try self.gpa.alloc(u32, envs);
            defer self.gpa.free(lengths);
            @memset(lengths, 0);
            var reward_sum: f32 = 0.0;
            var reward_steps: u32 = 0;
            // Counted exactly as training counts them: a unit of exposure per physics step per character, and
            // a failure when the fleet says the reference was LOST (not the clip ending). Their ratio is the
            // mean time to failure. (Until Sep 25 `evaluate` left both at zero - and a test printed that.)
            var exposure: u64 = 0;
            var failures: u32 = 0;
            var ended: u32 = 0;
            var ended_length: u64 = 0;
            for (0..decisions) |_| {
                for (0..envs) |env| {
                    const slot: []f32 = self.applied[env * dofs ..][0..dofs];
                    if (servo_only) {
                        @memset(slot, 0.0);
                    } else {
                        track.stateOf(self.m, &judge.data[env], &self.sim_state);
                        policy.observeFrom(
                            self.m,
                            self.subset,
                            judge,
                            judge.clips[judge.clip_of[env]],
                            judge.frame[env],
                            self.sim_state,
                            &self.views,
                            controller.lastAction(env),
                            self.obs_scratch,
                        );
                        self.normalize(self.obs_scratch, false);
                        self.ppo.actMean(self.obs_scratch, slot);
                        for (slot) |*a| {
                            a.* = clamp(a.*, -1.0, 1.0);
                        }
                    }
                }
                for (0..hold) |_| {
                    const full: []const f32 = controller.apply(self.applied);
                    _ = judge.step(full);
                    for (0..envs) |env| {
                        lengths[env] += 1;
                        exposure += 1;
                        if (judge.failures[env]) {
                            failures += 1;
                        }
                        reward_sum += judge.rewards[env];
                        reward_steps += 1;
                        if (judge.dones[env]) {
                            controller.forget(env);
                            ended += 1;
                            ended_length += lengths[env];
                            lengths[env] = 0;
                        }
                    }
                }
            }
            return .{
                .decisions = self.decisions,
                .steps = self.steps,
                .mean_reward = if (reward_steps > 0) reward_sum / float(reward_steps) else 0.0,
                .episodes = ended,
                .mean_episode = if (ended > 0) float(ended_length) / float(ended) else 0.0,
                .exposure = exposure,
                .failures = failures,
            };
        }

        /// GAE over each environment's column of the rollout, then normalised over the batch.
        fn computeAdvantages(self: *Self) void {
            const envs: usize = self.options.envs;
            for (0..envs) |env| {
                gaeColumn(
                    self.rewards,
                    self.values,
                    self.ends,
                    self.bootstrap,
                    self.options.horizon,
                    envs,
                    env,
                    self.options.gamma,
                    self.options.lambda,
                    self.advantages,
                    self.returns,
                );
            }
            var mean: f32 = 0.0;
            for (self.advantages) |a| {
                mean += a;
            }
            mean /= float(self.advantages.len);
            var spread: f32 = 0.0;
            for (self.advantages) |a| {
                spread += (a - mean) * (a - mean);
            }
            const deviation: f32 = @sqrt(spread / float(self.advantages.len)) + 1.0e-6;
            for (self.advantages) |*a| {
                a.* = (a.* - mean) / deviation;
            }
        }

        /// `epochs` passes over the batch in shuffled minibatches.
        fn update(self: *Self, random: std.Random) !void {
            const dofs: usize = self.subset.dofs;
            const rows: usize = self.options.minibatch;
            const transitions: usize = self.order.len;
            for (0..self.options.epochs) |_| {
                random.shuffle(u32, self.order);
                var first: usize = 0;
                while (first + rows <= transitions) : (first += rows) {
                    const staged = self.ppo.stage();
                    for (0..rows) |row| {
                        const at: usize = self.order[first + row];
                        const obs: []const f32 = self.observations[at * self.n_obs ..][0..self.n_obs];
                        @memcpy(staged.obs[row * self.n_obs ..][0..self.n_obs], obs);
                        @memcpy(staged.act[row * dofs ..][0..dofs], self.raw[at * dofs ..][0..dofs]);
                        staged.old[row] = self.log_probs[at];
                        staged.adv[row] = self.advantages[at];
                        staged.ret[row] = self.returns[at];
                    }
                    self.ppo.trainMinibatch();
                }
            }
        }
    };
}

/// The get-up proper: 9 s to 14 s of the capture - lying on the floor at the start, standing at the
/// end (the hips go from 6 cm to 81 cm across it).
pub const getup_first: usize = 540;
/// Five seconds of the walk, after its first second: the control run.
pub const walk_first: usize = 60;
pub const window_frames: usize = 300;
