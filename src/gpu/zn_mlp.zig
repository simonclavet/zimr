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
//! -- LAYOUT --
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
const cosRad = zm.cosRad;
const pi = zm.pi;
const sinRad = zm.sinRad;

/// Floats per buffer: 256k (1 MiB). A SAC critic for the humanoid - 97 inputs, two layers of
/// 256, batch 256 - needs ~150k floats of activations; its weights ~92k.
/// The buffers' lengths, from the sizes file beside this one: the pages' (`zn_mlp_sizes.zig`), or a program's own,
/// copied in under that name by its build (the trainer's).
const sizes = @import("zn_mlp_sizes.zig");

pub const config = k.Config{ .max = sizes.params_len, .workgroup = 64 };

/// What a layer's output goes through.
pub const Act = enum(u32) { linear = 0, tanh = 1, relu = 2 };

/// Whether a loss kernel counts every row, or only the rows a mask marks (`row_mask`): a replay window that has run
/// past its episode's end still rolls forward, but its rows count for nothing in the loss from then on.
/// How MPPI's elites are weighed (`mppi_elites`): exp(`mppi_temperature` x (score - best)) ABSOLUTE - TD-MPC2's
/// rule, for scores of a value's scale (tens), where a difference of 1 is small; or RELATIVE to the elites' own
/// spread, exp(`mppi_temperature` x (score - best) / (best - worst elite)) - so the worst elite weighs
/// exp(-`mppi_temperature`) of the best whatever the scores' units, and a cost of hundredths sharpens the search as
/// one of tens does.
pub const MppiTemperature = enum(u32) {
    absolute = 0,
    relative_to_elites = 1,
};

pub const RowMask = enum(u32) {
    /// Every row counts.
    every_row = 0,
    /// Row r counts by acts[`mask_off` + r]: 1 while its window is still counting, 0 once finished.
    counting_column = 1,
    /// Row r is weighted by acts[`mask_off` + r]: any number - the row's own share of a loss (the value tail's
    /// pessimism gives each head a weight per row).
    weight_column = 2,
};

/// How the two-hot kernels place a value on their bins' axis (`zimrnum.CategoricalScalar.Axis`): its symlog
/// (DreamerV3, TD-MPC2, BMPC), or the value itself.
pub const TwoHotAxis = enum(u32) { symlog = 0, identity = 1 };

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
    /// A layer norm's epsilon, added to the variance inside the root (`norm_fwd`): TD-MPC2's 1e-5.
    norm_epsilon: f32 = 1.0e-5,
    rate: f32 = 0,
    beta1: f32 = 0.9,
    beta2: f32 = 0.999,
    epsilon: f32 = 1.0e-8,
    /// Adam's bias corrections, 1 / (1 - beta^t), computed on the host: no pow in a kernel.
    correction1: f32 = 1,
    correction2: f32 = 1,
    /// PPO's clip range epsilon (`ppo_mean_grad`, `ppo_logstd_grad`, and FPO's `fpo_velocity_gradient`).
    clip: f32 = 0.2,
    /// SimNorm's group: a row's values are softmaxed in consecutive groups of this many (`simnorm_fwd`,
    /// `simnorm_bwd`). TD-MPC2's 8 by default - the kernels divide by it, so a dispatch that never set it must not
    /// find zero here.
    simnorm_group: u32 = 8,
    // -- SAC (the squash / target / temperature kernels below) --
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
    // -- SuperTrack on the cartpole (the cp_ kernels) --
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
    // -- The latent model's gather (`lat_gather`): sizes, and where each resident region starts
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
    /// change to this block - and THE ACTION FILTER's share of it in the action written (`lat_filter`; 1 is no
    /// filter). 16 bytes.
    lat_scale: f32 = 1.0,
    lat_sigma: f32 = 0.0,
    lat_seed: u32 = 0,
    lat_filter: f32 = 1.0,
    /// The action price's gradient coefficient for `lat_act_bwd` (2 w_action / (rows x actions)), and
    /// the SMOOTHNESS term's (CAPS: 2 w_smooth / (rows x actions)) with where the previous and next window
    /// steps' raw actions start. A step with no such neighbour points at ITSELF (its own `x_off`), so
    /// `raw - raw` is exactly zero: no sentinel to compare, no branch - nothing a shader translation can get
    /// subtly wrong. Once padding: the block is still 16 bytes.
    lat_penalty: f32 = 0.0,
    lat_smooth: f32 = 0.0,
    lat_prev: u32 = 0,
    lat_next: u32 = 0,
    /// The action filter's other two places (`lat_act`, `lat_act_bwd`): where the action the row held at the previous
    /// step starts, and its rows' stride - the previous step's action columns in its wide row, or the window's
    /// starting actions - and where the backward's CARRY lives, the action columns' whole gradient so far, one per
    /// (row, action).
    lat_prev_action: u32 = 0,
    lat_prev_action_stride: u32 = 0,
    lat_carry: u32 = 0,
    // -- The two-hot loss (the twohot_ kernels): the bins' range on their axis, the axis (`TwoHotAxis`), and what
    // each logit's gradient is divided by - the rows, for a mean over them. 16 bytes.
    twohot_low: f32 = -10.0,
    twohot_high: f32 = 10.0,
    twohot_axis: u32 = @backingInt(TwoHotAxis.symlog),
    twohot_divisor: f32 = 1.0,
    // -- A loss term's weight (`mse_bwd`, `twohot_bwd`): a learner whose loss is a weighted sum of terms -
    // EfficientTDMPC's consistency, rho^t / H per step and 20 overall, its reward and value terms 0.1 - scales each
    // term's gradient where it is made. 1 leaves the gradient as it always was, bit for bit. 16 bytes.
    loss_weight: f32 = 1.0,
    // -- the action filter for the limbs' stiffness (`latFilterShare`): an action's last `lat_stiffness_count` numbers
    // - each limb's stiffness, after the joints' offsets - take this share instead of `lat_filter`. 0 numbers (every
    // one an offset) and 1 (no filter) leave the action as it always was. In this row's padding, 16 bytes still.
    lat_stiffness_filter: f32 = 1.0,
    lat_stiffness_count: u32 = 0,
    /// Where the gradient a policy's reading of an action sends back to it is held (`lat_act_bwd`): the next
    /// decision's policy read this action as the one applied before it. 0: none - the region is never at the start of
    /// the gradients.
    lat_applied_gradient: u32 = 0,
    // -- The policy's distillation (`policy_distill_bwd`): the bounds its log spread is held between
    // (`zimrrl.TanhMeanGaussian`: BMPC's [-3, 1]) and the entropy bonus's coefficient (BMPC's 1e-4). 16 bytes.
    distill_log_std_low: f32 = -3.0,
    distill_log_std_high: f32 = 1.0,
    distill_entropy_coefficient: f32 = 1.0e-4,
    _p13: u32 = 0,
    // -- A value target's shape (`value_target_combine`): how many dynamics heads it looks ahead through, and how
    // many target value heads it averages at each - and a lambda-return's lambda and its values' head stride
    // (`value_lambda_combine`; 0: the rows). The discount is `gamma`. 16 bytes.
    target_dynamics_heads: u32 = 1,
    target_value_heads: u32 = 1,
    target_lambda: f32 = 0.95,
    target_head_stride: u32 = 0,
    // -- Which rows a loss counts (`RowMask`; `mse_bwd`, `twohot_fwd`, `twohot_bwd`): the mask's kind, where its
    // column is in acts, and - for `mse_bwd` - where the step's mean factor is (acts): batch / rows still counting, so
    // the whole batch's mean becomes the mean over the rows that count. 16 bytes.
    row_mask: u32 = @backingInt(RowMask.every_row),
    mask_off: u32 = 0,
    mean_factor_off: u32 = 0,
    _p16: u32 = 0,
    // -- A plan's shape (`broadcast_rows`, `plan_score_combine`): the candidates per state, the plan's length in
    // decisions, the dynamics heads every candidate is rolled under, and the value heads at each depth. 16 bytes.
    plan_candidates: u32 = 1,
    plan_horizon: u32 = 1,
    plan_dynamics_heads: u32 = 1,
    plan_value_heads: u32 = 1,
    // -- The plan's pessimism (`plan_score_combine`): beta, the score's price per standard deviation of the heads'
    // disagreement (EfficientTDMPC's eq. 10). 16 bytes.
    plan_pessimism: f32 = 0,
    // The policy's plans per state (`copy_row_blocks`): the first rows of each state's block of candidates.
    plan_policy_plans: u32 = 0,
    // The copies `broadcast_rows` makes of each source row: a state's candidates, or its policy plans.
    row_copies: u32 = 1,
    _p19: u32 = 0,
    // -- MPPI's refit (`mppi_elites`, `mppi_refit`): the elites each state keeps, the weights' temperature, and the
    // spread's floor and ceiling (BMPC: 64, 0.5, 0.05, 2). 16 bytes.
    mppi_elites: u32 = 1,
    mppi_temperature: f32 = 0.5,
    mppi_min_spread: f32 = 0.05,
    mppi_max_spread: f32 = 2.0,
    // -- SuperTrack's failure barrier (`lat_barrier_bwd`): the feature columns it reads - the head's height, the
    // first of the up direction's three - its weight, and the head height's margin, in metres. 16 bytes.
    barrier_head_column: u32 = 0,
    barrier_up_column: u32 = 0,
    barrier_weight: f32 = 0,
    barrier_head_margin: f32 = 0.25,
    // -- The head height's width, and the tilt's margin and width (in 1 - cos of the up directions' angle). 16 bytes.
    barrier_head_width: f32 = 0.05,
    barrier_tilt_margin: f32 = 1.0,
    barrier_tilt_width: f32 = 0.1,
    _p20: u32 = 0,
    // -- The flow policy (the `flow_` kernels): the time every row is at (`flow_time`) - or, with `flow_time_per_row`
    // 1, each row's own at acts `t_off` - the time's sine-cosine pairs, and the Euler step's size. 16 bytes.
    flow_time: f32 = 0,
    flow_time_per_row: u32 = 0,
    flow_frequencies: u32 = 3,
    flow_step: f32 = 0.25,
    // -- Where a copy or an Euler step writes (its destination rows' stride, and their first column: `copy_columns`,
    // `copy_columns_from_gradients`, `flow_euler_step`), FlowDPG's step share (alpha) and its anchor's weight
    // (lambda). 16 bytes.
    destination_stride: u32 = 0,
    destination_column: u32 = 0,
    flow_step_share: f32 = 0,
    flow_anchor: f32 = 1,
    // -- FlowDPG's step floor: the length its step is scaled by when the flow moves less (a flow at rest learns
    // too); how MPPI weighs its elites (`MppiTemperature`); how many steps its warm start shifts a plan by (the
    // steps since the last decision, `mppi_begin`); and the step a tracking planner's decision was made at
    // (`plan_mailbox`). 16 bytes.
    flow_step_floor: f32 = 0,
    mppi_temperature_mode: u32 = 0,
    mppi_warm_shift: u32 = 1,
    plan_decision_step: u32 = 0,
    // -- Teacher 3: advantage normalisation's epsilon, added to the deviation (`fpo_normalize_advantages`, as
    // `zimrrl.normalizeAdvantages`); the clipped Adam's ELEMENT-WISE bound on each gradient after the global factor,
    // 0 for none (`adam_clipped`); the rest padding. 16 bytes.
    advantage_epsilon: f32 = 1.0e-8,
    gradient_element_clip: f32 = 0,
    /// Where a statistic writes its numbers, in params (`stat_` kernels, `critic_value_stats`, `fpo_ratio_stats`): one
    /// place for all of them, so no statistic's output can collide with the inputs it reads.
    stat_off: u32 = 0,
    /// The per-step cost's cap far from the reference (`boundedCost`, `lat_tracking_cost`); 0 for none.
    cost_cap: f32 = 0,
    // -- A plan's knots (`planKnots`): its first `plan_fine_steps` steps each a knot, then a knot every
    // `plan_knot_span` steps to the horizon's last; 0 fine steps for every step a knot. 16 bytes.
    plan_fine_steps: u32 = 0,
    plan_knot_span: u32 = 1,
    _p21: u32 = 0,
    _p22: u32 = 0,
    // -- The world model's change in units of each feature's typical change (`lat_advance`): whether it is, and
    // where the statistics are in acts - `count` means, then `count` spreads. 16 bytes.
    lat_increments_on: u32 = 0,
    lat_increments_at: u32 = 0,
    /// Row stride of a dense layer's output (`dense_fwd`); 0 means rows of `out_dim`. A stride wider than the layer
    /// writes into rows laid out for someone else - a simulator's padded action rows - leaving the gaps untouched.
    y_stride: u32 = 0,
    _p24: u32 = 0,
};

/// The activation buffer is the one that grows: eight times the others. Everything the latent
/// world model's training keeps RESIDENT on the GPU lives in it - the rollout's blocks, and past them
/// the replay of features and the reference tables - because it cannot live in a buffer of its own:
/// WebGPU guarantees only 8 storage buffers to a shader stage, this kit already binds 7, and a binding
/// past the limit is not an error anywhere - its writes are silently dropped (compute_host.zig tells
/// that story). Every buffer is sized by its own field here, on the GPU and in the CPU twin alike;
/// the twin's arrays are static, so for the pages this is 8 MB of wasm memory on every page using the
/// kit (`zn_mlp_sizes.zig`; the trainer's sizes are its own).
pub const acts_len: u32 = sizes.acts_len;

/// The activation gradients' buffer, sized on its own: a learner's backward keeps a gradient for every activation of
/// every application it learns from - EfficientTDMPC's rollout over a whole batch of windows, every head at every step
/// - so it grows with the batch, where the parameters and their gradients and moments grow only with the networks
/// (`config.max` each). 4 MB for the pages (`zn_mlp_sizes.zig`).
pub const dacts_len: u32 = sizes.dacts_len;

pub const Buffers = extern struct {
    acts: [acts_len]f32,
    dacts: [dacts_len]f32,
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

pub inline fn activate(x: f32, act: u32) f32 {
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

inline fn outputStride() u32 {
    return if (params.y_stride != 0) params.y_stride else params.out_dim;
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
    b_acts[params.y_off + r * outputStride() + o] = activate(acc, params.act);
}

/// THE APPLIED ACTION's TERMS, ADDED TO A FIRST LAYER's SUM, THEN ITS ACTIVATION - one thread per (row, output). The
/// policy that sees the action applied before its decision reads it through a block of its own, its terms summed after
/// the goal's and the state's (the CPU learner's `policyWith` with `applied`): `y_off` holds the layer's linear sum
/// (bias, goal and state terms, from `dense_fwd`), and each applied number - `in_dim` of them, at `x_off`, rows
/// `stride` apart - adds itself times its weight, in order, before `act` is applied in place.
pub fn applied_add_activate(id: u32) void {
    if (id >= params.rows * params.out_dim) {
        return;
    }
    const r: u32 = id / params.out_dim;
    const o: u32 = id % params.out_dim;
    const y_at: u32 = params.y_off + r * params.out_dim + o;
    var sum: f32 = b_acts[y_at];
    var i: u32 = 0;
    while (i < params.in_dim) : (i += 1) {
        const applied_number: f32 = b_acts[params.x_off + r * inputStride() + i];
        const weight: f32 = b_params[params.w_off + i * params.out_dim + o];
        sum += applied_number * weight;
    }
    b_acts[y_at] = activate(sum, params.act);
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

/// The gradient of a mean squared error, one thread per value: for the loss mean over n values of (y - t)^2, each
/// value's gradient is 2 (y - t) / n - then times `loss_weight`, its term's weight in a weighted loss (1 for the error
/// alone). The predictions y from acts at `y_off`, the targets t from acts at `t_off`, `rows` x `out_dim` of each; the
/// gradients into dacts at `dy_off`.
///
/// With `row_mask` `.counting_column`, a row counts by its flag at acts `mask_off` + row and the error is the mean
/// over the rows that count: each gradient also times the row's flag (0 for a finished row: exactly no gradient) and
/// the mean factor at acts `mean_factor_off` - batch / rows still counting, 0 when none is (`zimrrl.LatentRollout`'s
/// masks, as `setFinished` makes them). With every flag 1 and the factor 1 the gradient is unchanged, bit for bit.
pub fn mse_bwd(id: u32) void {
    const value_count: u32 = params.rows * params.out_dim;
    if (id >= value_count) {
        return;
    }
    const prediction: f32 = b_acts[params.y_off + id];
    const target: f32 = b_acts[params.t_off + id];
    const difference: f32 = prediction - target;
    const unweighted_gradient: f32 = 2.0 * difference / float(value_count);
    const weighted_gradient: f32 = unweighted_gradient * params.loss_weight;
    if (params.row_mask == @backingInt(RowMask.counting_column)) {
        const row: u32 = id / params.out_dim;
        const counting: f32 = b_acts[params.mask_off + row];
        const mean_factor: f32 = b_acts[params.mean_factor_off];
        b_dacts[params.dy_off + id] = weighted_gradient * mean_factor * counting;
    } else {
        b_dacts[params.dy_off + id] = weighted_gradient;
    }
}

// -- ARITHMETIC SHARED BY KERNELS --
//
// One definition each, called by every kernel that needs it - so that the page's loss and the log's, or FPO's update
// and its statistics, cannot drift apart.

/// The mean squared difference of `count` activations at acts `first_at` and at acts `second_at`, summed in order; 0
/// for none.
fn meanSquaredDifference(first_at: u32, second_at: u32, count: u32) f32 {
    if (count == 0) {
        return 0;
    }
    var sum: f32 = 0;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const difference: f32 = b_acts[first_at + index] - b_acts[second_at + index];
        sum += difference * difference;
    }
    return sum / float(count);
}

/// The mean of `count` activations at acts `at`, summed in order; 0 for none.
fn meanOf(at: u32, count: u32) f32 {
    if (count == 0) {
        return 0;
    }
    var sum: f32 = 0;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        sum += b_acts[at + index];
    }
    return sum / float(count);
}

/// The sample deviation of `count` activations at acts `at` about their `mean` - the squared deviations' sum over
/// count - 1, as `zimrrl.normalizeAdvantages` takes it; 0 for fewer than two.
fn sampleDeviationOf(at: u32, count: u32, mean: f32) f32 {
    if (count < 2) {
        return 0;
    }
    var squares: f32 = 0;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const deviation: f32 = b_acts[at + index] - mean;
        squares += deviation * deviation;
    }
    return @sqrt(squares / float(count - 1));
}

/// Whether PPO's clip HOLDS an example: its clipped term, clamp(ratio, 1 - clip, 1 + clip) x advantage, is the smaller
/// of the two, so the example earns no gradient - the choice the minimum in `zimrrl.ppoClipSample` makes. An update
/// that would move the ratio past the clip in the improving direction is held; one moving the wrong way never is.
fn isClipHolding(ratio: f32, advantage: f32, clip: f32) bool {
    const unclipped: f32 = ratio * advantage;
    const clipped: f32 = clamp(ratio, 1 - clip, 1 + clip) * advantage;
    return !(unclipped <= clipped);
}

/// loss[0] = mean (y - t)^2, one thread: for the readback, not for training.
pub fn mse_value(id: u32) void {
    if (id != 0) {
        return;
    }
    b_loss[0] = meanSquaredDifference(params.y_off, params.t_off, params.rows * params.out_dim);
}

// -- THE GAUSSIAN PPO HEAD --
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

/// One parameter's Adam step from its (possibly clipped) gradient: the two running moments, their bias corrections
/// (the host's reciprocals of 1 - beta^t, in `correction1` and `correction2`), and the step. The one copy of Adam's
/// arithmetic on the kit: `adam` and `adam_clipped` both call it.
inline fn adamStep(parameter_index: u32, gradient: f32) void {
    const first_moment: f32 = params.beta1 * b_m[parameter_index] + (1.0 - params.beta1) * gradient;
    const second_moment: f32 = params.beta2 * b_v[parameter_index] + (1.0 - params.beta2) * gradient * gradient;
    b_m[parameter_index] = first_moment;
    b_v[parameter_index] = second_moment;
    const corrected_first: f32 = first_moment * params.correction1;
    const corrected_second: f32 = second_moment * params.correction2;
    b_params[parameter_index] -= params.rate * corrected_first / (sqrt(corrected_second) + params.epsilon);
}

/// Adam over `count` elements from `w_off`, with the host's bias corrections.
pub fn adam(id: u32) void {
    if (id >= params.count) {
        return;
    }
    const parameter_index: u32 = params.w_off + id;
    const gradient: f32 = b_grads[parameter_index];
    adamStep(parameter_index, gradient);
}

