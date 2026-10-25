//! tools/android_apk.zig - a single-file page as an Android app: `package` packs it into a signed APK, `install` puts
//! that APK on a phone and starts it. Under `-Dplatform=android`, `zig build <app>` runs the first, `run-<app>` both.
//!
//! An APK is a zip: the manifest in Android's binary XML, a resource table, the program as Dalvik bytecode
//! (`classes.dex`) and the files the program reads (`assets/`), all signed. zimr's program is one class,
//! src/android/WebViewActivity.java - a full-screen WebView showing assets/index.html - the same for every app, so one
//! app's APK differs from another's only by its manifest (its ID and its name) and its page.
//!
//! `package` runs the Android SDK's tools and a JDK's, in this order, each printing its own errors:
//!
//!     javac       WebViewActivity.java against the platform's android.jar    -> .class files
//!     d8          Java bytecode to Dalvik bytecode                            -> classes.dex
//!     aapt2 compile  the icon, when there is one: pictures and an adaptive icon -> icon.zip
//!     aapt2 link  the manifest compiled to binary XML, assets/ and the icon   -> an APK with no code yet
//!     jar         classes.dex added at the APK's root; stored entries stay stored
//!     zipalign    every stored entry on a 4-byte boundary, as Android requires
//!     apksigner   signed with the debug key Android Studio uses, made here when the machine has none
//!
//! It looks for them when it runs, never when the build is configured, so a build that asks for no APK never looks:
//! the SDK in ANDROID_HOME, ANDROID_SDK_ROOT or where Android Studio puts it, and in it the newest build-tools and the
//! newest platform; the JDK in JAVA_HOME or the one Android Studio ships (`jbr`), else on the PATH.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const Environ = std.process.Environ;
const allocPrint = std.fmt.allocPrint;
const parseInt = std.fmt.parseInt;
const startsWith = std.mem.startsWith;
const endsWith = std.mem.endsWith;
const splitScalar = std.mem.splitScalar;
const eql = std.mem.eql;
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;
const join = std.fs.path.join;

/// The oldest Android the app installs on: 12 (API 31), the first whose WebView has WebGPU.
const min_sdk: u32 = 31;
/// The Android whose behaviour the app asks for: 16 (API 36). Since 15 that means drawn edge to edge, under the
/// system bars, which the activity hides.
const target_sdk: u32 = 36;
/// The class every zimr APK starts (src/android/WebViewActivity.java).
const activity_class: []const u8 = "zimr.android.WebViewActivity";
/// What does NOT restart the activity, and the page with it: a rotation, a fold, a theme or density change.
const kept_across_changes: []const u8 =
    "orientation|screenSize|screenLayout|smallestScreenSize|keyboardHidden|uiMode|density";
/// The debug keystore's password and alias, the same on every developer's machine. That is what lets one debug build
/// install over another from the same machine, Android Studio's included.
const debug_key_password: []const u8 = "android";
const debug_key_alias: []const u8 = "androiddebugkey";
/// A program's file name ends with this on this system.
const exe_suffix: []const u8 = if (builtin.os.tag == .windows) ".exe" else "";
/// How far the icon's foreground is drawn in from each edge of the icon: Android's adaptive icon is 108 units square,
/// a launcher's shape shows the middle 72 and every shape keeps the middle 66 whole, so the foreground goes into those
/// 66 - 21 units, 19.4%, in from each side - and round art there is never cut.
const icon_foreground_inset: []const u8 = "19.4%";
/// The icon's background when the command line names neither a picture nor a color.
const default_icon_background_color: []const u8 = "#FFFFFF";

/// The subcommands. std's cli has no subcommands, so the command is the first positional - an enum, so a misspelt
/// one is refused with the usage.
const Command = enum { package, install };

/// The command line (std's cli, `src/command_line.zig`). Each command checks that it got the options it needs. The
/// parser wants the named options declared before the positional command.
const AndroidApkArgs = struct {
    @"--html": ?[]const u8 = null,
    @"--java": ?[]const u8 = null,
    @"--app-id": ?[]const u8 = null,
    @"--label": ?[]const u8 = null,
    @"--work": ?[]const u8 = null,
    @"--out": ?[]const u8 = null,
    @"--apk": ?[]const u8 = null,
    @"--icon-foreground": ?[]const u8 = null,
    @"--icon-background": ?[]const u8 = null,
    @"--icon-background-color": ?[]const u8 = null,
    command: Command,
};

