// examples/input_multitouch.zig - basic multi-touch visualisation:
// one circle per finger, labelled with its slot index.
// Port of raylib's `examples/core/core_input_multitouch.c` (*1,
// ~81 LOC).  Simplest demo of the touch API; on a phone, each
// finger gets its own coloured circle at the touch coordinate
// with a big number above it showing the touch slot index.
// On desktop without a touch device, the canvas stays blank
// except for the HUD line - that's expected (raylib's source
// does the same).
// **See also:** `examples/touch_paint.zig` is zimr's more
// complete touch demo - multi-touch finger painting with a
// distinct colour per touch ID and persistent trails.  Use
// `input_multitouch` for the minimum-viable visualiser, use
// `touch_paint` to see a touch ID get tracked across frames
// for an actual interaction loop.
// What this exercises:
//   - `z.getTouchPointCount` and `getTouchPosition(i)`,
//     the slot-indexed touch API.  Slots aren't stable across
//     gesture sessions - slot 0 is whichever finger came down
//     first this session - so the index labels reset every time
//     all fingers leave.  See `z.getTouchPointId` for the
//     stable per-finger ID if you need that.
//   - The (0, 0) sentinel: raylib's source skips drawing a
//     finger whose position is exactly (0, 0), since that's
//     the "no touch" placeholder in the slot.  We do the same.
// Controls:
//   Touch the screen (any number of fingers, up to 10)

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const Vec2 = zm.Vec2;

const screen_w: i32 = 800;
const screen_h: i32 = 450;
const max_touch_points: usize = 10;
const touch_radius: f32 = 34;
const label_offset_y: f32 = 70;

const c = Color;

const State = struct {
    font: z.Font,
    frame_count: usize = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 32);
    s.* = .{ .font = font };
}

fn update(f: *z.Frame, state: *State) void {
    state.frame_count += 1;

    // Clamp the engine-reported touch count to our display max.
    // Anything beyond max_touch_points just doesn't get drawn.
    const reported: i32 = z.getTouchPointCount(f.input);
    const t_count: usize = blk: {
        const r: usize = if (reported < 0) 0 else @intCast(reported);
        break :blk @min(r, max_touch_points);
    };

    // ---- Render ----------------------------------------------------------
    z.clearViewport(f, c.raywhite);

    var buf: [16]u8 = undefined;
    for (0..t_count) |i| {
        const idx_c: i32 = @intCast(i);
        const tp: Vec2 = z.getTouchPosition(f.input, idx_c);

        // Skip the (0, 0) "no touch" sentinel.  raylib's source
        // does the same exclusion; the actual API contract is
        // "0,0 means empty slot."
        if (tp[0] <= 0 or tp[1] <= 0) {
            continue;
        }

        const center: Vec2 = .{ tp[0], tp[1] };
        f.gl.circle(center, touch_radius, .{ .color = c.orange, .segments = 16 });

        const label: []const u8 = bufPrint(&buf, "{d}", .{i}) catch "?";
        const label_x: f32 = tp[0] - 10;
        const label_y: f32 = tp[1] - label_offset_y;
        f.gl.text(.{ label_x, label_y }, label, .{ .size = 40, .color = c.black, .font = &state.font });
    }

    f.gl.text(
        .{ 10, 10 },
        "touch the screen at multiple locations to get multiple balls",
        .{ .size = 20, .color = c.darkgray, .font = &state.font },
    );
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - input multitouch",
            .width = screen_w,
            .height = screen_h,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
