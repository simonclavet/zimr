//! wgpu_smoke.zig - the wgpu wasm smoke test, ported from webtests/
//! wgpu_smoke.ts (ZIG_BRIDGE_PLAN Phase 5b). Compiled to wasm32, transpiled
//! to JS by our own c2js, and run by webtests/runner.mjs (`node runner.mjs
//! wgpu_smoke.js [args]`). This is the DOGFOOD: the test logic is Zig through
//! our pipeline; runner.mjs is the only hand-written JS, doing nothing but
//! WebAssembly.instantiate + fs.
//!
//! Behavior mirrors the TS exactly so PASS output is byte-identical:
//!   - Single mode: --wasm=<path>  (default zig-out/wgpu/wgpu_bringup.wasm)
//!   - Dir mode:    --web-dir=<dir> [--focus=a,b*] - smoke every *.wasm
//!   - --frames=N (default 10)
//!   For each wasm: build the wgpu/wasi/dom/audio shim namespaces (runner
//!   provides the shim bodies; we provide the NAME LISTS), instantiate,
//!   require exports {memory,_initialize,update}, run _initialize + N
//!   update(1/60) frames, then print:
//!     "ok PASS  <label>  <bytes> bytes, init N calls, ~X.X/frame"
//!     "    by type/frame: name=K  name=K  ..."  (top 10 by count)
//!   Fail (missing export / undeclared import / instantiate) prints "x FAIL".
//!   Exit 0 iff all wasms pass.

// ---- JS interop kernel (the same primitives the real bridge uses) --------
const Handle = u32;
extern fn js_global() Handle;
extern fn js_get(o: Handle, p: [*]const u8, l: u32) Handle;
extern fn js_get_index(o: Handle, i: u32) Handle;
extern fn js_get_num(o: Handle, p: [*]const u8, l: u32) f64;
extern fn js_call0(o: Handle, p: [*]const u8, l: u32) Handle;
extern fn js_call1(o: Handle, p: [*]const u8, l: u32, a: Handle) Handle;
extern fn js_call1v(o: Handle, p: [*]const u8, l: u32, a: Handle) void;
extern fn js_call2(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: Handle,
    b: Handle,
) Handle;
extern fn js_call3(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: Handle,
    b: Handle,
    c: Handle,
) Handle;
extern fn js_str(p: [*]const u8, l: u32) Handle;
extern fn js_num(x: f64) Handle;
extern fn js_to_num(h: Handle) f64;
extern fn js_obj() Handle;
extern fn js_new0(ctor: Handle) Handle;
extern fn js_set(o: Handle, p: [*]const u8, l: u32, v: Handle) void;
extern fn js_string_into(h: Handle, p: [*]u8, max: u32) u32;

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const endsWith = std.mem.endsWith;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;

fn g() Handle {
    return js_global();
}
fn host() Handle {
    return js_get(g(), "__host", 6);
}
fn s(text: []const u8) Handle {
    return js_str(text.ptr, @intCast(text.len));
}
fn arr() Handle {
    return js_new0(js_get(g(), "Array", 5));
}
fn push(a: Handle, v: Handle) void {
    _ = js_call1(a, "push", 4, v);
}
fn print(text: []const u8) void {
    js_call1v(host(), "print", 5, s(text));
}
fn eprint(text: []const u8) void {
    js_call1v(host(), "eprint", 6, s(text));
}

// Read a JS string handle into a Zig buffer; returns the slice.
fn jsStrInto(h: Handle, buf: []u8) []const u8 {
    const n: u32 = js_string_into(h, buf.ptr, @intCast(buf.len));
    return buf[0..n];
}

// ---- the wgpu verb name table (mirrors src/wgpu.zig externs) -------------
// handle-returning verbs:
const wgpu_handle = [_][]const u8{
    "js_init_device",                      "js_device_get_queue",
    "js_get_surface",                      "js_surface_get_format",
    "js_surface_get_current_texture",      "js_device_create_buffer",
    "js_device_create_texture",            "js_texture_create_view",
    "js_device_create_sampler",            "js_device_create_bind_group_layout",
    "js_device_create_bind_group",         "js_device_create_pipeline_layout",
    "js_device_create_shader_module_wgsl", "js_device_create_render_pipeline",
    "js_device_create_compute_pipeline",   "js_device_create_command_encoder",
    "js_command_encoder_finish",           "js_buffer_read_start",
    "js_buffer_read_poll",                 "js_encoder_begin_render_pass",
    "js_encoder_begin_render_pass_mrt",    "js_encoder_begin_compute_pass",
};
// void verbs:
const wgpu_void = [_][]const u8{
    "js_surface_present",                  "js_queue_write_buffer",
    "js_buffer_destroy",                   "js_texture_destroy",
    "js_bind_group_destroy",               "js_bind_group_layout_destroy",
    "js_pipeline_layout_destroy",          "js_render_pipeline_destroy",
    "js_compute_pipeline_destroy",         "js_sampler_destroy",
    "js_shader_module_destroy",            "js_texture_view_destroy",
    "js_queue_write_texture",              "js_encoder_copy_buffer_to_buffer",
    "js_encoder_copy_texture_to_buffer",   "js_buffer_read_into",
    "js_buffer_read_release",              "js_queue_submit",
    "js_render_pass_set_pipeline",         "js_render_pass_set_bind_group",
    "js_render_pass_set_vertex_buffer",    "js_render_pass_set_index_buffer",
    "js_render_pass_draw",                 "js_render_pass_draw_indexed",
    "js_render_pass_set_scissor_rect",     "js_render_pass_end",
    "js_compute_pass_set_pipeline",        "js_compute_pass_set_bind_group",
    "js_compute_pass_dispatch_workgroups", "js_compute_pass_end",
};
// specials handled by runner (packed size / advancing clock):
const wgpu_special = [_][]const u8{
    "js_surface_get_size", "js_surface_get_css_size", "js_now_ms",
};

