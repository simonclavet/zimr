//! mjcf.zig — reading MuJoCo's own model format.
//!
//! ── ★ WHY THIS EXISTS WHEN URDF ALREADY WORKS ──
//!
//! The good robots live in MuJoCo Menagerie, and Menagerie is MJCF. URDF gets a robot's
//! LINKAGE across — bodies, joints, meshes — and stops there. MJCF carries the things that
//! decide whether a robot can actually be controlled: actuator force ranges, joint damping
//! and armature, contact parameters per geom, sensor definitions, and named keyframes to
//! start from. A quadruped imported from URDF is a shape; the same quadruped from MJCF is a
//! shape that can stand up.
//!
//! ── ★★ WHAT MAKES MJCF HARDER THAN URDF: `<default>` ──
//!
//! URDF states every value on the element that owns it. MJCF has an INHERITANCE TREE: a
//! `<default>` block sets values for a class, classes nest, a child class overrides its
//! parent field-by-field, and an element opts in with `class="name"` or inherits the
//! enclosing block's class implicitly. MuJoCo's own `humanoid.xml` has 21 nested `<default>`
//! blocks and most geoms state almost nothing locally:
//!
//!     <default>
//!       <default class="body">
//!         <geom type="capsule" friction=".7" solimp=".9 .99 .003"/>
//!         <default class="thigh">
//!           <geom size=".06"/>          <!-- inherits type, friction, solimp -->
//!         </default>
//!       </default>
//!     </default>
//!
//! So a reader that ignores defaults does not get a slightly-wrong model — it gets geoms with
//! no size, no type and no friction. **Resolution is the feature; the XML was the easy part.**
//!
//! This file does the resolution and nothing else yet. Turn 7 builds the body tree on top.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zm = @import("zm");
const codecs = @import("codecs.zig");
const urdf = @import("urdf.zig");

const Quat = zm.Quat;
const Vec = zm.Vec;
const pi = zm.pi;
const vec = zm.vec;
const splat = zm.splat;
const dot3 = zm.dot3;
const cross = zm.cross;
const normalize3 = zm.normalize3;
/// zm's `normalize` is generic over Vec and Quat alike (both are @Vector(4, f32)), so a
/// quaternion-flavoured name for it keeps call sites honest about what is being normalised.
const normalize = zm.normalize;
const length3 = zm.length3;
const vec_zero = zm.vec_zero;
const normalizeQuat = normalize;
const quatFromAxisAngle = zm.quatFromAxisAngle;
const qmul = zm.qmul;
const quat_identity = zm.quat_identity;

pub const Error = error{
    /// A `class="..."` naming a class that no `<default>` defines.
    UnknownClass,
    /// Two `<default class="x">` blocks at the same level, or a class name reused.
    DuplicateClass,
    /// `<default>` nested deeper than `max_depth`.
    DefaultsTooDeep,
    /// An attribute that should hold N numbers held fewer, or something unparseable.
    MalformedNumberList,
} || codecs.xml.Error || Allocator.Error;

/// How deeply `<default>` blocks may nest.
///
/// MuJoCo's own limit is 100 and `humanoid.xml` uses 3. A cap exists so a malformed file
/// cannot exhaust memory, and it is generous enough that no real model will meet it.
pub const max_depth: usize = 32;

/// One resolved set of attributes for one element kind, inside one class.
///
/// ★ STORED AS RAW ATTRIBUTE STRINGS, not parsed values, and that is deliberate. A class may
/// set `size=".06"` for a geom whose `type` comes from its grandparent; whether that size
/// means a radius, a half-extent or nothing at all is not knowable until both are in hand.
/// Resolving inheritance on strings and parsing once at the end keeps the two concerns apart
/// — and means an attribute this reader does not understand yet still inherits correctly
/// instead of being silently dropped.
pub const Attributes = struct {
    /// Name/value pairs, owned by the `Defaults` arena.
    pairs: []const Pair = &.{},

    pub const Pair = struct {
        name: []const u8,
        value: []const u8,
    };

    /// The value of one attribute, or null.
    pub fn get(self: Attributes, name: []const u8) ?[]const u8 {
        for (self.pairs) |pair| {
            if (std.mem.eql(u8, pair.name, name)) {
                return pair.value;
            }
        }
        return null;
    }
};

/// The element kinds `<default>` can carry. MJCF allows a default block for most element
/// types; these are the ones the importer will read.
/// ★ ONLY THE KINDS THIS IMPORTER ACTUALLY READS.
///
/// MJCF allows a `<default>` block for most element types. Listing them all here was the
/// obvious thing and the wrong one: five of the twelve were never consulted by anything, so
/// the enum advertised support that did not exist and a reader had no way to tell which
/// entries were real. `readClass` already skips unknown tags, so an unread kind costs
/// nothing by being absent — and the day one is needed, adding it is one line next to the
/// code that reads it.
pub const Kind = enum {
    geom,
    joint,
    motor,
    position,
    velocity,
    general,

    /// The MJCF tag name, which is the enum name — kept as a function so a rename cannot
    /// silently change the file format.
    pub fn tag(self: Kind) []const u8 {
        return @tagName(self);
    }

    pub fn fromTag(name: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, name);
    }
};

/// One class in the default tree, with its resolved attributes.
///
/// "Resolved" means inheritance has already been applied: reading `class.get(.geom, "type")`
/// gives the value an element of this class would see, whether it was stated here, in the
/// parent class, or at the root. That flattening happens once at parse time so lookups
/// during the import are a single scan.
pub const Class = struct {
    /// `""` for the unnamed root block.
    name: []const u8,
    /// Index of the enclosing class, or null for the root.
    parent: ?u32,
    /// Per-kind attributes, already merged with the parent's.
    by_kind: std.EnumArray(Kind, Attributes),

    pub fn get(self: *const Class, kind: Kind, attribute: []const u8) ?[]const u8 {
        return self.by_kind.get(kind).get(attribute);
    }
};

/// The whole `<default>` tree of one MJCF file, flattened.
pub const Defaults = struct {
    /// Owns every slice below.
    ///
    /// ── ★★★ A POINTER, AND NOT AS A STYLE CHOICE ──
    ///
    /// An `ArenaAllocator` is NOT movable once an `Allocator` has been taken from it: that
    /// allocator holds the arena struct's ADDRESS. Building into a stack-local arena and then
    /// returning the struct by value leaves every `Allocator` handed out during construction
    /// pointing at a dead frame — and `robot.zig` says exactly this, in the comment on
    /// `Model.arena`. These two functions did it anyway.
    ///
    /// ★ THE SYMPTOM WAS ABSURDLY INDIRECT: a 3324-byte leak, reported only in ReleaseSafe,
    /// only for the one fixture whose parse happened to grow the arena past a second buffer —
    /// because a single-buffer arena survives the move by luck and a two-buffer one does not.
    /// It cost most of two sessions, and the answer was written down in another file the whole
    /// time.
    arena: *std.heap.ArenaAllocator,
    classes: []Class,

    pub fn deinit(self: *Defaults) void {
        const gpa: Allocator = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }

    /// The root class — what an element with no `class` and no enclosing default sees.
    pub fn root(self: *const Defaults) *const Class {
        return &self.classes[0];
    }

    /// Look a class up by name. Returns null rather than erroring so a caller can decide
    /// whether an unknown class is a mistake or a shrug.
    pub fn byName(self: *const Defaults, name: []const u8) ?*const Class {
        for (self.classes) |*class| {
            if (std.mem.eql(u8, class.name, name)) {
                return class;
            }
        }
        return null;
    }

    /// What an element sees, given the class it names (or inherits from its enclosing body).
    ///
    /// ★ THE LOOKUP AN IMPORTER ACTUALLY WANTS. An element's own attributes win; anything it
    /// does not state comes from its class; anything the class does not state comes from the
    /// class's ancestors. Because `Class` is already flattened, that is two lookups rather
    /// than a walk.
    pub fn resolve(
        self: *const Defaults,
        class_name: ?[]const u8,
        kind: Kind,
        attribute: []const u8,
        stated: ?[]const u8,
    ) ?[]const u8 {
        if (stated) |value| {
            return value;
        }
        if (class_name) |name| {
            if (self.byName(name)) |class| {
                return class.get(kind, attribute);
            }
        }
        return self.root().get(kind, attribute);
    }
};

/// Read every `<default>` block in a parsed MJCF document and flatten the inheritance.
///
/// `doc` must outlive the returned `Defaults`: attribute values are slices INTO the source,
/// as everywhere else in `codecs`. Only the pair arrays are copied.
pub fn readDefaults(gpa: Allocator, doc: *const codecs.xml.Document) Error!Defaults {
    // Same reasoning as `Robot.arena`: the allocator taken below holds this struct's address.
    const arena: *std.heap.ArenaAllocator = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const a: Allocator = arena.allocator();

    var classes: std.ArrayListUnmanaged(Class) = .empty;
    // The root class always exists, even in a file with no `<default>` at all — that keeps
    // every caller on one path instead of branching on "are there defaults".
    try classes.append(a, .{
        .name = "",
        .parent = null,
        .by_kind = .initFill(.{}),
    });

    const mujoco: *const codecs.xml.Element = doc.rootElement();
    if (doc.child(mujoco, "default")) |top| {
        try readClass(a, doc, top, 0, &classes, 0);
    }

    return .{ .arena = arena, .classes = try classes.toOwnedSlice(a) };
}

/// Merge one `<default>` element into `classes[into]`, then recurse into nested blocks.
fn readClass(
    a: Allocator,
    doc: *const codecs.xml.Document,
    element: *const codecs.xml.Element,
    into: u32,
    classes: *std.ArrayListUnmanaged(Class),
    depth: usize,
) Error!void {
    if (depth >= max_depth) {
        return Error.DefaultsTooDeep;
    }

    for (doc.childrenOf(element)) |*child| {
        if (std.mem.eql(u8, child.name, "default")) {
            // A nested class. It STARTS as a copy of its parent — which is what makes
            // `Class` flat — and then its own attributes override field by field.
            const name: []const u8 = doc.attribute(child, "class") orelse "";
            if (name.len == 0) {
                // An unnamed nested default is not meaningful: there would be no way to
                // refer to it, and MJCF requires the name.
                return Error.UnknownClass;
            }
            for (classes.items) |existing| {
                if (std.mem.eql(u8, existing.name, name)) {
                    return Error.DuplicateClass;
                }
            }
            const index: u32 = @intCast(classes.items.len);
            try classes.append(a, .{
                .name = name,
                .parent = into,
                .by_kind = classes.items[into].by_kind,
            });
            try readClass(a, doc, child, index, classes, depth + 1);
            continue;
        }

        // An element kind's defaults. Unknown kinds are skipped rather than rejected: MJCF
        // has more element types than this importer reads, and a file using one it does not
        // understand is not thereby invalid.
        const kind: Kind = Kind.fromTag(child.name) orelse continue;
        var merged: std.ArrayListUnmanaged(Attributes.Pair) = .empty;
        try merged.appendSlice(a, classes.items[into].by_kind.get(kind).pairs);
        for (doc.attributes[child.attribute_start..][0..child.attribute_count]) |attr| {
            const attr_name: []const u8 = attr.name;
            const attr_value: []const u8 = attr.value;
            // Override in place if the parent already set it, so the pair list stays a set
            // and `get` can stop at the first match.
            var replaced: bool = false;
            for (merged.items) |*pair| {
                if (std.mem.eql(u8, pair.name, attr_name)) {
                    pair.value = attr_value;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) {
                try merged.append(a, .{ .name = attr_name, .value = attr_value });
            }
        }
        classes.items[into].by_kind.set(kind, .{ .pairs = try merged.toOwnedSlice(a) });
    }
}

// =============================================================================
// Tests
// =============================================================================

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const allocPrint = std.fmt.allocPrint;

test "mjcf defaults: a nested class inherits and overrides field by field" {
    // ★ THE SHAPE THAT MATTERS, taken from MuJoCo's own `humanoid.xml`: a geom in class
    // "thigh" states only its size, and must still come out with the type, friction and
    // solimp its grandparent set. A reader that ignores this does not get a slightly wrong
    // model — it gets geoms with no type and no size at all.
    const source: []const u8 =
        \\<mujoco>
        \\  <default>
        \\    <motor ctrlrange="-1 1" ctrllimited="true"/>
        \\    <default class="body">
        \\      <geom type="capsule" condim="1" friction=".7" solimp=".9 .99 .003"/>
        \\      <default class="thigh">
        \\        <geom size=".06"/>
        \\      </default>
        \\      <default class="foot">
        \\        <geom size=".027" friction="1.9"/>
        \\      </default>
        \\    </default>
        \\  </default>
        \\</mujoco>
    ;
    const gpa: Allocator = std.testing.allocator;
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, source, null);
    defer doc.deinit();
    var defaults: Defaults = try readDefaults(gpa, &doc);
    defer defaults.deinit();

    // Inherited two levels up, never stated in "thigh".
    const thigh: *const Class = defaults.byName("thigh").?;
    try expectEqualStrings("capsule", thigh.get(.geom, "type").?);
    try expectEqualStrings(".7", thigh.get(.geom, "friction").?);
    try expectEqualStrings(".9 .99 .003", thigh.get(.geom, "solimp").?);
    // Stated locally.
    try expectEqualStrings(".06", thigh.get(.geom, "size").?);

    // ★ "foot" OVERRIDES friction while inheriting everything else — field by field, not
    // block by block. Replacing the whole geom set would be the easy mistake and would
    // leave a foot with no type.
    const foot: *const Class = defaults.byName("foot").?;
    try expectEqualStrings("1.9", foot.get(.geom, "friction").?);
    try expectEqualStrings("capsule", foot.get(.geom, "type").?);
    try expectEqualStrings(".027", foot.get(.geom, "size").?);

    // Kinds are independent: the root's motor settings are not visible as geom settings,
    // and "body" never mentioned a motor but still sees the root's.
    const body: *const Class = defaults.byName("body").?;
    try expect(body.get(.geom, "ctrlrange") == null);
    try expectEqualStrings("-1 1", body.get(.motor, "ctrlrange").?);
}

