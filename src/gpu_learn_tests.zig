//! gpu_learn_tests - the GPU learning kit's proofs, on its CPU twin.
//!
//! These import the kernel module `src/gpu/zn_mlp.zig` BY PATH, so they cannot live in any file
//! of the `zimr` module: a page that registers the kit's kernels gets it as a NAMED module, and
//! Zig refuses one file in two modules of a compilation ("file exists in modules 'zn_mlp' and
//! 'zimr'"). `robot_gym` keeps only the generic `GpuPpoOn(M)`; this root instantiates it.

const std = @import("std");
const report = @import("test_report.zig");
const zm = @import("zm");
const zn = @import("zn");
const zrl = @import("zrl");
const gym = @import("robot_gym.zig");
const zn_mlp = @import("gpu/zn_mlp.zig");
/// The XOR network's kernels - the phone's GPU confidence test runs them beside the robot.
const zn_train = @import("gpu/zn_train.zig");
const compute_host = @import("compute_host.zig");
const bmpc_kit = @import("robot_bmpc_kit.zig");
const latent_kit = @import("robot_latent_kit.zig");
const kit_mlp = @import("kit_mlp.zig");
const bmpc = @import("robot_bmpc.zig");

const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectApproxEqRel = std.testing.expectApproxEqRel;
const Io = std.Io;
const Random = std.Random;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing_allocator = std.testing.allocator;
const float = zm.float;
const float64 = zm.float64;
const clamp = zm.clamp;
const nan = zm.nan;
const inf = zm.inf;
const pi = zm.pi;
const Layer = gym.Layer;
const AdamSet = gym.AdamSet;

const lab = @import("robot_lab.zig");
const ppo_track = @import("robot_ppo_track.zig");
const track_env = @import("robot_track_env.zig");
const expectEqualSlices = std.testing.expectEqualSlices;
const ArrayList = std.ArrayList;
const sortSlice = std.mem.sort;

/// The learner on the kit as this file imports it.
const GpuPpo = gym.GpuPpoOn(zn_mlp);

test "gpu learn: G1 - zn_mlp's kernels train a two-layer net exactly as zimrnum's graph does" {
    // *** THE PROOF THE GPU TRAINER STANDS ON, as `zimrnum_train` proved its XOR net: the same
    // network (5 -> 16 tanh -> 1, batch 8, MSE) trained 20 Adam steps both ways from the same
    // weights - zimrnum's CPU graph with `zn.adamStep`, and `zn_mlp`'s kernels on their CPU
    // twin through `z.Compute(...).initCpu()`, dispatched in dependency order exactly as the
    // GPU will run them. Every loss and the final weights must agree to float precision.
    const gpa: Allocator = testing_allocator;
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const rows: usize = 8;
    const n_in: usize = 5;
    const hidden: usize = 16;
    var init_rng: Random.DefaultPrng = .init(11);
    const random: Random = init_rng.random();

    // -- The CPU reference: zimrnum's graph, Adam. --
    var l1: Layer = try .init(arena, random, n_in, hidden, 1.0);
    var l2: Layer = try .init(arena, random, hidden, 1, 1.0);
    const x: zn.Tensor(f32) = try .alloc(arena, &.{ rows, n_in });
    const t: zn.Tensor(f32) = try .alloc(arena, &.{ rows, 1 });
    for (x.data) |*v| {
        v.* = 2.0 * random.float(f32) - 1.0;
    }
    for (t.data) |*v| {
        v.* = 2.0 * random.float(f32) - 1.0;
    }
    const ones_t: zn.Tensor(f32) = try .alloc(arena, &.{ rows, 1 });
    @memset(ones_t.data, 1.0);
    var graph: zn.Graph(f32) = .init(arena);
    const xv: zn.Var = try graph.constant(x);
    const tv: zn.Var = try graph.constant(t);
    const ones: zn.Var = try graph.constant(ones_t);
    const h: zn.Var = try graph.tanh(try l1.apply(&graph, xv, ones));
    const y: zn.Var = try l2.apply(&graph, h, ones);
    const loss: zn.Var = try graph.mseLoss(y, tv);
    var adam_cpu: AdamSet = try .init(arena, &.{ l1.w, l1.b, l2.w, l2.b });

    // -- The kit, on its CPU twin: the same weights, the same data, at host offsets. --
    const M = zn_mlp;
    var pipe: compute_host.Compute(M) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = M.config.max;
    const w1_off: u32 = 0;
    const w2_off: u32 = @intCast(n_in * hidden + hidden);
    const param_count: u32 = w2_off + @as(u32, @intCast(hidden + 1));
    const x_off: u32 = 0;
    const t_off: u32 = @intCast(rows * n_in);
    const h_off: u32 = t_off + @as(u32, @intCast(rows));
    const y_off: u32 = h_off + @as(u32, @intCast(rows * hidden));
    const dy_off: u32 = 0;
    const dh_off: u32 = @intCast(rows);
    const par: []f32 = try arena.alloc(f32, param_count);
    @memcpy(par[w1_off..][0 .. n_in * hidden], l1.w.data);
    @memcpy(par[n_in * hidden ..][0..hidden], l1.b.data);
    @memcpy(par[w2_off..][0..hidden], l2.w.data);
    par[w2_off + hidden] = l2.b.data[0];
    pipe.upload(.params, par);
    const acts: []f32 = try arena.alloc(f32, rows * n_in + rows);
    @memcpy(acts[0 .. rows * n_in], x.data);
    @memcpy(acts[rows * n_in ..], t.data);
    pipe.upload(.acts, acts);
    const zeros_buf: []f32 = try arena.alloc(f32, param_count);
    @memset(zeros_buf, 0.0);
    pipe.upload(.adam_m, zeros_buf);
    pipe.upload(.adam_v, zeros_buf);

    const Layer1 = M.Params{ .rows = @intCast(rows), .in_dim = @intCast(n_in), .out_dim = @intCast(hidden) };
    var worst_loss_gap: f32 = 0.0;
    for (1..21) |step| {
        // CPU reference step.
        try graph.recompute();
        try graph.backward(loss);
        const cpu_loss: f32 = graph.valueOf(loss).data[0];
        try adam_cpu.apply(&graph, &.{ l1.w, l1.b, l2.w, l2.b }, &.{ l1.w_var, l1.b_var, l2.w_var, l2.b_var }, 1.0e-2);

        // The kit's step, in the order the GPU will run it.
        var p1: M.Params = Layer1;
        p1.act = @backingInt(M.Act.tanh);
        p1.x_off = x_off;
        p1.y_off = h_off;
        p1.w_off = w1_off;
        p1.dy_off = dh_off;
        var p2: M.Params = .{ .rows = @intCast(rows), .in_dim = @intCast(hidden), .out_dim = 1 };
        p2.x_off = h_off;
        p2.y_off = y_off;
        p2.t_off = t_off;
        p2.w_off = w2_off;
        p2.dy_off = dy_off;
        p2.dx_off = dh_off;
        pipe.params = p1;
        pipe.run("dense_fwd", @intCast(rows * hidden));
        pipe.params = p2;
        pipe.run("dense_fwd", @intCast(rows));
        pipe.run("mse_value", 1);
        pipe.run("mse_bwd", @intCast(rows));
        pipe.run("dense_bwd_w", @intCast(hidden + 1));
        pipe.run("dense_bwd_x", @intCast(rows * hidden));
        pipe.params = p1;
        pipe.run("act_bwd", @intCast(rows * hidden));
        pipe.run("dense_bwd_w", @intCast(n_in * hidden + hidden));
        // Adam's bias corrections as zimrnum's Adam forms them, for the kernel's default betas.
        const kernel_defaults: zn_mlp.Params = .{};
        const corrections: zn.AdamCorrections(f32) = zn.adamCorrectionMultipliers(
            f32,
            kernel_defaults.beta1,
            kernel_defaults.beta2,
            step,
        );
        pipe.params = .{
            .w_off = 0,
            .count = param_count,
            .rate = 1.0e-2,
            .correction1 = corrections.first,
            .correction2 = corrections.second,
        };
        pipe.run("adam", param_count);
        const kit_loss: f32 = (pipe.readLatest(.loss) orelse return error.NoReadback)[0];
        worst_loss_gap = @max(worst_loss_gap, @abs(kit_loss - cpu_loss));
    }
    const kit_params: []const f32 = pipe.readLatest(.params) orelse return error.NoReadback;
    var worst_weight_gap: f32 = 0.0;
    for (l1.w.data, 0..) |w, i| {
        worst_weight_gap = @max(worst_weight_gap, @abs(w - kit_params[w1_off + i]));
    }
    for (l2.w.data, 0..) |w, i| {
        worst_weight_gap = @max(worst_weight_gap, @abs(w - kit_params[w2_off + i]));
    }
    report.print("\n  G1 parity, 20 Adam steps: worst loss gap {e:.2}, worst weight gap {e:.2}\n", .{
        worst_loss_gap,
        worst_weight_gap,
    });
    try expect(worst_loss_gap < 1.0e-5);
    try expect(worst_weight_gap < 1.0e-5);
}

test "gpu learn: D5 step 3a - cloning on the kit is the graph's, step for step; log-std and value untouched" {
    // The clone's proof, in G1's manner: GPU PPO's `cloneMinibatch` (the policy half of PPO's update, with
    // `mse_bwd` for the PPO head and Adam over the policy's layers only) against zimrnum's graph of the SAME
    // three-layer tanh policy, from the kit's own initial weights, on the same rows: 10 steps both ways, and
    // the weights must agree to float precision. And what cloning must NOT touch - the log-std row and the
    // value net - must come out bit for bit as they went in.
    const gpa: Allocator = testing_allocator;
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const n_obs: usize = 7;
    const n_act: usize = 3;
    const hidden: usize = 16;
    const rows: usize = 8;
    const rate: f32 = 1.0e-2;
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    var ppo: GpuPpo = try .init(gpa, &pipe, n_obs, n_act, .{
        .hidden = hidden,
        .rows = rows,
        .learning_rate = rate,
        .seed = 3,
    });
    defer ppo.deinit(gpa);
    const start: []f32 = try arena.dupe(f32, ppo.cpu_params);

    // The graph: the same three layers, from the kit's weights.
    var init_rng: Random.DefaultPrng = .init(1);
    const random: Random = init_rng.random();
    var l1: Layer = try .init(arena, random, n_obs, hidden, 1.0);
    var l2: Layer = try .init(arena, random, hidden, hidden, 1.0);
    var l3: Layer = try .init(arena, random, hidden, n_act, 1.0);
    const layers = [_]*Layer{ &l1, &l2, &l3 };
    const ins = [_]usize{ n_obs, hidden, hidden };
    const outs = [_]usize{ hidden, hidden, n_act };
    for (layers, ins, outs, 0..) |layer, in_dim, out_dim, i| {
        const at: usize = ppo.p_off[i];
        @memcpy(layer.w.data, start[at..][0 .. in_dim * out_dim]);
        @memcpy(layer.b.data, start[at + in_dim * out_dim ..][0..out_dim]);
    }
    const x: zn.Tensor(f32) = try .alloc(arena, &.{ rows, n_obs });
    const t: zn.Tensor(f32) = try .alloc(arena, &.{ rows, n_act });
    for (x.data) |*v| {
        v.* = 2.0 * random.float(f32) - 1.0;
    }
    for (t.data) |*v| {
        v.* = 2.0 * random.float(f32) - 1.0;
    }
    const ones_t: zn.Tensor(f32) = try .alloc(arena, &.{ rows, 1 });
    @memset(ones_t.data, 1.0);
    var graph: zn.Graph(f32) = .init(arena);
    const xv: zn.Var = try graph.constant(x);
    const tv: zn.Var = try graph.constant(t);
    const ones: zn.Var = try graph.constant(ones_t);
    const h1: zn.Var = try graph.tanh(try l1.apply(&graph, xv, ones));
    const h2: zn.Var = try graph.tanh(try l2.apply(&graph, h1, ones));
    const y: zn.Var = try l3.apply(&graph, h2, ones);
    const loss: zn.Var = try graph.mseLoss(y, tv);
    const tensors = [_]zn.Tensor(f32){ l1.w, l1.b, l2.w, l2.b, l3.w, l3.b };
    var adam_cpu: AdamSet = try .init(arena, &tensors);
    var first_loss: f32 = 0.0;
    var last_loss: f32 = 0.0;
    for (0..10) |step| {
        try graph.recompute();
        try graph.backward(loss);
        last_loss = graph.valueOf(loss).data[0];
        if (step == 0) {
            first_loss = last_loss;
        }
        try adam_cpu.apply(&graph, &tensors, &.{ l1.w_var, l1.b_var, l2.w_var, l2.b_var, l3.w_var, l3.b_var }, rate);
        ppo.cloneMinibatch(x.data, t.data);
    }
    const kit: []const f32 = pipe.readLatest(.params) orelse return error.NoReadback;
    var worst: f32 = 0.0;
    for (layers, ins, outs, 0..) |layer, in_dim, out_dim, i| {
        const at: usize = ppo.p_off[i];
        for (layer.w.data, kit[at..][0 .. in_dim * out_dim]) |a, b| {
            worst = @max(worst, @abs(a - b));
        }
        for (layer.b.data, kit[at + in_dim * out_dim ..][0..out_dim]) |a, b| {
            worst = @max(worst, @abs(a - b));
        }
    }
    var untouched: bool = true;
    for (start[ppo.log_std_off..ppo.param_count], kit[ppo.log_std_off..ppo.param_count]) |a, b| {
        untouched = untouched and a == b;
    }
    report.print("\n  D5 3a: 10 clone steps - kit vs graph weights at most {e:.2} apart; loss {d:.4} -> {d:.4}; " ++
        "log-std and value untouched: {}\n", .{ worst, first_loss, last_loss, untouched });
    try expect(worst < 1.0e-5);
    try expect(untouched);
    try expect(last_loss < first_loss);
}

test "gpu learn: GPU PPO (on the kit's CPU twin) learns the cartpole hold" {
    // ** THE LEARNER THE CARTPOLE PAGE WILL RUN, proven before the page exists: PPO whose update
    // is the zn_mlp kit (here its CPU twin - the same kernels a GPU runs), acting on the CPU.
    // zimrnum's continuous cartpole, task `.hold`, +-10 N, episodes capped at 500. 16 envs x 64
    // steps an iteration, GAE(0.99, 0.95), advantages normalised, 4 epochs of 256-row minibatches.
    // ~20 s: a learning run, gated like its siblings (G1's parity is the fast proof of the kit).
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    // A MEASUREMENT: it asserts nothing (a crash aside), so it runs when its table is asked for -
    // `-Dslow-tests -Dtest-report` - and not on every slow run, which would print nothing. See
    // `report.requested`.
    if (!report.requested()) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    var ppo: GpuPpo = try .init(gpa, &pipe, zrl.cartpole_state_dim, zrl.cartpole_action_dim, .{});
    defer ppo.deinit(gpa);
    const envs: usize = 16;
    const horizon: usize = 64;
    const samples: usize = envs * horizon;
    var states: [16]zrl.CartpoleState(f32) = undefined;
    var lengths: [16]u32 = @splat(0);
    var episode_counter: u32 = 0;
    for (&states) |*st| {
        st.* = zrl.cartpoleTaskReset(f32, zn.Rng.init(1), episode_counter, .hold);
        episode_counter += 1;
    }
    const obs_all: []f32 = try gpa.alloc(f32, samples * 4);
    defer gpa.free(obs_all);
    const act_all: []f32 = try gpa.alloc(f32, samples);
    defer gpa.free(act_all);
    const logp_all: []f32 = try gpa.alloc(f32, samples);
    defer gpa.free(logp_all);
    const advantages: []f64 = try gpa.alloc(f64, samples);
    defer gpa.free(advantages);
    const returns: []f64 = try gpa.alloc(f64, samples);
    defer gpa.free(returns);
    var rollout: zrl.RolloutBuffer = try .init(gpa, samples);
    defer rollout.deinit(gpa);
    var rng: Random.DefaultPrng = .init(5);
    const random: Random = rng.random();
    var order: [1024]u32 = undefined;
    for (&order, 0..) |*o, i| {
        o.* = @intCast(i);
    }
    report.print("\n  GPU PPO (CPU twin) on the cartpole hold (cap 500):\n", .{});
    for (0..40) |iteration| {
        rollout.len = 0;
        var finished: u32 = 0;
        var finished_steps: u64 = 0;
        // Env-major segments: each env's `horizon` steps together, cut with a bootstrap at the end.
        for (0..envs) |e| {
            for (0..horizon) |t| {
                const row: usize = e * horizon + t;
                var obs: [4]f32 = undefined;
                try zrl.cartpoleObserve(f32, states[e], &obs);
                @memcpy(obs_all[row * 4 ..][0..4], &obs);
                var action: [1]f32 = undefined;
                logp_all[row] = ppo.act(&obs, &action, random);
                act_all[row] = action[0];
                const v_now: f32 = ppo.value(&obs);
                const stepped = zrl.cartpoleTaskStep(f32, states[e], 10.0 * clamp(action[0], -1.0, 1.0), .hold);
                lengths[e] += 1;
                const capped: bool = !stepped.failed and lengths[e] >= 500;
                const segment_end: bool = t == horizon - 1;
                var v_next: f32 = 0.0;
                if (!stepped.failed) {
                    var next_obs: [4]f32 = undefined;
                    try zrl.cartpoleObserve(f32, stepped.state, &next_obs);
                    v_next = ppo.value(&next_obs);
                }
                const truncated: bool = capped or (segment_end and !stepped.failed);
                try rollout.record(stepped.reward, v_now, v_next, stepped.failed, truncated, logp_all[row]);
                states[e] = stepped.state;
                if (stepped.failed or capped) {
                    finished += 1;
                    finished_steps += lengths[e];
                    lengths[e] = 0;
                    states[e] = zrl.cartpoleTaskReset(f32, zn.Rng.init(1), episode_counter, .hold);
                    episode_counter += 1;
                }
            }
        }
        try zrl.gae(rollout.steps[0..rollout.len], 0.99, 0.95, advantages, returns);
        try zrl.normalizeAdvantages(f64, advantages, 1.0e-8);
        // 4 epochs of shuffled 256-row minibatches, each one kit step.
        for (0..4) |_| {
            random.shuffle(u32, order[0..samples]);
            var start: usize = 0;
            while (start < samples) : (start += ppo.options.rows) {
                const block: GpuPpo.Staged = ppo.stage();
                for (0..ppo.options.rows) |i| {
                    const src: usize = order[start + i];
                    @memcpy(block.obs[i * 4 ..][0..4], obs_all[src * 4 ..][0..4]);
                    block.act[i] = act_all[src];
                    block.old[i] = logp_all[src];
                    block.adv[i] = @floatCast(advantages[src]);
                    block.ret[i] = @floatCast(returns[src]);
                }
                ppo.trainMinibatch();
            }
        }
        _ = ppo.syncWeights();
        if (iteration % 5 == 4) {
            const mean_length: f32 = if (finished > 0) float(finished_steps) / float(finished) else 500.0;
            report.print("    iteration {d:>2} ({d:>5} samples): {d:>3} " ++
                "episodes finished, mean length {d:>6.1}\n", .{
                iteration + 1, (iteration + 1) * samples, finished, mean_length,
            });
        }
    }
}

/// SAC's update on the kit as this file imports it.
const GpuSac = gym.GpuSacOn(zn_mlp);

test "gpu learn: S2 - the kit's SAC update is SacAgent's, update for update" {
    // *** THE PROOF S2 STANDS ON, as G1's was for the layer kit: `SacAgent` (zimrnum's CPU
    // graphs) and the kit's SAC (on its CPU twin, dispatched exactly as a GPU runs it), from the
    // same weights, fed the same batches and the same noise for 5 updates. Two action dimensions,
    // so the per-dimension paths are exercised; a raised learning rate, so the updates move the
    // weights far enough to disagree if anything is wrong. Every parameter group must agree.
    const gpa: Allocator = testing_allocator;
    const n_obs: usize = 4;
    const n_act: usize = 2;
    const batch: usize = 8;
    const agent: *gym.SacAgent = try .init(gpa, n_obs, n_act, .{
        .hidden = 16,
        .batch = batch,
        .replay_capacity = 64,
        .warmup = 0,
        .learning_rate = 1.0e-2,
        .seed = 3,
    });
    defer agent.deinit();
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    var sac: GpuSac = try .initFrom(gpa, &pipe, agent);
    defer sac.deinit(gpa);
    // What the weights were, to prove below that the updates MOVED them - tiny gaps between
    // two learners that both did nothing would prove nothing.
    const start: []f32 = try gpa.dupe(f32, sac.readParams() orelse return error.NoReadback);
    defer gpa.free(start);
    var rng: Random.DefaultPrng = .init(9);
    const random: Random = rng.random();
    const width: usize = 2 * n_obs + n_act + 2;
    var rows: [batch * width]f32 = undefined;
    var next_noise: [batch * n_act]f32 = undefined;
    var actor_noise: [batch * n_act]f32 = undefined;
    for (0..5) |_| {
        for (0..batch) |i| {
            const row: []f32 = rows[i * width ..][0..width];
            for (row) |*v| {
                v.* = 2.0 * random.float(f32) - 1.0;
            }
            // The last column is the bootstrap discount: 0 for a termination, gamma otherwise.
            row[width - 1] = if (i % 4 == 0) 0.0 else 0.99;
        }
        for (&next_noise) |*v| {
            v.* = random.floatNorm(f32);
        }
        for (&actor_noise) |*v| {
            v.* = random.floatNorm(f32);
        }
        try agent.updateWith(&rows, &next_noise, &actor_noise);
        sac.updateWith(&rows, &next_noise, &actor_noise);
    }
    const gpu: []const f32 = sac.readParams() orelse return error.NoReadback;
    const gaps: GpuSac.Gaps = sac.gapsTo(agent, gpu);
    report.print("\n  S2 parity, 5 SAC updates: actor {e:.2}, log-std {e:.2}, log-alpha {e:.2}, " ++
        "critics {e:.2}, targets {e:.2}\n", .{
        gaps.actor, gaps.log_std, gaps.log_alpha, gaps.critics, gaps.targets,
    });
    try expect(gaps.actor < 1.0e-4 and gaps.log_std < 1.0e-4 and gaps.log_alpha < 1.0e-4);
    try expect(gaps.critics < 1.0e-4 and gaps.targets < 1.0e-4);
    var moved_actor: f32 = 0.0;
    for (start[sac.actor[0]..][0..sac.actor_count], gpu[sac.actor[0]..][0..sac.actor_count]) |a, b| {
        moved_actor = @max(moved_actor, @abs(a - b));
    }
    var moved_critics: f32 = 0.0;
    for (start[sac.q1[0]..][0..sac.critic_count], gpu[sac.q1[0]..][0..sac.critic_count]) |a, b| {
        moved_critics = @max(moved_critics, @abs(a - b));
    }
    report.print("  moved: actor {d:.4}, critics {d:.4}\n", .{ moved_actor, moved_critics });
    try expect(moved_actor > 1.0e-3 and moved_critics > 1.0e-3);
}

const st_mod = @import("robot_supertrack.zig");
/// SuperTrack's training steps on the kit as this file imports it.
const StKit = st_mod.SuperTrackKitOn(zn_mlp);

fn stParity(fused: bool) !void {
    // *** AS S2 WAS FOR SAC: `robot_supertrack.SuperTrack` (zimrnum's graph) and the kit's
    // SuperTrack (its CPU twin, dispatched exactly as a GPU runs it), from the same weights, fed
    // the same windows, start states and noise for 4 iterations of (world step, policy step), at
    // a raised learning rate. Both networks must agree - while their weights MOVE.
    const gpa: Allocator = testing_allocator;
    const options: st_mod.Options = .{
        .batch = 8,
        .hidden = 16,
        .wm_window = 4,
        .policy_window = 6,
        .wm_rate = 1.0e-2,
        .policy_rate = 1.0e-2,
    };
    const graph: *st_mod.SuperTrack = try .init(gpa, options);
    defer graph.deinit();
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    var kit: StKit = try .initFrom(gpa, &pipe, graph);
    defer kit.deinit();
    const start: []f32 = try gpa.dupe(f32, kit.readParams() orelse return error.NoReadback);
    defer gpa.free(start);
    var rng: Random.DefaultPrng = .init(21);
    const random: Random = rng.random();
    const b: usize = options.batch;
    const states: []f32 = try gpa.alloc(f32, b * (options.wm_window + 1) * 4);
    defer gpa.free(states);
    const forces: []f32 = try gpa.alloc(f32, b * options.wm_window);
    defer gpa.free(forces);
    const starts: []f32 = try gpa.alloc(f32, b * 4);
    defer gpa.free(starts);
    const noise: []f32 = try gpa.alloc(f32, options.policy_window * b);
    defer gpa.free(noise);
    for (0..4) |_| {
        for (states) |*v| {
            v.* = 0.3 * (2.0 * random.float(f32) - 1.0);
        }
        for (forces) |*v| {
            v.* = 2.0 * random.float(f32) - 1.0;
        }
        for (starts) |*v| {
            v.* = 0.2 * (2.0 * random.float(f32) - 1.0);
        }
        for (noise) |*v| {
            v.* = random.floatNorm(f32);
        }
        _ = try graph.trainWorldWith(states, forces);
        _ = try graph.trainPolicyWith(starts, noise);
        if (fused) {
            kit.trainWorldFused(states, forces);
            kit.trainPolicyFused(starts, noise);
        } else {
            kit.trainWorldWith(states, forces);
            kit.trainPolicyWith(starts, noise);
        }
    }
    const now: []const f32 = kit.readParams() orelse return error.NoReadback;
    const gaps: [2]f32 = kit.gapsTo(graph, now);
    var moved_policy: f32 = 0.0;
    for (start[0..kit.pol_count], now[0..kit.pol_count]) |a, c| {
        moved_policy = @max(moved_policy, @abs(a - c));
    }
    var moved_world: f32 = 0.0;
    for (start[kit.wm[0]..][0..kit.wm_count], now[kit.wm[0]..][0..kit.wm_count]) |a, c| {
        moved_world = @max(moved_world, @abs(a - c));
    }
    report.print("\n  SuperTrack kit parity ({s}), 4 iterations: policy {e:.2}, world {e:.2}; " ++
        "moved policy {d:.4}, world {d:.4}\n", .{
        if (fused) "fused" else "per-layer", gaps[0], gaps[1], moved_policy, moved_world,
    });
    try expect(gaps[0] < 1.0e-4 and gaps[1] < 1.0e-4);
    try expect(moved_policy > 1.0e-3 and moved_world > 1.0e-3);
}

test "gpu learn: SuperTrack on the kit is the graph's, step for step" {
    // *** AS S2 WAS FOR SAC: `robot_supertrack.SuperTrack` (zimrnum's graph) and the kit's
    // SuperTrack (its CPU twin, dispatched exactly as a GPU runs it), from the same weights, fed
    // the same windows, start states and noise for 4 iterations of (world step, policy step), at
    // a raised learning rate - both the per-layer path (~1,050 dispatches an iteration) and the
    // FUSED one (8). Both networks must agree - while their weights MOVE.
    try stParity(false);
    try stParity(true);
}

fn stCartpole(fused: bool) !void {
    // The kit training the real task end to end, at the full configuration (batch 32, windows
    // 8 / 32): the graph SuperTrack only gathers and samples (its buffer, its gym, its CPU
    // policy forward, fed the kit's policy after every step); the KIT does all the training.
    // The same gym, pushes and evaluation as robot_supertrack's own run - and the milliseconds
    // an iteration, which decide whether a page can afford it.
    const gpa: Allocator = testing_allocator;
    const options: st_mod.Options = .{};
    const host: *st_mod.SuperTrack = try .init(gpa, options);
    defer host.deinit();
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    var kit: StKit = try .initFrom(gpa, &pipe, host);
    defer kit.deinit();
    const io: Io = std.testing.io;
    var states: [8]zrl.CartpoleState(f32) = undefined;
    var steps: [8]u32 = @splat(0);
    var segments: [8]u32 = undefined;
    var next_segment: u32 = 0;
    var episode: u32 = 0;
    for (0..8) |e| {
        states[e] = zrl.cartpoleTaskReset(f32, zn.Rng.init(7), episode, .hold);
        episode += 1;
        segments[e] = next_segment;
        next_segment += 1;
    }
    const baseline: f32 = st_mod.evaluate(null, 10, 99);
    var train_ns: i96 = 0;
    var trained: u32 = 0;
    var final_eval: f32 = 0.0;
    report.print("\n  SuperTrack on the kit's CPU twin ({s}), real cartpole (baseline {d:.1}):\n", .{
        if (fused) "fused" else "per-layer",
        baseline,
    });
    for (1..2001) |iteration| {
        for (0..4) |_| {
            for (0..8) |e| {
                if (steps[e] > 0 and steps[e] % st_mod.push_every == 0) {
                    states[e].pole_rate_rad += st_mod.push_size * (2.0 * host.rng.random().float(f32) - 1.0);
                    segments[e] = next_segment;
                    next_segment += 1;
                }
                const force: f32 = host.act(st_mod.fromCartpole(states[e]), true);
                host.remember(e, st_mod.fromCartpole(states[e]), force, segments[e]);
                const stepped = zrl.cartpoleContinuousStep(f32, states[e], force);
                steps[e] += 1;
                if (stepped.failed or steps[e] >= st_mod.episode_cap) {
                    states[e] = zrl.cartpoleTaskReset(f32, zn.Rng.init(7), episode, .hold);
                    episode += 1;
                    steps[e] = 0;
                    segments[e] = next_segment;
                    next_segment += 1;
                } else {
                    states[e] = stepped.state;
                }
            }
        }
        if (host.sampleWorldBatch() and host.samplePolicyBatch()) {
            const started: Io.Timestamp = Io.Clock.now(.awake, io);
            if (fused) {
                kit.trainWorldFused(host.stage_states, host.stage_forces);
                kit.trainPolicyFused(host.stage_starts, host.stage_noise);
            } else {
                kit.trainWorldWith(host.stage_states, host.stage_forces);
                kit.trainPolicyWith(host.stage_starts, host.stage_noise);
            }
            const params_: []const f32 = kit.readParams() orelse return error.NoReadback;
            train_ns += Io.Clock.now(.awake, io).nanoseconds - started.nanoseconds;
            trained += 1;
            host.loadPolicy(params_, kit.pol);
        }
        if (iteration % 500 == 0) {
            final_eval = st_mod.evaluate(host, 10, 99);
            report.print("    iteration {d:>4}: REAL episodes {d:.1} steps\n", .{ iteration, final_eval });
            // The claim is "it gets past the bar within 2,000 iterations": stop once it has, unless the table is
            // asked for, which wants the whole curve.
            const cleared: bool = final_eval > baseline * 4.0;
            if (cleared and !report.requested()) {
                break;
            }
        }
    }
    const ms: f64 = float64(train_ns) / 1.0e6 / float64(@max(trained, 1));
    report.print("    the kit's CPU twin: {d:.2} ms an iteration " ++
        "(world step + policy step, batch 32, windows 8/32)\n", .{ms});
    try expect(final_eval > baseline * 4.0);
}

test "gpu learn: SuperTrack FUSED on the kit's CPU twin holds the real cartpole - and its cost" {
    // The kit training the real task end to end on the FUSED path (8 dispatches an iteration),
    // full configuration: the graph SuperTrack only gathers and samples; the kit trains. The
    // same gym, pushes and evaluation as robot_supertrack's own run, and the ms an iteration.
    // ~30 s: a learning run, gated like its siblings (the fused PARITY test is the fast proof).
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    try stCartpole(true);
}

test "gpu learn: SuperTrack per-layer on the kit's CPU twin holds the real cartpole - and its cost" {
    // The same on the per-layer path (~1,050 dispatches an iteration): slow, and superseded by
    // the fused path for training - kept as the reference the fused path was measured against.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    // PARKED (Oct 12): superseded by the fused path, which still runs; this is the reference it was
    // measured against. `-Dslow-tests -Dparked-tests` runs it; see `report.parked`.
    if (report.parked()) {
        return error.SkipZigTest;
    }
    try stCartpole(false);
}

/// The rate `geno_track`'s XOR confidence test trains at - one that never diverges (checked above).
const xor_page_rate: f32 = 0.2;

test "gpu learn: XOR on zn_train's CPU twin over long runs - does the loss stay finite?" {
    // Simon's phone: `geno_track`'s XOR confidence test drove the loss to 0 and then NaN inside 2,000-step runs.
    // The same kernels on their CPU twin, as the page drives them: eight seeds x 2,000 steps, the loss checked
    // at EVERY step. Finite throughout: the NaN is the GPU's (driver, precision), not the algorithm's. Not: the
    // algorithm's, and the first step it happens at says where to look.
    const samples: u32 = 4;
    const inputs: u32 = 2;
    const hidden: u32 = 4;
    const outputs: u32 = 1;
    const param_count: usize = inputs * hidden + hidden + hidden * outputs + outputs;
    const data = [_]f32{ 0, 0, 0, 1, 1, 0, 1, 1 } ++ [_]f32{ 0, 1, 1, 0 };
    // Rate 0.5 (zimrnum_train's) first - the phone's - then the candidates for a rate that never diverges.
    for ([_]f32{ 0.5, 0.2, 0.1 }) |rate| {
        var bad_runs: usize = 0;
        var converged: usize = 0;
        for (1..9) |seed| {
            var pipe: compute_host.Compute(zn_train) = .initCpu();
            defer pipe.deinit();
            pipe.element_count = samples * hidden;
            pipe.params = .{ .samples = samples, .inputs = inputs, .hidden = hidden, .outputs = outputs, .rate = rate };
            pipe.upload(.inputs, &data);
            var weights: [param_count]f32 = undefined;
            var rng: Random.DefaultPrng = .init(seed);
            for (&weights, 0..) |*w, i| {
                const bias: bool = (i >= inputs * hidden and i < inputs * hidden + hidden) or i == param_count - 1;
                w.* = if (bias) 0.0 else rng.random().floatNorm(f32);
            }
            pipe.upload(.params, &weights);
            var first_bad: ?usize = null;
            var last: f32 = 0.0;
            var best: f32 = 1.0e30;
            for (0..2000) |k| {
                pipe.params.step = @intCast(k);
                pipe.run("fwd_hidden", samples * hidden);
                pipe.run("fwd_out", samples * outputs);
                pipe.run("loss_value", 1);
                pipe.run("loss_grad", samples * outputs);
                pipe.run("bwd_w2", hidden * outputs);
                pipe.run("bwd_h", samples * hidden);
                pipe.run("bwd_w1", inputs * hidden);
                pipe.run("step", @intCast(param_count));
                const loss: []const f32 = pipe.readLatest(.loss) orelse continue;
                last = loss[0];
                if (!(last == last and @abs(last) < 1.0e30)) {
                    first_bad = k;
                    break;
                }
                best = @min(best, last);
            }
            if (first_bad != null) {
                bad_runs += 1;
            }
            if (best < 0.01) {
                converged += 1;
            }
        }
        report.print("{s}  XOR on the CPU twin, rate {d:.1}: {d} of 8 runs converged (< 0.01), " ++
            "{d} went non-finite\n", .{
            if (rate == 0.5) "\n" else "",
            rate,
            converged,
            bad_runs,
        });
        // The page's rate must never diverge; 0.5 is kept in the sweep as the phone's evidence.
        if (rate == xor_page_rate) {
            try expect(bad_runs == 0);
        }
    }
}

