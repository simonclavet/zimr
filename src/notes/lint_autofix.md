# zimrlint autofix — design & plan

Status: **P1 SHIPPED (turn 446).** `--fix` mode is live with three unambiguous
rules wired and verified end-to-end (detection + rewrite + idempotence + parse
guard + cascade) on fixtures. Remaining tiers stay as planned below.

## P1 — what landed

- `Issue` gained `fix: ?Fix{ start, end, replacement }`; check mode ignores it
  (gate untouched — 0 issues across the whole tree confirmed post-refactor).
- `Ctx.emitFix` (token-located) + `emitFixLC` (line/col, for the text-based
  shader rule), both riding the existing `// lint:off` suppression.
- `analyzeSource` extracted from `main` so check + fix share one analysis path.
- Machinery: `collectFixes` (sort asc, drop overlaps), `applyFixes` (segment
  splice), `countParseErrors` + the **parse-guard rollback** (an edit that raises
  the parse-error count is discarded), `runFixLoop` (≤5 passes for cascades).
- CLI: `--fix` (rewrite in place), `--dry-run` (report, no write), `--check`
  (explicit alias of default). **Decision taken:** default stays check (gate-safe),
  `--fix` is opt-in — the deliberate divergence from `zig fmt`'s default-write,
  since the linter is a build-gate dependency. Pair `--fix` with `zig fmt` after
  to collapse the blank line a deletion can leave.
- Rules wired (single-span, valid Zig even pre-fmt): **unused-global** (delete the
  decl span: doc-comments → `;` → trailing newline when it owns the line),
  **named-struct-init** (`foo.Bar{...}` → `.{...}`, whole type expr), **shader-
  inline-fn** (delete `inline `), and **no-qualified-zm half-1** (turn 450): when a
  file-scope `const X = zm.X;` already exists, rewrite an inline `zm.X` → `X` by
  deleting the `zm.` prefix. Only when the binding exists (then X provably resolves,
  no collision); the missing-binding case stays report-only.
- GUARD UPGRADE (turn 450): the rollback guard went from parse-only to **parse +
  AstGen** (`compilesClean` = `Ast.parse` then `AstGen.generate` / `hasCompileErrors`).
  This catches SEMANTIC breakage a parse check misses — when two fixes in one pass
  conflict (e.g. `unused-global` deletes `const clamp = zm.clamp` because its only
  use was the qualified `zm.clamp`, while `no-qualified-zm` rewrites that use to bare
  `clamp` → undeclared identifier). The pass rolls back, the file is left untouched,
  both issues report. AstGen treats `@import` opaquely so cross-module refs never
  false-trip; only runs when a fix is pending (zero cost on clean files).

Verified on fixtures: doc-commented unused decl, multi-line `blk:` decl, cascade
(`b` removed → `a` unused → both gone in 2 passes), `Point{...}`→`.{...}`,
`inline fn`→`fn`; dry-run leaves bytes intact; re-fix is a no-op; results
re-check clean and `zig ast-check` passes.

## P2 — build integration (turn 447, SHIPPED)

The "LINT-FIRST GATE" in build.zig already ran lint + `zig fmt --check` before
every compile. Added `-Dautofix` (default **true**) that flips that gate from
check to **apply**:

- `-Dautofix=true`: the install-path lint Run gets `--fix`, and a gate-only
  `fmt_apply_gate` runs after it (serialised — the two mutating steps never
  race), so the order before every compile is **lint --fix → zig fmt →
  compile**. Build proceeds when nothing unfixable remains; still fails (and
  shows them) on manual-tier issues like line-length / untyped-local.
- `-Dautofix=false`: the original strict gate (`fmt --check` + lint check, no
  mutation) — for CI, verification, and the `wgpu-check` regression gate.
- the standalone `lint` / `lint-check` steps still use check-mode `lint_run`, so
  explicit checks never mutate regardless of the option.

Why default-on clears the "confident we're not breaking anything" bar: the
parse-guard means a fix never writes a worse-parsing file, AND the very next step
is the compile, which catches any wrong deletion immediately (a removed-but-
referenced decl → undefined-identifier error in the same build). The one residual
risk is `@hasDecl(@This(), "private")` by string literal flipping true→false
silently — vanishingly rare, and a diff review catches it. Autofix also dissolves
the original turn-343 objection: dirty state used to *block* the build; now it
gets *fixed*.

Verified: planting an unused global in an example and running
`zig build <ex>-standalone` removes it + produces the html; `-Dautofix=false`
reports the same global and refuses to mutate; `wgpu-check -Dautofix=false` green;
default gate on a clean tree mutates nothing. Strict verification uses
`-Dautofix=false`.

## TODO (next)

