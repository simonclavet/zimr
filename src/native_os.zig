//! THE NATIVE HOST'S OPERATING-SYSTEM SERVICES - what the Vulkan host asks of the operating system besides a window:
//!
//!     the Vulkan loader   the library every Vulkan program opens first, and its one exported entry point,
//!                         `vkGetInstanceProcAddr`, through which every other command is fetched
//!     environment         the variables that steer the host (`ZIMR_GPU`, `ZIMR_VK_VALIDATE`)
//!     a monotonic clock   milliseconds that never run backwards, as the browser's `performance.now()` gives them
//!     saved values        a program's small persistent state, one file each under the user's application data
//!     files by path       read, write whole, test, delete, make folders, list them; the program's own folder
//!     child programs      start another program, know when and how it ended, stop it
//!
//! Each service has a Windows version, through `win32.zig`, and a Linux version, through the C library - which a
//! Linux program using Vulkan links anyway, since the Vulkan loader itself is a C library that `dlopen` loads. The
//! choice is made at compile time: the other platform's branch is never analyzed, so a Linux build references no
//! Win32 function and a Windows build no C-library one.
//!
//! The window is not here. It is Windows-only for now (`win32.zig`); a host without one runs headless, drawing into
//! textures - which is how the host's tests run on Linux, on Mesa's software Vulkan driver.

const builtin = @import("builtin");
const std = @import("std");
const vk = @import("vk.zig");
const win32 = @import("win32.zig");

const span = std.mem.span;
const Io = std.Io;
const bufPrint = std.fmt.bufPrint;
const endsWith = std.mem.endsWith;
const indexOfScalar = std.mem.indexOfScalar;

const host = @import("host.zig");
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
const ArrayList = std.ArrayList;

const is_windows: bool = builtin.os.tag == .windows;

// ---- The Vulkan loader ----

pub const VulkanLibrary = struct {
    /// The opened library: Win32's module handle, or the handle `dlopen` returned.
    handle: *anyopaque,
    /// `vkGetInstanceProcAddr`, the one command the host takes from the loader by name; every other is looked up
    /// through it. The operating system hands it out untyped; it gets its Vulkan type here, once.
    get_instance_proc_address: vk.PfnGetInstanceProcAddr,
};

pub const VulkanLibraryError = error{
    /// The loader library is not installed: no Vulkan driver on this machine.
    VulkanNotInstalled,
    /// The library loaded but does not export `vkGetInstanceProcAddr`.
    VulkanLoaderIncomplete,
};

/// The names the Vulkan loader is opened by with `dlopen`, tried in order: on Linux `libvulkan.so.1`, the loader's
/// ABI-versioned name, present wherever a Vulkan driver is installed (the unversioned `libvulkan.so` comes only with
/// development packages); on Android `libvulkan.so`, the system's own; on macOS the Vulkan SDK's loader,
/// `libvulkan.1.dylib`, then MoltenVK itself, `libMoltenVK.dylib`, which a program can carry beside it.
const vulkan_library_names: []const [:0]const u8 = if (builtin.target.abi.isAndroid())
    &.{"libvulkan.so"}
else switch (builtin.target.os.tag) {
    .macos, .ios => &.{ "libvulkan.1.dylib", "libMoltenVK.dylib" },
    else => &.{"libvulkan.so.1"},
};

