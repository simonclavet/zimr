//! src/shaders/normalmap_fs_io.zig - IO schema for the simple normal-map
//! shader (`shaders_normalmap_rendering`). It deliberately REUSES the PBR
//! fragment IO - the same samplers (base color + normal + ...), the same UBO
//! (view_pos, ambient, directional lights, col_diffuse), and the same
//! interpolated varyings (world pos / normal / tangent / uv). Sharing the
//! layout means this shader drops straight into the `pbr3d` renderer via
//! `Renderer.init(.{ .fs_wgsl = normalmap_fs_wgsl })` with an identical
//! bind-group layout - only the fragment BODY differs (a clear Blinn-Phong
//! normal-map lighting model instead of full metallic-roughness PBR), which is
//! exactly the point of a "here's what a normal map does" shaders example.
pub const pbr = @import("pbr_fs_io.zig");

pub const Inputs = pbr.Inputs;
pub const Samplers = pbr.Samplers;
pub const Ubo = pbr.Ubo;
pub const Outputs = pbr.Outputs;
