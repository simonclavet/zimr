//! robot_track_env - the tracking task as a DECISION-LEVEL environment: the one thing every learner of a residual
//! tracking policy steps through. PPO does (`robot_ppo_track`), SAC does (`robot_sac_track`), and the mixes of plan
//! Stage I will. Having ONE definition is the whole point: a learner that stepped the task its own way - held a
//! decision a step longer, credited a reward to the wrong decision, treated running out of time as dying - would be
//! learning a slightly different task, and no comparison between two learners would mean anything.
//!
//! **One step here is one DECISION**, not one physics step. Every environment is asked for an action, the action is
//! clamped to the controller's range, and the character lives with it for `decimation` physics steps (DReCon's k = 2),
//! the controller's filter blending it in. What comes back per environment is an `Outcome`: the reward credited to
//! the decision (the mean over its held steps, up to the first end - what came after, on the fresh start that replaced
//! a failed episode, is not the decision's), and how the transition ended:
//!
//!   * `.none` - the episode goes on; the next decision's observation follows this one.
//!   * `.stop` - the reference was LOST (or the clip ran out and the task says that is terminal): nothing to bootstrap.
//!   * `.cut`  - the step cap, or the clip's end when `clip_end = .bootstrap`: the episode was fine and merely ran out
//!               of time, so a learner bootstraps from the state it ended in - whose observation `decide` writes into
//!               `terminal`, read at the moment of the end, BEFORE the controller forgets that episode's filter.
//!
//! Below the environment sits `NStep`, which turns a stream of decisions into n-step TRANSITIONS - the rows an
//! off-policy learner (SAC, TD4) stores in its replay.
//!
//! The known answers live in `robot_ppo_track_tests.zig`: PPO's collection held decision for decision against a bare
//! `TrackEnv` on a twin fleet, and every row of SAC's replay held field by field against one. `NStep`'s are below, in
//! this file: planted rewards against the closed form.

