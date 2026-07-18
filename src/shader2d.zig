//! src/shader2d.zig — a USER fragment shader, run over the ordinary 2D batch.
//!
//! This is raylib's `BeginShaderMode` / `EndShaderMode`, and it is a different thing from
//! `effects2d`:
//!
//!   effects2d   runs a shader over a FULLSCREEN QUAD. It is a post-process: you render the
//!               scene to a texture, then filter the texture. The shader never sees a shape.
//!
//!   Shader2D    BECOMES the fragment stage of the shapes pipeline. Every `rect`, `circle`,
//!               `text` and `texture` drawn between `beginShaderMode` and `endShaderMode` is
//!               filtered AS IT RASTERIZES. A circle is grey because the circle's own
//!               fragments went through the user's code. Nothing is rendered to a texture and
//!               nothing is read back.
//!
//! WHY THE SWAP IS CHEAP.
//!
//! A shader written against `shapes_filter_fs_io` is LAYOUT-COMPATIBLE with the engine's own
//! shapes shader, by construction:
//!
//!   * same vertex stage (the engine's `default_shapes_vs`, reused verbatim),
//!   * same vertex buffer layout (position, uv, packed colour — 20 bytes),
//!   * same varyings (`frag_tex_coord`, `frag_color`),
//!   * projection still at group 0, texture+sampler still at group 1.
//!
//! WebGPU keeps bind groups bound across a pipeline change as long as the two pipeline layouts
//! agree on a prefix of bind-group layouts — and here groups 0 and 1 are literally the SAME
//! handles the renderer already built. So swapping a user shader in costs one `setPipeline`
//! and one `setBindGroup` (for group 2, the user's uniforms). No bind group is rebuilt, no
//! texture is re-bound, and the batch is not re-uploaded.
//!
//! The user's uniforms land at group 2 because that is what the engine's group convention
//! already does with a FRAGMENT uniform (vertex uniforms group 0, samplers group 1, fragment
//! uniforms group 2) — and the shapes layout leaves group 2 empty. Nothing had to be moved to
//! make room.
const std = @import("std");

const gpu = @import("gpu.zig");
const wgpu = @import("wgpu.zig");
const shader_introspect = @import("shader_introspect.zig");
const renderer_2d = @import("renderer_2d.zig");

const Allocator = std.mem.Allocator;
const Renderer2D = renderer_2d.Renderer2D;

