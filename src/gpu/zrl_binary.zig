//! zrl_binary.zig - zimrrl's elementwise kernels on the GPU: the reinforcement-learning rows of the CPU/GPU sweep.
//!
//! The cartpole's two steps, PPO's clipped surrogate of one sample and the discriminator reward. Each kernel calls
//! the zimrrl function the CPU runs, so the device executes the host function rather than a transcription of it.
//!
//! `config`, `Buffers` and `Params` are zn_binary.zig's, copied unchanged: the sweep binds every binary kernel file
//! the same way, and the sweep page checks at compile time that the two layouts are identical.
const k = @import("kompute");
const zrl = @import("zrl");

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

/// One cartpole timestep per thread: 1024 environments in one dispatch.
///
/// THE HOST TWIN IS `zrl.cartpoleStep`, WHICH ALREADY EXISTED
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
    // This kernel used to restate `zrl.cartpoleStep`'s arithmetic by hand, and a transcription is
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
    const state: zrl.CartpoleState(f32) = .{
        .cart = ba[base + 0],
        .cart_rate = ba[base + 1],
        .pole_rad = ba[base + 2],
        .pole_rate_rad = ba[base + 3],
    };
    const stepped = zrl.cartpoleStep(f32, state, if (bb[c.id] < 0) .left else .right);
    // The state block only: four floats per environment exactly fills the output buffer, and
    // writing the reward and flag after it runs off the end - the `mesh_grid` mistake.
    bout[base + 0] = stepped.state.cart;
    bout[base + 1] = stepped.state.cart_rate;
    bout[base + 2] = stepped.state.pole_rad;
    bout[base + 3] = stepped.state.pole_rate_rad;
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
    const start: zrl.CartpoleState(f32) = .{
        .cart = 0,
        .cart_rate = 0,
        .pole_rad = ba[id],
        .pole_rate_rad = 0,
    };
    bout[id] = zrl.cartpoleContinuousStep(f32, start, bb[id]).state.pole_rad;
}

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
    bout[id] = zrl.ppoClipSample(f32, ba[id], 0.0, bb[id], 0.2);
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
    bout[id] = zrl.discriminatorReward(f32, ba[id] * 20.0, bb[id], 1.0e-4);
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
    "cartpole_step",
    "cartpole_pole",
    "ppo_clip",
    "disc_reward",
};

comptime {
    for (kernels) |name| {
        k.installKernel(@This(), name);
    }
}