const dom_names = [_][]const u8{
    "js_log",                                "js_persistence_save",
    "js_persistence_size",                   "js_persistence_read",
    "js_persistence_remove",                 "js_set_cursor_style",
    "js_set_mouse_cursor",                   "js_set_title",
    "js_get_dpi_scale",                      "js_is_fullscreen",
    "js_toggle_fullscreen",                  "js_open_url",
    "js_take_screenshot",                    "js_request_pointer_lock",
    "js_exit_pointer_lock",                  "js_pointer_lock_active",
    "js_set_window_focused",                 "js_set_window_opacity",
    "js_set_window_icon_png",                "js_crypto_random_fill",
    "js_gamepad_vibrate",                    "js_panic",
    "js_set_clipboard_text",                 "js_show_overlay_input",
    "js_hide_overlay_input",                 "js_update_overlay_input_rect",
    "js_overlay_input_is_visible",           "js_get_overlay_input_text",
    "js_set_overlay_input_password",         "js_set_overlay_input_read_only",
    "js_set_overlay_input_escape_clears",    "js_set_overlay_input_allow_tab",
    "js_set_overlay_input_char_filters",     "js_set_input_mode",
    "js_show_overlay_textarea",              "js_hide_overlay_textarea",
    "js_update_overlay_textarea_rect",       "js_overlay_textarea_is_visible",
    "js_get_overlay_textarea_text",          "js_set_overlay_textarea_read_only",
    "js_set_overlay_textarea_escape_clears", "js_set_overlay_textarea_allow_tab",
    "js_set_overlay_textarea_char_filters",  "js_set_overlay_textarea_ctrl_enter_for_newline",
};

const audio_names = [_][]const u8{
    "js_audio_create_context",      "js_audio_close_context",
    "js_audio_resume_context",      "js_audio_get_sample_rate",
    "js_audio_get_current_time",    "js_audio_get_master_volume",
    "js_audio_set_master_volume",   "js_audio_load_buffer",
    "js_audio_unload_buffer",       "js_audio_play_buffer",
    "js_audio_stop_buffer",         "js_audio_pause_buffer",
    "js_audio_resume_buffer",       "js_audio_is_buffer_playing",
    "js_audio_play_buffer_at",      "js_audio_play_buffer_with_offset",
    "js_audio_decode_ogg_bytes",    "js_audio_is_decode_ready",
    "js_audio_take_decoded_buffer", "js_audio_cancel_decode",
};

// Build the importSpec object the runner consumes:
//   { namespaces: {wgpu:[...], wasi_snapshot_preview1:[], dom:[...], audio:[...]},
//     voidNames: [...] }
fn buildImportSpec() Handle {
    const spec: Handle = js_obj();
    const namespaces: Handle = js_obj();

    const wgpu_list: Handle = arr();
    for (wgpu_handle) |name| {
        push(wgpu_list, s(name));
    }
    for (wgpu_void) |name| {
        push(wgpu_list, s(name));
    }
    for (wgpu_special) |name| {
        push(wgpu_list, s(name));
    }
    js_set(namespaces, "wgpu", 4, wgpu_list);

    const dom_list: Handle = arr();
    for (dom_names) |name| {
        push(dom_list, s(name));
    }
    js_set(namespaces, "dom", 3, dom_list);

    const audio_list: Handle = arr();
    for (audio_names) |name| {
        push(audio_list, s(name));
    }
    js_set(namespaces, "audio", 5, audio_list);

    // wasi: the runner's Proxy stubs everything; an empty list is fine since
    // wasi calls are success/EBADF stubs that don't need recording here.
    js_set(namespaces, "wasi_snapshot_preview1", 22, arr());
    js_set(spec, "namespaces", 10, namespaces);

    // voidNames: the wgpu void verbs (dom/audio returns are fixed by runner).
    const void_list: Handle = arr();
    for (wgpu_void) |name| {
        push(void_list, s(name));
    }
    js_set(spec, "voidNames", 9, void_list);
    return spec;
}

// ---- per-call-type classification over the runner's call log -------------
// The log is a JS array of "name(args)" strings. We tally the top entries by
// bare name (split on "(") over the post-init slice, and format the
// "by type/frame:" line. Up to ~64 distinct verb names; fixed arrays avoid
// any allocator (none under the c2js runtime).
const max_types = 96;
const Tally = struct {
    names: [max_types][64]u8 = undefined,
    name_len: [max_types]u32 = @splat(0),
    count: [max_types]u32 = @splat(0),
    n: u32 = 0,

    fn bump(self: *Tally, name: []const u8) void {
        var i: u32 = 0;
        while (i < self.n) : (i += 1) {
            if (self.name_len[i] == name.len and
                eql(u8, self.names[i][0..name.len], name))
            {
                self.count[i] += 1;
                return;
            }
        }
        if (self.n >= max_types) {
            return;
        }
        const slot: u32 = self.n;
        const cap: usize = @min(name.len, 64);
        @memcpy(self.names[slot][0..cap], name[0..cap]);
        self.name_len[slot] = @intCast(cap);
        self.count[slot] = 1;
        self.n += 1;
    }
};

