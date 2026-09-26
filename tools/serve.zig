//! serve - zimr's pure-Zig static dev server (ZIG_BRIDGE_PLAN D7 / Phase 5
//! step 1). Replaces the bun-run webtests/server.ts for the SERVING path:
//! static files with correct MIME types (`.wasm` -> application/wasm in
//! particular) and an HMR client `<script>` injected into every `.html`
//! response so the on-disk files stay clean for static deploys.
//!
//! What this intentionally does NOT do yet: the live-reload WebSocket +
//! source watcher + `zig build` re-spawn. `std.http.Server` has
//! `respondWebSocket` and the watcher is a follow-on; serving + injection is
//! the daily-driver core and removes the last bun dependency for `serve`.
//! (Manual refresh works; auto-reload is the documented follow-on.)
//!
//! Usage: serve [--port N] [--root DIR] [--no-hmr] [--open PATH]
//!   --port   listen port (default 8080)
//!   --root   directory served at / (default "zig-out")
//!   --no-hmr suppress the injected reload script
//! Run from the project root so the default root resolves.
const std = @import("std");
const allocPrint = std.fmt.allocPrint;
const endsWith = std.mem.endsWith;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const Allocator = std.mem.Allocator;

const ServeOptions = struct {
    port: u16 = 8080,
    root: []const u8 = "zig-out",
    hmr: bool = true,
};

// The HMR client script injected before </body> (or appended) on every
// served .html. Manual-refresh build: it just logs; the WebSocket endpoint
// is a documented follow-on, so the script is a minimal placeholder that
// does nothing harmful when the endpoint is absent.
const hmr_script: []const u8 =
    "\n<script>console.info(\"[zimr serve] static dev server; refresh manually after rebuild\");</script>\n";

const MimeEntry = struct { ext: []const u8, mime: []const u8 };
const mime_table = [_]MimeEntry{
    .{ .ext = ".html", .mime = "text/html; charset=utf-8" },
    .{ .ext = ".js", .mime = "text/javascript; charset=utf-8" },
    .{ .ext = ".mjs", .mime = "text/javascript; charset=utf-8" },
    .{ .ext = ".wasm", .mime = "application/wasm" },
    .{ .ext = ".json", .mime = "application/json" },
    .{ .ext = ".css", .mime = "text/css; charset=utf-8" },
    .{ .ext = ".png", .mime = "image/png" },
    .{ .ext = ".jpg", .mime = "image/jpeg" },
    .{ .ext = ".jpeg", .mime = "image/jpeg" },
    .{ .ext = ".gif", .mime = "image/gif" },
    .{ .ext = ".svg", .mime = "image/svg+xml" },
    .{ .ext = ".ttf", .mime = "font/ttf" },
    .{ .ext = ".woff2", .mime = "font/woff2" },
    .{ .ext = ".ico", .mime = "image/x-icon" },
};

fn mimeFor(path: []const u8) []const u8 {
    for (mime_table) |entry| {
        if (endsWith(u8, path, entry.ext)) {
            return entry.mime;
        }
    }
    return "application/octet-stream";
}

fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) {
        return false;
    }
    const tail: []const u8 = haystack[haystack.len - needle.len ..];
    for (tail, needle) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) {
            return false;
        }
    }
    return true;
}

fn isHtml(path: []const u8) bool {
    return endsWith(u8, path, ".html") or endsWith(u8, path, "/");
}

// Inject the HMR script before the LAST </body> (case-insensitive), or
// append if there's none. Caller owns the returned slice.
fn injectHmr(gpa: Allocator, html: []const u8) ![]u8 {
    // Find the last "</body>" case-insensitively.
    var idx: ?usize = null;
    var i: usize = 0;
    while (i + 7 <= html.len) : (i += 1) {
        if (endsWithIgnoreCase(html[i .. i + 7], "</body>")) {
            idx = i;
        }
    }
    if (idx) |at| {
        const out: []u8 = try gpa.alloc(u8, html.len + hmr_script.len);
        @memcpy(out[0..at], html[0..at]);
        @memcpy(out[at .. at + hmr_script.len], hmr_script);
        @memcpy(out[at + hmr_script.len ..], html[at..]);
        return out;
    }
    const out: []u8 = try gpa.alloc(u8, html.len + hmr_script.len);
    @memcpy(out[0..html.len], html);
    @memcpy(out[html.len..], hmr_script);
    return out;
}

