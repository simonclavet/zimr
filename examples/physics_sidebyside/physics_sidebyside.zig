//! physics_sidebyside — two physics worlds, side by side, drawn the way each kind of
//! game would actually draw it.
//!
//!   LEFT  : the 2D engine (`zimrphysics2d`, a Box2D v3 port), rendered like a 2D game —
//!           an orthographic, screen-space pass of flat filled squares into a DrawList.
//!   RIGHT : the 3D engine (`zimrphysics`, a Jolt port), rendered in perspective as cubes,
//!           scoped to the right half of the canvas with `pushViewport`.
//!
//! Each world drops 10 boxes that fall and pile on a static ground. The point of the demo is
//! that the setup and per-step code below read almost line-for-line identically across the two
//! engines — that is what the API harmonization bought. A "Reset" button rebuilds both worlds.
//!
//! Standard wgpu example contract: a `pub const app: z.AppSpec(State)`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const ui = z.ui_real;

const p2 = z.zimrphysics2d; // 2D engine (Box2D v3 port)
const p3 = z.zimrphysics; //  3D engine (Jolt port)

// zm decls bound at file scope (the linter wants no qualified `zm.x` inside fn bodies).
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const Quat = zm.Quat;
const Rot2 = zm.Rot2;
const Color = zm.Color;
const Camera3D = zm.Camera3D;
const Mat = zm.Mat;
const vec = zm.vec;
const vec4 = zm.vec4;
const mulMat = zm.mulMat;
const perspectiveFovRh = zm.perspectiveFovRh;
const matFromQuat = zm.matFromQuat;
const pi = zm.pi;

const box_count: usize = 10;
const fixed_dt: f32 = 1.0 / 60.0;
const world_capacity: u32 = 64;
const half: f32 = 0.5; //   box half-extent (m)
const ground_y: f32 = -3.0;
const ground_hx: f32 = 4.5; // ground half-width (m)

// One palette, shared, so box i looks the same in both worlds.
const palette = [box_count]Color{
    .{ .r = 239, .g = 68, .b = 68, .a = 255 },
    .{ .r = 249, .g = 115, .b = 22, .a = 255 },
    .{ .r = 234, .g = 179, .b = 8, .a = 255 },
    .{ .r = 132, .g = 204, .b = 22, .a = 255 },
    .{ .r = 34, .g = 197, .b = 94, .a = 255 },
    .{ .r = 20, .g = 184, .b = 166, .a = 255 },
    .{ .r = 59, .g = 130, .b = 246, .a = 255 },
    .{ .r = 139, .g = 92, .b = 246, .a = 255 },
    .{ .r = 217, .g = 70, .b = 239, .a = 255 },
    .{ .r = 244, .g = 63, .b = 94, .a = 255 },
};
const ground_color: Color = .{ .r = 71, .g = 85, .b = 105, .a = 255 };
const panel_color: Color = .{ .r = 15, .g = 23, .b = 42, .a = 255 }; // opaque 2D backdrop (slate-900)
const divider_color: Color = .{ .r = 100, .g = 116, .b = 139, .a = 255 };

/// Minimal 2D camera: world metres -> screen pixels, centred at (cx, cy).
const Camera2D = zm.Camera2D;

const State = struct {
    gpa: Allocator,
    ui_host: z.UiHost,
    font: z.Font,
    world2d: p2.World,
    world3d: p3.World,
    boxes2d: [box_count]p2.BodyHandle = undefined,
    boxes3d: [box_count]p3.BodyHandle = undefined,
};

const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

/// A little horizontal scatter per box so the column topples into a natural pile.
fn dropX(i: usize) f32 {
    const fi: f32 = float(i);
    return (@mod(fi, 3.0) - 1.0) * 0.4;
}

// ---------------------------------------------------------------------------------------
// SETUP. The two functions below are written to be as parallel as the engines allow. The
// `createBody(world, .{ .motion_type, .position })` calls are identical; the only real
// difference is the shape model — 2D attaches a shape to the body (Box2D), 3D references a
// shared shape held in a store (Jolt). Both are exactly how each upstream library works.
// ---------------------------------------------------------------------------------------

