//! robot_3d - a real robot, from a real URDF, moving in three dimensions.
//!
//! * THE MILESTONE. Everything before this simulated robots we wrote ourselves. This one is
//! a KUKA LBR iiwa: seven axes, eight links, mass properties measured from the actual
//! hardware, described in a file somebody else wrote for a different toolchain.
//!
//! -- HOW IT GETS HERE --
//!
//!     kuka_iiwa.urdf --(zig build urdf-import)--> kuka_iiwa.zig --(comptime)--> Model
//!
//! The generated file is checked in and compiled like any hand-written model, so `Spec()`
//! validates it and the joint names become an ENUM - `Kuka.Joint.lbr_iiwa_joint_4` is
//! compile-checked, and a typo is a build error rather than a silent index. That is the
//! whole argument for the code generator over loading at runtime, and this file is where it
//! pays off: the controller below names joints, and the compiler checks it did so correctly.
//!
//! (`src/robot_urdf.zig` loads the same file at runtime for robots chosen at startup. Both
//! paths end at the same builder and a test asserts they agree - see section 4i-quater.)
//!
//! -- THE MESHES --
//!
//! The URDF names an `.obj` per link for its visual geometry, and `codecs.obj` already
//! parses those - so the robot is drawn with the actual shapes KUKA shipped, 890 KB of
//! them, embedded the way `damaged_helmet` embeds its 3.7 MB glb.
//!
//! * THE MESH IS DECORATION AND THE SKELETON IS THE TRUTH. What is simulated is eight
//! inertias connected by seven hinges; the meshes hang off those body frames and affect
//! nothing. Press W to see the joint frames underneath - the mass properties come from the
//! URDF's `<inertial>` blocks, not from these shapes, and the collision geometry (separate
//! `.stl` files) is not loaded at all yet. A pretty robot that is lying about its physics
//! is a real hazard, so this one shows you both.

const std = @import("std");
const common = @import("example_common");

/// A wasm safety trap is a bare `RuntimeError: unreachable` without this - no message, no line.
/// See `common.reportPanic`: six turns of debugging went to a panic that named itself in one
/// build once a handler existed.
pub const panic = std.debug.FullPanic(common.reportPanic);
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const ui = z.ui;
const zm = @import("zm");
const mulMat = zm.mulMat;
const isFinite = zm.isFinite;
const log10 = zm.log10;
const pow = zm.pow;
const rbt = z.robot;
const zp = z.zimrphysics;
const bridge_mod = z.robot_physics;
const scene_mod = z.robot_scene;
const ctl = z.robot_control;
// * THE GENERATED MODEL ITSELF, not a copy of it.
//
// This used to import a local `kuka_iiwa.zig` copied here by hand, and the copy went STALE
// the moment the importer learned to emit collision hulls: the example kept a model with
// `ngeom = 0`, so the bridge created no proxies, so the arm did not exist as far as the
// collision detector was concerned. The arm swept through the tower reporting zero contacts
// with every other part of the seam working perfectly.
//
// Nothing warns about a stale copy - it compiles, runs, and is simply an older robot. The
// fix is not to re-copy it but to stop having two of it.
const kuka = @import("kuka_iiwa.zig");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const Vec = zm.Vec;
const Color = zm.Color;
const vec = zm.vec;
const rotate = zm.rotate;
const Camera3D = zm.Camera3D;
const splat = zm.splat;
const bufPrint = std.fmt.bufPrint;
const acosRad = zm.acosRad;
const length3 = zm.length3;
const clamp = zm.clamp;
const float = zm.float;

const timestep: f32 = 1.0 / 240.0;

const bg: Color = .{ .r = 24, .g = 17, .b = 13, .a = 255 };
const link_col: Color = .{ .r = 79, .g = 179, .b = 165, .a = 255 };
const joint_col: Color = .{ .r = 232, .g = 196, .b = 92, .a = 255 };
const tip_col: Color = .{ .r = 211, .g = 95, .b = 51, .a = 255 };
/// Green when IK has the wrist on the goal, amber when it is straining at the edge of reach -
/// the same distinction the panel reports, where the eye already is.
const goal_reached_col: Color = .{ .r = 120, .g = 230, .b = 140, .a = 255 };
const goal_straining_col: Color = .{ .r = 240, .g = 150, .b = 90, .a = 255 };

/// A pose to hold, as joint angles. Named rather than numbered so the HUD can say which.
const Pose = struct {
    name: []const u8,
    angles: [7]f32,
};

const poses = [_]Pose{
    .{ .name = "home", .angles = .{ 0, 0, 0, 0, 0, 0, 0 } },
    .{ .name = "reach out", .angles = .{ 0, 0.9, 0, -1.2, 0, 0.9, 0 } },
    .{ .name = "folded", .angles = .{ 0, 1.4, 0, -2.0, 0, 1.0, 0 } },
    .{ .name = "twisted", .angles = .{ 1.2, 0.6, -0.8, -1.5, 1.1, 0.7, -0.5 } },
    // * The two that make contact interesting. "wind up" holds the arm clear to one side;
    // "sweep" carries it across the crate's position at roughly the crate's height. Going
    // from one to the other is a real arm swinging its own mass into an obstacle, with the
    // controller discovering the obstacle rather than being told about it.
    .{ .name = "wind up", .angles = .{ -1.1, 1.15, 0, -1.1, 0, 0.8, 0 } },
    .{ .name = "sweep", .angles = .{ 0.6, 1.15, 0, -1.1, 0, 0.8, 0 } },
};

/// -- THE TOWER --
///
/// A stack of crates rather than one, because a single box slides and a STACK TOPPLES - and
/// toppling is the thing worth watching. It also exercises far more of both engines: the
/// crates rest on each other through zimrphysics' own solver while the arm meets only the
/// one it strikes, so the collapse is transmitted through contacts neither engine was told
/// about in advance.
const crate_count: usize = 5;
const crate_half: f32 = 0.055;
/// Where the bottom crate's centre sits.
///
/// * MEASURED TWICE, AND THE SECOND TIME PROPERLY. The first placement put the tower at
/// radius 0.56 and the sweep missed it entirely - 0 N, a demo that silently does nothing.
/// Moving it to radius 0.64 produced a GLANCING blow: the closest any link centre came to
/// the tower was 0.062 m against a crate half-width of 0.055, so whether it connected at all
/// depended on which link happened to pass. That is worse than missing, because it works
/// sometimes.
///
/// The fix was to ask where the arm actually goes rather than nudge: sweeping it and
/// printing every link position showed the path is an ARC at y = 0.200 and radius 0.70. The
/// tower now sits ON that arc - same azimuth, radius corrected - so the arm goes through the
/// middle of it rather than shaving the edge.
///
/// This is the same lesson the 2D contact demo taught: a robot's reachable set is not
/// something to eyeball. Ask the kinematics where the hand goes, then put the target there.
const tower_base: Vec = vec(0.679, crate_half, 0.175);

