//! transpiler_corpus.zig — the spv2wgsl differential/fixture corpus test,
//! ported from webtests/transpiler_corpus.ts (ZIG_BRIDGE_PLAN Phase 5c).
//! Compiled to wasm32, transpiled to JS by our own c2js, run by
//! webtests/runner.mjs. DOGFOOD: all logic is Zig through our pipeline;
//! runner.mjs only does WebAssembly.instantiate + fs + the host primitives.
//!
//! What it does (mirrors the .ts so output is byte-identical):
//!   1. Walk a corpus root (default .zig-cache) for *.rewritten.spv inputs
//!      (the zspv output that the shipping WGSL path feeds into spv2wgsl;
//!      spirv-opt is disabled so .opt.spv is no longer produced).
//!   2. Dedup by MD5 of the SPIR-V bytes (md5File via runner), size-sorted.
//!   3. For each: write the SPIR-V into the transpiler wasm's input buffer,
//!      call transpile(len) -> packed ptr|len, read the WGSL back out of the
//!      wasm's memory, MD5 it (std.crypto.hash.Md5, in Zig), scan for
//!      __unresolved_N__ placeholders.
//!   4. Print the corpus summary + per-shader detail table.
//!   5. Fixture: --refresh-fixture writes tests/fixtures/wgsl_corpus.json;
//!      default CHECKS it (every fixture entry must match a live WGSL hash;
//!      a drift is a REGRESSION and exits non-zero).

const Handle = u32;
extern fn js_global() Handle;
extern fn js_get(o: Handle, p: [*]const u8, l: u32) Handle;
extern fn js_get_index(o: Handle, i: u32) Handle;
extern fn js_get_num(o: Handle, p: [*]const u8, l: u32) f64;
extern fn js_call0(o: Handle, p: [*]const u8, l: u32) Handle;
extern fn js_call1(o: Handle, p: [*]const u8, l: u32, a: Handle) Handle;
extern fn js_call1v(o: Handle, p: [*]const u8, l: u32, a: Handle) void;
extern fn js_call2(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: Handle,
    b: Handle,
) Handle;
extern fn js_call3(
    o: Handle,
    p: [*]const u8,
    l: u32,
    a: Handle,
    b: Handle,
    c: Handle,
) Handle;
extern fn js_str(p: [*]const u8, l: u32) Handle;
extern fn js_num(x: f64) Handle;
extern fn js_to_num(h: Handle) f64;
extern fn js_obj() Handle;
extern fn js_new0(ctor: Handle) Handle;
extern fn js_set(o: Handle, p: [*]const u8, l: u32, v: Handle) void;
extern fn js_string_into(h: Handle, p: [*]u8, max: u32) u32;
extern fn js_is_null(h: Handle) u32;

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;

fn g() Handle {
    return js_global();
}
fn host() Handle {
    return js_get(g(), "__host", 6);
}
fn s(text: []const u8) Handle {
    return js_str(text.ptr, @intCast(text.len));
}
fn n(x: f64) Handle {
    return js_num(x);
}
fn arr() Handle {
    return js_new0(js_get(g(), "Array", 5));
}
fn push(a: Handle, v: Handle) void {
    _ = js_call1(a, "push", 4, v);
}
fn print(text: []const u8) void {
    js_call1v(host(), "print", 5, s(text));
}
// Format into a scratch buffer and print; keeps call sites short. The buffer
// is generous; on overflow it prints the fallback (never happens here).
fn printf(comptime fmt: []const u8, args: anytype) void {
    var buf: [320]u8 = undefined;
    print(bufPrint(&buf, fmt, args) catch fmt);
}
fn eprint(text: []const u8) void {
    js_call1v(host(), "eprint", 6, s(text));
}
fn isNull(h: Handle) bool {
    return js_is_null(h) != 0;
}
fn jsStrInto(h: Handle, buf: []u8) []const u8 {
    const cnt: u32 = js_string_into(h, buf.ptr, @intCast(buf.len));
    return buf[0..cnt];
}

// A "=" * 72 / "-" * 72 rule line.
fn rule(comptime ch: u8) void {
    const line: [72]u8 = @splat(ch);
    print(&line);
}

const max_shaders = 256;
const Status = enum { ok_clean, ok_gaps, transpile_error, panicked };

