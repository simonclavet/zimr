//! urdf.zig — read a URDF into a description zimr can build a robot from.
//!
//! Sits between `codecs.xml`, which turns bytes into a tree, and `robot.zig`, which
//! simulates. It owns exactly one job: the SEMANTICS and the CONVENTIONS. What a `<joint>`
//! element means, which frame an axis lives in, and how URDF's world relates to zimr's.
//!
//! ── THE ARCHITECTURE, AND WHY IT IS THIS SHAPE ──
//!
//!     bytes → codecs.xml → urdf.parse → urdf.Robot → { emit Zig | build a Model }
//!
//! One semantic pass producing one runtime value, with thin backends after it. The hard
//! part — tree construction, frame conversion, unit handling — happens once and both
//! consumers inherit it. Writing a code generator and a runtime loader as separate parsers
//! would mean two chances to get the conventions wrong and no way to test one against the
//! other.
//!
//! `urdf.Robot` deliberately does NOT depend on `robot.zig`. It is a plain description in
//! zimr's conventions; the mapping onto `robot.ModelSpec` is the backend's business. That
//! keeps this file testable on its own and keeps the engine free of file formats.
//!
//! ── WHAT IS SUPPORTED, AND WHAT IS REFUSED ──
//!
//! Links, joints (revolute, continuous, prismatic, fixed, floating), inertials, and
//! primitive collision geometry. Meshes are recorded by filename but not loaded — that is
//! Milestone 2.
//!
//! Everything else is an ERROR carrying the element that caused it. `planar` joints, xacro
//! that has not been expanded, a forest instead of a tree: all refused loudly. A robot
//! description that half-imports is worse than one that does not import, because the
//! failure appears later as a machine that is subtly the wrong shape.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zm = @import("zm");
const float = zm.float;
const codecs = @import("codecs.zig");

const Vec = zm.Vec;
const Quat = zm.Quat;
const vec = zm.vec;
const vec_zero = zm.vec_zero;
const quat_identity = zm.quat_identity;
const qmul = zm.qmul;
const quatFromNormAxisAngle = zm.quatFromNormAxisAngle;
const normalize3 = zm.normalize3;
const maxInt = zm.maxInt;
const splat = zm.splat;
const dot3 = zm.dot3;
const length3 = zm.length3;
const pi = zm.pi;

pub const Error = error{
    /// The document's root is not `<robot>`.
    NotARobot,
    /// A `<link>` or `<joint>` without a name, or a duplicate name.
    BadName,
    /// A joint naming a link that does not exist.
    UnknownLink,
    /// Zero roots, or more than one — a URDF must be a single tree.
    NotATree,
    /// A joint chain that loops back on itself.
    CyclicTree,
    /// A numeric attribute that is not a number, or a tuple of the wrong length.
    BadNumber,
    /// A construct this importer does not implement, named in the diagnostic.
    Unsupported,
    /// A required child element or attribute is absent.
    MissingField,
    OutOfMemory,
};

pub const Diagnostic = struct {
    /// What went wrong, in words, pointing at the offending name where possible.
    detail: []const u8 = "",
    /// Line in the source file, when the failure is tied to an element.
    line: u32 = 0,
};

/// ★ URDF IS Z-UP; ZIMR IS Y-UP. This is the rotation between them, and applying it is a
/// one-line operation for a reason worth understanding.
///
/// A rigid rotation of the entire model leaves every body's pose RELATIVE TO ITS PARENT
/// unchanged — only the root's pose relative to the world moves. So the whole axis
/// conversion is: rotate the root. Joint axes, inertia tensors and child transforms are all
/// expressed in their own parent's frame and come along for free.
///
/// The rotation is −90° about X, which sends `+Z → +Y` and `+Y → −Z`: what URDF calls up is
/// what zimr calls up, and gravity along `−Y` is then correct without touching the model.
///
/// §1.2 of the plan promised this conversion would live in the importer. This is it, and it
/// is four lines because the tree structure does the rest.
pub const z_up_to_y_up: Quat = quatFromNormAxisAngle(vec(1, 0, 0), -pi * 0.5);

pub const JointKind = enum {
    /// A hinge with travel limits (URDF `revolute`).
    hinge,
    /// A hinge without limits (URDF `continuous`).
    continuous,
    /// A prismatic slider (URDF `prismatic`).
    slide,
    /// Welded to the parent. Contributes NO degrees of freedom, which in zimr's model is
    /// simply a body with no joints — the same thing, expressed structurally.
    fixed,
    /// Six DOFs (URDF `floating`).
    free,
};

pub const Joint = struct {
    name: []const u8,
    kind: JointKind,
    /// Axis in the CHILD body's frame, normalized. URDF states it that way and so does
    /// zimr, which is why no conversion appears here.
    axis: Vec,
    /// Travel limits, in radians or metres. Null for `continuous` and `fixed`.
    limit: ?[2]f32,
    /// `<dynamics damping=...>`.
    damping: f32,
    /// `<mimic>`: this joint follows another as `multiplier · other + offset`.
    ///
    /// Recorded rather than resolved, because in zimr's model a mimic is a FIXED TENDON —
    /// exactly `TendonSpec` with coefficients `(1, −multiplier)`. Phase 8 built the
    /// mechanism before this file existed; the backend just has to emit it.
    mimic: ?struct {
        joint: []const u8,
        multiplier: f32,
        offset: f32,
    },
};

pub const Inertial = struct {
    mass: f32,
    /// Centre of mass in the body's frame.
    pos: Vec,
    /// Inertia about the COM, expressed in the BODY frame, ordered as MuJoCo's
    /// `fullinertia`: `(xx, yy, zz, xy, xz, yz)`.
    ///
    /// URDF states the tensor in the `<inertial><origin>` frame, which may be ROTATED
    /// relative to the body. The rotation is applied here rather than being passed on, so
    /// the engine's spec never needs an inertia orientation — §4i-bis identified that as a
    /// real gap and this is the cheaper half of the fix.
    full_inertia: [6]f32,
};

pub const Shape = union(enum) {
    box: Vec, // half extents
    cylinder: struct { half_height: f32, radius: f32 },
    sphere: f32, // radius
    /// Recorded but not yet loaded. `filename` is verbatim from the URDF, so it may be a
    /// `package://` URI. `resolveMeshes` turns these into `.hull`.
    mesh: struct { filename: []const u8, scale: Vec },
    /// A loaded mesh, reduced to the points that span its convex hull. See `hullPoints`.
    hull: []const Vec,
};

/// Load every `.mesh` shape and replace it with the `.hull` its vertices span.
///
/// ★ THE FILE I/O IS THE CALLER'S. `urdf.zig` parses bytes and knows nothing about paths,
/// virtual filesystems or asset bundles — which is what lets it be tested without a disk and
/// used from a build tool, a game and a browser alike. `load` is handed the filename exactly
/// as the URDF wrote it and returns bytes or null.
///
/// A mesh that cannot be loaded is SKIPPED, not fatal: the mesh files are frequently
/// distributed separately from the URDF, and a robot with correct inertias and no collision
/// geometry is a useful thing that MuJoCo itself refuses to produce. The count comes back so
/// the caller can say so out loud.
pub fn resolveMeshes(
    gpa: Allocator,
    robot: *Robot,
    context: *anyopaque,
    load: *const fn (context: *anyopaque, filename: []const u8) ?[]const u8,
    direction_count: u32,
) Error!u32 {
    const a: Allocator = robot.arena.allocator();
    var resolved: u32 = 0;
    for (robot.bodies) |*body| {
        for (body.geoms) |*geom| {
            const mesh: @FieldType(Shape, "mesh") = switch (geom.shape) {
                .mesh => |m| m,
                else => continue,
            };
            const bytes: []const u8 = load(context, mesh.filename) orelse continue;
            const vertices: []f32 = try meshVertices(gpa, mesh.filename, bytes);
            defer gpa.free(vertices);
            // The URDF's `scale` applies to the mesh's own coordinates, before anything else
            // sees them. Almost always 1, and silently ignoring it would shrink a robot by
            // whatever factor its author chose.
            for (0..vertices.len / 3) |i| {
                inline for (0..3) |k| {
                    vertices[i * 3 + k] *= mesh.scale[k];
                }
            }
            const points: []Vec = try hullPoints(gpa, vertices, direction_count);
            defer gpa.free(points);
            geom.shape = .{ .hull = try a.dupe(Vec, points) };
            resolved += 1;
        }
    }
    return resolved;
}