// Map a request target to a filesystem path under root. "/" -> index.html;
// a trailing "/" -> that dir's index.html. Rejects ".." traversal.
fn resolvePath(
    gpa: Allocator,
    root: []const u8,
    target_in: []const u8,
) !?[]u8 {
    // Strip a leading '/' and any query string.
    var target: []const u8 = target_in;
    if (std.mem.indexOfScalar(u8, target, '?')) |q| {
        target = target[0..q];
    }
    if (startsWith(u8, target, "/")) {
        target = target[1..];
    }
    if (target.len == 0 or endsWith(u8, target, "/")) {
        target = if (target.len == 0)
            "index.html"
        else
            try allocPrint(gpa, "{s}index.html", .{target});
    }
    // Reject path traversal outright.
    if (std.mem.indexOf(u8, target, "..") != null) {
        return null;
    }
    return try allocPrint(gpa, "{s}/{s}", .{ root, target });
}

fn handleRequest(
    gpa: Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    opts: ServeOptions,
) !void {
    const target: []const u8 = request.head.target;
    const fs_path_opt: ?[]u8 = try resolvePath(gpa, opts.root, target);
    if (fs_path_opt == null) {
        try request.respond("403 forbidden\n", .{ .status = .forbidden });
        return;
    }
    const fs_path: []u8 = fs_path_opt.?;

    const file: std.Io.File = std.Io.Dir.cwd().openFile(io, fs_path, .{}) catch {
        try request.respond("404 not found\n", .{ .status = .not_found });
        return;
    };
    defer file.close(io);

    const stat: std.Io.File.Stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    const raw: []u8 = try gpa.alloc(u8, size);
    var read_buf: [64 * 1024]u8 = undefined;
    var reader: std.Io.File.Reader = file.reader(io, &read_buf);
    try reader.interface.readSliceAll(raw);

    const body: []const u8 = if (opts.hmr and isHtml(fs_path))
        try injectHmr(gpa, raw)
    else
        raw;

    try request.respond(body, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = mimeFor(fs_path) },
            // Dev server: never cache, so a rebuilt wasm is always fresh.
            .{ .name = "cache-control", .value = "no-store" },
        },
    });
}

fn parseOptions(argv: []const [:0]const u8) ServeOptions {
    var opts: ServeOptions = .{};
    var i: usize = 1; // skip exe name
    while (i < argv.len) : (i += 1) {
        const arg: []const u8 = argv[i];
        if (eql(u8, arg, "--port")) {
            if (i + 1 < argv.len) {
                i += 1;
                opts.port = std.fmt.parseInt(u16, argv[i], 10) catch opts.port;
            }
        } else if (eql(u8, arg, "--root")) {
            if (i + 1 < argv.len) {
                i += 1;
                opts.root = argv[i];
            }
        } else if (eql(u8, arg, "--no-hmr")) {
            opts.hmr = false;
        } else if (eql(u8, arg, "--open")) {
            i += 1; // accepted for CLI parity; opening a browser is the caller's job
        }
    }
    return opts;
}

pub fn main(init: std.process.Init) !void {
    const gpa: Allocator = init.gpa;
    const io: std.Io = init.io;

    const argv: []const [:0]const u8 = try init.minimal.args.toSlice(gpa);
    const opts: ServeOptions = parseOptions(argv);

    const address: std.Io.net.IpAddress = try std.Io.net.IpAddress.parse("127.0.0.1", opts.port);
    var server: std.Io.net.Server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    var stderr_buf: [256]u8 = undefined;
    var stderr_writer: std.Io.File.Writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr: *std.Io.Writer = &stderr_writer.interface;
    try stderr.print(
        "zimr serve: http://127.0.0.1:{d}/  (root={s}, hmr={})\n",
        .{ opts.port, opts.root, opts.hmr },
    );
    try stderr.flush();

    // One connection at a time is fine for a single-developer dev server.
    while (true) {
        const stream: std.Io.net.Stream = server.accept(io) catch continue;
        defer stream.close(io);

        var conn_recv: [64 * 1024]u8 = undefined;
        var conn_send: [64 * 1024]u8 = undefined;
        var conn_reader: std.Io.net.Stream.Reader = stream.reader(io, &conn_recv);
        var conn_writer: std.Io.net.Stream.Writer = stream.writer(io, &conn_send);
        var http_server: std.http.Server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

        // Serve requests on this connection until it closes.
        while (true) {
            var request: std.http.Server.Request = http_server.receiveHead() catch break;
            handleRequest(gpa, io, &request, opts) catch break;
        }
    }
}