test "gpu learn: a PPO actor's policy file acts as PPO acts, bit for bit - normalised, through its layers, clamped" {
    const gpa: Allocator = testing_allocator;
    const n_obs: usize = 7;
    const n_act: usize = 3;
    const hidden: usize = 16;
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    var ppo: GpuPpo = try .init(gpa, &pipe, n_obs, n_act, .{ .hidden = hidden, .rows = 8, .seed = 5 });
    defer ppo.deinit(gpa);
    // The normaliser's statistics, made up: a mean and a spread that differ from input to input.
    const observations_seen: u64 = 1000;
    var observation_means: [n_obs]f64 = undefined;
    var observation_squared_deviation_sums: [n_obs]f64 = undefined;
    for (&observation_means, &observation_squared_deviation_sums, 0..) |*mean, *m2, input_index| {
        const spread: f64 = 0.5 + 0.2 * float64(input_index);
        mean.* = 0.3 * float64(input_index) - 1.0;
        m2.* = spread * spread * float64(observations_seen);
    }
    // PPO's own clamps: its normaliser's, and the controller's range.
    const observation_clamp: f64 = (ppo_track.Options{}).observation_clamp;
    const action_limit: f32 = (track_env.Options{}).action_limit;
    // PPO's normaliser (`zrl.ObsNormalizer`), holding the made-up statistics.
    const ppo_normalizer: zrl.ObsNormalizer = .{
        .mean = &observation_means,
        .m2 = &observation_squared_deviation_sums,
        .count = float64(observations_seen),
        .clip = observation_clamp,
    };
    var policy: lab.GenoPolicy = try lab.policyOfPpo(gpa, .{
        .kit_parameters = ppo.cpu_params,
        .actor_layer_offsets = ppo.p_off,
        .observation_size = n_obs,
        .hidden_width = hidden,
        .action_size = n_act,
        .observation_normalizer = ppo_normalizer,
        .action_limit = action_limit,
        .action_scale = 0.3,
        .filter_beta = 0.2,
        .decimation = 2,
    });
    defer policy.deinit(gpa);
    // Through its file, as the lab reads it.
    const bytes: []u8 = try lab.PolicyFile.encode(gpa, &policy);
    defer gpa.free(bytes);
    var read_back: lab.GenoPolicy = try lab.PolicyFile.decode(gpa, bytes);
    defer read_back.deinit(gpa);
    var ping: [hidden]f32 = undefined;
    var pong: [hidden]f32 = undefined;
    const scratch: lab.PolicyScratch = .{ .ping = &ping, .pong = &pong };
    var generator: Random.DefaultPrng = .init(11);
    const random: Random = generator.random();
    for (0..20) |_| {
        var observation: [n_obs]f32 = undefined;
        for (&observation) |*value| {
            value.* = 4.0 * random.float(f32) - 2.0;
        }
        // PPO's way: its normaliser, its actor's mean, the watch's clamp.
        var normalized: [n_obs]f32 = observation;
        try ppo_normalizer.applyInPlaceF32(&normalized);
        var ppo_action: [n_act]f32 = undefined;
        ppo.actMean(&normalized, &ppo_action);
        for (&ppo_action) |*component| {
            component.* = clamp(component.*, -action_limit, action_limit);
        }
        var policy_action: [n_act]f32 = undefined;
        lab.policyMeanAction(&read_back, &observation, scratch, &policy_action);
        try expectEqualSlices(f32, &ppo_action, &policy_action);
    }
}

/// A slice as a row accessor (`zm.requireRowAccess`), for the tests' own statistics.
const TestRow = struct {
    values: []const f32,

    pub fn at(row: TestRow, index: usize) f32 {
        return row.values[index];
    }
};

/// Where a normed layer's values live in the kit's buffers for the tests: acts and dacts regions, params offsets.
const NormedRegions = struct {
    rows: u32,
    input_width: u32,
    output_width: u32,
    simnorm_group: u32,
    epsilon: f32,
    // params (and grads, laid out alike)
    weights: u32,
    gains: u32,
    // acts
    input: u32,
    linear: u32,
    normalised: u32,
    scaled: u32,
    output: u32,
    inverse_spreads: u32,
    targets: u32,
    acts_end: u32,
    // dacts
    output_gradient: u32,
    scaled_gradient: u32,
    linear_gradient: u32,
    input_gradient: u32,

    fn of(
        rows: u32,
        input_width: u32,
        output_width: u32,
        simnorm_group: u32,
        epsilon: f32,
    ) NormedRegions {
        const block: u32 = rows * output_width;
        const input_block: u32 = rows * input_width;
        const regions: NormedRegions = .{
            .rows = rows,
            .input_width = input_width,
            .output_width = output_width,
            .simnorm_group = simnorm_group,
            .epsilon = epsilon,
            .weights = 0,
            .gains = input_width * output_width + output_width,
            .input = 0,
            .linear = input_block,
            .normalised = input_block + block,
            .scaled = input_block + 2 * block,
            .output = input_block + 3 * block,
            .inverse_spreads = input_block + 4 * block,
            .targets = input_block + 4 * block + rows,
            .acts_end = input_block + 5 * block + rows,
            .output_gradient = 0,
            .scaled_gradient = block,
            .linear_gradient = 2 * block,
            .input_gradient = 3 * block,
        };
        return regions;
    }
};

/// A normed layer's norm and activation on the kit's CPU twin, from the pre-activations already in acts.
fn normedLayerNormAndActivation(
    pipe: *compute_host.Compute(zn_mlp),
    regions: NormedRegions,
    is_mish: bool,
) void {
    const rows: u32 = regions.rows;
    const out_dim: u32 = regions.output_width;
    pipe.params = .{
        .rows = rows,
        .out_dim = out_dim,
        .x_off = regions.linear,
        .w_off = regions.gains,
        .z_off = regions.normalised,
        .y_off = regions.scaled,
        .l_off = regions.inverse_spreads,
        .norm_epsilon = regions.epsilon,
    };
    pipe.run("norm_fwd", rows);
    pipe.params = .{
        .rows = rows,
        .out_dim = out_dim,
        .x_off = regions.scaled,
        .y_off = regions.output,
        .simnorm_group = regions.simnorm_group,
    };
    if (is_mish) {
        pipe.run("mish_fwd", rows * out_dim);
    } else {
        pipe.run("simnorm_fwd", rows * (out_dim / regions.simnorm_group));
    }
}

/// One normed layer's forward on the kit's CPU twin, from the input already in acts (`NormedRegions`): the linear
/// part, then the norm and the activation.
fn normedLayerForward(
    pipe: *compute_host.Compute(zn_mlp),
    regions: NormedRegions,
    is_mish: bool,
) void {
    pipe.params = .{
        .rows = regions.rows,
        .in_dim = regions.input_width,
        .out_dim = regions.output_width,
        .act = @backingInt(zn_mlp.Act.linear),
        .x_off = regions.input,
        .y_off = regions.linear,
        .w_off = regions.weights,
    };
    pipe.run("dense_fwd", regions.rows * regions.output_width);
    normedLayerNormAndActivation(pipe, regions, is_mish);
}

/// One normed layer's backward on the kit's CPU twin, as the device runs it - the gradient at the output from the
/// MSE against `targets`, then each of the forward's steps in reverse - from a forward already in `acts`'s regions
/// (`NormedRegions`). The gradients land in grads (W, b, then gains and norm biases, at `regions.weights`) and in
/// dacts (the input's, at `regions.input_gradient`).
fn normedLayerBackward(
    pipe: *compute_host.Compute(zn_mlp),
    regions: NormedRegions,
    is_mish: bool,
) void {
    const rows: u32 = regions.rows;
    const out_dim: u32 = regions.output_width;
    const block: u32 = rows * out_dim;
    pipe.params = .{
        .rows = rows,
        .out_dim = out_dim,
        .y_off = regions.output,
        .t_off = regions.targets,
        .dy_off = regions.output_gradient,
    };
    pipe.run("mse_bwd", block);
    if (is_mish) {
        pipe.params = .{
            .rows = rows,
            .out_dim = out_dim,
            .x_off = regions.scaled,
            .dy_off = regions.output_gradient,
            .dx_off = regions.scaled_gradient,
        };
        pipe.run("mish_bwd", block);
    } else {
        pipe.params = .{
            .rows = rows,
            .out_dim = out_dim,
            .y_off = regions.output,
            .dy_off = regions.output_gradient,
            .dx_off = regions.scaled_gradient,
            .simnorm_group = regions.simnorm_group,
        };
        pipe.run("simnorm_bwd", rows * (out_dim / regions.simnorm_group));
    }
    pipe.params = .{
        .rows = rows,
        .out_dim = out_dim,
        .dy_off = regions.scaled_gradient,
        .z_off = regions.normalised,
        .w_off = regions.gains,
    };
    pipe.run("norm_params_bwd", 2 * out_dim);
    pipe.params = .{
        .rows = rows,
        .out_dim = out_dim,
        .dy_off = regions.scaled_gradient,
        .w_off = regions.gains,
        .z_off = regions.normalised,
        .l_off = regions.inverse_spreads,
        .dx_off = regions.linear_gradient,
    };
    pipe.run("norm_bwd", rows);
    pipe.params = .{
        .rows = rows,
        .in_dim = regions.input_width,
        .out_dim = out_dim,
        .x_off = regions.input,
        .dy_off = regions.linear_gradient,
        .w_off = regions.weights,
    };
    pipe.run("dense_bwd_w", regions.input_width * out_dim + out_dim);
    pipe.params = .{
        .rows = rows,
        .in_dim = regions.input_width,
        .out_dim = out_dim,
        .dy_off = regions.linear_gradient,
        .w_off = regions.weights,
        .dx_off = regions.input_gradient,
    };
    pipe.run("dense_bwd_x", rows * regions.input_width);
}

test "gpu learn: the kit's normed layer forward is zimrnum's - norm and activation to the bit, layer to rounding" {
    // A NormedDense as EfficientTDMPC builds them - 6 inputs to 16 outputs, through Mish, and through SimNorm in
    // groups of 8 - forward on the kit's CPU twin, kernel by kernel as the device runs them (`dense_fwd` linear,
    // `norm_fwd`, then `mish_fwd` or `simnorm_fwd`), against zimrnum's graph of the same layer. The norm and the
    // activation are zimrmath's functions on both sides, so on the graph's OWN pre-activations the kit writes the
    // graph's output to the bit, and its normalised row and inverse spreads are zimrmath's. The whole layer, from the
    // input, differs only by the linear part's order of summation: to rounding. Gains and norm biases are set away
    // from 1 and 0, so a kernel that skipped them would show.
    const gpa: Allocator = testing_allocator;
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const rows: usize = 3;
    const input_width: usize = 6;
    const output_width: usize = 16;
    const simnorm_group: usize = 8;
    const input_values = [_]f32{
        0.3,  -1.2, 0.8,  2.0,  -0.4, 0.05,
        -0.7, 0.9,  1.5,  -2.2, 0.1,  0.6,
        1.1,  0.0,  -0.3, 0.4,  -1.8, 2.5,
    };
    const activations = [_]zn.Activation{ .mish, .{ .sim_norm = simnorm_group } };
    for (activations, 0..) |activation, layer_seed| {
        const normed: zn.NormedDense(f32) = try .init(
            arena,
            zn.Rng.init(@intCast(41 + layer_seed)),
            input_width,
            output_width,
            .xavier,
            activation,
            0,
        );
        for (normed.norm.gain.data, normed.norm.bias.data, 0..) |*gain, *norm_bias, feature| {
            gain.* = 0.5 + 0.1 * float(feature);
            norm_bias.* = 0.2 - 0.03 * float(feature);
        }
        // -- zimrnum's graph: the layer, and its linear part alone (the pre-activations).
        var graph: zn.Graph(f32) = .init(arena);
        const input_shape = [_]usize{ rows, input_width };
        const input: zn.Tensor(f32) = try .fromSlice(try arena.dupe(f32, &input_values), &input_shape);
        const input_value: zn.Var = try graph.constant(input);
        const through_graph: zn.NormedDense(f32).Attached = try normed.attach(&graph, input_value);
        const linear: zn.Dense(f32).Attached = try normed.dense.attach(&graph, input_value);
        const graph_output: []const f32 = graph.valueOf(through_graph.out).data;
        const graph_linear: []const f32 = graph.valueOf(linear.out).data;

        // -- The kit: W and b, then the gains and the norm biases, in params; the activations' regions in acts.
        const regions: NormedRegions = .of(
            @intCast(rows),
            @intCast(input_width),
            @intCast(output_width),
            @intCast(simnorm_group),
            normed.norm.epsilon,
        );
        const block: usize = rows * output_width;
        const parameters: []f32 = try arena.alloc(f32, input_width * output_width + 3 * output_width);
        var filled: usize = 0;
        for (normed.tensors()) |tensor| {
            @memcpy(parameters[filled..][0..tensor.data.len], tensor.data);
            filled += tensor.data.len;
        }
        const acts: []f32 = try arena.alloc(f32, regions.acts_end);
        @memset(acts, 0);
        @memcpy(acts[regions.input..][0..input_values.len], &input_values);
        const is_mish: bool = activation == .mish;
        var pipe: compute_host.Compute(zn_mlp) = .initCpu();
        defer pipe.deinit();
        // Readbacks hold this many values of each buffer: the whole of what the test wrote.
        pipe.element_count = @intCast(acts.len);
        pipe.upload(.params, parameters);
        // The norm and the activation, on the GRAPH's pre-activations.
        @memcpy(acts[regions.linear..][0..block], graph_linear);
        pipe.upload(.acts, acts);
        normedLayerNormAndActivation(&pipe, regions, is_mish);
        const on_graph_inputs: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
        try expectEqualSlices(f32, graph_output, on_graph_inputs[regions.output..][0..block]);
        // Its normalised rows and inverse spreads are zimrmath's statistics of the same rows.
        for (0..rows) |row| {
            const row_values: []const f32 = graph_linear[row * output_width ..][0..output_width];
            const statistics: zm.LayerNormStatistics(f32) = zm.layerNormRowStatistics(
                f32,
                TestRow,
                .{ .values = row_values },
                output_width,
                normed.norm.epsilon,
            );
            try expectEqual(statistics.inverse_spread, on_graph_inputs[regions.inverse_spreads + row]);
            for (row_values, 0..) |pre_activation, column| {
                const normalised: f32 = zm.layerNormValue(f32, pre_activation, statistics);
                try expectEqual(normalised, on_graph_inputs[regions.normalised + row * output_width + column]);
            }
        }
        // The whole layer, from the input: the kit's linear part, then the same norm and activation - to rounding.
        @memset(acts[regions.linear..], 0);
        pipe.upload(.acts, acts);
        normedLayerForward(&pipe, regions, is_mish);
        const from_input: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
        for (graph_output, from_input[regions.output..][0..block]) |expected, computed| {
            try expectApproxEqAbs(expected, computed, 1e-5);
        }
    }
}

test "gpu learn: the kit's normed layer backward is zimrnum's - every gradient, and a central difference" {
    // The two layers of the forward's test, now trained one MSE step's worth: the graph's gradients - at the input,
    // the weight, the bias, the gain and the norm bias - against the kit's, from `mse_bwd` back through the
    // activation's, `norm_params_bwd`, `norm_bwd` and the dense backward. To rounding: the dense parts sum in another
    // order. And one weight's gradient against the kit's OWN central difference of its loss, so the kit is right in
    // itself, not only alike to the graph.
    const gpa: Allocator = testing_allocator;
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const rows: usize = 3;
    const input_width: usize = 6;
    const output_width: usize = 16;
    const simnorm_group: usize = 8;
    const input_values = [_]f32{
        0.3,  -1.2, 0.8,  2.0,  -0.4, 0.05,
        -0.7, 0.9,  1.5,  -2.2, 0.1,  0.6,
        1.1,  0.0,  -0.3, 0.4,  -1.8, 2.5,
    };
    const activations = [_]zn.Activation{ .mish, .{ .sim_norm = simnorm_group } };
    for (activations, 0..) |activation, layer_seed| {
        const is_mish: bool = activation == .mish;
        const normed: zn.NormedDense(f32) = try .init(
            arena,
            zn.Rng.init(@intCast(61 + layer_seed)),
            input_width,
            output_width,
            .xavier,
            activation,
            0,
        );
        for (normed.norm.gain.data, normed.norm.bias.data, 0..) |*gain, *norm_bias, feature| {
            gain.* = 0.5 + 0.1 * float(feature);
            norm_bias.* = 0.2 - 0.03 * float(feature);
        }
        const targets: []f32 = try arena.alloc(f32, rows * output_width);
        for (targets, 0..) |*target, index| {
            target.* = if (is_mish) 0.3 * @sin(float(index)) else 0.125 + 0.05 * @cos(float(index));
        }
        // -- zimrnum's graph: the input a parameter too, so it has a gradient.
        var graph: zn.Graph(f32) = .init(arena);
        const input_shape = [_]usize{ rows, input_width };
        const output_shape = [_]usize{ rows, output_width };
        const input: zn.Tensor(f32) = try .fromSlice(try arena.dupe(f32, &input_values), &input_shape);
        const target_tensor: zn.Tensor(f32) = try .fromSlice(targets, &output_shape);
        const input_value: zn.Var = try graph.parameter(input);
        const target_value: zn.Var = try graph.constant(target_tensor);
        const layer: zn.NormedDense(f32).Attached = try normed.attach(&graph, input_value);
        const loss: zn.Var = try graph.mseLoss(layer.out, target_value);
        try graph.backward(loss);
        const graph_gradients = [_][]const f32{
            (try graph.gradOf(layer.weight)).data,
            (try graph.gradOf(layer.bias)).data,
            (try graph.gradOf(layer.gain)).data,
            (try graph.gradOf(layer.norm_bias)).data,
        };
        const graph_input_gradient: []const f32 = (try graph.gradOf(input_value)).data;

        // -- The kit.
        const regions: NormedRegions = .of(
            @intCast(rows),
            @intCast(input_width),
            @intCast(output_width),
            @intCast(simnorm_group),
            normed.norm.epsilon,
        );
        const weight_count: usize = input_width * output_width;
        const parameters: []f32 = try arena.alloc(f32, weight_count + 3 * output_width);
        var filled: usize = 0;
        for (normed.tensors()) |tensor| {
            @memcpy(parameters[filled..][0..tensor.data.len], tensor.data);
            filled += tensor.data.len;
        }
        const acts: []f32 = try arena.alloc(f32, regions.acts_end);
        @memset(acts, 0);
        @memcpy(acts[regions.input..][0..input_values.len], &input_values);
        @memcpy(acts[regions.targets..][0..targets.len], targets);
        var pipe: compute_host.Compute(zn_mlp) = .initCpu();
        defer pipe.deinit();
        pipe.element_count = @intCast(acts.len);
        pipe.upload(.params, parameters);
        pipe.upload(.acts, acts);
        normedLayerForward(&pipe, regions, is_mish);
        normedLayerBackward(&pipe, regions, is_mish);
        const kit_gradients: []const f32 = pipe.readLatest(.grads) orelse return error.NoReadback;
        const kit_dacts: []const f32 = pipe.readLatest(.dacts) orelse return error.NoReadback;
        var gradient_start: usize = 0;
        for (graph_gradients) |graph_gradient| {
            for (graph_gradient, kit_gradients[gradient_start..][0..graph_gradient.len]) |expected, computed| {
                try expectApproxEqAbs(expected, computed, 1e-5);
            }
            gradient_start += graph_gradient.len;
        }
        const kit_input_gradient: []const f32 = kit_dacts[regions.input_gradient..][0 .. rows * input_width];
        for (graph_input_gradient, kit_input_gradient) |expected, computed| {
            try expectApproxEqAbs(expected, computed, 1e-5);
        }
        // -- A central difference of the kit's own loss in one weight, against the kit's gradient for it: the weight
        // with the LARGEST gradient, so the check cannot pass by both numbers being near zero.
        var moved_weight: usize = 0;
        for (kit_gradients[0..weight_count], 0..) |gradient, weight_index| {
            if (@abs(gradient) > @abs(kit_gradients[moved_weight])) {
                moved_weight = weight_index;
            }
        }
        const difference_step: f32 = 1e-2;
        var loss_at = [2]f64{ 0, 0 };
        for ([2]f32{ difference_step, -difference_step }, 0..) |offset, side| {
            const shifted: []f32 = try arena.dupe(f32, parameters);
            shifted[moved_weight] += offset;
            pipe.upload(.params, shifted);
            pipe.upload(.acts, acts);
            normedLayerForward(&pipe, regions, is_mish);
            const outputs: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
            var squared_error_sum: f64 = 0;
            for (outputs[regions.output..][0..targets.len], targets) |output, target| {
                const error_value: f64 = output - target;
                squared_error_sum += error_value * error_value;
            }
            loss_at[side] = squared_error_sum / float64(targets.len);
        }
        const central_difference: f64 = (loss_at[0] - loss_at[1]) / (2.0 * difference_step);
        const kit_gradient: f64 = kit_gradients[moved_weight];
        // Within 1% of the gradient itself: f32 forwards and a step of 1e-2 leave a central difference that close.
        const tolerance: f64 = 0.01 * @abs(kit_gradient);
        try expect(@abs(kit_gradient) > 1e-3);
        try expectApproxEqAbs(central_difference, kit_gradient, tolerance);
    }
}

test "gpu learn: the kit's two-hot loss, gradient and decode are zimrnum's, bit for bit" {
    // Five rows of 101 logits, BMPC's bins (symlog, [-10, 10]), and targets that land inside a pair of bins, exactly
    // on one, and past both ends (clamped onto the end bins - the top one its own next). On the kit's CPU twin:
    // each row's loss against zimrnum's `softCrossEntropyRows` of that row and its `CategoricalScalar.encode` target;
    // the gradient against `softCrossEntropyRowsGrad` of the batch (its mean: the divisor the row count); the decode
    // against `CategoricalScalar.decode` of the softmax. Every piece is zimrmath's on both sides: to the bit.
    const gpa: Allocator = testing_allocator;
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const scalar: zn.CategoricalScalar(f32) = .{};
    const bins: usize = scalar.bin_count;
    const targets = [_]f32{ 0.5, -3.0, 0.0, 1.0e9, -1.0e9 };
    const rows: usize = targets.len;
    const logits_tensor: zn.Tensor(f32) = try .alloc(arena, &.{ rows, bins });
    for (logits_tensor.data, 0..) |*logit, index| {
        logit.* = 2.0 * @sin(0.37 * float(index)) + 0.5 * @cos(0.11 * float(index));
    }
    // -- zimrnum: the dense two-hot targets, each row's loss, the batch's gradient, the decoded values.
    const target_tensor: zn.Tensor(f32) = try .alloc(arena, &.{ rows, bins });
    try scalar.encodeRows(&targets, target_tensor);
    var expected_losses: [targets.len]f32 = undefined;
    for (0..rows) |row| {
        const row_logits: zn.Tensor(f32) = try .fromSlice(logits_tensor.data[row * bins ..][0..bins], &.{ 1, bins });
        const row_targets: zn.Tensor(f32) = try .fromSlice(target_tensor.data[row * bins ..][0..bins], &.{ 1, bins });
        expected_losses[row] = try zn.softCrossEntropyRows(f32, row_logits, row_targets);
    }
    const expected_gradient: zn.Tensor(f32) = try .alloc(arena, &.{ rows, bins });
    try zn.softCrossEntropyRowsGrad(f32, expected_gradient, logits_tensor, target_tensor);
    const probabilities: zn.Tensor(f32) = try .alloc(arena, &.{ rows, bins });
    try zn.softmaxRows(f32, probabilities, logits_tensor);
    var expected_values: [targets.len]f32 = undefined;
    try scalar.decodeRows(probabilities, &expected_values);

    // -- The kit: logits, then targets, then the losses and the values, in acts; the gradient in dacts.
    const logits_offset: u32 = 0;
    const targets_offset: u32 = @intCast(rows * bins);
    const losses_offset: u32 = targets_offset + @as(u32, @intCast(rows));
    const values_offset: u32 = losses_offset + @as(u32, @intCast(rows));
    const acts: []f32 = try arena.alloc(f32, values_offset + rows);
    @memset(acts, 0);
    @memcpy(acts[logits_offset..][0 .. rows * bins], logits_tensor.data);
    @memcpy(acts[targets_offset..][0..rows], &targets);
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = @intCast(acts.len);
    pipe.upload(.acts, acts);
    const two_hot: zn_mlp.Params = .{
        .rows = @intCast(rows),
        .out_dim = @intCast(bins),
        .x_off = logits_offset,
        .t_off = targets_offset,
        .twohot_low = scalar.low,
        .twohot_high = scalar.high,
        .twohot_axis = @backingInt(zn_mlp.TwoHotAxis.symlog),
        .twohot_divisor = float(rows),
    };
    var loss_params: zn_mlp.Params = two_hot;
    loss_params.y_off = losses_offset;
    pipe.params = loss_params;
    pipe.run("twohot_fwd", @intCast(rows));
    var gradient_params: zn_mlp.Params = two_hot;
    gradient_params.dy_off = 0;
    pipe.params = gradient_params;
    pipe.run("twohot_bwd", @intCast(rows));
    var decode_params: zn_mlp.Params = two_hot;
    decode_params.y_off = values_offset;
    pipe.params = decode_params;
    pipe.run("twohot_decode", @intCast(rows));
    const kit_acts: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
    const kit_dacts: []const f32 = pipe.readLatest(.dacts) orelse return error.NoReadback;
    try expectEqualSlices(f32, &expected_losses, kit_acts[losses_offset..][0..rows]);
    try expectEqualSlices(f32, expected_gradient.data, kit_dacts[0 .. rows * bins]);
    try expectEqualSlices(f32, &expected_values, kit_acts[values_offset..][0..rows]);
    // The losses are real cross-entropies: above the two-hot's own entropy, so above zero. (The targets past the bins'
    // ends are clamped onto the end bins on both sides - the gradient's rows show it, matching zimrnum's to the bit.)
    for (kit_acts[losses_offset..][0..rows]) |loss| {
        try expect(loss > 0);
    }
}

test "gpu learn: a two-hot target that is not a number stays in its row - its results NaN, the other row whole" {
    // A value target from a diverged model can be NaN. The two-hot kernels place it at 0 rather than let it become a
    // bin index (on a device, where min and max of a NaN are undefined, it could index anywhere) and make that row's
    // results NaN, so the learner's check for non-finite losses still sees it. The other row is untouched: its loss
    // and gradient are zimrnum's for it alone, the gradient halved by the batch's divisor of 2.
    const gpa: Allocator = testing_allocator;
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const scalar: zn.CategoricalScalar(f32) = .{};
    const bins: usize = scalar.bin_count;
    const rows: usize = 2;
    const nan_value: f32 = nan(f32);
    const targets = [_]f32{ 0.5, nan_value };
    const acts: []f32 = try arena.alloc(f32, rows * bins + 2 * rows);
    @memset(acts, 0);
    for (acts[0 .. rows * bins], 0..) |*logit, index| {
        logit.* = @sin(0.21 * float(index));
    }
    const targets_offset: u32 = @intCast(rows * bins);
    const losses_offset: u32 = targets_offset + @as(u32, @intCast(rows));
    @memcpy(acts[targets_offset..][0..rows], &targets);
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = @intCast(acts.len);
    pipe.upload(.acts, acts);
    const two_hot: zn_mlp.Params = .{
        .rows = @intCast(rows),
        .out_dim = @intCast(bins),
        .x_off = 0,
        .t_off = targets_offset,
        .y_off = losses_offset,
        .dy_off = 0,
        .twohot_divisor = float(rows),
    };
    pipe.params = two_hot;
    pipe.run("twohot_fwd", @intCast(rows));
    pipe.run("twohot_bwd", @intCast(rows));
    const kit_acts: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
    const kit_dacts: []const f32 = pipe.readLatest(.dacts) orelse return error.NoReadback;
    // The NaN row: a NaN loss, every gradient NaN.
    try expect(zm.isNan(kit_acts[losses_offset + 1]));
    for (kit_dacts[bins..][0..bins]) |gradient| {
        try expect(zm.isNan(gradient));
    }
    // The whole row: zimrnum's, for it alone.
    const first_logits: zn.Tensor(f32) = try .fromSlice(acts[0..bins], &.{ 1, bins });
    const first_target: zn.Tensor(f32) = try .alloc(arena, &.{ 1, bins });
    try scalar.encodeRows(targets[0..1], first_target);
    const expected_loss: f32 = try zn.softCrossEntropyRows(f32, first_logits, first_target);
    try expectEqual(expected_loss, kit_acts[losses_offset]);
    const expected_gradient: zn.Tensor(f32) = try .alloc(arena, &.{ 1, bins });
    try zn.softCrossEntropyRowsGrad(f32, expected_gradient, first_logits, first_target);
    for (expected_gradient.data, kit_dacts[0..bins]) |expected, computed| {
        try expectEqual(expected / 2, computed);
    }
}

test "gpu learn: a whole Mlp on the kit is zimrnum's - its output, every parameter's gradient and the input's" {
    // EfficientTDMPC's two shapes of network, laid out by `robot_bmpc_kit.KitNetwork` and run on the CPU twin: an
    // encoder (a normed Mish layer, then a normed SimNorm layer) and a head (two normed Mish layers, then a plain
    // layer of 101 outputs). Each forward over 5 rows, an MSE gradient at its output, and its backward - against
    // zimrnum's graph of the same `Mlp`: the output, the gradient of every tensor of every layer in zimrnum's order,
    // and the input's. To rounding: each dense layer sums in its own order.
    const gpa: Allocator = testing_allocator;
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const KitNetwork: type = kit_mlp.KitNetwork(zn_mlp);
    const rows: usize = 5;
    const encoder_spec: zn.Mlp(f32).Spec = .{
        .input = 12,
        .hidden = &.{16},
        .output = 16,
        .output_activation = .{ .sim_norm = 8 },
    };
    const head_spec: zn.Mlp(f32).Spec = .{ .input = 16, .hidden = &.{ 16, 16 }, .output = 101 };
    const specs = [_]zn.Mlp(f32).Spec{ encoder_spec, head_spec };
    for (specs, 0..) |spec, network_seed| {
        const mlp: zn.Mlp(f32) = try .init(arena, zn.Rng.init(@intCast(71 + network_seed)), spec);
        const input_values: []f32 = try arena.alloc(f32, rows * spec.input);
        for (input_values, 0..) |*value, index| {
            value.* = 1.3 * @sin(0.61 * float(index) + float(network_seed));
        }
        const target_values: []f32 = try arena.alloc(f32, rows * spec.output);
        for (target_values, 0..) |*value, index| {
            value.* = 0.2 * @cos(0.43 * float(index));
        }
        // -- zimrnum's graph: the input a parameter, so it has a gradient.
        var graph: zn.Graph(f32) = .init(arena);
        const input_shape = [_]usize{ rows, spec.input };
        const output_shape = [_]usize{ rows, spec.output };
        const input_tensor: zn.Tensor(f32) = try .fromSlice(try arena.dupe(f32, input_values), &input_shape);
        const target_tensor: zn.Tensor(f32) = try .fromSlice(try arena.dupe(f32, target_values), &output_shape);
        const input_value: zn.Var = try graph.parameter(input_tensor);
        const target_value: zn.Var = try graph.constant(target_tensor);
        const through_graph: zn.Mlp(f32).Attached = try mlp.attach(&graph, input_value, arena);
        const loss: zn.Var = try graph.mseLoss(through_graph.out, target_value);
        try graph.backward(loss);
        const graph_output: []const f32 = graph.valueOf(through_graph.out).data;

        // -- The kit: the network's parameters, the input and targets, one application, the output's gradient.
        var layout: kit_mlp.KitLayout = .{};
        const network: KitNetwork = try .init(arena, &layout, mlp);
        const input_offset: u32 = layout.reserveActs(@intCast(input_values.len));
        const target_offset: u32 = layout.reserveActs(@intCast(target_values.len));
        const app: KitNetwork.Application = try network.application(arena, &layout, @intCast(rows));
        const output_gradient: u32 = layout.reserveDacts(@intCast(target_values.len));
        const params: []f32 = try arena.alloc(f32, layout.params_floats);
        network.writeParams(mlp, params);
        const acts: []f32 = try arena.alloc(f32, layout.acts_floats);
        @memset(acts, 0);
        @memcpy(acts[input_offset..][0..input_values.len], input_values);
        @memcpy(acts[target_offset..][0..target_values.len], target_values);
        var pipe: compute_host.Compute(zn_mlp) = .initCpu();
        defer pipe.deinit();
        pipe.element_count = layout.largestBuffer();
        pipe.upload(.params, params);
        pipe.upload(.acts, acts);
        app.forward(&pipe, input_offset, 0);
        pipe.params = .{
            .rows = @intCast(rows),
            .out_dim = @intCast(spec.output),
            .y_off = app.outputsOffset(),
            .t_off = target_offset,
            .dy_off = output_gradient,
        };
        pipe.run("mse_bwd", @intCast(rows * spec.output));
        app.backward(&pipe, @intCast(rows), input_offset, 0, output_gradient, .overwrite);
        const kit_acts: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
        const kit_grads: []const f32 = pipe.readLatest(.grads) orelse return error.NoReadback;
        const kit_dacts: []const f32 = pipe.readLatest(.dacts) orelse return error.NoReadback;
        for (graph_output, kit_acts[app.outputsOffset()..][0..graph_output.len]) |expected, computed| {
            try expectApproxEqAbs(expected, computed, 1e-5);
        }
        // Every tensor's gradient, in zimrnum's order - which is the network's params order on the kit.
        var gradient_start: usize = 0;
        for (through_graph.values) |parameter| {
            const graph_gradient: []const f32 = (try graph.gradOf(parameter)).data;
            for (graph_gradient, kit_grads[gradient_start..][0..graph_gradient.len]) |expected, computed| {
                try expectApproxEqAbs(expected, computed, 1e-5);
            }
            gradient_start += graph_gradient.len;
        }
        try expectEqual(@as(usize, layout.params_floats), gradient_start);
        const graph_input_gradient: []const f32 = (try graph.gradOf(input_value)).data;
        const kit_input_gradient: []const f32 = kit_dacts[app.inputsGradientOffset()..][0..graph_input_gradient.len];
        for (graph_input_gradient, kit_input_gradient) |expected, computed| {
            try expectApproxEqAbs(expected, computed, 1e-5);
        }
    }
}

