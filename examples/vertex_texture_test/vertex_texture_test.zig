//! vertex_texture_test — the end-to-end proof that zimr can sample a texture in
//! the VERTEX stage.  A flat grid of triangles is warped in the vertex shader by
//! reading a checkerboard texture (via the explicit-LOD `warpLevel` accessor) and
//! offsetting each vertex.  A distorted grid (not a clean one) means vertex
//! texture fetch works end-to-end: schema-declared vertex-visible sampler ->
//! bind-group layout -> `textureSampleLevel` in the VS.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec = zm.Vec;
const co = @import("example_common");

const vs_wgsl = @embedFile("vertex_texture_test_vs.wgsl");
const fs_wgsl = @embedFile("vertex_texture_test_fs.wgsl");
const vs_io = @import("vertex_texture_test_vs_io.zig");
const fs_io = @import("vertex_texture_test_fs_io.zig");
const roboto = @embedFile("roboto_mono_ttf");

const grid: usize = 24;
const span: f32 = 1.7;

const State = struct {
    font: z.Font,
    shader: z.shader.LoadedShader(vs_io),
    vbo: z.wgpu.BufferHandle,
    warp: z.WgpuTexture,
    vertex_count: u32,
};

fn scale2d(sx: f32, sy: f32) [4]Vec {
    return .{
        .{ sx, 0, 0, 0 },
        .{ 0, sy, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    // `.managed`: free every GPU resource we created plus the font (see the
    // policy on AppSpec.memory — examples must be leak-tight).
    s.shader.deinit();
    s.warp.deinit();
    z.wgpu.destroyBuffer(s.vbo);
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const verts: usize = grid * grid * 6;
    const data: []f32 = try gpa.alloc(f32, verts * 4);
    defer gpa.free(data);
    var n: usize = 0;
    var gz: usize = 0;
    while (gz < grid) : (gz += 1) {
        var gx: usize = 0;
        while (gx < grid) : (gx += 1) {
            const s0: f32 = zm.float(gx) / zm.float(grid);
            const s1: f32 = zm.float(gx + 1) / zm.float(grid);
            const t0: f32 = zm.float(gz) / zm.float(grid);
            const t1: f32 = zm.float(gz + 1) / zm.float(grid);
            const x0: f32 = (s0 - 0.5) * span;
            const x1: f32 = (s1 - 0.5) * span;
            const y0: f32 = (t0 - 0.5) * span;
            const y1: f32 = (t1 - 0.5) * span;
            const corners = [4][4]f32{
                .{ x0, y0, s0, t0 },
                .{ x1, y0, s1, t0 },
                .{ x1, y1, s1, t1 },
                .{ x0, y1, s0, t1 },
            };
            const order = [6]usize{ 0, 1, 2, 0, 2, 3 };
            for (order) |ci| {
                @memcpy(data[n .. n + 4], &corners[ci]);
                n += 4;
            }
        }
    }

    const vbo: z.wgpu.BufferHandle = z.wgpu.createBuffer(f.gpu.device, .{
        .size = data.len * @sizeOf(f32),
        .usage = .{ .vertex = true, .copy_dst = true },
        .label = "vtx_test_vbo",
    });
    z.wgpu.queueWriteBuffer(f.gpu.queue, vbo, 0, std.mem.sliceAsBytes(data));

    const warp: z.WgpuTexture = try z.WgpuTexture.createCheckerboard(
        f.gpu.device,
        f.gpu.queue,
        gpa,
        .{ 255, 90, 40, 255 },
        .{ 40, 120, 255, 255 },
        64,
        8,
    );

    const shader: z.shader.LoadedShader(vs_io) = try z.shader.loadShaderVF(vs_io, fs_io, .{
        .f = f.gpu,
        .gpa = gpa,
        .vs_wgsl_source = vs_wgsl,
        .fs_wgsl_source = fs_wgsl,
        .vertex_buffer_layouts = &.{z.shader.vertexLayout(vs_io)},
        .initial_ubo = .{ .transform = scale2d(1, 1) },
        .textures = .{ .warp = warp },
        .label = "vertex_texture_test",
    });

    s.* = .{
        .font = try z.loadFont(f, gpa, roboto, 22),
        .shader = shader,
        .vbo = vbo,
        .warp = warp,
        .vertex_count = @intCast(verts),
    };
}

fn update(f: *z.Frame, s: *State) void {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const aspect: f32 = w / @max(h, 1.0);
    const sx: f32 = if (aspect < 1.0) 1.0 else 1.0 / aspect;
    const sy: f32 = if (aspect < 1.0) aspect else 1.0;
    s.shader.pushUbo(f.gpu.queue, .{ .transform = scale2d(sx, sy) });

    z.clearViewport(f, .{ .r = 12, .g = 16, .b = 26, .a = 255 });
    const ps: *z.PassState = f.gl.pass;
    // The 2D immediate-mode batch reserves bind group 1 for its texture atlas
    // (gpu_iface.batch_reserved_group) — the SAME group our vertex-visible
    // sampler occupies. `flushBatch` drains the batch but does NOT rebind the
    // pipeline (that's the consumer's job), so we bracket the custom draw:
    //   1. drain the pending clearViewport quad now, while the 2D pipeline is
    //      still bound, so it composites as the background under the 2D pipeline;
    //   2. after our draw, restore the 2D pipeline (+ its ortho group 0) so the
    //      text/caption material-swap flush below runs under the 2D pipeline
    //      instead of ours (which would set the atlas at group 1 against our
    //      pipeline → the "resources_bgl does not match" validation error).
    // This is the same bracketing draw3d.zig uses around its point/decal draws.
    f.gl.flushBeforeMaterialSwap();
    s.shader.bindForDraw(ps);
    s.shader.setVertex(ps, 0, s.vbo, s.vertex_count * 4 * @sizeOf(f32));
    s.shader.draw(ps, s.vertex_count, 1);
    f.gl.renderer().bindForPass(ps);

    f.gl.text(.{ 16, 16 }, "Vertex Texture Fetch", .{ .size = 22, .color = co.palette.ink, .font = &s.font });
    co.caption(f.gl, s.font, "grid warped by a texture sampled IN THE VERTEX SHADER (textureSampleLevel)");
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - shaders - vertex texture fetch (smoke test)",
            .width = 900,
            .height = 700,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
