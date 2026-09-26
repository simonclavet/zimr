//! chain_ik — ten joints for a two-joint job.
//!
//! A ten-link chain, base pinned, tip chasing a target. The task needs two numbers; the chain
//! has ten. **The eight left over are the null space**, and what a solver does with them is
//! usually invisible — in a six-DOF arm a badly conditioned step looks like a small twitch. In a
//! ten-link chain it looks like the whole thing being flung.
//!
//! ── ★★ DRAG THE DAMPING SLIDER, ESPECIALLY NEAR FULL STRETCH ──
//!
//! Damped least squares solves `Δq = Jᵀ(J·Jᵀ + λ²I)⁻¹·e`. Near a singularity — the chain
//! straight out, or folded back — `J·Jᵀ` is ill-conditioned, and a small `λ` asks for enormous
//! joint motion to buy a tiny tip motion. Measured across a sweep that crosses the reachable
//! boundary twice:
//!
//!     damping   worst tip error   peak |Δq| in one solve
//!       0.001          0.98 mm            100.07 rad
//!       0.010          0.89 mm             38.83 rad
//!       0.050          0.93 mm             11.57 rad
//!       0.300          1.00 mm              0.75 rad
//!
//! ★★★ **THE ACCURACY IS THE SAME AND THE MOTION SPANS 133x.** A hundred radians in one solve is
//! sixteen full revolutions of a joint to move a tip by a millimetre. That is the trade damping
//! makes, and inside the workspace it costs nothing at all.
//!
//! ── ★ AND ZERO DAMPING IS NOT THE NAIVE SOLVER, IT IS NO SOLVER ──
//!
//! At `λ = 0` this chain does not move: peak `|Δq|` measured **0.000**. `ctl.Ik` declines a
//! singular solve rather than diverging, which is the right call and means the textbook
//! "undamped versus damped" comparison is not available here. The honest one is between a
//! damping too small to condition the problem and one that does — which is the table above.

const std = @import("std");
const common = @import("example_common");

/// A wasm safety trap is a bare `RuntimeError: unreachable` without this - no message, no line.
/// See `common.reportPanic`: six turns of debugging went to a panic that named itself in one
/// build once a handler existed.
pub const panic = std.debug.FullPanic(common.reportPanic);
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const rbt = z.robot;
const ctl = z.robot_control;
const mjcf = z.mjcf;
const rmj = z.robot_mjcf;
const ui = z.ui;

const Vec = zm.Vec;
const Mat = zm.Mat;
const vec = zm.vec;
const Color = zm.Color;
const Camera3D = zm.Camera3D;
const pi = zm.pi;
const identity = zm.identity;
const translation = zm.translation;
const scaling = zm.scaling;
const mulMat = zm.mulMat;

const background: Color = .{ .r = 18, .g = 20, .b = 28, .a = 255 };
const link_colour: Color = .{ .r = 148, .g = 156, .b = 172, .a = 255 };
const joint_colour: Color = .{ .r = 107, .g = 158, .b = 219, .a = 255 };
const tip_ok: Color = .{ .r = 89, .g = 204, .b = 153, .a = 255 };
const tip_far: Color = .{ .r = 226, .g = 106, .b = 154, .a = 255 };
const target_colour: Color = .{ .r = 237, .g = 184, .b = 89, .a = 255 };
const reach_colour: Color = .{ .r = 64, .g = 72, .b = 88, .a = 255 };

const State = struct {
    gpa: Allocator,
    doc: z.codecs.xml.Document,
    robot: mjcf.Robot,
    imported: rmj.Imported,
    data: rbt.Data,
    actuation: ctl.Actuation,
    ik_scratch: []Vec,
    /// The pose before the last solve, so the joint step it asked for can be measured.
    previous: []f32,
    tip: u32,

    damping: f32,
    /// Where the tip is being sent, in polar terms so a phone can drive it.
    target_radius: f32,
    target_angle: f32,
    auto_sweep: bool,
    sweep_phase: f32,

    tip_error: f32,
    last_step: f32,
    peak_step: f32,
    reached: bool,

    cam: z.OrbitCamera,
    font: z.Font,
    ui_host: z.UiHost,
    cube: z.Mesh,
    sphere: z.Mesh,
    cylinder: z.Mesh,
    transform: [1]Mat,
};

