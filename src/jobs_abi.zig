//! lint:alias jobs_abi
//! src/jobs_abi.zig — the names the three sides of the jobs system must agree on.
//!
//! THREE sides, and that is why this file exists on its own:
//!
//!   * `src/jobs.zig`        compiles into the KERNEL WASM, and `@export`s these names.
//!   * `src/jobs_worker.zig` compiles into the WORKER'S JS, and calls them.
//!   * `src/bridge.zig`      compiles into the PAGE'S JS, and speaks the message protocol.
//!
//! They are three separate compilations that never link against each other. Before this file,
//! each name was a string literal in Zig AND a second string literal in hand-written
//! JavaScript, with nothing checking that the two agreed. Rename one and the worker fails
//! SILENTLY — no error, no result, a job that simply never comes back.
//!
//! WHY THE CONSTANTS ARE NOT IN jobs_worker.zig, WHERE THEY WERE FIRST WRITTEN.
//!
//! They were, for about ten minutes, and the build stopped it:
//!
//!     error: kernel wasm imports 'env.js_global' — a job kernel must be PURE.
//!
//! `jobs.zig` needs these names, and `jobs.zig` is linked into the kernel wasm. Importing them
//! from `jobs_worker.zig` dragged that file's `extern fn js_global` (and the rest of the
//! browser interop) along with them — into a wasm that is required to have ZERO imports so a
//! bare `{}` can instantiate it. The purity check in c2js caught it immediately, which is
//! precisely the job it was written for.
//!
//! So: the NAMES live here, where anything may import them. The BROWSER CODE lives in
//! jobs_worker.zig, where only the worker imports it.

/// The kernel wasm's linear memory, as a JS object with a `.buffer`.
///
/// CRITICAL: re-read `.buffer` AFTER EVERY call into the kernel. Growing a wasm memory
/// DETACHES the old ArrayBuffer, so any view taken beforehand is dead — and it dies silently,
/// as a zero-length read. This is the classic wasm-in-JS bug.
pub const memory = "memory";

/// `alloc(n) -> ptr`. Reserve n bytes inside the kernel wasm for the incoming job. 0 on
/// failure.
pub const alloc = "zimr_job_alloc";

/// `zimr_job_<name>(n) -> len`. ONE EXPORT PER KERNEL — no id, no dispatch table — so a job
/// physically cannot reach the wrong kernel. `len >= 0` is the result size in bytes; `len < 0`
/// means the kernel returned a Zig error.
pub const kernel_prefix = "zimr_job_";

/// `out_ptr() -> ptr`. Where the result was written. Only meaningful after a successful run.
pub const out_ptr = "zimr_job_out_ptr";

/// `err_ptr()` / `err_len()`. The kernel's error NAME as UTF-8, so a failure reads
/// "ShortPayload" rather than a bare "-1".
pub const err_ptr = "zimr_job_err_ptr";
pub const err_len = "zimr_job_err_len";

/// Message tags. The host sends `init` and `job`; the worker replies `ready` and `done`.
pub const msg = struct {
    pub const init = "init";
    /// The host will NOT dispatch a job to a worker that has not sent this.
    ///
    /// The worker always sent it. The host used to THROW IT AWAY — the message carries no
    /// job handle, so it fell through a `handle >= 1` guard and vanished. Nothing knew when a
    /// worker had finished instantiating, so `pump()` would hand a job to one that could not
    /// yet run it.
    pub const ready = "ready";
    pub const job = "job";
    pub const done = "done";
};

/// Failures the WORKER itself reports, as distinct from a kernel's own error.
pub const worker_errors = struct {
    pub const not_ready = "WorkerNotReady";
    pub const no_such_kernel = "NoSuchKernel";
    pub const out_of_memory = "OutOfMemory";
};
