//! Host-only one-shot probe: load DamagedHelmet.glb through our
//! glTF parser and report success / specific failure mode.  Run with:
//!
//!     zig run scripts/probe_damaged_helmet.zig --dep zimr -Mroot=. \
//!         -Mzimr=src/zimr.zig
//!
//! (Or just `zig test` against it.)  Goal: get the specific Error
//! variant from `codecs.gltf.parse` without round-tripping through
//! the browser.

const std = @import("std");
const Allocator = std.mem.Allocator;
const codecs = @import("src/codecs.zig");
const types = @import("src/types.zig");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa: Allocator = gpa_state.allocator();

    const bytes: []u8 = try std.fs.cwd().readFileAlloc(
        gpa,
        "examples/assets/DamagedHelmet.glb",
        16 * 1024 * 1024,
    );
    defer gpa.free(bytes);

    std.debug.print("loaded {d} bytes from DamagedHelmet.glb\n", .{bytes.len});
    std.debug.print("first 12 bytes: ", .{});
    for (bytes[0..12]) |b| {
        std.debug.print("{x:0>2} ", .{b});
    }
    std.debug.print("\n", .{});

    var data: codecs.gltf.Data = codecs.gltf.parse(gpa, bytes) catch |err| {
        std.debug.print("\n!!! codecs.gltf.parse FAILED: {s}\n", .{@errorName(err)});
        return err;
    };
    defer data.deinit();

    std.debug.print("\n=== PARSE SUCCESS ===\n", .{});
    std.debug.print("asset.version:    {s}\n", .{data.asset.version});
    std.debug.print("asset.generator:  {?s}\n", .{data.asset.generator});
    std.debug.print("meshes:           {d}\n", .{data.meshes.len});
    std.debug.print("accessors:        {d}\n", .{data.accessors.len});
    std.debug.print("buffers:          {d}\n", .{data.buffers.len});
    std.debug.print("buffer_views:     {d}\n", .{data.buffer_views.len});
    std.debug.print("materials:        {d}\n", .{data.materials.len});
    std.debug.print("textures:         {d}\n", .{data.textures.len});
    std.debug.print("images:           {d}\n", .{data.images.len});

    // Try meshesFromGltf too.
    const meshes: []types.Mesh = codecs.gltf.meshesFromGltf(gpa, data) catch |err| {
        std.debug.print("\n!!! meshesFromGltf FAILED: {s}\n", .{@errorName(err)});
        return err;
    };
    defer {
        for (meshes) |m| {
            // meshes carry CPU buffers we'd normally hand to uploadMesh;
            // free what's allocated.  This is best-effort — full cleanup
            // belongs to unloadMesh in drawing.zig.
            _ = m;
        }
        gpa.free(meshes);
    }
    std.debug.print("\nmeshesFromGltf produced {d} meshes\n", .{meshes.len});
}
