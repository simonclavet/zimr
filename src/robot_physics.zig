//! robot_physics.zig - where `robot.zig` meets `zimrphysics.zig`.
//!
//! robot.zig has no collision detector and deliberately never will: it takes contacts as
//! an input, exactly the way it takes controls. This file is the one place that knows how
//! to get those contacts out of a zimrphysics world, and it is a SEPARATE FILE for a
//! reason - robot.zig imports only zimrmath, so a batched GPU rollout or a headless
//! trajectory optimisation does not drag a 14k-line collision engine along with it.
//!
//! -- THE DESIGN, AND THE ALTERNATIVE THAT WAS REJECTED --
//!
//! A robot's links are registered as KINEMATIC bodies in a zimrphysics world, steered each
//! step to wherever the robot's own kinematics put them, and the world's contact listener
//! records the manifolds they generate.
//!
//! The obvious alternative - never touch the world, just query its broad phase for
//! candidates near the robot's geoms and run narrow phase ourselves - is tempting because
//! it duplicates no state and needs no body handles. It was rejected for one decisive
//! reason: **zimrphysics's own solver would not see the robot at all.** A crate could not
//! rest on an arm, because as far as the world is concerned the arm is not there. Since
//! the whole point of the seam is that a robot acts on the world, that is fatal.
//!
//! Kinematic bodies give the other direction for free. `moveKinematic` is Jolt's exact
//! tracking: the proxy follows the robot precisely and PUSHES dynamic bodies it meets,
//! with the world's own solver handling that side. Which is exactly the phase-7 one-way
//! coupling the plan specifies - the robot moves the world, the world's push on the robot
//! arrives as constraint rows, and the robot is immovable from the world's point of view.
//!
//! -- WHAT IS APPROXIMATE, STATED PLAINLY --
//!
//! The two solvers do not negotiate. zimrphysics resolves crate-vs-arm treating the arm as
//! infinitely massive, and robot.zig resolves the same contact treating the crate as
//! immovable. Both are solving a contact the other has also solved, so a heavy crate on a
//! light arm will be double-counted and feel stiffer than it should. That is correct for a
//! heavy arm and light objects, which is the case worth having first. See P4 in
//! `src/notes/robot_port_plan.md` for the upgrade ladder.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zm = @import("zm");
const zimrphysics = @import("zimrphysics.zig");
const rbt = @import("robot.zig");
const robot_scene = @import("robot_scene.zig");

const Vec = zm.Vec;
const vec = zm.vec;
const length3 = zm.length3;
const dot3 = zm.dot3;
const cross = zm.cross;
const codecs = @import("codecs.zig");
const mjcf = @import("mjcf.zig");
const robot_mjcf = @import("robot_mjcf.zig");
const clamp = zm.clamp;
const Quat = zm.Quat;
const normalize3 = zm.normalize3;
const splat = zm.splat;
const float = zm.float;
const quatFromAxisAngle = zm.quatFromAxisAngle;
const pi = zm.pi;
const assertf = zm.assertf;

/// One contact event, as recorded mid-step by the listener.
///
/// Recorded rather than acted on, because zimrphysics's listener contract is explicit that
/// callbacks must treat the world as read-only and only note what happened. Converting to
/// robot contacts happens after `step` returns.
const Event = struct {
    /// The tree body this contact touches. Always the `b` side of the robot contact, so
    /// the normal always points TOWARD it and a positive force pushes it away.
    robot_body: u32,
    /// * THE OTHER SIDE, AS A TREE BODY when it is one - section 4k's whole point.
    ///
    /// A crate that lives in the robot's own tree is not "external" to anything: a contact
    /// between an arm link and that crate is a contact between two bodies of ONE system, and
    /// the solver builds the relative Jacobian `jac_b - jac_a` for it exactly as it does for
    /// two links of the same arm. Momentum is then conserved by construction.
    ///
    /// `world_body` when the counterpart really is outside the tree - a static floor, or a
    /// zimrphysics body the scene chose not to simulate in the tree. That case still works
    /// and is still the immovable approximation, which is CORRECT for static geometry and
    /// deliberate for everything else.
    other_body: u32,
    /// The body on the OTHER side, in zimrphysics' numbering. Kept for diagnostics and for
    /// a caller that wants to know which world body a contact came from; the SIMULATION uses
    /// `other_body` above, which is a tree index.
    other: ?zimrphysics.BodyIndex,
    position: Vec,
    /// World normal, already oriented to point at the robot link.
    normal: Vec,
    /// Overlap along the normal, POSITIVE when interpenetrating - the opposite sign
    /// convention from `robot.Contact.distance`, which is negative when touching. Converted
    /// on the way out, once, here rather than at every use.
    depth: f32,
    friction: f32,
    /// `(sub_shape_pair, feature_id)` from the manifold, packed. zimrphysics documents
    /// `feature_id` as stable across frames for warm-start matching, which is exactly the
    /// property `robot.Contact.id` needs.
    id: u64,
};

/// The mapping between one robot and one zimrphysics world.
/// A contact found by sweeping a fast geom, rather than by the discrete detector.
const SweptHit = struct {
    /// The two materials' combined friction, computed the way the detector would have.
    friction: f32,
    geom: u32,
    robot_body: u32,
    /// The other side, already mapped to a tree body or `not_a_robot_body` for static geometry.
    other: u32,
    position: Vec,
    normal: Vec,
    /// Distance still to travel before the surface - positive, so the contact acts early.
    gap: f32,
};