// -- ONE CLIP OF THE GLOBAL GRADIENT NORM, THEN ADAM --
//
// A learner that clips its gradient by its GLOBAL norm (BMPC: 20 over the whole world model) scales every gradient
// by the same factor, min(1, limit / norm), which keeps the update's direction and only shortens it - clipping
// tensor by tensor would turn it. On the kit it is three dispatches:
//
//     grad_square_partials   one thread per CHUNK of the gradients: its sum of squares    -> acts[y_off + chunk]
//     clip_factor            one thread: the norm from the partials, and the factor       -> acts[z_off], [z_off + 1]
//     adam_clipped           one thread per parameter: Adam on gradient x factor
//
// zimrnum's `clipGradNorm` sums every square in one compensated running total; the kit sums each chunk with
// compensation, then the chunks' totals with compensation - the same terms, in another grouping, so the norm agrees
// to rounding. When the norm is within the limit the factor is exactly 1, and the gradient is used unchanged.

/// The sum of squares of one chunk of the gradients, ONE THREAD PER CHUNK: `count` gradients from grads at `w_off`,
/// in chunks of `stride` - chunk `id` covers [id x stride, (id + 1) x stride), the last one what is left - each
/// chunk's compensated sum into acts at `y_off + id`.
pub fn grad_square_partials(id: u32) void {
    const chunk_length: u32 = params.stride;
    const chunk_start: u32 = id * chunk_length;
    if (chunk_start >= params.count) {
        return;
    }
    const chunk_end: u32 = @min(chunk_start + chunk_length, params.count);
    var squares: zm.CompensatedSum(f32) = .{};
    var index: u32 = chunk_start;
    while (index < chunk_end) : (index += 1) {
        const gradient: f32 = b_grads[params.w_off + index];
        squares.add(gradient * gradient);
    }
    b_acts[params.y_off + id] = squares.value();
}

/// The global norm and the clip factor, ONE THREAD: the square root of the `rows` partial sums at acts `x_off`
/// (`grad_square_partials`), summed with compensation, into acts `z_off`; the factor - `clip` / norm past the limit,
/// exactly 1 within it - into acts `z_off + 1`.
pub fn clip_factor(id: u32) void {
    if (id != 0) {
        return;
    }
    var squares: zm.CompensatedSum(f32) = .{};
    var chunk: u32 = 0;
    while (chunk < params.rows) : (chunk += 1) {
        squares.add(b_acts[params.x_off + chunk]);
    }
    const norm: f32 = sqrt(squares.value());
    const limit: f32 = params.clip;
    const factor: f32 = if (norm > limit) limit / norm else 1.0;
    b_acts[params.z_off] = norm;
    b_acts[params.z_off + 1] = factor;
}

/// A TEACHER'S SHARE, ONE THREAD: the length of its gradient - the square root of the `rows` partial sums at acts
/// `x_off` (`grad_square_partials`), summed with compensation - into acts `z_off`, and the factor that scales it to
/// length `loss_weight`, its share, into acts `z_off + 1`: share / length, or 0 for a gradient of no length (a teacher
/// that taught nothing adds nothing) - `kit_mlp.TeacherShares`.
pub fn share_factor(id: u32) void {
    if (id != 0) {
        return;
    }
    var squares: zm.CompensatedSum(f32) = .{};
    var chunk: u32 = 0;
    while (chunk < params.rows) : (chunk += 1) {
        squares.add(b_acts[params.x_off + chunk]);
    }
    const gradient_length: f32 = sqrt(squares.value());
    const factor: f32 = if (gradient_length > 0) params.loss_weight / gradient_length else 0.0;
    b_acts[params.z_off] = gradient_length;
    b_acts[params.z_off + 1] = factor;
}

/// A TEACHER'S GRADIENT, SCALED, INTO THE SUM - ONE THREAD PER PARAMETER: `count` gradients from grads `w_off` times
/// the factor at acts `x_off` (`share_factor`), into acts `y_off` - added to what is there (`col` 1), or written over
/// it for the first teacher (`col` 0).
pub fn add_scaled_gradients(id: u32) void {
    if (id >= params.count) {
        return;
    }
    const factor: f32 = b_acts[params.x_off];
    const scaled: f32 = factor * b_grads[params.w_off + id];
    const so_far: f32 = if (params.col == 0) 0.0 else b_acts[params.y_off + id];
    b_acts[params.y_off + id] = so_far + scaled;
}

/// THE SUMMED GRADIENTS BACK WHERE THE OPTIMISER READS THEM - ONE THREAD PER PARAMETER: `count` numbers from acts
/// `y_off` into grads `w_off`.
pub fn gradients_from_sum(id: u32) void {
    if (id >= params.count) {
        return;
    }
    b_grads[params.w_off + id] = b_acts[params.y_off + id];
}

/// Adam on clipped gradients, ONE THREAD PER PARAMETER: `count` parameters from `w_off`, each gradient times the clip
/// factor at acts `x_off` (`clip_factor`) - one multiplication, as zimrnum's clip scales each gradient in place before
/// its Adam reads it - then `adam`'s step.
pub fn adam_clipped(id: u32) void {
    if (id >= params.count) {
        return;
    }
    const parameter_index: u32 = params.w_off + id;
    const factor: f32 = b_acts[params.x_off];
    const scaled_gradient: f32 = b_grads[parameter_index] * factor;
    // Then each number on its own, when a bound is given: a gradient concentrated in a few weights - a spike the
    // global length barely notices - cannot throw those weights far.
    const element_bound: f32 = params.gradient_element_clip;
    const clipped_gradient: f32 = if (element_bound > 0)
        clamp(scaled_gradient, -element_bound, element_bound)
    else
        scaled_gradient;
    adamStep(parameter_index, clipped_gradient);
}

// -- THE NORMED LAYER (TD-MPC2's NormedDense: zimrnum's `NormedDense`) --
//
// EfficientTDMPC's networks are built of one layer: linear, then a LAYER NORM over the row's outputs together, then
// a gain and a bias per output, then Mish - or, at the end of the encoder, SimNorm. On the kit it is three steps,
// because each needs a different shape of thread:
//
//     dense_fwd (linear)   p = b + x W               one thread per output value, as every dense layer here
//     norm_fwd             n = (p - mean) * inv      one thread per ROW: a row's mean and spread need all of it
//                          s = n * gain + bias
//     mish_fwd             y = Mish(s)               one thread per value
//  or simnorm_fwd          y = softmax per group     one thread per GROUP of `simnorm_group` values
//
// The row statistics and the group softmax are zimrmath's own (`zm.layerNormRowStatistics`,
// `zm.softmaxGroupStatistics`) - the functions zimrnum's `layerNormRows` and `simNormRows` call, and through them
// the agent's graph and the policy player. Given the same pre-activations, the kit therefore writes the same bits
// they do (on a device that does not fuse a multiply into an add). `norm_fwd` also keeps what the backward needs:
// the normalised row n, and each row's inverse spread.

/// A run of the activation buffer read as a row (`zm.requireRowAccess`): the values from `start` on.
const ActsRow = struct {
    start: u32,

    pub fn at(row: ActsRow, index: usize) f32 {
        const offset: u32 = row.start + @as(u32, @intCast(index));
        return b_acts[offset];
    }
};

/// A normed layer's norm, ONE THREAD PER ROW: `rows` rows of `out_dim` pre-activations p at `x_off`, normalised by
/// the row's own statistics (`zm.layerNormRowStatistics`, epsilon `norm_epsilon`), each then times its gain plus its
/// norm bias - from params at `w_off`, the gains [out_dim] then the norm biases [out_dim]. Writes the normalised row
/// n to `z_off`, s = n * gain + norm bias to `y_off`, and the row's inverse spread to `l_off` (one value a row): n
/// and the inverse spread are what `norm_bwd` takes back through the norm.
pub fn norm_fwd(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const width: u32 = params.out_dim;
    const row_offset: u32 = id * width;
    const pre_activations: ActsRow = .{ .start = params.x_off + row_offset };
    const statistics: zm.LayerNormStatistics(f32) = zm.layerNormRowStatistics(
        f32,
        ActsRow,
        pre_activations,
        width,
        params.norm_epsilon,
    );
    var column: u32 = 0;
    while (column < width) : (column += 1) {
        const pre_activation: f32 = b_acts[params.x_off + row_offset + column];
        const normalised: f32 = zm.layerNormValue(f32, pre_activation, statistics);
        const gain: f32 = b_params[params.w_off + column];
        const norm_bias: f32 = b_params[params.w_off + width + column];
        const scaled: f32 = normalised * gain;
        b_acts[params.z_off + row_offset + column] = normalised;
        b_acts[params.y_off + row_offset + column] = scaled + norm_bias;
    }
    b_acts[params.l_off + id] = statistics.inverse_spread;
}

/// Mish on `rows` x `out_dim` values, ONE THREAD PER VALUE: y = Mish(s) from `x_off` into `y_off` (`zm.mish`). Its
/// input is kept: Mish's slope cannot be recovered from its output, as tanh's and relu's are (`act_bwd`), so the
/// backward reads s.
pub fn mish_fwd(id: u32) void {
    const value_count: u32 = params.rows * params.out_dim;
    if (id >= value_count) {
        return;
    }
    const value: f32 = b_acts[params.x_off + id];
    b_acts[params.y_off + id] = zm.mish(value);
}

/// SimNorm on `rows` x `out_dim` values, ONE THREAD PER GROUP: each row's values in consecutive groups of
/// `simnorm_group`, each group softmaxed (`zm.softmaxGroupStatistics`, `zm.softmaxGroupValue`) - from `x_off` into
/// `y_off`. `out_dim` is a whole number of groups (the host's layer is built so).
pub fn simnorm_fwd(id: u32) void {
    const group_size: u32 = params.simnorm_group;
    const groups_per_row: u32 = params.out_dim / group_size;
    const group_count: u32 = params.rows * groups_per_row;
    if (id >= group_count) {
        return;
    }
    const row: u32 = id / groups_per_row;
    const group_in_row: u32 = id % groups_per_row;
    const row_offset: u32 = row * params.out_dim;
    const group_start: u32 = group_in_row * group_size;
    const row_values: ActsRow = .{ .start = params.x_off + row_offset };
    const statistics: zm.SoftmaxGroupStatistics(f32) = zm.softmaxGroupStatistics(
        f32,
        ActsRow,
        row_values,
        group_start,
        group_size,
    );
    var member: u32 = 0;
    while (member < group_size) : (member += 1) {
        const column: u32 = group_start + member;
        const value: f32 = b_acts[params.x_off + row_offset + column];
        b_acts[params.y_off + row_offset + column] = zm.softmaxGroupValue(f32, value, statistics);
    }
}

// The backward runs the forward's steps in reverse, each the same shape of thread as its forward:
//
//     mish_bwd             ds = dy * Mish'(s)                        per value, from the stored s
//  or simnorm_bwd          ds = y * (dy - sum(dy * y))               per group, from the stored output y
//     norm_params_bwd      d gain = sum over rows of ds * n          per column: the gain's and the norm bias's
//                          d norm_bias = sum over rows of ds            gradients, into grads
//     norm_bwd             dp = inv * (dn - mean(dn) - n mean(dn n)) per row, dn = ds * gain
//     dense_bwd_x / _w     the linear part's, as every dense layer's
//
// `norm_params_bwd` reads ds, which `norm_bwd` may overwrite (when its output is its input's region), so it runs
// first. The row couplings and the group's weighted sum are zimrmath's (`zm.layerNormGradientCouplings`,
// `zm.softmaxGroupGradientDot`), the functions zimrnum's backward calls.

/// A run of the gradient buffer read as a row (`zm.requireRowAccess`): the values from `start` on.
const DactsRow = struct {
    start: u32,

    pub fn at(row: DactsRow, index: usize) f32 {
        const offset: u32 = row.start + @as(u32, @intCast(index));
        return b_dacts[offset];
    }
};

/// The gradient arriving at a row's NORMALISED values, read as a row: the gradient at s = n * gain + norm_bias,
/// times its gain - what the multiplication's backward passes on. Computed where it is read, so no buffer holds it.
const GainScaledGradientRow = struct {
    gradient_start: u32,
    gain_start: u32,

    pub fn at(row: GainScaledGradientRow, index: usize) f32 {
        const column: u32 = @intCast(index);
        const arriving: f32 = b_dacts[row.gradient_start + column];
        const gain: f32 = b_params[row.gain_start + column];
        return arriving * gain;
    }
};

/// Mish's backward, ONE THREAD PER VALUE: ds = dy * Mish'(s) (`zm.mishSlope`), s from acts at `x_off` (`mish_fwd`'s
/// input), dy from dacts at `dy_off`, ds into dacts at `dx_off` (which may be `dy_off`: each value reads its own).
pub fn mish_bwd(id: u32) void {
    const value_count: u32 = params.rows * params.out_dim;
    if (id >= value_count) {
        return;
    }
    const input: f32 = b_acts[params.x_off + id];
    const arriving: f32 = b_dacts[params.dy_off + id];
    b_dacts[params.dx_off + id] = arriving * zm.mishSlope(input);
}

/// SimNorm's backward, ONE THREAD PER GROUP: each input's gradient its probability times how far its arriving
/// gradient is from the group's probability-weighted sum (`zm.softmaxGroupGradientDot`,
/// `zm.softmaxGroupInputGradient`). The probabilities are the forward's output, from acts at `y_off`; dy from dacts
/// at `dy_off`; the input gradients into dacts at `dx_off` (which may be `dy_off`: a group reads all of its values
/// before it writes any).
pub fn simnorm_bwd(id: u32) void {
    const group_size: u32 = params.simnorm_group;
    const groups_per_row: u32 = params.out_dim / group_size;
    const group_count: u32 = params.rows * groups_per_row;
    if (id >= group_count) {
        return;
    }
    const row: u32 = id / groups_per_row;
    const group_in_row: u32 = id % groups_per_row;
    const row_offset: u32 = row * params.out_dim;
    const group_start: u32 = group_in_row * group_size;
    const gradients: DactsRow = .{ .start = params.dy_off + row_offset };
    const probabilities: ActsRow = .{ .start = params.y_off + row_offset };
    const weighted_sum: f32 = zm.softmaxGroupGradientDot(
        f32,
        DactsRow,
        ActsRow,
        gradients,
        probabilities,
        group_start,
        group_size,
    );
    var member: u32 = 0;
    while (member < group_size) : (member += 1) {
        const column: u32 = group_start + member;
        const probability: f32 = b_acts[params.y_off + row_offset + column];
        const arriving: f32 = b_dacts[params.dy_off + row_offset + column];
        const input_gradient: f32 = zm.softmaxGroupInputGradient(f32, arriving, probability, weighted_sum);
        b_dacts[params.dx_off + row_offset + column] = input_gradient;
    }
}

/// A normed layer's gain and norm bias gradients, ONE THREAD PER PARAMETER: thread c < `out_dim` sums ds * n down
/// column c (the gain's gradient), thread `out_dim` + c sums ds down it (the norm bias's) - compensated, as zimrnum's
/// reductions are. ds from dacts at `dy_off`, n from acts at `z_off` (`norm_fwd`'s normalised rows), into grads at
/// `w_off` (the gains, then the norm biases - the layer's params order). With `accumulate` set they ADD to what is
/// there, as `dense_bwd_w` does: a layer used at several steps of an unrolled window sums its gradients.
pub fn norm_params_bwd(id: u32) void {
    const width: u32 = params.out_dim;
    if (id >= 2 * width) {
        return;
    }
    const is_gain: bool = id < width;
    const column: u32 = if (is_gain) id else id - width;
    var total: zm.CompensatedSum(f32) = .{};
    var row: u32 = 0;
    while (row < params.rows) : (row += 1) {
        const value_index: u32 = row * width + column;
        const arriving: f32 = b_dacts[params.dy_off + value_index];
        const normalised: f32 = b_acts[params.z_off + value_index];
        const contribution: f32 = if (is_gain) arriving * normalised else arriving;
        total.add(contribution);
    }
    const gradient: f32 = total.value();
    if (params.accumulate != 0) {
        b_grads[params.w_off + id] += gradient;
    } else {
        b_grads[params.w_off + id] = gradient;
    }
}

/// A normed layer's norm, backward, ONE THREAD PER ROW: the gradient at the pre-activations p from the gradient ds
/// at s (dacts at `dy_off`), through the gain (params at `w_off`) and the norm - the row's couplings
/// (`zm.layerNormGradientCouplings`) over dn = ds * gain and the forward's normalised row n (acts at `z_off`), each
/// input's gradient by `zm.layerNormInputGradient` with the row's inverse spread (acts at `l_off`). Into dacts at
/// `dx_off`; it may be `dy_off` - a row reads all its ds before it writes - but then `norm_params_bwd` must have run.
pub fn norm_bwd(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const width: u32 = params.out_dim;
    const row_offset: u32 = id * width;
    const scaled_gradients: GainScaledGradientRow = .{
        .gradient_start = params.dy_off + row_offset,
        .gain_start = params.w_off,
    };
    const normalised_row: ActsRow = .{ .start = params.z_off + row_offset };
    const couplings: zm.LayerNormGradientCouplings(f32) = zm.layerNormGradientCouplings(
        f32,
        GainScaledGradientRow,
        ActsRow,
        scaled_gradients,
        normalised_row,
        width,
    );
    const inverse_spread: f32 = b_acts[params.l_off + id];
    var column: u32 = 0;
    while (column < width) : (column += 1) {
        const scaled_gradient: f32 = scaled_gradients.at(column);
        const normalised: f32 = normalised_row.at(column);
        const input_gradient: f32 = zm.layerNormInputGradient(
            f32,
            scaled_gradient,
            normalised,
            couplings,
            inverse_spread,
        );
        b_dacts[params.dx_off + row_offset + column] = input_gradient;
    }
}

// -- THE TWO-HOT LOSS (regression as classification: a head predicts a value as a distribution over bins) --
//
// A reward or value head outputs `out_dim` logits per row - one per bin, the bins spread evenly from `twohot_low` to
// `twohot_high` on the axis (`TwoHotAxis`, by default the symlog of the value). Its prediction is the softmax's mean
// position, taken back from the axis; it is trained toward a TWO-HOT target, the true value placed on the axis and
// shared between the two bins around it, by the soft-label cross-entropy:
//
//     loss(row)        = - sum over j of target_j * (logit_j - logsumexp(logits))
//     d loss / d logit = (sum of target * softmax_j - target_j) / divisor
//
// Every piece is zimrmath's, the functions zimrnum's `CategoricalScalar` and `softCrossEntropyRows` use: the place on
// the axis (`zm.symlog`), the place among the bins (`zm.gridPosition`), the two shares (`zm.gridShares`), the
// softmax's statistics and log-denominator (`zm.softmaxGroupStatistics`, `zm.softmaxLogDenominator`). The target is
// never written out: its two nonzero bins are found where they are needed. One thread per row in all three kernels -
// a row's softmax needs all of its logits.

/// A value on the two-hot bins' axis (`TwoHotAxis`).
fn twoHotAxisPosition(value: f32) f32 {
    if (params.twohot_axis == @backingInt(TwoHotAxis.identity)) {
        return value;
    }
    return zm.symlog(f32, value);
}

/// A position on the two-hot bins' axis, taken back to a value.
fn twoHotValueOf(axis_position: f32) f32 {
    if (params.twohot_axis == @backingInt(TwoHotAxis.identity)) {
        return axis_position;
    }
    return zm.symexp(f32, axis_position);
}

/// A row's weight (`RowMask`): 1 when every row counts, else the row's number at acts `mask_off` + row - a counting
/// flag or a weight, the kernels multiply by it alike. The two-hot kernels multiply a row's two shares by a counting
/// flag, as the host multiplies its two-hot target row by the window's flag - a finished row's target is all zeros,
/// and costs exactly nothing, in value and in gradient; the policy's distillation multiplies a row's weight by it, as
/// the host builds its weights from the same flags; the decoded value's slope multiplies by a weight.
fn rowWeight(row: u32) f32 {
    if (params.row_mask == @backingInt(RowMask.every_row)) {
        return 1.0;
    }
    return b_acts[params.mask_off + row];
}