/// A compiled user 2D shader, plus the uniform buffer it reads.
///
/// OWNS six GPU handles, and frees all six in `deinit`. Every one of them is created here, so
/// every one of them is ours: the pipeline, its layout, the group-2 bind-group layout, the
/// fragment module, the uniform buffer, and the bind group. (The engine's own shapes VS module
/// and its group-0/group-1 layouts are BORROWED from `Renderer2D` and must not be freed.)
pub const Shader2D = struct {
    /// The render pipeline: engine vertex stage + the user's fragment stage.
    pipeline: wgpu.RenderPipelineHandle = .invalid,

    /// Group 2 — the user's uniforms. Bound by `beginShaderMode`.
    params_bind_group: wgpu.BindGroupHandle = .invalid,
    params_buffer: wgpu.BufferHandle = .invalid,

    // Build-time handles, kept only so `deinit` can free them.
    pipeline_layout: wgpu.PipelineLayoutHandle = .invalid,
    params_bg_layout: wgpu.BindGroupLayoutHandle = .invalid,
    fragment_module: wgpu.ShaderModuleHandle = .invalid,

    /// Kept so `setParams` can write the uniform buffer without the caller having to hand us a
    /// queue every frame.
    queue: wgpu.QueueHandle = .invalid,

    /// The uniform block, mirroring `shapes_filter_fs_io.Ubo`.
    ///
    /// One vector, not four floats. A std140 uniform array has a SIXTEEN-byte element stride,
    /// so a `[4]f32` would occupy 64 bytes with three quarters of it padding — and the layout
    /// validator in `shader_interface` rejects it outright rather than letting the CPU and the
    /// GPU disagree about where `params[1]` lives.
    pub const Params = extern struct {
        params: [4]f32 = .{ 0, 0, 0, 0 },
    };

    /// Compile a user fragment shader into a pipeline that can replace the engine's own.
    ///
    /// `fragment_wgsl` is the WGSL the build generated from the user's `*_fs.zig` — the same
    /// `@embedFile`-able artifact every other shader in zimr uses.
    pub fn init(
        gpa: Allocator,
        device: wgpu.DeviceHandle,
        queue: wgpu.QueueHandle,
        renderer: *const Renderer2D,
        fragment_wgsl: [:0]const u8,
        label: []const u8,
    ) !Shader2D {
        var self: Shader2D = .{ .queue = queue };

        // ---- group 2: the user's uniforms ---------------------------------------------
        //
        // Groups 0 and 1 are NOT created here. They are the renderer's own, borrowed by
        // handle, and that identity is precisely what makes the pipeline swap free.
        const params_entries = [_]shader_introspect.BindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = .{ .fragment = true },
                .resource = .{ .uniform_buffer = .{ .min_size = @sizeOf(Params) } },
            },
        };
        const params_layout_blob: []const u8 = try gpu.encodeBindGroupLayoutEntries(
            gpa,
            &params_entries,
        );
        defer gpa.free(params_layout_blob);

        self.params_bg_layout = wgpu.createBindGroupLayout(device, params_layout_blob, label);

        self.params_buffer = wgpu.createBuffer(device, .{
            .size = @sizeOf(Params),
            .usage = .{ .uniform = true, .copy_dst = true },
            .label = label,
        });

        const params_bg_blob: []const u8 = try gpu.encodeBindGroupEntries(gpa, &.{
            .{ .binding = 0, .resource = .{ .buffer = .{
                .handle = self.params_buffer,
                .offset = 0,
                .size = @sizeOf(Params),
            } } },
        });
        defer gpa.free(params_bg_blob);

        self.params_bind_group = wgpu.createBindGroup(
            device,
            self.params_bg_layout,
            params_bg_blob,
            label,
        );

        // ---- the pipeline: engine vertex stage, user fragment stage ---------------------
        //
        // The first two bind-group layouts are the RENDERER'S OWN HANDLES. That is not a
        // convenience — it is the requirement. WebGPU only keeps groups 0 and 1 bound across
        // the pipeline swap if the two layouts agree on that prefix, and handing it the same
        // handles is the only way to be certain they do.
        self.pipeline_layout = wgpu.createPipelineLayout(device, &.{
            renderer.resources.bg_layouts[0], // projection  (borrowed)
            renderer.resources.bg_layouts[1], // texture     (borrowed)
            self.params_bg_layout, // user params (ours)
        }, label);

        self.fragment_module = wgpu.createShaderModuleWgsl(device, fragment_wgsl, label);

        const pipeline_blob: []const u8 = try gpu.encodeRenderPipelineDescriptor(gpa, .{
            .vertex_buffer_layouts = &.{renderer_2d.shapesVertexBufferLayout()},
            .vs_entry_point = "entry",
            .fs_entry_point = "entry",
            .state = renderer.pipelineState(.alpha),
        });
        defer gpa.free(pipeline_blob);

        self.pipeline = wgpu.createRenderPipeline(
            device,
            self.pipeline_layout,
            renderer.shapes_vs_module, // the engine's vertex stage, verbatim
            self.fragment_module,
            pipeline_blob,
            label,
        );

        return self;
    }

    /// Update the shader's uniforms. Cheap enough to call every frame.
    pub fn setParams(self: *const Shader2D, params: Params) void {
        wgpu.queueWriteBuffer(self.queue, self.params_buffer, 0, std.mem.asBytes(&params));
    }

    /// Free all six handles this shader created.
    ///
    /// It does NOT free the renderer's vertex module or its group-0/group-1 layouts, which are
    /// borrowed. Creating a pipeline creates a layout, a bind-group layout and a shader module
    /// as well as the pipeline itself, and an example that frees only the obvious one leaks
    /// the other three silently — which is exactly what the smoke harness's leak census
    /// caught in `effects2d` once.
    pub fn deinit(self: *Shader2D) void {
        wgpu.destroyRenderPipeline(self.pipeline);
        wgpu.destroyPipelineLayout(self.pipeline_layout);
        wgpu.destroyBindGroup(self.params_bind_group);
        wgpu.destroyBindGroupLayout(self.params_bg_layout);
        wgpu.destroyBuffer(self.params_buffer);
        wgpu.destroyShaderModule(self.fragment_module);
        self.* = .{};
    }
};
