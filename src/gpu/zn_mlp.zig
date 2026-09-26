//! zn_mlp - dense layers on the GPU, and on the CPU twin from the same source.
//!
//! `zn_train` proves the pipeline with ONE hidden layer in buffers of 4,096 floats; this is the
//! kit that trains any stack of dense layers: forward, backward to the weights AND to the inputs,
//! activation gradients, an MSE gradient and Adam - each a kernel over flat buffers, addressed by
//! offsets the host writes into the params before each dispatch. One dispatch per layer
//! operation, one thread per output element (the tiled matmul, `zn_matmul.matmul_tiled`, is the
//! later speed step; correctness first). `z.Compute` uploads the params anew before every
//! unbatched dispatch, which is what lets one pipeline serve every layer of every network.
//!
//! ── LAYOUT ──
//!   params   per layer: W row-major [in, out], then b [out]
//!   grads    laid out exactly like params
//!   adam_m, adam_v   laid out exactly like params
//!   acts     inputs, each layer's outputs, targets - [rows, width] row-major, at host offsets
//!   dacts    the gradients of those, at host offsets
//!
//! BACKWARD TO THE INPUTS (`dense_bwd_x`) is not optional here: SAC's actor learns through the
//! critic, so the critic's gradient must reach its action input.

const k = @import("kompute");
const zm = @import("zm");
const float = zm.float;
const sqrt = zm.sqrt;
const tanh = zm.tanh;
const exp = zm.exp;
const ln = zm.ln;
const clamp = zm.clamp;

/// Floats per buffer: 256k (1 MiB). A SAC critic for the humanoid - 97 inputs, two layers of
/// 256, batch 256 - needs ~150k floats of activations; its weights ~92k.
pub const config = k.Config{ .max = 1 << 18, .workgroup = 64 };

/// What a layer's output goes through.
pub const Act = enum(u32) { linear = 0, tanh = 1, relu = 2 };

/// Everything a dispatch needs, written by the host before it.
pub const Params = extern struct {
    rows: u32 = 0,
    in_dim: u32 = 0,
    out_dim: u32 = 0,
    act: u32 = 0,
    /// acts offsets: the layer's input, its output, and (for MSE) the targets.
    x_off: u32 = 0,
    y_off: u32 = 0,
    t_off: u32 = 0,
    /// params / grads / adam offset of the layer's W (b follows it).
    w_off: u32 = 0,
    /// dacts offsets: the gradient at the layer's output, and at its input.
    dy_off: u32 = 0,
    dx_off: u32 = 0,
    /// A count, SHARED by kernels that need one - read the kernel's own doc: the elements `adam`,
    /// `polyak`, `add_block` and `st_reduce` process (from their offsets); the WINDOW LENGTH for
    /// the fused st_ kernels.
    count: u32 = 0,
    _p0: u32 = 0,
    rate: f32 = 0,
    beta1: f32 = 0.9,
    beta2: f32 = 0.999,
    epsilon: f32 = 1.0e-8,
    /// Adam's bias corrections, 1 / (1 - beta^t), computed on the host: no pow in a kernel.
    correction1: f32 = 1,
    correction2: f32 = 1,
    /// PPO's clip range epsilon (`ppo_mean_grad`, `ppo_logstd_grad`).
    clip: f32 = 0.2,
    _p2: u32 = 0,
    // ── SAC (the squash / target / temperature kernels below) ──
    /// A third acts offset (the second critic's output, an action's destination block).
    z_off: u32 = 0,
    /// acts offset of the pre-squash u (written forward, read backward).
    u_off: u32 = 0,
    /// acts offset of the per-row log-probability.
    l_off: u32 = 0,
    /// Row stride of an interleaved [state | action] block; 0 means rows of `in_dim`. Dense
    /// layers read their input rows with it, so the actor reads states straight out of the
    /// critic's input rows.
    stride: u32 = 0,
    /// The column an action starts at inside a strided row.
    col: u32 = 0,
    /// A second params offset: log alpha for the SAC kernels, the online copy for `polyak`.
    v_off: u32 = 0,
    /// A second dacts offset (the second critic's input gradient).
    e_off: u32 = 0,
    gamma: f32 = 0.99,
    tau: f32 = 0.005,
    target_entropy: f32 = -1.0,
    /// The bounds the actor's raw log-std is squashed into: min + half (1 + tanh(raw)).
    log_std_min: f32 = -5.0,
    log_std_max: f32 = 2.0,
    // ── SuperTrack on the cartpole (the cp_ kernels) ──
    /// 1: `dense_bwd_w` and `cp_track_bwd` ADD into their destination (gradients summed over
    /// unrolled steps); 0: they overwrite it.
    accumulate: u32 = 0,
    /// The simulator's step (s), the world model's output scale (its outputs are accelerations
    /// divided by this), and the exploration noise on the policy's pre-squash output.
    dt: f32 = 0.02,
    acc_scale: f32 = 10.0,
    sigma: f32 = 0.1,
    /// The tracking weights on (cart, cart rate, pole angle, pole rate), and the action penalty.
    w_cart: f32 = 1.0,
    w_cart_rate: f32 = 0.1,
    w_pole: f32 = 10.0,
    w_pole_rate: f32 = 0.1,
    w_action: f32 = 0.01,
    // ── The latent model's gather (`lat_gather`): sizes, and where each resident region starts
    // in the activation buffer. Named for what they are rather than borrowing other kernels'
    // fields - twelve words, 48 bytes, so the struct keeps its 16-byte multiple.
    lat_features: u32 = 0,
    lat_references: u32 = 0,
    lat_actions: u32 = 0,
    lat_steps: u32 = 0,
    lat_envs: u32 = 0,
    lat_capacity: u32 = 0,
    ring_off: u32 = 0,
    table_off: u32 = 0,
    norm_off: u32 = 0,
    starts_off: u32 = 0,
    blocks_off: u32 = 0,
    targets_off: u32 = 0,
    /// Goal columns in front of each wide row (0, or the feature count when a policy trains through
    /// the rollout), and where the contiguous goal block starts. Two padding words keep the 16-byte
    /// multiple.
    lat_lead: u32 = 0,
    goals_off: u32 = 0,
    _p7: u32 = 0,
    _p8: u32 = 0,
    /// The policy's action, as `lat_act` writes it: `lat_scale * (raw + lat_sigma * noise)`, the
    /// noise a hash of (`lat_seed`, row, column) - declared together so the noise needs no second
    /// change to this block. 16 bytes.
    lat_scale: f32 = 1.0,
    lat_sigma: f32 = 0.0,
    lat_seed: u32 = 0,
    _p9: u32 = 0,
    /// The action price's gradient coefficient for `lat_act_bwd` (2 w_action / (rows x actions)), and
    /// the SMOOTHNESS term's (CAPS: 2 w_smooth / (rows x actions)) with where the previous and next window
    /// steps' raw actions start. A step with no such neighbour points at ITSELF (its own `x_off`), so
    /// `raw - raw` is exactly zero: no sentinel to compare, no branch - nothing a shader translation can get
    /// subtly wrong. Once padding: the block is still 16 bytes.
    lat_penalty: f32 = 0.0,
    lat_smooth: f32 = 0.0,
    lat_prev: u32 = 0,
    lat_next: u32 = 0,
    _p4: u32 = 0,
    _p5: u32 = 0,
    _p6: u32 = 0,
};