/// Where a row's target lands among the bins (`zm.gridShares`): its two bins, and each one's share of the target. A
/// target that is not a number - a value target from a diverged model - must not become a bin index outside the
/// row, so it is placed at 0, and the kernels make that row's results NaN themselves: the learner's check for
/// non-finite losses still sees it. On the CPU the clamp inside `zm.gridPosition` would already keep a NaN on a
/// bound (`@min` and `@max` return their other operand); on a device the minimum and maximum of a NaN are undefined
/// (GLSL's FMin and FMax), and an index from one could fall anywhere - the explicit placement is for the device.
fn twoHotShares(target: f32) zm.GridShares(f32) {
    const placed_target: f32 = if (zm.isNan(target)) 0.0 else target;
    const axis_position: f32 = twoHotAxisPosition(placed_target);
    const bin_count: u32 = params.out_dim;
    const grid_position: f32 = zm.gridPosition(f32, axis_position, params.twohot_low, params.twohot_high, bin_count);
    return zm.gridShares(f32, grid_position, bin_count, 1.0);
}

/// The two-hot target's value at the row's two nonzero bins, as zimrnum's dense target holds them: the lower bin its
/// share, the upper its own - or, at the top bin, which is its own next, the one bin both shares.
fn twoHotTargetAt(shares: zm.GridShares(f32), bin: u32) f32 {
    const lower_bin: u32 = @intCast(shares.lower_index);
    const upper_bin: u32 = @intCast(shares.upper_index);
    var target_value: f32 = 0.0;
    if (bin == lower_bin) {
        target_value += shares.lower_share;
    }
    if (bin == upper_bin) {
        target_value += shares.upper_share;
    }
    return target_value;
}

/// The two-hot cross-entropy of each row, ONE THREAD PER ROW: `out_dim` logits from acts at `x_off`, the row's target
/// value from acts at `t_off` (one a row), the row's loss into acts at `y_off` (one a row). The loss is zimrnum's
/// `softCrossEntropyRows` of the row against its two-hot target, term for term: only the two nonzero bins contribute,
/// in bin order, exactly as the dense sum's other terms add nothing.
pub fn twohot_fwd(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const bin_count: u32 = params.out_dim;
    const logits_start: u32 = params.x_off + id * bin_count;
    const logits: ActsRow = .{ .start = logits_start };
    const statistics: zm.SoftmaxGroupStatistics(f32) = zm.softmaxGroupStatistics(f32, ActsRow, logits, 0, bin_count);
    const log_denominator: f32 = zm.softmaxLogDenominator(f32, statistics);
    var shares: zm.GridShares(f32) = twoHotShares(b_acts[params.t_off + id]);
    const counting: f32 = rowWeight(id);
    shares.lower_share *= counting;
    shares.upper_share *= counting;
    const lower_bin: u32 = @intCast(shares.lower_index);
    const upper_bin: u32 = @intCast(shares.upper_index);
    var row_loss: f32 = 0.0;
    const lower_log_probability: f32 = b_acts[logits_start + lower_bin] - log_denominator;
    row_loss -= twoHotTargetAt(shares, lower_bin) * lower_log_probability;
    if (upper_bin != lower_bin) {
        const upper_log_probability: f32 = b_acts[logits_start + upper_bin] - log_denominator;
        row_loss -= twoHotTargetAt(shares, upper_bin) * upper_log_probability;
    }
    // A target that is not a number gives a loss that is not one (`twoHotShares`).
    const target: f32 = b_acts[params.t_off + id];
    b_acts[params.y_off + id] = if (zm.isNan(target)) target else row_loss;
}

/// The two-hot cross-entropy's gradient at the logits, ONE THREAD PER ROW: (target mass x softmax_j - target_j) /
/// `twohot_divisor` x `loss_weight` for each of the row's `out_dim` logits (acts at `x_off`), the targets from acts
/// at `t_off`, into dacts at `dy_off`. The target mass is the two shares' sum, as zimrnum's sum of the dense target
/// row comes out. The divisor makes the mean over rows (zimrnum's `softCrossEntropyRowsGrad` divides by the row
/// count); the weight is the term's share of a weighted loss (1 for the term alone, as `mse_bwd` takes it).
pub fn twohot_bwd(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const bin_count: u32 = params.out_dim;
    const logits_start: u32 = params.x_off + id * bin_count;
    const logits: ActsRow = .{ .start = logits_start };
    const statistics: zm.SoftmaxGroupStatistics(f32) = zm.softmaxGroupStatistics(f32, ActsRow, logits, 0, bin_count);
    var shares: zm.GridShares(f32) = twoHotShares(b_acts[params.t_off + id]);
    const counting: f32 = rowWeight(id);
    shares.lower_share *= counting;
    shares.upper_share *= counting;
    const lower_bin: u32 = @intCast(shares.lower_index);
    const upper_bin: u32 = @intCast(shares.upper_index);
    var target_mass: f32 = twoHotTargetAt(shares, lower_bin);
    if (upper_bin != lower_bin) {
        target_mass += twoHotTargetAt(shares, upper_bin);
    }
    // A target that is not a number gives gradients that are not either (`twoHotShares`).
    const target: f32 = b_acts[params.t_off + id];
    const is_target_nan: bool = zm.isNan(target);
    var bin: u32 = 0;
    while (bin < bin_count) : (bin += 1) {
        const probability: f32 = zm.softmaxGroupValue(f32, b_acts[logits_start + bin], statistics);
        const target_value: f32 = twoHotTargetAt(shares, bin);
        const unscaled: f32 = target_mass * probability - target_value;
        const mean_gradient: f32 = unscaled / params.twohot_divisor;
        const gradient: f32 = mean_gradient * params.loss_weight;
        b_dacts[params.dy_off + id * bin_count + bin] = if (is_target_nan) target else gradient;
    }
}

/// A two-hot head's prediction, ONE THREAD PER ROW: the softmax's probability-weighted mean bin position
/// (`zm.binPosition`), taken back from the axis - zimrnum's `CategoricalScalar.decode`, term for term. Logits from acts
/// at `x_off`, the value into acts at `y_off` (one a row).
pub fn twohot_decode(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const bin_count: u32 = params.out_dim;
    const logits_start: u32 = params.x_off + id * bin_count;
    const logits: ActsRow = .{ .start = logits_start };
    const statistics: zm.SoftmaxGroupStatistics(f32) = zm.softmaxGroupStatistics(f32, ActsRow, logits, 0, bin_count);
    var mean_axis_position: f32 = 0.0;
    var bin: u32 = 0;
    while (bin < bin_count) : (bin += 1) {
        const probability: f32 = zm.softmaxGroupValue(f32, b_acts[logits_start + bin], statistics);
        const position: f32 = zm.binPosition(f32, params.twohot_low, params.twohot_high, bin_count, bin);
        mean_axis_position += probability * position;
    }
    b_acts[params.y_off + id] = twoHotValueOf(mean_axis_position);
}

/// The SLOPE of a two-hot head's decoded value in its logits, ONE THREAD PER ROW - `twohot_decode` run backward, for
/// a loss that uses the decoded value itself (SuperTrack's value tail). With p the softmax of the row's logits, x_j the
/// bins' positions and m = sum p_j x_j the decoded axis position, the value is v = symexp(m) (or m itself on the
/// identity axis), and
///
///     d m / d logit_j = p_j (x_j - m)          (the softmax's own derivative, summed against the positions)
///     d v / d logit_j = v'(m) x p_j (x_j - m)  v'(m) = `zm.symexpSlope`(m) = e^|m|, or 1 on the identity axis
///
/// A logit pulls the decoded value toward its own bin's position, in proportion to its probability. Worked, with two
/// bins at positions 0 and 1 holding probabilities 0.25 and 0.75: m = 0.75, and the slopes of m in the two logits are
/// 0.25 x (0 - 0.75) = -0.1875 and 0.75 x (1 - 0.75) = 0.1875 - equal and opposite, since raising every logit by the
/// same amount leaves the softmax, and so the value, where it was. On the symlog axis the value is symexp(0.75), and
/// both slopes are multiplied by e^0.75, about 2.117. The slope times
/// `loss_weight` - the value's weight in the loss - and the row's own weight (`rowWeight`) is written fresh into dacts
/// at `dy_off` [rows][bins]; the logits are read from acts at `x_off`, `out_dim` per row, the bins and axis from the
/// `twohot_` fields.
pub fn twohot_value_bwd(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const bin_count: u32 = params.out_dim;
    const logits_start: u32 = params.x_off + id * bin_count;
    const logits: ActsRow = .{ .start = logits_start };
    const statistics: zm.SoftmaxGroupStatistics(f32) = zm.softmaxGroupStatistics(f32, ActsRow, logits, 0, bin_count);
    // The decoded axis position m, as `twohot_decode` computes it.
    var mean_axis_position: f32 = 0.0;
    var bin: u32 = 0;
    while (bin < bin_count) : (bin += 1) {
        const probability: f32 = zm.softmaxGroupValue(f32, b_acts[logits_start + bin], statistics);
        const position: f32 = zm.binPosition(f32, params.twohot_low, params.twohot_high, bin_count, bin);
        mean_axis_position += probability * position;
    }
    const on_identity_axis: bool = params.twohot_axis == @backingInt(TwoHotAxis.identity);
    const value_slope: f32 = if (on_identity_axis) 1.0 else zm.symexpSlope(f32, mean_axis_position);
    const weighted_slope: f32 = params.loss_weight * rowWeight(id) * value_slope;
    bin = 0;
    while (bin < bin_count) : (bin += 1) {
        const probability: f32 = zm.softmaxGroupValue(f32, b_acts[logits_start + bin], statistics);
        const position: f32 = zm.binPosition(f32, params.twohot_low, params.twohot_high, bin_count, bin);
        const position_offset: f32 = position - mean_axis_position;
        b_dacts[params.dy_off + id * bin_count + bin] = weighted_slope * probability * position_offset;
    }
}

/// Each head's weight per row in a PESSIMISTIC ensemble cost, ONE THREAD PER ROW: the cost an ensemble of H heads
/// reports is their mean plus `plan_pessimism` (beta) of their spread -
///
///     P = m + beta s,      m = (1/H) sum_h C_h,      s = sqrt( (1/H) sum_h (C_h - m)^2 )
///
/// so that where the heads dispute a state's cost, the state is taken to cost more: a policy pushed by P avoids what
/// the critic is unsure of. The weight of head h is P's slope in C_h -
///
///     d P / d C_h = 1/H + beta (C_h - m) / (H s)  =  (1/H) (1 + beta (C_h - m) / s)
///
/// - each head pulls with the mean's equal share, and a head above the mean pulls harder, one below it less. With the
/// heads in agreement (s near 0) every weight is 1/H.
///
/// Worked: two heads with costs 3 and 5 at a row, beta 0.7. Then m = 4 and s = 1, so P = 4.7, and the weights are
/// (1/2)(1 - 0.7) = 0.15 for the head at 3 and (1/2)(1 + 0.7) = 0.85 for the head at 5: moving the more pessimistic
/// head's cost by 1 moves P by 0.85. The weights still add up to 1 - the slope of P along "both heads up by 1" is 1,
/// as for any mean - pessimism only redistributes the pull toward the head that says the state is worse.
///   reads  acts `v_off` each head's decoded cost [head][row], `target_value_heads` heads
///   writes acts `y_off` each head's weight [head][row]
pub fn ensemble_tail_weights(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const row_count: u32 = params.rows;
    const head_count: u32 = params.target_value_heads;
    const head_count_value: f32 = float(head_count);
    var cost_sum: f32 = 0;
    var head: u32 = 0;
    while (head < head_count) : (head += 1) {
        cost_sum += b_acts[params.v_off + head * row_count + id];
    }
    const mean_cost: f32 = cost_sum / head_count_value;
    var squared_deviation_sum: f32 = 0;
    head = 0;
    while (head < head_count) : (head += 1) {
        const deviation: f32 = b_acts[params.v_off + head * row_count + id] - mean_cost;
        squared_deviation_sum += deviation * deviation;
    }
    const cost_spread: f32 = sqrt(squared_deviation_sum / head_count_value);
    const heads_agree: bool = cost_spread < 1.0e-6;
    head = 0;
    while (head < head_count) : (head += 1) {
        const deviation: f32 = b_acts[params.v_off + head * row_count + id] - mean_cost;
        const pessimism_share: f32 = if (heads_agree) 0.0 else params.plan_pessimism * deviation / cost_spread;
        b_acts[params.y_off + head * row_count + id] = (1.0 + pessimism_share) / head_count_value;
    }
}

// -- THE POLICY'S DISTILLATION (BMPC: the planner distilled into the policy) --
//
// BMPC's policy is a Gaussian over actions whose CENTRE is squashed into the action range by tanh and whose SPREAD is
// held between two bounds (`zimrrl.TanhMeanGaussian`). The policy network outputs two numbers per action dimension -
// raw centres m, then raw spreads x - and the head bends them into place:
//
//     mean    = tanh(m)
//     log_std = tanh(x) x half_width + (low + half_width)          half_width = (high - low) / 2
//
// It is trained to say in one pass what the planner worked out slowly: at every stored step, toward the Gaussian the
// planner settled on there (its mean, and the log of its spread), by the divergence KL(policy || planner) -
// mode-seeking, so the policy settles where the planner was confident - averaged over the action's dimensions and
// divided by a running scale, less a faint entropy bonus (`zimrrl.PolicyDistillationLoss`):
//
//     loss = sum over rows r of  w_r x [ KL_r / dims / scale  -  c x dims x entropy_r ]
//
//     KL_r      = sum over d of  log s_q - log s_p  +  (s_p^2 + (m_p - m_q)^2) / (2 s_q^2)  -  1/2
//     entropy_r = sum over d of  log s_p + (log(2 pi) + 1) / 2
//
// with w_r the row's weight - rho^t / (H x rows per step) for a row of step t, 0 for a finished one. Its gradient,
// per dimension, in closed form:
//
//     d loss / d mean     = w_r / scale x (m_p - m_q) / s_q^2 / dims
//     d loss / d log_std  = w_r x [ (s_p^2 / s_q^2 - 1) / dims / scale  -  c x dims ]
//
// then through the head's two tanh to the raw outputs: x (1 - mean^2) for the centre, x half_width x (1 - tanh(x)^2)
// for the spread. One thread per row writes the row's gradients, its divergence KL_r / dims (which the running
// scale reads) and its entropy.

/// The policy head's two outputs at one action dimension (`zimrrl.TanhMeanGaussian`): its mean - the raw centre
/// squashed into the action range - and its log spread, the raw spread held between `distill_log_std_low` and
/// `_high`; with the squashed spread itself, which the spread's gradient needs.
const PolicyHeadOutputs = struct {
    mean: f32,
    log_std: f32,
    squashed_spread: f32,
};

/// The policy head (this section's head) at one action dimension: `PolicyHeadOutputs` from the network's raw centre
/// and raw spread, in the order the host's head computes them.
inline fn policyHead(raw_centre: f32, raw_spread: f32) PolicyHeadOutputs {
    const half_width: f32 = 0.5 * (params.distill_log_std_high - params.distill_log_std_low);
    const midpoint: f32 = params.distill_log_std_low + half_width;
    const squashed_spread: f32 = tanh(raw_spread);
    const outputs: PolicyHeadOutputs = .{
        .mean = tanh(raw_centre),
        .log_std = squashed_spread * half_width + midpoint,
        .squashed_spread = squashed_spread,
    };
    return outputs;
}

/// What a distillation row computes (`distillRow`): its divergence and entropy alone, or its gradients as well.
const DistillOutputs = enum { divergence_only, divergence_and_gradients };

/// One row of the distillation (this section's head), for both kernels: the head's mean and log spread, the
/// divergence's and entropy's terms, and - when `outputs` asks - the gradients at the raw outputs.
inline fn distillRow(id: u32, comptime outputs: DistillOutputs) void {
    const dimension_count: u32 = params.out_dim;
    const dimensions: f32 = float(dimension_count);
    const raw_row: u32 = params.x_off + id * 2 * dimension_count;
    const target_row: u32 = id * dimension_count;
    const half_width: f32 = 0.5 * (params.distill_log_std_high - params.distill_log_std_low);
    // ln(2 pi) / 2: the entropy's constant part, per dimension, with the + 1/2 beside it.
    const half_log_tau: f32 = 0.918938533204672741780329736406;
    var divergence_sum: f32 = 0;
    var log_std_sum: f32 = 0;
    var dimension: u32 = 0;
    while (dimension < dimension_count) : (dimension += 1) {
        // The head: the centre squashed into the action range, the log spread held inside its bounds.
        const raw_centre: f32 = b_acts[raw_row + dimension];
        const raw_spread: f32 = b_acts[raw_row + dimension_count + dimension];
        const head: PolicyHeadOutputs = policyHead(raw_centre, raw_spread);
        const mean: f32 = head.mean;
        const squashed_spread: f32 = head.squashed_spread;
        const log_std: f32 = head.log_std;
        // The planner's Gaussian at this row.
        const target_mean: f32 = b_acts[params.t_off + target_row + dimension];
        const target_log_std: f32 = b_acts[params.u_off + target_row + dimension];
        // The divergence's terms.
        const mean_gap: f32 = mean - target_mean;
        const policy_variance: f32 = @exp(2.0 * log_std);
        const inverse_target_variance: f32 = @exp(-2.0 * target_log_std);
        const spread_and_gap: f32 = policy_variance + mean_gap * mean_gap;
        divergence_sum += (target_log_std - log_std) + spread_and_gap * 0.5 * inverse_target_variance;
        log_std_sum += log_std;
        if (comptime outputs == .divergence_and_gradients) {
            // The gradients at the head's outputs, then through its two tanh.
            // The row's weight, 0 for a finished row (`rowWeight`).
            const row_weight: f32 = b_acts[params.v_off + id] * rowWeight(id);
            const inverse_scale: f32 = b_acts[params.e_off];
            const entropy_push: f32 = params.distill_entropy_coefficient * dimensions;
            const divergence_by_mean: f32 = mean_gap * inverse_target_variance / dimensions;
            const divergence_by_log_std: f32 = (policy_variance * inverse_target_variance - 1.0) / dimensions;
            const gradient_at_mean: f32 = row_weight * inverse_scale * divergence_by_mean;
            const gradient_at_log_std: f32 = row_weight * (inverse_scale * divergence_by_log_std - entropy_push);
            const centre_slope: f32 = 1.0 - mean * mean;
            const spread_slope: f32 = half_width * (1.0 - squashed_spread * squashed_spread);
            const gradient_row: u32 = params.dy_off + id * 2 * dimension_count;
            b_dacts[gradient_row + dimension] = gradient_at_mean * centre_slope;
            b_dacts[gradient_row + dimension_count + dimension] = gradient_at_log_std * spread_slope;
        }
    }
    const divergence: f32 = divergence_sum - 0.5 * dimensions;
    b_acts[params.y_off + id] = divergence / dimensions;
    b_acts[params.z_off + id] = log_std_sum + dimensions * (half_log_tau + 0.5);
}

/// The policy's divergence from the planner at each row, ONE THREAD PER ROW: `policy_distill_bwd`'s first half, for the
/// running scale - which must move with this batch's divergences before the gradients divide by it (torch BMPC's
/// order), and divergences do not depend on the scale. Reads and writes as `policy_distill_bwd` does, except dacts.
pub fn policy_divergence(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    distillRow(id, .divergence_only);
}

/// The policy's distillation loss, backward, ONE THREAD PER ROW (this section's head): for `rows` rows of `out_dim`
/// action dimensions -
///   reads  acts  `x_off`  the policy network's raw outputs [rows, 2 x dims]: raw centres, then raw spreads
///               `t_off`  the planner's means [rows, dims];  `u_off`  the logs of its spreads [rows, dims]
///               `v_off`  each row's weight [rows];  `e_off`  the scale's reciprocal (one value)
///   writes dacts `dy_off` the gradient at the raw outputs [rows, 2 x dims]
///          acts  `y_off`  each row's divergence, KL / dims [rows];  `z_off`  each row's entropy [rows]
/// The spread's bounds and the entropy's coefficient are `distill_log_std_low`, `_high`, `distill_entropy_coefficient`.
pub fn policy_distill_bwd(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    distillRow(id, .divergence_and_gradients);
}

