# lint-zimr-plan.md — AST-based style linter (drafted turn 337)

Encoding the mechanical rules from `claude.md` as a Zig program.
Runnable per-file (editor integration) or whole-codebase (build
step).

---

## Architecture

- Single Zig binary at `tools/zimrlint.zig`.  New `tools/` dir,
  distinct from `scripts/` (Python utilities).
- One `std.zig.Ast.parse` per file; all checks dispatched in a
  single walk.
- Build step: `zig build lint` (default scan: `src/` +
  `examples/`) or `zig build lint -- <files>`.
- Standalone: `zig run tools/zimrlint.zig -- <files>`.

---

## v1 checks (10 total)

| Tag | Rule | What it catches |
| --- | --- | --- |
| `untyped-local` | 2 | local `const/var X = ...` with no `:T` and no type signal in RHS |
| `module-var` | 9 | top-level `var` (allow-list: globals in `zimr.zig` + `runtime_assembly.zig`) |
| `array-mult` | 5 | `**` operator → suggest `@splat(N)` |
| `line-length` | 10 | > 120 columns |
| `c-types` | 11 | `c_int`/`c_uint`/`c_short`/etc. outside `extern struct`/`extern fn` |
| `fn-args-multiline` | 1 | fn DECLARATION (`fn_proto`) with 3+ params not one-per-line.  **Call sites NOT checked — line-length covers them.** |
| `branch-braces` | 3 | `if`/`while`/`for`/`else` body must be `.block` node when in statement context |
| `clamp-pattern` | bonus | `@max(L, @min(V, H))` → suggest `std.math.clamp(V, L, H)` |
| `floor-pattern` | bonus | `@intFromFloat(@as(f32, @floatFromInt(X)) * Y)` → suggest `@floor(X * Y)` |

> `ex-variant` (rule 14) was removed turn 379 after all pairs were
> resolved.  The Ex-suffix convention was inherited from raylib but
> wasn't pulling its weight as a lint rule — about a third of the
> pairs were genuinely distinct operations that needed semantic
> renames (`drawLineThick`, `drawCylinderBetween`, `drawModelPro`,
> `updateModelAnimationBlend`, `drawTextureRotated`, etc.), about
> half were Font-vs-FontCache variants where rename to `WithFont`
> was clearer than an opts struct, and only a couple were the pure
> "more defaults" pattern the rule had assumed.

---

## Type-signal definition (for `untyped-local`)

A type is "mentioned" in the init expression tree if any of:

- Identifier matching PascalCase **with at least one lowercase**:
  `[A-Z][a-z][A-Za-z0-9_]*`.  Filters out `ALL_CAPS_CONSTANTS`.
  Single-letter uppercase (`T`) accepted as generic-param
  convention.
- Identifier exactly matching a primitive: `i8..i128`, `u8..u128`,
  `usize`, `isize`, `f16..f128`, `bool`, `void`, `noreturn`,
  `type`, `anyerror`, `anyopaque`, `comptime_int`,
  `comptime_float`.
- `@as(...)` or `@TypeOf(...)` builtin call.
- `.struct_init*` (non-anon variants, i.e. NOT
  `.struct_init_dot*`) — explicit-typed struct literal.
- `.ptr_type*`, `.array_type*`, `.optional_type`, `.error_union`
  anywhere in the init's AST tree.

Walks the init tree recursively so wrapped expressions
(`try foo()`, `comptime bar()`) propagate.

---

## Mode + CLI

**Default behavior:** print all issues, **exit 0**.  Warn-only
until first cleanup pass clears existing hits.  Switch to
blocking (`exit code = min(num_issues, 1)`) after that.

**Flags:**

- `--quiet` — suppress per-issue output, print summary only.
- `--only=tag1,tag2` — run only listed checks.
- `--skip=tag1` — skip listed checks.

**Output format** (editor-parseable):

```
path:line:col: [tag] message (rule N)
```

**Summary line:** `N issues in M files`.

---

## Performance budget

- Single file (`src/ui.zig`, 25k lines): ~50ms cold, instant warm.
- Full `src/` (~40 files): target ~500ms.
- Full `src/` + `examples/` (~130 files): target <2s.
- If measurements exceed budget, parallelize via
  `std.Thread.Pool` — straightforward retrofit.

---

## Implementation scope

