//! examples/mocap_viewer — a BVH scrubber you can drop files onto.
//!
//! Reproduces the core of **BVHView** (and its descendant flomo, Simon's mocap tool): load a
//! motion-capture clip, play it, scrub it, and compare several at once in different colours.
//!
//! ★ IT OPENS BOTH `.bvh` AND `.fbx`, and the code below barely notices. FBX is normalised into
//! `codecs.bvh.Data` at load, so the skeleton conversion, sampling, forward kinematics and the
//! whole timeline are written once. That is the dividend of flomo's design decision — normalise
//! into BVH rather than build a parallel representation — and it is why adding a format this
//! much larger cost one branch in `addClip`.
//!
//! What it exercises that nothing else in the tree did:
//!   · `codecs.bvh` — the parser, on real captures rather than fixtures
//!   · `draw3d.loadBvhSkeletalClip` — BVH into `ModelSkeleton` + `ModelAnimation`
//!   · `web.userfile` — the first RUNTIME file input zimr has ever had. Every other example
//!     gets its assets from `@embedFile` at comptime.
//!
//! ── ★ THE UNIT SELECTOR IS NOT A NICETY ──
//!
//! BVH carries no unit. The load-time guess ("taller than 10 units, so it must be centimetres")
//! is right for one of the two real fixtures and WRONG for the other: `0005_2FeetJump001` is
//! 61.7 units tall, which the guess reads as 0.62 m — a knee-high dancer. At 0.0254 (inches) it
//! is 1.57 m, which is a person. Both BVHView (`bvhview.c:3656`) and flomo (`flomo.cpp:1327`)
//! ship the same five buttons rather than a cleverer heuristic, so this does too. Without them
//! the viewer looks broken on the second file it is handed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const vec = zm.vec;
const ui = z.ui_real;
const Camera3D = zm.Camera3D;
const Vec = zm.Vec;
const Quat = zm.Quat;
const d3 = z.draw3d;
const bufPrint = std.fmt.bufPrint;
const Color = zm.Color;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

/// The default clip, so the viewer is never blank: 10 seconds of `dance1_subject2`, frames
/// 1200-1800 (20 s to 30 s in), where the dance has actually got going — the opening seconds
/// are mostly the performer standing still.
///
/// Trimmed from a 43 MB original, which cannot be embedded: the whole launcher is 13 MB. Cut
/// reproducibly with `zig build run-bvh-trim` (`tools/bvh_trim.zig`), which runs on zimr's own
/// bvh codec, so this asset is a product of the parse/encode round trip the tests assert rather
/// than a blob trimmed by hand.
///
///     bvh_trim <source>/dance1_subject2.bvh examples/mocap_viewer/dance1_20s.bvh 1200 600
///
/// The 43 MB source is NOT in the repo — it is the one capture nothing reads at runtime, so
/// vendoring it would cost more than every other fixture combined. Re-cutting this clip means
/// fetching it from the capture bundle first; `assets/dance1_subject2_300.bvh` is the same take
/// at 300 frames if all you need is something to parse.
const embedded_bvh = @embedFile("dance1_20s.bvh");

const screen_w: i32 = 1000;
const screen_h: i32 = 760;

/// Beyond this a drop is refused rather than allowed to exhaust wasm memory. Real captures run
/// to tens of megabytes: `dance1_subject2` is 43 MB, so the ceiling has to be generous.
const max_file_bytes: usize = 64 << 20;

const max_clips: usize = 8;

/// The five unit choices both reference viewers offer. `auto` is not a unit at all — it
/// normalises whatever the file says to a 1.8 m figure, which is the only option that is right
/// for every file.
const Units = enum {
    meters,
    centimeters,
    inches,
    feet,
    auto,

    fn label(self: Units) []const u8 {
        return switch (self) {
            .meters => "m",
            .centimeters => "cm",
            .inches => "inch",
            .feet => "feet",
            .auto => "auto",
        };
    }

    fn scale(self: Units, auto_scale: f32) f32 {
        return switch (self) {
            .meters => 1.0,
            .centimeters => 0.01,
            .inches => 0.0254,
            .feet => 0.3048,
            .auto => auto_scale,
        };
    }
};

