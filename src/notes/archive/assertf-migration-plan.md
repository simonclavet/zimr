# assertf migration plan

Replace every `assert(...)` and `std.debug.assert(...)` call in zimr
with `assertf(ok, @src(), "msg", .{args})`.  After the sweep, delete
the no-message variants from `assert.zig` so there is one obvious
way to assert.  Also fix `alwaysAssert`'s `@src()`-in-inline-fn bug
along the way.

## Why

`@src()` inside an `inline fn` resolves to the inline fn's own
location, not the caller — confirmed (see `assert.zig` line 83-87
comment block).  Wasm stack traces are unsymbolicated, so a bare
`assert(ok)` that fires in production reports `assert.zig:NN` with
no localisation back to the caller.  `assertf` with a caller-side
`@src()` is the only form that gives a useful trap message in wasm.
With the new `release-with-zimr-asserts` build mode firing zimr
asserts in shipped wasm, every assertion needs that localisation
or it's useless when it triggers.

Companion rule: `src/notes/claude.md` §"Defensive coding — assert
every precondition".  This plan is the cleanup pass that brings the
existing 178 sites in line with that rule.

## Decisions (both confirmed)

1. **Delete `assert(ok)` and `assertSrc(ok, src)` after migration.**
   One obvious way — `assertf(ok, @src(), "msg", .{})` works for
   every case including no-args ones.  Keeping the no-message forms
   invites future regressions where someone reaches for the wrong
   one and loses localisation.
2. **Fix `alwaysAssert` signature to take `src` as 2nd arg.**  Same
   inline-fn bug as the old `assertf`.  No callers today, but the
   API should be consistent so the next real use is correct from
   day one.

## Survey

Counts taken at start of plan.  Re-grep before each phase — counts
should drop by exactly the phase's file's count.

| File                       | `assert(...)` | `std.debug.assert` | Phase |
| -------------------------- | ------------- | ------------------ | ----- |
| `src/codecs.zig`           | 38            | 0                  | 1     |
| `src/math.zig`             | 64            | 0                  | 2     |
| `src/entities.zig`         | 73            | 1                  | 3     |
| `src/ui.zig`               | 0             | 2                  | 4     |
| `src/runtime_assembly.zig` | 0             | 1                  | 4     |
| `src/assert.zig`           | 1 (own test)  | 0                  | 0, 5  |
| **Total**                  | **176**       | **4**              |       |

Excludes `src/notes/staging/ecs-original.zig` (frozen reference
copy, not built).  No `assert(...)` callers in `examples/` or
`src/tests/` — they use `try expect*` per Zig test convention.

## Mechanics

Transform pattern:

```zig
//  before
assert(cond);

//  after
assertf(cond, @src(), "<msg with interpolated state>", .{ <state> });
```

For `std.debug.assert(cond)`, additionally swap the import (each
file at most needs `const assertf = @import("assert.zig").assertf;`
once at the top).  Where the file already imports `assert` from
`assert.zig`, the import line stays — Phase 5 will rename it to
`assertf` once the no-message form is deleted.

### Authoring a good fmt string

Every site needs one — no `"assertion failed"` placeholders.  Rules:

1. **Interpolate the values that drove the condition.**  A bounds
   check fires → print both bounds.  A type tag check fires → print
   the actual tag.  A flag combination check fires → print the
   flags as hex.
2. **Name the invariant being checked.**  `"ring overflow"` beats
   `"len < cap"`.  Future-you reading the wasm log shouldn't need to
   open the source to know what broke.
3. **Use Zig fmt spec verbs that match the type:**
   - `{d}` for integers and floats (the most common case)
   - `{d:.6}` for floats where precision matters (drift checks)
   - `{x}` for flag bitmaps / opaque handles
   - `{s}` for `[]const u8` only
   - `{any}` is a last resort — prefer a custom format when the
     type is one of ours.
4. **Skip the values when the condition is binary and self-explanatory.**
   `assertf(app == null, @src(), "install: already installed", .{})`
   doesn't need to print `null` again.  Rare — most sites benefit
   from at least one value.
