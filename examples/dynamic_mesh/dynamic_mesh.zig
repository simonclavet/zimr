//! dynamic_mesh — port of the GL `dynamic_mesh`: a quad whose four corners
//! breathe in and out radially each frame via `updateMeshBuffer`, proving the
//! dynamic-vertex path. Built as a 4-vertex indexed mesh; the per-frame corner
//! positions are written into the mesh's position array, which the retained
//! draw path re-reads each frame (Step 3a). Drawn as a Model in a fixed camera.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");

const zm = @import("zm");
const Camera3D = zm.Camera3D;
const pointVec = zm.pointVec;
const vec = zm.vec;
const co = @import("example_common");
const c = z.colors;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const base_positions: [12]f32 = .{
    -1, -1, 0,
    1,  -1, 0,
    1,  1,  0,
    -1, 1,  0,
};

const State = struct {
    font: z.Font,
    quad: z.Mesh,
    model: z.Model,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.unloadModel(gpa, s.model);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    var mesh: z.Mesh = std.mem.zeroes(z.Mesh);
    mesh.vertexCount = 4;
    mesh.triangleCount = 2;

    // Position buffer — 12 floats, overwritten per-frame by updateMeshBuffer.
    const verts: []f32 = try gpa.alloc(f32, 12);
    @memcpy(verts, &base_positions);
    mesh.vertices = verts.ptr;

    // Texcoords (unused visually; present for attribute completeness).
    const texs: []f32 = try gpa.alloc(f32, 8);
    @memcpy(texs, &[8]f32{ 0, 0, 1, 0, 1, 1, 0, 1 });
    mesh.texcoords = texs.ptr;

    // Normals — all face +Z.
    const norms: []f32 = try gpa.alloc(f32, 12);
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        norms[i * 3 + 0] = 0;
        norms[i * 3 + 1] = 0;
        norms[i * 3 + 2] = 1;
    }
    mesh.normals = norms.ptr;

    // Indices — two triangles forming the quad.
    const idx: []u16 = try gpa.alloc(u16, 6);
    @memcpy(idx, &[6]u16{ 0, 1, 2, 0, 2, 3 });
    mesh.indices = idx.ptr;

    try z.uploadMesh(gpa, &mesh, true);
    const model: z.Model = try z.loadModelFromMesh(f.gl, gpa, mesh);

    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24),
        .quad = mesh,
        .model = model,
    };
}

fn update(f: *z.Frame, s: *State) void {
    // Breathing corner positions, then upload into attribute slot 0 (positions).
    const t: f32 = f.time.time;
    const radial: f32 = 1.0 + 0.3 * @sin(t * 2.5);
    const corners: [12]f32 = .{
        base_positions[0] * radial, base_positions[1] * radial,  0,
        base_positions[3] * radial, base_positions[4] * radial,  0,
        base_positions[6] * radial, base_positions[7] * radial,  0,
        base_positions[9] * radial, base_positions[10] * radial, 0,
    };
    z.updateMeshBuffer(s.quad, 0, std.mem.sliceAsBytes(corners[0..]), 0);

    z.clearViewport(f, co.palette.bg);

    const cam: Camera3D = .{
        .position = pointVec(0, 0, 4),
        .target = pointVec(0, 0, 0),
        .up = vec(0, 1, 0),
        .fovy_deg = 60,
        .projection = 0,
    };
    z.beginMode3D(f.gl, cam);
    z.drawModel(f.gl, s.model, pointVec(0, 0, 0), 1.0, c.sky_400);
    z.endMode3D(f.gl);

    co.caption(f.gl, s.font, "WebGPU dynamic mesh - updateMeshBuffer breathes the quad corners");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - dynamic mesh",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