test "gpu learn: the latent rollout on the kit is LatentRollout's - the consistency and every network's gradients" {
    // EfficientTDMPC's world model on one window - 4 windows of 3 steps, 2 dynamics heads, latent 16 in SimNorm groups
    // of 8, 4 actions - as zimrrl's `LatentRollout` builds it on zimrnum's graph and as `robot_bmpc_kit.KitRollout`
    // runs it on the CPU twin: the same encoder, heads, observations and actions. The consistency loss's value (from
    // the kit's predictions and targets, read back) and its gradient at every parameter of the encoder and of each
    // head, to rounding.
    const gpa: Allocator = testing_allocator;
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const KitNetwork: type = kit_mlp.KitNetwork(zn_mlp);
    const KitRollout: type = bmpc_kit.KitRollout(zn_mlp);
    const horizon: usize = 3;
    const batch: usize = 4;
    const observation_width: usize = 10;
    const action_width: usize = 4;
    const latent_width: usize = 16;
    const head_count: usize = 2;
    const rho: f32 = 0.5;
    const encoder: zn.Mlp(f32) = try .init(arena, zn.Rng.init(81), .{
        .input = observation_width,
        .hidden = &.{16},
        .output = latent_width,
        .output_activation = .{ .sim_norm = 8 },
    });
    var heads: [head_count]zn.Mlp(f32) = undefined;
    for (&heads, 0..) |*head, head_index| {
        head.* = try zn.Mlp(f32).init(arena, zn.Rng.init(@intCast(91 + head_index)), .{
            .input = latent_width + action_width,
            .hidden = &.{ 16, 16 },
            .output = latent_width,
            .output_activation = .{ .sim_norm = 8 },
        });
    }
    const observations: []f32 = try arena.alloc(f32, (horizon + 1) * batch * observation_width);
    for (observations, 0..) |*value, index| {
        value.* = 1.2 * @sin(0.37 * float(index));
    }
    const actions: []f32 = try arena.alloc(f32, horizon * batch * action_width);
    for (actions, 0..) |*value, index| {
        value.* = 0.8 * @cos(0.53 * float(index));
    }

    // -- zimrrl's LatentRollout on zimrnum's graph.
    var graph: zn.Graph(f32) = .init(arena);
    const encoder_bound: []zn.Var = try encoder.bind(&graph, .trained, arena);
    var head_bounds: [head_count][]const zn.Var = undefined;
    for (&head_bounds, heads) |*bound, head| {
        bound.* = try head.bind(&graph, .trained, arena);
    }
    const observation_shape = [_]usize{ (horizon + 1) * batch, observation_width };
    const observation_tensor: zn.Tensor(f32) = try .fromSlice(try arena.dupe(f32, observations), &observation_shape);
    var action_values: [horizon]zn.Var = undefined;
    for (&action_values, 0..) |*action_value, step| {
        const step_block: []const f32 = actions[step * batch * action_width ..][0 .. batch * action_width];
        const step_actions: []f32 = try arena.dupe(f32, step_block);
        const step_tensor: zn.Tensor(f32) = try .fromSlice(step_actions, &.{ batch, action_width });
        action_value.* = try graph.constant(step_tensor);
    }
    const rollout: zrl.LatentRollout(f32) = try .build(
        &graph,
        encoder,
        encoder_bound,
        &heads,
        &head_bounds,
        try graph.constant(observation_tensor),
        &action_values,
        .{ .horizon = horizon, .batch = batch, .rho = rho },
        arena,
    );
    try graph.backward(rollout.consistency);
    const graph_consistency: f32 = graph.valueOf(rollout.consistency).data[0];

    // -- The kit's rollout on the CPU twin.
    var layout: kit_mlp.KitLayout = .{};
    const kit_encoder: KitNetwork = try .init(arena, &layout, encoder);
    var kit_heads: [head_count]KitNetwork = undefined;
    for (&kit_heads, heads) |*kit_head, head| {
        kit_head.* = try KitNetwork.init(arena, &layout, head);
    }
    const kit_rollout: KitRollout = try .init(arena, &layout, kit_encoder, &kit_heads, .{
        .horizon = horizon,
        .window_count = batch,
        .observation_width = observation_width,
        .action_width = action_width,
        .rho = rho,
    });
    const params: []f32 = try arena.alloc(f32, layout.params_floats);
    kit_encoder.writeParams(encoder, params);
    for (kit_heads, heads) |kit_head, head| {
        kit_head.writeParams(head, params);
    }
    const acts: []f32 = try arena.alloc(f32, layout.acts_floats);
    @memset(acts, 0);
    kit_rollout.writeWindow(acts, observations, actions);
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = layout.largestBuffer();
    pipe.upload(.params, params);
    pipe.upload(.acts, acts);
    kit_rollout.forward(&pipe);
    kit_rollout.backward(&pipe, 1.0);
    const kit_acts: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
    const kit_grads: []const f32 = pipe.readLatest(.grads) orelse return error.NoReadback;

    // The consistency, from the kit's predictions and targets: per head, sum over t of rho^t / H x the step's mean
    // squared error; averaged over the heads.
    var kit_consistency: f64 = 0;
    for (kit_rollout.dynamics_heads) |head| {
        var step_weight: f64 = 1;
        for (head.step_applications, 0..) |step, step_index| {
            const predicted: []const f32 = kit_acts[step.outputsOffset()..][0 .. batch * latent_width];
            const target_start: u32 = kit_rollout.encodedLatentsOffset(@intCast(step_index + 1));
            const target: []const f32 = kit_acts[target_start..][0 .. batch * latent_width];
            var squared_error_sum: f64 = 0;
            for (predicted, target) |prediction, encoded| {
                const difference: f64 = prediction - encoded;
                squared_error_sum += difference * difference;
            }
            const mean_squared_error: f64 = squared_error_sum / float64(predicted.len);
            kit_consistency += step_weight / float64(horizon) * mean_squared_error / float64(head_count);
            step_weight *= rho;
        }
    }
    try expectApproxEqAbs(graph_consistency, @as(f32, @floatCast(kit_consistency)), 1e-6);
    try expect(graph_consistency > 1e-4);
    // Every parameter's gradient: the encoder's tensors, then each head's, in the kit's params order.
    const bounds_in_order = [_][]const zn.Var{ encoder_bound, head_bounds[0], head_bounds[1] };
    var gradient_start: usize = 0;
    for (bounds_in_order) |bound| {
        for (bound) |parameter| {
            const graph_gradient: []const f32 = (try graph.gradOf(parameter)).data;
            for (graph_gradient, kit_grads[gradient_start..][0..graph_gradient.len]) |expected, computed| {
                try expectApproxEqAbs(expected, computed, 1e-6);
            }
            gradient_start += graph_gradient.len;
        }
    }
    try expectEqual(@as(usize, layout.params_floats), gradient_start);
}

/// EfficientTDMPC's world model built twice for its known answers, from the same networks, window and targets: on
/// zimrnum's graph - zimrrl's `LatentRollout` and `WorldModelLoss`, the CPU agent's own - and on the kit's CPU twin,
/// `robot_bmpc_kit.KitWorldModel`. One window of 4 windows by 3 steps; an encoder, 2 dynamics heads, a reward head, 2
/// value heads and their 2 slow copies; BMPC's weights (20, 0.1, 0.1) and bins (101 on [-10, 10] of symlog). Value
/// dropout is off: the kit has none yet. The reward and value heads start with random last layers - BMPC zeroes them
/// (`zero_last`), which would leave every earlier layer's first gradient zero and the comparisons empty.
const WorldModelFixture = struct {
    const KitNetwork: type = kit_mlp.KitNetwork(zn_mlp);
    const KitRollout: type = bmpc_kit.KitRollout(zn_mlp);
    const KitWorldModel: type = bmpc_kit.KitWorldModel(zn_mlp);
    const KitPolicyLearner: type = bmpc_kit.KitPolicyLearner(zn_mlp);
    const KitValueTargets: type = bmpc_kit.KitValueTargets(zn_mlp);
    const horizon: usize = 3;
    const window_count: usize = 4;
    const observation_width: usize = 10;
    const action_width: usize = 4;
    const latent_width: usize = 16;
    const dynamics_head_count: usize = 2;
    const value_head_count: usize = 2;
    const rho: f32 = 0.5;
    /// The value targets' discount, and the seed of the policy's noise in them.
    const discount: f32 = 0.95;
    const target_noise_seed: u64 = 151;
    /// The value heads' dropout on their first layer: 25%, where BMPC's is 1% - at 1%, a window this small could drop
    /// no unit at all and leave the dropout untested. Off unless a test hands in a generator.
    const value_dropout: f32 = 0.25;

    // The networks, as zimrnum holds them.
    encoder: zn.Mlp(f32),
    dynamics: [dynamics_head_count]zn.Mlp(f32),
    reward_head: zn.Mlp(f32),
    value_heads: [value_head_count]zn.Mlp(f32),
    target_value_heads: [value_head_count]zn.Mlp(f32),
    policy: zn.Mlp(f32),
    // The window: step-major observations and actions, and one reward and one value target per window and step.
    observations: []f32,
    actions: []f32,
    rewards: []f32,
    value_targets: []f32,
    // The planner's Gaussians at each stored step: its means and the logs of its spreads, [horizon x window_count,
    // action] each, step-major.
    planner_means: []f32,
    planner_log_stds: []f32,
    // The policy's standard normal noise in the value targets, [horizon x window_count, action]: the CPU agent's
    // counter-based draws (`LatentValueTargets.compute`'s), so both sides draw the same actions.
    target_noise: []f32,
    // zimrnum's graph of the loss.
    graph: *zn.Graph(f32),
    encoder_bound: []const zn.Var,
    dynamics_bounds: [dynamics_head_count][]const zn.Var,
    reward_bound: []const zn.Var,
    value_bounds: [value_head_count][]const zn.Var,
    rollout: zrl.LatentRollout(f32),
    /// Each step's actions as graph constants - what a second loss on the same rollout is built with.
    action_values: []zn.Var,
    loss: zrl.WorldModelLoss(f32),
    // The kit's world model and policy learner, uploaded and ready to run.
    layout: kit_mlp.KitLayout,
    kit_value_targets: [value_head_count]KitNetwork,
    world_model: KitWorldModel,
    policy_learner: KitPolicyLearner,
    target_builder: KitValueTargets,
    /// The host's copy of acts as uploaded - a test that writes into it (masks, flags) uploads it again.
    host_acts: []f32,
    pipe: compute_host.Compute(zn_mlp),

    /// Everything built in `arena`; the pipe's own buffers released by `deinit`.
    fn init(fixture: *WorldModelFixture, arena: Allocator) !void {
        // whole-init-first: every field named, each filled below.
        fixture.* = .{
            .encoder = undefined,
            .dynamics = undefined,
            .reward_head = undefined,
            .value_heads = undefined,
            .target_value_heads = undefined,
            .policy = undefined,
            .observations = undefined,
            .actions = undefined,
            .rewards = undefined,
            .value_targets = undefined,
            .planner_means = undefined,
            .planner_log_stds = undefined,
            .target_noise = undefined,
            .graph = undefined,
            .encoder_bound = undefined,
            .dynamics_bounds = undefined,
            .reward_bound = undefined,
            .value_bounds = undefined,
            .rollout = undefined,
            .action_values = undefined,
            .loss = undefined,
            .layout = .{},
            .kit_value_targets = undefined,
            .world_model = undefined,
            .policy_learner = undefined,
            .target_builder = undefined,
            .host_acts = undefined,
            .pipe = undefined,
        };
        const scalar: zn.CategoricalScalar(f32) = .{};
        const bins: usize = scalar.bin_count;
        fixture.encoder = try zn.Mlp(f32).init(arena, zn.Rng.init(81), .{
            .input = observation_width,
            .hidden = &.{16},
            .output = latent_width,
            .output_activation = .{ .sim_norm = 8 },
        });
        for (&fixture.dynamics, 0..) |*head, head_index| {
            head.* = try zn.Mlp(f32).init(arena, zn.Rng.init(@intCast(91 + head_index)), .{
                .input = latent_width + action_width,
                .hidden = &.{ 16, 16 },
                .output = latent_width,
                .output_activation = .{ .sim_norm = 8 },
            });
        }
        fixture.reward_head = try zn.Mlp(f32).init(arena, zn.Rng.init(101), .{
            .input = latent_width + action_width,
            .hidden = &.{ 16, 16 },
            .output = bins,
        });
        for (&fixture.value_heads, &fixture.target_value_heads, 0..) |*value_head, *target_head, value_index| {
            value_head.* = try zn.Mlp(f32).init(arena, zn.Rng.init(@intCast(111 + value_index)), .{
                .input = latent_width,
                .hidden = &.{ 16, 16 },
                .output = bins,
                .first_dropout = value_dropout,
            });
            // The slow copy starts as the online head's twin, as the CPU agent's `Networks.init` makes it.
            const copied: zn.Params(f32) = try (try value_head.params(arena)).clone(arena);
            target_head.* = try value_head.withParams(copied, arena);
        }
        fixture.policy = try zn.Mlp(f32).init(arena, zn.Rng.init(121), .{
            .input = latent_width,
            .hidden = &.{ 16, 16 },
            .output = 2 * action_width,
        });
        fixture.planner_means = try arena.alloc(f32, horizon * window_count * action_width);
        fixture.planner_log_stds = try arena.alloc(f32, horizon * window_count * action_width);
        for (fixture.planner_means, fixture.planner_log_stds, 0..) |*planner_mean, *planner_log_std, index| {
            planner_mean.* = 0.7 * @sin(0.9 * float(index));
            // A planner's spread, between its floor 0.05 and 1.
            const spread: f32 = 0.05 + 0.95 * (0.5 + 0.5 * @cos(1.3 * float(index)));
            planner_log_std.* = @log(spread);
        }
        // The value targets' noise, as `LatentValueTargets.compute` draws it: each stored row's own stream, indexed by
        // step x action width + dimension (one step: the dimension).
        fixture.target_noise = try arena.alloc(f32, horizon * window_count * action_width);
        const noise_rng: zn.Rng = .init(target_noise_seed);
        for (0..horizon * window_count) |stored_row| {
            const row_rng: zn.Rng = noise_rng.split(@intCast(stored_row));
            for (0..action_width) |dimension| {
                fixture.target_noise[stored_row * action_width + dimension] = row_rng.normal(f32, @intCast(dimension));
            }
        }
        fixture.observations = try arena.alloc(f32, (horizon + 1) * window_count * observation_width);
        for (fixture.observations, 0..) |*value, index| {
            value.* = 1.2 * @sin(0.37 * float(index));
        }
        fixture.actions = try arena.alloc(f32, horizon * window_count * action_width);
        for (fixture.actions, 0..) |*value, index| {
            value.* = 0.8 * @cos(0.53 * float(index));
        }
        fixture.rewards = try arena.alloc(f32, horizon * window_count);
        fixture.value_targets = try arena.alloc(f32, horizon * window_count);
        for (fixture.rewards, fixture.value_targets, 0..) |*reward, *value_target, index| {
            reward.* = 0.6 + 0.3 * @sin(float(index));
            value_target.* = 12.0 + 5.0 * @cos(0.7 * float(index));
        }
        try fixture.buildGraph(arena, scalar);
        try fixture.buildKit(arena);
    }

    fn deinit(fixture: *WorldModelFixture) void {
        fixture.pipe.deinit();
    }

    /// zimrnum's graph of the whole loss, its targets filled and its forward pass computed.
    fn buildGraph(
        fixture: *WorldModelFixture,
        arena: Allocator,
        scalar: zn.CategoricalScalar(f32),
    ) !void {
        const graph: *zn.Graph(f32) = try arena.create(zn.Graph(f32));
        graph.* = zn.Graph(f32).init(arena);
        fixture.graph = graph;
        fixture.encoder_bound = try fixture.encoder.bind(graph, .trained, arena);
        for (&fixture.dynamics_bounds, fixture.dynamics) |*bound, head| {
            bound.* = try head.bind(graph, .trained, arena);
        }
        fixture.reward_bound = try fixture.reward_head.bind(graph, .trained, arena);
        for (&fixture.value_bounds, fixture.value_heads) |*bound, value_head| {
            bound.* = try value_head.bind(graph, .trained, arena);
        }
        const observation_shape = [_]usize{ (horizon + 1) * window_count, observation_width };
        const observations_copy: []f32 = try arena.dupe(f32, fixture.observations);
        const observation_tensor: zn.Tensor(f32) = try .fromSlice(observations_copy, &observation_shape);
        const action_values: []zn.Var = try arena.alloc(zn.Var, horizon);
        fixture.action_values = action_values;
        for (action_values, 0..) |*action_value, step| {
            const step_floats: usize = window_count * action_width;
            const step_block: []const f32 = fixture.actions[step * step_floats ..][0..step_floats];
            const step_tensor: zn.Tensor(f32) = try .fromSlice(try arena.dupe(f32, step_block), &.{
                window_count,
                action_width,
            });
            action_value.* = try graph.constant(step_tensor);
        }
        fixture.rollout = try zrl.LatentRollout(f32).build(
            graph,
            fixture.encoder,
            fixture.encoder_bound,
            &fixture.dynamics,
            &fixture.dynamics_bounds,
            try graph.constant(observation_tensor),
            action_values,
            .{ .horizon = horizon, .batch = window_count, .rho = rho },
            arena,
        );
        fixture.loss = try zrl.WorldModelLoss(f32).build(
            graph,
            fixture.rollout,
            action_values,
            fixture.reward_head,
            fixture.reward_bound,
            &fixture.value_heads,
            &fixture.value_bounds,
            null,
            .{ .horizon = horizon, .batch = window_count, .bins = scalar.bin_count, .rho = rho },
            arena,
        );
        for (0..horizon) |step| {
            const step_rewards: []const f32 = fixture.rewards[step * window_count ..][0..window_count];
            const step_values: []const f32 = fixture.value_targets[step * window_count ..][0..window_count];
            try scalar.encodeRows(step_rewards, fixture.loss.reward_targets[step]);
            try scalar.encodeRows(step_values, fixture.loss.value_targets[step]);
        }
        try graph.recompute();
    }

    /// The kit's world model: every network placed in the world model's order - encoder, dynamics heads, reward head,
    /// value heads, then the targets - the window and its targets written, everything uploaded, Adam's moments zero.
    fn buildKit(fixture: *WorldModelFixture, arena: Allocator) !void {
        fixture.layout = .{};
        const layout: *kit_mlp.KitLayout = &fixture.layout;
        const kit_encoder: KitNetwork = try .init(arena, layout, fixture.encoder);
        const kit_dynamics: []KitNetwork = try arena.alloc(KitNetwork, dynamics_head_count);
        for (kit_dynamics, fixture.dynamics) |*kit_head, head| {
            kit_head.* = try KitNetwork.init(arena, layout, head);
        }
        const kit_reward: KitNetwork = try .init(arena, layout, fixture.reward_head);
        const kit_values: []KitNetwork = try arena.alloc(KitNetwork, value_head_count);
        for (kit_values, fixture.value_heads) |*kit_value, value_head| {
            kit_value.* = try KitNetwork.init(arena, layout, value_head);
        }
        for (&fixture.kit_value_targets, fixture.target_value_heads) |*kit_target, target_head| {
            kit_target.* = try KitNetwork.init(arena, layout, target_head);
        }
        // The policy after everything the world model trains and follows: outside its clip's region.
        const kit_policy: KitNetwork = try .init(arena, layout, fixture.policy);
        const kit_rollout: KitRollout = try .init(arena, layout, kit_encoder, kit_dynamics, .{
            .horizon = horizon,
            .window_count = window_count,
            .observation_width = observation_width,
            .action_width = action_width,
            .rho = rho,
        });
        const value_targets: []const KitNetwork = &fixture.kit_value_targets;
        // The value heads drop out on the kit as they can on the CPU - every unit kept until a test writes masks.
        fixture.world_model = try KitWorldModel.init(
            arena,
            layout,
            kit_rollout,
            kit_reward,
            kit_values,
            value_targets,
            .{ .value_dropout = .on },
        );
        fixture.policy_learner = try KitPolicyLearner.init(arena, layout, kit_policy, kit_rollout, .{});
        fixture.target_builder = try KitValueTargets.init(
            arena,
            layout,
            kit_rollout,
            kit_policy,
            kit_reward,
            &fixture.kit_value_targets,
            fixture.world_model.value_targets_offset,
            .{ .discount = discount },
        );
        const params: []f32 = try arena.alloc(f32, layout.params_floats);
        kit_encoder.writeParams(fixture.encoder, params);
        for (kit_dynamics, fixture.dynamics) |kit_head, head| {
            kit_head.writeParams(head, params);
        }
        kit_reward.writeParams(fixture.reward_head, params);
        for (kit_values, fixture.value_heads) |kit_value, value_head| {
            kit_value.writeParams(value_head, params);
        }
        for (fixture.kit_value_targets, fixture.target_value_heads) |kit_target, target_head| {
            kit_target.writeParams(target_head, params);
        }
        kit_policy.writeParams(fixture.policy, params);
        const acts: []f32 = try arena.alloc(f32, layout.acts_floats);
        @memset(acts, 0);
        kit_rollout.writeWindow(acts, fixture.observations, fixture.actions);
        fixture.world_model.writeTargets(acts, fixture.rewards, fixture.value_targets);
        fixture.policy_learner.writeTargets(acts, fixture.planner_means, fixture.planner_log_stds);
        fixture.policy_learner.writeInitialState(acts);
        fixture.target_builder.writeNoise(acts, fixture.target_noise);
        try fixture.world_model.writeValueDropoutMasks(acts, null);
        fixture.host_acts = acts;
        layout.requireFitsKit(zn_mlp);
        const zero_moments: []f32 = try arena.alloc(f32, layout.params_floats);
        @memset(zero_moments, 0);
        fixture.pipe = compute_host.Compute(zn_mlp).initCpu();
        fixture.pipe.element_count = layout.largestBuffer();
        fixture.pipe.upload(.params, params);
        fixture.pipe.upload(.adam_m, zero_moments);
        fixture.pipe.upload(.adam_v, zero_moments);
        fixture.pipe.upload(.acts, acts);
    }

    /// The trained parameters' handles in the kit's params order: the encoder's, each dynamics head's, the reward
    /// head's, each value head's.
    fn trainedBounds(fixture: *const WorldModelFixture, arena: Allocator) ![]const []const zn.Var {
        var bounds: ArrayList([]const zn.Var) = .empty;
        try bounds.append(arena, fixture.encoder_bound);
        try bounds.appendSlice(arena, &fixture.dynamics_bounds);
        try bounds.append(arena, fixture.reward_bound);
        try bounds.appendSlice(arena, &fixture.value_bounds);
        return bounds.items;
    }
};

test "gpu learn: the world model's whole loss on the kit is WorldModelLoss's - its value and every gradient" {
    // The fixture's two world models: the total loss - formed from the kit's predictions, targets and row losses,
    // read back, by the loss's own formula - and the gradient of every parameter of the five trained networks, to
    // rounding.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var fixture: WorldModelFixture = undefined;
    try fixture.init(arena);
    defer fixture.deinit();
    try fixture.graph.backward(fixture.loss.total);
    const graph_total: f32 = fixture.graph.valueOf(fixture.loss.total).data[0];
    const world_model: WorldModelFixture.KitWorldModel = fixture.world_model;
    world_model.forward(&fixture.pipe);
    world_model.rowLosses(&fixture.pipe);
    world_model.backward(&fixture.pipe);
    const kit_acts: []const f32 = fixture.pipe.readLatest(.acts) orelse return error.NoReadback;
    const kit_grads: []const f32 = fixture.pipe.readLatest(.grads) orelse return error.NoReadback;
    // The total, from the kit's numbers.
    const horizon: usize = WorldModelFixture.horizon;
    const window_count: usize = WorldModelFixture.window_count;
    const latent_width: usize = WorldModelFixture.latent_width;
    var consistency_sum: f64 = 0;
    var reward_sum: f64 = 0;
    var value_sum: f64 = 0;
    for (world_model.rollout.dynamics_heads, 0..) |head, head_index| {
        var step_weight: f64 = 1;
        for (head.step_applications, 0..) |step, step_index| {
            const predicted: []const f32 = kit_acts[step.outputsOffset()..][0 .. window_count * latent_width];
            const target_start: u32 = world_model.rollout.encodedLatentsOffset(@intCast(step_index + 1));
            const target: []const f32 = kit_acts[target_start..][0 .. window_count * latent_width];
            var squared_error_sum: f64 = 0;
            for (predicted, target) |prediction, encoded| {
                const difference: f64 = prediction - encoded;
                squared_error_sum += difference * difference;
            }
            consistency_sum += step_weight / float64(horizon) * squared_error_sum / float64(predicted.len);
            const HeadApplication: type = WorldModelFixture.KitWorldModel.HeadApplication;
            const head_rewards: []const HeadApplication = world_model.reward_applications[head_index];
            const reward_losses_offset: u32 = head_rewards[step_index].row_losses_offset;
            for (kit_acts[reward_losses_offset..][0..window_count]) |row_loss| {
                reward_sum += step_weight / float64(horizon) * row_loss / float64(window_count);
            }
            for (world_model.value_applications[head_index][step_index]) |value_at_step| {
                for (kit_acts[value_at_step.row_losses_offset..][0..window_count]) |row_loss| {
                    const value_heads: f64 = float64(WorldModelFixture.value_head_count);
                    const value_share: f64 = step_weight / (float64(horizon) * value_heads);
                    value_sum += value_share * row_loss / float64(window_count);
                }
            }
            step_weight *= WorldModelFixture.rho;
        }
    }
    const heads_divisor: f64 = float64(WorldModelFixture.dynamics_head_count);
    const kit_total: f64 = 20 * consistency_sum / heads_divisor + 0.1 * reward_sum / heads_divisor +
        0.1 * value_sum / heads_divisor;
    try expectApproxEqAbs(graph_total, @as(f32, @floatCast(kit_total)), 1e-5);
    // Every trained parameter's gradient, in the kit's params order.
    var gradient_start: usize = 0;
    for (try fixture.trainedBounds(arena)) |bound| {
        for (bound) |parameter| {
            const graph_gradient: []const f32 = (try fixture.graph.gradOf(parameter)).data;
            for (graph_gradient, kit_grads[gradient_start..][0..graph_gradient.len]) |expected, computed| {
                try expectApproxEqAbs(expected, computed, 1e-6);
            }
            gradient_start += graph_gradient.len;
        }
    }
    try expectEqual(@as(usize, fixture.world_model.model_params_end), gradient_start);
}

test "gpu learn: the world model's update on the kit is the CPU agent's - clip, two Adams, the targets' follow" {
    // Two updates of the fixture's world model, on both sides, as the CPU agent's `WorldModelLearner.learn` takes
    // them: the backward, ONE clip of the global gradient norm (`zimrnum.clipGradNorm`), Adam with the encoder at 0.3 x
    // the rate (`zimrnum.Optimizer`, two of them), and the target value heads' 1% follow (`zimrnum.polyakUpdate`).
    // The clip's limit is set to 0.5 - BMPC's 20 would leave this small model's norm unclipped, its factor exactly 1,
    // and the clip untested. After each update, every parameter of every network, targets included, to rounding;
    // the second update checks that Adam's moments and step count carried over.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var fixture: WorldModelFixture = undefined;
    try fixture.init(arena);
    defer fixture.deinit();
    const update_options: WorldModelFixture.KitWorldModel.UpdateOptions = .{ .gradient_clip = 0.5 };
    // -- The CPU agent's optimiser, over the graph.
    const graph: *zn.Graph(f32) = fixture.graph;
    const encoder_rate: f32 = update_options.learning_rate * update_options.encoder_rate_scale;
    var encoder_optimizer: zn.Optimizer(f32) = try .init(arena, graph, fixture.encoder_bound, .{
        .adam = .{ .rate = encoder_rate },
    });
    var model_handles: ArrayList(zn.Var) = .empty;
    for (fixture.dynamics_bounds) |bound| {
        try model_handles.appendSlice(arena, bound);
    }
    try model_handles.appendSlice(arena, fixture.reward_bound);
    for (fixture.value_bounds) |bound| {
        try model_handles.appendSlice(arena, bound);
    }
    var model_optimizer: zn.Optimizer(f32) = try .init(arena, graph, model_handles.items, .{
        .adam = .{ .rate = update_options.learning_rate },
    });
    var clipped_handles: ArrayList(zn.Var) = .empty;
    try clipped_handles.appendSlice(arena, fixture.encoder_bound);
    try clipped_handles.appendSlice(arena, model_handles.items);
    const world_model: WorldModelFixture.KitWorldModel = fixture.world_model;
    for (1..3) |step| {
        // -- The CPU agent's update.
        if (step > 1) {
            try graph.recompute();
        }
        try graph.backward(fixture.loss.total);
        const cpu_norm: f32 = try zn.clipGradNorm(f32, graph, clipped_handles.items, update_options.gradient_clip);
        try encoder_optimizer.step(graph);
        try model_optimizer.step(graph);
        for (fixture.target_value_heads, fixture.value_bounds) |target_head, value_bound| {
            const target_tensors: []const zn.Tensor(f32) = (try target_head.params(arena)).tensors;
            for (target_tensors, value_bound) |target_tensor, online_handle| {
                try zn.polyakUpdate(f32, target_tensor, graph.valueOf(online_handle), update_options.target_follow);
            }
        }
        // -- The kit's.
        world_model.forward(&fixture.pipe);
        world_model.backward(&fixture.pipe);
        world_model.update(&fixture.pipe, update_options, @intCast(step));
        const kit_params: []const f32 = fixture.pipe.readLatest(.params) orelse return error.NoReadback;
        const kit_acts: []const f32 = fixture.pipe.readLatest(.acts) orelse return error.NoReadback;
        // The clip engaged, and both measured the same norm.
        const kit_norm: f32 = kit_acts[world_model.clip_norm_offset];
        try expect(cpu_norm > update_options.gradient_clip);
        try expectApproxEqRel(cpu_norm, kit_norm, 1e-5);
        // Every trained parameter, in the kit's params order.
        var params_start: usize = 0;
        for (try fixture.trainedBounds(arena)) |bound| {
            for (bound) |parameter| {
                const cpu_values: []const f32 = graph.valueOf(parameter).data;
                for (cpu_values, kit_params[params_start..][0..cpu_values.len]) |expected, computed| {
                    try expectApproxEqAbs(expected, computed, 2e-7);
                }
                params_start += cpu_values.len;
            }
        }
        // The targets, after the trained networks.
        for (fixture.target_value_heads) |target_head| {
            for ((try target_head.params(arena)).tensors) |target_tensor| {
                for (target_tensor.data, kit_params[params_start..][0..target_tensor.data.len]) |expected, computed| {
                    try expectApproxEqAbs(expected, computed, 2e-7);
                }
                params_start += target_tensor.data.len;
            }
        }
        // Everything up to the policy's parameters, which follow the targets.
        try expectEqual(@as(usize, fixture.policy_learner.network.paramsStart()), params_start);
    }
}