const android_apk_cli: cli.Config(AndroidApkArgs) = .{
    .prog = "android_apk",
    .description = "Packs a single-file page into an Android app (package), or installs one and starts it (install).",
    .args = .{
        .command = .{ .description = "package: the page into a signed APK; install: an APK onto the phone adb sees" },
        .@"--html" = .{ .description = "package: the page, packed as assets/index.html" },
        .@"--java" = .{ .description = "package: the activity's Java source, src/android/WebViewActivity.java" },
        .@"--app-id" = .{ .description = "the app's ID, such as org.zimr.goban (install starts it)" },
        .@"--label" = .{ .description = "package: the name under the app's icon" },
        .@"--work" = .{ .description = "package: an empty directory for the files made on the way" },
        .@"--out" = .{ .description = "package: the signed APK to write" },
        .@"--apk" = .{ .description = "install: the APK to install" },
        .@"--icon-foreground" = .{ .description = "package: the icon's picture (.png, .jpg, .webp), drawn centered" },
        .@"--icon-background" = .{ .description = "package: a picture filling the icon behind it" },
        .@"--icon-background-color" = .{ .description = "package: or a color behind it, #RRGGBB (default white)" },
    },
};

/// The Android SDK's tools and the JDK's, found once for a whole `package` run (`findToolchain`).
const Toolchain = struct {
    android_jar: []const u8,
    aapt2: []const u8,
    zipalign: []const u8,
    d8_jar: []const u8,
    apksigner_jar: []const u8,
    java: []const u8,
    javac: []const u8,
    jar: []const u8,
    keytool: []const u8,
};

/// Says what went wrong, on stderr, and returns the error that tells `main` it has been said.
fn fail(
    io: Io,
    arena: Allocator,
    comptime format: []const u8,
    format_args: anytype,
) error{Reported} {
    const message: []const u8 = allocPrint(arena, "android_apk: " ++ format ++ "\n", format_args) catch
        "android_apk: out of memory while reporting a failure\n";
    // A report that cannot be written has nowhere left to go; the exit status still says the run failed.
    Io.File.stderr().writeStreamingAll(io, message) catch {}; // lint:off catch-suppression: stderr, best-effort
    return error.Reported;
}

/// Whether `path` names a file or directory that exists, absolute or from the working directory.
fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Runs one tool to its end, its output going straight to the build's, and fails naming it when it fails.
fn runTool(io: Io, arena: Allocator, argv: []const []const u8) !void {
    var child: std.process.Child = std.process.spawn(io, .{ .argv = argv }) catch |err| {
        return fail(io, arena, "cannot start {s}: {t}", .{ argv[0], err });
    };
    const term: std.process.Child.Term = try child.wait(io);
    if (!term.success()) {
        return fail(io, arena, "{s} {f}", .{ std.fs.path.basename(argv[0]), term });
    }
}

/// The number a version part starts with - 36 of `36`, of `36-ext19` and of `36rc1` - or 0 when it starts with none.
fn leadingNumber(part: []const u8) u32 {
    var digit_count: usize = 0;
    while (digit_count < part.len and std.ascii.isDigit(part[digit_count])) {
        digit_count += 1;
    }
    return parseInt(u32, part[0..digit_count], 10) catch 0;
}

/// `left` is an older version than `right`: their dot-separated numbers compared in turn (`35.0.1` against `36.0.0`,
/// `36` against `36.1`), a missing number counting as 0.
fn versionIsOlder(left: []const u8, right: []const u8) bool {
    var left_parts: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, left, '.');
    var right_parts: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, right, '.');
    while (true) {
        const left_part: ?[]const u8 = left_parts.next();
        const right_part: ?[]const u8 = right_parts.next();
        const both_ended: bool = left_part == null and right_part == null;
        if (both_ended) {
            return false;
        }
        const left_number: u32 = if (left_part) |part| leadingNumber(part) else 0;
        const right_number: u32 = if (right_part) |part| leadingNumber(part) else 0;
        if (left_number != right_number) {
            return left_number < right_number;
        }
    }
}