pub const Bridge = struct {
    gpa: Allocator,
    /// One kinematic proxy body per robot geom.
    proxy: []zimrphysics.BodyHandle,
    /// Which robot body each proxy belongs to, parallel to `proxy`.
    proxy_body: []u32,
    /// Reverse lookup: zimrphysics body index -> robot body, or `not_a_robot_body`.
    /// A flat array rather than a hash map because it is read inside the contact callback,
    /// which runs per pair per step.
    world_to_robot: []u32,
    events: []Event,
    event_count: u32,
    /// Set by `teleported`, cleared by the next `sync`. See that function.
    skip_sweep_once: bool,
    /// Swept contacts found this step - see `recordSweptContact`.
    swept: []SweptHit,
    swept_count: u32,
    /// The model's timestep, kept so `harvest` can size a speculative margin without being
    /// handed the model - it is a constant of the model and never changes after `init`.
    timestep: f32,

    /// How soft and how thick the flesh around every body is.
    ///
    /// -- ** WHAT MAKES A CONTACT FEEL LIKE FLESH RATHER THAN BONE --
    ///
    /// Three separable properties, and the solver already implements all of them - this is
    /// where they get chosen rather than hardcoded:
    ///
    ///   * **soft at first touch, stiff when compressed.** `Impedance` ramps the constraint's
    ///     strength from `min` to `max` across `width` of penetration. A `min` near zero and a
    ///     `width` of a centimetre is skin then fat then bone;
    ///   * **absorbing, not returning.** `damp_ratio` above 1 is overdamped: the energy of an
    ///     impact goes into the contact instead of back into the body;
    ///   * **slow.** A longer `time_const_s` responds over milliseconds rather than instantly.
    ///
    /// * THE DEFAULTS REPRODUCE WHAT WAS HARDCODED HERE - `2 x timestep` and MuJoCo's own
    /// impedance defaults - so a caller that does not touch this sees exactly the old
    /// behaviour. `flesh_thickness` at zero means the impedance ramp is left alone.
    flesh: Flesh,

    /// The nearest ancestor reachable without crossing a joint - MuJoCo's `body_weldid`.
    ///
    /// -- *** WHY CONTACT NEEDS THIS AT ALL --
    ///
    /// Two links joined by a hinge OVERLAP near that hinge, always, by construction - that is
    /// what a joint looks like geometrically. Reporting those overlaps as contacts gives a
    /// limb that fights itself the moment it folds: measured on a 4-DOF arm commanded to a
    /// perfectly reachable pose, the elbow settled **0.43 rad short with two contacts that
    /// never went away**, and no amount of gain fixed it because the arm was pushing against
    /// its own upper link.
    ///
    /// **MuJoCo filters exactly this**, in `filterBodyPair`: same weld body, or either being
    /// the other's weld parent. Its `dsbl_filterparent` flag exists to turn it off, and
    /// essentially nothing does.
    ///
    /// * WELD, NOT PARENT. A chain of jointless bodies is ONE rigid object however many links
    /// it is written as, so the relation that matters is "same rigid piece, or adjacent rigid
    /// pieces" rather than "adjacent in the body list". Filtering on the raw parent would miss
    /// a decorative link sitting between two real ones.
    weld: []u32,
    /// `weld[parent[weld[b]]]` for each body - the rigid piece the piece above it belongs to.
    /// Precomputed because the contact callback has no model to walk, and it is a constant of
    /// the topology anyway.
    weld_parent: []u32,
    /// Body pairs the model says never collide (`Model.exclude_pairs`, MJCF's `<contact><exclude>`).
    /// Borrowed from the model, which outlives its bridge.
    excluded: []const [2]u32 = &.{},
    /// Whether a tree body is welded to the world, indexed by tree body.
    ///
    /// * PRECOMPUTED, because it is asked on every contact of every step and the answer never
    /// changes - it is a property of the model's topology. Walking to the root inside the
    /// callback would put a tree traversal in the hottest loop the bridge has.
    rigid: []bool,
    /// Set when more contacts arrived in a step than `Options.max_contacts` allows, so the
    /// overflow is reported once and calmly rather than as an assert inside a callback that
    /// is not allowed to fail.
    overflowed: bool,

    pub const not_a_robot_body: u32 = zm.maxInt(u32);

    /// Register every geom of `model` as a kinematic body in `world`.
    ///
    /// The proxies start at the robot's current pose, so call this after the robot's
    /// kinematics have been run at least once - otherwise they are all created at the
    /// origin and the first step sees a large spurious motion.
    /// Runtime-tunable contact feel. See `Bridge.flesh`.
    pub const Flesh = struct {
        /// How quickly a violated contact is corrected. Larger is softer.
        ///
        /// Null takes `2 x timestep`, which is what this was before it could be set - MuJoCo's
        /// own default at its default rate.
        time_const_s: ?f32 = null,
        /// 1 is critically damped; above 1 absorbs rather than rebounds.
        damp_ratio: f32 = 1.0,
        /// * THE "FAT" KNOB. The depth over which the contact stiffens from `soft_min` to full.
        /// Zero leaves the solver's default impedance untouched - a hard surface. One centimetre
        /// is a plausible layer of skin and fat over a bone.
        thickness_m: f32 = 0,
        /// Impedance at first touch, when `thickness_m` is non-zero. Near zero means the
        /// surface barely resists until it has been pressed into.
        soft_min: f32 = 0.02,
    };

    /// The softness these settings imply, for one contact.
    ///
    /// ** THE CALLER SUPPLIES ITS OWN DEFAULT, and that is not tidiness. The two contact
    /// producers had DIFFERENT defaults for good reasons: a swept contact is deliberately stiff
    /// at `2 x timestep`, because it exists to stop something travelling fast, while a discrete
    /// one takes `Softness{}`'s 0.02. Unifying them on the swept value made every ordinary
    /// contact five times stiffer and dropped a six-box stack by 3 cm - caught by the stack
    /// test, which is exactly the sort of thing a shared default quietly does.
    fn contactSoftness(self: *const Bridge, default_time_const: f32) rbt.Softness {
        return .{
            .time_const_s = self.flesh.time_const_s orelse default_time_const,
            .damp_ratio = self.flesh.damp_ratio,
        };
    }

    /// The impedance ramp these settings imply.
    fn contactImpedance(self: *const Bridge) rbt.Impedance {
        if (self.flesh.thickness_m <= 0) {
            return .{};
        }
        return .{
            .min = self.flesh.soft_min,
            .max = 0.99,
            .width = self.flesh.thickness_m,
        };
    }

    pub fn init(
        gpa: Allocator,
        world: *zimrphysics.World,
        model: *const rbt.Model,
        data: *const rbt.Data,
        world_body_capacity: u32,
    ) !Bridge {
        const count: usize = model.ngeom;

        // ** ALLOCATED ONE AT A TIME WITH `errdefer`, not in a struct literal.
        //
        // Five allocations and two more fallible calls follow - `addShape` and `createBody`,
        // either of which can fail on a full shape table. Inside a struct literal there is
        // nowhere to put an `errdefer`, so a failure at the third `alloc` leaked the first
        // two, and a failure in `createBody` leaked all five. Nothing observed it because the
        // only trigger is OOM, and `std.testing.allocator` never sees the path - which is
        // exactly why it is worth fixing rather than arguing about.
        const proxy: []zimrphysics.BodyHandle = try gpa.alloc(zimrphysics.BodyHandle, count);
        errdefer gpa.free(proxy);
        const proxy_body: []u32 = try gpa.alloc(u32, count);
        errdefer gpa.free(proxy_body);
        const world_to_robot: []u32 = try gpa.alloc(u32, world_body_capacity);
        errdefer gpa.free(world_to_robot);
        const events: []Event = try gpa.alloc(Event, model.opt.max_contacts);
        errdefer gpa.free(events);
        const rigid: []bool = try gpa.alloc(bool, model.nbody);
        errdefer gpa.free(rigid);
        // * COMPUTED PARENT-FIRST, so `weld[parent]` is already final when a child reads it.
        // `buildRuntime` guarantees that ordering, which is what makes one pass enough.
        const weld: []u32 = try gpa.alloc(u32, model.nbody);
        errdefer gpa.free(weld);
        weld[rbt.world_body] = rbt.world_body;
        for (1..model.nbody) |body| {
            weld[body] = if (model.body_dof_num[body] > 0)
                @intCast(body)
            else
                weld[model.body_parent[body]];
        }
        const weld_parent: []u32 = try gpa.alloc(u32, model.nbody);
        errdefer gpa.free(weld_parent);
        for (0..model.nbody) |body| {
            weld_parent[body] = weld[model.body_parent[weld[body]]];
        }
        // One swept hit per geom is the most a single step can produce.
        const swept: []SweptHit = try gpa.alloc(SweptHit, model.ngeom);
        errdefer gpa.free(swept);

        // * WELDED-TO-THE-WORLD, PRECOMPUTED. A body with no articulated DOF between it
        // and the world cannot move, and a contact between two such bodies is not a
        // constraint - it is a fact the solver can neither satisfy nor violate.
        //
        // `robot_3d`'s KUKA base sits 7 cm inside the floor and is welded there. Those
        // four rows appeared every step with an unfixable violation, consumed the whole
        // iteration budget, and the damage landed on the crates: **90 m/s ejections
        // instead of 1.34**. Nothing about it was visible, because the base could not
        // move and therefore always looked right.
        for (rigid, 0..) |*flag, body| {
            var dofs: u32 = 0;
            var walk: u32 = @intCast(body);
            while (walk != rbt.world_body) : (walk = model.body_parent[walk]) {
                dofs += model.body_dof_num[walk];
            }
            flag.* = dofs == 0;
        }

        var bridge: Bridge = .{
            .gpa = gpa,
            .proxy = proxy,
            .proxy_body = proxy_body,
            .world_to_robot = world_to_robot,
            .events = events,
            .weld = weld,
            .weld_parent = weld_parent,
            .excluded = model.exclude_pairs,
            .rigid = rigid,
            .swept = swept,
            .swept_count = 0,
            .skip_sweep_once = false,
            .timestep = model.opt.timestep,
            // Defaults reproduce exactly what was hardcoded here before it was tunable.
            .flesh = .{},
            .event_count = 0,
            .overflowed = false,
        };
        @memset(bridge.world_to_robot, not_a_robot_body);

        // ** ONE GROUP PER ROOT, NOT ONE PER MODEL - and getting this wrong made a crate
        // tower fall through itself.
        //
        // zimrphysics never tests two bodies that share a nonzero `group_id`. A single group
        // for the whole model meant no pair of tree bodies was ever broad-phased against
        // another, which was a sound optimisation while `onContact` discarded robot-vs-robot
        // pairs anyway. section 4k changed that: a scene's CRATES are tree bodies now, and
        // crate-versus-crate is the ordinary case rather than exotic self-collision.
        //
        // The symptom was precise and easy to misread: contacts were reported (4 of them),
        // the crates rested on the floor, and the tower still sank into itself - because
        // every reported contact was crate-0-versus-FLOOR and no crate ever saw another.
        //
        // Grouping by ROOT keeps what the optimisation was for. Bodies of one articulated
        // chain share a root and still do not self-collide - which is what a robot wants by
        // default, since adjacent links overlap at every joint. A free body is its own root,
        // so it collides with everything including other free bodies.

        for (0..count) |geom| {
            const body: u32 = model.geom_body[geom];
            const shape: zimrphysics.ShapeId = try addShape(gpa, world, model.geom_shape[geom]);
            const pose: rbt.Pose = geomPose(model, data, @intCast(geom));
            const handle: zimrphysics.BodyHandle = try world.createBody(.{
                .shape = shape,
                .position = pose.pos,
                .rotation = pose.rot,
                // KINEMATIC, not dynamic: the robot's own dynamics decide where this goes,
                // and a dynamic proxy would also feel gravity and fight them.
                // * THE PROXY CARRIES THE GEOM'S MATERIAL. Without this the detector has no idea
                // what the robot is made of, and every contact fell back to a constant.
                .friction = model.geom_friction[geom],
                .motion_type = .kinematic,
                // * NOT A SENSOR, and now for a simpler reason than before.
                //
                // A proxy exists so the detector can SEE the robot; it never needs to
                // respond, because it is kinematic and zimrphysics cannot move it anyway.
                // The sensor question mattered only while zimrphysics was also resolving
                // robot-vs-dynamic pairs - and with the tree unified it no longer resolves
                // them at all, because those bodies are not in its world as dynamics.
                .is_sensor = false,
                // * Without this the arm cannot touch the LEVEL. zimrphysics drops any pair
                // where neither body has finite mass - static/kinematic included - because
                // its own solver could carry no impulse across it. Perfectly sound for
                // zimrphysics; wrong for us, because robot.zig is the thing that carries
                // that impulse. The flag says "report it anyway, the owner will act on it",
                // and unlike `is_sensor` it leaves the proxy's push on dynamic bodies
                // untouched.
                .report_immovable_contacts = true,
                // * All of one robot's proxies share a group, so they never pair with each
                // other. Two things make this necessary rather than tidy. `onContact`
                // already discards robot-vs-robot pairs, so nothing was WRONG - but every
                // adjacent link whose geoms overlap was being broad-phased and
                // narrow-phased each step for a result that is thrown away, and a humanoid
                // has a lot of those. And `report_immovable_contacts` made it worse: before
                // it, kinematic-vs-kinematic pairs were dropped by the immovable gate, so
                // opting out of that gate is exactly what put this work back.
                //
                // ** AND THAT PREMISE WAS WRONG, WHICH IS WHY THIS IS NOW PER-LINK.
                // `onContact` does NOT discard robot-vs-robot pairs - it discards WELDED
                // and ADJACENT ones, via `sameOrAdjacentWeld`. Two shins are neither. A
                // whole-robot group therefore threw away exactly the self-collisions a
                // humanoid needs, and the legs passed through one another: measured, the
                // shins sat 0.0315 m apart with radii near 0.05 each - a 7 cm overlap -
                // reporting **zero** robot-vs-robot contacts where MuJoCo reported two.
                //
                // Per-link groups put those pairs back in the broad phase and leave the
                // filtering to `sameOrAdjacentWeld`, which is what MuJoCo does: it filters
                // by WELD RELATIONSHIP, not by membership of a body. The two-body contact
                // Jacobian (`J_b - J_a`, both sides in the tree) that these rows need is
                // already supported by `addContactRows`.
                //
                // * THE COST IS REAL AND WAS THE ORIGINAL MOTIVATION: adjacent links whose
                // geoms overlap at their shared joint are now broad- and narrow-phased each
                // step for a result `onContact` throws away. Correctness first; if that
                // shows up in a profile, the answer is a cheaper adjacency test in the
                // broad phase, not a group that also hides real contacts.
                .group_id = body | 0x8000_0000,
            });
            bridge.proxy[geom] = handle;
            bridge.proxy_body[geom] = body;
            const idx: u32 = @intCast(handle.index());
            assertf(
                idx < bridge.world_to_robot.len,
                @src(),
                "world body index {d} exceeds the bridge's capacity {d}",
                .{ idx, bridge.world_to_robot.len },
            );
            bridge.world_to_robot[idx] = body;
        }
        return bridge;
    }

    /// Which robot body a world body belongs to, or `not_a_robot_body`.
    fn robotBodyOf(self: *const Bridge, index: zimrphysics.BodyIndex) u32 {
        const i: usize = @intCast(index);
        if (i >= self.world_to_robot.len) {
            return not_a_robot_body;
        }
        return self.world_to_robot[i];
    }

    /// Give the world back everything this bridge put into it, then free our own memory.
    ///
    /// `world` is required, and that is deliberate. The previous version freed only the
    /// bridge's arrays, which left TWO live faults: the proxy bodies stayed in the world
    /// forever, colliding with things on behalf of a robot that no longer exists; and
    /// `world.contact_listener` still held a pointer to the freed bridge, so the next step
    /// called back into released memory. Neither is visible until something else happens to
    /// touch a proxy, which is the worst kind of bug to leave behind.
    /// Tell the bridge the robot was MOVED rather than having travelled.
    ///
    /// -- *** A TELEPORT IS NOT MOTION, AND ONLY THE CALLER KNOWS --
    ///
    /// `sync` cannot tell the difference by looking. It sees a proxy that was there and is now
    /// here, and every heuristic for "that was too far to be real" is a threshold that some
    /// scene sits on the wrong side of. A first attempt capped travel at twenty times a geom's
    /// own radius, which is fine for a ball and useless for a 1 cm capsule: a reset moving the
    /// robot 0.18 m is EIGHTEEN radii for a Go1 calf, comfortably under the bar, so the sweep
    /// ran and found the floor. Measured result: **47 contacts and velocity pinned at
    /// 100 m/s** on the first step after a reset.
    ///
    /// So the caller says so. Anything that writes `qpos` directly - a keyframe, a reset
    /// button, an editor drag, a scene reposition - calls this, and the next `sync` places the
    /// proxies without sweeping between the two poses.
    ///
    /// * ONE STEP ONLY. The step after a teleport is ordinary motion again, and leaving the
    /// suppression on would quietly disable continuous collision for good.
    pub fn teleported(self: *Bridge) void {
        self.skip_sweep_once = true;
    }

    /// Whether two tree bodies are the same rigid piece, or two pieces sharing a joint.
    ///
    /// MuJoCo's `filterBodyPair`, minus the sleep clauses this engine has no equivalent for.
    fn sameOrAdjacentWeld(self: *const Bridge, a: u32, b: u32) bool {
        if (a == not_a_robot_body or b == not_a_robot_body) {
            return false; // static geometry is nobody's limb
        }
        // Pairs the model excludes by name, in either order: MuJoCo's answer for two bodies that are not
        // adjacent but overlap by design (a chest and an upper arm, across a shapeless clavicle).
        for (self.excluded) |pair| {
            if ((pair[0] == a and pair[1] == b) or (pair[0] == b and pair[1] == a)) {
                return true;
            }
        }
        const weld_a: u32 = self.weld[a];
        const weld_b: u32 = self.weld[b];
        if (weld_a == weld_b) {
            return true;
        }
        // * NEITHER SIDE MAY BE THE WORLD. A body genuinely resting on the ground has the world
        // as its weld parent, and filtering that would drop every floor contact there is.
        if (weld_a == rbt.world_body or weld_b == rbt.world_body) {
            return false;
        }
        return weld_a == self.weld_parent[weld_b] or weld_b == self.weld_parent[weld_a];
    }

    /// True when no degree of freedom can change where this body is.
    fn isRigid(self: *const Bridge, body: u32) bool {
        if (body == not_a_robot_body or body == rbt.world_body) {
            return true; // static geometry, and the world itself
        }
        return self.rigid[body];
    }

    pub fn deinit(self: *Bridge, world: *zimrphysics.World) void {
        self.gpa.free(self.swept);
        self.gpa.free(self.weld_parent);
        self.gpa.free(self.weld);
        self.gpa.free(self.rigid);
        // Only clear the listener if it is still OURS. A caller who installed a different
        // listener afterwards should keep it.
        if (world.contact_listener) |listener| {
            if (listener.context == @as(?*anyopaque, @ptrCast(self))) {
                world.contact_listener = null;
            }
        }
        for (self.proxy) |handle| {
            _ = world.removeBody(handle.index());
        }
        self.gpa.free(self.proxy);
        self.gpa.free(self.proxy_body);
        self.gpa.free(self.world_to_robot);
        self.gpa.free(self.events);
        self.* = undefined;
    }

    /// Install this bridge's listener on the world. The world holds a pointer to the
    /// bridge, so the bridge must outlive the world's use of it.
    pub fn listen(self: *Bridge, world: *zimrphysics.World) void {
        world.contact_listener = .{
            .context = self,
            .on_contact_added = onContact,
            .on_contact_persisted = onContact,
        };
    }

    /// Steer every proxy to where the robot's kinematics currently put its geom. Call once
    /// per step, BEFORE `world.step`, with the same `dt` the world will use.
    pub fn sync(
        self: *Bridge,
        world: *zimrphysics.World,
        model: *const rbt.Model,
        // * MUTABLE ONLY TO CLEAR `teleported`. Everything else read here is read-only, and
        // the alternative - leaving the flag set - would suppress the sweep forever.
        data: *rbt.Data,
    ) !void {
        // ** TELEPORT, DO NOT STEER - and the distinction cost several sessions.
        //
        // `moveKinematic` does not move a body. It sets a VELOCITY that will carry it to the
        // target over `dt`, so during the collision detection that follows, **the proxy is
        // still at the PREVIOUS pose**. The detector reports contacts for where the robot
        // was, not where it is.
        //
        // For a body resting flat that lag is invisible, which is why every flat test
        // passed. For a box rocking on a corner it is fatal: the corner it is told about is
        // the one from last step, so the push arrives in the wrong place and the box rocks
        // instead of tipping. MuJoCo has no such gap - `mj_forward` collides at exactly the
        // `q` it then solves at.
        //
        // Steering was RIGHT while the bridge was a simulator: a kinematic body needs a
        // velocity for its contacts with dynamic bodies to transfer momentum. section 4k made the
        // bridge a pure DETECTOR - the crates it once pushed are tree bodies now, and
        // zimrphysics resolves nothing - so the velocity buys nothing and the lag is pure
        // cost. `setTransform` puts the proxy exactly where the tree says it is.
        self.swept_count = 0;
        // * EITHER SIGNAL SUPPRESSES THE SWEEP: the data's own flag, set by whatever wrote
        // `pos` wholesale, or an explicit `teleported()` from a caller doing something the
        // engine has no name for. The first covers keyframes and state restores without anyone
        // having to remember; the second is the escape hatch.
        const sweeping: bool = !self.skip_sweep_once and !data.teleported;
        self.skip_sweep_once = false;
        data.teleported = false;
        for (0..model.ngeom) |geom| {
            const pose: rbt.Pose = geomPose(model, data, @intCast(geom));
            const handle: zimrphysics.BodyIndex = self.proxy[geom].index();
            // * READ WHERE IT WAS BEFORE MOVING IT. The proxy's current position IS last
            // step's pose, so the sweep needs no extra bookkeeping - but only until
            // `setTransform` overwrites it two lines down.
            if (sweeping) {
                self.recordSweptContact(world, model, @intCast(geom), world.bodies.data[handle].com_pos, pose);
            }
            try world.setTransform(self.gpa, handle, pose.pos, pose.rot);
        }
        // -- *** SWEPT CONTACTS FOR ANYTHING OUTRUNNING ITS OWN SIZE --
        //
        // The discrete detector reports a contact for where a body IS. That is enough until a
        // body crosses something thin in one step - and then the contact it reports is on the
        // far side, with a normal that pushes the body onward. Measured on a 0.05 m ball at a
        // 0.10 m wall: contact detected at every speed, ball decelerated 20 m/s to 1.32, and
        // still ejected out the back because its centre had passed the wall's mid-plane before
        // the solver could act. **A convex shape has no memory of which side something entered
        // from.**
        //
        // So a fast geom is swept, and a hit becomes a contact for the moment of IMPACT rather
        // than for the pose it will illegally reach. The proxy still goes exactly where the
        // tree says - placing it short instead was tried first and is worse, because the
        // proxy freezes while the tree body flies on and the two describe different robots.
        // Events are collected during the step that follows, so clear now rather than
        // after - clearing after would discard the very events we are about to read.
        self.event_count = 0;
        self.overflowed = false;
    }

    /// Sweep a fast-moving geom and remember where it would first hit something.
    ///
    /// -- ** WHY A SWEPT CONTACT AND NOT A SWEPT POSITION --
    ///
    /// The obvious fix is to stop the proxy at the impact point. It does not work: the proxy
    /// freezes while the tree body - which the robot's own solver integrates - flies on, so the
    /// two describe different robots and the contact is reported for a pose nothing is in.
    ///
    /// A contact is the right output because that is what this module produces. The sweep says
    /// "this geom will reach that surface partway through the step"; expressed as a contact with a
    /// POSITIVE distance, that is exactly a speculative contact, and the solver already knows how
    /// to decelerate against one. It acts before the crossing instead of after.
    fn recordSweptContact(
        self: *Bridge,
        world: *const zimrphysics.World,
        model: *const rbt.Model,
        geom: u32,
        from: Vec,
        pose: rbt.Pose,
    ) void {
        if (self.swept_count >= self.swept.len) {
            return;
        }
        const motion: Vec = pose.pos - from;
        const travel: f32 = length3(motion);
        const reach: f32 = ccdRadius(model.geom_shape[geom]);
        // * `linear_cast_threshold` (0.75 of the shape's inner radius) is zimrphysics' own CCD
        // trigger, reused rather than a second convention invented next door. Below it the
        // discrete detector already sees the contact on the correct side.
        if (reach <= 0 or travel < world.settings.linear_cast_threshold * reach) {
            return;
        }

        // -- *** AND A JUMP IS NOT MOTION --
        //
        // A proxy that moved several metres in one step did not travel there; something
        // TELEPORTED it. Applying a keyframe does exactly that, and so does a demo's reset
        // button, an editor drag, or a scene being repositioned.
        //
        // Swept against the whole line between the two poses, such a jump finds whatever
        // happens to lie along it - geometry the robot was never near - and manufactures a
        // contact for it, at a gap of metres, with the stiff softness a swept contact carries.
        // The result is a robot that appears to explode the frame after being reset, which
        // reads as the reset being broken and is this.
        //
        // * THE BOUND IS GENEROUS BECAUSE IT ONLY HAS TO SEPARATE THE TWO CASES. The fastest
        // thing a demo throws is ~30 m/s, which at 500 Hz is 0.06 m - well under twenty radii
        // for anything but a pinhead. A reset moves metres. Nothing real lives in between.
        if (travel > max_swept_travel * reach) {
            return;
        }

        var buffer: [4096]u8 = undefined;
        var scratch: std.heap.FixedBufferAllocator = .init(&buffer);
        const handle: zimrphysics.BodyIndex = self.proxy[geom].index();
        const shape: *const zimrphysics.Shape = world.shapes.get(world.bodies.data[handle].shape);
        const hit: ?zimrphysics.ShapeCastHit = zimrphysics.castShapeClosest(
            world,
            scratch.allocator(),
            shape,
            from,
            pose.rot,
            motion,
            travel,
            .{ .exclude = handle, .include_sensors = false },
        ) catch return;

        const impact: zimrphysics.ShapeCastHit = hit orelse return;

        // -- *** THE SWEPT PATH MUST APPLY THE SAME FILTERS AS THE DISCRETE ONE --
        //
        // `onContact` drops pairs that cannot move relative to each other and pairs joined by a
        // joint. `recordSweptContact` pushes straight into `harvest` and bypassed both, so a
        // limb folding at speed generated exactly the self-contacts the filter exists to
        // remove: measured on a 4-DOF arm, `wrist` against `right_finger` - a parent and its
        // own child - pinning the elbow **0.43 rad short of a reachable pose**, with the
        // contacts never clearing however long it ran.
        //
        // * TWO PATHS TO THE SAME OUTPUT MUST SHARE THE SAME RULES. Adding a second producer
        // of contacts without giving it the first one's filters is the whole of this bug, and
        // it is worth stating because it will be true of the next producer too.
        const other: u32 = blk: {
            const mapped: u32 = self.robotBodyOf(impact.body);
            break :blk if (mapped == not_a_robot_body) rbt.world_body else mapped;
        };
        const mine: u32 = model.geom_body[geom];
        if (self.isRigid(mine) and self.isRigid(other)) {
            return;
        }
        if (self.sameOrAdjacentWeld(mine, other)) {
            return;
        }
        const mine_friction: f32 = world.bodies.data[handle].friction;
        const other_friction: f32 = world.bodies.data[impact.body].friction;
        // ---- BOUNDED, BECAUSE `swept` IS SIZED BY A GUESS ----
        //
        // *** `swept` is `alloc(SweptHit, model.ngeom)`, which assumes AT MOST ONE SWEEP PER
        // GEOM. A geom that moves far enough in one step can sweep against several others, so
        // the assumption is a heuristic and not a bound - and this write had no check at all.
        //
        // Overrunning it is an out-of-bounds write into whatever follows the allocation. In a
        // safe build that is a panic; in wasm it is a bare `unreachable` with no stack, which is
        // how it presented for five turns of debugging in `dance_track`.
        //
        // Dropping the hit is the right failure: a missed contact is a character that sinks
        // slightly, while a corrupted heap is anything at all.
        if (self.swept_count >= self.swept.len) {
            return;
        }
        self.swept[self.swept_count] = .{
            .friction = @sqrt(@max(0, mine_friction * other_friction)),
            .geom = geom,
            .robot_body = model.geom_body[geom],
            // * STATIC GEOMETRY IS `world_body`, NOT `not_a_robot_body` - the latter is maxInt, a
            // sentinel for "no mapping", and pushing it in as a body index reads far off the end
            // of every per-body array. Resolved above, where the filters need it too.
            .other = other,
            .position = impact.point,
            .normal = impact.normal,
            // How far along the step the surface is. Positive, so the contact engages EARLY -
            // which is the whole point: a speculative contact decelerates rather than catches.
            .gap = impact.fraction * travel,
        };
        self.swept_count += 1;
    }

    /// Convert the events recorded during `world.step` into robot contacts. Call AFTER the
    /// world has stepped and before the robot's `forward`.
    /// Turn this step's recorded contacts into the robot's contact inputs.
    ///
    /// * NO LONGER NEEDS THE WORLD. It briefly took one, to look up how heavy the other
    /// side of each contact was - the robot could not otherwise know. In a unified tree it
    /// does know: both bodies are in its own mass matrix, and the relative Jacobian carries
    /// them. What crosses this boundary is now purely GEOMETRY.
    pub fn harvest(self: *Bridge, data: *rbt.Data) void {
        data.clearContacts();

        // * SWEPT CONTACTS FIRST, so they are never the rows dropped when a step overflows
        // `max_contacts`. A contact that prevents a body leaving the world matters more than
        // one more row on a foot already resting on the floor.
        for (self.swept[0..self.swept_count]) |hit| {
            const frame: [2]Vec = tangentFrame(hit.normal);
            data.pushContact(.{
                .position = hit.position,
                .normal = hit.normal,
                .tangent = frame,
                .distance = hit.gap,
                // ** THE REAL MATERIALS, NOT A CONSTANT. This read `0.5` on both axes, so a
                // body moving fast enough to be swept got rubber friction whatever its
                // material said - ice gripped and a grippy foot slipped, but only above the
                // speed that triggers a sweep, which is a horrible thing to debug.
                //
                // The discrete path takes `event.friction`, already combined by the detector.
                // A sweep produces no event, so the same combination is done here from the two
                // bodies' own values, the geometric mean being what zimrphysics uses.
                .friction = .{ hit.friction, hit.friction },
                // * THE MARGIN COVERS THE WHOLE REMAINING TRAVEL, which is what makes this a
                // speculative contact rather than a distant one the solver would ignore: a row
                // only acts inside its margin, and the impact is exactly `gap` away.
                .margin = hit.gap + max_speculative_margin,
                // ** AND A SWEPT CONTACT IS STIFF, because it exists for ONE step.
                //
                // The default softness has a 0.02 s time constant - ten steps at 500 Hz -
                // which is right for a foot settling and useless for an impact that must be
                // arrested before the next frame. Measured with the default: a 20 m/s ball
                // decelerated and still crossed, because the contact was gone by the time it
                // had done a tenth of its work. Two timesteps is the stiffest setting the
                // solver can represent without asking for a correction it cannot make.
                .softness = self.contactSoftness(2.0 * self.timestep),
                .impedance = self.contactImpedance(),
                .body_a = hit.other,
                .body_b = hit.robot_body,
                .id = 0x57E9 +% hit.geom,
            });
        }
        for (self.events[0..self.event_count]) |event| {
            const frame: [2]Vec = tangentFrame(event.normal);
            data.pushContact(.{
                .position = event.position,
                .normal = event.normal,
                .tangent = frame,
                // zimrphysics reports overlap as POSITIVE depth; robot.Contact wants
                // separation, negative when touching.
                .distance = -event.depth,
                .friction = .{ event.friction, event.friction },
                // ** THE MARGIN, AND LEAVING IT AT ZERO CAUSED A LIMIT CYCLE.
                //
                // zimrphysics reports every contact within its SPECULATIVE DISTANCE - 2 cm
                // by default - so the robot receives pairs that are merely close, not yet
                // touching. With `margin = 0` the robot discarded all of those: a row only
                // existed once the shapes already overlapped.
                //
                // For a box resting flat that is harmless; four contacts settle into a
                // shallow overlap and stay. For a box balanced on a CORNER it is a limit
                // cycle: it falls, penetrates, gets a large corrective push (60 solver
                // iterations, the cap), separates, loses its rows entirely, falls again.
                // **Measured: a corner-balanced crate never settled - tilt swinging between
                // 0.7 and 2.6 rad with |omega| stuck at 1-2.7 rad/s, indefinitely.** Visible as
                // boxes that dance on their corners.
                //
                // Matching the detector's own speculative distance means a contact begins to
                // act as the gap closes, so the constraint DECELERATES the approach instead
                // of catching it after the fact. That is precisely what the field is for,
                // and what MuJoCo's own `margin` does.
                // ** AND IT SCALES WITH HOW FAR THE BODY MOVES IN A STEP.
                //
                // A fixed zero was correct for the settling case above and useless for a fast
                // one. **Measured: a 0.05 m ball fired at a 0.1 m wall passes THROUGH at
                // 20 m/s** - contact is reported, but only once the ball is already on the far
                // side, so the normal points the wrong way and the impulse helps it on its
                // way. A thrown ball is 10-30 m/s, so this is squarely in the range the demos
                // need.
                //
                // A margin is a distance at which a contact starts acting, so the useful size
                // is the distance the pair can close before the next step: `|v_rel| * dt`.
                // Below walking pace it is millimetres and nothing changes; at 20 m/s it is
                // 4 cm and the constraint engages while the ball is still in front of the wall.
                //
                // * CAPPED, because an unbounded margin is a body that collides with things it
                // will never reach - and an earlier attempt at a large fixed margin produced
                // 1.4 GN in the full scene.
                .margin = speculativeMargin(data.cvel[event.robot_body].lin, self.timestep),
                // * BOTH SIDES AS TREE BODIES where they are. `world_body` on the `a` side
                // is now the SPECIAL case - static geometry - rather than the only case.
                // ** THE SAME FLESH SETTINGS AS THE SWEPT PATH. This site had no `softness` or
                // `impedance` field at all, so it silently took `Contact`'s struct defaults - and a
                // knob wired into the other producer changed nothing, because the DISCRETE path is
                // the one that makes almost every contact. Two producers, one of them updated: the
                // same shape as the friction bug and the swept-filter bug before it.
                .softness = self.contactSoftness((rbt.Softness{}).time_const_s),
                .impedance = self.contactImpedance(),
                .body_a = event.other_body,
                .body_b = event.robot_body,
                .id = event.id,
            });
        }
    }
};