/// Centre of crate `i`, counting up from the floor. A hair of clearance between them so the
/// stack settles under gravity instead of starting interpenetrated - a stack that begins
/// overlapping explodes on frame one, which looks like a physics bug and is a setup bug.
fn cratePosition(i: usize) Vec {
    const gap: f32 = 0.004;
    const step: f32 = 2.0 * crate_half + gap;
    return tower_base + vec(0, float(i) * step, 0);
}

/// One visual mesh per link, in link order. `link_N.obj` is the shape bolted to
/// `lbr_iiwa_link_N`, so the index IS the body index minus one.
const mesh_sources = [_][]const u8{
    @embedFile("meshes/link_0.obj"),
    @embedFile("meshes/link_1.obj"),
    @embedFile("meshes/link_2.obj"),
    @embedFile("meshes/link_3.obj"),
    @embedFile("meshes/link_4.obj"),
    @embedFile("meshes/link_5.obj"),
    @embedFile("meshes/link_6.obj"),
    @embedFile("meshes/link_7.obj"),
};

/// ** THE CRATES LIVE IN THE ROBOT'S OWN TREE (section 4k).
///
/// Not in zimrphysics as dynamic bodies with contacts handed across a seam - as free-jointed
/// bodies in the same mass matrix as the arm. A contact between a link and a crate is then a
/// contact between two bodies of ONE system: the relative Jacobian spans both, the solver
/// resolves it once, and momentum is conserved by construction.
///
/// The visible consequence, and the thing to look for: **a heavier crate now resists more.**
/// Under the old two-solver seam a 666x mass range changed the arm's behaviour by under 1%,
/// because each engine treated the other side as immovable.
///
/// zimrphysics keeps the floor and does all the collision DETECTION. It simulates none of
/// the dynamics that matter here.
fn sceneCrates() [crate_count]scene_mod.FreeBody {
    var crates: [crate_count]scene_mod.FreeBody = undefined;
    for (0..crate_count) |i| {
        crates[i] = .{
            .name = crate_names[i],
            .pos = cratePosition(i),
            .geoms = &.{.{
                .shape = .{ .box = .{ .half_extent = splat(crate_half) } },
                .mass = 0.8,
            }},
            // A little damping: real crates have none, but a scene that never settles
            // accumulates jitter into perpetual motion. Small enough to leave a shove lively.
            .damping = 0.05,
        };
    }
    return crates;
}

const crate_names = [_][]const u8{ "crate0", "crate1", "crate2", "crate3", "crate4" };

