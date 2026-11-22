//! robot_policy - what a residual feedback policy sees, and what it is allowed to do.
//!
//! The reference already drives the character: its joint angles are the servo's targets, and that
//! open-loop control is nearly enough. What a policy adds is the balance correction - a small
//! offset on some of those targets - which is why every method here is *residual*, and why this
//! module's job is to make the policy's input small and informative and its output small and
//! smooth.
//!
//! The shape is DReCon's (Bergamin 2019 section 6.3-6.4), because they ablated it and we would otherwise
//! be guessing:
//!
//!   * **A subset of bodies in the observation, not all of them.** Six: the two toes, the torso,
//!     the head and the two forearms. Their Fig 12 has the subset learning FASTER and ending
//!     BETTER than the full set - fewer actions make exploration and credit assignment easier, and
//!     the rest of the state is mostly redundant with what those six imply.
//!   * **The simulated character AND its error against the reference** (their Fig 13's winner,
//!     over either alone): the error is what feedback control acts on, and a network that has to
//!     compute it from two absolute states wastes its first layer doing so.
//!   * **A subset of joints in the action.** Hips, knees, ankles, abdomen, shoulders - everything
//!     that carries weight or swings it. Toes and elbows are left to the open-loop reference.
//!   * **A filtered action, held for a few steps.** `y = beta a + (1 - beta) y_prev`, and the
//!     policy asked only every `decimation` steps. High-frequency target changes look wrong even
//!     when they score well (their Figs 6 and 7), and the filter's own output goes into the
//!     observation so the policy can see what it actually did.
//!
//! **Everything is measured in a heading frame at the centre of mass**: yaw only, so turning or
//! walking away does not change the numbers, but TILT does - which is the whole point, since tilt
//! is what a balance policy exists to correct. For a clip that goes to ground the heading needs
//! care: a character lying face-down has a forward axis pointing at the floor, so the heading
//! falls back to another axis rather than dividing by a vanishing horizontal component.

const std = @import("std");
const report = @import("test_report.zig");
const zm = @import("zm");
const rbt = @import("robot");
const dance = @import("robot_dance.zig");
const track = @import("robot_track.zig");

const Allocator = std.mem.Allocator;
const Vec = zm.Vec;
const Quat = zm.Quat;
const vec = zm.vec;
const splat = zm.splat;
const rotate = zm.rotate;
const conjugate = zm.conjugate;
const normalize3 = zm.normalize3;
const atan2Rad = zm.atan2Rad;
const length3 = zm.length3;
const assertf = zm.assertf;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const Random = std.Random;
const testing_allocator = std.testing.allocator;
const ArrayList = std.ArrayList;
const eql = std.mem.eql;

/// The bodies a policy watches and the joints it may nudge, as indices into the model.
pub const Subset = struct {
    bodies: []const usize,
    /// Joint indices; their degrees of freedom, in model order, are what the policy outputs.
    joints: []const usize,
    /// How many numbers the policy produces: the subset's degrees of freedom.
    dofs: usize,

    pub fn deinit(self: Subset, gpa: Allocator) void {
        gpa.free(self.bodies);
        gpa.free(self.joints);
    }
};

/// The bodies DReCon watches, named for this model: what the feet are doing, what the trunk and
/// head are doing, and where the arms are (they counterbalance, and on the floor they push).
pub const watched_bodies = [_][]const u8{
    "toe_left",
    "toe_right",
    "torso",
    "head",
    "lower_arm_left",
    "lower_arm_right",
};

/// The bodies whose joints the policy may offset - named by the body each joint drives, which is
/// how DReCon lists theirs. Everything that carries the body's weight or swings it; toes and
/// elbows are left to the reference, being cheap to get wrong and expensive to explore.
pub const actuated_bodies = [_][]const u8{
    "waist_lower",
    "pelvis",
    "thigh_left",
    "shin_left",
    "foot_left",
    "thigh_right",
    "shin_right",
    "foot_right",
    "upper_arm_left",
    "upper_arm_right",
};

/// Which bodies a DReCon policy WATCHES (its observation) and which it ACTUATES (its action), as one value - so a
/// robot names its pair once (`robot_geno.drecon_bodies`) instead of every trainer spelling out both lists. The
/// defaults are the old robot's.
pub const Bodies = struct {
    watched: []const []const u8 = &watched_bodies,
    actuated: []const []const u8 = &actuated_bodies,
};

fn indexOfName(names: []const []const u8, want: []const u8) ?usize {
    for (names, 0..) |name, i| {
        if (eql(u8, name, want)) {
            return i;
        }
    }
    return null;
}

fn dofsOf(m: *const rbt.Model, joint: usize) usize {
    return switch (m.joint_type[joint]) {
        .free => 6,
        .ball => 3,
        .hinge, .slide => 1,
    };
}