- ~~mtime-cache in fix mode~~ DONE (turn 448): `--fix` now shares the stamp
  cache — skips stamped-clean files, re-stamps a fixed file at its post-write
  mtime. Cold whole-tree fix ~3.7s, warm ~3ms. Stamps interchangeable with check
  mode (a file proven clean by either is known clean).
- Permanent fixture + host-test target (rollback + cascade fixtures) so this
  can't silently rot.
- no-qualified-zm **half-2**: auto-INSERT `const X = zm.X;` when missing. Needs a
  free-name guard (skip if X is any local/param/decl, else the binding collides or
  the rewrite dangles) + deterministic placement (after the col-0 `const zm =
  @import("zm");`) + insert-dedup across N uses. Safe given the compile backstop;
  not parse-safe alone. The common small-file case (e.g. a fresh `zm.radFromDeg`).
- A2 tier: as-round / redundant-cast, prefer-std-alias, import-at-top,
  std-debug-assert, clamp-pattern.

---

## 1. Why (original plan follows)

Every porting turn burns 2–4 fixes on deterministic nits the linter already
located precisely: an unused import, a qualified `zm.clamp` that wants the
file-scope alias, a missing trailing comma on a 3-arg signature, a braceless
`if`. These are not judgement calls — the linter knows the exact token. A
`--fix` pass collapses that hand-loop the same way `zig fmt` collapses
whitespace fiddling.

The tree currently sits at 0 lint issues (the gate enforces it), so this is not
a one-time cleanup — it is an inner-loop accelerator for *new* code between
edit and gate.

## 2. What exists today

- AST-based, one pass per rule. Each rule calls `ctx.emitAt(tok, tag, rule,
  fmt, args)`, which records `Issue{ line, col, message, rule }` — a *position*,
  not an *edit*.
- `// lint:off <rule>: <reason>` suppression and an `isSkipped` path allow-list,
  both applied before/at emit, so anything riding the issue stream inherits
  suppression for free.
- Per-file mtime stamp cache under `tools/.zig-cache/lint-stamps/`. The existing
  comment already says `--fix` should disable cache *lookups* (we always want
  fix to re-examine).
- File-writing already exists for stamps (`writeStamp` → `Dir.writeFile`), and
  byte spans are trivial: `ast.tokenStart(tok)` for the start, `tokenStart(last)
  + tokenSlice(last).len` for the end (see zimrlint.zig:2112-2114).

## 3. The core change — Issue carries an optional Fix

```zig
const Fix = struct {
    start: u32, // byte offset into source, inclusive
    end: u32, // byte offset, exclusive
    replacement: []const u8, // "" for a pure deletion; arena-owned
};
// Issue gains:  fix: ?Fix = null,
```

Rules that can mechanically repair themselves compute a span and set `.fix`.
Check mode ignores `.fix` entirely (output and exit code unchanged → the gate is
untouched). Suppressed issues never reach the fixer, so `lint:off` is honoured
with no extra code.

## 4. Safety invariant (the `} };` lesson)

A prior *external* autofixer once left `} };` shapes after struct-init returns,
producing parse errors that silently un-linted 5 files for ~5 turns
(zimrlint.zig:3510-3513). The non-negotiable rule that prevents a repeat:

> After applying edits, RE-PARSE the result. If it has more parse errors than
> the input did, roll the whole file back and report — never persist a file that
> parses worse than it started.

## 5. Fix-application algorithm (per file, in `--fix`)

1. Run all rules → issues (same as check).
2. Collect issues with non-null `.fix` into an edit list.
3. Sort edits by `.start` **descending**.
4. Walk the list; skip any edit overlapping an already-accepted (later-in-file)
   edit — conflicts defer to the next pass rather than corrupting.
5. Splice accepted edits into a copy of the source, back-to-front (so earlier
   offsets stay valid).
6. **Re-parse the spliced bytes.** New parse errors ⇒ discard this file's edits,
   report, exit non-zero (invariant §4).
7. Write the file. Re-lint it; loop up to 3 passes to (a) apply edits deferred
   for conflict, (b) catch newly-exposed issues (e.g. removing decl A makes B
   unused), (c) settle. Stop when a pass makes no edits.
8. **Pair with fmt.** The fixer makes the *minimal semantic* edit only (insert
   one comma, wrap a body in `{ }`) and leaves reflow to `zig fmt`. Fix mode runs
   `zig fmt` on touched files as its final step.

## 6. Rule-by-rule triage

Tiers: **A1** mechanical single-span (v1), **A2** multi-edit or light inference
(v2), **M** manual — needs human/semantic judgement, never auto.