const State = struct {
    gpa: Allocator,
    model: rbt.Model,
    data: rbt.Data,
    font: z.Font,
    cam: z.OrbitCamera,
    /// GPU-resident link meshes, and a one-element transform buffer reused for each draw.
    meshes: [mesh_sources.len]z.Mesh,
    /// One unit-ish cube, drawn once per crate with that crate's own transform.
    ///
    /// * WHY A MESH RATHER THAN `drawCube`. `drawCube` is axis-aligned and takes no
    /// rotation, so a toppling crate would keep sitting bolt upright - hiding the very
    /// thing the scene exists to show, and quietly implying the crates only ever slide.
    /// `drawMeshInstanced` takes a full transform, so a tumble reads as a tumble.
    crate_mesh: z.Mesh,
    transform: [1]zm.Mat,
    ui_host: z.UiHost,
    /// Show the skeleton the meshes hang on, and the meshes themselves.
    show_frames: bool,
    show_meshes: bool,
    /// Vertices actually uploaded, summed. A READOUT rather than a comment: if the meshes
    /// silently fail to load this reads zero, and the alternative is staring at an empty
    /// screen wondering which half is broken. It would have saved a round trip.
    mesh_vertices: u32,
    // -- THE PHYSICS SEAM --
    //
    // Two engines, each owning what it is good at. `robot.zig` owns the arm: seven hinges
    // in generalized coordinates, no collision detector, contacts arriving as an INPUT the
    // way controls do. `zimrphysics` owns the floor and the crate, and also holds a
    // KINEMATIC PROXY for each of the arm's collision hulls - bodies it steers to wherever
    // the arm's own kinematics put them.
    //
    // The proxies are what make the arm exist as far as the crate is concerned: a body
    // outside the broad phase cannot be collided with, however real it is elsewhere.
    world: zp.World,
    bridge: bridge_mod.Bridge,
    /// Peak contact force the ARM has felt, so a brief tap leaves a trace in the readout.
    peak_force: f32,
    physics_on: bool,
    accumulator: f32,
    pose: usize,
    /// * THE COMMANDED POSE, WHICH IS NOT THE SELECTED POSE.
    ///
    /// Pressing a button used to change the target INSTANTLY, and a computed-torque
    /// controller asked to move a metre in one timestep obliges: the arm reached the speed
    /// of a swung bat and launched the crates a hundred metres. That is not the controller
    /// misbehaving, it is being told to do something absurd.
    ///
    /// Real arms are commanded along a TRAJECTORY, not teleported to a setpoint. This slides
    /// toward the selected pose at a bounded joint rate, which is both what a real
    /// controller receives and what keeps the collision sane - the one-way coupling of section 4h
    /// treats the arm as immovable, so an arm moving impossibly fast delivers an impossible
    /// impulse and nothing pushes back.
    commanded: [7]f32,
    /// Scratch for the controller, sized from `nv` - which now counts the crates too.
    desired_acc: []f32,
    /// Which DOFs have a motor. The crates' free joints do not; see `ctl.Actuation`.
    actuation: ctl.Actuation,
    /// Scratch for the IK solve, and the pose it produces.
    ik_scratch: []Vec,
    ik_pose: []f32,
    /// Where the wrist is being asked to go, and whether IK is driving.
    ik_goal: Vec,
    ik_on: bool,
    ik_reached: bool,
    ik_error: f32,
    /// Fastest crate this frame, and the largest ever seen. See the readout.
    fastest_crate: f32,
    fastest_ever: f32,
    /// Crate mass in kg, live. See `applyCrateMass`.
    crate_mass: f32,
    /// Per-joint torque ceiling in N*m, live. See `control`.
    motor_limit: f32,
    /// What the sliders actually edit: base-10 exponents of the two above.
    crate_mass_exp: f32,
    motor_limit_exp: f32,
    /// Closed-loop natural frequency squared, and twice the damping. In computed-torque
    /// form these are PHYSICAL rather than tuned: `kp = omega^2` and `kv = 2 zeta omega` give a settling
    /// response of omega rad/s at damping ratio zeta, identical on every joint.
    ///
    /// omega = 8 rad/s, critically damped. At `dt = 1/240` that is `kv*dt = 0.067`, two orders
    /// of magnitude inside the explicit integrator's stability limit - where the naive
    /// uniform-gain version sat at 11.4 and diverged.
    kp: f32,
    kv: f32,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    var vertices_loaded: u32 = 0;
    var meshes: [mesh_sources.len]z.Mesh = undefined;
    for (mesh_sources, 0..) |source, i| {
        // * The existing OBJ codec, unchanged. Nothing about loading a robot's geometry
        // needed a new parser - the URDF points at `.obj`, and zimr has parsed those since
        // long before robots existed.
        meshes[i] = try loadObjMesh(gpa, source);
        vertices_loaded += @intCast(meshes[i].vertexCount);
        // No `uploadMesh` call: it is a raylib-parity no-op, and `drawMeshInstanced` uploads
        // on first use keyed by the mesh pointer. Calling it looked like the upload step and
        // was not one.
    }

    // -- THE WORLD --
    //
    // Built before the arm's model only because `initState` assigns the whole struct at
    // once; nothing here depends on the arm.
    s.* = .{
        .gpa = gpa,
        // * ONE MODEL for the arm and the crates. `kuka.spec` is the generated ModelSpec;
        // `Scene` appends the crates as free-jointed bodies and builds the lot. Robot 0
        // keeps its body indices, so `kuka.Model.Joint.*` still names the right joints.
        .model = try (scene_mod.Scene{
            .robots = &.{kuka.spec},
            .free_bodies = &sceneCrates(),
            .options = .{ .timestep = timestep, .max_contacts = 64 },
        }).build(gpa),
        .data = undefined,
        .font = font,
        .meshes = meshes,
        .crate_mesh = try z.genMeshCube(gpa, 2.0 * crate_half, 2.0 * crate_half, 2.0 * crate_half),
        .transform = .{zm.identity()},
        .ui_host = z.UiHost.init(gpa, font),
        .show_frames = false,
        .show_meshes = true,
        .mesh_vertices = vertices_loaded,
        // The iiwa is about 1.3 m tall; frame it from a little above and back.
        .cam = z.OrbitCamera.init(vec(0, 0.5, 0), 2.6),
        .world = try .init(gpa, 32),
        .bridge = undefined, // needs the arm's kinematics; see below
        .peak_force = 0,
        .physics_on = true,
        .accumulator = 0,
        .pose = 4, // "wind up", so the first thing pressed can be "sweep"
        .commanded = poses[4].angles,
        .desired_acc = &.{}, // sized from `nv` once the model exists
        .actuation = undefined, // needs the model; built below
        .ik_scratch = &.{},
        .ik_pose = &.{},
        // Out in front of the arm, at about elbow height - inside the workspace so the first
        // frame shows IK working rather than straining.
        .ik_goal = vec(0.45, 0.55, 0.15),
        .ik_on = false,
        .ik_reached = false,
        .ik_error = 0,
        .fastest_crate = 0,
        .fastest_ever = 0,
        .crate_mass = crate_mass_default,
        .motor_limit = motor_limit_default,
        .crate_mass_exp = log10(crate_mass_default),
        .motor_limit_exp = log10(motor_limit_default),

        .kp = 64, // omega^2 for omega = 8 rad/s
        .kv = 16, // 2 zeta omega for zeta = 1
    };
    s.model.opt.timestep = timestep;
    s.data = try rbt.Data.init(gpa, &s.model);
    s.desired_acc = try gpa.alloc(f32, s.model.nv);
    s.actuation = try ctl.Actuation.init(gpa, &s.model);
    s.ik_scratch = try gpa.alloc(Vec, ctl.Ik.scratchSize(&s.model));
    s.ik_pose = try gpa.alloc(f32, s.model.nq);
    // Start at the commanded pose so the first frame is not a lunge.
    for (poses[s.pose].angles, 0..) |angle, i| {
        s.data.pos[i] = angle;
    }

    // -- THE WORLD, BUILT THROUGH `s.world` --
    //
    // * NOT built on a local and copied in. `zp.World` owns arrays that other parts of the
    // engine reference by address, so a world constructed locally and then MOVED into the
    // state struct leaves the bodies created against the original - and the arm then swept
    // through the crates reporting zero contacts, with everything else about the setup
    // correct. Nothing crashes; the collisions simply never happen.
    //
    // `robot_contact` had this right and this file did not, which is what made the
    // difference findable: two demos with the same seam, one working.
    s.world.gravity = vec(0, -9.81, 0);

    // The floor. STATIC - and it only collides with the arm because the robot proxies set
    // `report_immovable_contacts`. Without that flag zimrphysics drops any pair where
    // neither body can respond (kinematic vs static), and the arm would sweep through the
    // floor as if it were not there.
    const floor_shape: zp.ShapeId = try s.world.shapes.add(gpa, .{
        // * HALF A METRE THICK, not a sheet.
        //
        // At 0.05 the crates TUNNELLED THROUGH: struck by the arm they crossed the whole
        // slab inside one 1/240 s step, missed it entirely, and free-fell to y = -100 m.
        // Measured, after the tower alone was shown to be perfectly stable - which is what
        // narrowed it from "the stack explodes" to "the floor is too thin to catch a fast
        // body".
        //
        // Half a metre of solid is what a floor actually is, and it is free: a static box
        // is one broad-phase entry whatever its size.
        .box = .{ .half_extent = vec(3, 0.5, 3), .convex_radius = 0.01 },
    });
    _ = try s.world.createBody(.{
        .shape = floor_shape,
        .position = vec(0, -0.5, 0),
        .motion_type = .static,
    });

    rbt.forward(&s.model, &s.data);

    // * THE BRIDGE IS BUILT LAST, and the order is load-bearing: it snapshots where each of
    // the arm's collision hulls currently IS, so the arm's kinematics must have run first.
    // Built earlier, every proxy would be born at the origin and the first world step would
    // see a spurious sweep from there to the arm's real pose - eight hulls scything through
    // the scene on frame one.
    s.bridge = try .init(gpa, &s.world, &s.model, &s.data, 32);
    s.bridge.listen(&s.world);
}