/// Vertices from whichever mesh format the filename names.
fn meshVertices(gpa: Allocator, filename: []const u8, bytes: []const u8) Error![]f32 {
    if (endsWithIgnoreCase(filename, ".stl")) {
        const mesh: codecs.stl.Mesh = codecs.stl.parse(gpa, bytes) catch return Error.Unsupported;
        defer mesh.deinit(gpa);
        return gpa.dupe(f32, mesh.positions) catch Error.OutOfMemory;
    }
    if (endsWithIgnoreCase(filename, ".obj")) {
        const parsed: codecs.obj.Data = codecs.obj.parse(gpa, bytes) catch return Error.Unsupported;
        defer parsed.deinit(gpa);
        return gpa.dupe(f32, parsed.positions) catch Error.OutOfMemory;
    }
    // COLLADA (.dae) is the remaining common one. Refused rather than guessed at: it is a
    // large XML format, and a robot silently missing its collision geometry is worse than
    // one that says which file it could not read.
    return Error.Unsupported;
}

fn endsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
    if (haystack.len < suffix.len) {
        return false;
    }
    const tail: []const u8 = haystack[haystack.len - suffix.len ..];
    for (tail, suffix) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) {
            return false;
        }
    }
    return true;
}

pub const Geom = struct {
    shape: Shape,
    pos: Vec,
    rot: Quat,
};

pub const Body = struct {
    name: []const u8,
    /// Index into `Robot.bodies`, always LESS than this body's own index. Null for the root.
    parent: ?u32,
    /// Pose relative to the parent's frame — which is exactly URDF's joint `<origin>`,
    /// because URDF puts the parent→child transform on the joint and zimr puts it on the
    /// body. The two conventions line up with no algebra.
    pos: Vec,
    rot: Quat,
    /// The joint connecting this body to its parent. Null for the root and for `fixed`
    /// joints, both of which contribute no degrees of freedom.
    joint: ?Joint,
    inertial: ?Inertial,
    geoms: []Geom,
};

pub const Robot = struct {
    arena: *std.heap.ArenaAllocator,
    name: []const u8,
    /// Topologically ordered: a body's parent always precedes it. Guaranteed by
    /// construction, so a consumer can build the tree in one forward pass.
    bodies: []Body,

    pub fn deinit(self: *Robot) void {
        const gpa: Allocator = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
        self.* = undefined;
    }
};

/// Read a URDF from bytes.
pub fn parse(
    gpa: Allocator,
    source: []const u8,
    diagnostic: ?*Diagnostic,
) Error!Robot {
    var xml_diagnostic: codecs.xml.Diagnostic = .{};
    var doc: codecs.xml.Document = codecs.xml.parse(gpa, source, &xml_diagnostic) catch {
        if (diagnostic) |d| {
            d.* = .{ .detail = "the file is not well-formed XML", .line = xml_diagnostic.line };
        }
        return Error.Unsupported;
    };
    defer doc.deinit();
    return fromDocument(gpa, &doc, diagnostic);
}

/// Read a URDF from an already-parsed document. Separate so a caller who has the tree for
/// another reason does not parse twice.
pub fn fromDocument(
    gpa: Allocator,
    doc: *const codecs.xml.Document,
    diagnostic: ?*Diagnostic,
) Error!Robot {
    var arena: *std.heap.ArenaAllocator = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();

    var reader: Reader = .{ .doc = doc, .arena = arena.allocator(), .diagnostic = diagnostic };
    const bodies: []Body = try reader.run();

    return .{
        .arena = arena,
        .name = doc.attribute(doc.rootElement(), "name") orelse "robot",
        .bodies = bodies,
    };
}

