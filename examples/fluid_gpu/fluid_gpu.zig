//! fluid_gpu — 20,000-particle Clavet fluid, ENTIRELY on the GPU.
//!
//! The arc closes: examples/sph_fluid_2d ported the algorithm to a CPU
//! loop because the GL backend had no compute. This is the same paper running
//! where it belongs — seven kompute kernels (fluid_kernels.zig), each
//! translated once to its own WGSL module (spv2wgsl --entry, the t1178
//! multi-kernel path), dispatched through ONE `z.Compute` pipe, rendered
//! zero-copy by `z.FluidDiscs` straight from the compute storage buffer.
//! Positions never visit the CPU.
//!
//! Per frame: 1 substep × 7 dispatches (gravityMouse → buildGrid →
//! viscosity → predict → buildGrid → density → force → applyAndFinalize),
//! then one instanced draw of N SDF discs coloured by density.
//!
//! Controls: drag = push, shift+drag (or the toggle) = pull; sliders for the
//! paper's four knobs; reset = dam-break.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float64 = zm.float64;
const float = zm.float;
const Vec2 = zm.Vec2;
const clamp = zm.clamp;
const fk = @import("fluid_kernels.zig");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const buildGrid_wgsl = @embedFile("buildGrid_wgsl");
const clearGrid_wgsl = @embedFile("clearGrid_wgsl");
const gravityMouse_wgsl = @embedFile("gravityMouse_wgsl");
const viscosity_wgsl = @embedFile("viscosity_wgsl");
const predict_wgsl = @embedFile("predict_wgsl");
const density_wgsl = @embedFile("density_wgsl");
const densityTiled_wgsl = @embedFile("densityTiled_wgsl");
const densityPig_wgsl = @embedFile("densityPig_wgsl");
const force_wgsl = @embedFile("force_wgsl");
const forcePig_wgsl = @embedFile("forcePig_wgsl");
const applyAndFinalize_wgsl = @embedFile("applyAndFinalize_wgsl");
const fallBounceLean_wgsl = @embedFile("fallBounceLean_wgsl");

const substeps: u32 = 1;
/// Sim-pixel radius of a rendered disc (the reference's RENDER_RADIUS).
const mouse_radius: f32 = 90.0;

/// t1178 HANDROLLED: the working hand-written JS demo's exact WebGPU shape,
/// reproduced through zimr's bridge — hand WGSL, SEPARATE runtime-sized
/// buffers per array, separate bindings. Same device, same submit pattern;
/// only the binding/struct shape differs from kompute's megastruct. If this
/// is stable at 20000 where the megastruct explodes at ~1000, the megastruct
/// is convicted and the kompute refactor direction is proven.
const handrolled_wgsl =
    \\struct P {
    \\    count: u32, dt: f32, gravity: f32, dom_w: f32,
    \\    dom_h: f32, pad0: f32, pad1: f32, pad2: f32,
    \\};
    \\@group(0) @binding(0) var<uniform> params: P;
    \\@group(0) @binding(1) var<storage, read_write> positions: array<vec2<f32>>;
    \\@group(0) @binding(2) var<storage, read_write> velocities: array<vec2<f32>>;
    \\@compute @workgroup_size(64)
    \\fn bounce(@builtin(global_invocation_id) gid: vec3<u32>) {
    \\    let i = gid.x;
    \\    if (i >= params.count) { return; }
    \\    var p = positions[i];
    \\    var v = velocities[i];
    \\    v.y = v.y + params.gravity * params.dt;
    \\    p = p + v * params.dt;
    \\    let r = 5.5;
    \\    if (p.x < r) { p.x = r; v.x = -v.x * 0.85; }
    \\    if (p.x > params.dom_w - r) { p.x = params.dom_w - r; v.x = -v.x * 0.85; }
    \\    if (p.y < r) { p.y = r; v.y = -v.y * 0.85; }
    \\    if (p.y > params.dom_h - r) { p.y = params.dom_h - r; v.y = -v.y * 0.85; }
    \\    positions[i] = p;
    \\    velocities[i] = v;
    \\}
;

const HandP = extern struct {
    count: u32,
    dt: f32,
    gravity: f32,
    dom_w: f32,
    dom_h: f32,
    pad0: f32 = 0,
    pad1: f32 = 0,
    pad2: f32 = 0,
};