// Extract the bare verb name from a "name(args)" entry.
fn bareName(entry: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, entry, '(')) |paren| {
        return entry[0..paren];
    }
    return entry;
}

const State = struct {
    frames: u32 = 10,
    web_dir_buf: [512]u8 = undefined,
    web_dir_len: u32 = 0,
    wasm_buf: [512]u8 = undefined,
    wasm_len: u32 = 0,
    focus_buf: [512]u8 = undefined,
    focus_len: u32 = 0,
    has_web_dir: bool = false,
    has_focus: bool = false,
    all_ok: bool = true,
};
// lint:off module-var: the one driver-state singleton for this test harness
var st: State = .{};

fn webDir() []const u8 {
    return st.web_dir_buf[0..st.web_dir_len];
}

fn hasExport(exports: Handle, name: []const u8) bool {
    const len: u32 = @trunc(js_get_num(exports, "length", 6));
    var i: u32 = 0;
    var buf: [128]u8 = undefined;
    while (i < len) : (i += 1) {
        const item: Handle = js_get_index(exports, i);
        const got: []const u8 = jsStrInto(item, &buf);
        if (eql(u8, got, name)) {
            return true;
        }
    }
    return false;
}

/// The runner's default cap on a page's call log (`webtests/runner.mjs`, `MAX_LOG`); past it, calls are
/// dropped and anything counted from the log is incomplete.
const runner_log_cap: u32 = 500_000;

fn logLen(id_h: Handle) u32 {
    const log: Handle = js_call1(host(), "sutCallLog", 10, id_h);
    return @trunc(js_get_num(log, "length", 6));
}

fn sutBytes(bytes: Handle) u32 {
    return @trunc(js_get_num(bytes, "length", 6));
}

fn printFail(label: []const u8, reason: []const u8) void {
    // 640, not 256: `printClobberFail` hands us a ~360-byte reason, so a
    // 256-byte line ALWAYS overflowed - and a bufPrint overflow here does not
    // reach the `catch`, it dies in c2js's miscompiled Io.Writer error path
    // ("ReferenceError: t19 is not defined"). Net effect: the clobber gate could
    // detect a clobber but never NAME one; you got a JS stack trace instead of
    // the diagnosis. Size the buffer for the real message.
    var buf: [640]u8 = undefined;
    const line: []const u8 = bufPrint(
        &buf,
        "\u{2717} FAIL  {s}  {s}",
        .{ label, reason },
    ) catch "\u{2717} FAIL";
    eprint(line);
}

fn printPass(label: []const u8, byte_len: u32, init_calls: u32, total_calls: u32) void {
    // per_frame to one decimal, via integer tenths (avoids std.fmt's float
    // path, which trips a c2js BigInt/Number mix in computePow5).
    const denom: u32 = if (st.frames == 0) 1 else st.frames;
    const post: u32 = total_calls - init_calls;
    const tenths: u32 = (post * 10 + denom / 2) / denom; // rounded
    const whole: u32 = tenths / 10;
    const frac: u32 = tenths % 10;
    var buf: [256]u8 = undefined;
    const line: []const u8 = bufPrint(
        &buf,
        "\u{2713} PASS  {s}  {d} bytes, init {d} calls, ~{d}.{d}/frame",
        .{ label, byte_len, init_calls, whole, frac },
    ) catch "\u{2713} PASS";
    print(line);
    printByType(label);
    _ = printLiveHandles("    GPU handles (created-destroyed): ");
}

// Re-read the last SUT's log and print the top-10 by-type/frame line. We
// re-fetch via the most-recent id tracked in last_id.
// lint:off module-var: tracks the SUT whose log we classify
var last_id: Handle = 0;

fn printByType(_: []const u8) void {
    const log: Handle = js_call1(host(), "sutCallLog", 10, last_id);
    const len: u32 = @trunc(js_get_num(log, "length", 6));
    var tally_counts: Tally = .{};
    var buf: [128]u8 = undefined;
    var i: u32 = last_init_calls;
    while (i < len) : (i += 1) {
        const item: Handle = js_get_index(log, i);
        const entry: []const u8 = jsStrInto(item, &buf);
        // Skip host-appended markers (e.g. LABEL_MAP) so only real js_* verbs
        // show in the per-frame type breakdown.
        if (!startsWith(u8, entry, "js_")) {
            continue;
        }
        tally_counts.bump(bareName(entry));
    }
    // Build the line: top 10 by count, "name=K  name=K".
    var out: [1024]u8 = undefined;
    var w: usize = 0;
    const prefix: []const u8 = "    by type/frame: ";
    @memcpy(out[0..prefix.len], prefix);
    w += prefix.len;
    const denom: f64 = if (st.frames == 0) 1.0 else @floatFromInt(st.frames);
    var printed: u32 = 0;
    while (printed < 10) : (printed += 1) {
        // find current max
        var best: i64 = -1;
        var best_idx: u32 = 0;
        var j: u32 = 0;
        while (j < tally_counts.n) : (j += 1) {
            if (@as(i64, tally_counts.count[j]) > best) {
                best = @intCast(tally_counts.count[j]);
                best_idx = j;
            }
        }
        if (best <= 0) {
            break;
        }
        const nm: []const u8 = tally_counts.names[best_idx][0..tally_counts.name_len[best_idx]];
        const cnt_f: f64 = @floatFromInt(tally_counts.count[best_idx]);
        const per: u32 = @trunc(cnt_f / denom);
        const seg: []const u8 = bufPrint(out[w..], "{s}={d}  ", .{ nm, per }) catch break;
        w += seg.len;
        tally_counts.count[best_idx] = 0; // consume
    }
    // Trim the trailing two-space separator to match the TS join exactly.
    if (w >= 2 and out[w - 1] == ' ' and out[w - 2] == ' ') {
        w -= 2;
    }
    print(out[0..w]);
}

