//! shaders_vertex_displacement - the GPU displacement-mapping showcase for
//! vertex texture fetch. A flat grid is pushed into a living, lit 3D surface by
//! sampling a Perlin heightfield IN THE VERTEX SHADER: three samples per vertex
//! (the height plus two neighbours), from which the surface normal is computed
//! in the vertex stage too. The heightfield is one static texture; scrolling the
//! vertex-stage lookup by time animates it into moving swells. Lit with a
//! height-graded colour + specular glint, depth-tested, orbited with the phone
//! camera.
//!
//! This replaces the earlier CPU fallback - its premise, "zimr's vertex stage
//! doesn't sample textures", no longer holds now that vertex texture fetch works.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec = zm.Vec;
const Camera3D = zm.Camera3D;
const pointVec = zm.pointVec;
const common = @import("example_common");
const float = zm.float;

const vs_wgsl = @embedFile("shaders_vertex_displacement_vs.wgsl");
const fs_wgsl = @embedFile("shaders_vertex_displacement_fs.wgsl");
const vs_io = @import("shaders_vertex_displacement_vs_io.zig");
const fs_io = @import("shaders_vertex_displacement_fs_io.zig");
const atkinson = @embedFile("atkinson_mono_ttf");

const grid_n: usize = 96; // cells per side
const verts_side: usize = grid_n + 1;
const vertex_count: usize = verts_side * verts_side;
const index_count: usize = grid_n * grid_n * 6;
const plane_size: f32 = 12.0;
const amplitude: f32 = 1.7;
const frequency: f32 = 1.6;
const texel: f32 = 1.5 / float(grid_n);

const State = struct {
    font: z.Font,
    cam: z.OrbitCamera,
    shader: z.shader.LoadedShader(vs_io),
    vbo: z.wgpu.BufferHandle,
    ibo: z.wgpu.BufferHandle,
    tex: z.WgpuTexture,
};

fn identity() [4]Vec {
    return .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } };
}

fn deinit(gpa: Allocator, s: *State) void {
    // Examples run under `.managed` with leak checking on, so free every GPU
    // resource we created (buffers, the heightfield texture, and the shader's
    // pipeline + bind groups) plus the font. `.arena` is only for external apps
    // that opt out of leak checking.
    s.shader.deinit();
    s.tex.deinit();
    z.wgpu.destroyBuffer(s.vbo);
    z.wgpu.destroyBuffer(s.ibo);
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    // Grid vertices: (worldX, worldZ, u, v). The height (Y) is added in the VS.
    const verts: []f32 = try gpa.alloc(f32, vertex_count * 4);
    defer gpa.free(verts);
    var gz: usize = 0;
    while (gz < verts_side) : (gz += 1) {
        var gx: usize = 0;
        while (gx < verts_side) : (gx += 1) {
            const u: f32 = float(gx) / float(grid_n);
            const v: f32 = float(gz) / float(grid_n);
            const i: usize = (gz * verts_side + gx) * 4;
            verts[i + 0] = (u - 0.5) * plane_size;
            verts[i + 1] = (v - 0.5) * plane_size;
            verts[i + 2] = u;
            verts[i + 3] = v;
        }
    }

    // Two triangles per cell.
    const idx: []u16 = try gpa.alloc(u16, index_count);
    defer gpa.free(idx);
    var n: usize = 0;
    gz = 0;
    while (gz < grid_n) : (gz += 1) {
        var gx: usize = 0;
        while (gx < grid_n) : (gx += 1) {
            const a: u16 = @intCast(gz * verts_side + gx);
            const b: u16 = @intCast(gz * verts_side + gx + 1);
            const c: u16 = @intCast((gz + 1) * verts_side + gx + 1);
            const d: u16 = @intCast((gz + 1) * verts_side + gx);
            idx[n + 0] = a;
            idx[n + 1] = b;
            idx[n + 2] = c;
            idx[n + 3] = a;
            idx[n + 4] = c;
            idx[n + 5] = d;
            n += 6;
        }
    }

    const vbo: z.wgpu.BufferHandle = z.wgpu.createBuffer(f.gpu.device, .{
        .size = verts.len * @sizeOf(f32),
        .usage = .{ .vertex = true, .copy_dst = true },
        .label = "vdisp_vbo",
    });
    z.wgpu.queueWriteBuffer(f.gpu.queue, vbo, 0, std.mem.sliceAsBytes(verts));

    const ibo: z.wgpu.BufferHandle = z.wgpu.createBuffer(f.gpu.device, .{
        .size = idx.len * @sizeOf(u16),
        .usage = .{ .index = true, .copy_dst = true },
        .label = "vdisp_ibo",
    });
    z.wgpu.queueWriteBuffer(f.gpu.queue, ibo, 0, std.mem.sliceAsBytes(idx));

    // Perlin heightfield. MIRROR_REPEAT addressing (not clamp) so the vertex
    // shader can sample at uv*freq > 1 - and once scrolling pushes the lookup
    // past 1 - and have the noise wrap instead of smearing the texture's edge
    // texels into flat / 1D-striped regions. Mirror (not plain repeat) keeps the
    // height continuous across the wrap since genImagePerlinNoise isn't tileable.
    // Linear filtering keeps the surface smooth. loadTextureFromImage would give
    // a clamp + nearest sampler, so build the texture directly.
    const img: z.Image = try z.genImagePerlinNoise(gpa, 256, 256, 0, 0, 6.0);
    const iw: u32 = @intCast(img.width);
    const ih: u32 = @intCast(img.height);
    const pixels: []const u8 = @as([*]const u8, @ptrCast(img.data.?))[0 .. iw * ih * 4];
    const tex: z.WgpuTexture = z.WgpuTexture.createFromPixels(f.gpu.device, f.gpu.queue, .{
        .width = iw,
        .height = ih,
        .pixels = pixels,
        .mag_filter_linear = true,
        .min_filter_linear = true,
        .address_mode = .mirror_repeat,
        .label = "heightfield",
    });
    z.unloadImage(gpa, img);

    const shader: z.shader.LoadedShader(vs_io) = try z.shader.loadShaderVF(vs_io, fs_io, .{
        .f = f.gpu,
        .gpa = gpa,
        .vs_wgsl_source = vs_wgsl,
        .fs_wgsl_source = fs_wgsl,
        .vertex_buffer_layouts = &.{z.shader.vertexLayout(vs_io)},
        .depth_state = .less_equal,
        .initial_ubo = .{ .mvp = identity(), .wave = .{ 0, amplitude, frequency, texel }, .cam = .{ 0, 0, 0, 0 } },
        .textures = .{ .height = tex },
        .label = "shaders_vertex_displacement",
    });

    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson, 22),
        .cam = z.OrbitCamera.init(pointVec(0, 0, 0), 19.0),
        .shader = shader,
        .vbo = vbo,
        .ibo = ibo,
        .tex = tex,
    };
}

