//! lint:alias shapes2d
//! src/shapes2d.zig — the backend-generic 2D shape primitives, MOVED
//! VERBATIM out of drawing.zig (GL retirement P1, t1173): rectangles,
//! ellipses, polys, rings, splines, lines — all over `gl: anytype`, drawn
//! by both backends (ui's widget rendering, wgpu_app's ShapesTextureState).
//! GL-free since GL-retirement P5d.
const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const zm = @import("zm");
const sinTurns = zm.sinTurns;
const cosTurns = zm.cosTurns;
const turnsFromRad = zm.turnsFromRad;
const float = zm.float;
const acosRad = zm.acosRad;
const floatEps = zm.floatEps;
const isFinite = zm.isFinite;
const pi = zm.pi;
/// One turn in 36 steps, which is what this constant always meant.
const seg_step36: f32 = 1.0 / 36.0;
const pow = zm.pow;
/// Inert renderer for the no-panic smoke tests below (GL-retirement P5d:
/// they used to replay into rlgl.GlState, whose host build was no-op
/// anyway).  Also re-exported as ui.TestGlStub — the one stub for the
/// whole replay trait.
pub const TestGl = struct {
    pub fn setTexture(_: *TestGl, _: anytype) void {}
    pub fn begin(_: *TestGl, _: anytype) void {}
    pub fn end(_: *TestGl) void {}
    pub fn vertex2f(_: *TestGl, _: anytype, _: anytype) void {}
    pub fn texCoord2f(_: *TestGl, _: anytype, _: anytype) void {}
    pub fn normal3f(_: *TestGl, _: anytype, _: anytype, _: anytype) void {}
    pub fn color4ub(
        _: *TestGl,
        _: anytype,
        _: anytype,
        _: anytype,
        _: anytype,
    ) void {}
    pub fn enable(_: *TestGl, _: anytype) void {}
    pub fn disable(_: *TestGl, _: anytype) void {}
    pub fn scissor(
        _: *TestGl,
        _: anytype,
        _: anytype,
        _: anytype,
        _: anytype,
    ) void {}
    pub fn matrixMode(_: *TestGl, _: anytype) void {}
    pub fn loadIdentity(_: *TestGl) void {}
    pub fn ortho(
        _: *TestGl,
        _: anytype,
        _: anytype,
        _: anytype,
        _: anytype,
        _: anytype,
        _: anytype,
    ) void {}
    pub fn pushMatrix(_: *TestGl) void {}
    pub fn popMatrix(_: *TestGl) void {}
    pub fn translatef(_: *TestGl, _: anytype, _: anytype, _: anytype) void {}
    pub fn viewport(
        _: *TestGl,
        _: anytype,
        _: anytype,
        _: anytype,
        _: anytype,
    ) void {}
};

const types = @import("types.zig");
const runtime = @import("runtime.zig");
const Mat = zm.Mat;
const z = struct {
    pub const Rectangle = types.Rectangle;
    pub const Texture = types.Texture;
};

const Vec2 = zm.Vec2;
const Color = zm.Color;
const Rectangle = z.Rectangle;
const Texture = z.Texture;

// rlgl extern declarations
//
// rshapes only touches eight rlgl entry points and four RL_ mode constants.
// The C side compiles rlgl.c into the binary; these externs let us call
// into it from Zig with no allocation, no wrapper overhead.

// rlgl entry points are reached through the `rl` namespace alias below,
// which forwarded to the retired GL state machine.  We do NOT use `extern fn` to
// declare these - Zig's wasm linker treats undecorated `extern fn` as
// `env.<name>` imports that don't unify with `pub export fn` definitions
// across compilation units (see ZIGGIFY_NOTES.md Session N+3).  Direct
// imports keep the call internal and let DCE strip the whole module
// when no example references it.

// Shapes texture state
//
// The "shapes texture" is a 1×1 white pixel by default - every solid-color
// shape samples from it so a single texture binding can serve filled and
// textured drawing in the same vertex batch (avoids a flush). The C side
// initializes this in rlglInit() to a magic 1×1 white pixel uploaded at
// texture id 1; we mirror that initial value here.

/// State for the "shapes texture" - the GPU texture that solid-color
/// shape draws sample from.  Default is a 1×1 white pixel uploaded by
/// `rlglInit`; user can swap to a custom atlas tile via
/// `setShapesTexture` (e.g. SDF mask).
pub const ShapesTextureState = struct {
    texture: Texture = .{
        .id = 1,
        .width = 1,
        .height = 1,
        .mipmaps = 1,
        .format = @backingInt(types.PixelFormat.uncompressed_r8g8b8a8),
    },
    source: Rectangle = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
};

/// Set the texture and source rectangle used to draw shapes. Useful for
/// applying a custom atlas tile (e.g. an SDF mask) to filled shapes.
pub fn setShapesTexture(
    state: *ShapesTextureState,
    texture: Texture,
    source: Rectangle,
) void {
    // Reset to default white pixel if the caller passes an invalid texture id.
    if (texture.id <= 0) {
        state.* = .{};
    } else {
        state.texture = texture;
        state.source = source;
    }
}

/// Get the current shapes texture.
pub fn getShapesTexture(state: *const ShapesTextureState) Texture {
    return state.texture;
}

/// Get the source rectangle of the current shapes texture.
pub fn getShapesTextureRectangle(state: *const ShapesTextureState) Rectangle {
    return state.source;
}

// Spline point evaluation
//
// All five splines take a parameter t in [0, 1] and return a point on the
// curve. They're pure math (no rlgl, no allocation) and pair with the
// drawSpline* functions added in Step 7.

/// Linear interpolation. Equivalent to `lerp(start, end, t)` per coordinate.
pub fn getSplinePointLinear(
    startPos: Vec2,
    endPos: Vec2,
    t: f32,
) Vec2 {
    return .{ startPos[0] * (1.0 - t) + endPos[0] * t, startPos[1] * (1.0 - t) + endPos[1] * t };
}

/// B-spline (basis-spline) point. Uses the uniform cubic B-spline basis;
/// the curve does NOT pass through any of the four control points.
pub fn getSplinePointBasis(
    p1: Vec2,
    p2: Vec2,
    p3: Vec2,
    p4: Vec2,
    t: f32,
) Vec2 {
    const a: f32 = pow(1.0 - t, 3.0) / 6.0;
    const b: f32 = (3.0 * pow(t, 3.0) - 6.0 * pow(t, 2.0) + 4.0) / 6.0;
    const c: f32 = (-3.0 * pow(t, 3.0) + 3.0 * pow(t, 2.0) + 3.0 * t + 1.0) / 6.0;
    const d: f32 = pow(t, 3.0) / 6.0;
    return .{ a * p1[0] + b * p2[0] + c * p3[0] + d * p4[0], a * p1[1] + b * p2[1] + c * p3[1] + d * p4[1] };
}

/// Catmull-Rom spline point. Curve passes through p2 (at t=0) and p3 (at
/// t=1); p1 and p4 are the prior/next_turns control points that influence the
/// tangent at the endpoints.
pub fn getSplinePointCatmullRom(
    p1: Vec2,
    p2: Vec2,
    p3: Vec2,
    p4: Vec2,
    t: f32,
) Vec2 {
    const q0: f32 = (-1.0 * t * t * t) + (2.0 * t * t) + (-1.0 * t);
    const q1: f32 = (3.0 * t * t * t) + (-5.0 * t * t) + 2.0;
    const q2: f32 = (-3.0 * t * t * t) + (4.0 * t * t) + t;
    const q3: f32 = t * t * t - t * t;
    return .{
        0.5 * (p1[0] * q0 + p2[0] * q1 + p3[0] * q2 + p4[0] * q3),
        0.5 * (p1[1] * q0 + p2[1] * q1 + p3[1] * q2 + p4[1] * q3),
    };
}

/// Quadratic Bézier point. Curve passes through `startPos` at t=0 and
/// `endPos` at t=1; `controlPos` shapes the curvature.
pub fn getSplinePointBezierQuad(
    startPos: Vec2,
    controlPos: Vec2,
    endPos: Vec2,
    t: f32,
) Vec2 {
    const a: f32 = pow(1.0 - t, 2.0);
    const b: f32 = 2.0 * (1.0 - t) * t;
    const c: f32 = pow(t, 2.0);
    return .{
        a * startPos[0] + b * controlPos[0] + c * endPos[0],
        a * startPos[1] + b * controlPos[1] + c * endPos[1],
    };
}

/// Cubic Bézier point. Curve passes through `startPos` at t=0 and `endPos`
/// at t=1; `startControlPos` and `endControlPos` shape the curvature.
pub fn getSplinePointBezierCubic(
    startPos: Vec2,
    startControlPos: Vec2,
    endControlPos: Vec2,
    endPos: Vec2,
    t: f32,
) Vec2 {
    const a: f32 = pow(1.0 - t, 3.0);
    const b: f32 = 3.0 * pow(1.0 - t, 2.0) * t;
    const c: f32 = 3.0 * (1.0 - t) * pow(t, 2.0);
    const d: f32 = pow(t, 3.0);
    return .{
        a * startPos[0] + b * startControlPos[0] + c * endControlPos[0] + d * endPos[0],
        a * startPos[1] + b * startControlPos[1] + c * endControlPos[1] + d * endPos[1],
    };
}

// Collision detection
/// Test if a point lies inside a rectangle (inclusive on top/left, exclusive
/// on bottom/right per the original - we use `<=` for parity with raylib).
pub fn checkCollisionPointRec(point: Vec2, rec: Rectangle) bool {
    return (point[0] >= rec.x) and (point[0] < (rec.x + rec.width)) and
        (point[1] >= rec.y) and (point[1] < (rec.y + rec.height));
}

/// Test if a point lies inside a circle.
pub fn checkCollisionPointCircle(
    point: Vec2,
    center: Vec2,
    radius: f32,
) bool {
    const dx: f32 = point[0] - center[0];
    const dy: f32 = point[1] - center[1];
    return (dx * dx + dy * dy) <= (radius * radius);
}

/// Test if a point lies inside (or on the edge of) a triangle. Uses the
/// barycentric-coordinate sign test - robust for any triangle winding.
pub fn checkCollisionPointTriangle(
    point: Vec2,
    p1: Vec2,
    p2: Vec2,
    p3: Vec2,
) bool {
    const alpha: f32 =
        ((p2[1] - p3[1]) * (point[0] - p3[0]) + (p3[0] - p2[0]) * (point[1] - p3[1])) /
        ((p2[1] - p3[1]) * (p1[0] - p3[0]) + (p3[0] - p2[0]) * (p1[1] - p3[1]));
    const beta: f32 =
        ((p3[1] - p1[1]) * (point[0] - p3[0]) + (p1[0] - p3[0]) * (point[1] - p3[1])) /
        ((p2[1] - p3[1]) * (p1[0] - p3[0]) + (p3[0] - p2[0]) * (p1[1] - p3[1]));
    const gamma: f32 = 1.0 - alpha - beta;
    return (alpha > 0) and (beta > 0) and (gamma > 0);
}

/// Test if a point lies inside a polygon. Uses the Jordan-curve ray-cast
/// algorithm: count how many polygon edges the half-line going right from
/// `point` crosses; odd → inside, even → outside.
pub fn checkCollisionPointPoly(
    point: Vec2,
    points: []const Vec2,
) bool {
    if (points.len < 3) {
        return false;
    }
    var inside: bool = false;
    var j: usize = points.len - 1;
    for (points, 0..) |a, i| {
        const b: Vec2 = points[j];
        if (((a[1] > point[1]) != (b[1] > point[1])) and
            (point[0] < (b[0] - a[0]) * (point[1] - a[1]) / (b[1] - a[1]) + a[0]))
        {
            inside = !inside;
        }
        j = i;
    }
    return inside;
}

/// Test if two axis-aligned rectangles overlap.
pub fn checkCollisionRecs(rec1: Rectangle, rec2: Rectangle) bool {
    return (rec1.x < (rec2.x + rec2.width) and (rec1.x + rec1.width) > rec2.x) and
        (rec1.y < (rec2.y + rec2.height) and (rec1.y + rec1.height) > rec2.y);
}

/// Test if two circles overlap.
pub fn checkCollisionCircles(
    center1: Vec2,
    radius1: f32,
    center2: Vec2,
    radius2: f32,
) bool {
    const dx: f32 = center2[0] - center1[0];
    const dy: f32 = center2[1] - center1[1];
    const dist_sq: f32 = dx * dx + dy * dy;
    const r_sum: f32 = radius1 + radius2;
    return dist_sq <= (r_sum * r_sum);
}

/// Test if a circle overlaps a rectangle. Clamps the circle center to the
/// rectangle's nearest edge and checks the squared distance.
pub fn checkCollisionCircleRec(
    center: Vec2,
    radius: f32,
    rec: Rectangle,
) bool {
    const rec_cx: f32 = rec.x + rec.width / 2.0;
    const rec_cy: f32 = rec.y + rec.height / 2.0;
    const dx: f32 = @abs(center[0] - rec_cx);
    const dy: f32 = @abs(center[1] - rec_cy);
    if (dx > (rec.width / 2.0 + radius)) {
        return false;
    }
    if (dy > (rec.height / 2.0 + radius)) {
        return false;
    }
    if (dx <= (rec.width / 2.0)) {
        return true;
    }
    if (dy <= (rec.height / 2.0)) {
        return true;
    }
    const corner_dx: f32 = dx - rec.width / 2.0;
    const corner_dy: f32 = dy - rec.height / 2.0;
    const corner_dist_sq: f32 = corner_dx * corner_dx + corner_dy * corner_dy;
    return corner_dist_sq <= (radius * radius);
}

/// Test if a circle overlaps a line segment.
pub fn checkCollisionCircleLine(
    center: Vec2,
    radius: f32,
    p1: Vec2,
    p2: Vec2,
) bool {
    const dx: f32 = p1[0] - p2[0];
    const dy: f32 = p1[1] - p2[1];
    if ((@abs(dx) + @abs(dy)) <= floatEps(f32)) {
        // Degenerate segment: just a point.
        const ddx: f32 = p1[0] - center[0];
        const ddy: f32 = p1[1] - center[1];
        return (ddx * ddx + ddy * ddy) <= (radius * radius);
    }
    const len_sq: f32 = dx * dx + dy * dy;
    const dot_prod: f32 = ((center[0] - p1[0]) * (p2[0] - p1[0]) + (center[1] - p1[1]) * (p2[1] - p1[1])) / len_sq;
    var dot_clamped: f32 = dot_prod;
    if (dot_clamped < 0) {
        dot_clamped = 0;
    }
    if (dot_clamped > 1) {
        dot_clamped = 1;
    }
    const closest_x: f32 = p1[0] + dot_clamped * (p2[0] - p1[0]);
    const closest_y: f32 = p1[1] + dot_clamped * (p2[1] - p1[1]);
    const ddx: f32 = closest_x - center[0];
    const ddy: f32 = closest_y - center[1];
    return (ddx * ddx + ddy * ddy) <= (radius * radius);
}

