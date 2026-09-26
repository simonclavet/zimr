//! text_on_texture - port of the GL `text_on_texture`, on the new textured-3D
//! path. Each frame it renders a 2D "sign" (a coloured panel + text) into an
//! offscreen render texture via beginTextureMode/endTextureMode, then maps that
//! render texture onto a rotating 3D cube with drawCubeTexture - so the cube's
//! faces display live-rendered text. A grid + a couple of solid markers give the
//! scene depth. Combines two subsystems: render-to-texture (RenderTexture) and
//! the textured-3D pipeline.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Camera3D = zm.Camera3D;
const pi = zm.pi;
const pointVec = zm.pointVec;
const vec = zm.vec;

const common = @import("example_common");
const c = z.colors;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const rt_size: f32 = 256;

const State = struct {
    rt: z.RenderTexture = .{},
    font: z.Font,
    angle: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.rt.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 48) };
}

fn update(f: *z.Frame, s: *State) void {
    if (s.rt.color == .invalid) {
        s.rt = z.loadRenderTexture(f.gl, @trunc(rt_size), @trunc(rt_size));
    }
    s.angle += f.time.delta_time * 20.0;

    // 1. OFFSCREEN FIRST: render the "sign" into the texture BEFORE the screen
    // pass opens (tile-based-GPU safe; app owns its begin/endDrawing).
    z.beginTextureMode(f.gl, s.rt, .{ .r = 18, .g = 44, .b = 60, .a = 255 });
    f.gl.rect(
        .{ .x = 6, .y = 6, .width = rt_size - 12, .height = rt_size - 12 },
        .{ .color = c.sky_400, .outline = 1.0 },
    );
    f.gl.text(.{ 22, 64 }, "zimr", .{ .size = 92, .color = c.white, .font = &s.font });
    f.gl.text(.{ 40, 162 }, "WebGPU", .{ .size = 44, .color = c.sky_300, .font = &s.font });
    z.endTextureMode(f.gl);

    // 2. SCREEN PASS: open once, clear, map the texture onto a rotating cube.
    z.beginDrawing(f.gl);
    z.clearViewport(f, .{ .r = 10, .g = 12, .b = 18, .a = 255 });

    // Map the render texture onto a rotating 3D cube.
    const rad: f32 = s.angle * pi / 180.0;
    const cam: Camera3D = .{
        .position = pointVec(@cos(rad) * 6.0, 3.0, @sin(rad) * 6.0),
        .target = pointVec(0, 1, 0),
        .up = vec(0, 1, 0),
        .fovy_deg = 50,
        .projection = 0,
    };
    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 16, 1.0);
    z.drawCubeTexture(f.gl, s.rt.asTexture(), pointVec(0, 1, 0), 2.0, c.white);
    z.drawCube(f.gl, pointVec(3, 0.4, 0), .{ .size = vec(0.8, 0.8, 0.8), .color = c.slate_600 });
    z.drawCube(f.gl, pointVec(-3, 0.4, 0), .{ .size = vec(0.8, 0.8, 0.8), .color = c.slate_600 });
    z.endMode3D(f.gl);

    common.caption(f.gl, s.font, "text rendered into a RenderTexture, mapped onto a 3D cube via drawCubeTexture");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - text on texture",
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
