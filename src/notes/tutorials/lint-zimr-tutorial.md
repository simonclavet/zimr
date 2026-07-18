# lint-zimr-tutorial.md — how the linter works

`tools/lint_zimr.zig` is an AST-based style linter for the zimr
codebase.  It encodes the mechanical style rules from `claude.md`
as automated checks, runnable per-file (for editor integration)
or whole-codebase (build step).

This document walks through what it does and how it works,
roughly in the order a fresh reader would want to learn it.

---

## 1. What it checks

Ten checks total.  Each is tagged so output is filterable
(`--only=untyped-local,line-length`).

| Tag | Rule | What it catches |
| --- | --- | --- |
| `untyped-local` | 2 | local `const`/`var` declarations without `:T` or any type signal in the init expression |
| `module-var` | 9 | top-level `var` declarations (mutable module globals) |
| `array-mult` | 5 | `**` array-repetition operator — flagged with suggestion to use `@splat(N)` |
| `line-length` | 10 | source lines longer than 120 columns |
| `c-types` | 11 | `c_int`/`c_uint`/etc. used outside FFI seams |
| `fn-args-multiline` | 1 | function DECLARATIONS with 3+ params not one-per-line.  Call sites are intentionally ignored — `line-length` covers them. |
| `branch-braces` | 3 | `if`/`while`/`for`/`else` bodies that aren't blocks.  `if (x) return y;` flagged (Simon's breakpoint reasoning — see § 4 below).  Switch bodies are exempt (the switch's own braces fully delimit the body). |
| `ex-variant` | 14 | functions `foo` + `fooEx` declared in the same file — suggest merging into one fn with an `opts` arg |
| `clamp-pattern` | (bonus) | `@max(L, @min(V, H))` or `@min(@max(V, L), H)` → suggest `std.math.clamp(V, L, H)` |
| `floor-pattern` | (bonus) | `@intFromFloat(@as(f32, @floatFromInt(X)) * Y)` → suggest `@floor(X * Y)` |

Rules deliberately NOT checked: 4 (comment style — voice
judgment), 6 (lift magic literals — needs cross-callsite
analysis), 7 (lift complex sub-exprs — subjective), 8 (helper
inlining — cross-fn analysis), 12 (read+overwrite same literal
— complex), 13 (`extern struct` only at FFI seams — partial, see
§ 7).

---

## 2. How to run it

Three ways.

**Build step (recommended for whole-codebase scans):**

```
zig build lint                       # scans every src/*.zig
zig build lint -- src/ui.zig         # specific file(s)
zig build lint -- --quiet            # summary only
zig build lint -- --only=untyped-local
zig build lint -- --skip=line-length
```

**Standalone `zig run` (recommended for editor integration):**

```
zig run tools/lint_zimr.zig -- <file.zig> [<file2.zig> ...]
```

**Compiled binary** (faster after first build):

```
zig build-exe tools/lint_zimr.zig -OReleaseFast
./lint_zimr src/ui.zig
```

Output format is editor-parseable:

```
src/ui.zig:1234:5: [untyped-local] local 'cursor_pos' lacks a type annotation (rule 2)
src/ui.zig:1289:1: [module-var] mutable module global 'last_id' (rule 9)
src/foo.zig:42:80: [line-length] 137 cols, max 120 (rule 10)

42 issues in 1 files
```

Exit code is 0 regardless of hits (warn-only mode) until the
first cleanup pass clears existing hits.  Then we'll flip to
blocking by editing `main`.

---

## 3. Big-picture architecture

The whole program is in one file, ~1200 lines.  Layout from top
to bottom:

```
┌─────────────────────────────────────────┐
│ Issue + Ctx types (output + state)     │
├─────────────────────────────────────────┤
│ Allow-list (rule 9 exceptions)         │
├─────────────────────────────────────────┤
│ Type-signal detection (rule 2)         │
│   primitives + c_types StaticStringMap │
│   isTypeNamedIdentifier                │
│   hasTypeSignal / hasTypeSignalImpl    │
│   childNodes (defensive AST walker)    │
├─────────────────────────────────────────┤
│ Top-down walker                         │
│   Pos enum (container/statement/expr)  │
│   runChecks                             │
│   walkNode (with fn_depth tracking)    │
│   walkBlockBody                         │
│   isContainerDeclTag helper             │
│   walkContainerChildren                 │
│   BlockSlice + blockStmts               │
├─────────────────────────────────────────┤
│ Individual checks (one fn each)         │
│   checkVarDecl, checkBranchBraces,     │
│   checkArrayMult, checkCTypes,         │
│   checkFnArgsMultiline,                │
│   checkClampPattern, checkFloorPattern │
├─────────────────────────────────────────┤
│ Whole-file checks                       │
│   runLineLength, runExVariant          │
│   FFI seam detection                    │
├─────────────────────────────────────────┤
│ Driver                                  │
│   Args + parseArgs + main               │
└─────────────────────────────────────────┘
```

The flow per file:

1. Read source bytes.
2. Parse via `std.zig.Ast.parse(allocator, source_z, .zig)`.
3. Detect FFI seam status (presence of any `extern fn`).
4. Walk the AST with `runChecks`, dispatching per-node checks.
5. Run whole-file checks that need cross-node visibility
   (`line-length`, `ex-variant`).
6. Sort issues by `(line, col)`.
7. Print to stdout.

---

## 4. The AST — what we actually walk

`std.zig.Ast` is Zig's official syntax tree.  After parsing, you
get:

- A flat array of nodes (`ast.nodes`).
- A flat array of tokens (`ast.tokens`).
- Methods to walk + interpret them.

Each node has a **tag** (e.g. `.simple_var_decl`, `.fn_decl`,
`.if_simple`) and a **data payload** whose shape depends on the
tag.  This is the most important thing to understand.

For example, for `.simple_var_decl` (`const x: T = init;`):

- `ast.nodeMainToken(node)` returns the `const`/`var` token.
- `ast.fullVarDecl(node)` returns an `Ast.full.VarDecl` struct
  with `.ast.type_node` (OptionalIndex), `.ast.init_node`
  (OptionalIndex), `.ast.mut_token`, etc.
- `ast.tokenSlice(mut_token)` returns the source text — either
  `"const"` or `"var"`.

For `.fn_decl`:

- `ast.nodeData(node).node_and_node` is a pair: `(proto_node,
  body_node)`.  The proto holds the signature, the body is a
  `.block`-tagged node.

The Ast API has helpers (`fullFnProto`, `fullIf`, `fullWhile`,
`fullFor`, `fullCall`) that abstract over the half-dozen
sub-tags each construct has.  For things without a `full*`
helper, you read the data tuple directly — and you'd better
know which tuple shape applies to the tag, or you'll panic.

**One thing that bit me**: the same construct can have several
sub-tags.  `.block` vs `.block_two` vs `.block_semicolon` vs
`.block_two_semicolon` — all blocks, but the data shape differs
(extra_range for many statements, opt_node_and_opt_node for ≤2).
Same story for `if` (`.if_simple` vs `.@"if"`),
`while`/`for`/calls/builtins/etc.  This is an optimization to
keep the AST compact.

---

## 5. Detecting "type mention" in an init expression

Rule 2 says locals need explicit types.  But Simon carved out:
"if the type is mentioned anywhere on the same line, we don't
need to also declare it."  So `const x = SomeType.init()` is
fine because `SomeType` appears — no need to add `: SomeType`.

The implementation lives in `hasTypeSignal` / `hasTypeSignalImpl`.
A node "has a type signal" if it (or any of its descendants) is
one of:

| AST construct | Examples |
| --- | --- |
| Identifier matching a primitive name | `i32`, `f32`, `usize`, `bool` |
| Identifier with PascalCase + ≥1 lowercase | `MyType`, `ArrayList` |
| Single-letter uppercase identifier | `T` (generic-param convention) |
| `@as` / `@TypeOf` / `@Type` builtin | `@as(u32, x)` |
| Explicit-typed struct literal | `Window{...}` (NOT the anon `.{...}`) |
| Pointer/array/optional/error-union type expr | `*const u8`, `[N]u8`, `?T`, `Error!T` |
| Error-set declaration | `error{...}` |

`isTypeNamedIdentifier` filters PascalCase carefully — `MAX_BUFFER`
(all caps, no lowercase) doesn't count as a type, so
`const x = MAX_BUFFER;` is still flagged.  This matches the
intuition: ALL_CAPS is a constant value; `PascalCaseWithLowercase`
is a type.

`hasTypeSignal` recursively walks via `childNodes` until it finds
a match or runs out of subtree.

---

## 6. childNodes — the defensive walker

`childNodes(ast, node, buf)` returns up to 8 immediate child
indices of a node.  This is what `hasTypeSignal` uses to descend.

The tricky bit: each AST tag has its own data shape.  Some are
`.node` (one Index).  Others are `.node_and_node` (two Indices).
Others are `.node_and_token` (one Index + one TokenIndex).
Others are `.opt_node_and_opt_node` (two OptionalIndex), or
`.node_and_extra` (an Index + an ExtraIndex pointing into a
SubRange of extra_data).  Accessing the wrong variant
**panics**: `access of union field 'node' while field 'X' is
active`.

`childNodes` is a giant switch keyed on tag.  For each tag we
know about, we pluck out the right subnode.  For tags we don't
recognize, we return an empty slice — meaning "we don't descend
through this construct."  False negatives (missed type signals
buried inside an un-recognized tag) are preferable to crashes.

