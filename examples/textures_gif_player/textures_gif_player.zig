//! textures_gif_player - port of raylib [textures] example - gif player.
//! raylib source: examples/textures/textures_gif_player.c (complexity 3/4).
//!
//! raylib's original decodes an animated GIF into one big Image (frames
//! appended in memory), uploads it as a texture, and auto-plays it while
//! LEFT/RIGHT change a fixed frame delay measured in vsync ticks. That's a
//! keyboard demo on a desktop; this is the honest phone translation, and it
//! goes further than the original in three ways a touch UI makes worth doing:
//!
//!   * a FRAME SCRUBBER - drag to any frame; raylib has no seek at all.
//!   * TIMELINE-ACCURATE playback - each frame is held for its OWN native
//!     delay (scarfy is a uniform 120 ms, but a real GIF varies per frame),
//!     scaled by a speed slider, instead of raylib's single tick counter.
//!   * frame-by-frame STEP buttons + a play/pause + loop toggle, so you can
//!     inspect the sprite sheet the way an animator would.
//!
//! The decode is the point: `z.loadGifAnim` runs the new pure-Zig GIF codec
//! (`codecs.gif`) - LZW + palette + per-frame disposal/transparency
//! compositing - validated pixel-exact against a reference decoder. Each
//! frame is a full RGBA8 canvas; playback just uploads the current one into a
//! single `CpuFramebuffer` (nearest-filtered, so the pixel art stays crisp).
//! `.memory = .managed`: the decoded frames, the GPU framebuffer, the font
//! and the UI host are all freed in `deinit`, and the twice-lifecycle smoke
//! census must come back FLAT.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;
const c = z.colors;
const common = @import("example_common");

const scarfy_gif = @embedFile("scarfy_run.gif");
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const State = struct {
    font: z.Font,
    ui_host: z.UiHost,
    anim: z.GifAnim,
    fb: z.CpuFramebuffer,

    playing: bool = true,
    loop: bool = true,
    /// Playback speed multiplier (1.0 = the GIF's native timing).
    speed: f32 = 1.0,
    /// Current frame index (also the scrubber's bound value).
    current: u32 = 0,
    /// Frame index currently uploaded to `fb`; -1 forces a first upload.
    shown: i32 = -1,
    /// Wall-clock accumulator (ms) toward the current frame's delay.
    accum_ms: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
    s.anim.deinit(gpa);
    s.fb.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const anim: z.GifAnim = try z.loadGifAnim(gpa, scarfy_gif);
    const ui_font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20);
    s.* = .{
        .font = ui_font,
        .ui_host = z.UiHost.init(gpa, ui_font),
        .anim = anim,
        // One GPU texture, sized to the GIF canvas, updated per frame.
        .fb = z.CpuFramebuffer.init(
            f.gpu.device,
            f.gpu.queue,
            anim.width,
            anim.height,
            anim.frame(0),
            "gif_frame",
        ),
    };
}

/// Advance the play head by wall-clock time, honouring each frame's own
/// native delay. Returns having left `s.current` on the frame to display.
fn advance(f: *z.Frame, s: *State) void {
    if (!s.playing or s.anim.frame_count <= 1) {
        return;
    }
    s.accum_ms += f.time.delta_time * 1000.0 * s.speed;
    // A while-loop (not an if) so a large dt or high speed can skip frames
    // instead of falling behind real time.
    var guard: u32 = 0;
    while (guard < s.anim.frame_count) : (guard += 1) {
        const hold: f32 = float(@max(s.anim.delays_ms[s.current], 1));
        if (s.accum_ms < hold) {
            break;
        }
        s.accum_ms -= hold;
        if (s.current + 1 >= s.anim.frame_count) {
            if (s.loop) {
                s.current = 0;
            } else {
                s.current = s.anim.frame_count - 1;
                s.playing = false;
                s.accum_ms = 0;
                break;
            }
        } else {
            s.current += 1;
        }
    }
}

