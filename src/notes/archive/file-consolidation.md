# File consolidation plan

zimr has 27 src files (excluding tests/zigimg/web), 22 test files, and
a vendored zigimg with 56 files.  This doc evaluates which deserve
merging.

## Headline recommendation

**Don't merge zigimg into one file.**  Reasoning below (it's
counterintuitive, but the upstream-tracking cost outweighs the
file-count win).  A few zimr-side merges are clear wins.

## The zigimg case — DON'T merge

It looks tempting: 56 files, many under 200 LOC, one logical unit
(image decode/encode), one re-export at `pub const zigimg =
@import("zigimg/zigimg.zig")`.  Let's enumerate the actual costs and
benefits.

### Cost of merging zigimg → 1 file

1. **Upstream cherry-picks die.**  The whole point of vendoring
   zigimg under `src/zigimg/` with the upstream layout preserved
   verbatim (per the header comment in zigimg.zig) is that we can
   pull bug fixes from upstream without manual translation.
   Concrete: a fix to PNG filtering at `formats/png/filtering.zig`
   is a `git diff` away.  In a merged file it becomes "find the
   right region of a 23 000-line file and patch by hand".  Multiply
   by the ~6-12 fixes/year a healthy upstream produces.

2. **Compile-time cost goes UP, not down.**  Zig caches per-file in
   `.zig-cache`.  A 23 000-line megafile recompiles entirely on any
   touch.  56 files recompile only the ones we actually modify
   (which is almost never — we don't edit zigimg).

3. **Naming collision risk.**  zigimg has at least three different
   `Image` types (top-level `Image`, `Image/Editor.zig`,
   `Image/Managed.zig`), nested `types.zig` in `formats/png/`,
   `formats/tiff/`, `formats/jpeg/JFIFHeader.zig` etc.  Merging
   forces hundreds of renames or deeply-nested namespaces.

4. **The Zig 0.16 -ODebug bug we already hit (Session N+54)**
   triggered on the comptime-iteration of zigimg's
   `all_interface_funcs` dispatch table.  Mashing every format into
   one file would intensify the comptime work LLVM has to do per
   compilation, possibly hitting more such bugs.

5. **Editor / IDE traversal.**  ZLS jump-to-def is much more
   useful with one symbol per file (or close to it).  Searching
   "where is `formatDetect` defined" inside one giant file vs. one
   per format is the difference between Ctrl-P and grep+jump.

### Benefit of merging zigimg

1. Top-level `src/` reads cleaner — one `zigimg.zig` instead of a
   `zigimg/` subdir.  But this is purely visual; we already have
   the subdir hidden behind a single re-export.
2. Slightly smaller wasm bundle?  No — the linker eliminates dead
   code per-symbol, not per-file.

### Verdict

**Keep zigimg as-is.**  The vendored-with-upstream-layout policy
documented in `src/zigimg/zigimg.zig` is correct.  The cost of
divergence is real (sync friction every time we want a fix), the
benefit is cosmetic.

**One small win available:** `compressions/deflate/` has 9 small
files (Token, BlockWriter, huffman_encoder, Lookup, SlidingWindow,
container, BitWriter, consts, deflate.zig itself) all internal to
the deflate implementation.  These never appear in upstream PRs
independently — they evolve together.  Could merge into one
`deflate.zig` (~1 800 LOC) with a `deflate/README.md` noting the
upstream → merged-file mapping.  But honestly even that's not
worth the merge-conflict risk; defer until upstream stabilizes.

## zimr-side merges — three real wins

### 1. Merge `clock.zig` + `rng.zig` + `logger.zig` + `loader.zig` → `effects.zig`

These four files implement the "no-globals effects" system from the
spring cleanup arc.  Each is small (185 / 168 / 242 / 377 LOC,
total 972).  They follow identical patterns (Self type with vtable +
userdata, default singleton, Mock/Capture/Seeded test variants) and
are imported as a unit in 100% of cases — every consumer that
imports one imports all four.

Concrete benefits:
- Style consistency enforceable in one place
- Cross-references stay local (`clock_mod.Mock` vs.
  `effects.Clock.Mock`)
- Test fixtures could share helpers
- Removes 4 entries from build.zig's test list (they all become
  one `effects_test.zig`)