/// The Vulkan loader. On Windows `vulkan-1.dll` (`win32.openVulkanLibrary`); elsewhere the first of
/// `vulkan_library_names` that opens.
pub fn openVulkanLibrary() VulkanLibraryError!VulkanLibrary {
    if (comptime is_windows) {
        const library: win32.VulkanLibrary = try win32.openVulkanLibrary();
        return .{ .handle = library.module, .get_instance_proc_address = @ptrCast(library.get_instance_proc_address) };
    }
    // LAZY: a symbol is resolved when first used, not all at load - the loader exports far more than one program calls.
    const handle: *anyopaque = for (vulkan_library_names) |library_name| {
        if (std.c.dlopen(library_name, .{ .LAZY = true })) |opened| {
            break opened;
        }
    } else return error.VulkanNotInstalled;
    const entry: *anyopaque = std.c.dlsym(handle, "vkGetInstanceProcAddr") orelse {
        _ = std.c.dlclose(handle);
        return error.VulkanLoaderIncomplete;
    };
    // A function's address is aligned as the target's code is - to 4 bytes on ARM64 (macOS, Android) - where `dlsym`'s
    // untyped pointer promises 1: the alignment is asserted, not assumed.
    return .{ .handle = handle, .get_instance_proc_address = @ptrCast(@alignCast(entry)) };
}

pub fn closeVulkanLibrary(library: VulkanLibrary) void {
    if (comptime is_windows) {
        win32.closeVulkanLibrary(.{
            .module = @ptrCast(library.handle),
            .get_instance_proc_address = @ptrCast(library.get_instance_proc_address),
        });
        return;
    }
    _ = std.c.dlclose(library.handle);
}

// ---- Environment ----

/// The environment variable `name`'s value as UTF-8, copied into `buffer`: null when it is not set or does not fit.
pub fn environmentVariable(comptime name: []const u8, buffer: []u8) ?[]const u8 {
    if (comptime is_windows) {
        return win32.environmentVariable(name, buffer);
    }
    const value: [*:0]const u8 = std.c.getenv(name ++ "\x00") orelse return null;
    const text: []const u8 = span(value);
    if (text.len > buffer.len) {
        return null;
    }
    @memcpy(buffer[0..text.len], text);
    return buffer[0..text.len];
}

// ---- The clock ----

/// A monotonic clock in milliseconds: Windows' performance counter, or Linux's `CLOCK_MONOTONIC` - both unaffected by
/// changes to the wall-clock time, and both starting at an arbitrary point, so only differences mean anything.
pub fn monotonicMilliseconds() f64 {
    if (comptime is_windows) {
        return win32.monotonicMilliseconds();
    }
    var now: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &now);
    const seconds: f64 = @floatFromInt(now.sec);
    const nanoseconds: f64 = @floatFromInt(now.nsec);
    return seconds * 1000.0 + nanoseconds / 1_000_000.0;
}

// ---- The services' Io ----

// lint:off module-var: the program's one `std.Io`, started at its first use and kept for the program's life
var program_threaded: ?Io.Threaded = null;

/// This program's own environment, as an `std.Io.Threaded` hands it to the programs it starts (`ChildProgram`): on
/// Windows the live environment itself, elsewhere the C library's - so a child inherits it, as one started from a
/// shell does. `Io.Threaded`'s default is an EMPTY environment, and a program started with none fails in ways that
/// name no cause: on Windows, NVIDIA's Vulkan driver refuses to make an instance (`vkCreateInstance` returns -3), the
/// loader skips it, and the child runs on another GPU - while `ZIMR_VK_VALIDATE` and every other setting is lost. A
/// build without the C library outside Windows has no environment to hand on: its children start with none.
fn programEnvironment() std.process.Environ {
    if (comptime is_windows) {
        return .{ .block = .global };
    }
    if (comptime builtin.link_libc) {
        const variables: [:null]const ?[*:0]const u8 = std.mem.sliceTo(std.c.environ, null);
        return .{ .block = .{ .slice = variables } };
    }
    return .empty;
}

/// An `std.Io` for callers that have none to pass: the platform contract's saved values (`loadValue`), whose
/// signatures - shared with the web's - carry no `Io`, and an app, which has no `main` of its own to receive one.
/// Everything else in this file takes the caller's `io`. `std.Io.Threaded`'s, on the program's thread-safe
/// allocator, with the program's environment for the programs it starts, started at its first use.
pub fn servicesIo() Io {
    if (program_threaded == null) {
        program_threaded = Io.Threaded.init(std.heap.smp_allocator, .{ .environ = programEnvironment() });
    }
    return program_threaded.?.io();
}

