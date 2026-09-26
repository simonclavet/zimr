// examples/plot3d_gallery/plot3d_gallery.zig
//! A tabbed gallery of zimr's 3D plotting (the ImPlot3D port), reproducing the
//! plots from ImPlot3D's README: a line + scatter pair (f(x)/g(x)), a warm
//! "wave surface", a correlated scatter cloud (Data 1 / Data 2), a wireframe
//! sphere, a solid mesh, and the filled-vs-open marker matrix with rotated
//! text. It mirrors plot_demo's tabbed shell, but each tab drives
//! `z.plot3d` (CPU projection + painter's-algorithm depth sort over ui.zig)
//! instead of the 2D plot_ui.
//!
//! Note: ImPlot3D's README renders a rubber-duck OBJ for its mesh example. That
//! asset is not bundled here, so the "Mesh" tab generates a torus to show the
//! same thing the duck does - an arbitrary solid triangle mesh, shaded.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;
const ui = z.ui_real;
const p3 = z.plot3d;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

// File-scope binds (lint: no qualified zm.* in bodies).
const Vec2 = zm.Vec2;
const pi = zm.pi;

const screen_w: i32 = 980;
const screen_h: i32 = 860;
const plot_h: f32 = 624;

// ---- data sizes ----------------------------------------------------------
const spring_n: usize = 480; // f(x): a coiled spring (line)
const gx_n: usize = 28; // g(x): rising parabola (scatter)
const grid_n: usize = 40; // wave surface is grid_n x grid_n vertices
const surf_n: usize = grid_n * grid_n;
const cloud1_n: usize = 220; // Data 1 (diagonal cloud)
const cloud2_n: usize = 90; // Data 2 (cross streak)

// sphere mesh (wireframe): (stacks+1) x (slices+1) vertices.
const sph_stacks: usize = 20;
const sph_slices: usize = 22;
const sph_vtx_cap: usize = (sph_stacks + 1) * (sph_slices + 1);
const sph_idx_cap: usize = sph_stacks * sph_slices * 6;

// torus mesh (solid): rings x sides vertices.
const tor_rings: usize = 48;
const tor_sides: usize = 24;
const tor_vtx_n: usize = tor_rings * tor_sides;
const tor_idx_n: usize = tor_rings * tor_sides * 6;

// ---- colors (zm.Color via p3.rgbaF; 0..1 sRGB floats) --------------------
const blue: Color = p3.rgbaF(0.30, 0.55, 0.95, 1);
const orange: Color = p3.rgbaF(0.95, 0.55, 0.20, 1);
const white: Color = p3.rgbaF(0.92, 0.94, 0.98, 1);
const yellow: Color = p3.rgbaF(0.88, 0.80, 0.12, 1);
const edge_dark: Color = p3.rgbaF(0.18, 0.16, 0.05, 1);
const clear: Color = p3.rgbaF(0, 0, 0, 0);

const marker_kinds = [_]p3.Marker{
    .circle, .square, .diamond, .up,   .down,
    .left,   .right,  .cross,   .plus, .asterisk,
};
const marker_cols = [_]Color{
    p3.rgbaF(0.91, 0.30, 0.24, 1),
    p3.rgbaF(0.95, 0.55, 0.20, 1),
    p3.rgbaF(0.93, 0.83, 0.25, 1),
    p3.rgbaF(0.40, 0.78, 0.35, 1),
    p3.rgbaF(0.25, 0.74, 0.70, 1),
    p3.rgbaF(0.30, 0.55, 0.95, 1),
    p3.rgbaF(0.45, 0.40, 0.85, 1),
    p3.rgbaF(0.65, 0.40, 0.85, 1),
    p3.rgbaF(0.90, 0.40, 0.80, 1),
    p3.rgbaF(0.70, 0.72, 0.78, 1),
};
// Unique per-row labels so the two columns never collide on item IDs.
const lbl_filled = [_][:0]const u8{
    "fm0", "fm1", "fm2", "fm3", "fm4", "fm5", "fm6", "fm7", "fm8", "fm9",
};
const lbl_open = [_][:0]const u8{
    "om0", "om1", "om2", "om3", "om4", "om5", "om6", "om7", "om8", "om9",
};

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    ctx: *p3.Context,
    current_tab: usize = 0,

    spring_x: [spring_n]f32 = undefined,
    spring_y: [spring_n]f32 = undefined,
    spring_z: [spring_n]f32 = undefined,
    gx_x: [gx_n]f32 = undefined,
    gx_y: [gx_n]f32 = undefined,
    gx_z: [gx_n]f32 = undefined,

    surf_x: [surf_n]f32 = undefined,
    surf_y: [surf_n]f32 = undefined,
    surf_z: [surf_n]f32 = undefined,

    c1x: [cloud1_n]f32 = undefined,
    c1y: [cloud1_n]f32 = undefined,
    c1z: [cloud1_n]f32 = undefined,
    c2x: [cloud2_n]f32 = undefined,
    c2y: [cloud2_n]f32 = undefined,
    c2z: [cloud2_n]f32 = undefined,

    sph_v: [sph_vtx_cap]p3.Point3 = undefined,
    sph_i: [sph_idx_cap]u32 = undefined,
    sph_vn: usize = 0,
    sph_in: usize = 0,

    tor_v: [tor_vtx_n]p3.Point3 = undefined,
    tor_i: [tor_idx_n]u32 = undefined,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    p3.destroyContext(s.ctx);
    s.ui_host.deinit();
}