Test side: `clock_test.zig` (68) + `rng_test.zig` (131) +
`logger_test.zig` (175) + `loader_test.zig` (256) = 630 LOC into
`effects_test.zig`.

Effort: ~1 turn.  Mechanical.  No public API change because the
re-exports at `zimr.zig` lines 63-66 already abstract the file
location.

### 2. Merge `errors.zig` + `libc.zig` → roll into the modules that need them

- `errors.zig` (39 LOC) defines just `LoadError` and re-exports
  `PngError` / `FetchError`.  Now that we're about to drop
  `src/png.zig` (Turn 7 in the next-10 plan), `LoadError` will only
  reference `fetch_mod.Error`.  At that point `errors.zig` is
  10-15 LOC of trivial type aliasing.  Move `LoadError` to
  `zimr.zig` (where it's already publicly exposed) and delete
  `errors.zig`.

- `libc.zig` (20 LOC) is a tiny shim — likely a `memset`/`memcpy`
  alias or similar.  Verify, then move into the one or two callers
  that need it.

Effort: ~half a turn after Turn 7's png removal.

### 3. Merge `font_default.zig` into `text.zig`

`font_default.zig` (291 LOC) is exclusively the embedded default
bitmap font data + the `loadDefaultFont` function.  It's used by
exactly one caller: `text.zig`.  No tests reference it directly.
The split exists from earlier when `text.zig` was already huge,
but it's still huge (1553 LOC) so the split doesn't help.

Better split would be to break up `text.zig` itself by topic
(layout vs. measurement vs. font loading vs. default font) — but
that's a much bigger restructure.

For now: just inline `font_default.zig` into `text.zig`.  The 291
extra lines disappear behind a `// ---- DEFAULT FONT (embedded
bitmap) ----` banner.

Effort: ~10 minutes.

## Other consolidations — DON'T

### `rlgl.zig` + `rlgl_gpu.zig` (1085 + 1382 = 2 467 LOC)

Tempting because they're a logical pair (rlgl constants vs. rlgl
GPU functions).  But:
- `rlgl.zig` is constant definitions only — it's host-importable.
- `rlgl_gpu.zig` has wasm-only externs (`rlLoadTexture` →
  WebGL forwarder).
- Tests can run rlgl_test.zig on host without dragging in
  the GL forwarders.

Merging would force `rlgl_test.zig` to gate every test under
`if (builtin.target.cpu.arch.isWasm())` or move all the constants
out to a third file.  Net: more complexity, not less.

### `shapes.zig` (1 771) + `textures.zig` (2 951) + `models.zig`
(2 967) + `text.zig` (1 553)

These are the four big modules covering most of zimr's public
surface.  They're already at the upper end of "single-file
manageable" — splitting them up would help comprehension, but
merging them into each other would not.  Each maps to a clean
raylib module (rshapes / rtextures / rmodels / rtext) and that
parity is valuable for cross-referencing the cheatsheet.

### `core.zig` + `zimr.zig`

`core.zig` (456) is the lower-level lifecycle (App.create / WASI
shim setup / dom log forwarders).  `zimr.zig` (727) is the
public-facing entry surface (z.run, z.init, Frame, all the
re-exports).  The split makes the entry surface (zimr.zig)
readable as the API doc it actually is.  Merging would bury the
public surface in lifecycle plumbing.

### `web/` subdir (4 files: dom 118 + gl 439 + fetch 119 + audio 42)

These are all wasm-only browser-bridge externs.  Could merge into
one `web.zig` (~720 LOC).  But:
- `audio.zig` is currently a 42-LOC stub (audio arc deferred);
  it'll grow when we actually start that arc
- `gl.zig` (439) is by itself most of the merged file's mass; the
  others are small bridges to specific browser APIs
