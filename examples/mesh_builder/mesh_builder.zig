//! mesh_builder - a little workshop for the mesh-ops toolkit. It doesn't draw
//! any bare primitive; instead it BUILDS things out of them, the way you're
//! meant to: generate parts, orient/place them with meshTranslate/meshRotate,
//! flip caps with meshInvert, and weld everything into one mesh with meshMerge.
//!
//! Two pieces are on display:
//!   * a solid capped cylinder  (cylinder body + a disk on each end)
//!   * an arrow pointing +X      (thin cylinder shaft + a cone head, both spun
//!                                90 deg off the +Y axis onto +X with meshRotate)
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const assert = zm.assert;

const Camera3D = zm.Camera3D;
const pi = zm.pi;
const pointVec = zm.pointVec;

// a quarter turn in radians - spinning a +Y part by -90 deg around Z lands it on +X
const quarter_turn: f32 = pi * 0.5;

const State = struct {
    capped_cylinder: z.Model,
    arrow: z.Model,
    cam: z.OrbitCamera,
};

/// Build a solid, capped cylinder standing along +Y. This is the bread-and-
/// butter of composition: make the open tube, make a disk for each end, place
/// them, and fuse the three into one mesh.
fn buildCappedCylinder(
    gpa: Allocator,
    radius: f32,
    height: f32,
    slices: i32,
) !z.types.Mesh {
    // the tube itself - open at both ends (that's what the caps are for)
    const tube_body: z.types.Mesh = try z.genMeshCylinder(gpa, radius, height, slices, 2);

    // top cap: a disk already faces up (+Y), so we just slide it up to the top
    var top_cap: z.types.Mesh = try z.genMeshDisk(gpa, radius, slices);
    z.meshTranslate(&top_cap, 0, height, 0);

    // bottom cap: it needs to face DOWN (outward at the base), but genMeshDisk
    // faces up - so flip it inside-out with meshInvert (reverses winding +
    // normals). It's already sitting at y = 0, so no translate needed.
    var bottom_cap: z.types.Mesh = try z.genMeshDisk(gpa, radius, slices);
    z.meshInvert(&bottom_cap);

    // weld the three parts together, freeing pieces as we fold them in
    const body_plus_top: z.types.Mesh = try z.meshMerge(gpa, tube_body, top_cap);
    const finished: z.types.Mesh = try z.meshMerge(gpa, body_plus_top, bottom_cap);
    z.unloadMesh(gpa, tube_body);
    z.unloadMesh(gpa, top_cap);
    z.unloadMesh(gpa, bottom_cap);
    z.unloadMesh(gpa, body_plus_top);
    return finished;
}

/// Build an arrow pointing along +X: a thin cylinder shaft with a cone head.
/// Both come out of the generators pointing UP (+Y), so we spin each one -90 deg
/// around Z to lay it on the +X axis - which is exactly what meshRotate is for.
fn buildArrow(gpa: Allocator) !z.types.Mesh {
    const shaft_length: f32 = 1.7;
    const head_length: f32 = 0.6;

    // shaft: a Y-axis cylinder (0..len), spun -90 deg about Z so it runs along +X
    var shaft: z.types.Mesh = try z.genMeshCylinder(gpa, 0.07, shaft_length, 18, 2);
    z.meshRotate(&shaft, 0, 0, 1, -quarter_turn); // +Y -> +X

    // head: a Y-axis cone (base at 0, tip at +Y), spun the same way so it points
    // +X, then slid out to sit right on the tip of the shaft
    var head: z.types.Mesh = try z.genMeshCone(gpa, 0.18, head_length, 18, 2);
    z.meshRotate(&head, 0, 0, 1, -quarter_turn);
    z.meshTranslate(&head, shaft_length, 0, 0);

    const arrow: z.types.Mesh = try z.meshMerge(gpa, shaft, head);
    z.unloadMesh(gpa, shaft);
    z.unloadMesh(gpa, head);
    return arrow;
}

/// A quick headless sanity check for the cleanup ops (unweld/weld/removeDegenerate).
/// Runs at init so the smoke harness exercises them; nothing is shown on screen.
fn verifyCleanupOps(gpa: Allocator) !void {
    const torus: z.types.Mesh = try z.genMeshTorus(gpa, 0.6, 0.25, 24, 12);
    defer z.unloadMesh(gpa, torus);
    // unweld: exactly three vertices per triangle, nothing shared
    const faceted: z.types.Mesh = try z.meshUnweld(gpa, torus);
    defer z.unloadMesh(gpa, faceted);
    assert(faceted.vertexCount == faceted.triangleCount * 3, @src());
    // weld the faceted mesh back down - should recover far fewer vertices
    const rewelded: z.types.Mesh = try z.meshWeld(gpa, faceted, 0.0001);
    defer z.unloadMesh(gpa, rewelded);
    assert(rewelded.vertexCount < faceted.vertexCount, @src());
    // a clean torus has no slivers, so removeDegenerate should drop nothing
    const cleaned: z.types.Mesh = try z.meshRemoveDegenerate(gpa, torus, 1e-9);
    defer z.unloadMesh(gpa, cleaned);
    assert(cleaned.triangleCount == torus.triangleCount, @src());
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    try verifyCleanupOps(gpa);
    const capped_mesh: z.types.Mesh = try buildCappedCylinder(gpa, 0.55, 1.4, 32);
    const arrow_mesh: z.types.Mesh = try buildArrow(gpa);
    s.* = .{
        // loadModelFromMesh takes ownership of the mesh data (freed by unloadModel)
        .capped_cylinder = try z.loadModelFromMesh(f.gl, gpa, capped_mesh),
        .arrow = try z.loadModelFromMesh(f.gl, gpa, arrow_mesh),
        .cam = .{ .target = pointVec(0.4, 0.4, 0), .distance = 6.5, .pitch = 0.5, .yaw = 0.7 },
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadModel(gpa, s.capped_cylinder);
    z.unloadModel(gpa, s.arrow);
}

fn update(f: *z.Frame, s: *State) void {
    const cam: Camera3D = s.cam.update(f, false, .{ .fovy_deg = 45 });
    z.clearViewport(f, .{ .r = 14, .g = 16, .b = 22, .a = 255 });
    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 10, 0.5);
    // the capped cylinder sits on the left, standing up
    z.drawModel(f.gl, s.capped_cylinder, pointVec(-1.3, 0, 0), 1.0, .{ .r = 120, .g = 200, .b = 110, .a = 255 });
    // the arrow sits on the right, pointing off to +X
    z.drawModel(f.gl, s.arrow, pointVec(0.4, 0.7, 0), 1.0, .{ .r = 240, .g = 150, .b = 80, .a = 255 });
    z.endMode3D(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - mesh builder",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .update = update,
    .deinit = deinit,
};