Tags currently handled:

- Wrappers (single `.node`): `try`, `comptime`, `nosuspend`,
  `address_of`, `deref`, `negation`, `bit_not`, `bool_not`.
- Field/method-access (`.node_and_token`): `field_access`,
  `unwrap_optional`, `grouped_expression`.
- Binary expressions (`.node_and_node`): `add`, `sub`, `mul`,
  `div`, `mod`, `array_mult`, comparison ops, sat/wrap variants.
- Function calls (full): `.call`, `.call_comma` — has a SubRange
  of args via `.node_and_extra`.
- Function calls (one-arg): `.call_one`, `.call_one_comma`
  (`.node_and_opt_node`).
- Builtin calls (full): `.builtin_call`, `.builtin_call_comma`
  (`.extra_range`).
- Builtin calls (≤2 args): `.builtin_call_two`,
  `.builtin_call_two_comma` (`.opt_node_and_opt_node`).

When you add a new tag, look it up in `/path/to/lib/std/zig/Ast.zig`
— the simplest way is to grep for `\.<tag_name> =>` and see how
the std functions access its data.

---

## 7. The walker — runChecks, walkNode, etc.

The top-level entry is `runChecks(ctx)`.  It does two things:

1. Walk every top-level declaration in the AST, dispatching
   per-node checks.
