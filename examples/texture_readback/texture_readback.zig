//! texture_readback — port of the GL `texture_readback`: prove the
//! GPU→CPU pixel path end-to-end.
//!
//!   1. Render an animated scene into a 256×256 RenderTexture.
//!   2. `wgpu.copyTextureToBuffer` (NEW bridge op, t1171) copies the RTT
//!      into a MAP_READ staging buffer on its own encoder+submit.
//!   3. The poll-based `bufferRead*` family (the compute path's readback
//!      machinery) maps it without ever stalling a frame.
//!   4. The bytes re-upload into a `CpuFramebuffer` and draw NEXT to the
//!      live RTT — the two panels must match (one async step apart).
//!
//! The GL original's `loadImageFromTexture` was synchronous (glReadPixels);
//! WebGPU mapping is async by spec, so the wgpu shape is a frame-delayed
//! state machine: copy → poll → read → re-upload → repeat.  The readback
//! panel therefore trails the live panel by the round-trip latency — watch
//! the orbiting dot lag a step; that lag IS the demo being honest.
//!
//! 256×256 is chosen so `width * 4 = 1024` bytes/row is already 256-aligned
//! (the WebGPU `bytesPerRow` rule) — no row padding to strip.
const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");

const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;
const pi = zm.pi;
const common = @import("example_common");
const c = z.colors;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const rt_size: u32 = 256;
const rt_bytes: u32 = rt_size * rt_size * 4;

const State = struct {
    font: z.Font,
    rt: z.RenderTexture = .{},
    /// MAP_READ|COPY_DST staging buffer the texture copies into.
    staging: z.wgpu.BufferHandle,
    /// In-flight poll handle; .invalid = no read pending → start one.
    read: z.wgpu.BufferRead = .invalid,
    /// CPU destination + the texture it re-uploads into.
    pixels: []u8,
    readback_fb: z.CpuFramebuffer,
    angle: f32 = 0,
    /// Completed round-trips, shown in the HUD (proves liveness in smoke).
    roundtrips: u32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    gpa.free(s.pixels);
    s.rt.deinit();
    s.readback_fb.deinit();
    z.wgpu.destroyBuffer(s.staging);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const pixels: []u8 = try gpa.alloc(u8, rt_bytes);
    @memset(pixels, 0);
    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22),
        .staging = z.wgpu.createBuffer(f.gpu.device, .{
            .size = rt_bytes,
            .usage = .{ .copy_dst = true, .map_read = true },
            .label = "readback_staging",
        }),
        .pixels = pixels,
        .readback_fb = z.CpuFramebuffer.init(
            f.gpu.device,
            f.gpu.queue,
            rt_size,
            rt_size,
            pixels,
            "readback_view",
        ),
    };
}

/// Advance the copy→map→read state machine by at most one step per frame.
/// Submission order makes this read LAST frame's RTT (the copy encoder
/// submits before the frame's own encoder) — exactly the one-step lag the
/// header describes.
fn pumpReadback(f: *z.Frame, s: *State) void {
    if (s.read != .invalid) {
        if (z.wgpu.bufferReadPoll(s.read)) {
            z.wgpu.bufferReadInto(s.read, s.pixels);
            z.wgpu.bufferReadRelease(s.read);
            s.read = .invalid;
            s.readback_fb.update(f.gpu.queue, s.pixels);
            s.roundtrips += 1;
        }
        return;
    }
    const enc: z.wgpu.CommandEncoderHandle = z.wgpu.createCommandEncoder(f.gpu.device);
    z.wgpu.copyTextureToBuffer(enc, s.rt.color, s.staging, rt_size * 4, rt_size, rt_size);
    z.wgpu.queueSubmit(f.gpu.queue, z.wgpu.finishCommandEncoder(enc));
    s.read = z.wgpu.bufferReadStart(s.staging, rt_bytes);
}