const std = @import("std");
const zm = @import("zm");
const rbt = @import("robot.zig");
const track = @import("robot_track.zig");
const policy = @import("robot_policy.zig");
const dance = @import("robot_dance.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const float = zm.float;
const clamp = zm.clamp;
const assertf = zm.assertf;

/// How a decision's transition ended, for a learner's bootstrap (see the file's header).
pub const EndKind = enum(u8) {
    /// The episode went on: the next decision's observation follows.
    none,
    /// Nothing follows: the reference was lost (or a clip's end counted as final, `ClipEnd.terminal`).
    stop,
    /// Cut short - the step cap, or a clip's end counted as a cut: what follows is the value of the state the episode
    /// ended IN (`decide`'s `terminal`), not of the fresh start that replaced it.
    cut,
};

/// What a clip running out means: terminal (`.stop`) or merely out of time (`.cut`).
pub const ClipEnd = enum { terminal, bootstrap };

/// The environment's settings - the task's, not any learner's. A learner hands its own values in.
pub const Options = struct {
    /// How many characters run side by side - each its own episode, its own decisions, its own row of every buffer.
    envs: usize = 8,
    /// Physics steps a decision is held for (DReCon's k = 2: 30 decisions a second at 60 Hz physics).
    decimation: u32 = 2,
    /// Simon's filter (DReCon's 0.2): each decision blended into what the controller is already applying.
    beta: f32 = 0.2,
    /// What the clip running out means to a learner: the end of the story (`.terminal`, a `.stop`), or just the end of
    /// the tape while the character was doing fine (`.bootstrap`, a `.cut` - value what comes next as if it went on).
    clip_end: ClipEnd = .terminal,
    /// Episodes end here even while tracking is fine (physics steps) - an end that is `.cut`, not `.stop`.
    max_episode_steps: u32 = 600,
    /// Radians per unit of action, handed to the fleet: the scale a policy is trained under is the one it is judged
    /// under.
    action_scale: f32 = 0.2,
    /// The task, WHOLE (`robot_track.Task`: servo, floor, reward, failure rule).
    task: track.Task = .{},
    /// DReCon's watched and actuated bodies, in this robot's names.
    bodies: policy.Bodies = .{},
    /// The fleet's random stream: where each episode starts on the clip. Same seed, same episodes.
    seed: u64 = 1,
};

/// How one environment's decision went.
pub const Outcome = struct {
    /// The reward credited to the decision: its held steps' rewards over the hold, up to the first end.
    reward: f32 = 0.0,
    /// The raw sum of those credited rewards, and how many steps were credited - for a learner's statistics.
    reward_sum: f32 = 0.0,
    credited: u32 = 0,
    /// How the decision's transition ended - its FIRST end, if the fresh episode ended too before the hold was over.
    end: EndKind = .none,
    /// Held steps on which the reference was LOST - counting EVERY held step, including any on the fresh episode that
    /// replaced an ended one: time-to-failure statistics count exposure the same way, so the two stay a fair ratio.
    failures: u32 = 0,
    /// Episodes that ended during the decision (almost always 0 or 1) and the sum of their lengths in physics steps.
    ended: u32 = 0,
    ended_length: u64 = 0,
};

pub const TrackEnv = struct {
    /// The robot's model (the caller owns it).
    m: *rbt.Model,
    options: Options,
    /// The characters on their floor, each tracking the clip: rewards, failures and episode ends per environment.
    fleet: *track.Fleet,
    /// DReCon's choice of bodies: the ones the policy WATCHES (its observation) and the joints it NUDGES (its action).
    subset: policy.Subset,
    /// Turns a decision into what reaches the joints: the subset's nudges, filtered (beta) and held for the decimation,
    /// exactly zero when asked for zero - so an untrained policy is the servo.
    controller: policy.Controller,
    /// The reference now and further ahead, for every observation (`policy.observeFrom`).
    views: policy.Views,
    /// Scratch: the simulated state an observation is built from.
    sim_state: track.State,
    /// The decision being applied, clamped: envs x dofs.
    applied: []f32,
    /// Physics steps into each environment's current episode.
    episode_steps: []u32,
    /// Per environment, during `decide`: has its episode ended yet (rewards after that are not the decision's).
    ended_yet: []bool,
    /// The observation's length, for a learner sizing its buffers.
    n_obs: usize,

    /// Build the environment in `arena` (the caller's; `deinit` releases the fleet, the arena the rest).
    pub fn init(
        arena: Allocator,
        m: *rbt.Model,
        body_names: []const []const u8,
        clips: []const *const dance.Clip,
        options: Options,
    ) !TrackEnv {
        const envs: usize = options.envs;
        const bodies: policy.Bodies = options.bodies;
        const subset: policy.Subset = try policy.subsetFor(arena, m, body_names, bodies.watched, bodies.actuated);
        const env: TrackEnv = .{
            .m = m,
            .options = options,
            .fleet = try track.Fleet.init(arena, m, clips, .{
                .envs = envs,
                .capacity = 16,
                .seed = options.seed,
                .max_steps = options.max_episode_steps,
                .action_scale = options.action_scale,
                .task = options.task,
                .body_names = body_names,
            }),
            .subset = subset,
            .controller = try policy.Controller.init(arena, m, subset, envs, .{
                .beta = options.beta,
                .decimation = options.decimation,
            }),
            .views = try policy.Views.init(arena, m),
            .sim_state = try track.State.init(arena, m.nbody),
            .applied = try arena.alloc(f32, envs * subset.dofs),
            .episode_steps = try arena.alloc(u32, envs),
            .ended_yet = try arena.alloc(bool, envs),
            .n_obs = policy.observationSize(subset),
        };
        @memset(env.episode_steps, 0);
        return env;
    }

    pub fn deinit(self: *TrackEnv) void {
        self.fleet.deinit();
    }

    /// Physics steps one decision is held for - the decimation, at least one. A learner counting exposure or steps
    /// asks here instead of recomputing it, so there is one definition of how long a decision lasts.
    pub fn heldSteps(self: *const TrackEnv) u32 {
        return @max(self.options.decimation, 1);
    }

    /// Environment `env`'s observation now: its simulated state, the reference around its frame, and the action its
    /// controller is applying.
    pub fn observe(self: *TrackEnv, env: usize, out: []f32) void {
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

    /// The observation of the state `env`'s episode ENDED in - the fleet's capture, before its restart - with the
    /// controller's action as it stood: what a cut-short episode is bootstrapped from. Only meaningful at the moment
    /// of the end, before `controller.forget`.
    pub fn observeTerminal(self: *TrackEnv, env: usize, out: []f32) void {
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

    /// One decision for every environment. `actions` (envs x dofs) as the learner drew them - clamped to the
    /// controller's [-1, 1] here, so a learner's log-probability stays the one of the sample it drew. Fills
    /// `outcomes[env]`; for every environment whose episode was CUT, writes the observation it ended in to row `env`
    /// of `terminal` (envs x n_obs) - other rows are left as they were.
    pub fn decide(
        self: *TrackEnv,
        actions: []const f32,
        outcomes: []Outcome,
        terminal: []f32,
    ) void {
        const envs: usize = self.options.envs;
        const dofs: usize = self.subset.dofs;
        const n_obs: usize = self.n_obs;
        for (0..envs) |env| {
            const requested: []const f32 = actions[env * dofs ..][0..dofs];
            for (self.applied[env * dofs ..][0..dofs], requested) |*applied, value| {
                applied.* = clamp(value, -1.0, 1.0);
            }
            outcomes[env] = .{};
            self.ended_yet[env] = false;
        }
        // Live with the decision for `decimation` physics steps. One subtlety, inherited on purpose from PPO's
        // original: when an episode ends on an early held step, the fleet restarts that character at once and the
        // SAME decision keeps driving the fresh episode for the rest of the hold - through a filter just reset to
        // zero, so at beta 0.2 it is a small push. Its reward is not credited to anyone; the fresh episode's first
        // real decision comes at the next `decide`.
        const held_steps: u32 = self.heldSteps();
        for (0..held_steps) |_| {
            const full_action: []const f32 = self.controller.apply(self.applied);
            _ = self.fleet.step(full_action);
            for (0..envs) |env| {
                const outcome: *Outcome = &outcomes[env];
                self.episode_steps[env] += 1;
                if (self.fleet.failures[env]) {
                    outcome.failures += 1;
                }
                if (!self.ended_yet[env]) {
                    outcome.reward += self.fleet.rewards[env] / float(held_steps);
                    outcome.reward_sum += self.fleet.rewards[env];
                    outcome.credited += 1;
                }
                if (!self.fleet.dones[env]) {
                    continue;
                }
                // How it ended - the FIRST end only: a second one, on the fresh start within the same hold, is not
                // this decision's. When cut short, the state it ended in is read now, before its filter is forgotten.
                if (!self.ended_yet[env]) {
                    outcome.end = switch (self.fleet.ends[env]) {
                        .lost => .stop,
                        .cap => .cut,
                        .clip_end => if (self.options.clip_end == .bootstrap) .cut else .stop,
                    };
                    if (outcome.end == .cut) {
                        self.observeTerminal(env, terminal[env * n_obs ..][0..n_obs]);
                    }
                }
                self.ended_yet[env] = true;
                self.controller.forget(env);
                outcome.ended += 1;
                outcome.ended_length += self.episode_steps[env];
                self.episode_steps[env] = 0;
            }
        }
    }
};

/// One n-step transition, as a learner stores it in its replay. The slices point into `NStep`'s storage (the
/// observation and the action) or into the caller's own buffers (the next observation), so they are good until that
/// environment's next `push` - consume them right away, which is what a learner storing rows does anyway.
pub const Transition = struct {
    /// The observation the window's FIRST decision was taken from.
    obs: []const f32,
    /// That first decision's action - what the critic learns the value of.
    action: []const f32,
    /// The window's discounted return: over its k decisions, reward_0 + gamma * reward_1 + ... + gamma^(k-1) *
    /// reward_(k-1). With a one-decision window, the reward itself.
    reward: f32,
    /// Where the window bootstraps from: the observation after its last decision - or, for a window ended by a cut,
    /// the state the episode ended in. Stored for a stop too, and never read (its discount is zero).
    next: []const f32,
    /// What multiplies the bootstrap: gamma^k for a window that goes on (k: its decisions), zero for one that ended
    /// in a termination. So a learner's target is `reward + discount * value(next)` whatever kind of window it is.
    discount: f32,
};

/// N-STEP TRANSITIONS over `TrackEnv` decisions - TD4's 5-step returns, and SAC's with them (plan I5 T1).
///
/// Why bother: a one-step target leans entirely on the critic's own guess one decision later, and early in training
/// that guess is noise. An n-step target spends n real rewards first and only then leans on the guess - discounted by
/// gamma^n - so real reward reaches the critic n times faster. The price: the n rewards were earned by the policy
/// that ACTED, which by the time the row is replayed is an older policy (the usual off-policy bias, small for small n).
///
/// How: every environment keeps a small ring of its decisions that are not stored yet - at most n of them. After each
/// decision, one of three things happens:
///
///   * the episode goes on, and the ring is full: the OLDEST pending decision's window is complete - its return summed
///     over the n decisions, bootstrapping from the observation after the newest at gamma^n. Out it goes, and it
///     leaves the ring, making room for the next;
///   * a CUT (out of time, not a failure): EVERY pending decision's window is complete. Each goes out with its return
///     up to the end and the terminal observation to bootstrap from, at gamma^k for its own k decisions to the end;
///   * a STOP (lost): every pending decision goes out too, with its return up to the end and a discount of ZERO -
///     nothing is bootstrapped past a failure.
///
/// So a window never reaches across an episode's end, and no decision is dropped at one. Returns are summed newest
/// first (Horner: r_j + gamma * (r_j+1 + gamma * (...))), which with n = 1 leaves a transition's return as its
/// reward untouched and its discount gamma itself - exactly the one-step rows, bit for bit.
pub const NStep = struct {
    /// The window's length in decisions (TD4: 5). 1 is plain one-step learning.
    n: usize,
    gamma: f32,
    n_obs: usize,
    dofs: usize,
    /// Every environment's ring of pending decisions - n slots each, environment after environment: the observation
    /// each was taken from, its action, and the reward it earned.
    pending_obs: []f32,
    pending_actions: []f32,
    pending_rewards: []f32,
    /// Per environment: which ring slot holds its OLDEST pending decision, and how many decisions are pending (0..n-1
    /// between pushes - a full ring is emptied by one before `push` returns).
    oldest: []usize,
    pending: []usize,

    pub fn init(
        arena: Allocator,
        envs: usize,
        n_obs: usize,
        dofs: usize,
        n: usize,
        gamma: f32,
    ) !NStep {
        assertf(n >= 1, @src(), "an n-step window needs n >= 1, not {d}", .{n});
        const self: NStep = .{
            .n = n,
            .gamma = gamma,
            .n_obs = n_obs,
            .dofs = dofs,
            .pending_obs = try arena.alloc(f32, envs * n * n_obs),
            .pending_actions = try arena.alloc(f32, envs * n * dofs),
            .pending_rewards = try arena.alloc(f32, envs * n),
            .oldest = try arena.alloc(usize, envs),
            .pending = try arena.alloc(usize, envs),
        };
        @memset(self.oldest, 0);
        @memset(self.pending, 0);
        return self;
    }

    /// One environment's decision: the observation it was taken from, its action, how it went (`decide`'s outcome),
    /// where that environment's NEXT decision starts (`next_obs` - for an ended episode, the fresh start's), and, for a
    /// cut, the state the episode ended in (`terminal_obs`). Writes the transitions this completes to `completed`,
    /// oldest first - none, one, or every pending one at an episode's end - and returns how many. `completed` needs
    /// room for n.
    pub fn push(
        self: *NStep,
        env: usize,
        obs: []const f32,
        action: []const f32,
        outcome: Outcome,
        next_obs: []const f32,
        terminal_obs: []const f32,
        completed: []Transition,
    ) usize {
        assertf(completed.len >= self.n, @src(), "room for {d} transitions, not {d}", .{ self.n, completed.len });
        // Into the ring, after the pending ones. There is always a free slot: between pushes at most n - 1 are pending.
        const slot: usize = self.slotOf(env, self.pending[env]);
        @memcpy(self.pending_obs[slot * self.n_obs ..][0..self.n_obs], obs);
        @memcpy(self.pending_actions[slot * self.dofs ..][0..self.dofs], action);
        self.pending_rewards[slot] = outcome.reward;
        self.pending[env] += 1;
        switch (outcome.end) {
            .none => {
                if (self.pending[env] < self.n) {
                    return 0;
                }
                // The ring is full: the oldest decision's n-step window is complete. Out it goes; its slot frees up.
                completed[0] = self.windowFrom(env, 0, next_obs, self.gammaPower(self.n));
                self.oldest[env] = (self.oldest[env] + 1) % self.n;
                self.pending[env] -= 1;
                return 1;
            },
            .cut, .stop => {
                // The episode ended: every pending decision's window ends here, shorter than n for all but the oldest
                // of a full ring. A cut bootstraps from the state it ended in; a stop does not bootstrap at all.
                const bootstrap_obs: []const f32 = if (outcome.end == .cut) terminal_obs else next_obs;
                const count: usize = self.pending[env];
                for (0..count) |first| {
                    const decisions_to_end: usize = count - first;
                    const discount: f32 = if (outcome.end == .cut) self.gammaPower(decisions_to_end) else 0.0;
                    completed[first] = self.windowFrom(env, first, bootstrap_obs, discount);
                }
                self.pending[env] = 0;
                return count;
            },
        }
    }

    /// Where pending decision `j` of `env` (0: its oldest) sits in the flat ring arrays.
    fn slotOf(self: *const NStep, env: usize, j: usize) usize {
        return env * self.n + (self.oldest[env] + j) % self.n;
    }

    /// gamma^k by repeated multiplication - so gamma^1 is gamma exactly, which the one-step rows rely on.
    fn gammaPower(self: *const NStep, k: usize) f32 {
        var result: f32 = 1.0;
        for (0..k) |_| {
            result *= self.gamma;
        }
        return result;
    }

    /// The transition whose window starts at pending decision `first` and runs to the newest: its first decision's
    /// observation and action, and its return summed newest-first.
    fn windowFrom(
        self: *const NStep,
        env: usize,
        first: usize,
        bootstrap_obs: []const f32,
        discount: f32,
    ) Transition {
        var discounted_return: f32 = 0.0;
        var j: usize = self.pending[env];
        while (j > first) {
            j -= 1;
            discounted_return = self.pending_rewards[self.slotOf(env, j)] + self.gamma * discounted_return;
        }
        const slot: usize = self.slotOf(env, first);
        return .{
            .obs = self.pending_obs[slot * self.n_obs ..][0..self.n_obs],
            .action = self.pending_actions[slot * self.dofs ..][0..self.dofs],
            .reward = discounted_return,
            .next = bootstrap_obs,
            .discount = discount,
        };
    }
};

// ---- NStep's known answers: planted rewards against the closed form, gamma 0.5 so every sum is exact ------------

const testing = std.testing;

/// Feeds one decision to a one-environment, one-feature NStep: its observation and action are its step's number,
/// `after` the next step's number, `terminal` 99.
fn feed(
    nstep: *NStep,
    step: f32,
    reward: f32,
    end: EndKind,
    out: []Transition,
) usize {
    const obs = [1]f32{step};
    const after = [1]f32{step + 1.0};
    const terminal = [1]f32{99.0};
    return nstep.push(0, &obs, &obs, .{ .reward = reward, .end = end }, &after, &terminal, out);
}

test "robot_track_env: NStep - full windows, a cut, a stop, against the closed form" {
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var nstep: NStep = try .init(arena_state.allocator(), 1, 1, 1, 3, 0.5);
    var out: [3]Transition = undefined;
    // Rewards 1, 2, 4, 8, 16: each window's terms come out equal, so its return is easy to state.
    try testing.expectEqual(@as(usize, 0), feed(&nstep, 0, 1, .none, &out));
    try testing.expectEqual(@as(usize, 0), feed(&nstep, 1, 2, .none, &out));
    // The window is full: step 0's transition - 1 + 0.5 * 2 + 0.25 * 4 = 3, bootstrapping from step 3 at 0.5^3.
    try testing.expectEqual(@as(usize, 1), feed(&nstep, 2, 4, .none, &out));
    try testing.expectEqual(@as(f32, 0), out[0].obs[0]);
    try testing.expectEqual(@as(f32, 3), out[0].reward);
    try testing.expectEqual(@as(f32, 3), out[0].next[0]);
    try testing.expectEqual(@as(f32, 0.125), out[0].discount);
    // Step 1's: 2 + 2 + 2 = 6.
    try testing.expectEqual(@as(usize, 1), feed(&nstep, 3, 8, .none, &out));
    try testing.expectEqual(@as(f32, 1), out[0].obs[0]);
    try testing.expectEqual(@as(f32, 6), out[0].reward);
    // A CUT at step 4: steps 2, 3 and 4 all go out, bootstrapping from the terminal state at 0.5^3, ^2, ^1.
    try testing.expectEqual(@as(usize, 3), feed(&nstep, 4, 16, .cut, &out));
    const cut_obs = [3]f32{ 2, 3, 4 };
    const cut_returns = [3]f32{ 12, 16, 16 };
    const cut_discounts = [3]f32{ 0.125, 0.25, 0.5 };
    for (out, cut_obs, cut_returns, cut_discounts) |t, o, r, d| {
        try testing.expectEqual(o, t.obs[0]);
        try testing.expectEqual(r, t.reward);
        try testing.expectEqual(@as(f32, 99), t.next[0]);
        try testing.expectEqual(d, t.discount);
    }
    // A fresh episode, lost on its third decision: everything pending goes out with a discount of zero.
    try testing.expectEqual(@as(usize, 0), feed(&nstep, 5, 1, .none, &out));
    try testing.expectEqual(@as(usize, 0), feed(&nstep, 6, 2, .none, &out));
    try testing.expectEqual(@as(usize, 3), feed(&nstep, 7, 4, .stop, &out));
    const stop_returns = [3]f32{ 3, 4, 4 };
    for (out, stop_returns, 0..) |t, r, k| {
        try testing.expectEqual(5.0 + float(k), t.obs[0]);
        try testing.expectEqual(r, t.reward);
        try testing.expectEqual(@as(f32, 0), t.discount);
    }
    // And a cut on an episode's FIRST decision: one transition, at gamma^1.
    try testing.expectEqual(@as(usize, 1), feed(&nstep, 8, 5, .cut, &out));
    try testing.expectEqual(@as(f32, 5), out[0].reward);
    try testing.expectEqual(@as(f32, 0.5), out[0].discount);
}

test "robot_track_env: NStep - with n = 1, exactly the one-step rows" {
    var arena_state: ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const gamma: f32 = 0.99;
    var nstep: NStep = try .init(arena_state.allocator(), 1, 1, 1, 1, gamma);
    var out: [1]Transition = undefined;
    const ends = [_]EndKind{ .none, .none, .cut, .none, .stop, .none };
    for (ends, 0..) |end, k| {
        const reward: f32 = 0.1 * float(k + 1) + 0.037;
        try testing.expectEqual(@as(usize, 1), feed(&nstep, float(k), reward, end, &out));
        const t: Transition = out[0];
        // The return is the reward itself, bit for bit; the discount is gamma (1 - done), bit for bit.
        try testing.expectEqual(reward, t.reward);
        const done: f32 = if (end == .stop) 1.0 else 0.0;
        try testing.expectEqual(gamma * (1.0 - done), t.discount);
        const expected_next: f32 = if (end == .cut) 99.0 else float(k) + 1.0;
        try testing.expectEqual(expected_next, t.next[0]);
    }
}
