// examples/ui_widgets_data_types.zig - Phase 0b multi-component
// widgets showcase.
// Mirrors the "Widgets/Data Types" section of imgui's demo.  Shows
// every (slider | drag | input) x (Float | Int) x (1 | 2 | 3 | 4)
// variant collapsed to the generic `anytype` surface:
//     ui.slider("vec3", &my_vec3, .{ .min = 0, .max = 1 });
//     ui.drag(  "vec2", &my_vec2, .{ .speed = 0.5 });
//     ui.input( "vec4", &my_vec4, .{});
// One function name per widget family - the type-and-count is
// inferred from `*[N]T`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const pi = zm.pi;
const ui = z.ui_real;

const screen_w: i32 = 900;
const screen_h: i32 = 720;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,

    // Slider playground.
    slider_f1: f32 = 0.5,
    slider_f2: [2]f32 = .{ 0.2, 0.8 },
    slider_f3: [3]f32 = .{ 0.25, 0.5, 0.75 },
    slider_f4: [4]f32 = .{ 0.1, 0.3, 0.6, 0.9 },
    slider_i1: i32 = 50,
    slider_i2: [2]i32 = .{ 10, 90 },
    slider_i3: [3]i32 = .{ 5, 50, 95 },
    slider_i4: [4]i32 = .{ 25, 50, 75, 100 },

    // Drag playground.
    drag_f1: f32 = 1.5,
    drag_f3: [3]f32 = .{ 0.0, 0.0, 0.0 }, // a 3D position
    drag_i2: [2]i32 = .{ 800, 600 }, // a window size

    // Input playground.
    input_f1: f32 = pi,
    input_f4: [4]f32 = .{ 1, 0, 0, 1 }, // an RGBA color triplet
    input_i3: [3]i32 = .{ 1920, 1080, 60 }, // resolution + fps

    // Section toggles (collapsing headers).
    sliders_open: bool = true,
    drags_open: bool = true,
    inputs_open: bool = true,
    buttons_open: bool = true,

    // Demo state for buttons section.
    counter: i32 = 0,
    arrow_dir_pick: i32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
}

fn update(f: *z.Frame, s: *State) void {
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("Widgets / data types", .{
        .initial_pos = .{ 20, 20 },
        .initial_size = .{ 860, 680 },
    })) |w| {
        defer w.close();

        u.text("Each widget family is one generic fn; type + count come from *[N]T.", .{});
        u.separator();

        if (u.collapsingHeader("Sliders - slider(...)", &s.sliders_open)) {
            u.text("Float - slider(*f32) → slider(*[2]f32) → slider(*[3]f32) → slider(*[4]f32)", .{});
            _ = u.slider("f32", &s.slider_f1, .{ .min = 0, .max = 1 });
            _ = u.slider("[2]f32", &s.slider_f2, .{ .min = 0, .max = 1 });
            _ = u.slider("[3]f32", &s.slider_f3, .{ .min = 0, .max = 1 });
            _ = u.slider("[4]f32", &s.slider_f4, .{ .min = 0, .max = 1 });
            u.separator();
            u.text("Int - same fn, integer pointer instead", .{});
            _ = u.slider("i32", &s.slider_i1, .{ .min = 0, .max = 100, .fmt = "{d}" });
            _ = u.slider("[2]i32", &s.slider_i2, .{ .min = 0, .max = 100, .fmt = "{d}" });
            _ = u.slider("[3]i32", &s.slider_i3, .{ .min = 0, .max = 100, .fmt = "{d}" });
            _ = u.slider("[4]i32", &s.slider_i4, .{ .min = 0, .max = 100, .fmt = "{d}" });
        }

        if (u.collapsingHeader("Drags - drag(...)", &s.drags_open)) {
            u.text("Unbounded edit by horizontal mouse-drag; speed = pixels-per-unit.", .{});
            _ = u.drag("scalar", &s.drag_f1, .{ .speed = 0.01 });
            _ = u.drag("position xyz", &s.drag_f3, .{ .speed = 0.1, .fmt = "{d:.2}" });
            _ = u.drag("window size", &s.drag_i2, .{ .speed = 1, .fmt = "{d}" });
        }

        if (u.collapsingHeader("Inputs - input(...)", &s.inputs_open)) {
            u.text("Click a box to type; press Enter to commit, Esc to cancel.", .{});
            _ = u.input("scalar", &s.input_f1, .{});
            _ = u.input("color rgba", &s.input_f4, .{});
            _ = u.input("res + fps", &s.input_i3, .{});
        }

        if (u.collapsingHeader("Buttons - arrow + small + collapsing", &s.buttons_open)) {
            // Arrow buttons - small directional buttons.
            u.text("Arrow buttons:", .{});
            if (u.arrowButton("a_up", .up)) {
                s.counter += 1;
            }
            u.sameLine(.{});
            if (u.arrowButton("a_down", .down)) {
                s.counter -= 1;
            }
            u.sameLine(.{});
            if (u.arrowButton("a_left", .left)) {
                s.counter -= 10;
            }
            u.sameLine(.{});
            if (u.arrowButton("a_right", .right)) {
                s.counter += 10;
            }
            u.sameLine(.{});
            u.text("counter = {d}", .{s.counter});

            u.separator();
            u.text("Small buttons:", .{});
            if (u.smallButton("Reset")) {
                s.counter = 0;
            }
            u.sameLine(.{});
            if (u.smallButton("+100")) {
                s.counter += 100;
            }
            u.sameLine(.{});
            if (u.smallButton("-100")) {
                s.counter -= 100;
            }
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - UI widgets / data types",
            .width = screen_w,
            .height = screen_h,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
