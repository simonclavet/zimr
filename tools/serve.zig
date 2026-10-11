//! serve - zimr's pure-Zig dev server (ZIG_BRIDGE_PLAN D7 / Phase 5 step 1).
//! Replaces the bun-run webtests/server.ts for the SERVING path: static files
//! with correct MIME types (`.wasm` -> application/wasm in particular), and a
//! live-reload `<script>` injected into every `.html` response, so the files
//! on disk stay clean for static deploys.
//!
//! Live reload: the injected script holds a WebSocket to `/__zimr/live<page>`,
//! and the page reloads when the server says so. The server says so when a
//! second `serve --open <page>` asks it to (`/__zimr/reload<page>`) - which is
//! what `zig build run-<app> -Dplatform=web` does after rebuilding the app. A
//! WebSocket, not server-sent events: an event stream holds one of the six
//! connections a browser opens to a host, and six open tabs would leave no
//! connection to load a seventh page with. There is no file watcher: what
//! reloads a page is a rebuild that asks for it (`zig build --watch run-<app>`
//! asks on every save).
//!
//! One server per port. Binding comes first, and without SO_REUSEADDR: on
//! Windows that option lets a second server bind a port already listened on,
//! and the two then split the connections between them, so an old server
//! answered some of a page's requests. When the bind finds the port taken,
//! serve asks the holder who it is (`/__zimr/serve`): a zimr serve of the same
//! directory is used as it is - it shows `--open`'s page, and this one ends -
//! and anything else stops this one with a message.
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
//! Usage: serve [--port N] [--root DIR] [--no-hmr] [--open PAGE]
//!   --port   listen port (default 8080)
//!   --root   directory served at / (default "zig-out")
//!   --no-hmr leave the live-reload script out of served pages
//!   --open   the page to show (e.g. /hello_world/): opened in the default
//!            browser - or, when a server is already running, by reloading
//!            the tabs already showing it, and opened only if there are none
//! Run from the project root so the default root resolves.
const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const allocPrint = std.fmt.allocPrint;
const bufPrint = std.fmt.bufPrint;
const parseInt = std.fmt.parseInt;
const endsWith = std.mem.endsWith;
const startsWith = std.mem.startsWith;
const eql = std.mem.eql;
const trim = std.mem.trim;
const trimEnd = std.mem.trimEnd;
const expect = std.testing.expect;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArenaAllocator = std.heap.ArenaAllocator;
const indexOf = std.mem.indexOf;
const indexOfScalar = std.mem.indexOfScalar;
const WebSocket = std.http.Server.WebSocket;

const ServeOptions = struct {
    port: u16 = 8080,
    root: []const u8 = "zig-out",
    hmr: bool = true,
    open: ?[]const u8 = null,
};

/// The live-reload script, injected before the last </body> (or appended) on
/// every served .html: a socket to `/__zimr/live<this page>`, and a reload
/// whenever the server sends "reload" down it. After the server stops it keeps
/// reconnecting, backing off to once every 10 s, so a restarted server finds
/// the tab again.
const live_reload_script: []const u8 =
    \\
    \\<script>
    \\(() => {
    \\  let wait = 500;
    \\  let told = false;
    \\  const connect = () => {
    \\    const socket = new WebSocket(`ws://${location.host}/__zimr/live${location.pathname}`);
    \\    socket.onopen = () => {
    \\      wait = 500;
    \\      if (!told) console.info("[zimr serve] live reload: zig build run-<app> reloads this page");
    \\      told = true;
    \\    };
    \\    socket.onmessage = (event) => { if (event.data === "reload") location.reload(); };
    \\    socket.onclose = () => { setTimeout(connect, wait); wait = Math.min(wait * 2, 10000); };
    \\  };
    \\  connect();
    \\})();
    \\</script>
    \\
;