// Resource types that have BOTH a create and a destroy - the leak-tracked set.
// (Command/pass encoders are frame-transient and deliberately excluded.)
const ResType = struct {
    name: []const u8,
    create: []const u8,
    destroy: []const u8,
};
const res_types = [_]ResType{
    .{ .name = "texture", .create = "js_device_create_texture", .destroy = "js_texture_destroy" },
    .{ .name = "buffer", .create = "js_device_create_buffer", .destroy = "js_buffer_destroy" },
    .{ .name = "bind_group", .create = "js_device_create_bind_group", .destroy = "js_bind_group_destroy" },
    .{
        .name = "bind_group_layout",
        .create = "js_device_create_bind_group_layout",
        .destroy = "js_bind_group_layout_destroy",
    },
    .{
        .name = "pipeline_layout",
        .create = "js_device_create_pipeline_layout",
        .destroy = "js_pipeline_layout_destroy",
    },
    .{
        .name = "render_pipeline",
        .create = "js_device_create_render_pipeline",
        .destroy = "js_render_pipeline_destroy",
    },
    .{
        .name = "compute_pipeline",
        .create = "js_device_create_compute_pipeline",
        .destroy = "js_compute_pipeline_destroy",
    },
    .{ .name = "sampler", .create = "js_device_create_sampler", .destroy = "js_sampler_destroy" },
    .{
        .name = "shader_module",
        .create = "js_device_create_shader_module_wgsl",
        .destroy = "js_shader_module_destroy",
    },
    .{ .name = "texture_view", .create = "js_texture_create_view", .destroy = "js_texture_view_destroy" },
};

// Net GPU handles (created - destroyed) over the whole run, per resource type.
// With no deinit called this is the example's working set; a per-frame leaker
// shows counts that scale with frame count. Once deinit is wired + called (leak
// mode), a non-zero here after teardown is a leak. Foundation for `leak-test`.
fn printLiveHandles(prefix: []const u8) [res_types.len]i32 {
    const log: Handle = js_call1(host(), "sutCallLog", 10, last_id);
    const len: u32 = @trunc(js_get_num(log, "length", 6));
    var live: [res_types.len]i32 = @splat(0);
    var buf: [128]u8 = undefined;
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const item: Handle = js_get_index(log, i);
        const entry: []const u8 = jsStrInto(item, &buf);
        if (!startsWith(u8, entry, "js_")) {
            continue;
        }
        const nm: []const u8 = bareName(entry);
        var k: usize = 0;
        while (k < res_types.len) : (k += 1) {
            if (eql(u8, nm, res_types[k].create)) {
                live[k] += 1;
                break;
            }
            if (eql(u8, nm, res_types[k].destroy)) {
                live[k] -= 1;
                break;
            }
        }
    }
    var out: [512]u8 = undefined;
    @memcpy(out[0..prefix.len], prefix);
    var w: usize = prefix.len;
    var any: bool = false;
    var k: usize = 0;
    while (k < res_types.len) : (k += 1) {
        if (live[k] != 0) {
            const seg: []const u8 = bufPrint(out[w..], "{s}={d}  ", .{ res_types[k].name, live[k] }) catch break;
            w += seg.len;
            any = true;
        }
    }
    if (!any) {
        const seg: []const u8 = bufPrint(out[w..], "(all balanced)", .{}) catch return live;
        w += seg.len;
    } else if (w >= 2 and out[w - 1] == ' ' and out[w - 2] == ' ') {
        w -= 2;
    }
    print(out[0..w]);
    return live;
}
// lint:off module-var: paired with last_id for the by-type slice start
var last_init_calls: u32 = 0;

// Override smokeOne's call path to record last_id/last_init_calls for the
// by-type pass (kept simple: set them right before printPass).
/// Scan the SUT's log for the runner's "!ASSERT " marker (pushed when the SUT
/// logs a fired assertf). Copies the message (minus the marker) into `out` and
/// returns it, or null if no assert fired. This is what turns a runtime assert
/// into a smoke FAIL - the CI catch for the "forgot ensureFrame / bad phase"
/// class that otherwise only shows up as a black screen on a device.
fn assertMsg(id_h: Handle, out: []u8) ?[]const u8 {
    const log: Handle = js_call1(host(), "sutCallLog", 10, id_h);
    const len: u32 = @trunc(js_get_num(log, "length", 6));
    var buf: [256]u8 = undefined;
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const item: Handle = js_get_index(log, i);
        const entry: []const u8 = jsStrInto(item, &buf);
        if (startsWith(u8, entry, "!ASSERT ")) {
            const msg: []const u8 = entry["!ASSERT ".len..];
            const n: usize = @min(msg.len, out.len);
            @memcpy(out[0..n], msg[0..n]);
            return out[0..n];
        }
    }
    return null;
}