/// The activation buffer is the one that grows: eight times the others. Everything the latent
/// world model's training keeps RESIDENT on the GPU lives in it - the rollout's blocks, and past them
/// the replay of features and the reference tables - because it cannot live in a buffer of its own:
/// WebGPU guarantees only 8 storage buffers to a shader stage, this kit already binds 7, and a binding
/// past the limit is not an error anywhere - its writes are silently dropped (compute_host.zig tells
/// that story). Every buffer is sized by its own field here, on the GPU and in the CPU twin alike;
/// the twin's arrays are static, so this is 8 MB of wasm memory on every page using the kit.
pub const acts_len: u32 = 1 << 21;

pub const Buffers = extern struct {
    acts: [acts_len]f32,
    dacts: [config.max]f32,
    params: [config.max]f32,
    grads: [config.max]f32,
    adam_m: [config.max]f32,
    adam_v: [config.max]f32,
    loss: [config.max]f32,
};

pub const g = k.Globals(@This());
const b_acts = g.bind(.acts);
const b_dacts = g.bind(.dacts);
const b_params = g.bind(.params);
const b_grads = g.bind(.grads);
const b_m = g.bind(.adam_m);
const b_v = g.bind(.adam_v);
const b_loss = g.bind(.loss);
const params = g.uniform();

inline fn activate(x: f32, act: u32) f32 {
    if (act == @backingInt(Act.tanh)) {
        return tanh(x);
    }
    if (act == @backingInt(Act.relu)) {
        return @max(x, 0.0);
    }
    return x;
}

/// The activation's derivative, from its OUTPUT: tanh' = 1 - y^2, relu' = [y > 0].
inline fn derivative(y: f32, act: u32) f32 {
    if (act == @backingInt(Act.tanh)) {
        return 1.0 - y * y;
    }
    if (act == @backingInt(Act.relu)) {
        return if (y > 0.0) 1.0 else 0.0;
    }
    return 1.0;
}

/// Input rows are `in_dim` apart unless a stride is given (an interleaved block).
inline fn inputStride() u32 {
    return if (params.stride != 0) params.stride else params.in_dim;
}

/// y[r, o] = act(b[o] + sum_i x[r, i] W[i, o]); one thread per (r, o).
pub fn dense_fwd(id: u32) void {
    if (id >= params.rows * params.out_dim) {
        return;
    }
    const r: u32 = id / params.out_dim;
    const o: u32 = id % params.out_dim;
    var acc: f32 = b_params[params.w_off + params.in_dim * params.out_dim + o];
    var i: u32 = 0;
    while (i < params.in_dim) : (i += 1) {
        acc += b_acts[params.x_off + r * inputStride() + i] * b_params[params.w_off + i * params.out_dim + o];
    }
    b_acts[params.y_off + id] = activate(acc, params.act);
}

/// dy[r, o] *= act'(y[r, o]), in place: the gradient at the pre-activation.
pub fn act_bwd(id: u32) void {
    if (id >= params.rows * params.out_dim) {
        return;
    }
    const y: f32 = b_acts[params.y_off + id];
    b_dacts[params.dy_off + id] = b_dacts[params.dy_off + id] * derivative(y, params.act);
}

/// dx[r, i] = sum_o dz[r, o] W[i, o]; one thread per (r, i).
pub fn dense_bwd_x(id: u32) void {
    if (id >= params.rows * params.in_dim) {
        return;
    }
    const r: u32 = id / params.in_dim;
    const i: u32 = id % params.in_dim;
    var acc: f32 = 0.0;
    var o: u32 = 0;
    while (o < params.out_dim) : (o += 1) {
        acc += b_dacts[params.dy_off + r * params.out_dim + o] * b_params[params.w_off + i * params.out_dim + o];
    }
    b_dacts[params.dx_off + id] = acc;
}

/// gW[i, o] = sum_r x[r, i] dz[r, o], then gb[o] = sum_r dz[r, o]: one thread per weight.
pub fn dense_bwd_w(id: u32) void {
    const weights: u32 = params.in_dim * params.out_dim;
    if (id >= weights + params.out_dim) {
        return;
    }
    var acc: f32 = 0.0;
    var r: u32 = 0;
    if (id < weights) {
        const i: u32 = id / params.out_dim;
        const o: u32 = id % params.out_dim;
        while (r < params.rows) : (r += 1) {
            acc += b_acts[params.x_off + r * inputStride() + i] * b_dacts[params.dy_off + r * params.out_dim + o];
        }
    } else {
        const o: u32 = id - weights;
        while (r < params.rows) : (r += 1) {
            acc += b_dacts[params.dy_off + r * params.out_dim + o];
        }
    }
    if (params.accumulate != 0) {
        b_grads[params.w_off + id] += acc;
    } else {
        b_grads[params.w_off + id] = acc;
    }
}

/// dy = 2 (y - t) / n over the rows x out_dim outputs: the gradient of their mean square error.
pub fn mse_bwd(id: u32) void {
    const n: u32 = params.rows * params.out_dim;
    if (id >= n) {
        return;
    }
    const diff: f32 = b_acts[params.y_off + id] - b_acts[params.t_off + id];
    b_dacts[params.dy_off + id] = 2.0 * diff / float(n);
}

/// loss[0] = mean (y - t)^2, one thread: for the readback, not for training.
pub fn mse_value(id: u32) void {
    if (id != 0) {
        return;
    }
    const n: u32 = params.rows * params.out_dim;
    var sum: f32 = 0.0;
    var j: u32 = 0;
    while (j < n) : (j += 1) {
        const diff: f32 = b_acts[params.y_off + j] - b_acts[params.t_off + j];
        sum += diff * diff;
    }
    b_loss[0] = sum / float(n);
}

// ── THE GAUSSIAN PPO HEAD ──
//
// For a diagonal Gaussian policy (mean from the policy MLP at acts[y_off], one log-std per action
// dimension at params[w_off]), PPO's clipped surrogate, averaged over the rows:
//     ratio = exp(logp_new - logp_old),  loss = -mean(min(ratio A, clip(ratio, 1-e, 1+e) A))
// Its gradient flows only where the unclipped term is the minimum: dloss/dlogp = -ratio A / rows,
// else 0; then dlogp/dmean_k = (a_k - mean_k) / std_k^2 and dlogp/dlog_std_k = z_k^2 - 1. The rows
// hold, at x_off, the actions [rows, out_dim]; at t_off, the old log-probs [rows] then the
// (normalised) advantages [rows].

inline fn ppoLogpGrad(r: u32) f32 {
    const dims: u32 = params.out_dim;
    var logp: f32 = 0.0;
    var j: u32 = 0;
    while (j < dims) : (j += 1) {
        const log_std: f32 = b_params[params.w_off + j];
        const at: u32 = r * dims + j;
        const z: f32 = (b_acts[params.x_off + at] - b_acts[params.y_off + at]) / exp(log_std);
        logp += -0.5 * z * z - log_std - 0.9189385;
    }
    const ratio: f32 = exp(logp - b_acts[params.t_off + r]);
    const advantage: f32 = b_acts[params.t_off + params.rows + r];
    const unclipped: f32 = ratio * advantage;
    const clipped: f32 = clamp(ratio, 1.0 - params.clip, 1.0 + params.clip) * advantage;
    if (unclipped > clipped) {
        return 0.0; // the clipped term is the minimum: no gradient through the ratio
    }
    return -unclipped / float(params.rows);
}