const Reader = struct {
    doc: *const codecs.xml.Document,
    arena: Allocator,
    diagnostic: ?*Diagnostic,

    const Element = codecs.xml.Element;

    /// One `<link>`, before the tree is known.
    const RawLink = struct {
        name: []const u8,
        inertial: ?Inertial,
        geoms: []Geom,
        /// Filled in during tree construction.
        parent_joint: ?u32 = null,
    };

    /// One `<joint>`, before the tree is known.
    const RawJoint = struct {
        joint: Joint,
        parent_name: []const u8,
        child_name: []const u8,
        /// Resolved in `buildTree`, once. Everything downstream works in indices — the
        /// names are kept only for error messages.
        parent: u32 = 0,
        child: u32 = 0,
        pos: Vec,
        rot: Quat,
        line: u32,
    };

    fn fail(self: *Reader, err: Error, detail: []const u8, line: u32) Error {
        if (self.diagnostic) |d| {
            d.* = .{ .detail = detail, .line = line };
        }
        return err;
    }

    fn run(self: *Reader) Error![]Body {
        const root: *const Element = self.doc.rootElement();
        if (!std.mem.eql(u8, root.name, "robot")) {
            return self.fail(Error.NotARobot, "root element is not <robot>", root.line);
        }

        var links: std.ArrayListUnmanaged(RawLink) = .empty;
        var joints: std.ArrayListUnmanaged(RawJoint) = .empty;

        for (self.doc.childrenOf(root)) |*element| {
            if (std.mem.eql(u8, element.name, "link")) {
                try links.append(self.arena, try self.readLink(element));
            } else if (std.mem.eql(u8, element.name, "joint")) {
                try joints.append(self.arena, try self.readJoint(element));
            }
            // Anything else at the top level — <material>, <transmission>, <gazebo> — is
            // ignored on purpose. Those describe appearance, ROS plumbing or simulator
            // hints, none of which affect the mechanism. Silently skipping an element that
            // cannot change the robot is different from silently skipping one that can,
            // which is why the joint and link readers below refuse what they do not know.
        }

        if (links.items.len == 0) {
            return self.fail(Error.NotATree, "the robot has no links", root.line);
        }
        return self.buildTree(links.items, joints.items, root.line);
    }

    /// Turn the flat link/joint lists into a parent-before-child ordered tree.
    ///
    /// URDF gives a set of joints, each naming a parent and a child link; the root is the
    /// link that is never anybody's child. Two failure modes are checked rather than
    /// assumed, because both produce a plausible-looking half-robot if ignored: more than
    /// one root (a forest — usually a typo in a link name) and a cycle.
    fn buildTree(
        self: *Reader,
        links: []RawLink,
        joints: []RawJoint,
        root_line: u32,
    ) Error![]Body {
        // ★ DUPLICATE NAMES FIRST, before anything resolves a name to an index.
        //
        // `findLink` returns the first match, so two links sharing a name would leave the
        // second unreachable while every joint naming it silently wired to the first. The
        // result is a robot that imports "successfully" with the wrong topology — the exact
        // failure this whole file is arranged to prevent, and one urdfdom checks for too.
        for (links, 0..) |link, i| {
            for (links[i + 1 ..]) |other| {
                if (std.mem.eql(u8, link.name, other.name)) {
                    return self.fail(Error.BadName, link.name, root_line);
                }
            }
        }
        for (joints, 0..) |joint, i| {
            for (joints[i + 1 ..]) |other| {
                if (std.mem.eql(u8, joint.joint.name, other.joint.name)) {
                    return self.fail(Error.BadName, joint.joint.name, joint.line);
                }
            }
        }

        // Resolve names to indices ONCE and keep them. Linear scans are fine at these sizes
        // — a large humanoid has fewer than a hundred links — but doing them repeatedly, or
        // comparing names again later, is how a duplicate slips back in.
        for (joints, 0..) |*joint, joint_index| {
            joint.parent = try self.findLink(links, joint.parent_name, joint.line);
            joint.child = try self.findLink(links, joint.child_name, joint.line);
            if (links[joint.child].parent_joint != null) {
                return self.fail(
                    Error.NotATree,
                    "a link is the child of more than one joint",
                    joint.line,
                );
            }
            links[joint.child].parent_joint = @intCast(joint_index);
        }

        // The root is the link with no parent joint. Exactly one, or this is not a tree.
        var root_index: ?u32 = null;
        for (links, 0..) |link, i| {
            if (link.parent_joint == null) {
                if (root_index != null) {
                    return self.fail(
                        Error.NotATree,
                        "more than one link has no parent — a URDF must be one tree",
                        root_line,
                    );
                }
                root_index = @intCast(i);
            }
        }
        const root: u32 = root_index orelse
            return self.fail(Error.CyclicTree, "every link has a parent, so the joints form a cycle", root_line);

        // Breadth-first from the root gives parent-before-child ordering for free, and
        // visiting each link exactly once detects a cycle hanging off the tree.
        var order: std.ArrayListUnmanaged(u32) = .empty;
        var new_index: []u32 = try self.arena.alloc(u32, links.len);
        @memset(new_index, maxInt(u32));
        try order.append(self.arena, root);
        new_index[root] = 0;

        var cursor: usize = 0;
        while (cursor < order.items.len) : (cursor += 1) {
            const parent_link: u32 = order.items[cursor];
            for (joints) |joint| {
                if (joint.parent != parent_link) {
                    continue;
                }
                if (new_index[joint.child] != maxInt(u32)) {
                    return self.fail(Error.CyclicTree, "the joints form a cycle", joint.line);
                }
                new_index[joint.child] = @intCast(order.items.len);
                try order.append(self.arena, joint.child);
            }
        }
        if (order.items.len != links.len) {
            return self.fail(
                Error.NotATree,
                "some links are unreachable from the root",
                root_line,
            );
        }

        // ---- emit, in tree order ----
        var bodies: []Body = try self.arena.alloc(Body, links.len);
        for (order.items, 0..) |link_index, i| {
            const link: RawLink = links[link_index];
            var body: Body = .{
                .name = link.name,
                .parent = null,
                .pos = vec_zero,
                // ★ The Z-up → Y-up conversion, in its entirety. Only the root carries it;
                // every other body's pose is relative to its parent and is already correct
                // in the rotated frame.
                .rot = if (i == 0) z_up_to_y_up else quat_identity,
                .joint = null,
                .inertial = link.inertial,
                .geoms = link.geoms,
            };
            if (link.parent_joint) |joint_index| {
                const joint: RawJoint = joints[joint_index];
                body.parent = new_index[joint.parent];
                body.pos = joint.pos;
                body.rot = joint.rot;
                // A fixed joint contributes no DOF, so it becomes a body with no joint —
                // which is what a weld IS in generalized coordinates, not an approximation
                // of one.
                body.joint = if (joint.joint.kind == .fixed) null else joint.joint;
            }
            bodies[i] = body;
        }
        return bodies;
    }

    fn findLink(
        self: *Reader,
        links: []const RawLink,
        name: []const u8,
        line: u32,
    ) Error!u32 {
        for (links, 0..) |link, i| {
            if (std.mem.eql(u8, link.name, name)) {
                return @intCast(i);
            }
        }
        return self.fail(Error.UnknownLink, name, line);
    }

    // ---- element readers ----

    fn readLink(self: *Reader, element: *const Element) Error!RawLink {
        const name: []const u8 = self.doc.attribute(element, "name") orelse
            return self.fail(Error.BadName, "a <link> has no name", element.line);

        var geoms: std.ArrayListUnmanaged(Geom) = .empty;
        for (self.doc.childrenOf(element)) |*child| {
            // Only <collision> becomes a geom. <visual> describes appearance and would
            // double the contact geometry if imported — real models give them different
            // shapes on purpose, a detailed mesh to look at and a crude hull to collide.
            if (!std.mem.eql(u8, child.name, "collision")) {
                continue;
            }
            if (try self.readGeom(child)) |geom| {
                try geoms.append(self.arena, geom);
            }
        }

        var inertial: ?Inertial = null;
        if (self.doc.child(element, "inertial")) |i| {
            inertial = try self.readInertial(i);
        }

        return .{
            .name = name,
            .inertial = inertial,
            .geoms = try geoms.toOwnedSlice(self.arena),
        };
    }

    fn readInertial(self: *Reader, element: *const Element) Error!Inertial {
        const mass_element: *const Element = self.doc.child(element, "mass") orelse
            return self.fail(Error.MissingField, "<inertial> without <mass>", element.line);
        const mass: f32 = try self.number(mass_element, "value", element.line);

        const tensor: *const Element = self.doc.child(element, "inertia") orelse
            return self.fail(Error.MissingField, "<inertial> without <inertia>", element.line);
        // URDF names the six independent components individually; all default to zero,
        // matching urdfdom.
        const ixx: f32 = try self.optionalNumber(tensor, "ixx", 0, element.line);
        const iyy: f32 = try self.optionalNumber(tensor, "iyy", 0, element.line);
        const izz: f32 = try self.optionalNumber(tensor, "izz", 0, element.line);
        const ixy: f32 = try self.optionalNumber(tensor, "ixy", 0, element.line);
        const ixz: f32 = try self.optionalNumber(tensor, "ixz", 0, element.line);
        const iyz: f32 = try self.optionalNumber(tensor, "iyz", 0, element.line);

        const pose: Pose = try self.readOrigin(element);

        // ★ Rotate the tensor into the BODY frame if the inertial origin is rotated.
        //
        // `I' = R·I·Rᵀ`. Doing it here means `robot.InertialSpec` never needs an
        // orientation field: the engine's spec stays minimal and the conversion lives with
        // the other conversions. The common case is an identity rotation and costs nothing.
        if (length3(pose.rot - quat_identity) < 1.0e-7 and @abs(pose.rot[3] - 1.0) < 1.0e-7) {
            return .{
                .mass = mass,
                .pos = pose.pos,
                .full_inertia = .{ ixx, iyy, izz, ixy, ixz, iyz },
            };
        }
        return .{
            .mass = mass,
            .pos = pose.pos,
            .full_inertia = rotateInertia(.{ ixx, iyy, izz, ixy, ixz, iyz }, pose.rot),
        };
    }

    fn readGeom(self: *Reader, element: *const Element) Error!?Geom {
        const geometry: *const Element = self.doc.child(element, "geometry") orelse
            return self.fail(Error.MissingField, "<collision> without <geometry>", element.line);
        const pose: Pose = try self.readOrigin(element);

        for (self.doc.childrenOf(geometry)) |*shape_element| {
            const shape: Shape = blk: {
                if (std.mem.eql(u8, shape_element.name, "box")) {
                    const size: Vec = try self.tuple3(shape_element, "size", shape_element.line);
                    // URDF gives full extents; zimr's box is a half-extent.
                    break :blk .{ .box = size * splat(0.5) };
                }
                if (std.mem.eql(u8, shape_element.name, "cylinder")) {
                    break :blk .{ .cylinder = .{
                        .half_height = try self.number(shape_element, "length", shape_element.line) * 0.5,
                        .radius = try self.number(shape_element, "radius", shape_element.line),
                    } };
                }
                if (std.mem.eql(u8, shape_element.name, "sphere")) {
                    break :blk .{ .sphere = try self.number(shape_element, "radius", shape_element.line) };
                }
                if (std.mem.eql(u8, shape_element.name, "mesh")) {
                    const filename: []const u8 = self.doc.attribute(shape_element, "filename") orelse
                        return self.fail(Error.MissingField, "<mesh> without filename", shape_element.line);
                    const scale: Vec = if (self.doc.attribute(shape_element, "scale") != null)
                        try self.tuple3(shape_element, "scale", shape_element.line)
                    else
                        vec(1, 1, 1);
                    break :blk .{ .mesh = .{ .filename = filename, .scale = scale } };
                }
                return self.fail(Error.Unsupported, shape_element.name, shape_element.line);
            };
            return .{ .shape = shape, .pos = pose.pos, .rot = pose.rot };
        }
        return null;
    }

    fn readJoint(self: *Reader, element: *const Element) Error!RawJoint {
        const name: []const u8 = self.doc.attribute(element, "name") orelse
            return self.fail(Error.BadName, "a <joint> has no name", element.line);
        const type_text: []const u8 = self.doc.attribute(element, "type") orelse
            return self.fail(Error.MissingField, name, element.line);

        const kind: JointKind = if (std.mem.eql(u8, type_text, "revolute"))
            .hinge
        else if (std.mem.eql(u8, type_text, "continuous"))
            .continuous
        else if (std.mem.eql(u8, type_text, "prismatic"))
            .slide
        else if (std.mem.eql(u8, type_text, "fixed"))
            .fixed
        else if (std.mem.eql(u8, type_text, "floating"))
            .free
        else
            // `planar` is the remaining URDF type. It is two translations and a rotation,
            // expressible as three joints on one body — but silently expanding it would
            // change the DOF count from what the file says, so it is refused until someone
            // has a model that needs it.
            return self.fail(Error.Unsupported, type_text, element.line);

        const parent_element: *const Element = self.doc.child(element, "parent") orelse
            return self.fail(Error.MissingField, name, element.line);
        const child_element: *const Element = self.doc.child(element, "child") orelse
            return self.fail(Error.MissingField, name, element.line);

        const axis: Vec = if (self.doc.child(element, "axis")) |a|
            normalize3(try self.tuple3(a, "xyz", element.line))
        else
            // URDF's default axis is +X. Stated here rather than assumed, because it is not
            // the default a reader would guess (zimr's own joints default to +Y).
            vec(1, 0, 0);

        // ★ A limit whose bounds are absent must NOT default to zero. `[0, 0]` is a joint
        // welded shut, and a robot whose every joint is locked looks like a physics bug
        // rather than an import one. URDF requires both bounds on revolute and prismatic
        // joints, so a missing one is a malformed file and is refused.
        var limit: ?[2]f32 = null;
        if (kind == .hinge or kind == .slide) {
            const limit_element: *const Element = self.doc.child(element, "limit") orelse
                return self.fail(Error.MissingField, name, element.line);
            const lower: f32 = try self.number(limit_element, "lower", element.line);
            const upper: f32 = try self.number(limit_element, "upper", element.line);
            if (lower > upper) {
                return self.fail(Error.BadNumber, name, element.line);
            }
            limit = .{ lower, upper };
        }

        const damping: f32 = if (self.doc.child(element, "dynamics")) |d|
            try self.optionalNumber(d, "damping", 0, element.line)
        else
            0;

        var mimic: @FieldType(Joint, "mimic") = null;
        if (self.doc.child(element, "mimic")) |m| {
            mimic = .{
                .joint = self.doc.attribute(m, "joint") orelse
                    return self.fail(Error.MissingField, name, element.line),
                .multiplier = try self.optionalNumber(m, "multiplier", 1, element.line),
                .offset = try self.optionalNumber(m, "offset", 0, element.line),
            };
        }

        const pose: Pose = try self.readOrigin(element);
        return .{
            .joint = .{
                .name = name,
                .kind = kind,
                .axis = axis,
                .limit = limit,
                .damping = damping,
                .mimic = mimic,
            },
            .parent_name = self.doc.attribute(parent_element, "link") orelse
                return self.fail(Error.MissingField, name, element.line),
            .child_name = self.doc.attribute(child_element, "link") orelse
                return self.fail(Error.MissingField, name, element.line),
            .pos = pose.pos,
            .rot = pose.rot,
            .line = element.line,
        };
    }

    const Pose = struct { pos: Vec, rot: Quat };

    /// A `<origin xyz rpy>` child, or the identity if absent.
    fn readOrigin(self: *Reader, element: *const Element) Error!Pose {
        const origin: *const Element = self.doc.child(element, "origin") orelse
            return .{ .pos = vec_zero, .rot = quat_identity };
        const pos: Vec = if (self.doc.attribute(origin, "xyz") != null)
            try self.tuple3(origin, "xyz", origin.line)
        else
            vec_zero;
        const rpy: Vec = if (self.doc.attribute(origin, "rpy") != null)
            try self.tuple3(origin, "rpy", origin.line)
        else
            vec_zero;
        return .{ .pos = pos, .rot = quatFromRpy(rpy) };
    }

    // ---- attribute readers ----

    fn number(
        self: *Reader,
        element: *const Element,
        name: []const u8,
        line: u32,
    ) Error!f32 {
        const text: []const u8 = self.doc.attribute(element, name) orelse
            return self.fail(Error.MissingField, name, line);
        return std.fmt.parseFloat(f32, std.mem.trim(u8, text, " \t\r\n")) catch
            return self.fail(Error.BadNumber, text, line);
    }

    fn optionalNumber(
        self: *Reader,
        element: *const Element,
        name: []const u8,
        default: f32,
        line: u32,
    ) Error!f32 {
        if (self.doc.attribute(element, name) == null) {
            return default;
        }
        return self.number(element, name, line);
    }

    /// Three space-separated numbers. URDF writes vectors this way everywhere.
    fn tuple3(
        self: *Reader,
        element: *const Element,
        name: []const u8,
        line: u32,
    ) Error!Vec {
        const text: []const u8 = self.doc.attribute(element, name) orelse
            return self.fail(Error.MissingField, name, line);
        var values: [3]f32 = .{ 0, 0, 0 };
        var count: usize = 0;
        var it: std.mem.TokenIterator(u8, .any) = std.mem.tokenizeAny(u8, text, " \t\r\n");
        while (it.next()) |token| {
            if (count == 3) {
                return self.fail(Error.BadNumber, text, line);
            }
            values[count] = std.fmt.parseFloat(f32, token) catch
                return self.fail(Error.BadNumber, token, line);
            count += 1;
        }
        if (count != 3) {
            return self.fail(Error.BadNumber, text, line);
        }
        return vec(values[0], values[1], values[2]);
    }
};

