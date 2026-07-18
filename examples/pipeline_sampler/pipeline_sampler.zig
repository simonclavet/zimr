//! pipeline_sampler — Phase 3 opener (`src/notes/webgpu_control.md`):
//! texture sampling control. One pattern (a checker tinted by a gradient,
//! painted by a COMPUTE shader into a storage texture) is drawn four ways with
//! UVs running 0..2.5 so both the filter and the address mode are obvious:
//!
//!   nearest / repeat   linear / repeat
//!   linear  / clamp    linear / mirror
//!
//! Filter: nearest = hard texel blocks, linear = smooth. Address (UV > 1):
//! repeat tiles, clamp holds the edge texel, mirror flips every tile. All four
//! share one texture + one pipeline; only the SAMPLER in the bind group differs
//! (no new plumbing — SamplerDesc already carries filters + address mode).
//!
//! Build:  zig build wgpu-pipeline-sampler
//! Device: zig build wgpu-pipeline-sampler-standalone -Dmode=release

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const co = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const tex_dim: u32 = 128;
const uv_max: f32 = 2.5;
const half: f32 = 0.42;

const compute_wgsl =
    \\@group(0) @binding(0) var out_tex: texture_storage_2d<rgba8unorm, write>;
    \\
    \\@compute @workgroup_size(8, 8)
    \\fn cs_main(@builtin(global_invocation_id) gid: vec3u) {
    \\    let dims = textureDimensions(out_tex);
    \\    if (gid.x >= dims.x || gid.y >= dims.y) {
    \\        return;
    \\    }
    \\    let fx = f32(gid.x) / f32(dims.x);
    \\    let fy = f32(gid.y) / f32(dims.y);
    \\    let cells = 6.0;
    \\    let cx = floor(fx * cells);
    \\    let cy = floor(fy * cells);
    \\    let checker = (cx + cy) % 2.0;
    \\    let dark = vec3f(0.10, 0.12, 0.20);
    \\    let light = vec3f(0.96, 0.92, 0.80);
    \\    var base = mix(dark, light, checker);
    \\    let tint = vec3f(fx, fy, 0.55);
    \\    base = mix(base, tint, 0.45);
    \\    textureStore(out_tex, vec2i(i32(gid.x), i32(gid.y)), vec4f(base, 1.0));
    \\}
;

const render_wgsl =
    \\struct U { aspect: vec4f };   // .xy = (sx, sy)
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
    \\fn vs_main(@location(0) p: vec2f, @location(1) uv: vec2f) -> VsOut {
    \\    var out: VsOut;
    \\    out.pos = vec4f(p.x * u.aspect.x, p.y * u.aspect.y, 0.0, 1.0);
    \\    out.uv = uv;
    \\    return out;
    \\}
    \\
    \\@fragment
    \\fn fs_main(in: VsOut) -> @location(0) vec4f {
    \\    return vec4f(textureSample(tex, samp, in.uv).rgb, 1.0);
    \\}
;

const Vertex = extern struct { x: f32, y: f32, u: f32, v: f32 };

const Cell = struct {
    cx: f32,
    cy: f32,
    label: []const u8,
    mag_linear: bool,
    address: z.wgpu.SamplerDesc.AddressMode,
};

const cells = [4]Cell{
    .{ .cx = -0.52, .cy = 0.52, .label = "nearest / repeat", .mag_linear = false, .address = .repeat },
    .{ .cx = 0.52, .cy = 0.52, .label = "linear / repeat", .mag_linear = true, .address = .repeat },
    .{ .cx = -0.52, .cy = -0.52, .label = "linear / clamp", .mag_linear = true, .address = .clamp_to_edge },
    .{ .cx = 0.52, .cy = -0.52, .label = "linear / mirror", .mag_linear = true, .address = .mirror_repeat },
};

fn quad(cx: f32, cy: f32) [6]Vertex {
    return .{
        .{ .x = cx - half, .y = cy + half, .u = 0, .v = 0 },
        .{ .x = cx - half, .y = cy - half, .u = 0, .v = uv_max },
        .{ .x = cx + half, .y = cy - half, .u = uv_max, .v = uv_max },
        .{ .x = cx - half, .y = cy + half, .u = 0, .v = 0 },
        .{ .x = cx + half, .y = cy - half, .u = uv_max, .v = uv_max },
        .{ .x = cx + half, .y = cy + half, .u = uv_max, .v = 0 },
    };
}

const State = struct {
    font: z.Font,
    st: z.material.StorageTexture,
    ubo: z.wgpu.BufferHandle,
    pipe: z.Pipeline,
    bgs: [4]z.wgpu.BindGroupHandle,
    vbos: [4]z.wgpu.BufferHandle,
    samplers: [4]z.wgpu.SamplerHandle,
};

