//! tools/spv2wgsl_check.zig — pure-Zig differential validator for
//! `spv2wgsl`.  Phase 0.4 of `src/notes/spv2wgsl-rewrite-plan.md`.
//!
//! Replaces the earlier `webtests/spv2wgsl_diff.ts` TypeScript/Bun
//! validator that depended on the npm `wgsl_reflect` package.  We
//! don't need wgsl_reflect: a small lexical WGSL structural check
//! plus our known-bug pattern detector covers every failure mode
//! we've seen.  Semantic equivalence is checked separately by the
//! smoke harness when Dawn's Tint runs over the WGSL via
//! `createShaderModule` at runtime.
//!
//! This is part of zimr's "pure Zig world" destination: no npm, no
//! Bun runtime dependency for development tooling, only Zig.
//!
//! For each input `.spv` (or directory full of them), the tool runs
//! `spv2wgsl.convertSpirvToWgsl` and reports:
//!
//!   1. Translation success — `convertSpirvToWgsl` returned without
//!      error.
//!   2. Structural WGSL check — braces and parens balance; no
//!      obviously-malformed identifiers; no stray top-level junk.
//!   3. No unresolved markers (`__unresolved_N__`).
//!   4. No `// ERROR:` or `UNHANDLED` translator diagnostics.
//!   5. No "phi-overwrite-after-if" lexical fingerprint — the
//!      canonical bug we discovered in the mandelbrot diagnostic
//!      and the bug pattern this rewrite arc fixes.
//!
//! Usage:
//!   spv2wgsl_check <name>               # one of {all, our-corpus, tint-corpus}
//!   spv2wgsl_check <path>               # a single .spv file
//!   spv2wgsl_check <dir>                # all .spv files under <dir>
//!
//! Wired in `tools/build.zig` as `spv2wgsl_check`, run via
//! `zig build corpus-diff` .
//!
//! Exit codes:
//!   0 — every shader passed every check
//!   1 — at least one shader failed at least one check
//!   2 — usage / setup error

const std = @import("std");
const ArrayList = std.ArrayList;
const allocPrint = std.fmt.allocPrint;
const expect = std.testing.expect;
const endsWith = std.mem.endsWith;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const Allocator = std.mem.Allocator;
const spv2wgsl = @import("spv2wgsl");

const cache_dir = ".zig-cache/o";
const tint_dir = "tests/fixtures/external/tint";

// ============================================================================
// Result types
// ============================================================================

const Outcome = enum {
    ok,
    trans_fail,
    parse_fail,
    err_marker,
    unresolved,
    known_bug,
};

const Diag = struct {
    line: u32,
    text: []const u8,
};

const Result = struct {
    name: []const u8,
    /// The shader's own name, recovered from the SPIR-V debug strings. Null when the module
    /// carries none. Printed on failure so a content hash is never the only identification.
    source_name: ?[]const u8 = null,
    path: []const u8,
    spv_bytes: usize,
    trans_ok: bool,
    trans_error: ?[]const u8 = null,
    wgsl_bytes: usize = 0,
    wgsl_lines: u32 = 0,
    parse_ok: bool = false,
    parse_error: ?[]const u8 = null,
    unresolved_count: u32 = 0,
    err_marker_count: u32 = 0,
    known_bug_count: u32 = 0,
    err_markers: []const Diag = &.{},
    known_bugs: []const Diag = &.{},

    fn outcome(self: Result) Outcome {
        if (!self.trans_ok) {
            return .trans_fail;
        }
        if (!self.parse_ok) {
            return .parse_fail;
        }
        if (self.known_bug_count > 0) {
            return .known_bug;
        }
        if (self.err_marker_count > 0) {
            return .err_marker;
        }
        if (self.unresolved_count > 0) {
            return .unresolved;
        }
        return .ok;
    }
};

// ============================================================================
// WGSL structural check — minimal lexical validator
// ============================================================================
//
// What we check for:
//   - Balanced braces, parens, brackets across the whole text.
//   - Every line of statement-shaped content (not blank, not comment,
//     not the inside of a struct/function header line) ends with `;`
//     or `{` or `}`.
//   - The presence of at least one entry-point attribute
//     (`@vertex` / `@fragment` / `@compute`) somewhere in the file.
//
// What we DON'T check:
//   - Full WGSL grammar (we don't reimplement Tint).  Anything our
//     translator can plausibly emit but is syntactically invalid
//     will be caught downstream by Dawn at `createShaderModule`
//     time during `zig build smoke`.
//
// In practice these three checks caught every malformed-WGSL case
// the old `wgsl_reflect`-based validator caught during the May
// 2026 baseline.