// ---- Saved values ----

/// The room a value's path takes: the data folder, `zimr`, the program's name and the key, escaped.
const value_path_room: usize = 1024;

/// The folder holding every program's saved values on this system (`zimr/<program>` under it): Windows'
/// `%APPDATA%`, Linux's `$XDG_DATA_HOME` or else `~/.local/share`, macOS's and iOS's `~/Library/Application Support`
/// (on iOS, inside the app's own container). Null on Android, whose folder comes from its activity, and wherever the
/// setting it is read from is not set.
fn dataFolder(buffer: []u8) ?[]const u8 {
    if (comptime is_windows) {
        return environmentVariable("APPDATA", buffer);
    }
    if (comptime builtin.target.abi.isAndroid()) {
        return null;
    }
    const is_apple: bool = builtin.target.os.tag == .macos or builtin.target.os.tag == .ios;
    if (comptime is_apple) {
        var home_buffer: [512]u8 = undefined;
        const home: []const u8 = environmentVariable("HOME", &home_buffer) orelse return null;
        return bufPrint(buffer, "{s}/Library/Application Support", .{home}) catch null;
    }
    if (environmentVariable("XDG_DATA_HOME", buffer)) |xdg_data_home| {
        if (xdg_data_home.len > 0) {
            return xdg_data_home;
        }
    }
    var home_buffer: [512]u8 = undefined;
    const home: []const u8 = environmentVariable("HOME", &home_buffer) orelse return null;
    return bufPrint(buffer, "{s}/.local/share", .{home}) catch null;
}

/// The path separator of this system's paths.
const separator: u8 = if (is_windows) '\\' else '/';

/// The program's name, as its folder of values is named: its executable's file name, without `.exe`.
fn programName(io: Io, buffer: []u8) ?[]const u8 {
    const path_length: usize = std.process.executablePath(io, buffer) catch return null;
    const path: []const u8 = buffer[0..path_length];
    const name_start: usize = if (std.mem.lastIndexOfScalar(u8, path, separator)) |last| last + 1 else 0;
    const file_name: []const u8 = path[name_start..];
    return if (endsWith(u8, file_name, ".exe")) file_name[0 .. file_name.len - 4] else file_name;
}

/// The folder of this program's values, `<data folder>/zimr/<program>`, written into `buffer`.
fn valuesFolder(io: Io, buffer: []u8) ?[]const u8 {
    var data_buffer: [512]u8 = undefined;
    const data: []const u8 = dataFolder(&data_buffer) orelse return null;
    var program_buffer: [512]u8 = undefined;
    const program: []const u8 = programName(io, &program_buffer) orelse return null;
    return bufPrint(buffer, "{s}{c}zimr{c}{s}", .{ data, separator, separator, program }) catch null;
}

/// The path of `key`'s file in `folder`, with `suffix` after it, written into `buffer`: a letter, a digit or one of
/// `-_.` stays as it is, every other byte becomes `%XX` - so any key is one file's name, the same on every system and
/// as Windows' platform names it.
fn valuePath(
    folder: []const u8,
    key: []const u8,
    suffix: []const u8,
    buffer: []u8,
) ?[]const u8 {
    var path_length: usize = (bufPrint(buffer, "{s}{c}", .{ folder, separator }) catch return null).len;
    for (key) |byte| {
        const is_plain: bool = std.ascii.isAlphanumeric(byte) or indexOfScalar(u8, "-_.", byte) != null;
        const written: []const u8 = if (is_plain)
            bufPrint(buffer[path_length..], "{c}", .{byte}) catch return null
        else
            bufPrint(buffer[path_length..], "%{X:0>2}", .{byte}) catch return null;
        path_length += written.len;
    }
    const extension: []const u8 = bufPrint(buffer[path_length..], ".value{s}", .{suffix}) catch return null;
    return buffer[0 .. path_length + extension.len];
}