/// Turn an OBJ into the `Mesh` the renderer wants.
///
/// A shim rather than a parser: `codecs.obj` does the reading and hands back a de-indexed
/// CPU mesh, and this only rearranges it into the renderer's C-compatible layout. The one
/// substantive conversion is 32-bit indices down to 16, which is what `types.Mesh` carries -
/// asserted rather than truncated, because a mesh silently losing its high indices renders
/// as an unrecognisable tangle and looks like a broken loader.
fn loadObjMesh(gpa: Allocator, source: []const u8) !z.Mesh {
    const parsed: z.codecs.obj.Data = try z.codecs.obj.parse(gpa, source);
    defer parsed.deinit(gpa);
    const cpu: z.codecs.obj.Mesh = try parsed.toMesh(gpa);
    defer cpu.deinit(gpa);

    const vertex_count: usize = cpu.vertexCount();
    zm.assertf(
        vertex_count <= 65535,
        @src(),
        "mesh has {d} vertices, more than 16-bit indices can address",
        .{vertex_count},
    );

    // The renderer owns these for the life of the mesh; `unloadMesh` frees them.
    const vertices: []f32 = try gpa.dupe(f32, cpu.positions);
    const normals: []f32 = try gpa.dupe(f32, cpu.normals);
    const indices: []u16 = try gpa.alloc(u16, cpu.indices.len);
    for (cpu.indices, 0..) |index, k| {
        indices[k] = @intCast(index);
    }

    return .{
        .vertexCount = @intCast(vertex_count),
        .triangleCount = @intCast(cpu.indices.len / 3),
        .vertices = vertices.ptr,
        .normals = if (cpu.had_normals) normals.ptr else null,
        .indices = indices.ptr,
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    gpa.free(s.ik_pose);
    gpa.free(s.ik_scratch);
    s.actuation.deinit();
    gpa.free(s.desired_acc);
    s.bridge.deinit(&s.world);
    s.world.deinit(gpa);
    s.ui_host.deinit();
    for (&s.meshes) |*mesh| {
        z.unloadMesh(gpa, mesh.*);
    }
    z.unloadMesh(gpa, s.crate_mesh);
    s.data.deinit();
    s.model.deinit();
    z.unloadFont(gpa, s.font);
}

/// COMPUTED-TORQUE CONTROL: the textbook robot controller, and the one this arm needs.
///
/// -- WHY THE OBVIOUS VERSION DOES NOT WORK --
///
/// The first version of this was a plain PD with one gain pair for all seven joints:
///
///     tau = c + kp*(q* - q) - kv*q_dot
///
/// It exploded on the first pose change. The reason is worth keeping, because it is a
/// property of robot arms rather than a coding slip: **this arm's joint inertias span a
/// factor of 300** - 3.43 kg*m^2 at the shoulder, 0.011 at the wrist. A damping gain that is
/// gentle on the shoulder is violent on the wrist. Explicit integration needs roughly
/// `kv*dt/M_ii < 2`; with `kv = 30` and `dt = 1/240` the wrist sat at **11.4**, and diverged
/// in a handful of steps.
///
/// -- THE FIX, WHICH IS ALSO THE STANDARD ANSWER --
///
/// Ask for an ACCELERATION and let the mass matrix convert it to torque:
///
///     a* = kp*(q* - q) - kv*q_dot          the motion we want, in acceleration
///     * tau  = M(q)*a* + c                 what it costs, given the arm's real inertia
///
/// Substituting into `M q_ddot + c = tau` gives `q_ddot = a*` exactly - the closed loop becomes a
/// linear, decoupled second-order system with the SAME response on every joint, whatever
/// the configuration. The 300x inertia spread disappears because `M` is precisely the thing
/// that accounts for it, and the gains become physical: `kp = omega^2`, `kv = 2 zeta omega` for a
/// natural frequency omega and damping ratio zeta.
///
/// It costs one `mulM` - a sparse multiply the engine already has because inverse dynamics
/// needed it - plus `bias_force`, which IS the torque that holds the arm still, so gravity
/// is cancelled exactly rather than fought.
/// Slide the commanded pose toward the selected one at a bounded rate.
///
/// 1.4 rad/s is about what a mid-size industrial arm's joints actually do. The point is not
/// realism for its own sake: an unbounded step command makes the arm arrive at a contact
/// with a speed no motor could produce, and with section 4h's one-way coupling nothing slows it
/// down - the crates then leave at a speed that says more about the setup than the physics.
fn advanceTrajectory(s: *State, dt: f32) void {
    const max_rate: f32 = 1.4; // rad/s
    const step: f32 = max_rate * dt;
    const target: [7]f32 = poses[s.pose].angles;
    for (&s.commanded, target) |*commanded, want| {
        const delta: f32 = want - commanded.*;
        commanded.* += clamp(delta, -step, step);
    }
}

/// Ask IK where the arm should be, and make that the pose the controller holds.
///
/// -- ** THE SOLVE RUNS ON A COPY, and that is the whole design --
///
/// `Ik.solve` writes joint angles directly into a `Data` - it IS the answer. Running it on the
/// LIVE data would teleport the arm to the solution every frame: no dynamics, no contact, no
/// crates being pushed, just a shape snapping between poses. The robot would look like it was
/// working and would be doing nothing.
///
/// So the solve runs on `s.data`'s positions saved and restored around it, and its output
/// becomes a TARGET for `PoseHold`. The arm then travels there under its own torque limits,
/// hits things on the way, and can fail to arrive - which is what makes it a robot rather than
/// an animation.
fn solveIk(s: *State) void {
    const wrist: u32 = @intCast(kuka.spec.bodies.len); // last link of the arm
    // Save the live pose; the solve is destructive.
    @memcpy(s.ik_pose, s.data.pos);

    const result: ctl.Ik.Result = (ctl.Ik{ .max_iterations = 12 }).solve(
        &s.model,
        &s.data,
        s.actuation,
        .{ .body = wrist, .goal = s.ik_goal },
        s.ik_scratch,
    );
    s.ik_reached = result.reached;
    s.ik_error = result.error_distance;

    // The solved ARM angles become the commanded pose; everything else - the crates' free
    // joints - is restored, because IK has no business moving them.
    for (0..7) |i| {
        s.commanded[i] = s.data.pos[i];
    }
    @memcpy(s.data.pos, s.ik_pose);
    s.data.stage = .stale;
    rbt.forward(&s.model, &s.data);
}

fn control(s: *State) void {
    // ** THE CONTROLLER ACTS ON THE ARM'S DOFs ONLY, and both halves of that matter.
    //
    // Once the crates joined the tree `nv` went from 7 to 37 - seven arm joints plus six per
    // crate. Two things broke.
    //
    // **The buffers.** `mulM` wants `nv`-vectors, and a `[7]f32` written up to `nv` is a
    // buffer overrun. The engine caught the size mismatch (`mulM wants 37-vectors`) and
    // `factorM` then reported NaN pivots - the corruption surfacing one pass later.
    //
    // *** AND THE CRATES MUST NOT BE HELD UP.** `bias_force` is the torque needed to keep
    // every DOF still, INCLUDING gravity on the crates. Adding it across all of `nv` would
    // cancel their weight and leave five boxes hanging in the air. Gravity compensation is
    // something a MOTOR does, and crates have no motors.
    //
    // The arm's rows are unaffected by the crates: free bodies are separate roots, so the
    // mass matrix has no coupling between them and the arm, and `M*a*` restricted to the arm
    // rows is exactly the arm's own mass matrix times its own desired acceleration.
    const arm_dofs: usize = 7;
    @memset(s.desired_acc, 0);
    for (0..arm_dofs) |i| {
        s.desired_acc[i] = s.kp * (s.commanded[i] - s.data.pos[i]) - s.kv * s.data.vel[i];
    }
    rbt.mulM(&s.model, &s.data, s.desired_acc, s.data.applied_force);

    for (0..s.model.nv) |i| {
        if (i < arm_dofs) {
            // * GRAVITY COMPENSATION FIRST, THEN CLAMP THE TOTAL. A motor's rating bounds
            // everything it does, including holding itself up - clamping only the tracking
            // part would let a weak arm cheat by treating its own weight as free.
            const wanted: f32 = s.data.applied_force[i] + s.data.bias_force[i];
            s.data.applied_force[i] = clamp(wanted, -s.motor_limit, s.motor_limit);
        } else {
            s.data.applied_force[i] = 0;
        }
    }
}

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;

    // -- ** IK RUNS ONCE PER FRAME, NOT ONCE PER PHYSICS SUBSTEP --
    //
    // It is a PLANNING step, not a physics one: it answers "where should the arm be aiming",
    // and that answer only changes when the goal moves - at frame rate, when a slider is
    // dragged. Solving it inside the fixed-timestep loop recomputed the same answer for every
    // substep, and the cost multiplied by however many substeps the accumulator owed.
    //
    // Worse, it fed back: a slow frame means a larger `delta_time`, which means more substeps,
    // which means more IK, which means a slower frame. The clamp on `delta_time` is the only
    // thing that bounded it. Reported from the device as "bad framerate when the IK target is
    // unreachable" - unreachable is exactly when the solve stops converging early and spends
    // its whole iteration budget.
    if (s.ik_on) {
        solveIk(s);
    }

    s.accumulator += @min(f.time.delta_time, 0.1);
    while (s.accumulator >= timestep) : (s.accumulator -= timestep) {
        // ** ONE STEP OF TWO ENGINES - AND KINEMATICS COME FIRST.
        //
        //   1. forward: where is everything RIGHT NOW
        //   2. steer the proxies to exactly that
        //   3. step the world, so its detector tests the current pose
        //   4. harvest the contacts as `robot.Contact` inputs
        //   5. decide torques, knowing what is touching
        //   6. step
        //
        // * `forward` USED TO COME AFTER `sync`, and that was a full step of positional lag:
        // the proxies were steered from `body_xpos` computed BEFORE the previous
        // integration, so the collision detector was always testing where the bodies had
        // been, not where they were.
        //
        // MuJoCo has no such gap - `mj_forward` runs kinematics, then collision, then the
        // constraint solve, all at the same `q`. For a body resting flat the lag is
        // invisible; for one balanced on a corner it is the difference between a contact
        // that holds and one that is computed for a pose the body has already left.
        // * IK REPLACES THE POSE RAMP RATHER THAN FIGHTING IT. Both write `s.commanded`, so
        // only one may drive at a time - running the trajectory ramp underneath a live IK
        // solve would have the two overwrite each other every frame and produce a visible
        // stutter with no obvious cause.
        if (!s.ik_on) {
            advanceTrajectory(s, timestep);
        }
        rbt.forward(&s.model, &s.data);
        if (s.physics_on) {
            s.bridge.sync(&s.world, &s.model, &s.data) catch |err| {
                zm.assertUnreachable(@src(), "proxy sync failed: {t}", .{err});
            };
            zp.step(&s.world, timestep) catch |err| {
                zm.assertUnreachable(@src(), "world step failed: {t}", .{err});
            };
            s.bridge.harvest(&s.data);
        } else {
            // ** TURNING PHYSICS OFF MUST CLEAR THE CONTACTS, and forgetting to is how this
            // demo produced `factorM: pivot 24 is nan`.
            //
            // `harvest` is what refreshes `d.contacts` each step. Skipping it does not leave
            // the robot contact-free - it leaves it enforcing the LAST set collected, frozen,
            // while the arm goes on moving. Those contacts describe a pose that no longer
            // exists, so their violations grow without bound, and a few hundred steps later
            // the mass matrix has a NaN pivot and the assert fires.
            //
            // The symptom named `factorM`, which is the first place a NaN becomes visible
            // rather than where it came from.
            s.data.clearContacts();
            s.data.forgetWarmStart();
        }
        control(s);
        rbt.step(&s.model, &s.data);
    }
    rbt.forward(&s.model, &s.data);

    // Track the load the ARM is carrying, summed over its solver's rows, with a peak held
    // so a brief tap leaves something to read - a contact at 240 Hz is otherwise gone
    // before an eye can catch it.
    // Fastest crate, from the tree's own velocities - six DOFs per crate, translation first.
    s.fastest_crate = 0;
    for (0..crate_count) |i| {
        const body: u32 = crateBody(i);
        const v: u32 = s.model.jnt_dof_adr[s.model.body_jnt_adr[body]];
        const speed: f32 = length3(vec(s.data.vel[v], s.data.vel[v + 1], s.data.vel[v + 2]));
        s.fastest_crate = @max(s.fastest_crate, speed);
    }
    s.fastest_ever = @max(s.fastest_ever, s.fastest_crate);

    var contact_force: f32 = 0;
    for (0..s.data.constraint_count) |row| {
        contact_force += s.data.constraint_force[row];
    }
    s.peak_force = @max(s.peak_force, contact_force);

    // * THE UI IS BUILT FIRST, BEFORE THE CAMERA READS THE MOUSE.
    //
    // `wantCaptureMouse` hit-tests the pointer against the windows submitted THIS
    // frame, so it can only answer correctly once they have been submitted. Building the
    // panel after the camera meant a drag on a checkbox also spun the scene - the camera
    // asked whether the UI wanted the mouse before the UI existed, and was told no.
    //
    // Nothing is drawn out of order by this: `ui_host.render` is deferred to the end of
    // the frame, so the panel still lands on top of the 3D scene.
    // ---- UI ----
    //
    // * A REAL UI PANEL, not hand-drawn rectangles with hit tests.
    //
    // The earlier version toggled the skeleton with the W key, which is unusable on a
    // phone - where every one of these demos is actually looked at. Hand-rolled buttons
    // also meant re-deriving hit testing, scaling and layout in each example, and getting
    // the scaling subtly wrong at device resolution.
    //
    // `zimr.ui` handles touch, scaling and layout, so a control is one call and works
    // where the demo is used.
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    // * `initial_pos` / `initial_size` as WINDOW OPTIONS - the idiom nine of ten UI examples
    // use, and none of them calls `setNextWindowSize`.
    //
    // The difference matters: `setNextWindowSize` is the imperative override applied EVERY
    // frame, so it fights the window's own layout; `initial_size` seeds the window once and
    // then leaves it alone. Reaching for the override first is what produced a panel with a
    // title bar and no content.
    if (u.window("KUKA LBR iiwa, imported from URDF", .{
        .initial_pos = .{ 12, 12 },
        .initial_size = .{ 360, 300 },
    })) |window| {
        defer window.close();

        u.text("{d} bodies   {d} DOF   {d:.1} kg", .{ s.model.nbody - 1, s.model.nv, totalMass(&s.model) });

        // * The mesh readout. Zero here means the geometry did not load, which is a very
        // different problem from the geometry not being drawn - and telling them apart from
        // a screenshot is otherwise impossible.
        u.text("{d} mesh vertices across {d} links", .{ s.mesh_vertices, s.meshes.len });

        // The joint name the generated enum makes safe to write. `lbr_iiwa_joint_4` is
        // checked at compile time - the payoff for emitting Zig rather than parsing at
        // runtime.
        u.text("elbow (joint_4) = {d:.3} rad", .{s.data.pos[@backingInt(kuka.Model.Joint.lbr_iiwa_joint_4)]});

        // * THE PANEL MUST FIT WITHOUT SCROLLING, on a phone, which is where these demos
        // are actually looked at.
        //
        // The previous version overflowed: the pose row ran off the right edge so "sweep" -
        // the one button that makes the scene do anything - was unreachable, and the panel
        // grew a scrollbar. A scrollable panel over a 3D scene is also the worst case for
        // gesture ownership, since a drag inside it could plausibly mean either "scroll the
        // list" or "orbit the camera". Making it fit removes the ambiguity rather than
        // arbitrating it.
        //
        // So: no explanatory paragraph, short labels, and the poses wrapped two per row.
        u.separator();
        _ = u.checkbox("meshes", &s.show_meshes);
        u.sameLine(.{});
        _ = u.checkbox("frames", &s.show_frames);

        u.text("contacts {d}   rows {d}   peak {d:.0} N", .{
            s.data.contact_count,
            s.data.constraint_count,
            s.peak_force,
        });
        // * A DIAGNOSTIC THAT SEPARATES THE TWO WAYS THIS CAN BE BROKEN, because from a
        // screenshot they look identical.
        //
        // `world` counts the bodies the physics engine actually holds: 1 floor + 5 crates +
        // one kinematic proxy per collision hull. If the proxies are missing, the arm does
        // not exist as far as the detector is concerned and nothing can ever touch it.
        //
        // `top y` is the highest crate's height. If the world is stepping, the stack settles
        // a millimetre or two under gravity and this reads slightly below its start; if it
        // is EXACTLY the start value the world is not stepping at all.
        //
        // Two numbers, and between them "no contact" stops being one symptom and becomes
        // three distinguishable causes.
        // * FASTEST CRATE, WITH A PEAK HELD - the readout for the one open problem.
        //
        // Measured headlessly after a hard sweep: a crate reaches 128 m/s. The solver
        // converges in one iteration and peak force stays a sane 800 N, so this is not the
        // old force explosion - it looks like a fast proxy sweeping THROUGH a crate within
        // one step and the contact being resolved once, hard. Tunnelling, of exactly the
        // kind speculative contacts exist to prevent.
        //
        // A live number rather than a note, because "the crates look fine" and "one crate
        // left at 128 m/s two seconds ago" are indistinguishable by eye once it is gone.
        u.text("iters {d}   crate max {d:.1} m/s   peak {d:.1} m/s", .{
            s.data.solver_iterations,
            s.fastest_crate,
            s.fastest_ever,
        });

        // * PER-CRATE TILT AND CONTACT COUNT - the readout that settles what a crate resting
        // on its corner actually is.
        //
        // A box tilted ~0.79 rad with ONE contact is impossible: a single point force cannot
        // resist the gravity torque about that point, so it must tip. A box tilted with
        // contacts against a NEIGHBOUR is an ordinary leaning pile and correct.
        //
        // Headless runs settle every crate flat at 1 iteration, so whatever is happening on
        // a device is not in the physics I can reproduce from here. Two numbers per crate
        // turn "it looks wrong" into which of those two it is.
        var tilt_line: [96]u8 = undefined;
        var used: usize = 0;
        for (0..crate_count) |i| {
            const body: u32 = crateBody(i);
            const up: Vec = rotate(s.data.body_xrot[body], vec(0, 1, 0));
            const tilt: f32 = acosRad(clamp(up[1], -1, 1));
            var touching: u32 = 0;
            for (0..s.data.contact_count) |c| {
                const contact: rbt.Contact = s.data.contacts[c];
                if (contact.body_a == body or contact.body_b == body) {
                    touching += 1;
                }
            }
            const written: []const u8 = bufPrint(
                tilt_line[used..],
                "{d:.1}/{d} ",
                .{ tilt, touching },
            ) catch break;
            used += written.len;
        }
        u.text("tilt/contacts: {s}", .{tilt_line[0..used]});
        u.separator();

        // -- * INVERSE KINEMATICS: point at a place, not at seven angles --
        //
        // The pose buttons below command JOINT ANGLES, which is how a robot is actually
        // driven and a hopeless way for a person to aim. IK inverts that: give it a point and
        // it finds angles that put the wrist there - or the closest it can manage, which is
        // the honest answer for a target outside the arm's reach.
        _ = u.checkbox("inverse kinematics", &s.ik_on);
        if (s.ik_on) {
            _ = u.slider("goal x", &s.ik_goal[0], .{ .min = -0.8, .max = 0.8, .fmt = "{d:.2}" });
            _ = u.slider("goal y", &s.ik_goal[1], .{ .min = 0.05, .max = 1.2, .fmt = "{d:.2}" });
            _ = u.slider("goal z", &s.ik_goal[2], .{ .min = -0.8, .max = 0.8, .fmt = "{d:.2}" });
            // * THE ERROR IS SHOWN, ALWAYS. "Reached" and "as close as it can get" look
            // identical from outside, and the difference is exactly what a caller needs: drag
            // the goal past the arm's reach and watch it stop shrinking.
            u.text("   {s}   error {d:.4} m", .{
                if (s.ik_reached) "reached" else "straining",
                s.ik_error,
            });
        }

        // -- * THE TWO NUMBERS THAT MAKE THE COUPLING VISIBLE --
        //
        // Drag `crate kg` up and sweep: the arm stops being able to move the boxes, and its
        // own pose starts lagging what it was told to hold. Drag `motor N*m` up and it wins
        // again. Neither of those could happen before section 4k - the robot treated every external
        // body as immovable, so across a 666x mass range its behaviour changed by under 1%.
        //
        // * THE SLIDERS ARE LOGARITHMIC, mapped here rather than by the widget.
        //
        // Both quantities span three decades and the interesting transition - "brushes it
        // aside" to "cannot budge it" - is narrow and sits in the middle. A linear slider
        // spends 90% of its travel above 30 kg where nothing further changes. `SliderOpts`
        // has no log mode, so the exponent is what the widget edits and the value is derived.
        if (u.slider("crate kg", &s.crate_mass_exp, .{ .min = -0.7, .max = 2.5, .fmt = "" })) {
            s.crate_mass = pow(f32, 10.0, s.crate_mass_exp);
            applyCrateMass(s);
        }
        _ = u.slider("motor N·m", &s.motor_limit_exp, .{ .min = 0.5, .max = 2.5, .fmt = "" });
        s.motor_limit = pow(f32, 10.0, s.motor_limit_exp);
        u.text("   {d:.1} kg each   {d:.0} N·m per joint", .{ s.crate_mass, s.motor_limit });
        _ = u.checkbox("physics", &s.physics_on);
        u.sameLine(.{});
        if (u.button("restack", .{})) {
            resetCrate(s);
        }

        u.separator();
        for (poses, 0..) |pose, i| {
            // Two per row: five buttons in one row overflow any phone, and the row that
            // overflows is the row with the interesting button on it.
            if (i % 2 != 0) {
                u.sameLine(.{});
            }
            if (u.button(pose.name, .{})) {
                s.pose = i;
            }
        }
    }

    z.clearViewport(f, bg);
    const cam: Camera3D = s.cam.update(f, u.wantCaptureMouse(), .{
        .min_distance = 0.8,
        .max_distance = 6.0,
    });
    z.beginMode3D(gl, cam);
    z.drawGrid(gl, 12, 0.25);

    // ---- the arm ----
    //
    // * EACH MESH IS PLACED BY ITS BODY'S SIMULATED POSE, and that is the whole trick. The
    // engine knows nothing about meshes; it produces a position and orientation per body,
    // and the shape is a rigid decoration hanging off that frame. Nothing here knows the
    // robot is a KUKA either - it walks whatever tree the model describes.
    var bi: u32 = 1;
    while (bi < s.model.nbody) : (bi += 1) {
        const mesh_index: usize = bi - 1;
        if (s.show_meshes and mesh_index < s.meshes.len) {
            const at: Vec = s.data.body_xpos[bi];
            s.transform[0] = mulMat(
                zm.translation(at[0], at[1], at[2]),
                zm.quatToMat(s.data.body_xrot[bi]),
            );
            z.drawMeshInstanced(gl, &s.meshes[mesh_index], &s.transform, link_col);
        }
    }

    // The skeleton the meshes hang on. Available because it is the TRUTH - the simulation
    // is these eight frames, and the meshes affect nothing.
    if (s.show_frames) {
        bi = 1;
        while (bi < s.model.nbody) : (bi += 1) {
            const parent: u32 = s.model.body_parent[bi];
            z.drawLine3D(gl, s.data.body_xpos[parent], s.data.body_xpos[bi], joint_col);
            z.drawSphere(gl, s.data.body_xpos[bi], .{
                .radius = 0.03,
                .rings = 8,
                .slices = 12,
                .color = joint_col,
            });
        }
        const last: u32 = s.model.nbody - 1;
        const flange: Vec = s.data.body_xpos[last] +
            rotate(s.data.body_xrot[last], vec(0, 0, 0.08));
        z.drawSphere(gl, flange, .{ .radius = 0.025, .rings = 8, .slices = 12, .color = tip_col });
    }

    // -- * THE IK GOAL, AND A LINE TO IT --
    //
    // The line is the point of the drawing. A marker alone shows WHERE the target is; the line
    // shows how far the arm is from it. Inside the workspace it shrinks to nothing; drag the
    // goal beyond reach and it grows - the same information the panel's error readout gives,
    // in the place the eye is already looking.
    if (s.ik_on) {
        const arm_tip: u32 = @intCast(kuka.spec.bodies.len);
        z.drawSphere(gl, s.ik_goal, .{
            .radius = 0.03,
            .rings = 8,
            .slices = 12,
            .color = if (s.ik_reached) goal_reached_col else goal_straining_col,
        });
        z.drawLine3D(gl, s.data.body_xpos[arm_tip], s.ik_goal, goal_straining_col);
    }
    // -- THE CRATE --
    //
    // Drawn from its ACTUAL simulated pose, so a tumble reads as a tumble. `drawCube` is
    // axis-aligned and takes no rotation, so the eight corners are transformed by hand and
    // joined - which also makes the rotation visible, where a fixed-orientation box would
    // hide it and quietly suggest the crate only ever slides.
    // -- THE CRATES --
    //
    // Drawn SOLID, from each crate's actual simulated transform. `drawMeshInstanced` takes
    // a full model matrix, so a crate that has been knocked over is drawn knocked over -
    // where an axis-aligned `drawCube` would keep it bolt upright and hide the tumble.
    for (0..crate_count) |i| {
        const body: u32 = crateBody(i);
        s.transform[0] = mulMat(
            zm.translation(s.data.body_xpos[body][0], s.data.body_xpos[body][1], s.data.body_xpos[body][2]),
            zm.quatToMat(s.data.body_xrot[body]),
        );
        z.drawMeshInstanced(gl, &s.crate_mesh, &s.transform, tip_col);
    }

    // Every contact the ARM is currently feeling, at the point it acts. These are the rows
    // in the arm's own solver, not zimrphysics' - what is drawn is what the robot knows.
    for (0..s.data.contact_count) |ci| {
        const contact: rbt.Contact = s.data.contacts[ci];
        if (contact.distance >= 0) {
            continue;
        }
        z.drawSphere(gl, contact.position, .{
            .radius = 0.02,
            .rings = 6,
            .slices = 10,
            .color = joint_col,
        });
    }
    z.endMode3D(gl);
}

