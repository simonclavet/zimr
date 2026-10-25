//! examples/goban/kernels.zig - goban's job kernels: the search for the computer's move.
//!
//! The build requires this file of an app with jobs, and compiles it into the separate kernel wasm the workers run,
//! which must import nothing. The search, and its registry, are in `goban.zig`, section 7 (`searchJob`,
//! `search_job_registry`): this file only lists them. The kernel reaches only the rules and the search, which touch
//! nothing of the engine, so nothing impure is compiled into it.
const goban = @import("goban.zig");

/// goban's kernels, by name: the wasm export of each is `zimr_job_<name>`.
pub const job_kernels = goban.search_job_kernels;

/// The registry goban submits its jobs through; the launcher's merged registry reads its bounds.
pub const registry = goban.search_job_registry;