2. Run whole-file checks (line-length, ex-variant) that need
   cross-cutting visibility.

`walkNode(ctx, node, pos, fn_depth)` is the core.  Two pieces
of context ride along with the recursion:

- **`pos`** — one of `.container`, `.statement`, or
  `.expression`.  Tracks what scope the current node is in.
  Module-var only fires at `.container`; branch-braces only at
  `.statement`; expression sub-trees descend with
  `.expression` so checks like array-mult fire deep in init
  expressions but branch-braces stays silent (e.g.,
  `const x = if (a) b else c;` is an expression — the `if`
  doesn't need braces).

- **`fn_depth`** — how many fn/test bodies we're nested inside.
  0 means module scope.  ≥1 means we're inside a function.
  Module-var only fires when `fn_depth == 0`, which lets the
  Zig idiom `const S = struct { var warned: bool = false; };`
  inside a function pass without flagging — those are
  function-local statics, not module globals.

For each node, walkNode:

1. Runs `checkVarDecl` (uses `pos` and `fn_depth` to dispatch
   to module-var vs. untyped-local, or skip both for fn-local
   container vars).
2. Runs `checkBranchBraces` (only if `pos == .statement`).
3. Runs unconditional checks: `array-mult`, `c-types`,
   `clamp-pattern`, `floor-pattern`.
4. Runs `checkFnArgsMultiline` (which itself checks if the
   node is a fn proto).
5. Recurses based on tag:
   - **`fn_decl` / `test_decl`** — bump fn_depth + 1, walk body
     via `walkBlockBody` (statement context).
   - **`block*`** — walk each statement (same fn_depth).
   - **`if_simple` / `@"if"` / `while_simple` / `@"while"` /
     `for_simple` / `@"for"`** — walk the then/else/body
     sub-trees, preserving pos and fn_depth.
   - **`@"switch"` / `switch_comma`** — walk condition as
     `.expression`, then each case's `target_expr` with the
     parent's pos.  Without this, statements inside switch
     arms get skipped.
   - **Anything else** — generic descent through `childNodes`,
     passing `.expression`.  Var decls get a special case: if
     the init is a container_decl (struct/union/enum literal),
     walk the members at `.container` pos with the same
     fn_depth.  Otherwise walk the init as an expression.

The generic-descent fallback is what makes array-mult and
c-types fire inside init expressions and other places we
didn't explicitly enumerate.  Without it, `const x = a ** 4;`
at statement position would never visit the `.array_mult`
node.

---

## 8. The FFI seam carve-out for c-types

Rule 11 forbids `c_int`/`c_uint`/etc. — they're paradigm-
incompatible with Zig's sized types.  But at genuine C ABI seams
(extern declarations bridging to JS or C), `c_int` IS the correct
type.

`detectFfiSeam(ast)` scans every top-level decl looking for an
`extern fn` declaration.  If one exists anywhere in the file,
the whole file is treated as an FFI seam and `c-types` is
suppressed.

This is a heuristic — a file could in principle have only an
`extern struct` and no `extern fn`.  In practice, every FFI seam
in zimr has both, so the heuristic catches them correctly.  If
a future seam contains only structs, we'd refine.

---

## 9. Whole-file checks

Two checks don't fit the per-node walk pattern:

**`runLineLength`** scans the source byte-by-byte, tracking line
breaks.  Triggers when any line exceeds 120 columns.  This is
strictly textual — doesn't need the AST at all.

**`runExVariant`** walks the AST collecting every fn declaration
name into a hashmap (name → token).  Then iterates the map
looking for any name ending in `"Ex"` whose corresponding `base`
(name with the `Ex` suffix removed) also exists.  Both exist →
flag the `Ex` variant as redundant with its base.  The collector
recurses into struct decls so namespaced fns get caught too.

---

## 10. Output + sorting + summary

Each issue is appended to a per-file `std.ArrayList(Issue)`.
After all checks complete, the list is sorted by `(line, col)`
ascending so output is deterministic.

Output is printed via a buffered `std.Io.File.Writer`.  For
each issue:

```
path:line:col: [tag] message (rule N)
```

The rule number is omitted for bonus checks (clamp-pattern,
floor-pattern) where rule 0 means "no specific rule."

At the end:

```
N issues in M files
```

---

## 11. Allow-list logic (rule 9 exceptions)

Four ways a `var` declaration can escape the module-var check:

1. **C-ABI bridge files** — `zimr.zig`, `runtime_assembly.zig`,
   `runtime.zig`.  These host wasm-side JS-callback storage
   that needs module-level lifetime.  Blanket-allowed by path
   suffix.
2. **One-shot warning flags** — any module-level `var` whose
   name starts with `warned_`.  This is the established idiom:
   `var warned_text_no_font: bool = false;` fires a log once
   per process lifetime.  Moving these to per-context state
   would re-fire per context.  Name-prefix match; the
   convention is established (see `drawing.zig`'s
   `warned_text_no_font` from turn 330).
3. **Function-local statics** — `const S = struct { var x:
   bool = false; };` inside a function body.  The walker
   visits the inner `var` at `.container` pos but with
   `fn_depth ≥ 1`, so module-var doesn't fire.  This is the
   canonical Zig idiom for function-scoped persistent state
   and Simon explicitly allows it (turn 339).
4. **The var is actually a `const`** — only `var` triggers the
   check.

If you need a new exception, prefer pattern 3 (move the
state inside a function-local struct) over patterns 1-2 — it
scopes the state to its actual user and reads more naturally.
The blanket-file allow-list and `warned_` prefix exist for
back-compat with established zimr code; for new code, use
fn-local statics.

---

## 12. Performance

Measured on a warm cache:

- Single file (`src/ui.zig`, ~25k lines): ~50ms parse + walk,
  ~100ms with the binary launch.
- Full `src/` (27 files, ~50k LOC total): ~1-2s.
- Build step overhead (`zig build lint`): adds ~3s for the
  build-graph step setup.

Cold (recompiling the linter): add ~30s.  Use the build step
to keep it warm in `.zig-cache`.

Bottleneck is `std.zig.Ast.parse` for the larger files.  If we
ever need more speed, the obvious move is `std.Thread.Pool` over
files — completely independent units of work.  Not needed yet.

---

## 13. Adding a new check

The structure makes this cheap.  Recipe:

1. **Decide if your check is per-node or whole-file.**

2. **Per-node case** — write a function `fn checkMyThing(ctx:
   Ctx, node: Index, tag: Ast.Node.Tag) !void`.  Bail out early
   if `tag` isn't the one you care about.  When you find a hit,
   call `ctx.emit(line, col, "my-tag", rule_num, fmt, args)`.
   Then add a call to it inside `walkNode` near the other
   per-node check dispatches.

3. **Whole-file case** — write `fn runMyThing(ctx: Ctx) !void`.
   Bail out if `!ctx.enabled("my-tag")`.  Do whatever
   cross-cutting analysis you need.  Add a call to it inside
   `runChecks` after the AST walk.

4. **Decide on the lint tag** (the string in square brackets in
   output).  Keep it short and kebab-case.

5. **Add a row to the table** in section 1 of this tutorial.

6. **Run the linter on itself** to make sure your additions
   don't trip rule 2 or rule 3 in your own code.

---

## 14. Limitations + known false negatives

- **Type signals buried in un-recognized AST tags** get missed
  (no type signal found → flagged as untyped).  Add the tag
  to `childNodes` to teach the walker about it.
- **Function-scoped statics via `const S = struct { var x =
  ...; };`** inside a function — these are at struct-scope and
  the walker tracks fn_depth, so they don't fire module-var.
  Idiomatic when you need a function-local static.
- **Generic-param convention** (`const T = anytype;` in
  contexts where types are values) — the matcher accepts
  single-uppercase, which is what we want.  Could rarely
  cause false acceptance for non-type single-uppercase locals
  but no real-world case has come up.
- **`@as(T, ...)` always counts as a type signal**, even if T
  is something contextual.  Intentional — the user explicitly
  named a type.
- **String/comment edge cases** are handled by the parser — the
  AST never reports identifiers inside strings or comments.
- **`extern struct` not at FFI seam** is filed as v2 (rule 13
  has only partial enforcement today).
- **Expression-position var decls** are walked with the same
  untyped-local check as statement-position.  Rare but
  consistent.

---

## 15. What's wired into `build.zig`

Steps in `build.zig` that touch the linter:

```zig
const lint_exe = b.addExecutable(.{
    .name = "lint_zimr",
    .root_module = b.createModule(.{
        .root_source_file = b.path("tools/lint_zimr.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    }),
});
const lint_run = b.addRunArtifact(lint_exe);
// (default scan of src/*.zig if no file args, then append b.args)
const lint_step = b.step("lint", "Run AST-based style linter on Zig sources");
lint_step.dependOn(&lint_run.step);
```

`ReleaseFast` matters — the linter is CPU-bound on `std.zig.Ast.parse`
and runs noticeably slower in Debug.

---

## 16. Where to go from here

Things filed for the v2 spec:

- `@as(T, @intCast(x))` drop-suggestion (needs slot-context
  analysis).
- Magic-literal repetition (cross-callsite, rule 6).
- Helper-inlining suggestion (cross-fn, rule 8).
- Read+overwrite same literal (rule 12, complex).
- Extern struct outside FFI seam (rule 13 has partial coverage).
- Parallelism via `std.Thread.Pool`.

Once existing hits are cleaned up, flip the exit code to
nonzero in `main` so the build step actually fails on
violations.
