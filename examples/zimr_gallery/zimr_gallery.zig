//! zimr_gallery - the native gallery: every example as its own program, chosen from a list as on the web.
//!
//! The web serves each example as its own page, picked from a list beside it. Natively, each example is its own
//! executable, built beside this one into the build's folder for its system - and the gallery is that list, drawn
//! with the engine's own UI:
//!
//!     examples                          audio - amp envelope
//!     [search  (press /)        ]       ADSR sliders reshape a tone's amplitude, and the plot below
//!     [all modules             v]       is the exact PCM you hear
//!     305 examples                      **
//!     audio                             running                       [ stop ]
//!       amp_envelope         **
//!     > keyboard             ***        <folder>/audio_keyboard.exe
//!
//! An example's picture is a thumbnail `zig build gallery-shots` saved - the example run headless for two seconds,
//! its frame shrunk - in `gallery_shots/` beside the build's folders: from the gallery's own folder,
//! `../gallery_shots/<name>.png`, loaded the first time the example is chosen (`thumbnailOf`) and kept. An example
//! with no thumbnail shows none.
//!
//! The list is the web gallery's catalog, `src/web/manifest.json`, in its order and grouped by module, each example
//! with its stars. A search keeps the examples whose name, title, description or module holds every word typed; the
//! module box keeps one module. Up and down move the selection, Enter starts it, `/` goes to the search, Escape
//! clears it. The panel beside the list shows the selected example: its description, how its program stands - not
//! built yet (and why), not started, running, closed, or failed with its exit code - and a button that starts or
//! stops it.
//!
//! Each example runs as a separate process, found beside the gallery's own executable (`native_os.ChildProgram`): a
//! crash, or a validation error that ends a program, belongs to that example alone, and several can run at once.
//! Each is watched by a thread of its own, which records how it ended, so that the gallery's frames never wait for a
//! program; stopping one is the system's own call.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArenaAllocator = std.heap.ArenaAllocator;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const indexOf = std.mem.indexOf;
const bufPrint = std.fmt.bufPrint;
const ArrayList = std.ArrayList;
const allocPrint = std.fmt.allocPrint;
const indexOfScalar = std.mem.indexOfScalar;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const Vec2 = zm.Vec2;
const clamp = zm.clamp;
const gallery_options = @import("gallery_options");
const native_os = z.native_os;
const ChildProgram = native_os.ChildProgram;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
/// The web gallery's catalog: every example's name, module, title, description and stars, in the gallery's order.
const manifest_json = @embedFile("examples_manifest");

const is_windows: bool = builtin.os.tag == .windows;

// ---- The catalog ----

/// One entry of the catalog, as `src/web/manifest.json` writes it; the fields the gallery does not show are skipped.
const CatalogEntry = struct {
    name: []const u8,
    module: []const u8,
    title: []const u8,
    description: []const u8 = "",
    stars: u8 = 0,
};

const Catalog = struct {
    examples: []const CatalogEntry,
};

/// The reason an example has no native build yet, from the build's list (`gallery_options`), or null.
fn pendingReason(name: []const u8) ?[]const u8 {
    for (gallery_options.pending_names, gallery_options.pending_reasons) |pending_name, reason| {
        if (eql(u8, pending_name, name)) {
            return reason;
        }
    }
    return null;
}

/// An example's title without the catalog's "zimr - " in front of it.
fn shortTitle(title: []const u8) []const u8 {
    const prefix: []const u8 = "zimr - ";
    return if (startsWith(u8, title, prefix)) title[prefix.len..] else title;
}

/// An example's stars, as the list shows them: one `*` each, up to five.
fn starsText(stars: u8) []const u8 {
    const all_stars: []const u8 = "*****";
    return all_stars[0..@min(stars, all_stars.len)];
}

