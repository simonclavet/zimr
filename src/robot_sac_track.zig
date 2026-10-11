//! robot_sac_track - SAC on the tracking task: `robot_gym.SacAgent` learning a residual tracking policy from
//! `TrackEnv`'s decisions. The off-policy half of plan Stage I's mixes - Simon's idea: SAC's sample efficiency to get
//! going fast, alongside PPO and SuperTrack.
//!
//! PPO uses each decision once and throws it away; SAC keeps every one in a replay and learns from it again and again.
//! That is where its sample efficiency comes from - and why what goes INTO the replay has to be exactly right: a
//! transition written wrong is learned from a thousand times. So the whole job of this file is the mapping from a
//! `TrackEnv` decision to a replay row (observation, action, reward, next observation, discount):
//!
//!   * the observation is the environment's just before the decision; the action is what SAC drew (the environment
//!     clamps what reaches the character, and SAC's squashed draws are inside [-1, 1] anyway); the reward is the one
//!     `TrackEnv` credited to the decision;
//!   * `.none` - the episode goes on: the next observation is the one the next decision starts from, discount gamma;
//!   * `.cut`  - out of time (the step cap, or a clip's end counted as a cut): the next observation is the state the
//!               episode ended IN (`TrackEnv`'s terminal capture), discount gamma - SAC bootstraps from where it was,
//!               because running out of time is not dying;
//!   * `.stop` - lost: discount ZERO, nothing is bootstrapped (the next observation is stored, and never read).
//!
//! With `n_step` above 1 the decisions go through `TrackEnv.NStep` first: a row's reward is then a window's discounted
//! return and its discount the window's own (gamma^k, zero after a stop). The mapping above is simply the n = 1 case -
//! row for row, bit for bit - so every row goes through `NStep`, whatever n is.
//!
//! Observations go into the replay RAW. With `sac.normalize_observations` on, SAC normalises each sampled batch - and
//! what it acts on - with its running statistics of that moment, so no stored row ever goes stale as they move.

const std = @import("std");
const rbt = @import("robot.zig");
const dance = @import("robot_dance.zig");
const gym = @import("robot_gym.zig");
const track_env = @import("robot_track_env.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const Options = struct {
    /// The task - the same `TrackEnv` settings every learner of it uses.
    env: track_env.Options = .{},
    /// SAC's own: network widths, batch, replay, learning rate, gamma, tau, warm-up, observation normalising.
    sac: gym.SacOptions = .{},
    /// SAC updates after every decision of the whole fleet (each decision adds up to `envs` transitions). DroQ's high
    /// update-to-data ratio is this knob turned up.
    updates_per_decision: u32 = 1,
    /// The return's horizon in decisions (`TrackEnv.NStep`): 1 is one-step SAC; TD4 uses 5.
    n_step: usize = 1,
};

/// How one fleet decision went, for a caller's running totals.
pub const StepStats = struct {
    /// The rewards credited to the decision, summed over the environments.
    reward_sum: f32 = 0.0,
    /// Environments whose episode was lost (`.stop`) or ran out of time (`.cut`) during the decision.
    stops: u32 = 0,
    cuts: u32 = 0,
};

