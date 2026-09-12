//! examples/launcher/kernels.zig — ONE kernel wasm for a page that bundles many examples.
//!
//! A page carries exactly one `ZIMR_KERNEL_WASM`. The launcher carries a dozen examples, two
//! of which have job kernels — so its kernel wasm has to serve both at once.
//!
//! It can, and cheaply, because the wasm exports are keyed by NAME (`zimr_job_encodePng`,
//! `zimr_job_mandel`) rather than by an index or a hash. A merged wasm exports a SUPERSET of
//! the names, so each example's `submit` finds its own kernel and nobody renumbers anything.
//! Had the design kept a hashed dispatch table, merging two registries would have meant
//! merging two id spaces — and this file could not exist.
//!
//! The table below is written by hand rather than concatenated with `++`, and that is a
//! limitation of the Zig, not the design: every kernel carries its own header type in its
//! signature (`Size` for the encoder, `JobHeader(M)` for the kompute one), so `++` on two
//! kernel TABLES has no common element type. Tuples would concatenate — but this Zig
//! (0.17.0-dev.1282) has no `@Type`, no `std.meta.Tuple`, and `@Struct` with numeric field
//! names yields something that does not support indexing. Two entries are cheap to write out;
//! when the language grows the tuple back, this becomes `a.job_kernels ++ b.job_kernels`.
const z = @import("zimr");

const jobs = z.jobs;

/// The examples on the launcher that have job kernels.
///
/// `four_ways` is the interesting one: it is the only example with BOTH `compute_kernels` and
/// `job_kernels`, and for a long time it could not be here at all. Not because of anything to
/// do with jobs — because `wireComputeKernels` minted a FRESH `kompute` module per example.
/// One compute example per page hid that completely. Two of them on one page (which is what a
/// launcher IS) gave Zig two distinct modules rooted at the same `src/kompute.zig`, so it
/// renamed the second to `kompute0` and then refused the file for belonging to both. The error
/// it printed named `escape_kernel.zig`, which is the import that tripped over it — not the
/// cause. The build now shares one kompute module, and the cap is gone.
const png = @import("k_worker_png");
const four = @import("k_four_ways");

/// The merged table.
///
/// `four_ways`' entry is DERIVED: `komputeKernel(module, "mandel")` builds the job wrapper and
/// its header type from the kompute module itself, so the same Zig function that runs on the
/// GPU as a compute shader runs here as a worker job, and neither spelling can drift from the
/// other.
pub const job_kernels = .{
    .{ "encodePng", png.encodePng },
    .{ "mandel", z.komputeKernel(four.module, "mandel") },
};

/// The bounds are the MAX over the members: one buffer serves every kernel on the page, so it
/// has to fit the largest input and the largest output any of them can present. A `max_input`
/// that is too small does not fail loudly at build time — it fails as `Error.InputTooLarge` on
/// a phone, which is exactly the kind of thing this should not be guessing at.
pub const registry = jobs.Registry(job_kernels, .{
    .max_input = @max(png.registry.max_input, four.registry.max_input),
    .max_output = @max(png.registry.max_output, four.registry.max_output),
});