/// The server's own requests, beside the files it serves. A tab's live-reload socket is `live_prefix` followed by its
/// page; `reload_prefix` followed by a page reloads the tabs showing it, and answers how many in `reloaded_header`;
/// `identity_target` answers the directory served, in `root_header`.
const live_prefix: []const u8 = "/__zimr/live";
const reload_prefix: []const u8 = "/__zimr/reload";
const identity_target: []const u8 = "/__zimr/serve";
const own_prefix: []const u8 = "/__zimr/";
const root_header: []const u8 = "x-zimr-root";
const reloaded_header: []const u8 = "x-zimr-reloaded";

/// How many tabs' sockets the server keeps, and the longest page path one may show; a tab beyond either simply
/// never reloads.
const max_tabs: usize = 64;
const max_page_len: usize = 256;

/// How long a question to the port's holder may wait for an answer (`askPort`), and how often the wait looks.
/// Windows reports a refused connection to a loopback port only after about two seconds, hence three.
const answer_limit_ms: i64 = 3000;
const answer_poll_ms: i64 = 10;

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

/// One open tab's live-reload socket, while the thread of its connection holds it.
const Tab = struct {
    /// Null while the slot is free.
    socket: ?*WebSocket = null,
    page: [max_page_len]u8 = undefined,
    page_len: usize = 0,
};

/// The pages open in a browser, each through its live-reload socket: what `--open` asks a running server to reload
/// before it opens another tab. Each socket's own thread adds and removes it; a reload request's thread writes to it,
/// under the lock, so a socket is never written once its thread has let it go.
const Tabs = struct {
    mutex: Io.Mutex = .init,
    slots: [max_tabs]Tab = @splat(.{}),

    /// Records `socket`, showing `page`: the slot to remove it from, or null when there is no room.
    fn add(tabs: *Tabs, io: Io, socket: *WebSocket, page: []const u8) ?usize {
        if (page.len > max_page_len) {
            return null;
        }
        tabs.mutex.lockUncancelable(io);
        defer tabs.mutex.unlock(io);
        for (&tabs.slots, 0..) |*tab, slot| {
            if (tab.socket == null) {
                tab.socket = socket;
                @memcpy(tab.page[0..page.len], page);
                tab.page_len = page.len;
                return slot;
            }
        }
        return null;
    }

    fn remove(tabs: *Tabs, io: Io, slot: usize) void {
        tabs.mutex.lockUncancelable(io);
        defer tabs.mutex.unlock(io);
        tabs.slots[slot].socket = null;
    }

    /// Tells every tab showing `page` to reload, and returns how many it told. A tab whose socket cannot be written
    /// is not counted: it is closing, and its own thread removes it.
    fn reload(tabs: *Tabs, io: Io, page: []const u8) usize {
        tabs.mutex.lockUncancelable(io);
        defer tabs.mutex.unlock(io);
        var told: usize = 0;
        for (&tabs.slots) |*tab| {
            const socket: *WebSocket = tab.socket orelse continue;
            if (!eql(u8, tab.page[0..tab.page_len], page)) {
                continue;
            }
            socket.writeMessage("reload", .text) catch continue;
            told += 1;
        }
        return told;
    }
};

/// What every connection's thread shares.
const Site = struct {
    /// The directory served, absolute when it could be resolved (`absolutePath`): the answer to `identity_target`,
    /// which a second serve compares with its own.
    root: []const u8,
    /// Whether served pages get the live-reload script.
    live_reload: bool,
    tabs: Tabs = .{},
};

/// One GET to the server on a port: the target, and the header of the answer that holds the reply.
const Question = struct {
    target: []const u8,
    header: []const u8,
};

