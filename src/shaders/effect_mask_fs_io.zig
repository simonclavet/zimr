//! src/shaders/effect_mask_fs_io.zig - two-source blend, with a mask.
//!
//! The first effect in the family to read MORE THAN ONE texture, which is the
//! whole point of it: raylib's `shaders_simple_mask` and `shaders_multi_sample2d`
//! are both "sample several textures in one fragment shader and combine them",
//! and neither is expressible with the single-`texture0` schema the other effects
//! share.
//!
//! Slots are EXPLICIT (`Sampler2D_atSlot`) rather than borrowed from the material
//! semantics (`.albedo` / `.metalness` / `.normal`): these are three peer sources,
//! not a base colour and a metalness map, and naming them after PBR channels would
//! be a lie that the next reader has to decode.
//!
//! Binding layout the DSL generates from this (checked against the PBR shader's
//! WGSL, which lays out its samplers the same way):
//!
//!     @group(1) @binding(0) tex_a     @binding(1) tex_a_sampler
//!     @group(1) @binding(2) tex_b     @binding(3) tex_b_sampler
//!     @group(1) @binding(4) tex_mask  @binding(5) tex_mask_sampler

const zm = @import("zm");
const Vec = zm.Vec;
const shader = @import("shader_interface");
const common = @import("effect_common_io.zig");

pub const Inputs = common.Inputs;
pub const Outputs = common.Outputs;

pub const Samplers = struct {
    tex_a: shader.Sampler2D_atSlot(0, .{}),
    tex_b: shader.Sampler2D_atSlot(1, .{}),
    tex_mask: shader.Sampler2D_atSlot(2, .{}),
};

/// `params` = {mode, divider, softness, 0}
///   mode     - 0 = MASK (blend by the mask texture's luminance)
///              1 = DIVIDER (hard split; `divider` is the split's x, in UV)
///   divider  - the split position, 0..1, when mode = 1
///   softness - width of the divider's feather, in UV. 0 gives raylib's hard cut.
pub const Ubo = struct {
    params: Vec = .{ 0, 0.5, 0.0, 0 },
};
