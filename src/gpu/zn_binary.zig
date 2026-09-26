//! zn_binary.zig - zimrnum's elementwise kernels on the GPU: dense f32, two inputs, one output.
//!
//! ** DENSE ONLY, AND THAT IS THE POINT OF THE EXAMPLE. The kernel takes flat buffers and a
//! count - no shape, no strides - exactly like znum's `k_binary.zig`. `zn.zip` on the CPU accepts
//! any rank up to 6 with arbitrary strides, so the GPU's domain is NARROWER: a broadcast view has
//! to be materialised before it can be bound. The host does that explicitly and shows it.
const k = @import("kompute");
const zm = @import("zm");
const float = zm.float;
const atan2Rad = zm.atan2Rad;
const zn = @import("zn");

pub const config = k.Config{ .max = 1 << 14, .workgroup = 64 };

/// Convention: the last field is the output, the rest are inputs.
pub const Buffers = extern struct {
    a: [config.max]f32,
    b: [config.max]f32,
    out: [config.max]f32,
    /// -- *** A THIRD INPUT, WHICH IS WHAT SEVERAL zimrnum FUNCTIONS NEEDED --
    ///
    /// `whereInto` takes a mask plus two sources; `sgdMomentum` takes a weight, a gradient and a
    /// velocity; `adamStep` takes two moments. All were host-only for want of one more binding,
    /// not for any reason of algorithm. WebGPU guarantees eight storage buffers per stage and
    /// this pipeline used three.
    c: [config.max]f32,
    /// Persistent state a kernel both reads and writes - a momentum velocity, an Adam moment.
    /// Separate from `c` because the sweep must be able to zero it between rows.
    state: [config.max]f32,
};

/// Uniforms must be 16-byte sized, padded with scalars - an `[3]u32` pad emits `array<u32,3>`
/// with stride 4, which WGSL rejects in the uniform address space.
pub const Params = extern struct {
    count: u32,
    /// The learning rate for `sgd_step`. One of the pad words carrying a value instead of a
    /// zero - a uniform must be 16-byte sized either way, so a scalar here is free.
    scalar: f32 = 0,
    /// Columns, for the entries that decode a flat id into (row, col).
    cols: u32 = 0,
    /// Huber's threshold. Named for what it is; `scalar` already carries the learning rate.
    delta: f32 = 0,
    /// * `sgd_momentum`'s decay. It gets its OWN field rather than borrowing `delta`: two kernels
    /// reading one uniform field need the same value, and Huber's threshold is 1.0 while a
    /// momentum is 0.9. Sharing would have made one of the two rows fail on the device only.
    momentum: f32 = 0,
    // * Three words of padding. Nine real fields is 36 bytes and WGSL uniform blocks round to
    // 16, so the next multiple is 48 - twelve words. The host names the exact size in its error,
    // so this is measured rather than guessed at.
    /// How many times `repeat_each` repeats each element. **Not `b_row`**: that is a row stride
    /// and `bcast_add` legitimately sets it to zero, which as a divisor is a fault. Overloading a
    /// field whose name says something else is how a kernel ends up dividing by a broadcast flag.
    repeat_count: u32 = 1,
    /// Where `slice_columns` starts reading. **Not `b_col`**: that is a column STRIDE and
    /// `bcast_add` sets it to 1, which as an offset would silently read the wrong column.
    /// Overloading a field whose name says something else is how `repeat_each` nearly ended up
    /// dividing by a broadcast flag - twice is a pattern, so this one gets its own slot.
    slice_start: u32 = 0,
    /// How many columns `concat_columns` takes from `ba` before switching to `bb`.
    left_columns: u32 = 0,
    /// -- *** STRIDES IN THE UNIFORM, AND A STRIDE OF ZERO BROADCASTS --
    ///
    /// This is `zn.broadcastTo`'s representation, moved into a uniform. A `(1, n)` row stretched
    /// down a `(m, n)` field has `row = 0`, so every output row reads the same input row - no
    /// copy, no second buffer. It is the same trick the CPU view uses, and it is why the tensor
    /// type already held the GPU's parameters.
    ///
    /// * Second half of a uniform that is now 32 bytes: still a multiple of 16, so nothing
    /// changes for the entries that ignore these.
    a_row: u32 = 0,
    a_col: u32 = 0,
    b_row: u32 = 0,
    b_col: u32 = 0,
};

