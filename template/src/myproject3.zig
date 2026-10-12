//! myproject3 - hello world, as a program that owns its `main`.
//!
//! myproject1 and myproject2 are descriptors: a `pub const app: z.AppSpec(State)` and nothing else. zimr's runner
//! is their program - it holds `main`, and opens and closes every frame around their `update`. This app is the
//! program itself (`.own_frame = true` on its row in build.zig), so three things that were the runner's are its own:
//!   - `main`: code that runs before the first frame, and natively after the window closes
//!   - the root module's declarations: `std_options` below, and a `panic` handler or exports if it wants them
//!   - each frame: `update` opens and closes it (`z.beginDrawing` / `z.endDrawing`)
//!
//! What it gives up: a descriptor can be hosted by another program - zimr's launcher runs many of them on one page,
//! each in its own viewport, and resets them - and a program cannot be. This template's gallery is only links to
//! each app's own page (public/index.html), so it lists this one like the others.
//!
//! Owning `main` is not owning the loop: the browser calls the page once per frame, so `zimr_app.run` returns once
//! the app is initialized, and natively `zimr_app.runNative` calls the frames until the window closes.
//!
//! Rename this file (and its row in build.zig + its card in public/index.html)
//! to whatever your project actually is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const colors = z.colors;

/// Routes `std.log` to the page's console panel (natively, to standard error). The root module decides where logs
/// go: for a descriptor the runner declares this, and here the root is this file.
pub const std_options = z.std_options;

/// The engine - GPU, window, input - that `run` starts. At file scope, where the browser's per-frame call reaches it.
pub var zimr_app: z.App = .{};

/// Wired by zimr's `Project`. zimr ships no default font: text needs one.
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const State = struct {
    font: z.Font,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 32);
    s.* = .{ .font = font };
}

fn update(f: *z.Frame, s: *State) void {
    // No runner opens the frame around this function: it opens and closes its own. beginDrawing clears to the
    // window's `.clear` color (see `main`).
    z.beginDrawing(f.gl);
    defer z.endDrawing(f.gl);

    // The canvas follows the browser window (`.responsive`), so read its size every frame.
    const width: f32 = f.window.widthf();
    const height: f32 = f.window.heightf();
    const center_x: f32 = width / 2;
    const center_y: f32 = height / 2;

    const half: f32 = @min(width, height) / 3;
    f.gl.rect(
        .{ .x = center_x - half, .y = center_y - half, .width = 2 * half, .height = 2 * half },
        .{ .color = colors.sky_400, .outline = 2 },
    );
    f.gl.text(
        .{ center_x - 90, center_y - 18 },
        "Hello, World!",
        .{ .size = 32, .color = colors.white, .font = &s.font },
    );

    const dim: Color = colors.slate_400;
    f.gl.text(
        .{ center_x - 110, center_y + 30 },
        "src/myproject3.zig owns main()",
        .{ .size = 14, .color = dim, .font = &s.font },
    );
    f.gl.textf(
        .{ 12, height - 28 },
        "frame {d}",
        .{f.time.frame_count},
        .{ .size = 14, .color = dim, .font = &s.font },
    );
}

/// The program's entry point. On the web, the page calls it once, when the wasm loads.
pub fn main() !void {
    std.log.info("myproject3: main() runs before the first frame", .{});

    try zimr_app.run(.{
        .window = .{
            .title = "myproject3 - owns its main",
            .width = 480,
            .height = 320,
            .scale_mode = .responsive,
            .clear = .{ .r = 0.12, .g = 0.12, .b = 0.16 },
        },
    }, State, initState, update);

    // On the web, `run` has returned with the app initialized, and the browser calls each frame from here on. A
    // native program calls them itself: `runNative` returns when the window is closed.
    if (comptime z.host.drives_own_frames) {
        zimr_app.runNative();
        std.log.info("myproject3: the window closed after {d} frames", .{zimr_app.frame_count});
    }
}
