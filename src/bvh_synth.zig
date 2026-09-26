//! Procedural BVH generation, for tests.
//!
//! WHY THIS EXISTS
//! ---------------
//! The two real fixtures (`dance1_subject2`, `0005_2FeetJump001`) disagree about nearly
//! everything - channel layout, rotation order, frame rate, units - and between them they
//! still leave holes. Neither is Z-up, so the coordinate-rotation path has no real test.
//! Neither has a joint name near the 32-byte `BoneInfo.name` limit, so the truncation path
//! has no real test. Neither is malformed, so no error path has one either.
//!
//! Hand-writing a BVH per case is how a test file becomes 400 lines of string literals that
//! nobody re-reads. Generating them keeps each case one line of intent, and - the actual
//! payoff - lets a test assert on values it COMPUTED rather than values it transcribed. A
//! synthetic clip whose joint angles are a known function of the frame index has a known
//! forward-kinematics answer at every frame, not just at frame 0.
//!
//! Everything here writes text; nothing here parses. Keeping the generator ignorant of the
//! parser is what stops the two agreeing on a shared misreading.

const std = @import("std");
const zm = @import("zm");
const assert = zm.assert;
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const indexOf = std.mem.indexOf;

/// The six BVH channel kinds, spelled as they appear in a file.
pub const Channel = enum {
    x_position,
    y_position,
    z_position,
    x_rotation,
    y_rotation,
    z_rotation,

    pub fn text(self: Channel) []const u8 {
        return switch (self) {
            .x_position => "Xposition",
            .y_position => "Yposition",
            .z_position => "Zposition",
            .x_rotation => "Xrotation",
            .y_rotation => "Yrotation",
            .z_rotation => "Zrotation",
        };
    }
};

/// Rotation channel order. Both real fixtures differ here and flomo's notes claim a third
/// spelling, so the generator treats it as a free parameter rather than a constant.
pub const RotationOrder = enum {
    zyx, // dance1_subject2
    xyz, // 0005_2FeetJump001
    zxy, // what flomo's CLAUDE.md and its FBX writer claim

    pub fn channels(self: RotationOrder) [3]Channel {
        return switch (self) {
            .zyx => .{ .z_rotation, .y_rotation, .x_rotation },
            .xyz => .{ .x_rotation, .y_rotation, .z_rotation },
            .zxy => .{ .z_rotation, .x_rotation, .y_rotation },
        };
    }
};

/// Which joints carry position channels. dance1 puts 6 channels on EVERY joint; 2FeetJump
/// uses the textbook root-only shape. Code that special-cases either breaks on the other,
/// so both are generatable.
pub const ChannelLayout = enum {
    /// 6 on the root, 3 on everything else.
    root_only,
    /// 6 on every joint. Position channels then OVERWRITE each joint's OFFSET at sample
    /// time, which makes the offsets dead weight for sampling but still live for the
    /// up-axis heuristic.
    all_joints,
};

pub const Options = struct {
    /// Chain length, root included. Each joint is a child of the previous one.
    joint_count: usize = 3,
    frame_count: usize = 4,
    frame_time: f32 = 1.0 / 60.0,
    rotation_order: RotationOrder = .zyx,
    layout: ChannelLayout = .root_only,
    /// Bone vector from each joint to its child, in file units, BEFORE any up-axis choice.
    /// Applied along +Y for Y-up files and along +Z for Z-up ones.
    bone_length: f32 = 10.0,
    /// Emit a Z-up skeleton (offsets run along +Z). Neither real fixture is Z-up, so this
    /// is the only way to exercise the coordinate-rotation path.
    z_up: bool = false,
    /// `\r\n` like both real fixtures, rather than bare `\n`.
    crlf: bool = true,
    /// Appended to each joint's name. Used to push names past `BoneInfo`'s 32-byte limit.
    name_prefix: []const u8 = "",
    /// Emit an `End Site` under the last joint, as real files do.
    end_site: bool = true,
    /// Degrees added to the FIRST rotation channel of joint `j` at frame `f`, as
    /// `rotation_step * (f + 1) * (j + 1)`. Zero gives a rest pose whose FK answer is
    /// trivially the bone chain, which is the easiest thing to assert first.
    rotation_step: f32 = 0.0,
    /// Root translation per frame, in file units.
    root_step: [3]f32 = .{ 0.0, 0.0, 0.0 },
};