fn targetAt(s: *const State) Vec {
    return vec(s.target_radius * @cos(s.target_angle), 0, s.target_radius * @sin(s.target_angle));
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.gpa = gpa;
    s.doc = try z.codecs.xml.parse(gpa, @embedFile("chain.xml"), null);
    s.robot = try mjcf.readRobot(gpa, &s.doc);
    s.imported = try rmj.build(gpa, &s.robot, .{
        .max_contacts = 4,
        .timestep = 1.0 / 240.0,
        .gravity = vec(0, 0, 0),
    });
    s.data = try rbt.Data.init(gpa, &s.imported.model);
    rbt.forward(&s.imported.model, &s.data);

    s.tip = s.imported.bodyIndex("tip") orelse 0;
    s.actuation = try ctl.limbActuation(gpa, &s.imported.model, s.tip);
    s.ik_scratch = try gpa.alloc(Vec, ctl.Ik.scratchSize(&s.imported.model));
    s.previous = try gpa.alloc(f32, s.imported.model.nq);

    s.damping = 0.05;
    s.target_radius = 2.0;
    s.target_angle = 0.6;
    s.auto_sweep = true;
    s.sweep_phase = 0;
    s.tip_error = 0;
    s.last_step = 0;
    s.peak_step = 0;
    s.reached = false;

    s.cam = z.OrbitCamera.init(vec(0, 0, 0), 8.5);
    s.font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.ui_host = z.UiHost.init(gpa, s.font);
    s.cube = try z.genMeshCube(gpa, 1.0, 1.0, 1.0);
    s.sphere = try z.genMeshSphere(gpa, 1.0, 14, 12);
    s.cylinder = try z.genMeshCylinder(gpa, 1.0, 1.0, 12, 2);
    s.transform = .{identity()};
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadMesh(gpa, s.cylinder);
    z.unloadMesh(gpa, s.sphere);
    z.unloadMesh(gpa, s.cube);
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
    gpa.free(s.previous);
    gpa.free(s.ik_scratch);
    s.actuation.deinit();
    s.data.deinit();
    s.imported.deinit();
    s.robot.deinit();
    s.doc.deinit();
}

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(u, s, f.window.widthf(), f.window.heightf());

    const model: *const rbt.Model = &s.imported.model;
    if (s.auto_sweep) {
        // ★ THE SWEEP CROSSES THE REACHABLE BOUNDARY AND COMES BACK, because the boundary is
        // where the conditioning shows. A path that stays comfortably inside proves nothing.
        s.sweep_phase += f.time.delta_time * 0.25;
        s.target_radius = 1.0 + 2.4 * @abs(@sin(s.sweep_phase));
        s.target_angle = 0.6 * @sin(s.sweep_phase * 6.0);
    }

    @memcpy(s.previous, s.data.pos);
    const result: ctl.Ik.Result = (ctl.Ik{
        .max_iterations = 12,
        .damping = s.damping,
        // ★ DELIBERATELY LOOSE. A tight `max_step` clamps away the very divergence this example
        // exists to show, and the comparison would prove nothing.
        .max_step = 100.0,
    }).solve(
        model,
        &s.data,
        s.actuation,
        .{ .body = s.tip, .offset = vec(0, 0, 0), .goal = targetAt(s) },
        s.ik_scratch,
    );
    s.tip_error = result.error_distance;
    s.reached = result.reached;

    var moved: f32 = 0;
    for (0..model.nq) |q| {
        moved = @max(moved, @abs(s.data.pos[q] - s.previous[q]));
    }
    s.last_step = moved;
    s.peak_step = @max(s.peak_step, moved);

    z.clearViewport(f, background);
    const cam: Camera3D = s.cam.update(f, captured, .{ .min_distance = 4.0, .max_distance = 20.0 });
    z.beginMode3D(gl, cam);
    z.drawGrid(gl, 14, 0.5);
    drawChain(s, gl);
    z.endMode3D(gl);
}

/// The chain lives in the model's x–z plane; the renderer is Y-up, so z maps to depth.
fn toRender(at: Vec) Vec {
    return vec(at[0], at[2], 0);
}