test "gpu learn: the policy's distillation on the kit is PolicyDistillationLoss's - its value and every gradient" {
    // BMPC's policy loss on 3 steps of 5 latents: the policy network (latent 16 -> 16 -> 16 -> 2 x 4 actions) through
    // `TanhMeanGaussian`'s head (log spread in [-3, 1]), toward the planner's Gaussians - KL(policy || planner)
    // averaged over the dimensions, over a scale of 1.7, less 1e-4 x dims x the entropy, each row weighted
    // rho^t / (H x batch). On zimrnum's graph as zimrrl's `PolicyDistillationLoss` builds it; on the kit's CPU twin
    // as one application of the policy per step and `policy_distill_bwd` at its outputs. The total, and the gradient
    // of every parameter of the policy network, to rounding.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const KitNetwork: type = kit_mlp.KitNetwork(zn_mlp);
    const horizon: usize = 3;
    const batch: usize = 5;
    const latent_width: usize = 16;
    const action_width: usize = 4;
    const rho: f32 = 0.5;
    const entropy_coefficient: f32 = 1e-4;
    const log_std_low: f32 = -3;
    const log_std_high: f32 = 1;
    const scale: f32 = 1.7;
    const policy: zn.Mlp(f32) = try .init(arena, zn.Rng.init(131), .{
        .input = latent_width,
        .hidden = &.{ 16, 16 },
        .output = 2 * action_width,
    });
    const row_count: usize = horizon * batch;
    const latents: []f32 = try arena.alloc(f32, row_count * latent_width);
    for (latents, 0..) |*value, index| {
        value.* = 0.25 + 0.2 * @sin(0.41 * float(index));
    }
    const target_means: []f32 = try arena.alloc(f32, row_count * action_width);
    const target_log_stds: []f32 = try arena.alloc(f32, row_count * action_width);
    for (target_means, target_log_stds, 0..) |*target_mean, *target_log_std, index| {
        target_mean.* = 0.7 * @sin(0.9 * float(index));
        // A planner's spread, between its floor 0.05 and 1.
        const spread: f32 = 0.05 + 0.95 * (0.5 + 0.5 * @cos(1.3 * float(index)));
        target_log_std.* = @log(spread);
    }

    // -- zimrrl's PolicyDistillationLoss on zimrnum's graph.
    var graph: zn.Graph(f32) = .init(arena);
    const policy_bound: []zn.Var = try policy.bind(&graph, .trained, arena);
    const latent_tensor: zn.Tensor(f32) = try .fromSlice(try arena.dupe(f32, latents), &.{ row_count, latent_width });
    const unfinished: []zn.Tensor(f32) = try arena.alloc(zn.Tensor(f32), horizon);
    for (unfinished) |*column| {
        column.* = try zn.ones(f32, arena, &.{ batch, 1 });
    }
    const loss: zrl.PolicyDistillationLoss(f32) = try .build(
        &graph,
        try graph.constant(latent_tensor),
        unfinished,
        policy,
        policy_bound,
        .{
            .horizon = horizon,
            .batch = batch,
            .rho = rho,
            .entropy_coefficient = entropy_coefficient,
            .log_std_low = log_std_low,
            .log_std_high = log_std_high,
        },
        arena,
    );
    @memcpy(loss.target_means.data, target_means);
    @memcpy(loss.target_log_stds.data, target_log_stds);
    loss.inverse_scale.data[0] = 1 / scale;
    try graph.recompute();
    try graph.backward(loss.total);
    const graph_total: f32 = graph.valueOf(loss.total).data[0];

    // -- The kit: the policy applied once per step, the distillation's gradient at each application's outputs.
    var layout: kit_mlp.KitLayout = .{};
    const kit_policy: KitNetwork = try .init(arena, &layout, policy);
    const latents_offset: u32 = layout.reserveActs(@intCast(latents.len));
    const target_means_offset: u32 = layout.reserveActs(@intCast(target_means.len));
    const target_log_stds_offset: u32 = layout.reserveActs(@intCast(target_log_stds.len));
    const weights_offset: u32 = layout.reserveActs(@intCast(row_count));
    const inverse_scale_offset: u32 = layout.reserveActs(1);
    const divergences_offset: u32 = layout.reserveActs(@intCast(row_count));
    const entropies_offset: u32 = layout.reserveActs(@intCast(row_count));
    const step_applications: []KitNetwork.Application = try arena.alloc(KitNetwork.Application, horizon);
    const step_gradients: []u32 = try arena.alloc(u32, horizon);
    for (step_applications, step_gradients) |*application, *gradient_offset| {
        application.* = try kit_policy.application(arena, &layout, @intCast(batch));
        gradient_offset.* = layout.reserveDacts(@intCast(batch * 2 * action_width));
    }
    layout.requireFitsKit(zn_mlp);
    const params: []f32 = try arena.alloc(f32, layout.params_floats);
    kit_policy.writeParams(policy, params);
    const acts: []f32 = try arena.alloc(f32, layout.acts_floats);
    @memset(acts, 0);
    @memcpy(acts[latents_offset..][0..latents.len], latents);
    @memcpy(acts[target_means_offset..][0..target_means.len], target_means);
    @memcpy(acts[target_log_stds_offset..][0..target_log_stds.len], target_log_stds);
    // Each row's weight as the loss makes it: rho^t, a running product, times 1 / (H x batch).
    const row_share: f32 = 1.0 / float(row_count);
    var step_weight: f32 = 1;
    for (0..horizon) |step| {
        @memset(acts[weights_offset + step * batch ..][0..batch], step_weight * row_share);
        step_weight *= rho;
    }
    acts[inverse_scale_offset] = 1 / scale;
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = layout.largestBuffer();
    pipe.upload(.params, params);
    pipe.upload(.acts, acts);
    for (step_applications, step_gradients, 0..) |application, gradient_offset, step| {
        const step_rows: u32 = @intCast(step * batch);
        const latent_columns: u32 = @intCast(latent_width);
        const action_columns: u32 = @intCast(action_width);
        const step_latents: u32 = latents_offset + step_rows * latent_columns;
        application.forward(&pipe, step_latents, 0);
        pipe.params = .{
            .rows = @intCast(batch),
            .out_dim = @intCast(action_width),
            .x_off = application.outputsOffset(),
            .t_off = target_means_offset + step_rows * action_columns,
            .u_off = target_log_stds_offset + step_rows * action_columns,
            .v_off = weights_offset + step_rows,
            .e_off = inverse_scale_offset,
            .y_off = divergences_offset + step_rows,
            .z_off = entropies_offset + step_rows,
            .dy_off = gradient_offset,
            .distill_log_std_low = log_std_low,
            .distill_log_std_high = log_std_high,
            .distill_entropy_coefficient = entropy_coefficient,
        };
        pipe.run("policy_distill_bwd", @intCast(batch));
        const parameter_gradients: kit_mlp.ParameterGradients = if (step == 0) .overwrite else .add;
        application.backward(&pipe, @intCast(batch), step_latents, 0, gradient_offset, parameter_gradients);
    }
    const kit_acts: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
    const kit_grads: []const f32 = pipe.readLatest(.grads) orelse return error.NoReadback;
    // The total, from the kit's per-row divergences and entropies by the loss's own formula.
    var kit_total: f64 = 0;
    for (0..row_count) |row| {
        const weight: f64 = acts[weights_offset + row];
        const divergence: f64 = kit_acts[divergences_offset + row];
        const entropy: f64 = kit_acts[entropies_offset + row];
        kit_total += weight * (divergence / scale - entropy_coefficient * float64(action_width) * entropy);
    }
    try expectApproxEqRel(graph_total, @as(f32, @floatCast(kit_total)), 1e-5);
    var gradient_start: usize = 0;
    for (policy_bound) |parameter| {
        const graph_gradient: []const f32 = (try graph.gradOf(parameter)).data;
        for (graph_gradient, kit_grads[gradient_start..][0..graph_gradient.len]) |expected, computed| {
            // A gradient as large as 3.6 rounds in its own last digits: the tolerance grows with it.
            const tolerance: f32 = 1e-6 * @max(1.0, @abs(expected));
            try expectApproxEqAbs(expected, computed, tolerance);
        }
        gradient_start += graph_gradient.len;
    }
    try expectEqual(@as(usize, layout.params_floats), gradient_start);
}

test "gpu learn: the running scale on the kit is RunningScale's - three batches, the scale to the bit" {
    // BMPC's running scale moved by three batches of 10 divergences, on the kit's CPU twin (`running_scale_update`,
    // the scale persisting in acts from batch to batch) and by zimrnum's `RunningScale(f32)`: after each batch the
    // scale and its reciprocal, to the bit - the same order statistics (any correct sort), the same interpolation and
    // the same step (zimrmath's `quantileOfSorted` and `runningScaleStep`). The batches: one wide (its spread well
    // above 1), one narrow (its spread under 1, so the floor counts it as 1), one with repeated values.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const batch_size: usize = 10;
    const batches = [3][batch_size]f32{
        .{ 3.2, 0.1, 7.5, 1.9, 0.4, 5.6, 2.2, 0.8, 4.1, 6.3 },
        .{ 0.31, 0.29, 0.35, 0.3, 0.33, 0.28, 0.32, 0.34, 0.3, 0.31 },
        .{ 2.0, 2.0, 0.5, 2.0, 9.0, 0.5, 2.0, 2.0, 9.0, 2.0 },
    };
    const rate: f32 = 0.1;
    var layout: kit_mlp.KitLayout = .{};
    const values_offset: u32 = layout.reserveActs(@intCast(batch_size));
    const scratch_offset: u32 = layout.reserveActs(@intCast(batch_size));
    const scale_offset: u32 = layout.reserveActs(1);
    const inverse_scale_offset: u32 = layout.reserveActs(1);
    layout.requireFitsKit(zn_mlp);
    const acts: []f32 = try arena.alloc(f32, layout.acts_floats);
    @memset(acts, 0);
    // The scale starts at 1, as `RunningScale`'s does.
    acts[scale_offset] = 1;
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = layout.largestBuffer();
    pipe.upload(.acts, acts);
    var cpu_scale: zn.RunningScale(f32) = .{ .tau = rate };
    var cpu_scratch: [batch_size]f32 = undefined;
    for (batches) |batch| {
        pipe.uploadAt(.acts, values_offset, &batch);
        pipe.params = .{
            .count = @intCast(batch_size),
            .x_off = values_offset,
            .z_off = scratch_offset,
            .v_off = scale_offset,
            .e_off = inverse_scale_offset,
            .tau = rate,
        };
        pipe.run("running_scale_update", 1);
        try cpu_scale.update(&batch, &cpu_scratch);
        const kit_acts: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
        try expectEqual(cpu_scale.value, kit_acts[scale_offset]);
        try expectEqual(1 / cpu_scale.value, kit_acts[inverse_scale_offset]);
        // The batch's copy is sorted, and the batch itself left as it was.
        try expectEqualSlices(f32, &cpu_scratch, kit_acts[scratch_offset..][0..batch_size]);
        try expectEqualSlices(f32, &batch, kit_acts[values_offset..][0..batch_size]);
    }
    // The three batches moved it: 1 -> toward 6.x, then toward the floor's 1, then toward 8.5.
    try expect(cpu_scale.value > 1.5);
}

test "gpu learn: the policy's update on the kit is PolicyLearner's - the scale, the clip and Adam, over two updates" {
    // The fixture's policy learning on its world model's rolled latents, every dynamics head's stacked into one batch:
    // on zimrnum's graph as the CPU agent's `PolicyLearner.update` does it - the latents copied from the rollout's
    // values, the planner's targets for every head's copy of a stored step, the running scale moved by the first
    // step's divergences (`PolicyDistillationLoss.updateScale`), the backward, `clipGradNorm` and Adam with epsilon
    // 1e-5 - and on the kit's CPU twin by `robot_bmpc_kit.KitPolicyLearner.update`, the latents read in the rollout's
    // wide rows. The clip's limit is set low enough to engage. After each of two updates: the running scale, the
    // clip's norm, every gradient of the policy before the clip and every parameter after the step, to rounding (the
    // latents themselves differ in their last bits: the two world models computed them).
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var fixture: WorldModelFixture = undefined;
    try fixture.init(arena);
    defer fixture.deinit();
    const horizon: usize = WorldModelFixture.horizon;
    const window_count: usize = WorldModelFixture.window_count;
    const head_count: usize = WorldModelFixture.dynamics_head_count;
    const latent_width: usize = WorldModelFixture.latent_width;
    const action_width: usize = WorldModelFixture.action_width;
    const stacked_windows: usize = head_count * window_count;
    const options: WorldModelFixture.KitPolicyLearner.Options = .{ .gradient_clip = 0.05 };
    // -- The CPU agent's policy update, on a graph of its own.
    var graph: zn.Graph(f32) = .init(arena);
    const policy_bound: []zn.Var = try fixture.policy.bind(&graph, .trained, arena);
    // The latents, step-major, each step a block of window_count rows per head (`PolicyLearner.update`'s layout).
    const latents: zn.Tensor(f32) = try .alloc(arena, &.{ horizon * stacked_windows, latent_width });
    for (0..horizon) |step| {
        for (0..head_count) |head_index| {
            const rolled: []const f32 = fixture.graph.valueOf(fixture.rollout.rolled[head_index][step]).data;
            const block_index: usize = step * head_count + head_index;
            @memcpy(latents.data[block_index * window_count * latent_width ..][0..rolled.len], rolled);
        }
    }
    const unfinished: []zn.Tensor(f32) = try arena.alloc(zn.Tensor(f32), horizon);
    for (unfinished) |*column| {
        column.* = try zn.ones(f32, arena, &.{ stacked_windows, 1 });
    }
    const loss: zrl.PolicyDistillationLoss(f32) = try .build(
        &graph,
        try graph.constant(latents),
        unfinished,
        fixture.policy,
        policy_bound,
        .{
            .horizon = horizon,
            .batch = stacked_windows,
            .rho = options.rho,
            .entropy_coefficient = options.entropy_coefficient,
            .log_std_low = options.log_std_low,
            .log_std_high = options.log_std_high,
        },
        arena,
    );
    // The planner's targets, the same for every head's copy of a stored step.
    for (0..horizon) |step| {
        for (0..head_count) |head_index| {
            for (0..window_count) |window| {
                const stored_row: usize = step * window_count + window;
                const loss_row: usize = (step * head_count + head_index) * window_count + window;
                const stored_means: []const f32 = fixture.planner_means[stored_row * action_width ..][0..action_width];
                const stored_log_stds: []const f32 =
                    fixture.planner_log_stds[stored_row * action_width ..][0..action_width];
                @memcpy(loss.target_means.data[loss_row * action_width ..][0..action_width], stored_means);
                @memcpy(loss.target_log_stds.data[loss_row * action_width ..][0..action_width], stored_log_stds);
            }
        }
    }
    var kl_scale: zn.RunningScale(f32) = .{ .tau = options.scale_rate };
    const scale_scratch: []f32 = try arena.alloc(f32, stacked_windows);
    var optimizer: zn.Optimizer(f32) = try .init(arena, &graph, policy_bound, .{
        .adam = .{ .rate = options.learning_rate, .epsilon = options.epsilon },
    });
    // -- The kit's world model forward fills the wide rows the policy reads.
    fixture.world_model.forward(&fixture.pipe);
    // The kit's learner with the same options as the CPU side's - the fixture built it with BMPC's.
    var learner: WorldModelFixture.KitPolicyLearner = fixture.policy_learner;
    learner.options = options;
    for (1..3) |step| {
        try graph.recompute();
        try loss.updateScale(&graph, &kl_scale, scale_scratch);
        try graph.recompute();
        try graph.backward(loss.total);
        // The gradients before the clip scales them in place.
        var cpu_gradients: ArrayList(f32) = .empty;
        for (policy_bound) |parameter| {
            try cpu_gradients.appendSlice(arena, (try graph.gradOf(parameter)).data);
        }
        const cpu_norm: f32 = try zn.clipGradNorm(f32, &graph, policy_bound, options.gradient_clip);
        try optimizer.step(&graph);
        learner.update(&fixture.pipe, @intCast(step));
        const kit_acts: []const f32 = fixture.pipe.readLatest(.acts) orelse return error.NoReadback;
        const kit_params: []const f32 = fixture.pipe.readLatest(.params) orelse return error.NoReadback;
        const kit_grads: []const f32 = fixture.pipe.readLatest(.grads) orelse return error.NoReadback;
        try expectApproxEqRel(kl_scale.value, kit_acts[learner.scale_offset], 1e-5);
        // The gradients, before the clip (the kit applies its factor inside Adam, so its grads are unclipped).
        var largest_gradient: f32 = 0;
        for (cpu_gradients.items) |gradient| {
            largest_gradient = @max(largest_gradient, @abs(gradient));
        }
        const policy_start: usize = learner.network.paramsStart();
        const kit_policy_gradients: []const f32 = kit_grads[policy_start..][0..cpu_gradients.items.len];
        for (cpu_gradients.items, kit_policy_gradients) |expected, computed| {
            try expectApproxEqAbs(expected, computed, 1e-5 * largest_gradient);
        }
        const kit_norm: f32 = kit_acts[learner.clip_norm_offset];
        try expect(cpu_norm > options.gradient_clip);
        try expectApproxEqRel(cpu_norm, kit_norm, 1e-4);
        var params_start: usize = learner.network.paramsStart();
        for (policy_bound) |parameter| {
            const cpu_values: []const f32 = graph.valueOf(parameter).data;
            for (cpu_values, kit_params[params_start..][0..cpu_values.len]) |expected, computed| {
                try expectApproxEqAbs(expected, computed, 2e-7);
            }
            params_start += cpu_values.len;
        }
        try expectEqual(@as(usize, learner.network.paramsEnd()), params_start);
    }
}

test "gpu learn: the value targets on the kit are LatentValueTargets' - every stored step's, through every head" {
    // The fixture's world model, one step of lookahead: at every stored step's true latent the policy draws an action
    // (the same noise on both sides), the reward head says what it earns, each of the 2 dynamics heads where it
    // leads, and each of the 2 target value heads what that is worth - R + gamma / heads x sum over heads of the
    // target heads' mean. On zimrnum's graph as zimrrl's `LatentValueTargets` computes it, and on the kit's CPU twin
    // by `robot_bmpc_kit.KitValueTargets`, into the world model's value targets: every stored step's, to rounding.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var fixture: WorldModelFixture = undefined;
    try fixture.init(arena);
    defer fixture.deinit();
    const horizon: usize = WorldModelFixture.horizon;
    const window_count: usize = WorldModelFixture.window_count;
    const observation_width: usize = WorldModelFixture.observation_width;
    const stored_rows: usize = horizon * window_count;
    // -- zimrrl's LatentValueTargets, over frozen handles of the same networks.
    var graph: zn.Graph(f32) = .init(arena);
    const encoder_bound: []zn.Var = try fixture.encoder.bind(&graph, .frozen, arena);
    const policy_bound: []zn.Var = try fixture.policy.bind(&graph, .frozen, arena);
    var dynamics_bounds: [WorldModelFixture.dynamics_head_count][]const zn.Var = undefined;
    for (&dynamics_bounds, fixture.dynamics) |*bound, head| {
        bound.* = try head.bind(&graph, .frozen, arena);
    }
    const reward_bound: []zn.Var = try fixture.reward_head.bind(&graph, .frozen, arena);
    var target_bounds: [WorldModelFixture.value_head_count][]const zn.Var = undefined;
    for (&target_bounds, fixture.target_value_heads) |*bound, target_head| {
        bound.* = try target_head.bind(&graph, .frozen, arena);
    }
    const targets_builder: zrl.LatentValueTargets(f32) = try .build(
        &graph,
        fixture.encoder,
        encoder_bound,
        fixture.policy,
        policy_bound,
        &fixture.dynamics,
        &dynamics_bounds,
        fixture.reward_head,
        reward_bound,
        &fixture.target_value_heads,
        &target_bounds,
        .{ .rows = stored_rows, .discount = WorldModelFixture.discount },
        arena,
    );
    // The stored steps' observations: the window's o_0 .. o_(H-1), step-major - its first H blocks.
    const stored_observations: []const f32 = fixture.observations[0 .. stored_rows * observation_width];
    @memcpy(targets_builder.observations.data, stored_observations);
    const cpu_targets: []f32 = try arena.alloc(f32, stored_rows);
    const noise_rng: zn.Rng = .init(WorldModelFixture.target_noise_seed);
    try targets_builder.compute(&graph, noise_rng, cpu_targets);
    // -- The kit's: the rollout's forward encodes the window, then the targets.
    fixture.world_model.rollout.forward(&fixture.pipe);
    fixture.target_builder.compute(&fixture.pipe);
    const kit_acts: []const f32 = fixture.pipe.readLatest(.acts) orelse return error.NoReadback;
    const kit_targets: []const f32 = kit_acts[fixture.world_model.value_targets_offset..][0..stored_rows];
    // To rounding, and ABSOLUTE rounding: a decoded value is a sum over 101 bins of probability x bin position, the
    // positions reaching +-10 on the axis, so its rounding is the size of those terms - not of the result, which for
    // untrained heads sits near zero.
    for (cpu_targets, kit_targets) |expected, computed| {
        try expectApproxEqAbs(expected, computed, 2e-6);
    }
    // The region held the fixture's uploaded targets (12 + 5 cos, for the loss's tests); the kit wrote over it.
    try expect(@abs(kit_targets[0] - fixture.value_targets[0]) > 1);
}

test "gpu learn: the kit's descriptors stay small enough to pass by value" {
    // `kit_mlp`'s head: a network, an application and the learners built of them are passed and stored by value -
    // made once, never changed, every copy describing the same regions. That stays cheap only while they stay small:
    // a few hundred bytes, against a dispatch's microseconds. A descriptor that grew past this - by holding an array
    // of numbers instead of a slice into the arena, say - should be passed by pointer instead, or slimmed.
    const largest_descriptor_bytes: usize = 512;
    const descriptor_sizes = [_]usize{
        @sizeOf(kit_mlp.KitNetwork(zn_mlp)),
        @sizeOf(kit_mlp.KitNetwork(zn_mlp).Application),
        @sizeOf(bmpc_kit.KitRollout(zn_mlp)),
        @sizeOf(bmpc_kit.KitWorldModel(zn_mlp)),
        @sizeOf(bmpc_kit.KitValueTargets(zn_mlp)),
        @sizeOf(bmpc_kit.KitPolicyLearner(zn_mlp)),
    };
    for (descriptor_sizes) |descriptor_size| {
        try expect(descriptor_size <= largest_descriptor_bytes);
    }
}

test "gpu learn: the world model's loss with finished windows on the kit is WorldModelLoss's" {
    // The fixture's window, two of its four windows running past their episodes' ends: window 1 finished from step 1
    // on, window 3 from step 2. A finished window still rolls forward, but counts for nothing in the loss from then
    // on: its consistency rows drop out of the step's mean, which becomes the mean over the windows still counting;
    // its reward and value target rows are all zeros, costing nothing. On zimrnum's graph by
    // `LatentRollout.setFinished`, on the kit by `KitRollout.writeFinished`'s counting column and mean factors.
    // The total and every trained parameter's gradient, to rounding.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var fixture: WorldModelFixture = undefined;
    try fixture.init(arena);
    defer fixture.deinit();
    const horizon: usize = WorldModelFixture.horizon;
    const window_count: usize = WorldModelFixture.window_count;
    const latent_width: usize = WorldModelFixture.latent_width;
    // Step-major: step 0 none, step 1 window 1, step 2 windows 1 and 3.
    const finished = [_]f32{ 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1 };
    // -- zimrnum's graph.
    try fixture.rollout.setFinished(&finished);
    try fixture.graph.recompute();
    try fixture.graph.backward(fixture.loss.total);
    const graph_total: f32 = fixture.graph.valueOf(fixture.loss.total).data[0];
    // -- The kit: the flags written into a host copy of acts, their two regions uploaded.
    const world_model: WorldModelFixture.KitWorldModel = fixture.world_model;
    const rollout: WorldModelFixture.KitRollout = world_model.rollout;
    const host_acts: []f32 = try arena.alloc(f32, fixture.layout.acts_floats);
    rollout.writeFinished(host_acts, &finished);
    const counting_floats: usize = horizon * window_count;
    fixture.pipe.uploadAt(.acts, rollout.counting_offset, host_acts[rollout.counting_offset..][0..counting_floats]);
    fixture.pipe.uploadAt(.acts, rollout.mean_factors_offset, host_acts[rollout.mean_factors_offset..][0..horizon]);
    world_model.forward(&fixture.pipe);
    world_model.rowLosses(&fixture.pipe);
    world_model.backward(&fixture.pipe);
    const kit_acts: []const f32 = fixture.pipe.readLatest(.acts) orelse return error.NoReadback;
    const kit_grads: []const f32 = fixture.pipe.readLatest(.grads) orelse return error.NoReadback;
    // The total from the kit's numbers: each step's consistency the mean over its counting windows; the finished
    // rows' cross-entropies read back as 0, the means still over the whole batch.
    var consistency_sum: f64 = 0;
    var reward_sum: f64 = 0;
    var value_sum: f64 = 0;
    for (rollout.dynamics_heads, 0..) |head, head_index| {
        var step_weight: f64 = 1;
        for (head.step_applications, 0..) |step, step_index| {
            const predicted: []const f32 = kit_acts[step.outputsOffset()..][0 .. window_count * latent_width];
            const target_start: u32 = rollout.encodedLatentsOffset(@intCast(step_index + 1));
            const target: []const f32 = kit_acts[target_start..][0 .. window_count * latent_width];
            const counting: []const f32 = kit_acts[rollout.countingAt(step_index)..][0..window_count];
            var squared_error_sum: f64 = 0;
            for (0..window_count) |window| {
                for (0..latent_width) |column| {
                    const value_index: usize = window * latent_width + column;
                    const difference: f64 = predicted[value_index] - target[value_index];
                    squared_error_sum += counting[window] * difference * difference;
                }
            }
            const mean_factor: f64 = kit_acts[rollout.meanFactorAt(step_index)];
            const whole_batch_mean: f64 = squared_error_sum / float64(predicted.len);
            consistency_sum += step_weight / float64(horizon) * whole_batch_mean * mean_factor;
            const HeadApplication: type = WorldModelFixture.KitWorldModel.HeadApplication;
            const head_rewards: []const HeadApplication = world_model.reward_applications[head_index];
            const reward_losses_offset: u32 = head_rewards[step_index].row_losses_offset;
            for (kit_acts[reward_losses_offset..][0..window_count], counting) |row_loss, window_counting| {
                if (window_counting == 0) {
                    try expectEqual(@as(f32, 0), row_loss);
                }
                reward_sum += step_weight / float64(horizon) * row_loss / float64(window_count);
            }
            for (world_model.value_applications[head_index][step_index]) |value_at_step| {
                for (kit_acts[value_at_step.row_losses_offset..][0..window_count]) |row_loss| {
                    const value_heads: f64 = float64(WorldModelFixture.value_head_count);
                    const value_share: f64 = step_weight / (float64(horizon) * value_heads);
                    value_sum += value_share * row_loss / float64(window_count);
                }
            }
            step_weight *= WorldModelFixture.rho;
        }
    }
    const heads_divisor: f64 = float64(WorldModelFixture.dynamics_head_count);
    const kit_total: f64 = 20 * consistency_sum / heads_divisor + 0.1 * reward_sum / heads_divisor +
        0.1 * value_sum / heads_divisor;
    try expectApproxEqAbs(graph_total, @as(f32, @floatCast(kit_total)), 1e-5);
    var gradient_start: usize = 0;
    for (try fixture.trainedBounds(arena)) |bound| {
        for (bound) |parameter| {
            const graph_gradient: []const f32 = (try fixture.graph.gradOf(parameter)).data;
            for (graph_gradient, kit_grads[gradient_start..][0..graph_gradient.len]) |expected, computed| {
                try expectApproxEqAbs(expected, computed, 1e-6);
            }
            gradient_start += graph_gradient.len;
        }
    }
    // The flags changed the loss: the step factors are 4/3 and 2, the finished rows' terms gone.
    try expectEqual(@as(f32, 2), kit_acts[rollout.meanFactorAt(2)]);
}

test "gpu learn: the value heads' dropout on the kit is WorldModelLoss's - the same masks, every gradient" {
    // The fixture's world model with its value heads dropping out (25% of their first layer's units, for the test):
    // on zimrnum's graph a second `WorldModelLoss` on the same rollout, handed a generator - each value head at each
    // step and dynamics head its own split of it, the mask drawn as the loss is built; on the kit the same masks,
    // drawn from the same generator split the same way (`KitWorldModel.writeValueDropoutMasks`). Every trained
    // parameter's gradient, to rounding - and the dropout changed the loss.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var fixture: WorldModelFixture = undefined;
    try fixture.init(arena);
    defer fixture.deinit();
    const scalar: zn.CategoricalScalar(f32) = .{};
    const dropout_rng: zn.Rng = .init(171);
    // -- zimrnum's graph: the loss again, with dropout.
    const dropout_loss: zrl.WorldModelLoss(f32) = try .build(
        fixture.graph,
        fixture.rollout,
        fixture.action_values,
        fixture.reward_head,
        fixture.reward_bound,
        &fixture.value_heads,
        &fixture.value_bounds,
        dropout_rng,
        .{
            .horizon = WorldModelFixture.horizon,
            .batch = WorldModelFixture.window_count,
            .bins = scalar.bin_count,
            .rho = WorldModelFixture.rho,
        },
        arena,
    );
    const window_count: usize = WorldModelFixture.window_count;
    for (0..WorldModelFixture.horizon) |step| {
        const step_rewards: []const f32 = fixture.rewards[step * window_count ..][0..window_count];
        const step_values: []const f32 = fixture.value_targets[step * window_count ..][0..window_count];
        try scalar.encodeRows(step_rewards, dropout_loss.reward_targets[step]);
        try scalar.encodeRows(step_values, dropout_loss.value_targets[step]);
    }
    try fixture.graph.recompute();
    try fixture.graph.backward(dropout_loss.total);
    const dropped_total: f32 = fixture.graph.valueOf(dropout_loss.total).data[0];
    const kept_total: f32 = fixture.graph.valueOf(fixture.loss.total).data[0];
    // -- The kit: the same masks, the whole of acts uploaded again with them.
    const world_model: WorldModelFixture.KitWorldModel = fixture.world_model;
    try world_model.writeValueDropoutMasks(fixture.host_acts, dropout_rng);
    fixture.pipe.upload(.acts, fixture.host_acts);
    world_model.forward(&fixture.pipe);
    world_model.backward(&fixture.pipe);
    const kit_grads: []const f32 = fixture.pipe.readLatest(.grads) orelse return error.NoReadback;
    var gradient_start: usize = 0;
    for (try fixture.trainedBounds(arena)) |bound| {
        for (bound) |parameter| {
            const graph_gradient: []const f32 = (try fixture.graph.gradOf(parameter)).data;
            for (graph_gradient, kit_grads[gradient_start..][0..graph_gradient.len]) |expected, computed| {
                try expectApproxEqAbs(expected, computed, 1e-6);
            }
            gradient_start += graph_gradient.len;
        }
    }
    // The masks dropped something: the loss with them is not the loss without.
    try expect(@abs(dropped_total - kept_total) > 1e-4);
}

