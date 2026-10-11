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

## NEXT: walker coverage + the constructor-literal policy (plan, Oct 2)

### What is wrong
1. **A third walker blind spot.** `walkNode`'s generic descent walks a container's MEMBERS only when the container
   initialises a declaration (`const X = struct {...}`). A container reached any other way - `return struct { ... }`
   in `fn Foo(comptime T: type) type`, i.e. EVERY generic type - goes through `childNodes`, which yields no members.
   So no per-node rule has ever seen the methods of `Tensor(T)`, `Graph(T)`, the zimrnum builders... Proven by probe
   (`untyped-local` misses an untyped local there, on the old binary too). Same family as the `.assign` /
   `.while_cont` holes (594 findings: the lint ratchet) and the old non-recursive / tools/ scan holes - a blind walker
   reports "clean" exactly where it cannot see.
2. **`prefer-decl-literal` predates the policy below**: it would convert a declaration split across lines
   (`var x: T =` / `try T.init(...)`), whose `.init(` line no longer shows the type. (The 1160 zimrnum conversions are
   all one-line declarations - consistent with the policy; the one split site was converted only in a scratch copy.)
3. **Nothing enforces the policy the other way** - `.{ .bozo = .init(gpa) }` passes today.

### The policy (Simon, Oct 2)
- A CONSTRUCTOR-LIKE call (`init`, `create`, `alloc`, ... - vocabulary to settle, L6) may be written as a decl literal
  ONLY where its type is spelled on the SAME LINE: `const t: Tensor(T) = try .alloc(gpa, shape);` is fine;
  `const a: S = .{ .bozo = .init(gpa) };` is not (bozo's type is nowhere in sight), nor `return .init(gpa);`,
  `self.grid = try .alloc(...);`, `f(.init(x))`, or a declaration split across lines.
- Every other literal stays free: enum literals (`.red`), value decls (`.empty`, `.zero`), anonymous `.{...}`.
  A constructor call says WHAT is being built; those do not hide anything a reader needs.

### Steps (each ends with the tree green)
- **L0 (done Oct 2)** tree green: the new helper moved above its caller (decl-order); `zig build check` 358/358.
- **L1 A COVERAGE ORACLE** - find every blind spot at once, not one per incident. In zimrlint.zig (no new files): for
  one file, record every node `walkNode` visits and compare with the AST's own node list (indices 0 .. nodes.len)
  restricted to the kinds rules inspect - var decls, fn decls, container members, calls, blocks. Unvisited = a hole,
  printed with tag and line. Run it on a COPY of the whole tree to list every hole (container-as-expression is one;
  candidates to MEASURE, not guess: defer/errdefer bodies, comptime blocks, catch/orelse payload blocks, field
  defaults). Keep a unit test over a corpus of every construct asserting zero unvisited nodes, so a new AST shape
  cannot reopen a hole silently.
  **L1 DONE Oct 2.** `zimrlint --coverage <files>`: `Ctx.visited` (one flag per node, set at the top of `walkNode`),
  `walkCoverage` (the walk `runChecks` does, findings dropped), `unwalkedNodes` over the tracked kinds (declarations,
  calls, builtin calls, if/while/for/switch, catch/orelse, struct literals, field accesses), `runCoverage` (per-node
  lines + a tally by kind). Test: the known hole is found, a walked declaration is not. zimrlint 93/93; self-lint
  clean. FIRST MEASUREMENT (a copy of `check`'s 839 files; single core: run in two parts, ~7 min uncached): 125610
  tracked nodes never walked, in 717 files - field_access 86927, call_one 17608, call 10744, builtin_call_two 5046,
  simple_var_decl 2321, fn_decl 973, if_simple 587, if 433, for_simple 246, call_comma 155, for 119, orelse 117,
  switch_comma 80, catch 67, while_simple 47, struct_init_one 45, while_cont 33. READING IT: most field accesses and
  calls are read THROUGH their parents (type positions the type walker covers, callees, inner links of `a.b.c`), so
  the raw count overstates the blindness; the statement-shaped kinds have no parent that reads them - 2321
  declarations, 973 functions, ~1600 control-flow nodes - and are where L2 starts. Expected: the container-as-
  expression branch accounts for most declarations and functions; re-measure after it, then attribute the rest.
- **L2 Close the holes** - REVISED Oct 2 after measuring (below): not one branch per hole - a COMPLETE walk.
  STEP 1 MEASURED (scratch, the container-as-expression branch, same 839-file copy): unwalked tracked nodes 125610 ->
  112388; simple_var_decl 2321 -> 224, fn_decl 973 -> 180, if_simple 587 -> 52, for_simple 246 -> 45, for 119 -> 10,
  while_cont 33 -> 0, while_simple 47 -> 5 - most statement-shaped holes were that one branch. ATTRIBUTION of the
  76127 remaining ROOTS (outermost unwalked nodes, labelled by context): type positions after ':' '*' '!' '[' (~18000,
  the type walker's by design - to decide), `defer` / `errdefer` bodies (6386), `if` conditions (~9000), `for`
  operands and ranges (~3250), operands of binary operators (< >= + - and or &: thousands), struct-literal field
  values (`.target = b.graph.host`), array-literal elements, array-access receivers. ONE CAUSE: `childNodes` is a
  PARTIAL switch ending in `else => no children`, so every unlisted tag is a silent hole - found one per incident.
  THE FIX: `childNodes` becomes an EXHAUSTIVE switch over `Ast.Node.Tag` with NO `else` arm, each tag's children
  read through std's `full*` helpers and node data layouts - complete by construction, and a Zig upgrade that adds a
  tag is a compile error instead of a new blind spot. Then: decide type positions (walk them too, so no-qualified-std
  & co. see `std.mem.Allocator` in signatures? measured in L3); `--coverage` on the copy must report ~zero; the unit
  test grows a corpus of every construct asserting zero; std-math's per-index sweep may then rejoin the walk (or stay
  as belt and braces). Built and measured in scratch; lands at L4 with the ratchet.
  **L2 DONE in scratch, Oct 2 - THE WALK IS COMPLETE: 125610 -> 0 unwalked tracked nodes on the 839-file copy.**
  Saved as `src/notes/lint_complete_walk.patch` (applies to tools/zimrlint.zig as of L1; lands at L4, then delete).
  What it does: (1) `allChildren` + `ChildIterator` / `ChildBuffer`: an EXHAUSTIVE switch over all 163 node tags, no
  `else` (it compiled first time - every tag named, none missing), composites through std's `full*` helpers, lists
  as slices (no 8-child cap - `childNodes` cut calls at 7 arguments); (2) `walkNode`'s handlers complete: if/while
  conditions, while continue expressions, for inputs, switch case values, declaration type / align / addrspace /
  section, the fn prototype walked as a node; the fallback iterates `allChildren`; (3) `walkContainerChildren`
  through `fullContainerDecl` for EVERY container tag (it decoded 2 of 12: `enum(u8)`, `packed struct(u32)` and all
  tagged unions had never been walked) and walks the tag argument; `isContainerDeclTag` gains the tagged unions (its
  only user is the walker); (4) `walkTypeExpr` recurses through `allChildren`; (5) `--coverage` reports ROOTS
  (outermost unwalked nodes) labelled by context. Stages: container-as-expression 112388; allChildren 226 (all in
  tag-argument containers); containers 0. BEFORE LANDING (L3/L4): type rules now run twice on prototypes (the walk
  visits them, and `walkTypeExpr` still does) - drop the `walkTypeExpr` calls or the checks' second call site and
  test for single reports; the unit test grows a corpus of every construct asserting zero; the other `childNodes`
  users (3) move to `allChildren`; std-math's per-index sweep stays as belt and braces.
  (Originally: one branch each where possible; the container-as-expression branch is written and
  verified in scratch (probes; `--fix` on pre-conversion zimrnum reproduces the verified 1160 sites byte for byte).)
- **L3 Measure the ratchet ON A COPY** - the 53 enforced rules over the newly visible code: (file, rule) counts above
  `tools/lint_baseline.tsv`, split into autofixable and manual. Decide from the numbers.
  **L3 DONE Oct 2 (on the copy, the 721 files `check` really lints - the build also skips the vendored std cli
  `src/cli*`, `notes/staging/`, `webtests/external_project`, `tools/c2js_cases`).** The committed walker: 0 findings
  there (the green `check`; the baseline is EMPTY - nothing grandfathered, so every new finding would fail `check`).
  The complete walk: 1967 distinct findings, all genuine on sampling (code never seen: generic types' methods,
  conditions, declaration types, field defaults, struct-literal values, tag-typed containers) - 1618 in rules WITH
  an autofix (no-qualified-std 1319, no-qualified-zm 285, float-from-int 14) and 349 manual (prefer-std-alias 99,
  untyped-local 77, fn-args-multiline 54, branch-braces 50, int-from-float 32, useless-error-return 13 - some may be
  signatures fixed by a fn-pointer type, review -, reserved-math-names 8, clamp-pattern 7, as-round 3,
  import-at-top 2, prefer-assert-unreachable / turn-in-radian-call / catch-suppression / anon-return 1 each).
  DUPLICATES: 107 at first (fn-args-multiline 53, no-qualified-std 53, anon-return 1) - the prototype checked by
  hand in the fn_decl handler (turn 348's fix for the old blind walk) AND walked. Fixed in scratch: ONE WALK -
  `walkTypeExpr` and all three call sites removed, the handler keeps only what needs the name or body; re-linted:
  1967 findings, 0 duplicates, the identical distinct set (lost 0, gained 0). The patch includes it.
- **L4 IN DETAIL (plan, Oct 2, Simon: "improve the autofix system a bit; many fixes by hand - each an opportunity
  to improve the code; work without recompiling too often").**
  PRINCIPLE. A by-hand fix is a small code review, not a silencing edit: read the function around the finding and
  fix it the way that also makes the code better - a named type where an annotation would only repeat noise, the
  rounding the code actually means, a signature without a needless error union, a better name than one shadowing
  zm. Patterns noticed go in a short list here, so similar sites get the same improvement.
  THREE TIERS OF VERIFICATION (measured on zimrnum.zig, 40k lines):
    T0, per edit, instant - `zig fmt` (0.04 s) + `zig ast-check <file>` (0.24 s). Proven to catch: syntax errors, a
        rename that missed a use (undeclared identifier), an alias that collides (shadowing), an unused local.
        Not types: `const wrong: bool = @as(u32, 3)` passes.
    T1, per file, seconds - the new zimrlint on that one file with the enforced rules (27 s for the largest file,
        a few for most): the finding is gone and nothing new appeared.
    T2, per BATCH, minutes - `zig build check` (~4 min warm: the compiler's type checking and the whole-tree lint),
        plus the module tests a batch can change the behaviour of (`zn-zimrnum` ~3 min, ...). Never per site.
  WHICH FIXES NEED WHICH TIER.
    Syntax only - safe at T0 + T1: branch-braces, fn-args-multiline, import-at-top (a move).
    Binding - T0 catches their failure modes (shadowing, undeclared): prefer-std-alias, no-qualified-std / zm,
        reserved-math-names (renames).
    Typed or behavioural - T2: untyped-local (the annotation must be the right type), int-from-float, as-round,
        clamp-pattern, float-from-int (conversions), useless-error-return (a signature change ripples to callers).
  - **L4a Autofixes, a bit more** (the triage in lint_autofix.md §6 already rates them A1 / A2): fn-args-multiline
    (A1: a trailing comma after the last parameter; the fix loop's fmt pass reflows), branch-braces (A1: wrap the
    body statement in `{ }`), prefer-std-alias (A2: file-scope alias + rewritten uses, reusing no-qualified-std's
    alias machinery). Each with unit tests and negative controls, in the scratch with the complete walk; measured
    on the copy: 349 by-hand findings -> 146. int-from-float stays BY HAND on purpose: choosing trunc / floor / round
    is exactly the improvement (lint_autofix.md: "emit, don't silently guess").
    L4a PROGRESS Oct 2 - fn-args-multiline and branch-braces DONE, in the real tools/zimrlint.zig (they change no
    `check` result: only `--fix` uses an edit). fn-args-multiline: `closingParen` (new: counts nesting forward from
    the prototype's `lparen`) and one `,` inserted before it - none when a trailing comma is already there (fmt alone
    is the fix). branch-braces: `emitBranchBraces` replaces the body with `{ body; }`, swallowing the `;` that ended
    the statement (a block-bodied if/while/for takes none) but never an `else` or a prong's `,`. Tests apply the fix
    and run std's `renderAlloc` (zig fmt's renderer) - parses, rule silent; a trailing comma already there gets a
    report without a fix. Negative controls: the comma after the `)` fails the first; leaving the `;` outside fails
    the second. NOTE: `--fix` does not format - `zig build fix` is `--fix` THEN `zig fmt`; the two comments that said
    otherwise were corrected. Dogfood: the linter fixed its own two findings (a 4-parameter helper, a `std.mem.sort`
    -> `sortSlice`), fmt reflowed, self-lint clean; zimrlint 95/95. ON REAL CODE (the 25 files holding all 104
    findings, copied, the complete walk): fix + fmt -> 0 left, every file passes `ast-check` (syntax-only fixes:
    T0 + T1 is their whole verification). A RULE GAP noticed: branch-braces does not look at `.while_cont`
    (`while (c) : (i += 1) x;`) - to widen later, measured like any rule change. Left in L4a: prefer-std-alias.
    L4a PART 2, Oct 2 - prefer-std-alias FOLDED INTO no-qualified-std (the vocabulary's own doc had said "until that
    rule folds in"): its 16 names (ArrayList, ArrayListAligned, fmt.bufPrint / allocPrint, all 12 testing.expect*)
    joined `std_vocabulary`; the rule, its check, its catalog entry and its LintRule field are gone; no-qualified-std's
    stale "(advisory)" removed; a test - `std.ArrayList` gets its binding (pass one), then its bare use (pass two).
    NOT LANDABLE ALONE: with TODAY's walker the fold reports 132 new findings in 27 files (std.ArrayList 115 in
    signatures and field types the body-only rule never saw; expect* 16; allocPrint 1) - all autofixable, but they
    would turn `check` red or force autofixes before the next full build. So it rides L4b.
    THE L4b PACKAGE is now ONE patch, `src/notes/lint_l4b.patch` (tools/zimrlint.zig + build.zig, `patch -p1` from the
    repo root; verified to reproduce the scratch) = the complete walk + one walk + coverage roots + the fold, on top of
    L4a. (It supersedes lint_complete_walk.patch.)
    FOUND WHILE TESTING THE PACKAGE (the complete walk's first unit-test run - L2/L3 only measured): 3 of 96 fail.
    (a) coverage's test asserts the returned struct's declaration is UNWALKED - must flip to "zero unwalked".
    (b, c) two no-qualified-zm tests: `zm.Vec3` in a SIGNATURE is now reported. `Vec3` IS a keyword (the keyword
    table, line ~660: Vec3, Vec2, Quat, Color, Ray, Mat3...); the test's comment "not a keyword" predates that, and it
    passed only because signatures were never walked by this rule. A SCOPE DECISION FOR SIMON: keywords bare in
    bodies only (the rule's wording, "in a body") or EVERYWHERE - signatures, field types (one way; what
    no-qualified-std already does). Then the tests and the message follow the answer.
    ALSO: L3 overstated what is autofixable - no-qualified-zm's fix only drops `zm.` when the file ALREADY binds the
    name; unlike no-qualified-std it cannot insert a missing binding. Give it the same two-pass fix (insert the
    binding, then the bare use) - the binding line is `const X = zm.X;` - and re-measure the by-hand count.
    And one line in the scratch's coverage attribution is 213 columns.
    DECIDED (Simon, Oct 2): zm keywords are bare EVERYWHERE - bodies, signatures, field types (one way, as
    no-qualified-std). In the package: the message, the catalog entry, the check's doc and the keyword table's doc no
    longer say "in a body"; test 69 binds `Vec3` too (it is about the drop-`zm.` fix), test 70 uses a real non-keyword
    (`matFromAxisAngle`), a new test pins the decision (a parameter, a return type and a field type are each
    reported, each with the drop-`zm.` fix); the coverage test flipped to "zero unwalked"; the 213-column prong list
    wrapped. AND no-qualified-zm's TWO-PASS FIX: a missing binding is inserted (`const X = <root>.X;`, the file's own
    zm root, at `bindingInsertOffset` - std's insertion point, renamed: it was generic in its roots already), the next
    pass drops each `zm.`; every use asks for the same insertion, so one binding. NOT when the name is already
    declared in the file (`declarationCount`, the token test no-qualified-std's pre-pass uses): the binding would
    collide, and no parse check would notice. Tests: two uses -> one binding, then both bare, clean; a parameter
    named `clamp` -> reported without a fix. Negative control (no guard) fails exactly the collision test. The
    package: 99/99. NEXT: re-measure the by-hand count on the copy with this fix.
    THE AUTOFIX HINT (Simon, Oct 2: "inform the user about the command to autofix") - LANDED in the real tree:
    every fixable finding ends with ` - autofix: <command>` and the summary adds "K of the findings can be fixed
    automatically: <command>". Decided by the finding's `fix`, never by a rule's wording - so the ad-hoc
    "(`--fix` rewrites it)" phrases left the messages (3 real, 1 in the package). The command comes from the caller:
    `--fix-command` (new); zimr's build passes `zig build fix`; without it, "rerun this command with --fix". APPS GOT
    A `fix` STEP: `LintOptions.fix` / `.fix_command`, and the project helper's `fix` = lint `--fix`, then zig fmt
    over its lint dirs (type-checked through the template's step list; its header lists it). Test: printIssues ends a
    fixable line with the hint, leaves the others alone, counts them. 96/96; `check` 358/358. The L4b package rebased
    on it (clean apply), 100/100, patch verified.
    RE-MEASURED WITH THE WHOLE PACKAGE (Oct 2; the 721-file copy; fixability read off each finding's new
    "- autofix:" marker, so per finding, not per rule): 2009 findings - 1849 autofix (no-qualified-std 1457,
    no-qualified-zm 276, fn-args-multiline 54, branch-braces 50, float-from-int 12) and 160 by hand. One of those was
    `src/codecs.zig`'s FILE-LEVEL `//! lint:off prefer-std-alias` - an `unknown-lint-tag` now the rule is retired (an
    earlier search, cut at 20 lines, had missed it). Deleting it is part of retiring the rule, so the package carries
    it (3 files now: zimrlint.zig, build.zig, codecs.zig): without it codecs.zig has 106 findings, ALL autofixable -
    no-qualified-std's collision guard covers the clash the directive had guarded. BY-HAND WORKLIST: 159 in 37
    files - untyped-local 79, int-from-float 32, useless-error-return 13, no-qualified-zm 9 (all runtime.zig:
    per-struct `Vec2` / `Mat` bindings, so the guard rightly withholds the fix - an improvement: one file-scope
    binding instead), reserved-math-names 8, clamp-pattern 7, as-round 3, import-at-top 2, float-from-int 2 (shapes
    its fix does not take), and 4 singles. Largest: entities.zig 38, gpu/zn_conformance.zig 16, utils.zig 14,
    zimrnum.zig 10, runtime.zig 9.
    THE L4b DRY RUN (Oct 2; a fresh copy of the 721 files as the landing sees them): one `--fix` (6 min, 163 files,
    1368 edits, nothing visibly refused), `zig fmt` (18 files), ast-check (719 / 721: the 2 failures are notes/scripts
    excerpts that fail identically untouched), re-lint: 642 STILL FIXABLE + 160 by hand. A second `--fix` on the 21
    files holding the 642 applied ZERO edits - and the run still printed "642 can be fixed automatically", a hint
    that was false for them. Two bugs, both real:
    (1) SILENT, TOTAL ROLLBACK. Bisected on codecs.zig (no-qualified-std's fixes alone: 0 edits) and a scratch
    diagnostic (no single fix breaks the file - a combination of 81 does): `collectFixes` sorted by START ONLY and
    dropped an edit only when equal to the one kept just before it, so two names' bindings at one spot interleaved
    (A, B, A, B) and the second A was inserted again - a redeclaration, AstGen failed, the guard discarded the
    file's whole pass, silently, every time. FIXED in the package: sort by start, end, then text (identical edits
    adjacent; the bindings at a spot come out sorted, the same every run); a test reproducing the interleave; its
    negative control (start only) fails it. Package 101/101.
    (2) A REWRITE ABOVE ITS BINDING. wgpu_app.zig already had `const Vec2 = zm.Vec2;` at line 1768, far below the
    header; the drop-`zm.` fix turned `zm.Vec2` at line 1312 into `Vec2` - a decl-order violation the fix created.
    TO FIX NEXT (both no-qualified-zm and no-qualified-std): offer the rewrite only when the binding is declared ABOVE
    the use; otherwise report without a fix - by hand: move the binding into the header (an improvement in itself).
    STILL TO ADD (usability): a rollback must never be silent - name the file and the AstGen error, and keep its
    findings from claiming "autofix". Then re-run the whole dry run.
    BOTH BUGS FIXED (Oct 2), in the package: (2) `fileScopeBinding` returns the binding's first token (was a bool,
    `fileScopeBinds`), and both rules rewrite a qualified use only BELOW its binding - above it, a by-hand report:
    "this file binds `X` only below this use (line N): move that binding up with the others". (Robustness) A pass
    that breaks a clean file is no longer thrown away whole: `applyFixesGuarded` applies its fixes one at a time from
    the last, keeps each that leaves the file clean, refuses the rest; the loop goes on while anything applies.
    `FixOutcome.refused_any` replaces `rolled_back`; the old message ("skipped a fix that would break parsing") is
    replaced by an honest one, refused findings print "refused here (it would break this file) - by hand", and the
    summary counts them apart. Tests: a binding below the use (both rules); a guarded pair that only clashes together
    (one kept, one refused); negative controls fail exactly their own tests. Package 103/103, patch verified.
    THE DRY RUN AGAIN (fresh copy, as landed): ONE `--fix` (387 s, 183 files, 2079 edits - 1368 before, when 21
    files lost everything), fmt (25 files), ast-check: only the 2 pre-existing notes excerpts, re-lint: 160 BY HAND
    and ONE fixable - features_test.zig:186's float-from-int, whose fix the run REFUSED (it would not compile there)
    and marked for a human. So one `zig build fix` converges. By hand: untyped-local 79, int-from-float 32,
    useless-error-return 13, no-qualified-zm 10 (runtime.zig 9, guarded; wgpu_app.zig's late `Vec2` 1 - a
    decl-order break before, an honest report now), reserved-math-names 8, clamp-pattern 7, as-round 3,
    import-at-top 2, float-from-int 2, 4 singles - plus that 1 refused = 161. NO decl-order. TO TIGHTEN (small):
    float-from-int should not offer a fix whose replacement cannot resolve (check `float` is bound, as the std/zm
    fixes check), so a plain lint stops calling it fixable. What only the real build can verify: semantics -
    float-from-int's rewrite and the binding renames (pure aliases) - which is what L4b's full build is for.
    L4b LANDED (Oct 2), then LINT TURNED OFF (Simon): the patch applied cleanly (zimrlint 103/103); `--fix` now
    exits 0 unless an input failed (a fix run rewrites, it does not gate - before, any by-hand finding stopped `zig
    build fix` ahead of its zig fmt); `prefer_decl_literal` joined `zimr_lint_rules` (one LOGICAL line - L5 retired);
    `zig build fix`: 102 s, 270 files, 3094 edits, 1 refused (features_test.zig), fmt clean. The package's own
    zimrlint.zig had 12 findings the complete walk now saw (a decl-order from the zm fix - repaired with
    `--reorder-decls`; `isStdRoot`, dead since the fold - removed; 10 untyped locals, 9 in the coverage attribution
    - typed): now 0 with no baseline. Baseline written: 160 findings, 47 lines, header restored. THE GATE FAILED ON
    LINT: the build passes paths as `./src/...` and the baseline was written with `src/...` - nothing matched. Simon
    then asked to comment every rule out of `zimr_lint_rules` for now (an empty `--enable=` checks nothing; `zig
    build lint` passes). NOT YET VERIFIED: the fixed tree's compile and tests (the gate stopped at lint, and the
    compiles are gated on it), and the tutorials' code folds (zimrnum.zig changed under the fixes; the gate's
    doc-folds regenerates them). TO RE-ENABLE: uncomment the list; regenerate the baseline from the build's own
    paths; run the gate.
    LINT RE-ENABLED, TREE GREEN (Oct 2): the rule list restored (53, prefer_decl_literal included); the baseline
    regenerated THROUGH THE BUILD (`zig build lint -- --write-baseline`: its own `./src/...` paths) - 163 findings in
    50 lines, header restored with that command; `zig build lint` passes. FIRST COMPILE OF THE FIXED TREE: `check`
    358/358 except doc_folds (the tutorials' excerpts quoted code the fixes changed) - regenerated (robot-mocap 29 of
    196 blocks, zimrnum's 342 folds), then 358/358. THE GATE: 402/406, 337/337 tests - two real failures: the
    TEMPLATE's build.zig still enabled the retired `prefer_std_alias` (a search cut at 20 lines had missed it - the
    second time) - removed, no_qualified_std already there; and doc-sync: robots.html quoted 4 lines the fixes
    rewrote (`std.mem.eql` -> `eql`, `*std.heap.ArenaAllocator` -> `*ArenaAllocator`, `std.testing.allocator` ->
    `testing_allocator`, `try Data.init(...)` -> `try .init(...)`) - updated to the code as it now reads. Then the
    template's own lint: one finding (`zm.Camera3D` in a signature) - fixed by the template's NEW `zig build fix`
    (binding + bare use, 2 edits). GATE 406/406. L4b is DONE; next is L4c, the by-hand burn-down (163).
    L4c STARTED (Oct 2) - and the first batch found a LINTER bug first. entities.zig's list held
    `pub const TagEnum = ...` inside a file-scope `union(enum)` as an untyped LOCAL. Cause: L2's edit meant for
    `isContainerDeclTag` (add the six tagged-union tags) had landed in `checkAnonReturn`'s container list instead -
    its anchor, a switch tail, matched there, the single-match check passed, and nothing checked WHICH function it
    edited; coverage still reached zero because a tagged union's members took the generic descent (visited - but as
    expressions, so its declarations were linted as statements). Fixed: `checkAnonReturn` restored byte for byte;
    `isContainerDeclTag` gains the six tags (verified inside the function this time); a regression test. 104/104;
    `check` 358/358; baseline regenerated through the build: 163 -> 161. LESSON: after an anchored edit, check the
    text of the FUNCTION it was meant for, not only the match count. NEXT: entities.zig's 36 (35 untyped locals - the
    newly visible methods of its generic types - and `pub const max` in an `enum(FlagInt)`, reserved-math-names).
    L4c BATCH 1 DONE (Oct 2) - src/entities.zig, 36 findings, ONE compile: 35 untyped locals typed from their
    sources (`*Slot`, `SiblingIterator`, `AncestorIterator`, `PreOrderIterator`, `PostOrderIterator`,
    `Handle(T_primary)`, `?*Self`, `u64`, `Subcmd.TagEnum`, `*const anyopaque`, `CmdBuf.Iterator`,
    `CmdBuf.Batch.ArchChange.Iterator`; comptime type values `: type`; the generic field read
    `@FieldType(T_composite, "primary")`). Improvements on the way: `bytes` had taken the address of a temporary
    slice (`&items[a..][0..n]`) though only `.ptr` was read - now the slice it means, `[]u8`; `CompFlag.max` (zm's
    `max`, reserved) is `CompFlag.capacity` - what it is, the number of flags the type can hold (11 places). T0
    caught one `ambiguous reference` (`Iterator` named both ArchChange's and CmdBuf's) - written
    `ArchChange.Iterator`, which says which. T1 0; T2 `check` 358/358; baseline 161 -> 125.
    L4c BATCH 2 DONE (Oct 2) - src/gpu/zn_conformance.zig, 16. The 11 useless-error-return were FALSE POSITIVES:
    each `fn f(...) anyerror!void` is a function LITERAL, `.cpu = struct { fn f ... }.f`, whose signature the table
    field dictates (`cpu: *const fn (out: Tn, a: Tn, b: Tn) anyerror!void`). Fixed in the linter, not with 11
    lint:offs: `isFunctionLiteral` (the member named right after its container's closing `}` - helpers beside it stay
    ordinary) exempts the idiom from useless-error-return; a test (a literal exempt, an ordinary fn reported) and a
    negative control. The 5 reserved-math-names: a local `vec` (zm's word) for the output's first `side` values seen
    as a 1-D tensor -> `output_row`. T0, T1 0, T2 `check` 358/358; zimrlint 105/105; baseline 125 -> 109
    (useless-error-return 13 -> 2 tree-wide).
    L4c BATCH 3 DONE (Oct 2) - src/utils.zig, 14 untyped locals in the bounded array (BoundedArrayAligned) and its
    writer: `T` from `get`, `*T` from `addOne`, `[]const T` subslices, `usize` arithmetic, `Self` via `try .init(...)`
    (the declaration names the type), `[]T` where `slice()` returns `[]align(a) T` (the alignment matters only to
    the buffer; the coercion is safe), `[]const u8` for a writer's splat pattern; `newlen` -> `new_length`. T0, T1 0,
    T2 `check` 358/358 on the first try.
    L4c BATCH 4 DONE (Oct 2) - src/zimrnum.zig, 10 + the advisory split DataLoader declaration. anon-return:
    `sumValid`'s anonymous `struct { total: T, count: usize }` is now `Series(T).ValidSum` (and `meanValid`'s
    `summed` is typed by it; a reference row). The layers' `attach` results typed by their OWN nested types -
    `Attention(T).Attached`, `Dense(T).Attached` (plain `Attached` would be the block's) - and in `Chain`'s generic
    loop `const Layer: type = @FieldType(Layers, layer_name); const attached: Layer.Attached = ...` (the layer type
    named, also keeping the line in 120). int-from-float, each by what it means: `@intFromFloat(@round(row))` was
    already rounding -> `@round(row)`; two test indexes from floats holding exact integers -> `@round(...)` (says
    it, and survives a 2.9999999). `try DataLoader(f64).init` on a split declaration -> `try .init` (one logical
    line). T0, T1 0; `zn-zimrnum` 325/325; `check` 358/358; zimrnum tutorial folds regenerated (774 rows); baseline
    95 -> 84.
    L4c BATCH 5 DONE (Oct 2) - src/runtime.zig, 9 no-qualified-zm. The file aggregates former files into
    namespaces ("was: src/core.zig"), and each namespace still re-bound its own zm names - leftovers of the old files'
    imports, not a design: `core` bound `Vec2` yet `getWindowScaleDPI` still wrote `zm.Vec2`. Seven names (Vec2,
    Mat, Camera2D, Camera3D, Ray, radFromDeg, sqrt1_2) are now bound ONCE in the file header and the 10 per-namespace
    copies are gone (they would shadow it - T0 confirmed none was left); then the autofix made all 9 uses bare. T1
    0; T2 `check` 358/358; +16 / -22 lines.
    L4c BATCH 6 DONE (Oct 2) - src/shader_runtime_wgpu.zig, 7 untyped locals: `usize` counts, the bind-group
    resources typed by their arrays (`wgpu_texture.WgpuTexture`, `StorageBinding`), the encoded blobs `[]u8`, a
    comptime `@tagName` as `[:0]const u8` (still comptime-known - it feeds a `++` compile error), a comptime index
    `usize`. T0, T1 0, T2 `check` 358/358 first try.
    L4c BATCH 7 DONE (Oct 2) - int-from-float, 29 sites in 11 files, each by what it means: 22 colour channels ->
    `@round` (quantising rounds to nearest; truncating biased every shade darker - ranges checked so none can round
    to 256: anchors <= 253, factors <= 1, fog/gradient clamped, alpha slider <= 255); 4 n-patch borders, a render
    texture's size, a font's base size -> `@round` (whole pixels); 2 time-to-sample indices -> `@floor` (the sample
    at or before t); and robot.zig's `steps = 1.0 / dt` -> `@round`, which FIXED A LATENT BUG: in f32, 1/(1/500) is
    499.99997, so "after one second" in the integrator test ran 499 steps (0.998 s) against a reference at 1 s -
    likewise at 1/1000 and 1/60. Comments where the choice carries meaning. T0, T1 0; T2 `check` 358/358 and
    `test-fast` 17/17 steps, 622 tests (the integrator test runs - it has no skip).
    L4c BATCH 8 DONE (Oct 2) - the last 14 untyped locals, across 10 files. `held()`'s anonymous
    `?struct { first: u64, last: u64 }` is now `Resident(M).HeldSteps` - the reason its caller's `range` had no type
    to write. compute_host's two `dst` pointers name `field_name` first, then `*@TypeOf(@field(wk.mirror.*,
    field_name))` (the file's own typed form, shorter). jobs' kernel loop: an EXPLAINED lint:off - each entry's
    kernel is its own function type, no one type fits (restating `@TypeOf(entry[1])` would say nothing). The rest
    typed from their sources (`Ppo.Staged`, `[]const u8`, `usize`, `f32`, `BufferHandle`, `Self`, `u32`,
    `std.heap.Check`, a map's `.Iterator`). A misread on the way: my listing printed each flagged line with the one
    above it, and wgpu.zig:1915 is `buf`, not the `size_bytes` above it (whose `@as` already shows its type) - the
    line-anchored edit refused, as it should. T0, T1 0; `check` 358/358; `test-fast` 17/17 (612 + 89 skipped in the
    main step; two small steps cached - not lost); robot-mocap tutorial: 1 fold regenerated. Baseline 39 -> 25.
    L4c BATCH 9 DONE (Oct 2) - clamp-pattern, 7 sites: `@max(lo, @min(hi, v))` -> `clamp(v, lo, hi)`. zm's clamp
    is `min(hi, max(lo, v))` - the other nesting; with constant bounds lo < hi the two agree on every number and
    differ only on NaN (the old sent it to hi, clamp to lo): the z-score's deviation carries +1e-8, so a NaN there
    means the observation itself was NaN; the Julia colours come from 0.5 + 0.5 cos(...), always in [0, 1]. On the
    six colour lines, batch 7's convention too: `@trunc` -> `@round` (range [0, 255] - no overflow), with its
    comment; `clamp` bound in the two examples' headers. T0, T1 0; `check` 358/358; `test-fast` 612 + 89 skipped.
    L4c BATCH 10 DONE (Oct 2) - the robot family's 6, and a CASCADE. Renames: robot_ppo_track's `normalize` (zm's
    word) -> `normalizeObservations` (8 calls); robot_track_resident's pub `round` -> `simulateAndTrain` (its doc's
    first line; 3 test + 2 example callers; the robot-mocap tutorial's fold key `data-decl`). `0.5 * @sin(2.0 * pi *
    t)` -> `0.5 * sinTurns(t)` (one cycle per unit of t is turns). The test's best-effort `deleteFile ... catch {}`:
    an explained lint:off, the convention snapshot_regression_test already uses. The two useless `!` (`update`,
    `uploadParameters`) dropped - and dropping their callers' `try` left THOSE callers' `!` useless too: `learn`,
    `iterate` (collect returns a plain bool) and `setParameters` (no callers; no interface shares it) followed, 10
    test call sites lost a `try`, and two examples (geno_ppo, getup_train) lost an `if (learn()) |stats| ... else
    |err|` branch handling a failure that could not happen - straight-line now. T0, T1 0; doc-folds 4 regenerated, 0
    errors; doc-sync 0 drifted; `check` 358/358; `test-fast` 612 + 89 skipped.
    L4c BATCH 11 - THE LAST 12 - AND THE BASELINE IS EMPTY (Oct 2). Frame indices inside format-argument tuples
    named first, so they have a type: `const current_frame: usize = @floor(...)` (the frame at or before t); mocap
    viewer's frame COUNT straight from the integer `keyframeCount`, not back out of its f32 copy. Two split
    declarations that name their type -> `.init(...)`, each one line again. `assertf(false, @src(), ...)` ->
    `assertUnreachable(@src(), ...)`. draw3d's two inline `@import("builtin")` -> one file-scope `builtin`.
    wgpu_app's late `Vec2` binding up into the zm header; its use bare. float-from-int in a test and a standalone
    tool (no zm there): a named f32 local takes the bare builtin (`sample_count`, `take_frames`, `text_bytes`) - the
    rule's point was the redundant `@as`, and no import was needed. T0, T1 0 in all 8 files; THE FULL GATE 406/406,
    618 tests (89 skipped); baseline regenerated: 0 lines - restored the EMPTY header. L4c DONE: 172 by-hand findings
    over ten batches, two linter bugs found and fixed on the way (tagged-union members linted as statements; the
    function-literal idiom flagged), one latent test bug (499 steps for one second), dead error branches removed.
    NEXT in this plan: L4d (keep `--coverage` at zero), L6 (the converse constructor-literal rule).
  - **L4b Land, at the next full build** (with L7's prefer-decl-literal, as Simon asked for that autofix): the
    complete walk + L4a into tools/zimrlint.zig; `--fix` on the tree with every rule that has a fix (1618 + 203
    sites); fmt; T2 once (check, plus the module tests the conversions touch); `--write-baseline` for the 146 left
    -> `check` green, the backlog is ONE file, `tools/lint_baseline.tsv`, and it only shrinks.
  - **L4c Burn down by hand, in batches.** The baseline IS the worklist: (file, rule, count). A batch = one module
    (a file or a few related files), 10-30 findings, read once with its context hot, worked syntax -> binding ->
    semantic. Per file: list its findings (T1), fix each as an improvement, T0, T1. Per batch: T2 once, then
    `--write-baseline` (the batch's lines disappear) and a journal line on what improved. ORDER - half the backlog
    is four files: entities.zig (36: untyped-local 35), gpu/zn_conformance.zig (16: useless-error-return 11 - check
    first whether a fn-pointer type dictates those signatures -, reserved-math-names 5), utils.zig (14:
    untyped-local), zimrnum.zig (10); then the 31 files with 1-7 each, grouped by area (examples' int-from-float
    together: one rounding decision, applied consistently). Today's remainder: untyped-local 77, int-from-float 32,
    useless-error-return 13, reserved-math-names 8, clamp-pattern 7, as-round 3, import-at-top 2, 4 singles.
  - **L4d Done when** the baseline is empty again; `--coverage` over the tree is the periodic audit (it must stay at
    zero - and a Zig upgrade that adds a node tag stops at `allChildren`'s exhaustive switch).
- **L4 Land the walker fixes + the ratchet** - apply only the safe autofixes the new findings have (then compile and
  test), regenerate the baseline DELIBERATELY for the rest (`--write-baseline`), so `check` stays green and the
  backlog is one visible file that shrinks by deleted lines.
- **UNCONFIRMED - written by a turn whose output Simon never saw (it ran on after he stopped seeing it; he then asked
  "Stuck?"). Nothing in the conversation shows Simon saying this; his stated rule is "the type spelled on the SAME
  line". Until he confirms: the three split declarations that turn's fix had converted (codecs.zig flate.Compress,
  draw3d.zig AutoHashMap, zimrnum.zig DataLoader) were restored to `Type.fn(` by hand; they now show as advisory
  prefer-decl-literal findings, and `zig build fix` would convert them again.**
  L5 RETIRED (Simon, Oct 2): "same line" means the same LOGICAL line - the declaration itself. A declaration
  split for length (`var x: T =` / `try T.init(...)`) still names its type, so `.init(...)` is fine there; and
  `prefer-decl-literal` already requires the annotation on the declaration it initialises - nothing to restrict. It
  joined `zimr_lint_rules` at the L4b landing (advisory; `zig build fix` converts every site). For L6, "in view" =
  the type is written in the same declaration or statement, not merely on the same physical line.**
- **L5 (as first planned) `prefer-decl-literal` under the policy** - fire only when the annotation and the call's `.` share ONE line;
  the split declaration then stays as written. Tests for both shapes.
- **L6 The converse rule** (name to choose, e.g. `constructor-literal-in-view`) - a decl-literal call to a
  constructor-like name whose type is NOT on its line: a struct-literal field, an argument, a `return`, an
  assignment. (A split declaration is ONE logical line - allowed; Simon, Oct 2.) NO autofix: the AST does not know a field's, parameter's or return slot's type -
  that is a human's (or a type-aware tool's) call. Advisory first; measured on a copy; existing sites fixed by hand or
  given an explained `lint:off`, then it graduates. VOCABULARY DECIDED (Simon, Oct 2): a BIG, opinionated list - one
  way to do things; creating something, above all something that owns memory, must say what it creates. Prefixes:
  `init`, `create`, `alloc`, `new`, `from`, `clone`, `dupe`, `copy`, `make`, `build`, `load`, `open`, `parse`,
  `spawn`, `decode` - each with its compounds (`initCapacity`, `allocSentinel`, `fromSlice`, ...). Finalised at L6
  against the tree: every decl-literal call name in it listed and classified, so the list is checked, not guessed.
  INVESTIGATED (Oct 2) with a census - a scratch whole-file check, kept as `src/notes/l6_census.patch` (apply to a
  scratch copy; it emits `census <name> <position>` under prefer-decl-literal's tag; never landed). Every decl-literal
  call in the 721 linted files: 3577 in 230 files, 52 names; IN VIEW (a typed declaration's initializer, through
  try / catch / orelse / parentheses / if branches - a split declaration counts, the logical line) 3422 = 95.7%.
  With the prefix vocabulary the converse rule would flag 143: MEMBER ASSIGNMENTS 84 (`s.world = try .init(gpa,
  256);` - examples' setup, robot files), struct-literal fields 23 (`return .{ .layers = .{ try .init(...), ... } }`),
  local assignments 19, tuple elements 9, arguments 5 (+2 under `comptime`), a return 1. Hot files: robot_gym 28,
  zimrnum 15, robot_supertrack 12, robot_latent 11, entities 10, codecs 9, robot_geno 9. The vocabulary covers 31
  of the 52 names - every memory-owning constructor; outside it: combine compute cwd empty fit fixed forActionDim
  lerp limited of over pack path read reserve reserveImmediateOrErr resolve skew stdin stdout submitAll (mostly
  operations). A typed array literal `[_]T{ .init(...) }` puts T in view - zero such sites, but the rule must know.
  The census also taught: `s.rng = .init(...)` and `.{ .rng = .init(...) }` look alike to a token scan - the rule
  must tell a member assignment from a literal field (the `.` after `{` or `,`, vs after an expression).
  OPEN DECISIONS (Simon): (1) member assignments - 84 of the 143; (2) std VALUE constructors passed as arguments -
  `.of(u32)`, `.limited(n)` (outside the list) and `.fromByteUnits(n)` (inside, via `from`): exempt by name?
  (3) `.empty(es)` - a function creating empty lists, 4 out of view: into the list? (4) the fix: spell the type at
  the call (`World.init(gpa, 256)`) or a typed local first; a semi-autofix is possible where the field's declaration
  sits in the same file (`self.x = .init` in a method, `.{ .x = .init }` returned as Self).
  DECIDED AND BUILT (Oct 2). Simon: the rule must be simple to understand and must not depend on type or variable
  names - and ASSIGNMENTS ARE IN (`foo.bar = .init(gpa)` is not good, whatever bar is). So: a decl-literal call to
  a constructor-like name is allowed ONLY as the value of a declaration that names its type (through try, both
  sides of catch / orelse, parentheses, if / else, switch prongs; split declarations are one declaration);
  anywhere else - assignment, struct-literal field (even inside a typed declaration: `.{ .t = .init(4) }`),
  argument, return, tuple element - spell the type. No exemptions: `.of(u32)` and `.limited(n)` pass only because
  they are not constructor names; `.fromByteUnits(n)` is one, and is reported; `.empty(...)` is not in the list.
  Landed as `constructor-in-view`, ADVISORY: catalog note; `constructor_prefixes` + `isConstructorName` (a prefix
  alone or continued in uppercase); `markDeclarationValue`; `checkConstructorInView` (two passes over the nodes,
  run from runChecks); the LintRule enum entry in build.zig - NOT yet in `zimr_lint_rules` (143 advisory lines on
  every lint until fixed). Tests: the allowed forms clean; the five forbidden forms reported; names outside the list
  left alone; negative control (no try arm) fails the allowed-forms test. zimrlint 108/108; self-lint clean (its
  one finding is build.zig's `cache.* = .init(...)`); `check` 358/358. Over the tree: 143 in 34 files - the census
  exactly (init 136, initMany 2, fromByteUnits 2, initOne, initFill, fromMilliseconds). NEXT: fix them by hand in
  batches (robot_gym 28, zimrnum 13, robot_supertrack 12, robot_latent 11, robot_geno 9, codecs 9, ...), then the
  rule joins zimr_lint_rules and graduates from advisory.
  REFINED - BARE WORDS ONLY (Simon, Oct 2): "`foo.bar = .initBozo(gpa)` should be allowed. What I don't like is
  bare init, even if I actually like the convention of calling constructors init." So the prefix-and-uppercase
  compounds are gone: the rule matches the 15 constructor words WHOLE (`constructor_words`, `isBareConstructorWord`).
  A longer name carries its own words - `.initBozo` even names what it makes, `.initCapacity` / `.fromSlice` say how
  - and telling those apart would need types, which the rule must not use. Simpler to state, too. Note and tests
  rewritten (`foo.bar = .initBozo(1)` clean; `initBozo`, `initCapacity`, `fromSlice` are not bare words); negative
  control (prefix matching restored) fails that test. 108/108; self-lint 0; `check` 358/358. Over the tree: 136 in
  34 files, every one `.init(` - the seven compound sites (initMany, fromByteUnits, initOne, initFill,
  fromMilliseconds) are now allowed.
  BURN-DOWN BATCH 1 (Oct 2) - robot_gym.zig, 28: every `x.field = .init(...)` spells the field's declared type -
  `dance.Tracker`, `robot_physics.Bridge`, `Random.DefaultPrng`, `ArenaAllocator`, `Layer`, `Mlp3`,
  `zn.Graph(f32)`, `AdamSet` (all declared in the same file, so in scope wherever assigned). T0, T1 0 (every rule +
  constructor-in-view); `check` 358/358 after regenerating 3 robot-mocap folds (the tutorial quotes HumanoidEnv,
  PpoTrainer and SacAgent whole); `test-fast` 612. 136 -> 108 left.
  BURN-DOWN BATCH 2 (Oct 2) - zimrnum.zig, 13 - and one RULE REFINEMENT: `var graphs: [2]Graph(f64) = .{
  .init(arena), .init(arena) };` (three tests) spells each element's type on its own line; fixing it literally would
  write the type three times. So a typed declaration's value now includes THE ELEMENTS OF THE ARRAY IT DECLARES
  (markDeclarationValue: the array_init tags; note and allowed-forms test updated; negative control - no array arm -
  fails it). A struct-literal field stays flagged: its type is not spelled. (Simon: it matches my intent.) The other
  seven lines spell their type: `ArenaAllocator` (scratch, twice), `NormedDense(T)` (the hidden layers - wrapped, one
  argument per line), `Mlp(f64)` (three test fixtures), `ReplayBuffer(T)`. zimrlint 108/108; T1 0; `zn-zimrnum`
  325/325; `check` 358/358; zimrnum tutorial folds regenerated. Tree: 108 -> 95 in 32 files.
  BURN-DOWN BATCH 3 (Oct 2) - the three robot files, 32: robot_supertrack 12 (`gym.Layer` for a three-layer tuple,
  ArenaAllocator, Random.DefaultPrng, Net, Graph, gym.AdamSet), robot_latent 11 (... and `track.Fleet`, whose init
  returns `!*Fleet` for a pointer field), robot_geno 9 (Reflex, FailureCheck, dance.ContactScratch,
  zimrphysics.World, robot_physics.Bridge, ServoRun.Snapshot, Random.DefaultPrng). Each type read from the nearest
  preceding declaration of the field - verified where it looked far (Planner spans 2694-3372; its rng is at 2732).
  T0, T1 0; 2 robot-mocap folds regenerated; `check` 358/358; `test-fast` 616. 95 -> 63 left.
  BURN-DOWN BATCH 4 (Oct 2) - codecs.zig 9, robot_sac_track 4, robot_world 3: locals by their own declarations
  (`cff_data: CffData`), fields by theirs (`Buf`, `track_env.TrackEnv`, `gym.SacAgent` behind a pointer field,
  `track_env.NStep`, `Random.DefaultPrng`), a return by its function's type (`return ReverseIterator.init(...)`),
  and six `arena.* = ArenaAllocator.init(gpa)` behind `gpa.create(ArenaAllocator)`. T0, T1 0; no tutorial fold
  changed; `check` 358/358; `test-fast` passed. 63 -> 47 left.
  L6 DONE - THE REST IN ONE PASS, TESTED AT THE END, AND GRADUATED (Oct 2; Simon: "do them all carefully, test only
  at the end"). The last 47 classified by kind (member / local / deref / literal field / return / argument) and each
  type resolved from its real declaration - candidates from the nearest preceding field, and every one whose
  literal or nesting could mislead checked by hand (State / Self literals; Fleet's nested Options closes before its
  fields - indent 4 throughout; an ECS component's anonymous struct; `self.map`'s value `ChunkList`; two `Any`
  parameters). One more RULE GAP found and fixed: a struct field's default value names its type
  (`cam: z.OrbitCamera = .init(...)`, rt_workers) - a container-field pass in checkConstructorInView, note + test,
  negative control fails it. 46 code sites spelled; constructor-in-view JOINED zimr_lint_rules (54 rules) and lost
  its advisory flag. Then, once: zimrlint 108/108; the whole tree under the enforced list 0 findings (the
  ChunkList use did not trip decl-order); doc-folds 1 regenerated; THE FULL GATE 406/406, 619 tests. No mistake
  surfaced. 136 bare `.init(` sites in four batches and this pass; three rule refinements on the way (bare words,
  array elements, field defaults).
- **L4d DONE (Oct 2) - the walk's own guard.** `zimrlint --coverage` (landed with the complete walk, still labelled
  "SCRATCH" and always returning 0) now FAILS when any tracked node is unwalked: it counts the roots it prints and
  ends with "N unwalked node(s) in M file(s): every rule is blind there - teach the walker (`allChildren`,
  `walkNode`)". build.zig: a fourth Run, `lint_coverage`, fed the same files as lint / lint-install / fix at the same
  three places (it cannot drift from what `lint` checks), a `lint-coverage` step, and the GATE depends on it (one
  more walk of the tree, ~1 min - not in `check`). Verified: the tree is fully covered (`zig build lint-coverage`
  3/3, 58 s); a deliberately blind linter (function bodies unwalked) makes `--coverage` exit 1 with a ROOT line and
  the summary on a probe; zimrlint 108/108. Why it matters: tagged unions were "covered" yet linted as statements,
  and before L2 125,610 nodes went unseen - the walk is now complete AND kept complete.
- **AUTOFIX DOGFOODED (Oct 3, Simon: "enable lint auto fix so we can dogfood our linter").** `-Dautofix` had a
  comment saying "default true" over code that said `orelse false`; it is now true, and the chain is: lint `--fix`
  -> `zig fmt` -> `lint` (check) and `fmt --check` -> every gated compile, `lint`, `lint-check` and `check`. The
  check must come AFTER the fix: `--fix` exits 0 whatever is left (it rewrites, it does not gate), and `check`
  depends on `lint-check` directly - a first wiring left lint-check outside the chain and it failed on the planted
  fixable finding. Dogfooded: a qualified `std.mem.eql` planted in robot_bmpc.zig - plain `zig build check` fixed it
  in place (the file byte for byte as before) and passed, 360/360 (the fix and the format now in the graph); an
  untyped local planted - `check` failed and the linter named it (stdout). `-Dautofix=false` keeps every check
  non-mutating (CI). A false lead on the way: the findings looked missing because `> file 2>&1` let the build
  runner's summary overwrite them; captured separately they were there, so the `.stdio = .inherit` tried meanwhile
  was not needed and was taken out.
- **L7 The next full build** - `.prefer_decl_literal` (and L6's rule) into `zimr_lint_rules`; `zig build fix` converts
  the ~920 sites outside zimrnum plus the generic-type sites L2 makes visible; full build and tests; both rules
  graduate from advisory once the tree is clean.

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

- **Opt-in tier (Sep 26), for apps built on zimr.** The linter used to be all-on with no
  config. Ten rules are now OPT-IN, run only under `--enable=<tag>`: the ones an outside
  Zig developer would switch off purely on taste, because mainstream Zig does the opposite
  and nothing breaks without them - untyped-local, anon-return (its reason IS untyped-local),
  branch-braces, decl-order, fn-args-multiline, module-var, no-qualified-zm,
  reserved-math-names, prefer-std-alias, ascii-comments. Everything that catches a bug,
  works around a toolchain limit, or holds the one-math-vocabulary contract stays always-on,
  and there is still NO way to turn a rule off - `--enable` rejects an always-on tag - so
  the reason `--only`/`--skip` were removed still holds. Borderline and kept always-on:
  catch-suppression (UB in ReleaseSmall), std-math (GPU portability), std-debug-assert,
  line-length. zimr enables all ten for itself except decl-order (`zimr_lint_rules` in
  build.zig); a project picks its own through `LintRule` / `addLint`, and the template lists
  them commented out.
- **The filter sits in ONE place: `analyzeSource`**, after every check has run, so the
  checks know nothing about configuration and a disabled rule's autofix can never apply
  (the fix loop analyses through the same function). The per-file clean stamps hash the
  enabled set: before that, a run with a new `--enable` skipped every stamped file.
- **Oct 2 - constructor literals only with their type in sight (Simon).** Zig's decl literals are welcome where the
  declaration already names the type on the same line (`const t: Tensor(T) = try .alloc(...)`), but a
  constructor-like call hidden behind a field or argument (`.{ .bozo = .init(gpa) }`) tells the reader nothing about
  what is built - so `init` / `create` / `alloc`-like calls keep their type unless it is on their line; other literals
  (enum tags, value decls, `.{...}`) stay free. Plan: the "NEXT" section above.

### 9. condition-steps  (readability; pure-AST)  — PROPOSED, not yet (Simon, Oct 7)

A condition that combines many boolean operators is read all at once; named steps read one idea at a time. The rule
would flag an `if` or `while` condition with more than one `and`/`or`, and a named `bool` with more than two,
and suggest one of three rewrites - the ones the Oct 7 sweep of the text-editing code used:
- **Name the parts.** `const collapses_selection: bool = !extend and has_selection and is_character_motion;` rather
  than the whole expression inside the `if`.
- **Decide, then act.** A call that changes state inside a condition (`if (wants_cut and editor.deleteSelection(t))`)
  hides an edit behind an `and`; the decision goes in the condition and the call in the body.
- **Keep the short-circuit with a labeled block** when a later part may only be evaluated once an earlier one holds -
  an index, a pointer, an expensive call:
  `const begins_word: bool = blk: { if (kind != .typed) break :blk false; ...; break :blk isBlank(first); };` -
  since splitting into plain named locals would evaluate every part. Early returns serve the same end in a function
  that can return (guards, one reason each).
Thresholds and exemptions (set membership like `a == X or a == Y or a == Z`, better written as a switch or an
`indexOfScalar` over a string) to be decided when the rule lands, opt-in and warning-level first, as every new rule.

## Platform correctness (Oct 9)

Four rules keep what the platform port settled from coming back. Each names the right way in its message, and each
exception is a directive saying why.

- **arch-check** - engine code asking the processor (`.isWasm()`, `.wasm32`). What it means is almost always a fact
  about the host - is this the browser, is there a GPU, a window - which `host.zig` states and which stays right on
  a new host. Code depending on wasm itself (its allocator, its linear memory, its lack of libc) opts out; a site
  waiting for its native equivalent names its step in the directive, so the directives list the work left.
- **own-clock** - a system clock read outside the platform layer. One monotonic clock, `platform.current.now()`,
  on every platform; a frame's time comes with the frame. Wall-clock needs (a certificate's validity) opt out.
- **process-exit** - `std.process.exit` outside an entry point: it skips every `defer`, the Vulkan host's shutdown
  and its validation report among them.
- **browser-call** - `web.zig` imported outside the browser's platform layer: a request only the browser will ever
  carry out. Where the contract lacks the request yet, the directive names the step that adds it.

A rule, once enabled, is enforced: what the tree does not follow yet is marked at each site, with a directive
saying why, rather than by keeping the rule in progress. Work in progress is how a rule lands, not how it lives.

## Value names at every depth (Oct 9)

`screaming-const` looked only at file scope, so `MAX_GAMEPADS` - a constant inside the runtime's `input` namespace -
kept the C-macro spelling where every other value in zimr is snake_case. The rule now looks at every declaration in
the tree, at any depth: file scope, a namespace struct, a function. It judges values only - a declaration naming its
type (other than `type`), or holding a literal - since short type aliases such as `V4` and `H2` are PascalCase
already; and it flags the macro spelling only, an all-caps name with an underscore or three letters or more, leaving
single capitals - `N`, `K`, `F0` - to the mathematics they come from. Turning it on renamed 111 values across 19
files (`max_gamepads`, `drag_threshold`, `char_filter_decimal`, ...), each where it was used in code - comments and
strings, which cite raylib's own names, were left as they were - and replaced the runtime's `LOG_*` aliases with the
enum tags they repeated (`.info`, `.err`).

## Work in progress, and every rule on (Oct 9)

A rule that reports without failing was called ADVISORY, which reads as optional advice. It is renamed WORK IN
PROGRESS (`RuleNote.work_in_progress`, printed `[rule, work in progress]`, announced by zbuild as
`zbuild: work in progress:`): the state a new rule is in while it is written and a tree converted to it, and nothing
else. In zimr a lint finding is a compile error, and an explained `// lint:off <rule>: <why>` is part of the language,
as much as any syntax. `prefer-decl-literal`, the last rule still flagged, finished - the tree had no finding left -
and is enforced. Every rule is on: zimr's own list holds all 58, and the example project's (template/build.zig), which
lacked six - `arch-check`, `browser-call`, `own-clock`, `process-exit`, `prefer-decl-literal`,
`constructor-in-view` - now holds all 58 too.
