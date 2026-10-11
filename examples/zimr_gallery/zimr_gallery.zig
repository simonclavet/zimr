//! zimr_gallery - the native gallery: every example as its own program, started from one list.
//!
//! The web serves each example as its own page. Natively, each example is its own executable, built beside this one
//! by `zig build all-examples-windows` into zig-out/windows/<name>.exe. The gallery lists them as the web's gallery
//! does - the same catalog, `src/web/manifest.json`, in its order and grouped by module - and starts the one clicked
//! as a separate process. A crash, or a validation error that ends a program, then belongs to that example alone,
//! and the gallery stays up to start the next. Each row shows how its program last stood: running, closed (exit code
//! 0), or failed (any other exit code). An example with no native build yet shows the reason instead, and does not
//! start.
//!
//! Windows only. A program is started with `CreateProcessW` and the command line "<name>.exe", which Windows looks
//! for first in the directory the gallery itself was loaded from - where the build put every example. A program's
//! console output goes to the gallery's console.

const std = @import("std");
const z = @import("zimr");
const zm = @import("zm");
const gallery_options = @import("gallery_options");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Color = zm.Color;
const Vec2 = zm.Vec2;
const bufPrint = std.fmt.bufPrint;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
/// The web gallery's catalog: every example's name, module, title and description, in the gallery's order.
const manifest_json = @embedFile("examples_manifest");

// ---- Starting a program: the four kernel32 calls the gallery needs, declared with plain types ----

const Handle = *anyopaque;
const Bool = i32;
const Dword = u32;

/// `STARTUPINFOW`: how a new process's first window appears. All zero but its own size: Windows' defaults.
const StartupInfo = extern struct {
    size: Dword,
    reserved: ?[*:0]u16 = null,
    desktop: ?[*:0]u16 = null,
    title: ?[*:0]u16 = null,
    x: Dword = 0,
    y: Dword = 0,
    x_size: Dword = 0,
    y_size: Dword = 0,
    x_count_chars: Dword = 0,
    y_count_chars: Dword = 0,
    fill_attribute: Dword = 0,
    flags: Dword = 0,
    show_window: u16 = 0,
    reserved2_size: u16 = 0,
    reserved2: ?*u8 = null,
    std_input: ?Handle = null,
    std_output: ?Handle = null,
    std_error: ?Handle = null,
};

/// `PROCESS_INFORMATION`: the new process and its first thread, as handles and ids.
const ProcessInformation = extern struct {
    process: ?Handle = null,
    thread: ?Handle = null,
    process_id: Dword = 0,
    thread_id: Dword = 0,
};

extern "kernel32" fn CreateProcessW(
    application_name: ?[*:0]const u16,
    command_line: ?[*:0]u16,
    process_attributes: ?*anyopaque,
    thread_attributes: ?*anyopaque,
    inherit_handles: Bool,
    creation_flags: Dword,
    environment: ?*anyopaque,
    current_directory: ?[*:0]const u16,
    startup_info: *StartupInfo,
    process_information: *ProcessInformation,
) callconv(.winapi) Bool;
extern "kernel32" fn WaitForSingleObject(handle: Handle, milliseconds: Dword) callconv(.winapi) Dword;
extern "kernel32" fn GetExitCodeProcess(process: Handle, exit_code: *Dword) callconv(.winapi) Bool;
extern "kernel32" fn CloseHandle(handle: Handle) callconv(.winapi) Bool;

/// `WaitForSingleObject`'s answer for a process that has ended.
const wait_object_0: Dword = 0;

// ---- The catalog ----

/// One entry of the catalog, as `src/web/manifest.json` writes it; the fields the gallery does not show are skipped.
const CatalogEntry = struct {
    name: []const u8,
    module: []const u8,
    title: []const u8,
    description: []const u8 = "",
};

const Catalog = struct {
    examples: []const CatalogEntry,
};

