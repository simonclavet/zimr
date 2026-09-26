//! mesh_bake - bake a DECIMATED glTF proxy into a generated `.zig` const.
//!
//! The comptime corner of the helmet side-by-side needs geometry the
//! COMPILER can rasterize: the full 15k-tri mesh is far past any sane
//! comptime budget, and the GLB parse is allocator-based (runtime-only).
//! So this build-step tool parses the GLB natively, vertex-cluster
//! decimates it to a few hundred triangles, bakes the base-color map down
//! to a small RGBA8 block, and emits everything as `pub const` arrays the
//! example imports as the anonymous module `helmet_proxy`.
//!
//! Decimation is plain VERTEX CLUSTERING: snap each vertex to a uniform
//! `grid^3` lattice over the mesh bbox, average position/normal/uv per
//! occupied cell, re-index the triangles onto the cluster representatives,
//! then drop degenerates (two-plus corners in one cell) and duplicate
//! triangles (sorted-id key).  Crude but exactly right for a ~48px inset:
//! the silhouette reads as THE helmet, and the comptime budget stays small.
//!
//! Tangents are deliberately ABSENT: the corner binds a 1x1 flat normal
//! map, so the shader's TBN collapses to the geometric normal and any
//! placeholder tangent works - the example supplies `(1,0,0,1)`.
//!
//! Usage: mesh_bake <in.glb> <out.zig> <grid> <tex_edge>

const std = @import("std");
const zm = @import("zm");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const codecs = @import("codecs");

const Cluster = struct {
    pos_sum: [3]f64 = .{ 0, 0, 0 },
    normal_sum: [3]f64 = .{ 0, 0, 0 },
    uv_sum: [2]f64 = .{ 0, 0 },
    count: u32 = 0,
};

const DecodedImage = struct {
    pixels: []u8,
    width: u32,
    height: u32,
};

/// The same texture walk `pbr3d.decodeMaterialMap` does, narrowed to the
/// base-color slot (this tool can't import pbr3d - it drags the whole
/// wgpu surface into a host exe).
fn decodeBaseColor(
    gpa: Allocator,
    document: codecs.gltf.Data,
    source_material: ?codecs.gltf.Material,
) ?DecodedImage {
    const material: codecs.gltf.Material = source_material orelse return null;
    const index: u32 = material.base_color_texture orelse return null;
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
    const image_bytes: []const u8 = buffer_data[buffer_view.byte_offset..][0..buffer_view.byte_length];
    const is_png: bool = if (img.mime_type) |mime| std.mem.indexOf(u8, mime, "png") != null else false;
    if (is_png) {
        const decoded: codecs.png.Image = codecs.png.decode(gpa, image_bytes) catch return null;
        return .{ .pixels = decoded.pixels, .width = decoded.width, .height = decoded.height };
    }
    const decoded: codecs.jpeg.Image = codecs.jpeg.decode(gpa, image_bytes) catch return null;
    return .{ .pixels = decoded.pixels, .width = decoded.width, .height = decoded.height };
}

/// Decode the material's base-color image and box-filter it down to
/// `tex_edge^2` RGBA8.  A neutral mid-grey block when the material has no
/// base-color texture (keeps the generated file shape stable).
fn bakeBaseColor(
    gpa: Allocator,
    document: codecs.gltf.Data,
    material: ?codecs.gltf.Material,
    tex_edge: u32,
) ![]u8 {
    const fallback_len: usize = @as(usize, tex_edge) * tex_edge * 4;
    const decoded: DecodedImage = decodeBaseColor(gpa, document, material) orelse {
        const grey: []u8 = try gpa.alloc(u8, fallback_len);
        @memset(grey, 180);
        var px: usize = 3;
        while (px < grey.len) : (px += 4) {
            grey[px] = 255;
        }
        return grey;
    };
    // Integer box filter, power-of-two factor - same scheme the example's
    // runtime CPU half uses, so the corner's texels are a coarser version
    // of the SAME data.
    var factor: u32 = 1;
    while (decoded.width / (factor * 2) >= tex_edge and decoded.height / (factor * 2) >= tex_edge) {
        factor *= 2;
    }
    const dst_w: u32 = @max(decoded.width / factor, 1);
    const dst_h: u32 = @max(decoded.height / factor, 1);
    const dst: []u8 = try gpa.alloc(u8, @as(usize, dst_w) * dst_h * 4);
    const samples: u32 = factor * factor;
    var dy: u32 = 0;
    while (dy < dst_h) : (dy += 1) {
        var dx: u32 = 0;
        while (dx < dst_w) : (dx += 1) {
            var acc: [4]u64 = .{ 0, 0, 0, 0 };
            var sy: u32 = 0;
            while (sy < factor) : (sy += 1) {
                var sx: u32 = 0;
                while (sx < factor) : (sx += 1) {
                    const si: usize = (@as(usize, dy * factor + sy) * decoded.width + (dx * factor + sx)) * 4;
                    acc[0] += decoded.pixels[si];
                    acc[1] += decoded.pixels[si + 1];
                    acc[2] += decoded.pixels[si + 2];
                    acc[3] += decoded.pixels[si + 3];
                }
            }
            const di: usize = (@as(usize, dy) * dst_w + dx) * 4;
            dst[di] = @intCast(acc[0] / samples);
            dst[di + 1] = @intCast(acc[1] / samples);
            dst[di + 2] = @intCast(acc[2] / samples);
            dst[di + 3] = @intCast(acc[3] / samples);
        }
    }
    if (dst_w != tex_edge or dst_h != tex_edge) {
        return error.UnexpectedTextureShape;
    }
    return dst;
}