test "mjcf defaults: an element's own attribute beats its class" {
    const source: []const u8 =
        \\<mujoco>
        \\  <default>
        \\    <default class="thing">
        \\      <geom type="box" size="1 1 1"/>
        \\    </default>
        \\  </default>
        \\</mujoco>
    ;
    const gpa: Allocator = std.testing.allocator;
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, source, null);
    defer doc.deinit();
    var defaults: Defaults = try readDefaults(gpa, &doc);
    defer defaults.deinit();

    // Stated wins.
    try expectEqualStrings(
        "sphere",
        defaults.resolve("thing", .geom, "type", "sphere").?,
    );
    // Not stated falls through to the class.
    try expectEqualStrings(
        "box",
        defaults.resolve("thing", .geom, "type", null).?,
    );
    // No class named, so the root — which says nothing about geoms here.
    try expect(defaults.resolve(null, .geom, "type", null) == null);
}

test "mjcf defaults: a file with no default block still resolves" {
    // The root class exists unconditionally, so an importer never branches on "are there
    // defaults" — it asks the same question and gets null.
    const gpa: Allocator = std.testing.allocator;
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, "<mujoco><worldbody/></mujoco>", null);
    defer doc.deinit();
    var defaults: Defaults = try readDefaults(gpa, &doc);
    defer defaults.deinit();
    try expectEqual(@as(usize, 1), defaults.classes.len);
    try expect(defaults.root().get(.geom, "type") == null);
}

test "mjcf defaults: a duplicate class name is rejected" {
    // ★ REJECTED RATHER THAN LAST-WINS. Two classes with one name means every `class="x"`
    // in the file is ambiguous, and silently picking one produces a model that is wrong in
    // a way no reader would think to check. The URDF importer rejects duplicate link names
    // for the same reason (§4i).
    const source: []const u8 =
        \\<mujoco>
        \\  <default>
        \\    <default class="a"><geom size="1"/></default>
        \\    <default class="a"><geom size="2"/></default>
        \\  </default>
        \\</mujoco>
    ;
    const gpa: Allocator = std.testing.allocator;
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, source, null);
    defer doc.deinit();
    try expectError(Error.DuplicateClass, readDefaults(gpa, &doc));
}

test "mjcf defaults: an unnamed nested default is rejected" {
    // There would be no way to refer to it, so it can only be a mistake.
    const source: []const u8 =
        \\<mujoco>
        \\  <default>
        \\    <default><geom size="1"/></default>
        \\  </default>
        \\</mujoco>
    ;
    const gpa: Allocator = std.testing.allocator;
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, source, null);
    defer doc.deinit();
    try expectError(Error.UnknownClass, readDefaults(gpa, &doc));
}

test "mjcf defaults: MuJoCo's own humanoid.xml, against numbers MuJoCo reports" {
    // ★★ THE REAL FILE, not a fixture. `humanoid.xml` has 21 nested `<default>` blocks and
    // is the model MuJoCo itself ships as a reference, so it exercises the inheritance the
    // way real models do.
    //
    // The expected values below are what `mujoco.MjModel.from_xml_path` reports for the same
    // file — `geom_solimp[1] = [0.9, 0.99, 0.003, 0.5, 2.0]` and `geom_friction[1] =
    // [0.7, 0.005, 0.0001]`. Those come from a class two levels up, so agreeing with them is
    // evidence the flattening is right rather than just self-consistent.
    const source: []const u8 = @embedFile("tests/fixtures/robot/humanoid.xml");
    const gpa: Allocator = std.testing.allocator;
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, source, null);
    defer doc.deinit();
    var defaults: Defaults = try readDefaults(gpa, &doc);
    defer defaults.deinit();

    // The classes the file declares, resolved rather than merely present.
    const body: *const Class = defaults.byName("body").?;
    try expectEqualStrings("capsule", body.get(.geom, "type").?);
    try expectEqualStrings(".7", body.get(.geom, "friction").?);
    try expectEqualStrings(".9 .99 .003", body.get(.geom, "solimp").?);
    try expectEqualStrings(".015 1", body.get(.geom, "solref").?);

    // Two levels down: size stated locally, everything else inherited.
    const thigh: *const Class = defaults.byName("thigh").?;
    try expectEqualStrings(".06", thigh.get(.geom, "size").?);
    try expectEqualStrings("capsule", thigh.get(.geom, "type").?);
    try expectEqualStrings(".9 .99 .003", thigh.get(.geom, "solimp").?);

    // And the root's motor block, which the actuators depend on.
    try expectEqualStrings("-1 1", defaults.root().get(.motor, "ctrlrange").?);
}

// =============================================================================
// The body tree — turn 7
// =============================================================================

/// How angles in the source are to be read.
///
/// ★★ MJCF DEFAULTS TO DEGREES. URDF is radians and always radians; MJCF has a compiler
/// switch whose DEFAULT is degrees, so `range="-30 10"` on a joint means ±half a radian, and
/// MuJoCo's built model reports `[-0.5236, 0.1745]` for exactly that line in `humanoid.xml`.
///
/// A reader that assumes radians does not fail loudly — it produces a robot whose joints have
/// 57x the intended range, which looks like a robot that can bend its knee backwards. Read
/// from `<compiler angle="...">` and applied to every angular quantity: joint ranges, `euler`,
/// and `axisangle`'s angle (but NOT its axis).
pub const AngleUnit = enum {
    degree,
    radian,

    pub fn toRadians(self: AngleUnit, value: f32) f32 {
        return switch (self) {
            .degree => value * pi / 180.0,
            .radian => value,
        };
    }
};

/// Compiler-level settings that change how the rest of the file is read.
pub const Compiler = struct {
    angle: AngleUnit = .degree,
    /// Euler convention, as three axis letters. MuJoCo's default is "xyz", applied as
    /// INTRINSIC rotations in that order.
    euler_seq: [3]u8 = .{ 'x', 'y', 'z' },
    /// Directory that `<mesh file=...>` paths are relative to, from `<compiler meshdir=...>`.
    /// Empty means alongside the model file, which is MJCF's default.
    mesh_dir: []const u8 = "",

    pub fn read(doc: *const codecs.xml.Document) Compiler {
        var self: Compiler = .{};
        const element: *const codecs.xml.Element = doc.child(doc.rootElement(), "compiler") orelse return self;
        if (doc.attribute(element, "angle")) |value| {
            if (std.mem.eql(u8, value, "radian")) {
                self.angle = .radian;
            }
        }
        if (doc.attribute(element, "meshdir")) |value| {
            self.mesh_dir = value;
        }
        if (doc.attribute(element, "eulerseq")) |value| {
            if (value.len == 3) {
                self.euler_seq = .{ value[0], value[1], value[2] };
            }
        }
        return self;
    }
};

/// Read an element's orientation, whichever of MJCF's five spellings it used.
///
/// ── ★ FIVE WAYS TO SAY THE SAME THING, and real models use four of them ──
///
/// Counted across MuJoCo's own model directory: `euler` 184 times, `zaxis` 37, `xyaxes` 15,
/// `quat` 4. A reader that handles only `quat` — the one a programmer would design — would
/// silently mis-orient the overwhelming majority of real elements, because a missing
/// orientation attribute is indistinguishable from an identity one.
///
/// The five, and what each means:
///
///   * `quat="w x y z"` — MuJoCo's order is W FIRST, zm's is w last. Reversing this is a
///     rotation that looks almost right, which is the worst kind of wrong.
///   * `euler="a b c"` — intrinsic rotations about the axes named by `eulerseq`, in the
///     file's angle unit.
///   * `axisangle="x y z a"` — an axis (never converted) and an angle (always converted).
///   * `zaxis="x y z"` — the rotation taking +Z to this direction, by the shortest path.
///   * `xyaxes="x1 y1 z1 x2 y2 z2"` — the first two columns of the rotation matrix; the
///     third is their cross product. The Y column is re-orthogonalised against X because
///     files state it approximately.
pub fn readOrientation(
    doc: *const codecs.xml.Document,
    element: *const codecs.xml.Element,
    compiler: Compiler,
) !Quat {
    inline for (.{ "quat", "euler", "axisangle", "zaxis", "xyaxes" }) |name| {
        if (doc.attribute(element, name)) |text| {
            return orientationFrom(name, text, compiler);
        }
    }
    return quat_identity;
}