test "gpu learn: one whole world-model update on the kit is the CPU agent's - sampled, finished, dropping out" {
    // The CPU agent's own `WorldModelLearner` (f32): a replay of two episodes, the first ending inside the sampled
    // windows; one `sample`, one `learn` - its value targets from the target heads at the policy's draw, the finished
    // windows masked, its value heads dropping out, the loss's backward, one clip, two Adams, the targets' follow.
    // The kit's `KitWorldModel` and `KitValueTargets` on the same batch - the windows as `loadWindows` lays them out,
    // the flags, the targets' noise and every dropout mask from the same generator as the CPU learner's. Every
    // parameter of every network after the update, target heads included, to rounding; and the value targets of
    // every row that counts.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const Tdmpc: type = bmpc.Bmpc(f32);
    const KitNetwork: type = kit_mlp.KitNetwork(zn_mlp);
    const observation_width: usize = 6;
    const action_width: usize = 3;
    const horizon: usize = 3;
    const window_count: usize = 4;
    var config: Tdmpc.Config = .{
        .latent_width = 16,
        .hidden_width = 16,
        .encoder_hidden_width = 16,
        .simnorm_group = 8,
        .horizon = horizon,
        .discount = 0.95,
        .windows = window_count,
        .dynamics_heads = 2,
        .value_heads = 2,
    };
    // A dropout this small window can see (BMPC's 1% might drop no unit at all here).
    config.value_dropout = 0.25;
    const networks: Tdmpc.Networks = try .init(arena, zn.Rng.init(201), observation_width, action_width, config);
    var learner: Tdmpc.WorldModelLearner = try .init(arena, networks, observation_width, action_width, config);
    // -- A replay: one character, four short episodes each cut at its last step - so a window of three steps
    //    nearly always runs past an episode's end.
    const row_layout: Tdmpc.Row = .{ .observation_width = observation_width, .action_width = action_width };
    var replay: zrl.SequenceReplay(f32) = try .init(arena, 1, 32, row_layout.width(), row_layout.doneColumn());
    const episode_lengths = [_]usize{ 2, 3, 2, 4 };
    var global_step: usize = 0;
    for (episode_lengths) |episode_length| {
        for (0..episode_length) |step| {
            var observation: [observation_width]f32 = undefined;
            var next_observation: [observation_width]f32 = undefined;
            for (&observation, &next_observation, 0..) |*value, *next_value, column| {
                value.* = 0.6 * @sin(0.37 * float(global_step) + float(column));
                next_value.* = 0.6 * @sin(0.37 * float(global_step + 1) + float(column));
            }
            var action: [action_width]f32 = undefined;
            for (&action, 0..) |*value, column| {
                value.* = 0.7 * @cos(0.53 * float(global_step) + float(column));
            }
            const is_last_step: bool = step + 1 == episode_length;
            const stored_step: Tdmpc.Step = .{
                .observation = &observation,
                .action = &action,
                .reward = 0.4 + 0.2 * @sin(float(global_step)),
                .next_observation = &next_observation,
                .terminated = false,
                .truncated = is_last_step,
                .target = null,
            };
            const row: []f32 = try arena.alloc(f32, row_layout.width());
            try row_layout.fill(row, stored_step);
            try replay.push(row, &.{true});
            global_step += 1;
        }
    }
    const update_rng: zn.Rng = .init(211);
    try learner.sample(&replay, update_rng, 0);
    const finished: []const f32 = try arena.dupe(f32, learner.finished);
    var finished_count: usize = 0;
    for (finished) |flag| {
        const is_finished: bool = flag == 1;
        finished_count += @intFromBool(is_finished);
    }
    // -- The kit: every network, placed in the world model's order, the policy after.
    var layout: kit_mlp.KitLayout = .{};
    const kit_encoder: KitNetwork = try .init(arena, &layout, networks.encoder);
    const kit_dynamics: []KitNetwork = try arena.alloc(KitNetwork, networks.dynamics.len);
    for (kit_dynamics, networks.dynamics) |*kit_head, head| {
        kit_head.* = try KitNetwork.init(arena, &layout, head);
    }
    const kit_reward: KitNetwork = try .init(arena, &layout, networks.reward);
    const kit_values: []KitNetwork = try arena.alloc(KitNetwork, networks.values.len);
    for (kit_values, networks.values) |*kit_value, value_head| {
        kit_value.* = try KitNetwork.init(arena, &layout, value_head);
    }
    const kit_targets: []KitNetwork = try arena.alloc(KitNetwork, networks.target_values.len);
    for (kit_targets, networks.target_values) |*kit_target, target_head| {
        kit_target.* = try KitNetwork.init(arena, &layout, target_head);
    }
    const kit_policy: KitNetwork = try .init(arena, &layout, networks.policy);
    const kit_rollout: bmpc_kit.KitRollout(zn_mlp) = try .init(arena, &layout, kit_encoder, kit_dynamics, .{
        .horizon = horizon,
        .window_count = window_count,
        .observation_width = observation_width,
        .action_width = action_width,
        .rho = config.rho,
    });
    const world_model: bmpc_kit.KitWorldModel(zn_mlp) = try .init(
        arena,
        &layout,
        kit_rollout,
        kit_reward,
        kit_values,
        kit_targets,
        .{ .value_dropout = .on },
    );
    const target_builder: bmpc_kit.KitValueTargets(zn_mlp) = try .init(
        arena,
        &layout,
        kit_rollout,
        kit_policy,
        kit_reward,
        kit_targets,
        world_model.value_targets_offset,
        .{
            .discount = config.discount,
            .log_std_low = config.spread.log_std_low,
            .log_std_high = config.spread.log_std_high,
        },
    );
    layout.requireFitsKit(zn_mlp);
    const params: []f32 = try arena.alloc(f32, layout.params_floats);
    const networks_in_order = [_]struct { kit: KitNetwork, mlp: zn.Mlp(f32) }{
        .{ .kit = kit_encoder, .mlp = networks.encoder },
        .{ .kit = kit_dynamics[0], .mlp = networks.dynamics[0] },
        .{ .kit = kit_dynamics[1], .mlp = networks.dynamics[1] },
        .{ .kit = kit_reward, .mlp = networks.reward },
        .{ .kit = kit_values[0], .mlp = networks.values[0] },
        .{ .kit = kit_values[1], .mlp = networks.values[1] },
        .{ .kit = kit_targets[0], .mlp = networks.target_values[0] },
        .{ .kit = kit_targets[1], .mlp = networks.target_values[1] },
        .{ .kit = kit_policy, .mlp = networks.policy },
    };
    for (networks_in_order) |pair| {
        pair.kit.writeParams(pair.mlp, params);
    }
    // The batch, as `loadWindows` lays it out: block 0 the windows' first observations, block t + 1 what followed
    // step t; each step's actions and rewards.
    const row_width: usize = row_layout.width();
    const observations: []f32 = try arena.alloc(f32, (horizon + 1) * window_count * observation_width);
    const actions: []f32 = try arena.alloc(f32, horizon * window_count * action_width);
    const rewards: []f32 = try arena.alloc(f32, horizon * window_count);
    for (0..horizon) |step| {
        for (0..window_count) |window| {
            const stored_index: usize = step * window_count + window;
            const stored: []const f32 = learner.window_rows[stored_index * row_width ..][0..row_width];
            if (step == 0) {
                const first_observation: []const f32 = stored[0..observation_width];
                @memcpy(observations[window * observation_width ..][0..observation_width], first_observation);
            }
            const successor_row: usize = (step + 1) * window_count + window;
            const next_start: usize = row_layout.nextObservationStart();
            const next_observation: []const f32 = stored[next_start..][0..observation_width];
            @memcpy(observations[successor_row * observation_width ..][0..observation_width], next_observation);
            const action: []const f32 = stored[row_layout.actionStart()..][0..action_width];
            @memcpy(actions[stored_index * action_width ..][0..action_width], action);
            rewards[stored_index] = stored[row_layout.rewardColumn()];
        }
    }
    // The targets' noise, as the CPU learner draws it: its `learn` generator split 1, each stored row's own stream.
    const target_rng: zn.Rng = update_rng.split(1);
    const target_noise: []f32 = try arena.alloc(f32, horizon * window_count * action_width);
    for (0..horizon * window_count) |stored_row| {
        const row_rng: zn.Rng = target_rng.split(@intCast(stored_row));
        for (0..action_width) |dimension| {
            target_noise[stored_row * action_width + dimension] = row_rng.normal(f32, @intCast(dimension));
        }
    }
    // The dropout masks, as the CPU learner draws them: split 2, then each dropout node's index in its graph - the
    // nodes in the order the loss built them, which is the kit's order of value applications.
    var dropout_rngs: ArrayList(zn.Rng) = .empty;
    for (learner.graph.nodes.items, 0..) |node, node_index| {
        if (node.op == .dropout_op) {
            try dropout_rngs.append(arena, update_rng.split(2).split(@intCast(node_index)));
        }
    }
    const acts: []f32 = try arena.alloc(f32, layout.acts_floats);
    @memset(acts, 0);
    kit_rollout.writeWindow(acts, observations, actions);
    kit_rollout.writeFinished(acts, finished);
    world_model.writeTargets(acts, rewards, rewards);
    target_builder.writeNoise(acts, target_noise);
    try world_model.writeValueDropoutMasksFrom(acts, dropout_rngs.items);
    const zero_moments: []f32 = try arena.alloc(f32, layout.params_floats);
    @memset(zero_moments, 0);
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = layout.largestBuffer();
    pipe.upload(.params, params);
    pipe.upload(.adam_m, zero_moments);
    pipe.upload(.adam_v, zero_moments);
    pipe.upload(.acts, acts);
    // -- Both updates.
    _ = try learner.learn(update_rng);
    world_model.forward(&pipe);
    target_builder.compute(&pipe);
    world_model.backward(&pipe);
    world_model.update(&pipe, .{
        .learning_rate = config.learning_rate,
        .encoder_rate_scale = config.encoder_rate_scale,
        .gradient_clip = config.gradient_clip,
        .target_follow = config.target_follow,
    }, 1);
    const kit_acts: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
    const kit_params: []const f32 = pipe.readLatest(.params) orelse return error.NoReadback;
    // The value targets of every row that counts (a finished row's starts in another episode, and is masked).
    const kit_value_targets: []const f32 = kit_acts[world_model.value_targets_offset..][0 .. horizon * window_count];
    for (learner.value_target_values, kit_value_targets, finished) |expected, computed, flag| {
        if (flag == 0) {
            try expectApproxEqAbs(expected, computed, 2e-6);
        }
    }
    // Every parameter after the update, the policy's untouched.
    var params_start: usize = 0;
    for (networks_in_order) |pair| {
        for ((try pair.mlp.params(arena)).tensors) |tensor| {
            for (tensor.data, kit_params[params_start..][0..tensor.data.len]) |expected, computed| {
                try expectApproxEqAbs(expected, computed, 3e-7);
            }
            params_start += tensor.data.len;
        }
    }
    try expectEqual(@as(usize, layout.params_floats), params_start);
    // The batch did cross an episode's end, and the dropout did drop.
    try expect(finished_count > 0);
    try expect(dropout_rngs.items.len == horizon * networks.dynamics.len * networks.values.len);
}

test "gpu learn: the planner's scores on the kit are LatentPlanScorer's - both objectives, pessimistic" {
    // The fixture's world model scoring 6 candidate plans of 3 actions for each of 2 states, every candidate rolled
    // under both dynamics heads and read by both value heads: on zimrnum's graph by zimrrl's `LatentPlanScorer`, on
    // the kit's CPU twin by `robot_bmpc_kit.KitPlanScorer` - for the discounted sum and for the mean over the plan's
    // prefixes, each with a pessimism of 0.7 so the variance counts too. Every candidate's score and variance, to
    // rounding.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var fixture: WorldModelFixture = undefined;
    try fixture.init(arena);
    defer fixture.deinit();
    const KitNetwork: type = kit_mlp.KitNetwork(zn_mlp);
    const horizon: u32 = 3;
    const state_count: u32 = 2;
    const candidate_count: u32 = 6;
    const observation_width: u32 = WorldModelFixture.observation_width;
    const action_width: u32 = WorldModelFixture.action_width;
    const row_count: usize = state_count * candidate_count;
    const observations: []f32 = try arena.alloc(f32, state_count * observation_width);
    for (observations, 0..) |*value, index| {
        value.* = 0.8 * @sin(0.61 * float(index) + 0.2);
    }
    const actions: []f32 = try arena.alloc(f32, horizon * row_count * action_width);
    for (actions, 0..) |*value, index| {
        value.* = 0.9 * @sin(1.27 * float(index) + 0.5);
    }
    const objectives = [_]zrl.PlanObjective{ .final, .mean_over_depths };
    for (objectives) |objective| {
        // -- zimrrl's scorer, over frozen handles of the fixture's networks.
        var graph: zn.Graph(f32) = .init(arena);
        const encoder_bound: []zn.Var = try fixture.encoder.bind(&graph, .frozen, arena);
        var dynamics_bounds: [WorldModelFixture.dynamics_head_count][]const zn.Var = undefined;
        for (&dynamics_bounds, fixture.dynamics) |*bound, head| {
            bound.* = try head.bind(&graph, .frozen, arena);
        }
        const reward_bound: []zn.Var = try fixture.reward_head.bind(&graph, .frozen, arena);
        var value_bounds: [WorldModelFixture.value_head_count][]const zn.Var = undefined;
        for (&value_bounds, fixture.value_heads) |*bound, value_head| {
            bound.* = try value_head.bind(&graph, .frozen, arena);
        }
        const pessimism: f32 = 0.7;
        const scorer: zrl.LatentPlanScorer(f32) = try .build(
            &graph,
            fixture.encoder,
            encoder_bound,
            &fixture.dynamics,
            &dynamics_bounds,
            fixture.reward_head,
            reward_bound,
            &fixture.value_heads,
            &value_bounds,
            observation_width,
            action_width,
            .{
                .horizon = horizon,
                .states = state_count,
                .candidates = candidate_count,
                .discount = WorldModelFixture.discount,
                .objective = objective,
                .pessimism = pessimism,
            },
            arena,
        );
        @memcpy(scorer.observations.data, observations);
        for (scorer.actions, 0..) |step_actions, step| {
            @memcpy(step_actions.data, actions[step * row_count * action_width ..][0 .. row_count * action_width]);
        }
        const cpu_scores: []f32 = try arena.alloc(f32, row_count);
        try scorer.score(&graph, cpu_scores);
        // -- The kit's.
        var layout: kit_mlp.KitLayout = .{};
        const kit_encoder: KitNetwork = try .init(arena, &layout, fixture.encoder);
        var kit_dynamics: [WorldModelFixture.dynamics_head_count]KitNetwork = undefined;
        for (&kit_dynamics, fixture.dynamics) |*kit_head, head| {
            kit_head.* = try KitNetwork.init(arena, &layout, head);
        }
        const kit_reward: KitNetwork = try .init(arena, &layout, fixture.reward_head);
        var kit_values: [WorldModelFixture.value_head_count]KitNetwork = undefined;
        for (&kit_values, fixture.value_heads) |*kit_value, value_head| {
            kit_value.* = try KitNetwork.init(arena, &layout, value_head);
        }
        const kit_scorer: bmpc_kit.KitPlanScorer(zn_mlp) = try .init(
            arena,
            &layout,
            kit_encoder,
            &kit_dynamics,
            kit_reward,
            &kit_values,
            observation_width,
            action_width,
            .{
                .horizon = horizon,
                .states = state_count,
                .candidates = candidate_count,
                .discount = WorldModelFixture.discount,
                .objective = objective,
                .pessimism = pessimism,
            },
        );
        layout.requireFitsKit(zn_mlp);
        const params: []f32 = try arena.alloc(f32, layout.params_floats);
        kit_encoder.writeParams(fixture.encoder, params);
        for (kit_dynamics, fixture.dynamics) |kit_head, head| {
            kit_head.writeParams(head, params);
        }
        kit_reward.writeParams(fixture.reward_head, params);
        for (kit_values, fixture.value_heads) |kit_value, value_head| {
            kit_value.writeParams(value_head, params);
        }
        const acts: []f32 = try arena.alloc(f32, layout.acts_floats);
        @memset(acts, 0);
        @memcpy(acts[kit_scorer.observations_offset..][0..observations.len], observations);
        @memcpy(acts[kit_scorer.actions_offset..][0..actions.len], actions);
        kit_scorer.writeWeights(acts);
        var pipe: compute_host.Compute(zn_mlp) = .initCpu();
        defer pipe.deinit();
        pipe.element_count = layout.largestBuffer();
        pipe.upload(.params, params);
        pipe.upload(.acts, acts);
        kit_scorer.score(&pipe);
        const kit_acts: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
        const kit_scores: []const f32 = kit_acts[kit_scorer.scores_offset..][0..row_count];
        const kit_variances: []const f32 = kit_acts[kit_scorer.variances_offset..][0..row_count];
        // To ABSOLUTE rounding: a decoded value is a sum over 101 bins of probability x position, positions to +-10.
        for (cpu_scores, kit_scores) |expected, computed| {
            try expectApproxEqAbs(expected, computed, 2e-6);
        }
        // A variance is a sum of squared deviations of estimates that each carry that rounding: its own rounding is
        // relative to it - a ten-thousandth, or 1e-8 for a variance near zero.
        for (scorer.score_variances, kit_variances) |expected, computed| {
            const variance_tolerance: f32 = @max(1e-8, 1e-4 * @abs(expected));
            try expectApproxEqAbs(expected, computed, variance_tolerance);
        }
        // The candidates differ, so the ranking means something.
        try expect(@abs(cpu_scores[0] - cpu_scores[1]) > 1e-4);
    }
}

test "gpu learn: the policy's plans on the kit are LatentPolicyPlans' - drawn, rolled, placed among the candidates" {
    // The fixture's policy proposing 3 plans of 3 actions for each of 2 states, rolled through the first dynamics
    // head, with reanalyze's wider spread (log s in [-2, 1]): on zimrnum's graph by zimrrl's `LatentPolicyPlans`, on
    // the kit's CPU twin by `robot_bmpc_kit.KitPolicyPlans` with the same noise (each (state, plan, step, dimension)'s
    // counter-based draw). Each state's plans are the first 3 of its 6 candidates; every action of every step, to
    // rounding - and every other candidate row left as it was.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var fixture: WorldModelFixture = undefined;
    try fixture.init(arena);
    defer fixture.deinit();
    const KitNetwork: type = kit_mlp.KitNetwork(zn_mlp);
    const horizon: u32 = 3;
    const state_count: u32 = 2;
    const candidate_count: u32 = 6;
    const plan_count: u32 = 3;
    const observation_width: u32 = WorldModelFixture.observation_width;
    const action_width: u32 = WorldModelFixture.action_width;
    const candidate_rows: usize = state_count * candidate_count;
    const plan_rows: usize = state_count * plan_count;
    const spread: zrl.TanhMeanGaussian(f32).Options = .{ .log_std_low = -2, .log_std_high = 1 };
    const observations: []f32 = try arena.alloc(f32, state_count * observation_width);
    for (observations, 0..) |*value, index| {
        value.* = 0.8 * @sin(0.61 * float(index) + 0.2);
    }
    const plans_rng: zn.Rng = .init(221);
    // -- zimrrl's plans, over frozen handles of the fixture's networks.
    var graph: zn.Graph(f32) = .init(arena);
    const plans: zrl.LatentPolicyPlans(f32) = try .build(
        &graph,
        fixture.encoder,
        try fixture.encoder.bind(&graph, .frozen, arena),
        fixture.dynamics[0],
        try fixture.dynamics[0].bind(&graph, .frozen, arena),
        fixture.policy,
        try fixture.policy.bind(&graph, .frozen, arena),
        .{
            .horizon = horizon,
            .states = state_count,
            .plans = plan_count,
            .candidates = candidate_count,
            .spread = spread,
        },
        arena,
    );
    @memcpy(plans.observations.data, observations);
    const cpu_actions: []zn.Tensor(f32) = try arena.alloc(zn.Tensor(f32), horizon);
    for (cpu_actions) |*step_actions| {
        step_actions.* = try zn.Tensor(f32).alloc(arena, &.{ candidate_rows, action_width });
        @memset(step_actions.data, 0);
    }
    try plans.fill(&graph, plans_rng, cpu_actions);
    // -- The kit's: a scorer for the candidates' layout, the plans beside it.
    var layout: kit_mlp.KitLayout = .{};
    const kit_encoder: KitNetwork = try .init(arena, &layout, fixture.encoder);
    const kit_dynamics: KitNetwork = try .init(arena, &layout, fixture.dynamics[0]);
    const kit_reward: KitNetwork = try .init(arena, &layout, fixture.reward_head);
    const kit_value: KitNetwork = try .init(arena, &layout, fixture.value_heads[0]);
    const kit_policy: KitNetwork = try .init(arena, &layout, fixture.policy);
    const kit_scorer: bmpc_kit.KitPlanScorer(zn_mlp) = try .init(
        arena,
        &layout,
        kit_encoder,
        &.{kit_dynamics},
        kit_reward,
        &.{kit_value},
        observation_width,
        action_width,
        .{ .horizon = horizon, .states = state_count, .candidates = candidate_count, .discount = 0.95 },
    );
    const plans_options: bmpc_kit.KitPolicyPlans(zn_mlp).Options = .{
        .plans = plan_count,
        .log_std_low = spread.log_std_low,
        .log_std_high = spread.log_std_high,
    };
    const kit_plans: bmpc_kit.KitPolicyPlans(zn_mlp) = try .init(
        arena,
        &layout,
        kit_scorer,
        kit_policy,
        kit_dynamics,
        plans_options,
    );
    layout.requireFitsKit(zn_mlp);
    const params: []f32 = try arena.alloc(f32, layout.params_floats);
    kit_encoder.writeParams(fixture.encoder, params);
    kit_dynamics.writeParams(fixture.dynamics[0], params);
    kit_reward.writeParams(fixture.reward_head, params);
    kit_value.writeParams(fixture.value_heads[0], params);
    kit_policy.writeParams(fixture.policy, params);
    // The noise as `fill` draws it: each state's own stream, indexed by (plan x horizon + step) x action width +
    // dimension; laid out [step][state x plan][dimension].
    const noise: []f32 = try arena.alloc(f32, horizon * plan_rows * action_width);
    for (0..state_count) |state| {
        const state_rng: zn.Rng = plans_rng.split(@intCast(state));
        for (0..plan_count) |plan| {
            for (0..horizon) |step| {
                for (0..action_width) |dimension| {
                    const noise_index: u32 = @intCast((plan * horizon + step) * action_width + dimension);
                    const plan_row: usize = state * plan_count + plan;
                    const at: usize = (step * plan_rows + plan_row) * action_width + dimension;
                    noise[at] = state_rng.normal(f32, noise_index);
                }
            }
        }
    }
    const acts: []f32 = try arena.alloc(f32, layout.acts_floats);
    @memset(acts, 0);
    @memcpy(acts[kit_scorer.observations_offset..][0..observations.len], observations);
    kit_plans.writeNoise(acts, noise);
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = layout.largestBuffer();
    pipe.upload(.params, params);
    pipe.upload(.acts, acts);
    kit_plans.fill(&pipe);
    const kit_acts: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
    var drawn_values: usize = 0;
    for (cpu_actions, 0..) |step_actions, step| {
        const step_floats: usize = candidate_rows * action_width;
        const kit_step: []const f32 = kit_acts[kit_scorer.actions_offset + step * step_floats ..][0..step_floats];
        for (step_actions.data, kit_step) |expected, computed| {
            try expectApproxEqAbs(expected, computed, 1e-6);
            if (expected != 0) {
                drawn_values += 1;
            }
        }
    }
    // Every policy row of every step was drawn (a draw of exactly 0 has probability 0); no other row was touched.
    try expectEqual(@as(usize, horizon * plan_rows * action_width), drawn_values);
}

test "gpu learn: one MPPI round on the kit is Mppi's - the sample, the elites (NaN, infinities, ties), the refit" {
    // zimrrl's `Mppi` and the kit's `robot_bmpc_kit.KitMppi` for 2 states of 8 candidates (the first 2 the policy's),
    // 3 elites, plans of 3 steps of 4 actions: one round's sample from a cold start with the same counter-based noise,
    // then one refit on the same scores. State 0's scores hold a NaN (ranked as 0), a +inf (the highest finite, so it
    // takes the whole weight), a -inf and a tie; state 1's best three tie, so their order (the higher candidate first,
    // as the host's stable sort read from the end gives it) and their equal weights are tested. The candidates, the
    // elites exactly, their weights, and the refitted means and spreads, to rounding.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var fixture: WorldModelFixture = undefined;
    try fixture.init(arena);
    defer fixture.deinit();
    const KitNetwork: type = kit_mlp.KitNetwork(zn_mlp);
    const horizon: u32 = 3;
    const state_count: u32 = 2;
    const candidate_count: u32 = 8;
    const action_width: u32 = WorldModelFixture.action_width;
    const candidate_rows: usize = state_count * candidate_count;
    const mppi_options: zrl.Mppi(f32).Options = .{
        .horizon = horizon,
        .action_width = action_width,
        .states = state_count,
        .candidates = candidate_count,
        .policy_candidates = 2,
        .elites = 3,
        .temperature = 0.5,
        .min_spread = 0.05,
        .max_spread = 2,
    };
    const sample_rng: zn.Rng = .init(231);
    const not_a_number: f32 = nan(f32);
    const infinity: f32 = inf(f32);
    const scores = [_]f32{
        0.3, not_a_number, 1.2,  1.2, -infinity, 0.7, infinity, -0.5,
        0.1, 0.2,          0.25, 0.9, 0.9,       0.9, -1,       0.05,
    };
    // -- zimrrl's.
    const cpu_mppi: zrl.Mppi(f32) = try .init(arena, mppi_options);
    try cpu_mppi.begin(&.{ false, false });
    const cpu_actions: []zn.Tensor(f32) = try arena.alloc(zn.Tensor(f32), horizon);
    for (cpu_actions) |*step_actions| {
        step_actions.* = try zn.Tensor(f32).alloc(arena, &.{ candidate_rows, action_width });
        @memset(step_actions.data, 0);
    }
    try cpu_mppi.sample(cpu_actions, sample_rng, 0);
    try cpu_mppi.refit(cpu_actions, &scores);
    // -- The kit's: a scorer for the candidates' layout, the search beside it.
    var layout: kit_mlp.KitLayout = .{};
    const kit_encoder: KitNetwork = try .init(arena, &layout, fixture.encoder);
    const kit_dynamics: KitNetwork = try .init(arena, &layout, fixture.dynamics[0]);
    const kit_reward: KitNetwork = try .init(arena, &layout, fixture.reward_head);
    const kit_value: KitNetwork = try .init(arena, &layout, fixture.value_heads[0]);
    const kit_scorer: bmpc_kit.KitPlanScorer(zn_mlp) = try .init(
        arena,
        &layout,
        kit_encoder,
        &.{kit_dynamics},
        kit_reward,
        &.{kit_value},
        WorldModelFixture.observation_width,
        action_width,
        .{ .horizon = horizon, .states = state_count, .candidates = candidate_count, .discount = 0.95 },
    );
    const kit_mppi: bmpc_kit.KitMppi(zn_mlp) = .init(&layout, kit_scorer.searchShape(), .{
        .policy_candidates = @intCast(mppi_options.policy_candidates),
        .elites = @intCast(mppi_options.elites),
        .temperature = mppi_options.temperature,
        .min_spread = mppi_options.min_spread,
        .max_spread = mppi_options.max_spread,
    });
    layout.requireFitsKit(zn_mlp);
    // The round's noise as `sample` draws it: the generator split by the round, then the state; indexed in the
    // state's stream by (candidate x horizon + step) x action width + dimension. The policy's rows draw none.
    const noise: []f32 = try arena.alloc(f32, candidate_rows * horizon * action_width);
    @memset(noise, 0);
    for (0..state_count) |state| {
        const state_rng: zn.Rng = sample_rng.split(0).split(@intCast(state));
        for (mppi_options.policy_candidates..candidate_count) |candidate| {
            for (0..horizon) |step| {
                for (0..action_width) |dimension| {
                    const noise_index: usize = (candidate * horizon + step) * action_width + dimension;
                    const candidate_row: usize = state * candidate_count + candidate;
                    const at: usize = (candidate_row * horizon + step) * action_width + dimension;
                    noise[at] = state_rng.normal(f32, @intCast(noise_index));
                }
            }
        }
    }
    const acts: []f32 = try arena.alloc(f32, layout.acts_floats);
    @memset(acts, 0);
    kit_mppi.writeColdStart(acts);
    kit_mppi.writeNoise(acts, 0, noise);
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = layout.largestBuffer();
    pipe.upload(.acts, acts);
    kit_mppi.sample(&pipe, 0);
    pipe.uploadAt(.acts, kit_scorer.scores_offset, &scores);
    kit_mppi.refit(&pipe);
    const kit_acts: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
    // The candidates, the policy's rows untouched.
    for (cpu_actions, 0..) |step_actions, step| {
        const step_floats: usize = candidate_rows * action_width;
        const kit_step: []const f32 = kit_acts[kit_scorer.actions_offset + step * step_floats ..][0..step_floats];
        for (step_actions.data, kit_step) |expected, computed| {
            try expectApproxEqAbs(expected, computed, 1e-6);
        }
    }
    // The elites exactly - state 0: the +inf, then the tie's higher candidate, then its lower; state 1: the three-way
    // tie from the highest candidate down - and their weights.
    const elite_count: usize = mppi_options.elites;
    for (cpu_mppi.elite_candidates, kit_acts[kit_mppi.elites_offset..][0 .. state_count * elite_count]) |cpu, kit| {
        try expectEqual(float(cpu), kit);
    }
    try expectEqualSlices(usize, &.{ 6, 3, 2, 13 - 8, 12 - 8, 11 - 8 }, cpu_mppi.elite_candidates);
    for (cpu_mppi.elite_weights, kit_acts[kit_mppi.weights_offset..][0 .. state_count * elite_count]) |cpu, kit| {
        try expectApproxEqAbs(cpu, kit, 1e-7);
    }
    // The refitted Gaussians.
    const gaussian_floats: usize = state_count * horizon * action_width;
    for (cpu_mppi.mean, kit_acts[kit_mppi.mean_offset..][0..gaussian_floats]) |expected, computed| {
        try expectApproxEqAbs(expected, computed, 1e-6);
    }
    for (cpu_mppi.spread, kit_acts[kit_mppi.spread_offset..][0..gaussian_floats]) |expected, computed| {
        try expectApproxEqAbs(expected, computed, 1e-6);
    }
}

/// The kit's search drawing plans of `horizon` steps at knots - `fine_steps` each a knot, then one every `knot_span`
/// steps - for 2 states of 8 candidates (the first 2 the flow's, untouched), actions of the fixture's width: with
/// planted means, spreads and noise, every candidate's every step is its knots' value (mean + spread x noise, clamped)
/// at a knot and the straight line between two; the refit fits each knot to the elites' values at the knot's step; a
/// warm start 2 steps on gives each knot the old plan 2 steps later - between knots where it falls between them, 0
/// past the plan's end. All against the host's own geometry and arithmetic.
fn expectKnotSearch(fine_steps: u32, knot_span: u32, horizon: u32) !void {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var fixture: WorldModelFixture = undefined;
    try fixture.init(arena);
    defer fixture.deinit();
    // The host's geometry, written apart from the kernels' (`zn_mlp.planKnots`).
    const HostKnots = struct {
        fine: u32,
        span: u32,
        steps: u32,

        fn count(geometry: @This()) u32 {
            return geometry.fine + (geometry.steps - geometry.fine) / geometry.span;
        }

        fn stepOf(geometry: @This(), knot: u32) u32 {
            if (knot < geometry.fine) {
                return knot;
            }
            return geometry.fine - 1 + (knot - (geometry.fine - 1)) * geometry.span;
        }

        fn atOrBefore(geometry: @This(), step: u32) u32 {
            if (step < geometry.fine) {
                return step;
            }
            return geometry.fine - 1 + (step - (geometry.fine - 1)) / geometry.span;
        }

        fn stepsPast(geometry: @This(), step: u32) u32 {
            if (step < geometry.fine) {
                return 0;
            }
            return (step - (geometry.fine - 1)) % geometry.span;
        }

        /// A curve given at the knots, read at `step`: the knot's value, or the straight line to the next.
        fn read(geometry: @This(), at_knots: []const f32, step: u32) f32 {
            const knot: u32 = geometry.atOrBefore(step);
            const past: u32 = geometry.stepsPast(step);
            if (past == 0) {
                return at_knots[knot];
            }
            const share: f32 = float(past) / float(geometry.span);
            return at_knots[knot] + share * (at_knots[knot + 1] - at_knots[knot]);
        }
    };
    const geometry: HostKnots = .{ .fine = fine_steps, .span = knot_span, .steps = horizon };
    const knots: u32 = geometry.count();
    const KitNetwork: type = kit_mlp.KitNetwork(zn_mlp);
    const state_count: u32 = 2;
    const candidate_count: u32 = 8;
    const proposals: u32 = 2;
    const elite_count: u32 = 3;
    const action_width: u32 = WorldModelFixture.action_width;
    const candidate_rows: u32 = state_count * candidate_count;
    var layout: kit_mlp.KitLayout = .{};
    const kit_encoder: KitNetwork = try .init(arena, &layout, fixture.encoder);
    const kit_dynamics: KitNetwork = try .init(arena, &layout, fixture.dynamics[0]);
    const kit_reward: KitNetwork = try .init(arena, &layout, fixture.reward_head);
    const kit_value: KitNetwork = try .init(arena, &layout, fixture.value_heads[0]);
    const kit_scorer: bmpc_kit.KitPlanScorer(zn_mlp) = try .init(
        arena,
        &layout,
        kit_encoder,
        &.{kit_dynamics},
        kit_reward,
        &.{kit_value},
        WorldModelFixture.observation_width,
        action_width,
        .{ .horizon = horizon, .states = state_count, .candidates = candidate_count, .discount = 0.95 },
    );
    const kit_mppi: bmpc_kit.KitMppi(zn_mlp) = .init(&layout, kit_scorer.searchShape(), .{
        .policy_candidates = proposals,
        .elites = elite_count,
        .temperature = 0.5,
        .min_spread = 0.05,
        .max_spread = 2,
        .fine_steps = fine_steps,
        .knot_span = knot_span,
    });
    layout.requireFitsKit(zn_mlp);
    try expectEqual(knots, kit_mppi.knotCount());
    // Planted: means and spreads per [state][knot][action], noise per [row][knot][action], scores per row.
    const gaussian_floats: u32 = state_count * knots * action_width;
    const means: []f32 = try arena.alloc(f32, gaussian_floats);
    const spreads: []f32 = try arena.alloc(f32, gaussian_floats);
    for (means, spreads, 0..) |*mean, *spread, index| {
        const at: f32 = float(index);
        mean.* = 0.6 * @sin(0.7 * at + 0.2);
        spread.* = 0.3 + 0.2 * @cos(1.3 * at);
    }
    const noise: []f32 = try arena.alloc(f32, candidate_rows * knots * action_width);
    for (noise, 0..) |*value, index| {
        const at: f32 = float(index);
        value.* = 1.8 * @sin(2.1 * at + 0.5);
    }
    var scores: [16]f32 = undefined;
    for (&scores, 0..) |*score, row| {
        const at: f32 = float(row);
        score.* = @cos(1.7 * at) + 0.01 * at;
    }
    const acts: []f32 = try arena.alloc(f32, layout.acts_floats);
    @memset(acts, 0);
    @memcpy(acts[kit_mppi.mean_offset..][0..gaussian_floats], means);
    @memcpy(acts[kit_mppi.spread_offset..][0..gaussian_floats], spreads);
    kit_mppi.writeNoise(acts, 0, noise);
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = layout.largestBuffer();
    pipe.upload(.acts, acts);
    kit_mppi.sample(&pipe, 0);
    pipe.uploadAt(.acts, kit_scorer.scores_offset, &scores);
    kit_mppi.refit(&pipe);
    const kit_acts: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
    // Each drawn row's knot values, and the curve through them, per dimension.
    const knot_values: []f32 = try arena.alloc(f32, knots);
    const KnotValues = struct {
        fn fill(
            into: []f32,
            row: u32,
            dimension: u32,
            planted_means: []const f32,
            planted_spreads: []const f32,
            planted_noise: []const f32,
            knot_count: u32,
        ) void {
            const state: u32 = row / candidate_count;
            for (into, 0..) |*value, knot_index| {
                const knot: u32 = @intCast(knot_index);
                const gaussian_index: u32 = (state * knot_count + knot) * action_width + dimension;
                const noise_index: u32 = (row * knot_count + knot) * action_width + dimension;
                const proposal: f32 = planted_means[gaussian_index] +
                    planted_spreads[gaussian_index] * planted_noise[noise_index];
                value.* = clamp(proposal, -1.0, 1.0);
            }
        }
    };
    // The sample: every drawn candidate's every step; the flow's rows untouched (0).
    for (0..candidate_rows) |row_index| {
        const row: u32 = @intCast(row_index);
        const is_proposal: bool = row % candidate_count < proposals;
        for (0..action_width) |dimension_index| {
            const dimension: u32 = @intCast(dimension_index);
            KnotValues.fill(knot_values, row, dimension, means, spreads, noise, knots);
            for (0..horizon) |step_index| {
                const step: u32 = @intCast(step_index);
                const at: usize = kit_scorer.actions_offset + (step * candidate_rows + row) * action_width + dimension;
                const expected: f32 = if (is_proposal) 0 else geometry.read(knot_values, step);
                try expectApproxEqAbs(expected, kit_acts[at], 1e-6);
            }
        }
    }
    // The refit: each state's 3 best rows by score, weighed exp(0.5 (score - best)), each knot fitted to their values
    // at the knot's step (the flow's rows' values there are 0).
    const refit_means: []f32 = try arena.alloc(f32, gaussian_floats);
    for (0..state_count) |state_index| {
        const state: u32 = @intCast(state_index);
        var order: [8]u32 = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
        const row_scores: []const f32 = scores[state * candidate_count ..][0..candidate_count];
        const ByScore = struct {
            fn higher(context: []const f32, a: u32, b: u32) bool {
                return context[a] > context[b];
            }
        };
        sortSlice(u32, &order, row_scores, ByScore.higher);
        var weights: [3]f32 = undefined;
        var weight_sum: f32 = 0;
        for (&weights, order[0..elite_count]) |*weight, candidate| {
            weight.* = @exp(0.5 * (row_scores[candidate] - row_scores[order[0]]));
            weight_sum += weight.*;
        }
        for (&weights) |*weight| {
            weight.* /= weight_sum;
        }
        for (0..action_width) |dimension_index| {
            const dimension: u32 = @intCast(dimension_index);
            for (0..knots) |knot_index| {
                const knot: u32 = @intCast(knot_index);
                const knot_step: u32 = geometry.stepOf(knot);
                var elite_values: [3]f32 = undefined;
                for (&elite_values, order[0..elite_count]) |*value, candidate| {
                    const row: u32 = state * candidate_count + candidate;
                    KnotValues.fill(knot_values, row, dimension, means, spreads, noise, knots);
                    value.* = if (candidate < proposals) 0 else geometry.read(knot_values, knot_step);
                }
                var mean: f32 = 0;
                for (weights, elite_values) |weight, value| {
                    mean += weight * value;
                }
                var variance: f32 = 0;
                for (weights, elite_values) |weight, value| {
                    variance += weight * (value - mean) * (value - mean);
                }
                const index: u32 = (state * knots + knot) * action_width + dimension;
                refit_means[index] = mean;
                try expectApproxEqAbs(mean, kit_acts[kit_mppi.mean_offset + index], 1e-5);
                const spread: f32 = clamp(@sqrt(variance), 0.05, 2);
                try expectApproxEqAbs(spread, kit_acts[kit_mppi.spread_offset + index], 1e-5);
            }
        }
    }
    // The warm start, 2 steps on: each knot the old plan 2 steps later, 0 past its end; every spread the ceiling.
    const flags = [_]f32{ 1, 1 };
    pipe.uploadAt(.acts, kit_mppi.warm_flags_offset, &flags);
    kit_mppi.begin(&pipe, 2);
    const warm_acts: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
    const old_curve: []f32 = try arena.alloc(f32, knots);
    for (0..state_count) |state_index| {
        const state: u32 = @intCast(state_index);
        for (0..action_width) |dimension_index| {
            const dimension: u32 = @intCast(dimension_index);
            for (old_curve, 0..) |*value, knot_index| {
                value.* = refit_means[(state * knots + @as(u32, @intCast(knot_index))) * action_width + dimension];
            }
            for (0..knots) |knot_index| {
                const knot: u32 = @intCast(knot_index);
                const source_step: u32 = geometry.stepOf(knot) + 2;
                const expected: f32 = if (source_step >= horizon) 0 else geometry.read(old_curve, source_step);
                const index: usize = (state * knots + knot) * action_width + dimension;
                try expectApproxEqAbs(expected, warm_acts[kit_mppi.mean_offset + index], 1e-5);
                try expectEqual(@as(f32, 2), warm_acts[kit_mppi.spread_offset + index]);
            }
        }
    }
}

