// examples/hello_world_owned_main/hello_world_owned_main.zig - hello_world with its own `main`.
//
// Draws examples/hello_world's text and squares (without its mouse circle and slider, to stay small). The
// difference is who runs it:
//
//   * hello_world is a DESCRIPTOR: it exports `pub const app: z.AppSpec(State)` and nothing else. zimr's runner
//     (src/wgpu_runner.zig) is the program's root - it owns `main`, the `z.App`, `std_options`, and each frame's
//     beginDrawing/endDrawing - and a launcher can tick the same descriptor into a part of its screen.
//
//   * this one OWNS ITS MAIN. Registered with `.own_frame = true` in build.zig, the file itself is the program's
//     root, on the web and natively, so it declares what the runner would have: the `z.App`, `std_options` so logs
//     reach the page or standard error, and `main`, which hands init and update to `App.run` (which records the app
//     as the engine's `active_app`). It opens and closes each frame itself. No launcher can host it: there is no
//     descriptor to hand one, and a program has one root.
//
// Use this shape when an example needs to do something before or after the engine runs, or drive its frames by
// hand (the 3D demos - cube_demo, lambert_demo - do the latter). Otherwise write a descriptor like hello_world.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const float = zm.float;

/// The program's root routes `std.log` - the runner's job for a descriptor, this file's here.
pub const std_options: std.Options = z.std_options;

/// The one app of the program: a global, so its address never changes. `App.run` records it as the engine's
/// `active_app`, and the engine keeps pointers into it. Named `zimr_app`, the one module-level `var` zimrlint allows.
pub var zimr_app: z.App = .{};

const State = struct {
    font: z.Font,
};

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 32);
    s.* = .{ .font = font };
}

fn update(f: *z.Frame, s: *State) void {
    // The frame is ours to open and close: the runner does this for a descriptor.
    z.beginDrawing(f.gl);
    defer z.endDrawing(f.gl);

    z.clearViewport(f, .{ .r = 30, .g = 30, .b = 40, .a = 255 });

    const sw: f32 = f.window.widthf();
    const sh: f32 = f.window.heightf();
    const cx: f32 = sw / 2;
    const cy: f32 = sh / 2;

    const white: Color = .{ .r = 240, .g = 240, .b = 240, .a = 255 };
    const dim: Color = .{ .r = 140, .g = 140, .b = 150, .a = 255 };
    const accent: Color = .{ .r = 96, .g = 165, .b = 250, .a = 255 };

    // Concentric squares centred in the canvas, sized by its smaller side.
    const min_dim: f32 = @min(sw, sh);
    var i: i32 = 1;
    while (i <= 4) : (i += 1) {
        const half: f32 = min_dim * float(i) / 12.0;
        f.gl.rect(
            .{ .x = cx - half, .y = cy - half, .width = 2 * half, .height = 2 * half },
            .{ .color = accent, .outline = 2 },
        );
    }

    f.gl.text(.{ cx - 90, cy - 18 }, "Hello, World!", .{ .size = 32, .color = white, .font = &s.font });

    f.gl.textf(
        .{ cx - 110, cy + 30 },
        "viewport: {d} x {d} CSS px",
        .{ sw, sh },
        .{ .size = 14, .color = dim, .font = &s.font },
    );

    f.gl.text(
        .{ 16, sh - 24 },
        "this example owns its main",
        .{ .size = 12, .color = dim, .font = &s.font },
    );
}

pub fn main() !void {
    try zimr_app.run(.{
        .window = .{
            .title = "zimr - hello_world_owned_main",
            .width = 480,
            .height = 200,
            .scale_mode = .responsive,
        },
    }, State, initState, update);
    // On the web `run` returns at once and the browser calls each frame through the `update` export. A native
    // program calls its frames itself, here, until its window closes.
    zimr_app.runNative();
}
