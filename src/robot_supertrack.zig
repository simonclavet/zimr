//! robot_supertrack - SuperTrack (Fussell, Bergamin & Holden 2021) and NOTHING else.
//!
//! Two networks, both trained by plain supervised learning:
//!
//!   * a WORLD MODEL, (state, force) -> accelerations, integrated like the simulator, fitted to
//!     real transitions over windows of its own predictions (the paper's N_W = 8);
//!   * a POLICY, trained by back-propagating a TRACKING LOSS through the world model unrolled
//!     over N_Pi = 32 frames - it never sees the simulator's gradient, because there is none.
//!
//! No reward, no critic, no advantage, no MPC, no PPO or SAC. The data comes from the current
//! policy plus Gaussian noise (the paper's sigma), into a cyclic buffer; the two networks train
//! in tandem from it, one step each per iteration.
//!
//! The question it answers (Simon, Sep 19): can that alone hold a REAL cartpole upright under
//! pushes? zimrnum's "SuperTrack in miniature" proved the mechanism - gradient reaches a policy
//! through a learned model - but measured its loss through the model, never ran the policy on
//! the simulator, and fed the model MPC data. This runs the policy on the real cartpole.
//!
//! Faithful to the paper except where the graph forces a choice: MSE instead of L1 (the tape
//! has no abs), tanh instead of ELU, and small networks for a small system.

const std = @import("std");
const zm = @import("zm");
const zn = @import("zn");
const gym = @import("robot_gym.zig");
const compute_host = @import("compute_host.zig");

const Allocator = std.mem.Allocator;
const Var = zn.Var;
const Graph = zn.Graph(f32);
const Tensor = zn.Tensor(f32);
const float = zm.float;
const tanh = zm.tanh;
const expect = std.testing.expect;

/// A cartpole state: cart position, cart rate, pole angle (0 = upright), pole rate.
pub const State4 = [4]f32;

/// The world model's outputs are the two accelerations DIVIDED by this: the graph's one-hot pick
/// columns and the kit's `acc_scale` both multiply it back, so the two stay one model.
pub const acc_scale: f32 = 10.0;

pub fn fromCartpole(s: zn.CartpoleState(f32)) State4 {
    return .{ s.cart, s.cart_rate, s.pole_rad, s.pole_rate_rad };
}

pub const Options = struct {
    hidden: usize = 32,
    batch: usize = 32,
    /// The paper's windows: 8 for the world model, 32 for the policy.
    wm_window: usize = 8,
    policy_window: usize = 32,
    wm_rate: f64 = 1.0e-3,
    policy_rate: f64 = 1.0e-3,
    /// Exploration noise on the policy's pre-squash output (the paper's sigma).
    sigma: f32 = 0.1,
    /// The tracking weights on (cart, cart rate, pole angle, pole rate), and the action penalty.
    w_cart: f32 = 1.0,
    w_cart_rate: f32 = 0.1,
    w_pole: f32 = 10.0,
    w_pole_rate: f32 = 0.1,
    w_action: f32 = 0.01,
    capacity: usize = 50_000,
    /// The simulator's step (s) - the world model integrates with it, semi-implicitly, as the
    /// simulator does - and the force limit (N): the policy's output goes through tanh, times it.
    /// zimrnum's cartpole: 0.02 s and 10 N; the page's robot.zig cartpole: 0.01 s and 6 N.
    dt: f32 = 0.02,
    max_force: f32 = 10.0,
    /// The gym's parallel cartpoles: each gets its OWN ring, so a window is one cartpole's
    /// consecutive frames.
    envs: usize = 8,
    seed: u64 = 1,
};

/// A three-layer tanh MLP whose parameter handles are made ONCE per graph and reused at every
/// unrolled step, so its gradient accumulates over the whole window (`gym.Layer.apply` makes
/// new handles on every call, which would split it across 32 copies).
const Net = struct {
    layers: [3]gym.Layer,

    fn init(
        arena: Allocator,
        random: std.Random,
        in: usize,
        hidden: usize,
        out: usize,
        last_gain: f32,
    ) !Net {
        return .{ .layers = .{
            try .init(arena, random, in, hidden, 1.0),
            try .init(arena, random, hidden, hidden, 1.0),
            try .init(arena, random, hidden, out, last_gain),
        } };
    }

    fn vars(net: *const Net, g: *Graph) ![6]Var {
        var v: [6]Var = undefined;
        for (net.layers, 0..) |layer, i| {
            v[2 * i] = try g.parameter(layer.w);
            v[2 * i + 1] = try g.parameter(layer.b);
        }
        return v;
    }

    fn tensors(net: *const Net) [6]Tensor {
        var t: [6]Tensor = undefined;
        for (net.layers, 0..) |layer, i| {
            t[2 * i] = layer.w;
            t[2 * i + 1] = layer.b;
        }
        return t;
    }

    fn apply(g: *Graph, v: [6]Var, x: Var, ones: Var) !Var {
        const h1: Var = try g.tanh(try g.add(try g.matmul(x, v[0]), try g.matmul(ones, v[1])));
        const h2: Var = try g.tanh(try g.add(try g.matmul(h1, v[2]), try g.matmul(ones, v[3])));
        return g.add(try g.matmul(h2, v[4]), try g.matmul(ones, v[5]));
    }

    /// One row on the CPU (acting): the same layers, no graph.
    fn forwardRow(
        net: *const Net,
        x: []const f32,
        t1: []f32,
        t2: []f32,
        out: []f32,
    ) void {
        net.layers[0].forward(x, t1, true);
        net.layers[1].forward(t1, t2, true);
        net.layers[2].forward(t2, out, false);
    }
};

/// A state as four [rows, 1] columns on the tape: cart, cart rate, pole angle, pole rate.
const Columns = [4]Var;

/// One transition in the buffer: the state, the force applied from it (N), and its segment -
/// a new segment starts at every reset AND at every push, so a window never spans a push the
/// world model could not explain.
const Record = struct {
    state: [4]f32,
    force: f32,
    segment: u32,
};

