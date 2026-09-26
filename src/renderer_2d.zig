//! lint:alias renderer_2d
// src/renderer_2d.zig - the raylib-parity drawing layer.
// WebGPU architecture is documented centrally in src/zimr.zig
// (the module-level `//!` doc) - read that before changing wgpu code.
//
//
// `Renderer2D` owns the resources needed for 2D drawing:
//
//   - The default shapes shader - TWO modules (VS + FS), each
//     compiled from a separate WGSL file produced by the engine's
//     typed shader pipeline (`src/shaders/default_shapes_vs.zig`
//     and `src/shaders/default_shapes_fs.zig`).  Rule 1 of the
//     wgpu migration plan: no hand-written WGSL.
//   - A 1x1 white texture (the "shapes" texture).
//   - The per-frame UBO buffer (group 0, binding 0) - currently
//     just the view-projection matrix.
//   - The per-frame and per-material bind groups.
//   - The shapes batch's GPU buffers (vertex + index).
//
// One `Renderer2D` per zimr app.  Lives on the user's `State`.
// `bindForPass` takes a `*PassState` from `gpu_iface` (since the
// May-2026 "mach move").
//
// Bind-group layout:
//   - Group 0 binding 0: per-frame UBO (vertex visibility).  The VS
//     shader declares `view_projection: [4]@Vector(4,f32)` in its
//     Ubo struct; the WGSL output lives at `@group(0) @binding(0)`.
//   - Group 1 binding 0: texture (fragment visibility).  Routed
//     through the engine's `--sampler-group=1` build flag (see
//     `src/shader_codegen.zig`) so the FS WGSL declares its texture at
//     `@group(1) @binding(0)`, dodging the VS UBO at group 0.
//   - Group 1 binding 1: sampler (fragment visibility), adjacent
//     to the texture in the same group.

const std = @import("std");
const gpu = @import("gpu.zig");
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectEqual = std.testing.expectEqual;
const Allocator = std.mem.Allocator;
const zm = @import("zm");
const assert = zm.assert;

// Structure-plan S0: the batch data layer lives in gpu_iface now (leaf);
// re-exported here so the renderer's public API is unchanged.
pub const Vertex2D = @import("gpu_iface.zig").Vertex2D;
pub const ShapesBatch = @import("gpu_iface.zig").ShapesBatch;
pub const max_batch_vertices = @import("gpu_iface.zig").max_batch_vertices;
pub const max_batch_indices = @import("gpu_iface.zig").max_batch_indices;
pub const vbo_ring_vertices = @import("gpu_iface.zig").vbo_ring_vertices;
pub const ibo_ring_indices = @import("gpu_iface.zig").ibo_ring_indices;
const wgpu = @import("wgpu.zig");
const wgpu_texture = @import("wgpu_texture.zig");
const shader = @import("shader_interface");
const shader_runtime = @import("shader_runtime_wgpu.zig");
const assertf = zm.assertf;

/// Slots in the per-frame ortho ring - the max projection switches one
/// frame can record (frame begin + one per beginTextureMode + one per
/// reopen2DPass).  UI-heavy frames reopen a handful of times; 32 gives
/// generous headroom at 2 KB total (32 x 64 B).
pub const ortho_ring_len: u32 = 32;

// Engine VS+FS IO modules - imported here so `Renderer2D.shapes_pipeline`
// can carry the comptime VS+FS types via `RenderPipeline(VsIoT, FsIoT)`.
// Turn 2 of finishing_new_gpu_foundations.md: the typed pipeline gives
// the SW backend a comptime path to the shader's Io/Out types, which
// it needs to dispatch the shader on the CPU side (turn 3).
//
// Note: we use the IO modules (not the body modules) as the type
// parameters because the body modules' externs use
// `addrspace(.constant)` which is SPIR-V-only - not native-importable.
// Turn 3 closes the loop by either (a) exposing a native-target
// build of the body modules, or (b) wiring the IO modules to carry
// `pub const shaderMain` pointers via codegen.
const default_shapes_vs_io = @import("shaders/default_shapes_vs_io.zig");
const default_shapes_fs_io = @import("shaders/default_shapes_fs_io.zig");

const WgpuTexture = wgpu_texture.WgpuTexture;
const GpuFrame = gpu.GpuFrame;

/// The merged engine schema - combines the VS UBO + FS samplers
/// into a single resource schema that drives the engine's bind
/// groups via `Resources(EngineSchema)`.  Declared here (rather than
/// imported from `default_shapes_*_io.zig`) to keep the engine
/// schema co-located with the renderer that uses it, and to avoid
/// dragging the IO files into the runtime module dep tree (they're
/// only meant to be consumed at build time by the codegen).
///
/// Field types and counts MUST stay in sync with the actual VS+FS
/// IO files; the solver-generated WGSL would mismatch otherwise.
pub const EngineSchema = struct {
    /// Per-frame view-projection matrix.  Equivalent shape to
    /// `default_shapes_vs_io.Ubo` - extern struct with one mat4 field.
    pub const Ubo = struct {
        view_projection: [4]@Vector(4, f32) = .{
            .{ 1, 0, 0, 0 },
            .{ 0, 1, 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ 0, 0, 0, 1 },
        },
    };

    /// One sampler - engine 2D shapes uses a single texture (white-1x1
    /// by default; user textures swap in via `Resources.set`).
    /// Equivalent to `default_shapes_fs_io.Samplers`.
    pub const Samplers = struct {
        texture0: shader.Sampler2D(.albedo, .{}),
    };
};

/// Engine VS WGSL - built by the typed shader pipeline from
/// `src/shaders/default_shapes_vs.zig`.  Declares `@group(0)
/// @binding(0)` for the view-projection UBO, entry-point `entry`.
const default_shapes_vs_wgsl = @embedFile("default_shapes_vs.wgsl");

/// Engine FS WGSL - built by the typed shader pipeline from
/// `src/shaders/default_shapes_fs.zig`.  Declares `@group(1)
/// @binding(0/1)` for texture + sampler (via `--sampler-group=1`),
/// entry-point `entry`.
const default_shapes_fs_wgsl = @embedFile("default_shapes_fs.wgsl");

// ============================================================================
// SECTION 1 - per-frame UBO type
// ============================================================================

