//! src/shaders/default_shapes_fs.zig - Zig source for the wgpu
//! engine's default 2D fragment shader.  Replaces the hand-written
//! the engine-emitted `default_shapes_fs.wgsl` -
//! same effect (sample texture x per-vertex color), now compiled
//! through the typed shader pipeline -> SPIR-V -> spv2wgsl -> embedded
//! `.wgsl`.  See `src/notes/webgpu-migration-plan.md` section 3 Phase C
//! for context.
//!
//! Single shader serves both UN-textured AND textured drawing.
//! Untextured draws bind the engine's 1x1 white texture (see
//! `src/wgpu_texture.zig::createWhite1x1`); sampling white is
//! essentially identity, so the per-vertex color survives unchanged.
//! Saves a shader swap when toggling textures on/off.

const zm = @import("zm");
const Vec = zm.Vec;
const shader_externs = @import("default_shapes_fs_externs");

/// Fragment shader has no UBO - its only per-frame inputs are the
/// interpolated varyings (uv, color) and the bound texture sampler.
/// `IoT(void)` produces an Io with no `.u` field; codegen recognises
/// the empty case.
pub const Io = shader_externs.IoT(void);
pub const Out = shader_externs.Out;
/// Re-export the codegen-emitted TextureRef so native consumers
/// can construct a `_texture0` field without poking at the
/// shader_externs module directly.  Same convention as
/// `examples/cube_split_fs.zig` and `examples/shader_chroma_fs.zig`.
pub const TextureRef = shader_externs.TextureRef;

/// Pure-logic kernel.  Sample the bound texture at the interpolated
/// UV; multiply by the interpolated tint; that's the fragment colour.
/// Same shape as the legacy hand-written WGSL:
///   let sample = textureSample(t_albedo, s_albedo, in.uv);
///   return sample * in.color;
///
/// On SPIR-V the texture0 accessor is a native `OpSampledImage` +
/// `OpImageSampleImplicitLod` on the generated texture0 / texture0_sampler
/// handles.  On wgpu via spv2wgsl that translates to
/// `textureSample(texture0, texture0_sampler, uv)`
/// - handled by spv2wgsl's `emitImageSample`.  On CPU via
/// `raster_shader.dispatchFragmentShader` this calls
/// `io_in.texture0(uv)` which the raster pixel pipeline implements
/// via nearest-neighbour sampling of the bound texture's bytes.
pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;
    const sample: Vec = io_in.texture0(io_in.frag_tex_coord);
    out.out_color = sample * io_in.frag_color;
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