fn smoke(path: []const u8, label: []const u8) bool {
    const bytes: Handle = js_call1(host(), "readFile", 8, s(path));
    const spec: Handle = buildImportSpec();
    const id_h: Handle = js_call2(host(), "instantiateSut", 14, bytes, spec);
    const id: f64 = js_to_num(id_h);
    if (id < 0) {
        printFail(label, "instantiation failed");
        return false;
    }
    const exports: Handle = js_call1(host(), "sutExports", 10, id_h);
    const required = [_][]const u8{ "memory", "_initialize", "update" };
    for (required) |name| {
        if (!hasExport(exports, name)) {
            printFail(label, "missing export");
            return false;
        }
    }
    _ = js_call2(host(), "sutCall", 7, id_h, s("_initialize"));
    const init_calls: u32 = logLen(id_h);
    var f: u32 = 0;
    var clobber: ClobberScan = .{};
    var frame_start: u32 = init_calls;
    // Live CPU bytes at the halfway frame and the last: memory that grows every frame and is freed only at
    // deinit passes the lifecycle check below, yet kills a page that runs for minutes (the counting
    // allocator's exact total - no fragmentation noise). Growth per frame is reported, not failed on.
    const counts_live: bool = hasExport(exports, "runnerLiveBytes");
    var live_mid: f64 = 0;
    while (f < st.frames) : (f += 1) {
        _ = js_call3(host(), "sutCall", 7, id_h, s("update"), js_num(1.0 / 60.0));
        const frame_end: u32 = logLen(id_h);
        clobber.scanFrame(id_h, frame_start, frame_end, f);
        frame_start = frame_end;
        if (counts_live and f + 1 == st.frames / 2) {
            live_mid = js_to_num(js_call2(host(), "sutCall", 7, id_h, s("runnerLiveBytes")));
        }
    }
    if (counts_live and st.frames >= 4) {
        const live_end: f64 = js_to_num(js_call2(host(), "sutCall", 7, id_h, s("runnerLiveBytes")));
        const half: f64 = @floatFromInt(st.frames - st.frames / 2);
        var lbuf: [200]u8 = undefined;
        const line: []const u8 = bufPrint(
            &lbuf,
            "    live CPU bytes: {d:.0} at frame {d}, {d:.0} at frame {d} - {d:.1} bytes a frame",
            .{ live_mid, st.frames / 2, live_end, st.frames, (live_end - live_mid) / half },
        ) catch "    live CPU bytes: (unprintable)";
        print(line);
    }
    const total_calls: u32 = logLen(id_h);
    last_id = id_h;
    last_init_calls = init_calls;
    if (clobber.violations > 0) {
        printClobberFail(label, &clobber);
        return false;
    }
    var abuf: [220]u8 = undefined;
    if (assertMsg(id_h, &abuf)) |msg| {
        printFail(label, msg);
        return false;
    }
    printPass(label, sutBytes(bytes), init_calls, total_calls);
    // Leak probe: run the example's deinit, then re-measure the handle balance.
    // The delta vs the line above is what deinit freed (ideal: back to the engine
    // baseline). A stub deinit frees nothing, so the two lines match.
    if (hasExport(exports, "runnerDeinit")) {
        _ = js_call2(host(), "sutCall", 7, id_h, s("runnerDeinit"));
        const c1: [res_types.len]i32 = printLiveHandles("    GPU handles after deinit:  ");
        const b1: f64 = if (hasExport(exports, "runnerLiveBytes"))
            js_to_num(js_call2(host(), "sutCall", 7, id_h, s("runnerLiveBytes")))
        else
            0;
        if (hasExport(exports, "runnerReinit")) {
            // TWICE-LIFECYCLE: re-init -> re-tick -> re-deinit. The engine
            // persists (its lazy init is guarded), so a census that GROWS over
            // the first teardown is a per-lifecycle leak - isolated from the
            // fixed engine baseline, which the single-deinit line can't separate.
            _ = js_call2(host(), "sutCall", 7, id_h, s("runnerReinit"));
            var rf: u32 = 0;
            while (rf < st.frames) : (rf += 1) {
                _ = js_call3(host(), "sutCall", 7, id_h, s("update"), js_num(1.0 / 60.0));
            }
            _ = js_call2(host(), "sutCall", 7, id_h, s("runnerDeinit"));
            const c2: [res_types.len]i32 = printLiveHandles("    GPU handles after 2nd deinit: ");
            const b2: f64 = if (hasExport(exports, "runnerLiveBytes"))
                js_to_num(js_call2(host(), "sutCall", 7, id_h, s("runnerLiveBytes")))
            else
                0;
            // ENFORCE for `.managed` examples: the census must be FLAT across the
            // two lifecycles; any positive growth (c2 > c1) is a per-lifecycle leak.
            const managed: bool = hasExport(exports, "runnerMemoryMode") and
                js_to_num(js_call2(host(), "sutCall", 7, id_h, s("runnerMemoryMode"))) > 0.5;
            // The handle balances are COUNTED FROM THE CALL LOG, and the runner caps it (500,000 entries by
            // default; `--max-log=N`) and drops every call past that. A long run fills it, the second
            // teardown's destroy calls are never recorded, and every live handle looks leaked - the "leaks"
            // three long-run pages showed (Sep 25), each identical to its RUNNING state. A full log cannot
            // judge a lifecycle: say so, and do not fail.
            const capped: bool = logLen(id_h) >= runner_log_cap;
            if (managed and capped) {
                var cb: [200]u8 = undefined;
                print(bufPrint(
                    &cb,
                    "    lifecycle leak check SKIPPED: the call log reached its cap ({d} entries) - pass " ++
                        "--max-log=N, or fewer frames, to judge it",
                    .{runner_log_cap},
                ) catch "    lifecycle leak check skipped: call log capped");
            }
            if (managed and !capped) {
                var lb: [256]u8 = undefined;
                var lw: usize = 0;
                var k: usize = 0;
                while (k < res_types.len) : (k += 1) {
                    if (c2[k] > c1[k]) {
                        const delta: i32 = c2[k] - c1[k];
                        const seg: []const u8 = bufPrint(
                            lb[lw..],
                            "{s}+{d} ",
                            .{ res_types[k].name, delta },
                        ) catch break;
                        lw += seg.len;
                    }
                }
                if (lw > 0) {
                    var fb: [320]u8 = undefined;
                    const msg: []const u8 = bufPrint(
                        &fb,
                        "LEAK (managed, per lifecycle): {s}",
                        .{lb[0..lw]},
                    ) catch "managed leak";
                    printFail(label, msg);
                    return false;
                }
                // PRECISE per-deinit completeness check. Between lifecycle 1's
                // deinit and lifecycle 2's reinit nothing runs, so b1 is exactly the
                // live-bytes baseline lifecycle 2 starts from. If lifecycle 2's deinit
                // freed everything its init allocated, live bytes return to b1; any
                // growth b2 > b1 is precisely an allocation the example's deinit
                // forgot to free (the CPU twin of a leaked GPU handle). This is the
                // CountingAllocator's exact net-live accounting - zero fragmentation
                // noise, so the comparison is strict.
                if (b2 > b1) {
                    printFail(label, "CPU LEAK (managed): deinit did not free every allocation (net live bytes grew)");
                    return false;
                }
            }
        }
    }

    // -- FULL ENGINE TEARDOWN: the memory-accounting proof ------------------
    // The lifecycle probe above proves each EXAMPLE frees what it allocated.
    // This tears down the baseline that persists across lifecycles (3D + 2D
    // renderers, pipeline/bind-group caches, the depth target) and requires the
    // census to be ALL ZERO afterward. The clean-zero state is the proof that
    // every GPU handle zimr allocates is accounted for.
    //
    // ENFORCED only for `.managed` examples: their deinit is complete, so the
    // ONLY thing left after shutdown is the engine baseline - now fully freed.
    // An `.arena` example legitimately leaks its OWN handles (stub deinit), so
    // its shutdown residual is not an engine defect and is printed, not gated.
    if (hasExport(exports, "runnerShutdown")) {
        _ = js_call2(host(), "sutCall", 7, id_h, s("runnerShutdown"));
        const cz: [res_types.len]i32 = printLiveHandles("    GPU handles after shutdown: ");
        var residual: bool = false;
        var zk: usize = 0;
        while (zk < res_types.len) : (zk += 1) {
            if (cz[zk] != 0) {
                residual = true;
            }
        }
        const managed_final: bool = hasExport(exports, "runnerMemoryMode") and
            js_to_num(js_call2(host(), "sutCall", 7, id_h, s("runnerMemoryMode"))) > 0.5;
        // Counted from the call log too: once it is capped, the shutdown's destroy calls may be missing.
        if (residual and managed_final and logLen(id_h) >= runner_log_cap) {
            print("    shutdown cleanliness check SKIPPED: the call log reached its cap");
        } else if (residual and managed_final) {
            printFail(label, "ENGINE NOT CLEAN after runnerShutdown (residual handles listed above)");
            return false;
        }
    }
    return true;
}

