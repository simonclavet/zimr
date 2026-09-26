//! robot_sidebyside — the same double pendulum, simulated two ways.
//!
//! ★ THIS IS THE ARGUMENT FOR THE WHOLE PORT, ON ONE SCREEN.
//!
//! LEFT: zimrphysics. Two rigid bodies, each carrying a full pose in world space, held
//! together by revolute constraints that a solver enforces every step.
//!
//! RIGHT: robot.zig. Two numbers. The joints are not enforced — they are the coordinates,
//! so there is nothing to violate.
//!
//! Both start from the same state, with the same masses, at the same timestep. The readout
//! measures how far each engine's joints have come apart: the distance between the two
//! points that a joint says must coincide. On the right it is **exactly zero, forever**,
//! and no amount of speed or stiffness changes that. On the left it is a small number that
//! wanders, and grows when you make the problem harder.
//!
//! ── BE FAIR TO THE LEFT ──
//!
//! zimrphysics is not losing. It is doing something different, and doing it well: for a
//! thousand loose crates, maximal coordinates are the right model, they parallelise, and a
//! millimetre of joint error is invisible. What this demo shows is a SPECIFIC TRADE, not a
//! verdict — and the trade only matters when error accumulates down a chain, which is
//! exactly what a robot arm is. A millimetre at the shoulder is centimetres at the hand.
//!
//! Standard wgpu example contract: a `pub const app: z.AppSpec(State)`.

const std = @import("std");
const common = @import("example_common");

/// A wasm safety trap is a bare `RuntimeError: unreachable` without this - no message, no line.
/// See `common.reportPanic`: six turns of debugging went to a panic that named itself in one
/// build once a handler existed.
pub const panic = std.debug.FullPanic(common.reportPanic);
const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;

const z = @import("zimr");
const zm = @import("zm");
const zp = z.zimrphysics;
const rbt = z.robot;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const vec = zm.vec;
const vec2 = zm.vec2;
const rotate = zm.rotate;
const length3 = zm.length3;
const float = zm.float;

// ---- One set of numbers, used to build BOTH models ----
// Shared deliberately: if the two engines were given even slightly different masses or
// lengths the comparison would be meaningless, and the difference would be invisible.
const upper_half: f32 = 0.22;
const lower_half: f32 = 0.18;
const link_radius: f32 = 0.045;
const density: f32 = 1000.0;
const timestep: f32 = 1.0 / 240.0;
/// Both start here, well away from vertical so the motion is vigorous.
const start_shoulder: f32 = 2.3;
const start_elbow: f32 = -1.5;

const Pendulum = rbt.Spec(.{
    .bodies = &.{
        .{
            .name = "upper",
            .joints = &.{.{ .name = "shoulder", .kind = .hinge, .axis = vec(0, 0, 1), .armature = 0 }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = upper_half, .radius = link_radius } },
                .pos = vec(0, -upper_half, 0),
                .density = density,
            }},
        },
        .{
            .name = "lower",
            .parent = "upper",
            .pos = vec(0, -2.0 * upper_half, 0),
            .joints = &.{.{ .name = "elbow", .kind = .hinge, .axis = vec(0, 0, 1), .armature = 0 }},
            .geoms = &.{.{
                .shape = .{ .capsule = .{ .half_height = lower_half, .radius = link_radius } },
                .pos = vec(0, -lower_half, 0),
                .density = density,
            }},
        },
    },
    .options = .{ .timestep = timestep },
});

const bg: Color = .{ .r = 31, .g = 20, .b = 14, .a = 255 };
const panel: Color = .{ .r = 51, .g = 34, .b = 24, .a = 255 };
const maximal: Color = .{ .r = 211, .g = 95, .b = 51, .a = 255 };
const generalized: Color = .{ .r = 79, .g = 179, .b = 165, .a = 255 };
const text_col: Color = .{ .r = 240, .g = 230, .b = 210, .a = 255 };
const dim_col: Color = .{ .r = 168, .g = 150, .b = 132, .a = 255 };
const alarm: Color = .{ .r = 232, .g = 120, .b = 92, .a = 255 };

