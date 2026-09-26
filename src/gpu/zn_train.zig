//! zn_train - every kernel a two-layer network needs to train, sharing ONE buffer set.
//!
//! -- *** WHY ONE FILE AND ONE BUFFER SET --
//!
//! The sweep's kernels each own their buffers, which is right for comparing operations one at a
//! time. A training step is different: the output of `matmul` is the input of `add`, whose
//! output is the input of `tanh`, and so on through the backward pass. With separate buffer sets
//! every arrow would be a readback and a re-upload. With one set, the whole step is a sequence
//! of dispatches over data that never leaves the device, and only the loss comes back.
//!
//! ** EACH KERNEL IS ONE STAGE, NOT ONE OPERATION. `fwd_hidden` does the matmul, the bias add
//! and the tanh in a single thread per output element, because splitting them would triple the
//! dispatches for no benefit - nothing between them needs a barrier. The backward kernels are
//! split where the thread geometry changes: `bwd_w2` has one thread per weight, `bwd_h` one per
//! hidden activation.
//!
//! * Sizes are fixed at `max` and the live extents ride in the uniform, the same arrangement as
//! the sweep's files. The CPU twin of every kernel here is valid - there are no barriers.

const k = @import("kompute");
const zm = @import("zm");
const float = zm.float;

pub const config = k.Config{ .max = 4096, .workgroup = 64 };

/// The live geometry: `samples` rows of `inputs` in, `hidden` units, `outputs` out.
pub const Params = extern struct {
    samples: u32,
    inputs: u32,
    hidden: u32,
    outputs: u32,
    rate: f32,
    /// Which training step this dispatch belongs to. `loss_value` writes it beside the loss, so
    /// the host attributes a readback to the right step regardless of how many frames the queue
    /// is behind - see the note on `loss_value`.
    step: u32 = 0,
    _p1: u32 = 0,
    _p2: u32 = 0,
};

/// -- *** SIX BUFFERS, NOT FIFTEEN --
///
/// The first version gave every tensor its own buffer and the host refused it: WebGPU guarantees
/// EIGHT storage buffers per shader stage, and bindings past the eighth silently do not bind -
/// writes to them are discarded with no error, and the kernel appears to run while computing
/// garbage. So tensors are packed by role, with offsets from the uniform's geometry.
///
/// ** The packing is also the better design. `params` and `grads` share one layout
/// (`w1 | b1 | w2 | b2`), so the SGD step is a single loop over one index with no branching on
/// which parameter a thread owns - the four-way `if` the first version needed is gone.
///
/// The last field is the output the host reads: the loss, one float.
pub const Buffers = extern struct {
    /// `x` at 0, then `t` at `samples * inputs`.
    inputs: [config.max]f32,
    /// `w1 | b1 | w2 | b2`, at the offsets `off*` compute.
    params: [config.max]f32,
    /// `h` at 0, then `y` at `samples * hidden`.
    acts: [config.max]f32,
    /// `dy` at 0, then `dpre` at `samples * outputs`.
    dacts: [config.max]f32,
    /// Same layout as `params`.
    grads: [config.max]f32,
    loss: [config.max]f32,
};

pub const g = k.Globals(@This());
const b_in = g.bind(.inputs);
const b_par = g.bind(.params);
const b_act = g.bind(.acts);
const b_dact = g.bind(.dacts);
const b_grad = g.bind(.grads);
const b_loss = g.bind(.loss);
const params = g.uniform();

// Offsets into the packed buffers. Plain functions of the uniform, so the host and every kernel
// derive the same layout from the same four numbers.
inline fn offT() u32 {
    return params.samples * params.inputs;
}
inline fn offB1() u32 {
    return params.inputs * params.hidden;
}
inline fn offW2() u32 {
    return offB1() + params.hidden;
}
inline fn offB2() u32 {
    return offW2() + params.hidden * params.outputs;
}
inline fn paramCount() u32 {
    return offB2() + params.outputs;
}
inline fn offY() u32 {
    return params.samples * params.hidden;
}
inline fn offDpre() u32 {
    return params.samples * params.outputs;
}

/// `h = tanh(x @ w1 + b1)`. One thread per hidden activation.
pub fn fwd_hidden(id: u32) void {
    if (id >= params.samples * params.hidden) {
        return;
    }
    const s: u32 = id / params.hidden;
    const j: u32 = id % params.hidden;
    var acc: f32 = b_par[offB1() + j];
    var i: u32 = 0;
    while (i < params.inputs) : (i += 1) {
        acc += b_in[s * params.inputs + i] * b_par[i * params.hidden + j];
    }
    b_act[id] = zm.tanh(acc);
}

/// `y = h @ w2 + b2`. One thread per output.
pub fn fwd_out(id: u32) void {
    if (id >= params.samples * params.outputs) {
        return;
    }
    const s: u32 = id / params.outputs;
    const o: u32 = id % params.outputs;
    var acc: f32 = b_par[offB2() + o];
    var j: u32 = 0;
    while (j < params.hidden) : (j += 1) {
        acc += b_act[s * params.hidden + j] * b_par[offW2() + j * params.outputs + o];
    }
    b_act[offY() + id] = acc;
}