- v1 binary: ~600-800 LOC Zig.
- `build.zig` integration: ~30 LOC.
- Estimated 1 turn to implement, 0.5 turn to triage and clean
  the first wave of hits in `src/ui.zig` (~150+ untyped locals
  expected from plan v5's count).

---

## Deferred / out of scope

| Rule | Why deferred |
| --- | --- |
| 4 (casual comments, banners) | voice judgment, not mechanical |
| 6 (lift magic literals at 2+ sites) | cross-callsite analysis; v2 |
| 7 (lift complex sub-exprs) | "complex" is subjective |
| 8 (helper inlining) | cross-fn reference analysis; v2 |
| 12 (read+overwrite in same literal) | complex pattern detection; v2 |
| `@as(T, @intCast(x))` drop suggestion | needs slot-context analysis; v2 |

Meta-rule "every line you touch must become clearer" is
inherently non-mechanical.  Same for "touching a fn = bringing
the whole fn up to spec" (needs git-diff integration).

---

## Decision log

- **Turn 337:** Single-file regex approach considered and
  rejected in favor of `std.zig.Ast` for precision (no false
  positives on type-signal detection, multi-line decl support,
  comment + string-literal stripping for free).
- **Turn 337:** `fn-args-multiline` scope narrowed to fn
  DECLARATIONS only.  Call sites with 3+ args are governed by
  `line-length` (rule 10); zig fmt handles call wrapping
  acceptably.  Simon's directive.
- **Turn 337:** Default exit code = 0 (warn-only) until first
  cleanup pass clears existing hits.  Then flip to blocking.
- **Turn 337:** `tools/` dir introduced.  Distinct from
  `scripts/` (Python).  Convention: Zig tooling in `tools/`.

---

## Future sweeps queue (post-current-cleanup)

These are mechanical sweeps queued for once the linter exit-code
flips to blocking (DONE turn 379, after `untyped-local`,
`line-length`, and `ex-variant` cleared).  They are NOT lint
rules — just one-shot codebase touch-ups.  Listed in suggested
order.

### 1. Top-of-file aliases (no rule, just a sweep)

Add `const Allocator = std.mem.Allocator;` (and similar high-use
aliases like `Index = Ast.Node.Index;` where applicable) at the
top of every `.zig` file that uses them.  Reasons:

- Cuts visual noise in fn signatures.  `fn foo(gpa: Allocator)`
  reads better than `fn foo(gpa: std.mem.Allocator)`.
- Already idiomatic in zig stdlib and several existing zimr files
  (`codecs.zig` does it for `Allocator`).
- Catches drift: when a file uses `std.mem.Allocator` 20+ times
  inline, that's a clean win.

**Not a rule** — no linter check, no automated nag.  Just a
one-turn sweep through every `.zig` file with grep-driven edits.
Should follow this pattern at file top, just after imports:

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
```

Candidate other aliases (decide per-file):
- `const Ast = std.zig.Ast;` if Ast types are referenced
- `const Vector2 = types.Vector2;` for files using zimr types heavily
- `const ArrayList = std.ArrayList;` (uses `ArrayList(T).empty` then)

### 2. Anonymous struct return types (`anon-return` survey)

Added turn 348.  Survey rule that walks `fn_proto` return-type
expressions and flags `struct { ... }` / `union { ... }` etc.
**Default OFF** — run with `--only=anon-return` to see the list.

**Survey baseline (turn 348):** 7 sites.

| Site | Kind |
|------|------|
| ~~`src/runtime.zig` `CanvasViewport.cssToLogical`~~ | FIXED turn 347; refactored further turn 349 to return existing `input.Vec2` instead of a new `LogicalPoint` (no need for a parallel type) |
| `examples/ui_custom_rendering.zig:124 at()` | local helper, easy fix |
| `src/entities.zig:5440 getLoc()` | internal helper, returns `{chunk, index_in_chunk}` |
| `src/physics.zig:1296 closestPointsOnTwoSegments()` | returns `{c1, c2}` pair of Vector3 |
| `src/physics.zig:1367 closestPointOnSegmentToOBB()` | similar pair-of-points return |
| `src/physics.zig:1503 capsuleSpine()` | returns `{p1, p2}` pair of Vector3 |
| `src/ui.zig:3884 dockBuilderSplitNode()` | PUBLIC API - returns `{a, b}` pair of Dock.Id |
| `src/notes/staging/ecs-original.zig:3386` | staging/donor copy - exempt |

**Refactor pattern - check before naming a new type.**  Before
introducing a new named type for an anonymous return, grep the
codebase for an existing struct of the same shape.  Turn 349
learned this the hard way: `cssToLogical` got a fresh
`LogicalPoint = struct { x: f32, y: f32 }`, but `runtime.input.Vec2`
already existed with the same shape and was the canonical
{x, y} type for screen-space points in the runtime layer.
Reusing it cut a redundant type without losing any clarity.

**Pattern when no existing type fits:**

```zig
// Before:
pub fn cssToLogical(self: CanvasViewport, css_x: f32, css_y: f32)
    struct { x: f32, y: f32 } { ... }

// After:
pub const LogicalPoint = struct { x: f32, y: f32 };
pub fn cssToLogical(self: CanvasViewport, css_x: f32, css_y: f32)
    LogicalPoint { ... }
```

**Decision pending:** whether to ban anon returns via a hard rule
(`anon-return` graduates from `--only=` survey to a default-on
warning).  Argument for: identically-shaped anon structs are
distinct types in Zig, which makes them awkward at any
caller wanting to annotate the binding (rule 2).  Argument
against: 7 sites is small; if all 7 get refactored before the
linter goes blocking, no rule is needed.

**Linter implementation note (turn 348):** Discovered the
walker was NOT descending into `fn_proto` nodes for top-level
`fn_decl` declarations, so `fn-args-multiline` and `anon-return`
were silently no-ops for `pub fn foo(...)` declarations.  Fixed
in the `.fn_decl` case to explicitly run proto checks on the
proto child node.  Pre-existing rules like fn-args-multiline
gained visibility too as a side effect.

### 3. (Future) Member-access type signal detection

R2 false-positive class: `const c: Color = ...` is fine but
`const v = [_]z.Color{...}` flags untyped-local even though
`z.Color` is visibly on the line.  The linter's type-signal
detection only recognizes single-identifier PascalCase, not
member access (`z.Color`, `runtime.core.CanvasViewport`).

A pass through the linter to recognize "PascalCase identifier
appears as a member-access tail" would cut maybe 20-30% of
untyped-local hits without weakening greppability — the dot path
still appears on the line.  Estimated: ~40 LOC in the linter.