/// The same choice for any robot: DReCon's watched and actuated bodies, named in THAT robot's words.
/// The anatomy is the method - feet, trunk, head and forearms watched; spine, legs and upper arms
/// actuated - and the names are just how a particular skeleton spells it.
pub fn subsetFor(
    gpa: Allocator,
    m: *const rbt.Model,
    body_names: []const []const u8,
    watched: []const []const u8,
    actuated: []const []const u8,
) !Subset {
    const bodies: []usize = try gpa.alloc(usize, watched.len);
    errdefer gpa.free(bodies);
    for (watched, bodies) |want, *slot| {
        const found: ?usize = indexOfName(body_names, want);
        assertf(found != null, @src(), "no body named {s} in this model", .{want});
        slot.* = found.?;
    }
    // Every joint belonging to an actuated body, in model order - so the policy's outputs line up
    // with the model's degrees of freedom without a lookup table to get wrong.
    var joint_list: ArrayList(usize) = .empty;
    errdefer joint_list.deinit(gpa);
    var dofs: usize = 0;
    for (actuated) |want| {
        const maybe: ?usize = indexOfName(body_names, want);
        assertf(maybe != null, @src(), "no body named {s} in this model", .{want});
        const body: usize = maybe.?;
        var found: usize = 0;
        for (0..m.joint_count) |j| {
            if (m.joint_body[j] == body and m.joint_type[j] != .free) {
                try joint_list.append(gpa, j);
                dofs += dofsOf(m, j);
                found += 1;
            }
        }
        assertf(found > 0, @src(), "body {s} has no joints to actuate", .{want});
    }
    return .{ .bodies = bodies, .joints = try joint_list.toOwnedSlice(gpa), .dofs = dofs };
}

/// Resolve those names against a model. Fails loudly: a policy quietly actuating the wrong joints
/// is a very long debugging session.
pub fn defaultSubset(
    gpa: Allocator,
    m: *const rbt.Model,
    body_names: []const []const u8,
) !Subset {
    return subsetFor(gpa, m, body_names, &watched_bodies, &actuated_bodies);
}

/// Every joint but the free root, in model order, and no watched body: the subset of a policy that acts on the whole
/// body and observes something other than DReCon's watched bodies - SuperTrack's, whose action is one number per
/// actuated degree of freedom (`robot_track.actionSize`). In model order, the subset's degrees of freedom are the
/// model's own after the root's, so `Controller.apply` spreads them onto the model's action one for one.
pub fn everyActuatedJoint(gpa: Allocator, m: *const rbt.Model) !Subset {
    var joint_list: ArrayList(usize) = .empty;
    errdefer joint_list.deinit(gpa);
    var dofs: usize = 0;
    for (0..m.joint_count) |joint| {
        const is_root: bool = m.joint_type[joint] == .free;
        if (!is_root) {
            try joint_list.append(gpa, joint);
            dofs += dofsOf(m, joint);
        }
    }
    const no_watched_bodies: []usize = try gpa.alloc(usize, 0);
    errdefer gpa.free(no_watched_bodies);
    const joints: []usize = try joint_list.toOwnedSlice(gpa);
    const action_size: usize = track.actionSize(m);
    assertf(dofs == action_size, @src(), "everyActuatedJoint: {d} degrees of freedom, an action of {d}", .{
        dofs,
        action_size,
    });
    return .{ .bodies = no_watched_bodies, .joints = joints, .dofs = dofs };
}

/// A frame that turns with the character but does not tilt with it, sitting at its centre of mass.
pub const Frame = struct {
    /// Rotates world vectors into the frame.
    to_local: Quat,
    origin: Vec,
};

/// The centre of mass of a whole-body state.
pub fn centreOfMass(m: *const rbt.Model, state: track.State) Vec {
    var total: f32 = 0.0;
    var sum: Vec = zm.vec_zero;
    for (1..state.bodies()) |b| {
        const mass: f32 = m.body_mass[b];
        sum += state.positions[b] * splat(mass);
        total += mass;
    }
    return sum * splat(1.0 / @max(total, 1.0e-9));
}

/// And its velocity.
pub fn centreOfMassVelocity(m: *const rbt.Model, state: track.State) Vec {
    var total: f32 = 0.0;
    var sum: Vec = zm.vec_zero;
    for (1..state.bodies()) |b| {
        const mass: f32 = m.body_mass[b];
        sum += state.velocities[b] * splat(mass);
        total += mass;
    }
    return sum * splat(1.0 / @max(total, 1.0e-9));
}