/// BMPC's running scale, moved by one batch, ONE THREAD (`zimrnum.RunningScale.update`): the `count` values at acts
/// `x_off` - the first step's divergences, from `policy_divergence` - copied into acts `z_off` and sorted there, their
/// 5th and 95th percentiles (`zm.quantileOfSorted`, the host's own interpolation), and the scale at acts `v_off` -
/// which persists from update to update, 1 to start - moved a fraction `tau` toward their spread
/// (`zm.runningScaleStep`). Its reciprocal, what `policy_distill_bwd` multiplies by, goes to acts `e_off`.
///
/// The sort is an insertion sort in one thread: a batch is a few hundred values, and any correct sort puts finite
/// values in the same order, so the percentiles are the host's exactly.
pub fn running_scale_update(id: u32) void {
    if (id != 0) {
        return;
    }
    const count: u32 = params.count;
    var copy_index: u32 = 0;
    while (copy_index < count) : (copy_index += 1) {
        b_acts[params.z_off + copy_index] = b_acts[params.x_off + copy_index];
    }
    // Insertion sort: each value in turn slides left past every larger one.
    var sorted_end: u32 = 1;
    while (sorted_end < count) : (sorted_end += 1) {
        const inserted: f32 = b_acts[params.z_off + sorted_end];
        var position: u32 = sorted_end;
        while (position > 0 and b_acts[params.z_off + position - 1] > inserted) : (position -= 1) {
            b_acts[params.z_off + position] = b_acts[params.z_off + position - 1];
        }
        b_acts[params.z_off + position] = inserted;
    }
    const sorted: ActsRow = .{ .start = params.z_off };
    const fifth_percentile: f32 = zm.quantileOfSorted(f32, ActsRow, sorted, count, 0.05);
    const ninety_fifth_percentile: f32 = zm.quantileOfSorted(f32, ActsRow, sorted, count, 0.95);
    const spread: f32 = ninety_fifth_percentile - fifth_percentile;
    const scale: f32 = zm.runningScaleStep(f32, b_acts[params.v_off], params.tau, spread);
    b_acts[params.v_off] = scale;
    b_acts[params.e_off] = 1.0 / scale;
}

// -- THE VALUE TARGETS (`zimrrl.LatentValueTargets`: what a stored step is worth, by one step of the model) --
//
// A value head is trained toward what its state is worth under the agent's CURRENT behaviour, estimated by the model
// itself - one step of it (BMPC's lookahead), through every dynamics head (EfficientTDMPC's eq. 14):
//
//     a       = the policy's draw at the stored step's true latent z      (`policy_draw`)
//     target  = R(z, a)  +  gamma x (1 / heads) x sum over dynamics heads i of  V_target(f_i(z, a))
//
// with V_target the TARGET value heads' decoded prediction, averaged over them. On the kit the true latents are the
// rollout's encoder pass; the drawn action is written beside its latent in a wide row, which the reward head and every
// dynamics head read; each head's next latent goes through every target value head; and `value_target_combine` adds
// it up per stored step in the host's order of arithmetic.

/// The policy's draw at each row, ONE THREAD PER ROW (`zm.tanhMeanGaussianDraw`, the host's own): from the policy
/// network's raw outputs at acts `x_off` [rows, 2 x dims] through the head (`policyHead`, its bounds
/// `distill_log_std_low` and `_high`) and the standard normal noise at acts `u_off` [rows, dims], each action written
/// into the action columns of the wide rows at acts `y_off` - rows `stride` apart, from column `col` - where the
/// reward head and the dynamics heads read it beside its latent.
pub fn policy_draw(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const dimension_count: u32 = params.out_dim;
    const raw_row: u32 = params.x_off + id * 2 * dimension_count;
    const noise_row: u32 = params.u_off + id * dimension_count;
    const action_columns: u32 = params.y_off + id * params.stride + params.col;
    var dimension: u32 = 0;
    while (dimension < dimension_count) : (dimension += 1) {
        const raw_centre: f32 = b_acts[raw_row + dimension];
        const raw_spread: f32 = b_acts[raw_row + dimension_count + dimension];
        const head: PolicyHeadOutputs = policyHead(raw_centre, raw_spread);
        const noise: f32 = b_acts[noise_row + dimension];
        b_acts[action_columns + dimension] = zm.tanhMeanGaussianDraw(f32, head.mean, head.log_std, noise);
    }
}

/// Each stored step's value target, ONE THREAD PER ROW, in `zimrrl.LatentValueTargets.compute`'s order of
/// arithmetic: for each of `target_dynamics_heads` heads in turn, its own target - the reward, then gamma over the
/// value-head count times each of `target_value_heads` target values, added in order - and the heads' targets summed
/// in order and scaled once by 1 / heads (a single head's target taken as it is).
///   reads  acts `x_off`  each row's decoded reward [rows]
///          acts `v_off`  the decoded target values, [dynamics head][target value head][rows]
///   writes acts `y_off`  each row's value target [rows] - the value heads' targets in the world model's loss
pub fn value_target_combine(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const row_count: u32 = params.rows;
    const dynamics_heads: u32 = params.target_dynamics_heads;
    const value_heads: u32 = params.target_value_heads;
    const reward: f32 = b_acts[params.x_off + id];
    const share_per_value_head: f32 = params.gamma / float(value_heads);
    var sum_over_heads: f32 = 0;
    var dynamics_head: u32 = 0;
    while (dynamics_head < dynamics_heads) : (dynamics_head += 1) {
        // This head's own target: the reward its step earns, then the discounted value where it leads.
        var head_target: f32 = 0;
        head_target += 1.0 * reward;
        var value_head: u32 = 0;
        while (value_head < value_heads) : (value_head += 1) {
            const block: u32 = dynamics_head * value_heads + value_head;
            const target_value: f32 = b_acts[params.v_off + block * row_count + id];
            head_target += share_per_value_head * target_value;
        }
        sum_over_heads = if (dynamics_head == 0) head_target else sum_over_heads + head_target;
    }
    const share_per_dynamics_head: f32 = 1.0 / float(dynamics_heads);
    const target: f32 = if (dynamics_heads == 1) sum_over_heads else sum_over_heads * share_per_dynamics_head;
    b_acts[params.y_off + id] = target;
}

/// The mean of `target_value_heads` target values for row `row`, each head's block `target_head_stride` apart from
/// `offset` (0: the rows, [value head][rows]): summed in head order, then divided once.
fn meanTargetValue(offset: u32, row: u32) f32 {
    const head_stride: u32 = if (params.target_head_stride == 0) params.rows else params.target_head_stride;
    const value_heads: u32 = params.target_value_heads;
    var value_sum: f32 = 0;
    var value_head: u32 = 0;
    while (value_head < value_heads) : (value_head += 1) {
        value_sum += b_acts[offset + value_head * head_stride + row];
    }
    return value_sum / float(value_heads);
}

/// One step of the critic's LAMBDA-RETURNS along an imagined trajectory, walked BACKWARD from its last step - the
/// recurrence of `zimrrl.gae`, generalised advantage estimation, in f32, ONE THREAD PER ROW:
///
///     delta_k   = c_(k+1) + gamma x V_(k+1) - V_k                     the step's temporal difference
///     running_k = delta_k + gamma x lambda x running_(k+1)            the advantage, 0 after the last step
///     G_k       = running_k + V_k                                     the return the critic is fitted to at state k
///
/// with c the cost of the step that leaves state k, V the target heads' mean value (`meanTargetValue`), gamma `gamma`
/// and lambda `target_lambda`. At lambda 0 the return is the one-step target, cost + gamma x V_(k+1); at 1 it is
/// the whole discounted cost of the trajectory, its last state's value after it. A fall is no terminal, so no trace is
/// cut. Called once per step, the steps last to first, so `running_(k+1)` is the previous call's.
///   reads   acts `x_off`  each row's c_(k+1) [rows]
///           acts `v_off`  the target values at state k+1, [value head][rows]
///           acts `u_off`  the target values at state k, [value head][rows]
///           acts `t_off`  each row's running advantage running_(k+1) [rows] - zero before the last step
///   writes  acts `t_off`  running_k, for the step before
///           acts `y_off`  G_k [rows]
pub fn value_lambda_combine(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const cost: f32 = b_acts[params.x_off + id];
    const next_value: f32 = meanTargetValue(params.v_off, id);
    const value: f32 = meanTargetValue(params.u_off, id);
    const following_advantage: f32 = b_acts[params.t_off + id];
    const delta: f32 = cost + params.gamma * next_value - value;
    const trace: f32 = params.gamma * params.target_lambda;
    const advantage: f32 = delta + trace * following_advantage;
    b_acts[params.t_off + id] = advantage;
    b_acts[params.y_off + id] = advantage + value;
}

/// Zeros `rows` numbers of acts from `y_off`: a region a recurrence starts from, such as `value_lambda_combine`'s
/// running advantage. A product with zero would not do - 0 x NaN is NaN, and a region holds anything before its first
/// use.
pub fn zero_rows(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    b_acts[params.y_off + id] = 0;
}

/// Zeros `rows` numbers of dacts from `y_off`: a gradient a recurrence carries back from its start, such as the action
/// filter's carry (`lat_act_bwd`), zero before the window's last step.
pub fn zero_gradient_rows(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    b_dacts[params.y_off + id] = 0;
}

// -- SCORING A PLAN (`zimrrl.LatentPlanScorer`: the world model's imagination, for the planner) --
//
// The planner proposes many candidate plans per state - `plan_candidates` of them, `plan_horizon` actions each - and
// the model scores them all. Every candidate starts from its state's latent (`broadcast_rows` copies it to every
// candidate's row), is rolled under EVERY dynamics head, and is read at each step by the reward head and, at the
// depths its objective weighs, by every value head. Each (dynamics head i, value head j) gives an estimate of the
// plan's worth:
//
//     Q(i, j)  =  sum over steps t of  w_t x r_(i,t)   +   sum over depths d of  v_d x V_(i,d,j)
//
// with w and v the objective's weights (`zimrrl.planObjectiveWeights`: the discounted sum, or the mean over the plan's
// prefixes). The score is their mean, and the variance of that mean their disagreement; a pessimistic planner pays
// beta standard deviations of it (`plan_score_combine`, the host's order of arithmetic throughout).

/// Each of `rows` packed source rows of `count` values (acts at `x_off`) copied to `row_copies` consecutive destination
/// rows, into columns `col` .. `col` + `count` of rows `stride` floats apart (acts at `y_off`), ONE THREAD PER VALUE
/// COPIED: a state's latent written into the latent columns of the wide row of each of its candidates (the scorer) or
/// each of its policy plans (the policy's plans).
///
///     source rows (one per state)        destination rows (row_copies per state)
///     state 0's latent        -->        copy 0, copy 1, ..., copy row_copies - 1      (state 0's block)
///     state 1's latent        -->        copy 0, copy 1, ..., copy row_copies - 1      (state 1's block)
pub fn broadcast_rows(id: u32) void {
    const destination_rows: u32 = params.rows * params.row_copies;
    const value_count: u32 = destination_rows * params.count;
    if (id >= value_count) {
        return;
    }
    const destination_row: u32 = id / params.count;
    const column: u32 = id % params.count;
    const source_row: u32 = destination_row / params.row_copies;
    const source_index: u32 = params.x_off + source_row * params.count + column;
    const destination_index: u32 = params.y_off + destination_row * params.stride + params.col + column;
    b_acts[destination_index] = b_acts[source_index];
}

/// Rows carried from a packed layout of `plan_policy_plans` rows per state into each state's block of
/// `plan_candidates` candidate rows, ONE THREAD PER VALUE: source row r = state x plans + plan, read at acts `x_off` +
/// r x `stride` + `col` (`count` values - the action columns of the policy plans' wide rows), written packed at acts
/// `y_off` + (state x candidates + plan) x `count` - the step's block of the scorer's candidate actions, where the
/// policy's plans are the first rows of each state's block. `rows` is states x plans.
pub fn copy_row_blocks(id: u32) void {
    const value_count: u32 = params.rows * params.count;
    if (id >= value_count) {
        return;
    }
    const source_row: u32 = id / params.count;
    const column: u32 = id % params.count;
    const state: u32 = source_row / params.plan_policy_plans;
    const plan: u32 = source_row % params.plan_policy_plans;
    const destination_row: u32 = state * params.plan_candidates + plan;
    const source_index: u32 = params.x_off + source_row * params.stride + params.col + column;
    const destination_index: u32 = params.y_off + destination_row * params.count + column;
    b_acts[destination_index] = b_acts[source_index];
}

/// One estimate's two parts, for candidate row `row` (`plan_score_combine`): the dynamics head's weighted rewards,
/// summed in step order. The combine asks for it again for every value head rather than keeping it: a plan is a few
/// steps long, so the repeat costs a few multiplications, and each estimate is then formed exactly as the host forms
/// it - the reward part, then the value part added - with no array a GPU thread would have to hold.
fn planRewardPart(row: u32, dynamics_head: u32) f32 {
    const row_count: u32 = params.rows;
    const horizon: u32 = params.plan_horizon;
    var reward_part: f32 = 0;
    var step: u32 = 0;
    while (step < horizon) : (step += 1) {
        const reward_weight: f32 = b_acts[params.u_off + step];
        const reward: f32 = b_acts[params.x_off + (dynamics_head * horizon + step) * row_count + row];
        reward_part += reward_weight * reward;
    }
    return reward_part;
}

/// The value part of estimate (dynamics head, value head) for candidate row `row`: the value weights times that value
/// head's decoded values at the depths they weigh, summed in depth order.
fn planValuePart(row: u32, dynamics_head: u32, value_head: u32) f32 {
    const row_count: u32 = params.rows;
    const horizon: u32 = params.plan_horizon;
    const value_heads: u32 = params.plan_value_heads;
    var value_part: f32 = 0;
    var depth: u32 = 0;
    while (depth < horizon) : (depth += 1) {
        const value_weight: f32 = b_acts[params.u_off + horizon + depth];
        if (value_weight != 0) {
            const block: u32 = (dynamics_head * horizon + depth) * value_heads + value_head;
            const value: f32 = b_acts[params.v_off + block * row_count + row];
            value_part += value_weight * value;
        }
    }
    return value_part;
}

/// A dynamics head's score for candidate row `row`: its weighted rewards, then each depth's value averaged over the
/// value heads - in the host's order, depth by depth, value head by value head.
fn planHeadScore(row: u32, dynamics_head: u32) f32 {
    const row_count: u32 = params.rows;
    const horizon: u32 = params.plan_horizon;
    const value_heads: u32 = params.plan_value_heads;
    var head_score: f32 = planRewardPart(row, dynamics_head);
    var depth: u32 = 0;
    while (depth < horizon) : (depth += 1) {
        const value_weight: f32 = b_acts[params.u_off + horizon + depth];
        if (value_weight != 0) {
            const share_per_value_head: f32 = value_weight / float(value_heads);
            var value_head: u32 = 0;
            while (value_head < value_heads) : (value_head += 1) {
                const block: u32 = (dynamics_head * horizon + depth) * value_heads + value_head;
                const value: f32 = b_acts[params.v_off + block * row_count + row];
                head_score += share_per_value_head * value;
            }
        }
    }
    return head_score;
}

/// Every candidate's score and variance, ONE THREAD PER CANDIDATE ROW (this section's head): `rows` candidate rows,
///   reads  acts `x_off`  the decoded rewards, [dynamics head][step][rows]
///          acts `v_off`  the decoded values, [dynamics head][depth][value head][rows] (the depths with weight)
///          acts `u_off`  the objective's weights: `plan_horizon` reward weights, then as many value weights
///   writes acts `y_off`  each candidate's score: the dynamics heads' mean, less `plan_pessimism` standard deviations
///          acts `z_off`  each candidate's variance of that mean: the estimates' variance over their count
pub fn plan_score_combine(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const dynamics_heads: u32 = params.plan_dynamics_heads;
    const value_heads: u32 = params.plan_value_heads;
    // The score: the dynamics heads' mean - summed in order, scaled once; one head's score as it is.
    var sum_over_heads: f32 = planHeadScore(id, 0);
    var dynamics_head: u32 = 1;
    while (dynamics_head < dynamics_heads) : (dynamics_head += 1) {
        sum_over_heads += planHeadScore(id, dynamics_head);
    }
    const share_per_dynamics_head: f32 = 1.0 / float(dynamics_heads);
    var score: f32 = if (dynamics_heads == 1) sum_over_heads else sum_over_heads * share_per_dynamics_head;
    // The variance of the mean: the Nf x Nv estimates' variance, over their count.
    const estimate_count: f32 = float(dynamics_heads * value_heads);
    var estimate_sum: f32 = 0;
    dynamics_head = 0;
    while (dynamics_head < dynamics_heads) : (dynamics_head += 1) {
        const reward_part: f32 = planRewardPart(id, dynamics_head);
        var value_head: u32 = 0;
        while (value_head < value_heads) : (value_head += 1) {
            const estimate: f32 = reward_part + planValuePart(id, dynamics_head, value_head);
            estimate_sum += estimate;
        }
    }
    const estimate_mean: f32 = estimate_sum / estimate_count;
    var squared_deviation_sum: f32 = 0;
    dynamics_head = 0;
    while (dynamics_head < dynamics_heads) : (dynamics_head += 1) {
        const reward_part: f32 = planRewardPart(id, dynamics_head);
        var value_head: u32 = 0;
        while (value_head < value_heads) : (value_head += 1) {
            const estimate: f32 = reward_part + planValuePart(id, dynamics_head, value_head);
            const deviation: f32 = estimate - estimate_mean;
            squared_deviation_sum += deviation * deviation;
        }
    }
    const estimates_variance: f32 = squared_deviation_sum / estimate_count;
    const score_variance: f32 = estimates_variance / estimate_count;
    if (params.plan_pessimism != 0) {
        const standard_deviation_of_mean: f32 = sqrt(score_variance);
        score -= params.plan_pessimism * standard_deviation_of_mean;
    }
    b_acts[params.y_off + id] = score;
    b_acts[params.z_off + id] = score_variance;
}

// -- ONE ROUND OF MPPI (`zimrrl.Mppi`: a population search over plans) --
//
// Each state keeps a Gaussian over plans - a MEAN plan and a SPREAD, one standard deviation per step and action
// dimension, [states][horizon][action]. One round: every candidate past the policy's own (`mppi_sample`) is drawn
// from its state's Gaussian, mean + spread x noise, clamped to [-1, 1]; the model scores them all
// (`plan_score_combine`); each state keeps its best `mppi_elites` (`mppi_elites`), weighed by
// exp(temperature x (score - best)) - the best weighs 1, one a point worse e^(-temperature) - and the Gaussian moves
// to the elites' weighted mean and their weighted standard deviation, clamped to [floor, ceiling] (`mppi_refit`): the
// floor keeps the search from collapsing onto one plan.

/// THE PLAN'S KNOTS (`PlanningSettings.fine_steps`, `knot_span`): the points of a plan the search draws, at two
/// scales. The first `plan_fine_steps` steps are each a knot - near the state, where a correction's every step
/// matters - and from the last of them a knot follows every `plan_knot_span` steps to the horizon's last step; a plan's
/// value at the steps between two knots is the straight line from one to the next. (horizon - fine steps) divides by
/// the span, which the planner's settings guarantee. 0 fine steps: every step a knot, the search drawing each step on
/// its own.
///
///     horizon 16, fine 16:         every step a knot                    16 knots
///     horizon 16, fine 1, span 5:  knots at steps 0, 5, 10, 15           4 knots
///     horizon 20, fine 4, span 4:  knots at steps 0, 1, 2, 3, 7, 11, 15, 19     8 knots - the far half's knots one
///                                  per jump of a model that predicts 4 steps at once
inline fn planFineSteps() u32 {
    return if (params.plan_fine_steps == 0) params.plan_horizon else params.plan_fine_steps;
}

/// The plan's knots (`planFineSteps` then one every span steps).
inline fn planKnots() u32 {
    const fine_steps: u32 = planFineSteps();
    return fine_steps + (params.plan_horizon - fine_steps) / params.plan_knot_span;
}

/// The step knot `knot` sits at.
inline fn planKnotStep(knot: u32) u32 {
    const fine_steps: u32 = planFineSteps();
    if (knot < fine_steps) {
        return knot;
    }
    const last_fine_step: u32 = fine_steps - 1;
    return last_fine_step + (knot - last_fine_step) * params.plan_knot_span;
}

/// The knot at step `step`, or the last before it.
inline fn planKnotAtOrBefore(step: u32) u32 {
    const fine_steps: u32 = planFineSteps();
    if (step < fine_steps) {
        return step;
    }
    const last_fine_step: u32 = fine_steps - 1;
    return last_fine_step + (step - last_fine_step) / params.plan_knot_span;
}