const Decimated = struct {
    clusters: std.AutoArrayHashMapUnmanaged(u32, Cluster),
    out_indices: ArrayList(u16),
};

/// Vertex-cluster decimation (the format-neutral core shared by the glTF and
/// OBJ front-ends): pass 1 bbox, pass 2 snap each vertex to a `grid^3` lattice
/// cell and average pos/normal/uv per occupied cell, pass 3 re-index triangles
/// onto the cluster representatives, dropping degenerate + duplicate tris.
/// `texcoords` is null for geometry-only sources (OBJ); uv_sum stays zero.
fn decimate(
    gpa: Allocator,
    vertices: []const f32,
    normals: []const f32,
    texcoords: ?[]const f32,
    indices: []const u32,
    vertex_count: usize,
    grid: u32,
) !Decimated {
    // ---- pass 1: bbox ----
    var bb_min: [3]f32 = .{ zm.floatMax(f32), zm.floatMax(f32), zm.floatMax(f32) };
    var bb_max: [3]f32 = .{ -zm.floatMax(f32), -zm.floatMax(f32), -zm.floatMax(f32) };
    var vi: usize = 0;
    while (vi < vertex_count) : (vi += 1) {
        var axis: usize = 0;
        while (axis < 3) : (axis += 1) {
            const v: f32 = vertices[vi * 3 + axis];
            bb_min[axis] = @min(bb_min[axis], v);
            bb_max[axis] = @max(bb_max[axis], v);
        }
    }

    // ---- pass 2: snap each vertex to its lattice cell, accumulate ----
    const grid_f: f32 = @floatFromInt(grid);
    const cell_of_vertex: []u32 = try gpa.alloc(u32, vertex_count);
    var clusters: std.AutoArrayHashMapUnmanaged(u32, Cluster) = .empty;
    vi = 0;
    while (vi < vertex_count) : (vi += 1) {
        var cell: [3]u32 = .{ 0, 0, 0 };
        var axis: usize = 0;
        while (axis < 3) : (axis += 1) {
            const extent: f32 = bb_max[axis] - bb_min[axis];
            if (extent > 0) {
                const t: f32 = (vertices[vi * 3 + axis] - bb_min[axis]) / extent;
                cell[axis] = @trunc(@min(t * grid_f, grid_f - 1));
            }
        }
        const key: u32 = cell[0] + cell[1] * grid + cell[2] * grid * grid;
        const slot: @TypeOf(clusters).GetOrPutResult = try clusters.getOrPutValue(gpa, key, .{});
        cell_of_vertex[vi] = @intCast(slot.index);
        const c: *Cluster = slot.value_ptr;
        c.count += 1;
        axis = 0;
        while (axis < 3) : (axis += 1) {
            c.pos_sum[axis] += vertices[vi * 3 + axis];
            c.normal_sum[axis] += normals[vi * 3 + axis];
        }
        if (texcoords) |uv| {
            c.uv_sum[0] += uv[vi * 2];
            c.uv_sum[1] += uv[vi * 2 + 1];
        }
    }

    // ---- pass 3: re-index triangles, drop degenerates + duplicates ----
    var out_indices: ArrayList(u16) = .empty;
    var seen_triangles: std.AutoHashMapUnmanaged(u64, void) = .empty;
    const index_count: usize = indices.len;
    var ti: usize = 0;
    while (ti + 2 < index_count) : (ti += 3) {
        const a: u32 = cell_of_vertex[indices[ti]];
        const b: u32 = cell_of_vertex[indices[ti + 1]];
        const c: u32 = cell_of_vertex[indices[ti + 2]];
        if (a == b or b == c or a == c) {
            continue;
        }
        var sorted: [3]u32 = .{ a, b, c };
        std.mem.sort(u32, &sorted, {}, std.sort.asc(u32));
        const tri_key: u64 = (@as(u64, sorted[0]) << 42) | (@as(u64, sorted[1]) << 21) | sorted[2];
        const entry: @TypeOf(seen_triangles).GetOrPutResult = try seen_triangles.getOrPut(gpa, tri_key);
        if (entry.found_existing) {
            continue;
        }
        try out_indices.append(gpa, @intCast(a));
        try out_indices.append(gpa, @intCast(b));
        try out_indices.append(gpa, @intCast(c));
    }

    return .{ .clusters = clusters, .out_indices = out_indices };
}