/// Test if two line segments intersect. If `collisionPoint` is non-null and
/// the segments do intersect, the intersection point is written through it.
/// Uses the parametric form: each line is parameterized as `start + t*r`,
/// solve for t and u (parameters along line 1 and line 2 respectively), and
/// require both to lie in [0, 1] for the intersection to fall within both
/// segments. Same algorithm as raylib's C version.
/// Find the intersection point of two line segments, or `null` if they
/// don't intersect.  Replaces raylib's `(bool, *Vec2)` shape with a
/// single typed-optional return - the caller naturally gets the point
/// from `if (checkCollisionLines(...)) |hit| { ... }`.
pub fn checkCollisionLines(
    startPos1: Vec2,
    endPos1: Vec2,
    startPos2: Vec2,
    endPos2: Vec2,
) ?Vec2 {
    const rx: f32 = endPos1[0] - startPos1[0];
    const ry: f32 = endPos1[1] - startPos1[1];
    const sx: f32 = endPos2[0] - startPos2[0];
    const sy: f32 = endPos2[1] - startPos2[1];
    const div: f32 = rx * sy - ry * sx;
    if (@abs(div) < floatEps(f32)) {
        return null; // parallel
    }

    const s12x: f32 = startPos2[0] - startPos1[0];
    const s12y: f32 = startPos2[1] - startPos1[1];
    const t: f32 = (s12x * sy - s12y * sx) / div;
    const u: f32 = (s12x * ry - s12y * rx) / div;
    if (t < 0.0 or t > 1.0 or u < 0.0 or u > 1.0) {
        return null;
    }

    return .{ startPos1[0] + t * rx, startPos1[1] + t * ry };
}

/// Test if a point lies on a line within `threshold` pixels (Euclidean).
pub fn checkCollisionPointLine(
    point: Vec2,
    p1: Vec2,
    p2: Vec2,
    threshold: i32,
) bool {
    const dxc: f32 = point[0] - p1[0];
    const dyc: f32 = point[1] - p1[1];
    const dxl: f32 = p2[0] - p1[0];
    const dyl: f32 = p2[1] - p1[1];
    const cross_z: f32 = dxc * dyl - dyc * dxl;
    if (@abs(cross_z) >= (float(threshold) * @max(@abs(dxl), @abs(dyl)))) {
        return false;
    }
    if (@abs(dxl) >= @abs(dyl)) {
        return if (dxl > 0)
            (p1[0] <= point[0] and point[0] <= p2[0])
        else
            (p2[0] <= point[0] and point[0] <= p1[0]);
    } else {
        return if (dyl > 0)
            (p1[1] <= point[1] and point[1] <= p2[1])
        else
            (p2[1] <= point[1] and point[1] <= p1[1]);
    }
}

/// Get the rectangle representing the overlap between two rectangles.
/// Returns a zero-size rectangle when there's no overlap.
pub fn getCollisionRec(rec1: Rectangle, rec2: Rectangle) Rectangle {
    var overlap: Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const left: f32 = if (rec1.x > rec2.x) rec1.x else rec2.x;
    const right1: f32 = rec1.x + rec1.width;
    const right2: f32 = rec2.x + rec2.width;
    const right: f32 = if (right1 < right2) right1 else right2;
    const top: f32 = if (rec1.y > rec2.y) rec1.y else rec2.y;
    const bottom1: f32 = rec1.y + rec1.height;
    const bottom2: f32 = rec2.y + rec2.height;
    const bottom: f32 = if (bottom1 < bottom2) bottom1 else bottom2;
    if (left < right and top < bottom) {
        overlap.x = left;
        overlap.y = top;
        overlap.width = right - left;
        overlap.height = bottom - top;
    }
    return overlap;
}

// Step 2: simple primitive draws
//
// Pixel, line, rectangle, triangle. The rectangle and pixel draws use the
// shapes texture so they can batch with textured drawing in the same
// rlBegin/End. drawLineThick + drawTriangleStrip are also here because
// drawLineThick forwards to drawTriangleStrip.

/// Texture coordinates spanning the current shapes-texture sub-rectangle.
const ShapesUV = struct { u0: f32, u1: f32, v0: f32, v1: f32 };

inline fn shapesUv(state: *const ShapesTextureState) ShapesUV {
    const tw: f32 = float(state.texture.width);
    const th: f32 = float(state.texture.height);
    return .{
        .u0 = state.source.x / tw,
        .u1 = (state.source.x + state.source.width) / tw,
        .v0 = state.source.y / th,
        .v1 = (state.source.y + state.source.height) / th,
    };
}

/// Emit a textured quad with the four corner vertices in winding order
/// `[top-left, bottom-left, bottom-right, top-right]` - same convention
/// as raylib uses everywhere. Wraps the rlBegin/rlEnd boilerplate that
/// would otherwise repeat in every solid-color shape draw.
fn emitTexturedQuad(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    p0: Vec2,
    p1: Vec2,
    p2: Vec2,
    p3: Vec2,
    color: Color,
) void {
    gl.setTexture(shapes_state.texture.id);
    const uv: ShapesUV = shapesUv(shapes_state);
    gl.begin(.quads);
    gl.normal3f(0, 0, 1);
    gl.color4ub(color.r, color.g, color.b, color.a);
    gl.texCoord2f(uv.u0, uv.v0);
    gl.vertex2f(p0[0], p0[1]);
    gl.texCoord2f(uv.u0, uv.v1);
    gl.vertex2f(p1[0], p1[1]);
    gl.texCoord2f(uv.u1, uv.v1);
    gl.vertex2f(p2[0], p2[1]);
    gl.texCoord2f(uv.u1, uv.v0);
    gl.vertex2f(p3[0], p3[1]);
    gl.end();
    gl.setTexture(0);
}

/// Draw a single pixel using a Vec2 position.
pub fn drawPixelV(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    position: Vec2,
    color: Color,
) void {
    emitTexturedQuad(
        gl,
        shapes_state,
        .{ position[0], position[1] },
        .{ position[0], position[1] + 1 },
        .{ position[0] + 1, position[1] + 1 },
        .{ position[0] + 1, position[1] },
        color,
    );
}

/// Draw a single pixel (1×1 textured quad). The integer overload forwards
/// to the float version.
pub fn drawPixel(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    posX: i32,
    posY: i32,
    color: Color,
) void {
    drawPixelV(gl, shapes_state, .{ @floatFromInt(posX), @floatFromInt(posY) }, color);
}

/// Draw a 1px line using GL lines. For thicker lines see `drawLineThick`.
pub fn drawLine(
    gl: anytype,
    startPosX: i32,
    startPosY: i32,
    endPosX: i32,
    endPosY: i32,
    color: Color,
) void {
    gl.begin(.lines);
    gl.color4ub(color.r, color.g, color.b, color.a);
    gl.vertex2f(@floatFromInt(startPosX), @floatFromInt(startPosY));
    gl.vertex2f(@floatFromInt(endPosX), @floatFromInt(endPosY));
    gl.end();
}

/// Draw a 1px line between two Vec2 endpoints.
pub fn drawLineV(
    gl: anytype,
    startPos: Vec2,
    endPos: Vec2,
    color: Color,
) void {
    gl.begin(.lines);
    gl.color4ub(color.r, color.g, color.b, color.a);
    gl.vertex2f(startPos[0], startPos[1]);
    gl.vertex2f(endPos[0], endPos[1]);
    gl.end();
}

/// Draw a triangle ribbon (sequence of pairs of vertices on opposite
/// edges) as a strip of quads.  Used by drawLineThick + drawSpline*
/// + drawLineBezier — all of which produce ribbon-style strips of
/// 4+ vertices where pairs `(2k, 2k+1)` are the two ends of one
/// cross-section.
///
/// Why RL_QUADS, not RL_TRIANGLES: WebGL2's textured batch path in
/// rlgl only samples the bound texture for RL_QUADS draw calls.
/// RL_TRIANGLES emits geometry but the shader path either doesn't
/// bind texture0 properly or doesn't honor UV interpolation, so
/// fragments render with zero (invisible) alpha.  raylib's
/// `rshapes.c` header comment is explicit: "Use QUADS instead of
/// TRIANGLES for drawing when possible," and issue #4347 spells out
/// "Texturing is only supported on RL_QUADS."  zimr inherits the
/// same WebGL2 batch shader so the same constraint applies.
///
/// Ribbon → quads mapping: vertices `[i, i+1]` form one cross-
/// section, `[i+2, i+3]` form the next_turns, and together they make one
/// quad in order `(i, i+1, i+3, i+2)` to keep consistent winding.
/// The loop strides by 2 since each iteration advances by one
/// cross-section.  Input with fewer than 4 vertices is a no-op
/// (one cross-section alone doesn't form a quad).
pub fn drawTriangleStrip(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    points: []const Vec2,
    color: Color,
) void {
    if (points.len < 4) {
        return;
    }
    gl.setTexture(shapes_state.texture.id);
    const uv: ShapesUV = shapesUv(shapes_state);
    gl.begin(.quads);
    gl.color4ub(color.r, color.g, color.b, color.a);
    var i: usize = 0;
    while (i + 3 < points.len) : (i += 2) {
        gl.texCoord2f(uv.u0, uv.v0);
        gl.vertex2f(points[i][0], points[i][1]);
        gl.texCoord2f(uv.u0, uv.v0);
        gl.vertex2f(points[i + 1][0], points[i + 1][1]);
        gl.texCoord2f(uv.u0, uv.v0);
        gl.vertex2f(points[i + 3][0], points[i + 3][1]);
        gl.texCoord2f(uv.u0, uv.v0);
        gl.vertex2f(points[i + 2][0], points[i + 2][1]);
    }
    gl.end();
    gl.setTexture(0);
}

/// Draw a thick line as a triangle strip. The strip's two long edges are
/// offset perpendicular to the line direction by `thick / 2`.
pub fn drawLineThick(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    startPos: Vec2,
    endPos: Vec2,
    thick: f32,
    color: Color,
) void {
    const dx: f32 = endPos[0] - startPos[0];
    const dy: f32 = endPos[1] - startPos[1];
    const len: f32 = @sqrt(dx * dx + dy * dy);
    if (len <= 0 or thick <= 0) {
        return;
    }

    const scale: f32 = thick / (2 * len);
    // Perpendicular offset: rotate (dx, dy) by 90° and scale to thick/2.
    const rx: f32 = -scale * dy;
    const ry: f32 = scale * dx;
    const strip = [_]Vec2{
        .{ startPos[0] - rx, startPos[1] - ry },
        .{ startPos[0] + rx, startPos[1] + ry },
        .{ endPos[0] - rx, endPos[1] - ry },
        .{ endPos[0] + rx, endPos[1] + ry },
    };
    drawTriangleStrip(gl, shapes_state, &strip, color);
}

/// Draw a filled rectangle with a rotation pivot and rotation angle_turns (radians).
/// `origin` is the rotation pivot, expressed relative to the rectangle's
/// top-left corner. `rotation_turns` is in radians (zimr is radians-centric).
pub fn drawRectanglePro(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    rec: Rectangle,
    origin: Vec2,
    rotation_turns: f32,
    color: Color,
) void {
    var top_left: Vec2 = undefined;
    var top_right: Vec2 = undefined;
    var bottom_left: Vec2 = undefined;
    var bottom_right: Vec2 = undefined;

    if (rotation_turns == 0.0) {
        // Fast path: just an AABB. Avoid the trig.
        const x: f32 = rec.x - origin[0];
        const y: f32 = rec.y - origin[1];
        top_left = .{ x, y };
        top_right = .{ x + rec.width, y };
        bottom_left = .{ x, y + rec.height };
        bottom_right = .{ x + rec.width, y + rec.height };
    } else {
        const sinr: f32 = sinTurns(rotation_turns);
        const cosr: f32 = cosTurns(rotation_turns);
        const x: f32 = rec.x;
        const y: f32 = rec.y;
        const dx: f32 = -origin[0];
        const dy: f32 = -origin[1];
        top_left = .{ x + dx * cosr - dy * sinr, y + dx * sinr + dy * cosr };
        top_right = .{ x + (dx + rec.width) * cosr - dy * sinr, y + (dx + rec.width) * sinr + dy * cosr };
        bottom_left = .{ x + dx * cosr - (dy + rec.height) * sinr, y + dx * sinr + (dy + rec.height) * cosr };
        bottom_right = .{
            x + (dx + rec.width) * cosr - (dy + rec.height) * sinr,
            y + (dx + rec.width) * sinr + (dy + rec.height) * cosr,
        };
    }

    emitTexturedQuad(gl, shapes_state, top_left, bottom_left, bottom_right, top_right, color);
}

/// Draw a filled rectangle from a position and a size.
pub fn drawRectangleV(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    position: Vec2,
    size: Vec2,
    color: Color,
) void {
    drawRectanglePro(
        gl,
        shapes_state,
        .{ .x = position[0], .y = position[1], .width = size[0], .height = size[1] },
        .{ 0, 0 },
        0.0,
        color,
    );
}

/// Draw a filled rectangle. Integer overload forwards to the float version.
pub fn drawRectangle(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    posX: i32,
    posY: i32,
    width: i32,
    height: i32,
    color: Color,
) void {
    drawRectangleV(
        gl,
        shapes_state,
        .{ @floatFromInt(posX), @floatFromInt(posY) },
        .{ @floatFromInt(width), @floatFromInt(height) },
        color,
    );
}

/// Draw a filled rectangle from a Rectangle struct.
pub fn drawRectangleRec(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    rec: Rectangle,
    color: Color,
) void {
    drawRectanglePro(gl, shapes_state, rec, .{ 0, 0 }, 0.0, color);
}

/// Draw a filled triangle. Vertices must be supplied in counter-clockwise
/// winding order, otherwise the triangle will be back-face culled by GL.
pub fn drawTriangle(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    v1: Vec2,
    v2: Vec2,
    v3: Vec2,
    color: Color,
) void {
    gl.setTexture(shapes_state.texture.id);
    const uv: ShapesUV = shapesUv(shapes_state);
    gl.begin(.quads);
    gl.color4ub(color.r, color.g, color.b, color.a);
    gl.normal3f(0, 0, 1);
    // RL_QUADS expands every 4 verts into two triangles via the
    // pre-filled index buffer `(0,1,2, 0,2,3)`.  We emit the
    // triangle TWICE with opposite winding rather than using a
    // degenerate fourth vertex: `(v1, v2, v3, v2)`.
    //   - First triangle (0,1,2) = (v1, v2, v3) — REAL.
    //   - Second triangle (0,2,3) = (v1, v3, v2) — REAL, same area,
    //     opposite winding.
    // The two triangles overlap exactly; on a 1×1 white texture
    // with face culling off (raylib default for 2D), this draws
    // the same pixels twice.  Slightly wasteful but matches the
    // pattern `drawPoly` uses for its wedges, which is the only
    // one that's been observed to actually render in WebGL2's
    // textured-shapes batch path.  Earlier attempts using a
    // degenerate fourth vertex (`v2_dup` or `v3_dup`) produced
    // blank output even though one of the two indexed triangles
    // had non-zero area, which suggests the WebGL2 driver or
    // batch shader has some interaction with leading-or-trailing
    // degenerate triangles in the index group that breaks
    // fragment generation for the whole quad.
    gl.texCoord2f(uv.u0, uv.v0);
    gl.vertex2f(v1[0], v1[1]);
    gl.texCoord2f(uv.u0, uv.v1);
    gl.vertex2f(v2[0], v2[1]);
    gl.texCoord2f(uv.u1, uv.v1);
    gl.vertex2f(v3[0], v3[1]);
    gl.texCoord2f(uv.u1, uv.v0);
    gl.vertex2f(v2[0], v2[1]);
    gl.end();
    gl.setTexture(0);
}

