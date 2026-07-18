// examples/ui_custom_widget.zig
//
// Reference implementation of a CUSTOM WIDGET built on the public
// `beginItem` / `endItem` extension primitives plus the typed-
// generic ext-state storage (`getState` / `getOrPutState`).  No
// internals reached — everything imports through `z.ui`.
//
// The widget: `starRating(label, value: *u8, max_stars)`.  Renders
// a row of star glyphs; clicking the Nth star sets value to N.
// Hover highlights stars up to the cursor.  A future animated grow
// on the hovered star would use `u.animated`.
//
// This is the file extension authors should look at when they
// want to know "how do I write a custom widget for zimr."  It's
// SHORT because the primitives do the boilerplate.
//
// Build standalone:
//   zig build install -Dfocus=ui_custom_widget
//   python3 scripts/build_standalone.py ui_custom_widget

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;
const ui = z.ui_real;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    rating_food: u8 = 3,
    rating_service: u8 = 0,
    rating_ambience: u8 = 5,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 28);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
}

/// Per-widget hover state.  Stored in Q2 by widget id — multiple
/// `starRating` instances each get their own slot.
const StarRatingState = struct {
    hover_index: i32 = -1, // -1 = not hovered; else index in 0..max-1
};

/// Custom widget built on widget primitives + ext-state storage.
///
/// Pattern (the whole point of this file):
///   1. Compute size from caller args.
///   2. `u.beginItem(label, .{.size = ...})` — does ID hashing,
///      cursor placement, clip test, hovered_id update, AND the
///      press/release state machine in one call.
///   3. Read/write per-id state via `u.getOrPutState`.
///   4. Draw based on `it.hovered`, `it.held`, `it.rect`.
///   5. Return whether the value changed.
///   6. `defer u.endItem(it)` advances the cursor.
///
/// Returns true if the user clicked a star this frame.
fn starRating(
    u: ui.Ui,
    label: []const u8,
    value: *u8,
    max_stars: u8,
) bool {
    const STAR_SIZE: f32 = 28;
    const STAR_SPACING: f32 = 2;
    const row_width: f32 = float(max_stars) * (STAR_SIZE + STAR_SPACING) - STAR_SPACING;

    const it: ui.Ui.ItemCtx = u.beginItem(label, .{
        .size = .{ row_width, STAR_SIZE },
    }) orelse return false;
    defer u.endItem(it);

    const r = u.getOrPutState(StarRatingState, it.id, .{});
    if (!r.found_existing) {
        r.value_ptr.* = .{};
    }
    const state: *StarRatingState = r.value_ptr;

    // Compute which star the mouse is over (if any).  Using
    // it.rect to keep coords consistent with what itemAdd
    // registered.
    var hover_idx: i32 = -1;
    if (it.hovered) {
        const local_x: f32 = u.ctx.input.mouse_pos[0] - it.rect.x;
        const star_pitch: f32 = STAR_SIZE + STAR_SPACING;
        const idx: i32 = @floor(local_x / star_pitch);
        if (idx >= 0 and idx < @as(i32, @intCast(max_stars))) {
            hover_idx = idx;
        }
    }
    state.hover_index = hover_idx;

    // Click → set value to hovered star (1-indexed for human-
    // readable "3 out of 5 stars" semantics).
    var changed: bool = false;
    if (it.pressed and hover_idx >= 0) {
        value.* = @intCast(hover_idx + 1);
        changed = true;
    }

    // Draw each star into the window's draw list — clipped to the
    // window content rect, so stars never spill past the edge.
    // (getWindowDrawList exposes the same list built-in widgets use.)
    const dl: ui.DrawListHandle = u.getWindowDrawList();
    const filled_cutoff: i32 = @max(@as(i32, value.*), hover_idx + 1);
    var i: u8 = 0;
    while (i < max_stars) : (i += 1) {
        const star_rect: z.Rectangle = .{
            .x = it.rect.x + float(i) * (STAR_SIZE + STAR_SPACING),
            .y = it.rect.y,
            .width = STAR_SIZE,
            .height = STAR_SIZE,
        };
        const is_filled: bool = @as(i32, i) < filled_cutoff;
        const color: Color = if (is_filled)
            .{ .r = 0xFF, .g = 0xD7, .b = 0x00, .a = 0xFF } // gold
        else
            .{ .r = 0x44, .g = 0x44, .b = 0x4A, .a = 0xFF }; // dim
        // Simple square stand-in for a star — keep this example
        // about the widget pattern, not glyph rendering.  Real
        // implementations would u.text("★", ...) at the right pos.
        dl.addRectFilled(star_rect, color);
    }

    return changed;
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, .{ .r = 16, .g = 18, .b = 26, .a = 255 });

    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("Restaurant review", .{
        .initial_pos = .{ 20, 20 },
        .initial_size = .{ 440, 320 },
    })) |w| {
        defer w.close();

        u.text("Rate each axis:", .{});
        u.spacing();

        u.text("Food:", .{});
        u.sameLine(.{});
        _ = starRating(u, "food", &s.rating_food, 5);

        u.text("Service:", .{});
        u.sameLine(.{});
        _ = starRating(u, "service", &s.rating_service, 5);

        u.text("Ambience:", .{});
        u.sameLine(.{});
        _ = starRating(u, "ambience", &s.rating_ambience, 5);

        u.spacing();
        u.separator();
        u.spacing();
        u.text("Stored: food={d}/5 service={d}/5 ambience={d}/5", .{
            s.rating_food, s.rating_service, s.rating_ambience,
        });
    }
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - custom widget reference",
            .width = 480,
            .height = 360,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
