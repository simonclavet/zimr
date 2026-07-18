//! compute_smoke — the GPU compute round-trip, now driven by `z.Compute(M)`
//! instead of hand-wired wgpu calls. Uploads [0,1,2,...,particle_count-1], runs the `double_it`
//! kernel (out[i] = in[i]*2) on the GPU, reads it back, draws it as bars (a correct
//! run = a doubled ascending staircase). Also runs a CPU-backend self-check at
//! startup over the SAME kernel, demonstrating the runtime CPU/GPU toggle.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const float = zm.float;
const double_it = @import("double_it.zig");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
// The compiled WGSL of double_it.zig (built by addComputeImport + spv2wgsl).
const double_wgsl = @embedFile("double_it_wgsl");

const particle_count: u32 = 64; // particles processed (the dispatch count)

const State = struct {
    font: z.Font,
    pipe: z.Compute(double_it),
    cpu_ok: bool = false,
    dispatched: bool = false,
    result: [particle_count]f32 = @splat(0),
    have_result: bool = false,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.pipe.deinit(); // compute pipeline + per-field storage/uniform/staging buffers + bind group
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);

    // CPU-backend self-check: run the SAME kernel on the CPU and verify doubling.
    var cpu: z.Compute(double_it) = z.Compute(double_it).initCpu();
    cpu.element_count = 5;
    cpu.params = .{ .count = 5 };
    const probe = [_]f32{ 1, 2, 3, 4, 5 };
    cpu.upload(.data, &probe);
    cpu.run("double", 5);
    const cpu_out: []const f32 = cpu.readLatest(.data).?;
    const cpu_ok: bool = cpu_out.len == 5 and cpu_out[0] == 2.0 and cpu_out[1] == 4.0 and cpu_out[4] == 10.0;

    // GPU-backend round-trip via z.Compute (storage/uniform/staging/pipeline derived
    // from the kernel's schema; the minBindingSize footgun cannot recur).
    var pipe: z.Compute(double_it) = try z.Compute(double_it).initGpu(
        gpa,
        f.gpu.device,
        f.gpu.queue,
        &.{.{ .name = "double", .wgsl = double_wgsl }},
    );
    pipe.element_count = particle_count;
    pipe.params = .{ .count = particle_count };
    var input: [particle_count]f32 = undefined;
    var i: u32 = 0;
    while (i < particle_count) : (i += 1) {
        input[i] = @floatFromInt(i);
    }
    pipe.upload(.data, input[0..]);

    s.* = .{ .font = font, .pipe = pipe, .cpu_ok = cpu_ok };
}

fn update(f: *z.Frame, s: *State) void {
    // One-shot dispatch (the kernel doubles in place, so running it once is enough).
    if (!s.dispatched) {
        s.dispatched = true;
        s.pipe.run("double", particle_count);
    }
    // Frame-delayed readback: returns last frame's mapped data, never stalls.
    if (s.pipe.readLatest(.data)) |out| {
        var i: u32 = 0;
        while (i < particle_count and i < out.len) : (i += 1) {
            s.result[i] = out[i];
        }
        s.have_result = true;
    }

    z.clearViewport(f, z.colors.slate_900);

    const sw: f32 = f.window.widthf();
    const sh: f32 = f.window.heightf();
    const bar_w: f32 = sw / float(particle_count);
    const max_val: f32 = float((particle_count - 1) * 2);
    var i: u32 = 0;
    while (i < particle_count) : (i += 1) {
        const v: f32 = s.result[i];
        const h: f32 = (v / max_val) * (sh * 0.8);
        const x: f32 = float(i) * bar_w;
        const hue: f32 = float(i) / float(particle_count) * 300.0;
        const col: Color = z.colorFromHSV(hue, 0.7, 0.95);
        f.gl.rect(.{ .x = x, .y = sh - h, .width = bar_w - 1, .height = h }, .{ .color = col });
    }

    const status: []const u8 = if (s.have_result)
        "GPU via z.Compute: out[i] = i*2 (doubled staircase)"
    else
        "dispatching...";
    f.gl.text(.{ 10, 10 }, status, .{ .size = 18, .color = z.colors.slate_100, .font = &s.font });
    const cpu_msg: []const u8 = if (s.cpu_ok)
        "CPU backend self-check: OK (1,2,3,4,5 -> 2,4,6,8,10)"
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
            .title = "zimr - WebGPU - compute smoke (z.Compute)",
            .width = 640,
            .height = 360,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
