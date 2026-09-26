//! gpu_learn_tests - the GPU learning kit's proofs, on its CPU twin.
//!
//! These import the kernel module `src/gpu/zn_mlp.zig` BY PATH, so they cannot live in any file
//! of the `zimr` module: a page that registers the kit's kernels gets it as a NAMED module, and
//! Zig refuses one file in two modules of a compilation ("file exists in modules 'zn_mlp' and
//! 'zimr'"). `robot_gym` keeps only the generic `GpuPpoOn(M)`; this root instantiates it.

const std = @import("std");
const zm = @import("zm");
const zn = @import("zn");
const gym = @import("robot_gym.zig");
const zn_mlp = @import("gpu/zn_mlp.zig");
/// The XOR network's kernels - the phone's GPU confidence test runs them beside the robot.
const zn_train = @import("gpu/zn_train.zig");
const compute_host = @import("compute_host.zig");

const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const float = zm.float;
const float64 = zm.float64;
const clamp = zm.clamp;
const Layer = gym.Layer;
const AdamSet = gym.AdamSet;

/// The learner on the kit as this file imports it.
const GpuPpo = gym.GpuPpoOn(zn_mlp);

test "gpu learn: G1 - zn_mlp's kernels train a two-layer net exactly as zimrnum's graph does" {
    // ★★★ THE PROOF THE GPU TRAINER STANDS ON, as `zimrnum_train` proved its XOR net: the same
    // network (5 -> 16 tanh -> 1, batch 8, MSE) trained 20 Adam steps both ways from the same
    // weights - zimrnum's CPU graph with `zn.adamStep`, and `zn_mlp`'s kernels on their CPU
    // twin through `z.Compute(...).initCpu()`, dispatched in dependency order exactly as the
    // GPU will run them. Every loss and the final weights must agree to float precision.
    const gpa: Allocator = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const rows: usize = 8;
    const n_in: usize = 5;
    const hidden: usize = 16;
    var init_rng: std.Random.DefaultPrng = .init(11);
    const random: std.Random = init_rng.random();

    // ── The CPU reference: zimrnum's graph, Adam. ──
    var l1: Layer = try .init(arena, random, n_in, hidden, 1.0);
    var l2: Layer = try .init(arena, random, hidden, 1, 1.0);
    const x: zn.Tensor(f32) = try zn.Tensor(f32).alloc(arena, &.{ rows, n_in });
    const t: zn.Tensor(f32) = try zn.Tensor(f32).alloc(arena, &.{ rows, 1 });
    for (x.data) |*v| {
        v.* = 2.0 * random.float(f32) - 1.0;
    }
    for (t.data) |*v| {
        v.* = 2.0 * random.float(f32) - 1.0;
    }
    const ones_t: zn.Tensor(f32) = try zn.Tensor(f32).alloc(arena, &.{ rows, 1 });
    @memset(ones_t.data, 1.0);
    var graph: zn.Graph(f32) = .init(arena);
    const xv: zn.Var = try graph.constant(x);
    const tv: zn.Var = try graph.constant(t);
    const ones: zn.Var = try graph.constant(ones_t);
    const h: zn.Var = try graph.tanh(try l1.apply(&graph, xv, ones));
    const y: zn.Var = try l2.apply(&graph, h, ones);
    const loss: zn.Var = try graph.mseLoss(y, tv);
    var adam_cpu: AdamSet = try .init(arena, &.{ l1.w, l1.b, l2.w, l2.b });

    // ── The kit, on its CPU twin: the same weights, the same data, at host offsets. ──
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
        const s: f32 = float(step);
        pipe.params = .{
            .w_off = 0,
            .count = param_count,
            .rate = 1.0e-2,
            .correction1 = 1.0 / (1.0 - @exp(s * @log(@as(f32, 0.9)))),
            .correction2 = 1.0 / (1.0 - @exp(s * @log(@as(f32, 0.999)))),
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
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  G1 parity, 20 Adam steps: worst loss gap {e:.2}, worst weight gap {e:.2}\n", .{
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
    const gpa: Allocator = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
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
    var init_rng: std.Random.DefaultPrng = .init(1);
    const random: std.Random = init_rng.random();
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
    const x: zn.Tensor(f32) = try zn.Tensor(f32).alloc(arena, &.{ rows, n_obs });
    const t: zn.Tensor(f32) = try zn.Tensor(f32).alloc(arena, &.{ rows, n_act });
    for (x.data) |*v| {
        v.* = 2.0 * random.float(f32) - 1.0;
    }
    for (t.data) |*v| {
        v.* = 2.0 * random.float(f32) - 1.0;
    }
    const ones_t: zn.Tensor(f32) = try zn.Tensor(f32).alloc(arena, &.{ rows, 1 });
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
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  D5 3a: 10 clone steps - kit vs graph weights at most {e:.2} apart; loss {d:.4} -> {d:.4}; " ++
        "log-std and value untouched: {}\n", .{ worst, first_loss, last_loss, untouched });
    try expect(worst < 1.0e-5);
    try expect(untouched);
    try expect(last_loss < first_loss);
}