/// Turn one orientation attribute into a quaternion.
///
/// Split out so the plain-element path and the class-resolving path cannot drift: there is
/// one implementation of each spelling, and adding a sixth means touching one place.
fn orientationFrom(
    comptime name: []const u8,
    text: []const u8,
    compiler: Compiler,
) !Quat {
    if (comptime std.mem.eql(u8, name, "quat")) {
        var v: [4]f32 = undefined;
        try readFloats(text, &v);
        // ★ MuJoCo stores (w, x, y, z); zm stores (x, y, z, w).
        return normalizeQuat(Quat{ v[1], v[2], v[3], v[0] });
    }
    if (comptime std.mem.eql(u8, name, "euler")) {
        var v: [3]f32 = undefined;
        try readFloats(text, &v);
        var q: Quat = quat_identity;
        for (compiler.euler_seq, 0..) |axis_letter, i| {
            const axis: Vec = switch (axis_letter) {
                'x', 'X' => vec(1, 0, 0),
                'y', 'Y' => vec(0, 1, 0),
                else => vec(0, 0, 1),
            };
            // Intrinsic: each rotation is about the axis as already rotated, which is
            // right-multiplication.
            q = qmul(q, quatFromAxisAngle(axis, compiler.angle.toRadians(v[i])));
        }
        return normalizeQuat(q);
    }
    if (comptime std.mem.eql(u8, name, "axisangle")) {
        var v: [4]f32 = undefined;
        try readFloats(text, &v);
        // The AXIS is a direction and never converted; only the angle is.
        return quatFromAxisAngle(
            normalize3(vec(v[0], v[1], v[2])),
            compiler.angle.toRadians(v[3]),
        );
    }
    if (comptime std.mem.eql(u8, name, "zaxis")) {
        var v: [3]f32 = undefined;
        try readFloats(text, &v);
        return shortestArc(vec(0, 0, 1), normalize3(vec(v[0], v[1], v[2])));
    }
    if (comptime std.mem.eql(u8, name, "xyaxes")) {
        var v: [6]f32 = undefined;
        try readFloats(text, &v);
        const x: Vec = normalize3(vec(v[0], v[1], v[2]));
        var y: Vec = vec(v[3], v[4], v[5]);
        // Re-orthogonalise: files state the second axis approximately, and a rotation matrix
        // built from non-orthogonal columns is not a rotation.
        y = normalize3(y - x * splat(dot3(x, y)));
        const z: Vec = cross(x, y);
        return normalizeQuat(zm.quatFromMat(.{
            Vec{ x[0], x[1], x[2], 0 },
            Vec{ y[0], y[1], y[2], 0 },
            Vec{ z[0], z[1], z[2], 0 },
            Vec{ 0, 0, 0, 1 },
        }));
    }
    return quat_identity;
}

/// The shortest rotation taking `from` to `to`, both unit.
fn shortestArc(from: Vec, to: Vec) Quat {
    const d: f32 = dot3(from, to);
    if (d > 0.999999) {
        return quat_identity;
    }
    if (d < -0.999999) {
        // Antiparallel: any perpendicular axis will do, so pick one that cannot be
        // degenerate by crossing with whichever cardinal axis `from` is least aligned to.
        const fallback: Vec = if (@abs(from[0]) < 0.9) vec(1, 0, 0) else vec(0, 1, 0);
        return quatFromAxisAngle(normalize3(cross(from, fallback)), pi);
    }
    const axis: Vec = cross(from, to);
    return normalizeQuat(Quat{ axis[0], axis[1], axis[2], 1.0 + d });
}

/// A three-vector attribute, resolved through the class chain.
fn resolveVec(
    defaults: *const Defaults,
    class: []const u8,
    kind: Kind,
    attribute: []const u8,
    stated: ?[]const u8,
) Error!Vec {
    const text: []const u8 = defaults.resolve(class, kind, attribute, stated) orelse return vec_zero;
    var v: [3]f32 = undefined;
    try readFloats(text, &v);
    return vec(v[0], v[1], v[2]);
}

/// An orientation, resolved through the class chain — all five spellings.
///
/// ★ THE SPELLINGS ARE MUTUALLY EXCLUSIVE AND CHECKED IN PRIORITY ORDER, so a class stating
/// `euler` cannot be half-overridden by an element stating `quat`: the first spelling that
/// resolves wins outright, exactly as `readOrientation` does for a bare element.
fn resolveOrientation(
    doc: *const codecs.xml.Document,
    element: *const codecs.xml.Element,
    class: []const u8,
    defaults: *const Defaults,
    compiler: Compiler,
) Error!Quat {
    inline for (.{ "quat", "euler", "axisangle", "zaxis", "xyaxes" }) |name| {
        if (defaults.resolve(class, .geom, name, doc.attribute(element, name))) |text| {
            return orientationFrom(name, text, compiler);
        }
    }
    return quat_identity;
}

/// Read exactly `out.len` whitespace-separated floats.
/// Read as many numbers as are present, leaving the rest untouched.
///
/// ★ SHORTER IS LEGAL FOR A COEFFICIENT LIST, where the omitted terms mean zero — `polycoef`
/// is usually written `"0 -1"` rather than `"0 -1 0 0 0"`. `readFloats` is the strict form and
/// stays that way: a `pos` with two numbers is a mistake, not an abbreviation, and the two
/// cases must not share a reader.
fn readFloatsUpTo(text: []const u8, out: []f32) !void {
    var it = std.mem.tokenizeAny(u8, text, " \t\n\r");
    for (out) |*slot| {
        const token: []const u8 = it.next() orelse return;
        slot.* = std.fmt.parseFloat(f32, token) catch return Error.MalformedNumberList;
    }
}

fn readFloats(text: []const u8, out: []f32) !void {
    var it = std.mem.tokenizeAny(u8, text, " \t\n\r");
    for (out) |*slot| {
        const token: []const u8 = it.next() orelse return Error.MalformedNumberList;
        slot.* = std.fmt.parseFloat(f32, token) catch return Error.MalformedNumberList;
    }
}

test "mjcf: every orientation spelling, against quaternions MuJoCo itself reports" {
    // ★★ THE NUMBERS BELOW CAME FROM MuJoCo 3.11.0, one `from_xml_string` per row, not from
    // deriving what they ought to be. Orientation is where a reader is quietly wrong: a
    // rotation built with the wrong quaternion order, or degrees read as radians, produces a
    // model that looks plausible and is bent.
    //
    // Counted across MuJoCo's own model directory: `euler` appears 184 times, `zaxis` 37,
    // `xyaxes` 15, `quat` 4. Handling only `quat` — the one a programmer would design for —
    // would mis-orient almost every real element.
    const gpa: Allocator = std.testing.allocator;
    const Case = struct {
        attribute: []const u8,
        // MuJoCo's order: w first.
        expect_wxyz: [4]f32,
    };
    const cases = [_]Case{
        .{ .attribute = "euler=\"30 0 0\"", .expect_wxyz = .{ 0.965926, 0.258819, 0, 0 } },
        .{ .attribute = "euler=\"10 20 30\"", .expect_wxyz = .{ 0.943714, 0.127679, 0.144878, 0.268536 } },
        .{ .attribute = "axisangle=\"0 1 0 45\"", .expect_wxyz = .{ 0.92388, 0, 0.382683, 0 } },
        .{ .attribute = "zaxis=\"1 0 0\"", .expect_wxyz = .{ 0.707107, 0, 0.707107, 0 } },
        .{ .attribute = "xyaxes=\"0 1 0 -1 0 0\"", .expect_wxyz = .{ 0.707107, 0, 0, 0.707107 } },
        .{ .attribute = "quat=\".7071 0 .7071 0\"", .expect_wxyz = .{ 0.707107, 0, 0.707107, 0 } },
    };

    for (cases) |case| {
        const source: []const u8 = try allocPrint(
            gpa,
            "<mujoco><worldbody><body {s}/></worldbody></mujoco>",
            .{case.attribute},
        );
        defer gpa.free(source);
        var doc: codecs.xml.Document = try codecs.xml.parse(gpa, source, null);
        defer doc.deinit();
        const world: *const codecs.xml.Element = doc.child(doc.rootElement(), "worldbody").?;
        const body: *const codecs.xml.Element = doc.child(world, "body").?;
        const got: Quat = try readOrientation(&doc, body, .{});

        // zm stores (x, y, z, w); MuJoCo (w, x, y, z). A quaternion and its negation are the
        // same rotation, so compare with whichever sign matches.
        const want: Quat = .{
            case.expect_wxyz[1],
            case.expect_wxyz[2],
            case.expect_wxyz[3],
            case.expect_wxyz[0],
        };
        const flip: f32 = if (dot3(got, want) + got[3] * want[3] < 0) -1.0 else 1.0;
        inline for (0..4) |k| {
            // The attribute is named in the failure so a regression says WHICH spelling
            // broke, not merely that a quaternion component differs.
            expectApproxEqAbs(want[k], got[k] * flip, 1.0e-4) catch |err| {
                std.log.err("orientation {s}: component {d}", .{ case.attribute, k });
                return err;
            };
        }
    }
}

test "mjcf: degrees are the default, and the humanoid proves it" {
    // ★ THE TRAP. `humanoid.xml` says `range="-30 10"` on class `hip_x`; MuJoCo's built model
    // reports `[-0.5236, 0.1745]` radians. A reader assuming radians gives that joint 57x the
    // range it should have, which does not fail — it produces a knee that bends backwards.
    try expectApproxEqAbs(
        @as(f32, -0.5236),
        AngleUnit.degree.toRadians(-30.0),
        1.0e-4,
    );
    try expectApproxEqAbs(
        @as(f32, 0.1745),
        AngleUnit.degree.toRadians(10.0),
        1.0e-4,
    );
    // And `angle="radian"` turns the conversion off rather than scaling it differently.
    try expectEqual(@as(f32, -30.0), AngleUnit.radian.toRadians(-30.0));

    // The humanoid states no `<compiler angle=...>`, so it must come out as degrees.
    const gpa: Allocator = std.testing.allocator;
    const source: []const u8 = @embedFile("tests/fixtures/robot/humanoid.xml");
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, source, null);
    defer doc.deinit();
    try expectEqual(AngleUnit.degree, Compiler.read(&doc).angle);
}

/// One body of the parsed tree, in MJCF's own terms.
///
/// A faithful reading of the file, not yet a `robot.Model` — the same split `urdf.zig` uses,
/// so the conversion to engine types is one reviewable step rather than being tangled through
/// the parser.
pub const Body = struct {
    name: []const u8,
    /// Index into `Robot.bodies`, or null for a child of `<worldbody>`.
    parent: ?u32,
    /// Pose relative to the parent.
    pos: Vec = vec_zero,
    rot: Quat = quat_identity,
    /// Spans into `Robot.joints` and `Robot.geoms`.
    /// Stated mass properties, if the body gives an `<inertial>`. Null means "derive from
    /// the geoms", which is MJCF's own rule and is right for a body that states nothing.
    inertial: ?Inertial = null,
    joint_start: u32 = 0,
    joint_count: u32 = 0,
    geom_start: u32 = 0,
    geom_count: u32 = 0,
};

pub const JointType = enum { free, ball, slide, hinge };

pub const Joint = struct {
    name: []const u8,
    kind: JointType = .hinge,
    /// Axis in the body's frame. Meaningless for `free` and `ball`.
    axis: Vec = vec(0, 0, 1),
    /// Anchor in the body's frame.
    pos: Vec = vec_zero,
    /// Already converted to radians (or metres, for a slide).
    range: ?[2]f32 = null,
    damping: f32 = 0,
    armature: f32 = 0,
    stiffness: f32 = 0,
};

pub const GeomType = enum { plane, sphere, capsule, ellipsoid, cylinder, box, mesh };

pub const Geom = struct {
    name: []const u8,
    kind: GeomType = .sphere,
    /// MJCF's `size`, meaning whatever that type says it means.
    size: [3]f32 = .{ 0, 0, 0 },
    pos: Vec = vec_zero,
    rot: Quat = quat_identity,
    /// Sliding friction. MJCF states three (slide, spin, roll); the engine uses the first two.
    friction: f32 = 1.0,
    /// Explicit mass or density, if stated.
    mass: ?f32 = null,
    density: f32 = 1000.0,
    /// For `mesh`, the asset name.
    mesh: []const u8 = "",
    /// Filled by `resolveMeshes`: the point cloud whose convex hull this geom collides as.
    ///
    /// ★ A CLOUD, NOT A BUILT HULL — the same call `urdf.zig` makes and for the same reason:
    /// `robot.zig` depends only on `zimrmath` and has no hull builder, so the engine takes
    /// points and zimrphysics builds the hull when it makes the proxy.
    hull: []const Vec = &.{},
};