pub const g = k.Globals(@This());
const ba = g.bind(.a);
const bb = g.bind(.b);
const bout = g.bind(.out);
const bc = g.bind(.c);
const bstate = g.bind(.state);

/// Guard first, then a branch-free body: every lane that survives does the same work.
pub fn add(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    bout[c.id] = ba[c.id] + bb[c.id];
}

pub fn mul(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    bout[c.id] = ba[c.id] * bb[c.id];
}

/// The entries this file exports. ONE list: the comptime loop below installs from it, and the
/// host derives its pipeline table from it too, so a kernel is named in exactly one place.
/// `out = if (a > 0) b else 0` - relu's gradient, with `a` the FORWARD INPUT and `b` the
/// incoming gradient. Matches `zn.reluGrad`.
pub fn relu_grad(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    bout[c.id] = if (ba[c.id] > 0) bb[c.id] else 0;
}

/// `out = a - rate * b` - one plain gradient-descent step, with `a` the weights and `b` the
/// gradient. Matches `zn.sgdStep`.
pub fn sgd_step(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    bout[c.id] = ba[c.id] - c.params.scalar * bb[c.id];
}

/// `out = a - b`. Matches `zn.sub`.
pub fn sub(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    bout[c.id] = ba[c.id] - bb[c.id];
}

/// `out = a / b`. Matches `zn.div`. No guard against a zero divisor: WGSL's `/` yields an
/// infinity there and so does the host's, which is the agreement the sweep checks.
pub fn div(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    bout[c.id] = ba[c.id] / bb[c.id];
}

