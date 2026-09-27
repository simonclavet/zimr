//! robot_track_resident - SuperTrack's training loop with everything but the simulation on the GPU.
//!
//! One round is the paper's iteration, split by what each processor is good at:
//!
//!   * **The CPU simulates and acts.** For every character, every step: its features, the policy's
//!     action from a MIRROR of the GPU's weights, and the step. Acting stays here because reading
//!     anything back from a GPU is asynchronous - the answer arrives a frame or so later - while the
//!     simulator needs its action now. The mirror is refreshed whenever the weights are read back;
//!     being a frame behind costs nothing, since weights move slowly.
//!   * **The CPU records** each step into the ring - one small upload for every character at once.
//!   * **The GPU learns.** The world model trains through its own rollouts, and the policy through the
//!     world model, on windows the GPU gathers itself from the ring and the reference tables. Each
//!     update takes its own window-start slot, because in a frame every upload lands before any of
//!     the frame's work runs.
//!
//! The pieces below it are checked against the CPU reference elsewhere: the gather and both training
//! steps follow `robot_latent`'s and `robot_track_st`'s own code to a few parts in a million. What
//! this file adds is the loop that puts them together, and the mirror that lets the simulation act.

const std = @import("std");
const zm = @import("zm");
const rbt = @import("robot.zig");
const track = @import("robot_track.zig");
const dance = @import("robot_dance.zig");
const latent = @import("robot_latent.zig");
const kit_mod = @import("robot_latent_kit.zig");
const compute_host = @import("compute_host.zig");

const Allocator = std.mem.Allocator;
const float = zm.float;
const assertf = zm.assertf;

pub const Options = struct {
    /// Windows per update, and steps per window.
    rows: u32 = 16,
    window: u32 = 8,
    /// The world model's width, and the policy's.
    hidden: u32 = 64,
    policy_hidden: u32 = 64,
    world_rate: f32 = 1.0e-3,
    policy_rate: f32 = 3.0e-4,
    /// Exploration noise, in units of the policy's raw output - in the simulator while collecting, and
    /// inside every training rollout.
    sigma: f32 = 0.1,
    /// The price on the size of the raw action, beside the policy's tracking loss.
    w_action: f32 = 0.01,
    /// The smoothness price on the policy's action along a window (CAPS; `robot_latent.LearnerOptions.w_smooth`).
    w_smooth: f32 = 0.0,
    /// One round: this many simulation steps, then this many updates of each network.
    collect: u32 = 32,
    world_updates: u32 = 1,
    policy_updates: u32 = 1,
    seed: u64 = 1,
};