pub const Robot = struct {
    /// Owns every slice below.
    ///
    /// ── ★★★ A POINTER, AND NOT AS A STYLE CHOICE ──
    ///
    /// An `ArenaAllocator` is NOT movable once an `Allocator` has been taken from it: that
    /// allocator holds the arena struct's ADDRESS. Building into a stack-local arena and then
    /// returning the struct by value leaves every `Allocator` handed out during construction
    /// pointing at a dead frame — and `robot.zig` says exactly this, in the comment on
    /// `Model.arena`. These two functions did it anyway.
    ///
    /// ★ THE SYMPTOM WAS ABSURDLY INDIRECT: a 3324-byte leak, reported only in ReleaseSafe,
    /// only for the one fixture whose parse happened to grow the arena past a second buffer —
    /// because a single-buffer arena survives the move by luck and a two-buffer one does not.
    /// It cost most of two sessions, and the answer was written down in another file the whole
    /// time.
    arena: *std.heap.ArenaAllocator,
    name: []const u8,
    compiler: Compiler,
    bodies: []Body,
    joints: []Joint,
    geoms: []Geom,
    actuators: []Actuator,
    keyframes: []Keyframe,
    /// Body pairs that must never collide, from `<contact><exclude body1="" body2=""/>` - MuJoCo's way to
    /// spare two bodies that are NOT adjacent (adjacent ones are spared anyway) but overlap by design.
    excludes: []const Exclude = &.{},
    /// `<asset>`'s meshes, by the name geoms refer to them by. The vertices are NOT loaded —
    /// see `MeshAsset`.
    meshes: []MeshAsset,
    /// `<sensor>` entries this engine can compute; the rest are skipped.
    sensors: []Sensor,
    /// Named frames instruments are mounted on. See `Site`.
    sites: []Site,
    /// Loop closures — `<equality type="connect">`. See `Equality`.
    equalities: []Equality,

    pub fn deinit(self: *Robot) void {
        const gpa: Allocator = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }
};

/// Read the whole `<worldbody>` tree, resolving every default as it goes.
///
/// ── ★ `doc` AND ITS SOURCE MUST OUTLIVE THE RETURNED `Robot` ──
///
/// Every name in the result — body names, joint names, the mesh an actuator refers to — is a
/// slice INTO the file's bytes, as everywhere else in `codecs`. The `Robot`'s arena owns the
/// arrays, not the strings in them.
///
/// This is stated here rather than only on `readDefaults` because `readRobot` is the function
/// callers actually reach for, and a use-after-free of a body name is the kind of bug that
/// surfaces as a garbled error message months later. In practice the source is an `@embedFile`
/// and outlives everything, which is exactly why the requirement is easy to forget.
pub fn readRobot(gpa: Allocator, doc: *const codecs.xml.Document) Error!Robot {
    // ★ HEAP-ALLOCATED SO ITS ADDRESS SURVIVES THE RETURN — see `Robot.arena`.
    const arena: *std.heap.ArenaAllocator = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const a: Allocator = arena.allocator();

    var defaults: Defaults = try readDefaults(gpa, doc);
    defer defaults.deinit();

    const compiler: Compiler = Compiler.read(doc);
    var bodies: std.ArrayListUnmanaged(Body) = .empty;
    var joints: std.ArrayListUnmanaged(Joint) = .empty;
    var geoms: std.ArrayListUnmanaged(Geom) = .empty;
    var sites: std.ArrayListUnmanaged(Site) = .empty;

    const root: *const codecs.xml.Element = doc.rootElement();
    if (doc.child(root, "worldbody")) |world| {
        for (doc.childrenOf(world)) |*child| {
            if (!std.mem.eql(u8, child.name, "body")) {
                continue;
            }
            try readBody(a, doc, child, null, "", &defaults, compiler, &bodies, &joints, &geoms, &sites, 0);
        }
    }

    // ★ SITES AND BODIES ARE OWNED FIRST, because `<equality>`'s site form resolves against
    // both — `site1`/`site2` name points whose BODIES are what the closure actually ties.
    const owned_bodies: []Body = try bodies.toOwnedSlice(a);
    const owned_sites: []Site = try sites.toOwnedSlice(a);

    return .{
        .arena = arena,
        .name = doc.attribute(root, "model") orelse "",
        .compiler = compiler,
        .bodies = owned_bodies,
        .joints = try joints.toOwnedSlice(a),
        .geoms = try geoms.toOwnedSlice(a),
        .actuators = try readActuators(a, doc, &defaults),
        .keyframes = try readKeyframes(a, doc),
        .excludes = try readExcludes(a, doc),
        .meshes = try readMeshAssets(a, doc),
        .sensors = try readSensors(a, doc),
        .sites = owned_sites,
        .equalities = try readEqualities(a, doc, owned_sites, owned_bodies),
    };
}

fn readBody(
    a: Allocator,
    doc: *const codecs.xml.Document,
    element: *const codecs.xml.Element,
    parent: ?u32,
    inherited_class: []const u8,
    defaults: *const Defaults,
    compiler: Compiler,
    bodies: *std.ArrayListUnmanaged(Body),
    joints: *std.ArrayListUnmanaged(Joint),
    geoms: *std.ArrayListUnmanaged(Geom),
    sites: *std.ArrayListUnmanaged(Site),
    depth: usize,
) Error!void {
    if (depth >= max_depth) {
        return Error.DefaultsTooDeep;
    }

    // ★ `childclass` SETS THE DEFAULT CLASS FOR EVERYTHING BELOW, not just this body.
    // `humanoid.xml` opens with `<body name="torso" childclass="body">` and then states
    // almost nothing on its geoms for the rest of the file — every one of them inherits
    // through this. A reader that treats `childclass` as applying only to the body it sits on
    // gets geoms with no type and no size.
    const child_class: []const u8 = doc.attribute(element, "childclass") orelse inherited_class;

    const index: u32 = @intCast(bodies.items.len);
    try bodies.append(a, .{
        .name = doc.attribute(element, "name") orelse "",
        .parent = parent,
        .pos = try readVec(doc, element, "pos", vec_zero),
        .rot = try readOrientation(doc, element, compiler),
        .inertial = try readInertial(doc, element, compiler),
        .joint_start = @intCast(joints.items.len),
        .geom_start = @intCast(geoms.items.len),
    });

    var joint_count: u32 = 0;
    var geom_count: u32 = 0;
    for (doc.childrenOf(element)) |*child| {
        if (std.mem.eql(u8, child.name, "joint")) {
            try joints.append(a, try readJoint(doc, child, child_class, defaults, compiler));
            joint_count += 1;
        } else if (std.mem.eql(u8, child.name, "freejoint")) {
            // Shorthand for `<joint type="free"/>`, and it takes no other attributes —
            // a free joint has no axis, no range and no anchor to state.
            try joints.append(a, .{
                .name = doc.attribute(child, "name") orelse "",
                .kind = .free,
            });
            joint_count += 1;
        } else if (std.mem.eql(u8, child.name, "geom")) {
            try geoms.append(a, try readGeom(doc, child, child_class, defaults, compiler));
            geom_count += 1;
        } else if (std.mem.eql(u8, child.name, "site")) {
            // ★ SITES CARRY THE SAME FIVE ORIENTATION SPELLINGS as bodies and geoms, so they
            // go through `readOrientation` rather than reading `quat` directly — a site given
            // `euler` or `zaxis` is perfectly legal and reasonably common on sensor mounts.
            try sites.append(a, .{
                .name = doc.attribute(child, "name") orelse "",
                .body = @intCast(index),
                .pos = try readVec(doc, child, "pos", vec_zero),
                .rot = try readOrientation(doc, child, compiler),
            });
        }
    }
    bodies.items[index].joint_count = joint_count;
    bodies.items[index].geom_count = geom_count;

    // Children last, so each body's own joints and geoms stay contiguous.
    for (doc.childrenOf(element)) |*child| {
        if (std.mem.eql(u8, child.name, "body")) {
            try readBody(
                a,
                doc,
                child,
                index,
                child_class,
                defaults,
                compiler,
                bodies,
                joints,
                geoms,
                sites,
                depth + 1,
            );
        }
    }
}

fn readJoint(
    doc: *const codecs.xml.Document,
    element: *const codecs.xml.Element,
    class: []const u8,
    defaults: *const Defaults,
    compiler: Compiler,
) Error!Joint {
    const own: ?[]const u8 = doc.attribute(element, "class");
    const use: []const u8 = own orelse class;
    var self: Joint = .{ .name = doc.attribute(element, "name") orelse "" };

    if (defaults.resolve(use, .joint, "type", doc.attribute(element, "type"))) |text| {
        self.kind = std.meta.stringToEnum(JointType, text) orelse .hinge;
    }
    if (defaults.resolve(use, .joint, "axis", doc.attribute(element, "axis"))) |text| {
        var v: [3]f32 = undefined;
        try readFloats(text, &v);
        self.axis = normalize3(vec(v[0], v[1], v[2]));
    }
    if (defaults.resolve(use, .joint, "pos", doc.attribute(element, "pos"))) |text| {
        var v: [3]f32 = undefined;
        try readFloats(text, &v);
        self.pos = vec(v[0], v[1], v[2]);
    }
    if (defaults.resolve(use, .joint, "range", doc.attribute(element, "range"))) |text| {
        var v: [2]f32 = undefined;
        try readFloats(text, &v);
        // ★ ANGULAR JOINTS CONVERT, SLIDERS DO NOT. A slide joint's range is in metres and
        // running it through a degree conversion would shrink it by 57 — the same trap as
        // reading radians for degrees, in the opposite direction.
        self.range = switch (self.kind) {
            .slide => .{ v[0], v[1] },
            else => .{ compiler.angle.toRadians(v[0]), compiler.angle.toRadians(v[1]) },
        };
    }
    self.damping = try readScalar(defaults, use, .joint, "damping", doc.attribute(element, "damping"), 0);
    self.armature = try readScalar(defaults, use, .joint, "armature", doc.attribute(element, "armature"), 0);
    self.stiffness = try readScalar(defaults, use, .joint, "stiffness", doc.attribute(element, "stiffness"), 0);
    return self;
}