/// `out = a + b` with each operand read through its own row/column strides, so a stride of 0
/// broadcasts that axis. The bias add of a dense layer: `(m, n) + (1, n)`.
/// The COLUMN grid of a mesh: `out[i][j] = x[j]`.
///
/// TWO KERNELS, NOT ONE WRITING TWICE
///
/// The first version filled both grids in one dispatch, writing the second to
/// `bout[count + id]` - past the end of a buffer sized for `count`. It passed every test I had
/// and the smoke caught it as a LEAK: the runtime grew the buffer, and 2 pipelines x 45
/// lifecycles showed up as `compute_pipeline+90`.
///
/// **A kernel that needs more output than the harness gives it is the harness telling you the
/// shape is wrong.** One grid per dispatch fits, and the pair is two rows instead of one.
/// Columns `[b_col, b_col + cols)` of `ba`, which is `a_row` wide.
///
/// PURE ADDRESSING - AND THAT IS WHY IT BELONGS ON THE GPU AT ALL
///
/// There is no arithmetic here, only an index. That makes it a poor candidate for a kernel on its
/// own and an excellent one as part of a chain: multi-head attention slices a projection once per
/// head, and doing that on the host would mean a round trip per head.
///
/// The host width is `a_row` and the output width is `cols`; they differ, which is the whole
/// point. A kernel that assumed they matched would read the right values for one head and the
/// wrong ones for every other.
/// One cartpole timestep per thread: 1024 environments in one dispatch.
///
/// THE HOST TWIN IS `zn.cartpoleStep`, WHICH ALREADY EXISTED
///
/// This is the arithmetic of that function transcribed, and the sweep row runs the two against
/// each other like every other kernel here. **The pure scalar step is what made the twin free** -
/// there was nothing to write on the host side, because the definition a caller uses IS the
/// reference.
///
/// `ba` is the state, four floats per row: cart, cart rate, pole angle in RADIANS, pole rate.
/// `bb` is the push, one per row, negative for left. `bout` takes the next state in the same
/// layout, and the reward and failure flag go in the two slots after the state block.
///
/// Radians here, not turns, for the reason the host function gives: the dynamics are
/// differential equations and a derivative costs a tau in turns.
pub fn cartpole_step(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    const base: u32 = c.id * 4;
    // THE HOST FUNCTION ITSELF - NOT A TRANSCRIPTION OF IT
    //
    // This kernel used to restate `zn.cartpoleStep`'s arithmetic by hand, and a transcription is
    // a second definition that can drift. It calls the host function now: **zimrnum compiles to
    // SPIR-V**, so the GPU runs the same code the CPU runs and the sweep row compares a function
    // against itself.
    //
    // The opt-in is `.wants_zimrnum` on this kernel's build entry. Per-kernel, because Zig
    // rejects a `--dep` for a module the file does not import - passing `zn` to every kernel
    // fails on the ones with no use for it, which is what blocked the first attempt.
    //
    // `ba` is the state, four floats per row; `bb` is the push, negative for left. Radians and
    // not turns for the reason the host function gives: the dynamics are differential equations,
    // and a derivative costs a tau in turns.
    const state: zn.CartpoleState(f32) = .{
        .cart = ba[base + 0],
        .cart_rate = ba[base + 1],
        .pole_rad = ba[base + 2],
        .pole_rate_rad = ba[base + 3],
    };
    const stepped = zn.cartpoleStep(f32, state, if (bb[c.id] < 0) .left else .right);
    // The state block only: four floats per environment exactly fills the output buffer, and
    // writing the reward and flag after it runs off the end - the `mesh_grid` mistake.
    bout[base + 0] = stepped.state.cart;
    bout[base + 1] = stepped.state.cart_rate;
    bout[base + 2] = stepped.state.pole_rad;
    bout[base + 3] = stepped.state.pole_rate_rad;
}

pub fn slice_columns(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    // THE OUTPUT IS NARROWER THAN `cols`, AND `cols` IS THE INPUT'S WIDTH
    //
    // The host sets `cols` once for every row in the sweep, and it is the FIELD's width. A slice
    // is narrower, so dividing by `cols` walks the wrong shape entirely - 32 rows of 64 instead
    // of 64 rows of 32.
    //
    // My headless twin set `cols` to the output width explicitly and passed, which means **it
    // verified a configuration the sweep never dispatches.** The width is derived here instead,
    // from parameters the host really does set.
    const out_width: u32 = c.params.cols - c.params.slice_start;
    const row: u32 = c.id / out_width;
    const col: u32 = c.id % out_width;
    bout[c.id] = ba[row * c.params.a_row + c.params.slice_start + col];
}

/// `ba`'s columns then `bb`'s, side by side.
///
/// The inverse of `slice_columns`, and the pair is what multi-head attention needs: split a
/// projection, attend per head, join the results. `a_col` is how many columns come from `ba`;
/// everything past that comes from `bb`.
pub fn concat_columns(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    const row: u32 = c.id / c.params.cols;
    const col: u32 = c.id % c.params.cols;
    if (col < c.params.left_columns) {
        bout[c.id] = ba[row * c.params.left_columns + col];
    } else {
        const from_b: u32 = col - c.params.left_columns;
        bout[c.id] = bb[row * (c.params.cols - c.params.left_columns) + from_b];
    }
}

pub fn mesh_grid_x(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    bout[c.id] = ba[c.id % c.params.cols];
}

/// The ROW grid of a mesh: `out[i][j] = y[i]`.
pub fn mesh_grid_y(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    bout[c.id] = bb[c.id / c.params.cols];
}