pub fn Resident(comptime M: type) type {
    return struct {
        const Self = @This();
        const Kit = kit_mod.LatentKit(M);

        gpa: Allocator,
        options: Options,
        fleet: *track.Fleet,
        kit: Kit,
        data: kit_mod.Resident(M),
        /// Physics steps watched while collecting, and the failures among them - the reference LOST,
        /// not a clip simply running out. Exactly what the PPO bench counts, so a milestone reached
        /// here and one reached there mean the same thing.
        ///
        /// These are steps taken WITH exploration noise, because that is how data is collected. They
        /// therefore say how long the policy-plus-noise tracks, which is not the same question as how
        /// long the POLICY tracks - and comparing them against a servo measured without noise flatters
        /// the servo. The pair below answers the second question.
        exposure: u64,
        failures: u64,
        /// The same two, for steps taken with the noise turned off: the policy as it would actually be
        /// used, and the only number comparable with the servo's own.
        judged_exposure: u64,
        judged_failures: u64,
        /// Updates so far, which also seed the rollouts' noise.
        world_updates: u32,
        policy_updates: u32,
        /// Readbacks refused because a weight was not finite (the mirror kept the last good ones), and
        /// actions the policy produced that were not finite (replaced by zero - the servo alone). Both
        /// should stay 0; if either climbs, training has blown up on the device - and now it says so
        /// instead of feeding NaN to the physics.
        mirror_rejected: u64,
        nonfinite_actions: u64,
        rng: std.Random.DefaultPrng,
        /// The policy's weights as the CPU last saw them - what acting uses.
        mirror: []f32,
        /// The normaliser, host-side, for the features acting needs.
        norm: latent.Normalizer,
        // Scratch for acting.
        sim: track.State,
        reference: track.State,
        probe: rbt.Data,
        raw_features: []f32,
        z: []f32,
        goal: []f32,
        raw: []f32,
        hidden1: []f32,
        hidden2: []f32,
        actions: []f32,
        starts: []kit_mod.Start,

        /// Build the loop on a fleet whose replay already holds data, with the normaliser it should
        /// use (the reference clips' statistics, or the replay's). The tables are uploaded here; the
        /// ring is filled by `act`, so call it before training on anything.
        pub fn init(
            gpa: Allocator,
            pipe: *compute_host.Compute(M),
            fleet: *track.Fleet,
            norm: latent.Normalizer,
            options: Options,
        ) !*Self {
            const self: *Self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            const m: *rbt.Model = fleet.m;
            const feature_count: u32 = @intCast(track.localSize(m.nbody));
            const actions: u32 = @intCast(track.actionSize(m));
            // whole-init-first: the whole struct first - defaults applied, every field named.
            self.* = .{
                .gpa = undefined,
                .options = undefined,
                .fleet = undefined,
                .kit = undefined,
                .data = undefined,
                .exposure = undefined,
                .failures = undefined,
                .judged_exposure = undefined,
                .judged_failures = undefined,
                .world_updates = undefined,
                .policy_updates = undefined,
                .mirror_rejected = undefined,
                .nonfinite_actions = undefined,
                .rng = undefined,
                .mirror = undefined,
                .norm = undefined,
                .sim = undefined,
                .reference = undefined,
                .probe = undefined,
                .raw_features = undefined,
                .z = undefined,
                .goal = undefined,
                .raw = undefined,
                .hidden1 = undefined,
                .hidden2 = undefined,
                .actions = undefined,
                .starts = undefined,
            };
            self.gpa = gpa;
            self.options = options;
            self.fleet = fleet;
            // Everything set here rather than by field defaults: `gpa.create` hands back uninitialised
            // memory, so a default written on a field would never be applied.
            self.exposure = 0;
            self.failures = 0;
            self.mirror_rejected = 0;
            self.nonfinite_actions = 0;
            self.judged_exposure = 0;
            self.judged_failures = 0;
            self.world_updates = 0;
            self.policy_updates = 0;
            self.rng = .init(options.seed);
            self.kit = try .init(
                pipe,
                feature_count,
                @intCast(track.targetSize(m)),
                actions,
                options.hidden,
                options.rows,
                options.window,
                feature_count,
                options.policy_hidden,
            );
            self.kit.sigma = options.sigma;
            self.kit.w_action = options.w_action;
            self.kit.w_smooth = options.w_smooth;
            // The kit's action scale stays 1: the fleet applies the one scale, and the world model
            // learns from the action the fleet records - the raw output plus its noise.
            const slots: u32 = options.world_updates + options.policy_updates;
            self.data = try .init(gpa, pipe, fleet, self.kit.total, options.rows, slots);
            errdefer self.data.deinit();
            self.data.uploadTables(fleet);
            self.data.uploadNormalizer(norm);
            self.norm = .{
                .mean = try gpa.dupe(f32, norm.mean),
                .spread = try gpa.dupe(f32, norm.spread),
            };
            errdefer gpa.free(self.norm.mean);
            errdefer gpa.free(self.norm.spread);
            self.mirror = try gpa.alloc(f32, self.kit.policy_count);
            errdefer gpa.free(self.mirror);
            // ZEROED, not left as `alloc` found it: if the first readback cannot fill it (the host's
            // readback window starts at nothing), acting would otherwise run on uninitialised memory
            // and simulate nonsense for a whole round. All zeros is the servo alone - no correction.
            @memset(self.mirror, 0.0);
            self.sim = try track.State.init(gpa, m.nbody);
            errdefer self.sim.deinit(gpa);
            self.reference = try track.State.init(gpa, m.nbody);
            errdefer self.reference.deinit(gpa);
            self.probe = try rbt.Data.init(gpa, m);
            errdefer self.probe.deinit();
            self.raw_features = try gpa.alloc(f32, feature_count);
            errdefer gpa.free(self.raw_features);
            self.z = try gpa.alloc(f32, feature_count);
            errdefer gpa.free(self.z);
            self.goal = try gpa.alloc(f32, feature_count);
            errdefer gpa.free(self.goal);
            self.raw = try gpa.alloc(f32, actions);
            errdefer gpa.free(self.raw);
            self.hidden1 = try gpa.alloc(f32, options.policy_hidden);
            errdefer gpa.free(self.hidden1);
            self.hidden2 = try gpa.alloc(f32, options.policy_hidden);
            errdefer gpa.free(self.hidden2);
            self.actions = try gpa.alloc(f32, fleet.options.envs * actions);
            errdefer gpa.free(self.actions);
            self.starts = try gpa.alloc(kit_mod.Start, options.rows);
            errdefer gpa.free(self.starts);
            // The readback has to reach the policy's weights, or the mirror can never be refreshed and
            // the simulation would act on the seeded weights for ever. Widen it, never narrow it: the
            // caller may want more of the buffers than this.
            const needed: u32 = self.kit.p_at + self.kit.policy_count;
            pipe.element_count = @max(pipe.element_count, needed);
            try self.seedWeights();
            self.syncMirror();
            return self;
        }

        /// Both networks' starting weights, and a clean optimiser: Xavier for the tanh layers, and a
        /// near-zero output layer each, so the world model starts as "nothing changes" and the policy
        /// as "no correction" - the servo alone. Without this the weights would be whatever the buffer
        /// held; all zeros, and no gradient could ever break their symmetry.
        fn seedWeights(self: *Self) !void {
            const kit: Kit = self.kit;
            const total: usize = kit.param_count + kit.policy_count;
            const weights: []f32 = try self.gpa.alloc(f32, total);
            defer self.gpa.free(weights);
            const random: std.Random = self.rng.random();
            const f: usize = self.z.len;
            const r: usize = kit.references;
            const a: usize = self.raw.len;
            const h: usize = kit.hidden;
            const hp: usize = self.hidden1.len;
            // Each layer as (how many weights, its fan-in, whether it is a hidden layer): the world
            // model's stacked first layer and its two more, then the policy's, in the packed order the
            // kit reads them. Fan-in 0 marks a BIAS - zeroed, as biases should start. A hidden layer
            // gets Xavier's 1/sqrt(fan-in), which keeps a tanh layer's outputs in its useful range
            // instead of saturated; an output layer gets a hundredth of that, so both networks begin as
            // the identity of their job - the world model predicting "nothing changes", the policy
            // "no correction", which is the servo alone.
            const layers = [_][3]usize{
                .{ (f + r + a) * h, f + r + a, 1 }, .{ h, 0, 0 },
                .{ h * h, h, 1 },                   .{ h, 0, 0 },
                .{ h * f, h, 0 },                   .{ f, 0, 0 },
                .{ 2 * f * hp, 2 * f, 1 },          .{ hp, 0, 0 },
                .{ hp * hp, hp, 1 },                .{ hp, 0, 0 },
                .{ hp * a, hp, 0 },                 .{ a, 0, 0 },
            };
            var at: usize = 0;
            for (layers) |layer| {
                const count: usize = layer[0];
                const fan: usize = layer[1];
                const deviation: f32 = if (fan == 0)
                    0.0
                else
                    @sqrt(1.0 / float(fan)) * @as(f32, if (layer[2] == 0) 0.01 else 1.0);
                for (weights[at..][0..count]) |*w| {
                    w.* = deviation * random.floatNorm(f32);
                }
                at += count;
            }
            assertf(at == total, @src(), "seedWeights: filled {d} of {d} weights", .{ at, total });
            kit.pipe.upload(.params, weights);
            @memset(weights, 0.0);
            kit.pipe.upload(.adam_m, weights);
            kit.pipe.upload(.adam_v, weights);
        }

        pub fn deinit(self: *Self) void {
            const gpa: Allocator = self.gpa;
            gpa.free(self.starts);
            gpa.free(self.actions);
            gpa.free(self.hidden2);
            gpa.free(self.hidden1);
            gpa.free(self.raw);
            gpa.free(self.goal);
            gpa.free(self.z);
            gpa.free(self.raw_features);
            self.probe.deinit();
            self.reference.deinit(gpa);
            self.sim.deinit(gpa);
            gpa.free(self.mirror);
            gpa.free(self.norm.spread);
            gpa.free(self.norm.mean);
            self.data.deinit();
            gpa.destroy(self);
        }

        /// The policy's weights as the CPU sees them from here on. On a GPU the readback is a frame or
        /// so old, which is why acting can use it at all: waiting for a fresh one would stall the
        /// simulation every step.
        pub fn syncMirror(self: *Self) void {
            // No readback yet (nothing has come back from the device), or one too narrow to reach the
            // policy's weights: keep the mirror as it is rather than copy half a policy. `init` widens
            // the readback so this cannot be the steady state - it is the first frame or two, when the
            // mirror still holds the weights the driver seeded.
            const params: []const f32 = self.kit.pipe.readLatest(.params) orelse return;
            if (params.len < self.kit.p_at + self.kit.policy_count) {
                return;
            }
            const weights: []const f32 = params[self.kit.p_at..][0..self.kit.policy_count];
            for (weights) |w| {
                if (!(w == w and @abs(w) < 1.0e30)) {
                    self.mirror_rejected += 1;
                    return;
                }
            }
            @memcpy(self.mirror, weights);
        }

        /// `steps` simulation steps with the policy acting - its raw output plus exploration noise,
        /// which the fleet scales into a pose offset - every one recorded into the ring.
        ///
        /// `noise_scale` of zero is the policy ALONE: no draw is made at all (so judging cannot shift
        /// the random stream and change what training does afterwards), and those steps are counted
        /// into the judged pair rather than the collected one. They are still recorded: noise-free
        /// on-policy steps are perfectly good data, and the ring must stay in step with the replay.
        pub fn act(self: *Self, steps: u32, noise_scale: f32) void {
            const random: std.Random = self.rng.random();
            const actions: usize = self.raw.len;
            for (0..steps) |_| {
                // Every character chooses its action from the SAME mirror within a step - the weights
                // as of the last readback - and then they all step together, which is what lets the
                // whole step become one upload into the ring.
                for (0..self.fleet.options.envs) |env| {
                    self.features(env);
                    self.policyRow();
                    for (self.actions[env * actions ..][0..actions], self.raw) |*slot, raw| {
                        // Exploration noise in the simulator comes from the ordinary random stream -
                        // unlike the training rollouts, which hash theirs so the GPU needs no upload.
                        // No draw at all when there is none: judging must not consume the stream, or a
                        // judged run would train differently afterwards. The fleet turns this into a
                        // pose offset with the one action scale it owns.
                        const spread: f32 = noise_scale * self.options.sigma;
                        const chosen: f32 = if (spread == 0.0) raw else raw + spread * random.floatNorm(f32);
                        // Never a non-finite action into the physics: NaN targets make NaN bodies, which
                        // are never "terminated" (every comparison with NaN is false) and poison the world.
                        if (chosen == chosen and @abs(chosen) < 1.0e30) {
                            slot.* = chosen;
                        } else {
                            slot.* = 0.0;
                            self.nonfinite_actions += 1;
                        }
                    }
                }
                _ = self.fleet.step(self.actions);
                // One step watched per character, and a failure for each that just lost its reference.
                // The fleet raises that flag on the step an episode ENDS, and only when it ended badly
                // - a clip running out is a character that survived to the end of the motion.
                //
                // Noise-free steps are counted apart: those are the policy being judged, not explored
                // with, and mixing the two would leave a number that answers neither question.
                for (self.fleet.failures) |lost| {
                    if (noise_scale == 0.0) {
                        self.judged_exposure += 1;
                        if (lost) {
                            self.judged_failures += 1;
                        }
                    } else {
                        self.exposure += 1;
                        if (lost) {
                            self.failures += 1;
                        }
                    }
                }
                self.data.appendLatest(self.fleet);
            }
        }

        /// One world-model update on freshly drawn windows, in its own start slot.
        pub fn trainWorld(self: *Self, slot: u32) void {
            if (!self.drawWindows(slot)) {
                return;
            }
            self.data.gather(&self.kit, slot);
            self.world_updates += 1;
            self.kit.trainStep(self.options.world_rate, self.world_updates);
        }

        /// One policy update, likewise - through the world model, which this leaves untouched.
        pub fn trainPolicy(self: *Self, slot: u32) void {
            if (!self.drawWindows(slot)) {
                return;
            }
            self.data.gather(&self.kit, slot);
            // The rollout's noise comes from this update's seed, hashed per step, row and action.
            self.kit.seed = self.policy_updates;
            self.policy_updates += 1;
            self.kit.policyTrainStep(self.options.policy_rate, self.policy_updates);
        }

        /// One round of the loop: simulate, then train each network, each update in its own slot.
        ///
        /// ONE RECORDING PER ROUND, and not one for several. Every `run` inside a recording carries
        /// its own parameters - without it each dispatch would read whichever parameters were written
        /// last, which on a device means every kernel in the frame running with the final one's. But a
        /// recording may not span rounds either: an upload made while one is open lands before the
        /// WHOLE recording executes, so a later round's appends would overwrite ring slots this
        /// round's gathers are still about to read. Simulate, record this round's dispatches, submit.
        pub fn round(self: *Self) void {
            self.act(self.options.collect, 1.0);
            self.kit.pipe.beginRecording();
            var slot: u32 = 0;
            for (0..self.options.world_updates) |_| {
                self.trainWorld(slot);
                slot += 1;
            }
            for (0..self.options.policy_updates) |_| {
                self.trainPolicy(slot);
                slot += 1;
            }
            self.kit.pipe.submitRecording();
            // The weights the simulation acts from, as of this round.
            self.syncMirror();
        }

        /// Windows the CPU replay draws - it knows where episodes begin and end - staged into `slot`.
        /// False when the replay cannot supply them yet. Public because a caller may want a batch of
        /// windows staged without an update following it, and because the tests compare both learners
        /// on the SAME windows.
        pub fn drawWindows(self: *Self, slot: u32) bool {
            const random: std.Random = self.rng.random();
            // Only what the RING holds. The replay knows where episodes begin and end, so it draws the
            // windows - but it may also hold steps from before the learner existed, or more of them
            // than the ring has room for, and a window the ring never received would be assembled out
            // of whatever those slots happen to contain. So: draw, and keep only what the ring carries.
            const range = self.data.held() orelse return false;
            for (self.starts) |*start| {
                var tries: u32 = 0;
                const window: track.Replay.Window = while (tries < 64) : (tries += 1) {
                    const drawn: track.Replay.Window =
                        self.fleet.replay.sampleWindow(random, self.options.window) orelse return false;
                    const inside: bool =
                        drawn.first >= range.first and drawn.first + self.options.window <= range.last;
                    if (inside) {
                        break drawn;
                    }
                } else {
                    // The ring is still far behind the replay - the first rounds, or just after a
                    // warm-up. Train nothing this round rather than train on slots we cannot vouch for.
                    return false;
                };
                start.* = .{ .env = @intCast(window.env), .index = window.first };
            }
            self.data.stageStarts(self.starts, slot, self.options.window);
            return true;
        }

        /// A character's features and its goal - where the reference is going, the frame the servo aims
        /// at - both normalised, as the policy reads them. Left in `z` and `goal`.
        pub fn features(self: *Self, env: usize) void {
            self.featuresOf(self.fleet, env);
        }

        /// The same for a character of ANY fleet on this model - the judge's (`judgeActor`), not only the
        /// learner's own. Everything read comes from `fleet`; only the scratch is the learner's.
        pub fn featuresOf(self: *Self, fleet: *track.Fleet, env: usize) void {
            track.stateOf(fleet.m, &fleet.data[env], &self.sim);
            track.local(self.sim, fleet.root, self.raw_features);
            self.norm.toNormal(self.raw_features, self.z);
            const clip: *const dance.Clip = fleet.clips[fleet.clip_of[env]];
            fleet.referenceStateInto(clip, fleet.frame[env] + 1, &self.probe, &self.reference);
            track.local(self.reference, fleet.root, self.raw_features);
            self.norm.toNormal(self.raw_features, self.goal);
        }

        /// The JUDGE's actor (plan F1): the policy's MEAN action - no exploration - for every character of the
        /// judge's fleet, from the mirror (the weights as of the last readback). Call `syncMirror` first to judge the
        /// latest policy. The learner is only borrowed for its scratch: judging does not touch its fleet, its ring or
        /// its random stream, so a judged run trains exactly as an unjudged one would.
        pub fn judgeActor(self: *Self) track.Actor {
            return .{ .context = self, .act = actOnJudgedFleet };
        }

        fn actOnJudgedFleet(context: *anyopaque, fleet: *track.Fleet, actions: []f32) void {
            const self: *Self = @ptrCast(@alignCast(context));
            const per_character: usize = self.raw.len;
            for (0..fleet.options.envs) |env| {
                self.featuresOf(fleet, env);
                self.policyRow();
                for (actions[env * per_character ..][0..per_character], self.raw) |*slot, raw| {
                    // Never a non-finite action into the physics (as `act`): the judge's fleet is as easily poisoned.
                    slot.* = if (raw == raw and @abs(raw) < 1.0e30) raw else 0.0;
                }
            }
        }

        /// The policy's raw action for one character, from whatever `z` and `goal` hold, left in `raw`.
        /// It reads the mirror - the packed weights in `LatentKit.packPolicy`'s order: the goal block,
        /// the state block, then the later layers. Public so a page can ask the policy for an action
        /// without collecting a step, and so a test can put the GPU's own rows through it.
        pub fn policyRow(self: *Self) void {
            const hp: usize = self.hidden1.len;
            const f: usize = self.z.len;
            // Walking the packed weights, in the order `packPolicy` writes them. The first layer is two
            // blocks because a row is [goal | state] and the policy reads both: the goal block first
            // (the row starts with the goal), then the state block, then that layer's bias. After it,
            // the ordinary pairs. Every weight matrix is stored row by row of its INPUT - element
            // (i, j) at i * outputs + j - which is why each inner loop strides by `hp` (or by the
            // action count in the last layer).
            const w_goal: usize = 0;
            const w_state: usize = f * hp;
            const b1: usize = w_state + f * hp;
            const w2: usize = b1 + hp;
            const b2: usize = w2 + hp * hp;
            const w3: usize = b2 + hp;
            const b3: usize = w3 + hp * self.raw.len;
            // The two input blocks are summed into one pre-activation, which is exactly what the kit's
            // stacked first layer does on the GPU - the same arithmetic, a different order (there, one
            // block after the other), so the two agree to rounding rather than to the bit.
            for (0..hp) |j| {
                var sum: f32 = self.mirror[b1 + j];
                for (self.goal, self.z, 0..) |g, x, i| {
                    sum += g * self.mirror[w_goal + i * hp + j] + x * self.mirror[w_state + i * hp + j];
                }
                self.hidden1[j] = zm.tanh(sum);
            }
            for (0..hp) |j| {
                var sum: f32 = self.mirror[b2 + j];
                for (self.hidden1, 0..) |x, i| {
                    sum += x * self.mirror[w2 + i * hp + j];
                }
                self.hidden2[j] = zm.tanh(sum);
            }
            for (self.raw, 0..) |*out, j| {
                var sum: f32 = self.mirror[b3 + j];
                for (self.hidden2, 0..) |x, i| {
                    sum += x * self.mirror[w3 + i * self.raw.len + j];
                }
                out.* = sum;
            }
        }
    };
}
