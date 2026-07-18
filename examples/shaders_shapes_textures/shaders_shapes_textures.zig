//! examples/shaders_shapes_textures — a port of raylib's `shaders_shapes_textures`.
//!
//! THE POINT. raylib's `BeginShaderMode` wraps ORDINARY draws, and toggles in and out of the
//! shader SEVERAL TIMES within a single frame:
//!
//!     DrawCircle(...);                 // default shader
//!     BeginShaderMode(grayscale);
//!       DrawRectangle(...);            // <- filtered
//!     EndShaderMode();
//!     DrawTriangle(...);               // default again
//!     BeginShaderMode(grayscale);
//!       DrawTexture(fudesumi, ...);    // <- filtered
//!     EndShaderMode();
//!
//! Until now zimr could only run a shader over a FULLSCREEN QUAD (`effects2d`), which is a
//! post-process: render the scene to a texture, then filter the texture. That cannot express
//! the above at all, because it cannot filter SOME shapes and not others.
//!
//! `z.Shader2D` can. The user's fragment shader BECOMES the fragment stage of the shapes
//! pipeline, so the rectangles below are grey because THEIR OWN fragments went through it.
//! Nothing is rendered to a texture and nothing is read back.
//!
//! The repeated toggling is not decoration — it is the test. Each `beginShaderMode` /
//! `endShaderMode` must FLUSH the pending batch, or geometry queued before the swap would be
//! drawn with the pipeline bound after it, and the columns would bleed into one another.
//! Three toggles in one frame is what makes that visible rather than theoretical.
//!
//! IMPROVEMENTS ON THE ORIGINAL
//!   * The grey is a SLIDER, not a hard on/off. The shader `mix`es rather than branching, so a
//!     value parked at 0.5 proves the shader really is running per fragment, rather than
//!     swapping in a pre-greyed texture.
//!   * A UI panel replaces the keyboard, because this runs on a phone.
//!   * A "filter the whole frame" toggle wraps EVERYTHING in one shader mode — the other thing
//!     raylib's API allows and its example never shows.
//!
//! (c) Fudesumi sprite by Eiden Marsal — shipped with raylib's examples.
const std = @import("std");
const z = @import("zimr");
const zm = @import("zm");

const Color = zm.Color;
const c = Color;
const tau = zm.tau;
const Allocator = std.mem.Allocator;

/// The WGSL the build generated from `src/shaders/shapes_filter_fs.zig` — raylib's
/// `grayscale.fs`, written in Zig.
const filter_wgsl = @embedFile("shapes_filter_fs.wgsl");

const fudesumi_png = @embedFile("fudesumi.png");
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const State = struct {
    gpa: Allocator,

    /// The user 2D shader. Owns SIX GPU handles — pipeline, its layout, the group-2
    /// bind-group layout, the fragment module, the uniform buffer, the bind group — and frees
    /// all six in `deinit`. Creating a pipeline creates more than a pipeline, and an example
    /// that frees only the obvious one leaks the other five in silence.
    filter: z.Shader2D = .{},

    fudesumi: z.WgpuTexture = .{},

    /// 0 = untouched, 1 = fully grey.
    amount: f32 = 1.0,

    /// Wrap the ENTIRE frame in one shader mode instead of the three interleaved ones.
    filter_everything: bool = false,

    elapsed: f32 = 0,
    font: z.Font,
    ui_host: z.UiHost,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 18);

    const image: z.Image = try z.loadImageFromMemory(gpa, fudesumi_png);
    defer z.unloadImage(gpa, image);
    const fudesumi: z.WgpuTexture = z.loadTextureFromImage(f.gl, image);

    // Built against the RENDERER'S OWN bind-group layouts. That shared identity is not a
    // convenience: WebGPU keeps groups 0 (projection) and 1 (texture) bound across a pipeline
    // swap only when the two pipeline layouts agree on that prefix, and handing it the same
    // handles is the only way to be certain that they do.
    const filter: z.Shader2D = try z.Shader2D.init(
        gpa,
        f.gpu.device,
        f.gpu.queue,
        f.gl.renderer(),
        filter_wgsl,
        "grayscale",
    );

    s.* = .{
        .gpa = gpa,
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
        .fudesumi = fudesumi,
        .filter = filter,
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    // Six GPU handles in `filter`, and the texture. Creating a pipeline creates a layout, a
    // bind-group layout and a shader module as well — an example that frees only the obvious
    // one leaks the rest in silence, which is exactly what the smoke harness's leak census is
    // there to catch.
    s.filter.deinit();
    s.fudesumi.deinit();
    s.ui_host.deinit();
}

// ---- the three columns, laid out exactly as raylib does ---------------------------------

