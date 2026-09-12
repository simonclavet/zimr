//! pipeline_array — Phase 3 (`src/notes/webgpu_control.md`): 2D texture
//! arrays. One texture holds four layers, each painted a distinct pattern by a
//! COMPUTE shader (a `texture_storage_2d_array`, one dispatch with z = layers).
//! A single render pipeline then samples a `texture_2d_array`: the layer index
//! is a per-vertex attribute, so ONE draw renders a 2x2 grid where each quad
//! reads a different layer.
//!
//! Plumbing added (additive): wgpu.TextureDesc.array_layers,
//! wgpu.createTextureViewArray (a 2d-array view, bound for both the compute
//! write and the sampled read), and a `view_dimension` field in the bind-group
//! layout blob (gpu.zig encoder + bridge decoder) so an entry can declare
//! `2d-array`. Existing entries default to `2d`, unchanged.
//!
//! Build:  zig build wgpu-pipeline-array
//! Device: zig build wgpu-pipeline-array-standalone -Dmode=release

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const common = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const tex_dim: u32 = 96;
const layers: u32 = 4;
const half: f32 = 0.40;

const compute_wgsl =
    \\@group(0) @binding(0) var out_tex: texture_storage_2d_array<rgba8unorm, write>;
    \\
    \\@compute @workgroup_size(8, 8, 1)
    \\fn cs_main(@builtin(global_invocation_id) gid: vec3u) {
    \\    let dims = textureDimensions(out_tex);
    \\    if (gid.x >= dims.x || gid.y >= dims.y || gid.z >= 4u) {
    \\        return;
    \\    }
    \\    let fx = f32(gid.x) / f32(dims.x);
    \\    let fy = f32(gid.y) / f32(dims.y);
    \\    var c = vec3f(0.0);
    \\    if (gid.z == 0u) {
    \\        let d = distance(vec2f(fx, fy), vec2f(0.5));
    \\        c = vec3f(1.0, 0.35, 0.35) * clamp(1.0 - d * 1.6, 0.0, 1.0);
    \\    } else if (gid.z == 1u) {
    \\        let s = step(0.5, fract(fx * 6.0));
    \\        c = mix(vec3f(0.10, 0.35, 0.12), vec3f(0.35, 1.0, 0.45), s);
    \\    } else if (gid.z == 2u) {
    \\        let cx = floor(fx * 6.0);
    \\        let cy = floor(fy * 6.0);
    \\        let ch = (cx + cy) % 2.0;
    \\        c = mix(vec3f(0.10, 0.15, 0.30), vec3f(0.40, 0.60, 1.0), ch);
    \\    } else {
    \\        c = vec3f(fx, fy, 0.7);
    \\    }
    \\    textureStore(out_tex, vec2i(i32(gid.x), i32(gid.y)), i32(gid.z), vec4f(c, 1.0));
    \\}
;

const render_wgsl =
    \\struct U { aspect: vec4f };   // .xy = (sx, sy)
    \\@group(0) @binding(0) var<uniform> u: U;
    \\@group(0) @binding(1) var tex: texture_2d_array<f32>;
    \\@group(0) @binding(2) var samp: sampler;
    \\
    \\struct VsOut {
    \\    @builtin(position) pos: vec4f,
    \\    @location(0) uv: vec2f,
    \\    @location(1) @interpolate(flat) layer: u32,
    \\};
    \\
    \\@vertex
    \\fn vs_main(@location(0) p: vec2f, @location(1) uv: vec2f, @location(2) layer: f32) -> VsOut {
    \\    var out: VsOut;
    \\    out.pos = vec4f(p.x * u.aspect.x, p.y * u.aspect.y, 0.0, 1.0);
    \\    out.uv = uv;
    \\    out.layer = u32(layer + 0.5);
    \\    return out;
    \\}
    \\
    \\@fragment
    \\fn fs_main(in: VsOut) -> @location(0) vec4f {
    \\    return vec4f(textureSample(tex, samp, in.uv, i32(in.layer)).rgb, 1.0);
    \\}
;

const Vertex = extern struct { x: f32, y: f32, u: f32, v: f32, layer: f32 };

