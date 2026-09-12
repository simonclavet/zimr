# Opinionated linter plan — "an extension of the compiler"

Goal: grow `tools/zimrlint.zig` into a very opinionated extension of the Zig
compiler — catching hazards and idiom drift the compiler allows. Seeded by
studying **zlint** (DonIsaac/zlint, ~19 rules + a semantic analyzer) and deciding,
rule by rule, what actually fits zimr.

**Hard constraint: everything stays in `tools/zimrlint.zig`. No new files.**

---

## North star: one obvious way

Zig's own ethos ("one obvious way"; `zig fmt` already enforces it for *layout*).
We extend that from formatting into *idiom*. A rule earns its place ONLY if it is
one of two modes:

- **Collapse** — when N spellings are the *identical* behavior, mandate the one
  canonical spelling. (`return try foo()` → `return foo()`.)
- **Force a choice** — when N forms mean genuinely *different* things, forbid the
  silent default and require a deliberate pick (or an explicit `// lint:off`).
  (every `catch {}` / `catch unreachable` → assertf, real handling, or lint:off.)

A candidate rule is rejected unless it (1) collapses a real redundancy OR forces a
conscious choice, (2) does **not** fight our own established canon, (3) is **not**
already covered by the compiler or an existing rule, and (4) has enough real
violations in-tree to be worth the friction (not "mostly already respected").

---

## Foundation: the "(a)" approximation — no symbol table

Several high-value rules want to answer "what does this name refer to?" We will
NOT build zlint's multi-file semantic analyzer (Symbol.Table / Scope.Tree). Instead
we extend the traversal we already have — `walkNode` / `walkBlockBody`, which
already track `.container` vs `.statement` position and `fn_depth` — with cheap
AST-local approximations:

- a per-function set of locally-declared `var`/`const` names (for
  returned-stack-reference),
- enclosing-function return-type awareness — is the fn typed `!T`? (for
  useless-error-return),
- a file-level two-pass "collect all container-scope decl names, collect all
  identifier references, diff" (for unused-decls).

Approximations occasionally mis-fire; that is fine — a genuine exception takes a
`// lint:off <tag>`. Because the linter gates **every** `zig build`, any new rule
must reach **zero false positives on the current tree** before it becomes blocking.
Rollout for FP-prone rules: implement → run on tree → resolve real hits / narrow
the rule / annotate legit exceptions → only then make it blocking.

---

## Rules to ADD

### 1. catch-suppression  (force-a-choice; pure-AST)
Flag empty `catch {}` (even with only comments inside) **and** `catch unreachable`.
Mechanically: a `catch` clause whose body is an empty block or a bare `unreachable`.
Sanctioned resolutions (pass): `catch { assertf(...) }`, `catch |e| { …handle… }`,
`catch @panic(...)`, a default value (`catch null` / `catch 0` / …), or a
control-flow diversion (`catch return` / `break` / `continue`). Genuine swallows
get an explicit `// lint:off catch-suppression: <why>`.

Why both `{}` and `unreachable`: safety ranks **assertf > {} > unreachable**.
- `catch { assertf(...) }` — assertf lowers to `unreachable` in ship mode, so it
  KEEPS the optimizer's "can't happen" hint AND adds a message-carrying abort in
  checked builds. Strictly ≥ bare `catch unreachable` in every mode → there is no
  reason left to ever write bare `catch unreachable`.
- `catch {}` — defined behavior; hides a failure but no UB.
- `catch unreachable` — the ONLY one that is undefined behavior in ReleaseFast if
  the assumption is wrong (a shipped game corrupts instead of crashing cleanly).