/// How many steps `step` lies past its knot (`planKnotAtOrBefore`): 0 at a knot.
inline fn planStepsPastKnot(step: u32) u32 {
    const fine_steps: u32 = planFineSteps();
    if (step < fine_steps) {
        return 0;
    }
    const last_fine_step: u32 = fine_steps - 1;
    return (step - last_fine_step) % params.plan_knot_span;
}

/// One knot of one candidate drawn from its state's Gaussian: mean + spread x noise, clamped to [-1, 1] - the means at
/// acts `t_off` and the spreads at `u_off`, [states][knots][action] each, the noise at `v_off`,
/// [states][candidates][knots][action].
inline fn knotProposal(
    state: u32,
    candidate: u32,
    knot: u32,
    dimension: u32,
    knots: u32,
) f32 {
    const action_width: u32 = params.out_dim;
    const candidates: u32 = params.plan_candidates;
    const gaussian_index: u32 = (state * knots + knot) * action_width + dimension;
    const noise_index: u32 = ((state * candidates + candidate) * knots + knot) * action_width + dimension;
    const noise: f32 = b_acts[params.v_off + noise_index];
    const proposal: f32 = b_acts[params.t_off + gaussian_index] + b_acts[params.u_off + gaussian_index] * noise;
    return clamp(proposal, -1.0, 1.0);
}

/// The round's candidates drawn from each state's Gaussian, ONE THREAD PER (state, candidate, step, dimension): for
/// `rows` states of `plan_candidates` candidates, each candidate from `plan_policy_plans` on (the policy's own rows
/// are left alone) gets mean + spread x noise, clamped to [-1, 1] -
///   reads  acts `t_off` the means, `u_off` the spreads, [states][horizon][action] each;
///          acts `v_off` the noise, [states][candidates][horizon][action]
///   writes acts `y_off` the candidates' actions, [horizon][states x candidates][action] (the scorer's layout)
pub fn mppi_sample(id: u32) void {
    const action_width: u32 = params.out_dim;
    const horizon: u32 = params.plan_horizon;
    const candidates: u32 = params.plan_candidates;
    const value_count: u32 = params.rows * candidates * horizon * action_width;
    if (id >= value_count) {
        return;
    }
    // The thread's value, read off its index in the NOISE's layout - [state][candidate][step][dimension], the order
    // the host draws it in - so each thread reads its own noise at `v_off` + id. It writes into the candidates' layout,
    // [step][state x candidate][dimension], which the scorer reads step by step.
    const dimension: u32 = id % action_width;
    const step: u32 = (id / action_width) % horizon;
    const candidate: u32 = (id / (action_width * horizon)) % candidates;
    const state: u32 = id / (action_width * horizon * candidates);
    if (candidate < params.plan_policy_plans) {
        return;
    }
    // The knot at or before this step, drawn; between two knots, the straight line to the next one (`planKnots`).
    const knots: u32 = planKnots();
    const knot: u32 = planKnotAtOrBefore(step);
    const steps_past_knot: u32 = planStepsPastKnot(step);
    const at_knot: f32 = knotProposal(state, candidate, knot, dimension, knots);
    var value: f32 = at_knot;
    const is_between_knots: bool = steps_past_knot != 0 and knot + 1 < knots;
    if (is_between_knots) {
        const at_next_knot: f32 = knotProposal(state, candidate, knot + 1, dimension, knots);
        const share_of_span: f32 = float(steps_past_knot) / float(params.plan_knot_span);
        value = at_knot + share_of_span * (at_next_knot - at_knot);
    }
    const row_count: u32 = params.rows * candidates;
    const candidate_row: u32 = state * candidates + candidate;
    const candidate_index: u32 = params.y_off + (step * row_count + candidate_row) * action_width + dimension;
    b_acts[candidate_index] = value;
}

/// Each state's elites and their weights, ONE THREAD PER STATE: of its `plan_candidates` scores at acts `x_off`
/// (made rankable, `zm.rankableScore`), the best `mppi_elites`, best first, in the host's order - the host sorts
/// ascending and stably and reads from the end, so among equal scores the higher candidate comes first. Each round
/// takes the largest (score, candidate) pair strictly below the last one taken, so nothing is sorted and nothing is
/// marked. Then each elite's weight, exp(`mppi_temperature` x (score - best)) - or, relative to the elites' spread
/// (`mppi_temperature_mode`, `MppiTemperature`), exp(`mppi_temperature` x (score - best) / (best - worst elite)) -
/// summed in rank order and each divided by the sum. Writes the elites' candidate numbers at acts `y_off` and their
/// weights at acts `z_off`, [states][elites].
pub fn mppi_elites(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    // A candidate's number is stored as a float in the f32 buffer: exact, since every whole number below 2^24 is a
    // float, and a state has hundreds of candidates. `mppi_refit` reads it back with `@trunc`.
    //
    // Why rank by (score, candidate) PAIRS: the host sorts the scores ascending and stably - equal scores keep their
    // candidates' order - and reads the elites from the end, so among equal scores the HIGHER candidate is taken first.
    // Comparing pairs reproduces exactly that, and picking each time the largest pair below the last one taken needs
    // no sort and no record of which candidates were taken: a state's few hundred scores are read once per elite.
    const candidates: u32 = params.plan_candidates;
    const elite_count: u32 = params.mppi_elites;
    const scores_start: u32 = params.x_off + id * candidates;
    const elites_start: u32 = id * elite_count;
    var previous_score: f32 = 0;
    var previous_candidate: u32 = 0;
    var rank: u32 = 0;
    while (rank < elite_count) : (rank += 1) {
        var found: bool = false;
        var best_score: f32 = 0;
        var best_candidate: u32 = 0;
        var candidate: u32 = 0;
        while (candidate < candidates) : (candidate += 1) {
            const rankable: f32 = zm.rankableScore(f32, b_acts[scores_start + candidate]);
            const below_previous: bool = rank == 0 or rankable < previous_score or
                (rankable == previous_score and candidate < previous_candidate);
            const above_best: bool = !found or rankable > best_score or
                (rankable == best_score and candidate > best_candidate);
            if (below_previous and above_best) {
                found = true;
                best_score = rankable;
                best_candidate = candidate;
            }
        }
        b_acts[params.y_off + elites_start + rank] = float(best_candidate);
        previous_score = best_score;
        previous_candidate = best_candidate;
    }
    // The weights: the best weighs exactly 1 before normalising, so the sum is never zero.
    const best_elite: u32 = @trunc(b_acts[params.y_off + elites_start]);
    const best_rankable: f32 = zm.rankableScore(f32, b_acts[scores_start + best_elite]);
    // The scale a score difference is read in: 1 (absolute), or the elites' own spread - the best minus the worst
    // elite, the last one taken (relative). Elites all equal in score weigh alike.
    const worst_elite: u32 = @trunc(b_acts[params.y_off + elites_start + elite_count - 1]);
    const worst_rankable: f32 = zm.rankableScore(f32, b_acts[scores_start + worst_elite]);
    const elite_spread: f32 = best_rankable - worst_rankable;
    const is_relative: bool = params.mppi_temperature_mode == @backingInt(MppiTemperature.relative_to_elites);
    const per_score_unit: f32 = if (!is_relative) 1.0 else if (elite_spread > 0) 1.0 / elite_spread else 0.0;
    var weight_sum: f32 = 0;
    rank = 0;
    while (rank < elite_count) : (rank += 1) {
        const elite: u32 = @trunc(b_acts[params.y_off + elites_start + rank]);
        const rankable: f32 = zm.rankableScore(f32, b_acts[scores_start + elite]);
        const weight: f32 = @exp(params.mppi_temperature * (rankable - best_rankable) * per_score_unit);
        b_acts[params.z_off + elites_start + rank] = weight;
        weight_sum += weight;
    }
    rank = 0;
    while (rank < elite_count) : (rank += 1) {
        b_acts[params.z_off + elites_start + rank] /= weight_sum;
    }
}

/// Each state's Gaussian refitted to its elites, ONE THREAD PER (state, step, dimension): the elites' weighted mean,
/// then - in a second pass, as the host - their weighted variance about it, and its square root clamped to
/// [`mppi_min_spread`, `mppi_max_spread`] -
///   reads  acts `x_off` the candidates' actions, [horizon][states x candidates][action];
///          acts `y_off` the elites' candidate numbers, `z_off` their weights, [states][elites] each
///   writes acts `t_off` the means, `u_off` the spreads, [states][horizon][action] each
pub fn mppi_refit(id: u32) void {
    const action_width: u32 = params.out_dim;
    const knots: u32 = planKnots();
    const value_count: u32 = params.rows * knots * action_width;
    if (id >= value_count) {
        return;
    }
    const dimension: u32 = id % action_width;
    const knot: u32 = (id / action_width) % knots;
    const state: u32 = id / (action_width * knots);
    // A knot's Gaussian is fitted to the elites' values at the knot's own step - exactly their knot values for the
    // candidates the search drew, the value at that step for the flow's.
    const step: u32 = planKnotStep(knot);
    const candidates: u32 = params.plan_candidates;
    const elite_count: u32 = params.mppi_elites;
    const row_count: u32 = params.rows * candidates;
    const elites_start: u32 = state * elite_count;
    const step_start: u32 = params.x_off + step * row_count * action_width;
    var weighted_mean: f32 = 0;
    var rank: u32 = 0;
    while (rank < elite_count) : (rank += 1) {
        const elite: u32 = @trunc(b_acts[params.y_off + elites_start + rank]);
        const weight: f32 = b_acts[params.z_off + elites_start + rank];
        const elite_value: f32 = b_acts[step_start + (state * candidates + elite) * action_width + dimension];
        weighted_mean += weight * elite_value;
    }
    var weighted_variance: f32 = 0;
    rank = 0;
    while (rank < elite_count) : (rank += 1) {
        const elite: u32 = @trunc(b_acts[params.y_off + elites_start + rank]);
        const weight: f32 = b_acts[params.z_off + elites_start + rank];
        const elite_value: f32 = b_acts[step_start + (state * candidates + elite) * action_width + dimension];
        const deviation: f32 = elite_value - weighted_mean;
        weighted_variance += weight * deviation * deviation;
    }
    const weighted_deviation: f32 = sqrt(weighted_variance);
    b_acts[params.t_off + id] = weighted_mean;
    b_acts[params.u_off + id] = clamp(weighted_deviation, params.mppi_min_spread, params.mppi_max_spread);
}

// -- A WHOLE DECISION (`zimrrl.Mppi.plan`, `choose`, `explore`) --
//
// Around the rounds: the warm start before them (`mppi_begin` - each state's mean is its last plan shifted one step,
// since the first step has been taken, or zero at an episode's start; every spread restarts at its ceiling), and after
// them the choice (`mppi_choose` - one elite drawn by the refit's weights, its first action the decision's target,
// the first step's spread beside it) and, while training, the jitter (`mppi_explore`).

/// The warm start, ONE THREAD PER (state, action dimension) walking the plan's steps in order: for `rows` states,
/// where the state's flag at acts `x_off` is 1 the plan moves forward by `mppi_warm_shift` steps - the steps since it
/// was decided, 1 for a planner that decides every step - each step's mean becoming that of the step S later, the
/// last S steps' 0; where the flag is 0 every step's mean is 0. Every spread is set to `mppi_max_spread`. The means at
/// acts `t_off`, the spreads at `u_off`, [states][horizon][action]. One thread per column walking up the steps reads
/// every step it needs (ahead of the one it writes) before writing it, so the shift needs no second buffer.
///
///     warm, horizon 4, shift 1:   means [0.2, 0.5, -0.1, 0.7]   -->   [0.5, -0.1, 0.7, 0]
///     warm, horizon 4, shift 2:   means [0.2, 0.5, -0.1, 0.7]   -->   [-0.1, 0.7, 0, 0]
///     cold:                       any means                    -->   [0, 0, 0, 0]
pub fn mppi_begin(id: u32) void {
    const action_width: u32 = params.out_dim;
    const horizon: u32 = params.plan_horizon;
    if (id >= params.rows * action_width) {
        return;
    }
    const state: u32 = id / action_width;
    const dimension: u32 = id % action_width;
    const warm_start: bool = b_acts[params.x_off + state] == 1.0;
    const shift: u32 = params.mppi_warm_shift;
    const knots: u32 = planKnots();
    var knot: u32 = 0;
    while (knot < knots) : (knot += 1) {
        const gaussian_index: u32 = (state * knots + knot) * action_width + dimension;
        // The old plan `shift` steps later - between its knots where it falls between them - or 0 past its end.
        // Every knot read lies at or after the one written, so the walk reads before it overwrites.
        const source_step: u32 = planKnotStep(knot) + shift;
        const is_past_plan: bool = source_step >= horizon;
        var shifted_mean: f32 = 0.0;
        if (!is_past_plan) {
            const source_knot: u32 = planKnotAtOrBefore(source_step);
            const steps_past_knot: u32 = planStepsPastKnot(source_step);
            const source_index: u32 = (state * knots + source_knot) * action_width + dimension;
            shifted_mean = b_acts[params.t_off + source_index];
            const is_between_knots: bool = steps_past_knot != 0 and source_knot + 1 < knots;
            if (is_between_knots) {
                const next_mean: f32 = b_acts[params.t_off + source_index + action_width];
                const share_of_span: f32 = float(steps_past_knot) / float(params.plan_knot_span);
                shifted_mean += share_of_span * (next_mean - shifted_mean);
            }
        }
        b_acts[params.t_off + gaussian_index] = if (warm_start) shifted_mean else 0.0;
        b_acts[params.u_off + gaussian_index] = params.mppi_max_spread;
    }
}

/// The choice, ONE THREAD PER STATE (`Mppi.choose` with `draw_elite`, BMPC's): one elite drawn by the refit's weights -
/// the uniform draw at acts `v_off` + state against the weights' running sum, in rank order, the first rank whose sum
/// exceeds it (the last rank if rounding leaves none) - and its FIRST action, the decision's target, with the first
/// step's spread beside it -
///   reads  acts `x_off` the candidates' actions, [horizon][states x candidates][action] (step 0's block);
///          acts `y_off` the elites' candidate numbers, `z_off` their weights, [states][elites] each;
///          acts `u_off` the spreads, [states][horizon][action]
///   writes acts `t_off` the targets and `t_off` + states x action the first spreads, [states][action] each;
///          acts `e_off` + state: the chosen candidate's number
pub fn mppi_choose(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const action_width: u32 = params.out_dim;
    const candidates: u32 = params.plan_candidates;
    const elite_count: u32 = params.mppi_elites;
    const elites_start: u32 = id * elite_count;
    const draw: f32 = b_acts[params.v_off + id];
    // The first rank whose running sum exceeds the draw. A flag rather than a `break`: the loop runs to its end on
    // every thread, and once a rank is chosen nothing after it can change the choice.
    var chosen_rank: u32 = elite_count - 1;
    var has_chosen: bool = false;
    var running_total: f32 = 0;
    var rank: u32 = 0;
    while (rank < elite_count) : (rank += 1) {
        running_total += b_acts[params.z_off + elites_start + rank];
        const exceeds_draw: bool = draw < running_total;
        if (exceeds_draw and !has_chosen) {
            chosen_rank = rank;
            has_chosen = true;
        }
    }
    const chosen_candidate: u32 = @trunc(b_acts[params.y_off + elites_start + chosen_rank]);
    const chosen_row: u32 = id * candidates + chosen_candidate;
    b_acts[params.e_off + id] = float(chosen_candidate);
    const first_spreads_offset: u32 = params.t_off + params.rows * action_width;
    var dimension: u32 = 0;
    while (dimension < action_width) : (dimension += 1) {
        const first_action: f32 = b_acts[params.x_off + chosen_row * action_width + dimension];
        const first_spread: f32 = b_acts[params.u_off + (id * planKnots()) * action_width + dimension];
        b_acts[params.t_off + id * action_width + dimension] = first_action;
        b_acts[first_spreads_offset + id * action_width + dimension] = first_spread;
    }
}

/// The jitter while training, ONE THREAD PER (state, action dimension) (`Mppi.explore`): the target plus its spread
/// times a standard normal draw, clamped to [-1, 1] - the targets at acts `t_off` and the first spreads after them
/// (`mppi_choose`'s layout), the noise at acts `v_off`, [states][action]; the actions acted on to acts `y_off`.
///
///     target 0.6, spread 0.3, noise 1.5  -->  0.6 + 0.45 = 1.05  -->  1.0
pub fn mppi_explore(id: u32) void {
    const action_width: u32 = params.out_dim;
    if (id >= params.rows * action_width) {
        return;
    }
    const target: f32 = b_acts[params.t_off + id];
    const first_spread: f32 = b_acts[params.t_off + params.rows * action_width + id];
    const jitter: f32 = first_spread * b_acts[params.v_off + id];
    b_acts[params.y_off + id] = clamp(target + jitter, -1.0, 1.0);
}

// -- SAC --
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

/// y = r + discount (min(q1', q2') - alpha log pi'): q1' at acts[y_off], q2' at acts[z_off], log pi'
/// at acts[l_off], rewards then DISCOUNTS at acts[x_off] - the replay row's last column, gamma (1 - done)
/// for a one-step row, gamma^k for an n-step one; y to acts[t_off].
pub fn sac_target(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const q_next: f32 = @min(b_acts[params.y_off + id], b_acts[params.z_off + id]);
    const reward: f32 = b_acts[params.x_off + id];
    const discount: f32 = b_acts[params.x_off + params.rows + id];
    const soft: f32 = q_next - alpha() * b_acts[params.l_off + id];
    b_acts[params.t_off + id] = reward + discount * soft;
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

/// Log alpha's gradient, -alpha (mean log pi + target entropy): `zrl.Temperature.gradient`.
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

/// A target network's slow follow over `count` params - each target value moved `tau` of the way to its online twin
/// (`zm.polyakFollow`: the increment form, the endpoints exact - zimrnum's own, so the host and the kit follow to the
/// same bits). The targets at params `w_off`, the online values at params `v_off`.
pub fn polyak(id: u32) void {
    if (id >= params.count) {
        return;
    }
    const target_index: u32 = params.w_off + id;
    const online_index: u32 = params.v_off + id;
    const held: f32 = b_params[target_index];
    const online: f32 = b_params[online_index];
    b_params[target_index] = zm.polyakFollow(f32, held, online, params.tau);
}

// -- SUPERTRACK ON THE CARTPOLE --
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

// -- THE ROLLOUT'S TWO JOINS: a packed block into columns of a wider one, and back --
//
// A rollout feeds each step's predicted latent to the next step beside that step's action, in one WIDE row
// [ z | a ] that the next layer reads through its input stride. The joins are the two directions of one copy:
//
//     place_columns (acts)             packed  [ z z z z ]            wide  [ z z z z | a a ]
//                                       x_off   count columns   ->    y_off  rows `stride` apart, from column `col`
//
//     take_columns  (dacts)            wide    [ dz dz dz dz | da da ]      packed  [ dz dz dz dz ]
//                                       dx_off  rows `stride` apart   ->    dy_off  count columns, written over
//
// `lat_take` is `take_columns` that ADDS - the later arrivals of a gradient summed over several paths. One thread per
// value copied, (row, column).

/// A packed block written into columns of a wider, strided one (this section's head): `rows` x `count` values from
/// acts at `x_off` into acts at `y_off`, rows `stride` apart, columns `col` .. `col` + `count`. The forward join of a
/// rollout whose dynamics predicts the next latent outright (EfficientTDMPC), where `lat_advance` adds a change.
pub fn place_columns(id: u32) void {
    const value_count: u32 = params.rows * params.count;
    if (id >= value_count) {
        return;
    }
    const row: u32 = id / params.count;
    const column: u32 = id % params.count;
    const packed_index: u32 = params.x_off + row * params.count + column;
    const wide_index: u32 = params.y_off + row * params.stride + params.col + column;
    b_acts[wide_index] = b_acts[packed_index];
}

/// Columns of a wide gradient block copied out into a packed one (the joins' head): `rows` x `count` values from dacts
/// at `dx_off` (rows `stride` apart, columns `col` .. `col` + `count`) into dacts at `dy_off`, WRITTEN OVER what is
/// there. The first arrival of a gradient summed over several paths - `lat_take` adds the later ones - so the sum
/// needs no zeroed block to start from.
pub fn take_columns(id: u32) void {
    const value_count: u32 = params.rows * params.count;
    if (id >= value_count) {
        return;
    }
    const row: u32 = id / params.count;
    const column: u32 = id % params.count;
    const wide_index: u32 = params.dx_off + row * params.stride + params.col + column;
    const packed_index: u32 = params.dy_off + row * params.count + column;
    b_dacts[packed_index] = b_dacts[wide_index];
}

/// Dropout in a layer, forward, ONE THREAD PER VALUE: `count` values in acts at `x_off` multiplied in place by the
/// mask at acts `z_off` - each mask value 1 / keep for a kept unit, 0 for a dropped one (inverted dropout, the mask
/// drawn once per update: `zimrnum.fillDropoutMask`).
pub fn mask_values(id: u32) void {
    if (id >= params.count) {
        return;
    }
    const mask_value: f32 = b_acts[params.z_off + id];
    b_acts[params.x_off + id] *= mask_value;
}

/// Dropout in a layer, backward, ONE THREAD PER VALUE: `count` gradients in dacts at `dy_off` multiplied in place by
/// the forward's mask at acts `z_off` - a dropped unit passes no gradient back, a kept one passes it scaled as its
/// value was.
pub fn mask_gradients(id: u32) void {
    if (id >= params.count) {
        return;
    }
    const mask_value: f32 = b_acts[params.z_off + id];
    b_dacts[params.dy_off + id] *= mask_value;
}

/// dacts[dy_off + i] += dacts[dx_off + i] over `count`: a gradient arriving by a second path.
pub fn add_block(id: u32) void {
    if (id >= params.count) {
        return;
    }
    b_dacts[params.dy_off + id] += b_dacts[params.dx_off + id];
}

// -- THE LATENT WORLD MODEL'S TWO JOINS --
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
    // The network's output is the change itself - or, with the increments' statistics on, the change in units of
    // the feature's typical change: mean + spread x output (`LatentKit.increments_at`).
    var change: f32 = b_acts[params.t_off + r * params.count + c];
    if (params.lat_increments_on != 0) {
        const change_mean: f32 = b_acts[params.lat_increments_at + c];
        const change_spread: f32 = b_acts[params.lat_increments_at + params.count + c];
        change = change_mean + change_spread * change;
    }
    const next: f32 = b_acts[params.x_off + r * params.stride + c] + change;
    b_acts[params.y_off + r * params.stride + c] = next;
    b_acts[params.z_off + r * params.count + c] = next;
}