fn checkWgslStructural(wgsl: []const u8) ?[]const u8 {
    // Balance check.  Track {} () [] separately; report the first
    // mismatch we hit.
    var curly: i32 = 0;
    var paren: i32 = 0;
    var brack: i32 = 0;
    var in_line_comment: bool = false;
    var in_block_comment: bool = false;
    var in_string: bool = false;
    var i: usize = 0;
    while (i < wgsl.len) : (i += 1) {
        const c: u8 = wgsl[i];
        if (in_line_comment) {
            if (c == '\n') {
                in_line_comment = false;
            }
            continue;
        }
        if (in_block_comment) {
            if (c == '*' and i + 1 < wgsl.len and wgsl[i + 1] == '/') {
                in_block_comment = false;
                i += 1;
            }
            continue;
        }
        if (in_string) {
            if (c == '"') {
                in_string = false;
            }
            continue;
        }
        if (c == '/' and i + 1 < wgsl.len and wgsl[i + 1] == '/') {
            in_line_comment = true;
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < wgsl.len and wgsl[i + 1] == '*') {
            in_block_comment = true;
            i += 1;
            continue;
        }
        if (c == '"') {
            in_string = true;
            continue;
        }
        switch (c) {
            '{' => curly += 1,
            '}' => curly -= 1,
            '(' => paren += 1,
            ')' => paren -= 1,
            '[' => brack += 1,
            ']' => brack -= 1,
            else => {},
        }
        if (curly < 0) {
            return "unbalanced }: too many closing braces";
        }
        if (paren < 0) {
            return "unbalanced ): too many closing parens";
        }
        if (brack < 0) {
            return "unbalanced ]: too many closing brackets";
        }
    }
    if (curly != 0) {
        return "unbalanced braces at end of file";
    }
    if (paren != 0) {
        return "unbalanced parens at end of file";
    }
    if (brack != 0) {
        return "unbalanced brackets at end of file";
    }

    // Must contain at least one entry-point attribute.  Without this
    // the WGSL is unusable; Dawn will reject it.
    const has_entry =
        std.mem.indexOf(u8, wgsl, "@vertex") != null or
        std.mem.indexOf(u8, wgsl, "@fragment") != null or
        std.mem.indexOf(u8, wgsl, "@compute") != null;
    if (!has_entry) {
        return "no entry-point attribute (@vertex / @fragment / @compute)";
    }

    // Struct-dedup tripwire: two byte-identical struct bodies mean spv2wgsl
    // emitted a nominal-type twin (a decorated uniform/storage block type plus
    // its undecorated value twin) that Tint rejects on a whole-block load.
    // After emitTypeStruct's dedup this never happens; if it does, fail the
    // gate at build time rather than on the device.
    if (spv2wgsl.wgsl_check.duplicateStructBody(wgsl) != null) {
        return "duplicate struct body (spv2wgsl struct-dedup regression — see emitTypeStruct)";
    }

    return null;
}

// ============================================================================
// Bug detector: phi-overwrite-after-if
// ============================================================================
//
// The canonical fingerprint of the mandelbrot bug:
//
//   if (cond) {
//     ...
//     phiN = X;       <- inside the if
//     ...
//   }
//   phiN = Y;         <- outside, immediately after — overwrites X
//
// Works at ANY nesting level — the if might itself be inside a loop
// or function body.  We approximate by walking line-by-line: when we
// see a `}` on line K followed by `phiN = ...;` on line K+1, we
// scan backward from K-1 to find the matching `{` (counting `}` as
// +depth, `{` as -depth, starting at 1, stopping at 0).  If the line
// containing that matching `{` starts with `if (`, AND `phiN` was
// also assigned inside the just-closed scope, that's the bug.

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