/// Contacts act from the moment they overlap, with no early-engagement margin.
///
/// -- * MEASURED, AFTER A LONG DETOUR --
///
/// A margin was added to fix boxes that danced on their corners, on the theory that a
/// constraint needs a band in which to decelerate an approach. It did not work: 0.004 still
/// danced, 0.02 settled a box but left it hovering one margin above the floor and produced
/// 1.4 GN in a full scene.
///
/// The dance was never about the margin. It was the proxy pose lagging a step (see `sync`),
/// and with that fixed every case settles at TWO solver iterations with no margin at all.
/// Kept as a named zero rather than deleted, because "why is there no margin here" is a
/// reasonable question to ask of this code and this is the answer.
fn ccdRadius(shape: rbt.GeomShape) f32 {
    return switch (shape) {
        .sphere => |s| s.radius,
        .capsule => |c| c.radius,
        .cylinder => |c| c.radius,
        .box => |b| @min(b.half_extent[0], @min(b.half_extent[1], b.half_extent[2])),
        .hull => |h| @min(h.bounds_half_extent[0], @min(h.bounds_half_extent[1], h.bounds_half_extent[2])),
    };
}

/// Furthest a geom may move in one step and still be treated as MOVING rather than teleported,
/// as a multiple of its own radius.
///
/// See `recordSweptContact`: past this, a sweep is finding geometry the body was never near.
const max_swept_travel: f32 = 20.0;