fn writeIndent(out: *std.ArrayList(u8), gpa: Allocator, depth: usize) !void {
    for (0..depth) |_| {
        try out.append(gpa, '\t');
    }
}

fn writeLine(out: *std.ArrayList(u8), gpa: Allocator, crlf: bool) !void {
    if (crlf) {
        try out.append(gpa, '\r');
    }
    try out.append(gpa, '\n');
}

/// Build a BVH document. Caller owns the returned bytes.
///
/// The skeleton is a straight chain - joint `i+1` is the child of joint `i` - because a
/// chain is the shape whose forward kinematics a test can state in closed form. Branching
/// skeletons are what the real fixtures are for.
pub fn generate(gpa: Allocator, opts: Options) ![]u8 {
    assert(opts.joint_count >= 1, @src());

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const w: *std.ArrayList(u8) = &out;

    const rot: [3]Channel = opts.rotation_order.channels();
    // The bone points along +Z for a Z-up file and +Y otherwise. This is the ONLY difference
    // a Z-up fixture has, which is exactly what makes it a clean test of the up-axis logic.
    const bone: [3]f32 = if (opts.z_up)
        .{ 0.0, 0.0, opts.bone_length }
    else
        .{ 0.0, opts.bone_length, 0.0 };

    try w.appendSlice(gpa, "HIERARCHY");
    try writeLine(w, gpa, opts.crlf);

    // Hierarchy: a chain, so depth == joint index.
    for (0..opts.joint_count) |i| {
        try writeIndent(w, gpa, i);
        if (i == 0) {
            try w.print(gpa, "ROOT {s}Joint{d}", .{ opts.name_prefix, i });
        } else {
            try w.print(gpa, "JOINT {s}Joint{d}", .{ opts.name_prefix, i });
        }
        try writeLine(w, gpa, opts.crlf);
        try writeIndent(w, gpa, i);
        try w.appendSlice(gpa, "{");
        try writeLine(w, gpa, opts.crlf);

        // The root sits at the origin; every other joint is offset from its parent by the
        // bone vector. A non-zero root offset is a WORLD PLACEMENT, not a bone - dance1 has
        // one and it skews the up-axis heuristic - so it is deliberately left at zero here.
        const off: [3]f32 = if (i == 0) .{ 0.0, 0.0, 0.0 } else bone;
        try writeIndent(w, gpa, i + 1);
        try w.print(gpa, "OFFSET {d:.6} {d:.6} {d:.6}", .{ off[0], off[1], off[2] });
        try writeLine(w, gpa, opts.crlf);

        const with_position: bool = (opts.layout == .all_joints) or (i == 0);
        try writeIndent(w, gpa, i + 1);
        if (with_position) {
            try w.print(gpa, "CHANNELS 6 Xposition Yposition Zposition {s} {s} {s}", .{
                rot[0].text(), rot[1].text(), rot[2].text(),
            });
        } else {
            try w.print(gpa, "CHANNELS 3 {s} {s} {s}", .{ rot[0].text(), rot[1].text(), rot[2].text() });
        }
        try writeLine(w, gpa, opts.crlf);
    }

    // End Site under the deepest joint, then close every brace.
    if (opts.end_site) {
        try writeIndent(w, gpa, opts.joint_count);
        try w.appendSlice(gpa, "End Site");
        try writeLine(w, gpa, opts.crlf);
        try writeIndent(w, gpa, opts.joint_count);
        try w.appendSlice(gpa, "{");
        try writeLine(w, gpa, opts.crlf);
        try writeIndent(w, gpa, opts.joint_count + 1);
        try w.print(gpa, "OFFSET {d:.6} {d:.6} {d:.6}", .{ bone[0], bone[1], bone[2] });
        try writeLine(w, gpa, opts.crlf);
        try writeIndent(w, gpa, opts.joint_count);
        try w.appendSlice(gpa, "}");
        try writeLine(w, gpa, opts.crlf);
    }
    var close: usize = opts.joint_count;
    while (close > 0) {
        close -= 1;
        try writeIndent(w, gpa, close);
        try w.appendSlice(gpa, "}");
        try writeLine(w, gpa, opts.crlf);
    }

    try w.appendSlice(gpa, "MOTION");
    try writeLine(w, gpa, opts.crlf);
    try w.print(gpa, "Frames: {d}", .{opts.frame_count});
    try writeLine(w, gpa, opts.crlf);
    try w.print(gpa, "Frame Time: {d:.6}", .{opts.frame_time});
    try writeLine(w, gpa, opts.crlf);

    for (0..opts.frame_count) |f| {
        const ff: f32 = @floatFromInt(f + 1);
        for (0..opts.joint_count) |j| {
            const jf: f32 = @floatFromInt(j + 1);
            const with_position: bool = (opts.layout == .all_joints) or (j == 0);
            if (with_position) {
                // Only the root actually travels; a non-root joint with position channels
                // (the dance1 shape) is emitted at its bone offset so that the pose is the
                // same whether or not the reader honours the OFFSET. That equivalence is
                // itself worth a test.
                const base: [3]f32 = if (j == 0) .{ 0.0, 0.0, 0.0 } else bone;
                if (j != 0) {
                    try w.print(gpa, "{d:.6} {d:.6} {d:.6} ", .{ base[0], base[1], base[2] });
                } else {
                    try w.print(gpa, "{d:.6} {d:.6} {d:.6} ", .{
                        opts.root_step[0] * ff,
                        opts.root_step[1] * ff,
                        opts.root_step[2] * ff,
                    });
                }
            }
            // Angle goes on the FIRST rotation channel only, so a reader that composes in
            // the wrong order still produces a DIFFERENT answer (one axis is unambiguous).
            const angle: f32 = opts.rotation_step * ff * jf;
            try w.print(gpa, "{d:.6} 0.000000 0.000000 ", .{angle});
        }
        try writeLine(w, gpa, opts.crlf);
    }

    return out.toOwnedSlice(gpa);
}