// ---- queue-timeline clobber detector --------------------------------------
// WebGPU executes every queue.writeBuffer BEFORE the frame's encoder submit,
// so the SAME (buffer, offset) written twice within one frame means only the
// LAST value reaches ANY pass segment - including segments recorded before
// the second write. That silently corrupts per-segment uniforms (the zimr517
// "duplicated grid" ortho bug). Structural fixes ring-buffer such writes
// (renderer_2d's ortho ring, flushBatch's vertex ring); this scan makes the
// whole bug CLASS a smoke FAILURE instead of a device-only visual glitch.
const max_frame_writes = 512;
const ClobberScan = struct {
    // (buffer, offset) pairs seen in the current frame.
    bufs: [max_frame_writes]u32 = @splat(0),
    offs: [max_frame_writes]u64 = @splat(0),
    n: u32 = 0,
    violations: u32 = 0,
    // First violation's details, for the failure message.
    first_buf: u32 = 0,
    first_off: u64 = 0,
    first_frame: u32 = 0,

    fn scanFrame(
        self: *ClobberScan,
        id_h: Handle,
        start: u32,
        end: u32,
        frame: u32,
    ) void {
        self.n = 0;
        const log: Handle = js_call1(host(), "sutCallLog", 10, id_h);
        var i: u32 = start;
        var buf: [512]u8 = undefined;
        while (i < end) : (i += 1) {
            const entry: []const u8 = jsStrInto(js_get_index(log, i), &buf);
            // A SUBMISSION consumes every write before it: WebGPU orders `writeBuffer` and `submit` on one
            // queue timeline, so "write, submit, write" to the same bytes is correct - each write reaches
            // the work submitted after it (the PPO trainer's minibatches do exactly this). Only a repeat
            // with NO submission between is dead: no GPU work could ever have seen the first write.
            if (startsWith(u8, entry, "js_queue_submit(")) {
                self.n = 0;
                continue;
            }
            const prefix: []const u8 = "js_queue_write_buffer(";
            if (!startsWith(u8, entry, prefix)) {
                continue;
            }
            // "js_queue_write_buffer(queue, buffer, offset, ptr, len)"
            const args: []const u8 = entry[prefix.len..];
            const buffer: u32 = @intCast(nthArg(args, 1));
            const offset: u64 = nthArg(args, 2);
            var k: u32 = 0;
            var dup: bool = false;
            while (k < self.n) : (k += 1) {
                if (self.bufs[k] == buffer and self.offs[k] == offset) {
                    dup = true;
                    break;
                }
            }
            if (dup) {
                if (self.violations == 0) {
                    self.first_buf = buffer;
                    self.first_off = offset;
                    self.first_frame = frame;
                }
                self.violations += 1;
            } else if (self.n < max_frame_writes) {
                self.bufs[self.n] = buffer;
                self.offs[self.n] = offset;
                self.n += 1;
            }
        }
    }
};

