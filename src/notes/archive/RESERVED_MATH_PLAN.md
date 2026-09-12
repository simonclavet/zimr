# Reserved math vocabulary + named-import convention

Status: **P1 + P2 + P3 LANDED** — yields applied; keep-list cleared; R1
(`reserved-math-names`) implemented in the linter and GREEN at 0 violations.
P4 (migrate `zm.X` bodies to named imports) is next. Decisions in §2/§9 are locked.

## 1. The goal (end state)

Every math-using file declares its zimrmath dependencies at the top, then uses bare
names in the body:

```zig
const zm = @import("zm");

// zimrmath imports
const Vec    = zm.Vec;
const dot     = zm.dot;
const length  = zm.length;
const max     = zm.max;

// ... body:
const n = length(v) / max(x, y);   // no zm. anywhere
```

Invariants:
1. **Named imports only** — `const NAME = zm.NAME;` (binding name == member name).
2. **`zm.*` banned in code** — the only legal `zm.X` is in a top-of-file binding.
3. **The common math words are reserved** — see §3; this is what makes bare names safe.

Verbose headers (deliberately — they *are* the dependency manifest), quiet bodies,
greppable vocabulary.

## 2. Five decisions that keep it light

**(a) Lean on the compiler; reserve only a curated core.** Zig already errors when a
file-scope `const length = zm.length;` is shadowed by a local/param `length`, so
*per-file* safety is free the instant a file imports a name. Global reservation only
buys cross-file grep consistency — a soft benefit. So we do **not** reserve all 399
zimrmath names. We reserve a small curated **core** (§3) of common, collision-prone,
math-owned words. Everything else (e.g. `quatFromAxisAngle`) is collision-free already
and is simply imported per-file under R2. Also note struct *fields* named `length`/
`add`/`step` never conflict — they're namespaced by the instance.

**(b) Auto-exempt math-free files.** If a file doesn't `@import("zm")`, the rules don't
apply to it. build.zig, most of tools/, codec internals — all exempt automatically, no
hand-maintained list to drift. A tiny manual skiplist covers hybrids only.

**(c) The library yields generic words.** Where a zimrmath name is a poor/generic fit
and collides with common non-math usage, we rename the **zm function** (one place)
instead of renaming many callers — and in every case the rename is a clarity
improvement (§4). This clears most collisions for free.

**(d) The import block is generated, not hand-written.** `zig build math-fix`
reconciles each file's binding block to actual usage (add/remove/sort) and autofixes
R2 by rewriting `zm.X`→`X` + inserting the binding. Humans never maintain 25 import
lines; the header is tool-maintained boilerplate.

**(e) Gentle rollout.** Warnings before errors; a committed baseline of known-existing
violations so the gate catches *new* ones immediately while old ones burn down; and a
per-decl `// lint:off reserved-math-names:` escape hatch (same pattern as the existing
`dup-pub-fn`).

## 3. The curated core R_core

Committed, reviewable list (the source of truth). Starts ~30 and grows by PR when
appetite allows. Proposed starting set — the scalar/vector staples math owns:

```
dot  cross  length  lengthSq  normalize  distance
lerp  clamp  clamp01  saturate  smoothstep
min  max  abs  sqrt  sin  cos  tan  pow  exp
floor  ceil  round  square  reflect  refract
pi  tau  phi  nan
```

Dimensioned variants are reserved too (decision locked): `dot3 dot4 cross3 length2
length3 length4 normalize3 distance3`. Distinctive names (`matFromAxisAngle`, `f32x4`, `lengthSq2Splat`,
…) are **not** in R_core — they never collide, so R2 + the compiler handle them
per-file.

## 4. Yield list — rename the zm function, free the generic word

Every one of these is also a clarity improvement. Counts = total word occurrences in
src+examples (overwhelmingly non-math).

