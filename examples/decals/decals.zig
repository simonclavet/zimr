//! decals — raylib's `models_decals`, done the real-engine way.
//!
//! Click a surface (the sphere or the bunny) to splat a textured DECAL onto
//! it. Each decal is SHADER-PROJECTED: the receiver mesh is re-drawn through a
//! decal pipeline whose fragment shader transforms each fragment's world
//! position by a projector matrix (world → decal-box space), discards anything
//! outside the box, and samples the decal texture at the planar box UV where it
//! lands. So a decal "paints" exactly the surface patch under its projector —
//! it wraps around curvature and follows the geometry with no mesh clipping,
//! and scales to any mesh density (the 69k-tri bunny is no problem). This is
//! how engines do bullet holes and scorch marks.
//!
//! An earlier version clipped the target mesh per-triangle (Sutherland–Hodgman
//! against the box) and re-uploaded the clipped geometry. That works on coarse
//! meshes but shatters on dense ones — thousands of tiny triangles fall in one
//! box and a fixed output cap captures a scattered subset. The shader path
//! replaces it entirely.
//!
//! Engine additions this drove: `z.uploadDecalReceiver` (upload a mesh once as
//! a decal receiver) + `z.drawDecal` (paint a projected decal onto it), backed
//! by a dedicated decal pipeline in draw3d with the decal_vs/decal_fs shaders
//! and a `less_equal_no_write` depth mode.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");

const Color = zm.Color;
const Camera3D = zm.Camera3D;
const Mat = zm.Mat;
const Ray = zm.Ray;
const RayCollision = zm.RayCollision;
const Vec = zm.Vec;
const inverse = zm.inverse;
const lookAtRh = zm.lookAtRh;
const compose = zm.compose;
const mulMatVec = zm.mulMatVec;
const pointVec = zm.pointVec;
const rotationZ = zm.rotationZ;
const vec = zm.vec;
const dot3 = zm.dot3;
const float = zm.float;
const rad_per_deg = zm.rad_per_deg;
const bufPrint = std.fmt.bufPrint;
const co = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const bunny_obj = @embedFile("bunny.obj");

pub var zimr_app: z.App = .{};

// Bunny placement: recenter its AABB, scale up, and shove it to the right of
// the sphere. Baked into the mesh vertices so pick-space == draw-space (both
// use an identity transform).
const bunny_center: [3]f32 = .{ -0.0168, 0.1102, -0.0015 };
const bunny_scale: f32 = 22.0;
const bunny_offset: [3]f32 = .{ 4.2, -1.6, 0.0 };

const sphere_radius: f32 = 2.0;
const decal_size: f32 = 1.1; // world extent of a decal box
const max_decals: usize = 64;

/// A recorded decal: the world→box projector, its tint, and which receiver
/// (sphere or bunny) it paints onto. The GPU does the projection each frame.
const Decal = struct {
    projector: Mat,
    forward: Vec, // projector facing dir = surface normal at the hit
    color: Color,
    receiver: u32, // decal-receiver handle
};

const State = struct {
    font: z.Font,
    ui_host: z.UiHost,
    cam: z.OrbitCamera,
    mesh: z.Mesh, // CPU sphere (for picking)
    sphere_model: z.Model, // GPU sphere for drawing (same mesh as the receiver)
    bunny: z.Mesh, // CPU bunny (for picking)
    bunny_model: z.Model, // GPU bunny for drawing
    sphere_recv: u32, // decal-receiver handle for the sphere
    bunny_recv: u32, // decal-receiver handle for the bunny
    decal_tex: z.WgpuTexture,
    decals: [max_decals]Decal = undefined,
    decal_count: usize = 0,
    show_target: bool = true,
    rng: u32 = 0x1234abcd,
};

fn deinit(gpa: Allocator, s: *State) void {
    // sphere_model/bunny_model COPY the mesh struct (shared vboId + CPU array
    // pointers), so unloadModel is the single owner of those buffers+arrays —
    // freeing s.mesh/s.bunny too would double-free (they're the same handles).
    z.unloadFont(gpa, s.font);
    z.unloadModel(gpa, s.sphere_model);
    z.unloadModel(gpa, s.bunny_model);
    s.decal_tex.deinit();
    s.ui_host.deinit();
}

