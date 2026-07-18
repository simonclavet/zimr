//! draw3d — the 3D library: immediate-mode primitives + the retained-mesh
//! API for the WebGPU backend, AND (since GL-retirement P5) the CPU
//! model/mesh library merged in from drawing.models: mesh generators
//! (plane/cone/cylinder/torus/knot/poly/tangents), collision + bounds +
//! raycast math, glTF model/animation loading, CPU pose evaluation
//! (updateModelAnimation/Blend), and CPU material descriptors.

const std = @import("std");
const gpu = @import("gpu.zig");
const ArrayList = std.ArrayList;
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;

/// Flip to `true` to re-enable the on-page `pbr3d.*` diagnostic logs
/// (glTF load counts, resolved map sizes, per-draw eye position). Off by
/// default so release standalones don't print over the scene.
const log_pbr3d: bool = false;
const zm = @import("zm");
const Quat = zm.Quat;
const Mat = zm.Mat;
const Vec3 = zm.Vec3;
const clamp = zm.clamp;
const cross = zm.cross;
const dot3 = zm.dot3;
const f32x4 = zm.f32x4;
const float = zm.float;
const identity = zm.identity;
const int = zm.int;
const length3 = zm.length3;
const lengthSq3 = zm.lengthSq3;
const lengthSq4 = zm.lengthSq4;
const lerp = zm.lerp;
const matFromQuat = zm.matFromQuat;
const mulMat = zm.mulMat;
const mulMatVec = zm.mulMatVec;
const Vec2 = zm.Vec2;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const perspectiveFovRh = zm.perspectiveFovRh;
const lookAtRh = zm.lookAtRh;
const inverse = zm.inverse;
const normalize4 = zm.normalize4;
const perpendicular3 = zm.perpendicular3;
const pi = zm.pi;
const tau = zm.tau;
const pointFromArr3 = zm.pointFromArr3;
const quat_identity = zm.quat_identity;
const rotateByAxisAngle3 = zm.rotateByAxisAngle3;
const safeNormalize3 = zm.safeNormalize3;
const scaling = zm.scaling;
const slerp = zm.slerp;
const translation = zm.translation;
const vec = zm.vec;
const vec4 = zm.vec4;
const assert = zm.assert;
const assertf = zm.assertf;
const wgpu = @import("wgpu.zig");
const shader = @import("shader_runtime_wgpu.zig");
const shader_iface = @import("shader_interface");
const render_pass = @import("wgpu.zig").render_pass;
const shader_introspect = @import("shader_introspect.zig");
const wgpu_texture = @import("wgpu_texture.zig");
const WgpuTexture = wgpu_texture.WgpuTexture;
const WgpuBackend = @import("gpu_iface.zig").WgpuBackend;

const types = @import("types.zig");
const Color = zm.Color;

// ============================================================================
// Static unit-cube geometry (CPU-side, expanded per drawCube into the batch)
// ============================================================================

/// One local-space cube corner: position + face normal. Stride 24.
pub const CubeVertex = extern struct {
    pos: [3]f32,
    normal: [3]f32,
};

const half: f32 = 0.5;

/// Unit cube centred at the origin, edge length 1. Six faces, four verts each,
/// wound CCW from outside (back faces culled).
pub const cube_vertices = [24]CubeVertex{
    .{ .pos = .{ -half, -half, half }, .normal = .{ 0, 0, 1 } },
    .{ .pos = .{ half, -half, half }, .normal = .{ 0, 0, 1 } },
    .{ .pos = .{ half, half, half }, .normal = .{ 0, 0, 1 } },
    .{ .pos = .{ -half, half, half }, .normal = .{ 0, 0, 1 } },
    .{ .pos = .{ half, -half, -half }, .normal = .{ 0, 0, -1 } },
    .{ .pos = .{ -half, -half, -half }, .normal = .{ 0, 0, -1 } },
    .{ .pos = .{ -half, half, -half }, .normal = .{ 0, 0, -1 } },
    .{ .pos = .{ half, half, -half }, .normal = .{ 0, 0, -1 } },
    .{ .pos = .{ half, -half, half }, .normal = .{ 1, 0, 0 } },
    .{ .pos = .{ half, -half, -half }, .normal = .{ 1, 0, 0 } },
    .{ .pos = .{ half, half, -half }, .normal = .{ 1, 0, 0 } },
    .{ .pos = .{ half, half, half }, .normal = .{ 1, 0, 0 } },
    .{ .pos = .{ -half, -half, -half }, .normal = .{ -1, 0, 0 } },
    .{ .pos = .{ -half, -half, half }, .normal = .{ -1, 0, 0 } },
    .{ .pos = .{ -half, half, half }, .normal = .{ -1, 0, 0 } },
    .{ .pos = .{ -half, half, -half }, .normal = .{ -1, 0, 0 } },
    .{ .pos = .{ -half, half, half }, .normal = .{ 0, 1, 0 } },
    .{ .pos = .{ half, half, half }, .normal = .{ 0, 1, 0 } },
    .{ .pos = .{ half, half, -half }, .normal = .{ 0, 1, 0 } },
    .{ .pos = .{ -half, half, -half }, .normal = .{ 0, 1, 0 } },
    .{ .pos = .{ -half, -half, -half }, .normal = .{ 0, -1, 0 } },
    .{ .pos = .{ half, -half, -half }, .normal = .{ 0, -1, 0 } },
    .{ .pos = .{ half, -half, half }, .normal = .{ 0, -1, 0 } },
    .{ .pos = .{ -half, -half, half }, .normal = .{ 0, -1, 0 } },
};

/// 36 indices: two triangles per face (CPU-expanded into the batch).
pub const cube_indices = blk: {
    var idx: [36]u32 = undefined;
    var face: u32 = 0;
    while (face < 6) : (face += 1) {
        const base: u32 = face * 4;
        const o: u32 = face * 6;
        idx[o + 0] = base + 0;
        idx[o + 1] = base + 1;
        idx[o + 2] = base + 2;
        idx[o + 3] = base + 0;
        idx[o + 4] = base + 2;
        idx[o + 5] = base + 3;
    }
    break :blk idx;
};

// ============================================================================
// Batch vertex stream + shader schema
// ============================================================================

/// One vertex in the dynamic batch: world-space position + world-space normal
/// + colour. Stride 40 — position vec3 @0, normal vec3 @12, colour vec4 @24.
pub const BatchVertex = extern struct {
    pos: [3]f32,
    normal: [3]f32,
    color: [4]f32,
};

/// Capacity of the batch vertex buffer (vertices). 262144 verts / 36 per cube
/// ≈ 7280 cubes, or ~227 spheres at 12×16 tessellation. Fixed (no grow): excess
/// primitives in a frame are dropped rather than reallocating mid-draw. Sized
/// generously so dense immediate-mode scenes (e.g. the physics demo's Plinko
/// board: ~50 pegs + ~50 balls = ~100 spheres ≈ 115K verts) render in full
/// rather than silently truncating bodies past the budget.
const batch_capacity: u32 = 262144;

/// Normal assigned to line vertices. It equals the shader's fixed light
/// direction (already unit-length), so n·l == 1 → full brightness: lines render
/// flat/unlit through the same lit cube3d shader, no shader branch needed.
const line_normal: [3]f32 = .{ 0.36, 0.80, 0.48 };

// ---- Instancing (Step 4): a separate GPU pipeline. The mesh stays in LOCAL
// space in a GPU vertex buffer (pos+normal), and a per-instance buffer supplies
// the model matrix (four vec4 columns) + colour with instance step-mode, so N
// copies render in ONE instanced draw. This is distinct from the immediate
// batch (which bakes the model transform into world-space verts on the CPU).

/// One vertex of a GPU-resident instanced mesh: local position + normal,
/// interleaved (24 bytes). Colour is per-instance, not per-vertex.
pub const MeshVertex = extern struct {
    pos: [3]f32,
    normal: [3]f32,
};

/// Per-instance data, instance-step. `model` is column-major (matches zm.Mat
/// and the four vec4 attributes the instanced VS reads at locations 2–5), stored
/// as `[4][4]f32` so this stays an extern struct with a guaranteed layout on
/// every target (Zig 1245 bans `@Vector` fields in extern structs on CPU); the
/// bytes are identical to `[4]@Vector(4, f32)`. `color` rides at location 6.
/// 80 bytes.
pub const InstanceVertex = extern struct {
    model: [4][4]f32,
    color: [4]f32,
};

/// GPU buffers for one uploaded mesh, indexed by `Mesh.vaoId − 1` in the
/// `mesh_gpu` registry (vaoId 0 = not yet uploaded). Built lazily on the first
/// `drawMeshInstanced` (uploadMesh's signature carries no device).
const MeshGpu = struct {
    vbo: wgpu.BufferHandle,
    ibo: wgpu.BufferHandle,
    index_count: u32,
};

/// WGSL for the instanced VS (emitted from `src/shaders/cube3d_instanced_vs.zig`
/// by the shader pipeline). Reuses `cube3d_fs` for shading.
const cube_instanced_vs_wgsl = @embedFile("cube3d_instanced_vs.wgsl");

/// UBO (group 0): the camera view-projection, mirroring
/// `cube3d_vs_io.Ubo` field-for-field.
pub const CubeSchema = struct {
    pub const Ubo = struct {
        view_projection: [4]Vec = .{
            .{ 1, 0, 0, 0 },
            .{ 0, 1, 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ 0, 0, 0, 1 },
        },
    };
};

// WGSL emitted by the typed shader pipeline from `src/shaders/cube3d_vs.zig`
// and `cube3d_fs.zig` (Zig → SPIR-V → spv2wgsl), wired into the zimr
// module by build.zig's engine-shader discovery loop.
const cube_vs_wgsl = @embedFile("cube3d_vs.wgsl");
const cube_fs_wgsl = @embedFile("cube3d_fs.wgsl");

// ---- Textured-3D (drawCubeTexture / drawBillboard) ----
// A small dedicated pipeline that samples a texture in the same depth-tested 3D
// pass as the solid cube batch. Group 0 reuses Cube3D's camera UBO (shared,
// compatible layout); group 1 is a per-texture {texture, sampler} bind group.
// WGSL is generated from typed pure-Zig shaders (src/shaders/billboard_{vs,fs}.zig,
// entry-point `entry`) via the .zig→SPIR-V→spv2wgsl pipeline — the FS through the
// sampler-rewrite path (zsample2d + zspv). No inline WGSL remains.
const TexVertex = extern struct { pos: [3]f32, uv: [2]f32, color: [4]f32 };
const TexDraw = struct {
    bind_group: wgpu.BindGroupHandle,
    pipeline: wgpu.RenderPipelineHandle,
    first: u32,
    count: u32,
};
const tex_capacity: usize = 8192;

// ---- Shader-projected decals ----
// Per-decal uniform (group 1): world→box projector + tint + packed params
// (x = half box size, y = 1/decal_size). Three vec4-aligned members (std140).
const DecalUbo = struct {
    projector: [4]Vec,
    color: Vec,
    params: Vec,
    // World-space direction the projector faces along (the surface normal at the
    // hit). The FS rejects fragments whose own normal faces away from this, so a
    // decal only paints the surface facing the projector — never the far wall of
    // its box (e.g. the back of the sphere showing through the front).
    forward: Vec,
};
// A receiver mesh uploaded once as a pos-only vertex buffer (world-space
// positions). Re-drawn per decal that targets it; no per-frame re-upload.
const DecalReceiver = struct {
    vbo: wgpu.BufferHandle,
    vcount: u32,
};
// One recorded decal: which receiver to redraw, which projector-UBO ring slot
// holds its DecalUbo, and the decal texture's bind group.
const DecalDraw = struct {
    receiver: u32,
    proj_slot: u32,
    tex_bg: wgpu.BindGroupHandle,
};
// Projector-UBO ring: each decal in a frame needs its own (buffer, offset) so a
// later decal's projector write can't clobber an earlier one on the queue
// timeline (the pbr3d/renderer2d ring lesson). 64 covers the example cap.
const decal_ring_len: u32 = 64;

/// Slots in the per-pass view-projection ring: ONE per `beginMode3D` in a frame.
/// 16 is far past what any example opens (a split screen needs 2, the deferred
/// demo 3); the encoder-scoped assert below turns an overflow into a loud panic
/// rather than a silent clobber.
const vp_ring_len: u32 = 16;
/// WebGPU's minimum uniform-buffer binding offset alignment.
const vp_ubo_stride: u64 = 256;
// 256-byte stride: WebGPU requires dynamic UBO offsets to be 256-aligned, and
// one DecalUbo (96 B) fits comfortably.
const decal_ubo_stride: u32 = 256;

// WGSL emitted by the typed shader pipeline from `src/shaders/billboard_vs.zig`
// and `billboard_fs.zig` (pure-Zig `@SpirvType` → SPIR-V → spv2wgsl). The FS goes
// through the proven sampler path — `zsample2d` + `zm.binding(&tex_sampler2d,1,0)`
// + `zspv --rewrite-samplers-wgsl` → real `@group(1)@binding(0) texture_2d<f32>`
// and `@group(1)@binding(1) sampler`, matching the per-texture bind group below.
// Auto-discovered + wired as anonymous imports by build.zig. Entry point `entry`.
const billboard_vs_wgsl = @embedFile("billboard_vs.wgsl");
const billboard_fs_wgsl = @embedFile("billboard_fs.wgsl");

// ---- Gradient skybox (drawSkybox) ----
// A fullscreen-triangle pass that fills the far background with a vertical
// gradient. The VS unprojects each NDC corner at z=1 through inverse_view_proj
// to a world ray; the FS lerps sky_bottom→sky_top by the ray's Y. Clip z is
// parked at 0.999999 (just inside the far plane) so it draws over cleared depth
// (1.0) but loses to any closer 3D — so it's always the background. One UBO at
// group 0, no vertex buffer (the VS uses @builtin(vertex_index)).
const SkyboxSchema = struct {
    pub const Ubo = struct {
        inv_view_proj: [4]Vec = .{
            .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 },
        },
        camera_pos: Vec = .{ 0, 0, 0, 0 },
        sky_bottom: Vec = .{ 0.8, 0.9, 1.0, 1.0 },
        sky_top: Vec = .{ 0.4, 0.6, 1.0, 1.0 },
    };
};

// WGSL emitted by the typed shader pipeline from `src/shaders/skybox_vs.zig`
// and `skybox_fs.zig` (pure-Zig `@SpirvType` → SPIR-V → spv2wgsl), wired in as
// anonymous imports by build.zig's shader auto-discovery loop. These shaders use
// only runtime-bits resources (uniform + vertex_index builtin), so no sampler
// rewrite is involved. Entry point is `entry` for both (see `.vs_entry_point`).
const skybox_vs_wgsl = @embedFile("skybox_vs.wgsl");
const skybox_fs_wgsl = @embedFile("skybox_fs.wgsl");

// WGSL emitted from src/shaders/decal_vs.zig / decal_fs.zig (direct @SpirvType,
// billboard pattern; FS through the sampler-rewrite path). The receiver mesh is
// drawn pos-only; the FS projects each fragment into decal-box space and paints
// the decal texture where it lands inside the box. Auto-discovered by build.zig.
const decal_vs_wgsl = @embedFile("decal_vs.wgsl");
const decal_fs_wgsl = @embedFile("decal_fs.wgsl");

/// Build one render pipeline for the 3D batch: depth-tested, with the given
/// topology + cull mode, sharing the cube3d shader modules, vertex layout, and
/// UBO layout.
fn makePipeline(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    pipeline_layout: wgpu.PipelineLayoutHandle,
    vs_module: wgpu.ShaderModuleHandle,
    fs_module: wgpu.ShaderModuleHandle,
    layout: gpu.VertexBufferLayout,
    topology: wgpu.PrimitiveTopology,
    cull: wgpu.CullMode,
    depth: wgpu.DepthMode,
    fmt: wgpu.TextureFormat,
) !wgpu.RenderPipelineHandle {
    const state_combo: gpu.StateCombo = gpu.StateCombo.fromParts(
        topology,
        .alpha,
        depth,
        cull,
        fmt,
        .depth24_plus,
        1,
    );
    const pipe_desc = gpu.RenderPipelineDescriptor{
        .vertex_buffer_layouts = &.{layout},
        .vs_entry_point = "entry",
        .fs_entry_point = "entry",
        .state = state_combo,
    };
    const blob: []const u8 = try gpu.encodeRenderPipelineDescriptor(gpa, pipe_desc);
    defer gpa.free(blob);
    return wgpu.createRenderPipeline(device, pipeline_layout, vs_module, fs_module, blob, "draw3d_pipe");
}

/// Build the instanced 3D pipeline: depth-tested triangles, no cull, with TWO
/// vertex buffers — the mesh (vertex step) and the per-instance data (instance
/// step). Shares the UBO bind-group layout via `pipeline_layout`.
fn makeInstancedPipeline(
    gpa: Allocator,
    device: wgpu.DeviceHandle,
    pipeline_layout: wgpu.PipelineLayoutHandle,
    vs_module: wgpu.ShaderModuleHandle,
    fs_module: wgpu.ShaderModuleHandle,
    mesh_layout: gpu.VertexBufferLayout,
    instance_layout: gpu.VertexBufferLayout,
    fmt: wgpu.TextureFormat,
) !wgpu.RenderPipelineHandle {
    const state_combo: gpu.StateCombo = gpu.StateCombo.fromParts(
        .triangle_list,
        .alpha,
        .less,
        .none,
        fmt,
        .depth24_plus,
        1,
    );
    const pipe_desc = gpu.RenderPipelineDescriptor{
        .vertex_buffer_layouts = &.{ mesh_layout, instance_layout },
        .vs_entry_point = "entry",
        .fs_entry_point = "entry",
        .state = state_combo,
    };
    const blob: []const u8 = try gpu.encodeRenderPipelineDescriptor(gpa, pipe_desc);
    defer gpa.free(blob);
    return wgpu.createRenderPipeline(device, pipeline_layout, vs_module, fs_module, blob, "draw3d_inst_pipe");
}

/// Convert an 8-bit Color to normalized f32 rgba for the vertex stream.
/// Unit-sphere direction (also the outward normal) at latitude `theta`
/// (0 = +Y pole .. pi = -Y pole) and longitude `phi`.
fn sphereDir(theta: f32, phi: f32) [3]f32 {
    const st: f32 = @sin(theta);
    return .{ st * @cos(phi), @cos(theta), st * @sin(phi) };
}

const Vec = zm.Vec;

/// World position of a unit direction scaled by `r` and offset to `center`.
fn radialPos(
    center: Vec,
    r: f32,
    dir: [3]f32,
) [3]f32 {
    return .{ center[0] + r * dir[0], center[1] + r * dir[1], center[2] + r * dir[2] };
}

/// Apply a rotation matrix to a vec3 (direction transform, w = 0).
fn rotateVec3(rot: Mat, v: [3]f32) [3]f32 {
    const out: Vec = mulMatVec(rot, vec4(v[0], v[1], v[2], 0.0));
    return .{ out[0], out[1], out[2] };
}

// ============================================================================
// Retained mesh tier (Step 3a): generated meshes + Model wrapping. The draw
// path (Cube3D.appendModel / appendModelWires below) CPU-transforms a mesh's
// vertex arrays into the immediate batch each frame — correct and fast at the
// mesh sizes these examples use. GPU-resident buffers + a per-instance model
// matrix (true instancing) arrive in Step 4 for high-count scenes.
// ============================================================================

/// Generate a box mesh of size width×height×length centred at the origin — 24
/// vertices (flat per-face normals), 36 indices. Mirrors raylib genMeshCube.
pub fn genMeshCube(
    gpa: Allocator,
    width: f32,
    height: f32,
    length: f32,
) Allocator.Error!types.Mesh {
    var mesh: types.Mesh = std.mem.zeroes(types.Mesh);
    const verts: []f32 = try gpa.alloc(f32, cube_vertices.len * 3);
    errdefer gpa.free(verts);
    const norms: []f32 = try gpa.alloc(f32, cube_vertices.len * 3);
    errdefer gpa.free(norms);
    const idx: []u16 = try gpa.alloc(u16, cube_indices.len);
    errdefer gpa.free(idx);
    for (cube_vertices, 0..) |cv, i| {
        verts[i * 3 + 0] = cv.pos[0] * width;
        verts[i * 3 + 1] = cv.pos[1] * height;
        verts[i * 3 + 2] = cv.pos[2] * length;
        norms[i * 3 + 0] = cv.normal[0];
        norms[i * 3 + 1] = cv.normal[1];
        norms[i * 3 + 2] = cv.normal[2];
    }
    for (cube_indices, 0..) |c, i| {
        idx[i] = @intCast(c);
    }
    mesh.vertexCount = @intCast(cube_vertices.len);
    mesh.triangleCount = @intCast(cube_indices.len / 3);
    mesh.vertices = verts.ptr;
    mesh.normals = norms.ptr;
    mesh.indices = idx.ptr;
    return mesh;
}

/// Generate an indexed UV sphere: `rings` latitude bands × `slices` longitude
/// segments, outward normals; (rings+1)·(slices+1) verts, rings·slices·2 tris.
/// Mirrors raylib genMeshSphere.
pub fn genMeshSphere(
    gpa: Allocator,
    radius: f32,
    rings: i32,
    slices: i32,
) Allocator.Error!types.Mesh {
    var mesh: types.Mesh = std.mem.zeroes(types.Mesh);
    if (rings < 3 or slices < 3) {
        return mesh;
    }
    const ru: usize = @intCast(rings);
    const su: usize = @intCast(slices);
    const rows: usize = ru + 1;
    const cols: usize = su + 1;
    const vcount: usize = rows * cols;
    const verts: []f32 = try gpa.alloc(f32, vcount * 3);
    errdefer gpa.free(verts);
    const norms: []f32 = try gpa.alloc(f32, vcount * 3);
    errdefer gpa.free(norms);
    const tris: usize = ru * su * 2;
    const idx: []u16 = try gpa.alloc(u16, tris * 3);
    errdefer gpa.free(idx);
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        const theta: f32 = pi * float(r) / float(ru);
        var s: usize = 0;
        while (s < cols) : (s += 1) {
            const phi_angle: f32 = 2.0 * pi * float(s) / float(su);
            const dir: [3]f32 = sphereDir(theta, phi_angle);
            const vi: usize = (r * cols + s) * 3;
            verts[vi + 0] = radius * dir[0];
            verts[vi + 1] = radius * dir[1];
            verts[vi + 2] = radius * dir[2];
            norms[vi + 0] = dir[0];
            norms[vi + 1] = dir[1];
            norms[vi + 2] = dir[2];
        }
    }
    var ii: usize = 0;
    r = 0;
    while (r < ru) : (r += 1) {
        var s: usize = 0;
        while (s < su) : (s += 1) {
            const a: u16 = @intCast(r * cols + s);
            const b: u16 = @intCast((r + 1) * cols + s);
            const c: u16 = @intCast(r * cols + s + 1);
            const d: u16 = @intCast((r + 1) * cols + s + 1);
            idx[ii + 0] = a;
            idx[ii + 1] = b;
            idx[ii + 2] = c;
            idx[ii + 3] = c;
            idx[ii + 4] = b;
            idx[ii + 5] = d;
            ii += 6;
        }
    }
    mesh.vertexCount = @intCast(vcount);
    mesh.triangleCount = @intCast(tris);
    mesh.vertices = verts.ptr;
    mesh.normals = norms.ptr;
    mesh.indices = idx.ptr;
    return mesh;
}

/// wgpu Step-3a no-op (kept for raylib parity): retained meshes draw from their
/// CPU vertex arrays via the immediate batch, so there is no separate GPU upload
/// yet. Step 4 (instanced drawing) makes this build the vertex/index buffers.
pub fn uploadMesh(
    gpa: Allocator,
    mesh: *types.Mesh,
    dynamic: bool,
) Allocator.Error!void {
    _ = gpa;
    _ = mesh;
    _ = dynamic;
}

/// Mean-of-RGB grayscale, matching the GL donor's height read.
inline fn grayValue(c: Color) f32 {
    return (float(c.r) + float(c.g) + float(c.b)) / 3.0;
}

/// Wrap a single mesh in a Model with an identity transform (no materials — the
/// unlit draw path takes a tint). Mirrors raylib loadModelFromMesh.
/// Heightmap image → triangle mesh (raylib `genMeshHeightmap`), ported from
/// the GL `drawing.zig` original for the wgpu retained-mesh path.  CPU
/// arrays only — pair with `loadModelFromMesh` like every other wgpu-side
/// mesh (no GL `uploadMesh` tail here; the wgpu draw path owns GPU
/// buffers).  `size` = world extents `(x, max_height, z)`; per-vertex
/// height comes from the pixel's grayscale.  Flat per-face normals, same
/// as the donor.  RGBA8 images only (what `image_gen` produces); other
/// formats error rather than mis-read.
pub fn genMeshHeightmap(
    gpa: Allocator,
    heightmap: types.Image,
    size: Vec,
) error{ OutOfMemory, UnsupportedImageFormat }!types.Mesh {
    var mesh: types.Mesh = std.mem.zeroes(types.Mesh);
    const map_x: i32 = heightmap.width;
    const map_z: i32 = heightmap.height;
    if (map_x < 2 or map_z < 2) {
        return mesh;
    }
    if (heightmap.format != @intFromEnum(types.PixelFormat.uncompressed_r8g8b8a8)) {
        return error.UnsupportedImageFormat;
    }
    const data: *anyopaque = heightmap.data orelse return mesh;
    const mx: usize = @intCast(map_x);
    const mz: usize = @intCast(map_z);
    const pixels: [*]const Color = @ptrCast(@alignCast(data));

    // (mx - 1) × (mz - 1) quads, each = 2 triangles = 6 vertices.
    const tri_count: usize = (mx - 1) * (mz - 1) * 2;
    const vertex_count: usize = tri_count * 3;
    const verts: []f32 = try gpa.alloc(f32, vertex_count * 3);
    errdefer gpa.free(verts);
    const norm: []f32 = try gpa.alloc(f32, vertex_count * 3);
    errdefer gpa.free(norm);
    const tex: []f32 = try gpa.alloc(f32, vertex_count * 2);
    errdefer gpa.free(tex);

    const sx: f32 = size[0] / float(mx - 1);
    const sy: f32 = size[1] / 255.0;
    const sz: f32 = size[2] / float(mz - 1);

    var v_off: usize = 0;
    var t_off: usize = 0;
    var zi: usize = 0;
    while (zi + 1 < mz) : (zi += 1) {
        var x: usize = 0;
        while (x + 1 < mx) : (x += 1) {
            const h00: f32 = grayValue(pixels[x + zi * mx]) * sy;
            const h01: f32 = grayValue(pixels[x + (zi + 1) * mx]) * sy;
            const h10: f32 = grayValue(pixels[(x + 1) + zi * mx]) * sy;
            const h11: f32 = grayValue(pixels[(x + 1) + (zi + 1) * mx]) * sy;
            const xf: f32 = float(x);
            const zf: f32 = float(zi);
            const positions = [_]f32{
                xf * sx,       h00, zf * sz,
                xf * sx,       h01, (zf + 1) * sz,
                (xf + 1) * sx, h10, zf * sz,
                (xf + 1) * sx, h10, zf * sz,
                xf * sx,       h01, (zf + 1) * sz,
                (xf + 1) * sx, h11, (zf + 1) * sz,
            };
            @memcpy(verts[v_off .. v_off + 18], &positions);

            // Per-triangle face normal from the cross product of two edges;
            // each set of 3 verts shares one normal.
            var i: usize = 0;
            while (i < 18) : (i += 9) {
                const ex: f32 = positions[i + 3] - positions[i + 0];
                const ey: f32 = positions[i + 4] - positions[i + 1];
                const ez: f32 = positions[i + 5] - positions[i + 2];
                const fx: f32 = positions[i + 6] - positions[i + 0];
                const fy: f32 = positions[i + 7] - positions[i + 1];
                const fz: f32 = positions[i + 8] - positions[i + 2];
                var nx: f32 = ey * fz - ez * fy;
                var ny: f32 = ez * fx - ex * fz;
                var nz: f32 = ex * fy - ey * fx;
                const len: f32 = @sqrt(nx * nx + ny * ny + nz * nz);
                if (len > 0) {
                    nx /= len;
                    ny /= len;
                    nz /= len;
                }
                var k: usize = 0;
                while (k < 9) : (k += 3) {
                    norm[v_off + i + k + 0] = nx;
                    norm[v_off + i + k + 1] = ny;
                    norm[v_off + i + k + 2] = nz;
                }
            }

            const tu0: f32 = xf / float(mx - 1);
            const tu1: f32 = (xf + 1) / float(mx - 1);
            const tv0: f32 = zf / float(mz - 1);
            const tv1: f32 = (zf + 1) / float(mz - 1);
            const tcs = [_]f32{
                tu0, tv0,
                tu0, tv1,
                tu1, tv0,
                tu1, tv0,
                tu0, tv1,
                tu1, tv1,
            };
            @memcpy(tex[t_off .. t_off + 12], &tcs);

            v_off += 18;
            t_off += 12;
        }
    }

    mesh.vertexCount = @intCast(vertex_count);
    mesh.triangleCount = @intCast(tri_count);
    mesh.vertices = verts.ptr;
    mesh.normals = norm.ptr;
    mesh.texcoords = tex.ptr;
    return mesh;
}

/// Cubicmap image → cube-walled maze mesh (raylib `GenMeshCubicmap`).
/// Each WHITE pixel becomes a solid 1×1 cube column of height `size.y`;
/// BLACK pixels are empty (floor). Top and bottom faces are always
/// emitted (so the map reads from above and below); each of the four
/// side walls is emitted ONLY where the neighbor cell is empty (or the
/// map edge) — walls shared between adjacent white cells are occluded
/// and skipped, which is what keeps the maze cheap. Per-face UVs index
/// a 2×2 atlas: right/left/front/back in the top row, top/bottom in the
/// bottom row (raylib's `cubicmap_atlas.png` layout). RGBA8 only.
pub fn genMeshCubicmap(
    gpa: Allocator,
    cubicmap: types.Image,
    cube_size: Vec,
) error{ OutOfMemory, UnsupportedImageFormat }!types.Mesh {
    var mesh: types.Mesh = std.mem.zeroes(types.Mesh);
    if (cubicmap.width < 1 or cubicmap.height < 1) {
        return mesh;
    }
    if (cubicmap.format != @intFromEnum(types.PixelFormat.uncompressed_r8g8b8a8)) {
        return error.UnsupportedImageFormat;
    }
    const data: *anyopaque = cubicmap.data orelse return mesh;
    const map_w: usize = @intCast(cubicmap.width);
    const map_h: usize = @intCast(cubicmap.height);
    const pixels: [*]const Color = @ptrCast(@alignCast(data));

    // Worst case: every cell a full cube (12 tris), 3 verts each.
    const max_verts: usize = map_w * map_h * 12 * 3;
    const verts: []f32 = try gpa.alloc(f32, max_verts * 3);
    errdefer gpa.free(verts);
    const norm: []f32 = try gpa.alloc(f32, max_verts * 3);
    errdefer gpa.free(norm);
    const tex: []f32 = try gpa.alloc(f32, max_verts * 2);
    errdefer gpa.free(tex);

    const w: f32 = cube_size[0];
    const h2: f32 = cube_size[1]; // wall height (y)
    const h: f32 = cube_size[2]; // cell depth (z)

    // 2×2 atlas sub-rects {x, y, w, h}, matching raylib's cubicmap_atlas.
    // (`half` = 0.5 is the file-scope constant.)
    const right_uv = [4]f32{ 0.0, 0.0, half, half };
    const left_uv = [4]f32{ half, 0.0, half, half };
    const front_uv = [4]f32{ 0.0, 0.0, half, half };
    const back_uv = [4]f32{ half, 0.0, half, half };
    const top_uv = [4]f32{ 0.0, half, half, half };
    const bottom_uv = [4]f32{ half, half, half, half };

    var v_off: usize = 0; // float index into verts (3 per vertex)
    var n_off: usize = 0;
    var t_off: usize = 0;

    const CG = struct {
        fn vert(vbuf: []f32, off: *usize, p: [3]f32) void {
            vbuf[off.*] = p[0];
            vbuf[off.* + 1] = p[1];
            vbuf[off.* + 2] = p[2];
            off.* += 3;
        }
        fn nrm(nbuf: []f32, off: *usize, nv: [3]f32) void {
            nbuf[off.*] = nv[0];
            nbuf[off.* + 1] = nv[1];
            nbuf[off.* + 2] = nv[2];
            off.* += 3;
        }
        fn uv(tbuf: []f32, off: *usize, u: f32, v: f32) void {
            tbuf[off.*] = u;
            tbuf[off.* + 1] = v;
            off.* += 2;
        }
    };

    var zc: usize = 0;
    while (zc < map_h) : (zc += 1) {
        var xc: usize = 0;
        while (xc < map_w) : (xc += 1) {
            const fx: f32 = float(@as(i32, @intCast(xc)));
            const fz: f32 = float(@as(i32, @intCast(zc)));
            // 8 cube corners (v1..v4 top ring, v5..v8 bottom ring).
            const v1 = [3]f32{ w * (fx - 0.5), h2, h * (fz - 0.5) };
            const v2 = [3]f32{ w * (fx - 0.5), h2, h * (fz + 0.5) };
            const v3 = [3]f32{ w * (fx + 0.5), h2, h * (fz + 0.5) };
            const v4 = [3]f32{ w * (fx + 0.5), h2, h * (fz - 0.5) };
            const v5 = [3]f32{ w * (fx + 0.5), 0, h * (fz - 0.5) };
            const v6 = [3]f32{ w * (fx - 0.5), 0, h * (fz - 0.5) };
            const v7 = [3]f32{ w * (fx - 0.5), 0, h * (fz + 0.5) };
            const v8 = [3]f32{ w * (fx + 0.5), 0, h * (fz + 0.5) };

            const c: Color = pixels[zc * map_w + xc];
            const is_white: bool = c.r == 255 and c.g == 255 and c.b == 255;
            if (!is_white) {
                continue;
            }

            // --- top face (always) : v1 v2 v3, v1 v3 v4, normal +Y ---
            inline for (.{ v1, v2, v3, v1, v3, v4 }) |p| {
                CG.vert(verts, &v_off, p);
                CG.nrm(norm, &n_off, .{ 0, 1, 0 });
            }
            CG.uv(tex, &t_off, top_uv[0], top_uv[1]);
            CG.uv(tex, &t_off, top_uv[0], top_uv[1] + top_uv[3]);
            CG.uv(tex, &t_off, top_uv[0] + top_uv[2], top_uv[1] + top_uv[3]);
            CG.uv(tex, &t_off, top_uv[0], top_uv[1]);
            CG.uv(tex, &t_off, top_uv[0] + top_uv[2], top_uv[1] + top_uv[3]);
            CG.uv(tex, &t_off, top_uv[0] + top_uv[2], top_uv[1]);

            // --- bottom face (always) : v6 v8 v7, v6 v5 v8, normal -Y ---
            inline for (.{ v6, v8, v7, v6, v5, v8 }) |p| {
                CG.vert(verts, &v_off, p);
                CG.nrm(norm, &n_off, .{ 0, -1, 0 });
            }
            CG.uv(tex, &t_off, bottom_uv[0] + bottom_uv[2], bottom_uv[1]);
            CG.uv(tex, &t_off, bottom_uv[0], bottom_uv[1] + bottom_uv[3]);
            CG.uv(tex, &t_off, bottom_uv[0] + bottom_uv[2], bottom_uv[1] + bottom_uv[3]);
            CG.uv(tex, &t_off, bottom_uv[0] + bottom_uv[2], bottom_uv[1]);
            CG.uv(tex, &t_off, bottom_uv[0], bottom_uv[1]);
            CG.uv(tex, &t_off, bottom_uv[0], bottom_uv[1] + bottom_uv[3]);

            // Neighbor is empty when it's BLACK or off the map edge.
            const empty_front: bool = (zc < map_h - 1 and isBlack(pixels[(zc + 1) * map_w + xc])) or zc == map_h - 1;
            const empty_back: bool = (zc > 0 and isBlack(pixels[(zc - 1) * map_w + xc])) or zc == 0;
            const empty_right: bool = (xc < map_w - 1 and isBlack(pixels[zc * map_w + (xc + 1)])) or xc == map_w - 1;
            const empty_left: bool = (xc > 0 and isBlack(pixels[zc * map_w + (xc - 1)])) or xc == 0;

            // --- front wall (+Z) : v2 v7 v3, v3 v7 v8 ---
            if (empty_front) {
                inline for (.{ v2, v7, v3, v3, v7, v8 }) |p| {
                    CG.vert(verts, &v_off, p);
                    CG.nrm(norm, &n_off, .{ 0, 0, 1 });
                }
                CG.uv(tex, &t_off, front_uv[0], front_uv[1]);
                CG.uv(tex, &t_off, front_uv[0], front_uv[1] + front_uv[3]);
                CG.uv(tex, &t_off, front_uv[0] + front_uv[2], front_uv[1]);
                CG.uv(tex, &t_off, front_uv[0] + front_uv[2], front_uv[1]);
                CG.uv(tex, &t_off, front_uv[0], front_uv[1] + front_uv[3]);
                CG.uv(tex, &t_off, front_uv[0] + front_uv[2], front_uv[1] + front_uv[3]);
            }
            // --- back wall (-Z) : v1 v5 v6, v1 v4 v5 ---
            if (empty_back) {
                inline for (.{ v1, v5, v6, v1, v4, v5 }) |p| {
                    CG.vert(verts, &v_off, p);
                    CG.nrm(norm, &n_off, .{ 0, 0, -1 });
                }
                CG.uv(tex, &t_off, back_uv[0] + back_uv[2], back_uv[1]);
                CG.uv(tex, &t_off, back_uv[0], back_uv[1] + back_uv[3]);
                CG.uv(tex, &t_off, back_uv[0] + back_uv[2], back_uv[1] + back_uv[3]);
                CG.uv(tex, &t_off, back_uv[0] + back_uv[2], back_uv[1]);
                CG.uv(tex, &t_off, back_uv[0], back_uv[1]);
                CG.uv(tex, &t_off, back_uv[0], back_uv[1] + back_uv[3]);
            }
            // --- right wall (+X) : v3 v8 v4, v4 v8 v5 ---
            if (empty_right) {
                inline for (.{ v3, v8, v4, v4, v8, v5 }) |p| {
                    CG.vert(verts, &v_off, p);
                    CG.nrm(norm, &n_off, .{ 1, 0, 0 });
                }
                CG.uv(tex, &t_off, right_uv[0], right_uv[1]);
                CG.uv(tex, &t_off, right_uv[0], right_uv[1] + right_uv[3]);
                CG.uv(tex, &t_off, right_uv[0] + right_uv[2], right_uv[1]);
                CG.uv(tex, &t_off, right_uv[0] + right_uv[2], right_uv[1]);
                CG.uv(tex, &t_off, right_uv[0], right_uv[1] + right_uv[3]);
                CG.uv(tex, &t_off, right_uv[0] + right_uv[2], right_uv[1] + right_uv[3]);
            }
            // --- left wall (-X) : v1 v7 v2, v1 v6 v7 ---
            if (empty_left) {
                inline for (.{ v1, v7, v2, v1, v6, v7 }) |p| {
                    CG.vert(verts, &v_off, p);
                    CG.nrm(norm, &n_off, .{ -1, 0, 0 });
                }
                CG.uv(tex, &t_off, left_uv[0], left_uv[1]);
                CG.uv(tex, &t_off, left_uv[0], left_uv[1] + left_uv[3]);
                CG.uv(tex, &t_off, left_uv[0] + left_uv[2], left_uv[1]);
                CG.uv(tex, &t_off, left_uv[0] + left_uv[2], left_uv[1]);
                CG.uv(tex, &t_off, left_uv[0], left_uv[1] + left_uv[3]);
                CG.uv(tex, &t_off, left_uv[0] + left_uv[2], left_uv[1] + left_uv[3]);
            }
        }
    }

    const used_verts: usize = v_off / 3; // 3 floats per vertex
    // The arrays were sized for the worst case (max_verts); shrink them to the
    // ACTUAL vertex count so unloadMesh — which frees vertexCount-derived lengths
    // — frees exactly what was allocated. Without this, the max/used difference is
    // handed to free() with the wrong length and leaks (a real per-lifecycle CPU
    // leak the leak-test flags on cubicmap / first_person_maze).
    const vf: []f32 = gpa.realloc(verts, used_verts * 3) catch verts;
    const nf: []f32 = gpa.realloc(norm, used_verts * 3) catch norm;
    const tf: []f32 = gpa.realloc(tex, used_verts * 2) catch tex;
    mesh.vertexCount = @intCast(used_verts);
    mesh.triangleCount = @intCast(used_verts / 3);
    mesh.vertices = vf.ptr;
    mesh.normals = nf.ptr;
    mesh.texcoords = tf.ptr;
    return mesh;
}

