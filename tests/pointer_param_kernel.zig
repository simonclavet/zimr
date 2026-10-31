//! tests/pointer_param_kernel.zig - a kompute kernel that hands POINTERS to non-inline functions, the shape of every
//! `zm.CompensatedSum.add(&sum, x)` call. `zig build tripwires` compiles it to SPIR-V and translates it the way every
//! kernel is translated (`addComputeOutput`, strict), then checks that its WGSL passes by reference:
//!
//!   - the callee takes `ptr<function, T>` and stores through `(*p)`;
//!   - the kernel passes its whole local variable as `&tally`;
//!   - a function handing its own pointer parameter on passes `&(*p)`.
//!
//! Lowered by value instead - the parameter copied into a local - the WGSL compiles just as well and every write lands
//! in the copy: the caller's sum stays zero, in the browser only, since Vulkan runs the SPIR-V itself. zn_mlp's
//! `norm_fwd` and zn_unary's `layernorm_rows` computed that way on the web while their CPU twins were right.

const k = @import("kompute");

pub const config = k.Config{ .max = 64, .workgroup = 64 };

pub const Buffers = extern struct {
    sums: [config.max]f32,
};

/// A uniform: sixteen bytes of scalars (an array pad would be `array<u32, 3>`, which WGSL refuses in `uniform`).
pub const Params = extern struct {
    count: u32,
    _pad0: u32 = 0,
    _pad1: u32 = 0,
    _pad2: u32 = 0,
};

pub const g = k.Globals(@This());

const b_sums = g.bind(.sums);

/// A running sum and how many values went into it: a struct, as `zm.CompensatedSum` is, so `add` takes it by pointer
/// and writes two fields through it.
const Tally = struct {
    total: f32 = 0,
    value_count: f32 = 0,

    /// Not `inline`, so the call reaches the SPIR-V as an `OpFunctionCall` with a pointer argument.
    fn add(tally: *Tally, value: f32) void {
        tally.total += value;
        tally.value_count += 1.0;
    }

    /// Hands its own pointer parameter on to `add`, twice.
    fn addTwice(tally: *Tally, value: f32) void {
        tally.add(value);
        tally.add(value);
    }
};

/// `sums[i] = 3 * sums[i]`, as three adds into one local `Tally`. All three must reach it: lowered by value, the
/// result is zero.
pub fn tallyThreeTimes(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    var tally: Tally = .{};
    tally.add(b_sums[c.id]);
    tally.addTwice(b_sums[c.id]);
    b_sums[c.id] = tally.total;
}

pub const kernels = [_][:0]const u8{"tallyThreeTimes"};

comptime {
    k.installKernels(@This());
}