test "gpu learn: MPPI in knots - drawn at the knots, straight between them, refitted at them, shifted along them" {
    // One scale - knots at steps 0, 3, 6 of 7 - and two: every step of the first 4 a knot, then every 4th to step 19
    // of 20 (knots at 0, 1, 2, 3, 7, 11, 15, 19), the far half's knots one per jump of a 4-step model.
    try expectKnotSearch(1, 3, 7);
    try expectKnotSearch(4, 4, 20);
}

test "gpu learn: two decisions on the kit are the CPU actor's - cold then warm, every target, spread and action" {
    // The CPU agent's own `Actor` (f32) and the kit's `robot_bmpc_kit.KitPlanner` deciding for 2 states: the policy's
    // 2 plans among 8 candidates, 2 rounds of sample, score and refit under both dynamics heads and both value heads,
    // 3 elites, the drawn elite's first action jittered for exploration. The first decision is cold (an episode's
    // start); the second warm - the kit's Gaussians carried over in acts from the first, shifted one step. Every
    // piece's noise is the actor's, drawn from the same generators split the same way. After each decision: every
    // target, first spread and explored action, to rounding, and every chosen elite exactly.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const Tdmpc: type = bmpc.Bmpc(f32);
    const KitNetwork: type = kit_mlp.KitNetwork(zn_mlp);
    const observation_width: u32 = 6;
    const action_width: u32 = 3;
    const state_count: u32 = 2;
    const config: Tdmpc.Config = .{
        .latent_width = 16,
        .hidden_width = 16,
        .encoder_hidden_width = 16,
        .simnorm_group = 8,
        .horizon = 3,
        .discount = 0.95,
        .dynamics_heads = 2,
        .value_heads = 2,
    };
    const planner_config: Tdmpc.PlannerConfig = .{
        .horizon = 3,
        .candidates = 8,
        .policy_candidates = 2,
        .elites = 3,
        .iterations = 2,
    };
    const horizon: u32 = @intCast(planner_config.horizon);
    const candidate_count: u32 = @intCast(planner_config.candidates);
    const plan_count: u32 = @intCast(planner_config.policy_candidates);
    const rounds: u32 = @intCast(planner_config.iterationsFor(action_width));
    const networks: Tdmpc.Networks = try .init(arena, zn.Rng.init(241), observation_width, action_width, config);
    const actor: Tdmpc.Actor = try .init(
        arena,
        networks,
        observation_width,
        action_width,
        state_count,
        config,
        planner_config,
    );
    // -- The kit's planner over the same networks.
    var layout: kit_mlp.KitLayout = .{};
    const kit_encoder: KitNetwork = try .init(arena, &layout, networks.encoder);
    const kit_dynamics: []KitNetwork = try arena.alloc(KitNetwork, networks.dynamics.len);
    for (kit_dynamics, networks.dynamics) |*kit_head, head| {
        kit_head.* = try KitNetwork.init(arena, &layout, head);
    }
    const kit_reward: KitNetwork = try .init(arena, &layout, networks.reward);
    const kit_values: []KitNetwork = try arena.alloc(KitNetwork, networks.values.len);
    for (kit_values, networks.values) |*kit_value, value_head| {
        kit_value.* = try KitNetwork.init(arena, &layout, value_head);
    }
    const kit_policy: KitNetwork = try .init(arena, &layout, networks.policy);
    const scorer: bmpc_kit.KitPlanScorer(zn_mlp) = try .init(
        arena,
        &layout,
        kit_encoder,
        kit_dynamics,
        kit_reward,
        kit_values,
        observation_width,
        action_width,
        .{
            .horizon = horizon,
            .states = state_count,
            .candidates = candidate_count,
            .discount = config.discount,
            .objective = planner_config.objective,
            .pessimism = planner_config.pessimism,
        },
    );
    const plans_options: bmpc_kit.KitPolicyPlans(zn_mlp).Options = .{
        .plans = plan_count,
        .log_std_low = config.spread.log_std_low,
        .log_std_high = config.spread.log_std_high,
    };
    const policy_plans: bmpc_kit.KitPolicyPlans(zn_mlp) = try .init(
        arena,
        &layout,
        scorer,
        kit_policy,
        kit_dynamics[0],
        plans_options,
    );
    const mppi: bmpc_kit.KitMppi(zn_mlp) = .init(&layout, scorer.searchShape(), .{
        .policy_candidates = plan_count,
        .elites = @intCast(planner_config.elites),
        .temperature = config.temperature,
        .min_spread = config.min_spread,
        .max_spread = config.max_spread,
        .rounds = rounds,
    });
    const planner: bmpc_kit.KitPlanner(zn_mlp) = .{ .scorer = scorer, .policy_plans = policy_plans, .mppi = mppi };
    layout.requireFitsKit(zn_mlp);
    const params: []f32 = try arena.alloc(f32, layout.params_floats);
    kit_encoder.writeParams(networks.encoder, params);
    for (kit_dynamics, networks.dynamics) |kit_head, head| {
        kit_head.writeParams(head, params);
    }
    kit_reward.writeParams(networks.reward, params);
    for (kit_values, networks.values) |kit_value, value_head| {
        kit_value.writeParams(value_head, params);
    }
    kit_policy.writeParams(networks.policy, params);
    const acts: []f32 = try arena.alloc(f32, layout.acts_floats);
    @memset(acts, 0);
    scorer.writeWeights(acts);
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = layout.largestBuffer();
    pipe.upload(.params, params);
    pipe.upload(.acts, acts);
    const action_floats: usize = state_count * action_width;
    const decision_seeds = [_]u32{ 251, 252 };
    for (decision_seeds, 0..) |seed, decision_index| {
        const decision_rng: zn.Rng = .init(seed);
        const is_first_decision: bool = decision_index == 0;
        const first_steps = [_]bool{ is_first_decision, is_first_decision };
        const observations: []f32 = try arena.alloc(f32, state_count * observation_width);
        for (observations, 0..) |*value, index| {
            value.* = 0.7 * @sin(0.53 * float(index) + float(decision_index));
        }
        // -- The CPU actor's decision.
        const decision: Tdmpc.Decision = .{
            .actions = try arena.alloc(f32, action_floats),
            .target_means = try arena.alloc(f32, action_floats),
            .target_spreads = try arena.alloc(f32, action_floats),
        };
        try actor.act(observations, &first_steps, .explore, decision_rng, decision);
        // -- The kit's inputs, drawn as the actor draws them (`KitPlanner.writeDecisionInputs`), uploaded region by
        //    region - the Gaussians the last decision left in acts stay where they are.
        planner.writeDecisionInputs(acts, observations, &first_steps, decision_rng, 0);
        planner.uploadDecisionInputs(&pipe, acts);
        // -- The kit's decision.
        planner.decide(&pipe, .explore);
        const kit_acts: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
        const kit_targets: []const f32 = kit_acts[mppi.targets_offset..][0..action_floats];
        const kit_spreads: []const f32 = kit_acts[mppi.targets_offset + action_floats ..][0..action_floats];
        const kit_actions: []const f32 = kit_acts[mppi.actions_offset..][0..action_floats];
        for (decision.target_means, kit_targets) |expected, computed| {
            try expectApproxEqAbs(expected, computed, 1e-6);
        }
        for (decision.target_spreads, kit_spreads) |expected, computed| {
            try expectApproxEqAbs(expected, computed, 1e-6);
        }
        for (decision.actions, kit_actions) |expected, computed| {
            try expectApproxEqAbs(expected, computed, 1e-6);
        }
        for (0..state_count) |state| {
            const cpu_chosen: usize = actor.mppi.chosen_rows[state] - state * candidate_count;
            try expectEqual(float(cpu_chosen), kit_acts[mppi.chosen_offset + state]);
        }
    }
}

/// The kit learner's tests' setup: `networks` placed on a kit layout in the world model's order (the policy after),
/// a `KitLearner` over them, every network's numbers written, and each kit network paired with the CPU network it
/// copies - the pairs in the layout's order, for comparing every parameter after an update.
const KitLearnerSetup = struct {
    const KitNetwork = kit_mlp.KitNetwork(zn_mlp);
    const NetworkPair = struct { kit: KitNetwork, mlp: zn.Mlp(f32) };

    layout: kit_mlp.KitLayout,
    learner: bmpc_kit.KitLearner(zn_mlp),
    pairs: []const NetworkPair,
    kit_policy: KitNetwork,
    params: []f32,
    zero_moments: []f32,
    host_acts: []f32,

    fn init(
        arena: Allocator,
        networks: bmpc.Bmpc(f32).Networks,
        observation_width: u32,
        action_width: u32,
        config: bmpc.Bmpc(f32).Config,
        options: bmpc_kit.KitLearner(zn_mlp).Options,
    ) !KitLearnerSetup {
        var layout: kit_mlp.KitLayout = .{};
        var pairs: ArrayList(NetworkPair) = .empty;
        const kit_encoder: KitNetwork = try .init(arena, &layout, networks.encoder);
        try pairs.append(arena, .{ .kit = kit_encoder, .mlp = networks.encoder });
        const kit_dynamics: []KitNetwork = try arena.alloc(KitNetwork, networks.dynamics.len);
        for (kit_dynamics, networks.dynamics) |*kit_head, head| {
            kit_head.* = try KitNetwork.init(arena, &layout, head);
            try pairs.append(arena, .{ .kit = kit_head.*, .mlp = head });
        }
        const kit_reward: KitNetwork = try .init(arena, &layout, networks.reward);
        try pairs.append(arena, .{ .kit = kit_reward, .mlp = networks.reward });
        const kit_values: []KitNetwork = try arena.alloc(KitNetwork, networks.values.len);
        for (kit_values, networks.values) |*kit_value, value_head| {
            kit_value.* = try KitNetwork.init(arena, &layout, value_head);
            try pairs.append(arena, .{ .kit = kit_value.*, .mlp = value_head });
        }
        const kit_targets: []KitNetwork = try arena.alloc(KitNetwork, networks.target_values.len);
        for (kit_targets, networks.target_values) |*kit_target, target_head| {
            kit_target.* = try KitNetwork.init(arena, &layout, target_head);
            try pairs.append(arena, .{ .kit = kit_target.*, .mlp = target_head });
        }
        const kit_policy: KitNetwork = try .init(arena, &layout, networks.policy);
        try pairs.append(arena, .{ .kit = kit_policy, .mlp = networks.policy });
        var learner: bmpc_kit.KitLearner(zn_mlp) = try .init(arena, &layout, .{
            .encoder = kit_encoder,
            .dynamics = kit_dynamics,
            .reward = kit_reward,
            .values = kit_values,
            .target_values = kit_targets,
            .policy = kit_policy,
        }, observation_width, action_width, config, options);
        layout.requireFitsKit(zn_mlp);
        const params: []f32 = try arena.alloc(f32, layout.params_floats);
        for (pairs.items) |pair| {
            pair.kit.writeParams(pair.mlp, params);
        }
        const zero_moments: []f32 = try arena.alloc(f32, layout.params_floats);
        @memset(zero_moments, 0);
        const host_acts: []f32 = try learner.allocateHostActs(arena, layout.acts_floats);
        const setup: KitLearnerSetup = .{
            .layout = layout,
            .learner = learner,
            .pairs = pairs.items,
            .kit_policy = kit_policy,
            .params = params,
            .zero_moments = zero_moments,
            .host_acts = host_acts,
        };
        return setup;
    }

    /// Every buffer's starting contents uploaded: the parameters, Adam's zero moments, the host's copy of acts.
    fn uploadStart(setup: *const KitLearnerSetup, pipe: *compute_host.Compute(zn_mlp)) void {
        pipe.element_count = setup.layout.largestBuffer();
        pipe.upload(.params, setup.params);
        pipe.upload(.adam_m, setup.zero_moments);
        pipe.upload(.adam_v, setup.zero_moments);
        pipe.upload(.acts, setup.host_acts);
    }

    /// The largest gap between the kit's parameters and the CPU networks' - every network, in the layout's order.
    fn largestParameterGap(
        setup: *const KitLearnerSetup,
        arena: Allocator,
        kit_params: []const f32,
    ) !f32 {
        var largest_gap: f32 = 0;
        var params_start: usize = 0;
        for (setup.pairs) |pair| {
            for ((try pair.mlp.params(arena)).tensors) |tensor| {
                for (tensor.data, kit_params[params_start..][0..tensor.data.len]) |expected, computed| {
                    largest_gap = @max(largest_gap, @abs(expected - computed));
                }
                params_start += tensor.data.len;
            }
        }
        return largest_gap;
    }
};

/// The kit learner's tests' replay: one character, four short episodes each cut at its last step - so a window of
/// three steps nearly always runs past an episode's end - every step stored with a planner's target (its means and
/// spreads). Built afresh for each side of a test that writes targets back.
fn learnerTestReplay(arena: Allocator, row_layout: bmpc.Bmpc(f32).Row) !zrl.SequenceReplay(f32) {
    const Tdmpc: type = bmpc.Bmpc(f32);
    const observation_width: usize = row_layout.observation_width;
    const action_width: usize = row_layout.action_width;
    var replay: zrl.SequenceReplay(f32) = try .init(arena, 1, 32, row_layout.width(), row_layout.doneColumn());
    const episode_lengths = [_]usize{ 2, 3, 2, 4 };
    var global_step: usize = 0;
    for (episode_lengths) |episode_length| {
        for (0..episode_length) |step| {
            const observation: []f32 = try arena.alloc(f32, observation_width);
            const next_observation: []f32 = try arena.alloc(f32, observation_width);
            for (observation, next_observation, 0..) |*value, *next_value, column| {
                value.* = 0.6 * @sin(0.37 * float(global_step) + float(column));
                next_value.* = 0.6 * @sin(0.37 * float(global_step + 1) + float(column));
            }
            const action: []f32 = try arena.alloc(f32, action_width);
            const target_means: []f32 = try arena.alloc(f32, action_width);
            const target_spreads: []f32 = try arena.alloc(f32, action_width);
            for (action, target_means, target_spreads, 0..) |*value, *mean, *spread, column| {
                value.* = 0.7 * @cos(0.53 * float(global_step) + float(column));
                mean.* = 0.5 * @sin(0.71 * float(global_step) + float(column));
                spread.* = 0.05 + 0.6 * (0.5 + 0.5 * @cos(1.1 * float(global_step + column)));
            }
            const is_last_step: bool = step + 1 == episode_length;
            const stored_step: Tdmpc.Step = .{
                .observation = observation,
                .action = action,
                .reward = 0.4 + 0.2 * @sin(float(global_step)),
                .next_observation = next_observation,
                .terminated = false,
                .truncated = is_last_step,
                .target = .{ .means = target_means, .spreads = target_spreads },
            };
            const row: []f32 = try arena.alloc(f32, row_layout.width());
            try row_layout.fill(row, stored_step);
            try replay.push(row, &.{true});
            global_step += 1;
        }
    }
    return replay;
}

test "gpu learn: three updates of the kit's learner are the CPU agent's - pretraining, then world model and policy" {
    // The CPU agent's own `Learner` (f32, reanalyze off) and `robot_bmpc_kit.KitLearner` on the same replay - four
    // short episodes, every stored step with a planner's target - over three updates: the first pretraining (the world
    // model alone), the next two whole (the world model, then the policy on its rolled latents, its targets read from
    // the batch's rows). The kit's batch is sampled by the same call; the targets' noise is the same split of each
    // update's generator, the dropout masks the CPU learner's own generators. After every update: every parameter of
    // every network - the policy's and the target heads' included - to rounding.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const Tdmpc: type = bmpc.Bmpc(f32);
    const KitLearner: type = bmpc_kit.KitLearner(zn_mlp);
    const observation_width: u32 = 6;
    const action_width: u32 = 3;
    var config: Tdmpc.Config = .{
        .latent_width = 16,
        .hidden_width = 16,
        .encoder_hidden_width = 16,
        .simnorm_group = 8,
        .horizon = 3,
        .discount = 0.95,
        .windows = 4,
        .dynamics_heads = 2,
        .value_heads = 2,
    };
    config.value_dropout = 0.25;
    config.reanalyze_interval = 0;
    const networks: Tdmpc.Networks = try .init(arena, zn.Rng.init(261), observation_width, action_width, config);
    var cpu_learner: Tdmpc.Learner = try .init(arena, networks, observation_width, action_width, config);
    // -- A replay of four short episodes, each step stored with a planner's target.
    const row_layout: Tdmpc.Row = .{ .observation_width = observation_width, .action_width = action_width };
    var replay: zrl.SequenceReplay(f32) = try learnerTestReplay(arena, row_layout);
    // -- The kit's learner over the same networks, placed in the world model's order, the policy after.
    const setup: KitLearnerSetup = try .init(arena, networks, observation_width, action_width, config, .{});
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    setup.uploadStart(&pipe);
    const layout: kit_mlp.KitLayout = setup.layout;
    var kit_learner: KitLearner = setup.learner;
    const pairs: []const KitLearnerSetup.NetworkPair = setup.pairs;
    // -- Three updates on each side.
    for (0..3) |update_number| {
        const update_index: u32 = @intCast(update_number);
        const pretraining: bool = update_number == 0;
        const update_rng: zn.Rng = zn.Rng.init(271).split(update_index);
        _ = try cpu_learner.update(&replay, update_rng, update_index, pretraining);
        // The CPU learner's dropout generators: split 2, then each dropout node's index in its graph.
        var dropout_rngs: ArrayList(zn.Rng) = .empty;
        for (cpu_learner.world_model.graph.nodes.items, 0..) |node, node_index| {
            if (node.op == .dropout_op) {
                try dropout_rngs.append(arena, update_rng.split(2).split(@intCast(node_index)));
            }
        }
        try kit_learner.update(&pipe, &replay, update_rng, update_index, pretraining, dropout_rngs.items);
        const kit_params: []const f32 = pipe.readLatest(.params) orelse return error.NoReadback;
        var params_start: usize = 0;
        for (pairs) |pair| {
            for ((try pair.mlp.params(arena)).tensors) |tensor| {
                for (tensor.data, kit_params[params_start..][0..tensor.data.len]) |expected, computed| {
                    try expectApproxEqAbs(expected, computed, 1e-6);
                }
                params_start += tensor.data.len;
            }
        }
        try expectEqual(@as(usize, layout.params_floats), params_start);
    }
    try expectEqual(@as(usize, 2), kit_learner.updates);
}

test "gpu learn: the kit's learner reanalyzes as the CPU agent's - replanned targets, the replay written back" {
    // The CPU agent's own `Learner` and `robot_bmpc_kit.KitLearner` with reanalyze on every real update: the first 2
    // of the 4 windows' stored states, 6 of them, planned again from scratch by a small reanalyzing planner (8
    // candidates, 2 of them the policy's, 3 elites, 2 rounds, a pessimism of 0.5) before the world model learns. Each
    // side updates its own copy of the same replay, since reanalyze writes its targets back. Over three updates - the
    // first pretraining, so not reanalyzing - every parameter, the policy's included (it learns from the new
    // targets), and every stored row of the two replays (the written-back targets among them), to rounding.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const Tdmpc: type = bmpc.Bmpc(f32);
    const KitLearner: type = bmpc_kit.KitLearner(zn_mlp);
    const observation_width: u32 = 6;
    const action_width: u32 = 3;
    var config: Tdmpc.Config = .{
        .latent_width = 16,
        .hidden_width = 16,
        .encoder_hidden_width = 16,
        .simnorm_group = 8,
        .horizon = 3,
        .discount = 0.95,
        .windows = 4,
        .dynamics_heads = 2,
        .value_heads = 2,
    };
    config.value_dropout = 0.25;
    config.reanalyze_interval = 1;
    config.reanalyze_windows = 2;
    config.reanalyzing = .{
        .horizon = 3,
        .candidates = 8,
        .policy_candidates = 2,
        .elites = 3,
        .iterations = 2,
        .pessimism = 0.5,
    };
    const networks: Tdmpc.Networks = try .init(arena, zn.Rng.init(281), observation_width, action_width, config);
    var cpu_learner: Tdmpc.Learner = try .init(arena, networks, observation_width, action_width, config);
    const row_layout: Tdmpc.Row = .{ .observation_width = observation_width, .action_width = action_width };
    var cpu_replay: zrl.SequenceReplay(f32) = try learnerTestReplay(arena, row_layout);
    var kit_replay: zrl.SequenceReplay(f32) = try learnerTestReplay(arena, row_layout);
    // Chunks of 4: the six stored states in two chunks, the second padded - as one decision over all six would.
    const setup: KitLearnerSetup = try .init(arena, networks, observation_width, action_width, config, .{
        .reanalyze_chunk_states = 4,
    });
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    setup.uploadStart(&pipe);
    var kit_learner: KitLearner = setup.learner;
    var reanalyzed_updates: usize = 0;
    for (0..3) |update_number| {
        const update_index: u32 = @intCast(update_number);
        const pretraining: bool = update_number == 0;
        const update_rng: zn.Rng = zn.Rng.init(291).split(update_index);
        const cpu_report: Tdmpc.LearnerReport = try cpu_learner.update(
            &cpu_replay,
            update_rng,
            update_index,
            pretraining,
        );
        reanalyzed_updates += @intFromBool(cpu_report.reanalyzed);
        var dropout_rngs: ArrayList(zn.Rng) = .empty;
        for (cpu_learner.world_model.graph.nodes.items, 0..) |node, node_index| {
            if (node.op == .dropout_op) {
                try dropout_rngs.append(arena, update_rng.split(2).split(@intCast(node_index)));
            }
        }
        try kit_learner.update(&pipe, &kit_replay, update_rng, update_index, pretraining, dropout_rngs.items);
        const kit_params: []const f32 = pipe.readLatest(.params) orelse return error.NoReadback;
        const largest_gap: f32 = try setup.largestParameterGap(arena, kit_params);
        try expect(largest_gap < 1e-6);
        // The replays: every stored row, the written-back targets among them.
        const cpu_rows: []const f32 = cpu_replay.environment_rings[0].data;
        const kit_rows: []const f32 = kit_replay.environment_rings[0].data;
        for (cpu_rows, kit_rows) |expected, computed| {
            try expectApproxEqAbs(expected, computed, 1e-6);
        }
    }
    try expectEqual(@as(usize, 2), reanalyzed_updates);
    try expectEqual(@as(usize, 2), kit_learner.updates);
}

/// The failure barrier's value for one row of normalised features `z` against the goal `goal` - the host's sum of the
/// two smooth hinges `lat_barrier_bwd` takes the gradient of, before the weight and the share over rows.
fn failureBarrierValue(
    z: []const f64,
    goal: []const f64,
    means: []const f64,
    spreads: []const f64,
    head_column: usize,
    up_column: usize,
    barrier: latent_kit.FailureBarrier,
) f64 {
    const head_height: f64 = z[head_column] * spreads[head_column] + means[head_column];
    const reference_head_height: f64 = goal[head_column] * spreads[head_column] + means[head_column];
    const height_error: f64 = @abs(head_height - reference_head_height);
    const head_hinge: f64 = zm.smoothHinge(f64, height_error, barrier.head_margin, barrier.head_width);
    var up_dot: f64 = 0;
    var up_square: f64 = 0;
    var reference_up_square: f64 = 0;
    for (0..3) |axis| {
        const column: usize = up_column + axis;
        const up: f64 = z[column] * spreads[column] + means[column];
        const reference_up: f64 = goal[column] * spreads[column] + means[column];
        up_dot += up * reference_up;
        up_square += up * up;
        reference_up_square += reference_up * reference_up;
    }
    const cosine: f64 = up_dot / (@sqrt(up_square) * @sqrt(reference_up_square));
    const tilt_hinge: f64 = zm.smoothHinge(f64, 1 - cosine, barrier.tilt_margin, barrier.tilt_width);
    return head_hinge + tilt_hinge;
}

test "gpu learn: the failure barrier's gradient is its value's, by central differences" {
    // `lat_barrier_bwd` on three rows of eight features - the head's height in column 2, up in columns 5 to 7 -
    // placed about both margins: head height errors of 0.10, 0.24 and 0.31 m, tilts of 30, 85 and 100 degrees. A
    // normaliser with non-trivial means and spreads, so the un-normalising is checked too. Every column's gradient
    // against central differences of the host's value, weight and share included; the other columns untouched.
    const rows: usize = 3;
    const features: usize = 8;
    const head_column: usize = 2;
    const up_column: usize = 5;
    const barrier: latent_kit.FailureBarrier = .{ .weight = 1.7 };
    const means = [features]f64{ 0.1, -0.2, 0.9, 0.0, 0.3, 0.0, 0.1, 0.8 };
    const spreads = [features]f64{ 1.0, 0.5, 0.2, 2.0, 1.0, 0.4, 0.5, 0.3 };
    const head_errors = [rows]f64{ 0.10, 0.24, 0.31 };
    const tilts_deg = [rows]f64{ 30.0, 85.0, 100.0 };
    var z: [rows * features]f64 = undefined;
    var goal: [rows * features]f64 = undefined;
    for (0..rows) |row| {
        for (0..features) |column| {
            z[row * features + column] = 0.3 * @sin(float64(row * features + column));
            goal[row * features + column] = 0.2 * @cos(float64(row * features + column));
        }
        // The raw head heights: the reference at 1.5 m, the character the row's error below it.
        const reference_height: f64 = 1.5;
        const head_height: f64 = reference_height - head_errors[row];
        goal[row * features + head_column] = (reference_height - means[head_column]) / spreads[head_column];
        z[row * features + head_column] = (head_height - means[head_column]) / spreads[head_column];
        // The raw up directions: the reference's straight up, the character's tilted by the row's angle in x-z.
        const tilt_rad: f64 = tilts_deg[row] * pi / 180.0;
        const reference_up = [3]f64{ 0, 0, 1 };
        const up = [3]f64{ @sin(tilt_rad), 0, @cos(tilt_rad) };
        for (0..3) |axis| {
            const column: usize = up_column + axis;
            goal[row * features + column] = (reference_up[axis] - means[column]) / spreads[column];
            z[row * features + column] = (up[axis] - means[column]) / spreads[column];
        }
    }
    // The kit's kernel on the CPU twin.
    var host_acts: [1024]f32 = @splat(0);
    const z_at: u32 = 0;
    const goal_at: u32 = 64;
    const norm_at: u32 = 128;
    for (z, goal, 0..) |z_value, goal_value, index| {
        host_acts[z_at + index] = @floatCast(z_value);
        host_acts[goal_at + index] = @floatCast(goal_value);
    }
    for (means, spreads, 0..) |mean, spread, column| {
        host_acts[norm_at + column] = @floatCast(mean);
        host_acts[norm_at + features + column] = @floatCast(spread);
    }
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = 1024;
    pipe.upload(.acts, &host_acts);
    const zero_gradients: [1024]f32 = @splat(0);
    pipe.upload(.dacts, &zero_gradients);
    pipe.params = .{
        .rows = @intCast(rows),
        .out_dim = @intCast(features),
        .y_off = z_at,
        .t_off = goal_at,
        .u_off = norm_at,
        .dy_off = 0,
        .barrier_head_column = @intCast(head_column),
        .barrier_up_column = @intCast(up_column),
        .barrier_weight = barrier.weight,
        .barrier_head_margin = barrier.head_margin,
        .barrier_head_width = barrier.head_width,
        .barrier_tilt_margin = barrier.tilt_margin,
        .barrier_tilt_width = barrier.tilt_width,
    };
    pipe.run("lat_barrier_bwd", @intCast(rows));
    const gradients: []const f32 = pipe.readLatest(.dacts) orelse return error.NoReadback;
    // Central differences of the host's value, weighted and shared over the rows as the kernel's.
    const difference_step: f64 = 1e-6;
    const row_share: f64 = barrier.weight / float64(rows);
    for (0..rows) |row| {
        const row_goal: []const f64 = goal[row * features ..][0..features];
        for (0..features) |column| {
            var ahead: [features]f64 = z[row * features ..][0..features].*;
            var behind: [features]f64 = ahead;
            ahead[column] += difference_step;
            behind[column] -= difference_step;
            const value_ahead: f64 =
                failureBarrierValue(&ahead, row_goal, &means, &spreads, head_column, up_column, barrier);
            const value_behind: f64 =
                failureBarrierValue(&behind, row_goal, &means, &spreads, head_column, up_column, barrier);
            const numeric: f64 = row_share * (value_ahead - value_behind) / (2 * difference_step);
            try expectApproxEqAbs(numeric, gradients[row * features + column], 2e-4);
        }
    }
}