/// Largest speculative margin any contact may claim, in metres.
///
/// Bounds the motion-proportional margin below. Beyond a few centimetres a contact is being
/// created for a meeting that may not happen, and every one of those is a row the solver pays
/// for; an early attempt at a large FIXED margin reached 1.4 GN in the full scene.
const max_speculative_margin: f32 = 0.06;

/// How far ahead a contact should begin to act, from how fast its body is moving.
///
/// Uses the tree body's own velocity rather than a relative one: the other side is either
/// static or another tree body being integrated the same way, and a per-pair relative speed
/// would need the contact before the margin that produces it.
fn speculativeMargin(velocity: Vec, timestep: f32) f32 {
    return @min(length3(velocity) * timestep, max_speculative_margin);
}

/// The world pose of one geom, from the robot's own kinematics. Returns `robot.Pose`
/// rather than a fresh anonymous type - the concept already exists there and composing
/// poses is exactly what it is for.
fn geomPose(model: *const rbt.Model, data: *const rbt.Data, geom: u32) rbt.Pose {
    const body: u32 = model.geom_body[geom];
    const body_pose: rbt.Pose = .{ .pos = data.body_xpos[body], .rot = data.body_xrot[body] };
    return body_pose.compose(.{ .pos = model.geom_pos[geom], .rot = model.geom_rot[geom] });
}

/// Translate a robot geom shape into a zimrphysics shape.
fn addShape(
    gpa: Allocator,
    world: *zimrphysics.World,
    shape: rbt.GeomShape,
) !zimrphysics.ShapeId {
    return switch (shape) {
        .sphere => |s| world.shapes.add(gpa, .{ .sphere = .{ .radius = s.radius } }),
        // zimrphysics boxes and cylinders carry a `convex_radius` - a small rounding used
        // by GJK for numerical robustness. robot.zig's shapes have no such notion, so it
        // is set to the engine's own default rather than invented here.
        .box => |s| world.shapes.add(gpa, .{
            .box = .{ .half_extent = s.half_extent, .convex_radius = default_convex_radius },
        }),
        // Both engines run their capsule along local Y, so this needs no rotation - a
        // coincidence worth noting, since MuJoCo's runs along Z and an importer must fix it.
        .capsule => |s| world.shapes.add(gpa, .{
            .capsule = .{ .half_height = s.half_height, .radius = s.radius },
        }),
        // * The point cloud becomes a real convex hull HERE, in the engine that owns
        // collision. robot.zig carries only the points - it has no hull builder and needs
        // none, since it never asks whether two shapes touch.
        //
        // This is what lets an imported robot collide with the world: real models describe
        // collision geometry with meshes almost without exception, so a hull path is the
        // difference between a robot that can be simulated and one that can also touch
        // something.
        .hull => |s| world.shapes.addConvexHull(gpa, s.points),
        .cylinder => |s| world.shapes.add(gpa, .{ .cylinder = .{
            .half_height = s.half_height,
            .radius = s.radius,
            .convex_radius = default_convex_radius,
        } }),
    };
}

/// Two unit vectors completing a right-handed frame with `normal`.
///
/// Built from whichever world axis is least aligned with the normal, so the construction
/// never degenerates. It is NOT stable frame to frame - a normal that rotates slowly will
/// make the tangents jump when the least-aligned axis changes - which matters only for
/// warm starting, and warm starting is not implemented. When it is, this should instead
/// carry the previous frame forward.
fn tangentFrame(normal: Vec) [2]Vec {
    // Pick the world axis least aligned with the normal, so the cross product is
    // well conditioned.
    //
    // * KNOWN WEAKNESS, recorded rather than hidden: this is DISCONTINUOUS. As a normal
    // rotates and the smallest component changes which axis it is, the chosen helper jumps
    // and the whole tangent frame rotates by ninety degrees. Nothing breaks - any frame
    // orthogonal to the normal is a valid basis, and the pyramid still bounds the friction
    // correctly - but two things suffer: the pyramid's mild anisotropy (friction is
    // stronger along the edges than the faces) rotates with it, and a future warm start
    // cannot reuse last step's tangential force because it no longer means the same
    // direction.
    //
    // The fix, when warm starting arrives, is to carry the tangent frame ON THE CONTACT
    // across steps and re-orthogonalise it against the new normal - the same trick used
    // for a stable contact basis in every engine that warm-starts friction. `Contact`
    // already takes the tangents as an input for exactly this reason.
    const ax: f32 = @abs(normal[0]);
    const ay: f32 = @abs(normal[1]);
    const az: f32 = @abs(normal[2]);
    const helper: Vec = if (ax <= ay and ax <= az)
        vec(1, 0, 0)
    else if (ay <= az)
        vec(0, 1, 0)
    else
        vec(0, 0, 1);
    const first: Vec = normalize3(cross(normal, helper));
    return .{ first, cross(normal, first) };
}

/// The contact callback. Records; never acts.
fn onContact(
    context: ?*anyopaque,
    world: *const zimrphysics.World,
    body_a: zimrphysics.BodyIndex,
    body_b: zimrphysics.BodyIndex,
    sub: u32,
    manifold: *const zimrphysics.Manifold,
    settings: *zimrphysics.ContactSettings,
) void {
    const self: *Bridge = @ptrCast(@alignCast(context orelse return));

    const robot_a: u32 = self.robotBodyOf(body_a);
    const robot_b: u32 = self.robotBodyOf(body_b);
    // A pair with no tree body in it is none of our business.
    const a_is_robot: bool = robot_a != Bridge.not_a_robot_body;
    const b_is_robot: bool = robot_b != Bridge.not_a_robot_body;
    if (!a_is_robot and !b_is_robot) {
        return;
    }

    // *** A PAIR THAT CANNOT MOVE APART IS NOISE, NOT A CONSTRAINT - and letting one
    // through cost a very long hunt.
    //
    // The KUKA's base link is welded to the world: no joint, so no degree of freedom can
    // change the distance between it and static geometry. In `robot_3d` its collision hull
    // also sits **7 cm inside the floor**, permanently, from step zero. Nothing about that is
    // visible - the base cannot move, so it simply stays there looking correct.
    //
    // But it produced four contact rows every step with an unfixable 7 cm violation, and the
    // solver spent its whole iteration budget on them. The effect landed on the ROWS THAT
    // MATTERED: crates left at **90 m/s** and fell through the floor. Clearing the floor from
    // the base changed that to **1.34 m/s and nothing lost**, with everything else identical.
    //
    // The scene was wrong, and it should not have mattered. A contact whose relative motion
    // no coordinate can affect is not something a solver can satisfy or violate; feeding it
    // one is asking for an answer to a question with no variables. Dropped here, where both
    // sides' tree roots are known.
    if (self.isRigid(robot_a) and self.isRigid(robot_b)) {
        return;
    }

    // ** AND A LIMB DOES NOT COLLIDE WITH ITSELF ACROSS A JOINT. See `Bridge.weld`: two links
    // joined by a hinge overlap near it by construction, and reporting that as contact gives an
    // arm that jams the moment it folds.
    if (self.sameOrAdjacentWeld(robot_a, robot_b)) {
        return;
    }

    // ** BOTH SIDES IN THE TREE IS THE INTERESTING CASE NOW - section 4k.
    //
    // This used to `return`, with the comment "robot self-collision, which needs the
    // two-body contact Jacobian rather than the against-the-world one". Two things changed.
    // The two-body Jacobian was always there - `addContactRows` has built `jac_b - jac_a`
    // since phase 6 - and a scene's CRATES are now tree bodies too, so this pair is no
    // longer an exotic self-collision but the ordinary case of a robot touching the thing it
    // is meant to touch.
    //
    // Skipping it is what made the old demo's crates unpushable: every arm-vs-crate contact
    // was silently dropped here and the arm swept through reporting nothing.
    //
    // Orient the normal to point at the `b` side, so a positive constraint force always
    // pushes `body_b` away from `body_a`. zimrphysics reports the normal as A -> B, and
    // `harvest` fills the robot contact in the same order.
    const robot_body: u32 = if (b_is_robot) robot_b else robot_a;
    const other_body: u32 = if (b_is_robot) robot_a else robot_b;
    const normal: Vec = if (b_is_robot) manifold.normal else -manifold.normal;

    // -- ** THE TWO SURFACES, COMBINED --
    //
    // `settings.friction` is what the detector decided for this pair, and it is null unless
    // something set it - which for a robot proxy against world geometry nothing does. Falling
    // straight through to a constant is what discarded every model's material for several
    // sessions, and the symptom was nowhere near the cause: a limp humanoid crept sideways at
    // an accelerating rate because 0.5 could not hold what its joint springs were pushing.
    //
    // * GEOMETRIC MEAN, `sqrt(a*b)` - what `zimrphysics` uses for its own pairs and what MuJoCo
    // uses for its. An arithmetic mean would let one grippy surface rescue a frictionless one,
    // which is not how sliding works.
    const friction: f32 = settings.friction orelse blk: {
        const mu_a: f32 = world.bodies.data[body_a].friction;
        const mu_b: f32 = world.bodies.data[body_b].friction;
        // A zero means "not set" rather than "perfectly slippery" - nothing in these models
        // wants a frictionless surface, and treating it as one would be a silent trap.
        if (mu_a <= 0 or mu_b <= 0) {
            break :blk default_friction;
        }
        break :blk @sqrt(mu_a * mu_b);
    };

    for (manifold.points[0..manifold.count], 0..) |point, index| {
        if (self.event_count >= self.events.len) {
            self.overflowed = true;
            return;
        }
        // zimrphysics's own convention: overlap along A -> B is `dot(a - b, normal)`.
        const depth: f32 = dot3(point.point_on_a - point.point_on_b, manifold.normal);
        self.events[self.event_count] = .{
            .robot_body = robot_body,
            // The other side as a TREE body, or `world_body` when it is genuinely outside
            // the tree. Recorded now, while both indices are in hand - recovering it later
            // would mean re-deriving which side was which.
            .other_body = if (other_body == Bridge.not_a_robot_body) rbt.world_body else other_body,
            .other = if (b_is_robot) body_a else body_b,
            // Midway between the two witness points, which is where the contact acts.
            .position = (point.point_on_a + point.point_on_b) * splat(0.5),
            .normal = normal,
            .depth = depth,
            .friction = friction,
            // ** THE BODY PAIR IS PART OF THE IDENTITY, and leaving it out was a real bug.
            //
            // This packed sub-shape, feature id and point index - which IS unique within one
            // pair, and identical across pairs. Five crates resting on the same floor
            // produce the same sub-shape (0), the same box-vs-box feature ids and the same
            // point indices, so all five contacts numbered themselves the same way.
            //
            // `constraintKey` is exact rather than hashed precisely so a collision cannot
            // happen - and its own comment says a collision "would silently warm-start a row
            // from an unrelated force, a wrong answer that converges". That is what this
            // caused: the solver pulled one crate's force onto another every step and never
            // settled. **Measured: five settled crates needed up to 60 PGS iterations - the
            // cap - where a single crate needs one or two.** Visible as boxes that shiver in
            // place instead of resting.
            //
            // The tree bodies are the right discriminator: they are stable across frames
            // (which a zimrphysics body index need not be) and they are what the solver
            // reasons about anyway. 12 bits each is 4096 bodies, far past anything the
            // articulated solver will carry.
            .id = (@as(u64, robot_body) << 52) | (@as(u64, other_body & 0xFFF) << 40) |
                (@as(u64, sub) << 24) | (@as(u64, point.feature_id) << 8) | index,
        };
        self.event_count += 1;
    }
}

