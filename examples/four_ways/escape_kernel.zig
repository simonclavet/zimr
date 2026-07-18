//! examples/four_ways/escape_kernel.zig — the kernel.
//!
//! Three lines of body. All it does is turn an invocation id into a pixel coordinate and
//! call `escape`. That call is the entire content of this file, and it is what reaches all
//! three RUNTIME machines:
//!
//!   * `.cpu`    — kompute runs the kernel as a plain `while` loop over ids;
//!   * `.worker` — the SAME loop, in another wasm instance on another thread;
//!   * `.gpu`    — compiled to SPIR-V (`escape` appears in it by name), then transpiled to
//!                 WGSL, then dispatched `ceil(n/64)` workgroups wide.
//!
//! What does NOT reach comptime is this kernel — only the function it calls. The kernel
//! indexes `M.g.B`, a module-level `var`, and comptime cannot touch module-level runtime
//! memory. That is not a limitation to engineer around: the globals exist BECAUSE the GPU
//! needs per-field storage bindings (one megastruct binding corrupts on Adreno past ~1000
//! invocations — kompute learned that the hard way). The globals are forced by hardware.
//!
//! So the honest claim, and the more interesting one:
//!
//!     the FUNCTION is shared by all four.
//!     the KERNEL   is shared by three.
//!
//! The comptime panel draws its fractal in characters by calling `escape` directly. The
//! other three draw the same fractal in pixels by calling it from here. You can see the
//! same shape twice, and nobody has to tell you the function is the invariant.
const k = @import("kompute");
const escape = @import("escape.zig").escape;

/// 128x96 = 12288 pixels. Big enough that the main-thread CPU pass VISIBLY hitches (which
/// is the point of the `.worker` panel), small enough that the whole `Buffers` image is
/// 48 KB — so shipping it to a worker and back costs microseconds, not milliseconds.
pub const width: u32 = 128;
pub const height: u32 = 96;
pub const pixels: u32 = width * height;

pub const config = k.Config{ .max = pixels, .workgroup = 64 };

/// ONE buffer. The `.worker` backend copies the whole `Buffers` image both ways on every
/// dispatch, so a module that wants a worker arm should keep its state modest — 48 KB here.
/// (A megabyte of particles you wanted stepped every frame is what `.gpu` is for.)
pub const Buffers = extern struct {
    out: [pixels]u32,
};

/// `extern`: these bytes are memcpy'd out of the app's wasm and into the KERNEL's wasm —
/// two separate compilations — and Zig's auto layout is explicitly free to reorder fields.
/// It is deterministic for one compiler and target, so auto would work today, by luck.
/// `extern` is what the language provides for "these bytes cross a boundary".
pub const Params = extern struct {
    max_iter: u32,
    w: u32,
    h: u32,
    _pad: u32 = 0,
    cx: f32,
    cy: f32,
    zoom: f32,
    _pad1: f32 = 0,
};

pub const g = k.Globals(@This());

/// Named here so the worker's kernel wasm knows what to export, and so `komputeTable` can
/// derive a job kernel per name. (This Zig's `@typeInfo` has no `.decls`, so the list has
/// to be written down — `installKernels` reads the same one.)
pub const kernels = [_][:0]const u8{"mandel"};

const b_out = g.bind(.out);

/// id -> pixel -> complex plane -> `escape`. That last call is the only line that matters.
pub fn mandel(c: k.Ctx(@This())) void {
    const i: u32 = c.id;
    if (i >= c.params.w * c.params.h) {
        return;
    }
    const px: u32 = i % c.params.w;
    const py: u32 = i / c.params.w;

    const fx: f32 = @floatFromInt(px);
    const fy: f32 = @floatFromInt(py);
    const fw: f32 = @floatFromInt(c.params.w);
    const fh: f32 = @floatFromInt(c.params.h);

    // Pixel -> the complex plane, centred on (cx, cy).
    const u: f32 = (fx / fw - 0.5) * 3.0 / c.params.zoom;
    const v: f32 = (fy / fh - 0.5) * 2.2 / c.params.zoom;

    b_out[i] = escape(c.params.cx + u, c.params.cy + v, c.params.max_iter);
}

comptime {
    k.installKernels(@This());
}