/// Draw a triangle outline using GL lines.
pub fn drawTriangleLines(
    gl: anytype,
    v1: Vec2,
    v2: Vec2,
    v3: Vec2,
    color: Color,
) void {
    gl.begin(.lines);
    gl.color4ub(color.r, color.g, color.b, color.a);
    gl.vertex2f(v1[0], v1[1]);
    gl.vertex2f(v2[0], v2[1]);
    gl.vertex2f(v2[0], v2[1]);
    gl.vertex2f(v3[0], v3[1]);
    gl.vertex2f(v3[0], v3[1]);
    gl.vertex2f(v1[0], v1[1]);
    gl.end();
}

/// Draw a single triangle whose three vertices each carry their own
/// colour, with linear interpolation across the face by the GPU.  The
/// CPU-side equivalent (writes into an `Image`) is `imageDrawTriangleGradient`
/// in the textures namespace.
/// Goes through the rlgl batch path - three `rlColor4ub`/`rlVertex2f`
/// pairs inside a single `rlBegin(RL_TRIANGLES)` scope.  No batch
/// flush.  Degenerate (collinear) input is silently accepted; the GPU
/// rasterises zero pixels.
pub fn drawTriangleGradient(
    gl: anytype,
    v1: Vec2,
    v2: Vec2,
    v3: Vec2,
    c1: Color,
    c2: Color,
    c3: Color,
) void {
    gl.begin(.triangles);
    gl.color4ub(c1.r, c1.g, c1.b, c1.a);
    gl.vertex2f(v1[0], v1[1]);
    gl.color4ub(c2.r, c2.g, c2.b, c2.a);
    gl.vertex2f(v2[0], v2[1]);
    gl.color4ub(c3.r, c3.g, c3.b, c3.a);
    gl.vertex2f(v3[0], v3[1]);
    gl.end();
}

test "drawTriangleGradient: doesn't trap with valid input" {
    var gl: TestGl = .{};
    // rlgl is no-op on host; this just verifies the call path
    // compiles and reaches rlEnd without trapping.
    const v1: Vec2 = .{ 0, 0 };
    const v2: Vec2 = .{ 100, 0 };
    const v3: Vec2 = .{ 50, 100 };
    const red: Color = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const green: Color = .{ .r = 0, .g = 255, .b = 0, .a = 255 };
    const blue: Color = .{ .r = 0, .g = 0, .b = 255, .a = 255 };
    drawTriangleGradient(&gl, v1, v2, v3, red, green, blue);
}

test "drawTriangleGradient: doesn't trap with degenerate (collinear) input" {
    var gl: TestGl = .{};
    // All three vertices on the same horizontal line.  Zero area;
    // the GPU rasterises nothing, but the call must still complete.
    const v1: Vec2 = .{ 0, 50 };
    const v2: Vec2 = .{ 100, 50 };
    const v3: Vec2 = .{ 200, 50 };
    const c: Color = .{ .r = 128, .g = 128, .b = 128, .a = 255 };
    drawTriangleGradient(&gl, v1, v2, v3, c, c, c);
}

// Step 3: multi-vertex draws
//
// Triangle fan, ellipses (filled + lines), regular polygons (filled +
// lines), circle gradient. All emit at most 360/10 = 36 segments on
// fixed-tessellation paths; arc functions with caller-controlled segment
// counts come in Step 4.

/// Draw a triangle fan: a series of triangles all sharing `points[0]` as a
/// common vertex, fanning out around it. `points` must contain at least 3
/// points.
pub fn drawTriangleFan(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    points: []const Vec2,
    color: Color,
) void {
    if (points.len < 3) {
        return;
    }
    gl.setTexture(shapes_state.texture.id);
    const uv: ShapesUV = shapesUv(shapes_state);
    gl.begin(.quads);
    gl.color4ub(color.r, color.g, color.b, color.a);
    for (1..points.len - 1) |i| {
        // One quad per fan triangle: corners (center, p[i], p[i+1], p[i+1]).
        // The duplicated p[i+1] collapses the quad into a triangle while
        // keeping the QUADS primitive count consistent for batching.
        gl.texCoord2f(uv.u0, uv.v0);
        gl.vertex2f(points[0][0], points[0][1]);
        gl.texCoord2f(uv.u0, uv.v1);
        gl.vertex2f(points[i][0], points[i][1]);
        gl.texCoord2f(uv.u1, uv.v1);
        gl.vertex2f(points[i + 1][0], points[i + 1][1]);
        gl.texCoord2f(uv.u1, uv.v0);
        gl.vertex2f(points[i + 1][0], points[i + 1][1]);
    }
    gl.end();
    gl.setTexture(0);
}

/// Draw a filled ellipse using a Vec2 center.
pub fn drawEllipseV(
    gl: anytype,
    center: Vec2,
    radiusH: f32,
    radiusV: f32,
    color: Color,
) void {
    gl.begin(.triangles);
    var i: i32 = 0;
    while (i < 36) : (i += 1) {
        gl.color4ub(color.r, color.g, color.b, color.a);
        gl.vertex2f(center[0], center[1]);
        const a1_turns = float(i + 1) * seg_step36;
        const a0_turns = float(i) * seg_step36;
        gl.vertex2f(center[0] + cosTurns(a1_turns) * radiusH, center[1] + sinTurns(a1_turns) * radiusV);
        gl.vertex2f(center[0] + cosTurns(a0_turns) * radiusH, center[1] + sinTurns(a0_turns) * radiusV);
    }
    gl.end();
}

/// Draw a filled ellipse (axis-aligned, no rotation). The integer overload
/// forwards to the float version.
pub fn drawEllipse(
    gl: anytype,
    centerX: i32,
    centerY: i32,
    radiusH: f32,
    radiusV: f32,
    color: Color,
) void {
    drawEllipseV(gl, .{ @floatFromInt(centerX), @floatFromInt(centerY) }, radiusH, radiusV, color);
}

/// Draw an ellipse outline using a Vec2 center.
pub fn drawEllipseLinesV(
    gl: anytype,
    center: Vec2,
    radiusH: f32,
    radiusV: f32,
    color: Color,
) void {
    gl.begin(.lines);
    var i: i32 = 0;
    while (i < 36) : (i += 1) {
        gl.color4ub(color.r, color.g, color.b, color.a);
        const a1_turns = float(i + 1) * seg_step36;
        const a0_turns = float(i) * seg_step36;
        gl.vertex2f(center[0] + cosTurns(a1_turns) * radiusH, center[1] + sinTurns(a1_turns) * radiusV);
        gl.vertex2f(center[0] + cosTurns(a0_turns) * radiusH, center[1] + sinTurns(a0_turns) * radiusV);
    }
    gl.end();
}

/// Draw an ellipse outline. Integer overload.
pub fn drawEllipseLines(
    gl: anytype,
    centerX: i32,
    centerY: i32,
    radiusH: f32,
    radiusV: f32,
    color: Color,
) void {
    drawEllipseLinesV(gl, .{ @floatFromInt(centerX), @floatFromInt(centerY) }, radiusH, radiusV, color);
}

/// Draw a regular polygon (filled). `sides` is clamped to a minimum of 3.
/// `rotation_turns` is in radians, applied to the first vertex's angle_turns.
pub fn drawPoly(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    center: Vec2,
    sides_in: i32,
    radius: f32,
    rotation_turns: f32,
    color: Color,
) void {
    var sides: i32 = sides_in;
    if (sides < 3) {
        sides = 3;
    }
    var central_turns: f32 = rotation_turns;
    // One turn shared between the sides.
    const step_turns: f32 = 1.0 / float(sides);

    gl.setTexture(shapes_state.texture.id);
    const uv: ShapesUV = shapesUv(shapes_state);
    gl.begin(.quads);
    for (0..@intCast(sides)) |_| {
        gl.color4ub(color.r, color.g, color.b, color.a);
        const next_turns: f32 = central_turns + step_turns;
        // Wedge as a quad: (center, p[i], p[i+1], center). The first and
        // last vertex are both the center, collapsing the quad into a
        // triangle for the polygon segment.
        gl.texCoord2f(uv.u0, uv.v0);
        gl.vertex2f(center[0], center[1]);
        gl.texCoord2f(uv.u0, uv.v1);
        gl.vertex2f(center[0] + cosTurns(central_turns) * radius, center[1] + sinTurns(central_turns) * radius);
        gl.texCoord2f(uv.u1, uv.v0);
        gl.vertex2f(center[0] + cosTurns(next_turns) * radius, center[1] + sinTurns(next_turns) * radius);
        gl.texCoord2f(uv.u1, uv.v1);
        gl.vertex2f(center[0] + cosTurns(central_turns) * radius, center[1] + sinTurns(central_turns) * radius);
        central_turns = next_turns;
    }
    gl.end();
    gl.setTexture(0);
}

/// Draw a regular polygon outline.
pub fn drawPolyLines(
    gl: anytype,
    center: Vec2,
    sides_in: i32,
    radius: f32,
    rotation_turns: f32,
    color: Color,
) void {
    var sides: i32 = sides_in;
    if (sides < 3) {
        sides = 3;
    }
    var central_turns: f32 = rotation_turns;
    // One turn shared between the sides.
    const step_turns: f32 = 1.0 / float(sides);
    gl.begin(.lines);
    for (0..@intCast(sides)) |_| {
        gl.color4ub(color.r, color.g, color.b, color.a);
        gl.vertex2f(center[0] + cosTurns(central_turns) * radius, center[1] + sinTurns(central_turns) * radius);
        gl.vertex2f(
            center[0] + cosTurns(central_turns + step_turns) * radius,
            center[1] + sinTurns(central_turns + step_turns) * radius,
        );
        central_turns += step_turns;
    }
    gl.end();
}

/// Draw a radial gradient circle (inner color at center fading to outer
/// color at the rim). Tessellated into 36 fixed segments - for finer
/// control over segment count use `drawCircleSector`.
pub fn drawCircleGradient(
    gl: anytype,
    center: Vec2,
    radius: f32,
    inner: Color,
    outer: Color,
) void {
    gl.begin(.triangles);
    // 36 segments around the full circle; i is the segment index and
    // a0_turns/a1_turns are its bounds in TURNS: i/36 .. (i+1)/36.
    for (0..36) |seg| {
        const i: i32 = @intCast(seg);
        gl.color4ub(inner.r, inner.g, inner.b, inner.a);
        gl.vertex2f(center[0], center[1]);
        gl.color4ub(outer.r, outer.g, outer.b, outer.a);
        const a1_turns = float(i + 1) * seg_step36;
        gl.vertex2f(center[0] + cosTurns(a1_turns) * radius, center[1] + sinTurns(a1_turns) * radius);
        gl.color4ub(outer.r, outer.g, outer.b, outer.a);
        const a0_turns = float(i) * seg_step36;
        gl.vertex2f(center[0] + cosTurns(a0_turns) * radius, center[1] + sinTurns(a0_turns) * radius);
    }
    gl.end();
}

// Step 4: arcs - circles, circle sectors, rings
//
// All four arc functions (circle sector + lines, ring + lines) share the
// same setup: validate angles, optionally compute an adaptive segment count
// so the arc looks smooth at the requested radius, then walk the arc
// emitting wedge primitives. The plain `drawCircle/V/Lines/LinesV` are thin
// wrappers that forward to the sector versions with start=0, end=360.

/// Maximum chord error rate (in pixels) the adaptive tessellation aims for.
/// Smaller → more segments → smoother arc. 0.5 px is raylib's default and
/// looks crisp at any reasonable display density.
const smooth_circle_error_rate: f32 = 0.5;

/// Compute how many arc segments to use to keep the chord-error below
/// smooth_circle_error_rate at the given radius. If the caller already
/// requested at least `minSegments = ceil(arc_span / (pi/2))`, that's
/// honored; otherwise the formula picks an adaptive count.
fn adaptiveArcSegments(
    start_turns: f32,
    end_turns: f32,
    radius: f32,
    requested: i32,
) i32 {
    // A quarter turn per segment is the floor, which in turns is simply 0.25.
    const min_segments: i32 = @ceil((end_turns - start_turns) / 0.25);
    if (requested >= min_segments) {
        return requested;
    }
    // Solve for the maximum angle_turns between segments such that the chord
    // height at `radius` stays below smooth_circle_error_rate.
    const ratio: f32 = 1.0 - smooth_circle_error_rate / radius;
    // `acos` returns radians, so the count it feeds is converted to turns once here.
    const th_turns: f32 = turnsFromRad(acosRad(2.0 * (ratio * ratio) - 1.0));
    const adaptive: i32 = @trunc((end_turns - start_turns) * @ceil(1.0 / th_turns));
    return if (adaptive <= 0) min_segments else adaptive;
}

/// Draw a circle sector - a wedge of a circle from `start_turns` to
/// `end_turns` (radians). `segments` is a hint; the actual count may be
/// raised if too few are requested for a smooth-looking arc at this
/// radius.
pub fn drawCircleSector(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    center: Vec2,
    radius_in: f32,
    start_turns: f32,
    end_turns: f32,
    segments_in: i32,
    color: Color,
) void {
    var start: f32 = start_turns;
    var end: f32 = end_turns;
    if (start == end) {
        return;
    }
    var radius: f32 = radius_in;
    if (radius <= 0) {
        radius = 0.1; // avoid div-by-zero in the segment math
    }
    if (end < start) {
        std.mem.swap(f32, &start, &end);
    }

    const segments: i32 = adaptiveArcSegments(start, end, radius, segments_in);
    const step_turns: f32 = (end - start) / float(segments);
    var angle_turns: f32 = start;

    gl.setTexture(shapes_state.texture.id);
    const uv: ShapesUV = shapesUv(shapes_state);
    gl.begin(.quads);
    // Each quad covers TWO arc segments (saves one vertex per segment).
    const pairs: i32 = @divFloor(segments, 2);
    for (0..@intCast(pairs)) |_| {
        gl.color4ub(color.r, color.g, color.b, color.a);
        const a0_turns: f32 = angle_turns;
        const a1_turns: f32 = (angle_turns + step_turns);
        const a2_turns: f32 = (angle_turns + step_turns * 2.0);
        gl.texCoord2f(uv.u0, uv.v0);
        gl.vertex2f(center[0], center[1]);
        gl.texCoord2f(uv.u1, uv.v0);
        gl.vertex2f(center[0] + cosTurns(a2_turns) * radius, center[1] + sinTurns(a2_turns) * radius);
        gl.texCoord2f(uv.u1, uv.v1);
        gl.vertex2f(center[0] + cosTurns(a1_turns) * radius, center[1] + sinTurns(a1_turns) * radius);
        gl.texCoord2f(uv.u0, uv.v1);
        gl.vertex2f(center[0] + cosTurns(a0_turns) * radius, center[1] + sinTurns(a0_turns) * radius);
        angle_turns += step_turns * 2.0;
    }
    // Odd-segment leftover: emit a single wedge as a quad with one vertex
    // duplicated at the center.
    if (@mod(segments, 2) == 1) {
        gl.color4ub(color.r, color.g, color.b, color.a);
        const a0_turns: f32 = angle_turns;
        const a1_turns: f32 = (angle_turns + step_turns);
        gl.texCoord2f(uv.u0, uv.v0);
        gl.vertex2f(center[0], center[1]);
        gl.texCoord2f(uv.u1, uv.v1);
        gl.vertex2f(center[0] + cosTurns(a1_turns) * radius, center[1] + sinTurns(a1_turns) * radius);
        gl.texCoord2f(uv.u0, uv.v1);
        gl.vertex2f(center[0] + cosTurns(a0_turns) * radius, center[1] + sinTurns(a0_turns) * radius);
        gl.texCoord2f(uv.u1, uv.v0);
        gl.vertex2f(center[0], center[1]);
    }
    gl.end();
    gl.setTexture(0);
}