const Handrolled = struct {
    pos_buf: z.wgpu.BufferHandle,
    vel_buf: z.wgpu.BufferHandle,
    uni_buf: z.wgpu.BufferHandle,
    pipeline: z.wgpu.ComputePipelineHandle,
    bind_group: z.wgpu.BindGroupHandle,
    queue: z.wgpu.QueueHandle,
    dev: z.wgpu.DeviceHandle,

    fn init(
        gpa: Allocator,
        dev: z.wgpu.DeviceHandle,
        queue: z.wgpu.QueueHandle,
    ) !Handrolled {
        const n_bytes: u32 = fk.num_particles * 8;
        const pos_buf: z.wgpu.BufferHandle = z.wgpu.createBuffer(dev, .{
            .size = n_bytes,
            .usage = .{ .storage = true, .copy_src = true, .copy_dst = true },
            .label = "hand_positions",
        });
        const vel_buf: z.wgpu.BufferHandle = z.wgpu.createBuffer(dev, .{
            .size = n_bytes,
            .usage = .{ .storage = true, .copy_dst = true },
            .label = "hand_velocities",
        });
        const uni_buf: z.wgpu.BufferHandle = z.wgpu.createBuffer(dev, .{
            .size = @sizeOf(HandP),
            .usage = .{ .uniform = true, .copy_dst = true },
            .label = "hand_params",
        });
        const layout_entries = [_]z.shader_introspect.BindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = .{ .compute = true },
                .resource = .{ .uniform_buffer = .{ .min_size = @sizeOf(HandP) } },
            },
            .{
                .binding = 1,
                .visibility = .{ .compute = true },
                .resource = .{ .storage_buffer = .{ .read_only = false, .min_size = n_bytes } },
            },
            .{
                .binding = 2,
                .visibility = .{ .compute = true },
                .resource = .{ .storage_buffer = .{ .read_only = false, .min_size = n_bytes } },
            },
        };
        const bgl_blob: []const u8 = try z.gpu.encodeBindGroupLayoutEntries(gpa, &layout_entries);
        defer gpa.free(bgl_blob);
        const bgl: z.wgpu.BindGroupLayoutHandle = z.wgpu.createBindGroupLayout(dev, bgl_blob, "hand_bgl");
        const pl: z.wgpu.PipelineLayoutHandle = z.wgpu.createPipelineLayout(dev, &.{bgl}, "hand_pl");
        const module: z.wgpu.ShaderModuleHandle = z.wgpu.createShaderModuleWgsl(dev, handrolled_wgsl, "hand_bounce");
        const pipeline: z.wgpu.ComputePipelineHandle = z.wgpu.createComputePipeline(
            dev,
            pl,
            module,
            "bounce",
            "hand_pipeline",
        );
        const bg_entries = [_]z.gpu.BindGroupEntry{
            .{ .binding = 0, .resource = .{ .buffer = .{ .handle = uni_buf } } },
            .{ .binding = 1, .resource = .{ .buffer = .{ .handle = pos_buf } } },
            .{ .binding = 2, .resource = .{ .buffer = .{ .handle = vel_buf } } },
        };
        const bg_blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &bg_entries);
        defer gpa.free(bg_blob);
        const bind_group: z.wgpu.BindGroupHandle = z.wgpu.createBindGroup(dev, bgl, bg_blob, "hand_bg");
        // Build-only handles: the pipeline + bind group retain them internally,
        // so release the source handles now (explicit ownership, no leak).
        z.wgpu.destroyShaderModule(module);
        z.wgpu.destroyPipelineLayout(pl);
        z.wgpu.destroyBindGroupLayout(bgl);
        return .{
            .pos_buf = pos_buf,
            .vel_buf = vel_buf,
            .uni_buf = uni_buf,
            .pipeline = pipeline,
            .bind_group = bind_group,
            .queue = queue,
            .dev = dev,
        };
    }

    /// Free the three buffers, the compute pipeline, and the bind group this
    /// owns. The example calls this from its `deinit` — managed memory means
    /// every handle has a named owner that releases it.
    fn deinit(h: *Handrolled) void {
        z.wgpu.destroyComputePipeline(h.pipeline);
        z.wgpu.destroyBindGroup(h.bind_group);
        z.wgpu.destroyBuffer(h.pos_buf);
        z.wgpu.destroyBuffer(h.vel_buf);
        z.wgpu.destroyBuffer(h.uni_buf);
    }

    /// One dispatch, encoded and submitted exactly like the JS demo's frame.
    fn step(h: *const Handrolled, count: u32, p: HandP) void {
        z.wgpu.queueWriteBuffer(h.queue, h.uni_buf, 0, std.mem.asBytes(&p));
        const enc: z.wgpu.CommandEncoderHandle = z.wgpu.createCommandEncoder(h.dev);
        const pass: z.wgpu.ComputePassEncoderHandle = z.compute_pass.begin(enc);
        z.compute_pass.setPipeline(pass, h.pipeline);
        z.compute_pass.setBindGroup(pass, 0, h.bind_group);
        z.compute_pass.dispatchWorkgroups(pass, .{ .x = (count + 63) / 64 });
        z.compute_pass.end(pass);
        const cmd: z.wgpu.CommandBufferHandle = z.wgpu.finishCommandEncoder(enc);
        z.wgpu.queueSubmit(h.queue, cmd);
    }
};