/// A GRADIENT BLOCK'S COLUMNS SCALED, ONE THREAD PER VALUE: `rows` rows of `count` columns from dacts `x_off` into
/// dacts `y_off` (the same place for in place), each column times its own factor from acts `u_off` + column. The
/// world model's change in units of each feature's typical change passes its gradient on times the feature's spread
/// (`LatentKit.changeGradient`); its loss weighs each feature's error by its own weight (`LatentKit.loss_weights_at`).
pub fn lat_scale_columns(id: u32) void {
    if (id >= params.rows * params.count) {
        return;
    }
    const column: u32 = id % params.count;
    const factor: f32 = b_acts[params.u_off + column];
    b_dacts[params.y_off + id] = b_dacts[params.x_off + id] * factor;
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

/// Exploration noise, identical on every device: an integer hash of (seed, row, column) - shifts,
/// xors and wrapping multiplies, the same bits on any GPU - turned into four uniforms from its top 24
/// bits (exact as floats), summed, centred and scaled by sqrt(3): mean 0, variance 1, bounded at
/// +-3.46 (Irwin-Hall, rather than Box-Muller, whose log and cos GPUs may round differently). Plain
/// Zig, so the CPU reference calls THIS function too - no copy to drift.
// -------- The resident data's layouts --------
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

/// Where a record's action begins. (Its features begin at nothing, so they need no name.)
pub fn latRecordAction(features: u32) u32 {
    return features;
}

/// A raw feature normalised as every state and goal a rollout reads is: (raw - mean) / spread, column `column` of
/// the normaliser at acts `norm_off` (`f` means, then `f` spreads). The one definition both gathers use - SuperTrack's
/// training windows (`lat_gather`) and the tracking planner's rows (`plan_gather`) - so a planned rollout sees exactly
/// the numbers a trained one would.
inline fn normalisedFeature(raw: f32, column: u32, f: u32) f32 {
    const mean: f32 = b_acts[params.norm_off + column];
    const spread: f32 = b_acts[params.norm_off + f + column];
    return (raw - mean) / spread;
}

/// THE WINDOWS' STARTING ACTIONS, gathered from the ring beside `lat_gather`: for each window's row, the action given
/// at the decision before its first record - what the action filter blends the window's first decision into and the
/// policy reads as applied before it - or rest, zero, when the window opens its segment (an episode's first record,
/// or one whose predecessor the ring no longer holds). One thread per (row, action number) over `rows x lat_actions`.
/// The rows' flags at `x_off` (1: the record before is the same segment's and held), written to `y_off` packed
/// `lat_actions` wide; the starts and the ring as `lat_gather` reads them.
pub fn lat_gather_start_actions(id: u32) void {
    const f: u32 = params.lat_features;
    const a: u32 = params.lat_actions;
    if (id >= params.rows * a) {
        return;
    }
    const row: u32 = id / a;
    const number: u32 = id % a;
    const written_at: u32 = params.y_off + row * a + number;
    const continues: bool = b_acts[params.x_off + row] != 0.0;
    if (!continues) {
        b_acts[written_at] = 0.0;
        return;
    }
    // The row's start: its world and the ring slot of its window's first record, two numbers per start.
    const start_at: u32 = params.starts_off + row * 2;
    const env: u32 = @trunc(b_acts[start_at]);
    const first_slot: u32 = @trunc(b_acts[start_at + 1]);
    // The record before the window's first, a ring step back (the ring wraps); records are slot-major, a world's
    // record after another's within a slot.
    const steps_back: u32 = params.lat_capacity - 1;
    const previous_slot: u32 = (first_slot + steps_back) % params.lat_capacity;
    const record_index: u32 = previous_slot * params.lat_envs + env;
    const record: u32 = params.ring_off + record_index * latRecordWidth(f, a);
    const action_at: u32 = record + latRecordAction(f) + number;
    b_acts[written_at] = b_acts[action_at];
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
        const goal: f32 = normalisedFeature(raw_goal, column, f);
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
        const value: f32 = normalisedFeature(b_acts[record + c], c, f);
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

/// A hashed UNIFORM number in [0, 1) for `row` under `seed`: the hash's top 24 bits, as a fraction - every value a
/// multiple of 2^-24, each equally likely. (The flow's training times.)
pub fn latUniform(seed: u32, row: u32) f32 {
    const bits: u32 = latHash(seed ^ latHash(row *% 0x9e3779b9)) >> 8;
    return float(bits) * (1.0 / 16777216.0);
}

/// A different seed for every step of the rollout, from one seed per training step.
pub fn latStepSeed(seed: u32, step: u32) u32 {
    return latHash(seed +% step *% 0x27d4eb2f);
}

/// A NUMBER's SHARE OF THE ACTION FILTER (`lat_act`, `lat_act_bwd`): an action holds the joints' offsets first, then
/// each limb's stiffness - its last `lat_stiffness_count` numbers - and each kind is smoothed at its own share,
/// `lat_filter` for the offsets, `lat_stiffness_filter` for the stiffnesses (as the device's `filter_actions` chooses).
fn latFilterShare(number: u32) f32 {
    const offset_count: u32 = params.count - params.lat_stiffness_count;
    return if (number < offset_count) params.lat_filter else params.lat_stiffness_filter;
}

/// The policy's action into its row: `lat_scale * raw` into the wide row's action columns, so the
/// world model's next step reads the action the policy just chose. `raw` is the policy's output,
/// contiguous at `x_off` (`count` per row); the action columns start at `y_off`, rows `stride` apart.
/// One thread per (row, action). With `lat_sigma` > 0 the action carries exploration noise,
/// `lat_scale * (raw + lat_sigma * latNoise(lat_seed, row, action))` - the policy learns corrections
/// that still work when it cannot act exactly as it meant to.
///
/// THE ACTION FILTER, with `lat_filter` below 1: the physics is given a blend of what the policy chose and what it was
/// given at the previous decision, so imagination writes the same blend -
///
///     action = lat_filter x lat_scale x (raw + noise)  +  (1 - lat_filter) x the previous action
///
/// the previous action read at `lat_prev_action`, rows `lat_prev_action_stride` apart: the previous step's action
/// columns in its wide row, or, at a window's first step, the action given before the window began. The world model
/// then reads the action the physics would be given. At 1 the action is written as it always was, exactly.
pub fn lat_act(id: u32) void {
    if (id >= params.rows * params.count) {
        return;
    }
    const r: u32 = id / params.count;
    const j: u32 = id % params.count;
    const raw_at: u32 = params.x_off + r * params.count + j;
    const raw: f32 = b_acts[raw_at];
    const noise: f32 = latNoise(params.lat_seed, r, j);
    const scaled_noise: f32 = params.lat_sigma * noise;
    const noisy: f32 = raw + scaled_noise;
    const chosen: f32 = params.lat_scale * noisy;
    const written_at: u32 = params.y_off + r * params.stride + j;
    const share: f32 = latFilterShare(j);
    if (share == 1.0) {
        b_acts[written_at] = chosen;
        return;
    }
    // The action filter: this number's share of the new action, the rest of the action applied before it.
    const previous_at: u32 = params.lat_prev_action + r * params.lat_prev_action_stride + j;
    const previous: f32 = b_acts[previous_at];
    const kept_share: f32 = 1.0 - share;
    const new_part: f32 = share * chosen;
    const kept_part: f32 = kept_share * previous;
    b_acts[written_at] = new_part + kept_part;
}

/// The action's gradient back to the policy's raw output: `d raw = lat_scale * d action +
/// lat_penalty * raw` (with the action filter, the action's carried gradient - below). The first term undoes
/// `lat_act`'s scale; the second is the action price's gradient (mean raw^2, times its weight). The noise was ADDED,
/// so it contributes nothing here.
/// `d action` is the world model's input gradient in its action columns (from `dx_off`, rows `stride`
/// apart - the input-gradient block's width, not the wide row's); `raw` the policy's output
/// (contiguous at `x_off`); `d raw` written contiguous at `dy_off`. One thread per (row, action).
pub fn lat_act_bwd(id: u32) void {
    if (id >= params.rows * params.count) {
        return;
    }
    const r: u32 = id / params.count;
    const j: u32 = id % params.count;
    const action_gradient_at: u32 = params.dx_off + r * params.stride + j;
    const d_action: f32 = b_dacts[action_gradient_at];
    const raw_at: u32 = params.x_off + r * params.count + j;
    const raw: f32 = b_acts[raw_at];
    // Smoothness: this step's action is pulled toward its neighbours in the window - the gradient of
    // w |a_k - a_(k-1)|^2 summed over the window, from the pair before and the pair after. A missing
    // neighbour's offset is this step's own, contributing exactly zero.
    const before_at: u32 = params.lat_prev + r * params.count + j;
    const after_at: u32 = params.lat_next + r * params.count + j;
    const before: f32 = b_acts[before_at];
    const after: f32 = b_acts[after_at];
    const pull_from_before: f32 = raw - before;
    const pull_from_after: f32 = raw - after;
    const smooth: f32 = params.lat_smooth * (pull_from_before + pull_from_after);
    // The action price's gradient: the raw output's own size, priced.
    const price_gradient: f32 = params.lat_penalty * raw;
    // What the next decision's policy, reading this action as the one applied before it, sends back to it.
    const reads_applied: bool = params.lat_applied_gradient != 0;
    const from_policy_at: u32 = params.lat_applied_gradient + r * params.count + j;
    const from_policy: f32 = if (reads_applied) b_dacts[from_policy_at] else 0.0;
    const raw_gradient_at: u32 = params.dy_off + r * params.count + j;
    // This number's share, the same at every step: a number at 1 never reads or leaves a carry.
    const share: f32 = latFilterShare(j);
    if (share == 1.0) {
        const action_gradient: f32 = d_action + from_policy;
        const through_action: f32 = params.lat_scale * action_gradient;
        b_dacts[raw_gradient_at] = through_action + price_gradient + smooth;
        return;
    }
    // THE ACTION FILTER (`lat_act`): a step's action feeds the next step's by (1 - lat_filter), so the action's whole
    // gradient is its own plus (1 - lat_filter) x the next step's whole gradient. The backward runs the steps last to
    // first, so the CARRY at `lat_carry` holds the next step's whole gradient when this step reads it (zero before the
    // window's last step), and leaves this step's for the one before. The raw output's share of the action is
    // lat_filter x lat_scale.
    const carry_at: u32 = params.lat_carry + r * params.count + j;
    const kept_share: f32 = 1.0 - share;
    const later_whole_gradient: f32 = b_dacts[carry_at];
    const carried: f32 = kept_share * later_whole_gradient;
    const own_and_carried: f32 = d_action + carried;
    const whole_gradient: f32 = own_and_carried + from_policy;
    b_dacts[carry_at] = whole_gradient;
    const raw_share: f32 = share * params.lat_scale;
    const through_action: f32 = raw_share * whole_gradient;
    b_dacts[raw_gradient_at] = through_action + price_gradient + smooth;
}

// -- SUPERTRACK'S FAILURE BARRIER --
//
// The task's failure rule is a cliff: one step the character is tracking, the next its episode is lost - and a
// pathwise gradient through the world model cannot see a cliff coming. The barrier puts a slope in front of it, in the
// loss the policy learns from: at every step of the rolled window, a SMOOTH HINGE (`zm.smoothHinge`) on two of the
// rule's own measures, read from the rolled features -
//
//     the head's height error   |h - h_ref|             margin 0.25 m     (the rule's head-height limit)
//     the tilt error            1 - cos(up, up_ref)     margin 1          (the up directions 90 degrees apart)
//
// with h the head body's world height and up the world's up seen from the root - both features of the state
// (`robot_track.local`), here un-normalised (feature x spread + mean). About nothing well inside a margin, it rises a
// few widths before the edge, and past it costs the distance - so the policy is pushed away from a fall before the
// rule fires. (The rule's third measure, the root's distance from the reference's, is no feature: the features are
// each root's own frame, so the drift between the two is not in the state the world model rolls.)

/// The failure barrier's two measures for one row: the head's height error (the character's height minus the
/// reference's, in metres), and the dot product and squared lengths of the character's and the reference's up
/// directions, from which their cosine - and so the tilt - and its gradient follow.
pub const BarrierMeasures = struct {
    height_error: f32,
    up_dot: f32,
    up_square: f32,
    reference_up_square: f32,
};

/// The barrier's measures for one row of normalised features - the state and its goal, the normaliser's means and
/// spreads - each read through a row accessor (`zm.requireRowAccess`): the kernels read the buffers (`ActsRow`), the
/// host reads slices. One definition of what the barrier measures, so the policy's loss and a planner's hazard (which
/// the host computes for a character it is acting for) cannot disagree about it. The head's height is in column
/// `head_column`, the up direction's three numbers from `up_column`.
pub fn barrierMeasuresOf(
    comptime Row: type,
    state: Row,
    goal: Row,
    means: Row,
    spreads: Row,
    head_column: u32,
    up_column: u32,
) BarrierMeasures {
    zm.requireRowAccess(f32, Row);
    const head_spread: f32 = spreads.at(head_column);
    const head_mean: f32 = means.at(head_column);
    const head_height: f32 = state.at(head_column) * head_spread + head_mean;
    const reference_head_height: f32 = goal.at(head_column) * head_spread + head_mean;
    var up_dot: f32 = 0;
    var up_square: f32 = 0;
    var reference_up_square: f32 = 0;
    var axis: u32 = 0;
    while (axis < 3) : (axis += 1) {
        const column: u32 = up_column + axis;
        const spread: f32 = spreads.at(column);
        const mean: f32 = means.at(column);
        const up: f32 = state.at(column) * spread + mean;
        const reference_up: f32 = goal.at(column) * spread + mean;
        up_dot += up * reference_up;
        up_square += up * up;
        reference_up_square += reference_up * reference_up;
    }
    const measures: BarrierMeasures = .{
        .height_error = head_height - reference_head_height,
        .up_dot = up_dot,
        .up_square = up_square,
        .reference_up_square = reference_up_square,
    };
    return measures;
}

/// The barrier's VALUE before its weight: the head's hinge on |height error| plus the tilt's hinge on 1 - cos(up,
/// up_ref) (`zm.smoothHinge`, each with its margin and width). Two up directions of no length count as aligned: no
/// tilt, no cost. Used by the tracking cost (times the barrier's weight) and by a planner's hazard (alone).
pub fn barrierHinges(
    measures: BarrierMeasures,
    head_margin: f32,
    head_width: f32,
    tilt_margin: f32,
    tilt_width: f32,
) f32 {
    const height_error_size: f32 = @abs(measures.height_error);
    const head_hinge: f32 = zm.smoothHinge(f32, height_error_size, head_margin, head_width);
    const lengths_product: f32 = sqrt(measures.up_square) * sqrt(measures.reference_up_square);
    const cosine: f32 = if (lengths_product < 1.0e-6) 1.0 else measures.up_dot / lengths_product;
    const tilt_hinge: f32 = zm.smoothHinge(f32, 1.0 - cosine, tilt_margin, tilt_width);
    return head_hinge + tilt_hinge;
}

/// `barrierMeasuresOf` for row `row_start` of the buffers: states at acts `states_at`, goals at `goals_at`, the
/// normaliser's means at `means` and spreads at `spreads`, the columns the uniform's.
inline fn barrierMeasures(
    row_start: u32,
    states_at: u32,
    goals_at: u32,
    means: u32,
    spreads: u32,
) BarrierMeasures {
    const state_row: ActsRow = .{ .start = states_at + row_start };
    const goal_row: ActsRow = .{ .start = goals_at + row_start };
    const means_row: ActsRow = .{ .start = means };
    const spreads_row: ActsRow = .{ .start = spreads };
    const head_column: u32 = params.barrier_head_column;
    const up_column: u32 = params.barrier_up_column;
    return barrierMeasuresOf(ActsRow, state_row, goal_row, means_row, spreads_row, head_column, up_column);
}

/// The failure barrier's gradient, ONE THREAD PER ROW, ADDED to a rolled step's state gradient (this section's head):
/// for `rows` rows of `out_dim` features -
///   reads  acts `y_off` the rolled features Z, `t_off` the goal G (the reference's features), both normalised,
///          [rows, features]; acts `u_off` the normaliser's means, then its spreads, `out_dim` each
///   adds   into dacts `dy_off` the gradient of  barrier_weight / rows x (the head's hinge + the tilt's hinge)
/// The columns, the weight, the margins and the widths are the `barrier_` fields.
pub fn lat_barrier_bwd(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const features: u32 = params.out_dim;
    const row_start: u32 = id * features;
    // The loss is the barrier's mean over the rows, times its weight: each row's share of the gradient.
    const weight_per_row: f32 = params.barrier_weight / float(params.rows);
    const means_at: u32 = params.u_off;
    const spreads_at: u32 = params.u_off + features;
    const measures: BarrierMeasures = barrierMeasures(row_start, params.y_off, params.t_off, means_at, spreads_at);
    // THE HEAD. The hinge is on the error's size |e|, e = h - h_ref, and h = z_head x spread + mean, so by the chain
    // rule
    //     d hinge / d z_head = hinge'(|e|) x sign(e) x spread
    // - the hinge's slope (`zm.smoothHingeSlope`), the sign of the error (a head too low and a head too high are both
    // pushed back toward the reference's height), and the normaliser's spread (a normalised feature moves the raw
    // height by `spread` metres per unit).
    const head_column: u32 = params.barrier_head_column;
    const head_spread: f32 = b_acts[spreads_at + head_column];
    const height_error: f32 = measures.height_error;
    const height_error_size: f32 = @abs(height_error);
    const height_error_sign: f32 = if (height_error < 0) -1.0 else 1.0;
    const head_margin: f32 = params.barrier_head_margin;
    const head_width: f32 = params.barrier_head_width;
    const head_hinge_slope: f32 = zm.smoothHingeSlope(f32, height_error_size, head_margin, head_width);
    const head_gradient: f32 = weight_per_row * head_hinge_slope * height_error_sign * head_spread;
    b_dacts[params.dy_off + row_start + head_column] += head_gradient;
    // THE TILT. The hinge is on 1 - cos, with cos = (u . r) / (|u| |r|) for the character's up u and the reference's
    // r. Differentiating the quotient in u (r is the goal, a constant here):
    //     d cos / d u_i = r_i / (|u| |r|) - (u . r) u_i / (|u|^3 |r|)  =  r_i / (|u| |r|) - cos x u_i / |u|^2
    // The first term turns u toward r; the second removes the part of that turn that would only lengthen u - the
    // cosine does not care how long u is. Then the minus sign of 1 - cos, the hinge's slope, and each axis's spread.
    const up_column: u32 = params.barrier_up_column;
    const up_square: f32 = measures.up_square;
    const up_length: f32 = sqrt(up_square);
    const reference_up_length: f32 = sqrt(measures.reference_up_square);
    const lengths_product: f32 = up_length * reference_up_length;
    // Two directions of no length have no angle between them, and nothing to turn.
    if (lengths_product < 1.0e-6) {
        return;
    }
    const cosine: f32 = measures.up_dot / lengths_product;
    const tilt_error: f32 = 1.0 - cosine;
    const tilt_margin: f32 = params.barrier_tilt_margin;
    const tilt_width: f32 = params.barrier_tilt_width;
    const tilt_hinge_slope: f32 = zm.smoothHingeSlope(f32, tilt_error, tilt_margin, tilt_width);
    var axis: u32 = 0;
    while (axis < 3) : (axis += 1) {
        const column: u32 = up_column + axis;
        const spread: f32 = b_acts[spreads_at + column];
        const mean: f32 = b_acts[means_at + column];
        const up_component: f32 = b_acts[params.y_off + row_start + column] * spread + mean;
        const reference_up_component: f32 = b_acts[params.t_off + row_start + column] * spread + mean;
        const cosine_slope: f32 = reference_up_component / lengths_product - cosine * up_component / up_square;
        const tilt_error_slope: f32 = -cosine_slope;
        const tilt_gradient: f32 = weight_per_row * tilt_hinge_slope * tilt_error_slope * spread;
        b_dacts[params.dy_off + row_start + column] += tilt_gradient;
    }
}

/// A per-step cost BOUNDED far from the reference: cap x tanh(cost / cap). Near the reference it is the cost itself -
/// tanh of a small number is that number, under 4% off below a third of the cap - and far from it, the cap: every step
/// of a fall costs the same, so a critic summing it into the future values a fallen state by how long it will take to
/// be near the reference again - its TIME TO RETURN - rather than by how far its bodies are from a pose they cannot
/// reach. And the critic's values stay inside its bins: at most the cap over (1 - discount). A cap of 0 leaves the
/// cost as it is.
pub fn boundedCost(cost: f32, cap: f32) f32 {
    if (cap <= 0) {
        return cost;
    }
    return cap * zm.tanh(cost / cap);
}

/// SuperTrack's per-step TRACKING COST of a state, ONE THREAD PER ROW - what its policy's loss charges a rolled step
/// (`mse_bwd` and `lat_barrier_bwd` are this cost's gradient, averaged over the rows), and what its critic sums into
/// the future:
///
///     cost = (1 / features) x sum over features of (z - g)^2
///          + barrier_weight x (the head's hinge + the tilt's hinge)
///
///   reads  acts `y_off` the states Z, `t_off` the goals G, both normalised, [rows, out_dim]; acts `u_off` the
///          normaliser's means, then its spreads
///   writes acts `x_off` each row's cost [rows]
/// The barrier's columns, weight, margins and widths are the `barrier_` fields; a weight of 0 leaves the distance.
pub fn lat_tracking_cost(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const features: u32 = params.out_dim;
    const row_start: u32 = id * features;
    // The distance from the goal: the mean, over the features, of the squared difference - in normalised units, as
    // the policy's loss measures it (`mse_bwd` is its gradient, averaged over the rows too).
    var squared_difference_sum: f32 = 0;
    var column: u32 = 0;
    while (column < features) : (column += 1) {
        const state_value: f32 = b_acts[params.y_off + row_start + column];
        const goal_value: f32 = b_acts[params.t_off + row_start + column];
        const difference: f32 = state_value - goal_value;
        squared_difference_sum += difference * difference;
    }
    const mean_square: f32 = squared_difference_sum / float(features);
    // The barrier's two hinges, on the measures `lat_barrier_bwd` takes the gradient of - none at weight 0.
    var barrier_cost: f32 = 0;
    if (params.barrier_weight != 0) {
        const means_at: u32 = params.u_off;
        const spreads_at: u32 = params.u_off + features;
        const measures: BarrierMeasures = barrierMeasures(row_start, params.y_off, params.t_off, means_at, spreads_at);
        const hinges: f32 = barrierHinges(
            measures,
            params.barrier_head_margin,
            params.barrier_head_width,
            params.barrier_tilt_margin,
            params.barrier_tilt_width,
        );
        barrier_cost = params.barrier_weight * hinges;
    }
    // Bounded far from the reference when the cost has a cap (`boundedCost`): the critic, the planner and FPO all read
    // this; the policy's pathwise loss has its own gradient and keeps SuperTrack's cost.
    const step_cost: f32 = mean_square + barrier_cost;
    b_acts[params.x_off + id] = boundedCost(step_cost, params.cost_cap);
}

// -- THE FLOW POLICY (`zimrrl.FlowPolicy`, `kit_mlp.KitFlow`) --
//
// An action made from noise by following a learned velocity v(c, x, t) along flow time t from 0 to 1. The velocity is
// an ordinary network on wide rows [condition | x | time features]; these kernels are what surrounds it: the time
// features, the Euler step from one point to the next, the straight path's points and velocities for training, and
// FlowDPG's gradient at the velocity.

/// The flow time as the velocity network reads it, ONE THREAD PER (row, sine-cosine pair): for pair p the frequency
/// f = 2^p and the pair [sin(pi f t), cos(pi f t)] - half a cycle over [0, 1] at the lowest frequency, so no two times
/// look alike. The time is `flow_time` for every row, or each row's own at acts `t_off` (`flow_time_per_row` 1). Into
/// acts at `y_off` + row x `stride` + `col` + 2p: the time columns of each wide row.
pub fn flow_time_features(id: u32) void {
    const pair_count: u32 = params.flow_frequencies;
    if (id >= params.rows * pair_count) {
        return;
    }
    const row: u32 = id / pair_count;
    const pair: u32 = id % pair_count;
    const row_time: f32 = if (params.flow_time_per_row == 1) b_acts[params.t_off + row] else params.flow_time;
    const frequency: f32 = float(@as(u32, 1) << @intCast(pair));
    const angle_rad: f32 = pi * frequency * row_time;
    const at: u32 = params.y_off + row * params.stride + params.col + 2 * pair;
    b_acts[at] = sinRad(angle_rad);
    b_acts[at + 1] = cosRad(angle_rad);
}

/// One EULER STEP of the flow, ONE THREAD PER (row, action dimension): x_(k+1) = x_k + `flow_step` x v(x_k). The point
/// x_k from acts at `x_off` + row x `stride` + `col` (a wide row's x columns), the velocity from acts at `z_off` +
/// row x `count` (the network's packed output, `count` the action's width); the next point into acts at `y_off` +
/// row x `destination_stride` + `destination_column` - the next wide row's x columns, or, at the last step,
/// wherever the action is read next.
pub fn flow_euler_step(id: u32) void {
    const action_width: u32 = params.count;
    if (id >= params.rows * action_width) {
        return;
    }
    const row: u32 = id / action_width;
    const dimension: u32 = id % action_width;
    const point: f32 = b_acts[params.x_off + row * params.stride + params.col + dimension];
    const velocity: f32 = b_acts[params.z_off + row * action_width + dimension];
    const destination: u32 = params.y_off + row * params.destination_stride + params.destination_column;
    b_acts[destination + dimension] = point + params.flow_step * velocity;
}

/// The STRAIGHT PATH for training, ONE THREAD PER (row, action dimension): each row's point x_t = (1 - t) x_0 + t a and
/// the path's velocity there, a - x_0. The action a from acts at `x_off`, the noise x_0 at `z_off` (both packed [rows,
/// `count`]), the row's time at acts `t_off` + row; the point into acts at `y_off` + row x `stride` + `col` (the wide
/// row's x columns), the path's velocity into acts at `u_off` (packed).
pub fn flow_path_points(id: u32) void {
    const action_width: u32 = params.count;
    if (id >= params.rows * action_width) {
        return;
    }
    const row: u32 = id / action_width;
    const packed_at: u32 = row * action_width + id % action_width;
    const action_value: f32 = b_acts[params.x_off + packed_at];
    const noise_value: f32 = b_acts[params.z_off + packed_at];
    const row_time: f32 = b_acts[params.t_off + row];
    const point: f32 = (1.0 - row_time) * noise_value + row_time * action_value;
    b_acts[params.y_off + row * params.stride + params.col + id % action_width] = point;
    b_acts[params.u_off + packed_at] = action_value - noise_value;
}

/// HASHED NORMAL NOISE into columns of strided rows, ONE THREAD PER (row, column): `lat_sigma` times the hashed
/// standard normal of (row, column) under the seed `lat_seed` (`latNoise`), into acts at `y_off` + row x `stride` +
/// `col` + column, `count` columns. Its uses:
///   - a flow's BASE NOISE at a rollout's step (`count` the action's width, the step's seed): the very numbers
///     `lat_act` adds to a Gaussian policy's raw action as its exploration - so a flow whose velocity is still zero,
///     its action its noise unchanged, acts exactly as a zero policy with that exploration does;
///   - an MPPI round's sampling noise (`count` the plan's horizon x action width, sigma 1, the round's seed).
pub fn hashed_noise(id: u32) void {
    const action_width: u32 = params.count;
    if (id >= params.rows * action_width) {
        return;
    }
    const row: u32 = id / action_width;
    const dimension: u32 = id % action_width;
    const noise_value: f32 = params.lat_sigma * latNoise(params.lat_seed, row, dimension);
    b_acts[params.y_off + row * params.stride + params.col + dimension] = noise_value;
}

/// A run of columns copied from one strided row layout to another, ONE THREAD PER VALUE: `count` columns of each of
/// `rows` rows, read at acts `x_off` + row x `stride` + `col` + column, written at acts `y_off` + row x
/// `destination_stride` + `destination_column` + column. (A flow block's condition columns, filled from a
/// rollout's wide row: the policy's [goal | state].)
pub fn copy_columns(id: u32) void {
    const column_count: u32 = params.count;
    if (id >= params.rows * column_count) {
        return;
    }
    const row: u32 = id / column_count;
    const column: u32 = id % column_count;
    const source: f32 = b_acts[params.x_off + row * params.stride + params.col + column];
    const destination_row_start: u32 = params.y_off + row * params.destination_stride;
    b_acts[destination_row_start + params.destination_column + column] = source;
}

/// `copy_columns` from the GRADIENT buffer: the same run of columns read from dacts, written into acts - a gradient
/// a backward left (an action's, for one) handed on as data to a step that reads it from acts (FlowDPG's cost
/// gradient). Source at dacts `x_off` + row x `stride` + `col`, destination at acts `y_off` + row x
/// `destination_stride` + `destination_column`.
pub fn copy_columns_from_gradients(id: u32) void {
    const column_count: u32 = params.count;
    if (id >= params.rows * column_count) {
        return;
    }
    const row: u32 = id / column_count;
    const column: u32 = id % column_count;
    const source: f32 = b_dacts[params.x_off + row * params.stride + params.col + column];
    const destination_row_start: u32 = params.y_off + row * params.destination_stride;
    b_acts[destination_row_start + params.destination_column + column] = source;
}

/// HASHED UNIFORM NUMBERS, ONE THREAD PER ROW: each row's number drawn uniformly from [0, 1) (`latUniform` under
/// `lat_seed`), into acts at `y_off` + row. Its uses: a flow's training times (where on its path, between its noise
/// and its action, each training row's velocity is asked for), and an MPPI search's draws for choosing an elite.
pub fn hashed_uniforms(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    b_acts[params.y_off + id] = latUniform(params.lat_seed, id);
}

/// FLOWDPG'S GRADIENT at the velocity, ONE THREAD PER ROW. The target velocity (`zimrrl.FlowPolicy.flowDpgTargets`)
///
///     u* = t u + (1 - t) v^ - alpha (max(|v^|, floor) / |g|) g          u = a - x_0, the straight path's velocity
///
/// with v^ the velocity itself, held fixed - so the loss mean |v - u*|^2 + lambda mean |v - u|^2 has the gradient
///
///     d L / d v = (2 / n) [ (v - u*) + lambda (v - u) ]       n = rows x the action's width
///
/// The velocity from acts at `x_off`, the path's velocity at `u_off`, the cost's gradient g at `v_off` (all packed
/// [rows, `count`]), the time at `t_off` + row; alpha `flow_step_share`, lambda `flow_anchor`, the floor
/// `flow_step_floor` (`zimrrl.FlowPolicy`'s: a flow at rest has no motion of its own to scale its step by); the
/// gradient written fresh into dacts at `dy_off` (packed). A row whose cost gradient is zero takes no step.
pub fn flow_dpg_bwd(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const action_width: u32 = params.count;
    const row_start: u32 = id * action_width;
    var velocity_square_sum: f32 = 0;
    var gradient_square_sum: f32 = 0;
    var dimension: u32 = 0;
    while (dimension < action_width) : (dimension += 1) {
        const velocity: f32 = b_acts[params.x_off + row_start + dimension];
        const cost_gradient: f32 = b_acts[params.v_off + row_start + dimension];
        velocity_square_sum += velocity * velocity;
        gradient_square_sum += cost_gradient * cost_gradient;
    }
    const gradient_length: f32 = sqrt(gradient_square_sum);
    const velocity_length: f32 = sqrt(velocity_square_sum);
    const has_gradient: bool = gradient_length > 0;
    const step_length: f32 = @max(velocity_length, params.flow_step_floor);
    const step_per_gradient: f32 = if (has_gradient) params.flow_step_share * step_length / gradient_length else 0;
    const row_time: f32 = b_acts[params.t_off + id];
    const value_count: f32 = float(params.rows * action_width);
    const gradient_scale: f32 = 2.0 / value_count;
    dimension = 0;
    while (dimension < action_width) : (dimension += 1) {
        const at: u32 = row_start + dimension;
        const velocity: f32 = b_acts[params.x_off + at];
        const path_velocity: f32 = b_acts[params.u_off + at];
        const cost_gradient: f32 = b_acts[params.v_off + at];
        const toward_estimate: f32 = row_time * path_velocity + (1.0 - row_time) * velocity;
        const target_velocity: f32 = toward_estimate - step_per_gradient * cost_gradient;
        const toward_target: f32 = velocity - target_velocity;
        const toward_path: f32 = velocity - path_velocity;
        b_dacts[params.dy_off + at] = gradient_scale * (toward_target + params.flow_anchor * toward_path);
    }
}

/// THE TRACKING PLANNER'S GATHER, ONE THREAD PER NUMBER WRITTEN over `rows x (lat_steps + 1) x width`: a planner
/// kit's rows - [state][candidate], `plan_candidates` rows per state - filled from each state's start and the
/// reference table, in `lat_gather`'s conventions, so a planned rollout sees what a training window would:
///   * GOAL columns (the first `lat_lead`), step k >= 1: the reference where step k - 1 is going - table row
///     (start + k), normalised - into wide row k - 1's goal columns and goal block G_k: the flow's condition at step
///     k - 1, and the cost's goal for the state that step produces
///   * STATE columns, step 0: the state's start, already normalised
///   * REFERENCE columns, step k < `lat_steps`: table row (start + k)'s encoded targets - a table row is [goal |
///     encoded targets] and the world model's slice [state | reference | action], so the reference sits at the same
///     offset in both
///   * ACTION columns: left alone - the search's and the flow's to write
/// The table rows run on from the state's start row and hold at its clip's last row, as the training records do.
/// Each state's inputs at acts `starts_off` + state x (features + 2): its normalised start features, then its start
/// row and its clip's last row (floats holding integers, exact below 2^24). The table at `table_off`, the normaliser
/// at `norm_off` (means, then spreads), the wide rows at `blocks_off`, the goal blocks at `goals_off`.
pub fn plan_gather(id: u32) void {
    const f: u32 = params.lat_features;
    const r: u32 = params.lat_references;
    const lead: u32 = params.lat_lead;
    const steps: u32 = params.lat_steps;
    const width: u32 = lead + f + r + params.lat_actions;
    if (id >= params.rows * (steps + 1) * width) {
        return;
    }
    const column: u32 = id % width;
    const step: u32 = (id / width) % (steps + 1);
    const row: u32 = id / (width * (steps + 1));
    const state: u32 = row / params.plan_candidates;
    const inputs_at: u32 = params.starts_off + state * (f + 2);
    const start_row: u32 = @trunc(b_acts[inputs_at + f]);
    const last_row: u32 = @trunc(b_acts[inputs_at + f + 1]);
    const table_row: u32 = @min(start_row + step, last_row);
    const table_row_at: u32 = params.table_off + table_row * latTableWidth(f, r);
    if (column < lead) {
        if (step == 0) {
            return;
        }
        const raw_goal: f32 = b_acts[table_row_at + column];
        const goal: f32 = normalisedFeature(raw_goal, column, f);
        b_acts[params.blocks_off + ((step - 1) * params.rows + row) * width + column] = goal;
        b_acts[params.goals_off + ((step - 1) * params.rows + row) * f + column] = goal;
        return;
    }
    // The world model's slice: `c` counts from its first column.
    const c: u32 = column - lead;
    const wide_row_at: u32 = params.blocks_off + (step * params.rows + row) * width;
    if (c < f) {
        if (step == 0) {
            b_acts[wide_row_at + column] = b_acts[inputs_at + c];
        }
        return;
    }
    const is_reference: bool = c < f + r;
    if (is_reference and step < steps) {
        b_acts[wide_row_at + column] = b_acts[table_row_at + c];
    }
}

/// EACH EXAMPLE'S FLOW MATCHING LOSS, AVERAGED OVER ITS DRAWS, ONE THREAD PER EXAMPLE - FPO's stand-in for an action's
/// negative log-likelihood (`zimrrl.FlowPolicy.drawLosses`, whose arithmetic this is). A flow trainer's rows hold
/// `count` consecutive draws per example - example b's rows b x count .. b x count + count - 1, each with the example's
/// condition and action and a time and noise of its own - and after the training forward each row's velocity sits
/// beside the path's velocity it should match. Example b's loss is
///
///     L(b) = (1/count) sum over its draws of | v - (a - x_0) |^2          summed over the `out_dim` action numbers
///
///   reads  acts `y_off` the velocities [rows x count][out_dim], acts `t_off` the path's velocities, alike
///   writes acts `x_off` the losses [rows] (`rows` the examples)
pub fn flow_draw_losses(id: u32) void {
    if (id >= params.rows) {
        return;
    }
    const draws: u32 = params.count;
    const action_width: u32 = params.out_dim;
    var total: f32 = 0;
    var draw: u32 = 0;
    while (draw < draws) : (draw += 1) {
        const row_start: u32 = (id * draws + draw) * action_width;
        var action: u32 = 0;
        while (action < action_width) : (action += 1) {
            const velocity: f32 = b_acts[params.y_off + row_start + action];
            const path_velocity: f32 = b_acts[params.t_off + row_start + action];
            const difference: f32 = velocity - path_velocity;
            total += difference * difference;
        }
    }
    b_acts[params.x_off + id] = total / float(draws);
}

/// TEACHER 3'S ADVANTAGE, ONE THREAD PER EXAMPLE: how a real step turned out against what the critic expected,
///
///     A = -c - gamma C(next) + C(this)          C the mean of the critic's `count` heads
///
/// positive when the step did better than expected - its cost and the cost-to-go it left cheaper than the cost-to-go
/// the critic gave the state it started from - and negative when it did worse (`robot_latent_kit.FlowActor.Fpo`).
///   reads  acts `x_off` the steps' costs [rows]; acts `v_off` the heads' values [head][2 rows]: in each head's block
///          the first `rows` at each step's start (C(this)), the next `rows` where it led (C(next))
///   writes acts `y_off` the advantages [rows]
pub fn fpo_advantages(id: u32) void {
    const rows: u32 = params.rows;
    if (id >= rows) {
        return;
    }
    const heads: u32 = params.count;
    var this_sum: f32 = 0;
    var next_sum: f32 = 0;
    var head: u32 = 0;
    while (head < heads) : (head += 1) {
        const head_block_at: u32 = params.v_off + head * 2 * rows;
        this_sum += b_acts[head_block_at + id];
        next_sum += b_acts[head_block_at + rows + id];
    }
    const head_count: f32 = @floatFromInt(heads);
    const this_value: f32 = this_sum / head_count;
    const next_value: f32 = next_sum / head_count;
    const cost: f32 = b_acts[params.x_off + id];
    b_acts[params.y_off + id] = -cost - params.gamma * next_value + this_value;
}

// -- STATISTICS FOR THE LOG (`robot_latent_kit.DeviceStats`) --
//
// Each writes one or two numbers into the parameter buffer at `y_off`: the learner's stats block, inside the range it
// reads back every frame, so the numbers reach the host with the weights at no transfer of their own. One thread
// each: a statistic is taken once per update, over a few thousand numbers at most.

/// ONE NUMBER COPIED: the activation at acts `x_off` into params `stat_off` - a value another kernel already worked
/// out, such as a clipped optimiser's gradient length, kept for the log.
pub fn stat_copy(id: u32) void {
    if (id != 0) {
        return;
    }
    b_params[params.stat_off] = b_acts[params.x_off];
}

/// THE ROOT MEAN SQUARE of `rows` gradients at dacts `x_off` - how large a gradient is, whatever its sign - into
/// params `stat_off`.
pub fn stat_root_mean_square(id: u32) void {
    if (id != 0) {
        return;
    }
    var squares: f32 = 0;
    var index: u32 = 0;
    while (index < params.rows) : (index += 1) {
        const value: f32 = b_dacts[params.x_off + index];
        squares += value * value;
    }
    const count: f32 = @floatFromInt(@max(params.rows, 1));
    b_params[params.stat_off] = @sqrt(squares / count);
}

/// THE MEAN SQUARED DIFFERENCE of `rows` activations at acts `x_off` and at acts `t_off` - a regression's loss per
/// number, as flow matching's is between the velocity given and the path's - into params `stat_off`.
pub fn stat_mean_square_difference(id: u32) void {
    if (id != 0) {
        return;
    }
    b_params[params.stat_off] = meanSquaredDifference(params.x_off, params.t_off, params.rows);
}

/// THE MEAN AND THE SAMPLE DEVIATION of `rows` activations at acts `x_off` - the deviation divided by rows - 1, as
/// `zimrrl.normalizeAdvantages` takes it; 0 for fewer than two - into params `stat_off` and `stat_off + 1`.
pub fn stat_mean_and_deviation(id: u32) void {
    if (id != 0) {
        return;
    }
    const mean: f32 = meanOf(params.x_off, params.rows);
    b_params[params.stat_off] = mean;
    b_params[params.stat_off + 1] = sampleDeviationOf(params.x_off, params.rows, mean);
}

/// THE SKIP HEAD'S INPUTS (`SkipModel`), ONE THREAD PER VALUE: for each of `count` jumps of `col` steps through a
/// window of the latent kit's rollout, and each of its `rows` rows, the row the head reads -
///
///     [ the world model's second hidden layer at the jump's first step | the next col - 1 steps' references and
///       actions ]                                                                                   `out_dim` wide
///
/// The hidden layer (`in_dim` wide) is the world model's own encoding of the jump's start state, its reference and its
/// first action, from acts `t_off`, [step][row][hidden] - the start state block 0's recorded one for the first jump,
/// the rollout's own prediction for a later jump. Each further step's reference and action are its block's, read from
/// acts `x_off`: block 0's reference columns (each block's action after its reference), `rows` rows `stride` apart, a
/// block `rows` x `stride` after the one before. Into acts `y_off`, [jump][row][column].
pub fn lat_skip_gather(id: u32) void {
    const input_width: u32 = params.out_dim;
    const value_count: u32 = params.count * params.rows * input_width;
    if (id >= value_count) {
        return;
    }
    const hidden: u32 = params.in_dim;
    const span: u32 = params.col;
    const column: u32 = id % input_width;
    const row: u32 = (id / input_width) % params.rows;
    const jump: u32 = id / (input_width * params.rows);
    const start_step: u32 = jump * span;
    var value: f32 = 0;
    if (column < hidden) {
        // The world model's encoding of the jump's first step.
        value = b_acts[params.t_off + (start_step * params.rows + row) * hidden + column];
    } else {
        // Step `start_step + 1 + step_after_first`'s reference and action, from its block.
        const step_columns: u32 = (input_width - hidden) / (span - 1);
        const step_column: u32 = column - hidden;
        const step_after_first: u32 = step_column / step_columns;
        const within_step: u32 = step_column % step_columns;
        const block: u32 = start_step + 1 + step_after_first;
        const block_floats: u32 = params.rows * params.stride;
        value = b_acts[params.x_off + block * block_floats + row * params.stride + within_step];
    }
    b_acts[params.y_off + id] = value;
}

/// THE SKIP HEAD'S TARGETS (`SkipModel`), ONE THREAD PER VALUE: each jump's change over its `col` steps, from the state
/// it starts at to the RECORDED state after its last step - for `count` jumps of `rows` rows of `in_dim` features. The
/// start state is its block's state columns (acts `x_off`, block 0's, rows `stride` apart, a block `rows` x `stride`
/// after the one before): the recorded state for the first jump, the rollout's own prediction for a later one - so a
/// later jump learns to land on what was recorded from where the world model had drifted to. The recorded states after
/// steps 1 .. window at acts `t_off`, [step][row][feature]. Into acts `y_off`, [jump][row][feature].
pub fn lat_skip_targets(id: u32) void {
    const features: u32 = params.in_dim;
    const value_count: u32 = params.count * params.rows * features;
    if (id >= value_count) {
        return;
    }
    const span: u32 = params.col;
    const feature: u32 = id % features;
    const row: u32 = (id / features) % params.rows;
    const jump: u32 = id / (features * params.rows);
    const start_step: u32 = jump * span;
    const end_step: u32 = start_step + span;
    const end_index: u32 = ((end_step - 1) * params.rows + row) * features + feature;
    const end_state: f32 = b_acts[params.t_off + end_index];
    const block_floats: u32 = params.rows * params.stride;
    const start_state: f32 = b_acts[params.x_off + start_step * block_floats + row * params.stride + feature];
    b_acts[params.y_off + id] = end_state - start_state;
}

/// THE PLANNER'S GAIN over its proposals, ONE THREAD: for `rows` states of `plan_candidates` candidates, the first
/// `plan_policy_plans` of each the actor's own proposals (the flow's plans) and the rest drawn by the search - the
/// scores at acts `x_off` [states x candidates], each state's chosen candidate at acts `e_off` + state (a number held
/// in a float) - into params `stat_off` the chosen plan's score less the best proposal's, averaged over the states,
/// and into `stat_off + 1` the share of states whose chosen plan is one the search drew. With no proposals the gain is
/// 0 and every choice the search's. Near zero gain and share: the search finds nothing the actor does not already
/// propose.
pub fn plan_gain_stats(id: u32) void {
    if (id != 0) {
        return;
    }
    const states: u32 = params.rows;
    const candidates: u32 = params.plan_candidates;
    const proposals: u32 = params.plan_policy_plans;
    var gain_sum: f32 = 0;
    var searched_choices: f32 = 0;
    var state: u32 = 0;
    while (state < states) : (state += 1) {
        const scores_at: u32 = params.x_off + state * candidates;
        const chosen: u32 = @trunc(b_acts[params.e_off + state]);
        if (chosen >= proposals) {
            searched_choices += 1;
        }
        if (proposals == 0) {
            continue;
        }
        var best_proposal: f32 = b_acts[scores_at];
        var candidate: u32 = 1;
        while (candidate < proposals) : (candidate += 1) {
            best_proposal = @max(best_proposal, b_acts[scores_at + candidate]);
        }
        gain_sum += b_acts[scores_at + chosen] - best_proposal;
    }
    const state_count: f32 = float(@max(states, 1));
    b_params[params.stat_off] = gain_sum / state_count;
    b_params[params.stat_off + 1] = searched_choices / state_count;
}

/// THE CRITIC'S HEADS on a batch: `count` heads' decoded values at acts `x_off`, [head][row] for `rows` rows, and the
/// rows' targets at acts `t_off` - into params `stat_off` the heads' mean value, `stat_off + 1` their mean SPREAD (each
/// row's standard deviation across the heads, averaged over the rows: the disagreement a pessimistic critic adds to its
/// value), and `stat_off + 2` the heads' error against the targets as a root mean square, in the cost's own units.
pub fn critic_value_stats(id: u32) void {
    if (id != 0) {
        return;
    }
    const rows: u32 = params.rows;
    const heads: u32 = params.count;
    var value_sum: f32 = 0;
    var spread_sum: f32 = 0;
    var error_squares: f32 = 0;
    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        var row_sum: f32 = 0;
        var head: u32 = 0;
        while (head < heads) : (head += 1) {
            row_sum += b_acts[params.x_off + head * rows + row];
        }
        const row_mean: f32 = row_sum / float(@max(heads, 1));
        var row_squares: f32 = 0;
        const target: f32 = b_acts[params.t_off + row];
        head = 0;
        while (head < heads) : (head += 1) {
            const value: f32 = b_acts[params.x_off + head * rows + row];
            row_squares += (value - row_mean) * (value - row_mean);
            error_squares += (value - target) * (value - target);
        }
        value_sum += row_sum;
        spread_sum += @sqrt(row_squares / float(@max(heads, 1)));
    }
    const value_count: f32 = float(@max(rows * heads, 1));
    b_params[params.stat_off] = value_sum / value_count;
    b_params[params.stat_off + 1] = spread_sum / float(@max(rows, 1));
    b_params[params.stat_off + 2] = @sqrt(error_squares / value_count);
}

/// THE FAILURE BARRIER'S HINGES over a rollout: `count` steps of `rows` rows, each step's rolled states at acts `y_off`
/// and goals at `t_off` advancing one block (`rows` x `out_dim`) a step, the normaliser at `u_off` - each row's head
/// and tilt hinges as the tracking cost charges them (`barrierMeasures`, `barrierHinges`, the `barrier_` fields), their
/// mean into params `stat_off`, unweighted: 0 while every imagined state keeps well inside the failure rule, larger the
/// more and the deeper the rollouts press against it.
pub fn stat_barrier(id: u32) void {
    if (id != 0) {
        return;
    }
    const rows: u32 = params.rows;
    const features: u32 = params.out_dim;
    const block_floats: u32 = rows * features;
    const means_at: u32 = params.u_off;
    const spreads_at: u32 = params.u_off + features;
    var hinge_sum: f32 = 0;
    var step: u32 = 0;
    while (step < params.count) : (step += 1) {
        const states_at: u32 = params.y_off + step * block_floats;
        const goals_at: u32 = params.t_off + step * block_floats;
        var row: u32 = 0;
        while (row < rows) : (row += 1) {
            const row_start: u32 = row * features;
            const measures: BarrierMeasures = barrierMeasures(row_start, states_at, goals_at, means_at, spreads_at);
            hinge_sum += barrierHinges(
                measures,
                params.barrier_head_margin,
                params.barrier_head_width,
                params.barrier_tilt_margin,
                params.barrier_tilt_width,
            );
        }
    }
    b_params[params.stat_off] = hinge_sum / float(@max(rows * params.count, 1));
}

/// FPO'S RATIOS over `rows` examples - each exp(L_old - L_new), from the old losses at acts `x_off` and the new at
/// `u_off` - their mean into params `stat_off`, and into `stat_off + 1` the share of examples the clip holds: those
/// whose clipped term is the smaller, decided with the advantages at `v_off` and the `clip` exactly as
/// `fpo_velocity_gradient` decides it. A mean far from 1, or a large share held, says the round's updates have moved
/// the flow far from where its examples were taken.
pub fn fpo_ratio_stats(id: u32) void {
    if (id != 0) {
        return;
    }
    const rows: u32 = params.rows;
    var ratio_sum: f32 = 0;
    var held: f32 = 0;
    var example: u32 = 0;
    while (example < rows) : (example += 1) {
        const advantage: f32 = b_acts[params.v_off + example];
        const ratio: f32 = @exp(b_acts[params.x_off + example] - b_acts[params.u_off + example]);
        ratio_sum += ratio;
        held += if (isClipHolding(ratio, advantage, params.clip)) 1 else 0;
    }
    const count: f32 = float(@max(rows, 1));
    b_params[params.stat_off] = ratio_sum / count;
    b_params[params.stat_off + 1] = held / count;
}

/// A BATCH'S ADVANTAGES NORMALISED, ONE THREAD FOR THE WHOLE BATCH - zero mean, unit deviation, in
/// `zimrrl.normalizeAdvantages`' arithmetic and order: the mean, the SAMPLE deviation (divided by rows - 1), and each
/// advantage minus the mean over the deviation plus `advantage_epsilon` - so a batch of equal advantages, legitimate if
/// uninformative, gives zeros rather than a division by zero. A batch is tens of numbers: one thread keeps the sums in
/// zimrrl's order.
///   reads  acts `x_off` the advantages [rows], `rows` at least 2
///   writes acts `y_off` the normalised advantages [rows]
pub fn fpo_normalize_advantages(id: u32) void {
    if (id != 0) {
        return;
    }
    const rows: u32 = params.rows;
    const mean: f32 = meanOf(params.x_off, rows);
    const divisor: f32 = sampleDeviationOf(params.x_off, rows, mean) + params.advantage_epsilon;
    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        b_acts[params.y_off + row] = (b_acts[params.x_off + row] - mean) / divisor;
    }
}