/// The newest of `parent`'s directories named `prefix` then a version (`36.0.0` in build-tools/, `android-37.0` in
/// platforms/) that holds `required`, a file every usable one has - or null when there is none.
fn newestVersionDir(
    io: Io,
    arena: Allocator,
    parent: []const u8,
    prefix: []const u8,
    required: []const u8,
) !?[]const u8 {
    var dir: Io.Dir = Io.Dir.cwd().openDir(io, parent, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var newest_name: ?[]const u8 = null;
    var entries: Io.Dir.Iterator = dir.iterate();
    while (try entries.next(io)) |entry| {
        const is_versioned_dir: bool = entry.kind == .directory and startsWith(u8, entry.name, prefix);
        if (!is_versioned_dir) {
            continue;
        }
        // The entry's name lives in the iterator's buffer, which the next call reuses.
        const name: []const u8 = try arena.dupe(u8, entry.name);
        const required_path: []const u8 = try join(arena, &.{ parent, name, required });
        if (!exists(io, required_path)) {
            continue;
        }
        const is_newest: bool = if (newest_name) |current|
            versionIsOlder(current[prefix.len..], name[prefix.len..])
        else
            true;
        if (is_newest) {
            newest_name = name;
        }
    }
    const chosen: []const u8 = newest_name orelse return null;
    return try join(arena, &.{ parent, chosen });
}

/// Where Android Studio puts the SDK when told nothing else, or null where the variable it starts from is unset.
fn defaultSdkRoot(arena: Allocator, env: *const Environ.Map) !?[]const u8 {
    switch (builtin.os.tag) {
        .windows => {
            const local_app_data: []const u8 = env.get("LOCALAPPDATA") orelse return null;
            return try join(arena, &.{ local_app_data, "Android", "Sdk" });
        },
        .macos => {
            const home: []const u8 = env.get("HOME") orelse return null;
            return try join(arena, &.{ home, "Library", "Android", "sdk" });
        },
        else => {
            const home: []const u8 = env.get("HOME") orelse return null;
            return try join(arena, &.{ home, "Android", "Sdk" });
        },
    }
}

/// The Android SDK: ANDROID_HOME, else ANDROID_SDK_ROOT, else Android Studio's default place - the first that exists.
fn findSdkRoot(io: Io, arena: Allocator, env: *const Environ.Map) ![]const u8 {
    const candidates: [3]?[]const u8 = .{
        env.get("ANDROID_HOME"),
        env.get("ANDROID_SDK_ROOT"),
        try defaultSdkRoot(arena, env),
    };
    for (candidates) |candidate| {
        const root: []const u8 = candidate orelse continue;
        if (exists(io, root)) {
            return root;
        }
    }
    return fail(io, arena, "no Android SDK found: set ANDROID_HOME to it, or install Android Studio, whose first " ++
        "launch installs one in its default place", .{});
}

/// The JDK's home: JDK_HOME, else JAVA_HOME, else the JDK Android Studio ships (`jbr`) where Android Studio installs
/// by default - or null, and the JDK's programs are looked up on the PATH.
fn findJavaHome(io: Io, arena: Allocator, env: *const Environ.Map) !?[]const u8 {
    if (env.get("JDK_HOME")) |jdk_home| {
        return jdk_home;
    }
    if (env.get("JAVA_HOME")) |java_home| {
        return java_home;
    }
    const studio_jbr: ?[]const u8 = switch (builtin.os.tag) {
        .windows => if (env.get("ProgramFiles")) |program_files|
            try join(arena, &.{ program_files, "Android", "Android Studio", "jbr" })
        else
            null,
        .macos => "/Applications/Android Studio.app/Contents/jbr/Contents/Home",
        else => "/opt/android-studio/jbr",
    };
    const jbr: []const u8 = studio_jbr orelse return null;
    return if (exists(io, jbr)) jbr else null;
}

/// One of the JDK's programs: in `java_home`'s bin/, or by bare name - the PATH decides - without a home.
fn jdkTool(arena: Allocator, java_home: ?[]const u8, name: []const u8) ![]const u8 {
    const file_name: []const u8 = try allocPrint(arena, "{s}{s}", .{ name, exe_suffix });
    const home: []const u8 = java_home orelse return file_name;
    return try join(arena, &.{ home, "bin", file_name });
}

/// Every tool `package` runs; fails naming what to install when the SDK lacks a part.
fn findToolchain(io: Io, arena: Allocator, env: *const Environ.Map) !Toolchain {
    const sdk_root: []const u8 = try findSdkRoot(io, arena, env);
    const aapt2_name: []const u8 = try allocPrint(arena, "aapt2{s}", .{exe_suffix});
    const zipalign_name: []const u8 = try allocPrint(arena, "zipalign{s}", .{exe_suffix});
    const build_tools_parent: []const u8 = try join(arena, &.{ sdk_root, "build-tools" });
    const build_tools: []const u8 = (try newestVersionDir(io, arena, build_tools_parent, "", aapt2_name)) orelse
        return fail(io, arena, "no build-tools in {s}: install them with Android Studio's SDK Manager", .{sdk_root});
    const platforms_parent: []const u8 = try join(arena, &.{ sdk_root, "platforms" });
    const platform: []const u8 = (try newestVersionDir(io, arena, platforms_parent, "android-", "android.jar")) orelse
        return fail(io, arena, "no Android platform in {s}: install one with the SDK Manager", .{sdk_root});
    const java_home: ?[]const u8 = try findJavaHome(io, arena, env);
    return .{
        .android_jar = try join(arena, &.{ platform, "android.jar" }),
        .aapt2 = try join(arena, &.{ build_tools, aapt2_name }),
        .zipalign = try join(arena, &.{ build_tools, zipalign_name }),
        .d8_jar = try join(arena, &.{ build_tools, "lib", "d8.jar" }),
        .apksigner_jar = try join(arena, &.{ build_tools, "lib", "apksigner.jar" }),
        .java = try jdkTool(arena, java_home, "java"),
        .javac = try jdkTool(arena, java_home, "javac"),
        .jar = try jdkTool(arena, java_home, "jar"),
        .keytool = try jdkTool(arena, java_home, "keytool"),
    };
}

/// Whether `app_id` is an Android app ID: two or more dot-separated parts, each a letter then letters, digits and
/// underscores. aapt2 would refuse anything else with a message about the manifest's `package`.
fn isValidAppId(app_id: []const u8) bool {
    var part_count: usize = 0;
    var parts: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, app_id, '.');
    while (parts.next()) |part| {
        const starts_with_letter: bool = part.len > 0 and std.ascii.isAlphabetic(part[0]);
        if (!starts_with_letter) {
            return false;
        }
        for (part) |char| {
            const is_allowed: bool = std.ascii.isAlphanumeric(char) or char == '_';
            if (!is_allowed) {
                return false;
            }
        }
        part_count += 1;
    }
    return part_count >= 2;
}

