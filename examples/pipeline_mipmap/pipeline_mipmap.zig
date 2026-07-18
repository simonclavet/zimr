//! pipeline_mipmap — Phase 3 (`src/notes/webgpu_control.md`): mipmaps and
//! LOD selection. A texture is built with a full mip chain, and a COMPUTE
//! shader paints each level a DISTINCT hue (level 0 red, climbing the spectrum
//! to the 1x1 top). The texture is then drawn on a perspective ground plane:
//! the GPU picks a mip level per pixel from the UV derivatives, so distance
//! selects the level and the road shows the chain as colour bands receding to
//! the horizon — you literally see which LOD is sampled where.
//!
//! Plumbing added (additive): wgpu.TextureDesc.mip_level_count,
//! wgpu.createTextureViewMip (a single-level view, used to bind each mip as a
//! compute write target), and SamplerDesc.mipmap_filter_linear. The sampler
//! here uses nearest mip filtering so the bands stay crisp.
//!
//! Each level is filled by one dispatch whose storage view targets just that
//! level; the colour is derived from the level's own dimensions, so no
//! per-level uniform is needed.
//!
//! Build:  zig build wgpu-pipeline-mipmap
//! Device: zig build wgpu-pipeline-mipmap-standalone -Dmode=release

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const co = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const tex_dim: u32 = 256;
const mip_levels: u32 = 9; // log2(256) + 1

const compute_wgsl =
    \\@group(0) @binding(0) var out_tex: texture_storage_2d<rgba8unorm, write>;
    \\
    \\fn hsv2rgb(h: f32, s: f32, v: f32) -> vec3f {
    \\    let k = vec3f(5.0, 3.0, 1.0);
    \\    let p = abs(fract(vec3f(h) + k / 6.0) * 6.0 - 3.0);
    \\    return v * mix(vec3f(1.0), clamp(p - 1.0, vec3f(0.0), vec3f(1.0)), s);
    \\}
    \\
    \\@compute @workgroup_size(8, 8)
    \\fn cs_main(@builtin(global_invocation_id) gid: vec3u) {
    \\    let dims = textureDimensions(out_tex);
    \\    if (gid.x >= dims.x || gid.y >= dims.y) {
    \\        return;
    \\    }
    \\    let lvl = log2(256.0 / f32(max(dims.x, 1u)));
    \\    let c = hsv2rgb(lvl / 8.0, 0.85, 0.95);
    \\    textureStore(out_tex, vec2i(i32(gid.x), i32(gid.y)), vec4f(c, 1.0));
    \\}
;

const render_wgsl =
    \\struct U { mvp: mat4x4f };
    \\@group(0) @binding(0) var<uniform> u: U;
    \\@group(0) @binding(1) var tex: texture_2d<f32>;
    \\@group(0) @binding(2) var samp: sampler;
    \\
    \\struct VsOut {
    \\    @builtin(position) pos: vec4f,
    \\    @location(0) uv: vec2f,
    \\};
    \\
    \\@vertex
    \\fn vs_main(@location(0) p: vec3f, @location(1) uv: vec2f) -> VsOut {
    \\    var out: VsOut;
    \\    out.pos = u.mvp * vec4f(p, 1.0);
    \\    out.uv = uv;
    \\    return out;
    \\}
    \\
    \\@fragment
    \\fn fs_main(in: VsOut) -> @location(0) vec4f {
    \\    return vec4f(textureSample(tex, samp, in.uv).rgb, 1.0);
    \\}
;

const Vertex = extern struct { x: f32, y: f32, z: f32, u: f32, v: f32 };

// Ground plane in world space (y = 0), UV tiled every 2 units for fine detail.
const plane = [_]Vertex{
    .{ .x = -20, .y = 0, .z = 0, .u = -10, .v = 0 },
    .{ .x = 20, .y = 0, .z = 0, .u = 10, .v = 0 },
    .{ .x = 20, .y = 0, .z = 80, .u = 10, .v = 40 },
    .{ .x = -20, .y = 0, .z = 0, .u = -10, .v = 0 },
    .{ .x = 20, .y = 0, .z = 80, .u = 10, .v = 40 },
    .{ .x = -20, .y = 0, .z = 80, .u = -10, .v = 40 },
};