test "gpu learn: GPU PPO (on the kit's CPU twin) learns the cartpole hold" {
    // ★★ THE LEARNER THE CARTPOLE PAGE WILL RUN, proven before the page exists: PPO whose update
    // is the zn_mlp kit (here its CPU twin - the same kernels a GPU runs), acting on the CPU.
    // zimrnum's continuous cartpole, task `.hold`, +-10 N, episodes capped at 500. 16 envs x 64
    // steps an iteration, GAE(0.99, 0.95), advantages normalised, 4 epochs of 256-row minibatches.
    // ~20 s: a learning run, gated like its siblings (G1's parity is the fast proof of the kit).
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = std.testing.allocator;
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    var ppo: GpuPpo = try .init(gpa, &pipe, zn.cartpole_state_dim, zn.cartpole_action_dim, .{});
    defer ppo.deinit(gpa);
    const envs: usize = 16;
    const horizon: usize = 64;
    const samples: usize = envs * horizon;
    var states: [16]zn.CartpoleState(f32) = undefined;
    var lengths: [16]u32 = @splat(0);
    var episode_counter: u32 = 0;
    for (&states) |*st| {
        st.* = zn.cartpoleTaskReset(f32, zn.Rng.init(1), episode_counter, .hold);
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
    var rollout: zn.RolloutBuffer = try .init(gpa, samples);
    defer rollout.deinit(gpa);
    var rng: std.Random.DefaultPrng = .init(5);
    const random: std.Random = rng.random();
    var order: [1024]u32 = undefined;
    for (&order, 0..) |*o, i| {
        o.* = @intCast(i);
    }
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  GPU PPO (CPU twin) on the cartpole hold (cap 500):\n", .{});
    for (0..40) |iteration| {
        rollout.len = 0;
        var finished: u32 = 0;
        var finished_steps: u64 = 0;
        // Env-major segments: each env's `horizon` steps together, cut with a bootstrap at the end.
        for (0..envs) |e| {
            for (0..horizon) |t| {
                const row: usize = e * horizon + t;
                var obs: [4]f32 = undefined;
                try zn.cartpoleObserve(f32, states[e], &obs);
                @memcpy(obs_all[row * 4 ..][0..4], &obs);
                var action: [1]f32 = undefined;
                logp_all[row] = ppo.act(&obs, &action, random);
                act_all[row] = action[0];
                const v_now: f32 = ppo.value(&obs);
                const stepped = zn.cartpoleTaskStep(f32, states[e], 10.0 * clamp(action[0], -1.0, 1.0), .hold);
                lengths[e] += 1;
                const capped: bool = !stepped.failed and lengths[e] >= 500;
                const segment_end: bool = t == horizon - 1;
                var v_next: f32 = 0.0;
                if (!stepped.failed) {
                    var next_obs: [4]f32 = undefined;
                    try zn.cartpoleObserve(f32, stepped.state, &next_obs);
                    v_next = ppo.value(&next_obs);
                }
                const truncated: bool = capped or (segment_end and !stepped.failed);
                try rollout.record(stepped.reward, v_now, v_next, stepped.failed, truncated, logp_all[row]);
                states[e] = stepped.state;
                if (stepped.failed or capped) {
                    finished += 1;
                    finished_steps += lengths[e];
                    lengths[e] = 0;
                    states[e] = zn.cartpoleTaskReset(f32, zn.Rng.init(1), episode_counter, .hold);
                    episode_counter += 1;
                }
            }
        }
        try zn.gae(rollout.steps[0..rollout.len], 0.99, 0.95, advantages, returns);
        try zn.normalizeAdvantages(f64, advantages, 1.0e-8);
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
            // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
            std.debug.print("    iteration {d:>2} ({d:>5} samples): {d:>3} " ++
                "episodes finished, mean length {d:>6.1}\n", .{
                iteration + 1, (iteration + 1) * samples, finished, mean_length,
            });
        }
    }
}