const State = struct {
    font: z.Font,
    pipe: z.Compute(fk),
    discs: z.FluidDiscs,
    ui_host: z.UiHost,
    /// Persistent spawn/reset scratch (reset re-seeds through the same
    /// upload path; 20k × 8B is cheap to keep).
    scratch: []Vec2,
    // The paper's knobs (uploaded into Params each frame).
    k_far: f32 = 0.009,
    k_near: f32 = 0.028,
    // ρ0, the rest/desired density: pressure is k_far·(ρ − ρ0). Higher = the
    // fluid wants to pack denser (more cohesive); lower = it expands.
    rest_density: f32 = 15.39,
    gravity_y: f32 = 0.097,
    visc_beta: f32 = 0.017,
    mouse_force_mag: f32 = 3.0,
    attract_toggle: bool = false,
    // ---- diagnostics (t1178 GPU-divergence hunt) ----
    paused: bool = false,
    /// Single compute pass per frame vs one submit per dispatch — the live
    /// A/B for device-side inter-submit coherency (t1178).
    batch_mode: bool = true,
    /// SIMPLE MODE (default): only the fallBounce kernel — gravity +
    /// bounce, zero interaction. The ground-up rebuild step.
    simple_mode: bool = false,
    /// THE DUALITY (t1178): run the SAME kernel fns as plain Zig loops in
    /// wasm, then upload pos+density into the GPU storage buffer the
    /// renderer already binds. CPU correct + GPU corrupt = the compute
    /// dispatch path itself is broken on this device.
    cpu_kernels: bool = false,
    /// t1178 SWEEP: dispatched particle count, runtime-adjustable. Arrays
    /// (and the GPU buffer) stay at the full 20000 so buffer size is held
    /// CONSTANT while the dispatch width sweeps — dragging this finds the
    /// exact cliff where corruption begins on the device.
    sim_count_f: f32 = 20000,
    /// t1178 DECOUPLED RENDER: discs read a SECOND buffer fed by the
    /// frame-delayed readback mirror — the render pass never touches the
    /// live compute storage buffer. If high-count explosions vanish in
    /// this mode, the compute↔render overlap is convicted.
    decoupled: bool = false,
    /// t1178: drive the hand-rolled (JS-shaped) compute instead of kompute.
    handrolled_mode: bool = false,
    hand: Handrolled = undefined,
    mirror_buf: z.wgpu.BufferHandle = .invalid,
    discs_mirror: z.FluidDiscs = undefined,
    adapter_buf: [192]u8 = undefined,
    adapter_len: usize = 0,
    en_gravity: bool = true,
    en_grid: bool = true,
    en_viscosity: bool = true,
    en_predict: bool = true,
    en_density: bool = true,
    // Stage 2b A/B: route the density pass through the shared-memory tiled
    // kernel (one workgroup per cell) instead of the per-particle `density`.
    // OFF by default — the per-particle path is the proven 9.4ms baseline.
    tiled_density: bool = false,
    // Stage 2c A/B: route density+force through the pos-in-grid variants
    // (neighbour positions read from grid_data_pos, contiguous per cell, instead
    // of the random b_pos[j] indirection). OFF by default.
    pos_in_grid: bool = false,
    en_force: bool = true,
    en_apply: bool = true,
    stat_centroid: Vec2 = .{ 0, 0 },
    stat_min: Vec2 = .{ 0, 0 },
    stat_max: Vec2 = .{ 0, 0 },
    stat_rho: f32 = 0,
    /// Mean rho_near — the ALWAYS-REPULSIVE half of Clavet's double density. Printed beside
    /// the far term so the two demos can be compared on the quantity that actually decides
    /// whether a fluid settles, rather than on how they look.
    stat_rho_near: f32 = 0,
    stat_frozen_pct: f32 = 0,
    // Grid occupancy (from grid_counts readback, diagnostics only): the
    // fullest cell, the mean over non-empty cells, and how many cells hit the
    // max_per_cell cap (neighbours dropped → density error). These drive the
    // cell-size + particle-count tuning.
    stat_cell_max: u32 = 0,
    stat_cell_avg: f32 = 0,
    stat_cells_capped: u32 = 0,
    stat_p0: Vec2 = .{ 0, 0 },
    stat_pmid: Vec2 = .{ 0, 0 },
    frame_no: u32 = 0,
    prev_stat_pos: []Vec2,

    // ---- Average-FPS benchmark readout (the baseline-to-beat) ----
    // EMA = a smooth instantaneous-ish number; the windowed average is a
    // STABLE figure recomputed every `fps_window_secs` so the displayed value
    // doesn't jitter while you read it. accum/count build the next window.
    fps_ema: f32 = 0,
    fps_avg: f32 = 0, // published windowed average (the headline number)
    fps_accum_time: f32 = 0, // seconds accumulated in the current window
    fps_accum_frames: u32 = 0,
    fps_min: f32 = 0, // worst frame in the current/last window (1% lows feel)
    fps_min_accum: f32 = 1e9,

    // ---- Vsync-independent benchmark ----
    // Run `bench_mult` sim substeps per displayed frame (1..5). Bump it until
    // FPS drops below the refresh cap (frame time past vsync => compute-bound),
    // then ms/substep is the real, vsync-independent throughput figure to
    // compare before/after a change. ms_frame is the EMA of the whole frame.
    bench_mult: u32 = 3,
    ms_frame: f32 = 0,

    // Collapsing-section open state (closed by default — clean main view).
    show_advanced: bool = false,
    show_diag: bool = false,
    // The whole control panel is collapsed by default: just a small ☰ toggle
    // floats in the corner so the fluid is unobstructed until you want a knob.
    panel_open: bool = false,
};

fn deinit(gpa: Allocator, s: *State) void {
    s.pipe.deinit();
    s.discs.deinit();
    s.discs_mirror.deinit();
    s.hand.deinit();
    if (s.mirror_buf != .invalid) {
        z.wgpu.destroyBuffer(s.mirror_buf);
    }
    s.ui_host.deinit();
    gpa.free(s.scratch);
    gpa.free(s.prev_stat_pos);
    z.unloadFont(gpa, s.font);
}