- The subdir keeps the wasm-only-ness obvious from the file path

Verdict: leave alone for now, revisit once the audio arc
materializes.

## Bonus suggestions

### Move `truetype.zig` (2 491 LOC) and `rectpack.zig` (151 LOC) under a `vendor/` subdir

`truetype.zig` is Andrew Kelley's port of stb_truetype (MIT
inline header).  `rectpack.zig` is our own shelf-bin packer but
it's small and well-scoped.

Currently they sit at `src/truetype.zig` and `src/rectpack.zig`,
which puts them in the same namespace as the curated zimr surface.
Both are infrastructure that the user shouldn't import directly.

Suggested move:
- `src/vendor/truetype.zig` (with same header)
- `src/vendor/rectpack.zig` (mark as "internal — used by text.zig
  for atlas baking; not part of the public API")

This sits next to `src/zigimg/` which is also vendored.  Public
re-exports stay in `zimr.zig`.

Effort: ~15 minutes (move + update imports).

### Split `text.zig` (1 553 LOC) into 3 files — OPPOSITE of merging

`text.zig` is the awkward middle child.  It's currently:
- Default bitmap font (would be 1 844 LOC if we inline
  `font_default.zig` per item #3 above)
- TTF loading (`loadFontFromTtfData`, `bakeFontAtlas`)
- Drawing (`drawText`, `drawTextEx`, `drawTextPro`)
- Measurement (`measureText`, `measureTextEx`)

Possible split:
- `text/font.zig` — loading + atlas + default font (~700 LOC)
- `text/draw.zig` — drawing functions (~500 LOC)
- `text/measure.zig` — measurement (~350 LOC)

Each maps to a coherent set of raylib functions.  Public
namespace `z.text.*` stays the same via a `text.zig` aggregator.

Conflicts with item #3.  Pick one or the other; both is
over-engineering.  My recommendation: **skip the split for now**,
do item #3 (inline font_default), revisit splits if `text.zig`
crosses 2 500 LOC.

### Move `multiapp_test.zig` and `leak_test.zig` into a `tests/` subdir

These two tests don't have a paired source file (they exercise
multi-module behaviour).  They sit in `src/` next to module-paired
tests, which is mildly confusing.

Suggested:
- `src/tests/multiapp_test.zig`
- `src/tests/leak_test.zig`

Update `build.zig`'s test list paths.

Effort: ~10 minutes.

## Recommended ordering

If we want to spend ~2-3 turns on file consolidation between the
example-porting work in next-10-turns.md, do them in this order:

1. **Inline `font_default.zig` into `text.zig`** — 10-min trivial win
2. **Drop `errors.zig`, move LoadError into `zimr.zig`** — half-turn,
   best done WITH Turn 7 of the next-10 plan (which removes png.zig
   and changes LoadError's shape anyway)
3. **Move truetype + rectpack under `src/vendor/`** — 15 min
4. **Move multiapp + leak tests under `src/tests/`** — 10 min
5. **Merge clock + rng + logger + loader into `effects.zig`** — 1
   turn, the largest item.  Worth doing because it unifies a
   coherent system that's currently scattered

Skip:
- All zigimg merging (upstream-tracking cost)
- All rlgl merging (host vs. wasm split is valuable)
- Big-module merging (shapes/textures/models/text already mapped
  to raylib parity)
- `web/` merging (premature; revisit with audio arc)
- `text.zig` splitting (premature; revisit at 2 500 LOC)

## Total cleanup yield

If we did items 1-5 above:
- 27 zimr-side src files → 23 (-4)
- 22 test files → 19 (-3, with multiapp+leak relocated rather than
  deleted)
- Cleaner `src/` listing: vendor/ subdir for truetype/rectpack,
  tests/ subdir for multi-module tests, `effects.zig` instead of
  4 files

zigimg's 56 files stay as-is.  Documenting "we considered merging
and decided not to" is itself valuable for future contributors who
will have the same instinct.