/// How an example's program stands.
const Run = union(enum) {
    /// Not started since the gallery opened.
    idle,
    /// Started; the handle is the process's, kept to learn when it ends.
    running: Handle,
    /// Ended, with this exit code: 0 for a program that closed normally.
    ended: Dword,
    /// `CreateProcessW` refused: most likely its executable was not built.
    not_started,
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

/// Starts the example `name` as its own process: "<name>.exe", found beside the gallery.
fn start(name: []const u8) Run {
    var utf8_buffer: [128]u8 = undefined;
    const executable: []const u8 = bufPrint(&utf8_buffer, "{s}.exe", .{name}) catch return .not_started;
    var command_line: [128:0]u16 = @splat(0);
    const unit_count: usize = std.unicode.utf8ToUtf16Le(&command_line, executable) catch return .not_started;
    command_line[unit_count] = 0;
    var startup: StartupInfo = .{ .size = @sizeOf(StartupInfo) };
    var information: ProcessInformation = .{};
    const created: Bool = CreateProcessW(null, &command_line, null, null, 0, 0, null, null, &startup, &information);
    if (created == 0) {
        return .not_started;
    }
    // The gallery watches the process, never its thread.
    if (information.thread) |thread| {
        _ = CloseHandle(thread);
    }
    const process: Handle = information.process orelse return .not_started;
    return .{ .running = process };
}

/// Learns, without waiting, whether a running program has ended, and with which exit code.
fn poll(run: *Run) void {
    const process: Handle = switch (run.*) {
        .running => |handle| handle,
        else => return,
    };
    if (WaitForSingleObject(process, 0) != wait_object_0) {
        return;
    }
    var exit_code: Dword = 0;
    _ = GetExitCodeProcess(process, &exit_code);
    _ = CloseHandle(process);
    run.* = .{ .ended = exit_code };
}

// ---- The app ----

const State = struct {
    arena: ArenaAllocator,
    font: z.Font,
    catalog: Catalog,
    runs: []Run,
    /// How far the list is scrolled, in logical pixels.
    scroll: f32 = 0,
};

/// Each row's height, and the list's margins, in logical pixels.
const row_height: f32 = 22;
const margin: f32 = 16;
const header_height: f32 = 48;

const background: Color = .{ .r = 24, .g = 26, .b = 32, .a = 255 };
const text_color: Color = .{ .r = 230, .g = 232, .b = 238, .a = 255 };
const dim_color: Color = .{ .r = 130, .g = 136, .b = 150, .a = 255 };
const module_color: Color = .{ .r = 96, .g = 165, .b = 250, .a = 255 };
const hover_color: Color = .{ .r = 44, .g = 48, .b = 60, .a = 255 };
const running_color: Color = .{ .r = 250, .g = 204, .b = 21, .a = 255 };
const closed_color: Color = .{ .r = 74, .g = 222, .b = 128, .a = 255 };
const failed_color: Color = .{ .r = 248, .g = 113, .b = 113, .a = 255 };

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    var arena: ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const catalog: Catalog = try std.json.parseFromSliceLeaky(Catalog, arena.allocator(), manifest_json, .{
        .ignore_unknown_fields = true,
    });
    const runs: []Run = try arena.allocator().alloc(Run, catalog.examples.len);
    @memset(runs, .idle);
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 16);
    s.* = .{ .arena = arena, .font = font, .catalog = catalog, .runs = runs };
}

fn deinit(gpa: Allocator, s: *State) void {
    // A program still running keeps running; the gallery only lets go of its handle.
    for (s.runs) |run| {
        switch (run) {
            .running => |process| _ = CloseHandle(process),
            else => {},
        }
    }
    z.unloadFont(gpa, s.font);
    s.arena.deinit();
}

/// A title without the catalog's "zimr - " prefix, which every entry shares.
fn shortTitle(title: []const u8) []const u8 {
    const prefix: []const u8 = "zimr - ";
    return if (startsWith(u8, title, prefix)) title[prefix.len..] else title;
}

/// What a row says about its program, and in which colour.
const RunLabel = struct {
    text: []const u8,
    color: Color,
};

/// The label for how a program stands; a failure's exit code is written into `buffer`.
fn runText(run: Run, buffer: []u8) RunLabel {
    return switch (run) {
        .idle => .{ .text = "", .color = dim_color },
        .running => .{ .text = "running", .color = running_color },
        .ended => |code| if (code == 0)
            .{ .text = "closed", .color = closed_color }
        else
            .{ .text = bufPrint(buffer, "failed, exit code {d}", .{code}) catch "failed", .color = failed_color },
        .not_started => .{ .text = "not built", .color = failed_color },
    };
}

fn update(f: *z.Frame, s: *State) void {
    for (s.runs) |*run| {
        poll(run);
    }
    const width: f32 = f.window.widthf();
    const height: f32 = f.window.heightf();
    const pointer: Vec2 = z.getMousePosition(f.input);
    const clicked: bool = z.isMouseButtonPressed(f.input, .left);
    s.scroll = @max(0, s.scroll - z.getMouseWheelMove(f.input) * row_height * 3);

    z.clearViewport(f, background);
    f.gl.text(.{ margin, 14 }, "zimr gallery: every example as its own program", .{
        .size = 18,
        .color = text_color,
        .font = &s.font,
    });

    var y: f32 = header_height - s.scroll;
    var previous_module: []const u8 = "";
    var status_buffer: [48]u8 = undefined;
    for (s.catalog.examples, s.runs) |entry, *run| {
        if (!eql(u8, entry.module, previous_module)) {
            previous_module = entry.module;
            y += row_height / 2;
            if (y > header_height - row_height and y < height) {
                f.gl.text(.{ margin, y }, entry.module, .{ .size = 15, .color = module_color, .font = &s.font });
            }
            y += row_height;
        }
        const row_top: f32 = y;
        y += row_height;
        const visible: bool = row_top > header_height - row_height and row_top < height;
        if (!visible) {
            continue;
        }
        const pending: ?[]const u8 = pendingReason(entry.name);
        const hovered: bool = pointer[1] >= row_top and pointer[1] < row_top + row_height and pointer[0] < width;
        if (hovered and pending == null) {
            f.gl.rect(.{ .x = 0, .y = row_top, .width = width, .height = row_height }, .{ .color = hover_color });
            const startable: bool = switch (run.*) {
                .running => false,
                else => true,
            };
            if (clicked and startable) {
                run.* = start(entry.name);
            }
        }
        const title_color: Color = if (pending == null) text_color else dim_color;
        f.gl.text(.{ margin * 2, row_top + 3 }, shortTitle(entry.title), .{
            .size = 14,
            .color = title_color,
            .font = &s.font,
        });
        if (pending) |reason| {
            f.gl.text(.{ width * 0.45, row_top + 3 }, reason, .{ .size = 13, .color = dim_color, .font = &s.font });
        } else {
            const status: RunLabel = runText(run.*, &status_buffer);
            f.gl.text(.{ width * 0.72, row_top + 3 }, status.text, .{
                .size = 13,
                .color = status.color,
                .font = &s.font,
            });
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - gallery",
            .width = 960,
            .height = 720,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
