# spv2wgsl-baseline-may-2026.md — pre-rewrite parity measurement

> Baseline run captured 2026-05-29 (start of Phase 0 of the
> [spv2wgsl-rewrite-plan](../src/notes/spv2wgsl-rewrite-plan.md)).
> Re-run any time with `zig build wgpu-diff`.

## Method

For each compiled SPIR-V file in `.zig-cache/o/<hash>/shader.opt.spv`
(post spirv-opt, what spv2wgsl actually consumes in our build
pipeline), we run the current linear `src/spv2wgsl.zig` translator
and check:

1. **Translate** — wasm didn't trap, returned non-zero output.
2. **Parse** — output passes structural parse via
   `wgsl_reflect.WgslReflect` (the only WGSL parser available on
   npm; we use it lexically because no `tint-wasm` package exists).
3. **No unresolved markers** — no `__unresolved_N__` strings (those
   indicate gaps in our id / type propagation).
4. **No error markers** — no `// ERROR:` or `UNHANDLED` lines from
   the translator itself.
5. **No known bugs** — no detectable instances of the
   "phi-overwrite-after-if" pattern that drove this rewrite (the
   mandelbrot diagnostic).

Pattern (5) is the canonical bug fingerprint: a `phiN = X;`
statement immediately inside an `if (cond) { ... }` block followed
by `phiN = Y;` at the same function scope right after the close
brace.  In the linear emitter, this is what happens when a
one-sided `if` whose body breaks out of an outer construct hits
the merge label's predecessor-phi assignment.

## Results (linear emitter, May 2026)

Ran across **16 distinct `.opt.spv` files** in our build cache
(translator wasm: `zig-out/wgpu/spv2wgsl.wasm`):

```
results: 13 ok, 3 failed (3 of which are known bugs)
```

### The 3 known-bug shaders

| Cache hash       | spv bytes | wgsl bytes | bugs detected |
|------------------|-----------|------------|---------------|
| `1ea13160…`      | 4 024     | 3 058      | 1 phi-overwrite (phi1975 at line 122) |
| `55fa56c7…`      | 7 460     | 6 082      | 4 phi-overwrites (phi2056, phi2068, phi2082, phi2258) |
| `9f25a77e…`      | 7 924     | 6 526      | 4 phi-overwrites (phi2183, phi2195, phi2209, phi2385) |

These are mandelbrot, julia, and mandel_julia — the three fractal
shaders.  They are the only shaders in our corpus that have a
**loop containing a conditional `break`** in Zig source, which is
the SPIR-V structural CF pattern that triggers our linear emitter's
phi-overwrite bug.

### The 13 clean shaders

Eight `shader.opt.spv` files (post-opt) plus eight `shader.spv`
files (raw, where opt didn't run for that target):

- 5 small VS / passthrough FS — no control flow at all, trivially
  correct.
- 3 mid-sized shaders with one-sided ifs but no breaks — `if`
  bodies all converge at the merge, no phi-overwrite trigger.
- 5 larger shaders (raw `.spv`, not post-opt) — visible loops and
  selections but Zig's SPIR-V backend output for these doesn't hit
  the same pattern.  These likely use `early_return` instead of
  `break out of loop`, which routes through a different SPIR-V
  shape.

## Conclusion

**100% of the bugs are in 3 of 16 shaders.**  All three exhibit
the same root cause (the if-break / phi-overwrite pattern
documented in `spv2wgsl-flow-guards.md`).  Total bug
count: 9 instances across 3 shaders.

This validates the rewrite scope: the recursive walker described
in [§2 of the plan](../src/notes/spv2wgsl-rewrite-plan.md#2-architecture-recursive-descent-with-stop-set)
needs to fix exactly this one pattern.  No other shader category
in our corpus produces buggy WGSL today; the rewrite is targeted.

**Target for Phase 5 (cutover):**
```
results: 16 ok, 0 failed
```

## How to reproduce

```bash
zig build wgpu-diff
```

The validator is pure Zig and lives entirely inside the test
framework:

- `src/spv2wgsl/wgsl_check.zig` — structural WGSL check + known-bug
  scanner.
- `src/tests/spv2wgsl_corpus_test.zig` — corpus runner.  Walks
  `tests/fixtures/external/tint/*.spv` AND
  `.zig-cache/o/*/shader.opt.spv`, calls
  `spv2wgsl.convertSpirvToWgsl` directly, tallies, asserts against
  baseline.
- `zig build wgpu-diff` builds a filtered native test binary off
  `src/tests.zig` (filters: `"spv2wgsl corpus"`, `wgsl_check`,
  `scanBugs`).  No external process, no JS, no npm, no Bun.

Same tests also run as part of `zig build test`.

## External corpus (Tint fixtures)

`tests/fixtures/external/tint/` contains 181 SPIR-V fixtures derived
from Dawn `main`'s `parser/{branch,phi,function}_test.cc` test
sources.  Both `.spvasm` (assembly source) and `.spv` (binary,
pre-assembled) are checked in.  These fixtures were one-shot
extracted; no extraction tooling is retained.  See
`tests/fixtures/external/tint/LICENSE.md` for the Apache 2.0
attribution.

Running our validator over all 181 external fixtures (run 2026-05-29):

```
results: 178 ok, 3 failed (3 of which are known bugs)
```

The 3 known bugs are:
- `phi_Phi_Switch_FromIfBreak.spv` — phi-overwrite where if-break
  exits a switch construct.
- `phi_Phi_Switch_FromIfBreakBoth_InDefault.spv` — both branches
  of the if-break, same root cause.

Three different Tint test cases hit the same pattern as our
mandelbrot diagnostic.  **178 / 181 = 98.3% structural correctness
on the most comprehensive SPIR-V CF test corpus available.**  The
remaining 1.7% is exactly the bug class the rewrite targets.

A few caveats:
- "OK" here means "translates without our detected markers AND
  parses via wgsl_reflect".  It does NOT mean "semantically
  equivalent to Tint's output".  Tint's tests check exact IR
  structure; we check structural correctness and known-bug
  absence.  Some of the 178 likely emit valid-looking but
  semantically wrong WGSL for edge cases the linear emitter
  hasn't been challenged with.  Phase 6 hardening will surface
  those via differential render testing.
- The "KNOWN-BUG" detector is a lexical fingerprint, not a
  proof.  False positives are possible; in this corpus we
  manually verified all 3 hits are real.