pub const SuperTrack = struct {
    arena_state: std.heap.ArenaAllocator,
    gpa: Allocator,
    options: Options,
    policy: Net,
    world: Net,
    /// `envs` rings of `per_env` records each, back to back.
    ///
    /// ★ ONE SHARED RING WAS THE FIRST VERSION'S BUG: the cartpoles take turns recording, so
    /// consecutive records were different cartpoles - a world-model "window" was nine states of
    /// nine cartpoles (its end check passed because record +8 is the same one a tick later), and
    /// a policy start's 1-step window never matched a segment, so the policy never trained.
    records: []Record,
    per_env: usize,
    heads: []usize,
    lens: []usize,
    rng: std.Random.DefaultPrng,
    // ── The world model's graph: a window of real states and forces, rolled out. ──
    wm_graph: Graph,
    wm_states: [][4]Var,
    wm_forces: []Var,
    wm_loss: Var,
    wm_vars: [6]Var,
    wm_adam: gym.AdamSet,
    // ── The policy's graph: a start state and noise, rolled out through the world model. ──
    pi_graph: Graph,
    pi_start: Columns,
    pi_noise: []Var,
    pi_loss: Var,
    pi_vars: [6]Var,
    pi_adam: gym.AdamSet,
    /// A drawn batch, for `trainWorldWith` / `trainPolicyWith` (which a check calls with its own).
    stage_states: []f32,
    stage_forces: []f32,
    stage_starts: []f32,
    stage_noise: []f32,
    // acting scratch
    t1: []f32,
    t2: []f32,
    out: [1]f32 = .{0},

    pub fn init(gpa: Allocator, options: Options) !*SuperTrack {
        const st: *SuperTrack = try gpa.create(SuperTrack);
        errdefer gpa.destroy(st);
        // whole-init-first: the whole struct first - defaults applied, every field named.
        st.* = .{
            .arena_state = undefined,
            .gpa = undefined,
            .options = undefined,
            .policy = undefined,
            .world = undefined,
            .records = undefined,
            .per_env = undefined,
            .heads = undefined,
            .lens = undefined,
            .rng = undefined,
            .wm_graph = undefined,
            .wm_states = undefined,
            .wm_forces = undefined,
            .wm_loss = undefined,
            .wm_vars = undefined,
            .wm_adam = undefined,
            .pi_graph = undefined,
            .pi_start = undefined,
            .pi_noise = undefined,
            .pi_loss = undefined,
            .pi_vars = undefined,
            .pi_adam = undefined,
            .stage_states = undefined,
            .stage_forces = undefined,
            .stage_starts = undefined,
            .stage_noise = undefined,
            .t1 = undefined,
            .t2 = undefined,
        };
        st.arena_state = .init(gpa);
        errdefer st.arena_state.deinit();
        const arena: Allocator = st.arena_state.allocator();
        st.gpa = gpa;
        st.options = options;
        st.out = .{0};
        st.rng = .init(options.seed);
        const random: std.Random = st.rng.random();
        const h: usize = options.hidden;
        const b: usize = options.batch;
        st.policy = try .init(arena, random, 4, h, 1, 0.01);
        // In: cart rate, pole angle, pole rate, force / max_force. Out: the two accelerations / 10.
        st.world = try .init(arena, random, 4, h, 2, 1.0);
        st.per_env = options.capacity / options.envs;
        st.records = try arena.alloc(Record, st.per_env * options.envs);
        st.heads = try arena.alloc(usize, options.envs);
        st.lens = try arena.alloc(usize, options.envs);
        @memset(st.heads, 0);
        @memset(st.lens, 0);
        st.t1 = try arena.alloc(f32, h);
        st.t2 = try arena.alloc(f32, h);
        st.stage_states = try arena.alloc(f32, b * (options.wm_window + 1) * 4);
        st.stage_forces = try arena.alloc(f32, b * options.wm_window);
        st.stage_starts = try arena.alloc(f32, b * 4);
        st.stage_noise = try arena.alloc(f32, options.policy_window * b);

        const ones_t: Tensor = try filled(arena, &.{ b, 1 }, 1.0);
        // One-hot columns that pick an acceleration out of the world model's [rows, 2] output.
        const pick_cart: Tensor = try Tensor.alloc(arena, &.{ 2, 1 });
        pick_cart.data[0] = acc_scale;
        pick_cart.data[1] = 0.0;
        const pick_pole: Tensor = try Tensor.alloc(arena, &.{ 2, 1 });
        pick_pole.data[0] = 0.0;
        pick_pole.data[1] = acc_scale;
        const zero_col: Tensor = try filled(arena, &.{ b, 1 }, 0.0);

        // ── The world model's graph. ──
        st.wm_graph = .init(arena);
        st.wm_graph.useScratchAllocator(gpa);
        const wg: *Graph = &st.wm_graph;
        st.wm_vars = try st.world.vars(wg);
        const w_ones: Var = try wg.constant(ones_t);
        const w_pick_cart: Var = try wg.constant(pick_cart);
        const w_pick_pole: Var = try wg.constant(pick_pole);
        st.wm_states = try arena.alloc([4]Var, options.wm_window + 1);
        st.wm_forces = try arena.alloc(Var, options.wm_window);
        for (st.wm_states) |*cols| {
            for (cols) |*c| {
                c.* = try wg.constant(try filled(arena, &.{ b, 1 }, 0.0));
            }
        }
        for (st.wm_forces) |*f| {
            f.* = try wg.constant(try filled(arena, &.{ b, 1 }, 0.0));
        }
        var p: Columns = st.wm_states[0];
        var loss: ?Var = null;
        for (0..options.wm_window) |k| {
            p = try step(wg, st.wm_vars, p, st.wm_forces[k], w_ones, w_pick_cart, w_pick_pole, options.dt);
            const term: Var = try weightedDistance(wg, options, p, st.wm_states[k + 1]);
            loss = if (loss) |l| try wg.add(l, term) else term;
        }
        st.wm_loss = loss.?;
        st.wm_adam = try .init(arena, &st.world.tensors());

        // ── The policy's graph: rolled out through the SAME world model weights. ──
        st.pi_graph = .init(arena);
        st.pi_graph.useScratchAllocator(gpa);
        const pg: *Graph = &st.pi_graph;
        st.pi_vars = try st.policy.vars(pg);
        const world_in_pi: [6]Var = try st.world.vars(pg);
        const p_ones: Var = try pg.constant(ones_t);
        const p_pick_cart: Var = try pg.constant(pick_cart);
        const p_pick_pole: Var = try pg.constant(pick_pole);
        const p_zero: Var = try pg.constant(zero_col);
        const upright: Columns = .{ p_zero, p_zero, p_zero, p_zero };
        for (&st.pi_start) |*c| {
            c.* = try pg.constant(try filled(arena, &.{ b, 1 }, 0.0));
        }
        st.pi_noise = try arena.alloc(Var, options.policy_window);
        var q: Columns = st.pi_start;
        var pi_loss: ?Var = null;
        for (0..options.policy_window) |k| {
            const x: Var = try concat4(pg, q);
            const o: Var = try Net.apply(pg, st.pi_vars, x, p_ones);
            st.pi_noise[k] = try pg.constant(try filled(arena, &.{ b, 1 }, 0.0));
            // The force the world model sees: tanh(o + sigma eps), i.e. force / max_force.
            const squashed: Var = try pg.tanh(try pg.add(o, try pg.scale(st.pi_noise[k], options.sigma)));
            q = try step(pg, world_in_pi, q, squashed, p_ones, p_pick_cart, p_pick_pole, options.dt);
            var term: Var = try weightedDistance(pg, options, q, upright);
            term = try pg.add(term, try pg.scale(try pg.mseLoss(o, p_zero), options.w_action));
            pi_loss = if (pi_loss) |l| try pg.add(l, term) else term;
        }
        st.pi_loss = pi_loss.?;
        st.pi_adam = try .init(arena, &st.policy.tensors());
        return st;
    }

    pub fn deinit(st: *SuperTrack) void {
        st.wm_graph.deinitScratch();
        st.pi_graph.deinitScratch();
        st.arena_state.deinit();
        st.gpa.destroy(st);
    }

    fn filled(arena: Allocator, shape: []const usize, value: f32) !Tensor {
        const t: Tensor = try Tensor.alloc(arena, shape);
        @memset(t.data, value);
        return t;
    }

    fn concat4(g: *Graph, c: Columns) !Var {
        return g.concat(try g.concat(try g.concat(c[0], c[1], 1), c[2], 1), c[3], 1);
    }

    /// One step ON THE TAPE: the world model's accelerations from (cart rate, pole angle, pole
    /// rate, force / max_force), integrated exactly as the simulator integrates - velocities
    /// first, positions from the new velocities.
    fn step(
        g: *Graph,
        w: [6]Var,
        s: Columns,
        force_unit: Var,
        ones: Var,
        pick_cart: Var,
        pick_pole: Var,
        dt: f32,
    ) !Columns {
        const in: Var = try concat4(g, .{ s[1], s[2], s[3], force_unit });
        const acc: Var = try Net.apply(g, w, in, ones);
        const cart_rate: Var = try g.add(s[1], try g.scale(try g.matmul(acc, pick_cart), dt));
        const pole_rate: Var = try g.add(s[3], try g.scale(try g.matmul(acc, pick_pole), dt));
        return .{
            try g.add(s[0], try g.scale(cart_rate, dt)),
            cart_rate,
            try g.add(s[2], try g.scale(pole_rate, dt)),
            pole_rate,
        };
    }

    /// The tracking loss between two states: weighted mean squares per component.
    fn weightedDistance(g: *Graph, o: Options, a: Columns, b: Columns) !Var {
        const weights = [4]f32{ o.w_cart, o.w_cart_rate, o.w_pole, o.w_pole_rate };
        var total: ?Var = null;
        for (a, b, weights) |x, y, w| {
            const term: Var = try g.scale(try g.mseLoss(x, y), w);
            total = if (total) |t| try g.add(t, term) else term;
        }
        return total.?;
    }

    /// The policy's force for one state (N), with or without its exploration noise.
    pub fn act(st: *SuperTrack, state: State4, noisy: bool) f32 {
        st.policy.forwardRow(&state, st.t1, st.t2, &st.out);
        const noise: f32 = if (noisy) st.options.sigma * st.rng.random().floatNorm(f32) else 0.0;
        return st.options.max_force * tanh(st.out[0] + noise);
    }

    pub fn remember(
        st: *SuperTrack,
        env: usize,
        state: State4,
        force: f32,
        segment: u32,
    ) void {
        const ring: []Record = st.records[env * st.per_env ..][0..st.per_env];
        ring[st.heads[env]] = .{
            .state = state,
            .force = force,
            .segment = segment,
        };
        st.heads[env] = (st.heads[env] + 1) % st.per_env;
        st.lens[env] = @min(st.lens[env] + 1, st.per_env);
    }

    /// A window of `n` consecutive transitions (n + 1 states) of ONE cartpole inside one
    /// segment: the ring it is in, and the index of its oldest record; null if none was found.
    const Window = struct { ring: []const Record, first: usize };

    fn sampleWindow(st: *SuperTrack, n: usize) ?Window {
        for (0..64) |_| {
            const env: usize = st.rng.random().uintLessThan(usize, st.options.envs);
            const len: usize = st.lens[env];
            if (len < n + 2) {
                continue;
            }
            const ring: []const Record = st.records[env * st.per_env ..][0..st.per_env];
            const oldest: usize = (st.heads[env] + st.per_env - len) % st.per_env;
            const offset: usize = st.rng.random().uintLessThan(usize, len - n);
            const first: usize = (oldest + offset) % st.per_env;
            const last: usize = (first + n) % st.per_env;
            if (ring[first].segment == ring[last].segment) {
                return .{ .ring = ring, .first = first };
            }
        }
        return null;
    }

    fn setColumn(g: *Graph, v: Var, row: usize, value: f32) void {
        g.valueOf(v).data[row] = value;
    }

    /// One world-model step on a batch of sampled windows: supervised, on real transitions.
    pub fn trainWorld(st: *SuperTrack) !?f32 {
        if (!st.sampleWorldBatch()) {
            return null;
        }
        return try st.trainWorldWith(st.stage_states, st.stage_forces);
    }

    /// Draw a world-model batch into `stage_states` / `stage_forces`; false if the buffer cannot
    /// supply one yet. Either trainer (this graph, or the kit) can then take it.
    pub fn sampleWorldBatch(st: *SuperTrack) bool {
        const n: usize = st.options.wm_window;
        for (0..st.options.batch) |row| {
            const w: Window = st.sampleWindow(n) orelse return false;
            for (0..n + 1) |k| {
                const rec: Record = w.ring[(w.first + k) % w.ring.len];
                @memcpy(st.stage_states[(row * (n + 1) + k) * 4 ..][0..4], &rec.state);
                if (k < n) {
                    st.stage_forces[row * n + k] = rec.force / st.options.max_force;
                }
            }
        }
        return true;
    }

    /// One world-model step on GIVEN windows: states [batch][window + 1][4], forces (already
    /// divided by the force limit) [batch][window].
    pub fn trainWorldWith(
        st: *SuperTrack,
        states: []const f32,
        forces_unit: []const f32,
    ) !f32 {
        const g: *Graph = &st.wm_graph;
        const n: usize = st.options.wm_window;
        for (0..st.options.batch) |row| {
            for (0..n + 1) |k| {
                for (0..4) |c| {
                    setColumn(g, st.wm_states[k][c], row, states[(row * (n + 1) + k) * 4 + c]);
                }
                if (k < n) {
                    setColumn(g, st.wm_forces[k], row, forces_unit[row * n + k]);
                }
            }
        }
        try g.recompute();
        try g.backward(st.wm_loss);
        try st.wm_adam.apply(g, &st.world.tensors(), &st.wm_vars, st.options.wm_rate);
        return g.valueOf(st.wm_loss).data[0];
    }

    /// One policy step from sampled start states and fresh noise.
    pub fn trainPolicy(st: *SuperTrack) !?f32 {
        if (!st.samplePolicyBatch()) {
            return null;
        }
        return try st.trainPolicyWith(st.stage_starts, st.stage_noise);
    }

    /// Draw start states and noise into `stage_starts` / `stage_noise`; false if not yet.
    pub fn samplePolicyBatch(st: *SuperTrack) bool {
        for (0..st.options.batch) |row| {
            const w: Window = st.sampleWindow(1) orelse return false;
            @memcpy(st.stage_starts[row * 4 ..][0..4], &w.ring[w.first].state);
        }
        for (st.stage_noise) |*e| {
            e.* = st.rng.random().floatNorm(f32);
        }
        return true;
    }

    /// Take a policy's weights (in the kit's layout, from `offsets`) - so a kit-trained policy
    /// acts through this object's CPU forward.
    pub fn loadPolicy(st: *SuperTrack, params_: []const f32, offsets: [3]u32) void {
        for (st.policy.layers, offsets) |layer, off| {
            @memcpy(layer.w.data, params_[off..][0..layer.w.data.len]);
            @memcpy(layer.b.data, params_[off + layer.w.data.len ..][0..layer.b.data.len]);
        }
    }

    /// One policy step from GIVEN start states [batch][4] and noise [policy_window][batch]:
    /// rolled out through the world model, the tracking loss back-propagated into the POLICY
    /// only (the world model's gradients are not applied).
    pub fn trainPolicyWith(
        st: *SuperTrack,
        starts: []const f32,
        noise: []const f32,
    ) !f32 {
        const g: *Graph = &st.pi_graph;
        const b: usize = st.options.batch;
        for (0..b) |row| {
            for (0..4) |c| {
                setColumn(g, st.pi_start[c], row, starts[row * 4 + c]);
            }
        }
        for (st.pi_noise, 0..) |v, k| {
            @memcpy(g.valueOf(v).data, noise[k * b ..][0..b]);
        }
        try g.recompute();
        try g.backward(st.pi_loss);
        try st.pi_adam.apply(g, &st.policy.tensors(), &st.pi_vars, st.options.policy_rate);
        return g.valueOf(st.pi_loss).data[0];
    }
};