fn update(f: *z.Frame, s: *State) void {
    if (s.rt.color == .invalid) {
        s.rt = z.loadRenderTexture(f.gl, rt_size, rt_size);
    }
    pumpReadback(f, s);
    s.angle += f.time.delta_time * 90.0;
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    // OFFSCREEN FIRST (tile-based-GPU safe; app owns begin/endDrawing).
    // ---- Animated source content into the RTT --------------------------------
    z.beginTextureMode(f.gl, s.rt, .{ .r = 18, .g = 22, .b = 34, .a = 255 });
    const rtf: f32 = float(rt_size);
    const rad: f32 = s.angle * pi / 180.0;
    f.gl.rect(
        .{ .x = 24, .y = 24, .width = rtf - 48, .height = rtf - 48 },
        .{ .color = .{ .r = 30, .g = 40, .b = 64, .a = 255 } },
    );
    f.gl.rect(.{ .x = 24, .y = 24, .width = rtf - 48, .height = rtf - 48 }, .{ .color = c.slate_400, .outline = 1.0 });
    f.gl.circle(
        .{ rtf * 0.5 + @cos(rad) * 80, rtf * 0.5 + @sin(rad) * 80 },
        18,
        .{ .color = c.amber_400, .segments = 16 },
    );
    f.gl.circle(.{ rtf * 0.5, rtf * 0.5 }, 30, .{ .color = c.sky_400, .segments = 16 });
    f.gl.rect(
        .{ .x = rtf * 0.5 - 6, .y = rtf * 0.5 - 60 - @sin(rad * 2) * 20, .width = 12, .height = 40 },
        .{ .color = c.rose_400 },
    );
    z.endTextureMode(f.gl);

    // SCREEN PASS: open once, clear, then draw the panels.
    z.beginDrawing(f.gl);
    z.clearViewport(f, common.palette.bg);

    // ---- Two panels: live RTT (left) vs round-tripped pixels (right) ---------
    const pad: f32 = 14;
    const panel: f32 = @min((vw - pad * 3) * 0.5, vh - 110);
    const py: f32 = (vh - panel) * 0.5;
    const x1: f32 = pad;
    const x2: f32 = pad * 2 + panel;
    const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    f.gl.texture(.{ .x = x1, .y = py, .width = panel, .height = panel }, s.rt.asTexture(), .{ .tint = white });
    s.readback_fb.present(f.gl, x2, py, panel, panel);
    f.gl.rect(
        .{ .x = x1 - 1, .y = py - 1, .width = panel + 2, .height = panel + 2 },
        .{ .color = c.slate_500, .outline = 1.0 },
    );
    f.gl.rect(
        .{ .x = x2 - 1, .y = py - 1, .width = panel + 2, .height = panel + 2 },
        .{ .color = c.slate_500, .outline = 1.0 },
    );

    f.gl.text(
        .{ x1, py - 28 },
        "render texture",
        .{ .size = 18, .color = .{ .r = 235, .g = 235, .b = 245, .a = 255 }, .font = &s.font },
    );
    f.gl.text(
        .{ x2, py - 28 },
        "GPU>CPU>GPU readback",
        .{ .size = 18, .color = .{ .r = 235, .g = 235, .b = 245, .a = 255 }, .font = &s.font },
    );
    var hud_buf: [64]u8 = undefined;
    const hud: []const u8 = bufPrint(&hud_buf, "round-trips: {d}", .{s.roundtrips}) catch "round-trips: ?";
    f.gl.text(
        .{ x2, py + panel + 10 },
        hud,
        .{ .size = 16, .color = .{ .r = 170, .g = 180, .b = 200, .a = 255 }, .font = &s.font },
    );
    common.caption(f.gl, s.font, "copyTextureToBuffer + poll-mapped staging - the panels match, one async step apart");
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - texture readback (GPU to CPU to GPU)",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
    // Offscreen render-texture drawn before the screen opens (tile-based-GPU
    // safe); owns its own begin/endDrawing.
    .manages_own_frame = true,
};