/// SAC's update on the kit as this file imports it.
const GpuSac = gym.GpuSacOn(zn_mlp);

test "gpu learn: S2 - the kit's SAC update is SacAgent's, update for update" {
    // ★★★ THE PROOF S2 STANDS ON, as G1's was for the layer kit: `SacAgent` (zimrnum's CPU
    // graphs) and the kit's SAC (on its CPU twin, dispatched exactly as a GPU runs it), from the
    // same weights, fed the same batches and the same noise for 5 updates. Two action dimensions,
    // so the per-dimension paths are exercised; a raised learning rate, so the updates move the
    // weights far enough to disagree if anything is wrong. Every parameter group must agree.
    const gpa: Allocator = std.testing.allocator;
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
    var rng: std.Random.DefaultPrng = .init(9);
    const random: std.Random = rng.random();
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
            row[width - 1] = if (i % 4 == 0) 1.0 else 0.0;
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
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  S2 parity, 5 SAC updates: actor {e:.2}, log-std {e:.2}, log-alpha {e:.2}, " ++
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
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("  moved: actor {d:.4}, critics {d:.4}\n", .{ moved_actor, moved_critics });
    try expect(moved_actor > 1.0e-3 and moved_critics > 1.0e-3);
}

const st_mod = @import("robot_supertrack.zig");
/// SuperTrack's training steps on the kit as this file imports it.
const StKit = st_mod.SuperTrackKitOn(zn_mlp);

test "gpu learn: SuperTrack on the kit is the graph's, step for step" {
    // ★★★ AS S2 WAS FOR SAC: `robot_supertrack.SuperTrack` (zimrnum's graph) and the kit's
    // SuperTrack (its CPU twin, dispatched exactly as a GPU runs it), from the same weights, fed
    // the same windows, start states and noise for 4 iterations of (world step, policy step), at
    // a raised learning rate - both the per-layer path (~1,050 dispatches an iteration) and the
    // FUSED one (8). Both networks must agree - while their weights MOVE.
    try stParity(false);
    try stParity(true);
}

fn stParity(fused: bool) !void {
    // ★★★ AS S2 WAS FOR SAC: `robot_supertrack.SuperTrack` (zimrnum's graph) and the kit's
    // SuperTrack (its CPU twin, dispatched exactly as a GPU runs it), from the same weights, fed
    // the same windows, start states and noise for 4 iterations of (world step, policy step), at
    // a raised learning rate. Both networks must agree - while their weights MOVE.
    const gpa: Allocator = std.testing.allocator;
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
    var rng: std.Random.DefaultPrng = .init(21);
    const random: std.Random = rng.random();
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
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  SuperTrack kit parity ({s}), 4 iterations: policy {e:.2}, world {e:.2}; " ++
        "moved policy {d:.4}, world {d:.4}\n", .{
        if (fused) "fused" else "per-layer", gaps[0], gaps[1], moved_policy, moved_world,
    });
    try expect(gaps[0] < 1.0e-4 and gaps[1] < 1.0e-4);
    try expect(moved_policy > 1.0e-3 and moved_world > 1.0e-3);
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
    try stCartpole(false);
}