/// A pixel is "empty" (a maze corridor) when it is pure black.
inline fn isBlack(c: Color) bool {
    return c.r == 0 and c.g == 0 and c.b == 0;
}

pub fn loadModelFromMesh(gpa: Allocator, mesh: types.Mesh) Allocator.Error!types.Model {
    var model: types.Model = std.mem.zeroes(types.Model);
    model.transform = identity();
    const meshes: []types.Mesh = try gpa.alloc(types.Mesh, 1);
    meshes[0] = mesh;
    model.meshes = meshes.ptr;
    model.meshCount = 1;
    return model;
}

/// Update part of a mesh's CPU vertex data in place (raylib updateMeshBuffer).
/// `index` selects the attribute (0 = positions, 1 = texcoords, 2 = normals);
/// `data` is raw bytes written at `offset`. Step-3a draws from the CPU arrays
/// each frame, so updating them here is all that's needed (no GPU re-upload).
pub fn updateMeshBuffer(
    mesh: types.Mesh,
    index: usize,
    data: []const u8,
    offset: usize,
) void {
    const target: [*c]f32 = switch (index) {
        0 => mesh.vertices,
        1 => mesh.texcoords,
        2 => mesh.normals,
        else => return,
    };
    if (target == null) {
        return;
    }
    const dst: [*]u8 = @ptrCast(target);
    @memcpy(dst[offset .. offset + data.len], data);
}

/// World position of mesh-local vertex `k` after the model transform, then a
/// uniform scale and translation (drawModel semantics).
fn meshWorldPos(
    v: [*c]f32,
    k: usize,
    xform: Mat,
    position: Vec,
    scale: f32,
) [3]f32 {
    const lp: Vec = mulMatVec(xform, vec4(v[k * 3], v[k * 3 + 1], v[k * 3 + 2], 1.0));
    return .{ position[0] + scale * lp[0], position[1] + scale * lp[1], position[2] + scale * lp[2] };
}

/// World normal of mesh-local vertex `k` after the model transform (rotation
/// part; the shader normalises). Defaults to +Y when the mesh has no normals.
fn meshWorldNormal(n: [*c]f32, k: usize, xform: Mat) [3]f32 {
    if (n == null) {
        return .{ 0, 1, 0 };
    }
    const ln: Vec = mulMatVec(xform, vec4(n[k * 3], n[k * 3 + 1], n[k * 3 + 2], 0.0));
    return .{ ln[0], ln[1], ln[2] };
}

// ============================================================================
// Cube3D — the immediate 3D batch: pipeline + dynamic vertex stream
// ============================================================================