/// d loss / d mean[r, k]: one thread per (row, action dimension), into dacts[dy_off].
pub fn ppo_mean_grad(id: u32) void {
    if (id >= params.rows * params.out_dim) {
        return;
    }
    const r: u32 = id / params.out_dim;
    const dim: u32 = id % params.out_dim;
    const log_std: f32 = b_params[params.w_off + dim];
    const variance: f32 = exp(2.0 * log_std);
    const deviation: f32 = b_acts[params.x_off + id] - b_acts[params.y_off + id];
    b_dacts[params.dy_off + id] = ppoLogpGrad(r) * deviation / variance;
}

/// d loss / d log_std[k]: one thread per action dimension, summed over the rows, into grads.
pub fn ppo_logstd_grad(id: u32) void {
    if (id >= params.out_dim) {
        return;
    }
    const log_std: f32 = b_params[params.w_off + id];
    var acc: f32 = 0.0;
    var r: u32 = 0;
    while (r < params.rows) : (r += 1) {
        const row: u32 = r * params.out_dim + id;
        const z: f32 = (b_acts[params.x_off + row] - b_acts[params.y_off + row]) / exp(log_std);
        acc += ppoLogpGrad(r) * (z * z - 1.0);
    }
    b_grads[params.w_off + id] = acc;
}

/// Adam over `count` elements from `w_off`, with the host's bias corrections.
pub fn adam(id: u32) void {
    if (id >= params.count) {
        return;
    }
    const j: u32 = params.w_off + id;
    const grad: f32 = b_grads[j];
    const m: f32 = params.beta1 * b_m[j] + (1.0 - params.beta1) * grad;
    const v: f32 = params.beta2 * b_v[j] + (1.0 - params.beta2) * grad * grad;
    b_m[j] = m;
    b_v[j] = v;
    const m_hat: f32 = m * params.correction1;
    const v_hat: f32 = v * params.correction2;
    b_params[j] -= params.rate * m_hat / (sqrt(v_hat) + params.epsilon);
}

// ── SAC ──
//
// The actor is a tanh-squashed Gaussian with ONE learned log-std per action dimension, bounded as
// `log_std_min + half (1 + tanh(raw))` - exactly `robot_gym.SacAgent`'s parameterisation, so the
// two can be checked against each other on the same numbers. Alpha lives in params at `v_off`, as
// log alpha, and is read (never written) by every kernel but its own Adam step.

inline fn boundedLogStd(raw: f32) f32 {
    const half: f32 = 0.5 * (params.log_std_max - params.log_std_min);
    return params.log_std_min + half * (1.0 + tanh(raw));
}

inline fn softplus(x: f32) f32 {
    if (x > 20.0) {
        return x;
    }
    return ln(1.0 + exp(x));
}

/// log(1 - tanh(u)^2), in the form that stays finite where tanh(u) rounds to 1.
inline fn squashCorrection(u: f32) f32 {
    return 2.0 * (0.6931472 - u - softplus(-2.0 * u));
}

inline fn alpha() f32 {
    return exp(b_params[params.v_off]);
}

/// u = mean + std eps, a = tanh(u): u kept at acts[u_off], the action written into a strided
/// block (acts[z_off + r stride + col + k]). Means at acts[y_off], noise at acts[x_off], the raw
/// log-std at params[w_off]. One thread per (row, dimension).
pub fn squash_fwd(id: u32) void {
    if (id >= params.rows * params.out_dim) {
        return;
    }
    const r: u32 = id / params.out_dim;
    const dim: u32 = id % params.out_dim;
    const std_dev: f32 = exp(boundedLogStd(b_params[params.w_off + dim]));
    const u: f32 = b_acts[params.y_off + id] + std_dev * b_acts[params.x_off + id];
    b_acts[params.u_off + id] = u;
    b_acts[params.z_off + r * params.stride + params.col + dim] = tanh(u);
}

/// log pi per row: sum over dimensions of -eps^2/2 - log std - log(2 pi)/2 - log(1 - tanh(u)^2).
pub fn squash_logp(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    var logp: f32 = 0.0;
    var dim: u32 = 0;
    while (dim < params.out_dim) : (dim += 1) {
        const at: u32 = id * params.out_dim + dim;
        const eps: f32 = b_acts[params.x_off + at];
        const ls: f32 = boundedLogStd(b_params[params.w_off + dim]);
        logp += -0.5 * eps * eps - ls - 0.9189385 - squashCorrection(b_acts[params.u_off + at]);
    }
    b_acts[params.l_off + id] = logp;
}

/// y = r + gamma (1 - done)(min(q1', q2') - alpha log pi'): q1' at acts[y_off], q2' at
/// acts[z_off], log pi' at acts[l_off], rewards then dones at acts[x_off]; y to acts[t_off].
pub fn sac_target(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const q_next: f32 = @min(b_acts[params.y_off + id], b_acts[params.z_off + id]);
    const reward: f32 = b_acts[params.x_off + id];
    const done: f32 = b_acts[params.x_off + params.rows + id];
    const soft: f32 = q_next - alpha() * b_acts[params.l_off + id];
    b_acts[params.t_off + id] = reward + params.gamma * (1.0 - done) * soft;
}

/// The actor loss's -mean(min(q1, q2)) gradient, routed WHOLE to the smaller critic (ties go to
/// the first, as zimrnum's graph `min`): into dacts[dy_off] for q1 and dacts[dx_off] for q2.
pub fn min_route(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const share: f32 = -1.0 / float(params.rows);
    const first: bool = b_acts[params.y_off + id] <= b_acts[params.z_off + id];
    b_dacts[params.dy_off + id] = if (first) share else 0.0;
    b_dacts[params.dx_off + id] = if (first) 0.0 else share;
}

/// dL/du for the actor loss mean(alpha log pi - min q): the critics' gradient at their action
/// input (both blocks, dacts[dx_off] and dacts[e_off], strided; one of each row's is zero)
/// through tanh, plus alpha's pull through the squash correction (d/du of -log(1 - tanh^2) is
/// 2 tanh). Into dacts[dy_off] - it IS the gradient at the mean, since du/dmean = 1.
pub fn squash_bwd(id: u32) void {
    if (id >= params.rows * params.out_dim) {
        return;
    }
    const r: u32 = id / params.out_dim;
    const dim: u32 = id % params.out_dim;
    const a: f32 = tanh(b_acts[params.u_off + id]);
    const at: u32 = r * params.stride + params.col + dim;
    const dq: f32 = b_dacts[params.dx_off + at] + b_dacts[params.e_off + at];
    b_dacts[params.dy_off + id] = dq * (1.0 - a * a) + alpha() * 2.0 * a / float(params.rows);
}

/// The raw log-std's gradient: sum over rows of dL/du std eps, less alpha (the -log std in log
/// pi, averaged), through the tanh bound. du at dacts[dy_off], noise at acts[x_off].
pub fn squash_logstd_grad(id: u32) void {
    if (id >= params.out_dim) {
        return;
    }
    const raw: f32 = b_params[params.w_off + id];
    const std_dev: f32 = exp(boundedLogStd(raw));
    var acc: f32 = 0.0;
    var r: u32 = 0;
    while (r < params.rows) : (r += 1) {
        const at: u32 = r * params.out_dim + id;
        acc += b_dacts[params.dy_off + at] * std_dev * b_acts[params.x_off + at];
    }
    const t: f32 = tanh(raw);
    const bound_slope: f32 = 0.5 * (params.log_std_max - params.log_std_min) * (1.0 - t * t);
    b_grads[params.w_off + id] = (acc - alpha()) * bound_slope;
}