/// Parse the bunny .obj and bake recenter + scale + world offset into a
/// `z.Mesh` (interleaved xyz verts + u16 indices), so picking, decal
/// projection, and drawing all share one world-space coordinate frame.
fn loadBunny(gpa: Allocator) !z.Mesh {
    var data: z.codecs.obj.Data = try z.codecs.obj.parse(gpa, bunny_obj);
    defer data.deinit(gpa);
    const om: z.codecs.obj.Mesh = try data.toMesh(gpa);
    defer om.deinit(gpa);

    const vcount: usize = om.vertexCount();
    const tris: usize = om.indices.len / 3;
    const verts: []f32 = try gpa.alloc(f32, vcount * 3);
    const norms: []f32 = try gpa.alloc(f32, vcount * 3);
    const idx: []u16 = try gpa.alloc(u16, tris * 3);

    var i: usize = 0;
    while (i < vcount) : (i += 1) {
        // Bake: (p - center) * scale + offset.
        verts[i * 3 + 0] = (om.positions[i * 3 + 0] - bunny_center[0]) * bunny_scale + bunny_offset[0];
        verts[i * 3 + 1] = (om.positions[i * 3 + 1] - bunny_center[1]) * bunny_scale + bunny_offset[1];
        verts[i * 3 + 2] = (om.positions[i * 3 + 2] - bunny_center[2]) * bunny_scale + bunny_offset[2];
        // `toMesh` always populates normals — it synthesizes smooth per-vertex
        // normals when the OBJ has no `vn` (bunny.obj has none). So use them
        // directly; the decal facing test depends on real normals.
        norms[i * 3 + 0] = om.normals[i * 3 + 0];
        norms[i * 3 + 1] = om.normals[i * 3 + 1];
        norms[i * 3 + 2] = om.normals[i * 3 + 2];
    }
    for (om.indices, 0..) |ix, k| {
        idx[k] = @intCast(ix);
    }

    var mesh: z.Mesh = .{};
    mesh.vertexCount = @intCast(vcount);
    mesh.triangleCount = @intCast(tris);
    mesh.vertices = verts.ptr;
    mesh.normals = norms.ptr;
    mesh.indices = idx.ptr;
    return mesh;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    const mesh: z.Mesh = try z.genMeshSphere(gpa, sphere_radius, 24, 32);
    const sphere_model: z.Model = try z.loadModelFromMesh(f.gl, gpa, mesh);
    const bunny: z.Mesh = try loadBunny(gpa);
    const bunny_model: z.Model = try z.loadModelFromMesh(f.gl, gpa, bunny);
    // Upload both targets as decal receivers (pos+normal VBOs, once). Decals are
    // painted onto these by re-drawing them through the projector shader. Both
    // targets are drawn as MODELS from the SAME meshes used as receivers, so the
    // drawn surface and the decal surface are identical geometry (no mismatch).
    const sphere_recv: u32 = z.uploadDecalReceiver(f.gl, mesh) orelse return error.DecalReceiverFailed;
    const bunny_recv: u32 = z.uploadDecalReceiver(f.gl, bunny) orelse return error.DecalReceiverFailed;
    var cam: z.OrbitCamera = z.OrbitCamera.init(pointVec(1.6, 0, 0), 9.0);
    cam.yaw = 0.7;
    cam.pitch = 0.4;
    const decal_img: z.Image = try makeDecalImage(gpa);
    defer z.unloadImage(gpa, decal_img);
    s.* = .{
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
        .cam = cam,
        .mesh = mesh,
        .sphere_model = sphere_model,
        .bunny = bunny,
        .bunny_model = bunny_model,
        .sphere_recv = sphere_recv,
        .bunny_recv = bunny_recv,
        .decal_tex = z.loadTextureFromImage(f.gl, decal_img),
    };
}

fn xorshift(state: *u32) u32 {
    var x: u32 = state.*;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    state.* = x;
    return x;
}