/// FPO'S GRADIENT ON EACH DRAW'S VELOCITY, ONE THREAD PER (row, action number). FPO's loss over a batch of `rows`
/// examples, each with `count` draws (`zimrrl.fpoLoss`, which this differentiates):
///
///     loss = -(1/B) sum over examples of min(r A, clamp(r, 1 - clip, 1 + clip) A)      r = exp(L_old - L_new)
///     L_new(b) = (1/N) sum over its draws of | v - u |^2        (`flow_draw_losses`)
///
/// so, by the chain rule through r and L_new, on draw row i of example b:
///
///     d loss / d v = weight x A x r x 2 / (B N) x (v - u)       where the unclipped term is the smaller
///                  = 0                                          where the clipped one is
///
/// The term the minimum picks is decided exactly as `zimrrl.ppoClipSample` decides it - the unclipped term, ratio x A,
/// against the clipped one - so an update that would move the ratio past the clip in the improving direction earns
/// nothing more, while one moving the wrong way still pays in full. A positive advantage pulls v toward u: the new
/// loss falls, and the flow makes that correction more likely.
///   reads  acts `y_off` the velocities and acts `t_off` the path's velocities, [rows x count][`out_dim`]; acts
///          `x_off` the old losses, `u_off` the new losses, `v_off` the advantages, [rows] each
///   writes dacts `dy_off` the velocities' gradient, [rows x count][`out_dim`] (`loss_weight` the teacher's weight,
///          `clip` PPO's clip range, as for PPO's own heads)
pub fn fpo_velocity_gradient(id: u32) void {
    const examples: u32 = params.rows;
    const draws: u32 = params.count;
    const action_width: u32 = params.out_dim;
    if (id >= examples * draws * action_width) {
        return;
    }
    const draw_row: u32 = id / action_width;
    const example: u32 = draw_row / draws;
    const advantage: f32 = b_acts[params.v_off + example];
    const ratio: f32 = @exp(b_acts[params.x_off + example] - b_acts[params.u_off + example]);
    if (isClipHolding(ratio, advantage, params.clip)) {
        b_dacts[params.dy_off + id] = 0;
        return;
    }
    const scale_rows: f32 = @floatFromInt(examples * draws);
    const coefficient: f32 = params.loss_weight * advantage * ratio * 2 / scale_rows;
    const difference: f32 = b_acts[params.y_off + id] - b_acts[params.t_off + id];
    b_dacts[params.dy_off + id] = coefficient * difference;
}