/// Emit the geometry block shared by both proxy shapes: `vertex_count`,
/// per-cluster averaged `positions` + normalized `normals`, and the decimated
/// `indices`.  The glTF path emits `uvs` + the base-color texture after this.
fn emitProxyGeometry(
    w: *std.Io.Writer,
    clusters: std.AutoArrayHashMapUnmanaged(u32, Cluster),
    out_indices: []const u16,
) !void {
    const cluster_count: usize = clusters.count();
    try w.print("pub const vertex_count: usize = {d};\n", .{cluster_count});

    try w.print("pub const positions: [{d}][3]f32 = .{{\n", .{cluster_count});
    for (clusters.values()) |c| {
        const count_f: f64 = @floatFromInt(c.count);
        const inv: f64 = 1.0 / count_f;
        try w.print("    .{{ {e}, {e}, {e} }},\n", .{
            @as(f32, @floatCast(c.pos_sum[0] * inv)),
            @as(f32, @floatCast(c.pos_sum[1] * inv)),
            @as(f32, @floatCast(c.pos_sum[2] * inv)),
        });
    }
    try w.print("}};\n", .{});

    try w.print("pub const normals: [{d}][3]f32 = .{{\n", .{cluster_count});
    for (clusters.values()) |c| {
        var n: [3]f64 = .{ c.normal_sum[0], c.normal_sum[1], c.normal_sum[2] };
        const len: f64 = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
        if (len > 1e-12) {
            n = .{ n[0] / len, n[1] / len, n[2] / len };
        } else {
            n = .{ 0, 1, 0 };
        }
        try w.print("    .{{ {e}, {e}, {e} }},\n", .{
            @as(f32, @floatCast(n[0])),
            @as(f32, @floatCast(n[1])),
            @as(f32, @floatCast(n[2])),
        });
    }
    try w.print("}};\n", .{});

    try w.print("pub const indices: [{d}]u16 = .{{", .{out_indices.len});
    for (out_indices, 0..) |index_value, k| {
        if (k % 24 == 0) {
            try w.print("\n    ", .{});
        }
        try w.print("{d}, ", .{index_value});
    }
    try w.print("\n}};\n", .{});
}