test "gpu learn: the critic's TD targets are each transition's cost plus the discounted target heads, by hand" {
    // `LatentCritic.computeTargets` on a hand-made window batch: one row, three steps of eight features - two real
    // transitions, 1 -> 2 and 2 -> 3 - with a non-trivial normaliser and the failure barrier at weight 1.5 (head
    // height in column 2, up in 5 to 7). The two target heads are set to predict known values: all but a vanishing
    // share of their softmax on the bins at 1 and 2 of the symlog axis, so they decode to e - 1 and e^2 - 1. Each
    // target must be the transition's cost - the mean squared distance from the goal where it led, plus the barrier,
    // by hand - plus 0.9 times the two heads' mean; and each input row the goal beside the state.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const Critic: type = latent_kit.LatentCritic(zn_mlp);
    const features: u32 = 8;
    const steps: u32 = 3;
    const head_column: u32 = 2;
    const up_column: u32 = 5;
    const barrier: latent_kit.FailureBarrier = .{ .weight = 1.5 };
    const means = [features]f64{ 0.1, -0.2, 0.9, 0.0, 0.3, 0.0, 0.1, 0.8 };
    const spreads = [features]f64{ 1.0, 0.5, 0.2, 2.0, 1.0, 0.4, 0.5, 0.3 };
    const source: Critic.Source = .{
        .features = features,
        .rows = 1,
        .steps = steps,
        .states_at = 0,
        .goals_at = 32,
        .norm_at = 64,
        .barrier = barrier,
        .barrier_head_column = head_column,
        .barrier_up_column = up_column,
    };
    var layout: kit_mlp.KitLayout = .{ .acts_floats = 128 };
    const critic: Critic = try .init(arena, &layout, source, .{ .heads = 2, .hidden = 4, .discount = 0.9 });
    // The target heads: their last layer's weights are zero, so their logits are its bias - 30 on one bin, 0 on the
    // rest. Bins sit 0.2 apart on [-10, 10]: bin 55 at 1, bin 60 at 2.
    const chosen_bins = [2]usize{ 55, 60 };
    for (critic.target_mlps, chosen_bins) |target_mlp, chosen_bin| {
        const tensors: []const zn.Tensor(f32) = (try target_mlp.params(arena)).tensors;
        const output_bias: []f32 = tensors[tensors.len - 1].data;
        @memset(output_bias, 0);
        output_bias[chosen_bin] = 30;
    }
    const params: []f32 = try arena.alloc(f32, layout.params_floats);
    critic.writeParams(params);
    // The window batch: states and goals after steps 1 to 3, the normaliser.
    var host_acts: []f32 = try arena.alloc(f32, layout.acts_floats);
    @memset(host_acts, 0);
    var states: [steps * features]f64 = undefined;
    var goals: [steps * features]f64 = undefined;
    for (0..steps * features) |index| {
        states[index] = 0.4 * @sin(0.7 * float64(index) + 0.3);
        goals[index] = 0.3 * @cos(0.5 * float64(index));
        host_acts[source.states_at + index] = @floatCast(states[index]);
        host_acts[source.goals_at + index] = @floatCast(goals[index]);
    }
    for (means, spreads, 0..) |mean, spread, column| {
        host_acts[source.norm_at + column] = @floatCast(mean);
        host_acts[source.norm_at + features + column] = @floatCast(spread);
    }
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = layout.largestBuffer();
    pipe.upload(.params, params);
    pipe.upload(.acts, host_acts);
    critic.computeTargets(&pipe);
    const device_acts: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
    // By hand.
    const first_head_value: f64 = @exp(@as(f64, 1.0)) - 1;
    const second_head_value: f64 = @exp(@as(f64, 2.0)) - 1;
    const head_values_mean: f64 = (first_head_value + second_head_value) / 2;
    for (0..steps - 1) |transition| {
        const next_state: []const f64 = states[(transition + 1) * features ..][0..features];
        const next_goal: []const f64 = goals[(transition + 1) * features ..][0..features];
        var square_sum: f64 = 0;
        for (next_state, next_goal) |state_value, goal_value| {
            square_sum += (state_value - goal_value) * (state_value - goal_value);
        }
        const hinges: f64 =
            failureBarrierValue(next_state, next_goal, &means, &spreads, head_column, up_column, barrier);
        const cost: f64 = square_sum / float64(features) + barrier.weight * hinges;
        try expectApproxEqAbs(cost, device_acts[critic.costs_at + transition], 1e-5);
        const target: f64 = cost + 0.9 * head_values_mean;
        try expectApproxEqAbs(target, device_acts[critic.targets_at + transition], 1e-4);
        // The input row: this step's goal, then its state.
        const input_row: []const f32 = device_acts[critic.inputs_at + transition * 2 * features ..][0 .. 2 * features];
        for (0..features) |column| {
            try expectApproxEqAbs(goals[transition * features + column], input_row[column], 1e-6);
            try expectApproxEqAbs(states[transition * features + column], input_row[features + column], 1e-6);
        }
    }
}

test "gpu learn: one update of the critic moves every head's prediction toward its target" {
    // The targets check's hand-made batch - one row, three steps, two transitions, the target heads predicting known
    // values (e - 1 and e^2 - 1) - and the online heads as they start, predicting about nothing. One update, at a
    // learning rate large enough to see in one step: every online head's prediction at every transition, read again
    // afterwards, is closer to its target than before, and on the target's side.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const Critic: type = latent_kit.LatentCritic(zn_mlp);
    const features: u32 = 8;
    const steps: u32 = 3;
    const source: Critic.Source = .{
        .features = features,
        .rows = 1,
        .steps = steps,
        .states_at = 0,
        .goals_at = 32,
        .norm_at = 64,
        .barrier = .{},
        .barrier_head_column = 2,
        .barrier_up_column = 5,
    };
    var layout: kit_mlp.KitLayout = .{ .acts_floats = 128 };
    const critic: Critic = try .init(arena, &layout, source, .{
        .heads = 2,
        .hidden = 8,
        .discount = 0.9,
        .learning_rate = 0.05,
    });
    // Each online head's predictions, read again after the update.
    const first_head_predictions_at: u32 = layout.reserveActs(critic.transitions);
    const second_head_predictions_at: u32 = layout.reserveActs(critic.transitions);
    const prediction_offsets: [2]u32 = .{ first_head_predictions_at, second_head_predictions_at };
    const chosen_bins = [2]usize{ 55, 60 };
    for (critic.target_mlps, chosen_bins) |target_mlp, chosen_bin| {
        const tensors: []const zn.Tensor(f32) = (try target_mlp.params(arena)).tensors;
        const output_bias: []f32 = tensors[tensors.len - 1].data;
        @memset(output_bias, 0);
        output_bias[chosen_bin] = 30;
    }
    const params: []f32 = try arena.alloc(f32, layout.params_floats);
    critic.writeParams(params);
    const zero_moments: []f32 = try arena.alloc(f32, layout.params_floats);
    @memset(zero_moments, 0);
    const host_acts: []f32 = try arena.alloc(f32, layout.acts_floats);
    @memset(host_acts, 0);
    for (0..steps * features) |index| {
        host_acts[source.states_at + index] = 0.4 * @sin(0.7 * float(index) + 0.3);
        host_acts[source.goals_at + index] = 0.3 * @cos(0.5 * float(index));
    }
    for (0..features) |column| {
        host_acts[source.norm_at + column] = 0;
        host_acts[source.norm_at + features + column] = 1;
    }
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = layout.largestBuffer();
    pipe.upload(.params, params);
    pipe.upload(.adam_m, zero_moments);
    pipe.upload(.adam_v, zero_moments);
    pipe.upload(.acts, host_acts);
    // Before: each online head's predictions where the transitions start.
    const input_row_width: u32 = 2 * features;
    var before: [2][2]f32 = undefined;
    critic.computeTargets(&pipe);
    for (critic.head_passes, prediction_offsets, 0..) |head_pass, prediction_offset, head_index| {
        head_pass.forward(&pipe, critic.inputs_at, input_row_width);
        bmpc_kit.decodeTwoHotRows(zn_mlp, &pipe, head_pass, critic.bins, prediction_offset);
        const device_acts: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
        before[head_index] = device_acts[prediction_offset..][0..2].*;
    }
    // One update, then the predictions again.
    critic.update(&pipe, 1);
    const targets_acts: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
    const targets: [2]f32 = targets_acts[critic.targets_at..][0..2].*;
    for (critic.head_passes, prediction_offsets, 0..) |head_pass, prediction_offset, head_index| {
        head_pass.forward(&pipe, critic.inputs_at, input_row_width);
        bmpc_kit.decodeTwoHotRows(zn_mlp, &pipe, head_pass, critic.bins, prediction_offset);
        const device_acts: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
        const after: [2]f32 = device_acts[prediction_offset..][0..2].*;
        for (before[head_index], after, targets) |old_prediction, new_prediction, target| {
            try expect(@abs(new_prediction - target) < @abs(old_prediction - target));
            try expect(new_prediction > old_prediction);
        }
    }
}

test "gpu learn: the value tail's gradient is its value's, by central differences; a zero critic adds exactly nothing" {
    // `LatentCritic.Tail` on two windows' last states of six features. First the critic as it starts - its heads'
    // last layers zero, so its value is the same everywhere: the tail must leave a state gradient filled with
    // arbitrary numbers bit for bit as it was. Then the heads' last layers given small weights: the gradient the tail
    // adds in every state feature, against central differences of the tail's value (weight / (rows x heads) x the
    // sum of every head's decoded value), the value taken by the kit's own forward at the perturbed states.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const Critic: type = latent_kit.LatentCritic(zn_mlp);
    const features: u32 = 6;
    const rows: u32 = 2;
    const source: Critic.Source = .{
        .features = features,
        .rows = rows,
        .steps = 2,
        .states_at = 0,
        .goals_at = 0,
        .norm_at = 0,
        .barrier = .{},
        .barrier_head_column = 0,
        .barrier_up_column = 0,
    };
    var layout: kit_mlp.KitLayout = .{ .acts_floats = 64, .dacts_floats = 64 };
    const critic: Critic = try .init(arena, &layout, source, .{ .heads = 2, .hidden = 8 });
    var tail: Critic.Tail = try critic.initTail(arena, &layout, rows);
    tail.weight = 1.3;
    // The batch: goals and states at the window's end in acts, the state gradient in dacts, the values' scratch.
    const goals_at: u32 = 0;
    const states_at: u32 = 16;
    const gradient_at: u32 = 0;
    const values_at: u32 = layout.reserveActs(2 * rows);
    const host_acts: []f32 = try arena.alloc(f32, layout.acts_floats);
    @memset(host_acts, 0);
    for (0..rows * features) |index| {
        host_acts[goals_at + index] = 0.3 * @cos(0.9 * float(index));
        host_acts[states_at + index] = 0.5 * @sin(0.6 * float(index) + 0.2);
    }
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = layout.largestBuffer();
    // 1. The critic as it starts: nothing added, to the bit.
    const params: []f32 = try arena.alloc(f32, layout.params_floats);
    critic.writeParams(params);
    pipe.upload(.params, params);
    pipe.upload(.acts, host_acts);
    var arbitrary_gradient: [rows * features]f32 = undefined;
    for (&arbitrary_gradient, 0..) |*value, index| {
        value.* = 0.01 * float(index) - 0.05;
    }
    const zero_dacts: []f32 = try arena.alloc(f32, layout.dacts_floats);
    @memset(zero_dacts, 0);
    @memcpy(zero_dacts[gradient_at..][0 .. rows * features], &arbitrary_gradient);
    pipe.upload(.dacts, zero_dacts);
    tail.addGradient(&pipe, goals_at, states_at, gradient_at, false);
    const dacts_after_zero_critic: []const f32 = pipe.readLatest(.dacts) orelse return error.NoReadback;
    const untouched: []const f32 = dacts_after_zero_critic[gradient_at..][0 .. rows * features];
    for (arbitrary_gradient, untouched) |before, after| {
        try expectEqual(@as(u32, @bitCast(before)), @as(u32, @bitCast(after)));
    }
    // 2. Small last-layer weights: a value that depends on the state, and its gradient.
    for (critic.mlps) |mlp| {
        const tensors: []const zn.Tensor(f32) = (try mlp.params(arena)).tensors;
        for (tensors[tensors.len - 2].data, 0..) |*weight, index| {
            weight.* = 0.4 * @sin(1.7 * float(index) + 0.5);
        }
    }
    critic.writeParams(params);
    pipe.upload(.params, params);
    @memset(zero_dacts, 0);
    pipe.upload(.dacts, zero_dacts);
    tail.addGradient(&pipe, goals_at, states_at, gradient_at, false);
    const dacts_after_tail: []const f32 = pipe.readLatest(.dacts) orelse return error.NoReadback;
    const tail_gradient: []const f32 = try arena.dupe(f32, dacts_after_tail[gradient_at..][0 .. rows * features]);
    // The tail's value at a set of states, by the kit's forward.
    const difference_step: f32 = 1e-2;
    const weight_per_value: f32 = tail.weight / float(rows * 2);
    var largest_gradient: f32 = 0;
    for (0..rows * features) |state_index| {
        var value_at_side: [2]f32 = undefined;
        for ([2]f32{ difference_step, -difference_step }, &value_at_side) |offset, *side_value| {
            host_acts[states_at + state_index] += offset;
            pipe.uploadAt(.acts, states_at, host_acts[states_at..][0 .. rows * features]);
            tail.forwardValues(&pipe, goals_at, states_at, values_at);
            const acts_now: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
            const decoded: []const f32 = acts_now[values_at..][0 .. 2 * rows];
            var value_sum: f32 = 0;
            for (decoded) |head_value| {
                value_sum += head_value;
            }
            side_value.* = weight_per_value * value_sum;
            host_acts[states_at + state_index] -= offset;
        }
        const numeric: f32 = (value_at_side[0] - value_at_side[1]) / (2 * difference_step);
        try expectApproxEqAbs(numeric, tail_gradient[state_index], 2e-3 + 1e-2 * @abs(numeric));
        largest_gradient = @max(largest_gradient, @abs(tail_gradient[state_index]));
    }
    try expect(largest_gradient > 1e-3);
    // 3. Pessimism: the same critic, the tail reading the heads' mean plus 0.7 of their spread - its gradient against
    // central differences of that value, per row mean + beta x spread over the two heads, averaged over the rows.
    tail.pessimism = 0.7;
    @memset(zero_dacts, 0);
    pipe.upload(.dacts, zero_dacts);
    pipe.uploadAt(.acts, states_at, host_acts[states_at..][0 .. rows * features]);
    tail.addGradient(&pipe, goals_at, states_at, gradient_at, false);
    const dacts_after_pessimism: []const f32 = pipe.readLatest(.dacts) orelse return error.NoReadback;
    const pessimistic_rows: []const f32 = dacts_after_pessimism[gradient_at..][0 .. rows * features];
    const pessimistic_gradient: []const f32 = try arena.dupe(f32, pessimistic_rows);
    const weight_per_row: f32 = tail.weight / float(rows);
    for (0..rows * features) |state_index| {
        var pessimistic_value_at_side: [2]f32 = undefined;
        for ([2]f32{ difference_step, -difference_step }, &pessimistic_value_at_side) |offset, *side_value| {
            host_acts[states_at + state_index] += offset;
            pipe.uploadAt(.acts, states_at, host_acts[states_at..][0 .. rows * features]);
            tail.forwardValues(&pipe, goals_at, states_at, values_at);
            const acts_now: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
            const decoded: []const f32 = acts_now[values_at..][0 .. 2 * rows];
            var row_sum: f32 = 0;
            for (0..rows) |row| {
                const first_head: f32 = decoded[row];
                const second_head: f32 = decoded[rows + row];
                const mean: f32 = (first_head + second_head) / 2;
                const spread: f32 = @abs(first_head - second_head) / 2;
                row_sum += mean + tail.pessimism * spread;
            }
            side_value.* = weight_per_row * row_sum;
            host_acts[states_at + state_index] -= offset;
        }
        const numeric: f32 = (pessimistic_value_at_side[0] - pessimistic_value_at_side[1]) / (2 * difference_step);
        try expectApproxEqAbs(numeric, pessimistic_gradient[state_index], 2e-3 + 1e-2 * @abs(numeric));
    }
}

test "gpu learn: the flow on the kit is zimrrl's - the sampler's actions, the flow matching and FlowDPG gradients" {
    // `kit_mlp.KitFlow` over the velocity network of a `zimrrl.FlowPolicy` (f32): three rows, four observed numbers,
    // two actions, two hidden layers of 8, four Euler steps, three sine-cosine pairs of time. The sampler's actions
    // against zimrrl's sampled on its graph from the same conditions and noise; the flow matching gradient and
    // FlowDPG's (alpha 0.3, anchor 0.5, a cost gradient per action) against the graph's autodiff of the same losses -
    // every weight's gradient, to rounding.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const Flow: type = zrl.FlowPolicy(f32);
    const KitFlow: type = kit_mlp.KitFlow(zn_mlp);
    const condition_width: u32 = 4;
    const action_width: u32 = 2;
    const rows: u32 = 3;
    const hidden: []const usize = &.{ 8, 8 };
    const flow_options: Flow.Options = .{ .euler_steps = 4, .time_frequencies = 3, .starts_at_zero_velocity = false };
    const flow: Flow = try .init(arena, zn.Rng.init(11), condition_width, action_width, hidden, flow_options);
    var layout: kit_mlp.KitLayout = .{};
    const kit_flow: KitFlow = try .init(arena, &layout, flow.velocity, condition_width, action_width, .{
        .euler_steps = 4,
        .time_frequencies = 3,
    });
    const sampler: KitFlow.Sampler = try kit_flow.initSampler(arena, &layout, rows);
    const trainer: KitFlow.Trainer = try kit_flow.initTrainer(arena, &layout, rows);
    const sampled_actions_at: u32 = layout.reserveActs(rows * action_width);
    layout.requireFitsKit(zn_mlp);
    const params: []f32 = try arena.alloc(f32, layout.params_floats);
    kit_flow.network.writeParams(flow.velocity, params);
    // The data: conditions, noise, actions, times and cost gradients.
    var conditions: [rows * condition_width]f32 = undefined;
    for (&conditions, 0..) |*value, index| {
        value.* = 0.7 * @sin(0.9 * float(index) + 0.1);
    }
    var noise: [rows * action_width]f32 = undefined;
    var actions: [rows * action_width]f32 = undefined;
    var cost_gradients: [rows * action_width]f32 = undefined;
    for (&noise, &actions, &cost_gradients, 0..) |*noise_value, *action_value, *gradient_value, index| {
        noise_value.* = 0.8 * @cos(1.3 * float(index));
        action_value.* = 0.5 * @sin(0.4 * float(index) + 1.0);
        gradient_value.* = 0.6 * @cos(0.7 * float(index) + 0.5);
    }
    const times = [rows]f32{ 0.15, 0.5, 0.85 };
    const host_acts: []f32 = try arena.alloc(f32, layout.acts_floats);
    @memset(host_acts, 0);
    kit_flow.writeSamplerInputs(host_acts, sampler, &conditions, &noise);
    const width: u32 = kit_flow.wideRowWidth();
    for (0..rows) |row| {
        const training_row_start: usize = trainer.wide_rows_at + row * width;
        const row_condition: []const f32 = conditions[row * condition_width ..][0..condition_width];
        @memcpy(host_acts[training_row_start..][0..condition_width], row_condition);
    }
    @memcpy(host_acts[trainer.actions_at..][0 .. rows * action_width], &actions);
    @memcpy(host_acts[trainer.noise_at..][0 .. rows * action_width], &noise);
    @memcpy(host_acts[trainer.times_at..][0..rows], &times);
    @memcpy(host_acts[trainer.cost_gradients_at..][0 .. rows * action_width], &cost_gradients);
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = layout.largestBuffer();
    pipe.upload(.params, params);
    pipe.upload(.acts, host_acts);
    const params_start: u32 = kit_flow.network.paramsStart();
    const params_end: u32 = kit_flow.network.paramsEnd();
    // 1. The sampler.
    kit_flow.sample(&pipe, sampler, .packedRows(sampled_actions_at, action_width));
    const acts_after_sampling: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
    const kit_actions: []const f32 = acts_after_sampling[sampled_actions_at..][0 .. rows * action_width];
    var graph: zn.Graph(f32) = .init(arena);
    const frozen_parameters: []const zn.Var = try flow.velocity.bind(&graph, .frozen, arena);
    const condition_copy: []f32 = try arena.dupe(f32, &conditions);
    const condition_tensor: zn.Tensor(f32) = try .fromSlice(condition_copy, &.{ rows, condition_width });
    const noise_tensor: zn.Tensor(f32) = try .fromSlice(try arena.dupe(f32, &noise), &.{ rows, action_width });
    const graph_actions: zn.Var = try flow.sample(arena, &graph, frozen_parameters, condition_tensor, noise_tensor);
    for (graph.valueOf(graph_actions).data, kit_actions) |expected, computed| {
        try expectApproxEqAbs(expected, computed, 1e-5);
    }
    // And on the host, from the host's copy of the weights - the sampler a fleet acts with, from a mirror.
    const input_scratch: []f32 = try arena.alloc(f32, kit_flow.wideRowWidth());
    const layer_scratch: []f32 = try arena.alloc(f32, 2 * kit_flow.network.widestOutput());
    const velocity_scratch: []f32 = try arena.alloc(f32, action_width);
    var host_action: [action_width]f32 = undefined;
    var largest_host_gap: f32 = 0;
    for (0..rows) |row| {
        const row_condition: []const f32 = conditions[row * condition_width ..][0..condition_width];
        const row_noise: []const f32 = noise[row * action_width ..][0..action_width];
        kit_flow.sampleHost(
            params,
            row_condition,
            row_noise,
            input_scratch,
            layer_scratch,
            velocity_scratch,
            &host_action,
        );
        for (host_action, kit_actions[row * action_width ..][0..action_width]) |host_value, kit_value| {
            largest_host_gap = @max(largest_host_gap, @abs(host_value - kit_value));
        }
    }
    try expect(largest_host_gap <= 1e-6);
    // 2. The flow matching gradient.
    kit_flow.flowMatchingGradient(&pipe, trainer, 1, .overwrite);
    const grads_after_matching: []const f32 = pipe.readLatest(.grads) orelse return error.NoReadback;
    const matching_gradients: []const f32 = try arena.dupe(f32, grads_after_matching[params_start..params_end]);
    var matching_graph: zn.Graph(f32) = .init(arena);
    const trained_parameters: []const zn.Var = try flow.velocity.bind(&matching_graph, .trained, arena);
    const matching_loss: zn.Var =
        try flow.flowMatchingLoss(arena, &matching_graph, trained_parameters, &conditions, &actions, &noise, &times);
    try matching_graph.backward(matching_loss);
    var gradient_start: usize = 0;
    for (trained_parameters) |parameter| {
        const expected_gradient: zn.Tensor(f32) = try matching_graph.gradOf(parameter);
        const computed_gradient: []const f32 = matching_gradients[gradient_start..][0..expected_gradient.data.len];
        for (expected_gradient.data, computed_gradient) |expected, computed| {
            try expectApproxEqAbs(expected, computed, 1e-5);
        }
        gradient_start += expected_gradient.data.len;
    }
    // 3. FlowDPG's gradient: the loss mean |v - u*|^2 + 0.5 mean |v - u|^2, u* from zimrrl's targets at v^ = v.
    kit_flow.flowDpgGradient(&pipe, trainer, 0.3, 0, 0.5, .overwrite);
    const grads_after_dpg: []const f32 = pipe.readLatest(.grads) orelse return error.NoReadback;
    const dpg_gradients: []const f32 = try arena.dupe(f32, grads_after_dpg[params_start..params_end]);
    var dpg_graph: zn.Graph(f32) = .init(arena);
    const dpg_parameters: []const zn.Var = try flow.velocity.bind(&dpg_graph, .trained, arena);
    var points: [rows * action_width]f32 = undefined;
    const path_velocities: zn.Tensor(f32) = try .alloc(arena, &.{ rows, action_width });
    flow.pathPointsAndVelocities(&actions, &noise, &times, &points, path_velocities.data);
    const velocity_inputs: zn.Tensor(f32) = try flow.velocityInputs(arena, &conditions, &points, &times);
    const velocity_input_var: zn.Var = try dpg_graph.constant(velocity_inputs);
    const velocity_var: zn.Var = try flow.velocityAt(&dpg_graph, dpg_parameters, velocity_input_var);
    const dpg_targets: zn.Tensor(f32) = try .alloc(arena, &.{ rows, action_width });
    const velocities_there: []const f32 = dpg_graph.valueOf(velocity_var).data;
    flow.flowDpgTargets(&actions, &noise, &times, velocities_there, &cost_gradients, 0.3, 0, dpg_targets.data);
    const target_term: zn.Var = try dpg_graph.mseLoss(velocity_var, try dpg_graph.constant(dpg_targets));
    const anchor_term: zn.Var = try dpg_graph.mseLoss(velocity_var, try dpg_graph.constant(path_velocities));
    const dpg_loss: zn.Var = try dpg_graph.add(target_term, try dpg_graph.scale(anchor_term, 0.5));
    try dpg_graph.backward(dpg_loss);
    gradient_start = 0;
    for (dpg_parameters) |parameter| {
        const expected_gradient: zn.Tensor(f32) = try dpg_graph.gradOf(parameter);
        const computed_gradient: []const f32 = dpg_gradients[gradient_start..][0..expected_gradient.data.len];
        for (expected_gradient.data, computed_gradient) |expected, computed| {
            try expectApproxEqAbs(expected, computed, 1e-5);
        }
        gradient_start += expected_gradient.data.len;
    }
}

test "gpu learn: MPPI's relative temperature weighs the elites alike whatever the scores' scale" {
    // One state, eight candidates' scores, four elites, temperature 2. Relative to the elites' spread, the weights of
    // the scores and of the same scores x 100 agree to rounding, and the worst elite weighs exp(-2) of the best; with
    // the absolute rule, scaling the scores changes the weights - the control showing the mode does something.
    const candidate_count: u32 = 8;
    const elite_count: u32 = 4;
    const scores_at: u32 = 0;
    const elites_at: u32 = 16;
    const weights_at: u32 = 32;
    const scores = [candidate_count]f32{ -0.031, -0.052, -0.017, -0.044, -0.020, -0.090, -0.025, -0.060 };
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = 64;
    var weights_by_case: [3][elite_count]f32 = undefined;
    const cases = [3]struct { scale: f32, mode: zn_mlp.MppiTemperature }{
        .{ .scale = 1, .mode = .relative_to_elites },
        .{ .scale = 100, .mode = .relative_to_elites },
        .{ .scale = 100, .mode = .absolute },
    };
    for (cases, &weights_by_case) |case, *case_weights| {
        var acts: [64]f32 = @splat(0);
        for (scores, 0..) |score, index| {
            acts[scores_at + index] = case.scale * score;
        }
        pipe.upload(.acts, &acts);
        pipe.params = .{
            .rows = 1,
            .plan_candidates = candidate_count,
            .mppi_elites = elite_count,
            .mppi_temperature = 2,
            .mppi_temperature_mode = @backingInt(case.mode),
            .x_off = scores_at,
            .y_off = elites_at,
            .z_off = weights_at,
        };
        pipe.run("mppi_elites", 1);
        const read: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
        @memcpy(case_weights, read[weights_at..][0..elite_count]);
    }
    for (weights_by_case[0], weights_by_case[1]) |unscaled, scaled| {
        try expectApproxEqAbs(unscaled, scaled, 1e-6);
    }
    try expectApproxEqAbs(@exp(@as(f32, -2)), weights_by_case[0][elite_count - 1] / weights_by_case[0][0], 1e-5);
    var absolute_differs: bool = false;
    for (weights_by_case[0], weights_by_case[2]) |relative_weight, absolute_weight| {
        absolute_differs = absolute_differs or @abs(relative_weight - absolute_weight) > 1e-3;
    }
    try expect(absolute_differs);
}

test "gpu learn: MPPI's warm start moves a plan forward by the steps since it was decided" {
    // `mppi_begin`'s worked rows: a plan of four steps with one action, [0.2, 0.5, -0.1, 0.7] - shifted by 1, by 2,
    // and started cold - and every spread set to the ceiling.
    const horizon: u32 = 4;
    const flags_at: u32 = 0;
    const means_at: u32 = 4;
    const spreads_at: u32 = 8;
    const plan = [horizon]f32{ 0.2, 0.5, -0.1, 0.7 };
    const Case = struct { shift: u32, warm: bool, expected: [horizon]f32 };
    const cases = [3]Case{
        .{ .shift = 1, .warm = true, .expected = .{ 0.5, -0.1, 0.7, 0 } },
        .{ .shift = 2, .warm = true, .expected = .{ -0.1, 0.7, 0, 0 } },
        .{ .shift = 1, .warm = false, .expected = .{ 0, 0, 0, 0 } },
    };
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = 16;
    for (cases) |case| {
        var acts: [16]f32 = @splat(0);
        acts[flags_at] = if (case.warm) 1 else 0;
        @memcpy(acts[means_at..][0..horizon], &plan);
        pipe.upload(.acts, &acts);
        pipe.params = .{
            .rows = 1,
            .out_dim = 1,
            .plan_horizon = horizon,
            .mppi_max_spread = 2,
            .mppi_warm_shift = case.shift,
            .x_off = flags_at,
            .t_off = means_at,
            .u_off = spreads_at,
        };
        pipe.run("mppi_begin", 1);
        const read: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
        try expectEqualSlices(f32, &case.expected, read[means_at..][0..horizon]);
        for (read[spreads_at..][0..horizon]) |spread| {
            try expectEqual(@as(f32, 2), spread);
        }
    }
}

/// Trains a flow by flow matching alone on `rows` rows that share `condition`, row r's action `planned_actions` row r
/// (each row of `action_width`): every update a fresh noise and flow time per row, the gradient, a clipped Adam step.
/// Returns the trained parameters, read back. The distillation rule of teacher 2, on its own.
fn trainFlowOnPlans(
    arena: Allocator,
    flow: zrl.FlowPolicy(f32),
    kit_flow: kit_mlp.KitFlow(zn_mlp),
    layout: *kit_mlp.KitLayout,
    condition: []const f32,
    planned_actions: []const f32,
    rows: u32,
    updates: u32,
) ![]const f32 {
    const KitFlow: type = kit_mlp.KitFlow(zn_mlp);
    const trainer: KitFlow.Trainer = try kit_flow.initTrainer(arena, layout, rows);
    const params_start: u32 = kit_flow.network.paramsStart();
    const params_count: u32 = kit_flow.network.paramsEnd() - params_start;
    const optimizer: kit_mlp.ClippedAdam = .reserve(layout, params_start, params_count);
    layout.requireFitsKit(zn_mlp);
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = layout.largestBuffer();
    const params: []f32 = try arena.alloc(f32, layout.params_floats);
    @memset(params, 0);
    kit_flow.network.writeParams(flow.velocity, params);
    pipe.upload(.params, params);
    const zeros: []f32 = try arena.alloc(f32, layout.params_floats);
    @memset(zeros, 0);
    pipe.upload(.adam_m, zeros);
    pipe.upload(.adam_v, zeros);
    // The rows' conditions and actions, the same every update.
    const host_acts: []f32 = try arena.alloc(f32, layout.acts_floats);
    @memset(host_acts, 0);
    const width: u32 = kit_flow.wideRowWidth();
    const action_width: u32 = kit_flow.action_width;
    for (0..rows) |row| {
        @memcpy(host_acts[trainer.wide_rows_at + row * width ..][0..condition.len], condition);
    }
    @memcpy(host_acts[trainer.actions_at..][0 .. rows * action_width], planned_actions);
    pipe.upload(.acts, host_acts);
    var generator: Random.DefaultPrng = .init(57);
    const random: Random = generator.random();
    const noise: []f32 = try arena.alloc(f32, rows * action_width);
    const times: []f32 = try arena.alloc(f32, rows);
    for (1..updates + 1) |update| {
        for (noise) |*value| {
            value.* = random.floatNorm(f32);
        }
        for (times) |*value| {
            value.* = random.float(f32);
        }
        pipe.uploadAt(.acts, trainer.noise_at, noise);
        pipe.uploadAt(.acts, trainer.times_at, times);
        kit_flow.flowMatchingGradient(&pipe, trainer, 1, .overwrite);
        optimizer.step(zn_mlp, &pipe, .{ .learning_rate = 3e-3 }, @intCast(update));
    }
    const trained: []const f32 = pipe.readLatest(.params) orelse return error.NoReadback;
    return arena.dupe(f32, trained[0..layout.params_floats]);
}

test "gpu learn: a flow distilled from one plan acts it out from any noise" {
    // Teacher 2's rule alone: 64 rows of one situation, each with the same planned action (0.4, -0.3); 1200 updates
    // of flow matching from a flow at rest. Its flow carries every noise onto that one action: eight samples from eight
    // different noises all land within 0.05 of it.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const Flow: type = zrl.FlowPolicy(f32);
    const KitFlow: type = kit_mlp.KitFlow(zn_mlp);
    const hidden: []const usize = &.{ 32, 32 };
    const flow: Flow = try .init(arena, zn.Rng.init(41), 3, 2, hidden, .{});
    var layout: kit_mlp.KitLayout = .{};
    const kit_flow: KitFlow = try .init(arena, &layout, flow.velocity, 3, 2, .{});
    const condition = [3]f32{ 0.2, -0.5, 0.9 };
    const plan = [2]f32{ 0.4, -0.3 };
    const rows: u32 = 64;
    const planned_actions: []f32 = try arena.alloc(f32, rows * 2);
    for (0..rows) |row| {
        @memcpy(planned_actions[row * 2 ..][0..2], &plan);
    }
    const params: []const f32 =
        try trainFlowOnPlans(arena, flow, kit_flow, &layout, &condition, planned_actions, rows, 1200);
    const input_scratch: []f32 = try arena.alloc(f32, kit_flow.wideRowWidth());
    const layer_scratch: []f32 = try arena.alloc(f32, 2 * kit_flow.network.widestOutput());
    var velocity_scratch: [2]f32 = undefined;
    var action: [2]f32 = undefined;
    var generator: Random.DefaultPrng = .init(91);
    const random: Random = generator.random();
    for (0..8) |_| {
        const noise = [2]f32{ random.floatNorm(f32), random.floatNorm(f32) };
        kit_flow.sampleHost(params, &condition, &noise, input_scratch, layer_scratch, &velocity_scratch, &action);
        for (action, plan) |acted, planned| {
            try expectApproxEqAbs(planned, acted, 0.05);
        }
    }
}