fn readGeom(
    doc: *const codecs.xml.Document,
    element: *const codecs.xml.Element,
    class: []const u8,
    defaults: *const Defaults,
    compiler: Compiler,
) Error!Geom {
    const own: ?[]const u8 = doc.attribute(element, "class");
    const use: []const u8 = own orelse class;
    var self: Geom = .{ .name = doc.attribute(element, "name") orelse "" };

    // ★★ AN EXPLICIT `type` WINS OVER AN INHERITED `mesh`, and the order matters.
    //
    // These two used to be applied in sequence, with `mesh` overwriting the kind
    // unconditionally. That is wrong whenever a class carries a mesh and a geom states its
    // own shape — a collision capsule inside a class whose visuals are meshes becomes a mesh,
    // and since this importer cannot build meshes it is then SKIPPED. The robot keeps every
    // body and every name and quietly loses the collision geometry that made it solid.
    //
    // MJCF's rule is that `type` is authoritative and `mesh` names an asset. A mesh only
    // IMPLIES the type when nothing else stated one.
    const stated_type: ?[]const u8 = defaults.resolve(use, .geom, "type", doc.attribute(element, "type"));
    self.mesh = defaults.resolve(use, .geom, "mesh", doc.attribute(element, "mesh")) orelse "";
    if (stated_type) |text| {
        self.kind = std.meta.stringToEnum(GeomType, text) orelse .sphere;
    } else if (self.mesh.len > 0) {
        self.kind = .mesh;
    }
    if (defaults.resolve(use, .geom, "size", doc.attribute(element, "size"))) |text| {
        // `size` may state fewer numbers than three; the rest stay zero, which is what MJCF
        // means by them (a sphere states one, a capsule one or two, a box three).
        var it = std.mem.tokenizeAny(u8, text, " \t\n\r");
        for (&self.size) |*slot| {
            const token: []const u8 = it.next() orelse break;
            slot.* = std.fmt.parseFloat(f32, token) catch return Error.MalformedNumberList;
        }
    }
    // ★★ POSITION AND ORIENTATION RESOLVE THROUGH THE CLASS TOO, and missing that put every
    // one of the Go1's feet in the wrong place.
    //
    // These two read straight from the ELEMENT, skipping the default machinery that every
    // other attribute goes through. The Go1 states its foot as
    //
    //     <default class="foot">
    //       <geom type="sphere" size="0.023" pos="0 0 -0.213" .../>
    //     </default>
    //
    // — the offset to the ankle lives in the CLASS. Dropped, each foot collapsed onto its
    // calf's origin, 21 cm above where it belongs. The robot then stood on its SHINS, which
    // still looks like a robot standing.
    //
    // Nothing caught it: forward kinematics agrees to 1e-4 because that is about BODY poses,
    // and geoms do not enter it.
    self.pos = try resolveVec(defaults, use, .geom, "pos", doc.attribute(element, "pos"));
    self.rot = try resolveOrientation(doc, element, use, defaults, compiler);

    // ★ `fromto` REPLACES pos, orientation AND half-length in one attribute, and it is how
    // real models are written — `humanoid.xml` uses it 14 times against 12 plain `size`s.
    // Two endpoints of a capsule's or cylinder's AXIS: the centre is their midpoint, the
    // rotation takes +Z along the segment, and the half-length is half its length. Ignore it
    // and the geom collapses to a zero-length capsule at the body origin.
    if (defaults.resolve(use, .geom, "fromto", doc.attribute(element, "fromto"))) |text| {
        var v: [6]f32 = undefined;
        try readFloats(text, &v);
        const from: Vec = vec(v[0], v[1], v[2]);
        const to: Vec = vec(v[3], v[4], v[5]);
        const along: Vec = to - from;
        const span: f32 = length3(along);
        self.pos = (from + to) * splat(@as(f32, 0.5));
        self.rot = shortestArc(vec(0, 0, 1), normalize3(along));
        self.size[1] = 0.5 * span;
    }

    if (defaults.resolve(use, .geom, "friction", doc.attribute(element, "friction"))) |text| {
        var it = std.mem.tokenizeAny(u8, text, " \t\n\r");
        if (it.next()) |token| {
            // one scalar of three; the engine uses slide friction only
            self.friction = std.fmt.parseFloat(f32, token) catch return Error.MalformedNumberList;
        }
    }
    if (defaults.resolve(use, .geom, "mass", doc.attribute(element, "mass"))) |text| {
        self.mass = std.fmt.parseFloat(f32, text) catch return Error.MalformedNumberList;
    }
    self.density = try readScalar(defaults, use, .geom, "density", doc.attribute(element, "density"), 1000.0);
    return self;
}

fn readScalar(
    defaults: *const Defaults,
    class: []const u8,
    kind: Kind,
    attribute: []const u8,
    stated: ?[]const u8,
    fallback: f32,
) Error!f32 {
    const text: []const u8 = defaults.resolve(class, kind, attribute, stated) orelse return fallback;
    return std.fmt.parseFloat(f32, text) catch Error.MalformedNumberList;
}

fn readVec(
    doc: *const codecs.xml.Document,
    element: *const codecs.xml.Element,
    attribute: []const u8,
    fallback: Vec,
) Error!Vec {
    const text: []const u8 = doc.attribute(element, attribute) orelse return fallback;
    var v: [3]f32 = undefined;
    try readFloats(text, &v);
    return vec(v[0], v[1], v[2]);
}

test "mjcf: the humanoid's body tree matches what MuJoCo builds" {
    // ★★ THE ACCEPTANCE TEST FOR TURN 7, against a live MuJoCo 3.11.0 rather than a reading
    // of the spec. For `humanoid.xml` it reports nbody=17 (16 plus the world), njnt=22,
    // nq=28, nv=27, and the parent/position table checked below.
    const gpa: Allocator = std.testing.allocator;
    const source: []const u8 = @embedFile("tests/fixtures/robot/humanoid.xml");
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, source, null);
    defer doc.deinit();
    var robot: Robot = try readRobot(gpa, &doc);
    defer robot.deinit();

    // 16 bodies here; MuJoCo counts 17 because it includes the world as body 0.
    try expectEqual(@as(usize, 16), robot.bodies.len);
    try expectEqual(@as(usize, 22), robot.joints.len);

    // ── the tree shape, as MuJoCo reports it (its ids are ours + 1) ──
    const Expect = struct { name: []const u8, parent: ?u32, pos: [3]f32 };
    const expected = [_]Expect{
        .{ .name = "torso", .parent = null, .pos = .{ 0, 0, 1.282 } },
        .{ .name = "head", .parent = 0, .pos = .{ 0, 0, 0.19 } },
        .{ .name = "waist_lower", .parent = 0, .pos = .{ -0.01, 0, -0.26 } },
        .{ .name = "pelvis", .parent = 2, .pos = .{ 0, 0, -0.165 } },
        .{ .name = "thigh_right", .parent = 3, .pos = .{ 0, -0.1, -0.04 } },
        .{ .name = "shin_right", .parent = 4, .pos = .{ 0, 0.01, -0.4 } },
        .{ .name = "foot_right", .parent = 5, .pos = .{ 0, 0, -0.39 } },
    };
    for (expected, 0..) |want, i| {
        const got: Body = robot.bodies[i];
        try expectEqualStrings(want.name, got.name);
        try expectEqual(want.parent, got.parent);
        inline for (0..3) |k| {
            try expectApproxEqAbs(want.pos[k], got.pos[k], 1.0e-5);
        }
    }

    // ── ★ THE FREE JOINT, and it is written `<freejoint/>` rather than `type="free"` ──
    try expectEqual(JointType.free, robot.joints[0].kind);
    try expectEqualStrings("root", robot.joints[0].name);

    // ── ★ A RANGE THAT CAME THROUGH A CLASS, IN DEGREES ──
    // `hip_x_right` states only `class="hip_x"`; the class says `range="-30 10"`, and MuJoCo
    // reports [-0.5236, 0.1745] radians. Both the inheritance and the unit conversion have to
    // be right for this one line to pass.
    var hip_x_right: ?Joint = null;
    for (robot.joints) |joint| {
        if (std.mem.eql(u8, joint.name, "hip_x_right")) {
            hip_x_right = joint;
        }
    }
    try expect(hip_x_right != null);
    try expectEqual(JointType.hinge, hip_x_right.?.kind);
    try expectApproxEqAbs(@as(f32, -0.5236), hip_x_right.?.range.?[0], 1.0e-4);
    try expectApproxEqAbs(@as(f32, 0.1745), hip_x_right.?.range.?[1], 1.0e-4);

    // ── ★ A GEOM WHOSE TYPE AND FRICTION CAME FROM A CLASS TWO LEVELS UP ──
    // MuJoCo reports geom_friction[1] = [0.7, ...] and type capsule for `torso`.
    var torso_geom: ?Geom = null;
    for (robot.geoms) |geom| {
        if (std.mem.eql(u8, geom.name, "torso")) {
            torso_geom = geom;
        }
    }
    try expect(torso_geom != null);
    try expectEqual(GeomType.capsule, torso_geom.?.kind);
    try expectApproxEqAbs(@as(f32, 0.7), torso_geom.?.friction, 1.0e-5);
}

test "mjcf: fromto places and orients a capsule, and sets its half-length" {
    // ★ `fromto` IS HOW REAL MODELS ARE WRITTEN — 14 uses against 12 plain sizes in
    // `humanoid.xml`. It replaces position, orientation AND half-length at once, so a reader
    // that ignores it produces a zero-length capsule sitting at the body origin: present in
    // the model, invisible in the world, and contributing no collision.
    const gpa: Allocator = std.testing.allocator;
    const source: []const u8 =
        \\<mujoco><worldbody><body>
        \\  <geom type="capsule" size=".05" fromto="0 0 0  0 0 -.4"/>
        \\</body></worldbody></mujoco>
    ;
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, source, null);
    defer doc.deinit();
    var robot: Robot = try readRobot(gpa, &doc);
    defer robot.deinit();

    const geom: Geom = robot.geoms[0];
    try expectEqual(GeomType.capsule, geom.kind);
    // Centre is the midpoint of the segment.
    try expectApproxEqAbs(@as(f32, 0.0), geom.pos[0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, -0.2), geom.pos[2], 1.0e-5);
    // Radius stays where `size` put it; the half-length is derived.
    try expectApproxEqAbs(@as(f32, 0.05), geom.size[0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, 0.2), geom.size[1], 1.0e-5);
    // And +Z now points along the segment, which here is straight down.
    const down: Vec = zm.rotate(geom.rot, vec(0, 0, 1));
    try expectApproxEqAbs(@as(f32, -1.0), down[2], 1.0e-4);
}

test "mjcf: childclass reaches every descendant, not just the body that states it" {
    // ★ `humanoid.xml` opens `<body name="torso" childclass="body">` and then states almost
    // nothing on the geoms for the rest of the file. Treating `childclass` as applying only
    // to the body it sits on gives every one of those geoms no type and no size.
    const gpa: Allocator = std.testing.allocator;
    const source: []const u8 =
        \\<mujoco>
        \\  <default><default class="thing"><geom type="box" size="1 2 3"/></default></default>
        \\  <worldbody>
        \\    <body name="top" childclass="thing">
        \\      <body name="middle">
        \\        <body name="deep"><geom name="g"/></body>
        \\      </body>
        \\    </body>
        \\  </worldbody>
        \\</mujoco>
    ;
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, source, null);
    defer doc.deinit();
    var robot: Robot = try readRobot(gpa, &doc);
    defer robot.deinit();

    // Three bodies deep, and the geom still inherits from the class named at the top.
    try expectEqual(@as(usize, 3), robot.bodies.len);
    try expectEqual(GeomType.box, robot.geoms[0].kind);
    try expectApproxEqAbs(@as(f32, 1.0), robot.geoms[0].size[0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, 3.0), robot.geoms[0].size[2], 1.0e-5);
}

// =============================================================================
// Actuators, sensors and keyframes — turn 8
// =============================================================================

/// What kind of controller MJCF wraps around a joint.
///
/// ── ★ WHY THIS IS THE REASON TO READ MJCF AT ALL ──
///
/// URDF stops at the linkage. It says a knee exists and how it bends, and nothing about what
/// drives it. MJCF states the transmission: this joint is driven by a motor with a gear ratio
/// of 80, a control range of ±1, and a force limit. A quadruped imported from URDF is a shape
/// that falls over; the same quadruped from MJCF has legs that can push.
pub const ActuatorKind = enum {
    /// Direct force: `force = gear * ctrl`.
    motor,
    /// Position servo: `force = gear * kp * (ctrl - qpos)`.
    position,
    /// Velocity servo: `force = gear * kv * (ctrl - qvel)`.
    velocity,
};

pub const Actuator = struct {
    name: []const u8,
    kind: ActuatorKind = .motor,
    /// The joint this drives, by name. Resolved to an index when the model is built.
    joint: []const u8,
    /// ★ GEAR IS A TRANSMISSION RATIO, NOT A LIMIT. `humanoid.xml` gives its knee `gear="80"`
    /// and a `ctrlrange` of ±1, so `ctrl = 1` means 80 N·m. Reading gear as a maximum torque
    /// and ignoring it gives a robot whose knees produce 1 N·m — indistinguishable from a
    /// robot with no actuators, because it simply collapses.
    gear: f32 = 1.0,
    /// Range of the control signal.
    ctrl_range: ?[2]f32 = null,
    /// Range of the OUTPUT force, after gear. Zero-width means unlimited.
    force_range: ?[2]f32 = null,
    /// Servo gains. Only meaningful for `position` / `velocity`.
    kp: f32 = 1.0,
    kv: f32 = 1.0,
};

/// A named pose the model can be reset to.
///
/// ★ THE THING THAT MAKES A LEGGED ROBOT USABLE. A quadruped dropped at its zero pose is a
/// tangle of straight legs that falls over before a controller can do anything. `humanoid.xml`
/// ships four — `squat`, `stand_on_left_leg`, `prone`, `supine` — and Menagerie models almost
/// always ship a `home`. Starting from one is the difference between debugging a controller
/// and debugging a fall.
/// One `<contact><exclude>`: two bodies, by name, that never collide.
pub const Exclude = struct {
    body1: []const u8,
    body2: []const u8,
};