/// Column 1 (x = 80): circles. raylib leaves these on the DEFAULT shader.
fn drawCircles(gl: anytype) void {
    gl.circle(.{ 80, 120 }, 35, .{ .color = c.darkblue, .segments = 48 });
    gl.circleGradient(.{ 80, 220 }, 60, c.green, c.skyblue);
    gl.circleSectorLines(.{ 80, 340 }, 80, 0, tau, 36, .{ .color = c.darkblue });
}

/// Column 2 (x = 250): rectangles. raylib puts these INSIDE the shader.
fn drawRectangles(gl: anytype) void {
    gl.rect(.{ .x = 250 - 60, .y = 90, .width = 120, .height = 60 }, .{ .color = c.red });

    // raylib's `DrawRectangleGradientH` is a horizontal gradient; zimr's four-corner form says
    // the same thing as a left pair and a right pair.
    gl.rectGradientCorners(
        .{ .x = 250 - 90, .y = 170, .width = 180, .height = 130 },
        c.maroon, // top-left
        c.maroon, // bottom-left
        c.gold, // bottom-right
        c.gold, // top-right
    );

    gl.rect(
        .{ .x = 250 - 40, .y = 320, .width = 80, .height = 60 },
        .{ .color = c.orange, .outline = 1 },
    );
}

/// Column 3 (x = 430): triangles and a hexagon. DEFAULT shader again.
fn drawTriangles(gl: anytype) void {
    gl.triangle(.{ 430, 80 }, .{ 430 - 60, 150 }, .{ 430 + 60, 150 }, .{ .color = c.violet });
    gl.triangleLines(.{ 430, 160 }, .{ 430 - 20, 230 }, .{ 430 + 20, 230 }, .{ .color = c.darkblue });
    gl.poly(.{ 430, 320 }, 6, 80, 0, .{ .color = c.brown });
}

/// The sprite. raylib puts this INSIDE the shader, as a SECOND, separate shader mode — which
/// is what proves the mode can be re-entered rather than merely entered once.
fn drawSprite(gl: anytype, s: *State) void {
    const w: f32 = @floatFromInt(s.fudesumi.width);
    const h: f32 = @floatFromInt(s.fudesumi.height);
    gl.texture(
        .{ .x = 500, .y = -30, .width = w, .height = h },
        s.fudesumi,
        .{ .tint = c.white },
    );
}

fn drawLabels(gl: anytype) void {
    gl.text(.{ 20, 40 }, "USING DEFAULT SHADER", .{ .size = 14, .color = c.red });
    gl.text(.{ 190, 40 }, "USING CUSTOM SHADER", .{ .size = 14, .color = c.red });
    gl.text(.{ 370, 40 }, "USING DEFAULT SHADER", .{ .size = 14, .color = c.red });
    gl.text(
        .{ 380, 428 },
        "(c) Fudesumi sprite by Eiden Marsal",
        .{ .size = 11, .color = c.gray },
    );
}

fn update(f: *z.Frame, s: *State) void {
    s.elapsed += f.time.delta_time;
    z.clearViewport(f, c.raywhite);

    const gl = f.gl;
    s.filter.setParams(.{ .params = .{ s.amount, s.elapsed, 0, 0 } });

    if (s.filter_everything) {
        // One shader mode around the whole frame — everything, including the labels, goes grey.
        z.beginShaderMode(gl, s.filter);
        drawLabels(gl);
        drawCircles(gl);
        drawRectangles(gl);
        drawTriangles(gl);
        drawSprite(gl, s);
        z.endShaderMode(gl);
    } else {
        // raylib's exact interleaving: default, custom, default, custom.
        drawLabels(gl);
        drawCircles(gl);

        z.beginShaderMode(gl, s.filter);
        drawRectangles(gl);
        z.endShaderMode(gl);

        drawTriangles(gl);

        z.beginShaderMode(gl, s.filter);
        drawSprite(gl, s);
        z.endShaderMode(gl);
    }

    const u: z.ui_real.Ui = s.ui_host.begin(f);
    if (u.window("grayscale.fs", .{})) |win| {
        defer win.close();
        u.text("Middle column + sprite run the user shader.", .{});
        u.text("Circles and triangles do not.", .{});
        _ = u.slider("grey", &s.amount, .{ .min = 0, .max = 1 });
        _ = u.checkbox("filter the whole frame", &s.filter_everything);
    }
    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - shaders - shapes + textures (BeginShaderMode)",
            // raylib's 800x450 design space, kept exactly.
            .width = 800,
            .height = 450,
            // `.fit` because those coordinates are a FIXED design space. Under `.responsive`
            // the coordinate space is the ACTUAL device size (a phone is ~412 CSS px wide), so
            // every hardcoded column above would land off-screen.
            .scale_mode = .fit,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