test "gpu learn: a flow distilled from two plans keeps both ways, and not their average" {
    // Two plans for the same situation - a step one way, 0.6, and the other, -0.6 - half the rows each; 1500 updates
    // of flow matching. A regression would learn their average, 0: no step at all. The flow carries part of the noise
    // to each: of 200 samples, at least 80% land within 0.2 of one plan or the other, each plan gets at least a
    // quarter, and few land in between. EIGHT Euler steps: the flow's paths from one noise distribution to two modes
    // bend - the noise is split at a sharp boundary midway - and four straight steps cut across the bends, leaving the
    // noises near the boundary between the modes (76% near a plan, 10% between); eight follow them (94%, 1.5%).
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const Flow: type = zrl.FlowPolicy(f32);
    const KitFlow: type = kit_mlp.KitFlow(zn_mlp);
    const hidden: []const usize = &.{ 32, 32 };
    const flow: Flow = try .init(arena, zn.Rng.init(43), 2, 1, hidden, .{ .euler_steps = 8 });
    var layout: kit_mlp.KitLayout = .{};
    const kit_flow: KitFlow = try .init(arena, &layout, flow.velocity, 2, 1, .{ .euler_steps = 8 });
    const condition = [2]f32{ 0.3, -0.7 };
    const rows: u32 = 64;
    const planned_actions: []f32 = try arena.alloc(f32, rows);
    for (planned_actions, 0..) |*planned, row| {
        planned.* = if (row % 2 == 0) 0.6 else -0.6;
    }
    const params: []const f32 =
        try trainFlowOnPlans(arena, flow, kit_flow, &layout, &condition, planned_actions, rows, 1500);
    const input_scratch: []f32 = try arena.alloc(f32, kit_flow.wideRowWidth());
    const layer_scratch: []f32 = try arena.alloc(f32, 2 * kit_flow.network.widestOutput());
    var velocity_scratch: [1]f32 = undefined;
    var action: [1]f32 = undefined;
    var generator: Random.DefaultPrng = .init(93);
    const random: Random = generator.random();
    const sample_count: u32 = 200;
    var near_first: u32 = 0;
    var near_second: u32 = 0;
    var in_between: u32 = 0;
    for (0..sample_count) |_| {
        const noise = [1]f32{random.floatNorm(f32)};
        kit_flow.sampleHost(params, &condition, &noise, input_scratch, layer_scratch, &velocity_scratch, &action);
        near_first += @intFromBool(@abs(action[0] - 0.6) < 0.2);
        near_second += @intFromBool(@abs(action[0] + 0.6) < 0.2);
        in_between += @intFromBool(@abs(action[0]) < 0.2);
    }
    report.print("\n  two plans distilled: {d} near 0.6, {d} near -0.6, {d} between, of {d}\n", .{
        near_first,
        near_second,
        in_between,
        sample_count,
    });
    try expect(near_first + near_second >= sample_count * 8 / 10);
    try expect(near_first >= sample_count / 4 and near_second >= sample_count / 4);
    try expect(in_between <= sample_count / 10);
}

test "gpu learn: the kit's draw losses are zimrrl's - each example's flow matching loss, averaged over its draws" {
    // FPO's stand-in for a negative log-likelihood, on the kit and on zimrrl's graph: a moving flow, three examples,
    // four draws each, the same conditions, actions, noises and times on both sides. The kit's trainer holds each
    // example's condition and action in its four consecutive rows, as the learner lays them out; its losses must be
    // the graph's to f32 rounding.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const Flow: type = zrl.FlowPolicy(f32);
    const KitFlow: type = kit_mlp.KitFlow(zn_mlp);
    const condition_width: usize = 3;
    const action_width: usize = 2;
    const examples: usize = 3;
    const draws: usize = 4;
    const hidden: []const usize = &.{8};
    const flow: Flow = try .init(arena, zn.Rng.init(71), condition_width, action_width, hidden, .{
        .starts_at_zero_velocity = false,
    });
    var layout: kit_mlp.KitLayout = .{};
    const kit_flow: KitFlow = try .init(arena, &layout, flow.velocity, condition_width, action_width, .{});
    const trainer: KitFlow.Trainer = try kit_flow.initTrainer(arena, &layout, examples * draws);
    const losses_at: u32 = layout.reserveActs(examples);
    layout.requireFitsKit(zn_mlp);
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = layout.largestBuffer();
    const params: []f32 = try arena.alloc(f32, layout.params_floats);
    @memset(params, 0);
    kit_flow.network.writeParams(flow.velocity, params);
    pipe.upload(.params, params);
    // The examples and their draws.
    var generator: Random.DefaultPrng = .init(72);
    const random: Random = generator.random();
    var conditions: [examples * condition_width]f32 = undefined;
    var actions: [examples * action_width]f32 = undefined;
    var draw_noise: [examples * draws * action_width]f32 = undefined;
    var draw_times: [examples * draws]f32 = undefined;
    for (&conditions) |*value| {
        value.* = random.floatNorm(f32);
    }
    for (&actions) |*value| {
        value.* = random.floatNorm(f32);
    }
    for (&draw_noise) |*value| {
        value.* = random.floatNorm(f32);
    }
    for (&draw_times) |*value| {
        value.* = random.float(f32);
    }
    // The kit's rows: each example's condition and action in its draws' rows.
    const host_acts: []f32 = try arena.alloc(f32, layout.acts_floats);
    @memset(host_acts, 0);
    const wide_width: usize = kit_flow.wideRowWidth();
    for (0..examples) |example| {
        for (0..draws) |draw| {
            const row: usize = example * draws + draw;
            const condition: []const f32 = conditions[example * condition_width ..][0..condition_width];
            @memcpy(host_acts[trainer.wide_rows_at + row * wide_width ..][0..condition_width], condition);
            const action: []const f32 = actions[example * action_width ..][0..action_width];
            @memcpy(host_acts[trainer.actions_at + row * action_width ..][0..action_width], action);
        }
    }
    @memcpy(host_acts[trainer.noise_at..][0..draw_noise.len], &draw_noise);
    @memcpy(host_acts[trainer.times_at..][0..draw_times.len], &draw_times);
    pipe.upload(.acts, host_acts);
    kit_flow.drawLosses(&pipe, trainer, draws, losses_at);
    const acts: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
    const kit_losses: []const f32 = acts[losses_at..][0..examples];
    // zimrrl's, on the graph.
    var graph: zn.Graph(f32) = .init(arena);
    const frozen: []const zn.Var = try flow.velocity.bind(&graph, .frozen, arena);
    const reference: zn.Var =
        try flow.drawLosses(arena, &graph, frozen, &conditions, &actions, &draw_noise, &draw_times);
    const reference_losses: []const f32 = graph.valueOf(reference).data;
    for (kit_losses, reference_losses) |kit_loss, reference_loss| {
        try expect(reference_loss > 0);
        try expectApproxEqAbs(reference_loss, kit_loss, 1e-5 * @max(1, reference_loss));
    }
}

test "gpu learn: the kit's FPO gradient is zimrrl's - PPO's clipped surrogate on a flow, a clipped example included" {
    // A moving flow, three examples of four draws. Example 0 at its old weights (ratio exactly 1, advantage +1);
    // example 1 likewise with a negative advantage; example 2 with its old loss raised by 0.5, so its ratio e^0.5 is
    // past the clip in the improving direction - it must contribute nothing, its draws' velocity gradient zero. The
    // kit's gradient on the flow's weights must be autodiff's of zimrrl's `fpoLoss` on the same draws, old losses and
    // advantages - the graph's gradients laid out in the kit's order by `writeParams` itself - to f32 rounding.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const Flow: type = zrl.FlowPolicy(f32);
    const KitFlow: type = kit_mlp.KitFlow(zn_mlp);
    const condition_width: usize = 3;
    const action_width: usize = 2;
    const examples: usize = 3;
    const draws: usize = 4;
    const hidden: []const usize = &.{8};
    const flow: Flow = try .init(arena, zn.Rng.init(81), condition_width, action_width, hidden, .{
        .starts_at_zero_velocity = false,
    });
    var layout: kit_mlp.KitLayout = .{};
    const kit_flow: KitFlow = try .init(arena, &layout, flow.velocity, condition_width, action_width, .{});
    const trainer: KitFlow.Trainer = try kit_flow.initTrainer(arena, &layout, examples * draws);
    const fpo_numbers: KitFlow.FpoNumbers = .{
        .old_losses_at = layout.reserveActs(examples),
        .new_losses_at = layout.reserveActs(examples),
        .advantages_at = layout.reserveActs(examples),
    };
    layout.requireFitsKit(zn_mlp);
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = layout.largestBuffer();
    const params: []f32 = try arena.alloc(f32, layout.params_floats);
    @memset(params, 0);
    kit_flow.network.writeParams(flow.velocity, params);
    pipe.upload(.params, params);
    // The examples, their draws, their old losses and advantages.
    var generator: Random.DefaultPrng = .init(82);
    const random: Random = generator.random();
    var conditions: [examples * condition_width]f32 = undefined;
    var actions: [examples * action_width]f32 = undefined;
    var draw_noise: [examples * draws * action_width]f32 = undefined;
    var draw_times: [examples * draws]f32 = undefined;
    for (&conditions) |*value| {
        value.* = random.floatNorm(f32);
    }
    for (&actions) |*value| {
        value.* = random.floatNorm(f32);
    }
    for (&draw_noise) |*value| {
        value.* = random.floatNorm(f32);
    }
    for (&draw_times) |*value| {
        value.* = random.float(f32);
    }
    var old_graph: zn.Graph(f32) = .init(arena);
    const frozen: []const zn.Var = try flow.velocity.bind(&old_graph, .frozen, arena);
    const old_var: zn.Var =
        try flow.drawLosses(arena, &old_graph, frozen, &conditions, &actions, &draw_noise, &draw_times);
    var old_losses: [examples]f32 = old_graph.valueOf(old_var).data[0..examples].*;
    old_losses[2] += 0.5;
    const advantages = [examples]f32{ 1.0, -0.7, 0.8 };
    // The kit: the trainer's rows, as the learner lays them out, and its gradient.
    const host_acts: []f32 = try arena.alloc(f32, layout.acts_floats);
    @memset(host_acts, 0);
    const wide_width: usize = kit_flow.wideRowWidth();
    for (0..examples) |example| {
        for (0..draws) |draw| {
            const row: usize = example * draws + draw;
            const condition: []const f32 = conditions[example * condition_width ..][0..condition_width];
            @memcpy(host_acts[trainer.wide_rows_at + row * wide_width ..][0..condition_width], condition);
            const action: []const f32 = actions[example * action_width ..][0..action_width];
            @memcpy(host_acts[trainer.actions_at + row * action_width ..][0..action_width], action);
        }
    }
    @memcpy(host_acts[trainer.noise_at..][0..draw_noise.len], &draw_noise);
    @memcpy(host_acts[trainer.times_at..][0..draw_times.len], &draw_times);
    @memcpy(host_acts[fpo_numbers.old_losses_at..][0..examples], &old_losses);
    @memcpy(host_acts[fpo_numbers.advantages_at..][0..examples], &advantages);
    pipe.upload(.acts, host_acts);
    kit_flow.fpoGradient(&pipe, trainer, draws, fpo_numbers, 0.2, 1.0, .overwrite);
    const grads: []const f32 = pipe.readLatest(.grads) orelse return error.NoReadback;
    const network = kit_flow.network;
    const kit_gradient: []const f32 = try arena.dupe(f32, grads[network.paramsStart()..network.paramsEnd()]);
    // The clipped example's draws: no gradient at all.
    const dacts: []const f32 = pipe.readLatest(.dacts) orelse return error.NoReadback;
    const clipped_rows_at: usize = trainer.velocity_gradient_at + 2 * draws * action_width;
    const clipped_rows: []const f32 = dacts[clipped_rows_at..][0 .. draws * action_width];
    for (clipped_rows) |value| {
        try expectEqual(@as(f32, 0), value);
    }
    // zimrrl's, on the graph, laid out in the kit's order.
    var graph: zn.Graph(f32) = .init(arena);
    const parameters: []const zn.Var = try flow.velocity.bind(&graph, .trained, arena);
    const loss: zn.Var = try zrl.fpoLoss(
        f32,
        flow,
        arena,
        &graph,
        parameters,
        &conditions,
        &actions,
        &draw_noise,
        &draw_times,
        &old_losses,
        &advantages,
        0.2,
    );
    try graph.backward(loss);
    const tensors: []const zn.Tensor(f32) = (try flow.velocity.params(arena)).tensors;
    for (tensors, parameters) |tensor, parameter| {
        const parameter_gradient: zn.Tensor(f32) = try graph.gradOf(parameter);
        @memcpy(tensor.data, parameter_gradient.data);
    }
    const expected_buffer: []f32 = try arena.alloc(f32, layout.params_floats);
    @memset(expected_buffer, 0);
    network.writeParams(flow.velocity, expected_buffer);
    const expected: []const f32 = expected_buffer[network.paramsStart()..network.paramsEnd()];
    var largest: f32 = 0;
    for (expected, kit_gradient) |expected_value, kit_value| {
        largest = @max(largest, @abs(expected_value));
        try expectApproxEqAbs(expected_value, kit_value, 1e-5 * @max(1, @abs(expected_value)));
    }
    try expect(largest > 0);
}

test "gpu learn: the statistics for the log - each kernel's numbers are the host's arithmetic on planted values" {
    // Planted activations and gradients, each statistic run into a block of the parameter buffer, and each number
    // against the same arithmetic on the host: the root mean square of gradients; the mean squared difference of two
    // regions; the mean and sample deviation; and FPO's ratios - their mean, and the share the clip holds, for three
    // examples whose ratios are below, inside and above the clip with advantages chosen so exactly one is held.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var layout: kit_mlp.KitLayout = .{};
    const count: u32 = 7;
    const first_at: u32 = layout.reserveActs(count);
    const second_at: u32 = layout.reserveActs(count);
    const gradients_at: u32 = layout.reserveDacts(count);
    const old_at: u32 = layout.reserveActs(3);
    const new_at: u32 = layout.reserveActs(3);
    const advantages_at: u32 = layout.reserveActs(3);
    const stats_at: u32 = layout.reserveParams(6);
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = layout.largestBuffer();
    const first = [7]f32{ 0.5, -1.25, 2.0, 0.0, 3.5, -0.75, 1.0 };
    const second = [7]f32{ 0.25, -1.0, 1.5, 0.5, 3.0, -1.25, 0.0 };
    const gradients = [7]f32{ 1.0, -2.0, 0.5, 0.0, -0.25, 3.0, -1.5 };
    // Ratios exp(old - new): about 0.61 (below the clip), 1.0 (inside), 1.65 (above), the clip 0.2.
    const old_losses = [3]f32{ 0.5, 1.0, 1.5 };
    const new_losses = [3]f32{ 1.0, 1.0, 1.0 };
    // Below the clip with a positive advantage: the unclipped term is the smaller, not held. Inside: never held.
    // Above with a positive advantage: the clipped term is the smaller, held.
    const advantages = [3]f32{ 1.0, -0.5, 2.0 };
    const host_acts: []f32 = try arena.alloc(f32, layout.acts_floats);
    @memset(host_acts, 0);
    @memcpy(host_acts[first_at..][0..count], &first);
    @memcpy(host_acts[second_at..][0..count], &second);
    @memcpy(host_acts[old_at..][0..3], &old_losses);
    @memcpy(host_acts[new_at..][0..3], &new_losses);
    @memcpy(host_acts[advantages_at..][0..3], &advantages);
    pipe.upload(.acts, host_acts);
    const host_dacts: []f32 = try arena.alloc(f32, layout.dacts_floats);
    @memset(host_dacts, 0);
    @memcpy(host_dacts[gradients_at..][0..count], &gradients);
    pipe.upload(.dacts, host_dacts);
    pipe.params = .{ .rows = count, .x_off = gradients_at, .stat_off = stats_at };
    pipe.run("stat_root_mean_square", 1);
    pipe.params = .{ .rows = count, .x_off = first_at, .t_off = second_at, .stat_off = stats_at + 1 };
    pipe.run("stat_mean_square_difference", 1);
    pipe.params = .{ .rows = count, .x_off = first_at, .stat_off = stats_at + 2 };
    pipe.run("stat_mean_and_deviation", 1);
    pipe.params = .{
        .rows = 3,
        .x_off = old_at,
        .u_off = new_at,
        .v_off = advantages_at,
        .clip = 0.2,
        .stat_off = stats_at + 4,
    };
    pipe.run("fpo_ratio_stats", 1);
    const params: []const f32 = pipe.readLatest(.params) orelse return error.NoReadback;
    const stats: []const f32 = params[stats_at..][0..6];
    // The host's arithmetic, in the kernels' order.
    var gradient_squares: f32 = 0;
    for (gradients) |value| {
        gradient_squares += value * value;
    }
    try expectApproxEqAbs(@sqrt(gradient_squares / 7.0), stats[0], 1e-6);
    var difference_squares: f32 = 0;
    for (first, second) |a, b| {
        difference_squares += (a - b) * (a - b);
    }
    try expectApproxEqAbs(difference_squares / 7.0, stats[1], 1e-6);
    var sum: f32 = 0;
    for (first) |value| {
        sum += value;
    }
    const mean: f32 = sum / 7.0;
    var squares: f32 = 0;
    for (first) |value| {
        squares += (value - mean) * (value - mean);
    }
    try expectApproxEqAbs(mean, stats[2], 1e-6);
    try expectApproxEqAbs(@sqrt(squares / 6.0), stats[3], 1e-6);
    const ratio_mean: f32 = (@exp(@as(f32, -0.5)) + 1.0 + @exp(@as(f32, 0.5))) / 3.0;
    try expectApproxEqAbs(ratio_mean, stats[4], 1e-6);
    try expectEqual(@as(f32, 1.0 / 3.0), stats[5]);
}

test "gpu learn: the clipped Adam bounds each gradient after the global factor - the first moment holds the bound" {
    // Three weights with planted gradients - far past the element-wise bound, inside it, far past it the other way -
    // the global bound out of the way. After one step Adam's first moment is exactly (1 - beta1) times each gradient
    // as clamped: the bound reached the optimiser, the middle one untouched.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var layout: kit_mlp.KitLayout = .{};
    const params_start: u32 = layout.reserveParams(3);
    const adam: kit_mlp.ClippedAdam = .reserve(&layout, params_start, 3);
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = layout.largestBuffer();
    const zeros: []f32 = try arena.alloc(f32, layout.params_floats);
    @memset(zeros, 0);
    pipe.upload(.params, zeros);
    pipe.upload(.adam_m, zeros);
    pipe.upload(.adam_v, zeros);
    const gradients: []f32 = try arena.alloc(f32, layout.params_floats);
    @memset(gradients, 0);
    gradients[params_start] = 5.0;
    gradients[params_start + 1] = -0.05;
    gradients[params_start + 2] = -3.0;
    pipe.upload(.grads, gradients);
    const settings: kit_mlp.ClippedAdam.Settings = .{ .gradient_clip = 1.0e30, .element_clip = 0.1, .beta1 = 0.9 };
    adam.step(zn_mlp, &pipe, settings, 1);
    const first_moments: []const f32 = pipe.readLatest(.adam_m) orelse return error.NoReadback;
    const expected = [3]f32{ 0.1 * 0.1, 0.1 * -0.05, 0.1 * -0.1 };
    for (expected, first_moments[params_start..][0..3]) |want, got| {
        try expectApproxEqAbs(want, got, 1e-7);
    }
}

test "gpu learn: the critic's and the barrier's statistics - the host's arithmetic on planted values" {
    // The critic's: three heads' values on four rows and the rows' targets - the heads' mean, each row's standard
    // deviation across the heads averaged, and the root mean square error against the targets. The barrier's: two
    // steps of three rows, four features - the head's height in column 0, the up direction in columns 1 to 3, equal
    // to the goal's so the tilt adds nothing - each head at a chosen distance from its goal's; the mean of the
    // head hinges (`zm.smoothHinge`, the tracking cost's own) over the six rows.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var layout: kit_mlp.KitLayout = .{};
    const values_at: u32 = layout.reserveActs(12);
    const targets_at: u32 = layout.reserveActs(4);
    const states_at: u32 = layout.reserveActs(24);
    const goals_at: u32 = layout.reserveActs(24);
    const normaliser_at: u32 = layout.reserveActs(8);
    const stats_at: u32 = layout.reserveParams(4);
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = layout.largestBuffer();
    const values = [12]f32{ 1.0, 2.0, 0.5, -1.0, 1.5, 2.5, 0.0, -0.5, 1.25, 3.0, 1.0, -2.0 };
    const targets = [4]f32{ 1.0, 2.0, 1.0, -1.0 };
    const host_acts: []f32 = try arena.alloc(f32, layout.acts_floats);
    @memset(host_acts, 0);
    @memcpy(host_acts[values_at..][0..12], &values);
    @memcpy(host_acts[targets_at..][0..4], &targets);
    // The barrier's rows: up (0, 0, 1) for state and goal alike; the heads 0.05, 0.3 and 0.6 m above the goal's.
    const head_offsets = [6]f32{ 0.05, 0.3, 0.6, -0.1, -0.35, 0.0 };
    for (head_offsets, 0..) |offset, row| {
        const state_row: *[4]f32 = host_acts[states_at + row * 4 ..][0..4];
        const goal_row: *[4]f32 = host_acts[goals_at + row * 4 ..][0..4];
        state_row.* = .{ 1.0 + offset, 0, 0, 1 };
        goal_row.* = .{ 1.0, 0, 0, 1 };
    }
    // The normaliser: means 0, spreads 1 - the features are the raw numbers.
    @memset(host_acts[normaliser_at..][0..4], 0);
    @memset(host_acts[normaliser_at + 4 ..][0..4], 1);
    pipe.upload(.acts, host_acts);
    pipe.params = .{ .rows = 4, .count = 3, .x_off = values_at, .t_off = targets_at, .stat_off = stats_at };
    pipe.run("critic_value_stats", 1);
    const barrier: latent_kit.FailureBarrier = .{};
    pipe.params = .{
        .rows = 3,
        .out_dim = 4,
        .count = 2,
        .y_off = states_at,
        .t_off = goals_at,
        .u_off = normaliser_at,
        .stat_off = stats_at + 3,
        .barrier_head_column = 0,
        .barrier_up_column = 1,
        .barrier_head_margin = barrier.head_margin,
        .barrier_head_width = barrier.head_width,
        .barrier_tilt_margin = barrier.tilt_margin,
        .barrier_tilt_width = barrier.tilt_width,
    };
    pipe.run("stat_barrier", 1);
    const params: []const f32 = pipe.readLatest(.params) orelse return error.NoReadback;
    const stats: []const f32 = params[stats_at..][0..4];
    // The critic's, by hand: per row the heads are values[head * 4 + row].
    var value_sum: f32 = 0;
    var spread_sum: f32 = 0;
    var error_squares: f32 = 0;
    for (0..4) |row| {
        var row_sum: f32 = 0;
        for (0..3) |head| {
            row_sum += values[head * 4 + row];
        }
        const row_mean: f32 = row_sum / 3.0;
        var row_squares: f32 = 0;
        for (0..3) |head| {
            const value: f32 = values[head * 4 + row];
            row_squares += (value - row_mean) * (value - row_mean);
            error_squares += (value - targets[row]) * (value - targets[row]);
        }
        value_sum += row_sum;
        spread_sum += @sqrt(row_squares / 3.0);
    }
    try expectApproxEqAbs(value_sum / 12.0, stats[0], 1e-6);
    try expectApproxEqAbs(spread_sum / 4.0, stats[1], 1e-6);
    try expectApproxEqAbs(@sqrt(error_squares / 12.0), stats[2], 1e-6);
    // The barrier's: each row's hinges by the cost's own function (`barrierHinges`) on its measures - the head's
    // height error formed as the kernel forms it (the state's height less the goal's, in floats), the up directions
    // equal, so the tilt adds only its smooth hinge's small value at zero error.
    var hinge_sum: f32 = 0;
    for (head_offsets) |offset| {
        const head_height: f32 = 1.0 + offset;
        const measures: zn_mlp.BarrierMeasures = .{
            .height_error = head_height - 1.0,
            .up_dot = 1,
            .up_square = 1,
            .reference_up_square = 1,
        };
        const head_margin: f32 = barrier.head_margin;
        const tilt_margin: f32 = barrier.tilt_margin;
        hinge_sum += zn_mlp.barrierHinges(measures, head_margin, barrier.head_width, tilt_margin, barrier.tilt_width);
    }
    try expect(hinge_sum > 0);
    try expectApproxEqAbs(hinge_sum / 6.0, stats[3], 1e-6);
}

test "gpu learn: the time-to-return cost - SuperTrack's near the reference, the cap far from it" {
    // Two rows of four features, no barrier: one a quarter of a unit from its goal in every feature (a mean square of
    // 1/16), one 30 units (900). With no cap the costs are the mean squares; with a cap of 25 the near one is unchanged
    // to a part in ten thousand and the far one is the cap - `cap x tanh(cost / cap)` on both, as `boundedCost` says.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var layout: kit_mlp.KitLayout = .{};
    const states_at: u32 = layout.reserveActs(8);
    const goals_at: u32 = layout.reserveActs(8);
    const costs_at: u32 = layout.reserveActs(2);
    const capped_at: u32 = layout.reserveActs(2);
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = layout.largestBuffer();
    const host_acts: []f32 = try arena.alloc(f32, layout.acts_floats);
    @memset(host_acts, 0);
    @memset(host_acts[states_at..][0..4], 0.25);
    @memset(host_acts[states_at + 4 ..][0..4], 30);
    pipe.upload(.acts, host_acts);
    const uncapped: latent_kit.TrackingCost = .{
        .features = 4,
        .barrier = .{},
        .barrier_head_column = 0,
        .barrier_up_column = 1,
        .norm_at = 0,
    };
    latent_kit.runTrackingCost(zn_mlp, &pipe, uncapped, 2, states_at, goals_at, costs_at);
    var capped: latent_kit.TrackingCost = uncapped;
    capped.cap = 25;
    latent_kit.runTrackingCost(zn_mlp, &pipe, capped, 2, states_at, goals_at, capped_at);
    const acts: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
    try expectApproxEqAbs(@as(f32, 1.0 / 16.0), acts[costs_at], 1e-6);
    try expectApproxEqAbs(@as(f32, 900), acts[costs_at + 1], 1e-3);
    try expectApproxEqAbs(zn_mlp.boundedCost(1.0 / 16.0, 25), acts[capped_at], 1e-6);
    try expectApproxEqAbs(@as(f32, 1.0 / 16.0), acts[capped_at], 1e-4 * (1.0 / 16.0) + 1e-7);
    try expectApproxEqAbs(@as(f32, 25), acts[capped_at + 1], 1e-4);
}

test "gpu learn: teacher shares - every teacher's gradient at its share, whatever its natural size" {
    // Five parameters and four teachers whose gradients are wildly different in size - lengths 1e-6, 3 and 400, and a
    // fourth that taught nothing (zeros) - given shares 1, 0.5, 0.25 and 1. Each teacher's gradient written over the
    // range, then absorbed; the sum must be  sum share_i x g_i / |g_i|  exactly as the host computes it, the silent
    // teacher adding nothing, and each teacher's natural length left where a statistic reads it.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var layout: kit_mlp.KitLayout = .{};
    const params_start: u32 = layout.reserveParams(5);
    const shares: kit_mlp.TeacherShares = .reserve(&layout, params_start, 5);
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = layout.largestBuffer();
    const directions = [4][5]f32{
        .{ 1, -2, 0, 2, 4 },
        .{ 3, 0, -4, 0, 0 },
        .{ -1, 1, 1, -1, 1 },
        .{ 0, 0, 0, 0, 0 },
    };
    const scales = [4]f32{ 1e-6 / 5.0, 3.0 / 5.0, 400.0 / 2.0, 1 };
    const share_values = [4]f32{ 1, 0.5, 0.25, 1 };
    var expected: [5]f64 = @splat(0);
    const grads_host: []f32 = try arena.alloc(f32, layout.params_floats);
    for (directions, scales, share_values, 0..) |direction, scale, share, teacher| {
        @memset(grads_host, 0);
        var squares: f64 = 0;
        for (direction, 0..) |value, index| {
            const gradient: f32 = value * scale;
            grads_host[params_start + index] = gradient;
            squares += @as(f64, gradient) * gradient;
        }
        pipe.upload(.grads, grads_host);
        shares.absorb(zn_mlp, &pipe, share, teacher == 0);
        const acts_now: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
        const gradient_length: f64 = @sqrt(squares);
        const measured_length: f32 = acts_now[shares.factor_offset];
        try expectApproxEqRel(@as(f32, @floatCast(gradient_length + 1e-30)), measured_length + 1e-30, 1e-5);
        if (gradient_length > 0) {
            for (direction, 0..) |value, index| {
                expected[index] += share * (value * scale) / gradient_length;
            }
        }
    }
    shares.finish(zn_mlp, &pipe);
    const grads: []const f32 = pipe.readLatest(.grads) orelse return error.NoReadback;
    for (expected, 0..) |value, index| {
        try expectApproxEqAbs(@as(f32, @floatCast(value)), grads[params_start + index], 1e-5);
    }
}

test "gpu learn: the skip head's inputs and targets gathered from the world model's rollout" {
    // 3 rows, a window of 8 steps in jumps of 4 (2 jumps), blocks of a 2-column lead, 3 state features and a reference
    // and an action per step, and the world model's second hidden layer 5 wide at every step; every planted value
    // distinct. Each jump's row must be the hidden layer at its first step, then the next 3 steps' reference and action
    // from their blocks; its target the recorded state after its last step less the state its block holds at its
    // start - block 0's for the first jump, block 4's (where a rollout writes its prediction) for the second. Exactly,
    // against the host's own assembly.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const rows: u32 = 3;
    const window: u32 = 8;
    const span: u32 = 4;
    const jumps: u32 = window / span;
    const lead: u32 = 2;
    const features: u32 = 3;
    const step_columns: u32 = 2;
    const hidden: u32 = 5;
    const stride: u32 = lead + features + step_columns;
    const input_width: u32 = hidden + (span - 1) * step_columns;
    const blocks_floats: u32 = (window + 1) * rows * stride;
    const hidden_at: u32 = blocks_floats;
    const hidden_floats: u32 = window * rows * hidden;
    const targets_at: u32 = hidden_at + hidden_floats;
    const targets_floats: u32 = window * rows * features;
    const inputs_at: u32 = targets_at + targets_floats;
    const inputs_floats: u32 = jumps * rows * input_width;
    const changes_at: u32 = inputs_at + inputs_floats;
    const changes_floats: u32 = jumps * rows * features;
    const total_floats: u32 = changes_at + changes_floats;
    const acts: []f32 = try arena.alloc(f32, total_floats);
    for (acts, 0..) |*value, index| {
        value.* = 1.0 + 0.001 * float(index);
    }
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = total_floats;
    pipe.upload(.acts, acts);
    pipe.params = .{
        .count = jumps,
        .rows = rows,
        .col = span,
        .in_dim = hidden,
        .out_dim = input_width,
        .stride = stride,
        .x_off = lead + features,
        .t_off = hidden_at,
        .y_off = inputs_at,
    };
    pipe.run("lat_skip_gather", inputs_floats);
    pipe.params = .{
        .count = jumps,
        .rows = rows,
        .col = span,
        .in_dim = features,
        .stride = stride,
        .x_off = lead,
        .t_off = targets_at,
        .y_off = changes_at,
    };
    pipe.run("lat_skip_targets", changes_floats);
    const gathered: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
    for (0..jumps) |jump_index| {
        const jump: u32 = @intCast(jump_index);
        const start_step: u32 = jump * span;
        for (0..rows) |row_index| {
            const row: u32 = @intCast(row_index);
            const row_at: u32 = inputs_at + (jump * rows + row) * input_width;
            for (0..hidden) |unit_index| {
                const unit: u32 = @intCast(unit_index);
                const planted_at: u32 = hidden_at + (start_step * rows + row) * hidden + unit;
                try expectEqual(acts[planted_at], gathered[row_at + unit]);
            }
            for (1..span) |step_index| {
                const step_in_jump: u32 = @intCast(step_index);
                const block: u32 = start_step + step_in_jump;
                for (0..step_columns) |column_index| {
                    const within_step: u32 = @intCast(column_index);
                    const block_at: u32 = block * rows * stride + row * stride + lead + features + within_step;
                    const input_column: u32 = hidden + (step_in_jump - 1) * step_columns + within_step;
                    try expectEqual(acts[block_at], gathered[row_at + input_column]);
                }
            }
            for (0..features) |feature_index| {
                const feature: u32 = @intCast(feature_index);
                const start_at: u32 = start_step * rows * stride + row * stride + lead + feature;
                const end_at: u32 = targets_at + ((start_step + span - 1) * rows + row) * features + feature;
                const change_at: u32 = changes_at + (jump * rows + row) * features + feature;
                try expectEqual(acts[end_at] - acts[start_at], gathered[change_at]);
            }
        }
    }
}

test "gpu learn: the change in units of the typical change, and a gradient block's columns scaled" {
    // lat_advance with the statistics on: next = state + mean + spread x output, for 2 rows of 3 features; then
    // lat_scale_columns, once into another block and once in place - every value times its column's factor.
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = 64;
    const acts = [_]f32{
        // state, 2 rows of 3 (stride 3)              at 0
        1,   2,   3,   4,    5,   6,
        // the network's output, 2 x 3                at 6
        0.5, -1,  2,   0.25, 0,   -0.5,
        // the statistics: means, then spreads        at 12
        0.1, 0.2, 0.3, 2,    0.5, 4,
        // the factors for the scaling                at 18
        3,   -1,  0.5,
    };
    pipe.upload(.acts, &acts);
    pipe.params = .{
        .rows = 2,
        .count = 3,
        .stride = 3,
        .x_off = 0,
        .t_off = 6,
        .y_off = 32,
        .z_off = 40,
        .lat_increments_on = 1,
        .lat_increments_at = 12,
    };
    pipe.run("lat_advance", 6);
    const advanced: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
    for (0..2) |row| {
        for (0..3) |feature| {
            const state: f32 = acts[row * 3 + feature];
            const output: f32 = acts[6 + row * 3 + feature];
            const expected: f32 = state + acts[12 + feature] + acts[15 + feature] * output;
            try expectEqual(expected, advanced[32 + row * 3 + feature]);
            try expectEqual(expected, advanced[40 + row * 3 + feature]);
        }
    }
    const gradients = [_]f32{ 1, 2, 3, 4, 5, 6 };
    pipe.upload(.dacts, &gradients);
    pipe.params = .{ .rows = 2, .count = 3, .x_off = 0, .y_off = 8, .u_off = 18 };
    pipe.run("lat_scale_columns", 6);
    pipe.params = .{ .rows = 2, .count = 3, .x_off = 0, .y_off = 0, .u_off = 18 };
    pipe.run("lat_scale_columns", 6);
    const scaled: []const f32 = pipe.readLatest(.dacts) orelse return error.NoReadback;
    for (gradients, 0..) |gradient, index| {
        const expected: f32 = gradient * acts[18 + index % 3];
        try expectEqual(expected, scaled[8 + index]);
        try expectEqual(expected, scaled[index]);
    }
}