/// The heading frame: yaw taken from the root, origin at the centre of mass.
pub fn headingFrame(m: *const rbt.Model, state: track.State, root: usize) Frame {
    const q: Quat = state.rotations[root];
    // Which way is the character facing? Its own forward axis, flattened. A character lying face
    // down has a forward axis pointing at the floor, so its horizontal part vanishes and the yaw
    // it implies is noise - fall back to another axis rather than normalise a zero vector. This
    // matters for exactly one clip in the set, and that clip is the point of the set.
    const candidates = [_]Vec{ vec(1, 0, 0), vec(0, 1, 0), vec(0, 0, 1) };
    var forward: Vec = vec(1, 0, 0);
    for (candidates) |axis| {
        const turned: Vec = rotate(q, axis);
        const flat: Vec = vec(turned[0], turned[1], 0.0);
        if (length3(flat) > 0.1) {
            forward = normalize3(flat);
            break;
        }
    }
    const half: f32 = 0.5 * atan2Rad(forward[1], forward[0]);
    const yaw: Quat = .{ 0.0, 0.0, @sin(half), @cos(half) };
    return .{ .to_local = conjugate(yaw), .origin = centreOfMass(m, state) };
}

/// LOOKAHEAD (MimicKit's `tar_obs_steps`, Sep 26): the reference seen further ahead than the frame the
/// coming action aims at (+1) - these many physics frames past the character's CURRENT frame. At 60 Hz and a
/// decision every 2 frames that's 33, 67 and 100 ms: MimicKit's 1, 2 and 3 steps at its 30 Hz control. The
/// teacher plans 15 frames ahead; a policy that sees one frame cannot anticipate what it does (D5's clone).
pub const lookahead_frames = [_]u32{ 2, 4, 6 };

/// How many numbers the policy sees.
pub fn observationSize(subset: Subset) usize {
    // The three centre-of-mass velocities (simulated, reference, and their difference), the centre of mass's
    // HEIGHT, where the reference IS relative to the character (3) and how its heading differs (2), then for each
    // watched body its position and velocity, then the same errors again, then for each lookahead frame where the
    // reference's centre of mass will be (relative to the character) and its watched bodies' shape there, then
    // the last action the filter actually applied (always LAST).
    return 9 + 1 + 5 + subset.bodies.len * 12 + lookahead_frames.len * (3 + subset.bodies.len * 3) + subset.dofs;
}

/// What an observation built from a fleet needs besides the character's own state: the reference where the
/// coming action aims, the reference further ahead, and a probe to pose them with. Allocated once per caller.
pub const Views = struct {
    reference: track.State,
    ahead: [lookahead_frames.len]track.State,
    probe: rbt.Data,

    pub fn init(gpa: Allocator, m: *const rbt.Model) !Views {
        var views: Views = .{ .reference = undefined, .ahead = undefined, .probe = undefined };
        views.reference = try track.State.init(gpa, m.body_count);
        errdefer views.reference.deinit(gpa);
        var made: usize = 0;
        errdefer for (views.ahead[0..made]) |*state| state.deinit(gpa);
        for (&views.ahead) |*state| {
            state.* = try track.State.init(gpa, m.body_count);
            made += 1;
        }
        views.probe = try rbt.Data.init(gpa, m);
        return views;
    }

    pub fn deinit(self: *Views, gpa: Allocator) void {
        self.probe.deinit();
        for (&self.ahead) |*state| {
            state.deinit(gpa);
        }
        self.reference.deinit(gpa);
    }
};

fn writeVec(out: []f32, at: *usize, v: Vec) void {
    out[at.*] = v[0];
    out[at.* + 1] = v[1];
    out[at.* + 2] = v[2];
    at.* += 3;
}

