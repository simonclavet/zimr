// tools/lint_zimr.zig - AST-based style linter for zimr.
// Encodes the mechanical rules from `src/notes/claude.md` as
// checks runnable per-file or on the whole codebase.  See
// `src/notes/lint-zimr-plan.md` for the v1 spec.
// Usage:
//   lint_zimr <file.zig> [<file2.zig> ...]
// Exits non-zero on any issue.  No flags, no levels — like zig,
// either you pass or you don't.

const std = @import("std");
const ArrayList = std.ArrayList;
const allocPrint = std.fmt.allocPrint;
const endsWith = std.mem.endsWith;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

/// A 78-character `=` divider for the rule-note headers.  Written as an
/// explicit literal (not `"=" ** 78`) per the linter's own retired-`**`
/// rule (rule 5).
const rule_divider: []const u8 = "==============================================================================";
const Index = Ast.Node.Index;

/// A mechanical source edit proposed by a rule and applied in `--fix` mode.
/// `start`/`end` are byte offsets into the file's source (`end` exclusive);
/// `replacement` is spliced in their place. A pure deletion uses `""`. Only
/// rules whose repair is unambiguous attach one; everything else leaves it
/// null and stays report-only.
const Fix = struct {
    start: u32,
    end: u32,
    replacement: []const u8 = "",
};

const Issue = struct {
    file: []const u8, // borrowed from arg list
    line: u32, // 1-based
    col: u32, // 1-based
    tag: []const u8, // static string
    message: []u8, // owned by issues arena
    rule: u8, // claude.md rule number, 0 for bonus checks
    fix: ?Fix = null, // present ⇒ `--fix` can repair this mechanically
};