/// Put the crate back where it started, at rest.
///
/// Worth having as a button rather than a restart: the interesting thing about this scene is
/// what happens when the arm meets the crate, and that is worth being able to repeat without
/// losing the camera angle you found.
/// Default crate mass, and the arm's default per-joint torque ceiling.
///
/// * THE CEILING IS WHAT MAKES MASS MATTER, and without it the demo would show nothing.
/// Computed torque asks the mass matrix for whatever acceleration it wants and gets it, so an
/// unlimited arm pushes a 200 kg block exactly as easily as a 1 kg one. A real motor has a
/// rating it cannot exceed to win an argument. 25 N*m is deliberately feeble for a KUKA -
/// enough to hold itself up and shove a light box, not enough to move a heavy one.
const crate_mass_default: f32 = 0.8;
const motor_limit_default: f32 = 25.0;

/// Push the slider's mass into the model, live.
///
/// * NO REBUILD NEEDED. `body_inertia` is read by `crb` every step to form the mass matrix,
/// so scaling it here changes the physics from the next step on - the crate genuinely becomes
/// heavier rather than being re-created heavier. Rotational inertia scales with mass for a
/// box of fixed size, so the whole tensor takes the same factor.
fn applyCrateMass(s: *State) void {
    for (0..crate_count) |i| {
        const body: u32 = crateBody(i);
        // ** A RATIO NEEDS ITS DENOMINATOR CHECKED, and this one reaches the mass matrix.
        //
        // Scaling by `target / current` is the right operation - it keeps the inertia tensor
        // consistent with the mass without re-deriving it - but a zero or non-finite `current`
        // turns the factor into `inf`, and `0 * inf` is NaN. That NaN then propagates into
        // `body_inertia`, into `M`, and surfaces as `factorM: pivot N is nan`, which names the
        // place it became VISIBLE rather than where it came from.
        //
        // A device report of exactly that assert could not be reproduced here, so this is a
        // guard rather than a fix: if the ratio is ever unusable, the mass is set directly and
        // the model stays finite. Cheap, and it removes one candidate from the next hunt.
        const current: f32 = s.model.body_mass[body];
        const scale: f32 = if (current > 1.0e-9) s.crate_mass / current else 0.0;
        if (scale == 0.0 or !isFinite(scale)) {
            std.log.warn("crate {d}: mass {d} cannot be scaled to {d}; leaving it alone", .{
                i,
                current,
                s.crate_mass,
            });
            continue;
        }
        s.model.body_mass[body] *= scale;
        s.model.body_inertia[body].mass *= scale;
        s.model.body_inertia[body].diag *= splat(scale);
        s.model.body_inertia[body].off *= splat(scale);
        s.model.body_inertia[body].h *= splat(scale);
    }
    // ** AND THE SUBTREE MASSES, which are NOT recomputed each step. Miss this and the
    // model is internally inconsistent - 100 kg bodies inside a subtree that still believes
    // it weighs 0.8 - and the mass matrix is assembled from two different systems. It cost
    // over a meganewton and a negative pivot to find. See `refreshSubtreeMass`.
    rbt.refreshSubtreeMass(&s.model);

    // -- ** AND THE SCENE IS RE-POSED, which is not a cop-out but the honest operation --
    //
    // Changing mass by 100x on bodies that are ACTIVELY IN CONTACT is violent. The stack is
    // resting at an equilibrium penetration that matched the old weight; multiply the weight
    // and every contact is suddenly wrong by that factor, all at once, while touching.
    // Measured: peak row force **1.16 MN** and velocities past 1e24 - a numerical runaway,
    // not physics.
    //
    // Two things were tried and neither was enough on its own. Clearing the warm start helps
    // - it holds forces computed for the old inertias, and seeding those into a system a
    // hundred times heavier is an enormous impulse - but only halved the peak. Ramping the
    // change over thirty frames did not help either; the contacts are wrong throughout the
    // ramp rather than only at its end.
    //
    // The fix is to stop pretending it is a small change. A body's mass is not a runtime
    // knob in any physics engine; changing it is closer to rebuilding the scene. So the
    // crates are put back at rest, which is also what a user dragging a mass slider
    // expects - heavier boxes, freshly stacked.
    resetCrate(s);
    s.data.forgetWarmStart();
}

