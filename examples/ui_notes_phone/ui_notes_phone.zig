// examples/ui_notes_phone.zig — Q8 auto-save scratchpad.
//
// The phone-focused demo for turn 442b.  Wires together three
// pieces that landed across turns 423, 441b, and 442:
//
//   1. The `inputTextMultiline` widget with the DOM `<textarea>`
//      overlay (turn 441b — so the soft keyboard actually pops on
//      mobile and the user can write more than a few words).
//   2. The `edit` callback on InputTextOpts (turn 442 — the only
//      callback that fires reliably on web; great for "saved!"
//      indicators).
//   3. Q8 persistent state via `getOrPutState(T, id, .{.persist =
//      true})` (turn 423 — typed comptime-generated serialize/
//      deserialize for plain-data structs).
//
// The interaction: open the page on a phone (or any browser),
// type some notes into the field.  Each keystroke bumps a "Saved
// at frame N" counter via the edit callback.  Close the tab.
// Reopen the page.  Your notes are still there.
//
// What makes this a useful demo (vs the input-flags zoo):
//   - The zoo proves every flag works in isolation.
//   - This example proves the *combination* of (textarea overlay
//     + edit callback + Q8 persistence) composes into something a
//     user would actually use.  Composition is where bugs hide.
//
// Build standalone:
//   zig build install -Dfocus=ui_notes_phone
//   python3 scripts/build_standalone.py ui_notes_phone

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;
const ui = z.ui_real;

/// State that LIVES IN Q8.  Q8's serializer walks this struct at
/// app exit (writes to localStorage on web, to a file on host)
/// and reconstitutes it on next startup.  Has to be plain-data
/// (no pointers, no slices — just fixed-size primitives + arrays).
///
/// `buf` is 512 bytes which is enough for a few paragraphs of
/// notes; bigger if the demo grows.  `len` is usize because that's
/// what `inputTextMultiline` expects — Q8 handles platform-dependent
/// widths (wasm32: 4 bytes; host: 8 bytes) via the same compile-
/// time codepath that generated the (de)serializer.
const NotesData = struct {
    buf: [512]u8 = @splat(0),
    len: usize = 0,
    /// Frame number at which the most recent edit happened.  Used
    /// to show "saved Xs ago" in the UI.  u32 wraps every ~2
    /// years at 60fps, fine for a scratchpad.
    last_edit_frame: u32 = 0,
    /// Monotonic count of how many edit-events fired.  Visible in
    /// the readout so the user can see the callback is actually
    /// firing on every keystroke.
    edit_count: u32 = 0,
};

/// Stable Id for the persistent notes state.  Any arbitrary u32
/// works; just needs to be the same across app launches.  Picked
/// the bytes of "NOTE" mapped through "0x" so it's obvious in a
/// Q8 dump.
const notes_state_id: ui.Id = 0x4E4F_5445;

/// Sidecar passed as `user_data` to the edit callback.  Holds a
/// pointer to the Q8-resident NotesData PLUS the current frame
/// number (which Q8 can't know — it changes every frame).  The
/// callback uses both: writes to NotesData via the pointer,
/// reads the current frame via the value.
const EditCbCtx = struct {
    notes: *NotesData,
    frame: u32,
};

fn notesEditCb(d: *ui.InputTextCallbackData) void {
    const cb: *EditCbCtx = @ptrCast(@alignCast(d.user_data.?));
    cb.notes.last_edit_frame = cb.frame;
    cb.notes.edit_count +%= 1;
}

/// Non-persistent app state.  UI context, font cache, shapes
/// texture — none of this needs to survive across launches.  The
/// PERSISTENT bits live in NotesData (above), reached via Q8.
const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    frame: u32 = 0,
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

    s.frame +%= 1;

    const fw: f32 = float(f.window.screen_width);
    const fh: f32 = float(f.window.screen_height);
    u.setNextWindowPos(.{ 0, 0 }, .{});
    u.setNextWindowSize(.{ fw, fh }, .{});
    if (u.window("notes", .{
        .flags = .{
            .no_title_bar = true,
            .no_resize = true,
            .no_move = true,
            .no_collapse = true,
        },
    })) |w| {
        defer w.close();

        u.textColored(Color.hex(0xFFFFFFFF), "notes scratchpad", .{});
        u.textColored(Color.hex(0x909090FF), "type into the field.  every keystroke auto-saves.", .{});
        u.textColored(Color.hex(0x909090FF), "close + reopen the tab to verify persistence.", .{});
        u.spacing();

        // Resolve the Q8-persisted notes state.  First call after a
        // fresh page load returns `found_existing = false`; if there
        // was a prior session, Q8 has already deserialized the value
        // back into the slot, so `found_existing` will be true and
        // `value_ptr.*` holds the previous contents.
        const r = u.getOrPutState(NotesData, notes_state_id, .{ .persist = true });
        if (!r.found_existing) {
            r.value_ptr.* = .{};
        }
        const notes: *NotesData = r.value_ptr;

        // Sidecar lives in stack frame for THIS update call.  Safe
        // because the callback only fires SYNCHRONOUSLY inside the
        // upcoming inputTextMultiline call — `&cb_ctx` doesn't
        // escape.
        var cb_ctx = EditCbCtx{ .notes = notes, .frame = s.frame };
        _ = u.inputTextMultiline("notes-field", &notes.buf, &notes.len, .{ 380, 240 }, .{
            .edit = notesEditCb,
            .user_data = &cb_ctx,
        });
        u.spacing();

        // Live save indicator.  `edit_count` increments per
        // keystroke; `last_edit_frame` captures when.  "frames ago"
        // gives a sense of recency without needing to fetch wall-
        // clock time.
        const frames_ago: u32 = s.frame -% notes.last_edit_frame;
        if (notes.edit_count == 0) {
            u.textColored(Color.hex(0x808080FF), "no edits yet", .{});
        } else {
            u.textColored(Color.hex(0x60FFB0FF), "saved {d} frames ago  (edit #{d})", .{
                frames_ago, notes.edit_count,
            });
        }
        u.spacing();
        u.separator();
        u.textColored(Color.hex(0x909090FF), "buf len: {d} / {d} bytes", .{ notes.len, notes.buf.len });
        u.textColored(Color.hex(0x909090FF), "Q8 will serialize this on app exit.", .{});
        u.textColored(Color.hex(0x909090FF), "On web that's localStorage; on host a file.", .{});
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - notes scratchpad (Q8)",
            .width = 420,
            .height = 720,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
