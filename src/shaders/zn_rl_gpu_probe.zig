//! A shader whose only job is to fail the build if zimrnum's RL arithmetic stops working on the
//! GPU.
//!
//! ---- WHY THIS FILE EXISTS ----
//!
//! `src/zimrnum.zig` is shader-free by design, and that is load-bearing: it keeps the numerics
//! library a `test-fast` root that runs in seconds without dragging a WebGPU queue into a
//! Jacobian test. But shader-free is not the same as **shader-incompatible**, and until this
//! file there was nothing holding the difference.
//!
//! The measured position when it was written: the op sweep covers 92 kernels of elementwise,
//! reduction and matmul arithmetic, and **not one reinforcement-learning operation**. PPO's
//! clipped surrogate, the DQN and SAC targets, advantage normalisation, the distribution
//! log-probs - all CPU-only, none ever run on a device.
//!
//! That matters for a specific reason. The PPO minibatch loop is elementwise over samples,
//! which is exactly what a GPU is for; when it moves, the kernel and the CPU loop should call
//! the SAME function rather than two transcriptions of one formula. Two transcriptions is how a
//! CPU/GPU comparison becomes circular - it compares a formula against itself and passes while
//! both are wrong.
//!
//! So the functions are written scalar-first (`ppoClipSample` and friends: no allocation, no
//! error union, no slice) and this probe proves that shape stays callable from a real SPIR-V
//! entry point.
//!
//! ---- WHAT IT DOES NOT CLAIM ----
//!
//! It proves these functions COMPILE for a shader and produce a value the optimiser cannot
//! delete. It does not prove the GPU result MATCHES the CPU one - that is the sweep's job, and
//! no RL row is in the sweep yet. Compiling is the precondition, not the guarantee.
//!
//! HOW TO ADD TO IT: call the function and fold its result into `acc`. Anything reachable from
//! the entry point is compiled; anything folded into the output survives dead-code elimination
//! at `-O ReleaseFast`, which is how the build runs it. A call whose result is discarded proves
//! nothing, because the optimiser is entitled to delete it.

const zn = @import("zn");

export fn rlProbeMain(
    out: *addrspace(.storage_buffer) f32,
    x: f32,
) callconv(.{ .spirv_fragment = .{} }) void {
    // PPO's clipped surrogate for one sample. `@exp`, `scalarClamp` and `@min` underneath -
    // every one of which a shader can do, but the error-returning wrapper around them could not
    // be called from here at all.
    var acc: f32 = zn.ppoClipSample(f32, x, x * 0.5, 1.0, 0.2);

    // The same function at the clip boundary, where the `@min` actually selects. A probe that
    // only ever exercised the unclipped branch would not notice `scalarClamp` breaking.
    acc += zn.ppoClipSample(f32, x + 4.0, x, -1.0, 0.2);

    // The off-policy target's branch, as a shader must express it: a SELECT, not an `if`.
    // `Transition.bootstraps()` is the CPU form of this decision and returns a bool from a
    // struct; a kernel has neither the struct nor the branch, so what has to stay true is that
    // the ARITHMETIC either side of the decision is shader-expressible.
    const bootstrapped: f32 = 1.0 + 0.99 * x;
    const ended: f32 = 1.0;
    const terminal: bool = x > 1.0e9; // never true at runtime; keeps both sides live
    acc += if (terminal) ended else bootstrapped;

    // ---- THE CARTPOLE DYNAMICS, WHICH IS WHERE COLLECTION SPENDS ITS TIME ----
    //
    // On-policy RL spends most of its wall clock COLLECTING, and collection is embarrassingly
    // parallel across environments - one row each, no interaction. That is the shape a GPU
    // wants, and it is how znum's resident rollout runs cartpole.
    //
    // `cartpoleContinuousStep` is pure arithmetic over a four-field struct: no allocation, no error
    // union, no slice. This proves it stays that way. If someone adds a `try` or a heap
    // allocation to the dynamics, the build stops here rather than on a device.
    const start: zn.CartpoleState(f32) = .{
        .cart = x * 0.01,
        .cart_rate = 0,
        .pole_rad = x * 0.02,
        .pole_rate_rad = 0,
    };
    const advanced = zn.cartpoleContinuousStep(f32, start, x * 0.1);
    acc += advanced.state.pole_rad + advanced.state.cart_rate;

    // Both TASKS, because they differ in a `switch` and a shader must be able to take either
    // branch. `swingup` also calls `cos`, which `hold` does not - so a probe that only ever
    // exercised `hold` would not notice the trigonometry failing to lower.
    const held = zn.cartpoleOutcome(f32, advanced.state, .hold);
    const swung = zn.cartpoleOutcome(f32, advanced.state, .swingup);
    acc += held.reward + swung.reward;
    acc += if (held.failed) 1.0 else 0.0;
    acc += if (swung.failed) 1.0 else 0.0;

    // The adversarial style reward, at the point where its floor binds. A discriminator that is
    // being fooled drives `1 - sigmoid(logit)` toward zero and the log toward infinity, so the
    // interesting branch is the SATURATED one - a probe that only ever passed a small logit
    // would compile the arithmetic and never reach the clamp that stops a winning policy from
    // earning an unbounded reward.
    acc += zn.discriminatorReward(f32, x * 20.0, 1.0, 1.0e-4);
    acc += zn.discriminatorReward(f32, -x, 2.0, 1.0e-4);

    // Folded into the output so ReleaseFast cannot delete the whole thing and call it verified.
    out.* = acc;
}