/// Parse the Nth (0-based) comma-separated numeric arg of "a, b, c, ...".
fn nthArg(args: []const u8, n: u32) u64 {
    var idx: u32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= args.len) : (i += 1) {
        const at_end: bool = i == args.len;
        const at_sep: bool = !at_end and args[i] == ',';
        const at_close: bool = !at_end and args[i] == ')';
        if (at_sep or at_close or at_end) {
            if (idx == n) {
                var seg: []const u8 = args[start..i];
                while (seg.len > 0 and seg[0] == ' ') {
                    seg = seg[1..];
                }
                return std.fmt.parseInt(u64, seg, 10) catch 0;
            }
            idx += 1;
            start = i + 1;
            if (at_close) {
                break;
            }
        }
    }
    return 0;
}

fn printClobberFail(label: []const u8, c: *const ClobberScan) void {
    // The format string alone is ~300 bytes before a single arg is filled in.
    var buf: [512]u8 = undefined;
    var lbuf: [128]u8 = undefined;
    // Name the offending buffer from its creation label (empty if it was
    // created without one - which is itself the signal: add a `.label` at that
    // createBuffer site so the next clobber names itself).
    const owner: []const u8 = lookupLabel(last_id, c.first_buf, &lbuf);
    const msg: []const u8 = bufPrint(
        &buf,
        "queue-timeline clobber: buffer {d} (label='{s}') offset {d} written 2+ times in " ++
            "frame {d} ({d} total violations) — only the LAST write reaches the whole frame. " ++
            "Fix: ring-buffer the writes (renderer_2d ortho ring / draw3d pbr3d ubo ring) OR " ++
            "drop a dead init seed (a lazy-init'd subsystem seeding a UBO it also writes in " ++
            "frame 0 clobbers itself).",
        .{ c.first_buf, owner, c.first_off, c.first_frame, c.violations },
    ) catch "queue-timeline clobber";
    printFail(label, msg);
}

/// Scan the call log for the host-appended marker "LABEL_MAP(handle, name)"
/// and return the name for `want_handle` (empty if none). The host appends one
/// such entry per labeled create.
fn lookupLabel(id_h: Handle, want_handle: u32, out: []u8) []const u8 {
    const log: Handle = js_call1(host(), "sutCallLog", 10, id_h);
    const total: u32 = logLen(id_h);
    var i: u32 = 0;
    var buf: [512]u8 = undefined;
    const prefix: []const u8 = "LABEL_MAP(";
    while (i < total) : (i += 1) {
        const entry: []const u8 = jsStrInto(js_get_index(log, i), &buf);
        if (!startsWith(u8, entry, prefix)) {
            continue;
        }
        const args: []const u8 = entry[prefix.len..];
        const h: u32 = @intCast(nthArg(args, 0));
        if (h != want_handle) {
            continue;
        }
        // The name is the 2nd arg up to the closing ')'.
        var start: usize = 0;
        var commas: u32 = 0;
        var j: usize = 0;
        while (j < args.len) : (j += 1) {
            if (args[j] == ',') {
                commas += 1;
                if (commas == 1) {
                    start = j + 1;
                }
            } else if (args[j] == ')') {
                break;
            }
        }
        var name: []const u8 = args[start..];
        // trim leading space + trailing ')'
        while (name.len > 0 and name[0] == ' ') {
            name = name[1..];
        }
        while (name.len > 0 and (name[name.len - 1] == ')' or name[name.len - 1] == ' ')) {
            name = name[0 .. name.len - 1];
        }
        const n: usize = @min(name.len, out.len);
        @memcpy(out[0..n], name[0..n]);
        return out[0..n];
    }
    return out[0..0];
}