/// Reduce a mesh's vertices to a small set that spans the same convex hull.
///
/// ── ★ WHY THIS EXISTS: 2.7 MB OF GENERATED SOURCE ──
///
/// A KUKA link's collision mesh is 3038 triangles — 9114 vertices, since STL repeats every
/// shared corner. Emitted verbatim that is 347 KB of Zig per link and 2.7 MB for the arm,
/// to describe a shape whose convex hull has perhaps eighty corners. The compiler would
/// chew through it and the file would be unreadable.
///
/// ── THE IDEA ──
///
/// Every vertex of a convex hull is the FARTHEST point of the cloud in some direction. So
/// sampling many directions and keeping the extreme point in each recovers the hull's
/// corners and discards everything interior — which is most of a mesh. What comes back is a
/// subset of the original points, so it can only under-approximate: no direction produces a
/// point the cloud does not contain, and the hull of the subset is contained in the hull of
/// the whole.
///
/// Directions come from a Fibonacci sphere, which spreads points on a sphere far more evenly
/// than latitude/longitude bands — those cluster at the poles and would resolve the top of a
/// shape finely while missing detail around its equator.
///
/// ── WHY A SINGLE HULL AT ALL ──
///
/// A concave link becomes its convex hull, which is an over-approximation of the solid.
/// That is not a shortcut relative to MuJoCo: **MuJoCo's collision system is convex-only and
/// treats a `<mesh>` geom as its hull too.** `obj2mjcf` offers CoACD decomposition into
/// several hulls, and offers it OPT-IN with a single hull as the default. Matching that
/// default is parity, and decomposition can follow if a model needs it.
pub fn hullPoints(
    gpa: Allocator,
    vertices: []const f32,
    direction_count: u32,
) Error![]Vec {
    if (vertices.len < 9) {
        return Error.BadNumber;
    }
    const point_count: usize = vertices.len / 3;

    var kept: std.ArrayListUnmanaged(Vec) = .empty;
    errdefer kept.deinit(gpa);

    // ★ THE SIX AXES FIRST, then the spread. A Fibonacci spiral distributes directions
    // evenly but hits no axis exactly, so the extreme point along ±X, ±Y, ±Z could be
    // missed by a fraction of a millimetre. That matters more than it sounds: the kept
    // points' bounding box becomes the geom's `bounds_half_extent`, which is what the
    // inertia is computed from. Seeding the axes makes the AABB EXACT rather than nearly
    // right, for six extra iterations.
    const axes = [_]Vec{
        vec(1, 0, 0), vec(-1, 0, 0),
        vec(0, 1, 0), vec(0, -1, 0),
        vec(0, 0, 1), vec(0, 0, -1),
    };
    const axis_count: u32 = axes.len;
    var d: u32 = 0;
    while (d < direction_count + axis_count) : (d += 1) {
        const direction: Vec = if (d < axis_count)
            axes[d]
        else
            fibonacciDirection(d - axis_count, direction_count);
        var best: usize = 0;
        var best_dot: f32 = -1.0e30;
        for (0..point_count) |i| {
            const v: Vec = vec(vertices[i * 3], vertices[i * 3 + 1], vertices[i * 3 + 2]);
            // Support function: the vertex furthest along `direction`. Named `projection` rather
            // than `dot` because the bare name shadows zimrmath's, and because what it measures is
            // how far this vertex projects onto the search direction.
            const projection: f32 = dot3(direction, v);
            if (projection > best_dot) {
                best_dot = projection;
                best = i;
            }
        }
        const winner: Vec = vec(
            vertices[best * 3],
            vertices[best * 3 + 1],
            vertices[best * 3 + 2],
        );
        // Neighbouring directions usually pick the SAME corner, so most iterations add
        // nothing — which is the mechanism working, not a waste.
        var already: bool = false;
        for (kept.items) |existing| {
            if (length3(existing - winner) < 1.0e-6) {
                already = true;
                break;
            }
        }
        if (!already) {
            try kept.append(gpa, winner);
        }
    }
    return kept.toOwnedSlice(gpa);
}

/// The `i`-th of `n` roughly-equal-area directions on the unit sphere.
///
/// Latitude/longitude sampling clusters at the poles; this does not. The golden-angle
/// spiral places each point at a fixed height increment with the azimuth advanced by an
/// irrational fraction of a turn, so no two ever line up.
fn fibonacciDirection(i: u32, n: u32) Vec {
    const golden_angle: f32 = pi * (3.0 - @sqrt(5.0));
    const fi: f32 = @floatFromInt(i);
    const fn_: f32 = @floatFromInt(n);
    const y: f32 = 1.0 - 2.0 * (fi + 0.5) / fn_;
    const radius: f32 = @sqrt(@max(0.0, 1.0 - y * y));
    const theta: f32 = golden_angle * fi;
    return vec(radius * @cos(theta), y, radius * @sin(theta));
}