/// If `line` is `phiN = ...;` (where N is one or more digits), return "phiN".
/// Otherwise return null.
fn parsePhiAssign(line: []const u8) ?[]const u8 {
    if (!startsWith(u8, line, "phi")) {
        return null;
    }
    var i: usize = 3;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    if (i == 3) {
        return null; // no digits after "phi"
    }
    // After phiN we want optional whitespace then `=`.
    var j: usize = i;
    while (j < line.len and (line[j] == ' ' or line[j] == '\t')) : (j += 1) {}
    if (j >= line.len or line[j] != '=') {
        return null;
    }
    // Make sure it's not `==`.
    if (j + 1 < line.len and line[j + 1] == '=') {
        return null;
    }
    return line[0..i];
}

fn scanKnownBugs(arena: Allocator, wgsl: []const u8) ![]Diag {
    var out: ArrayList(Diag) = .empty;

    var lines: ArrayList([]const u8) = .empty;
    defer lines.deinit(arena);
    var line_it = std.mem.splitScalar(u8, wgsl, '\n');
    while (line_it.next()) |l| {
        try lines.append(arena, l);
    }

    var i: usize = 1;
    while (i < lines.items.len) : (i += 1) {
        const cur: []const u8 = trim(lines.items[i]);
        const prev: []const u8 = trim(lines.items[i - 1]);
        // Looking for `}\nphiN = ...;`.  `prev` is the just-closed
        // brace line; `cur` is the line that starts with `phiN = `.
        if (!eql(u8, prev, "}")) {
            continue;
        }
        // `parsePhiAssign` returns the phi's NAME, or null when the line is not a phi assignment
        // at all - the `orelse continue` is the 'not interesting' path, not an error.
        const phi_name: []const u8 = parsePhiAssign(cur) orelse continue;

        // Walk backward from i-2: track relative depth.  Start at 1
        // because we're "inside" the just-closed scope.  Increment on
        // `}` at a line end, decrement on `{` at a line end.  When
        // depth hits 0, the current line is the construct opener.
        var depth: i32 = 1;
        var set_inside_if: bool = false;
        var opener_line: ?usize = null;
        var j: usize = i;
        while (j > 0) {
            j -= 1;
            // skip the `}` line itself
            if (j == i - 1) {
                continue;
            }
            const t: []const u8 = trim(lines.items[j]);
            // Adjust depth for braces on this line.  Count them all,
            // not just at start/end (some lines have both `} else {`).
            for (t) |c| switch (c) {
                '}' => depth += 1,
                '{' => depth -= 1,
                else => {},
            };
            // Inside the construct: check if phi_name is assigned here.
            if (depth == 1) {
                if (parsePhiAssign(t)) |inner_phi| {
                    if (eql(u8, inner_phi, phi_name)) {
                        set_inside_if = true;
                    }
                }
            }
            if (depth == 0) {
                opener_line = j;
                break;
            }
        }

        if (opener_line) |opener| {
            const open_text: []const u8 = trim(lines.items[opener]);
            const is_if = startsWith(u8, open_text, "if (") or
                startsWith(u8, open_text, "} else if (");
            if (is_if and set_inside_if) {
                const msg: []u8 = try allocPrint(
                    arena,
                    "phi-overwrite-after-if: {s} set in if then overwritten at line {d}",
                    .{ phi_name, i + 1 },
                );
                try out.append(arena, .{ .line = @intCast(i + 1), .text = msg });
            }
        }
    }

    return out.toOwnedSlice(arena);
}

// ============================================================================
// Other lexical scans
// ============================================================================

fn countUnresolved(wgsl: []const u8) u32 {
    var n: u32 = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, wgsl, i, "__unresolved_")) |pos| {
        // Confirm pattern: __unresolved_<digits>__
        var k: usize = pos + "__unresolved_".len;
        const start: usize = k;
        while (k < wgsl.len and std.ascii.isDigit(wgsl[k])) : (k += 1) {}
        if (k > start and k + 2 <= wgsl.len and wgsl[k] == '_' and wgsl[k + 1] == '_') {
            n += 1;
        }
        i = pos + 1;
    }
    return n;
}

fn scanErrorMarkers(arena: Allocator, wgsl: []const u8) ![]Diag {
    var out: ArrayList(Diag) = .empty;
    var it = std.mem.splitScalar(u8, wgsl, '\n');
    var line_no: u32 = 1;
    while (it.next()) |line| : (line_no += 1) {
        const trimmed: []const u8 = trim(line);
        if (std.mem.indexOf(u8, trimmed, "// ERROR:") != null or
            std.mem.indexOf(u8, trimmed, "UNHANDLED") != null)
        {
            try out.append(arena, .{ .line = line_no, .text = try arena.dupe(u8, trimmed) });
        }
    }
    return out.toOwnedSlice(arena);
}

