// examples/plot3d_demo.zig — the first target that drives `zimr.plot3d`.
//
// Purpose is twofold:
//   1. A real full-graph compile gate. plot3d was ported and then migrated
//      onto zimrmath (f32 zm.Vec/zm.Quat) while UNWIRED to any build target,
//      so its function bodies had only ever been forced through `zig test`.
//      Being an actual wgpu example compiles it under the true backend.
//   2. Visual validation of the quaternion conventions. zm's `qmul` is Hamilton
//      order (`qmul(a,b) == a*b`, matching matrices and Jolt) — but rotation is
//      something the eye confirms, not the type checker. Drag-orbit here runs the
//      exact compose path (`plot.rotation = qmul(qmul(q_pitch, rotation), q_yaw)`).
//
// Three series, each lighting up a different code path:
//   · a parametric helix      -> plotLine     (projection + per-segment depth)
//   · a Lissajous point cloud -> plotScatter  (markers, NDC normalize)
//   · a sinc ripple surface   -> plotSurface  (the painter's-algorithm
//                                              triangle batch + colormap fill)

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const ui = z.ui_real;
const p3 = z.plot3d;
const pi = zm.pi;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const screen_w: i32 = 980;
const screen_h: i32 = 820;

const helix_n: usize = 240;
const cloud_n: usize = 400;
const grid_n: usize = 32; // surface is grid_n × grid_n vertices

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    ctx: *p3.Context,

    // Static geometry, filled once in init (the helix and cloud are
    // deterministic; only the surface animates).
    helix_x: [helix_n]f32 = undefined,
    helix_y: [helix_n]f32 = undefined,
    helix_z: [helix_n]f32 = undefined,
    cloud_x: [cloud_n]f32 = undefined,
    cloud_y: [cloud_n]f32 = undefined,
    cloud_z: [cloud_n]f32 = undefined,

    // Surface vertex buffers (row-major grid_n × grid_n), rebuilt per frame.
    surf_x: [grid_n * grid_n]f32 = undefined,
    surf_y: [grid_n * grid_n]f32 = undefined,
    surf_z: [grid_n * grid_n]f32 = undefined,

    // Toggles.
    show_helix: bool = true,
    show_cloud: bool = true,
    show_surface: bool = true,
    show_mesh: bool = false,
    animate: bool = true,
    ripple_amp: f32 = 1.0,
    anim_t: f32 = 0.0,

    // Scaled copy of plot3d's built-in unit cube, exercised by plotMesh.
    cube_v: [8]p3.Point3 = undefined,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    p3.destroyContext(s.ctx);
    s.ui_host.deinit();
}