/// ★ URDF's roll-pitch-yaw, as a quaternion.
///
/// THE most dangerous conversion in this file: get the composition order wrong and every
/// link is subtly rotated, which produces a robot of the right shape in the wrong pose —
/// the failure that is hardest to see and easiest to ship.
///
/// The order is FIXED-AXIS: roll about world X, then pitch about world Y, then yaw about
/// world Z, which composes right to left as
///
///     R = Rz(yaw) · Ry(pitch) · Rx(roll)
///
/// Confirmed against two independent implementations rather than derived from the spec's
/// prose: `URDFLoader.js` builds a three.js Euler with order `'ZYX'`, and `tinyurdfparser`
/// calls `KDL::Rotation::RPY(r, p, y)`. Both are the same composition.
pub fn quatFromRpy(rpy: Vec) Quat {
    const roll: Quat = quatFromNormAxisAngle(vec(1, 0, 0), rpy[0]);
    const pitch: Quat = quatFromNormAxisAngle(vec(0, 1, 0), rpy[1]);
    const yaw: Quat = quatFromNormAxisAngle(vec(0, 0, 1), rpy[2]);
    return qmul(yaw, qmul(pitch, roll));
}

/// `I' = R·I·Rᵀ` on the packed six-component form.
///
/// The same operation `robot.Inertia.rotated` performs, repeated here so this file does not
/// depend on the engine. It is six dot products; sharing it would cost a dependency worth
/// more than the duplication.
fn rotateInertia(packed_tensor: [6]f32, rot: Quat) [6]f32 {
    const columns = [3]Vec{
        zm.rotate(rot, vec(1, 0, 0)),
        zm.rotate(rot, vec(0, 1, 0)),
        zm.rotate(rot, vec(0, 0, 1)),
    };
    // Rows of R are columns of Rᵀ; `I'[a][b] = rowᵃ · (I · rowᵇ)`.
    const rows = [3]Vec{
        vec(columns[0][0], columns[1][0], columns[2][0]),
        vec(columns[0][1], columns[1][1], columns[2][1]),
        vec(columns[0][2], columns[1][2], columns[2][2]),
    };
    const applied = [3]Vec{
        applyTensor(packed_tensor, rows[0]),
        applyTensor(packed_tensor, rows[1]),
        applyTensor(packed_tensor, rows[2]),
    };
    return .{
        dot3(rows[0], applied[0]),
        dot3(rows[1], applied[1]),
        dot3(rows[2], applied[2]),
        dot3(rows[0], applied[1]),
        dot3(rows[0], applied[2]),
        dot3(rows[1], applied[2]),
    };
}

fn applyTensor(t: [6]f32, v: Vec) Vec {
    return vec(
        t[0] * v[0] + t[3] * v[1] + t[4] * v[2],
        t[3] * v[0] + t[1] * v[1] + t[5] * v[2],
        t[4] * v[0] + t[5] * v[1] + t[2] * v[2],
    );
}

// =============================================================================
// Tests
// =============================================================================

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

fn expectVec(want: Vec, got: Vec, tol: f32) !void {
    inline for (0..3) |k| {
        try expectApproxEqAbs(want[k], got[k], tol);
    }
}

test "urdf: rpy composes as Rz(yaw)·Ry(pitch)·Rx(roll)" {
    // ★ The conversion that decides whether every link is in the right pose. Checked by
    // what the rotation DOES to basis vectors, not by comparing quaternion components —
    // components can agree with a wrong convention that happens to share a sign pattern,
    // where the mapping of axes cannot.
    const quarter: f32 = pi * 0.5;

    // Roll alone: +90° about X sends +Y to +Z.
    try expectVec(vec(0, 0, 1), zm.rotate(quatFromRpy(vec(quarter, 0, 0)), vec(0, 1, 0)), 1.0e-6);
    // Pitch alone: +90° about Y sends +Z to +X.
    try expectVec(vec(1, 0, 0), zm.rotate(quatFromRpy(vec(0, quarter, 0)), vec(0, 0, 1)), 1.0e-6);
    // Yaw alone: +90° about Z sends +X to +Y.
    try expectVec(vec(0, 1, 0), zm.rotate(quatFromRpy(vec(0, 0, quarter)), vec(1, 0, 0)), 1.0e-6);

    // ★ The order, which is the part a wrong implementation gets wrong. Roll then yaw,
    // both 90°: R = Rz·Rx. Applied to +Y, Rx sends it to +Z, then Rz leaves +Z alone.
    // The other order (Rx·Rz) would send +Y to −X, so this single case separates them.
    try expectVec(
        vec(0, 0, 1),
        zm.rotate(quatFromRpy(vec(quarter, 0, quarter)), vec(0, 1, 0)),
        1.0e-6,
    );
}

test "urdf: the Z-up to Y-up rotation is exactly the axis swap it claims" {
    try expectVec(vec(0, 1, 0), zm.rotate(z_up_to_y_up, vec(0, 0, 1)), 1.0e-6); // up stays up
    try expectVec(vec(1, 0, 0), zm.rotate(z_up_to_y_up, vec(1, 0, 0)), 1.0e-6); // forward unchanged
    try expectVec(vec(0, 0, -1), zm.rotate(z_up_to_y_up, vec(0, 1, 0)), 1.0e-6);
}

test "urdf: a two-link arm imports with the tree, poses and axes intact" {
    const source: []const u8 =
        \\<?xml version="1.0"?>
        \\<robot name="toy">
        \\  <link name="base">
        \\    <inertial>
        \\      <mass value="3"/>
        \\      <origin xyz="0 0 0.05"/>
        \\      <inertia ixx="0.1" iyy="0.2" izz="0.3"/>
        \\    </inertial>
        \\    <collision><geometry><box size="0.2 0.2 0.1"/></geometry></collision>
        \\  </link>
        \\  <link name="upper"/>
        \\  <joint name="shoulder" type="revolute">
        \\    <origin xyz="0 0 0.1" rpy="0 0 0"/>
        \\    <parent link="base"/>
        \\    <child link="upper"/>
        \\    <axis xyz="0 1 0"/>
        \\    <limit lower="-1.5" upper="1.5" effort="10" velocity="2"/>
        \\    <dynamics damping="0.4"/>
        \\  </joint>
        \\</robot>
    ;
    var robot: Robot = try parse(std.testing.allocator, source, null);
    defer robot.deinit();

    try expectEqualStrings("toy", robot.name);
    try expectEqual(@as(usize, 2), robot.bodies.len);

    // Root first, carrying the axis conversion and nothing else.
    const base: Body = robot.bodies[0];
    try expectEqualStrings("base", base.name);
    try expect(base.parent == null);
    try expect(base.joint == null);
    try expectVec(vec_zero, base.pos, 1.0e-7);
    try expectVec(vec(0, 1, 0), zm.rotate(base.rot, vec(0, 0, 1)), 1.0e-6);

    // Mass properties come across verbatim; the origin is the COM, not a body offset.
    const inertial: Inertial = base.inertial.?;
    try expectApproxEqAbs(@as(f32, 3), inertial.mass, 1.0e-6);
    try expectVec(vec(0, 0, 0.05), inertial.pos, 1.0e-6);
    try expectApproxEqAbs(@as(f32, 0.2), inertial.full_inertia[1], 1.0e-6);
    // URDF gives full box extents; zimr wants half.
    try expectVec(vec(0.1, 0.1, 0.05), base.geoms[0].shape.box, 1.0e-6);

    // The child carries the JOINT's origin as its own pose — the convention that lines up
    // without algebra — and the axis is untouched because both express it in the child.
    const upper: Body = robot.bodies[1];
    try expectEqual(@as(?u32, 0), upper.parent);
    try expectVec(vec(0, 0, 0.1), upper.pos, 1.0e-6);
    const joint: Joint = upper.joint.?;
    try expectEqualStrings("shoulder", joint.name);
    try expectEqual(JointKind.hinge, joint.kind);
    try expectVec(vec(0, 1, 0), joint.axis, 1.0e-6);
    try expectApproxEqAbs(@as(f32, -1.5), joint.limit.?[0], 1.0e-6);
    try expectApproxEqAbs(@as(f32, 0.4), joint.damping, 1.0e-6);
}

