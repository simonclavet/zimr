// examples/ui_multiselect_finder.zig demo for the imgui-parity arc.
// Finder-style file list (50 items) demonstrating the MultiSelect
// API.  Built in parallel with the API across turns 303-305:
//   - Turn 303: types + SelectionBasicStorage land; demo used the
//     "manual click-toggle" placeholder pattern.
//   - Turn 304: real Begin/End + Selectable hooks.  Click emits
//     SetAll-clear + SetRange(item..item, true); Ctrl-click emits
//     SetRange(item..item, toggle); Shift-click emits SetAll-clear
//     + SetRange(anchor..item, true).  Escape clears when
//     `clear_on_escape` is set.  ClearOnClickVoid wired.
//   - Turn 305 (current): phone-friendly tap-mode segmented
//     control.  Phones have no Ctrl/Shift, so the demo synthesizes
//     them by flipping the InputSnapshot's modifier bits before
//     calling beginMultiSelect (and restoring right after Begin
//     captures them onto the scope).  Three modes:
//       - Replace: plain tap, default; tap one row replaces sel.
//       - Toggle: tap-as-Ctrl-click; each tap adds/removes from sel.
//       - Range: tap-as-Shift-click; first tap sets anchor, second
//         tap extends range.
// The data model is a static array of file entries: name + size + type
// (file/folder).  No real filesystem - this is a UI demo.  Layout
// matches macOS Finder column view: name on left, type icon, size
// on right.
// Why MultiSelect matters: the standard "click=replace, Ctrl=add,
// Shift=range" idiom is what every file manager and IDE list does.
// Implementing it manually means tracking the anchor item across
// frames, handling clipper interactions, dealing with Escape +
// Ctrl-A keyboard.  The imgui API absorbs this complexity into a
// request-list protocol you apply against your storage.  See
// `src/notes/multiselect-tutorial.md` for the full walkthrough.

const std = @import("std");
const zm = @import("zm");
const assertUnreachable = zm.assertUnreachable;
const float64 = zm.float64;
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const ui = z.ui_real;

// ----- The file list (static)
const FileKind = enum { folder, document, image, archive, code };

const FileItem = struct {
    name: []const u8,
    kind: FileKind,
    size_bytes: u64,
};

// 50 synthetic items.  Mix of kinds + a few "folders" at the top to
// match Finder's typical layout (folders first).  Sizes chosen to
// span the natural formatting transitions (B -> KB -> MB -> GB).
const files = [_]FileItem{
    .{ .name = "Projects", .kind = .folder, .size_bytes = 0 },
    .{ .name = "Downloads", .kind = .folder, .size_bytes = 0 },
    .{ .name = "Documents", .kind = .folder, .size_bytes = 0 },
    .{ .name = "Pictures", .kind = .folder, .size_bytes = 0 },
    .{ .name = "Music", .kind = .folder, .size_bytes = 0 },
    .{ .name = "annual_report.pdf", .kind = .document, .size_bytes = 2_400_000 },
    .{ .name = "budget_2026.xlsx", .kind = .document, .size_bytes = 184_000 },
    .{ .name = "draft_proposal.docx", .kind = .document, .size_bytes = 92_000 },
    .{ .name = "meeting_notes.md", .kind = .document, .size_bytes = 14_500 },
    .{ .name = "todo.txt", .kind = .document, .size_bytes = 1_240 },
    .{ .name = "vacation_photos.zip", .kind = .archive, .size_bytes = 1_840_000_000 },
    .{ .name = "backup_2025_q4.tar.gz", .kind = .archive, .size_bytes = 12_400_000_000 },
    .{ .name = "logs_old.gz", .kind = .archive, .size_bytes = 47_000_000 },
    .{ .name = "screenshot_landscape.png", .kind = .image, .size_bytes = 2_800_000 },
    .{ .name = "screenshot_portrait.png", .kind = .image, .size_bytes = 3_100_000 },
    .{ .name = "icon_set_v2.svg", .kind = .image, .size_bytes = 92_000 },
    .{ .name = "profile_photo.jpg", .kind = .image, .size_bytes = 450_000 },
    .{ .name = "wallpaper_4k.heic", .kind = .image, .size_bytes = 8_400_000 },
    .{ .name = "main.zig", .kind = .code, .size_bytes = 18_400 },
    .{ .name = "build.zig", .kind = .code, .size_bytes = 4_200 },
    .{ .name = "ui.zig", .kind = .code, .size_bytes = 720_000 },
    .{ .name = "config.json", .kind = .code, .size_bytes = 3_400 },
    .{ .name = "package-lock.json", .kind = .code, .size_bytes = 142_000 },
    .{ .name = "README.md", .kind = .document, .size_bytes = 8_400 },
    .{ .name = "LICENSE.txt", .kind = .document, .size_bytes = 1_080 },
    .{ .name = "Cargo.toml", .kind = .code, .size_bytes = 980 },
    .{ .name = "tsconfig.json", .kind = .code, .size_bytes = 1_240 },
    .{ .name = "fixture_data.bin", .kind = .archive, .size_bytes = 84_000_000 },
    .{ .name = "test_results.xml", .kind = .document, .size_bytes = 24_000 },
    .{ .name = "coverage_report.html", .kind = .document, .size_bytes = 380_000 },
    .{ .name = "old_pitch_deck.pptx", .kind = .document, .size_bytes = 18_400_000 },
    .{ .name = "interview_recording.mp3", .kind = .archive, .size_bytes = 24_000_000 },
    .{ .name = "demo_clip.mp4", .kind = .archive, .size_bytes = 184_000_000 },
    .{ .name = "podcast_ep_42.flac", .kind = .archive, .size_bytes = 92_000_000 },
    .{ .name = "favicon.ico", .kind = .image, .size_bytes = 4_200 },
    .{ .name = "diagram_v3.png", .kind = .image, .size_bytes = 184_000 },
    .{ .name = "sketch_notes.heif", .kind = .image, .size_bytes = 740_000 },
    .{ .name = "raw_telemetry.csv", .kind = .document, .size_bytes = 4_800_000 },
    .{ .name = "compressed_logs.lz4", .kind = .archive, .size_bytes = 18_000_000 },
    .{ .name = "lib.rs", .kind = .code, .size_bytes = 8_400 },
    .{ .name = "Dockerfile", .kind = .code, .size_bytes = 1_200 },
    .{ .name = "docker-compose.yml", .kind = .code, .size_bytes = 2_400 },
    .{ .name = "schema.sql", .kind = .code, .size_bytes = 12_400 },
    .{ .name = "migration_001.sql", .kind = .code, .size_bytes = 3_400 },
    .{ .name = "secret_keys.env", .kind = .document, .size_bytes = 240 },
    .{ .name = "private_diary.md", .kind = .document, .size_bytes = 84_000 },
    .{ .name = "Drafts", .kind = .folder, .size_bytes = 0 },
    .{ .name = "Archive_Old", .kind = .folder, .size_bytes = 0 },
    .{ .name = "shared_with_team.url", .kind = .document, .size_bytes = 240 },
    .{ .name = "untitled.txt", .kind = .document, .size_bytes = 0 },
};