const ShaderResult = struct {
    md5: [32]u8 = @splat(0),
    wgsl_md5: [32]u8 = @splat(0),
    size_bytes: u32 = 0,
    wgsl_lines: u32 = 0,
    unresolved_total: u32 = 0,
    unresolved_distinct: u32 = 0,
    status: Status = .transpile_error,
    path_off: u32 = 0, // offset into path_pool
    path_len: u32 = 0,
};

// State singleton (no allocator under the c2js runtime).
const State = struct {
    results: [max_shaders]ShaderResult = undefined,
    n: u32 = 0,
    path_pool: [max_shaders * 256]u8 = undefined,
    path_used: u32 = 0,
    sut_id: Handle = 0,
    refresh: bool = false,
};
// lint:off module-var: the one driver-state singleton for this test harness
var st: State = .{};

const PathRef = struct { off: u32, len: u32 };
fn storePath(p: []const u8) PathRef {
    const off: u32 = st.path_used;
    const cap: usize = @min(p.len, st.path_pool.len - st.path_used);
    @memcpy(st.path_pool[off .. off + cap], p[0..cap]);
    st.path_used += @intCast(cap);
    return .{ .off = off, .len = @intCast(cap) };
}
fn pathOf(r: ShaderResult) []const u8 {
    return st.path_pool[r.path_off .. r.path_off + r.path_len];
}

// MD5 of bytes as lowercase hex (Zig-side, for WGSL hashing).
fn md5Hex(bytes: []const u8, out: *[32]u8) void {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(bytes, &digest, .{});
    const hex: []const u8 = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
}

// Count "__unresolved_N__" occurrences (total + distinct ids) in WGSL.
const Scan = struct { total: u32, distinct: u32 };
fn scanWgsl(wgsl: []const u8) Scan {
    var total: u32 = 0;
    var seen: [128]u32 = @splat(0);
    var seen_n: u32 = 0;
    const needle: []const u8 = "__unresolved_";
    var i: usize = 0;
    while (i + needle.len < wgsl.len) {
        if (eql(u8, wgsl[i .. i + needle.len], needle)) {
            // parse the digits
            var j: usize = i + needle.len;
            var id: u32 = 0;
            var any: bool = false;
            while (j < wgsl.len and wgsl[j] >= '0' and wgsl[j] <= '9') {
                id = id * 10 + @as(u32, wgsl[j] - '0');
                j += 1;
                any = true;
            }
            if (any and j + 1 < wgsl.len and wgsl[j] == '_' and wgsl[j + 1] == '_') {
                total += 1;
                var found: bool = false;
                var k: u32 = 0;
                while (k < seen_n) : (k += 1) {
                    if (seen[k] == id) {
                        found = true;
                        break;
                    }
                }
                if (!found and seen_n < seen.len) {
                    seen[seen_n] = id;
                    seen_n += 1;
                }
                i = j + 2;
                continue;
            }
        }
        i += 1;
    }
    return .{ .total = total, .distinct = seen_n };
}

// Transpile one shader: write SPIR-V into the SUT input buffer, call
// transpile(len), read WGSL back. Returns the WGSL into `out_buf` or null.
fn transpileOne(spv_path: []const u8, out_buf: []u8) ?[]const u8 {
    // read the spv bytes via the host into a JS array, get length
    const bytes_h: Handle = js_call1(host(), "readFile", 8, s(spv_path));
    if (isNull(bytes_h)) {
        return null;
    }
    const spv_len: u32 = @trunc(js_get_num(bytes_h, "length", 6));
    const cap_h: Handle = js_call2(host(), "sutCall", 7, st.sut_id, s("input_buffer_capacity"));
    const cap: u32 = @trunc(js_to_num(cap_h));
    if (spv_len > cap) {
        return null;
    }
    const ptr_h: Handle = js_call2(host(), "sutCall", 7, st.sut_id, s("input_buffer_ptr"));
    const in_ptr: u32 = @trunc(js_to_num(ptr_h));
    // write the bytes into the SUT memory
    _ = js_call3(host(), "sutMemWrite", 11, st.sut_id, n(@floatFromInt(in_ptr)), bytes_h);
    // call transpile(len) -> packed {ptr,len} or null
    const packed_h: Handle = js_call3(
        host(),
        "sutCallPacked",
        13,
        st.sut_id,
        s("transpile"),
        n(@floatFromInt(spv_len)),
    );
    if (isNull(packed_h)) {
        return null;
    }
    const out_ptr: u32 = @trunc(js_get_num(packed_h, "ptr", 3));
    const out_len: u32 = @trunc(js_get_num(packed_h, "len", 3));
    if (out_len > out_buf.len) {
        return null;
    }
    // read the WGSL bytes back out of SUT memory (array of byte numbers)
    const wgsl_h: Handle = js_call3(
        host(),
        "sutMemRead",
        10,
        st.sut_id,
        n(@floatFromInt(out_ptr)),
        n(@floatFromInt(out_len)),
    );
    var i: u32 = 0;
    while (i < out_len) : (i += 1) {
        out_buf[i] = @trunc(js_to_num(js_get_index(wgsl_h, i)));
    }
    return out_buf[0..out_len];
}