/// Build one observation from two states. Pure, so the invariance below can be tested on it
/// directly rather than through a fleet.
pub fn observe(
    m: *const rbt.Model,
    subset: Subset,
    sim: track.State,
    reference: track.State,
    ahead: []const track.State,
    root: usize,
    previous_action: []const f32,
    out: []f32,
) void {
    assertf(out.len == observationSize(subset), @src(), "observation is {d} long, wants {d}", .{
        out.len,
        observationSize(subset),
    });
    assertf(ahead.len == lookahead_frames.len, @src(), "lookahead has {d} states, wants {d}", .{
        ahead.len,
        lookahead_frames.len,
    });
    assertf(previous_action.len == subset.dofs, @src(), "previous action is {d}, wants {d}", .{
        previous_action.len,
        subset.dofs,
    });
    const sim_frame: Frame = headingFrame(m, sim, root);
    const ref_frame: Frame = headingFrame(m, reference, root);
    const sim_cm: Vec = rotate(sim_frame.to_local, centreOfMassVelocity(m, sim));
    const ref_cm: Vec = rotate(ref_frame.to_local, centreOfMassVelocity(m, reference));
    var at: usize = 0;
    writeVec(out, &at, sim_cm);
    writeVec(out, &at, ref_cm);
    writeVec(out, &at, sim_cm - ref_cm);
    // The centre of mass's HEIGHT above the floor (z = 0): what a get-up is about, and what positions measured
    // FROM the centre of mass cannot show. Vertical, so no heading changes it.
    out[at] = sim_frame.origin[2];
    at += 1;
    // WHERE THE REFERENCE IS, from the character (MimicKit places its targets exactly so): its
    // centre of mass in the character's heading frame, and its heading against the character's, as cos and sin.
    // Every other term is a difference taken in each character's OWN frame - drift-free by construction, which
    // also made drift INVISIBLE: a policy rewarded for following the reference's root motion could not see that
    // it had wandered off it, or turned away from it, and so could never learn to turn on the spot or go
    // somewhere reliably.
    writeVec(out, &at, rotate(sim_frame.to_local, ref_frame.origin - sim_frame.origin));
    const facing: Vec = rotate(sim_frame.to_local, rotate(conjugate(ref_frame.to_local), vec(1.0, 0.0, 0.0)));
    out[at] = facing[0];
    out[at + 1] = facing[1];
    at += 2;
    for (subset.bodies) |b| {
        writeVec(out, &at, rotate(sim_frame.to_local, sim.positions[b] - sim_frame.origin));
        writeVec(out, &at, rotate(sim_frame.to_local, sim.velocities[b]));
    }
    for (subset.bodies) |b| {
        const p: Vec = rotate(sim_frame.to_local, sim.positions[b] - sim_frame.origin);
        const p_ref: Vec = rotate(ref_frame.to_local, reference.positions[b] - ref_frame.origin);
        const v: Vec = rotate(sim_frame.to_local, sim.velocities[b]);
        const v_ref: Vec = rotate(ref_frame.to_local, reference.velocities[b]);
        writeVec(out, &at, p - p_ref);
        writeVec(out, &at, v - v_ref);
    }
    // FURTHER AHEAD: where the reference's centre of mass will be, from the CHARACTER (in its heading frame - the
    // way to go, drift included: a rise, a jump or a turn shows here before it happens), and its watched bodies'
    // SHAPE then (each future frame in its own heading frame - the pose, free of where it stands).
    for (ahead) |future| {
        const future_frame: Frame = headingFrame(m, future, root);
        writeVec(out, &at, rotate(sim_frame.to_local, future_frame.origin - sim_frame.origin));
        for (subset.bodies) |b| {
            writeVec(out, &at, rotate(future_frame.to_local, future.positions[b] - future_frame.origin));
        }
    }
    @memcpy(out[at..][0..previous_action.len], previous_action);
}

/// The observation of a character in state `sim` tracking `clip`, its state at `frame`: the reference where
/// the coming action aims (`frame + 1`) and further ahead (`lookahead_frames`), posed through the fleet - which
/// knows how its clips are lifted and placed. Every caller builds its observation here (the trainer, its judge,
/// its bootstrap from a terminal state, the teacher's recorder), so they cannot disagree.
pub fn observeFrom(
    m: *const rbt.Model,
    subset: Subset,
    fleet: *track.Fleet,
    clip: *const dance.Clip,
    frame: u32,
    sim: track.State,
    views: *Views,
    previous_action: []const f32,
    out: []f32,
) void {
    fleet.referenceStateInto(clip, frame + 1, &views.probe, &views.reference);
    for (lookahead_frames, &views.ahead) |k, *state| {
        fleet.referenceStateInto(clip, frame + k, &views.probe, state);
    }
    observe(m, subset, sim, views.reference, &views.ahead, fleet.root, previous_action, out);
}

