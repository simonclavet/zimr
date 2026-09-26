//! bridge_classic_probe - ZIG_BRIDGE Phase 3a validator. A wasm32-wasi
//! REACTOR speaking the CLASSIC zimr contract (`_initialize` + `update(dt)`)
//! against the new Zig bridge: device/queue/surface singletons, buffer
//! create + queue write, WGSL shader module, sampler, and a per-frame
//! encoder/finish/submit round. The jsdom gate asserts each verb landed by
//! counting mock-device calls.
const dom = struct {
    extern "dom" fn create(tag: [*]const u8, len: u32) u32;
    extern "dom" fn attach_body(h: u32) void;
    extern "dom" fn set_text(h: u32, p: [*]const u8, l: u32) void;
    extern "dom" fn set_style(h: u32, p: [*]const u8, l: u32) void;
};

const wgpu = struct {
    extern "wgpu" fn js_init_device() u32;
    extern "wgpu" fn js_device_get_queue(device: u32) u32;
    extern "wgpu" fn js_get_surface() u32;
    extern "wgpu" fn js_surface_get_current_texture(surface: u32) u32;
    extern "wgpu" fn js_surface_get_size(surface: u32) u32;
    extern "wgpu" fn js_now_ms() f64;
    extern "wgpu" fn js_device_create_buffer(
        device: u32,
        size: u64,
        usage: u32,
        label_ptr: [*]const u8,
        label_len: usize,
    ) u32;
    extern "wgpu" fn js_queue_write_buffer(
        queue: u32,
        buffer: u32,
        offset: u64,
        data_ptr: [*]const u8,
        data_len: usize,
    ) u32;
    extern "wgpu" fn js_device_create_shader_module_wgsl(
        device: u32,
        wgsl_ptr: [*]const u8,
        wgsl_len: usize,
        label_ptr: [*]const u8,
        label_len: usize,
    ) u32;
    extern "wgpu" fn js_device_create_sampler(
        device: u32,
        mag_filter_linear: u32,
        min_filter_linear: u32,
        address_mode: u32,
    ) u32;
    extern "wgpu" fn js_device_create_command_encoder(device: u32) u32;
    extern "wgpu" fn js_command_encoder_finish(encoder: u32) u32;
    extern "wgpu" fn js_queue_submit(queue: u32, cmd_buffer: u32) void;
    extern "wgpu" fn js_encoder_begin_render_pass(
        encoder: u32,
        color_view: u32,
        clear_r: f32,
        clear_g: f32,
        clear_b: f32,
        clear_a: f32,
        load_op: u32,
        store_op: u32,
        depth_view: u32,
    ) u32;
    extern "wgpu" fn js_render_pass_end(pass: u32) void;
    extern "wgpu" fn js_surface_get_format(surface: u32) u32;
    extern "wgpu" fn js_device_create_pipeline_layout(
        device: u32,
        bgls_ptr: [*]const u32,
        bgls_len: usize,
        label_ptr: [*]const u8,
        label_len: usize,
    ) u32;
    extern "wgpu" fn js_device_create_render_pipeline(
        device: u32,
        layout: u32,
        vs_module: u32,
        fs_module: u32,
        descriptor_ptr: [*]const u8,
        descriptor_len: usize,
        label_ptr: [*]const u8,
        label_len: usize,
    ) u32;
    extern "wgpu" fn js_render_pass_set_pipeline(pass: u32, pipeline: u32) void;
    extern "wgpu" fn js_render_pass_set_vertex_buffer(
        pass: u32,
        slot: u32,
        buffer: u32,
        offset: u64,
        size: u64,
    ) void;
    extern "wgpu" fn js_render_pass_draw(
        pass: u32,
        vertex_count: u32,
        instance_count: u32,
        first_vertex: u32,
        first_instance: u32,
    ) void;
};

const ProbeState = struct {
    device: u32 = 0,
    queue: u32 = 0,
    surface: u32 = 0,
    vertex_buffer: u32 = 0,
    pipeline: u32 = 0,
    frames: u32 = 0,
    elapsed: f64 = 0,
    banner_shown: bool = false,
};

/// Little-endian writer for the render-pipeline descriptor blob - the same
/// packed format pipeline_cache.zig emits and the bridge's Cursor decodes.
const BlobWriter = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,

    fn u32At(self: *BlobWriter, v: u32) void {
        self.buf[self.len + 0] = @truncate(v);
        self.buf[self.len + 1] = @truncate(v >> 8);
        self.buf[self.len + 2] = @truncate(v >> 16);
        self.buf[self.len + 3] = @truncate(v >> 24);
        self.len += 4;
    }
    fn strAt(self: *BlobWriter, text: []const u8) void {
        self.u32At(@intCast(text.len));
        for (text) |ch| {
            self.buf[self.len] = ch;
            self.len += 1;
        }
    }
};
// lint:off module-var: THE one page singleton for this probe
var probe: ProbeState = .{};