/// Log alpha's gradient, -alpha (mean log pi + target entropy): `zn.Temperature.gradient`.
pub fn alpha_grad(id: u32) void {
    if (id != 0) {
        return;
    }
    var sum: f32 = 0.0;
    var r: u32 = 0;
    while (r < params.rows) : (r += 1) {
        sum += b_acts[params.l_off + r];
    }
    b_grads[params.v_off] = -alpha() * (sum / float(params.rows) + params.target_entropy);
}

/// target = tau online + (1 - tau) target, over `count` params: target at w_off, online at v_off.
pub fn polyak(id: u32) void {
    if (id >= params.count) {
        return;
    }
    const j: u32 = params.w_off + id;
    b_params[j] = params.tau * b_params[params.v_off + id] + (1.0 - params.tau) * b_params[j];
}

// ── SUPERTRACK ON THE CARTPOLE ──
//
// A state is four floats per row: cart, cart rate, pole angle, pole rate. The world model takes
// [cart rate, pole angle, pole rate, force / max_force] and returns the two accelerations divided
// by `acc_scale`; `cp_step` integrates them exactly as zimrnum's cartpole does (semi-implicit:
// velocities first, positions from the NEW velocities). Every kernel's backward is its exact
// adjoint, so the policy's gradient flows back through the whole unrolled window - the
// `robot_supertrack` graph, as kernels.

/// [cart rate, pole angle, pole rate] of the state at acts[x_off] and the force at acts[u_off]
/// into the world model's input rows at acts[z_off].
pub fn cp_wm_input(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const s: u32 = params.x_off + id * 4;
    const d: u32 = params.z_off + id * 4;
    b_acts[d] = b_acts[s + 1];
    b_acts[d + 1] = b_acts[s + 2];
    b_acts[d + 2] = b_acts[s + 3];
    b_acts[d + 3] = b_acts[params.u_off + id];
}

/// The world-model input's gradient (dacts[dx_off], rows x 4) back to the state: ADDED into the
/// state gradient at dacts[dy_off] (columns 1-3); the force's share to dacts[e_off].
pub fn cp_wm_input_bwd(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const src: u32 = params.dx_off + id * 4;
    const d: u32 = params.dy_off + id * 4;
    b_dacts[d + 1] += b_dacts[src];
    b_dacts[d + 2] += b_dacts[src + 1];
    b_dacts[d + 3] += b_dacts[src + 2];
    b_dacts[params.e_off + id] = b_dacts[src + 3];
}

/// The policy's force: tanh(o + sigma eps), o at acts[y_off], eps at acts[x_off], into acts[u_off].
pub fn cp_force(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const pre: f32 = b_acts[params.y_off + id] + params.sigma * b_acts[params.x_off + id];
    b_acts[params.u_off + id] = tanh(pre);
}

/// d loss / d o: the force's gradient (dacts[e_off]) through tanh, plus the action penalty's
/// 2 w_action o / rows. Into dacts[dy_off].
pub fn cp_force_bwd(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const f: f32 = b_acts[params.u_off + id];
    const o: f32 = b_acts[params.y_off + id];
    const penalty: f32 = 2.0 * params.w_action * o / float(params.rows);
    b_dacts[params.dy_off + id] = b_dacts[params.e_off + id] * (1.0 - f * f) + penalty;
}

/// One integration step: the state at acts[x_off], the world model's output at acts[y_off]
/// (rows x 2), the next state to acts[z_off].
pub fn cp_step(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const s: u32 = params.x_off + id * 4;
    const a: u32 = params.y_off + id * 2;
    const n: u32 = params.z_off + id * 4;
    const cart_rate: f32 = b_acts[s + 1] + params.dt * params.acc_scale * b_acts[a];
    const pole_rate: f32 = b_acts[s + 3] + params.dt * params.acc_scale * b_acts[a + 1];
    b_acts[n] = b_acts[s] + params.dt * cart_rate;
    b_acts[n + 1] = cart_rate;
    b_acts[n + 2] = b_acts[s + 2] + params.dt * pole_rate;
    b_acts[n + 3] = pole_rate;
}

/// `cp_step`'s adjoint: the next state's gradient (dacts[dy_off]) to the state's (dacts[e_off],
/// OVERWRITTEN - this starts the step's state gradient) and the world model output's
/// (dacts[dx_off], rows x 2).
pub fn cp_step_bwd(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const n: u32 = params.dy_off + id * 4;
    const cart_rate_total: f32 = b_dacts[n + 1] + params.dt * b_dacts[n];
    const pole_rate_total: f32 = b_dacts[n + 3] + params.dt * b_dacts[n + 2];
    const s: u32 = params.e_off + id * 4;
    b_dacts[s] = b_dacts[n];
    b_dacts[s + 1] = cart_rate_total;
    b_dacts[s + 2] = b_dacts[n + 2];
    b_dacts[s + 3] = pole_rate_total;
    const a: u32 = params.dx_off + id * 2;
    b_dacts[a] = cart_rate_total * params.dt * params.acc_scale;
    b_dacts[a + 1] = pole_rate_total * params.dt * params.acc_scale;
}

/// The tracking loss's gradient at a state (acts[x_off], rows x 4) against a target
/// (acts[t_off]): 2 w_c (s - t) / rows, into dacts[dy_off] - ADDED when `accumulate`.
pub fn cp_track_bwd(id: u32) void {
    if (id >= params.rows * 4) {
        return;
    }
    const c: u32 = id % 4;
    var w: f32 = params.w_cart;
    if (c == 1) {
        w = params.w_cart_rate;
    } else if (c == 2) {
        w = params.w_pole;
    } else if (c == 3) {
        w = params.w_pole_rate;
    }
    const grad: f32 = 2.0 * w * (b_acts[params.x_off + id] - b_acts[params.t_off + id]) / float(params.rows);
    if (params.accumulate != 0) {
        b_dacts[params.dy_off + id] += grad;
    } else {
        b_dacts[params.dy_off + id] = grad;
    }
}

/// dacts[dy_off + i] += dacts[dx_off + i] over `count`: a gradient arriving by a second path.
pub fn add_block(id: u32) void {
    if (id >= params.count) {
        return;
    }
    b_dacts[params.dy_off + id] += b_dacts[params.dx_off + id];
}

// ── THE LATENT WORLD MODEL'S TWO JOINS ──
//
// The latent model (robot_latent.zig) steps as z' = z + Net([z | reference | action]). On the kit
// the three inputs are one wide row - a block X_k of `rows` rows, `stride` floats apart, with z in
// its first `count` columns - read by the dense layers through their input stride, so the concat is
// only a buffer layout. What the layers cannot do is JOIN the steps: put this step's z plus its
// predicted change into the next step's block, and carry the gradient back out of it. These two
// kernels are that join, forward and backward. Everything else the rollout needs already exists.