pub const Cube3D = struct {
    resources: shader.Resources(CubeSchema),
    pipeline: wgpu.RenderPipelineHandle,
    pipeline_layout: wgpu.PipelineLayoutHandle,
    vs_module: wgpu.ShaderModuleHandle,
    fs_module: wgpu.ShaderModuleHandle,
    batch_buffer: wgpu.BufferHandle,
    batch_buffer_cap: u32,
    batch: ArrayList(BatchVertex),
    line_pipeline: wgpu.RenderPipelineHandle,
    line_buffer: wgpu.BufferHandle,
    line_buffer_cap: u32,
    line_batch: ArrayList(BatchVertex),
    // Instancing (Step 4): a dedicated pipeline + VS, a registry of uploaded
    // mesh GPU buffers, and a reusable per-instance buffer that grows on demand.
    instanced_pipeline: wgpu.RenderPipelineHandle,
    instanced_vs_module: wgpu.ShaderModuleHandle,
    mesh_gpu: ArrayList(MeshGpu),
    instance_buffer: wgpu.BufferHandle,
    instance_capacity: u32,
    device: wgpu.DeviceHandle,
    gpa: Allocator,
    // Textured-3D: a depth-tested pipeline sharing group 0 (camera) with the
    // solid batch; group 1 is a per-texture bind group (cached by view handle).
    tex_pipeline: wgpu.RenderPipelineHandle,
    billboard_pipeline: wgpu.RenderPipelineHandle,
    tex_bgl: wgpu.BindGroupLayoutHandle,
    tex_buffer: wgpu.BufferHandle,
    tex_batch: ArrayList(TexVertex),
    tex_draws: ArrayList(TexDraw),
    tex_bind_cache: std.AutoHashMapUnmanaged(u64, wgpu.BindGroupHandle),
    // Shader-projected decals: a dedicated pipeline that re-draws a receiver
    // mesh (pos-only) and paints a projected decal texture onto the fragments
    // inside the projector box — no mesh clipping, scales to any density.
    // Group 0 = camera UBO (shared); group 1 = per-decal projector UBO (ring
    // slot, dynamic offset); group 2 = decal texture (reuses tex_bgl shape).
    decal_pipeline: wgpu.RenderPipelineHandle,
    decal_proj_bgl: wgpu.BindGroupLayoutHandle,
    decal_proj_buffer: wgpu.BufferHandle,
    // One pre-built bind group per ring slot, each pointing at its slot's 256-B
    // window of decal_proj_buffer (the bridge's setBindGroup takes no dynamic
    // offset, so we bake the offset into per-slot bind groups — the pbr3d-ring
    // pattern). Bind slot `proj_cursor % decal_ring_len` for each decal.
    decal_proj_bgs: [decal_ring_len]wgpu.BindGroupHandle,
    decal_proj_cursor: u32,
    decal_receivers: ArrayList(DecalReceiver),
    decal_draws: ArrayList(DecalDraw),
    // Gradient skybox: its own UBO (inverse-view-proj + sky colours) at group 0.
    skybox_resources: shader.Resources(SkyboxSchema),
    skybox_pipeline: wgpu.RenderPipelineHandle,

    // ---- The per-pass VIEW-PROJECTION ring (group 0) ----
    //
    // `Resources.writeUbo` writes ONE buffer at offset 0, and says so:
    // "★ INVARIANT: at most ONE write per frame ★". Every `beginMode3D` writes
    // the camera UBO — so the moment an app opens TWO 3D passes in a frame
    // (split-screen, a minimap, a security camera, rendering 3D into a render
    // texture at all) that invariant breaks. `queue.writeBuffer` executes before
    // the frame's single submit, so ALL 3D passes then read the LAST camera:
    // both halves of a split screen silently render the same view. The smoke
    // ClobberScan sees it, but nothing else does — it is invisible in the
    // sandbox and looks merely "wrong" on device.
    //
    // Same medicine as renderer_2d's ortho ring and the decal projector ring
    // below: one buffer, a 256-B slot per pass, and a PRE-BUILT bind group per
    // slot (the bridge's setBindGroup takes no dynamic offset, so the offset is
    // baked into the bind group). `beginFrame3D` advances the cursor; every
    // flush binds THIS pass's slot, so each recorded pass keeps the matrix it
    // was recorded with.
    vp_ring_buffer: wgpu.BufferHandle,
    vp_ring_bgs: [vp_ring_len]wgpu.BindGroupHandle,
    /// Slot holding the CURRENT pass's view-projection (what the flushes bind).
    vp_slot: u32,
    /// Writes within the CURRENT encoder — a wrap inside one encoder would
    /// clobber a slot an already-recorded pass still points at, i.e. the very
    /// bug the ring exists to prevent. Reset structurally when the encoder
    /// handle changes (monotonic on both the bridge and the smoke mock), so no
    /// per-frame call is required of the app.
    vp_writes_this_frame: u32,
    vp_ring_encoder: wgpu.CommandEncoderHandle,

    // ---- Frame-scoped APPEND cursors for the vertex streams ----
    //
    // Same queue-timeline hazard, vertex data instead of uniforms: every stream
    // used to `queueWriteBuffer(..., offset 0, ...)` on each flush, so a second
    // 3D pass (or merely a second `drawMeshInstanced` in one frame) overwrote
    // the bytes an already-recorded draw still points at — only the LAST write
    // survives to the submit. The 2D shapes batch fixed this years ago by
    // appending at a running offset (`gpu_iface.flushBatch`, `vbo_ring_vertices`);
    // the 3D streams never did. Each cursor is an ELEMENT count into its buffer,
    // reset when the frame's encoder changes.
    batch_cursor: u32,
    line_cursor: u32,
    tex_cursor: u32,
    inst_cursor: u32,

    pub fn init(gpa: Allocator, f: *gpu.GpuFrame) !Cube3D {
        const device: wgpu.DeviceHandle = f.device;
        const fmt: wgpu.TextureFormat = f.backbuffer_format;

        const batch_buffer: wgpu.BufferHandle = wgpu.createBuffer(device, .{
            .size = @as(u64, batch_capacity) * @sizeOf(BatchVertex),
            .usage = .{ .vertex = true, .copy_dst = true },
            .label = "draw3d_batch_vbo",
        });

        const layout = gpu.VertexBufferLayout{
            .array_stride = @sizeOf(BatchVertex),
            .step_mode = .vertex,
            .attributes = &.{
                .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
                .{ .format = .float32x3, .offset = 12, .shader_location = 1 },
                .{ .format = .float32x4, .offset = 24, .shader_location = 2 },
            },
        };

        // No `.initial_ubo`: the batch's view-projection UBO is written by
        // `beginFrame3D` at the top of every 3D block, ALWAYS before any draw
        // records (draws flush at endMode3D). Seeding it here too would write
        // the same buffer+offset twice in the first update frame (a
        // queue-timeline clobber the smoke ClobberScan flags) for a value no
        // pass can ever observe. Leaving it null lets the real per-frame write
        // stand alone; the buffer is only ever read after that write.
        const resources = try shader.Resources(CubeSchema).init(gpa, f, .{});

        const bgls: [1]wgpu.BindGroupLayoutHandle = .{resources.bg_layouts[0]};
        const pipeline_layout: wgpu.PipelineLayoutHandle =
            wgpu.createPipelineLayout(device, bgls[0..], "draw3d_pl");

        const vs_module: wgpu.ShaderModuleHandle =
            wgpu.createShaderModuleWgsl(device, cube_vs_wgsl, "cube3d_vs");
        const fs_module: wgpu.ShaderModuleHandle =
            wgpu.createShaderModuleWgsl(device, cube_fs_wgsl, "cube3d_fs");

        // Two pipelines sharing shader + layout + UBO: filled triangles
        // (back-face culled) for solids, and line-list (no cull) for grids /
        // wires / lines. Both depth-tested in the dedicated 3D pass.
        const pipeline: wgpu.RenderPipelineHandle = try makePipeline(
            gpa,
            device,
            pipeline_layout,
            vs_module,
            fs_module,
            layout,
            .triangle_list,
            // No cull: with depth testing, back faces of a convex solid are
            // always occluded by front faces, so culling is just an
            // optimization — dropping it makes mesh winding irrelevant
            // (sphere/cylinder generators can't render inside-out).
            .none,
            .less,
            fmt,
        );
        const line_pipeline: wgpu.RenderPipelineHandle = try makePipeline(
            gpa,
            device,
            pipeline_layout,
            vs_module,
            fs_module,
            layout,
            .line_list,
            .none,
            .less,
            fmt,
        );

        const line_buffer: wgpu.BufferHandle = wgpu.createBuffer(device, .{
            .size = @as(u64, batch_capacity) * @sizeOf(BatchVertex),
            .usage = .{ .vertex = true, .copy_dst = true },
            .label = "draw3d_line_vbo",
        });

        // Instanced pipeline: shares the UBO bind group (view-projection) but
        // its own VS + two vertex buffers (mesh verts @vertex-step, per-instance
        // model/colour @instance-step).
        const instanced_vs_module: wgpu.ShaderModuleHandle =
            wgpu.createShaderModuleWgsl(device, cube_instanced_vs_wgsl, "cube3d_instanced_vs");
        const mesh_layout = gpu.VertexBufferLayout{
            .array_stride = @sizeOf(MeshVertex),
            .step_mode = .vertex,
            .attributes = &.{
                .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
                .{ .format = .float32x3, .offset = 12, .shader_location = 1 },
            },
        };
        const instance_layout = gpu.VertexBufferLayout{
            .array_stride = @sizeOf(InstanceVertex),
            .step_mode = .instance,
            .attributes = &.{
                .{ .format = .float32x4, .offset = 0, .shader_location = 2 },
                .{ .format = .float32x4, .offset = 16, .shader_location = 3 },
                .{ .format = .float32x4, .offset = 32, .shader_location = 4 },
                .{ .format = .float32x4, .offset = 48, .shader_location = 5 },
                .{ .format = .float32x4, .offset = 64, .shader_location = 6 },
            },
        };
        const instanced_pipeline: wgpu.RenderPipelineHandle = try makeInstancedPipeline(
            gpa,
            device,
            pipeline_layout,
            instanced_vs_module,
            fs_module,
            mesh_layout,
            instance_layout,
            fmt,
        );
        const instance_capacity: u32 = 1024;
        const instance_buffer: wgpu.BufferHandle = wgpu.createBuffer(device, .{
            .size = @as(u64, instance_capacity) * @sizeOf(InstanceVertex),
            .usage = .{ .vertex = true, .copy_dst = true },
            .label = "draw3d_instance_vbo",
        });

        // Textured-3D pipeline: group 0 = camera UBO (shared with the solid
        // pipeline via resources.bg_layouts[0]); group 1 = {texture, sampler}.
        const tex_bgl_entries = [_]shader_introspect.BindGroupLayoutEntry{
            .{ .binding = 0, .visibility = .{ .fragment = true }, .resource = .{ .texture = .{} } },
            .{ .binding = 1, .visibility = .{ .fragment = true }, .resource = .{ .sampler = .{} } },
        };
        const tex_bgl_blob: []const u8 = try gpu.encodeBindGroupLayoutEntries(gpa, &tex_bgl_entries);
        defer gpa.free(tex_bgl_blob);
        const tex_bgl: wgpu.BindGroupLayoutHandle =
            wgpu.createBindGroupLayout(device, tex_bgl_blob, "draw3d_tex_bgl");
        const tex_bgls = [_]wgpu.BindGroupLayoutHandle{ resources.bg_layouts[0], tex_bgl };
        const tex_pl: wgpu.PipelineLayoutHandle =
            wgpu.createPipelineLayout(device, tex_bgls[0..], "draw3d_tex_pl");
        const tex_vs: wgpu.ShaderModuleHandle =
            wgpu.createShaderModuleWgsl(device, billboard_vs_wgsl, "billboard_vs");
        const tex_fs: wgpu.ShaderModuleHandle =
            wgpu.createShaderModuleWgsl(device, billboard_fs_wgsl, "billboard_fs");
        const tex_layout = gpu.VertexBufferLayout{
            .array_stride = @sizeOf(TexVertex),
            .step_mode = .vertex,
            .attributes = &.{
                .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
                .{ .format = .float32x2, .offset = 12, .shader_location = 1 },
                .{ .format = .float32x4, .offset = 20, .shader_location = 2 },
            },
        };
        const tex_pipeline: wgpu.RenderPipelineHandle = try makePipeline(
            gpa,
            device,
            tex_pl,
            tex_vs,
            tex_fs,
            tex_layout,
            .triangle_list,
            .none,
            .less,
            fmt,
        );
        // Billboards/transparent sprites: depth-TEST against the opaque scene but
        // never WRITE depth, so alpha quads don't occlude each other or the scene
        // behind their transparent pixels. Same shader + layout as tex_pipeline.
        const billboard_pipeline: wgpu.RenderPipelineHandle = try makePipeline(
            gpa,
            device,
            tex_pl,
            tex_vs,
            tex_fs,
            tex_layout,
            .triangle_list,
            .none,
            .less_no_write,
            fmt,
        );
        const tex_buffer: wgpu.BufferHandle = wgpu.createBuffer(device, .{
            .size = @as(u64, tex_capacity) * @sizeOf(TexVertex),
            .usage = .{ .vertex = true, .copy_dst = true },
            .label = "draw3d_tex_vbo",
        });

        // Skybox: a UBO bind group + a no-vertex-buffer fullscreen-triangle pipe.
        // Same reasoning as the batch UBO above: `drawSkybox` calls `writeUbo`
        // immediately before binding, every frame, so an init seed only
        // double-writes the same buffer+offset in frame 0 (clobber) for a value
        // no pass reads. Default the init arg to null.
        const skybox_resources = try shader.Resources(SkyboxSchema).init(gpa, f, .{});
        const sky_bgls = [_]wgpu.BindGroupLayoutHandle{skybox_resources.bg_layouts[0]};
        const sky_pl: wgpu.PipelineLayoutHandle =
            wgpu.createPipelineLayout(device, sky_bgls[0..], "skybox_pl");
        const sky_vs: wgpu.ShaderModuleHandle =
            wgpu.createShaderModuleWgsl(device, skybox_vs_wgsl, "skybox_vs");
        const sky_fs: wgpu.ShaderModuleHandle =
            wgpu.createShaderModuleWgsl(device, skybox_fs_wgsl, "skybox_fs");
        const sky_state: gpu.StateCombo = gpu.StateCombo.fromParts(
            .triangle_list,
            .none,
            .less,
            .none,
            fmt,
            .depth24_plus,
            1,
        );
        const sky_desc = gpu.RenderPipelineDescriptor{
            .vertex_buffer_layouts = &.{},
            .vs_entry_point = "entry",
            .fs_entry_point = "entry",
            .state = sky_state,
        };
        const sky_blob: []const u8 = try gpu.encodeRenderPipelineDescriptor(gpa, sky_desc);
        defer gpa.free(sky_blob);
        const skybox_pipeline: wgpu.RenderPipelineHandle =
            wgpu.createRenderPipeline(device, sky_pl, sky_vs, sky_fs, sky_blob, "skybox_pipe");

        // ---- Shader-projected decals ----
        // Group 1: per-decal projector UBO. Group 2: decal texture (same shape
        // as tex_bgl). Group 0 reuses the camera UBO layout.
        const decal_proj_entries = [_]shader_introspect.BindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = .{ .fragment = true },
                .resource = .{ .uniform_buffer = .{ .min_size = shader_iface.wireSizeOf(DecalUbo) } },
            },
        };
        const decal_proj_blob: []const u8 = try gpu.encodeBindGroupLayoutEntries(gpa, &decal_proj_entries);
        defer gpa.free(decal_proj_blob);
        const decal_proj_bgl: wgpu.BindGroupLayoutHandle =
            wgpu.createBindGroupLayout(device, decal_proj_blob, "draw3d_decal_proj_bgl");
        const decal_bgls = [_]wgpu.BindGroupLayoutHandle{ resources.bg_layouts[0], decal_proj_bgl, tex_bgl };
        const decal_pl: wgpu.PipelineLayoutHandle =
            wgpu.createPipelineLayout(device, decal_bgls[0..], "draw3d_decal_pl");
        const decal_vs: wgpu.ShaderModuleHandle =
            wgpu.createShaderModuleWgsl(device, decal_vs_wgsl, "decal_vs");
        const decal_fs: wgpu.ShaderModuleHandle =
            wgpu.createShaderModuleWgsl(device, decal_fs_wgsl, "decal_fs");
        // Receiver drawn with position (float32x3 @0) + normal (float32x3 @1).
        const decal_layout = gpu.VertexBufferLayout{
            .array_stride = 24,
            .step_mode = .vertex,
            .attributes = &.{
                .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
                .{ .format = .float32x3, .offset = 12, .shader_location = 1 },
            },
        };
        const decal_pipeline: wgpu.RenderPipelineHandle = try makePipeline(
            gpa,
            device,
            decal_pl,
            decal_vs,
            decal_fs,
            decal_layout,
            .triangle_list,
            // No cull: receiver meshes vary in winding (genMeshSphere is CW-
            // outward, OBJ meshes are CCW), and .back would cull one of them —
            // that's what hid decals on the sphere. The FS discards everything
            // outside the projector box, so back faces contribute nothing
            // visible anyway; no-cull is both correct and winding-agnostic.
            .none,
            .less_equal_no_write,
            fmt,
        );
        // Ring buffer of projector UBOs + a pre-built bind group per slot (each
        // pointing at its 256-B window), so no dynamic offset is needed.
        const decal_proj_buffer: wgpu.BufferHandle = wgpu.createBuffer(device, .{
            .size = @as(u64, decal_ring_len) * decal_ubo_stride,
            .usage = .{ .uniform = true, .copy_dst = true },
            .label = "draw3d_decal_proj_ubo_ring",
        });
        var decal_proj_bgs: [decal_ring_len]wgpu.BindGroupHandle = undefined;
        {
            var slot: u32 = 0;
            while (slot < decal_ring_len) : (slot += 1) {
                const entries = [_]gpu.BindGroupEntry{
                    .{ .binding = 0, .resource = .{ .buffer = .{
                        .handle = decal_proj_buffer,
                        .offset = @as(u64, slot) * decal_ubo_stride,
                        .size = shader_iface.wireSizeOf(DecalUbo),
                    } } },
                };
                const blob: []const u8 = try gpu.encodeBindGroupEntries(gpa, &entries);
                defer gpa.free(blob);
                decal_proj_bgs[slot] = wgpu.createBindGroup(device, decal_proj_bgl, blob, "draw3d_decal_proj_bg");
            }
        }

        // Per-pass view-projection ring (see the field comment): one buffer, a
        // 256-B window per slot, one pre-built bind group each — against the
        // SAME group-0 layout the pipelines were built with, so binding a slot
        // is layout-identical to binding Resources' own group 0.
        const vp_ring_buffer: wgpu.BufferHandle = wgpu.createBuffer(device, .{
            .size = @as(u64, vp_ring_len) * vp_ubo_stride,
            .usage = .{ .uniform = true, .copy_dst = true },
            .label = "draw3d_vp_ubo_ring",
        });
        var vp_ring_bgs: [vp_ring_len]wgpu.BindGroupHandle = undefined;
        {
            var slot: u32 = 0;
            while (slot < vp_ring_len) : (slot += 1) {
                const entries = [_]gpu.BindGroupEntry{
                    .{ .binding = 0, .resource = .{ .buffer = .{
                        .handle = vp_ring_buffer,
                        .offset = @as(u64, slot) * vp_ubo_stride,
                        .size = shader_iface.wireSizeOf(CubeSchema.Ubo),
                    } } },
                };
                const blob: []const u8 = try gpu.encodeBindGroupEntries(gpa, &entries);
                defer gpa.free(blob);
                vp_ring_bgs[slot] = wgpu.createBindGroup(
                    device,
                    resources.bg_layouts[0],
                    blob,
                    "draw3d_vp_bg",
                );
            }
        }

        // Every pipeline above is now built, and WebGPU has internalized the
        // layouts + shader modules each one referenced — so the build-only
        // intermediates can be released immediately (the pipelines keep working).
        // Only tex_pl/tex_vs/tex_fs are shared (tex_pipeline AND billboard_pipeline
        // use them), and both are built by now, so this is safe. The layout + three
        // modules KEPT as fields (pipeline_layout, vs_module, fs_module,
        // instanced_vs_module) are the ones a hot-reload path could rebuild from;
        // they're freed symmetrically in `deinit`.
        wgpu.destroyPipelineLayout(tex_pl);
        wgpu.destroyPipelineLayout(sky_pl);
        wgpu.destroyPipelineLayout(decal_pl);
        wgpu.destroyShaderModule(tex_vs);
        wgpu.destroyShaderModule(tex_fs);
        wgpu.destroyShaderModule(sky_vs);
        wgpu.destroyShaderModule(sky_fs);
        wgpu.destroyShaderModule(decal_vs);
        wgpu.destroyShaderModule(decal_fs);

        return .{
            .resources = resources,
            .pipeline = pipeline,
            .pipeline_layout = pipeline_layout,
            .vs_module = vs_module,
            .fs_module = fs_module,
            .batch_buffer = batch_buffer,
            .batch_buffer_cap = batch_capacity,
            .batch = .empty,
            .line_pipeline = line_pipeline,
            .line_buffer = line_buffer,
            .line_buffer_cap = batch_capacity,
            .line_batch = .empty,
            .instanced_pipeline = instanced_pipeline,
            .instanced_vs_module = instanced_vs_module,
            .mesh_gpu = .empty,
            .instance_buffer = instance_buffer,
            .instance_capacity = instance_capacity,
            .device = device,
            .gpa = gpa,
            .tex_pipeline = tex_pipeline,
            .billboard_pipeline = billboard_pipeline,
            .tex_bgl = tex_bgl,
            .tex_buffer = tex_buffer,
            .tex_batch = .empty,
            .tex_draws = .empty,
            .tex_bind_cache = .empty,
            .skybox_resources = skybox_resources,
            .vp_ring_buffer = vp_ring_buffer,
            .vp_ring_bgs = vp_ring_bgs,
            .vp_slot = 0,
            .vp_writes_this_frame = 0,
            .vp_ring_encoder = .invalid,
            .batch_cursor = 0,
            .line_cursor = 0,
            .tex_cursor = 0,
            .inst_cursor = 0,
            .skybox_pipeline = skybox_pipeline,
            .decal_pipeline = decal_pipeline,
            .decal_proj_bgl = decal_proj_bgl,
            .decal_proj_buffer = decal_proj_buffer,
            .decal_proj_bgs = decal_proj_bgs,
            .decal_proj_cursor = 0,
            .decal_receivers = .empty,
            .decal_draws = .empty,
        };
    }

    /// Begin a 3D frame: set the camera view-projection and clear the batch.
    /// `view_proj` follows the cube_demo convention (proj × view, used as M*v).
    /// Draw the gradient skybox into the current pass: a fullscreen triangle at
    /// the far plane. Call inside beginMode3D/endMode3D (it draws immediately,
    /// before the batched solids/billboards flush — it's the background).
    pub fn drawSkybox(
        self: *Cube3D,
        ps: anytype,
        inv_view_proj: Mat,
        cam_pos: Vec,
        sky_bottom: [3]f32,
        sky_top: [3]f32,
    ) void {
        self.skybox_resources.writeUbo(.{
            .inv_view_proj = inv_view_proj,
            .camera_pos = .{ cam_pos[0], cam_pos[1], cam_pos[2], 0 },
            .sky_bottom = .{ sky_bottom[0], sky_bottom[1], sky_bottom[2], 1 },
            .sky_top = .{ sky_top[0], sky_top[1], sky_top[2], 1 },
        });
        WgpuBackend.setPipeline(ps, shader.RenderPipeline(void, void){ .gpu_handle = self.skybox_pipeline });
        self.skybox_resources.bind(ps);
        render_pass.draw(ps.pass, .{ .vertex_count = 3, .instance_count = 1, .first_vertex = 0, .first_instance = 0 });
    }

    pub fn beginFrame3D(self: *Cube3D, view_proj: Mat) void {
        self.writeViewProj(view_proj);
        self.batch.clearRetainingCapacity();
        self.line_batch.clearRetainingCapacity();
        self.tex_batch.clearRetainingCapacity();
        self.tex_draws.clearRetainingCapacity();
        self.decal_draws.clearRetainingCapacity();
        self.decal_proj_cursor = 0;
    }

    /// Take the next ring slot for THIS 3D pass and write its camera there.
    /// Replaces `resources.writeUbo`, whose one-buffer-at-offset-0 write is only
    /// safe for a single 3D pass per frame (see the ring's field comment).
    fn writeViewProj(self: *Cube3D, view_proj: Mat) void {
        const f: *gpu.GpuFrame = self.resources.f;
        // Structural budget reset: a new encoder = a new frame = the previously
        // recorded passes are gone, so every slot is free again.
        if (f.encoder != self.vp_ring_encoder) {
            self.vp_ring_encoder = f.encoder;
            self.vp_writes_this_frame = 0;
            self.vp_slot = 0;
            // A new encoder = a new frame: last frame's recorded draws are gone,
            // so every vertex stream may start appending from zero again.
            self.batch_cursor = 0;
            self.line_cursor = 0;
            self.tex_cursor = 0;
            self.inst_cursor = 0;
        } else {
            self.vp_slot = (self.vp_slot + 1) % vp_ring_len;
        }
        self.vp_writes_this_frame += 1;
        assertf(
            self.vp_writes_this_frame <= vp_ring_len,
            @src(),
            "more than {d} beginMode3D passes in one frame: the view-projection ring " ++
                "wrapped, so an already-recorded pass would silently get another pass's " ++
                "camera. Raise vp_ring_len in draw3d.zig.",
            .{vp_ring_len},
        );
        const ubo: CubeSchema.Ubo = .{ .view_projection = view_proj };
        const bytes: [shader_iface.wireSizeOf(CubeSchema.Ubo)]u8 =
            shader_iface.wireOf(CubeSchema.Ubo, &ubo);
        wgpu.queueWriteBuffer(
            f.queue,
            self.vp_ring_buffer,
            @as(u64, self.vp_slot) * vp_ubo_stride,
            &bytes,
        );
    }

    /// Bind group 0 = THIS pass's camera slot. Every 3D flush goes through here
    /// instead of `resources.bind`, so a pass recorded earlier in the frame
    /// keeps pointing at the matrix it was recorded with.
    fn bindViewProj(self: *Cube3D, ps: anytype) void {
        WgpuBackend.setBindGroup(ps, 0, self.vp_ring_bgs[self.vp_slot]);
    }

    /// Append a world-space line segment (two endpoints) to the line batch.
    pub fn appendLine(
        self: *Cube3D,
        a: [3]f32,
        b: [3]f32,
        color: Color,
    ) void {
        const col: [4]f32 = .{
            float(color.r) / 255.0,
            float(color.g) / 255.0,
            float(color.b) / 255.0,
            float(color.a) / 255.0,
        };
        self.line_batch.append(self.gpa, .{ .pos = a, .normal = line_normal, .color = col }) catch {};
        self.line_batch.append(self.gpa, .{ .pos = b, .normal = line_normal, .color = col }) catch {};
    }

    /// Append a triangle with per-vertex normals into the solid (triangle) batch.
    fn appendTri3(
        self: *Cube3D,
        p0: [3]f32,
        n0: [3]f32,
        p1: [3]f32,
        n1: [3]f32,
        p2: [3]f32,
        n2: [3]f32,
        col: [4]f32,
    ) void {
        self.batch.append(self.gpa, .{ .pos = p0, .normal = n0, .color = col }) catch {};
        self.batch.append(self.gpa, .{ .pos = p1, .normal = n1, .color = col }) catch {};
        self.batch.append(self.gpa, .{ .pos = p2, .normal = n2, .color = col }) catch {};
    }

    /// Append a UV sphere (centre + radius) to the solid batch. Normals are the
    /// outward radial directions (smooth shading).
    pub fn appendSphere(
        self: *Cube3D,
        center: Vec,
        radius: f32,
        rings: u32,
        sectors: u32,
        color: Color,
    ) void {
        const col: [4]f32 = Color.toFloats(color);
        var i: u32 = 0;
        while (i < rings) : (i += 1) {
            const th0: f32 = pi * float(i) / float(rings);
            const th1: f32 = pi * float(i + 1) / float(rings);
            var j: u32 = 0;
            while (j < sectors) : (j += 1) {
                const ph0: f32 = 2.0 * pi * float(j) / float(sectors);
                const ph1: f32 = 2.0 * pi * float(j + 1) / float(sectors);
                const da: [3]f32 = sphereDir(th0, ph0);
                const db: [3]f32 = sphereDir(th0, ph1);
                const dc: [3]f32 = sphereDir(th1, ph0);
                const dd: [3]f32 = sphereDir(th1, ph1);
                const pa: [3]f32 = radialPos(center, radius, da);
                const pb: [3]f32 = radialPos(center, radius, db);
                const pc: [3]f32 = radialPos(center, radius, dc);
                const pd: [3]f32 = radialPos(center, radius, dd);
                self.appendTri3(pa, da, pc, dc, pd, dd, col);
                self.appendTri3(pa, da, pd, dd, pb, db, col);
            }
        }
    }

    /// Append a Y-axis cylinder (centre, radius, half-height) to the solid
    /// batch: side wall with radial normals, plus flat top and bottom caps.
    pub fn appendCylinder(
        self: *Cube3D,
        center: Vec,
        radius: f32,
        half_height: f32,
        sectors: u32,
        color: Color,
    ) void {
        const col: [4]f32 = Color.toFloats(color);
        const cx: f32 = center[0];
        const cy: f32 = center[1];
        const cz: f32 = center[2];
        const up: [3]f32 = .{ 0, 1, 0 };
        const down: [3]f32 = .{ 0, -1, 0 };
        const top_c: [3]f32 = .{ cx, cy + half_height, cz };
        const bot_c: [3]f32 = .{ cx, cy - half_height, cz };
        var j: u32 = 0;
        while (j < sectors) : (j += 1) {
            const ph0: f32 = 2.0 * pi * float(j) / float(sectors);
            const ph1: f32 = 2.0 * pi * float(j + 1) / float(sectors);
            const c0: f32 = @cos(ph0);
            const s0: f32 = @sin(ph0);
            const c1: f32 = @cos(ph1);
            const s1: f32 = @sin(ph1);
            const b0: [3]f32 = .{ cx + radius * c0, cy - half_height, cz + radius * s0 };
            const b1: [3]f32 = .{ cx + radius * c1, cy - half_height, cz + radius * s1 };
            const t0: [3]f32 = .{ cx + radius * c0, cy + half_height, cz + radius * s0 };
            const t1: [3]f32 = .{ cx + radius * c1, cy + half_height, cz + radius * s1 };
            const n0: [3]f32 = .{ c0, 0, s0 };
            const n1: [3]f32 = .{ c1, 0, s1 };
            self.appendTri3(b0, n0, t0, n0, t1, n1, col);
            self.appendTri3(b0, n0, t1, n1, b1, n1, col);
            self.appendTri3(top_c, up, t0, up, t1, up, col);
            self.appendTri3(bot_c, down, b1, down, b0, down, col);
        }
    }

    /// Append a (possibly tapered) cylinder between two world points: radius
    /// `r0` at `p0`, `r1` at `p1`, `sides` around the wall. An end cap is added
    /// only when its radius is non-zero, so `r1 == 0` yields a cone and equal
    /// radii a plain cylinder. Wall normals are radial; cap normals are axial.
    /// The axis is arbitrary (an orthonormal basis is built from it), so this
    /// also serves capsule bodies and tilted shapes. Triangle winding is
    /// irrelevant — the 3D pipeline is cull-`.none` and depth-sorted.
    pub fn appendConeBetween(
        self: *Cube3D,
        p0: Vec,
        p1: Vec,
        r0: f32,
        r1: f32,
        sides: u32,
        color: Color,
    ) void {
        const col: [4]f32 = Color.toFloats(color);
        const a0: [3]f32 = .{ p0[0], p0[1], p0[2] };
        const a1: [3]f32 = .{ p1[0], p1[1], p1[2] };
        var ax: [3]f32 = .{ a1[0] - a0[0], a1[1] - a0[1], a1[2] - a0[2] };
        const al: f32 = @sqrt(ax[0] * ax[0] + ax[1] * ax[1] + ax[2] * ax[2]);
        if (al < 1.0e-6) {
            return;
        }
        ax = .{ ax[0] / al, ax[1] / al, ax[2] / al };
        const ndir: [3]f32 = .{ -ax[0], -ax[1], -ax[2] };
        // Orthonormal basis (u, v) for the plane perpendicular to the axis.
        const ref: [3]f32 = if (@abs(ax[1]) < 0.99) .{ 0, 1, 0 } else .{ 1, 0, 0 };
        var u: [3]f32 = .{
            ref[1] * ax[2] - ref[2] * ax[1],
            ref[2] * ax[0] - ref[0] * ax[2],
            ref[0] * ax[1] - ref[1] * ax[0],
        };
        const ul: f32 = @sqrt(u[0] * u[0] + u[1] * u[1] + u[2] * u[2]);
        u = .{ u[0] / ul, u[1] / ul, u[2] / ul };
        const v: [3]f32 = .{
            ax[1] * u[2] - ax[2] * u[1],
            ax[2] * u[0] - ax[0] * u[2],
            ax[0] * u[1] - ax[1] * u[0],
        };
        var j: u32 = 0;
        while (j < sides) : (j += 1) {
            const t0: f32 = 2.0 * pi * float(j) / float(sides);
            const t1: f32 = 2.0 * pi * float(j + 1) / float(sides);
            const c0: f32 = @cos(t0);
            const s0: f32 = @sin(t0);
            const c1: f32 = @cos(t1);
            const s1: f32 = @sin(t1);
            const d0: [3]f32 = .{ c0 * u[0] + s0 * v[0], c0 * u[1] + s0 * v[1], c0 * u[2] + s0 * v[2] };
            const d1: [3]f32 = .{ c1 * u[0] + s1 * v[0], c1 * u[1] + s1 * v[1], c1 * u[2] + s1 * v[2] };
            const b0: [3]f32 = .{ a0[0] + r0 * d0[0], a0[1] + r0 * d0[1], a0[2] + r0 * d0[2] };
            const b1: [3]f32 = .{ a0[0] + r0 * d1[0], a0[1] + r0 * d1[1], a0[2] + r0 * d1[2] };
            const e0: [3]f32 = .{ a1[0] + r1 * d0[0], a1[1] + r1 * d0[1], a1[2] + r1 * d0[2] };
            const e1: [3]f32 = .{ a1[0] + r1 * d1[0], a1[1] + r1 * d1[1], a1[2] + r1 * d1[2] };
            self.appendTri3(b0, d0, e0, d0, e1, d1, col);
            self.appendTri3(b0, d0, e1, d1, b1, d1, col);
            if (r0 > 1.0e-6) {
                self.appendTri3(a0, ndir, b1, ndir, b0, ndir, col);
            }
            if (r1 > 1.0e-6) {
                self.appendTri3(a1, ax, e0, ax, e1, ax, col);
            }
        }
    }

    /// Append a cube with per-axis `size` and rotation `rot`, centred at
    /// `center`. Positions and normals are both rotated.
    pub fn appendCubeEx(
        self: *Cube3D,
        center: Vec,
        size: Vec,
        rot: Mat,
        color: Color,
    ) void {
        const col: [4]f32 = Color.toFloats(color);
        for (cube_indices) |i| {
            const v: CubeVertex = cube_vertices[i];
            const scaled: [3]f32 = .{ v.pos[0] * size[0], v.pos[1] * size[1], v.pos[2] * size[2] };
            const rp: [3]f32 = rotateVec3(rot, scaled);
            const wp: [3]f32 = .{ center[0] + rp[0], center[1] + rp[1], center[2] + rp[2] };
            const rn: [3]f32 = rotateVec3(rot, v.normal);
            self.batch.append(self.gpa, .{ .pos = wp, .normal = rn, .color = col }) catch {};
        }
    }

    /// Append the 12 wireframe edges of a rotated, per-axis-sized cube.
    pub fn appendCubeWiresEx(
        self: *Cube3D,
        center: Vec,
        size: Vec,
        rot: Mat,
        color: Color,
    ) void {
        var corners: [8][3]f32 = undefined;
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            const sx: f32 = if (k & 1 != 0) size[0] * 0.5 else -size[0] * 0.5;
            const sy: f32 = if (k & 2 != 0) size[1] * 0.5 else -size[1] * 0.5;
            const sz: f32 = if (k & 4 != 0) size[2] * 0.5 else -size[2] * 0.5;
            const rp: [3]f32 = rotateVec3(rot, .{ sx, sy, sz });
            corners[k] = .{ center[0] + rp[0], center[1] + rp[1], center[2] + rp[2] };
        }
        const edges = [12][2]u8{
            .{ 0, 1 }, .{ 2, 3 }, .{ 4, 5 }, .{ 6, 7 },
            .{ 0, 2 }, .{ 1, 3 }, .{ 4, 6 }, .{ 5, 7 },
            .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 },
        };
        for (edges) |e| {
            self.appendLine(corners[e[0]], corners[e[1]], color);
        }
    }

    /// Append a wireframe sphere: `rings` latitude circles + `sectors`
    /// longitude circles, as line segments. Raylib parity: `DrawSphereWires`.
    pub fn appendSphereWires(
        self: *Cube3D,
        center: Vec,
        radius: f32,
        rings: u32,
        sectors: u32,
        color: Color,
    ) void {
        const cx: f32 = center[0];
        const cy: f32 = center[1];
        const cz: f32 = center[2];
        const nr: u32 = @max(rings, 2);
        const ns: u32 = @max(sectors, 3);
        // Latitude circles (constant polar angle), stepped in longitude.
        var ri: u32 = 1;
        while (ri < nr) : (ri += 1) {
            const theta: f32 = pi * float(ri) / float(nr);
            const y: f32 = @cos(theta) * radius;
            const r: f32 = @sin(theta) * radius;
            var si: u32 = 0;
            while (si < ns) : (si += 1) {
                const p0: f32 = 2.0 * pi * float(si) / float(ns);
                const p1: f32 = 2.0 * pi * float(si + 1) / float(ns);
                self.appendLine(
                    .{ cx + r * @cos(p0), cy + y, cz + r * @sin(p0) },
                    .{ cx + r * @cos(p1), cy + y, cz + r * @sin(p1) },
                    color,
                );
            }
        }
        // Longitude circles (constant azimuth), stepped in polar angle.
        var sj: u32 = 0;
        while (sj < ns) : (sj += 1) {
            const phi: f32 = 2.0 * pi * float(sj) / float(ns);
            const cph: f32 = @cos(phi);
            const sph: f32 = @sin(phi);
            var rj: u32 = 0;
            while (rj < nr) : (rj += 1) {
                const t0: f32 = pi * float(rj) / float(nr);
                const t1: f32 = pi * float(rj + 1) / float(nr);
                const y0: f32 = @cos(t0) * radius;
                const r0: f32 = @sin(t0) * radius;
                const y1: f32 = @cos(t1) * radius;
                const r1: f32 = @sin(t1) * radius;
                self.appendLine(
                    .{ cx + r0 * cph, cy + y0, cz + r0 * sph },
                    .{ cx + r1 * cph, cy + y1, cz + r1 * sph },
                    color,
                );
            }
        }
    }

    /// Append a wireframe Y-axis cylinder: top + bottom rings joined by
    /// `sectors` vertical struts. Raylib parity: `DrawCylinderWires`.
    pub fn appendCylinderWires(
        self: *Cube3D,
        center: Vec,
        radius: f32,
        half_height: f32,
        sectors: u32,
        color: Color,
    ) void {
        const cx: f32 = center[0];
        const cy: f32 = center[1];
        const cz: f32 = center[2];
        const ns: u32 = @max(sectors, 3);
        const yt: f32 = cy + half_height;
        const yb: f32 = cy - half_height;
        var j: u32 = 0;
        while (j < ns) : (j += 1) {
            const p0: f32 = 2.0 * pi * float(j) / float(ns);
            const p1: f32 = 2.0 * pi * float(j + 1) / float(ns);
            const x0: f32 = cx + radius * @cos(p0);
            const z0: f32 = cz + radius * @sin(p0);
            const x1: f32 = cx + radius * @cos(p1);
            const z1: f32 = cz + radius * @sin(p1);
            self.appendLine(.{ x0, yt, z0 }, .{ x1, yt, z1 }, color); // top ring
            self.appendLine(.{ x0, yb, z0 }, .{ x1, yb, z1 }, color); // bottom ring
            self.appendLine(.{ x0, yb, z0 }, .{ x0, yt, z0 }, color); // vertical strut
        }
    }

    /// Append a flat XZ plane (normal +Y), centred at `center`, with X/Z extent.
    pub fn appendPlane(
        self: *Cube3D,
        center: Vec,
        size_x: f32,
        size_z: f32,
        color: Color,
    ) void {
        const col: [4]f32 = Color.toFloats(color);
        const hx: f32 = size_x * 0.5;
        const hz: f32 = size_z * 0.5;
        const up: [3]f32 = .{ 0, 1, 0 };
        const cy: f32 = center[1];
        const p0: [3]f32 = .{ center[0] - hx, cy, center[2] - hz };
        const p1: [3]f32 = .{ center[0] + hx, cy, center[2] - hz };
        const p2: [3]f32 = .{ center[0] + hx, cy, center[2] + hz };
        const p3: [3]f32 = .{ center[0] - hx, cy, center[2] + hz };
        self.appendTri3(p0, up, p1, up, p2, up, col);
        self.appendTri3(p0, up, p2, up, p3, up, col);
    }

    /// Draw a Model as filled triangles by CPU-transforming each mesh vertex
    /// into the solid batch (uniform scale + translation over the model
    /// transform; tint applied to all vertices).
    /// Append a single flat-shaded triangle (world-space positions) to the 3D
    /// batch. Normal is the geometric face normal. Used by callers that supply
    /// their own tessellated geometry (e.g. a plot surface) rather than one of
    /// the built-in shape helpers.
    pub fn appendTriangle(
        self: *Cube3D,
        p0: Vec,
        p1: Vec,
        p2: Vec,
        col: Color,
    ) void {
        const e1: Vec = p1 - p0;
        const e2: Vec = p2 - p0;
        // Geometric normal = e1 × e2 (xyz lanes), normalized; degenerate → up.
        var nx: f32 = e1[1] * e2[2] - e1[2] * e2[1];
        var ny: f32 = e1[2] * e2[0] - e1[0] * e2[2];
        var nz: f32 = e1[0] * e2[1] - e1[1] * e2[0];
        const len: f32 = @sqrt(nx * nx + ny * ny + nz * nz);
        if (len > 1e-12) {
            nx /= len;
            ny /= len;
            nz /= len;
        } else {
            nx = 0;
            ny = 1;
            nz = 0;
        }
        const n3: [3]f32 = .{ nx, ny, nz };
        const c: [4]f32 = Color.toFloats(col);
        self.appendTri3(
            .{ p0[0], p0[1], p0[2] },
            n3,
            .{ p1[0], p1[1], p1[2] },
            n3,
            .{ p2[0], p2[1], p2[2] },
            n3,
            c,
        );
    }

    pub fn appendModel(
        self: *Cube3D,
        model: types.Model,
        position: Vec,
        scale: f32,
        tint: Color,
    ) void {
        if (model.meshCount <= 0 or model.meshes == null) {
            return;
        }
        const col: [4]f32 = Color.toFloats(tint);
        const meshes: [*c]types.Mesh = model.meshes;
        var m: usize = 0;
        while (m < @as(usize, @intCast(model.meshCount))) : (m += 1) {
            const mesh: types.Mesh = meshes[m];
            if (mesh.vertices == null) {
                continue;
            }
            const v: [*c]f32 = mesh.vertices;
            const n: [*c]f32 = mesh.normals;
            if (mesh.indices != null) {
                const ic: usize = @intCast(mesh.triangleCount * 3);
                const idx: [*c]c_ushort = mesh.indices;
                var t: usize = 0;
                while (t + 3 <= ic) : (t += 3) {
                    const e0: usize = idx[t];
                    const e1: usize = idx[t + 1];
                    const e2: usize = idx[t + 2];
                    self.appendTri3(
                        meshWorldPos(v, e0, model.transform, position, scale),
                        meshWorldNormal(n, e0, model.transform),
                        meshWorldPos(v, e1, model.transform, position, scale),
                        meshWorldNormal(n, e1, model.transform),
                        meshWorldPos(v, e2, model.transform, position, scale),
                        meshWorldNormal(n, e2, model.transform),
                        col,
                    );
                }
            } else {
                const vc: usize = @intCast(mesh.vertexCount);
                var k: usize = 0;
                while (k + 3 <= vc) : (k += 3) {
                    self.appendTri3(
                        meshWorldPos(v, k, model.transform, position, scale),
                        meshWorldNormal(n, k, model.transform),
                        meshWorldPos(v, k + 1, model.transform, position, scale),
                        meshWorldNormal(n, k + 1, model.transform),
                        meshWorldPos(v, k + 2, model.transform, position, scale),
                        meshWorldNormal(n, k + 2, model.transform),
                        col,
                    );
                }
            }
        }
    }

    /// Draw a Model as wireframe by emitting each triangle's three edges as
    /// lines (raylib drawModelWires semantics).
    pub fn appendModelWires(
        self: *Cube3D,
        model: types.Model,
        position: Vec,
        scale: f32,
        tint: Color,
    ) void {
        if (model.meshCount <= 0 or model.meshes == null) {
            return;
        }
        const meshes: [*c]types.Mesh = model.meshes;
        var m: usize = 0;
        while (m < @as(usize, @intCast(model.meshCount))) : (m += 1) {
            const mesh: types.Mesh = meshes[m];
            if (mesh.vertices == null) {
                continue;
            }
            const v: [*c]f32 = mesh.vertices;
            if (mesh.indices != null) {
                const ic: usize = @intCast(mesh.triangleCount * 3);
                const idx: [*c]c_ushort = mesh.indices;
                var t: usize = 0;
                while (t + 3 <= ic) : (t += 3) {
                    const p0: [3]f32 = meshWorldPos(v, idx[t], model.transform, position, scale);
                    const p1: [3]f32 = meshWorldPos(v, idx[t + 1], model.transform, position, scale);
                    const p2: [3]f32 = meshWorldPos(v, idx[t + 2], model.transform, position, scale);
                    self.appendLine(p0, p1, tint);
                    self.appendLine(p1, p2, tint);
                    self.appendLine(p2, p0, tint);
                }
            } else {
                const vc: usize = @intCast(mesh.vertexCount);
                var k: usize = 0;
                while (k + 3 <= vc) : (k += 3) {
                    const p0: [3]f32 = meshWorldPos(v, k, model.transform, position, scale);
                    const p1: [3]f32 = meshWorldPos(v, k + 1, model.transform, position, scale);
                    const p2: [3]f32 = meshWorldPos(v, k + 2, model.transform, position, scale);
                    self.appendLine(p0, p1, tint);
                    self.appendLine(p1, p2, tint);
                    self.appendLine(p2, p0, tint);
                }
            }
        }
    }

    /// Upload one vertex stream and issue a single draw with the given
    /// pipeline. No-op when empty. The GPU buffer GROWS to fit the frame rather
    /// than truncating: a fixed cap used to silently drop every primitive past
    /// the budget (the "bodies vanish past ~N spheres" bug — e.g. the Plinko
    /// board's balls behind ~50 pegs). Growth happens in `batch_capacity`-vertex
    /// chunks and settles at the scene's high-water mark (recreation is rare).
    fn drawStream(
        self: *Cube3D,
        ps: anytype,
        pipeline: wgpu.RenderPipelineHandle,
        buffer_ptr: *wgpu.BufferHandle,
        cap_ptr: *u32,
        cursor_ptr: *u32,
        items: []const BatchVertex,
    ) void {
        const n: u32 = @intCast(items.len);
        if (n == 0) {
            return;
        }
        // APPEND at this frame's running offset, never at 0: a frame's writes all
        // execute before its single submit, so restarting at 0 in a second pass
        // would hand the first pass's recorded draw the second pass's vertices.
        const base: u32 = cursor_ptr.*;
        const needed: u32 = base + n;
        if (needed > cap_ptr.*) {
            var new_cap: u32 = cap_ptr.*;
            while (new_cap < needed) : (new_cap += batch_capacity) {}
            buffer_ptr.* = wgpu.createBuffer(self.device, .{
                .size = @as(u64, new_cap) * @sizeOf(BatchVertex),
                .usage = .{ .vertex = true, .copy_dst = true },
                .label = "draw3d_batch_vbo",
            });
            cap_ptr.* = new_cap;
        }
        // Backstop: after grow the buffer must hold the whole frame. If this ever
        // fires, the GPU refused a buffer large enough (past the device's max
        // buffer size) — a loud panic beats a silently half-drawn scene.
        assertf(
            needed <= cap_ptr.*,
            @src(),
            "draw3d batch overflow: {d} verts this frame > cap {d}",
            .{ needed, cap_ptr.* },
        );
        const byte_base: u64 = @as(u64, base) * @sizeOf(BatchVertex);
        wgpu.queueWriteBuffer(ps.queue, buffer_ptr.*, byte_base, std.mem.sliceAsBytes(items[0..n]));
        WgpuBackend.setPipeline(ps, shader.RenderPipeline(void, void){ .gpu_handle = pipeline });
        self.bindViewProj(ps);
        render_pass.setVertexBuffer(ps.pass, .{
            .slot = 0,
            .buffer = buffer_ptr.*,
            .offset = byte_base,
            .size = @as(u64, n) * @sizeOf(BatchVertex),
        });
        render_pass.draw(ps.pass, .{
            .vertex_count = n,
            .instance_count = 1,
            .first_vertex = 0,
            .first_instance = 0,
        });
        cursor_ptr.* = needed;
    }

    /// Flush both batches into the given depth-attached pass: filled triangles
    /// (solids) first, then lines (grids / wires / segments).
    pub fn flush(self: *Cube3D, ps: anytype) void {
        self.drawStream(
            ps,
            self.pipeline,
            &self.batch_buffer,
            &self.batch_buffer_cap,
            &self.batch_cursor,
            self.batch.items,
        );
        self.drawStream(
            ps,
            self.line_pipeline,
            &self.line_buffer,
            &self.line_buffer_cap,
            &self.line_cursor,
            self.line_batch.items,
        );
        self.flushTextured(ps);
        self.flushDecals(ps);
    }

    /// Upload the textured-quad batch and issue one draw per recorded texture
    /// (group 1 swaps per texture; group 0 camera is shared). Same depth pass as
    /// the solids, so textured cubes/billboards occlude + are occluded correctly.
    /// Upload a receiver mesh's positions once as a pos-only vertex buffer.
    /// Returns a handle (index) to pass to `drawDecal`. World-space positions
    /// are read straight from `mesh.vertices` (xyz interleaved) via its indices,
    /// de-indexed into a flat triangle-soup vbo (the decal pipeline draws
    /// non-indexed). Call once per receiver at setup, not per frame.
    pub fn uploadDecalReceiver(
        self: *Cube3D,
        queue: wgpu.QueueHandle,
        mesh: types.Mesh,
    ) ?u32 {
        if (mesh.vertices == null or mesh.vertexCount <= 0 or mesh.triangleCount <= 0) {
            return null;
        }
        const v: [*c]f32 = mesh.vertices;
        const nrm: [*c]f32 = mesh.normals;
        const tri_count: usize = @intCast(mesh.triangleCount);
        const vcount: usize = tri_count * 3;
        // Interleaved position (3f) + normal (3f) per vertex, de-indexed to a
        // triangle soup. The FS uses the normal to reject fragments whose
        // surface faces away from the projector (so a decal never paints the far
        // wall of its box — e.g. the back of the sphere).
        const data: []f32 = self.gpa.alloc(f32, vcount * 6) catch return null;
        defer self.gpa.free(data);

        var w: usize = 0;
        var t: usize = 0;
        while (t < tri_count) : (t += 1) {
            var tri: [3]usize = undefined;
            if (mesh.indices != null) {
                tri = .{
                    @intCast(mesh.indices[t * 3 + 0]),
                    @intCast(mesh.indices[t * 3 + 1]),
                    @intCast(mesh.indices[t * 3 + 2]),
                };
            } else {
                tri = .{ t * 3 + 0, t * 3 + 1, t * 3 + 2 };
            }
            for (tri) |vi| {
                data[w + 0] = v[vi * 3 + 0];
                data[w + 1] = v[vi * 3 + 1];
                data[w + 2] = v[vi * 3 + 2];
                if (nrm != null) {
                    data[w + 3] = nrm[vi * 3 + 0];
                    data[w + 4] = nrm[vi * 3 + 1];
                    data[w + 5] = nrm[vi * 3 + 2];
                } else {
                    data[w + 3] = 0;
                    data[w + 4] = 0;
                    data[w + 5] = 0;
                }
                w += 6;
            }
        }

        const vbo: wgpu.BufferHandle = wgpu.createBufferInit(
            self.device,
            queue,
            std.mem.sliceAsBytes(data),
            .{ .vertex = true, .copy_dst = true },
            "draw3d_decal_receiver",
        );
        const handle: u32 = @intCast(self.decal_receivers.items.len);
        self.decal_receivers.append(self.gpa, .{ .vbo = vbo, .vcount = @intCast(vcount) }) catch return null;
        return handle;
    }

    /// Destroy every uploaded decal-receiver VBO and clear the list. Called on
    /// example teardown (like Renderer2D.resetRegistry) so receiver buffers an
    /// example uploaded don't accumulate in the engine-owned Cube3D across
    /// example lifecycles. The shared decal_proj_buffer (engine-lifetime) stays.
    pub fn resetDecalReceivers(self: *Cube3D) void {
        for (self.decal_receivers.items) |recv| {
            if (recv.vbo != .invalid) {
                wgpu.destroyBuffer(recv.vbo);
            }
        }
        self.decal_receivers.clearRetainingCapacity();
    }

    /// Flush every PER-EXAMPLE 3D registration so the persistent engine `Cube3D`
    /// doesn't grow across example lifecycles (the twice-lifecycle leak probe and
    /// the launcher's app-switch). The FIXED baseline built in `init` — all seven
    /// pipelines, their layouts/modules, the vp/decal ring buffers, and the fixed
    /// UBO `Resources` — PERSISTS; only example-driven caches clear here:
    ///   • tex_bind_cache: one bind group per example texture, keyed by the
    ///     texture-VIEW handle. That handle changes every lifecycle (a new texture
    ///     is loaded), so without this flush each run strands its predecessor's
    ///     bind group — the exact `drawBillboard` +1 bind_group/lifecycle leak.
    ///   • mesh_gpu: the vbo/ibo uploaded for each example mesh (instancing demos).
    ///   • decal_receivers: per-example receiver geometry (folds in the call above).
    /// Mirrors `Renderer2D.resetRegistry`; called from `runnerDeinit`.
    pub fn resetRegistry(self: *Cube3D) void {
        var it: @TypeOf(self.tex_bind_cache).ValueIterator = self.tex_bind_cache.valueIterator();
        while (it.next()) |bg| {
            if (bg.* != .invalid) {
                wgpu.destroyBindGroup(bg.*);
            }
        }
        self.tex_bind_cache.clearRetainingCapacity();

        for (self.mesh_gpu.items) |m| {
            if (m.vbo != .invalid) {
                wgpu.destroyBuffer(m.vbo);
            }
            if (m.ibo != .invalid) {
                wgpu.destroyBuffer(m.ibo);
            }
        }
        self.mesh_gpu.clearRetainingCapacity();

        self.resetDecalReceivers();
    }

    /// Free EVERY GPU handle and heap allocation this Cube3D owns — the fixed
    /// engine-baseline teardown. After this the create/destroy census returns to
    /// zero for the 3D subsystem; nothing is left for a JS-side device release to
    /// mop up. Call once at engine shutdown, after the final frame.
    ///
    /// All seven pipelines are built directly by `makePipeline` /
    /// `createRenderPipeline` (NOT the dedup `PipelineCache`), so this owns and
    /// destroys them outright — there is no double-free with `PipelineCache.deinit`.
    pub fn deinit(self: *Cube3D) void {
        // Per-example caches first: destroy the bind groups / mesh buffers /
        // decal-receiver buffers they hold, then the collections' heap is freed
        // at the bottom of this function.
        self.resetRegistry();

        wgpu.destroyRenderPipeline(self.pipeline);
        wgpu.destroyRenderPipeline(self.line_pipeline);
        wgpu.destroyRenderPipeline(self.instanced_pipeline);
        wgpu.destroyRenderPipeline(self.tex_pipeline);
        wgpu.destroyRenderPipeline(self.billboard_pipeline);
        wgpu.destroyRenderPipeline(self.skybox_pipeline);
        wgpu.destroyRenderPipeline(self.decal_pipeline);

        // The build-only layout + modules retained as fields (see init).
        wgpu.destroyPipelineLayout(self.pipeline_layout);
        wgpu.destroyShaderModule(self.vs_module);
        wgpu.destroyShaderModule(self.fs_module);
        wgpu.destroyShaderModule(self.instanced_vs_module);

        // Bind-group layouts reused at runtime to mint per-texture / per-decal
        // bind groups (so they had to outlive init).
        wgpu.destroyBindGroupLayout(self.tex_bgl);
        wgpu.destroyBindGroupLayout(self.decal_proj_bgl);

        // Pre-built ring bind groups (one per slot).
        for (self.vp_ring_bgs) |bg| {
            if (bg != .invalid) {
                wgpu.destroyBindGroup(bg);
            }
        }
        for (self.decal_proj_bgs) |bg| {
            if (bg != .invalid) {
                wgpu.destroyBindGroup(bg);
            }
        }

        // Fixed vertex / uniform buffers.
        wgpu.destroyBuffer(self.batch_buffer);
        wgpu.destroyBuffer(self.line_buffer);
        wgpu.destroyBuffer(self.instance_buffer);
        wgpu.destroyBuffer(self.tex_buffer);
        wgpu.destroyBuffer(self.decal_proj_buffer);
        wgpu.destroyBuffer(self.vp_ring_buffer);

        // The fixed UBO Resources own their own buffer + group-0 bind group.
        self.resources.deinit();
        self.skybox_resources.deinit();

        // Heap backing of the (now GPU-empty) batch/registry collections.
        self.batch.deinit(self.gpa);
        self.line_batch.deinit(self.gpa);
        self.mesh_gpu.deinit(self.gpa);
        self.tex_batch.deinit(self.gpa);
        self.tex_draws.deinit(self.gpa);
        self.tex_bind_cache.deinit(self.gpa);
        self.decal_receivers.deinit(self.gpa);
        self.decal_draws.deinit(self.gpa);
    }

    /// Record a projected decal: paint `tex` onto receiver `handle` wherever
    /// its fragments fall inside the projector box. `projector` maps world →
    /// box space (the CPU-built `lookAt·rotZ`); `size` is the box world extent.
    /// Writes the projector to a fresh ring slot and records the draw; the
    /// actual draw happens in `flushDecals` at the end of the 3D pass.
    pub fn drawDecal(
        self: *Cube3D,
        ps_queue: anytype,
        handle: u32,
        projector: Mat,
        forward: Vec,
        size: f32,
        tex: WgpuTexture,
        tint: Color,
    ) void {
        if (handle >= self.decal_receivers.items.len) {
            return;
        }
        const tex_bg: wgpu.BindGroupHandle = self.texBindGroup(tex);
        if (tex_bg == .invalid) {
            return;
        }
        const slot: u32 = self.decal_proj_cursor % decal_ring_len;
        self.decal_proj_cursor += 1;
        const col: [4]f32 = Color.toFloats(tint);
        const half_size: f32 = 0.5 * size;
        const ubo: DecalUbo = .{
            .projector = projector,
            .color = .{ col[0], col[1], col[2], col[3] },
            .params = .{ half_size, 1.0 / size, 0, 0 },
            .forward = forward,
        };
        const ubo_bytes: [shader_iface.wireSizeOf(DecalUbo)]u8 = shader_iface.wireOf(DecalUbo, &ubo);
        wgpu.queueWriteBuffer(
            ps_queue,
            self.decal_proj_buffer,
            @as(u64, slot) * decal_ubo_stride,
            &ubo_bytes,
        );
        self.decal_draws.append(self.gpa, .{
            .receiver = handle,
            .proj_slot = slot,
            .tex_bg = tex_bg,
        }) catch {};
    }

    /// Draw every recorded decal: for each, bind the camera (group 0), the
    /// decal's projector slot (group 1), its texture (group 2), and re-draw the
    /// receiver's positions. The FS discards fragments outside the box, so only
    /// the surface patch under each projector is painted. less_equal_no_write
    /// depth so decals lie on the surface and stack without z-fighting.
    fn flushDecals(self: *Cube3D, ps: anytype) void {
        if (self.decal_draws.items.len == 0) {
            return;
        }
        WgpuBackend.setPipeline(ps, shader.RenderPipeline(void, void){ .gpu_handle = self.decal_pipeline });
        self.bindViewProj(ps);
        for (self.decal_draws.items) |d| {
            const recv: DecalReceiver = self.decal_receivers.items[d.receiver];
            WgpuBackend.setBindGroup(ps, 1, self.decal_proj_bgs[d.proj_slot]);
            WgpuBackend.setBindGroup(ps, 2, d.tex_bg);
            render_pass.setVertexBuffer(ps.pass, .{
                .slot = 0,
                .buffer = recv.vbo,
                .offset = 0,
                .size = @as(u64, recv.vcount) * 24,
            });
            render_pass.draw(ps.pass, .{
                .vertex_count = recv.vcount,
                .instance_count = 1,
                .first_vertex = 0,
                .first_instance = 0,
            });
        }
    }

    fn flushTextured(self: *Cube3D, ps: anytype) void {
        if (self.tex_draws.items.len == 0) {
            return;
        }
        var n: u32 = @intCast(self.tex_batch.items.len);
        // Loud rather than silent: truncating textured geometry would drop
        // whole quads (the same class of bug as the solid-batch overflow). The
        // cap is large (tex_capacity quads); exceeding it is a real authoring
        // error worth surfacing in dev/asserts builds. The budget is now for the
        // WHOLE FRAME, since a second 3D pass appends rather than restarting.
        const base: u32 = self.tex_cursor;
        assertf(
            base + n <= tex_capacity,
            @src(),
            "draw3d textured batch overflow: {d} verts this frame > cap {d}",
            .{ base + n, tex_capacity },
        );
        if (base + n > tex_capacity) {
            n = @intCast(tex_capacity - @min(@as(usize, base), tex_capacity));
        }
        if (n == 0) {
            return;
        }
        const byte_base: u64 = @as(u64, base) * @sizeOf(TexVertex);
        wgpu.queueWriteBuffer(ps.queue, self.tex_buffer, byte_base, std.mem.sliceAsBytes(self.tex_batch.items[0..n]));
        render_pass.setVertexBuffer(ps.pass, .{
            .slot = 0,
            .buffer = self.tex_buffer,
            // The bound RANGE starts at this pass's slice, so each draw's
            // `first_vertex` stays relative to the batch, unchanged.
            .offset = byte_base,
            .size = @as(u64, n) * @sizeOf(TexVertex),
        });
        self.tex_cursor = base + n;
        for (self.tex_draws.items) |d| {
            if (d.first + d.count > n) {
                continue;
            }
            // Per draw: opaque textured cubes write depth (tex_pipeline);
            // transparent billboards test-only (billboard_pipeline).
            WgpuBackend.setPipeline(ps, shader.RenderPipeline(void, void){ .gpu_handle = d.pipeline });
            self.bindViewProj(ps);
            WgpuBackend.setBindGroup(ps, 1, d.bind_group);
            render_pass.draw(ps.pass, .{
                .vertex_count = d.count,
                .instance_count = 1,
                .first_vertex = d.first,
                .first_instance = 0,
            });
        }
    }

    /// Get-or-create the group-1 bind group for a texture, cached by view handle.
    fn texBindGroup(self: *Cube3D, tex: WgpuTexture) wgpu.BindGroupHandle {
        const key: u64 = @intFromEnum(tex.view);
        if (self.tex_bind_cache.get(key)) |bg| {
            return bg;
        }
        const entries = [_]gpu.BindGroupEntry{
            .{ .binding = 0, .resource = .{ .texture_view = tex.view } },
            .{ .binding = 1, .resource = .{ .sampler = tex.sampler } },
        };
        const blob: []const u8 = gpu.encodeBindGroupEntries(self.gpa, &entries) catch return .invalid;
        defer self.gpa.free(blob);
        const bg: wgpu.BindGroupHandle = wgpu.createBindGroup(self.device, self.tex_bgl, blob, "draw3d_tex_bg");
        self.tex_bind_cache.put(self.gpa, key, bg) catch {};
        return bg;
    }

    /// Append one textured quad (CCW p0→p3) with corner UVs (top-left origin).
    fn appendTexQuad(
        self: *Cube3D,
        p0: [3]f32,
        p1: [3]f32,
        p2: [3]f32,
        p3: [3]f32,
        col: [4]f32,
    ) void {
        self.appendTexQuadUV(p0, p1, p2, p3, .{ 0, 0 }, .{ 1, 1 }, col);
    }

    /// Like `appendTexQuad` but with an explicit UV sub-rectangle: `uv_min` maps
    /// to corner p0 (top-left), `uv_max` to p2 (bottom-right). Lets a billboard
    /// frame one cell of a sprite atlas instead of the whole texture.
    fn appendTexQuadUV(
        self: *Cube3D,
        p0: [3]f32,
        p1: [3]f32,
        p2: [3]f32,
        p3: [3]f32,
        uv_min: [2]f32,
        uv_max: [2]f32,
        col: [4]f32,
    ) void {
        const su0: f32 = uv_min[0];
        const sv0: f32 = uv_min[1];
        const su1: f32 = uv_max[0];
        const sv1: f32 = uv_max[1];
        self.tex_batch.append(self.gpa, .{ .pos = p0, .uv = .{ su0, sv0 }, .color = col }) catch {};
        self.tex_batch.append(self.gpa, .{ .pos = p1, .uv = .{ su1, sv0 }, .color = col }) catch {};
        self.tex_batch.append(self.gpa, .{ .pos = p2, .uv = .{ su1, sv1 }, .color = col }) catch {};
        self.tex_batch.append(self.gpa, .{ .pos = p0, .uv = .{ su0, sv0 }, .color = col }) catch {};
        self.tex_batch.append(self.gpa, .{ .pos = p2, .uv = .{ su1, sv1 }, .color = col }) catch {};
        self.tex_batch.append(self.gpa, .{ .pos = p3, .uv = .{ su0, sv1 }, .color = col }) catch {};
    }

    /// Draw an axis-aligned cube with `tex` mapped 0..1 on each of its six faces.
    pub fn drawCubeTexture(
        self: *Cube3D,
        tex: WgpuTexture,
        center: Vec,
        size: f32,
        tint: Color,
    ) void {
        const bg: wgpu.BindGroupHandle = self.texBindGroup(tex);
        if (bg == .invalid) {
            return;
        }
        const first: u32 = @intCast(self.tex_batch.items.len);
        const col: [4]f32 = Color.toFloats(tint);
        const h: f32 = size * 0.5;
        const x0: f32 = center[0] - h;
        const x1: f32 = center[0] + h;
        const y0: f32 = center[1] - h;
        const y1: f32 = center[1] + h;
        const z0: f32 = center[2] - h;
        const z1: f32 = center[2] + h;
        // +Z, -Z, +X, -X, +Y, -Y (cull is .none, so winding is cosmetic).
        self.appendTexQuad(.{ x0, y1, z1 }, .{ x1, y1, z1 }, .{ x1, y0, z1 }, .{ x0, y0, z1 }, col);
        self.appendTexQuad(.{ x1, y1, z0 }, .{ x0, y1, z0 }, .{ x0, y0, z0 }, .{ x1, y0, z0 }, col);
        self.appendTexQuad(.{ x1, y1, z1 }, .{ x1, y1, z0 }, .{ x1, y0, z0 }, .{ x1, y0, z1 }, col);
        self.appendTexQuad(.{ x0, y1, z0 }, .{ x0, y1, z1 }, .{ x0, y0, z1 }, .{ x0, y0, z0 }, col);
        self.appendTexQuad(.{ x0, y1, z0 }, .{ x1, y1, z0 }, .{ x1, y1, z1 }, .{ x0, y1, z1 }, col);
        self.appendTexQuad(.{ x0, y0, z1 }, .{ x1, y0, z1 }, .{ x1, y0, z0 }, .{ x0, y0, z0 }, col);
        self.tex_draws.append(self.gpa, .{
            .bind_group = bg,
            .pipeline = self.tex_pipeline,
            .first = first,
            .count = 36,
        }) catch {};
    }

    /// Draw a camera-facing textured quad at `pos`, `w`×`h`, using the camera's
    /// `right`/`up` basis (caller supplies them, normalized).
    pub fn drawBillboard(
        self: *Cube3D,
        tex: WgpuTexture,
        right: [3]f32,
        up: [3]f32,
        pos: Vec,
        w: f32,
        h: f32,
        tint: Color,
    ) void {
        const bg: wgpu.BindGroupHandle = self.texBindGroup(tex);
        if (bg == .invalid) {
            return;
        }
        const first: u32 = @intCast(self.tex_batch.items.len);
        const col: [4]f32 = Color.toFloats(tint);
        const hw: f32 = w * 0.5;
        const hh: f32 = h * 0.5;
        const rx: f32 = right[0] * hw;
        const ry: f32 = right[1] * hw;
        const rz: f32 = right[2] * hw;
        const ux: f32 = up[0] * hh;
        const uy: f32 = up[1] * hh;
        const uz: f32 = up[2] * hh;
        const tl: [3]f32 = .{ pos[0] - rx + ux, pos[1] - ry + uy, pos[2] - rz + uz };
        const tr: [3]f32 = .{ pos[0] + rx + ux, pos[1] + ry + uy, pos[2] + rz + uz };
        const br: [3]f32 = .{ pos[0] + rx - ux, pos[1] + ry - uy, pos[2] + rz - uz };
        const bl: [3]f32 = .{ pos[0] - rx - ux, pos[1] - ry - uy, pos[2] - rz - uz };
        self.appendTexQuad(tl, tr, br, bl, col);
        self.tex_draws.append(self.gpa, .{
            .bind_group = bg,
            .pipeline = self.billboard_pipeline,
            .first = first,
            .count = 6,
        }) catch {};
    }

    /// Camera-facing textured quad framing a UV sub-rect of `tex` (a sprite
    /// atlas cell). `uv_min`/`uv_max` are normalized 0..1. `anchor` shifts the
    /// quad in its own plane in units of (w, h): {0.5, 0.5} centers it (the
    /// default billboard), {0.5, 0} plants its BOTTOM on `pos` (feet-on-ground
    /// sprites). Raylib parity: the core of `DrawBillboardPro`.
    pub fn drawBillboardRec(
        self: *Cube3D,
        tex: WgpuTexture,
        right: [3]f32,
        up: [3]f32,
        pos: Vec,
        w: f32,
        h: f32,
        uv_min: [2]f32,
        uv_max: [2]f32,
        anchor: [2]f32,
        tint: Color,
    ) void {
        const bg: wgpu.BindGroupHandle = self.texBindGroup(tex);
        if (bg == .invalid) {
            return;
        }
        const first: u32 = @intCast(self.tex_batch.items.len);
        const col: [4]f32 = Color.toFloats(tint);
        const hw: f32 = w * 0.5;
        const hh: f32 = h * 0.5;
        // Anchor shift: move the centre so `anchor` (in w/h units, origin
        // bottom-left of the quad) lands on `pos`. {0.5,0.5} = no shift.
        const ox: f32 = (0.5 - anchor[0]) * w;
        const oy: f32 = (0.5 - anchor[1]) * h;
        const cx: f32 = pos[0] + right[0] * ox + up[0] * oy;
        const cy: f32 = pos[1] + right[1] * ox + up[1] * oy;
        const cz: f32 = pos[2] + right[2] * ox + up[2] * oy;
        const rx: f32 = right[0] * hw;
        const ry: f32 = right[1] * hw;
        const rz: f32 = right[2] * hw;
        const ux: f32 = up[0] * hh;
        const uy: f32 = up[1] * hh;
        const uz: f32 = up[2] * hh;
        const tl: [3]f32 = .{ cx - rx + ux, cy - ry + uy, cz - rz + uz };
        const tr: [3]f32 = .{ cx + rx + ux, cy + ry + uy, cz + rz + uz };
        const br: [3]f32 = .{ cx + rx - ux, cy + ry - uy, cz + rz - uz };
        const bl: [3]f32 = .{ cx - rx - ux, cy - ry - uy, cz - rz - uz };
        self.appendTexQuadUV(tl, tr, br, bl, uv_min, uv_max, col);
        self.tex_draws.append(self.gpa, .{
            .bind_group = bg,
            .pipeline = self.billboard_pipeline,
            .first = first,
            .count = 6,
        }) catch {};
    }

    /// Draw an arbitrary list of textured, depth-tested 3D triangles from `tex`.
    /// `positions` and `uvs` are parallel arrays, 3 entries per triangle (length
    /// must be a multiple of 3 and match). Used for projected decals and other
    /// clipped/generated textured geometry the quad helpers can't express. Uses
    /// the depth-tested `tex_pipeline` (not the always-facing billboard one), so
    /// decals sit on the surface and are occluded correctly.
    pub fn drawTexturedTriangles(
        self: *Cube3D,
        tex: WgpuTexture,
        positions: []const [3]f32,
        uvs: []const [2]f32,
        tint: Color,
        depth_write: bool,
    ) void {
        if (positions.len == 0 or positions.len != uvs.len or positions.len % 3 != 0) {
            return;
        }
        const bg: wgpu.BindGroupHandle = self.texBindGroup(tex);
        if (bg == .invalid) {
            return;
        }
        const first: u32 = @intCast(self.tex_batch.items.len);
        const col: [4]f32 = Color.toFloats(tint);
        for (positions, uvs) |p, uv| {
            self.tex_batch.append(self.gpa, .{ .pos = p, .uv = uv, .color = col }) catch {};
        }
        // depth_write=true uses the opaque `tex_pipeline` (test + write); false
        // uses `billboard_pipeline` (test-only), so many overlapping translucent
        // triangles — e.g. stacked decals — blend by draw order instead of
        // z-fighting each other at the same depth. Both still test against the
        // opaque scene, so the geometry is occluded correctly either way.
        const pipeline: wgpu.RenderPipelineHandle =
            if (depth_write) self.tex_pipeline else self.billboard_pipeline;
        self.tex_draws.append(self.gpa, .{
            .bind_group = bg,
            .pipeline = pipeline,
            .first = first,
            .count = @intCast(positions.len),
        }) catch {};
    }

    fn ensureMeshGpu(self: *Cube3D, mesh: *types.Mesh, queue: wgpu.QueueHandle) ?u32 {
        if (mesh.vaoId != 0) {
            return mesh.vaoId - 1;
        }
        if (mesh.vertices == null or mesh.indices == null or mesh.vertexCount <= 0 or mesh.triangleCount <= 0) {
            return null;
        }
        const vcount: usize = @intCast(mesh.vertexCount);
        const icount: usize = @intCast(mesh.triangleCount * 3);

        const verts: []MeshVertex = self.gpa.alloc(MeshVertex, vcount) catch return null;
        defer self.gpa.free(verts);
        const has_normals: bool = mesh.normals != null;
        var i: usize = 0;
        while (i < vcount) : (i += 1) {
            const px: f32 = mesh.vertices[i * 3];
            const py: f32 = mesh.vertices[i * 3 + 1];
            const pz: f32 = mesh.vertices[i * 3 + 2];
            const nrm: [3]f32 = if (has_normals)
                .{ mesh.normals[i * 3], mesh.normals[i * 3 + 1], mesh.normals[i * 3 + 2] }
            else
                .{ 0, 1, 0 };
            verts[i] = .{ .pos = .{ px, py, pz }, .normal = nrm };
        }

        const vbo: wgpu.BufferHandle = wgpu.createBuffer(self.device, .{
            .size = @as(u64, vcount) * @sizeOf(MeshVertex),
            .usage = .{ .vertex = true, .copy_dst = true },
            .label = "mesh_vbo",
        });
        const ibo: wgpu.BufferHandle = wgpu.createBuffer(self.device, .{
            .size = @as(u64, icount) * @sizeOf(u16),
            .usage = .{ .index = true, .copy_dst = true },
            .label = "mesh_ibo",
        });
        wgpu.queueWriteBuffer(queue, vbo, 0, std.mem.sliceAsBytes(verts));
        wgpu.queueWriteBuffer(queue, ibo, 0, std.mem.sliceAsBytes(mesh.indices[0..icount]));

        self.mesh_gpu.append(self.gpa, .{ .vbo = vbo, .ibo = ibo, .index_count = @intCast(icount) }) catch return null;
        const slot: u32 = @intCast(self.mesh_gpu.items.len - 1);
        mesh.vaoId = slot + 1;
        return slot;
    }

    /// Draw `transforms.len` instances of `mesh` (one tint for all) in a single
    /// instanced indexed draw, recorded straight into the active 3D pass. The
    /// mesh uploads on first use; the per-instance model+colour buffer is rebuilt
    /// each call (fine into the low thousands).
    pub fn drawMeshInstanced(
        self: *Cube3D,
        ps: anytype,
        mesh: *types.Mesh,
        transforms: []const Mat,
        color: Color,
    ) void {
        if (transforms.len == 0) {
            return;
        }
        const slot: u32 = self.ensureMeshGpu(mesh, ps.queue) orelse return;
        const mg: MeshGpu = self.mesh_gpu.items[slot];

        const count: u32 = @intCast(transforms.len);
        // APPEND, don't restart: every `drawMeshInstanced` in a frame shares this
        // buffer, and all of a frame's queue writes land before its single submit.
        // Writing at 0 each call meant TWO instanced meshes in one frame ended up
        // both drawing the LAST call's transforms — no second pass required.
        const base: u32 = self.inst_cursor;
        const needed: u32 = base + count;
        if (needed > self.instance_capacity) {
            self.instance_buffer = wgpu.createBuffer(self.device, .{
                .size = @as(u64, needed) * @sizeOf(InstanceVertex),
                .usage = .{ .vertex = true, .copy_dst = true },
                .label = "draw3d_instance_vbo",
            });
            self.instance_capacity = needed;
        }

        const col: [4]f32 = Color.toFloats(color);
        const insts: []InstanceVertex = self.gpa.alloc(InstanceVertex, count) catch return;
        defer self.gpa.free(insts);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            // zm.Mat is [4]@Vector(4, f32); reinterpret to the extern-safe
            // [4][4]f32 (identical bytes) for the vertex buffer.
            insts[i] = .{ .model = @bitCast(transforms[i]), .color = col };
        }
        const byte_base: u64 = @as(u64, base) * @sizeOf(InstanceVertex);
        wgpu.queueWriteBuffer(ps.queue, self.instance_buffer, byte_base, std.mem.sliceAsBytes(insts));
        self.inst_cursor = needed;

        WgpuBackend.setPipeline(ps, shader.RenderPipeline(void, void){ .gpu_handle = self.instanced_pipeline });
        self.bindViewProj(ps);
        render_pass.setVertexBuffer(ps.pass, .{ .slot = 0, .buffer = mg.vbo, .offset = 0, .size = ~@as(u64, 0) });
        render_pass.setVertexBuffer(ps.pass, .{
            .slot = 1,
            .buffer = self.instance_buffer,
            .offset = byte_base,
            .size = @as(u64, count) * @sizeOf(InstanceVertex),
        });
        render_pass.setIndexBuffer(ps.pass, .{ .buffer = mg.ibo, .format = .uint16 });
        render_pass.drawIndexed(ps.pass, .{
            .index_count = mg.index_count,
            .instance_count = count,
            .first_index = 0,
            .base_vertex = 0,
            .first_instance = 0,
        });
    }
};