pub const PerFrameUbo = extern struct {
    /// Column-major mat4x4 - the view-projection matrix used by every
    /// 2D draw call.  Updated once per frame at `beginFrame2D`.
    view_projection: [16]f32 = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    },
};

// ============================================================================
// SECTION 1B - MatrixStack + ShapesBatch (the drawing-layer state machine)
// ============================================================================
//
// These used to live on `GpuFrame`, but they're drawing-layer
// concerns, not GPU-trait concerns.  Moved here in step #6 of the
// May-2026 birds-eye plan so `Renderer2D` owns them outright - the
// GpuFrame stays a thin "long-lived GPU resources" container, and
// `gpu_iface` no longer has to know about matrix stacks or batched
// shape buffers.

/// Maximum depth of the matrix stack.  raylib defaults to 32; we
/// match.  Stack overflow panics with a clear message.
pub const max_matrix_stack: u8 = 32;

const identity_mat4: [16]f32 = .{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
};

pub const MatrixStack = struct {
    matrices: [max_matrix_stack][16]f32 = @splat(identity_mat4),
    top: u8 = 0,
    /// True when the top matrix has been modified since the last GPU
    /// upload.  Set by translate/rotate/scale/multMatrix; cleared by
    /// the drawing path after re-uploading the MVP UBO.
    dirty: bool = false,

    pub fn reset(self: *MatrixStack) void {
        self.top = 0;
        self.matrices[0] = identity_mat4;
        self.dirty = true;
    }

    pub fn push(self: *MatrixStack) void {
        assert(self.top < max_matrix_stack - 1, @src());
        self.matrices[self.top + 1] = self.matrices[self.top];
        self.top += 1;
    }

    pub fn pop(self: *MatrixStack) void {
        assert(self.top > 0, @src());
        self.top -= 1;
        self.dirty = true;
    }

    pub fn current(self: *const MatrixStack) [16]f32 {
        return self.matrices[self.top];
    }

    pub fn setCurrent(self: *MatrixStack, m: [16]f32) void {
        self.matrices[self.top] = m;
        self.dirty = true;
    }
};

/// Cap on textures registered for the gl_iface `setTexture(id)` bridge (a font
/// atlas + a handful of user textures; ids 1..N, 0 = white/untextured).
pub const max_registered_textures: u32 = 64;
/// Sprite GPU residency cache capacity (bounded by the texture registry above).
const max_sprite_residency: usize = 64;

// ============================================================================
// SECTION 2 - Renderer2D
// ============================================================================

/// Build a material bind group (group 1) for the given texture.
/// Used at Renderer2D init and any time the user binds a new texture.
///
/// Texture lands at binding 0, sampler at binding 1 - matches the
/// FS WGSL declaration produced with `--sampler-group=1`.
pub fn buildMaterialBindGroup(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    layout: wgpu.BindGroupLayoutHandle,
    tex: WgpuTexture,
) !wgpu.BindGroupHandle {
    const entries: []const gpu.BindGroupEntry = &.{
        .{ .binding = 0, .resource = .{ .texture_view = tex.view } },
        .{ .binding = 1, .resource = .{ .sampler = tex.sampler } },
    };
    const blob: []const u8 = try gpu.encodeBindGroupEntries(gpa, entries);
    defer gpa.free(blob);
    return wgpu.createBindGroup(device, layout, blob, "material");
}

/// The 2D batch's vertex layout: position (2xf32), uv (2xf32), packed colour (4xu8) = 20 bytes.
///
/// A free function, NOT a literal inlined at each use, because `Shader2D` builds a user
/// pipeline against this exact layout. Two copies would drift silently - a mismatched
/// `array_stride` does not raise an error, it reads the wrong bytes as vertices.
pub fn shapesVertexBufferLayout() gpu.VertexBufferLayout {
    return .{
        .array_stride = 20,
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x2, .offset = 8, .shader_location = 1 },
            .{ .format = .uint8x4_unorm, .offset = 16, .shader_location = 2 },
        },
    };
}