/// Dam-break: a dense block in the left third, jittered so columns don't
/// lock. Velocities start at zero — gravity does the rest.
fn spawnDamBreak(
    pipe: *z.Compute(fk),
    scratch: []Vec2,
    hand: *const Handrolled,
    mirror_buf: z.wgpu.BufferHandle,
) void {
    var prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0xf1a1d);
    const rng: std.Random = prng.random();
    // CULPRIT EXPERIMENT (t1178 hunt): a packed disk at domain center with
    // the PRESSURE pipeline enabled (grid+density+force+predict+apply) and
    // gravity+viscosity off. Correct physics = a radially SYMMETRIC
    // explosion that settles into an even spread. Any corner-drift or
    // asymmetry convicts the grid-loop kernels on this GPU. (Ground-truth
    // static render already verified: spawn/upload/mapping all correct.)
    var i: u32 = 0;
    while (i < fk.num_particles) : (i += 1) {
        const ang: f32 = rng.float(f32) * 6.2831853;
        const rad: f32 = 220.0 * @sqrt(rng.float(f32));
        scratch[i] = .{
            fk.domain_w * 0.5 + @cos(ang) * rad,
            fk.domain_h * 0.5 + @sin(ang) * rad,
        };
    }
    pipe.upload(.pos, scratch[0..fk.num_particles]);
    @memcpy(fk.g.B.pos[0..fk.num_particles], scratch[0..fk.num_particles]);
    z.wgpu.queueWriteBuffer(hand.queue, hand.pos_buf, 0, std.mem.sliceAsBytes(scratch[0..fk.num_particles]));
    for (scratch[0..fk.num_particles], 0..) |*v, vi| {
        // small deterministic per-particle kick so the bounce reads on screen
        const a: f32 = float(vi % 628) * 0.01;
        v.* = .{ @cos(a) * 2.0, @sin(a) * 1.0 };
    }
    pipe.upload(.vel, scratch[0..fk.num_particles]);
    @memcpy(fk.g.B.vel[0..fk.num_particles], scratch[0..fk.num_particles]);
    z.wgpu.queueWriteBuffer(hand.queue, hand.vel_buf, 0, std.mem.sliceAsBytes(scratch[0..fk.num_particles]));
    pipe.upload(.delta, scratch[0..fk.num_particles]);
    // Lean kernel never writes density: fill it bright ONCE here so the
    // colour reach-in renders visibly (and any 12345 seen later in pos is
    // unambiguous corruption, not this fill — this writes density only).
    for (scratch[0..fk.num_particles]) |*v| {
        v.* = .{ 600.0, 1.0 };
    }
    pipe.upload(.density, scratch[0..fk.num_particles]);
    z.wgpu.queueWriteBuffer(
        hand.queue,
        mirror_buf,
        @offsetOf(fk.Buffers, "density"),
        std.mem.sliceAsBytes(scratch[0..fk.num_particles]),
    );
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);

    var pipe: z.Compute(fk) = try z.Compute(fk).initGpu(
        gpa,
        f.gpu.device,
        f.gpu.queue,
        &.{
            .{ .name = "buildGrid", .wgsl = buildGrid_wgsl },
            .{ .name = "clearGrid", .wgsl = clearGrid_wgsl },
            .{ .name = "gravityMouse", .wgsl = gravityMouse_wgsl },
            .{ .name = "viscosity", .wgsl = viscosity_wgsl },
            .{ .name = "predict", .wgsl = predict_wgsl },
            .{ .name = "density", .wgsl = density_wgsl },
            .{ .name = "densityTiled", .wgsl = densityTiled_wgsl },
            .{ .name = "densityPig", .wgsl = densityPig_wgsl },
            .{ .name = "force", .wgsl = force_wgsl },
            .{ .name = "forcePig", .wgsl = forcePig_wgsl },
            .{ .name = "applyAndFinalize", .wgsl = applyAndFinalize_wgsl },
            .{ .name = "fallBounceLean", .wgsl = fallBounceLean_wgsl },
        },
    );

    // Variable-length fields slice to num_particles on readback: the diagnostics
    // scan and the decoupled-render mirror both want the full buffer. The live
    // slider only sets per-call dispatch width + the disc draw count, not the
    // readback length, so this stays at capacity.
    pipe.element_count = fk.num_particles;

    const scratch: []Vec2 = try gpa.alloc(Vec2, fk.num_particles);
    const prev_stat_pos: []Vec2 = try gpa.alloc(Vec2, fk.num_particles);
    @memset(prev_stat_pos, .{ 0, 0 });
    const hand: Handrolled = try Handrolled.init(gpa, f.gpu.device, f.gpu.queue);
    const mirror_buf_h: z.wgpu.BufferHandle = z.wgpu.createBuffer(f.gpu.device, .{
        .size = @sizeOf(fk.Buffers),
        .usage = .{ .storage = true, .copy_dst = true },
        .label = "fluid_mirror",
    });
    spawnDamBreak(&pipe, scratch, &hand, mirror_buf_h);

    const n_bytes: u64 = fk.num_particles * 8;
    const discs: z.FluidDiscs = try z.FluidDiscs.init(
        f.gpu,
        gpa,
        f.gpu.device,
        f.gpu.queue,
        f.gpu.backbuffer_format,
        f.gpu.depth_format orelse .undefined_,
        .{ .handle = pipe.fieldBuffer(.pos).?, .size = n_bytes },
        .{ .handle = pipe.fieldBuffer(.density).?, .size = n_bytes },
        fk.domain_w,
        fk.domain_h,
    );
    // Decoupled-render twin buffer was created earlier (before spawn) so the
    // spawn-time density fill can target it.
    const mirror_buf: z.wgpu.BufferHandle = mirror_buf_h;
    // Spawn + kick into the hand-rolled buffers (CPU fills scratch below for
    // kompute; reuse the same data here).
    const discs_mirror: z.FluidDiscs = try z.FluidDiscs.init(
        f.gpu,
        gpa,
        f.gpu.device,
        f.gpu.queue,
        f.gpu.backbuffer_format,
        f.gpu.depth_format orelse .undefined_,
        .{ .handle = mirror_buf, .offset = @offsetOf(fk.Buffers, "pos"), .size = n_bytes },
        .{ .handle = mirror_buf, .offset = @offsetOf(fk.Buffers, "density"), .size = n_bytes },
        fk.domain_w,
        fk.domain_h,
    );

    s.* = .{
        .font = font,
        .pipe = pipe,
        .discs = discs,
        .ui_host = z.UiHost.init(gpa, font),
        .mirror_buf = mirror_buf,
        .discs_mirror = discs_mirror,
        .hand = hand,
        .scratch = scratch,
        .prev_stat_pos = prev_stat_pos,
    };
}