5. **Keep the message under ~80 chars before the `.{...}`.**  Long
   wasm log lines wrap badly in the dev console.

### Cluster-aware refactoring

When the same 2+ preconditions appear in 2+ adjacent functions,
collapse them into a private helper using `assertf` internally.
**Only known cluster: `math.zig` perspective/ortho preconditions**
(see Phase 2).  Do not invent helpers for non-clusters — the rule
is "2+ call sites with the same 2+ checks", not "looks similar".

### Cost-vs-strip audit per site

Per `claude.md` §"Defensive coding", expensive conditions must be
wrapped in `if (comptime assert.allow_assert) { ... assertf(...); }`.
Definitions:

- **Cheap** (no wrap): scalar compare, single hash lookup, single
  `math.approxEqAbs`, single `isFinite`, struct field read.
- **Expensive** (wrap): `for` loop, recursion, sort, anything O(n)
  in a dataset.

Spot-check during the sweep — none of the 178 known sites look
expensive on first scan, but eyeball every condition before
transforming.  If you find one, wrap it and add a one-line comment
naming the cost ("O(n) bound — wrapped").

## Phase plan

Build-green policy: green at end of every phase.  Mid-phase breakage
inside a single file is fine per `claude.md` build-breakage policy.

### Phase 0 — `assert.zig` API fix

**Scope:** make the assert module consistent before migrating callers.

1. Change `alwaysAssert` to take `src: std.builtin.SourceLocation`
   as 2nd arg, mirroring `assertf`'s new shape.  Update its
   docstring + the `fail(@src(), ...)` line to pass `src` through.
2. Update the file-header comment block (lines 1-57): the
   `alwaysAssert(ok, fmt, args)` row becomes `alwaysAssert(ok, @src(),
   fmt, args)`; add a one-line note about why (same inline-fn issue).
3. `zig build test` — should still pass; no caller-side changes
   needed since `alwaysAssert` has zero callers in real code.

**Acceptance:** `zig build test` green, `grep -n alwaysAssert
src/` shows the signature change at the definition only.

### Phase 1 — `src/codecs.zig` (38 sites)

**Scope:** stb_truetype port internals.  Self-contained file, no
cross-file dependencies on the asserts.

Pattern observed in spot-check:

```zig
assert(glyph_index < tt.glyphs_len);
assert(tt.index_to_loc_format < 2);
assert(top_width >= 0);
assert(z.direction != 0);
```

Most are bounds + non-zero + format-version guards.  Straightforward
fmt strings.

Two `const assert = @import("assert.zig").assert;` lines at
`codecs.zig:698` and `:4044` (inside fns / blocks).  Replace each
with `const assertf = @import("assert.zig").assertf;`.

**Watch for:** any condition that references a `union(enum)` tag
— the `{any}` fmt may not print usefully; check tag names manually.

**Acceptance:** `zig build test` green; `grep -c '^\s*assert\s*('
src/codecs.zig` returns 0; smoke test the rasterizer-heavy examples
(`writing_anim`, `text_layout`) — but only if Phase 5 runs in a
later turn that touches `drawing.zig` too; otherwise skip smoke this
phase.

### Phase 2 — `src/math.zig` (64 sites)

**Scope:** projection / matrix math preconditions.  Cluster
refactor goes here.

**Step 2a — projection-input helper.**  Add a private
`assertProjectionInputs` that takes the four common args:

```zig
inline fn assertProjectionInputs(
    src: std.builtin.SourceLocation,
    near: f32,
    far: f32,
    scfov0: f32,
    aspect: f32,
) void {
    assertf(near > 0.0 and far > 0.0, src,
        "projection: near and far must be > 0 (near={d} far={d})",
        .{ near, far });
    assertf(!approxEqAbs(f32, scfov0, 0.0, 0.001), src,
        "projection: fov sin/cos[0] must be non-zero (got {d:.6})",
        .{scfov0});
    assertf(!approxEqAbs(f32, far, near, 0.001), src,
        "projection: far must differ from near (near={d} far={d})",
        .{ near, far });
    assertf(!approxEqAbs(f32, aspect, 0.0, 0.01), src,
        "projection: aspect must be non-zero (got {d:.6})",
        .{aspect});
}
```