pub const Renderer2D = struct {
    gpa: Allocator,

    // Shaders + pipeline.  Two separate modules - engine emits VS
    // and FS WGSL as independent files.
    shapes_vs_module: wgpu.ShaderModuleHandle = .invalid,
    shapes_fs_module: wgpu.ShaderModuleHandle = .invalid,

    /// Typed render pipeline (turn 2 of finishing_new_gpu_foundations.md).
    /// Wraps `wgpu.RenderPipelineHandle` with the comptime VS+FS IO
    /// module types so the SW backend (turn 3) can find the shader
    /// dispatch entry points.  On the wgpu side, this is bit-for-bit
    /// equivalent to a raw handle - `setPipeline` extracts
    /// `.gpu_handle` and binds it.
    shapes_pipeline: shader_runtime.RenderPipeline(
        default_shapes_vs_io,
        default_shapes_fs_io,
    ) = .{},
    shapes_pipeline_layout: wgpu.PipelineLayoutHandle = .invalid,

    /// One shapes pipeline per BlendMode (indexed by @intFromEnum), all built at
    /// setup and sharing the VS/FS modules + layout. beginBlendMode switches
    /// `shapes_pipeline` between these. Default = blend_pipes[.alpha].
    blend_pipes: [5]wgpu.RenderPipelineHandle = .{ .invalid, .invalid, .invalid, .invalid, .invalid },

    /// The formats the shapes pipelines were built against.
    ///
    /// Kept because `Shader2D` must build the USER's pipeline with the same ones. The depth
    /// part is the trap: when the app has no depth target the pipeline must declare NO depth
    /// state, or it is incompatible with the depth-less pass it is bound into - and WebGPU
    /// rejects the entire command buffer, not just the offending draw.
    backbuffer_format: wgpu.TextureFormat = .rgba8_unorm,
    depth_format: ?wgpu.TextureFormat = null,

    /// The blend mode in force, so `endShaderMode` knows what to go BACK to.
    ///
    /// Without this, leaving a user shader would silently reset the blend to `.alpha` -
    /// so `beginBlendMode(.additive)` ... `beginShaderMode` ... `endShaderMode` would drop
    /// the additive blend on the floor and nothing would say why.
    active_blend: wgpu.BlendMode = .alpha,

    /// All bind-group state for the engine's shapes pipeline - UBO
    /// at group 0 + sampler at group 1.  Replaces the hand-wired
    /// `per_frame_bgl`/`material_bgl`/`per_frame_ubo`/
    /// `per_frame_bind_group`/`white_material_bind_group` fields
    /// of the pre-turn-1 shape.  See the `EngineSchema` decl above
    /// for the resource shape.
    resources: shader_runtime.Resources(EngineSchema) = undefined,

    // Built-in 1x1 white texture.  Owned separately from `resources`
    // because the user can replace it via `Resources.set(.texture0,
    // their_tex)` and we want a reset-to-default path.
    white_tex: WgpuTexture = .{},

    // GPU buffers for the shapes batch
    batch_vbo: wgpu.BufferHandle = .invalid,
    batch_ibo: wgpu.BufferHandle = .invalid,

    /// Drawing-layer state machine.  Owns the per-frame matrix
    /// transform stack (raylib-parity `pushMatrix`/`translate`/
    /// `rotate`/etc.) and the accumulating shapes batch (filled by
    /// `gpu_iface.drawQuadBatched`/`drawTriangleBatched`, drained
    /// by `gpu_iface.flushBatch`).  Pre step #6 these lived on
    /// `GpuFrame`; they're here now because they're drawing
    /// concerns, not GPU concerns, and the user already holds the
    /// `Renderer2D` they belong to.
    matrix_stack: MatrixStack = .{},
    shapes_batch: ShapesBatch = .{},

    // ---- The per-frame ortho RING ----
    //
    // `queue.writeBuffer` calls all execute BEFORE the frame's single
    // encoder submit, so writing ONE ubo several times in a frame means
    // only the LAST matrix survives - and it applies to EVERY pass
    // segment, including ones already recorded.  The shapes batch
    // solved this exact hazard for VERTEX data with a ring (see
    // `flushBatch`: "queue-timeline writes clobber each other");
    // the ortho UBO needs the same medicine, because
    // `beginTextureMode` and every `reopen2DPass` legitimately switch
    // the projection mid-frame.  Each `updatePerFrame` call now writes
    // the NEXT slot and `bindForPass` binds that slot's bind group, so
    // every pass segment keeps the matrix it was recorded with.
    // (The zimr516 shader_effects "duplicated grid" glitch was this.)
    ortho_ring_bufs: [ortho_ring_len]wgpu.BufferHandle = @splat(.invalid),
    ortho_ring_bgs: [ortho_ring_len]wgpu.BindGroupHandle = @splat(.invalid),
    /// Index of the slot holding the CURRENT projection (the one
    /// `bindForPass` binds).  Advanced by `updatePerFrame`.
    ortho_cursor: u32 = 0,
    /// Ortho writes within the CURRENT encoder - asserted <= ring
    /// length, because a wrap within one encoder would clobber a slot
    /// an earlier recorded pass segment still references (the exact
    /// bug the ring prevents).  The budget resets automatically when
    /// the frame's encoder changes (encoder handles are monotonic on
    /// both the real bridge and the smoke mock), so NO per-frame call
    /// is required of the app - the reset is structural.
    ortho_writes_this_frame: u32 = 0,
    ortho_ring_encoder: wgpu.CommandEncoderHandle = .invalid,

    // Texture-id registry: the gl_iface trait's `setTexture(id: u32)` (and the
    // reusable text/texture stack in drawing.zig, which is generic over `gl`)
    // identifies textures by a small integer id, like the GL backend. The wgpu
    // backend has no such ids natively, so we hand them out here: registerTexture
    // returns the next id and stores the WgpuTexture + its material bind group;
    // setTexture(id) on WgpuGl looks it up. id 0 is reserved (= the built-in
    // white texture / untextured). Caps at max_registered_textures (plenty for a
    // font atlas + a handful of user textures).
    registered_textures: [max_registered_textures]WgpuTexture = @splat(.{}),
    registered_bind_groups: [max_registered_textures]wgpu.BindGroupHandle = @splat(.invalid),
    // Which registrations the ENGINE created + owns (e.g. a font atlas): those
    // textures must be DESTROYED on resetRegistry. Example-drawn textures are
    // owned by the example (freed via its WgpuTexture.deinit) -> owned=false, so
    // resetRegistry frees only their bind group, never the texture.
    registered_owned: [max_registered_textures]bool = @splat(false),
    // Per-CHILD attribution for the launcher: which child "gen" registered each
    // slot (0 = engine / launcher-fixed, never released). `releaseOwner(gen)`
    // clears exactly one child's registrations, so sibling apps in a shared
    // registry (the 2x2 grid) are untouched. Registrations made while
    // `current_reg_owner` is set (the launcher wraps a child's init+update) are
    // tagged with it.
    registered_owner: [max_registered_textures]u32 = @splat(0),
    // lint:off module-var: n/a (this is a struct field)
    current_reg_owner: u32 = 0,
    // Free-list of reclaimable ids, so repeated register/release (launcher
    // reset) reuses slots and the registry can't march to the cap.
    reg_free: [max_registered_textures]u32 = @splat(0),
    reg_free_len: u32 = 0,
    registered_count: u32 = 1, // id 0 reserved for white/untextured
    // Sprite GPU residency: sprite.id (monotonic) -> registered texture id, so a
    // Sprite uploads + registers once. Cleared with the registry (resetRegistryFrom).
    sprite_ids: [max_sprite_residency]u64 = undefined,
    sprite_tex: [max_sprite_residency]u32 = undefined,
    sprite_count: usize = 0,

    pub fn init(gpa: Allocator, f: *GpuFrame) !Renderer2D {
        var r: Renderer2D = .{ .gpa = gpa };

        // ---- 1. Load the two engine WGSL modules ----
        //
        // The engine's typed shader pipeline produces these as
        // separate files (see `src/shader_codegen.zig::ShaderPipeline`
        // and `build.zig`'s engine-shader auto-discovery loop).
        // Both have entry-point `entry`; collision is avoided
        // because they live in different modules.  Rule 1 of the
        // wgpu plan: no hand-written WGSL anywhere.
        r.shapes_vs_module = wgpu.createShaderModuleWgsl(
            f.device,
            default_shapes_vs_wgsl,
            "shapes_vs",
        );
        r.shapes_fs_module = wgpu.createShaderModuleWgsl(
            f.device,
            default_shapes_fs_wgsl,
            "shapes_fs",
        );

        // ---- 2. Built-in 1x1 white texture ----
        // Created before Resources.init so we can pass it as the
        // initial `texture0` value.  User-supplied textures swap
        // in later via `r.resources.set(.texture0, their_tex)`.
        r.white_tex = WgpuTexture.createWhite1x1(f.device, f.queue);

        // ---- 3. Resources(EngineSchema) - replaces all the
        // hand-wired BGL/BG construction for both groups.
        //
        // Before turn 1, this block was 50+ LOC of:
        //   - encodeBindGroupLayoutEntries for the UBO group
        //   - createBindGroupLayout per_frame_bgl
        //   - encodeBindGroupLayoutEntries for the material group
        //   - createBindGroupLayout material_bgl
        //   - createBuffer for the UBO + queueWriteBuffer initial
        //   - encodeBindGroupEntries + createBindGroup for UBO BG
        //   - buildMaterialBindGroup for white material BG
        //
        // After turn 1: one `Resources.init` call.  The solver
        // assigns group 0 to the UBO (default for `.ubo` kind),
        // group 1 to the sampler (default for `.sampler_2d`),
        // matching the engine's WGSL layout exactly.
        r.resources = try shader_runtime.Resources(EngineSchema).init(
            gpa,
            f,
            .{
                .initial_ubo = .{}, // identity matrix; updatePerFrame replaces
                .texture0 = r.white_tex,
            },
        );

        // ---- 3b. The per-frame ortho ring (see field docs) ----
        // One 64-byte buffer + one group-0 bind group per slot, all
        // against the SAME layout Resources built for the UBO group, so
        // the pipeline layout below stays untouched.
        for (&r.ortho_ring_bufs, &r.ortho_ring_bgs) |*buf, *bg| {
            buf.* = wgpu.createBuffer(f.device, .{
                .size = shader.wireSizeOf(EngineSchema.Ubo),
                .usage = .{ .uniform = true, .copy_dst = true },
                .label = "renderer2d_ortho_ring",
            });
            const entries = [_]gpu.BindGroupEntry{
                .{ .binding = 0, .resource = .{ .buffer = .{
                    .handle = buf.*,
                    .size = shader.wireSizeOf(EngineSchema.Ubo),
                } } },
            };
            const blob: []const u8 = try gpu.encodeBindGroupEntries(gpa, &entries);
            defer gpa.free(blob);
            bg.* = wgpu.createBindGroup(
                f.device,
                r.resources.bg_layouts[0],
                blob,
                "ortho_ring",
            );
        }

        // ---- 4. Build the pipeline layout (chains both groups) ----
        // The pipeline layout consumes the BGLs Resources just built.
        const bgls: [2]wgpu.BindGroupLayoutHandle = .{
            r.resources.bg_layouts[0],
            r.resources.bg_layouts[1],
        };
        r.shapes_pipeline_layout = wgpu.createPipelineLayout(
            f.device,
            bgls[0..],
            "shapes_pl",
        );

        // ---- 5. Build the render pipeline ----
        r.backbuffer_format = f.backbuffer_format;
        r.depth_format = f.depth_format;

        const default_vbl: gpu.VertexBufferLayout = shapesVertexBufferLayout();
        const blend_modes = [_]wgpu.BlendMode{ .none, .alpha, .additive, .multiply, .premultiplied };
        for (blend_modes) |bm| {
            const state: gpu.StateCombo = gpu.StateCombo.fromParts(
                .triangle_list,
                bm,
                // When a depth target exists (a 3D scene opted in via
                // window.depth_format), the single shared pass carries depth, so 2D
                // pipelines need a matching depth state. compare=always means 2D
                // ignores depth and always draws (HUD over 3D). No depth target -> none.
                if (f.depth_format != null) .always else .none,
                .none,
                f.backbuffer_format,
                f.depth_format orelse .undefined_,
                1,
            );
            const pipe_desc = gpu.RenderPipelineDescriptor{
                .vertex_buffer_layouts = &.{default_vbl},
                .vs_entry_point = "entry",
                .fs_entry_point = "entry",
                .state = state,
            };
            const pipe_blob: []const u8 = try gpu.encodeRenderPipelineDescriptor(gpa, pipe_desc);
            const pipe_handle: wgpu.RenderPipelineHandle = wgpu.createRenderPipeline(
                f.device,
                r.shapes_pipeline_layout,
                r.shapes_vs_module,
                r.shapes_fs_module,
                pipe_blob,
                "shapes",
            );
            gpa.free(pipe_blob);
            r.blend_pipes[@backingInt(bm)] = pipe_handle;
        }
        r.shapes_pipeline = .{ .gpu_handle = r.blend_pipes[@backingInt(wgpu.BlendMode.alpha)] };

        // ---- 6. Batch VBO + IBO ----
        const max_vert_bytes = @as(u64, vbo_ring_vertices) *
            @sizeOf(Vertex2D);
        const max_idx_bytes = @as(u64, ibo_ring_indices) * @sizeOf(u16);
        r.batch_vbo = wgpu.createBuffer(f.device, .{
            .size = max_vert_bytes,
            .usage = .{ .vertex = true, .copy_dst = true },
            .label = "shapes_vbo",
        });
        r.batch_ibo = wgpu.createBuffer(f.device, .{
            .size = max_idx_bytes,
            .usage = .{ .index = true, .copy_dst = true },
            .label = "shapes_ibo",
        });

        // ---- 7. Initialise the drawing-layer state machine ----
        r.matrix_stack.reset();
        r.shapes_batch.vbo = r.batch_vbo;
        r.shapes_batch.ibo = r.batch_ibo;
        r.shapes_batch.current_texture_bind_group = r.resources.bind_groups[1];
        r.shapes_batch.current_shader = r.shapes_pipeline.gpu_handle;

        return r;
    }

    /// Register a texture for the gl_iface `setTexture(id)` bridge: builds its
    /// material bind group, stores both, and returns a small integer id (>=1).
    /// Returns 0 (= white/untextured) if the registry is full. Used by the
    /// font-atlas upload + any user texture drawn through the `gl: anytype`
    /// texture stack (drawTexturePro etc.).
    pub fn registerTexture(self: *Renderer2D, tex: WgpuTexture) u32 {
        // Reuse a freed slot first (bounds the registry under register/release
        // cycles - the launcher reset path); otherwise grow.
        var id: u32 = undefined;
        if (self.reg_free_len > 0) {
            self.reg_free_len -= 1;
            id = self.reg_free[self.reg_free_len];
        } else if (self.registered_count < max_registered_textures) {
            id = self.registered_count;
            self.registered_count += 1;
        } else {
            return 0;
        }
        const bg: wgpu.BindGroupHandle = buildMaterialBindGroup(
            self.gpa,
            self.resources.f.device,
            self.resources.bg_layouts[1],
            tex,
        ) catch return 0;
        self.registered_textures[id] = tex;
        self.registered_bind_groups[id] = bg;
        self.registered_owner[id] = self.current_reg_owner;
        return id;
    }

    /// Release ONE registered texture: destroy its material bind group, free the
    /// texture if the engine owns it (a font atlas does), and recycle the id via
    /// the free list. The single-id counterpart of `releaseOwner`.
    ///
    /// This is what makes re-baking a font safe. Without it, every re-bake
    /// registers a NEW atlas and abandons the old one: the GPU textures pile up
    /// and, once `max_registered_textures` (64) is exhausted, `registerTexture`
    /// returns 0 - the white/untextured slot - so text would silently render as
    /// solid blocks. Callers must flush any pending batch first (the app-level
    /// `unloadFont` does), since staged geometry can still reference the bind
    /// group being destroyed.
    pub fn releaseTextureById(self: *Renderer2D, id: u32) void {
        if (id == 0 or id >= self.registered_count) {
            return; // 0 is the reserved white/untextured slot
        }
        if (self.registered_bind_groups[id] != .invalid) {
            wgpu.destroyBindGroup(self.registered_bind_groups[id]);
            self.registered_bind_groups[id] = .invalid;
        }
        if (self.registered_owned[id]) {
            self.registered_textures[id].deinit();
            self.registered_owned[id] = false;
        }
        self.registered_textures[id] = .{};
        self.registered_owner[id] = 0;
        self.reg_free[self.reg_free_len] = id;
        self.reg_free_len += 1;
        // The staged-material dedup may hold the group we just destroyed.
        self.shapes_batch.current_texture_bind_group = self.resources.bind_groups[1];
    }

    /// Set the owner tag applied to subsequent registrations. The launcher sets
    /// a child's gen around that child's init+update, then 0 again, so the
    /// child's registrations can be released as a unit without touching others.
    pub fn setRegOwner(self: *Renderer2D, owner: u32) void {
        self.current_reg_owner = owner;
    }

    /// Release every registration tagged `owner`: destroy its material bind group
    /// (and, if engine-owned like a font atlas, its texture), then recycle the id
    /// via the free-list. Sibling owners' registrations are untouched - this is
    /// what makes the shared-registry launcher (2x2 grid) leak-tight on a child
    /// reset. No-op for owner 0 (engine / launcher-fixed).
    pub fn releaseOwner(self: *Renderer2D, owner: u32) void {
        if (owner == 0) {
            return;
        }
        var i: u32 = 1;
        while (i < self.registered_count) : (i += 1) {
            if (self.registered_owner[i] != owner) {
                continue;
            }
            if (self.registered_bind_groups[i] != .invalid) {
                wgpu.destroyBindGroup(self.registered_bind_groups[i]);
                self.registered_bind_groups[i] = .invalid;
            }
            if (self.registered_owned[i]) {
                self.registered_textures[i].deinit();
                self.registered_owned[i] = false;
            }
            self.registered_textures[i] = .{};
            self.registered_owner[i] = 0;
            self.reg_free[self.reg_free_len] = i;
            self.reg_free_len += 1;
        }
        self.shapes_batch.current_texture_bind_group = self.resources.bind_groups[1];
    }

    /// Release every per-example texture registration - destroy each material
    /// bind group (id >= 1) and reset the count, keeping only id 0 (the engine
    /// white/untextured group). Called on example teardown so the engine does
    /// NOT retain an example's texture registrations across lifecycles (the
    /// registry-growth leak). The registered textures themselves are owned +
    /// freed by whoever created them (the example's WgpuTexture.deinit); this
    /// only frees the engine-side bind groups that referenced them.
    /// Look up a Sprite's registered texture id (uploaded on first draw); null if
    /// not yet resident. Used by the immediate backend's `image`; see
    /// notes/drawing_api.md.
    pub fn findSprite(self: *Renderer2D, sprite_id: u64) ?u32 {
        var i: usize = 0;
        while (i < self.sprite_count) : (i += 1) {
            if (self.sprite_ids[i] == sprite_id) {
                return self.sprite_tex[i];
            }
        }
        return null;
    }

    /// Record a Sprite's residency (its uploaded, registered texture id).
    pub fn cacheSprite(self: *Renderer2D, sprite_id: u64, tex_id: u32) void {
        if (self.sprite_count < self.sprite_ids.len) {
            self.sprite_ids[self.sprite_count] = sprite_id;
            self.sprite_tex[self.sprite_count] = tex_id;
            self.sprite_count += 1;
        }
    }

    pub fn resetRegistry(self: *Renderer2D) void {
        self.resetRegistryFrom(1);
    }

    /// Release registrations from `base` upward (destroy each material bind group
    /// and, if engine-owned, its texture), resetting the count to `base`. This is
    /// what makes the LAUNCHER leak-tight: it snapshots the registry count before
    /// a child inits and clears from there on the child's teardown, so the child's
    /// registrations go but everything registered earlier (the launcher's own UI,
    /// the engine white texture at id 0) is preserved.
    pub fn resetRegistryFrom(self: *Renderer2D, base: u32) void {
        var i: u32 = base;
        while (i < self.registered_count) : (i += 1) {
            if (self.registered_bind_groups[i] != .invalid) {
                wgpu.destroyBindGroup(self.registered_bind_groups[i]);
                self.registered_bind_groups[i] = .invalid;
            }
            if (self.registered_owned[i]) {
                self.registered_textures[i].deinit();
                self.registered_owned[i] = false;
            }
            self.registered_textures[i] = .{};
            self.registered_owner[i] = 0;
        }
        if (self.registered_count > base) {
            self.registered_count = base;
        }
        // Sprite textures were owned + freed above; forget their residency so they
        // re-upload on next draw.
        self.sprite_count = 0;
        // Count reset supersedes the free-list (all ids >= base are free again).
        self.reg_free_len = 0;
        // The batch may still point at a now-destroyed group; re-arm to white.
        self.shapes_batch.current_texture_bind_group = self.resources.bind_groups[1];
    }

    /// Register a texture the ENGINE owns (destroyed on resetRegistry), e.g. a
    /// font atlas. Same as registerTexture but marks the slot engine-owned.
    pub fn registerOwnedTexture(self: *Renderer2D, tex: WgpuTexture) u32 {
        const id: u32 = self.registerTexture(tex);
        if (id != 0) {
            self.registered_owned[id] = true;
        }
        return id;
    }

    /// Change a registered texture's sampler filter (raylib `SetTextureFilter`).
    /// The filter lives in the SAMPLER, and the sampler is baked into the
    /// texture's material bind group - so switching it means rebuilding both:
    /// new sampler, new bind group, old ones destroyed.
    ///
    /// CALLER MUST FLUSH FIRST (`wgpu_app.setTextureFilter` does): pending
    /// batched geometry can still reference the OLD bind group, and destroying a
    /// handle the command buffer is about to use is an invalid-submit. After the
    /// swap the batch's staged-material dedup is reset to the untextured group so
    /// the next `bindTexture` re-binds rather than short-circuiting on a stale
    /// handle.
    pub fn setTextureFilterById(self: *Renderer2D, id: u32, linear: bool) void {
        if (id == 0 or id >= self.registered_count) {
            return; // 0 is the reserved white/untextured slot
        }
        const tex: *WgpuTexture = &self.registered_textures[id];
        if (tex.view == .invalid) {
            return;
        }
        const device = self.resources.f.device;
        const new_sampler: wgpu.SamplerHandle = wgpu.createSampler(device, .{
            .mag_filter_linear = linear,
            .min_filter_linear = linear,
            .address_mode = .clamp_to_edge,
        });
        // Rebuild the bind group BEFORE destroying anything, so a failure leaves
        // the texture drawable with its old sampler rather than half-swapped.
        const new_bg: wgpu.BindGroupHandle = buildMaterialBindGroup(
            self.gpa,
            device,
            self.resources.bg_layouts[1],
            .{
                .handle = tex.handle,
                .view = tex.view,
                .sampler = new_sampler,
                .width = tex.width,
                .height = tex.height,
                .format = tex.format,
            },
        ) catch {
            wgpu.destroySampler(new_sampler);
            return;
        };
        if (tex.sampler != .invalid) {
            wgpu.destroySampler(tex.sampler);
        }
        if (self.registered_bind_groups[id] != .invalid) {
            wgpu.destroyBindGroup(self.registered_bind_groups[id]);
        }
        tex.sampler = new_sampler;
        self.registered_bind_groups[id] = new_bg;
        // Invalidate the staged-material dedup (it may hold the destroyed group).
        self.shapes_batch.current_texture_bind_group = self.resources.bind_groups[1];
    }

    /// Resolve a registered texture id to its material bind group. id 0 (or any
    /// unregistered id) returns the engine white-texture group (untextured).
    pub fn lookupBindGroup(self: *const Renderer2D, id: u32) wgpu.BindGroupHandle {
        if (id == 0 or id >= self.registered_count) {
            return self.resources.bind_groups[1]; // white / untextured
        }
        return self.registered_bind_groups[id];
    }

    /// Swap the texture behind an already-registered id IN PLACE (a fresh
    /// material bind group around the new view; the id stays stable so
    /// callers' `setTexture(id)` keeps working).  This is what makes a
    /// resizable `CpuFramebuffer` possible - recreate the texture at the
    /// new size, then update the registration instead of consuming a new
    /// slot per resize.  The OLD bind-group handle is dropped without a
    /// destroy (the JS bridge has no bind-group destroy yet - see
    /// audit_cleanup_notes.md); one handle per resize, bounded by how
    /// often the user rotates the device.  No-op on id 0 / unregistered.
    pub fn updateRegisteredTexture(self: *Renderer2D, id: u32, tex: WgpuTexture) void {
        if (id == 0 or id >= self.registered_count) {
            return;
        }
        const bg: wgpu.BindGroupHandle = buildMaterialBindGroup(
            self.gpa,
            self.resources.f.device,
            self.resources.bg_layouts[1],
            tex,
        ) catch return;
        self.registered_textures[id] = tex;
        self.registered_bind_groups[id] = bg;
    }

    /// Return a material bind group for `tex`, caching by texture HANDLE. If the
    /// texture was already registered (by handle), reuse its bind group;
    /// otherwise register it now. This is the SAFE replacement for mutating the
    /// shared `bind_groups[1]` in place: every distinct texture gets its own
    /// persistent bind-group handle, so the deferred shapes batch (which resolves
    /// the bind group at flush/submit time) can never alias one texture's draw
    /// onto another's. (.invalid -> white/untextured.) Bounded by
    /// max_registered_textures; falls back to white if the registry is full.
    pub fn bindGroupForTexture(self: *Renderer2D, tex: WgpuTexture) wgpu.BindGroupHandle {
        if (tex.view == .invalid) {
            return self.resources.bind_groups[1]; // white / untextured
        }
        var i: u32 = 1;
        while (i < self.registered_count) : (i += 1) {
            if (self.registered_textures[i].view == tex.view) {
                return self.registered_bind_groups[i];
            }
        }
        const id: u32 = self.registerTexture(tex);
        return self.lookupBindGroup(id);
    }

    pub fn deinit(self: *Renderer2D) void {
        self.resources.deinit();
        wgpu.destroyBuffer(self.batch_vbo);
        wgpu.destroyBuffer(self.batch_ibo);
        for (self.ortho_ring_bufs) |buf| {
            if (buf != .invalid) {
                wgpu.destroyBuffer(buf);
            }
        }
        for (self.ortho_ring_bgs) |bg| {
            if (bg != .invalid) {
                wgpu.destroyBindGroup(bg);
            }
        }
        self.white_tex.deinit();
        // Fixed shapes pipelines/layout/modules. Built directly (not via the
        // dedup PipelineCache - they survive its deinit), so this owns them.
        // `shapes_pipeline` aliases one of `blend_pipes`, so the array covers it.
        for (self.blend_pipes) |p| {
            if (p != .invalid) {
                wgpu.destroyRenderPipeline(p);
            }
        }
        if (self.shapes_pipeline_layout != .invalid) {
            wgpu.destroyPipelineLayout(self.shapes_pipeline_layout);
        }
        if (self.shapes_vs_module != .invalid) {
            wgpu.destroyShaderModule(self.shapes_vs_module);
        }
        if (self.shapes_fs_module != .invalid) {
            wgpu.destroyShaderModule(self.shapes_fs_module);
        }
        self.* = .{ .gpa = self.gpa };
    }

    /// Record a NEW per-frame projection.  Safe to call several times a
    /// frame (frame begin, `beginTextureMode`, every `reopen2DPass`):
    /// each call advances the ortho ring and writes a FRESH slot, so
    /// pass segments recorded earlier keep the matrix they were bound
    /// with - a plain single-buffer write here would be clobbered by
    /// the last write of the frame (queue-timeline ordering), which is
    /// exactly the zimr516 "duplicated grid" glitch.  Call BEFORE
    /// `bindForPass` (both call sites do).
    pub fn updatePerFrame(
        self: *Renderer2D,
        f: *GpuFrame,
        ubo: PerFrameUbo,
    ) void {
        // The clobber hazard is scoped to ONE encoder (all queue writes
        // land before its submit), so the write budget is too: a fresh
        // encoder means recorded segments from the old one are sealed,
        // and every ring slot is reusable again.
        if (f.encoder != self.ortho_ring_encoder) {
            self.ortho_ring_encoder = f.encoder;
            self.ortho_writes_this_frame = 0;
        }
        self.ortho_cursor = (self.ortho_cursor + 1) % ortho_ring_len;
        self.ortho_writes_this_frame += 1;
        // A wrap within one frame would clobber a slot an earlier
        // recorded segment still references - surface it loudly rather
        // than glitch silently.  Debug @panics; release logs to the
        // page overlay and the LAST writer wins for the overflowing
        // segments (degraded, but bounded).
        assertf(
            self.ortho_writes_this_frame <= ortho_ring_len,
            @src(),
            "ortho ring overflow: {d} projection switches in one frame (ring holds {d}). " ++
                "Raise renderer_2d.ortho_ring_len.",
            .{ self.ortho_writes_this_frame, ortho_ring_len },
        );
        // Translate PerFrameUbo (local type, [16]f32 representation)
        // -> EngineSchema.Ubo (the schema's mat4-of-vec4 shape). The flat
        // [16]f32 reinterprets to [4]@Vector(4, f32) (identical bytes); the
        // plain-struct Ubo is then serialized via the wire layout.
        const schema_ubo: EngineSchema.Ubo = .{ .view_projection = @bitCast(ubo.view_projection) };
        const ubo_bytes: [shader.wireSizeOf(EngineSchema.Ubo)]u8 =
            shader.wireOf(EngineSchema.Ubo, &schema_ubo);
        wgpu.queueWriteBuffer(
            f.queue,
            self.ortho_ring_bufs[self.ortho_cursor],
            0,
            &ubo_bytes,
        );
    }

    /// Bind the engine's pipeline + bind groups on the given render
    /// pass.  Call at the start of every render pass (right after
    /// `beginRenderPass`).  Routes through the deduping
    /// `WgpuBackend.setPipeline` / `setBindGroup` so subsequent
    /// `flushBatch` calls during the same pass don't re-emit the
    /// same bindings.
    pub fn bindForPass(self: *Renderer2D, ps: *@import("gpu_iface.zig").PassState) void {
        const Backend = @import("gpu_iface.zig").WgpuBackend;
        // Drop the dedup's memory FIRST. This function is called both at pass start and as the
        // restore after a custom/3D pipeline has been bound - and in the restore case the
        // device has already invalidated these groups even though the tracker has not. Binding
        // unconditionally is what "bind for pass" has to mean; the cost is a handful of
        // redundant binds per pass. See `WgpuBackend.invalidateBindGroups`.
        Backend.invalidateBindGroups(ps);
        Backend.setPipeline(ps, self.shapes_pipeline);
        // Record that the 2D shapes pipeline now owns the batch, so a later
        // `flushBatch` can assert it's still bound when it drains. This is the
        // "restore" call custom-pipeline draws must issue before touching 2D
        // immediate mode again (text/caption/clearViewport). See
        // `PassState.batch_owner_pipeline` and the assert in `flushBatch`.
        ps.batch_owner_pipeline = self.shapes_pipeline.gpu_handle;
        self.resources.bind(ps);
        // Group 0 comes from the ortho RING, not Resources' single ubo:
        // the current slot holds the projection `updatePerFrame` just
        // wrote for THIS pass segment (see the ring's field docs).
        // Overrides the group-0 binding `resources.bind` emitted; the
        // dedup in setBindGroup keeps the double-set cheap.
        Backend.setBindGroup(ps, 0, self.ortho_ring_bgs[self.ortho_cursor]);
    }

    /// The pipeline state the engine's own shapes pipelines are built with.
    ///
    /// `Shader2D` must build the user's pipeline with the SAME state, and the depth part is
    /// the trap: when the app has no depth target the pipeline must declare NO depth state, or
    /// it is incompatible with the depth-less pass it gets bound into - and WebGPU rejects the
    /// whole command buffer, not just the draw.
    pub fn pipelineState(self: *const Renderer2D, blend: wgpu.BlendMode) gpu.StateCombo {
        @setEvalBranchQuota(2000);
        return gpu.StateCombo.fromParts(
            .triangle_list,
            blend,
            if (self.depth_format != null) .always else .none,
            .none,
            self.backbuffer_format,
            self.depth_format orelse .undefined_,
            1,
        );
    }

    /// Switch the active 2D blend mode. Flushes the pending batch (so queued
    /// geometry keeps the previous blend), then rebinds the matching pipeline.
    pub fn setBlend(
        self: *Renderer2D,
        ps: *@import("gpu_iface.zig").PassState,
        mode: wgpu.BlendMode,
    ) void {
        const Backend = @import("gpu_iface.zig").WgpuBackend;
        Backend.flushBatch(ps);
        self.active_blend = mode;
        self.shapes_pipeline = .{ .gpu_handle = self.blend_pipes[@backingInt(mode)] };
        Backend.setPipeline(ps, self.shapes_pipeline);
        // The blend variant is a batch-compatible pipeline (same layout, only
        // blend state differs), so it becomes the batch's owner for the assert
        // in flushBatch. See `PassState.batch_owner_pipeline`.
        ps.batch_owner_pipeline = self.shapes_pipeline.gpu_handle;
    }

    /// Run a USER fragment shader over the ordinary 2D batch - raylib's `BeginShaderMode`.
    ///
    /// This is not a post-process and it is not `effects2d`. There is no fullscreen quad and
    /// no render target: the user's shader BECOMES the fragment stage of the shapes pipeline,
    /// so every `rect`, `circle`, `text` and `texture` drawn until `clearUserShader` is
    /// filtered as it rasterizes. A circle comes out grey because the circle's own fragments
    /// went through the user's code.
    ///
    /// It works because a user shader built from `shapes_filter_fs_io` is
    /// LAYOUT-COMPATIBLE with the engine's own: same vertex stage, same varyings, projection
    /// still at group 0, texture still at group 1. Its uniforms land at group 2, which the
    /// shapes layout leaves empty. So the swap costs one `setPipeline` and rebuilds nothing.
    ///
    /// The flush is the load-bearing part. Geometry already queued was queued to be drawn
    /// with the CURRENT pipeline; if we swapped without draining the batch, everything drawn
    /// earlier this frame would retroactively be filtered too.
    pub fn setUserShader(
        self: *Renderer2D,
        ps: *@import("gpu_iface.zig").PassState,
        pipeline: wgpu.RenderPipelineHandle,
    ) void {
        const Backend = @import("gpu_iface.zig").WgpuBackend;
        Backend.flushBatch(ps);
        self.shapes_pipeline = .{ .gpu_handle = pipeline };
        Backend.setPipeline(ps, self.shapes_pipeline);
        // The user shader is LAYOUT-COMPATIBLE with the shapes pipeline (texture
        // still at group 1; see the doc above), so it validly owns the batch for
        // the flushBatch assert. See `PassState.batch_owner_pipeline`.
        ps.batch_owner_pipeline = self.shapes_pipeline.gpu_handle;
    }

    /// Back to the engine's own shapes shader - raylib's `EndShaderMode`.
    ///
    /// Returns to whatever BLEND MODE was in force, not unconditionally to `.alpha`, so a
    /// user shader nested inside `beginBlendMode(.additive)` leaves the additive blend intact.
    pub fn clearUserShader(
        self: *Renderer2D,
        ps: *@import("gpu_iface.zig").PassState,
    ) void {
        const Backend = @import("gpu_iface.zig").WgpuBackend;
        Backend.flushBatch(ps);
        self.shapes_pipeline = .{ .gpu_handle = self.blend_pipes[@backingInt(self.active_blend)] };
        Backend.setPipeline(ps, self.shapes_pipeline);
        ps.batch_owner_pipeline = self.shapes_pipeline.gpu_handle;
    }
};