// ===========================================================================
// CPU model/mesh library — MOVED from drawing.zig's `models` namespace
// (GL-retirement P5).  Mesh generators, collision/bounds/raycast math,
// model + animation loading, CPU pose evaluation.  The GL halves of that
// namespace (uploadMesh, the rlgl draw paths, GL material/skinned-shader
// wiring) died with the backend; `updateModelAnimation`/`Blend` keep the
// CPU pose computation the future wgpu GPU-skinning variant will consume.
// ===========================================================================

const models_types = @import("types.zig");
const allocator_mod = @import("runtime.zig").allocator;

// ---- Default material (CPU port, GL-retirement P5) -----------------------
const Material = models_types.Material;

const MaterialMap = models_types.MaterialMap;

pub const max_material_maps: usize = 12;

/// Construct a default Material: heap-allocated `maps` array, identity
/// colors.  The GL build also wired rlgl's built-in shader + 1x1 white
/// texture ids; on the wgpu path materials are CPU descriptors and the
/// renderer resolves textures/pipelines itself.  Free with
/// `unloadMaterial(gpa, mat)` using the same allocator.
pub fn loadMaterialDefault(
    gpa: Allocator,
) Allocator.Error!Material {
    var mat: Material = std.mem.zeroes(Material);
    const maps: []MaterialMap = try gpa.alloc(MaterialMap, max_material_maps);
    errdefer gpa.free(maps);
    @memset(maps, std.mem.zeroes(MaterialMap));
    mat.maps = maps.ptr;
    // MATERIAL_MAP_DIFFUSE = 0, MATERIAL_MAP_SPECULAR = 1.
    mat.maps[0].color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    mat.maps[1].color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    return mat;
}

/// Free a Material's CPU-side resources: the `maps` array.  (The GL build
/// also unloaded the shader + per-map GPU textures; those ids don't exist
/// on the wgpu path.)
pub fn unloadMaterial(
    gpa: Allocator,
    material: Material,
) void {
    if (material.maps != null) {
        allocator_mod.freeMany(gpa, material.maps, max_material_maps);
    }
}

const errors = @import("errors.zig");

const z = struct {
    pub const Ray = zm.Ray;
    pub const RayCollision = zm.RayCollision;
    pub const BoundingBox = types.BoundingBox;
    pub const Mesh = types.Mesh;
    pub const Material = types.Material;
    pub const MaterialMap = types.MaterialMap;
    pub const MaterialMapIndex = types.MaterialMapIndex;
    pub const Model = types.Model;
    pub const ModelAnimation = types.ModelAnimation;
    pub const Shader = types.Shader;
    pub const Image = types.Image;
    pub const Texture = types.Texture;
    pub const Rectangle = types.Rectangle;
};

inline fn v3ToZm(v: Vec) Vec {
    return v; // Vec IS Vec post-Z4 wave 2
}

inline fn v3FromZm(v: Vec) Vec {
    return v;
}

/// Vector sum `a + b`.
inline fn v3Add(a: Vec, b: Vec) Vec {
    return v3FromZm(v3ToZm(a) + v3ToZm(b));
}

/// Vector difference `a - b`.
inline fn v3Sub(a: Vec, b: Vec) Vec {
    return v3FromZm(v3ToZm(a) - v3ToZm(b));
}

/// Scalar multiply `v * s` (`@splat` broadcast).
inline fn v3Scale(v: Vec, s: f32) Vec {
    return v3FromZm(v3ToZm(v) * @as(Vec, @splat(s)));
}

/// Negate a vector.
inline fn v3Negate(v: Vec) Vec {
    return -v;
}

/// The zero vector.
inline fn v3Zero() Vec {
    return vec(0, 0, 0);
}

/// Normalize a 3-vector.
inline fn v3Normalize(v: Vec) Vec {
    // safeNormalize3 (not normalize3): callers like getRayCollisionSphere can
    // pass a zero vector on no-hit paths; the assert in normalize3 would fire.
    // Fallback to +Y for a degenerate normal.
    return v3FromZm(safeNormalize3(v3ToZm(v), vec(0, 1, 0)));
}

/// Cross product `a × b`.
inline fn v3Cross(a: Vec, b: Vec) Vec {
    return v3FromZm(cross(v3ToZm(a), v3ToZm(b)));
}

/// Dot product `a · b`.
inline fn v3Dot(a: Vec, b: Vec) f32 {
    return dot3(v3ToZm(a), v3ToZm(b));
}

/// Vector length.
inline fn v3Length(v: Vec) f32 {
    return length3(v3ToZm(v));
}

/// Squared distance between two points (cheaper than the distance
/// itself - no sqrt - for comparisons).
inline fn v3DistanceSqr(a: Vec, b: Vec) f32 {
    return lengthSq3(v3ToZm(a) - v3ToZm(b));
}

/// A unit vector perpendicular to `v`.
inline fn v3Perpendicular(v: Vec) Vec {
    return v3FromZm(perpendicular3(v3ToZm(v)));
}

/// Rotate a vector around an axis (need not be normalized) by an
/// angle in radians.
inline fn v3RotateByAxisAngle(
    v: Vec,
    axis: Vec,
    angle: f32,
) Vec {
    return v3FromZm(rotateByAxisAngle3(v3ToZm(v), v3ToZm(axis), angle));
}

const Matrix = Mat;

/// Transform a point by a matrix (column-vector convention, w = 1).
inline fn v3Transform(v: Vec, m: Matrix) Vec {
    return v3FromZm(mulMatVec(m, pointFromArr3(v)));
}

/// Spherical-linear interpolation between two quaternions.
inline fn quatSlerp(
    a: Quat,
    b: Quat,
    t: f32,
) Quat {
    return slerp(a, b, t);
}

/// Linear interpolation between two vectors.
inline fn v3Lerp(
    a: Vec,
    b: Vec,
    t: f32,
) Vec {
    return v3FromZm(lerp(v3ToZm(a), v3ToZm(b), t));
}

/// Componentwise division `a / b`.
inline fn v3Divide(a: Vec, b: Vec) Vec {
    return v3FromZm(v3ToZm(a) / v3ToZm(b));
}

/// Helper: emit the three edges of a triangle as six vertices
/// (RL_LINES expects vertex pairs).
inline fn emitTriangleEdges(
    gl: anytype,
    verts: [*c]const f32,
    ia: usize,
    ib: usize,
    ic: usize,
) void {
    const ax: f32 = verts[ia * 3 + 0];
    const ay: f32 = verts[ia * 3 + 1];
    const az: f32 = verts[ia * 3 + 2];
    const bx: f32 = verts[ib * 3 + 0];
    const by: f32 = verts[ib * 3 + 1];
    const bz: f32 = verts[ib * 3 + 2];
    const cx: f32 = verts[ic * 3 + 0];
    const cy: f32 = verts[ic * 3 + 1];
    const cz: f32 = verts[ic * 3 + 2];
    // Edge A→B
    gl.vertex3f(ax, ay, az);
    gl.vertex3f(bx, by, bz);
    // Edge B→C
    gl.vertex3f(bx, by, bz);
    gl.vertex3f(cx, cy, cz);
    // Edge C→A
    gl.vertex3f(cx, cy, cz);
    gl.vertex3f(ax, ay, az);
}

inline fn sphereVert(phi: f32, theta: f32, r: f32) Vec {
    return vec(r * @sin(phi) * @cos(theta), r * @cos(phi), r * @sin(phi) * @sin(theta));
}

inline fn writeFlat(
    v: []f32,
    n: []f32,
    t: []f32,
    slot: usize,
    p: Vec,
    r: f32,
    u: f32,
    vt: f32,
) void {
    v[slot * 3 + 0] = p[0];
    v[slot * 3 + 1] = p[1];
    v[slot * 3 + 2] = p[2];
    n[slot * 3 + 0] = p[0] / r;
    n[slot * 3 + 1] = p[1] / r;
    n[slot * 3 + 2] = p[2] / r;
    t[slot * 2 + 0] = u;
    t[slot * 2 + 1] = vt;
}

inline fn writeXYZ(
    arr: []f32,
    slot: usize,
    p: Vec,
) void {
    arr[slot * 3 + 0] = p[0];
    arr[slot * 3 + 1] = p[1];
    arr[slot * 3 + 2] = p[2];
}

inline fn writeUV(
    arr: []f32,
    slot: usize,
    u: f32,
    v: f32,
) void {
    arr[slot * 2 + 0] = u;
    arr[slot * 2 + 1] = v;
}

inline fn torusPoint(R: f32, r: f32, u: f32, vAng: f32) Vec {
    return vec((R + r * @cos(vAng)) * @cos(u), r * @sin(vAng), (R + r * @cos(vAng)) * @sin(u));
}

inline fn torusNormal(u: f32, vAng: f32) Vec {
    return vec(@cos(vAng) * @cos(u), @sin(vAng), @cos(vAng) * @sin(u));
}

const KnotFrame = struct { c: Vec, n: Vec, b: Vec };

inline fn ringVert(
    frame: KnotFrame,
    r: f32,
    ang: f32,
) Vec {
    const ca: f32 = @cos(ang);
    const sa: f32 = @sin(ang);
    return vec(
        frame.c[0] + r * (ca * frame.n[0] + sa * frame.b[0]),
        frame.c[1] + r * (ca * frame.n[1] + sa * frame.b[1]),
        frame.c[2] + r * (ca * frame.n[2] + sa * frame.b[2]),
    );
}

inline fn ringNorm(frame: KnotFrame, ang: f32) Vec {
    const ca: f32 = @cos(ang);
    const sa: f32 = @sin(ang);
    return vec(
        ca * frame.n[0] + sa * frame.b[0],
        ca * frame.n[1] + sa * frame.b[1],
        ca * frame.n[2] + sa * frame.b[2],
    );
}

inline fn vec3Cross(a: Vec, b: Vec) Vec {
    return vec(a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]);
}

inline fn vec3Normalize(v: Vec) Vec {
    const len_sq: f32 = v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
    if (len_sq <= 0) {
        return v;
    }
    const inv_len: f32 = 1.0 / @sqrt(len_sq);
    return vec(v[0] * inv_len, v[1] * inv_len, v[2] * inv_len);
}

const libc = @import("runtime.zig").libc;
const Ray = zm.Ray;
const RayCollision = zm.RayCollision;
const BoundingBox = models_types.BoundingBox;
const Mesh = models_types.Mesh;
const Image = models_types.Image;
const Model = models_types.Model;
const MaterialMapIndex = models_types.MaterialMapIndex;
const ModelAnimation = models_types.ModelAnimation;
const Texture = models_types.Texture;

const max_mesh_vertex_buffers: usize = 9; // matches raylib's #define

pub const FlatMeshArrays = struct {
    verts: []f32,
    norms: []f32,
    texs: []f32,
};

fn trefoilFrame(tp: f32, scale: f32) KnotFrame {
    // Standard trefoil parameterization.  Center curve:
    //   x = sin(t) + 2*sin(2t)
    //   y = cos(t) - 2*cos(2t)
    //   z = -sin(3t)
    // Tangent is the derivative; we build a perpendicular frame from it.
    const sx: f32 = @sin(tp);
    const cx: f32 = @cos(tp);
    const s2: f32 = @sin(2.0 * tp);
    const c2: f32 = @cos(2.0 * tp);
    const s3: f32 = @sin(3.0 * tp);
    const c3: f32 = @cos(3.0 * tp);

    const center: Vec = vec(scale * (sx + 2.0 * s2), scale * (cx - 2.0 * c2), scale * -s3);
    const tangent_raw: Vec = vec(cx + 4.0 * c2, -sx + 4.0 * s2, -3.0 * c3);
    const tangent: Vec = vec3Normalize(tangent_raw);
    // Pick an arbitrary up to construct a perpendicular frame.
    const up: Vec = if (@abs(tangent[1]) < 0.9) vec(0, 1, 0) else vec(1, 0, 0);
    const binormal: Vec = vec3Normalize(vec3Cross(tangent, up));
    const normal: Vec = vec3Cross(binormal, tangent);
    return .{ .c = center, .n = normal, .b = binormal };
}

const eps: f32 = 1e-5;

/// Subdivided plane in the XZ plane. `res_x` × `res_z` give the
/// face-grid resolution (cells), the vertex grid is one larger in each
/// dimension. Vertices are shared between adjacent quads (indexed mesh).
pub fn genMeshPlane(
    gpa: Allocator,
    width: f32,
    length: f32,
    res_x: i32,
    res_z: i32,
) Allocator.Error!Mesh {
    var mesh: Mesh = std.mem.zeroes(Mesh);
    if (res_x < 1 or res_z < 1) {
        return mesh;
    }

    // raylib increments these once before use; the literal grid is
    // (res_x + 1) × (res_z + 1) vertices for res_x × res_z faces.
    const rx: usize = @intCast(res_x + 1);
    const rz: usize = @intCast(res_z + 1);
    const vertex_count: usize = rx * rz;
    const num_faces: usize = (rx - 1) * (rz - 1);
    const tri_count: usize = num_faces * 2;

    const verts: []f32 = try gpa.alloc(f32, vertex_count * 3);
    errdefer gpa.free(verts);
    const tex: []f32 = try gpa.alloc(f32, vertex_count * 2);
    errdefer gpa.free(tex);
    const norm: []f32 = try gpa.alloc(f32, vertex_count * 3);
    errdefer gpa.free(norm);
    const idx: []u16 = try gpa.alloc(u16, tri_count * 3);
    errdefer gpa.free(idx);

    const rxf: f32 = float(rx - 1);
    const rzf: f32 = float(rz - 1);
    var zi: usize = 0;
    while (zi < rz) : (zi += 1) {
        const z_pos = (float(zi) / rzf - 0.5) * length;
        for (0..rx) |x| {
            const x_pos = (float(x) / rxf - 0.5) * width;
            const v: usize = x + zi * rx;
            verts[v * 3 + 0] = x_pos;
            verts[v * 3 + 1] = 0;
            verts[v * 3 + 2] = z_pos;
            tex[v * 2 + 0] = float(x) / rxf;
            tex[v * 2 + 1] = float(zi) / rzf;
            norm[v * 3 + 0] = 0;
            norm[v * 3 + 1] = 1;
            norm[v * 3 + 2] = 0;
        }
    }

    // Two triangles per face, winding so +Y faces upward (CCW from above).
    var t: usize = 0;
    var face: usize = 0;
    while (face < num_faces) : (face += 1) {
        // Lower-left vertex of this face. We add `face / (rx-1)` to skip
        // the right edge of each row.
        const ll = face + face / (rx - 1);
        idx[t + 0] = @intCast(ll + rx);
        idx[t + 1] = @intCast(ll + 1);
        idx[t + 2] = @intCast(ll);
        idx[t + 3] = @intCast(ll + rx);
        idx[t + 4] = @intCast(ll + rx + 1);
        idx[t + 5] = @intCast(ll + 1);
        t += 6;
    }

    mesh.vertexCount = @intCast(vertex_count);
    mesh.triangleCount = @intCast(tri_count);
    mesh.vertices = verts.ptr;
    mesh.texcoords = tex.ptr;
    mesh.normals = norm.ptr;
    mesh.indices = idx.ptr;

    try uploadMesh(gpa, &mesh, false);
    return mesh;
}

/// Get ray-sphere intersection. Returns hit=true with distance/point/normal
/// filled when the ray hits; otherwise hit=false.
/// raylib's `GetScreenToWorldRayEx`: turn a screen-space point (pixels,
/// top-left origin) into a world-space picking ray for `camera`.
/// Unprojects the point on the near and far planes through the inverse
/// view-projection and takes the direction between them.  Perspective
/// only (projection 0) — the orthographic branch can join when an
/// example needs it.
pub fn getScreenToWorldRay(
    position: Vec2,
    camera: zm.Camera3D,
    width: f32,
    height: f32,
) Ray {
    // Screen -> NDC (y flips; WebGPU clip is y-up).
    const ndc_x: f32 = (2.0 * position[0]) / @max(width, 1.0) - 1.0;
    const ndc_y: f32 = 1.0 - (2.0 * position[1]) / @max(height, 1.0);

    const fovy_rad: f32 = camera.fovy_deg * (pi / 180.0);
    const proj: Mat = perspectiveFovRh(fovy_rad, width / @max(height, 1.0), 0.01, 1000.0);
    const view: Mat = lookAtRh(camera.position, camera.target, camera.up);
    const inv_vp: Mat = inverse(mulMat(proj, view));

    // Unproject near (z=0 in WebGPU's [0,1] clip) and far (z=1).
    const near_h: Vec = mulMatVec(inv_vp, .{ ndc_x, ndc_y, 0.0, 1.0 });
    const far_h: Vec = mulMatVec(inv_vp, .{ ndc_x, ndc_y, 1.0, 1.0 });
    const near_p: Vec = near_h / @as(Vec, @splat(@max(near_h[3], 1.0e-9)));
    const far_p: Vec = far_h / @as(Vec, @splat(@max(far_h[3], 1.0e-9)));

    var dir: Vec = far_p - near_p;
    dir[3] = 0;
    return .{ .position = camera.position, .direction = normalize4(dir) };
}

pub fn getRayCollisionSphere(
    ray: Ray,
    center: Vec,
    radius: f32,
) RayCollision {
    var collision: RayCollision = .{
        .hit = false,
        .distance = 0,
        .point = vec(0, 0, 0),
        .normal = vec(0, 0, 0),
    };
    const ray_to_sphere: Vec = vec(
        center[0] - ray.position[0],
        center[1] - ray.position[1],
        center[2] - ray.position[2],
    );
    const vector: f32 = v3Dot(ray_to_sphere, ray.direction);
    const dist: f32 = @sqrt(
        ray_to_sphere[0] * ray_to_sphere[0] +
            ray_to_sphere[1] * ray_to_sphere[1] +
            ray_to_sphere[2] * ray_to_sphere[2],
    );
    const d: f32 = radius * radius - (dist * dist - vector * vector);
    collision.hit = d >= 0.0;
    if (dist < radius) {
        // Ray origin inside sphere - flip the hit point to the far intersection.
        collision.distance = vector + @sqrt(d);
        collision.point = v3Add(ray.position, v3Scale(ray.direction, collision.distance));
        const diff: Vec = vec(
            collision.point[0] - center[0],
            collision.point[1] - center[1],
            collision.point[2] - center[2],
        );
        collision.normal = v3Negate(v3Normalize(diff));
    } else {
        collision.distance = vector - @sqrt(d);
        collision.point = v3Add(ray.position, v3Scale(ray.direction, collision.distance));
        const diff: Vec = vec(
            collision.point[0] - center[0],
            collision.point[1] - center[1],
            collision.point[2] - center[2],
        );
        collision.normal = v3Normalize(diff);
    }
    return collision;
}

/// Get ray-AABB (axis-aligned bounding box) intersection.
pub fn getRayCollisionBox(ray_in: Ray, box: BoundingBox) RayCollision {
    var ray: Ray = ray_in;
    var collision: RayCollision = .{
        .hit = false,
        .distance = 0,
        .point = vec(0, 0, 0),
        .normal = vec(0, 0, 0),
    };
    const inside: bool = ray.position[0] > box.min[0] and ray.position[0] < box.max[0] and
        ray.position[1] > box.min[1] and ray.position[1] < box.max[1] and
        ray.position[2] > box.min[2] and ray.position[2] < box.max[2];
    if (inside) {
        ray.direction = v3Negate(ray.direction);
    }

    const inv_x: f32 = 1.0 / ray.direction[0];
    const inv_y: f32 = 1.0 / ray.direction[1];
    const inv_z: f32 = 1.0 / ray.direction[2];
    const t0: f32 = (box.min[0] - ray.position[0]) * inv_x;
    const t1: f32 = (box.max[0] - ray.position[0]) * inv_x;
    const t2: f32 = (box.min[1] - ray.position[1]) * inv_y;
    const t3: f32 = (box.max[1] - ray.position[1]) * inv_y;
    const t4: f32 = (box.min[2] - ray.position[2]) * inv_z;
    const t5: f32 = (box.max[2] - ray.position[2]) * inv_z;
    const t_near: f32 = @max(@max(@min(t0, t1), @min(t2, t3)), @min(t4, t5));
    const t_far: f32 = @min(@min(@max(t0, t1), @max(t2, t3)), @max(t4, t5));

    collision.hit = !(t_far < 0 or t_near > t_far);
    collision.distance = t_near;
    collision.point = v3Add(ray.position, v3Scale(ray.direction, collision.distance));

    // Normal = sign of (point - boxCenter) projected to the cube's longest axis.
    var normal: Vec = v3Lerp(box.min, box.max, 0.5);
    normal = vec(collision.point[0] - normal[0], collision.point[1] - normal[1], collision.point[2] - normal[2]);
    normal = v3Scale(normal, 2.01);
    normal = v3Divide(
        normal,
        vec(box.max[0] - box.min[0], box.max[1] - box.min[1], box.max[2] - box.min[2]),
    );
    // Truncate to integer to keep only the dominant axis.
    normal[0] = @floatFromInt(int(i32, normal[0]));
    normal[1] = @floatFromInt(int(i32, normal[1]));
    normal[2] = @floatFromInt(int(i32, normal[2]));
    collision.normal = v3Normalize(normal);

    if (inside) {
        collision.distance *= -1.0;
        collision.normal = v3Negate(collision.normal);
    }
    return collision;
}

/// Ray-triangle intersection (Möller-Trumbore). Triangle vertices in CCW order.
pub fn getRayCollisionTriangle(
    ray: Ray,
    p1: Vec,
    p2: Vec,
    p3: Vec,
) RayCollision {
    const EPS: f32 = 0.000001;
    var collision: RayCollision = .{
        .hit = false,
        .distance = 0,
        .point = vec(0, 0, 0),
        .normal = vec(0, 0, 0),
    };
    const edge1: Vec = vec(p2[0] - p1[0], p2[1] - p1[1], p2[2] - p1[2]);
    const edge2: Vec = vec(p3[0] - p1[0], p3[1] - p1[1], p3[2] - p1[2]);
    const p: Vec = v3Cross(ray.direction, edge2);
    const det: f32 = v3Dot(edge1, p);
    if (det > -EPS and det < EPS) {
        return collision;
    }
    const inv_det: f32 = 1.0 / det;
    const tv: Vec = vec(ray.position[0] - p1[0], ray.position[1] - p1[1], ray.position[2] - p1[2]);
    const u: f32 = v3Dot(tv, p) * inv_det;
    if (u < 0 or u > 1) {
        return collision;
    }
    const q: Vec = v3Cross(tv, edge1);
    const v: f32 = v3Dot(ray.direction, q) * inv_det;
    if (v < 0 or (u + v) > 1) {
        return collision;
    }
    const t: f32 = v3Dot(edge2, q) * inv_det;
    if (t > EPS) {
        collision.hit = true;
        collision.distance = t;
        collision.normal = v3Normalize(v3Cross(edge1, edge2));
        collision.point = v3Add(ray.position, v3Scale(ray.direction, t));
    }
    return collision;
}

/// Ray-quad intersection (CCW winding). Tries the two diagonal triangles
/// of the quad and returns whichever hits first.
pub fn getRayCollisionQuad(
    ray: Ray,
    p1: Vec,
    p2: Vec,
    p3: Vec,
    p4: Vec,
) RayCollision {
    var collision: RayCollision = getRayCollisionTriangle(ray, p1, p2, p4);
    if (!collision.hit) {
        collision = getRayCollisionTriangle(ray, p2, p3, p4);
    }
    return collision;
}

/// Ray-mesh intersection. Walks all triangles, returns the closest hit.
pub fn getRayCollisionMesh(
    ray: Ray,
    mesh: Mesh,
    transform: Matrix,
) RayCollision {
    var collision: RayCollision = .{
        .hit = false,
        .distance = 0,
        .point = vec(0, 0, 0),
        .normal = vec(0, 0, 0),
    };
    if (mesh.vertices == null) {
        return collision;
    }
    const tri_count: usize = @intCast(mesh.triangleCount);
    for (0..tri_count) |i| {
        var a: Vec = undefined;
        var b: Vec = undefined;
        var c: Vec = undefined;
        // mesh.vertices is interleaved float32 [x,y,z] tuples.
        if (mesh.indices != null) {
            const ia: usize = @intCast(mesh.indices[i * 3 + 0]);
            const ib: usize = @intCast(mesh.indices[i * 3 + 1]);
            const ic: usize = @intCast(mesh.indices[i * 3 + 2]);
            a = vec(mesh.vertices[ia * 3 + 0], mesh.vertices[ia * 3 + 1], mesh.vertices[ia * 3 + 2]);
            b = vec(mesh.vertices[ib * 3 + 0], mesh.vertices[ib * 3 + 1], mesh.vertices[ib * 3 + 2]);
            c = vec(mesh.vertices[ic * 3 + 0], mesh.vertices[ic * 3 + 1], mesh.vertices[ic * 3 + 2]);
        } else {
            a = vec(mesh.vertices[i * 9 + 0], mesh.vertices[i * 9 + 1], mesh.vertices[i * 9 + 2]);
            b = vec(mesh.vertices[i * 9 + 3], mesh.vertices[i * 9 + 4], mesh.vertices[i * 9 + 5]);
            c = vec(mesh.vertices[i * 9 + 6], mesh.vertices[i * 9 + 7], mesh.vertices[i * 9 + 8]);
        }
        a = v3Transform(a, transform);
        b = v3Transform(b, transform);
        c = v3Transform(c, transform);
        const tri: RayCollision = getRayCollisionTriangle(ray, a, b, c);
        if (tri.hit) {
            if (!collision.hit or collision.distance > tri.distance) {
                collision = tri;
            }
        }
    }
    return collision;
}

/// Get the AABB of a Mesh (walks all vertices).
pub fn getMeshBoundingBox(mesh: Mesh) BoundingBox {
    var minv: Vec = vec(0, 0, 0);
    var maxv: Vec = vec(0, 0, 0);
    if (mesh.vertices != null and mesh.vertexCount > 0) {
        minv = vec(mesh.vertices[0], mesh.vertices[1], mesh.vertices[2]);
        maxv = minv;
        var i: usize = 1;
        const n: usize = @intCast(mesh.vertexCount);
        while (i < n) : (i += 1) {
            const x: f32 = mesh.vertices[i * 3 + 0];
            const y: f32 = mesh.vertices[i * 3 + 1];
            const zc: f32 = mesh.vertices[i * 3 + 2];
            if (x < minv[0]) minv[0] = x;
            if (y < minv[1]) minv[1] = y;
            if (zc < minv[2]) minv[2] = zc;
            if (x > maxv[0]) maxv[0] = x;
            if (y > maxv[1]) maxv[1] = y;
            if (zc > maxv[2]) maxv[2] = zc;
        }
    }
    return .{ .min = minv, .max = maxv };
}

/// Animation matches a model when their bone counts agree. The
/// keyframe transforms themselves are then applied per-bone.
pub fn isModelAnimationValid(model: Model, anim: ModelAnimation) bool {
    return model.skeleton.boneCount == anim.boneCount;
}

/// Encode a `Mesh` as Wavefront OBJ text.  Caller owns the returned
/// memory (use `gpa.free(...)`).  Returns `error.OutOfMemory` on
/// allocation failure - previously this swallowed the error and
/// returned an empty slice that was indistinguishable from a
/// successful zero-byte output.
pub fn exportMeshAsObj(
    gpa: Allocator,
    mesh: z.Mesh,
    name: []const u8,
) Allocator.Error![]u8 {
    var buf: ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    // Header.
    try buf.print(gpa, "# Exported by zimr\n", .{});
    try buf.print(gpa, "o {s}\n", .{name});

    if (mesh.vertices == null or mesh.vertexCount == 0) {
        try buf.print(gpa, "# (empty mesh)\n", .{});
        return buf.toOwnedSlice(gpa);
    }

    const vc: usize = @intCast(mesh.vertexCount);

    // Positions
    for (0..vc) |i| {
        const x: f32 = mesh.vertices[i * 3 + 0];
        const y: f32 = mesh.vertices[i * 3 + 1];
        const zv: f32 = mesh.vertices[i * 3 + 2];
        try buf.print(gpa, "v {d} {d} {d}\n", .{ x, y, zv });
    }

    // Texcoords (optional)
    const has_tex: bool = mesh.texcoords != null;
    if (has_tex) {
        for (0..vc) |i| {
            const u: f32 = mesh.texcoords[i * 2 + 0];
            const v: f32 = mesh.texcoords[i * 2 + 1];
            try buf.print(gpa, "vt {d} {d}\n", .{ u, v });
        }
    }

    // Normals (optional)
    const has_norm: bool = mesh.normals != null;
    if (has_norm) {
        for (0..vc) |i| {
            const x: f32 = mesh.normals[i * 3 + 0];
            const y: f32 = mesh.normals[i * 3 + 1];
            const zv: f32 = mesh.normals[i * 3 + 2];
            try buf.print(gpa, "vn {d} {d} {d}\n", .{ x, y, zv });
        }
    }

    // Faces.  OBJ indices are 1-based.  We support indexed and
    // non-indexed meshes.
    const has_indices: bool = mesh.indices != null;
    const tri_count: usize = if (has_indices)
        @intCast(@divFloor(mesh.triangleCount, 1))
    else
        @intCast(@divFloor(vc, 3));

    for (0..tri_count) |t| {
        const idx0: usize = if (has_indices) @intCast(mesh.indices[t * 3 + 0]) else t * 3 + 0;
        const idx1: usize = if (has_indices) @intCast(mesh.indices[t * 3 + 1]) else t * 3 + 1;
        const idx2: usize = if (has_indices) @intCast(mesh.indices[t * 3 + 2]) else t * 3 + 2;

        // OBJ is 1-indexed.
        const a: usize = idx0 + 1;
        const b: usize = idx1 + 1;
        const c: usize = idx2 + 1;

        // Format the face line based on which attribute slots are present.
        if (has_tex and has_norm) {
            try buf.print(gpa, "f {d}/{d}/{d} {d}/{d}/{d} {d}/{d}/{d}\n", .{ a, a, a, b, b, b, c, c, c });
        } else if (has_norm) {
            try buf.print(gpa, "f {d}//{d} {d}//{d} {d}//{d}\n", .{ a, a, b, b, c, c });
        } else if (has_tex) {
            try buf.print(gpa, "f {d}/{d} {d}/{d} {d}/{d}\n", .{ a, a, b, b, c, c });
        } else {
            try buf.print(gpa, "f {d} {d} {d}\n", .{ a, b, c });
        }
    }

    return buf.toOwnedSlice(gpa);
}