| rule | tier | mechanical fix |
|---|---|---|
| unused-global | A1 | delete the decl span (doc-comments → `;` → trailing `\n`). FLAGSHIP. |
| shader-inline-fn | A1 | delete the `inline ` keyword token. |
| named-struct-init | A1 | delete the type-name token before `{` → `.{...}`. |
| fn-args-multiline | A1 | insert a trailing comma after the last param; fmt reflows. |
| branch-braces | A1 | wrap the body statement in `{ }`; fmt reflows. |
| as-round | A2 | unwrap `@as(T, @trunc(x))` → `@trunc(x)` (type comes from context). |
| redundant-cast | A2 | drop the cast helper when the decl already names the type. |
| int-from-float | A2 | `@intFromFloat(x)` → `@trunc(x)` *default* (intent trunc/floor/round can't always be inferred — emit, don't silently guess floor/round). |
| std-debug-assert | A2 | `std.debug.assert(x)` → `assert(x, @src())` shape; may need an alias decl. |
| prefer-std-alias | A2 | add a file-scope `const <name> = std.<path>;` + rewrite call sites (multi-edit). |
| import-at-top | A2 | hoist the import decl to file scope (move). |
| clamp-pattern | A2 | `@min(@max(x,lo),hi)` → `clamp(x,lo,hi)` (arg reorder). |
| decl-order | A2/A3 | reorder decls defined-before-use (move blocks; opt-in migration rule). |
| untyped-local | M | requires type inference to write the annotation. |
| std-math | M | the only fix is adding the fn to zimrmath.zig. |
| reserved-math-names | M | rename a local + all its uses (scope analysis). |
| module-var | M | `var`→`const` only if never mutated (mutation analysis). |
| line-length | M | no safe break point (fmt itself won't break it). |
| array-mult | M | `**` → `@splat` is context-dependent. |
| shader-no-atan | M | needs a polyfill, not a rewrite. |
| sampler-in-branch / -in-helper | M | structural shader restructuring. |
| anon-return | M | survey rule; naming the type is a judgement call. |
| parse-error | M | a failure state, not a fixable lint. |

## 7. CLI — fmt symmetry, with a deliberate divergence

`zig fmt` *writes by default* and `--check` opts into non-mutating. For a linter
that is a **build-gate dependency** (every standalone build runs whole-tree lint
as a gate step), a default that mutates source on every build is hazardous.
Recommendation:

- `zimrlint <files>` → **check** (default, unchanged, gate-safe).
- `zimrlint --fix <files>` → apply autofixes, re-check, exit 0 iff no *unfixable*
  issues remain. Cache lookups stay disabled under `--fix`.
- `zimrlint --fix --dry-run <files>` → print a unified diff, write nothing
  (optional, nice for reviewing before committing).
- `zimrlint --check <files>` → explicit alias of the default, for fmt muscle
  memory.

Open question for Simon: accept the divergence (default = check), or match fmt
literally (default = fix, require `--check` in the gate)? The former is safer;
flagging because the framing was "behave the same way as fmt".

## 8. Implementation phases

- **P1 — plumbing + one rule.** Add `Fix` to `Issue`; `applyFixes()` with the
  §5 algorithm incl. the re-parse rollback guard; `--fix`/`--check`/`--dry-run`
  arg parsing; final `zig fmt` pass. Wire **unused-global** only. Land with
  fixtures + tests.
- **P2 — rest of A1.** shader-inline-fn, named-struct-init, fn-args-multiline,
  branch-braces.
- **P3 — A2.** as-round / redundant-cast first (highest hit-rate in porting),
  then prefer-std-alias, import-at-top, std-debug-assert, clamp-pattern.

## 9. Tests

- `tools/lint_fixtures/<rule>.in.zig` + `<rule>.out.zig` pairs; a host test runs
  fix on `.in` and asserts byte-equality with `.out` (post-fmt).
- A **rollback fixture**: input crafted so a naive edit would break parsing;
  assert the fixer writes nothing and exits non-zero (guards §4).
- A **cascade fixture**: two decls where removing the first unuses the second;
  assert both are gone after the multi-pass loop.
- Idempotence: running fix twice equals running once.

## 10. unused-global fix detail (flagship)

In `runUnusedPrivateGlobals` we already hold the `decl` node (and `vd`). To
delete it:

- `start = ast.tokenStart(ast.firstToken(decl))`, then walk *backwards* over any
  contiguous `.doc_comment` tokens and their leading indentation so the `///`
  lines go too.
- `end = ast.tokenStart(last) + ast.tokenSlice(last).len` where `last =
  ast.lastToken(decl)` (the `;`), then extend over the trailing `\n`.
- `replacement = ""`.
- Edge cases: a decl sharing a line with siblings (`const a = 1; const b = 2;`)
  — delete only its own span; the multi-pass loop handles cascade unusing; a
  decl carrying `// lint:off unused-global` is already suppressed upstream so it
  never produces a Fix.