/// sinc ripple: z = amp · sinc(k·r − phase), sampled on a [-2,2]² grid.
fn rebuildSurface(s: *State, phase: f32) void {
    const span: f32 = 4.0; // domain width, centered at 0
    for (0..grid_n) |iy| {
        for (0..grid_n) |ix| {
            const fx: f32 = float(ix) / float(grid_n - 1);
            const fy: f32 = float(iy) / float(grid_n - 1);
            const x: f32 = -span / 2.0 + fx * span;
            const y: f32 = -span / 2.0 + fy * span;
            const r: f32 = @sqrt(x * x + y * y) + 1e-4;
            const arg: f32 = 2.5 * r - phase;
            const sinc: f32 = @sin(arg) / arg;
            const idx: usize = iy * grid_n + ix;
            s.surf_x[idx] = x;
            s.surf_y[idx] = y;
            s.surf_z[idx] = s.ripple_amp * sinc * 2.0;
        }
    }
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 28);
    s.* = .{
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
        .ctx = p3.createContext(gpa),
    };

    // Helix: r=1 spiral climbing in z, two turns.
    for (0..helix_n) |i| {
        const t: f32 = float(i) / float(helix_n - 1);
        const ang: f32 = t * 4.0 * pi;
        s.helix_x[i] = @cos(ang);
        s.helix_y[i] = @sin(ang);
        s.helix_z[i] = -1.0 + 2.0 * t;
    }

    // Lissajous cloud: deterministic PRNG-free sampling of a 3-freq curve,
    // jittered onto a shell so it reads as a cloud rather than a wire.
    for (0..cloud_n) |i| {
        const t: f32 = float(i) / float(cloud_n - 1);
        const a: f32 = t * 2.0 * pi;
        s.cloud_x[i] = @sin(3.0 * a) * (0.6 + 0.4 * @cos(7.0 * a));
        s.cloud_y[i] = @sin(4.0 * a + 1.3) * 0.9;
        s.cloud_z[i] = @cos(5.0 * a) * 0.8;
    }

    rebuildSurface(s, 0.0);
    // Scale the built-in ±0.5 unit cube up to ±0.8 plot units.
    for (p3.cube_vtx, 0..) |v, i| {
        s.cube_v[i] = v * zm.splat(1.6);
    }
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, .{ .r = 14, .g = 16, .b = 22, .a = 255 });

    if (s.animate) {
        s.anim_t += f.time.delta_time * 2.0;
    }
    rebuildSurface(s, s.anim_t);

    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    // plot3d reads input, layout and the draw list through this handle; bind
    // it once per frame before any plot3d call.
    p3.setUiHandle(s.ctx, u);

    if (u.window("3D plot demo", .{
        .initial_pos = .{ 16, 16 },
        .initial_size = .{ 948, 788 },
    })) |w| {
        defer w.close();

        u.text("Drag to orbit. Pinch/scroll to zoom. Shift-drag or two-finger to pan. Double-click resets.", .{});
        _ = u.checkbox("helix (line)", &s.show_helix);
        u.sameLine(.{});
        _ = u.checkbox("cloud (scatter)", &s.show_cloud);
        u.sameLine(.{});
        _ = u.checkbox("surface", &s.show_surface);
        _ = u.checkbox("animate ripple", &s.animate);
        _ = u.checkbox("mesh + tri + quad", &s.show_mesh);
        _ = u.slider("ripple amplitude", &s.ripple_amp, .{ .min = 0.0, .max = 2.0, .fmt = "{d:.2}" });
        u.separator();

        if (p3.beginPlot(s.ctx, "sinc surface + helix + cloud###scene", .{ 0, 560 }, .{})) {
            p3.setupAxes(s.ctx, "x", "y", "z", .{}, .{}, .{});
            p3.setupAxesLimits(s.ctx, -2.2, 2.2, -2.2, 2.2, -2.2, 2.2, .once);

            if (s.show_surface) {
                p3.plotSurface(
                    s.ctx,
                    f32,
                    "sinc",
                    s.surf_x[0..],
                    s.surf_y[0..],
                    s.surf_z[0..],
                    grid_n,
                    grid_n,
                    .{ .fill_alpha = 0.75 },
                );
            }
            if (s.show_helix) {
                p3.plotLine(
                    s.ctx,
                    f32,
                    "helix",
                    s.helix_x[0..],
                    s.helix_y[0..],
                    s.helix_z[0..],
                    .{ .line_weight = 2.0 },
                );
            }
            if (s.show_cloud) {
                p3.plotScatter(
                    s.ctx,
                    f32,
                    "cloud",
                    s.cloud_x[0..],
                    s.cloud_y[0..],
                    s.cloud_z[0..],
                    .{ .marker = .circle, .marker_size = 2.5 },
                );
            }
            if (s.show_mesh) {
                p3.plotMesh(s.ctx, "cube", s.cube_v[0..], p3.cube_idx[0..], .{ .fill_alpha = 0.35 });
                // A free-standing triangle and quad in opposite corners — small,
                // mostly here to force-analyze plotTriangle/plotQuad under the
                // real build (their generic bodies are otherwise uninstantiated).
                const tx: [3]f32 = .{ -1.8, -1.0, -1.4 };
                const ty: [3]f32 = .{ -1.8, -1.8, -1.0 };
                const tz: [3]f32 = .{ 1.4, 1.4, 2.0 };
                p3.plotTriangle(s.ctx, f32, "tri", tx[0..], ty[0..], tz[0..], .{ .fill_alpha = 0.6 });
                const qx: [4]f32 = .{ 1.0, 1.8, 1.8, 1.0 };
                const qy: [4]f32 = .{ 1.0, 1.0, 1.8, 1.8 };
                const qz: [4]f32 = .{ -1.8, -1.8, -1.2, -1.2 };
                p3.plotQuad(s.ctx, f32, "quad", qx[0..], qy[0..], qz[0..], .{ .fill_alpha = 0.6 });
            }
            p3.endPlot(s.ctx);
        }
    }
}

/// Descriptor-only integration point; the wgpu_runner owns the frame.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - 3D plot demo",
            .width = screen_w,
            .height = screen_h,
            // The GPU surface path (drawTriangle3D) is depth-tested, so the main
            // pass needs a depth attachment. Harmless for the CPU path: the 2D
            // pipelines carry depth state when this is set.
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