fn update(f: *z.Frame, s: *State) void {
    // ---- Average-FPS benchmark (the baseline figure we're trying to beat) ----
    // dt is the real frame delta; guard the first frame / pauses where it's 0.
    const dt: f32 = f.time.delta_time;
    if (dt > 0.0) {
        const inst_fps: f32 = 1.0 / dt;
        // EMA with ~0.1 weight: smooth but responsive.
        s.fps_ema = if (s.fps_ema == 0) inst_fps else s.fps_ema * 0.9 + inst_fps * 0.1;
        const inst_ms: f32 = dt * 1000.0;
        s.ms_frame = if (s.ms_frame == 0) inst_ms else s.ms_frame * 0.9 + inst_ms * 0.1;
        // Windowed average: accumulate, publish every fps_window_secs.
        s.fps_accum_time += dt;
        s.fps_accum_frames += 1;
        if (inst_fps < s.fps_min_accum) {
            s.fps_min_accum = inst_fps;
        }
        const fps_window_secs: f32 = 0.5;
        if (s.fps_accum_time >= fps_window_secs) {
            s.fps_avg = float(s.fps_accum_frames) / s.fps_accum_time;
            s.fps_min = s.fps_min_accum;
            s.fps_accum_time = 0;
            s.fps_accum_frames = 0;
            s.fps_min_accum = 1e9;
        }
    }

    // ---- Input → mouse force (logical px → sim px via the renderer's fit) ----
    const lw: f32 = f.window.widthf();
    const lh: f32 = f.window.heightf();
    const mraw: Vec2 = z.getMousePosition(f.input);
    const mp_arr: [2]f32 = s.discs.simFromLogical(lw, lh, .{ mraw[0], mraw[1] });
    const mp: Vec2 = .{ mp_arr[0], mp_arr[1] };
    const pressing: bool = z.isMouseButtonDown(f.input, .left);
    const attract: bool = s.attract_toggle or
        z.isKeyDown(f.input, .left_shift) or
        z.isKeyDown(f.input, .right_shift);
    const signed_force: f32 = if (!pressing)
        0.0
    else if (attract)
        -s.mouse_force_mag
    else
        s.mouse_force_mag;

    // ---- Substeps: 8 dispatches each, all on-device ----
    const live_count: u32 = @trunc(clamp(s.sim_count_f, 1, fk.num_particles));
    // Compute this frame's GPU sim params ONCE, before the batch: a batch writes
    // the uniform a single time at beginBatch, so params must be final by then
    // (endBatch asserts no mid-batch change). The simple SWEEP path and the full-
    // physics path are mutually exclusive (s.simple_mode) and differ only in
    // dispatch width + gravity.
    const sim_params: fk.Params = .{
        .count = if (s.simple_mode) live_count else fk.num_particles,
        .dt = 1.0,
        .h = fk.interact_radius,
        .r0 = s.rest_density,
        .k_far = s.k_far,
        .k_near = s.k_near,
        .gravity_y = if (s.simple_mode) 0.12 else s.gravity_y,
        .visc_beta = s.visc_beta,
        .mouse_x = mp[0],
        .mouse_y = mp[1],
        .mouse_force = signed_force,
        .mouse_radius = mouse_radius,
        .dom_w = fk.domain_w,
        .dom_h = fk.domain_h,
        .n_cols = fk.grid_cols,
        .n_rows = fk.grid_rows,
    };
    s.pipe.params = sim_params; // non-batch mode reads this per dispatch
    if (!s.paused and s.batch_mode) {
        s.pipe.beginBatch(sim_params);
    }
    if (!s.paused and s.simple_mode and s.cpu_kernels) {
        // ---- CPU twin: the literal kernel fn, looped, then ONE upload ----
        const cpu_params: fk.Params = .{
            .count = fk.num_particles,
            .dt = 1.0,
            .h = fk.interact_radius,
            .r0 = s.rest_density,
            .k_far = s.k_far,
            .k_near = s.k_near,
            .gravity_y = 0.12,
            .visc_beta = s.visc_beta,
            .mouse_x = mp[0],
            .mouse_y = mp[1],
            .mouse_force = signed_force,
            .mouse_radius = mouse_radius,
            .dom_w = fk.domain_w,
            .dom_h = fk.domain_h,
            .n_cols = fk.grid_cols,
            .n_rows = fk.grid_rows,
        };
        var ss: u32 = 0;
        while (ss < substeps) : (ss += 1) {
            var id: u32 = 0;
            while (id < fk.num_particles) : (id += 1) {
                fk.fallBounceLean(.{ .id = id, .params = cpu_params });
            }
        }
        s.pipe.upload(.pos, fk.g.B.pos[0..fk.num_particles]);
        s.pipe.upload(.density, fk.g.B.density[0..fk.num_particles]);
    }
    if (!s.paused and s.handrolled_mode) {
        // The JS demo's frame, byte for byte: uniform write + dispatch per
        // substep, separate buffers, hand WGSL.
        var hs: u32 = 0;
        while (hs < substeps) : (hs += 1) {
            s.hand.step(live_count, .{
                .count = live_count,
                .dt = 1.0,
                .gravity = 0.12,
                .dom_w = fk.domain_w,
                .dom_h = fk.domain_h,
            });
        }
    }
    var step: u32 = 0;
    while (!s.paused and !s.handrolled_mode and s.simple_mode and !s.cpu_kernels and step < substeps) : (step += 1) {
        // t1178 SWEEP: dispatch width follows the slider; buffer constant.
        s.pipe.run("fallBounceLean", live_count);
    }
    s.frame_no += 1;
    // The benchmark multiplier scales the substep count at runtime so we can
    // push the GPU past the vsync cap and read a real ms/substep number.
    const bench_n: u32 = clamp(s.bench_mult, @as(u32, 1), @as(u32, 5));
    while (!s.paused and !s.simple_mode and step < substeps * bench_n) : (step += 1) {
        // Clavet ordering (t1178): gravity+mouse → viscosity → predict, as THREE
        // dispatches. Viscosity runs on the STALE grid still in the buffer from
        // last frame's build (a damping term tolerates the drift), BEFORE predict
        // and BEFORE the rebuild — so the grid is still built only ONCE per frame
        // (below, on the predicted positions density+force need). Splitting
        // viscosity out of `force` and applying it pre-predict is more stable,
        // which lets dt grow.
        if (s.en_gravity) {
            s.pipe.run("gravityMouse", fk.num_particles);
        }
        if (s.en_viscosity) {
            s.pipe.run("viscosity", fk.num_particles);
        }
        if (s.en_predict) {
            s.pipe.run("predict", fk.num_particles);
        }
        if (s.en_grid) {
            // clearGrid zeroes the per-cell counts (per cell); buildGrid then
            // claims slots per PARTICLE via atomicAdd (O(N), the parallel
            // build that replaced the O(cells×N) single-writer scan).
            s.pipe.run("clearGrid", fk.grid_cells);
            s.pipe.run("buildGrid", fk.num_particles);
        }
        if (s.en_density) {
            if (s.tiled_density) {
                // One workgroup per cell: dispatch grid_cells * wg threads, so
                // each workgroup (wg lanes) owns exactly one cell. (No count to
                // restore now — each run states its own width.)
                s.pipe.run("densityTiled", fk.grid_cells * fk.config.workgroup);
            } else if (s.pos_in_grid) {
                s.pipe.run("densityPig", fk.num_particles);
            } else {
                s.pipe.run("density", fk.num_particles);
            }
        }
        if (s.en_force) {
            if (s.pos_in_grid) {
                s.pipe.run("forcePig", fk.num_particles);
            } else {
                s.pipe.run("force", fk.num_particles);
            }
        }
        if (s.en_apply) {
            s.pipe.run("applyAndFinalize", fk.num_particles);
        }
    }
    if (!s.paused and s.batch_mode) {
        s.pipe.endBatch();
    }

    // ---- Diagnostics readback (centroid/bbox/rho/frozen) — GATED + THROTTLED.
    // readLatest() copies EVERY GPU buffer to staging + submits + maps (a
    // blocking GPU sync), and the CPU scans 20k elements. Doing all THREE
    // readbacks every frame (for stats only visible in the `diagnostics` panel)
    // pinned the GPU and — critically — added ~3 GPU stalls/frame that inflate
    // ms_frame and distort the per-particle-vs-tiled A/B (the stalls hit the two
    // dispatch patterns differently). So only pay for it when the panel is open
    // AND only once every `diag_every` frames; the stat_* fields persist between
    // samples, so the panel still updates (~1x/sec) without taxing every frame.
    // Measure perf with the panel CLOSED for the cleanest number regardless.
    const diag_every: u32 = 30;
    if (s.show_diag and s.frame_no % diag_every == 0) {
        if (s.pipe.readLatest(.pos)) |pos_now| {
            var cx: f64 = 0;
            var cy: f64 = 0;
            var mn: Vec2 = .{ 1e9, 1e9 };
            var mx: Vec2 = .{ -1e9, -1e9 };
            var frozen: u32 = 0;
            for (pos_now, 0..) |p, i| {
                cx += p[0];
                cy += p[1];
                mn = .{ @min(mn[0], p[0]), @min(mn[1], p[1]) };
                mx = .{ @max(mx[0], p[0]), @max(mx[1], p[1]) };
                const dp: Vec2 = p - s.prev_stat_pos[i];
                if (@abs(dp[0]) + @abs(dp[1]) < 0.01) {
                    frozen += 1;
                }
                s.prev_stat_pos[i] = p;
            }
            const fnn: f64 = float64(fk.num_particles);
            s.stat_centroid = .{ @floatCast(cx / fnn), @floatCast(cy / fnn) };
            s.stat_min = mn;
            s.stat_max = mx;
            s.stat_frozen_pct = 100.0 * float(frozen) / float(fk.num_particles);
        }
        if (s.pipe.readLatest(.density)) |d_now| {
            var rs: f64 = 0;
            var rns: f64 = 0;
            for (d_now) |d| {
                rs += d[0];
                rns += d[1];
            }
            s.stat_rho = @floatCast(rs / float64(fk.num_particles));
            s.stat_rho_near = @floatCast(rns / float64(fk.num_particles));
        }
        if (s.pipe.readLatest(.grid_counts)) |gc| {
            var cmax: u32 = 0;
            var nonempty: u32 = 0;
            var capped: u32 = 0;
            var total: u64 = 0;
            for (gc) |cnt| {
                if (cnt > cmax) {
                    cmax = cnt;
                }
                if (cnt > 0) {
                    nonempty += 1;
                    total += cnt;
                }
                if (cnt >= fk.max_per_cell) {
                    capped += 1;
                }
            }
            s.stat_cell_max = cmax;
            s.stat_cells_capped = capped;
            const ne_f: f32 = float(nonempty);
            const tot_f: f32 = float(total);
            s.stat_cell_avg = if (nonempty > 0) tot_f / ne_f else 0;
        }
    }

    // ---- Pre-discs marker kept minimal: the FPS/ms readout now lives in the
    // pinned control panel (always visible), so the old top-left headline was
    // both redundant and occluded by the panel — removed. ----

    // ---- Render: clear + N discs (BACKGROUND) + reference geometry + UI ----
    z.clearViewport(f, .{ .r = 1, .g = 3, .b = 8, .a = 255 });

    // Discs FIRST so the 2D overlays + UI compose ON TOP of the fluid. The
    // DrawPoints pass discipline (flushBatch → disc draw → renderer.bindForPass)
    // restores the 2D pipeline + bind group, so subsequent 2D draws are valid.
    if (s.handrolled_mode) {
        const enc: z.wgpu.CommandEncoderHandle = z.wgpu.createCommandEncoder(f.gpu.device);
        z.wgpu.copyBufferToBuffer(enc, s.hand.pos_buf, 0, s.mirror_buf, 0, fk.num_particles * 8);
        const cmd: z.wgpu.CommandBufferHandle = z.wgpu.finishCommandEncoder(enc);
        z.wgpu.queueSubmit(f.gpu.queue, cmd);
        s.discs_mirror.draw(f.gl, live_count, lw, lh, .{ .radius_px = 8.0, .density_scale = 1.0 / 24.0 });
    } else if (s.decoupled) {
        if (s.pipe.readLatest(.pos)) |pm| {
            z.wgpu.queueWriteBuffer(f.gpu.queue, s.mirror_buf, @offsetOf(fk.Buffers, "pos"), std.mem.sliceAsBytes(pm));
        }
        if (s.pipe.readLatest(.density)) |dm| {
            const off: usize = @offsetOf(fk.Buffers, "density");
            z.wgpu.queueWriteBuffer(f.gpu.queue, s.mirror_buf, off, std.mem.sliceAsBytes(dm));
        }
        s.discs_mirror.draw(f.gl, live_count, lw, lh, .{ .radius_px = 8.0, .density_scale = 1.0 / 24.0 });
    } else {
        s.discs.draw(f.gl, live_count, lw, lh, .{ .radius_px = 8.0, .density_scale = 1.0 / 24.0 });
    }
    // Reopen a fresh 2D pass after the discs' custom pass so the border and UI
    // compose ON TOP (the disc pass leaves pipeline/pass state the 2D
    // batch can't recover from on the Adreno — the source of the old
    // "discs must be drawn last" workaround).
    z.reopenOverlayPass(f.gl);

    const blind: bool = s.frame_no < 300;
    const so: [2][2]f32 = s.discs.fitScaleOffset(lw, lh);
    const sc: f32 = so[0][0];
    const ox: f32 = so[1][0];
    const oy: f32 = so[1][1];
    // Domain border (2D layer, logical coords): where FluidDiscs SHOULD map.
    f.gl.rect(
        .{ .x = ox, .y = oy, .width = fk.domain_w * sc, .height = fk.domain_h * sc },
        .{ .color = .{ .r = 90, .g = 200, .b = 90, .a = 255 }, .outline = 2.0 },
    );
    if (blind) {
        const badge_pos: Vec2 = .{ ox + fk.domain_w * sc - 30.0 * sc, oy + 18.0 * sc };
        f.gl.rect(
            .{ .x = badge_pos[0], .y = badge_pos[1], .width = 22.0 * sc, .height = 22.0 * sc },
            .{ .color = .{ .r = 240, .g = 240, .b = 240, .a = 255 } },
        );
    }

    // ---- Controls ----
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    // Phone strategy: a SMALL always-visible bar (fps + a ☰ toggle) floats at
    // the top-left so the fluid is unobstructed. Tapping ☰ opens the full
    // control panel; tapping ✕ collapses it. Font is sized to the logical
    // width so nothing clips on a narrow canvas. lw/lh = logical CSS px.
    const ui_w: f32 = lw * 0.5;
    // 30% smaller than the previous sizing: cap 34→24, and the divisor tracks
    // the (now half-width) panel so text still fits.
    const fsz: f32 = clamp(ui_w / 16.0, 12.0, 24.0);
    u.style().font_size = fsz;
    u.style().frame_padding = .{ fsz * 0.35, fsz * 0.3 };
    u.style().item_spacing = .{ fsz * 0.4, fsz * 0.4 };
    u.style().window_padding = .{ fsz * 0.5, fsz * 0.5 };
    u.style().title_bar_height = fsz * 1.6;

    // The compact toggle bar — always visible, minimal footprint.
    u.setNextWindowPos(.{ 0, 0 }, .{});
    u.setNextWindowSize(.{ ui_w, fsz * 2.6 }, .{});
    if (u.window("hud", .{ .flags = .{ .no_move = true, .no_resize = true, .no_title_bar = true } })) |w| {
        defer w.close();
        const sub_n: f32 = float(clamp(s.bench_mult, @as(u32, 1), @as(u32, 5)));
        const toggle_label: []const u8 = if (s.panel_open) "X" else "=";
        if (u.button(toggle_label, .{ .size = .{ fsz * 1.8, fsz * 1.8 } })) {
            s.panel_open = !s.panel_open;
        }
        u.sameLine(.{});
        u.text("{d:.0} fps  {d:.1} ms/sub  [{s}]", .{
            s.fps_avg,
            s.ms_frame / sub_n,
            if (s.tiled_density) "TILED" else if (s.pos_in_grid) "pos-in-grid" else "per-particle",
        });
    }

    // The full control panel — only when opened.
    if (s.panel_open) {
        u.setNextWindowPos(.{ 0, fsz * 2.8 }, .{});
        u.setNextWindowSize(.{ ui_w, lh - fsz * 2.8 }, .{});
        if (u.window("fluid", .{ .flags = .{ .no_move = true, .no_resize = true } })) |w| {
            defer w.close();

            // ---- Benchmark stepper (−  N  +), 1..5. Big square buttons: no
            // keyboard, big targets, whole range in ≤4 taps. ----
            u.text("substeps:", .{});
            const bw: f32 = fsz * 2.0;
            if (u.button("-", .{ .size = .{ bw, bw } })) {
                if (s.bench_mult > 1) {
                    s.bench_mult -= 1;
                }
            }
            u.sameLine(.{});
            u.text(" {d} ", .{s.bench_mult});
            u.sameLine(.{});
            if (u.button("+", .{ .size = .{ bw, bw } })) {
                if (s.bench_mult < 5) {
                    s.bench_mult += 1;
                }
            }

            _ = u.checkbox("pause", &s.paused);
            u.sameLine(.{});
            if (u.button("reset", .{ .size = .{ 0, fsz * 2.0 } })) {
                spawnDamBreak(&s.pipe, s.scratch, &s.hand, s.mirror_buf);
            }

            // ---- Core fluid knobs (short labels) ----
            _ = u.slider("count", &s.sim_count_f, .{ .min = 1, .max = 20000, .fmt = "{d:.0}" });
            _ = u.slider("gravity", &s.gravity_y, .{ .min = 0, .max = 0.5 });
            _ = u.slider("viscosity", &s.visc_beta, .{ .min = 0, .max = 0.5 });
            _ = u.slider("rest density", &s.rest_density, .{ .min = 0, .max = 30, .fmt = "{d:.1}" });
            _ = u.checkbox("attract", &s.attract_toggle);

            // ---- Advanced (collapsed) ----
            if (u.collapsingHeader("advanced", &s.show_advanced)) {
                _ = u.slider("k far", &s.k_far, .{ .min = 0, .max = 0.02, .fmt = "{d:.4}" });
                _ = u.slider("k near", &s.k_near, .{ .min = 0, .max = 0.06, .fmt = "{d:.4}" });
                _ = u.checkbox("handrolled", &s.handrolled_mode);
                _ = u.checkbox("decoupled", &s.decoupled);
                _ = u.checkbox("batch", &s.batch_mode);
                _ = u.checkbox("simple", &s.simple_mode);
                _ = u.checkbox("cpu kernels", &s.cpu_kernels);
            }

            // ---- Diagnostics (collapsed; readback only runs while open) ----
            if (u.collapsingHeader("diagnostics", &s.show_diag)) {
                u.text("rho {d:.1}  rho_near {d:.1}  frozen {d:.0}%", .{
                    s.stat_rho, s.stat_rho_near, s.stat_frozen_pct,
                });
                u.text("far {d:.4}  near {d:.4}", .{
                    s.k_far * (s.stat_rho - s.rest_density),
                    s.k_near * s.stat_rho_near,
                });
                u.text("cellmax {d} avg {d:.1} cap {d}", .{ s.stat_cell_max, s.stat_cell_avg, s.stat_cells_capped });
                _ = u.checkbox("gravity", &s.en_gravity);
                _ = u.checkbox("viscosity (pre-predict)", &s.en_viscosity);
                _ = u.checkbox("grid", &s.en_grid);
                _ = u.checkbox("predict", &s.en_predict);
                _ = u.checkbox("density", &s.en_density);
                _ = u.checkbox("  tiled density (A/B)", &s.tiled_density);
                _ = u.checkbox("  pos-in-grid (A/B)", &s.pos_in_grid);
                _ = u.checkbox("force", &s.en_force);
                _ = u.checkbox("apply", &s.en_apply);
            }
        }
    }
    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    // Transient GPU compute demo: pipeline/shader setup handles aren't retained
    // in State, so a leak-tight deinit isn't practical — opt out of the gate.
    .memory = .managed,
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - 20k GPU fluid",
            .width = 900,
            .height = 600,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    // .memory left default (arena): the t1178 diagnostic teardown — the
    // no-deinit `Handrolled` compute path plus the mirror discs/buffer — is a
    // deep, conditional free deferred while that coherency hunt is live. The
    // deinit already frees the primary pipe/discs/ui_host.
    .deinit = deinit,
    .update = update,
};