/// The policy's hands on the controls: filtering what it asks for, holding it for a few steps, and
/// spreading the subset's numbers back over the model's full action.
///
/// A POLICY THAT ALSO GIVES EACH LIMB A STIFFNESS (`track.Fleet.Options.limb_stiffness`) has `stiffness_count` more
/// numbers after its joints', which pass through the filter at a share of their own and go to the end of the full
/// action, where such a fleet reads them:
///
///     the policy's action     subset's joints ...........  | limbs' stiffnesses
///     filtered, each part     at `beta`                    | at `stiffness_beta`
///     the full action         every actuated joint ......  | limbs' stiffnesses      (`track.actionWidth`)
pub const Controller = struct {
    pub const Options = struct {
        /// The filter's stiffness. DReCon's 0.2: a fifth of the new action, four fifths of the old.
        beta: f32 = 0.2,
        /// How many simulation steps one action is held for.
        decimation: u32 = 2,
        /// The limbs' stiffnesses in the policy's action, after its joints' numbers: the model's limbs for a policy
        /// that gives them, 0 for an action of the joints alone.
        stiffness_count: usize = 0,
        /// The filter's share for the limbs' stiffnesses, as `beta` is the joints'. 1 is no filter.
        stiffness_beta: f32 = 1.0,
    };

    gpa: Allocator,
    m: *const rbt.Model,
    subset: Subset,
    options: Options,
    envs: usize,
    /// Per environment: the filter's state - the subset's numbers, then the limbs' stiffnesses (`actionWidth`) - and
    /// the full action it expands to: every actuated joint's, then the stiffnesses (`fullWidth`).
    filtered: []f32,
    expanded: []f32,
    held: u32 = 0,

    pub fn init(
        gpa: Allocator,
        m: *const rbt.Model,
        subset: Subset,
        envs: usize,
        options: Options,
    ) !Controller {
        const action_width: usize = subset.dofs + options.stiffness_count;
        const full_width: usize = track.actionSize(m) + options.stiffness_count;
        const filtered: []f32 = try gpa.alloc(f32, envs * action_width);
        errdefer gpa.free(filtered);
        const expanded: []f32 = try gpa.alloc(f32, envs * full_width);
        @memset(filtered, 0.0);
        @memset(expanded, 0.0);
        return .{
            .gpa = gpa,
            .m = m,
            .subset = subset,
            .options = options,
            .envs = envs,
            .filtered = filtered,
            .expanded = expanded,
        };
    }

    pub fn deinit(self: *Controller) void {
        self.gpa.free(self.filtered);
        self.gpa.free(self.expanded);
    }

    /// Does this step need a new decision from the policy, or does the last one still stand?
    pub fn wantsAction(self: Controller) bool {
        return self.held % @max(self.options.decimation, 1) == 0;
    }

    /// The numbers the policy gives an environment: the subset's joints', then the limbs' stiffnesses.
    pub fn actionWidth(self: Controller) usize {
        return self.subset.dofs + self.options.stiffness_count;
    }

    /// The numbers of an environment's full action: every actuated joint's, then the limbs' stiffnesses - what its
    /// fleet takes (`track.actionWidth`).
    pub fn fullWidth(self: Controller) usize {
        return track.actionSize(self.m) + self.options.stiffness_count;
    }

    /// Take what the policy asked for (`envs * actionWidth()`, each in [-1, 1]), filter it - the joints' numbers at
    /// `beta`, the limbs' stiffnesses at `stiffness_beta` - and return the full action for every environment. When
    /// the policy is not being asked this step, `raw` is ignored and the last filtered action stands.
    pub fn apply(self: *Controller, raw: []const f32) []const f32 {
        const dofs: usize = self.subset.dofs;
        const action_width: usize = self.actionWidth();
        const wanted_length: usize = self.envs * action_width;
        assertf(raw.len == wanted_length, @src(), "actions are {d}, want {d}", .{ raw.len, wanted_length });
        if (self.wantsAction()) {
            for (0..self.envs) |env| {
                const asked: []const f32 = raw[env * action_width ..][0..action_width];
                const kept: []f32 = self.filtered[env * action_width ..][0..action_width];
                track.filterAction(self.options.beta, asked[0..dofs], kept[0..dofs]);
                track.filterAction(self.options.stiffness_beta, asked[dofs..], kept[dofs..]);
            }
        }
        self.held +%= 1;
        // Spread the subset over the model's action: everything else stays exactly zero, which is
        // the reference's own target, untouched. The limbs' stiffnesses follow the joints'.
        @memset(self.expanded, 0.0);
        const joint_numbers: usize = track.actionSize(self.m);
        const full_width: usize = self.fullWidth();
        for (0..self.envs) |env| {
            const kept: []const f32 = self.filtered[env * action_width ..][0..action_width];
            const full_action: []f32 = self.expanded[env * full_width ..][0..full_width];
            var at: usize = 0;
            for (self.subset.joints) |joint| {
                const dof: usize = self.m.joint_first_dof[joint] - track.rootDofs(self.m);
                const count: usize = dofsOf(self.m, joint);
                @memcpy(full_action[dof..][0..count], kept[at..][0..count]);
                at += count;
            }
            @memcpy(full_action[joint_numbers..], kept[dofs..]);
        }
        return self.expanded;
    }

    /// Start an environment's filter from rest - at a reset, the last action means nothing.
    pub fn forget(self: *Controller, env: usize) void {
        const action_width: usize = self.actionWidth();
        @memset(self.filtered[env * action_width ..][0..action_width], 0.0);
    }

    /// The filter's current output for one environment's joints, which goes into DReCon's observation.
    pub fn lastAction(self: Controller, env: usize) []const f32 {
        return self.filtered[env * self.actionWidth() ..][0..self.subset.dofs];
    }

    /// The whole action the filter holds for one environment - its joints' numbers, then its limbs' stiffnesses:
    /// the action applied before its next decision, which a policy trained to see it reads.
    pub fn appliedAction(self: Controller, env: usize) []const f32 {
        const action_width: usize = self.actionWidth();
        return self.filtered[env * action_width ..][0..action_width];
    }
};

// -- The checks. --

const codecs = @import("codecs.zig");
const mjcf = @import("mjcf.zig");
const robot_mjcf = @import("robot_mjcf.zig");

const flex2_xml: []const u8 = @embedFile("tests/fixtures/robot/humanoid_flex2.xml");