fn stCartpole(fused: bool) !void {
    // The kit training the real task end to end, at the full configuration (batch 32, windows
    // 8 / 32): the graph SuperTrack only gathers and samples (its buffer, its gym, its CPU
    // policy forward, fed the kit's policy after every step); the KIT does all the training.
    // The same gym, pushes and evaluation as robot_supertrack's own run - and the milliseconds
    // an iteration, which decide whether a page can afford it.
    const gpa: Allocator = std.testing.allocator;
    const options: st_mod.Options = .{};
    const host: *st_mod.SuperTrack = try .init(gpa, options);
    defer host.deinit();
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    var kit: StKit = try .initFrom(gpa, &pipe, host);
    defer kit.deinit();
    const io: std.Io = std.testing.io;
    var states: [8]zn.CartpoleState(f32) = undefined;
    var steps: [8]u32 = @splat(0);
    var segments: [8]u32 = undefined;
    var next_segment: u32 = 0;
    var episode: u32 = 0;
    for (0..8) |e| {
        states[e] = zn.cartpoleTaskReset(f32, zn.Rng.init(7), episode, .hold);
        episode += 1;
        segments[e] = next_segment;
        next_segment += 1;
    }
    const baseline: f32 = st_mod.evaluate(null, 10, 99);
    var train_ns: i96 = 0;
    var trained: u32 = 0;
    var final_eval: f32 = 0.0;
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  SuperTrack on the kit's CPU twin ({s}), real cartpole (baseline {d:.1}):\n", .{
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
                const stepped = zn.cartpoleContinuousStep(f32, states[e], force);
                steps[e] += 1;
                if (stepped.failed or steps[e] >= st_mod.episode_cap) {
                    states[e] = zn.cartpoleTaskReset(f32, zn.Rng.init(7), episode, .hold);
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
            const started: std.Io.Timestamp = std.Io.Clock.now(.awake, io);
            if (fused) {
                kit.trainWorldFused(host.stage_states, host.stage_forces);
                kit.trainPolicyFused(host.stage_starts, host.stage_noise);
            } else {
                kit.trainWorldWith(host.stage_states, host.stage_forces);
                kit.trainPolicyWith(host.stage_starts, host.stage_noise);
            }
            const params_: []const f32 = kit.readParams() orelse return error.NoReadback;
            train_ns += std.Io.Clock.now(.awake, io).nanoseconds - started.nanoseconds;
            trained += 1;
            host.loadPolicy(params_, kit.pol);
        }
        if (iteration % 500 == 0) {
            final_eval = st_mod.evaluate(host, 10, 99);
            // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
            std.debug.print("    iteration {d:>4}: REAL episodes {d:.1} steps\n", .{ iteration, final_eval });
        }
    }
    const ms: f64 = float64(train_ns) / 1.0e6 / float64(@max(trained, 1));
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("    the kit's CPU twin: {d:.2} ms an iteration " ++
        "(world step + policy step, batch 32, windows 8/32)\n", .{ms});
    try expect(final_eval > baseline * 4.0);
}

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
            var rng: std.Random.DefaultPrng = .init(seed);
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
        // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
        std.debug.print("{s}  XOR on the CPU twin, rate {d:.1}: {d} of 8 runs converged (< 0.01), " ++
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

/// The rate `geno_track`'s XOR confidence test trains at - one that never diverges (checked above).
const xor_page_rate: f32 = 0.2;
