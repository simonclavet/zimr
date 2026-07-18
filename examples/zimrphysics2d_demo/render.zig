//! render.zig — visualize a `zimrphysics2d` World by adapting the engine's
//! box2d-faithful DebugDraw callbacks into zimr's batched `ui.DrawList`.
//!
//! Why this shape: the engine already walks the world (`phys.draw`) and fires one
//! callback per primitive — every shape, joint, contact, and AABB it can emit. We
//! supply ~10 small callbacks that push into a DrawList; the demo never switches on
//! shape type, so any new primitive the engine learns to draw lights up here for
//! free. ImDrawList batches all of it into a handful of GPU draw calls, so "draw the
//! whole world" is a couple of vertex buffers, not a draw call per body.

const z = @import("zimr");
const zm = @import("zm");
const ui = z.ui_real;

const phys = z.zimrphysics2d;

const Vec2 = zm.Vec2;
const Color = zm.Color;
const Transform2 = zm.Transform2;
const transformPoint2 = zm.transformPoint2;
const rotateVec2 = zm.rotateVec2;

/// World(metres) → screen(pixels). Physics is Y-up; the screen is Y-down, so the
/// vertical axis flips. `target` is the world point parked at the screen centre and
pub const Camera2D = zm.Camera2D;

/// Forwarded to every DebugDraw callback through `DebugDraw.context`.
pub const DrawCtx = struct {
    dl: ui.DrawListHandle,
    cam: Camera2D,
};

/// Context handed to a scene's optional `lab` fn each frame: the world to query, a draw
/// list + camera, and the pointer as an interactive probe. Draw helpers take WORLD coords.
pub const LabCtx = struct {
    world: *phys.World,
    dl: ui.DrawListHandle,
    cam: Camera2D,
    pointer: Vec2,
    pointer_down: bool,
    time: f32,

    pub fn line(
        self: LabCtx,
        a: Vec2,
        b: Vec2,
        col: Color,
        thick: f32,
    ) void {
        self.dl.addLine(self.cam.worldToScreen(a), self.cam.worldToScreen(b), col, thick);
    }

    pub fn mark(self: LabCtx, p: Vec2, r_px: f32, col: Color) void {
        self.dl.addCircleFilled(self.cam.worldToScreen(p), r_px, col);
    }

    pub fn ring(
        self: LabCtx,
        c: Vec2,
        r_world: f32,
        col: Color,
        thick: f32,
    ) void {
        self.dl.addCircle(self.cam.worldToScreen(c), r_world * self.cam.zoom, col, thick);
    }

    pub fn rect(
        self: LabCtx,
        lo: Vec2,
        hi: Vec2,
        col: Color,
        thick: f32,
    ) void {
        self.line(.{ lo[0], lo[1] }, .{ hi[0], lo[1] }, col, thick);
        self.line(.{ hi[0], lo[1] }, .{ hi[0], hi[1] }, col, thick);
        self.line(.{ hi[0], hi[1] }, .{ lo[0], hi[1] }, col, thick);
        self.line(.{ lo[0], hi[1] }, .{ lo[0], lo[1] }, col, thick);
    }

    pub fn arrow(
        self: LabCtx,
        a: Vec2,
        b: Vec2,
        col: Color,
        thick: f32,
    ) void {
        self.line(a, b, col, thick);
        const dx: f32 = b[0] - a[0];
        const dy: f32 = b[1] - a[1];
        const mag: f32 = @sqrt(dx * dx + dy * dy);
        if (mag < 1.0e-4) {
            return;
        }
        const ux: f32 = dx / mag;
        const uy: f32 = dy / mag;
        const hl: f32 = 0.3;
        const hw: f32 = 0.16;
        const bx: f32 = b[0] - ux * hl;
        const by: f32 = b[1] - uy * hl;
        self.line(.{ b[0], b[1] }, .{ bx - uy * hw, by + ux * hw }, col, thick);
        self.line(.{ b[0], b[1] }, .{ bx + uy * hw, by - ux * hw }, col, thick);
    }
};

fn ctxOf(p: *anyopaque) *DrawCtx {
    return @ptrCast(@alignCast(p));
}

/// 0xRRGGBB → opaque colour. box2d hands us 24-bit hex (b2HexColor).
fn hex(c: phys.HexColor) Color {
    const r: u8 = @intCast((c >> 16) & 0xFF);
    const g: u8 = @intCast((c >> 8) & 0xFF);
    const b: u8 = @intCast(c & 0xFF);
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

fn withAlpha(c: Color, a: u8) Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
}