pub const Keyframe = struct {
    name: []const u8,
    /// Generalized positions, in the model's own `qpos` order. Empty if the key omits them.
    qpos: []const f32 = &.{},
    qvel: []const f32 = &.{},
    ctrl: []const f32 = &.{},
};

/// Read `<actuator>`, resolving defaults exactly as bodies do.
pub fn readActuators(
    a: Allocator,
    doc: *const codecs.xml.Document,
    defaults: *const Defaults,
) Error![]Actuator {
    var out: std.ArrayListUnmanaged(Actuator) = .empty;
    const block: *const codecs.xml.Element =
        doc.child(doc.rootElement(), "actuator") orelse return out.toOwnedSlice(a);

    for (doc.childrenOf(block)) |*child| {
        const kind: ActuatorKind = std.meta.stringToEnum(ActuatorKind, child.name) orelse continue;
        // An actuator's defaults live under its own tag — `<motor>` settings do not apply to
        // a `<position>` — which is why `Kind` mirrors the tag names.
        const dk: Kind = switch (kind) {
            .motor => .motor,
            .position => .position,
            .velocity => .velocity,
        };
        const class: []const u8 = doc.attribute(child, "class") orelse "";
        var self: Actuator = .{
            .name = doc.attribute(child, "name") orelse "",
            .kind = kind,
            .joint = defaults.resolve(class, dk, "joint", doc.attribute(child, "joint")) orelse "",
        };
        self.gear = try readScalar(defaults, class, dk, "gear", doc.attribute(child, "gear"), 1.0);
        self.kp = try readScalar(defaults, class, dk, "kp", doc.attribute(child, "kp"), 1.0);
        self.kv = try readScalar(defaults, class, dk, "kv", doc.attribute(child, "kv"), 1.0);
        if (defaults.resolve(class, dk, "ctrlrange", doc.attribute(child, "ctrlrange"))) |text| {
            var v: [2]f32 = undefined;
            try readFloats(text, &v);
            self.ctrl_range = v;
        }
        if (defaults.resolve(class, dk, "forcerange", doc.attribute(child, "forcerange"))) |text| {
            var v: [2]f32 = undefined;
            try readFloats(text, &v);
            self.force_range = v;
        }
        try out.append(a, self);
    }
    return out.toOwnedSlice(a);
}

/// Read `<keyframe>`.
pub fn readKeyframes(
    a: Allocator,
    doc: *const codecs.xml.Document,
) Error![]Keyframe {
    var out: std.ArrayListUnmanaged(Keyframe) = .empty;
    const block: *const codecs.xml.Element =
        doc.child(doc.rootElement(), "keyframe") orelse return out.toOwnedSlice(a);

    for (doc.childrenOf(block)) |*child| {
        if (!std.mem.eql(u8, child.name, "key")) {
            continue;
        }
        try out.append(a, .{
            .name = doc.attribute(child, "name") orelse "",
            .qpos = try readFloatList(a, doc.attribute(child, "qpos")),
            .qvel = try readFloatList(a, doc.attribute(child, "qvel")),
            .ctrl = try readFloatList(a, doc.attribute(child, "ctrl")),
        });
    }
    return out.toOwnedSlice(a);
}

/// Read `<contact>`'s `<exclude>` entries. A missing body name is an error the build reports, when
/// names become bodies; here an entry lacking either attribute is simply not an exclusion.
fn readExcludes(
    a: Allocator,
    doc: *const codecs.xml.Document,
) Error![]const Exclude {
    var out: std.ArrayListUnmanaged(Exclude) = .empty;
    const block: *const codecs.xml.Element =
        doc.child(doc.rootElement(), "contact") orelse return out.toOwnedSlice(a);
    for (doc.childrenOf(block)) |*child| {
        if (!std.mem.eql(u8, child.name, "exclude")) {
            continue;
        }
        const first: []const u8 = doc.attribute(child, "body1") orelse continue;
        const second: []const u8 = doc.attribute(child, "body2") orelse continue;
        try out.append(a, .{ .body1 = first, .body2 = second });
    }
    return out.toOwnedSlice(a);
}

/// Read however many floats an attribute holds — the count is the model's business, not
/// this reader's, and a keyframe legitimately states a different number per model.
fn readFloatList(a: Allocator, text: ?[]const u8) Error![]const f32 {
    const source: []const u8 = text orelse return &.{};
    var out: std.ArrayListUnmanaged(f32) = .empty;
    var it = std.mem.tokenizeAny(u8, source, " \t\n\r");
    while (it.next()) |token| {
        try out.append(a, std.fmt.parseFloat(f32, token) catch return Error.MalformedNumberList);
    }
    return out.toOwnedSlice(a);
}

test "mjcf: the humanoid's actuators and keyframes match MuJoCo" {
    // ★★ THIS IS WHY MJCF IS WORTH READING AT ALL. URDF says a knee exists and how it bends;
    // MJCF says what drives it. MuJoCo reports nu=21 and nkey=4 for this file, with the gear
    // ratios asserted below.
    const gpa: Allocator = std.testing.allocator;
    const source: []const u8 = @embedFile("tests/fixtures/robot/humanoid.xml");
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, source, null);
    defer doc.deinit();
    var robot: Robot = try readRobot(gpa, &doc);
    defer robot.deinit();

    try expectEqual(@as(usize, 21), robot.actuators.len);

    // ── ★ GEAR VARIES PER JOINT, AND BY SIX TIMES ACROSS THIS ROBOT ──
    // A knee needs 80 N·m where an ankle needs 20 and a hip 120. Reading `gear` as anything
    // other than a transmission ratio — or ignoring it, since `ctrlrange` is ±1 everywhere —
    // gives every joint 1 N·m, which is indistinguishable from having no actuators.
    const Want = struct { name: []const u8, gear: f32 };
    const wanted = [_]Want{
        .{ .name = "abdomen_z", .gear = 40 },
        .{ .name = "hip_y_right", .gear = 120 },
        .{ .name = "knee_right", .gear = 80 },
        .{ .name = "ankle_y_right", .gear = 20 },
    };
    for (wanted) |want| {
        var found: ?Actuator = null;
        for (robot.actuators) |actuator| {
            if (std.mem.eql(u8, actuator.name, want.name)) {
                found = actuator;
            }
        }
        try expect(found != null);
        try expectApproxEqAbs(want.gear, found.?.gear, 1.0e-5);
        try expectEqual(ActuatorKind.motor, found.?.kind);
        // Every one drives the joint of the same name here, which is worth pinning because a
        // silently unresolved transmission would drive nothing at all.
        try expectEqualStrings(want.name, found.?.joint);
        // `ctrlrange` comes from the root `<default><motor ctrlrange="-1 1"/>`, so this also
        // checks that actuator defaults resolve through the same path bodies use.
        try expectApproxEqAbs(@as(f32, -1.0), found.?.ctrl_range.?[0], 1.0e-5);
        try expectApproxEqAbs(@as(f32, 1.0), found.?.ctrl_range.?[1], 1.0e-5);
    }

    // ── ★ FOUR NAMED POSES, and this is what makes a legged robot testable ──
    // A humanoid dropped at its zero pose is a tangle of straight limbs that falls before a
    // controller can act. MuJoCo reports nq=28, and `squat`'s qpos has exactly that many
    // numbers with the torso at z = 0.596.
    try expectEqual(@as(usize, 4), robot.keyframes.len);
    try expectEqualStrings("squat", robot.keyframes[0].name);
    try expectEqualStrings("stand_on_left_leg", robot.keyframes[1].name);
    try expectEqual(@as(usize, 28), robot.keyframes[0].qpos.len);
    try expectApproxEqAbs(@as(f32, 0.596), robot.keyframes[0].qpos[2], 1.0e-4);
}

test "mjcf: actuator defaults do not leak between kinds" {
    // ★ A `<motor>` default block must not configure a `<position>` servo. They are different
    // transmissions with different meanings for the same attribute names — `kp` on a position
    // servo is a gain, and a motor has none — so sharing a default set would silently give
    // one the other's numbers.
    const gpa: Allocator = std.testing.allocator;
    const source: []const u8 =
        \\<mujoco>
        \\  <default>
        \\    <motor gear="40" ctrlrange="-1 1"/>
        \\    <position kp="200" ctrlrange="-3 3"/>
        \\  </default>
        \\  <worldbody><body name="b"><joint name="j"/><geom size=".1"/></body></worldbody>
        \\  <actuator>
        \\    <motor name="m" joint="j"/>
        \\    <position name="p" joint="j"/>
        \\  </actuator>
        \\</mujoco>
    ;
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, source, null);
    defer doc.deinit();
    var robot: Robot = try readRobot(gpa, &doc);
    defer robot.deinit();

    try expectEqual(@as(usize, 2), robot.actuators.len);
    const motor: Actuator = robot.actuators[0];
    const position: Actuator = robot.actuators[1];

    try expectEqual(ActuatorKind.motor, motor.kind);
    try expectApproxEqAbs(@as(f32, 40.0), motor.gear, 1.0e-5);
    try expectApproxEqAbs(@as(f32, -1.0), motor.ctrl_range.?[0], 1.0e-5);

    try expectEqual(ActuatorKind.position, position.kind);
    try expectApproxEqAbs(@as(f32, 200.0), position.kp, 1.0e-5);
    try expectApproxEqAbs(@as(f32, -3.0), position.ctrl_range.?[0], 1.0e-5);
    // ★ The position servo did NOT pick up the motor's gear of 40.
    try expectApproxEqAbs(@as(f32, 1.0), position.gear, 1.0e-5);
}

test "mjcf: an explicit geom type beats a mesh inherited from its class" {
    // ★★ THE FAILURE THIS PREVENTS IS INVISIBLE. A class that carries a mesh — every real
    // model has one for visuals — used to force `kind = .mesh` on any geom inside it, even a
    // geom that stated its own shape. Since this importer cannot build meshes, that geom is
    // then SKIPPED at conversion: the robot keeps every body, every joint and every name, and
    // quietly loses the collision shape that made it solid.
    //
    // A robot that imports cleanly and falls through the floor is a much worse outcome than
    // one that refuses to import.
    const gpa: Allocator = std.testing.allocator;
    const source: []const u8 =
        \\<mujoco>
        \\  <default>
        \\    <default class="skin">
        \\      <geom type="mesh" mesh="shell"/>
        \\      <default class="hardpoint">
        \\        <geom type="capsule" size=".02 .1"/>
        \\      </default>
        \\    </default>
        \\  </default>
        \\  <worldbody><body>
        \\    <geom class="skin"/>
        \\    <geom class="hardpoint"/>
        \\    <geom class="skin" type="box" size=".1 .1 .1"/>
        \\  </body></worldbody>
        \\</mujoco>
    ;
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, source, null);
    defer doc.deinit();
    var robot: Robot = try readRobot(gpa, &doc);
    defer robot.deinit();

    try expectEqual(@as(usize, 3), robot.geoms.len);

    // The visual: type and mesh both from the class, so it really is a mesh.
    try expectEqual(GeomType.mesh, robot.geoms[0].kind);
    try expectEqualStrings("shell", robot.geoms[0].mesh);

    // ★ A CHILD CLASS OVERRIDING THE TYPE. It still inherits `mesh` — MJCF's inheritance is
    // field by field — but the nearer `type` is the one that counts.
    try expectEqual(GeomType.capsule, robot.geoms[1].kind);
    try expectEqualStrings("shell", robot.geoms[1].mesh);

    // ★ And a type stated on the element itself, over a class that says mesh.
    try expectEqual(GeomType.box, robot.geoms[2].kind);
}