/// `text` with XML's five special characters written as entities, for an attribute's value.
fn escapeXml(arena: Allocator, text: []const u8) ![]const u8 {
    var escaped: ArrayList(u8) = .empty;
    for (text) |char| {
        const entity: ?[]const u8 = switch (char) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&apos;",
            else => null,
        };
        if (entity) |spelled| {
            try escaped.appendSlice(arena, spelled);
        } else {
            try escaped.append(arena, char);
        }
    }
    return escaped.items;
}

/// The app's manifest: its ID and name, its icon when it has one (`compileIcon`), the Androids it runs on, and its one
/// activity - started from the home screen, and kept running through rotations and the like (`kept_across_changes`) so
/// the page never starts over.
fn manifestXml(
    arena: Allocator,
    app_id: []const u8,
    label: []const u8,
    has_icon: bool,
) ![]const u8 {
    const escaped_label: []const u8 = try escapeXml(arena, label);
    const icon_attribute: []const u8 = if (has_icon) " android:icon=\"@mipmap/ic_launcher\"" else "";
    return try allocPrint(arena,
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<manifest xmlns:android="http://schemas.android.com/apk/res/android"
        \\    package="{s}" android:versionCode="1" android:versionName="1.0">
        \\    <uses-sdk android:minSdkVersion="{d}" android:targetSdkVersion="{d}" />
        \\    <application android:label="{s}"{s}
        \\        android:theme="@android:style/Theme.DeviceDefault.NoActionBar">
        \\        <activity android:name="{s}" android:exported="true" android:configChanges="{s}">
        \\            <intent-filter>
        \\                <action android:name="android.intent.action.MAIN" />
        \\                <category android:name="android.intent.category.LAUNCHER" />
        \\            </intent-filter>
        \\        </activity>
        \\    </application>
        \\</manifest>
        \\
    , .{ app_id, min_sdk, target_sdk, escaped_label, icon_attribute, activity_class, kept_across_changes });
}