/// SuperTrack's two training steps on the zn_mlp kit (a GPU, or the kit's CPU twin), step for
/// step `SuperTrack.trainWorldWith` / `trainPolicyWith`: the same networks, the same unrolled
/// windows, the same losses - as kernels, two ways, both checked against the graph:
///   * PER-LAYER (`trainWorldWith` / `trainPolicyWith`): one dispatch per layer operation, the
///     cp_ kernels - the forward keeps every step's activations, the backward walks the window
///     in reverse and SUMS the weight gradients over the steps (`accumulate`). ~1,050 dispatches
///     an iteration: the reference, and slow;
///   * FUSED (`trainWorldFused` / `trainPolicyFused`): the st_ kernels, one thread per batch row
///     walking the whole window, per-row gradients reduced - 8 dispatches an iteration. What
///     training uses.
/// The uploaded inputs sit in compact regions at the front of `acts` (each step uploads only its
/// own - see `compute_host.uploadAt`): a few thousand floats, whatever the window lengths.
pub fn SuperTrackKitOn(comptime M: type) type {
    return struct {
        const Self = @This();

        pipe: *compute_host.Compute(M),
        options: Options,
        rows: u32,
        hidden: u32,
        pol: [3]u32,
        pol_count: u32,
        wm: [3]u32,
        wm_count: u32,
        param_count: u32,
        // the uploaded region
        zero: u32,
        p_start: u32,
        p_eps: []u32,
        w_start: u32,
        w_target: []u32,
        w_force: []u32,
        upload_len: u32,
        // the policy pass, per unrolled step (p_state has one more: the state after the last)
        p_state: []u32,
        p_h1: []u32,
        p_h2: []u32,
        p_o: []u32,
        p_f: []u32,
        p_in: []u32,
        p_g1: []u32,
        p_g2: []u32,
        p_acc: []u32,
        // the world-model pass
        w_state: []u32,
        w_in: []u32,
        w_g1: []u32,
        w_g2: []u32,
        w_acc: []u32,
        // dacts scratch (one step at a time)
        d_a: u32,
        d_b: u32,
        d_acc: u32,
        d_wh2: u32,
        d_wh1: u32,
        d_win: u32,
        d_f: u32,
        d_o: u32,
        d_ph2: u32,
        d_ph1: u32,
        d_pin: u32,
        staging: []f32,
        pol_step: u32 = 0,
        wm_step: u32 = 0,
        arena_state: std.heap.ArenaAllocator,
        // ── The FUSED path (st_ kernels): its own upload region, records, per-row gradients. ──
        f_p_start: u32,
        f_p_eps: u32,
        f_w_start: u32,
        f_w_target: u32,
        f_w_force: u32,
        f_upload_len: u32,
        f_p_records: u32,
        f_w_records: u32,
        f_pol_grads: u32,
        f_wm_grads: u32,
        f_scratch: u32,
        f_staging: []f32,

        const Bump = struct {
            at: u32 = 0,
            fn take(bump: *Bump, n: u32) u32 {
                const o: u32 = bump.at;
                bump.at += n;
                return o;
            }
            fn takeEach(bump: *Bump, arena: Allocator, count: usize, n: u32) ![]u32 {
                const out: []u32 = try arena.alloc(u32, count);
                for (out) |*o| {
                    o.* = bump.take(n);
                }
                return out;
            }
        };

        fn layerSize(in: u32, out: u32) u32 {
            return in * out + out;
        }

        pub fn init(gpa: Allocator, pipe: *compute_host.Compute(M), options: Options) !Self {
            var p: Self = undefined;
            p.arena_state = .init(gpa);
            errdefer p.arena_state.deinit();
            const arena: Allocator = p.arena_state.allocator();
            p.pipe = pipe;
            p.options = options;
            p.pol_step = 0;
            p.wm_step = 0;
            const r: u32 = @intCast(options.batch);
            const h: u32 = @intCast(options.hidden);
            p.rows = r;
            p.hidden = h;
            const np: usize = options.policy_window;
            const nw: usize = options.wm_window;
            var par: Bump = .{};
            p.pol = .{ par.take(layerSize(4, h)), par.take(layerSize(h, h)), par.take(layerSize(h, 1)) };
            p.pol_count = par.at;
            p.wm = .{ par.take(layerSize(4, h)), par.take(layerSize(h, h)), par.take(layerSize(h, 2)) };
            p.wm_count = par.at - p.wm[0];
            p.param_count = par.at;
            var act: Bump = .{};
            p.zero = act.take(4 * r);
            p.p_start = act.take(4 * r);
            p.p_eps = try act.takeEach(arena, np, r);
            p.w_start = act.take(4 * r);
            p.w_target = try act.takeEach(arena, nw, 4 * r);
            p.w_force = try act.takeEach(arena, nw, r);
            p.upload_len = act.at;
            p.p_state = try arena.alloc(u32, np + 1);
            p.p_state[0] = p.p_start;
            for (p.p_state[1..]) |*o| {
                o.* = act.take(4 * r);
            }
            p.p_h1 = try act.takeEach(arena, np, h * r);
            p.p_h2 = try act.takeEach(arena, np, h * r);
            p.p_o = try act.takeEach(arena, np, r);
            p.p_f = try act.takeEach(arena, np, r);
            p.p_in = try act.takeEach(arena, np, 4 * r);
            p.p_g1 = try act.takeEach(arena, np, h * r);
            p.p_g2 = try act.takeEach(arena, np, h * r);
            p.p_acc = try act.takeEach(arena, np, 2 * r);
            p.w_state = try arena.alloc(u32, nw + 1);
            p.w_state[0] = p.w_start;
            for (p.w_state[1..]) |*o| {
                o.* = act.take(4 * r);
            }
            p.w_in = try act.takeEach(arena, nw, 4 * r);
            p.w_g1 = try act.takeEach(arena, nw, h * r);
            p.w_g2 = try act.takeEach(arena, nw, h * r);
            p.w_acc = try act.takeEach(arena, nw, 2 * r);
            var dact: Bump = .{};
            p.d_a = dact.take(4 * r);
            p.d_b = dact.take(4 * r);
            p.d_acc = dact.take(2 * r);
            p.d_wh2 = dact.take(h * r);
            p.d_wh1 = dact.take(h * r);
            p.d_win = dact.take(4 * r);
            p.d_f = dact.take(r);
            p.d_o = dact.take(r);
            p.d_ph2 = dact.take(h * r);
            p.d_ph1 = dact.take(h * r);
            p.d_pin = dact.take(4 * r);
            const fits: bool = act.at <= M.config.max and dact.at <= M.config.max and par.at <= M.config.max;
            zm.assertf(fits, @src(), "the kit's buffers are too small for this SuperTrack", .{});
            p.staging = try arena.alloc(f32, p.upload_len);
            @memset(p.staging, 0.0);
            // The fused path's layout (acts from 0 again: the two paths are alternatives).
            const rec: u32 = 12 + 4 * h;
            var fa: Bump = .{};
            p.f_p_start = fa.take(4 * r);
            p.f_p_eps = fa.take(@as(u32, @intCast(np)) * r);
            p.f_w_start = fa.take(4 * r);
            p.f_w_target = fa.take(@as(u32, @intCast(nw)) * 4 * r);
            p.f_w_force = fa.take(@as(u32, @intCast(nw)) * r);
            p.f_upload_len = fa.at;
            p.f_p_records = fa.take(@as(u32, @intCast(np + 1)) * r * rec);
            p.f_w_records = fa.take(@as(u32, @intCast(nw + 1)) * r * rec);
            var fd: Bump = .{};
            p.f_pol_grads = fd.take(r * p.pol_count);
            p.f_wm_grads = fd.take(r * p.wm_count);
            p.f_scratch = fd.take(r * 4 * h);
            const fused_fits: bool = fa.at <= M.config.max and fd.at <= M.config.max;
            zm.assertf(fused_fits, @src(), "the kit's buffers are too small for this fused SuperTrack", .{});
            p.f_staging = try arena.alloc(f32, p.f_upload_len);
            @memset(p.f_staging, 0.0);
            pipe.element_count = p.param_count;
            return p;
        }

        /// A kit holding `st`'s exact weights - for checking one against the other.
        pub fn initFrom(gpa: Allocator, pipe: *compute_host.Compute(M), st: *const SuperTrack) !Self {
            var p: Self = try .init(gpa, pipe, st.options);
            errdefer p.deinit();
            const arena: Allocator = p.arena_state.allocator();
            const params_: []f32 = try arena.alloc(f32, p.param_count);
            copyNet(params_, p.pol, &st.policy);
            copyNet(params_, p.wm, &st.world);
            pipe.upload(.params, params_);
            @memset(params_, 0.0);
            pipe.upload(.adam_m, params_);
            pipe.upload(.adam_v, params_);
            return p;
        }

        fn copyNet(out: []f32, offsets: [3]u32, net: *const Net) void {
            for (net.layers, offsets) |layer, off| {
                @memcpy(out[off..][0..layer.w.data.len], layer.w.data);
                @memcpy(out[off + layer.w.data.len ..][0..layer.b.data.len], layer.b.data);
            }
        }

        pub fn deinit(p: *Self) void {
            p.arena_state.deinit();
        }

        fn run(p: *Self, comptime kernel: []const u8, params_: M.Params, n: u32) void {
            p.pipe.params = params_;
            p.pipe.run(kernel, n);
        }

        /// The kernels' shared parameters: the options' step, scale, noise and weights.
        fn base(p: *const Self) M.Params {
            return .{
                .rows = p.rows,
                .dt = p.options.dt,
                .acc_scale = acc_scale,
                .sigma = p.options.sigma,
                .w_cart = p.options.w_cart,
                .w_cart_rate = p.options.w_cart_rate,
                .w_pole = p.options.w_pole,
                .w_pole_rate = p.options.w_pole_rate,
                .w_action = p.options.w_action,
            };
        }

        fn fwd(
            p: *Self,
            x: u32,
            in: u32,
            out: u32,
            activation: M.Act,
            w: u32,
            y: u32,
        ) void {
            var q: M.Params = p.base();
            q.in_dim = in;
            q.out_dim = out;
            q.act = @backingInt(activation);
            q.x_off = x;
            q.w_off = w;
            q.y_off = y;
            p.run("dense_fwd", q, p.rows * out);
        }

        fn mlpFwd(
            p: *Self,
            net: [3]u32,
            x: u32,
            out: u32,
            h1: u32,
            h2: u32,
            y: u32,
        ) void {
            p.fwd(x, 4, p.hidden, .tanh, net[0], h1);
            p.fwd(h1, p.hidden, p.hidden, .tanh, net[1], h2);
            p.fwd(h2, p.hidden, out, .linear, net[2], y);
        }

        fn bwdW(
            p: *Self,
            x: u32,
            in: u32,
            out: u32,
            w: u32,
            dy: u32,
            accumulate: bool,
        ) void {
            var q: M.Params = p.base();
            q.in_dim = in;
            q.out_dim = out;
            q.x_off = x;
            q.w_off = w;
            q.dy_off = dy;
            q.accumulate = @intFromBool(accumulate);
            p.run("dense_bwd_w", q, in * out + out);
        }

        fn bwdX(
            p: *Self,
            in: u32,
            out: u32,
            w: u32,
            dy: u32,
            dx: u32,
        ) void {
            var q: M.Params = p.base();
            q.in_dim = in;
            q.out_dim = out;
            q.w_off = w;
            q.dy_off = dy;
            q.dx_off = dx;
            p.run("dense_bwd_x", q, p.rows * in);
        }

        fn tanhBwd(p: *Self, out: u32, y: u32, dy: u32) void {
            var q: M.Params = p.base();
            q.out_dim = out;
            q.act = @backingInt(M.Act.tanh);
            q.y_off = y;
            q.dy_off = dy;
            p.run("act_bwd", q, p.rows * out);
        }

        fn adam(
            p: *Self,
            start: u32,
            count: u32,
            step: u32,
            rate: f64,
        ) void {
            const s: f32 = float(step);
            var q: M.Params = p.base();
            q.w_off = start;
            q.count = count;
            q.rate = @floatCast(rate);
            q.correction1 = 1.0 / (1.0 - @exp(s * @log(@as(f32, 0.9))));
            q.correction2 = 1.0 / (1.0 - @exp(s * @log(@as(f32, 0.999))));
            p.run("adam", q, count);
        }

        /// One integration step's forward: world model on [rates, angle, force], then `cp_step`.
        fn worldForward(
            p: *Self,
            state: u32,
            force: u32,
            in: u32,
            g1: u32,
            g2: u32,
            acc: u32,
            next: u32,
        ) void {
            var q: M.Params = p.base();
            q.x_off = state;
            q.u_off = force;
            q.z_off = in;
            p.run("cp_wm_input", q, p.rows);
            p.mlpFwd(p.wm, in, 2, g1, g2, acc);
            var s: M.Params = p.base();
            s.x_off = state;
            s.y_off = acc;
            s.z_off = next;
            p.run("cp_step", s, p.rows);
        }

        /// A step's backward from the next state's gradient (`cur`): the tracking gradient added
        /// against `target`, the step's adjoint into `nxt`, the world model's input gradient (its
        /// weight gradients only when `world_weights`, summed over steps unless `first`).
        fn stepBackward(
            p: *Self,
            next_state: u32,
            target: u32,
            cur: u32,
            nxt: u32,
            in: u32,
            g1: u32,
            g2: u32,
            first: bool,
            world_weights: bool,
        ) void {
            var t: M.Params = p.base();
            t.x_off = next_state;
            t.t_off = target;
            t.dy_off = cur;
            t.accumulate = @intFromBool(!first);
            p.run("cp_track_bwd", t, p.rows * 4);
            var s: M.Params = p.base();
            s.dy_off = cur;
            s.e_off = nxt;
            s.dx_off = p.d_acc;
            p.run("cp_step_bwd", s, p.rows);
            const h: u32 = p.hidden;
            if (world_weights) {
                p.bwdW(g2, h, 2, p.wm[2], p.d_acc, !first);
            }
            p.bwdX(h, 2, p.wm[2], p.d_acc, p.d_wh2);
            p.tanhBwd(h, g2, p.d_wh2);
            if (world_weights) {
                p.bwdW(g1, h, h, p.wm[1], p.d_wh2, !first);
            }
            p.bwdX(h, h, p.wm[1], p.d_wh2, p.d_wh1);
            p.tanhBwd(h, g1, p.d_wh1);
            if (world_weights) {
                p.bwdW(in, 4, h, p.wm[0], p.d_wh1, !first);
            }
            p.bwdX(4, h, p.wm[0], p.d_wh1, p.d_win);
            var w: M.Params = p.base();
            w.dx_off = p.d_win;
            w.dy_off = nxt;
            w.e_off = p.d_f;
            p.run("cp_wm_input_bwd", w, p.rows);
        }

        /// `SuperTrack.trainWorldWith`, as kernels.
        pub fn trainWorldWith(p: *Self, states: []const f32, forces_unit: []const f32) void {
            const n: usize = p.options.wm_window;
            const r: usize = p.rows;
            for (0..r) |row| {
                @memcpy(p.staging[p.w_start + row * 4 ..][0..4], states[row * (n + 1) * 4 ..][0..4]);
                for (0..n) |k| {
                    const real: []const f32 = states[(row * (n + 1) + k + 1) * 4 ..][0..4];
                    @memcpy(p.staging[p.w_target[k] + row * 4 ..][0..4], real);
                    p.staging[p.w_force[k] + row] = forces_unit[row * n + k];
                }
            }
            // Only the world step's own region: the policy step's is disjoint (see `uploadAt`).
            p.pipe.uploadAt(.acts, p.w_start, p.staging[p.w_start..p.upload_len]);
            p.pipe.beginRecording();
            for (0..n) |k| {
                const next: u32 = p.w_state[k + 1];
                p.worldForward(p.w_state[k], p.w_force[k], p.w_in[k], p.w_g1[k], p.w_g2[k], p.w_acc[k], next);
            }
            var cur: u32 = p.d_a;
            var nxt: u32 = p.d_b;
            var k: usize = n;
            while (k > 0) {
                k -= 1;
                const last: bool = k == n - 1;
                p.stepBackward(p.w_state[k + 1], p.w_target[k], cur, nxt, p.w_in[k], p.w_g1[k], p.w_g2[k], last, true);
                std.mem.swap(u32, &cur, &nxt);
            }
            p.wm_step += 1;
            p.adam(p.wm[0], p.wm_count, p.wm_step, p.options.wm_rate);
            p.pipe.submitRecording();
        }

        /// `SuperTrack.trainPolicyWith`, as kernels.
        pub fn trainPolicyWith(p: *Self, starts: []const f32, noise: []const f32) void {
            const n: usize = p.options.policy_window;
            const r: usize = p.rows;
            @memcpy(p.staging[p.p_start..][0 .. r * 4], starts[0 .. r * 4]);
            for (0..n) |k| {
                @memcpy(p.staging[p.p_eps[k]..][0..r], noise[k * r ..][0..r]);
            }
            @memset(p.staging[p.zero..][0 .. r * 4], 0.0);
            // Only the policy step's own region (the zero target, starts, noise).
            p.pipe.uploadAt(.acts, 0, p.staging[0..p.w_start]);
            // ONE submission for the whole window, ~900 dispatches (compute_host's recording, §8 E1).
            p.pipe.beginRecording();
            for (0..n) |k| {
                p.mlpFwd(p.pol, p.p_state[k], 1, p.p_h1[k], p.p_h2[k], p.p_o[k]);
                var f: M.Params = p.base();
                f.y_off = p.p_o[k];
                f.x_off = p.p_eps[k];
                f.u_off = p.p_f[k];
                p.run("cp_force", f, p.rows);
                p.worldForward(p.p_state[k], p.p_f[k], p.p_in[k], p.p_g1[k], p.p_g2[k], p.p_acc[k], p.p_state[k + 1]);
            }
            var cur: u32 = p.d_a;
            var nxt: u32 = p.d_b;
            const h: u32 = p.hidden;
            var k: usize = n;
            while (k > 0) {
                k -= 1;
                const first: bool = k == n - 1;
                p.stepBackward(p.p_state[k + 1], p.zero, cur, nxt, p.p_in[k], p.p_g1[k], p.p_g2[k], first, false);
                var fb: M.Params = p.base();
                fb.u_off = p.p_f[k];
                fb.y_off = p.p_o[k];
                fb.e_off = p.d_f;
                fb.dy_off = p.d_o;
                p.run("cp_force_bwd", fb, p.rows);
                p.bwdW(p.p_h2[k], h, 1, p.pol[2], p.d_o, !first);
                p.bwdX(h, 1, p.pol[2], p.d_o, p.d_ph2);
                p.tanhBwd(h, p.p_h2[k], p.d_ph2);
                p.bwdW(p.p_h1[k], h, h, p.pol[1], p.d_ph2, !first);
                p.bwdX(h, h, p.pol[1], p.d_ph2, p.d_ph1);
                p.tanhBwd(h, p.p_h1[k], p.d_ph1);
                p.bwdW(p.p_state[k], 4, h, p.pol[0], p.d_ph1, !first);
                p.bwdX(4, h, p.pol[0], p.d_ph1, p.d_pin);
                var add: M.Params = p.base();
                add.dy_off = nxt;
                add.dx_off = p.d_pin;
                add.count = p.rows * 4;
                p.run("add_block", add, p.rows * 4);
                std.mem.swap(u32, &cur, &nxt);
            }
            p.pol_step += 1;
            p.adam(p.pol[0], p.pol_count, p.pol_step, p.options.policy_rate);
            p.pipe.submitRecording();
        }

        /// `trainWorldWith`, FUSED: four dispatches (forward, backward, reduce, Adam) instead of
        /// ~150 - one thread per row walks the whole window.
        pub fn trainWorldFused(p: *Self, states: []const f32, forces_unit: []const f32) void {
            const n: usize = p.options.wm_window;
            const r: usize = p.rows;
            for (0..r) |row| {
                @memcpy(p.f_staging[p.f_w_start + row * 4 ..][0..4], states[row * (n + 1) * 4 ..][0..4]);
                for (0..n) |k| {
                    const real: []const f32 = states[(row * (n + 1) + k + 1) * 4 ..][0..4];
                    @memcpy(p.f_staging[p.f_w_target + (k * r + row) * 4 ..][0..4], real);
                    p.f_staging[p.f_w_force + k * r + row] = forces_unit[row * n + k];
                }
            }
            p.pipe.uploadAt(.acts, p.f_w_start, p.f_staging[p.f_w_start..p.f_upload_len]);
            p.pipe.beginRecording();
            var q: M.Params = p.base();
            q.in_dim = p.hidden;
            q.x_off = p.f_w_records;
            q.z_off = p.f_w_start;
            q.y_off = p.f_w_force;
            q.t_off = p.f_w_target;
            q.w_off = p.wm[0];
            q.count = @intCast(n);
            q.dx_off = p.f_wm_grads;
            q.e_off = p.f_scratch;
            p.run("st_world_fwd", q, p.rows);
            p.run("st_world_bwd", q, p.rows);
            var red: M.Params = p.base();
            red.w_off = p.wm[0];
            red.count = p.wm_count;
            red.dx_off = p.f_wm_grads;
            p.run("st_reduce", red, p.wm_count);
            p.wm_step += 1;
            p.adam(p.wm[0], p.wm_count, p.wm_step, p.options.wm_rate);
            p.pipe.submitRecording();
        }

        /// `trainPolicyWith`, FUSED: four dispatches instead of ~900.
        pub fn trainPolicyFused(p: *Self, starts: []const f32, noise: []const f32) void {
            const n: usize = p.options.policy_window;
            const r: usize = p.rows;
            @memcpy(p.f_staging[p.f_p_start..][0 .. r * 4], starts[0 .. r * 4]);
            @memcpy(p.f_staging[p.f_p_eps..][0 .. n * r], noise[0 .. n * r]);
            p.pipe.uploadAt(.acts, p.f_p_start, p.f_staging[p.f_p_start..p.f_w_start]);
            p.pipe.beginRecording();
            var q: M.Params = p.base();
            q.in_dim = p.hidden;
            q.x_off = p.f_p_records;
            q.z_off = p.f_p_start;
            q.y_off = p.f_p_eps;
            q.w_off = p.pol[0];
            q.v_off = p.wm[0];
            q.count = @intCast(n);
            q.dx_off = p.f_pol_grads;
            q.e_off = p.f_scratch;
            p.run("st_policy_fwd", q, p.rows);
            p.run("st_policy_bwd", q, p.rows);
            var red: M.Params = p.base();
            red.w_off = p.pol[0];
            red.count = p.pol_count;
            red.dx_off = p.f_pol_grads;
            p.run("st_reduce", red, p.pol_count);
            p.pol_step += 1;
            p.adam(p.pol[0], p.pol_count, p.pol_step, p.options.policy_rate);
            p.pipe.submitRecording();
        }

        pub fn readParams(p: *Self) ?[]const f32 {
            return p.pipe.readLatest(.params);
        }

        /// The largest difference between the kit's policy and world model and `st`'s.
        pub fn gapsTo(p: *const Self, st: *const SuperTrack, kit: []const f32) [2]f32 {
            return .{ netGap(kit, p.pol, &st.policy), netGap(kit, p.wm, &st.world) };
        }

        fn netGap(kit: []const f32, offsets: [3]u32, net: *const Net) f32 {
            var worst: f32 = 0.0;
            for (net.layers, offsets) |layer, off| {
                for (layer.w.data, 0..) |v, i| {
                    worst = @max(worst, @abs(v - kit[off + i]));
                }
                for (layer.b.data, 0..) |v, i| {
                    worst = @max(worst, @abs(v - kit[off + layer.w.data.len + i]));
                }
            }
            return worst;
        }
    };
}