/// OBJ front-end: parse + de-index + triangulate, then decimate to a
/// geometry-only proxy (positions/normals/indices - no material, no UVs).
/// The Stanford bunny and friends land here; `tex_edge` is unused.
fn bakeObj(
    gpa: Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    in_path: []const u8,
    out_path: []const u8,
    grid: u32,
) !void {
    const obj_bytes: []const u8 = try cwd.readFileAlloc(io, in_path, gpa, .unlimited);
    var data: codecs.obj.Data = try codecs.obj.parse(gpa, obj_bytes);
    defer data.deinit(gpa);
    const mesh: codecs.obj.Mesh = try data.toMesh(gpa);
    defer mesh.deinit(gpa);
    const vertex_count: usize = mesh.vertexCount();
    const dec: Decimated = try decimate(gpa, mesh.positions, mesh.normals, null, mesh.indices, vertex_count, grid);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w: *std.Io.Writer = &aw.writer;
    try w.print(
        \\//! GENERATED by tools/mesh_bake.zig (OBJ path) — do not edit.
        \\//! Vertex-cluster-decimated OBJ proxy for the comptime corner:
        \\//! {d} clusters, {d} triangles (from {d} verts / {d} tris).
        \\//! Geometry-only: positions / normals / indices (no material, no UVs).
        \\
        \\
    , .{ dec.clusters.count(), dec.out_indices.items.len / 3, vertex_count, mesh.indices.len / 3 });
    try emitProxyGeometry(w, dec.clusters, dec.out_indices.items);
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = aw.written() });
}

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const gpa: Allocator = arena_state.allocator();
    const io: std.Io = init.io;

    var args_list: ArrayList([]u8) = .empty;
    var arg_it: std.process.Args.Iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    while (arg_it.next()) |arg| {
        try args_list.append(gpa, try gpa.dupe(u8, arg));
    }
    const args: [][]u8 = args_list.items;
    if (args.len != 5) {
        return error.BadArgs;
    }
    const grid: u32 = try std.fmt.parseInt(u32, args[3], 10);
    const tex_edge: u32 = try std.fmt.parseInt(u32, args[4], 10);
    if (grid < 2 or grid > 64) {
        return error.GridOutOfRange;
    }

    const cwd: std.Io.Dir = std.Io.Dir.cwd();

    // OBJ front-end: geometry-only proxy (no material/UVs).  Same decimator and
    // the same emitted positions/normals/indices shape as the glTF path below.
    if (std.mem.endsWith(u8, args[1], ".obj")) {
        try bakeObj(gpa, io, cwd, args[1], args[2], grid);
        return;
    }

    // ---- glTF front-end (with base-color texture bake) ----
    const glb_bytes: []const u8 = try cwd.readFileAlloc(io, args[1], gpa, .unlimited);
    const document: codecs.gltf.Data = try codecs.gltf.parse(gpa, glb_bytes);
    const meshes: []codecs.types.Mesh = try codecs.gltf.meshesFromGltf(gpa, document);
    if (meshes.len == 0) {
        return error.NoMesh;
    }
    const mesh: codecs.types.Mesh = meshes[0];
    if (mesh.normals == null or mesh.texcoords == null) {
        return error.MeshMissingAttributes;
    }
    const vertex_count: usize = @intCast(mesh.vertexCount);
    const index_count: usize = @as(usize, @intCast(mesh.triangleCount)) * 3;
    const src_indices: []const u16 = @as([*]const u16, @ptrCast(mesh.indices))[0..index_count];
    const idx_u32: []u32 = try gpa.alloc(u32, index_count);
    for (src_indices, 0..) |iv, k| {
        idx_u32[k] = iv;
    }
    const dec: Decimated = try decimate(
        gpa,
        mesh.vertices[0 .. vertex_count * 3],
        mesh.normals[0 .. vertex_count * 3],
        mesh.texcoords[0 .. vertex_count * 2],
        idx_u32,
        vertex_count,
        grid,
    );

    // ---- base color: walk material -> texture -> image, decode, downsample ----
    var material: ?codecs.gltf.Material = null;
    if (document.meshes.len > 0 and document.meshes[0].primitives.len > 0) {
        if (document.meshes[0].primitives[0].material) |mat_index| {
            if (mat_index < document.materials.len) {
                material = document.materials[mat_index];
            }
        }
    }
    const baked_tex: []u8 = try bakeBaseColor(gpa, document, material, tex_edge);

    // ---- emit ----
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w: *std.Io.Writer = &aw.writer;
    const cluster_count: usize = dec.clusters.count();
    try w.print(
        \\//! GENERATED by tools/mesh_bake.zig — do not edit.
        \\//! Vertex-cluster-decimated glTF proxy for the comptime corner:
        \\//! {d} clusters, {d} triangles (from {d} verts / {d} tris), plus the
        \\//! base-color map box-filtered to {d}².  Imported as `helmet_proxy`.
        \\
        \\
    , .{ cluster_count, dec.out_indices.items.len / 3, vertex_count, index_count / 3, tex_edge });

    try emitProxyGeometry(w, dec.clusters, dec.out_indices.items);

    try w.print("pub const uvs: [{d}][2]f32 = .{{\n", .{cluster_count});
    for (dec.clusters.values()) |c| {
        const count_f: f64 = @floatFromInt(c.count);
        const inv: f64 = 1.0 / count_f;
        try w.print("    .{{ {e}, {e} }},\n", .{
            @as(f32, @floatCast(c.uv_sum[0] * inv)),
            @as(f32, @floatCast(c.uv_sum[1] * inv)),
        });
    }
    try w.print("}};\n", .{});

    try w.print("pub const tex_edge: u32 = {d};\n", .{tex_edge});
    try w.print("pub const base_color: [{d}]u8 = .{{", .{baked_tex.len});
    for (baked_tex, 0..) |byte, k| {
        if (k % 32 == 0) {
            try w.print("\n    ", .{});
        }
        try w.print("{d}, ", .{byte});
    }
    try w.print("\n}};\n", .{});

    const mat: codecs.gltf.Material = material orelse .{};
    try w.print("pub const base_color_factor: [4]f32 = .{{ {e}, {e}, {e}, {e} }};\n", .{
        mat.base_color_factor[0],
        mat.base_color_factor[1],
        mat.base_color_factor[2],
        mat.base_color_factor[3],
    });
    try w.print("pub const metallic_factor: f32 = {e};\n", .{mat.metallic_factor});
    try w.print("pub const roughness_factor: f32 = {e};\n", .{mat.roughness_factor});

    try cwd.writeFile(io, .{ .sub_path = args[2], .data = aw.written() });
}