/// Draw a circle sector outline: the curved arc plus two radial cap lines
/// connecting the arc endpoints to the center.
pub fn drawCircleSectorLines(
    gl: anytype,
    center: Vec2,
    radius_in: f32,
    start_turns: f32,
    end_turns: f32,
    segments_in: i32,
    color: Color,
) void {
    var start: f32 = start_turns;
    var end: f32 = end_turns;
    if (start == end) {
        return;
    }
    var radius: f32 = radius_in;
    if (radius <= 0) {
        radius = 0.1;
    }
    if (end < start) {
        std.mem.swap(f32, &start, &end);
    }

    const segments: i32 = adaptiveArcSegments(start, end, radius, segments_in);
    const step_turns: f32 = (end - start) / float(segments);
    var angle_turns: f32 = start;

    gl.begin(.lines);
    // Cap line from center to arc start.
    gl.color4ub(color.r, color.g, color.b, color.a);
    gl.vertex2f(center[0], center[1]);
    gl.vertex2f(center[0] + cosTurns(angle_turns) * radius, center[1] + sinTurns(angle_turns) * radius);

    for (0..@intCast(segments)) |_| {
        gl.color4ub(color.r, color.g, color.b, color.a);
        const a0_turns: f32 = angle_turns;
        const a1_turns: f32 = (angle_turns + step_turns);
        gl.vertex2f(center[0] + cosTurns(a0_turns) * radius, center[1] + sinTurns(a0_turns) * radius);
        gl.vertex2f(center[0] + cosTurns(a1_turns) * radius, center[1] + sinTurns(a1_turns) * radius);
        angle_turns += step_turns;
    }

    // Cap line from center to arc end.
    gl.color4ub(color.r, color.g, color.b, color.a);
    gl.vertex2f(center[0], center[1]);
    gl.vertex2f(center[0] + cosTurns(angle_turns) * radius, center[1] + sinTurns(angle_turns) * radius);
    gl.end();
}

/// Draw a filled circle from a Vec2 center.
pub fn drawCircleV(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    center: Vec2,
    radius: f32,
    color: Color,
) void {
    drawCircleSector(gl, shapes_state, center, radius, 0, 1.0, 36, color);
}

/// Draw a filled circle (full 360° sector with 36 segments).
pub fn drawCircle(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    centerX: i32,
    centerY: i32,
    radius: f32,
    color: Color,
) void {
    drawCircleV(gl, shapes_state, .{ @floatFromInt(centerX), @floatFromInt(centerY) }, radius, color);
}

/// Draw a circle outline as 36 line segments around the perimeter.
pub fn drawCircleLinesV(
    gl: anytype,
    center: Vec2,
    radius: f32,
    color: Color,
) void {
    gl.begin(.lines);
    gl.color4ub(color.r, color.g, color.b, color.a);
    var i: i32 = 0;
    while (i < 36) : (i += 1) {
        const a0_turns = float(i) * seg_step36;
        const a1_turns = float(i + 1) * seg_step36;
        gl.vertex2f(center[0] + cosTurns(a0_turns) * radius, center[1] + sinTurns(a0_turns) * radius);
        gl.vertex2f(center[0] + cosTurns(a1_turns) * radius, center[1] + sinTurns(a1_turns) * radius);
    }
    gl.end();
}

/// Draw a circle outline (integer overload).
pub fn drawCircleLines(
    gl: anytype,
    centerX: i32,
    centerY: i32,
    radius: f32,
    color: Color,
) void {
    drawCircleLinesV(gl, .{ @floatFromInt(centerX), @floatFromInt(centerY) }, radius, color);
}

/// Draw a filled ring (annulus) between two radii. If `innerRadius <= 0`
/// this collapses to a `drawCircleSector` call. `end_turns < start_turns`
/// is silently swapped; `outerRadius < innerRadius` is also swapped.
pub fn drawRing(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    center: Vec2,
    innerRadius_in: f32,
    outerRadius_in: f32,
    start_turns: f32,
    end_turns: f32,
    segments_in: i32,
    color: Color,
) void {
    var inner: f32 = innerRadius_in;
    var outer: f32 = outerRadius_in;
    var start: f32 = start_turns;
    var end: f32 = end_turns;
    if (start == end) {
        return;
    }
    if (outer < inner) {
        std.mem.swap(f32, &outer, &inner);
        if (outer <= 0) {
            outer = 0.1;
        }
    }
    if (end < start) {
        std.mem.swap(f32, &start, &end);
    }

    const segments: i32 = adaptiveArcSegments(start, end, outer, segments_in);
    if (inner <= 0) {
        // Collapse to a sector if there's no hole.
        drawCircleSector(gl, shapes_state, center, outer, start, end, segments, color);
        return;
    }

    const step_turns: f32 = (end - start) / float(segments);
    var angle_turns: f32 = start;

    gl.setTexture(shapes_state.texture.id);
    const uv: ShapesUV = shapesUv(shapes_state);
    gl.begin(.quads);
    for (0..@intCast(segments)) |_| {
        gl.color4ub(color.r, color.g, color.b, color.a);
        const a0_turns: f32 = angle_turns;
        const a1_turns: f32 = (angle_turns + step_turns);
        // Each quad spans one segment, with corners on both radii.
        gl.texCoord2f(uv.u0, uv.v1);
        gl.vertex2f(center[0] + cosTurns(a0_turns) * outer, center[1] + sinTurns(a0_turns) * outer);
        gl.texCoord2f(uv.u0, uv.v0);
        gl.vertex2f(center[0] + cosTurns(a0_turns) * inner, center[1] + sinTurns(a0_turns) * inner);
        gl.texCoord2f(uv.u1, uv.v0);
        gl.vertex2f(center[0] + cosTurns(a1_turns) * inner, center[1] + sinTurns(a1_turns) * inner);
        gl.texCoord2f(uv.u1, uv.v1);
        gl.vertex2f(center[0] + cosTurns(a1_turns) * outer, center[1] + sinTurns(a1_turns) * outer);
        angle_turns += step_turns;
    }
    gl.end();
    gl.setTexture(0);
}

/// Draw a ring outline: outer arc + inner arc + two radial cap lines.
pub fn drawRingLines(
    gl: anytype,
    center: Vec2,
    innerRadius_in: f32,
    outerRadius_in: f32,
    start_turns: f32,
    end_turns: f32,
    segments_in: i32,
    color: Color,
) void {
    var inner: f32 = innerRadius_in;
    var outer: f32 = outerRadius_in;
    var start: f32 = start_turns;
    var end: f32 = end_turns;
    if (start == end) {
        return;
    }
    if (outer < inner) {
        std.mem.swap(f32, &outer, &inner);
        if (outer <= 0) {
            outer = 0.1;
        }
    }
    if (end < start) {
        std.mem.swap(f32, &start, &end);
    }

    const segments: i32 = adaptiveArcSegments(start, end, outer, segments_in);
    if (inner <= 0) {
        drawCircleSectorLines(gl, center, outer, start, end, segments, color);
        return;
    }

    const step_turns: f32 = (end - start) / float(segments);
    var angle_turns: f32 = start;

    gl.begin(.lines);
    // Cap line at start.
    gl.color4ub(color.r, color.g, color.b, color.a);
    gl.vertex2f(center[0] + cosTurns(angle_turns) * outer, center[1] + sinTurns(angle_turns) * outer);
    gl.vertex2f(center[0] + cosTurns(angle_turns) * inner, center[1] + sinTurns(angle_turns) * inner);

    for (0..@intCast(segments)) |_| {
        gl.color4ub(color.r, color.g, color.b, color.a);
        const a0_turns: f32 = angle_turns;
        const a1_turns: f32 = (angle_turns + step_turns);
        // Outer arc segment.
        gl.vertex2f(center[0] + cosTurns(a0_turns) * outer, center[1] + sinTurns(a0_turns) * outer);
        gl.vertex2f(center[0] + cosTurns(a1_turns) * outer, center[1] + sinTurns(a1_turns) * outer);
        // Inner arc segment.
        gl.vertex2f(center[0] + cosTurns(a0_turns) * inner, center[1] + sinTurns(a0_turns) * inner);
        gl.vertex2f(center[0] + cosTurns(a1_turns) * inner, center[1] + sinTurns(a1_turns) * inner);
        angle_turns += step_turns;
    }

    // Cap line at end.
    gl.color4ub(color.r, color.g, color.b, color.a);
    gl.vertex2f(center[0] + cosTurns(angle_turns) * outer, center[1] + sinTurns(angle_turns) * outer);
    gl.vertex2f(center[0] + cosTurns(angle_turns) * inner, center[1] + sinTurns(angle_turns) * inner);
    gl.end();
}

// Step 5: line variants + gradients + line rectangles + thick poly outline
/// Number of subdivisions per spline segment for `drawLineBezier`. Matches
/// raylib's default; bigger means smoother curves but more vertices.
const spline_segment_divisions: i32 = 24;

/// Cubic ease-in-out - value `t` in [0, d] eased between [b, b+c]. Used by
/// drawLineBezier to compute the y-position of each curve sample. Matches
/// the static helper of the same name in rshapes.c.
fn easeCubicInOut(t_in: f32, b: f32, c: f32, d: f32) f32 {
    var t: f32 = t_in / (0.5 * d);
    if (t < 1.0) {
        return 0.5 * c * t * t * t + b;
    }
    t -= 2.0;
    return 0.5 * c * (t * t * t + 2.0) + b;
}

/// Draw a polyline through `points`. Each consecutive pair becomes a line.
pub fn drawLineStrip(
    gl: anytype,
    points: []const Vec2,
    color: Color,
) void {
    if (points.len < 2) {
        return;
    }
    gl.begin(.lines);
    gl.color4ub(color.r, color.g, color.b, color.a);
    for (0..points.len - 1) |i| {
        gl.vertex2f(points[i][0], points[i][1]);
        gl.vertex2f(points[i + 1][0], points[i + 1][1]);
    }
    gl.end();
}

/// Draw a thick line that bows along a cubic-eased curve from `startPos` to
/// `endPos`. Despite the name this is NOT a Bézier - only the y-axis is
/// eased; the x-axis is linear. Matches raylib's behaviour for backward
/// compatibility.
pub fn drawLineBezier(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    startPos: Vec2,
    endPos: Vec2,
    thick: f32,
    color: Color,
) void {
    var previous: Vec2 = startPos;
    var current: Vec2 = .{ 0, 0 };

    // Triangle-strip edge ribbon: 2 vertices per sample + 2 for the start.
    // The loop below fills every entry (indices 0..N-1) before the strip
    // is drawn, so leaving them undefined here is safe.
    const N: usize = 2 * @as(usize, @intCast(spline_segment_divisions)) + 2;
    var points: [N]Vec2 = undefined;

    for (1..(spline_segment_divisions + 1)) |i| {
        current[1] = easeCubicInOut(
            @floatFromInt(i),
            startPos[1],
            endPos[1] - startPos[1],
            @floatFromInt(spline_segment_divisions),
        );
        current[0] = previous[0] + (endPos[0] - startPos[0]) / float(spline_segment_divisions);

        const dy: f32 = current[1] - previous[1];
        const dx: f32 = current[0] - previous[0];
        const size: f32 = 0.5 * thick / @sqrt(dx * dx + dy * dy);

        if (i == 1) {
            // Seed both edges of the strip at the start.
            points[0] = .{ previous[0] + dy * size, previous[1] - dx * size };
            points[1] = .{ previous[0] - dy * size, previous[1] + dx * size };
        }

        const idx: usize = 2 * i;
        points[idx + 1] = .{ current[0] - dy * size, current[1] + dx * size };
        points[idx] = .{ current[0] + dy * size, current[1] - dx * size };
        previous = current;
    }

    drawTriangleStrip(gl, shapes_state, &points, color);
}

/// Draw a line as a series of dashes. `dashSize` and `spaceSize` are in
/// pixels along the line. If the line is too short to fit one dash, falls
/// back to a solid line.
pub fn drawLineDashed(
    gl: anytype,
    startPos: Vec2,
    endPos: Vec2,
    dashSize: i32,
    spaceSize: i32,
    color: Color,
) void {
    const dx: f32 = endPos[0] - startPos[0];
    const dy: f32 = endPos[1] - startPos[1];
    const line_length: f32 = @sqrt(dx * dx + dy * dy);
    const dash_size_f: f32 = float(dashSize);
    const space_size_f: f32 = float(spaceSize);

    if (line_length < (dash_size_f + space_size_f) or dashSize <= 0) {
        drawLineV(gl, startPos, endPos, color);
        return;
    }

    const inv_len: f32 = 1.0 / line_length;
    const dir_x: f32 = dx * inv_len;
    const dir_y: f32 = dy * inv_len;

    var current_pos: Vec2 = startPos;
    var traveled: f32 = 0;

    gl.begin(.lines);
    gl.color4ub(color.r, color.g, color.b, color.a);
    while (traveled < line_length) {
        var dash_end_dist: f32 = traveled + dash_size_f;
        if (dash_end_dist > line_length) {
            dash_end_dist = line_length;
        }
        const dash_end_x: f32 = startPos[0] + dash_end_dist * dir_x;
        const dash_end_y: f32 = startPos[1] + dash_end_dist * dir_y;
        gl.vertex2f(current_pos[0], current_pos[1]);
        gl.vertex2f(dash_end_x, dash_end_y);
        traveled = dash_end_dist + space_size_f;
        current_pos[0] = startPos[0] + traveled * dir_x;
        current_pos[1] = startPos[1] + traveled * dir_y;
    }
    gl.end();
}

