//! THE NATIVE LOOP - what the browser does for a zimr program, done by the program itself on a native host.
//!
//! In the browser, the page owns the window (the canvas), the frame clock (`requestAnimationFrame`) and the event
//! queue, and calls the program's `update` export once per frame. A native program owns all three, so this file
//! provides them - and nothing else changes: `App.run` sets the program up exactly as on the web, and every frame is
//! the same `update` call.
//!
//!     openWindow   App.run, before the first GPU call: the window, then handed to the Vulkan host, which creates its
//!                  surface from it - choosing a GPU depends on presenting to it
//!     run          the runner's main, after App.run: drain the window's messages, hand their input to the
//!                  engine as events, call `update`, until the window closes. A minimized window gets no
//!                  frames, like a hidden tab; FIFO presentation waits for the display inside each frame, so the loop
//!                  runs at the display's rate, as requestAnimationFrame does
//!     finish       after the app's teardown: the Vulkan host's shutdown and its validation report, then the window
//!
//! Input reaches the engine as the browser delivers it: the window hands each input message to `queueInput`,
//! `native_input.zig` translates it and queues it, and before each frame the queued input is converted into the
//! contract's events (`platform/contract.zig`) and handed, in order, to the engine's `receiveEvent` - which makes the
//! same calls the browser's bridge makes (`wgpu_app.zig`'s `inputPush*`, which the bridge reaches by their exported
//! names, `input_push_*`). With `ZIMR_LOG_INPUT=1`, each event is also printed as the engine receives it.
//!
//! Windows only, for now: a second platform replaces `win32.zig`, and this file's window type with it.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const ArenaAllocator = std.heap.ArenaAllocator;
const native_input = @import("native_input.zig");
const contract = @import("platform/contract.zig");
const console = @import("platform/console.zig");
const zm = @import("zm");
const float = zm.float;
const native_os = @import("native_os.zig");
const vulkan_host = @import("wgpu_vulkan.zig");
const headless_platform = @import("platform/headless.zig");
const script_log = std.log.scoped(.script);
const win32 = @import("win32.zig");
const Allocator = std.mem.Allocator;

const bufPrint = std.fmt.bufPrint;
const eql = std.mem.eql;
const sliceTo = std.mem.sliceTo;
const zeroes = std.mem.zeroes;
const startsWith = std.mem.startsWith;
const indexOfScalar = std.mem.indexOfScalar;
const copyForwards = std.mem.copyForwards;
const trim = std.mem.trim;

// One window per process, and the operating system keeps a pointer to it, so it lives at a fixed address for the
// program's whole life; the browser's canvas is the same kind of singleton.
// lint:off module-var: the process's one window, which must not move
var window: win32.Window = undefined;

// The input waiting for the next frame, filled by the window's messages - as the browser keeps one event queue.
// lint:off module-var: the window's input, which its handler fills between frames
var input: native_input.InputQueue = .{};

// The queued events' conversion into the contract's, which keeps the pointer's last position from frame to frame.
// lint:off module-var: the conversion's state, kept between frames as the queue is
var contract_events: native_input.ContractEvents = .{};

// The timer the frame's wait wakes on between its askings (`waitForFrame`): a high-resolution one, asked for at the
// first wait and kept for the program's life - null where the system has none.
// lint:off module-var: the window loop's own timer, one for the program
var frame_wait_timer: ?win32.HANDLE = null;
// lint:off module-var: whether the timer has been asked for, so that a system without one is asked once only
var has_asked_for_frame_wait_timer: bool = false;

// Whether each input event is printed (`ZIMR_LOG_INPUT=1`), read once when the window opens.
// lint:off module-var: a setting read once, at startup
var logs_input: bool = false;

/// The program's per-frame function: the runner's exported `update`. It follows the C calling convention because the
/// browser's JavaScript calls it; the native loop calls the very same function, once per frame.
pub const UpdateFunction = *const fn (frame_ms: f64) callconv(.c) void;

/// The engine's event function: each event, in order, as the contract defines it (`platform/contract.zig`).
pub const EventFunction = *const fn (event: contract.Event) void;

/// Whether `ZIMR_LOG_INPUT=1` asks for each input event to be printed.
fn readInputLogSetting() bool {
    var setting_buffer: [8]u8 = undefined;
    const setting: []const u8 = native_os.environmentVariable("ZIMR_LOG_INPUT", &setting_buffer) orelse return false;
    return eql(u8, setting, "1");
}

/// Prints one event as the engine receives it - straight to the console, whatever the build's log level.
fn logEvent(event: contract.Event) void {
    var line_buffer: [128]u8 = undefined;
    const line: []const u8 = switch (event) {
        .key_down => |down| bufPrint(&line_buffer, "input: key down {t} ({d}){s}", .{
            down.key,
            @backingInt(down.key),
            if (down.repeat) ", repeat" else "",
        }),
        .key_up => |up| bufPrint(&line_buffer, "input: key up {t} ({d})", .{ up.key, @backingInt(up.key) }),
        .text => |text| bufPrint(&line_buffer, "input: text {s}", .{text.bytes}),
        .mouse_move => |move| bufPrint(&line_buffer, "input: mouse at {d:.1}, {d:.1}, moved {d:.1}, {d:.1}", .{
            move.x,
            move.y,
            move.dx,
            move.dy,
        }),
        .mouse_button_down => |button| bufPrint(&line_buffer, "input: button {d} down", .{button.button}),
        .mouse_button_up => |button| bufPrint(&line_buffer, "input: button {d} up", .{button.button}),
        .mouse_wheel => |wheel| bufPrint(&line_buffer, "input: wheel {d:.2}, {d:.2}", .{ wheel.dx, wheel.dy }),
        else => bufPrint(&line_buffer, "input: {t}", .{event}),
    } catch return;
    console.log(.info, line);
}

/// The window's input handler: each input message, translated and queued for the next frame.
fn queueInput(message: win32.InputMessage) void {
    native_input.translate(message, &input);
}

/// Hands the engine one event about the window itself - hidden, shown, resized - printing it first when asked, as
/// input events are.
fn deliverWindowEvent(receive_event: EventFunction, event: contract.Event) void {
    if (logs_input) {
        logEvent(event);
    }
    receive_event(event);
}

// ---- Files the person hands the app, and the file it offers to save ----

/// The memory chosen and dropped files are read into while they wait.
const file_heap: Allocator = std.heap.smp_allocator;

/// The most files that wait at once: a file chosen or dropped while the queue is full is left out.
const file_queue_capacity: usize = 16;

/// The room for a path, in UTF-16 code units, and for a file's name and the accepted names, in bytes.
const file_path_room: usize = 1024;
const file_name_room: usize = 256;

/// A file the person chose or dropped, waiting for the app: its name without a path, and its bytes.
const ReceivedFile = struct {
    name: []u8,
    bytes: []u8,
};

/// The dialog a press on one of the app's buttons asked for, opened once the frame's input is delivered.
const FileDialog = enum { none, open, save };

/// The files waiting for the app, the areas of its Load and Save buttons, and the file it offers.
const FileRequests = struct {
    queue: [file_queue_capacity]ReceivedFile = undefined,
    count: usize = 0,
    picker_area: ?contract.ButtonArea = null,
    accept: [file_name_room]u8 = undefined,
    accept_length: usize = 0,
    save_area: ?contract.ButtonArea = null,
    offered_bytes: []u8 = &.{},
    offered_name: [file_name_room]u8 = undefined,
    offered_name_length: usize = 0,
    dialog: FileDialog = .none,
    /// The press that opened a dialog was not the app's, so neither is its release.
    swallows_release: bool = false,
};

// lint:off module-var: the files waiting for the app, and the buttons that ask for them, kept between frames
var files: FileRequests = .{};

pub fn pendingFileCount() u32 {
    return @intCast(files.count);
}

pub fn nextFileSize() u32 {
    if (files.count == 0) {
        return 0;
    }
    return @intCast(files.queue[0].bytes.len);
}

pub fn nextFileName(out: []u8) u32 {
    if (files.count == 0) {
        return 0;
    }
    const name: []const u8 = files.queue[0].name;
    const copied: usize = @min(name.len, out.len);
    @memcpy(out[0..copied], name[0..copied]);
    return @intCast(copied);
}

fn removeOldestFile() void {
    const oldest: ReceivedFile = files.queue[0];
    file_heap.free(oldest.name);
    file_heap.free(oldest.bytes);
    copyForwards(ReceivedFile, files.queue[0..], files.queue[1..files.count]);
    files.count -= 1;
}