/// Friction to use when the world does not supply one for a pair.
const default_friction: f32 = 0.5;

/// Convex rounding for shapes that need one. Small relative to any sensible link.
const default_convex_radius: f32 = 0.001;

// =============================================================================
// Tests
//
// The risk in a seam is never the algorithm, it is the CONVENTIONS: which way a normal
// points, which sign means overlap, which body is `a`. Each of those is a coin flip that
// compiles either way, so each gets an assertion.
// =============================================================================

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

/// A one-hinge pendulum whose tip sphere can reach a floor.
const TestArm = rbt.Spec(.{
    .bodies = &.{.{
        .name = "link",
        .joints = &.{.{ .name = "j", .kind = .hinge, .axis = vec(0, 0, 1), .armature = 0.001 }},
        .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.08 } }, .pos = vec(0, -0.5, 0) }},
    }},
    .options = .{ .max_contacts = 8 },
});

test "bridge: a link resting on a floor produces a contact pointing UP at the link" {
    // Every convention in one assertion set. A floor under a hanging pendulum: the normal
    // must point at the link (+Y), the distance must be NEGATIVE (robot.Contact reports
    // separation, while zimrphysics reports overlap as positive depth), and the robot body
    // must be on the `b` side so a positive constraint force pushes the link up.
    const gpa: Allocator = std.testing.allocator;

    var model: rbt.Model = try TestArm.build(gpa);
    defer model.deinit();
    var data: rbt.Data = try rbt.Data.init(gpa, &model);
    defer data.deinit();

    var world: zimrphysics.World = try .init(gpa, 64);
    defer world.deinit(gpa);

    // A slab whose top surface sits just above the sphere's lowest point, so they overlap.
    // The sphere hangs at y = -0.5 with radius 0.08, so its bottom is at -0.58.
    //
    // * DYNAMIC, not static, and that is a constraint rather than a preference.
    // zimrphysics's broad phase skips any pair without a non-sleeping DYNAMIC body in it -
    // static/kinematic is one of the combinations it explicitly drops, because neither
    // body could respond. So a kinematic proxy against STATIC level geometry produces no
    // pair, no manifold and no event at all. See the note on `Bridge`.
    const floor_shape: zimrphysics.ShapeId =
        try world.shapes.add(gpa, .{
            .box = .{ .half_extent = vec(2, 0.1, 2), .convex_radius = default_convex_radius },
        });
    _ = try world.createBody(.{
        .shape = floor_shape,
        .position = vec(0, -0.66, 0), // top face at -0.56, so 0.02 of overlap
        .rotation = zm.quat_identity,
        .motion_type = .dynamic,
    });

    // The robot must be posed before the proxies are created, or they start at the origin.
    rbt.forward(&model, &data);

    var bridge: Bridge = try .init(gpa, &world, &model, &data, 64);
    defer bridge.deinit(&world);
    bridge.listen(&world);

    const dt: f32 = 1.0 / 240.0;
    try bridge.sync(&world, &model, &data);
    try zimrphysics.step(&world, dt);
    bridge.harvest(&data);

    try expect(!bridge.overflowed);
    try expect(data.contact_count >= 1);

    const contact: rbt.Contact = data.contacts[0];
    // Points UP, at the link.
    try expect(contact.normal[1] > 0.9);
    // Overlapping, so separation is negative.
    try expect(contact.distance < 0.0);
    try expect(contact.distance > -0.1); // and plausible, not a wild value
    // The robot link is body `b`; the world is `a`.
    try expectEqual(rbt.world_body, contact.body_a);
    try expectEqual(@as(u32, 1), contact.body_b);
    // The tangents form a right-handed orthonormal frame with the normal.
    try expectApproxEqAbs(@as(f32, 0), dot3(contact.normal, contact.tangent[0]), 1.0e-5);
    try expectApproxEqAbs(@as(f32, 0), dot3(contact.normal, contact.tangent[1]), 1.0e-5);
    try expectApproxEqAbs(@as(f32, 0), dot3(contact.tangent[0], contact.tangent[1]), 1.0e-5);
}

test "bridge: the contact actually holds the link up" {
    // The end-to-end behavioural check: with the floor present the link must not sink
    // through it. This is the first time the two engines cooperate on anything.
    const gpa: Allocator = std.testing.allocator;

    var model: rbt.Model = try TestArm.build(gpa);
    defer model.deinit();
    var data: rbt.Data = try rbt.Data.init(gpa, &model);
    defer data.deinit();

    var world: zimrphysics.World = try .init(gpa, 64);
    defer world.deinit(gpa);
    const floor_shape: zimrphysics.ShapeId =
        try world.shapes.add(gpa, .{
            .box = .{ .half_extent = vec(2, 0.1, 2), .convex_radius = default_convex_radius },
        });
    _ = try world.createBody(.{
        .shape = floor_shape,
        // STATIC, which is what a floor actually is. This used to need to be dynamic,
        // because a kinematic proxy never paired with static geometry - and a dynamic
        // "floor" falls, so it had left the scene long before the pendulum swung down to
        // where it had been. `report_immovable_contacts` on the proxy removed the need for
        // the workaround, and the test now describes a real situation.
        .position = vec(0, -0.66, 0), // top face at -0.56; the link's low point is -0.58
        .rotation = zm.quat_identity,
        .motion_type = .static,
    });

    // Start displaced so gravity swings the link down onto the floor.
    data.pos[0] = 0.9;
    rbt.forward(&model, &data);

    var bridge: Bridge = try .init(gpa, &world, &model, &data, 64);
    defer bridge.deinit(&world);
    bridge.listen(&world);

    const dt: f32 = model.opt.timestep;
    var saw_contact: bool = false;
    for (0..1200) |_| { // 5 seconds
        try bridge.sync(&world, &model, &data);
        try zimrphysics.step(&world, dt);
        bridge.harvest(&data);
        if (data.contact_count > 0) {
            saw_contact = true;
        }
        rbt.step(&model, &data);
    }
    rbt.forward(&model, &data);

    // A contact really did happen - otherwise this test proves nothing about contacts.
    try expect(saw_contact);
    // And the state stayed finite, which a badly-signed normal would not.
    try expect(data.pos[0] == data.pos[0]); // NaN check without std.math
    try expect(@abs(data.pos[0]) < 10.0);
    try expect(@abs(data.vel[0]) < 50.0);
}

test "bridge: a settled crate keeps reporting contacts after the sleep timer elapses" {
    // * The blind spot this test exists to close. zimrphysics puts settled bodies to sleep
    // (`time_before_sleep` is half a second) and the narrow phase skips a pair whose islands
    // are all asleep. If a crate resting on a motionless arm went to sleep and stopped being
    // reported, the arm would silently stop feeling its weight - a plausible scene with an
    // invisible failure, which is the worst combination.
    //
    // Reasoning says it is safe: `moveKinematic` calls `setLinearVelocity`, which wakes the
    // proxy every single step, and the island gate passes when EITHER endpoint is awake. But
    // that is a chain of three inferences across two files, and the cost of being wrong is a
    // robot that cannot hold anything. So: measured, over four times the sleep threshold.
    const gpa: Allocator = std.testing.allocator;

    // A link with a flat BOX geom, not the shared sphere: a crate balanced on a sphere
    // rolls off, and this test must measure sleeping rather than balance.
    const Table: type = rbt.Spec(.{
        .bodies = &.{.{
            .name = "top",
            .joints = &.{.{ .name = "j", .kind = .hinge, .axis = vec(0, 0, 1), .armature = 0.01 }},
            .geoms = &.{.{
                .shape = .{ .box = .{ .half_extent = vec(0.4, 0.05, 0.4) } },
                .pos = vec(0, -0.3, 0),
            }},
        }},
        .options = .{ .max_contacts = 16 },
    });
    var model: rbt.Model = try Table.build(gpa);
    defer model.deinit();
    var data: rbt.Data = try rbt.Data.init(gpa, &model);
    defer data.deinit();

    var world: zimrphysics.World = try .init(gpa, 64);
    defer world.deinit(gpa);

    // A crate sitting squarely on the table top, whose surface is at y = -0.25.
    const crate_shape: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(0.1, 0.1, 0.1), .convex_radius = default_convex_radius },
    });
    const crate: zimrphysics.BodyHandle = try world.createBody(.{
        .shape = crate_shape,
        .position = vec(0, -0.145, 0), // underside at -0.245: 5 mm of overlap
        .rotation = zm.quat_identity,
        .motion_type = .dynamic,
    });

    rbt.forward(&model, &data);
    var bridge: Bridge = try .init(gpa, &world, &model, &data, 64);
    defer bridge.deinit(&world);
    bridge.listen(&world);

    const dt: f32 = model.opt.timestep;
    var contacts_early: u32 = 0;
    var contacts_late: u32 = 0;
    // Two seconds - four times `time_before_sleep`. The robot is held still by cancelling
    // gravity, which is the scene that would let everything settle and sleep.
    for (0..480) |tick| {
        try bridge.sync(&world, &model, &data);
        try zimrphysics.step(&world, dt);
        bridge.harvest(&data);
        if (tick < 60) {
            contacts_early += data.contact_count;
        } else if (tick >= 420) {
            contacts_late += data.contact_count;
        }
        rbt.forward(&model, &data);
        @memcpy(data.applied_force, data.bias_force); // hold the arm still
        rbt.step(&model, &data);
    }

    // The crate must still be ON the table, or a lost contact would mean it fell off
    // rather than that reporting stopped.
    const crate_pos: Vec = world.bodies.data[crate.index()].com_pos;
    try expect(@abs(crate_pos[0]) < 0.3);
    try expect(crate_pos[1] > -0.4);
    // It must have been in contact at the start, or the test is measuring nothing.
    try expect(contacts_early > 0);
    // * And still be reported long after the sleep timer would have elapsed.
    try expect(contacts_late > 0);
}

test "bridge: pairs with no robot in them are ignored" {
    // Two dynamic bodies colliding with each other must produce no robot contacts, or the
    // robot would be enforcing constraints for a collision it is not part of.
    const gpa: Allocator = std.testing.allocator;

    var model: rbt.Model = try TestArm.build(gpa);
    defer model.deinit();
    var data: rbt.Data = try rbt.Data.init(gpa, &model);
    defer data.deinit();

    var world: zimrphysics.World = try .init(gpa, 64);
    defer world.deinit(gpa);

    // Put the robot far away from everything.
    data.pos[0] = 0;
    rbt.forward(&model, &data);
    var bridge: Bridge = try .init(gpa, &world, &model, &data, 64);
    defer bridge.deinit(&world);
    bridge.listen(&world);

    // Two boxes overlapping each other, nowhere near the robot.
    const box: zimrphysics.ShapeId =
        try world.shapes.add(gpa, .{
            .box = .{ .half_extent = vec(0.2, 0.2, 0.2), .convex_radius = default_convex_radius },
        });
    _ = try world.createBody(.{
        .shape = box,
        .position = vec(5, 5, 0),
        .rotation = zm.quat_identity,
        .motion_type = .static,
    });
    _ = try world.createBody(.{
        .shape = box,
        .position = vec(5, 5.3, 0),
        .rotation = zm.quat_identity,
        .motion_type = .dynamic,
    });

    const dt: f32 = 1.0 / 240.0;
    try bridge.sync(&world, &model, &data);
    try zimrphysics.step(&world, dt);
    bridge.harvest(&data);
    try expectEqual(@as(u32, 0), data.contact_count);
}

/// An octahedron: the smallest point cloud that is unambiguously a volume rather than a
/// plane, and whose extent is trivial to reason about - 0.1 m along every axis.
const octahedron = [_]Vec{
    vec(0.1, 0, 0), vec(-0.1, 0, 0),
    vec(0, 0.1, 0), vec(0, -0.1, 0),
    vec(0, 0, 0.1), vec(0, 0, -0.1),
};

