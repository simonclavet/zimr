//! render.zig — draw a `zimrphysics` World with zimr's 3D immediate-mode API.
//!
//! The pattern: the renderer is a *pure read* over `world.bodies` — the physics
//! ECS (`entities.Entities(Body)`) IS the scene description, so there is no
//! parallel render state to allocate, sync, or tear down. Per-body colour rides
//! on the Body's own `material` tag (an opaque `u16` the caller already owns), so
//! the physics world stays the single source of truth.
//!
//! Contrast the older `wgpu_physics_pyramid` demo, which mirrored every transform
//! into a *second* ECS (Transform + Collider + BodyColor) purely so it could be
//! drawn. Here the draw pass is a `world.bodies.forEach` over the bodies that
//! already exist, reading `com_pos` / `rot` / `shape` straight off each Body.

const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;

const phys = z.zimrphysics;

/// A body with this `material` is collidable but not drawn — "glass" walls that
/// keep bodies contained while staying out of the camera's way.
pub const invisible_material: u16 = 0xFFFF;

const Vec = zm.Vec;
const Quat = zm.Quat;
const Color = zm.Color;
const vec = zm.vec;
const splat = zm.splat;
const rotate = zm.rotate;
const qmul = zm.qmul;
const cross = zm.cross;
const normalize3 = zm.normalize3;
const matFromQuat = zm.matFromQuat;
const WgpuGl = z.WgpuGl;

/// How the world is coloured and tessellated. `palette` is indexed by
/// `Body.material` (wrapping), so materials 0,1,2,… select palette[0],[1],[2],…;
/// static bodies use `static_color` so the ground reads as fixed.
pub const Style = struct {
    palette: []const Color,
    static_color: Color,
    sphere_rings: i32 = 12,
    sphere_slices: i32 = 16,
    capsule_slices: i32 = 12,
    capsule_rings: i32 = 6,
    cylinder_sides: i32 = 16,
};

fn colorFor(style: Style, body: *const phys.Body) Color {
    if (body.motion_type == .static) {
        return style.static_color;
    }
    if (style.palette.len == 0) {
        return style.static_color;
    }
    return style.palette[body.material % style.palette.len];
}

fn darkenColor(c: Color, factor: f32) Color {
    const f: f32 = if (factor < 0.0) 0.0 else if (factor > 1.0) 1.0 else factor;
    return .{
        .r = @intFromFloat(float(c.r) * f),
        .g = @intFromFloat(float(c.g) * f),
        .b = @intFromFloat(float(c.b) * f),
        .a = c.a,
    };
}

/// Heightfield local vertex (gx, gz): `(gx·cell, height, gz·cell)`, matching the
/// engine's `hfVertex`.
fn hfVertexLocal(hf: *const phys.HeightField, gx: u32, gz: u32) Vec {
    const fx: f32 = float(gx);
    const fz: f32 = float(gz);
    return vec(fx * hf.cell_size, hf.heights[gz * hf.sample_count_x + gx], fz * hf.cell_size);
}