test "mjcf: a mesh with no type still comes out as a mesh" {
    // The other half of the rule: `type` is authoritative, but a mesh with nothing else
    // stated must still be recognised, or a visual-only model loses its geometry entirely.
    const gpa: Allocator = std.testing.allocator;
    const source: []const u8 =
        \\<mujoco><worldbody><body>
        \\  <geom mesh="body_shell"/>
        \\</body></worldbody></mujoco>
    ;
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, source, null);
    defer doc.deinit();
    var robot: Robot = try readRobot(gpa, &doc);
    defer robot.deinit();
    try expectEqual(GeomType.mesh, robot.geoms[0].kind);
    try expectEqualStrings("body_shell", robot.geoms[0].mesh);
}

/// A body's stated mass properties, if it gives any.
///
/// ── ★★ WHY THIS MATTERS MORE THAN IT LOOKS ──
///
/// Without it a body's mass comes from its COLLISION GEOMS, which are deliberately simplified
/// — capsules and boxes standing in for machined parts. Measured on the Go1, whose every body
/// states an `<inertial>`:
///
/// | body | stated | derived from geoms | error |
/// |---|---|---|---|
/// | trunk | 5.2040 kg | 7.9507 kg | +53% |
/// | FR_thigh | 1.0090 kg | 0.2592 kg | −74% |
///
/// The inertia tensors are worse: the trunk's principal moments come out in a different
/// ORDER, so the simulated body is heaviest about a different axis than the real one. A robot
/// built that way stands convincingly and walks wrong, and a policy trained on it learns a
/// machine that does not exist.
pub const Inertial = struct {
    mass: f32,
    /// Centre of mass, in the body's frame.
    pos: Vec = vec_zero,
    /// The full symmetric tensor about the COM, in MuJoCo's `fullinertia` order:
    /// `ixx, iyy, izz, ixy, ixz, iyz`.
    full: [6]f32,
};

/// Read a body's `<inertial>`, in either of MJCF's two spellings.
///
/// ★ MJCF OFFERS `fullinertia` OR `diaginertia`+orientation, and real files use the second:
/// a CAD tool produces principal moments and the rotation that diagonalises them, which is
/// what `<inertial pos=... quat=... mass=... diaginertia=.../>` records. Supporting only
/// `fullinertia` would read every Menagerie model as having no stated inertia at all — a
/// silent fallback to the geom-derived numbers, which is the failure this exists to prevent.
///
/// The conversion is `I = R · diag(d) · Rᵀ`, and it is done here rather than in the engine so
/// that `InertialSpec` keeps carrying one representation (§1: no eigendecomposition, no
/// degenerate-eigenvalue cases).
pub fn readInertial(
    doc: *const codecs.xml.Document,
    body: *const codecs.xml.Element,
    compiler: Compiler,
) Error!?Inertial {
    const element: *const codecs.xml.Element = doc.child(body, "inertial") orelse return null;
    const mass_text: []const u8 = doc.attribute(element, "mass") orelse return null;

    var self: Inertial = .{
        .mass = std.fmt.parseFloat(f32, mass_text) catch return Error.MalformedNumberList,
        .full = .{ 0, 0, 0, 0, 0, 0 },
    };
    if (doc.attribute(element, "pos")) |text| {
        var v: [3]f32 = undefined;
        try readFloats(text, &v);
        self.pos = vec(v[0], v[1], v[2]);
    }

    if (doc.attribute(element, "fullinertia")) |text| {
        try readFloats(text, &self.full);
        return self;
    }

    if (doc.attribute(element, "diaginertia")) |text| {
        var d: [3]f32 = undefined;
        try readFloats(text, &d);
        // The orientation of the principal axes, in whichever spelling the file used — the
        // same five `readOrientation` already handles, since `<inertial>` takes them all.
        const rot: Quat = try readOrientation(doc, element, compiler);
        const x: Vec = zm.rotate(rot, vec(1, 0, 0));
        const y: Vec = zm.rotate(rot, vec(0, 1, 0));
        const z: Vec = zm.rotate(rot, vec(0, 0, 1));
        // I = R·diag(d)·Rᵀ, written out: each column of R scaled by its moment, then
        // recombined. Only six of the nine entries are independent.
        inline for (0..3) |r| {
            inline for (r..3) |c| {
                const entry: f32 = d[0] * x[r] * x[c] + d[1] * y[r] * y[c] + d[2] * z[r] * z[c];
                // fullinertia order: xx, yy, zz, xy, xz, yz.
                const slot: usize = if (r == c) r else switch (r * 3 + c) {
                    1 => 3, // xy
                    2 => 4, // xz
                    else => 5, // yz
                };
                self.full[slot] = entry;
            }
        }
        return self;
    }

    // Mass with no inertia stated is legal; the tensor stays zero and the caller decides.
    return self;
}

/// One entry of `<asset>`: a mesh the model refers to by name.
///
/// ── ★ WHY THE FILE IS NOT LOADED HERE ──
///
/// `mjcf.zig` reads a document and knows nothing about disks — the same split `urdf.zig` uses,
/// and the reason both are testable from a string literal with no fixture directory. The
/// caller resolves `file` against `meshdir` and hands the vertices back, exactly as
/// `urdf.resolveMeshes` does.
pub const MeshAsset = struct {
    /// The name geoms refer to. MJCF defaults it to the file's stem when `name` is absent,
    /// which real models rely on: `<mesh file="trunk.stl"/>` is referred to as `"trunk"`.
    name: []const u8,
    /// As written in the file, relative to `Compiler.mesh_dir`.
    file: []const u8,
    /// Uniform or per-axis scale, applied to the vertices by whoever loads them.
    scale: [3]f32 = .{ 1, 1, 1 },
};

/// Read `<asset>`'s `<mesh>` entries.
pub fn readMeshAssets(a: Allocator, doc: *const codecs.xml.Document) Error![]MeshAsset {
    var out: std.ArrayListUnmanaged(MeshAsset) = .empty;
    const block: *const codecs.xml.Element =
        doc.child(doc.rootElement(), "asset") orelse return out.toOwnedSlice(a);

    for (doc.childrenOf(block)) |*child| {
        if (!std.mem.eql(u8, child.name, "mesh")) {
            continue;
        }
        const file: []const u8 = doc.attribute(child, "file") orelse continue;
        var self: MeshAsset = .{
            // ★ THE NAME DEFAULTS TO THE FILE'S STEM, and every Menagerie model depends on it.
            // `<mesh file="trunk.stl"/>` is referred to as `mesh="trunk"`; requiring an
            // explicit `name` would leave every geom pointing at an asset that does not exist.
            .name = doc.attribute(child, "name") orelse stemOf(file),
            .file = file,
        };
        if (doc.attribute(child, "scale")) |text| {
            try readFloats(text, &self.scale);
        }
        try out.append(a, self);
    }
    return out.toOwnedSlice(a);
}

/// The filename without its directory or extension.
fn stemOf(path: []const u8) []const u8 {
    var start: usize = 0;
    if (std.mem.lastIndexOfAny(u8, path, "/\\")) |slash| {
        start = slash + 1;
    }
    const name: []const u8 = path[start..];
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        return name[0..dot];
    }
    return name;
}

test "mjcf: mesh assets, with names defaulting to the file stem" {
    // ★ EVERY MENAGERIE MODEL DEPENDS ON THE DEFAULT. The Go1 writes
    // `<mesh class="go1" file="trunk.stl"/>` and then refers to it as `mesh="trunk"` — the
    // name is never stated. Requiring one would leave every geom pointing at an asset that
    // does not exist, and the robot would import with no collision geometry at all.
    const gpa: Allocator = std.testing.allocator;
    const source: []const u8 = @embedFile("tests/fixtures/robot/go1/go1.xml");
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, source, null);
    defer doc.deinit();
    var robot: Robot = try readRobot(gpa, &doc);
    defer robot.deinit();

    try expectEqual(@as(usize, 5), robot.meshes.len);
    try expectEqualStrings("trunk", robot.meshes[0].name);
    try expectEqualStrings("trunk.stl", robot.meshes[0].file);
    try expectEqualStrings("thigh_mirror", robot.meshes[2].name);

    // ★ AND `meshdir`, which is where those files actually live. Resolving against the model's
    // own directory instead — the obvious guess — misses every one of them.
    try expectEqualStrings("assets", robot.compiler.mesh_dir);

    // The Go1 states `angle="radian"`, unlike the humanoid, so the compiler read has to be
    // per-file rather than assumed.
    try expectEqual(AngleUnit.radian, robot.compiler.angle);

    // Every geom naming a mesh resolves to one of these assets — the check that would have
    // caught a stem-vs-name mismatch.
    for (robot.geoms) |geom| {
        if (geom.mesh.len == 0) {
            continue;
        }
        var found: bool = false;
        for (robot.meshes) |asset| {
            if (std.mem.eql(u8, asset.name, geom.mesh)) {
                found = true;
            }
        }
        expect(found) catch |err| {
            std.log.err("geom '{s}' names mesh '{s}', which no asset provides", .{ geom.name, geom.mesh });
            return err;
        };
    }
}

/// Load every mesh a geom refers to, reducing each to a convex point cloud.
///
/// ── ★ THE CALLBACK, RATHER THAN A PATH ──
///
/// `mjcf.zig` never touches a disk: `load` is handed a filename already resolved against
/// `meshdir` and returns the file's bytes, or null if it cannot be read. That is what keeps
/// this module testable from a string literal, and it is the same seam `urdf.resolveMeshes`
/// uses — a caller that already has an STL reader wires the two together in a few lines.
///
/// A mesh that fails to load leaves its geom with an empty hull rather than failing the
/// import. Real models refer to visual assets that a headless caller has no reason to ship,
/// and refusing the robot over one would make the importer useless on the files it exists for.
/// Returns how many geoms were resolved, so a caller can notice when the answer is zero.
pub fn resolveMeshes(
    robot: *Robot,
    context: *anyopaque,
    load: *const fn (context: *anyopaque, filename: []const u8) ?[]const f32,
    direction_count: u32,
) (Error || urdf.Error)!u32 {
    const a: Allocator = robot.arena.allocator();
    var resolved: u32 = 0;
    for (robot.geoms) |*geom| {
        if (geom.kind != .mesh or geom.mesh.len == 0 or geom.hull.len > 0) {
            continue;
        }
        const asset: MeshAsset = for (robot.meshes) |candidate| {
            if (std.mem.eql(u8, candidate.name, geom.mesh)) {
                break candidate;
            }
        } else continue;

        const vertices: []const f32 = load(context, asset.file) orelse continue;
        // ★ SCALE IS APPLIED BEFORE THE HULL IS REDUCED, not after. Reducing first and scaling
        // the survivors would be the same for a uniform scale and wrong for a per-axis one:
        // the support points of a stretched shape are not the stretched support points of the
        // original.
        const scaled: []f32 = try a.alloc(f32, vertices.len);
        var i: usize = 0;
        while (i + 2 < vertices.len) : (i += 3) {
            scaled[i + 0] = vertices[i + 0] * asset.scale[0];
            scaled[i + 1] = vertices[i + 1] * asset.scale[1];
            scaled[i + 2] = vertices[i + 2] * asset.scale[2];
        }
        geom.hull = try urdf.hullPoints(a, scaled, direction_count);
        resolved += 1;
    }
    return resolved;
}

/// A named point on a body.
///
/// ★ SITES EXIST TO BE MEASURED FROM. A geom is collision or visual; a site is neither — it is
/// a frame you attach an instrument to, and every frame-relative sensor names one. Reading
/// them is therefore a prerequisite for reading sensors at all, which is why they arrive in
/// the same change.
pub const Site = struct {
    name: []const u8,
    /// Index into `Robot.bodies`.
    body: u32,
    pos: Vec = vec_zero,
    rot: Quat = quat_identity,
};

