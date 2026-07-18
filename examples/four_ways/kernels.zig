//! examples/four_ways/kernels.zig — the worker's half, and it is FOUR LINES of substance.
//!
//! Compare `examples/worker_png/kernels.zig`: that one hand-writes its kernel function, its
//! header type, its table, and guesses `max_input`/`max_output`. It has to — `encodePng` is
//! an ordinary function, not a data-parallel kernel, so there is nothing to derive it from.
//!
//! A kompute module is different. Everything the jobs system needs is ALREADY declared on
//! it, so `komputeRegistry` derives the lot:
//!
//!   * the kernel functions — one per name in `M.kernels`, each wrapping the same `while`
//!     loop over ids that the `.cpu` backend runs;
//!   * the header type      — `{ n: u32, params: M.Params }`;
//!   * the bounds           — EXACTLY `@sizeOf(Hdr) + @sizeOf(M.Buffers)` in and
//!     `@sizeOf(M.Buffers)` out. Not a guess. Not a knob.
//!
//! So the app-author cost of giving an existing compute kernel a worker backend is: this
//! file, plus `.job_kernels = true` in build.zig, plus changing `initGpu` to `initWorker`.
//! **That is the feature.** The demo is downstream of it.
//!
//! This file is compiled TWICE — into the app (so `submit` knows the header type, checked at
//! comptime) and into a separate freestanding kernel wasm with ZERO imports, which the Web
//! Workers instantiate with `{}`. The build ASSERTS that import section is empty, so a
//! kernel that reaches for the DOM fails to build rather than failing on a phone.
const zimr = @import("zimr");

/// The kompute module. Note it is the SAME file the GPU path compiles to SPIR-V — one
/// module, three runtime machines.
pub const module = @import("escape_kernel.zig");

/// Everything below is derived. There is nothing to configure and nothing to keep in sync.
pub const registry = zimr.komputeRegistry(module);

/// Exposed so registries COMPOSE: the launcher bundles many examples into one kernel wasm
/// and needs a single table.
///
///     jobs.Registry(worker_png.job_kernels ++ four_ways.job_kernels, .{})
///
/// This works only because the wasm exports are keyed by NAME rather than an index or a
/// hash — a merged kernel wasm satisfies every example's `submit` with nobody renumbering.
pub const job_kernels = zimr.komputeTable(module);