/// Each element repeated `repeat_count` times along the last axis.
///
/// The whole operation is `at / count` on the repeated axis: position 4 with a count of 2 reads
/// source 2. `tile` would be `at % length` instead, and that one character is the entire
/// difference between the two - which is why the CPU names are `repeatEach` and `tile` rather
/// than numpy's `repeat` and `tile`.
pub fn repeat_each(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    const row: u32 = c.id / c.params.cols;
    const col: u32 = c.id % c.params.cols;
    // THE SOURCE ROW STRIDE IS NOT THE SOURCE WIDTH
    //
    // The first version derived it as `cols / count`, assuming the input was packed at its own
    // width. It is not: the host uploads the whole field and the input is a strided VIEW of the
    // first half of each row, so consecutive source rows are `a_row` apart, not `cols / count`.
    // The headless twin caught it at 5.16 - the kernel was reading the wrong row entirely.
    bout[c.id] = ba[row * c.params.a_row + col / c.params.repeat_count];
}

pub fn bcast_add(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    const row: u32 = c.id / c.params.cols;
    const col: u32 = c.id % c.params.cols;
    const av: f32 = ba[row * c.params.a_row + col * c.params.a_col];
    const bv: f32 = bb[row * c.params.b_row + col * c.params.b_col];
    bout[c.id] = av + bv;
}

/// `out = dy * y * (1 - y)` - sigmoid's gradient from its OUTPUT `a = y` and the incoming
/// gradient `b = dy`. Taking the output is what makes it one multiply instead of recomputing the
/// sigmoid; `relu` had to take its input for the opposite reason.
pub fn sigmoid_grad(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    const y: f32 = ba[c.id];
    bout[c.id] = bb[c.id] * y * (1.0 - y);
}

/// `out = dy * (1 - y*y)` - tanh's gradient, also from its output.
pub fn tanh_grad(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    const y: f32 = ba[c.id];
    bout[c.id] = bb[c.id] * (1.0 - y * y);
}

pub fn minimum(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    bout[c.id] = @min(ba[c.id], bb[c.id]);
}

pub fn maximum(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    bout[c.id] = @max(ba[c.id], bb[c.id]);
}

pub fn atan2f(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    bout[c.id] = atan2Rad(ba[c.id], bb[c.id]);
}

pub fn hypotf(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    const x: f32 = ba[c.id];
    const y: f32 = bb[c.id];
    bout[c.id] = @sqrt(x * x + y * y);
}

pub fn greater(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    bout[c.id] = if (ba[c.id] > bb[c.id]) 1.0 else 0.0;
}

pub fn less(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    bout[c.id] = if (ba[c.id] < bb[c.id]) 1.0 else 0.0;
}

pub fn equal(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    bout[c.id] = if (ba[c.id] == bb[c.id]) 1.0 else 0.0;
}

/// `t` rides in `params.scalar`. Interpolates from the NEARER endpoint, matching `zn.lerpTo`:
/// either one-line form misses one of its own endpoints in floating point.
pub fn lerpf(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    const x: f32 = ba[c.id];
    const y: f32 = bb[c.id];
    const t: f32 = c.params.scalar;
    bout[c.id] = if (t <= 0.5) x + t * (y - x) else y - (1.0 - t) * (y - x);
}

/// `out[0] = mean((a - b)^2)` - the loss, as a scalar. Matches `zn.mseLoss`.
///
/// * One thread over the whole buffer, like `sum_all`: the checkable reference a tree reduction
/// will be compared against. The CPU side compensates and this does not, so the row measures the
/// drift of a plain 4096-term accumulation - the same number `sum all (scalar)` reports, and the
/// justification for `sumAll`'s compensated default.
pub fn mse_loss(c: k.Ctx(@This())) void {
    if (c.id >= 1) {
        return;
    }
    var total: f32 = 0;
    var i: u32 = 0;
    while (i < c.params.count) : (i += 1) {
        const d: f32 = ba[i] - bb[i];
        total += d * d;
    }
    bout[0] = total / float(c.params.count);
}

