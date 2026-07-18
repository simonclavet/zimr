//! shared_smoke — workgroup shared-memory + barrier DIAGNOSTIC, on device.
//! Runs the `diag` kernel once and checks three independent results so a single
//! run pinpoints which primitive works on this GPU:
//!   1. local id     (out_localid)  — is local_invocation_id delivered?
//!   2. shared self  (out_self)     — does a workgroup var round-trip a value?
//!   3. shared rotate(out_rotate)   — does cross-thread sharing + the barrier work?
//! Each line shows PASS (green) or FAIL (red, with mismatch count). The CPU
//! backend runs the same kernel at startup as an independent oracle.
const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const shared_rotate = @import("shared_rotate.zig");
const zm = @import("zm");
const Color = zm.Color;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const diag_wgsl = @embedFile("shared_rotate_wgsl");

const count: u32 = 1024; // 4 full workgroups of 256 (must be a multiple of wg_size)

const State = struct {
    font: z.Font,
    pipe: z.Compute(shared_rotate),
    cpu_ok: bool = false,
    dispatched: bool = false,
    have_result: bool = false,
    miss_localid: u32 = count,
    miss_self: u32 = count,
    miss_rotate: u32 = count,
};

fn deinit(gpa: Allocator, s: *State) void {
    _ = gpa;
    s.pipe.deinit();
}

fn expectLocalId(gid: u32) f32 {
    return @floatFromInt(gid % shared_rotate.wg_size);
}
fn expectSelf(gid: u32) f32 {
    return @floatFromInt(gid);
}
fn expectRotate(gid: u32) f32 {
    const wg: u32 = shared_rotate.wg_size;
    const base: u32 = (gid / wg) * wg;
    const lid: u32 = gid % wg;
    return @floatFromInt(base + ((lid + 1) % wg));
}

fn countMismatch(out: []const f32, comptime expect: fn (u32) f32) u32 {
    var m: u32 = 0;
    var i: u32 = 0;
    while (i < count and i < out.len) : (i += 1) {
        if (out[i] != expect(i)) {
            m += 1;
        }
    }
    return m;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);

    // CPU-backend oracle.
    var cpu: z.Compute(shared_rotate) = z.Compute(shared_rotate).initCpu();
    cpu.element_count = count;
    cpu.params = .{ .count = count };
    var probe: [count]f32 = undefined;
    for (0..count) |i| {
        probe[i] = @floatFromInt(i);
    }
    cpu.upload(.input, probe[0..]);
    cpu.run("diag", count);
    const cl: []const f32 = cpu.readLatest(.out_localid).?;
    const cs: []const f32 = cpu.readLatest(.out_self).?;
    const cr: []const f32 = cpu.readLatest(.out_rotate).?;
    const cpu_ok: bool = countMismatch(cl, expectLocalId) == 0 and
        countMismatch(cs, expectSelf) == 0 and countMismatch(cr, expectRotate) == 0;

    // GPU round-trip.
    var pipe: z.Compute(shared_rotate) = try z.Compute(shared_rotate).initGpu(
        gpa,
        f.gpu.device,
        f.gpu.queue,
        &.{.{ .name = "diag", .wgsl = diag_wgsl }},
    );
    pipe.element_count = count;
    pipe.params = .{ .count = count };
    var input: [count]f32 = undefined;
    for (0..count) |i| {
        input[i] = @floatFromInt(i);
    }
    pipe.upload(.input, input[0..]);

    s.* = .{ .font = font, .pipe = pipe, .cpu_ok = cpu_ok };
}

fn drawLine(
    f: *z.Frame,
    s: *State,
    label: []const u8,
    miss: u32,
    y: *f32,
) void {
    var buf: [128]u8 = undefined;
    const txt: []const u8 = if (!s.have_result)
        bufPrint(&buf, "{s}: ...", .{label}) catch label
    else if (miss == 0)
        bufPrint(&buf, "{s}: PASS", .{label}) catch label
    else
        bufPrint(&buf, "{s}: FAIL ({d}/{d} wrong)", .{ label, miss, count }) catch label;
    const col: Color = if (!s.have_result)
        z.colors.slate_300
    else if (miss == 0)
        z.colors.green_400
    else
        z.colors.red_500;
    f.gl.text(.{ 14, y.* }, txt, .{ .size = 20, .color = col, .font = &s.font });
    y.* += 30;
}

fn update(f: *z.Frame, s: *State) void {
    if (!s.dispatched) {
        s.dispatched = true;
        s.pipe.run("diag", count);
    }
    // All three outputs land together; read them once the readback is ready.
    if (s.pipe.readLatest(.out_rotate)) |rot| {
        if (s.pipe.readLatest(.out_localid)) |lid| {
            if (s.pipe.readLatest(.out_self)) |slf| {
                s.miss_localid = countMismatch(lid, expectLocalId);
                s.miss_self = countMismatch(slf, expectSelf);
                s.miss_rotate = countMismatch(rot, expectRotate);
                s.have_result = true;
            }
        }
    }

    z.clearViewport(f, z.colors.slate_900);

    var y: f32 = 14;
    drawLine(f, s, "1. local_invocation_id", s.miss_localid, &y);
    drawLine(f, s, "2. shared var self-roundtrip", s.miss_self, &y);
    drawLine(f, s, "3. shared + barrier (rotate)", s.miss_rotate, &y);

    y += 12;
    const cpu_msg: []const u8 = if (s.cpu_ok) "CPU oracle: PASS" else "CPU oracle: FAIL";
    f.gl.text(
        .{ 14, y },
        cpu_msg,
        .{ .size = 15, .color = if (s.cpu_ok) z.colors.green_400 else z.colors.red_500, .font = &s.font },
    );

    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - shared memory diagnostic",
            .width = 760,
            .height = 420,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