/// What a search looks through, for one example: its name, title, description and module, in lower case.
fn haystackOf(arena: Allocator, entry: CatalogEntry) Allocator.Error![]const u8 {
    const joined: []u8 = try allocPrint(arena, "{s} {s} {s} {s}", .{
        entry.name,
        entry.title,
        entry.description,
        entry.module,
    });
    for (joined) |*byte| {
        byte.* = std.ascii.toLower(byte.*);
    }
    return joined;
}

/// Whether `haystack` holds every word of `search`, compared in lower case; an empty search keeps everything.
fn matchesSearch(haystack: []const u8, search: []const u8) bool {
    var words = std.mem.tokenizeScalar(u8, search, ' ');
    while (words.next()) |word| {
        var lower_buffer: [96]u8 = undefined;
        const word_length: usize = @min(word.len, lower_buffer.len);
        const lower_word: []u8 = lower_buffer[0..word_length];
        for (word[0..word_length], lower_word) |byte, *lower_byte| {
            lower_byte.* = std.ascii.toLower(byte);
        }
        if (indexOf(u8, haystack, lower_word) == null) {
            return false;
        }
    }
    return true;
}

// ---- A program started from the gallery ----

// Removing a setting from the gallery's own environment, declared with plain types.
extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) i32;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Removes `ZIMR_SCRIPT` from the gallery's own environment, which the programs it starts inherit: a scripted run
/// of the gallery is the gallery's, and an example started from it must not run the gallery's script. Done at the
/// first frame, once the engine has read the script it runs.
fn forgetScriptSetting() void {
    if (comptime is_windows) {
        _ = SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("ZIMR_SCRIPT"), null);
        return;
    }
    _ = unsetenv("ZIMR_SCRIPT");
}

// ---- An example's thumbnail ----

/// The widest a thumbnail is shown in the panel, and the tallest - a portrait one shrunk to fit.
const thumbnail_largest_size: Vec2 = .{ 320, 360 };

/// A thumbnail loaded: its texture, and its size in pixels.
const LoadedThumbnail = struct {
    texture: z.WgpuTexture,
    width: f32,
    height: f32,
};

/// What the gallery knows of an example's thumbnail (`thumbnailOf`): not looked for yet, looked for and absent - so
/// that it is looked for once - or loaded.
const ThumbnailSlot = union(enum) {
    unknown,
    missing,
    loaded: LoadedThumbnail,
};

/// Where the panel's thumbnail is drawn this frame (`buildDetails`, then `update` after the UI): the room the panel
/// reserved for it, and its texture.
const ThumbnailPlacement = struct {
    texture: z.WgpuTexture,
    top_left: Vec2,
    size: Vec2,
};

// ---- The gallery ----

const State = struct {
    gpa: Allocator,
    arena: ArenaAllocator,
    ui_font: z.Font,
    ui_host: z.UiHost,
    examples: []const CatalogEntry,
    /// For each example, what a search looks through (`haystackOf`).
    haystacks: []const []const u8,
    programs: []ChildProgram,
    /// The modules, in the catalog's order, after "all modules": the module box's items.
    module_items: []const []const u8,
    module_index: i32 = 0,
    search_buffer: [96]u8 = undefined,
    search_length: usize = 0,
    /// The examples the search and the module keep, as indices into `examples`, rebuilt each frame.
    shown: []usize,
    shown_count: usize = 0,
    selected: ?usize = null,
    /// The folder the examples' executables are in: the gallery's own.
    executable_folder_buffer: [1024]u8 = undefined,
    executable_folder_length: usize = 0,
    /// Whether the gallery's script setting has been removed from its environment (`forgetScriptSetting`).
    has_forgotten_script_setting: bool = false,
    /// Each example's thumbnail, as far as the gallery knows it.
    thumbnails: []ThumbnailSlot,
    /// The thumbnail the panel placed this frame, drawn after the UI (`buildDetails`).
    thumbnail_placement: ?ThumbnailPlacement = null,
};