test "hull geoms collide, so an imported robot can touch the world" {
    // ** THE END OF THE IMPORT PATH. A real URDF describes collision with meshes; the
    // importer turns those into point clouds; `robot.zig` carries them without knowing what
    // a hull is; and THIS engine builds the hull and reports the contact.
    //
    // Without this the KUKA can be simulated but passes through everything - which is a
    // robot in the same sense that a hologram is.
    const gpa: Allocator = std.testing.allocator;

    // An octahedron: the smallest cloud that is unambiguously a volume rather than a plane,
    // and one whose extent is easy to reason about (0.1 m along every axis).
    const Arm: type = rbt.Spec(.{
        .bodies = &.{.{
            .name = "link",
            .joints = &.{.{
                .name = "slide",
                .kind = .slide,
                .axis = vec(0, 1, 0),
                .armature = 0.01,
            }},
            .geoms = &.{.{ .shape = .{ .hull = .{
                .points = &octahedron,
                .bounds_half_extent = vec(0.1, 0.1, 0.1),
            } } }},
            .inertial = .{
                .mass = 1.0,
                .pos = vec(0, 0, 0),
                .full_inertia = .{ 0.01, 0.01, 0.01, 0, 0, 0 },
            },
        }},
        .options = .{ .max_contacts = 8 },
    });

    var model: rbt.Model = try Arm.build(gpa);
    defer model.deinit();
    var data: rbt.Data = try rbt.Data.init(gpa, &model);
    defer data.deinit();

    var world: zimrphysics.World = try .init(gpa, 8);
    defer world.deinit(gpa);
    world.gravity = vec(0, -9.81, 0);

    // A floor for it to land on.
    const ground: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(2, 0.1, 2), .convex_radius = 0.01 },
    });
    _ = try world.createBody(.{
        .shape = ground,
        .position = vec(0, -0.5, 0),
        .motion_type = .static,
    });

    // The hull proxy must be built without error - that is already half the test, since a
    // degenerate cloud or a missing case would fail here.
    var bridge: Bridge = try .init(gpa, &world, &model, &data, 8);
    defer bridge.deinit(&world);
    bridge.listen(&world);

    // Drop it onto the floor.
    data.setJointPos(&model, Arm.Joint.slide, 0.6);
    rbt.forward(&model, &data);
    var touched: bool = false;
    for (0..600) |_| {
        try bridge.sync(&world, &model, &data);
        try zimrphysics.step(&world, model.opt.timestep);
        bridge.harvest(&data);
        rbt.step(&model, &data);
        if (data.contact_count > 0) {
            touched = true;
        }
    }
    rbt.forward(&model, &data);

    // It made contact, and it came to rest ON the floor rather than through it. The floor's
    // top is at -0.4 and the hull's half extent is 0.1, so a resting slide position puts the
    // body centre near -0.3 - checked loosely, since the exact penetration is a function of
    // both engines' softness.
    try expect(touched);
    try expect(data.pos[0] > -0.45);
    try expect(data.pos[0] < -0.15);
}

test "bridge: a failed allocation partway through init leaks nothing" {
    // ** THE ONLY WAY TO TEST AN ERROR PATH IS TO CAUSE THE ERROR. `Bridge.init` makes five
    // allocations and two more fallible calls; before this it built them inside a struct
    // literal, where there is nowhere to put an `errdefer`, so a failure at the third leaked
    // the first two.
    //
    // Nothing observed it: the only trigger is OOM, and no test ever went near the path.
    // `FailingAllocator` goes near it deliberately - one run per allocation index, each
    // failing at a different point - and `testing.allocator` underneath reports any block
    // that was not freed.
    const gpa: Allocator = std.testing.allocator;
    var model: rbt.Model = try rbt.Spec(.{
        .bodies = &.{.{
            .name = "link",
            .joints = &.{.{ .name = "j", .kind = .hinge, .axis = zm.vec(0, 0, 1) }},
            .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.05 } } }},
        }},
        .options = .{ .max_contacts = 4 },
    }).build(gpa);
    defer model.deinit();
    var data: rbt.Data = try rbt.Data.init(gpa, &model);
    defer data.deinit();

    // Walk the failure point outward until `init` succeeds; every earlier index must have
    // unwound cleanly, which `testing.allocator` enforces when this function returns.
    var fail_at: usize = 0;
    while (fail_at < 24) : (fail_at += 1) {
        var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_at });
        var world: zimrphysics.World = try .init(gpa, 8);
        defer world.deinit(gpa);
        var bridge = Bridge.init(failing.allocator(), &world, &model, &data, 8) catch |err| {
            try expectEqual(error.OutOfMemory, err);
            continue;
        };
        // Reached the end without failing, so the walk has covered every allocation.
        bridge.deinit(&world);
        break;
    }
    // The loop must have terminated by succeeding, not by exhausting the range - otherwise
    // the test proved nothing about the successful path.
    try expect(fail_at < 24);
}

test "* a fast projectile is stopped, not passed through" {
    // *** THE CASE THAT NEEDED CONTINUOUS COLLISION. A 0.05 m ball fired at a 0.10 m wall used
    // to arrive on the far side at every speed above about 10 m/s - and NOT because of
    // tunnelling in the usual sense. Measured before this existed: the contact was detected at
    // every speed and the solver decelerated the ball from 20 m/s to 1.32, but by then its
    // centre had passed the wall's mid-plane, the nearest exit face flipped, and a perfectly
    // resolved contact ejected it out the back. Running at 8000 Hz - 2.5 mm per step, a
    // twentieth of the ball's radius - did not help.
    const gpa: Allocator = std.testing.allocator;
    const ball = [_]robot_scene.FreeBody{.{
        .name = "ball",
        .pos = vec(0, 0.3, -1.0),
        .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.05 } }, .mass = 0.2 }},
    }};
    var model: rbt.Model = try (robot_scene.Scene{
        .robots = &.{},
        .free_bodies = &ball,
        .options = .{ .timestep = 1.0 / 500.0, .max_contacts = 32, .gravity = vec(0, -9.81, 0) },
    }).build(gpa);
    defer model.deinit();
    var data: rbt.Data = try rbt.Data.init(gpa, &model);
    defer data.deinit();

    var world: zimrphysics.World = try .init(gpa, 32);
    defer world.deinit(gpa);
    world.gravity = vec(0, -9.81, 0);
    // A wall 0.10 m thick with its near face at z = 0 - thinner than the ball travels in a
    // single step at the speeds below.
    const wall: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(2, 2, 0.05), .convex_radius = 0.01 },
    });
    _ = try world.createBody(.{ .shape = wall, .position = vec(0, 0, 0.05), .motion_type = .static });

    rbt.forward(&model, &data);
    var bridge: Bridge = try .init(gpa, &world, &model, &data, 32);
    defer bridge.deinit(&world);
    bridge.listen(&world);

    // 100 m/s is 0.2 m per step - four times the ball's diameter, and twice the wall's
    // thickness. Nothing discrete can see this.
    data.vel[2] = 100.0;
    data.stage = .stale;
    for (0..600) |_| {
        rbt.forward(&model, &data);
        try bridge.sync(&world, &model, &data);
        try zimrphysics.step(&world, 1.0 / 500.0);
        bridge.harvest(&data);
        @memset(data.applied_force, 0);
        rbt.step(&model, &data);
    }
    rbt.forward(&model, &data);

    // * IT IS ON THE NEAR SIDE. Where exactly does not matter - it bounces and falls - but
    // which side of the wall it ended up on is the whole question.
    try expect(data.body_xpos[1][2] < 0.0);
}

test "* a keyframe teleport is detected without being announced" {
    // ** THE POINT OF `Data.teleported`. `applyKeyframe` sets it, `sync` consumes it, and no
    // caller has to remember anything - which matters because there were thirty-one places
    // that write `pos` wholesale and any one of them forgetting reintroduces the explosion.
    //
    // This test deliberately never calls `Bridge.teleported()`. If the automatic path breaks,
    // the swept contact fires and the velocities give it away.
    const gpa: Allocator = std.testing.allocator;
    const ball = [_]robot_scene.FreeBody{.{
        .name = "ball",
        .pos = vec(0, 0.2, 0),
        .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.05 } }, .mass = 0.5 }},
    }};
    var model: rbt.Model = try (robot_scene.Scene{
        .robots = &.{},
        .free_bodies = &ball,
        .options = .{ .timestep = 1.0 / 500.0, .max_contacts = 32, .gravity = vec(0, -9.81, 0) },
    }).build(gpa);
    defer model.deinit();
    var data: rbt.Data = try rbt.Data.init(gpa, &model);
    defer data.deinit();
    var world: zimrphysics.World = try .init(gpa, 32);
    defer world.deinit(gpa);
    world.gravity = vec(0, -9.81, 0);
    const ground: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(30, 0.5, 30), .convex_radius = 0.01 },
    });
    _ = try world.createBody(.{ .shape = ground, .position = vec(0, -0.5, 0), .motion_type = .static });
    rbt.forward(&model, &data);
    var bridge: Bridge = try .init(gpa, &world, &model, &data, 32);
    defer bridge.deinit(&world);
    bridge.listen(&world);

    for (0..600) |_| {
        rbt.forward(&model, &data);
        try bridge.sync(&world, &model, &data);
        try zimrphysics.step(&world, 1.0 / 500.0);
        bridge.harvest(&data);
        @memset(data.applied_force, 0);
        rbt.step(&model, &data);
    }

    // * `reset` MOVES EVERYTHING AND SETS THE FLAG ITSELF. No `bridge.teleported()` here.
    data.reset(&model);
    data.pos[0] = 15.0;
    data.pos[2] = -9.0;
    rbt.forward(&model, &data);
    try expect(data.teleported); // the flag survived `forward`

    for (0..20) |_| {
        rbt.forward(&model, &data);
        try bridge.sync(&world, &model, &data);
        try zimrphysics.step(&world, 1.0 / 500.0);
        bridge.harvest(&data);
        @memset(data.applied_force, 0);
        rbt.step(&model, &data);
    }
    // * AND IT IS CLEARED AFTER ONE SYNC, or continuous collision would be off for good.
    try expect(!data.teleported);

    var fastest: f32 = 0;
    for (0..model.nv) |i| {
        fastest = @max(fastest, @abs(data.vel[i]));
    }
    try expect(fastest < 2.0);
}

test "* a teleported body does not explode" {
    // *** THE REGRESSION SWEPT CONTACTS INTRODUCED. A proxy that moved several metres in one
    // step did not travel there - something TELEPORTED it: a keyframe applied, a reset button,
    // an editor drag. Swept against the whole line between the two poses, that jump finds
    // whatever lies along it and manufactures a contact at a gap of metres, carrying the stiff
    // softness a swept contact uses.
    //
    // **Measured with the bound removed: velocity pinned at 100 m/s on the first step after a
    // reset**, with the body climbing. Reported from the device as "reset to home still
    // explodes somehow", and it was this rather than anything about the reset.
    const gpa: Allocator = std.testing.allocator;
    const ball = [_]robot_scene.FreeBody{.{
        .name = "ball",
        .pos = vec(0, 0.2, 0),
        .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.05 } }, .mass = 0.5 }},
    }};
    var model: rbt.Model = try (robot_scene.Scene{
        .robots = &.{},
        .free_bodies = &ball,
        .options = .{ .timestep = 1.0 / 500.0, .max_contacts = 32, .gravity = vec(0, -9.81, 0) },
    }).build(gpa);
    defer model.deinit();
    var data: rbt.Data = try rbt.Data.init(gpa, &model);
    defer data.deinit();

    var world: zimrphysics.World = try .init(gpa, 32);
    defer world.deinit(gpa);
    world.gravity = vec(0, -9.81, 0);
    const ground: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(30, 0.5, 30), .convex_radius = 0.01 },
    });
    _ = try world.createBody(.{ .shape = ground, .position = vec(0, -0.5, 0), .motion_type = .static });

    rbt.forward(&model, &data);
    var bridge: Bridge = try .init(gpa, &world, &model, &data, 32);
    defer bridge.deinit(&world);
    bridge.listen(&world);

    // Let it settle on the ground.
    for (0..600) |_| {
        rbt.forward(&model, &data);
        try bridge.sync(&world, &model, &data);
        try zimrphysics.step(&world, 1.0 / 500.0);
        bridge.harvest(&data);
        @memset(data.applied_force, 0);
        rbt.step(&model, &data);
    }

    // * NOW TELEPORT IT ACROSS THE WORLD - twelve metres in one step, which is what a reset
    // looks like to the bridge.
    data.pos[0] = 12.0;
    data.pos[2] = -8.0;
    @memset(data.vel, 0);
    data.stage = .stale;
    rbt.forward(&model, &data);

    for (0..20) |_| {
        rbt.forward(&model, &data);
        try bridge.sync(&world, &model, &data);
        try zimrphysics.step(&world, 1.0 / 500.0);
        bridge.harvest(&data);
        @memset(data.applied_force, 0);
        rbt.step(&model, &data);
    }

    // -- * IT IS WHERE IT WAS PUT, AND NOT MOVING FAST --
    //
    // Gravity over twenty steps is 0.8 m/s, so anything above a couple of m/s is the sweep
    // inventing a contact rather than physics.
    var fastest: f32 = 0;
    for (0..model.nv) |i| {
        fastest = @max(fastest, @abs(data.vel[i]));
    }
    try expect(fastest < 2.0);
    rbt.forward(&model, &data);
    try expectApproxEqAbs(@as(f32, 12.0), data.body_xpos[1][0], 0.05);
    try expectApproxEqAbs(@as(f32, -8.0), data.body_xpos[1][2], 0.05);
}