fn update(f: *z.Frame, s: *State) void {
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    z.clearViewport(f, co.palette.bg);

    const u: z.ui_real.Ui = s.ui_host.begin(f);
    const cam: Camera3D = s.cam.update(f, u.wantCaptureMouse(), .{
        .min_distance = 4.0,
        .max_distance = 20.0,
    });

    // ---- pick the surface under the cursor (test both targets, keep nearer) ----
    const m: zm.Vec2 = z.getMousePosition(f.input);
    const ray: Ray = z.getScreenToWorldRay(m, cam, vw, vh);
    const hit_sphere: RayCollision = z.getRayCollisionMesh(ray, s.mesh, zm.identity());
    const hit_bunny: RayCollision = z.getRayCollisionMesh(ray, s.bunny, zm.identity());
    var hit: RayCollision = hit_sphere;
    var receiver: u32 = s.sphere_recv;
    if (hit_bunny.hit and (!hit_sphere.hit or hit_bunny.distance < hit_sphere.distance)) {
        hit = hit_bunny;
        receiver = s.bunny_recv;
    }
    // `getRayCollisionTriangle` derives the normal from cross(edge1, edge2),
    // whose sign depends on triangle WINDING — genMeshSphere is CW-wound, so its
    // hit normal points INWARD (opposite the surface's outward vertex normals),
    // while the OBJ bunny is CCW so its points outward. That inconsistency made
    // the decal facing test reject the whole sphere. Fix winding-independently:
    // the visible surface always faces the ray origin, so flip the normal to
    // point back toward the camera.
    if (hit.hit) {
        const to_eye: Vec = vec(
            ray.position[0] - hit.point[0],
            ray.position[1] - hit.point[1],
            ray.position[2] - hit.point[2],
        );
        if (dot3(hit.normal, to_eye) < 0) {
            hit.normal = vec(-hit.normal[0], -hit.normal[1], -hit.normal[2]);
        }
    }

    // ---- click: splat a decal on whichever target was hit ----
    if (hit.hit and !u.wantCaptureMouse() and z.isMouseButtonPressed(f.input, .left)) {
        placeDecal(s, hit, receiver);
    }

    // ---- UI ----
    controlPanel(u, s, vw, vh);

    // ---- render ----
    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 12, 1.0);
    if (s.show_target) {
        // Both targets drawn the SAME way — as models from the exact meshes used
        // as decal receivers, so drawn surface == decal surface for both.
        z.drawModel(f.gl, s.sphere_model, pointVec(0, 0, 0), 1.0, .{ .r = 120, .g = 130, .b = 150, .a = 255 });
        z.drawModel(f.gl, s.bunny_model, pointVec(0, 0, 0), 1.0, .{ .r = 150, .g = 140, .b = 130, .a = 255 });
    }
    var i: usize = 0;
    while (i < s.decal_count) : (i += 1) {
        const d: *const Decal = &s.decals[i];
        z.drawDecal(f.gl, d.receiver, d.projector, s.decal_tex, .{
            .size = decal_size,
            .tint = d.color,
            .forward = d.forward,
        });
    }
    // Placement preview: a wire box oriented like the decal-to-be.
    if (hit.hit and !u.wantCaptureMouse()) {
        drawPreview(f, hit);
    }
    z.endMode3D(f.gl);

    // ---- HUD ----
    var buf: [80]u8 = undefined;
    const hud: []const u8 = bufPrint(
        &buf,
        "decals: {d}/{d}   click to splat",
        .{ s.decal_count, max_decals },
    ) catch "";
    f.gl.text(.{ 14, 42 }, hud, .{ .size = 18, .color = co.palette.ink_dim, .font = &s.font });

    // ---- DEBUG: show the last hit + first decal vertex to diagnose placement ----
    if (hit.hit) {
        var dbg: [128]u8 = undefined;
        const d1: []const u8 = bufPrint(
            &dbg,
            "hit ({d:.2},{d:.2},{d:.2}) n({d:.2},{d:.2},{d:.2})",
            .{ hit.point[0], hit.point[1], hit.point[2], hit.normal[0], hit.normal[1], hit.normal[2] },
        ) catch "";
        f.gl.text(
            .{ 14, 66 },
            d1,
            .{ .size = 15, .color = .{ .r = 120, .g = 230, .b = 120, .a = 255 }, .font = &s.font },
        );
    }

    co.caption(f.gl, s.font, "WebGPU 3D - projected decals (click sphere or bunny; drag to orbit)");
    s.ui_host.render(f);
}

/// Record a decal at the hit: build the world→box projector and store it with
/// the receiver handle. The GPU projects + paints it each frame (no clipping).
fn placeDecal(s: *State, hit: RayCollision, receiver: u32) void {
    if (s.decal_count >= max_decals) {
        return;
    }
    // Projection: look from just outside the surface toward the hit point,
    // spun a random amount about its own axis (raylib's `splat`).
    const eye: Vec = vec(
        hit.point[0] + hit.normal[0],
        hit.point[1] + hit.normal[1],
        hit.point[2] + hit.normal[2],
    );
    const look: Mat = lookAtRh(hit.point, eye, vec(0, 1, 0));
    const spin_deg: f32 = float(@as(i32, @intCast(xorshift(&s.rng) % 360)) - 180);
    // Apply the world→box `look`, then spin in-plane (spin acting in box space).
    // `compose(first, then)` reads in application order.
    const projector: Mat = compose(look, rotationZ(spin_deg * rad_per_deg));

    s.decals[s.decal_count] = .{
        .projector = projector,
        .forward = vec(hit.normal[0], hit.normal[1], hit.normal[2]),
        .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .receiver = receiver,
    };
    s.decal_count += 1;
}