/// The next state, in two places at once: z_{k+1} = z_k + change, written into the next block's z
/// columns (strided, so the next step's first layer reads it) AND into a contiguous block (the
/// loss kernels read contiguous rows). z_k is read strided from X_k at `x_off`; the change is
/// contiguous at `t_off`; the next block at `y_off`, the contiguous copy at `z_off`. One thread per
/// (row, feature); the next block's other columns - its reference and action - are not touched.
pub fn lat_advance(id: u32) void {
    if (id >= params.rows * params.count) {
        return;
    }
    const r: u32 = id / params.count;
    const c: u32 = id % params.count;
    const next: f32 = b_acts[params.x_off + r * params.stride + c] + b_acts[params.t_off + r * params.count + c];
    b_acts[params.y_off + r * params.stride + c] = next;
    b_acts[params.z_off + r * params.count + c] = next;
}

/// The backward join: the gradient that reached a block's z columns (strided, at `dx_off`) added
/// into the state's contiguous gradient (at `dy_off`) - the path by which the loss at later steps
/// reaches earlier states THROUGH the network, beside the residual path `add_block` carries. One
/// thread per (row, feature).
pub fn lat_take(id: u32) void {
    if (id >= params.rows * params.count) {
        return;
    }
    const r: u32 = id / params.count;
    const c: u32 = id % params.count;
    b_dacts[params.dy_off + r * params.count + c] += b_dacts[params.dx_off + r * params.stride + c];
}

/// A batch of training windows, assembled on the GPU from what is resident there: the feature ring
/// (a record per character per step: raw features, action, table row), the reference tables (a row
/// per clip frame: raw goal features, encoded targets) and the normaliser (means, then spreads).
/// Per window, the host uploads only where it starts: the character, and its first record's slot -
/// two floats, holding integers (exact below 2^24).
///
/// One thread per number written, over `rows x (steps + 1) x width`, a thread (row, k, column):
///   * state columns - step 0 writes the window's first state into the first wide row; step k >= 1
///     writes the state the simulator reached after k steps, into target block k. Both normalised
///     as `(x - mean) / spread`: the CPU normaliser's operations, in its order, so the two agree
///     bit for bit.
///   * reference columns (k < steps) - copied from the table row of step k's frame. A table row is
///     [goal | encoded targets] and a wide row [state | reference | action], so the reference sits
///     at the SAME offset in both and one index serves.
///   * action columns (k < steps) - copied from step k's record.
/// The wide rows' state columns for k >= 1 are left alone: the rollout fills them.
pub fn lat_gather(id: u32) void {
    const f: u32 = params.lat_features;
    const r: u32 = params.lat_references;
    const a: u32 = params.lat_actions;
    const lead: u32 = params.lat_lead;
    // The wide row's stride: the goal columns (if any), then the world model's slice.
    const width: u32 = lead + f + r + a;
    const steps: u32 = params.lat_steps;
    if (id >= params.rows * (steps + 1) * width) {
        return;
    }
    // Unpack the thread: `column` of a wide row, `step` 0..steps (one more than the rollout's steps
    // - step `steps` exists only to write the last target and goal), `row` the window.
    const column: u32 = id % width;
    const step: u32 = (id / width) % (steps + 1);
    const row: u32 = id / (width * (steps + 1));
    // The two integers each window travels as, and the table row a record holds, are stored as
    // floats (the buffer holds nothing else) - exact below 2^24 - and `@trunc` makes them integers.
    const env: u32 = @trunc(b_acts[params.starts_off + row * 2]);
    const first_slot: u32 = @trunc(b_acts[params.starts_off + row * 2 + 1]);
    // The ring is step-major: slot s holds every character's record for one replay index, side by
    // side, so a character's consecutive records are `envs` records apart - and the ring wraps.
    const slot: u32 = (first_slot + step) % params.lat_capacity;
    const record: u32 = params.ring_off + (slot * params.lat_envs + env) * latRecordWidth(f, a);
    const table_row: u32 = @trunc(b_acts[record + latRecordTableRow(f, a)]);
    if (column < lead) {
        // GOAL columns (lead is the feature count): the reference where step `step - 1` was GOING -
        // this record's frame - normalised like every state. It is the policy's input at step - 1
        // (SuperTrack's Local(K_{i+1})), and the tracking target for the state that step produced.
        if (step == 0) {
            return;
        }
        const raw_goal: f32 = b_acts[params.table_off + table_row * latTableWidth(f, r) + column];
        const goal: f32 = (raw_goal - b_acts[params.norm_off + column]) / b_acts[params.norm_off + f + column];
        b_acts[params.blocks_off + ((step - 1) * params.rows + row) * width + column] = goal;
        b_acts[params.goals_off + ((step - 1) * params.rows + row) * f + column] = goal;
        return;
    }
    // The world model's slice: `c` counts from its first column.
    const c: u32 = column - lead;
    if (c < f) {
        // STATE columns: step 0's state is the rollout's starting point (the first wide row); every
        // later step's state is a TARGET - what the simulator reached, which the rollout's prediction
        // is scored against. The later rows' state columns are the rollout's to fill, with its own
        // predictions: the whole point of training through rollouts.
        const value: f32 = (b_acts[record + c] - b_acts[params.norm_off + c]) / b_acts[params.norm_off + f + c];
        if (step == 0) {
            b_acts[params.blocks_off + row * width + lead + c] = value;
        } else {
            b_acts[params.targets_off + ((step - 1) * params.rows + row) * f + c] = value;
        }
    } else if (c < f + r) {
        // REFERENCE columns: the encoded targets the servo aimed at during step `step - 1` - this
        // record's frame, the one that step was driving toward. A table row is [goal | encoded
        // targets] and the slice [state | reference | action], so they sit at the same offset `c`.
        if (step > 0) {
            const block: u32 = params.blocks_off + ((step - 1) * params.rows + row) * width + lead;
            b_acts[block + c] = b_acts[params.table_off + table_row * latTableWidth(f, r) + c];
        }
    } else if (step < steps) {
        // ACTION columns: the action this record's step took.
        const block: u32 = params.blocks_off + (step * params.rows + row) * width + lead;
        b_acts[block + c] = b_acts[record + latRecordAction(f) + (c - f - r)];
    }
}

/// Exploration noise, identical on every device: an integer hash of (seed, row, column) - shifts,
/// xors and wrapping multiplies, the same bits on any GPU - turned into four uniforms from its top 24
/// bits (exact as floats), summed, centred and scaled by sqrt(3): mean 0, variance 1, bounded at
/// +-3.46 (Irwin-Hall, rather than Box-Muller, whose log and cos GPUs may round differently). Plain
/// Zig, so the CPU reference calls THIS function too - no copy to drift.
// ──────── The resident data's layouts ────────
//
// Three parties have to agree on the shapes below, and only two of them exist today: the host packing
// a record (`Resident.appendLatest`) and `lat_gather` reading one. The third arrives when the
// simulator itself moves onto the GPU and a KERNEL writes the records instead of the host. Spelled out
// once here - in the module both sides already import for `latNoise` - that day is one edit rather
// than a hunt through every place the arithmetic was written out by hand.

/// Floats in one record of the feature ring: a character's raw (unnormalised) features, the action it
/// took on that step, and one more for which reference-table row it was aiming at.
pub fn latRecordWidth(features: u32, actions: u32) u32 {
    return features + actions + 1;
}

/// Where a record's action begins. (Its features begin at nothing, so they need no name.)
pub fn latRecordAction(features: u32) u32 {
    return features;
}