/// Whether `text` is a color as Android's resources write one: `#RRGGBB`, or `#AARRGGBB` with its opacity first.
fn isColor(text: []const u8) bool {
    const length_fits: bool = text.len == 7 or text.len == 9;
    const starts_with_hash: bool = text.len > 0 and text[0] == '#';
    if (!length_fits or !starts_with_hash) {
        return false;
    }
    for (text[1..]) |char| {
        if (!std.ascii.isHex(char)) {
            return false;
        }
    }
    return true;
}

/// The extension a picture keeps in res/, which tells aapt2 what it is: `.png`, `.jpg` or `.webp`, whatever the case
/// it was written in - or null for a file aapt2 does not take as a picture.
fn pictureExtension(path: []const u8) ?[]const u8 {
    const extension: []const u8 = std.fs.path.extension(path);
    for ([_][]const u8{ ".png", ".jpg", ".webp" }) |known| {
        if (std.ascii.eqlIgnoreCase(extension, known)) {
            return known;
        }
    }
    return null;
}

/// Copies the icon picture `source` into the resource directory `dir` as `name` and its extension.
fn copyPicture(
    io: Io,
    arena: Allocator,
    source: []const u8,
    dir: []const u8,
    name: []const u8,
) !void {
    const extension: []const u8 = pictureExtension(source) orelse
        return fail(io, arena, "the icon picture {s} is not a PNG, JPEG (.jpg) or WebP file", .{source});
    const file_name: []const u8 = try allocPrint(arena, "{s}{s}", .{ name, extension });
    try Io.Dir.cwd().copyFile(source, .cwd(), try join(arena, &.{ dir, file_name }), io, .{});
}

/// The app's icon as Android resources, compiled - or null without `--icon-foreground`, and the app shows Android's
/// default icon. It is an adaptive icon: the foreground picture, drawn `icon_foreground_inset` in from the edges, on a
/// background picture or color filling the square, both cut to whatever shape the phone's launcher gives every icon.
/// The pictures go in mipmap-xxxhdpi/, the densest, which Android scales down for the phone; the adaptive icon tying
/// them in mipmap-anydpi-v26/; `aapt2 compile` makes of res/ one zip that `aapt2 link` takes.
fn compileIcon(
    io: Io,
    arena: Allocator,
    aapt2: []const u8,
    work: []const u8,
    args: AndroidApkArgs,
) !?[]const u8 {
    const background_picture: ?[]const u8 = args.@"--icon-background";
    const background_color: ?[]const u8 = args.@"--icon-background-color";
    const foreground: []const u8 = args.@"--icon-foreground" orelse {
        const has_background: bool = background_picture != null or background_color != null;
        if (has_background) {
            return fail(io, arena, "an icon background needs the picture it is behind: --icon-foreground", .{});
        }
        return null;
    };
    const has_both_backgrounds: bool = background_picture != null and background_color != null;
    if (has_both_backgrounds) {
        return fail(io, arena, "the icon's background is a picture or a color, not both", .{});
    }
    const cwd: Io.Dir = .cwd();
    const res_dir: []const u8 = try join(arena, &.{ work, "res" });
    const pictures_dir: []const u8 = try join(arena, &.{ res_dir, "mipmap-xxxhdpi" });
    const adaptive_dir: []const u8 = try join(arena, &.{ res_dir, "mipmap-anydpi-v26" });
    try cwd.createDirPath(io, pictures_dir);
    try cwd.createDirPath(io, adaptive_dir);
    try copyPicture(io, arena, foreground, pictures_dir, "ic_launcher_foreground");

    const background_drawable: []const u8 = if (background_picture) |picture| picture_background: {
        try copyPicture(io, arena, picture, pictures_dir, "ic_launcher_background");
        break :picture_background "@mipmap/ic_launcher_background";
    } else color_background: {
        const color: []const u8 = background_color orelse default_icon_background_color;
        if (!isColor(color)) {
            return fail(io, arena, "'{s}' is not an icon background color: #RRGGBB, such as #FFFFFF", .{color});
        }
        const values_dir: []const u8 = try join(arena, &.{ res_dir, "values" });
        try cwd.createDirPath(io, values_dir);
        const color_xml: []const u8 = try allocPrint(arena,
            \\<?xml version="1.0" encoding="utf-8"?>
            \\<resources>
            \\    <color name="ic_launcher_background">{s}</color>
            \\</resources>
            \\
        , .{color});
        const color_path: []const u8 = try join(arena, &.{ values_dir, "ic_launcher_background.xml" });
        try cwd.writeFile(io, .{ .sub_path = color_path, .data = color_xml });
        break :color_background "@color/ic_launcher_background";
    };
    const adaptive_xml: []const u8 = try allocPrint(arena,
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
        \\    <background android:drawable="{s}" />
        \\    <foreground>
        \\        <inset android:drawable="@mipmap/ic_launcher_foreground" android:inset="{s}" />
        \\    </foreground>
        \\</adaptive-icon>
        \\
    , .{ background_drawable, icon_foreground_inset });
    const adaptive_path: []const u8 = try join(arena, &.{ adaptive_dir, "ic_launcher.xml" });
    try cwd.writeFile(io, .{ .sub_path = adaptive_path, .data = adaptive_xml });

    const compiled_zip: []const u8 = try join(arena, &.{ work, "icon.zip" });
    try runTool(io, arena, &.{ aapt2, "compile", "--dir", res_dir, "-o", compiled_zip });
    return compiled_zip;
}