fn deinit(gpa: Allocator, s: *State) void {
    s.pipe.deinit();
    s.st.deinit();
    for (s.bgs) |bg| {
        if (bg != .invalid) {
            z.wgpu.destroyBindGroup(bg);
        }
    }
    for (s.vbos) |vbo| {
        if (vbo != .invalid) {
            z.wgpu.destroyBuffer(vbo);
        }
    }
    for (s.samplers) |smp| {
        if (smp != .invalid) {
            z.wgpu.destroySampler(smp);
        }
    }
    z.wgpu.destroyBuffer(s.ubo);
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    // Paint the checker+gradient into a storage texture via compute — the fill's
    // scaffolding is built and released inside the helper (leak-safe).
    const st: z.material.StorageTexture = try z.material.storageTextureFilled(
        gpa,
        f,
        tex_dim,
        tex_dim,
        compute_wgsl,
        "sampler_tex",
    );

    const aspect0: [4]f32 = .{ 1, 1, 0, 0 };
    const ubo: z.wgpu.BufferHandle = z.material.uniformBuffer(f, std.mem.sliceAsBytes(&aspect0), "sampler_ubo");

    const bgl: z.wgpu.BindGroupLayoutHandle = try z.material.bindGroupLayout(gpa, f, &.{
        .{ .binding = 0, .visibility = .{ .vertex = true }, .resource = .{ .uniform_buffer = .{} } },
        .{ .binding = 1, .visibility = .{ .fragment = true }, .resource = .{ .texture = .{} } },
        .{ .binding = 2, .visibility = .{ .fragment = true }, .resource = .{ .sampler = .{} } },
    }, "sampler_bgl");

    var bgs: [4]z.wgpu.BindGroupHandle = undefined;
    var vbos: [4]z.wgpu.BufferHandle = undefined;
    var samplers: [4]z.wgpu.SamplerHandle = undefined;
    for (cells, 0..) |c, i| {
        const sampler: z.wgpu.SamplerHandle = z.wgpu.createSampler(f.gpu.device, .{
            .mag_filter_linear = c.mag_linear,
            .min_filter_linear = c.mag_linear,
            .address_mode = c.address,
        });
        samplers[i] = sampler;
        bgs[i] = try z.material.bindGroup(gpa, f, bgl, &.{
            .{ .binding = 0, .resource = .{ .buffer = .{ .handle = ubo } } },
            .{ .binding = 1, .resource = .{ .texture_view = st.view } },
            .{ .binding = 2, .resource = .{ .sampler = sampler } },
        }, "sampler_cell_bg");
        const verts: [6]Vertex = quad(c.cx, c.cy);
        const vbo: z.wgpu.BufferHandle = z.wgpu.createBuffer(f.gpu.device, .{
            .size = @sizeOf([6]Vertex),
            .usage = .{ .vertex = true, .copy_dst = true },
            .label = "sampler_vbo",
        });
        z.wgpu.queueWriteBuffer(f.gpu.queue, vbo, 0, std.mem.sliceAsBytes(&verts));
        vbos[i] = vbo;
    }

    const layout: z.VertexLayout = .{
        .array_stride = @sizeOf(Vertex),
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x2, .offset = 8, .shader_location = 1 },
        },
    };
    const pipe: z.Pipeline = try z.Pipeline.init(gpa, f, .{
        .wgsl = render_wgsl,
        .layouts = &.{layout},
        .bind_group_layouts = &.{bgl},
        .label = "sampler_render",
    });
    // The render bgl defined the pipeline + all four cell bind groups, which
    // retain it — release the build-only handle now.
    z.wgpu.destroyBindGroupLayout(bgl);

    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20),
        .st = st,
        .ubo = ubo,
        .pipe = pipe,
        .bgs = bgs,
        .vbos = vbos,
        .samplers = samplers,
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
    for (s.bgs, s.vbos) |bg, vbo| {
        s.pipe.bind(ps);
        s.pipe.setBindGroup(ps, 0, bg);
        s.pipe.setVertex(ps, 0, vbo, @sizeOf([6]Vertex));
        s.pipe.drawArrays(ps, 6, 1);
    }

    // Labels under each quad (design-space center -> screen pixels).
    for (cells) |c| {
        const px: f32 = (c.cx * sx * 0.5 + 0.5) * w;
        const py: f32 = (0.5 - (c.cy - half) * sy * 0.5) * h + 8.0;
        f.gl.text(.{ px - 70.0, py }, c.label, .{ .size = 20, .color = co.palette.ink_dim, .font = &s.font });
    }
    co.caption(f.gl, s.font, "pipeline_sampler: filter (nearest/linear) + address (repeat/clamp/mirror)");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    // Transient GPU-technique demo: pipeline setup creates layouts and shader
    // modules that aren't retained in State, so a leak-tight deinit isn't
    // practical. Opt out of the managed leak gate rather than fake teardown.
    .memory = .managed,
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - pipeline sampler",
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