const Rig = struct {
    doc: codecs.xml.Document,
    robot: mjcf.Robot,
    imported: robot_mjcf.Imported,

    fn init(rig: *Rig, gpa: Allocator) !void {
        // whole-init-first: the whole struct first - defaults applied, every field named.
        rig.* = .{
            .doc = undefined,
            .robot = undefined,
            .imported = undefined,
        };
        rig.doc = try codecs.xml.parse(gpa, flex2_xml, null);
        errdefer rig.doc.deinit();
        rig.robot = try mjcf.readRobot(gpa, &rig.doc);
        errdefer rig.robot.deinit();
        var options: rbt.Options = .{ .timestep = 1.0 / 60.0, .gravity = vec(0, 0, -9.81), .max_contacts = 256 };
        options.solver.algorithm = .newton;
        rig.imported = try robot_mjcf.build(gpa, &rig.robot, options);
    }

    fn deinit(rig: *Rig) void {
        rig.imported.deinit();
        rig.robot.deinit();
        rig.doc.deinit();
    }

    fn model(rig: *Rig) *rbt.Model {
        return &rig.imported.model;
    }
};

test "robot_policy: the observation does not move with the character" {
    // Walk the whole world sideways and turn it about the vertical, and the policy must see the
    // same numbers - otherwise it has to learn the same balance correction again in every corner
    // of the room, facing every direction. TILT is deliberately NOT removed: a leaning character
    // must look different from an upright one, because that difference is the policy's whole job.
    const gpa: Allocator = testing_allocator;
    var rig: Rig = undefined;
    try rig.init(gpa);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    const subset: Subset = try defaultSubset(gpa, m, rig.imported.names);
    defer subset.deinit(gpa);
    var data: rbt.Data = try .init(gpa, m);
    defer data.deinit();
    var sim: track.State = try .init(gpa, m.body_count);
    defer sim.deinit(gpa);
    var reference: track.State = try .init(gpa, m.body_count);
    defer reference.deinit(gpa);
    var moved_sim: track.State = try .init(gpa, m.body_count);
    defer moved_sim.deinit(gpa);
    var moved_reference: track.State = try .init(gpa, m.body_count);
    defer moved_reference.deinit(gpa);
    // The reference further ahead: three more poses, each a little further on.
    var ahead: [lookahead_frames.len]track.State = undefined;
    var moved_ahead: [lookahead_frames.len]track.State = undefined;
    for (&ahead, &moved_ahead) |*a, *b| {
        a.* = try track.State.init(gpa, m.body_count);
        b.* = try track.State.init(gpa, m.body_count);
    }
    defer for (&ahead, &moved_ahead) |*a, *b| {
        a.deinit(gpa);
        b.deinit(gpa);
    };
    const root: usize = track.rootBody(m);

    var rng: Random.DefaultPrng = .init(4);
    const random: Random = rng.random();
    data.reset(m);
    for (data.joint_positions[7..]) |*q| {
        q.* += 0.3 * random.floatNorm(f32);
    }
    for (data.joint_velocities) |*v| {
        v.* = 0.2 * random.floatNorm(f32);
    }
    // A tilted, moving character, and a reference a little away from it.
    data.joint_positions[2] = 1.1;
    data.stage = .stale;
    rbt.forward(m, &data);
    track.stateOf(m, &data, &sim);
    for (data.joint_positions[7..]) |*q| {
        q.* += 0.05;
    }
    data.stage = .stale;
    rbt.forward(m, &data);
    track.stateOf(m, &data, &reference);
    for (&ahead) |*future| {
        for (data.joint_positions[7..]) |*q| {
            q.* += 0.03;
        }
        data.joint_positions[2] += 0.05;
        data.stage = .stale;
        rbt.forward(m, &data);
        track.stateOf(m, &data, future);
    }

    const previous: []f32 = try gpa.alloc(f32, subset.dofs);
    defer gpa.free(previous);
    for (previous) |*a| {
        a.* = random.floatNorm(f32) * 0.3;
    }
    const before: []f32 = try gpa.alloc(f32, observationSize(subset));
    defer gpa.free(before);
    const after: []f32 = try gpa.alloc(f32, observationSize(subset));
    defer gpa.free(after);
    observe(m, subset, sim, reference, &ahead, root, previous, before);

    // Move both characters together: 7 m east, 3 m north, turned 0.8 rad about the vertical.
    const turn: Quat = .{ 0.0, 0.0, @sin(0.4), @cos(0.4) };
    const shift: Vec = vec(7.0, 3.0, 0.0);
    const froms = [_]*track.State{ &sim, &reference, &ahead[0], &ahead[1], &ahead[2] };
    const tos = [_]*track.State{ &moved_sim, &moved_reference, &moved_ahead[0], &moved_ahead[1], &moved_ahead[2] };
    for (froms, tos) |from, to| {
        for (0..m.body_count) |b| {
            to.positions[b] = rotate(turn, from.positions[b]) + shift;
            to.rotations[b] = zm.qmul(turn, from.rotations[b]);
            to.velocities[b] = rotate(turn, from.velocities[b]);
            to.angular[b] = rotate(turn, from.angular[b]);
        }
    }
    observe(m, subset, moved_sim, moved_reference, &moved_ahead, root, previous, after);

    var worst: f32 = 0.0;
    for (before, after) |a, b| {
        worst = @max(worst, @abs(a - b));
    }
    report.print("\n  observation: {d} numbers, worst change under a 10 m move and a 0.8 rad turn {e}\n", .{
        observationSize(subset),
        worst,
    });
    try expect(worst < 1.0e-4);

    // And a tilt DOES change it - the control that says the invariance is not simply blindness.
    const lean: Quat = .{ @sin(0.15), 0.0, 0.0, @cos(0.15) };
    for (0..m.body_count) |b| {
        moved_sim.positions[b] = rotate(lean, sim.positions[b]);
        moved_sim.rotations[b] = zm.qmul(lean, sim.rotations[b]);
        moved_sim.velocities[b] = rotate(lean, sim.velocities[b]);
        moved_sim.angular[b] = rotate(lean, sim.angular[b]);
    }
    observe(m, subset, moved_sim, reference, &ahead, root, previous, after);
    var changed: f32 = 0.0;
    for (before, after) |a, b| {
        changed = @max(changed, @abs(a - b));
    }
    try expect(changed > 0.01);

    // And DRIFT must show (Sep 26): the reference ALONE moved 0.5 m - where the character sees it must move by
    // exactly that much - then turned ALONE 0.3 rad about its centre of mass - the heading it sees must turn by
    // exactly that. (Right after the height: the reference's place at 10..13, its heading at 13..15.)
    observe(m, subset, sim, reference, &ahead, root, previous, before);
    for (0..m.body_count) |b| {
        moved_reference.positions[b] = reference.positions[b] + vec(0.5, 0.0, 0.0);
        moved_reference.rotations[b] = reference.rotations[b];
        moved_reference.velocities[b] = reference.velocities[b];
        moved_reference.angular[b] = reference.angular[b];
    }
    observe(m, subset, sim, moved_reference, &ahead, root, previous, after);
    const shifted: f32 = length3(vec(after[10], after[11], after[12]) - vec(before[10], before[11], before[12]));
    const centre: Vec = centreOfMass(m, reference);
    const yaw: Quat = .{ 0.0, 0.0, @sin(0.15), @cos(0.15) };
    for (0..m.body_count) |b| {
        moved_reference.positions[b] = rotate(yaw, reference.positions[b] - centre) + centre;
        moved_reference.rotations[b] = zm.qmul(yaw, reference.rotations[b]);
    }
    observe(m, subset, sim, moved_reference, &ahead, root, previous, after);
    const turned: f32 = @abs(atan2Rad(after[14], after[13]) - atan2Rad(before[14], before[13]));
    report.print("  drift made visible: the reference moved 0.5 m alone -> seen {d:.6} m; " ++
        "turned 0.3 rad alone -> seen {d:.6} rad\n", .{ shifted, turned });
    try expect(@abs(shifted - 0.5) < 1.0e-4);
    try expect(@abs(turned - 0.3) < 1.0e-3);
}

