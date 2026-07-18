//! double_it.zig — the simplest compute kernel: out[i] = in[i] * 2, written in
//! the kompute DSL form. The author writes only config + Buffers + Params + the
//! kernel fn; `kompute` generates the g-namespace (extern storage/uniform on GPU,
//! plain var on CPU), the Ctx type, and the spirv_kernel entry.
const k = @import("kompute");

pub const config = k.Config{ .max = 1024, .workgroup = 64 };

pub const Buffers = extern struct {
    data: [config.max]f32,
};
// Params is a uniform: keep it 16-byte sized with scalar pads (an array pad like
// [3]u32 would emit array<u32,3> with stride 4, which WGSL rejects in `uniform`).
pub const Params = extern struct {
    count: u32,
    _pad0: u32 = 0,
    _pad1: u32 = 0,
    _pad2: u32 = 0,
};

pub const g = k.Globals(@This());
const b_data = g.bind(.data);

/// The kernel. Identical on CPU and GPU; buffers reached via module-level `b`.
pub fn double(c: k.Ctx(@This())) void {
    if (c.id >= c.params.count) {
        return;
    }
    b_data[c.id] = b_data[c.id] * 2.0;
}

comptime {
    k.installKernel(@This(), "double");
}