/// Draw a four-corner gradient rectangle. Each corner gets its own color;
/// GL interpolates linearly across the quad.
pub fn drawRectangleGradientEx(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    rec: Rectangle,
    topLeft: Color,
    bottomLeft: Color,
    bottomRight: Color,
    topRight: Color,
) void {
    gl.setTexture(shapes_state.texture.id);
    const uv: ShapesUV = shapesUv(shapes_state);
    gl.begin(.quads);
    gl.normal3f(0, 0, 1);

    gl.color4ub(topLeft.r, topLeft.g, topLeft.b, topLeft.a);
    gl.texCoord2f(uv.u0, uv.v0);
    gl.vertex2f(rec.x, rec.y);

    gl.color4ub(bottomLeft.r, bottomLeft.g, bottomLeft.b, bottomLeft.a);
    gl.texCoord2f(uv.u0, uv.v1);
    gl.vertex2f(rec.x, rec.y + rec.height);

    gl.color4ub(bottomRight.r, bottomRight.g, bottomRight.b, bottomRight.a);
    gl.texCoord2f(uv.u1, uv.v1);
    gl.vertex2f(rec.x + rec.width, rec.y + rec.height);

    gl.color4ub(topRight.r, topRight.g, topRight.b, topRight.a);
    gl.texCoord2f(uv.u1, uv.v0);
    gl.vertex2f(rec.x + rec.width, rec.y);
    gl.end();
    gl.setTexture(0);
}

/// Draw a vertical-gradient rectangle (top color → bottom color).
pub fn drawRectangleGradientV(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    posX: i32,
    posY: i32,
    width: i32,
    height: i32,
    top: Color,
    bottom: Color,
) void {
    drawRectangleGradientEx(
        gl,
        shapes_state,
        .{
            .x = @floatFromInt(posX),
            .y = @floatFromInt(posY),
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        },
        top,
        bottom,
        bottom,
        top,
    );
}

/// Draw a horizontal-gradient rectangle (left color → right color).
pub fn drawRectangleGradientH(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    posX: i32,
    posY: i32,
    width: i32,
    height: i32,
    left: Color,
    right: Color,
) void {
    drawRectangleGradientEx(
        gl,
        shapes_state,
        .{
            .x = @floatFromInt(posX),
            .y = @floatFromInt(posY),
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        },
        left,
        left,
        right,
        right,
    );
}

/// Draw a 1px rectangle outline. Uses the current modelview transform's
/// scale to nudge each line in by half a pixel - this avoids the line
/// disappearing when the rectangle is rendered at a fractional scale.
pub fn drawRectangleLines(
    gl: anytype,
    posX: i32,
    posY: i32,
    width: i32,
    height: i32,
    color: Color,
) void {
    const mat: Mat = gl.getMatrixTransform();
    const x_offset: f32 = 0.5 / mat[0][0];
    const y_offset: f32 = 0.5 / mat[1][1];
    const x: f32 = float(posX);
    const y: f32 = float(posY);
    const w: f32 = float(width);
    const h: f32 = float(height);

    gl.begin(.lines);
    gl.color4ub(color.r, color.g, color.b, color.a);
    // Top edge
    gl.vertex2f(x + x_offset, y + y_offset);
    gl.vertex2f(x + w - x_offset, y + y_offset);
    // Right edge
    gl.vertex2f(x + w - x_offset, y + y_offset);
    gl.vertex2f(x + w - x_offset, y + h - y_offset);
    // Bottom edge
    gl.vertex2f(x + w - x_offset, y + h - y_offset);
    gl.vertex2f(x + x_offset, y + h - y_offset);
    // Left edge
    gl.vertex2f(x + x_offset, y + h - y_offset);
    gl.vertex2f(x + x_offset, y + y_offset);
    gl.end();
}

/// Draw a thick rectangle outline. `lineThick` is the border thickness in
/// pixels; if it's larger than half the rectangle's smaller dimension,
/// it's clamped to fit.
pub fn drawRectangleLinesThick(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    rec: Rectangle,
    lineThick_in: f32,
    color: Color,
) void {
    var lineThick: f32 = lineThick_in;
    // Clamp lineThick so the four border rectangles don't overlap into the
    // interior when the border would otherwise cover the whole shape.
    if (lineThick > rec.width or lineThick > rec.height) {
        if (rec.width >= rec.height) {
            lineThick = rec.height / 2;
        } else {
            lineThick = rec.width / 2;
        }
    }

    const top = Rectangle{ .x = rec.x, .y = rec.y, .width = rec.width, .height = lineThick };
    const bottom = Rectangle{
        .x = rec.x,
        .y = rec.y - lineThick + rec.height,
        .width = rec.width,
        .height = lineThick,
    };
    const left = Rectangle{
        .x = rec.x,
        .y = rec.y + lineThick,
        .width = lineThick,
        .height = rec.height - lineThick * 2.0,
    };
    const right = Rectangle{
        .x = rec.x - lineThick + rec.width,
        .y = rec.y + lineThick,
        .width = lineThick,
        .height = rec.height - lineThick * 2.0,
    };

    drawRectangleRec(gl, shapes_state, top, color);
    drawRectangleRec(gl, shapes_state, bottom, color);
    drawRectangleRec(gl, shapes_state, left, color);
    drawRectangleRec(gl, shapes_state, right, color);
}

/// Draw a thick polygon outline. Implemented as a ring of trapezoidal
/// quads between an outer vertex (at `radius`) and an inner vertex (at
/// `radius - lineThick * cos(half exterior angle_turns)`), so the outline is
/// drawn entirely INSIDE the polygon's perimeter circle.
pub fn drawPolyLinesThick(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    center: Vec2,
    sides_in: i32,
    radius: f32,
    rotation_turns: f32,
    lineThick: f32,
    color: Color,
) void {
    var sides: i32 = sides_in;
    if (sides < 3) {
        sides = 3;
    }
    var central_turns: f32 = rotation_turns;
    // One turn shared between the sides.
    const ext_turns: f32 = 1.0 / float(sides);
    // Inner radius is offset perpendicular to each edge so the band's width
    // (measured perpendicular to each edge) equals lineThick exactly.
    const inner: f32 = radius - lineThick * cosTurns(ext_turns / 2.0);

    gl.setTexture(shapes_state.texture.id);
    const uv: ShapesUV = shapesUv(shapes_state);
    gl.begin(.quads);
    for (0..@intCast(sides)) |_| {
        gl.color4ub(color.r, color.g, color.b, color.a);
        const next_turns: f32 = central_turns + ext_turns;
        gl.texCoord2f(uv.u0, uv.v1);
        gl.vertex2f(center[0] + cosTurns(central_turns) * radius, center[1] + sinTurns(central_turns) * radius);
        gl.texCoord2f(uv.u0, uv.v0);
        gl.vertex2f(center[0] + cosTurns(central_turns) * inner, center[1] + sinTurns(central_turns) * inner);
        gl.texCoord2f(uv.u1, uv.v1);
        gl.vertex2f(center[0] + cosTurns(next_turns) * inner, center[1] + sinTurns(next_turns) * inner);
        gl.texCoord2f(uv.u1, uv.v0);
        gl.vertex2f(center[0] + cosTurns(next_turns) * radius, center[1] + sinTurns(next_turns) * radius);
        central_turns = next_turns;
    }
    gl.end();
    gl.setTexture(0);
}

// Step 6: rounded rectangles
//
// Rounded rectangles are split into 9 regions: 4 corner arcs + 4 edge
// rectangles + 1 center rectangle. The geometry is identical for the
// filled and outline-with-thickness variants - just the corner-arc
// rendering changes.

/// Draw a filled rectangle with rounded corners. `roundness` is in [0, 1]:
/// 0 = sharp corners, 1 = corner radius equal to half the shorter side.
/// `segments` is a hint for corner-arc tessellation; minimum effective
/// value is 4.
pub fn drawRectangleRounded(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    rec: Rectangle,
    roundness_in: f32,
    segments_in: i32,
    color: Color,
) void {
    if (roundness_in <= 0.0) {
        drawRectangleRec(gl, shapes_state, rec, color);
        return;
    }
    var roundness: f32 = roundness_in;
    if (roundness >= 1.0) {
        roundness = 1.0;
    }
    const radius: f32 = if (rec.width > rec.height)
        (rec.height * roundness) / 2.0
    else
        (rec.width * roundness) / 2.0;
    if (radius <= 0.0) {
        return;
    }

    var segments: i32 = segments_in;
    if (segments < 4) {
        const ratio: f32 = 1.0 - smooth_circle_error_rate / radius;
        // `acos` returns radians, so the count it feeds is converted to turns once here.
        const th_turns: f32 = turnsFromRad(acosRad(2.0 * (ratio * ratio) - 1.0));
        segments = @trunc(@ceil(1.0 / th_turns) / 4.0);
        if (segments <= 0) {
            segments = 4;
        }
    }
    // A quarter turn, split across the corner's segments.
    const step_turns: f32 = 0.25 / float(segments);

    // Twelve geometry anchor points. See ASCII sketch in rshapes.c for
    // reference; P0..P7 lie on the rectangle's outer rounded perimeter,
    // P8..P11 are the four arc-center points (matched 1:1 with `centers`).
    const point: [12]Vec2 = .{
        .{ rec.x + radius, rec.y },
        .{ rec.x + rec.width - radius, rec.y },
        .{ rec.x + rec.width, rec.y + radius },
        .{ rec.x + rec.width, rec.y + rec.height - radius },
        .{ rec.x + rec.width - radius, rec.y + rec.height },
        .{ rec.x + radius, rec.y + rec.height },
        .{ rec.x, rec.y + rec.height - radius },
        .{ rec.x, rec.y + radius },
        .{ rec.x + radius, rec.y + radius },
        .{ rec.x + rec.width - radius, rec.y + radius },
        .{ rec.x + rec.width - radius, rec.y + rec.height - radius },
        .{ rec.x + radius, rec.y + rec.height - radius },
    };
    const centers: [4]Vec2 = .{ point[8], point[9], point[10], point[11] };
    const angles: [4]f32 = .{ pi, pi * 1.5, 0.0, pi * 0.5 };

    gl.setTexture(shapes_state.texture.id);
    const uv: ShapesUV = shapesUv(shapes_state);
    gl.begin(.quads);

    // Four corner arcs. Each quad covers two segments (sector-style) plus
    // an odd-leftover wedge.
    for (0..4) |k| {
        var angle_turns: f32 = angles[k];
        const c: Vec2 = centers[k];
        const pairs: i32 = @divFloor(segments, 2);
        for (0..@intCast(pairs)) |_| {
            gl.color4ub(color.r, color.g, color.b, color.a);
            const a0_turns: f32 = angle_turns;
            const a1_turns: f32 = (angle_turns + step_turns);
            const a2_turns: f32 = (angle_turns + step_turns * 2.0);
            gl.texCoord2f(uv.u0, uv.v0);
            gl.vertex2f(c[0], c[1]);
            gl.texCoord2f(uv.u1, uv.v0);
            gl.vertex2f(c[0] + cosTurns(a2_turns) * radius, c[1] + sinTurns(a2_turns) * radius);
            gl.texCoord2f(uv.u1, uv.v1);
            gl.vertex2f(c[0] + cosTurns(a1_turns) * radius, c[1] + sinTurns(a1_turns) * radius);
            gl.texCoord2f(uv.u0, uv.v1);
            gl.vertex2f(c[0] + cosTurns(a0_turns) * radius, c[1] + sinTurns(a0_turns) * radius);
            angle_turns += step_turns * 2.0;
        }
        if (@mod(segments, 2) == 1) {
            gl.color4ub(color.r, color.g, color.b, color.a);
            const a0_turns: f32 = angle_turns;
            const a1_turns: f32 = (angle_turns + step_turns);
            gl.texCoord2f(uv.u0, uv.v0);
            gl.vertex2f(c[0], c[1]);
            gl.texCoord2f(uv.u1, uv.v1);
            gl.vertex2f(c[0] + cosTurns(a1_turns) * radius, c[1] + sinTurns(a1_turns) * radius);
            gl.texCoord2f(uv.u0, uv.v1);
            gl.vertex2f(c[0] + cosTurns(a0_turns) * radius, c[1] + sinTurns(a0_turns) * radius);
            gl.texCoord2f(uv.u1, uv.v0);
            gl.vertex2f(c[0], c[1]);
        }
    }

    // Five rectangles between the corner arcs (top, right, bottom, left,
    // middle). Each is one quad emitted in TL/BL/BR/TR winding order.
    const FillRect = struct {
        fn go(gl_inner: anytype, uv0: ShapesUV, c: Color, p0: Vec2, p1: Vec2, p2: Vec2, p3: Vec2) void {
            gl_inner.color4ub(c.r, c.g, c.b, c.a);
            gl_inner.texCoord2f(uv0.u0, uv0.v0);
            gl_inner.vertex2f(p0[0], p0[1]);
            gl_inner.texCoord2f(uv0.u0, uv0.v1);
            gl_inner.vertex2f(p1[0], p1[1]);
            gl_inner.texCoord2f(uv0.u1, uv0.v1);
            gl_inner.vertex2f(p2[0], p2[1]);
            gl_inner.texCoord2f(uv0.u1, uv0.v0);
            gl_inner.vertex2f(p3[0], p3[1]);
        }
    }.go;
    FillRect(gl, uv, color, point[0], point[8], point[9], point[1]);
    FillRect(gl, uv, color, point[2], point[9], point[10], point[3]);
    FillRect(gl, uv, color, point[11], point[5], point[4], point[10]);
    FillRect(gl, uv, color, point[7], point[6], point[11], point[8]);
    FillRect(gl, uv, color, point[8], point[11], point[10], point[9]);

    gl.end();
    gl.setTexture(0);
}