fn statusLabel(status: Status) []const u8 {
    return switch (status) {
        .ok_clean => "\u{2713} clean",
        .ok_gaps => "\u{26a0} gaps ",
        .transpile_error => "\u{2717} transp",
        .panicked => "\u{2717} panick",
    };
}

export fn _start() void {
    // ---- args ----
    const argv: Handle = js_call0(host(), "argv", 4);
    const argc: u32 = @trunc(js_get_num(argv, "length", 6));
    var root_buf: [512]u8 = undefined;
    var root_len: u32 = 0;
    var i: u32 = 0;
    var abuf: [512]u8 = undefined;
    while (i < argc) : (i += 1) {
        const a: []const u8 = jsStrInto(js_get_index(argv, i), &abuf);
        if (eql(u8, a, "--refresh-fixture")) {
            st.refresh = true;
        } else if (!startsWith(u8, a, "--") and root_len == 0) {
            @memcpy(root_buf[0..a.len], a);
            root_len = @intCast(a.len);
        }
    }
    const root: []const u8 = if (root_len > 0) root_buf[0..root_len] else ".zig-cache";

    // ---- load transpiler wasm ----
    const wasm_path: []const u8 = "zig-out/wgpu/spv2wgsl.wasm";
    const wasm_bytes: Handle = js_call1(host(), "readFile", 8, s(wasm_path));
    if (isNull(wasm_bytes)) {
        eprint("\u{2717} failed to load transpiler wasm at zig-out/wgpu/spv2wgsl.wasm");
        eprint("  Did you run `zig build corpus`?");
        js_call1v(host(), "exit", 4, n(1));
        return;
    }
    // import spec: just wasi (runner Proxy-stubs every fn success-y)
    const spec: Handle = js_obj();
    const namespaces: Handle = js_obj();
    js_set(namespaces, "wasi_snapshot_preview1", 22, arr());
    js_set(spec, "namespaces", 10, namespaces);
    const id_h: Handle = js_call2(host(), "instantiateSut", 14, wasm_bytes, spec);
    if (js_to_num(id_h) < 0) {
        eprint("\u{2717} failed to instantiate transpiler wasm");
        js_call1v(host(), "exit", 4, n(1));
        return;
    }
    st.sut_id = id_h;
    _ = js_call2(host(), "sutCall", 7, st.sut_id, s("_initialize"));
    const cap_h: Handle = js_call2(host(), "sutCall", 7, st.sut_id, s("input_buffer_capacity"));
    const cap: u32 = @trunc(js_to_num(cap_h));
    const cap_str_h: Handle = js_call0(js_num(@floatFromInt(cap)), "toLocaleString", 14);
    var capnum: [48]u8 = undefined;
    const cap_str: []const u8 = jsStrInto(cap_str_h, &capnum);
    printf("\u{2713} loaded transpiler wasm (capacity {s} bytes)", .{cap_str});

    // ---- find + dedup .rewritten.spv (the real spv2wgsl input) ----
    var sbuf: [256]u8 = undefined;
    print(bufPrint(&sbuf, "scanning {s}/ for .spv files...", .{root}) catch "scanning");
    const listing_h: Handle = js_call2(host(), "listFiles", 9, s(root), s(".rewritten.spv"));
    var lbuf: [65536]u8 = undefined;
    const listing: []const u8 = jsStrInto(listing_h, &lbuf);

    var total_files: u32 = 0;
    var it = std.mem.splitScalar(u8, listing, '\n');
    // First pass: dedup by md5 of spv bytes (md5File via host), collect.
    while (it.next()) |path| {
        if (path.len == 0) {
            continue;
        }
        total_files += 1;
        if (st.n >= max_shaders) {
            continue;
        }
        var hbuf: [40]u8 = undefined;
        const md5_h: Handle = js_call1(host(), "md5File", 7, s(path));
        const md5: []const u8 = jsStrInto(md5_h, &hbuf);
        if (md5.len == 0) {
            continue;
        }
        // dedup
        var dup: bool = false;
        var k: u32 = 0;
        while (k < st.n) : (k += 1) {
            if (eql(u8, &st.results[k].md5, md5[0..@min(md5.len, 32)])) {
                dup = true;
                break;
            }
        }
        if (dup) {
            continue;
        }
        const sz_h: Handle = js_call1(host(), "fileSize", 8, s(path));
        const sz: u32 = @trunc(js_to_num(sz_h));
        var r: ShaderResult = .{};
        @memcpy(r.md5[0..@min(md5.len, 32)], md5[0..@min(md5.len, 32)]);
        r.size_bytes = sz;
        const sp: PathRef = storePath(path);
        r.path_off = sp.off;
        r.path_len = sp.len;
        st.results[st.n] = r;
        st.n += 1;
    }
    // size-sort ascending (simple insertion sort; n is small)
    var a: u32 = 1;
    while (a < st.n) : (a += 1) {
        const key = st.results[a];
        var b: i64 = @as(i64, a) - 1;
        while (b >= 0 and st.results[@intCast(b)].size_bytes > key.size_bytes) {
            st.results[@intCast(b + 1)] = st.results[@intCast(b)];
            b -= 1;
        }
        st.results[@intCast(b + 1)] = key;
    }
    var fbuf: [128]u8 = undefined;
    print(bufPrint(&fbuf, "  found {d} files, {d} unique by md5", .{ total_files, st.n }) catch "  found");
    print("");

    // ---- transpile each ----
    var wgsl_buf: [262144]u8 = undefined;
    i = 0;
    while (i < st.n) : (i += 1) {
        const out = transpileOne(pathOf(st.results[i]), &wgsl_buf);
        if (out) |wgsl| {
            st.results[i].wgsl_lines = countLines(wgsl);
            md5Hex(wgsl, &st.results[i].wgsl_md5);
            const scan = scanWgsl(wgsl);
            st.results[i].unresolved_total = scan.total;
            st.results[i].unresolved_distinct = scan.distinct;
            st.results[i].status = if (scan.total == 0) .ok_clean else .ok_gaps;
        } else {
            st.results[i].status = .transpile_error;
        }
    }

    report();

    if (st.refresh) {
        refreshFixture();
    } else {
        checkFixture();
    }
}