const Clip = struct {
    clip: d3.BvhSkeletalClip,
    name: [64]u8,
    name_len: usize,
    color: Color,
    visible: bool,
    units: Units,
    /// `1.8 / height`, so `.auto` renders any skeleton at human size.
    auto_scale: f32,
    /// Scratch for one frame of forward kinematics. Sized once at load.
    positions: []Vec,
    rotations: []Quat,

    fn label(self: *const Clip) []const u8 {
        return self.name[0..self.name_len];
    }
};

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    cam: z.OrbitCamera,
    gpa: Allocator,

    clips: [max_clips]Clip = undefined,
    clip_count: usize = 0,
    active: usize = 0,

    play_time: f32 = 0,
    playing: bool = true,
    looping: bool = true,
    /// Lock the root's horizontal travel so the figure dances in place. What makes this a
    /// scrubber rather than a player: a clip that walks away leaves the frame.
    in_place: bool = false,
    show_end_sites: bool = true,
    show_axes: bool = false,

    /// Where the Load button is drawn, so the invisible `<input type="file">` can be parked on
    /// top of it. See `web.userfile` — a wasm-drawn button is not a user gesture.
    picker_rect: [4]f32 = .{ 0, 0, 0, 0 },

    status: [128]u8 = @splat(0),
    status_len: usize = 0,
};

/// Palette for successive clips, so a comparison reads at a glance.
const clip_colors = [_]Color{
    .{ .r = 120, .g = 200, .b = 255, .a = 255 },
    .{ .r = 255, .g = 170, .b = 90, .a = 255 },
    .{ .r = 150, .g = 255, .b = 150, .a = 255 },
    .{ .r = 255, .g = 130, .b = 200, .a = 255 },
    .{ .r = 230, .g = 230, .b = 120, .a = 255 },
    .{ .r = 170, .g = 150, .b = 255, .a = 255 },
    .{ .r = 120, .g = 235, .b = 225, .a = 255 },
    .{ .r = 240, .g = 120, .b = 120, .a = 255 },
};

fn setStatus(s: *State, comptime fmt: []const u8, args: anytype) void {
    const written: []u8 = bufPrint(&s.status, fmt, args) catch {
        s.status_len = 0;
        return;
    };
    s.status_len = written.len;
}