/// Compute the AABB enclosing every mesh in the model, then transform
/// it by `model.transform`. NOTE: the result only stays correct under
/// translation + uniform scale; for rotations the axis-aligned box is
/// no longer tight (raylib has the same caveat).
pub fn getModelBoundingBox(model: Model) z.BoundingBox {
    var bounds: z.BoundingBox = .{ .min = vec(0, 0, 0), .max = vec(0, 0, 0) };
    if (model.meshCount <= 0) {
        return bounds;
    }

    bounds = getMeshBoundingBox(model.meshes[0]);
    var i: usize = 1;
    const n: usize = @intCast(model.meshCount);
    while (i < n) : (i += 1) {
        const t: BoundingBox = getMeshBoundingBox(model.meshes[i]);
        bounds.min[0] = @min(bounds.min[0], t.min[0]);
        bounds.min[1] = @min(bounds.min[1], t.min[1]);
        bounds.min[2] = @min(bounds.min[2], t.min[2]);
        bounds.max[0] = @max(bounds.max[0], t.max[0]);
        bounds.max[1] = @max(bounds.max[1], t.max[1]);
        bounds.max[2] = @max(bounds.max[2], t.max[2]);
    }

    bounds.min = v3Transform(bounds.min, model.transform);
    bounds.max = v3Transform(bounds.max, model.transform);
    return bounds;
}

/// AABB of a sphere centered at `center` with radius `radius`.
pub fn getSphereBoundingBox(center: Vec, radius: f32) BoundingBox {
    const r: f32 = @abs(radius);
    return .{
        .min = vec(center[0] - r, center[1] - r, center[2] - r),
        .max = vec(center[0] + r, center[1] + r, center[2] + r),
    };
}

/// AABB of an axis-aligned cube centered at `center` with full
/// dimensions `(w, h, d)`.
pub fn getCubeBoundingBox(
    center: Vec,
    w: f32,
    h: f32,
    d: f32,
) BoundingBox {
    const hw: f32 = @abs(w) * 0.5;
    const hh: f32 = @abs(h) * 0.5;
    const hd: f32 = @abs(d) * 0.5;
    return .{
        .min = vec(center[0] - hw, center[1] - hh, center[2] - hd),
        .max = vec(center[0] + hw, center[1] + hh, center[2] + hd),
    };
}

/// AABB of a capsule with hemispherical caps at `start` and `end`,
/// each of radius `radius`.  This is the union of two caps' AABBs.
pub fn getCapsuleBoundingBox(
    start: Vec,
    end: Vec,
    radius: f32,
) BoundingBox {
    const r: f32 = @abs(radius);
    return .{
        .min = vec(@min(start[0], end[0]) - r, @min(start[1], end[1]) - r, @min(start[2], end[2]) - r),
        .max = vec(@max(start[0], end[0]) + r, @max(start[1], end[1]) + r, @max(start[2], end[2]) + r),
    };
}

/// AABB of a cylinder with axis-aligned (Y-up) center axis from
/// `(position, position[1])` to `(position, position[1] + height)` and
/// radius `radius_top` at the top, `radius_bottom` at the bottom.
/// Matches the orientation that `drawCylinder` uses.
pub fn getCylinderBoundingBox(
    position: Vec,
    radius_top: f32,
    radius_bottom: f32,
    height: f32,
) BoundingBox {
    const r: f32 = @abs(@max(radius_top, radius_bottom));
    const h: f32 = @abs(height);
    return .{
        .min = vec(position[0] - r, position[1], position[2] - r),
        .max = vec(position[0] + r, position[1] + h, position[2] + r),
    };
}

/// Bind a texture to one of the material's map slots
/// (MATERIAL_MAP_DIFFUSE, MATERIAL_MAP_NORMAL, etc.).
pub fn setMaterialTexture(
    material: *Material,
    map_type: i32,
    texture: Texture,
) void {
    if (map_type < 0 or map_type >= max_material_maps) {
        return;
    }
    material.maps[@intCast(map_type)].texture = texture;
}

/// Bind a material slot to a specific mesh on a model.
pub fn setModelMeshMaterial(
    model: *Model,
    mesh_id: i32,
    material_id: i32,
) void {
    if (mesh_id < 0 or mesh_id >= model.meshCount) {
        return;
    }
    if (material_id < 0 or material_id >= model.materialCount) {
        return;
    }
    model.meshMaterial[@intCast(mesh_id)] = material_id;
}

/// Sphere-vs-sphere overlap test. Uses squared distances to avoid sqrt.
pub fn checkCollisionSpheres(
    c1: Vec,
    r1: f32,
    c2: Vec,
    r2: f32,
) bool {
    const sum: f32 = r1 + r2;
    return v3DistanceSqr(c1, c2) <= sum * sum;
}

/// AABB-vs-AABB overlap test on three axes.
pub fn checkCollisionBoxes(box1: z.BoundingBox, box2: z.BoundingBox) bool {
    if (box1.max[0] < box2.min[0] or box1.min[0] > box2.max[0]) {
        return false;
    }
    if (box1.max[1] < box2.min[1] or box1.min[1] > box2.max[1]) {
        return false;
    }
    if (box1.max[2] < box2.min[2] or box1.min[2] > box2.max[2]) {
        return false;
    }
    return true;
}

/// AABB-vs-sphere overlap test. Compute the closest point on the box
/// to the sphere center; collision iff that point is within radius.
pub fn checkCollisionBoxSphere(
    box: z.BoundingBox,
    center: Vec,
    radius: f32,
) bool {
    const closest: Vec = vec(
        clamp(center[0], box.min[0], box.max[0]),
        clamp(center[1], box.min[1], box.max[1]),
        clamp(center[2], box.min[2], box.max[2]),
    );
    return v3DistanceSqr(center, closest) <= radius * radius;
}

/// Convex polygon ("fan" of triangles meeting at center). The mesh is
/// in the XZ plane with normals pointing +Y, so it can be drawn as a
/// floor disc. `sides < 3` returns an empty mesh.
pub fn genMeshPoly(
    gpa: Allocator,
    sides: i32,
    radius: f32,
) Allocator.Error!Mesh {
    var mesh: Mesh = std.mem.zeroes(Mesh);
    if (sides < 3) {
        return mesh;
    }

    const s: usize = @intCast(sides);
    const vertex_count: usize = s * 3; // each side = a centered triangle
    const verts: []f32 = try gpa.alloc(f32, vertex_count * 3);
    errdefer gpa.free(verts);
    const tex: []f32 = try gpa.alloc(f32, vertex_count * 2);
    errdefer gpa.free(tex);
    const norm: []f32 = try gpa.alloc(f32, vertex_count * 3);
    errdefer gpa.free(norm);

    const d_step: f32 = tau / float(sides);
    for (0..s) |i| {
        const d0 = float(i) * d_step;
        const d1 = (float(i) + 1.0) * d_step;
        // Triangle: center, then two perimeter points.
        const base: usize = i * 9;
        verts[base + 0] = 0;
        verts[base + 1] = 0;
        verts[base + 2] = 0;
        verts[base + 3] = @sin(d0) * radius;
        verts[base + 4] = 0;
        verts[base + 5] = @cos(d0) * radius;
        verts[base + 6] = @sin(d1) * radius;
        verts[base + 7] = 0;
        verts[base + 8] = @cos(d1) * radius;
    }

    // Normals are all +Y (up); texcoords are zero (raylib's choice).
    for (0..vertex_count) |k| {
        norm[k * 3 + 0] = 0;
        norm[k * 3 + 1] = 1;
        norm[k * 3 + 2] = 0;
        tex[k * 2 + 0] = 0;
        tex[k * 2 + 1] = 0;
    }

    mesh.vertexCount = @intCast(vertex_count);
    mesh.triangleCount = sides;
    mesh.vertices = verts.ptr;
    mesh.texcoords = tex.ptr;
    mesh.normals = norm.ptr;

    try uploadMesh(gpa, &mesh, false);
    return mesh;
}

/// Build zimr `Material` array from a parsed glTF document.  Each
/// glTF material becomes one zimr Material, in order.
/// For each material:
///   - `base_color_factor` → `maps[DIFFUSE].color` (clamped to 0-255)
///   - `base_color_texture.source` → resolve image bytes (from
///     `bufferView` slice in BIN chunk, or `uri` data: URI), decode
///     PNG via `codecs.png.decode`, upload via `loadTextureFromImage`,
///     install at `maps[DIFFUSE].texture`
/// Returns a heap-allocated `[]Material`.  Caller must free each
/// material with `unloadMaterial(gpa, mat)` and the slice with
/// `gpa.free(slice)`.  Empty materials list (or all-default fields)
/// returns a single default-material slice so the caller never has
/// a zero-material model.
fn materialsFromGltf(
    gpa: Allocator,
    data: anytype, // codecs.gltf.Data
) errors.LoadError![]Material {
    const n: usize = if (data.materials.len > 0) data.materials.len else 1;
    const out: []Material = gpa.alloc(Material, n) catch return errors.LoadError.OutOfMemory;
    errdefer gpa.free(out);

    // Track how many slots we've successfully built so the
    // errdefer can unwind the right ones.
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |m| unloadMaterial(gpa, m);
    }

    if (data.materials.len == 0) {
        out[0] = loadMaterialDefault(gpa) catch return errors.LoadError.OutOfMemory;
        built = 1;
        return out;
    }

    for (data.materials, 0..) |gmat, i| {
        // GL-retirement P5: per-map GPU texture upload (loadGltfTexture)
        // died with the GL backend — on the wgpu path the renderer binds
        // textures itself (see gltf_textured).  Color factors below
        // are the CPU-side material content.
        var mat: Material = loadMaterialDefault(gpa) catch return errors.LoadError.OutOfMemory;

        // baseColorFactor → DIFFUSE colour tint.  Clamp to 0-255.
        const bcf: Vec = gmat.base_color_factor;
        mat.maps[0].color = .{
            .r = @trunc(clamp(bcf[0] * 255.0, 0.0, 255.0)),
            .g = @trunc(clamp(bcf[1] * 255.0, 0.0, 255.0)),
            .b = @trunc(clamp(bcf[2] * 255.0, 0.0, 255.0)),
            .a = @trunc(clamp(bcf[3] * 255.0, 0.0, 255.0)),
        };

        // baseColorTexture → DIFFUSE texture.  Resolve through:
        //   material → texture index → image index → bytes
        // The whole resolve+decode+upload chain lives in a labeled
        // block so any decode/upload failure can early-exit via
        // `break :tex_block` and leave the material with just its
        // baseColorFactor (no texture) rather than aborting the
        // entire model load.
        // ---- PBR texture loading (all five maps) ------------------
        //
        // glTF's PBR material model has up to five textures per
        // material:
        //   1. baseColorTexture        → MaterialMapIndex.albedo
        //   2. metallicRoughnessTexture → MaterialMapIndex.metalness
        //                                 (B = metalness, G = roughness;
        //                                  shader samples once and uses
        //                                  both channels)
        //   3. normalTexture           → MaterialMapIndex.normal
        //   4. occlusionTexture        → MaterialMapIndex.occlusion
        //   5. emissiveTexture         → MaterialMapIndex.emission
        //
        // `loadGltfTexture` returns null on any failure (missing
        // index, decode failure, upload failure) — the material
        // just won't have that texture, and the shader falls back
        // to using the scalar factor alone for that slot.

        // Scalar factors — multipliers for the corresponding
        // textures (or used directly when no texture is bound).
        mat.maps[@intFromEnum(MaterialMapIndex.metalness)].value = gmat.metallic_factor;
        mat.maps[@intFromEnum(MaterialMapIndex.roughness)].value = gmat.roughness_factor;
        // Emissive factor stored as the emission map's `color`
        // tint: per glTF, emissive_factor is RGB in linear space,
        // clamped to [0, 1] then scaled to [0, 255] for our Color.
        const ef: Vec = gmat.emissive_factor;
        mat.maps[@intFromEnum(MaterialMapIndex.emission)].color = .{
            .r = @trunc(clamp(ef[0] * 255.0, 0.0, 255.0)),
            .g = @trunc(clamp(ef[1] * 255.0, 0.0, 255.0)),
            .b = @trunc(clamp(ef[2] * 255.0, 0.0, 255.0)),
            .a = 255,
        };

        _ = i; // currently unused; reserved for per-mat name logging

        out[built] = mat;
        built += 1;
    }

    return out;
}

/// For each glTF mesh-primitive, look up its `material` index and
/// return a flat `[]i32` of the same length as `model.meshes`.
/// Defaults to 0 (the default material slot) when a primitive has
/// no material reference.
fn meshMaterialIndicesFromGltf(
    gpa: Allocator,
    data: anytype,
) errors.LoadError![]i32 {
    var total: usize = 0;
    for (data.meshes) |m| {
        total += m.primitives.len;
    }
    if (total == 0) {
        return errors.LoadError.GltfParseFailed;
    }

    const out: []i32 = gpa.alloc(i32, total) catch return errors.LoadError.OutOfMemory;
    var i: usize = 0;
    for (data.meshes) |m| {
        for (m.primitives) |p| {
            out[i] = @intCast(p.material orelse 0);
            i += 1;
        }
    }
    return out;
}

/// Free GPU + CPU memory for a Mesh. Safe to call even if some buffers
/// are null (raylib's malloc/free pattern allows that).
pub fn unloadMesh(
    gpa: Allocator,
    mesh: Mesh,
) void {
    if (mesh.vboId != null) {
        allocator_mod.freeMany(gpa, mesh.vboId, max_mesh_vertex_buffers);
    }

    const vc: usize = @intCast(mesh.vertexCount);
    const tc: usize = @intCast(mesh.triangleCount);

    // CPU-side per-vertex arrays - lengths derived from vertexCount.
    if (mesh.vertices != null) {
        allocator_mod.freeMany(gpa, mesh.vertices, vc * 3);
    }
    if (mesh.texcoords != null) {
        allocator_mod.freeMany(gpa, mesh.texcoords, vc * 2);
    }
    if (mesh.normals != null) {
        allocator_mod.freeMany(gpa, mesh.normals, vc * 3);
    }
    if (mesh.colors != null) {
        allocator_mod.freeMany(gpa, mesh.colors, vc * 4);
    }
    if (mesh.tangents != null) {
        allocator_mod.freeMany(gpa, mesh.tangents, vc * 4);
    }
    if (mesh.texcoords2 != null) {
        allocator_mod.freeMany(gpa, mesh.texcoords2, vc * 2);
    }
    if (mesh.indices != null) {
        allocator_mod.freeMany(gpa, mesh.indices, tc * 3);
    }

    // Skinning data: 4 weights/indices per vertex.
    if (mesh.boneWeights != null) {
        allocator_mod.freeMany(gpa, mesh.boneWeights, vc * 4);
    }
    if (mesh.boneIndices != null) {
        allocator_mod.freeMany(gpa, mesh.boneIndices, vc * 4);
    }

    // Runtime CPU-side skinned vertex buffers (computed in
    // updateModelAnimation when GPU skinning is off).
    if (mesh.animVertices != null) {
        allocator_mod.freeMany(gpa, mesh.animVertices, vc * 3);
    }
    if (mesh.animNormals != null) {
        allocator_mod.freeMany(gpa, mesh.animNormals, vc * 3);
    }
}

/// Compute per-vertex tangent vectors from `mesh.vertices`,
/// `mesh.normals`, `mesh.texcoords`.  Required input for normal-
/// mapped shaders that read a tangent-space normal map and
/// reconstruct the world-space normal.
/// Allocates `mesh.tangents` as a flat array of `vertexCount × 4`
/// floats - three components for the tangent direction plus a
/// fourth "handedness" value (`+1.0` or `-1.0`) that disambiguates
/// the bitangent's sign.  If `mesh.tangents` is already populated
/// it's freed first to avoid a leak.
/// Algorithm: accumulate per-triangle (sdir, tdir) contributions
/// into temporary `tan1` / `tan2` arrays, then for each vertex
/// run Gram-Schmidt orthogonalization against the normal.  Skips
/// gracefully if `vertices`, `normals`, or `texcoords` are null,
/// returning without modification.
/// Note: this CPU-side computation only.  Uploading the new
/// tangents to the GPU as an additional vertex attribute is the
/// caller's job - re-call `uploadMesh` after if the mesh is being
/// rebuilt for use with a normal-mapped shader.  Future work will
/// add a paired `rlUpdateVertexBuffer` path to update an existing
/// VAO in place (mirrors raylib's tail-end logic).
pub fn genMeshTangents(
    gpa: Allocator,
    mesh: *Mesh,
) Allocator.Error!void {
    if (mesh.vertices == null or mesh.normals == null or mesh.texcoords == null) {
        return;
    }
    if (mesh.vertexCount <= 0) {
        return;
    }

    const vc: usize = @intCast(mesh.vertexCount);
    const tc: usize = @intCast(mesh.triangleCount);

    // Free any existing tangents before re-allocating - matches
    // raylib's "free + malloc" pattern for repeat callers.
    if (mesh.tangents != null) {
        const old: []f32 = @as([*]f32, @ptrCast(mesh.tangents))[0 .. vc * 4];
        gpa.free(old);
        mesh.tangents = null;
    }
    const tangents: []f32 = try gpa.alloc(f32, vc * 4);
    errdefer gpa.free(tangents);
    @memset(tangents, 0);

    // Temporary per-vertex sdir / tdir accumulators.  Both are
    // `Vec{0,0,0}` initially; we sum per-triangle contributions
    // into them.
    const tan1: []Vec = try gpa.alloc(Vec, vc);
    defer gpa.free(tan1);
    const tan2: []Vec = try gpa.alloc(Vec, vc);
    defer gpa.free(tan2);
    @memset(tan1, vec(0, 0, 0));
    @memset(tan2, vec(0, 0, 0));

    for (0..tc) |t| {
        // Resolve the three vertex indices for this triangle.
        const vi0: usize = if (mesh.indices != null) mesh.indices[t * 3 + 0] else t * 3 + 0;
        const vi1: usize = if (mesh.indices != null) mesh.indices[t * 3 + 1] else t * 3 + 1;
        const vi2: usize = if (mesh.indices != null) mesh.indices[t * 3 + 2] else t * 3 + 2;

        const v1: Vec = vec(mesh.vertices[vi0 * 3 + 0], mesh.vertices[vi0 * 3 + 1], mesh.vertices[vi0 * 3 + 2]);
        const v2: Vec = vec(mesh.vertices[vi1 * 3 + 0], mesh.vertices[vi1 * 3 + 1], mesh.vertices[vi1 * 3 + 2]);
        const v3: Vec = vec(mesh.vertices[vi2 * 3 + 0], mesh.vertices[vi2 * 3 + 1], mesh.vertices[vi2 * 3 + 2]);

        const uv1_x: f32 = mesh.texcoords[vi0 * 2 + 0];
        const uv1_y: f32 = mesh.texcoords[vi0 * 2 + 1];
        const uv2_x: f32 = mesh.texcoords[vi1 * 2 + 0];
        const uv2_y: f32 = mesh.texcoords[vi1 * 2 + 1];
        const uv3_x: f32 = mesh.texcoords[vi2 * 2 + 0];
        const uv3_y: f32 = mesh.texcoords[vi2 * 2 + 1];

        // Triangle edges in object space.
        const x1: f32 = v2[0] - v1[0];
        const y1: f32 = v2[1] - v1[1];
        const z1: f32 = v2[2] - v1[2];
        const x2: f32 = v3[0] - v1[0];
        const y2: f32 = v3[1] - v1[1];
        const z2: f32 = v3[2] - v1[2];

        // Texture-coordinate deltas.
        const s1: f32 = uv2_x - uv1_x;
        const tt1: f32 = uv2_y - uv1_y;
        const s2: f32 = uv3_x - uv1_x;
        const tt2: f32 = uv3_y - uv1_y;

        // Inverse of the UV-delta determinant.  Guard against the
        // degenerate case where two triangle UVs collapse onto a
        // line - produces div=0 which we treat as zero
        // contribution (the per-vertex Gram-Schmidt below will
        // synthesise a fallback tangent later).
        const div: f32 = s1 * tt2 - s2 * tt1;
        const r: f32 = if (@abs(div) < 0.0001) 0.0 else 1.0 / div;

        const sdir: Vec = vec((tt2 * x1 - tt1 * x2) * r, (tt2 * y1 - tt1 * y2) * r, (tt2 * z1 - tt1 * z2) * r);
        const tdir: Vec = vec((s1 * x2 - s2 * x1) * r, (s1 * y2 - s2 * y1) * r, (s1 * z2 - s2 * z1) * r);

        // Sum per-vertex.  All three vertices of the triangle
        // accumulate the same sdir/tdir - for shared vertices,
        // multiple triangles' contributions stack.
        tan1[vi0] = v3Add(tan1[vi0], sdir);
        tan1[vi1] = v3Add(tan1[vi1], sdir);
        tan1[vi2] = v3Add(tan1[vi2], sdir);
        tan2[vi0] = v3Add(tan2[vi0], tdir);
        tan2[vi1] = v3Add(tan2[vi1], tdir);
        tan2[vi2] = v3Add(tan2[vi2], tdir);
    }

    // Per-vertex Gram-Schmidt orthogonalisation against the normal,
    // then handedness from the cross-product test.
    for (0..vc) |i| {
        const normal: Vec = vec(mesh.normals[i * 3 + 0], mesh.normals[i * 3 + 1], mesh.normals[i * 3 + 2]);
        const tangent: Vec = tan1[i];

        // Degenerate case: this vertex's accumulated tangent is
        // zero (only happens when every triangle touching it had
        // collapsed UVs).  Synthesise something perpendicular to
        // the normal.
        const tangent_len: f32 = v3Length(tangent);
        if (tangent_len < 0.0001) {
            const fallback: Vec = if (@abs(normal[2]) > 0.707)
                vec(1.0, 0.0, 0.0)
            else
                v3Normalize(vec(-normal[1], normal[0], 0.0));
            tangents[i * 4 + 0] = fallback[0];
            tangents[i * 4 + 1] = fallback[1];
            tangents[i * 4 + 2] = fallback[2];
            tangents[i * 4 + 3] = 1.0;
            continue;
        }

        // Gram-Schmidt: T' = T - N * dot(N, T), then normalize.
        // This forces the tangent to lie in the tangent plane,
        // which the shader's TBN matrix construction expects.
        const dot_nt: f32 = v3Dot(normal, tangent);
        const orthog: Vec = v3Normalize(vec(
            tangent[0] - normal[0] * dot_nt,
            tangent[1] - normal[1] * dot_nt,
            tangent[2] - normal[2] * dot_nt,
        ));

        tangents[i * 4 + 0] = orthog[0];
        tangents[i * 4 + 1] = orthog[1];
        tangents[i * 4 + 2] = orthog[2];
        // Handedness: +1 / -1 depending on whether tan2's
        // contribution agrees with N × T.  Used by the shader to
        // reconstruct the bitangent without storing it explicitly.
        const cross_nt: Vec = v3Cross(normal, orthog);
        const handedness: f32 = if (v3Dot(cross_nt, tan2[i]) < 0.0) -1.0 else 1.0;
        tangents[i * 4 + 3] = handedness;
    }

    mesh.tangents = tangents.ptr;
}

pub fn loadModelFromMemory(
    gpa: Allocator,
    bytes: []const u8,
) errors.LoadError!Model {
    const codecs_mod = @import("codecs.zig");
    const dom = @import("web.zig").dom;
    var doc: codecs_mod.gltf.Data = codecs_mod.gltf.parse(gpa, bytes) catch |err| {
        var buf: [192]u8 = undefined;
        const msg: []const u8 = bufPrint(
            &buf,
            "[gltf] parse failed: {s} (input {d} bytes, first4='{c}{c}{c}{c}')",
            .{
                @errorName(err),
                bytes.len,
                if (bytes.len > 0) bytes[0] else '?',
                if (bytes.len > 1) bytes[1] else '?',
                if (bytes.len > 2) bytes[2] else '?',
                if (bytes.len > 3) bytes[3] else '?',
            },
        ) catch "[gltf] parse failed (fmt err)";
        dom.log(.err, msg);
        return errors.LoadError.GltfParseFailed;
    };
    defer doc.deinit();

    const meshes: []Mesh = codecs_mod.gltf.meshesFromGltf(gpa, doc) catch |err| {
        var buf: [192]u8 = undefined;
        const msg: []const u8 = bufPrint(
            &buf,
            "[gltf] meshesFromGltf failed: {s} (meshes={d}, accessors={d}, buffers={d})",
            .{ @errorName(err), doc.meshes.len, doc.accessors.len, doc.buffers.len },
        ) catch "[gltf] meshesFromGltf failed (fmt err)";
        dom.log(.err, msg);
        return errors.LoadError.GltfParseFailed;
    };
    errdefer {
        for (meshes) |m| unloadMesh(gpa, m);
        gpa.free(meshes);
    }

    // Auto-fulfill vertex attributes for the PBR vertex schema.
    // PBR's `Attributes` declares `vertex_tangent`, so meshes
    // missing tangents but with normals + UVs get tangents
    // generated.  glTF assets often ship without TANGENT — the
    // spec says renderers should compute them via mikktspace when
    // needed.  Must happen BEFORE uploadMesh so the tangent VBO
    // is created alongside the other vertex attributes.
    //
    // GL-retirement P5: the GL `prepareMeshFor` (schema-driven attribute
    // prep + VBO planning) died with the backend; the CPU-valuable piece
    // is tangent generation, called directly.
    for (meshes) |*m| {
        if (m.tangents == null and m.normals != null and m.texcoords != null) {
            genMeshTangents(gpa, m) catch |err| {
                var buf: [128]u8 = undefined;
                const msg: []const u8 = bufPrint(
                    &buf,
                    "[gltf] genMeshTangents failed: {s} (vc={d})",
                    .{ @errorName(err), m.vertexCount },
                ) catch "[gltf] genMeshTangents failed (fmt err)";
                dom.log(.warn, msg);
            };
        }
    }

    // GL-retirement P5: the GL uploadMesh (VBO/VAO creation) is gone —
    // GPU residency on the wgpu path comes from loadModelFromMesh /
    // the retained-mesh API, which consume these CPU arrays.

    // Materials: one zimr Material per glTF material.  PNG-decoded
    // diffuse textures are uploaded inside the helper.  Falls back
    // to a single default material if the glTF has none.
    const mats: []Material = try materialsFromGltf(gpa, doc);
    errdefer {
        for (mats) |mat| unloadMaterial(gpa, mat);
        gpa.free(mats);
    }

    // Per-mesh-primitive material index.
    const mm: []i32 = try meshMaterialIndicesFromGltf(gpa, doc);
    errdefer gpa.free(mm);

    var model: Model = std.mem.zeroes(Model);
    model.transform = identity();
    model.meshes = meshes.ptr;
    model.meshCount = @intCast(meshes.len);
    model.materials = mats.ptr;
    model.materialCount = @intCast(mats.len);
    model.meshMaterial = mm.ptr;
    return model;
}

/// Free a Model - recursively free meshes, free each material's maps
/// (but not the shader/textures: caller owns those if shared), then
/// free the top-level arrays and skeleton data.
/// Per raylib's contract: shaders and textures are NOT unloaded
/// because the caller may share them across models.
/// The meshes / materials / meshMaterial / per-material maps arrays
/// are gpa-allocated (by `loadModelFromMesh` / `loadMaterialDefault`).
/// The skeleton arrays are libc-allocated by the underlying model
/// loaders.
pub fn unloadModel(
    gpa: Allocator,
    model: Model,
) void {
    // Per-mesh: frees the per-attribute CPU arrays plus the GPU VAO/VBOs.
    var i: usize = 0;
    const mc: usize = @intCast(model.meshCount);
    while (i < mc) : (i += 1) {
        unloadMesh(gpa, model.meshes[i]);
    }

    // Per-material: free the `maps` array (gpa).
    var m: usize = 0;
    const matc: usize = @intCast(model.materialCount);
    while (m < matc) : (m += 1) {
        if (model.materials[m].maps != null) {
            allocator_mod.freeMany(gpa, model.materials[m].maps, max_material_maps);
        }
    }

    // Top-level arrays (gpa).
    if (model.meshes != null) {
        allocator_mod.freeMany(gpa, model.meshes, mc);
    }
    if (model.materials != null) {
        allocator_mod.freeMany(gpa, model.materials, matc);
    }
    if (model.meshMaterial != null) {
        allocator_mod.freeMany(gpa, model.meshMaterial, mc);
    }

    // Bone-palette buffer (allocated by `updateModelAnimation`
    // on first call; sized to anim.boneCount).  Read the count
    // off whichever Mesh has bone influences - it's the same
    // value across the model.  Zero-skipping handles non-skinned
    // models cleanly.
    if (model.boneMatrices != null) {
        // Use the maximum bone-index referenced by any mesh's
        // boneIndices array as a conservative upper bound.  If
        // we don't have skinning data we shouldn't have allocated
        // the buffer in the first place, but be defensive.
        var bone_count: usize = 0;
        for (0..mc) |k| {
            if (model.meshes[k].boneIndices == null) {
                continue;
            }
            const vc: usize = @intCast(@max(model.meshes[k].vertexCount, 0));
            for (0..vc * 4) |bi| {
                const id: u8 = model.meshes[k].boneIndices[bi];
                if (id + 1 > bone_count) {
                    bone_count = id + 1;
                }
            }
        }
        if (bone_count > 0) {
            allocator_mod.freeMany(gpa, model.boneMatrices, bone_count);
        }
    }

    // Skeleton - still libc-allocated by the not-yet-ported model
    // loaders (loadModel from glTF/OBJ/IQM/M3D).  These libc.free
    // calls are dead today because no loader produces skeleton data;
    // they go live when ROADMAP §8 (zgltf adoption) lands and the
    // loaders allocate via gpa.  At that point this whole block
    // becomes `allocator_mod.freeMany(gpa, ..., bone_count)` etc.
    if (model.skeleton.bones != null) {
        libc.free(@ptrCast(model.skeleton.bones));
    }
    if (model.skeleton.bindPose != null) {
        libc.free(@ptrCast(model.skeleton.bindPose));
    }
}

/// Free an array of ModelAnimations and the per-animation per-keyframe
/// pose arrays they own.  Same Phase-D-and-zgltf-adoption note as
/// Decode glTF animations into a heap-allocated `[]ModelAnimation`.
/// Each glTF `animation` becomes one `ModelAnimation` whose
/// keyframes are the union of its samplers' input timestamps,
/// taken from the first sampler as the canonical set.  At each
/// keyframe, each channel's `target_path` (translation/rotation/
/// scale) is sampled with linear interpolation and written into
/// the destination bone's slot.
/// `boneCount` is computed as `max(channel.target_node) + 1` for
/// the animation, which means each glTF node referenced as an
/// animation target gets one Transform slot in every keyframe.
/// This matches raylib's mental model where bones and nodes are
/// the same thing for animation purposes.
/// Caller MUST free with `unloadModelAnimations(gpa, slice)` using
/// the same allocator.
pub fn loadModelAnimations(
    gpa: Allocator,
    bytes: []const u8,
) errors.LoadError![]ModelAnimation {
    const codecs_mod = @import("codecs.zig");
    var doc: codecs_mod.gltf.Data = codecs_mod.gltf.parse(gpa, bytes) catch return errors.LoadError.GltfParseFailed;
    defer doc.deinit();

    if (doc.animations.len == 0) {
        // Empty slice is fine - no animations is not an error.
        return gpa.alloc(ModelAnimation, 0) catch return errors.LoadError.OutOfMemory;
    }

    const out: []ModelAnimation = gpa.alloc(
        ModelAnimation,
        doc.animations.len,
    ) catch return errors.LoadError.OutOfMemory;
    var built: usize = 0;
    errdefer {
        // Release any animations we already populated before failure.
        for (out[0..built]) |a| {
            const kc: usize = @intCast(@max(a.keyframeCount, 0));
            for (0..kc) |k| {
                if (a.keyframePoses[k] != null) {
                    const bc: usize = @intCast(@max(a.boneCount, 0));
                    const ptr: [*]types.Transform = @ptrCast(@alignCast(a.keyframePoses[k]));
                    gpa.free(ptr[0..bc]);
                }
            }
            if (a.keyframePoses != null) {
                const kp_ptr: [*]types.ModelAnimPose = @ptrCast(@alignCast(a.keyframePoses));
                gpa.free(kp_ptr[0..kc]);
            }
        }
        gpa.free(out);
    }

    for (doc.animations, 0..) |gltf_anim, i| {
        var anim: ModelAnimation = std.mem.zeroes(ModelAnimation);

        // Copy name into the fixed-size [32]u8 (null-terminated).
        if (gltf_anim.name) |nm| {
            const n: usize = @min(nm.len, anim.name.len - 1);
            @memcpy(anim.name[0..n], nm[0..n]);
            anim.name[n] = 0;
        }

        // Compute boneCount = max target_node + 1.
        var max_node: u32 = 0;
        for (gltf_anim.channels) |ch| {
            if (ch.target_node > max_node) {
                max_node = ch.target_node;
            }
        }
        const bone_count: usize = @intCast(max_node + 1);
        anim.boneCount = @intCast(bone_count);

        // Take the first sampler's input timestamps as the keyframe set.
        if (gltf_anim.samplers.len == 0 or gltf_anim.channels.len == 0) {
            anim.keyframeCount = 0;
            anim.keyframePoses = null;
            out[i] = anim;
            built += 1;
            continue;
        }
        const canonical_input_acc_idx: u32 = gltf_anim.samplers[0].input;
        if (canonical_input_acc_idx >= doc.accessors.len) {
            return errors.LoadError.GltfParseFailed;
        }
        const ts = codecs_mod.gltf.readAccessor(f32, gpa, doc, doc.accessors[canonical_input_acc_idx]) catch
            return errors.LoadError.GltfParseFailed;
        defer gpa.free(ts);
        const keyframe_count: usize = ts.len;
        anim.keyframeCount = @intCast(keyframe_count);

        // Allocate keyframePoses[k] = pointer to Transform[boneCount].
        const kp_slice: []types.ModelAnimPose = gpa.alloc(
            types.ModelAnimPose,
            keyframe_count,
        ) catch return errors.LoadError.OutOfMemory;
        anim.keyframePoses = kp_slice.ptr;
        for (kp_slice) |*p| {
            p.* = null;
        } // start cleared so errdefer can free safely

        for (kp_slice, 0..) |*pose_ptr, k| {
            _ = k;
            const bone_arr: []types.Transform = gpa.alloc(
                types.Transform,
                bone_count,
            ) catch return errors.LoadError.OutOfMemory;
            // Initialise every bone to identity Trs.
            for (bone_arr) |*tr| {
                tr.* = .{
                    .translation = vec(0, 0, 0),
                    .rotation = quat_identity,
                    .scale = vec(1, 1, 1),
                };
            }
            pose_ptr.* = bone_arr.ptr;
        }

        // Walk channels: for each, read input + output, then sample
        // at each keyframe time using linear interp.
        for (gltf_anim.channels) |ch| {
            if (ch.sampler >= gltf_anim.samplers.len) {
                continue;
            }
            const samp: codecs_mod.gltf.AnimationSampler = gltf_anim.samplers[ch.sampler];
            if (samp.input >= doc.accessors.len) {
                continue;
            }
            if (samp.output >= doc.accessors.len) {
                continue;
            }
            const in_acc: codecs_mod.gltf.Accessor = doc.accessors[samp.input];
            const out_acc: codecs_mod.gltf.Accessor = doc.accessors[samp.output];

            const in_ts = codecs_mod.gltf.readAccessor(f32, gpa, doc, in_acc) catch continue;
            defer gpa.free(in_ts);
            const out_vals = codecs_mod.gltf.readAccessor(f32, gpa, doc, out_acc) catch continue;
            defer gpa.free(out_vals);

            // Number of components per element in the output.
            const components: usize = switch (ch.target_path) {
                .translation, .scale => 3,
                .rotation => 4,
                .weights => 1,
            };

            const node: usize = ch.target_node;
            if (node >= bone_count) {
                continue;
            }

            for (kp_slice, 0..) |pose_ptr2, k| {
                const t: f32 = ts[k];
                // Find segment [a, a+1] enclosing t in in_ts.
                var seg: usize = 0;
                var found: bool = false;
                while (seg + 1 < in_ts.len) : (seg += 1) {
                    if (t <= in_ts[seg + 1]) {
                        found = true;
                        break;
                    }
                }
                var t_norm: f32 = 0;
                if (found and in_ts.len >= 2) {
                    const t0: f32 = in_ts[seg];
                    const t1: f32 = in_ts[seg + 1];
                    const dt: f32 = t1 - t0;
                    t_norm = if (dt > 0) (t - t0) / dt else 0;
                } else {
                    seg = if (in_ts.len > 0) in_ts.len - 1 else 0;
                    t_norm = 0;
                }

                const a_off: usize = seg * components;
                const b_off: usize = if (found) (seg + 1) * components else a_off;

                const bone_arr_ptr: [*]types.Transform = @ptrCast(@alignCast(pose_ptr2));
                var tr: types.Transform = bone_arr_ptr[node];

                switch (ch.target_path) {
                    .translation => {
                        tr.translation[0] = lerp(out_vals[a_off + 0], out_vals[b_off + 0], t_norm);
                        tr.translation[1] = lerp(out_vals[a_off + 1], out_vals[b_off + 1], t_norm);
                        tr.translation[2] = lerp(out_vals[a_off + 2], out_vals[b_off + 2], t_norm);
                    },
                    .scale => {
                        tr.scale[0] = lerp(out_vals[a_off + 0], out_vals[b_off + 0], t_norm);
                        tr.scale[1] = lerp(out_vals[a_off + 1], out_vals[b_off + 1], t_norm);
                        tr.scale[2] = lerp(out_vals[a_off + 2], out_vals[b_off + 2], t_norm);
                    },
                    .rotation => {
                        // Linear lerp on quaternion components - not
                        // strictly correct (should be slerp), but close
                        // enough for keyframe sampling at typical frame
                        // rates.  Step 41 will use proper slerp for the
                        // cross-fade path.
                        const qa: Vec = f32x4(
                            out_vals[a_off + 0],
                            out_vals[a_off + 1],
                            out_vals[a_off + 2],
                            out_vals[a_off + 3],
                        );
                        const qb: Vec = f32x4(
                            out_vals[b_off + 0],
                            out_vals[b_off + 1],
                            out_vals[b_off + 2],
                            out_vals[b_off + 3],
                        );
                        const q = qa + (qb - qa) * @as(Vec, @splat(t_norm));
                        // Normalize so the lerp doesn't drift over time.
                        // `normalize4` returns 0/0/0/0 if input is zero
                        // not what we want for an animation drift fix.
                        // Guard with length-squared.
                        const len_sq: f32 = lengthSq4(q);
                        tr.rotation = if (len_sq > 0) normalize4(q) else quat_identity;
                    },
                    .weights => {
                        // Morph target weights - not used for skinned
                        // animation; skip.
                    },
                }
                bone_arr_ptr[node] = tr;
            }
        }

        out[i] = anim;
        built += 1;
    }

    return out;
}