/// Fill a torus: `rings` major segments, `sides` minor segments. Wraps both
/// rings of indices so the surface is closed.
fn genTorus(
    out_v: []p3.Point3,
    out_i: []u32,
    big_r: f32,
    small_r: f32,
    rings: usize,
    sides: usize,
) void {
    var vi: usize = 0;
    for (0..rings) |ri| {
        const a: f32 = 2.0 * pi * float(ri) / float(rings);
        for (0..sides) |si| {
            const b: f32 = 2.0 * pi * float(si) / float(sides);
            const rim: f32 = big_r + small_r * @cos(b);
            out_v[vi] = p3.point3(rim * @cos(a), rim * @sin(a), small_r * @sin(b));
            vi += 1;
        }
    }
    var ii: usize = 0;
    for (0..rings) |ri| {
        const rn: usize = (ri + 1) % rings;
        for (0..sides) |si| {
            const sn: usize = (si + 1) % sides;
            const v00: u32 = @intCast(ri * sides + si);
            const v10: u32 = @intCast(rn * sides + si);
            const v11: u32 = @intCast(rn * sides + sn);
            const v01: u32 = @intCast(ri * sides + sn);
            out_i[ii + 0] = v00;
            out_i[ii + 1] = v10;
            out_i[ii + 2] = v11;
            out_i[ii + 3] = v00;
            out_i[ii + 4] = v11;
            out_i[ii + 5] = v01;
            ii += 6;
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

    // f(x): a horizontal coiled spring (nine turns) along x.
    for (0..spring_n) |i| {
        const t: f32 = float(i) / float(spring_n - 1);
        const ang: f32 = t * 9.0 * 2.0 * pi;
        s.spring_x[i] = t;
        s.spring_y[i] = 0.30 * @sin(ang);
        s.spring_z[i] = 0.30 * @cos(ang);
    }
    // g(x): a rising parabola sampled as markers.
    for (0..gx_n) |i| {
        const t: f32 = float(i) / float(gx_n - 1);
        s.gx_x[i] = t;
        s.gx_y[i] = 0;
        s.gx_z[i] = t * t;
    }

    // Wave surface: radial z = cos(r), giving a central peak, a trough ring,
    // and rising corners (domain chosen so the corners reach the next crest).
    for (0..grid_n) |j| {
        for (0..grid_n) |i| {
            const fx: f32 = float(i) / float(grid_n - 1);
            const fy: f32 = float(j) / float(grid_n - 1);
            const xv: f32 = -4.6 + 9.2 * fx;
            const yv: f32 = -4.6 + 9.2 * fy;
            const r: f32 = @sqrt(xv * xv + yv * yv);
            const idx: usize = j * grid_n + i;
            s.surf_x[idx] = xv;
            s.surf_y[idx] = yv;
            s.surf_z[idx] = 0.85 * @cos(r);
        }
    }

    var prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0x9E3779B97F4A7C15);
    const rnd: std.Random = prng.random();
    // Data 1: a noisy main-diagonal cloud.
    for (0..cloud1_n) |i| {
        const t: f32 = float(i) / float(cloud1_n - 1);
        s.c1x[i] = t + rnd.floatNorm(f32) * 0.05;
        s.c1y[i] = t + rnd.floatNorm(f32) * 0.05;
        s.c1z[i] = t + rnd.floatNorm(f32) * 0.05;
    }
    // Data 2: a tight cluster crossing the diagonal near the centre.
    for (0..cloud2_n) |i| {
        const u: f32 = rnd.float(f32) * 2.0 - 1.0;
        s.c2x[i] = 0.5 + u * 0.32 + rnd.floatNorm(f32) * 0.03;
        s.c2y[i] = 0.5 - u * 0.04 + rnd.floatNorm(f32) * 0.05;
        s.c2z[i] = 0.5 + rnd.floatNorm(f32) * 0.05;
    }

    // Wireframe sphere mesh.
    const sc: p3.SphereCounts = p3.genSphere(1.0, sph_stacks, sph_slices, s.sph_v[0..], s.sph_i[0..]);
    s.sph_vn = sc.vtx;
    s.sph_in = sc.idx;

    // Solid torus mesh (the duck stand-in).
    genTorus(s.tor_v[0..], s.tor_i[0..], 0.70, 0.30, tor_rings, tor_sides);
}

fn tabLineScatter(s: *State) void {
    p3.pushColormap(s.ctx, .deep);
    if (p3.beginPlot(s.ctx, "f(x) / g(x)###ls", .{ 0, plot_h }, .{})) {
        p3.setupAxes(s.ctx, "x", "y", "z", .{}, .{}, .{});
        p3.setupAxesLimits(s.ctx, 0, 1, -0.4, 0.4, -0.4, 1.1, .once);
        p3.plotLine(s.ctx, f32, "f(x)", s.spring_x[0..], s.spring_y[0..], s.spring_z[0..], .{
            .line_color = blue,
            .line_weight = 2.0,
        });
        p3.plotScatter(s.ctx, f32, "g(x)", s.gx_x[0..], s.gx_y[0..], s.gx_z[0..], .{
            .marker = .circle,
            .marker_size = 4.0,
            .line_color = orange,
        });
        p3.endPlot(s.ctx);
    }
}

fn tabSurface(s: *State) void {
    p3.pushColormap(s.ctx, .hot);
    if (p3.beginPlot(s.ctx, "Wave Surface###surf", .{ 0, plot_h }, .{})) {
        p3.setupAxes(s.ctx, "x", "y", "z", .{}, .{}, .{});
        p3.setupAxesLimits(s.ctx, -4.6, 4.6, -4.6, 4.6, -1, 1, .once);
        p3.plotSurface(s.ctx, f32, "Wave Surface", s.surf_x[0..], s.surf_y[0..], s.surf_z[0..], grid_n, grid_n, .{
            .fill_alpha = 1.0,
        });
        p3.endPlot(s.ctx);
    }
}

fn tabScatter(s: *State) void {
    p3.pushColormap(s.ctx, .deep);
    if (p3.beginPlot(s.ctx, "Data 1 / Data 2###sc", .{ 0, plot_h }, .{})) {
        p3.setupAxes(s.ctx, "x", "y", "z", .{}, .{}, .{});
        p3.setupAxesLimits(s.ctx, -0.1, 1.1, -0.1, 1.1, -0.1, 1.1, .once);
        p3.plotScatter(s.ctx, f32, "Data 1", s.c1x[0..], s.c1y[0..], s.c1z[0..], .{
            .marker = .circle,
            .marker_size = 3.0,
            .line_color = blue,
        });
        p3.plotScatter(s.ctx, f32, "Data 2", s.c2x[0..], s.c2y[0..], s.c2z[0..], .{
            .marker = .square,
            .marker_size = 4.0,
            .line_color = orange,
        });
        p3.endPlot(s.ctx);
    }
}

fn tabSphere(s: *State) void {
    p3.pushColormap(s.ctx, .deep);
    if (p3.beginPlot(s.ctx, "Sphere###sph", .{ 0, plot_h }, .{})) {
        p3.setupAxes(s.ctx, "x", "y", "z", .{}, .{}, .{});
        p3.setupAxesLimits(s.ctx, -1.2, 1.2, -1.2, 1.2, -1.2, 1.2, .once);
        // fill_alpha = 0 leaves only the triangle edges -> a see-through mesh.
        p3.plotMesh(s.ctx, "Sphere", s.sph_v[0..s.sph_vn], s.sph_i[0..s.sph_in], .{
            .fill_alpha = 0.0,
            .line_color = white,
            .line_weight = 1.0,
        });
        p3.endPlot(s.ctx);
    }
}

fn tabMesh(s: *State) void {
    p3.pushColormap(s.ctx, .deep);
    if (p3.beginPlot(s.ctx, "Solid Mesh###mesh", .{ 0, plot_h }, .{})) {
        p3.setupAxes(s.ctx, "x", "y", "z", .{}, .{}, .{});
        p3.setupAxesLimits(s.ctx, -1.1, 1.1, -1.1, 1.1, -0.6, 0.6, .once);
        p3.plotMesh(s.ctx, "Solid Mesh", s.tor_v[0..], s.tor_i[0..], .{
            .fill_color = yellow,
            .line_color = edge_dark,
            .line_weight = 1.0,
        });
        p3.endPlot(s.ctx);
    }
}

fn tabMarkers(s: *State) void {
    p3.pushColormap(s.ctx, .deep);
    if (p3.beginPlot(s.ctx, "Markers###mk", .{ 0, plot_h }, .{})) {
        p3.setupAxes(s.ctx, "x", "y", "z", .{}, .{}, .{});
        p3.setupAxesLimits(s.ctx, -2, 2, -1.7, 1.7, -1, 1, .once);
        for (marker_kinds, 0..) |m, i| {
            const yy: f32 = 1.2 - float(i) * 0.26;
            const col: Color = marker_cols[i];

            const xl: [2]f32 = .{ -1.4, -0.8 };
            const xr: [2]f32 = .{ 0.8, 1.4 };
            const ys: [2]f32 = .{ yy, yy };
            const zs: [2]f32 = .{ 0, 0 };

            // Filled markers (left column): the marker fills with the line color.
            p3.plotLine(s.ctx, f32, lbl_filled[i], xl[0..], ys[0..], zs[0..], .{
                .line_color = col,
                .line_weight = 1.5,
                .marker = .none,
                .flags = .{ .no_legend = true },
            });
            p3.plotScatter(s.ctx, f32, lbl_filled[i], xl[0..], ys[0..], zs[0..], .{
                .marker = m,
                .marker_size = 6.0,
                .line_color = col,
                .flags = .{ .no_legend = true },
            });

            // Open markers (right column): transparent fill -> outline only.
            p3.plotLine(s.ctx, f32, lbl_open[i], xr[0..], ys[0..], zs[0..], .{
                .line_color = col,
                .line_weight = 1.5,
                .marker = .none,
                .flags = .{ .no_legend = true },
            });
            p3.plotScatter(s.ctx, f32, lbl_open[i], xr[0..], ys[0..], zs[0..], .{
                .marker = m,
                .marker_size = 6.0,
                .line_color = col,
                .marker_fill_color = clear,
                .flags = .{ .no_legend = true },
            });
        }
        const no_off: Vec2 = .{ 0, 0 };
        p3.plotText(s.ctx, "Filled Markers", -1.1, 1.5, 0, 0, no_off);
        p3.plotText(s.ctx, "Open Markers", 0.7, 1.5, 0, 0, no_off);
        p3.plotText(s.ctx, "Rotated Text", -0.35, 0.0, 0.0, 0.6, no_off);
        p3.endPlot(s.ctx);
    }
}

fn update(f: *z.Frame, s: *State) void {
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);
    p3.setUiHandle(s.ctx, u);

    if (u.window("zimr 3D plot gallery", .{
        .initial_pos = .{ 14, 14 },
        .initial_size = .{ 952, 832 },
    })) |w| {
        defer w.close();
        u.text("ImPlot3D gallery. Drag to orbit, pinch/scroll to zoom, double-tap to fit.", .{});
        u.separator();

        if (u.beginTabBar("gallery", .{})) {
            defer u.endTabBar();
            if (u.beginTabItem("Line + Scatter", null, .{})) {
                defer u.endTabItem();
                tabLineScatter(s);
            }
            if (u.beginTabItem("Surface", null, .{})) {
                defer u.endTabItem();
                tabSurface(s);
            }
            if (u.beginTabItem("Scatter", null, .{})) {
                defer u.endTabItem();
                tabScatter(s);
            }
            if (u.beginTabItem("Sphere", null, .{})) {
                defer u.endTabItem();
                tabSphere(s);
            }
            if (u.beginTabItem("Mesh", null, .{})) {
                defer u.endTabItem();
                tabMesh(s);
            }
            if (u.beginTabItem("Markers", null, .{})) {
                defer u.endTabItem();
                tabMarkers(s);
            }
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - 3D plot gallery",
            .width = screen_w,
            .height = screen_h,
            // Harmless for the CPU painter path; matches plot3d_demo.
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