/// Copies the oldest file's bytes into `out` and removes it; 0 when `out` is too small, the file kept.
pub fn readNextFile(out: []u8) u32 {
    if (files.count == 0) {
        return 0;
    }
    const bytes: []const u8 = files.queue[0].bytes;
    if (out.len < bytes.len) {
        return 0;
    }
    const byte_count: usize = bytes.len;
    @memcpy(out[0..byte_count], bytes);
    removeOldestFile();
    return @intCast(byte_count);
}

pub fn discardNextFile() void {
    if (files.count > 0) {
        removeOldestFile();
    }
}

pub fn setFilePickerArea(area: contract.ButtonArea, accept: []const u8) void {
    files.picker_area = area;
    const kept: usize = @min(accept.len, files.accept.len);
    @memcpy(files.accept[0..kept], accept[0..kept]);
    files.accept_length = kept;
}

pub fn hideFilePicker() void {
    files.picker_area = null;
}

/// Keeps a copy of the file the Save button saves; with no memory for it, none is offered.
pub fn offerFile(bytes: []const u8, name: []const u8) void {
    file_heap.free(files.offered_bytes);
    files.offered_bytes = file_heap.dupe(u8, bytes) catch &.{};
    const kept: usize = @min(name.len, files.offered_name.len);
    @memcpy(files.offered_name[0..kept], name[0..kept]);
    files.offered_name_length = kept;
}

pub fn setSaveArea(area: contract.ButtonArea) void {
    files.save_area = area;
}

pub fn hideSave() void {
    files.save_area = null;
}

/// Whether the point (logical pixels) is inside `area`.
fn isInsideArea(area: contract.ButtonArea, x: f32, y: f32) bool {
    const is_inside_x: bool = x >= area.x and x < area.x + area.width;
    const is_inside_y: bool = y >= area.y and y < area.y + area.height;
    return is_inside_x and is_inside_y;
}

/// Whether `event` is a press on one of the app's Load or Save buttons, or the release after one: such a press asks
/// for the system's dialog, and neither it nor its release is the app's - as in the browser, where an element of
/// the page over the button takes them.
fn takesFilePress(event: contract.Event) bool {
    switch (event) {
        .mouse_button_down => |press| {
            if (press.button != .left) {
                return false;
            }
            if (files.picker_area) |area| {
                if (isInsideArea(area, press.x, press.y)) {
                    files.dialog = .open;
                    files.swallows_release = true;
                    return true;
                }
            }
            if (files.save_area) |area| {
                const has_offer: bool = files.offered_bytes.len > 0;
                if (has_offer and isInsideArea(area, press.x, press.y)) {
                    files.dialog = .save;
                    files.swallows_release = true;
                    return true;
                }
            }
            return false;
        },
        .mouse_button_up => |release| {
            const is_swallowed: bool = release.button == .left and files.swallows_release;
            if (is_swallowed) {
                files.swallows_release = false;
            }
            return is_swallowed;
        },
        else => return false,
    }
}

/// The Open dialog's filter for the names an app accepts - ".bvh,.fbx", in the browser's form - written into `out`
/// in the dialog's: the accepted patterns ("*.bvh;*.fbx") under a description, then all files, each string
/// null-terminated and an empty string ending the list. A media type such as "image/*" has no pattern there and is
/// left out; with none left, only all files remain.
fn openDialogFilter(accept: []const u8, out: []u16) [*]const u16 {
    var patterns: [file_name_room * 2]u8 = undefined;
    var patterns_length: usize = 0;
    var names = std.mem.tokenizeScalar(u8, accept, ',');
    while (names.next()) |untrimmed| {
        const name: []const u8 = trim(u8, untrimmed, " ");
        const is_extension: bool = name.len > 1 and name[0] == '.';
        const fits: bool = patterns_length + name.len + 2 <= patterns.len;
        if (!is_extension or !fits) {
            continue;
        }
        const separator: []const u8 = if (patterns_length == 0) "*" else ";*";
        @memcpy(patterns[patterns_length..][0..separator.len], separator);
        patterns_length += separator.len;
        @memcpy(patterns[patterns_length..][0..name.len], name);
        patterns_length += name.len;
    }
    var list: [file_name_room * 6]u8 = undefined;
    const accepted: []const u8 = patterns[0..patterns_length];
    const all_files: []const u8 = "All files (*.*)\x00*.*\x00\x00";
    const accepted_format: []const u8 = "Accepted files ({s})\x00{s}\x00" ++ "All files (*.*)\x00*.*\x00\x00";
    const written: []const u8 = if (accepted.len > 0)
        std.fmt.bufPrint(&list, accepted_format, .{ accepted, accepted }) catch all_files
    else
        all_files;
    const units: usize = std.unicode.utf8ToUtf16Le(out, written) catch 0;
    out[units] = 0;
    return out.ptr;
}

/// Whether a handle `CreateFileW` answered is its failure value, all bits set.
fn isFailedFileHandle(handle: win32.HANDLE) bool {
    return @intFromPtr(handle) == ~@as(usize, 0);
}