/// Restack the crates by writing the TREE's own coordinates.
///
/// * A free body's state lives in `qpos` and `vel` like every other joint's - seven position
/// coordinates (three for the translation, four for the quaternion) and six velocities. There
/// is no separate rigid-body store to keep in step, which is one of the quieter benefits of
/// the unified tree: resetting a crate is the same operation as resetting a joint angle.
fn resetCrate(s: *State) void {
    for (0..crate_count) |i| {
        const body: u32 = crateBody(i);
        const joint: u32 = s.model.body_jnt_adr[body];
        const q: u32 = s.model.jnt_qpos_adr[joint];
        const v: u32 = s.model.jnt_dof_adr[joint];
        const at: Vec = cratePosition(i);
        s.data.pos[q + 0] = at[0];
        s.data.pos[q + 1] = at[1];
        s.data.pos[q + 2] = at[2];
        // Identity quaternion, in the engine's (x, y, z, w) order.
        s.data.pos[q + 3] = 0;
        s.data.pos[q + 4] = 0;
        s.data.pos[q + 5] = 0;
        s.data.pos[q + 6] = 1;
        @memset(s.data.vel[v..][0..6], 0);
    }
    s.data.stage = .stale;
    s.peak_force = 0;
}

/// Tree index of crate `i`. The arm's bodies come first and keep their numbering, so the
/// crates follow - see `Scene.freeBodyIndex`.
fn crateBody(i: usize) u32 {
    return @intCast(1 + kuka.spec.bodies.len + i);
}

fn totalMass(m: *const rbt.Model) f32 {
    var total: f32 = 0;
    for (1..m.nbody) |bi| {
        total += m.body_mass[bi];
    }
    return total;
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - KUKA iiwa from URDF",
            .width = 820,
            .height = 680,
            .scale_mode = .responsive,
            // 3D needs a depth buffer or nearer geometry does not occlude farther -
            // `beginMode3D` asserts without it.
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
