//! pipeline_storage — Phase 2 (`src/notes/webgpu_control.md`): a COMPUTE
//! shader writes an image into a STORAGE TEXTURE, which a render pass then
//! samples. This is the compute<->render bridge: GPU-generated texture content,
//! no CPU upload.
//!
//! Flow (one-shot at init, on its own command encoder so it runs outside the
//! frame's render pass — compute and render passes can't be open at once):
//!   - create an rgba8unorm texture with usage { storage_binding, texture_binding }
//!   - compute BGL: @binding(0) texture_storage_2d<rgba8unorm, write>, vis=compute
//!   - dispatch an 8x8 workgroup grid; the kernel `textureStore`s a plasma
//!   - submit; then every frame a fullscreen pipeline samples the same view
//!
//! Uses the material API: z.material.storageTexture (STORAGE|TEXTURE binding)
//! + z.ComputePipeline (one WGSL @compute entry; .dispatch runs it once on its
//! own encoder, the right shape for a fill outside the frame's render pass).
//!
//! Build:  zig build wgpu-pipeline-storage
//! Device: zig build wgpu-pipeline-storage-standalone -Dmode=release

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const co = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const tex_dim: u32 = 512;

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
    \\    let v = sin(fx * 10.0) + sin(fy * 10.0) + sin((fx + fy) * 10.0)
    \\          + sin(sqrt(fx * fx + fy * fy) * 14.0);
    \\    let c = vec3f(
    \\        0.5 + 0.5 * sin(v * 1.5),
    \\        0.5 + 0.5 * sin(v * 1.5 + 2.094),
    \\        0.5 + 0.5 * sin(v * 1.5 + 4.188)
    \\    );
    \\    textureStore(out_tex, vec2i(i32(gid.x), i32(gid.y)), vec4f(c, 1.0));
    \\}
;

const render_wgsl =
    \\@group(0) @binding(0) var tex: texture_2d<f32>;
    \\@group(0) @binding(1) var samp: sampler;
    \\
    \\struct VsOut {
    \\    @builtin(position) pos: vec4f,
    \\    @location(0) uv: vec2f,
    \\};
    \\
    \\@vertex
    \\fn vs_main(@builtin(vertex_index) vi: u32) -> VsOut {
    \\    var pts = array<vec2f, 3>(
    \\        vec2f(-1.0, -1.0),
    \\        vec2f(3.0, -1.0),
    \\        vec2f(-1.0, 3.0)
    \\    );
    \\    let xy = pts[vi];
    \\    var out: VsOut;
    \\    out.pos = vec4f(xy, 0.0, 1.0);
    \\    out.uv = vec2f((xy.x + 1.0) * 0.5, 1.0 - (xy.y + 1.0) * 0.5);
    \\    return out;
    \\}
    \\
    \\@fragment
    \\fn fs_main(in: VsOut) -> @location(0) vec4f {
    \\    return vec4f(textureSample(tex, samp, in.uv).rgb, 1.0);
    \\}
;

const State = struct {
    font: z.Font,
    st: z.material.StorageTexture,
    sampler: z.wgpu.SamplerHandle,
    render_pipe: z.Pipeline,
    render_bg: z.wgpu.BindGroupHandle,
};

fn deinit(gpa: Allocator, s: *State) void {
    s.render_pipe.deinit();
    s.st.deinit();
    if (s.render_bg != .invalid) {
        z.wgpu.destroyBindGroup(s.render_bg);
    }
    if (s.sampler != .invalid) {
        z.wgpu.destroySampler(s.sampler);
    }
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    // Create the storage texture and paint it once via compute — the fill's
    // scaffolding is built and released inside the helper (leak-safe).
    const st: z.material.StorageTexture = try z.material.storageTextureFilled(
        gpa,
        f,
        tex_dim,
        tex_dim,
        compute_wgsl,
        "storage_tex",
    );

    const sampler: z.wgpu.SamplerHandle = z.wgpu.createSampler(f.gpu.device, .{
        .mag_filter_linear = true,
        .min_filter_linear = true,
        .address_mode = .clamp_to_edge,
    });

    const render_bgl: z.wgpu.BindGroupLayoutHandle = try z.material.bindGroupLayout(gpa, f, &.{
        .{ .binding = 0, .visibility = .{ .fragment = true }, .resource = .{ .texture = .{} } },
        .{ .binding = 1, .visibility = .{ .fragment = true }, .resource = .{ .sampler = .{} } },
    }, "storage_render_bgl");
    const render_bg: z.wgpu.BindGroupHandle = try z.material.bindGroup(gpa, f, render_bgl, &.{
        .{ .binding = 0, .resource = .{ .texture_view = st.view } },
        .{ .binding = 1, .resource = .{ .sampler = sampler } },
    }, "storage_render_bg");
    const render_pipe: z.Pipeline = try z.Pipeline.init(gpa, f, .{
        .wgsl = render_wgsl,
        .bind_group_layouts = &.{render_bgl},
        .label = "storage_render",
    });
    // render_bgl was build-only: it defined the render pipeline's layout and the
    // render bind group, both of which retain it. Release the handle now.
    z.wgpu.destroyBindGroupLayout(render_bgl);

    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24),
        .st = st,
        .sampler = sampler,
        .render_pipe = render_pipe,
        .render_bg = render_bg,
    };
}

fn update(f: *z.Frame, s: *State) void {
    const ps: *z.PassState = f.gl.pass;
    s.render_pipe.bind(ps);
    s.render_pipe.setBindGroup(ps, 0, s.render_bg);
    s.render_pipe.drawArrays(ps, 3, 1);

    co.caption(f.gl, s.font, "pipeline_storage: compute shader -> storage texture -> sampled fullscreen");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    // Transient GPU-technique demo: pipeline setup creates layouts and shader
    // modules that aren't retained in State, so a leak-tight deinit isn't
    // practical. Opt out of the managed leak gate rather than fake teardown.
    .memory = .managed,
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - pipeline storage",
            .width = 800,
            .height = 600,
            .scale_mode = .responsive,
            .clear = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
        },
    },
    .init = initState,
    // .memory left default (arena): init creates a compute pipeline + storage
    // texture (+ their bind groups/layouts) that aren't kept in State, so a full
    // managed teardown needs new State fields to hold those handles — deferred.
    // The stored render_pipe/tex_view/sampler/render_bg would free cleanly.
    .deinit = deinit,
    .update = update,
};