/// The modules of `examples`, each once, in the order they first appear, after "all modules".
fn moduleItems(arena: Allocator, examples: []const CatalogEntry) Allocator.Error![]const []const u8 {
    var items: ArrayList([]const u8) = .empty;
    try items.append(arena, "all modules");
    for (examples) |entry| {
        const is_listed: bool = for (items.items) |item| {
            if (eql(u8, item, entry.module)) {
                break true;
            }
        } else false;
        if (!is_listed) {
            try items.append(arena, entry.module);
        }
    }
    return items.items;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    var arena: ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const arena_allocator: Allocator = arena.allocator();
    const catalog: Catalog = try std.json.parseFromSliceLeaky(Catalog, arena_allocator, manifest_json, .{
        .ignore_unknown_fields = true,
    });
    const haystacks: [][]const u8 = try arena_allocator.alloc([]const u8, catalog.examples.len);
    for (catalog.examples, haystacks) |entry, *haystack| {
        haystack.* = try haystackOf(arena_allocator, entry);
    }
    const programs: []ChildProgram = try arena_allocator.alloc(ChildProgram, catalog.examples.len);
    @memset(programs, .{});
    const shown: []usize = try arena_allocator.alloc(usize, catalog.examples.len);
    const thumbnails: []ThumbnailSlot = try arena_allocator.alloc(ThumbnailSlot, catalog.examples.len);
    @memset(thumbnails, .unknown);
    const module_items: []const []const u8 = try moduleItems(arena_allocator, catalog.examples);
    const ui_font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20);
    s.* = .{
        .gpa = gpa,
        .thumbnails = thumbnails,
        .arena = arena,
        .ui_font = ui_font,
        .ui_host = z.UiHost.init(gpa, ui_font),
        .examples = catalog.examples,
        .haystacks = haystacks,
        .programs = programs,
        .module_items = module_items,
        .shown = shown,
    };
    // An app has no `main` to receive an `Io`; the engine's services hold one for it.
    const io: Io = native_os.servicesIo();
    const executable_folder: []const u8 = native_os.executableFolder(io, &s.executable_folder_buffer) orelse "";
    s.executable_folder_length = executable_folder.len;
}

fn deinit(gpa: Allocator, s: *State) void {
    // A program still running keeps running, and its watcher with it; the gallery waits for the watchers whose
    // programs have ended, so that none outlives the memory it writes.
    for (s.programs) |*program| {
        program.deinit();
    }
    for (s.thumbnails) |*slot| {
        switch (slot.*) {
            .loaded => |*loaded| loaded.texture.deinit(),
            .unknown, .missing => {},
        }
    }
    s.ui_host.deinit();
    z.unloadFont(gpa, s.ui_font);
    s.arena.deinit();
}

/// The path of `name`'s executable, beside the gallery's: `<folder>/<name>`, with `.exe` on Windows.
fn executablePath(
    s: *const State,
    name: []const u8,
    buffer: []u8,
) ?[]const u8 {
    const folder: []const u8 = s.executable_folder_buffer[0..s.executable_folder_length];
    const separator: u8 = if (is_windows) '\\' else '/';
    const extension: []const u8 = if (is_windows) ".exe" else "";
    return bufPrint(buffer, "{s}{c}{s}{s}", .{ folder, separator, name, extension }) catch null;
}

/// Starts the example at `index` as its own process, beside the gallery's own (`ChildProgram`). One already running
/// is left as it is; one whose executable is not there shows `not_started`.
fn startProgram(s: *State, index: usize) void {
    var path_buffer: [1200]u8 = undefined;
    const path: []const u8 = executablePath(s, s.examples[index].name, &path_buffer) orelse return;
    // An app has no `main` to receive an `Io`; the engine's services hold one for it.
    const io: Io = native_os.servicesIo();
    s.programs[index].start(io, &.{path});
}