/// `out[0] = mean |a - b|`. One thread, plainly accumulated, like `mse_loss`.
pub fn mae_loss(c: k.Ctx(@This())) void {
    if (c.id >= 1) {
        return;
    }
    var total: f32 = 0;
    var i: u32 = 0;
    while (i < c.params.count) : (i += 1) {
        total += @abs(ba[i] - bb[i]);
    }
    bout[0] = total / float(c.params.count);
}

/// Huber: squared below `delta`, linear above - the same branch as `zn.huberLoss`, so the two
/// sides agree on which side of the threshold every element falls.
pub fn huber_loss(c: k.Ctx(@This())) void {
    if (c.id >= 1) {
        return;
    }
    const delta: f32 = c.params.delta;
    var total: f32 = 0;
    var i: u32 = 0;
    while (i < c.params.count) : (i += 1) {
        const d: f32 = @abs(ba[i] - bb[i]);
        total += if (d <= delta) 0.5 * d * d else delta * (d - 0.5 * delta);
    }
    bout[0] = total / float(c.params.count);
}

/// Binary cross-entropy from logits `a` against targets `b`, in the overflow-free form
/// `max(x,0) - x*t + log(1 + e^-|x|)` that `zn.bceLogitsLoss` uses. The sweep's `b` is a ramp on
/// [-1, 1] rather than a probability; the expression is defined for any real target and both
/// sides compute the same one, so the row still compares the implementation.
pub fn bce_loss(c: k.Ctx(@This())) void {
    if (c.id >= 1) {
        return;
    }
    var total: f32 = 0;
    var i: u32 = 0;
    while (i < c.params.count) : (i += 1) {
        const x: f32 = ba[i];
        total += @max(x, 0) - x * bb[i] + @log(1 + @exp(-@abs(x)));
    }
    bout[0] = total / float(c.params.count);
}

/// 2-D cross-correlation of `a` (a `cols x cols` image) with the 3x3 kernel held in `b[0..9]`,
/// stride 1, padding 1 - so the output is the image's size. One thread per output pixel.
///
/// * Padding is implicit: a tap that lands outside the image is skipped, contributing zero.
/// The bounds tests are on signed values because the top-left taps land at -1.
pub fn conv2d_same(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    const w: u32 = c.params.cols;
    const y: i32 = @intCast(c.id / w);
    const x: i32 = @intCast(c.id % w);
    const side: i32 = @intCast(w);
    var acc: f32 = 0;
    var i: i32 = 0;
    while (i < 3) : (i += 1) {
        const iy: i32 = y + i - 1;
        if (iy < 0 or iy >= side) {
            continue;
        }
        var j: i32 = 0;
        while (j < 3) : (j += 1) {
            const ix: i32 = x + j - 1;
            if (ix < 0 or ix >= side) {
                continue;
            }
            const pixel: u32 = @intCast(iy * side + ix);
            const tap: u32 = @intCast(i * 3 + j);
            acc += ba[pixel] * bb[tap];
        }
    }
    bout[c.id] = acc;
}

pub fn not_equal(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    bout[c.id] = if (ba[c.id] != bb[c.id]) 1.0 else 0.0;
}

pub fn greater_equal(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    bout[c.id] = if (ba[c.id] >= bb[c.id]) 1.0 else 0.0;
}

pub fn less_equal(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    bout[c.id] = if (ba[c.id] <= bb[c.id]) 1.0 else 0.0;
}

/// `out = a where c is non-zero, else b`. The mask arrives in `c`, matching `zn.whereInto`.
pub fn where_pick(k_ctx: k.Ctx(@This())) void {
    if (k_ctx.id >= k_ctx.params.count) {
        return;
    }
    bout[k_ctx.id] = if (bc[k_ctx.id] != 0) ba[k_ctx.id] else bb[k_ctx.id];
}