/// Build the world-space matrix for a single bone's transform.
/// `Transform` has translation + rotation (quaternion) + scale.
fn matrixFromTransform(t: types.Transform) Matrix {
    // raylib uses Trs composition: scale → rotate → translate.
    const scale_m: Mat = scaling(t.scale[0], t.scale[1], t.scale[2]);
    const rot_m: Mat = matFromQuat(t.rotation);
    const trans_m: Mat = translation(t.translation[0], t.translation[1], t.translation[2]);
    // math `T * R * S` - applied to a vertex, scale happens first.
    // zmath's row-vector `mul` reverses operands: mul(S, mul(R, T)).
    return mulMat(trans_m, mulMat(rot_m, scale_m));
}

/// Apply a single keyframe of `anim` to `model`.  `frame` is a
/// 0-indexed keyframe number; values outside `[0, anim.keyframeCount)`
/// wrap modulo (so callers can drive it from a frame counter
/// without bounds-checking).
/// Pipeline:
///   1. Look up keyframe pose at index `frame % keyframeCount`
///   2. Compute Matrix from each Transform in the pose
///   3. Allocate `boneMatrices: []Matrix` if not already on the model
///   4. Upload to skinned shader's `boneMatrices[]` uniform via rlSetUniformMatrices
///   5. Swap each material's shader to the skinned variant
/// On host this is mostly a no-op (rlgl forwarders return null/-1)
/// but the path is exercised end-to-end so smoke tests catch
/// regressions.
pub fn updateModelAnimation(
    gl: anytype,
    gpa: Allocator,
    model: *Model,
    anim: ModelAnimation,
    frame: i32,
) Allocator.Error!void {
    if (anim.keyframeCount <= 0) {
        return;
    }
    const kc: usize = @intCast(anim.keyframeCount);
    const bc: usize = @intCast(@max(anim.boneCount, 0));
    if (bc == 0) {
        return;
    }

    // Wrap frame into valid range (modulo).
    var f: i32 = @mod(frame, anim.keyframeCount);
    if (f < 0) {
        f += anim.keyframeCount;
    }
    const idx: usize = @intCast(f);
    if (idx >= kc) {
        return;
    }

    const pose_ptr: [*]types.Transform = @ptrCast(@alignCast(anim.keyframePoses[idx]));
    // Allocate or reuse the boneMatrices buffer on the model.
    if (model.boneMatrices == null) {
        const buf: []Matrix = try gpa.alloc(Matrix, bc);
        model.boneMatrices = buf.ptr;
    }
    // Compute matrix per bone.
    for (0..bc) |b| {
        model.boneMatrices[b] = matrixFromTransform(pose_ptr[b]);
    }

    // Mirror the bone-matrix pointer to each mesh that has bone
    // indices.  drawMesh uses `mesh.boneMatrices != null` as the
    // signal to take the skinned path: re-upload the uniform after
    // binding the shader, draw with the skinned program.  Mirroring
    // (rather than passing model into drawMesh) preserves raylib's
    // function-signature contract for drawMesh.
    const mc: usize = @intCast(@max(model.meshCount, 0));
    for (0..mc) |mi| {
        if (model.meshes[mi].boneIndices != null) {
            model.meshes[mi].boneMatrices = model.boneMatrices;
        }
    }

    // GL-retirement P5: the GL tail (swap materials to the skinned
    // shader + upload boneMatrices as a uniform array via rlgl) is
    // gone.  The CPU pose above (model.boneMatrices + per-mesh
    // mirroring) is the part the wgpu GPU-skinning variant will
    // consume when the typed-3D-shader arc adds it; until then,
    // CPU deformation (skinned_mesh) reads the same pose.
    _ = gl;
}

/// Free a model-animation slice and all its owned keyframe poses.
/// Pass the same allocator used for `loadModelAnimations`.
pub fn unloadModelAnimations(
    gpa: Allocator,
    animations: []ModelAnimation,
) void {
    for (animations) |anim| {
        const kc: usize = @intCast(@max(anim.keyframeCount, 0));
        const bc: usize = @intCast(@max(anim.boneCount, 0));
        for (0..kc) |k| {
            if (anim.keyframePoses[k] != null) {
                const ptr: [*]types.Transform = @ptrCast(@alignCast(anim.keyframePoses[k]));
                gpa.free(ptr[0..bc]);
            }
        }
        if (anim.keyframePoses != null) {
            const kp_ptr: [*]types.ModelAnimPose = @ptrCast(@alignCast(anim.keyframePoses));
            gpa.free(kp_ptr[0..kc]);
        }
    }
    if (animations.len > 0) {
        gpa.free(animations);
    }
}

/// Cross-fade two animations at given keyframes.  `blend ∈ [0, 1]`:
/// 0 = entirely animA at frameA, 1 = entirely animB at frameB.
/// Per-bone:
///   - translation: linear lerp
///   - rotation: quaternion slerp (proper spherical interpolation,
///     not lerp+normalize - preserves angular velocity for slow blends)
///   - scale: linear lerp
/// `boneCount` is taken from `animA` - the two animations should
/// agree on bone topology (same skeleton).  If they don't, bones
/// past `min(animA.boneCount, animB.boneCount)` get only the animA
/// contribution.
pub fn updateModelAnimationBlend(
    gl: anytype,
    gpa: Allocator,
    model: *Model,
    anim_a: ModelAnimation,
    frame_a: i32,
    anim_b: ModelAnimation,
    frame_b: i32,
    blend: f32,
) Allocator.Error!void {
    if (anim_a.keyframeCount <= 0 or anim_a.boneCount <= 0) {
        return;
    }
    if (anim_b.keyframeCount <= 0) {
        // B is empty - fall back to plain animA update.
        return updateModelAnimation(gl, gpa, model, anim_a, frame_a);
    }

    const bc_a: usize = @intCast(anim_a.boneCount);
    const bc_b: usize = @intCast(@max(anim_b.boneCount, 0));
    const bc_min: usize = @min(bc_a, bc_b);

    // Wrap both frames into valid range.
    var fa: i32 = @mod(frame_a, anim_a.keyframeCount);
    if (fa < 0) {
        fa += anim_a.keyframeCount;
    }
    const idx_a: usize = @intCast(fa);
    var fb: i32 = @mod(frame_b, anim_b.keyframeCount);
    if (fb < 0) {
        fb += anim_b.keyframeCount;
    }
    const idx_b: usize = @intCast(fb);
    if (idx_a >= @as(usize, @intCast(anim_a.keyframeCount))) {
        return;
    }
    if (idx_b >= @as(usize, @intCast(anim_b.keyframeCount))) {
        return;
    }

    const pose_a: [*]types.Transform = @ptrCast(@alignCast(anim_a.keyframePoses[idx_a]));
    const pose_b: [*]types.Transform = @ptrCast(@alignCast(anim_b.keyframePoses[idx_b]));

    // Allocate or reuse the boneMatrices buffer.
    if (model.boneMatrices == null) {
        const buf: []Matrix = try gpa.alloc(Matrix, bc_a);
        model.boneMatrices = buf.ptr;
    }

    // Clamp blend.
    const t: f32 = clamp(blend, 0.0, 1.0);

    for (0..bc_a) |b| {
        var blended: types.Transform = undefined;
        if (b < bc_min) {
            const a: types.Transform = pose_a[b];
            const c: types.Transform = pose_b[b];
            blended.translation = vec(
                lerp(a.translation[0], c.translation[0], t),
                lerp(a.translation[1], c.translation[1], t),
                lerp(a.translation[2], c.translation[2], t),
            );
            blended.scale = vec(
                lerp(a.scale[0], c.scale[0], t),
                lerp(a.scale[1], c.scale[1], t),
                lerp(a.scale[2], c.scale[2], t),
            );
            blended.rotation = quatSlerp(a.rotation, c.rotation, t);
        } else {
            blended = pose_a[b];
        }
        model.boneMatrices[b] = matrixFromTransform(blended);
    }

    // Mirror to meshes + swap shader (same as updateModelAnimation).
    const mc: usize = @intCast(@max(model.meshCount, 0));
    for (0..mc) |mi| {
        if (model.meshes[mi].boneIndices != null) {
            model.meshes[mi].boneMatrices = model.boneMatrices;
        }
    }
    // GL-retirement P5: GL skinned-shader tail removed — the CPU
    // pose above is the product.
}

/// success, propagates Allocator.Error on failure (with errdefer
/// cleanup of partial allocations).
fn allocFlatMeshArrays(
    gpa: Allocator,
    tri_count: usize,
) Allocator.Error!FlatMeshArrays {
    const vc: usize = tri_count * 3;
    const v: []f32 = try gpa.alloc(f32, vc * 3);
    errdefer gpa.free(v);
    const n: []f32 = try gpa.alloc(f32, vc * 3);
    errdefer gpa.free(n);
    const t: []f32 = try gpa.alloc(f32, vc * 2);
    return .{ .verts = v, .norms = n, .texs = t };
}

/// Half-sphere (top hemisphere only, no bottom cap).
pub fn genMeshHemiSphere(
    gpa: Allocator,
    radius: f32,
    rings: i32,
    slices: i32,
) Allocator.Error!Mesh {
    var mesh: Mesh = std.mem.zeroes(Mesh);
    if (rings < 3 or slices < 3) {
        return mesh;
    }

    const rings_u: usize = @intCast(rings);
    const slices_u: usize = @intCast(slices);
    const tri_count: usize = rings_u * slices_u * 2;
    const arrs: FlatMeshArrays = try allocFlatMeshArrays(gpa, tri_count);
    errdefer gpa.free(arrs.verts);
    errdefer gpa.free(arrs.norms);
    errdefer gpa.free(arrs.texs);
    const v: []f32 = arrs.verts;
    const n: []f32 = arrs.norms;
    const t: []f32 = arrs.texs;

    var idx: usize = 0;
    var ri: usize = 0;
    while (ri < rings_u) : (ri += 1) {
        // phi sweeps only [0, pi/2].
        const vt0: f32 = float(ri) / float(rings_u);
        const vt1: f32 = float(ri + 1) / float(rings_u);
        const phi0 = vt0 * (pi / 2.0);
        const phi1 = vt1 * (pi / 2.0);

        var si: usize = 0;
        while (si < slices_u) : (si += 1) {
            const ut0: f32 = float(si) / float(slices_u);
            const ut1: f32 = float(si + 1) / float(slices_u);
            const th0: f32 = ut0 * 2.0 * pi;
            const th1: f32 = ut1 * 2.0 * pi;

            const a = sphereVert(phi0, th0, radius);
            const b = sphereVert(phi0, th1, radius);
            const c = sphereVert(phi1, th1, radius);
            const d = sphereVert(phi1, th0, radius);

            writeFlat(v, n, t, idx + 0, a, radius, ut0, vt0);
            writeFlat(v, n, t, idx + 1, c, radius, ut1, vt1);
            writeFlat(v, n, t, idx + 2, b, radius, ut1, vt0);
            writeFlat(v, n, t, idx + 3, a, radius, ut0, vt0);
            writeFlat(v, n, t, idx + 4, d, radius, ut0, vt1);
            writeFlat(v, n, t, idx + 5, c, radius, ut1, vt1);
            idx += 6;
        }
    }

    mesh.vertices = v.ptr;
    mesh.normals = n.ptr;
    mesh.texcoords = t.ptr;
    mesh.vertexCount = @intCast(tri_count * 3);
    mesh.triangleCount = @intCast(tri_count);
    try uploadMesh(gpa, &mesh, false);
    return mesh;
}

/// Cylinder along Y, base at y=0, top at y=height.  Includes top + bottom caps.
pub fn genMeshCylinder(
    gpa: Allocator,
    radius: f32,
    height: f32,
    slices: i32,
) Allocator.Error!Mesh {
    var mesh: Mesh = std.mem.zeroes(Mesh);
    if (slices < 3) {
        return mesh;
    }

    const slices_u: usize = @intCast(slices);
    // Side: slices × 2 triangles.  Top cap: slices triangles. Bottom cap: slices triangles.
    const tri_count: usize = slices_u * 2 + slices_u + slices_u;
    const arrs: FlatMeshArrays = try allocFlatMeshArrays(gpa, tri_count);
    errdefer gpa.free(arrs.verts);
    errdefer gpa.free(arrs.norms);
    errdefer gpa.free(arrs.texs);
    const v: []f32 = arrs.verts;
    const n: []f32 = arrs.norms;
    const t: []f32 = arrs.texs;

    var idx: usize = 0;
    var si: usize = 0;
    while (si < slices_u) : (si += 1) {
        const ut0: f32 = float(si) / float(slices_u);
        const ut1: f32 = float(si + 1) / float(slices_u);
        const th0: f32 = ut0 * 2.0 * pi;
        const th1: f32 = ut1 * 2.0 * pi;
        const c0 = @cos(th0);
        const s0 = @sin(th0);
        const c1 = @cos(th1);
        const s1 = @sin(th1);

        // ---- Side wall (a quad split into 2 triangles).  Normal is
        // the radial direction at each vertex.
        const a: Vec = vec(radius * c0, 0, radius * s0);
        const b: Vec = vec(radius * c1, 0, radius * s1);
        const c: Vec = vec(radius * c1, height, radius * s1);
        const d: Vec = vec(radius * c0, height, radius * s0);

        writeXYZ(v, idx + 0, a);
        writeXYZ(n, idx + 0, vec(c0, 0, s0));
        writeUV(t, idx + 0, ut0, 0);
        writeXYZ(v, idx + 1, c);
        writeXYZ(n, idx + 1, vec(c1, 0, s1));
        writeUV(t, idx + 1, ut1, 1);
        writeXYZ(v, idx + 2, b);
        writeXYZ(n, idx + 2, vec(c1, 0, s1));
        writeUV(t, idx + 2, ut1, 0);
        writeXYZ(v, idx + 3, a);
        writeXYZ(n, idx + 3, vec(c0, 0, s0));
        writeUV(t, idx + 3, ut0, 0);
        writeXYZ(v, idx + 4, d);
        writeXYZ(n, idx + 4, vec(c0, 0, s0));
        writeUV(t, idx + 4, ut0, 1);
        writeXYZ(v, idx + 5, c);
        writeXYZ(n, idx + 5, vec(c1, 0, s1));
        writeUV(t, idx + 5, ut1, 1);
        idx += 6;
    }

    // ---- Top cap: a fan of slices triangles meeting at (0, height, 0).
    si = 0;
    while (si < slices_u) : (si += 1) {
        const ut0: f32 = float(si) / float(slices_u);
        const ut1: f32 = float(si + 1) / float(slices_u);
        const th0: f32 = ut0 * 2.0 * pi;
        const th1: f32 = ut1 * 2.0 * pi;
        const a: Vec = vec(0, height, 0);
        const b: Vec = vec(radius * @cos(th0), height, radius * @sin(th0));
        const c: Vec = vec(radius * @cos(th1), height, radius * @sin(th1));
        const up: Vec = vec(0, 1, 0);
        writeXYZ(v, idx + 0, a);
        writeXYZ(n, idx + 0, up);
        writeUV(t, idx + 0, 0.5, 0.5);
        writeXYZ(v, idx + 1, b);
        writeXYZ(n, idx + 1, up);
        writeUV(t, idx + 1, @cos(th0) * 0.5 + 0.5, @sin(th0) * 0.5 + 0.5);
        writeXYZ(v, idx + 2, c);
        writeXYZ(n, idx + 2, up);
        writeUV(t, idx + 2, @cos(th1) * 0.5 + 0.5, @sin(th1) * 0.5 + 0.5);
        idx += 3;
    }

    // ---- Bottom cap: fan around (0, 0, 0), normal -Y, reversed winding.
    si = 0;
    while (si < slices_u) : (si += 1) {
        const ut0: f32 = float(si) / float(slices_u);
        const ut1: f32 = float(si + 1) / float(slices_u);
        const th0: f32 = ut0 * 2.0 * pi;
        const th1: f32 = ut1 * 2.0 * pi;
        const a: Vec = vec(0, 0, 0);
        const b: Vec = vec(radius * @cos(th0), 0, radius * @sin(th0));
        const c: Vec = vec(radius * @cos(th1), 0, radius * @sin(th1));
        const dn: Vec = vec(0, -1, 0);
        writeXYZ(v, idx + 0, a);
        writeXYZ(n, idx + 0, dn);
        writeUV(t, idx + 0, 0.5, 0.5);
        writeXYZ(v, idx + 1, c);
        writeXYZ(n, idx + 1, dn);
        writeUV(t, idx + 1, @cos(th1) * 0.5 + 0.5, @sin(th1) * 0.5 + 0.5);
        writeXYZ(v, idx + 2, b);
        writeXYZ(n, idx + 2, dn);
        writeUV(t, idx + 2, @cos(th0) * 0.5 + 0.5, @sin(th0) * 0.5 + 0.5);
        idx += 3;
    }

    mesh.vertices = v.ptr;
    mesh.normals = n.ptr;
    mesh.texcoords = t.ptr;
    mesh.vertexCount = @intCast(tri_count * 3);
    mesh.triangleCount = @intCast(tri_count);
    try uploadMesh(gpa, &mesh, false);
    return mesh;
}

/// Cone along Y, apex at top.  One triangle slant per slice + bottom cap.
pub fn genMeshCone(
    gpa: Allocator,
    radius: f32,
    height: f32,
    slices: i32,
) Allocator.Error!Mesh {
    var mesh: Mesh = std.mem.zeroes(Mesh);
    if (slices < 3) {
        return mesh;
    }

    const slices_u: usize = @intCast(slices);
    // Slant: slices triangles.  Bottom cap: slices triangles.
    const tri_count: usize = slices_u + slices_u;
    const arrs: FlatMeshArrays = try allocFlatMeshArrays(gpa, tri_count);
    errdefer gpa.free(arrs.verts);
    errdefer gpa.free(arrs.norms);
    errdefer gpa.free(arrs.texs);
    const v: []f32 = arrs.verts;
    const n: []f32 = arrs.norms;
    const t: []f32 = arrs.texs;

    const slant_len: f32 = @sqrt(radius * radius + height * height);
    const ny_factor: f32 = radius / slant_len;
    const ny: f32 = ny_factor; // y-component of slant normal (constant around)
    const nxz_scale: f32 = height / slant_len;

    var idx: usize = 0;
    var si: usize = 0;
    while (si < slices_u) : (si += 1) {
        const ut0: f32 = float(si) / float(slices_u);
        const ut1: f32 = float(si + 1) / float(slices_u);
        const th0: f32 = ut0 * 2.0 * pi;
        const th1: f32 = ut1 * 2.0 * pi;
        const c0 = @cos(th0);
        const s0 = @sin(th0);
        const c1 = @cos(th1);
        const s1 = @sin(th1);

        const apex: Vec = vec(0, height, 0);
        const b: Vec = vec(radius * c0, 0, radius * s0);
        const c: Vec = vec(radius * c1, 0, radius * s1);
        // Slant normal: outward radial × scale + constant Y.
        const n0: Vec = vec(c0 * nxz_scale, ny, s0 * nxz_scale);
        const n1: Vec = vec(c1 * nxz_scale, ny, s1 * nxz_scale);
        const napex: Vec = vec((c0 + c1) * 0.5 * nxz_scale, ny, (s0 + s1) * 0.5 * nxz_scale);

        writeXYZ(v, idx + 0, apex);
        writeXYZ(n, idx + 0, napex);
        writeUV(t, idx + 0, (ut0 + ut1) * 0.5, 1);
        writeXYZ(v, idx + 1, c);
        writeXYZ(n, idx + 1, n1);
        writeUV(t, idx + 1, ut1, 0);
        writeXYZ(v, idx + 2, b);
        writeXYZ(n, idx + 2, n0);
        writeUV(t, idx + 2, ut0, 0);
        idx += 3;
    }

    // Bottom cap.
    si = 0;
    while (si < slices_u) : (si += 1) {
        const ut0: f32 = float(si) / float(slices_u);
        const ut1: f32 = float(si + 1) / float(slices_u);
        const th0: f32 = ut0 * 2.0 * pi;
        const th1: f32 = ut1 * 2.0 * pi;
        const a: Vec = vec(0, 0, 0);
        const b: Vec = vec(radius * @cos(th0), 0, radius * @sin(th0));
        const c: Vec = vec(radius * @cos(th1), 0, radius * @sin(th1));
        const dn: Vec = vec(0, -1, 0);
        writeXYZ(v, idx + 0, a);
        writeXYZ(n, idx + 0, dn);
        writeUV(t, idx + 0, 0.5, 0.5);
        writeXYZ(v, idx + 1, c);
        writeXYZ(n, idx + 1, dn);
        writeUV(t, idx + 1, @cos(th1) * 0.5 + 0.5, @sin(th1) * 0.5 + 0.5);
        writeXYZ(v, idx + 2, b);
        writeXYZ(n, idx + 2, dn);
        writeUV(t, idx + 2, @cos(th0) * 0.5 + 0.5, @sin(th0) * 0.5 + 0.5);
        idx += 3;
    }

    mesh.vertices = v.ptr;
    mesh.normals = n.ptr;
    mesh.texcoords = t.ptr;
    mesh.vertexCount = @intCast(tri_count * 3);
    mesh.triangleCount = @intCast(tri_count);
    try uploadMesh(gpa, &mesh, false);
    return mesh;
}

/// Torus: major radius `radius`, tube thickness `size`.  `rad_seg` is
/// the segment count along the major circle, `sides` along the tube.
pub fn genMeshTorus(
    gpa: Allocator,
    radius: f32,
    size: f32,
    rad_seg: i32,
    sides: i32,
) Allocator.Error!Mesh {
    var mesh: Mesh = std.mem.zeroes(Mesh);
    if (rad_seg < 3 or sides < 3) {
        return mesh;
    }

    const seg_u: usize = @intCast(rad_seg);
    const sides_u: usize = @intCast(sides);
    const tri_count: usize = seg_u * sides_u * 2;
    const arrs: FlatMeshArrays = try allocFlatMeshArrays(gpa, tri_count);
    errdefer gpa.free(arrs.verts);
    errdefer gpa.free(arrs.norms);
    errdefer gpa.free(arrs.texs);
    const v: []f32 = arrs.verts;
    const n: []f32 = arrs.norms;
    const t: []f32 = arrs.texs;

    var idx: usize = 0;
    for (0..seg_u) |i| {
        const ut0: f32 = float(i) / float(seg_u);
        const ut1: f32 = float(i + 1) / float(seg_u);
        const a0: f32 = ut0 * 2.0 * pi;
        const a1: f32 = ut1 * 2.0 * pi;
        for (0..sides_u) |j| {
            const vt0: f32 = float(j) / float(sides_u);
            const vt1: f32 = float(j + 1) / float(sides_u);
            const b0: f32 = vt0 * 2.0 * pi;
            const b1: f32 = vt1 * 2.0 * pi;

            const aV: Vec = torusPoint(radius, size, a0, b0);
            const bV: Vec = torusPoint(radius, size, a1, b0);
            const cV: Vec = torusPoint(radius, size, a1, b1);
            const dV: Vec = torusPoint(radius, size, a0, b1);

            const an: Vec = torusNormal(a0, b0);
            const bn: Vec = torusNormal(a1, b0);
            const cn: Vec = torusNormal(a1, b1);
            const dn: Vec = torusNormal(a0, b1);

            writeXYZ(v, idx + 0, aV);
            writeXYZ(n, idx + 0, an);
            writeUV(t, idx + 0, ut0, vt0);
            writeXYZ(v, idx + 1, cV);
            writeXYZ(n, idx + 1, cn);
            writeUV(t, idx + 1, ut1, vt1);
            writeXYZ(v, idx + 2, bV);
            writeXYZ(n, idx + 2, bn);
            writeUV(t, idx + 2, ut1, vt0);
            writeXYZ(v, idx + 3, aV);
            writeXYZ(n, idx + 3, an);
            writeUV(t, idx + 3, ut0, vt0);
            writeXYZ(v, idx + 4, dV);
            writeXYZ(n, idx + 4, dn);
            writeUV(t, idx + 4, ut0, vt1);
            writeXYZ(v, idx + 5, cV);
            writeXYZ(n, idx + 5, cn);
            writeUV(t, idx + 5, ut1, vt1);
            idx += 6;
        }
    }

    mesh.vertices = v.ptr;
    mesh.normals = n.ptr;
    mesh.texcoords = t.ptr;
    mesh.vertexCount = @intCast(tri_count * 3);
    mesh.triangleCount = @intCast(tri_count);
    try uploadMesh(gpa, &mesh, false);
    return mesh;
}

/// Trefoil knot mesh.  `radius` is the dominant scale; `size` is the
/// tube radius.  rad_seg = curve sample count, sides = tube sides.
pub fn genMeshKnot(
    gpa: Allocator,
    radius: f32,
    size: f32,
    rad_seg: i32,
    sides: i32,
) Allocator.Error!Mesh {
    var mesh: Mesh = std.mem.zeroes(Mesh);
    if (rad_seg < 8 or sides < 3) {
        return mesh;
    }

    const seg_u: usize = @intCast(rad_seg);
    const sides_u: usize = @intCast(sides);
    const tri_count: usize = seg_u * sides_u * 2;
    const arrs: FlatMeshArrays = try allocFlatMeshArrays(gpa, tri_count);
    errdefer gpa.free(arrs.verts);
    errdefer gpa.free(arrs.norms);
    errdefer gpa.free(arrs.texs);
    const v: []f32 = arrs.verts;
    const n: []f32 = arrs.norms;
    const t: []f32 = arrs.texs;

    var idx: usize = 0;
    for (0..seg_u) |i| {
        const ut0: f32 = float(i) / float(seg_u);
        const ut1: f32 = float(i + 1) / float(seg_u);
        const t0: f32 = ut0 * 2.0 * pi;
        const t1: f32 = ut1 * 2.0 * pi;

        // Trefoil center curve + tangent + a perpendicular frame.
        const cf0: KnotFrame = trefoilFrame(t0, radius);
        const cf1: KnotFrame = trefoilFrame(t1, radius);

        for (0..sides_u) |j| {
            const vt0: f32 = float(j) / float(sides_u);
            const vt1: f32 = float(j + 1) / float(sides_u);
            const a0: f32 = vt0 * 2.0 * pi;
            const a1: f32 = vt1 * 2.0 * pi;

            const aP: Vec = ringVert(cf0, size, a0);
            const bP: Vec = ringVert(cf1, size, a0);
            const cP: Vec = ringVert(cf1, size, a1);
            const dP: Vec = ringVert(cf0, size, a1);

            const aN: Vec = ringNorm(cf0, a0);
            const bN: Vec = ringNorm(cf1, a0);
            const cN: Vec = ringNorm(cf1, a1);
            const dN: Vec = ringNorm(cf0, a1);

            writeXYZ(v, idx + 0, aP);
            writeXYZ(n, idx + 0, aN);
            writeUV(t, idx + 0, ut0, vt0);
            writeXYZ(v, idx + 1, cP);
            writeXYZ(n, idx + 1, cN);
            writeUV(t, idx + 1, ut1, vt1);
            writeXYZ(v, idx + 2, bP);
            writeXYZ(n, idx + 2, bN);
            writeUV(t, idx + 2, ut1, vt0);
            writeXYZ(v, idx + 3, aP);
            writeXYZ(n, idx + 3, aN);
            writeUV(t, idx + 3, ut0, vt0);
            writeXYZ(v, idx + 4, dP);
            writeXYZ(n, idx + 4, dN);
            writeUV(t, idx + 4, ut0, vt1);
            writeXYZ(v, idx + 5, cP);
            writeXYZ(n, idx + 5, cN);
            writeUV(t, idx + 5, ut1, vt1);
            idx += 6;
        }
    }

    mesh.vertices = v.ptr;
    mesh.normals = n.ptr;
    mesh.texcoords = t.ptr;
    mesh.vertexCount = @intCast(tri_count * 3);
    mesh.triangleCount = @intCast(tri_count);
    try uploadMesh(gpa, &mesh, false);
    return mesh;
}

/// Convert any uncompressed Image to a flat RGBA Color slice,
/// allocating fresh memory with `gpa`.  Free with `gpa.free(slice)`.
/// Returns an empty slice for empty images or compressed pixel
/// formats.  Supported formats: GRAYSCALE, GRAY_ALPHA, R5G5B5A1,
/// R5G6B5, R4G4B4A4, R8G8B8, R8G8B8A8.  16-bit and 32-bit float
/// formats are not supported.
pub fn loadImageColors(
    gpa: Allocator,
    image: z.Image,
) Allocator.Error![]Color {
    if (image.width <= 0 or image.height <= 0 or image.data == null) {
        return &[_]Color{};
    }

    const pixel_count: usize = @intCast(image.width * image.height);
    const out: []Color = try gpa.alloc(Color, pixel_count);
    errdefer gpa.free(out);

    const src8: [*c]const u8 = @ptrCast(@alignCast(image.data));
    const src16: [*c]const u16 = @ptrCast(@alignCast(image.data));

    const fmt: @import("types.zig").PixelFormat = @enumFromInt(image.format);
    switch (fmt) {
        .uncompressed_grayscale => {
            for (out, 0..) |*p, i| {
                const v: u8 = src8[i];
                p.* = .{ .r = v, .g = v, .b = v, .a = 255 };
            }
        },
        .uncompressed_gray_alpha => {
            for (out, 0..) |*p, i| {
                const v: u8 = src8[i * 2];
                const a: u8 = src8[i * 2 + 1];
                p.* = .{ .r = v, .g = v, .b = v, .a = a };
            }
        },
        .uncompressed_r5g5b5a1 => {
            for (out, 0..) |*p, i| {
                const px: u16 = src16[i];
                p.* = .{
                    .r = @intCast(((px & 0xF800) >> 11) * (255 / 31)),
                    .g = @intCast(((px & 0x07C0) >> 6) * (255 / 31)),
                    .b = @intCast(((px & 0x003E) >> 1) * (255 / 31)),
                    .a = if ((px & 1) != 0) 255 else 0,
                };
            }
        },
        .uncompressed_r5g6b5 => {
            for (out, 0..) |*p, i| {
                const px: u16 = src16[i];
                p.* = .{
                    .r = @intCast(((px & 0xF800) >> 11) * (255 / 31)),
                    .g = @intCast(((px & 0x07E0) >> 5) * (255 / 63)),
                    .b = @intCast((px & 0x001F) * (255 / 31)),
                    .a = 255,
                };
            }
        },
        .uncompressed_r4g4b4a4 => {
            for (out, 0..) |*p, i| {
                const px: u16 = src16[i];
                p.* = .{
                    .r = @intCast(((px & 0xF000) >> 12) * (255 / 15)),
                    .g = @intCast(((px & 0x0F00) >> 8) * (255 / 15)),
                    .b = @intCast(((px & 0x00F0) >> 4) * (255 / 15)),
                    .a = @intCast((px & 0x000F) * (255 / 15)),
                };
            }
        },
        .uncompressed_r8g8b8 => {
            for (out, 0..) |*p, i| {
                p.* = .{
                    .r = src8[i * 3],
                    .g = src8[i * 3 + 1],
                    .b = src8[i * 3 + 2],
                    .a = 255,
                };
            }
        },
        .uncompressed_r8g8b8a8 => {
            for (out, 0..) |*p, i| {
                p.* = .{
                    .r = src8[i * 4],
                    .g = src8[i * 4 + 1],
                    .b = src8[i * 4 + 2],
                    .a = src8[i * 4 + 3],
                };
            }
        },
        else => {
            // Unsupported format - zero the slice (raylib emits a
            // TraceLog warning here; we silently zero).
            @memset(@as([*]u8, @ptrCast(out))[0 .. pixel_count * @sizeOf(Color)], 0);
        },
    }

    return out;
}

fn close(a: f32, b: f32) bool {
    return @abs(a - b) <= eps;
}