/// What asking the holder of a port found.
const Answer = union(enum) {
    /// Nothing listens on the port.
    nobody,
    /// Something answered over HTTP: the value of the header asked for, or null when the answer has none - which is
    /// how anything that is not a zimr serve answers.
    answered: ?[]const u8,
    /// Something holds the port and did not answer in time, or the conversation broke off.
    silent,
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

// Inject the live-reload script before the LAST </body> (case-insensitive),
// or append if there's none. Caller owns the returned slice.
fn injectLiveReload(gpa: Allocator, html: []const u8) ![]u8 {
    // Find the last "</body>" case-insensitively.
    var idx: ?usize = null;
    var i: usize = 0;
    while (i + 7 <= html.len) : (i += 1) {
        if (endsWithIgnoreCase(html[i .. i + 7], "</body>")) {
            idx = i;
        }
    }
    if (idx) |at| {
        const out: []u8 = try gpa.alloc(u8, html.len + live_reload_script.len);
        @memcpy(out[0..at], html[0..at]);
        @memcpy(out[at .. at + live_reload_script.len], live_reload_script);
        @memcpy(out[at + live_reload_script.len ..], html[at..]);
        return out;
    }
    const out: []u8 = try gpa.alloc(u8, html.len + live_reload_script.len);
    @memcpy(out[0..html.len], html);
    @memcpy(out[html.len..], live_reload_script);
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
    if (indexOfScalar(u8, target, '?')) |q| {
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
    if (indexOf(u8, target, "..") != null) {
        return null;
    }
    return try allocPrint(gpa, "{s}/{s}", .{ root, target });
}

/// The page a path names, as the tabs are keyed: no query, and no `index.html` - `/hello_world/index.html` and
/// `/hello_world/` are one page.
fn pageKey(path: []const u8) []const u8 {
    const no_query: []const u8 = path[0 .. indexOfScalar(u8, path, '?') orelse path.len];
    if (endsWith(u8, no_query, "/index.html")) {
        return no_query[0 .. no_query.len - "index.html".len];
    }
    return no_query;
}

/// A tab's live-reload socket (`live_prefix` + its page): recorded in the tabs until the tab closes it. The page
/// never writes to it; reading only notices the close. The connection's thread waits here meanwhile - every
/// connection has a thread of its own (see the file header).
fn serveLiveSocket(
    io: Io,
    request: *std.http.Server.Request,
    site: *Site,
    page: []const u8,
) !void {
    const key: []const u8 = switch (request.upgradeRequested()) {
        .websocket => |websocket_key| websocket_key orelse "",
        .other, .none => "",
    };
    if (key.len == 0) {
        try request.respond("400 expected a websocket\n", .{ .status = .bad_request });
        return;
    }
    var socket: WebSocket = try request.respondWebSocket(.{ .key = key });
    try socket.flush();
    // `page` points into the request's head, which stays put until the socket is read: `add` copies it first.
    const slot: ?usize = site.tabs.add(io, &socket, page);
    defer {
        if (slot) |taken| {
            site.tabs.remove(io, taken);
        }
    }
    while (true) {
        _ = socket.readSmallMessage() catch break;
    }
}

/// Answers one request, and returns whether the connection serves more: a live-reload socket is the connection's
/// last. Everything it allocates - the path, the whole file, the script-injected copy - goes into `arena`, which the
/// caller resets once the response is sent: a connection streaming a dozen wasm files must not keep every one of
/// them.
fn handleRequest(
    arena: Allocator,
    io: Io,
    request: *std.http.Server.Request,
    site: *Site,
) !bool {
    const target: []const u8 = request.head.target;
    if (startsWith(u8, target, live_prefix)) {
        try serveLiveSocket(io, request, site, pageKey(target[live_prefix.len..]));
        return false;
    }
    if (startsWith(u8, target, reload_prefix)) {
        const told: usize = site.tabs.reload(io, pageKey(target[reload_prefix.len..]));
        var told_buffer: [24]u8 = undefined;
        const told_text: []const u8 = try bufPrint(&told_buffer, "{d}", .{told});
        try request.respond("", .{
            .extra_headers = &.{
                .{ .name = reloaded_header, .value = told_text },
                .{ .name = "cache-control", .value = "no-store" },
            },
        });
        return true;
    }
    if (eql(u8, target, identity_target)) {
        try request.respond("zimr serve\n", .{
            .extra_headers = &.{
                .{ .name = root_header, .value = site.root },
                .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-store" },
            },
        });
        return true;
    }
    if (startsWith(u8, target, own_prefix)) {
        try request.respond("404 not found\n", .{ .status = .not_found });
        return true;
    }

    const fs_path_opt: ?[]u8 = try resolvePath(arena, site.root, target);
    if (fs_path_opt == null) {
        try request.respond("403 forbidden\n", .{ .status = .forbidden });
        return true;
    }
    const fs_path: []u8 = fs_path_opt.?;

    const file: Io.File = Io.Dir.cwd().openFile(io, fs_path, .{}) catch {
        try request.respond("404 not found\n", .{ .status = .not_found });
        return true;
    };
    defer file.close(io);

    const stat: Io.File.Stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    const raw: []u8 = try arena.alloc(u8, size);
    var read_buf: [64 * 1024]u8 = undefined;
    var reader: Io.File.Reader = file.reader(io, &read_buf);
    try reader.interface.readSliceAll(raw);

    const body: []const u8 = if (site.live_reload and isHtml(fs_path))
        try injectLiveReload(arena, raw)
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
    return true;
}

/// The command line (std's cli, `src/command_line.zig`). A bad port or an unknown option is refused with the
/// usage. The hand parser this replaced ignored both - `--port 80a` served on 8080 without a word.
const ServeArgs = struct {
    @"--port": u16 = 8080,
    @"--root": []const u8 = "zig-out",
    @"--no-hmr": bool = false,
    @"--open": ?[]const u8 = null,
};

const serve_cli: cli.Config(ServeArgs) = .{
    .prog = "serve",
    .description = "A dev server for the built pages (`zig build serve` passes the root and the port).",
    .args = .{
        .@"--root" = .{ .description = "the directory to serve" },
        .@"--no-hmr" = .{ .description = "leave the live-reload script out of served .html pages" },
        .@"--open" = .{
            .description = "the page to show (/hello_world/): opened in a browser, or reloaded where a tab shows it",
        },
    },
};

fn parseOptions(init: *const std.process.Init) ServeOptions {
    const args: ServeArgs = cli.args(init, ServeArgs, serve_cli);
    return .{
        .port = args.@"--port",
        .root = args.@"--root",
        .hmr = !args.@"--no-hmr",
        .open = args.@"--open",
    };
}

/// Serves one connection until the browser closes it. Each request's allocations
/// go into one arena that is reset once the response is sent.
fn serveConnection(
    gpa: Allocator,
    io: Io,
    stream: Io.net.Stream,
    site: *Site,
) void {
    defer stream.close(io);
    var request_arena: ArenaAllocator = .init(gpa);
    defer request_arena.deinit();

    var conn_recv: [64 * 1024]u8 = undefined;
    var conn_send: [64 * 1024]u8 = undefined;
    var conn_reader: Io.net.Stream.Reader = stream.reader(io, &conn_recv);
    var conn_writer: Io.net.Stream.Writer = stream.writer(io, &conn_send);
    var http_server: std.http.Server = .init(&conn_reader.interface, &conn_writer.interface);

    while (true) {
        var request: std.http.Server.Request = http_server.receiveHead() catch break;
        const serves_more: bool = handleRequest(request_arena.allocator(), io, &request, site) catch break;
        _ = request_arena.reset(.retain_capacity);
        if (!serves_more) {
            break;
        }
    }
}

/// Accepts connections until the listening socket closes, and serves each one on
/// a thread of its own, so an idle browser socket holds up nobody else (see the
/// file header).
fn acceptLoop(
    gpa: Allocator,
    io: Io,
    server: *Io.net.Server,
    site: *Site,
) void {
    while (true) {
        const stream: Io.net.Stream = server.accept(io) catch |err| switch (err) {
            error.SocketNotListening => return,
            else => continue,
        };
        const connection_thread: std.Thread = std.Thread.spawn(
            .{},
            serveConnection,
            .{ gpa, io, stream, site },
        ) catch {
            // No thread to serve it on: drop the connection, and the browser retries.
            stream.close(io);
            continue;
        };
        connection_thread.detach();
    }
}

/// `path` made absolute and canonical in `buffer`, or `path` itself when it cannot be: two serves of one directory,
/// started from different directories, compare it.
fn absolutePath(io: Io, path: []const u8, buffer: []u8) []const u8 {
    const length: usize = Io.Dir.cwd().realPathFile(io, path, buffer) catch return path;
    return buffer[0..length];
}

/// Whether two absolute paths name the same directory: Windows' paths ignore case.
fn samePath(left: []const u8, right: []const u8) bool {
    if (builtin.os.tag == .windows) {
        return std.ascii.eqlIgnoreCase(left, right);
    }
    return eql(u8, left, right);
}

/// Asks the server on `port` `question`, and waits for the answer; sets `finished` when it has one. The reply is
/// copied into `buffer`, cut to fit.
fn askNow(
    io: Io,
    port: u16,
    question: Question,
    buffer: []u8,
    finished: *std.atomic.Value(bool),
) Answer {
    defer finished.store(true, .release);
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream: Io.net.Stream = address.connect(io, .{ .mode = .stream }) catch |err| switch (err) {
        error.ConnectionRefused => return .nobody,
        else => return .silent,
    };
    defer stream.close(io);
    var send_buffer: [512]u8 = undefined;
    var sender: Io.net.Stream.Writer = stream.writer(io, &send_buffer);
    sender.interface.print(
        "GET {s} HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n",
        .{question.target},
    ) catch return .silent;
    sender.interface.flush() catch return .silent;
    var receive_buffer: [4096]u8 = undefined;
    var receiver: Io.net.Stream.Reader = stream.reader(io, &receive_buffer);
    // The status line, then the headers, up to the empty line that ends them.
    _ = receiver.interface.takeDelimiter('\n') catch return .silent;
    while (receiver.interface.takeDelimiter('\n') catch return .silent) |raw_line| {
        const line: []const u8 = trimEnd(u8, raw_line, "\r");
        if (line.len == 0) {
            break;
        }
        const colon: usize = indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], question.header)) {
            continue;
        }
        const value: []const u8 = trim(u8, line[colon + 1 ..], " \t");
        const kept: []u8 = buffer[0..@min(value.len, buffer.len)];
        @memcpy(kept, value[0..kept.len]);
        return .{ .answered = kept };
    }
    return .{ .answered = null };
}