// ----- State
const TapMode = enum { replace, toggle, range };

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    /// Allocator owned by the user, threaded explicitly through
    /// every storage call below.  Captured in `initState`.  By
    /// keeping the gpa here (and not reaching into `ui_ctx.gpa` at
    /// the call site), the user can swap in a no-alloc-after-init
    /// allocator to PROVE the update path doesn't allocate.  See
    /// claude.md "Allocator lives on user State" for the rationale.
    gpa: Allocator,
    /// Multi-select state - the persistent backing storage.
    selection: ui.SelectionBasicStorage = .{},
    /// Phone tap-mode affordance.  Phones have no Ctrl/Shift, so the
    /// canonical multi-select modifiers aren't reachable via touch.
    /// This 3-state toggle synthesizes them: in `.toggle` mode the
    /// demo flips `key_ctrl_down` on the input snapshot before
    /// calling beginMultiSelect (so taps emit Ctrl-click requests),
    /// and in `.range` mode it flips `key_shift_down`.  Restored
    /// immediately after Begin captures them onto the scope.
    tap_mode: TapMode = .replace,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{
        .ui_host = z.UiHost.init(gpa, font),
        .font = font,
        .gpa = gpa,
    };

    // Phone readability - same recipe as ui_log_viewer.
}

// ----- Helpers
fn kindGlyph(k: FileKind) []const u8 {
    return switch (k) {
        .folder => "[d]",
        .document => "[f]",
        .image => "[i]",
        .archive => "[z]",
        .code => "[c]",
    };
}

fn formatSize(buf: []u8, bytes: u64) []const u8 {
    if (bytes == 0) {
        return "-";
    }
    const kb: f64 = float64(bytes) / 1024.0;
    if (kb < 1.0) {
        return bufPrint(buf, "{d} B", .{bytes}) catch "?";
    } else if (kb < 1024.0) {
        return bufPrint(buf, "{d:.1} KB", .{kb}) catch "?";
    } else if (kb < 1024.0 * 1024.0) {
        const mb: f64 = kb / 1024.0;
        return bufPrint(buf, "{d:.1} MB", .{mb}) catch "?";
    } else {
        const gb: f64 = kb / (1024.0 * 1024.0);
        return bufPrint(buf, "{d:.1} GB", .{gb}) catch "?";
    }
}