/// Draw a thick outline of a rounded rectangle. When `lineThick <= 1`, GL
/// lines are used; otherwise the outline is built from quads (4 corner
/// arcs + 4 edge rectangles).
pub fn drawRectangleRoundedLinesThick(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    rec: Rectangle,
    roundness_in: f32,
    segments_in: i32,
    lineThick_in: f32,
    color: Color,
) void {
    var lineThick: f32 = lineThick_in;
    if (lineThick < 0) {
        lineThick = 0;
    }
    if (roundness_in <= 0.0) {
        // No rounding - fall back to the regular thick-line rectangle.
        drawRectangleLinesThick(
            gl,
            shapes_state,
            .{
                .x = rec.x - lineThick,
                .y = rec.y - lineThick,
                .width = rec.width + 2 * lineThick,
                .height = rec.height + 2 * lineThick,
            },
            lineThick,
            color,
        );
        return;
    }
    var roundness: f32 = roundness_in;
    if (roundness >= 1.0) {
        roundness = 1.0;
    }
    const radius: f32 = if (rec.width > rec.height)
        (rec.height * roundness) / 2.0
    else
        (rec.width * roundness) / 2.0;
    if (radius <= 0.0) {
        return;
    }

    var segments: i32 = segments_in;
    if (segments < 4) {
        const ratio: f32 = 1.0 - smooth_circle_error_rate / radius;
        // `acos` returns radians, so the count it feeds is converted to turns once here.
        const th_turns: f32 = turnsFromRad(acosRad(2.0 * (ratio * ratio) - 1.0));
        segments = @trunc(@ceil(1.0 / th_turns) / 2.0);
        if (segments <= 0) {
            segments = 4;
        }
    }
    // A quarter turn, split across the corner's segments.
    const step_turns: f32 = 0.25 / float(segments);
    const outer: f32 = radius + lineThick;
    const inner: f32 = radius;

    // Sixteen anchor points; the half-pixel offsets nudge edges to the
    // pixel center so the outline doesn't bleed at integer coords. See
    // sketch in rshapes.c.
    const point: [16]Vec2 = .{
        .{ rec.x + inner + 0.5, rec.y - lineThick + 0.5 }, // P0
        .{ rec.x + rec.width - inner - 0.5, rec.y - lineThick + 0.5 }, // P1
        .{ rec.x + rec.width + lineThick - 0.5, rec.y + inner + 0.5 }, // P2
        .{ rec.x + rec.width + lineThick - 0.5, rec.y + rec.height - inner - 0.5 }, // P3
        .{ rec.x + rec.width - inner - 0.5, rec.y + rec.height + lineThick - 0.5 }, // P4
        .{ rec.x + inner + 0.5, rec.y + rec.height + lineThick - 0.5 }, // P5
        .{ rec.x - lineThick + 0.5, rec.y + rec.height - inner - 0.5 }, // P6
        .{ rec.x - lineThick + 0.5, rec.y + inner + 0.5 }, // P7
        .{ rec.x + inner + 0.5, rec.y + 0.5 }, // P8
        .{ rec.x + rec.width - inner - 0.5, rec.y + 0.5 }, // P9
        .{ rec.x + rec.width - 0.5, rec.y + inner + 0.5 }, // P10
        .{ rec.x + rec.width - 0.5, rec.y + rec.height - inner - 0.5 }, // P11
        .{ rec.x + rec.width - inner - 0.5, rec.y + rec.height - 0.5 }, // P12
        .{ rec.x + inner + 0.5, rec.y + rec.height - 0.5 }, // P13
        .{ rec.x + 0.5, rec.y + rec.height - inner - 0.5 }, // P14
        .{ rec.x + 0.5, rec.y + inner + 0.5 }, // P15
    };
    const centers: [4]Vec2 = .{
        .{ rec.x + inner + 0.5, rec.y + inner + 0.5 },
        .{ rec.x + rec.width - inner - 0.5, rec.y + inner + 0.5 },
        .{ rec.x + rec.width - inner - 0.5, rec.y + rec.height - inner - 0.5 },
        .{ rec.x + inner + 0.5, rec.y + rec.height - inner - 0.5 },
    };
    const angles: [4]f32 = .{ pi, pi * 1.5, 0.0, pi * 0.5 };

    if (lineThick > 1.0) {
        gl.setTexture(shapes_state.texture.id);
        const uv: ShapesUV = shapesUv(shapes_state);
        gl.begin(.quads);
        // Four corner arcs, each as a band of trapezoidal quads.
        for (0..4) |k| {
            var angle_turns: f32 = angles[k];
            const c: Vec2 = centers[k];
            for (0..@intCast(segments)) |_| {
                gl.color4ub(color.r, color.g, color.b, color.a);
                const a0_turns: f32 = angle_turns;
                const a1_turns: f32 = (angle_turns + step_turns);
                gl.texCoord2f(uv.u0, uv.v0);
                gl.vertex2f(c[0] + cosTurns(a0_turns) * inner, c[1] + sinTurns(a0_turns) * inner);
                gl.texCoord2f(uv.u1, uv.v0);
                gl.vertex2f(c[0] + cosTurns(a1_turns) * inner, c[1] + sinTurns(a1_turns) * inner);
                gl.texCoord2f(uv.u1, uv.v1);
                gl.vertex2f(c[0] + cosTurns(a1_turns) * outer, c[1] + sinTurns(a1_turns) * outer);
                gl.texCoord2f(uv.u0, uv.v1);
                gl.vertex2f(c[0] + cosTurns(a0_turns) * outer, c[1] + sinTurns(a0_turns) * outer);
                angle_turns += step_turns;
            }
        }
        // Four edge rectangles of the band.
        const edge = struct {
            fn go(gl_inner: anytype, uv0: ShapesUV, c: Color, p0: Vec2, p1: Vec2, p2: Vec2, p3: Vec2) void {
                gl_inner.color4ub(c.r, c.g, c.b, c.a);
                gl_inner.texCoord2f(uv0.u0, uv0.v0);
                gl_inner.vertex2f(p0[0], p0[1]);
                gl_inner.texCoord2f(uv0.u0, uv0.v1);
                gl_inner.vertex2f(p1[0], p1[1]);
                gl_inner.texCoord2f(uv0.u1, uv0.v1);
                gl_inner.vertex2f(p2[0], p2[1]);
                gl_inner.texCoord2f(uv0.u1, uv0.v0);
                gl_inner.vertex2f(p3[0], p3[1]);
            }
        }.go;
        edge(gl, uv, color, point[0], point[8], point[9], point[1]); // top
        edge(gl, uv, color, point[2], point[10], point[11], point[3]); // right
        edge(gl, uv, color, point[13], point[5], point[4], point[12]); // bottom
        edge(gl, uv, color, point[15], point[7], point[6], point[14]); // left
        gl.end();
        gl.setTexture(0);
    } else {
        // Thin (1px) outline: just GL_LINES. Four corner arcs + four
        // straight cap segments connecting them.
        gl.begin(.lines);
        for (0..4) |k| {
            var angle_turns: f32 = angles[k];
            const c: Vec2 = centers[k];
            for (0..@intCast(segments)) |_| {
                gl.color4ub(color.r, color.g, color.b, color.a);
                const a0_turns: f32 = angle_turns;
                const a1_turns: f32 = (angle_turns + step_turns);
                gl.vertex2f(c[0] + cosTurns(a0_turns) * outer, c[1] + sinTurns(a0_turns) * outer);
                gl.vertex2f(c[0] + cosTurns(a1_turns) * outer, c[1] + sinTurns(a1_turns) * outer);
                angle_turns += step_turns;
            }
        }
        var i: usize = 0;
        while (i < 8) : (i += 2) {
            gl.color4ub(color.r, color.g, color.b, color.a);
            gl.vertex2f(point[i][0], point[i][1]);
            gl.vertex2f(point[i + 1][0], point[i + 1][1]);
        }
        gl.end();
    }
}

/// Draw a 1px outline of a rounded rectangle.
pub fn drawRectangleRoundedLines(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    rec: Rectangle,
    roundness: f32,
    segments: i32,
    color: Color,
) void {
    drawRectangleRoundedLinesThick(gl, shapes_state, rec, roundness, segments, 1.0, color);
}

// Step 7: spline drawing
//
// Each spline-segment draw walks the curve in spline_segment_divisions+1
// steps, computes a perpendicular offset (`dy*size, -dx*size` and its
// mirror) at every step_turns, fills a 2-vertex-wide ribbon in points[], and
// hands it to drawTriangleStrip. The multi-segment drawSpline* variants
// chain segment draws and add round caps via drawCircleV.

/// Buffer size for one segment's strip ribbon.
const spline_ribbon_size: usize = 2 * @as(usize, @intCast(spline_segment_divisions)) + 2;

/// Draw a single thick line segment (no curve). Equivalent to drawLineThick;
/// duplicated here for API symmetry with the other drawSplineSegment* fns.
pub fn drawSplineSegmentLinear(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    p1: Vec2,
    p2: Vec2,
    thick: f32,
    color: Color,
) void {
    const dx: f32 = p2[0] - p1[0];
    const dy: f32 = p2[1] - p1[1];
    const len: f32 = @sqrt(dx * dx + dy * dy);
    if (len <= 0 or thick <= 0) {
        return;
    }
    const scale: f32 = thick / (2 * len);
    const rx: f32 = -scale * dy;
    const ry: f32 = scale * dx;
    const strip = [_]Vec2{
        .{ p1[0] - rx, p1[1] - ry },
        .{ p1[0] + rx, p1[1] + ry },
        .{ p2[0] - rx, p2[1] - ry },
        .{ p2[0] + rx, p2[1] + ry },
    };
    drawTriangleStrip(gl, shapes_state, &strip, color);
}

/// Draw a thick polyline by chaining `drawSplineSegmentLinear` segments.
pub fn drawSplineLinear(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    points: []const Vec2,
    thick: f32,
    color: Color,
) void {
    if (points.len < 2) {
        return;
    }
    // Non-mitered fallback (SUPPORT_SPLINE_MITERS is not defined in our
    // config). Each segment is drawn independently; the seams will appear
    // at sharp corners but are visually fine for typical use.
    for (0..points.len - 1) |i| {
        drawSplineSegmentLinear(gl, shapes_state, points[i], points[i + 1], thick, color);
    }
}

/// Draw a thick B-spline curve (uniform cubic). Requires at least 4 points.
pub fn drawSplineBasis(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    points: []const Vec2,
    thick: f32,
    color: Color,
) void {
    if (points.len < 4) {
        return;
    }
    var current: Vec2 = .{ 0, 0 };
    var next_turns: Vec2 = .{ 0, 0 };
    var dx: f32 = 0;
    var dy: f32 = 0;
    var size: f32 = 0;
    var vertices: [spline_ribbon_size]Vec2 = undefined;

    for (0..points.len - 3) |i| {
        const p1: Vec2 = points[i];
        const p2: Vec2 = points[i + 1];
        const p3: Vec2 = points[i + 2];
        const p4: Vec2 = points[i + 3];

        const a0_turns: f32 = (-p1[0] + 3.0 * p2[0] - 3.0 * p3[0] + p4[0]) / 6.0;
        const a1_turns: f32 = (3.0 * p1[0] - 6.0 * p2[0] + 3.0 * p3[0]) / 6.0;
        const a2_turns: f32 = (-3.0 * p1[0] + 3.0 * p3[0]) / 6.0;
        const a3: f32 = (p1[0] + 4.0 * p2[0] + p3[0]) / 6.0;
        const b0: f32 = (-p1[1] + 3.0 * p2[1] - 3.0 * p3[1] + p4[1]) / 6.0;
        const b1: f32 = (3.0 * p1[1] - 6.0 * p2[1] + 3.0 * p3[1]) / 6.0;
        const b2: f32 = (-3.0 * p1[1] + 3.0 * p3[1]) / 6.0;
        const b3: f32 = (p1[1] + 4.0 * p2[1] + p3[1]) / 6.0;

        current[0] = a3;
        current[1] = b3;
        if (i == 0) {
            drawCircleV(gl, shapes_state, current, thick / 2.0, color);
        }

        if (i > 0) {
            // Reuse the dy/dx/size from the previous segment's last sample
            // so the ribbon-start vertices line up across segment seams.
            vertices[0] = .{ current[0] + dy * size, current[1] - dx * size };
            vertices[1] = .{ current[0] - dy * size, current[1] + dx * size };
        }

        for (1..spline_segment_divisions + 1) |j| {
            const t: f32 = float(j) / float(spline_segment_divisions);
            next_turns[0] = a3 + t * (a2_turns + t * (a1_turns + t * a0_turns));
            next_turns[1] = b3 + t * (b2 + t * (b1 + t * b0));
            dy = next_turns[1] - current[1];
            dx = next_turns[0] - current[0];
            size = 0.5 * thick / @sqrt(dx * dx + dy * dy);
            if (i == 0 and j == 1) {
                vertices[0] = .{ current[0] + dy * size, current[1] - dx * size };
                vertices[1] = .{ current[0] - dy * size, current[1] + dx * size };
            }
            const k: usize = 2 * j;
            vertices[k + 1] = .{ next_turns[0] - dy * size, next_turns[1] + dx * size };
            vertices[k] = .{ next_turns[0] + dy * size, next_turns[1] - dx * size };
            current = next_turns;
        }
        drawTriangleStrip(gl, shapes_state, &vertices, color);
    }
    drawCircleV(gl, shapes_state, current, thick / 2.0, color);
}

/// Draw a thick Catmull-Rom spline through `points` (curve passes through
/// each control point except the first and last). Requires at least 4 points.
pub fn drawSplineCatmullRom(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    points: []const Vec2,
    thick: f32,
    color: Color,
) void {
    if (points.len < 4) {
        return;
    }
    var current: Vec2 = points[1];
    var next_turns: Vec2 = .{ 0, 0 };
    var dx: f32 = 0;
    var dy: f32 = 0;
    var size: f32 = 0;
    var vertices: [spline_ribbon_size]Vec2 = undefined;
    drawCircleV(gl, shapes_state, current, thick / 2.0, color);

    for (0..points.len - 3) |i| {
        const p1: Vec2 = points[i];
        const p2: Vec2 = points[i + 1];
        const p3: Vec2 = points[i + 2];
        const p4: Vec2 = points[i + 3];

        if (i > 0) {
            vertices[0] = .{ current[0] + dy * size, current[1] - dx * size };
            vertices[1] = .{ current[0] - dy * size, current[1] + dx * size };
        }
        for (1..spline_segment_divisions + 1) |j| {
            const t: f32 = float(j) / float(spline_segment_divisions);
            const q0: f32 = (-1.0 * t * t * t) + (2.0 * t * t) + (-1.0 * t);
            const q1: f32 = (3.0 * t * t * t) + (-5.0 * t * t) + 2.0;
            const q2: f32 = (-3.0 * t * t * t) + (4.0 * t * t) + t;
            const q3: f32 = t * t * t - t * t;
            next_turns[0] = 0.5 * (p1[0] * q0 + p2[0] * q1 + p3[0] * q2 + p4[0] * q3);
            next_turns[1] = 0.5 * (p1[1] * q0 + p2[1] * q1 + p3[1] * q2 + p4[1] * q3);
            dy = next_turns[1] - current[1];
            dx = next_turns[0] - current[0];
            size = 0.5 * thick / @sqrt(dx * dx + dy * dy);
            if (i == 0 and j == 1) {
                vertices[0] = .{ current[0] + dy * size, current[1] - dx * size };
                vertices[1] = .{ current[0] - dy * size, current[1] + dx * size };
            }
            const k: usize = 2 * j;
            vertices[k + 1] = .{ next_turns[0] - dy * size, next_turns[1] + dx * size };
            vertices[k] = .{ next_turns[0] + dy * size, next_turns[1] - dx * size };
            current = next_turns;
        }
        drawTriangleStrip(gl, shapes_state, &vertices, color);
    }
    drawCircleV(gl, shapes_state, current, thick / 2.0, color);
}