// ===========================================================================
// STRUCTURE-PLAN S2 (t1177): former src/pbr3d.zig folded in as a
// section namespace.  One-way deps only; the umbrella re-exports keep the
// public `z.pbr3d` shape unchanged.
// ===========================================================================
pub const pbr3d = struct {
    // src/pbr3d.zig -- a small, reusable PBR 3D renderer for the wgpu backend.
    //
    // This generalizes the hand-wired DamagedHelmet showcase into a module any
    // example can drive: it owns the PBR pipeline + the three bind-group layouts,
    // loads a glTF binary into a `Model` (geometry + the five PBR maps), and draws
    // models with a simple beginFrame / draw / endFrame loop.
    //
    // The whole WebGPU stack -- the shader pipeline, the stage-segregated binding
    // model, the runtime layers -- is documented atop `src/zimr.zig`; read
    // that first. This file only adds the PBR-model convenience layer on top.
    //
    // Texture resolution goes through the glTF *material* (base-color, metallic-
    // roughness, normal, occlusion, emissive), not a hardcoded image order, so the
    // same loader handles arbitrary glbs. Maps a model leaves unset fall back to
    // neutral textures (white, or a flat tangent-space normal).
    //
    // The example supplies the compiled PBR WGSL (wired per-example in build.zig)
    // as init params, so adding this renderer did not require threading the WGSL
    // into the `zimr` module itself.
    //
    // v1 scope -- honest about what it does NOT do yet:
    //  * One model per frame. The VS matrices + the FS uniform block live in
    //    shared per-renderer buffers that `draw` rewrites each call, so two draws
    //    in one frame would collapse to the last write. Multi-model wants per-model
    //    buffers or dynamic offsets.
    //  * Shadows are gated off (the shader supports a shadow map; wiring one is
    //    future work).
    //  * `loadGltf` leaks the temporary CPU-side mesh arrays from `meshesFromGltf`
    //    -- fine for a handful of one-shot model loads.
    //  * Only embedded images (buffer-view backed) decode; an external-`uri` image
    //    falls back to the neutral texture.

    const codecs = @import("codecs.zig");
    const gpu_iface = @import("gpu_iface.zig");
    // For drawInApp: composite the PBR result into the app's own render pass
    // (so a 2D blit + splitter can overlay it). One-way dependency; wgpu_app does
    // not import pbr3d.

    const Backend = gpu_iface.WgpuBackend;
    const GpuFrame = gpu.GpuFrame;

    // On-page diagnostics: the wgpu JS bridge maps `dom.js_log` to the browser
    // console (and the standalone mirrors the console into an on-page pane), so
    // this is how the wasm reports what it actually did -- the same channel the
    // WebGL bridge used. No-op on native so host tests / lint stay clean.
    const dom = struct {
        extern "dom" fn js_log(
            level: u32,
            ptr: [*]const u8,
            len: usize,
        ) void;
    };
    fn pageLog(comptime fmt: []const u8, args: anytype) void {
        if (comptime !log_pbr3d) {
            return;
        }
        if (@import("builtin").target.cpu.arch.isWasm()) {
            var buf: [256]u8 = undefined;
            const msg: []u8 = bufPrint(&buf, fmt, args) catch return;
            dom.js_log(1, msg.ptr, msg.len);
        }
    }

    // The PBR shader caps these light counts; the host Ubo mirrors the sizes.
    pub const max_directional_lights: usize = @import("shaders/pbr_common_io.zig").max_directional_lights;
    pub const max_point_lights: usize = @import("shaders/pbr_common_io.zig").max_point_lights;

    // One 4x4 f32 matrix = 64 bytes. The engine emits one VS uniform binding per
    // matrix (five of them: model, view, projection, normal, light-space).
    const mat4_bytes: u64 = 64;
    // Ring depth for the per-draw VS/FS UBOs: how many models can be drawn in
    // one frame before a slot must be reused. Side-by-sides draw 2; 8 leaves
    // headroom. A frame exceeding this asserts in `draw()`.
    const ubo_ring_len: u32 = 8;

    // ============================================================================
    // Public value types
    // ============================================================================

    /// The vertex the PBR VS consumes: position, uv, normal, color, tangent,
    /// interleaved into one buffer. `extern` because the byte layout is a GPU-ABI
    /// seam -- the GPU reads it back through `vertex_layout`'s offsets.
    pub const Vertex = extern struct {
        position: [3]f32,
        tex_coord: [2]f32,
        normal: [3]f32,
        color: [4]f32 = .{ 1, 1, 1, 1 },
        tangent: [4]f32 = .{ 1, 0, 0, 1 },
    };

    /// A single directional light plus scene ambient. The shader also supports
    /// point lights + fog; this v1 leaves those off for a clean default.
    pub const Light = struct {
        dir: [3]f32 = .{ -0.4, -0.8, -0.5 },
        color: [3]f32 = .{ 1, 1, 1 },
        ambient: [3]f32 = .{ 0.12, 0.12, 0.14 },
    };

    /// The five PBR maps plus the glTF scalar factors for one model.
    pub const Material = struct {
        base_color: WgpuTexture,
        metallic_roughness: WgpuTexture,
        normal: WgpuTexture,
        occlusion: WgpuTexture,
        emissive: WgpuTexture,
        base_color_factor: [4]f32 = .{ 1, 1, 1, 1 },
        metallic_factor: f32 = 1,
        roughness_factor: f32 = 1,
        emissive_factor: [3]f32 = .{ 0, 0, 0 },
    };

    /// A drawable: the GPU buffers plus its material's bind group.
    pub const Model = struct {
        vertex_buffer: wgpu.BufferHandle,
        index_buffer: wgpu.BufferHandle,
        vertex_bytes: u64,
        index_bytes: u64,
        index_count: u32,
        material: pbr3d.Material,
        material_bind_group: wgpu.BindGroupHandle,

        pub fn deinit(self: *@This()) void {
            if (self.vertex_buffer != .invalid) {
                wgpu.destroyBuffer(self.vertex_buffer);
            }
            if (self.index_buffer != .invalid) {
                wgpu.destroyBuffer(self.index_buffer);
            }
            if (self.material_bind_group != .invalid) {
                wgpu.destroyBindGroup(self.material_bind_group);
            }
            self.material.base_color.deinit();
            self.material.metallic_roughness.deinit();
            self.material.normal.deinit();
            self.material.occlusion.deinit();
            self.material.emissive.deinit();
        }
    };

    pub const Camera = struct {
        view: Mat,
        proj: Mat,
        eye: [3]f32 = .{ 0, 0, 0 },
    };

    /// CPU-side geometry in exactly the shape the PBR pipeline consumes —
    /// interleaved `Vertex` array + u16 indices.  Produced by `buildCpuMesh`;
    /// `loadGltf` uploads it to GPU buffers, and the software-rasterizer path
    /// feeds the same data through `pbr_vs.shaderMain` per vertex.
    pub const CpuMesh = struct {
        vertices: []Vertex,
        indices: []u16,

        pub fn deinit(self: CpuMesh, gpa: Allocator) void {
            gpa.free(self.vertices);
            gpa.free(self.indices);
        }
    };

    /// Interleave a parsed glTF's first mesh into `Vertex` records, synthesizing
    /// flat normals when the file omits NORMAL and Lengyel tangents always (the
    /// helmet glb ships no TANGENT).  Pure CPU — no GPU handles touched — so the
    /// software-renderer half of a side-by-side gets byte-identical geometry to
    /// what `loadGltf` uploads.  Caller owns the result (`CpuMesh.deinit`).
    pub fn buildCpuMesh(gpa: Allocator, document: codecs.gltf.Data) !CpuMesh {
        // KNOWN LEAK (documented in the module doc): the attribute arrays inside
        // `meshes` are allocated by meshesFromGltf and the matching free
        // (`unloadMesh`) lives in the GL-only drawing.zig.  One-shot init-time
        // cost; the audit_cleanup_notes.md entry tracks giving codecs.gltf its
        // own symmetric free.
        const meshes: []types.Mesh = try codecs.gltf.meshesFromGltf(gpa, document);
        defer gpa.free(meshes);
        if (meshes.len == 0) {
            return error.NoMesh;
        }
        const mesh: types.Mesh = meshes[0];

        const vertex_count: usize = @intCast(mesh.vertexCount);
        const triangle_count: usize = @intCast(mesh.triangleCount);
        const index_count: usize = triangle_count * 3;
        assert(vertex_count > 0, @src());
        assert(index_count > 0, @src());

        // The loader hands back indices as a C-ABI `[*c]c_ushort`; the GPU wants
        // a plain u16 index buffer, so view the same bytes as `[]const u16`.
        const raw_index_ptr: [*]const u16 = @ptrCast(mesh.indices);
        const indices: []u16 = try gpa.dupe(u16, raw_index_ptr[0..index_count]);
        errdefer gpa.free(indices);

        // glTF attributes are all optional. Positions are required; texcoords
        // and normals may be absent (a bare quad has UVs but no normals), in
        // which case we zero the UVs and synthesize flat normals below.
        const has_texcoords: bool = mesh.texcoords != null;
        const has_normals: bool = mesh.normals != null;

        // ---- interleave the loader's separate attribute arrays into Vertex ----
        const vertices: []Vertex = try gpa.alloc(Vertex, vertex_count);
        errdefer gpa.free(vertices);
        for (vertices, 0..) |*vertex, i| {
            const uv: [2]f32 = if (has_texcoords) .{ mesh.texcoords[i * 2], mesh.texcoords[i * 2 + 1] } else .{ 0, 0 };
            var normal: [3]f32 = .{ 0, 0, 0 };
            if (has_normals) {
                normal = .{ mesh.normals[i * 3], mesh.normals[i * 3 + 1], mesh.normals[i * 3 + 2] };
            }
            vertex.* = .{
                .position = .{ mesh.vertices[i * 3], mesh.vertices[i * 3 + 1], mesh.vertices[i * 3 + 2] },
                .tex_coord = uv,
                .normal = normal, // synthesized below when the glTF omits normals
                .color = .{ 1, 1, 1, 1 },
                .tangent = .{ 1, 0, 0, 1 }, // overwritten by computeTangents
            };
        }
        // A glTF without normals needs them for lighting; derive flat per-face
        // normals from the triangle winding.
        if (!has_normals) {
            synthesizeFlatNormals(vertices, indices);
        }
        // glTF ships no TANGENT attribute here; derive one from positions + UVs.
        computeTangents(vertices, indices, gpa);
        return .{ .vertices = vertices, .indices = indices };
    }

    pub const ClearColor = struct { r: f32 = 0.05, g: f32 = 0.06, b: f32 = 0.10, a: f32 = 1.0 };

    pub const FrameDesc = struct {
        camera: Camera,
        light: Light = .{},
        clear: ClearColor = .{},
    };

    pub const InitOptions = struct {
        device: wgpu.DeviceHandle,
        queue: wgpu.QueueHandle,
        gpa: Allocator,
        surface_format: wgpu.TextureFormat,
        // Must match the GpuFrame's depth_format -- the frame owns the depth
        // texture; the renderer only needs the format to build a matching pipeline.
        depth_format: wgpu.TextureFormat = .depth24_plus,
        vs_wgsl: []const u8,
        fs_wgsl: []const u8,
        /// Face culling. A closed solid (the helmet) wants `.back`; a single-sided
        /// flat model (a quad, plane, card, billboard) must use `.none`, or its one
        /// face gets culled whenever its winding faces away from the camera.
        cull_mode: wgpu.CullMode = .back,
    };

    // ============================================================================
    // FsUbo — the shader's @group(2) @binding(0) uniform block, taken DIRECTLY
    // from the schema (`src/shaders/pbr_fs_io.zig`).  This used to be a
    // hand-maintained byte-mirror with a "MUST agree" comment; pbr3d and the
    // io file live in the same module, so the mirror is gone and host-vs-WGSL
    // std140 drift is structurally impossible.  The size assert stays as a
    // std140 sanity check on the schema itself.
    // ============================================================================

    const FsUbo = @import("shaders/pbr_fs_io.zig").Ubo;
    comptime {
        if (shader_iface.wireSizeOf(FsUbo) % 16 != 0) {
            @compileError("FsUbo: wire size must be a multiple of 16 (std140)");
        }
    }

    // ============================================================================
    // Material (group 1) sampler bindings — DERIVED FROM THE SCHEMA, the same way
    // the WGSL's `@group(1) @binding(N)` decorations are. Each `Sampler2D` field
    // in `pbr_fs_io.Samplers` becomes a texture at binding N and a paired sampler
    // at N+1 (the solver spaces them 2 apart). Hand-rolling "@0..5 textures,
    // @6..11 samplers" here silently drifted from the interleaved scheme the
    // codegen emits — Dawn rejected the mismatch ("binding type in the shader
    // (sampler) doesn't match the layout (texture)"). Deriving both the layout
    // and the bind group from `solveLayout` makes host-vs-WGSL drift impossible,
    // exactly like FsUbo above.
    // ============================================================================

    const PbrFsIo = @import("shaders/pbr_fs_io.zig");
    /// Texture binding for each material map, in `Samplers` declaration order
    /// (base color, metallic-roughness, normal, occlusion, emissive, shadow).
    /// The paired sampler sits at `+1`. Computed from the schema at comptime.
    const material_tex_bindings: [6]u32 = blk: {
        const layout = shader_introspect.solveLayout(PbrFsIo);
        var out: [6]u32 = undefined;
        var i: usize = 0;
        for (layout.fields) |fld| {
            if (fld.kind != .sampler_2d) {
                continue;
            }
            if (i >= out.len) {
                @compileError("pbr_fs_io.Samplers has more than 6 sampler fields — " ++
                    "update material_tex_bindings and the texture list in buildMaterialBindGroup.");
            }
            out[i] = fld.binding;
            i += 1;
        }
        if (i != 6) {
            @compileError("pbr_fs_io.Samplers must declare exactly 6 samplers " ++
                "(base color, metallic-roughness, normal, occlusion, emissive, shadow).");
        }
        break :blk out;
    };

    // One interleaved vertex buffer feeds five shader locations. The offsets are
    // the byte positions of each `Vertex` field.
    const vertex_layout = gpu.VertexBufferLayout{
        .array_stride = @sizeOf(Vertex),
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x3, .offset = 0, .shader_location = 0 }, // position
            .{ .format = .float32x2, .offset = 12, .shader_location = 1 }, // tex_coord
            .{ .format = .float32x3, .offset = 20, .shader_location = 2 }, // normal
            .{ .format = .float32x4, .offset = 32, .shader_location = 3 }, // color
            .{ .format = .float32x4, .offset = 48, .shader_location = 4 }, // tangent
        },
    };

    // ============================================================================
    // Renderer
    // ============================================================================

    pub const Renderer = struct {
        gpa: Allocator,
        device: wgpu.DeviceHandle,
        queue: wgpu.QueueHandle,
        depth_format: wgpu.TextureFormat,

        // group 0 (VS): five mat4 uniform buffers. group 2 (FS): one Ubo block.
        // These are RINGED across the frame: `draw()` advances `ubo_cursor` and
        // writes a fresh slot, so a frame that draws several models never writes
        // the same buffer twice (the queue-timeline clobber — every writeBuffer
        // lands before any pass runs, so a reused buffer would corrupt the
        // earlier draw's pass). Mirrors renderer_2d's ortho ring. One slot =
        // five VS UBOs + one FS UBO + their two bind groups.
        vs_uniform_buffers: [ubo_ring_len][5]wgpu.BufferHandle = @splat(@splat(.invalid)),
        fs_uniform_buffer: [ubo_ring_len]wgpu.BufferHandle = @splat(.invalid),
        vs_bind_group: [ubo_ring_len]wgpu.BindGroupHandle = @splat(.invalid),
        fs_bind_group: [ubo_ring_len]wgpu.BindGroupHandle = @splat(.invalid),
        /// Slot holding the CURRENT draw's UBOs. Advanced by `draw()`, reset to
        /// 0 by `beginFrame`. A wrap within one frame is asserted against
        /// (would clobber a slot an earlier recorded draw still references).
        ubo_cursor: u32 = 0,
        ubo_writes_this_frame: u32 = 0,

        pipeline: wgpu.RenderPipelineHandle = .invalid,
        pipeline_layout: wgpu.PipelineLayoutHandle = .invalid,
        vs_module: wgpu.ShaderModuleHandle = .invalid,
        fs_module: wgpu.ShaderModuleHandle = .invalid,

        // Neutral fallbacks for material slots a glTF leaves unset: opaque white
        // (1,1,1,1) for color/MR/AO/emissive + the shadow slot, and a flat
        // tangent-space normal (0.5,0.5,1) so an absent normal map yields the
        // geometric normal unchanged.
        white_texture: WgpuTexture = .{},
        flat_normal_texture: WgpuTexture = .{},
        // Neutral metallic-roughness fallback for a model with no MR map. glTF packs
        // metallic in B and roughness in G, so this is (R=255, G=255, B=0): metallic
        // 0, roughness 1 -- a plain matte dielectric. A *white* fallback here would
        // read B=255 -> metallic 1.0, zeroing the diffuse term (kD = 1-metallic) and
        // rendering an untextured model nearly black.
        default_mr_texture: WgpuTexture = .{},

        // Per-frame scratch, set by beginFrame and consumed by draw / endFrame.
        active_frame: ?*GpuFrame = null,
        pass: gpu_iface.PassState = undefined,
        frame_desc: FrameDesc = undefined,

        pub fn deinit(self: *Renderer) void {
            for (&self.vs_uniform_buffers) |*slot| {
                for (slot.*) |b| {
                    if (b != .invalid) {
                        wgpu.destroyBuffer(b);
                    }
                }
            }
            for (self.fs_uniform_buffer) |b| {
                if (b != .invalid) {
                    wgpu.destroyBuffer(b);
                }
            }
            for (self.vs_bind_group) |bg| {
                if (bg != .invalid) {
                    wgpu.destroyBindGroup(bg);
                }
            }
            for (self.fs_bind_group) |bg| {
                if (bg != .invalid) {
                    wgpu.destroyBindGroup(bg);
                }
            }
            if (self.pipeline != .invalid) {
                wgpu.destroyRenderPipeline(self.pipeline);
            }
            if (self.pipeline_layout != .invalid) {
                wgpu.destroyPipelineLayout(self.pipeline_layout);
            }
            if (self.vs_module != .invalid) {
                wgpu.destroyShaderModule(self.vs_module);
            }
            if (self.fs_module != .invalid) {
                wgpu.destroyShaderModule(self.fs_module);
            }
            self.white_texture.deinit();
            self.flat_normal_texture.deinit();
            self.default_mr_texture.deinit();
        }

        pub fn init(opts: InitOptions) !Renderer {
            assert(opts.vs_wgsl.len > 0 and opts.fs_wgsl.len > 0, @src());

            const device: wgpu.DeviceHandle = opts.device;
            const queue: wgpu.QueueHandle = opts.queue;
            const gpa: Allocator = opts.gpa;

            var self: Renderer = .{
                .gpa = gpa,
                .device = device,
                .queue = queue,
                .depth_format = opts.depth_format,
            };

            // The depth attachment is owned by the GpuFrame (auto-sized to the
            // surface), not by this renderer -- it arrives via the FrameContext in
            // beginFrame. We only need depth_format here to build the pipeline.

            // ---- neutral fallback textures ----
            const opaque_white: [4]u8 = .{ 0xff, 0xff, 0xff, 0xff };
            self.white_texture = try WgpuTexture.createCheckerboard(
                device,
                queue,
                gpa,
                opaque_white,
                opaque_white,
                8,
                1,
            );

            // A 1x1 RGB (128,128,255) decodes to the tangent-space +Z normal.
            const flat_normal_pixel: [4]u8 = .{ 128, 128, 255, 255 };
            self.flat_normal_texture = WgpuTexture.createFromPixels(device, queue, .{
                .pixels = &flat_normal_pixel,
                .width = 1,
                .height = 1,
                .format = .rgba8_unorm,
                .mag_filter_linear = false,
                .min_filter_linear = false,
                .address_mode = .repeat,
                .label = "pbr3d_flat_normal",
            });

            // A 1x1 (R=255, G=255, B=0): metallic 0 (B), roughness 1 (G) -- matte
            // dielectric, the right neutral for a model with no MR map.
            const default_mr_pixel: [4]u8 = .{ 255, 255, 0, 255 };
            self.default_mr_texture = WgpuTexture.createFromPixels(device, queue, .{
                .pixels = &default_mr_pixel,
                .width = 1,
                .height = 1,
                .format = .rgba8_unorm,
                .mag_filter_linear = false,
                .min_filter_linear = false,
                .address_mode = .repeat,
                .label = "pbr3d_default_mr",
            });

            // ---- group 0 + group 2: N ring slots, each 5 VS mat4 UBOs + 1 FS
            // UBO + their bind groups. NOT seeded: `draw()` fully writes every
            // buffer of the slot it uses before binding it, so a seed here would
            // be a dead write — and worse, since the launcher inits children
            // lazily inside update frame 0, a seed would land in the SAME frame
            // as the first draw's write and clobber it (the zimr534 hazard).
            // See the ring field docs. ----
            for (0..ubo_ring_len) |slot| {
                for (&self.vs_uniform_buffers[slot]) |*buffer| {
                    buffer.* = wgpu.createBuffer(device, .{
                        .size = mat4_bytes,
                        .usage = .{ .uniform = true, .copy_dst = true },
                        .label = "pbr3d_vs_ubo_ring",
                    });
                }
                self.fs_uniform_buffer[slot] = wgpu.createBuffer(device, .{
                    .size = shader_iface.wireSizeOf(FsUbo),
                    .usage = .{ .uniform = true, .copy_dst = true },
                    .label = "pbr3d_fs_ubo_ring",
                });
                self.vs_bind_group[slot] = try self.buildVsBindGroup(@intCast(slot));
                self.fs_bind_group[slot] = try self.buildFsBindGroup(@intCast(slot));
            }

            // ---- pipeline layout: group 0 (VS) + group 1 (material) + group 2 (FS) ----
            const vs_layout: wgpu.BindGroupLayoutHandle = try makeVsLayout(gpa, device);
            const material_layout: wgpu.BindGroupLayoutHandle = try makeMaterialLayout(gpa, device);
            const fs_layout: wgpu.BindGroupLayoutHandle = try makeFsLayout(gpa, device);
            const all_layouts: [3]wgpu.BindGroupLayoutHandle = .{ vs_layout, material_layout, fs_layout };
            self.pipeline_layout = wgpu.createPipelineLayout(device, all_layouts[0..], "pbr3d_pl");
            // The three group layouts were only needed to build the pipeline
            // layout (which is self-contained once created) — release them.
            wgpu.destroyBindGroupLayout(vs_layout);
            wgpu.destroyBindGroupLayout(material_layout);
            wgpu.destroyBindGroupLayout(fs_layout);

            // ---- shader modules + the render pipeline ----
            // Debug-only safety net: independently reflect the embedded FS WGSL's
            // @group/@binding declarations and compare them, cell by cell, to the
            // host layout `solveLayout(PbrFsIo)` produced (the same authority
            // `material_tex_bindings` uses). If they ever disagree — the exact
            // drift that shipped as Dawn's opaque "binding type in the shader
            // doesn't match the layout" — this names the cell in the console at
            // pipeline creation instead of leaving it to Dawn's cascade. Log-only
            // (never crashes) and compiled out of release builds.
            if (@import("builtin").mode == .Debug) {
                if (shader_introspect.layoutWgslMismatch(gpa, PbrFsIo, opts.fs_wgsl) catch null) |mm| {
                    std.log.warn(
                        "pbr3d host/WGSL layout drift: @group({d}) @binding({d}) '{s}' is {s} " ++
                            "in the WGSL but the host layout provides {s} there.",
                        .{ mm.group, mm.binding, mm.name, mm.found, mm.expected },
                    );
                }
            }
            self.vs_module = wgpu.createShaderModuleWgsl(device, opts.vs_wgsl, "pbr3d_vs");
            self.fs_module = wgpu.createShaderModuleWgsl(device, opts.fs_wgsl, "pbr3d_fs");

            const pipeline_state: gpu.StateCombo = gpu.StateCombo.fromParts(
                .triangle_list,
                .alpha,
                .less,
                opts.cull_mode,
                opts.surface_format,
                opts.depth_format,
                1,
            );
            const pipeline_descriptor: gpu.RenderPipelineDescriptor = .{
                .vertex_buffer_layouts = &.{vertex_layout},
                .vs_entry_point = "entry",
                .fs_entry_point = "entry",
                .state = pipeline_state,
            };
            const pipeline_blob: []const u8 = try gpu.encodeRenderPipelineDescriptor(
                gpa,
                pipeline_descriptor,
            );
            defer gpa.free(pipeline_blob);
            self.pipeline = wgpu.createRenderPipeline(
                device,
                self.pipeline_layout,
                self.vs_module,
                self.fs_module,
                pipeline_blob,
                "pbr3d_pipe",
            );

            return self;
        }

        /// Parse a glTF binary (.glb) into a `Model`: interleave the first mesh's
        /// geometry, generate tangents (the FS needs a TBN for normal mapping), and
        /// resolve + decode the five PBR maps through the primitive's material.
        pub fn loadGltf(self: *Renderer, glb: []const u8) !pbr3d.Model {
            const gpa: Allocator = self.gpa;

            var document: codecs.gltf.Data = try codecs.gltf.parse(gpa, glb);
            defer document.deinit();

            const cpu_mesh: CpuMesh = try buildCpuMesh(gpa, document);
            defer cpu_mesh.deinit(gpa);
            const vertices: []const Vertex = cpu_mesh.vertices;
            const indices: []const u16 = cpu_mesh.indices;
            const vertex_count: usize = vertices.len;
            const index_count: usize = indices.len;
            pageLog("pbr3d.loadGltf: verts={d} indices={d}", .{ vertex_count, index_count });

            // ---- upload geometry to GPU buffers ----
            const vertex_bytes: u64 = vertex_count * @sizeOf(Vertex);
            const vertex_buffer: wgpu.BufferHandle = wgpu.createBuffer(self.device, .{
                .size = vertex_bytes,
                .usage = .{ .vertex = true, .copy_dst = true },
                .label = "pbr3d_vbo",
            });
            wgpu.queueWriteBuffer(self.queue, vertex_buffer, 0, std.mem.sliceAsBytes(vertices));

            const index_bytes: u64 = index_count * @sizeOf(u16);
            const index_buffer: wgpu.BufferHandle = wgpu.createBuffer(self.device, .{
                .size = index_bytes,
                .usage = .{ .index = true, .copy_dst = true },
                .label = "pbr3d_ibo",
            });
            wgpu.queueWriteBuffer(self.queue, index_buffer, 0, std.mem.sliceAsBytes(indices));

            // ---- resolve the material: scalar factors first, then the maps ----
            const source_material: ?codecs.gltf.Material = firstPrimitiveMaterial(document);

            var material: pbr3d.Material = .{
                .base_color = self.white_texture,
                .metallic_roughness = self.default_mr_texture,
                .normal = self.flat_normal_texture,
                .occlusion = self.white_texture,
                .emissive = self.white_texture,
            };
            if (source_material) |gltf_material| {
                const factor: Vec = gltf_material.base_color_factor;
                material.base_color_factor = .{ factor[0], factor[1], factor[2], factor[3] };
                material.metallic_factor = gltf_material.metallic_factor;
                material.roughness_factor = gltf_material.roughness_factor;
                const emissive: Vec = gltf_material.emissive_factor;
                material.emissive_factor = .{ emissive[0], emissive[1], emissive[2] };
            }

            // Each slot resolves its own format + fallback inside resolveMap.
            material.base_color = self.resolveMap(document, source_material, .base_color);
            material.metallic_roughness = self.resolveMap(document, source_material, .metallic_roughness);
            material.normal = self.resolveMap(document, source_material, .normal);
            material.occlusion = self.resolveMap(document, source_material, .occlusion);
            material.emissive = self.resolveMap(document, source_material, .emissive);

            const material_bind_group: wgpu.BindGroupHandle = try self.buildMaterialBindGroup(material);

            return .{
                .vertex_buffer = vertex_buffer,
                .index_buffer = index_buffer,
                .vertex_bytes = vertex_bytes,
                .index_bytes = index_bytes,
                .index_count = @intCast(index_count),
                .material = material,
                .material_bind_group = material_bind_group,
            };
        }

        /// Load a Wavefront OBJ model. Parses + de-indexes + triangulates via
        /// `codecs.obj`, synthesizing smooth normals when the file omits them,
        /// and uploads with the renderer's default (untextured white) material.
        /// Materials (.mtl) are not consumed. Pairs with `draw` like loadGltf.
        pub fn loadObj(self: *Renderer, bytes: []const u8) !pbr3d.Model {
            const gpa: Allocator = self.gpa;

            var data: codecs.obj.Data = try codecs.obj.parse(gpa, bytes);
            defer data.deinit(gpa);
            var mesh: codecs.obj.Mesh = try data.toMesh(gpa);
            defer mesh.deinit(gpa);

            const vertex_count: usize = mesh.vertexCount();
            if (vertex_count > std.math.maxInt(u16)) {
                // The PBR pipeline indexes with u16. Bigger meshes need the
                // u32 index path (not yet wired) or decimation upstream.
                return error.TooManyVertices;
            }
            const vertices: []Vertex = try gpa.alloc(Vertex, vertex_count);
            defer gpa.free(vertices);
            var vi: usize = 0;
            while (vi < vertex_count) : (vi += 1) {
                vertices[vi] = .{
                    .position = .{
                        mesh.positions[vi * 3],
                        mesh.positions[vi * 3 + 1],
                        mesh.positions[vi * 3 + 2],
                    },
                    .tex_coord = .{ mesh.tex_coords[vi * 2], mesh.tex_coords[vi * 2 + 1] },
                    .normal = .{
                        mesh.normals[vi * 3],
                        mesh.normals[vi * 3 + 1],
                        mesh.normals[vi * 3 + 2],
                    },
                };
            }

            const indices: []u16 = try gpa.alloc(u16, mesh.indices.len);
            defer gpa.free(indices);
            for (mesh.indices, 0..) |idx, k| {
                indices[k] = @intCast(idx);
            }

            pageLog("pbr3d.loadObj: verts={d} indices={d}", .{ vertex_count, indices.len });
            return self.uploadDefaultMesh(vertices, indices);
        }

        /// Upload an interleaved `Vertex` array + u16 indices to GPU buffers and
        /// pair them with the renderer's default (white) material. Shared by
        /// loaders that carry no material of their own (e.g. `loadObj`). Kept
        /// separate from `loadGltf`'s inline upload so that device-tested path
        /// is untouched.
        fn uploadDefaultMesh(
            self: *Renderer,
            vertices: []const Vertex,
            indices: []const u16,
        ) !pbr3d.Model {
            const vertex_bytes: u64 = vertices.len * @sizeOf(Vertex);
            const vertex_buffer: wgpu.BufferHandle = wgpu.createBuffer(self.device, .{
                .size = vertex_bytes,
                .usage = .{ .vertex = true, .copy_dst = true },
                .label = "pbr3d_obj_vbo",
            });
            wgpu.queueWriteBuffer(self.queue, vertex_buffer, 0, std.mem.sliceAsBytes(vertices));

            // WebGPU requires writeBuffer sizes to be a multiple of 4. u16
            // indices hit that only when the count is even; an odd count (e.g.
            // the bunny's 208,353) gives 2-mod-4 bytes. Pad the buffer to an
            // even index count — the extra slot is never drawn (index_count
            // below stays the real count).
            const real_index_count: usize = indices.len;
            const padded_index_count: usize = real_index_count + (real_index_count & 1);
            const index_bytes: u64 = padded_index_count * @sizeOf(u16);
            const index_buffer: wgpu.BufferHandle = wgpu.createBuffer(self.device, .{
                .size = index_bytes,
                .usage = .{ .index = true, .copy_dst = true },
                .label = "pbr3d_obj_ibo",
            });
            if (real_index_count != padded_index_count) {
                const padded: []u16 = try self.gpa.alloc(u16, padded_index_count);
                defer self.gpa.free(padded);
                @memcpy(padded[0..real_index_count], indices);
                padded[real_index_count] = 0;
                wgpu.queueWriteBuffer(self.queue, index_buffer, 0, std.mem.sliceAsBytes(padded));
            } else {
                wgpu.queueWriteBuffer(self.queue, index_buffer, 0, std.mem.sliceAsBytes(indices));
            }

            const material: pbr3d.Material = .{
                .base_color = self.white_texture,
                .metallic_roughness = self.default_mr_texture,
                .normal = self.flat_normal_texture,
                .occlusion = self.white_texture,
                .emissive = self.white_texture,
            };
            const material_bind_group: wgpu.BindGroupHandle = try self.buildMaterialBindGroup(material);

            const index_count: u32 = @intCast(indices.len);
            return .{
                .vertex_buffer = vertex_buffer,
                .index_buffer = index_buffer,
                .vertex_bytes = vertex_bytes,
                .index_bytes = index_bytes,
                .index_count = index_count,
                .material = material,
                .material_bind_group = material_bind_group,
            };
        }

        pub fn beginFrame(
            self: *Renderer,
            frame: *GpuFrame,
            desc: FrameDesc,
        ) void {
            self.active_frame = frame;
            self.frame_desc = desc;
            // Fresh frame: recorded draws from the prior frame are sealed, so
            // every ring slot is reusable again. Reset the cursor + budget.
            self.ubo_cursor = 0;
            self.ubo_writes_this_frame = 0;

            // Ensure the frame carries a depth attachment matching the pipeline
            // (built with self.depth_format). Without this, a frame whose
            // depth_format was never set has no depth texture, so the pass opens
            // depth-less and the pass/pipeline depth states mismatch — WebGPU
            // silently invalidates the pass (black). ensureDepth (in
            // Backend.beginFrame) creates the texture lazily and is idempotent.
            frame.depth_format = self.depth_format;

            const frame_context = Backend.beginFrame(frame);
            self.pass = Backend.beginRenderPass(frame_context.encoder, .{
                .color_view = frame_context.surface_view,
                .clear = .{ .r = desc.clear.r, .g = desc.clear.g, .b = desc.clear.b, .a = desc.clear.a },
                .depth_view = frame_context.depth_view,
            });
            self.pass.queue = frame.queue;

            Backend.setPipeline(&self.pass, shader.RenderPipeline(void, void){ .gpu_handle = self.pipeline });
            Backend.setBindGroup(&self.pass, 0, self.vs_bind_group[0]);
            Backend.setBindGroup(&self.pass, 2, self.fs_bind_group[0]);
        }

        pub fn draw(
            self: *Renderer,
            model: pbr3d.Model,
            model_matrix: Mat,
        ) void {
            const frame: *GpuFrame = self.active_frame orelse return;
            const camera: Camera = self.frame_desc.camera;

            // Advance to a fresh ring slot so this draw's UBOs never overwrite a
            // buffer an earlier-recorded draw in this frame still references
            // (the queue-timeline clobber). A wrap within one frame is a bug.
            self.ubo_cursor = (self.ubo_cursor + 1) % ubo_ring_len;
            self.ubo_writes_this_frame += 1;
            assertf(
                self.ubo_writes_this_frame <= ubo_ring_len,
                @src(),
                "pbr3d UBO ring overflow: {d} model draws in one frame (ring holds {d}). " ++
                    "Raise draw3d.ubo_ring_len.",
                .{ self.ubo_writes_this_frame, ubo_ring_len },
            );
            const slot: u32 = self.ubo_cursor;

            // group 0 slots: model@0, view@1, projection@2, normal@3, light-space@4.
            // The normal matrix equals the model matrix here (uniform scale only);
            // the light-space matrix is identity since shadows are gated off.
            var model_value: Mat = model_matrix;
            var view_value: Mat = camera.view;
            var projection_value: Mat = camera.proj;
            var identity_value: Mat = identity();
            wgpu.queueWriteBuffer(frame.queue, self.vs_uniform_buffers[slot][0], 0, std.mem.asBytes(&model_value));
            wgpu.queueWriteBuffer(frame.queue, self.vs_uniform_buffers[slot][1], 0, std.mem.asBytes(&view_value));
            wgpu.queueWriteBuffer(frame.queue, self.vs_uniform_buffers[slot][2], 0, std.mem.asBytes(&projection_value));
            wgpu.queueWriteBuffer(frame.queue, self.vs_uniform_buffers[slot][3], 0, std.mem.asBytes(&model_value));
            wgpu.queueWriteBuffer(frame.queue, self.vs_uniform_buffers[slot][4], 0, std.mem.asBytes(&identity_value));

            // group 2: scene lights (this frame) + the model's material factors.
            const ubo: FsUbo = self.buildUbo(model.material);
            const ubo_bytes: [shader_iface.wireSizeOf(FsUbo)]u8 = shader_iface.wireOf(FsUbo, &ubo);
            wgpu.queueWriteBuffer(frame.queue, self.fs_uniform_buffer[slot], 0, &ubo_bytes);

            // Bind THIS slot's groups (overriding beginFrame's slot-0 binding).
            Backend.setBindGroup(&self.pass, 0, self.vs_bind_group[slot]);
            Backend.setBindGroup(&self.pass, 2, self.fs_bind_group[slot]);
            Backend.setBindGroup(&self.pass, 1, model.material_bind_group);
            render_pass.setVertexBuffer(self.pass.pass, .{
                .slot = 0,
                .buffer = model.vertex_buffer,
                .offset = 0,
                .size = model.vertex_bytes,
            });
            render_pass.setIndexBuffer(self.pass.pass, .{
                .buffer = model.index_buffer,
                .format = .uint16,
                .offset = 0,
                .size = model.index_bytes,
            });
            render_pass.drawIndexed(self.pass.pass, .{
                .index_count = model.index_count,
                .instance_count = 1,
                .first_index = 0,
                .base_vertex = 0,
                .first_instance = 0,
            });

            // One-shot: report the first draw's shape so the page log shows the
            // geometry actually reached drawIndexed (vs being culled / no-op'd).
            const Once = struct {
                var logged: bool = false;
            };
            if (!Once.logged) {
                Once.logged = true;
                pageLog("pbr3d.draw: index_count={d} eye=({d:.1},{d:.1},{d:.1})", .{
                    model.index_count, camera.eye[0], camera.eye[1], camera.eye[2],
                });
            }
        }

        pub fn endFrame(self: *Renderer) void {
            Backend.endRenderPass(&self.pass);
            if (self.active_frame) |frame| {
                Backend.endFrame(frame);
            }
            self.active_frame = null;
        }

        /// Draw the model into the APP's CURRENT render pass instead of pbr3d
        /// owning its own frame.  The sanctioned composite pattern wraps this in a
        /// render-texture pass:
        ///
        ///   z.beginTextureMode(gl, rt, clear);   // pass now targets the RTT
        ///   renderer.drawInApp(gl, desc, model, m);
        ///   z.endTextureMode(gl);                // fresh backbuffer pass, 2D rebound
        ///
        /// `endTextureMode` reopens the backbuffer pass and re-binds the 2D
        /// pipeline, so pbr3d's pipeline/bind-group state can't leak into later
        /// 2D draws (the bug the old draw-into-the-frame-pass usage had).  The
        /// renderer's `surface_format` must match the pass target (the RTT's
        /// format — `.rgba8_unorm` for `loadRenderTexture`), and the target needs
        /// a depth attachment matching `depth_format`.  No present here: the
        /// app's `endDrawing` finishes the frame.
        pub fn drawInApp(
            self: *Renderer,
            gl: anytype,
            frame: *gpu.GpuFrame,
            desc: FrameDesc,
            model: pbr3d.Model,
            model_matrix: Mat,
        ) void {
            // S2: duck-typed `gl` + explicit frame — pbr3d no longer reaches
            // into wgpu_app (appOf), which would cycle once it lives in draw3d.
            self.active_frame = frame;
            self.frame_desc = desc;
            // One-shot draw into the app's pass: reset the ring so this draw
            // takes slot 1 (draw() pre-increments from 0). The initial slot-0
            // binding below is immediately overridden by draw().
            self.ubo_cursor = 0;
            self.ubo_writes_this_frame = 0;
            self.pass = gl.pass.*;
            self.pass.queue = frame.queue;
            Backend.setPipeline(&self.pass, shader.RenderPipeline(void, void){ .gpu_handle = self.pipeline });
            Backend.setBindGroup(&self.pass, 0, self.vs_bind_group[0]);
            Backend.setBindGroup(&self.pass, 2, self.fs_bind_group[0]);
            self.draw(model, model_matrix);
            self.active_frame = null;
        }

        // ------------------------------------------------------------------------
        // Per-draw uniform assembly
        // ------------------------------------------------------------------------

        fn buildUbo(self: *Renderer, material: pbr3d.Material) FsUbo {
            const light: Light = self.frame_desc.light;
            const camera: Camera = self.frame_desc.camera;

            // Normalize the light direction once; the shader expects a unit vector.
            const direction: [3]f32 = light.dir;
            const dir_x_sq: f32 = direction[0] * direction[0];
            const dir_y_sq: f32 = direction[1] * direction[1];
            const dir_z_sq: f32 = direction[2] * direction[2];
            const len: f32 = @sqrt(dir_x_sq + dir_y_sq + dir_z_sq);
            const inverse_length: f32 = 1.0 / len;
            const unit_direction: Vec = .{
                direction[0] * inverse_length,
                direction[1] * inverse_length,
                direction[2] * inverse_length,
                0,
            };

            var ubo: FsUbo = .{
                .col_diffuse = .{
                    material.base_color_factor[0],
                    material.base_color_factor[1],
                    material.base_color_factor[2],
                    material.base_color_factor[3],
                },
                .view_pos = .{ camera.eye[0], camera.eye[1], camera.eye[2], 0 },
                .ambient_color = .{ light.ambient[0], light.ambient[1], light.ambient[2], 0 },
                .emissive_factor = .{
                    material.emissive_factor[0],
                    material.emissive_factor[1],
                    material.emissive_factor[2],
                    0,
                },
                .metallic_factor = material.metallic_factor,
                .roughness_factor = material.roughness_factor,
                .directional_light_count = 1,
                .fog_far = 100,
            };
            ubo.directional_light_dir[0] = unit_direction;
            ubo.directional_light_color[0] = .{ light.color[0], light.color[1], light.color[2], 1 };
            return ubo;
        }

        // ------------------------------------------------------------------------
        // Bind groups
        // ------------------------------------------------------------------------

        fn buildVsBindGroup(self: *Renderer, slot: u32) !wgpu.BindGroupHandle {
            const layout: wgpu.BindGroupLayoutHandle = try makeVsLayout(self.gpa, self.device);
            var entries: [5]gpu.BindGroupEntry = undefined;
            for (&entries, 0..) |*entry, i| {
                entry.* = .{
                    .binding = @intCast(i),
                    .resource = .{ .buffer = .{ .handle = self.vs_uniform_buffers[slot][i], .size = mat4_bytes } },
                };
            }
            const blob: []const u8 = try gpu.encodeBindGroupEntries(self.gpa, &entries);
            defer self.gpa.free(blob);
            const bg: wgpu.BindGroupHandle = wgpu.createBindGroup(self.device, layout, blob, "pbr3d_vs_bg");
            wgpu.destroyBindGroupLayout(layout); // build-only
            return bg;
        }

        fn buildFsBindGroup(self: *Renderer, slot: u32) !wgpu.BindGroupHandle {
            const layout: wgpu.BindGroupLayoutHandle = try makeFsLayout(self.gpa, self.device);
            const entries = [_]gpu.BindGroupEntry{.{
                .binding = 0,
                .resource = .{ .buffer = .{
                    .handle = self.fs_uniform_buffer[slot],
                    .size = shader_iface.wireSizeOf(FsUbo),
                } },
            }};
            const blob: []const u8 = try gpu.encodeBindGroupEntries(self.gpa, &entries);
            defer self.gpa.free(blob);
            const bg: wgpu.BindGroupHandle = wgpu.createBindGroup(self.device, layout, blob, "pbr3d_fs_bg");
            wgpu.destroyBindGroupLayout(layout); // build-only
            return bg;
        }

        fn buildMaterialBindGroup(self: *Renderer, material: pbr3d.Material) !wgpu.BindGroupHandle {
            const layout: wgpu.BindGroupLayoutHandle = try makeMaterialLayout(self.gpa, self.device);

            // The FS sampler order is fixed: 0 base, 1 MR, 2 normal, 3 AO,
            // 4 emissive, 5 shadow. The shadow slot reuses the white fallback
            // (shadows are gated off).
            const textures = [6]WgpuTexture{
                material.base_color,
                material.metallic_roughness,
                material.normal,
                material.occlusion,
                material.emissive,
                self.white_texture,
            };

            // Each map binds a texture view at material_tex_bindings[i] and its
            // sampler at +1 — same schema-derived scheme as makeMaterialLayout
            // and the WGSL.
            var entries: [12]gpu.BindGroupEntry = undefined;
            for (textures, 0..) |texture, i| {
                entries[2 * i] = .{
                    .binding = material_tex_bindings[i],
                    .resource = .{ .texture_view = texture.view },
                };
                entries[2 * i + 1] = .{
                    .binding = material_tex_bindings[i] + 1,
                    .resource = .{ .sampler = texture.sampler },
                };
            }
            const blob: []const u8 = try gpu.encodeBindGroupEntries(self.gpa, &entries);
            defer self.gpa.free(blob);
            const bg: wgpu.BindGroupHandle = wgpu.createBindGroup(self.device, layout, blob, "pbr3d_material_bg");
            // The layout was only needed to build the bind group — release it.
            wgpu.destroyBindGroupLayout(layout);
            return bg;
        }

        // ------------------------------------------------------------------------
        // Texture resolution
        // ------------------------------------------------------------------------

        /// Decode the embedded image a material slot points at and upload it, or
        /// return `fallback` when the slot is unset / points at an external or
        /// undecodable image.
        fn resolveMap(
            self: *Renderer,
            document: codecs.gltf.Data,
            source_material: ?codecs.gltf.Material,
            slot: MaterialSlot,
        ) WgpuTexture {
            // ClearColor maps decode as sRGB; the data maps (MR / normal / AO) stay linear.
            const format: wgpu.TextureFormat = switch (slot) {
                .base_color, .emissive => .rgba8_unorm_srgb,
                .metallic_roughness, .normal, .occlusion => .rgba8_unorm,
            };
            // Each slot has its own neutral fallback: a flat normal, a matte-
            // dielectric MR, and opaque white for the rest.
            const fallback: WgpuTexture = switch (slot) {
                .normal => self.flat_normal_texture,
                .metallic_roughness => self.default_mr_texture,
                else => self.white_texture,
            };

            const decoded: DecodedMap = decodeMaterialMap(self.gpa, document, source_material, slot) orelse
                return fallback;
            defer decoded.deinit(self.gpa);
            pageLog("pbr3d.resolveMap: {s} = {d}x{d}", .{ @tagName(slot), decoded.width, decoded.height });
            return self.uploadMap(decoded.pixels, decoded.width, decoded.height, format);
        }

        fn uploadMap(
            self: *Renderer,
            pixels: []const u8,
            width: u32,
            height: u32,
            format: wgpu.TextureFormat,
        ) WgpuTexture {
            return WgpuTexture.createFromPixels(self.device, self.queue, .{
                .pixels = pixels,
                .width = width,
                .height = height,
                .format = format,
                .mag_filter_linear = true,
                .min_filter_linear = true,
                .address_mode = .repeat, // glTF UVs may tile (the helmet's V runs [1,2])
                .label = "pbr3d_map",
            });
        }
    };

    // ============================================================================
    // Free helpers
    // ============================================================================

    pub const MaterialSlot = enum { base_color, metallic_roughness, normal, occlusion, emissive };

    /// A material map decoded to RGBA8 on the CPU.  `decodeMaterialMap`
    /// produces these; the GPU path uploads-and-frees, the software-
    /// rasterizer path keeps (or downsamples) the pixels for `TextureRef`
    /// sampling.  Caller owns `pixels` (`deinit` frees).
    pub const DecodedMap = struct {
        pixels: []u8,
        width: u32,
        height: u32,

        pub fn deinit(self: DecodedMap, gpa: Allocator) void {
            gpa.free(self.pixels);
        }
    };

    /// Walk texture-ref → image → buffer-view → bytes for `slot` and decode
    /// the embedded PNG/JPEG to RGBA8.  Returns null when the slot is unset,
    /// points at an external/undecodable image, or any index is out of range
    /// — callers substitute their own neutral fallback.  Pure CPU; both the
    /// GPU upload path (`resolveMap`) and the software-renderer material
    /// loader call this, so the two halves of a side-by-side decode the
    /// SAME bytes.
    pub fn decodeMaterialMap(
        gpa: Allocator,
        document: codecs.gltf.Data,
        source_material: ?codecs.gltf.Material,
        slot: MaterialSlot,
    ) ?DecodedMap {
        const texture_index: ?u32 = textureRef(source_material, slot);
        const index: u32 = texture_index orelse return null;
        if (index >= document.textures.len) {
            return null;
        }
        const image_index: u32 = document.textures[index].source orelse return null;
        if (image_index >= document.images.len) {
            return null;
        }
        const img: codecs.gltf.Image = document.images[image_index];
        const buffer_view_index: u32 = img.buffer_view orelse return null;
        if (buffer_view_index >= document.buffer_views.len) {
            return null;
        }
        const buffer_view: codecs.gltf.BufferView = document.buffer_views[buffer_view_index];
        const buffer_data: []const u8 = document.buffers[buffer_view.buffer].data orelse return null;
        const byte_start: usize = buffer_view.byte_offset;
        const byte_end: usize = byte_start + buffer_view.byte_length;
        const image_bytes: []const u8 = buffer_data[byte_start..byte_end];

        // png.Image and jpeg.Image are distinct types with identical fields,
        // so each branch hands its pixels off on its own.
        const is_png: bool = if (img.mime_type) |mime| std.mem.indexOf(u8, mime, "png") != null else false;
        if (is_png) {
            const decoded: codecs.png.Image = codecs.png.decode(gpa, image_bytes) catch return null;
            return .{ .pixels = decoded.pixels, .width = decoded.width, .height = decoded.height };
        }
        const decoded: codecs.jpeg.Image = codecs.jpeg.decode(gpa, image_bytes) catch return null;
        return .{ .pixels = decoded.pixels, .width = decoded.width, .height = decoded.height };
    }

    /// The material backing the first mesh's first primitive, if any.
    pub fn firstPrimitiveMaterial(document: codecs.gltf.Data) ?codecs.gltf.Material {
        if (document.meshes.len == 0) {
            return null;
        }
        const primitives: []codecs.gltf.Primitive = document.meshes[0].primitives;
        if (primitives.len == 0) {
            return null;
        }
        const material_index: u32 = primitives[0].material orelse return null;
        if (material_index >= document.materials.len) {
            return null;
        }
        return document.materials[material_index];
    }

    /// The `Data.textures` index a material slot points at, if any.
    fn textureRef(source_material: ?codecs.gltf.Material, slot: MaterialSlot) ?u32 {
        const material: codecs.gltf.Material = source_material orelse return null;
        return switch (slot) {
            .base_color => material.base_color_texture,
            .metallic_roughness => material.metallic_roughness_texture,
            .normal => material.normal_texture,
            .occlusion => material.occlusion_texture,
            .emissive => material.emissive_texture,
        };
    }

    // group 0: five mat4 VS uniform buffers.
    fn makeVsLayout(gpa: Allocator, device: wgpu.DeviceHandle) !wgpu.BindGroupLayoutHandle {
        var entries: [5]shader_introspect.BindGroupLayoutEntry = undefined;
        for (&entries, 0..) |*entry, i| {
            entry.* = .{
                .binding = @intCast(i),
                .visibility = .{ .vertex = true },
                .resource = .{ .uniform_buffer = .{ .min_size = mat4_bytes } },
            };
        }
        const blob: []const u8 = try gpu.encodeBindGroupLayoutEntries(gpa, &entries);
        defer gpa.free(blob);
        return wgpu.createBindGroupLayout(device, blob, "pbr3d_vs_layout");
    }

    // group 1: six {texture at material_tex_bindings[i], sampler at +1} pairs,
    // derived from the pbr_fs_io schema (same authority as the WGSL).
    fn makeMaterialLayout(gpa: Allocator, device: wgpu.DeviceHandle) !wgpu.BindGroupLayoutHandle {
        var entries: [12]shader_introspect.BindGroupLayoutEntry = undefined;
        for (material_tex_bindings, 0..) |tex_binding, i| {
            entries[2 * i] = .{
                .binding = tex_binding,
                .visibility = .{ .fragment = true },
                .resource = .{ .texture = .{} },
            };
            entries[2 * i + 1] = .{
                .binding = tex_binding + 1,
                .visibility = .{ .fragment = true },
                .resource = .{ .sampler = .{} },
            };
        }
        const blob: []const u8 = try gpu.encodeBindGroupLayoutEntries(gpa, &entries);
        defer gpa.free(blob);
        return wgpu.createBindGroupLayout(device, blob, "pbr3d_material_layout");
    }

    // group 2: one FS uniform block (the Ubo) @binding 0.
    fn makeFsLayout(gpa: Allocator, device: wgpu.DeviceHandle) !wgpu.BindGroupLayoutHandle {
        const entries = [_]shader_introspect.BindGroupLayoutEntry{.{
            .binding = 0,
            .visibility = .{ .fragment = true },
            .resource = .{ .uniform_buffer = .{ .min_size = shader_iface.wireSizeOf(FsUbo) } },
        }};
        const blob: []const u8 = try gpu.encodeBindGroupLayoutEntries(gpa, &entries);
        defer gpa.free(blob);
        return wgpu.createBindGroupLayout(device, blob, "pbr3d_fs_layout");
    }

    /// Flat per-face normals for a glTF that ships none: each triangle's geometric
    /// normal (normalized edge cross-product) is written to all three of its
    /// vertices. Shared vertices end up with the last face's normal, which is fine
    /// for the flat-shaded look these attribute-less models expect.
    fn synthesizeFlatNormals(vertices: []Vertex, indices: []const u16) void {
        var triangle_start: usize = 0;
        while (triangle_start + 2 < indices.len) : (triangle_start += 3) {
            const ia: usize = @intCast(indices[triangle_start]);
            const ib: usize = @intCast(indices[triangle_start + 1]);
            const ic: usize = @intCast(indices[triangle_start + 2]);

            const p0: [3]f32 = vertices[ia].position;
            const p1: [3]f32 = vertices[ib].position;
            const p2: [3]f32 = vertices[ic].position;
            const edge1: Vec3 = .{ p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2] };
            const edge2: Vec3 = .{ p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2] };

            // cross(edge1, edge2) is the unnormalized face normal.
            const cross_x: f32 = edge1[1] * edge2[2] - edge1[2] * edge2[1];
            const cross_y: f32 = edge1[2] * edge2[0] - edge1[0] * edge2[2];
            const cross_z: f32 = edge1[0] * edge2[1] - edge1[1] * edge2[0];
            const len: f32 = @sqrt(cross_x * cross_x + cross_y * cross_y + cross_z * cross_z);
            const face_normal: [3]f32 = if (len > 1e-8)
                .{ cross_x / len, cross_y / len, cross_z / len }
            else
                .{ 0, 1, 0 };

            vertices[ia].normal = face_normal;
            vertices[ib].normal = face_normal;
            vertices[ic].normal = face_normal;
        }
    }

    /// Per-vertex tangents from positions + UVs (Lengyel's method): accumulate a
    /// per-triangle tangent/bitangent into each of its vertices, then Gram-Schmidt
    /// the tangent against the normal and pick the handedness sign. Writes
    /// `Vertex.tangent` (xyz direction + w sign).
    fn computeTangents(
        vertices: []Vertex,
        indices: []const u16,
        gpa: Allocator,
    ) void {
        const vertex_count: usize = vertices.len;
        const tangents: []Vec3 = gpa.alloc(Vec3, vertex_count) catch @panic("oom (tangents)");
        defer gpa.free(tangents);
        const bitangents: []Vec3 = gpa.alloc(Vec3, vertex_count) catch @panic("oom (bitangents)");
        defer gpa.free(bitangents);
        @memset(tangents, Vec3{ 0, 0, 0 });
        @memset(bitangents, Vec3{ 0, 0, 0 });

        // ---- accumulate per-triangle tangent/bitangent into each vertex ----
        var triangle_start: usize = 0;
        while (triangle_start + 2 < indices.len) : (triangle_start += 3) {
            const ia: usize = @intCast(indices[triangle_start]);
            const ib: usize = @intCast(indices[triangle_start + 1]);
            const ic: usize = @intCast(indices[triangle_start + 2]);

            const p0: [3]f32 = vertices[ia].position;
            const p1: [3]f32 = vertices[ib].position;
            const p2: [3]f32 = vertices[ic].position;
            const uv0: [2]f32 = vertices[ia].tex_coord;
            const uv1: [2]f32 = vertices[ib].tex_coord;
            const uv2: [2]f32 = vertices[ic].tex_coord;

            const edge1: Vec3 = .{ p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2] };
            const edge2: Vec3 = .{ p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2] };
            const duv1_x: f32 = uv1[0] - uv0[0];
            const duv1_y: f32 = uv1[1] - uv0[1];
            const duv2_x: f32 = uv2[0] - uv0[0];
            const duv2_y: f32 = uv2[1] - uv0[1];

            // Degenerate UV triangle -> no usable tangent basis; skip it.
            const det: f32 = duv1_x * duv2_y - duv2_x * duv1_y;
            if (@abs(det) < 1e-12) {
                continue;
            }
            const inverse_determinant: f32 = 1.0 / det;

            const triangle_tangent: Vec3 = .{
                (edge1[0] * duv2_y - edge2[0] * duv1_y) * inverse_determinant,
                (edge1[1] * duv2_y - edge2[1] * duv1_y) * inverse_determinant,
                (edge1[2] * duv2_y - edge2[2] * duv1_y) * inverse_determinant,
            };
            const triangle_bitangent: Vec3 = .{
                (edge2[0] * duv1_x - edge1[0] * duv2_x) * inverse_determinant,
                (edge2[1] * duv1_x - edge1[1] * duv2_x) * inverse_determinant,
                (edge2[2] * duv1_x - edge1[2] * duv2_x) * inverse_determinant,
            };
            for ([_]usize{ ia, ib, ic }) |vertex_index| {
                tangents[vertex_index] = .{
                    tangents[vertex_index][0] + triangle_tangent[0],
                    tangents[vertex_index][1] + triangle_tangent[1],
                    tangents[vertex_index][2] + triangle_tangent[2],
                };
                bitangents[vertex_index] = .{
                    bitangents[vertex_index][0] + triangle_bitangent[0],
                    bitangents[vertex_index][1] + triangle_bitangent[1],
                    bitangents[vertex_index][2] + triangle_bitangent[2],
                };
            }
        }

        // ---- orthonormalize each accumulated tangent against its normal ----
        for (vertices, 0..) |*vertex, i| {
            const normal: [3]f32 = vertex.normal;
            const accumulated: Vec3 = tangents[i];

            // Gram-Schmidt: subtract the normal-parallel component.
            const nx_tx: f32 = normal[0] * accumulated[0];
            const ny_ty: f32 = normal[1] * accumulated[1];
            const nz_tz: f32 = normal[2] * accumulated[2];
            const normal_dot_tangent: f32 = nx_tx + ny_ty + nz_tz;
            var tx: f32 = accumulated[0] - normal[0] * normal_dot_tangent;
            var ty: f32 = accumulated[1] - normal[1] * normal_dot_tangent;
            var tz: f32 = accumulated[2] - normal[2] * normal_dot_tangent;

            const tangent_length: f32 = @sqrt(tx * tx + ty * ty + tz * tz);
            if (tangent_length > 1e-8) {
                tx /= tangent_length;
                ty /= tangent_length;
                tz /= tangent_length;
            } else {
                // No usable tangent accumulated; fall back to an arbitrary axis.
                tx = 1;
                ty = 0;
                tz = 0;
            }

            // Handedness: w = sign(dot(cross(N, T), accumulated bitangent)).
            const cross_x: f32 = normal[1] * tz - normal[2] * ty;
            const cross_y: f32 = normal[2] * tx - normal[0] * tz;
            const cross_z: f32 = normal[0] * ty - normal[1] * tx;
            const bitangent: Vec3 = bitangents[i];
            const handedness_dot: f32 = cross_x * bitangent[0] + cross_y * bitangent[1] + cross_z * bitangent[2];
            const sign: f32 = if (handedness_dot < 0) -1 else 1;

            vertex.tangent = .{ tx, ty, tz, sign };
        }
    }
};