/// Where the thumbnails are, from the gallery's own folder: `zig build gallery-shots` saves them in
/// zig-out/gallery_shots/, one folder up from the Windows programs (zig-out/windows/) and two from the headless ones
/// (zig-out/headless/bin/).
const thumbnail_folders_up = [_][]const u8{ "..", "../.." };

/// The path of `name`'s thumbnail, `<folder>/<up>/gallery_shots/<name>.png`, from the gallery's own folder.
fn thumbnailPath(
    s: *const State,
    folders_up: []const u8,
    name: []const u8,
    buffer: []u8,
) ?[]const u8 {
    const folder: []const u8 = s.executable_folder_buffer[0..s.executable_folder_length];
    return bufPrint(buffer, "{s}/{s}/gallery_shots/{s}.png", .{ folder, folders_up, name }) catch null;
}

/// The thumbnail of the example at `index`: loaded the first time it is asked for - the file read, its PNG decoded,
/// the pixels uploaded as a texture - and kept; null when there is none, which is remembered too.
fn thumbnailOf(f: *z.Frame, s: *State, index: usize) ?LoadedThumbnail {
    const slot: *ThumbnailSlot = &s.thumbnails[index];
    switch (slot.*) {
        .loaded => |loaded| return loaded,
        .missing => return null,
        .unknown => {},
    }
    slot.* = .missing;
    const io: Io = native_os.servicesIo();
    const most_bytes: usize = 4 << 20;
    // The first of the folders it can be in that holds it.
    const png_bytes: []u8 = for (thumbnail_folders_up) |folders_up| {
        var path_buffer: [1200]u8 = undefined;
        const path: []const u8 = thumbnailPath(s, folders_up, s.examples[index].name, &path_buffer) orelse continue;
        if (native_os.readWhole(s.gpa, io, path, most_bytes) catch null) |read_bytes| {
            break read_bytes;
        }
    } else return null;
    defer s.gpa.free(png_bytes);
    const image: z.Image = z.loadImageFromMemory(s.gpa, png_bytes) catch return null;
    defer z.unloadImage(s.gpa, image);
    const texture: z.WgpuTexture = z.loadTextureFromImage(f.gl, image);
    const loaded: LoadedThumbnail = .{
        .texture = texture,
        .width = @floatFromInt(image.width),
        .height = @floatFromInt(image.height),
    };
    slot.* = .{ .loaded = loaded };
    return loaded;
}

/// The size a thumbnail is shown at in the panel: its own, shrunk - keeping its shape - to fit both `largest` and the
/// width the panel has.
fn shownThumbnailSize(loaded: LoadedThumbnail, panel_width: f32) Vec2 {
    const widest: f32 = @min(thumbnail_largest_size[0], panel_width);
    const width_scale: f32 = widest / loaded.width;
    const height_scale: f32 = thumbnail_largest_size[1] / loaded.height;
    const scale: f32 = @min(1, @min(width_scale, height_scale));
    return .{ loaded.width * scale, loaded.height * scale };
}

/// The examples the search and the module box keep, into `s.shown`, in the catalog's order.
fn filterExamples(s: *State) void {
    const search: []const u8 = s.search_buffer[0..s.search_length];
    const chosen_module: ?[]const u8 = if (s.module_index > 0) s.module_items[@intCast(s.module_index)] else null;
    s.shown_count = 0;
    for (s.examples, s.haystacks, 0..) |entry, haystack, index| {
        const is_in_module: bool = if (chosen_module) |module| eql(u8, entry.module, module) else true;
        if (is_in_module and matchesSearch(haystack, search)) {
            s.shown[s.shown_count] = index;
            s.shown_count += 1;
        }
    }
}