/// Recursive so compounds and pose decorators draw their resolved leaves.
fn drawShape(
    gl: *WgpuGl,
    world: *phys.World,
    style: *const Style,
    shape: *const phys.Shape,
    pos: Vec,
    rot: Quat,
    color: Color,
) void {
    switch (shape.*) {
        .sphere => |s| {
            z.drawSphere(gl, pos, .{
                .radius = s.radius,
                .rings = style.sphere_rings,
                .slices = style.sphere_slices,
                .color = color,
            });
        },
        .box => |b| {
            z.drawCube(gl, pos, .{
                .size = b.half_extent * splat(2.0),
                .rotation = matFromQuat(rot),
                .color = color,
            });
        },
        .capsule => |c| {
            const axis: Vec = rotate(rot, vec(0, c.half_height, 0));
            z.drawCapsule(gl, pos + axis, pos - axis, c.radius, style.capsule_slices, style.capsule_rings, color);
        },
        .cylinder => |c| {
            const axis: Vec = rotate(rot, vec(0, c.half_height, 0));
            z.drawCylinderBetween(gl, pos + axis, pos - axis, c.radius, c.radius, style.cylinder_sides, color);
        },
        .tapered_capsule => |c| {
            const axis: Vec = rotate(rot, vec(0, c.half_height, 0));
            const sides: i32 = style.cylinder_sides;
            z.drawCylinderBetween(gl, pos + axis, pos - axis, c.top_radius, c.bottom_radius, sides, color);
        },
        .compound => |cmp| {
            for (cmp.children, 0..) |child, ci| {
                const cs: *const phys.Shape = world.shapes.get(child.shape);
                const cpos: Vec = pos + rotate(rot, child.local_pos);
                const crot: Quat = qmul(rot, child.local_rot);
                // Child 0 is the main shape (its body colour); later children (spokes,
                // markers, knobs) are drawn a shade darker so they read as distinct
                // attached parts rather than blending into the same-coloured parent.
                const ccolor: Color = if (ci == 0) color else darkenColor(color, 0.58);
                drawShape(gl, world, style, cs, cpos, crot, ccolor);
            }
        },
        .rotated_translated => |rt| {
            const cs: *const phys.Shape = world.shapes.get(rt.child);
            const cpos: Vec = pos + rotate(rot, rt.position);
            const crot: Quat = qmul(rot, rt.rotation);
            drawShape(gl, world, style, cs, cpos, crot, color);
        },
        .offset_com => |oc| {
            // The body's com_pos IS the COM; the child origin sits at -offset from
            // it (engine: `p = p - rotate(r, oc.offset)`), so draw the child there.
            const cs: *const phys.Shape = world.shapes.get(oc.child);
            const cpos: Vec = pos - rotate(rot, oc.offset);
            drawShape(gl, world, style, cs, cpos, rot, color);
        },
        .convex_hull => |h| {
            // Triangle-fan each hull face. Hull points are COM-centred and com_pos
            // is the COM, so pos + rot*point is world.
            for (h.faces) |face| {
                if (face.vertex_count < 3) {
                    continue;
                }
                const base: u32 = face.first_vertex;
                const p0: Vec = pos + rotate(rot, h.points[h.face_vertices[base]]);
                var k: u32 = 1;
                while (k + 1 < face.vertex_count) : (k += 1) {
                    const p1: Vec = pos + rotate(rot, h.points[h.face_vertices[base + k]]);
                    const p2: Vec = pos + rotate(rot, h.points[h.face_vertices[base + k + 1]]);
                    z.drawTriangle3D(gl, p0, p1, p2, color);
                }
            }
        },
        .triangle => |t| {
            z.drawTriangle3D(gl, pos + rotate(rot, t.v0), pos + rotate(rot, t.v1), pos + rotate(rot, t.v2), color);
        },
        .mesh => |m| {
            for (m.triangles) |t| {
                z.drawTriangle3D(
                    gl,
                    pos + rotate(rot, m.vertices[t.v[0]]),
                    pos + rotate(rot, m.vertices[t.v[1]]),
                    pos + rotate(rot, m.vertices[t.v[2]]),
                    color,
                );
            }
        },
        .heightfield => |hf| {
            // Two triangles per cell (tri order matches collision: a,d,b / a,c,d).
            var cz: u32 = 0;
            while (cz + 1 < hf.sample_count_z) : (cz += 1) {
                var cx: u32 = 0;
                while (cx + 1 < hf.sample_count_x) : (cx += 1) {
                    const a: Vec = pos + rotate(rot, hfVertexLocal(&hf, cx, cz));
                    const b: Vec = pos + rotate(rot, hfVertexLocal(&hf, cx + 1, cz));
                    const c: Vec = pos + rotate(rot, hfVertexLocal(&hf, cx, cz + 1));
                    const d: Vec = pos + rotate(rot, hfVertexLocal(&hf, cx + 1, cz + 1));
                    z.drawTriangle3D(gl, a, d, b, color);
                    z.drawTriangle3D(gl, a, c, d, color);
                }
            }
        },
        .plane => |pl| {
            // Finite quad on the infinite half-space. x0 = closest point to origin;
            // an orthonormal tangent basis spans a display-capped square.
            const n: Vec = rotate(rot, pl.normal);
            const x0: Vec = pos + rotate(rot, pl.normal * splat(-pl.distance));
            const seed: Vec = if (@abs(n[1]) < 0.9) vec(0, 1, 0) else vec(1, 0, 0);
            const u: Vec = normalize3(cross(seed, n));
            const w: Vec = cross(n, u);
            const e: f32 = @min(pl.half_extent, 25.0);
            const c0: Vec = x0 + (u + w) * splat(e);
            const c1: Vec = x0 + (w - u) * splat(e);
            const c2: Vec = x0 - (u + w) * splat(e);
            const c3: Vec = x0 + (u - w) * splat(e);
            z.drawTriangle3D(gl, c0, c1, c2, color);
            z.drawTriangle3D(gl, c0, c2, c3, color);
        },
        // empty = constraint-only placeholder (nothing to draw).
        .empty => {},
    }
}

/// Draw every live body in `world`. Call between `z.beginMode3D` and
/// `z.endMode3D`. No allocation, no persistent state: one ECS pass per frame.
pub fn drawWorld(gl: *WgpuGl, world: *phys.World, style: Style) void {
    const zw: z.profiler.Zone = z.profiler.zoneNamed(@src(), "render.world");
    defer zw.end();
    const Ctx = struct {
        gl: *WgpuGl,
        world: *phys.World,
        style: Style,
    };
    var ctx: Ctx = .{ .gl = gl, .world = world, .style = style };
    world.bodies.forEach(struct {
        fn cb(cx: *Ctx, body: *const phys.Body) void {
            if (body.material == invisible_material) {
                return;
            }
            const color: Color = colorFor(cx.style, body);
            const shape: *const phys.Shape = cx.world.shapes.get(body.shape);
            drawShape(cx.gl, cx.world, &cx.style, shape, body.com_pos, body.rot, color);
        }
    }.cb, &ctx);
}