fn countLines(text: []const u8) u32 {
    var lines: u32 = 1;
    for (text) |c| {
        if (c == '\n') {
            lines += 1;
        }
    }
    return lines;
}

fn report() void {
    var clean: u32 = 0;
    var gaps: u32 = 0;
    var errored: u32 = 0;
    var i: u32 = 0;
    while (i < st.n) : (i += 1) {
        switch (st.results[i].status) {
            .ok_clean => clean += 1,
            .ok_gaps => gaps += 1,
            else => errored += 1,
        }
    }
    rule('=');
    var b: [96]u8 = undefined;
    print(bufPrint(&b, "CORPUS: {d} unique SPIR-V shaders", .{st.n}) catch "CORPUS");
    rule('=');
    print(bufPrint(&b, "  \u{2713} transpiled cleanly (zero unresolved):  {d}", .{clean}) catch "");
    print(bufPrint(&b, "  \u{26a0} transpiled with gaps:                  {d}", .{gaps}) catch "");
    print(bufPrint(&b, "  \u{2717} transpile failed (panic / error):      {d}", .{errored}) catch "");
    // clean rate to one decimal. The .ts computes clean/total*100 which is
    // NaN when total==0 (JS 0/0); match that exactly.
    if (st.n == 0) {
        print("  clean rate:                              NaN%");
    } else {
        const tenths: u32 = (clean * 1000 + st.n / 2) / st.n;
        printf("  clean rate:                              {d}.{d}%", .{ tenths / 10, tenths % 10 });
    }

    // Per-shader detail table (sorted by status score, then size).
    sortByStatusThenSize();
    print("");
    print("Per-shader detail (sorted by status, then size):");
    rule('-');
    // The header is padEnd(72): "  status  spv-bytes   wgsl-lines  unresolved   shader" + trailing spaces.
    const header: []const u8 = "  status  spv-bytes   wgsl-lines  unresolved   shader";
    var hbuf: [80]u8 = undefined;
    @memcpy(hbuf[0..header.len], header);
    var hp: usize = header.len;
    while (hp < 72) : (hp += 1) {
        hbuf[hp] = ' ';
    }
    print(hbuf[0..72]);
    rule('-');
    var ri: u32 = 0;
    while (ri < st.n) : (ri += 1) {
        printDetailRow(st.results[ri]);
    }

    print("");
    rule('=');
    if (clean == st.n) {
        print("\u{2713} ENTIRE CORPUS TRANSPILES CLEANLY");
    } else {
        var distinct_sum: u32 = 0;
        var j: u32 = 0;
        while (j < st.n) : (j += 1) {
            if (st.results[j].status == .ok_gaps) {
                distinct_sum += st.results[j].unresolved_distinct;
            }
        }
        printf(
            "Top priority: identify which opcodes produce the {d} unresolved ids across the dirty shaders.",
            .{distinct_sum},
        );
    }
}