/// Reads the file at `path` whole into the queue, named by the part of its path after the last separator. A file
/// that cannot be read, or that does not fit - the queue full, or the file past 4 GiB, the most a size in the
/// queue's answers holds - is left out.
fn queueFile(path: [*:0]const u16) void {
    if (files.count == file_queue_capacity) {
        return;
    }
    const handle: win32.HANDLE = win32.CreateFileW(
        path,
        win32.GENERIC_READ,
        win32.FILE_SHARE_READ,
        null,
        win32.OPEN_EXISTING,
        win32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (isFailedFileHandle(handle)) {
        return;
    }
    defer _ = win32.CloseHandle(handle);
    var file_size: i64 = 0;
    const has_size: bool = win32.GetFileSizeEx(handle, &file_size) != 0;
    const most_bytes: i64 = 0xffff_ffff;
    if (!has_size or file_size < 0 or file_size > most_bytes) {
        return;
    }
    const bytes: []u8 = file_heap.alloc(u8, @intCast(file_size)) catch return;
    var read_count: usize = 0;
    while (read_count < bytes.len) {
        var read_now: win32.DWORD = 0;
        const remaining: win32.DWORD = @intCast(bytes.len - read_count);
        const is_read: bool = win32.ReadFile(handle, bytes[read_count..].ptr, remaining, &read_now, null) != 0;
        if (!is_read or read_now == 0) {
            file_heap.free(bytes);
            return;
        }
        read_count += read_now;
    }
    const wide_path: []const u16 = std.mem.span(path);
    const last_separator: ?usize = std.mem.lastIndexOfAny(u16, wide_path, &.{ '\\', '/' });
    const wide_name: []const u16 = if (last_separator) |at| wide_path[at + 1 ..] else wide_path;
    const name: []u8 = std.unicode.utf16LeToUtf8Alloc(file_heap, wide_name) catch {
        file_heap.free(bytes);
        return;
    };
    files.queue[files.count] = .{ .name = name, .bytes = bytes };
    files.count += 1;
}

/// Writes the offered file at `path`, replacing what is there - the Save dialog asked the person first.
fn writeOfferedFile(path: [*:0]const u16) void {
    const handle: win32.HANDLE = win32.CreateFileW(
        path,
        win32.GENERIC_WRITE,
        0,
        null,
        win32.CREATE_ALWAYS,
        win32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (isFailedFileHandle(handle)) {
        return;
    }
    defer _ = win32.CloseHandle(handle);
    var written_count: usize = 0;
    const bytes: []const u8 = files.offered_bytes;
    while (written_count < bytes.len) {
        var written_now: win32.DWORD = 0;
        const remaining: win32.DWORD = @intCast(bytes.len - written_count);
        const write_from: [*]const u8 = bytes[written_count..].ptr;
        const is_written: bool = win32.WriteFile(handle, write_from, remaining, &written_now, null) != 0;
        if (!is_written or written_now == 0) {
            return;
        }
        written_count += written_now;
    }
}

/// Opens the dialog a press asked for: the Open dialog, its file read into the queue; or the Save dialog, the
/// offered file written where the person chose. The dialog is modal: the frames wait while it is open.
fn runFileDialog() void {
    const dialog: FileDialog = files.dialog;
    files.dialog = .none;
    var path: [file_path_room]u16 = undefined;
    switch (dialog) {
        .none => {},
        .open => {
            var filter: [file_name_room * 6]u16 = undefined;
            const filter_list: [*]const u16 = openDialogFilter(files.accept[0..files.accept_length], &filter);
            if (window.chooseFileToOpen(filter_list, &path)) {
                queueFile(@ptrCast(&path));
            }
        },
        .save => {
            const name: []const u8 = files.offered_name[0..files.offered_name_length];
            const name_units: usize = std.unicode.utf8ToUtf16Le(path[0 .. path.len - 1], name) catch 0;
            path[name_units] = 0;
            // The filter and the extension added to a name typed without one come from the offered name's.
            const extension_dot: ?usize = std.mem.lastIndexOfScalar(u8, name, '.');
            const extension: []const u8 = if (extension_dot) |at| name[at + 1 ..] else "";
            var filter: [file_name_room * 6]u16 = undefined;
            var extension_wide: [file_name_room]u16 = undefined;
            const extension_room: []u16 = extension_wide[0 .. extension_wide.len - 1];
            const extension_units: usize = std.unicode.utf8ToUtf16Le(extension_room, extension) catch 0;
            extension_wide[extension_units] = 0;
            var accept: [file_name_room]u8 = undefined;
            const accept_text: []const u8 = std.fmt.bufPrint(&accept, ".{s}", .{extension}) catch "";
            const filter_list: [*]const u16 = openDialogFilter(if (extension.len > 0) accept_text else "", &filter);
            if (window.chooseFileToSave(filter_list, @ptrCast(&extension_wide), &path)) {
                writeOfferedFile(@ptrCast(&path));
            }
        },
    }
}

/// Reads the files of a batch dropped on the window into the queue, then lets the system free the batch.
fn queueDroppedFiles() void {
    const drop: win32.HDROP = window.takeDroppedFiles() orelse return;
    defer win32.DragFinish(drop);
    const count: win32.UINT = win32.DragQueryFileW(drop, 0xffff_ffff, null, 0);
    for (0..count) |index| {
        var path: [file_path_room]u16 = undefined;
        const path_length: win32.UINT = win32.DragQueryFileW(drop, @intCast(index), &path, file_path_room);
        if (path_length == 0 or path_length >= file_path_room) {
            continue;
        }
        path[path_length] = 0;
        queueFile(@ptrCast(&path));
    }
}

/// Hands the queued input to the engine, in order, each converted into the contract's event - printing each first
/// when asked.
fn deliverInput(receive_event: EventFunction) void {
    for (input.pending()) |queued| {
        const event: contract.Event = contract_events.convert(queued);
        if (logs_input) {
            logEvent(event);
        }
        if (takesFilePress(event)) {
            continue;
        }
        receive_event(event);
    }
    input.clear();
    // A dialog a press asked for opens once the frame's input is delivered; dropped files join the queue.
    runFileDialog();
    queueDroppedFiles();
}

pub const OpenError = win32.WindowError || error{ OutOfMemory, WindowUnwritten };

/// Whether this system's window and its loop are written: Windows' only, so far. Elsewhere - the systems the unwritten
/// platform stands for (`platform/unwritten.zig`) - `openWindow`, `run` and `finish` refuse, and the Win32 code they
/// would call is never compiled; the headless loop (`headless`) and the scripts (`script`) are every system's.
const has_window_loop: bool = builtin.target.os.tag == .windows;

/// What the Vulkan host's validation layer counted.
pub const Counts = vulkan_host.MessageCounts;

/// The window's handle, for the system calls that act for a window - the clipboard's owner; null before it opens.
pub fn windowHandle() ?win32.HWND {
    return window.handle;
}

/// Reads the clipboard's text and delivers it as a paste (`win32.Window.requestPaste`).
pub fn requestPaste() void {
    window.requestPaste();
}

/// Fullscreen on or off (`win32.Window.setFullscreen`); the outcome arrives as an event.
pub fn setFullscreen(on: bool) void {
    window.setFullscreen(on);
}

/// Text input on (`win32.Window.setInputMethodEnabled`): the input method composes the keys when `is_composed`; a
/// password's keys go straight on, as a system's own password boxes take them.
pub fn startTextInput(is_composed: bool) void {
    window.setInputMethodEnabled(is_composed);
}

/// Places the input method's windows for a field at `area` (`win32.Window.placeInputMethod`): the area comes in
/// logical pixels, and the window's scale (dpi / 96) turns them into the client pixels the input method takes.
pub fn setTextInputArea(area: contract.TextInputArea) void {
    const scale: f32 = window.scale();
    const field: win32.RECT = .{
        .left = @round(area.x * scale),
        .top = @round(area.y * scale),
        .right = @round((area.x + area.width) * scale),
        .bottom = @round((area.y + area.height) * scale),
    };
    const caret: win32.POINT = .{ .x = @round((area.x + area.caret_x) * scale), .y = field.top };
    window.placeInputMethod(field, caret);
}

/// Text input off: the input method too, until a field takes text again.
pub fn stopTextInput() void {
    window.setInputMethodEnabled(false);
}

/// Sets the window's title bar (`win32.Window.setTitle`).
pub fn setTitle(title: []const u8) void {
    window.setTitle(title);
}

/// Shows a system cursor over the window, or hides it (null) - `win32.Window.setCursorShape`.
pub fn setCursorShape(cursor_id: ?usize) void {
    window.setCursorShape(cursor_id);
}

/// Locks the pointer to the window (`win32.Window.lockPointer`); the outcome arrives as an event.
pub fn requestPointerLock() void {
    window.lockPointer();
}

/// Ends the window's pointer lock; the end arrives as an event.
pub fn releasePointerLock() void {
    window.releasePointerLock();
}

/// The window's drawing area in logical pixels, and its scale - the contract's `size` (`platform/windows.zig`).
pub fn size() contract.Size {
    const scale: f32 = window.scale();
    return .{
        .width = float(window.client_width) / scale,
        .height = float(window.client_height) / scale,
        .scale = scale,
    };
}

/// Opens the program's window and gives it to the Vulkan host.
pub fn openWindow(options: win32.WindowOptions) OpenError!void {
    if (comptime !has_window_loop) {
        console.log(.err, "the window and its loop are not written for this system: the program stops here");
        return error.WindowUnwritten;
    }
    try window.open(options);
    // The input method starts off: it turns on only while a text field takes text (`startTextInput`).
    window.setInputMethodEnabled(false);
    window.input_handler = &queueInput;
    logs_input = readInputLogSetting();
    try vulkan_host.attachWindow(&window);
}

/// A script's run, on whichever loop runs it - a window's (`run`) or a headless run's (`headless`): the lines of a
/// script, commands written in ZON (`native_input.Command`), executed as they are read, so the run is paused whenever
/// it waits for its next line, and more lines resume it. Each frame happens at the time the script gives it, a
/// sixtieth of a second after the one before - however long the run waited between lines - so a script draws the
/// same frames every time it runs, on every platform: its frames on a window and on a headless screen can be compared.
pub const script = struct {
    /// The time between two frames, in milliseconds.
    pub const frame_milliseconds: f64 = 1000.0 / 60.0;
    /// The first frame's time. Not zero: the engine's frame driver takes a previous frame's time of zero to mean
    /// there was none.
    pub const start_milliseconds: f64 = 1000.0;
    /// The longest script line read; a longer one is skipped, as a line that failed.
    pub const line_room: usize = 64 * 1024;
    /// What a run's commands are read with.
    const allocator: Allocator = std.heap.smp_allocator;

    /// Saves the frame last drawn as a PNG file at `path`, its directory made when missing; returns whether it could.
    /// Saves the frame last drawn as a PNG file at `path`, shrunk to `width` pixels across - its height in
    /// proportion - when `width` is less than the frame's; 0 saves it whole. Whether it could.
    pub const CaptureFunction = *const fn (io: Io, path: []const u8, width: u32) bool;

    /// How a run went: the frames it drew, and the lines it could not run.
    pub const Outcome = struct {
        frame_count: u32 = 0,
        failed_line_count: u32 = 0,
    };

    /// What differs between the loops a script runs on: how a frame is drawn - returning false when the loop can draw
    /// no more, its window closed - how the system's paste command is answered, and how the loop waits while a
    /// followed script has no new line yet: a window keeps handling its messages, so that it stays alive and a
    /// person's input still arrives, and returns false once closed.
    pub const Loop = struct {
        draw_frame: *const fn (
            update: UpdateFunction,
            receive_event: EventFunction,
            frame_ms: f64,
        ) bool,
        request_paste: *const fn (receive_event: EventFunction) void,
        wait: *const fn (io: Io, receive_event: EventFunction) bool,
        /// The gamepad a script holds in a slot, given to the platform - null for an empty slot.
        set_gamepad: *const fn (slot: contract.GamepadSlot, pad: ?contract.Gamepad) void,
        /// The sound played so far, written as a WAV file at a path - a run's own sound, so headless only.
        capture_audio: *const fn (io: Io, path: []const u8) CaptureAudioError!void,
    };

    pub const CaptureAudioError = error{ NotHeadless, WriteFailed };

    /// The gamepad slots a script plays, as the contract's platforms have them.
    pub const scripted_gamepad_slots: usize = 4;

    /// Whether a script read from a file is followed as it grows (`ScriptFile`): the `ZIMR_FOLLOW` setting, given and
    /// not "0". A session's caller sets it; a replay of the session's transcript, without it, ends where the file ends.
    pub fn isFollowing() bool {
        var setting_buffer: [16]u8 = undefined;
        const setting: []const u8 = native_os.environmentVariable("ZIMR_FOLLOW", &setting_buffer) orelse return false;
        return !eql(u8, setting, "0");
    }

    /// A script read from a file - followed as it grows, when it is (`isFollowing`): lines are taken whole, up to their
    /// line feed, from reads at the file's offset, so that a line still being appended is never taken half-written.
    /// At the file's end a followed file waits for more (`Loop.wait`), and one not followed ends, its last line taken
    /// even without a line feed.
    pub const ScriptFile = struct {
        io: Io,
        file: Io.File,
        is_followed: bool,
        /// Where the next read starts in the file.
        offset: u64 = 0,
        /// The bytes read and not yet taken, `held[start..end]`.
        held: [line_room]u8 = undefined,
        start: usize = 0,
        end: usize = 0,
        /// Set while the rest of a line longer than `line_room` is dropped, up to its line feed.
        is_dropping_line: bool = false,

        pub const LineError = error{ TooLong, ReadFailed };

        /// The next line, without its line feed, valid until the next call; null at the end of a file not followed,
        /// or when the loop can wait no more. A line longer than `line_room` is reported once (`TooLong`), and its
        /// rest dropped.
        fn nextLine(
            script_file: *ScriptFile,
            loop: Loop,
            receive_event: EventFunction,
        ) LineError!?[]const u8 {
            while (true) {
                const unread: []u8 = script_file.held[script_file.start..script_file.end];
                if (indexOfScalar(u8, unread, '\n')) |newline_index| {
                    script_file.start += newline_index + 1;
                    if (script_file.is_dropping_line) {
                        script_file.is_dropping_line = false;
                        continue;
                    }
                    return unread[0..newline_index];
                }
                // No whole line is held: what is held moves to the front, and the next read lands after it.
                copyForwards(u8, script_file.held[0..unread.len], unread);
                script_file.start = 0;
                script_file.end = unread.len;
                if (script_file.end == script_file.held.len) {
                    script_file.end = 0;
                    if (!script_file.is_dropping_line) {
                        script_file.is_dropping_line = true;
                        return LineError.TooLong;
                    }
                    continue;
                }
                const room: []u8 = script_file.held[script_file.end..];
                const read_count: usize = script_file.file.readPositional(
                    script_file.io,
                    &.{room},
                    script_file.offset,
                ) catch return LineError.ReadFailed;
                if (read_count > 0) {
                    script_file.end += read_count;
                    script_file.offset += read_count;
                    continue;
                }
                // The file's end, for now.
                if (!script_file.is_followed) {
                    const has_last_line: bool = script_file.end > 0 and !script_file.is_dropping_line;
                    if (!has_last_line) {
                        return null;
                    }
                    const last_line: []u8 = script_file.held[0..script_file.end];
                    script_file.end = 0;
                    return last_line;
                }
                if (!loop.wait(script_file.io, receive_event)) {
                    return null;
                }
            }
        }
    };

    /// Where a script's lines come from: a file (`ScriptFile`), or a reader - the standard input, a fixed text.
    pub const LineSource = union(enum) {
        file: *ScriptFile,
        reader: *Io.Reader,
    };

    /// A run in progress: what executing a script's lines needs, and what they have done so far.
    pub const Session = struct {
        io: Io,
        loop: Loop,
        update: UpdateFunction,
        receive_event: EventFunction,
        capture: CaptureFunction,
        replies: *Io.Writer,
        person: native_input.ScriptedPerson = .{},
        /// The gamepads the script holds, by slot: connected by `gamepad_connect`, changed by `gamepad_button` and
        /// `gamepad_axis`, emptied by `gamepad_disconnect` - each change handed to the loop whole (`Loop.set_gamepad`).
        gamepads: [scripted_gamepad_slots]?contract.Gamepad = @splat(null),
        outcome: Outcome = .{},
        line_number: usize = 0,
        /// Set when the loop can draw no more: the rest of the script is not run.
        is_stopped: bool = false,

        /// Runs every line `source` gives, until its end, a `quit`, or the loop's stopping. The app first gains the
        /// keyboard's focus, as a window opening does.
        pub fn runLines(session: *Session, source: LineSource) void {
            session.receive_event(.focus_gained);
            while (!session.is_stopped) {
                const next_line: ?[]const u8 = switch (source) {
                    .file => |script_file| script_file.nextLine(session.loop, session.receive_event) catch |err| {
                        switch (err) {
                            error.TooLong => {
                                session.line_number += 1;
                                session.fail("a line longer than {d} bytes", .{line_room});
                                continue;
                            },
                            error.ReadFailed => {
                                session.fail("the script could not be read further", .{});
                                return;
                            },
                        }
                    },
                    .reader => |reader| reader.takeDelimiter('\n') catch |err| switch (err) {
                        error.StreamTooLong => {
                            session.line_number += 1;
                            session.fail("a line longer than {d} bytes", .{line_room});
                            _ = reader.discardDelimiterInclusive('\n') catch return;
                            continue;
                        },
                        error.ReadFailed => {
                            session.fail("the script could not be read further", .{});
                            return;
                        },
                    },
                };
                const read_line: []const u8 = next_line orelse return;
                session.line_number += 1;
                // A file written on Windows may start with UTF-8's byte order mark, which is not part of its text.
                const byte_order_mark: []const u8 = "\xef\xbb\xbf";
                const starts_with_mark: bool = session.line_number == 1 and startsWith(u8, read_line, byte_order_mark);
                const line: []const u8 = if (starts_with_mark) read_line[byte_order_mark.len..] else read_line;
                if (native_input.isBlankLine(line)) {
                    continue;
                }
                // The command's strings and the diagnostics live as long as the line.
                var line_arena: ArenaAllocator = .init(allocator);
                defer line_arena.deinit();
                var diagnostics: std.zon.parse.Diagnostics = undefined;
                const parsed: native_input.ParseError!native_input.Command = native_input.parseCommand(
                    allocator,
                    line_arena.allocator(),
                    line,
                    &diagnostics,
                );
                const command: native_input.Command = parsed catch |err| {
                    switch (err) {
                        error.ParseZon => session.fail("not a command: {f}", .{diagnostics.fmt("script")}),
                        error.TooManyFrames => session.fail("more than {d} frames at once", .{
                            native_input.most_frames_per_advance,
                        }),
                        error.OutOfMemory => session.fail("no memory to read it", .{}),
                    }
                    continue;
                };
                if (command == .quit) {
                    return;
                }
                session.execute(command);
            }
        }

        fn execute(session: *Session, command: native_input.Command) void {
            switch (command) {
                .advance => |frame_count| session.drawFrames(frame_count),
                .capture => session.captureFrame(null, 0),
                .capture_to => |path| session.captureFrame(path, 0),
                .capture_thumbnail => |thumbnail| session.captureFrame(thumbnail.path, thumbnail.width),
                .capture_audio_to => |path| session.captureAudio(path),
                .sync => |token| session.reply("synced {s}", .{token}),
                .quit => {},
                .move, .press, .release, .wheel, .key_down, .key_up, .text, .paste => session.deliverInput(command),
                .gamepad_connect, .gamepad_disconnect, .gamepad_button, .gamepad_axis => session.playGamepad(command),
            }
        }

        /// Saves the sound played so far as a WAV file (`Loop.capture_audio`), and replies with its path.
        fn captureAudio(session: *Session, path: []const u8) void {
            session.loop.capture_audio(session.io, path) catch |err| switch (err) {
                error.NotHeadless => {
                    session.fail("audio capture runs headless: a window's sound goes to its device", .{});
                    return;
                },
                error.WriteFailed => {
                    session.fail("the sound could not be written to {s}", .{path});
                    return;
                },
            };
            session.reply("captured audio {s}", .{path});
        }

        /// Plays a gamepad command: connects a gamepad - every button up, the sticks centred - empties a slot, or
        /// changes a button or an axis of a connected one; then hands the slot's gamepad to the loop. A slot past the
        /// four, or a change to an empty slot, fails the line.
        fn playGamepad(session: *Session, command: native_input.Command) void {
            const slot: contract.GamepadSlot = switch (command) {
                .gamepad_connect, .gamepad_disconnect => |command_slot| command_slot,
                .gamepad_button => |button_value| button_value.slot,
                .gamepad_axis => |axis_value| axis_value.slot,
                else => unreachable,
            };
            if (slot >= scripted_gamepad_slots) {
                session.fail("gamepad slot {d}: there are {d} slots", .{ slot, scripted_gamepad_slots });
                return;
            }
            switch (command) {
                .gamepad_connect => session.gamepads[slot] = .{ .buttons = .initFill(0), .axes = .initFill(0) },
                .gamepad_disconnect => session.gamepads[slot] = null,
                .gamepad_button => |button_value| {
                    const pad: *contract.Gamepad = if (session.gamepads[slot]) |*connected| connected else {
                        session.fail("gamepad slot {d} has no gamepad: connect one first", .{slot});
                        return;
                    };
                    pad.buttons.set(button_value.button, button_value.value);
                },
                .gamepad_axis => |axis_value| {
                    const pad: *contract.Gamepad = if (session.gamepads[slot]) |*connected| connected else {
                        session.fail("gamepad slot {d} has no gamepad: connect one first", .{slot});
                        return;
                    };
                    pad.axes.set(axis_value.axis, axis_value.value);
                },
                else => unreachable,
            }
            session.loop.set_gamepad(slot, session.gamepads[slot]);
        }

        /// Delivers the events an input command makes, as a window delivers its messages; a key going down that is
        /// the system's paste command is answered as the loop answers it.
        fn deliverInput(session: *Session, command: native_input.Command) void {
            var events: [native_input.ScriptedPerson.most_events_per_command]contract.Event = undefined;
            for (session.person.eventsFor(command, &events)) |event| {
                session.receive_event(event);
                const is_paste_command: bool = switch (event) {
                    .key_down => |down| native_input.isPasteCommand(down),
                    else => false,
                };
                if (is_paste_command) {
                    session.loop.request_paste(session.receive_event);
                }
            }
        }

        /// Draws frames, each at its time on the script's clock.
        fn drawFrames(session: *Session, frame_count: u32) void {
            for (0..frame_count) |_| {
                const frame_ms: f64 = start_milliseconds + float(session.outcome.frame_count) * frame_milliseconds;
                if (!session.loop.draw_frame(session.update, session.receive_event, frame_ms)) {
                    session.is_stopped = true;
                    return;
                }
                session.outcome.frame_count += 1;
            }
        }

        /// Saves the frame last drawn, at `path` or as frame_<n>.png in the capture directory, and replies with the
        /// file written.
        fn captureFrame(session: *Session, path: ?[]const u8, width: u32) void {
            if (session.outcome.frame_count == 0) {
                session.fail("nothing has been drawn yet to capture", .{});
                return;
            }
            var directory_buffer: [512]u8 = undefined;
            var path_buffer: [600]u8 = undefined;
            const last_frame_index: u32 = session.outcome.frame_count - 1;
            const capture_path: []const u8 = path orelse bufPrint(&path_buffer, "{s}/frame_{d}.png", .{
                captureDirectory(&directory_buffer),
                last_frame_index,
            }) catch {
                session.fail("the capture directory's name is too long", .{});
                return;
            };
            if (!session.capture(session.io, capture_path, width)) {
                session.fail("capturing to {s} failed", .{capture_path});
                return;
            }
            session.reply("captured {s}", .{capture_path});
        }

        /// One reply line, sent at once: a session's caller waits for it.
        fn reply(
            session: *Session,
            comptime format: []const u8,
            arguments: anytype,
        ) void {
            // lint:off catch-suppression: with the replies' destination gone, no reply can reach anyone
            session.replies.print(format ++ "\n", arguments) catch {};
            // lint:off catch-suppression: (as above)
            session.replies.flush() catch {};
        }

        /// A line that could not run: reported with its number, counted, and skipped - a session survives it.
        fn fail(
            session: *Session,
            comptime format: []const u8,
            arguments: anytype,
        ) void {
            session.outcome.failed_line_count += 1;
            var message_buffer: [line_room + 128]u8 = undefined;
            const message: []const u8 = bufPrint(&message_buffer, format, arguments) catch "(a message too long)";
            script_log.err("line {d}: {s}", .{ session.line_number, message });
        }
    };

    /// The directory captured frames are written into when a `capture` names no path: the `ZIMR_CAPTURE_DIR`
    /// setting's, or the working directory.
    pub fn captureDirectory(buffer: []u8) []const u8 {
        return native_os.environmentVariable("ZIMR_CAPTURE_DIR", buffer) orelse ".";
    }

    /// The size of the frame last drawn, in pixels: width, then height (`vulkan_host.lastFrameSize`).
    pub fn lastFrameSize() [2]u32 {
        return vulkan_host.lastFrameSize();
    }

    /// Reads the frame last drawn back as 8-bit RGBA rows, top to bottom (`vulkan_host.readLastFrame`). Returns
    /// whether it could.
    pub fn readLastFrame(out: []u8) bool {
        vulkan_host.readLastFrame(out) catch return false;
        return true;
    }
};

// ---- Monitors ----

/// The most monitors listed; more are left out.
const monitor_capacity: usize = 16;

/// One monitor as Windows knows it: its handle, its rectangle's corner on the desktop in physical pixels and its DPI
/// - what placing a window on it needs - and its description for the contract.
const KnownMonitor = struct {
    handle: *anyopaque,
    physical_left: i32,
    physical_top: i32,
    dpi: u32,
    description: contract.Monitor,
};

/// The monitors, listed once and kept (`knownMonitors`): listing them asks Windows for each one's information, scale,
/// display configuration and mode - the last from the display driver, which can be slow - so they are listed again
/// only after a message says they changed (`win32.Window.monitors_changed`).
const MonitorList = struct {
    monitors: [monitor_capacity]KnownMonitor = undefined,
    count: usize = 0,
    is_current: bool = false,
};

// lint:off module-var: the monitors, listed once and kept until Windows says they changed
var monitor_list: MonitorList = .{};

/// The monitors' handles, gathered by `EnumDisplayMonitors`' callback.
const MonitorHandles = struct {
    handles: [monitor_capacity]*anyopaque = undefined,
    count: usize = 0,
};

/// `EnumDisplayMonitors`' callback: adds each monitor's handle to the list `data` points to, and goes on.
fn gatherMonitor(
    monitor_handle: ?*anyopaque,
    device_context: ?*anyopaque,
    rect: ?*win32.RECT,
    data: win32.LPARAM,
) callconv(.winapi) win32.BOOL {
    _ = device_context;
    _ = rect;
    const handles: *MonitorHandles = @ptrFromInt(@as(usize, @bitCast(data)));
    const handle: *anyopaque = monitor_handle orelse return 1;
    if (handles.count < monitor_capacity) {
        handles.handles[handles.count] = handle;
        handles.count += 1;
    }
    return 1;
}

/// What the display configuration tells of one active monitor (`readDisplayPaths`): the GDI device name it is known
/// by, the monitor's own name from its EDID, and its exact refresh rate, a ratio.
const DisplayPath = struct {
    device_name: [32]u16,
    friendly_name: [64]u16,
    refresh_numerator: u32,
    refresh_denominator: u32,
};

/// The display configuration's paths, found by device name (`find`).
const DisplayPaths = struct {
    paths: [monitor_capacity]DisplayPath = undefined,
    count: usize = 0,

    /// The path of the monitor whose GDI device name is `device_name`, if the configuration has one.
    fn find(display_paths: *const DisplayPaths, device_name: []const u16) ?*const DisplayPath {
        for (display_paths.paths[0..display_paths.count]) |*path| {
            if (eql(u16, sliceTo(&path.device_name, 0), device_name)) {
                return path;
            }
        }
        return null;
    }
};

/// The active displays' names and exact refresh rates (`win32.QueryDisplayConfig`): each path's source named
/// (`DISPLAYCONFIG_SOURCE_DEVICE_NAME`), to find its monitor by, and its target (`DISPLAYCONFIG_TARGET_DEVICE_NAME`).
/// Empty when Windows cannot say - the monitors are then named by device and rated by their display mode.
fn readDisplayPaths() DisplayPaths {
    var found: DisplayPaths = .{};
    var path_count: u32 = 0;
    var mode_count: u32 = 0;
    if (win32.GetDisplayConfigBufferSizes(win32.QDC_ONLY_ACTIVE_PATHS, &path_count, &mode_count) != 0) {
        return found;
    }
    var path_infos: [monitor_capacity * 2]win32.DISPLAYCONFIG_PATH_INFO = undefined;
    var mode_infos: [monitor_capacity * 4]win32.DISPLAYCONFIG_MODE_INFO = undefined;
    if (path_count > path_infos.len or mode_count > mode_infos.len) {
        return found;
    }
    const query_status: win32.LONG = win32.QueryDisplayConfig(
        win32.QDC_ONLY_ACTIVE_PATHS,
        &path_count,
        &path_infos,
        &mode_count,
        &mode_infos,
        null,
    );
    if (query_status != 0) {
        return found;
    }
    for (path_infos[0..path_count]) |path_info| {
        if (found.count == found.paths.len) {
            break;
        }
        var source_name: win32.DISPLAYCONFIG_SOURCE_DEVICE_NAME = zeroes(win32.DISPLAYCONFIG_SOURCE_DEVICE_NAME);
        source_name.header = .{
            .type = win32.DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME,
            .size = @sizeOf(win32.DISPLAYCONFIG_SOURCE_DEVICE_NAME),
            .adapterId = path_info.sourceInfo.adapterId,
            .id = path_info.sourceInfo.id,
        };
        if (win32.DisplayConfigGetDeviceInfo(&source_name.header) != 0) {
            continue;
        }
        var target_name: win32.DISPLAYCONFIG_TARGET_DEVICE_NAME = zeroes(win32.DISPLAYCONFIG_TARGET_DEVICE_NAME);
        target_name.header = .{
            .type = win32.DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME,
            .size = @sizeOf(win32.DISPLAYCONFIG_TARGET_DEVICE_NAME),
            .adapterId = path_info.targetInfo.adapterId,
            .id = path_info.targetInfo.id,
        };
        const has_target_name: bool = win32.DisplayConfigGetDeviceInfo(&target_name.header) == 0;
        found.paths[found.count] = .{
            .device_name = source_name.viewGdiDeviceName,
            .friendly_name = if (has_target_name) target_name.monitorFriendlyDeviceName else @splat(0),
            .refresh_numerator = path_info.targetInfo.refreshRate.Numerator,
            .refresh_denominator = path_info.targetInfo.refreshRate.Denominator,
        };
        found.count += 1;
    }
    return found;
}

/// One monitor, known: its rectangle and flags (`GetMonitorInfoW`), its scale - its effective DPI over 96
/// (`GetDpiForMonitor`) - and its description. The rectangle, divided by the scale, is in the monitor's own logical
/// pixels. The refresh rate is the display configuration's exact ratio, or else the display mode's whole hertz
/// (`EnumDisplaySettingsW`); the name is the monitor's own, or else its device's (`\\.\DISPLAY1`).
fn knowMonitor(handle: *anyopaque, display_paths: *const DisplayPaths) KnownMonitor {
    var info: win32.MONITORINFOEXW = zeroes(win32.MONITORINFOEXW);
    info.cbSize = @sizeOf(win32.MONITORINFOEXW);
    _ = win32.GetMonitorInfoW(handle, @ptrCast(&info));
    var dpi_x: win32.UINT = 96;
    var dpi_y: win32.UINT = 96;
    _ = win32.GetDpiForMonitor(handle, win32.MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y);
    const scale: f32 = float(dpi_x) / 96.0;
    const device_name: []const u16 = sliceTo(&info.szDevice, 0);
    const path: ?*const DisplayPath = display_paths.find(device_name);
    var refresh_hz: f32 = 0;
    if (path) |display_path| {
        if (display_path.refresh_denominator != 0) {
            refresh_hz = float(display_path.refresh_numerator) / float(display_path.refresh_denominator);
        }
    }
    if (refresh_hz == 0) {
        var mode: win32.DEVMODEW = zeroes(win32.DEVMODEW);
        mode.dmSize = @sizeOf(win32.DEVMODEW);
        const device_name_z: [*:0]const u16 = @ptrCast(&info.szDevice);
        if (win32.EnumDisplaySettingsW(device_name_z, win32.ENUM_CURRENT_SETTINGS, &mode) != 0) {
            refresh_hz = float(mode.dmDisplayFrequency);
        }
    }
    const rect: win32.RECT = info.rcMonitor;
    var described: contract.Monitor = .{
        .x = float(rect.left) / scale,
        .y = float(rect.top) / scale,
        .width = float(rect.right - rect.left) / scale,
        .height = float(rect.bottom - rect.top) / scale,
        .scale = scale,
        .refresh_hz = refresh_hz,
        .is_primary = info.dwFlags & win32.MONITORINFOF_PRIMARY != 0,
    };
    const friendly_name: []const u16 = if (path) |display_path| sliceTo(&display_path.friendly_name, 0) else &.{};
    const name_units: []const u16 = if (friendly_name.len > 0) friendly_name else device_name;
    var name_bytes: [256]u8 = undefined;
    const name_byte_count: usize = std.unicode.utf16LeToUtf8(&name_bytes, name_units) catch 0;
    described.setName(name_bytes[0..name_byte_count]);
    return .{
        .handle = handle,
        .physical_left = rect.left,
        .physical_top = rect.top,
        .dpi = dpi_x,
        .description = described,
    };
}

/// Lists the monitors into `list`: their handles (`EnumDisplayMonitors`), then each one known (`knowMonitor`), the
/// display configuration read once for them all.
fn listMonitors(list: *MonitorList) void {
    var handles: MonitorHandles = .{};
    _ = win32.EnumDisplayMonitors(null, null, &gatherMonitor, @bitCast(@intFromPtr(&handles)));
    const display_paths: DisplayPaths = readDisplayPaths();
    for (handles.handles[0..handles.count], 0..) |handle, index| {
        list.monitors[index] = knowMonitor(handle, &display_paths);
    }
    list.count = handles.count;
    list.is_current = true;
}

/// The monitors: the kept list, listed again first when Windows has said they changed since.
fn knownMonitors() []const KnownMonitor {
    if (window.monitors_changed) {
        window.monitors_changed = false;
        monitor_list.is_current = false;
    }
    if (!monitor_list.is_current) {
        listMonitors(&monitor_list);
    }
    return monitor_list.monitors[0..monitor_list.count];
}

/// How many monitors there are.
pub fn monitorCount() u32 {
    return @intCast(knownMonitors().len);
}

/// A monitor's description; null past the count.
pub fn monitor(index: u32) ?contract.Monitor {
    const known: []const KnownMonitor = knownMonitors();
    if (index >= known.len) {
        return null;
    }
    return known[index].description;
}

/// The monitor holding most of the window, as `MonitorFromWindow` finds it.
pub fn currentMonitor() u32 {
    const known: []const KnownMonitor = knownMonitors();
    const window_handle: win32.HWND = window.handle orelse return 0;
    const current: *anyopaque = win32.MonitorFromWindow(window_handle, win32.MONITOR_DEFAULTTONEAREST) orelse return 0;
    for (known, 0..) |known_monitor, index| {
        if (known_monitor.handle == current) {
            return @intCast(index);
        }
    }
    return 0;
}

// ---- How the window is shown, and where ----

/// The app asks to end: the flag the close button's message sets (`WM_CLOSE`) is set, so the next pass of the window's
/// loop (`serviceWindow`) answers `.closed` and the run's own teardown follows - the GPU released, the allocator's
/// leaks counted - exactly as when the person closes the window.
pub fn requestQuit() void {
    window.close_requested = true;
}

/// Minimizes, maximizes or restores the window. A fullscreen window already covers its monitor: maximizing it does
/// nothing, as with GLFW.
pub fn showWindow(show: contract.WindowShow) void {
    if (show == .maximized and window.is_fullscreen) {
        return;
    }
    const command: i32 = switch (show) {
        .normal => win32.SW_RESTORE,
        .minimized => win32.SW_MINIMIZE,
        .maximized => win32.SW_MAXIMIZE,
    };
    window.show(command);
}

/// Asks to bring the window to the front (`win32.Window.bringToFront`).
pub fn focusWindow() void {
    window.bringToFront();
}

/// Places the window's drawing area - its client area - on monitor `monitor_index`, its top-left corner (`x`, `y`)
/// logical pixels from the monitor's own: the offset converted at that monitor's scale and added to the monitor's
/// corner in physical pixels, the frame placed around (`win32.Window.moveClientTo`). A fullscreen window, covering
/// its monitor, and a monitor past the count leave the window where it is.
pub fn setWindowPosition(monitor_index: u32, x: f32, y: f32) void {
    if (window.is_fullscreen) {
        return;
    }
    const known: []const KnownMonitor = knownMonitors();
    if (monitor_index >= known.len) {
        return;
    }
    const target: KnownMonitor = known[monitor_index];
    const target_scale: f32 = float(target.dpi) / 96.0;
    const offset_x: i32 = @round(x * target_scale);
    const offset_y: i32 = @round(y * target_scale);
    window.moveClientTo(target.physical_left + offset_x, target.physical_top + offset_y, target.dpi);
}

/// The drawing area's size limits, in logical pixels: kept by the window, which applies them whenever Windows asks,
/// and at once to a window now outside them (`win32.Window.applySizeLimits`).
pub fn setWindowSizeLimits(limits: contract.SizeLimits) void {
    window.min_client_width = limits.min_width;
    window.min_client_height = limits.min_height;
    window.max_client_width = limits.max_width;
    window.max_client_height = limits.max_height;
    window.applySizeLimits();
}

/// What one pass of the window's loop found, once its messages were handled (`serviceWindow`).
const WindowPass = enum {
    /// A frame can be drawn.
    draw,
    /// The window is minimized: nothing can be shown, so no frame is drawn.
    hidden,
    /// The window was closed.
    closed,
};

// lint:off module-var: what the engine was last told of the window, so each pass reports only what changed
var reported_hidden: bool = false;
// lint:off module-var: (see `reported_hidden`)
var reported_size: contract.Size = .{ .width = 0, .height = 0, .scale = 1 };

/// One pass of the window's loop before a frame: handles every waiting message, reports what changed about the window
/// - minimized means hidden, and a change of size or scale is a resize - and hands the input to the engine as the
/// contract's events.
fn serviceWindow(receive_event: EventFunction) WindowPass {
    window.pump();
    if (window.close_requested) {
        return .closed;
    }
    if (window.minimized != reported_hidden) {
        reported_hidden = window.minimized;
        deliverWindowEvent(receive_event, if (reported_hidden) .hidden else .shown);
    }
    if (window.minimized) {
        return .hidden;
    }
    const current_size: contract.Size = size();
    const is_resized: bool = current_size.width != reported_size.width or
        current_size.height != reported_size.height or current_size.scale != reported_size.scale;
    if (is_resized) {
        reported_size = current_size;
        deliverWindowEvent(receive_event, .{ .resized = current_size });
    }
    // The pass's input arrived now, as far as the frame's wait can tell (`waitForFrame` hands it over as it comes).
    contract_events.arrival_ms = native_os.monotonicMilliseconds();
    deliverInput(receive_event);
    return .draw;
}

/// How long the frame's wait sleeps between its askings, in units of 100 ns: a millisecond.
const frame_wait_step_100ns: i64 = 10_000;

/// The frame's wait, before the frame: until the next frame can begin without waiting inside it - the frame slot free
/// and a swapchain image in hand (`vulkan_host.tryAcquireAhead`) - the window's messages are handled as they arrive
/// (`serviceWindow`), so that input reaches the engine, and an app's `on_input`, the moment it comes rather than at
/// the next frame; the frame then draws at the display's pace, as before.
///
/// Between askings the thread sleeps on the message queue and a high-resolution waitable timer together
/// (`MsgWaitForMultipleObjectsEx`), waking for a message at once and otherwise after a millisecond. The timer must be
/// a high-resolution one (Windows 10 version 1803 and later): an ordinary timer, or a timeout, waits for the system's
/// tick - 15.6 ms unless a program asks for less - and the frame could start a refresh late. Where the system has
/// none, there is no wait here: the frame waits inside its own acquire, as before this wait existed, and its input is
/// read at its start. A window minimized or closed during the wait ends it, with what the loop does for it.
fn waitForFrame(receive_event: EventFunction) WindowPass {
    if (!has_asked_for_frame_wait_timer) {
        has_asked_for_frame_wait_timer = true;
        frame_wait_timer = win32.CreateWaitableTimerExW(
            null,
            null,
            win32.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
            win32.TIMER_ALL_ACCESS,
        );
    }
    const timer: win32.HANDLE = frame_wait_timer orelse return .draw;
    while (!vulkan_host.tryAcquireAhead()) {
        // Due one step from now - a negative due time is relative. Setting the timer also clears a signal left from
        // an earlier wait, so this wait ends at the step, or at a message.
        const due_in_one_step: i64 = -frame_wait_step_100ns;
        _ = win32.SetWaitableTimer(timer, &due_in_one_step, 0, null, null, 0);
        const wait_handles: [1]win32.HANDLE = .{timer};
        _ = win32.MsgWaitForMultipleObjectsEx(
            1,
            &wait_handles,
            win32.INFINITE,
            win32.QS_ALLINPUT,
            win32.MWMO_INPUTAVAILABLE,
        );
        // Whichever woke it - a message, or the step - the window's messages are handled and its input handed over.
        const pass: WindowPass = serviceWindow(receive_event);
        if (pass != .draw) {
            return pass;
        }
    }
    return .draw;
}

/// A script's frames in the window: each pass handles the window's messages - the window stays alive and can be
/// watched, and a person's own input still arrives - and draws at the script's time. Minimized, the script waits for
/// the window to show again; closed, it stops.
fn drawScriptedWindowFrame(
    update: UpdateFunction,
    receive_event: EventFunction,
    frame_ms: f64,
) bool {
    while (true) {
        switch (serviceWindow(receive_event)) {
            .draw => {
                update(frame_ms);
                return true;
            },
            .hidden => win32.Sleep(16),
            .closed => return false,
        }
    }
}

/// The paste command in a window: the clipboard's text, read and delivered with the next frame's input.
fn requestWindowPaste(receive_event: EventFunction) void {
    _ = receive_event;
    window.requestPaste();
}

/// A gamepad slot as a script in a window plays it: untouched - the real gamepad, read through XInput - or the
/// script's, connected or empty, which the platform answers with instead (`scriptedGamepad`), so that a script runs
/// alike in a window and headless.
const ScriptedSlot = union(enum) {
    real,
    scripted: ?contract.Gamepad,
};

// lint:off module-var: the gamepad slots a script in a window has taken over, by slot
var scripted_slots: [script.scripted_gamepad_slots]ScriptedSlot = @splat(.real);

/// A window's sound goes to its device: there is no run's own sound to capture.
fn captureWindowAudio(io: Io, path: []const u8) script.CaptureAudioError!void {
    _ = io;
    _ = path;
    return error.NotHeadless;
}

/// A script's gamepad in a window's slot (`Loop.set_gamepad`): from now on the slot answers with it.
fn setWindowGamepad(slot: contract.GamepadSlot, pad: ?contract.Gamepad) void {
    if (slot < scripted_slots.len) {
        scripted_slots[slot] = .{ .scripted = pad };
    }
}

/// The slot as a script plays it, or null for a slot no script has taken over - read through XInput.
pub fn scriptedGamepad(slot: contract.GamepadSlot) ?ScriptedSlot {
    if (slot >= scripted_slots.len) {
        return null;
    }
    return switch (scripted_slots[slot]) {
        .real => null,
        .scripted => scripted_slots[slot],
    };
}

/// Waiting for a followed script's next line in a window: the window's messages are handled - it stays alive, and a
/// person's input reaches the engine, for the next frame - then the loop sleeps briefly. Returns false once closed.
fn waitInWindow(io: Io, receive_event: EventFunction) bool {
    _ = io;
    if (serviceWindow(receive_event) == .closed) {
        return false;
    }
    win32.Sleep(10);
    return true;
}

/// Runs the script at `script_path` in the window: the frames it draws are shown as they are drawn, each frame is kept
/// for `capture` (`vulkan_host.keepPresentedFrames`), and the replies go to a file beside the script,
/// `<script>.replies` - a program with a window has no console to print them to. The window closes when the script
/// ends.
fn runScriptInWindow(
    update: UpdateFunction,
    receive_event: EventFunction,
    capture: script.CaptureFunction,
    script_path: []const u8,
) script.Outcome {
    var threaded: Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io: Io = threaded.io();
    const script_file: Io.File = Io.Dir.cwd().openFile(io, script_path, .{}) catch |err| {
        script_log.err("opening the script {s} failed: {s}", .{ script_path, @errorName(err) });
        return .{ .failed_line_count = 1 };
    };
    defer script_file.close(io);
    var replies_path_buffer: [600]u8 = undefined;
    const replies_path: []const u8 = bufPrint(&replies_path_buffer, "{s}.replies", .{script_path}) catch {
        script_log.err("the script's path is too long", .{});
        return .{ .failed_line_count = 1 };
    };
    const replies_file: Io.File = Io.Dir.cwd().createFile(io, replies_path, .{}) catch |err| {
        script_log.err("making {s} failed: {s}", .{ replies_path, @errorName(err) });
        return .{ .failed_line_count = 1 };
    };
    defer replies_file.close(io);
    var reply_buffer: [1024]u8 = undefined;
    var replies: Io.File.Writer = replies_file.writer(io, &reply_buffer);
    vulkan_host.keepPresentedFrames(true);
    var session: script.Session = .{
        .io = io,
        .loop = .{
            .draw_frame = &drawScriptedWindowFrame,
            .request_paste = &requestWindowPaste,
            .wait = &waitInWindow,
            .set_gamepad = &setWindowGamepad,
            .capture_audio = &captureWindowAudio,
        },
        .update = update,
        .receive_event = receive_event,
        .capture = capture,
        .replies = &replies.interface,
    };
    var followed_file: script.ScriptFile = .{ .io = io, .file = script_file, .is_followed = script.isFollowing() };
    session.runLines(.{ .file = &followed_file });
    const outcome: script.Outcome = session.outcome;
    script_log.info("{d} frames run; {d} lines failed", .{ outcome.frame_count, outcome.failed_line_count });
    return session.outcome;
}

/// Runs the window's frames until it is closed, each at the time it starts on the system's clock - or, when the
/// `ZIMR_SCRIPT` setting names a script, runs the script in the window (`runScriptInWindow`) and returns how it went.
pub fn run(
    update: UpdateFunction,
    receive_event: EventFunction,
    capture: script.CaptureFunction,
) ?script.Outcome {
    if (comptime !has_window_loop) {
        // No window was opened (`openWindow`): no frames to run.
        return null;
    }
    reported_size = size();
    var setting_buffer: [512]u8 = undefined;
    if (native_os.environmentVariable("ZIMR_SCRIPT", &setting_buffer)) |script_path| {
        return runScriptInWindow(update, receive_event, capture, script_path);
    }
    while (true) {
        const pass: WindowPass = switch (serviceWindow(receive_event)) {
            // The frame's wait, here, input handed over as it arrives (`waitForFrame`).
            .draw => waitForFrame(receive_event),
            else => |other| other,
        };
        switch (pass) {
            .draw => update(native_os.monotonicMilliseconds()),
            .hidden => win32.Sleep(16),
            .closed => return null,
        }
    }
}

/// A headless run's frames (`host.kind == .headless`): no window - the Vulkan host draws into a screen of the app's
/// size (`vulkan_host.startHeadlessWithScreen`) - and no person: a script stands for one (`script`). The script is the
/// file `ZIMR_SCRIPT` names - followed as it grows when `ZIMR_FOLLOW` is set, for a live session - or the standard
/// input when it names "-"; with no script, the run draws a second of frames. Replies go to the standard output, one
/// line each; the log goes to the standard error.
pub const headless = struct {
    /// What a run does without a script: a second of frames.
    const default_script: []const u8 = ".{ .advance = 60 }\n";

    /// A headless frame: the platform's outcomes for the app delivered first (a paste it asked for, a lock granted),
    /// as a window's loop delivers its queued messages, then the frame drawn at its time. The loop never stops.
    /// One frame, headless: the sound due by its time plays first, as a device would have played it meanwhile
    /// (`headless_platform.playAudioUntil`); then the frame's events, and the engine's update.
    fn drawHeadlessFrame(
        update: UpdateFunction,
        receive_event: EventFunction,
        frame_ms: f64,
    ) bool {
        headless_platform.playAudioUntil(frame_ms);
        deliverPlatformEvents(receive_event);
        update(frame_ms);
        // An app that asked to end in this frame ends the run after it, as the script's `.quit` would.
        const run_goes_on: bool = !headless_platform.isQuitRequested();
        return run_goes_on;
    }

    /// The run's own sound, written as a WAV file (`headless_platform.writeAudioCapture`).
    fn captureHeadlessAudio(io: Io, path: []const u8) script.CaptureAudioError!void {
        headless_platform.writeAudioCapture(io, path) catch return error.WriteFailed;
    }

    /// The paste command, headless: the platform's clipboard, delivered at once, right after the key - as on Windows.
    fn requestHeadlessPaste(receive_event: EventFunction) void {
        headless_platform.requestPaste();
        deliverPlatformEvents(receive_event);
    }

    /// Waiting for a followed script's next line, headless: a brief sleep. Returns false only when cancelled.
    fn waitHeadless(io: Io, receive_event: EventFunction) bool {
        _ = receive_event;
        io.sleep(.fromMilliseconds(10), .awake) catch return false;
        return true;
    }

    /// Delivers the outcomes the platform holds for the app (`headless_platform.takeEvent`): a paste, a lock granted.
    fn deliverPlatformEvents(receive_event: EventFunction) void {
        while (headless_platform.takeEvent()) |event| {
            receive_event(event);
        }
    }

    /// Starts the Vulkan host without a window, with a screen of `width` by `height` pixels, and gives the platform
    /// the screen's size.
    pub fn start(width: u32, height: u32) Allocator.Error!void {
        try vulkan_host.startHeadlessWithScreen(width, height);
        headless_platform.setSize(float(width), float(height));
        // Saved values kept as files in the folder the run names, from before the app's init - which may read them.
        var folder_buffer: [512]u8 = undefined;
        if (native_os.environmentVariable("ZIMR_VALUES_DIR", &folder_buffer)) |values_folder| {
            headless_platform.keepValuesIn(values_folder);
        }
    }

    /// Runs the script (see `headless`), and returns how it went. Reports the frames run against those drawn on the
    /// screen - the same count when the app drew every frame - and the lines that failed.
    pub fn run(
        update: UpdateFunction,
        receive_event: EventFunction,
        capture: script.CaptureFunction,
    ) script.Outcome {
        var threaded: Io.Threaded = .init(std.heap.smp_allocator, .{});
        defer threaded.deinit();
        const io: Io = threaded.io();
        var reply_buffer: [1024]u8 = undefined;
        var replies: Io.File.Writer = Io.File.stdout().writerStreaming(io, &reply_buffer);
        var session: script.Session = .{
            .io = io,
            .loop = .{
                .draw_frame = &drawHeadlessFrame,
                .request_paste = &requestHeadlessPaste,
                .wait = &waitHeadless,
                .set_gamepad = &headless_platform.setScriptedGamepad,
                .capture_audio = &captureHeadlessAudio,
            },
            .update = update,
            .receive_event = receive_event,
            .capture = capture,
            .replies = &replies.interface,
        };
        var line_buffer: [script.line_room]u8 = undefined;
        var setting_buffer: [512]u8 = undefined;
        const script_setting: ?[]const u8 = native_os.environmentVariable("ZIMR_SCRIPT", &setting_buffer);
        if (script_setting) |script_path| {
            if (eql(u8, script_path, "-")) {
                var stdin_reader: Io.File.Reader = Io.File.stdin().readerStreaming(io, &line_buffer);
                session.runLines(.{ .reader = &stdin_reader.interface });
            } else {
                const script_file: Io.File = Io.Dir.cwd().openFile(io, script_path, .{}) catch |err| {
                    script_log.err("opening the script {s} failed: {s}", .{ script_path, @errorName(err) });
                    return .{ .failed_line_count = 1 };
                };
                defer script_file.close(io);
                var followed_file: script.ScriptFile = .{
                    .io = io,
                    .file = script_file,
                    .is_followed = script.isFollowing(),
                };
                session.runLines(.{ .file = &followed_file });
            }
        } else {
            var default_reader: Io.Reader = .fixed(default_script);
            session.runLines(.{ .reader = &default_reader });
        }
        const drawn_frame_count: u64 = vulkan_host.headlessScreenDrawnFrameCount();
        script_log.info("{d} frames run, {d} drawn on the screen; {d} lines failed", .{
            session.outcome.frame_count,
            drawn_frame_count,
            session.outcome.failed_line_count,
        });
        return session.outcome;
    }

    /// Shuts the Vulkan host down, returning what its validation layer counted.
    pub fn finish() Counts {
        return vulkan_host.shutdown();
    }
};

/// Shuts the Vulkan host down (its validation layer reports anything still alive as an error) and closes the window.
pub fn finish() Counts {
    if (comptime !has_window_loop) {
        // Nothing was opened: no host to shut down, no window to close.
        return .{};
    }
    const counts: Counts = vulkan_host.shutdown();
    window.close();
    return counts;
}