test "robot_policy: the filter, and a zero action that changes nothing" {
    const gpa: Allocator = testing_allocator;
    var rig: Rig = undefined;
    try rig.init(gpa);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    const subset: Subset = try defaultSubset(gpa, m, rig.imported.names);
    defer subset.deinit(gpa);
    var controller: Controller = try .init(gpa, m, subset, 1, .{});
    defer controller.deinit();
    const raw: []f32 = try gpa.alloc(f32, subset.dofs);
    defer gpa.free(raw);

    // The filter: one fifth of the way on the first step, and closing on a held request after
    // that - never overshooting, never jumping.
    @memset(raw, 1.0);
    _ = controller.apply(raw);
    try expect(@abs(controller.lastAction(0)[0] - 0.2) < 1.0e-6);
    var previous: f32 = 0.2;
    for (0..20) |_| {
        _ = controller.apply(raw);
        const now: f32 = controller.lastAction(0)[0];
        try expect(now >= previous and now < 1.0);
        previous = now;
    }
    try expect(previous > 0.8);

    // Held between decisions: with decimation 2 the filter moves on every other step only.
    var slow: Controller = try .init(gpa, m, subset, 1, .{ .decimation = 2 });
    defer slow.deinit();
    @memset(raw, 1.0);
    _ = slow.apply(raw);
    const first: f32 = slow.lastAction(0)[0];
    _ = slow.apply(raw);
    try expect(slow.lastAction(0)[0] == first);
    _ = slow.apply(raw);
    try expect(slow.lastAction(0)[0] > first);

    // A zero request expands to exactly nothing: the reference's own targets, untouched. This is
    // the property that lets a policy start as the servo and get better from there, and it has to
    // be exact rather than small - `applyAction` reproduces the reference bit for bit at zero.
    var fresh: Controller = try .init(gpa, m, subset, 4, .{});
    defer fresh.deinit();
    const zeros: []f32 = try gpa.alloc(f32, 4 * subset.dofs);
    defer gpa.free(zeros);
    @memset(zeros, 0.0);
    for (0..5) |_| {
        for (fresh.apply(zeros)) |a| {
            try expect(a == 0.0);
        }
    }
    report.print("  action: {d} of {d} model degrees of freedom, {d} watched bodies\n", .{
        subset.dofs,
        track.actionSize(m),
        subset.bodies.len,
    });
}