// ============================================================================
// Per-shader runner
// ============================================================================

const UintParse = struct { value: u32, end: usize };

fn parseUintAt(wgsl: []const u8, start: usize) ?UintParse {
    var i: usize = start;
    var v: u32 = 0;
    var any: bool = false;
    while (i < wgsl.len and wgsl[i] >= '0' and wgsl[i] <= '9') : (i += 1) {
        v = v * 10 + (wgsl[i] - '0');
        any = true;
    }
    if (!any) {
        return null;
    }
    return .{ .value = v, .end = i };
}

/// Extract the variable name that follows a `@group@binding` attribute pair:
/// `... var[<...>] NAME :`.  Best-effort; returns "?" if it can't find one.
fn varNameAfter(wgsl: []const u8, from: usize) []const u8 {
    const v = std.mem.indexOfPos(u8, wgsl, from, "var") orelse return "?";
    var i: usize = v + 3;
    // Skip an optional `<...>` address-space qualifier.
    while (i < wgsl.len and (wgsl[i] == ' ' or wgsl[i] == '\t')) : (i += 1) {}
    if (i < wgsl.len and wgsl[i] == '<') {
        while (i < wgsl.len and wgsl[i] != '>') : (i += 1) {}
        if (i < wgsl.len) {
            i += 1;
        }
    }
    while (i < wgsl.len and (wgsl[i] == ' ' or wgsl[i] == '\t')) : (i += 1) {}
    const name_start = i;
    while (i < wgsl.len and (std.ascii.isAlphanumeric(wgsl[i]) or wgsl[i] == '_')) : (i += 1) {}
    if (i == name_start) {
        return "?";
    }
    return wgsl[name_start..i];
}

/// Binding-consistency check — the build-time tripwire for the class of
/// device bug that Dawn only rejects at `createShaderModule`/pipeline time and
/// that the mock smoke test can't see.  Invariant, derived from the WGSL text
/// alone (no host layout, no GPU):
///
///   NO DUPLICATE `(group, binding)` cell.  Two `var`s at the same cell is
///   exactly Dawn's "multiple variables use the same resource binding" — the
///   6-texture PBR sampler collision that shipped before this gate existed.
///   We report BOTH colliding names so the fix is obvious.
///
/// NB: we deliberately do NOT assert a texture@N / sampler@N+1 pairing here.
/// That pairing is the *material* sampler convention, but other shaders
/// legitimately place a lone sampler (shadow-map comparison samplers, deferred
/// g-buffer inputs) at binding 0, so a pairing rule would false-positive. The
/// host-vs-WGSL agreement for the material path is locked separately by
/// `draw3d.material_tex_bindings` deriving from the same solver as the WGSL.
///
/// Returns an owned message on the first violation, else null.
fn checkWgslBindings(arena: Allocator, wgsl: []const u8) !?[]const u8 {
    // Groups 0-3, bindings 0-63 — the range the sampler solver tracks.
    var name_at: [4][64]?[]const u8 = undefined;
    for (0..4) |gi| {
        for (0..64) |bi| {
            name_at[gi][bi] = null;
        }
    }

    var i: usize = 0;
    while (std.mem.indexOfPos(u8, wgsl, i, "@group(")) |g_at| {
        const g: UintParse = parseUintAt(wgsl, g_at + "@group(".len) orelse {
            i = g_at + 1;
            continue;
        };
        const b_kw = std.mem.indexOfPos(u8, wgsl, g.end, "@binding(") orelse {
            i = g_at + 1;
            continue;
        };
        // The @binding must belong to THIS @group (same declaration): reject if
        // another @group intervenes.
        if (std.mem.indexOfPos(u8, wgsl, g.end, "@group(")) |next_g| {
            if (next_g < b_kw) {
                i = g_at + 1;
                continue;
            }
        }
        const b: UintParse = parseUintAt(wgsl, b_kw + "@binding(".len) orelse {
            i = g_at + 1;
            continue;
        };
        i = b.end;
        if (g.value >= 4 or b.value >= 64) {
            // Out of the tracked range; the layout solver would already have
            // rejected it. Skip rather than index out of bounds.
            continue;
        }
        const name: []const u8 = varNameAfter(wgsl, b.end);
        if (name_at[g.value][b.value]) |prev| {
            return try allocPrint(
                arena,
                "duplicate @group({d}) @binding({d}): both `{s}` and `{s}` " ++
                    "declared at the same cell (Dawn rejects this as \"multiple " ++
                    "variables use the same resource binding\")",
                .{ g.value, b.value, prev, name },
            );
        }
        name_at[g.value][b.value] = name;
    }
    return null;
}