/// One SGD-with-momentum step. `a` is the weight, `b` the gradient, `state` the velocity, which
/// this kernel updates in place. `scalar` is the learning rate, `delta` the momentum.
///
/// * The velocity accumulates the GRADIENT, not the step - the same choice `zn.sgdMomentum`
/// makes, so changing the learning rate does not retroactively rescale the history.
pub fn sgd_momentum(k_ctx: k.Ctx(@This())) void {
    if (k_ctx.id >= k_ctx.params.count) {
        return;
    }
    const velocity: f32 = k_ctx.params.momentum * bstate[k_ctx.id] + bb[k_ctx.id];
    bstate[k_ctx.id] = velocity;
    bout[k_ctx.id] = ba[k_ctx.id] - k_ctx.params.scalar * velocity;
}

/// One Adam step from a zeroed state, which is step 1 - so both bias corrections are exactly
/// `1 - beta` and the update reduces to `rate * sign(gradient)`. `a` is the weight, `b` the
/// gradient; `state` holds the first moment and `c` the second.
///
/// * Step 1 rather than a general step because the sweep runs each row once from a known state.
/// The general form is `zn.adamStep`, and the CPU twin here calls it with step 1.
pub fn adam_step(k_ctx: k.Ctx(@This())) void {
    if (k_ctx.id >= k_ctx.params.count) {
        return;
    }
    const beta1: f32 = 0.9;
    const beta2: f32 = 0.999;
    const gradient: f32 = bb[k_ctx.id];
    const first: f32 = (1 - beta1) * gradient;
    const second: f32 = (1 - beta2) * gradient * gradient;
    bstate[k_ctx.id] = first;
    bc[k_ctx.id] = second;
    const corrected_first: f32 = first / (1 - beta1);
    const corrected_second: f32 = second / (1 - beta2);
    bout[k_ctx.id] = ba[k_ctx.id] -
        k_ctx.params.scalar * corrected_first / (@sqrt(corrected_second) + 1.0e-8);
}

// * ONE ENTRY PER LINE, deliberately. `zig fmt` column-aligns a list whose items share
// a line, and that realignment silently broke an append anchor three times during the
// port. A vertical list is stable under formatting, so adding a kernel is a one-line
// diff that no tooling will reflow.
/// PPO's clipped surrogate, per sample, on the device.
///
/// ---- WHY THIS ROW EXISTS ----
///
/// `ppoClipSample` was written scalar-first - no allocation, no error union, no slice - SO THAT
/// a kernel and the CPU loop could call the same function rather than two transcriptions of one
/// formula. Two transcriptions is how a CPU/GPU comparison becomes circular: it compares a
/// formula against itself and passes while both are wrong.
///
/// Until this row, that was an intention. The SPIR-V probe proved the shape COMPILES; only the
/// sweep proves the device produces the same numbers.
///
/// The clip is fixed at 0.2 - the standard value, and a constant here so the row tests the
/// arithmetic rather than a parameter the harness would have to carry.
pub fn ppo_clip(k_ctx: k.Ctx(@This())) void {
    if (k_ctx.id >= k_ctx.params.count) {
        return;
    }
    const id: u32 = k_ctx.id;
    // `a` is the LOG-RATIO and `b` the advantage, so `logp_old` is zero and `logp_new` is the
    // ratio's log directly. Two inputs, not three - the harness fills `a` and `b` for every row
    // and `c` only for the kernels that populate it themselves.
    //
    // This encoding is not a compromise: with the advantage varying in sign across the input
    // field, BOTH clip branches are exercised. A row that fixed the advantage positive would
    // only ever test the upper one, and the `@min` that makes this a trust region would be
    // half-verified.
    bout[id] = zn.ppoClipSample(f32, ba[id], 0.0, bb[id], 0.2);
}

