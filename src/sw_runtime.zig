//! src/sw_runtime.zig - single-module entry point for native
//! consumers of the software-renderer + codec pieces.  Bundles
//! `raster`, `raster_shader`, `codecs`, and `shader_connect` so they
//! share one module (avoiding Zig 0.16's one-file-per-module rule -
//! they all transitively import `types.zig`).
//!
//! Consumers import this and reach internals via `bundle.raster.X`,
//! `bundle.raster_shader.Y`, `bundle.codecs.png.Z`, and
//! `bundle.autoConnect(VsOut, FsIo)`.

pub const raster = @import("raster.zig");
pub const raster_shader = @import("raster_shader.zig");
pub const codecs = @import("codecs.zig");
pub const autoConnect = @import("shader_connect.zig").autoConnect;

// GL-retirement P2 additions: the native SW demos (sw_mandelbrot, sw_julia,
// julia_gallery) migrated here from the GL `zimr` umbrella - this is their
// whole remaining surface.
pub const gpu_iface = @import("gpu_iface.zig");
pub const shader_runtime = @import("shader_runtime_wgpu.zig");
pub const wgpu = @import("wgpu.zig");
/// Engine 2D shapes shader pair (vs+fs) for native consumers - the former
/// default_shapes_bundle.zig, inlined here (structure-plan S2).  One
/// umbrella keeps the shared common_io inside a single module's graph.
pub const default_shapes = struct {
    pub const vs = @import("shaders/default_shapes_vs.zig");
    pub const fs = @import("shaders/default_shapes_fs.zig");
};
/// 2D renderer helpers (orthoTopLeft etc.) - already in this module's
/// graph via shader_runtime; re-exported for the native demos.
pub const renderer_2d = @import("renderer_2d.zig");
