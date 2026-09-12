//! launcher — the flagship multi-app switcher. Hosts many full example apps
//! (each self-contained: its own shaders/fonts/State, isolated leak-checking
//! allocator) and shows ONE at a time full-screen via z.Launcher. A switch pill
//! (◂ prev, a dot per app, ▸ next) cycles between apps on tap.
//!
//! Children are added with addDeferred (LAZY): only the shown app is initialized,
//! on the frame it's first switched to — so booting many apps (incl. a 6MB
//! helmet) stays light. The contract is uniform: a child draws its scene + its
//! own UI and NEVER calls endDrawing — the runner owns frame begin/end, and the
//! launcher composes this pill on top in the same frame. App.endDrawing asserts
//! if a child violates that (see Launcher.tickFullscreen).
//!
//! Why fullscreen (not a placement rect): pushViewport remaps RENDERING but not
//! INPUT, so an offset child's own touch UI (physics orbit, showcase tabs) would
//! mis-hit. Fullscreen keeps each child's input space identical to standalone. On
//! a switch tap we change the index and SKIP the child that frame, so the tap
//! can't bleed into the incoming app.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const vec2 = zm.vec2;

// The flagship roster. Order = switch order. A broad tour of the engine: 3D PBR,
// full UI, physics, robot dynamics with a live MPC planner, two CPU-vs-GPU
// side-by-sides, 2D/3D plots, two GPU fluids, a warp starfield, switchable 2D
// post-fx, and fractals.
const flagships = [_]z.AppVtable{
    z.eraseApp(@import("ex_helmet_sw").app), // CPU vs GPU PBR helmet
    z.eraseApp(@import("ex_bone_socket").app), // rigged character, skeletal animation + socketed sword
    z.eraseApp(@import("ex_shadowmap_sw").app), // CPU vs GPU vs comptime shadow map
    z.eraseApp(@import("ex_decals").app), // projected decals onto geometry
    z.eraseApp(@import("ex_deferred_render").app), // MRT G-buffer deferred rendering
    z.eraseApp(@import("ex_cel_shading").app), // toon/cel shading
    z.eraseApp(@import("ex_fog_rendering").app), // distance fog
    z.eraseApp(@import("ex_hybrid_render").app), // raster cubes + raymarched metaballs
    z.eraseApp(@import("ex_textures_background_scrolling").app), // parallax scrolling layers
    z.eraseApp(@import("ex_ui_full_showcase").app), // full imgui-style UI
    z.eraseApp(@import("ex_zimrphysics_demo").app), // Jolt physics scenes
    z.eraseApp(@import("ex_zimrphysics2d_demo").app), // box2d 2D physics scenes
    z.eraseApp(@import("ex_mpc_cartpole").app), // MPC: a cartpole planning its own swing-up
    z.eraseApp(@import("ex_mandel_sidebyside").app), // CPU vs GPU mandelbrot
    z.eraseApp(@import("ex_rt_sidebyside").app), // CPU vs GPU ray tracer
    z.eraseApp(@import("ex_plot_demo").app), // 2D plotting
    z.eraseApp(@import("ex_plot3d_demo").app), // 3D plotting
    z.eraseApp(@import("ex_sph_fluid_2d").app), // GPU SPH fluid
    z.eraseApp(@import("ex_fluid_sort").app), // GPU SPH fluid (sorted grid)
    z.eraseApp(@import("ex_four_ways").app),
    z.eraseApp(@import("ex_worker_png").app), // PNG encode on a Web Worker (off the main thread)
    z.eraseApp(@import("ex_mandel_julia").app), // fractal explorer
    z.eraseApp(@import("ex_waving_cubes").app), // animated HSV cube field
    z.eraseApp(@import("ex_tic_tac_toe").app), // two-player tic tac toe, plain 2D shapes
    z.eraseApp(@import("ex_langton_ant").app), // Langtons ant with pan/zoom + turn trail
    z.eraseApp(@import("ex_snake").app), // snake: eat dots to grow, keyboard + swipe
    z.eraseApp(@import("ex_fps_playground").app), // first-person physics: walk + jump on cubes
    z.eraseApp(@import("ex_starfield").app), // warp-speed starfield
    z.eraseApp(@import("ex_shader_effects").app), // switchable 2D post-fx
    // ★ A Go1 with a procedurally spliced arm: the torso weaves through three incommensurate
    // frequencies while the gripper holds a point that travels with the feet. Reports its own
    // attitude error, gripper drift, foot slip and friction-cone occupancy.
    z.eraseApp(@import("ex_quadruped").app), // articulated robot: gimbal + contact readouts
    z.eraseApp(@import("ex_gallery_all").app), // 2x2 grid of 4 mini-apps (launcher-in-launcher!)
};
const n_apps = flagships.len;