In-tree impact: ~137 `catch {}` + 21 `catch unreachable` = ~158 sites, each becomes
a conscious decision. Expected: majority → `catch { assertf(...) }`; some → real
handling; a small tail → `lint:off`. The linter CANNOT tell "good degrade" from
"bad hide" — that's the point: force each to be resolved. Legit `catch {}` that
must stay (and become `lint:off`, NOT assertf): writer/log ops (`writer.print(...)
catch {}` — a benign write failure must not abort a checked build) and deliberate
OOM-survivable degradation (e.g. physics `world.events.contactEnd().append(...)
catch {}` — dropping one event beats crashing a shipped game).

### 2. no-return-try  (REJECTED — zimr925; see "Rules REJECTED")
`return try foo()` → `return foo()` when the `try` is redundant (the enclosing fn
already returns the same error union). Do NOT fire on a `try` doing real work.
**Turned out that "doing real work" can't be detected by AST alone** — `!?T`
payload-coercion cases make `return try X` non-redundant, and 8 tree sites broke on
conversion. Rejected as a blocking pure-AST rule; a `!void`-only subset would be safe.

### 3. no-catch-return  (collapse; pure-AST)  — LANDED (zimr925, blocking, 0 tree hits)
`catch |e| return e` (propagating the SAME error) → prefer `try`. Fire ONLY on the
truly-equivalent case — not `catch return <default>`, which means something
different (that's a handled default, sanctioned by rule 1). Preventive: 0 existing
hits (zimr already uses `try`), so it just guards against the verbose form creeping in.

### 4. returned-stack-reference  (force-correctness; uses (a))  — flagship bug-catcher
Catch `return &<x>` where `<x>` is a stack local declared in the current function
(a dangling pointer → UB). Approximation: track the per-fn local `var`/`const`
name set; flag `return &<simple-identifier>` ONLY when the identifier is a tracked
local. This automatically skips the ~40 legit `return &…` sites in zimr, which are
all `&self.field`, `&arr[i]`, `&.{}`, `&[_]T{}` (none are bare local identifiers).
No name resolution beyond the local-name set.

### 5. unused-decls  (compiler blind spot; uses (a))
The compiler errors on unused *locals*, params, and captures — but says nothing
about unused *file-scope* declarations. Flag only **non-`pub`, file-scope**
const/fn/var never referenced by name in the same file. Conservative: `pub` decls
are exempt (cross-file usage is invisible to a per-file linter and would
false-positive). Catches dead private helpers.

**STATUS (zimr927): LANDED — const/var + fn, blocking, tree clean.**
The const/var half was already the `unused-global` rule. Extended
`runUnusedPrivateGlobals` to fns (skip `pub`; skip `export`/`extern` via
`FnProto.extern_export_inline_token` == keyword_export/keyword_extern = WASM entry
points + ABI decls; `inline` NOT skipped) — same ref-count + `unusedGlobalFix`
(works on any decl span). Simon chose "delete the orphans": `--fix` (runFixLoop
iterates ≤5 passes with a parse guard, so it sweeps the cascade) removed **45 dead
private fns** (35 flagged + 8 draw3d cascade + 2 in webtests my first scan missed).
THREE deliberate exceptions kept via `// lint:off unused-global`: `mix`/`saturate`/
`stepEdge` in zimrmath (@hasDecl-pinned discoverability stubs — the linter can't see
string-based @hasDecl refs, so they're false positives) and `debugCheckPbrWinding`
(debug tooling). rule_notes entry + 3 harness tests + "unused-global" in `tested`.
Full `zig build` green, 24 harness tests. NOTE: the build lints a broader set than
`find src examples tools` — it includes `webtests/`; scan that too.

### 6. useless-error-return  (bug-catcher; uses (a))  — LANDED, BLOCKING
A fn typed `!T` whose body can never actually error (an over-broad signature).

**STATUS (zimr929): LANDED — blocking, tree clean, 3 lint:offs.**

**★ POLICY CORRECTION (Simon, zimr929): there is no report-only tier.** I first
shipped this behind an opt-in `--useless-error-return` flag because the linter has
no advisory severity. That was wrong -- "lint gates as much as compile". A rule
nobody's build runs isn't a rule. The only options are: tune it FP-free (lint:off
the cases a contract genuinely forces, and MANY lint:offs are acceptable), or kill
the rule. The flag is gone; the rule is unconditional.

**Detection.** Flag a `!T`/`E!T` fn when the body can't error. "Can error" =
(a) tokens include `try`/`errdefer`/`error`; (b) a `catch` RE-RAISES -- its handler
returns something not provably non-error; (c) any `return` value isn't provably
non-error, where provable = literal / aggregate init / enum literal only.
`fnUsedAsValue` additionally skips any fn whose name appears as a VALUE.

**★ The big FP-killer: `fnUsedAsValue`.** 13 of the first 20 hits were callbacks
whose signature is PINNED by a contract -- `AppSpec.init` is declared
`fn (Allocator, *Frame, *StateT) anyerror!void`, image_editor holds a
`*const fn (...) anyerror!void` table -- and Zig will NOT coerce a plain-`void` fn
into an error-union slot, so the `!` isn't the author's to drop. Detecting
"name used as a value" (not `.field`, not followed by `(`) auto-skips all of them,
so every FUTURE example's init is free too. Turning a recurring 13+ lint:off tax
into zero. Same bare-identifier approximation as unused-global.

**★ The FN-killer: precise `catch` semantics.** Treating every `catch` as
error-preserving hid 4 fns. But `catch` only preserves the error if the handler
RE-RAISES (`catch return WriteError.Failed`) -- a handler yielding a default
(`catch return .{...}`), a bare `return;`, or a noreturn panic
(`catch assertUnreachable(...)`) HANDLES it. Implemented as `catchReraises`:
a flat scan of the node list for `.catch` nodes inside the body's token span
(NOT a walker -- `childNodes` covers expressions only, no blocks/var-decls/
if-while-for, so a walker silently misses `const x = foo() catch ...`). Measured
`errdefer` suppression separately: 0 FNs, so it stays. This surfaced 3 real hits
(zimrphysics2d `sleepIslands`, codecs `glyphBoxT2`, plot_svg_demo `main`) while
correctly keeping zspv `write` quiet.

**Tree fixes (7 `!` dropped, all compiler-verified):** 4 `main`s (Simon: "mains that
dont error should not have !"), material `ComputePipeline.init` (+2 callers'
`try`), plus the 3 catch-surfaced ones (+1 caller).

**3 lint:offs — contracts the linter can't see:** spv2wgsl `emitSampledImage`
(shape uniform with the 18-arm `emit*` dispatch), entities `finish` (overridable
hook; overrides return EcsEntityOverflow), draw3d `uploadMesh` (raylib-parity
no-op; Step 4 allocates). All three already documented that intent in their own
doc comments.

**Known FN limit (needs type resolution, NOT fixable pure-AST):** `return foo()`
and `return someLocal` are skipped because AST alone can't tell whether the callee
/ local is an error union. A fn that only "errors" through such a return is missed.
Accepted: this direction costs nothing but a missed catch, never a broken build.

### 7. duplicate-case  (collapse/suspicious; pure-AST)  — LANDED, BLOCKING

**STATUS (zimr930): LANDED — blocking, tree clean, 0 lint:offs, 3 prongs merged.**

Two prongs of one switch with byte-identical bodies: either they were meant to be
one prong (`.a, .b => body`) or one is a copy-paste that forgot to change. The
merge is always semantics-preserving.

**★ The whole story here was NARROWING, because repeating a body is often GOOD
Zig.** Naive byte-equality gave **89 hits** — and nearly all were canon, not
redundancy:
- **Lookup tables** (`.rgb565 => 2, .rgba4444 => 2`, 30 in zimrphysics_demo alone):
  one line per variant is idiomatic + diff-friendly. Merging costs readability.
  -> skip bare-expression bodies; require a BLOCK. 89 -> 9.
- **Exhaustive no-ops** (`.joined_as => {}, .channel_open => {}` in net_cursors):
  the per-variant `{}` is what makes adding an enum field a compile error. That is
  the point of the switch. -> skip empty blocks.
- **Doc-separated prongs** (each SPIR-V opcode documenting its operand layout in
  spv2wgsl; each ignored event saying why in net_cursors): the author already made
  the conscious choice, and merging would delete the documentation. -> skip any
  prong carrying its own comment (`prongHasComment` byte-scans the gap between the
  previous token and the prong's first token, where the tokenizer drops comments).
  9 -> 3.

Also skipped structurally: prongs with a CAPTURE `|v|` (payload type can differ per
tag, so identical text isn't identical meaning and the merge may not even compile)
and `inline` prongs (tag is comptime-known inside, so the same text can lower
differently). Byte equality means a differing comment keeps it quiet — safe
direction.

**The 3 survivors were all genuine and got merged:** runtime `.up`/`.cancel` (same
gesture reset), zbuild `.dag`/`.other` (same suppression bookkeeping), and
zimrlint's own walker `.while_simple`/`.for_simple` (same single-body walk). Zero
lint:offs needed — every intentional duplicate is detected structurally.

**Honest assessment:** the weakest of the seven. It found no actual bugs, only 3
minor collapses, and needed four carve-outs to stop fighting canon. It is cheap to
keep (block-bodied undocumented identical prongs are rare, so the future tax is
near zero) and it would catch a real copy-paste someday — but it is the first
candidate to delete if it ever nags.

### 8. redundant-import  (collapse; pure-AST)  — LANDED, BLOCKING  [from zwanzig]

**STATUS (zimr931): LANDED — blocking, tree clean, 88 sites autofixed, 0 lint:offs.**

Borrowed from zwanzig's `dupe-import` (see the STUDY note below). When a file binds
`const wgpu = @import("wgpu.zig");`, writing `@import("wgpu.zig").render_pass`
inline again is the long way round. Same "one obvious way" as prefer-std-alias and
no-qualified-zm, generalized to every module; `--fix` swaps in the alias.

Narrow by construction: only WHOLE-module bindings count (a member binding like
`const truetype = @import("codecs.zig").truetype;` is not a module alias), and a
module bound to two names is skipped entirely (no single right replacement).

**Side benefit:** collapsing the verbose form exposed 4 locals that had been hiding
from `untyped-local` — the rule-2 exception logic never saw through
`@import(...).f()`. Annotated them; latent gap closed.

**Open, NOT done (judgment call for Simon):** 9 files bind ONE module to 2+
file-scope aliases — `text2d.zig` has image.zig as `textures_module`,
`textures_local` AND `img`; `wgpu_app.zig` has types.zig as `types`, `types_img`,
`types_font`; `zimr.zig` has `types`/`colors`, `entities`/`ecs`, `ui_real`/`ui`;
three ui tests have `ui`/`ui_screenshot`. Some are deliberate semantic aliases, so
this half stays unimplemented pending a call on which to collapse.

## STUDY: zwanzig (external Zig linter, 43k LOC) — what we took and what we did not

Two-tier: fast AST/token rules + CFG checkers doing path-sensitive symbolic
execution (exploded graph) over ZIR.

- **TOOK: dupe-import** -> rule 8 above, 88 real hits.
- **REJECTED: shadowed-variable** — compile-tested it: Zig ALREADY errors on both
  parameter and file-scope shadowing. Compiler-covered, fails the north star.
- **REJECTED: empty-defer / empty-errdefer** — 0 hits in this tree.
- **REJECTED: deinit-lifecycle** (same cleanup in both defer AND errdefer). Probed
  properly: keying on receiver+method gives 20 hits but ALL are false positives
  (`errdefer gpa.free(pixels)` vs `defer gpa.free(seeds)` free different
  resources — for allocator-style cleanup the resource is the ARGUMENT, not the
  receiver). Keying on the exact cleanup expression: **0 hits**. No signal here.
- **★ REJECTED: the whole ZIR/CFG engine, and this is the important one.** ZIR does
  NOT carry resolved types — AstGen is syntactic lowering; type resolution lives in
  Sema/AIR and needs the full compile pipeline. Their own "ZIR bridge" proves it:
  `parseBuiltinType` does `_ = zir;` and string-matches type NAMES, and
  `inferTypeFromInit` switches on AST tags. So ZIR would NOT have saved rule 2
  (no-return-try) and does NOT fix rule 6's `return foo()` false negative. Both
  rejections were correct; the "no semantic analyzer" decision stands. (We already
  generate ZIR in `compilesClean` for the --fix guard and discard it — it is there
  for intra-function control flow if ever wanted, just not for types.)
- **Suppressions:** theirs has region disable/enable plus BLANKET disable with no
  rule list. Ours deliberately ignores a bare `// lint:off`, which matters more now
  that every rule gates the build. Keep ours. Only idea worth stealing later:
  region suppression for a generated table block.
- **Deferred candidate:** their `swallowed-error` extends catch-suppression to
  non-empty handlers that neither rethrow nor call anything
  (`catch |e| { flag = true; }`). Not yet measured here.
- **Doc idea:** their RULES.md gives every rule a Bad/Good code pair; our
  `rule_notes` are prose-only. Cheap improvement if we want it.

## ROLLOUT COMPLETE
All 7 rules resolved: 1 catch-suppression, 3 no-catch-return, 4
returned-stack-reference, 5 unused-decls, 6 useless-error-return, 7 duplicate-case
all LANDED + BLOCKING; 2 no-return-try REJECTED (needs type resolution — `!?T`
payload coercion means AST can't tell a redundant `try` from a coercing one).
Flag two prongs in one `switch` with duplicate *bodies* (NOT duplicate values —
the compiler already errors on duplicate case values). Simplified for zimr: compare
prong body *source spans* for exact equality (literal copy-paste); skip zlint's
commutative normalization (`y+1` == `1+y`) as over-engineering. Moderate
implementation cost, likely low hit count — build last, or defer.

---

## Rules REJECTED (and why — so this isn't re-litigated)

- **unsafe-undefined** — zimr has ~1388 `= undefined` (every fixed buffer). Fights
  our entire style. Out.
- **avoid-as** — we deliberately chose `@as` + typed locals as our one way. A rule
  pushing the other direction fights our own canon. Out.
- **no-unresolved** — the compiler already errors on bad `@import`s. Redundant. Out.
- **homeless-try** — the compiler already errors on `try` outside an error-returning
  fn. Redundant. Out.
- **case-convention** — mostly self-respected (low value) AND not safe to enforce:
  type-returning functions are conventionally TitleCase (`fn Net(...) type`), so a
  naive "functions are camelCase" rule false-positives on every comptime type
  constructor; separating them needs real return-type analysis. The one part that
  matters (no SCREAMING_CASE) is ALREADY covered by our `screaming-const` rule
  (zimrlint.zig ~3795). Out.
- **allocator-first-param** — mostly respected + legit exceptions (`comptime T:
  type` leads, `self` leads, subject-being-operated-on can lead) + fights our own
  canon: our serialize API deliberately puts the allocator LAST (`decode(comptime
  T, bytes, gpa)`, `encodeAlloc(value, gpa)`). Out.
- **must-return-ref** — niche (getters returning refs). Out.
- **empty-file** — near-zero value. Out.
- **line-length**, **no-print** — we already have both.
- **no-return-try** — IMPLEMENTED + tested (zimr925), found 138 genuine hits (the
  307 other `return try` correctly skipped as non-error). But NOT safe to enforce
  as pure-AST: `return try X` collapses to `return X` only when X's error-union
  PAYLOAD matches the fn's return payload. When a fn returns `!?T` (error union of
  an optional) and X returns `![]u8`, `return try X` unwraps to `[]u8` then coerces
  to `?[]const u8` (optional-wrap in VALUE position) — but `return X` fails, because
  Zig does NOT optional-wrap an error-union payload. So that `try` is doing real
  coercion work, indistinguishable by AST alone from a redundant `try` without type
  resolution. 8 of the 138 broke the build exactly this way, all `!?[]const u8` fns
  returning `try allocPrint(...)`. Reverted. A narrowed `!void`/`E!void`-only subset
  WOULD be safe (void has no payload to coerce) — held as a future option. Out (as a
  blocking pure-AST rule).

---

## Rollout sequence (each step ends with the tree green)

**Landed (zimr919): the "(a)" local-name-tracking piece + returned-stack-reference,
blocking, 0 tree hits, 4 harness tests.** Built its consumer alongside the machinery
so the approximation was provable, rather than shipping unused infrastructure.
Remaining machinery (enclosing-fn return-type flag; file-level decl/use collection)
lands with its own first consumer (useless-error-return; unused-decls).

1. **(a) machinery** — per-fn local-name set + enclosing-fn return-type flag +
   file-level decl/use collection. Infrastructure only; no rules yet.
2. **catch-suppression** — add rule → resolve the ~158 sites (mostly → assertf,
   some → handle, tail → lint:off). The big cleanup.
3. **no-return-try** + **no-catch-return** — small mechanical collapse rules.
   DONE (zimr925): no-catch-return landed (blocking, 0 hits); no-return-try rejected
   (needs type resolution — `!?T` payload coercion — reverted; see Rules REJECTED).
4. **returned-stack-reference** — run → verify it skips the 40 legit `return &…`
   and catches any real dangling pointer.
5. **unused-decls** (non-pub scope) — run → delete dead private helpers.
6. **useless-error-return** — report-only → tune to FP-free → maybe blocking later.
7. **duplicate-case** — only if the exact-body-span version stays simple; else defer.

Each new rule: a kebab tag, integration with the existing `emitAt` / `Issue` /
`// lint:off <tag>` machinery and doc-comment style, and (where it fixes a
canonical form) an optional autofix following the existing `Fix` pattern.

---

## Test harness (LANDED, zimr918)

A tiny RuleTester-style harness now lives at the bottom of `tools/zimrlint.zig`
(kept in-file per the one-file rule). Run it with `zig test tools/zimrlint.zig`.
`ruleFires(alloc, src, tag)` lints a source snippet in-memory through the SAME
`analyzeSource` path `main` uses; `expectFires` / `expectClean` wrap it. Every new
rule below MUST land with a fires/clean pair so its behavior is pinned, not just
asserted. Two invariants are also guarded: rule_notes has no duplicate tags, and
every harness-tested tag has a rule_notes entry (the seed of a full "every emitted
tag is documented" cross-check). The linter lints its own harness, so keep it
lint-clean (it already caught a prefer-std-alias slip during authoring).

## Decision log (the reasoning behind the calls)

- **assertf > {} > unreachable.** assertf → unreachable in ship keeps the
  optimization hint + gives a checked-build diagnostic; `catch unreachable` is the
  only one that's UB in ReleaseFast if wrong. ⇒ catch rule targets BOTH `{}` and
  `unreachable`; there is no reason to ever write bare `catch unreachable`.
- **`catch {}` is legitimately correct** for writer/log ops and deliberate
  OOM-survivable degradation. Those become `lint:off`, never assertf (assertf would
  abort a checked build on a failure the game is meant to survive).
- **Naming + allocator-first skipped** on the shared test "mostly-respected +
  not-trivial-to-enforce + fights-our-canon." SCREAMING already handled.
- **No semantic analyzer.** The (a) approximation gets ~80% of the bug-catching
  value in one file; zlint's Symbol.Table/Scope.Tree is a multi-file undertaking we
  explicitly decline.