/// Parse `bytes` and append the result as a new clip.
///
/// The BVH `Data` is a scratch value: everything the viewer needs is copied into the engine
/// types by `loadBvhSkeletalClip`, so the parse is freed before this returns. That matters —
/// `Data` holds the whole motion matrix, which for a real capture is most of the file.
fn addClip(s: *State, gpa: Allocator, bytes: []const u8, name: []const u8) !void {
    if (s.clip_count >= max_clips) {
        setStatus(s, "clip limit reached ({d})", .{max_clips});
        return;
    }

    // ★ THE FORMAT IS SNIFFED FROM THE BYTES, NOT THE FILE NAME. A dropped file's name is
    // whatever the user called it, and on the web there is no path at all — but an FBX opens
    // with a 23-byte magic, so the content answers definitively.
    //
    // Both branches end at the SAME `bvh.Data`, which is the payoff of normalising FBX into
    // BVH rather than into a parallel representation: everything below this point — the
    // skeleton conversion, sampling, forward kinematics, the timeline — never learns which
    // format it came from.
    var data: z.codecs.bvh.Data = if (z.codecs.fbx.isBinary(bytes)) blk: {
        var scene: z.codecs.fbx.Scene = z.codecs.fbx.loadScene(gpa, bytes) catch |err| {
            setStatus(s, "{s}: {s}", .{ name, @errorName(err) });
            return;
        };
        defer scene.deinit();
        // Read the capture's own rate; 30/60/120 all occur across the fixtures.
        const hint: ?f32 = z.codecs.bvh.fbxFrameTimeHint(&scene);
        const fps: f32 = if (hint) |ft| (if (ft > 0) 1.0 / ft else 30.0) else 30.0;
        break :blk z.codecs.bvh.fromFbx(gpa, &scene, .{ .fps = fps }) catch |err| {
            // A valid FBX that simply is not a character — an optical-marker capture or a
            // blend-shape rig — deserves that answer rather than "parse failed".
            if (err == z.codecs.bvh.Error.NoSkeleton) {
                setStatus(s, "{s}: no skeleton (mesh or marker data?)", .{name});
            } else {
                setStatus(s, "{s}: {s}", .{ name, @errorName(err) });
            }
            return;
        };
    } else blk: {
        var diag: z.codecs.bvh.Diagnostic = .{};
        break :blk z.codecs.bvh.parse(gpa, bytes, &diag) catch |err| {
            setStatus(s, "{s}: {s} at line {d}", .{ name, @errorName(err), diag.line });
            return;
        };
    };
    defer data.deinit();

    const clip: d3.BvhSkeletalClip = try d3.loadBvhSkeletalClip(gpa, data);
    errdefer d3.unloadBvhSkeletalClip(gpa, clip);

    const n: usize = clip.boneCount();
    const positions: []Vec = try gpa.alloc(Vec, n);
    errdefer gpa.free(positions);
    const rotations: []Quat = try gpa.alloc(Quat, n);
    errdefer gpa.free(rotations);

    const idx: usize = s.clip_count;
    s.clips[idx] = .{
        .clip = clip,
        .name = @splat(0),
        .name_len = @min(name.len, 64),
        .color = clip_colors[idx % clip_colors.len],
        .visible = true,
        .units = .auto,
        .auto_scale = 1.0,
        .positions = positions,
        .rotations = rotations,
    };
    @memcpy(s.clips[idx].name[0..s.clips[idx].name_len], name[0..s.clips[idx].name_len]);

    // Height at frame 0 decides the auto scale AND the initial unit guess. Run FK once rather
    // than trusting the bind pose: a file whose joints all carry position channels (dance1)
    // has offsets that say nothing about where the skeleton actually stands.
    d3.bvhForwardKinematics(clip, 0, positions, rotations);
    var height: f32 = 1.0e-8;
    for (positions) |p| {
        height = @max(height, p[1]);
    }
    s.clips[idx].auto_scale = 1.8 / height;

    s.clip_count += 1;
    s.active = idx;
    s.play_time = 0;
    setStatus(s, "{s}: {d} joints, {d} frames, {d:.1}s", .{
        name,
        n,
        clip.animation.keyframeCount,
        float(clip.animation.keyframeCount) * clip.frame_time,
    });
}

/// Drain any files the user dropped or picked since the last frame.
///
/// Polled rather than delivered by callback: a browser read resolves whenever it resolves, and
/// `web.userfile` exposes that instead of hiding it behind a virtual filesystem the way
/// emscripten does. See its doc comment.
fn pollUserFiles(s: *State, gpa: Allocator) void {
    while (z.web.userfile.pendingCount() > 0) {
        const size: usize = z.web.userfile.nextSize();
        if (size == 0 or size > max_file_bytes) {
            setStatus(s, "file too large ({d} bytes); skipped", .{size});
            z.web.userfile.discardNext();
            continue;
        }

        var name_buf: [64]u8 = @splat(0);
        const name_len: usize = z.web.userfile.nextName(&name_buf);

        const buf: []u8 = gpa.alloc(u8, size) catch {
            setStatus(s, "out of memory for {d} bytes", .{size});
            z.web.userfile.discardNext();
            continue;
        };
        defer gpa.free(buf);

        const got: usize = z.web.userfile.readNext(buf);
        if (got == 0) {
            // The buffer was refused, so the file is still queued. Discard it explicitly or
            // this loop spins forever on the same entry.
            setStatus(s, "could not read {d} bytes", .{size});
            z.web.userfile.discardNext();
            continue;
        }

        const name: []const u8 = if (name_len > 0) name_buf[0..name_len] else "dropped.bvh";
        addClip(s, gpa, buf[0..got], name) catch |err| {
            setStatus(s, "load failed: {s}", .{@errorName(err)});
        };
    }
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20);
    s.* = .{
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
        .cam = z.OrbitCamera.init(vec(0, 0.9, 0), 3.6),
        .gpa = gpa,
    };
    try addClip(s, gpa, embedded_bvh, "dance1_20s.bvh");
}