const fill_alpha: u8 = 200;
const edge_thickness: f32 = 1.5;

fn drawSolidPolygon(
    transform: Transform2,
    vertices: []const Vec2,
    radius: f32,
    color: phys.HexColor,
    ctx: *anyopaque,
) void {
    _ = radius;
    const c: *DrawCtx = ctxOf(ctx);
    var buf: [phys.max_polygon_vertices]Vec2 = undefined;
    const n: usize = vertices.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        buf[i] = c.cam.worldToScreen(transformPoint2(transform, vertices[i]));
    }
    const edge: Color = hex(color);
    c.dl.addPolygon(buf[0..n], withAlpha(edge, fill_alpha));
    c.dl.addPolyline(buf[0..n], edge, edge_thickness, true);
}

fn drawPolygon(
    transform: Transform2,
    vertices: []const Vec2,
    color: phys.HexColor,
    ctx: *anyopaque,
) void {
    const c: *DrawCtx = ctxOf(ctx);
    var buf: [phys.max_polygon_vertices]Vec2 = undefined;
    const n: usize = vertices.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        buf[i] = c.cam.worldToScreen(transformPoint2(transform, vertices[i]));
    }
    c.dl.addPolyline(buf[0..n], hex(color), edge_thickness, true);
}

fn drawSolidCircle(
    transform: Transform2,
    center: Vec2,
    radius: f32,
    color: phys.HexColor,
    ctx: *anyopaque,
) void {
    const c: *DrawCtx = ctxOf(ctx);
    const world_center: Vec2 = transformPoint2(transform, center);
    const screen_center: Vec2 = c.cam.worldToScreen(world_center);
    const r_px: f32 = radius * c.cam.zoom;
    const edge: Color = hex(color);
    c.dl.addCircleFilled(screen_center, r_px, withAlpha(edge, fill_alpha));
    c.dl.addCircle(screen_center, r_px, edge, edge_thickness);
    // A spoke to the rim along the body's local +x, so spin is legible.
    const rim: Vec2 = world_center + rotateVec2(transform.q, .{ radius, 0.0 });
    c.dl.addLine(screen_center, c.cam.worldToScreen(rim), edge, edge_thickness);
}

fn drawCircle(
    center: Vec2,
    radius: f32,
    color: phys.HexColor,
    ctx: *anyopaque,
) void {
    const c: *DrawCtx = ctxOf(ctx);
    const screen_center: Vec2 = c.cam.worldToScreen(center);
    c.dl.addCircle(screen_center, radius * c.cam.zoom, hex(color), edge_thickness);
}

fn drawSolidCapsule(
    p1: Vec2,
    p2: Vec2,
    radius: f32,
    color: phys.HexColor,
    ctx: *anyopaque,
) void {
    const c: *DrawCtx = ctxOf(ctx);
    const r_px: f32 = radius * c.cam.zoom;
    const edge: Color = hex(color);
    const fill: Color = withAlpha(edge, fill_alpha);
    const s1: Vec2 = c.cam.worldToScreen(p1);
    const s2: Vec2 = c.cam.worldToScreen(p2);
    // Stadium = two end discs + the body rectangle. Offset each endpoint by the
    // screen-space normal × r to get the rectangle's four corners.
    const d: Vec2 = .{ s2[0] - s1[0], s2[1] - s1[1] };
    const len_px: f32 = @sqrt(d[0] * d[0] + d[1] * d[1]);
    const inv: f32 = if (len_px > 1.0e-6) 1.0 / len_px else 0.0;
    const nrm: Vec2 = .{ -d[1] * inv * r_px, d[0] * inv * r_px };
    const a: Vec2 = .{ s1[0] + nrm[0], s1[1] + nrm[1] };
    const b: Vec2 = .{ s2[0] + nrm[0], s2[1] + nrm[1] };
    const e: Vec2 = .{ s2[0] - nrm[0], s2[1] - nrm[1] };
    const g: Vec2 = .{ s1[0] - nrm[0], s1[1] - nrm[1] };
    c.dl.addCircleFilled(s1, r_px, fill);
    c.dl.addCircleFilled(s2, r_px, fill);
    c.dl.addQuadFilled(a, b, e, g, fill);
    c.dl.addLine(a, b, edge, edge_thickness);
    c.dl.addLine(g, e, edge, edge_thickness);
    c.dl.addCircle(s1, r_px, edge, edge_thickness);
    c.dl.addCircle(s2, r_px, edge, edge_thickness);
}