| zm fn (line) | what it actually is | rename → | frees word (~occ) |
|---|---|---|---|
| `log` (475) | natural log | **`ln`** | `log` (703 — logging) |
| `step` (7623) | GLSL edge threshold | **`stepEdge`** | `step` (1294 — loops/Build.Step/sim) |
| `all` (981) | vector-bool reduce | **`allTrue`** | `all` (2268) |
| `any` (1008) | vector-bool reduce | **`anyTrue`** | `any` (1373) |
| `add` (550) | overflow-checked int add | **`addChecked`** | `add` (883) |
| `sub` (526) | overflow-checked int sub | **`subChecked`** | `sub` (571) |
| `mul` (538) | overflow-checked int mul | **`mulChecked`** | `mul` |
| `mod` | modulo | **`modulo`** | `mod` (= "module" everywhere) |
| `select` (2050) | vector ternary | **`blend`** | `select` (+ dodges `TestOp.select` field) |
| `mix` (7611) | == lerp | **folded into `lerp`, deleted** (locked) | `mix` (87) |
| `point` (6202) | Vec from x,y,z | **`pointVec`** (locked) | `point` (1124) |
| `store`/`load` (854/823) | vec ↔ []f32 | **`storeVec`/`loadVec`** (ArrN forms stay) | `store`/`load` |

**Applied via `tools/rename_pub_fn.zig`** (AST-precise: only identifier nodes + the fn
name token; comments, `.field`, and longer names like `log2`/`mulMat` untouched).
Cross-file `zm.X` and `math.X` call sites fixed by word-anchored sed (only `log`/`mod`
are also `std.math` members and were handled per-file). After these renames the generic words
(`log step all any add sub mul mod select mix point store load`) are available to
everyone, clearing the bulk of the 42 collisions automatically — including the
`bridge.log` logging fn, the two demo `step(s: *State)` ticks, the ECS `var add`, the
substring `const sub`, the SPIR-V `const mod`, and the raytracer `const point`.

## 5. Keep list — math owns the word, fix the few callers

Core words math keeps; rename the handful of colliding decls (all in math-using files):

- `length` → `len` — src/draw3d.zig:4677, 4979
- `phi` → `phi_angle` — src/draw3d.zig:427
- `min`/`max` → `min_corner`/`max_corner` — src/ui.zig:9096-9097, 30325-30326
- `rad_per_deg` → use `zm.rad_per_deg` — src/ui.zig:7140 (redefines a zm const)
- `dot` → `dot_color` — examples/wgpu_audio_basic:140
- `exp` → `exports_val` — src/bridge.zig:1827
- `nan` → `nan_f32` — src/rlsw_pixel.zig:1273
- `is_gpu` → use `zm.is_gpu` — examples/wgpu_compute_particles:147
- `is_wasm` → use `zm.is_wasm` — src/runtime.zig:4821
- `identity` — verify none remain (draw3d already → `ident`)

Duplicate functions → delete and use zm:
- `quatFromAxisAngle` — src/physics.zig:290
- `hsvToRgb`/`rgbToHsv` — src/ui.zig:22023, 22029
- `cross3` — examples/wgpu_billboards:74
- `lerp` — src/draw3d.zig:3131

**Excluded entirely:** `std builtin math assert assertf expect util` (re-exports,
auto-detected by their `@import`/alias RHS); `sw` (screen-width abbreviation, not core
math). `bridge.math()` is fine — `math` is the excluded `std.math` re-export.

## 6. The two lint rules (in tools/zimrlint.zig)

**R1 `reserved-math-names`** — ✅ IMPLEMENTED in `tools/zimrlint.zig`. In a file that
imports zm, flags any `const`/`var`/`fn` decl whose name ∈ R_core, except the canonical
binding `const NAME = zm.NAME;`. R_core is a `StaticStringMap`; `collectZmAliases` scans
each file for whole-module `const X = @import("zm");` bindings (empty ⇒ exempt, decision
2b); `checkReservedMath` runs from `checkVarDecl` (const/var) and the `.fn_decl` branch.
Struct/enum FIELDS and PARAMS are deliberately NOT covered (only decls). Verified:
flags real collisions, honours the binding + the no-zm exemption, prints a rule note.