test "urdf: a fixed joint becomes a body with no joint, not a special case" {
    const source: []const u8 =
        \\<robot name="welded">
        \\  <link name="a"/>
        \\  <link name="b"/>
        \\  <joint name="weld" type="fixed">
        \\    <origin xyz="0.3 0 0"/>
        \\    <parent link="a"/><child link="b"/>
        \\  </joint>
        \\</robot>
    ;
    var robot: Robot = try parse(std.testing.allocator, source, null);
    defer robot.deinit();
    const b: Body = robot.bodies[1];
    // Attached, positioned, and carrying no degrees of freedom — which is what a weld IS in
    // generalized coordinates rather than an approximation of one.
    try expectEqual(@as(?u32, 0), b.parent);
    try expectVec(vec(0.3, 0, 0), b.pos, 1.0e-6);
    try expect(b.joint == null);
}

test "urdf: a mimic joint is recorded, because it is a tendon" {
    const source: []const u8 =
        \\<robot name="gripper">
        \\  <link name="palm"/><link name="l"/><link name="r"/>
        \\  <joint name="drive" type="revolute">
        \\    <parent link="palm"/><child link="l"/><axis xyz="0 0 1"/>
        \\    <limit lower="0" upper="0.8"/>
        \\  </joint>
        \\  <joint name="follow" type="revolute">
        \\    <parent link="palm"/><child link="r"/><axis xyz="0 0 1"/>
        \\    <limit lower="0" upper="0.8"/>
        \\    <mimic joint="drive" multiplier="-1" offset="0"/>
        \\  </joint>
        \\</robot>
    ;
    var robot: Robot = try parse(std.testing.allocator, source, null);
    defer robot.deinit();
    var found: bool = false;
    for (robot.bodies) |body| {
        if (body.joint) |joint| {
            if (joint.mimic) |mimic| {
                try expectEqualStrings("drive", mimic.joint);
                try expectApproxEqAbs(@as(f32, -1), mimic.multiplier, 1.0e-6);
                found = true;
            }
        }
    }
    try expect(found);
}

test "urdf: a rotated inertial origin rotates the tensor into the body frame" {
    // ★ The gap §4i-bis found. URDF states the tensor in the `<inertial><origin>` frame;
    // zimr's spec has no orientation field, so the rotation must be applied HERE. A 90°
    // roll about X swaps the Y and Z moments — a check that fails loudly if the rotation is
    // skipped or applied transposed.
    const source: []const u8 =
        \\<robot name="tilted">
        \\  <link name="a">
        \\    <inertial>
        \\      <mass value="1"/>
        \\      <origin xyz="0 0 0" rpy="1.5707963 0 0"/>
        \\      <inertia ixx="1" iyy="2" izz="3"/>
        \\    </inertial>
        \\  </link>
        \\</robot>
    ;
    var robot: Robot = try parse(std.testing.allocator, source, null);
    defer robot.deinit();
    const i: [6]f32 = robot.bodies[0].inertial.?.full_inertia;
    try expectApproxEqAbs(@as(f32, 1), i[0], 1.0e-4); // xx untouched by a roll
    try expectApproxEqAbs(@as(f32, 3), i[1], 1.0e-4); // yy takes the old zz
    try expectApproxEqAbs(@as(f32, 2), i[2], 1.0e-4); // zz takes the old yy
    for (i[3..]) |off_diagonal| {
        try expectApproxEqAbs(@as(f32, 0), off_diagonal, 1.0e-4);
    }
}

test "urdf: malformed topology is refused rather than half-imported" {
    const cases = [_]struct { source: []const u8, err: anyerror }{
        // Two roots: usually a typo in a link name, and it silently makes half a robot.
        .{
            .source =
            \\<robot name="forest">
            \\  <link name="a"/><link name="b"/><link name="c"/>
            \\  <joint name="j" type="fixed"><parent link="a"/><child link="b"/></joint>
            \\</robot>
            ,
            .err = Error.NotATree,
        },
        // A joint naming a link that does not exist.
        .{
            .source =
            \\<robot name="ghost">
            \\  <link name="a"/>
            \\  <joint name="j" type="fixed"><parent link="a"/><child link="nope"/></joint>
            \\</robot>
            ,
            .err = Error.UnknownLink,
        },
        // A cycle: every link has a parent, so there is no root at all.
        .{
            .source =
            \\<robot name="loop">
            \\  <link name="a"/><link name="b"/>
            \\  <joint name="j1" type="fixed"><parent link="a"/><child link="b"/></joint>
            \\  <joint name="j2" type="fixed"><parent link="b"/><child link="a"/></joint>
            \\</robot>
            ,
            .err = Error.CyclicTree,
        },
        // A joint type we do not implement, refused rather than approximated.
        .{
            .source =
            \\<robot name="flat">
            \\  <link name="a"/><link name="b"/>
            \\  <joint name="j" type="planar"><parent link="a"/><child link="b"/></joint>
            \\</robot>
            ,
            .err = Error.Unsupported,
        },
        // ★ Two links sharing a name. Without the check the second is unreachable and
        // every joint naming it wires silently to the first — a robot that imports
        // "successfully" with the wrong topology.
        .{
            .source =
            \\<robot name="twins">
            \\  <link name="a"/><link name="b"/><link name="b"/>
            \\  <joint name="j" type="fixed"><parent link="a"/><child link="b"/></joint>
            \\</robot>
            ,
            .err = Error.BadName,
        },
        // Two joints sharing a name, same reasoning.
        .{
            .source =
            \\<robot name="twins2">
            \\  <link name="a"/><link name="b"/><link name="c"/>
            \\  <joint name="j" type="fixed"><parent link="a"/><child link="b"/></joint>
            \\  <joint name="j" type="fixed"><parent link="a"/><child link="c"/></joint>
            \\</robot>
            ,
            .err = Error.BadName,
        },
        // ★ A revolute joint with no <limit>. Defaulting the bounds to zero would weld it
        // shut, and a robot whose every joint is locked reads as a physics bug.
        .{
            .source =
            \\<robot name="unbounded">
            \\  <link name="a"/><link name="b"/>
            \\  <joint name="j" type="revolute">
            \\    <parent link="a"/><child link="b"/><axis xyz="0 0 1"/>
            \\  </joint>
            \\</robot>
            ,
            .err = Error.MissingField,
        },
        // A limit with lower above upper: an interval no joint can be inside.
        .{
            .source =
            \\<robot name="inverted">
            \\  <link name="a"/><link name="b"/>
            \\  <joint name="j" type="revolute">
            \\    <parent link="a"/><child link="b"/><axis xyz="0 0 1"/>
            \\    <limit lower="1" upper="-1"/>
            \\  </joint>
            \\</robot>
            ,
            .err = Error.BadNumber,
        },
        // A tuple of the wrong length, which would otherwise become a silent zero.
        .{
            .source =
            \\<robot name="short">
            \\  <link name="a"/><link name="b"/>
            \\  <joint name="j" type="fixed">
            \\    <origin xyz="1 2"/><parent link="a"/><child link="b"/>
            \\  </joint>
            \\</robot>
            ,
            .err = Error.BadNumber,
        },
    };
    for (cases) |case| {
        var diagnostic: Diagnostic = .{};
        try expectError(case.err, parse(std.testing.allocator, case.source, &diagnostic));
        // Every refusal must say something, or the error is useless in practice.
        try expect(diagnostic.detail.len > 0);
    }
}

test "hullPoints: a cube reduces to its eight corners, whatever the cloud" {
    // ★ The property that makes the reduction safe: the extreme point in any direction is
    // a corner, so a cube must come back as EXACTLY eight points however many interior or
    // face-centre vertices the mesh carried. Anything more means the deduplication is
    // broken; anything less means the sampling missed a corner.
    const gpa: Allocator = std.testing.allocator;
    var vertices: std.ArrayListUnmanaged(f32) = .empty;
    defer vertices.deinit(gpa);

    // Eight corners...
    for ([_]f32{ -1, 1 }) |x| {
        for ([_]f32{ -1, 1 }) |y| {
            for ([_]f32{ -1, 1 }) |z| {
                try vertices.appendSlice(gpa, &.{ x, y, z });
            }
        }
    }
    // ...plus a grid of interior and surface points that must all be discarded.
    var i: i32 = -4;
    while (i <= 4) : (i += 1) {
        const t_: f32 = float(i) / 5.0;
        try vertices.appendSlice(gpa, &.{ t_, t_, t_, t_, 0, 0, 0, t_, 0, 0, 0, t_ });
    }

    const points: []Vec = try hullPoints(gpa, vertices.items, 128);
    defer gpa.free(points);
    try expectEqual(@as(usize, 8), points.len);
    for (points) |p| {
        inline for (0..3) |k| {
            try expectApproxEqAbs(@as(f32, 1), @abs(p[k]), 1.0e-5);
        }
    }
}