/// `key`'s saved bytes in `folder`, read into `buffer`; null when there are none, or they do not fit.
pub fn loadValueIn(
    io: Io,
    folder: []const u8,
    key: []const u8,
    buffer: []u8,
) ?[]u8 {
    var path_buffer: [value_path_room]u8 = undefined;
    const path: []const u8 = valuePath(folder, key, "", &path_buffer) orelse return null;
    return Io.Dir.cwd().readFile(io, path, buffer) catch null;
}

/// Saves `bytes` as `key`'s value in `folder`, the folder made if it is not there: written whole to a new file, then
/// renamed over the old one, so that a program stopped in the middle leaves the old value or the new, never half of
/// one. A save that fails leaves the old value.
pub fn saveValueIn(
    io: Io,
    folder: []const u8,
    key: []const u8,
    bytes: []const u8,
) void {
    var path_buffer: [value_path_room]u8 = undefined;
    var new_path_buffer: [value_path_room]u8 = undefined;
    const path: []const u8 = valuePath(folder, key, "", &path_buffer) orelse return;
    const new_path: []const u8 = valuePath(folder, key, ".new", &new_path_buffer) orelse return;
    Io.Dir.cwd().createDirPath(io, folder) catch return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = new_path, .data = bytes }) catch return;
    // Both paths are whole - or, in a test, relative to the current folder - so they are renamed from that folder:
    // `renameAbsolute` would assert them absolute.
    const current_folder: Io.Dir = .cwd();
    current_folder.rename(new_path, current_folder, path, io) catch return;
}

/// Removes `key`'s value from `folder`; nothing when it has none.
pub fn removeValueIn(io: Io, folder: []const u8, key: []const u8) void {
    var path_buffer: [value_path_room]u8 = undefined;
    const path: []const u8 = valuePath(folder, key, "", &path_buffer) orelse return;
    Io.Dir.cwd().deleteFile(io, path) catch return;
}

/// The contract's saved values (`loadValue`, `saveValue`, `removeValue`) as files, for a native system: each value
/// one file in this program's folder (`valuesFolder`). Null, or nothing done, where the system has no such folder.
pub fn loadValue(key: []const u8, buffer: []u8) ?[]u8 {
    const io: Io = servicesIo();
    var folder_buffer: [value_path_room]u8 = undefined;
    const folder: []const u8 = valuesFolder(io, &folder_buffer) orelse return null;
    return loadValueIn(io, folder, key, buffer);
}

pub fn saveValue(key: []const u8, bytes: []const u8) void {
    const io: Io = servicesIo();
    var folder_buffer: [value_path_room]u8 = undefined;
    const folder: []const u8 = valuesFolder(io, &folder_buffer) orelse return;
    saveValueIn(io, folder, key, bytes);
}

pub fn removeValue(key: []const u8) void {
    const io: Io = servicesIo();
    var folder_buffer: [value_path_room]u8 = undefined;
    const folder: []const u8 = valuesFolder(io, &folder_buffer) orelse return;
    removeValueIn(io, folder, key);
}

// ---- Files by path ----
//
// A native program reaches its files by path: a run folder a trainer writes into and a lab reads, a thumbnail
// beside the gallery. Every call goes through the services' own `Io` (`io`). A page has no file system - it reaches
// files through the file dialog (`z.userfile`) - so a web build that calls one of these fails to compile, saying so.

/// Fails the compile of a web build that reaches a file by path.
fn requireFilesByPath() void {
    if (comptime host.is_browser) {
        @compileError("files by path are native only: a page reaches files through the file dialog (z.userfile)");
    }
}