const State = struct {
    gpa: Allocator,
    font: z.Font,

    // ---- right: generalized coordinates ----
    model: rbt.Model,
    data: rbt.Data,

    // ---- left: maximal coordinates ----
    world: zp.World,
    upper: zp.BodyHandle,
    lower: zp.BodyHandle,

    accumulator: f32,
    elapsed: f32,
    /// Worst joint-anchor error seen on each side since the last reset. The WORST rather
    /// than the current, because the instantaneous value flickers and the honest question
    /// is how bad it ever gets.
    worst_maximal: f32,
    worst_generalized: f32,

    fn reset(self: *State) !void {
        self.data.reset(&self.model);
        self.data.setJointPos(&self.model, Pendulum.Joint.shoulder, start_shoulder);
        self.data.setJointPos(&self.model, Pendulum.Joint.elbow, start_elbow);
        rbt.forward(&self.model, &self.data);

        // Place the maximal bodies at exactly where the generalized model says its links
        // are. Deriving the left side's initial pose FROM the right side is the only way to
        // be sure both start from the same configuration rather than from two independent
        // transcriptions of the same intent.
        try self.placeBody(self.upper, 1);
        try self.placeBody(self.lower, 2);

        self.accumulator = 0;
        self.elapsed = 0;
        self.worst_maximal = 0;
        self.worst_generalized = 0;
    }

    fn placeBody(self: *State, handle: zp.BodyHandle, link: u32) !void {
        const idx: zp.BodyIndex = handle.index();
        // The robot's body origin is the link's top; the physics body's shape is centred on
        // its own origin, so offset by half a link down the link's own axis.
        const half: f32 = if (link == 1) upper_half else lower_half;
        const centre: Vec = self.data.body_xpos[link] +
            rotate(self.data.body_xrot[link], vec(0, -half, 0));
        try self.world.setTransform(self.gpa, idx, centre, self.data.body_xrot[link]);
        try self.world.setLinearVelocity(self.gpa, handle, zm.vec_zero);
        try self.world.setAngularVelocity(self.gpa, handle, zm.vec_zero);
    }
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{
        .gpa = gpa,
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22),
        .model = try Pendulum.build(gpa),
        .data = undefined,
        .world = try .init(gpa, 16),
        .upper = undefined,
        .lower = undefined,
        .accumulator = 0,
        .elapsed = 0,
        .worst_maximal = 0,
        .worst_generalized = 0,
    };
    s.data = try rbt.Data.init(gpa, &s.model);
    s.world.gravity = vec(0, -9.81, 0);

    const upper_shape: zp.ShapeId = try s.world.shapes.add(gpa, .{
        .capsule = .{ .half_height = upper_half, .radius = link_radius },
    });
    const lower_shape: zp.ShapeId = try s.world.shapes.add(gpa, .{
        .capsule = .{ .half_height = lower_half, .radius = link_radius },
    });
    s.upper = try s.world.createBody(.{
        .shape = upper_shape,
        .position = vec(0, -upper_half, 0),
        .motion_type = .dynamic,
        .density = density,
        // The links must not collide with each other — they overlap at the joint by
        // construction, and a contact there would be an artefact of the discretisation
        // rather than physics. A shared group is how zimrphysics says "same assembly".
        .group_id = 1,
    });
    s.lower = try s.world.createBody(.{
        .shape = lower_shape,
        .position = vec(0, -2.0 * upper_half - lower_half, 0),
        .motion_type = .dynamic,
        .density = density,
        .group_id = 1,
    });

    // An immovable anchor for the shoulder. zimrphysics has no implicit world body, so the
    // pivot has to be a real static body — which is itself a small illustration of the
    // difference: on the generalized side the world is body 0 and needs no representation.
    const anchor_shape: zp.ShapeId = try s.world.shapes.add(gpa, .{ .sphere = .{ .radius = 0.01 } });
    const anchor: zp.BodyHandle = try s.world.createBody(.{
        .shape = anchor_shape,
        .position = vec(0, 0, 0),
        .motion_type = .static,
        .group_id = 1,
    });

    // The two revolute joints, at exactly the anchors the generalized model uses.
    try zp.createRevoluteJoint(&s.world, anchor, s.upper, .{
        .anchor = vec(0, 0, 0),
        .axis = vec(0, 0, 1),
    });
    try zp.createRevoluteJoint(&s.world, s.upper, s.lower, .{
        .anchor = vec(0, -2.0 * upper_half, 0),
        .axis = vec(0, 0, 1),
    });

    try s.reset();
}