test "hullPoints: a real KUKA collision mesh reduces by two orders of magnitude" {
    // ★ THE MEASUREMENT THAT JUSTIFIES THE WHOLE FUNCTION. 9114 vertices emitted verbatim
    // would be 347 KB of generated Zig per link — 2.7 MB for the arm — to describe a shape
    // with well under a hundred corners.
    const gpa: Allocator = std.testing.allocator;
    const bytes: []const u8 = @embedFile("tests/fixtures/robot/meshes/link_0.stl");
    const mesh: codecs.stl.Mesh = try codecs.stl.parse(gpa, bytes);
    defer mesh.deinit(gpa);
    try expectEqual(@as(usize, 3038 * 3), mesh.positions.len / 3);

    const points: []Vec = try hullPoints(gpa, mesh.positions, 128);
    defer gpa.free(points);

    // Two orders of magnitude smaller, and still a solid rather than a sliver.
    try expect(points.len >= 8);
    try expect(points.len <= 128);
    try expect(points.len * 50 < mesh.positions.len / 3);

    // ★ The reduction must not SHRINK the shape: the kept points are a subset of the
    // original cloud, so their bounding box can only be contained in the original's — and
    // for a hull it should very nearly EQUAL it, since the extreme point along each axis is
    // always a hull vertex and the direction set includes directions close to each axis.
    var mesh_lo: Vec = splat(1e9);
    var mesh_hi: Vec = splat(-1e9);
    var i: usize = 0;
    while (i < mesh.positions.len) : (i += 3) {
        const v: Vec = vec(mesh.positions[i], mesh.positions[i + 1], mesh.positions[i + 2]);
        mesh_lo = @min(mesh_lo, v);
        mesh_hi = @max(mesh_hi, v);
    }
    var kept_lo: Vec = splat(1e9);
    var kept_hi: Vec = splat(-1e9);
    for (points) |p| {
        kept_lo = @min(kept_lo, p);
        kept_hi = @max(kept_hi, p);
    }
    inline for (0..3) |k| {
        try expectApproxEqAbs(mesh_lo[k], kept_lo[k], 1.0e-4);
        try expectApproxEqAbs(mesh_hi[k], kept_hi[k], 1.0e-4);
    }
}

test "urdf: the real KUKA iiwa imports as a seven-DOF chain" {
    // ★ The whole point. A file written by someone else, for a different toolchain,
    // describing a robot that exists.
    const source: []const u8 = @embedFile("tests/fixtures/robot/kuka_iiwa.urdf");
    var diagnostic: Diagnostic = .{};
    var robot: Robot = parse(std.testing.allocator, source, &diagnostic) catch |err| {
        // The diagnostic is the whole point of a strict parser: a failure here should say
        // WHERE and WHY, not just that the import did not work.
        std.log.err("KUKA import failed: {t} — {s} (line {d})", .{
            err, diagnostic.detail, diagnostic.line,
        });
        return err;
    };
    defer robot.deinit();

    try expectEqualStrings("lbr_iiwa", robot.name);
    try expectEqual(@as(usize, 8), robot.bodies.len);

    // Parent-before-child ordering, which a consumer builds the tree in one pass on.
    for (robot.bodies, 0..) |body, i| {
        if (body.parent) |parent| {
            try expect(parent < i);
        } else {
            try expectEqual(@as(usize, 0), i); // exactly one root, and it is first
        }
    }

    // Seven revolute joints and mass on every link.
    var hinges: u32 = 0;
    for (robot.bodies) |body| {
        try expect(body.inertial != null);
        try expect(body.inertial.?.mass >= 0);
        if (body.joint) |joint| {
            try expectEqual(JointKind.hinge, joint.kind);
            try expect(joint.limit != null);
            hinges += 1;
        }
    }
    try expectEqual(@as(u32, 7), hinges);

    // The arm is about 1.3 m tall: summing the link offsets along the chain is a coarse but
    // real check that the poses were read rather than defaulted to zero.
    var reach: f32 = 0;
    for (robot.bodies) |body| {
        reach += length3(body.pos);
    }
    try expect(reach > 0.8);
    try expect(reach < 2.0);
}

// =============================================================================
// The emitter — urdf.Robot to Zig source
//
// ★ WHY GENERATE SOURCE RATHER THAN BUILD A MODEL AT RUNTIME.
//
// Three reasons, in order of weight. The generated model is COMPTIME-VALIDATED like any
// hand-written one, so an import bug becomes a compile error naming the body rather than a
// wrong number at runtime. No XML parser ships in the binary. And the output is a file that
// can be READ AND DIFFED — which is how a convention regression gets noticed, and the reason
// §4i-ter decided the generated file is checked in rather than treated as a build artifact.
//
// A runtime path stays possible and is deliberately not foreclosed: `urdf.Robot` is the
// single semantic representation and a runtime builder would consume the same value.
// =============================================================================

pub const EmitError = error{
    /// A `<mimic>` with a nonzero offset. A fixed tendon expresses
    /// `q_follower = multiplier · q_driver` exactly but not the affine `+ offset`, so this
    /// is refused rather than silently dropped. Almost every real mimic has offset zero;
    /// §1.1's rule says do not build the escape hatch until a model needs it.
    MimicOffsetUnsupported,
    /// A name that is not a valid Zig identifier. `Spec()` turns names into enum fields, so
    /// a dash or a dot would produce source that does not compile — better to say so here,
    /// naming the offender, than to emit a file that fails mysteriously.
    NameNotAnIdentifier,
    OutOfMemory,
} || std.Io.Writer.Error;

