//! bridge_slice — ZIG_BRIDGE_PLAN Phase-2 slice (doctrine D9–D11).
//! THE APP OWNS THE PAGE: this wasm module builds the entire document —
//! css, heading, prose, a link, an embedded YouTube iframe, and TWO
//! dynamically created WebGPU canvases on the shared device — through the
//! bridge's generic "dom" verbs, then animates per-canvas clears and
//! reacts to clicks on canvas 1. No HTML or JS was written for this page.

pub const EvRec = extern struct { code: u32, a: f32, b: f32 };

const dom = struct {
    extern "dom" fn create(tag: [*]const u8, len: u32) u32;
    extern "dom" fn attach_body(h: u32) void;
    extern "dom" fn append(parent: u32, child: u32) void;
    extern "dom" fn set_text(h: u32, p: [*]const u8, l: u32) void;
    extern "dom" fn set_attr(
        element: u32,
        key_ptr: [*]const u8,
        key_len: u32,
        value_ptr: [*]const u8,
        value_len: u32,
    ) void;
    extern "dom" fn set_style(h: u32, p: [*]const u8, l: u32) void;
    extern "dom" fn css(p: [*]const u8, l: u32) void;
    extern "dom" fn listen(h: u32, ep: [*]const u8, el: u32, code: u32) void;
    extern "dom" fn poll_event(out: *EvRec) u32;
    extern "dom" fn canvas_configure(h: u32) u32;
    extern "dom" fn canvas_size(h: u32, out: *[2]u32) void;
};
const wgpu = struct {
    extern "wgpu" fn current_view(canvas: u32) u32;
    extern "wgpu" fn clear(view: u32, r: f32, g: f32, b: f32) void;
};

fn el(comptime tag: []const u8) u32 {
    return dom.create(tag.ptr, tag.len);
}
fn text(h: u32, comptime s: []const u8) void {
    dom.set_text(h, s.ptr, s.len);
}
fn style(h: u32, comptime s: []const u8) void {
    dom.set_style(h, s.ptr, s.len);
}
fn attr(
    h: u32,
    comptime k: []const u8,
    comptime v: []const u8,
) void {
    dom.set_attr(h, k.ptr, k.len, v.ptr, v.len);
}

/// Page-lifetime app state. Freestanding wasm has no State plumbing, so this
/// lives at module scope — but as ONE object, the app's only global.
const PageState = struct {
    top_canvas: u32 = 0,
    bottom_canvas: u32 = 0,
    click_hue_shift: f32 = 0, // accumulated tap-to-shift phase
};
// lint:off module-var: THE one page singleton for this app
var page: PageState = .{};

export fn zimr_page_main() void {
    const page_css: []const u8 =
        "body{background:#14100c;color:#ece2cf;font:17px/1.6 system-ui;margin:0;padding:20px;max-width:760px}" ++
        "h1{font-size:30px;margin:8px 0 4px}a{color:#e8b04b}" ++
        "canvas{display:block;border:1px solid #4a4036;border-radius:6px;margin:14px 0}";
    dom.css(page_css.ptr, page_css.len);

    const h1: u32 = el("h1");
    text(h1, "zimr: the app owns the page");
    dom.attach_body(h1);

    const p1: u32 = el("p");
    const intro: []const u8 = "Every element here — including this paragraph, the link, the video, " ++
        "and both live WebGPU canvases below — was created by Zig running as wasm, through fourteen " ++
        "generic bridge verbs. Tap the first canvas to shift its colors.";
    text(p1, intro);
    dom.attach_body(p1);

    const link: u32 = el("a");
    text(link, "ziglang.org");
    attr(link, "href", "https://ziglang.org");
    dom.attach_body(link);

    const yt: u32 = el("iframe");
    attr(yt, "src", "https://www.youtube.com/embed/dQw4w9WgXcQ");
    attr(yt, "allow", "encrypted-media");
    style(yt, "width:100%;aspect-ratio:16/9;border:0;border-radius:6px;margin:14px 0");
    dom.attach_body(yt);

    page.top_canvas = el("canvas");
    style(page.top_canvas, "width:100%;height:140px");
    dom.attach_body(page.top_canvas);
    page.bottom_canvas = el("canvas");
    style(page.bottom_canvas, "width:100%;height:140px");
    dom.attach_body(page.bottom_canvas);

    var wh: [2]u32 = undefined;
    dom.canvas_size(page.top_canvas, &wh);
    dom.canvas_size(page.bottom_canvas, &wh);
    _ = dom.canvas_configure(page.top_canvas);
    _ = dom.canvas_configure(page.bottom_canvas);
    dom.listen(page.top_canvas, "click".ptr, "click".len, 1);
}

fn wave(t: f32, phase: f32) f32 {
    // cheap freestanding sin approximation via Bhaskara on wrapped angle
    var x: f32 = t + phase;
    const tau: f32 = 6.28318;
    x = x - tau * @floor(x / tau);
    const pi: f32 = 3.14159;
    const sign: f32 = if (x > pi) -1.0 else 1.0;
    if (x > pi) {
        x -= pi;
    }
    const s: f32 = (16.0 * x * (pi - x)) / (5.0 * pi * pi - 4.0 * x * (pi - x));
    return 0.5 + 0.5 * sign * s;
}

export fn zimr_frame(t_ms: f64) void {
    var ev: EvRec = undefined;
    while (dom.poll_event(&ev) != 0) {
        if (ev.code == 1) {
            page.click_hue_shift += 0.9;
        }
    }
    const t: f32 = @floatCast(t_ms * 0.001);
    const v1: u32 = wgpu.current_view(page.top_canvas);
    const shifted_t: f32 = t + page.click_hue_shift;
    wgpu.clear(v1, wave(shifted_t, 0.0), wave(shifted_t, 2.1), wave(shifted_t, 4.2));
    const v2: u32 = wgpu.current_view(page.bottom_canvas);
    wgpu.clear(v2, wave(-t, 4.2), wave(-t, 2.1), wave(-t, 0.0));
}
