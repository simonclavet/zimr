// examples/ui_input_query_demo.zig
//
// Live diagnostic of zimr's Q1 input layer (turn 415 / 415b).
// Shows the current state of every key in `InputSnapshot.keys`,
// plus the mouse + modifier state, plus zimr's
// `wantCaptureKeyboard` / `wantCaptureMouse` flags.
//
// Doubles as both:
//   - reference doc for "how do I query input?" (`u.isKeyDown`,
//     `u.isKeyPressed`, `u.isKeyReleased`, `u.isShiftDown`, etc.)
//   - smoke test for the Q1 input migration (every key in the
//     `KeyCode` enum gets a live readout - if a key never lights
//     up under a key press, the snapshot population path is wrong)
//
// Phone-friendly: large readable font, single-screen scrollable
// list, no widgets requiring precise pointer input.  Open the
// standalone build on a phone, the on-screen keyboard's modifier
// keys should light up the corresponding rows.
//
// Build standalone:
//   python3 scripts/build_standalone.py ui_input_query_demo
//   open prebuilt/standalone/ui_input_query_demo.html on phone

const zm = @import("zm");
const Vec2 = zm.Vec2;
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const ui = z.ui_real;

const State = struct {
    ui_host: z.UiHost = undefined,
    font: z.Font = undefined,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
}

fn boolStr(b: bool) []const u8 {
    return if (b) "T" else "F";
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, .{ .r = 18, .g = 22, .b = 32, .a = 255 });

    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("Input Query", .{ .initial_size = .{ 380, 800 } })) |w| {
        defer w.close();

        u.text("zimr capture flags:", .{});
        u.text("  wantCaptureKeyboard = {s}", .{boolStr(u.wantCaptureKeyboard())});
        u.text("  wantCaptureMouse    = {s}", .{boolStr(u.wantCaptureMouse())});
        u.spacing();
        u.separator();
        u.spacing();

        const m: Vec2 = s.ui_host.ctx.input.mouse_pos;
        u.text("mouse pos = ({d:.0}, {d:.0})", .{ m[0], m[1] });
        const ld: bool = s.ui_host.ctx.input.mouse_left_down;
        const lc: bool = s.ui_host.ctx.input.mouse_left_clicked;
        const lr: bool = s.ui_host.ctx.input.mouse_left_released;
        u.text("  L: down={s} click={s} release={s}", .{
            boolStr(ld), boolStr(lc), boolStr(lr),
        });
        u.text("  M click={s}  R click={s}", .{
            boolStr(s.ui_host.ctx.input.mouse_middle_clicked),
            boolStr(s.ui_host.ctx.input.mouse_right_clicked),
        });
        u.text("  wheel = ({d:.1}, {d:.1})", .{
            s.ui_host.ctx.input.mouse_wheel_x,
            s.ui_host.ctx.input.mouse_wheel_y,
        });
        u.spacing();
        u.separator();
        u.spacing();

        u.text("modifiers (Ui.isShiftDown / isCtrlDown / etc):", .{});
        u.text("  shift={s}  ctrl={s}  alt={s}  super={s}", .{
            boolStr(u.isShiftDown()),
            boolStr(u.isCtrlDown()),
            boolStr(u.isAltDown()),
            boolStr(u.isSuperDown()),
        });
        u.spacing();
        u.separator();
        u.spacing();

        u.text("active keys (down / pressed / released):", .{});
        var any_active: bool = false;
        inline for (std.enums.values(ui.KeyCode)) |kc| {
            if (kc == .MAX) {
                continue;
            }
            const ks: ui.KeyState = s.ui_host.ctx.input.keys[@backingInt(kc)];
            if (ks.down or ks.pressed_this_frame or ks.released_this_frame) {
                u.text("  {s:<14} D={s} P={s} R={s} dur={d}", .{
                    @tagName(kc),
                    boolStr(ks.down),
                    boolStr(ks.pressed_this_frame),
                    boolStr(ks.released_this_frame),
                    ks.down_duration_frames,
                });
                any_active = true;
            }
        }
        if (!any_active) {
            u.text("  (press any key to see state)", .{});
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - input query",
            .width = 400,
            .height = 880,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