fn checkOne(
    arena: Allocator,
    io: std.Io,
    name: []const u8,
    path: []const u8,
) !Result {
    var r: Result = .{
        .name = try arena.dupe(u8, name),
        .path = try arena.dupe(u8, path),
        .spv_bytes = 0,
        .trans_ok = false,
    };

    const bytes: []u8 = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| {
        r.trans_error = try allocPrint(arena, "read failed: {s}", .{@errorName(err)});
        return r;
    };
    r.spv_bytes = bytes.len;
    r.source_name = guessShaderName(bytes);
    if (bytes.len % 4 != 0) {
        r.trans_error = try arena.dupe(u8, "input is not multiple of 4 bytes (not SPIR-V)");
        return r;
    }
    // SPIR-V is a stream of u32 words. `readFileAlloc` only guarantees byte
    // alignment, so `@alignCast`-ing the buffer to `[]align(4) u8` panics in
    // safe builds whenever the allocator hands back a misaligned buffer (it
    // aborted the standalone run before this fix). Allocating a `[]u32` is
    // naturally 4-aligned; copy the bytes in and read words from there.
    const words: []u32 = try arena.alloc(u32, bytes.len / 4);
    @memcpy(std.mem.sliceAsBytes(words), bytes);

    const wgsl: []const u8 = spv2wgsl.convertSpirvToWgsl(arena, words) catch |err| {
        r.trans_error = try allocPrint(arena, "convertSpirvToWgsl: {s}", .{@errorName(err)});
        return r;
    };
    r.trans_ok = true;
    r.wgsl_bytes = wgsl.len;
    var lc: u32 = 1;
    for (wgsl) |c| {
        if (c == '\n') {
            lc += 1;
        }
    }
    r.wgsl_lines = lc;

    if (checkWgslStructural(wgsl)) |err_msg| {
        r.parse_error = try arena.dupe(u8, err_msg);
    } else if (try checkWgslBindings(arena, wgsl)) |bind_msg| {
        r.parse_error = bind_msg;
    } else {
        r.parse_ok = true;
    }

    r.unresolved_count = countUnresolved(wgsl);

    const err_diags: []Diag = try scanErrorMarkers(arena, wgsl);
    r.err_marker_count = @intCast(err_diags.len);
    r.err_markers = err_diags;

    const bug_diags: []Diag = try scanKnownBugs(arena, wgsl);
    r.known_bug_count = @intCast(bug_diags.len);
    r.known_bugs = bug_diags;

    return r;
}

// ============================================================================
// Path discovery
// ============================================================================

/// True when `path` exists AND holds at least one byte.
///
/// ★ THE SIZE CHECK IS THE POINT. A FAILED shader compile leaves a ZERO-BYTE `.spv` behind in
/// the cache, and this walker would happily hand it to the translator, which correctly refuses
/// an empty module — reported as TRANS-FAIL. That is build detritus being scored as a
/// translator bug, and it cost real time: two of five failures in the SSAO session were empty
/// files, and their presence made the three REAL failures look like a pre-existing condition.
///
/// An empty `.spv` is never interesting to this gate: whatever produced it already failed
/// loudly at compile time.
fn statFile(io: std.Io, path: []const u8) bool {
    var f: std.Io.File = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer f.close(io);
    const st: std.Io.File.Stat = f.stat(io) catch return false;
    return st.size > 0;
}