export fn _initialize() void {
    probe.device = wgpu.js_init_device();
    probe.queue = wgpu.js_device_get_queue(probe.device);
    probe.surface = wgpu.js_get_surface();

    const usage_vertex_copy_dst: u32 = (1 << 5) | (1 << 3);
    const label: []const u8 = "probe-vertices";
    probe.vertex_buffer = wgpu.js_device_create_buffer(
        probe.device,
        64,
        usage_vertex_copy_dst,
        label.ptr,
        label.len,
    );

    const vertices = [6]f32{ 0.0, 0.62, -0.55, -0.45, 0.55, -0.45 };
    _ = wgpu.js_queue_write_buffer(
        probe.queue,
        probe.vertex_buffer,
        0,
        @ptrCast(&vertices),
        @sizeOf(@TypeOf(vertices)),
    );

    // One WGSL module carrying BOTH entry points - the historical
    // Renderer2D shape, so vs_module == fs_module is exercised too.
    const wgsl: []const u8 =
        "@vertex fn vs(@location(0) p: vec2f) -> @builtin(position) vec4f {" ++
        "  return vec4f(p, 0.0, 1.0);" ++
        "}" ++
        "@fragment fn fs() -> @location(0) vec4f {" ++
        "  return vec4f(0.98, 0.83, 0.29, 1.0);" ++ // zimr gold
        "}";
    const shader_label: []const u8 = "probe-shader";
    const shader: u32 = wgpu.js_device_create_shader_module_wgsl(
        probe.device,
        wgsl.ptr,
        wgsl.len,
        shader_label.ptr,
        shader_label.len,
    );
    _ = wgpu.js_device_create_sampler(probe.device, 1, 1, 0);

    // Empty pipeline layout (no bind groups - positions only).
    const no_bgls = [0]u32{};
    const layout_label: []const u8 = "probe-layout";
    const layout: u32 = wgpu.js_device_create_pipeline_layout(
        probe.device,
        &no_bgls,
        0,
        layout_label.ptr,
        layout_label.len,
    );

    // The descriptor blob, byte-for-byte the format the bridge decodes:
    // one vertex buffer (stride 8, per-vertex, one float32x2 attr at
    // location 0), entries "vs"/"fs", triangle-list, no cull/blend/depth,
    // the SURFACE's color format, sample count 1.
    var blob: BlobWriter = .{};
    blob.u32At(1); // vbl_count
    blob.u32At(8); // stride
    blob.u32At(0); // step_mode: vertex
    blob.u32At(1); // attr_count
    blob.u32At(1); // format: float32x2
    blob.u32At(0); // offset
    blob.u32At(0); // shader_location
    blob.strAt("vs");
    blob.strAt("fs");
    blob.u32At(3); // topology: triangle-list
    blob.u32At(0); // cull: none
    blob.u32At(0); // blend: none
    blob.u32At(0); // depth: off
    blob.u32At(wgpu.js_surface_get_format(probe.surface));
    blob.u32At(0); // depth format: none
    blob.u32At(1); // sample count
    const pipe_label: []const u8 = "probe-pipeline";
    probe.pipeline = wgpu.js_device_create_render_pipeline(
        probe.device,
        layout,
        shader,
        shader,
        &blob.buf,
        blob.len,
        pipe_label.ptr,
        pipe_label.len,
    );
}

fn wave(t: f32, phase: f32) f32 {
    // Bhaskara sine approximation on a wrapped angle - freestanding-friendly.
    var x: f32 = t + phase;
    const tau: f32 = 6.28318;
    x = x - tau * @floor(x / tau);
    const pi: f32 = 3.14159;
    const sign: f32 = if (x > pi) -1.0 else 1.0;
    if (x > pi) {
        x -= pi;
    }
    const sine: f32 = (16.0 * x * (pi - x)) / (5.0 * pi * pi - 4.0 * x * (pi - x));
    return 0.5 + 0.5 * sign * sine;
}

export fn update(dt: f64) void {
    probe.elapsed += dt;
    const t: f32 = @floatCast(probe.elapsed);

    // The visible heartbeat: clear the whole surface to a slowly cycling
    // color every frame - unmistakable proof the pass/submit path is live.
    const view: u32 = wgpu.js_surface_get_current_texture(probe.surface);
    const encoder: u32 = wgpu.js_device_create_command_encoder(probe.device);
    const pass: u32 = wgpu.js_encoder_begin_render_pass(
        encoder,
        view,
        wave(t, 0.0),
        wave(t, 2.1),
        wave(t, 4.2),
        1.0,
        1, // loadOp clear
        0, // storeOp store
        0, // no depth
    );
    wgpu.js_render_pass_set_pipeline(pass, probe.pipeline);
    wgpu.js_render_pass_set_vertex_buffer(pass, 0, probe.vertex_buffer, 0, 0);
    wgpu.js_render_pass_draw(pass, 3, 1, 0, 0);
    wgpu.js_render_pass_end(pass);
    const cmd: u32 = wgpu.js_command_encoder_finish(encoder);
    wgpu.js_queue_submit(probe.queue, cmd);

    probe.frames += 1;
    if (probe.frames == 3 and !probe.banner_shown) {
        probe.banner_shown = true;
        const banner: u32 = dom.create("div".ptr, 3);
        const css: []const u8 = "position:fixed;top:12px;left:12px;right:12px;padding:12px 16px;" ++
            "background:#0a3d1f;color:#b8f5cd;font:15px/1.4 monospace;border-radius:8px;z-index:9";
        dom.set_style(banner, css.ptr, css.len);
        const msg: []const u8 = "PHASE 3 PROBE OK - classic zimr contract on the Zig bridge: " ++
            "device/queue/surface, buffer create+write, WGSL module, sampler, " ++
            "binary-blob render pipeline, and a drawn triangle on a breathing clear.";
        dom.set_text(banner, msg.ptr, msg.len);
        dom.attach_body(banner);
    }
}