fn deinit(gpa: Allocator, s: *State) void {
    for (s.clips[0..s.clip_count]) |c| {
        d3.unloadBvhSkeletalClip(gpa, c.clip);
        gpa.free(c.positions);
        gpa.free(c.rotations);
    }
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

/// Draw one posed skeleton: a joint marker per bone and a line to its parent.
///
/// Deliberately the wireframe view, matching `flomo.cpp:887` — capsules with analytical
/// shadows and ambient occlusion are a separate arc (see `mocap_plan.md` §7a) and would
/// obscure whether the POSE is right, which is what this example exists to show.
fn drawSkeleton(
    gl: *z.WgpuGl,
    c: *const Clip,
    scale: f32,
    show_end_sites: bool,
    show_axes: bool,
) void {
    const n: usize = c.clip.boneCount();
    const end_color: Color = .{ .r = 255, .g = 90, .b = 90, .a = 255 };
    for (0..n) |i| {
        const p: Vec = c.positions[i] * @as(Vec, @splat(scale));
        const is_end: bool = c.clip.end_site[i];
        if (is_end and !show_end_sites) {
            continue;
        }
        if (is_end) {
            z.drawCubeWires(gl, p, .{ .size = vec(0.02, 0.02, 0.02), .color = end_color });
        } else {
            z.drawSphereWires(gl, p, .{ .radius = 0.012, .rings = 4, .slices = 6, .color = c.color });
        }

        const parent: i32 = c.clip.skeleton.bones[i].parent;
        if (parent >= 0) {
            const pp: Vec = c.positions[@intCast(parent)] * @as(Vec, @splat(scale));
            z.drawLine3D(gl, p, pp, if (is_end) end_color else c.color);
        }

        // An RGB triad is the fastest way to SEE a wrong rotation order — the single most
        // likely BVH bug, since real files disagree (ZYX, XYZ, ZXY all occur).
        if (show_axes and !is_end) {
            const q: Quat = c.rotations[i];
            const len: f32 = 0.06;
            z.drawLine3D(gl, p, p + zm.rotate(q, vec(len, 0, 0)), .{ .r = 255, .g = 60, .b = 60, .a = 255 });
            z.drawLine3D(gl, p, p + zm.rotate(q, vec(0, len, 0)), .{ .r = 60, .g = 255, .b = 60, .a = 255 });
            z.drawLine3D(gl, p, p + zm.rotate(q, vec(0, 0, len)), .{ .r = 60, .g = 120, .b = 255, .a = 255 });
        }
    }
}

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;
    pollUserFiles(s, s.gpa);

    // Advance the clock off the ACTIVE clip's frame time. 60 fps and 120 fps files both occur;
    // assuming either turns the other into slow motion or a blur.
    if (s.playing and s.clip_count > 0) {
        const a: *const Clip = &s.clips[s.active];
        const duration: f32 = float(a.clip.animation.keyframeCount) * a.clip.frame_time;
        s.play_time += f.time.delta_time;
        if (s.play_time >= duration) {
            s.play_time = if (s.looping) 0 else duration;
        }
    }

    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    z.clearViewport(f, .{ .r = 16, .g = 18, .b = 24, .a = 255 });
    const cam: Camera3D = s.cam.update(f, u.wantCaptureMouse(), .{
        .min_distance = 0.5,
        .max_distance = 12.0,
    });
    z.beginMode3D(gl, cam);
    z.drawGrid(gl, 20, 0.25);

    for (s.clips[0..s.clip_count]) |*c| {
        if (!c.visible) {
            continue;
        }
        const frames: usize = @intCast(@max(c.clip.animation.keyframeCount, 0));
        if (frames == 0) {
            continue;
        }
        // Each clip is sampled at the SHARED wall-clock time, converted through its own frame
        // rate — that is what lets a 60 fps and a 120 fps capture play side by side correctly.
        var k: usize = @trunc(@max(s.play_time / c.clip.frame_time, 0));
        if (k >= frames) {
            k = if (s.looping) k % frames else frames - 1;
        }
        d3.bvhForwardKinematics(c.clip, k, c.positions, c.rotations);
        if (s.in_place) {
            // Cancel the root's horizontal travel, keeping height so a jump still reads.
            const root: Vec = c.positions[0];
            const shift: Vec = vec(root[0], 0, root[2]);
            for (c.positions) |*p| {
                p.* -= shift;
            }
        }
        drawSkeleton(gl, c, c.units.scale(c.auto_scale), s.show_end_sites, s.show_axes);
    }
    z.endMode3D(gl);

    drawPanel(s, u);
}