// -- A FLOW'S CORRECTION IN SYNERGIES (`robot_latent_kit.FlowActor`) --
//
// The flow does not replace the policy; it corrects it, in a few synergies (`zimrrl.ActionSynergies`): the policy's
// raw action plus B^T c, with c the flow's k coefficients and B the synergies, [synergy][action], in the parameter
// buffer. Forward, the correction is decoded and added; backward, the raw action's gradient is projected onto the
// synergies - the chain rule through raw + B^T c, which gives d/dc = B d/draw.

/// A flow's correction DECODED AND ADDED, ONE THREAD PER (row, action): raw[row][a] += sum over j of c[row][j] B[j][a].
///   reads  acts `x_off` the coefficients [rows][`count`], params `w_off` the synergies [`count`][`out_dim`]
///   adds into acts `y_off` the raw actions [rows][`out_dim`]
pub fn synergy_decode_add(id: u32) void {
    const action_width: u32 = params.out_dim;
    if (id >= params.rows * action_width) {
        return;
    }
    const row: u32 = id / action_width;
    const action: u32 = id % action_width;
    const synergy_count: u32 = params.count;
    var correction: f32 = 0;
    var synergy: u32 = 0;
    while (synergy < synergy_count) : (synergy += 1) {
        const coefficient: f32 = b_acts[params.x_off + row * synergy_count + synergy];
        correction += coefficient * b_params[params.w_off + synergy * action_width + action];
    }
    b_acts[params.y_off + id] += correction;
}

/// A raw action's gradient PROJECTED ONTO THE SYNERGIES, ONE THREAD PER (row, synergy):
/// g_c[row][j] = sum over a of B[j][a] g[row][a] - the gradient with respect to the flow's coefficients.
///   reads  dacts `x_off` the raw actions' gradient [rows][`out_dim`];
///          params `w_off` the synergies [`count`][`out_dim`]
///   writes acts `y_off` [rows][`count`] - in acts, where the flow's training reads its cost gradients
pub fn synergy_project_gradient(id: u32) void {
    const synergy_count: u32 = params.count;
    if (id >= params.rows * synergy_count) {
        return;
    }
    const row: u32 = id / synergy_count;
    const synergy: u32 = id % synergy_count;
    const action_width: u32 = params.out_dim;
    var projected: f32 = 0;
    var action: u32 = 0;
    while (action < action_width) : (action += 1) {
        const action_gradient: f32 = b_dacts[params.x_off + row * action_width + action];
        projected += b_params[params.w_off + synergy * action_width + action] * action_gradient;
    }
    b_acts[params.y_off + id] = projected;
}

/// THE TRACKING PLANNER'S MAILBOX, ONE THREAD PER (state, step, action dimension): each state's chosen plan - the
/// whole plan of the candidate its decision chose (`mppi_choose`'s choice at acts `e_off`), not the search's mean,
/// which averages elites and so, between two ways back, would take neither - copied out of the candidates' actions
/// (acts `x_off`, [step][states x `plan_candidates`][action]) into the PARAMETER buffer at `y_off` + 1, [state][step]
/// [action]. The parameter buffer is the one the host reads back every frame, so a plan reaches the acting loop with
/// it, a few frames late on a GPU. The first float at `y_off` holds the decision's step, `plan_decision_step`, as its
/// exact bits - so the host knows which decision a readback holds, and from which of its steps to act.
pub fn plan_mailbox(id: u32) void {
    const action_width: u32 = params.out_dim;
    const horizon: u32 = params.plan_horizon;
    if (id >= params.rows * horizon * action_width) {
        return;
    }
    const state: u32 = id / (horizon * action_width);
    const step: u32 = (id / action_width) % horizon;
    const dimension: u32 = id % action_width;
    const candidate_rows: u32 = params.rows * params.plan_candidates;
    const chosen_candidate: u32 = @trunc(b_acts[params.e_off + state]);
    const chosen_row: u32 = state * params.plan_candidates + chosen_candidate;
    const action_at: u32 = params.x_off + (step * candidate_rows + chosen_row) * action_width + dimension;
    b_params[params.y_off + 1 + id] = b_acts[action_at];
    if (id == 0) {
        b_params[params.y_off] = @bitCast(params.plan_decision_step);
    }
}

// -- SUPERTRACK, FUSED: ONE THREAD PER BATCH ROW RUNS THE WHOLE WINDOW --
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

/// The kit's kernels by their entry names, in order: the one list of them, in `zn_mlp_kernels.zig` - a file of its
/// own so the build script can read it too.
pub const kernels = @import("zn_mlp_kernels.zig").kernels;

// *** THE EXPORT HOOK. Without it the SPIR-V compile of this file exports NOTHING: a 68-byte
// module, an empty compute.wgsl for every entry, and `initGpu` failing on
// `UniformBindingNotFound` - while the CPU twin, which calls the functions directly, passes every
// test. zn_train has the same block; the kit was written without it.
comptime {
    for (kernels) |name| {
        k.installKernelLean(@This(), name);
    }
}