fn statusScore(status: Status) u32 {
    return switch (status) {
        .ok_clean => 0,
        .ok_gaps => 1,
        else => 2,
    };
}

fn sortByStatusThenSize() void {
    var a: u32 = 1;
    while (a < st.n) : (a += 1) {
        const key = st.results[a];
        var b: i64 = @as(i64, a) - 1;
        while (b >= 0) {
            const cur = st.results[@intCast(b)];
            const swap = statusScore(cur.status) > statusScore(key.status) or
                (statusScore(cur.status) == statusScore(key.status) and cur.size_bytes > key.size_bytes);
            if (!swap) {
                break;
            }
            st.results[@intCast(b + 1)] = cur;
            b -= 1;
        }
        st.results[@intCast(b + 1)] = key;
    }
}

// One detail row matching the .ts padding exactly:
//   "  {status:pad7} {size:>7}     {wgslLines:>5}      {unresolved:pad12} {shortPath}"
fn printDetailRow(r: ShaderResult) void {
    var b: [320]u8 = undefined;
    var w: usize = 0;
    const status: []const u8 = switch (r.status) {
        .ok_clean => "\u{2713} clean",
        .ok_gaps => "\u{26a0} gaps ",
        .transpile_error => "\u{2717} transp",
        .panicked => "\u{2717} panick",
    };
    // "  " + status.padEnd(7) + " "
    b[w] = ' ';
    w += 1;
    b[w] = ' ';
    w += 1;
    w += writePadEnd(b[w..], status, 7);
    b[w] = ' ';
    w += 1;
    // size.padStart(7)
    var num: [16]u8 = undefined;
    const size_str: []const u8 = bufPrint(&num, "{d}", .{r.size_bytes}) catch "0";
    w += writePadStart(b[w..], size_str, 7);
    // "     "
    @memcpy(b[w .. w + 5], "     ");
    w += 5;
    // wgsl-lines: padStart(5) or "    -"
    if (r.status == .ok_clean or r.status == .ok_gaps) {
        var lb: [16]u8 = undefined;
        const ls: []const u8 = bufPrint(&lb, "{d}", .{r.wgsl_lines}) catch "0";
        w += writePadStart(b[w..], ls, 5);
    } else {
        @memcpy(b[w .. w + 5], "    -");
        w += 5;
    }
    // "      "
    @memcpy(b[w .. w + 6], "      ");
    w += 6;
    // unresolved: "{distinct}id/{total}ref" padEnd(12), or "-" padEnd(12)
    var ub: [32]u8 = undefined;
    const unres: []const u8 = if (r.status == .ok_clean or r.status == .ok_gaps)
        bufPrint(&ub, "{d}id/{d}ref", .{ r.unresolved_distinct, r.unresolved_total }) catch "-"
    else
        "-";
    w += writePadEnd(b[w..], unres, 12);
    b[w] = ' ';
    w += 1;
    // shortPath: strip everything up to and including ".zig-cache/"
    const full: []const u8 = pathOf(r);
    const short: []const u8 = stripCachePrefix(full);
    @memcpy(b[w .. w + short.len], short);
    w += short.len;
    print(b[0..w]);
}