// ============================================================================
// SECTION 3 - orthographic projection helper
// ============================================================================

/// Build a column-major mat4x4 for a screen-space orthographic
/// projection (0,0 = top-left, width/height = bottom-right).
/// Used as the default per-frame view_projection.
pub fn orthoTopLeft(width: f32, height: f32) [16]f32 {
    return .{
        2.0 / width, 0,             0, 0,
        0,           -2.0 / height, 0, 0,
        0,           0,             1, 0,
        -1.0,        1.0,           0, 1,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "PerFrameUbo is 64 bytes (mat4x4)" {
    try expectEqual(@as(usize, 64), @sizeOf(PerFrameUbo));
}

test "orthoTopLeft maps (0,0) to NDC (-1,1)" {
    const m: [16]f32 = orthoTopLeft(800, 600);
    // Apply the matrix to (0,0,0,1):
    //   x_ndc = m[0]*0 + m[4]*0 + m[8]*0 + m[12]*1 = m[12]
    //   y_ndc = m[1]*0 + m[5]*0 + m[9]*0 + m[13]*1 = m[13]
    try expectApproxEqAbs(@as(f32, -1.0), m[12], 1e-6);
    try expectApproxEqAbs(@as(f32, 1.0), m[13], 1e-6);
}

test "orthoTopLeft maps (width, height) to NDC (1, -1)" {
    const m: [16]f32 = orthoTopLeft(800, 600);
    // Apply to (800, 600, 0, 1):
    //   x_ndc = m[0]*800 + m[12]*1 = (2/800)*800 - 1 = 1
    //   y_ndc = m[5]*600 + m[13]*1 = (-2/600)*600 + 1 = -1
    const x_ndc: f32 = m[0] * 800.0 + m[12] * 1.0;
    const y_ndc: f32 = m[5] * 600.0 + m[13] * 1.0;
    try expectApproxEqAbs(@as(f32, 1.0), x_ndc, 1e-6);
    try expectApproxEqAbs(@as(f32, -1.0), y_ndc, 1e-6);
}

test "Renderer2D default-initialises to invalid handles" {
    const r: Renderer2D = .{ .gpa = std.testing.allocator };
    try expectEqual(wgpu.ShaderModuleHandle.invalid, r.shapes_vs_module);
    try expectEqual(wgpu.ShaderModuleHandle.invalid, r.shapes_fs_module);
    try expectEqual(wgpu.RenderPipelineHandle.invalid, r.shapes_pipeline.gpu_handle);
}

test "MatrixStack push/pop returns to identity" {
    var ms: MatrixStack = .{};
    ms.reset();
    ms.push();
    ms.setCurrent(.{ 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 1 });
    try expectEqual(@as(u8, 1), ms.top);
    try expectEqual(@as(f32, 2), ms.current()[0]);
    ms.pop();
    try expectEqual(@as(u8, 0), ms.top);
    try expectEqual(@as(f32, 1), ms.current()[0]);
}

test "Vertex2D packs to 20 bytes" {
    // 8 (pos) + 8 (uv) + 4 (color) = 20
    try expectEqual(@as(usize, 20), @sizeOf(Vertex2D));
}