/// Pushes: every `push_every` steps the pole's rate jumps by up to +-`push_size` rad/s.
pub const push_every: u32 = 40;
pub const push_size: f32 = 0.4;
pub const episode_cap: u32 = 500;

/// Mean episode length of `episodes` REAL cartpole episodes under pushes: the policy without
/// noise, or no force at all (`policy` null) for the baseline.
pub fn evaluate(st: ?*SuperTrack, episodes: u32, seed: u64) f32 {
    var rng: std.Random.DefaultPrng = .init(seed);
    const random: std.Random = rng.random();
    var total: u32 = 0;
    for (0..episodes) |e| {
        var state = zn.cartpoleTaskReset(f32, zn.Rng.init(@truncate(seed)), @intCast(e), .hold);
        var steps: u32 = 0;
        while (steps < episode_cap) : (steps += 1) {
            if (steps > 0 and steps % push_every == 0) {
                state.pole_rate_rad += push_size * (2.0 * random.float(f32) - 1.0);
            }
            const force: f32 = if (st) |s| s.act(fromCartpole(state), false) else 0.0;
            const stepped = zn.cartpoleContinuousStep(f32, state, force);
            if (stepped.failed) {
                break;
            }
            state = stepped.state;
        }
        total += steps;
    }
    return float(total) / float(episodes);
}