/// Draw a single quadratic Bezier segment (3 points: anchor, control, anchor).
pub fn drawSplineSegmentBezierQuadratic(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    p1: Vec2,
    c2: Vec2,
    p3: Vec2,
    thick: f32,
    color: Color,
) void {
    const inv_div: f32 = 1.0 / float(spline_segment_divisions);
    var previous: Vec2 = p1;
    var current: Vec2 = .{ 0, 0 };
    var points: [spline_ribbon_size]Vec2 = undefined;

    for (1..(spline_segment_divisions + 1)) |i| {
        const t: f32 = inv_div * float(i);
        const a: f32 = pow(1.0 - t, 2.0);
        const b: f32 = 2.0 * (1.0 - t) * t;
        const c: f32 = pow(t, 2.0);
        current[1] = a * p1[1] + b * c2[1] + c * p3[1];
        current[0] = a * p1[0] + b * c2[0] + c * p3[0];
        const dy: f32 = current[1] - previous[1];
        const dx: f32 = current[0] - previous[0];
        const size: f32 = 0.5 * thick / @sqrt(dx * dx + dy * dy);
        if (i == 1) {
            points[0] = .{ previous[0] + dy * size, previous[1] - dx * size };
            points[1] = .{ previous[0] - dy * size, previous[1] + dx * size };
        }
        const k: usize = 2 * i;
        points[k + 1] = .{ current[0] - dy * size, current[1] + dx * size };
        points[k] = .{ current[0] + dy * size, current[1] - dx * size };
        previous = current;
    }
    drawTriangleStrip(gl, shapes_state, &points, color);
}

/// Draw a quadratic Bezier curve chain. Each consecutive triple is
/// `[anchor, control, anchor]`; the curve passes through each anchor.
/// Requires at least 3 points.
pub fn drawSplineBezierQuadratic(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    points: []const Vec2,
    thick: f32,
    color: Color,
) void {
    if (points.len < 3) {
        return;
    }
    // Each curve segment consumes 2 points (anchor, control) plus
    // shares the next_turns anchor - so segment k uses points[2k, 2k+1, 2k+2].
    // Loop until we no longer have a full triple of points.
    const n_segs: usize = @divFloor(points.len - 1, 2);
    for (0..n_segs) |k| {
        const i: usize = k * 2;
        drawSplineSegmentBezierQuadratic(gl, shapes_state, points[i], points[i + 1], points[i + 2], thick, color);
    }
}

/// Draw a single cubic Bezier segment (4 points: anchor, control, control, anchor).
pub fn drawSplineSegmentBezierCubic(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    p1: Vec2,
    c2: Vec2,
    c3: Vec2,
    p4: Vec2,
    thick: f32,
    color: Color,
) void {
    const inv_div: f32 = 1.0 / float(spline_segment_divisions);
    var previous: Vec2 = p1;
    var current: Vec2 = .{ 0, 0 };
    var points: [spline_ribbon_size]Vec2 = undefined;

    for (1..(spline_segment_divisions + 1)) |i| {
        const t: f32 = inv_div * float(i);
        const a: f32 = pow(1.0 - t, 3.0);
        const b: f32 = 3.0 * pow(1.0 - t, 2.0) * t;
        const c: f32 = 3.0 * (1.0 - t) * pow(t, 2.0);
        const d: f32 = pow(t, 3.0);
        current[1] = a * p1[1] + b * c2[1] + c * c3[1] + d * p4[1];
        current[0] = a * p1[0] + b * c2[0] + c * c3[0] + d * p4[0];
        const dy: f32 = current[1] - previous[1];
        const dx: f32 = current[0] - previous[0];
        const size: f32 = 0.5 * thick / @sqrt(dx * dx + dy * dy);
        if (i == 1) {
            points[0] = .{ previous[0] + dy * size, previous[1] - dx * size };
            points[1] = .{ previous[0] - dy * size, previous[1] + dx * size };
        }
        const k: usize = 2 * i;
        points[k + 1] = .{ current[0] - dy * size, current[1] + dx * size };
        points[k] = .{ current[0] + dy * size, current[1] - dx * size };
        previous = current;
    }
    drawTriangleStrip(gl, shapes_state, &points, color);
}

/// Draw a cubic Bezier curve chain. Each consecutive quad is
/// `[anchor, control, control, anchor]`; the curve passes through each
/// anchor. Requires at least 4 points.
pub fn drawSplineBezierCubic(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    points: []const Vec2,
    thick: f32,
    color: Color,
) void {
    if (points.len < 4) {
        return;
    }
    // Segment k uses points[3k, 3k+1, 3k+2, 3k+3].  Loop until we
    // no longer have a full quadruple.
    const n_segs: usize = @divFloor(points.len - 1, 3);
    for (0..n_segs) |k| {
        const i: usize = k * 3;
        drawSplineSegmentBezierCubic(
            gl,
            shapes_state,
            points[i],
            points[i + 1],
            points[i + 2],
            points[i + 3],
            thick,
            color,
        );
    }
}

/// Draw a single B-spline segment (4 control points → 1 curve segment).
pub fn drawSplineSegmentBasis(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    p1: Vec2,
    p2: Vec2,
    p3: Vec2,
    p4: Vec2,
    thick: f32,
    color: Color,
) void {
    const inv_div: f32 = 1.0 / float(spline_segment_divisions);
    var current: Vec2 = .{ 0, 0 };
    var next_turns: Vec2 = .{ 0, 0 };
    var points: [spline_ribbon_size]Vec2 = undefined;

    const a0_turns: f32 = (-p1.x + 3.0 * p2.x - 3.0 * p3.x + p4.x) / 6.0;
    const a1_turns: f32 = (3.0 * p1.x - 6.0 * p2.x + 3.0 * p3.x) / 6.0;
    const a2_turns: f32 = (-3.0 * p1.x + 3.0 * p3.x) / 6.0;
    const a3: f32 = (p1.x + 4.0 * p2.x + p3.x) / 6.0;
    const b0: f32 = (-p1.y + 3.0 * p2.y - 3.0 * p3.y + p4.y) / 6.0;
    const b1: f32 = (3.0 * p1.y - 6.0 * p2.y + 3.0 * p3.y) / 6.0;
    const b2: f32 = (-3.0 * p1.y + 3.0 * p3.y) / 6.0;
    const b3: f32 = (p1.y + 4.0 * p2.y + p3.y) / 6.0;
    current.x = a3;
    current.y = b3;

    for (0..(spline_segment_divisions + 1)) |i| {
        const t: f32 = inv_div * float(i);
        next_turns.x = a3 + t * (a2_turns + t * (a1_turns + t * a0_turns));
        next_turns.y = b3 + t * (b2 + t * (b1 + t * b0));
        const dy: f32 = next_turns.y - current.y;
        const dx: f32 = next_turns.x - current.x;
        const size: f32 = 0.5 * thick / @sqrt(dx * dx + dy * dy);
        if (i == 1) {
            points[0] = .{ current.x + dy * size, current.y - dx * size };
            points[1] = .{ current.x - dy * size, current.y + dx * size };
        }
        const k: usize = 2 * i;
        points[k + 1] = .{ next_turns.x - dy * size, next_turns.y + dx * size };
        points[k] = .{ next_turns.x + dy * size, next_turns.y - dx * size };
        current = next_turns;
    }
    drawTriangleStrip(gl, shapes_state, &points, color);
}

/// Draw a single Catmull-Rom segment (4 control points → 1 curve segment;
/// curve passes through p2 at t=0 and p3 at t=1).
pub fn drawSplineSegmentCatmullRom(
    gl: anytype,
    shapes_state: *const ShapesTextureState,
    p1: Vec2,
    p2: Vec2,
    p3: Vec2,
    p4: Vec2,
    thick: f32,
    color: Color,
) void {
    const inv_div: f32 = 1.0 / float(spline_segment_divisions);
    var current: Vec2 = p1;
    var next_turns: Vec2 = .{ 0, 0 };
    var points: [spline_ribbon_size]Vec2 = undefined;

    for (0..(spline_segment_divisions + 1)) |i| {
        const t: f32 = inv_div * float(i);
        const q0: f32 = (-1.0 * t * t * t) + (2.0 * t * t) + (-1.0 * t);
        const q1: f32 = (3.0 * t * t * t) + (-5.0 * t * t) + 2.0;
        const q2: f32 = (-3.0 * t * t * t) + (4.0 * t * t) + t;
        const q3: f32 = t * t * t - t * t;
        next_turns.x = 0.5 * (p1.x * q0 + p2.x * q1 + p3.x * q2 + p4.x * q3);
        next_turns.y = 0.5 * (p1.y * q0 + p2.y * q1 + p3.y * q2 + p4.y * q3);
        const dy: f32 = next_turns.y - current.y;
        const dx: f32 = next_turns.x - current.x;
        const size: f32 = 0.5 * thick / @sqrt(dx * dx + dy * dy);
        if (i == 1) {
            points[0] = .{ current.x + dy * size, current.y - dx * size };
            points[1] = .{ current.x - dy * size, current.y + dx * size };
        }
        const k: usize = 2 * i;
        points[k + 1] = .{ next_turns.x - dy * size, next_turns.y + dx * size };
        points[k] = .{ next_turns.x + dy * size, next_turns.y - dx * size };
        current = next_turns;
    }
    drawTriangleStrip(gl, shapes_state, &points, color);
}

// ---- tests -------------------------------------------------------- (formerly src/tests/shapes_test.zig)
// rlgl stubs
//
// Step 2 added drawing functions that call into rlgl; the test binary needs
// these symbols to resolve at link time even though the tests below don't
// exercise them.
// Previously this file declared its own `export fn rl*` stubs because
// shapes.zig used `extern fn` declarations.  After the Phase-12-prep
// audit note (historical, GL era): the stub-vs-export collision below
// is moot since GL-retirement P5d.

const eps: f32 = 1e-5;
fn close(a: f32, b: f32) bool {
    return @abs(a - b) < eps;
}
fn closeV2(a: Vec2, b: Vec2) bool {
    return close(a[0], b[0]) and close(a[1], b[1]);
}

// ===========================================================================
// State functions
// ===========================================================================

test "default shapes texture is the 1x1 white pixel" {
    var state: ShapesTextureState = .{};
    const tex: Texture = getShapesTexture(&state);
    try expectEqual(@as(u32, 1), tex.id);
    try expectEqual(@as(i32, 1), tex.width);
    try expectEqual(@as(i32, 1), tex.height);
}

test "default shapes texture rectangle covers the full pixel" {
    var state: ShapesTextureState = .{};
    const r: Rectangle = getShapesTextureRectangle(&state);
    try expect(r.x == 0 and r.y == 0 and r.width == 1 and r.height == 1);
}

test "setShapesTexture stores then retrieves" {
    var state: ShapesTextureState = .{};
    const custom = Texture{ .id = 42, .width = 256, .height = 256, .mipmaps = 1, .format = 7 };
    const rec = Rectangle{ .x = 10, .y = 20, .width = 64, .height = 64 };
    setShapesTexture(&state, custom, rec);
    const got: Texture = getShapesTexture(&state);
    try expectEqual(@as(u32, 42), got.id);
    try expectEqual(@as(i32, 256), got.width);
    const got_r: Rectangle = getShapesTextureRectangle(&state);
    try expect(got_r.x == 10 and got_r.width == 64);
}

test "setShapesTexture with id=0 resets to default white pixel" {
    var state: ShapesTextureState = .{};
    setShapesTexture(
        &state,
        .{ .id = 99, .width = 10, .height = 10, .mipmaps = 1, .format = 7 },
        .{ .x = 1, .y = 1, .width = 1, .height = 1 },
    );
    setShapesTexture(
        &state,
        .{ .id = 0, .width = 0, .height = 0, .mipmaps = 0, .format = 0 },
        .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    );
    const tex: Texture = getShapesTexture(&state);
    try expectEqual(@as(u32, 1), tex.id);
}

// ===========================================================================
// Spline point evaluation
// ===========================================================================

test "Linear spline at endpoints" {
    const a = Vec2{ 0, 0 };
    const b = Vec2{ 10, 20 };
    try expect(closeV2(getSplinePointLinear(a, b, 0.0), a));
    try expect(closeV2(getSplinePointLinear(a, b, 1.0), b));
    try expect(closeV2(getSplinePointLinear(a, b, 0.5), .{ 5, 10 }));
}

test "Catmull-Rom passes through interior control points" {
    // CatmullRom: t=0 → p2, t=1 → p3
    const p1 = Vec2{ 0, 0 };
    const p2 = Vec2{ 10, 0 };
    const p3 = Vec2{ 20, 0 };
    const p4 = Vec2{ 30, 0 };
    try expect(closeV2(getSplinePointCatmullRom(p1, p2, p3, p4, 0.0), p2));
    try expect(closeV2(getSplinePointCatmullRom(p1, p2, p3, p4, 1.0), p3));
}

test "Cubic Bezier passes through start and end points" {
    const start = Vec2{ 0, 0 };
    const c1 = Vec2{ 1, 5 };
    const c2 = Vec2{ 9, 5 };
    const end = Vec2{ 10, 0 };
    try expect(closeV2(getSplinePointBezierCubic(start, c1, c2, end, 0.0), start));
    try expect(closeV2(getSplinePointBezierCubic(start, c1, c2, end, 1.0), end));
}

test "Quadratic Bezier passes through start and end points" {
    const start = Vec2{ 0, 0 };
    const ctl = Vec2{ 5, 10 };
    const end = Vec2{ 10, 0 };
    try expect(closeV2(getSplinePointBezierQuad(start, ctl, end, 0.0), start));
    try expect(closeV2(getSplinePointBezierQuad(start, ctl, end, 1.0), end));
    // At t=0.5, the curve should be halfway in the y direction (5 = avg of 0 and 10)
    const mid: Vec2 = getSplinePointBezierQuad(start, ctl, end, 0.5);
    try expect(close(mid[0], 5.0));
    try expect(close(mid[1], 5.0));
}

test "Basis spline produces a smooth curve (no NaNs)" {
    // B-spline does NOT pass through control points; just verify it produces
    // finite values along the parameter range.
    const p1 = Vec2{ 0, 0 };
    const p2 = Vec2{ 10, 10 };
    const p3 = Vec2{ 20, -10 };
    const p4 = Vec2{ 30, 0 };
    var t: f32 = 0;
    while (t <= 1.0) : (t += 0.1) {
        const p = getSplinePointBasis(p1, p2, p3, p4, t);
        try expect(isFinite(p[0]) and isFinite(p[1]));
    }
}

// ===========================================================================
// Collision detection - points
// ===========================================================================

test "checkCollisionPointRec inside" {
    const r = Rectangle{ .x = 0, .y = 0, .width = 10, .height = 10 };
    try expect(checkCollisionPointRec(.{ 5, 5 }, r));
    try expect(!checkCollisionPointRec(.{ 15, 5 }, r));
    try expect(!checkCollisionPointRec(.{ -1, 5 }, r));
}

test "checkCollisionPointCircle" {
    const center = Vec2{ 0, 0 };
    try expect(checkCollisionPointCircle(.{ 0, 0 }, center, 5.0));
    try expect(checkCollisionPointCircle(.{ 3, 4 }, center, 5.0)); // 3-4-5 triangle, exactly on
    try expect(!checkCollisionPointCircle(.{ 4, 4 }, center, 5.0)); // length √32 > 5
}

test "checkCollisionPointTriangle" {
    const p1 = Vec2{ 0, 0 };
    const p2 = Vec2{ 10, 0 };
    const p3 = Vec2{ 5, 10 };
    try expect(checkCollisionPointTriangle(.{ 5, 3 }, p1, p2, p3));
    try expect(!checkCollisionPointTriangle(.{ 100, 100 }, p1, p2, p3));
}