fn drawLine(
    p1: Vec2,
    p2: Vec2,
    color: phys.HexColor,
    ctx: *anyopaque,
) void {
    const c: *DrawCtx = ctxOf(ctx);
    c.dl.addLine(c.cam.worldToScreen(p1), c.cam.worldToScreen(p2), hex(color), edge_thickness);
}

fn drawPoint(
    p: Vec2,
    size: f32,
    color: phys.HexColor,
    ctx: *anyopaque,
) void {
    const c: *DrawCtx = ctxOf(ctx);
    // `size` is already in pixels (box2d convention). Draw a small filled SQUARE rather than a
    // tessellated circle: drawPoly emits each circle as N quads (a 12-gon = 48 verts / 72 indices),
    // and a dense scene's contact overlay has tens of thousands of points — Benchmark|Barrel 2.4
    // peaks at ~26K manifold points, which as circles is ~1.4M verts and overruns the 2D ring. A
    // square is 4 verts / 6 indices (~12x cheaper) and reads the same at debug-dot sizes.
    const sp: Vec2 = c.cam.worldToScreen(p);
    const h: f32 = size * 0.5;
    c.dl.addRectFilled(
        .{ .x = sp[0] - h, .y = sp[1] - h, .width = size, .height = size },
        hex(color),
    );
}

fn drawTransform(
    transform: Transform2,
    ctx: *anyopaque,
) void {
    const c: *DrawCtx = ctxOf(ctx);
    const axis_len: f32 = 0.4;
    const origin: Vec2 = c.cam.worldToScreen(transform.p);
    const xend: Vec2 = transform.p + rotateVec2(transform.q, .{ axis_len, 0.0 });
    const yend: Vec2 = transform.p + rotateVec2(transform.q, .{ 0.0, axis_len });
    const x_col: Color = .{ .r = 220, .g = 60, .b = 60, .a = 255 };
    const y_col: Color = .{ .r = 60, .g = 200, .b = 90, .a = 255 };
    c.dl.addLine(origin, c.cam.worldToScreen(xend), x_col, edge_thickness);
    c.dl.addLine(origin, c.cam.worldToScreen(yend), y_col, edge_thickness);
}

fn drawString(
    p: Vec2,
    s: []const u8,
    color: phys.HexColor,
    ctx: *anyopaque,
) void {
    const c: *DrawCtx = ctxOf(ctx);
    c.dl.addText(s, c.cam.worldToScreen(p), 13, hex(color));
}

fn drawAabb(
    aabb: phys.Aabb2,
    color: phys.HexColor,
    ctx: *anyopaque,
) void {
    const c: *DrawCtx = ctxOf(ctx);
    const lo: Vec2 = aabb.lower;
    const hi: Vec2 = aabb.upper;
    const pts: [4]Vec2 = .{
        c.cam.worldToScreen(.{ lo[0], lo[1] }),
        c.cam.worldToScreen(.{ hi[0], lo[1] }),
        c.cam.worldToScreen(.{ hi[0], hi[1] }),
        c.cam.worldToScreen(.{ lo[0], hi[1] }),
    };
    c.dl.addPolyline(pts[0..], hex(color), 1.0, true);
}

/// Optional decoration layers on top of the shapes.
pub const Options = struct {
    draw_joints: bool = false,
    draw_bounds: bool = false,
    draw_contacts: bool = false,
};

/// Build a DebugDraw wired to `ctx`. Pass it to `phys.draw(world, &dd)`.
pub fn debugDraw(ctx: *DrawCtx, opts: Options) phys.DebugDraw {
    return .{
        .draw_polygon = drawPolygon,
        .draw_solid_polygon = drawSolidPolygon,
        .draw_circle = drawCircle,
        .draw_solid_circle = drawSolidCircle,
        .draw_solid_capsule = drawSolidCapsule,
        .draw_line = drawLine,
        .draw_transform = drawTransform,
        .draw_point = drawPoint,
        .draw_string = drawString,
        .draw_aabb = drawAabb,
        .draw_shapes = true,
        .draw_joints = opts.draw_joints,
        .draw_joint_extras = opts.draw_joints,
        .draw_bounds = opts.draw_bounds,
        .draw_contacts = opts.draw_contacts,
        .draw_contact_normals = opts.draw_contacts,
        .context = ctx,
    };
}
