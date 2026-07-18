//! verify_imports — pure-Zig replacement for webtests/verify_imports.js.
//!
//! The browser rejects a standalone at `WebAssembly.instantiate` when the wasm
//! imports a host function the bridge never built (a LinkError). Neither the Zig
//! compiler (blind to the JS side) nor the smoke (its runner.mjs auto-stubs every
//! import via a Proxy) can see it. But both sides are static artifacts:
//!
//!   - the BLOB side: the wasm's import section lists every (module, field) it needs.
//!   - the BRIDGE side: bridge.zig registers each host fn as `.set("js_x", ...)`.
//!
//! This reads both in Zig and fails if the blob imports a host name the bridge
//! doesn't provide. No JS, no Node, no wasm execution.
//!
//!   verify_imports <example.wasm> <bridge.zig>
//!
//! wasi_snapshot_preview1 imports are the WASI runtime shim, not bridge.zig's job,
//! so they're skipped; every other namespace (dom/wgpu/audio/jobs) is `js_`-named.
const std = @import("std");

/// Minimal LEB128 + section walker over the wasm binary, pulling out the
/// (module, field) pair of every import. Only the import section (id 2) is read.
const WasmImports = struct {
    fn readU32Leb(bytes: []const u8, pos: *usize) u32 {
        var result: u32 = 0;
        var shift: u5 = 0;
        while (true) {
            const b: u8 = bytes[pos.*];
            pos.* += 1;
            result |= @as(u32, b & 0x7f) << shift;
            if (b & 0x80 == 0) {
                break;
            }
            shift += 7;
        }
        return result;
    }

    /// Calls `sink` with (module, field) for each import. Returns error on a
    /// malformed header rather than trusting a bad file.
    fn each(
        bytes: []const u8,
        ctx: anytype,
        comptime sink: fn (@TypeOf(ctx), []const u8, []const u8) anyerror!void,
    ) !void {
        if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..4], "\x00asm")) {
            return error.NotWasm;
        }
        var pos: usize = 8; // past magic + version
        while (pos < bytes.len) {
            const id: u8 = bytes[pos];
            pos += 1;
            const size: u32 = readU32Leb(bytes, &pos);
            const body_end: usize = pos + size;
            if (id != 2) { // not the import section — skip its body
                pos = body_end;
                continue;
            }
            const count: u32 = readU32Leb(bytes, &pos);
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const mod_len: u32 = readU32Leb(bytes, &pos);
                const module: []const u8 = bytes[pos .. pos + mod_len];
                pos += mod_len;
                const field_len: u32 = readU32Leb(bytes, &pos);
                const field: []const u8 = bytes[pos .. pos + field_len];
                pos += field_len;
                const kind: u8 = bytes[pos];
                pos += 1;
                switch (kind) { // skip the kind-specific descriptor
                    0 => _ = readU32Leb(bytes, &pos), // func: typeidx
                    1 => { // table: elemtype + limits
                        pos += 1;
                        const flags: u8 = bytes[pos];
                        pos += 1;
                        _ = readU32Leb(bytes, &pos);
                        if (flags & 1 != 0) {
                            _ = readU32Leb(bytes, &pos);
                        }
                    },
                    2 => { // mem: limits
                        const flags: u8 = bytes[pos];
                        pos += 1;
                        _ = readU32Leb(bytes, &pos);
                        if (flags & 1 != 0) {
                            _ = readU32Leb(bytes, &pos);
                        }
                    },
                    3 => pos += 2, // global: valtype + mut
                    else => return error.BadImportKind,
                }
                try sink(ctx, module, field);
            }
            return; // import section handled; nothing after it matters here
        }
    }
};

/// True when bridge source registers `field` via a `.set("field", …)` call.
/// Scans for the quoted literal, tolerating the multi-line `.set(\n  "js_x",`
/// form (host names are globally unique, so namespace need not be matched).
fn bridgeProvides(bridge: []const u8, field: []const u8) bool {
    var buf: [256]u8 = undefined;
    if (field.len + 2 > buf.len) {
        return false;
    }
    buf[0] = '"';
    @memcpy(buf[1 .. 1 + field.len], field);
    buf[1 + field.len] = '"';
    return std.mem.indexOf(u8, bridge, buf[0 .. field.len + 2]) != null;
}

const Ctx = struct {
    bridge: []const u8,
    missing: *usize,
    total: *usize,
    path: []const u8,
};

fn check(ctx: *Ctx, module: []const u8, field: []const u8) !void {
    if (std.mem.eql(u8, module, "wasi_snapshot_preview1")) {
        return; // WASI shim, not the bridge's job
    }
    ctx.total.* += 1;
    if (!bridgeProvides(ctx.bridge, field)) {
        ctx.missing.* += 1;
        std.debug.print("   {s}: {s}.{s}\n", .{ ctx.path, module, field });
    }
}

const Counts = struct { modules: usize = 0, bad: usize = 0, missing: usize = 0 };

fn checkOne(
    io: std.Io,
    arena: std.mem.Allocator,
    bridge: []const u8,
    path: []const u8,
    c: *Counts,
) !void {
    const wasm: []u8 = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch return;
    c.modules += 1;
    var missing: usize = 0;
    var total: usize = 0;
    var ctx: Ctx = .{ .bridge = bridge, .missing = &missing, .total = &total, .path = path };
    try WasmImports.each(wasm, &ctx, check);
    if (missing != 0) {
        c.bad += 1;
        c.missing += missing;
    }
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io: std.Io = init.io;
    const argv: []const [:0]const u8 = try init.minimal.args.toSlice(arena);
    if (argv.len < 3) {
        std.debug.print("usage: verify_imports <bridge.zig> <wasm-or-dir> [<wasm-or-dir> ...]\n", .{});
        return error.Usage;
    }
    // The bridge is read once and reused across every wasm in the batch.
    const bridge: []u8 = try std.Io.Dir.cwd().readFileAlloc(io, argv[1], arena, .unlimited);

    var c: Counts = .{};
    for (argv[2..]) |path| {
        // A directory arg is scanned (flat) for *.wasm; anything else is a wasm file.
        if (std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true })) |dir_opened| {
            var dir: std.Io.Dir = dir_opened;
            var it: std.Io.Dir.Iterator = dir.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind != .file) {
                    continue;
                }
                if (!std.mem.endsWith(u8, entry.name, ".wasm")) {
                    continue;
                }
                const full: []const u8 = try std.fs.path.join(arena, &.{ path, entry.name });
                try checkOne(io, arena, bridge, full, &c);
            }
        } else |_| {
            try checkOne(io, arena, bridge, path, &c);
        }
    }
    if (c.bad == 0) {
        std.debug.print("verify-imports: PASS ({d} module(s), all host imports provided by bridge)\n", .{c.modules});
        return;
    }
    std.debug.print(
        "verify-imports: FAIL — {d} unprovided host import(s) across {d} module(s) (see above). " ++
            "Add a `.set(\"js_x\", ...)` in src/bridge.zig.\n",
        .{ c.missing, c.bad },
    );
    return error.ImportsMissing;
}
