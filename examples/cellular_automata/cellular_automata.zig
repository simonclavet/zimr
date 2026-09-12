//! cellular_automata — Wolfram's 1-D elementary cellular automata (Rule 30, 90, 110, …). Each row is
//! computed from the three cells above it: the 3-bit neighbourhood (0..7) indexes the 8-bit rule to
//! decide the new cell. The grid is a CPU pixel buffer streamed to the GPU every frame via a
//! CpuFramebuffer (update -> present), so it exercises the dynamic-texture-upload path. Tap a preset
//! chip to pick a rule, or tap the canvas to cycle; it auto-advances when a pattern finishes.
//! From raylib textures_cellular_automata.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const common = @import("example_common");

const distance = zm.distance;
const float = zm.float;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const bufPrint = std.fmt.bufPrint;
const sliceAsBytes = std.mem.sliceAsBytes;

const im_w: usize = 512;
const im_h: usize = 512;
const lines_per_frame: usize = 4;

const presets = [_]u8{ 18, 30, 60, 86, 102, 124, 126, 150, 182, 225 };

const on_color: Color = common.palette.ink;
const off_color: Color = common.palette.surface;

const State = struct {
    font: z.Font,
    pixels: []Color,
    fb: z.CpuFramebuffer,
    rule: u8 = 30,
    line: usize = 1,
    hold: f32 = 0,
    preset: usize = 1, // presets[1] == 30
    press: Vec2 = .{ 0, 0 },
    dragged: bool = false,
    gpa: Allocator,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.fb.deinit(); // CpuFramebuffer owns a GPU blit texture (+ view + sampler)
    gpa.free(s.pixels);
}

fn seed(s: *State) void {
    @memset(s.pixels, off_color);
    s.pixels[im_w / 2] = on_color; // top-row centre cell on
    s.line = 1;
    s.hold = 0;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const pixels: []Color = try gpa.alloc(Color, im_w * im_h);
    @memset(pixels, off_color);
    pixels[im_w / 2] = on_color;
    const fb: z.CpuFramebuffer = z.CpuFramebuffer.init(
        f.gpu.device,
        f.gpu.queue,
        @intCast(im_w),
        @intCast(im_h),
        sliceAsBytes(pixels),
        "cellular_automata_fb",
    );
    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24),
        .pixels = pixels,
        .fb = fb,
        .gpa = gpa,
    };
}

fn isOn(s: *State, x: usize, y: usize) bool {
    return s.pixels[y * im_w + x].r > 128;
}

fn computeLine(s: *State, y: usize) void {
    var x: usize = 1;
    while (x < im_w - 1) : (x += 1) {
        const l: u8 = if (isOn(s, x - 1, y - 1)) 4 else 0;
        const c: u8 = if (isOn(s, x, y - 1)) 2 else 0;
        const r: u8 = if (isOn(s, x + 1, y - 1)) 1 else 0;
        const k: u3 = @intCast(l + c + r);
        const lit: bool = ((s.rule >> k) & 1) == 1;
        s.pixels[y * im_w + x] = if (lit) on_color else off_color;
    }
}

fn setRule(s: *State, preset_idx: usize) void {
    s.preset = preset_idx;
    s.rule = presets[preset_idx];
    seed(s);
}

const Layout = struct {
    chip_w: f32,
    chip_h: f32,
    pad: f32,
    canvas_y: f32,
    canvas_h: f32,
};

fn layoutOf(f: *z.Frame) Layout {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const pad: f32 = 8.0;
    const chip_h: f32 = 30.0;
    const chip_w: f32 = (w - 2.0 * pad - float(presets.len - 1) * 4.0) / float(presets.len);
    const canvas_y: f32 = pad + chip_h + pad;
    return .{
        .chip_w = chip_w,
        .chip_h = chip_h,
        .pad = pad,
        .canvas_y = canvas_y,
        .canvas_h = h - canvas_y - pad - 22.0,
    };
}

fn chipX(lay: Layout, i: usize) f32 {
    return lay.pad + float(i) * (lay.chip_w + 4.0);
}

fn update(f: *z.Frame, s: *State) void {
    const lay: Layout = layoutOf(f);
    z.clearViewport(f, common.palette.bg);

    // --- input (edge-triggered tap; chip vs canvas decided from the press point) ---
    const m: Vec2 = z.getMousePosition(f.input);
    if (z.isMouseButtonPressed(f.input, .left)) {
        s.press = m;
        s.dragged = false;
    }
    if (z.isMouseButtonDown(f.input, .left) and distance(m, s.press) > 8.0) {
        s.dragged = true;
    }
    if (z.isMouseButtonReleased(f.input, .left) and !s.dragged) {
        handleTap(s, lay);
    }

    // --- compute next rows + stream to GPU ---
    if (s.line < im_h) {
        var i: usize = 0;
        while (i < lines_per_frame and s.line + i < im_h) : (i += 1) {
            computeLine(s, s.line + i);
        }
        s.line += lines_per_frame;
        s.fb.update(f.gpu.queue, sliceAsBytes(s.pixels));
    } else {
        s.hold += f.time.delta_time;
        if (s.hold > 1.5) {
            setRule(s, (s.preset + 1) % presets.len);
        }
    }

    // --- draw: CA canvas, then the preset chips on top ---
    s.fb.present(f.gl, lay.pad, lay.canvas_y, f.window.widthf() - 2.0 * lay.pad, lay.canvas_h);
    drawChips(f, s, lay);

    var buf: [32]u8 = undefined;
    const label: []const u8 = bufPrint(&buf, "rule {d} - tap a preset or the canvas", .{s.rule}) catch "";
    common.caption(f.gl, s.font, label);
    z.endDrawing(f.gl);
}

fn handleTap(s: *State, lay: Layout) void {
    // chip row?
    if (s.press[1] >= lay.pad and s.press[1] <= lay.pad + lay.chip_h) {
        var i: usize = 0;
        while (i < presets.len) : (i += 1) {
            const x0: f32 = chipX(lay, i);
            if (s.press[0] >= x0 and s.press[0] <= x0 + lay.chip_w) {
                setRule(s, i);
                return;
            }
        }
    }
    // otherwise cycle
    setRule(s, (s.preset + 1) % presets.len);
}

fn drawChips(f: *z.Frame, s: *State, lay: Layout) void {
    const gl = f.gl;
    var i: usize = 0;
    while (i < presets.len) : (i += 1) {
        const x0: f32 = chipX(lay, i);
        const selected: bool = (i == s.preset);
        const fill: Color = if (selected) common.palette.accent else common.palette.surface;
        gl.rectRoundedXYWH(x0, lay.pad, lay.chip_w, lay.chip_h, 0.35, 6, .{ .color = fill });
        var nb: [8]u8 = undefined;
        const num: []const u8 = bufPrint(&nb, "{d}", .{presets[i]}) catch "";
        const dim: Vec2 = z.measureText(s.font, num, 14);
        const tcol: Color = if (selected) common.palette.bg else common.palette.ink_dim;
        gl.text(
            .{ x0 + (lay.chip_w - dim[0]) * 0.5, lay.pad + (lay.chip_h - dim[1]) * 0.5 },
            num,
            .{ .size = 14, .color = tcol, .font = &s.font },
        );
    }
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - cellular automata",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