/// Write `robot` as a Zig source file defining `pub const spec` and `pub const Model`.
///
/// `import_path` is how the generated file reaches the robot engine. It is spliced in as an
/// EXPRESSION rather than a path, because the two places this model is emitted reach it
/// differently: a file inside `src/` says `@import("../../../robot.zig")`, while an example
/// reaches it through the module as `@import("zimr").robot`. Passing the whole expression
/// keeps the emitter from having to know which world it is writing for.
pub fn emitZig(
    writer: *std.Io.Writer,
    robot: *const Robot,
    source_name: []const u8,
    import_path: []const u8,
) EmitError!void {
    for (robot.bodies) |body| {
        try requireIdentifier(body.name);
        if (body.joint) |joint| {
            try requireIdentifier(joint.name);
            if (joint.mimic) |mimic| {
                if (mimic.offset != 0.0) {
                    return EmitError.MimicOffsetUnsupported;
                }
            }
        }
    }

    try writer.print(
        \\//! GENERATED from {s} by tools/urdf_import.zig. Do not edit by hand.
        \\//!
        \\//! Checked in rather than built on the fly: a generated model that is only a build
        \\//! artifact cannot be reviewed in a diff, and a diff is how a convention regression
        \\//! gets caught. Regenerate with `zig build urdf-import`.
        \\
        \\const rbt = {s};
        \\const zm = @import("zm");
        \\const vec = zm.vec;
        \\
        \\pub const spec: rbt.ModelSpec = .{{
        \\    .bodies = &.{{
        \\
    , .{ source_name, import_path });

    for (robot.bodies) |body| {
        try writer.print("        .{{\n            .name = \"{s}\",\n", .{body.name});
        if (body.parent) |parent| {
            try writer.print("            .parent = \"{s}\",\n", .{robot.bodies[parent].name});
        }
        try writer.print("            .pos = ", .{});
        try emitVec(writer, body.pos);
        try writer.print(",\n            .rot = ", .{});
        try emitQuat(writer, body.rot);
        try writer.print(",\n", .{});

        // A `fixed` URDF joint arrives here as no joint at all — a weld IS zero degrees of
        // freedom, so there is nothing to emit.
        if (body.joint) |joint| {
            try writer.print("            .joints = &.{{.{{\n", .{});
            try writer.print("                .name = \"{s}\",\n", .{joint.name});
            try writer.print("                .kind = .{s},\n", .{switch (joint.kind) {
                .hinge, .continuous => "hinge",
                .slide => "slide",
                .free => "free",
                .fixed => unreachable, // filtered above
            }});
            try writer.print("                .axis = ", .{});
            try emitVec(writer, joint.axis);
            try writer.print(",\n", .{});
            if (joint.limit) |limit| {
                try writer.print(
                    "                .range = .{{ {d}, {d} }},\n",
                    .{ limit[0], limit[1] },
                );
            }
            if (joint.damping != 0.0) {
                try writer.print("                .damping = {d},\n", .{joint.damping});
            }
            // ★ Armature, added by the importer rather than read from the file.
            //
            // URDF has no armature field: it describes the mechanism, not the gearbox. But
            // a real geared joint has rotor inertia, and without it a model with light
            // distal links is badly conditioned — which shows up as a solver that will not
            // converge rather than as anything recognisable. A small fraction of the
            // joint's own inertia is the rule §3b settled on, and stating it here beats
            // discovering it as instability.
            try writer.print("                .armature = {d},\n", .{default_armature});
            try writer.print("            }},}},\n", .{});
        }

        if (body.inertial) |inertial| {
            try writer.print("            .inertial = .{{\n", .{});
            try writer.print("                .mass = {d},\n", .{inertial.mass});
            try writer.print("                .pos = ", .{});
            try emitVec(writer, inertial.pos);
            try writer.print(",\n                .full_inertia = .{{ ", .{});
            for (inertial.full_inertia, 0..) |component, i| {
                try writer.print("{s}{d}", .{ if (i == 0) "" else ", ", component });
            }
            try writer.print(" }},\n            }},\n", .{});
        }

        var emitted_geoms: u32 = 0;
        for (body.geoms) |geom| {
            if (geom.shape == .mesh) {
                continue; // unresolved; counted and reported by the caller — see `meshCount`
            }
            if (emitted_geoms == 0) {
                try writer.print("            .geoms = &.{{\n", .{});
            }
            emitted_geoms += 1;
            // ★ ONE FIELD PER LINE, WITH TRAILING COMMAS. `zig fmt` collapses a struct
            // literal onto one line whenever it can, and a hull geom's closing line then
            // carries a bounds vector plus pos, rot and mass — 157 columns, over the 120
            // the linter enforces on every file including generated ones. A trailing comma
            // is how you tell `zig fmt` to keep it broken.
            try writer.print("                .{{\n                    .shape = ", .{});
            switch (geom.shape) {
                .box => |half| {
                    try writer.print(".{{ .box = .{{ .half_extent = ", .{});
                    try emitVec(writer, half);
                    try writer.print(" }} }}", .{});
                },
                .cylinder => |c| try writer.print(
                    ".{{ .cylinder = .{{ .half_height = {d}, .radius = {d} }} }}",
                    .{ c.half_height, c.radius },
                ),
                .sphere => |radius| try writer.print(
                    ".{{ .sphere = .{{ .radius = {d} }} }}",
                    .{radius},
                ),
                .hull => |points| {
                    // The point cloud, inline. `hullPoints` has already reduced a link's
                    // several thousand mesh vertices to under a hundred, which is what
                    // makes writing them into source reasonable at all.
                    try writer.print(".{{ .hull = .{{\n                        .points = &.{{\n", .{});
                    for (points) |point| {
                        try writer.print("                            ", .{});
                        try emitVec(writer, point);
                        try writer.print(",\n", .{});
                    }
                    try writer.print("                        }},\n", .{});
                    try writer.print("                        .bounds_half_extent = ", .{});
                    try emitVec(writer, boundsHalfExtent(points));
                    try writer.print(",\n                    }} }}", .{});
                },
                .mesh => unreachable,
            }
            try writer.print(",\n                    .pos = ", .{});
            try emitVec(writer, geom.pos);
            try writer.print(",\n                    .rot = ", .{});
            try emitQuat(writer, geom.rot);
            // ★ Mass comes from the <inertial>, so the geom must not contribute any.
            //
            // Without this the geom's density-derived mass would be ADDED to the stated
            // one — a body silently several times too heavy. `InertialSpec` replaces the
            // geom-derived properties entirely, so a zero here is belt and braces, but it
            // documents the intent at the point a reader would wonder.
            if (body.inertial != null) {
                try writer.print(",\n                    .mass = 0", .{});
            }
            try writer.print(",\n                }},\n", .{});
        }
        if (emitted_geoms > 0) {
            try writer.print("            }},\n", .{});
        }
        try writer.print("        }},\n", .{});
    }

    try writer.print("    }},\n", .{});

    // ---- tendons, from <mimic> ----
    var mimics: u32 = 0;
    for (robot.bodies) |body| {
        if (body.joint) |joint| {
            if (joint.mimic != null) {
                mimics += 1;
            }
        }
    }
    if (mimics > 0) {
        // ★ A mimic is a fixed tendon. `q_follower = multiplier · q_driver` rearranges to
        // `q_follower − multiplier · q_driver = 0`, which is a tendon of length zero over
        // the two joints with coefficients `(1, −multiplier)` — held exactly, for the cost
        // of a dot product, where an equality constraint would cost a solver row and hold
        // only approximately.
        try writer.print("    .tendons = &.{{\n", .{});
        for (robot.bodies) |body| {
            const joint: Joint = body.joint orelse continue;
            const mimic: @typeInfo(@FieldType(Joint, "mimic")).optional.child = joint.mimic orelse continue;
            try writer.print(
                "        .{{ .name = \"{s}_mimic\", .joints = &.{{\n",
                .{joint.name},
            );
            try writer.print(
                "            .{{ .name = \"{s}\", .coefficient = 1 }},\n",
                .{joint.name},
            );
            try writer.print(
                "            .{{ .name = \"{s}\", .coefficient = {d} }},\n",
                .{ mimic.joint, -mimic.multiplier },
            );
            try writer.print("        }} }},\n", .{});
        }
        try writer.print("    }},\n", .{});
    }

    try writer.print(
        \\}};
        \\
        \\pub const Model = rbt.Spec(spec);
        \\
    , .{});
}

/// Half the extent of a point cloud's axis-aligned bounding box — the hull's stand-in for
/// its true volume when computing mass properties. See `robot.GeomShape.hull`.
fn boundsHalfExtent(points: []const Vec) Vec {
    var lo: Vec = points[0];
    var hi: Vec = points[0];
    for (points) |p| {
        lo = @min(lo, p);
        hi = @max(hi, p);
    }
    return (hi - lo) * splat(0.5);
}

/// How many mesh geoms were skipped. Reported by the tool so a silent omission becomes a
/// visible one — §4i's rule is that an importer must never quietly drop something.
pub fn meshCount(robot: *const Robot) u32 {
    var count: u32 = 0;
    for (robot.bodies) |body| {
        for (body.geoms) |geom| {
            if (geom.shape == .mesh) {
                count += 1;
            }
        }
    }
    return count;
}

/// A small fraction of a typical link inertia. See the note at the emission site.
const default_armature: f32 = 0.01;

fn emitVec(writer: *std.Io.Writer, v: Vec) EmitError!void {
    try writer.print("vec(", .{});
    inline for (0..3) |k| {
        try writer.print("{s}", .{if (k == 0) "" else ", "});
        try emitFloat(writer, v[k]);
    }
    try writer.print(")", .{});
}

fn emitQuat(writer: *std.Io.Writer, q: Quat) EmitError!void {
    try writer.print(".{{ ", .{});
    inline for (0..4) |k| {
        try writer.print("{s}", .{if (k == 0) "" else ", "});
        try emitFloat(writer, q[k]);
    }
    try writer.print(" }}", .{});
}

/// One float, as Zig source.
///
/// ★ NEGATIVE ZERO IS THE TRAP. A rotation of exactly −90° produces components of `-0.0`,
/// and `{d}` prints that as `-0` — which Zig rejects outright as an ambiguous integer
/// literal, so the generated file does not compile at all. Loud, at least, but it fails at
/// the far end of the pipeline from the cause.
///
/// Normalising negative zero to zero is correct as well as convenient: the two are equal in
/// every arithmetic sense that matters here, and the sign carries no information about a
/// robot's geometry.
///
/// The `.0` suffix on whole numbers is the other half — `1` is an integer literal and `1.0`
/// a float one, and the difference matters when the value lands in a `@Vector(4, f32)`.
fn emitFloat(writer: *std.Io.Writer, value: f32) EmitError!void {
    const cleaned: f32 = if (value == 0.0) 0.0 else value;
    if (cleaned == @trunc(cleaned) and @abs(cleaned) < 1.0e9) {
        try writer.print("{d}.0", .{cleaned});
        return;
    }
    try writer.print("{d}", .{cleaned});
}

/// Names become enum fields in `Spec()`, so they must be valid Zig identifiers.
fn requireIdentifier(name: []const u8) EmitError!void {
    if (name.len == 0) {
        return EmitError.NameNotAnIdentifier;
    }
    if (std.ascii.isDigit(name[0])) {
        return EmitError.NameNotAnIdentifier;
    }
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') {
            return EmitError.NameNotAnIdentifier;
        }
    }
}
