// src/leak_test.zig - lifecycle and stress tests that exercise the
// allocator-explicit surface added by spring cleanup phases A-E.
// These tests are different in shape from the per-module unit tests:
// they drive *chains* of operations (gen, transform, transform, free)
// across many iterations, proving that:
//   - The full alloc/free chain is symmetric with no slow leak.
//   - The freeImageData / freeMany / errdefer paths are wired
//     correctly at every step.
//   - Realistic patterns (image-with-transforms, mesh-gen) are
//     leak-free under repeated invocation.
// `std.testing.allocator` is a DebugAllocator(.{ .safety = true })
// - at the end of every test it asserts no live allocations remain.
// Any leak in any function on these chains makes the whole suite go
// red.
// We deliberately avoid GPU-dependent paths (uploadMesh, texture
// upload) because they require rlgl_gpu state that doesn't exist on
// host.  CPU-only resource paths are what we cover here.
// GL-retirement P5: the CPU image + mesh libraries now live in
// image.zig and draw3d.zig; we import those directly - pulling zimr.zig
// onto a host target fails because it transitively imports
// src/web/{dom,gl}.zig which need wasm linkage.

const std = @import("std");
const expect = std.testing.expect;
const image = @import("../image.zig");
const draw3d = @import("../draw3d.zig");
const types = @import("../types.zig");
const Image = types.Image;
const rng_mod = @import("../runtime.zig").effects.rng;
const zm = @import("zm");
const radFromDeg = zm.radFromDeg;
const Color = zm.Color;
const Allocator = std.mem.Allocator;

// Image lifecycle stress
test "leak: gen/free image - 100 iterations" {
    const ta: Allocator = std.testing.allocator;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const img: Image = try image.genImageColor(ta, 32, 32, .{ .r = 100, .g = 50, .b = 200, .a = 255 });
        image.unloadImage(ta, img);
    }
}

test "leak: gen/resize/free chain - 50 iterations" {
    const ta: Allocator = std.testing.allocator;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var img: Image = try image.genImageColor(ta, 16, 16, .{ .r = 80, .g = 80, .b = 80, .a = 255 });
        try image.imageResize(ta, &img, 32, 32);
        image.unloadImage(ta, img);
    }
}

test "leak: gen/full-transform-chain/free - 25 iterations" {
    const ta: Allocator = std.testing.allocator;
    var i: usize = 0;
    while (i < 25) : (i += 1) {
        // Build a 32x32 image, run it through 5 different transforms,
        // then free.  Any errdefer or freeImageData mismatch leaks.
        var img: Image = try image.genImageColor(ta, 32, 32, .{ .r = 50, .g = 100, .b = 150, .a = 255 });
        try image.imageResize(ta, &img, 64, 64);
        try image.imageRotateCW(ta, &img);
        try image.imageCrop(ta, &img, .{ .x = 8, .y = 8, .width = 32, .height = 32 });
        try image.imageResizeNN(ta, &img, 16, 16);
        try image.imageResizeCanvas(ta, &img, 24, 24, 4, 4, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
        image.unloadImage(ta, img);
    }
}

test "leak: imageCopy roundtrip - 50 iterations" {
    const ta: Allocator = std.testing.allocator;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const src: Image = try image.genImageColor(ta, 12, 12, .{ .r = 200, .g = 100, .b = 50, .a = 255 });
        const dst: Image = try image.imageCopy(ta, src);
        image.unloadImage(ta, src);
        image.unloadImage(ta, dst);
    }
}

test "leak: imageFromImage extract - 50 iterations" {
    const ta: Allocator = std.testing.allocator;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const src: Image = try image.genImageColor(ta, 8, 8, .{ .r = 30, .g = 60, .b = 90, .a = 255 });
        const sub: Image = try image.imageFromImage(ta, src, .{ .x = 1, .y = 1, .width = 4, .height = 4 });
        image.unloadImage(ta, src);
        image.unloadImage(ta, sub);
    }
}

test "leak: gen/blur/free - exercises gpa scratch buffers" {
    const ta: Allocator = std.testing.allocator;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var img: Image = try image.genImageColor(ta, 16, 16, .{ .r = 200, .g = 200, .b = 200, .a = 255 });
        try image.imageBlurGaussian(ta, &img, 2);
        image.unloadImage(ta, img);
    }
}