// ===========================================================================
// STRUCTURE-PLAN S2 (t1177): former src/draw_points.zig folded in as a
// section namespace.  One-way deps only; the umbrella re-exports keep the
// public `z.draw_points` shape unchanged.
// ===========================================================================
pub const draw_points = struct {
    // draw_points.zig — `z.DrawPoints`: zero-copy instanced rendering of points read
    // straight from a GPU storage buffer (the positions a compute kernel wrote). A
    // tiny instanced pipeline whose vertex shader reads `pos[instance_index]` from the
    // buffer (`var<storage, read>` — vertex-stage storage is allowed read-only) and
    // emits a screen-space quad. No CPU readback: the data never leaves the GPU.
    //
    //     var dp = try z.DrawPoints.init(f.gpu, gpa, dev, queue, fmt, pipe.storageBuffer().?, bytes);
    //     // each frame, between beginDrawing/endDrawing:
    //     dp.draw(f.gl, count, sw, sh, .{ .size_px = 3 });
    const gpu_iface = @import("gpu_iface.zig");
    const WgpuGl = @import("WgpuGl.zig");

    // WGSL emitted from `src/shaders/points_vs.zig` + `points_fs.zig` (pure-Zig
    // @SpirvType → SPIR-V → spv2wgsl), embedded by build.zig's shader
    // auto-discovery loop. The storage buffer is read-only (spv2wgsl auto-emits
    // `var<storage, read>` for the vertex stage). Entry point is `entry` for both.
    const points_vs_wgsl = @embedFile("points_vs.wgsl");
    const points_fs_wgsl = @embedFile("points_fs.wgsl");

    const Uniforms = extern struct {
        half_ndc: [2]f32,
        pad: [2]f32 = .{ 0, 0 },
        top: [4]f32,
        bot: [4]f32,
    };

    // Merged binding schema for `Resources`: the UBO at group 0 binding 0 and
    // the read-only position storage buffer at group 0 binding 1 — the same
    // layout the VS shader (`points_vs_io.zig`) declares and emits. `Resources`
    // auto-generates the matching bind-group layout + bind group from this, so
    // the host no longer hand-writes them. (Attributes/Builtins live in the
    // shader's own `_io.zig` and don't bind, so they're omitted here.)
    const PointsSchema = struct {
        pub const Ubo = Uniforms;
        pub const Storage = struct {
            positions: shader_iface.StorageBuf(zm.Vec2, .read),
        };
    };

    pub const Options = struct {
        size_px: f32 = 3.0,
        top: [4]f32 = .{ 0.25, 0.9, 1.0, 1.0 },
        bot: [4]f32 = .{ 0.85, 0.3, 1.0, 1.0 },
    };

    pub const DrawPoints = struct {
        pipeline: wgpu.RenderPipelineHandle,
        resources: shader.Resources(PointsSchema),
        queue: wgpu.QueueHandle,
        pos_buffer: wgpu.BufferHandle,

        /// Build the instanced points pipeline bound to `pos_buffer` (the storage a
        /// compute kernel writes; read as `array<vec2<f32>>`). `pos_bytes` is the bound
        /// size (typically `@sizeOf(M.Buffers)` when pos is the first field).
        pub fn init(
            f: *gpu.GpuFrame,
            gpa: Allocator,
            dev: wgpu.DeviceHandle,
            queue: wgpu.QueueHandle,
            color_format: wgpu.TextureFormat,
            pos_buffer: wgpu.BufferHandle,
            pos_bytes: u32,
        ) !DrawPoints {
            const vs_module: wgpu.ShaderModuleHandle =
                wgpu.createShaderModuleWgsl(dev, points_vs_wgsl, "draw_points_vs");
            const fs_module: wgpu.ShaderModuleHandle =
                wgpu.createShaderModuleWgsl(dev, points_fs_wgsl, "draw_points_fs");

            // `Resources` auto-generates the UBO buffer + the bind-group layout
            // and bind group (UBO at binding 0, positions storage at binding 1)
            // from `PointsSchema`. The host supplies only the caller-owned
            // position buffer; everything else is derived from the schema.
            const resources = try shader.Resources(PointsSchema).init(gpa, f, .{
                .positions = .{ .handle = pos_buffer, .size = pos_bytes },
            });

            const pl: wgpu.PipelineLayoutHandle =
                wgpu.createPipelineLayout(dev, &.{resources.bg_layouts[0]}, "draw_points_pl");
            const state: gpu.StateCombo = gpu.StateCombo.fromParts(
                .triangle_list,
                .alpha,
                .none,
                .none,
                color_format,
                .undefined_,
                1,
            );
            const pdesc = gpu.RenderPipelineDescriptor{
                .vertex_buffer_layouts = &.{},
                .vs_entry_point = "entry",
                .fs_entry_point = "entry",
                .state = state,
            };
            const blob: []const u8 = try gpu.encodeRenderPipelineDescriptor(gpa, pdesc);
            defer gpa.free(blob);
            const pipeline: wgpu.RenderPipelineHandle = wgpu.createRenderPipeline(
                dev,
                pl,
                vs_module,
                fs_module,
                blob,
                "draw_points",
            );
            // Build-only intermediates: WebGPU internalized them into `pipeline`.
            wgpu.destroyPipelineLayout(pl);
            wgpu.destroyShaderModule(vs_module);
            wgpu.destroyShaderModule(fs_module);
            return .{
                .pipeline = pipeline,
                .resources = resources,
                .queue = queue,
                .pos_buffer = pos_buffer,
            };
        }

        /// Free the render pipeline + its `Resources` (UBO buffer + bind group +
        /// layout). Does NOT touch `pos_buffer` — that's the caller's compute
        /// storage buffer, borrowed zero-copy and freed by the `Compute` pipeline.
        pub fn deinit(self: *DrawPoints) void {
            wgpu.destroyRenderPipeline(self.pipeline);
            self.resources.deinit();
        }

        /// Draw `count` instanced points into the active 2D pass. Flushes the 2D batch,
        /// draws the points pipeline, then re-binds the 2D pipeline so later draws/text
        /// keep working. Call between `beginDrawing` and `endDrawing`.
        pub fn draw(
            self: *DrawPoints,
            gl: *WgpuGl,
            count: u32,
            screen_w: f32,
            screen_h: f32,
            opts: Options,
        ) void {
            self.resources.writeUbo(.{
                .half_ndc = .{ opts.size_px / screen_w, opts.size_px / screen_h },
                .top = opts.top,
                .bot = opts.bot,
            });
            const ps: *gpu_iface.PassState = gl.pass;
            gpu_iface.WgpuBackend.flushBatch(ps);
            // Cache-aware binds keep ps.current_* honest, so `bindForPass` below
            // actually restores the 2D pipeline + ortho group-0. A raw
            // render_pass bind here would desync the dedup cache and make the
            // restore a no-op (the draw_points_pl vs ortho_ring error). See
            // `setPipelineHandle`; the `raw-pass-state-bind` lint enforces this.
            gpu_iface.WgpuBackend.setPipelineHandle(ps, self.pipeline);
            gpu_iface.WgpuBackend.setBindGroup(ps, 0, self.resources.bind_groups[0]);
            render_pass.draw(ps.pass, .{ .vertex_count = 6, .instance_count = count });
            gl.renderer().bindForPass(ps); // restore the 2D pipeline for subsequent draws/text
        }

        /// Overwrite the bound position buffer with host-computed positions (e.g. the
        /// CPU backend's result) so the next `draw` renders them through the same
        /// instanced path. GPU-compute callers never need this — the kernel writes the
        /// buffer on-device (that's the zero-copy path). `pos_bytes` go to offset 0.
        pub fn uploadPositions(self: *DrawPoints, pos_bytes: []const u8) void {
            wgpu.queueWriteBuffer(self.queue, self.pos_buffer, 0, pos_bytes);
        }
    };

    // ------------------------------------------------------------------------
    // FluidDiscs — instanced SDF discs for pixel-space particle fields
    // (t1178, built for the GPU fluid). Same zero-copy idea as DrawPoints,
    // three upgrades: positions are in SIM PIXELS (a domain uniform maps to
    // NDC), each instance is a soft-edged SDF disc instead of a flat quad,
    // and colour is driven by a per-particle scalar (density) read from the
    // SAME storage buffer via an element-index base — `positions` is bound as
    // one big array<vec2<f32>> over the whole Buffers struct, so any vec2
    // field is reachable as `positions[base + ii]` with zero extra bindings
    // and zero offset-alignment constraints.
    // ------------------------------------------------------------------------
    // WGSL generated from typed pure-Zig shaders src/shaders/fluid_discs_{vs,fs}.zig
    // (@SpirvType → SPIR-V → spv2wgsl; two read-only storage buffers in the VS).
    // Auto-discovered + wired as anonymous imports by build.zig. Entry point
    // `entry` for both. The FS's original `if (r>1) discard` is reproduced by the
    // smoothstep edge fade (alpha→0 outside the disc — see fluid_discs_fs.zig).
    const fluid_discs_vs_wgsl = @embedFile("fluid_discs_vs.wgsl");
    const fluid_discs_fs_wgsl = @embedFile("fluid_discs_fs.wgsl");

    const FluidUniforms = extern struct {
        scale: [2]f32,
        offset: [2]f32,
        inv_logical: [2]f32,
        half_px: [2]f32,
        lo: [4]f32,
        hi: [4]f32,
        density_scale: f32,
        pad0: f32 = 0,
        pad1: f32 = 0,
        pad2: f32 = 0,
    };

    // Merged binding schema for `Resources`: the UBO at group 0 binding 0 and
    // two read-only storage buffers (`positions` at binding 1, `density` at
    // binding 2) — the same layout `fluid_discs_vs_io.zig` declares and emits.
    // `Resources` auto-generates the bind-group layout + bind group from this.
    const FluidSchema = struct {
        pub const Ubo = FluidUniforms;
        pub const Storage = struct {
            positions: shader_iface.StorageBuf(zm.Vec2, .read),
            density: shader_iface.StorageBuf(zm.Vec2, .read),
        };
    };

    pub const FluidOptions = struct {
        /// Disc radius in SIM pixels (scaled to NDC via the screen size).
        radius_px: f32 = 5.5,
        /// 1 / density-at-full-colour.
        density_scale: f32 = 1.0 / 24.0,
        lo: [4]f32 = .{ 0.10, 0.35, 0.95, 0.95 },
        hi: [4]f32 = .{ 0.65, 0.95, 1.0, 1.0 },
    };

    /// A region of a GPU buffer to bind: handle + byte offset + byte size.
    /// Offsets into storage bindings must respect the device's storage-buffer
    /// offset alignment (256 by default) — field offsets in the kompute
    /// per-field layout and `Buffers`-shaped mirror buffers all satisfy it.
    pub const BufRegion = struct {
        handle: wgpu.BufferHandle,
        offset: u64 = 0,
        size: u64,
    };

    pub const FluidDiscs = struct {
        pipeline: wgpu.RenderPipelineHandle,
        resources: shader.Resources(FluidSchema),
        queue: wgpu.QueueHandle,
        dom_w: f32,
        dom_h: f32,

        /// `buffer` is the compute storage buffer (whole Buffers struct,
        /// pos first); `buf_bytes` its full size; `dom_w/h` the sim domain
        /// in pixels (the VS maps domain → NDC).
        pub fn init(
            f: *gpu.GpuFrame,
            gpa: Allocator,
            dev: wgpu.DeviceHandle,
            queue: wgpu.QueueHandle,
            color_format: wgpu.TextureFormat,
            depth_format: wgpu.TextureFormat,
            pos: BufRegion,
            density: BufRegion,
            dom_w: f32,
            dom_h: f32,
        ) !FluidDiscs {
            const vs_module: wgpu.ShaderModuleHandle =
                wgpu.createShaderModuleWgsl(dev, fluid_discs_vs_wgsl, "fluid_discs_vs");
            const fs_module: wgpu.ShaderModuleHandle =
                wgpu.createShaderModuleWgsl(dev, fluid_discs_fs_wgsl, "fluid_discs_fs");

            // `Resources` auto-generates the UBO buffer + bind-group layout and
            // bind group (UBO@0, positions@1, density@2) from `FluidSchema`.
            // The host supplies the two caller-owned storage regions (handle +
            // offset + size); everything else is derived from the schema.
            const resources = try shader.Resources(FluidSchema).init(gpa, f, .{
                .positions = .{ .handle = pos.handle, .offset = pos.offset, .size = pos.size },
                .density = .{ .handle = density.handle, .offset = density.offset, .size = density.size },
            });

            const pl: wgpu.PipelineLayoutHandle =
                wgpu.createPipelineLayout(dev, &.{resources.bg_layouts[0]}, "fluid_discs_pl");
            // Match the pass's depth attachment: a passive depth-stencil
            // (`always`, no real test) when the frame has depth (e.g. as a
            // launcher child whose host frame is depth-enabled), or none when it
            // doesn't. A mismatch here invalidates the pass (black-screen).
            const depth_mode: wgpu.DepthMode = if (depth_format == .undefined_) .none else .always;
            const state: gpu.StateCombo = gpu.StateCombo.fromParts(
                .triangle_list,
                .alpha,
                depth_mode,
                .none,
                color_format,
                depth_format,
                1,
            );
            const pdesc = gpu.RenderPipelineDescriptor{
                .vertex_buffer_layouts = &.{},
                .vs_entry_point = "entry",
                .fs_entry_point = "entry",
                .state = state,
            };
            const blob: []const u8 = try gpu.encodeRenderPipelineDescriptor(gpa, pdesc);
            defer gpa.free(blob);
            const pipeline: wgpu.RenderPipelineHandle = wgpu.createRenderPipeline(
                dev,
                pl,
                vs_module,
                fs_module,
                blob,
                "fluid_discs",
            );
            // Build-only handles: the pipeline retains its layout + modules
            // internally, so release the source handles now (one pipeline, no
            // later rebuilds). Explicit ownership — no program-lifetime leak.
            // Same discipline as compute_host's kernel build loop.
            wgpu.destroyShaderModule(vs_module);
            wgpu.destroyShaderModule(fs_module);
            wgpu.destroyPipelineLayout(pl);
            return .{
                .pipeline = pipeline,
                .resources = resources,
                .queue = queue,
                .dom_w = dom_w,
                .dom_h = dom_h,
            };
        }

        /// Draw `count` discs into the active 2D pass (flush + restore, the
        /// DrawPoints pass discipline). `screen_w/h` are the render-target
        /// pixels; the disc radius is in SIM pixels and scales with the
        /// domain→screen mapping.
        /// The aspect-fit mapping from sim pixels into the logical viewport:
        /// scale = min(logical/dom), centered. Shared by `draw` (forward) and
        /// `simFromLogical` (inverse, for input coordinates).
        pub fn fitScaleOffset(
            self: *const FluidDiscs,
            logical_w: f32,
            logical_h: f32,
        ) [2][2]f32 {
            const sc: f32 = @min(logical_w / self.dom_w, logical_h / self.dom_h);
            const ox: f32 = (logical_w - self.dom_w * sc) * 0.5;
            const oy: f32 = (logical_h - self.dom_h * sc) * 0.5;
            return .{ .{ sc, sc }, .{ ox, oy } };
        }

        /// Map a LOGICAL-pixel point (e.g. the mouse) into SIM pixels.
        pub fn simFromLogical(
            self: *const FluidDiscs,
            logical_w: f32,
            logical_h: f32,
            p: [2]f32,
        ) [2]f32 {
            const so: [2][2]f32 = self.fitScaleOffset(logical_w, logical_h);
            return .{ (p[0] - so[1][0]) / so[0][0], (p[1] - so[1][1]) / so[0][1] };
        }

        /// Free the render pipeline + its `Resources` (UBO buffer + bind group +
        /// layout). Mirrors `DrawPoints.deinit`; the borrowed storage buffer is
        /// the caller's compute buffer, freed by the `Compute` pipeline.
        pub fn deinit(self: *FluidDiscs) void {
            wgpu.destroyRenderPipeline(self.pipeline);
            self.resources.deinit();
        }

        pub fn draw(
            self: *FluidDiscs,
            gl: *WgpuGl,
            count: u32,
            screen_w: f32,
            screen_h: f32,
            opts: FluidOptions,
        ) void {
            const so: [2][2]f32 = self.fitScaleOffset(screen_w, screen_h);
            self.resources.writeUbo(.{
                .scale = so[0],
                .offset = so[1],
                .inv_logical = .{ 1.0 / screen_w, 1.0 / screen_h },
                .half_px = .{ opts.radius_px * so[0][0], opts.radius_px * so[0][1] },
                .lo = opts.lo,
                .hi = opts.hi,
                .density_scale = opts.density_scale,
            });
            const ps: *gpu_iface.PassState = gl.pass;
            gpu_iface.WgpuBackend.flushBatch(ps);
            // Cache-aware binds (see DrawPoints / setPipelineHandle).
            gpu_iface.WgpuBackend.setPipelineHandle(ps, self.pipeline);
            gpu_iface.WgpuBackend.setBindGroup(ps, 0, self.resources.bind_groups[0]);
            render_pass.draw(ps.pass, .{ .vertex_count = 6, .instance_count = count });
            gl.renderer().bindForPass(ps);
        }
    };
};

test "getScreenToWorldRay: center pixel looks down the camera axis" {
    const cam: zm.Camera3D = .{
        .position = .{ 0, 2, 5, 0 },
        .target = .{ 0, 0, 0, 0 },
        .up = .{ 0, 1, 0, 0 },
        .fovy_deg = 45,
    };
    const ray: Ray = getScreenToWorldRay(.{ 400, 300 }, cam, 800, 600);
    // Direction must match normalize(target - position).
    const want: Vec = normalize4(cam.target - cam.position);
    try expectApproxEqAbs(want[0], ray.direction[0], 1.0e-4);
    try expectApproxEqAbs(want[1], ray.direction[1], 1.0e-4);
    try expectApproxEqAbs(want[2], ray.direction[2], 1.0e-4);
    // And a sphere sitting at the target must be hit.
    const hit: RayCollision = getRayCollisionSphere(ray, .{ 0, 0, 0, 0 }, 0.5);
    try expect(hit.hit);
}

test "getScreenToWorldRay: corner pixel diverges from the axis" {
    const cam: zm.Camera3D = .{
        .position = .{ 0, 0, 5, 0 },
        .target = .{ 0, 0, 0, 0 },
        .up = .{ 0, 1, 0, 0 },
        .fovy_deg = 60,
    };
    const ray: Ray = getScreenToWorldRay(.{ 0, 0 }, cam, 800, 600);
    // Top-left pixel: ray tips up (+y) and left (-x) in this frame.
    try expect(ray.direction[1] > 0.1);
    try expect(ray.direction[0] < -0.1);
}

test "pbr3d material bindings are the schema-derived interleaved pairs" {
    // The material layout (makeMaterialLayout) and bind group
    // (buildMaterialBindGroup) both index material_tex_bindings; the WGSL
    // derives its @group(1) bindings from the SAME solveLayout. Lock the
    // interleaved scheme (texture at 2i, sampler at 2i+1) so a future schema
    // edit that reorders/adds samplers can't silently reintroduce the host-vs-
    // WGSL drift Dawn rejected ("binding type ... doesn't match the layout").
    try expectEqual(@as(usize, 6), pbr3d.material_tex_bindings.len);
    const expected: [6]u32 = .{ 0, 2, 4, 6, 8, 10 };
    for (pbr3d.material_tex_bindings, expected) |got, want| {
        try expectEqual(want, got);
    }
    // And every texture binding must leave its +1 sampler slot free of the next
    // texture — i.e. strictly increasing by at least 2.
    var prev: i64 = -2;
    for (pbr3d.material_tex_bindings) |b| {
        try expect(@as(i64, b) >= prev + 2);
        prev = @as(i64, b);
    }
}