pub const SacTrack = struct {
    gpa: Allocator,
    /// Owns everything below except the agent (which lives in its own arena, from `gpa`).
    arena: ArenaAllocator,
    options: Options,
    env: track_env.TrackEnv,
    agent: *gym.SacAgent,
    /// Every environment's observation for the decision it is about to take (envs x n_obs).
    decision_obs: []f32,
    /// Scratch: every environment's observation right after a decision - where its next decision starts (for an
    /// environment whose episode just ended, the fresh start's). Becomes `decision_obs` at the end of `step`.
    after_obs: []f32,
    /// The decision being taken: envs x dofs, as SAC drew it.
    actions: []f32,
    /// How each environment's decision went, and - where an episode was cut short - the state it ended in.
    outcomes: []track_env.Outcome,
    terminal_obs: []f32,
    /// The n-step windows per environment, and room for the transitions one decision can complete (up to n).
    nstep: track_env.NStep,
    completed: []track_env.Transition,
    /// Decisions taken so far, over all environments.
    decisions_taken: u64 = 0,

    pub fn init(
        gpa: Allocator,
        m: *rbt.Model,
        body_names: []const []const u8,
        clips: []const *const dance.Clip,
        options: Options,
    ) !*SacTrack {
        const self: *SacTrack = try gpa.create(SacTrack);
        errdefer gpa.destroy(self);
        // whole-init-first: the whole struct first - defaults applied, every field named.
        self.* = .{
            .gpa = gpa,
            .arena = ArenaAllocator.init(gpa),
            .options = options,
            .env = undefined,
            .agent = undefined,
            .decision_obs = undefined,
            .after_obs = undefined,
            .actions = undefined,
            .outcomes = undefined,
            .terminal_obs = undefined,
            .nstep = undefined,
            .completed = undefined,
        };
        errdefer self.arena.deinit();
        const owned: Allocator = self.arena.allocator();
        self.env = try track_env.TrackEnv.init(owned, m, body_names, clips, options.env);
        errdefer self.env.deinit();
        const envs: usize = options.env.envs;
        const n_obs: usize = self.env.n_obs;
        const dofs: usize = self.env.subset.dofs;
        self.agent = try gym.SacAgent.init(gpa, n_obs, dofs, options.sac);
        errdefer self.agent.deinit();
        self.decision_obs = try owned.alloc(f32, envs * n_obs);
        self.after_obs = try owned.alloc(f32, envs * n_obs);
        self.actions = try owned.alloc(f32, envs * dofs);
        self.outcomes = try owned.alloc(track_env.Outcome, envs);
        self.terminal_obs = try owned.alloc(f32, envs * n_obs);
        // The windows discount with SAC's own gamma - the one its targets use.
        self.nstep = try track_env.NStep.init(owned, envs, n_obs, dofs, options.n_step, options.sac.gamma);
        self.completed = try owned.alloc(track_env.Transition, options.n_step);
        for (0..envs) |env| {
            self.env.observe(env, self.decision_obs[env * n_obs ..][0..n_obs]);
        }
        return self;
    }

    pub fn deinit(self: *SacTrack) void {
        const gpa: Allocator = self.gpa;
        self.agent.deinit();
        self.env.deinit();
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// One decision for the whole fleet: every environment acts (SAC's draw - uniform during its warm-up), the fleet
    /// lives with it (`TrackEnv.decide`), every completed transition goes into SAC's replay (the mapping in the file's
    /// header), then `updates_per_decision` SAC updates (each a no-op until the replay is past the warm-up).
    pub fn step(self: *SacTrack) !StepStats {
        const envs: usize = self.options.env.envs;
        const n_obs: usize = self.env.n_obs;
        const dofs: usize = self.env.subset.dofs;
        for (0..envs) |env| {
            self.agent.act(self.decision_obs[env * n_obs ..][0..n_obs], self.actions[env * dofs ..][0..dofs], false);
        }
        self.env.decide(self.actions, self.outcomes, self.terminal_obs);
        var stats: StepStats = .{};
        for (self.outcomes, 0..) |outcome, env| {
            const obs_before: []const f32 = self.decision_obs[env * n_obs ..][0..n_obs];
            const obs_after: []f32 = self.after_obs[env * n_obs ..][0..n_obs];
            self.env.observe(env, obs_after);
            // Into its n-step window; out come the transitions this decision completes - none, one, or every pending
            // one at an episode's end. With n = 1, exactly this decision's own one-step row.
            const action: []const f32 = self.actions[env * dofs ..][0..dofs];
            const terminal: []const f32 = self.terminal_obs[env * n_obs ..][0..n_obs];
            const completed_count: usize = self.nstep.push(
                env,
                obs_before,
                action,
                outcome,
                obs_after,
                terminal,
                self.completed,
            );
            for (self.completed[0..completed_count]) |transition| {
                try self.agent.rememberDiscounted(
                    transition.obs,
                    transition.action,
                    transition.reward,
                    transition.next,
                    transition.discount,
                );
            }
            stats.reward_sum += outcome.reward;
            switch (outcome.end) {
                .stop => stats.stops += 1,
                .cut => stats.cuts += 1,
                .none => {},
            }
        }
        // Where every environment's next decision starts.
        @memcpy(self.decision_obs, self.after_obs);
        self.decisions_taken += envs;
        for (0..self.options.updates_per_decision) |_| {
            try self.agent.update();
        }
        return stats;
    }
};