const Cell = struct { cx: f32, cy: f32, layer: f32, label: []const u8 };

const grid = [4]Cell{
    .{ .cx = -0.5, .cy = 0.5, .layer = 0, .label = "layer 0" },
    .{ .cx = 0.5, .cy = 0.5, .layer = 1, .label = "layer 1" },
    .{ .cx = -0.5, .cy = -0.5, .layer = 2, .label = "layer 2" },
    .{ .cx = 0.5, .cy = -0.5, .layer = 3, .label = "layer 3" },
};

fn quad(c: Cell) [6]Vertex {
    const l: f32 = c.layer;
    return .{
        .{ .x = c.cx - half, .y = c.cy + half, .u = 0, .v = 0, .layer = l },
        .{ .x = c.cx - half, .y = c.cy - half, .u = 0, .v = 1, .layer = l },
        .{ .x = c.cx + half, .y = c.cy - half, .u = 1, .v = 1, .layer = l },
        .{ .x = c.cx - half, .y = c.cy + half, .u = 0, .v = 0, .layer = l },
        .{ .x = c.cx + half, .y = c.cy - half, .u = 1, .v = 1, .layer = l },
        .{ .x = c.cx + half, .y = c.cy + half, .u = 1, .v = 0, .layer = l },
    };
}

const State = struct {
    font: z.Font,
    tex: z.wgpu.TextureHandle,
    arr_view: z.wgpu.TextureViewHandle,
    sampler: z.wgpu.SamplerHandle,
    ubo: z.wgpu.BufferHandle,
    pipe: z.Pipeline,
    bind_group: z.wgpu.BindGroupHandle,
    vbo: z.wgpu.BufferHandle,
};

fn deinit(gpa: Allocator, s: *State) void {
    s.pipe.deinit();
    if (s.arr_view != .invalid) {
        z.wgpu.destroyTextureView(s.arr_view);
    }
    if (s.tex != .invalid) {
        z.wgpu.destroyTexture(s.tex);
    }
    if (s.sampler != .invalid) {
        z.wgpu.destroySampler(s.sampler);
    }
    if (s.bind_group != .invalid) {
        z.wgpu.destroyBindGroup(s.bind_group);
    }
    z.wgpu.destroyBuffer(s.vbo);
    z.wgpu.destroyBuffer(s.ubo);
    z.unloadFont(gpa, s.font);
}