fn deinit(gpa: Allocator, s: *State) void {
    s.world.deinit(gpa);
    s.data.deinit();
    s.model.deinit();
    z.unloadFont(gpa, s.font);
}

/// The same measurement on the generalized side.
///
/// Reads the elbow twice — once as the parent's far end, once as the child's origin — and
/// returns the distance between them, exactly as the maximal version does. The answer is
/// structurally zero, because `kinematics` computes the child's origin FROM the parent's
/// pose, so the two expressions are the same number by construction.
///
/// Computed rather than printed as a constant. A hardcoded zero would be a claim; this is a
/// measurement that happens to be zero, and if a future change to `kinematics` ever broke
/// the property, this readout would say so.
fn generalizedJointError(s: *const State) f32 {
    const from_parent: Vec = s.data.body_xpos[1] +
        rotate(s.data.body_xrot[1], vec(0, -2.0 * upper_half, 0));
    const from_child: Vec = s.data.body_xpos[2];
    return length3(from_parent - from_child);
}

/// How far apart the two points a joint says must coincide have actually drifted.
///
/// For the maximal side this is a real measurement: each body carries an independent pose,
/// and the constraint holds them together only to the solver's tolerance. For the
/// generalized side it is a formality — the shared point is computed once from the parent
/// and inherited by the child, so it cannot differ from itself. Measuring both the same way
/// is the point: the number on the right is zero because of what it IS, not because it was
/// specially handled.
fn maximalJointError(s: *const State) f32 {
    const upper: *const zp.Body = &s.world.bodies.data[s.upper.index()];
    const lower: *const zp.Body = &s.world.bodies.data[s.lower.index()];
    // The elbow, as each body believes it to be.
    const from_upper: Vec = upper.com_pos + rotate(upper.rot, vec(0, -upper_half, 0));
    const from_lower: Vec = lower.com_pos + rotate(lower.rot, vec(0, lower_half, 0));
    return length3(from_upper - from_lower);
}

/// How much to scale text and spacing for this viewport.
///
/// ★ NOT A COSMETIC KNOB. A standalone build renders into a canvas at DEVICE resolution: a
/// phone whose CSS width is 400 gives a canvas around 1080 pixels wide, so a font asked for
/// at 13 "pixels" arrives about four CSS pixels tall and is genuinely unreadable. The in-app
/// viewer hides this by rendering smaller; open the same file in a browser full-screen and
/// the labels vanish.
///
/// Scaling against the viewport's SMALLER dimension is resolution-independent — it makes a
/// glyph a fixed fraction of the screen rather than a fixed count of pixels — and gives sane
/// results on a desktop window and a phone alike, without needing the device pixel ratio,
/// which is not exposed here.
fn uiScale(w: f32, h: f32) f32 {
    return @max(1.0, @min(w, h) / 450.0);
}