// ---- argv parsing --------------------------------------------------------
fn parseArgs() void {
    const argv: Handle = js_call0(host(), "argv", 4);
    const argc: u32 = @trunc(js_get_num(argv, "length", 6));
    var i: u32 = 0;
    var buf: [512]u8 = undefined;
    while (i < argc) : (i += 1) {
        const a: []const u8 = jsStrInto(js_get_index(argv, i), &buf);
        if (startsWith(u8, a, "--wasm=")) {
            const v: []const u8 = a["--wasm=".len..];
            @memcpy(st.wasm_buf[0..v.len], v);
            st.wasm_len = @intCast(v.len);
        } else if (startsWith(u8, a, "--web-dir=")) {
            const v: []const u8 = a["--web-dir=".len..];
            @memcpy(st.web_dir_buf[0..v.len], v);
            st.web_dir_len = @intCast(v.len);
            st.has_web_dir = true;
        } else if (startsWith(u8, a, "--focus=")) {
            const v: []const u8 = a["--focus=".len..];
            @memcpy(st.focus_buf[0..v.len], v);
            st.focus_len = @intCast(v.len);
            st.has_focus = true;
        } else if (startsWith(u8, a, "--frames=")) {
            const v: []const u8 = a["--frames=".len..];
            st.frames = std.fmt.parseInt(u32, v, 10) catch 10;
        }
    }
}

// Does `name` match any of the comma-separated focus patterns (suffix '*' =
// prefix match)?
fn focusMatch(name: []const u8) bool {
    if (!st.has_focus) {
        return true;
    }
    const patterns: []const u8 = st.focus_buf[0..st.focus_len];
    var it = std.mem.splitScalar(u8, patterns, ',');
    while (it.next()) |pat_raw| {
        const pat: []const u8 = std.mem.trim(u8, pat_raw, " ");
        if (pat.len == 0) {
            continue;
        }
        if (pat[pat.len - 1] == '*') {
            if (startsWith(u8, name, pat[0 .. pat.len - 1])) {
                return true;
            }
        } else if (eql(u8, name, pat)) {
            return true;
        }
    }
    return false;
}

export fn _start() void {
    parseArgs();

    if (st.has_web_dir) {
        const listing_h: Handle = js_call1(host(), "listWasms", 9, s(webDir()));
        var lbuf: [16384]u8 = undefined;
        const listing: []const u8 = jsStrInto(listing_h, &lbuf);
        if (listing.len == 0) {
            eprint("no .wasm files in --web-dir");
            js_call1v(host(), "exit", 4, js_num(1));
            return;
        }
        var path_buf: [600]u8 = undefined;
        var label_buf: [256]u8 = undefined;
        var count: u32 = 0;
        var it = std.mem.splitScalar(u8, listing, '\n');
        while (it.next()) |fname| {
            if (fname.len == 0) {
                continue;
            }
            // label = fname without ".wasm"
            const label: []const u8 = if (endsWith(u8, fname, ".wasm"))
                fname[0 .. fname.len - 5]
            else
                fname;
            if (!focusMatch(label)) {
                continue;
            }
            const lcap: usize = @min(label.len, label_buf.len);
            @memcpy(label_buf[0..lcap], label[0..lcap]);
            const full: []const u8 = bufPrint(&path_buf, "{s}/{s}", .{ webDir(), fname }) catch continue;
            if (!smoke(full, label_buf[0..lcap])) {
                st.all_ok = false;
            }
            count += 1;
        }
        if (st.all_ok) {
            var b: [64]u8 = undefined;
            const line: []const u8 = bufPrint(
                &b,
                "\n\u{2713} wgpu_smoke PASSED ({d} wasms)",
                .{count},
            ) catch "\nPASSED";
            print(line);
        } else {
            print("\n\u{2717} wgpu_smoke FAILED");
        }
        js_call1v(host(), "exit", 4, js_num(if (st.all_ok) 0 else 1));
        return;
    }

    // Single-wasm mode.
    const path: []const u8 = if (st.wasm_len > 0)
        st.wasm_buf[0..st.wasm_len]
    else
        "zig-out/wgpu/wgpu_bringup.wasm";
    var label_buf: [256]u8 = undefined;
    // label = basename without ".wasm"
    var base: []const u8 = path;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        base = path[slash + 1 ..];
    }
    if (endsWith(u8, base, ".wasm")) {
        base = base[0 .. base.len - 5];
    }
    const lcap: usize = @min(base.len, label_buf.len);
    @memcpy(label_buf[0..lcap], base[0..lcap]);
    const ok: bool = smoke(path, label_buf[0..lcap]);
    if (ok) {
        print("\n\u{2713} wgpu_smoke PASSED");
    } else {
        print("\n\u{2717} wgpu_smoke FAILED");
    }
    js_call1v(host(), "exit", 4, js_num(if (ok) 0 else 1));
}