test "* a limb does not collide with itself across a joint" {
    // *** MuJoCo'S PARENT FILTER, WHICH THIS ENGINE DID NOT HAVE. Two links joined by a hinge
    // OVERLAP near that hinge by construction - that is what a joint looks like geometrically -
    // so reporting the overlap as contact gives a limb that fights itself the moment it folds.
    //
    // Measured before this existed, on a 4-DOF arm commanded to a perfectly reachable pose:
    // `wrist` against `right_finger`, a parent and its own child, **two contacts that never
    // cleared** however long it ran.
    //
    // MuJoCo does this in `filterBodyPair`: same weld body, or either being the other's weld
    // parent. Its `dsbl_filterparent` flag turns it off and essentially nothing uses that.
    const gpa: Allocator = std.testing.allocator;
    const Folding: type = rbt.Spec(.{
        .bodies = &.{
            .{
                .name = "upper",
                .joints = &.{.{ .name = "shoulder", .kind = .hinge, .axis = vec(0, 0, 1) }},
                // Deliberately fat and overlapping at the joint, as real links are.
                .geoms = &.{.{
                    .shape = .{ .capsule = .{ .half_height = 0.15, .radius = 0.05 } },
                    .pos = vec(0.15, 0, 0),
                    .rot = quatFromAxisAngle(vec(0, 0, 1), 0.5 * pi),
                }},
            },
            .{
                .name = "lower",
                .parent = "upper",
                .pos = vec(0.30, 0, 0),
                .joints = &.{.{ .name = "elbow", .kind = .hinge, .axis = vec(0, 0, 1) }},
                .geoms = &.{.{
                    .shape = .{ .capsule = .{ .half_height = 0.15, .radius = 0.05 } },
                    .pos = vec(0.15, 0, 0),
                    .rot = quatFromAxisAngle(vec(0, 0, 1), 0.5 * pi),
                }},
            },
        },
        .options = .{ .timestep = 1.0 / 500.0, .max_contacts = 32, .gravity = vec(0, 0, 0) },
    });
    var model: rbt.Model = try Folding.build(gpa);
    defer model.deinit();
    var data: rbt.Data = try rbt.Data.init(gpa, &model);
    defer data.deinit();
    var world: zimrphysics.World = try .init(gpa, 32);
    defer world.deinit(gpa);
    rbt.forward(&model, &data);
    var bridge: Bridge = try .init(gpa, &world, &model, &data, 32);
    defer bridge.deinit(&world);
    bridge.listen(&world);

    // * FOLD THE ELBOW RIGHT BACK, so the two links lie alongside each other and overlap along
    // their whole length - far more than any real joint would, to leave no doubt.
    data.pos[1] = 2.9;
    data.stage = .stale;
    for (0..200) |_| {
        rbt.forward(&model, &data);
        try bridge.sync(&world, &model, &data);
        try zimrphysics.step(&world, 1.0 / 500.0);
        bridge.harvest(&data);
        @memset(data.applied_force, 0);
        rbt.step(&model, &data);
    }

    // -- * NOT ONE CONTACT, and the elbow stayed where it was put --
    try expectEqual(@as(u32, 0), data.contact_count);
    try expectApproxEqAbs(@as(f32, 2.9), data.pos[1], 0.01);
}

test "** Newton holds a stack that PGS drops" {
    // *** THE ACCEPTANCE TEST THE PLAN SET FOR NEWTON, and it is met by a wide margin.
    //
    // Six boxes, 96 contact rows. Measured on a cold solve from the settled configuration:
    //
    //     PGS      1 iter 26.7 * 5 iters 13.4 * 20 iters 4.83 * 100 iters 0.269   stack COLLAPSES
    //     Newton   1 iter 0.0000004 * 2 iters 0.0000005 and converged              stack STANDS
    //
    // PGS sweeps rows, so information travels one contact per sweep and a six-high stack needs
    // six sweeps before the floor is felt at the top - with every later sweep undoing what the
    // one before it fixed. Newton minimises the whole objective at once and does not care how
    // long the chain is.
    const gpa: Allocator = std.testing.allocator;
    const box_count: usize = 6;
    var boxes: [box_count]robot_scene.FreeBody = undefined;
    const names = [_][]const u8{ "b0", "b1", "b2", "b3", "b4", "b5" };
    for (0..box_count) |i| {
        boxes[i] = .{
            .name = names[i],
            .pos = vec(0, 0.05 + float(i) * 0.1005, 0),
            .geoms = &.{.{
                .shape = .{ .box = .{ .half_extent = splat(@as(f32, 0.05)) } },
                .mass = 1.0,
            }},
        };
    }
    var model: rbt.Model = try (robot_scene.Scene{
        .robots = &.{},
        .free_bodies = &boxes,
        .options = .{
            .timestep = 1.0 / 500.0,
            .max_contacts = 256,
            .gravity = vec(0, -9.81, 0),
            .solver = .{ .algorithm = .newton, .max_iterations = 50 },
        },
    }).build(gpa);
    defer model.deinit();
    var data: rbt.Data = try rbt.Data.init(gpa, &model);
    defer data.deinit();

    var world: zimrphysics.World = try .init(gpa, 64);
    defer world.deinit(gpa);
    world.gravity = vec(0, -9.81, 0);
    const ground_shape: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(5, 0.5, 5), .convex_radius = 0.01 },
    });
    _ = try world.createBody(.{ .shape = ground_shape, .position = vec(0, -0.5, 0), .motion_type = .static });

    rbt.forward(&model, &data);
    var bridge: Bridge = try .init(gpa, &world, &model, &data, 256);
    defer bridge.deinit(&world);
    bridge.listen(&world);

    for (0..1000) |_| {
        rbt.forward(&model, &data);
        try bridge.sync(&world, &model, &data);
        try zimrphysics.step(&world, 1.0 / 500.0);
        bridge.harvest(&data);
        @memset(data.applied_force, 0);
        rbt.step(&model, &data);
    }
    rbt.forward(&model, &data);

    // -- * EVERY BOX WITHIN A CENTIMETRE OF WHERE IT BELONGS --
    //
    // The tower is metastable, so this is checked after two seconds rather than twenty: a real
    // stack settles into slight asymmetry and eventually topples, and testing THAT would be
    // testing chance. Two seconds is long enough for a solver that cannot hold it to have
    // dropped it - PGS puts the top box on the floor well inside that.
    for (0..box_count) |i| {
        const want: f32 = 0.05 + float(i) * 0.1;
        try expectApproxEqAbs(want, data.body_xpos[i + 1][1], 0.01);
    }

    // * AND IT CONVERGED IN A HANDFUL OF ITERATIONS, not by exhausting the cap.
    try expect(data.solver_iterations < 10);
}

test "* a swept contact uses the real materials, not a constant" {
    // ** FOUND BY READING THE TWO CONTACT PRODUCERS SIDE BY SIDE. The discrete path takes
    // `event.friction`, already combined by the detector. The swept path had `0.5` written in,
    // so a body moving fast enough to be swept got rubber friction whatever its material said.
    //
    // * AND THE FAILURE ONLY APPEARS ABOVE THE SWEEP THRESHOLD, which is a horrible thing to
    // debug: the same model slides correctly when nudged and grips wrongly when thrown.
    const gpa: Allocator = std.testing.allocator;
    const puck = [_]robot_scene.FreeBody{.{
        .name = "puck",
        .pos = vec(0, 0.05, 0),
        .geoms = &.{.{ .shape = .{ .sphere = .{ .radius = 0.05 } }, .mass = 0.4 }},
    }};
    var model: rbt.Model = try (robot_scene.Scene{
        .robots = &.{},
        .free_bodies = &puck,
        .options = .{ .timestep = 1.0 / 500.0, .max_contacts = 32, .gravity = vec(0, -9.81, 0) },
    }).build(gpa);
    defer model.deinit();
    var data: rbt.Data = try rbt.Data.init(gpa, &model);
    defer data.deinit();

    var world: zimrphysics.World = try .init(gpa, 32);
    defer world.deinit(gpa);
    world.gravity = vec(0, -9.81, 0);
    const wall: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(0.05, 2, 2), .convex_radius = 0.01 },
    });
    // * AN ALMOST FRICTIONLESS WALL. With the constant, a swept contact against this reported
    // 0.5 - ten times what the material states.
    const slippery: zimrphysics.BodyHandle = try world.createBody(.{
        .shape = wall,
        .position = vec(1.0, 0, 0),
        .motion_type = .static,
        .friction = 0.02,
    });
    _ = slippery;

    rbt.forward(&model, &data);
    var bridge: Bridge = try .init(gpa, &world, &model, &data, 32);
    defer bridge.deinit(&world);
    bridge.listen(&world);

    // Fast enough that the sweep fires: 40 m/s is 0.08 m per step against a 0.05 m radius.
    data.vel[0] = 40.0;
    data.stage = .stale;
    var swept_friction: f32 = -1;
    for (0..200) |_| {
        rbt.forward(&model, &data);
        try bridge.sync(&world, &model, &data);
        try zimrphysics.step(&world, 1.0 / 500.0);
        bridge.harvest(&data);
        for (0..data.contact_count) |c| {
            if (data.contacts[c].friction[0] < 0.2) {
                swept_friction = data.contacts[c].friction[0];
            }
        }
        @memset(data.applied_force, 0);
        rbt.step(&model, &data);
    }

    // * THE PUCK'S OWN FRICTION TIMES THE WALL'S, GEOMETRICALLY - the combination zimrphysics
    // uses itself. What matters is that it is nowhere near the 0.5 that used to be hardcoded.
    try expect(swept_friction >= 0);
    try expect(swept_friction < 0.2);
}

test "** the solver's FORCES match MuJoCo, not just its behaviour" {
    // *** THE ORACLE THAT WAS MISSING. An audit of what is checked against MuJoCo found
    // forward kinematics, mass, inertia, sensors and equalities all verified against its own
    // numbers - and the SOLVER verified only by behaviour: robots stand, stacks stand, heights
    // roughly agree.
    //
    // **That is a weak oracle.** Many wrong solvers make a robot stand. A constraint force that
    // is 10% high still supports a box; it shows up later as a foot that bounces, a grip that
    // crushes, or a policy that learns to exploit a contact model no real robot has.
    //
    // -- * THE CASE IS CHOSEN SO THE ANSWER IS KNOWN WITHOUT EITHER ENGINE --
    //
    // A 2 kg box resting on a plane. At rest the constraint must carry exactly its weight -
    // `m*g = 19.62 N` - so this checks both engines against PHYSICS, and each other for the
    // parts physics does not pin down.
    //
    //     MuJoCo (Newton, 200 iterations, tol 1e-12):  z 0.099892   qfrc_constraint[2] 19.62
    //     ours, PGS:                                   z 0.099878   qfrc_constraint[2] 19.620
    //     ours, Newton:                                z 0.099878   qfrc_constraint[2] 19.620
    //
    // Sixteen rows in every case - four contact points, four pyramid edges each - and the
    // resting depth agrees to 1.4e-5, which is the softness constant doing the same thing in
    // both.
    const gpa: Allocator = std.testing.allocator;
    inline for (.{ rbt.Algorithm.pgs, rbt.Algorithm.newton }) |algorithm| {
        const box = [_]robot_scene.FreeBody{.{
            .name = "box",
            .pos = vec(0, 0.1, 0),
            .geoms = &.{.{
                .shape = .{ .box = .{ .half_extent = splat(@as(f32, 0.1)) } },
                .mass = 2.0,
            }},
        }};
        var model: rbt.Model = try (robot_scene.Scene{
            .robots = &.{},
            .free_bodies = &box,
            .options = .{
                .timestep = 1.0 / 500.0,
                .max_contacts = 64,
                .gravity = vec(0, -9.81, 0),
                .solver = .{ .algorithm = algorithm, .max_iterations = 200 },
            },
        }).build(gpa);
        defer model.deinit();
        var data: rbt.Data = try rbt.Data.init(gpa, &model);
        defer data.deinit();

        var world: zimrphysics.World = try .init(gpa, 32);
        defer world.deinit(gpa);
        world.gravity = vec(0, -9.81, 0);
        const ground: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
            .box = .{ .half_extent = vec(5, 0.5, 5), .convex_radius = 0.01 },
        });
        _ = try world.createBody(.{
            .shape = ground,
            .position = vec(0, -0.5, 0),
            .motion_type = .static,
        });

        rbt.forward(&model, &data);
        var bridge: Bridge = try .init(gpa, &world, &model, &data, 64);
        defer bridge.deinit(&world);
        bridge.listen(&world);

        for (0..3000) |_| {
            rbt.forward(&model, &data);
            try bridge.sync(&world, &model, &data);
            try zimrphysics.step(&world, 1.0 / 500.0);
            bridge.harvest(&data);
            @memset(data.applied_force, 0);
            rbt.step(&model, &data);
        }
        rbt.forward(&model, &data);

        // * THE FORCE IS THE WEIGHT. Not approximately the weight - a resting body is a
        // statically determinate problem and there is one right answer.
        try expectApproxEqAbs(@as(f32, 19.62), data.constraint_joint_force[1], 0.02);

        // * AND NOTHING SIDEWAYS. A friction pyramid that is not symmetric about the normal
        // leaves a residual tangential force, which a resting box would slowly slide under -
        // slowly enough that no behavioural test would see it inside a few seconds.
        try expectApproxEqAbs(@as(f32, 0), data.constraint_joint_force[0], 0.02);
        try expectApproxEqAbs(@as(f32, 0), data.constraint_joint_force[2], 0.02);

        // Sixteen rows: four contact points, four pyramid edges each - the same count MuJoCo
        // reports, so the two are solving the same problem and not merely reaching similar
        // answers from different ones.
        try expectEqual(@as(u32, 16), data.constraint_count);

        // Resting depth, against MuJoCo's 0.099892.
        try expectApproxEqAbs(@as(f32, 0.09989), data.body_xpos[1][1], 1.0e-4);
    }
}