/// Every .class file javac wrote under `classes_dir`: one per class, nested classes included
/// (`WebViewActivity$AssetClient.class`). d8 takes files, not a directory.
fn classFiles(io: Io, arena: Allocator, classes_dir: []const u8) ![]const []const u8 {
    var dir: Io.Dir = try Io.Dir.cwd().openDir(io, classes_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker: Io.Dir.Walker = try dir.walk(arena);
    defer walker.deinit();
    var files: ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        const is_class_file: bool = entry.kind == .file and endsWith(u8, entry.basename, ".class");
        if (is_class_file) {
            try files.append(arena, try join(arena, &.{ classes_dir, entry.path }));
        }
    }
    return files.items;
}

/// The debug keystore: in ANDROID_USER_HOME, else ~/.android - Android Studio's, made here the way Android Studio
/// makes it when this machine has none yet.
fn debugKeystore(
    io: Io,
    arena: Allocator,
    env: *const Environ.Map,
    keytool: []const u8,
) ![]const u8 {
    const android_user_home: []const u8 = env.get("ANDROID_USER_HOME") orelse home: {
        const home_variable: []const u8 = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
        const home: []const u8 = env.get(home_variable) orelse
            return fail(io, arena, "{s} is not set, so there is no ~/.android for the debug key", .{home_variable});
        break :home try join(arena, &.{ home, ".android" });
    };
    const keystore: []const u8 = try join(arena, &.{ android_user_home, "debug.keystore" });
    if (exists(io, keystore)) {
        return keystore;
    }
    try Io.Dir.cwd().createDirPath(io, android_user_home);
    try runTool(io, arena, &.{
        keytool,
        "-genkeypair",
        "-keystore",
        keystore,
        "-storepass",
        debug_key_password,
        "-keypass",
        debug_key_password,
        "-alias",
        debug_key_alias,
        "-keyalg",
        "RSA",
        "-keysize",
        "2048",
        "-validity",
        "10000",
        "-dname",
        "CN=Android Debug,O=Android,C=US",
    });
    return keystore;
}