/// Where each panel sits and how big it is.
///
/// Side by side when the window is wide, STACKED when it is tall. A phone in portrait is
/// roughly 1:2, and forcing two panels across it leaves each one narrower than the pendulum
/// is long — so the arms overrun the divider and the two readouts collide. Choosing the
/// axis from the aspect ratio costs one branch and is the difference between a demo that
/// reads on the device it is looked at on and one that does not.
const Layout = struct {
    /// Panel centres in pixels, and the metres-to-pixels scale they share.
    origin: [2]Vec2,
    scale: f32,
    /// Where each panel's readout line goes.
    label: [2]Vec2,
    stacked: bool,

    fn fit(w: f32, h: f32) Layout {
        const ui: f32 = uiScale(w, h);
        const top: f32 = 112 * ui; // headroom for the title block
        const bottom: f32 = 80 * ui; // the reset button and clock
        const usable_h: f32 = @max(h - top - bottom, 120);
        const stacked: bool = h > w * 1.15;
        // The pendulum reaches `reach` metres from its pivot, and hangs DOWNWARD, so what
        // must fit is the half-width sideways and the full reach below.
        const reach: f32 = 2.0 * (upper_half + lower_half);
        if (stacked) {
            const cell: f32 = usable_h * 0.5;
            const scale: f32 = @min(w * 0.42, cell * 0.40) / reach;
            return .{
                .origin = .{
                    vec2(w * 0.5, top + cell * 0.32),
                    vec2(w * 0.5, top + cell + cell * 0.32),
                },
                .scale = scale,
                .label = .{
                    vec2(16 * ui, top + cell * 0.94),
                    vec2(16 * ui, top + cell + cell * 0.94),
                },
                .stacked = true,
            };
        }
        const scale: f32 = @min(w * 0.20, usable_h * 0.34) / reach;
        return .{
            .origin = .{ vec2(w * 0.27, top + usable_h * 0.30), vec2(w * 0.73, top + usable_h * 0.30) },
            .scale = scale,
            .label = .{ vec2(w * 0.04, top - 14 * ui), vec2(w * 0.52, top - 14 * ui) },
            .stacked = false,
        };
    }

    fn toScreen(self: Layout, side: usize, p: Vec2) Vec2 {
        const o: Vec2 = self.origin[side];
        return vec2(o[0] + p[0] * self.scale, o[1] - p[1] * self.scale);
    }
};

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;
    const w: f32 = float(f.window.screen_width);
    const h: f32 = float(f.window.screen_height);

    s.accumulator += @min(f.time.delta_time, 0.1);
    while (s.accumulator >= timestep) : (s.accumulator -= timestep) {
        zp.step(&s.world, timestep) catch |err| {
            zm.assertUnreachable(@src(), "zimrphysics step failed: {t}", .{err});
        };
        rbt.step(&s.model, &s.data);
        s.elapsed += timestep;
        s.worst_maximal = @max(s.worst_maximal, maximalJointError(s));
        s.worst_generalized = @max(s.worst_generalized, generalizedJointError(s));
    }
    rbt.forward(&s.model, &s.data);

    z.clearViewport(f, bg);
    const ui: f32 = uiScale(w, h);
    const layout: Layout = .fit(w, h);
    // The divider runs across the split, whichever way it goes.
    if (layout.stacked) {
        const mid: f32 = (layout.origin[0][1] + layout.origin[1][1]) * 0.5 + 20;
        gl.line(vec2(20, mid), vec2(w - 20, mid), .{ .color = panel, .thickness = 2 * ui });
    } else {
        gl.line(vec2(w * 0.5, 104 * ui), vec2(w * 0.5, h - 62 * ui), .{ .color = panel, .thickness = 2 * ui });
    }

    // ---- left: maximal ----
    {
        const upper: *const zp.Body = &s.world.bodies.data[s.upper.index()];
        const lower: *const zp.Body = &s.world.bodies.data[s.lower.index()];
        const pivot: Vec = upper.com_pos + rotate(upper.rot, vec(0, upper_half, 0));
        const elbow: Vec = upper.com_pos + rotate(upper.rot, vec(0, -upper_half, 0));
        const elbow_b: Vec = lower.com_pos + rotate(lower.rot, vec(0, lower_half, 0));
        const tip: Vec = lower.com_pos + rotate(lower.rot, vec(0, -lower_half, 0));
        // Drawn as TWO separate links from each body's own pose, deliberately. Where they
        // fail to meet is the joint error, visible as a kink at the elbow — the readout's
        // number, made geometric.
        gl.line(
            layout.toScreen(0, vec2(pivot[0], pivot[1])),
            layout.toScreen(0, vec2(elbow[0], elbow[1])),
            .{ .color = maximal, .thickness = 9 * ui },
        );
        gl.line(
            layout.toScreen(0, vec2(elbow_b[0], elbow_b[1])),
            layout.toScreen(0, vec2(tip[0], tip[1])),
            .{ .color = maximal, .thickness = 9 * ui },
        );
        gl.circle(layout.toScreen(0, vec2(tip[0], tip[1])), 6 * ui, .{ .color = maximal });
        gl.circle(layout.toScreen(0, vec2(0, 0)), 6 * ui, .{ .color = dim_col });
    }

    // ---- right: generalized ----
    {
        const elbow: Vec = s.data.body_xpos[2];
        const tip: Vec = s.data.body_xpos[2] + rotate(s.data.body_xrot[2], vec(0, -2.0 * lower_half, 0));
        gl.line(
            layout.toScreen(1, vec2(0, 0)),
            layout.toScreen(1, vec2(elbow[0], elbow[1])),
            .{ .color = generalized, .thickness = 9 * ui },
        );
        gl.line(
            layout.toScreen(1, vec2(elbow[0], elbow[1])),
            layout.toScreen(1, vec2(tip[0], tip[1])),
            .{ .color = generalized, .thickness = 9 * ui },
        );
        gl.circle(layout.toScreen(1, vec2(tip[0], tip[1])), 6 * ui, .{ .color = generalized });
        gl.circle(layout.toScreen(1, vec2(0, 0)), 6 * ui, .{ .color = dim_col });
    }

    // ---- the readout, which is the actual content ----
    gl.text(
        vec2(16 * ui, 30 * ui),
        "the same pendulum, twice",
        .{ .size = 20 * ui, .color = text_col, .font = &s.font },
    );
    gl.text(
        vec2(16 * ui, 56 * ui),
        "compare the JOINT ERROR, not the pose",
        .{ .size = 13 * ui, .color = text_col, .font = &s.font },
    );
    // ★ Said outright, because without it the demo looks like it is failing. A double
    // pendulum is CHAOTIC: any difference between two simulations — and there will always be
    // one, since the two engines discretise differently — is amplified exponentially, so
    // within seconds the arms are in visibly different poses. That is correct rather than a
    // discrepancy to fix. The claim this demo makes is about how far each engine's own
    // joints have come apart, which is a property of the METHOD and not of the trajectory.
    gl.text(
        vec2(16 * ui, 80 * ui),
        "they drift apart - chaos amplifies any difference. expected.",
        .{ .size = 11 * ui, .color = dim_col, .font = &s.font },
    );

    var buf: [128]u8 = undefined;
    const maximal_now: f32 = maximalJointError(s);
    const left_line: []const u8 = bufPrint(
        &buf,
        "ENFORCED by a solver: error {d:.6} m  (worst {d:.6})",
        .{ maximal_now, s.worst_maximal },
    ) catch "";
    const left_col: Color = if (s.worst_maximal > 1.0e-4) alarm else maximal;
    gl.text(layout.label[0], left_line, .{ .size = 12 * ui, .color = left_col, .font = &s.font });

    var buf2: [128]u8 = undefined;
    // Not a stored number: recomputed the same way as the left, so the zero is earned.
    const right_line: []const u8 = bufPrint(
        &buf2,
        "ARE the coordinates: error {d:.6} m  (worst {d:.6})",
        .{ generalizedJointError(s), s.worst_generalized },
    ) catch "";
    gl.text(layout.label[1], right_line, .{ .size = 12 * ui, .color = generalized, .font = &s.font });

    var buf3: [96]u8 = undefined;
    const clock: []const u8 = bufPrint(&buf3, "t = {d:.1} s", .{s.elapsed}) catch "";
    gl.text(vec2(16 * ui, h - 64 * ui), clock, .{ .size = 12 * ui, .color = dim_col, .font = &s.font });

    const reset_box: z.Rectangle = .{
        .x = 16 * ui,
        .y = h - 52 * ui,
        .width = 180 * ui,
        .height = 42 * ui,
    };
    gl.rect(reset_box, .{ .color = panel });
    gl.text(
        vec2(reset_box.x + 14 * ui, reset_box.y + 28 * ui),
        "re-throw both",
        .{ .size = 14 * ui, .color = text_col, .font = &s.font },
    );
    if (z.isMouseButtonPressed(f.input, .left)) {
        const p: Vec2 = z.getMousePosition(f.input);
        if (p[0] >= reset_box.x and p[0] <= reset_box.x + reset_box.width and
            p[1] >= reset_box.y and p[1] <= reset_box.y + reset_box.height)
        {
            s.reset() catch |err| {
                zm.assertUnreachable(@src(), "reset failed: {t}", .{err});
            };
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - maximal | generalized",
            .width = 900,
            .height = 620,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