/// Up and down move the selection through the examples shown, Enter starts it, Escape clears the search. Whether `/`
/// asked for the search field, which the list's frame then focuses.
fn readKeys(f: *z.Frame, s: *State) bool {
    const shown: []const usize = s.shown[0..s.shown_count];
    if (z.isKeyPressed(f.input, .escape)) {
        s.search_length = 0;
    }
    const step: i32 = if (z.isKeyPressed(f.input, .down)) 1 else if (z.isKeyPressed(f.input, .up)) -1 else 0;
    if (step != 0 and shown.len > 0) {
        const current_position: ?usize = if (s.selected) |selected| indexOfScalar(usize, shown, selected) else null;
        const next_position: usize = if (current_position) |position| step: {
            const moved: i64 = @as(i64, @intCast(position)) + step;
            break :step @intCast(clamp(moved, 0, @as(i64, @intCast(shown.len - 1))));
        } else 0;
        s.selected = shown[next_position];
    }
    if (z.isKeyPressed(f.input, .enter)) {
        if (s.selected) |selected| {
            startProgram(s, selected);
        }
    }
    return z.isKeyPressed(f.input, .slash);
}

/// How a program's state reads in the panel (`stateLine`): its words, and their colour.
const StateLine = struct {
    text: []const u8,
    color: Color,
};

/// How a program's state reads in the panel, and in which colour.
fn stateLine(
    s: *const State,
    index: usize,
    buffer: []u8,
) StateLine {
    const program: *const ChildProgram = &s.programs[index];
    if (pendingReason(s.examples[index].name)) |reason| {
        return .{ .text = reason, .color = .{ .r = 150, .g = 150, .b = 150, .a = 255 } };
    }
    return switch (program.currentState()) {
        .idle => .{ .text = "not started", .color = .{ .r = 170, .g = 170, .b = 170, .a = 255 } },
        .running => .{ .text = "running", .color = .{ .r = 90, .g = 200, .b = 120, .a = 255 } },
        .closed => .{ .text = "closed", .color = .{ .r = 170, .g = 170, .b = 170, .a = 255 } },
        .failed => .{
            .text = bufPrint(buffer, "failed, exit code {d}", .{program.exit_code}) catch "failed",
            .color = .{ .r = 230, .g = 90, .b = 80, .a = 255 },
        },
        .not_started => .{
            .text = "could not be started - is it built?",
            .color = .{ .r = 230, .g = 90, .b = 80, .a = 255 },
        },
    };
}

/// The list: the search, the module box, the count, and the examples grouped by module.
fn buildList(
    s: *State,
    ui: z.ui_real.Ui,
    height: f32,
    wants_search: bool,
) void {
    if (wants_search) {
        ui.setKeyboardFocusHere();
    }
    _ = ui.inputTextWithHint("##search", "search  (press /)", &s.search_buffer, &s.search_length, .{ .width = -1 });
    _ = ui.combo("##module", &s.module_index, s.module_items, .{ .width = -1, .max_visible_items = 12 });
    filterExamples(s);
    if (s.shown_count == s.examples.len) {
        ui.text("{d} examples", .{s.examples.len});
    } else {
        ui.text("{d} of {d}", .{ s.shown_count, s.examples.len });
    }
    // The list takes what the window has left below the rows above it.
    const rows_above_height: f32 = 4 * (ui.calcTextSize("M")[1] + 12);
    const list_height: f32 = @max(100, height - rows_above_height);
    if (ui.beginChild("list", .{ 0, list_height }, .{})) {
        const module_color: Color = .{ .r = 140, .g = 170, .b = 230, .a = 255 };
        var group: []const u8 = "";
        for (s.shown[0..s.shown_count]) |index| {
            const entry: CatalogEntry = s.examples[index];
            if (!eql(u8, entry.module, group)) {
                group = entry.module;
                ui.textColored(module_color, "{s}", .{group});
            }
            var label_buffer: [160]u8 = undefined;
            const label: []const u8 = bufPrint(&label_buffer, "  {s}  {s}##{s}", .{
                entry.name,
                starsText(entry.stars),
                entry.name,
            }) catch entry.name;
            const is_selected: bool = if (s.selected) |selected| selected == index else false;
            if (ui.selectable(label, is_selected, .{})) {
                s.selected = index;
            }
        }
        if (s.shown_count == 0) {
            ui.text("No example matches.", .{});
        }
    }
    ui.endChild();
}