fn lessThanStr(
    _: void,
    a: []const u8,
    b: []const u8,
) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Every `.spv` the build has ever produced and still has cached.
///
/// ── ★★ THIS IS CACHE-DERIVED, NOT SOURCE-DERIVED, AND THAT HAS TEETH ──
///
/// The walk is over `.zig-cache/o/<hash>/`, which knows nothing about which shader sources
/// currently exist. Three consequences, all of them real:
///
///   1. **A DELETED OR RENAMED SHADER KEEPS BEING CHECKED** until the cache is cleared. Its
///      failures have no source to fix.
///   2. **EVERY REVISION OF A SHADER UNDER DEVELOPMENT ACCUMULATES.** Iterating on one shader
///      left THREE cached entries, all failing, all reported separately — which read as three
///      independent problems.
///   3. ★ **DELETING A SOURCE FILE IS NOT A CONTROL EXPERIMENT.** Removing three new shaders
///      and re-running gave an IDENTICAL failure count, which looked like proof they were
///      innocent. The cached `.spv` were still there and still being scanned. They were
///      guilty. To attribute a failure here, identify the input directly —
///      `strings <hash>/shader.spv | grep <name>` names it immediately — or clear the cache.
///
/// The breadth is deliberate: scanning everything the build ever emitted is what makes this a
/// corpus rather than a spot check, and it catches shaders no example currently draws. But the
/// price is that a result here is evidence about the CACHE, not about the working tree.
fn listOurCorpus(arena: Allocator, io: std.Io) ![][]const u8 {
    // Walk .zig-cache/o/<hash>/ for shader.opt.spv, shader.spv, or compute.spv.
    // `compute.spv` is the kompute compute-kernel output (addCompute) — without
    // it the kernels' WGSL was never reached by this gate, so the fluid_sort
    // struct-dedup failure had no build-time tripwire at all.
    var out: ArrayList([]const u8) = .empty;
    var dir: std.Io.Dir = std.Io.Dir.cwd().openDir(io, cache_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return out.toOwnedSlice(arena),
        else => return err,
    };
    defer dir.close(io);

    var it: std.Io.Dir.Iterator = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) {
            continue;
        }
        const opt_path: []u8 = try std.fs.path.join(arena, &.{ cache_dir, entry.name, "shader.opt.spv" });
        const raw_path: []u8 = try std.fs.path.join(arena, &.{ cache_dir, entry.name, "shader.spv" });
        const compute_path: []u8 = try std.fs.path.join(arena, &.{ cache_dir, entry.name, "compute.spv" });
        if (statFile(io, opt_path)) {
            try out.append(arena, opt_path);
        } else if (statFile(io, raw_path)) {
            try out.append(arena, raw_path);
        }
        // A dir can hold BOTH a render shader and a compute kernel only in
        // pathological cases; check compute.spv independently so kernels are
        // never skipped.
        if (statFile(io, compute_path)) {
            try out.append(arena, compute_path);
        }
    }
    std.mem.sort([]const u8, out.items, {}, lessThanStr);
    return out.toOwnedSlice(arena);
}

fn listTintCorpus(arena: Allocator, io: std.Io) ![][]const u8 {
    var out: ArrayList([]const u8) = .empty;
    var dir: std.Io.Dir = std.Io.Dir.cwd().openDir(io, tint_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return out.toOwnedSlice(arena),
        else => return err,
    };
    defer dir.close(io);
    var it: std.Io.Dir.Iterator = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) {
            continue;
        }
        if (!endsWith(u8, entry.name, ".spv")) {
            continue;
        }
        const p: []u8 = try std.fs.path.join(arena, &.{ tint_dir, entry.name });
        try out.append(arena, p);
    }
    std.mem.sort([]const u8, out.items, {}, lessThanStr);
    return out.toOwnedSlice(arena);
}

// ============================================================================
// Reporting
// ============================================================================

/// Pull a shader's own name out of its SPIR-V, for failure reporting.
///
/// ★ THE CACHE NAMES EVERY SHADER BY CONTENT HASH, which is exactly no help when one fails:
/// `ERR-MARKER ... 13f8626c97ee8878e34ed80e22be531d` says nothing about WHICH shader is
/// broken. Attributing three failures in the SSAO session meant running
/// `strings <hash>/shader.spv | grep` by hand, and the missing attribution is what made a
/// wrong conclusion easy to reach in the first place.
///
/// SPIR-V keeps `OpName`/`OpSource` debug strings in the module, so the source name is sitting
/// right there in the bytes. This scans for the first identifier-shaped run ending in `_fs`,
/// `_vs` or `_io` — deliberately lexical rather than a real SPIR-V parse, because this runs
/// only on the failure path and must never itself fail.
fn guessShaderName(spv: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < spv.len) : (i += 1) {
        if (!isIdentByte(spv[i])) {
            continue;
        }
        var j: usize = i;
        while (j < spv.len and isIdentByte(spv[j])) : (j += 1) {}
        const word: []const u8 = spv[i..j];
        if (word.len >= 5 and word.len <= 64 and
            (endsWith(u8, word, "_fs") or endsWith(u8, word, "_vs") or endsWith(u8, word, "_io")))
        {
            return word;
        }
        i = j;
    }
    return null;
}

