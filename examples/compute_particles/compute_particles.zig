//! compute_particles — 65536 particles driven by `z.Compute`, demonstrating the
//! CPU/GPU compute toggle on the zero-copy render path. The SAME kernel auto-flips
//! between a GPU dispatch and a CPU loop every few seconds, with the live state carried
//! across the flip so the sim never resets. Both backends render through `z.DrawPoints`:
//! the GPU path is zero-copy (the kernel writes the very buffer the vertex shader reads)
//! and the CPU path copies its result into that buffer, then draws the same way.
const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const Vec2 = zm.Vec2;
const particle_step = @import("particle_step.zig");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const step_wgsl = @embedFile("particle_step_wgsl");

const particle_count: u32 = 8192;
const screen_w: f32 = 720.0;
const screen_h: f32 = 720.0;
const flip_frames: u32 = 300; // auto-toggle the compute backend on this cadence

const State = struct {
    font: z.Font,
    pipe: z.Compute(particle_step),
    dp: z.DrawPoints,
    transfer_pos: []Vec2,
    transfer_vel: []Vec2,
    cpu_ok: bool = false,
    frame: u32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.pipe.deinit(); // compute pipeline + storage/uniform/staging buffers + bind group
    s.dp.deinit(); // points render pipeline + its Resources (pos_buffer is borrowed)
    gpa.free(s.transfer_pos);
    gpa.free(s.transfer_vel);
}

fn spawn(
    pipe: *z.Compute(particle_step),
    scratch: []Vec2,
    rng: std.Random,
) void {
    var i: u32 = 0;
    while (i < particle_count) : (i += 1) {
        scratch[i] = .{ 0.1 + rng.float(f32) * 0.8, rng.float(f32) * 0.4 };
    }
    pipe.upload(.pos, scratch[0..particle_count]);
    i = 0;
    while (i < particle_count) : (i += 1) {
        scratch[i] = .{ (rng.float(f32) - 0.5) * 0.2, (rng.float(f32) - 0.5) * 0.1 };
    }
    pipe.upload(.vel, scratch[0..particle_count]);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);

    // CPU-backend self-check: a particle at rest must fall after one step.
    var cpu: z.Compute(particle_step) = z.Compute(particle_step).initCpu();
    cpu.element_count = 1;
    cpu.params = .{ .count = 1, .dt = 0.1, .gravity = 10.0, .damping = 0.5 };
    const one_pos = [_]Vec2{.{ 0.5, 0.5 }};
    const one_vel = [_]Vec2{.{ 0.0, 0.0 }};
    cpu.upload(.pos, &one_pos);
    cpu.upload(.vel, &one_vel);
    cpu.run("particleStep", 1);
    const cpu_pos: []const Vec2 = cpu.readLatest(.pos).?;
    const cpu_ok: bool = cpu_pos[0][1] > 0.5;

    // GPU backend: a single pipe whose `.backend` we flip live. initGpu also wires the
    // CPU path (the kernel's module globals always exist), so one pipe runs both.
    var pipe: z.Compute(particle_step) = try z.Compute(particle_step).initGpu(
        gpa,
        f.gpu.device,
        f.gpu.queue,
        &.{.{ .name = "particleStep", .wgsl = step_wgsl }},
    );
    pipe.element_count = particle_count;
    pipe.params = .{ .count = particle_count, .dt = 1.0 / 60.0, .gravity = 1.5, .damping = 0.6 };

    const transfer_pos: []Vec2 = try gpa.alloc(Vec2, particle_count);
    const transfer_vel: []Vec2 = try gpa.alloc(Vec2, particle_count);
    var prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0x5eed);
    spawn(&pipe, transfer_pos, prng.random()); // reuse transfer_pos as spawn scratch

    const dp: z.DrawPoints = try z.DrawPoints.init(
        f.gpu,
        gpa,
        f.gpu.device,
        f.gpu.queue,
        f.gpu.backbuffer_format,
        pipe.fieldBuffer(.pos).?,
        particle_step.config.max * 8,
    );

    s.* = .{
        .font = font,
        .pipe = pipe,
        .dp = dp,
        .transfer_pos = transfer_pos,
        .transfer_vel = transfer_vel,
        .cpu_ok = cpu_ok,
    };
}

fn update(f: *z.Frame, s: *State) void {
    s.frame += 1;

    // Auto-flip the compute backend, carrying the live state across so the sim
    // continues seamlessly (one GPU readback per flip, not per frame).
    if (s.frame % flip_frames == 0) {
        if (s.pipe.readLatest(.pos)) |pos| {
            @memcpy(s.transfer_pos[0..pos.len], pos);
        }
        if (s.pipe.readLatest(.vel)) |vel| {
            @memcpy(s.transfer_vel[0..vel.len], vel);
        }
        s.pipe.backend = if (s.pipe.backend == .gpu) .cpu else .gpu;
        s.pipe.upload(.pos, s.transfer_pos[0..particle_count]);
        s.pipe.upload(.vel, s.transfer_vel[0..particle_count]);
    }

    s.pipe.run("particleStep", particle_count); // GPU dispatch or CPU loop, per s.pipe.backend

    // CPU result lives in host memory — copy it into the buffer DrawPoints renders.
    // (The GPU path skips this: the kernel already wrote that buffer in place.)
    if (s.pipe.backend == .cpu) {
        if (s.pipe.readLatest(.pos)) |pos| {
            s.dp.uploadPositions(std.mem.sliceAsBytes(pos[0..particle_count]));
        }
    }

    z.clearViewport(f, z.colors.slate_900);
    s.dp.draw(f.gl, particle_count, screen_w, screen_h, .{ .size_px = 2.0 });

    const is_gpu: bool = s.pipe.backend == .gpu;
    const backend_name: []const u8 = if (is_gpu) "GPU compute" else "CPU compute";
    const render_note: []const u8 = if (is_gpu) "zero-copy" else "host upload";
    var buf: [112]u8 = undefined;
    const hud: []const u8 = bufPrint(
        &buf,
        "backend: {s} | {d} particles | {s} render (auto-toggle)",
        .{ backend_name, particle_count, render_note },
    ) catch "particles";
    f.gl.text(.{ 10, 10 }, hud, .{ .size = 18, .color = z.colors.slate_100, .font = &s.font });
    const cpu_msg: []const u8 = if (s.cpu_ok)
        "same kernel runs on both backends (CPU self-check: OK)"
    else
        "CPU backend self-check: FAIL";
    const cpu_col: Color = z.colorFromHSV(if (s.cpu_ok) 120.0 else 0.0, 0.7, 0.95);
    f.gl.text(.{ 10, 32 }, cpu_msg, .{ .size = 14, .color = cpu_col, .font = &s.font });

    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - compute particles",
            .width = 720,
            .height = 720,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