fn update(f: *z.Frame, s: *State) void {
    const aspect: f32 = f.window.widthf() / @max(f.window.heightf(), 1.0);
    const cam: Camera3D = s.cam.update(f, false, .{ .min_distance = 9.0, .max_distance = 40.0 });
    const mvp: [4]Vec = cam.viewProj(aspect, 0.1, 120.0);
    const slope: f32 = amplitude / (texel * plane_size);

    s.shader.pushUbo(f.gpu.queue, .{
        .mvp = mvp,
        .wave = .{ f.time.time, amplitude, frequency, texel },
        .cam = .{ cam.position[0], cam.position[1], cam.position[2], slope },
    });

    z.clearViewport(f, .{ .r = 6, .g = 10, .b = 18, .a = 255 });
    const ps: *z.PassState = f.gl.pass;
    // Bracket the custom pipeline draw so the 2D immediate batch (the clear quad
    // plus the text below) always flushes under the 2D pipeline, never ours -
    // our vertex-visible sampler sits at the batch's reserved group 1. See the
    // guard in gpu_iface.flushBatch and the note on LoadedShader.bindForDraw.
    f.gl.flushBeforeMaterialSwap();
    s.shader.bindForDraw(ps);
    s.shader.setVertex(ps, 0, s.vbo, vertex_count * 4 * @sizeOf(f32));
    s.shader.setIndex(ps, s.ibo, .uint16, index_count * @sizeOf(u16));
    s.shader.drawIndexed(ps, @intCast(index_count), 1);
    f.gl.renderer().bindForPass(ps);

    f.gl.text(.{ 16, 16 }, "Vertex Displacement", .{ .size = 24, .color = common.palette.ink, .font = &s.font });
    f.gl.text(
        .{ 16, 46 },
        "a Perlin heightfield sampled in the VERTEX SHADER; normals computed there too",
        .{ .size = 14, .color = common.palette.ink_dim, .font = &s.font },
    );
    common.caption(f.gl, s.font, "GPU vertex texture fetch - drag to orbit, pinch/wheel to zoom");
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - shaders - vertex displacement (GPU heightfield)",
            .width = 960,
            .height = 600,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