fn writePadEnd(dst: []u8, text: []const u8, width: usize) usize {
    @memcpy(dst[0..text.len], text);
    var w: usize = text.len;
    while (w < width) : (w += 1) {
        dst[w] = ' ';
    }
    return w;
}
fn writePadStart(dst: []u8, text: []const u8, width: usize) usize {
    var w: usize = 0;
    if (text.len < width) {
        const pad: usize = width - text.len;
        while (w < pad) : (w += 1) {
            dst[w] = ' ';
        }
    }
    @memcpy(dst[w .. w + text.len], text);
    return w + text.len;
}
fn stripCachePrefix(p: []const u8) []const u8 {
    const marker: []const u8 = ".zig-cache/";
    if (std.mem.indexOf(u8, p, marker)) |idx| {
        return p[idx + marker.len ..];
    }
    return p;
}

// Build a fixture-JSON string {version, refreshed_at, expected:{spvMd5:wgslMd5}}
// and write it; only clean results with zero unresolved go in.
fn refreshFixture() void {
    var json: [65536]u8 = undefined;
    var w: usize = 0;
    const head: []const u8 = "{\n  \"version\": 1,\n  \"expected\": {\n";
    @memcpy(json[0..head.len], head);
    w += head.len;
    var first: bool = true;
    var i: u32 = 0;
    while (i < st.n) : (i += 1) {
        const r = st.results[i];
        if (r.status != .ok_clean) {
            continue;
        }
        if (!first) {
            json[w] = ',';
            w += 1;
            json[w] = '\n';
            w += 1;
        }
        first = false;
        const seg = bufPrint(json[w..], "    \"{s}\": \"{s}\"", .{ r.md5, r.wgsl_md5 }) catch break;
        w += seg.len;
    }

    // ---- MERGE, don't replace: carry forward pinned entries whose
    // SPIR-V isn't among the live set.  The live scan is whatever
    // `.zig-cache` currently holds, which is BUILD-STATE-DEPENDENT — a
    // partially evicted cache once silently shrank the fixture from 97
    // pinned shaders to 47.  Entries for shaders that merely aren't
    // built right now must survive a refresh; genuinely deleted shaders
    // accumulate as stale pins until a deliberate manual prune, which
    // is the safe direction to fail in.
    var carried: u32 = 0;
    const raw_h: Handle = js_call1(host(), "readText", 8, s("tests/fixtures/wgsl_corpus.json"));
    if (!isNull(raw_h)) {
        var rbuf: [65536]u8 = undefined;
        const raw: []const u8 = jsStrInto(raw_h, &rbuf);
        const json_obj: Handle = js_call1(js_get(g(), "JSON", 4), "parse", 5, s(raw));
        const expected: Handle = js_get(json_obj, "expected", 8);
        const keys_h: Handle = js_call1(js_get(g(), "Object", 6), "keys", 4, expected);
        const vals_h: Handle = js_call1(js_get(g(), "Object", 6), "values", 6, expected);
        const key_count: u32 = @trunc(js_get_num(keys_h, "length", 6));
        var kbuf: [40]u8 = undefined;
        var vbuf: [40]u8 = undefined;
        var k: u32 = 0;
        while (k < key_count) : (k += 1) {
            const old_key: []const u8 = jsStrInto(js_get_index(keys_h, k), &kbuf);
            // Skip entries the live pass already (re)wrote.
            var live: bool = false;
            var li: u32 = 0;
            while (li < st.n) : (li += 1) {
                if (st.results[li].status != .ok_clean) {
                    continue;
                }
                const lm: []const u8 = st.results[li].md5[0..];
                if (eql(u8, lm[0..@min(lm.len, old_key.len)], old_key)) {
                    live = true;
                    break;
                }
            }
            if (live) {
                continue;
            }
            const old_val: []const u8 = jsStrInto(js_get_index(vals_h, k), &vbuf);
            if (!first) {
                json[w] = ',';
                w += 1;
                json[w] = '\n';
                w += 1;
            }
            first = false;
            const seg = bufPrint(json[w..], "    \"{s}\": \"{s}\"", .{ old_key, old_val }) catch break;
            w += seg.len;
            carried += 1;
        }
    }

    const tail: []const u8 = "\n  }\n}\n";
    @memcpy(json[w .. w + tail.len], tail);
    w += tail.len;
    _ = js_call2(host(), "writeFile", 9, s("tests/fixtures/wgsl_corpus.json"), s(json[0..w]));
    print("");
    var b: [128]u8 = undefined;
    print(bufPrint(
        &b,
        "\u{2713} wrote fixture: tests/fixtures/wgsl_corpus.json ({d} live + {d} carried)",
        .{ st.n, carried },
    ) catch "");
}