fn setup2d(world: *p2.World, boxes: *[box_count]p2.BodyHandle) !void {
    // static ground
    const ground: p2.BodyHandle = try p2.createBody(world, .{
        .motion_type = .static,
        .position = .{ 0, ground_y },
    });
    _ = try p2.createShape(world, ground, .{ .geom = .{ .polygon = p2.makeBox(ground_hx, 0.5) } });

    // ten dynamic boxes stacked above the ground, so they fall and pile
    for (0..box_count) |i| {
        const fi: f32 = float(i);
        const body: p2.BodyHandle = try p2.createBody(world, .{
            .motion_type = .dynamic,
            .position = .{ dropX(i), 1.0 + fi * 1.25 },
        });
        _ = try p2.createShape(world, body, .{ .geom = .{ .polygon = p2.makeBox(half, half) } });
        boxes[i] = body;
    }
}

fn setup3d(world: *p3.World, boxes: *[box_count]p3.BodyHandle) !void {
    const gpa: Allocator = world.allocator;
    const ground_geom: p3.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(ground_hx, 0.5, ground_hx), .convex_radius = 0.02 },
    });
    const box_geom: p3.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(half, half, half), .convex_radius = 0.02 },
    });

    // static ground
    _ = try p3.createBody(world, .{
        .motion_type = .static,
        .position = vec(0, ground_y, 0),
        .shape = ground_geom,
    });

    // ten dynamic boxes stacked above the ground, so they fall and pile
    for (0..box_count) |i| {
        const fi: f32 = float(i);
        const body: p3.BodyHandle = try p3.createBody(world, .{
            .motion_type = .dynamic,
            .position = vec(dropX(i), 1.0 + fi * 1.25, dropX(i) * 0.5),
            .shape = box_geom,
        });
        boxes[i] = body;
    }
}

/// Tear both worlds down and rebuild them from scratch (the Reset button).
fn resetWorlds(s: *State) void {
    s.world2d.deinit(s.gpa);
    s.world3d.deinit(s.gpa);
    s.world2d = p2.World.init(s.gpa, world_capacity) catch @panic("reset: 2D world init failed");
    s.world3d = p3.World.init(s.gpa, world_capacity) catch @panic("reset: 3D world init failed");
    s.world3d.gravity = vec(0, -10, 0);
    setup2d(&s.world2d, &s.boxes2d) catch @panic("reset: 2D setup failed");
    setup3d(&s.world3d, &s.boxes3d) catch @panic("reset: 3D setup failed");
}

/// One rotated box corner, taken straight to screen space. `off` is the corner in the body's
/// local frame; `r` is the body's orientation.
fn corner2d(
    cam: Camera2D,
    pos: Vec2,
    r: Rot2,
    off: Vec2,
) Vec2 {
    const wx: f32 = pos[0] + r.cosine * off[0] - r.sine * off[1];
    const wy: f32 = pos[1] + r.sine * off[0] + r.cosine * off[1];
    return cam.worldToScreen(.{ wx, wy });
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, roboto_mono_ttf, 22);
    s.* = .{
        .gpa = gpa,
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
        .world2d = try p2.World.init(gpa, world_capacity),
        .world3d = try p3.World.init(gpa, world_capacity),
    };
    // Match gravity exactly across the two worlds (2D already defaults to -10).
    s.world3d.gravity = vec(0, -10, 0);
    try setup2d(&s.world2d, &s.boxes2d);
    try setup3d(&s.world3d, &s.boxes3d);
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.world2d.deinit(gpa);
    s.world3d.deinit(gpa);
    s.ui_host.deinit();
}