/// File-level opt-out: a top-of-file `//! lint:off <tag>[,<tag2>] [: why]`
/// container doc-comment suppresses `tag` for the WHOLE file.  Use sparingly,
/// for files whose existing convention conflicts with a rule (e.g. codecs.zig's
/// per-struct `const testing = std.testing;` alias clashing with the file-scope
/// `prefer-std-alias` binding).  Tag-list syntax matches the per-line form.
fn fileSuppressedByDirective(source: [:0]const u8, tag: []const u8) bool {
    var lines: std.mem.SplitIterator(u8, .scalar) = std.mem.splitScalar(u8, source, '\n');
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
        var it: std.mem.SplitIterator(u8, .scalar) = std.mem.splitScalar(u8, text[p..rule_end], ',');
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
    const marker_idx: usize = std.mem.indexOf(u8, text, marker) orelse return false;

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

    // Parse the rule list — tokens separated by ',', terminated by ':' / ws.
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

    var it: std.mem.SplitIterator(u8, .scalar) = std.mem.splitScalar(u8, rules, ',');
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
///   - At least one rule name is required — bare `// lint:off` is
///     ignored so accidental blanket suppression can't happen.
///   - Justification after the optional `:` is for humans, not parsed.
fn lineSuppressedByDirective(
    source: [:0]const u8,
    line_idx: u32,
    tag: []const u8,
) bool {
    // `std-math` has NO opt-out: the only sanctioned fix is wrapping
    // the function in zimrmath (gated on !is_gpu, with a GPU branch).
    // A `// lint:off std-math` must NOT silence it.
    if (eql(u8, tag, "std-math")) {
        return false;
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
    /// Empty ⇒ the file doesn't import zm ⇒ the reserved-math rule is skipped
    /// entirely (decision 2b in RESERVED_MATH_PLAN.md).  Usually one entry
    /// (`zm`), occasionally `math`.  Points into `source`.
    zm_aliases: []const []const u8 = &.{},
    /// Whole-module std aliases found in this file (`const X = @import("std");`).
    /// Lets `std-math` catch `<alias>.math` (e.g. `std_mod.math.pi`), not just
    /// the literal `std.math`.  Points into `source`.
    std_aliases: []const []const u8 = &.{},

    /// Node indices (`true` = yes) of canonical `const X = zm.X;` binding
    /// inits.  `no-qualified-zm` skips these — that single `zm.X` is the legal
    /// home for the named import `X`.  Sized to `ast.nodes.len` by the per-file
    /// pre-pass; empty ⇒ nothing is treated as a binding init.  Points nowhere
    /// into `source` (it is a parallel bool array, freed after the file).
    canonical_zm_inits: []const bool = &.{},

    /// Whether the `prefer-vec` rule runs. GATING (default ON) now that the
    /// tree is fully migrated to `Vec`/`Vec2`/`Vec3`. `--no-prefer-vec` disables
    /// it (escape hatch); `--fix` autofixes `@Vector(N,f32)` wherever the alias
    /// is bound.
    prefer_vec: bool = true,

    /// Whether this file has a column-0 `const zm = @import("zm");` (or `pub`
    /// variant).  Only such files are subject to `no-qualified-zm`; a file
    /// whose sole zm import is per-struct/indented (runtime.zig's per-namespace
    /// imports) can't host a file-scope binding and is exempt — mirroring the
    /// P4 migration tool's own col-0 requirement.
    zm_col0: bool = false,

    /// Whether this file has a column-0 `const std = @import("std");` (or `pub`
    /// variant).  Like `zm_col0`: only such files are subject to
    /// `prefer-std-alias`, since a file whose std import is function-local
    /// can't host a file-scope alias binding.
    std_col0: bool = false,

    /// Whether the opt-in `decl-order` rule runs (set by `--decl-order`).
    check_decl_order: bool = false,

    /// Run ONLY the decl-order check, skipping every other rule (set by
    /// `--decl-order-only`). For fast iterative reordering of large files.
    decl_order_only: bool = false,

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
    /// every rule wants — it resolves the token's 1-based line/column
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
        try self.issues.append(self.alloc, .{
            .file = self.path,
            .line = line,
            .col = col,
            .tag = tag,
            .message = msg,
            .rule = rule,
            .fix = fix,
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
//   - `warned_*` flags       — one-shot per-process log warnings.
//                              `drawing.zig`'s `warned_text_no_font` is the
//                              canonical example.  Lifting these onto a
//                              context would re-fire per ctx, defeating
//                              the "warn once per process" intent.
//   - `zimr_app`             — the user-owned C-ABI bridge in every
//                              example.  The framework reaches it via
//                              `@import("root").zimr_app` at comptime.
//   - `*_fs.zig` / `*_vs.zig`— SPIR-V stage source files; `extern var
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
// The directive is general — it works for any rule, not just module-var.
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
// See `src/notes/lint-zimr-plan.md` § "Type-signal definition"
// for the full list.  In short:
//   - PascalCase identifier with ≥1 lowercase letter
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
// zimr "keywords" — the curated zm vocabulary that is part of the language.
// ============================================================================
// A keyword is a zm decl that (1) must be aliased at file scope (`const NAME =
// zm.NAME;`) and used bare — never written `zm.NAME` in a body (`no-qualified-zm`)
// — and (2) may NOT be the name of any other decl/local (`reserved-math-names`),
// so bare `dot`/`clamp`/`atan2` always means the zimrmath function and stays
// greppable. NON-keyword zm decls (matFromAxisAngle, quatFromEulerXYZ, the obscure
// helpers, and common-word decls like `float`/`angle`/`texture`) need NEITHER:
// they may be used qualified as `zm.X` without an alias. The list is hand-curated
// (NOT every zm decl — that would forbid common local names) and maintained here;
// every entry must be a real `pub` decl in zimrmath.zig.
const keywords = std.StaticStringMap(void).initComptime(.{
    // scalar functions
    .{ "abs", {} },          .{ "sqrt", {} },          .{ "sin", {} },            .{ "cos", {} },
    .{ "tan", {} },          .{ "asin", {} },          .{ "acos", {} },           .{ "atan", {} },
    .{ "atan2", {} },        .{ "sincos", {} },        .{ "exp", {} },            .{ "exp2", {} },
    .{ "exp10", {} },        .{ "pow", {} },           .{ "log2", {} },           .{ "log10", {} },
    .{ "floor", {} },        .{ "ceil", {} },          .{ "round", {} },          .{ "trunc", {} },
    .{ "fract", {} },        .{ "hypot", {} },         .{ "mulAdd", {} },         .{ "radFromDeg", {} },
    .{ "degFromRad", {} },
    // interpolation / range
      .{ "lerp", {} },          .{ "clamp", {} },          .{ "clamp01", {} },
    .{ "smoothstep", {} },   .{ "min", {} },           .{ "max", {} },
    // vector functions
               .{ "dot", {} },
    .{ "dot2", {} },         .{ "dot3", {} },          .{ "dot4", {} },           .{ "cross", {} },
    .{ "cross2", {} },       .{ "length", {} },        .{ "length2", {} },        .{ "length3", {} },
    .{ "length4", {} },      .{ "lengthSq2", {} },     .{ "lengthSq3", {} },      .{ "lengthSq4", {} },
    .{ "normalize", {} },    .{ "normalize2", {} },    .{ "normalize3", {} },     .{ "normalize4", {} },
    .{ "distance", {} },     .{ "distance2", {} },     .{ "distance3", {} },      .{ "distance4", {} },
    .{ "reflect2", {} },     .{ "reflect3", {} },      .{ "refract2", {} },       .{ "refract3", {} },
    .{ "project3", {} },     .{ "reject3", {} },       .{ "angle2", {} },         .{ "angle3", {} },
    // vector constructors
    .{ "vec2", {} },         .{ "vec3", {} },          .{ "vec4", {} },
    // constants
              .{ "pi", {} },
    .{ "tau", {} },          .{ "phi", {} },           .{ "nan", {} },            .{ "inf", {} },
    .{ "sqrt2", {} },        .{ "sqrt1_2", {} },       .{ "euler", {} },          .{ "log2e", {} },
    .{ "log10e", {} },       .{ "ln2", {} },           .{ "ln10", {} },           .{ "two_sqrtpi", {} },
    .{ "rad_per_deg", {} },  .{ "deg_per_rad", {} },
    // types (a zimr program means zm.Color/zm.Mat4/... by these names — never re-bind them)
      .{ "Aabb", {} },           .{ "Aabb2", {} },
    .{ "Boolx4", {} },       .{ "Boolx8", {} },        .{ "Boolx16", {} },        .{ "CameraProjection", {} },
    .{ "ColorU32", {} },     .{ "Complex", {} },       .{ "F32x4Component", {} }, .{ "F32x8", {} },
    .{ "F32x16", {} },       .{ "Mat", {} },           .{ "Mat2", {} },           .{ "Mat22", {} },
    .{ "Mat3", {} },         .{ "OrthoBasis3", {} },   .{ "Plane2", {} },         .{ "Quat", {} },
    .{ "RayCamera", {} },    .{ "RayCameraDesc", {} }, .{ "Rot2", {} },           .{ "Sweep2", {} },
    .{ "Transform2", {} },   .{ "Trs", {} },           .{ "Vec", {} },            .{ "Vec2i", {} },
    .{ "Vec3", {} },         .{ "Vec2", {} },          .{ "Color", {} },          .{ "Ray", {} },
    .{ "RayCollision", {} }, .{ "Transform", {} },     .{ "quat", {} },           .{ "Camera2D", {} },
    .{ "Camera3D", {} },
    // more functions (distinctive, no collisions)
        .{ "complex", {} },       .{ "determinant", {} },    .{ "f32x4", {} },
    .{ "f32x8", {} },        .{ "lerpV", {} },         .{ "mapLinear", {} },      .{ "modAngle", {} },
    .{ "mulMat", {} },       .{ "mulMatVec", {} },     .{ "niceNum", {} },        .{ "remap", {} },
    .{ "scaling", {} },      .{ "splat", {} },         .{ "swizzle", {} },        .{ "transpose", {} },
    .{ "vec", {} },
    // numeric conversions (int<->float helpers; never a local name)
             .{ "float", {} },         .{ "float64", {} },        .{ "int", {} },
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
// Suppressed under `--quiet`.  Per-tag, per-run (not per-file) — the
// `seen_tags` set lives in `main` across the whole file loop.

const RuleNote = struct {
    tag: []const u8,
    title: []const u8,
    body: []const u8,
};

const rule_notes = [_]RuleNote{
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
        .tag = "prefer-std-alias",
        .title = "prefer-std-alias - bind hot std.* names at file scope, use bare",
        .body =
        \\Frequently-used std members read better aliased once at file scope
        \\and used bare: `const ArrayList = std.ArrayList;` then `ArrayList(u8)`;
        \\`const expectEqual = std.testing.expectEqual;` then `expectEqual(...)`.
        \\Greppability + less line noise; the file-scope binding is the single
        \\home for the name (mirrors the zm convention).
        \\
        \\Enforced names: std.ArrayList, std.ArrayListAligned, std.fmt.bufPrint,
        \\std.fmt.allocPrint, and the std.testing.expect* family.  Only fires
        \\inside function/test bodies (the file-scope binding itself is fine)
        \\and only in files with a column-0 `const std = @import("std");` (a
        \\file whose std is function-local can't host the binding).  mem.eql /
        \\startsWith / endsWith and std.meta are deliberately NOT enforced -
        \\they collide with idiomatic method names (`fn eql`).
        \\
        \\Fix: add `const <name> = std.<path>.<name>;` near the top and use
        \\`<name>`.  If the bare name is already taken, keep the qualified
        \\form with `// lint:off prefer-std-alias: <why>`.
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
        \\GATING (the tree is fully migrated).  `--fix` rewrites the whole
        \\`@Vector(N, f32)` span to the alias (only the f32 widths 2/3/4 have
        \\aliases; other element types / widths keep the raw form).
        \\`--no-prefer-vec` disables the rule; `// lint:off prefer-vec: <why>`
        \\for a single deliberate raw use.
        ,
    },
    .{
        .tag = "anon-return",
        .title = "Survey rule - anonymous struct return types",
        .body =
        \\Functions returning `struct { ... }` directly are awkward at
        \\call sites: callers can't write `const x: ReturnType = ...`
        \\because identically-shaped anonymous structs are DISTINCT
        \\types in Zig.  Workarounds are `@TypeOf(call())` (verbose)
        \\or skipping the annotation (violates rule 2).  The fix is
        \\to name the type, e.g.
        \\  `pub const LogicalPoint = struct { x: f32, y: f32 };`
        \\  `pub fn cssToLogical(...) LogicalPoint { ... }`
        \\Defaults to OFF - opt in with `--only=anon-return` for the
        \\survey.  Whether to ban these via a hard rule is TBD; the
        \\survey output informs that decision.
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
};

fn lookupRuleNote(tag: []const u8) ?RuleNote {
    for (rule_notes) |note| {
        if (eql(u8, note.tag, tag)) {
            return note;
        }
    }
    return null;
}

/// PascalCase with ≥1 lowercase letter, OR single uppercase letter.
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
            const start: u32 = @intFromEnum(range.start);
            const end: u32 = @intFromEnum(range.end);
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
        // clamp-pattern, as-round, …) fire inside return expressions too.
        // `return;` (void) has no operand.  Was a blind spot: `std-math`
        // missed `return std.math.clamp(...)` in image.zig.
        .@"return" => {
            if (data.opt_node.unwrap()) |operand| {
                buf[0] = operand;
                return buf[0..1];
            }
            return buf[0..0];
        },
        else => return buf[0..0],
    }
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
            // `@import("foo")` / `@cImport({...})` yield a `type` value —
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
// not apply — a `:type` annotation on `const Vec2 = zm.Vec2;` would be noise.
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
        // Transparent unary wrappers — descend.
        .@"try", .@"comptime", .@"nosuspend" => {
            const inner: Index = ast.nodeData(node).node;
            try walkInitForNamedStruct(ctx, inner);
        },
        // Binary branchers — both arms could carry the value.
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
        // Skip the `_dot_` variants — those are already anonymous.
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
            // byte before `{`) and replace with `.` — correct for qualified
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

/// True when `init_node` is exactly `<alias>.<name>` for one of the file's zm
/// aliases and `<name>` equals the decl name — i.e. the canonical import
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
    // Binding-less `@import("zm").NAME` — the only file-scope alias form
    // available to files that cannot introduce a `zm` const because a
    // fn-local `const zm = @import("zm");` would illegally shadow it
    // (e.g. runtime.zig imports zm per-namespace).
    return isZmImportCall(ast, lhs);
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
    // ceili) spells the target type twice — the `: T` annotation already drives
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
    // struct-literal check — a literal `.{...}` forces every field to be set (or
    // defaulted / explicitly `= undefined`), but starting from whole-struct
    // `undefined` and filling piecemeal leaves any forgotten field as garbage.
    // Require the State to be born from a `.{...}` literal instead. Scoped to
    // example files, where `State` is the AppSpec state type (other modules have
    // their own unrelated `State` structs that legitimately use `= undefined`).
    if (std.mem.indexOf(u8, ctx.path, "examples/") != null and
        vd.ast.type_node != .none and isStateTypedVar(ast, vd))
    {
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
fn isAcceptableBranchBody(ast: *const Ast, body: Index) bool {
    return switch (ast.nodeTag(body)) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => true,
        // Switch body has its own braces - breakpoint-friendly.
        .@"switch", .switch_comma => true,
        else => false,
    };
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
                const kw: []const u8 = ast.tokenSlice(main_tok);
                try ctx.emitAt(main_tok, "branch-braces", 3, "{s} body should be a block", .{kw});
            }
        },
        .@"if" => {
            const f: Ast.full.If = ast.fullIf(node).?;
            if (!isAcceptableBranchBody(ast, f.ast.then_expr)) {
                try ctx.emitAt(ast.nodeMainToken(node), "branch-braces", 3, "if-then body should be a block", .{});
            }
            if (f.ast.else_expr.unwrap()) |e| {
                // Chain `else if` is fine - that's an idiomatic
                // pattern, not a no-brace branch.
                const etag: Ast.Node.Tag = ast.nodeTag(e);
                if (etag != .if_simple and etag != .@"if" and !isAcceptableBranchBody(ast, e)) {
                    try ctx.emitAt(ast.nodeMainToken(e), "branch-braces", 3, "else body should be a block", .{});
                }
            }
        },
        .@"while" => {
            const w: Ast.full.While = ast.fullWhile(node).?;
            if (!isAcceptableBranchBody(ast, w.ast.then_expr)) {
                try ctx.emitAt(ast.nodeMainToken(node), "branch-braces", 3, "while body should be a block", .{});
            }
        },
        .@"for" => {
            const f: Ast.full.For = ast.fullFor(node).?;
            if (!isAcceptableBranchBody(ast, f.ast.then_expr)) {
                try ctx.emitAt(ast.nodeMainToken(node), "branch-braces", 3, "for body should be a block", .{});
            }
        },
        else => {},
    }
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
    // → `std_mod.math.pi`).  Aliasing the import must not evade the ban.
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
///     the GPU memory layout (a UBO/vertex `vec4<f32>`) — pre-marked in
///     `ctx.extern_field_vecs`.
/// Autofix: splice the alias name over the whole `@Vector(N, f32)` span. The
/// alias resolves through `zm` in any file that does vector math (which, by the
/// reserved-math rule, is every file using these types); a file that somehow
/// lacks the binding gets a report to add it.
fn checkPreferVec(ctx: Ctx, node: Index, tag: Ast.Node.Tag) !void {
    if (!ctx.prefer_vec) {
        return;
    }
    if (tag != .builtin_call_two and tag != .builtin_call_two_comma) {
        return;
    }
    const ast: *const Ast = ctx.ast;
    // zimrmath.zig defines Vec/Vec2/Vec3 themselves — leave those alone.
    if (endsWith(u8, ctx.path, "zimrmath.zig")) {
        return;
    }
    if (!eql(u8, ast.tokenSlice(ast.nodeMainToken(node)), "@Vector")) {
        return;
    }
    // (Vec works in extern/packed fields too — proven: it transpiles to the
    // same `vec4<f32>` std140 layout — so those are NOT exempt.)
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

/// True when the file has a file-scope `const <name> = <zmAlias>.<name>;` binding
/// — the canonical home for `name`. When present, an inline `zm.<name>` in a body
/// can be safely rewritten to bare `<name>` (it already resolves to this binding,
/// no collision), which is what the `no-qualified-zm` autofix does.
fn fileScopeBindsZm(
    ast: *const Ast,
    zm_aliases: []const []const u8,
    name: []const u8,
) bool {
    for (ast.rootDecls()) |decl| {
        const vd: Ast.full.VarDecl = ast.fullVarDecl(decl) orelse continue;
        const decl_name: []const u8 = ast.tokenSlice(vd.ast.mut_token + 1);
        if (!eql(u8, decl_name, name)) {
            continue;
        }
        const init: Index = vd.ast.init_node.unwrap() orelse continue;
        if (ast.nodeTag(init) != .field_access) {
            continue;
        }
        const d: Ast.Node.Data = ast.nodeData(init);
        const lhs: Index = d.node_and_token[0];
        const ftok: u32 = d.node_and_token[1];
        if (ast.nodeTag(lhs) != .identifier) {
            continue;
        }
        const obj: []const u8 = ast.tokenSlice(ast.nodeMainToken(lhs));
        const fld: []const u8 = ast.tokenSlice(ftok);
        if (!eql(u8, fld, name)) {
            continue;
        }
        for (zm_aliases) |a| {
            if (eql(u8, obj, a)) {
                return true;
            }
        }
    }
    return false;
}

/// `no-qualified-zm` (R2): every `zm.X` member access in a zm-importing file
/// must go through a file-scope named import (`const X = zm.X;`), never inline
/// in a body.  The canonical binding init is the one allowed `zm.X` (pre-marked
/// in `ctx.canonical_zm_inits`).  Files that don't import zm are exempt
/// (`zm_aliases` empty — e.g. zimrmath itself).  Mirrors checkDebugPrint: fires
/// on a `field_access` whose object identifier is a zm alias, at the field
/// token.  A blocked name (a local/param/fn already owns `X`) or runtime.zig's
/// per-struct zm opts out with `// lint:off no-qualified-zm: <reason>`.
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
    const idx: usize = @intFromEnum(node);
    if (idx < ctx.canonical_zm_inits.len and ctx.canonical_zm_inits[idx]) {
        return;
    }
    const ast: *const Ast = ctx.ast;
    const data: Ast.Node.Data = ast.nodeData(node);
    const lhs: Index = data.node_and_token[0];
    const field_tok: u32 = data.node_and_token[1];
    if (ast.nodeTag(lhs) != .identifier) {
        return;
    }
    const obj: []const u8 = ast.tokenSlice(ast.nodeMainToken(lhs));
    var is_zm: bool = false;
    for (ctx.zm_aliases) |a| {
        if (eql(u8, obj, a)) {
            is_zm = true;
        }
    }
    if (!is_zm) {
        return;
    }
    const field: []const u8 = ast.tokenSlice(field_tok);
    // Only KEYWORDS need aliasing. A non-keyword zm decl (matFromAxisAngle, the
    // obscure helpers) may be used qualified as `zm.X` without a file-scope alias.
    if (!keywords.has(field)) {
        return;
    }
    // Autofix half-1: if `const <field> = zm.<field>;` already exists at file
    // scope, the inline use can be rewritten to bare `<field>` simply by deleting
    // the `zm.` prefix (the field token already resolves to that binding — safe,
    // no collision). When the binding is absent we only report: adding it is the
    // riskier half (needs a free-name check) and is left to the developer.
    if (fileScopeBindsZm(ast, ctx.zm_aliases, field)) {
        const del_start: u32 = @intCast(ast.tokenStart(ast.firstToken(node)));
        const del_end: u32 = @intCast(ast.tokenStart(field_tok));
        try ctx.emitFix(
            field_tok,
            "no-qualified-zm",
            0,
            .{ .start = del_start, .end = del_end, .replacement = "" },
            "qualified 'zm.{s}' in a body - bind it once at file scope as " ++
                "`const {s} = zm.{s};` then use `{s}`, or rename the decl that " ++
                "shadows it (`// lint:off no-qualified-zm: <why>` for a real one)",
            .{ field, field, field, field },
        );
        return;
    }
    try ctx.emitAt(
        field_tok,
        "no-qualified-zm",
        0,
        "qualified 'zm.{s}' in a body - bind it once at file scope as " ++
            "`const {s} = zm.{s};` then use `{s}`, or rename the decl that " ++
            "shadows it (`// lint:off no-qualified-zm: <why>` for a real one)",
        .{ field, field, field, field },
    );
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
    // @max(L, @min(V, H)) → suggest std.math.clamp(V, L, H)
    // @min(H, @max(L, V)) → suggest std.math.clamp(V, L, H)
    // Precision: skip when L or H is itself a builtin call (the
    // outer @max/@min then can't be a clamp — see ray-AABB t-near
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
        => true,
        else => false,
    };
}

/// True when `path` lives under a `src/` directory (the engine code that
/// ships in every app's wasm).  Handles absolute (`...\Zimr\src\foo.zig`)
/// and relative (`src/foo.zig`) forms on both path separators.
fn inSrcDir(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "/src/") != null or
        std.mem.indexOf(u8, path, "\\src\\") != null or
        startsWith(u8, path, "src/") or
        startsWith(u8, path, "src\\");
}

/// `debug-print` - bans `std.debug.print` in engine code (`src/`).
///
/// std.debug.print bypasses `std_options` and writes to the raw stderr
/// writer, whose wasm path traps under ReleaseSmall - a SILENT freeze in
/// a release standalone (a real bug: a UI font-misconfig diagnostic took
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
    return std.mem.indexOf(u8, path, "/examples/") != null or
        std.mem.indexOf(u8, path, "\\examples\\") != null or
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

/// True when `obj` names std: the literal `std` or a whole-module
/// `@import("std")` alias collected for this file.
fn isStdRoot(ctx: Ctx, obj: []const u8) bool {
    if (eql(u8, obj, "std")) {
        return true;
    }
    for (ctx.std_aliases) |a| {
        if (eql(u8, obj, a)) {
            return true;
        }
    }
    return false;
}

/// `prefer-std-alias` - in a function/test body, a hot std.* member should be
/// bound once at file scope and used bare.  Enforced names: std.ArrayList,
/// std.ArrayListAligned, std.fmt.bufPrint, std.fmt.allocPrint, and the
/// std.testing.expect* family.  mem.eql/startsWith/endsWith and std.meta are
/// intentionally NOT enforced (they collide with idiomatic method names like
/// `fn eql`).  Skipped at container scope (fn_depth 0 - that's the binding
/// itself) and in files without a col-0 std import (can't host the binding).
/// Detection mirrors checkDebugPrint: a `field_access` rooted at `std` (or a
/// whole-module std alias), one segment (`std.ArrayList`) or two
/// (`std.fmt.bufPrint`, `std.testing.expect*`).
fn checkPreferStdAlias(
    ctx: Ctx,
    node: Index,
    tag: Ast.Node.Tag,
    fn_depth: u8,
) !void {
    if (tag != .field_access) {
        return;
    }
    if (fn_depth == 0) {
        return;
    }
    if (!ctx.std_col0) {
        return;
    }
    const ast: *const Ast = ctx.ast;
    const data: Ast.Node.Data = ast.nodeData(node);
    const lhs: Index = data.node_and_token[0];
    const field_tok: u32 = data.node_and_token[1];
    const field: []const u8 = ast.tokenSlice(field_tok);

    const lhs_tag: Ast.Node.Tag = ast.nodeTag(lhs);
    var matched: bool = false;
    if (lhs_tag == .identifier) {
        // 1-segment: <std>.<field>  (std.ArrayList, std.ArrayListAligned)
        if (isStdRoot(ctx, ast.tokenSlice(ast.nodeMainToken(lhs)))) {
            if (eql(u8, field, "ArrayList") or eql(u8, field, "ArrayListAligned")) {
                matched = true;
            }
        }
    } else if (lhs_tag == .field_access) {
        // 2-segment: <std>.<mid>.<field>  (std.testing.expect*, std.fmt.bufPrint)
        const ld: Ast.Node.Data = ast.nodeData(lhs);
        const ll: Index = ld.node_and_token[0];
        const mid_tok: u32 = ld.node_and_token[1];
        if (ast.nodeTag(ll) == .identifier and
            isStdRoot(ctx, ast.tokenSlice(ast.nodeMainToken(ll))))
        {
            const mid: []const u8 = ast.tokenSlice(mid_tok);
            if (eql(u8, mid, "testing") and startsWith(u8, field, "expect")) {
                matched = true;
            } else if (eql(u8, mid, "fmt") and
                (eql(u8, field, "bufPrint") or eql(u8, field, "allocPrint")))
            {
                matched = true;
            }
        }
    }
    if (!matched) {
        return;
    }
    try ctx.emitAt(
        field_tok,
        "prefer-std-alias",
        0,
        "qualified std '{s}' in a body - bind it once at file scope as " ++
            "`const {s} = std.<path>.{s};` then use `{s}` (if the bare name " ++
            "is taken: `// lint:off prefer-std-alias: <why>`)",
        .{ field, field, field, field },
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
/// int→float cast form: the `@as(T, ...)` wrapper only exists to give
/// `@floatFromInt` a result type, which `zm.float(x)` (→f32) / `zm.float64(x)`
/// (→f64) supply on their own.  Flags them and AUTOFIXES to the helper call
/// (the fix rewrites the whole `@as(...)` node; the file still needs a
/// `const float = zm.float;` / `const float64 = zm.float64;` alias in scope).
/// Bare `@floatFromInt(x)` in an inferred context is left alone — without an
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

    // Whole `@as(...)` node byte span → replaced wholesale by `helper(x_src)`.
    const as_last: u32 = ast.lastToken(node);
    const as_start: u32 = @intCast(ast.tokenStart(ast.firstToken(node)));
    const as_end: u32 = @intCast(ast.tokenStart(as_last) + ast.tokenSlice(as_last).len);

    const x_last: u32 = ast.lastToken(x);
    const x_start: usize = ast.tokenStart(ast.firstToken(x));
    const x_end: usize = ast.tokenStart(x_last) + ast.tokenSlice(x_last).len;
    const x_src: []const u8 = ctx.source[x_start..x_end];

    const replacement: []const u8 = try allocPrint(ctx.alloc, "{s}({s})", .{ helper, x_src });

    try ctx.emitFix(
        ast.nodeMainToken(node),
        "float-from-int",
        0,
        .{ .start = as_start, .end = as_end, .replacement = replacement },
        "@as({s}, @floatFromInt(x)) is redundant - use zm.{s}(x)",
        .{ ty_slice, helper },
    );
}

/// Byte length of the source line containing `byte_offset`, newline excluded —
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
/// rationale doesn't apply — `fn vec(x: f32, y: f32, z: f32)`
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

    // (5) full signature line ≤ 80 cols.  The signature is
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
            // friends are stable mathematical shapes — diff-ability
            // rationale doesn't apply.  See
            // `isSimpleUniformPrimitiveSig` for the exact criteria.
            if (isSimpleUniformPrimitiveSig(ctx, proto, params.items)) {
                return;
            }
            try ctx.emitAt(
                main_tok,
                "fn-args-multiline",
                1,
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
    const tag: Ast.Node.Tag = ast.nodeTag(container);
    var buf: [2]Index = undefined;
    const members: []const Index = switch (tag) {
        .container_decl, .container_decl_trailing => blk: {
            const range: Ast.Node.SubRange = ast.nodeData(container).extra_range;
            break :blk ast.extraDataSlice(range, Index);
        },
        .container_decl_two, .container_decl_two_trailing => blk: {
            const a, const b = ast.nodeData(container).opt_node_and_opt_node;
            var n: usize = 0;
            if (a.unwrap()) |x| {
                buf[n] = x;
                n += 1;
            }
            if (b.unwrap()) |x| {
                buf[n] = x;
                n += 1;
            }
            break :blk buf[0..n];
        },
        else => return,
    };
    for (members) |m| {
        try walkNode(ctx, m, .container, fn_depth);
    }
}

/// Run type-level checks on a type-expression node and everything reachable
/// from it. The main walk skips fn-proto param/return type nodes (it descends
/// into bodies, not signatures), so type rules like `prefer-vec` need this to
/// reach `fn f(v: @Vector(4, f32))` and `fn f() @Vector(4, f32)`.
fn walkTypeExpr(ctx: Ctx, node: Index) anyerror!void {
    const ast: *const Ast = ctx.ast;
    const tag: Ast.Node.Tag = ast.nodeTag(node);
    try checkPreferVec(ctx, node, tag);
    var buf: [8]Index = undefined;
    for (childNodes(ast, node, &buf)) |child| {
        try walkTypeExpr(ctx, child);
    }
}

/// Walk one node, run every per-node check, then recurse into
/// children.  `pos` says whether we're at container or
/// statement scope; `fn_depth` says how many fn/test bodies we're
/// nested inside (0 means module scope, ≥1 means inside a fn).
fn walkNode(
    ctx: Ctx,
    node: Index,
    pos: Pos,
    fn_depth: u8,
) anyerror!void {
    const ast: *const Ast = ctx.ast;
    const tag: Ast.Node.Tag = ast.nodeTag(node);

    // Per-node checks.
    if (ast.fullVarDecl(node)) |vd| {
        try checkVarDecl(ctx, vd, pos, fn_depth);
        // The generic descent visits the init expression but not the explicit
        // type annotation (`const uv: @Vector(2, f32) = ...`), so type rules
        // like prefer-vec would miss it. Walk it explicitly.
        if (vd.ast.type_node.unwrap()) |tn| {
            try walkTypeExpr(ctx, tn);
        }
    }
    // Struct/union field types (`field: @Vector(4, f32)`) aren't visited by the
    // generic descent either — reach them so prefer-vec covers UBO/vertex
    // schema fields (`Vec` transpiles to the same `vec4<f32>` there).
    if (ast.fullContainerField(node)) |cf| {
        if (cf.ast.type_expr.unwrap()) |tn| {
            try walkTypeExpr(ctx, tn);
        }
    }
    if (pos == .statement) {
        try checkBranchBraces(ctx, node, tag);
    }
    try checkStdMath(ctx, node, tag);
    try checkDebugPrint(ctx, node, tag);
    try checkNoQualifiedZm(ctx, node, tag);
    try checkPreferVec(ctx, node, tag);
    try checkStdDebugAssert(ctx, node, tag);
    try checkPreferStdAlias(ctx, node, tag, fn_depth);
    try checkImportAtTop(ctx, node, tag, fn_depth);
    try checkClampPattern(ctx, node, tag);
    try checkAsRound(ctx, node, tag);
    try checkIntFromFloat(ctx, node, tag);
    try checkFloatFromInt(ctx, node, tag);
    try checkBannedConversion(ctx, node, tag);
    try checkFnArgsMultiline(ctx, node, tag);
    try checkAnonReturn(ctx, node, tag);

    // Recurse.  fn_decl / test_decl bump fn_depth and walk the
    // body as statements.  Most other branching constructs
    // preserve pos (we're either in statements or in
    // expressions; that doesn't change by descending into a
    // condition or body).
    switch (tag) {
        .fn_decl => {
            // The walker reaches `.fn_decl` but never descends into
            // the fn_proto child (which holds params + return type).
            // Run proto-targeted checks explicitly so they actually
            // fire on top-level fns.  Without this, fn-args-multiline
            // and anon-return silently do nothing for `pub fn foo(...)`
            // declarations - bug discovered turn 348.
            const proto_n, const body = ast.nodeData(node).node_and_node;
            const proto_tag: Ast.Node.Tag = ast.nodeTag(proto_n);
            try checkFnArgsMultiline(ctx, proto_n, proto_tag);
            try checkAnonReturn(ctx, proto_n, proto_tag);
            // Rule reserved-math-names: a fn named like an R_core word
            // (e.g. a local `fn lerp`) shadows zm.* - flag it.
            var name_buf: [1]Index = undefined;
            if (ast.fullFnProto(&name_buf, node)) |proto| {
                if (proto.name_token) |nt| {
                    try checkReservedMath(ctx, nt, null);
                }
                // The walk descends into fn BODIES but not the proto's type
                // expressions, so type-level rules (prefer-vec) would miss
                // param and return types. Visit them explicitly.
                var it: Ast.full.FnProto.Iterator = proto.iterate(ast);
                while (it.next()) |param| {
                    if (param.type_expr) |te| {
                        try walkTypeExpr(ctx, te);
                    }
                }
                if (proto.ast.return_type.unwrap()) |rt| {
                    try walkTypeExpr(ctx, rt);
                }
            }
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
            _, const then_e = ast.nodeData(node).node_and_node;
            try walkNode(ctx, then_e, pos, fn_depth);
        },
        .@"if" => {
            const if_full: Ast.full.If = ast.fullIf(node).?;
            try walkNode(ctx, if_full.ast.then_expr, pos, fn_depth);
            if (if_full.ast.else_expr.unwrap()) |e| {
                try walkNode(ctx, e, pos, fn_depth);
            }
        },
        .while_simple => {
            _, const body = ast.nodeData(node).node_and_node;
            try walkNode(ctx, body, pos, fn_depth);
        },
        .@"while" => {
            const w: Ast.full.While = ast.fullWhile(node).?;
            try walkNode(ctx, w.ast.then_expr, pos, fn_depth);
            if (w.ast.else_expr.unwrap()) |e| {
                try walkNode(ctx, e, pos, fn_depth);
            }
        },
        .for_simple => {
            _, const body = ast.nodeData(node).node_and_node;
            try walkNode(ctx, body, pos, fn_depth);
        },
        .@"for" => {
            const f: Ast.full.For = ast.fullFor(node).?;
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
                if (vd.ast.init_node.unwrap()) |init_n| {
                    const init_tag: Ast.Node.Tag = ast.nodeTag(init_n);
                    if (isContainerDeclTag(init_tag)) {
                        try walkContainerChildren(ctx, init_n, fn_depth);
                    } else {
                        try walkNode(ctx, init_n, .expression, fn_depth);
                    }
                }
            } else {
                var buf: [8]Index = undefined;
                const children: []const Index = childNodes(ast, node, &buf);
                for (children) |c| {
                    try walkNode(ctx, c, .expression, fn_depth);
                }
            }
        },
    }
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
            if (test_depth <= 0 and std.mem.indexOfScalar(u8, line, '}') != null) {
                in_test = false;
            }
            continue;
        }
        const code: []const u8 = if (std.mem.indexOf(u8, line, "//")) |ci| line[0..ci] else line;
        for (banned) |b| {
            if (std.mem.indexOf(u8, code, b.pat) != null) {
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
fn runUnusedPrivateGlobals(ctx: Ctx) !void {
    const ast: *const Ast = ctx.ast;
    const tags: []const std.zig.Token.Tag = ast.tokens.items(.tag);
    for (ast.rootDecls()) |decl| {
        const vd: Ast.full.VarDecl = ast.fullVarDecl(decl) orelse continue;
        if (vd.visib_token != null) {
            continue;
        }
        const name_tok: u32 = vd.ast.mut_token + 1;
        const name: []const u8 = ast.tokenSlice(name_tok);
        var refs: u32 = 0;
        var i: usize = 0;
        while (i < tags.len) : (i += 1) {
            if (tags[i] != .identifier) {
                continue;
            }
            if (i > 0 and tags[i - 1] == .period) {
                continue;
            }
            if (eql(u8, ast.tokenSlice(@intCast(i)), name)) {
                refs += 1;
            }
        }
        if (refs <= 1) {
            const fix: Fix = unusedGlobalFix(ast, decl);
            try ctx.emitFix(name_tok, "unused-global", 0, fix, "unused private global '{s}'", .{name});
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
/// body calls B) IS flagged on purpose — that is the "weird recursion" that has
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
        const fn_node: Index = @enumFromInt(fi);
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
            const cnode: Index = @enumFromInt(ci);
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

fn runDeclOrder(ctx: Ctx) !void {
    const ast: *const Ast = ctx.ast;
    var decls: std.StringHashMap(DeclSite) = std.StringHashMap(DeclSite).init(ctx.alloc);
    defer decls.deinit();

    // 1) Catalogue every file-scope declaration by name. First one wins
    //    (file-scope names are unique; a duplicate would be a compile error).
    for (ast.rootDecls()) |node| {
        const name_tok: u32 = declNameToken(ast, node) orelse continue;
        const name: []const u8 = ast.tokenSlice(name_tok);
        const gop: std.StringHashMap(DeclSite).GetOrPutResult = try decls.getOrPut(name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .first_token = ast.firstToken(node), .name_token = name_tok };
        }
    }

    // 2) One pass over every identifier node. If it names a file-scope decl and
    //    sits before that decl's first token, it is a forward reference; keep
    //    the earliest one per decl.
    var i: usize = 0;
    while (i < ast.nodes.len) : (i += 1) {
        const node: Index = @enumFromInt(i);
        if (ast.nodeTag(node) != .identifier) {
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
    var it: std.StringHashMap(DeclSite).Iterator = decls.iterator();
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
/// Skips comment lines.  Doesn't try to parse — the pattern is
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
    if (std.mem.indexOf(u8, line, "@atan2(") orelse
        std.mem.indexOf(u8, line, "@atan(")) |idx|
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
/// — i.e. `<io_name>.<method>(...)`.  Namespace calls such as
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
    // are valid in helpers and branches — and are the ONLY kind of sample legal
    // in a vertex shader. Mirror the bare-`sampleLevel` exemption below: match
    // only the implicit-LOD accessor `io.<name>(uv)`, never `io.<name>Level(...)`.
    const method_tok: u32 = ast.nodeData(fn_expr).node_and_token[1];
    const method: []const u8 = ast.tokenSlice(method_tok);
    if (endsWith(u8, method, "Level")) {
        return false;
    }
    return true;
}

/// True if `node` is a call to an IMPLICIT-LOD sampler helper by NAME —
/// `zsample2d(...)`, `zm.zsample2d(...)`, `sampleLod(...)`, or `zm.sampleLod(...)`.
/// These lower to `textureSample`, which WGSL/Tint permit only in UNIFORM
/// control flow, so they must be caught outside shaderMain's uniform top.
/// `sampleLevel(...)` takes an EXPLICIT LOD (no derivatives) and lowers to
/// `textureSampleLevel`, which is valid in ANY control flow — it is the escape
/// hatch for sampling in a helper/branch, so it is intentionally NOT matched.
fn isBareSamplerCall(ctx: Ctx, node: Index) bool {
    const ast: *const Ast = ctx.ast;
    const fn_expr: Index = switch (ast.nodeTag(node)) {
        .call, .call_comma => ast.nodeData(node).node_and_extra[0],
        .call_one, .call_one_comma => ast.nodeData(node).node_and_opt_node[0],
        else => return false,
    };
    // Resolve the callee's trailing name: either a bare identifier `zsample2d`
    // or a field access `zm.zsample2d`.
    const name_tok: u32 = switch (ast.nodeTag(fn_expr)) {
        .identifier => ast.nodeMainToken(fn_expr),
        .field_access => ast.nodeData(fn_expr).node_and_token[1],
        else => return false,
    };
    const name: []const u8 = ast.tokenSlice(name_tok);
    return eql(u8, name, "zsample2d") or eql(u8, name, "sampleLod");
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
/// allowed only in the straight-line *prologue* — the run of statements
/// before the first control-flow construct, where every invocation is
/// still in lockstep (= uniform).  After any if/loop/switch, later
/// statements (even unconditional ones) may be reached non-uniformly, so
/// a sample there is flagged.  This is a sound over-approximation of
/// WGSL's uniformity rule: it never permits a real violation, and the
/// fix it asks for (sample at the very top) is always available.  A
/// possible false positive (a sample that is in fact uniform after a
/// uniform branch) is acceptable — false negatives, which would let the
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
            // Direct `@SpirvType` shader (billboard/skybox/points/decal …): the
            // exported `entry` fn has no Io param, so the IoT path skips it. It
            // can still call `zsample2d(...)` — which must sit at uniform control
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

/// Flag file-scope value consts named in SCREAMING_CASE. Zig idiom: value consts are
/// snake_case, types are PascalCase — an all-uppercase name is the C-macro style we don't
/// use here. Suppress a genuine exception with `// lint:off screaming-const: <reason>`.
fn runScreamingConsts(ctx: Ctx) !void {
    const ast: *const Ast = ctx.ast;
    for (ast.rootDecls()) |decl| {
        const vd: Ast.full.VarDecl = ast.fullVarDecl(decl) orelse continue;
        const name_tok: u32 = vd.ast.mut_token + 1;
        const name: []const u8 = ast.tokenSlice(name_tok);
        if (isScreaming(name)) {
            try ctx.emitAt(name_tok, "screaming-const", 0, "SCREAMING_CASE global '{s}' - use snake_case", .{name});
        }
    }
}

fn runChecks(ctx: Ctx) !void {
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
    // Two checks operate on the whole file in one go rather than
    // node-by-node, so they live outside the walk.
    try runLineLength(ctx);
    try runShaderChecks(ctx);
    try runShaderSafeChecks(ctx);
    try runSamplerDiscipline(ctx);
    try runUnusedPrivateGlobals(ctx);
    try runScreamingConsts(ctx);
    try checkScopeBalance(ctx);
    if (ctx.check_decl_order) {
        try runDeclOrder(ctx);
    }
}

/// Files scheduled for deletion: the doomed GL backend, plus the top-level GL example
/// programs that are being ported to `examples/wgpu_*/` or dropped as redundant. The linter
/// skips these entirely — there's no point enforcing style on code about to be removed.
/// Shader sources (`_fs.zig`/`_vs.zig`) are NOT skipped: they are live and the shader rules
/// still apply to them.
fn isSkipped(path: []const u8) bool {
    // GL-retirement P5 (t1176): the doomed-file lists are gone — the files
    // are deleted.  One data-file exception remains: quad_glb_data.zig
    // is an embedded-GLB byte array a wgpu example imports for its asset,
    // not style-relevant code.
    return endsWith(u8, path, "examples" ++ std.fs.path.sep_str ++ "quad_glb_data.zig");
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
// facilities, no extern declarations, no wasm-bridge imports — outside
// `test` blocks (host tests are fine; they never enter the pipeline).
// ===========================================================================

// ===========================================================================
// Sampler-at-top discipline (shader files).
//
// WGSL forbids calling an implicit-LOD sampler (`textureSample`) from
// non-uniform control flow.  The robust, checkable rule: every texture
// sample must be taken at the unconditional top of `shaderMain` and its
// value threaded down — never inside an `if`/loop, and never inside a
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
    var it: std.mem.SplitIterator(u8, .scalar) = std.mem.splitScalar(u8, source, '\n');
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
        const eq: usize = std.mem.indexOf(u8, after, needle) orelse continue;
        // Whole-module only: the char after `@import("zm")` must end the init
        // (`;`), not continue into a field access (`.Vec`).
        const tail: []const u8 = after[eq + needle.len ..];
        if (tail.len == 0 or tail[0] != ';') {
            continue;
        }
        const ident: []const u8 = std.mem.trim(u8, after[0..eq], " \t");
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
    var it: std.mem.SplitIterator(u8, .scalar) = std.mem.splitScalar(u8, source, '\n');
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
/// or `pub const std = @import("std")`.  Drives `prefer-std-alias`'s scope: a
/// file whose only std import is function-local (e.g. zimr.zig's logFn) can't
/// host a file-scope alias and is exempt.  Mirrors `hasCol0ZmImport`.
fn hasCol0StdImport(source: []const u8) bool {
    var it: std.mem.SplitIterator(u8, .scalar) = std.mem.splitScalar(u8, source, '\n');
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

/// Pre-pass for `no-qualified-zm`: set `out[node] = true` for every canonical
/// `const X = zm.X;` binding-init field-access node, so the rule can skip that
/// one allowed `zm.X`.  `out` is sized to `ast.nodes.len`.  One O(nodes) pass.
fn markCanonicalZmInits(ast: *const Ast, aliases: []const []const u8, out: []bool) void {
    var i: usize = 0;
    while (i < ast.nodes.len) : (i += 1) {
        const node: Index = @enumFromInt(i);
        const vd: Ast.full.VarDecl = ast.fullVarDecl(node) orelse continue;
        const init_n: Index = vd.ast.init_node.unwrap() orelse continue;
        if (ast.nodeTag(init_n) != .field_access) {
            continue;
        }
        const name: []const u8 = ast.tokenSlice(vd.ast.mut_token + 1);
        const data: Ast.Node.Data = ast.nodeData(init_n);
        const lhs: Index = data.node_and_token[0];
        const field_tok: u32 = data.node_and_token[1];
        if (!eql(u8, ast.tokenSlice(field_tok), name)) {
            continue;
        }
        if (ast.nodeTag(lhs) != .identifier) {
            continue;
        }
        const obj: []const u8 = ast.tokenSlice(ast.nodeMainToken(lhs));
        for (aliases) |a| {
            if (eql(u8, obj, a)) {
                out[@intFromEnum(init_n)] = true;
            }
        }
    }
}

// True if `node` is a call to one of the float->int rounding builtins
// (@trunc / @floor / @round / @ceil).  Each takes one arg, so they parse as
// builtin_call_two with a single populated slot.

// If `node` is a call to a zimrmath float->int cast helper — `zm.int`,
// `zm.floori`, `zm.roundi`, `zm.ceili` (or the bare names inside zimrmath
// itself) — return the helper name; else null.  Used to spot a helper whose
// explicit target type is already pinned by an enclosing typed decl.

// Ban @as(T, @trunc(x)) and friends.  The rounding builtins convert straight
// to an integer once the result type is known, so the @as wrapper is never
// right: drop it (`@trunc(x)`) when T is inferable, or use the zm.int / floori
// / roundi / ceili helper when T must be spelled.  Purely syntactic — an @as
// whose VALUE argument (the second one) is a rounding builtin call.

// Ban @intFromFloat outright.  In current Zig the rounding builtins
// `@trunc`/`@floor`/`@round`/`@ceil` perform the float->int conversion
// directly when the result type is an integer (e.g. `const i: i32 =
// @trunc(x);`), so `@intFromFloat(@trunc(x))` is redundant — just write
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
    if (endsWith(u8, path, "gpu_iface.zig") or endsWith(u8, path, "wgpu.zig") or
        endsWith(u8, path, "lint_zimr.zig"))
    {
        // gpu_iface.zig owns the caches, wgpu.zig defines the raw primitives,
        // and lint_zimr.zig holds these patterns as rule data / documentation.
        return;
    }
    const needles = [_][]const u8{ "render_pass.setPipeline(", "render_pass.setBindGroup(" };
    var line: u32 = 1;
    var it: std.mem.SplitIterator(u8, .scalar) = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| : (line += 1) {
        const trimmed: []const u8 = std.mem.trimStart(u8, raw, " \t");
        if (startsWith(u8, trimmed, "//") or startsWith(u8, trimmed, "\\\\")) {
            continue; // comment / doc line or multiline-string literal line
        }
        for (needles) |needle| {
            const at: usize = std.mem.indexOf(u8, raw, needle) orelse continue;
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
// FFI seam detection.
// ============================================================================

// ============================================================================
// Driver.
// ============================================================================

const Args = struct {
    files: ArrayList([]const u8),
    /// `--decl-order` opts in to the (migration-stage) decl-order rule. It is
    /// OFF by default so the standing lint gate stays green while files are
    /// reorganised into declare-before-use order incrementally.
    decl_order: bool = false,
    /// `--decl-order-only` runs ONLY the decl-order check (implies decl_order).
    decl_order_only: bool = false,
    /// `--fix` applies the mechanical autofixes in place (mirrors `zig fmt`'s
    /// write mode). Off by default so the gate stays a pure check.
    fix: bool = false,
    /// `--check` is an explicit alias of the default (report-only); accepted for
    /// `zig fmt --check` muscle memory.
    check: bool = false,
    /// `--dry-run` (with `--fix`) reports what would change but writes nothing.
    dry_run: bool = false,
    /// prefer-vec gates by default; `--no-prefer-vec` turns it off (see Ctx).
    prefer_vec: bool = true,

    fn deinit(self: *Args, alloc: Allocator) void {
        self.files.deinit(alloc);
    }
};

// ============================================================================
// Per-file mtime cache (turn 382).
// ============================================================================
// Files are linted in one batch but we don't want to re-process clean
// files on every invocation.  For each file passed in, we maintain a
// stamp at `tools/.zig-cache/lint-stamps/<hash>.stamp` containing the
// source file's mtime AND the lint binary's mtime at the moment we
// last produced 0 issues for that file.
//
// If both mtimes match on the next run, the file is skipped.  Editing
// any file re-lints just that file.  Rebuilding the linter (binary
// mtime changes) invalidates every stamp.  Result: warm `zig build
// lint-check` after a single-file edit drops from ~2.4s to ~0.X s.
// See turn 382 notes.

const stamp_dir_path = "tools/.zig-cache/lint-stamps";

const Stamp = extern struct {
    source_mtime_ns: i128,
    binary_mtime_ns: i128,
};

fn stampPathFor(arena: Allocator, source_path: []const u8) ![]const u8 {
    // Hash the path so source files at deep paths still map to a flat
    // stamp filename.  Wyhash is plenty for collision avoidance
    // among ~150 files.
    const hash: u64 = std.hash.Wyhash.hash(0, source_path);
    return allocPrint(arena, stamp_dir_path ++ "/{x:0>16}.stamp", .{hash});
}

fn loadStamp(
    io: std.Io,
    alloc: Allocator,
    sp: []const u8,
) ?Stamp {
    const bytes: []u8 = std.Io.Dir.cwd().readFileAlloc(io, sp, alloc, .unlimited) catch return null;
    defer alloc.free(bytes);
    if (bytes.len != @sizeOf(Stamp)) {
        return null;
    }
    var stamp: Stamp = undefined;
    @memcpy(std.mem.asBytes(&stamp), bytes);
    return stamp;
}

fn writeStamp(
    io: std.Io,
    sp: []const u8,
    stamp: Stamp,
) void {
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = sp,
        .data = std.mem.asBytes(&stamp),
    }) catch {};
}

fn parseArgs(alloc: Allocator, argv: []const [:0]const u8) !Args {
    var a: Args = .{
        .files = .empty,
    };
    var i: usize = 1; // skip program name
    while (i < argv.len) : (i += 1) {
        if (eql(u8, argv[i], "--decl-order")) {
            a.decl_order = true;
            continue;
        }
        if (eql(u8, argv[i], "--decl-order-only")) {
            a.decl_order = true;
            a.decl_order_only = true;
            continue;
        }
        if (eql(u8, argv[i], "--fix")) {
            a.fix = true;
            continue;
        }
        if (eql(u8, argv[i], "--check")) {
            a.check = true;
            continue;
        }
        if (eql(u8, argv[i], "--dry-run")) {
            a.dry_run = true;
            continue;
        }
        if (eql(u8, argv[i], "--prefer-vec")) {
            a.prefer_vec = true; // back-compat no-op (now default on)
            continue;
        }
        if (eql(u8, argv[i], "--no-prefer-vec")) {
            a.prefer_vec = false;
            continue;
        }
        try a.files.append(alloc, argv[i]);
    }
    return a;
}

/// Parse + run all checks on one in-memory source buffer, appending issues.
/// Returns whether the file had parse errors (AST checks are skipped if so).
/// Mirrors the per-file body of `main` so the check path and the fix loop share
/// exactly one analysis routine.
fn analyzeSource(
    gpa: Allocator,
    path: []const u8,
    source_z: [:0]u8,
    args: *const Args,
    issues: *ArrayList(Issue),
) !bool {
    try scanArrayMult(gpa, path, source_z[0..source_z.len], issues);
    try scanRawPassBind(gpa, path, source_z, issues);
    var ast: std.zig.Ast = try std.zig.Ast.parse(gpa, source_z, .{ .mode = .zig });
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
    const ctx: Ctx = .{
        .alloc = gpa,
        .path = path,
        .source = source_z,
        .ast = &ast,
        .issues = issues,
        .zm_aliases = zm_alias_buf[0..zm_alias_n],
        .std_aliases = std_alias_buf[0..std_alias_n],
        .canonical_zm_inits = canon_inits,
        .prefer_vec = args.prefer_vec,
        .zm_col0 = hasCol0ZmImport(source_z),
        .std_col0 = hasCol0StdImport(source_z),
        .check_decl_order = args.decl_order,
        .decl_order_only = args.decl_order_only,
    };
    try runChecks(ctx);
    return false;
}

/// True when `bytes` clears both parse AND AstGen (ZIR lowering), i.e. it gets at
/// least as far as a real build's front-end. The fix loop's guard uses this to
/// catch SEMANTIC breakage a parse-only check misses — an undeclared identifier
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
            continue; // defensive: overlap survived filtering — skip
        }
        try out.appendSlice(gpa, source[cursor..fx.start]);
        try out.appendSlice(gpa, fx.replacement);
        cursor = fx.end;
    }
    try out.appendSlice(gpa, source[cursor..]);
    return out.toOwnedSlice(gpa);
}

/// Gather the `Fix`es carried by `issues` into `out`, sorted ascending by start
/// with overlapping edits dropped (deferred to a later pass).
fn collectFixes(gpa: Allocator, issues: []const Issue, out: *ArrayList(Fix)) !void {
    out.clearRetainingCapacity();
    for (issues) |is| {
        if (is.fix) |fx| {
            try out.append(gpa, fx);
        }
    }
    std.mem.sort(Fix, out.items, {}, struct {
        fn lt(_: void, a: Fix, b: Fix) bool {
            return a.start < b.start;
        }
    }.lt);
    var w: usize = 0;
    var running_end: u32 = 0;
    for (out.items) |fx| {
        if (w == 0 or fx.start >= running_end) {
            out.items[w] = fx;
            w += 1;
            running_end = fx.end;
        }
    }
    out.items.len = w;
}

/// Outcome of fixing one file: the final source (owned), how many edits landed,
/// and whether a pass was rolled back by the parse guard.
const FixOutcome = struct {
    bytes: []u8,
    edits_applied: usize,
    rolled_back: bool,
};

/// Iteratively analyze → collect fixes → splice, until no more fixes (or 5
/// passes). The loop is what lets a cascade settle: removing decl A in pass 1
/// can make decl B unused, caught in pass 2. Each pass re-parses the spliced
/// result and rolls back if it parses worse than its input.
fn runFixLoop(gpa: Allocator, path: []const u8, original: []const u8, args: *const Args) !FixOutcome {
    var cur: []u8 = try gpa.dupe(u8, original);
    var total_edits: usize = 0;
    var rolled_back: bool = false;
    var pass: usize = 0;
    while (pass < 5) : (pass += 1) {
        const cur_z: [:0]u8 = try gpa.allocSentinel(u8, cur.len, 0);
        @memcpy(cur_z, cur);
        var issues: ArrayList(Issue) = .empty;
        defer {
            for (issues.items) |is| {
                gpa.free(is.message);
            }
            issues.deinit(gpa);
        }
        _ = analyzeSource(gpa, path, cur_z, args, &issues) catch {};
        gpa.free(cur_z);

        var fixes: ArrayList(Fix) = .empty;
        defer fixes.deinit(gpa);
        try collectFixes(gpa, issues.items, &fixes);
        if (fixes.items.len == 0) {
            break;
        }
        const before_ok: bool = compilesClean(gpa, cur);
        const next: []u8 = try applyFixes(gpa, cur, fixes.items);
        const after_ok: bool = compilesClean(gpa, next);
        if (before_ok and !after_ok) {
            gpa.free(next); // guard: a clean file just went broken — discard the pass
            rolled_back = true;
            break;
        }
        gpa.free(cur);
        cur = next;
        total_edits += fixes.items.len;
    }
    return .{ .bytes = cur, .edits_applied = total_edits, .rolled_back = rolled_back };
}

/// Sort + print a file's issues (with first-hit rule notes), shared by the
/// check path and the fix path's residual report.
fn printIssues(
    stdout: *std.Io.Writer,
    seen_tags: *std.StringHashMap(void),
    issues: []Issue,
) !void {
    std.mem.sort(Issue, issues, {}, struct {
        fn lt(_: void, a: Issue, b: Issue) bool {
            if (a.line != b.line) {
                return a.line < b.line;
            }
            return a.col < b.col;
        }
    }.lt);
    for (issues) |is| {
        if (!seen_tags.contains(is.tag)) {
            try seen_tags.put(is.tag, {});
            if (lookupRuleNote(is.tag)) |note| {
                try stdout.print("\n", .{});
                try stdout.writeAll(rule_divider);
                try stdout.print("\n{s}\n", .{note.title});
                try stdout.writeAll(rule_divider);
                try stdout.print("\n{s}\n\n", .{note.body});
            }
        }
        try stdout.print("{s}:{d}:{d}: [{s}] {s}", .{
            is.file, is.line, is.col, is.tag, is.message,
        });
        if (is.rule > 0) {
            try stdout.print(" (rule {d})\n", .{is.rule});
        } else {
            try stdout.writeAll("\n");
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa: Allocator = init.gpa;
    const arena: Allocator = init.arena.allocator();
    const io: std.Io = init.io;

    const argv: []const [:0]const u8 = try init.minimal.args.toSlice(arena);

    var args: Args = try parseArgs(gpa, argv);
    defer args.deinit(gpa);

    if (args.files.items.len == 0) {
        std.debug.print("usage: lint_zimr <file.zig> [<file2.zig> ...]\n", .{});
        return;
    }

    // ---- Per-file mtime cache setup --------------------------------
    // Stamps live under tools/.zig-cache/lint-stamps/ so they survive
    // `rm -rf .zig-cache` in the project root.  --no-cache or --fix
    // disable lookups (but --no-cache still writes fresh stamps).
    std.Io.Dir.cwd().createDirPath(io, stamp_dir_path) catch {};
    const binary_mtime_ns: i128 = blk: {
        const stat: std.Io.Dir.Stat = std.Io.Dir.cwd().statFile(io, argv[0], .{}) catch break :blk 0;
        break :blk stat.mtime.nanoseconds;
    };

    var total_issues: usize = 0;
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout: *std.Io.Writer = &stdout_writer.interface;

    // First-hit tag tracker - drives the detailed rule-note printing
    // (turn 344).  Lives across all files: we want each rule's "why"
    // to appear once per `lint-check` invocation, not once per file.
    var seen_tags: std.StringHashMap(void) = .init(gpa);
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
                const stat: std.Io.Dir.Stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch break :blk 0;
                break :blk stat.mtime.nanoseconds;
            };
            const fix_stamp_path: []const u8 = try stampPathFor(arena, path);
            if (!args.dry_run) {
                if (loadStamp(io, gpa, fix_stamp_path)) |stamp| {
                    if (stamp.source_mtime_ns == fix_mtime_ns and stamp.binary_mtime_ns == binary_mtime_ns) {
                        continue;
                    }
                }
            }

            const source_bytes: []u8 = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |e| {
                std.debug.print("error reading {s}: {s}\n", .{ path, @errorName(e) });
                continue;
            };
            defer gpa.free(source_bytes);

            const outcome: FixOutcome = try runFixLoop(gpa, path, source_bytes, &args);
            defer gpa.free(outcome.bytes);

            if (outcome.rolled_back) {
                try stdout.print("{s}: skipped a fix that would break parsing (parse guard)\n", .{path});
            }
            if (outcome.edits_applied > 0) {
                if (args.dry_run) {
                    try stdout.print("would fix {d} in {s}\n", .{ outcome.edits_applied, path });
                } else {
                    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = outcome.bytes }) catch |e| {
                        std.debug.print("error writing {s}: {s}\n", .{ path, @errorName(e) });
                        continue;
                    };
                    try stdout.print("fixed {d} in {s}\n", .{ outcome.edits_applied, path });
                }
            }

            // Residual report: re-analyze the (fixed) bytes so anything the
            // autofixer can't handle still surfaces and still fails CI.
            const final_z: [:0]u8 = try gpa.allocSentinel(u8, outcome.bytes.len, 0);
            @memcpy(final_z, outcome.bytes);
            defer gpa.free(final_z);
            var fix_issues: ArrayList(Issue) = .empty;
            defer {
                for (fix_issues.items) |is| {
                    gpa.free(is.message);
                }
                fix_issues.deinit(gpa);
            }
            _ = try analyzeSource(gpa, path, final_z, &args, &fix_issues);
            try printIssues(stdout, &seen_tags, fix_issues.items);
            total_issues += fix_issues.items.len;

            // Stamp clean when the file is fully resolved (no residual, no
            // rollback, real write). Re-stat after a write so the stamp records
            // the post-fix mtime; an untouched clean file keeps `fix_mtime_ns`.
            if (!args.dry_run and !outcome.rolled_back and fix_issues.items.len == 0) {
                const stamp_mtime_ns: i128 = if (outcome.edits_applied == 0) fix_mtime_ns else blk: {
                    const stat: std.Io.Dir.Stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch break :blk 0;
                    break :blk stat.mtime.nanoseconds;
                };
                if (stamp_mtime_ns != 0) {
                    writeStamp(io, fix_stamp_path, .{
                        .source_mtime_ns = stamp_mtime_ns,
                        .binary_mtime_ns = binary_mtime_ns,
                    });
                }
            }
            continue;
        }

        // ---- Check mode (default) ----
        // Cache lookup: if source mtime + binary mtime match the stamp, skip.
        const source_mtime_ns: i128 = blk: {
            const stat: std.Io.Dir.Stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch break :blk 0;
            break :blk stat.mtime.nanoseconds;
        };
        const stamp_sub_path: []const u8 = try stampPathFor(arena, path);
        if (loadStamp(io, gpa, stamp_sub_path)) |stamp| {
            if (stamp.source_mtime_ns == source_mtime_ns and stamp.binary_mtime_ns == binary_mtime_ns) {
                continue;
            }
        }

        const source_bytes: []u8 = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |e| {
            std.debug.print("error reading {s}: {s}\n", .{ path, @errorName(e) });
            continue;
        };
        defer gpa.free(source_bytes);
        const source_z: [:0]u8 = try gpa.allocSentinel(u8, source_bytes.len, 0);
        @memcpy(source_z, source_bytes);
        defer gpa.free(source_z);

        var issues: ArrayList(Issue) = .empty;
        defer {
            for (issues.items) |is| {
                gpa.free(is.message);
            }
            issues.deinit(gpa);
        }

        const has_parse_errors: bool = try analyzeSource(gpa, path, source_z, &args, &issues);
        try printIssues(stdout, &seen_tags, issues.items);
        total_issues += issues.items.len;

        // Cache write: stamp only when clean (never on parse errors — we want a
        // re-check next run).
        if (issues.items.len == 0 and !has_parse_errors) {
            writeStamp(io, stamp_sub_path, .{
                .source_mtime_ns = source_mtime_ns,
                .binary_mtime_ns = binary_mtime_ns,
            });
        }
    }

    if (total_issues > 0) {
        try stdout.print(
            "\n{d} issues in {d} files\n",
            .{ total_issues, args.files.items.len },
        );
    }
    try stdout.flush();

    // Hard gate (turn 379, after all rules cleared).  Non-zero exit
    // means `zig build lint` and `zig build lint-check` fail on any
    // issue.  Before this turn lint_zimr always returned 0; the
    // cleanup arc through turn 378 cleared every existing hit, so
    // we can now enforce.
    if (total_issues > 0) {
        std.process.exit(1);
    }
}
// (cache-bust: force fresh lint-tool compile after a corrupt cached SIGILL binary)