/// The panel: the selected example's title, description, stars, how its program stands, and the button that starts
/// or stops it.
fn buildDetails(
    f: *z.Frame,
    s: *State,
    ui: z.ui_real.Ui,
    panel_width: f32,
) void {
    const index: usize = s.selected orelse {
        ui.textWrapped("Choose an example in the list - or search for one - and start it here, or with Enter.", .{});
        return;
    };
    const entry: CatalogEntry = s.examples[index];
    ui.text("{s}", .{shortTitle(entry.title)});
    ui.separator();
    if (entry.description.len > 0) {
        ui.textWrapped("{s}", .{entry.description});
    }
    ui.text("{s}", .{starsText(entry.stars)});
    // The thumbnail: its room reserved here, the picture drawn there after the UI (`update`) - the UI draws a texture
    // of its own kind only.
    if (thumbnailOf(f, s, index)) |loaded| {
        const shown_size: Vec2 = shownThumbnailSize(loaded, panel_width - 32);
        ui.dummy(shown_size);
        s.thumbnail_placement = .{
            .texture = loaded.texture,
            .top_left = ui.getItemRectMin(),
            .size = shown_size,
        };
    }
    var state_buffer: [64]u8 = undefined;
    const state_line: StateLine = stateLine(s, index, &state_buffer);
    ui.textColored(state_line.color, "{s}", .{state_line.text});
    const has_native_build: bool = pendingReason(entry.name) == null;
    if (has_native_build) {
        const program: *ChildProgram = &s.programs[index];
        const is_running: bool = program.currentState() == .running;
        if (is_running) {
            if (ui.button("stop", .{})) {
                program.stop();
            }
        } else if (ui.button("start", .{})) {
            startProgram(s, index);
        }
        var path_buffer: [1200]u8 = undefined;
        if (executablePath(s, entry.name, &path_buffer)) |path| {
            ui.textWrapped("{s}", .{path});
        }
    }
}

fn update(f: *z.Frame, s: *State) void {
    if (!s.has_forgotten_script_setting) {
        forgetScriptSetting();
        s.has_forgotten_script_setting = true;
    }
    const width: f32 = f.window.widthf();
    const height: f32 = f.window.heightf();
    const wants_search: bool = readKeys(f, s);
    const ui: z.ui_real.Ui = s.ui_host.begin(f);
    // The list on the left, the panel beside it; both fill the window's height and follow its size.
    const list_width: f32 = @max(280, width * 0.4);
    const fixed: z.ui_real.WindowFlags = .{ .no_move = true, .no_resize = true, .no_collapse = true };
    ui.setNextWindowPos(.{ 0, 0 }, .{});
    ui.setNextWindowSize(.{ list_width, height }, .{});
    if (ui.window("examples", .{ .flags = fixed })) |list_window| {
        defer list_window.close();
        buildList(s, ui, height, wants_search);
    }
    ui.setNextWindowPos(.{ list_width, 0 }, .{});
    ui.setNextWindowSize(.{ width - list_width, height }, .{});
    s.thumbnail_placement = null;
    if (ui.window("example", .{ .flags = fixed })) |panel_window| {
        defer panel_window.close();
        buildDetails(f, s, ui, width - list_width);
    }
    s.ui_host.render(f);
    // The panel's thumbnail, in the room it reserved, over the UI.
    if (s.thumbnail_placement) |placement| {
        const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
        const top_left: Vec2 = placement.top_left;
        z.drawTexture(f.gl, placement.texture, top_left[0], top_left[1], placement.size[0], placement.size[1], white);
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - gallery",
            .width = 1100,
            .height = 720,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