/// `package`: the page and the activity's Java into a signed APK at `--out`, by the steps the file comment lists.
fn packageApk(
    io: Io,
    arena: Allocator,
    env: *const Environ.Map,
    args: AndroidApkArgs,
) !void {
    const html: []const u8 = args.@"--html" orelse return fail(io, arena, "package needs --html", .{});
    const java_source: []const u8 = args.@"--java" orelse return fail(io, arena, "package needs --java", .{});
    const app_id: []const u8 = args.@"--app-id" orelse return fail(io, arena, "package needs --app-id", .{});
    const label: []const u8 = args.@"--label" orelse return fail(io, arena, "package needs --label", .{});
    const work: []const u8 = args.@"--work" orelse return fail(io, arena, "package needs --work", .{});
    const out: []const u8 = args.@"--out" orelse return fail(io, arena, "package needs --out", .{});
    if (!isValidAppId(app_id)) {
        return fail(io, arena, "'{s}' is not an Android app ID: two or more dot-separated parts, each a letter " ++
            "then letters, digits or underscores, such as org.zimr.goban", .{app_id});
    }
    const tools: Toolchain = try findToolchain(io, arena, env);
    const cwd: Io.Dir = .cwd();
    const min_sdk_text: []const u8 = try allocPrint(arena, "{d}", .{min_sdk});

    // javac: the activity, compiled against the platform's own classes, to Java 11 bytecode, which every d8 reads. The
    // source is read as UTF-8 whatever the JDK: before 18 a JDK on Windows reads it as windows-1252.
    const classes_dir: []const u8 = try join(arena, &.{ work, "classes" });
    try cwd.createDirPath(io, classes_dir);
    try runTool(io, arena, &.{
        tools.javac,
        "-encoding",
        "utf8",
        "--release",
        "11",
        "-classpath",
        tools.android_jar,
        "-d",
        classes_dir,
        java_source,
    });

    // d8: Java bytecode to Dalvik's, as classes.dex. A JDK since 24 warns about the native code d8 and apksigner load
    // unless they are let in up front.
    const dex_dir: []const u8 = try join(arena, &.{ work, "dex" });
    try cwd.createDirPath(io, dex_dir);
    var d8_argv: ArrayList([]const u8) = .empty;
    try d8_argv.appendSlice(arena, &.{
        tools.java,
        "--enable-native-access=ALL-UNNAMED",
        "-cp",
        tools.d8_jar,
        "com.android.tools.r8.D8",
        "--release",
        "--min-api",
        min_sdk_text,
        "--lib",
        tools.android_jar,
        "--output",
        dex_dir,
    });
    try d8_argv.appendSlice(arena, try classFiles(io, arena, classes_dir));
    try runTool(io, arena, d8_argv.items);

    // The icon's resources, compiled - when the command line names an icon.
    const compiled_icon: ?[]const u8 = try compileIcon(io, arena, tools.aapt2, work, args);

    // aapt2: the manifest compiled to binary XML, beside the page as assets/index.html and the icon - an APK with no
    // code yet. --debug-mode makes the app debuggable, which is what lets desktop Chrome inspect its page
    // (chrome://inspect).
    const assets_dir: []const u8 = try join(arena, &.{ work, "assets" });
    try cwd.createDirPath(io, assets_dir);
    try cwd.copyFile(html, cwd, try join(arena, &.{ assets_dir, "index.html" }), io, .{});
    const manifest: []const u8 = try join(arena, &.{ work, "AndroidManifest.xml" });
    const manifest_xml: []const u8 = try manifestXml(arena, app_id, label, compiled_icon != null);
    try cwd.writeFile(io, .{ .sub_path = manifest, .data = manifest_xml });
    const linked_apk: []const u8 = try join(arena, &.{ work, "linked.apk" });
    var link_argv: ArrayList([]const u8) = .empty;
    try link_argv.appendSlice(arena, &.{
        tools.aapt2,
        "link",
        "-o",
        linked_apk,
        "-I",
        tools.android_jar,
        "--manifest",
        manifest,
        "-A",
        assets_dir,
        "--debug-mode",
    });
    if (compiled_icon) |icon_zip| {
        try link_argv.append(arena, icon_zip);
    }
    try runTool(io, arena, link_argv.items);

    // jar: classes.dex added at the root. resources.arsc must stay stored (uncompressed) for Android 11 and up to
    // install the app, and jar keeps the method of every entry it does not touch.
    try runTool(io, arena, &.{
        tools.jar,
        "--update",
        "--no-manifest",
        "--file",
        linked_apk,
        "-C",
        dex_dir,
        "classes.dex",
    });

    // zipalign: each stored entry's data on a 4-byte boundary, so Android can map it in place.
    const aligned_apk: []const u8 = try join(arena, &.{ work, "aligned.apk" });
    try runTool(io, arena, &.{ tools.zipalign, "-f", "4", linked_apk, aligned_apk });

    // apksigner: signed with the debug key. No v4 signature: that one is a file of its own beside the APK, for
    // incremental installs, and adb installs the APK whole without it.
    const keystore: []const u8 = try debugKeystore(io, arena, env, tools.keytool);
    const password_argument: []const u8 = try allocPrint(arena, "pass:{s}", .{debug_key_password});
    try runTool(io, arena, &.{
        tools.java,
        "--enable-native-access=ALL-UNNAMED",
        "-jar",
        tools.apksigner_jar,
        "sign",
        "--ks",
        keystore,
        "--ks-pass",
        password_argument,
        "--key-pass",
        password_argument,
        "--ks-key-alias",
        debug_key_alias,
        "--v4-signing-enabled",
        "false",
        "--out",
        out,
        aligned_apk,
    });
}