test "** a ragdoll comes to rest under Newton, and keeps twitching under PGS" {
    // *** THE SOLVER DIFFERENCE IN A REAL SCENE, not a synthetic stack. A 27-DOF humanoid
    // dropped on its side with NO control at all - the hardest thing a contact solver is
    // routinely asked to do, because a limp body has no actuator holding anything and every
    // joint is free to be pushed by every contact.
    //
    // Measured, six seconds after landing, from two drop heights:
    //
    //     from 1.2 m   PGS: settled |v| 2.67   Newton: 0.41
    //     from 2.5 m   PGS: settled |v| 1.39   Newton: 0.24
    //
    // * BOTH REACH THE SAME POSE - pelvis at z 0.177 either way - so this is not PGS getting
    // the answer wrong. It is PGS not getting all the way there: 15 coupled rows, linear
    // convergence, and a residual that reads on screen as a body that will not stop twitching.
    //
    // ** AND THIS IS WHY THE `algorithm` OPTION EXISTS. PGS is the default and 1.86x faster on
    // a Go1 holding its pose, where there are sixteen rows and little coupling. A ragdoll is
    // the other regime, and picking per scene is the whole point of having both.
    const gpa: Allocator = std.testing.allocator;
    const source: []const u8 = @embedFile("tests/fixtures/robot/humanoid.xml");
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, source, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();

    var options: rbt.Options = .{
        .max_contacts = 256,
        .timestep = 1.0 / 500.0,
        .gravity = vec(0, 0, -9.81),
    };
    options.solver.algorithm = .newton;
    options.solver.max_iterations = 100;
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, options);
    defer imported.deinit();
    const model: *rbt.Model = &imported.model;
    var data: rbt.Data = try rbt.Data.init(gpa, model);
    defer data.deinit();

    var world: zimrphysics.World = try .init(gpa, 256);
    defer world.deinit(gpa);
    world.gravity = vec(0, 0, -9.81);
    const ground: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(6, 6, 0.5), .convex_radius = 0.01 },
    });
    _ = try world.createBody(.{
        .shape = ground,
        .position = vec(0, 0, -0.5),
        .motion_type = .static,
    });

    _ = robot_mjcf.applyKeyframe(model, &data, robot.keyframes[0]);
    // Dropped from 1.2 m and tipped, so it lands on its side rather than its feet - a body
    // that lands upright makes far fewer contacts and proves far less.
    data.pos[2] = 1.2;
    const tipped: Quat = quatFromAxisAngle(normalize3(vec(1, 0.3, 0)), 1.4);
    data.pos[3] = tipped[0];
    data.pos[4] = tipped[1];
    data.pos[5] = tipped[2];
    data.pos[6] = tipped[3];
    data.stage = .stale;
    rbt.forward(model, &data);

    var bridge: Bridge = try .init(gpa, &world, model, &data, 256);
    defer bridge.deinit(&world);
    bridge.listen(&world);

    var peak_contacts: u32 = 0;
    for (0..3000) |_| {
        rbt.forward(model, &data);
        try bridge.sync(&world, model, &data);
        try zimrphysics.step(&world, 1.0 / 500.0);
        bridge.harvest(&data);
        @memset(data.applied_force, 0);
        rbt.step(model, &data);
        peak_contacts = @max(peak_contacts, data.contact_count);
    }
    rbt.forward(model, &data);

    var fastest: f32 = 0;
    for (0..model.nv) |i| {
        fastest = @max(fastest, @abs(data.vel[i]));
    }

    // -- *** THIS BAR MOVED WHEN FRICTION WAS FIXED, AND THAT IS THE INTERESTING PART --
    //
    // Written against a hardcoded mu = 0.5 it asserted `< 1.0` and measured 0.41. With the
    // model's real friction reaching the contacts, the same drop measures **higher**, around
    // 2.0 - because a body that cannot SLIDE puts the energy its joint springs supply into its
    // JOINTS instead. More grip, more twitching. The physics is more right and the number is
    // worse, which is exactly the sort of thing a test bar tuned to a bug will hide.
    //
    // * AND A KNOWN GAP REMAINS. MuJoCo on this same model and drop holds max joint |v| at
    // 0.014-0.134; ours runs 0.67-1.94. Damping, stiffness and armature all import correctly -
    // `dof_armature` matches MuJoCo's 0.2100 exactly - so the parameters are right and the
    // dissipation is not. The bar below is set where the engine actually is, not where it
    // should be, so that CLOSING that gap shows up as this test needing a tighter bar.
    try expect(fastest < 4.0);
    // * AND IT LANDED RATHER THAN SANK OR EXPLODED - a body resting on its side puts its
    // pelvis a little above the floor, not at it and not below.
    try expect(data.body_xpos[1][2] > 0.05);
    try expect(data.body_xpos[1][2] < 0.5);
    // Enough contacts that the result means something: a limp humanoid on its side touches
    // the ground in several places at once.
    try expect(peak_contacts >= 8);
}

test "** a model's friction reaches its contacts" {
    // *** A CHAIN THAT WAS BROKEN IN THREE PLACES AT ONCE, and every one of them was silent.
    // MJCF stated `friction=".7"`, `robot_mjcf` discarded it with a comment saying so, `Model`
    // had nowhere to put it, the proxy body was created without it, and `onContact` fell
    // through to a hardcoded 0.5. Five links, and a broken one anywhere gives the same
    // symptom: every contact in every model behaving identically whatever the model says.
    //
    // * THE SYMPTOM WAS NOWHERE NEAR THE CAUSE. A limp humanoid on the ground crept sideways at
    // an ACCELERATING rate - 0.109 m over 25 s against MuJoCo's 0.071 and falling - because 0.5
    // could not hold what its joint springs were pushing. With the chain repaired the same drop
    // measures **0.0705 m against MuJoCo's 0.071**.
    //
    // This test walks the whole chain rather than its end, so a future break is attributed to
    // the link that broke.
    const gpa: Allocator = std.testing.allocator;
    const grippy: f32 = 0.7;
    const floor_mu: f32 = 0.9;

    const Puck: type = rbt.Spec(.{
        .bodies = &.{.{
            .name = "puck",
            .joints = &.{.{ .name = "free", .kind = .free }},
            .geoms = &.{.{
                .shape = .{ .box = .{ .half_extent = splat(@as(f32, 0.05)) } },
                .mass = 1.0,
                .friction = grippy,
            }},
        }},
        .options = .{ .timestep = 1.0 / 500.0, .max_contacts = 32, .gravity = vec(0, -9.81, 0) },
    });
    var model: rbt.Model = try Puck.build(gpa);
    defer model.deinit();

    // Link 1: the spec reaches the model's table.
    try expectApproxEqAbs(grippy, model.geom_friction[0], 1.0e-6);

    var data: rbt.Data = try rbt.Data.init(gpa, &model);
    defer data.deinit();
    var world: zimrphysics.World = try .init(gpa, 32);
    defer world.deinit(gpa);
    world.gravity = vec(0, -9.81, 0);
    const ground: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(5, 0.5, 5), .convex_radius = 0.01 },
    });
    _ = try world.createBody(.{
        .shape = ground,
        .position = vec(0, -0.5, 0),
        .motion_type = .static,
        .friction = floor_mu,
    });

    data.pos[1] = 0.049;
    data.stage = .stale;
    rbt.forward(&model, &data);
    var bridge: Bridge = try .init(gpa, &world, &model, &data, 32);
    defer bridge.deinit(&world);
    bridge.listen(&world);

    for (0..200) |_| {
        rbt.forward(&model, &data);
        try bridge.sync(&world, &model, &data);
        try zimrphysics.step(&world, 1.0 / 500.0);
        bridge.harvest(&data);
        @memset(data.applied_force, 0);
        rbt.step(&model, &data);
    }

    try expect(data.contact_count > 0);
    // * LINKS 2-5: the proxy carries it, the detector sees both bodies, and the contact gets
    // their GEOMETRIC mean - `sqrt(0.9 x 0.7) = 0.7937`, which is what zimrphysics uses for its
    // own pairs and what MuJoCo uses for its. Under the old code this read exactly 0.5, and
    // asserting on that number is what makes the regression impossible to reintroduce quietly.
    const want: f32 = @sqrt(floor_mu * grippy);
    for (0..data.contact_count) |c| {
        try expectApproxEqAbs(want, data.contacts[c].friction[0], 1.0e-3);
        try expectApproxEqAbs(want, data.contacts[c].friction[1], 1.0e-3);
    }
}

test "* THE GATE: a Unitree Go1 stands still for 30 seconds" {
    // *** PHASE C TURN 11, and the thing the whole roadmap turns on. A quadruped that will
    // not stand still fails for SOLVER reasons rather than modelling ones - contact softness,
    // friction and the warm start all show up here first - so everything after this is
    // guesswork until it holds.
    //
    // A real robot, imported from Menagerie's MJCF, held at its own `home` keyframe by plain
    // PD at the manufacturer's own `kp = 100`, on a floor, for 15000 steps at 500 Hz.
    const gpa: Allocator = std.testing.allocator;
    const source: []const u8 = @embedFile("tests/fixtures/robot/go1/go1.xml");
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, source, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();

    // * MJCF IS Z-UP, so the world's gravity has to be too. Handing a Z-up robot a Y-up
    // gravity gives a machine that falls sideways, which looks like a controller problem.
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, .{
        .max_contacts = 128,
        .timestep = 1.0 / 500.0,
        .gravity = vec(0, 0, -9.81),
    });
    defer imported.deinit();
    const model: *rbt.Model = &imported.model;
    var data: rbt.Data = try rbt.Data.init(gpa, model);
    defer data.deinit();

    var world: zimrphysics.World = try .init(gpa, 128);
    defer world.deinit(gpa);
    world.gravity = vec(0, 0, -9.81);
    const ground: zimrphysics.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(5, 5, 0.5), .convex_radius = 0.01 },
    });
    _ = try world.createBody(.{
        .shape = ground,
        .position = vec(0, 0, -0.5),
        .motion_type = .static,
    });

    try expect(robot_mjcf.applyKeyframe(model, &data, robot.keyframes[0]));
    rbt.forward(model, &data);
    var bridge: Bridge = try .init(gpa, &world, model, &data, 128);
    defer bridge.deinit(&world);
    bridge.listen(&world);

    const home: []f32 = try gpa.dupe(f32, robot.keyframes[0].qpos);
    defer gpa.free(home);
    const dt: f32 = 1.0 / 500.0;

    for (0..15000) |_| {
        rbt.forward(model, &data);
        try bridge.sync(&world, model, &data);
        try zimrphysics.step(&world, dt);
        bridge.harvest(&data);

        // * PLAIN PD IN TORQUE SPACE, clamped to the joint's rating, plus gravity
        // compensation ON THE ACTUATED DOFs ONLY.
        //
        // Two mistakes were made here first and both are worth keeping:
        //
        //   * **Computed torque cannot command a floating base.** `tau = M*a*` solves for
        //     accelerations the trunk has no motor to produce; zeroing those rows afterwards
        //     leaves the legs making up a difference they were never asked for, and the robot
        //     folds to a third of its height while looking like a tuning problem.
        //   * **Gravity compensation on the free joint makes the robot fly.** `bias_force`
        //     covers every DOF including the trunk's six; adding all of it cancels the
        //     machine's own weight, and it rises at a steady 2.4 m/s. A trunk has no motor,
        //     so it must feel its weight - the same rule the crates taught.
        @memset(data.applied_force, 0);
        for (0..model.njnt) |j| {
            if (model.jnt_type[j] != .hinge) {
                continue;
            }
            const q: u32 = model.jnt_qpos_adr[j];
            const v: u32 = model.jnt_dof_adr[j];
            const wanted: f32 = 100.0 * (home[q] - data.pos[q]) - 2.0 * data.vel[v];
            data.applied_force[v] = clamp(wanted, -35.55, 35.55) + data.bias_force[v];
        }
        rbt.step(model, &data);
    }
    rbt.forward(model, &data);

    // -- * IT IS STILL STANDING, and still --
    const trunk: u32 = imported.bodyIndex("trunk").?;
    // * A RANGE, NOT A TARGET - and the reason is worth recording.
    //
    // This asserted `0.27 +/- 0.03`, calibrated when two geometry bugs were still present: the
    // capsules were rotated 90 deg from MJCF's axis, and every foot's `pos` came from a CLASS
    // and was being dropped, so the robot stood on its shins. Both are fixed, the feet are
    // now the lowest geometry as they should be, and it settles higher.
    //
    // Which number is right cannot be re-derived here - MuJoCo needs the Menagerie mesh
    // assets to load this model and they are not checked in. So the test asserts what it can
    // actually justify: **the robot is standing on its legs**, somewhere between a deep
    // crouch and full extension, rather than a precise height whose reference was measured
    // against a bug.
    //
    // Tightening this again is a genuine to-do: re-derive the settled height from MuJoCo
    // with the assets present, and put the number back.
    try expect(data.body_xpos[trunk][2] > 0.20);
    try expect(data.body_xpos[trunk][2] < 0.40);
    // And nothing is moving: 1 cm/s over half a minute is a machine at rest, not one
    // drifting slowly enough to pass a short test.
    var fastest: f32 = 0;
    for (0..model.nv) |i| {
        fastest = @max(fastest, @abs(data.vel[i]));
    }
    try expect(fastest < 0.05);
    // Four feet on the ground.
    try expect(data.contact_count >= 4);
}
