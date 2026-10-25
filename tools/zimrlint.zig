//! zimrlint -- zimr's opinionated linter: an extension of the compiler.
//!
//! WHAT IT IS
//!   An AST-based linter enforcing zimr's house rules on top of what the Zig
//!   compiler already checks. Guiding idea (see src/notes/lint_opinionated_plan.md):
//!   "one obvious way" -- where several spellings mean the same thing, mandate the
//!   canonical one; where a silent default hides a real choice, force it to be made.
//!   Like `zig fmt` it has no severity levels -- a file either passes or it
//!   doesn't. In zimr a lint finding is a compile error, and an explained
//!   `// lint:off <rule>: <why>` is part of the language, as much as any syntax.
//!   The ONE exception is a rule still WORK IN PROGRESS: it reports and never
//!   fails the run while it is written and a tree is converted to it; once the
//!   tree is clean it is finished, and enforced like every other rule.
//!   Every rule is OPT-IN: a run checks exactly the rules `--enable` names. A build
//!   lists the rules it holds its sources to -- zimr's own tree in build.zig's
//!   `zimr_lint_rules`, an app in its `.lint.enable` (build.zig's `LintRule` names
//!   every rule) -- so nothing is on by accident, and a new rule reaches a tree only
//!   when that tree's build asks for it.
//!
//! HOW TO RUN IT
//!   zimrlint --enable=<tag>,<tag> <file.zig> ...   check these rules; exits non-zero on any issue
//!   zimrlint --fix --enable=<tag>,... <file.zig>   apply the autofixes those rules marked safe: each fixed file
//!                                           written once, laid out as `zig fmt` lays it out, then a line naming
//!                                           what was fixed (`zimrlint: fixed <file>: <rule> x<count>, ...`), the
//!                                           file's diff (`line_diff.zig`), and what is left in it for a person.
//!                                           `zig build fix` runs this; no other step writes a source file.
//!   zimrlint --list-rules                   every tag (those in progress marked)
//!   zimrlint --cache-dir <dir> ...          where the per-file clean stamps go
//!   Built as a ReleaseSafe exe (NOT ReleaseFast -- this dev Zig miscompiles it in
//!   ReleaseFast; see build.zig). `zig build` compiles it and runs it over the tree.
//!
//! THE RULES  (full catalog + rationale = the `rule_notes` table below; search it)
//!   Every rule has a kebab tag emitted in its diagnostic and a `rule_notes` entry,
//!   so the tag is self-documenting. A reviewed exception is silenced with a trailing
//!   `// lint:off <tag>: <why>` (one line) or a file-level `//! lint:off <tag>`
//!   (container doc-comment). Rough groupings:
//!     idiom/style : untyped-local, branch-braces, fn-args-multiline, decl-order,
//!                   anon-return, module-var, ascii-comments,
//!                   no-qualified-std,
//!                   import-at-top, import-at-root, line-length, ascii-test-names,
//!                   named-struct-init, screaming-const, canonical-alias,
//!                   redundant-import, duplicate-case, unused-global
//!     math -> zm  : no-qualified-zm, reserved-math-names, std-math, clamp-pattern,
//!                   prefer-vec, array-mult, int-from-float, float-from-int,
//!                   as-round, redundant-cast, std-debug-assert, custom-degrad,
//!                   turn-in-radian-call, prefer-splat
//!     errors      : catch-suppression, no-catch-return, useless-error-return,
//!                   prefer-assert-unreachable
//!     bugs        : returned-stack-reference, whole-init-first, state-uninit,
//!                   scope-balance, depth-format, debug-print, no-std-timer,
//!                   import-cycle
//!     shaders     : shader-inline-fn, shader-missing-entry, shader-no-atan,
//!                   shader-safe, sampler-in-branch, sampler-in-helper
//!     gpu safety  : raw-pass-state-bind
//!     meta        : parse-error (file didn't parse -> AST rules skipped for it),
//!                   unknown-lint-tag (a `lint:off` naming no rule),
//!                   zig-fmt (the file is not laid out as `zig fmt` lays it out)
//!
//! HOW THE FILE IS LAID OUT  (chapters are marked by `====` dividers -- search a title)
//!   1. Data model           Fix / Issue / Ctx -- the diagnostic, the fix, and the
//!                           per-file context handed to every check.
//!   2. Directives + vocab   the `// lint:off` parser; the curated zm "keyword"
//!                           vocabulary; type-signal detection for untyped-local.
//!   3. rule_notes           the rule catalog: tag + title + prose rationale per rule.
//!   4. The walker           walkNode / walkBlockBody / walkContainerChildren -- ONE
//!                           depth-first AST pass that dispatches every per-node check,
//!                           tracking position (.container vs .statement) and fn_depth.
//!   5. The checks           ~50 checkX functions, one (or a few) per rule.
//!   6. Whole-file checks     cross-cutting passes that need no AST walk.
//!   7. The driver           main(): arg parsing, the per-file mtime cache, --fix.
//!
//! ADDING A RULE
//!   Write `checkX(ctx, ...)`, call it from the walker (per node) or as a whole-file
//!   pass, and emit with `ctx.emitAt(token, "kebab-tag", ...)`. Add a `rule_notes`
//!   entry (emitting a tag without one panics), and give it a `// lint:off`
//!   escape. Every rule then needs a field in build.zig's `LintRule`, and a
//!   place in `zimr_lint_rules` (and the template's list) wherever a tree holds
//!   itself to it. A new rule may be WORK IN PROGRESS while a tree catches up;
//!   otherwise lint gates the build exactly like the compiler, so a rule is tuned until it is
//!   FP-free on the whole tree (with `// lint:off <tag>: <why>` for the cases a
//!   contract genuinely forces) -- or it is deleted. A rule nobody's build
//!   enforces isn't a rule.
//!
//! GOTCHA
//!   The linter lints its OWN source. This file defines the raw-pass-state-bind
//!   needle literals as data, which would trip that rule -- so it opts out with the
//!   file-level directive just below, NOT by hardcoding its own filename (which is
//!   exactly what silently broke on the lint_zimr -> zimrlint rename). Two engine
//!   files (gpu_iface.zig, wgpu.zig) are still name-exempted in scanRawPassBind
//!   because they legitimately CALL the raw primitives; those filenames are stable.
//!
//! lint:off raw-pass-state-bind: this file defines the rule's own needle literals as data

const std = @import("std");
const cli = @import("cli");
const line_diff = @import("line_diff.zig");
const ArrayList = std.ArrayList;
const allocPrint = std.fmt.allocPrint;
const bufPrint = std.fmt.bufPrint;
const endsWith = std.mem.endsWith;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
const Io = std.Io;
const StringHashMap = std.StringHashMap;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing_allocator = std.testing.allocator;
const indexOf = std.mem.indexOf;
const indexOfPos = std.mem.indexOfPos;
const asBytes = std.mem.asBytes;
const splitScalar = std.mem.splitScalar;
const trim = std.mem.trim;
const sortSlice = std.mem.sort;
const parseInt = std.fmt.parseInt;
const indexOfScalar = std.mem.indexOfScalar;

/// A 78-character `=` divider for the rule-note headers.  Written as an
/// explicit literal (not `"=" ** 78`) per the linter's own retired-`**`
/// rule (rule 5).
const rule_divider: []const u8 = "==============================================================================";
const Index = Ast.Node.Index;

/// A mechanical source edit proposed by a rule and applied in `--fix` mode.
/// `start`/`end` are byte offsets into the file's source (`end` exclusive);
/// `replacement` is spliced in their place. A pure deletion uses `""`. Only
/// rules whose repair is unambiguous attach one; everything else leaves it
/// null and is reported for a human to fix by hand.
///
/// A rule hands `emitFix` a BORROWED replacement - a static string, a slice of
/// the source, or a temporary it frees itself. `emitFixLC` copies it after the
/// suppression check, and the `Issue` owns the copy. That split is the point:
/// a rule that pre-allocated its replacement leaked it every time the line
/// carried a `lint:off`, because the early return dropped a string the rule
/// had already handed over.
const Fix = struct {
    start: u32,
    end: u32,
    replacement: []const u8 = "",
    /// The rule whose finding this repairs - a static tag - for the report of what a fix run changed.
    tag: []const u8 = "",
};

const Issue = struct {
    file: []const u8, // borrowed from arg list
    line: u32, // 1-based
    col: u32, // 1-based
    tag: []const u8, // static string
    message: []u8, // owned - freed by `deinit`
    rule: u8, // claude.md rule number, 0 for bonus checks
    fix: ?Fix = null, // present => `--fix` can repair this mechanically; replacement owned

    /// Frees everything an issue owns: its message and its fix's replacement.
    /// Every list of issues is torn down through this one function, so an owned
    /// field added later has exactly one place to be freed.
    fn deinit(self: Issue, gpa: Allocator) void {
        gpa.free(self.message);
        if (self.fix) |fix| {
            gpa.free(fix.replacement);
        }
    }
};

/// A module's own declaration of how importers should name it, from a top-of-file
/// `//! lint:alias <name>`. `stem` is the declaring file's basename without `.zig`.
const AliasDecl = struct {
    stem: []const u8,
    alias: []const u8,
};

/// The basename of `path` with any directories and a trailing `.zig` removed, so
/// `src/tests/../image.zig`, `../image.zig` and `image` all reduce to `image`.
fn moduleStem(path: []const u8) []const u8 {
    var s: []const u8 = path;
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| {
        s = s[i + 1 ..];
    }
    if (endsWith(u8, s, ".zig")) {
        s = s[0 .. s.len - 4];
    }
    return s;
}

/// Reads a module's `//! lint:alias <name>` declaration: "when you import me, call
/// me this". Living in the module (not a central table in the linter) means a new
/// file ships its own convention and doubles as documentation - open the file and
/// line one tells you how to import it.
fn declaredAliasOf(source: []const u8) ?[]const u8 {
    var lines: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const text: []const u8 = std.mem.trimStart(u8, raw, " \t");
        const marker: []const u8 = "//! lint:alias";
        if (!startsWith(u8, text, marker)) {
            continue;
        }
        var p: usize = marker.len;
        while (p < text.len and (text[p] == ' ' or text[p] == '\t')) : (p += 1) {}
        var e: usize = p;
        while (e < text.len) : (e += 1) {
            const c: u8 = text[e];
            if (c == ' ' or c == '\t' or c == '\r') {
                break;
            }
        }
        if (e > p) {
            return text[p..e];
        }
    }
    return null;
}

/// File-level opt-out: a top-of-file `//! lint:off <tag>[,<tag2>] [: why]`
/// container doc-comment suppresses `tag` for the WHOLE file.  Use sparingly,
/// for files whose existing convention conflicts with a rule (e.g. codecs.zig's
/// per-struct `const testing = std.testing;` alias clashing with a file-scope
/// `no-qualified-std` binding).  Tag-list syntax matches the per-line form.
fn fileSuppressedByDirective(source: [:0]const u8, tag: []const u8) bool {
    var lines: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const text: []const u8 = std.mem.trimStart(u8, raw, " \t");
        const marker: []const u8 = "//! lint:off";
        if (!startsWith(u8, text, marker)) {
            continue;
        }
        var p: usize = marker.len;
        while (p < text.len and (text[p] == ' ' or text[p] == '\t')) : (p += 1) {}
        var rule_end: usize = p;
        while (rule_end < text.len) : (rule_end += 1) {
            const c: u8 = text[rule_end];
            if (c == ':' or c == ' ' or c == '\t') {
                break;
            }
        }
        if (rule_end == p) {
            continue;
        }
        var it: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, text[p..rule_end], ',');
        while (it.next()) |r| {
            if (eql(u8, r, tag)) {
                return true;
            }
        }
    }
    return false;
}

const DirectivePlacement = enum { anywhere, leading_only };

fn lineHasDirectiveFor(
    source: [:0]const u8,
    line_idx: u32,
    tag: []const u8,
    placement: DirectivePlacement,
) bool {
    // Locate the byte range of the requested 1-indexed line.
    var current: u32 = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < source.len and current < line_idx) : (i += 1) {
        if (source[i] == '\n') {
            current += 1;
            line_start = i + 1;
        }
    }
    if (current != line_idx) {
        return false;
    }
    var line_end: usize = line_start;
    while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}
    const text: []const u8 = source[line_start..line_end];

    const marker: []const u8 = "// lint:off";
    const marker_idx: usize = indexOf(u8, text, marker) orelse return false;

    // For `leading_only`, everything before the marker must be whitespace.
    // This blocks a trailing `// lint:off` on a code line from leaking
    // forward to suppress the next line's offense.
    if (placement == .leading_only) {
        for (text[0..marker_idx]) |c| {
            if (c != ' ' and c != '\t') {
                return false;
            }
        }
    }

    var p: usize = marker_idx + marker.len;
    while (p < text.len and (text[p] == ' ' or text[p] == '\t')) : (p += 1) {}

    // Parse the rule list - tokens separated by ',', terminated by ':' / ws.
    var rule_end: usize = p;
    while (rule_end < text.len) : (rule_end += 1) {
        const c: u8 = text[rule_end];
        if (c == ':' or c == ' ' or c == '\t') {
            break;
        }
    }
    if (rule_end == p) {
        return false;
    }
    const rules: []const u8 = text[p..rule_end];

    var it: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, rules, ',');
    while (it.next()) |r| {
        if (eql(u8, r, tag)) {
            return true;
        }
    }
    return false;
}

/// Returns true when the source has a `// lint:off <tag>[,<tag2>,...]
/// [: justification]` directive that suppresses `tag` at `line_idx`
/// (1-indexed).  Called from `Ctx.emit` to skip a per-site warning
/// without touching the linter's static allow-list.
///
/// Two accepted placements:
///   - **Trailing same-line**: the directive sits on the offending line
///     itself, after the code: `var x = ...; // lint:off rule: reason`.
///     Best for short decls.
///   - **Leading prev-line**: the directive sits on the line above the
///     offending one, as a comment-only line: `    // lint:off rule:
///     reason\n    var x = ...;`.  Needed when the trailing form would
///     bust the 120-col line-length rule, or for multi-line decls.
///     The line above must contain ONLY whitespace before the marker
///     so a trailing comment on an unrelated line above can't leak
///     forward into a real suppression.
///
/// Syntax:
///   - Rule list is comma-separated, no spaces inside the list.
///   - At least one rule name is required - bare `// lint:off` is
///     ignored so accidental blanket suppression can't happen.
///   - Justification after the optional `:` is for humans, not parsed.
fn lineSuppressedByDirective(
    source: [:0]const u8,
    line_idx: u32,
    tag: []const u8,
) bool {
    // -- `std-math`: A FILE-LEVEL OPT-OUT ONLY, NEVER A PER-LINE ONE --
    //
    // The ban exists for exactly one reason: std.math is host-only and does not reliably lower
    // to SPIR-V. A file that can never reach a shader has no portability exposure, and applying
    // the rule there is following it past its reason - it costs a real dependency and buys
    // nothing. The standalone transpilers are that case: `c2js` gained a whole `zm` import for
    // ONE `zm.nan(f64)`, which is a module dependency for a constant.
    //
    // But the escape is deliberately file-level. "This file never reaches a GPU" is a property
    // of the whole file, declared at the top where a reviewer sees it. A per-line `lint:off`
    // would let one call be silenced inside a file that IS shader-reachable, which is precisely
    // the hazard the ban was written to stop - and it would be invisible 4000 lines down.
    if (eql(u8, tag, "std-math")) {
        return fileSuppressedByDirective(source, tag);
    }
    if (fileSuppressedByDirective(source, tag)) {
        return true;
    }
    if (lineHasDirectiveFor(source, line_idx, tag, .anywhere)) {
        return true;
    }
    if (line_idx > 1 and lineHasDirectiveFor(source, line_idx - 1, tag, .leading_only)) {
        return true;
    }
    return false;
}

const Ctx = struct {
    alloc: Allocator,
    path: []const u8,
    source: [:0]const u8,
    ast: *const Ast,
    issues: *ArrayList(Issue),
    /// Whole-module zm aliases found in this file (`const X = @import("zm");`).
    /// Empty => the file doesn't import zm => the reserved-math rule is skipped
    /// entirely (decision 2b in RESERVED_MATH_PLAN.md).  Usually one entry
    /// (`zm`), occasionally `math`.  Points into `source`.
    zm_aliases: []const []const u8 = &.{},
    /// Whole-module std aliases found in this file (`const X = @import("std");`).
    /// Lets `std-math` catch `<alias>.math` (e.g. `std_mod.math.pi`), not just
    /// the literal `std.math`.  Points into `source`.
    std_aliases: []const []const u8 = &.{},

    /// Node indices (`true` = yes) of canonical `const X = zm.X;` binding
    /// inits.  `no-qualified-zm` skips these - that single `zm.X` is the legal
    /// home for the named import `X`.  Sized to `ast.nodes.len` by the per-file
    /// pre-pass; empty => nothing is treated as a binding init.  Points nowhere
    /// into `source` (it is a parallel bool array, freed after the file).
    canonical_zm_inits: []const bool = &.{},

    /// `no-qualified-std`'s binding inits (`const eql = std.mem.eql;`), marked like `canonical_zm_inits`.
    canonical_std_inits: []const bool = &.{},

    /// `no-qualified-std`: how many times each `std_vocabulary` alias is declared in this file (one count per
    /// entry). Empty => nothing counted, which the rule reads as "no declarations".
    std_alias_declarations: []const u32 = &.{},

    /// Whether this file has a column-0 `const zm = @import("zm");` (or `pub`
    /// variant).  Only such files are subject to `no-qualified-zm`; a file
    /// whose sole zm import is per-struct/indented (runtime.zig's per-namespace
    /// imports) can't host a file-scope binding and is exempt - mirroring the
    /// P4 migration tool's own col-0 requirement.
    zm_col0: bool = false,

    /// Whether this file has a column-0 `const std = @import("std");` (or `pub`
    /// variant).  Like `zm_col0`: only such files are subject to
    /// `no-qualified-std`, since a file whose std import is function-local
    /// can't host a file-scope alias binding.
    std_col0: bool = false,

    /// Whether this file declares an app (`AppSpec(` appears in it) - the files
    /// whose `State` is an app's state type, for `state-uninit`.
    declares_app: bool = false,

    /// Whether the `decl-order` rule runs (`--enable=decl-order`). The
    /// one rule that is skipped rather than filtered: its pass is the
    /// expensive one, and `--decl-order-only` runs it alone.
    check_decl_order: bool = false,

    /// Run ONLY the decl-order check, skipping every other rule (set by
    /// `--decl-order-only`). For fast iterative reordering of large files.
    decl_order_only: bool = false,

    /// Module alias declarations for `canonical-alias` (see Args.aliases).
    aliases: []const AliasDecl = &.{},
    /// `--coverage`: one flag per AST node, set by `walkNode` when the walk reaches the node - so the nodes left
    /// false are the ones no per-node rule ever looked at (`walkCoverage`). Empty, the default: not recording.
    visited: []bool = &.{},

    fn emit(
        self: Ctx,
        line: u32,
        col: u32,
        tag: []const u8,
        rule: u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        if (lineSuppressedByDirective(self.source, line, tag)) {
            return;
        }
        const msg: []u8 = try allocPrint(self.alloc, fmt, args);
        errdefer self.alloc.free(msg);
        try self.issues.append(self.alloc, .{
            .file = self.path,
            .line = line,
            .col = col,
            .tag = tag,
            .message = msg,
            .rule = rule,
        });
    }

    /// Emit an issue located at an AST token.  This is the form almost
    /// every rule wants - it resolves the token's 1-based line/column
    /// and forwards to `emit`, so call sites stay a single line instead
    /// of repeating the `tokenLineCol` dance.  Use the lower-level
    /// `emit` directly only when the position is not a token (e.g. the
    /// line-length scan, which works from byte offsets with a fixed
    /// column).
    fn emitAt(
        self: Ctx,
        tok: u32,
        tag: []const u8,
        rule: u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const lc: LineCol = self.tokenLineCol(tok);
        try self.emit(lc.line, lc.col, tag, rule, fmt, args);
    }

    /// Like `emit`, but attaches a mechanical `Fix` for `--fix`. Rides the
    /// same per-line `// lint:off` suppression as `emit`, so a suppressed
    /// decl is never rewritten. Use the token form `emitFix` where possible.
    fn emitFixLC(
        self: Ctx,
        line: u32,
        col: u32,
        tag: []const u8,
        rule: u8,
        fix: Fix,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        if (lineSuppressedByDirective(self.source, line, tag)) {
            return;
        }
        const msg: []u8 = try allocPrint(self.alloc, fmt, args);
        errdefer self.alloc.free(msg);
        // The issue owns a COPY of the replacement, made only once the issue is known
        // to be kept (see `Fix`). The caller's slice may be static, borrowed from a
        // source buffer that dies before `--fix` splices, or a temporary it frees.
        const replacement_owned: []u8 = try self.alloc.dupe(u8, fix.replacement);
        errdefer self.alloc.free(replacement_owned);
        var fix_owned: Fix = fix;
        fix_owned.replacement = replacement_owned;
        fix_owned.tag = tag;
        try self.issues.append(self.alloc, .{
            .file = self.path,
            .line = line,
            .col = col,
            .tag = tag,
            .message = msg,
            .rule = rule,
            .fix = fix_owned,
        });
    }

    /// Token-located variant of `emitFixLC`.
    fn emitFix(
        self: Ctx,
        tok: u32,
        tag: []const u8,
        rule: u8,
        fix: Fix,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const lc: LineCol = self.tokenLineCol(tok);
        try self.emitFixLC(lc.line, lc.col, tag, rule, fix, fmt, args);
    }

    /// A 1-based (line, column) source position.  Named (not an
    /// anonymous tuple) per the linter's own anon-return rule.
    const LineCol = struct { line: u32, col: u32 };

    /// Resolve an AST token to its 1-based (line, column).  `tokenLocation`
    /// is 0-based, hence the `+ 1` on each axis.
    fn tokenLineCol(self: Ctx, tok: u32) LineCol {
        const loc: Ast.Location = self.ast.tokenLocation(0, tok);
        return .{ .line = @intCast(loc.line + 1), .col = @intCast(loc.column + 1) };
    }
};

// ============================================================================
// Rule 9 allow-list + the `// lint:off` directive.
// ============================================================================

// Module-scope `var` is forbidden except for three convention-based
// blanket carve-outs (matched here in code):
//   - `warned_*` flags       - one-shot per-process log warnings.
//                              `drawing.zig`'s `warned_text_no_font` is the
//                              canonical example.  Lifting these onto a
//                              context would re-fire per ctx, defeating
//                              the "warn once per process" intent.
//   - `zimr_app`             - the user-owned C-ABI bridge in every
//                              example.  The framework reaches it via
//                              `@import("root").zimr_app` at comptime.
//   - `*_fs.zig` / `*_vs.zig`- SPIR-V stage source files; `extern var
//                              name: T addrspace(.output)` is structural
//                              for shader entry points.
//
// Anything else uses a per-site `// lint:off` directive.  Two placements:
//
//   Trailing same-line (preferred for short decls):
//     var counter: u32 = 0; // lint:off module-var: atomic per-world stamp
//
//   Leading prev-line (for long decls that would bust the 120-col rule,
//   or multi-line decls where the trailing comment would land awkwardly):
//     // lint:off module-var: JS-bridge log sink
//     var defaultSink: ?*const fn (level: i32, msg: []const u8) void = null;
//
// The directive is general - it works for any rule, not just module-var.
// See `lineSuppressedByDirective` for the full syntax.

fn isAllowlistedModuleVar(path: []const u8, name: []const u8) bool {
    if (startsWith(u8, name, "warned_")) {
        return true;
    }
    if (eql(u8, name, "zimr_app")) {
        return true;
    }
    if (endsWith(u8, path, "_fs.zig") or endsWith(u8, path, "_vs.zig")) {
        return true;
    }
    return false;
}

// ============================================================================
// Type-signal detection for `untyped-local` (rule 2).
// ============================================================================

// A "type signal" is any AST construct in the init expression
// that names a type, making `const x = <expr>` self-documenting
// without a separate `:T` annotation.
// See `src/notes/lint-zimr-plan.md` section  "Type-signal definition"
// for the full list.  In short:
//   - PascalCase identifier with >=1 lowercase letter
//   - Single uppercase letter (generic-param convention)
//   - Primitive type identifier (i32/u8/.../bool/void/...)
//   - `@as(...)` / `@TypeOf(...)` builtin
//   - Explicit-typed struct literal
//   - Pointer/array/optional/error-union type expressions

const primitives = std.StaticStringMap(void).initComptime(.{
    .{ "i8", {} },             .{ "i16", {} },      .{ "i32", {} },       .{ "i64", {} },
    .{ "i128", {} },           .{ "u8", {} },       .{ "u16", {} },       .{ "u32", {} },
    .{ "u64", {} },            .{ "u128", {} },     .{ "usize", {} },     .{ "isize", {} },
    .{ "f16", {} },            .{ "f32", {} },      .{ "f64", {} },       .{ "f80", {} },
    .{ "f128", {} },           .{ "bool", {} },     .{ "void", {} },      .{ "noreturn", {} },
    .{ "type", {} },           .{ "anyerror", {} }, .{ "anyopaque", {} }, .{ "comptime_int", {} },
    .{ "comptime_float", {} },
});

const c_types = std.StaticStringMap(void).initComptime(.{
    .{ "c_char", {} },      .{ "c_short", {} },      .{ "c_ushort", {} }, .{ "c_int", {} },
    .{ "c_uint", {} },      .{ "c_long", {} },       .{ "c_ulong", {} },  .{ "c_longlong", {} },
    .{ "c_ulonglong", {} }, .{ "c_longdouble", {} },
});

// ============================================================================
// zimr "keywords" - the curated zm vocabulary that is part of the language.
// ============================================================================

// A keyword is a zm decl that (1) must be aliased at file scope (`const NAME =
// zm.NAME;`) and used bare - never written `zm.NAME`, anywhere (`no-qualified-zm`)
// - and (2) may NOT be the name of any other decl/local (`reserved-math-names`),
// so bare `dot`/`clamp`/`atan2` always means the zimrmath function and stays
// greppable. NON-keyword zm decls (matFromAxisAngle, quatFromEulerXYZ, the obscure
// helpers, and common-word decls like `float`/`angle`/`texture`) need NEITHER:
// they may be used qualified as `zm.X` without an alias. The list is hand-curated
// (NOT every zm decl - that would forbid common local names) and maintained here;
// every entry must be a real `pub` decl in zimrmath.zig.
const keywords = std.StaticStringMap(void).initComptime(.{
    // scalar functions
    .{ "abs", {} },           .{ "sqrt", {} },           .{ "sinRad", {} },           .{ "cosRad", {} },
    .{ "tanRad", {} },        .{ "asinRad", {} },        .{ "acosRad", {} },          .{ "atanRad", {} },
    .{ "atan2Rad", {} },      .{ "sincosRad", {} },      .{ "exp", {} },              .{ "exp2", {} },
    .{ "exp10", {} },         .{ "pow", {} },            .{ "log2", {} },             .{ "log10", {} },
    .{ "floor", {} },         .{ "ceil", {} },           .{ "round", {} },            .{ "trunc", {} },
    .{ "fract", {} },         .{ "hypot", {} },          .{ "mulAdd", {} },           .{ "radFromDeg", {} },
    .{ "degFromRad", {} },
    // turns: the unit an angle is measured in when it is a fraction of a circle. Same standing
    // as `sin`/`cos` above - aliased at file scope, used bare, never shadowed - because a call
    // reading `sinTurns(phase_turns)` is the point and `zm.sinTurns(phase_turns)` is noise.
       .{ "sinTurns", {} },       .{ "cosTurns", {} },         .{ "tanTurns", {} },
    .{ "sincosTurns", {} },   .{ "turnsFromRad", {} },   .{ "radFromTurns", {} },     .{ "turnsFromDeg", {} },
    .{ "degFromTurns", {} },
    // interpolation / range
     .{ "lerp", {} },           .{ "clamp", {} },            .{ "clamp01", {} },
    .{ "smoothStep", {} },    .{ "min", {} },            .{ "max", {} },              .{ "smootherStep", {} },
    .{ "smoothStep01", {} },  .{ "smootherStep01", {} },
    // vector functions
    .{ "dot", {} },              .{ "dot2", {} },
    .{ "dot3", {} },          .{ "dot4", {} },           .{ "cross", {} },            .{ "cross2", {} },
    .{ "length", {} },        .{ "length2", {} },        .{ "length3", {} },          .{ "length4", {} },
    .{ "lengthSq2", {} },     .{ "lengthSq3", {} },      .{ "lengthSq4", {} },        .{ "normalize", {} },
    .{ "normalize2", {} },    .{ "normalize3", {} },     .{ "normalize4", {} },       .{ "distance", {} },
    .{ "distance2", {} },     .{ "distance3", {} },      .{ "distance4", {} },        .{ "reflect2", {} },
    .{ "reflect3", {} },      .{ "refract2", {} },       .{ "refract3", {} },         .{ "project3", {} },
    .{ "reject3", {} },       .{ "angle2", {} },         .{ "angle3", {} },
    // vector constructors
              .{ "vec2", {} },
    .{ "vec3", {} },          .{ "vec4", {} },
    // constants
              .{ "pi", {} },
    // `phi` is NOT reserved, deliberately: it means an SSA phi node in spv2wgsl and the
    // azimuthal angle in spherical coordinates, both of which predate and outnumber the
    // golden ratio here. Reserving it made every angle named `phi` a violation. The
    // constant is `golden_ratio` now, and that is what is reserved.
                  .{ "tau", {} },
    .{ "golden_ratio", {} },  .{ "nan", {} },            .{ "inf", {} },              .{ "sqrt2", {} },
    .{ "sqrt1_2", {} },       .{ "euler", {} },          .{ "log2e", {} },            .{ "log10e", {} },
    .{ "ln2", {} },           .{ "ln10", {} },           .{ "two_sqrtpi", {} },       .{ "rad_per_deg", {} },
    .{ "deg_per_rad", {} },
    // types (a zimr program means zm.Color/zm.Mat4/... by these names - never re-bind them)
      .{ "Aabb", {} },           .{ "Aabb2", {} },            .{ "Boolx4", {} },
    .{ "Boolx8", {} },        .{ "Boolx16", {} },        .{ "CameraProjection", {} }, .{ "ColorU32", {} },
    .{ "Complex", {} },       .{ "F32x4Component", {} }, .{ "F32x8", {} },            .{ "F32x16", {} },
    .{ "Mat", {} },           .{ "Mat2", {} },           .{ "Mat22", {} },            .{ "Mat3", {} },
    .{ "OrthoBasis3", {} },   .{ "Plane2", {} },         .{ "Quat", {} },             .{ "RayCamera", {} },
    .{ "RayCameraDesc", {} }, .{ "Rot2", {} },           .{ "Sweep2", {} },           .{ "Transform2", {} },
    .{ "Trs", {} },           .{ "Vec", {} },            .{ "Vec2i", {} },            .{ "Vec3", {} },
    .{ "Vec2", {} },          .{ "Color", {} },          .{ "Ray", {} },              .{ "RayCollision", {} },
    .{ "Transform", {} },     .{ "quat", {} },           .{ "Camera2D", {} },         .{ "Camera3D", {} },
    // more functions (distinctive, no collisions). `splat3` / `splat2` / `splat2i` are the rest of the `splat`
    // family - what `prefer-splat` writes for Vec3 / Vec2 / Vec2i.
    .{ "complex", {} },       .{ "determinant", {} },    .{ "f32x4", {} },            .{ "f32x8", {} },
    .{ "lerpV", {} },         .{ "mapLinear", {} },      .{ "modAngle", {} },         .{ "mulMat", {} },
    .{ "mulMatVec", {} },     .{ "niceNum", {} },        .{ "remap", {} },            .{ "scaling", {} },
    .{ "splat", {} },         .{ "swizzle", {} },        .{ "transpose", {} },        .{ "vec", {} },
    .{ "splat3", {} },        .{ "splat2", {} },         .{ "splat2i", {} },
    // numeric conversions (int<->float helpers; never a local name)
             .{ "float", {} },
    .{ "float64", {} },       .{ "int", {} },
});

// ============================================================================
// Detailed rule notes (turn 344).
// ============================================================================

// Printed once per `lint-check` run, the first time each tag fires.
// The goal: surface the WHY of every rule without the user having to
// open claude.md.  A two-paragraph note above the first violation
// of a rule is enough context for someone to decide whether the rule
// applies to their case or whether the linter is wrong.
//
// Per-tag, per-run (not per-file) - the `seen_tags` set lives in `main`
// across the whole file loop.
//
// This table is also the linter's ONE list of rules: every tag any check can
// emit has an entry, which is what lets `--enable` and the `unknown-lint-tag`
// check tell a real tag from a typo.

const RuleNote = struct {
    tag: []const u8,
    title: []const u8,
    body: []const u8,
    /// A rule still WORK IN PROGRESS reports but never fails a run: its findings
    /// are printed, marked, and counted apart, and never reach the exit code. It
    /// is the state a new rule is in while it is written and a tree is converted
    /// to it; once the tree is clean the rule is finished (drop this flag) and
    /// fails a run like every other.
    work_in_progress: bool = false,
};

/// Whether `tag` names a rule still in progress in `notes` - `isWorkInProgressTag` for any table.
fn isWorkInProgressIn(notes: []const RuleNote, tag: []const u8) bool {
    for (notes) |note| {
        if (eql(u8, note.tag, tag)) {
            return note.work_in_progress;
        }
    }
    return false;
}

const rule_notes = [_]RuleNote{
    .{
        .tag = "import-cycle",
        .title = "import-cycle - files must not import each other, directly or through others",
        .body =
        \\Zig accepts it: a module's files are analysed lazily, so two files that
        \\import each other compile. It still costs. The two files become one unit -
        \\neither can be read, tested or moved without the other - and every test
        \\root that reaches one compiles both closures. `robot_mjcf` <-> `robot_physics`
        \\is why test-fast re-ran the same few hundred tests under several roots.
        \\
        \\The shapes it takes, and the fix for each:
        \\  * shared TYPES living in the file that also holds the entry point -
        \\    move the entry point up into its own file;
        \\  * a TEST that needs a higher-level file - move the test up, into a file
        \\    that already depends on both (the Go1 gate, into robot_physics);
        \\  * a file importing ITSELF to qualify its own names - `@This()`.
        \\
        \\Only `@import("*.zig")` paths are resolved; named modules are wired in
        \\build.zig and invisible here. Files outside this run are not seen, so the
        \\full-tree gate is the run that counts. A reviewed, deliberate back edge
        \\carries `// lint:off import-cycle: <why>` on its import line and is then
        \\left out of the graph.
        ,
    },
    .{
        .tag = "raw-pass-state-bind",
        .title = "raw-pass-state-bind - bind pipeline/bind-groups through the PassState cache",
        .body =
        \\Raw `render_pass.setPipeline(...)` / `render_pass.setBindGroup(...)`
        \\bypass PassState's dedup caches (`current_pipeline` /
        \\`current_bind_groups`).  That desyncs the cache from the GPU's real
        \\state, so a later dedup'd rebind (e.g. Renderer2D.bindForPass) can skip
        \\and leave the wrong pipeline / bind group active — the "draw_points_pl
        \\does not match ortho_ring at group 0" class of bug, which the headless
        \\smoke cannot see (it tracks handle balance, not draw-time validation).
        \\Use `WgpuBackend.setPipelineHandle(ps, handle)` for a raw wgpu pipeline,
        \\`WgpuBackend.setPipeline(ps, typed)` for a typed RenderPipeline, and
        \\`WgpuBackend.setBindGroup(ps, group, bg)` for bind groups.  Only
        \\gpu_iface.zig (the cache owner) and wgpu.zig (the raw layer) call the
        \\render_pass primitives directly.  A reviewed exception carries
        \\`// lint:off raw-pass-state-bind: <why>`.
        ,
    },
    .{
        .tag = "parse-error",
        .title = "parse-error - file failed to parse, AST checks skipped",
        .body =
        \\Critical: this file has syntax-level errors and the linter
        \\could not analyze it.  All AST-based rules are skipped for
        \\this file - so a clean lint count means NOTHING for it
        \\until the parse error is fixed.  Common causes: a half-
        \\applied autofixer left `} };` after a struct-init return,
        \\or a missing `;`, or mismatched braces.  Run
        \\`zig ast-check <file>` for the full error list.  Until
        \\this is cleared, the lint total is undercounting that
        \\file's real issues.
        ,
    },
    .{
        .tag = "zig-fmt",
        .title = "zig-fmt - the file is laid out as `zig fmt` lays it out",
        .body =
        \\`zig fmt --check`, inside the linter. The file is rendered by `zig fmt`'s own
        \\renderer (`std.zig.Ast.render`, from the std this linter was built with - the
        \\Zig that builds the project) and compared with the file on disk; the finding
        \\points at the first line that differs. `// zig fmt: off` regions are left
        \\alone, as `zig fmt` leaves them.
        \\
        \\It is a rule rather than a separate `zig fmt --check` so that layout reports
        \\like every other finding: in the same list, with the same `autofix:` hint.
        \\`zig fmt --check` named a file and said nothing about what to run. The fix -
        \\`zig build fix` - writes the formatted file and prints its diff.
        ,
    },
    .{
        .tag = "fn-args-multiline",
        .title = "Rule 1 - fn signatures: 5+ args multiline; 3-4 args one-line only if <=90 cols",
        .body =
        \\Functions with 5 or more parameters split to one argument per line
        \\with a trailing comma.  Improves diff-ability: each line touches at
        \\most one parameter, and `zig fmt` will keep the layout stable.
        \\3 or 4 parameters MAY stay on one line when the whole signature line
        \\fits in 90 columns; if it's wider than 90 they also break one-per-line.
        \\Two-arg signatures may stay on one line if they fit under 80 cols;
        \\single-arg signatures always stay one line.
        \\Exception (turn 362): "simple uniform primitive" signatures —
        \\every param has the same primitive type (`f32`, `i32`, `bool`,
        \\...), no param has a doc comment, full line ≤ 80 cols.  These are
        \\stable mathematical shapes (`fn vec(x: f32, y: f32, z: f32) Vec`,
        \\`fn boolx4(e0: bool, e1: bool, e2: bool, e3: bool) Boolx4`) where
        \\diff-ability doesn't pay for vertical space.
        ,
    },
    .{
        .tag = "untyped-local",
        .title = "Rule 2 - locals: write the type even when Zig can deduce it",
        .body =
        \\Reason: greppability.  To find every place that produces a Foo,
        \\grep `: Foo` - locals that omit their annotation hide from that
        \\search.  Exceptions auto-detected by the linter: allocations
        \\(`gpa.alloc(T, n)`), casts (`@as(T, ...)`, `@intCast`, etc.),
        \\explicit-typed struct literals (`Mat{...}`), typed array
        \\literals (`[N]T{...}` and `[_]T{...}`), captures
        \\(`for (xs) |x|`, `catch |err|`) where the type is already
        \\on the line, and inits that call the zm `float`/`float64`
        \\helpers (their f32/f64 result type is pinned).
        ,
    },
    .{
        .tag = "branch-braces",
        .title = "Rule 3 - braces required on every if/else/while/for body",
        .body =
        \\Even single-statement bodies get braces.  A one-line `if (x)
        \\return;` that later grows a second statement silently gains
        \\that statement OUTSIDE the conditional - braces make the
        \\structure explicit at the point of edit.  No exceptions for
        \\`return`, `continue`, `break`, assignments, or function calls.
        ,
    },
    .{
        .tag = "array-mult",
        .title = "Rule 5 - array repetition: use @splat, not `**`",
        .body =
        \\The array-repetition `**` operator is being retired from Zig.
        \\Use `@splat(value)` for fill-N-with-same-value arrays.  For
        \\multi-element patterns like `[_]u8{1,2,3,4} ** 4`, expand to
        \\an explicit literal.  For string repetition, use comptime `++`
        \\or write the explicit literal.  `@splat` typically needs a type
        \\annotation on the LHS to bind the result size.
        ,
    },
    .{
        .tag = "module-var",
        .title = "Rule 9 - no module-level mutable globals",
        .body =
        \\Mutable state belongs on a struct that's owned, allocated, and
        \\passed explicitly.  Module-level `var` is forbidden except at
        \\C-ABI seams that can't carry context.  Blanket allow-list (in
        \\code, not per-site): `warned_*` flag names, `zimr_app`, and
        \\`*_fs.zig`/`*_vs.zig` shader stage files.  For one-off cases,
        \\add a `// lint:off module-var: <reason>` directive — either
        \\trailing on the same line, or on a comment-only line above
        \\(use prev-line when trailing would bust the 120-col rule).
        \\Anything else means the function signature should carry the
        \\state instead.
        ,
    },
    .{
        .tag = "depth-format",
        .title = "3D render needs a depth attachment",
        .body =
        \\A file that calls `beginMode3D` / `beginMode3DMatrix` AND owns a
        \\window config (`AppSpec(...)` with a `.window`) must set
        \\`.depth_format = .depth24_plus` in that config. Without it,
        \\`beginMode3D` asserts at runtime ("needs a depth attachment") the
        \\first time a real GPU renders the frame -- a crash a GPU-less
        \\build can't catch, so we catch it statically. Depth is what makes
        \\near geometry occlude far geometry; a 3D pass without it is wrong
        \\even when it doesn't assert. Helper files that draw 3D but declare
        \\no AppSpec (a shared `render.zig`) are exempt: the file that
        \\includes them owns the window and is where the config belongs.
        ,
    },
    .{
        .tag = "line-length",
        .title = "Rule 10 - lines under 120 columns",
        .body =
        \\Hard cap at 120.  Wide lines almost always mean too much is
        \\happening on one line; the fix is the fix you'd want anyway:
        \\add a trailing comma to the offending list (zig fmt then
        \\breaks it across lines), lift a sub-expression to a named
        \\local, or split a chained method call across `.` boundaries.
        \\Markdown files are exempt; the rule is only for `.zig` and
        \\other code files.
        ,
    },
    .{
        .tag = "ascii-comments",
        .title = "Comments are ASCII",
        .body =
        \\Every comment - `//`, `///` and `//!` - is plain ASCII. A comment
        \\that needs a font gets mangled by a terminal with the wrong
        \\locale, a diff viewer or a patch pasted through a chat window,
        \\and a symbol nobody can type is a symbol nobody can grep for.
        \\Spellings: `->` `<-` `=>` for arrows, `*` for stars, bullets and
        \\middle dots, `-` for every dash, `x` for times, `~` for
        \\approximately, `>=` `<=` `!=`, `+/-`, `...`, `sqrt`, `deg`,
        \\`section 12`, `M^-1` and `S^T` for superscripts, `f_x` for
        \\subscripts, Greek letters by name (`theta`, `omega`), `q_dot`
        \\and `r_hat` for accented symbols, `+-+` and `|` for boxes.
        \\When a comment is ABOUT a character (a UTF-8 byte count, say),
        \\name it by code point: `U+4E2D is 3 bytes`. String and char
        \\literals are data and are not checked - except test names,
        \\which have their own rule, `ascii-test-names`.
        ,
    },
    .{
        .tag = "ascii-test-names",
        .title = "Test names are ASCII",
        .body =
        \\A `test "..."` name is prose, not data: it is printed by the test
        \\runner, pasted into `-Dtest-filter=<substring>`, and quoted in
        \\notes. A name holding an arrow or a star is one nobody can type
        \\into a filter from a keyboard, and one a Windows console may print
        \\as garbage. Same spellings as `ascii-comments`: `->` for arrows,
        \\`*` for stars, `-` for dashes, `x` for times, `sqrt`, `pi`, and a
        \\character that is the SUBJECT of the test named by code point
        \\(`U+20AC is three bytes E2 82 AC`).
        ,
    },
    .{
        .tag = "named-struct-init",
        .title = "Rule 15 - use `.{...}` when the LHS already declares the type",
        .body =
        \\When a `const x: Foo = ...;` or `return ...;` site already
        \\names the struct type on the LHS or in the return slot, the
        \\initializer should be `.{...}`, not `Foo{...}`.  The named
        \\form is redundant noise.  Detected even through `try`,
        \\`orelse`, `catch`, `if-else`, and grouped expression wrappers.
        ,
    },
    .{
        .tag = "prefer-decl-literal",
        .title = "prefer-decl-literal - `.make(...)` when the declaration already names the type",
        .body =
        \\`const grid: Tensor(T) = try Tensor(T).alloc(gpa, shape);` says the type
        \\twice. Zig's decl literal says it once: where the result type is known,
        \\`.name` is looked up IN that type, so `try .alloc(gpa, shape)` is the very
        \\same call. The call twin of named-struct-init.
        \\
        \\A decl literal searches the DECLARED type (an anonymous `.{...}` merely
        \\coerces to it), so this fires only where the two spellings are the same
        \\call by construction: the declaration has a type and an initializer; the
        \\initializer IS the call, or `try` of it (under `catch`, `orelse`, a field
        \\access or parentheses it is another expression, left alone); and the
        \\receiver is spelled with exactly the annotation's tokens - the same
        \\expression in the same scope, so the same type. `const b: Base =
        \\Other.make();` is never touched: `.make()` would look `make` up in `Base`.
        \\
        \\`--fix` deletes the receiver, keeping everything from the `.` on. It was
        \\work in progress while zimr's tree was converted (zimrnum first: 1160
        \\sites, compiled and tested), and is enforced now that the tree is clean.
        ,
    },
    .{
        .tag = "constructor-in-view",
        .title = "constructor-in-view - a bare `.init(...)` only where the declaration names the type",
        .body =
        \\`.init(gpa)` says nothing about what it makes. That is fine where the
        \\declaration names it - `const world: World = try .init(gpa, 256);` -
        \\and nowhere else: a decl literal that is a BARE constructor word -
        \\init create alloc new from clone dupe copy make build load open parse
        \\spawn decode - in an assignment (`s.world = .init(gpa)`), a struct-
        \\literal field (`.{ .world = .init(gpa) }`), an argument, a return or a
        \\tuple element makes a value nobody can name from where it is made.
        \\Spell the type there (`World.init(gpa)`), or give it a typed
        \\declaration first. A longer name carries its own words and is left
        \\alone: `s.world = .initBozo(gpa)`, `.fromSlice(s)`.
        \\
        \\The declaration's value includes its branches - `try`, both sides of
        \\`catch` and `orelse`, parentheses, `if` / `else`, `switch` prongs - and
        \\the elements of the array it declares: `var graphs: [2]Graph(f64) =
        \\.{ .init(arena), .init(arena) };` spells each one's type. A struct-
        \\literal field is not its value: `.{ .t = .init(a) }` hides the field's
        \\type. A struct field's default value counts too: `cam: OrbitCamera =
        \\.init(...)` names its type. A declaration split across lines is still
        \\one declaration. It does not
        \\depend on any type's or variable's name. No autofix: the linter cannot
        \\know a field's, parameter's or return slot's type. The converse of
        \\prefer-decl-literal.
        ,
    },
    .{
        .tag = "turn-in-radian-call",
        .title = "turn-in-radian-call - a pi or tau inside a trig argument means you wanted turns",
        .body =
        \\`sinRad(x * tau)` multiplies a turn count by tau so that a radian
        \\function will take it - and every fast trig implementation divides
        \\it straight back out. The multiply and the divide cancel, and both
        \\lose bits: measured at f32, `sin(tau*x)` at x = 100_000.25 turns is
        \\off by 2.76e-4 where `sinTurns(x)` is EXACT, and over 2000 whole
        \\turns at f64 the radian route drifts to 1.38e-12 where turns return
        \\exactly zero.
        \\
        \\Fix: call `sinTurns`/`cosTurns`/`tanTurns` and drop the constant.
        \\A quarter turn is 0.25, a half turn is 0.5. If the value really is
        \\an angle in radians that happens to be built from pi, bind it to a
        \\`_rad` local first so the call site reads as one unit throughout.
        \\
        \\This rule does NOT ban `@sin` or `sinRad` - a genuine radian angle
        \\is exactly what they are for. It bans only the round trip.
        ,
    },
    .{
        .tag = "std-math",
        .title = "std-math - no std.math outside zimrmath (GPU-portability)",
        .body =
        \\std.math is host-only by design (f64 code paths, lookup
        \\tables) and does not reliably lower to SPIR-V, so using it at
        \\a call site silently risks breaking the GPU build.  zimrmath
        \\is the ONE file allowed to touch std.math, and only behind a
        \\`comptime !is_gpu` gate with a hand-rolled GPU branch.
        \\
        \\Fix: add the function you need to zimrmath.zig as a `zm.*`
        \\wrapper — `if (comptime !is_gpu) return std.math.<fn>(...);`
        \\then an `else` branch that works on SPIR-V — verify it
        \\compiles for a shader, and call `zm.<fn>` at the site.  This
        \\rule has NO `// lint:off`: the wrap is the only sanctioned
        \\path, so that code is GPU-portable by construction.
        ,
    },
    .{
        .tag = "std-debug-assert",
        .title = "std-debug-assert - no std.debug.assert outside tools",
        .body =
        \\The codebase shares one assert family in zimrmath: `zm.assert(ok,
        \\@src())` and `zm.assertf(ok, @src(), fmt, args)`.  Both lower to a
        \\bare `unreachable` on GPU and in ship builds (identical to
        \\std.debug.assert) but log file:line + `@panic` in dev.  Engine
        \\(src/) and example code must use them; mixing in std.debug.assert
        \\splits the codebase across two mechanisms for no gain.
        \\
        \\Fix: `const assert = zm.assert;` then `assert(ok, @src());` (or
        \\`assertf` for a message).  Native tools (under tools/, plus the
        \\in-src transpiler spv2wgsl) compile for the host only and are
        \\exempt.  Comptime/container-scope checks where @src() is illegal use
        \\@compileError, or opt out with `// lint:off std-debug-assert: <why>`.
        ,
    },
    .{
        .tag = "import-at-top",
        .title = "import-at-top - std/builtin/root imports belong at file scope",
        .body =
        \\A standard-library import (std, builtin, root) buried inside a
        \\function body should be a single column-0 binding at the top of the
        \\file instead.  Function-local std imports hide the dependency and
        \\force per-function aliases that the untyped-local rule then rejects.
        \\
        \\Project-module imports inside a function (e.g.
        \\`const enc = @import("gpu.zig");`) are NOT flagged -
        \\that is the sanctioned cycle-breaking idiom for the single-module
        \\layout.  Only std/builtin/root are flagged.
        \\
        \\Fix: hoist to a file-scope `const std = @import("std");`.  Genuine
        \\comptime-only or conditional imports opt out with
        \\`// lint:off import-at-top: <why>`.
        ,
    },
    .{
        .tag = "clamp-pattern",
        .title = "Bonus rule - prefer zm.clamp over @min(@max())",
        .body =
        \\Pattern `@min(hi, @max(lo, v))` or `@max(lo, @min(hi, v))`
        \\should be `zm.clamp(v, lo, hi)` (works for scalars AND Vector
        \\types, on CPU + GPU + comptime).  The named call says
        \\WHAT the math does; the manual form makes the reader trace
        \\the nesting to recognise the pattern.  The linter skips the
        \\flag when lo or hi is itself a builtin call - some uses
        \\(like ray-AABB t-near intersection math) syntactically
        \\match but semantically aren't clamps.
        ,
    },
    .{
        .tag = "as-round",
        .title = "Rule - no @as(T, @trunc(x)); use bare builtin or zm.* helper",
        .body =
        \\`@as(T, @trunc(x))` (and @floor / @round / @ceil) is banned.
        \\
        \\Since Zig 0.16 the rounding builtins forward their result type and
        \\convert straight to an integer when that type is known (see the
        \\`int-from-float` rule), so wrapping them in `@as(T, ...)` just
        \\spells the type a second time.  Pick one:
        \\  - T is inferable from context (a typed decl, a fn arg/return, a
        \\    struct field, an array element) -> just write `@trunc(x)`;
        \\  - T must be spelled out -> use the zimrmath helper `zm.int(T, x)`
        \\    (trunc toward zero), `zm.floori(T, x)`, `zm.roundi(T, x)`, or
        \\    `zm.ceili(T, x)` — they read better than the @as form.
        \\`// lint:off as-round: <why>` for a rare deliberate cast.
        ,
    },
    .{
        .tag = "redundant-cast",
        .title = "Rule - drop the cast helper when the decl already gives the type",
        .body =
        \\A `const`/`var` with an explicit `: T` annotation whose initializer
        \\is exactly a `zm.int(...)` / `zm.floori` / `zm.roundi` / `zm.ceili`
        \\call spells the target type twice — the `: T` already drives the
        \\rounding builtin's result type.  Write the bare builtin instead:
        \\`const n: i32 = @trunc(x);` not `const n: i32 = zm.int(i32, x);`.
        \\Keep the `zm.*` helpers for the spots where the type ISN'T inferable
        \\(fn-call args, format tuples, etc.).  `// lint:off redundant-cast`.
        ,
    },
    .{
        .tag = "int-from-float",
        .title = "Rule - use @trunc/@floor/@round directly, not @intFromFloat",
        .body =
        \\`@intFromFloat` is banned outright — it is DEPRECATED in current Zig.
        \\
        \\THE ONE DECISION (don't overthink this — it cost a full turn once):
        \\  Is the target integer type inferable from where the value LANDS?
        \\  A value lands in an inferable type when it is: the initializer of a
        \\  `const x: T = ...` / `var x: T = ...`, a `return` in a fn with an
        \\  int return type, a fn CALL argument, a struct-field or array-element
        \\  value, or a `.{ ... }` field with a known type.
        \\
        \\  YES, inferable  ->  write the BARE builtin, nothing else wrapped:
        \\        const cell: i32 = @round(wx - off);   // rounds AND converts
        \\        return @trunc(x);                      // fn returns i32
        \\        foo(@floor(y));                        // arg type is known
        \\      Do NOT write `@intFromFloat(@round(x))`, `@as(i32, @round(x))`,
        \\      or `zm.roundi(i32, x)` in these spots — the type is already
        \\      there once; spelling it again is the violation.
        \\
        \\  NO, not inferable (e.g. the value feeds an `anytype`/format tuple,
        \\  or is used inline where no type drives it)  ->  name it with the
        \\  zimrmath helper, which carries the type AND the rounding mode:
        \\        zm.int(T, x)    trunc toward zero   (the "trunki")
        \\        zm.floori(T, x) toward -inf
        \\        zm.roundi(T, x) nearest             (the "roundi")
        \\        zm.ceili(T, x)  toward +inf
        \\
        \\WHY the bare builtin works (Zig 0.16+): `@trunc`/`@floor`/`@round`/
        \\`@ceil` FORWARD their result type, so when that type is an integer the
        \\builtin does the float->int conversion itself, in one step. That is
        \\why `@intFromFloat` is now pure redundancy, and why the builtin name
        \\(`@round` vs `@trunc`) also documents the rounding mode at the call
        \\site — a bonus the old silent `@intFromFloat` truncation never gave.
        \\
        \\QUICK PICK: type is on the line already -> bare `@round`/`@trunc`/… ;
        \\type is nowhere on the line -> `zm.roundi`/`zm.int`/… . That's the
        \\whole rule.  `// lint:off int-from-float: reason` for the rare case.
        ,
    },
    .{
        .tag = "reserved-math-names",
        .title = "Rule - reserved math vocabulary: don't shadow the zm.* core",
        .body =
        \\A curated core of common math words - dot, cross, length, normalize,
        \\lerp, clamp, min, max, sqrt, sin, cos, pow, pi, tau, ... (full list in
        \\RESERVED_MATH_PLAN.md §3) - is RESERVED in any file that imports zm.
        \\
        \\The point: a bare `length` / `dot` / `min` should always mean the
        \\zimrmath function, so the vocabulary stays greppable across all math
        \\code.  So in a zm-importing file you may not declare a `const` / `var`
        \\/ `fn` with one of these names - EXCEPT the canonical import binding
        \\`const length = zm.length;` (binding name == member name), which is
        \\exactly how you pull the name in.  To fix a collision: rename the local
        \\(`length`->`len`, `min`->`min_corner`) or, if it just recomputes a zm
        \\value, use `zm.<name>` directly.
        \\
        \\This principle is about ONE math vocabulary - functions AND types.  Any
        \\file that does vector/matrix/quaternion math uses zm's types
        \\(`zm.Vec`, `zm.Mat3`, `zm.Aabb`, ...) and zm's functions; it does not
        \\define its own `@Vector(4, f32)` alias, hand-roll a `vec()`, or reach
        \\for `std.math`.  In particular, NOT importing zm so these rules go quiet
        \\is circumvention, not an exemption: a file is only genuinely exempt when
        \\it does no math at all.  If you're writing math, import zm and use it.
        \\
        \\Struct/enum FIELDS and PARAMS are not covered - only decls.
        \\`lint:off reserved-math-names: why` for a deliberate exception.
        ,
    },
    .{
        .tag = "prefer-vec",
        .title = "Rule - prefer `Vec` over the verbose `@Vector(4, f32)`",
        .body =
        \\`Vec` (= `@Vector(4, f32)`) is zimr's central type — the SIMD register
        \\the whole math layer is built on.  Spelling it out longhand as
        \\`@Vector(4, f32)` in a local, param, return type, or non-extern type
        \\buries the most important type in the codebase under boilerplate, so
        \\use the alias: `Vec`, and likewise `Vec3` for `@Vector(3, f32)` and
        \\`Vec2` for `@Vector(2, f32)`.  The alias resolves through the file's
        \\`zm` import like every other math name (see reserved-math-names).
        \\
        \\`Vec` works even in `extern`/`packed` UBO/vertex schema fields — it
        \\transpiles to the identical `vec4<f32>` std140 layout — so those are
        \\flagged too.  The ONLY exemption is the canonical definitions in
        \\`zimrmath.zig` themselves (`pub const Vec = @Vector(4, f32)` etc.).
        \\
        \\`--fix` rewrites the whole `@Vector(N, f32)` span to the alias (only
        \\the f32 widths 2/3/4 have aliases; other element types / widths keep
        \\the raw form).  `// lint:off prefer-vec: <why>` for a single
        \\deliberate raw use.
        ,
    },
    .{
        .tag = "anon-return",
        .title = "anon-return - name the struct a function returns",
        .body =
        \\Functions returning `struct { ... }` directly are awkward at
        \\call sites: callers can't write `const x: ReturnType = ...`
        \\because identically-shaped anonymous structs are DISTINCT
        \\types in Zig.  Workarounds are `@TypeOf(call())` (verbose)
        \\or skipping the annotation (violates untyped-local).  The fix
        \\is to name the type, e.g.
        \\  `pub const LogicalPoint = struct { x: f32, y: f32 };`
        \\  `pub fn cssToLogical(...) LogicalPoint { ... }`
        \\Opt-in, and meant to be enabled together with untyped-local:
        \\without that rule a caller can simply leave the local untyped.
        ,
    },
    .{
        .tag = "shader-inline-fn",
        .title = "Shader rule - no `inline fn` in `_fs.zig` / `_vs.zig`",
        .body =
        \\Zig's SPIR-V backend emits structured-control-flow markers
        \\around inline calls that bake into the output as `if (X == X)`
        \\constant branches.  Use plain `fn` (or `pub fn`) in shader
        \\DSL files; `spirv-opt -O` does the inlining post-codegen.
        ,
    },
    .{
        .tag = "shader-no-atan",
        .title = "Shader rule - `@atan` / `@atan2` not available under SPIR-V",
        .body =
        \\Zig 0.16's SPIR-V backend doesn't expose `@atan` or `@atan2`
        \\as builtins.  Use `zm.atan2(y, x)` from shadermath — a
        \\Hastings polynomial approximation, ~0.01 rad accuracy,
        \\branch-light, recursion-free.  Add `zm.atan` similarly if
        \\you need the single-arg form.
        ,
    },
    .{
        .tag = "sampler-in-branch",
        .title = "Shader rule - sample textures at the top of shaderMain, not in a branch",
        .body =
        \\WGSL rejects an implicit-LOD sampler call (`textureSample`,
        \\which needs screen-space derivatives) reached through
        \\non-uniform control flow - Tint errors with "must only be
        \\called from uniform control flow".  Neither naga nor nagac
        \\catches this, so it only shows up at runtime.  Fix: take
        \\every sample unconditionally at the top of `shaderMain` and
        \\thread the value down into the lighting/branch code.
        ,
    },
    .{
        .tag = "sampler-in-helper",
        .title = "Shader rule - texture samples belong in shaderMain, not helper fns",
        .body =
        \\A helper fn can be called from a branch (e.g. `if (i == 0)
        \\computeShadow(...)`), which puts its texture sample in
        \\non-uniform control flow and trips WGSL's uniformity rule.
        \\Sample at the top of `shaderMain` and pass the sampled value
        \\into the helper as a parameter (see `computeShadow` taking a
        \\pre-sampled `closest_depth`).
        \\
        \\This applies ONLY to implicit-LOD samples (`io.tex(uv)` ->
        \\`textureSample`), which need derivatives and so are fragment-
        \\stage + uniform-control-flow only. Explicit-LOD accessors
        \\(`io.texLevel(uv, lod)` -> `textureSampleLevel`) take no
        \\derivatives, are uniformity-exempt, and are the only kind of
        \\sample legal in a vertex shader — they are NOT flagged, so a
        \\vertex shader may factor its fetches into a helper freely.
        ,
    },
    .{
        .tag = "decl-order",
        .title = "decl-order - declare file-scope names before they are used",
        .body =
        \\A reference to a file-scope `fn`, `const`, or `var` appears before
        \\that declaration in the source.  Zig allows container-scope decls in
        \\any order, but we keep files in logical top-down reading order: every
        \\name is defined before its first use.  Fix by MOVING the declaration
        \\above the reference (a dependency should sit above its dependents).
        \\
        \\Self-recursion is fine and never flagged - the call sits after the
        \\function's own name.  Mutual recursion (A defined first, A's body
        \\calls B which is defined later) cannot be ordered both ways; the
        \\forward leg is legal but must be opted into with a per-site
        \\`// lint:off decl-order: mutual recursion with <name>` on the call.
        ,
    },
    .{
        .tag = "whole-init-first",
        .title = "whole-init-first - fill uninitialised memory with ONE whole-struct write",
        .body =
        \\Memory from `allocator.create(T)` is uninitialised, and so is whatever an
        \\in-place `init*(self: *T, ...)` is handed (`var x: T = undefined; x.init()`).
        \\Field DEFAULTS are applied only by a struct literal - never to memory
        \\written field by field - so `self.a = ...; self.b = ...` leaves every
        \\defaulted field it skips, and every field it forgets, as garbage the
        \\compiler cannot see (a counter reading 13470109670760158464 on a phone).
        \\
        \\So the FIRST write through such a pointer must be the whole struct:
        \\`self.* = .{ .gpa = gpa, .items = undefined, ... }` - the compiler then
        \\applies every default and rejects any field left out; fields filled in
        \\later are spelled `= undefined` in the literal, visibly.  `x.* = undefined`
        \\is the footgun written out and fires too.  A method called on the pointer
        \\first (`try x.init(...)`) hands initialisation over and ends the check
        \\(an `init*` method is checked in its own right).
        ,
    },
    .{
        .tag = "returned-stack-reference",
        .title = "returned-stack-reference - never return a pointer to a local",
        .body =
        \\`return &x` where `x` is a `var`/`const` declared in THIS function hands
        \\the caller a pointer to a stack slot freed the instant the function
        \\returns - a dangling pointer, undefined behavior to read.  The compiler
        \\does not catch this.  Return by value, or return a pointer into
        \\caller-owned / heap / `self` memory instead.
        \\
        \\Only a bare `return &<identifier>` naming a local fires; `&self.field`,
        \\`&arr[i]`, `&global`, and `&literal` are fine and skipped.  A genuine
        \\exception carries `// lint:off returned-stack-reference: <why>`.
        ,
    },
    .{
        .tag = "catch-suppression",
        .title = "catch-suppression - make swallowing an error a conscious choice",
        .body =
        \\Empty `catch {}` silently swallows the error.  `catch unreachable` is
        \\worse: it is undefined behavior in ReleaseFast if it ever fires (a shipped
        \\build corrupts instead of aborting).  Neither should be the reflexive
        \\default.  Safety ranks assertf > {} > unreachable: `catch { assertf(...) }`
        \\lowers to `unreachable` in ship (KEEPS the optimizer's "can't happen" hint)
        \\AND carries a message in checked builds, so it dominates bare `catch
        \\unreachable` in every mode -- there is never a reason to write the latter.
        \\
        \\Sanctioned handlers (all pass): `catch { assertf(...) }`, a real
        \\`catch |e| { ... }` body, `catch @panic(...)`, a default value
        \\(`catch null` / `catch 0` / ...), or a control-flow diversion
        \\(`catch return` / `break` / `continue`).  A genuinely fine swallow -- a
        \\writer/log op, or OOM-survivable degradation a shipped game must ride out
        \\-- carries `// lint:off catch-suppression: <why>` (NOT assertf, which would
        \\abort a checked build on a failure you mean to survive).
        ,
    },
    .{
        .tag = "prefer-assert-unreachable",
        .title = "prefer-assert-unreachable - name the impossible, with a message",
        .body =
        \\`assert(false, @src())` and `assertf(false, @src(), fmt, args)` are the
        \\long way to say `assertUnreachable(@src(), fmt, args)` -- the zimrmath
        \\helper for "control should never get here".  The named form reads better
        \\and (unlike `assert(false, ...)`) always carries a message.  For a
        \\VALUE-result `catch` (nothing to continue with) use the `noreturn`
        \\sibling `panicf(@src(), fmt, args)` instead.
        \\
        \\Fix: `... catch assertUnreachable(@src(), "OOM", .{});` (void result) or
        \\`const w = create() catch panicf(@src(), "OOM", .{});` (value result).
        ,
    },
    .{
        .tag = "no-catch-return",
        .title = "no-catch-return - `catch |e| return e` is just `try`",
        .body =
        \\`foo() catch |e| return e` catches the error only to return it unchanged
        \\-- which is exactly what `try foo()` does. Fires ONLY on the truly-
        \\equivalent form (the returned value is the captured error itself), never
        \\`catch |e| return someDefault`, which is a handled default and stays.
        \\
        \\Fix: `try foo()`.
        ,
    },
    .{
        .tag = "unused-global",
        .title = "unused-global - a private file-scope decl nothing references",
        .body =
        \\A non-`pub` file-scope `const`/`var`/`fn` whose name never appears again in
        \\its own file is dead: the compiler flags unused locals/params but says
        \\nothing about unused file-scope decls. Skips `pub` (usable cross-file,
        \\invisible to a per-file linter) and `export`/`extern` fns (WASM entry
        \\points + ABI decls -- used externally, never dead). Approximation: counts
        \\bare-identifier occurrences of the name (a leading `.` = field access, not a
        \\reference), so `@hasDecl`/reflection by string name is invisible -- pin such
        \\intentional stubs with `// lint:off unused-global: <why>`.
        \\
        \\Fix: delete it (`--fix` does this, and re-runs to sweep the cascade), or
        \\`pub` it if it's meant to be API.
        ,
    },
    .{
        .tag = "useless-error-return",
        .title = "useless-error-return - `!T` on a fn whose body can't error",
        .body =
        \\A fn typed `!T`/`E!T` with no way to produce an error forces every caller
        \\into a needless `try`. The body counts as able-to-error when: its tokens
        \\include `try`/`errdefer`/`error`; a `catch` RE-RAISES (its handler returns
        \\something not provably non-error, like `catch return WriteError.Failed`) --
        \\a handler yielding a default or a bare `return;` HANDLES it and does not
        \\count; or any `return` value isn't PROVABLY non-error (only a literal,
        \\aggregate init, or enum literal is). So `return MyError.Foo`,
        \\`return maybeErr()`, `return someLocal`, and `return if (c) a() else b()`
        \\all correctly suppress it.
        \\
        \\A fn whose name is used as a VALUE (`.init = myFn`, `&myFn`,
        \\`register(myFn)`) is skipped: its signature is pinned by whatever consumes
        \\it (an `AppSpec`-style `fn (...) anyerror!void` field, a fn pointer), and
        \\Zig won't coerce a plain-`void` fn into an error-union slot, so the `!`
        \\isn't the author's to drop.
        \\
        \\Fix: drop the `!` and the callers' `try`. If the signature is fixed by a
        \\contract the linter can't see (a duck-typed hook others override, an
        \\emitter family's uniform shape, deliberate API parity), keep it with
        \\`// lint:off useless-error-return: <why>`.
        ,
    },
    .{
        .tag = "duplicate-case",
        .title = "duplicate-case - two switch prongs with the same body",
        .body =
        \\Two prongs of one switch whose bodies are byte-identical: either they were
        \\meant to be a single prong (`.a, .b => body`) or one is a copy-paste that
        \\forgot to change. Merging is always semantics-preserving, so the collapse
        \\is safe.
        \\
        \\Deliberately narrow, because repeating a body is often GOOD Zig. Skipped:
        \\bare-expression bodies (a lookup table like `.rgb565 => 2, .rgba4444 => 2`
        \\reads better one-per-line); empty `{}` bodies (an exhaustive switch's
        \\per-variant no-op, which is what makes adding an enum field a compile
        \\error); any prong carrying its own comment (each SPIR-V opcode documenting
        \\its operand layout, each event saying why it is ignored -- that conscious
        \\choice is already made); prongs with a CAPTURE `|v|` (the payload type can
        \\differ per tag, so identical text isn't identical meaning and the merge may
        \\not compile); and `inline` prongs (the tag is comptime-known inside, so the
        \\same text can lower differently). Byte equality means a differing comment
        \\keeps it quiet -- the safe direction.
        \\
        \\Fix: merge them into one prong, or make the bodies actually differ.
        ,
    },
    .{
        .tag = "redundant-import",
        .title = "redundant-import - the module already has a file-scope alias",
        .body =
        \\When a file binds `const wgpu = @import("wgpu.zig");`, spelling the import
        \\out again inline is the long way round: `@import("wgpu.zig").render_pass`
        \\says exactly what `wgpu.render_pass` says, with the alias sitting right
        \\there. Same "one obvious way" as no-qualified-std and no-qualified-zm,
        \\generalized to every module. `--fix` swaps in the alias.
        \\
        \\Only WHOLE-module bindings count. A member binding
        \\(`const truetype = @import("codecs.zig").truetype;`) is not an alias for
        \\the module, so other imports of it stay quiet. A module bound to two
        \\different names is skipped entirely -- there is no single right
        \\replacement, and choosing one is a human's call.
        \\
        \\Fix: use the alias (`--fix` does it).
        ,
    },
    .{
        .tag = "canonical-alias",
        .title = "canonical-alias - import a module under the name it declares",
        .body =
        \\A module declares how importers should name it with a top-of-file
        \\`//! lint:alias <name>`, and every importer must use that spelling. One
        \\name per module tree-wide is what makes `grep "zm\\."` find every use;
        \\seven different names for image.zig (`img`, `image_mod`,
        \\`textures_module`, ...) makes it find none of them. The declaration lives
        \\WITH the module, not in a table inside the linter, so a new file ships its
        \\own convention and line one documents how to import it.
        \\
        \\Opt-in: only modules that declare are enforced, so families that
        \\deliberately share a generic local name (every shader importing its own
        \\`*_io.zig` as `shader_io`) declare nothing and stay untouched. `pub`
        \\bindings are exempt -- `pub const colors = @import("types.zig");` is API
        \\surface named for the caller (`z.colors.sky_300`), not a private alias.
        \\
        \\Pick the filename stem unless density argues otherwise: `zm` (dense math
        \\expressions) and `z` (every example line) earn short names; `img`, `ent`,
        \\`core` and `k` do not.
        \\
        \\Fix: rename the binding (and its uses) to the declared name, or
        \\`// lint:off canonical-alias: <why>`.
        ,
    },

    .{
        .tag = "import-at-root",
        .title = "import-at-root - bind imports at container scope, not mid-expression",
        .body =
        \\`@import("wgpu.zig").render_pass.setScissorRect(...)` buried in a function
        \\hides a dependency from everyone who scans the top of the file, and
        \\`const dom = @import("web.zig").dom;` repeated inside fourteen functions
        \\hides it fourteen times. Bind the module once at container scope and use
        \\the name.
        \\
        \\Allowed: a binding at ANY container nesting -- a nested namespace
        \\(`pub const default_shapes = struct { pub const vs = @import("..."); };`)
        \\is deliberate API shape -- member bindings
        \\(`const truetype = @import("codecs.zig").truetype;`), and
        \\`_ = @import("x_test.zig");`, the test-aggregation idiom whose whole job
        \\is to reference a module without naming it.
        \\
        \\NO autofix on purpose: repairing one means creating a decl and choosing
        \\its name, and an auto-inserted binding can collide with an existing
        \\identifier or add a second alias to a module that already has one.
        \\
        \\Fix: add the binding (use the module's `//! lint:alias` name) and refer to
        \\it, or `// lint:off import-at-root: <why>` for a file that is all imports.
        ,
    },
    .{
        .tag = "state-uninit",
        .title = "state-uninit - an app's State must be born from a `.{...}` literal",
        .body =
        \\`var s: State = undefined` in a file that declares an `AppSpec` skips the
        \\one check that keeps app state honest: a struct literal makes the compiler
        \\demand every field (or its default, or an explicit `= undefined`), while a
        \\whole-struct `undefined` filled in piecemeal leaves any forgotten field as
        \\garbage. Only files declaring an AppSpec are checked - other modules have
        \\their own unrelated `State` types that may legitimately start undefined.
        \\
        \\Fix: `var s: State = .{ ... };`, or `// lint:off state-uninit: <why>`.
        ,
    },
    .{
        .tag = "no-qualified-zm",
        .title = "no-qualified-zm - bind zm math keywords once at file scope, use them bare",
        .body =
        \\In a file with a column-0 `const zm = @import("zm");`, a zm KEYWORD (the
        \\curated core vocabulary: length, dot, cross, clamp, vec, ...) is used bare
        \\through a file-scope binding - `const length = zm.length;` then
        \\`length(v)` - never qualified as `zm.length(v)`: not in a body, not in a
        \\signature, not in a field type (one way, Oct 2). Math reads
        \\like math, and the binding block at the top of the file is the list of
        \\what the file uses. Non-keyword zm helpers may stay qualified.
        \\
        \\`--fix` drops the `zm.` when the binding already exists. Otherwise add
        \\the binding, or `// lint:off no-qualified-zm: <why>` when a local
        \\already owns the name.
        ,
    },
    .{
        .tag = "no-qualified-std",
        .title = "no-qualified-std - bind the hot std names once at file scope, use them bare",
        .body =
        \\Zig is verbose, and the std names every file reaches for are most of it:
        \\`std.testing.allocator`, `std.mem.eql`, `std.heap.ArenaAllocator`,
        \\`std.Io`. no-qualified-zm's idea applied to std: a curated VOCABULARY
        \\(`std_vocabulary`, chosen by counting zimr's own uses) is bound once at
        \\file scope - `const eql = std.mem.eql;` - and used bare. The binding block
        \\at the top of the file is the list of what the file leans on.
        \\
        \\Most entries bind to their own name; two get a clearer one:
        \\`testing_allocator` (a bare `allocator` would say nothing) and
        \\`sortSlice` (zimrnum's own `sort` sorts tensors).
        \\
        \\It stays SILENT where the bare name is already declared in the file - a
        \\local, parameter or capture of that name would not compile beside the
        \\binding, and a method of that name (legal: members are namespaced) would
        \\give one word two meanings on one page. `std.meta.eql` is left out for
        \\the same reason.
        \\
        \\It was work in progress (reporting, never failing) while zimr's 248 files were
        \\migrated, and graduated once the tree was clean. `--fix` does the whole job:
        \\a missing binding is inserted (after the header's last std alias, or right
        \\after the std import when a header line needs it), and the next pass of the
        \\fix loop rewrites every use (the whole expression, for a renamed alias).
        ,
    },
    .{
        .tag = "custom-degrad",
        .title = "custom-degrad - one spelling for degree/radian conversion",
        .body =
        \\`deg2rad`, `DEG2RAD`, `toRadians`, `degrees_to_radians` and their
        \\siblings are the same conversion under a dozen names. zimr has exactly
        \\one: `zm.radFromDeg` / `zm.degFromRad`, or the constants
        \\`zm.rad_per_deg` / `zm.deg_per_rad`. Only those exact banned names fire.
        \\
        \\Fix: call the zm helper and delete the local copy.
        ,
    },
    .{
        .tag = "no-std-timer",
        .title = "no-std-timer - std.time.Timer does not exist in the pinned std",
        .body =
        \\The pinned Zig has no `std.time.Timer` (nor `nanoTimestamp` /
        \\`milliTimestamp`), so this fails to compile with an unhelpful "struct
        \\'time' has no member" error. The rule exists to put the real answer next
        \\to the error: in an app, time things with the frame clock (`f.time` on the
        \\Frame). A native host-only tool that needs a monotonic clock opts out with
        \\`// lint:off no-std-timer: <why>`.
        ,
    },
    .{
        .tag = "debug-print",
        .title = "debug-print - no std.debug.print in code that ships as wasm",
        .body =
        \\`std.debug.print` bypasses `std_options.logFn` and writes to the raw
        \\stderr writer, whose wasm path traps under ReleaseSmall - a SILENT freeze
        \\in a release page. The sanctioned sink is `std.log.*`, which zimr routes
        \\to the browser console on wasm and to stderr on the host.
        \\
        \\Fix: `std.log.info(...)` / `.warn` / `.err`. Native host-only code opts
        \\out with `// lint:off debug-print: <why>`.
        ,
    },
    .{
        .tag = "float-from-int",
        .title = "float-from-int - `@as(f32, @floatFromInt(x))` is `zm.float(x)`",
        .body =
        \\The `@as(T, ...)` wrapper exists only to give `@floatFromInt` a result
        \\type, which the zm helpers already carry: `zm.float(x)` -> f32,
        \\`zm.float64(x)` -> f64. A bare `@floatFromInt(x)` whose type comes from
        \\context is left alone.
        \\
        \\`--fix` rewrites to `float(x)` when the file binds `const float =
        \\zm.float;`, and to `zm.float(x)` when it only imports zm.
        ,
    },
    .{
        .tag = "prefer-splat",
        .title = "prefer-splat - `@as(Vec, @splat(x))` is `splat(x)`",
        .body =
        \\`@splat` takes its type from where the value lands, and a binary operator
        \\gives it none - so `v * @splat(s)` does not compile, and the usual way out,
        \\`v * @as(Vec, @splat(s))`, spells the type to say nothing. zm's broadcast
        \\helpers carry it: `splat(s)` -> Vec, `splat3(s)` -> Vec3, `splat2(s)` ->
        \\Vec2, `splat2i(s)` -> Vec2i. The type may be qualified (`zm.Vec`,
        \\`rbt.Vec`): these names are reserved for zm's types, so any `Vec` is zm's.
        \\A `const k: Vec = @splat(s);` already has its type and is left alone, as
        \\is any other vector type (`@as(T, @splat(s))` in generic code).
        \\
        \\`--fix` rewrites to `splat(x)` when the file binds `const splat =
        \\zm.splat;` (or declares the helper itself), and to `zm.splat(x)` when it
        \\only imports zm - which `no-qualified-zm` then binds.
        ,
    },
    .{
        .tag = "shader-safe",
        .title = "shader-safe - a SHADER-SAFE file stays compilable for the GPU",
        .body =
        \\A file starting with `//! SHADER-SAFE` (and every `*_io.zig` shader
        \\interface) promises it compiles for SPIR-V. Allocators, heap containers,
        \\filesystem and runtime IO, `std.debug.print`, `extern fn` and the wasm
        \\bridge imports cannot, so they are banned outside `test` blocks - the
        \\breakage otherwise shows up only when a shader that imports the file is
        \\built.
        \\
        \\Fix: move the host-only code to a file that is not marked SHADER-SAFE.
        ,
    },
    .{
        .tag = "scope-balance",
        .title = "scope-balance - every begin{X} in a function has its end{X}",
        .body =
        \\A function that calls `beginDrawing`, `beginMode3D`, `beginChild`, ...
        \\must also call the matching `end*` - directly or through `defer`. A missing
        \\end leaves the renderer or UI in the wrong scope for the rest of the frame,
        \\which shows up as a blank or corrupted frame rather than an error.
        \\
        \\Fix: add the `end*` (a `defer z.endX();` right after the begin is the
        \\usual form). A helper that deliberately opens a scope its caller closes
        \\carries `// lint:off scope-balance: <why>`.
        ,
    },
    .{
        .tag = "screaming-const",
        .title = "screaming-const - value consts are snake_case, at every depth",
        .body =
        \\Zig's style: types are PascalCase, values are snake_case. An all-caps
        \\`MAX_ITEMS` is the C-macro spelling and reads as foreign next to every
        \\other name - at file scope, inside a namespace struct, or in a function.
        \\Only values are judged: a declaration naming its type (other than `type`),
        \\or holding a literal. A short type alias such as `V4` or `H2` is PascalCase;
        \\a single capital (`N`, `K`, `F0`) is a mathematical symbol, left as written.
        \\
        \\Fix: `max_items`, or `// lint:off screaming-const: <why>` for a name
        \\mirrored from an external spec.
        ,
    },
    .{
        .tag = "shader-missing-entry",
        .title = "shader-missing-entry - a shader body must bind its SPIR-V entry",
        .body =
        \\A `_fs.zig` / `_vs.zig` body that imports its generated `*_externs` module
        \\and defines `shaderMain` must call `installSpirvEntry(shaderMain)`.
        \\Without it the file compiles clean and passes the headless smoke:
        \\`shaderMain` is unreferenced, the SPIR-V backend strips it, and the WGSL
        \\comes out empty - which fails only on a real GPU, as "entryPoint doesn't
        \\exist". The lint gate is the last place to catch it before hardware.
        ,
    },
    .{
        .tag = "unknown-lint-tag",
        .title = "unknown-lint-tag - a `lint:off` names a rule that does not exist",
        .body =
        \\A `// lint:off <tag>` or `//! lint:off <tag>` whose tag is not a rule
        \\silences nothing: it is a typo that fails silently, or a leftover from a
        \\rule that was renamed or deleted. Either way the comment lies about the
        \\code next to it.
        \\
        \\Fix: correct the tag (the rule list is the `rule_notes` table in
        \\tools/zimrlint.zig), or delete the stale directive.
        ,
    },
    .{
        .tag = "arch-check",
        .title = "arch-check - ask the host's facts, not the processor",
        .body =
        \\Engine code (src/) that asks `builtin.cpu.arch.isWasm()`, or compares the
        \\architecture with `.wasm32`, almost always means a fact about where it runs:
        \\is this the browser, is there a GPU, a window, does the program call its own
        \\frames. `host.zig` states those facts - `host.is_browser`, `host.has_gpu`,
        \\`host.has_window`, `host.drives_own_frames` - and they stay right when a
        \\build targets a new host. Only code that depends on wasm itself - its
        \\allocator, its linear memory, its lack of libc - asks the processor.
        \\
        \\Fix: ask the host (`host.is_browser`, ...). Code that truly depends on wasm
        \\opts out with `// lint:off arch-check: <why>`; a site waiting for its native
        \\equivalent names its step there, so the directive marks the work left; a file
        \\that is the browser's own opts out whole, with `//! lint:off arch-check`.
        ,
    },
    .{
        .tag = "browser-call",
        .title = "browser-call - reach the browser through the platform contract",
        .body =
        \\`web.zig` is the browser's own module: what it calls exists in the browser
        \\alone. Engine code importing it outside the browser's platform layer
        \\(`web.zig`, `bridge.zig`, `platform/web.zig`) does something only the
        \\browser will ever do - where the platform contract (`platform.current`)
        \\would carry the request out on every platform.
        \\
        \\Fix: call the contract's request. Where the contract has none yet, the
        \\directive `// lint:off browser-call: <why>` names the step that adds it; what
        \\only a browser can do says so.
        ,
    },
    .{
        .tag = "own-clock",
        .title = "own-clock - read the platform's clock, not the system's",
        .body =
        \\Every platform implements one monotonic clock, `platform.current.now()` - the
        \\browser's `performance.now()`, Windows' performance counter, the monotonic
        \\clock elsewhere - and a frame's time comes with the frame (`f.time`), from
        \\whatever drives frames. Engine code reading a system clock itself
        \\(`clock_gettime`, `QueryPerformanceCounter`, `Io.Timestamp.now`, ...) keeps
        \\a clock of its own: one more to port to each platform, and one a headless
        \\run cannot give a frame's time.
        \\
        \\Fix: `platform.current.now()`, or `f.time`. The platform layer is where
        \\clocks are read (`src/platform/`, `native_os.zig`, `win32.zig`); code that
        \\needs the wall clock for itself - a certificate's validity - opts out with
        \\`// lint:off own-clock: <why>`.
        ,
    },
    .{
        .tag = "process-exit",
        .title = "process-exit - only a program's entry point exits",
        .body =
        \\`std.process.exit` ends the program from wherever it is called, skipping
        \\every `defer` on the way out: the Vulkan host's shutdown and its validation
        \\report, a file half written, a session's last replies. Engine code returns
        \\what went wrong, as an error or an outcome, up to the program's entry
        \\point, which alone decides the exit status.
        \\
        \\Fix: return an error or an outcome. The entry point's own exit opts out with
        \\`// lint:off process-exit: <why>`.
        ,
    },
};

/// Whether `tag` names a rule still in progress (see `RuleNote.work_in_progress`).
fn isWorkInProgressTag(tag: []const u8) bool {
    return isWorkInProgressIn(&rule_notes, tag);
}

/// `failingCount` against any table of rules.
fn failingCountIn(notes: []const RuleNote, issues: []const Issue) usize {
    var failing: usize = 0;
    for (issues) |issue| {
        if (!isWorkInProgressIn(notes, issue.tag)) {
            failing += 1;
        }
    }
    return failing;
}

/// How many of `issues` FAIL the run - every one but the reports of rules still in progress.
fn failingCount(issues: []const Issue) usize {
    return failingCountIn(&rule_notes, issues);
}

fn lookupRuleNote(tag: []const u8) ?RuleNote {
    for (rule_notes) |note| {
        if (eql(u8, note.tag, tag)) {
            return note;
        }
    }
    return null;
}

/// Index of `tag` in `rule_notes`, or null for a string that is not a rule.
fn ruleIndex(tag: []const u8) ?usize {
    for (rule_notes, 0..) |note, i| {
        if (eql(u8, note.tag, tag)) {
            return i;
        }
    }
    return null;
}

/// Which rules this run enables, indexed like `rule_notes` - every rule is opt-in.
const EnabledRules = [rule_notes.len]bool;

/// Whether issues tagged `tag` are reported in this run: only when `--enable` named the rule. An emitted tag with no
/// `rule_notes` entry is a linter bug, and is reported loudly rather than
/// silently kept or dropped.
fn ruleEnabled(enabled: *const EnabledRules, tag: []const u8) bool {
    const i: usize = ruleIndex(tag) orelse std.debug.panic(
        "zimrlint bug: a check emitted '{s}', which has no rule_notes entry",
        .{tag},
    );
    return enabled[i];
}

/// PascalCase with >=1 lowercase letter, OR single uppercase letter.
/// Filters out ALL_CAPS_CONSTANTS (e.g. `MAX_BUFFER`).
fn isTypeNamedIdentifier(name: []const u8) bool {
    if (name.len == 0) {
        return false;
    }
    if (name[0] < 'A' or name[0] > 'Z') {
        return false;
    }
    if (name.len == 1) { // generic-param convention (e.g. `T`)
        return true;
    }
    // require at least one lowercase after the first uppercase
    for (name[1..]) |c| {
        if (c >= 'a' and c <= 'z') {
            return true;
        }
    }
    return false;
}

/// Best-effort enumeration of an AST node's direct child node
/// indices.  Doesn't have to be exhaustive - type-signal
/// detection only needs to descend through wrappers like `try`,
/// `&`, `.?`, `.*`, function-call args, etc.  Missing a child
/// means a false negative (we don't see a type signal that's
/// there), which is the conservative direction.
fn childNodes(
    ast: *const Ast,
    node: Index,
    buf: *[8]Index,
) []const Index {
    const data: Ast.Node.Data = ast.nodeData(node);
    const tag: Ast.Node.Tag = ast.nodeTag(node);
    switch (tag) {
        // Tags whose data is a single Index.
        .@"try",
        .@"comptime",
        .@"nosuspend",
        .address_of,
        .deref,
        .negation,
        .negation_wrap,
        .bit_not,
        .bool_not,
        => {
            buf[0] = data.node;
            return buf[0..1];
        },
        // Tags whose data is node_and_token - we want the node side.
        .field_access,
        .unwrap_optional,
        .grouped_expression,
        => {
            buf[0] = data.node_and_token[0];
            return buf[0..1];
        },
        // Binary expressions.
        .add,
        .sub,
        .mul,
        .div,
        .mod,
        .shl,
        .shr,
        .bool_and,
        .bool_or,
        .bit_and,
        .bit_or,
        .bit_xor,
        .equal_equal,
        .bang_equal,
        .less_than,
        .greater_than,
        .less_or_equal,
        .greater_or_equal,
        .merge_error_sets,
        .array_cat,
        .add_wrap,
        .sub_wrap,
        .mul_wrap,
        .add_sat,
        .sub_sat,
        .mul_sat,
        .shl_sat,
        .@"orelse",
        .@"catch",
        // -- ASSIGNMENTS. Their absence here was a silent hole in EVERY rule --
        //
        // `childNodes` ends in `else => return buf[0..0]`, so an unhandled tag reports no
        // children and its whole subtree goes unvisited by every check in this file. `.assign`
        // was unhandled, which meant `o = std.math.clamp(x, 0, 1);` was invisible to `std-math`
        // - a rule that documents itself as having no opt-out, guarding GPU portability. It was
        // found by grepping the tree for violations the linter reported zero of, and it had been
        // hiding real ones: `src/zimrphysics.zig` calls `std.math.sign` three times, all on the
        // right of an assignment.
        //
        // Compound assignments are included for the same reason - `x += std.math.pi` is no more
        // visible than `x = std.math.pi` was.
        .assign,
        .assign_add,
        .assign_add_sat,
        .assign_add_wrap,
        .assign_bit_and,
        .assign_bit_or,
        .assign_bit_xor,
        .assign_div,
        .assign_mod,
        .assign_mul,
        .assign_mul_sat,
        .assign_mul_wrap,
        .assign_shl,
        .assign_shl_sat,
        .assign_shr,
        .assign_sub,
        .assign_sub_sat,
        .assign_sub_wrap,
        => {
            const lhs, const rhs = data.node_and_node;
            buf[0] = lhs;
            buf[1] = rhs;
            return buf[0..2];
        },
        // Function call (full form).
        .call, .call_comma => {
            const fn_expr, const extra_index = data.node_and_extra;
            const range = ast.extraData(extra_index, Ast.Node.SubRange);
            const start: u32 = @backingInt(range.start);
            const end: u32 = @backingInt(range.end);
            buf[0] = fn_expr;
            if (end <= start) {
                return buf[0..1];
            }
            const args = ast.extraDataSlice(range, Index);
            const max_args: usize = 7;
            const arg_count: usize = if (args.len > max_args) max_args else args.len;
            for (args[0..arg_count], 0..) |a, i| {
                buf[i + 1] = a;
            }
            return buf[0 .. arg_count + 1];
        },
        // Call with up to one arg.
        .call_one, .call_one_comma => {
            const fn_expr, const arg_opt = data.node_and_opt_node;
            buf[0] = fn_expr;
            if (arg_opt.unwrap()) |a| {
                buf[1] = a;
                return buf[0..2];
            }
            return buf[0..1];
        },
        // Builtin call full.
        .builtin_call, .builtin_call_comma => {
            const args = ast.extraDataSlice(data.extra_range, Index);
            const n: usize = @min(args.len, 8);
            for (args[0..n], 0..) |a, i| {
                buf[i] = a;
            }
            return buf[0..n];
        },
        // Builtin call up-to-2.
        .builtin_call_two, .builtin_call_two_comma => {
            const a, const b = data.opt_node_and_opt_node;
            var n: usize = 0;
            if (a.unwrap()) |x| {
                buf[n] = x;
                n += 1;
            }
            if (b.unwrap()) |x| {
                buf[n] = x;
                n += 1;
            }
            return buf[0..n];
        },
        // Anonymous struct / array literals with up to 2 elements - `.{a, b}`,
        // `.{ .x = a }`, the common format-tuple shape `.{@as(...)}`. Descend
        // into the element value expressions.
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        => {
            const a, const b = data.opt_node_and_opt_node;
            var n: usize = 0;
            if (a.unwrap()) |x| {
                buf[n] = x;
                n += 1;
            }
            if (b.unwrap()) |x| {
                buf[n] = x;
                n += 1;
            }
            return buf[0..n];
        },
        // Optional: walk error-set type's lhs (the success type
        // of the union) - not strictly needed since the tag
        // .error_union itself is a type signal, but harmless.
        // `return X;` - walk the operand so node-checks (std-math,
        // clamp-pattern, as-round, ...) fire inside return expressions too.
        // `return;` (void) has no operand.  Was a blind spot: `std-math`
        // missed `return std.math.clamp(...)` in image.zig.
        .@"return" => {
            if (data.opt_node.unwrap()) |operand| {
                buf[0] = operand;
                return buf[0..1];
            }
            return buf[0..0];
        },
        // -- TYPE EXPRESSIONS: the same silent hole as `.assign` --
        //
        // A pointer, optional or array type was an unhandled tag, so its element type went
        // unvisited by every check: `[4]@Vector(4, f32)` hid its vector from `prefer-vec` in
        // twenty shader-IO and example fields, `*const fn (a, b, c) void` hid its parameter list
        // from `fn-args-multiline`, and `*std.Io.Writer` hid its `std.Io` from
        // `no-qualified-std`. Found when that rule saw `gpa: std.mem.Allocator` and not the
        // pointer beside it.
        .optional_type => {
            buf[0] = data.node;
            return buf[0..1];
        },
        .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => {
            const pointer: Ast.full.PtrType = ast.fullPtrType(node).?;
            var child_count: usize = 0;
            buf[child_count] = pointer.ast.child_type;
            child_count += 1;
            if (pointer.ast.sentinel.unwrap()) |sentinel| {
                buf[child_count] = sentinel;
                child_count += 1;
            }
            if (pointer.ast.align_node.unwrap()) |alignment| {
                buf[child_count] = alignment;
                child_count += 1;
            }
            return buf[0..child_count];
        },
        .array_type, .array_type_sentinel => {
            const array: Ast.full.ArrayType = ast.fullArrayType(node).?;
            var child_count: usize = 0;
            buf[child_count] = array.ast.elem_count;
            child_count += 1;
            buf[child_count] = array.ast.elem_type;
            child_count += 1;
            if (array.ast.sentinel.unwrap()) |sentinel| {
                buf[child_count] = sentinel;
                child_count += 1;
            }
            return buf[0..child_count];
        },
        else => return buf[0..0],
    }
}

/// Where `allChildren` keeps the children it cannot point into the AST for: the irregular ones (a condition, a
/// callee, a type expression...) and the one- or two-node buffers std's `full*` helpers fill for their short forms.
const ChildBuffer = struct {
    fixed: [8]Index = undefined,
    helper: [2]Index = undefined,
};

/// A node's children in two runs: `fixed`, the irregular children, then `list`, the list-shaped run - arguments,
/// statements, members, elements, prongs, inputs, parameters - straight from the AST or from a helper's buffer.
const ChildIterator = struct {
    fixed: []const Index,
    list: []const Index = &.{},
    next_index: usize = 0,

    fn next(self: *ChildIterator) ?Index {
        if (self.next_index < self.fixed.len) {
            self.next_index += 1;
            return self.fixed[self.next_index - 1];
        }
        const list_index: usize = self.next_index - self.fixed.len;
        if (list_index < self.list.len) {
            self.next_index += 1;
            return self.list[list_index];
        }
        return null;
    }
};

/// Fills `ChildBuffer.fixed`: present children only.
const FixedChildren = struct {
    buffer: *[8]Index,
    count: usize = 0,

    fn add(self: *FixedChildren, child: Index) void {
        self.buffer[self.count] = child;
        self.count += 1;
    }

    fn addOptional(self: *FixedChildren, child: Ast.Node.OptionalIndex) void {
        if (child.unwrap()) |present| {
            self.add(present);
        }
    }

    fn done(self: FixedChildren, list: []const Index) ChildIterator {
        return .{ .fixed = self.buffer[0..self.count], .list = list };
    }
};

/// EVERY child node of `node` - no exceptions, so a walk built on it cannot be blind anywhere. An EXHAUSTIVE switch
/// over `Ast.Node.Tag` with NO `else` arm: a tag a future Zig adds is a compile error here, not a silent hole (the
/// holes `childNodes` collected, one per incident, are the reason this exists). Composite shapes go through std's
/// `full*` helpers, which decode every variant of a family; simple shapes read their node data directly.
fn allChildren(ast: *const Ast, node: Index, buffer: *ChildBuffer) ChildIterator {
    var fixed: FixedChildren = .{ .buffer = &buffer.fixed };
    const data: Ast.Node.Data = ast.nodeData(node);
    switch (ast.nodeTag(node)) {
        .root => return fixed.done(ast.rootDecls()),
        // Nothing below a leaf: literals, identifiers, error sets and multiline strings are tokens.
        .anyframe_literal,
        .char_literal,
        .number_literal,
        .unreachable_literal,
        .identifier,
        .enum_literal,
        .string_literal,
        .error_value,
        .multiline_string_literal,
        .error_set_decl,
        => return fixed.done(&.{}),
        // One operand.
        .bool_not,
        .negation,
        .bit_not,
        .negation_wrap,
        .address_of,
        .@"try",
        .optional_type,
        .deref,
        .@"suspend",
        .@"resume",
        .@"comptime",
        .@"nosuspend",
        .@"defer",
        .@"errdefer",
        => fixed.add(data.node),
        .field_access, .unwrap_optional, .grouped_expression, .asm_input => fixed.add(data.node_and_token[0]),
        .asm_output => fixed.addOptional(data.opt_node_and_token[0]),
        .anyframe_type => fixed.add(data.token_and_node[1]),
        .@"return" => fixed.addOptional(data.opt_node),
        .@"break", .@"continue" => fixed.addOptional(data.opt_token_and_opt_node[1]),
        .test_decl => fixed.add(data.opt_token_and_node[1]),
        // Two operands: every binary operator, assignment, comparison, `catch`, `orelse`, `a[i]`, `a!b`, `[n]T`.
        .@"catch",
        .@"orelse",
        .equal_equal,
        .bang_equal,
        .less_than,
        .greater_than,
        .less_or_equal,
        .greater_or_equal,
        .assign,
        .assign_mul,
        .assign_div,
        .assign_mod,
        .assign_add,
        .assign_sub,
        .assign_shl,
        .assign_shl_sat,
        .assign_shr,
        .assign_bit_and,
        .assign_bit_xor,
        .assign_bit_or,
        .assign_mul_wrap,
        .assign_add_wrap,
        .assign_sub_wrap,
        .assign_mul_sat,
        .assign_add_sat,
        .assign_sub_sat,
        .merge_error_sets,
        .mul,
        .div,
        .mod,
        .mul_wrap,
        .mul_sat,
        .add,
        .sub,
        .array_cat,
        .add_wrap,
        .sub_wrap,
        .add_sat,
        .sub_sat,
        .shl,
        .shl_sat,
        .shr,
        .bit_and,
        .bit_xor,
        .bit_or,
        .bool_and,
        .bool_or,
        .array_access,
        .error_union,
        .switch_range,
        .fn_decl,
        => {
            const left: Index, const right: Index = data.node_and_node;
            fixed.add(left);
            fixed.add(right);
        },
        .for_range => {
            const start: Index, const end: Ast.Node.OptionalIndex = data.node_and_opt_node;
            fixed.add(start);
            fixed.addOptional(end);
        },
        .simple_var_decl, .local_var_decl, .global_var_decl, .aligned_var_decl => {
            const declaration: Ast.full.VarDecl = ast.fullVarDecl(node).?;
            fixed.addOptional(declaration.ast.type_node);
            fixed.addOptional(declaration.ast.align_node);
            fixed.addOptional(declaration.ast.addrspace_node);
            fixed.addOptional(declaration.ast.section_node);
            fixed.addOptional(declaration.ast.init_node);
        },
        .assign_destructure => {
            const destructure: Ast.full.AssignDestructure = ast.assignDestructure(node);
            fixed.add(destructure.ast.value_expr);
            return fixed.done(destructure.ast.variables);
        },
        .container_field_init, .container_field_align, .container_field => {
            const field: Ast.full.ContainerField = ast.fullContainerField(node).?;
            fixed.addOptional(field.ast.type_expr);
            fixed.addOptional(field.ast.align_expr);
            fixed.addOptional(field.ast.value_expr);
        },
        .fn_proto_simple, .fn_proto_multi, .fn_proto_one, .fn_proto => {
            var param_buffer: [1]Index = undefined;
            const proto: Ast.full.FnProto = ast.fullFnProto(&param_buffer, node).?;
            fixed.addOptional(proto.ast.return_type);
            fixed.addOptional(proto.ast.align_expr);
            fixed.addOptional(proto.ast.addrspace_expr);
            fixed.addOptional(proto.ast.section_expr);
            fixed.addOptional(proto.ast.callconv_expr);
            // A one-parameter form keeps its parameter in the helper's buffer: copy it into ours.
            if (proto.ast.params.len == 1 and proto.ast.params.ptr == &param_buffer) {
                buffer.helper[0] = param_buffer[0];
                return fixed.done(buffer.helper[0..1]);
            }
            return fixed.done(proto.ast.params);
        },
        .if_simple, .@"if" => {
            const branch: Ast.full.If = ast.fullIf(node).?;
            fixed.add(branch.ast.cond_expr);
            fixed.add(branch.ast.then_expr);
            fixed.addOptional(branch.ast.else_expr);
        },
        .while_simple, .while_cont, .@"while" => {
            const loop: Ast.full.While = ast.fullWhile(node).?;
            fixed.add(loop.ast.cond_expr);
            fixed.addOptional(loop.ast.cont_expr);
            fixed.add(loop.ast.then_expr);
            fixed.addOptional(loop.ast.else_expr);
        },
        .for_simple, .@"for" => {
            const loop: Ast.full.For = ast.fullFor(node).?;
            fixed.add(loop.ast.then_expr);
            fixed.addOptional(loop.ast.else_expr);
            return fixed.done(loop.ast.inputs);
        },
        .@"switch", .switch_comma => {
            const choice: Ast.full.Switch = ast.fullSwitch(node).?;
            fixed.add(choice.ast.condition);
            return fixed.done(choice.ast.cases);
        },
        .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline => {
            const prong: Ast.full.SwitchCase = ast.fullSwitchCase(node).?;
            fixed.add(prong.ast.target_expr);
            return fixed.done(prong.ast.values);
        },
        .call_one, .call_one_comma, .call, .call_comma => {
            const call: Ast.full.Call = ast.fullCall(buffer.helper[0..1], node).?;
            fixed.add(call.ast.fn_expr);
            return fixed.done(call.ast.params);
        },
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            return fixed.done(ast.builtinCallParams(&buffer.helper, node).?);
        },
        .block_two, .block_two_semicolon, .block, .block_semicolon => {
            return fixed.done(ast.blockStatements(&buffer.helper, node).?);
        },
        .struct_init_one,
        .struct_init_one_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init,
        .struct_init_comma,
        => {
            const literal: Ast.full.StructInit = ast.fullStructInit(&buffer.helper, node).?;
            fixed.addOptional(literal.ast.type_expr);
            return fixed.done(literal.ast.fields);
        },
        .array_init_one,
        .array_init_one_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init,
        .array_init_comma,
        => {
            const literal: Ast.full.ArrayInit = ast.fullArrayInit(&buffer.helper, node).?;
            fixed.addOptional(literal.ast.type_expr);
            return fixed.done(literal.ast.elements);
        },
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => {
            const container: Ast.full.ContainerDecl = ast.fullContainerDecl(&buffer.helper, node).?;
            fixed.addOptional(container.ast.arg);
            return fixed.done(container.ast.members);
        },
        .array_type, .array_type_sentinel => {
            const array: Ast.full.ArrayType = ast.fullArrayType(node).?;
            fixed.add(array.ast.elem_count);
            fixed.addOptional(array.ast.sentinel);
            fixed.add(array.ast.elem_type);
        },
        .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => {
            const pointer: Ast.full.PtrType = ast.fullPtrType(node).?;
            fixed.addOptional(pointer.ast.align_node);
            fixed.addOptional(pointer.ast.addrspace_node);
            fixed.addOptional(pointer.ast.sentinel);
            fixed.addOptional(pointer.ast.bit_range_start);
            fixed.addOptional(pointer.ast.bit_range_end);
            fixed.add(pointer.ast.child_type);
        },
        .slice_open, .slice, .slice_sentinel => {
            const slice: Ast.full.Slice = ast.fullSlice(node).?;
            fixed.add(slice.ast.sliced);
            fixed.add(slice.ast.start);
            fixed.addOptional(slice.ast.end);
            fixed.addOptional(slice.ast.sentinel);
        },
        .asm_simple, .@"asm" => {
            const assembly: Ast.full.Asm = ast.fullAsm(node).?;
            fixed.add(assembly.ast.template);
            fixed.addOptional(assembly.ast.clobbers);
            return fixed.done(assembly.ast.items);
        },
    }
    return fixed.done(&.{});
}

fn hasTypeSignalImpl(
    ast: *const Ast,
    node: Index,
    depth: u8,
) bool {
    if (depth > 32) { // sanity guard against pathological nesting
        return false;
    }
    const tag: Ast.Node.Tag = ast.nodeTag(node);
    switch (tag) {
        // Identifier - check name against primitives + PascalCase heuristic.
        .identifier => {
            const main_tok: u32 = ast.nodeMainToken(node);
            const name: []const u8 = ast.tokenSlice(main_tok);
            if (primitives.has(name)) {
                return true;
            }
            if (c_types.has(name)) { // c_* names still read as type mentions
                return true;
            }
            // `float`/`float64` are the zm int->f32/f64 helpers (return type is
            // pinned), so `const d = float(i) * k;` is as self-documenting as a
            // `: f32` would be. Reached here as a call's fn_expr via childNodes
            // recursion, so it fires for any init that calls one anywhere.
            if (eql(u8, name, "float") or eql(u8, name, "float64")) {
                return true;
            }
            if (isTypeNamedIdentifier(name)) {
                return true;
            }
            return false;
        },

        // Builtins that explicitly name a type.
        .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {
            const main_tok: u32 = ast.nodeMainToken(node);
            const name: []const u8 = ast.tokenSlice(main_tok);
            if (eql(u8, name, "@as")) {
                return true;
            }
            if (eql(u8, name, "@TypeOf")) {
                return true;
            }
            if (eql(u8, name, "@Type")) {
                return true;
            }
            // `@import("foo")` / `@cImport({...})` yield a `type` value -
            // a namespace.  Conventionally used as `const std = @import("std")`;
            // forcing a `: type` annotation everywhere would be noise.
            if (eql(u8, name, "@import")) {
                return true;
            }
            if (eql(u8, name, "@cImport")) {
                return true;
            }
            // Other builtins - fall through to recurse on args.
        },

        // Explicit-typed struct literal (not the `.{...}` anon form).
        .struct_init,
        .struct_init_comma,
        .struct_init_one,
        .struct_init_one_comma,
        => return true,

        // Typed array literal: `[N]T{...}` or `[_]T{...}` - the type
        // prefix names the element type, making the local self-
        // documenting.  Excludes `.array_init_dot*` which is the
        // anonymous `.{...}` form with no type prefix.
        .array_init,
        .array_init_comma,
        .array_init_one,
        .array_init_one_comma,
        => return true,

        // Pointer/array/optional/error-union type expressions are types themselves.
        .ptr_type,
        .ptr_type_aligned,
        .ptr_type_bit_range,
        .ptr_type_sentinel,
        .array_type,
        .array_type_sentinel,
        .optional_type,
        .error_union,
        => return true,

        // Container literal at expr position - `error{...}`, `struct{...}` literal.
        .container_decl,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .error_set_decl,
        => return true,

        else => {},
    }

    // Recurse into children.  Use a generic helper that walks
    // the immediate sub-nodes regardless of tag.
    var buf: [8]Index = undefined;
    const children: []const Index = childNodes(ast, node, &buf);
    for (children) |c| {
        if (hasTypeSignalImpl(ast, c, depth + 1)) {
            return true;
        }
    }
    return false;
}

/// Walk an init expression looking for type-naming constructs.
/// Returns true if any sub-node is a type signal.
fn hasTypeSignal(ast: *const Ast, node: Index) bool {
    return hasTypeSignalImpl(ast, node, 0);
}

// An *alias* is a `const NAME = <reference path>;` whose entire init is a bare
// identifier or a field-access chain (`zm.Vec2`, `foo.bar.Baz`). These re-bind
// an existing decl rather than computing a value, so the untyped-local rule does
// not apply - a `:type` annotation on `const Vec2 = zm.Vec2;` would be noise.
// (Aliases should live at file scope; this only matters for transitional locals.)
fn isAliasInit(ast: *const Ast, node: Index) bool {
    return switch (ast.nodeTag(node)) {
        .identifier, .field_access => true,
        else => false,
    };
}

// ============================================================================
// Walker - depth-first AST traversal that runs checks at each node.
// ============================================================================

// We walk the AST once, calling each check at every node.  The
// walker tracks two pieces of context:
//   pos - `.container` means we're at module scope or inside a
//         struct/union/enum decl that's itself at module scope.
//         `.statement` means we're inside a function/test body
//         block.  Most checks only care about which of these
//         we're in (module-var is container-only; branch-braces
//         is statement-only; untyped-local is statement-only).
//   fn_depth - how many `fn`/`test` bodies we're nested inside.
//         The module-var check only fires at fn_depth == 0.
//         A `var` inside a function-local struct (the Zig idiom
//         for one-shot warning flags scoped to one function) is
//         technically at "container position" but logically a
//         function-local static - the user said to allow these
//        .

const Pos = enum {
    /// At module scope or inside a top-level container decl.
    container,
    /// Inside a function/test body block.  Branch-braces fires
    /// only here - `if (x) y;` in statement position needs
    /// braces because the user wants a breakpoint on the body.
    statement,
    /// Inside an expression (init of a var_decl, argument to a
    /// call, etc).  Branch-braces stays silent here since the
    /// `if/while/for` is being used as a value, not as
    /// control-flow you'd want to step through.
    expression,
};

fn castHelperName(ast: *const Ast, node: Index) ?[]const u8 {
    const fn_expr: Index = switch (ast.nodeTag(node)) {
        .call, .call_comma => ast.nodeData(node).node_and_extra[0],
        .call_one, .call_one_comma => ast.nodeData(node).node_and_opt_node[0],
        else => return null,
    };
    const name_tok: u32 = switch (ast.nodeTag(fn_expr)) {
        .field_access => ast.nodeData(fn_expr).node_and_token[1], // `int` in zm.int
        .identifier => ast.nodeMainToken(fn_expr), // bare int(...) inside zimrmath
        else => return null,
    };
    const nm: []const u8 = ast.tokenSlice(name_tok);
    if (eql(u8, nm, "int") or eql(u8, nm, "floori") or
        eql(u8, nm, "roundi") or eql(u8, nm, "ceili"))
    {
        return nm;
    }
    return null;
}

/// Descend through transparent expression wrappers and emit at any
/// typed struct_init leaf reached.  "Transparent" here means
/// wrappers that don't change the type of the value flowing through:
/// try/comptime/nosuspend pass-through, orelse/catch/if-else
/// branch the same type, parens are invisible.
fn walkInitForNamedStruct(ctx: Ctx, node: Index) anyerror!void {
    const ast: *const Ast = ctx.ast;
    const tag: Ast.Node.Tag = ast.nodeTag(node);

    switch (tag) {
        // Transparent unary wrappers - descend.
        .@"try", .@"comptime", .@"nosuspend" => {
            const inner: Index = ast.nodeData(node).node;
            try walkInitForNamedStruct(ctx, inner);
        },
        // Binary branchers - both arms could carry the value.
        .@"orelse", .@"catch" => {
            const l, const r = ast.nodeData(node).node_and_node;
            try walkInitForNamedStruct(ctx, l);
            try walkInitForNamedStruct(ctx, r);
        },
        .if_simple => {
            _, const then_e = ast.nodeData(node).node_and_node;
            try walkInitForNamedStruct(ctx, then_e);
        },
        .@"if" => {
            const if_full: Ast.full.If = ast.fullIf(node).?;
            try walkInitForNamedStruct(ctx, if_full.ast.then_expr);
            if (if_full.ast.else_expr.unwrap()) |e| {
                try walkInitForNamedStruct(ctx, e);
            }
        },
        .grouped_expression => {
            const inner, _ = ast.nodeData(node).node_and_token;
            try walkInitForNamedStruct(ctx, inner);
        },

        // The rule fire: typed struct literal `Name{ ... }`.
        // Skip the `_dot_` variants - those are already anonymous.
        .struct_init,
        .struct_init_comma,
        .struct_init_one,
        .struct_init_one_comma,
        => {
            const main_tok: u32 = ast.nodeMainToken(node);
            // The type-name token sits immediately before the '{'
            // main token.
            if (main_tok == 0) {
                return;
            }
            const type_tok: u32 = main_tok - 1;
            const type_name: []const u8 = ast.tokenSlice(type_tok);
            // Delete the WHOLE type expression (its first token through the
            // byte before `{`) and replace with `.` - correct for qualified
            // types like `foo.Bar{...}`, not just single-token names.
            const fix: Fix = .{
                .start = @intCast(ast.tokenStart(ast.firstToken(node))),
                .end = @intCast(ast.tokenStart(main_tok)),
                .replacement = ".",
            };
            try ctx.emitFix(
                type_tok,
                "named-struct-init",
                15,
                fix,
                "use '.{{...}}' instead of '{s}{{...}}'; LHS already declares type",
                .{type_name},
            );
        },

        // Everything else: opaque expression, stop here.
        else => {},
    }
}

/// Rule 15: prefer `.{...}` over `Bar{...}` when LHS has explicit
/// type annotation.  Walks the init through transparent wrappers
/// looking for a typed struct literal.  Does NOT descend into struct
/// fields (nested `Foo{ .bar = Bar{...} }` only flags the outer Foo;
/// the inner Bar may genuinely need the name when the field type
/// isn't pinned).
fn checkNamedStructInit(ctx: Ctx, vd: Ast.full.VarDecl) !void {
    if (vd.ast.type_node == .none) {
        return;
    }
    const init_node: Index = vd.ast.init_node.unwrap() orelse return;
    try walkInitForNamedStruct(ctx, init_node);
}

/// Whether two expressions are spelled with the same tokens, one for one - whitespace and comments aside. For two
/// expressions in one scope, that makes them the same expression.
fn spelledAlike(ast: *const Ast, first: Index, second: Index) bool {
    const first_start: u32 = ast.firstToken(first);
    const first_end: u32 = ast.lastToken(first);
    const second_start: u32 = ast.firstToken(second);
    const second_end: u32 = ast.lastToken(second);
    if (first_end - first_start != second_end - second_start) {
        return false;
    }
    var offset: u32 = 0;
    while (offset <= first_end - first_start) : (offset += 1) {
        if (!eql(u8, ast.tokenSlice(first_start + offset), ast.tokenSlice(second_start + offset))) {
            return false;
        }
    }
    return true;
}

/// prefer-decl-literal: a declaration that names its type and then calls a function OF that type to make
/// its value - `const grid: Tensor(T) = try Tensor(T).alloc(gpa, shape);` - says the type twice. Zig's DECL LITERAL
/// says it once: where the result type is known, `.name` is looked up IN that type, so `try .alloc(gpa, shape)` is
/// the very same call. `named-struct-init`'s twin for calls (`Foo{...}` there, `Foo.make(...)` here).
///
/// Unlike an anonymous struct literal, which coerces to whatever type receives it, a decl literal SEARCHES the
/// declared type - so this fires only where the two spellings are the same call by construction:
///   * the declaration has a type annotation and an initializer;
///   * the initializer IS the call, or `try` of it - a call under `catch`, `orelse`, a field access or parentheses
///     is another expression, and is left alone;
///   * the callee is `Receiver.name`, and the receiver is spelled with exactly the annotation's tokens: the same
///     expression in the same scope, so the same type. `const b: Base = Other.make();` must never become `.make()`,
///     which would look `make` up in `Base` instead.
/// The fix deletes the receiver, keeping the `.` and everything after it.
fn checkPreferDeclLiteral(ctx: Ctx, vd: Ast.full.VarDecl) !void {
    const ast: *const Ast = ctx.ast;
    const type_node: Index = vd.ast.type_node.unwrap() orelse return;
    const init_node: Index = vd.ast.init_node.unwrap() orelse return;
    // One `try` is transparent: the call's result type is then the declaration's, wrapped in an error union.
    const call_node: Index = if (ast.nodeTag(init_node) == .@"try") ast.nodeData(init_node).node else init_node;
    const callee: Index = switch (ast.nodeTag(call_node)) {
        .call, .call_comma => ast.nodeData(call_node).node_and_extra[0],
        .call_one, .call_one_comma => ast.nodeData(call_node).node_and_opt_node[0],
        else => return,
    };
    if (ast.nodeTag(callee) != .field_access) {
        return;
    }
    const receiver: Index, const name_token: u32 = ast.nodeData(callee).node_and_token;
    if (!spelledAlike(ast, receiver, type_node)) {
        return;
    }
    // Delete from the receiver's first token up to the `.` before the name (a field access's main token), whatever
    // whitespace sits between: `Tensor(T).alloc(` becomes `.alloc(`.
    const receiver_token: u32 = ast.firstToken(receiver);
    const dot_token: u32 = ast.nodeMainToken(callee);
    const fix: Fix = .{
        .start = @intCast(ast.tokenStart(receiver_token)),
        .end = @intCast(ast.tokenStart(dot_token)),
    };
    try ctx.emitFix(
        receiver_token,
        "prefer-decl-literal",
        0,
        fix,
        "the call repeats the declared type - write '.{s}(...)', a decl literal",
        .{ast.tokenSlice(name_token)},
    );
}

/// True when `node` is the builtin call `@import("zm")`.
fn isZmImportCall(ast: *const Ast, node: Index) bool {
    const t: Ast.Node.Tag = ast.nodeTag(node);
    if (t != .builtin_call_two and t != .builtin_call_two_comma) {
        return false;
    }
    if (!eql(u8, ast.tokenSlice(ast.nodeMainToken(node)), "@import")) {
        return false;
    }
    const arg_opt, _ = ast.nodeData(node).opt_node_and_opt_node;
    const arg: Index = arg_opt.unwrap() orelse return false;
    if (ast.nodeTag(arg) != .string_literal) {
        return false;
    }
    return eql(u8, ast.tokenSlice(ast.nodeMainToken(arg)), "\"zm\"");
}

/// True when `init_node` is exactly `<alias>.<name>` for one of the file's zm
/// aliases and `<name>` equals the decl name - i.e. the canonical import
/// binding `const length = zm.length;`, which is the one allowed form.
fn isCanonicalZmBinding(ctx: Ctx, init_node: Index, name: []const u8) bool {
    const ast: *const Ast = ctx.ast;
    if (ast.nodeTag(init_node) != .field_access) {
        return false;
    }
    const data: Ast.Node.Data = ast.nodeData(init_node);
    const lhs: Index = data.node_and_token[0];
    const field_tok: u32 = data.node_and_token[1];
    if (!eql(u8, ast.tokenSlice(field_tok), name)) {
        return false;
    }
    // `<zmalias>.NAME`, where <zmalias> is a file-scope `const zm = @import("zm");`.
    if (ast.nodeTag(lhs) == .identifier) {
        const obj: []const u8 = ast.tokenSlice(ast.nodeMainToken(lhs));
        for (ctx.zm_aliases) |a| {
            if (eql(u8, obj, a)) {
                return true;
            }
        }
        return false;
    }
    // Binding-less `@import("zm").NAME` - the only file-scope alias form
    // available to files that cannot introduce a `zm` const because a
    // fn-local `const zm = @import("zm");` would illegally shadow it
    // (e.g. runtime.zig imports zm per-namespace).
    return isZmImportCall(ast, lhs);
}

/// Rule `reserved-math-names`: in a zm-importing file, a `const`/`var`/`fn`
/// decl may not use an R_core word, except the canonical `const NAME = zm.NAME;`
/// binding.  Files that don't import zm are exempt (empty `zm_aliases`).  `fn`
/// decls pass `init_node == null` (no binding form is possible).
fn checkReservedMath(ctx: Ctx, name_tok: u32, init_node: ?Index) !void {
    if (ctx.zm_aliases.len == 0) {
        return;
    }
    const name: []const u8 = ctx.ast.tokenSlice(name_tok);
    if (!keywords.has(name)) {
        return;
    }
    if (init_node) |init| {
        if (isCanonicalZmBinding(ctx, init, name)) {
            return;
        }
    }
    try ctx.emitAt(
        name_tok,
        "reserved-math-names",
        0,
        "'{s}' is a reserved math word - don't shadow zm.{s}; bind it as " ++
            "`const {s} = zm.{s};` or rename this decl",
        .{ name, name, name, name },
    );
}

/// A module-level `var` whose declared type is `App` (or a qualified `z.App`)
/// is exempt from the module-var rule: it is the sanctioned wasm app-bridge
/// handle (`pub var zimr_app: z.App = .{}`) that every own-frame example must
/// hold at module scope. Matches on the final identifier of the type node, so
/// both bare `App` and `z.App` qualify while `MyApp`/`SubApp` do not.
fn isAppTypedVar(ast: *const Ast, vd: Ast.full.VarDecl) bool {
    const type_node: Ast.Node.Index = vd.ast.type_node.unwrap() orelse return false;
    const last_tok: u32 = ast.lastToken(type_node);
    return eql(u8, ast.tokenSlice(last_tok), "App");
}

/// True when the var_decl is annotated with the example `State` type, i.e.
/// `var x: State = ...` (the type expression's last token is exactly `State`).
/// Drives the state-uninit rule below.
fn isStateTypedVar(ast: *const Ast, vd: Ast.full.VarDecl) bool {
    const type_node: Ast.Node.Index = vd.ast.type_node.unwrap() orelse return false;
    const last_tok: u32 = ast.lastToken(type_node);
    return eql(u8, ast.tokenSlice(last_tok), "State");
}

/// True when `init_node` is the bare `undefined` keyword.
fn initIsUndefined(ast: *const Ast, init_node: Ast.Node.Index) bool {
    if (ast.nodeTag(init_node) != .identifier) {
        return false;
    }
    return eql(u8, ast.tokenSlice(ast.nodeMainToken(init_node)), "undefined");
}

/// Rule 9 (module-var) and rule 2 (untyped-local) both gate on
/// where the var_decl lives in the source.  Module-var only fires
/// at module scope (fn_depth == 0).  Untyped-local fires in
/// function-body statement context.  A var declared inside a
/// function-local struct (the Zig idiom for fn-scoped one-shot
/// statics) gets neither - the user explicitly allows these (turn
/// 339) because they're fn-local-static, not a module global.
fn checkVarDecl(
    ctx: Ctx,
    vd: Ast.full.VarDecl,
    pos: Pos,
    fn_depth: u8,
) !void {
    const ast: *const Ast = ctx.ast;
    const mut_tok: u32 = vd.ast.mut_token;
    const mut_text: []const u8 = ast.tokenSlice(mut_tok);
    const is_var: bool = eql(u8, mut_text, "var");
    const name_tok: u32 = mut_tok + 1;
    const name: []const u8 = ast.tokenSlice(name_tok);

    switch (pos) {
        .container => {
            // Module-var only fires at actual module scope.
            // Inside a fn-local container (the Zig idiom for
            // function-scoped one-shot static state), a `var`
            // is fine.
            if (is_var and fn_depth == 0 and
                !isAllowlistedModuleVar(ctx.path, name) and
                !isAppTypedVar(ast, vd))
            {
                try ctx.emitAt(name_tok, "module-var", 9, "mutable module global '{s}'", .{name});
            }
        },
        .statement => {
            // Untyped-local: no `:T` annotation, and the init
            // expression doesn't mention a type anywhere.
            if (vd.ast.type_node == .none) {
                if (vd.ast.init_node.unwrap()) |init_node| {
                    if (!isAliasInit(ast, init_node) and !hasTypeSignal(ast, init_node)) {
                        try ctx.emitAt(name_tok, "untyped-local", 2, "local '{s}' lacks a type annotation", .{name});
                    }
                }
            }
        },
        .expression => {
            // Var decls don't normally appear in expression
            // position, but the parser does allow them inside
            // blocks-as-expressions.  Treat as statement.
            if (vd.ast.type_node == .none) {
                if (vd.ast.init_node.unwrap()) |init_node| {
                    if (!isAliasInit(ast, init_node) and !hasTypeSignal(ast, init_node)) {
                        try ctx.emitAt(name_tok, "untyped-local", 2, "local '{s}' lacks a type annotation", .{name});
                    }
                }
            }
        },
    }

    // Rule: redundant-cast.  `const n: T = zm.int(T2, x)` (or floori/roundi/
    // ceili) spells the target type twice - the `: T` annotation already drives
    // the rounding builtin's result type, so the bare `@trunc(x)` form suffices.
    // Only the direct-initializer case is flagged (wrapped inits keep the
    // helper, where inference may not reach).
    if (vd.ast.type_node != .none) {
        if (vd.ast.init_node.unwrap()) |init_node| {
            if (castHelperName(ast, init_node)) |hname| {
                const builtin: []const u8 = if (eql(u8, hname, "int"))
                    "@trunc"
                else if (eql(u8, hname, "floori"))
                    "@floor"
                else if (eql(u8, hname, "roundi"))
                    "@round"
                else
                    "@ceil";
                try ctx.emitAt(
                    name_tok,
                    "redundant-cast",
                    0,
                    "'{s}': the declared type already pins the result - use bare {s}(x), not the zm.{s} helper",
                    .{ name, builtin, hname },
                );
            }
        }
    }

    // Rule state-uninit: `var x: State = undefined` bypasses Zig's exhaustive
    // struct-literal check - a literal `.{...}` forces every field to be set (or
    // defaulted / explicitly `= undefined`), but starting from whole-struct
    // `undefined` and filling piecemeal leaves any forgotten field as garbage.
    // Require the State to be born from a `.{...}` literal instead. Scoped to
    // files that declare an AppSpec, where `State` is the app's state type (other
    // modules have their own unrelated `State` structs that legitimately use
    // `= undefined`). Keyed on content, not on an `examples/` path: that never
    // matched Windows' `.\examples\...` paths, and an app outside zimr's tree has
    // no `examples/` at all.
    if (ctx.declares_app and vd.ast.type_node != .none and isStateTypedVar(ast, vd)) {
        if (vd.ast.init_node.unwrap()) |init_node| {
            if (initIsUndefined(ast, init_node)) {
                try ctx.emitAt(
                    name_tok,
                    "state-uninit",
                    0,
                    "'{s}': State set to `undefined` leaves fields uninitialised - " ++
                        "assign an exhaustive `.{{...}}` literal (compiler then forces every field to be set)",
                    .{name},
                );
            }
        }
    }

    // Rule 15: named-struct-init.  When LHS has `: T` annotation and
    // RHS contains a typed struct literal `T{ ... }`, suggest the
    // anonymous form `.{ ... }`.  Walks through transparent wrappers
    // (try/orelse/catch/if-else/grouped) to find the struct literal.
    try checkNamedStructInit(ctx, vd);
    // Its twin for calls: `Foo.make(...)` under a `Foo` annotation is `.make(...)` (prefer-decl-literal).
    try checkPreferDeclLiteral(ctx, vd);

    // Rule reserved-math-names: don't shadow an R_core word (length, dot,
    // min, ...) in a zm-importing file - except `const NAME = zm.NAME;`.
    try checkReservedMath(ctx, name_tok, vd.ast.init_node.unwrap());
}

/// What counts as an "acceptable body" for an if/while/for.
/// The rule is: bodies must be blocks (braces).  The reason isn't
/// aesthetics - the user wants to set breakpoints on the body line.
/// `if (cond) return x;` is one statement; a breakpoint on it
/// stops BEFORE the condition is evaluated.  Move that to
/// `if (cond) {\n    return x;\n}` and the breakpoint lands on
/// the return - much more useful when stepping through.
/// The one carve-out: `for (xs) |x| switch (x) { ... }` is fine.
/// The switch's own braces fully delimit the body; a breakpoint
/// on one of the switch arms still stops in the right place.
/// The four AST tags Zig uses for a braced block, which differ only in arity and
/// trailing-comma. Every rule that asks "is this body braced?" means these.
fn isBlockTag(t: Ast.Node.Tag) bool {
    return switch (t) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => true,
        else => false,
    };
}

fn isAcceptableBranchBody(ast: *const Ast, body: Index) bool {
    return switch (ast.nodeTag(body)) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => true,
        // Switch body has its own braces - breakpoint-friendly.
        .@"switch", .switch_comma => true,
        else => false,
    };
}

/// Whether `node`, made a statement, ends with a block of its own and so takes no `;` after it: a block, a switch,
/// or a `for` / `while` / `if` whose last branch does. `for (xs) |x| { ... }` is a whole statement as it stands;
/// `total += x` and `x = S{}` need their `;`.
fn statementEndsInBlock(ast: *const Ast, node: Index) bool {
    if (ast.fullFor(node)) |for_node| {
        return statementEndsInBlock(ast, for_node.ast.else_expr.unwrap() orelse for_node.ast.then_expr);
    }
    if (ast.fullWhile(node)) |while_node| {
        return statementEndsInBlock(ast, while_node.ast.else_expr.unwrap() orelse while_node.ast.then_expr);
    }
    if (ast.fullIf(node)) |if_node| {
        return statementEndsInBlock(ast, if_node.ast.else_expr.unwrap() orelse if_node.ast.then_expr);
    }
    return isAcceptableBranchBody(ast, node);
}

/// branch-braces' report and its fix: the body wrapped in a block, `{ body; }`, its text kept byte for byte -
/// comments and all. When the body ends the statement - a `;` follows - the block swallows that `;`: a block-bodied
/// `if` / `while` / `for` takes none, and `if (c) { ... };` would not parse. A body that ends in a block of its own
/// (`if (c) for (xs) |x| { ... };`) gets no `;` inside the new block either - `{ for ... { ... }; }` would not parse,
/// and the guard refused that fix until Oct 18. Before an `else`, or a `,` closing a switch prong, the rest stays as
/// it is. `--fix` lays the block out afterwards, as `zig fmt` does.
fn emitBranchBraces(
    ctx: Ctx,
    report_token: u32,
    body: Index,
    branch_name: []const u8,
) !void {
    const ast: *const Ast = ctx.ast;
    const first_token: u32 = ast.firstToken(body);
    const last_token: u32 = ast.lastToken(body);
    const body_start: u32 = @intCast(ast.tokenStart(first_token));
    const body_end: u32 = @intCast(ast.tokenStart(last_token) + ast.tokenSlice(last_token).len);
    const after_body: u32 = last_token + 1;
    const ends_statement: bool = ast.tokenTag(after_body) == .semicolon;
    const span_end: u32 = if (ends_statement) @intCast(ast.tokenStart(after_body) + 1) else body_end;
    const body_text: []const u8 = ctx.source[body_start..body_end];
    const replacement: []u8 = if (statementEndsInBlock(ast, body))
        try allocPrint(ctx.alloc, "{{ {s} }}", .{body_text})
    else
        try allocPrint(ctx.alloc, "{{ {s}; }}", .{body_text});
    defer ctx.alloc.free(replacement);
    const fix: Fix = .{ .start = body_start, .end = span_end, .replacement = replacement };
    try ctx.emitFix(report_token, "branch-braces", 3, fix, "{s} body should be a block", .{branch_name});
}

fn checkBranchBraces(
    ctx: Ctx,
    node: Index,
    tag: Ast.Node.Tag,
) !void {
    const ast: *const Ast = ctx.ast;
    switch (tag) {
        .if_simple, .while_simple, .for_simple => {
            _, const body = ast.nodeData(node).node_and_node;
            if (!isAcceptableBranchBody(ast, body)) {
                const main_tok: u32 = ast.nodeMainToken(node);
                try emitBranchBraces(ctx, main_tok, body, ast.tokenSlice(main_tok));
            }
        },
        .@"if" => {
            const f: Ast.full.If = ast.fullIf(node).?;
            if (!isAcceptableBranchBody(ast, f.ast.then_expr)) {
                try emitBranchBraces(ctx, ast.nodeMainToken(node), f.ast.then_expr, "if-then");
            }
            if (f.ast.else_expr.unwrap()) |e| {
                // Chain `else if` is fine - that's an idiomatic
                // pattern, not a no-brace branch.
                const etag: Ast.Node.Tag = ast.nodeTag(e);
                if (etag != .if_simple and etag != .@"if" and !isAcceptableBranchBody(ast, e)) {
                    try emitBranchBraces(ctx, ast.nodeMainToken(e), e, "else");
                }
            }
        },
        .@"while" => {
            const w: Ast.full.While = ast.fullWhile(node).?;
            if (!isAcceptableBranchBody(ast, w.ast.then_expr)) {
                try emitBranchBraces(ctx, ast.nodeMainToken(node), w.ast.then_expr, "while");
            }
        },
        .@"for" => {
            const f: Ast.full.For = ast.fullFor(node).?;
            if (!isAcceptableBranchBody(ast, f.ast.then_expr)) {
                try emitBranchBraces(ctx, ast.nodeMainToken(node), f.ast.then_expr, "for");
            }
        },
        else => {},
    }
}

/// Whether `c` can appear inside an identifier or a number.
fn isWordByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_' or c == '.';
}

/// `std-math` - bans `std.math.*` everywhere except zimrmath.zig.
///
/// std.math is host-only by design (f64 paths, lookup tables) and does
/// NOT reliably compile to SPIR-V, so reaching for it at a call site is
/// a silent GPU-portability hazard.  zimrmath is the ONE place allowed
/// to delegate to std.math, behind a `comptime !is_gpu` gate with a
/// hand-rolled GPU branch.  Detection: a `field_access` whose field is
/// `math` and whose object identifier is `std` OR any whole-module
/// `@import("std")` alias in the file (so `std_mod.math.pi` is caught too),
/// firing once per usage at the `math` token.  No `// lint:off` for this tag.
/// A pi or tau inside a trig argument is a turn count converting itself to radians.
///
/// Catches `sinRad(x * tau)` and `@sin(2.0 * pi * x)` alike. It does NOT ban either function -
/// a genuine radian angle is what they are for - only the round trip through a constant that a
/// turns call would not need.
///
/// Deliberately textual on the argument's source span rather than structural: the shapes vary
/// (`x * tau`, `2.0 * pi * x`, `tau * x / n`, a bare `6.2831853`) and what they have in common
/// is the CONSTANT, which is exactly what a substring scan finds.
fn checkTurnInRadianCall(
    ctx: Ctx,
    node: Index,
    tag: Ast.Node.Tag,
) !void {
    if (tag != .call_one and tag != .call and tag != .builtin_call_two and tag != .builtin_call) {
        return;
    }
    const ast: *const Ast = ctx.ast;
    const main_tok: u32 = ast.nodeMainToken(node);
    const callee: []const u8 = ast.tokenSlice(main_tok);
    const radian_trig = [_][]const u8{
        "sinRad", "cosRad", "tanRad", "sincosRad", "@sin", "@cos", "@tan",
    };
    var is_trig: bool = false;
    for (radian_trig) |name| {
        if (eql(u8, callee, name)) {
            is_trig = true;
            break;
        }
    }
    if (!is_trig) {
        return;
    }
    // The argument's source span: from after the open paren to the matching close.
    const start: usize = ast.tokenStart(main_tok);
    var cursor: usize = start;
    while (cursor < ctx.source.len and ctx.source[cursor] != '(') {
        cursor += 1;
    }
    var depth: usize = 0;
    const open: usize = cursor;
    while (cursor < ctx.source.len) : (cursor += 1) {
        if (ctx.source[cursor] == '(') {
            depth += 1;
        } else if (ctx.source[cursor] == ')') {
            depth -= 1;
            if (depth == 0) {
                break;
            }
        }
    }
    if (cursor <= open + 1) {
        return;
    }
    const arg: []const u8 = ctx.source[open + 1 .. cursor];
    const constants = [_][]const u8{ "tau", "pi", "6.283", "3.14159" };
    for (constants) |needle| {
        var at: usize = 0;
        while (indexOfPos(u8, arg, at, needle)) |hit| {
            at = hit + needle.len;
            // A bare word, not `pixel` or `tauri` or part of a longer number.
            const before_ok: bool = hit == 0 or !isWordByte(arg[hit - 1]);
            const after: usize = hit + needle.len;
            const after_ok: bool = after >= arg.len or !isWordByte(arg[after]);
            if (!before_ok or !after_ok) {
                continue;
            }
            try ctx.emitAt(
                main_tok,
                "turn-in-radian-call",
                0,
                "`{s}` is called with `{s}` in its argument - that is a turn count " ++
                    "converting itself to radians so a radian function will take it. " ++
                    "Use `sinTurns`/`cosTurns`/`tanTurns` and drop the constant: a quarter " ++
                    "turn is 0.25.",
                .{ callee, needle },
            );
            return;
        }
    }
}

fn checkStdMath(
    ctx: Ctx,
    node: Index,
    tag: Ast.Node.Tag,
) !void {
    if (tag != .field_access) {
        return;
    }
    // zimrmath is the single sanctioned home for std.math delegation.
    if (endsWith(u8, ctx.path, "zimrmath.zig")) {
        return;
    }
    const ast: *const Ast = ctx.ast;
    const data: Ast.Node.Data = ast.nodeData(node);
    const lhs: Index = data.node_and_token[0];
    const field_tok: u32 = data.node_and_token[1];
    if (!eql(u8, ast.tokenSlice(field_tok), "math")) {
        return;
    }
    if (ast.nodeTag(lhs) != .identifier) {
        return;
    }
    // Flag the literal `std.math` AND any `<alias>.math` where the alias is a
    // whole-module `@import("std")` binding (e.g. `const std_mod = @import("std")`
    // -> `std_mod.math.pi`).  Aliasing the import must not evade the ban.
    const obj_name: []const u8 = ast.tokenSlice(ast.nodeMainToken(lhs));
    var is_std: bool = eql(u8, obj_name, "std");
    if (!is_std) {
        for (ctx.std_aliases) |a| {
            if (eql(u8, obj_name, a)) {
                is_std = true;
                break;
            }
        }
    }
    if (!is_std) {
        return;
    }
    try ctx.emitAt(
        field_tok,
        "std-math",
        0,
        "std.math is banned outside zimrmath (GPU-portability). " ++
            "Wrap the needed function in zimrmath.zig — gated on `!is_gpu` " ++
            "with a GPU branch, verified to compile for a shader — and call " ++
            "it as `zm.<fn>`. There is no lint:off for this.",
        .{},
    );
}

/// Rule `prefer-vec`: `Vec` is zimr's central type; the verbose
/// `@Vector(4, f32)` (and `@Vector(3, f32)` / `@Vector(2, f32)`) should be its
/// named alias `Vec` / `Vec3` / `Vec2` everywhere EXCEPT:
///   - the canonical definitions in `zimrmath.zig` (`pub const Vec = @Vector(...)`),
///   - `extern`/`packed` struct field types, where the explicit width documents
///     the GPU memory layout (a UBO/vertex `vec4<f32>`) - pre-marked in
///     `ctx.extern_field_vecs`.
/// Autofix: splice the alias name over the whole `@Vector(N, f32)` span. The
/// alias resolves through `zm` in any file that does vector math (which, by the
/// reserved-math rule, is every file using these types); a file that somehow
/// lacks the binding gets a report to add it.
fn checkPreferVec(ctx: Ctx, node: Index, tag: Ast.Node.Tag) !void {
    if (tag != .builtin_call_two and tag != .builtin_call_two_comma) {
        return;
    }
    const ast: *const Ast = ctx.ast;
    // zimrmath.zig defines Vec/Vec2/Vec3 themselves - leave those alone.
    if (endsWith(u8, ctx.path, "zimrmath.zig")) {
        return;
    }
    if (!eql(u8, ast.tokenSlice(ast.nodeMainToken(node)), "@Vector")) {
        return;
    }
    // (Vec works in extern/packed fields too - proven: it transpiles to the
    // same `vec4<f32>` std140 layout - so those are NOT exempt.)
    // Read the two args: a lane count (number_literal) and an element type.
    const a0_opt, const a1_opt = ast.nodeData(node).opt_node_and_opt_node;
    const a0: Index = a0_opt.unwrap() orelse return;
    const a1: Index = a1_opt.unwrap() orelse return;
    if (ast.nodeTag(a0) != .number_literal or ast.nodeTag(a1) != .identifier) {
        return;
    }
    if (!eql(u8, ast.tokenSlice(ast.nodeMainToken(a1)), "f32")) {
        return; // only the f32 vectors have Vec/Vec2/Vec3 aliases
    }
    const lanes: []const u8 = ast.tokenSlice(ast.nodeMainToken(a0));
    const alias: []const u8 = if (eql(u8, lanes, "4"))
        "Vec"
    else if (eql(u8, lanes, "3"))
        "Vec3"
    else if (eql(u8, lanes, "2"))
        "Vec2"
    else
        return; // exotic widths keep the explicit form

    const span_start: u32 = @intCast(ast.tokenStart(ast.firstToken(node)));
    const last_tok: u32 = ast.lastToken(node); // the closing ')'
    const span_end: u32 = @intCast(ast.tokenStart(last_tok) + ast.tokenSlice(last_tok).len);
    try ctx.emitFix(
        ast.nodeMainToken(node),
        "prefer-vec",
        0,
        .{ .start = span_start, .end = span_end, .replacement = alias },
        "use '{s}' instead of the verbose '@Vector({s}, f32)' — Vec is zimr's " ++
            "central type (`// lint:off prefer-vec: <why>` for a deliberate raw form)",
        .{ alias, lanes },
    );
}

// ==== Names bound once and used bare: no-qualified-zm and no-qualified-std share this ====
//
// Both rules ask the same three questions of a member reached through a module alias (`zm.length`,
// `std.mem.eql`): which bare name would the file bind it to, does the file already have that binding, and
// is this use the binding's own init (its one legal home)? A FAMILY answers the first - the rest is shared.

/// A member reached through a module alias: `<root>.<name>` (no namespace - `zm.length`, `std.Io`) or
/// `<root>.<namespace>.<name>` (`std.mem.eql`).
const QualifiedMember = struct {
    /// The middle segment, or "" for a member of the module itself.
    namespace: []const u8,
    name: []const u8,
    /// The member name's token - where a report points and a fix ends.
    name_token: u32,
};

fn isOneOf(word: []const u8, words: []const []const u8) bool {
    for (words) |candidate| {
        if (eql(u8, word, candidate)) {
            return true;
        }
    }
    return false;
}

/// `node` as a member of one of `roots` (a file's aliases of one module), or null. Both shapes are field
/// accesses; in the two-level one the object is itself a one-level access (the namespace).
fn qualifiedMember(
    ast: *const Ast,
    node: Index,
    roots: []const []const u8,
) ?QualifiedMember {
    if (ast.nodeTag(node) != .field_access) {
        return null;
    }
    const access: Ast.Node.Data = ast.nodeData(node);
    const object: Index = access.node_and_token[0];
    const name_token: u32 = access.node_and_token[1];
    const name: []const u8 = ast.tokenSlice(name_token);
    switch (ast.nodeTag(object)) {
        .identifier => {
            const root_name: []const u8 = ast.tokenSlice(ast.nodeMainToken(object));
            if (!isOneOf(root_name, roots)) {
                return null;
            }
            return .{ .namespace = "", .name = name, .name_token = name_token };
        },
        .field_access => {
            const namespace_access: Ast.Node.Data = ast.nodeData(object);
            const root_node: Index = namespace_access.node_and_token[0];
            if (ast.nodeTag(root_node) != .identifier) {
                return null;
            }
            if (!isOneOf(ast.tokenSlice(ast.nodeMainToken(root_node)), roots)) {
                return null;
            }
            const namespace: []const u8 = ast.tokenSlice(namespace_access.node_and_token[1]);
            return .{ .namespace = namespace, .name = name, .name_token = name_token };
        },
        else => return null,
    }
}

/// One std name worth binding once: `std.<namespace>.<name>` (or `std.<name>`) bound as `alias`.
const StdAlias = struct {
    namespace: []const u8,
    name: []const u8,
    alias: []const u8,
};

/// The std names `no-qualified-std` asks to be bound once and used bare - chosen by counting zimr's own
/// qualified uses (Sep 29: `std.testing.allocator` 1969, `std.Io` 1066, `std.mem.eql` 498, ...). Kept out:
/// `std.meta.eql` (a bare `eql` can mean one thing), `std.debug.print` and `std.log.*` (their own rules and
/// idioms), `std.Build`, `std.process`, `std.fs` (few files; OS-facing calls read better qualified). Folded in on
/// Oct 2: the names `prefer-std-alias` used to enforce in bodies only (`ArrayList`, `bufPrint`, `allocPrint`, every
/// `expect...`) - one rule, one binding mechanism, everywhere, with this rule's collision safety and its `--fix`.
const std_vocabulary = [_]StdAlias{
    // Types and namespaces.
    .{ .namespace = "", .name = "Io", .alias = "Io" },
    .{ .namespace = "", .name = "Random", .alias = "Random" },
    .{ .namespace = "", .name = "ArrayListUnmanaged", .alias = "ArrayListUnmanaged" },
    .{ .namespace = "", .name = "ArrayList", .alias = "ArrayList" },
    .{ .namespace = "", .name = "ArrayListAligned", .alias = "ArrayListAligned" },
    .{ .namespace = "", .name = "AutoHashMapUnmanaged", .alias = "AutoHashMapUnmanaged" },
    .{ .namespace = "", .name = "StringHashMap", .alias = "StringHashMap" },
    .{ .namespace = "mem", .name = "Allocator", .alias = "Allocator" },
    .{ .namespace = "heap", .name = "ArenaAllocator", .alias = "ArenaAllocator" },
    // Testing: a bare `allocator` would say nothing, so the testing one says where it is from.
    .{ .namespace = "testing", .name = "allocator", .alias = "testing_allocator" },
    .{ .namespace = "testing", .name = "refAllDecls", .alias = "refAllDecls" },
    // std.mem.
    .{ .namespace = "mem", .name = "eql", .alias = "eql" },
    .{ .namespace = "mem", .name = "indexOf", .alias = "indexOf" },
    .{ .namespace = "mem", .name = "indexOfPos", .alias = "indexOfPos" },
    .{ .namespace = "mem", .name = "indexOfScalar", .alias = "indexOfScalar" },
    .{ .namespace = "mem", .name = "indexOfScalarPos", .alias = "indexOfScalarPos" },
    .{ .namespace = "mem", .name = "startsWith", .alias = "startsWith" },
    .{ .namespace = "mem", .name = "endsWith", .alias = "endsWith" },
    .{ .namespace = "mem", .name = "sliceAsBytes", .alias = "sliceAsBytes" },
    .{ .namespace = "mem", .name = "asBytes", .alias = "asBytes" },
    .{ .namespace = "mem", .name = "zeroes", .alias = "zeroes" },
    .{ .namespace = "mem", .name = "splitScalar", .alias = "splitScalar" },
    .{ .namespace = "mem", .name = "trim", .alias = "trim" },
    .{ .namespace = "mem", .name = "swap", .alias = "swap" },
    .{ .namespace = "mem", .name = "copyForwards", .alias = "copyForwards" },
    .{ .namespace = "mem", .name = "readInt", .alias = "readInt" },
    .{ .namespace = "mem", .name = "writeInt", .alias = "writeInt" },
    // Sorting: `sortSlice`, since zimrnum's `sort` sorts tensors. (`std.sort.asc` / `desc`: too rare to bind.)
    .{ .namespace = "mem", .name = "sort", .alias = "sortSlice" },
    // std.fmt.
    .{ .namespace = "fmt", .name = "parseInt", .alias = "parseInt" },
    .{ .namespace = "fmt", .name = "bufPrint", .alias = "bufPrint" },
    .{ .namespace = "fmt", .name = "allocPrint", .alias = "allocPrint" },
    // The test vocabulary: every `expect...` std.testing has.
    .{ .namespace = "testing", .name = "expect", .alias = "expect" },
    .{ .namespace = "testing", .name = "expectEqual", .alias = "expectEqual" },
    .{ .namespace = "testing", .name = "expectError", .alias = "expectError" },
    .{ .namespace = "testing", .name = "expectEqualSlices", .alias = "expectEqualSlices" },
    .{ .namespace = "testing", .name = "expectEqualStrings", .alias = "expectEqualStrings" },
    .{ .namespace = "testing", .name = "expectEqualDeep", .alias = "expectEqualDeep" },
    .{ .namespace = "testing", .name = "expectEqualSentinel", .alias = "expectEqualSentinel" },
    .{ .namespace = "testing", .name = "expectApproxEqAbs", .alias = "expectApproxEqAbs" },
    .{ .namespace = "testing", .name = "expectApproxEqRel", .alias = "expectApproxEqRel" },
    .{ .namespace = "testing", .name = "expectFmt", .alias = "expectFmt" },
    .{ .namespace = "testing", .name = "expectStringStartsWith", .alias = "expectStringStartsWith" },
    .{ .namespace = "testing", .name = "expectStringEndsWith", .alias = "expectStringEndsWith" },
    .{ .namespace = "fmt", .name = "parseFloat", .alias = "parseFloat" },
};

/// The bare name the vocabulary binds `member` to, or null when it is not in the vocabulary.
fn stdVocabularyAlias(member: QualifiedMember) ?[]const u8 {
    for (std_vocabulary) |entry| {
        if (eql(u8, entry.namespace, member.namespace) and eql(u8, entry.name, member.name)) {
            return entry.alias;
        }
    }
    return null;
}

/// The families of names bound once and used bare.
const AliasFamily = enum {
    /// zimrmath: any `const X = zm.X;` is a binding; its KEYWORDS must be used through one.
    zm,
    /// std: the `std_vocabulary` table - each entry's path, and the bare name it binds to.
    std_lib,

    /// The bare name `member` binds to in this family, or null when the family binds it to none.
    fn aliasFor(family: AliasFamily, member: QualifiedMember) ?[]const u8 {
        return switch (family) {
            .zm => if (member.namespace.len == 0) member.name else null,
            .std_lib => stdVocabularyAlias(member),
        };
    }

    /// Whether a qualified use of `member` must go through the binding.
    fn mustBeBare(family: AliasFamily, member: QualifiedMember) bool {
        return switch (family) {
            .zm => member.namespace.len == 0 and keywords.has(member.name),
            .std_lib => stdVocabularyAlias(member) != null,
        };
    }
};

/// The file-scope binding for `alias` in `family` - a root declaration named `alias` whose init is a member of
/// `roots` that the family binds to `alias` (`const eql = std.mem.eql;`) - as its first token; null when the file
/// has none. WHERE it sits matters: a qualified use may become the bare name only BELOW the binding, or the rewrite
/// would create a use before the declaration (`decl-order`) - the L4b dry run met one, wgpu_app.zig's late
/// `const Vec2 = zm.Vec2;` hundreds of lines under a `zm.Vec2` the fix had turned into `Vec2`.
fn fileScopeBinding(
    ast: *const Ast,
    roots: []const []const u8,
    family: AliasFamily,
    alias: []const u8,
) ?u32 {
    for (ast.rootDecls()) |decl| {
        const var_decl: Ast.full.VarDecl = ast.fullVarDecl(decl) orelse continue;
        const declared_name: []const u8 = ast.tokenSlice(var_decl.ast.mut_token + 1);
        if (!eql(u8, declared_name, alias)) {
            continue;
        }
        const init: Index = var_decl.ast.init_node.unwrap() orelse continue;
        const member: QualifiedMember = qualifiedMember(ast, init, roots) orelse continue;
        const bound_to: []const u8 = family.aliasFor(member) orelse continue;
        if (eql(u8, bound_to, alias)) {
            return ast.firstToken(decl);
        }
    }
    return null;
}

/// True when the file has a file-scope `const <n> = <zmAlias>.<n>;` binding - `fileScopeBinds` for zm.
fn fileScopeBindsZm(
    ast: *const Ast,
    zm_aliases: []const []const u8,
    name: []const u8,
) bool {
    return fileScopeBinding(ast, zm_aliases, .zm, name) != null;
}

/// The fix that turns a qualified use into the bare name. When the alias IS the member's name, drop the
/// qualifier (`zm.length` -> `length`, `std.mem.eql` -> `eql`); when it is a clearer name, replace the whole
/// expression (`std.testing.allocator` -> `testing_allocator`).
fn bareUseFix(
    ast: *const Ast,
    node: Index,
    member: QualifiedMember,
    alias: []const u8,
) Fix {
    const expression_start: u32 = @intCast(ast.tokenStart(ast.firstToken(node)));
    const name_start: u32 = @intCast(ast.tokenStart(member.name_token));
    if (eql(u8, alias, member.name)) {
        return .{ .start = expression_start, .end = name_start };
    }
    const name_end: u32 = name_start + @as(u32, @intCast(member.name.len));
    return .{ .start = expression_start, .end = name_end, .replacement = alias };
}

// ---- The std vocabulary ----------------------------------------------------------------------------------------

/// Each vocabulary entry's binding as a whole line - what `--fix` inserts when a file lacks it. Built at compile
/// time, so a fix can carry it without owning memory.
const std_binding_lines: [std_vocabulary.len][]const u8 = blk: {
    var lines: [std_vocabulary.len][]const u8 = undefined;
    for (std_vocabulary, &lines) |entry, *line| {
        const separator: []const u8 = if (entry.namespace.len > 0) "." else "";
        line.* = std.fmt.comptimePrint("const {s} = std.{s}{s}{s};\n", .{
            entry.alias,
            entry.namespace,
            separator,
            entry.name,
        });
    }
    break :blk lines;
};

/// The vocabulary entry whose alias is `alias`, or null.
fn stdVocabularyIndexOfAlias(alias: []const u8) ?usize {
    for (std_vocabulary, 0..) |entry, index| {
        if (eql(u8, entry.alias, alias)) {
            return index;
        }
    }
    return null;
}

/// Whether the identifier at `index` is being DECLARED (see `countStdAliasDeclarations`).
fn isDeclarationToken(tags: []const std.zig.Token.Tag, index: usize) bool {
    const previous: ?std.zig.Token.Tag = if (index > 0) tags[index - 1] else null;
    const next: ?std.zig.Token.Tag = if (index + 1 < tags.len) tags[index + 1] else null;
    const after_keyword: bool = previous == .keyword_fn or previous == .keyword_const or previous == .keyword_var;
    const parameter_or_field: bool = next == .colon and
        (previous == .l_paren or previous == .comma or previous == .keyword_comptime or previous == .keyword_noalias);
    const pointer_capture: bool = previous == .asterisk and index >= 2 and tags[index - 2] == .pipe;
    const capture: bool = previous == .pipe or pointer_capture or (previous == .comma and next == .pipe);
    return after_keyword or parameter_or_field or capture;
}

/// Pre-pass for `no-qualified-std`: how many times each vocabulary alias is DECLARED in the file, into
/// `counts` (one per `std_vocabulary` entry). A declaration is a name right after `fn` / `const` / `var`, a
/// parameter or field (`(name:` / `, name:`), or a capture (`|name|`, `|*name|`, `|a, name|`); a use is
/// none of these. One pass over the tokens.
fn countStdAliasDeclarations(ast: *const Ast, counts: []u32) void {
    @memset(counts, 0);
    const tags: []const std.zig.Token.Tag = ast.tokens.items(.tag);
    for (tags, 0..) |token_tag, token_index| {
        if (token_tag != .identifier) {
            continue;
        }
        const word: []const u8 = ast.tokenSlice(@intCast(token_index));
        const vocabulary_index: usize = stdVocabularyIndexOfAlias(word) orelse continue;
        if (isDeclarationToken(tags, token_index)) {
            counts[vocabulary_index] += 1;
        }
    }
}

/// `no-qualified-zm` (R2): every `zm.X` member access in a zm-importing file
/// must go through a file-scope named import (`const X = zm.X;`), never inline -
/// anywhere: bodies, signatures, field types (one way: Simon, Oct 2; the old walk
/// never showed this rule a signature, so it used to read "in a body").  The
/// canonical binding init is the one allowed `zm.X` (pre-marked
/// in `ctx.canonical_zm_inits`).  Files that don't import zm are exempt
/// (`zm_aliases` empty - e.g. zimrmath itself).  Mirrors checkDebugPrint: fires
/// on a `field_access` whose object identifier is a zm alias, at the field
/// token.  A blocked name (a local/param/fn already owns `X`) or runtime.zig's
/// per-struct zm opts out with `// lint:off no-qualified-zm: <reason>`.
/// How many times `name` is DECLARED in the file - after `fn` / `const` / `var`, as a parameter or field, or as a
/// capture (`isDeclarationToken`, the test `no-qualified-std`'s pre-pass uses). One pass over the tokens.
fn declarationCount(ast: *const Ast, name: []const u8) u32 {
    const tags: []const std.zig.Token.Tag = ast.tokens.items(.tag);
    var count: u32 = 0;
    for (tags, 0..) |token_tag, token_index| {
        if (token_tag == .identifier and eql(u8, ast.tokenSlice(@intCast(token_index)), name)) {
            if (isDeclarationToken(tags, token_index)) {
                count += 1;
            }
        }
    }
    return count;
}

/// Whether the member chain `node` (`std.Io.Writer`) starts at one of `roots`.
fn memberRoot(ast: *const Ast, node: Index, roots: []const []const u8) bool {
    var current: Index = node;
    while (ast.nodeTag(current) == .field_access) {
        current = ast.nodeData(current).node_and_token[0];
    }
    return ast.nodeTag(current) == .identifier and isOneOf(ast.tokenSlice(ast.nodeMainToken(current)), roots);
}

/// Where `--fix` inserts a missing binding - std's (`no-qualified-std`) or zm's (`no-qualified-zm`), the family
/// given by its `roots`. For std: the start of the line after the header's last std alias
/// (the run of one-line `const` imports and aliases following the std import), or right after the std import
/// itself when a header line uses `qualified` (e.g. `std.Io`) - a header alias like `const Writer = std.Io.Writer;`
/// must find `Io` declared above it. Decided per NAME, not per use: every use of one missing name must ask for
/// its binding at the same spot, or the copies would not collapse into one. Null without a column-0 std import.
fn bindingInsertOffset(
    ast: *const Ast,
    std_roots: []const []const u8,
    qualified: []const u8,
) ?u32 {
    const roots: []const Index = ast.rootDecls();
    var std_index: ?usize = null;
    for (roots, 0..) |decl, index| {
        const var_decl: Ast.full.VarDecl = ast.fullVarDecl(decl) orelse continue;
        const name: []const u8 = ast.tokenSlice(var_decl.ast.mut_token + 1);
        const init: Index = var_decl.ast.init_node.unwrap() orelse continue;
        if (isOneOf(name, std_roots) and ast.nodeTag(init) == .builtin_call_two) {
            std_index = index;
            break;
        }
    }
    const std_at: usize = std_index orelse return null;
    // The header: the one-line `const` aliases and imports right after the std import.
    var last_std_alias: usize = std_at;
    var header_end: usize = std_at;
    var index: usize = std_at + 1;
    while (index < roots.len) : (index += 1) {
        const var_decl: Ast.full.VarDecl = ast.fullVarDecl(roots[index]) orelse break;
        const init: Index = var_decl.ast.init_node.unwrap() orelse break;
        const init_tag: Ast.Node.Tag = ast.nodeTag(init);
        const is_alias: bool = init_tag == .field_access;
        const is_import: bool = init_tag == .builtin_call_two;
        if (!is_alias and !is_import) {
            break;
        }
        header_end = index;
        if (is_alias and memberRoot(ast, init, std_roots)) {
            last_std_alias = index;
        }
    }
    // Does a header line use the name? Its text holds `qualified` followed by no identifier character.
    var used_in_header: bool = false;
    for (roots[std_at + 1 .. header_end + 1]) |decl| {
        const first_byte: usize = ast.tokenStart(ast.firstToken(decl));
        const last_token: u32 = ast.lastToken(decl);
        const end_byte: usize = ast.tokenStart(last_token) + ast.tokenSlice(last_token).len;
        const text: []const u8 = ast.source[first_byte..end_byte];
        var search_from: usize = 0;
        while (indexOfPos(u8, text, search_from, qualified)) |found| {
            const after: usize = found + qualified.len;
            const boundary: bool = after >= text.len or !(std.ascii.isAlphanumeric(text[after]) or text[after] == '_');
            if (boundary) {
                used_in_header = true;
                break;
            }
            search_from = after;
        }
    }
    const anchor: Index = roots[if (used_in_header) std_at else last_std_alias];
    // The start of the line after the anchor's `;`.
    const source: []const u8 = ast.source;
    var at: usize = ast.tokenStart(ast.lastToken(anchor));
    while (at < source.len and source[at] != '\n') {
        at += 1;
    }
    if (at >= source.len) {
        return null;
    }
    return @intCast(at + 1);
}

fn checkNoQualifiedZm(ctx: Ctx, node: Index, tag: Ast.Node.Tag) !void {
    if (tag != .field_access) {
        return;
    }
    if (ctx.zm_aliases.len == 0) {
        return;
    }
    if (!ctx.zm_col0) {
        return;
    }
    const node_number: usize = @backingInt(node);
    if (node_number < ctx.canonical_zm_inits.len and ctx.canonical_zm_inits[node_number]) {
        return;
    }
    const ast: *const Ast = ctx.ast;
    const member: QualifiedMember = qualifiedMember(ast, node, ctx.zm_aliases) orelse return;
    // Only KEYWORDS need aliasing. A non-keyword zm decl (matFromAxisAngle, the
    // obscure helpers) may be used qualified as `zm.X` without a file-scope alias.
    if (!AliasFamily.zm.mustBeBare(member)) {
        return;
    }
    const field: []const u8 = member.name;
    // Autofix half-1: if `const <field> = zm.<field>;` already exists at file
    // scope, the inline use can be rewritten to bare `<field>` simply by deleting
    // the `zm.` prefix (the field token already resolves to that binding - safe,
    // no collision). When the binding is absent we only report: adding it is the
    // riskier half (needs a free-name check) and is left to the developer.
    if (fileScopeBinding(ast, ctx.zm_aliases, .zm, field)) |binding_token| {
        // Bound ABOVE this use: drop the `zm.`. Bound only below it: the rewrite would put the use before the
        // declaration - a human moves the binding up with the others first.
        if (binding_token < ast.firstToken(node)) {
            try ctx.emitFix(
                member.name_token,
                "no-qualified-zm",
                0,
                bareUseFix(ast, node, member, field),
                "qualified 'zm.{s}' - bind it once at file scope as " ++
                    "`const {s} = zm.{s};` then use `{s}`, or rename the decl that " ++
                    "shadows it (`// lint:off no-qualified-zm: <why>` for a real one)",
                .{ field, field, field, field },
            );
        } else {
            const binding_line: usize = ast.tokenLocation(0, binding_token).line + 1;
            try ctx.emitAt(
                member.name_token,
                "no-qualified-zm",
                0,
                "qualified 'zm.{s}' - this file binds `{s}` only below this use (line {d}): " ++
                    "move that binding up with the others, then use `{s}`",
                .{ field, field, binding_line, field },
            );
        }
        return;
    }
    // The binding is missing. `--fix` inserts it - one pass - and the next pass, now bound, drops the `zm.` from every
    // use; every use of one name asks for the same insertion, so the copies collapse into one binding. Not when the
    // name is already declared somewhere in the file (a local, a parameter, a capture): the binding would collide
    // with it, which no parse check would notice - that one is for a human (or `reserved-math-names`) to resolve.
    const root_name: []const u8 = ast.tokenSlice(ast.firstToken(node));
    var qualified_buffer: [128]u8 = undefined;
    const qualified: []const u8 = bufPrint(&qualified_buffer, "{s}.{s}", .{ root_name, field }) catch "";
    const insert_at: ?u32 = if (qualified.len > 0) bindingInsertOffset(ast, ctx.zm_aliases, qualified) else null;
    if (insert_at != null and declarationCount(ast, field) == 0) {
        const binding_line: []u8 = try allocPrint(ctx.alloc, "const {s} = {s}.{s};\n", .{ field, root_name, field });
        defer ctx.alloc.free(binding_line);
        const binding: Fix = .{ .start = insert_at.?, .end = insert_at.?, .replacement = binding_line };
        try ctx.emitFix(
            member.name_token,
            "no-qualified-zm",
            0,
            binding,
            "qualified 'zm.{s}' - bind it once at file scope as " ++
                "`const {s} = zm.{s};` then use `{s}`",
            .{ field, field, field, field },
        );
        return;
    }
    try ctx.emitAt(
        member.name_token,
        "no-qualified-zm",
        0,
        "qualified 'zm.{s}' - bind it once at file scope as " ++
            "`const {s} = zm.{s};` then use `{s}`, or rename the decl that " ++
            "shadows it (`// lint:off no-qualified-zm: <why>` for a real one)",
        .{ field, field, field, field },
    );
}

/// `no-qualified-std` on one member access (see `checkNoQualifiedStd`).
fn reportQualifiedStd(ctx: Ctx, node: Index) !void {
    const node_number: usize = @backingInt(node);
    if (node_number < ctx.canonical_std_inits.len and ctx.canonical_std_inits[node_number]) {
        return;
    }
    const ast: *const Ast = ctx.ast;
    const member: QualifiedMember = qualifiedMember(ast, node, ctx.std_aliases) orelse return;
    const alias: []const u8 = AliasFamily.std_lib.aliasFor(member) orelse return;
    // Declared elsewhere in the file? The binding itself is one declaration of the name; any other means the
    // name is taken, and the rule stays out of it.
    const binding_token: ?u32 = fileScopeBinding(ast, ctx.std_aliases, .std_lib, alias);
    const bound: bool = binding_token != null;
    const vocabulary_index: usize = stdVocabularyIndexOfAlias(alias).?;
    const declarations: u32 = if (vocabulary_index < ctx.std_alias_declarations.len)
        ctx.std_alias_declarations[vocabulary_index]
    else
        0;
    const binding_declarations: u32 = @intFromBool(bound);
    if (declarations > binding_declarations) {
        return;
    }
    const separator: []const u8 = if (member.namespace.len > 0) "." else "";
    if (bound) {
        // Bound ABOVE this use: rewrite it. Bound only below: the rewrite would put the use before the declaration.
        if (binding_token.? < ast.firstToken(node)) {
            try ctx.emitFix(
                member.name_token,
                "no-qualified-std",
                0,
                bareUseFix(ast, node, member, alias),
                "qualified 'std.{s}{s}{s}' - this file binds `{s}`; use it",
                .{ member.namespace, separator, member.name, alias },
            );
        } else {
            const binding_line: usize = ast.tokenLocation(0, binding_token.?).line + 1;
            try ctx.emitAt(
                member.name_token,
                "no-qualified-std",
                0,
                "qualified 'std.{s}{s}{s}' - this file binds `{s}` only below this use (line {d}): " ++
                    "move that binding up with the others, then use it",
                .{ member.namespace, separator, member.name, alias, binding_line },
            );
        }
        return;
    }
    // The binding is missing: `--fix` inserts it (one pass), and the next pass - now bound - rewrites every use.
    const unbound_message: []const u8 = "qualified 'std.{s}{s}{s}' - bind it once at file scope, " ++
        "`const {s} = std.{s}{s}{s};`, and use `{s}`";
    // The qualified text as the file spells it (`std.mem.eql`), for the header check.
    var qualified_buffer: [128]u8 = undefined;
    const root_name: []const u8 = ast.tokenSlice(ast.firstToken(node));
    const qualified: []const u8 = bufPrint(&qualified_buffer, "{s}.{s}{s}{s}", .{
        root_name,
        member.namespace,
        separator,
        member.name,
    }) catch return;
    if (bindingInsertOffset(ast, ctx.std_aliases, qualified)) |offset| {
        const binding: Fix = .{ .start = offset, .end = offset, .replacement = std_binding_lines[vocabulary_index] };
        try ctx.emitFix(
            member.name_token,
            "no-qualified-std",
            0,
            binding,
            unbound_message,
            .{ member.namespace, separator, member.name, alias, member.namespace, separator, member.name, alias },
        );
        return;
    }
    try ctx.emitAt(
        member.name_token,
        "no-qualified-std",
        0,
        unbound_message,
        .{ member.namespace, separator, member.name, alias, member.namespace, separator, member.name, alias },
    );
}

/// `no-qualified-std`: a std name from `std_vocabulary`, used qualified, should go through its
/// file-scope binding. Anywhere - bodies, signatures, field types - except the binding's own init
/// (`ctx.canonical_std_inits`), and only in files with a column-0 std import (a file whose std is
/// function-local cannot host the binding). Silent when the bare name is already declared in the file
/// (`ctx.std_alias_declarations`): a local, parameter or capture of that name could not coexist with the
/// binding, and a method of that name would give one word two meanings on one page.
fn checkNoQualifiedStd(ctx: Ctx, node: Index, tag: Ast.Node.Tag) !void {
    if (ctx.std_aliases.len == 0 or !ctx.std_col0) {
        return;
    }
    if (tag == .field_access) {
        try reportQualifiedStd(ctx, node);
    }
}

/// `import-at-top` - a std/builtin/root `@import` inside a function body must be
/// hoisted to a file-scope binding.  Project-module imports
/// (`@import("foo.zig")`) inside a fn are the sanctioned cycle-breaking idiom
/// and are NOT flagged.  The string argument is read from the token two past
/// the `@import` builtin token (`@import` `(` `"std"`).
fn checkImportAtTop(
    ctx: Ctx,
    node: Index,
    tag: Ast.Node.Tag,
    fn_depth: u8,
) !void {
    if (fn_depth == 0) {
        return;
    }
    switch (tag) {
        .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {},
        else => return,
    }
    const ast: *const Ast = ctx.ast;
    const main_tok: u32 = ast.nodeMainToken(node);
    if (!eql(u8, ast.tokenSlice(main_tok), "@import")) {
        return;
    }
    const arg_slice: []const u8 = ast.tokenSlice(main_tok + 2);
    const is_stdlib: bool = eql(u8, arg_slice, "\"std\"") or
        eql(u8, arg_slice, "\"builtin\"") or
        eql(u8, arg_slice, "\"root\"");
    if (!is_stdlib) {
        return;
    }
    try ctx.emitAt(
        main_tok,
        "import-at-top",
        0,
        "{s} @import inside a function body - hoist it to a file-scope " ++
            "`const std = @import(\"std\");` at the top (rare comptime/" ++
            "conditional cases: `// lint:off import-at-top: <why>`)",
        .{arg_slice},
    );
}

fn checkClampPattern(
    ctx: Ctx,
    node: Index,
    tag: Ast.Node.Tag,
) !void {
    // @max(L, @min(V, H)) -> suggest std.math.clamp(V, L, H)
    // @min(H, @max(L, V)) -> suggest std.math.clamp(V, L, H)
    // Precision: skip when L or H is itself a builtin call (the
    // outer @max/@min then can't be a clamp - see ray-AABB t-near
    // / t-far computation in drawing.zig for a real-world example
    // of `@max(@max(@min,@min), @min)` that is NOT a clamp).
    if (tag != .builtin_call_two and tag != .builtin_call_two_comma) {
        return;
    }
    const ast: *const Ast = ctx.ast;
    const name: []const u8 = ast.tokenSlice(ast.nodeMainToken(node));
    if (!eql(u8, name, "@max") and !eql(u8, name, "@min")) {
        return;
    }

    const data: Ast.Node.Data = ast.nodeData(node);
    const a, const b = data.opt_node_and_opt_node;
    const arg_a: Index = a.unwrap() orelse return;
    const arg_b: Index = b.unwrap() orelse return;

    // Check if either arg is the inverse builtin.
    const a_tag: Ast.Node.Tag = ast.nodeTag(arg_a);
    const b_tag: Ast.Node.Tag = ast.nodeTag(arg_b);
    const opposite: []const u8 = if (eql(u8, name, "@max")) "@min" else "@max";

    // Helper: a "bound" is OK if it's NOT a builtin call.
    // Bounds that are themselves @max/@min/@floor/etc. mean we're
    // inside a wider numeric expression, not a clamp.
    const bound_is_simple = struct {
        fn check(node_tag: Ast.Node.Tag) bool {
            return node_tag != .builtin_call_two and
                node_tag != .builtin_call_two_comma and
                node_tag != .builtin_call and
                node_tag != .builtin_call_comma;
        }
    }.check;

    inline for (.{ .{ arg_a, a_tag, arg_b }, .{ arg_b, b_tag, arg_a } }) |pair| {
        const inv_arg, const inv_t, const outer_bound = pair;
        if (inv_t == .builtin_call_two or inv_t == .builtin_call_two_comma) {
            const inner_name: []const u8 = ast.tokenSlice(ast.nodeMainToken(inv_arg));
            if (eql(u8, inner_name, opposite)) {
                // The OTHER outer arg is the LO bound (for @max-outer)
                // or HI bound (for @min-outer).  Inside the inverse,
                // the FIRST arg is the other bound.  If either bound
                // is a builtin call, this isn't a clamp.
                if (!bound_is_simple(ast.nodeTag(outer_bound))) {
                    return;
                }
                const inv_data: Ast.Node.Data = ast.nodeData(inv_arg);
                const ia, _ = inv_data.opt_node_and_opt_node;
                const inner_first: Index = ia.unwrap() orelse return;
                if (!bound_is_simple(ast.nodeTag(inner_first))) {
                    return;
                }
                const main_tok: u32 = ast.nodeMainToken(node);
                try ctx.emitAt(
                    main_tok,
                    "clamp-pattern",
                    0,
                    "{s}({s}(...)) - use zm.clamp(V, lo, hi)",
                    .{ name, opposite },
                );
                return;
            }
        }
    }
}

fn checkIntFromFloat(
    ctx: Ctx,
    node: Index,
    tag: Ast.Node.Tag,
) !void {
    // @intFromFloat takes exactly one arg, so it is always a
    // builtin_call_two / _comma node (callee + one arg).
    if (tag != .builtin_call_two and tag != .builtin_call_two_comma) {
        return;
    }
    const ast: *const Ast = ctx.ast;
    const name: []const u8 = ast.tokenSlice(ast.nodeMainToken(node));
    if (!eql(u8, name, "@intFromFloat")) {
        return;
    }
    const main_tok: u32 = ast.nodeMainToken(node);
    try ctx.emitAt(
        main_tok,
        "int-from-float",
        0,
        "@intFromFloat is redundant - @trunc/@floor/@round/@ceil convert to int directly; write e.g. @trunc(x)",
        .{},
    );
}

/// `custom-degrad`: ban locally-rolled degree<->radian conversion identifiers
/// (DEG2RAD, deg2rad, radToDeg, d2r-style, etc.). The engine standardises on the
/// `zm` helpers `radFromDeg` / `degFromRad` (and the constants `rad_per_deg` /
/// `deg_per_rad`) so every conversion reads the same and the unit direction is
/// unambiguous. Fires on any USE of a banned name (the decl must be used, else
/// `unused-global` catches it). `radFromDeg` / `degFromRad` / `rad_per_deg` /
/// `deg_per_rad` are NOT banned (exact-name match only).
fn checkBannedConversion(
    ctx: Ctx,
    node: Index,
    tag: Ast.Node.Tag,
) !void {
    if (tag != .identifier) {
        return;
    }
    const ast: *const Ast = ctx.ast;
    const name: []const u8 = ast.tokenSlice(ast.nodeMainToken(node));
    const banned = [_][]const u8{
        "DEG2RAD",            "RAD2DEG",
        "deg2rad",            "rad2deg",
        "DEG_TO_RAD",         "RAD_TO_DEG",
        "degToRad",           "radToDeg",
        "degrees_to_radians", "radians_to_degrees",
        "toRadians",          "toDegrees",
    };
    for (banned) |b| {
        if (eql(u8, name, b)) {
            try ctx.emitAt(
                ast.nodeMainToken(node),
                "custom-degrad",
                0,
                "custom degree<->radian conversion is banned - standardise on the zm helpers " ++
                    "zm.radFromDeg / zm.degFromRad (or constants zm.rad_per_deg / zm.deg_per_rad)",
                .{},
            );
            return;
        }
    }
}

fn checkAnonReturn(
    ctx: Ctx,
    node: Index,
    tag: Ast.Node.Tag,
) !void {
    const ast: *const Ast = ctx.ast;
    var buf: [1]Index = undefined;
    const proto_full: ?Ast.full.FnProto = switch (tag) {
        .fn_proto => ast.fnProto(node),
        .fn_proto_multi => ast.fnProtoMulti(node),
        .fn_proto_one => ast.fnProtoOne(&buf, node),
        .fn_proto_simple => ast.fnProtoSimple(&buf, node),
        else => null,
    };
    const proto: Ast.full.FnProto = proto_full orelse return;

    // Look at the return type expression node.  If it's a
    // container_decl (anonymous struct/union/enum), flag it -
    // anon struct returns force callers to either use
    // `@TypeOf(...)` or skip type annotation, and identically-
    // shaped anon structs are distinct types in Zig (so the
    // returned value can't flow through annotated locals at
    // call sites without `@TypeOf`).  Named return types are
    // simpler all around.
    const ret_node: Index = proto.ast.return_type.unwrap() orelse return;
    const ret_tag: Ast.Node.Tag = ast.nodeTag(ret_node);
    const is_anon: bool = switch (ret_tag) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        => true,
        else => false,
    };
    if (!is_anon) {
        return;
    }

    // Name of the function for the message.  fn_proto may be
    // un-named (function-type expressions); skip those - they
    // appear in type positions, not at call-target sites.
    const name_tok: u32 = proto.name_token orelse return;
    const fn_name: []const u8 = ast.tokenSlice(name_tok);

    const main_tok: u32 = ast.nodeMainToken(node);
    try ctx.emitAt(
        main_tok,
        "anon-return",
        0,
        "fn '{s}' returns an anonymous struct - prefer a named type (see CanvasViewport.LogicalPoint)",
        .{fn_name},
    );
}

/// Recognize the four container-decl tags that hold member
/// lists (struct/union/enum/error-set literal bodies).  Used
/// to decide whether to walk a var_decl init as a container
/// (with members at container position) vs as an expression.
fn isContainerDeclTag(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => true,
        else => false,
    };
}

/// True when `path` lives under a `src/` directory (the engine code that
/// ships in every app's wasm).  Handles absolute (`...\Zimr\src\foo.zig`)
/// and relative (`src/foo.zig`) forms on both path separators.
fn inSrcDir(path: []const u8) bool {
    return indexOf(u8, path, "/src/") != null or
        indexOf(u8, path, "\\src\\") != null or
        startsWith(u8, path, "src/") or
        startsWith(u8, path, "src\\");
}

/// `arch-check` - asking the processor (`.isWasm()`, `.wasm32`) in engine code, where a host's fact is meant.
fn checkArchCheck(
    ctx: Ctx,
    node: Index,
    tag: Ast.Node.Tag,
) !void {
    if (!inSrcDir(ctx.path)) {
        return;
    }
    const ast: *const Ast = ctx.ast;
    const asked_token: u32 = switch (tag) {
        .field_access => ast.nodeData(node).node_and_token[1],
        .enum_literal => ast.nodeMainToken(node),
        else => return,
    };
    const name: []const u8 = ast.tokenSlice(asked_token);
    const is_asking_processor: bool = switch (tag) {
        .field_access => eql(u8, name, "isWasm"),
        else => eql(u8, name, "wasm32") or eql(u8, name, "wasm64"),
    };
    if (!is_asking_processor) {
        return;
    }
    try ctx.emitAt(
        asked_token,
        "arch-check",
        0,
        "asking the processor ({s}) where a host's fact is meant: use host.is_browser, host.has_gpu, " ++
            "host.has_window or host.drives_own_frames; code that depends on wasm itself opts out with " ++
            "`// lint:off arch-check: <why>`",
        .{name},
    );
}

/// The files of the browser's platform layer, which may import `web.zig` - under either separator, as on Windows a
/// path comes with `\`.
fn isBrowserLayer(path: []const u8) bool {
    const browser_layer_files = [_][]const u8{
        "src/web.zig",
        "src/bridge.zig",
        "src/platform/web.zig",
        "src\\web.zig",
        "src\\bridge.zig",
        "src\\platform\\web.zig",
    };
    for (browser_layer_files) |layer_file| {
        if (endsWith(u8, path, layer_file)) {
            return true;
        }
    }
    return false;
}

/// `browser-call` - importing the browser's own module (`web.zig`) outside the browser's platform layer.
fn checkBrowserCall(
    ctx: Ctx,
    node: Index,
    tag: Ast.Node.Tag,
) !void {
    const is_builtin_call: bool = tag == .builtin_call_two or tag == .builtin_call_two_comma or
        tag == .builtin_call or tag == .builtin_call_comma;
    if (!is_builtin_call or !inSrcDir(ctx.path) or isBrowserLayer(ctx.path)) {
        return;
    }
    const ast: *const Ast = ctx.ast;
    const builtin_token: u32 = ast.nodeMainToken(node);
    if (!eql(u8, ast.tokenSlice(builtin_token), "@import")) {
        return;
    }
    // The imported path is the string literal right after `@import(`.
    const path_token: u32 = builtin_token + 2;
    const imported: []const u8 = ast.tokenSlice(path_token);
    // `web.zig` from src/, `../web.zig` from below it; `platform/web.zig` is the browser's platform, not its module.
    const is_web_module: bool = eql(u8, imported, "\"web.zig\"") or eql(u8, imported, "\"../web.zig\"");
    if (!is_web_module) {
        return;
    }
    try ctx.emitAt(
        builtin_token,
        "browser-call",
        0,
        "the browser's own module imported outside its platform layer: what it calls exists in the browser " ++
            "alone - go through the platform contract (platform.current)",
        .{},
    );
}

/// The files where system clocks are read: the platform layer.
fn isClockLayer(path: []const u8) bool {
    const is_unix_platform_dir: bool = indexOf(u8, path, "src/platform/") != null;
    const is_platform_dir: bool = is_unix_platform_dir or indexOf(u8, path, "src\\platform\\") != null;
    return is_platform_dir or endsWith(u8, path, "native_os.zig") or endsWith(u8, path, "win32.zig");
}

/// `own-clock` - a system clock read in engine code outside the platform layer.
fn checkOwnClock(
    ctx: Ctx,
    node: Index,
    tag: Ast.Node.Tag,
) !void {
    if (!inSrcDir(ctx.path) or isClockLayer(ctx.path)) {
        return;
    }
    const ast: *const Ast = ctx.ast;
    const name_token: u32 = switch (tag) {
        .field_access => ast.nodeData(node).node_and_token[1],
        .identifier => ast.nodeMainToken(node),
        else => return,
    };
    const name: []const u8 = ast.tokenSlice(name_token);
    const system_clocks = [_][]const u8{
        "clock_gettime",              "QueryPerformanceCounter",      "QueryPerformanceFrequency",
        "RtlQueryPerformanceCounter", "RtlQueryPerformanceFrequency", "GetSystemTimePreciseAsFileTime",
        "GetSystemTimeAsFileTime",    "GetTickCount",                 "GetTickCount64",
    };
    var is_system_clock: bool = false;
    for (system_clocks) |clock_name| {
        if (eql(u8, name, clock_name)) {
            is_system_clock = true;
        }
    }
    // `Io.Timestamp.now`: the field `now` of a `Timestamp`.
    if (tag == .field_access and eql(u8, name, "now")) {
        const owner: Index = ast.nodeData(node).node_and_token[0];
        const owner_name_token: ?u32 = switch (ast.nodeTag(owner)) {
            .field_access => ast.nodeData(owner).node_and_token[1],
            .identifier => ast.nodeMainToken(owner),
            else => null,
        };
        if (owner_name_token) |owner_token| {
            is_system_clock = eql(u8, ast.tokenSlice(owner_token), "Timestamp");
        }
    }
    if (!is_system_clock) {
        return;
    }
    try ctx.emitAt(
        name_token,
        "own-clock",
        0,
        "{s} reads a system clock outside the platform layer: use platform.current.now(), or the frame's " ++
            "f.time; code needing the wall clock for itself opts out with `// lint:off own-clock: <why>`",
        .{name},
    );
}

/// `process-exit` - `std.process.exit` in engine code.
fn checkProcessExit(
    ctx: Ctx,
    node: Index,
    tag: Ast.Node.Tag,
) !void {
    if (tag != .field_access or !inSrcDir(ctx.path)) {
        return;
    }
    const ast: *const Ast = ctx.ast;
    const data: Ast.Node.Data = ast.nodeData(node);
    const field_token: u32 = data.node_and_token[1];
    if (!eql(u8, ast.tokenSlice(field_token), "exit")) {
        return;
    }
    const owner: Index = data.node_and_token[0];
    const owner_name_token: u32 = switch (ast.nodeTag(owner)) {
        .field_access => ast.nodeData(owner).node_and_token[1],
        .identifier => ast.nodeMainToken(owner),
        else => return,
    };
    if (!eql(u8, ast.tokenSlice(owner_name_token), "process")) {
        return;
    }
    try ctx.emitAt(
        field_token,
        "process-exit",
        0,
        "std.process.exit skips every defer on the way out: return an error or an outcome to the entry point, " ++
            "which alone decides the exit status",
        .{},
    );
}

/// `debug-print` - bans `std.debug.print` in engine code (`src/`).
///
/// std.debug.print bypasses `std_options` and writes to the raw stderr
/// writer, whose wasm path traps under ReleaseSmall - a SILENT freeze in
/// a release standalone (a real bug: a UI font-misconfig diagnostic took
/// `no-std-timer` - flags `std.time.Timer` (and it fires only on that exact
/// field-access path). This pinned std (0.17-dev) has no `std.time.Timer`
/// (nor `nanoTimestamp`/`milliTimestamp`), so reaching for it fails to compile
/// with an inscrutable "struct 'time' has no member" error. In examples, use
/// the frame clock (`f.time` on the `Frame`) for elapsed/delta time. Native
/// host-only sites that genuinely need a monotonic clock opt out with
/// `// lint:off no-std-timer: <reason>`. Detection mirrors checkDebugPrint:
/// identifier `std`, field `time`, field `Timer`, firing at the `Timer` token.
fn checkStdTimer(
    ctx: Ctx,
    node: Index,
    tag: Ast.Node.Tag,
) !void {
    if (tag != .field_access) {
        return;
    }
    const ast: *const Ast = ctx.ast;
    const data: Ast.Node.Data = ast.nodeData(node);
    const lhs: Index = data.node_and_token[0];
    const field_tok: u32 = data.node_and_token[1];
    if (!eql(u8, ast.tokenSlice(field_tok), "Timer")) {
        return;
    }
    if (ast.nodeTag(lhs) != .field_access) {
        return;
    }
    const lhs_data: Ast.Node.Data = ast.nodeData(lhs);
    const lhs_lhs: Index = lhs_data.node_and_token[0];
    const lhs_field_tok: u32 = lhs_data.node_and_token[1];
    if (!eql(u8, ast.tokenSlice(lhs_field_tok), "time")) {
        return;
    }
    if (ast.nodeTag(lhs_lhs) != .identifier) {
        return;
    }
    if (!eql(u8, ast.tokenSlice(ast.nodeMainToken(lhs_lhs)), "std")) {
        return;
    }
    try ctx.emitAt(
        field_tok,
        "no-std-timer",
        0,
        "std.time.Timer does not exist in this pinned std (0.17-dev) - it " ++
            "fails to compile with a 'struct time has no member Timer' error " ++
            "(std.time.nanoTimestamp / milliTimestamp are gone too). In an " ++
            "example, time things via the frame clock (`f.time` on the Frame). " ++
            "A native host-only site that truly needs a monotonic clock opts " ++
            "out with `// lint:off no-std-timer: <reason>`.",
        .{},
    );
}

/// down `wgpu-ui-demo` this way).  The one sanctioned sink is `std.log.*`,
/// which funnels through `std_options.logFn` -> `web.zig`'s `dom.log` ->
/// `js_log` on wasm (and stderr on host).  Scoped to `src/` because the
/// engine compiles into every app; native tools and the host-only logging
/// fallback opt out with `// lint:off debug-print: <reason>`.  Detection
/// mirrors checkStdMath: the `field_access` `std.debug.print` (identifier
/// `std`, field `debug`, field `print`), firing at the `print` token.
fn checkDebugPrint(
    ctx: Ctx,
    node: Index,
    tag: Ast.Node.Tag,
) !void {
    if (tag != .field_access) {
        return;
    }
    if (!inSrcDir(ctx.path)) {
        return;
    }
    const ast: *const Ast = ctx.ast;
    const data: Ast.Node.Data = ast.nodeData(node);
    const lhs: Index = data.node_and_token[0];
    const field_tok: u32 = data.node_and_token[1];
    if (!eql(u8, ast.tokenSlice(field_tok), "print")) {
        return;
    }
    // lhs must itself be the `std.debug` field_access.
    if (ast.nodeTag(lhs) != .field_access) {
        return;
    }
    const lhs_data: Ast.Node.Data = ast.nodeData(lhs);
    const lhs_lhs: Index = lhs_data.node_and_token[0];
    const lhs_field_tok: u32 = lhs_data.node_and_token[1];
    if (!eql(u8, ast.tokenSlice(lhs_field_tok), "debug")) {
        return;
    }
    if (ast.nodeTag(lhs_lhs) != .identifier) {
        return;
    }
    if (!eql(u8, ast.tokenSlice(ast.nodeMainToken(lhs_lhs)), "std")) {
        return;
    }
    try ctx.emitAt(
        field_tok,
        "debug-print",
        0,
        "std.debug.print is banned in engine code (src/): it bypasses " ++
            "std_options and its raw-stderr writer traps under ReleaseSmall " ++
            "on wasm - a silent freeze in a release standalone. Use " ++
            "std.log.warn / std.log.err / std.log.debug instead (they route " ++
            "through std_options.logFn -> dom.log -> js_log on wasm, stderr " ++
            "on host). Host-only/native sites opt out with a " ++
            "`// lint:off debug-print: <reason>` directive.",
        .{},
    );
}

/// True when `path` lives under an `examples/` directory (the demo programs,
/// which also compile to wasm/gpu).  Mirrors `inSrcDir` for both path forms.
fn inExamplesDir(path: []const u8) bool {
    return indexOf(u8, path, "/examples/") != null or
        indexOf(u8, path, "\\examples\\") != null or
        startsWith(u8, path, "examples/") or
        startsWith(u8, path, "examples\\");
}

/// `std-debug-assert` - bans `std.debug.assert` in engine + example code.
///
/// The whole codebase shares ONE assert family in zimrmath: `zm.assert(ok,
/// @src())` (no message) and `zm.assertf(ok, @src(), fmt, args)`.  Both lower
/// to a bare `unreachable` on GPU and in ship builds (byte-identical to
/// std.debug.assert) but log file:line + `@panic` in dev - localisation that
/// std.debug.assert can't give on unsymbolicated wasm.  Mixing in
/// std.debug.assert splits the codebase across two assert mechanisms for no
/// gain.  Scoped to `src/` + `examples/` (the code that ships to wasm/gpu);
/// native tools (under `tools/`, plus the in-`src/` SPIR-V transpiler
/// `spv2wgsl`) compile for the host only and may use std.debug.assert freely.
/// Genuine comptime/container-scope checks where `@src()` is illegal should use
/// `@compileError`, or opt out with `// lint:off std-debug-assert: <reason>`.
/// Detection mirrors checkDebugPrint: the `field_access` `std.debug.assert`
/// (identifier `std`, field `debug`, field `assert`), firing at the `assert`
/// token.
fn checkStdDebugAssert(
    ctx: Ctx,
    node: Index,
    tag: Ast.Node.Tag,
) !void {
    if (tag != .field_access) {
        return;
    }
    // Only engine + example code ships to wasm/gpu, where the canonical zm
    // assert must be used.  Native tools are host-only and opt out.
    if (!inSrcDir(ctx.path) and !inExamplesDir(ctx.path)) {
        return;
    }
    // spv2wgsl lives in src/ but is a build-time native tool, never wasm/gpu.
    if (endsWith(u8, ctx.path, "spv2wgsl.zig")) {
        return;
    }
    const ast: *const Ast = ctx.ast;
    const data: Ast.Node.Data = ast.nodeData(node);
    const lhs: Index = data.node_and_token[0];
    const field_tok: u32 = data.node_and_token[1];
    if (!eql(u8, ast.tokenSlice(field_tok), "assert")) {
        return;
    }
    // lhs must itself be the `std.debug` field_access.
    if (ast.nodeTag(lhs) != .field_access) {
        return;
    }
    const lhs_data: Ast.Node.Data = ast.nodeData(lhs);
    const lhs_lhs: Index = lhs_data.node_and_token[0];
    const lhs_field_tok: u32 = lhs_data.node_and_token[1];
    if (!eql(u8, ast.tokenSlice(lhs_field_tok), "debug")) {
        return;
    }
    if (ast.nodeTag(lhs_lhs) != .identifier) {
        return;
    }
    if (!eql(u8, ast.tokenSlice(ast.nodeMainToken(lhs_lhs)), "std")) {
        return;
    }
    try ctx.emitAt(
        field_tok,
        "std-debug-assert",
        0,
        "std.debug.assert is banned in engine + example code: the codebase " ++
            "shares one assert family in zimrmath. Use `assert(ok, @src())` " ++
            "(bring it in with `const assert = zm.assert;`) or " ++
            "`assertf(ok, @src(), fmt, args)` - they lower to the same " ++
            "`unreachable` in ship builds but log file:line in dev. Native " ++
            "tools (tools/, spv2wgsl) opt out; comptime checks where @src() " ++
            "is illegal use @compileError (or " ++
            "`// lint:off std-debug-assert: <reason>`).",
        .{},
    );
}

fn isRoundingBuiltin(ast: *const Ast, node: Index) bool {
    const t: Ast.Node.Tag = ast.nodeTag(node);
    if (t != .builtin_call_two and t != .builtin_call_two_comma and
        t != .builtin_call and t != .builtin_call_comma)
    {
        return false;
    }
    const n: []const u8 = ast.tokenSlice(ast.nodeMainToken(node));
    return eql(u8, n, "@trunc") or eql(u8, n, "@floor") or
        eql(u8, n, "@round") or eql(u8, n, "@ceil");
}

fn checkAsRound(
    ctx: Ctx,
    node: Index,
    tag: Ast.Node.Tag,
) !void {
    if (tag != .builtin_call_two and tag != .builtin_call_two_comma) {
        return;
    }
    const ast: *const Ast = ctx.ast;
    const name: []const u8 = ast.tokenSlice(ast.nodeMainToken(node));
    if (!eql(u8, name, "@as")) {
        return;
    }
    // @as(T, value): T is the first builtin arg, the cast value is the second.
    const data: Ast.Node.Data = ast.nodeData(node);
    _, const val_opt = data.opt_node_and_opt_node;
    const val: Index = val_opt.unwrap() orelse return;
    if (!isRoundingBuiltin(ast, val)) {
        return;
    }
    try ctx.emitAt(
        ast.nodeMainToken(node),
        "as-round",
        0,
        "@as(T, @round(x)) is banned - use @trunc(x) (type inferable) or zm.int/floori/roundi/ceili(T, x)",
        .{},
    );
}

/// `@as(f32, @floatFromInt(x))` / `@as(f64, @floatFromInt(x))` are the redundant
/// int->float cast form: the `@as(T, ...)` wrapper only exists to give
/// `@floatFromInt` a result type, which `zm.float(x)` (->f32) / `zm.float64(x)`
/// (->f64) supply on their own.  Flags them and AUTOFIXES to the helper call
/// (the fix rewrites the whole `@as(...)` node; the file still needs a
/// `const float = zm.float;` / `const float64 = zm.float64;` alias in scope).
/// Bare `@floatFromInt(x)` in an inferred context is left alone - without an
/// explicit f32/f64 there is no way to pick between the two helpers.
fn checkFloatFromInt(
    ctx: Ctx,
    node: Index,
    tag: Ast.Node.Tag,
) !void {
    if (tag != .builtin_call_two and tag != .builtin_call_two_comma) {
        return;
    }
    const ast: *const Ast = ctx.ast;
    const name: []const u8 = ast.tokenSlice(ast.nodeMainToken(node));
    if (!eql(u8, name, "@as")) {
        return;
    }
    // @as(T, value): T is the first builtin arg, the cast value is the second.
    const data: Ast.Node.Data = ast.nodeData(node);
    const ty_opt, const val_opt = data.opt_node_and_opt_node;
    const ty: Index = ty_opt.unwrap() orelse return;
    const val: Index = val_opt.unwrap() orelse return;

    // T must be exactly the identifier `f32` or `f64`.
    const ty_slice: []const u8 = ast.tokenSlice(ast.nodeMainToken(ty));
    const helper: []const u8 = if (eql(u8, ty_slice, "f32"))
        "float"
    else if (eql(u8, ty_slice, "f64"))
        "float64"
    else
        return;

    // value must be `@floatFromInt(x)`.
    const vtag: Ast.Node.Tag = ast.nodeTag(val);
    if (vtag != .builtin_call_two and vtag != .builtin_call_two_comma) {
        return;
    }
    const vname: []const u8 = ast.tokenSlice(ast.nodeMainToken(val));
    if (!eql(u8, vname, "@floatFromInt")) {
        return;
    }

    // x = @floatFromInt's single argument.
    const vdata: Ast.Node.Data = ast.nodeData(val);
    const x_opt, _ = vdata.opt_node_and_opt_node;
    const x: Index = x_opt.unwrap() orelse return;

    // Whole `@as(...)` node byte span -> replaced wholesale by `helper(x_src)`.
    const as_last: u32 = ast.lastToken(node);
    const as_start: u32 = @intCast(ast.tokenStart(ast.firstToken(node)));
    const as_end: u32 = @intCast(ast.tokenStart(as_last) + ast.tokenSlice(as_last).len);

    const x_last: u32 = ast.lastToken(x);
    const x_start: usize = ast.tokenStart(ast.firstToken(x));
    const x_end: usize = ast.tokenStart(x_last) + ast.tokenSlice(x_last).len;
    const x_src: []const u8 = ctx.source[x_start..x_end];

    // The fix spells the helper the way the file can resolve it: bare when the file
    // binds `const float = zm.float;`, qualified when it only imports zm. A bare
    // `float(x)` with no binding is an undeclared identifier, which the fix loop's
    // guard catches by throwing away the whole pass - every other fix with it. A
    // file that doesn't import zm at all gets the report without a fix.
    const message: []const u8 = "@as({s}, @floatFromInt(x)) is redundant - use zm.{s}(x)";
    // A temporary: `emitFix` copies it if the issue is kept, so it is freed here either way.
    const replacement: []const u8 = if (fileScopeBindsZm(ast, ctx.zm_aliases, helper))
        try allocPrint(ctx.alloc, "{s}({s})", .{ helper, x_src })
    else if (ctx.zm_aliases.len > 0)
        try allocPrint(ctx.alloc, "{s}.{s}({s})", .{ ctx.zm_aliases[0], helper, x_src })
    else
        return ctx.emitAt(ast.nodeMainToken(node), "float-from-int", 0, message, .{ ty_slice, helper });
    defer ctx.alloc.free(replacement);

    try ctx.emitFix(
        ast.nodeMainToken(node),
        "float-from-int",
        0,
        .{ .start = as_start, .end = as_end, .replacement = replacement },
        message,
        .{ ty_slice, helper },
    );
}

/// The name token of a file-scope declaration, or null for `test` /
/// `comptime` / `usingnamespace` (which have no name to reference).
fn declNameToken(ast: *const Ast, node: Index) ?u32 {
    if (ast.nodeTag(node) == .fn_decl) {
        var buf: [1]Index = undefined;
        const proto: Ast.full.FnProto = ast.fullFnProto(&buf, node) orelse return null;
        return proto.name_token;
    }
    const vd: Ast.full.VarDecl = ast.fullVarDecl(node) orelse return null;
    return vd.ast.mut_token + 1;
}

/// Whether a bare `name` already resolves above `use_token`: the file binds it from zm (`const splat = zm.splat;`)
/// or declares a function of that name itself (zimrmath.zig, where the helpers live) - either one ABOVE the use,
/// so the rewrite never puts a use before its declaration (`decl-order`).
fn bareNameResolvesAbove(ctx: Ctx, name: []const u8, use_token: u32) bool {
    const ast: *const Ast = ctx.ast;
    if (fileScopeBinding(ast, ctx.zm_aliases, .zm, name)) |binding_token| {
        return binding_token < use_token;
    }
    for (ast.rootDecls()) |decl| {
        if (ast.nodeTag(decl) != .fn_decl) {
            continue;
        }
        const name_token: u32 = declNameToken(ast, decl) orelse continue;
        if (eql(u8, ast.tokenSlice(name_token), name)) {
            return ast.firstToken(decl) < use_token;
        }
    }
    return false;
}

/// `prefer-splat`: `@as(Vec, @splat(x))` - the `@as` only gives `@splat` a result type, which zm's broadcast
/// helpers carry themselves: `splat(x)` -> Vec, `splat3` -> Vec3, `splat2` -> Vec2, `splat2i` -> Vec2i. The
/// type may be bare or qualified (`zm.Vec`, `rbt.Vec`): the names are reserved for zm's types
/// (`reserved-math-names`), so a `Vec` reached through any module is zm's. Each helper takes the lane type
/// (`f32`, or `i32` for `splat2i`), which `@splat` coerces `x` to as well, so the two spellings accept the same
/// arguments. Autofixes like `float-from-int`: bare when the name resolves above the use, `zm.<helper>(x)` when the
/// file only imports zm (`no-qualified-zm` then binds it), a report alone when it has no zm import.
fn checkPreferSplat(ctx: Ctx, node: Index, tag: Ast.Node.Tag) !void {
    if (tag != .builtin_call_two and tag != .builtin_call_two_comma) {
        return;
    }
    const ast: *const Ast = ctx.ast;
    if (!eql(u8, ast.tokenSlice(ast.nodeMainToken(node)), "@as")) {
        return;
    }
    // @as(T, value): T is the first builtin arg, the cast value is the second.
    const ty_opt, const val_opt = ast.nodeData(node).opt_node_and_opt_node;
    const ty: Index = ty_opt.unwrap() orelse return;
    const val: Index = val_opt.unwrap() orelse return;

    // T is `Vec` / `Vec3` / `Vec2` / `Vec2i`, bare or as the last segment of a member access.
    const type_token: u32 = switch (ast.nodeTag(ty)) {
        .identifier => ast.nodeMainToken(ty),
        .field_access => ast.nodeData(ty).node_and_token[1],
        else => return,
    };
    const type_name: []const u8 = ast.tokenSlice(type_token);
    const helper: []const u8 = if (eql(u8, type_name, "Vec"))
        "splat"
    else if (eql(u8, type_name, "Vec3"))
        "splat3"
    else if (eql(u8, type_name, "Vec2"))
        "splat2"
    else if (eql(u8, type_name, "Vec2i"))
        "splat2i"
    else
        return;

    // value is `@splat(x)`, with its one argument.
    const val_tag: Ast.Node.Tag = ast.nodeTag(val);
    if (val_tag != .builtin_call_two and val_tag != .builtin_call_two_comma) {
        return;
    }
    if (!eql(u8, ast.tokenSlice(ast.nodeMainToken(val)), "@splat")) {
        return;
    }
    const x_opt, const extra_opt = ast.nodeData(val).opt_node_and_opt_node;
    const x: Index = x_opt.unwrap() orelse return;
    if (extra_opt.unwrap() != null) {
        return; // two arguments: not a valid `@splat`, the compiler's to report
    }

    // The whole `@as(...)` node is replaced by `helper(x_src)`.
    const as_last: u32 = ast.lastToken(node);
    const as_start: u32 = @intCast(ast.tokenStart(ast.firstToken(node)));
    const as_end: u32 = @intCast(ast.tokenStart(as_last) + ast.tokenSlice(as_last).len);
    const x_last: u32 = ast.lastToken(x);
    const x_start: usize = ast.tokenStart(ast.firstToken(x));
    const x_end: usize = ast.tokenStart(x_last) + ast.tokenSlice(x_last).len;
    const x_src: []const u8 = ctx.source[x_start..x_end];

    const message: []const u8 = "@as({s}, @splat(x)) spells the type to say nothing - use {s}(x) " ++
        "(`// lint:off prefer-splat: <why>` for a deliberate one)";
    // A temporary: `emitFix` copies it if the issue is kept, so it is freed here either way.
    const replacement: []const u8 = if (bareNameResolvesAbove(ctx, helper, ast.firstToken(node)))
        try allocPrint(ctx.alloc, "{s}({s})", .{ helper, x_src })
    else if (ctx.zm_aliases.len > 0)
        try allocPrint(ctx.alloc, "{s}.{s}({s})", .{ ctx.zm_aliases[0], helper, x_src })
    else
        return ctx.emitAt(ast.nodeMainToken(node), "prefer-splat", 0, message, .{ type_name, helper });
    defer ctx.alloc.free(replacement);

    try ctx.emitFix(
        ast.nodeMainToken(node),
        "prefer-splat",
        0,
        .{ .start = as_start, .end = as_end, .replacement = replacement },
        message,
        .{ type_name, helper },
    );
}

/// Byte length of the source line containing `byte_offset`, newline excluded -
/// matches the line-length rule's measure (raw bytes, no tab expansion).
fn lineLenAt(source: [:0]const u8, byte_offset: usize) usize {
    var start: usize = byte_offset;
    while (start > 0 and source[start - 1] != '\n') {
        start -= 1;
    }
    var end: usize = byte_offset;
    while (end < source.len and source[end] != '\n') {
        end += 1;
    }
    return end - start;
}

/// True if every param of a fn signature sits on ONE source line and that line
/// is at most `max_cols` bytes (same measure as the line-length rule). Backs
/// the fn-args-multiline 3-4-arg carve-out.
fn fnSigFitsOnOneLine(
    ctx: Ctx,
    params: []const Ast.full.FnProto.Param,
    max_cols: usize,
) bool {
    const ast: *const Ast = ctx.ast;
    var first_tok: ?u32 = null;
    var first_line: u32 = 0;
    var last_line: u32 = 0;
    for (params) |p| {
        const tok: u32 = if (p.name_token) |n| n else p.first_doc_comment orelse continue;
        const line: u32 = ctx.tokenLineCol(tok).line;
        if (first_tok == null) {
            first_tok = tok;
            first_line = line;
        }
        last_line = line;
    }
    const ft: u32 = first_tok orelse return false;
    if (first_line != last_line) {
        return false;
    }
    return lineLenAt(ctx.source, ast.tokenStart(ft)) <= max_cols;
}

/// Return true if `byte_offset` falls inside a `// zig fmt: off`
/// region.  Scans the source from the start, toggling state at each
/// `// zig fmt: off` / `// zig fmt: on` marker.  O(N) per call but
/// rarely hot - fn-args-multiline only calls it when a violation
/// would otherwise fire.
fn isInsideFmtOff(source: []const u8, byte_offset: usize) bool {
    var off: bool = false;
    var i: usize = 0;
    while (i < source.len and i < byte_offset) : (i += 1) {
        if (source[i] != '/') {
            continue;
        }
        if (startsWith(u8, source[i..], "// zig fmt: off")) {
            off = true;
            i += "// zig fmt: off".len;
        } else if (startsWith(u8, source[i..], "// zig fmt: on")) {
            off = false;
            i += "// zig fmt: on".len;
        }
    }
    return off;
}

/// Carve-out for `fn-args-multiline`: a signature is "simple
/// uniform primitive" if every param has the same primitive
/// type, no param has a doc comment, and the full signature
/// line fits in 80 cols.  In that case the diff-ability
/// rationale doesn't apply - `fn vec(x: f32, y: f32, z: f32)`
/// is a stable mathematical shape, not a list of named
/// parameters that might gain/lose members.
fn isSimpleUniformPrimitiveSig(
    ctx: Ctx,
    proto: Ast.full.FnProto,
    params: []const Ast.full.FnProto.Param,
) bool {
    _ = proto;
    const ast: *const Ast = ctx.ast;

    // (1) every param has a type_expr (no anytype/comptime),
    // (2) every type text is identical,
    // (3) the common type is a primitive,
    // (4) no param has a doc comment.
    var first_type_text: ?[]const u8 = null;
    for (params) |p| {
        if (p.first_doc_comment != null) {
            return false;
        }
        const type_node: Index = p.type_expr orelse return false;
        const first_tok: u32 = ast.firstToken(type_node);
        const last_tok: u32 = ast.lastToken(type_node);
        const start: usize = ast.tokenStart(first_tok);
        const last_slice: []const u8 = ast.tokenSlice(last_tok);
        const end: usize = ast.tokenStart(last_tok) + last_slice.len;
        const type_text: []const u8 = ctx.source[start..end];
        if (first_type_text) |first| {
            if (!eql(u8, first, type_text)) {
                return false;
            }
        } else {
            if (!primitives.has(type_text)) {
                return false;
            }
            first_type_text = type_text;
        }
    }

    // (5) full signature line <= 80 cols.  The signature is
    // already on one line (else the rule wouldn't have been
    // about to fire); measure that line.
    if (params.len == 0) {
        return false;
    }
    const probe_tok: u32 = if (params[0].name_token) |n| n else return false;
    const probe_byte: usize = ast.tokenStart(probe_tok);
    var line_start: usize = probe_byte;
    while (line_start > 0 and ctx.source[line_start - 1] != '\n') : (line_start -= 1) {}
    var line_end: usize = probe_byte;
    while (line_end < ctx.source.len and ctx.source[line_end] != '\n') : (line_end += 1) {}
    if (line_end - line_start > 80) {
        return false;
    }

    return true;
}

/// The `)` closing the `(` at `open_paren`, nested parentheses counted on the way. (The file parsed, so they
/// balance; the end of the file is the answer only for a source that would not have got this far.)
fn closingParen(ast: *const Ast, open_paren: u32) u32 {
    var depth: u32 = 0;
    var token: u32 = open_paren;
    while (true) : (token += 1) {
        switch (ast.tokenTag(token)) {
            .l_paren => depth += 1,
            .r_paren => {
                depth -= 1;
                if (depth == 0) {
                    return token;
                }
            },
            .eof => return token,
            else => {},
        }
    }
}

fn checkFnArgsMultiline(
    ctx: Ctx,
    node: Index,
    tag: Ast.Node.Tag,
) !void {
    const ast: *const Ast = ctx.ast;
    // Only fn declarations (proto nodes).  Call sites covered by
    // line-length instead.
    var buf: [1]Index = undefined;
    const proto_full: ?Ast.full.FnProto = switch (tag) {
        .fn_proto => ast.fnProto(node),
        .fn_proto_multi => ast.fnProtoMulti(node),
        .fn_proto_one => ast.fnProtoOne(&buf, node),
        .fn_proto_simple => ast.fnProtoSimple(&buf, node),
        else => null,
    };
    const proto: Ast.full.FnProto = proto_full orelse return;

    var params: ArrayList(Ast.full.FnProto.Param) = .empty;
    defer params.deinit(ctx.alloc);
    var it: Ast.full.FnProto.Iterator = proto.iterate(ast);
    while (it.next()) |p| {
        try params.append(ctx.alloc, p);
    }
    if (params.items.len < 3) {
        return;
    }

    // Carve-out: 3 or 4 params on a SINGLE line are allowed when the whole
    // signature line fits in 90 columns. The one-per-line rule exists for
    // diff-ability of wide/growing signatures; a short 3-4 arg sig that fits
    // comfortably reads fine on one line. 5+ params (or anything wider than
    // 90 cols) still break one-per-line.
    if (params.items.len <= 4 and fnSigFitsOnOneLine(ctx, params.items, 90)) {
        return;
    }

    // Check that each consecutive pair of params is on different lines.
    var prev_line: u32 = 0;
    for (params.items, 0..) |p, i| {
        const tok: u32 = if (p.name_token) |n| n else p.first_doc_comment orelse {
            // skip params without a name token (rare)
            continue;
        };
        const line: u32 = ctx.tokenLineCol(tok).line;
        if (i > 0 and line == prev_line) {
            const main_tok: u32 = ast.nodeMainToken(node);
            // Respect `// zig fmt: off` blocks (turn 349) - this
            // rule's fix is "add a trailing comma so zig fmt
            // breaks the sig," which is meaningless when fmt is
            // disabled.  The math.zig SIMD constructors
            // (f32x16, boolx16) use this to keep 8-per-row vector
            // lane layout.
            if (isInsideFmtOff(ctx.source, ast.tokenStart(main_tok))) {
                return;
            }
            // Carve-out for simple uniform primitive constructors
            // (turn 362).  `fn vec(x: f32, y: f32, z: f32) Vec` and
            // friends are stable mathematical shapes - diff-ability
            // rationale doesn't apply.  See
            // `isSimpleUniformPrimitiveSig` for the exact criteria.
            if (isSimpleUniformPrimitiveSig(ctx, proto, params.items)) {
                return;
            }
            // The fix: one comma right before the parameter list's closing parenthesis. A trailing comma is zig
            // fmt's signal to lay a list out one item per line, so `zig build fix` - `--fix`, then fmt - ends with
            // exactly the layout this rule asks for. A trailing comma already there means fmt has not run yet: fmt
            // alone is the fix, there is nothing to insert.
            const closing: u32 = closingParen(ast, proto.lparen);
            if (ast.tokenTag(closing - 1) == .comma) {
                try ctx.emitAt(
                    main_tok,
                    "fn-args-multiline",
                    1,
                    "fn declaration with {d} params: put each on its own line",
                    .{params.items.len},
                );
                return;
            }
            const insert_at: u32 = @intCast(ast.tokenStart(closing));
            const fix: Fix = .{ .start = insert_at, .end = insert_at, .replacement = "," };
            try ctx.emitFix(
                main_tok,
                "fn-args-multiline",
                1,
                fix,
                "fn declaration with {d} params: put each on its own line",
                .{params.items.len},
            );
            return;
        }
        prev_line = line;
    }
}

const BlockSlice = struct {
    inline_buf: [2]Index = .{ undefined, undefined },
    inline_len: usize = 0,
    heap_slice: ?[]const Index = null,

    fn items(self: *const BlockSlice) []const Index {
        if (self.heap_slice) |s| {
            return s;
        }
        return self.inline_buf[0..self.inline_len];
    }
};

fn blockStmts(ast: *const Ast, node: Index) BlockSlice {
    const tag: Ast.Node.Tag = ast.nodeTag(node);
    switch (tag) {
        .block, .block_semicolon => {
            const data: Ast.Node.Data = ast.nodeData(node);
            return .{ .heap_slice = ast.extraDataSlice(data.extra_range, Index) };
        },
        .block_two, .block_two_semicolon => {
            const data: Ast.Node.Data = ast.nodeData(node);
            const a, const b = data.opt_node_and_opt_node;
            var bs: BlockSlice = .{};
            if (a.unwrap()) |x| {
                bs.inline_buf[bs.inline_len] = x;
                bs.inline_len += 1;
            }
            if (b.unwrap()) |x| {
                bs.inline_buf[bs.inline_len] = x;
                bs.inline_len += 1;
            }
            return bs;
        },
        else => return .{},
    }
}

fn walkBlockBody(
    ctx: Ctx,
    body: Index,
    fn_depth: u8,
) !void {
    const bs: BlockSlice = blockStmts(ctx.ast, body);
    for (bs.items()) |stmt| {
        // walkNode and walkBlockBody are mutually recursive: the visitor
        // descends into block bodies here, and walkNode recurses back per
        // statement. No declaration order can define both before the other.
        // lint:off decl-order: mutual recursion with walkBlockBody
        try walkNode(ctx, stmt, .statement, fn_depth);
    }
}

fn walkContainerChildren(
    ctx: Ctx,
    container: Index,
    fn_depth: u8,
) !void {
    const ast: *const Ast = ctx.ast;
    var member_buffer: [2]Index = undefined;
    const declaration: Ast.full.ContainerDecl = ast.fullContainerDecl(&member_buffer, container) orelse return;
    // `enum(u8)`'s tag type, `union(E)`'s enum, a packed struct's backing integer: an expression like any other.
    if (declaration.ast.arg.unwrap()) |argument| {
        try walkNode(ctx, argument, .expression, fn_depth);
    }
    for (declaration.ast.members) |member| {
        try walkNode(ctx, member, .container, fn_depth);
    }
}

/// Walk one node, run every per-node check, then recurse into
/// children.  `pos` says whether we're at container or
/// statement scope; `fn_depth` says how many fn/test bodies we're
/// nested inside (0 means module scope, >=1 means inside a fn).
// returned-stack-reference: `return &<local>` hands the caller a pointer to a
// stack variable that dies when the function returns.  We approximate scope with
// a per-function set of local var/const names (the plan's "(a)" machinery), and
// flag only a bare `return &<identifier>` naming one of them -- so `&self.field`,
// `&arr[i]`, `&global`, and `&literal` are skipped (none is a bare local ident).
const StackRefCand = struct { name: []const u8, tok: u32 };

// Walk a function body's STATEMENT constructs, collecting local var/const names
// into `locals` and every `return &<ident>` into `cands`.  Statement-level only
// (blocks, if/while/for/switch bodies) -- decls and returns don't live in plain
// expressions, so this stays small and needs no childNodes descent.
fn collectStackRef(
    ast: *const Ast,
    node: Index,
    locals: *ArrayList([]const u8),
    cands: *ArrayList(StackRefCand),
    gpa: Allocator,
    depth: u8,
) anyerror!void {
    if (depth > 64) {
        return;
    }
    if (ast.fullVarDecl(node)) |vd| {
        try locals.append(gpa, ast.tokenSlice(vd.ast.mut_token + 1));
    }
    const tag: Ast.Node.Tag = ast.nodeTag(node);
    if (tag == .@"return") {
        if (ast.nodeData(node).opt_node.unwrap()) |operand| {
            if (ast.nodeTag(operand) == .address_of) {
                const inner: Index = ast.nodeData(operand).node;
                if (ast.nodeTag(inner) == .identifier) {
                    try cands.append(gpa, .{
                        .name = ast.tokenSlice(ast.nodeMainToken(inner)),
                        .tok = ast.nodeMainToken(node),
                    });
                }
            }
        }
    }
    // Descend into statement bodies (fullIf/While/For cover simple + full forms).
    if (ast.fullIf(node)) |f| {
        try collectStackRef(ast, f.ast.then_expr, locals, cands, gpa, depth + 1);
        if (f.ast.else_expr.unwrap()) |e| {
            try collectStackRef(ast, e, locals, cands, gpa, depth + 1);
        }
        return;
    }
    if (ast.fullWhile(node)) |w| {
        try collectStackRef(ast, w.ast.then_expr, locals, cands, gpa, depth + 1);
        if (w.ast.else_expr.unwrap()) |e| {
            try collectStackRef(ast, e, locals, cands, gpa, depth + 1);
        }
        return;
    }
    if (ast.fullFor(node)) |fo| {
        try collectStackRef(ast, fo.ast.then_expr, locals, cands, gpa, depth + 1);
        if (fo.ast.else_expr.unwrap()) |e| {
            try collectStackRef(ast, e, locals, cands, gpa, depth + 1);
        }
        return;
    }
    switch (tag) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            const bs: BlockSlice = blockStmts(ast, node);
            for (bs.items()) |stmt| {
                try collectStackRef(ast, stmt, locals, cands, gpa, depth + 1);
            }
        },
        .@"switch", .switch_comma => {
            const sw: Ast.full.Switch = ast.fullSwitch(node).?;
            for (sw.ast.cases) |case_node| {
                if (ast.fullSwitchCase(case_node)) |case_full| {
                    try collectStackRef(ast, case_full.ast.target_expr, locals, cands, gpa, depth + 1);
                }
            }
        },
        else => {},
    }
}

fn isIdentifierNamed(ast: *const Ast, node: Index, name: []const u8) bool {
    return ast.nodeTag(node) == .identifier and eql(u8, ast.tokenSlice(ast.nodeMainToken(node)), name);
}

/// Whether `stmt` is (a `try` of) a call of a method on `name`: `name.init(...)`.
fn callsMethodOn(ast: *const Ast, stmt: Index, name: []const u8) bool {
    const inner: Index = if (ast.nodeTag(stmt) == .@"try") ast.nodeData(stmt).node else stmt;
    const fn_expr: Index = switch (ast.nodeTag(inner)) {
        .call, .call_comma => ast.nodeData(inner).node_and_extra[0],
        .call_one, .call_one_comma => ast.nodeData(inner).node_and_opt_node[0],
        else => return false,
    };
    if (ast.nodeTag(fn_expr) != .field_access) {
        return false;
    }
    const obj: Index, _ = ast.nodeData(fn_expr).node_and_token;
    return isIdentifierNamed(ast, obj, name);
}

// Per-function driver: collect the body's locals, then flag any `return &<local>`.
/// whole-init-first: after `name` comes to point at uninitialised memory, scan `stmts` in order for the first
/// write through it. `name.* = <not undefined>` is right and ends the scan; `name.field = ...` (or
/// `name.* = undefined`) fires; a method called on `name` hands initialisation over and ends it.
fn checkFirstWrite(ctx: Ctx, name: []const u8, stmts: []const Index, why: []const u8) !void {
    const ast: *const Ast = ctx.ast;
    for (stmts) |stmt| {
        if (ast.nodeTag(stmt) == .assign) {
            const lhs: Index, const rhs: Index = ast.nodeData(stmt).node_and_node;
            if (ast.nodeTag(lhs) == .deref and isIdentifierNamed(ast, ast.nodeData(lhs).node, name)) {
                const undef: bool = ast.nodeTag(rhs) == .identifier and
                    eql(u8, ast.tokenSlice(ast.nodeMainToken(rhs)), "undefined");
                if (undef) {
                    try ctx.emitAt(
                        ast.firstToken(stmt),
                        "whole-init-first",
                        0,
                        "`{s}.* = undefined` applies no field defaults ({s}); write `{s}.* = .{{ ... }}` instead",
                        .{ name, why, name },
                    );
                }
                return;
            }
            if (ast.nodeTag(lhs) == .field_access) {
                const obj: Index, const field_tok: u32 = ast.nodeData(lhs).node_and_token;
                if (isIdentifierNamed(ast, obj, name)) {
                    try ctx.emitAt(
                        ast.firstToken(stmt),
                        "whole-init-first",
                        0,
                        "`{s}.{s} = ...` before `{s}.* = .{{ ... }}` ({s}): defaults never apply to it and a " ++
                            "forgotten field stays garbage - write the whole struct first, later fields `= undefined`",
                        .{ name, ast.tokenSlice(field_tok), name, why },
                    );
                    return;
                }
            }
        }
        if (callsMethodOn(ast, stmt, name)) {
            return;
        }
    }
}

/// The name a declaration binds when its value is (a `try` of) `<anything>.create(...)`.
fn createdName(ast: *const Ast, stmt: Index) ?[]const u8 {
    const vd: Ast.full.VarDecl = ast.fullVarDecl(stmt) orelse return null;
    const init_node: Index = vd.ast.init_node.unwrap() orelse return null;
    const inner: Index = if (ast.nodeTag(init_node) == .@"try") ast.nodeData(init_node).node else init_node;
    const fn_expr: Index = switch (ast.nodeTag(inner)) {
        .call, .call_comma => ast.nodeData(inner).node_and_extra[0],
        .call_one, .call_one_comma => ast.nodeData(inner).node_and_opt_node[0],
        else => return null,
    };
    if (ast.nodeTag(fn_expr) != .field_access) {
        return null;
    }
    _, const method_tok: u32 = ast.nodeData(fn_expr).node_and_token;
    if (!eql(u8, ast.tokenSlice(method_tok), "create")) {
        return null;
    }
    return ast.tokenSlice(vd.ast.mut_token + 1);
}

/// whole-init-first, the create form: in one block, every `x = ... .create(...)` and what follows it.
fn checkCreateFirstWrite(ctx: Ctx, stmts: []const Index) !void {
    for (stmts, 0..) |stmt, i| {
        if (createdName(ctx.ast, stmt)) |name| {
            try checkFirstWrite(ctx, name, stmts[i + 1 ..], "memory from create() is uninitialised");
        }
    }
}

/// whole-init-first, the init form: `fn init*(self: *T, ...)` - the caller may hand it undefined memory.
fn checkInitFirstWrite(ctx: Ctx, proto: Ast.full.FnProto, body: Index) !void {
    const ast: *const Ast = ctx.ast;
    const name_tok: u32 = proto.name_token orelse return;
    if (!startsWith(u8, ast.tokenSlice(name_tok), "init")) {
        return;
    }
    var it: Ast.full.FnProto.Iterator = proto.iterate(ast);
    const first: Ast.full.FnProto.Param = it.next() orelse return;
    const param_tok: u32 = first.name_token orelse return;
    const type_expr: Index = first.type_expr orelse return;
    const ptr: Ast.full.PtrType = ast.fullPtrType(type_expr) orelse return;
    if (ptr.size != .one) {
        return;
    }
    const bs: BlockSlice = blockStmts(ast, body);
    try checkFirstWrite(ctx, ast.tokenSlice(param_tok), bs.items(), "an init's pointer may be undefined memory");
}

/// whole-init-first over EVERY node of the file, not through the walk: the walk does not descend into a struct
/// returned by a generic type function (`fn Box(comptime T: type) type { return struct { ... } }`) - where much
/// of the engine's init code lives, the resident learner's included - so neither would this rule.
fn runWholeInitFirst(ctx: Ctx) !void {
    const ast: *const Ast = ctx.ast;
    var i: usize = 0;
    while (i < ast.nodes.len) : (i += 1) {
        const n: Index = @fromBackingInt(@intCast(i));
        switch (ast.nodeTag(n)) {
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                const bs: BlockSlice = blockStmts(ast, n);
                try checkCreateFirstWrite(ctx, bs.items());
            },
            .fn_decl => {
                var buf: [1]Index = undefined;
                const proto: Ast.full.FnProto = ast.fullFnProto(&buf, n) orelse continue;
                _, const body: Index = ast.nodeData(n).node_and_node;
                try checkInitFirstWrite(ctx, proto, body);
            },
            else => {},
        }
    }
}

fn checkReturnedStackRef(ctx: Ctx, body: Index) !void {
    var locals: ArrayList([]const u8) = .empty;
    defer locals.deinit(ctx.alloc);
    var cands: ArrayList(StackRefCand) = .empty;
    defer cands.deinit(ctx.alloc);
    try collectStackRef(ctx.ast, body, &locals, &cands, ctx.alloc, 0);
    for (cands.items) |cand| {
        var is_local: bool = false;
        for (locals.items) |name| {
            if (eql(u8, name, cand.name)) {
                is_local = true;
            }
        }
        if (is_local) {
            try ctx.emitAt(
                cand.tok,
                "returned-stack-reference",
                0,
                "returning `&{s}` hands back a pointer to a stack local; it dangles once the function returns",
                .{cand.name},
            );
        }
    }
}

// `!T` (inferred error set) leaves a `.bang` token just before the inner type
// node; `E!T` is an `.error_union` node. (Confirmed by AST probe; was first written
// for the rejected no-return-try, now reused by useless-error-return.)
fn fnReturnsErrorUnion(ast: *const Ast, rt: Index) bool {
    if (ast.nodeTag(rt) == .error_union) {
        return true;
    }
    const ft: u32 = ast.firstToken(rt);
    if (ft > 0 and ast.tokenTag(ft - 1) == .bang) {
        return true;
    }
    return false;
}

// A return operand PROVABLY not an error union: a literal, an aggregate init, or an
// enum literal. None of these can carry an error, so `return <one of these>` never
// propagates. Everything else (calls, field access = maybe `MyError.Foo`, bare
// identifiers = maybe a stored error union, and `if`/`switch`/block expressions
// whose leaves might be calls) is NOT provable from AST, so it is treated as "can
// error" -- keeping the rule from ever flagging a real error path.
fn returnOperandProvablyNonError(t: Ast.Node.Tag) bool {
    return switch (t) {
        .number_literal,
        .char_literal,
        .string_literal,
        .multiline_string_literal,
        .enum_literal,
        .struct_init_one,
        .struct_init_one_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init,
        .struct_init_comma,
        .array_init_one,
        .array_init_one_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init,
        .array_init_comma,
        => true,
        else => false,
    };
}

// Statement-level recursion for a `return` whose value can't be proven non-error:
// a call may propagate, a field access may be a named error-set member, a bare
// identifier may be a stored error union. Mirrors collectStackRef -- no descent into
// nested fn/struct bodies (whose returns aren't this fn's).
fn returnMightBeError(ast: *const Ast, node: Index, depth: u8) bool {
    if (depth > 64) {
        return true; // too deep to be sure -> assume it can, so we do NOT flag
    }
    const tag: Ast.Node.Tag = ast.nodeTag(node);
    if (tag == .@"return") {
        if (ast.nodeData(node).opt_node.unwrap()) |op| {
            if (!returnOperandProvablyNonError(ast.nodeTag(op))) {
                return true;
            }
        }
        // A bare `return;` yields void -- provably non-error, so it does not skip.
    }
    if (ast.fullIf(node)) |f| {
        if (returnMightBeError(ast, f.ast.then_expr, depth + 1)) {
            return true;
        }
        if (f.ast.else_expr.unwrap()) |e| {
            if (returnMightBeError(ast, e, depth + 1)) {
                return true;
            }
        }
        return false;
    }
    if (ast.fullWhile(node)) |w| {
        if (returnMightBeError(ast, w.ast.then_expr, depth + 1)) {
            return true;
        }
        if (w.ast.else_expr.unwrap()) |e| {
            if (returnMightBeError(ast, e, depth + 1)) {
                return true;
            }
        }
        return false;
    }
    if (ast.fullFor(node)) |fo| {
        if (returnMightBeError(ast, fo.ast.then_expr, depth + 1)) {
            return true;
        }
        if (fo.ast.else_expr.unwrap()) |e| {
            if (returnMightBeError(ast, e, depth + 1)) {
                return true;
            }
        }
        return false;
    }
    switch (tag) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            const bs: BlockSlice = blockStmts(ast, node);
            for (bs.items()) |stmt| {
                if (returnMightBeError(ast, stmt, depth + 1)) {
                    return true;
                }
            }
        },
        .@"switch", .switch_comma => {
            const sw: Ast.full.Switch = ast.fullSwitch(node).?;
            for (sw.ast.cases) |case_node| {
                if (ast.fullSwitchCase(case_node)) |cf| {
                    if (returnMightBeError(ast, cf.ast.target_expr, depth + 1)) {
                        return true;
                    }
                }
            }
        },
        else => {},
    }
    return false;
}

/// True when some `catch` inside the body RE-RAISES: its handler returns something
/// not provably non-error (`catch return WriteError.Failed`, `catch |e| return e`),
/// so the fn can still error. A handler that yields a default or does a bare
/// `return;` HANDLES the error and leaves the fn errorless -- treating every
/// `catch` as error-preserving is what used to hide those.
///
/// Scans the flat node list for `.catch` nodes whose position lies in the body
/// rather than walking down to them: `childNodes` covers expressions only (no
/// blocks, var decls, or if/while/for), so a walker would silently miss catches in
/// `const x = foo() catch ...;`. A catch in a NESTED fn body also lands in this
/// range -- that only ever suppresses, which is the safe direction.
fn catchReraises(ast: *const Ast, body: Index) bool {
    const first: u32 = ast.firstToken(body);
    const last: u32 = ast.lastToken(body);
    var i: usize = 0;
    while (i < ast.nodes.len) : (i += 1) {
        const n: Index = @fromBackingInt(@intCast(i));
        if (ast.nodeTag(n) != .@"catch") {
            continue;
        }
        const ft: u32 = ast.firstToken(n);
        if (ft < first or ft > last) {
            continue;
        }
        _, const rhs: Index = ast.nodeData(n).node_and_node;
        if (returnMightBeError(ast, rhs, 0)) {
            return true;
        }
    }
    return false;
}

// useless-error-return (blocking): a fn typed `!T`/`E!T` whose body cannot
// actually produce an error -- the `!` is dead weight, forcing needless `try` on
// callers. The body "can error" when its tokens include `try`/`errdefer`/`error`
// (a token scan, so expression-nested uses count), when a `catch` re-raises, or
// when any `return` value isn't PROVABLY non-error.
fn bodyMightError(ast: *const Ast, body: Index) bool {
    const first: u32 = ast.firstToken(body);
    const last: u32 = ast.lastToken(body);
    var t: u32 = first;
    while (t <= last) : (t += 1) {
        switch (ast.tokenTag(t)) {
            .keyword_try, .keyword_errdefer, .keyword_error => {
                return true;
            },
            else => {},
        }
    }
    if (catchReraises(ast, body)) {
        return true;
    }
    return returnMightBeError(ast, body, 0);
}

/// True when the fn's name appears in the file as a VALUE rather than as a call or
/// a field name -- `.init = myFn`, `&myFn`, `register(myFn)`. Such a fn's signature
/// is pinned by whatever consumes it (an `AppSpec`-style `fn (...) anyerror!void`
/// field, a `*const fn (...) anyerror!void` pointer), and Zig will NOT coerce a
/// plain-`void` fn into an error-union fn slot -- so the `!` is not the author's to
/// drop and useless-error-return must stay quiet. Same bare-identifier
/// approximation as runUnusedPrivateGlobals: a leading `.` means field access, a
/// trailing `(` means a call. (String-based `@field` lookups stay invisible, same
/// caveat as unused-global.)
fn fnUsedAsValue(ast: *const Ast, name: []const u8, decl_name_tok: u32) bool {
    const tags: []const std.zig.Token.Tag = ast.tokens.items(.tag);
    var i: usize = 0;
    while (i < tags.len) : (i += 1) {
        if (tags[i] != .identifier) {
            continue;
        }
        if (i == decl_name_tok) {
            continue;
        }
        if (i > 0 and tags[i - 1] == .period) {
            continue;
        }
        if (i + 1 < tags.len and tags[i + 1] == .l_paren) {
            continue;
        }
        if (eql(u8, ast.tokenSlice(@intCast(i)), name)) {
            return true;
        }
    }
    return false;
}

/// True for the function-literal idiom, `struct { fn f(...) ... }.f`: a function written inside an anonymous
/// container only to be taken out as a VALUE (Zig has no lambdas). Its signature is the one its destination
/// dictates - a table field's function type, a parameter's - e.g. the `anyerror!void` every case of a conformance
/// table must share, whether or not this case's body can fail; a rule judging the signature from the body alone
/// cannot see that. Only the member named after the closing `}` counts: a helper beside it is an ordinary function.
fn isFunctionLiteral(ast: *const Ast, fn_decl: Index, name_token: u32) bool {
    const tags: []const std.zig.Token.Tag = ast.tokens.items(.tag);
    // Forward from the end of the function to the `}` that closes its container...
    var depth: u32 = 0;
    var token: u32 = ast.lastToken(fn_decl) + 1;
    while (token < tags.len) : (token += 1) {
        switch (tags[token]) {
            .l_brace => depth += 1,
            .r_brace => {
                if (depth == 0) {
                    // ...which, for a literal, is followed by `.name` - this very function, taken out.
                    if (token + 2 >= tags.len) {
                        return false;
                    }
                    const takes_a_member: bool = tags[token + 1] == .period and tags[token + 2] == .identifier;
                    return takes_a_member and eql(u8, ast.tokenSlice(token + 2), ast.tokenSlice(name_token));
                }
                depth -= 1;
            },
            else => {},
        }
    }
    return false;
}

fn checkUselessErrorReturn(ctx: Ctx, proto: Ast.full.FnProto, rt: Index, body: Index) !void {
    const ast: *const Ast = ctx.ast;
    if (!fnReturnsErrorUnion(ast, rt)) {
        return;
    }
    if (bodyMightError(ast, body)) {
        return;
    }
    if (proto.name_token) |nt| {
        if (fnUsedAsValue(ast, ast.tokenSlice(nt), nt)) {
            return;
        }
    }
    try ctx.emitAt(
        ast.firstToken(rt),
        "useless-error-return",
        0,
        "error-union return but the body never errors - the `!` forces needless `try` on callers",
        .{},
    );
}

// catch-suppression: an empty `catch {}` silently swallows the error; `catch
// unreachable` is worse -- undefined behavior in ReleaseFast if it ever fires.
// Force a conscious choice: assertf, handle it, a default value, a control-flow
// diversion, or an explicit `// lint:off`.  Pure-AST: a `.@"catch"` node whose
// handler is an empty block or a bare `unreachable`.
fn checkCatchSuppression(ctx: Ctx, node: Index, tag: Ast.Node.Tag) !void {
    if (tag != .@"catch") {
        return;
    }
    const ast: *const Ast = ctx.ast;
    _, const rhs = ast.nodeData(node).node_and_node;
    const rhs_tag: Ast.Node.Tag = ast.nodeTag(rhs);
    const catch_tok: u32 = ast.nodeMainToken(node);
    if (isBlockTag(rhs_tag)) {
        if (blockStmts(ast, rhs).items().len == 0) {
            try ctx.emitAt(
                catch_tok,
                "catch-suppression",
                0,
                "empty `catch {{}}` swallows the error - assertf, handle it, give a default, or lint:off",
                .{},
            );
        }
        return;
    }
    if (rhs_tag == .unreachable_literal) {
        try ctx.emitAt(
            catch_tok,
            "catch-suppression",
            0,
            "`catch unreachable` is UB in ReleaseFast if it fires - use `catch {{ assertf(...) }}` instead",
            .{},
        );
    }
}

// prefer-assert-unreachable: `assert(false, ...)` / `assertf(false, ...)` is the
// long way to write `assertUnreachable(@src(), fmt, args)`, which names the intent
// and forces a message.  Collapse to it.  (Value-result catches want the noreturn
// `panicf` instead; both live in zimrmath.)
fn checkPreferAssertUnreachable(ctx: Ctx, node: Index, tag: Ast.Node.Tag) !void {
    switch (tag) {
        .call, .call_comma, .call_one, .call_one_comma => {},
        else => return,
    }
    const ast: *const Ast = ctx.ast;
    var buf: [8]Index = undefined;
    const kids: []const Index = childNodes(ast, node, &buf);
    if (kids.len < 2) {
        return; // need a callee AND a first argument
    }
    const fn_expr: Index = kids[0];
    const fname: []const u8 = switch (ast.nodeTag(fn_expr)) {
        .identifier => ast.tokenSlice(ast.nodeMainToken(fn_expr)),
        .field_access => ast.tokenSlice(ast.nodeData(fn_expr).node_and_token[1]),
        else => return,
    };
    if (!eql(u8, fname, "assert") and !eql(u8, fname, "assertf")) {
        return;
    }
    const first: Index = kids[1];
    if (ast.nodeTag(first) != .identifier) {
        return;
    }
    if (!eql(u8, ast.tokenSlice(ast.nodeMainToken(first)), "false")) {
        return;
    }
    try ctx.emitAt(
        ast.nodeMainToken(node),
        "prefer-assert-unreachable",
        0,
        "`{s}(false, ...)` is `assertUnreachable(@src(), ...)` spelled long - use the named form",
        .{fname},
    );
}

// Unwrap a catch handler to its `return` node: either a bare `return X` or a
// single-statement block `{ return X; }`.
fn returnNodeOf(ast: *const Ast, rhs: Index) ?Index {
    if (ast.nodeTag(rhs) == .@"return") {
        return rhs;
    }
    switch (ast.nodeTag(rhs)) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            const bs: BlockSlice = blockStmts(ast, rhs);
            if (bs.items().len == 1 and ast.nodeTag(bs.items()[0]) == .@"return") {
                return bs.items()[0];
            }
        },
        else => {},
    }
    return null;
}

// no-catch-return: `catch |e| return e` (returning the SAME captured error) is
// exactly what `try` does -- collapse it. Fires ONLY on the truly-equivalent form,
// never `catch |e| return someDefault` (a handled default, sanctioned by rule 1).
fn checkNoCatchReturn(ctx: Ctx, node: Index, tag: Ast.Node.Tag) !void {
    if (tag != .@"catch") {
        return;
    }
    const ast: *const Ast = ctx.ast;
    const catch_tok: u32 = ast.nodeMainToken(node);
    // Must capture the error: `catch |e| ...` (main token `catch`, then `|`, then name).
    if (ast.tokenTag(catch_tok + 1) != .pipe) {
        return;
    }
    const cap_name: []const u8 = ast.tokenSlice(catch_tok + 2);
    _, const rhs = ast.nodeData(node).node_and_node;
    const ret_node: Index = returnNodeOf(ast, rhs) orelse return;
    const operand: Index = ast.nodeData(ret_node).opt_node.unwrap() orelse return;
    if (ast.nodeTag(operand) != .identifier) {
        return;
    }
    if (!eql(u8, ast.tokenSlice(ast.nodeMainToken(operand)), cap_name)) {
        return;
    }
    try ctx.emitAt(
        catch_tok,
        "no-catch-return",
        0,
        "`catch |{s}| return {s}` is just `try` - propagating the caught error is what try does",
        .{ cap_name, cap_name },
    );
}

/// True when a comment sits immediately before this switch prong (on its own line
/// above, or trailing the previous prong on the same line). Byte-scans the gap
/// between the previous token and the prong's first token, which is exactly where
/// the tokenizer drops comments.
fn prongHasComment(ast: *const Ast, case_node: Index) bool {
    const first: u32 = ast.firstToken(case_node);
    if (first == 0) {
        return false;
    }
    const prev_end: u32 = ast.tokenStart(first - 1) + @as(u32, @intCast(ast.tokenSlice(first - 1).len));
    const gap: []const u8 = ast.source[prev_end..ast.tokenStart(first)];
    return indexOf(u8, gap, "//") != null;
}

/// duplicate-case: two prongs of the SAME switch whose bodies are byte-identical.
/// Either they were meant to be one prong (`.a, .b => body`) or one of them is a
/// copy-paste that forgot to change -- both are worth a look, and merging is always
/// semantics-preserving.
///
/// Skips a prong that has a CAPTURE (`|v|`): the payload type can differ per tag,
/// so identical text is not identical meaning and the merge may not even compile.
/// Skips `inline` prongs for the same reason -- the tag is comptime-known inside,
/// so the same text can lower differently per prong. Skips `else`. Byte equality of
/// the body's source span means a differing comment is enough to stay quiet, which
/// is the safe direction.
fn checkDuplicateCase(ctx: Ctx, node: Index) !void {
    const ast: *const Ast = ctx.ast;
    const sw: Ast.full.Switch = ast.fullSwitch(node) orelse return;
    const cases: []const Index = sw.ast.cases;
    for (cases, 0..) |a, ai| {
        const ca: Ast.full.SwitchCase = ast.fullSwitchCase(a) orelse continue;
        if (ca.ast.values.len == 0 or ca.payload_token != null or ca.inline_token != null) {
            continue;
        }
        const body_a: []const u8 = ast.getNodeSource(ca.ast.target_expr);
        for (cases[ai + 1 ..]) |b| {
            const cb: Ast.full.SwitchCase = ast.fullSwitchCase(b) orelse continue;
            if (cb.ast.values.len == 0 or cb.payload_token != null or cb.inline_token != null) {
                continue;
            }
            if (!eql(u8, body_a, ast.getNodeSource(cb.ast.target_expr))) {
                continue;
            }
            // Only a non-empty BLOCK body. A bare-expression prong is the shape of
            // a lookup table (`.rgb565 => 2, .rgba4444 => 2`) and an empty `{}` is
            // an exhaustive switch's deliberate per-variant no-op -- both are good
            // Zig, and merging them would cost readability, not buy it.
            if (!isBlockTag(ast.nodeTag(cb.ast.target_expr))) {
                continue;
            }
            if (blockStmts(ast, cb.ast.target_expr).items().len == 0) {
                continue;
            }
            // A prong carrying its own comment was split on purpose (each SPIR-V
            // opcode documenting its operand layout, each event saying why it is
            // ignored). That IS the conscious choice this rule exists to force, so
            // it is already made -- stay quiet.
            if (prongHasComment(ast, b) or prongHasComment(ast, a)) {
                continue;
            }
            try ctx.emitAt(
                ast.firstToken(b),
                "duplicate-case",
                0,
                "switch prong body is identical to an earlier prong - merge them (`.a, .b => ...`)",
                .{},
            );
            break;
        }
    }
}

fn walkNode(
    ctx: Ctx,
    node: Index,
    pos: Pos,
    fn_depth: u8,
) anyerror!void {
    const ast: *const Ast = ctx.ast;
    const tag: Ast.Node.Tag = ast.nodeTag(node);
    // `--coverage` records every node the walk reaches (`walkCoverage`).
    if (ctx.visited.len != 0) {
        ctx.visited[@backingInt(node)] = true;
    }

    // Per-node checks.
    // Declaration types and field types need no second walk: the walk reaches them, like every other node.
    if (ast.fullVarDecl(node)) |vd| {
        try checkVarDecl(ctx, vd, pos, fn_depth);
    }
    if (pos == .statement) {
        try checkBranchBraces(ctx, node, tag);
    }
    try checkStdMath(ctx, node, tag);
    try checkTurnInRadianCall(ctx, node, tag);
    try checkDebugPrint(ctx, node, tag);
    try checkArchCheck(ctx, node, tag);
    try checkBrowserCall(ctx, node, tag);
    try checkOwnClock(ctx, node, tag);
    try checkProcessExit(ctx, node, tag);
    try checkStdTimer(ctx, node, tag);
    try checkNoQualifiedZm(ctx, node, tag);
    try checkNoQualifiedStd(ctx, node, tag);
    try checkPreferVec(ctx, node, tag);
    try checkStdDebugAssert(ctx, node, tag);
    try checkImportAtTop(ctx, node, tag, fn_depth);
    try checkClampPattern(ctx, node, tag);
    try checkAsRound(ctx, node, tag);
    try checkIntFromFloat(ctx, node, tag);
    try checkFloatFromInt(ctx, node, tag);
    try checkPreferSplat(ctx, node, tag);
    try checkBannedConversion(ctx, node, tag);
    try checkFnArgsMultiline(ctx, node, tag);
    try checkAnonReturn(ctx, node, tag);
    try checkCatchSuppression(ctx, node, tag);
    try checkPreferAssertUnreachable(ctx, node, tag);
    try checkNoCatchReturn(ctx, node, tag);
    if (tag == .@"switch" or tag == .switch_comma) {
        try checkDuplicateCase(ctx, node);
    }

    // Recurse.  fn_decl / test_decl bump fn_depth and walk the
    // body as statements.  Most other branching constructs
    // preserve pos (we're either in statements or in
    // expressions; that doesn't change by descending into a
    // condition or body).
    switch (tag) {
        .fn_decl => {
            // The prototype - parameters, return type, align / section / callconv - is walked as a node below, like any
            // other node: its own checks (fn-args-multiline, anon-return) and the checks on its types run there, once.
            // (While the walk never descended into prototypes, those ran here by hand - a fix from turn 348 that
            // became a duplicate once the walk could see everything.) What stays here needs the name or the body.
            const proto_n, const body = ast.nodeData(node).node_and_node;
            // Rule reserved-math-names: a fn named like an R_core word (e.g. a local `fn lerp`) shadows zm.* - flag it.
            var name_buf: [1]Index = undefined;
            if (ast.fullFnProto(&name_buf, node)) |proto| {
                if (proto.name_token) |nt| {
                    try checkReservedMath(ctx, nt, null);
                }
                if (proto.ast.return_type.unwrap()) |rt| {
                    // A function literal has the signature its destination dictates; its error union is not the
                    // author's to drop, whatever its body does (`isFunctionLiteral`).
                    const is_literal: bool = if (proto.name_token) |nt| isFunctionLiteral(ast, node, nt) else false;
                    if (!is_literal) {
                        try checkUselessErrorReturn(ctx, proto, rt, body);
                    }
                }
            }
            try checkReturnedStackRef(ctx, body);
            try walkNode(ctx, proto_n, .expression, fn_depth);
            try walkBlockBody(ctx, body, fn_depth + 1);
        },
        .test_decl => {
            _, const body = ast.nodeData(node).opt_token_and_node;
            try walkBlockBody(ctx, body, fn_depth + 1);
        },
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            // A block reached as an expression - its inner
            // statements are still statements.
            try walkBlockBody(ctx, node, fn_depth);
        },
        .if_simple => {
            const condition, const then_e = ast.nodeData(node).node_and_node;
            try walkNode(ctx, condition, .expression, fn_depth);
            try walkNode(ctx, then_e, pos, fn_depth);
        },
        .@"if" => {
            const if_full: Ast.full.If = ast.fullIf(node).?;
            try walkNode(ctx, if_full.ast.cond_expr, .expression, fn_depth);
            try walkNode(ctx, if_full.ast.then_expr, pos, fn_depth);
            if (if_full.ast.else_expr.unwrap()) |e| {
                try walkNode(ctx, e, pos, fn_depth);
            }
        },
        .while_simple, .for_simple => {
            const head, const body = ast.nodeData(node).node_and_node;
            try walkNode(ctx, head, .expression, fn_depth);
            try walkNode(ctx, body, pos, fn_depth);
        },
        // `.while_cont` is the `while (i < n) : (i += 1)` form and is a DIFFERENT tag from
        // `.while_simple`. It appeared in neither this switch nor `childNodes`, so its body was
        // never walked by ANY rule - and a counted loop is exactly where numeric code lives.
        // `src/image.zig:515` calls `std.math.clamp` inside one, and `zig build lint` has
        // reported clean for as long as that line has existed.
        .@"while", .while_cont => {
            const w: Ast.full.While = ast.fullWhile(node).?;
            try walkNode(ctx, w.ast.cond_expr, .expression, fn_depth);
            if (w.ast.cont_expr.unwrap()) |continuation| {
                try walkNode(ctx, continuation, .expression, fn_depth);
            }
            try walkNode(ctx, w.ast.then_expr, pos, fn_depth);
            if (w.ast.else_expr.unwrap()) |e| {
                try walkNode(ctx, e, pos, fn_depth);
            }
        },
        .@"for" => {
            const f: Ast.full.For = ast.fullFor(node).?;
            for (f.ast.inputs) |input| {
                try walkNode(ctx, input, .expression, fn_depth);
            }
            try walkNode(ctx, f.ast.then_expr, pos, fn_depth);
            if (f.ast.else_expr.unwrap()) |e| {
                try walkNode(ctx, e, pos, fn_depth);
            }
        },
        .@"switch", .switch_comma => {
            // Walk the condition AND every case's target.  The
            // target carries the same pos as the parent switch
            // - if the switch was a statement, the case body
            // is too; if the switch was an expression, the case
            // body is an expression.
            const s: Ast.full.Switch = ast.fullSwitch(node).?;
            try walkNode(ctx, s.ast.condition, .expression, fn_depth);
            for (s.ast.cases) |case_node| {
                if (ast.fullSwitchCase(case_node)) |case_full| {
                    for (case_full.ast.values) |value| {
                        try walkNode(ctx, value, .expression, fn_depth);
                    }
                    try walkNode(ctx, case_full.ast.target_expr, pos, fn_depth);
                }
            }
        },
        else => {
            // Anything else: generic descent.  Visit every
            // child node through `childNodes` so per-node
            // checks (array-mult, clamp-pattern,
            // floor-pattern) fire deep inside init
            // expressions and other sub-trees.  Pos becomes
            // .expression so branch-braces stays silent
            // (`const x = if (a) b else c;` is fine without
            // braces - the if is being used as a value).
            // Var decls are the one special case that needs
            // both directions: if the init is a container_decl
            // (struct/union/enum literal), walk it as a
            // container so nested fn decls get linted; if it's
            // anything else, walk as an expression.
            if (ast.fullVarDecl(node)) |vd| {
                const declaration_parts = [_]Ast.Node.OptionalIndex{
                    vd.ast.type_node, vd.ast.align_node, vd.ast.addrspace_node, vd.ast.section_node,
                };
                for (declaration_parts) |part| {
                    if (part.unwrap()) |present| {
                        try walkNode(ctx, present, .expression, fn_depth);
                    }
                }
                if (vd.ast.init_node.unwrap()) |init_n| {
                    const init_tag: Ast.Node.Tag = ast.nodeTag(init_n);
                    if (isContainerDeclTag(init_tag)) {
                        try walkContainerChildren(ctx, init_n, fn_depth);
                    } else {
                        try walkNode(ctx, init_n, .expression, fn_depth);
                    }
                }
            } else if (isContainerDeclTag(tag)) {
                try walkContainerChildren(ctx, node, fn_depth);
            } else {
                var child_buffer: ChildBuffer = .{};
                var children: ChildIterator = allChildren(ast, node, &child_buffer);
                while (children.next()) |child| {
                    try walkNode(ctx, child, .expression, fn_depth);
                }
            }
        },
    }
}

/// A file that renders 3D (`beginMode3D` / `beginMode3DMatrix`) AND owns a window
/// config (`AppSpec` with a `.window`) must set `.depth_format`, or `beginMode3D`
/// asserts at runtime ("needs a depth attachment"). This is a runtime-only crash a
/// GPU-less build can't catch, so we catch it here. Helper files that draw 3D but
/// carry no AppSpec (e.g. a shared render.zig) are exempt - they don't own the
/// window, the file that includes them does.
fn runDepthFormat(ctx: Ctx) !void {
    const src: []const u8 = ctx.source;
    const uses_3d: bool = indexOf(u8, src, "beginMode3D") != null;
    if (!uses_3d) {
        return;
    }
    // Only files that declare the window config are responsible for depth_format.
    const owns_window: bool = indexOf(u8, src, "AppSpec(") != null and
        indexOf(u8, src, ".window") != null;
    if (!owns_window) {
        return;
    }
    if (indexOf(u8, src, "depth_format") != null) {
        return; // set somewhere in this file - good enough (it's a small config)
    }

    // Point at the first beginMode3D call so the message lands on the offending line.
    const at: usize = indexOf(u8, src, "beginMode3D").?;
    var line: u32 = 1;
    for (src[0..at]) |ch| {
        if (ch == '\n') {
            line += 1;
        }
    }
    try ctx.emit(
        line,
        1,
        "depth-format",
        10,
        "3D render (beginMode3D) needs a depth buffer: add " ++
            "`.depth_format = .depth24_plus` to the window config, " ++
            "or beginMode3D asserts at runtime",
        .{},
    );
}

fn runLineLength(ctx: Ctx) !void {
    var line: u32 = 1;
    var line_start: usize = 0;
    for (ctx.source, 0..) |c, i| {
        if (c == '\n') {
            const len: usize = i - line_start;
            if (len > 120) {
                try ctx.emit(line, 121, "line-length", 10, "{d} cols, max 120", .{len});
            }
            line += 1;
            line_start = i + 1;
        }
    }
}

/// Where a non-ASCII byte sits, as far as the two ASCII rules care.
const NonAsciiPlace = enum { data, comment, test_name };

/// `ascii-comments` and `ascii-test-names`: every comment - plain, doc and container
/// doc - and every `test "..."` name is ASCII.
///
/// Works from the non-ASCII bytes rather than from the comments, because they are rare:
/// each one is located in the token stream by binary search. Zig identifiers are ASCII,
/// so a non-ASCII byte is either inside a token or between tokens, where the only thing
/// that can hold it is a plain `//` comment. Inside a token it is a doc comment, a test
/// name (a string literal right after `test`), or data - any other string or char
/// literal, which is allowed. One issue per line, at its first offender.
fn runAsciiComments(ctx: Ctx) !void {
    const ast: *const Ast = ctx.ast;
    const tags: []const std.zig.Token.Tag = ast.tokens.items(.tag);
    const starts: []const u32 = ast.tokens.items(.start);
    var line: u32 = 1;
    var last_reported_line: u32 = 0;
    var i: usize = 0;
    while (i < ctx.source.len) : (i += 1) {
        const byte: u8 = ctx.source[i];
        if (byte == '\n') {
            line += 1;
            continue;
        }
        const is_ascii: bool = byte < 0x80;
        const line_already_reported: bool = line == last_reported_line;
        if (is_ascii or line_already_reported) {
            continue;
        }

        // The last token starting at or before `i`.
        var low: usize = 0;
        var high: usize = starts.len;
        while (low < high) {
            const mid: usize = low + (high - low) / 2;
            if (starts[mid] <= i) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        const place: NonAsciiPlace = place: {
            if (low == 0) {
                break :place .comment; // before the first token: a leading plain comment
            }
            const token: u32 = @intCast(low - 1);
            const token_end: usize = starts[token] + ast.tokenSlice(token).len;
            const inside_token: bool = i < token_end;
            if (!inside_token) {
                break :place .comment;
            }
            const tag: std.zig.Token.Tag = tags[token];
            const is_doc_comment: bool = tag == .doc_comment or tag == .container_doc_comment;
            if (is_doc_comment) {
                break :place .comment;
            }
            const is_test_name: bool = tag == .string_literal and token > 0 and tags[token - 1] == .keyword_test;
            if (is_test_name) {
                break :place .test_name;
            }
            break :place .data;
        };
        if (place == .data) {
            continue;
        }

        var line_start: usize = i;
        while (line_start > 0 and ctx.source[line_start - 1] != '\n') : (line_start -= 1) {}
        const col: u32 = @intCast(i - line_start + 1);
        const sequence_len: u3 = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        const sequence_end: usize = @min(i + sequence_len, ctx.source.len);
        const codepoint: u21 = std.unicode.utf8Decode(ctx.source[i..sequence_end]) catch byte;
        switch (place) {
            .comment => try ctx.emit(
                line,
                col,
                "ascii-comments",
                0,
                "comment holds U+{X:0>4} - write it in ASCII (`->` not an arrow, `*` not a star, `x` not a times sign)",
                .{codepoint},
            ),
            .test_name => try ctx.emit(
                line,
                col,
                "ascii-test-names",
                0,
                "test name holds U+{X:0>4} - write it in ASCII, so `-Dtest-filter` can be typed to reach it",
                .{codepoint},
            ),
            .data => unreachable, // skipped above
        }
        last_reported_line = line;
    }
}

fn runShaderSafeChecks(ctx: Ctx) !void {
    const src_z: [:0]const u8 = ctx.source;
    const marked: bool = startsWith(u8, src_z, "//! SHADER-SAFE");
    const is_io: bool = endsWith(u8, ctx.path, "_io.zig");
    if (!marked and !is_io) {
        return;
    }
    const banned = [_]struct { pat: []const u8, why: []const u8 }{
        .{ .pat = "std.heap", .why = "allocators" },
        .{ .pat = "mem.Allocator", .why = "allocators" },
        .{ .pat = "std.ArrayList", .why = "heap containers" },
        .{ .pat = "std.fs", .why = "filesystem" },
        .{ .pat = "std.Io", .why = "runtime IO" },
        .{ .pat = "std.debug.print", .why = "runtime printing" },
        .{ .pat = "extern fn", .why = "extern declarations" },
        .{ .pat = "@import(\"wgpu", .why = "bridge imports" },
        .{ .pat = "@import(\"web", .why = "bridge imports" },
    };
    var line_no: u32 = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    var test_depth: i32 = 0;
    var in_test: bool = false;
    while (i <= src_z.len) : (i += 1) {
        if (i < src_z.len and src_z[i] != '\n') {
            continue;
        }
        const line: []const u8 = src_z[line_start..i];
        defer {
            line_no += 1;
            line_start = i + 1;
        }
        if (!in_test and startsWith(u8, line, "test ")) {
            in_test = true;
            test_depth = 0;
        }
        if (in_test) {
            for (line) |c| {
                if (c == '{') {
                    test_depth += 1;
                }
                if (c == '}') {
                    test_depth -= 1;
                }
            }
            if (test_depth <= 0 and indexOfScalar(u8, line, '}') != null) {
                in_test = false;
            }
            continue;
        }
        const code: []const u8 = if (indexOf(u8, line, "//")) |ci| line[0..ci] else line;
        for (banned) |b| {
            if (indexOf(u8, code, b.pat) != null) {
                try ctx.emit(
                    line_no,
                    1,
                    "shader-safe",
                    0,
                    "SHADER-SAFE file uses {s} ({s}) outside a test block",
                    .{ b.pat, b.why },
                );
            }
        }
    }
}

/// Byte span that deletes an entire unused file-scope `const`/`var`
/// declaration: from any leading `///` doc-comment lines (and the decl's own
/// indentation) through the terminating `;` and, when the decl owns its whole
/// line, the trailing newline. A decl sharing a line with siblings loses only
/// its own tokens (no newline swallow), keeping the survivors intact.
fn unusedGlobalFix(ast: *const Ast, decl: Index) Fix {
    const src: [:0]const u8 = ast.source;
    const tok_tags: []const std.zig.Token.Tag = ast.tokens.items(.tag);

    // Walk back over contiguous doc-comment tokens so `///` lines go too.
    var first_tok: u32 = ast.firstToken(decl);
    while (first_tok > 0 and tok_tags[first_tok - 1] == .doc_comment) {
        first_tok -= 1;
    }
    var start: usize = ast.tokenStart(first_tok);

    // Find the start of `start`'s line; the decl "owns" the line when every
    // byte before it on that line is whitespace.
    var line_start: usize = start;
    while (line_start > 0 and src[line_start - 1] != '\n') {
        line_start -= 1;
    }
    var owns_line: bool = true;
    var p: usize = line_start;
    while (p < start) : (p += 1) {
        if (src[p] != ' ' and src[p] != '\t') {
            owns_line = false;
            break;
        }
    }
    if (owns_line) {
        start = line_start;
    }

    // End: past the last token, then absorb a trailing `;` (when `lastToken`
    // stopped at the init expr) and, if the decl owns the line, its newline.
    const last_tok: u32 = ast.lastToken(decl);
    var end: usize = ast.tokenStart(last_tok) + ast.tokenSlice(last_tok).len;
    while (end < src.len and (src[end] == ' ' or src[end] == '\t')) {
        end += 1;
    }
    if (end < src.len and src[end] == ';') {
        end += 1;
    }
    if (owns_line and end < src.len and src[end] == '\n') {
        end += 1;
    }
    return .{ .start = @intCast(start), .end = @intCast(end), .replacement = "" };
}

/// reference is "bare" when the identifier is not preceded by `.`, so a
/// field access like `co.Color` does NOT count as a use of a global
/// `Color`, and the decl's own initializer (e.g. `= z.Color`) is excluded
/// for the same reason.
/// The module path of an `@import("...")` builtin call, quotes stripped, or null
/// when `node` isn't one. Reads the string straight off the token stream: the
/// builtin's main token is `@import`, `+1` is `(`, `+2` is the path literal.
fn importModuleOf(ast: *const Ast, node: Index) ?[]const u8 {
    switch (ast.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {},
        else => return null,
    }
    const main_tok: u32 = ast.nodeMainToken(node);
    if (!eql(u8, ast.tokenSlice(main_tok), "@import")) {
        return null;
    }
    if (ast.tokenTag(main_tok + 2) != .string_literal) {
        return null;
    }
    const raw: []const u8 = ast.tokenSlice(main_tok + 2);
    if (raw.len < 2) {
        return null;
    }
    return raw[1 .. raw.len - 1];
}

/// redundant-import: the file already binds this module to a file-scope alias, so
/// a second `@import("m.zig")` spelled out inline is the long way round --
/// `wgpu.render_pass` says the same thing as `@import("wgpu.zig").render_pass`
/// with the alias sitting right there. Same "one obvious way" as no-qualified-std
/// and no-qualified-zm, generalized to every module.
///
/// Only whole-module bindings count (`const wgpu = @import("wgpu.zig");`); a
/// member binding (`const truetype = @import("codecs.zig").truetype;`) is NOT an
/// alias for the module, so imports alongside it stay quiet. A module bound to two
/// different names is skipped -- there's no single right replacement, and picking
/// one is a judgment call for a human.
/// True when any `@import` builtin token sits in [first, last]. Used to record ONLY
/// import-bearing constructs below: a fn body or decl with no import in it can
/// never matter, and filtering on that keeps the fixed buffers from overflowing on
/// a big file (src/ui.zig alone has 664 fns and 5526 container-scope decls, both
/// far past any sane cap -- silently truncating there would have produced FALSE
/// POSITIVES on every import past the cutoff).
fn spanHasImport(ast: *const Ast, first: u32, last: u32) bool {
    var t: u32 = first;
    while (t <= last and t < ast.tokens.len) : (t += 1) {
        if (ast.tokenTag(t) != .builtin) {
            continue;
        }
        if (eql(u8, ast.tokenSlice(t), "@import")) {
            return true;
        }
    }
    return false;
}

/// import-at-root: every `@import` must be a container-scope binding, so a file's
/// dependencies are readable in one place instead of buried mid-expression.
/// `@import("wgpu.zig").render_pass.setScissorRect(...)` inside a function hides a
/// dependency from everyone who scans the top of the file.
///
/// Allowed: a binding at container scope, at ANY nesting -- a nested namespace
/// (`pub const default_shapes = struct { pub const vs = @import("..."); };`) is
/// deliberate API shape -- and member bindings (`const truetype =
/// @import("codecs.zig").truetype;`). Also `_ = @import("x_test.zig");`, the test
/// aggregation idiom, which exists precisely to reference a module without naming
/// it. Flagged: imports inside a FUNCTION BODY, and imports used inline in an
/// expression or type.
///
/// Deliberately NO autofix: repairing one means creating a file-scope decl and
/// choosing its name, and an auto-inserted binding can collide with an existing
/// identifier or add a second alias for a module that already has one.
fn runImportAtRoot(ctx: Ctx) !void {
    const ast: *const Ast = ctx.ast;
    const cap: usize = 512;
    var ok_start: [cap]u32 = undefined;
    var ok_end: [cap]u32 = undefined;
    var ok_n: usize = 0;
    var fn_start: [cap]u32 = undefined;
    var fn_end: [cap]u32 = undefined;
    var fn_n: usize = 0;

    var i: usize = 0;
    while (i < ast.nodes.len) : (i += 1) {
        const n: Index = @fromBackingInt(@intCast(i));
        if (ast.nodeTag(n) != .fn_decl or fn_n == cap) {
            continue;
        }
        _, const body: Index = ast.nodeData(n).node_and_node;
        const bf: u32 = ast.firstToken(body);
        const bl: u32 = ast.lastToken(body);
        if (!spanHasImport(ast, bf, bl)) {
            continue;
        }
        fn_start[fn_n] = bf;
        fn_end[fn_n] = bl;
        fn_n += 1;
    }

    i = 0;
    while (i < ast.nodes.len) : (i += 1) {
        const n: Index = @fromBackingInt(@intCast(i));
        if (ok_n == cap) {
            break;
        }
        if (ast.fullVarDecl(n)) |vd| {
            const init_node: Index = vd.ast.init_node.unwrap() orelse continue;
            const decl_tok: u32 = ast.firstToken(n);
            var in_fn: bool = false;
            for (0..fn_n) |k| {
                if (decl_tok >= fn_start[k] and decl_tok <= fn_end[k]) {
                    in_fn = true;
                    break;
                }
            }
            if (in_fn) {
                continue;
            }
            const inf: u32 = ast.firstToken(init_node);
            const inl: u32 = ast.lastToken(init_node);
            if (!spanHasImport(ast, inf, inl)) {
                continue;
            }
            ok_start[ok_n] = inf;
            ok_end[ok_n] = inl;
            ok_n += 1;
            continue;
        }
        if (ast.nodeTag(n) == .assign) {
            const lhs: Index, const rhs: Index = ast.nodeData(n).node_and_node;
            if (eql(u8, ast.tokenSlice(ast.firstToken(lhs)), "_")) {
                ok_start[ok_n] = ast.firstToken(rhs);
                ok_end[ok_n] = ast.lastToken(rhs);
                ok_n += 1;
            }
        }
    }

    i = 0;
    while (i < ast.nodes.len) : (i += 1) {
        const n: Index = @fromBackingInt(@intCast(i));
        const mod: []const u8 = importModuleOf(ast, n) orelse continue;
        const tok: u32 = ast.firstToken(n);
        var allowed: bool = false;
        for (0..ok_n) |k| {
            if (tok >= ok_start[k] and tok <= ok_end[k]) {
                allowed = true;
                break;
            }
        }
        if (allowed) {
            continue;
        }
        try ctx.emitAt(
            tok,
            "import-at-root",
            0,
            "`@import(\"{s}\")` here hides a dependency - bind it at container scope and use the name",
            .{mod},
        );
    }
}

/// canonical-alias: a module declares how it wants to be named via a top-of-file
/// `//! lint:alias <name>`; every importer must use that name. One spelling per
/// module tree-wide is what makes `grep "zm\."` find every use.
///
/// Opt-in by design: only modules that declare are enforced, so families that
/// deliberately share a generic local name (every shader importing its own
/// `*_io.zig` as `shader_io`) declare nothing and stay untouched.
///
/// An import string is matched to a declaration when its stem equals the declaring
/// file's stem OR the declared alias -- so zimrmath.zig declaring `zm` captures
/// `@import("zm")` (the build-module name), `@import("zimrmath")` and
/// `@import("zimrmath.zig")` without the linter knowing the build graph.
fn runCanonicalAlias(ctx: Ctx) !void {
    if (ctx.aliases.len == 0) {
        return;
    }
    const ast: *const Ast = ctx.ast;
    const self_stem: []const u8 = moduleStem(ctx.path);
    for (ast.rootDecls()) |decl| {
        const vd: Ast.full.VarDecl = ast.fullVarDecl(decl) orelse continue;
        const init_node: Index = vd.ast.init_node.unwrap() orelse continue;
        const mod: []const u8 = importModuleOf(ast, init_node) orelse continue;
        // A `pub` binding is API surface, not a private alias: `pub const colors =
        // @import("types.zig");` in the zimr facade is deliberately named for the
        // caller (`z.colors.sky_300`), and renaming it would rewrite the public
        // API. Only the file's own internal spelling is this rule's business.
        if (vd.visib_token != null) {
            continue;
        }
        const key: []const u8 = moduleStem(mod);
        for (ctx.aliases) |d| {
            if (!eql(u8, d.stem, key) and !eql(u8, d.alias, key)) {
                continue;
            }
            // A file importing itself (re-export shims) is its own business.
            if (eql(u8, d.stem, self_stem)) {
                break;
            }
            const name_tok: u32 = vd.ast.mut_token + 1;
            const name: []const u8 = ast.tokenSlice(name_tok);
            if (eql(u8, name, d.alias)) {
                break;
            }
            try ctx.emitAt(
                name_tok,
                "canonical-alias",
                0,
                "'{s}' declares `//! lint:alias {s}` - import it as '{s}', not '{s}'",
                .{ d.stem, d.alias, d.alias, name },
            );
            break;
        }
    }
}

fn runRedundantImports(ctx: Ctx) !void {
    const ast: *const Ast = ctx.ast;
    // Bounded by DISTINCT modules given a file-scope binding, not by decls: the
    // busiest file in tree binds 47. Overflow would only drop later modules from
    // the alias map (a false negative), never invent a violation -- unlike
    // import-at-root, where truncating the allow-list produced false positives.
    const cap: usize = 128;
    var mods: [cap][]const u8 = undefined;
    var names: [cap][]const u8 = undefined;
    var binding: [cap]Index = undefined;
    var ambiguous: [cap]bool = undefined;
    var n: usize = 0;

    for (ast.rootDecls()) |decl| {
        const vd: Ast.full.VarDecl = ast.fullVarDecl(decl) orelse continue;
        const init_node: Index = vd.ast.init_node.unwrap() orelse continue;
        const mod: []const u8 = importModuleOf(ast, init_node) orelse continue;
        var seen: bool = false;
        for (0..n) |i| {
            if (eql(u8, mods[i], mod)) {
                ambiguous[i] = true;
                seen = true;
                break;
            }
        }
        if (seen or n == cap) {
            continue;
        }
        mods[n] = mod;
        names[n] = ast.tokenSlice(vd.ast.mut_token + 1);
        binding[n] = init_node;
        ambiguous[n] = false;
        n += 1;
    }
    if (n == 0) {
        return;
    }

    var i: usize = 0;
    while (i < ast.nodes.len) : (i += 1) {
        const node: Index = @fromBackingInt(@intCast(i));
        const mod: []const u8 = importModuleOf(ast, node) orelse continue;
        for (0..n) |k| {
            if (!eql(u8, mods[k], mod)) {
                continue;
            }
            if (ambiguous[k] or binding[k] == node) {
                break;
            }
            const ft: u32 = ast.firstToken(node);
            const lt: u32 = ast.lastToken(node);
            const end: u32 = ast.tokenStart(lt) + @as(u32, @intCast(ast.tokenSlice(lt).len));
            // `names[k]` borrows `ast.source`, which is gone by the time `--fix`
            // splices - `emitFix` keeps its own copy, so borrowing is safe here.
            const fix: Fix = .{ .start = ast.tokenStart(ft), .end = end, .replacement = names[k] };
            try ctx.emitFix(
                ft,
                "redundant-import",
                0,
                fix,
                "'{s}' is already imported as '{s}' in this file - use the alias",
                .{ mod, names[k] },
            );
            break;
        }
    }
}

fn runUnusedPrivateGlobals(ctx: Ctx) !void {
    const ast: *const Ast = ctx.ast;
    const tags: []const std.zig.Token.Tag = ast.tokens.items(.tag);
    for (ast.rootDecls()) |decl| {
        // Resolve the decl's name token + kind for both `const`/`var` and `fn`.
        // Skip anything pub (usable cross-file, invisible to a per-file linter) and
        // export/extern fns (WASM entry points + ABI declarations -- used externally,
        // never "dead" even when uncalled in-file). `inline` is NOT skipped -- an
        // uncalled private `inline fn` is just as dead as a normal one.
        var name_tok: u32 = undefined;
        var is_fn: bool = false;
        if (ast.fullVarDecl(decl)) |vd| {
            if (vd.visib_token != null) {
                continue;
            }
            name_tok = vd.ast.mut_token + 1;
        } else if (ast.nodeTag(decl) == .fn_decl) {
            var nb: [1]Index = undefined;
            const proto: Ast.full.FnProto = ast.fullFnProto(&nb, decl) orelse continue;
            if (proto.visib_token != null) {
                continue;
            }
            if (proto.extern_export_inline_token) |et| {
                const ett: std.zig.Token.Tag = ast.tokenTag(et);
                if (ett == .keyword_export or ett == .keyword_extern) {
                    continue;
                }
            }
            name_tok = proto.name_token orelse continue;
            is_fn = true;
        } else {
            continue;
        }
        const name: []const u8 = ast.tokenSlice(name_tok);
        var refs: u32 = 0;
        var i: usize = 0;
        while (i < tags.len) : (i += 1) {
            if (tags[i] != .identifier) {
                continue;
            }
            // For a const/var, a leading `.` means field access, not a reference.
            // For a fn it means the OPPOSITE: a private method is reached as
            // `self.flushGroup()`, so skipping `.`-preceded names made every such
            // method look dead -- and `--fix` deleted three of them from
            // WgpuGl.zig before this was caught. Counting them can only overcount
            // (a missed dead fn), which is the safe direction.
            if (!is_fn and i > 0 and tags[i - 1] == .period) {
                continue;
            }
            if (eql(u8, ast.tokenSlice(@intCast(i)), name)) {
                refs += 1;
            }
        }
        if (refs <= 1) {
            // NO AUTOFIX FOR FUNCTIONS. Deleting a decl is irreversible, and this
            // rule's evidence is a bare-identifier count -- far too weak a basis
            // for removing code unsupervised. A const/var still autofixes; a fn is
            // reported for a human to delete.
            if (is_fn) {
                try ctx.emitAt(name_tok, "unused-global", 0, "unused private fn '{s}'", .{name});
            } else {
                const fix: Fix = unusedGlobalFix(ast, decl);
                try ctx.emitFix(name_tok, "unused-global", 0, fix, "unused private global '{s}'", .{name});
            }
        }
    }
}

/// One file-scope declaration, for the `decl-order` rule.
const DeclSite = struct {
    /// First token of the declaration (the `pub`/`const`/`var`/`fn` keyword).
    first_token: u32,
    /// The declaration's name token (for the "declared at line N" message).
    name_token: u32,
    /// The earliest reference that appears before `first_token`, if any.
    earliest_use: ?u32 = null,
};

/// `decl-order`: flag a reference to a file-scope declaration (`fn`, `const`,
/// or `var`) that appears in the source BEFORE that declaration, so files read
/// top-down with every name defined before its first use.
///
/// Why this needs no scope analysis: Zig forbids a local variable or parameter
/// from shadowing a container-scope declaration, so a bare `.identifier` whose
/// name matches a file-scope decl can ONLY be a reference to that decl. We work
/// with `.identifier` nodes (not raw tokens), so struct-field declarations,
/// `a.b` field accesses, enum literals, and the decl's own name token are all
/// excluded for free.
///
/// Recursion: a self-call sits after the function's own name token, so it is
/// never flagged. The forward leg of mutual recursion (A defined before B, A's
/// body calls B) IS flagged on purpose - that is the "weird recursion" that has
/// to be opted into with `// lint:off decl-order: <why>` on the call line.
///
/// Limitation: only file-scope (`rootDecls`) names are tracked. A decl nested
/// in a `struct`/`union` that reuses a file-scope name (legal, separate
/// namespace) could in principle mis-resolve; suppress with `lint:off`.
// ---- Rule: scope-balance -------------------------------------------------
// Every begin{Drawing,Mode3D,TextureMode,...}/beginChild/... must have a
// matching end IN THE SAME FUNCTION. We flag only an UNMATCHED BEGIN (more
// begins than ends) = a forgotten end. That's the class that leaks pass state
// and asserts at runtime (e.g. helmet_sw forgot endDrawing). Flagging only
// surplus-begins (not surplus-ends) means a pre-migration example that calls
// endDrawing while the RUNNER owns beginDrawing is NOT falsely flagged.
const ScopePair = struct { begin: []const u8, end: []const u8 };

const scope_pairs = [_]ScopePair{
    .{ .begin = "beginDrawing", .end = "endDrawing" },
    .{ .begin = "beginMode3D", .end = "endMode3D" },
    .{ .begin = "beginMode2D", .end = "endMode2D" },
    .{ .begin = "beginTextureModeRaw", .end = "endTextureModeRaw" },
    .{ .begin = "beginTextureMode", .end = "endTextureMode" },
    .{ .begin = "beginBlendMode", .end = "endBlendMode" },
    .{ .begin = "beginScissorMode", .end = "endScissorMode" },
    .{ .begin = "beginShaderMode", .end = "endShaderMode" },
    .{ .begin = "beginChild", .end = "endChild" },
    .{ .begin = "beginCanvas", .end = "endCanvas" },
    .{ .begin = "beginDisabled", .end = "endDisabled" },
    // beginMode3DMatrix shares endMode3D with beginMode3D (a "shared end" pair:
    // the non-matching begin nets <= 0, so it never false-positives).
    .{ .begin = "beginMode3DMatrix", .end = "endMode3D" },
    .{ .begin = "beginTabBar", .end = "endTabBar" },
    .{ .begin = "beginTabItem", .end = "endTabItem" },
    .{ .begin = "beginTable", .end = "endTable" },
    .{ .begin = "beginCombo", .end = "endCombo" },
    .{ .begin = "beginListBox", .end = "endListBox" },
    .{ .begin = "beginMenuBar", .end = "endMenuBar" },
    .{ .begin = "beginMainMenuBar", .end = "endMainMenuBar" },
    .{ .begin = "beginMenu", .end = "endMenu" },
    .{ .begin = "beginGroup", .end = "endGroup" },
    // Popup family: all three begins pair with endPopup (shared end, safe).
    .{ .begin = "beginPopup", .end = "endPopup" },
    .{ .begin = "beginPopupModal", .end = "endPopup" },
    .{ .begin = "beginPopupContextItem", .end = "endPopup" },
    .{ .begin = "beginTooltip", .end = "endTooltip" },
    .{ .begin = "beginItemTooltip", .end = "endItemTooltip" },
    .{ .begin = "beginDragDropSource", .end = "endDragDropSource" },
    .{ .begin = "beginDragDropTarget", .end = "endDragDropTarget" },
    .{ .begin = "beginMultiSelect", .end = "endMultiSelect" },
    .{ .begin = "beginListClipper", .end = "endListClipper" },
};

/// Method/fn name of a call node (`z.beginDrawing(..)` -> "beginDrawing",
/// bare `foo(..)` -> "foo"). null for non-calls.
fn calledName(ast: *const Ast, node: Index) ?[]const u8 {
    const fn_expr: Index = switch (ast.nodeTag(node)) {
        .call, .call_comma => ast.nodeData(node).node_and_extra[0],
        .call_one, .call_one_comma => ast.nodeData(node).node_and_opt_node[0],
        else => return null,
    };
    const name_tok: u32 = switch (ast.nodeTag(fn_expr)) {
        .field_access => ast.nodeData(fn_expr).node_and_token[1],
        .identifier => ast.nodeMainToken(fn_expr),
        else => return null,
    };
    return ast.tokenSlice(name_tok);
}

/// scope-balance pass: an unmatched begin{X} in a function is a forgotten end{X}.
fn checkScopeBalance(ctx: Ctx) !void {
    const ast: *const Ast = ctx.ast;
    var fi: usize = 0;
    while (fi < ast.nodes.len) : (fi += 1) {
        const fn_node: Index = @fromBackingInt(@intCast(fi));
        if (ast.nodeTag(fn_node) != .fn_decl) {
            continue;
        }
        const lo: u32 = ast.firstToken(fn_node);
        const hi: u32 = ast.lastToken(fn_node);
        var net: [scope_pairs.len]i32 = @splat(0);
        var first_begin: [scope_pairs.len]u32 = @splat(0);
        // Scan every call node whose main token lies in this fn's token span.
        // (Robust against block/if/while nesting that childNodes doesn't walk.)
        var ci: usize = 0;
        while (ci < ast.nodes.len) : (ci += 1) {
            const cnode: Index = @fromBackingInt(@intCast(ci));
            const nm: []const u8 = calledName(ast, cnode) orelse continue;
            const ctok: u32 = ast.nodeMainToken(cnode);
            if (ctok < lo or ctok > hi) {
                continue;
            }
            for (scope_pairs, 0..) |pair, k| {
                if (eql(u8, nm, pair.begin)) {
                    if (net[k] == 0) {
                        first_begin[k] = ctok;
                    }
                    net[k] += 1;
                } else if (eql(u8, nm, pair.end)) {
                    net[k] -= 1;
                }
            }
        }
        for (scope_pairs, 0..) |pair, k| {
            if (net[k] > 0) {
                try ctx.emitAt(
                    first_begin[k],
                    "scope-balance",
                    20,
                    "'{s}' opened but not closed in this function - add a matching " ++
                        "'{s}' (a `defer z.{s}(...)` in a block works too). An unclosed " ++
                        "render/UI scope leaks pass state and asserts at runtime.",
                    .{ pair.begin, pair.end, pair.end },
                );
            }
        }
    }
}

/// Which identifier nodes are enum FIELD NAMES rather than uses, indexed by node. `enum { floor, mod, rem }`
/// parses every bare name as a tuple-like field whose "type" is an identifier - Zig decides it is a name only
/// later, once it knows the container is an enum. For `decl-order` those are not references to file-scope
/// declarations that happen to share the name. (zimrnum's `DivideWay` enum names `mod` and `rem`, the very
/// functions it chooses between - and looked like a cycle with them.) A tuple STRUCT's identifier is a real
/// type, so only enums count; and `enum(u8) { mod = 1 }` never parses its name as an identifier node.
fn enumFieldNameNodes(arena: Allocator, ast: *const Ast) ![]bool {
    const names: []bool = try arena.alloc(bool, ast.nodes.len);
    @memset(names, false);
    var buffer: [2]Index = undefined;
    var node_number: usize = 0;
    while (node_number < ast.nodes.len) : (node_number += 1) {
        const node: Index = @fromBackingInt(@intCast(node_number));
        const container: Ast.full.ContainerDecl = ast.fullContainerDecl(&buffer, node) orelse continue;
        if (ast.tokenTag(container.ast.main_token) != .keyword_enum) {
            continue;
        }
        for (container.ast.members) |member| {
            const field: Ast.full.ContainerField = ast.fullContainerField(member) orelse continue;
            if (!field.ast.tuple_like) {
                continue;
            }
            const name_node: Index = field.ast.type_expr.unwrap() orelse continue;
            if (ast.nodeTag(name_node) == .identifier) {
                names[@backingInt(name_node)] = true;
            }
        }
    }
    return names;
}

fn runDeclOrder(ctx: Ctx) !void {
    const ast: *const Ast = ctx.ast;
    var decls: StringHashMap(DeclSite) = .init(ctx.alloc);
    defer decls.deinit();

    // 1) Catalogue every file-scope declaration by name. First one wins
    //    (file-scope names are unique; a duplicate would be a compile error).
    for (ast.rootDecls()) |node| {
        const name_tok: u32 = declNameToken(ast, node) orelse continue;
        const name: []const u8 = ast.tokenSlice(name_tok);
        const gop: StringHashMap(DeclSite).GetOrPutResult = try decls.getOrPut(name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .first_token = ast.firstToken(node), .name_token = name_tok };
        }
    }

    // 2) One pass over every identifier node. If it names a file-scope decl and
    //    sits before that decl's first token, it is a forward reference; keep
    //    the earliest one per decl. An enum's field names are not uses (`enumFieldNameNodes`).
    const enum_field_names: []bool = try enumFieldNameNodes(ctx.alloc, ast);
    defer ctx.alloc.free(enum_field_names);
    var i: usize = 0;
    while (i < ast.nodes.len) : (i += 1) {
        const node: Index = @fromBackingInt(@intCast(i));
        if (ast.nodeTag(node) != .identifier or enum_field_names[i]) {
            continue;
        }
        const use_tok: u32 = ast.nodeMainToken(node);
        const name: []const u8 = ast.tokenSlice(use_tok);
        const site: *DeclSite = decls.getPtr(name) orelse continue;
        if (use_tok >= site.first_token) {
            continue;
        }
        if (site.earliest_use == null or use_tok < site.earliest_use.?) {
            site.earliest_use = use_tok;
        }
    }

    // 3) Emit one issue per offending decl, located at its earliest forward use
    //    (so the `// lint:off decl-order` goes on the reference line).
    var it: StringHashMap(DeclSite).Iterator = decls.iterator();
    while (it.next()) |entry| {
        const use_tok: u32 = entry.value_ptr.earliest_use orelse continue;
        const decl_line: u32 = ctx.tokenLineCol(entry.value_ptr.name_token).line;
        try ctx.emitAt(
            use_tok,
            "decl-order",
            0,
            "'{s}' used before its declaration (declared at line {d})",
            .{ entry.key_ptr.*, decl_line },
        );
    }
}

/// Path-suffix test for shader stage files (`_fs.zig` / `_vs.zig`).
fn isShaderPath(path: []const u8) bool {
    return endsWith(u8, path, "_fs.zig") or
        endsWith(u8, path, "_vs.zig");
}

/// Catches `inline fn ...` (and `pub inline fn ...`) at module scope.
/// Skips comment lines.  Doesn't try to parse - the pattern is
/// unambiguous enough on a per-line basis in shader-DSL files.
fn checkShaderInlineFn(
    ctx: Ctx,
    line: []const u8,
    line_no: u32,
) !void {
    var trimmed: []const u8 = std.mem.trimStart(u8, line, " \t");
    if (startsWith(u8, trimmed, "//")) {
        return;
    }
    if (startsWith(u8, trimmed, "pub ")) {
        trimmed = trimmed[4..];
    }
    if (!startsWith(u8, trimmed, "inline fn ")) {
        return;
    }
    const col: u32 = @intCast(line.len - trimmed.len + 1);
    // `trimmed` points into `ctx.source`; the `inline ` keyword starts there.
    const off: usize = @intFromPtr(trimmed.ptr) - @intFromPtr(ctx.source.ptr);
    const fix: Fix = .{
        .start = @intCast(off),
        .end = @intCast(off + "inline ".len),
        .replacement = "",
    };
    try ctx.emitFixLC(
        line_no,
        col,
        "shader-inline-fn",
        0,
        fix,
        "`inline fn` in shader file - use plain `fn` (spirv-opt -O inlines post-codegen)",
        .{},
    );
}

/// Catches `@atan(` / `@atan2(` use in shader DSL files.  Neither
/// builtin works under Zig 0.16's SPIR-V target.
fn checkShaderNoAtan(
    ctx: Ctx,
    line: []const u8,
    line_no: u32,
) !void {
    const trimmed: []const u8 = std.mem.trimStart(u8, line, " \t");
    if (startsWith(u8, trimmed, "//")) {
        return;
    }
    // Look for `@atan(` or `@atan2(` anywhere on the line.
    if (indexOf(u8, line, "@atan2(") orelse
        indexOf(u8, line, "@atan(")) |idx|
    {
        const col: u32 = @intCast(idx + 1);
        try ctx.emit(
            line_no,
            col,
            "shader-no-atan",
            0,
            "`@atan`/`@atan2` aren't valid SPIR-V builtins - use `zm.atan2(y, x)`",
            .{},
        );
    }
}

fn runShaderChecks(ctx: Ctx) !void {
    if (!isShaderPath(ctx.path)) {
        return;
    }

    const src: [:0]const u8 = ctx.source;
    var line_no: u32 = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= src.len) : (i += 1) {
        if (i < src.len and src[i] != '\n') {
            continue;
        }
        const line: []const u8 = src[line_start..i];
        try checkShaderInlineFn(ctx, line, line_no);
        try checkShaderNoAtan(ctx, line, line_no);
        line_no += 1;
        line_start = i + 1;
    }
}

/// Name of the parameter whose type text is exactly `Io` (the zimr
/// shader convention), or null if the fn has no such parameter.
fn findIoParamName(ctx: Ctx, proto: Ast.full.FnProto) ?[]const u8 {
    const ast: *const Ast = ctx.ast;
    var it: Ast.full.FnProto.Iterator = proto.iterate(ast);
    while (it.next()) |p| {
        const type_node: Index = p.type_expr orelse continue;
        const name_tok: u32 = p.name_token orelse continue;
        const first_tok: u32 = ast.firstToken(type_node);
        const last_tok: u32 = ast.lastToken(type_node);
        const start: usize = ast.tokenStart(first_tok);
        const last_slice: []const u8 = ast.tokenSlice(last_tok);
        const end: usize = ast.tokenStart(last_tok) + last_slice.len;
        if (eql(u8, ctx.source[start..end], "Io")) {
            return ast.tokenSlice(name_tok);
        }
    }
    return null;
}

/// True if `node` is a method call on the Io parameter named `io_name`
/// - i.e. `<io_name>.<method>(...)`.  Namespace calls such as
/// `zm.dot(...)` don't match (`zm` is an import, not the io param), and
/// plain field reads such as `io.view_pos` aren't calls.
fn isSamplerCallOn(
    ctx: Ctx,
    node: Index,
    io_name: []const u8,
) bool {
    const ast: *const Ast = ctx.ast;
    const fn_expr: Index = switch (ast.nodeTag(node)) {
        .call, .call_comma => ast.nodeData(node).node_and_extra[0],
        .call_one, .call_one_comma => ast.nodeData(node).node_and_opt_node[0],
        else => return false,
    };
    if (ast.nodeTag(fn_expr) != .field_access) {
        return false;
    }
    const obj: Index = ast.nodeData(fn_expr).node_and_token[0];
    if (ast.nodeTag(obj) != .identifier) {
        return false;
    }
    const obj_name: []const u8 = ast.tokenSlice(ast.nodeMainToken(obj));
    if (!eql(u8, obj_name, io_name)) {
        return false;
    }
    // Explicit-LOD accessors (`<name>Level`, lowering to `textureSampleLevel`)
    // take no derivatives and are exempt from WGSL's uniformity rule, so they
    // are valid in helpers and branches - and are the ONLY kind of sample legal
    // in a vertex shader. Mirror the bare-`sampleLevel` exemption below: match
    // only the implicit-LOD accessor `io.<name>(uv)`, never `io.<name>Level(...)`.
    const method_tok: u32 = ast.nodeData(fn_expr).node_and_token[1];
    const method: []const u8 = ast.tokenSlice(method_tok);
    if (endsWith(u8, method, "Level")) {
        return false;
    }
    return true;
}

/// True if `node` is a call to the IMPLICIT-LOD sampler helper by NAME -
/// `sampleLod(...)` or `<module>.sampleLod(...)`.
/// These lower to `textureSample`, which WGSL/Tint permit only in UNIFORM
/// control flow, so they must be caught outside shaderMain's uniform top.
/// `sampleLevel(...)` takes an EXPLICIT LOD (no derivatives) and lowers to
/// `textureSampleLevel`, which is valid in ANY control flow - it is the escape
/// hatch for sampling in a helper/branch, so it is intentionally NOT matched.
fn isBareSamplerCall(ctx: Ctx, node: Index) bool {
    const ast: *const Ast = ctx.ast;
    const fn_expr: Index = switch (ast.nodeTag(node)) {
        .call, .call_comma => ast.nodeData(node).node_and_extra[0],
        .call_one, .call_one_comma => ast.nodeData(node).node_and_opt_node[0],
        else => return false,
    };
    // Resolve the callee's trailing name: either a bare identifier `sampleLod`
    // or a field access `sb.sampleLod`.
    const name_tok: u32 = switch (ast.nodeTag(fn_expr)) {
        .identifier => ast.nodeMainToken(fn_expr),
        .field_access => ast.nodeData(fn_expr).node_and_token[1],
        else => return false,
    };
    const name: []const u8 = ast.tokenSlice(name_tok);
    return eql(u8, name, "sampleLod");
}

/// Recursively flag sampler calls that aren't at the uniform top of
/// `shaderMain`.  `nested` = inside a control-flow body; `in_main` =
/// inside shaderMain (vs a helper).  A sampler call is allowed only when
/// `in_main and !nested`.
fn scanForSamplers(
    ctx: Ctx,
    node: Index,
    io_name: []const u8,
    nested: bool,
    in_main: bool,
) anyerror!void {
    const ast: *const Ast = ctx.ast;
    const tag: Ast.Node.Tag = ast.nodeTag(node);

    if (isSamplerCallOn(ctx, node, io_name) or isBareSamplerCall(ctx, node)) {
        const tok: u32 = ast.firstToken(node);
        if (!in_main) {
            try ctx.emitAt(
                tok,
                "sampler-in-helper",
                0,
                "texture sample in a helper fn - sample at shaderMain's top and pass the value in",
                .{},
            );
        } else if (nested) {
            try ctx.emitAt(
                tok,
                "sampler-in-branch",
                0,
                "texture sample inside a branch/loop - move it to the unconditional top of shaderMain",
                .{},
            );
        }
    }

    switch (tag) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            const bs: BlockSlice = blockStmts(ast, node);
            for (bs.items()) |stmt| {
                try scanForSamplers(ctx, stmt, io_name, nested, in_main);
            }
        },
        .if_simple => {
            const cond, const then_e = ast.nodeData(node).node_and_node;
            try scanForSamplers(ctx, cond, io_name, nested, in_main);
            try scanForSamplers(ctx, then_e, io_name, true, in_main);
        },
        .@"if" => {
            const f: Ast.full.If = ast.fullIf(node).?;
            try scanForSamplers(ctx, f.ast.cond_expr, io_name, nested, in_main);
            try scanForSamplers(ctx, f.ast.then_expr, io_name, true, in_main);
            if (f.ast.else_expr.unwrap()) |e| {
                try scanForSamplers(ctx, e, io_name, true, in_main);
            }
        },
        .while_simple, .while_cont, .@"while" => {
            const w: Ast.full.While = ast.fullWhile(node).?;
            try scanForSamplers(ctx, w.ast.cond_expr, io_name, nested, in_main);
            try scanForSamplers(ctx, w.ast.then_expr, io_name, true, in_main);
            if (w.ast.else_expr.unwrap()) |e| {
                try scanForSamplers(ctx, e, io_name, true, in_main);
            }
        },
        .for_simple => {
            const input, const body = ast.nodeData(node).node_and_node;
            try scanForSamplers(ctx, input, io_name, nested, in_main);
            try scanForSamplers(ctx, body, io_name, true, in_main);
        },
        .@"for" => {
            const f: Ast.full.For = ast.fullFor(node).?;
            for (f.ast.inputs) |inp| {
                try scanForSamplers(ctx, inp, io_name, nested, in_main);
            }
            try scanForSamplers(ctx, f.ast.then_expr, io_name, true, in_main);
            if (f.ast.else_expr.unwrap()) |e| {
                try scanForSamplers(ctx, e, io_name, true, in_main);
            }
        },
        .@"switch", .switch_comma => {
            const s: Ast.full.Switch = ast.fullSwitch(node).?;
            try scanForSamplers(ctx, s.ast.condition, io_name, nested, in_main);
            for (s.ast.cases) |case_node| {
                if (ast.fullSwitchCase(case_node)) |case_full| {
                    try scanForSamplers(ctx, case_full.ast.target_expr, io_name, true, in_main);
                }
            }
        },
        else => {
            if (ast.fullVarDecl(node)) |vd| {
                if (vd.ast.init_node.unwrap()) |init_n| {
                    try scanForSamplers(ctx, init_n, io_name, nested, in_main);
                }
            } else {
                var buf: [8]Index = undefined;
                const children: []const Index = childNodes(ast, node, &buf);
                for (children) |c| {
                    try scanForSamplers(ctx, c, io_name, nested, in_main);
                }
            }
        },
    }
}

/// Per-fn driver: for every top-level fn with an `Io` parameter, scan
/// for misplaced sampler calls.  shaderMain may sample at its top;
/// helpers may not sample at all.
/// Control-flow statement tags.  Once one appears in shaderMain's
/// top-level statement sequence, later invocations may have diverged (a
/// branch can `return`/`discard`/`break`), so the "uniform prologue"
/// ends and subsequent samples are no longer provably uniform.
fn isControlFlowTag(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .if_simple,
        .@"if",
        .while_simple,
        .while_cont,
        .@"while",
        .for_simple,
        .@"for",
        .@"switch",
        .switch_comma,
        => true,
        else => false,
    };
}

/// Scan shaderMain's body in statement order.  Texture samples are
/// allowed only in the straight-line *prologue* - the run of statements
/// before the first control-flow construct, where every invocation is
/// still in lockstep (= uniform).  After any if/loop/switch, later
/// statements (even unconditional ones) may be reached non-uniformly, so
/// a sample there is flagged.  This is a sound over-approximation of
/// WGSL's uniformity rule: it never permits a real violation, and the
/// fix it asks for (sample at the very top) is always available.  A
/// possible false positive (a sample that is in fact uniform after a
/// uniform branch) is acceptable - false negatives, which would let the
/// error reach the browser, are not.
fn scanMainBody(
    ctx: Ctx,
    body: Index,
    io_name: []const u8,
) !void {
    const ast: *const Ast = ctx.ast;
    const bs: BlockSlice = blockStmts(ast, body);
    var past_prologue: bool = false;
    for (bs.items()) |stmt| {
        try scanForSamplers(ctx, stmt, io_name, past_prologue, true);
        if (isControlFlowTag(ast.nodeTag(stmt))) {
            past_prologue = true;
        }
    }
}

fn runSamplerDiscipline(ctx: Ctx) !void {
    if (!isShaderPath(ctx.path)) {
        return;
    }
    const ast: *const Ast = ctx.ast;
    for (ast.rootDecls()) |decl| {
        if (ast.nodeTag(decl) != .fn_decl) {
            continue;
        }
        const proto_n, const body = ast.nodeData(decl).node_and_node;
        var buf: [1]Index = undefined;
        const proto_full: ?Ast.full.FnProto = switch (ast.nodeTag(proto_n)) {
            .fn_proto => ast.fnProto(proto_n),
            .fn_proto_multi => ast.fnProtoMulti(proto_n),
            .fn_proto_one => ast.fnProtoOne(&buf, proto_n),
            .fn_proto_simple => ast.fnProtoSimple(&buf, proto_n),
            else => null,
        };
        const proto: Ast.full.FnProto = proto_full orelse continue;
        const name_tok: u32 = proto.name_token orelse continue;
        const fn_name: []const u8 = ast.tokenSlice(name_tok);
        if (findIoParamName(ctx, proto)) |io_name| {
            // IoT-pattern shader: scan for io.<method>() sampler calls (and bare
            // ones). shaderMain's top is the only allowed sample site.
            const in_main: bool = eql(u8, fn_name, "shaderMain");
            if (in_main) {
                try scanMainBody(ctx, body, io_name);
            } else {
                try scanForSamplers(ctx, body, io_name, false, false);
            }
        } else if (eql(u8, fn_name, "entry")) {
            // Direct `@SpirvType` shader (billboard/skybox/points/decal ...): the
            // exported `entry` fn has no Io param, so the IoT path skips it. It
            // can still call `sampleLod(...)` - which must sit at uniform control
            // flow just the same. Scan it treating `entry` as the main body; the
            // empty io_name means only bare sampler calls match.
            try scanMainBody(ctx, body, "");
        }
    }
}

/// A name is SCREAMING_CASE when it has at least one letter and no lowercase letter.
fn isScreaming(name: []const u8) bool {
    var has_letter: bool = false;
    for (name) |ch| {
        if (ch >= 'a' and ch <= 'z') {
            return false;
        }
        if (ch >= 'A' and ch <= 'Z') {
            has_letter = true;
        }
    }
    return has_letter;
}

/// Whether a SCREAMING name is spelled as a C macro is: with an underscore (`MAX_ITEMS`), or with three letters or more
/// (`EPS`). A single capital, with or without digits - `N`, `K`, `F0` - is a mathematical symbol, written as the
/// mathematics writes it, and not this rule's concern.
fn isMacroStyle(name: []const u8) bool {
    if (!isScreaming(name)) {
        return false;
    }
    var letter_count: usize = 0;
    for (name) |character| {
        if (character == '_') {
            return true;
        }
        if (character >= 'A' and character <= 'Z') {
            letter_count += 1;
        }
    }
    return letter_count >= 3;
}

/// Whether a declaration holds a value rather than a type: it names its type, other than `type` - `const EPS: f32` - or
/// its initializer is a literal: a number, a string, a character, an enum literal, an array, a negated number. A type
/// alias names no type and starts with a type expression (`const V4 = @Vector(4, f32)`, `const H2 = struct {...}`).
fn isValueDecl(ast: *const Ast, vd: Ast.full.VarDecl) bool {
    if (vd.ast.type_node.unwrap()) |type_node| {
        return !eql(u8, ast.getNodeSource(type_node), "type");
    }
    const init_node: Index = vd.ast.init_node.unwrap() orelse return false;
    return switch (ast.nodeTag(init_node)) {
        .number_literal,
        .string_literal,
        .multiline_string_literal,
        .char_literal,
        .enum_literal,
        .array_init_one,
        .array_init_one_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init,
        .array_init_comma,
        .negation,
        => true,
        else => false,
    };
}

/// `screaming-const` - a value const named in SCREAMING_CASE, at any depth: at file scope, in a nested container such
/// as a namespace struct, or in a function. Every declaration in the tree is looked at, so none hides in a container
/// the walk enters late. Zig names values in snake_case and types in PascalCase; only values are judged
/// (`isValueDecl`). Suppress a genuine exception with `// lint:off screaming-const: <reason>`.
fn runScreamingConsts(ctx: Ctx) !void {
    const ast: *const Ast = ctx.ast;
    for (1..ast.nodes.len) |node_number| {
        const node: Index = @fromBackingInt(@intCast(node_number));
        const vd: Ast.full.VarDecl = ast.fullVarDecl(node) orelse continue;
        const name_tok: u32 = vd.ast.mut_token + 1;
        const name: []const u8 = ast.tokenSlice(name_tok);
        if (isMacroStyle(name) and isValueDecl(ast, vd)) {
            try ctx.emitAt(name_tok, "screaming-const", 0, "SCREAMING_CASE value '{s}' - use snake_case", .{name});
        }
    }
}

/// True when `s` is shaped like a rule tag: non-empty lowercase kebab-case.
/// Anything else after `lint:off` - `<tag>`, `...` - is prose ABOUT the
/// directive, not a directive.
fn isTagShaped(s: []const u8) bool {
    if (s.len == 0) {
        return false;
    }
    for (s) |c| {
        const ok: bool = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) {
            return false;
        }
    }
    return true;
}

/// `unknown-lint-tag`: a `// lint:off` / `//! lint:off` naming a tag that is not
/// a rule suppresses nothing, so it is either a typo or left over from a rule
/// that was renamed or deleted.
///
/// Only real directives are checked. Mentions of the syntax are skipped: a
/// `///` doc line or a `\\` multiline-string line, a marker quoted in backticks
/// or inside a string literal (an odd number of `"` before it), and a tag list
/// that isn't tag-shaped (`<tag>`). The file-level form is recognised only at
/// the start of a line, matching `fileSuppressedByDirective`.
fn runUnknownLintTags(ctx: Ctx) !void {
    var lines: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, ctx.source, '\n');
    var line_no: u32 = 0;
    while (lines.next()) |line| {
        line_no += 1;
        const trimmed: []const u8 = std.mem.trimStart(u8, line, " \t");
        const file_marker: []const u8 = "//! lint:off";
        const line_marker: []const u8 = "// lint:off";
        var list_start: usize = undefined;
        if (startsWith(u8, trimmed, file_marker)) {
            list_start = (line.len - trimmed.len) + file_marker.len;
        } else {
            if (startsWith(u8, trimmed, "///") or startsWith(u8, trimmed, "\\\\")) {
                continue;
            }
            const idx: usize = indexOf(u8, line, line_marker) orelse continue;
            if (idx > 0 and line[idx - 1] == '`') {
                continue;
            }
            const quotes: usize = std.mem.count(u8, line[0..idx], "\"");
            if (quotes % 2 == 1) {
                continue;
            }
            list_start = idx + line_marker.len;
        }
        while (list_start < line.len and (line[list_start] == ' ' or line[list_start] == '\t')) {
            list_start += 1;
        }
        var list_end: usize = list_start;
        while (list_end < line.len) : (list_end += 1) {
            const c: u8 = line[list_end];
            if (c == ':' or c == ' ' or c == '\t' or c == '\r') {
                break;
            }
        }
        const list: []const u8 = line[list_start..list_end];
        var shaped: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, list, ',');
        var all_shaped: bool = list.len > 0;
        while (shaped.next()) |tag| {
            if (!isTagShaped(tag)) {
                all_shaped = false;
            }
        }
        if (!all_shaped) {
            continue;
        }
        var tags: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, list, ',');
        while (tags.next()) |tag| {
            if (ruleIndex(tag) == null) {
                try ctx.emit(
                    line_no,
                    @intCast(list_start + 1),
                    "unknown-lint-tag",
                    0,
                    "`lint:off {s}` names no rule - fix the tag or delete the directive",
                    .{tag},
                );
            }
        }
    }
}

// ==== The walk's own coverage: --coverage ============================================================================
//
// Every per-node rule runs inside `walkNode`, so a node the walk never reaches is a node NO rule has ever looked at -
// and the lint reports "clean" there, by blindness. Such holes were found one at a time, each by noticing a violation
// the linter had reported zero of: `.assign` right-hand sides, `.while_cont` bodies, `if` conditions, the members of
// a struct returned from a function. `--coverage` finds them all at once: it walks a file exactly as `runChecks`
// does, records every node `walkNode` reaches, and lists the nodes of the kinds rules inspect that it never reached.

/// The node kinds the per-node rules inspect - declarations, calls, control flow, struct literals, field accesses. A
/// walk that misses one of these leaves rules blind there. (Leaves - identifiers, literals, operators - are read
/// through the nodes above them, so they are not counted.)
fn isCoverageTracked(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .simple_var_decl,
        .local_var_decl,
        .global_var_decl,
        .aligned_var_decl,
        .fn_decl,
        .test_decl,
        .call_one,
        .call_one_comma,
        .call,
        .call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        .builtin_call,
        .builtin_call_comma,
        .if_simple,
        .@"if",
        .while_simple,
        .while_cont,
        .@"while",
        .for_simple,
        .@"for",
        .@"switch",
        .switch_comma,
        .@"catch",
        .@"orelse",
        .struct_init_one,
        .struct_init_one_comma,
        .struct_init,
        .struct_init_comma,
        .field_access,
        => true,
        else => false,
    };
}

/// The tracked nodes a walk left unvisited, in node order. `visited` holds one flag per node, from a walk with
/// `Ctx.visited` set. Node 0 is the file's root container - where the walk starts, not a node it reaches - so it is
/// skipped.
fn unwalkedNodes(gpa: Allocator, ast: *const Ast, visited: []const bool) ![]Index {
    var unwalked: ArrayList(Index) = .empty;
    errdefer unwalked.deinit(gpa);
    for (visited[1..], 1..) |was_visited, node_number| {
        const node: Index = @fromBackingInt(@intCast(node_number));
        if (!was_visited and isCoverageTracked(ast.nodeTag(node))) {
            try unwalked.append(gpa, node);
        }
    }
    return unwalked.toOwnedSlice(gpa);
}

/// Walk `ast` the way `runChecks` does - every root declaration, at container position - recording what `walkNode`
/// reaches, and return the tracked nodes it did not reach. The checks run as usual along the way (running them is
/// what the walk is for); their findings land in a scratch list and are dropped: coverage is about WHERE the checks
/// ran, not what they said.
fn walkCoverage(
    gpa: Allocator,
    path: []const u8,
    source_z: [:0]const u8,
    ast: *const Ast,
) ![]Index {
    const visited: []bool = try gpa.alloc(bool, ast.nodes.len);
    defer gpa.free(visited);
    @memset(visited, false);
    var scratch_issues: ArrayList(Issue) = .empty;
    defer {
        for (scratch_issues.items) |issue| {
            issue.deinit(gpa);
        }
        scratch_issues.deinit(gpa);
    }
    const ctx: Ctx = .{
        .alloc = gpa,
        .path = path,
        .source = source_z,
        .ast = ast,
        .issues = &scratch_issues,
        .visited = visited,
    };
    for (ast.rootDecls()) |decl| {
        try walkNode(ctx, decl, .container, 0);
    }
    return unwalkedNodes(gpa, ast, visited);
}

/// SCRATCH (L2 measurement): what opens the block enclosing token `token` - the reason a statement there was missed.
fn enclosingBlockOpener(ast: *const Ast, token: u32) []const u8 {
    const tags: []const std.zig.Token.Tag = ast.tokens.items(.tag);
    var depth: u32 = 0;
    var cursor: u32 = token;
    while (cursor > 0) {
        cursor -= 1;
        switch (tags[cursor]) {
            .r_brace => depth += 1,
            .l_brace => {
                if (depth == 0) {
                    if (cursor == 0) {
                        return "the file";
                    }
                    const opener: std.zig.Token.Tag = tags[cursor - 1];
                    const before_opener: std.zig.Token.Tag = if (cursor >= 2) tags[cursor - 2] else .invalid;
                    return switch (opener) {
                        .equal_angle_bracket_right => "a `switch` prong's block",
                        .pipe => "a block after a capture |x|",
                        .keyword_comptime => "a `comptime` block",
                        .keyword_defer, .keyword_errdefer => "a defer block",
                        .keyword_else => "an `else` block",
                        .colon => "a labeled block",
                        .r_paren => switch (before_opener) {
                            .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => "a container's members",
                            else => "a block after ')' (if/while/for/fn body, or a tagged container)",
                        },
                        .keyword_struct, .keyword_union, .keyword_enum, .keyword_opaque => blk: {
                            const before_keyword: std.zig.Token.Tag = if (cursor >= 2) tags[cursor - 2] else .invalid;
                            break :blk switch (before_keyword) {
                                .keyword_return => "the members of a container in a `return`",
                                .equal => "the members of a container after '='",
                                .l_paren, .comma => "the members of a container passed as an argument",
                                .keyword_packed, .keyword_extern => "the members of a packed/extern container",
                                else => "the members of a container (other)",
                            };
                        },
                        .keyword_test, .string_literal, .identifier => "a test or named block",
                        else => @tagName(opener),
                    };
                }
                depth -= 1;
            },
            else => {},
        }
    }
    return "the file";
}

/// SCRATCH (L2 measurement): a short label for where an unwalked ROOT sits.
fn coverageContext(ast: *const Ast, node: Index) []const u8 {
    const tags: []const std.zig.Token.Tag = ast.tokens.items(.tag);
    const first: u32 = ast.firstToken(node);
    const last: u32 = ast.lastToken(node);
    const next: std.zig.Token.Tag = if (last + 1 < tags.len) tags[last + 1] else .eof;
    switch (ast.nodeTag(node)) {
        .simple_var_decl,
        .local_var_decl,
        .global_var_decl,
        .aligned_var_decl,
        .fn_decl,
        .test_decl,
        .if_simple,
        .@"if",
        .while_simple,
        .while_cont,
        .@"while",
        .for_simple,
        .@"for",
        .@"switch",
        .switch_comma,
        => {
            const previous: std.zig.Token.Tag = if (first > 0) tags[first - 1] else .invalid;
            if (previous == .semicolon or previous == .l_brace or previous == .r_brace or
                previous == .doc_comment or previous == .container_doc_comment or previous == .keyword_pub)
            {
                return enclosingBlockOpener(ast, first);
            }
        },
        .field_access => {
            if (next == .l_paren) {
                return "a callee, read through its call";
            }
            if (next == .period) {
                return "a receiver, read through its field access";
            }
        },
        else => {},
    }
    if (first == 0) {
        return "the file's first token";
    }
    const previous: std.zig.Token.Tag = tags[first - 1];
    const before_previous: std.zig.Token.Tag = if (first >= 2) tags[first - 2] else .invalid;
    return switch (previous) {
        .colon => "after ':' - a type",
        .l_paren => switch (before_previous) {
            .keyword_if => "an `if` condition",
            .keyword_while => "a `while` condition",
            .keyword_switch => "a `switch` operand",
            .keyword_for => "a `for` operand",
            else => "after '(' - a first argument or a grouped expression",
        },
        .r_paren => "after ')' - a return type, or an if/while/for branch",
        .keyword_return => "a `return` value",
        .equal => "after '=' - an initializer or assignment",
        .comma => "after ',' - a later argument or element",
        .keyword_try => "after `try`",
        .keyword_orelse => "after `orelse`",
        .keyword_catch => "after `catch`",
        .pipe => "after a capture |x| (a catch/if/while body)",
        .equal_angle_bracket_right => "a `switch` prong's value",
        .keyword_else => "an `else` value",
        .l_bracket => "an index or array type",
        .bang => "after '!' - an error union's payload type",
        .question_mark => "after '?' - an optional's payload type",
        .asterisk => "after '*' - a pointer type, or a product",
        else => @tagName(previous),
    };
}

/// `--coverage`: the walk's own check. Every tracked node of every file must be walked - a node the walk misses is code
/// no rule can see. Prints the ROOTS only (outermost unwalked tracked nodes, by token span), each labelled by
/// `coverageContext`, and FAILS when there is any: the build's `lint-coverage` step (run by the gate) keeps the walk
/// complete as rules, the walker and the language move.
fn runCoverage(io: Io, gpa: Allocator, files: []const []const u8) !u8 {
    var out_buffer: [4096]u8 = undefined;
    var out_writer: Io.File.Writer = Io.File.stdout().writer(io, &out_buffer);
    const out: *Io.Writer = &out_writer.interface;
    // Outermost unwalked nodes, and the files holding any - the summary, and the exit code.
    var root_count: usize = 0;
    var files_with_roots: usize = 0;
    for (files) |path| {
        var file_counted: bool = false;
        const source: []u8 = Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch continue;
        defer gpa.free(source);
        const source_z: [:0]u8 = try gpa.allocSentinel(u8, source.len, 0);
        defer gpa.free(source_z);
        @memcpy(source_z, source);
        var ast: Ast = try .parse(gpa, source_z, .{ .mode = .zig });
        defer ast.deinit(gpa);
        if (ast.errors.len > 0) {
            continue;
        }
        const unwalked: []Index = try walkCoverage(gpa, path, source_z, &ast);
        defer gpa.free(unwalked);
        // Every unwalked node, for the totals by kind.
        for (unwalked) |node| {
            try out.print("ALL\t{s}\n", .{@tagName(ast.nodeTag(node))});
        }
        // Roots: sort by (first token ascending, last token descending), sweep with the end of the open root.
        const Span = struct { first: u32, last: u32, node: Index };
        const spans: []Span = try gpa.alloc(Span, unwalked.len);
        defer gpa.free(spans);
        for (unwalked, spans) |node, *span| {
            span.* = .{ .first = ast.firstToken(node), .last = ast.lastToken(node), .node = node };
        }
        sortSlice(Span, spans, {}, struct {
            fn lessThan(_: void, a: Span, b: Span) bool {
                return a.first < b.first or (a.first == b.first and a.last > b.last);
            }
        }.lessThan);
        var open_root_end: ?u32 = null;
        for (spans) |span| {
            if (open_root_end) |end| {
                if (span.first <= end) {
                    continue;
                } // inside the open root
            }
            open_root_end = span.last;
            const location: Ast.Location = ast.tokenLocation(0, span.first);
            const kind: []const u8 = @tagName(ast.nodeTag(span.node));
            const context: []const u8 = coverageContext(&ast, span.node);
            try out.print("ROOT\t{s}\t{s}\t{s}:{d}\n", .{ kind, context, path, location.line + 1 });
            root_count += 1;
            if (!file_counted) {
                files_with_roots += 1;
                file_counted = true;
            }
        }
    }
    if (root_count > 0) {
        try out.print("{d} unwalked node(s) in {d} file(s): every rule is blind there - teach the walker " ++
            "(`allChildren`, `walkNode`)\n", .{ root_count, files_with_roots });
    }
    try out.flush();
    return if (root_count > 0) 1 else 0;
}

/// The bare constructor words `constructor-in-view` watches - the whole name, nothing more. `.init(gpa)` says nothing
/// about what it makes; `.initBozo(gpa)` or `.fromSlice(s)` carries its own words and is left alone. The convention of
/// naming constructors `init` stays: the short call is for where the declaration names the type.
const constructor_words = [_][]const u8{
    "init", "create", "alloc", "new",  "from",  "clone", "dupe",   "copy",
    "make", "build",  "load",  "open", "parse", "spawn", "decode",
};

fn isBareConstructorWord(name: []const u8) bool {
    for (constructor_words) |word| {
        if (eql(u8, name, word)) {
            return true;
        }
    }
    return false;
}

/// Mark the calls that ARE a typed declaration's value - its initializer, through `try`, both sides of `catch` and
/// `orelse`, parentheses, `if` / `else` branches, `switch` prongs and the elements of the array it declares. The only
/// places a decl-literal constructor's type is in view.
fn markDeclarationValue(ast: *const Ast, node: Index, in_view: *std.DynamicBitSetUnmanaged) void {
    switch (ast.nodeTag(node)) {
        .@"try" => markDeclarationValue(ast, ast.nodeData(node).node, in_view),
        .@"catch", .@"orelse" => {
            const sides: [2]Index = ast.nodeData(node).node_and_node;
            markDeclarationValue(ast, sides[0], in_view);
            markDeclarationValue(ast, sides[1], in_view);
        },
        .grouped_expression => markDeclarationValue(ast, ast.nodeData(node).node_and_token[0], in_view),
        .if_simple, .@"if" => {
            const branches: Ast.full.If = ast.fullIf(node).?;
            markDeclarationValue(ast, branches.ast.then_expr, in_view);
            if (branches.ast.else_expr.unwrap()) |else_expr| {
                markDeclarationValue(ast, else_expr, in_view);
            }
        },
        .@"switch", .switch_comma => {
            const choice: Ast.full.Switch = ast.fullSwitch(node).?;
            for (choice.ast.cases) |case_node| {
                const prong: Ast.full.SwitchCase = ast.fullSwitchCase(case_node).?;
                markDeclarationValue(ast, prong.ast.target_expr, in_view);
            }
        },
        // The elements of the array a declaration declares: `[2]Graph(f64)` spells each element's type.
        .array_init_one,
        .array_init_one_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init,
        .array_init_comma,
        => {
            var buffer: [2]Index = undefined;
            const array: Ast.full.ArrayInit = ast.fullArrayInit(&buffer, node).?;
            for (array.ast.elements) |element| {
                markDeclarationValue(ast, element, in_view);
            }
        },
        .call, .call_comma, .call_one, .call_one_comma => in_view.set(@backingInt(node)),
        else => {},
    }
}

/// `constructor-in-view`: a decl-literal call to a bare constructor word, anywhere but a typed declaration's
/// value. Two passes over the nodes: mark every typed declaration's value, then report every other
/// decl-literal constructor.
fn checkConstructorInView(ctx: Ctx) !void {
    const ast: *const Ast = ctx.ast;
    var in_view: std.DynamicBitSetUnmanaged = try .initEmpty(ctx.alloc, ast.nodes.len);
    defer in_view.deinit(ctx.alloc);
    for (0..ast.nodes.len) |index| {
        const declaration: Ast.full.VarDecl = ast.fullVarDecl(@fromBackingInt(@intCast(index))) orelse continue;
        if (declaration.ast.type_node == .none) {
            continue;
        }
        const value: Index = declaration.ast.init_node.unwrap() orelse continue;
        markDeclarationValue(ast, value, &in_view);
    }
    // A container field names its type on its own line too: `cam: OrbitCamera = .init(...)`, its default value.
    for (0..ast.nodes.len) |index| {
        const field: Ast.full.ContainerField = ast.fullContainerField(@fromBackingInt(@intCast(index))) orelse continue;
        if (field.ast.type_expr == .none) {
            continue;
        }
        const default_value: Index = field.ast.value_expr.unwrap() orelse continue;
        markDeclarationValue(ast, default_value, &in_view);
    }
    for (0..ast.nodes.len) |index| {
        const node: Index = @fromBackingInt(@intCast(index));
        const callee: Index = switch (ast.nodeTag(node)) {
            .call, .call_comma => ast.nodeData(node).node_and_extra[0],
            .call_one, .call_one_comma => ast.nodeData(node).node_and_opt_node[0],
            else => continue,
        };
        if (ast.nodeTag(callee) != .enum_literal or in_view.isSet(index)) {
            continue;
        }
        const name_token: u32 = ast.nodeMainToken(callee);
        const name: []const u8 = ast.tokenSlice(name_token);
        if (!isBareConstructorWord(name)) {
            continue;
        }
        try ctx.emitAt(
            name_token,
            "constructor-in-view",
            0,
            "`.{s}(...)` builds a value whose type is not named here - spell it (`T.{s}(...)`), " ++
                "or give it a typed declaration first",
            .{ name, name },
        );
    }
}

fn runChecks(ctx: Ctx) !void {
    try checkConstructorInView(ctx);
    // Fast path for the reorder tooling: run ONLY the decl-order check and skip
    // the full node walk + every other rule. Turns an O(all-rules) pass into a
    // single O(nodes) pass, which is what makes iterative reordering of large
    // files tractable.
    if (ctx.decl_order_only) {
        try runDeclOrder(ctx);
        return;
    }
    // Kick off the walk from every root decl.  Module scope
    // counts as container position with no enclosing function.
    for (ctx.ast.rootDecls()) |decl| {
        try walkNode(ctx, decl, .container, 0);
    }

    // -- *** std-math IS SWEPT OVER EVERY NODE, NOT WALKED --
    //
    // `childNodes` enumerates tags and returns NO children for anything unlisted, and `walkNode`
    // visits only some children of the tags it does handle - `if`/`while` bodies but never their
    // CONDITIONS, for instance. Every gap is a place a rule silently does not apply, and they
    // were found one at a time by grepping for violations the linter reported zero of:
    // `.assign` right-hand sides, `.while_cont` bodies, positional `.{ a, b, c }` initialisers,
    // `if (std.math.isNan(x))` conditions. Each fix revealed the next.
    //
    // `std-math` is the rule that cannot afford any of them: it has no `lint:off`, and what it
    // guards is that zimr's math compiles for SPIR-V at all. So it does not participate in the
    // walk. It runs over EVERY node index in the file, which is complete by construction and
    // cannot develop a new blind spot when an unfamiliar syntax shape appears.
    //
    // The other rules stay on the walk because they need `pos` (statement vs expression) or
    // `fn_depth`, which a flat sweep does not have. Widening them is worth doing and is a
    // separate job: each newly-reached node is a violation that has to be either fixed or
    // baselined, and doing it rule-by-rule keeps that reviewable.
    {
        var node_index: u32 = 0;
        while (node_index < ctx.ast.nodes.len) : (node_index += 1) {
            const n: Index = @fromBackingInt(@intCast(node_index));
            try checkStdMath(ctx, n, ctx.ast.nodeTag(n));
        }
    }
    // Two checks operate on the whole file in one go rather than
    // node-by-node, so they live outside the walk.
    try runLineLength(ctx);
    try runAsciiComments(ctx);
    try runUnknownLintTags(ctx);
    try runDepthFormat(ctx);
    try runShaderChecks(ctx);
    try runShaderSafeChecks(ctx);
    try runSamplerDiscipline(ctx);
    try runCanonicalAlias(ctx);
    try runImportAtRoot(ctx);
    try runWholeInitFirst(ctx);
    try runRedundantImports(ctx);
    try runUnusedPrivateGlobals(ctx);
    try runScreamingConsts(ctx);
    try checkScopeBalance(ctx);
    if (ctx.check_decl_order) {
        try runDeclOrder(ctx);
    }
}

/// Files scheduled for deletion: the doomed GL backend, plus the top-level GL example
/// programs that are being ported to `examples/wgpu_*/` or dropped as redundant. The linter
/// skips these entirely - there's no point enforcing style on code about to be removed.
/// Shader sources (`_fs.zig`/`_vs.zig`) are NOT skipped: they are live and the shader rules
/// still apply to them.
fn isSkipped(path: []const u8) bool {
    // GL-retirement P5 (t1176): the doomed-file lists are gone - the files
    // are deleted.  What remains are DATA files: machine-written arrays that
    // a Zig file imports as an asset or a test oracle.  Style rules like
    // line-length and untyped-local describe how a human should write code;
    // they say nothing useful about a generated number table, and the
    // generator would have to be taught to satisfy them for no gain.
    //   * quad_glb_data.zig  - an embedded GLB byte array (wgpu example asset)
    //   * tests/fixtures/    - generated reference data, e.g. the robot.zig
    //                          oracle emitted by scripts/robot_oracle.py
    const sep = std.fs.path.sep_str;
    if (endsWith(u8, path, "examples" ++ sep ++ "quad_glb_data.zig")) {
        return true;
    }
    return indexOf(u8, path, "tests" ++ sep ++ "fixtures" ++ sep) != null;
}

/// Text-based scan for shader-DSL-specific footguns.  Fires only on
/// `_fs.zig` / `_vs.zig` files (path-suffix detected).  See
/// `src/notes/shader-style.md` for the full do/don't list.

// ===========================================================================
// SHADER-SAFE tier (structure-plan S5, t1177).
//
// A file whose first line is `//! SHADER-SAFE` (plus every `*_io.zig`,
// implied by suffix) promises it can be @imported by shader sources
// compiled through the SPIR-V pipeline and by comptime executors.  The
// checkable subset of that promise: no allocators, no runtime std
// facilities, no extern declarations, no wasm-bridge imports - outside
// `test` blocks (host tests are fine; they never enter the pipeline).
// ===========================================================================

// ===========================================================================
// Sampler-at-top discipline (shader files).
//
// WGSL forbids calling an implicit-LOD sampler (`textureSample`) from
// non-uniform control flow.  The robust, checkable rule: every texture
// sample must be taken at the unconditional top of `shaderMain` and its
// value threaded down - never inside an `if`/loop, and never inside a
// helper fn (which may be called conditionally).  This catches the class
// of bug that otherwise only surfaces as a Tint validation error at
// runtime, since neither naga nor nagac enforces uniformity.
//
// Detection is schema-free: samplers are the only *callable* members of
// an `Io` struct (uniforms/inputs are plain fields, read without `()`),
// so any `<io>.<method>(...)` call is a sample.  The Io parameter is
// found by its type (`Io`), so the rule works regardless of its name.
// ===========================================================================

// ============================================================================
// Individual checks.
// ============================================================================

// (checkArrayMult removed: Zig 0.17 retired the `**` operator and its AST
// node, so the lint rule that flagged `**` usage is obsolete.
// See src/notes/zig17_migration.md.)

// ============================================================================
// reserved-math-names (R1).  See RESERVED_MATH_PLAN.md.
// ============================================================================

fn isPlainIdent(s: []const u8) bool {
    for (s, 0..) |c, i| {
        const ok: bool = c == '_' or
            (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (i > 0 and c >= '0' and c <= '9');
        if (!ok) {
            return false;
        }
    }
    return true;
}

/// Collect whole-module import aliases declared in `source` for the import
/// whose init equals `needle` (e.g. ` = @import("zm")` or ` = @import("std")`):
/// `const X =<needle>;` / `pub const X =<needle>;`.  Decl-imports like
/// `const Vec = @import("zm").Vec;` are NOT module aliases and are excluded by
/// requiring the init to terminate right after the needle.  Slices point into
/// `source`.  Returns the count written into `out`.
fn collectImportAliases(source: []const u8, out: [][]const u8, needle: []const u8) usize {
    var n: usize = 0;
    var it: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, source, '\n');
    while (it.next()) |raw| {
        if (n >= out.len) {
            break;
        }
        var line: []const u8 = std.mem.trimStart(u8, raw, " \t");
        if (startsWith(u8, line, "pub ")) {
            line = line["pub ".len..];
        }
        if (!startsWith(u8, line, "const ")) {
            continue;
        }
        const after: []const u8 = line["const ".len..];
        const eq: usize = indexOf(u8, after, needle) orelse continue;
        // Whole-module only: the char after `@import("zm")` must end the init
        // (`;`), not continue into a field access (`.Vec`).
        const tail: []const u8 = after[eq + needle.len ..];
        if (tail.len == 0 or tail[0] != ';') {
            continue;
        }
        const ident: []const u8 = trim(u8, after[0..eq], " \t");
        if (ident.len == 0 or !isPlainIdent(ident)) {
            continue;
        }
        out[n] = ident;
        n += 1;
    }
    return n;
}

/// True when the source has a column-0 (file-scope) `const zm = @import("zm")`
/// or `pub const zm = @import("zm")`.  Lines are tested WITHOUT trimming, so an
/// indented per-struct import does not match.  Drives `no-qualified-zm`'s scope
/// (see the `zm_col0` field on Ctx).
fn hasCol0ZmImport(source: []const u8) bool {
    var it: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        var l: []const u8 = line;
        if (startsWith(u8, l, "pub ")) {
            l = l["pub ".len..];
        }
        if (startsWith(u8, l, "const zm = @import(\"zm\")")) {
            return true;
        }
    }
    return false;
}

/// True when the source has a column-0 (file-scope) `const std = @import("std")`
/// or `pub const std = @import("std")`.  Drives `no-qualified-std`'s scope: a
/// file whose only std import is function-local (e.g. zimr.zig's logFn) can't
/// host a file-scope alias and is exempt.  Mirrors `hasCol0ZmImport`.
fn hasCol0StdImport(source: []const u8) bool {
    var it: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        var l: []const u8 = line;
        if (startsWith(u8, l, "pub ")) {
            l = l["pub ".len..];
        }
        if (startsWith(u8, l, "const std = @import(\"std\")")) {
            return true;
        }
    }
    return false;
}

/// Pre-pass for `no-qualified-zm` and `no-qualified-std`: set `out[node] = true` for every binding-init node
/// of `family` - the init of `const <alias> = <root>.<member>;` where the family binds that member to that
/// alias - so the rules can skip that one legal qualified use. `out` is sized to `ast.nodes.len`. One pass.
fn markCanonicalInits(ast: *const Ast, roots: []const []const u8, family: AliasFamily, out: []bool) void {
    var node_number: usize = 0;
    while (node_number < ast.nodes.len) : (node_number += 1) {
        const node: Index = @fromBackingInt(@intCast(node_number));
        const var_decl: Ast.full.VarDecl = ast.fullVarDecl(node) orelse continue;
        const init: Index = var_decl.ast.init_node.unwrap() orelse continue;
        const member: QualifiedMember = qualifiedMember(ast, init, roots) orelse continue;
        const bound_to: []const u8 = family.aliasFor(member) orelse continue;
        const declared_name: []const u8 = ast.tokenSlice(var_decl.ast.mut_token + 1);
        if (eql(u8, bound_to, declared_name)) {
            out[@backingInt(init)] = true;
        }
    }
}

/// `markCanonicalInits` for zm (`const X = zm.X;`).
fn markCanonicalZmInits(ast: *const Ast, aliases: []const []const u8, out: []bool) void {
    markCanonicalInits(ast, aliases, .zm, out);
}

// True if `node` is a call to one of the float->int rounding builtins
// (@trunc / @floor / @round / @ceil).  Each takes one arg, so they parse as
// builtin_call_two with a single populated slot.

// If `node` is a call to a zimrmath float->int cast helper - `zm.int`,
// `zm.floori`, `zm.roundi`, `zm.ceili` (or the bare names inside zimrmath
// itself) - return the helper name; else null.  Used to spot a helper whose
// explicit target type is already pinned by an enclosing typed decl.

// Ban @as(T, @trunc(x)) and friends.  The rounding builtins convert straight
// to an integer once the result type is known, so the @as wrapper is never
// right: drop it (`@trunc(x)`) when T is inferable, or use the zm.int / floori
// / roundi / ceili helper when T must be spelled.  Purely syntactic - an @as
// whose VALUE argument (the second one) is a rounding builtin call.

// Ban @intFromFloat outright.  In current Zig the rounding builtins
// `@trunc`/`@floor`/`@round`/`@ceil` perform the float->int conversion
// directly when the result type is an integer (e.g. `const i: i32 =
// @trunc(x);`), so `@intFromFloat(@trunc(x))` is redundant - just write
// `@trunc(x)`.  Using the rounding builtin directly also names the rounding
// mode at the call site, killing the silent truncate-toward-zero footgun that
// bare `@intFromFloat(x)` used to hide.  (The narrower `floor-pattern` rule
// above still offers the more specific "prefer @floor" hint if @intFromFloat
// reappears; this is the general gate.)

// ============================================================================
// Whole-file checks (no AST walk needed / cross-cutting).
// ============================================================================

// Rule 5 (array-mult): flag the retired `**` array-repetition operator. Done
// as a raw-byte scan because `**` is a parse error in this toolchain (it no
// longer tokenizes), so an AST check can never see it. Skips string literals
// (" and \\ multiline), char literals ('), and comments (//) so a `**` inside
// text or prose doesn't false-positive. Emits at most one finding per line.
/// `raw-pass-state-bind`: flag raw `render_pass.setPipeline(` /
/// `render_pass.setBindGroup(` outside the pass-state wrapper. These bypass the
/// PassState dedup caches; see the rule_notes body. gpu_iface.zig (the cache
/// owner) and wgpu.zig (the raw layer) are exempt. Comment lines are skipped and
/// a `// lint:off raw-pass-state-bind` suppresses a reviewed exception.
fn scanRawPassBind(
    gpa: Allocator,
    path: []const u8,
    src: [:0]const u8,
    issues: *ArrayList(Issue),
) !void {
    if (endsWith(u8, path, "gpu_iface.zig") or endsWith(u8, path, "wgpu.zig")) {
        // gpu_iface.zig owns the caches and wgpu.zig defines the raw primitives, so
        // they legitimately call these directly. (This linter file ALSO holds the
        // needles as rule data, but it opts out with a file-level `//! lint:off`
        // in its header instead of being special-cased here by name -- so the linter
        // can lint itself, and a rename can't silently un-exempt it.)
        return;
    }
    const needles = [_][]const u8{ "render_pass.setPipeline(", "render_pass.setBindGroup(" };
    var line: u32 = 1;
    var it: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, src, '\n');
    while (it.next()) |raw| : (line += 1) {
        const trimmed: []const u8 = std.mem.trimStart(u8, raw, " \t");
        if (startsWith(u8, trimmed, "//") or startsWith(u8, trimmed, "\\\\")) {
            continue; // comment / doc line or multiline-string literal line
        }
        for (needles) |needle| {
            const at: usize = indexOf(u8, raw, needle) orelse continue;
            if (lineSuppressedByDirective(src, line, "raw-pass-state-bind")) {
                continue;
            }
            const msg: []u8 = try allocPrint(
                gpa,
                "raw `{s}...)` bypasses the PassState dedup cache - use " ++
                    "WgpuBackend.setPipelineHandle / setPipeline / setBindGroup",
                .{needle},
            );
            try issues.append(gpa, .{
                .file = path,
                .line = line,
                .col = @intCast(at + 1),
                .tag = "raw-pass-state-bind",
                .message = msg,
                .rule = 0,
            });
        }
    }
}

/// A `_fs.zig`/`_vs.zig` GPU shader body - one that imports its generated
/// `*_externs` module and defines `shaderMain` - MUST bind the SPIR-V entry
/// with `installSpirvEntry(shaderMain)`. Forgetting it compiles clean AND
/// passes the headless smoke: `shaderMain` is then unreferenced, the SPIR-V
/// backend dead-strips it, spv2wgsl emits an entry-less (empty) module, and the
/// failure only surfaces on a real GPU as `CreateRenderPipeline(... entryPoint
/// "entry" doesn't exist)`. That device-only blind spot is exactly why this is
/// a lint rule - the gate is the last place it can be caught before hardware.
fn scanShaderEntry(
    gpa: Allocator,
    path: []const u8,
    src: [:0]const u8,
    issues: *ArrayList(Issue),
) !void {
    if (!isShaderPath(path)) {
        return;
    }
    // Only new-API GPU shader bodies: they import the generated `*_externs`
    // module. Old-API (`extern var out_color` + `setup()`) and CPU/software
    // shaders don't, so they're correctly out of scope.
    if (indexOf(u8, src, "_externs\")") == null) {
        return;
    }
    if (indexOf(u8, src, "shaderMain") == null) {
        return;
    }
    if (indexOf(u8, src, "installSpirvEntry") != null) {
        return;
    }
    // Point at the shaderMain definition - that's what needs binding.
    const at: usize = indexOf(u8, src, "pub fn shaderMain") orelse
        indexOf(u8, src, "shaderMain").?;
    var line: u32 = 1;
    var col: u32 = 1;
    var i: usize = 0;
    while (i < at) : (i += 1) {
        if (src[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    if (lineSuppressedByDirective(src, line, "shader-missing-entry")) {
        return;
    }
    const msg: []u8 = try allocPrint(
        gpa,
        "GPU shader defines `shaderMain` and imports its `_externs` module but never calls " ++
            "`installSpirvEntry(shaderMain)` - shaderMain is dead-stripped, the shader emits no " ++
            "entry point, and CreateRenderPipeline fails on device. Add " ++
            "`comptime {{ _ = shader_externs.installSpirvEntry(shaderMain); }}` at file scope.",
        .{},
    );
    try issues.append(gpa, .{
        .file = path,
        .line = line,
        .col = col,
        .tag = "shader-missing-entry",
        .message = msg,
        .rule = 0,
    });
}

fn scanArrayMult(
    gpa: Allocator,
    path: []const u8,
    src: []const u8,
    issues: *ArrayList(Issue),
) !void {
    var line: u32 = 1;
    var col: u32 = 1;
    var i: usize = 0;
    var last_flagged_line: u32 = 0;
    while (i < src.len) {
        const c: u8 = src[i];
        // Line comment: skip to end of line.
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') {
                i += 1;
            }
            continue;
        }
        // Char literal: skip to closing ' (handle escapes).
        if (c == '\'') {
            i += 1;
            col += 1;
            while (i < src.len and src[i] != '\'') {
                if (src[i] == '\\') {
                    i += 1;
                    col += 1;
                }
                if (i < src.len and src[i] == '\n') {
                    line += 1;
                    col = 1;
                } else {
                    col += 1;
                }
                i += 1;
            }
            if (i < src.len) {
                i += 1;
                col += 1;
            }
            continue;
        }
        // String literal: skip to closing " (handle escapes).
        if (c == '"') {
            i += 1;
            col += 1;
            while (i < src.len and src[i] != '"') {
                if (src[i] == '\\') {
                    i += 1;
                    col += 1;
                }
                if (i < src.len and src[i] == '\n') {
                    line += 1;
                    col = 1;
                } else {
                    col += 1;
                }
                i += 1;
            }
            if (i < src.len) {
                i += 1;
                col += 1;
            }
            continue;
        }
        // Multiline string line: `\\...` runs to end of line, all literal.
        if (c == '\\' and i + 1 < src.len and src[i + 1] == '\\') {
            while (i < src.len and src[i] != '\n') {
                i += 1;
            }
            continue;
        }
        // The operator: two adjacent '*' not part of a longer run.
        if (c == '*' and i + 1 < src.len and src[i + 1] == '*') {
            const prev_star: bool = i > 0 and src[i - 1] == '*';
            if (!prev_star and line != last_flagged_line) {
                const msg: []u8 = try allocPrint(
                    gpa,
                    "`**` array-repetition is retired - use @splat(value) " ++
                        "(or expand to an explicit literal)",
                    .{},
                );
                try issues.append(gpa, .{
                    .file = path,
                    .line = line,
                    .col = col,
                    .tag = "array-mult",
                    .message = msg,
                    .rule = 5,
                });
                last_flagged_line = line;
            }
        }
        if (c == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
        i += 1;
    }
}

// ============================================================================
// Driver.
// ============================================================================

/// Where the per-file clean stamps live unless `--cache-dir` says otherwise:
/// zimr's own tools cache, which survives `rm -rf .zig-cache` at the root.
const default_stamp_dir = "tools/.zig-cache/lint-stamps";

const Args = struct {
    files: ArrayList([]const u8),
    /// `--baseline <path>` grandfathers the violations a tree already has.
    ///
    /// WHY THIS EXISTS. `childNodes` returned no children for `.assign` and `.while_cont`, so
    /// every rule in this file silently skipped assignment right-hand sides and the bodies of
    /// `while (i < n) : (i += 1)` loops. Fixing the walk exposed 606 pre-existing violations -
    /// the tree was never clean, the walk was just blind, and the "after all rules cleared"
    /// comment on the hard gate below was true only of what the walker could see.
    ///
    /// Reverting the fix would re-hide real bugs; failing on all 606 would leave every build red
    /// and the gate would get switched off. So: a RATCHET. The baseline records a count per
    /// (file, tag); anything at or under it is grandfathered, anything ABOVE it fails. New code
    /// is held to the rule from today, the backlog is visible in one file, and burning it down
    /// is a matter of deleting lines.
    ///
    /// Keyed by (file, tag) rather than by line, so an unrelated edit that moves a line does not
    /// spuriously fail.
    baseline_path: ?[]const u8 = null,
    /// `--write-baseline` regenerates that file from the current tree instead of checking
    /// against it. Run it only when deliberately accepting a new backlog.
    write_baseline: bool = false,
    /// `--enable=<tag>[,<tag>...]` turns rules on - every rule is opt-in, so this is the whole configuration.
    /// A tag that is not a rule is a usage error.
    enabled: EnabledRules = @splat(false),
    /// `--decl-order-only` runs ONLY the decl-order check (implies enabling it).
    decl_order_only: bool = false,
    /// `--reorder-decls` repairs decl-order instead of linting: each file's declarations are hoisted above
    /// their first use (`reorderDecls`), and the file rewritten unless `--dry-run`.
    reorder_decls: bool = false,
    /// `--coverage`: report where the rule walk is blind (`runCoverage`) instead of linting.
    coverage: bool = false,
    /// `--fix-command`: what a reader runs to apply the autofixes - `zig build fix` from zimr's build and from a
    /// project's. Null: the linter's own advice, `fix_command_default`.
    fix_command: ?[]const u8 = null,
    /// `--fix` applies the mechanical autofixes in place (mirrors `zig fmt`'s
    /// write mode). Off by default so the gate stays a pure check.
    fix: bool = false,
    /// `--check` is an explicit alias of the default (report-only); accepted for
    /// `zig fmt --check` muscle memory.
    check: bool = false,
    /// `--dry-run` (with `--fix`) reports what would change but writes nothing.
    dry_run: bool = false,
    /// `--list-rules` prints every rule tag, marking those still in progress, and exits.
    list_rules: bool = false,
    /// `--cache-dir <dir>` puts the per-file clean stamps somewhere other than
    /// zimr's `tools/.zig-cache/lint-stamps` - an app linting its own sources
    /// passes its build cache, so nothing is written into its source tree.
    cache_dir: []const u8 = default_stamp_dir,

    /// Module alias declarations gathered from every input file's
    /// `//! lint:alias <name>` header, driving `canonical-alias`.
    aliases: []const AliasDecl = &.{},

    fn deinit(self: *Args, alloc: Allocator) void {
        self.files.deinit(alloc);
    }
};

// ============================================================================
// Per-file mtime cache (turn 382).
// ============================================================================

// Files are linted in one batch but we don't want to re-process clean
// files on every invocation.  For each file passed in, we maintain a
// stamp at `<cache-dir>/<hash>.stamp` containing the source file's
// mtime AND the lint binary's mtime at the moment we last produced 0
// issues for that file.
//
// If both mtimes match on the next run, the file is skipped.  Editing
// any file re-lints just that file.  Rebuilding the linter (binary
// mtime changes) invalidates every stamp.  Result: warm `zig build
// lint-check` after a single-file edit drops from ~2.4s to ~0.X s.
// See turn 382 notes.

const Stamp = extern struct {
    source_mtime_ns: i128,
    binary_mtime_ns: i128,
    /// Hash of everything besides the file itself that decides its verdict:
    ///   * every `//! lint:alias` declaration in the run - `canonical-alias`
    ///     makes one file's verdict depend on ANOTHER file's header, so editing
    ///     zimrmath.zig's directive must invalidate every importer's "clean";
    ///   * which rules are enabled - a file clean without untyped-local
    ///     is not clean with it, and before this was folded in, a run with a
    ///     new `--enable` skipped every stamped file and reported nothing;
    ///   * `--decl-order-only`, which runs one rule and so proves nothing about
    ///     the rest.
    config_hash: u64,
};

fn stampPathFor(arena: Allocator, cache_dir: []const u8, source_path: []const u8) ![]const u8 {
    // Hash the path so source files at deep paths still map to a flat
    // stamp filename.  Wyhash is plenty for collision avoidance
    // among ~150 files.
    const hash: u64 = std.hash.Wyhash.hash(0, source_path);
    return allocPrint(arena, "{s}/{x:0>16}.stamp", .{ cache_dir, hash });
}

fn loadStamp(
    io: Io,
    alloc: Allocator,
    sp: []const u8,
) ?Stamp {
    const bytes: []u8 = Io.Dir.cwd().readFileAlloc(io, sp, alloc, .unlimited) catch return null;
    defer alloc.free(bytes);
    if (bytes.len != @sizeOf(Stamp)) {
        return null;
    }
    var stamp: Stamp = undefined;
    @memcpy(asBytes(&stamp), bytes);
    return stamp;
}

/// Writes `bytes` to the file at `path` whole or not at all: into an unnamed file beside it, which then replaces it in
/// one step (`Io.Dir.createFileAtomic`, `File.Atomic.replace`). A run stopped mid-write - a build stopped at its first
/// finding, or Ctrl-C - leaves the old file as it was, never a file cut short. Creating the file and writing into it,
/// as `writeFile` does, would truncate it first.
fn writeFileWhole(io: Io, path: []const u8, bytes: []const u8) !void {
    var atomic_file: Io.File.Atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, bytes);
    try atomic_file.replace(io);
}

fn writeStamp(
    io: Io,
    sp: []const u8,
    stamp: Stamp,
) void {
    writeFileWhole(io, sp, asBytes(&stamp)) catch @panic("OOM");
}

/// A malformed command line. The message has already been printed.
const UsageError = error{Usage};

/// Prints every rule tag - the valid values for `--enable`.
fn printRuleTags() void {
    std.debug.print("rules:", .{});
    for (rule_notes) |note| {
        std.debug.print(" {s}", .{note.tag});
    }
    std.debug.print("\n", .{});
}

/// Turns on each rule named in the comma-separated `list`. A tag that is not a
/// rule is a usage error, printed here with the list of real ones.
fn enableRules(enabled: *EnabledRules, list: []const u8) UsageError!void {
    var it: std.mem.TokenIterator(u8, .scalar) = std.mem.tokenizeScalar(u8, list, ',');
    while (it.next()) |tag| {
        const i: usize = ruleIndex(tag) orelse {
            std.debug.print("zimrlint: --enable: '{s}' is not a rule\n", .{tag});
            printRuleTags();
            return error.Usage;
        };
        enabled[i] = true;
    }
}

/// Hash of the run's configuration that a per-file verdict depends on - see
/// `Stamp.config_hash`. Opt-in rules are hashed in `rule_notes` order, so the
/// order they were listed in on the command line does not matter.
fn configHash(args: *const Args) u64 {
    var h: std.hash.Wyhash = .init(0);
    for (args.aliases) |d| {
        h.update(d.stem);
        h.update("=");
        h.update(d.alias);
        h.update(";");
    }
    for (rule_notes, 0..) |note, i| {
        if (args.enabled[i]) {
            h.update("+");
            h.update(note.tag);
        }
    }
    if (args.decl_order_only) {
        h.update("decl-order-only");
    }
    return h.final();
}

/// The command line (std's cli, `src/command_line.zig`), read into `Args` - the struct the rest of the linter
/// uses. `--enable` may be given more than once; its tags go through `enableRules`, which can say WHY one is refused
/// (not a rule) - more than a parser could.
const LintCli = struct {
    @"--enable": []const []const u8 = &.{},
    @"--decl-order-only": bool = false,
    @"--cache-dir": []const u8 = default_stamp_dir,
    @"--list-rules": bool = false,
    @"--baseline": ?[]const u8 = null,
    @"--write-baseline": bool = false,
    @"--fix": bool = false,
    @"--check": bool = false,
    @"--dry-run": bool = false,
    @"--reorder-decls": bool = false,
    @"--coverage": bool = false,
    @"--fix-command": ?[]const u8 = null,
    files: []const []const u8 = &.{},
};

const lint_cli: cli.Config(LintCli) = .{
    .prog = "zimrlint",
    .description = "zimr's linter: the house rules over the files given (`zig build check` runs it on the tree). " ++
        "Exit 1: findings. Exit 2: a bad command line.",
    .args = .{
        .@"--enable" = .{ .description = "the rules to check, comma-separated; repeatable (see --list-rules)" },
        .@"--decl-order-only" = .{ .description = "run only the decl-order rule" },
        .@"--cache-dir" = .{ .description = "where the per-file clean stamps live" },
        .@"--list-rules" = .{ .description = "print every rule, marking those still in progress, and exit" },
        .@"--baseline" = .{ .description = "the ratchet: a TSV of counts per (file, rule) that are grandfathered" },
        .@"--write-baseline" = .{ .description = "rewrite that file from the current tree instead of checking" },
        .@"--fix" = .{ .description = "apply the mechanical autofixes in place" },
        .@"--check" = .{ .description = "report only - the default; accepted for `zig fmt --check` muscle memory" },
        .@"--dry-run" = .{ .description = "with --fix / --reorder-decls: report, write nothing" },
        .@"--reorder-decls" = .{ .description = "move declarations above their first use (repairs decl-order)" },
        .@"--coverage" = .{ .description = "self-check: list the nodes the rule walk never reaches, and exit" },
        .@"--fix-command" = .{ .description = "the command applying the autofixes, shown by each fixable finding" },
        .files = .{ .description = "the .zig files to lint" },
    },
};

/// The generated usage, to stderr.
fn printCliUsage(arena: Allocator) void {
    var usage: Io.Writer.Allocating = .init(arena);
    cli.printUsage(&usage.writer, LintCli, lint_cli, "zimrlint") catch return;
    std.debug.print("{s}", .{usage.written()});
}

/// Parsed with `cli.parse` rather than the usual `cli.args`, which exits 1 on a bad command line: for zimrlint 1
/// means FINDINGS, and a caller must be able to tell "the tree has findings" from "you called me wrong" (2).
fn parseArgs(gpa: Allocator, arena: Allocator, argv: []const [:0]const u8) !Args {
    const parsed: LintCli = cli.parse(arena, LintCli, lint_cli, argv) catch |err| switch (err) {
        error.HelpRequested => {
            printCliUsage(arena);
            return error.Help;
        },
        error.IncorrectUsage => {
            var why_buf: [256]u8 = undefined;
            if (cli.misfit(LintCli, lint_cli, argv, &why_buf)) |why| {
                std.debug.print("zimrlint: {s}\n\n", .{why});
            }
            printCliUsage(arena);
            return error.Usage;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    var a: Args = .{ .files = .empty };
    errdefer a.files.deinit(gpa);
    for (parsed.@"--enable") |list| {
        try enableRules(&a.enabled, list);
    }
    if (parsed.@"--decl-order-only") {
        a.enabled[ruleIndex("decl-order").?] = true;
        a.decl_order_only = true;
    }
    a.cache_dir = parsed.@"--cache-dir";
    a.list_rules = parsed.@"--list-rules";
    a.baseline_path = parsed.@"--baseline";
    a.write_baseline = parsed.@"--write-baseline";
    a.fix = parsed.@"--fix";
    a.check = parsed.@"--check";
    a.dry_run = parsed.@"--dry-run";
    a.reorder_decls = parsed.@"--reorder-decls";
    a.coverage = parsed.@"--coverage";
    a.fix_command = parsed.@"--fix-command";
    try a.files.appendSlice(gpa, parsed.files);
    return a;
}

/// `zig-fmt`: the file as `zig fmt` writes it (`Ast.render`) against the file as it is, reported at the first line
/// that differs. Its fix is the whole file, formatted - which overlaps every other rule's fix, so the fix loop leaves
/// it out (`collectFixes`) and `--fix` formats the file once, after every other fix has landed.
fn checkZigFmt(ctx: Ctx) !void {
    const formatted: []u8 = try ctx.ast.renderAlloc(ctx.alloc);
    defer ctx.alloc.free(formatted);
    const source: []const u8 = ctx.source;
    if (eql(u8, formatted, source)) {
        return;
    }
    const common_length: usize = @min(formatted.len, source.len);
    var first_difference: usize = 0;
    while (first_difference < common_length and formatted[first_difference] == source[first_difference]) {
        first_difference += 1;
    }
    var line: u32 = 1;
    for (source[0..first_difference]) |byte| {
        if (byte == '\n') {
            line += 1;
        }
    }
    try ctx.emitFixLC(
        line,
        1,
        "zig-fmt",
        0,
        .{ .start = 0, .end = @intCast(source.len), .replacement = formatted },
        "not laid out as `zig fmt` lays it out - this is the first line that differs",
        .{},
    );
}

/// `analyzeSource` before the enabled-rules filter: every check, every rule.
fn analyzeSourceAllRules(
    gpa: Allocator,
    path: []const u8,
    source_z: [:0]u8,
    args: *const Args,
    issues: *ArrayList(Issue),
) !bool {
    try scanArrayMult(gpa, path, source_z[0..source_z.len], issues);
    try scanRawPassBind(gpa, path, source_z, issues);
    try scanShaderEntry(gpa, path, source_z, issues);
    var ast: std.zig.Ast = try .parse(gpa, source_z, .{ .mode = .zig });
    defer ast.deinit(gpa);
    if (ast.errors.len > 0) {
        const first: std.zig.Ast.Error = ast.errors[0];
        const tok: u32 = if (first.token_is_prev) first.token + 1 else first.token;
        const loc: Ast.Location = ast.tokenLocation(0, tok);
        const msg: []u8 = try allocPrint(
            gpa,
            "file has {d} parse error(s) - run `zig ast-check {s}` for details",
            .{ ast.errors.len, path },
        );
        try issues.append(gpa, .{
            .file = path,
            .line = @intCast(loc.line + 1),
            .col = @intCast(loc.column + 1),
            .tag = "parse-error",
            .message = msg,
            .rule = 0,
        });
        return true;
    }
    var zm_alias_buf: [8][]const u8 = undefined;
    const zm_alias_n: usize = collectImportAliases(source_z, &zm_alias_buf, " = @import(\"zm\")");
    var std_alias_buf: [8][]const u8 = undefined;
    const std_alias_n: usize = collectImportAliases(source_z, &std_alias_buf, " = @import(\"std\")");
    const canon_inits: []bool = try gpa.alloc(bool, ast.nodes.len);
    defer gpa.free(canon_inits);
    @memset(canon_inits, false);
    markCanonicalZmInits(&ast, zm_alias_buf[0..zm_alias_n], canon_inits);
    const canonical_std: []bool = try gpa.alloc(bool, ast.nodes.len);
    defer gpa.free(canonical_std);
    @memset(canonical_std, false);
    markCanonicalInits(&ast, std_alias_buf[0..std_alias_n], .std_lib, canonical_std);
    var std_alias_declarations: [std_vocabulary.len]u32 = undefined;
    countStdAliasDeclarations(&ast, &std_alias_declarations);
    const ctx: Ctx = .{
        .alloc = gpa,
        .path = path,
        .source = source_z,
        .ast = &ast,
        .issues = issues,
        .zm_aliases = zm_alias_buf[0..zm_alias_n],
        .std_aliases = std_alias_buf[0..std_alias_n],
        .canonical_zm_inits = canon_inits,
        .canonical_std_inits = canonical_std,
        .std_alias_declarations = &std_alias_declarations,
        .zm_col0 = hasCol0ZmImport(source_z),
        .std_col0 = hasCol0StdImport(source_z),
        .declares_app = indexOf(u8, source_z, "AppSpec(") != null,
        .check_decl_order = args.enabled[ruleIndex("decl-order").?],
        .decl_order_only = args.decl_order_only,
        .aliases = args.aliases,
    };
    try runChecks(ctx);
    // Only when enabled, unlike the checks above: rendering the whole file is the one check that costs as much as the
    // parse.
    if (args.enabled[ruleIndex("zig-fmt").?]) {
        try checkZigFmt(ctx);
    }
    return false;
}

/// Parse + run all checks on one in-memory source buffer, appending issues.
/// Returns whether the file had parse errors (AST checks are skipped if so).
/// Mirrors the per-file body of `main` so the check path and the fix loop share
/// exactly one analysis routine.
///
/// Issues from rules the run did not `--enable` are dropped HERE, the one
/// point every issue passes through - AST checks, the raw-text scans that append
/// directly, and parse errors alike. Filtering at the end rather than gating each
/// check keeps the checks unaware of configuration, and because the fix loop
/// analyses through this same function, a disabled rule's autofix is never
/// applied either.
fn analyzeSource(
    gpa: Allocator,
    path: []const u8,
    source_z: [:0]u8,
    args: *const Args,
    issues: *ArrayList(Issue),
) !bool {
    const first_new: usize = issues.items.len;
    const has_parse_errors: bool = try analyzeSourceAllRules(gpa, path, source_z, args, issues);
    var kept: usize = first_new;
    for (issues.items[first_new..]) |is| {
        if (ruleEnabled(&args.enabled, is.tag)) {
            issues.items[kept] = is;
            kept += 1;
        } else {
            is.deinit(gpa);
        }
    }
    issues.items.len = kept;
    return has_parse_errors;
}

// ============================================================================
// Rewriting files - `--fix` and `--reorder-decls`.
// ============================================================================

/// True when `bytes` clears both parse AND AstGen (ZIR lowering), i.e. it gets at
/// least as far as a real build's front-end. The fix loop's guard uses this to
/// catch SEMANTIC breakage a parse-only check misses - an undeclared identifier
/// or duplicate decl produced when two fixes in one pass conflict (e.g. one
/// deletes a binding while another rewrites a use to depend on it). AstGen treats
/// `@import` opaquely, so cross-module references never false-trip this.
fn compilesClean(gpa: Allocator, bytes: []const u8) bool {
    const z: [:0]u8 = gpa.allocSentinel(u8, bytes.len, 0) catch return false;
    defer gpa.free(z);
    @memcpy(z, bytes);
    var ast: std.zig.Ast = std.zig.Ast.parse(gpa, z, .{ .mode = .zig }) catch return false;
    defer ast.deinit(gpa);
    if (ast.errors.len > 0) {
        return false;
    }
    var zir: std.zig.Zir = std.zig.AstGen.generate(gpa, ast) catch return false;
    defer zir.deinit(gpa);
    return !zir.hasCompileErrors();
}

/// Splice `fixes` (sorted ascending by `start`, non-overlapping) into `source`,
/// producing a fresh owned buffer. Segments between edits are copied verbatim.
fn applyFixes(gpa: Allocator, source: []const u8, fixes: []const Fix) ![]u8 {
    var out: ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var cursor: usize = 0;
    for (fixes) |fx| {
        if (fx.start < cursor) {
            continue; // defensive: overlap survived filtering - skip
        }
        try out.appendSlice(gpa, source[cursor..fx.start]);
        try out.appendSlice(gpa, fx.replacement);
        cursor = fx.end;
    }
    try out.appendSlice(gpa, source[cursor..]);
    return out.toOwnedSlice(gpa);
}

/// A fix the fix loop's guard refused (`applyFixesGuarded`), as the loop remembers it: where it was and what it would
/// have written. A later pass leaves the same fix out, so the fixes it overlapped - which `collectFixes` held back
/// behind it - get their turn. Before Oct 18 a pass that applied nothing ended the loop, and a fix inside a refused
/// one's span was never tried at all.
const RefusedFix = struct {
    start: u32,
    end: u32,
    replacement_hash: u64,

    fn of(fix: Fix) RefusedFix {
        return .{ .start = fix.start, .end = fix.end, .replacement_hash = std.hash.Wyhash.hash(0, fix.replacement) };
    }

    fn isAmong(fix: Fix, refused: []const RefusedFix) bool {
        const fingerprint: RefusedFix = .of(fix);
        for (refused) |earlier| {
            const same: bool = earlier.start == fingerprint.start and earlier.end == fingerprint.end and
                earlier.replacement_hash == fingerprint.replacement_hash;
            if (same) {
                return true;
            }
        }
        return false;
    }
};

/// Gather the `Fix`es carried by `issues` into `out`, sorted ascending by start
/// with overlapping edits dropped (deferred to a later pass), and without the
/// fixes the guard already refused (`refused`).
fn collectFixes(
    gpa: Allocator,
    issues: []const Issue,
    refused: []const RefusedFix,
    out: *ArrayList(Fix),
) !void {
    out.clearRetainingCapacity();
    // * Deleting an unused declaration waits for a pass with nothing else to do. Another fix in
    // the same pass may be about to USE it - `float-from-int` writes `float(x)` against the
    // `const float = zm.float;` that `unused-global` wants gone - and applying both broke the
    // file, so the parse guard discarded the whole pass and neither fix ever landed. The fix loop
    // re-analyses after every pass, so a declaration that is still unused goes one pass later.
    // * `zig-fmt`'s fix is never collected: it is the whole file, formatted, so it would overlap every other fix -
    // and it is not "pending" either, or it would hold back that deletion forever. `--fix` formats the file once, at
    // the end. A fix the guard refused is neither collected nor pending, for the same two reasons.
    var other_fixes_pending: bool = false;
    for (issues) |is| {
        const fix: Fix = is.fix orelse continue;
        const is_other_fix: bool = !eql(u8, is.tag, "unused-global") and !eql(u8, is.tag, "zig-fmt") and
            !RefusedFix.isAmong(fix, refused);
        if (is_other_fix) {
            other_fixes_pending = true;
            break;
        }
    }
    for (issues) |is| {
        if (is.fix) |fx| {
            const deferred: bool = other_fixes_pending and eql(u8, is.tag, "unused-global");
            if (deferred or eql(u8, is.tag, "zig-fmt") or RefusedFix.isAmong(fx, refused)) {
                continue;
            }
            try out.append(gpa, fx);
        }
    }
    // By start, then end, then text: identical edits must sit side by side for the duplicate check below to see
    // them. Sorting by start alone let two names' bindings at one spot interleave - A, B, A, B - and each A, compared
    // only with the B before it, was inserted again: a redeclaration, AstGen failed, the guard threw the whole pass
    // away, and every fix of the file was lost (codecs.zig's 106, found by the L4b dry run). The text order also
    // makes the bindings inserted at one spot come out sorted, the same on every run.
    sortSlice(Fix, out.items, {}, struct {
        fn lt(_: void, a: Fix, b: Fix) bool {
            if (a.start != b.start) {
                return a.start < b.start;
            }
            if (a.end != b.end) {
                return a.end < b.end;
            }
            return std.mem.order(u8, a.replacement, b.replacement) == .lt;
        }
    }.lt);
    var w: usize = 0;
    var running_end: u32 = 0;
    for (out.items) |fx| {
        // The same edit twice (several uses of one missing name each ask for its binding, at one
        // spot) is one intention: keep one, or the duplicates would fail AstGen and sink the pass.
        if (w > 0) {
            const kept: Fix = out.items[w - 1];
            if (fx.start == kept.start and fx.end == kept.end and eql(u8, fx.replacement, kept.replacement)) {
                continue;
            }
        }
        if (w == 0 or fx.start >= running_end) {
            out.items[w] = fx;
            w += 1;
            running_end = fx.end;
        }
    }
    out.items.len = w;
}

/// Outcome of fixing one file: the final source (owned), how many edits landed,
/// and whether any fix was refused because it would have broken the file.
/// How many fixes of each rule a fix run applied to a file, in the order the rules first applied one: what the run
/// reports for the file (`zimrlint: fixed <file>: <rule> x<count>, ...`).
const FixTally = struct {
    const RuleCount = struct {
        tag: []const u8,
        count: usize,
    };
    rule_counts: ArrayList(RuleCount) = .empty,

    fn add(self: *FixTally, gpa: Allocator, tag: []const u8) !void {
        for (self.rule_counts.items) |*rule_count| {
            if (eql(u8, rule_count.tag, tag)) {
                rule_count.count += 1;
                return;
            }
        }
        try self.rule_counts.append(gpa, .{ .tag = tag, .count = 1 });
    }

    fn deinit(self: *FixTally, gpa: Allocator) void {
        self.rule_counts.deinit(gpa);
    }
};

const FixOutcome = struct {
    bytes: []u8,
    edits_applied: usize,
    /// The fixes applied, by rule.
    tally: FixTally,
    /// Some fixes were refused: applied, they would have broken the file (`applyFixesGuarded`). The findings they
    /// belong to stay, marked for a human.
    refused_any: bool,
    /// The file as read was not laid out as `zig fmt` lays it out (`zig-fmt`, when enabled): `--fix` formats it even
    /// when no other rule fixed anything, and counts that as `zig-fmt`'s fix.
    unformatted: bool,
};

/// What `applyFixesGuarded` did: the result (owned), and how many fixes it kept and refused.
const GuardedOutcome = struct {
    bytes: []u8,
    applied: usize,
    refused: usize,
};

/// `fixes` applied to `source` ONE AT A TIME - from the last, so each one's offsets still hold - keeping each that
/// leaves the file clean (`compilesClean`) and refusing the others. What the fix loop falls back to when a pass,
/// applied all at once, breaks the file: one bad fix, or two that only clash together, must not cost the file all
/// the good ones. `fixes` are sorted ascending and do not overlap (`collectFixes`). Each refused fix is added to
/// `refused_out`, for the next pass to leave out.
fn applyFixesGuarded(
    gpa: Allocator,
    source: []const u8,
    fixes: []const Fix,
    tally: *FixTally,
    refused_out: *ArrayList(RefusedFix),
) !GuardedOutcome {
    var current: []u8 = try gpa.dupe(u8, source);
    errdefer gpa.free(current);
    var applied: usize = 0;
    var refused: usize = 0;
    var index: usize = fixes.len;
    while (index > 0) {
        index -= 1;
        const candidate: []u8 = try applyFixes(gpa, current, fixes[index .. index + 1]);
        if (compilesClean(gpa, candidate)) {
            gpa.free(current);
            current = candidate;
            applied += 1;
            try tally.add(gpa, fixes[index].tag);
        } else {
            gpa.free(candidate);
            refused += 1;
            try refused_out.append(gpa, .of(fixes[index]));
        }
    }
    return .{ .bytes = current, .applied = applied, .refused = refused };
}

/// `source` laid out as `zig fmt` lays it out - its own renderer, `std.zig.Ast.render` - so that a fixed file is
/// written formatted, in the one write that fixes it: a fix makes the smallest edit (one comma, say) and leaves the
/// layout to the renderer, and nothing that stops a build between the two can leave a file fixed but unformatted.
/// The source unchanged, as a copy, when it does not parse.
fn zigFormatted(gpa: Allocator, source: []const u8) ![]u8 {
    const source_z: [:0]u8 = try gpa.allocSentinel(u8, source.len, 0);
    defer gpa.free(source_z);
    @memcpy(source_z, source);
    var tree: std.zig.Ast = try .parse(gpa, source_z, .{ .mode = .zig });
    defer tree.deinit(gpa);
    if (tree.errors.len > 0) {
        return gpa.dupe(u8, source);
    }
    return tree.renderAlloc(gpa);
}

/// One line for a file a fix run rewrote: `zimrlint: fixed <path>: <rule> x<count>, ...` (`would fix` in a dry run),
/// the rules in the order they first applied a fix - what a person, or a program editing the file, needs to know to
/// read it again. Its diff follows it (`line_diff.print`).
fn printFixTally(
    out: *Io.Writer,
    verb: []const u8,
    path: []const u8,
    tally: FixTally,
) !void {
    try out.print("zimrlint: {s} {s}:", .{ verb, path });
    for (tally.rule_counts.items, 0..) |rule_count, index| {
        const separator: []const u8 = if (index == 0) " " else ", ";
        try out.print("{s}{s} x{d}", .{ separator, rule_count.tag, rule_count.count });
    }
    try out.print("\n", .{});
}

/// Iteratively analyze -> collect fixes -> splice, until no more fixes (or 5
/// passes). The loop is what lets a cascade settle: removing decl A in pass 1
/// can make decl B unused, caught in pass 2. Each pass re-parses the spliced
/// result and rolls back if it parses worse than its input.
fn runFixLoop(gpa: Allocator, path: []const u8, original: []const u8, args: *const Args) !FixOutcome {
    var cur: []u8 = try gpa.dupe(u8, original);
    var total_edits: usize = 0;
    var refused_any: bool = false;
    var unformatted: bool = false;
    var tally: FixTally = .{};
    errdefer tally.deinit(gpa);
    // The fixes the guard refused so far, left out of every later pass (`RefusedFix`).
    var refused_fixes: ArrayList(RefusedFix) = .empty;
    defer refused_fixes.deinit(gpa);
    var pass: usize = 0;
    while (pass < 5) : (pass += 1) {
        const cur_z: [:0]u8 = try gpa.allocSentinel(u8, cur.len, 0);
        @memcpy(cur_z, cur);
        var issues: ArrayList(Issue) = .empty;
        defer {
            for (issues.items) |is| {
                is.deinit(gpa);
            }
            issues.deinit(gpa);
        }
        // This is the --fix RE-SCAN of a file just rewritten. A failure here means the rewrite
        // produced something unanalysable, and the loop's own parse-guard already refuses to keep
        // such a file - so the useful response is to stop proposing fixes for this pass, which is
        // exactly what leaving `issues` empty does.
        // lint:off catch-suppression: deliberate - see above
        _ = analyzeSource(gpa, path, cur_z, args, &issues) catch {};
        gpa.free(cur_z);
        if (pass == 0) {
            for (issues.items) |first_pass_issue| {
                if (eql(u8, first_pass_issue.tag, "zig-fmt")) {
                    unformatted = true;
                }
            }
        }

        var fixes: ArrayList(Fix) = .empty;
        defer fixes.deinit(gpa);
        try collectFixes(gpa, issues.items, refused_fixes.items, &fixes);
        if (fixes.items.len == 0) {
            break;
        }
        const before_ok: bool = compilesClean(gpa, cur);
        const next: []u8 = try applyFixes(gpa, cur, fixes.items);
        const after_ok: bool = compilesClean(gpa, next);
        if (before_ok and !after_ok) {
            // Together these edits break a clean file. Keep the ones that do not, one at a time; refuse the rest.
            gpa.free(next);
            const guarded: GuardedOutcome = try applyFixesGuarded(gpa, cur, fixes.items, &tally, &refused_fixes);
            gpa.free(cur);
            cur = guarded.bytes;
            total_edits += guarded.applied;
            refused_any = refused_any or guarded.refused > 0;
            // On, even when nothing applied: the next pass leaves the refused fixes out, so the ones they overlapped
            // get their turn; with none left, it finds nothing to do and the loop ends.
            continue;
        }
        gpa.free(cur);
        cur = next;
        total_edits += fixes.items.len;
        for (fixes.items) |applied_fix| {
            try tally.add(gpa, applied_fix.tag);
        }
    }
    return .{
        .bytes = cur,
        .edits_applied = total_edits,
        .tally = tally,
        .refused_any = refused_any,
        .unformatted = unformatted,
    };
}

// ==== --reorder-decls: move declarations above their first use (the hoist strategy) ====
//
// `decl-order` asks for every file-scope name to be declared above its first use. Zig does not
// care about container-level order, so the repair is a pure reorder - but a careful one:
//
//   * A declaration moves as a BLOCK of whole lines: the declaration as the syntax tree sees it,
//     its terminating `;` included (a multiline-string value ends on its last `\\` line, and a
//     `;` left behind would ride with the next declaration and break the file), plus the `///`
//     and `//` lines directly above it. A blank line ends that upward walk, so the `//!` header
//     and blank-separated banners (`// ===== X =====`) stay where they are.
//   * HOIST, not sort: each forward-referenced declaration moves to just above the top-level
//     declaration holding its earliest use, and nothing else moves. Its own dependencies may now
//     sit below it; they are hoisted in turn, until no forward reference is left.
//   * A cycle (A uses B, B uses A) can never be ordered - the hoisting would chase itself - so a
//     file that has not settled after one move per declaration is REFUSED, left as it was.
//   * Guards: the non-blank lines are the same multiset before and after (only order changed),
//     the result parses and passes AstGen (`compilesClean`), and no forward reference remains.
//     Anything else is refused and nothing is written.

/// One top-level declaration as a block of whole lines (0-based, inclusive), with the token
/// range the syntax tree gives it (so a use can be traced to the declaration that holds it).
const DeclBlock = struct {
    first_line: usize,
    last_line: usize,
    first_token: u32,
    last_token: u32,
    /// The declaration's name, or null for `test` / `comptime`.
    name: ?[]const u8,
    /// A container FIELD (a file is a struct and may have them): nothing may be inserted between fields.
    is_field: bool,
};

/// A forward reference, as block indices: `referenced` is used inside `user`, above its declaration, first at
/// token `use_token`.
const ForwardReference = struct {
    referenced: usize,
    user: usize,
    use_token: u32,
};

/// One hoist: block `moved` goes directly above block `target`.
const Hoist = struct {
    moved: usize,
    target: usize,
};

/// What `reorderDecls` did - or why it refused and changed nothing.
const ReorderResult = struct {
    /// The reordered source (the input itself when nothing moved or it refused), from `gpa`.
    source: []u8,
    /// Declarations hoisted.
    moves: usize,
    /// Lines in the hoisted blocks, summed - how much the file was reshuffled.
    lines_moved: usize,
    /// Why nothing was written, or null.
    refused: ?[]const u8,
};

/// The 0-based line holding byte `offset`, given each line's starting offset (ascending).
fn lineOfOffset(line_starts: []const usize, offset: usize) usize {
    var low: usize = 0;
    var high: usize = line_starts.len;
    // The last line whose start is at or before `offset`.
    while (high - low > 1) {
        const middle: usize = low + (high - low) / 2;
        if (line_starts[middle] <= offset) {
            low = middle;
        } else {
            high = middle;
        }
    }
    return low;
}

/// The blocks of `ast`'s top-level declarations over `lines` (the source split on '\n'), in
/// source order. Errors when two declarations share a line - a file `zig fmt` never writes.
fn declBlocks(
    arena: Allocator,
    ast: *const Ast,
    lines: []const []const u8,
    line_starts: []const usize,
) ![]DeclBlock {
    const tags: []const std.zig.Token.Tag = ast.tokens.items(.tag);
    const root_decls: []const Index = ast.rootDecls();
    const blocks: []DeclBlock = try arena.alloc(DeclBlock, root_decls.len);
    var previous_last_line: ?usize = null;
    for (root_decls, blocks) |node, *block| {
        const first_token: u32 = ast.firstToken(node);
        var last_token: u32 = ast.lastToken(node);
        // The terminating `;` belongs to the declaration.
        if (last_token + 1 < tags.len and tags[last_token + 1] == .semicolon) {
            last_token += 1;
        }
        // Its doc comments are tokens right before it - attached across blank lines, as Zig's grammar attaches
        // them. (A walk over the lines alone would stop at the blank and leave a `///` behind, to land above
        // whatever moves in next - above a `test`, that no longer even parses.)
        var first_doc_token: u32 = first_token;
        while (first_doc_token > 0 and tags[first_doc_token - 1] == .doc_comment) {
            first_doc_token -= 1;
        }
        var first_line: usize = lineOfOffset(line_starts, ast.tokenStart(first_doc_token));
        const last_line: usize = lineOfOffset(line_starts, ast.tokenStart(last_token));
        if (previous_last_line) |previous| {
            if (first_line <= previous) {
                return error.DeclarationsShareALine;
            }
        }
        // Walk up over the comment lines attached to it: `///` and `//`, never `//!`, and no
        // blank line between.
        while (first_line > 0) {
            const above: usize = first_line - 1;
            if (previous_last_line) |previous| {
                if (above <= previous) {
                    break;
                }
            }
            const above_text: []const u8 = trim(u8, lines[above], " \t\r");
            const attached: bool = startsWith(u8, above_text, "//") and !startsWith(u8, above_text, "//!");
            if (!attached) {
                break;
            }
            first_line = above;
        }
        const name_token: ?u32 = declNameToken(ast, node);
        const name: ?[]const u8 = if (name_token) |token| ast.tokenSlice(token) else null;
        const node_tag: Ast.Node.Tag = ast.nodeTag(node);
        const is_field: bool = node_tag == .container_field or node_tag == .container_field_init or
            node_tag == .container_field_align;
        block.* = .{
            .first_line = first_line,
            .last_line = last_line,
            .first_token = first_token,
            .last_token = last_token,
            .name = name,
            .is_field = is_field,
        };
        previous_last_line = last_line;
    }
    return blocks;
}

fn isBannerBar(line: []const u8) bool {
    if (!startsWith(u8, line, "// ") or line.len < 3 + 20) {
        return false;
    }
    for (line[3..]) |character| {
        if (character != '=') {
            return false;
        }
    }
    return true;
}

fn isTopLevelDeclarationLine(line: []const u8) bool {
    const starts: [9][]const u8 = .{
        "pub ", "fn ", "const ", "var ", "test ", "comptime ", "export ", "extern ", "inline ",
    };
    for (starts) |prefix| {
        if (startsWith(u8, line, prefix)) {
            return true;
        }
    }
    return false;
}

/// The titles of the section banners in `lines` that have at least one top-level declaration under them,
/// up to the next banner. A banner is a `// ====...` bar, its title line, any comment lines, and an
/// optional closing bar - the house style for sections. Used to refuse a reorder that would leave a
/// section heading nothing: the hoist moves declarations, never comments, so a section's code can be
/// carried away while its banner stays put.
fn bannersWithCode(arena: Allocator, lines: []const []const u8) ![]const []const u8 {
    var titles: ArrayList([]const u8) = .empty;
    var current: ?[]const u8 = null;
    var counted: bool = false;
    var index: usize = 0;
    while (index < lines.len) : (index += 1) {
        const line: []const u8 = lines[index];
        if (isBannerBar(line) and index + 1 < lines.len and startsWith(u8, lines[index + 1], "// ") and
            !isBannerBar(lines[index + 1]))
        {
            current = lines[index + 1];
            counted = false;
            index += 1;
            while (index + 1 < lines.len) {
                const next: []const u8 = lines[index + 1];
                if (!startsWith(u8, next, "//") or isBannerBar(next)) {
                    break;
                }
                index += 1;
            }
            if (index + 1 < lines.len and isBannerBar(lines[index + 1])) {
                index += 1;
            }
            continue;
        }
        if (current) |title| {
            if (!counted and isTopLevelDeclarationLine(line)) {
                try titles.append(arena, title);
                counted = true;
            }
        }
    }
    return titles.items;
}

/// Each line's starting byte offset in `lines` joined by '\n' - so a token's line is a binary search
/// (`lineOfOffset`), not `ast.tokenLocation(0, token)`, which counts lines from the top of the file on every
/// call (a thousand declarations in an 11k-line file made each pass minutes long).
fn lineStarts(arena: Allocator, lines: []const []const u8) ![]usize {
    const starts: []usize = try arena.alloc(usize, lines.len);
    var offset: usize = 0;
    for (lines, starts) |line, *start| {
        start.* = offset;
        offset += line.len + 1;
    }
    return starts;
}

fn earlierUse(_: void, left: ForwardReference, right: ForwardReference) bool {
    return left.use_token < right.use_token;
}

/// Every forward reference in the file, earliest use first - exactly `decl-order`'s notion: an identifier naming
/// a file-scope declaration, before that declaration's first token. The rule reports each declaration once, at
/// its EARLIEST such use, and a `// lint:off decl-order` there (or a file-level one) silences that declaration
/// entirely - so a declaration whose earliest use is suppressed is not a forward reference here either. That is
/// how an explained cycle (and an exempt file) is left alone. Empty when the file is in order.
fn forwardReferences(
    arena: Allocator,
    ast: *const Ast,
    blocks: []const DeclBlock,
    line_starts: []const usize,
) ![]ForwardReference {
    var by_name: StringHashMap(usize) = .init(arena);
    for (blocks, 0..) |block, index| {
        if (block.name) |name| {
            const entry: StringHashMap(usize).GetOrPutResult = try by_name.getOrPut(name);
            if (!entry.found_existing) {
                entry.value_ptr.* = index;
            }
        }
    }
    const earliest_use: []?u32 = try arena.alloc(?u32, blocks.len);
    @memset(earliest_use, null);
    const enum_field_names: []bool = try enumFieldNameNodes(arena, ast);
    var node_number: usize = 0;
    while (node_number < ast.nodes.len) : (node_number += 1) {
        const node: Index = @fromBackingInt(@intCast(node_number));
        if (ast.nodeTag(node) != .identifier or enum_field_names[node_number]) {
            continue;
        }
        const use_token: u32 = ast.nodeMainToken(node);
        const referenced: usize = by_name.get(ast.tokenSlice(use_token)) orelse continue;
        if (use_token >= blocks[referenced].first_token) {
            continue;
        }
        if (earliest_use[referenced] == null or use_token < earliest_use[referenced].?) {
            earliest_use[referenced] = use_token;
        }
    }
    var found: ArrayList(ForwardReference) = .empty;
    for (earliest_use, 0..) |use, referenced| {
        const use_token: u32 = use orelse continue;
        // `lineSuppressedByDirective` counts lines from 1, as reports do; `lineOfOffset` from 0.
        const use_line_number: usize = lineOfOffset(line_starts, ast.tokenStart(use_token)) + 1;
        if (lineSuppressedByDirective(ast.source, @intCast(use_line_number), "decl-order")) {
            continue;
        }
        const user: usize = for (blocks, 0..) |block, index| {
            if (use_token >= block.first_token and use_token <= block.last_token) {
                break index;
            }
        } else return error.UseOutsideEveryDeclaration;
        try found.append(arena, .{ .referenced = referenced, .user = user, .use_token = use_token });
    }
    sortSlice(ForwardReference, found.items, {}, earlierUse);
    return found.items;
}

/// `lines` with every `hoists` block taken out and put back directly above its target (which sits earlier in
/// the file), each followed by one blank line; runs of blank lines are then collapsed to one. Blocks bound for the
/// same target arrive in `hoists` order - earliest use first, so it lands farthest up, as one hoist at a time
/// would have left them. The caller guarantees no block both moves and receives, and none moves twice.
fn hoistBlocks(
    arena: Allocator,
    lines: []const []const u8,
    blocks: []const DeclBlock,
    hoists: []const Hoist,
) ![]const []const u8 {
    const leaving: []bool = try arena.alloc(bool, lines.len);
    @memset(leaving, false);
    for (hoists) |hoist| {
        const moved: DeclBlock = blocks[hoist.moved];
        @memset(leaving[moved.first_line .. moved.last_line + 1], true);
    }
    var result: ArrayList([]const u8) = .empty;
    for (lines, 0..) |line, index| {
        for (hoists) |hoist| {
            if (blocks[hoist.target].first_line == index) {
                const moved: DeclBlock = blocks[hoist.moved];
                try result.appendSlice(arena, lines[moved.first_line .. moved.last_line + 1]);
                try result.append(arena, "");
            }
        }
        if (!leaving[index]) {
            try result.append(arena, line);
        }
    }
    // One blank line between blocks is enough (taking a block out leaves two side by side), and
    // none at the very end (the file's final newline is kept apart from its lines).
    var collapsed: ArrayList([]const u8) = .empty;
    for (result.items, 0..) |line, index| {
        const blank: bool = trim(u8, line, " \t\r").len == 0;
        const previous_blank: bool = index > 0 and trim(u8, result.items[index - 1], " \t\r").len == 0;
        if (blank and previous_blank) {
            continue;
        }
        try collapsed.append(arena, line);
    }
    while (collapsed.items.len > 0 and trim(u8, collapsed.items[collapsed.items.len - 1], " \t\r").len == 0) {
        _ = collapsed.pop();
    }
    return collapsed.items;
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

/// The non-blank lines of `lines`, sorted - two sources with equal results hold the same lines.
fn sortedNonBlankLines(arena: Allocator, lines: []const []const u8) ![]const []const u8 {
    var kept: ArrayList([]const u8) = .empty;
    for (lines) |line| {
        if (trim(u8, line, " \t\r").len > 0) {
            try kept.append(arena, line);
        }
    }
    sortSlice([]const u8, kept.items, {}, lessThanString);
    return kept.items;
}

fn splitLines(arena: Allocator, source: []const u8) ![]const []const u8 {
    var lines: ArrayList([]const u8) = .empty;
    var pieces: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, source, '\n');
    while (pieces.next()) |line| {
        try lines.append(arena, line);
    }
    return lines.items;
}

/// `lines` joined with '\n', plus a final newline when `final_newline`.
fn joinLines(arena: Allocator, lines: []const []const u8, final_newline: bool) ![:0]u8 {
    var total: usize = @intFromBool(final_newline);
    for (lines, 0..) |line, index| {
        total += line.len + @intFromBool(index + 1 < lines.len);
    }
    const text: [:0]u8 = try arena.allocSentinel(u8, total, 0);
    var at: usize = 0;
    for (lines, 0..) |line, index| {
        @memcpy(text[at..][0..line.len], line);
        at += line.len;
        if (index + 1 < lines.len) {
            text[at] = '\n';
            at += 1;
        }
    }
    if (final_newline) {
        text[at] = '\n';
    }
    return text;
}

/// Hoist `source`'s declarations until each sits above its first use (see the section comment).
/// The result's `source` is always allocated from `gpa`; on refusal it is a copy of the input.
fn reorderDecls(gpa: Allocator, source: []const u8) !ReorderResult {
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    // The file's final newline is kept apart, so a line list never ends in an empty "line".
    const ends_with_newline: bool = endsWith(u8, source, "\n");
    const body: []const u8 = if (ends_with_newline) source[0 .. source.len - 1] else source;
    var lines: []const []const u8 = try splitLines(arena, body);
    const original_lines: []const []const u8 = lines;
    var moves: usize = 0;
    var lines_moved: usize = 0;
    var refused: ?[]const u8 = null;
    var move_budget: usize = 0;
    while (true) {
        // Each pass's text, syntax tree and bookkeeping live in a scratch arena freed when the pass ends - kept
        // for the whole run, a 37k-line file's trees outgrew memory. Only `lines` survives a pass, and its
        // entries are slices of the original source.
        var pass_state: ArenaAllocator = .init(gpa);
        defer pass_state.deinit();
        const scratch: Allocator = pass_state.allocator();
        const text: [:0]u8 = try joinLines(scratch, lines, ends_with_newline);
        const ast: Ast = try .parse(scratch, text, .{ .mode = .zig });
        if (ast.errors.len > 0) {
            refused = "the source does not parse";
            break;
        }
        const line_starts: []usize = try lineStarts(scratch, lines);
        const blocks: []DeclBlock = declBlocks(scratch, &ast, lines, line_starts) catch {
            refused = "two declarations share a line";
            break;
        };
        if (moves == 0) {
            move_budget = blocks.len;
        }
        const forwards: []const ForwardReference = try forwardReferences(scratch, &ast, blocks, line_starts);
        if (forwards.len == 0) {
            break;
        }
        if (moves >= move_budget) {
            refused = "a cycle - the declarations reference each other, and no order satisfies them all";
            break;
        }
        // Every hoist that does not disturb another goes in this pass (one re-parse per pass, not per hoist - a
        // 37k-line file needs a hundred). A block that moves may not also receive, nor move twice; the ones
        // that would wait for the next pass, which is exactly when one hoist at a time would have done them.
        const moving: []bool = try scratch.alloc(bool, blocks.len);
        const receiving: []bool = try scratch.alloc(bool, blocks.len);
        @memset(moving, false);
        @memset(receiving, false);
        var hoists: ArrayList(Hoist) = .empty;
        for (forwards) |forward| {
            // A field's user means the whole run of fields: the declaration goes above the first of them, since
            // Zig allows no declaration between container fields.
            var target: usize = forward.user;
            while (blocks[target].is_field and target > 0 and blocks[target - 1].is_field) {
                target -= 1;
            }
            const disturbs: bool = moving[forward.referenced] or receiving[forward.referenced] or moving[target];
            if (disturbs) {
                continue;
            }
            if (moves + hoists.items.len >= move_budget) {
                break;
            }
            moving[forward.referenced] = true;
            receiving[target] = true;
            try hoists.append(scratch, .{ .moved = forward.referenced, .target = target });
            const moved: DeclBlock = blocks[forward.referenced];
            lines_moved += moved.last_line - moved.first_line + 1;
        }
        lines = try hoistBlocks(arena, lines, blocks, hoists.items);
        moves += hoists.items.len;
    }
    if (refused == null and moves > 0) {
        const before: []const []const u8 = try sortedNonBlankLines(arena, original_lines);
        const after: []const []const u8 = try sortedNonBlankLines(arena, lines);
        var same_lines: bool = before.len == after.len;
        if (same_lines) {
            for (before, after) |left, right| {
                if (!eql(u8, left, right)) {
                    same_lines = false;
                    break;
                }
            }
        }
        if (!same_lines) {
            refused = "the reorder changed a line's content, not only its position";
        } else if (!compilesClean(arena, try joinLines(arena, lines, ends_with_newline))) {
            refused = "the reordered file fails AstGen";
        } else {
            // Every section banner that headed code must still head some.
            const banners_with_code_before: []const []const u8 = try bannersWithCode(arena, original_lines);
            const banners_with_code_after: []const []const u8 = try bannersWithCode(arena, lines);
            for (banners_with_code_before) |title| {
                const still: bool = for (banners_with_code_after) |kept| {
                    if (eql(u8, kept, title)) {
                        break true;
                    }
                } else false;
                if (!still) {
                    refused = "a section banner would be left with no code under it - move that section by hand";
                    break;
                }
            }
        }
    }
    if (refused != null) {
        return .{ .source = try gpa.dupe(u8, source), .moves = 0, .lines_moved = 0, .refused = refused };
    }
    const result_text: []const u8 = try joinLines(arena, lines, ends_with_newline);
    return .{ .source = try gpa.dupe(u8, result_text), .moves = moves, .lines_moved = lines_moved, .refused = null };
}

/// `--reorder-decls`: `reorderDecls` on each file - report what moved, or why it refused - and write the result
/// unless `dry_run`. A refused file is left exactly as it was. Exit 1 when any file was refused or unreadable.
fn runReorderDecls(
    io: Io,
    gpa: Allocator,
    files: []const []const u8,
    dry_run: bool,
) !u8 {
    var out_buf: [4096]u8 = undefined;
    var out_writer: Io.File.Writer = Io.File.stdout().writer(io, &out_buf);
    const out: *Io.Writer = &out_writer.interface;
    var any_refused: bool = false;
    for (files) |path| {
        const source: []u8 = Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |e| {
            try out.print("{s}: unreadable ({s})\n", .{ path, @errorName(e) });
            any_refused = true;
            continue;
        };
        defer gpa.free(source);
        const result: ReorderResult = try reorderDecls(gpa, source);
        defer gpa.free(result.source);
        if (result.refused) |why| {
            try out.print("{s}: refused - {s}\n", .{ path, why });
            any_refused = true;
            continue;
        }
        if (result.moves == 0) {
            try out.print("{s}: already in order\n", .{path});
            continue;
        }
        if (!dry_run) {
            try writeFileWhole(io, path, result.source);
        }
        const verb: []const u8 = if (dry_run) "would move" else "moved";
        try out.print("{s}: {s} {d} declaration(s), {d} line(s)\n", .{ path, verb, result.moves, result.lines_moved });
    }
    try out.flush();
    return if (any_refused) 1 else 0;
}

/// What to run to apply the autofixes when the caller did not say (`--fix-command`): the same command line, plus
/// `--fix`. zimr's build and a project's pass `zig build fix` instead - the step that runs `--fix` and prints the diff
/// of every file it rewrites.
const fix_command_default: []const u8 = "rerun this command with --fix";

/// What a `--fix` run says of a finding it left with a fix it could not apply: refused (applied, it broke the file) or
/// not reached in the fix loop's passes. Rerunning the same fix will not apply it.
const unapplied_fix_note: []const u8 = "its autofix could not be applied: fix it by hand";

/// Sort + print a file's issues (with first-hit rule notes), shared by the
/// check path and the fix path's residual report. A finding with a mechanical
/// fix ends with ` - <fixable_note>` - in a check, `autofix: <fix command>`, the
/// same for every rule, decided by the finding's `fix`, never by a rule's wording.
/// Returns how many fixable findings it printed, for the summary.
fn printIssues(
    out: *Io.Writer,
    seen_tags: *StringHashMap(void),
    issues: []Issue,
    fixable_note: []const u8,
) !usize {
    sortSlice(Issue, issues, {}, struct {
        fn lt(_: void, a: Issue, b: Issue) bool {
            if (a.line != b.line) {
                return a.line < b.line;
            }
            return a.col < b.col;
        }
    }.lt);
    var fixable_count: usize = 0;
    for (issues) |is| {
        if (!seen_tags.contains(is.tag)) {
            try seen_tags.put(is.tag, {});
            if (lookupRuleNote(is.tag)) |note| {
                try out.print("\n", .{});
                try out.writeAll(rule_divider);
                try out.print("\n{s}\n", .{note.title});
                try out.writeAll(rule_divider);
                try out.print("\n{s}\n\n", .{note.body});
            }
        }
        // A finding of a rule still in progress says so in its brackets - `[rule, work in progress]` - so that a reader
        // of the log, or a tool stopping a build at its first finding, can tell it from one that fails the run.
        const work_in_progress_mark: []const u8 = if (isWorkInProgressTag(is.tag)) ", work in progress" else "";
        try out.print("{s}:{d}:{d}: [{s}{s}] {s}", .{
            is.file, is.line, is.col, is.tag, work_in_progress_mark, is.message,
        });
        if (is.rule > 0) {
            try out.print(" (rule {d})", .{is.rule});
        }
        if (is.fix != null) {
            fixable_count += 1;
            try out.print(" - {s}", .{fixable_note});
        }
        try out.writeAll("\n");
    }
    return fixable_count;
}

/// A `--fix` run's account of what it could not fix in one file, under the file's diff: a count, then each finding
/// indented. Indented, so that a build watcher stopping at the first finding (zbuild) does not stop the fix run
/// before the other files are fixed - the check after it (`zig build lint`, an app's build) lists them as findings.
/// Returns how many of them still carry a fix (`unapplied_fix_note`).
fn printLeftForPerson(out: *Io.Writer, path: []const u8, issues: []Issue) !usize {
    if (issues.len == 0) {
        return 0;
    }
    sortSlice(Issue, issues, {}, struct {
        fn lt(_: void, a: Issue, b: Issue) bool {
            if (a.line != b.line) {
                return a.line < b.line;
            }
            return a.col < b.col;
        }
    }.lt);
    try out.print("zimrlint: {d} left in {s} for a person:\n", .{ issues.len, path });
    var unapplied: usize = 0;
    for (issues) |is| {
        try out.print("    {s}:{d}:{d}: [{s}] {s}", .{ is.file, is.line, is.col, is.tag, is.message });
        if (is.fix != null) {
            unapplied += 1;
            try out.print(" - {s}", .{unapplied_fix_note});
        }
        try out.writeAll("\n");
    }
    return unapplied;
}

/// One `@import("x.zig")` between two files of this run, and where it is written.
const ImportEdge = struct {
    from: u32,
    to: u32,
    line: u32,
    col: u32,
};

/// -- `import-cycle`: the one rule that needs every file at once --
///
/// Builds the graph of `@import("*.zig")` edges between the files of this run - each path
/// resolved against the importing file, so `../robot.zig` and `robot.zig` meet - and reports
/// every edge that closes a cycle, with the whole cycle in the message. An import carrying
/// `// lint:off import-cycle: <why>` is a reviewed back edge and is left out of the graph, so a
/// suppression does not depend on which way the search happened to walk.
///
/// It reads every input itself, like the alias registry, instead of riding the per-file loop:
/// that loop skips stamped-clean files, and a cycle is usually two files each clean on its own.
/// Roots are visited in sorted-path order, so the edge reported for a cycle is the same on
/// every machine.
fn checkImportCycles(
    gpa: Allocator,
    io: Io,
    files: []const []const u8,
    out_issues: *ArrayList(Issue),
) !void {
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    const keys: [][]const u8 = try arena.alloc([]const u8, files.len);
    var index_of: StringHashMap(u32) = .init(arena);
    for (files, 0..) |path, i| {
        keys[i] = try std.fs.path.resolveAlloc(arena, &.{path});
        try index_of.put(keys[i], @intCast(i));
    }

    var edges: ArrayList(ImportEdge) = .empty;
    const out_edges: []ArrayList(u32) = try arena.alloc(ArrayList(u32), files.len);
    @memset(out_edges, .empty);
    for (files, 0..) |path, i| {
        // * NO `isSkipped` here. That list exempts generated data from STYLE rules, but a
        // generated fixture that imports `robot.zig` is still a dependency - skipping it hid the
        // `robot.zig` <-> `kuka_iiwa.zig` cycle on this rule's first run.
        const bytes: []u8 = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch continue;
        const source: [:0]u8 = try arena.allocSentinel(u8, bytes.len, 0);
        @memcpy(source, bytes);
        const dir: []const u8 = std.fs.path.dirname(keys[i]) orelse ".";

        var tokenizer: std.zig.Tokenizer = .init(source);
        var line: u32 = 1;
        var line_start: usize = 0;
        var scanned: usize = 0;
        while (true) {
            const token: std.zig.Token = tokenizer.next();
            if (token.tag == .eof) {
                break;
            }
            const is_import: bool = token.tag == .builtin and
                eql(u8, source[token.loc.start..token.loc.end], "@import");
            if (!is_import) {
                continue;
            }
            while (scanned < token.loc.start) : (scanned += 1) {
                if (source[scanned] == '\n') {
                    line += 1;
                    line_start = scanned + 1;
                }
            }
            const paren: std.zig.Token = tokenizer.next();
            const literal: std.zig.Token = tokenizer.next();
            const names_a_file: bool = paren.tag == .l_paren and literal.tag == .string_literal and
                endsWith(u8, source[literal.loc.start..literal.loc.end], ".zig\"");
            if (!names_a_file) {
                continue; // std, builtin, or a named module wired in build.zig
            }
            if (lineSuppressedByDirective(source, line, "import-cycle")) {
                continue; // a reviewed back edge: not part of the graph
            }
            const target_text: []const u8 = source[literal.loc.start + 1 .. literal.loc.end - 1];
            const target_key: []const u8 = try std.fs.path.resolveAlloc(arena, &.{ dir, target_text });
            const target: u32 = index_of.get(target_key) orelse continue; // not in this run
            try out_edges[i].append(arena, @intCast(edges.items.len));
            try edges.append(arena, .{
                .from = @intCast(i),
                .to = target,
                .line = line,
                .col = @intCast(token.loc.start - line_start + 1),
            });
        }
    }

    const order: []u32 = try arena.alloc(u32, files.len);
    for (order, 0..) |*slot, i| {
        slot.* = @intCast(i);
    }
    sortSlice(u32, order, keys, struct {
        fn lessByPath(paths: [][]const u8, a: u32, b: u32) bool {
            return std.mem.lessThan(u8, paths[a], paths[b]);
        }
    }.lessByPath);

    // Iterative DFS: a back edge - one into a file still on the current path - closes a cycle.
    const VisitState = enum { unvisited, on_path, finished };
    const state: []VisitState = try arena.alloc(VisitState, files.len);
    @memset(state, .unvisited);
    const PathFrame = struct { file: u32, next_edge: usize };
    var dfs_path: ArrayList(PathFrame) = .empty;
    for (order) |root| {
        if (state[root] != .unvisited) {
            continue;
        }
        state[root] = .on_path;
        try dfs_path.append(arena, .{ .file = root, .next_edge = 0 });
        while (dfs_path.items.len > 0) {
            const top: *PathFrame = &dfs_path.items[dfs_path.items.len - 1];
            const outgoing: []const u32 = out_edges[top.file].items;
            if (top.next_edge == outgoing.len) {
                state[top.file] = .finished;
                _ = dfs_path.pop();
                continue;
            }
            const edge: ImportEdge = edges.items[outgoing[top.next_edge]];
            top.next_edge += 1; // before any append below moves `top`
            switch (state[edge.to]) {
                .unvisited => {
                    state[edge.to] = .on_path;
                    try dfs_path.append(arena, .{ .file = edge.to, .next_edge = 0 });
                },
                .finished => {},
                .on_path => {
                    // The cycle is the path from where `edge.to` sits on it, down to here.
                    var first_on_cycle: usize = 0;
                    while (dfs_path.items[first_on_cycle].file != edge.to) {
                        first_on_cycle += 1;
                    }
                    var chain: ArrayList(u8) = .empty;
                    for (dfs_path.items[first_on_cycle..]) |frame| {
                        try chain.appendSlice(arena, std.fs.path.basename(files[frame.file]));
                        try chain.appendSlice(arena, " -> ");
                    }
                    try chain.appendSlice(arena, std.fs.path.basename(files[edge.to]));
                    const imports_itself: bool = edge.from == edge.to;
                    const message: []u8 = if (imports_itself)
                        try allocPrint(gpa, "{s} - a file reaches its own names through @This()", .{chain.items})
                    else
                        try allocPrint(gpa, "this import closes a cycle: {s}", .{chain.items});
                    errdefer gpa.free(message);
                    try out_issues.append(gpa, .{
                        .file = files[edge.from],
                        .line = edge.line,
                        .col = edge.col,
                        .tag = "import-cycle",
                        .message = message,
                        .rule = 0,
                    });
                },
            }
        }
    }
}

/// Returns the exit code rather than calling `std.process.exit`, so every path out -
/// the failing one included - unwinds the defers and reaches `start.zig`'s leak check.
/// An `exit(1)` skipped it, which made a leak visible only on a CLEAN tree: the
/// suppressed-fix leak above surfaced exactly because the tree lints clean.
pub fn main(init: std.process.Init) !u8 {
    const gpa: Allocator = init.gpa;
    const arena: Allocator = init.arena.allocator();
    const io: Io = init.io;

    const argv: []const [:0]const u8 = try init.minimal.args.toSlice(arena);

    var args: Args = parseArgs(gpa, arena, argv) catch |e| switch (e) {
        error.Usage => return 2,
        error.Help => return 0,
        else => return e,
    };
    defer args.deinit(gpa);

    if (args.list_rules) {
        var list_buf: [1024]u8 = undefined;
        var list_writer: Io.File.Writer = Io.File.stdout().writer(io, &list_buf);
        for (rule_notes) |note| {
            const marker: []const u8 = if (note.work_in_progress) "  (work in progress)" else "";
            try list_writer.interface.print("{s}{s}\n", .{ note.tag, marker });
        }
        try list_writer.interface.flush();
        return 0;
    }
    if (args.files.items.len == 0) {
        printCliUsage(arena);
        return 0;
    }
    if (args.reorder_decls) {
        return runReorderDecls(io, gpa, args.files.items, args.dry_run);
    }
    if (args.coverage) {
        return runCoverage(io, gpa, args.files.items);
    }

    // ---- Per-file mtime cache setup --------------------------------
    // Stamps live under tools/.zig-cache/lint-stamps/ by default so they
    // survive `rm -rf .zig-cache` in the project root; `--cache-dir` moves
    // them. `--fix --dry-run` skips lookups.
    Io.Dir.cwd().createDirPath(io, args.cache_dir) catch {}; // lint:off catch-suppression: stamp dir, non-fatal
    const binary_mtime_ns: i128 = blk: {
        const stat: Io.Dir.Stat = Io.Dir.cwd().statFile(io, argv[0], .{}) catch break :blk 0;
        break :blk stat.mtime.nanoseconds;
    };

    // ---- Module alias registry -------------------------------------
    // Collect every input file's `//! lint:alias <name>` BEFORE checking any
    // file: canonical-alias needs the declarations up front. Reads headers only
    // (the directive must be in the container doc-comment block), so this stays
    // cheap even though it also visits files the mtime cache would skip.
    var alias_list: ArrayList(AliasDecl) = .empty;
    defer alias_list.deinit(gpa);
    for (args.files.items) |path| {
        if (isSkipped(path)) {
            continue;
        }
        // NOTE: `.limited(n)` ERRORS on a file bigger than n rather than truncating,
        // which silently skipped every module over 8 KB. Read whole files.
        const head: []u8 = Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch continue;
        defer gpa.free(head);
        const declared: []const u8 = declaredAliasOf(head) orelse continue;
        try alias_list.append(gpa, .{
            .stem = try arena.dupe(u8, moduleStem(path)),
            .alias = try arena.dupe(u8, declared),
        });
    }
    args.aliases = alias_list.items;
    const config_hash: u64 = configHash(&args);

    var total_issues: usize = 0;
    // The findings `--fix` can repair, and the command that does it (`--fix-command`, else the linter's own advice).
    var total_fixable: usize = 0;
    // Fixes `--fix` refused because applying them would have broken their file - left for a human.
    var total_refused: usize = 0;
    const fix_command: []const u8 = args.fix_command orelse fix_command_default;
    // What every fixable finding of a check ends with.
    const autofix_note: []const u8 = try allocPrint(arena, "autofix: {s}", .{fix_command});
    // Under --fix: the files rewritten, and the findings left in them for a person (listed as each file is done).
    var files_fixed: usize = 0;
    var total_left: usize = 0;
    // Reports from rules still in progress: printed, counted here, never in the exit code.
    var total_work_in_progress: usize = 0;
    // Inputs that could not be read (or, under --fix, written back). Each one fails
    // the run: a path the linter could not open was not linted, and passing it
    // meant a build handing over a directory (`b.path("src")`) linted nothing and
    // went green.
    var io_failures: usize = 0;

    // The grandfathered counts, keyed "<path>\t<tag>". Empty unless --baseline was given, in
    // which case every rule behaves exactly as it did before the ratchet existed.
    var baseline: StringHashMap(usize) = .init(gpa);
    defer {
        var it: StringHashMap(usize).KeyIterator = baseline.keyIterator();
        while (it.next()) |k| {
            gpa.free(k.*);
        }
        baseline.deinit();
    }
    if (args.baseline_path) |bp| {
        if (!args.write_baseline) {
            const text: []u8 = Io.Dir.cwd().readFileAlloc(io, bp, gpa, .unlimited) catch &.{};
            defer gpa.free(text);
            var lines = splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                const trimmed: []const u8 = trim(u8, line, " \t\r");
                if (trimmed.len == 0 or trimmed[0] == '#') {
                    continue;
                }
                const last_tab: usize = std.mem.lastIndexOfScalar(u8, trimmed, '\t') orelse continue;
                const count: usize = parseInt(usize, trimmed[last_tab + 1 ..], 10) catch continue;
                const key: []u8 = try gpa.dupe(u8, trimmed[0..last_tab]);
                try baseline.put(key, count);
            }
        }
    }
    var baseline_buf: Io.Writer.Allocating = .init(gpa);
    defer baseline_buf.deinit();
    const baseline_out: *Io.Writer = &baseline_buf.writer;
    var out_buf: [4096]u8 = undefined;
    // Violations + fix notes go to STDERR, not out: when lint runs as a
    // build GATE (a dependency of a compile), Zig's Run step surfaces a failed
    // child's stderr but swallows its out - so out-only reports vanished
    // from build logs, leaving just "run exe zimrlint failure". stderr makes
    // the actual `[rule]` line visible (and nothing consumes lint's out).
    var out_writer: Io.File.Writer = Io.File.stdout().writer(io, &out_buf);
    const out: *Io.Writer = &out_writer.interface;

    // First-hit tag tracker - drives the detailed rule-note printing
    // (turn 344).  Lives across all files: we want each rule's "why"
    // to appear once per `lint-check` invocation, not once per file.
    var seen_tags: StringHashMap(void) = .init(gpa);
    defer seen_tags.deinit();

    for (args.files.items) |path| {
        if (isSkipped(path)) {
            continue;
        }

        // ---- Fix mode (`--fix`): rewrite the file in place, like `zig fmt`. ----
        // Uses the same per-file mtime stamp cache as check mode so warm autofix
        // builds skip clean files: a stamped-clean file has nothing to fix, and
        // the stamp's binary-mtime invalidates the moment new fix rules ship. A
        // file that IS fixed is re-stamped at its post-write mtime (residual-0),
        // so the next build skips it too. Unfixable issues still report + fail.
        if (args.fix) {
            const fix_mtime_ns: i128 = blk: {
                const stat: Io.Dir.Stat = Io.Dir.cwd().statFile(io, path, .{}) catch break :blk 0;
                break :blk stat.mtime.nanoseconds;
            };
            const fix_stamp_path: []const u8 = try stampPathFor(arena, args.cache_dir, path);
            if (!args.dry_run) {
                if (loadStamp(io, gpa, fix_stamp_path)) |stamp| {
                    if (stamp.source_mtime_ns == fix_mtime_ns and
                        stamp.binary_mtime_ns == binary_mtime_ns and
                        stamp.config_hash == config_hash)
                    {
                        continue;
                    }
                }
            }

            const source_bytes: []u8 = Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |e| {
                std.debug.print("error reading {s}: {s}\n", .{ path, @errorName(e) });
                io_failures += 1;
                continue;
            };
            defer gpa.free(source_bytes);

            var outcome: FixOutcome = try runFixLoop(gpa, path, source_bytes, &args);
            defer outcome.tally.deinit(gpa);
            // The fixed file is written formatted (`zigFormatted`): a fix makes the smallest edit and leaves the layout
            // to the renderer. A file `zig-fmt` found unformatted is formatted even when no other rule fixed anything;
            // any other file nothing fixed is left exactly as it was.
            if (outcome.edits_applied > 0 or outcome.unformatted) {
                const formatted_bytes: []u8 = try zigFormatted(gpa, outcome.bytes);
                gpa.free(outcome.bytes);
                outcome.bytes = formatted_bytes;
            }
            defer gpa.free(outcome.bytes);
            if (outcome.unformatted) {
                try outcome.tally.add(gpa, "zig-fmt");
            }

            // Every change shown the moment it is made: the rules that made it, then the diff, then the file is done.
            const changed: bool = !eql(u8, outcome.bytes, source_bytes);
            if (changed) {
                if (!args.dry_run) {
                    writeFileWhole(io, path, outcome.bytes) catch |e| {
                        std.debug.print("error writing {s}: {s}\n", .{ path, @errorName(e) });
                        io_failures += 1;
                        continue;
                    };
                }
                files_fixed += 1;
                try printFixTally(out, if (args.dry_run) "would fix" else "fixed", path, outcome.tally);
                try line_diff.print(gpa, out, path, source_bytes, outcome.bytes);
            }

            // What is left for a person, listed under the file's diff: whoever ran the fix wants to know what it
            // could not do. A finding that still carries a fix had it refused, or not reached in the passes.
            const final_z: [:0]u8 = try gpa.allocSentinel(u8, outcome.bytes.len, 0);
            @memcpy(final_z, outcome.bytes);
            defer gpa.free(final_z);
            var fix_issues: ArrayList(Issue) = .empty;
            defer {
                for (fix_issues.items) |is| {
                    is.deinit(gpa);
                }
                fix_issues.deinit(gpa);
            }
            _ = try analyzeSource(gpa, path, final_z, &args, &fix_issues);
            const residual_fixable: usize = try printLeftForPerson(out, path, fix_issues.items);
            total_left += fix_issues.items.len;
            if (outcome.refused_any) {
                total_refused += residual_fixable;
            }
            try out.flush();

            // Stamp clean when the file is fully resolved (no residual, no
            // rollback, real write). Re-stat after a write so the stamp records
            // the post-fix mtime; an untouched clean file keeps `fix_mtime_ns`.
            if (!args.dry_run and !outcome.refused_any and fix_issues.items.len == 0) {
                const stamp_mtime_ns: i128 = if (!changed) fix_mtime_ns else blk: {
                    const stat: Io.Dir.Stat = Io.Dir.cwd().statFile(io, path, .{}) catch break :blk 0;
                    break :blk stat.mtime.nanoseconds;
                };
                if (stamp_mtime_ns != 0) {
                    writeStamp(io, fix_stamp_path, .{
                        .source_mtime_ns = stamp_mtime_ns,
                        .binary_mtime_ns = binary_mtime_ns,
                        .config_hash = config_hash,
                    });
                }
            }
            continue;
        }

        // ---- Check mode (default) ----
        // Cache lookup: if source mtime + binary mtime match the stamp, skip.
        const source_mtime_ns: i128 = blk: {
            const stat: Io.Dir.Stat = Io.Dir.cwd().statFile(io, path, .{}) catch break :blk 0;
            break :blk stat.mtime.nanoseconds;
        };
        const stamp_sub_path: []const u8 = try stampPathFor(arena, args.cache_dir, path);
        if (loadStamp(io, gpa, stamp_sub_path)) |stamp| {
            if (stamp.source_mtime_ns == source_mtime_ns and
                stamp.binary_mtime_ns == binary_mtime_ns and
                stamp.config_hash == config_hash)
            {
                continue;
            }
        }

        const source_bytes: []u8 = Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |e| {
            std.debug.print("error reading {s}: {s}\n", .{ path, @errorName(e) });
            io_failures += 1;
            continue;
        };
        defer gpa.free(source_bytes);
        const source_z: [:0]u8 = try gpa.allocSentinel(u8, source_bytes.len, 0);
        @memcpy(source_z, source_bytes);
        defer gpa.free(source_z);

        var issues: ArrayList(Issue) = .empty;
        defer {
            for (issues.items) |is| {
                is.deinit(gpa);
            }
            issues.deinit(gpa);
        }

        const has_parse_errors: bool = try analyzeSource(gpa, path, source_z, &args, &issues);

        // -- THE RATCHET --
        // Grandfathered issues are counted, recorded, and not reported. Anything ABOVE the
        // recorded count for a (file, tag) is new and fails. See `Args.baseline_path`.
        var kept: ArrayList(Issue) = .empty;
        defer kept.deinit(gpa);
        if (baseline.count() > 0 or args.write_baseline) {
            var per_tag: StringHashMap(usize) = .init(gpa);
            defer per_tag.deinit();
            for (issues.items) |is| {
                const seen_before: usize = per_tag.get(is.tag) orelse 0;
                try per_tag.put(is.tag, seen_before + 1);
                if (args.write_baseline) {
                    continue;
                }
                // Built in a stack buffer rather than allocated: this runs once per issue per
                // file, the two parts are a path and a static tag, and an allocation here has to
                // be freed on every exit path including the two `continue`s. A fixed buffer has
                // no exit paths to get wrong.
                var key_buf: [512]u8 = undefined;
                const key: []const u8 = bufPrint(
                    &key_buf,
                    "{s}\t{s}",
                    .{ path, is.tag },
                ) catch {
                    // Absurdly long path: report rather than silently grandfather.
                    try kept.append(gpa, is);
                    continue;
                };
                const allowance: usize = baseline.get(key) orelse 0;
                if (seen_before < allowance) {
                    continue; // within the grandfathered count
                }
                try kept.append(gpa, is);
            }
            if (args.write_baseline) {
                var it: StringHashMap(usize).Iterator = per_tag.iterator();
                while (it.next()) |e| {
                    try baseline_out.print("{s}\t{s}\t{d}\n", .{ path, e.key_ptr.*, e.value_ptr.* });
                }
            }
        } else {
            try kept.appendSlice(gpa, issues.items);
        }

        total_fixable += try printIssues(out, &seen_tags, kept.items, autofix_note);
        // Reports of rules in progress are printed with the rest but counted apart: they never fail the run.
        const failing: usize = failingCount(kept.items);
        total_issues += failing;
        total_work_in_progress += kept.items.len - failing;

        // Cache write: stamp only when clean (never on parse errors - we want a
        // re-check next run).
        if (issues.items.len == 0 and !has_parse_errors) {
            writeStamp(io, stamp_sub_path, .{
                .source_mtime_ns = source_mtime_ns,
                .binary_mtime_ns = binary_mtime_ns,
                .config_hash = config_hash,
            });
        }
    }

    if (args.write_baseline) {
        if (args.baseline_path) |bp| {
            try writeFileWhole(io, bp, baseline_buf.written());
            try out.print("wrote baseline: {s}\n", .{bp});
        }
        try out.flush();
        return 0;
    }

    // -- import-cycle: the one cross-file rule. It runs over EVERY input, after the per-file
    // reports, because the loop above skips stamped-clean files and a cycle is usually two clean
    // files. Not ratcheted: the baseline is per (file, rule), and a cycle belongs to no one file.
    {
        var cycle_issues: ArrayList(Issue) = .empty;
        defer {
            for (cycle_issues.items) |is| {
                is.deinit(gpa);
            }
            cycle_issues.deinit(gpa);
        }
        try checkImportCycles(gpa, io, args.files.items, &cycle_issues);
        total_fixable += try printIssues(out, &seen_tags, cycle_issues.items, autofix_note);
        total_issues += cycle_issues.items.len;
    }

    if (total_work_in_progress > 0) {
        const in_progress_summary: []const u8 = "\n{d} report(s) of rules in progress - " ++
            "printed above, failing no run\n";
        try out.print(in_progress_summary, .{total_work_in_progress});
    }
    const has_issues: bool = total_issues > 0;
    if (has_issues) {
        try out.print(
            "\n{d} issues in {d} files\n",
            .{ total_issues, args.files.items.len },
        );
    }
    // The way out, spelled exactly: the command that applies the fixes, on a line of its own to copy.
    if (total_fixable > 0) {
        if (args.fix_command) |command| {
            try out.print(
                "{d} of the findings above can be fixed automatically - the fix prints every change it makes. Run:" ++
                    "\n\n    {s}\n\n",
                .{ total_fixable, command },
            );
        } else {
            try out.print("{d} of the findings above can be fixed automatically: {s}\n", .{
                total_fixable,
                fix_command_default,
            });
        }
    }
    // A fix run's last word, only when it has one: a run that found nothing to do says nothing, as `zig fmt` does
    // (`zig build fix` runs several of them - the tree, the template's layout - and an empty one is noise).
    if (args.fix and (files_fixed > 0 or total_left > 0)) {
        if (files_fixed > 0) {
            const verb: []const u8 = if (args.dry_run) "would rewrite" else "rewrote";
            try out.print("zimrlint: {s} {d} file(s) - the diff of each is printed above", .{ verb, files_fixed });
        } else {
            try out.writeAll("zimrlint: nothing here could be fixed automatically");
        }
        if (total_left > 0) {
            try out.print("; {d} finding(s) left for a person, listed under their files", .{total_left});
        }
        try out.writeAll("\n");
    }
    if (total_refused > 0) {
        try out.print("{d} autofix(es) refused - applied, they would break their file: fix those by hand\n", .{
            total_refused,
        });
    }
    if (io_failures > 0) {
        try out.print("\n{d} input(s) could not be read or written - pass files, not directories\n", .{io_failures});
    }
    try out.flush();

    // `--fix` rewrites; it does not gate. What it could not fix is listed under each file's diff, and the next
    // check - `zig build lint`, `check`, an app's build - fails on it. Only an input it could not read or write fails
    // a fix run.
    if (args.fix) {
        return if (io_failures > 0) 1 else 0;
    }
    // The hard gate: any issue is a non-zero exit, so `zig build lint`, `lint-check`
    // and every compile gated on lint fail on it. So is an input that was never linted.
    if (has_issues or io_failures > 0) {
        return 1;
    }
    return 0;
}

// ============================================================================
// Tests -- a tiny in-file rule harness.  Run: `zig test tools/zimrlint.zig`.
// ============================================================================

// Each case feeds a source snippet through the SAME analysis path `main` uses
// (`analyzeSource`) and asserts a rule tag fires -- or stays quiet.  This is
// zlint's RuleTester idea, kept in-file per our one-file rule.  New rules should
// land with a fires/clean pair here so behavior is pinned, not just asserted.

/// `ruleFiresArgs` for a file at `path`: for the rules whose scope is a directory or a file.
fn ruleFiresArgsAt(alloc: Allocator, path: []const u8, src: []const u8, tag: []const u8, args: *Args) !bool {
    const src_z: [:0]u8 = try alloc.allocSentinel(u8, src.len, 0);
    @memcpy(src_z[0..src.len], src);
    var issues: ArrayList(Issue) = .empty;
    _ = try analyzeSource(alloc, path, src_z, args, &issues);
    for (issues.items) |issue| {
        if (eql(u8, issue.tag, tag)) {
            return true;
        }
    }
    return false;
}

/// Lint `src` in-memory and report whether any emitted issue carries `tag`.
/// Uses an arena so nothing leaks (issue messages are owned by the allocator).
fn ruleFiresArgs(alloc: Allocator, src: []const u8, tag: []const u8, args: *Args) !bool {
    // A src/ path so directory-scoped rules (which mostly target src/) apply.
    return ruleFiresArgsAt(alloc, "src/lint_fixture.zig", src, tag, args);
}

/// An `Args` with every rule enabled - what the fires/clean harness uses,
/// since it pins what each rule DOES, not whether a given run has it switched on.
fn allRulesArgs() Args {
    var args: Args = .{ .files = .empty };
    args.enabled = @splat(true);
    return args;
}

fn ruleFires(alloc: Allocator, src: []const u8, tag: []const u8) !bool {
    var args: Args = allRulesArgs();
    return ruleFiresArgs(alloc, src, tag, &args);
}

/// `ruleFires` for a file at `path`.
fn ruleFiresAt(alloc: Allocator, path: []const u8, src: []const u8, tag: []const u8) !bool {
    var args: Args = allRulesArgs();
    return ruleFiresArgsAt(alloc, path, src, tag, &args);
}

fn expectFires(src: []const u8, tag: []const u8) !void {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    try expect(try ruleFires(arena.allocator(), src, tag));
}

fn expectClean(src: []const u8, tag: []const u8) !void {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    try expect(!try ruleFires(arena.allocator(), src, tag));
}

// catch-suppression now runs unconditionally; these are thin tag wrappers.
fn expectCatchFires(src: []const u8) !void {
    try expectFires(src, "catch-suppression");
}

fn expectCatchClean(src: []const u8) !void {
    try expectClean(src, "catch-suppression");
}

test "branch-braces fires on an unbraced if body" {
    try expectFires("fn f(x: bool) void {\n    if (x) return;\n}\n", "branch-braces");
}

test "branch-braces stays quiet when the body is a block" {
    try expectClean("fn f(x: bool) void {\n    if (x) {\n        return;\n    }\n}\n", "branch-braces");
}

test "untyped-local fires on a const with no type annotation" {
    try expectFires("fn f() void {\n    const n = 3;\n    _ = n;\n}\n", "untyped-local");
}

test "untyped-local stays quiet with a type annotation" {
    try expectClean("fn f() void {\n    const n: u32 = 3;\n    _ = n;\n}\n", "untyped-local");
}

test "a file-level //! lint:off directive suppresses a rule" {
    try expectClean("//! lint:off branch-braces\nfn f(x: bool) void {\n    if (x) return;\n}\n", "branch-braces");
}

test "returned-stack-reference fires on return &local" {
    try expectFires("fn f() *u32 {\n    var x: u32 = 1;\n    return &x;\n}\n", "returned-stack-reference");
}

test "returned-stack-reference stays quiet on return &self.field" {
    try expectClean(
        "const S = struct {\n    v: u32,\n    fn get(self: *S) *u32 {\n" ++
            "        return &self.v;\n    }\n};\n",
        "returned-stack-reference",
    );
}

test "returned-stack-reference stays quiet on return &arr[i]" {
    try expectClean("fn f(arr: []u32, i: usize) *u32 {\n    return &arr[i];\n}\n", "returned-stack-reference");
}

test "whole-init-first fires on create then field writes" {
    try expectFires(
        "const S = struct { a: u32, b: u32 = 7 };\n" ++
            "fn make(gpa: std.mem.Allocator) !*S {\n    const s: *S = try gpa.create(S);\n" ++
            "    s.a = 1;\n    return s;\n}\n",
        "whole-init-first",
    );
}

test "whole-init-first stays quiet on create then a whole write" {
    try expectClean(
        "const S = struct { a: u32, b: u32 = 7 };\n" ++
            "fn make(gpa: std.mem.Allocator) !*S {\n    const s: *S = try gpa.create(S);\n" ++
            "    s.* = .{ .a = 1 };\n    s.a = 2;\n    return s;\n}\n",
        "whole-init-first",
    );
}

test "whole-init-first fires on an init writing a field first" {
    try expectFires(
        "const S = struct {\n    a: u32,\n    b: u32 = 7,\n" ++
            "    fn init(self: *S) void {\n        self.a = 1;\n    }\n};\n",
        "whole-init-first",
    );
}

test "whole-init-first fires on self.* = undefined" {
    try expectFires(
        "const S = struct {\n    a: u32,\n" ++
            "    fn init(self: *S) void {\n        self.* = undefined;\n        self.a = 1;\n    }\n};\n",
        "whole-init-first",
    );
}

test "whole-init-first stays quiet when a method takes the initialisation over" {
    try expectClean(
        "const S = struct {\n    a: u32,\n    fn init(self: *S) void {\n        self.* = .{ .a = 1 };\n    }\n};\n" ++
            "fn make(gpa: std.mem.Allocator) !*S {\n    const s: *S = try gpa.create(S);\n" ++
            "    s.init();\n    s.a = 2;\n    return s;\n}\n",
        "whole-init-first",
    );
}

test "whole-init-first reaches inside a generic type function's struct" {
    try expectFires(
        "fn Box(comptime T: type) type {\n    return struct {\n        a: T,\n" ++
            "        fn make(gpa: std.mem.Allocator) !*@This() {\n" ++
            "            const s: *@This() = try gpa.create(@This());\n            s.a = 1;\n" ++
            "            return s;\n        }\n    };\n}\n",
        "whole-init-first",
    );
}

test "whole-init-first stays quiet on a non-init method writing fields" {
    try expectClean(
        "const S = struct {\n    a: u32,\n    fn reset(self: *S) void {\n        self.a = 0;\n    }\n};\n",
        "whole-init-first",
    );
}

test "returned-stack-reference stays quiet on return &global" {
    try expectClean("const g: u32 = 0;\nfn f() *const u32 {\n    return &g;\n}\n", "returned-stack-reference");
}

test "catch-suppression fires on empty catch {}" {
    try expectCatchFires("fn f() void {\n    foo() catch {};\n}\n");
}

test "catch-suppression fires on catch unreachable" {
    try expectCatchFires("fn f() void {\n    foo() catch unreachable;\n}\n");
}

test "catch-suppression stays quiet on a real handler body" {
    try expectCatchClean("fn f() void {\n    foo() catch {\n        bar();\n    };\n}\n");
}

test "catch-suppression stays quiet on catch return" {
    try expectCatchClean("fn f() !void {\n    foo() catch return;\n}\n");
}

test "catch-suppression stays quiet on a default value" {
    try expectCatchClean("fn f() u32 {\n    return foo() catch 0;\n}\n");
}

test "prefer-assert-unreachable fires on assertf(false, ...)" {
    try expectFires("fn f() void {\n    assertf(false, @src(), \"x\", .{});\n}\n", "prefer-assert-unreachable");
}

test "prefer-assert-unreachable fires on assert(false, ...)" {
    try expectFires("fn f() void {\n    assert(false, @src());\n}\n", "prefer-assert-unreachable");
}

test "prefer-assert-unreachable stays quiet on a real condition" {
    try expectClean("fn f(x: bool) void {\n    assertf(x, @src(), \"x\", .{});\n}\n", "prefer-assert-unreachable");
}

test "no-catch-return fires on catch |e| return e" {
    try expectFires("fn f() !void {\n    g() catch |e| return e;\n}\n", "no-catch-return");
}

test "no-catch-return stays quiet returning a different value" {
    try expectClean("fn f() !void {\n    g() catch |e| return other;\n}\n", "no-catch-return");
}

test "unused-global fires on an unused private fn" {
    try expectFires("fn helper() void {}\n", "unused-global");
}

test "unused-global stays quiet on an export fn" {
    try expectClean("export fn entry() void {}\n", "unused-global");
}

test "unused-global stays quiet on a called private fn" {
    try expectClean("pub fn a() void {\n    b();\n}\nfn b() void {}\n", "unused-global");
}

// useless-error-return runs unconditionally; these are thin tag wrappers.
fn expectUselessFires(src: []const u8) !void {
    try expectFires(src, "useless-error-return");
}

fn expectUselessClean(src: []const u8) !void {
    try expectClean(src, "useless-error-return");
}

test "useless-error-return fires on an errorless !void fn" {
    try expectUselessFires("fn f() !void {\n    doStuff();\n}\n");
}

test "useless-error-return fires on a literal-returning !u32 fn" {
    try expectUselessFires("fn f() !u32 {\n    return 42;\n}\n");
}

test "useless-error-return stays quiet when the body has a try" {
    try expectUselessClean("fn f() !void {\n    try g();\n}\n");
}

test "useless-error-return stays quiet on a named-error-set return" {
    try expectUselessClean("fn f() !void {\n    return MyError.Bad;\n}\n");
}

test "useless-error-return stays quiet on a returned call" {
    try expectUselessClean("fn f() !u32 {\n    return g();\n}\n");
}

test "useless-error-return stays quiet on a returned if-expr of calls" {
    try expectUselessClean("fn f() !u32 {\n    return if (c) a() else b();\n}\n");
}

test "useless-error-return ignores a plain (non-error) return type" {
    try expectUselessClean("fn f() u32 {\n    return 42;\n}\n");
}

test "useless-error-return stays quiet when the fn is used as a value" {
    try expectUselessClean("fn f() !void {\n    g();\n}\nconst spec = .{ .init = f };\n");
}

test "useless-error-return fires when a catch handles the error" {
    try expectUselessFires("fn f() !void {\n    g() catch return;\n}\n");
}

test "useless-error-return stays quiet when a catch re-raises" {
    try expectUselessClean("fn f() !void {\n    g() catch return MyError.Failed;\n}\n");
}

const dup_fires =
    \\fn f(x: E) void {
    \\    switch (x) {
    \\        .a => {
    \\            doThing();
    \\        },
    \\        .b => {
    \\            doThing();
    \\        },
    \\    }
    \\}
;

test "duplicate-case fires on two prongs with the same block body" {
    try expectFires(dup_fires, "duplicate-case");
}

const dup_lookup =
    \\fn f(x: E) u8 {
    \\    return switch (x) {
    \\        .a => 2,
    \\        .b => 2,
    \\    };
    \\}
;

test "duplicate-case stays quiet on a lookup-table switch" {
    try expectClean(dup_lookup, "duplicate-case");
}

const dup_noop =
    \\fn f(x: E) void {
    \\    switch (x) {
    \\        .a => {},
    \\        .b => {},
    \\    }
    \\}
;

test "duplicate-case stays quiet on exhaustive no-op prongs" {
    try expectClean(dup_noop, "duplicate-case");
}

const dup_commented =
    \\fn f(x: E) void {
    \\    switch (x) {
    \\        .a => {
    \\            doThing();
    \\        },
    \\        // kept separate on purpose
    \\        .b => {
    \\            doThing();
    \\        },
    \\    }
    \\}
;

test "duplicate-case stays quiet when a prong carries its own comment" {
    try expectClean(dup_commented, "duplicate-case");
}

const dup_captured =
    \\fn f(x: E) void {
    \\    switch (x) {
    \\        .a => |v| {
    \\            doThing(v);
    \\        },
    \\        .b => |v| {
    \\            doThing(v);
    \\        },
    \\    }
    \\}
;

test "duplicate-case stays quiet on prongs with captures" {
    try expectClean(dup_captured, "duplicate-case");
}

const imp_fires =
    \\const wgpu = @import("wgpu.zig");
    \\fn f() void {
    \\    @import("wgpu.zig").go();
    \\}
;

test "redundant-import fires when a file-scope alias already exists" {
    try expectFires(imp_fires, "redundant-import");
}

const imp_no_alias =
    \\pub const a = @import("m.zig").a;
    \\pub const b = @import("m.zig").b;
;

test "redundant-import stays quiet with no whole-module alias" {
    try expectClean(imp_no_alias, "redundant-import");
}

const imp_member_only =
    \\const thing = @import("m.zig").thing;
    \\fn f() void {
    \\    @import("m.zig").other();
    \\}
;

test "redundant-import stays quiet when only a member is bound" {
    try expectClean(imp_member_only, "redundant-import");
}

const imp_two_aliases =
    \\const m1 = @import("m.zig");
    \\const m2 = @import("m.zig");
    \\fn f() void {
    \\    @import("m.zig").go();
    \\}
;

test "redundant-import stays quiet when the module has two aliases" {
    try expectClean(imp_two_aliases, "redundant-import");
}

fn withAlias(src: []const u8, stem: []const u8, alias: []const u8) !bool {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const decls = [_]AliasDecl{.{ .stem = stem, .alias = alias }};
    var args: Args = .{ .files = .empty, .aliases = &decls };
    // Every rule is opt-in: the rule under test must be switched on.
    try enableRules(&args.enabled, "canonical-alias");
    return ruleFiresArgs(arena.allocator(), src, "canonical-alias", &args);
}

test "canonical-alias fires on a non-declared spelling" {
    try expect(try withAlias("const img = @import(\"image.zig\");\n", "image", "image"));
}

test "canonical-alias stays quiet on the declared spelling" {
    try expect(!try withAlias("const image = @import(\"image.zig\");\n", "image", "image"));
}

test "canonical-alias matches a build-module name via the declared alias" {
    try expect(try withAlias("const m = @import(\"zm\");\n", "zimrmath", "zm"));
}

test "canonical-alias exempts a pub re-export" {
    try expect(!try withAlias("pub const colors = @import(\"types.zig\");\n", "types", "types"));
}

test "import-at-root fires on an import inside a function body" {
    try expectFires("fn f() void {\n    const w = @import(\"web.zig\");\n    _ = w;\n}\n", "import-at-root");
}

test "import-at-root fires on an import used inline in an expression" {
    try expectFires("fn f() void {\n    @import(\"web.zig\").go();\n}\n", "import-at-root");
}

test "import-at-root stays quiet on a container-scope binding" {
    try expectClean("const web = @import(\"web.zig\");\n", "import-at-root");
}

test "import-at-root stays quiet on a nested namespace binding" {
    try expectClean("const ns = struct {\n    pub const vs = @import(\"vs.zig\");\n};\n", "import-at-root");
}

test "import-at-root stays quiet on test aggregation" {
    try expectClean("test {\n    _ = @import(\"x_test.zig\");\n}\n", "import-at-root");
}

test "rule_notes has no duplicate tags" {
    for (rule_notes, 0..) |a, i| {
        for (rule_notes[i + 1 ..]) |b| {
            try expect(!eql(u8, a.tag, b.tag));
        }
    }
}

test "tags asserted by the harness are documented in rule_notes" {
    // Seed of the "every emitted tag has a rationale" cross-check: any rule with
    // a fires/clean test above must also have a rule_notes entry.
    const tested = [_][]const u8{
        "branch-braces",
        "untyped-local",
        "returned-stack-reference",
        "whole-init-first",
        "catch-suppression",
        "prefer-assert-unreachable",
        "no-catch-return",
        "unused-global",
        "useless-error-return",
        "duplicate-case",
        "redundant-import",
        "canonical-alias",
        "import-at-root",
        "state-uninit",
        "float-from-int",
        "prefer-splat",
        "zig-fmt",
        "unknown-lint-tag",
    };
    for (tested) |tag| {
        var found: bool = false;
        for (rule_notes) |note| {
            if (eql(u8, note.tag, tag)) {
                found = true;
            }
        }
        try expect(found);
    }
}

test "a rule reports nothing unless enabled" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const src: []const u8 = "fn f(x: bool) void {\n    if (x) return;\n}\n";
    var args: Args = .{ .files = .empty };
    try expect(!try ruleFiresArgs(arena.allocator(), src, "branch-braces", &args));
    try enableRules(&args.enabled, "branch-braces");
    try expect(try ruleFiresArgs(arena.allocator(), src, "branch-braces", &args));
}

test "every rule is opt-in: even a bug catcher like catch-suppression reports nothing until enabled" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    var args: Args = .{ .files = .empty };
    const src: []const u8 = "fn f() void {\n    foo() catch {};\n}\n";
    try expect(!try ruleFiresArgs(arena.allocator(), src, "catch-suppression", &args));
    try enableRules(&args.enabled, "catch-suppression");
    try expect(try ruleFiresArgs(arena.allocator(), src, "catch-suppression", &args));
}

test "--enable accepts every rule and rejects a tag that is not one" {
    var enabled: EnabledRules = @splat(false);
    try enableRules(&enabled, "untyped-local,anon-return,line-length");
    try expect(enabled[ruleIndex("untyped-local").?]);
    try expect(enabled[ruleIndex("anon-return").?]);
    try expect(enabled[ruleIndex("line-length").?]);
    try expectError(error.Usage, enableRules(&enabled, "no-such-rule"));
}

test "the stamp config hash follows the enabled set, not its order" {
    var a: Args = .{ .files = .empty };
    var b: Args = .{ .files = .empty };
    const none: u64 = configHash(&a);
    try enableRules(&a.enabled, "untyped-local,branch-braces");
    try enableRules(&b.enabled, "branch-braces,untyped-local");
    try expect(configHash(&a) != none);
    try expect(configHash(&a) == configHash(&b));
}

test "unknown-lint-tag fires on a directive naming no rule" {
    try expectFires("const a: u32 = 1; // lint:off no-such-rule: why\n", "unknown-lint-tag");
    try expectFires("//! lint:off branch-braces,no-such-rule\n", "unknown-lint-tag");
}

test "unknown-lint-tag stays quiet on real tags and on prose about the syntax" {
    try expectClean("const a: u32 = 1; // lint:off line-length: why\n", "unknown-lint-tag");
    try expectClean("// A reviewed exception carries `// lint:off tag-here: why`.\n", "unknown-lint-tag");
    try expectClean("/// Write // lint:off rule: reason on the line.\n", "unknown-lint-tag");
    try expectClean("// Add a // lint:off <tag>: <why> directive.\n", "unknown-lint-tag");
    try expectClean("const marker: []const u8 = \"// lint:off nope\";\n", "unknown-lint-tag");
}

test "state-uninit fires only in a file that declares an AppSpec" {
    const body: []const u8 = "fn f() void {\n    var s: State = undefined;\n    _ = &s;\n}\n";
    const app: []const u8 = "pub const app: z.AppSpec(State) = .{};\n";
    var buf: [256]u8 = undefined;
    const with_app: []const u8 = try bufPrint(&buf, "{s}{s}", .{ app, body });
    try expectFires(with_app, "state-uninit");
    try expectClean(body, "state-uninit");
}

/// The replacement text of the first `tag` fix emitted for `src`, or null.
fn fixReplacement(alloc: Allocator, src: []const u8, tag: []const u8) !?[]const u8 {
    const src_z: [:0]u8 = try alloc.allocSentinel(u8, src.len, 0);
    @memcpy(src_z[0..src.len], src);
    var issues: ArrayList(Issue) = .empty;
    var args: Args = allRulesArgs();
    _ = try analyzeSource(alloc, "src/lint_fixture.zig", src_z, &args, &issues);
    for (issues.items) |issue| {
        if (eql(u8, issue.tag, tag)) {
            if (issue.fix) |fx| {
                return fx.replacement;
            }
        }
    }
    return null;
}

test "float-from-int fixes to the spelling the file can resolve" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const a: Allocator = arena.allocator();
    const bound: []const u8 =
        \\const zm = @import("zm");
        \\const float = zm.float;
        \\fn f(n: u32) f32 {
        \\    return @as(f32, @floatFromInt(n));
        \\}
        \\
    ;
    const unbound: []const u8 =
        \\const zm = @import("zm");
        \\fn f(n: u32) f32 {
        \\    return @as(f32, @floatFromInt(n));
        \\}
        \\
    ;
    const no_zm: []const u8 = "fn f(n: u32) f32 {\n    return @as(f32, @floatFromInt(n));\n}\n";
    try expect(eql(u8, (try fixReplacement(a, bound, "float-from-int")).?, "float(n)"));
    try expect(eql(u8, (try fixReplacement(a, unbound, "float-from-int")).?, "zm.float(n)"));
    try expect(try fixReplacement(a, no_zm, "float-from-int") == null);
    try expectFires(no_zm, "float-from-int");
}

test "prefer-splat fixes to the spelling the file can resolve" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const a: Allocator = arena.allocator();
    const bound: []const u8 =
        \\const zm = @import("zm");
        \\const Vec = zm.Vec;
        \\const splat = zm.splat;
        \\pub fn f(v: Vec, s: f32) Vec {
        \\    return v * @as(Vec, @splat(s));
        \\}
        \\
    ;
    const unbound: []const u8 =
        \\const zm = @import("zm");
        \\const Vec = zm.Vec;
        \\pub fn f(v: Vec, s: f32) Vec {
        \\    return v * @as(Vec, @splat(s));
        \\}
        \\
    ;
    // Bound only BELOW the use: the bare name would be a use before its declaration.
    const bound_below: []const u8 =
        \\const zm = @import("zm");
        \\const Vec = zm.Vec;
        \\pub fn f(v: Vec, s: f32) Vec {
        \\    return v * @as(Vec, @splat(s));
        \\}
        \\const splat = zm.splat;
        \\
    ;
    // zimrmath.zig's own shape: no zm import, the helper declared in the file.
    const declares_helper: []const u8 =
        \\pub const Vec = @Vector(4, f32);
        \\pub fn splat(v: f32) Vec {
        \\    return @splat(v);
        \\}
        \\pub fn half(v: Vec) Vec {
        \\    return v * @as(Vec, @splat(0.5));
        \\}
        \\
    ;
    const no_zm: []const u8 = "pub fn f(v: @Vector(4, f32)) @Vector(4, f32) {\n" ++
        "    return v * @as(Vec, @splat(2.0));\n}\n";
    try expectEqualStrings("splat(s)", (try fixReplacement(a, bound, "prefer-splat")).?);
    try expectEqualStrings("zm.splat(s)", (try fixReplacement(a, unbound, "prefer-splat")).?);
    try expectEqualStrings("zm.splat(s)", (try fixReplacement(a, bound_below, "prefer-splat")).?);
    try expectEqualStrings("splat(0.5)", (try fixReplacement(a, declares_helper, "prefer-splat")).?);
    try expect(try fixReplacement(a, no_zm, "prefer-splat") == null);
    try expectFires(no_zm, "prefer-splat");
}

test "prefer-splat: each width gets its helper, the type bare or qualified, the argument kept whole" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const a: Allocator = arena.allocator();
    const prefix: []const u8 = "const zm = @import(\"zm\");\nconst rbt = @import(\"robot.zig\");\n";
    const Case = struct { expression: []const u8, replacement: []const u8 };
    const cases = [_]Case{
        .{ .expression = "@as(Vec3, @splat(r * 2.0))", .replacement = "zm.splat3(r * 2.0)" },
        .{ .expression = "@as(Vec2, @splat(1.0 / r))", .replacement = "zm.splat2(1.0 / r)" },
        .{ .expression = "@as(Vec2i, @splat(0))", .replacement = "zm.splat2i(0)" },
        .{ .expression = "@as(zm.Vec, @splat(r))", .replacement = "zm.splat(r)" },
        .{ .expression = "@as(rbt.Vec, @splat(length(v)))", .replacement = "zm.splat(length(v))" },
    };
    for (cases) |case| {
        const src: []const u8 = try std.mem.concat(a, u8, &.{
            prefix,
            "pub fn f(r: f32) void {\n    _ = r;\n    _ = ",
            case.expression,
            ";\n}\n",
        });
        try expectEqualStrings(case.replacement, (try fixReplacement(a, src, "prefer-splat")).?);
    }
}

test "prefer-splat stays quiet where the type is not one of zm's or the @as is not wrapping a splat" {
    const tag: []const u8 = "prefer-splat";
    const prefix: []const u8 = "const zm = @import(\"zm\");\nconst Vec = zm.Vec;\n";
    // The declaration already gives `@splat` its type - nothing to remove.
    try expectClean(prefix ++ "pub fn f(s: f32) Vec {\n    const k: Vec = @splat(s);\n    return k;\n}\n", tag);
    // Generic code and the wide types keep the explicit form.
    try expectClean("pub fn f(comptime T: type, s: f32) T {\n    return @as(T, @splat(s));\n}\n", tag);
    try expectClean(prefix ++ "pub fn f(s: f32) zm.F32x8 {\n    return @as(zm.F32x8, @splat(s));\n}\n", tag);
    try expectClean("pub fn f(s: f32) [4]f32 {\n    return @as([4]f32, @splat(s));\n}\n", tag);
    // An `@as(Vec, ...)` of something other than `@splat`.
    try expectClean(prefix ++ "pub fn f(v: Vec) Vec {\n    return @as(Vec, v);\n}\n", tag);
}

// ---- no-qualified-zm, pinned before its machinery was shared with no-qualified-std --------------------------------

/// Every issue `tag` reports on `src` (every rule enabled), allocated from `alloc` - for tests that need a
/// report's message or fix, not only whether it fired.
fn issuesTagged(alloc: Allocator, src: []const u8, tag: []const u8) ![]Issue {
    const src_z: [:0]u8 = try alloc.allocSentinel(u8, src.len, 0);
    @memcpy(src_z[0..src.len], src);
    var issues: ArrayList(Issue) = .empty;
    var args: Args = allRulesArgs();
    _ = try analyzeSource(alloc, "src/lint_fixture.zig", src_z, &args, &issues);
    var tagged: ArrayList(Issue) = .empty;
    for (issues.items) |issue| {
        if (eql(u8, issue.tag, tag)) {
            try tagged.append(alloc, issue);
        }
    }
    return tagged.items;
}

/// `src` with `fix` applied - the text `--fix` would write.
fn applyFix(alloc: Allocator, src: []const u8, fix: Fix) ![]u8 {
    return std.mem.concat(alloc, u8, &.{ src[0..fix.start], fix.replacement, src[fix.end..] });
}

test "no-qualified-zm fires on a qualified keyword in a body when nothing binds it" {
    try expectFires(
        "const zm = @import(\"zm\");\nfn f(v: zm.Vec3) f32 {\n    return zm.length(v);\n}\n",
        "no-qualified-zm",
    );
}

test "no-qualified-zm offers the fix when the binding exists - dropping `zm.`" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const src: []const u8 = "const zm = @import(\"zm\");\nconst length = zm.length;\nconst Vec3 = zm.Vec3;\n" ++
        "fn f(v: Vec3) f32 {\n    return zm.length(v);\n}\n";
    const issues: []Issue = try issuesTagged(arena.allocator(), src, "no-qualified-zm");
    try expect(issues.len == 1);
    const fix: Fix = issues[0].fix.?;
    try expect(eql(u8, fix.replacement, ""));
    try expect(eql(u8, src[fix.start..fix.end], "zm."));
    const fixed: []u8 = try applyFix(arena.allocator(), src, fix);
    try expect(indexOf(u8, fixed, "return length(v);") != null);
}

test "no-qualified-zm: a keyword is bare EVERYWHERE - a parameter, a return type, a field type (Oct 2)" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const src: []const u8 = "const zm = @import(\"zm\");\nconst Vec3 = zm.Vec3;\n" ++
        "fn f(v: zm.Vec3) zm.Vec3 {\n    return v;\n}\n" ++
        "const Body = struct {\n    position: zm.Vec3,\n};\n";
    const issues: []Issue = try issuesTagged(arena.allocator(), src, "no-qualified-zm");
    try expect(issues.len == 3);
    for (issues) |issue| {
        // The binding exists, so each one's fix drops the `zm.`.
        try expect(issue.fix != null and eql(u8, src[issue.fix.?.start..issue.fix.?.end], "zm."));
    }
}

test "no-qualified-zm --fix: a missing binding is inserted (pass one), then every use goes bare (pass two)" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const alloc: Allocator = arena.allocator();
    const src: []const u8 = "const zm = @import(\"zm\");\n" ++
        "fn f(a: f32, b: f32) f32 {\n    return zm.clamp(a, 0, 1) + zm.clamp(b, 0, 1);\n}\n";
    // Pass one: both uses ask for the same insertion - one binding, right after the zm import.
    const first: []Issue = try issuesTagged(alloc, src, "no-qualified-zm");
    try expect(first.len == 2);
    try expect(first[0].fix != null and first[1].fix != null);
    try expect(first[0].fix.?.start == first[1].fix.?.start);
    const bound: []u8 = try applyFix(alloc, src, first[0].fix.?);
    try expect(startsWith(u8, bound, "const zm = @import(\"zm\");\nconst clamp = zm.clamp;\n"));
    // Pass two: bound now - each fix drops a `zm.`; applied back to front, nothing is left to say.
    const second: []Issue = try issuesTagged(alloc, bound, "no-qualified-zm");
    try expect(second.len == 2);
    const one_dropped: []u8 = try applyFix(alloc, bound, second[1].fix.?);
    const both_dropped: []u8 = try applyFix(alloc, one_dropped, second[0].fix.?);
    try expect(indexOf(u8, both_dropped, "return clamp(a, 0, 1) + clamp(b, 0, 1);") != null);
    try expectClean(both_dropped, "no-qualified-zm");
}

test "no-qualified-zm --fix inserts no binding where the name is already declared - that would collide" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const src: []const u8 = "const zm = @import(\"zm\");\n" ++
        "fn f(clamp: f32) f32 {\n    return zm.clamp(clamp, 0, 1);\n}\n";
    const issues: []Issue = try issuesTagged(arena.allocator(), src, "no-qualified-zm");
    try expect(issues.len == 1 and issues[0].fix == null);
}

test "no-qualified-zm stays quiet on a non-keyword, on the binding itself, and without a column-0 zm" {
    // `matFromAxisAngle` is not a keyword: it may stay qualified.
    try expectClean(
        "const zm = @import(\"zm\");\nfn f(axis: [3]f32) [16]f32 {\n    return zm.matFromAxisAngle(axis, 0.5);\n}\n",
        "no-qualified-zm",
    );
    // The binding's own `zm.length` is its one legal home.
    try expectClean("const zm = @import(\"zm\");\nconst length = zm.length;\n", "no-qualified-zm");
    // zm imported inside a struct, not at column 0: no file-scope binding is possible.
    try expectClean(
        "const S = struct {\n    const zm = @import(\"zm\");\n" ++
            "    fn f(v: zm.Vec3) f32 {\n        return zm.length(v);\n    }\n};\n",
        "no-qualified-zm",
    );
}

// ---- no-qualified-std ----------------------------------------------------------------------------------------------

test "no-qualified-std fires on a vocabulary name used qualified - in a body and in a signature" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const src: []const u8 = "const std = @import(\"std\");\n" ++
        "fn f(gpa: std.mem.Allocator, a: []const u8) bool {\n    _ = gpa;\n    return std.mem.eql(u8, a, \"x\");\n}\n";
    const issues: []Issue = try issuesTagged(arena.allocator(), src, "no-qualified-std");
    try expect(issues.len == 2);
    try expect(eql(u8, issues[0].fix.?.replacement, "const Allocator = std.mem.Allocator;\n"));
    try expect(startsWith(u8, issues[0].message, "qualified 'std.mem.Allocator'"));
    try expect(indexOf(u8, issues[0].message, "`const Allocator = std.mem.Allocator;`") != null);
    try expect(indexOf(u8, issues[1].message, "`const eql = std.mem.eql;`") != null);
}

test "no-qualified-std, with the binding present: the fix drops the qualifier; a renamed alias replaces it all" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const alloc: Allocator = arena.allocator();
    const same_name: []const u8 = "const std = @import(\"std\");\nconst eql = std.mem.eql;\n" ++
        "fn f(a: []const u8) bool {\n    return std.mem.eql(u8, a, \"x\");\n}\n";
    const same_issues: []Issue = try issuesTagged(alloc, same_name, "no-qualified-std");
    try expect(same_issues.len == 1);
    const same_fixed: []u8 = try applyFix(alloc, same_name, same_issues[0].fix.?);
    try expect(indexOf(u8, same_fixed, "return eql(u8, a, \"x\");") != null);
    const renamed: []const u8 = "const std = @import(\"std\");\nconst testing_allocator = std.testing.allocator;\n" ++
        "test \"t\" {\n    const gpa = std.testing.allocator;\n    _ = gpa;\n}\n";
    const renamed_issues: []Issue = try issuesTagged(alloc, renamed, "no-qualified-std");
    try expect(renamed_issues.len == 1);
    const renamed_fixed: []u8 = try applyFix(alloc, renamed, renamed_issues[0].fix.?);
    try expect(indexOf(u8, renamed_fixed, "const gpa = testing_allocator;") != null);
}

test "no-qualified-std stays quiet on the binding, where the name is declared, without a column-0 std, off-vocabulary" {
    // The binding's own init is its one legal home.
    try expectClean("const std = @import(\"std\");\nconst eql = std.mem.eql;\n", "no-qualified-std");
    // A parameter of that name: the binding would not compile beside it.
    try expectClean(
        "const std = @import(\"std\");\nfn f(eql: bool) bool {\n    return eql or std.mem.eql(u8, \"a\", \"b\");\n}\n",
        "no-qualified-std",
    );
    // A method of that name: legal, but one word would mean two things on one page.
    try expectClean(
        "const std = @import(\"std\");\nconst P = struct {\n    x: u8,\n    fn eql(a: P, b: P) bool {\n" ++
            "        return a.x == b.x and std.mem.eql(u8, \"a\", \"b\");\n    }\n};\n",
        "no-qualified-std",
    );
    // std imported inside a function: no file-scope binding is possible.
    try expectClean(
        "fn f(a: []const u8) bool {\n    const std = @import(\"std\");\n    return std.mem.eql(u8, a, \"x\");\n}\n",
        "no-qualified-std",
    );
    // `std.meta.eql` is not in the vocabulary (a bare `eql` can mean one thing).
    try expectClean(
        "const std = @import(\"std\");\nfn f(a: u8, b: u8) bool {\n    return std.meta.eql(a, b);\n}\n",
        "no-qualified-std",
    );
}

test "no-qualified-std reports `std.Io.Writer` once, for `std.Io`" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const src: []const u8 = "const std = @import(\"std\");\nfn f(w: *std.Io.Writer) void {\n    _ = w;\n}\n";
    const issues: []Issue = try issuesTagged(arena.allocator(), src, "no-qualified-std");
    try expect(issues.len == 1);
    try expect(indexOf(u8, issues[0].message, "'std.Io'") != null);
}

// ---- prefer-decl-literal ------------------------------------------------------------------------------------------

test "prefer-decl-literal fires where the call repeats the declared type - with and without try, at any scope" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const alloc: Allocator = arena.allocator();
    const src: []const u8 = "const seeded: Rng = Rng.init(7);\n" ++
        "fn f(gpa: Allocator) !void {\n" ++
        "    var grid: Tensor(f32) = try Tensor(f32).alloc(gpa, &.{ 2, 3 });\n" ++
        "    _ = &grid;\n" ++
        "}\n";
    const issues: []Issue = try issuesTagged(alloc, src, "prefer-decl-literal");
    try expect(issues.len == 2);
    // Reported at the receiver: `Rng` after `const seeded: Rng = `, `Tensor` after `... = try `.
    try expect(issues[0].line == 1 and issues[0].col == 21);
    try expect(issues[1].line == 3 and issues[1].col == 33);
    try expect(indexOf(u8, issues[0].message, "'.init(...)'") != null);
    try expect(indexOf(u8, issues[1].message, "'.alloc(...)'") != null);
    // Each fix removes exactly the receiver.
    const first_fixed: []u8 = try applyFix(alloc, src, issues[0].fix.?);
    try expect(startsWith(u8, first_fixed, "const seeded: Rng = .init(7);\n"));
    const second_fixed: []u8 = try applyFix(alloc, src, issues[1].fix.?);
    try expect(indexOf(u8, second_fixed, "    var grid: Tensor(f32) = try .alloc(gpa, &.{ 2, 3 });\n") != null);
}

test "prefer-decl-literal stays quiet unless the rewrite is the same call by construction" {
    // A different receiver - `.make()` would look `make` up in Base, not Other - and another instantiation.
    try expectClean("const b: Base = Other.make();\n", "prefer-decl-literal");
    const another_instantiation: []const u8 = "fn f() !void {\n" ++
        "    const t: Tensor(f32) = try Tensor(f64).alloc(gpa, &.{1});\n    _ = t;\n}\n";
    try expectClean(another_instantiation, "prefer-decl-literal");
    // A receiver that only ENDS like the type: other tokens, maybe another type.
    try expectClean("const a: Foo = ns.Foo.make();\n", "prefer-decl-literal");
    // The call is not the whole initializer: under catch, orelse, a field access, parentheses, comptime.
    try expectClean("const a: Foo = Foo.make() catch unreachable;\n", "prefer-decl-literal");
    try expectClean("const a: Foo = Foo.find(1) orelse Foo.empty;\n", "prefer-decl-literal");
    try expectClean("const a: Foo = Foo.make().inner;\n", "prefer-decl-literal");
    try expectClean("const a: Foo = (Foo.make());\n", "prefer-decl-literal");
    try expectClean("const a: Foo = comptime Foo.make();\n", "prefer-decl-literal");
    // An optional annotation is another type than its payload.
    try expectClean("const a: ?Foo = Foo.make();\n", "prefer-decl-literal");
    // No annotation; a value rather than a call; a call already written as a decl literal.
    try expectClean("const a = Foo.make();\n", "prefer-decl-literal");
    try expectClean("const a: Foo = Foo.empty;\n", "prefer-decl-literal");
    try expectClean("const a: Foo = .make();\n", "prefer-decl-literal");
    // A reviewed exception.
    try expectClean("const a: Foo = Foo.make(); // lint:off prefer-decl-literal: the example\n", "prefer-decl-literal");
}

test "prefer-decl-literal's fix: the receiver goes and the rest stays, across lines and odd spacing; once is enough" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const alloc: Allocator = arena.allocator();
    // The annotation and the receiver differ only in whitespace: the same tokens, the same type.
    const src: []const u8 = "fn f(gpa: Allocator) !void {\n" ++
        "    const grid: Tensor( f64 ) = try Tensor(f64).fromSlice(\n" ++
        "        gpa,\n" ++
        "        &.{ 1, 2 },\n" ++
        "    );\n" ++
        "    _ = grid;\n" ++
        "}\n";
    const issues: []Issue = try issuesTagged(alloc, src, "prefer-decl-literal");
    try expect(issues.len == 1);
    const fixed: []u8 = try applyFix(alloc, src, issues[0].fix.?);
    try expect(indexOf(u8, fixed, "    const grid: Tensor( f64 ) = try .fromSlice(\n        gpa,\n") != null);
    // The fixed source parses without a single error, and the rule has nothing left to say about it.
    const fixed_terminated: [:0]u8 = try alloc.allocSentinel(u8, fixed.len, 0);
    @memcpy(fixed_terminated, fixed);
    var tree: Ast = try .parse(alloc, fixed_terminated, .{ .mode = .zig });
    defer tree.deinit(alloc);
    try expect(tree.errors.len == 0);
    try expectClean(fixed, "prefer-decl-literal");
}

// ---- --coverage ----------------------------------------------------------------------------------------------------

test "constructor-in-view: the short form where a declaration names the type - its branches included" {
    const source: []const u8 =
        \\const T = struct {
        \\    a: u32 = 0,
        \\    pub fn init(a: u32) T {
        \\        return .{ .a = a };
        \\    }
        \\    pub fn load() !T {
        \\        return .{};
        \\    }
        \\};
        \\fn pick(flag: bool, maybe: ?T) !T {
        \\    const typed: T = .init(1);
        \\    const split: T =
        \\        .init(2);
        \\    const loaded: T = try .load();
        \\    const fallback: T = maybe orelse .init(3);
        \\    const branched: T = if (flag) .init(4) else .init(5);
        \\    const chosen: T = switch (typed.a) {
        \\        1 => .init(6),
        \\        else => (.init(7)),
        \\    };
        \\    const pair: [2]T = .{ .init(8), .init(9) };
        \\    const Holder = struct { t: T = .init(10) };
        \\    _ = .{ split, loaded, fallback, branched, chosen, pair, Holder };
        \\    return typed;
        \\}
        \\
    ;
    try expectClean(source, "constructor-in-view");
}

test "constructor-in-view: everywhere else is reported - assignments, fields, arguments, returns" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const source: []const u8 =
        \\const T = struct {
        \\    a: u32 = 0,
        \\    pub fn init(a: u32) T {
        \\        return .{ .a = a };
        \\    }
        \\};
        \\const Holder = struct { t: T };
        \\fn take(t: T) u32 {
        \\    return t.a;
        \\}
        \\fn make() T {
        \\    return .init(1);
        \\}
        \\fn all(holder: *Holder) u32 {
        \\    holder.t = .init(2);
        \\    var local: T = make();
        \\    local = .init(3);
        \\    const inner: Holder = .{ .t = .init(4) };
        \\    _ = .{ local, inner };
        \\    return take(.init(5));
        \\}
        \\
    ;
    // The return, the member assignment, the local assignment, the field (its declaration names Holder, not T) and
    // the argument.
    const issues: []Issue = try issuesTagged(arena.allocator(), source, "constructor-in-view");
    try expect(issues.len == 5);
}

test "constructor-in-view: only the BARE words - `foo.bar = .initBozo(gpa)` carries its own name" {
    const source: []const u8 =
        \\const Bozo = struct {
        \\    pub fn initBozo(n: u32) Bozo {
        \\        _ = n;
        \\        return .{};
        \\    }
        \\};
        \\const Foo = struct { bar: Bozo };
        \\fn f(foo: *Foo) void {
        \\    foo.bar = .initBozo(1);
        \\}
        \\
    ;
    try expectClean(source, "constructor-in-view");
    try expect(isBareConstructorWord("init") and isBareConstructorWord("create") and isBareConstructorWord("from"));
    try expect(!isBareConstructorWord("initBozo") and !isBareConstructorWord("initCapacity"));
    try expect(!isBareConstructorWord("fromSlice") and !isBareConstructorWord("of"));
    try expect(!isBareConstructorWord("empty"));
}

test "useless-error-return leaves a function literal alone - `struct { fn f ... }.f` has its destination's type" {
    // A table whose every case must share `anyerror!void`: this case cannot fail, the field's type says it may.
    try expectClean("const Case = struct { run: *const fn () anyerror!void };\n" ++
        "const cases = [_]Case{.{ .run = struct {\n    fn f() anyerror!void {}\n}.f }};\n", "useless-error-return");
    // An ordinary function is still judged by its body.
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const ordinary: []Issue = try issuesTagged(arena.allocator(), "fn g() anyerror!void {}\n", "useless-error-return");
    try expect(ordinary.len == 1);
}

test "a tagged union's members are container members, not locals - untyped-local stays quiet on them" {
    // `isContainerDeclTag` once lacked the tagged unions, so a `union(enum)`'s members took the generic descent and
    // were linted as statements: `pub const TagEnum = ...` reported as an untyped LOCAL (entities.zig, Oct 2).
    try expectClean("pub const Subcmd = union(enum) {\n" ++
        "    a: u32,\n" ++
        "    pub const marker = {};\n" ++
        "    pub const TagEnum = @typeInfo(@This()).@\"union\".tag_type.?;\n" ++
        "};\n", "untyped-local");
}

test "coverage: the complete walk reaches every tracked node - even inside a struct returned by a function" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const alloc: Allocator = arena.allocator();
    const src: [:0]const u8 = "fn Series(comptime T: type) type {\n" ++
        "    return struct {\n" ++
        "        fn make(n: usize) usize {\n" ++
        "            const doubled: usize = n * 2;\n" ++
        "            return doubled;\n" ++
        "        }\n" ++
        "    };\n" ++
        "}\n" ++
        "fn plain(n: usize) usize {\n" ++
        "    const doubled: usize = n * 2;\n" ++
        "    return doubled;\n" ++
        "}\n";
    var ast: Ast = try .parse(alloc, src, .{ .mode = .zig });
    defer ast.deinit(alloc);
    const unwalked: []Index = try walkCoverage(alloc, "probe.zig", src, &ast);
    // The returned struct's method and its declaration were the old walk's blind spot; nothing is missed now.
    try expect(unwalked.len == 0);
}

// ---- fn-args-multiline and branch-braces: the autofixes ------------------------------------------------------------

/// What `--fix` leaves: `issues`' fixes applied back to front, then zig fmt's own rendering (std's `renderAlloc`, the
/// formatter `zig fmt` runs). The fixed source must parse - a fix that breaks parsing is never written.
fn fixedAndFormatted(alloc: Allocator, src: []const u8, issues: []const Issue) ![]u8 {
    const fixes: []Fix = try alloc.alloc(Fix, issues.len);
    for (fixes, issues) |*fix, issue| {
        fix.* = issue.fix.?;
    }
    sortSlice(Fix, fixes, {}, struct {
        fn later(_: void, a: Fix, b: Fix) bool {
            return a.start > b.start;
        }
    }.later);
    var fixed: []u8 = try alloc.dupe(u8, src);
    for (fixes) |fix| {
        fixed = try applyFix(alloc, fixed, fix);
    }
    const fixed_terminated: [:0]u8 = try alloc.allocSentinel(u8, fixed.len, 0);
    @memcpy(fixed_terminated, fixed);
    var tree: Ast = try .parse(alloc, fixed_terminated, .{ .mode = .zig });
    try expect(tree.errors.len == 0);
    return tree.renderAlloc(alloc);
}

test "fn-args-multiline's fix: one trailing comma - and zig fmt puts each parameter on its own line" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const alloc: Allocator = arena.allocator();
    const src: []const u8 = "fn f(a: u32, b: []const u8, c: bool, d: f32, e: *u8) void {\n" ++
        "    _ = .{ a, b, c, d, e };\n" ++
        "}\n";
    const issues: []Issue = try issuesTagged(alloc, src, "fn-args-multiline");
    try expect(issues.len == 1 and issues[0].fix != null);
    // The comma lands right before the closing parenthesis, nothing else changes.
    const fixed: []u8 = try applyFix(alloc, src, issues[0].fix.?);
    try expect(startsWith(u8, fixed, "fn f(a: u32, b: []const u8, c: bool, d: f32, e: *u8,) void {\n"));
    const formatted: []u8 = try fixedAndFormatted(alloc, src, issues);
    try expect(indexOf(u8, formatted, "fn f(\n    a: u32,\n    b: []const u8,\n    c: bool,\n") != null);
    try expectClean(formatted, "fn-args-multiline");
    // A trailing comma already there (fmt not yet run): still reported, nothing to insert - fmt alone is the fix.
    const comma_already: []const u8 = "fn g(a: u32, b: []const u8, c: bool, d: f32, e: *u8,) void {\n" ++
        "    _ = .{ a, b, c, d, e };\n" ++
        "}\n";
    const pending: []Issue = try issuesTagged(alloc, comma_already, "fn-args-multiline");
    try expect(pending.len == 1 and pending[0].fix == null);
}

test "branch-braces' fix: the body in a block, swallowing the statement's `;` but never an `else`" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const alloc: Allocator = arena.allocator();
    const src: []const u8 = "fn f(c: bool, x: u32) u32 {\n" ++
        "    if (c) return x;\n" ++
        "    var i: u32 = 0;\n" ++
        "    while (i < x) i += 1;\n" ++
        "    if (c) g() else h();\n" ++
        "    return i;\n" ++
        "}\n";
    const issues: []Issue = try issuesTagged(alloc, src, "branch-braces");
    try expect(issues.len == 4);
    // One at a time, each exactly: the `;` that ended the statement moves inside the block...
    const expected_lines = [_][]const u8{
        "    if (c) { return x; }\n",
        "    while (i < x) { i += 1; }\n",
        // ...while a then-body before `else` keeps the `else` where it was.
        "    if (c) { g(); } else h();\n",
        "    if (c) g() else { h(); }\n",
    };
    for (issues, expected_lines) |issue, expected_line| {
        try expect(issue.fix != null);
        const fixed: []u8 = try applyFix(alloc, src, issue.fix.?);
        try expect(indexOf(u8, fixed, expected_line) != null);
    }
    // All four together, then zig fmt: it parses, and the rule has nothing left to say.
    const formatted: []u8 = try fixedAndFormatted(alloc, src, issues);
    try expectClean(formatted, "branch-braces");
}

test "a binding below the use gets no rewrite - it would put the use before the declaration (both rules)" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const alloc: Allocator = arena.allocator();
    const zm_source: []const u8 = "const zm = @import(\"zm\");\n" ++
        "fn f(v: zm.Vec2) f32 {\n    return v[0];\n}\n" ++
        "const Vec2 = zm.Vec2;\n";
    const zm_issues: []Issue = try issuesTagged(alloc, zm_source, "no-qualified-zm");
    try expect(zm_issues.len == 1 and zm_issues[0].fix == null);
    try expect(indexOf(u8, zm_issues[0].message, "only below this use (line 5)") != null);
    const std_source: []const u8 = "const std = @import(\"std\");\n" ++
        "fn f(a: []const u8, b: []const u8) bool {\n    return std.mem.eql(u8, a, b);\n}\n" ++
        "const eql = std.mem.eql;\n";
    const std_issues: []Issue = try issuesTagged(alloc, std_source, "no-qualified-std");
    try expect(std_issues.len == 1 and std_issues[0].fix == null);
    try expect(indexOf(u8, std_issues[0].message, "only below this use (line 5)") != null);
}

test "a fixed file is written formatted: a trailing comma's parameters one per line, in the same write" {
    const gpa: Allocator = testing_allocator;
    // What a fix leaves - one comma - and what the renderer makes of it.
    const fixed_source: []const u8 = "fn open(a: u32, b: u32, c: u32,) void {\n    _ = a;\n    _ = b;\n    _ = c;\n}\n";
    const written: []u8 = try zigFormatted(gpa, fixed_source);
    defer gpa.free(written);
    const expected: []const u8 =
        \\fn open(
        \\    a: u32,
        \\    b: u32,
        \\    c: u32,
        \\) void {
        \\    _ = a;
        \\    _ = b;
        \\    _ = c;
        \\}
        \\
    ;
    try expectEqualStrings(expected, written);
    // A source that does not parse is kept as it is.
    const broken: []u8 = try zigFormatted(gpa, "fn (");
    defer gpa.free(broken);
    try expectEqualStrings("fn (", broken);
}

test "a fix run's report names each rule once, with its count, in the order the rules first fixed" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const alloc: Allocator = arena.allocator();
    var tally: FixTally = .{};
    try tally.add(alloc, "fn-args-multiline");
    try tally.add(alloc, "std-alias");
    try tally.add(alloc, "fn-args-multiline");
    var report: Io.Writer.Allocating = .init(alloc);
    try printFixTally(&report.writer, "fixed", "tools/x.zig", tally);
    try expectEqualStrings("zimrlint: fixed tools/x.zig: fn-args-multiline x2, std-alias x1\n", report.written());
}

test "applyFixesGuarded keeps each fix that leaves the file clean and refuses the one that would not" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const alloc: Allocator = arena.allocator();
    // Each insertion is fine alone; together they declare `b` twice - AstGen fails.
    const source: []const u8 = "const a: u32 = 1;\n";
    const end: u32 = @intCast(source.len);
    const fixes = [_]Fix{
        .{ .start = end, .end = end, .replacement = "const b: u32 = 2;\n", .tag = "first-binding" },
        .{ .start = end, .end = end, .replacement = "const b: u32 = a;\n", .tag = "second-binding" },
    };
    try expect(!compilesClean(alloc, try applyFixes(alloc, source, &fixes)));
    var tally: FixTally = .{};
    var refused: ArrayList(RefusedFix) = .empty;
    const guarded: GuardedOutcome = try applyFixesGuarded(alloc, source, &fixes, &tally, &refused);
    try expect(guarded.applied == 1 and guarded.refused == 1);
    // Only the applied fix is counted, under its rule; the refused one is remembered, for the next pass to leave out.
    try expect(tally.rule_counts.items.len == 1 and tally.rule_counts.items[0].count == 1);
    try expect(refused.items.len == 1);
    try expect(compilesClean(alloc, guarded.bytes));
}

test "collectFixes keeps ONE of each binding when two names' insertions at one spot interleave (A, B, A, B)" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const alloc: Allocator = arena.allocator();
    const first_binding: []const u8 = "const allocPrint = std.fmt.allocPrint;\n";
    const second_binding: []const u8 = "const expectEqual = std.testing.expectEqual;\n";
    var issues: [4]Issue = undefined;
    for (&issues, [_][]const u8{ second_binding, first_binding, second_binding, first_binding }) |*issue, line| {
        issue.* = .{
            .file = "a.zig",
            .line = 1,
            .col = 1,
            .tag = "no-qualified-std",
            .message = try alloc.dupe(u8, "qualified"),
            .rule = 0,
            .fix = .{ .start = 30, .end = 30, .replacement = try alloc.dupe(u8, line) },
        };
    }
    var fixes: ArrayList(Fix) = .empty;
    try collectFixes(alloc, &issues, &.{}, &fixes);
    try expect(fixes.items.len == 2);
    // Sorted by text at the one spot - the same on every run.
    try expect(eql(u8, fixes.items[0].replacement, first_binding));
    try expect(eql(u8, fixes.items[1].replacement, second_binding));
}

test "collectFixes leaves out a fix the guard refused, so the fix inside its span gets its turn" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const alloc: Allocator = arena.allocator();
    // A block wrapped around a body (branch-braces), and a `zm.` dropped inside that body (no-qualified-zm).
    const outer_text: []const u8 = try alloc.dupe(u8, "{ body }");
    const outer: Fix = .{ .start = 0, .end = 40, .replacement = outer_text, .tag = "branch-braces" };
    const inner: Fix = .{ .start = 12, .end = 15, .replacement = try alloc.dupe(u8, ""), .tag = "no-qualified-zm" };
    const issues = [_]Issue{
        .{
            .file = "a.zig",
            .line = 1,
            .col = 1,
            .tag = "branch-braces",
            .message = try alloc.dupe(u8, "if"),
            .rule = 3,
            .fix = outer,
        },
        .{
            .file = "a.zig",
            .line = 1,
            .col = 13,
            .tag = "no-qualified-zm",
            .message = try alloc.dupe(u8, "zm"),
            .rule = 0,
            .fix = inner,
        },
    };
    var fixes: ArrayList(Fix) = .empty;
    // First pass: the inner fix overlaps the outer one, and waits behind it.
    try collectFixes(alloc, &issues, &.{}, &fixes);
    try expect(fixes.items.len == 1 and fixes.items[0].start == 0);
    // The outer one refused: the next pass takes the inner one.
    const refused = [_]RefusedFix{.of(outer)};
    try collectFixes(alloc, &issues, &refused, &fixes);
    try expect(fixes.items.len == 1 and fixes.items[0].start == 12);
}

test "a fixable finding ends with the command that fixes it; the others do not; printIssues counts them" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const alloc: Allocator = arena.allocator();
    var issues = [_]Issue{
        .{
            .file = "a.zig",
            .line = 4,
            .col = 5,
            .tag = "untyped-local",
            .message = try alloc.dupe(u8, "local 'x' lacks a type annotation"),
            .rule = 2,
        },
        .{
            .file = "a.zig",
            .line = 2,
            .col = 5,
            .tag = "branch-braces",
            .message = try alloc.dupe(u8, "if body should be a block"),
            .rule = 3,
            .fix = .{ .start = 0, .end = 0, .replacement = try alloc.dupe(u8, "{") },
        },
    };
    var seen_tags: StringHashMap(void) = .init(alloc);
    var written: Io.Writer.Allocating = .init(alloc);
    const fixable: usize = try printIssues(&written.writer, &seen_tags, &issues, "autofix: zig build fix");
    try expect(fixable == 1);
    const text: []const u8 = written.written();
    const fixable_line: []const u8 = "a.zig:2:5: [branch-braces] if body should be a block (rule 3)" ++
        " - autofix: zig build fix\n";
    try expect(indexOf(u8, text, fixable_line) != null);
    try expect(indexOf(u8, text, "a.zig:4:1: [untyped-local]") == null);
    try expect(indexOf(u8, text, "a.zig:4:5: [untyped-local] local 'x' lacks a type annotation (rule 2)\n") != null);
}

test "no-qualified-std covers what prefer-std-alias did: `std.ArrayList` gets its binding, then its bare use" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const alloc: Allocator = arena.allocator();
    const src: []const u8 = "const std = @import(\"std\");\n" ++
        "fn f() void {\n" ++
        "    var list: std.ArrayList(u8) = .empty;\n" ++
        "    _ = &list;\n" ++
        "}\n";
    // Pass one: the binding is missing - the fix inserts it.
    const first: []Issue = try issuesTagged(alloc, src, "no-qualified-std");
    try expect(first.len == 1 and first[0].fix != null);
    const bound: []u8 = try applyFix(alloc, src, first[0].fix.?);
    try expect(indexOf(u8, bound, "const ArrayList = std.ArrayList;") != null);
    // Pass two: now bound - the fix rewrites the use, and nothing is left to say.
    const second: []Issue = try issuesTagged(alloc, bound, "no-qualified-std");
    try expect(second.len == 1 and second[0].fix != null);
    const rewritten: []u8 = try applyFix(alloc, bound, second[0].fix.?);
    try expect(indexOf(u8, rewritten, "    var list: ArrayList(u8) = .empty;\n") != null);
    try expectClean(rewritten, "no-qualified-std");
}

test "a rule in progress never fails a run - and no-qualified-std, finished, fails it like any rule" {
    // The mechanism, on a table of its own (no real rule is in progress once its tree has caught up).
    const notes = [_]RuleNote{
        .{ .tag = "house-rule", .title = "", .body = "", .work_in_progress = true },
        .{ .tag = "ordinary-rule", .title = "", .body = "" },
    };
    try expect(isWorkInProgressIn(&notes, "house-rule"));
    try expect(!isWorkInProgressIn(&notes, "ordinary-rule"));
    var no_message: [0]u8 = .{};
    const mixed = [_]Issue{
        .{ .file = "a.zig", .line = 1, .col = 1, .tag = "house-rule", .message = &no_message, .rule = 0 },
        .{ .file = "a.zig", .line = 2, .col = 1, .tag = "ordinary-rule", .message = &no_message, .rule = 0 },
    };
    try expect(failingCountIn(&notes, &mixed) == 1);
    // The real table: no-qualified-std now counts.
    try expect(!isWorkInProgressTag("no-qualified-std"));
    try expect(!isWorkInProgressTag("prefer-decl-literal"));
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const src: []const u8 = "const std = @import(\"std\");\n" ++
        "fn f(a: []const u8) bool {\n    return std.mem.eql(u8, a, \"x\");\n}\n";
    const reports: []Issue = try issuesTagged(arena.allocator(), src, "no-qualified-std");
    try expect(reports.len == 1);
    try expect(failingCount(reports) == 1);
}

test "no-qualified-std opens pointer, optional and array types - in fields too - and generic calls inside them" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const src: []const u8 = "const std = @import(\"std\");\nconst S = struct {\n    gpa: ?std.mem.Allocator,\n" ++
        "    list: *std.ArrayListUnmanaged(u8),\n    rows: []const std.Random,\n};\n";
    const issues: []Issue = try issuesTagged(arena.allocator(), src, "no-qualified-std");
    try expect(issues.len == 3);
    try expect(indexOf(u8, issues[0].message, "'std.mem.Allocator'") != null);
    try expect(indexOf(u8, issues[1].message, "'std.ArrayListUnmanaged'") != null);
    try expect(indexOf(u8, issues[2].message, "'std.Random'") != null);
}

// ---- --reorder-decls ----------------------------------------------------------------------------------------------

/// `reorderDecls` on `source`, expecting it to succeed with exactly `expected`.
fn expectReordered(source: []const u8, expected: []const u8) !void {
    const result: ReorderResult = try reorderDecls(testing_allocator, source);
    defer testing_allocator.free(result.source);
    try expect(result.refused == null);
    try expectEqualStrings(expected, result.source);
}

test "reorder-decls hoists a declaration above its first use, and moves nothing else" {
    try expectReordered(
        "const std = @import(\"std\");\n\nfn a() u32 {\n    return b();\n}\n\nfn b() u32 {\n    return 1;\n}\n",
        "const std = @import(\"std\");\n\nfn b() u32 {\n    return 1;\n}\n\nfn a() u32 {\n    return b();\n}\n",
    );
}

test "reorder-decls: a doc comment travels with its declaration; the //! header and a banner stay put" {
    try expectReordered(
        "//! header line\nconst std = @import(\"std\");\n\n// ===== Section =====\n\n" ++
            "fn a() u32 {\n    return b();\n}\n\n/// b's doc\nfn b() u32 {\n    return 1;\n}\n",
        "//! header line\nconst std = @import(\"std\");\n\n// ===== Section =====\n\n" ++
            "/// b's doc\nfn b() u32 {\n    return 1;\n}\n\nfn a() u32 {\n    return b();\n}\n",
    );
}

test "reorder-decls moves a multiline-string declaration with its `;`" {
    try expectReordered(
        "fn describe() []const u8 {\n    return text;\n}\n\nconst text =\n    \\\\hello\n    \\\\world\n;\n",
        "const text =\n    \\\\hello\n    \\\\world\n;\n\nfn describe() []const u8 {\n    return text;\n}\n",
    );
}

test "reorder-decls follows a chain: each hoisted declaration's own dependencies are hoisted in turn" {
    try expectReordered(
        "fn a() u32 {\n    return b();\n}\n\nfn b() u32 {\n    return c();\n}\n\nfn c() u32 {\n    return 1;\n}\n",
        "fn c() u32 {\n    return 1;\n}\n\nfn b() u32 {\n    return c();\n}\n\nfn a() u32 {\n    return b();\n}\n",
    );
}

test "reorder-decls refuses a cycle and changes nothing; an ordered file comes back byte for byte" {
    const cycle: []const u8 = "fn a(n: u32) u32 {\n    return if (n == 0) 0 else b(n - 1);\n}\n\n" ++
        "fn b(n: u32) u32 {\n    return if (n == 0) 1 else a(n - 1);\n}\n";
    const refused: ReorderResult = try reorderDecls(testing_allocator, cycle);
    defer testing_allocator.free(refused.source);
    try expect(refused.refused != null);
    try expect(eql(u8, cycle, refused.source));
    const ordered: []const u8 = "fn b() u32 {\n    return 1;\n}\n\nfn a() u32 {\n    return b();\n}\n";
    const unchanged: ReorderResult = try reorderDecls(testing_allocator, ordered);
    defer testing_allocator.free(unchanged.source);
    try expect(unchanged.refused == null and unchanged.moves == 0);
    try expect(eql(u8, ordered, unchanged.source));
}

/// The fix loop on `source` with every rule enabled, as `--fix` runs it; the result must be `expected`.
fn expectFixedTo(source: []const u8, expected: []const u8) !void {
    const args: Args = allRulesArgs();
    var outcome: FixOutcome = try runFixLoop(testing_allocator, "src/lint_fixture.zig", source, &args);
    defer outcome.tally.deinit(testing_allocator);
    defer testing_allocator.free(outcome.bytes);
    try expect(!outcome.refused_any);
    try expectEqualStrings(expected, outcome.bytes);
}

test "no-qualified-std --fix adds a missing binding, then rewrites the use (two passes of the loop)" {
    try expectFixedTo(
        "const std = @import(\"std\");\n\n" ++
            "pub fn f(a: []const u8) bool {\n    return std.mem.eql(u8, a, \"x\");\n}\n",
        "const std = @import(\"std\");\nconst eql = std.mem.eql;\n\n" ++
            "pub fn f(a: []const u8) bool {\n    return eql(u8, a, \"x\");\n}\n",
    );
}

test "no-qualified-std --fix: a header line using the name gets its binding above it" {
    try expectFixedTo(
        "const std = @import(\"std\");\npub const Writer = std.Io.Writer;\n\n" ++
            "pub fn f(w: *std.Io.Writer) void {\n    _ = w;\n}\n",
        "const std = @import(\"std\");\nconst Io = std.Io;\npub const Writer = Io.Writer;\n\n" ++
            "pub fn f(w: *Io.Writer) void {\n    _ = w;\n}\n",
    );
}

test "no-qualified-std --fix: three uses of one missing name make ONE binding" {
    try expectFixedTo(
        "const std = @import(\"std\");\nconst Allocator = std.mem.Allocator;\n\n" ++
            "pub fn f(a: []const u8, b: []const u8, c: []const u8) bool {\n" ++
            "    return std.mem.eql(u8, a, b) and std.mem.eql(u8, b, c) and std.mem.eql(u8, a, c);\n}\n" ++
            "pub fn g(gpa: Allocator) void {\n    _ = gpa;\n}\n",
        "const std = @import(\"std\");\nconst Allocator = std.mem.Allocator;\nconst eql = std.mem.eql;\n\n" ++
            "pub fn f(a: []const u8, b: []const u8, c: []const u8) bool {\n" ++
            "    return eql(u8, a, b) and eql(u8, b, c) and eql(u8, a, c);\n}\n" ++
            "pub fn g(gpa: Allocator) void {\n    _ = gpa;\n}\n",
    );
}

test "prefer-splat --fix in a file that binds no helper: `zm.splat`, then the binding, then the bare use" {
    try expectFixedTo(
        "const zm = @import(\"zm\");\nconst Vec = zm.Vec;\nconst Vec3 = zm.Vec3;\n\n" ++
            "pub fn f(v: Vec, s: f32) Vec {\n    return v * @as(Vec, @splat(s));\n}\n" ++
            "pub fn g(p: Vec3, s: f32) Vec3 {\n    return p * @as(Vec3, @splat(s));\n}\n",
        "const zm = @import(\"zm\");\nconst Vec = zm.Vec;\nconst Vec3 = zm.Vec3;\n" ++
            "const splat = zm.splat;\nconst splat3 = zm.splat3;\n\n" ++
            "pub fn f(v: Vec, s: f32) Vec {\n    return v * splat(s);\n}\n" ++
            "pub fn g(p: Vec3, s: f32) Vec3 {\n    return p * splat3(s);\n}\n",
    );
}

test "zig-fmt fires where `zig fmt` would change the file, at the first line that differs; its fix is that file" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const formatted: []const u8 = "pub fn f() u32 {\n    return 1;\n}\n";
    try expectClean(formatted, "zig-fmt");
    const unformatted: []const u8 = "pub fn f() u32 {\n  return 1;\n}\n";
    const issues: []Issue = try issuesTagged(arena.allocator(), unformatted, "zig-fmt");
    try expect(issues.len == 1);
    try expect(issues[0].line == 2);
    try expectEqualStrings(formatted, issues[0].fix.?.replacement);
    // A file that does not parse is parse-error's, not this rule's.
    try expectClean("pub fn f( {\n", "zig-fmt");
}

test "branch-braces --fix: a body that ends in a block of its own gets no `;` inside the new block" {
    // `if (c) for (xs) |x| { ... };` - robot_control.zig's shape, whose fix the guard refused before Oct 18.
    try expectFixedTo(
        "pub fn f(c: bool, xs: []const u32) u32 {\n    var total: u32 = 0;\n" ++
            "    if (c) for (xs) |x| {\n        total += x;\n    };\n    return total;\n}\n",
        "pub fn f(c: bool, xs: []const u32) u32 {\n    var total: u32 = 0;\n" ++
            "    if (c) { for (xs) |x| {\n        total += x;\n    } }\n    return total;\n}\n",
    );
}

test "zig-fmt's whole-file fix stays out of the fix loop, and does not hold back an unused declaration's deletion" {
    // Unformatted (a two-space indent) AND carrying an unused private constant: the loop deletes the constant and
    // leaves the layout alone - `--fix` formats once, after the loop (`main`).
    try expectFixedTo(
        "const unused: u32 = 1;\n\npub fn f() u32 {\n  return 2;\n}\n",
        "\npub fn f() u32 {\n  return 2;\n}\n",
    );
}

test "reorder-decls: a doc comment travels even across a blank line; a field's dependency goes above ALL fields" {
    // `///` attaches across a blank line in Zig's grammar - so it moves with its declaration.
    try expectReordered(
        "fn a() u32 {\n    return b();\n}\n\n/// b's doc\n\nfn b() u32 {\n    return 1;\n}\n",
        "/// b's doc\n\nfn b() u32 {\n    return 1;\n}\n\nfn a() u32 {\n    return b();\n}\n",
    );
    // A file with fields: `mode`'s type is declared below; it must land above the first field, not between.
    try expectReordered(
        "count: u32 = 0,\nmode: Mode = .idle,\n\nconst Mode = enum { idle, busy };\n",
        "const Mode = enum { idle, busy };\n\ncount: u32 = 0,\nmode: Mode = .idle,\n",
    );
}

test "reorder-decls honours decl-order's suppressions: an explained cycle and an exempt file are left alone" {
    // A cycle: `rotate` returns `Turn` before it is declared, and `Turn` calls `rotate`. With the forward
    // edge explained, the file is in order as far as the rule goes - so the tool neither refuses nor moves.
    const explained: []const u8 = "fn rotate(x: f32) Turn { // lint:off decl-order: Turn.of calls rotate - a cycle\n" ++
        "    return .{ .angle = x };\n}\n\nconst Turn = struct {\n    angle: f32,\n" ++
        "    fn of(x: f32) Turn {\n        return rotate(x);\n    }\n};\n";
    const cycle: ReorderResult = try reorderDecls(testing_allocator, explained);
    defer testing_allocator.free(cycle.source);
    try expect(cycle.refused == null and cycle.moves == 0);
    try expect(eql(u8, explained, cycle.source));
    // A file-level exemption: the tool changes nothing.
    const exempt: []const u8 = "//! lint:off decl-order: feature order\nfn a() u32 {\n    return b();\n}\n\n" ++
        "fn b() u32 {\n    return 1;\n}\n";
    const left: ReorderResult = try reorderDecls(testing_allocator, exempt);
    defer testing_allocator.free(left.source);
    try expect(left.refused == null and left.moves == 0);
    try expect(eql(u8, exempt, left.source));
}

test "reorder-decls: two declarations bound for one user move in one pass, in earliest-use order" {
    try expectReordered(
        "fn a() u32 {\n    return b() + c();\n}\n\nfn b() u32 {\n    return 1;\n}\n\nfn c() u32 {\n    return 2;\n}\n",
        "fn b() u32 {\n    return 1;\n}\n\nfn c() u32 {\n    return 2;\n}\n\nfn a() u32 {\n    return b() + c();\n}\n",
    );
}

test "decl-order: an enum's field names are not uses of the declarations they share a name with" {
    // `Way` names `mod` and `rem` above the functions `mod` and `rem`: names, not references.
    const enum_names: []const u8 = "const Way = enum { mod, rem };\n\n" ++
        "pub fn mod(a: u32, b: u32) u32 {\n    return a % b;\n}\n\n" ++
        "pub fn rem(a: u32, b: u32) u32 {\n    return a % b;\n}\n" ++
        "pub fn pick(way: Way) u32 {\n    return if (way == .mod) mod(7, 3) else rem(7, 3);\n}\n";
    try expectClean(enum_names, "decl-order");
    // A real use above the declaration still counts.
    try expectFires("pub fn f() u32 {\n    return g();\n}\n\nfn g() u32 {\n    return 1;\n}\n", "decl-order");
}

test "reorder-decls refuses to strand a section banner; keeps one whose section keeps code" {
    const bar: []const u8 = "// ========================================\n";
    // `b` would hoist above `a`, leaving the "Helpers" banner heading nothing: refused, unchanged.
    const strands: []const u8 = bar ++ "// Users\n" ++ bar ++ "\nfn a() u32 {\n    return b();\n}\n\n" ++
        bar ++ "// Helpers\n" ++ bar ++ "\nfn b() u32 {\n    return 1;\n}\n";
    const refused: ReorderResult = try reorderDecls(testing_allocator, strands);
    defer testing_allocator.free(refused.source);
    try expect(refused.refused != null);
    try expect(eql(u8, strands, refused.source));
    // The same hoist inside ONE section strands nothing: it goes ahead.
    const one_section: []const u8 = bar ++ "// Everything\n" ++ bar ++
        "\nfn a() u32 {\n    return b();\n}\n\nfn b() u32 {\n    return 1;\n}\n";
    const moved: ReorderResult = try reorderDecls(testing_allocator, one_section);
    defer testing_allocator.free(moved.source);
    try expect(moved.refused == null and moved.moves == 1);
}

test "arch-check: the processor asked in engine code fires; the host's fact does not" {
    try expectFires("const on_web: bool = @import(\"builtin\").target.cpu.arch.isWasm();\n", "arch-check");
    try expectFires("fn f(a: anytype) bool {\n    return a == .wasm32;\n}\n", "arch-check");
    try expectClean("const host = @import(\"host.zig\");\nconst on_web: bool = host.is_browser;\n", "arch-check");
}

test "browser-call: web.zig imported outside the browser's layer fires; inside it, it does not" {
    const source: []const u8 = "const dom = @import(\"web.zig\").dom;\n";
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    try expect(try ruleFiresAt(arena.allocator(), "src/lint_fixture.zig", source, "browser-call"));
    try expect(!try ruleFiresAt(arena.allocator(), "src/platform/web.zig", source, "browser-call"));
    // On Windows the build names the file with `\`.
    try expect(!try ruleFiresAt(arena.allocator(), ".\\src\\platform\\web.zig", source, "browser-call"));
    try expectClean("const platform = @import(\"platform.zig\");\n", "browser-call");
    try expectClean("pub const web = @import(\"platform/web.zig\");\n", "browser-call");
}

test "own-clock: a system clock outside the platform layer fires; inside it, it does not" {
    const source: []const u8 = "fn f(io: anytype) void {\n    _ = io.Timestamp.now(io, .real);\n}\n";
    try expectFires(source, "own-clock");
    try expectFires("fn f() void {\n    _ = QueryPerformanceCounter(null);\n}\n", "own-clock");
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    try expect(!try ruleFiresAt(arena.allocator(), "src/platform/windows.zig", source, "own-clock"));
    try expectClean("fn f(platform: anytype) u64 {\n    return platform.current.now();\n}\n", "own-clock");
}

test "process-exit: std.process.exit fires; returning an error does not" {
    try expectFires("fn f() void {\n    @import(\"std\").process.exit(1);\n}\n", "process-exit");
    try expectClean("fn f() !void {\n    return error.Failed;\n}\n", "process-exit");
}

test "screaming-const: a SCREAMING value fires at file scope, in a namespace and in a function; a type alias does not" {
    try expectFires("const MAX_ITEMS: usize = 4;\n", "screaming-const");
    try expectFires("const input = struct {\n    pub const MAX_GAMEPADS: usize = 4;\n};\n", "screaming-const");
    try expectFires("fn f() void {\n    const LIMIT = 3;\n    _ = LIMIT;\n}\n", "screaming-const");
    try expectClean("const V4 = @Vector(4, f32);\n", "screaming-const");
    try expectClean("const N: usize = 4;\n", "screaming-const");
    try expectClean("const F0: f32 = 0.04;\n", "screaming-const");
    try expectFires("const EPS: f32 = 0.000001;\n", "screaming-const");
    try expectClean("const H2 = struct {\n    x: f32,\n};\n", "screaming-const");
    try expectClean("const input = struct {\n    pub const max_gamepads: usize = 4;\n};\n", "screaming-const");
}