pub const std_options = z.std_options;

const State = struct {
    launcher: z.Launcher,
    ids: [n_apps]z.ChildId,
    active: usize,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    _ = f;
    // Build the Launcher straight into its final home and register children on
    // it there — no local `var launcher` that gets copied into the slot. `.ids`
    // is filled by the loop below (still exhaustive: the field is written here).
    s.* = .{ .launcher = z.Launcher.init(gpa), .ids = undefined, .active = 0 };
    inline for (flagships, 0..) |vt, i| {
        s.ids[i] = try s.launcher.addDeferred(vt); // lazy: init happens on first show
    }
}

fn deinit(gpa: Allocator, s: *State) void {
    _ = gpa;
    s.launcher.deinit();
}

const zone_w: f32 = 42; // width of each tap zone (prev on the left, next on the right)

fn drawPill(
    f: *z.Frame,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    active: usize,
) void {
    const gl: *z.WgpuGl = f.gl;
    const white: Color = .{ .r = 235, .g = 235, .b = 245, .a = 255 };
    gl.rect(.{ .x = x, .y = y, .width = w, .height = h }, .{ .color = .{ .r = 24, .g = 26, .b = 34, .a = 225 } });

    const cy: f32 = y + h * 0.5;

    // ◂ prev chevron (apex left), left zone.
    gl.triangle(vec2(x + 18, cy - 7), vec2(x + 18, cy + 7), vec2(x + 8, cy), .{ .color = white });
    // ▸ next chevron (apex right), right zone.
    gl.triangle(vec2(x + w - 18, cy - 7), vec2(x + w - 18, cy + 7), vec2(x + w - 8, cy), .{ .color = white });

    // One dot per app between the chevrons; the active one is bright.
    const spacing: f32 = 11;
    const start_x: f32 = x + 44;
    var i: usize = 0;
    while (i < n_apps) : (i += 1) {
        const dx: f32 = start_x + spacing * float(i);
        const col: Color = if (i == active)
            white
        else
            .{ .r = 84, .g = 90, .b = 104, .a = 255 };
        gl.circle(.{ dx, cy }, 3, .{ .color = col, .segments = 12 });
    }
}

fn update(f: *z.Frame, s: *State) void {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();

    // Switch pill: ◂ [dot per app] ▸. Centered, raised above the bottom edge so
    // it clears bottom-corner content (insets, logs).
    const spacing: f32 = 11;
    const n_f: f32 = float(n_apps);
    const pill_w: f32 = 80 + spacing * (n_f - 1);
    const pill_h: f32 = 34;
    const px: f32 = (w - pill_w) * 0.5;
    const py: f32 = h - pill_h - 56;

    // Hit-test BEFORE ticking the child so a switch tap is consumed here and
    // can't reach the (incoming) app the same frame. Left zone = prev, right = next.
    const m: Vec2 = z.getMousePosition(f.input);
    const in_y: bool = m[1] >= py and m[1] <= py + pill_h;
    if (z.isMouseButtonPressed(f.input, .left) and in_y) {
        if (m[0] >= px and m[0] < px + zone_w) {
            s.active = (s.active + n_apps - 1) % n_apps;
            drawPill(f, px, py, pill_w, pill_h, s.active);
            return;
        }
        if (m[0] > px + pill_w - zone_w and m[0] <= px + pill_w) {
            s.active = (s.active + 1) % n_apps;
            drawPill(f, px, py, pill_w, pill_h, s.active);
            return;
        }
    }

    s.launcher.tickFullscreen(f, s.ids[s.active]);
    drawPill(f, px, py, pill_w, pill_h, s.active);
}

pub const app: z.AppSpec(State) = .{
    // Multi-example host: it drives dozens of hosted example lifecycles, so a
    // single leak-tight deinit isn't meaningful — opt out of the managed gate.
    .memory = .managed,
    .config = .{
        .window = .{
            .title = "zimr - launcher",
            .width = 480,
            .height = 320,
            .scale_mode = .responsive,
            // The 3D children (helmet, physics, plot3d, ...) need a depth
            // attachment; the launcher owns the frame, so its config governs.
            .depth_format = .depth24_plus,
            .clear = .{ .r = 10.0 / 255.0, .g = 12.0 / 255.0, .b = 18.0 / 255.0, .a = 1.0 },
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