fn update(f: *z.Frame, s: *State) void {
    // STEP — identical across the two engines.
    p2.step(&s.world2d, fixed_dt) catch {};
    p3.step(&s.world3d, fixed_dt) catch {};

    const fw: f32 = f.window.widthf();
    const fh: f32 = f.window.heightf();
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    // ---- RIGHT HALF: the 3D world, in perspective. There is no GPU sub-rect viewport (only a
    // scissor), so beginMode3D would centre world-origin on the *full* screen — i.e. on the divider.
    // Instead we build the view-projection ourselves and shift clip space into the right half:
    //   x' = 0.5*x + 0.5*w   maps NDC x in [-1, 1] -> [0, 1] (the right half),
    // so world-origin lands at the centre of the right half, undistorted at the half-width aspect.
    const cam: Camera3D = .{
        .position = vec(0, 4, 22),
        .target = vec(0, -1, 0),
        .up = vec(0, 1, 0),
        .fovy_deg = 45,
        .projection = 0,
    };
    const fovy_rad: f32 = cam.fovy_deg * (pi / 180.0);
    const proj: Mat = perspectiveFovRh(fovy_rad, (fw * 0.5) / fh, 0.01, 1000.0);
    const shift: Mat = .{
        vec4(0.5, 0, 0, 0),
        vec4(0, 1, 0, 0),
        vec4(0, 0, 1, 0),
        vec4(0.5, 0, 0, 1),
    };
    const view_proj: Mat = mulMat(shift, mulMat(proj, cam.viewMatrix()));
    z.beginMode3DMatrix(f.gl, view_proj);
    z.drawGrid(f.gl, 24, 1.0);
    z.drawCube(f.gl, vec(0, ground_y, 0), .{ .size = vec(2 * ground_hx, 1, 2 * ground_hx), .color = ground_color });
    for (s.boxes3d, 0..) |h, i| {
        const pos: Vec = p3.getPosition(&s.world3d, h);
        const rot: Quat = p3.getRotation(&s.world3d, h);
        z.drawCube(f.gl, pos, .{
            .size = vec(2 * half, 2 * half, 2 * half),
            .rotation = matFromQuat(rot),
            .color = palette[i],
        });
    }
    z.endMode3D(f.gl);

    // ---- LEFT HALF: the 2D world, drawn flat in screen space like a 2D game ----
    const bg: ui.DrawListHandle = u.getBackgroundDrawList();
    // Opaque backdrop for the 2D half (also masks any 3D that bleeds past the viewport edge).
    bg.addRectFilled(.{ .x = 0, .y = 0, .width = fw * 0.5, .height = fh }, panel_color);

    const ppm: f32 = @min((fw * 0.5) / (2 * ground_hx + 2.0), fh / 9.0);
    const cam2d: Camera2D = .{ .target = .{ 0, 0.5 }, .zoom = ppm, .offset = .{ fw * 0.25, fh * 0.5 }, .flip_y = true };

    // ground slab (axis-aligned filled rect)
    const g_tl: Vec2 = cam2d.worldToScreen(.{ -ground_hx, ground_y + 0.5 });
    const g_br: Vec2 = cam2d.worldToScreen(.{ ground_hx, ground_y - 0.5 });
    bg.addRectFilled(.{
        .x = g_tl[0],
        .y = g_tl[1],
        .width = g_br[0] - g_tl[0],
        .height = g_br[1] - g_tl[1],
    }, ground_color);

    // boxes — each a filled, rotated quad (mirrors the 3D loop: get pos, get rot, draw)
    for (s.boxes2d, 0..) |h, i| {
        const pos: Vec2 = p2.getPosition(&s.world2d, h);
        const rot: Rot2 = p2.getRotation(&s.world2d, h);
        const q0: Vec2 = corner2d(cam2d, pos, rot, .{ -half, -half });
        const q1: Vec2 = corner2d(cam2d, pos, rot, .{ half, -half });
        const q2: Vec2 = corner2d(cam2d, pos, rot, .{ half, half });
        const q3: Vec2 = corner2d(cam2d, pos, rot, .{ -half, half });
        bg.addQuadFilled(q0, q1, q2, q3, palette[i]);
    }

    // divider between the two halves
    bg.addLine(.{ fw * 0.5, 0 }, .{ fw * 0.5, fh }, divider_color, 2.0);

    // ---- Reset control ----
    const btn: ui.ButtonOpts = .{ .size = .{ 140, 30 } };
    if (u.window("controls", .{
        .initial_pos = .{ fw * 0.5 - 82, 10 },
        .initial_size = .{ 164, 56 },
        .flags = .{ .no_move = false, .no_resize = true, .no_collapse = true },
    })) |win| {
        defer win.close();
        if (u.button("Reset both", btn)) {
            resetWorlds(s);
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - 2D | 3D physics side by side",
            .width = 1000,
            .height = 560,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