/// Where a record's reference-table row sits: the last column, kept as a float like everything else
/// in the buffer and rounded back to an integer when read.
pub fn latRecordTableRow(features: u32, actions: u32) u32 {
    return features + actions;
}

/// Floats in one row of the reference tables: a frame's features, then the servo targets the fleet
/// would aim at for it - everything a rollout needs about a reference frame, so a window can be built
/// without the clips being on the device at all.
pub fn latTableWidth(features: u32, references: u32) u32 {
    return features + references;
}

pub fn latNoise(seed: u32, row: u32, column: u32) f32 {
    const key: u32 = latHash(seed ^ latHash(row *% 0x9e3779b9 +% column));
    var sum: f32 = 0.0;
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        const bits: u32 = latHash(key +% i *% 0x85ebca6b) >> 8;
        sum += float(bits) * (1.0 / 16777216.0);
    }
    return (sum - 2.0) * 1.7320508;
}

/// A different seed for every step of the rollout, from one seed per training step.
pub fn latStepSeed(seed: u32, step: u32) u32 {
    return latHash(seed +% step *% 0x27d4eb2f);
}

/// Chris Wellons' lowbias32: a well-mixed 32-bit integer hash.
fn latHash(input: u32) u32 {
    var x: u32 = input;
    x ^= x >> 16;
    x *%= 0x7feb352d;
    x ^= x >> 15;
    x *%= 0x846ca68b;
    x ^= x >> 16;
    return x;
}

/// The policy's action into its row: `lat_scale * raw` into the wide row's action columns, so the
/// world model's next step reads the action the policy just chose. `raw` is the policy's output,
/// contiguous at `x_off` (`count` per row); the action columns start at `y_off`, rows `stride` apart.
/// One thread per (row, action). With `lat_sigma` > 0 the action carries exploration noise,
/// `lat_scale * (raw + lat_sigma * latNoise(lat_seed, row, action))` - the policy learns corrections
/// that still work when it cannot act exactly as it meant to.
pub fn lat_act(id: u32) void {
    if (id >= params.rows * params.count) {
        return;
    }
    const r: u32 = id / params.count;
    const j: u32 = id % params.count;
    const raw: f32 = b_acts[params.x_off + r * params.count + j];
    const noisy: f32 = raw + params.lat_sigma * latNoise(params.lat_seed, r, j);
    b_acts[params.y_off + r * params.stride + j] = params.lat_scale * noisy;
}

/// The action's gradient back to the policy's raw output: `d raw = lat_scale * d action +
/// lat_penalty * raw`. The first term undoes `lat_act`'s scale; the second is the action price's
/// gradient (mean raw^2, times its weight). The noise was ADDED, so it contributes nothing here.
/// `d action` is the world model's input gradient in its action columns (from `dx_off`, rows `stride`
/// apart - the input-gradient block's width, not the wide row's); `raw` the policy's output
/// (contiguous at `x_off`); `d raw` written contiguous at `dy_off`. One thread per (row, action).
pub fn lat_act_bwd(id: u32) void {
    if (id >= params.rows * params.count) {
        return;
    }
    const r: u32 = id / params.count;
    const j: u32 = id % params.count;
    const d_action: f32 = b_dacts[params.dx_off + r * params.stride + j];
    const raw: f32 = b_acts[params.x_off + r * params.count + j];
    // Smoothness: this step's action is pulled toward its neighbours in the window - the gradient of
    // w |a_k - a_(k-1)|^2 summed over the window, from the pair before and the pair after. A missing
    // neighbour's offset is this step's own, contributing exactly zero.
    const before: f32 = b_acts[params.lat_prev + r * params.count + j];
    const after: f32 = b_acts[params.lat_next + r * params.count + j];
    const smooth: f32 = params.lat_smooth * ((raw - before) + (raw - after));
    b_dacts[params.dy_off + r * params.count + j] = params.lat_scale * d_action + params.lat_penalty * raw + smooth;
}

// ── SUPERTRACK, FUSED: ONE THREAD PER BATCH ROW RUNS THE WHOLE WINDOW ──
//
// The cp_ kernels above are one dispatch per layer operation: ~27 a window step, ~1,050 a
// training iteration. These do the same arithmetic with ONE thread per batch row walking the
// whole unrolled window - forward, then backward with each row's OWN copy of the weight
// gradients, summed across rows by `st_reduce` - 4 dispatches a step (forward, backward, reduce,
// Adam). Scalars and global memory only (no pointers, no function-local arrays), for the SPIR-V
// compile. For hidden sizes like the cartpole's (32) a thread per row is right; a humanoid wants
// a workgroup per row.
//
// Shared layout. Networks (input 4, hidden h = `in_dim`): W0 [4, h], b0 [h], W1 [h, h], b1 [h],
// W2 [h, out], b2 [out], contiguous - the policy (out 1) at `w_off`, the world model (out 2) at
// `v_off`. A RECORD per (step step, row r) at x_off + (step rows + r)(12 + 4h):
//     S [4] | h1 [h] | h2 [h] | o | f | win [4] | g1 [h] | g2 [h] | acc [2]
// (the policy's layers h1, h2, o; the force f; the world model's input, layers and output); the
// record after the last step holds only the final state. `count` is the window length. Per-row
// weight gradients at dacts[dx_off + r n] (n the net's parameter count); per-row scratch (four
// vectors of h) at dacts[e_off + r 4h].

inline fn stRecord(h: u32) u32 {
    return 12 + 4 * h;
}

/// A dense tanh layer for one row, in -> h, reading its input from acts and writing its output
/// to acts: out[j] = tanh(b[j] + sum_i in[i] W[i, j]).
inline fn stLayerTanh(w: u32, in_at: u32, in_n: u32, h: u32, out_at: u32) void {
    var j: u32 = 0;
    while (j < h) : (j += 1) {
        var a: f32 = b_params[w + in_n * h + j];
        var i: u32 = 0;
        while (i < in_n) : (i += 1) {
            a += b_acts[in_at + i] * b_params[w + i * h + j];
        }
        b_acts[out_at + j] = tanh(a);
    }
}

/// One linear output of a layer, h -> out: b[c] + sum_i in[i] W[i, c].
inline fn stLinear(w: u32, in_at: u32, h: u32, out: u32, c: u32) f32 {
    var a: f32 = b_params[w + h * out + c];
    var i: u32 = 0;
    while (i < h) : (i += 1) {
        a += b_acts[in_at + i] * b_params[w + i * out + c];
    }
    return a;
}

/// The world model and the integration for one row from its record's `win`; returns nothing,
/// writes g1, g2, acc and the next state into the next record.
inline fn stWorldStep(base: u32, next: u32, h: u32, wm: u32) void {
    const wm1: u32 = wm + 5 * h;
    const wm2: u32 = wm1 + h * h + h;
    stLayerTanh(wm, base + 6 + 2 * h, 4, h, base + 10 + 2 * h);
    stLayerTanh(wm1, base + 10 + 2 * h, h, h, base + 10 + 3 * h);
    const a0: f32 = stLinear(wm2, base + 10 + 3 * h, h, 2, 0);
    const a1: f32 = stLinear(wm2, base + 10 + 3 * h, h, 2, 1);
    b_acts[base + 10 + 4 * h] = a0;
    b_acts[base + 11 + 4 * h] = a1;
    const cart_rate: f32 = b_acts[base + 1] + params.dt * params.acc_scale * a0;
    const pole_rate: f32 = b_acts[base + 3] + params.dt * params.acc_scale * a1;
    b_acts[next] = b_acts[base] + params.dt * cart_rate;
    b_acts[next + 1] = cart_rate;
    b_acts[next + 2] = b_acts[base + 2] + params.dt * pole_rate;
    b_acts[next + 3] = pole_rate;
}

