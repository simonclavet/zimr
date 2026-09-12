//! src/shader_connect.zig — comptime-monomorphized varying connector.
//!
//! Bridges a vertex shader's `Out` to a fragment shader's `Io` by
//! matching field names.  Used by:
//!   - `shader_runtime.zig` (browser path) internally during pipeline
//!     creation to wire varyings
//!   - native examples (CPU path) to connect VS outputs to FS inputs
//!     during `raster_shader.rasterizeTriangles` dispatch
//!
//! Lives in its own module (zero dependencies beyond `std`) so both
//! the browser-side and native-side code can import it without pulling
//! the other's transitive deps.  This is the smallest possible
//! shared module that closes the duplication: prior to its existence,
//! `autoConnect` was copy-pasted into every native example.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const std = @import("std");
const eql = std.mem.eql;
const expectEqual = std.testing.expectEqual;

/// Returns a comptime-monomorphized function that copies fields from
/// a VS `Out` struct to a FS `Io` struct by matching field names.
///
/// The `position` field is skipped — that's the clip-space output the
/// rasterizer uses for triangle setup, not a varying.  Any other field
/// in `VsOut` that also appears in `FsIo` is copied; fields in `FsIo`
/// that aren't in `VsOut` are left alone (preserving caller-set UBO
/// values, sampler bindings, etc.).
pub fn autoConnect(comptime VsOut: type, comptime FsIo: type) fn (VsOut, *FsIo) void {
    return struct {
        fn connect(vs_out: VsOut, fs_io: *FsIo) void {
            inline for (@typeInfo(VsOut).@"struct".field_names) |vs_field_name| {
                if (comptime eql(u8, vs_field_name, "position")) continue;
                if (comptime @hasField(FsIo, vs_field_name)) {
                    @field(fs_io.*, vs_field_name) = @field(vs_out, vs_field_name);
                }
            }
        }
    }.connect;
}

test "autoConnect skips position, copies matching varyings" {
    const VsOut = struct {
        position: Vec,
        frag_color: Vec,
        frag_uv: Vec2,
    };
    const FsIo = struct {
        frag_color: Vec,
        frag_uv: Vec2,
        unrelated: f32, // not in VsOut; should be left alone
    };

    const connect = autoConnect(VsOut, FsIo);
    const vs_out: VsOut = .{
        .position = .{ 0, 0, 0, 1 },
        .frag_color = .{ 1, 0.5, 0, 1 },
        .frag_uv = .{ 0.3, 0.7 },
    };
    var fs_io: FsIo = .{
        .frag_color = .{ 0, 0, 0, 0 },
        .frag_uv = .{ 0, 0 },
        .unrelated = 42,
    };
    connect(vs_out, &fs_io);

    try expectEqual(Vec{ 1, 0.5, 0, 1 }, fs_io.frag_color);
    try expectEqual(Vec2{ 0.3, 0.7 }, fs_io.frag_uv);
    try expectEqual(@as(f32, 42), fs_io.unrelated); // untouched
}