fn isIdentByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

fn printRow(
    io: std.Io,
    stdout_w: *std.Io.File.Writer,
    r: Result,
) !void {
    const status: []const u8 = switch (r.outcome()) {
        .ok => "OK",
        .trans_fail => "TRANS-FAIL",
        .parse_fail => "PARSE-FAIL",
        .err_marker => "ERR-MARKER",
        .unresolved => "UNRESOLVED",
        .known_bug => "KNOWN-BUG",
    };
    _ = io;
    try stdout_w.interface.print(
        "  {s: <11}  {d: >7}B  {d: >7}B  {d: >4}L  unres={d}  err={d}  bug={d}  {s}\n",
        .{
            status,
            r.spv_bytes,
            r.wgsl_bytes,
            r.wgsl_lines,
            r.unresolved_count,
            r.err_marker_count,
            r.known_bug_count,
            r.name,
        },
    );
    // ★ On any failure, say WHICH SHADER — the hash alone is unactionable.
    if (r.outcome() != .ok) {
        if (r.source_name) |src| {
            try stdout_w.interface.print("     shader: {s}\n", .{src});
        }
    }
    if (r.trans_error) |msg| {
        try stdout_w.interface.print("     trans: {s}\n", .{msg});
    }
    if (r.parse_error) |msg| {
        try stdout_w.interface.print("     parse: {s}\n", .{msg});
    }
    for (r.err_markers) |d| {
        try stdout_w.interface.print("     err :{d}: {s}\n", .{ d.line, d.text });
    }
    for (r.known_bugs) |d| {
        try stdout_w.interface.print("     bug: {s}\n", .{d.text});
    }
}

// ============================================================================
// Entry point
// ============================================================================