/// The policy's window forward, one thread per row: starts at acts[z_off], noise per step at
/// acts[y_off + step rows + r].
pub fn st_policy_fwd(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const h: u32 = params.in_dim;
    const rec: u32 = stRecord(h);
    const pol1: u32 = params.w_off + 5 * h;
    const pol2: u32 = pol1 + h * h + h;
    const first: u32 = params.x_off + id * rec;
    var c: u32 = 0;
    while (c < 4) : (c += 1) {
        b_acts[first + c] = b_acts[params.z_off + id * 4 + c];
    }
    var step: u32 = 0;
    while (step < params.count) : (step += 1) {
        const base: u32 = params.x_off + (step * params.rows + id) * rec;
        const next: u32 = params.x_off + ((step + 1) * params.rows + id) * rec;
        stLayerTanh(params.w_off, base, 4, h, base + 4);
        stLayerTanh(pol1, base + 4, h, h, base + 4 + h);
        const o: f32 = stLinear(pol2, base + 4 + h, h, 1, 0);
        const f: f32 = tanh(o + params.sigma * b_acts[params.y_off + step * params.rows + id]);
        b_acts[base + 4 + 2 * h] = o;
        b_acts[base + 5 + 2 * h] = f;
        b_acts[base + 6 + 2 * h] = b_acts[base + 1];
        b_acts[base + 7 + 2 * h] = b_acts[base + 2];
        b_acts[base + 8 + 2 * h] = b_acts[base + 3];
        b_acts[base + 9 + 2 * h] = f;
        stWorldStep(base, next, h, params.v_off);
    }
}

/// The world model's window forward, one thread per row: the real start at acts[z_off], the real
/// forces per step at acts[y_off + step rows + r].
pub fn st_world_fwd(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const h: u32 = params.in_dim;
    const rec: u32 = stRecord(h);
    const first: u32 = params.x_off + id * rec;
    var c: u32 = 0;
    while (c < 4) : (c += 1) {
        b_acts[first + c] = b_acts[params.z_off + id * 4 + c];
    }
    var step: u32 = 0;
    while (step < params.count) : (step += 1) {
        const base: u32 = params.x_off + (step * params.rows + id) * rec;
        const next: u32 = params.x_off + ((step + 1) * params.rows + id) * rec;
        b_acts[base + 6 + 2 * h] = b_acts[base + 1];
        b_acts[base + 7 + 2 * h] = b_acts[base + 2];
        b_acts[base + 8 + 2 * h] = b_acts[base + 3];
        b_acts[base + 9 + 2 * h] = b_acts[params.y_off + step * params.rows + id];
        stWorldStep(base, next, h, params.w_off);
    }
}

/// The world model's backward for one row and step, from the gradient at its output (da0, da1):
/// its weight gradients ADDED into the row's slice at `grads_at` when that is not the sentinel
/// 0xffffffff; its scratch (dg1 at `scr`, dg2 at scr + h). Returns nothing; leaves the input's
/// gradient in scr + 2h .. + 4.
inline fn stWorldBack(
    base: u32,
    h: u32,
    wm: u32,
    da0: f32,
    da1: f32,
    grads_at: u32,
    scr: u32,
) void {
    const wm1: u32 = wm + 5 * h;
    const wm2: u32 = wm1 + h * h + h;
    const with_grads: bool = grads_at != 0xffffffff;
    var i: u32 = 0;
    while (i < h) : (i += 1) {
        const g2: f32 = b_acts[base + 10 + 3 * h + i];
        b_dacts[scr + h + i] = (da0 * b_params[wm2 + i * 2] + da1 * b_params[wm2 + i * 2 + 1]) * (1.0 - g2 * g2);
        if (with_grads) {
            b_dacts[grads_at + 6 * h + h * h + i * 2] += g2 * da0;
            b_dacts[grads_at + 6 * h + h * h + i * 2 + 1] += g2 * da1;
        }
    }
    if (with_grads) {
        b_dacts[grads_at + 8 * h + h * h] += da0;
        b_dacts[grads_at + 8 * h + h * h + 1] += da1;
    }
    i = 0;
    while (i < h) : (i += 1) {
        const g1: f32 = b_acts[base + 10 + 2 * h + i];
        var a: f32 = 0.0;
        var j: u32 = 0;
        while (j < h) : (j += 1) {
            const dg2: f32 = b_dacts[scr + h + j];
            a += dg2 * b_params[wm1 + i * h + j];
            if (with_grads) {
                b_dacts[grads_at + 5 * h + i * h + j] += g1 * dg2;
            }
        }
        b_dacts[scr + i] = a * (1.0 - g1 * g1);
    }
    if (with_grads) {
        var j: u32 = 0;
        while (j < h) : (j += 1) {
            b_dacts[grads_at + 5 * h + h * h + j] += b_dacts[scr + h + j];
        }
    }
    var in_i: u32 = 0;
    while (in_i < 4) : (in_i += 1) {
        const x: f32 = b_acts[base + 6 + 2 * h + in_i];
        var a: f32 = 0.0;
        var j: u32 = 0;
        while (j < h) : (j += 1) {
            const dg1: f32 = b_dacts[scr + j];
            a += dg1 * b_params[wm + in_i * h + j];
            if (with_grads) {
                b_dacts[grads_at + in_i * h + j] += x * dg1;
            }
        }
        b_dacts[scr + 2 * h + in_i] = a;
    }
    if (with_grads) {
        var j: u32 = 0;
        while (j < h) : (j += 1) {
            b_dacts[grads_at + 4 * h + j] += b_dacts[scr + j];
        }
    }
}

/// The tracking weight of state component c.
inline fn stWeight(c: u32) f32 {
    if (c == 0) {
        return params.w_cart;
    }
    if (c == 1) {
        return params.w_cart_rate;
    }
    if (c == 2) {
        return params.w_pole;
    }
    return params.w_pole_rate;
}