/// One cartpole step's pole angle, under a continuous force.
///
/// Collection is where on-policy RL spends its wall clock and it is embarrassingly parallel
/// across environments, so the dynamics belong on a device. This row is the narrow version of
/// that claim: the same equations, the same answer, both sides.
///
/// The pole angle and the applied force are the row's two inputs.
pub fn cartpole_pole(k_ctx: k.Ctx(@This())) void {
    if (k_ctx.id >= k_ctx.params.count) {
        return;
    }
    const id: u32 = k_ctx.id;
    // `a` is the pole angle, `b` the applied force. The cart and the pole's rate start at zero
    // so the row has one degree of freedom to disagree on rather than four - a mismatch here
    // names the term that caused it.
    const start: zn.CartpoleState(f32) = .{
        .cart = 0,
        .cart_rate = 0,
        .pole_rad = ba[id],
        .pole_rate_rad = 0,
    };
    bout[id] = zn.cartpoleContinuousStep(f32, start, bb[id]).state.pole_rad;
}

/// The adversarial style reward, on the device.
///
/// `a` is the discriminator's logit, `b` the reward scale. The floor is fixed at 1e-4 - the
/// value AMP uses - so the row tests the arithmetic rather than a parameter the harness would
/// have to carry.
///
/// The input field spans both regimes: a losing policy where the log is gentle, and a winning
/// one where `1 - sigmoid` underflows and the floor is the only thing keeping the reward finite.
pub fn disc_reward(k_ctx: k.Ctx(@This())) void {
    if (k_ctx.id >= k_ctx.params.count) {
        return;
    }
    const id: u32 = k_ctx.id;
    bout[id] = zn.discriminatorReward(f32, ba[id] * 20.0, bb[id], 1.0e-4);
}

/// Adam at a LATER step, with moments that already carry history.
///
/// ---- THE GAP THIS CLOSES, AND WHY IT IS THE SHAPE OF A REAL BUG ----
///
/// `adam_step` above hardcodes the first step: it computes the first moment as
/// `(1 - beta1) * gradient`, which is only true when the incoming moment is ZERO, and divides by
/// `1 - beta1`, which is only the bias correction at `t = 1`. The conformance row for it fills
/// both moments with zero, so CPU and GPU agree - about a step that happens once per training
/// run.
///
/// **Every update after the first takes a different path, and nothing checked it.** That matters
/// beyond tidiness: a predecessor project's GPU-resident SAC learned correctly for one update and
/// then diverged, with eleven hypotheses formed and none confirmed. "Nearly right for one step
/// and systematically wrong thereafter" is exactly what a first-step-only optimiser produces.
///
/// The incoming moments are DERIVED from the inputs rather than uploaded, so both sides can build
/// them identically without the harness carrying two more buffers. The point is to exercise the
/// warm arithmetic, not to reproduce any particular training state.
pub fn adam_step_warm(k_ctx: k.Ctx(@This())) void {
    if (k_ctx.id >= k_ctx.params.count) {
        return;
    }
    const id: u32 = k_ctx.id;
    const beta1: f32 = 0.9;
    const beta2: f32 = 0.999;
    const rate: f32 = 0.01;
    const eps: f32 = 1e-8;

    const weight: f32 = ba[id];
    const gradient: f32 = bb[id];
    // History the previous updates would have left behind.
    const first_in: f32 = 0.3 * gradient;
    const second_in: f32 = 0.2 * gradient * gradient;

    const first: f32 = beta1 * first_in + (1 - beta1) * gradient;
    const second: f32 = beta2 * second_in + (1 - beta2) * gradient * gradient;
    // Bias correction at step 5, as constants rather than a device `pow` or a repurposed
    // uniform field - `lo` and `hi` are the clamp bounds and are shared by every kernel here.
    //
    //   1 - 0.9^5   = 0.40951
    //   1 - 0.999^5 = 0.004990009995000983
    //
    // Fixing the step is what makes them constants, and fixing the step is fine: the point is to
    // exercise the arithmetic that runs when the moments are NOT empty, not to sweep `t`.
    const correction_first: f32 = 0.40951;
    const correction_second: f32 = 0.004990009995000983;
    const corrected_first: f32 = first / correction_first;
    const corrected_second: f32 = second / correction_second;
    bout[id] = weight - rate * corrected_first / (@sqrt(corrected_second) + eps);
}