fn update(f: *z.Frame, s: *State) void {
    const fw: f32 = f.window.widthf();
    const fh: f32 = f.window.heightf();

    advance(f, s);

    // Upload only when the frame actually changed (scrub, step, or play).
    if (s.shown != @as(i32, @intCast(s.current))) {
        s.fb.update(f.gpu.queue, s.anim.frame(s.current));
        s.shown = @intCast(s.current);
    }

    z.clearViewport(f, .{ .r = 18, .g = 20, .b = 28, .a = 255 });
    const u: z.ui_real.Ui = s.ui_host.begin(f);

    // ---- the sprite, centred, scaled up to fit the space above the panel --
    const panel_h: f32 = 250;
    const avail_h: f32 = fh - panel_h - 24;
    const aw: f32 = float(s.anim.width);
    const ah: f32 = float(s.anim.height);
    // Integer scale keeps pixel art crisp; at least 1x, and leave a margin.
    var scale: f32 = @min((fw - 40) / aw, (avail_h - 40) / ah);
    scale = @trunc(scale);
    if (scale < 1) {
        scale = 1;
    }
    const dw: f32 = aw * scale;
    const dh: f32 = ah * scale;
    const dx: f32 = (fw - dw) * 0.5;
    const dy: f32 = 16 + (avail_h - dh) * 0.5;

    // A checkerboard behind the sprite so the GIF's transparency is visible
    // (raylib draws it on solid RAYWHITE and you can't tell it's cut out).
    drawChecker(f.gl, dx, dy, dw, dh);
    s.fb.present(f.gl, dx, dy, dw, dh);
    f.gl.rect(
        .{ .x = dx - 1, .y = dy - 1, .width = dw + 2, .height = dh + 2 },
        .{ .color = c.slate_500, .outline = 1.0 },
    );

    // ---- control panel ----------------------------------------------------
    u.setNextWindowPos(.{ 8, fh - panel_h - 8 }, .{});
    u.setNextWindowSize(.{ fw - 16.0, panel_h }, .{});
    if (u.window("GIF player", .{})) |w| {
        defer w.close();

        u.text("scarfy_run.gif  -  {d}x{d}  -  {d} frames", .{ s.anim.width, s.anim.height, s.anim.frame_count });
        // The byte offset raylib's original prints, as a nod to "frames are
        // just appended in image.data" - here it is the real frame stride.
        const offset: usize = @as(usize, s.current) * @as(usize, s.fb.width) * @as(usize, s.fb.height) * 4;
        u.text("current frame {d} / {d}   data offset {d}", .{ s.current + 1, s.anim.frame_count, offset });
        u.text("this frame delay: {d} ms", .{s.anim.delays_ms[s.current]});
        u.separator();

        if (u.button(if (s.playing) "Pause" else "Play", .{})) {
            s.playing = !s.playing;
            // Resuming from the last frame with loop off? restart.
            if (s.playing and !s.loop and s.current + 1 >= s.anim.frame_count) {
                s.current = 0;
                s.accum_ms = 0;
            }
        }
        u.sameLine(.{});
        if (u.button("|< prev", .{})) {
            s.playing = false;
            s.current = if (s.current == 0) s.anim.frame_count - 1 else s.current - 1;
            s.accum_ms = 0;
        }
        u.sameLine(.{});
        if (u.button("next >|", .{})) {
            s.playing = false;
            s.current = if (s.current + 1 >= s.anim.frame_count) 0 else s.current + 1;
            s.accum_ms = 0;
        }
        u.sameLine(.{});
        _ = u.checkbox("loop", &s.loop);

        // Frame scrubber: dragging pauses and seeks. `slider` is generic over
        // *u32, so the bound value IS the frame index - no float round-trip.
        u.separator();
        if (u.slider("frame", &s.current, .{ .min = 0, .max = s.anim.frame_count - 1 })) {
            s.playing = false;
            s.accum_ms = 0;
        }
        _ = u.slider("speed", &s.speed, .{ .min = 0.1, .max = 4.0 });
    }

    s.ui_host.render(f);

    common.caption(f.gl, s.font, "(c) Scarfy sprite by Eiden Marsal - decoded by the pure-Zig GIF codec");
    z.endDrawing(f.gl);
}

/// A dim checkerboard so the sprite's transparent cut-out reads as such.
fn drawChecker(
    gl: *z.WgpuGl,
    x: f32,
    y: f32,
    wpx: f32,
    hpx: f32,
) void {
    const cell: f32 = 12;
    const a: Color = .{ .r = 44, .g = 48, .b = 58, .a = 255 };
    const b: Color = .{ .r = 34, .g = 38, .b = 46, .a = 255 };
    var yy: f32 = 0;
    var row: u32 = 0;
    while (yy < hpx) : (yy += cell) {
        var xx: f32 = 0;
        var col: u32 = 0;
        while (xx < wpx) : (xx += cell) {
            const cw: f32 = @min(cell, wpx - xx);
            const ch: f32 = @min(cell, hpx - yy);
            const on: bool = ((row + col) & 1) == 0;
            gl.rect(
                .{ .x = x + xx, .y = y + yy, .width = cw, .height = ch },
                .{ .color = if (on) a else b },
            );
            col += 1;
        }
        row += 1;
    }
}

/// Descriptor-only: the runner or launcher drives this. No offscreen render
/// pass, so the runtime owns begin/end (no `manages_own_frame`), exactly like
/// the other 2D UI examples.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - textures gif player",
            .width = 800,
            .height = 640,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