/// The policy's window backward, one thread per row, in reverse: the tracking gradient (target
/// upright, zeros), the step's adjoint, back through the world model to its input (no world-model
/// gradients), the force, the policy - its weight gradients into this row's slice.
pub fn st_policy_bwd(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const h: u32 = params.in_dim;
    const rec: u32 = stRecord(h);
    const n_pol: u32 = h * h + 7 * h + 1;
    const pol1: u32 = params.w_off + 5 * h;
    const pol2: u32 = pol1 + h * h + h;
    const g_at: u32 = params.dx_off + id * n_pol;
    const scr: u32 = params.e_off + id * 4 * h;
    const rows_f: f32 = float(params.rows);
    var z: u32 = 0;
    while (z < n_pol) : (z += 1) {
        b_dacts[g_at + z] = 0.0;
    }
    var d0: f32 = 0.0;
    var d1: f32 = 0.0;
    var d2: f32 = 0.0;
    var d3: f32 = 0.0;
    var step: u32 = params.count;
    while (step > 0) {
        step -= 1;
        const base: u32 = params.x_off + (step * params.rows + id) * rec;
        const next: u32 = params.x_off + ((step + 1) * params.rows + id) * rec;
        d0 += 2.0 * stWeight(0) * b_acts[next] / rows_f;
        d1 += 2.0 * stWeight(1) * b_acts[next + 1] / rows_f;
        d2 += 2.0 * stWeight(2) * b_acts[next + 2] / rows_f;
        d3 += 2.0 * stWeight(3) * b_acts[next + 3] / rows_f;
        const gv: f32 = d1 + params.dt * d0;
        const gw: f32 = d3 + params.dt * d2;
        var e0: f32 = d0;
        var e1: f32 = gv;
        var e2: f32 = d2;
        var e3: f32 = gw;
        const da0: f32 = gv * params.dt * params.acc_scale;
        const da1: f32 = gw * params.dt * params.acc_scale;
        stWorldBack(base, h, params.v_off, da0, da1, 0xffffffff, scr);
        e1 += b_dacts[scr + 2 * h];
        e2 += b_dacts[scr + 2 * h + 1];
        e3 += b_dacts[scr + 2 * h + 2];
        const df: f32 = b_dacts[scr + 2 * h + 3];
        const f: f32 = b_acts[base + 5 + 2 * h];
        const o: f32 = b_acts[base + 4 + 2 * h];
        const dout: f32 = df * (1.0 - f * f) + 2.0 * params.w_action * o / rows_f;
        // Policy layer 2 (linear, h -> 1), then layer 1, then layer 0 - dh2 at scr + h, dh1 at scr.
        var i: u32 = 0;
        while (i < h) : (i += 1) {
            const h2: f32 = b_acts[base + 4 + h + i];
            b_dacts[g_at + 6 * h + h * h + i] += h2 * dout;
            b_dacts[scr + h + i] = dout * b_params[pol2 + i] * (1.0 - h2 * h2);
        }
        b_dacts[g_at + 7 * h + h * h] += dout;
        i = 0;
        while (i < h) : (i += 1) {
            const h1: f32 = b_acts[base + 4 + i];
            var a: f32 = 0.0;
            var j: u32 = 0;
            while (j < h) : (j += 1) {
                const dh2: f32 = b_dacts[scr + h + j];
                a += dh2 * b_params[pol1 + i * h + j];
                b_dacts[g_at + 5 * h + i * h + j] += h1 * dh2;
            }
            b_dacts[scr + i] = a * (1.0 - h1 * h1);
        }
        var j: u32 = 0;
        while (j < h) : (j += 1) {
            b_dacts[g_at + 5 * h + h * h + j] += b_dacts[scr + h + j];
            b_dacts[g_at + 4 * h + j] += b_dacts[scr + j];
        }
        var in_i: u32 = 0;
        while (in_i < 4) : (in_i += 1) {
            const x: f32 = b_acts[base + in_i];
            var a: f32 = 0.0;
            j = 0;
            while (j < h) : (j += 1) {
                const dh1: f32 = b_dacts[scr + j];
                a += dh1 * b_params[params.w_off + in_i * h + j];
                b_dacts[g_at + in_i * h + j] += x * dh1;
            }
            if (in_i == 0) {
                e0 += a;
            } else if (in_i == 1) {
                e1 += a;
            } else if (in_i == 2) {
                e2 += a;
            } else {
                e3 += a;
            }
        }
        d0 = e0;
        d1 = e1;
        d2 = e2;
        d3 = e3;
    }
}

/// The world model's window backward, one thread per row, in reverse: the gradient against the
/// real next states (acts[t_off + (step rows + r) 4]), the step's adjoint, the world model's
/// backward WITH its weight gradients into this row's slice.
pub fn st_world_bwd(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const h: u32 = params.in_dim;
    const rec: u32 = stRecord(h);
    const n_wm: u32 = h * h + 8 * h + 2;
    const g_at: u32 = params.dx_off + id * n_wm;
    const scr: u32 = params.e_off + id * 4 * h;
    const rows_f: f32 = float(params.rows);
    var z: u32 = 0;
    while (z < n_wm) : (z += 1) {
        b_dacts[g_at + z] = 0.0;
    }
    var d0: f32 = 0.0;
    var d1: f32 = 0.0;
    var d2: f32 = 0.0;
    var d3: f32 = 0.0;
    var step: u32 = params.count;
    while (step > 0) {
        step -= 1;
        const base: u32 = params.x_off + (step * params.rows + id) * rec;
        const next: u32 = params.x_off + ((step + 1) * params.rows + id) * rec;
        const target: u32 = params.t_off + (step * params.rows + id) * 4;
        d0 += 2.0 * stWeight(0) * (b_acts[next] - b_acts[target]) / rows_f;
        d1 += 2.0 * stWeight(1) * (b_acts[next + 1] - b_acts[target + 1]) / rows_f;
        d2 += 2.0 * stWeight(2) * (b_acts[next + 2] - b_acts[target + 2]) / rows_f;
        d3 += 2.0 * stWeight(3) * (b_acts[next + 3] - b_acts[target + 3]) / rows_f;
        const gv: f32 = d1 + params.dt * d0;
        const gw: f32 = d3 + params.dt * d2;
        const da0: f32 = gv * params.dt * params.acc_scale;
        const da1: f32 = gw * params.dt * params.acc_scale;
        stWorldBack(base, h, params.w_off, da0, da1, g_at, scr);
        const e1: f32 = gv + b_dacts[scr + 2 * h];
        const e2: f32 = d2 + b_dacts[scr + 2 * h + 1];
        const e3: f32 = gw + b_dacts[scr + 2 * h + 2];
        d1 = e1;
        d2 = e2;
        d3 = e3;
    }
}

/// grads[w_off + j] = sum over rows of the per-row gradients (dacts[dx_off + r count + j]).
pub fn st_reduce(id: u32) void {
    if (id >= params.count) {
        return;
    }
    var a: f32 = 0.0;
    var r: u32 = 0;
    while (r < params.rows) : (r += 1) {
        a += b_dacts[params.dx_off + r * params.count + id];
    }
    b_grads[params.w_off + id] = a;
}

pub const kernels = [_][:0]const u8{
    "dense_fwd",
    "act_bwd",
    "dense_bwd_x",
    "dense_bwd_w",
    "mse_bwd",
    "mse_value",
    "adam",
    "ppo_mean_grad",
    "ppo_logstd_grad",
    "squash_fwd",
    "squash_logp",
    "sac_target",
    "min_route",
    "squash_bwd",
    "squash_logstd_grad",
    "alpha_grad",
    "polyak",
    "cp_wm_input",
    "cp_wm_input_bwd",
    "cp_force",
    "cp_force_bwd",
    "cp_step",
    "cp_step_bwd",
    "cp_track_bwd",
    "add_block",
    "lat_advance",
    "lat_take",
    "lat_gather",
    "lat_act",
    "lat_act_bwd",
    "st_policy_fwd",
    "st_policy_bwd",
    "st_world_fwd",
    "st_world_bwd",
    "st_reduce",
};

// ★★★ THE EXPORT HOOK. Without it the SPIR-V compile of this file exports NOTHING: a 68-byte
// module, an empty compute.wgsl for every entry, and `initGpu` failing on
// `UniformBindingNotFound` - while the CPU twin, which calls the functions directly, passes every
// test. zn_train has the same block; the kit was written without it.
comptime {
    for (kernels) |name| {
        k.installKernelLean(@This(), name);
    }
}