// Load the fixture, check every entry matches a live WGSL hash. Drift ->
// regression -> exit 2.
fn checkFixture() void {
    print("");
    const raw_h: Handle = js_call1(host(), "readText", 8, s("tests/fixtures/wgsl_corpus.json"));
    if (isNull(raw_h)) {
        print("(no fixture at tests/fixtures/wgsl_corpus.json; run with --refresh-fixture to create one)");
        return;
    }
    // Parse JSON via host JSON.parse (avoids a Zig JSON parser through the bridge).
    var rbuf: [65536]u8 = undefined;
    const raw: []const u8 = jsStrInto(raw_h, &rbuf);
    const json_obj: Handle = js_call1(js_get(g(), "JSON", 4), "parse", 5, s(raw));
    const expected: Handle = js_get(json_obj, "expected", 8);
    const keys_h: Handle = js_call1(js_get(g(), "Object", 6), "keys", 4, expected);
    const vals_h: Handle = js_call1(js_get(g(), "Object", 6), "values", 6, expected);
    const key_count: u32 = @trunc(js_get_num(keys_h, "length", 6));

    var regressions: u32 = 0;
    var missing_live: u32 = 0;
    var kbuf: [40]u8 = undefined;
    var vbuf: [40]u8 = undefined;
    var b: [160]u8 = undefined;
    var k: u32 = 0;
    while (k < key_count) : (k += 1) {
        const spv_md5_h: Handle = js_get_index(keys_h, k);
        const spv_md5: []const u8 = jsStrInto(spv_md5_h, &kbuf);
        // Read the expected WGSL md5 by the SAME index (parallel arrays).
        // NB: do NOT look it up via js_get(expected, spv_md5.ptr, len) — the
        // c2js kernel's __jstr caches decoded strings by POINTER, and spv_md5
        // reuses one stack buffer (kbuf) every iteration, so a pointer-keyed
        // lookup would return the first key's value forever. Indexing
        // Object.values sidesteps the cache entirely.
        const exp_wgsl_h: Handle = js_get_index(vals_h, k);
        const exp_wgsl: []const u8 = jsStrInto(exp_wgsl_h, &vbuf);
        // find a live result with this spv md5
        var live_idx: i64 = -1;
        var i: u32 = 0;
        while (i < st.n) : (i += 1) {
            if (eql(u8, st.results[i].md5[0..@min(spv_md5.len, 32)], spv_md5[0..@min(spv_md5.len, 32)])) {
                live_idx = i;
                break;
            }
        }
        if (live_idx < 0) {
            missing_live += 1;
            printf(
                "  \u{26a0} fixture entry {s}... has no matching live shader (input went away?)",
                .{spv_md5[0..@min(spv_md5.len, 8)]},
            );
            continue;
        }
        const live = st.results[@intCast(live_idx)];
        if (live.status != .ok_clean and live.status != .ok_gaps) {
            regressions += 1;
            printf("  \u{2717} REGRESSION: {s}... was clean, now failed", .{spv_md5[0..@min(spv_md5.len, 8)]});
            continue;
        }
        if (!eql(u8, live.wgsl_md5[0..@min(exp_wgsl.len, 32)], exp_wgsl[0..@min(exp_wgsl.len, 32)])) {
            regressions += 1;
            printf("  \u{2717} REGRESSION: {s}... WGSL drifted", .{spv_md5[0..@min(spv_md5.len, 8)]});
        }
    }

    print(bufPrint(&b, "Fixture check: {d} entries in tests/fixtures/wgsl_corpus.json", .{key_count}) catch "");
    if (missing_live > 0) {
        printf("  \u{26a0} {d} fixture entries have no matching live input", .{missing_live});
        printf("  \u{26a0} STALE CORPUS: dead fixtures are untested shaders. If the shader set or", .{});
        printf("  \u{26a0} layouts changed intentionally, run `zig build corpus-refresh` to re-pin.", .{});
    }
    if (regressions > 0) {
        printf("\u{2717} {d} REGRESSION(S) - transpiler output drift detected", .{regressions});
        js_call1v(host(), "exit", 4, n(2));
        return;
    }
    print("\u{2713} NO REGRESSIONS");
}