/// `askNow` with a time limit: a holder of the port that accepts the connection and never answers is `.silent` after
/// `answer_limit_ms`, instead of holding this up for good.
fn askPort(io: Io, port: u16, question: Question, buffer: []u8) Answer {
    var finished: std.atomic.Value(bool) = .init(false);
    var asking: Io.Future(Answer) = io.concurrent(askNow, .{ io, port, question, buffer, &finished }) catch {
        // No second thread to wait beside: ask with no limit.
        return askNow(io, port, question, buffer, &finished);
    };
    var waited_ms: i64 = 0;
    while (waited_ms < answer_limit_ms and !finished.load(.acquire)) {
        io.sleep(.fromMilliseconds(answer_poll_ms), .awake) catch break;
        waited_ms += answer_poll_ms;
    }
    // Answered: `cancel` collects the answer. Still waiting: it cancels the read, and `askNow` returns `.silent`.
    return asking.cancel(io);
}

/// Opens `url` in the default browser. Waits for the program that hands it over, which returns as soon as it has.
fn openBrowser(io: Io, url: []const u8) void {
    const opener: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ "rundll32.exe", "url.dll,FileProtocolHandler" },
        .macos => &.{"open"},
        else => &.{"xdg-open"},
    };
    var argv: [3][]const u8 = undefined;
    @memcpy(argv[0..opener.len], opener);
    argv[opener.len] = url;
    var child: std.process.Child = std.process.spawn(io, .{
        .argv = argv[0 .. opener.len + 1],
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    // Its exit status says nothing worth reporting: the browser opens, or the user sees it did not.
    _ = child.wait(io) catch return;
}

/// What a second serve does with the zimr serve already on the port (`served_root` is the root it answered, null
/// when what answered is not a zimr serve): when it serves this root, show `--open`'s page through it and succeed;
/// otherwise say what holds the port and fail. Returns the exit status.
fn useRunningServer(
    io: Io,
    stderr: *Io.Writer,
    opts: ServeOptions,
    root: []const u8,
    served_root: ?[]const u8,
) !u8 {
    const its_root: []const u8 = served_root orelse {
        try stderr.print("zimr serve: port {d} is taken by a program that is not a zimr serve - or by a zimr serve " ++
            "older than this one, which does not say: stop it, or serve on another port\n", .{opts.port});
        try stderr.flush();
        return 1;
    };
    if (!samePath(its_root, root)) {
        try stderr.print("zimr serve: port {d} is taken by a zimr serve of {s}, not {s}: stop it, or serve on " ++
            "another port\n", .{ opts.port, its_root, root });
        try stderr.flush();
        return 1;
    }
    try stderr.print("zimr serve: http://127.0.0.1:{d}/ is already being served (root={s})\n", .{ opts.port, root });
    try stderr.flush();
    const page: []const u8 = opts.open orelse return 0;
    var reload_target_buffer: [reload_prefix.len + max_page_len]u8 = undefined;
    const reload_target: []const u8 = try bufPrint(&reload_target_buffer, "{s}{s}", .{ reload_prefix, page });
    var told_buffer: [24]u8 = undefined;
    const question: Question = .{ .target = reload_target, .header = reloaded_header };
    const answer: Answer = askPort(io, opts.port, question, &told_buffer);
    const told: usize = switch (answer) {
        .answered => |told_text| parseInt(usize, told_text orelse "0", 10) catch 0,
        .nobody, .silent => 0,
    };
    if (told > 0) {
        try stderr.print("zimr serve: reloaded {d} tab(s) showing {s}\n", .{ told, page });
    } else {
        var url_buffer: [64 + max_page_len]u8 = undefined;
        const url: []const u8 = try bufPrint(&url_buffer, "http://127.0.0.1:{d}{s}", .{ opts.port, page });
        try stderr.print("zimr serve: opening {s}\n", .{url});
        openBrowser(io, url);
    }
    try stderr.flush();
    return 0;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa: Allocator = init.gpa;
    const io: Io = init.io;

    var opts: ServeOptions = parseOptions(&init);
    var page_buffer: [max_page_len]u8 = undefined;
    if (opts.open) |page| {
        // A page is a path from the root: `hello_world/` means `/hello_world/`.
        const rooted: []const u8 = if (startsWith(u8, page, "/"))
            page
        else
            try bufPrint(&page_buffer, "/{s}", .{page});
        opts.open = pageKey(rooted);
    }

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = Io.File.stderr().writer(io, &stderr_buf);
    const stderr: *Io.Writer = &stderr_writer.interface;

    var root_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const root: []const u8 = absolutePath(io, opts.root, &root_buffer);

    const address: Io.net.IpAddress = try .parse("127.0.0.1", opts.port);
    var server: Io.net.Server = listen: {
        if (address.listen(io, .{})) |listening| {
            break :listen listening;
        } else |err| switch (err) {
            error.AddressInUse => {},
            else => return err,
        }
        var served_root_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
        const question: Question = .{ .target = identity_target, .header = root_header };
        switch (askPort(io, opts.port, question, &served_root_buffer)) {
            .answered => |served_root| return useRunningServer(io, stderr, opts, root, served_root),
            // Taken, yet nothing listens: connections closed a moment ago, waiting out their TIME_WAIT, which POSIX
            // will not bind over without SO_REUSEADDR. With nothing listening, the option can share nothing.
            .nobody => break :listen try address.listen(io, .{ .reuse_address = true }),
            .silent => {
                try stderr.print("zimr serve: port {d} is taken by a program that does not answer: stop it, or " ++
                    "serve on another port\n", .{opts.port});
                try stderr.flush();
                return 1;
            },
        }
    };
    defer server.deinit(io);

    var site: Site = .{ .root = root, .live_reload = opts.hmr };
    try stderr.print(
        "zimr serve: http://127.0.0.1:{d}/  (root={s}, live reload={})\n",
        .{ opts.port, root, opts.hmr },
    );
    var url_buffer: [64 + max_page_len]u8 = undefined;
    if (opts.open) |page| {
        const url: []const u8 = try bufPrint(&url_buffer, "http://127.0.0.1:{d}{s}", .{ opts.port, page });
        try stderr.print("zimr serve: opening {s}\n", .{url});
        // On a thread of its own: the opener may wait for the browser, and the browser for this server. `url` lives in
        // this frame, which serves until the process ends.
        const opener_thread: ?std.Thread = std.Thread.spawn(.{}, openBrowser, .{ io, url }) catch null;
        if (opener_thread) |thread| {
            thread.detach();
        }
    }
    try stderr.flush();

    acceptLoop(gpa, io, &server, &site);
    return 0;
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
    io: Io,
    silent: Io.net.Stream,
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
    const server_threaded: *Io.Threaded = try server_memory.create(Io.Threaded);
    server_threaded.* = Io.Threaded.init(server_memory, .{});
    const server_io: Io = server_threaded.io();
    const listen_on: Io.net.IpAddress = try .parse("127.0.0.1", 0);
    const server: *Io.net.Server = try server_memory.create(Io.net.Server);
    server.* = try listen_on.listen(server_io, .{});
    const port: u16 = server.socket.address.getPort();
    // No such root, so every answer is a 404 - an answer is all this test needs.
    const site: *Site = try server_memory.create(Site);
    site.* = .{ .root = "serve-test-no-such-root", .live_reload = false };
    const accept_thread: std.Thread = try .spawn(
        .{},
        acceptLoop,
        .{ server_memory, server_io, server, site },
    );
    accept_thread.detach();

    const io: Io = std.testing.io;
    const target: Io.net.IpAddress = try .parse("127.0.0.1", port);
    // A browser's preconnect: connected, and not one byte sent.
    const silent: Io.net.Stream = try target.connect(io, .{ .mode = .stream });
    var done: std.atomic.Value(bool) = .init(false);
    var closed: std.atomic.Value(bool) = .init(false);
    const closer: std.Thread = try .spawn(.{}, closeWhenDone, .{ io, silent, &done, &closed });
    defer closer.join();
    defer done.store(true, .release);

    const asker: Io.net.Stream = try target.connect(io, .{ .mode = .stream });
    defer asker.close(io);
    var send_buf: [256]u8 = undefined;
    var sender: Io.net.Stream.Writer = asker.writer(io, &send_buf);
    try sender.interface.writeAll("GET / HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n");
    try sender.interface.flush();
    var recv_buf: [1024]u8 = undefined;
    var receiver: Io.net.Stream.Reader = asker.reader(io, &recv_buf);
    const status_line: []const u8 = try receiver.interface.takeDelimiterExclusive('\n');
    const answered_while_silent_socket_open: bool = !closed.load(.acquire);

    try expect(startsWith(u8, status_line, "HTTP/1.1 404"));
    try expect(answered_while_silent_socket_open);
}

test "the page of a path drops the query and index.html" {
    try expect(eql(u8, pageKey("/hello_world/"), "/hello_world/"));
    try expect(eql(u8, pageKey("/hello_world/index.html"), "/hello_world/"));
    try expect(eql(u8, pageKey("/hello_world/?seed=3"), "/hello_world/"));
    try expect(eql(u8, pageKey("/index.html"), "/"));
    try expect(eql(u8, pageKey("/notes.html"), "/notes.html"));
}
