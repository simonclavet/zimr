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
//! Every connection is served on its own thread. A browser keeps idle sockets
//! open - keep-alive ones, and speculative preconnects that never send a byte -
//! so a loop that serves one connection until it closes sits in `receiveHead`
//! on such a socket while every other request waits. The gallery hit that the
//! moment it fetched an example's source.json while the example's page loaded:
//! with a browser attached, the old loop answered NOTHING within 4 s, and
//! answering with `Connection: close` did not help either (a preconnect never
//! gets as far as a response). The test at the bottom is that measurement.
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
const expect = std.testing.expect;
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

/// Answers one request. Everything it allocates - the path, the whole file, the
/// HMR-injected copy - goes into `arena`, which the caller resets once the
/// response is sent: a connection streaming a dozen wasm files must not keep
/// every one of them.
fn handleRequest(
    arena: Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    opts: ServeOptions,
) !void {
    const target: []const u8 = request.head.target;
    const fs_path_opt: ?[]u8 = try resolvePath(arena, opts.root, target);
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
    const raw: []u8 = try arena.alloc(u8, size);
    var read_buf: [64 * 1024]u8 = undefined;
    var reader: std.Io.File.Reader = file.reader(io, &read_buf);
    try reader.interface.readSliceAll(raw);

    const body: []const u8 = if (opts.hmr and isHtml(fs_path))
        try injectHmr(arena, raw)
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

/// Serves one connection until the browser closes it. Each request's allocations
/// go into one arena that is reset once the response is sent.
fn serveConnection(
    gpa: Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    opts: ServeOptions,
) void {
    defer stream.close(io);
    var request_arena: std.heap.ArenaAllocator = .init(gpa);
    defer request_arena.deinit();

    var conn_recv: [64 * 1024]u8 = undefined;
    var conn_send: [64 * 1024]u8 = undefined;
    var conn_reader: std.Io.net.Stream.Reader = stream.reader(io, &conn_recv);
    var conn_writer: std.Io.net.Stream.Writer = stream.writer(io, &conn_send);
    var http_server: std.http.Server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

    while (true) {
        var request: std.http.Server.Request = http_server.receiveHead() catch break;
        handleRequest(request_arena.allocator(), io, &request, opts) catch break;
        _ = request_arena.reset(.retain_capacity);
    }
}

/// Accepts connections until the listening socket closes, and serves each one on
/// a thread of its own, so an idle browser socket holds up nobody else (see the
/// file header).
fn acceptLoop(
    gpa: Allocator,
    io: std.Io,
    server: *std.Io.net.Server,
    opts: ServeOptions,
) void {
    while (true) {
        const stream: std.Io.net.Stream = server.accept(io) catch |err| switch (err) {
            error.SocketNotListening => return,
            else => continue,
        };
        const connection_thread: std.Thread = std.Thread.spawn(
            .{},
            serveConnection,
            .{ gpa, io, stream, opts },
        ) catch {
            // No thread to serve it on: drop the connection, and the browser retries.
            stream.close(io);
            continue;
        };
        connection_thread.detach();
    }
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

    acceptLoop(gpa, io, &server, opts);
}

// ---- test: an idle browser socket must not stall anyone else ----------------

/// How long `closeWhenDone` waits for the test before closing the silent socket
/// anyway. It only bounds a FAILING run, which then reports instead of hanging.
const stall_limit_ms: i64 = 5000;
const stall_poll_ms: i64 = 20;

/// Holds the silent socket open until the test is `done` - or `stall_limit_ms`,
/// whichever comes first - then records that it closed, and closes it. A server
/// that waits on the silent socket can only answer AFTER `closed` is set, which
/// is what the test checks.
fn closeWhenDone(
    io: std.Io,
    silent: std.Io.net.Stream,
    done: *std.atomic.Value(bool),
    closed: *std.atomic.Value(bool),
) void {
    var waited_ms: i64 = 0;
    while (waited_ms < stall_limit_ms and !done.load(.acquire)) {
        io.sleep(.fromMilliseconds(stall_poll_ms), .awake) catch break;
        waited_ms += stall_poll_ms;
    }
    closed.store(true, .release);
    silent.close(io);
}

test "a silent browser socket does not stall the next request" {
    // The server outlives this test (its accept thread never returns), and the
    // test runner tears `std.testing.io` down after every test - so the server
    // gets an Io and memory of its own, deliberately never freed.
    const server_memory: Allocator = std.heap.page_allocator;
    const server_threaded: *std.Io.Threaded = try server_memory.create(std.Io.Threaded);
    server_threaded.* = .init(server_memory, .{});
    const server_io: std.Io = server_threaded.io();
    const listen_on: std.Io.net.IpAddress = try .parse("127.0.0.1", 0);
    const server: *std.Io.net.Server = try server_memory.create(std.Io.net.Server);
    server.* = try listen_on.listen(server_io, .{});
    const port: u16 = server.socket.address.getPort();
    // No such root, so every answer is a 404 - an answer is all this test needs.
    const opts: ServeOptions = .{ .port = port, .root = "serve-test-no-such-root", .hmr = false };
    const accept_thread: std.Thread = try std.Thread.spawn(
        .{},
        acceptLoop,
        .{ server_memory, server_io, server, opts },
    );
    accept_thread.detach();

    const io: std.Io = std.testing.io;
    const target: std.Io.net.IpAddress = try .parse("127.0.0.1", port);
    // A browser's preconnect: connected, and not one byte sent.
    const silent: std.Io.net.Stream = try target.connect(io, .{ .mode = .stream });
    var done: std.atomic.Value(bool) = .init(false);
    var closed: std.atomic.Value(bool) = .init(false);
    const closer: std.Thread = try std.Thread.spawn(.{}, closeWhenDone, .{ io, silent, &done, &closed });
    defer closer.join();
    defer done.store(true, .release);

    const asker: std.Io.net.Stream = try target.connect(io, .{ .mode = .stream });
    defer asker.close(io);
    var send_buf: [256]u8 = undefined;
    var sender: std.Io.net.Stream.Writer = asker.writer(io, &send_buf);
    try sender.interface.writeAll("GET / HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n");
    try sender.interface.flush();
    var recv_buf: [1024]u8 = undefined;
    var receiver: std.Io.net.Stream.Reader = asker.reader(io, &recv_buf);
    const status_line: []const u8 = try receiver.interface.takeDelimiterExclusive('\n');
    const answered_while_silent_socket_open: bool = !closed.load(.acquire);

    try expect(startsWith(u8, status_line, "HTTP/1.1 404"));
    try expect(answered_while_silent_socket_open);
}
