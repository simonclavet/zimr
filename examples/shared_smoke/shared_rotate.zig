//! shared_rotate.zig - workgroup shared-memory + barrier DIAGNOSTIC.
//!
//! One dispatch writes THREE separate result buffers so a single device run
//! pinpoints exactly which primitive works:
//!   out_localid[gid] = local_invocation_id         -> is the local id delivered?
//!   out_self[gid]    = tile[lid]    (own slot)      -> does a workgroup var even
//!                                                      round-trip a value?
//!   out_rotate[gid]  = tile[(lid+1)%wg] (neighbour) -> does cross-thread sharing
//!                                                      + the barrier work?
//! All three reads happen AFTER one barrier over a tile each thread filled with
//! its own input value. Expected (input[i] == i, wg_size == 256):
//!   out_localid[gid] == gid % 256
//!   out_self[gid]    == gid
//!   out_rotate[gid]  == base + (lid+1)%256   (left-rotate within the block)
//!
//! GPU path uses k.shared / k.localId / k.workgroupBarrier. CPU path computes
//! the same values directly (the oracle). The barrier is in UNIFORM control
//! flow (no early-return; count is an exact multiple of wg_size).
const k = @import("kompute");
const zm = @import("zm");
const float = zm.float;

pub const config = k.Config{ .max = 1024, .workgroup = 256 };

/// Workgroup size as a comptime constant (the rotate modulus + tile length).
pub const wg_size: u32 = config.workgroup;

pub const Buffers = extern struct {
    input: [config.max]f32,
    out_localid: [config.max]f32,
    out_self: [config.max]f32,
    out_rotate: [config.max]f32,
};

pub const Params = extern struct {
    count: u32,
    _pad0: u32 = 0,
    _pad1: u32 = 0,
    _pad2: u32 = 0,
};

pub const g = k.Globals(@This());
const b_input = g.bind(.input);
const b_out_localid = g.bind(.out_localid);
const b_out_self = g.bind(.out_self);
const b_out_rotate = g.bind(.out_rotate);
const tile = k.shared(f32, wg_size, "rot_tile");

pub fn diag(c: k.Ctx(@This())) void {
    const gid: u32 = c.id;
    if (k.is_gpu) {
        const lid: u32 = k.localId();
        b_out_localid[gid] = @floatFromInt(lid);
        tile[lid] = b_input[gid];
        k.workgroupBarrier();
        b_out_self[gid] = tile[lid];
        const src: u32 = (lid + 1) % wg_size;
        b_out_rotate[gid] = tile[src];
    } else {
        if (gid >= c.params.count) {
            return;
        }
        const base: u32 = (gid / wg_size) * wg_size;
        const lid: u32 = gid % wg_size;
        b_out_localid[gid] = @floatFromInt(lid);
        b_out_self[gid] = b_input[gid];
        b_out_rotate[gid] = b_input[base + ((lid + 1) % wg_size)];
    }
}

comptime {
    k.installKernel(@This(), "diag");
}

test "shared_rotate CPU oracle: diag buffers" {
    // lint:off import-at-top: test-local std keeps the file free of a col-0 std import
    const std = @import("std");
    const N: u32 = 1024;
    g.P = .{ .count = N };
    for (0..N) |i| {
        g.B.input[i] = @floatFromInt(i);
    }
    var id: u32 = 0;
    while (id < N) : (id += 1) {
        diag(.{ .id = id, .params = g.P });
    }
    for (0..N) |gi| {
        const gid: u32 = @intCast(gi);
        const base: u32 = (gid / wg_size) * wg_size;
        const lid: u32 = gid % wg_size;
        try std.testing.expectEqual(float(lid), g.B.out_localid[gi]);
        try std.testing.expectEqual(float(gid), g.B.out_self[gi]);
        const want_rot: f32 = float(base + ((lid + 1) % wg_size));
        try std.testing.expectEqual(want_rot, g.B.out_rotate[gi]);
    }
}