/// The file at `path`, read whole into `gpa`'s memory - at most `most_bytes` - or null when there is none.
pub fn readWhole(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    most_bytes: usize,
) !?[]u8 {
    requireFilesByPath();
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(most_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// Writes `bytes` as the file at `path`: whole, to `<path>.new`, then renamed over the old file - a reader sees the
/// old version or the new, never part of one, and a program stopped in the middle of the write leaves the old.
pub fn writeWhole(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    bytes: []const u8,
) !void {
    requireFilesByPath();
    const new_path: []const u8 = try allocPrint(gpa, "{s}.new", .{path});
    defer gpa.free(new_path);
    const current_folder: Io.Dir = .cwd();
    try current_folder.writeFile(io, .{ .sub_path = new_path, .data = bytes });
    try current_folder.rename(new_path, current_folder, path, io);
}

/// Whether anything exists at `path`.
pub fn fileExists(io: Io, path: []const u8) bool {
    requireFilesByPath();
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Deletes the file at `path`; nothing when there is none.
pub fn deleteFileIfPresent(io: Io, path: []const u8) !void {
    requireFilesByPath();
    Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

/// Makes the folder at `path`, and every folder above it that is missing; nothing when it exists.
pub fn makeFolder(io: Io, path: []const u8) !void {
    requireFilesByPath();
    try Io.Dir.cwd().createDirPath(io, path);
}

/// One entry of a folder (`listFolder`): its name, owned by the list, and what it is.
pub const FolderEntry = struct {
    name: []const u8,
    kind: Kind,

    pub const Kind = enum { file, folder, other };
};

/// Frees a `listFolder` list and its names.
pub fn freeFolderEntries(gpa: Allocator, entries: []const FolderEntry) void {
    for (entries) |entry| {
        gpa.free(entry.name);
    }
    gpa.free(entries);
}

/// The entries of the folder at `path`, in the order the system lists them, or an empty list when there is no such
/// folder. The names are allocated with `gpa`: free the list with `freeFolderEntries`.
pub fn listFolder(gpa: Allocator, io: Io, path: []const u8) ![]FolderEntry {
    requireFilesByPath();
    var folder: Io.Dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer folder.close(io);
    var entries: ArrayList(FolderEntry) = .empty;
    // On a failure part-way: the names so far, then the list's own memory - whose length is its capacity, not the
    // number of entries, so it is released by the list and never as a slice of its entries.
    errdefer {
        for (entries.items) |listed| {
            gpa.free(listed.name);
        }
        entries.deinit(gpa);
    }
    var iterator: Io.Dir.Iterator = folder.iterate();
    while (try iterator.next(io)) |entry| {
        const kind: FolderEntry.Kind = switch (entry.kind) {
            .file => .file,
            .directory => .folder,
            else => .other,
        };
        const name: []const u8 = try gpa.dupe(u8, entry.name);
        errdefer gpa.free(name);
        try entries.append(gpa, .{ .name = name, .kind = kind });
    }
    return entries.toOwnedSlice(gpa);
}

/// Seconds since the Unix epoch by the system's wall clock: for a moment another program, or another day, compares
/// with - when a file was written. Not for timing a duration: the wall clock can be set back
/// (`monotonicMilliseconds`).
pub fn wallClockSeconds(io: Io) i64 {
    const now: Io.Timestamp = Io.Clock.real.now(io);
    const nanoseconds_per_second: i96 = 1_000_000_000;
    const seconds: i96 = @divFloor(now.nanoseconds, nanoseconds_per_second);
    return @intCast(seconds);
}

/// The folder this program's executable is in, written into `buffer`; null when the system will not say.
pub fn executableFolder(io: Io, buffer: []u8) ?[]const u8 {
    requireFilesByPath();
    const length: usize = std.process.executableDirPath(io, buffer) catch return null;
    return buffer[0..length];
}

// ---- Child programs ----
//
// A program can start another as a separate process - the gallery an example, a training lab a trainer - so that
// the other runs on its own: a crash or a long computation in it is its own. `ChildProgram` starts one and watches
// it with a thread of its own, which waits for it to end and records how, so that the starting program never waits
// for it. Stopping one is the system's own call, by the id taken as it started: `TerminateProcess` on Windows,
// `SIGTERM` elsewhere. Not `std.process.Child.kill`, which also waits for the child - as its watcher already does -
// and not the child's handle, which its wait closes once the program ends.
//
//     start    idle, closed, failed or not_started  ->  running        (the system would not start it: not_started)
//     its end  running  ->  closed (exit code 0)  or  failed (another exit code, or a signal: 255)
//     stop     running  ->  the system ends it, and its watcher records the end as for any

/// Where a child program is (`ChildProgram.currentState`).
pub const ChildState = enum(u8) {
    /// Not started yet.
    idle,
    /// Started, and not ended yet.
    running,
    /// Ended with exit code 0.
    closed,
    /// Ended with another exit code, or by a signal (`ChildProgram.exit_code`).
    failed,
    /// The system would not start it: most likely its executable is not there.
    not_started,
};

/// A program started from this one, as this one last knows it. The watcher thread writes `exit_code`, then `state`
/// with release ordering; `currentState` reads `state` with acquire ordering, so `exit_code` is complete when the
/// state says the program ended.
pub const ChildProgram = struct {
    state: std.atomic.Value(ChildState) = .init(.idle),
    exit_code: u32 = 0,
    /// The process's id, taken as it starts: what `stop` names.
    process_id: u64 = 0,
    watcher: ?std.Thread = null,

    pub fn currentState(self: *const ChildProgram) ChildState {
        return self.state.load(.acquire);
    }

    /// The system's id of a started child: Windows' process id, or the pid.
    fn processIdOf(child: std.process.Child) u64 {
        if (comptime is_windows) {
            return win32.GetProcessId(child.id.?);
        }
        return @intCast(child.id.?);
    }

    /// A child program's watcher: waits for it to end, then records how - its exit code, or 255 for a program ended by
    /// a signal or whose end could not be read.
    fn watch(
        program: *ChildProgram,
        started_child: std.process.Child,
        io: Io,
    ) void {
        var child: std.process.Child = started_child;
        const termination: std.process.Child.Term = child.wait(io) catch {
            program.exit_code = 255;
            program.state.store(.failed, .release);
            return;
        };
        const exit_code: u32 = switch (termination) {
            .exited => |code| code,
            else => 255,
        };
        program.exit_code = exit_code;
        const ended_state: ChildState = if (exit_code == 0) .closed else .failed;
        program.state.store(ended_state, .release);
    }

    /// Starts `argv` - the executable's path, then its arguments - as a separate process, watched by a thread of
    /// its own. A program already running is left as it is; one the system will not start ends `not_started`.
    pub fn start(self: *ChildProgram, io: Io, argv: []const []const u8) void {
        if (self.currentState() == .running) {
            return;
        }
        // The watcher of the previous run has ended with it: joined before a new one starts.
        if (self.watcher) |previous_watcher| {
            previous_watcher.join();
            self.watcher = null;
        }
        const child: std.process.Child = std.process.spawn(io, .{ .argv = argv }) catch {
            self.state.store(.not_started, .release);
            return;
        };
        self.process_id = processIdOf(child);
        self.exit_code = 0;
        self.state.store(.running, .release);
        self.watcher = std.Thread.spawn(.{}, watch, .{ self, child, io }) catch {
            // Unwatched, nothing would ever record its end and it would show `running` for good: it is ended here
            // instead, and counts as not started.
            var unwatched_child: std.process.Child = child;
            unwatched_child.kill(io);
            self.state.store(.not_started, .release);
            return;
        };
    }

    /// Ends a running program as the system ends one; its watcher then records the end. Nothing for one not running.
    pub fn stop(self: *ChildProgram) void {
        if (self.currentState() != .running) {
            return;
        }
        if (comptime is_windows) {
            const process_id: u32 = @intCast(self.process_id);
            const process: win32.HANDLE = win32.OpenProcess(win32.PROCESS_TERMINATE, 0, process_id) orelse return;
            defer _ = win32.CloseHandle(process);
            _ = win32.TerminateProcess(process, 1);
            return;
        }
        std.posix.kill(@intCast(self.process_id), std.posix.SIG.TERM) catch return;
    }

    /// Lets go of the program: a watcher whose program has ended is joined; one whose program still runs is
    /// detached, and the program keeps running - stop it first to end it.
    pub fn deinit(self: *ChildProgram) void {
        const watcher: std.Thread = self.watcher orelse return;
        if (self.currentState() == .running) {
            watcher.detach();
        } else {
            watcher.join();
        }
        self.watcher = null;
    }
};

const testing = std.testing;
const expect = testing.expect;

/// Whether this build can reach the environment and the Vulkan loader: through the C library on POSIX systems,
/// through the system's own calls on Windows. The host's tests also build without the C library; there these two
/// tests skip.
const reaches_system_libraries: bool = is_windows or builtin.link_libc;

test "native_os: an unset variable is null; the clock never runs backwards" {
    if (comptime !reaches_system_libraries) {
        return error.SkipZigTest;
    }
    var buffer: [64]u8 = undefined;
    try expect(environmentVariable("ZIMR_NATIVE_OS_TEST_SURELY_UNSET", &buffer) == null);
    const first: f64 = monotonicMilliseconds();
    const second: f64 = monotonicMilliseconds();
    try expect(second >= first);
}

test "native_os: the Vulkan loader opens with its entry point, or is reported missing" {
    if (comptime !reaches_system_libraries) {
        return error.SkipZigTest;
    }
    const library: VulkanLibrary = openVulkanLibrary() catch |err| {
        // A machine without a Vulkan driver: the one failure that is not a bug.
        try testing.expectEqual(VulkanLibraryError.VulkanNotInstalled, err);
        return;
    };
    defer closeVulkanLibrary(library);
    try expect(@intFromPtr(library.get_instance_proc_address) != 0);
}

test "native_os: a saved value reads back, is replaced whole, and is gone once removed" {
    const io: Io = servicesIo();
    const folder: []const u8 = ".zig-cache/tmp/native_os_values_test";
    // lint:off catch-suppression: a folder from an earlier run, or none
    Io.Dir.cwd().deleteTree(io, folder) catch {};
    // lint:off catch-suppression: the test's own folder, removed as far as it can be
    defer Io.Dir.cwd().deleteTree(io, folder) catch {};
    var buffer: [64]u8 = undefined;
    try expect(loadValueIn(io, folder, "best score/level 1", &buffer) == null);
    saveValueIn(io, folder, "best score/level 1", "1200");
    try testing.expectEqualStrings("1200", loadValueIn(io, folder, "best score/level 1", &buffer).?);
    saveValueIn(io, folder, "best score/level 1", "980");
    try testing.expectEqualStrings("980", loadValueIn(io, folder, "best score/level 1", &buffer).?);
    removeValueIn(io, folder, "best score/level 1");
    try expect(loadValueIn(io, folder, "best score/level 1", &buffer) == null);
    // The key's space and slash escaped, so it is one file's name.
    var path_buffer: [value_path_room]u8 = undefined;
    const path: []const u8 = valuePath(folder, "best score/level 1", "", &path_buffer).?;
    try expect(endsWith(u8, path, "best%20score%2Flevel%201.value"));
}

test "native_os: a file written whole reads back, is listed in its folder, and is gone once deleted" {
    const io: Io = servicesIo();
    const gpa: Allocator = testing.allocator;
    const folder: []const u8 = ".zig-cache/tmp/native_os_files_test";
    // lint:off catch-suppression: a folder from an earlier run, or none
    Io.Dir.cwd().deleteTree(io, folder) catch {};
    // lint:off catch-suppression: the test's own folder, removed as far as it can be
    defer Io.Dir.cwd().deleteTree(io, folder) catch {};
    try makeFolder(io, folder ++ "/inner");
    const path: []const u8 = folder ++ "/weights";
    try expect(!fileExists(io, path));
    try expect(try readWhole(gpa, io, path, 1024) == null);
    try writeWhole(gpa, io, path, "first");
    try writeWhole(gpa, io, path, "second, whole");
    const read_back: []u8 = (try readWhole(gpa, io, path, 1024)).?;
    defer gpa.free(read_back);
    try testing.expectEqualStrings("second, whole", read_back);
    try expect(!fileExists(io, path ++ ".new"));
    const entries: []FolderEntry = try listFolder(gpa, io, folder);
    defer freeFolderEntries(gpa, entries);
    var file_count: usize = 0;
    var folder_count: usize = 0;
    for (entries) |entry| {
        switch (entry.kind) {
            .file => file_count += 1,
            .folder => folder_count += 1,
            .other => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), file_count);
    try testing.expectEqual(@as(usize, 1), folder_count);
    try deleteFileIfPresent(io, path);
    try deleteFileIfPresent(io, path);
    try expect(!fileExists(io, path));
    const missing: []FolderEntry = try listFolder(gpa, io, folder ++ "/no such folder");
    try testing.expectEqual(@as(usize, 0), missing.len);
}

/// Waits for `program` to end, at most five seconds, looking every millisecond.
fn waitForEnd(io: Io, program: *const ChildProgram) void {
    var polls: u32 = 0;
    const one_millisecond: Io.Clock.Duration = .{ .raw = .fromMilliseconds(1), .clock = .awake };
    while (program.currentState() == .running and polls < 5000) : (polls += 1) {
        // lint:off catch-suppression: a sleep cut short only polls once more
        one_millisecond.sleep(io) catch {};
    }
}

test "native_os: a child program's end is recorded - its exit code - and one that cannot start says so" {
    const io: Io = servicesIo();
    // A shell to run: present on the systems the host's tests run on, Linux and macOS.
    if (comptime is_windows) {
        return error.SkipZigTest;
    }
    if (!fileExists(io, "/bin/sh")) {
        return error.SkipZigTest;
    }
    var exits_three: ChildProgram = .{};
    defer exits_three.deinit();
    exits_three.start(io, &.{ "/bin/sh", "-c", "exit 3" });
    waitForEnd(io, &exits_three);
    try testing.expectEqual(ChildState.failed, exits_three.currentState());
    try testing.expectEqual(@as(u32, 3), exits_three.exit_code);

    var missing: ChildProgram = .{};
    defer missing.deinit();
    missing.start(io, &.{"/no/such/program"});
    try testing.expectEqual(ChildState.not_started, missing.currentState());
}

test "native_os: a child program started through the services' Io inherits the program's environment" {
    if (comptime !reaches_system_libraries) {
        return error.SkipZigTest;
    }
    const io: Io = servicesIo();
    // A variable every system sets, tested by the system's own shell: exit 0 when the child sees it, 3 when not.
    // A child with an empty environment - `Io.Threaded`'s default - exits 3.
    var shell_buffer: [512]u8 = undefined;
    const windows_test: []const u8 = "if defined SystemRoot (exit 0) else (exit 3)";
    const posix_test: []const u8 = "test -n \"$PATH\" || exit 3";
    var argv_buffer: [4][]const u8 = undefined;
    const argv: []const []const u8 = if (comptime is_windows) windows: {
        var root_buffer: [256]u8 = undefined;
        const system_root: []const u8 = environmentVariable("SystemRoot", &root_buffer) orelse
            return error.SkipZigTest;
        const shell: []const u8 = try bufPrint(&shell_buffer, "{s}\\System32\\cmd.exe", .{system_root});
        argv_buffer = .{ shell, "/d", "/c", windows_test };
        break :windows &argv_buffer;
    } else posix: {
        if (!fileExists(io, "/bin/sh")) {
            return error.SkipZigTest;
        }
        argv_buffer[0..3].* = .{ "/bin/sh", "-c", posix_test };
        break :posix argv_buffer[0..3];
    };
    var program: ChildProgram = .{};
    defer program.deinit();
    program.start(io, argv);
    waitForEnd(io, &program);
    try testing.expectEqual(ChildState.closed, program.currentState());
}