fn fillLayers(gpa: Allocator, f: *z.Frame, arr_view: z.wgpu.TextureViewHandle) !void {
    // One compute dispatch paints all array layers (z = layers). The fill's
    // scaffolding is built and released inside the helper (leak-safe).
    const groups: u32 = (tex_dim + 7) / 8;
    try z.material.fillStorageView(gpa, f, arr_view, .{
        .wgsl = compute_wgsl,
        .groups = .{ .x = groups, .y = groups, .z = layers },
        .view_dimension = .d2_array,
        .label = "arr_cs",
    });
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const tex: z.wgpu.TextureHandle = z.wgpu.createTexture(f.gpu.device, .{
        .width = tex_dim,
        .height = tex_dim,
        .format = .rgba8_unorm,
        .usage = .{ .storage_binding = true, .texture_binding = true },
        .array_layers = layers,
        .label = "arr_tex",
    });
    const arr_view: z.wgpu.TextureViewHandle = z.wgpu.createTextureViewArray(tex, layers);
    try fillLayers(gpa, f, arr_view);

    const sampler: z.wgpu.SamplerHandle = z.wgpu.createSampler(f.gpu.device, .{
        .mag_filter_linear = true,
        .min_filter_linear = true,
        .address_mode = .clamp_to_edge,
    });

    const aspect0: [4]f32 = .{ 1, 1, 0, 0 };
    const ubo: z.wgpu.BufferHandle = z.material.uniformBuffer(f, std.mem.sliceAsBytes(&aspect0), "arr_ubo");

    const bgl: z.wgpu.BindGroupLayoutHandle = try z.material.bindGroupLayout(gpa, f, &.{
        .{ .binding = 0, .visibility = .{ .vertex = true }, .resource = .{ .uniform_buffer = .{} } },
        .{
            .binding = 1,
            .visibility = .{ .fragment = true },
            .resource = .{ .texture = .{ .view_dimension = .d2_array } },
        },
        .{ .binding = 2, .visibility = .{ .fragment = true }, .resource = .{ .sampler = .{} } },
    }, "arr_bgl");
    const bind_group: z.wgpu.BindGroupHandle = try z.material.bindGroup(gpa, f, bgl, &.{
        .{ .binding = 0, .resource = .{ .buffer = .{ .handle = ubo } } },
        .{ .binding = 1, .resource = .{ .texture_view = arr_view } },
        .{ .binding = 2, .resource = .{ .sampler = sampler } },
    }, "arr_bg");

    var verts: [24]Vertex = undefined;
    for (grid, 0..) |c, i| {
        const q: [6]Vertex = quad(c);
        @memcpy(verts[i * 6 .. i * 6 + 6], &q);
    }
    const vbo: z.wgpu.BufferHandle = z.wgpu.createBuffer(f.gpu.device, .{
        .size = @sizeOf([24]Vertex),
        .usage = .{ .vertex = true, .copy_dst = true },
        .label = "arr_vbo",
    });
    z.wgpu.queueWriteBuffer(f.gpu.queue, vbo, 0, std.mem.sliceAsBytes(&verts));

    const layout: z.VertexLayout = .{
        .array_stride = @sizeOf(Vertex),
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x2, .offset = 8, .shader_location = 1 },
            .{ .format = .float32, .offset = 16, .shader_location = 2 },
        },
    };
    const pipe: z.Pipeline = try z.Pipeline.init(gpa, f, .{
        .wgsl = render_wgsl,
        .layouts = &.{layout},
        .bind_group_layouts = &.{bgl},
        .label = "arr_render",
    });
    // Render bgl was build-only (defined the pipeline + bind group).
    z.wgpu.destroyBindGroupLayout(bgl);

    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20),
        .tex = tex,
        .arr_view = arr_view,
        .sampler = sampler,
        .ubo = ubo,
        .pipe = pipe,
        .bind_group = bind_group,
        .vbo = vbo,
    };
}

fn update(f: *z.Frame, s: *State) void {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const aspect: f32 = w / @max(h, 1.0);
    const sx: f32 = if (aspect < 1.0) 1.0 else 1.0 / aspect;
    const sy: f32 = if (aspect < 1.0) aspect else 1.0;
    const av: [4]f32 = .{ sx, sy, 0, 0 };
    z.wgpu.queueWriteBuffer(f.gpu.queue, s.ubo, 0, std.mem.sliceAsBytes(&av));

    const ps: *z.PassState = f.gl.pass;
    s.pipe.bind(ps);
    s.pipe.setBindGroup(ps, 0, s.bind_group);
    s.pipe.setVertex(ps, 0, s.vbo, @sizeOf([24]Vertex));
    s.pipe.drawArrays(ps, 24, 1); // all four layered quads in one draw

    for (grid) |c| {
        const px: f32 = (c.cx * sx * 0.5 + 0.5) * w;
        const py: f32 = (0.5 - (c.cy - half) * sy * 0.5) * h + 8.0;
        f.gl.text(.{ px - 40.0, py }, c.label, .{ .size = 20, .color = common.palette.ink_dim, .font = &s.font });
    }
    common.caption(f.gl, s.font, "pipeline_array: one texture_2d_array, 4 layers, sampled by per-vertex index");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    // Transient GPU-technique demo: pipeline setup creates layouts and shader
    // modules that aren't retained in State, so a leak-tight deinit isn't
    // practical. Opt out of the managed leak gate rather than fake teardown.
    .memory = .managed,
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - pipeline array",
            .width = 800,
            .height = 600,
            .scale_mode = .responsive,
            .clear = .{ .r = 0.02, .g = 0.02, .b = 0.03, .a = 1.0 },
        },
    },
    .init = initState,
    // .memory left default (arena): init builds a compute pipeline / multi-pass
    // chain (mipmap or bloom) whose intermediate handles aren't kept in State,
    // so a full managed teardown needs added State fields — deferred.
    .deinit = deinit,
    .update = update,
};