// ----- Frame
fn update(f: *z.Frame, s: *State) void {
    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    if (u.window("Files", .{
        .initial_pos = .{ 8, 8 },
        .initial_size = .{ 380, 840 },
    })) |w| {
        defer w.close();

        u.text("multi-select finder demo", .{});
        u.textDisabled(
            "Desktop: tap/Ctrl-tap/Shift-tap/Esc.  Phone: tap-mode buttons below.",
            .{},
        );

        // ---- Selection HUD ------------------------------------
        u.separatorText("Selection");
        var hud_buf: [64]u8 = undefined;
        const hud_text: []const u8 = bufPrint(
            &hud_buf,
            "selected: {d} / {d}",
            .{ s.selection.size(), files.len },
        ) catch "?";
        u.text("{s}", .{hud_text});

        if (u.button("Clear All", .{})) {
            s.selection.clear();
        }
        u.sameLine(.{});
        if (u.button("Select All", .{})) {
            // Build a SetAll(true) request and apply - exercises the
            // applyRequests path even before Begin/End emit anything.
            const reqs: [1]ui.SelectionRequest = .{.{ .set_all = true }};
            const io: ui.MultiSelectIO = .{
                .requests = &reqs,
                .range_src_item = null,
                .nav_id_item = null,
                .nav_id_selected = false,
                .items_count = @intCast(files.len),
            };
            s.selection.applyRequests(s.gpa, &io) catch assertUnreachable(@src(), "OOM", .{});
        }

        // ---- Tap mode (phone affordance)
        // Three-button segmented control sets `s.tap_mode`.  Below,
        // around `beginMultiSelect`, we temporarily flip the input
        // snapshot's modifier flags so the MS scope captures the
        // synthesized modifier on its key_ctrl / key_shift fields.
        // Restoration happens right after Begin returns, so
        // downstream widgets in this frame see the real modifier
        // state.
        u.separatorText("Tap mode");
        const replace_label: []const u8 = if (s.tap_mode == .replace) "[*] Replace" else "[ ] Replace";
        const toggle_label: []const u8 = if (s.tap_mode == .toggle) "[*] Toggle" else "[ ] Toggle";
        const range_label: []const u8 = if (s.tap_mode == .range) "[*] Range" else "[ ] Range";
        if (u.button(replace_label, .{})) {
            s.tap_mode = .replace;
        }
        u.sameLine(.{});
        if (u.button(toggle_label, .{})) {
            s.tap_mode = .toggle;
        }
        u.sameLine(.{});
        if (u.button(range_label, .{})) {
            s.tap_mode = .range;
        }

        // ---- File list ----------------------------------------
        u.separatorText("Files");

        // -------- MultiSelect scope
        // Wraps the row loop so click/Ctrl-click/Shift-click emit
        // proper SelectionRequest values.  Storage is updated by
        // two `applyRequests` calls - one after Begin (drains any
        // keyboard-shortcut-derived pending requests), one after
        // End (drains this-frame's click-emitted requests).
        // The Selectable's return value is now intentionally
        // discarded - the storage state is owned by the scope's
        // applyRequests path, not by inline mutation.
        // Phone modifier synth: flip the left_ctrl / left_shift
        // key down-state on the input snapshot just before Begin so
        // the scope captures the synthesized modifier; restore
        // immediately after Begin.  The scope retains its captured
        // copy, so downstream widgets in this frame see the real
        // modifier state.
        const ctrl_idx: usize = @backingInt(ui.KeyCode.left_control);
        const shift_idx: usize = @backingInt(ui.KeyCode.left_shift);
        const saved_ctrl: bool = u.ctx.input.keys[ctrl_idx].down;
        const saved_shift: bool = u.ctx.input.keys[shift_idx].down;
        u.ctx.input.keys[ctrl_idx].down = saved_ctrl or (s.tap_mode == .toggle);
        u.ctx.input.keys[shift_idx].down = saved_shift or (s.tap_mode == .range);

        const ms_io: *const ui.MultiSelectIO = u.beginMultiSelect(.{
            .clear_on_escape = true,
            .no_auto_clear_on_reselect = true, // Mac Finder feel on phone
            .clear_on_click_void = true,
        }, @intCast(s.selection.size()), @intCast(files.len));

        u.ctx.input.keys[ctrl_idx].down = saved_ctrl;
        u.ctx.input.keys[shift_idx].down = saved_shift;

        s.selection.applyRequests(s.gpa, ms_io) catch assertUnreachable(@src(), "OOM", .{});

        for (files, 0..) |item, idx| {
            // Build the row label: "[k] name             size".  We
            // pad the name area to a fixed width so the size column
            // aligns.will replace this with a proper
            // 3-column layout via separators.
            var row_buf: [128]u8 = undefined;
            var size_buf: [16]u8 = undefined;
            const size_str: []const u8 = formatSize(&size_buf, item.size_bytes);
            const row: []const u8 = bufPrint(
                &row_buf,
                "{s} {s:<28} {s:>10}",
                .{ kindGlyph(item.kind), item.name, size_str },
            ) catch item.name;

            const id: u64 = @intCast(idx);
            u.setNextItemSelectionUserData(id);
            // Discard return value - selection is mutated by the
            // scope's applyRequests after endMultiSelect below,
            // not by inline toggle.  Matches the canonical
            // multi-select demo idiom in imgui_demo.cpp:2745+.
            _ = u.selectable(row, s.selection.contains(id), .{});
        }

        const ms_io2: *const ui.MultiSelectIO = u.endMultiSelect();
        s.selection.applyRequests(s.gpa, ms_io2) catch assertUnreachable(@src(), "OOM", .{});

        u.separatorText("Status");
        u.textDisabled("Buttons exercise applyRequests directly.", .{});
        u.textDisabled("Rows go through the MS scope (tap mode applies).", .{});
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - multi-select finder",
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