test "supertrack: supervised learning alone holds a real cartpole upright under pushes" {
    // ★★★ SIMON'S QUESTION: can a world model learned by supervision, and a policy optimised by
    // back-propagating a tracking loss through it, hold a REAL cartpole upright under pushes -
    // with no reward, no critic, no MPC and no PPO or SAC? Eight cartpoles gather data with the
    // current policy plus noise; each iteration trains the world model one step and the policy
    // one step; every 250 iterations the policy, WITHOUT noise, runs 10 real episodes of up to
    // 500 steps with a push every 40. The zero-force baseline says what the pushes alone do.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const final_eval: f32 = try runCartpole(.{}, 3000, 250);
    try expect(final_eval > evaluate(null, 10, 99) * 4.0);
}

test "supertrack: the page's small configuration - its cost, and that it still learns" {
    // What the page can afford: batch 16 and a 16-frame policy window (0.32 s here) - the cost
    // an iteration, and the real episodes it reaches in 1,500 iterations.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const final_eval: f32 = try runCartpole(.{ .batch = 16, .policy_window = 16 }, 1500, 500);
    try expect(final_eval > evaluate(null, 10, 99) * 4.0);
}

/// The gym and the training loop over zimrnum's cartpole: `iterations` of (gather 4 ticks of 8
/// cartpoles, one world-model step, one policy step), the real evaluation every `every`.
fn runCartpole(options: Options, iterations: usize, every: usize) !f32 {
    const gpa: Allocator = std.testing.allocator;
    const st: *SuperTrack = try .init(gpa, options);
    defer st.deinit();
    const envs: usize = 8;
    var states: [8]zn.CartpoleState(f32) = undefined;
    var steps: [8]u32 = @splat(0);
    var segments: [8]u32 = undefined;
    var next_segment: u32 = 0;
    var episode: u32 = 0;
    for (0..envs) |e| {
        states[e] = zn.cartpoleTaskReset(f32, zn.Rng.init(7), episode, .hold);
        episode += 1;
        segments[e] = next_segment;
        next_segment += 1;
    }
    const baseline: f32 = evaluate(null, 10, 99);
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  SuperTrack alone, real cartpole, a push every {d} steps (cap {d}):\n", .{
        push_every,
        episode_cap,
    });
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("    zero-force baseline: {d:.1} steps\n", .{baseline});
    var samples: usize = 0;
    var wm_loss: f32 = 0;
    var pi_loss: f32 = 0;
    var final_eval: f32 = 0;
    const io: std.Io = std.testing.io;
    var train_ns: i96 = 0;
    for (1..iterations + 1) |iteration| {
        // Gather: 4 ticks of 8 cartpoles, the current policy plus noise.
        for (0..4) |_| {
            for (0..envs) |e| {
                if (steps[e] > 0 and steps[e] % push_every == 0) {
                    states[e].pole_rate_rad += push_size * (2.0 * st.rng.random().float(f32) - 1.0);
                    segments[e] = next_segment;
                    next_segment += 1;
                }
                const force: f32 = st.act(fromCartpole(states[e]), true);
                st.remember(e, fromCartpole(states[e]), force, segments[e]);
                const stepped = zn.cartpoleContinuousStep(f32, states[e], force);
                steps[e] += 1;
                samples += 1;
                if (stepped.failed or steps[e] >= episode_cap) {
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
        const started: std.Io.Timestamp = std.Io.Clock.now(.awake, io);
        if (try st.trainWorld()) |l| {
            wm_loss = l;
        }
        if (try st.trainPolicy()) |l| {
            pi_loss = l;
        }
        train_ns += std.Io.Clock.now(.awake, io).nanoseconds - started.nanoseconds;
        if (iteration % every == 0) {
            final_eval = evaluate(st, 10, 99);
            // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
            std.debug.print("    iteration {d:>4} ({d:>6} samples): world loss {e:.2}, policy loss {d:.4}, " ++
                "REAL episodes {d:.1} steps\n", .{ iteration, samples, wm_loss, pi_loss, final_eval });
        }
    }
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("    training: {d:.2} ms an iteration (batch {d}, windows {d}/{d})\n", .{
        @as(f64, @floatFromInt(train_ns)) / 1.0e6 / @as(f64, @floatFromInt(iterations)),
        options.batch,
        options.wm_window,
        options.policy_window,
    });
    return final_eval;
}