/// What a `<sensor>` entry reads.
///
/// ── ★ MJCF NAMES SENSORS BY TAG, NOT BY AN ATTRIBUTE ──
///
/// `<jointpos joint="x"/>` and `<framepos objtype="site" objname="x"/>` are different
/// ELEMENTS, where actuators are `<motor>`/`<position>`/`<velocity>` distinguished the same
/// way. So the tag is the kind, and the attribute that names the target changes with it —
/// `joint`, `site`, `actuator`, or the `objtype`/`objname` pair.
pub const SensorKind = enum {
    joint_pos,
    joint_vel,
    /// `<framepos>` / `<framequat>` with `objtype="site"`.
    site_pos,
    site_quat,
    /// Site-frame linear velocity, angular velocity, and proper acceleration.
    velocimeter,
    gyro,
    accelerometer,
    actuator_force,

    fn fromTag(tag: []const u8) ?SensorKind {
        const Entry = struct { []const u8, SensorKind };
        const table: [8]Entry = .{
            .{ "jointpos", SensorKind.joint_pos },
            .{ "jointvel", SensorKind.joint_vel },
            .{ "framepos", SensorKind.site_pos },
            .{ "framequat", SensorKind.site_quat },
            .{ "velocimeter", SensorKind.velocimeter },
            .{ "gyro", SensorKind.gyro },
            .{ "accelerometer", SensorKind.accelerometer },
            .{ "actuatorfrc", SensorKind.actuator_force },
        };
        inline for (table) |entry| {
            if (std.mem.eql(u8, tag, entry[0])) {
                return entry[1];
            }
        }
        return null;
    }
};

pub const Sensor = struct {
    name: []const u8,
    kind: SensorKind,
    /// Joint, site or actuator name, depending on `kind`.
    target: []const u8,
};

/// Read the `<sensor>` block.
///
/// ★ AN UNRECOGNISED SENSOR IS SKIPPED, NOT AN ERROR. MuJoCo has upwards of thirty kinds —
/// touch, rangefinder, magnetometer, force, torque, subtree momentum, user — and a model that
/// happens to carry one this engine cannot compute should still import. The alternative is an
/// importer that refuses whole robots over an instrument nobody asked to read.
pub fn readSensors(a: Allocator, doc: *const codecs.xml.Document) Error![]Sensor {
    var out: std.ArrayListUnmanaged(Sensor) = .empty;
    const block: *const codecs.xml.Element =
        doc.child(doc.rootElement(), "sensor") orelse return out.toOwnedSlice(a);

    for (doc.childrenOf(block)) |*child| {
        const kind: SensorKind = SensorKind.fromTag(child.name) orelse continue;
        // ★ THE TARGET ATTRIBUTE DEPENDS ON THE KIND, which is the whole awkwardness of this
        // corner of the format. `framepos` uses `objname` alongside an `objtype` that must say
        // `site` — this engine has no frame sensors for anything else — while the others name
        // their target directly.
        const target: []const u8 = switch (kind) {
            .joint_pos, .joint_vel => doc.attribute(child, "joint") orelse continue,
            .velocimeter, .gyro, .accelerometer => doc.attribute(child, "site") orelse continue,
            .actuator_force => doc.attribute(child, "actuator") orelse continue,
            .site_pos, .site_quat => blk: {
                const objtype: []const u8 = doc.attribute(child, "objtype") orelse "site";
                if (!std.mem.eql(u8, objtype, "site")) {
                    continue;
                }
                break :blk doc.attribute(child, "objname") orelse continue;
            },
        };
        try out.append(a, .{
            .name = doc.attribute(child, "name") orelse target,
            .kind = kind,
            .target = target,
        });
    }
    return out.toOwnedSlice(a);
}

/// A loop closure from `<equality>`.
///
/// ── ★ MJCF SPELLS THIS TWO WAYS, AND BOTH ARE COMMON ──
///
/// **Body semantic**: `<connect body1="a" body2="b" anchor="x y z"/>` — the anchor is a point
/// in `body1`'s frame, and MuJoCo's compiler derives `body2`'s from the rest pose.
///
/// **Site semantic**: `<connect site1="p" site2="q"/>` — two sites that must coincide, which is
/// often more readable because a site already names the point.
///
/// Both reduce to the same thing: two bodies and a shared point. The site form is resolved
/// against `Robot.sites`, which is why sites had to be readable before this could exist.
pub const Equality = struct {
    /// True for `<weld>`, which holds ORIENTATION as well as position.
    weld: bool = false,
    /// `<weld torquescale=...>` — how much the orientation rows count for against the
    /// position ones. Meaningless for a `connect`, which has no orientation rows.
    torque_scale: f32 = 1.0,
    body_a: []const u8,
    body_b: []const u8,
    /// Set when the file used `<joint>` rather than `<connect>`: the two joints and the
    /// polynomial relating them. See `JointCoupling`.
    couple: ?JointCoupling = null,
    /// The point in `body_a`'s frame. Null when the file used the site form and the anchor is
    /// the site's own offset — the caller derives the partner either way.
    anchor: ?Vec,
    /// True when the file named sites rather than bodies, so `anchor` is already the site's
    /// offset on `body_a`.
    from_sites: bool = false,
};

/// `<equality type="joint">` — one joint's coordinate as a polynomial in another's.
///
/// ★ `joint2` IS OPTIONAL, and its absence is meaningful rather than a default: with no second
/// joint the first is pinned to a constant, which is how MJCF locks a joint without deleting
/// it. A model that simulates a wrist both free and fixed uses one file and one equality.
pub const JointCoupling = struct {
    driven: []const u8,
    driver: ?[]const u8,
    /// `c0 … c4`. MuJoCo's default is `(0, 1, 0, 0, 0)` — the two joints simply equal.
    poly: [5]f32 = .{ 0, 1, 0, 0, 0 },
};

/// Read `<equality>`.
///
/// ★ ONLY `connect` IS READ. MuJoCo has five types — `weld`, `joint` coupling, `tendon`,
/// `distance` and this one — and an unrecognised entry is SKIPPED rather than refused, the same
/// call made for sensors and geoms. A model carrying a weld it does not depend on should still
/// import; one that depends on it will visibly come apart, which is the honest failure.
pub fn readEqualities(
    a: Allocator,
    doc: *const codecs.xml.Document,
    sites: []const Site,
    bodies: []const Body,
) Error![]Equality {
    var out: std.ArrayListUnmanaged(Equality) = .empty;
    const block: *const codecs.xml.Element =
        doc.child(doc.rootElement(), "equality") orelse return out.toOwnedSlice(a);

    for (doc.childrenOf(block)) |*child| {
        if (std.mem.eql(u8, child.name, "joint")) {
            var couple: JointCoupling = .{
                .driven = doc.attribute(child, "joint1") orelse continue,
                .driver = doc.attribute(child, "joint2"),
            };
            if (doc.attribute(child, "polycoef")) |text| {
                // ★ SHORTER THAN FIVE IS LEGAL, and common — `polycoef="0 -1"` is a mirror.
                // `readFloats` fills what is there and the rest stay zero, which is what the
                // omitted terms mean.
                @memset(&couple.poly, 0);
                try readFloatsUpTo(text, &couple.poly);
            }
            try out.append(a, .{ .body_a = "", .body_b = "", .anchor = null, .couple = couple });
            continue;
        }
        // ★ `connect` AND `weld` READ IDENTICALLY except for one attribute. A weld is a
        // connect that also holds orientation, and the file says so the same way — two bodies
        // or two sites, plus an anchor. Branching on the tag once here keeps the two spellings
        // from drifting apart in the reader the way they have not in the format.
        const welds: bool = std.mem.eql(u8, child.name, "weld");
        if (!welds and !std.mem.eql(u8, child.name, "connect")) {
            continue;
        }
        if (doc.attribute(child, "body1")) |first| {
            var closure: Equality = .{
                .weld = welds,
                .torque_scale = torqueScale(doc, child),
                .body_a = first,
                // ★ `body2` DEFAULTS TO THE WORLD, which is how a pendulum is pinned to a
                // fixed point. Requiring it would refuse a legal and useful construction.
                .body_b = doc.attribute(child, "body2") orelse "",
                .anchor = null,
            };
            if (doc.attribute(child, "anchor")) |text| {
                var v: [3]f32 = undefined;
                try readFloats(text, &v);
                closure.anchor = vec(v[0], v[1], v[2]);
            }
            try out.append(a, closure);
            continue;
        }
        // Site form: look both up, and take the first site's offset as the anchor.
        const name_a: []const u8 = doc.attribute(child, "site1") orelse continue;
        const name_b: []const u8 = doc.attribute(child, "site2") orelse continue;
        const site_a: Site = findSite(sites, name_a) orelse continue;
        const site_b: Site = findSite(sites, name_b) orelse continue;
        try out.append(a, .{
            .weld = welds,
            .torque_scale = torqueScale(doc, child),
            .body_a = bodies[site_a.body].name,
            .body_b = bodies[site_b.body].name,
            .anchor = site_a.pos,
            .from_sites = true,
        });
    }
    return out.toOwnedSlice(a);
}

/// `torquescale`, defaulting to MuJoCo's 1.
fn torqueScale(doc: *const codecs.xml.Document, element: *const codecs.xml.Element) f32 {
    const text: []const u8 = doc.attribute(element, "torquescale") orelse return 1.0;
    return std.fmt.parseFloat(f32, text) catch 1.0;
}

fn findSite(sites: []const Site, name: []const u8) ?Site {
    for (sites) |site| {
        if (std.mem.eql(u8, site.name, name)) {
            return site;
        }
    }
    return null;
}

test "★ the arena survives being returned — a moved arena would strand it" {
    // ★★★ THE REGRESSION GUARD FOR A BUG THAT COST TWO SESSIONS. `readRobot` built into a
    // STACK-LOCAL `ArenaAllocator` and returned the struct by value; every `Allocator` taken
    // during construction held that dead frame's address.
    //
    // ★ AND IT WAS NEARLY INVISIBLE. A single-buffer arena survives the move by luck. Only a
    // fixture whose parse grows the arena past a SECOND buffer strands anything, and only an
    // optimised build lays the stack out so it shows — so the symptom was a 3324-byte leak in
    // ReleaseSafe, on one file out of five.
    //
    // This test does the two things that make it detectable at all: it uses the fixture with
    // the biggest parse, and it reads through the returned slices AFTER the move, so a stranded
    // buffer is a use-after-free rather than a silent leak.
    const gpa: Allocator = std.testing.allocator;
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, @embedFile("tests/fixtures/robot/go1/go1.xml"), null);
    defer doc.deinit();
    var robot: Robot = try readRobot(gpa, &doc);
    defer robot.deinit();

    // ★ THE ARENA IS BEHIND A POINTER, which is the whole fix. Asserting on the type keeps a
    // future tidy-up from quietly reverting it — the compiler would accept a value again.
    comptime {
        if (@typeInfo(@FieldType(Robot, "arena")) != .pointer) {
            @compileError("Robot.arena must stay a POINTER: an Allocator taken from an arena " ++
                "holds that struct's address, and readRobot allocates the whole robot before " ++
                "returning it. Storing it by value strands every buffer past the first.");
        }
    }

    // Read everything the arena owns, after the return. Under the old code this walked memory
    // belonging to a frame that had already gone.
    var name_bytes: usize = 0;
    for (robot.bodies) |body| {
        name_bytes += body.name.len;
    }
    for (robot.joints) |joint| {
        name_bytes += joint.name.len;
    }
    for (robot.geoms) |geom| {
        name_bytes += @intFromBool(geom.kind == .mesh);
    }
    for (robot.actuators) |actuator| {
        name_bytes += actuator.name.len;
    }
    // The Go1 is large enough that its parse needs more than one arena buffer, which is the
    // condition under which the old code stranded anything at all.
    try expect(robot.bodies.len == 13);
    try expect(name_bytes > 100);
}