/// A target network following its online network by a fraction.
///
/// ---- ALSO A SECOND-UPDATE OPERATION, ALSO UNCHECKED UNTIL NOW ----
///
/// At the first update a target network has just been copied from the online one, so the follow
/// moves it from a value to the same value and any error in the arithmetic is invisible. From the
/// second update onward it is the only thing keeping the bootstrap target from chasing the
/// critic that produced it.
///
/// So this shares the shape of the warm Adam row above: correct-looking for one step, and the
/// governing operation thereafter. `follow` is fixed at 0.005 - the SMALL number, which is the
/// convention `polyakUpdate` takes and the one that is easy to pass the complement of.
pub fn polyak_follow(k_ctx: k.Ctx(@This())) void {
    if (k_ctx.id >= k_ctx.params.count) {
        return;
    }
    const id: u32 = k_ctx.id;
    const follow: f32 = 0.005;
    bout[id] = ba[id] + follow * (bb[id] - ba[id]);
}

/// SAC's tanh-squash log-density correction, at saturation.
///
/// ---- THE INPUT FIELD IS SCALED UP ON PURPOSE ----
///
/// `a` is multiplied by 12 so the field reaches pre-squash values where `tanh` rounds to exactly
/// 1 in f32. That is where the textbook form `-log(1 - tanh(u)^2)` becomes `log(0)`, and it is
/// **where a converged SAC policy spends most of its time** - the correction is needed most
/// precisely where the naive spelling fails.
///
/// A row fed ordinary small values would agree perfectly and check nothing that matters.
pub fn squash_correction(k_ctx: k.Ctx(@This())) void {
    if (k_ctx.id >= k_ctx.params.count) {
        return;
    }
    const id: u32 = k_ctx.id;
    bout[id] = zn.squashCorrection(f32, ba[id] * 12.0);
}

// ---- `sacTarget` IS NOT KERNEL-CALLABLE, AND THAT IS WORTH RECORDING ----
//
// A row for it was written and removed. `sacTarget` takes `next_estimates: []const T` - a slice,
// because it aggregates over however many critics there are - and SPIR-V rejects constructing a
// slice from a local array: "cannot construct slices without the variable_pointers capability".
//
// So despite reading like a scalar-first function, it cannot run on a device as written. For a
// GPU-resident trainer the aggregation would have to be unrolled at the call site, or the
// function would need a fixed-arity twin for the common twin-critic case.
//
// Recorded here rather than in a plan file because this is where someone will next try it.

pub const kernels = [_][:0]const u8{
    "squash_correction",
    "polyak_follow",
    "adam_step_warm",
    "disc_reward",
    "ppo_clip",
    "cartpole_pole",
    "add",
    "mul",
    "sub",
    "div",
    "relu_grad",
    "sgd_step",
    "bcast_add",
    "sigmoid_grad",
    "tanh_grad",
    "minimum",
    "maximum",
    "atan2f",
    "hypotf",
    "greater",
    "less",
    "equal",
    "lerpf",
    "mse_loss",
    "mae_loss",
    "huber_loss",
    "bce_loss",
    "conv2d_same",
    "not_equal",
    "greater_equal",
    "less_equal",
    "where_pick",
    "sgd_momentum",
    "adam_step",
    "mesh_grid_x",
    "mesh_grid_y",
    "repeat_each",
    "slice_columns",
    "concat_columns",
    "cartpole_step",
};

comptime {
    for (kernels) |name| {
        k.installKernel(@This(), name);
    }
}