This collapses the 4-line cluster at math.zig:2382-2385, 2400-2403,
2420-..., (~7 fns × 4 asserts = 28 sites) into 7 single-line calls
that each forward `@src()` — caller-site localisation preserved
because the helper takes `src` rather than calling `@src()` itself.

**Step 2b — remaining ~36 sites.**  Sweep one-by-one with the
authoring rules.  Many are `len_sq > 0.9 and < 1.1` style unit-norm
checks; format with `{d:.6}` for the actual length.

**Watch for:** sites that compute a derived value in the condition
itself (`lengthSq4(q)[0]`).  Lift to a `const len_sq` local *before*
the assert so the value is available for the fmt args without
recomputing.  This is also the §6 "Touching a fn = bringing the
whole fn up to spec" rule — a function whose assert recomputes
state is one bug-print away from drift between the check and the
message.

**Acceptance:** `zig build test` green; ~28 sites become ~7
helper calls plus ~36 inline `assertf` calls.  Net call-site
count drops from 64 → ~43.

### Phase 3 — `src/entities.zig` (74 sites)

**Scope:** ECS internals.  Biggest file; biggest fmt-authoring
investment.  Sites cluster around four invariant kinds:

1. **Handle / generation checks** (`result.key.generation !=
   .invalid`, `cycle[0] == 1`).  Print the key as `{any}` only if
   `Handle` has a custom format; otherwise interpolate `key.index`
   and `key.generation` separately.
2. **Index / capacity checks** (`offset != 0`, `idx < next_index`,
   `capacity < maxInt(IndexInt)`).  Print both sides.
3. **Archetype consistency** (`offset != 0; // present in arch by
   construction`).  The existing comments tell you the invariant
   — promote them into the fmt string.
4. **Initial-state checks at fn entry** (`std.debug.assert(options.
   capacity > 0)`).  Convert to `assertf` and migrate the import.

**Process suggestion:** open the file, go top-to-bottom, batch in
chunks of ~15 sites between intermediate compiles.  Build can be
red mid-phase per policy.

**Watch for:**
- `assert(@as(u32, @intCast(...)) == ...)` patterns — keep the
  cast as-is in the condition; don't try to simplify during this
  sweep (out of scope).
- `assert(try self.changeArchUninitImmediateOrErr(...))` at
  line 3181 — the condition has side effects.  This is fine
  under the new rule (cheap-ish, scalar bool return) but flag in
  a comment: "// side-effecting condition: do not strip via
  comptime guard".  Do NOT wrap in `if (comptime allow_assert)`
  — that would silently skip the call in ship.  This is the
  edge case where the side effect IS the point.

**Acceptance:** `zig build test` green; `grep -c '^\s*assert\s*('
src/entities.zig` returns 0; `grep std.debug.assert src/entities.zig`
returns 0.

### Phase 4 — `src/ui.zig` + `src/runtime_assembly.zig` (3 sites)

**Scope:** mop-up.  Trivial.

- `runtime_assembly.zig:84` — `app == null` precondition in
  `install`.  Single fmt string, no values needed:
  `assertf(app == null, @src(), "install: runtime already installed", .{})`.
- `ui.zig:3588`, `:3642` — `FilterMatcher` buffer-length and
  segment-range checks.  Print the lengths.