test "robot_policy: the limbs' stiffnesses pass through a filter of their own, to the end of the full action" {
    // Two environments, the subset's joints and three stiffnesses each, the joints filtered at a quarter and the
    // stiffnesses at a half. From rest, one decision leaves each joint's number at a quarter of what was asked and
    // each stiffness at a half; the full action holds the joints where the model has them and the stiffnesses after
    // every joint's number; the held step changes nothing; a second decision moves each part by its own share again;
    // and forgetting an environment clears both its parts, the other environment's kept.
    const gpa: Allocator = testing_allocator;
    var rig: Rig = undefined;
    try rig.init(gpa);
    defer rig.deinit();
    const m: *rbt.Model = rig.model();
    const subset: Subset = try defaultSubset(gpa, m, rig.imported.names);
    defer subset.deinit(gpa);
    const env_count: usize = 2;
    const stiffness_count: usize = 3;
    var controller: Controller = try .init(gpa, m, subset, env_count, .{
        .beta = 0.25,
        .decimation = 2,
        .stiffness_count = stiffness_count,
        .stiffness_beta = 0.5,
    });
    defer controller.deinit();
    const action_width: usize = subset.dofs + stiffness_count;
    const joint_numbers: usize = track.actionSize(m);
    const full_width: usize = joint_numbers + stiffness_count;
    try expectEqual(action_width, controller.actionWidth());
    try expectEqual(full_width, controller.fullWidth());
    // What is asked: a joint's number 0.8 in the first environment and -0.4 in the second; a stiffness 1 and -1.
    const asked: []f32 = try gpa.alloc(f32, env_count * action_width);
    defer gpa.free(asked);
    const asked_joint = [env_count]f32{ 0.8, -0.4 };
    const asked_stiffness = [env_count]f32{ 1.0, -1.0 };
    for (0..env_count) |env| {
        const action: []f32 = asked[env * action_width ..][0..action_width];
        @memset(action[0..subset.dofs], asked_joint[env]);
        @memset(action[subset.dofs..], asked_stiffness[env]);
    }
    const first_full: []const f32 = controller.apply(asked);
    try expectEqual(env_count * full_width, first_full.len);
    for (0..env_count) |env| {
        const applied: []const f32 = controller.appliedAction(env);
        try expectEqual(action_width, applied.len);
        for (applied[0..subset.dofs]) |joint_number| {
            try expectEqual(0.25 * asked_joint[env], joint_number);
        }
        for (applied[subset.dofs..]) |stiffness| {
            try expectEqual(0.5 * asked_stiffness[env], stiffness);
        }
        // DReCon's observation reads the joints' part alone.
        try expectEqualSlices(f32, applied[0..subset.dofs], controller.lastAction(env));
        // The full action: the stiffnesses after every joint's number, and as many joints' numbers moved as the
        // subset nudges - the rest exactly zero.
        const full_action: []const f32 = first_full[env * full_width ..][0..full_width];
        try expectEqualSlices(f32, applied[subset.dofs..], full_action[joint_numbers..]);
        var joints_moved: usize = 0;
        for (full_action[0..joint_numbers]) |joint_number| {
            const is_moved: bool = joint_number != 0;
            if (is_moved) {
                try expectEqual(0.25 * asked_joint[env], joint_number);
                joints_moved += 1;
            }
        }
        try expectEqual(subset.dofs, joints_moved);
    }
    // The decision's second step holds: nothing moves, whatever is asked.
    const held_before: []const f32 = try gpa.dupe(f32, controller.filtered);
    defer gpa.free(held_before);
    @memset(asked, 0.0);
    _ = controller.apply(asked);
    try expectEqualSlices(f32, held_before, controller.filtered);
    // The next decision, asking for nothing: each part falls by its own share - three quarters left of a joint's
    // number, a half of a stiffness.
    _ = controller.apply(asked);
    for (0..env_count) |env| {
        const applied: []const f32 = controller.appliedAction(env);
        try expectEqual(0.75 * (0.25 * asked_joint[env]), applied[0]);
        try expectEqual(0.5 * (0.5 * asked_stiffness[env]), applied[subset.dofs]);
    }
    // Forgetting the first environment clears its joints and its stiffnesses, and leaves the second's.
    const second_before: []const f32 = try gpa.dupe(f32, controller.appliedAction(1));
    defer gpa.free(second_before);
    controller.forget(0);
    for (controller.appliedAction(0)) |number| {
        try expectEqual(@as(f32, 0), number);
    }
    try expectEqualSlices(f32, second_before, controller.appliedAction(1));
}