const State = struct {
    font: z.Font,
    tex: z.wgpu.TextureHandle,
    full_view: z.wgpu.TextureViewHandle,
    sampler: z.wgpu.SamplerHandle,
    mvp_ubo: z.wgpu.BufferHandle,
    pipe: z.Pipeline,
    bind_group: z.wgpu.BindGroupHandle,
    vbo: z.wgpu.BufferHandle,
};

fn deinit(gpa: Allocator, s: *State) void {
    s.pipe.deinit();
    if (s.full_view != .invalid) {
        z.wgpu.destroyTextureView(s.full_view);
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
    z.wgpu.destroyBuffer(s.mvp_ubo);
    z.unloadFont(gpa, s.font);
}

// --- tiny column-major mat4 helpers ---------------------------------------

fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) [16]f32 {
    const ft: f32 = 1.0 / @tan(fovy * 0.5);
    const nf: f32 = 1.0 / (near - far);
    return .{ ft / aspect, 0, 0, 0, 0, ft, 0, 0, 0, 0, far * nf, -1, 0, 0, near * far * nf, 0 };
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn norm3(a: [3]f32) [3]f32 {
    const l: f32 = @sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
    return .{ a[0] / l, a[1] / l, a[2] / l };
}

fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn lookAt(eye: [3]f32, center: [3]f32, up: [3]f32) [16]f32 {
    const fwd: [3]f32 = norm3(.{ center[0] - eye[0], center[1] - eye[1], center[2] - eye[2] });
    const s: [3]f32 = norm3(cross(fwd, up));
    const u: [3]f32 = cross(s, fwd);
    return .{
        s[0],          u[0],          -fwd[0],        0,
        s[1],          u[1],          -fwd[1],        0,
        s[2],          u[2],          -fwd[2],        0,
        -dot3(s, eye), -dot3(u, eye), dot3(fwd, eye), 1,
    };
}

fn mul4(a: [16]f32, b: [16]f32) [16]f32 {
    var r: [16]f32 = @splat(0);
    var col: usize = 0;
    while (col < 4) : (col += 1) {
        var row: usize = 0;
        while (row < 4) : (row += 1) {
            var sum: f32 = 0;
            var k: usize = 0;
            while (k < 4) : (k += 1) {
                sum += a[k * 4 + row] * b[col * 4 + k];
            }
            r[col * 4 + row] = sum;
        }
    }
    return r;
}

fn fillMips(gpa: Allocator, f: *z.Frame, tex: z.wgpu.TextureHandle) !void {
    const bgl: z.wgpu.BindGroupLayoutHandle = try z.material.bindGroupLayout(gpa, f, &.{
        .{
            .binding = 0,
            .visibility = .{ .compute = true },
            .resource = .{ .storage_texture = .{ .access = .write_only, .format = .rgba8_unorm } },
        },
    }, "mip_cs_bgl");
    var pipe: z.ComputePipeline = try z.ComputePipeline.init(gpa, f, .{
        .wgsl = compute_wgsl,
        .bind_group_layouts = &.{bgl},
        .label = "mip_cs",
    });
    var lvl: u32 = 0;
    while (lvl < mip_levels) : (lvl += 1) {
        const view: z.wgpu.TextureViewHandle = z.wgpu.createTextureViewMip(tex, lvl, 1);
        const bg: z.wgpu.BindGroupHandle = try z.material.bindGroup(gpa, f, bgl, &.{
            .{ .binding = 0, .resource = .{ .texture_view = view } },
        }, "mip_cs_bg");
        const dim: u32 = @max(tex_dim >> @intCast(lvl), 1);
        const groups: u32 = (dim + 7) / 8;
        pipe.dispatch(f, bg, .{ .x = groups, .y = groups });
        // The per-level bind group is ours to free (build-only for this
        // dispatch). The mip `view`, however, is owned by `tex`: on this bridge
        // destroying the mipmapped texture (in deinit) releases its per-level
        // views, so destroying `view` here too would double-free it. Freed with
        // the texture, not here. (NB: full `createTextureView` views are NOT
        // auto-freed and still need an explicit destroy — see notes.)
        z.wgpu.destroyBindGroup(bg);
    }
    // The compute pipeline + its layout were build-only for the whole fill.
    pipe.deinit();
    z.wgpu.destroyBindGroupLayout(bgl);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const tex: z.wgpu.TextureHandle = z.wgpu.createTexture(f.gpu.device, .{
        .width = tex_dim,
        .height = tex_dim,
        .format = .rgba8_unorm,
        .usage = .{ .storage_binding = true, .texture_binding = true },
        .mip_level_count = mip_levels,
        .label = "mip_tex",
    });
    try fillMips(gpa, f, tex);
    const full_view: z.wgpu.TextureViewHandle = z.wgpu.createTextureView(tex);

    const sampler: z.wgpu.SamplerHandle = z.wgpu.createSampler(f.gpu.device, .{
        .mag_filter_linear = true,
        .min_filter_linear = true,
        .mipmap_filter_linear = false, // nearest mip -> crisp bands
        .address_mode = .repeat,
    });

    const mvp0: [16]f32 = @splat(0);
    const mvp_ubo: z.wgpu.BufferHandle = z.material.uniformBuffer(f, std.mem.sliceAsBytes(&mvp0), "mip_mvp");

    const bgl: z.wgpu.BindGroupLayoutHandle = try z.material.bindGroupLayout(gpa, f, &.{
        .{ .binding = 0, .visibility = .{ .vertex = true }, .resource = .{ .uniform_buffer = .{} } },
        .{ .binding = 1, .visibility = .{ .fragment = true }, .resource = .{ .texture = .{} } },
        .{ .binding = 2, .visibility = .{ .fragment = true }, .resource = .{ .sampler = .{} } },
    }, "mip_bgl");
    const bind_group: z.wgpu.BindGroupHandle = try z.material.bindGroup(gpa, f, bgl, &.{
        .{ .binding = 0, .resource = .{ .buffer = .{ .handle = mvp_ubo } } },
        .{ .binding = 1, .resource = .{ .texture_view = full_view } },
        .{ .binding = 2, .resource = .{ .sampler = sampler } },
    }, "mip_bg");

    const vbo: z.wgpu.BufferHandle = z.wgpu.createBuffer(f.gpu.device, .{
        .size = @sizeOf(@TypeOf(plane)),
        .usage = .{ .vertex = true, .copy_dst = true },
        .label = "mip_vbo",
    });
    z.wgpu.queueWriteBuffer(f.gpu.queue, vbo, 0, std.mem.sliceAsBytes(&plane));

    const layout: z.VertexLayout = .{
        .array_stride = @sizeOf(Vertex),
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x2, .offset = 12, .shader_location = 1 },
        },
    };
    const pipe: z.Pipeline = try z.Pipeline.init(gpa, f, .{
        .wgsl = render_wgsl,
        .layouts = &.{layout},
        .bind_group_layouts = &.{bgl},
        .label = "mip_render",
    });
    // Render bgl was build-only (defined the pipeline + bind group).
    z.wgpu.destroyBindGroupLayout(bgl);

    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22),
        .tex = tex,
        .full_view = full_view,
        .sampler = sampler,
        .mvp_ubo = mvp_ubo,
        .pipe = pipe,
        .bind_group = bind_group,
        .vbo = vbo,
    };
}

fn update(f: *z.Frame, s: *State) void {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const aspect: f32 = w / @max(h, 1.0);
    const proj: [16]f32 = perspective(1.0472, aspect, 0.1, 200.0);
    const view: [16]f32 = lookAt(.{ 0, 3.0, -3.0 }, .{ 0, 0, 28.0 }, .{ 0, 1, 0 });
    const mvp: [16]f32 = mul4(proj, view);
    z.wgpu.queueWriteBuffer(f.gpu.queue, s.mvp_ubo, 0, std.mem.sliceAsBytes(&mvp));

    const ps: *z.PassState = f.gl.pass;
    s.pipe.bind(ps);
    s.pipe.setBindGroup(ps, 0, s.bind_group);
    s.pipe.setVertex(ps, 0, s.vbo, @sizeOf(@TypeOf(plane)));
    s.pipe.drawArrays(ps, plane.len, 1);

    co.caption(f.gl, s.font, "pipeline_mipmap: each band is a mip level - distance selects the LOD");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    // Transient GPU-technique demo: pipeline setup creates layouts and shader
    // modules that aren't retained in State, so a leak-tight deinit isn't
    // practical. Opt out of the managed leak gate rather than fake teardown.
    .memory = .managed,
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - pipeline mipmap",
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