fn drawPanel(s: *State, u: ui.Ui) void {
    if (u.window("mocap viewer", .{
        .initial_pos = .{ 12, 12 },
        .initial_size = .{ 330, 470 },
    })) |w| {
        defer w.close();

        u.text("Drop .bvh or .fbx files anywhere, or tap Load.", .{});

        // The Load button's rectangle is handed to the host every frame so the invisible
        // <input type="file"> tracks it. A stale overlay would swallow taps meant elsewhere.
        _ = u.button("Load .bvh / .fbx", .{});
        const rmin: zm.Vec2 = u.getItemRectMin();
        const rmax: zm.Vec2 = u.getItemRectMax();
        s.picker_rect = .{ rmin[0], rmin[1], rmax[0] - rmin[0], rmax[1] - rmin[1] };
        z.web.userfile.setPickerRect(
            s.picker_rect[0],
            s.picker_rect[1],
            s.picker_rect[2],
            s.picker_rect[3],
            ".bvh,.fbx",
        );

        if (s.status_len > 0) {
            u.text("{s}", .{s.status[0..s.status_len]});
        }
        u.separator();

        if (s.clip_count == 0) {
            u.text("no clips loaded", .{});
            return;
        }

        const a: *Clip = &s.clips[s.active];
        const frames: f32 = float(@max(a.clip.animation.keyframeCount, 0));
        const duration: f32 = frames * a.clip.frame_time;

        _ = u.checkbox("play", &s.playing);
        u.sameLine(.{});
        _ = u.checkbox("loop", &s.looping);
        u.sameLine(.{});
        _ = u.checkbox("in place", &s.in_place);
        _ = u.checkbox("end sites", &s.show_end_sites);
        u.sameLine(.{});
        _ = u.checkbox("axes", &s.show_axes);

        _ = u.slider("time", &s.play_time, .{ .min = 0.0, .max = duration, .fmt = "{d:.2}s" });
        u.text("frame {d} / {d}   {d:.0} fps", .{
            @as(usize, @trunc(@max(s.play_time / a.clip.frame_time, 0))),
            @as(usize, @trunc(frames)),
            1.0 / a.clip.frame_time,
        });

        u.separator();
        u.text("units ({s})", .{a.units.label()});
        inline for (@typeInfo(Units).@"enum".field_names, 0..) |_, i| {
            const unit: Units = @fromBackingInt(@intCast(i));
            if (i > 0) {
                u.sameLine(.{});
            }
            if (u.button(unit.label(), .{})) {
                a.units = unit;
            }
        }

        u.separator();
        u.text("clips", .{});
        for (s.clips[0..s.clip_count], 0..) |*c, i| {
            _ = u.checkbox(c.label(), &c.visible);
            u.sameLine(.{});
            if (u.button("select", .{})) {
                s.active = i;
            }
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - mocap viewer",
            .width = screen_w,
            .height = screen_h,
            // The 3D primitives are depth-tested, so the main pass needs a depth attachment.
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