test "checkCollisionPointPoly with a square" {
    const poly = [_]Vec2{
        .{ 0, 0 },
        .{ 10, 0 },
        .{ 10, 10 },
        .{ 0, 10 },
    };
    try expect(checkCollisionPointPoly(.{ 5, 5 }, &poly));
    try expect(!checkCollisionPointPoly(.{ 15, 5 }, &poly));
    try expect(!checkCollisionPointPoly(.{ -1, -1 }, &poly));
}

test "checkCollisionPointPoly with too few points returns false" {
    const tri = [_]Vec2{
        .{ 0, 0 },
        .{ 10, 10 },
    };
    try expect(!checkCollisionPointPoly(.{ 5, 5 }, &tri));
}

test "checkCollisionPointLine: point exactly on segment" {
    const p1 = Vec2{ 0, 0 };
    const p2 = Vec2{ 10, 0 };
    try expect(checkCollisionPointLine(.{ 5, 0 }, p1, p2, 1));
    try expect(!checkCollisionPointLine(.{ 5, 5 }, p1, p2, 1));
}

test "checkCollisionPointLine: threshold lets nearby points hit" {
    const p1 = Vec2{ 0, 0 };
    const p2 = Vec2{ 10, 0 };
    // 2 units off; threshold 5 → hit
    try expect(checkCollisionPointLine(.{ 5, 2 }, p1, p2, 5));
    // 2 units off; threshold 1 → miss
    try expect(!checkCollisionPointLine(.{ 5, 2 }, p1, p2, 1));
}

// ===========================================================================
// Collision detection - shapes
// ===========================================================================

test "checkCollisionRecs: overlap and disjoint" {
    const a = Rectangle{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const b = Rectangle{ .x = 5, .y = 5, .width = 10, .height = 10 };
    const c = Rectangle{ .x = 100, .y = 100, .width = 1, .height = 1 };
    try expect(checkCollisionRecs(a, b));
    try expect(!checkCollisionRecs(a, c));
}

test "checkCollisionCircles" {
    const a = Vec2{ 0, 0 };
    const b = Vec2{ 5, 0 };
    try expect(checkCollisionCircles(a, 3, b, 3)); // gap = -1, overlap
    try expect(!checkCollisionCircles(a, 1, b, 1)); // gap = 3
}

test "checkCollisionCircleRec: corner case (literal)" {
    // Rectangle at (10, 10) with size 10x10. Circle near top-left corner.
    const rec = Rectangle{ .x = 10, .y = 10, .width = 10, .height = 10 };
    // Circle outside corner but radius reaches it
    try expect(checkCollisionCircleRec(.{ 8, 8 }, 3.0, rec));
    // Circle far away
    try expect(!checkCollisionCircleRec(.{ 100, 100 }, 3.0, rec));
    // Circle covering entire rect
    try expect(checkCollisionCircleRec(.{ 15, 15 }, 100.0, rec));
}

test "checkCollisionLines: crossing" {
    const hit: ?Vec2 = checkCollisionLines(
        .{ 0, 0 },
        .{ 10, 10 },
        .{ 0, 10 },
        .{ 10, 0 },
    );
    try expect(hit != null);
    try expect(close(hit.?[0], 5.0));
    try expect(close(hit.?[1], 5.0));
}

test "checkCollisionLines: parallel (no crossing)" {
    const hit: ?Vec2 = checkCollisionLines(
        .{ 0, 0 },
        .{ 10, 0 },
        .{ 0, 5 },
        .{ 10, 5 },
    );
    try expect(hit == null);
}

test "checkCollisionLines: meeting at endpoint" {
    const hit: ?Vec2 = checkCollisionLines(
        .{ 0, 0 },
        .{ 10, 0 },
        .{ 10, 0 },
        .{ 10, 10 },
    );
    try expect(hit != null);
    try expect(close(hit.?[0], 10.0));
    try expect(close(hit.?[1], 0.0));
}

test "checkCollisionLines: segments far apart (extensions cross, segments don't)" {
    // The infinite lines y=x and y=-x+100 cross at (50, 50), but only
    // segments that span x∈[0..10] and x∈[60..70] respectively.
    const hit: ?Vec2 = checkCollisionLines(
        .{ 0, 0 },
        .{ 10, 10 },
        .{ 60, 40 },
        .{ 70, 30 },
    );
    try expect(hit == null);
}

test "checkCollisionCircleLine" {
    const p1 = Vec2{ 0, 0 };
    const p2 = Vec2{ 10, 0 };
    try expect(checkCollisionCircleLine(.{ 5, 1 }, 2.0, p1, p2));
    try expect(!checkCollisionCircleLine(.{ 5, 5 }, 2.0, p1, p2));
    // Circle touches endpoint exactly
    try expect(checkCollisionCircleLine(.{ -2, 0 }, 2.0, p1, p2));
}

test "getCollisionRec for overlapping rectangles" {
    const a = Rectangle{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const b = Rectangle{ .x = 5, .y = 5, .width = 10, .height = 10 };
    const r: Rectangle = getCollisionRec(a, b);
    try expect(r.x == 5 and r.y == 5);
    try expect(r.width == 5 and r.height == 5);
}

test "getCollisionRec for disjoint rectangles returns zero rect" {
    const a = Rectangle{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const b = Rectangle{ .x = 100, .y = 100, .width = 10, .height = 10 };
    const r: Rectangle = getCollisionRec(a, b);
    try expect(r.width == 0 and r.height == 0);
}

test "getCollisionRec is symmetric in argument order" {
    const a = Rectangle{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const b = Rectangle{ .x = 5, .y = 5, .width = 10, .height = 10 };
    const ab: Rectangle = getCollisionRec(a, b);
    const ba: Rectangle = getCollisionRec(b, a);
    try expect(ab.x == ba.x and ab.y == ba.y);
    try expect(ab.width == ba.width and ab.height == ba.height);
}

// ===========================================================================
// Cat 1 slice-API contract tests
// Each of these drawing functions used to take `[*]const Vec2 +
// count: i32`; the count parameter let a buggy caller request more
// vertices than the buffer actually held - undefined memory access, no
// compile-time check.  With the slice form, the count IS the slice
// length, and Zig's array bounds checks catch any internal off-by-one.
// These tests pin the contract: too-short input returns silently
// (matches raylib's lenient behaviour), zero-length input is also
// silent, and the bodies don't index past the slice end on any input
// that meets the documented minimum.
// ===========================================================================

const test_red: Color = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
const test_green: Color = .{ .r = 0, .g = 255, .b = 0, .a = 255 };

test "drawTriangleStrip: too-short slice is a silent no-op" {
    var gl: TestGl = .{};
    const shapes_state: ShapesTextureState = .{};
    // Empty.
    const empty: []const Vec2 = &.{};
    drawTriangleStrip(&gl, &shapes_state, empty, test_red);
    // 1 vertex.
    const one: [1]Vec2 = .{.{ 0, 0 }};
    drawTriangleStrip(&gl, &shapes_state, &one, test_red);
    // 2 vertices.
    const two: [2]Vec2 = .{ .{ 0, 0 }, .{ 1, 0 } };
    drawTriangleStrip(&gl, &shapes_state, &two, test_red);
    // 3 vertices — one cross-section is not yet a quad.  Ribbon
    // semantics require pairs of pairs (4+ verts) before any
    // geometry is emitted.
    const three: [3]Vec2 = .{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 } };
    drawTriangleStrip(&gl, &shapes_state, &three, test_red);
}

test "drawTriangleStrip: 4 vertices is the smallest valid input" {
    var gl: TestGl = .{};
    const shapes_state: ShapesTextureState = .{};
    // Two cross-sections (the minimum ribbon) make one quad.
    const four: [4]Vec2 = .{
        .{ 0, 0 },
        .{ 1, 0 },
        .{ 0, 1 },
        .{ 1, 1 },
    };
    drawTriangleStrip(&gl, &shapes_state, &four, test_red);
    // No assertion - just verifying no panic on the boundary case.
}

test "drawTriangleFan: too-short slice is a silent no-op" {
    var gl: TestGl = .{};
    const shapes_state: ShapesTextureState = .{};
    drawTriangleFan(&gl, &shapes_state, &.{}, test_red);
    const one: [1]Vec2 = .{.{ 0, 0 }};
    drawTriangleFan(&gl, &shapes_state, &one, test_red);
}

test "drawLineStrip: less than 2 points is a silent no-op" {
    var gl: TestGl = .{};
    drawLineStrip(&gl, &.{}, test_red);
    const one: [1]Vec2 = .{.{ 5, 5 }};
    drawLineStrip(&gl, &one, test_red);
}

test "drawLineStrip: 2 points is the smallest valid input" {
    var gl: TestGl = .{};
    const two: [2]Vec2 = .{ .{ 0, 0 }, .{ 10, 10 } };
    drawLineStrip(&gl, &two, test_green);
}

test "drawSplineLinear: less than 2 points is a no-op" {
    var gl: TestGl = .{};
    const shapes_state: ShapesTextureState = .{};
    drawSplineLinear(&gl, &shapes_state, &.{}, 2.0, test_red);
    const one: [1]Vec2 = .{.{ 0, 0 }};
    drawSplineLinear(&gl, &shapes_state, &one, 2.0, test_red);
}

test "drawSplineBasis: less than 4 points is a no-op" {
    var gl: TestGl = .{};
    const shapes_state: ShapesTextureState = .{};
    drawSplineBasis(&gl, &shapes_state, &.{}, 2.0, test_red);
    const three: [3]Vec2 = .{
        .{ 0, 0 },
        .{ 1, 0 },
        .{ 0, 1 },
    };
    drawSplineBasis(&gl, &shapes_state, &three, 2.0, test_red);
}

test "drawSplineCatmullRom: less than 4 points is a no-op" {
    var gl: TestGl = .{};
    const shapes_state: ShapesTextureState = .{};
    drawSplineCatmullRom(&gl, &shapes_state, &.{}, 2.0, test_red);
    const three: [3]Vec2 = .{
        .{ 0, 0 },
        .{ 1, 0 },
        .{ 0, 1 },
    };
    drawSplineCatmullRom(&gl, &shapes_state, &three, 2.0, test_red);
}

test "drawSplineBezierQuadratic: less than 3 points is a no-op" {
    var gl: TestGl = .{};
    const shapes_state: ShapesTextureState = .{};
    drawSplineBezierQuadratic(&gl, &shapes_state, &.{}, 2.0, test_red);
    const two: [2]Vec2 = .{ .{ 0, 0 }, .{ 1, 0 } };
    drawSplineBezierQuadratic(&gl, &shapes_state, &two, 2.0, test_red);
}

test "drawSplineBezierCubic: less than 4 points is a no-op" {
    var gl: TestGl = .{};
    const shapes_state: ShapesTextureState = .{};
    drawSplineBezierCubic(&gl, &shapes_state, &.{}, 2.0, test_red);
    const three: [3]Vec2 = .{
        .{ 0, 0 },
        .{ 1, 0 },
        .{ 0, 1 },
    };
    drawSplineBezierCubic(&gl, &shapes_state, &three, 2.0, test_red);
}

test "checkCollisionPointPoly: empty slice returns false" {
    const empty: []const Vec2 = &.{};
    try expect(!checkCollisionPointPoly(.{ 0, 0 }, empty));
}

test "checkCollisionPointPoly: edge case at exact polygon bound" {
    // Triangle with vertex at origin.  Point exactly AT a vertex
    // the ray-cast algorithm's behaviour at vertices is undefined in
    // strict math, but raylib's port classifies "outside" via the
    // `> 0` strict inequality.  Pin that behaviour.
    const tri = [_]Vec2{
        .{ 0, 0 },
        .{ 10, 0 },
        .{ 0, 10 },
    };
    // Centre of the triangle - clearly inside.
    try expect(checkCollisionPointPoly(.{ 2, 2 }, &tri));
    // Far outside.
    try expect(!checkCollisionPointPoly(.{ 20, 20 }, &tri));
}

// ===========================================================================
// Scissor dispatch (moved from drawing.zig's shaders namespace,
// GL-retirement P4): generic over `gl: anytype` — drives WgpuGl and
// raster; the comptime rlgl arm dies with rlgl in P5d.
// ===========================================================================

/// Begin scissor mode - restrict subsequent drawing to the
/// rectangle (x, y, width, height) in screen coordinates.  Note that
/// raylib defines the scissor rect with its origin at the upper-left,
/// so we flip Y here to match GL's bottom-left expectation.
/// `gl` is the rlgl state (the active batch is flushed and a
/// scissor command is queued onto it).  `window` is read-only
/// the y-flip needs `getRenderHeight` to map upper-left coords
/// to GL's lower-left convention.
pub fn beginScissorMode(
    gl: anytype,
    window: *const runtime.core.WindowState,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) void {
    // GL-retirement P5d: the rlgl arm (scope push + batch flush before
    // changing scissor state) died with the backend; WgpuGl and raster both
    // take the scissor through the generic trait directly.
    gl.enable(.scissor_test);
    // Caller passes coords in the app's LOGICAL space — the same space as `rect`/`circle` and
    // as the UI's clip rects. Getting to framebuffer pixels is TWO transforms, not one:
    //
    //   1. logical -> CSS   : the `.fit` letterbox (scale + centring offset). Identity under
    //                         `.responsive`, where logical IS CSS.
    //   2. CSS -> framebuffer: the device-pixel ratio (render / screen).
    //
    // This function used to do only step_turns 2, which is why it was correct in `.responsive` and
    // silently wrong in `.fit`: the UI's window clipped to a rectangle shifted sideways by the
    // letterbox offset it never applied. Both factors now come from `WindowState`, derived ONCE
    // in wgpu_app — this must not re-derive them (see `logicalToCss`).
    const core_mod = runtime.core;
    const screen_w: i32 = core_mod.getScreenWidth(window);
    const screen_h_logical: i32 = core_mod.getScreenHeight(window);
    const render_w: i32 = core_mod.getRenderWidth(window);
    const render_h: i32 = core_mod.getRenderHeight(window);

    // 1. logical -> CSS.
    const css_x: f32 = float(x) * window.fit_scale + window.fit_off_x;
    const css_y: f32 = float(y) * window.fit_scale + window.fit_off_y;
    const css_w: f32 = float(width) * window.fit_scale;
    const css_h: f32 = float(height) * window.fit_scale;

    // 2. CSS -> framebuffer. On raster the framebuffer IS the canvas (no DPR), so
    // screen == render and the ratio is 1.
    const sx: f32 = if (screen_w > 0) float(render_w) / float(screen_w) else 1;
    const sy: f32 = if (screen_h_logical > 0) float(render_h) / float(screen_h_logical) else 1;
    const dx: i32 = @floor(css_x * sx);
    const dy: i32 = @floor(css_y * sy);
    const dw: i32 = @floor(css_w * sx);
    const dh: i32 = @floor(css_h * sy);
    gl.scissor(dx, render_h - (dy + dh), dw, dh);
}
/// End scissor mode - disable the test entirely.
/// `gl` mutated only to flush the active batch before the
/// scissor is disabled (no scissor read).
pub fn endScissorMode(gl: anytype) void {
    gl.disable(.scissor_test);
}