fn drawPreview(f: *z.Frame, hit: RayCollision) void {
    // Show the ACTUAL oriented decal box at the hit: the 8 corners of the
    // [-s, s]^3 box transformed by the inverse projection into world space,
    // drawn as edges. This is the ground-truth cursor — if a decal doesn't
    // land inside this box, the projection is wrong.
    const eye: Vec = vec(
        hit.point[0] + hit.normal[0],
        hit.point[1] + hit.normal[1],
        hit.point[2] + hit.normal[2],
    );
    const look: Mat = lookAtRh(hit.point, eye, vec(0, 1, 0));
    const inv_proj: Mat = inverse(look);
    const s: f32 = 0.5 * decal_size;
    var c: [8]Vec = undefined;
    var i: usize = 0;
    inline for ([_]f32{ -1, 1 }) |sx| {
        inline for ([_]f32{ -1, 1 }) |sy| {
            inline for ([_]f32{ -1, 1 }) |sz| {
                c[i] = mulMatVec(inv_proj, pointVec(sx * s, sy * s, sz * s));
                i += 1;
            }
        }
    }
    const col: Color = .{ .r = 120, .g = 230, .b = 120, .a = 255 };
    // 12 edges of the box (corner index bit pattern: x=bit2, y=bit1, z=bit0).
    const edges = [_][2]usize{
        .{ 0, 1 }, .{ 2, 3 }, .{ 4, 5 }, .{ 6, 7 }, // z edges
        .{ 0, 2 }, .{ 1, 3 }, .{ 4, 6 }, .{ 5, 7 }, // y edges
        .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 }, // x edges
    };
    for (edges) |e| {
        z.drawLine3D(f.gl, c[e[0]], c[e[1]], col);
    }
}

fn controlPanel(u: z.ui_real.Ui, s: *State, vw: f32, vh: f32) void {
    u.setNextWindowPos(.{ 8, vh - 66 }, .{});
    u.setNextWindowSize(.{ @min(320, vw - 16), 58 }, .{});
    if (u.window("decals", .{})) |w| {
        defer w.close();
        if (u.button(if (s.show_target) "hide target" else "show target", .{})) {
            s.show_target = !s.show_target;
        }
        u.sameLine(.{});
        if (u.button("clear", .{})) {
            s.decal_count = 0;
        }
    }
}

/// The decal sticker: a bright ring/target with a transparent surround so the
/// decal edges fade rather than showing box seams.
fn makeDecalImage(gpa: Allocator) !z.Image {
    const n: usize = 64;
    const img: z.Image = try z.genImageColor(gpa, @intCast(n), @intCast(n), .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    const px: [*]u8 = @ptrCast(img.data.?);
    const c: f32 = float(n) * 0.5 - 0.5;
    for (0..n) |y| {
        for (0..n) |x| {
            const dx: f32 = float(x) - c;
            const dy: f32 = float(y) - c;
            const r: f32 = @sqrt(dx * dx + dy * dy) / c;
            var a: u8 = 0;
            var col: [3]u8 = .{ 255, 220, 60 };
            // Fade the ring fully to transparent by r≈0.72 — well inside the
            // decal box's edges — so the box side-plane clip only ever cuts
            // already-transparent texels and never leaves a hard straight edge.
            if (r < 0.72) {
                a = 255;
                // Concentric rings (packed into the inner 0.7 radius).
                const band: f32 = @mod(r * 5.0, 1.0);
                if (band < 0.5) {
                    col = .{ 230, 60, 60 };
                } else {
                    col = .{ 255, 220, 60 };
                }
                if (r > 0.55) {
                    a = @intFromFloat(@round(255.0 * (0.72 - r) / 0.17));
                }
            }
            const i: usize = (y * n + x) * 4;
            px[i + 0] = col[0];
            px[i + 1] = col[1];
            px[i + 2] = col[2];
            px[i + 3] = a;
        }
    }
    return img;
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - decals",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