// genImage* family - covers Phase B's full surface
test "leak: gen all image variants" {
    const ta: Allocator = std.testing.allocator;
    const c1: Color = .{ .r = 10, .g = 20, .b = 30, .a = 255 };
    const c2: Color = .{ .r = 200, .g = 180, .b = 160, .a = 255 };

    const img1: Image = try image.genImageColor(ta, 16, 16, c1);
    defer image.unloadImage(ta, img1);

    const img2: Image = try image.genImageGradientLinear(ta, 16, 16, radFromDeg(45.0), c1, c2);
    defer image.unloadImage(ta, img2);

    const img3: Image = try image.genImageGradientRadial(ta, 16, 16, 0.3, c1, c2);
    defer image.unloadImage(ta, img3);

    const img4: Image = try image.genImageGradientSquare(ta, 16, 16, 0.3, c1, c2);
    defer image.unloadImage(ta, img4);

    const img5: Image = try image.genImageChecked(ta, 16, 16, 4, 4, c1, c2);
    defer image.unloadImage(ta, img5);

    var seeded: rng_mod.Seeded = rng_mod.Seeded.init(42);
    const img6: Image = try image.genImageWhiteNoise(ta, seeded.rng(), 16, 16, 0.5);
    defer image.unloadImage(ta, img6);

    try expect(img1.data != null and img1.width == 16);
    try expect(img2.data != null and img2.width == 16);
    try expect(img3.data != null and img3.width == 16);
    try expect(img4.data != null and img4.width == 16);
    try expect(img5.data != null and img5.width == 16);
    try expect(img6.data != null and img6.width == 16);
}

// genMesh* family - covers Phase A's CPU-side surface
test "leak: gen/free mesh - 25 iterations across mesh types" {
    const ta: Allocator = std.testing.allocator;
    // genMesh* internally calls uploadMesh which needs GPU.  On host
    // uploadMesh's wasm_fwd stubs no-op, so the upload doesn't actually
    // happen but the CPU-side per-attribute arrays are allocated.
    // unloadMesh frees those CPU arrays.  This proves the gen->unload
    // pair is balanced.
    var i: usize = 0;
    while (i < 25) : (i += 1) {
        const cube: types.Mesh = try draw3d.genMeshCube(ta, 1.0, 1.0, 1.0);
        draw3d.unloadMesh(ta, cube);

        const sphere: types.Mesh = try draw3d.genMeshSphere(ta, 0.5, 8, 8);
        draw3d.unloadMesh(ta, sphere);

        // genMeshTangents allocates a 4xvc float array and stores
        // it on mesh.tangents.  unloadMesh must free it via the
        // same allocator.
        var sphere_with_tangents: types.Mesh = try draw3d.genMeshSphere(ta, 0.5, 8, 8);
        try draw3d.genMeshTangents(ta, &sphere_with_tangents);
        draw3d.unloadMesh(ta, sphere_with_tangents);

        // Re-running genMeshTangents on a mesh that already has
        // tangents must free the old buffer before allocating the
        // new one.
        var cube_repeat: types.Mesh = try draw3d.genMeshCube(ta, 1.0, 1.0, 1.0);
        try draw3d.genMeshTangents(ta, &cube_repeat);
        try draw3d.genMeshTangents(ta, &cube_repeat);
        draw3d.unloadMesh(ta, cube_repeat);

        const plane: types.Mesh = try draw3d.genMeshPlane(ta, 1.0, 1.0, 2, 2);
        draw3d.unloadMesh(ta, plane);
    }
}

// loadImageColors stress - Phase E.2's draw3d.zig private API
test "leak: loadImageColors round-trip - 50 iterations" {
    const ta: Allocator = std.testing.allocator;
    const src: types.Image = try image.genImageColor(ta, 8, 8, .{ .r = 30, .g = 60, .b = 90, .a = 255 });
    defer image.unloadImage(ta, src);

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const colors: []Color = try draw3d.loadImageColors(ta, src);
        defer ta.free(colors);
        try expect(colors.len == 64);
        try expect(colors[0].r == 30);
    }
}

// Frame-arena pattern - emulates the per-frame "scratch" allocator
// reset that user update fns rely on
test "leak: per-frame arena reset pattern - 100 frames" {
    var gpa_state: std.heap.DebugAllocator(.{ .safety = true }) = .init;
    defer {
        const status = gpa_state.deinit();
        if (status == .leak) {
            @panic("leak detected in per-frame arena pattern");
        }
    }
    const gpa: Allocator = gpa_state.allocator();

    // Per-frame arena: reset (retain capacity) at the start of each
    // frame, freed at end of test.
    var frame_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(gpa);
    defer frame_arena.deinit();

    var frame_count: usize = 0;
    while (frame_count < 100) : (frame_count += 1) {
        _ = frame_arena.reset(.retain_capacity);
        // A fresh handle each frame: `reset` invalidates the previous allocator's state, so
        // reusing one taken before the reset would hand out pointers into released memory.
        const fa: Allocator = frame_arena.allocator();

        // Simulate a per-frame allocation pattern: two small,
        // one medium scratch buffer.
        const small1 = try fa.alloc(u8, 64);
        _ = small1;
        const small2 = try fa.alloc(f32, 16);
        _ = small2;
        const medium = try fa.alloc(u32, 256);
        _ = medium;
        // No free - that's the point of an arena.  Reset on next
        // iteration recycles all of it.
    }
}