**R2 `no-qualified-zm`** — ✅ IMPLEMENTED in `tools/zimrlint.zig` and enforced (P5).
Fires on any `zm.X` field-access in a body, EXCEPT the canonical binding init
`const X = zm.X;` (name == member), which is pre-marked per file by
`markCanonicalZmInits` and skipped. Modeled on `checkDebugPrint` (a per-`field_access`
check, emitting at the field token). **Scope:** only files with a column-0 `const zm =
@import("zm");` are checked (`hasCol0ZmImport` → the `zm_col0` Ctx flag); a file whose
only zm import is per-struct/indented (runtime.zig's per-namespace imports) cannot host
a file-scope binding and is exempt — mirroring P4's own col-0 requirement. Files that
don't import zm are exempt (empty `zm_aliases`, e.g. zimrmath itself). The escape
hatch for a genuine same-named-owner is `// lint:off no-qualified-zm: <why>`, **but the
tree currently uses it zero times** — every collision was resolved at the source rather
than suppressed: physics's `quatFromAxisAngle` was a redundant pass-through wrapper, now
a plain `const quatFromAxisAngle = zm.quatFromAxisAngle;` binding; ui's `hsvToRgb`/
`rgbToHsv` were scalar↔Vec4 adapters that didn't belong in ui at all — they moved into
zimrmath as `hsvToRgb3`/`rgbToHsv3` (3-channel `[3]f32` form), with ui consuming them via
named imports. R2 also rejects name-mismatched bindings (`const d = zm.dot;`).

R1 (greppability of the common core) and R2 (no `zm.` in bodies) are orthogonal and
compose.

## 7. Tooling

- `tools/rename_pub_fn.zig` (built for P1) — AST cross-file public-function renamer
  (def name token + all identifier references in the defining file; refuses if the new
  name already exists). Validated on all 13 yields.
- `tools/rename_local.zig` (exists) — scoped local renames for the keep-list locals.
- `tools/zm_namedimports.zig` (new) — the migration + `math-fix` workhorse: find the zm
  alias, collect distinct `zm.X`, insert a sorted `const X = zm.X;` block, rewrite body
  `zm.X`→`X`. AST-based (ignores strings/comments), idempotent. Same `std.Io`
  conventions as rename_local.
- A small cross-file fn rename for the yields, or do the ~13 by hand.

## 8. Phased rollout (each phase gated + shippable)

- **P0 — finalize.** ✅ Done. R_core + exclusions locked; `mix`→`lerp`, `point`→`pointVec`,
  dot3-style variants reserved, no shader carve-out.
- **P1 — yields.** ✅ Done. 13 zm functions renamed + all call sites fixed; tests + gate
  green. Cleared the bulk of the 42 collisions automatically.
- **P2 — keep-list cleanup.** ✅ Done. Renamed the §5 keep-list locals, redirected
  draw3d's duplicate `lerp` to `zm.lerp`, and renamed billboards' `cross3` (its `[3]f32`
  signature is incompatible with `zm.cross3`'s `Vec`).  A full R_core re-scan caught **5
  collisions the original audit missed** — all now fixed: `wgpu_app` `tau`→`two_pi`,
  `codecs` `length`→`len`, `shapes2d` `cross`→`cross_z` + `length`→`len` ×2.  Files that
  don't import zm stayed untouched (auto-exempt, decision 2b): `spv2wgsl`,
  `spv2wgsl_wasm`, `shader_codegen` (its `zm.` refs are all in comments), and the
  `bridge_*` probe examples.  The 3 private non-R_core dup fns (`quatFromAxisAngle`,
  `hsvToRgb`/`rgbToHsv`) were left alone: not pub (so dup-pub-fn ignores them), not in
  R_core (so R1 ignores them), and the hsv/rgb ones have Vec-vs-scalar signatures anyway.
- **P3 — turn on R1.** ✅ Done. Implemented + verified; baseline is empty (P2 cleared
  every collision), so R1 went straight to a hard gate — no warn phase needed since there
  was nothing to suppress. `lint:off reserved-math-names:` hatch is wired (shared
  directive machinery).
- **P4 — migrate `zm.X` → named imports** via `zm_namedimports`, src/ then examples/,
  in batches. Ship per batch.
- **P5 — turn on R2** ✅ COMPLETE. R2 implemented + enforced (gate 0/277, `zig build
  test` green). True surface was 43 fires: 40 in runtime.zig (cleared by the col-0 scope
  rule) + 3 same-named wrappers (physics's was redundant duplication → now a named
  import; 2 ui adapters keep `lint:off`). Convention locked. Shipped zimr1204; physics
  cleanup + this note in zimr1205.
- **P6 — generalize (evaluated → not pursuing).** Investigated the two candidates.
  `z.colors` is `types.zig`, aliased `const c = z.colors;` across many examples; it exports
  42 Tailwind-specific names (`amber_500`-style) plus just 2 bare words (`white`/`black`).
  `z.rlsw` exports 9 *specific* nouns (`Context`, `Texture`, `dispatchFragmentShader`,
  `PixelFormat`). Neither has zm's problem: zm exports *generic English words*
  (dot/cross/length/clamp) used in *expression* position, which collide with locals and
  read verbosely when qualified — the reason R1/R2 exist. colors/rlsw export specific
  nouns used as values/types, where qualified access (`c.amber_500`, `rlsw.Context`) is
  idiomatic and clear; an R2-analog (`const amber_500 = c.amber_500;` per colour) would be
  *actively worse* and defeats the point of the `c` palette alias. So the
  `{alias, reserved-source}` registry would add machinery + churn for a non-problem.
  Revisit only if a future namespaced module exports generic words. **The reserved-math
  arc is complete at P5** (R1 + R2 live, named imports everywhere, zero `lint:off`).

## 9. Decisions (locked)

1. `mix` → **folded into `lerp`** and deleted.
2. `point` → **`pointVec`**.
3. R_core **includes** the dimensioned variants (`dot3`, `cross3`, `length3`, …).
4. **No shader carve-out** — `.fs.zig`/`.vs.zig` follow the same import-based scoping as
   any file. None collided in the audit; a shader that imports zm obeys R1/R2 like the rest.

## 10. Next step — P4 (migrate `zm.X` bodies → named imports)

R1 is live and green, so the foundation is in place.  P4 builds
`tools/zm_namedimports.zig`: for each zm-importing file, find the distinct `zm.X` used
in bodies, insert a sorted `const X = zm.X;` binding block under the existing
`const zm = @import("zm");`, and rewrite the body `zm.X` → `X`.  AST-based (skips
strings/comments), idempotent, run in batches (src/ then examples/), each batch its own
shippable gate.  R1 already guarantees the inserted bindings are the only legal home for
those names, so the two rules compose.  After P4: P5 turns on R2 (`no-qualified-zm`),
which bans any remaining body-level `zm.X`.  R_core itself can later be generated from a
`// reserved` marker in zimrmath instead of the hand-list (§3).

**Status — P4 batch rollout COMPLETE (src + examples).** The tool was made
collision-aware (this was essential): before migrating a name it now checks whether that
name is already declared in the file (any top-level const/fn, or a local/param), and if so
leaves `zm.X` qualified rather than inserting a duplicate or shadowing binding.  Without
this it corrupted real code — physics.zig has an `inline fn quatFromAxisAngle` wrapper
around `zm.quatFromAxisAngle`, and the naive rewrite turned its body into infinite
recursion; ui.zig has its own `hsvToRgb`/`rgbToHsv`; wgpu_app.zig has `const Vec2 =
input.Vec2`.  All three are now left qualified.

Result: **441 `const X = zm.X` bindings across 136 files**; body `zm.X` occurrences
3234 → ~1011.  The ~1011 that remain are *correctly* left qualified: names colliding with
a file-local decl (zimrmath's own `dot`/`cross`/…, types.zig's `Vec2`/`Vec3`,
raytracer/physics/ui locals), plus runtime.zig (skipped — its zm is per-struct/indented,
not col-0), plus doc-comment mentions the AST tool ignores.

Verified green across every compile path: `zig build test` (all CPU src + every example
typecheck + corpus 57/57 internal); wasm `wgpu-basic` (default_shapes shaders + runtime);
`wgpu-pbr-demo` (pbr_fs/vs, heaviest src shader); `wgpu-rt-shader` (rt_fs, heaviest example
fragment shader); `wgpu-compute-particles` + `wgpu-fluid-gpu` (kernel Zig→SPIR-V→WGSL,
"Validation successful").  Build SEQUENTIALLY — parallel `zig build` clobbers the shared
`tools/zig-out` and produces spurious shader-pipeline failures.

**P5 — R2 enforced (COMPLETE).** R2 (`no-qualified-zm`) is implemented in
`tools/zimrlint.zig` and live in the gate.  The feared ~1011 was a textual grep count
inflated by doc-comments; the real AST surface was **43 fires across 3 files**:
runtime.zig (40), ui.zig (2), physics.zig (1).  runtime.zig's 40 are its per-struct
`const zm` uses — not bindable at file scope — and are cleared *en masse* by R2's
col-0 scope rule (`hasCol0ZmImport` → the `zm_col0` flag), which exempts any file with
no file-scope zm import, exactly as P4 skipped runtime.zig.  Of the remaining 3: physics's
`quatFromAxisAngle` was a redundant pass-through wrapper (identical signature to
`zm.quatFromAxisAngle`, `Quat`/`Vec` structurally equal) — deleted in favour of a
`const quatFromAxisAngle = zm.quatFromAxisAngle;` binding (R2 accepts it as canonical, 6
callers unchanged).  ui's `hsvToRgb`/`rgbToHsv` were initially kept as `lint:off`'d
adapters, but that still left two definitions of the same conversion in two modules —
the exact duplication this rule exists to prevent.  So they were moved into zimrmath as
`hsvToRgb3`/`rgbToHsv3` (the 3-channel, no-alpha `[3]f32` form; `3` matches zimrmath's
`angle3`/`barycenter3` convention).  To avoid a pack→SIMD→unpack tax on the array path,
they are the *scalar* implementation; the Vec `hsvToRgb`/`rgbToHsv` reuse them in their
`is_wasm` branch (reattaching alpha) while keeping the native SIMD branch untouched — so
the conversion math lives once and array callers stay pure-scalar.  ui now imports
`const hsvToRgb3 = zm.hsvToRgb3;` etc.  **Net result: zero `lint:off no-qualified-zm` in
the tree** — every collision resolved at the source.  Gate: 0 issues / 277 files;
`zig build test` green (internal corpus 79/79, incl. new scalar-vs-Vec parity tests).  A
new inline `zm.X` in any file-scope-zm file now fails the gate — the convention is locked.

**On runtime.zig's per-namespace zm.** runtime.zig has no root `const zm`; instead its
`pub const gestures/camera/allocator = struct {…}` namespaces each `@import("zm")`
locally.  This is a deliberate self-contained-namespace style, not a bug — but since Zig's
lexical scoping would make a single root `const zm` visible inside all of them, the local
imports ARE redundant and a root import would be more consistent with the other 153 files.
The tradeoff: hoisting to root would then subject runtime.zig's 40 `zm.X` to R2 (it would
gain a file-scope zm), so it would need a P4-style named-import migration of those 40 to
stay green.  Left as-is for now (the col-0 scope rule handles it cleanly and the namespace
style is defensible); revisit if consistency is preferred over self-containment.

## 11. Import uniformity (COMPLETE)

`const zm = @import("zm");` is now the universal, only form — **153 files**, zero
exceptions.  Confirmed at the build level that every module has "zm" as a *direct*
dependency: examples via `buildUserMod` (`addImport("zm", ...)`), src/ via direct imports,
and even compute kernels via `addCompute` (lines 787-792 pass `--dep zm -Mzm=`), so every
swap was a same-module access-path change — semantically identical, no build.zig edits.

Why it mattered: R1's `collectZmAliases` keys on `@import("zm")`, so any file reaching zm
through a re-export (`z.math`/`k.math`/`sw.math`) was silently EXEMPT from R1.  Uniform
imports make R1 cover the whole tree, and remove the indirection P4/P5 would otherwise
have to special-case.

Done:
- 67 examples: `const zm = z.math;` → `@import("zm")` (6 also had inline `z.math.X`,
  converted to `zm.X`).
- 10 examples used inline `z.math.X` with no binding → added the binding + converted.
  Re-running the gate with R1 now active on them was clean: their only R_core-named decls
  were `const tau = zm.tau` / `const pi = zm.pi` (zoo_phone), which R1 correctly exempts as
  the canonical `const NAME = zm.NAME` re-binding pattern (the intended P4 form).
- 4 compute kernels: `const zm = k.math;` → `@import("zm")`, keeping `const k =
  @import("kompute")` (still used for `k.C`/`k.G`/`k.s…`, the Compute API).
- 3 native sw demos (`sw_julia`, `sw_mandelbrot`, `sw_engine_shader`): added the binding +
  converted `sw.math.X`/`sw_runtime.math.X` → `zm.X`.
- `rlsw_pixel.zig`: dropped a redundant duplicate `const zm_math = @import("zm")` (it
  already had `const zm`); pointed its 2 uses at `zm`.
- Removed the 3 re-exports `pub const math = @import("zm");` (in `zimr_wgpu`, `kompute`,
  `sw_runtime`) — all had `math.uses=0` internally (pure re-exports), so deletion was one
  line each (+ dropped kompute's now-obsolete `const zm = k.math` doc comment).
- Fixed a P1 regression the audit surfaced: `runtime.zig` reached zm via inline
  `@import("zm").mul(...)` (no alias), which the P1 sed didn't match and which native
  `zig build test` never compiled (wasm-only allocator).  → `mulChecked`.

Verified: gate 0/276 (R1 active on every zm file); `zig build test` green (corpus 38/38,
example typecheck); `wgpu-keys` built to wasm (regular example + `runtime.zig`);
`wgpu-compute-particles` built to wasm with "Validation successful" (kernel
Zig→SPIR-V→WGSL + naga) — the decisive proof kernels survive the `@import("zm")` swap.

## 11b. Lint hardening — aliased-std detection + return-walk gap (DONE)

Resolves the §11 finding (`runtime.zig` reaching `std.math` via an aliased `std` import).

(a) **`std-math` now catches aliased std.**  Generalized `collectZmAliases` →
`collectImportAliases(source, out, needle)` and added a `Ctx.std_aliases` field collecting
whole-module `@import("std")` bindings.  `checkStdMath` now flags `<obj>.math` when `obj` is
`std` OR any std alias — so `std_mod.math.pi` is caught, not just literal `std.math`.
Verified on a fixture: flags `std.math.pi` and `std_mod.math.e`, leaves a non-std
`other.math.foo` alone.  (The decl-import form `const m = @import("std").math; m.atan2(…)`
does not occur anywhere in the tree; noted as the one remaining theoretical evasion.)

(b) **Fixed `runtime.zig`.**  The file is split into namespace structs (`core`, `input`,
`gestures`, `camera`, `effects`, `allocator`, `libc`), each with *local* imports; `camera`
already had its own `const zm`.  `gestures.vec2AngleDeg` reached `std.math.atan2`/`pi`
through a local `const std_mod = @import("std")` — converted to `zm.atan2`/`zm.pi` and gave
`gestures` (and `allocator`, for an inline `@import("zm").mulChecked`) its own local
`const zm`, matching `camera`.  A first attempt at a single file-top `const zm` collided
with `camera`'s local one (37 "ambiguous reference" errors — Zig's no-hiding rule), which is
why the fix is per-namespace.

(c) **Closed a return-expression walk gap (was a blind spot for ALL node-checks).**
`walkNode`'s generic descent goes through `childNodes`, which had no `.@"return"` case
(`else => buf[0..0]`), so `return <expr>;` operands were never walked — `std-math`,
`clamp-pattern`, `as-round`, `typed-local`, `branch-braces` etc. all silently skipped return
expressions.  Added a `.@"return"` case (`data.opt_node`).  This surfaced 7 real violations
that had been hiding: `src/image.zig` (`std.math.clamp` in a return → `zm.clamp`),
`web.zig` ×2 (untyped `ptr`/`len` in a `return switch` block), `zimrmath.zig` + `ui.zig`
(unbraced `if` bodies in `return blk:` expressions), `bridge.zig` (untyped `digits`),
`wgpu_shapes_demo` (`@max(@min(...))` → `zm.clamp`).  All fixed.

Verified: gate 0/276; `zig build test` green (corpus 49/49, example typecheck); the lint
fixture confirms aliased-std + return-position detection both fire.