Add `const assertf = @import("assert.zig").assertf;` near the
top of each file if not already present (ui.zig likely already
has it; runtime_assembly.zig probably doesn't).

**Acceptance:** `zig build test` green; `grep -nr 'std\.debug\.assert'
src/` returns 0 (excluding the staging file).

### Phase 5 — kill the no-message variants

**Scope:** delete dead code now that nothing reaches `assert(ok)`
or `assertSrc(ok, src)`.

1. **Re-verify nothing calls them:** `grep -nrE '\b(assert|assertSrc)\s*\(' src/` should
   show only references inside `assert.zig` itself.  Important nuance:
   matches like `assertf(...)`, `std.debug.assert(...)`, or
   `alwaysAssert(...)` are NOT call sites for the targets and will
   appear in the above grep — eyeball each match before deleting.
2. **Delete `assert` and `assertSrc` from `assert.zig`**, along with
   their docstrings and the `IMPORTANT` block about inline-fn `@src()`
   misreporting (which no longer applies since the only remaining
   form takes caller-side `src`).
3. **Update the file-header comment block** to list only
   `assertf` and `alwaysAssert` as the two assertion forms.
4. **Migrate the import-alias pattern.**  Files currently say
   `const assert = @import("assert.zig").assert;`.  These need to
   either:
   - become `const assertf = @import("assert.zig").assertf;`, or
   - if the file already imports `assertf` directly, just delete
     the line.
   Walk each file: `physics.zig`, `math.zig`, `entities.zig`,
   `codecs.zig` (2 sites).
5. **Update `src/notes/claude.md` and `src/notes/claude_long.md`**
   if they reference the dropped forms.  Currently only `claude.md`
   §"Defensive coding" mentions `assertf` (good) but the original
   `assert.zig` migration-snippet (`const assert = std.debug.assert
   → const assert = @import("assert.zig").assert;`) gets dropped.
6. **Delete the failed-test note in `assert.zig`** ("Negative-path
   tests would need to be in a separate executable...") — still
   accurate but reword to mention `assertf` not `assert`.

**Acceptance:** `zig build test` green.  `grep -nrE 'assertSrc\b'
src/` returns nothing.  Final API surface of `assert.zig`:
`assertf`, `alwaysAssert`, `allow_assert`.

## Risks and rollback

- **fmt-string typos** are caught at comptime by `std.fmt` — Zig
  refuses to compile a `{d}` against a `[]const u8`.  Low risk.
- **Mid-sweep test failures** would indicate a pre-existing assert
  was actually wrong (the migration changes the trap mechanism but
  not the condition).  If `zig build test` fails inside a phase,
  bisect: the condition itself was incorrect before, or the fmt
  string evaluates an arg with a side effect.  Asserts must never
  have side effects in their condition (entities.zig:3181 is the
  one exception — its side effect is intentional and we flagged it).
- **Rollback strategy:** each phase is one or two files.  If a
  phase needs to be unwound, `git checkout HEAD -- <file>` reverts.
  Phase 0 (alwaysAssert signature) is the only one with potential
  upstream blast radius — but with zero callers, that radius is
  zero.

## Out of scope

- Renaming `assert.zig` or restructuring its module shape.
- Touching vendored stb sources outside `src/codecs.zig`.
- Adding new asserts beyond what's already in the code.  This is
  a pure migration; the §"Defensive coding" rule applies going
  forward, not retroactively.
- Migrating asserts inside `src/notes/staging/ecs-original.zig`
  — frozen reference copy, not built.

## After the sweep

- The follow-up coding rule (write asserts liberally, always pass
  `@src()`) is already documented in `claude.md`.  No further docs
  to update.
- The `alwaysAssert` form is now ready for first use whenever a
  memory-corruption invariant comes up.  Don't pre-emptively
  convert "important-looking" asserts to `alwaysAssert` during
  this migration — that's a different decision per site.

## Suggested turn-by-turn execution

| Turn | Phase                            | Sites done | Cumulative |
| ---- | -------------------------------- | ---------- | ---------- |
| N+1  | Phase 0 + Phase 4 (3 mop-up)     | 3          | 3 / 180    |
| N+2  | Phase 1 (codecs)                 | 38         | 41 / 180   |
| N+3  | Phase 2 (math, with helper)      | 64         | 105 / 180  |
| N+4  | Phase 3 (entities)               | 74         | 179 / 180  |
| N+5  | Phase 5 (kill dead variants)     | (cleanup)  | 180 / 180  |

5 turns end-to-end if focused.  Phase 4 piggybacks on Phase 0 to
make the first turn worth its setup cost.  Phases 1-3 are large
enough that each warrants its own turn; the alternative
(bundling) risks a sloppy fmt-string pass.

Last meaningful update: this initial draft.