fn drawChain(s: *State, gl: *z.WgpuGl) void {
    const m: *const rbt.Model = &s.imported.model;

    // The reachable circle, so "at full stretch" is something you can see rather than infer.
    var previous_edge: Vec = vec(3.0, 0, 0);
    var i: usize = 1;
    while (i <= 72) : (i += 1) {
        const a: f32 = 2.0 * pi * float(i) / 72.0;
        const edge: Vec = vec(3.0 * @cos(a), 3.0 * @sin(a), 0);
        z.drawLine3D(gl, previous_edge, edge, reach_colour);
        previous_edge = edge;
    }

    // Links, drawn from each body's own frame so what is shown is what the solver produced.
    for (1..m.nbody) |b| {
        const at: Vec = toRender(s.data.body_xpos[b]);
        s.transform[0] = mulMat(translation(at[0], at[1], at[2]), scaling(0.09, 0.09, 0.09));
        z.drawMeshInstanced(gl, &s.sphere, &s.transform, joint_colour);
        const parent: u32 = m.body_parent[b];
        if (parent != rbt.world_body) {
            z.drawLine3D(gl, toRender(s.data.body_xpos[parent]), at, link_colour);
        }
    }

    const tip_at: Vec = toRender(s.data.body_xpos[s.tip]);
    s.transform[0] = mulMat(translation(tip_at[0], tip_at[1], tip_at[2]), scaling(0.14, 0.14, 0.14));
    z.drawMeshInstanced(gl, &s.sphere, &s.transform, if (s.reached) tip_ok else tip_far);

    const goal: Vec = toRender(targetAt(s));
    s.transform[0] = mulMat(translation(goal[0], goal[1], goal[2]), scaling(0.1, 0.1, 0.1));
    z.drawMeshInstanced(gl, &s.cube, &s.transform, target_colour);
    z.drawLine3D(gl, tip_at, goal, target_colour);
}

fn drawPanel(u: ui.Ui, s: *State, viewport_w: f32, viewport_h: f32) bool {
    // ★ THE HEIGHT IS NO LONGER NEEDED: the window sizes to its content, so nothing here has to
    // know how tall the viewport is. Kept in the signature because every example shares it.
    _ = viewport_h;
    const captured: bool = u.wantCaptureMouse();
    const narrow: bool = ui.Ui.isNarrow(viewport_w);
    // ★ AUTO-SIZED, AND NARROW ON A PHONE. These panels asked for 70-80% of the viewport height,
    // which on a phone left the thing the demo is ABOUT as a sliver at the bottom. Letting the
    // window size to its content keeps it as small as it can be, and capping the width stops it
    // spanning the screen.
    const panel_w: f32 = if (narrow) @min(viewport_w - 16, 340.0) else @min(380.0, viewport_w * 0.32);

    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ panel_w, 0 }, .{});
    if (u.window("ten joints for a two-joint job", .{ .flags = .{ .always_auto_resize = true } })) |window| {
        defer window.close();

        u.text("tip error {d:>8.5} m   {s}", .{
            s.tip_error,
            if (s.reached) "reached" else "OUT OF REACH",
        });
        // ★ THE JOINT STEP IS THE MEASUREMENT. Tracking accuracy barely moves with damping;
        // this spans a factor of 133.
        u.text("joint step {d:>8.3} rad  (peak {d:>7.2})", .{ s.last_step, s.peak_step });
        if (u.button("clear peak", .{})) {
            s.peak_step = 0;
        }
        u.separator();

        _ = u.slider("damping", &s.damping, .{ .min = 0.0, .max = 0.4, .fmt = "{d:.3}" });
        u.text("0.001 -> 100 rad steps; 0.30 -> 0.75", .{});
        u.text("accuracy is the same either way", .{});
        u.text("0.000 does not solve at all — Ik declines", .{});
        u.text("  a singular system rather than diverging", .{});
        u.separator();

        _ = u.checkbox("sweep across the reach boundary", &s.auto_sweep);
        if (!s.auto_sweep) {
            _ = u.slider("target radius", &s.target_radius, .{ .min = 0.2, .max = 3.6, .fmt = "{d:.2}" });
            _ = u.slider("target angle", &s.target_angle, .{ .min = -3.0, .max = 3.0, .fmt = "{d:.2}" });
        }
        u.text("reach is 3.0 m — push past it and watch", .{});
        u.text("  the chain straighten into a singularity", .{});
    }
    return captured;
}

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - ten joints for a two-joint job",
            .width = 900,
            .height = 640,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