/// `dy = 2 (y - t) / samples`, the gradient of the mean squared error. One thread per output.
pub fn loss_grad(id: u32) void {
    if (id >= params.samples * params.outputs) {
        return;
    }
    const diff: f32 = b_act[offY() + id] - b_in[offT() + id];
    b_dact[id] = 2.0 * diff / float(params.samples);
}

/// The loss itself, for the host to read, WITH THE STEP IT BELONGS TO beside it.
///
/// -- *** THE GPU LABELS ITS OWN OUTPUT --
///
/// The first version assumed the readback lagged by exactly one frame and paired loss `i` with
/// step `i`. On the device the GPU loss at "steps 1 and 2" was the same number, 3.4334915 -
/// the CPU's step-3 loss, read twice - because the queue was three frames behind, not one, and
/// the pairing was attributing losses to steps they did not come from. Nothing was wrong with
/// any kernel; the early-agreement check correctly failed anyway.
///
/// Writing the step counter beside the loss makes the attribution independent of timing: the
/// host reads `(loss, step)` and files the loss under that step. A readback seen twice is filed
/// twice under the same step, harmlessly.
pub fn loss_value(id: u32) void {
    if (id >= 1) {
        return;
    }
    const total: u32 = params.samples * params.outputs;
    var acc: f32 = 0;
    var i: u32 = 0;
    while (i < total) : (i += 1) {
        const d: f32 = b_act[offY() + i] - b_in[offT() + i];
        acc += d * d;
    }
    b_loss[0] = acc / float(total);
    // * `step + 1`, so that a readback of the untouched buffer - all zeros, before any
    // dispatch has landed - reads as "no step yet" rather than as step 0 with a loss of 0. On
    // the device that zero readback arrived first and claimed step 0's slot; the real step-0
    // loss then arrived and was refused as already seen.
    b_loss[1] = @floatFromInt(params.step + 1);
}

/// `dw2 = h^T @ dy`, `db2 = sum over samples of dy`. One thread per weight of w2; the thread for
/// weight (0, o) also owns db2[o], so no second dispatch is needed.
pub fn bwd_w2(id: u32) void {
    if (id >= params.hidden * params.outputs) {
        return;
    }
    const j: u32 = id / params.outputs;
    const o: u32 = id % params.outputs;
    var acc: f32 = 0;
    var bias: f32 = 0;
    var s: u32 = 0;
    while (s < params.samples) : (s += 1) {
        const d: f32 = b_dact[s * params.outputs + o];
        acc += b_act[s * params.hidden + j] * d;
        bias += d;
    }
    b_grad[offW2() + id] = acc;
    if (j == 0) {
        b_grad[offB2() + o] = bias;
    }
}

/// `dpre = (dy @ w2^T) * (1 - h^2)`: back through the second matmul and the tanh. One thread per
/// hidden activation.
pub fn bwd_h(id: u32) void {
    if (id >= params.samples * params.hidden) {
        return;
    }
    const s: u32 = id / params.hidden;
    const j: u32 = id % params.hidden;
    var acc: f32 = 0;
    var o: u32 = 0;
    while (o < params.outputs) : (o += 1) {
        acc += b_dact[s * params.outputs + o] * b_par[offW2() + j * params.outputs + o];
    }
    const hv: f32 = b_act[id];
    b_dact[offDpre() + id] = acc * (1.0 - hv * hv);
}

/// `dw1 = x^T @ dpre`, `db1 = sum over samples of dpre`. One thread per weight of w1.
pub fn bwd_w1(id: u32) void {
    if (id >= params.inputs * params.hidden) {
        return;
    }
    const i: u32 = id / params.hidden;
    const j: u32 = id % params.hidden;
    var acc: f32 = 0;
    var bias: f32 = 0;
    var s: u32 = 0;
    while (s < params.samples) : (s += 1) {
        const d: f32 = b_dact[offDpre() + s * params.hidden + j];
        acc += b_in[s * params.inputs + i] * d;
        bias += d;
    }
    b_grad[id] = acc;
    if (i == 0) {
        b_grad[offB1() + j] = bias;
    }
}

/// SGD over every parameter at once: one loop over the packed layout, no branching.
pub fn step(id: u32) void {
    if (id >= paramCount()) {
        return;
    }
    b_par[id] -= params.rate * b_grad[id];
}

// * One entry per line: see `zn_binary.kernels`.
pub const kernels = [_][:0]const u8{
    "fwd_hidden",
    "fwd_out",
    "loss_grad",
    "loss_value",
    "bwd_w2",
    "bwd_h",
    "bwd_w1",
    "step",
};

comptime {
    for (kernels) |name| {
        k.installKernelLean(@This(), name);
    }
}