pub fn main(init: std.process.Init) !void {
    const gpa: Allocator = init.gpa;
    const io: std.Io = init.io;

    var args_list: ArrayList([]u8) = .empty;
    defer {
        for (args_list.items) |a| gpa.free(a);
        args_list.deinit(gpa);
    }
    var arg_it: std.process.Args.Iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    while (arg_it.next()) |arg| {
        try args_list.append(gpa, try gpa.dupe(u8, arg));
    }
    const args: [][]u8 = args_list.items;

    if (args.len < 2) {
        var stderr_buf: [512]u8 = undefined;
        var stderr_w: std.Io.File.Writer = std.Io.File.stderr().writer(io, &stderr_buf);
        try stderr_w.interface.print(
            "usage: spv2wgsl_check <target>...\n" ++
                "       target: 'all' | 'our-corpus' | 'tint-corpus' | <path-to-spv> | <directory>\n",
            .{},
        );
        try stderr_w.interface.flush();
        std.process.exit(2);
    }

    var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    // Resolve target list.
    var targets: ArrayList(struct { name: []const u8, path: []const u8 }) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (eql(u8, a, "all")) {
            for (try listOurCorpus(arena, io)) |p| {
                const name: []const u8 = std.fs.path.basename(std.fs.path.dirname(p) orelse p);
                try targets.append(arena, .{ .name = name, .path = p });
            }
            for (try listTintCorpus(arena, io)) |p| {
                try targets.append(arena, .{ .name = std.fs.path.basename(p), .path = p });
            }
        } else if (eql(u8, a, "our-corpus")) {
            for (try listOurCorpus(arena, io)) |p| {
                const name: []const u8 = std.fs.path.basename(std.fs.path.dirname(p) orelse p);
                try targets.append(arena, .{ .name = name, .path = p });
            }
        } else if (eql(u8, a, "tint-corpus")) {
            for (try listTintCorpus(arena, io)) |p| {
                try targets.append(arena, .{ .name = std.fs.path.basename(p), .path = p });
            }
        } else if (endsWith(u8, a, ".spv")) {
            try targets.append(arena, .{ .name = std.fs.path.basename(a), .path = try arena.dupe(u8, a) });
        } else {
            // Try as directory.
            var dir: std.Io.Dir = std.Io.Dir.cwd().openDir(io, a, .{ .iterate = true }) catch {
                var stderr_buf: [512]u8 = undefined;
                var stderr_w: std.Io.File.Writer = std.Io.File.stderr().writer(io, &stderr_buf);
                try stderr_w.interface.print("unknown target: {s}\n", .{a});
                try stderr_w.interface.flush();
                std.process.exit(2);
            };
            defer dir.close(io);
            var it: std.Io.Dir.Iterator = dir.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind != .file) {
                    continue;
                }
                if (!endsWith(u8, entry.name, ".spv")) {
                    continue;
                }
                const p: []u8 = try std.fs.path.join(arena, &.{ a, entry.name });
                try targets.append(arena, .{ .name = entry.name, .path = p });
            }
        }
    }

    // Run + print.
    var stdout_buf: [4096]u8 = undefined;
    var stdout_w: std.Io.File.Writer = std.Io.File.stdout().writer(io, &stdout_buf);

    try stdout_w.interface.print("\nspv2wgsl_check — {d} shader(s)\n\n", .{targets.items.len});
    try stdout_w.interface.print(
        "  status         spv         wgsl  lines  diags                       name\n",
        .{},
    );
    var dashes_buf: [80]u8 = undefined;
    @memset(&dashes_buf, '-');
    try stdout_w.interface.print("  {s}\n", .{dashes_buf[0..]});

    var ok_count: u32 = 0;
    var fail_count: u32 = 0;
    var bug_count: u32 = 0;
    for (targets.items) |t| {
        var per_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(gpa);
        defer per_state.deinit();
        const per_arena: Allocator = per_state.allocator();
        const r: Result = try checkOne(per_arena, io, t.name, t.path);
        try printRow(io, &stdout_w, r);
        switch (r.outcome()) {
            .ok => ok_count += 1,
            .known_bug => {
                bug_count += 1;
                fail_count += 1;
            },
            else => fail_count += 1,
        }
    }

    try stdout_w.interface.print(
        "\nresults: {d} ok, {d} failed ({d} known bug)\n",
        .{ ok_count, fail_count, bug_count },
    );
    try stdout_w.interface.flush();
    if (fail_count > 0) {
        std.process.exit(1);
    }
}

test "checkWgslBindings: clean interleaved bindings pass" {
    const wgsl: []const u8 =
        \\@group(0) @binding(0) var<uniform> u: Camera;
        \\@group(1) @binding(0) var texture0: texture_2d<f32>;
        \\@group(1) @binding(1) var texture0_sampler: sampler;
        \\@group(1) @binding(2) var metallic_roughness: texture_2d<f32>;
        \\@group(1) @binding(3) var metallic_roughness_sampler: sampler;
    ;
    const r: ?[]const u8 = try checkWgslBindings(std.testing.allocator, wgsl);
    try expect(r == null);
}

test "checkWgslBindings: a lone shadow sampler at binding 0 is fine" {
    const wgsl: []const u8 =
        \\@group(1) @binding(0) var shadow_sampler: sampler;
        \\@group(2) @binding(0) var<uniform> fs: FsUbo;
    ;
    const r: ?[]const u8 = try checkWgslBindings(std.testing.allocator, wgsl);
    try expect(r == null);
}

test "checkWgslBindings: duplicate (group,binding) is caught and names both vars" {
    // The exact collision shape Dawn rejects: two vars at @group(1)@binding(1).
    const wgsl: []const u8 =
        \\@group(1) @binding(0) var texture0: texture_2d<f32>;
        \\@group(1) @binding(1) var texture0_sampler: sampler;
        \\@group(1) @binding(1) var metallic_roughness: texture_2d<f32>;
    ;
    const r: ?[]const u8 = try checkWgslBindings(std.testing.allocator, wgsl);
    defer if (r) |m| std.testing.allocator.free(m);
    try expect(r != null);
    try expect(std.mem.indexOf(u8, r.?, "texture0_sampler") != null);
    try expect(std.mem.indexOf(u8, r.?, "metallic_roughness") != null);
    try expect(std.mem.indexOf(u8, r.?, "@group(1) @binding(1)") != null);
}