test "synth: the generated document has the shape the options asked for" {
    const gpa: Allocator = std.testing.allocator;
    const bytes: []u8 = try generate(gpa, .{
        .joint_count = 2,
        .frame_count = 3,
        .layout = .root_only,
        .rotation_order = .xyz,
    });
    defer gpa.free(bytes);

    // Root carries 6 channels, the child 3 - the 2FeetJump shape.
    try expect(indexOf(u8, bytes, "CHANNELS 6 Xposition Yposition Zposition Xrotation Yrotation Zrotation") != null);
    try expect(indexOf(u8, bytes, "CHANNELS 3 Xrotation Yrotation Zrotation") != null);
    try expect(indexOf(u8, bytes, "Frames: 3") != null);
    try expect(indexOf(u8, bytes, "End Site") != null);
    // CRLF by default, like both real fixtures.
    try expect(indexOf(u8, bytes, "\r\n") != null);
}

test "synth: rotation order and layout are free parameters, not constants" {
    const gpa: Allocator = std.testing.allocator;
    const zyx: []u8 = try generate(gpa, .{ .rotation_order = .zyx, .layout = .all_joints, .joint_count = 2 });
    defer gpa.free(zyx);
    // dance1's shape: 6 channels on EVERY joint, ZYX order.
    try expect(indexOf(u8, zyx, "Zrotation Yrotation Xrotation") != null);
    try expect(indexOf(u8, zyx, "CHANNELS 3 ") == null);

    const zup: []u8 = try generate(gpa, .{ .z_up = true, .joint_count = 2, .bone_length = 10.0 });
    defer gpa.free(zup);
    // A Z-up skeleton puts the bone on Z; neither real fixture can test this path.
    try expect(indexOf(u8, zup, "OFFSET 0.000000 0.000000 10.000000") != null);
}