/// `install`: the APK onto the phone adb sees - over an earlier build of the same app, which keeps its saved data -
/// and the app started afresh: `-S` stops a copy still running, `-W` waits for the start and prints how it went.
fn installApk(
    io: Io,
    arena: Allocator,
    env: *const Environ.Map,
    args: AndroidApkArgs,
) !void {
    const apk: []const u8 = args.@"--apk" orelse return fail(io, arena, "install needs --apk", .{});
    const app_id: []const u8 = args.@"--app-id" orelse return fail(io, arena, "install needs --app-id", .{});
    const sdk_root: []const u8 = try findSdkRoot(io, arena, env);
    const adb_name: []const u8 = try allocPrint(arena, "adb{s}", .{exe_suffix});
    const adb: []const u8 = try join(arena, &.{ sdk_root, "platform-tools", adb_name });
    if (!exists(io, adb)) {
        return fail(io, arena, "no adb in {s}: install Platform-Tools with Android Studio's SDK Manager", .{sdk_root});
    }
    try runTool(io, arena, &.{ adb, "install", "-r", apk });
    const component: []const u8 = try allocPrint(arena, "{s}/{s}", .{ app_id, activity_class });
    try runTool(io, arena, &.{ adb, "shell", "am", "start", "-S", "-W", "-n", component });
}

pub fn main(init: std.process.Init) !u8 {
    const io: Io = init.io;
    const arena: Allocator = init.arena.allocator();
    const args: AndroidApkArgs = cli.args(&init, AndroidApkArgs, android_apk_cli);
    const outcome: anyerror!void = switch (args.command) {
        .package => packageApk(io, arena, init.environ_map, args),
        .install => installApk(io, arena, init.environ_map, args),
    };
    outcome catch |err| switch (err) {
        // Already said on stderr; the exit status is all there is left to say.
        error.Reported => return 1,
        else => return err,
    };
    return 0;
}

test "versionIsOlder orders build-tools and platform versions by their numbers" {
    try expect(versionIsOlder("35.0.1", "36.0.0"));
    try expect(versionIsOlder("9.0.0", "10.0.0"));
    try expect(versionIsOlder("36", "36.1"));
    try expect(versionIsOlder("36-ext19", "37.0"));
    try expect(!versionIsOlder("36.0.0", "36.0.0"));
    try expect(!versionIsOlder("37.0", "36"));
}

test "isValidAppId takes Android's app ID shape and refuses the rest" {
    try expect(isValidAppId("org.zimr.go_puzzles_hero"));
    try expect(isValidAppId("com.bofstudios.gopuzzleshero"));
    try expect(!isValidAppId("goban"));
    try expect(!isValidAppId("org.zimr.3d_probe"));
    try expect(!isValidAppId("org..zimr"));
    try expect(!isValidAppId("org.zimr.go-puzzles"));
}

test "escapeXml writes the label's special characters as entities" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const escaped: []const u8 = try escapeXml(arena_state.allocator(), "Tom & Jerry's \"<Go>\"");
    try expectEqualStrings("Tom &amp; Jerry&apos;s &quot;&lt;Go&gt;&quot;", escaped);
    try expect(eql(u8, try escapeXml(arena_state.allocator(), "zimr - goban"), "zimr - goban"));
}

test "isColor takes #RRGGBB and #AARRGGBB and refuses the rest" {
    try expect(isColor("#FFFFFF"));
    try expect(isColor("#80c0ffee"));
    try expect(!isColor("FFFFFF"));
    try expect(!isColor("#FFF"));
    try expect(!isColor("#GGGGGG"));
    try expect(!isColor(""));
}

test "pictureExtension keeps what aapt2 takes as a picture, lowercased" {
    try expectEqualStrings(".png", pictureExtension("examples/goban/black_stone.png").?);
    try expectEqualStrings(".jpg", pictureExtension("art/Icon.JPG").?);
    try expectEqualStrings(".webp", pictureExtension("icon.webp").?);
    try expect(pictureExtension("icon.jpeg") == null);
    try expect(pictureExtension("icon.svg") == null);
    try expect(pictureExtension("icon") == null);
}
