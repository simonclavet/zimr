# font-default-plan.md

> **Style guide reminder.**  Before executing any phase below,
> apply these rules to all new and modified code (full text in
> `src/notes/claude.md`):
>
> 1. Function args — 1 per line for 3+ args, trailing comma.
> 2. Locals — explicit types (`const i: usize = ...`).
> 3. Braces — required on every if/else/while/for branch.
> 4. Comments — casual, what + why, no decoration.
> 5. Array-of-N-copies — `@splat(...)`, not `**`.
> 6. Magic literals — lift to named locals before the call.
> 7. Conditions — trivial; lift complex sub-exprs to bools.
> 8. Helpers — only when name does real work AND it'll see a
>    second caller, or chunks are genuinely separable.
> 9. No module-level mutable globals (whole codebase, JS-
>    bridge in `src/zimr.zig` excepted).
> 10. Lines ≤ 120 cols; trailing commas force multi-line.
> 11. Integer types — `i32` / `usize` defaults; never `c_int`.
>
> Touching a function means bringing the whole function up to
> spec, not just the change.

---

## TL;DR

**Goal:** make zimr's default font **Atkinson Hyperlegible
Mono** (not the raylib bitmap font).  zimr apps should look
distinctively like zimr apps without any caller affordance.

**Scope:** **4 turns**.  The TTF is already embedded in
`src/drawing.zig` (`text.atkinson_mono_ttf`); this plan covers
the migration of `loadFontDefault` from bitmap to TTF, plus the
caller updates across ~50 examples and ~10 internal call sites.

**License:** SIL Open Font License 1.1.  Compatible with
zimr's overall license.  Full text in
`src/assets/atkinson_mono_LICENSE.txt`.

**Per-turn outline:**

| Turn | Theme | Output |
|---|---|---|
| F1 | API surface | `loadFontDefault(gpa, *FontCache)`; old bitmap path remains as `loadFontRaylibBitmap` |
| F2 | Internal call sites | runtime/UI font cache wiring updated |
| F3 | Examples migration | ~50 examples updated; smoke 92/92 clean |
| F4 | Capstone refresh + close | `ui_full_showcase` shows off the font; arc-close gates |

---

## Architectural decisions

### 1. Default font_size: **16**

The raylib bitmap default rendered at 10 pixels.  At 10 px,
Atkinson glyphs are too small to be readable — defeating the
"hyperlegibility" reason for picking this font.  Default size
moves to 16 pixels.

Tradeoff: widget heights computed from `font_size` shift up
proportionally.  ImGui-derived defaults (`frame_padding`,
`item_spacing`, button heights, etc.) scale automatically since
they're already expressed in multiples of `font_size`.  Tables,
plots, drag-drop ghost windows — all auto-fit.

Risk: some examples have visual layouts tuned to the 10-px
metric.  Phase F3 audits them; layouts that break get fixed in
the same turn.

### 2. Allocator on the load path

The bitmap default fit in `FontCache`'s fixed buffers (224
glyphs at fixed 8×10).  Atkinson at 16 px is variable-width;
stb_truetype's atlas baker allocates dynamically.  So
`loadFontDefault` needs an allocator:

```zig
// Before:
z.text.loadFontDefault(&s.font_cache);

// After:
z.text.loadFontDefault(gpa, &s.font_cache);
```

All call sites are in `initState` functions or runtime init
paths where `gpa` is in scope.  No example needs new plumbing.

### 3. Codepoint coverage: **ASCII 32-127** at v1

For v1 we bake codepoints 32 (`' '`) through 127 (`~`) — same
range the raylib bitmap covered minus the extended bytes
128-255 (which were box-drawing / accented characters that no
existing example uses).  Extended Latin / Cyrillic / Greek /
emoji are a future enhancement; the codepoint range is a
single `[]const u21` slice passed to `loadFontFromTtfData`.

### 4. The bitmap path is **not deleted**, just renamed

The ~7KB of bitmap default-font data + the unpack loop stays
in `drawing.zig` under the new name `loadFontRaylibBitmap`.
Rationale: it's a legitimately useful alternative for
extremely low-pixel-density contexts, and it costs nothing to
keep available.  Examples that want the old aesthetic opt in.

### 5. FontCache fixed buffers — repurposed not deleted

`FontCache.atlas_pixels: [128*128*4]u8` and `glyph_pixels: ...`
were sized for the bitmap default's atlas.  After migration,
these become scratch buffers that `loadFontDefault` writes
into during TTF baking before the GPU upload.  Atkinson at 16
px / 96 glyphs / typical advance widths fits in a 128×128
atlas — no allocator growth needed at runtime.

If a future enhancement increases the codepoint range past
what fits in 128×128, `FontCache` grows to 256×256 (256 KB
atlas pixels in BSS) or moves to allocator-owned.  Decision
deferred until needed.

---

## F1 — API surface + migration — **SHIPPED Turn 194**

F1 absorbed F2 and F3 because Zig has no function overloading:
once `loadFontDefault`'s signature changed, every existing
caller broke at compile time.  Shipping F1 alone would leave
the tree in an uncompilable state.  All three phases collapsed
into one turn.

What landed:

- **API surface.**
  - `loadFontDefault(gpa: Allocator, state: *FontCache) !void` —
    the new "branded default."  Bakes ASCII 32-127 from the
    embedded `atkinson_mono_ttf` at 16 px, padding 1, via
    `loadFontFromTtfData`.  Idempotent on `state.loaded`.
    Errset is `LoadFontError` (OOM, TtfParseFailed, AtlasOverflow,
    GpuUploadFailed).  Host builds short-circuit on `comptime
    !is_wasm` so host examples stay allocator-free.
  - `loadFontRaylibBitmap(state: *FontCache) void` — the old
    bitmap loader, renamed.  Available for callers who want
    the retro aesthetic.  Allocator-free; uses the fixed
    buffers on `FontCache`.
  - `unloadFontDefault(gpa: Allocator, state: *FontCache) void` —
    signature change; now frees the TTF allocator-owned glyph
    data via `unloadFont`.  Bitmap path has its own
    `unloadFontRaylibBitmap(state)` companion.
  - `DEFAULT_FONT_CODEPOINTS: [96]u21` — module-level const
    holding the ASCII 32-127 range, so its address can flow
    into the runtime `loadFontFromTtfData` call (a comptime-
    local var can't escape to runtime).

- **Mass migration.**  71 example files updated by a Python
  script (`re.sub` over the call patterns):
  - 21 example `initState` signatures un-anonymized: `_:
    std.mem.Allocator` → `gpa: std.mem.Allocator`.
  - 71 call sites updated: `z.text.loadFontDefault(&fc)` →
    `try z.text.loadFontDefault(gpa, &fc)`.
  - The `!State` inferred error union on `initState` absorbs
    `LoadFontError` automatically; no example needed an
    explicit error-set annotation.

- **Internal rename.**  `loadFontDefaultImpl` →
  `loadFontRaylibBitmapImpl` and `unloadFontDefaultImpl` →
  `unloadFontRaylibBitmapImpl` for consistency.  Only called
  inside `drawing.zig` so no external surface affected.

- **Gates.**
  - install (`--release=small`): clean.  wasm.js 42.21 KB
    unchanged.  Per-wasm size +100-150 KB across the tree —
    the 34 KB TTF embed plus a small bake-path code increment.
  - smoke: **93/93 PASS** (zero visual regressions detected
    at the GL-call-count level — sub-pixel layout differences
    won't show in a headless count).
  - test: **1272/1278** held.
  - fmt + globals + DAG: clean.

- **Verification standalone.**  `prebuilt/standalone/ui_input_callbacks.html`
  rebuilt; opens with the new Atkinson rendering of every UI
  label and input field.  Visual confirmation that the
  migration produces the intended font, not just "doesn't
  crash."

### Notes for future-Claude

- The `loadFontFromTtfData` errset surfaces real failure modes
  (`AtlasOverflow`, `TtfParseFailed`).  For the embedded
  Atkinson bytes at the chosen parameters none of these can
  actually fire, but the error path is real for users who
  load their own TTFs through the same baker — leave the
  `try` in place even when callers know it can't fail.
- `loadFontFromTtfData` is now the hottest path on startup.
  If wasm startup latency becomes a concern, the TTF bake
  could move to a build-time step that produces a pre-baked
  atlas blob; that's a future optimization, not for this arc.

---

## F2 — Internal call sites — absorbed into F1

F1's signature change broke compilation everywhere; F2's
"audit internal call sites" became "fix the only internal
call site that exists" (`src/drawing.zig` itself, where the
function is defined — already covered by the F1 rewrite).
No other internal callers were found by `grep -rE
"loadFontDefault\(" src/ 2>/dev/null`.

## F3 — Examples migration — absorbed into F1

The mechanical sweep over 71 example files happened the same
turn for the same reason — couldn't ship F1 in a compilable
state without it.

---

## F4 — Capstone refresh + close (1 turn)

- [ ] `ui_full_showcase.zig` gets a small "Fonts" subsection
      demonstrating `pushFont(font_x)` for a section in a
      different size or weight.
- [ ] Arc-close CHANGELOG entry covering F1-F4.
- [ ] Archive this plan to `src/notes/archive/`.
- [ ] `PLAN.md` row marked complete.

---

## Open questions (resolve before F1)

1. **Does stb_truetype handle weight-variant TTFs?**  Atkinson
   Mono ships as a variable-weight font.  We embed the
   "Regular" static (`static/AtkinsonHyperlegibleMono-Regular.ttf`)
   not the variable-weight master.  Sanity: confirm
   `loadFontFromTtfData(... atkinson_mono_ttf ...)` returns
   without error.
2. **`font_size` — store on FontCache or pass per-call?**
   ImGui has `style.font_size`; raylib has a per-call size
   param.  zimr today has BOTH (`Style.font_size` for ui
   widgets, explicit param for `text.drawEx`).  No change
   needed in the migration — the TTF gets baked once at size
   16, and rendering scales from there.  Whether 16 stays the
   default `Style.font_size` is a tweak in F1.
3. **What about the legacy `default_font_data: [512]u32`
   const?**  It's ~7 KB of comptime data.  After
   `loadFontRaylibBitmap` is the only consumer, keep it; the
   wasm cost is negligible and it preserves the option to use
   the raylib aesthetic.

---

## Why a separate plan and not absorbed into imgui-parity?

The imgui-parity arc is already 26 turns.  Tacking on 4 more
"loosely related" font-default turns muddles its scope.
Cleaner to ship font-default as its own arc and slot it before
or after Phase B of imgui-parity.

Recommended ordering: **font-default first**, THEN resume
imgui-parity at A4 (InputTextCallbackData).  Why first?
Because once the font is the new default, every demo we ship
during imgui-parity automatically gets the branding effect.
Migrating after would mean retroactively re-snapshotting demo
visuals.

---

# Addendum — turn 330: revisit "default font" altogether

The footgun-fix this turn (`beginFrame` now lazy-calls
`loadFontDefault`) shipped under pressure to unstick the phone
debug.  Simon's reaction, paraphrased: *"I don't really like
the concept of default font.  Users should bring their own font
and embed or load it themselves.  I like explicit, verbose.
Having a default font always felt wrong to me."*

This addendum:
  (a) records both sides of the argument so future-me can
      revisit with full context,
  (b) sketches the migration if we decide to remove the
      default, and
  (c) commits to a near-term direction without blocking
      ongoing docking work.

## The case for keeping a default font (current state)

1. **Hello-world friction.**  Without a default, every demo
   needs ≥ 1 explicit line in `initState`.  zimr aims to be
   raylib+imgui-like and both have defaults built in.  The
   industry convention skews toward bundled defaults.
2. **Branding.**  The Atkinson Hyperlegible Mono default IS the
   zimr aesthetic — see the entire pre-330 part of this plan
   document.  Removing it removes a tiny but real piece of
   identity.
3. **The TTF is small.**  34 KB compressed.  At present-day
   bundle sizes (~500 KB for a docking standalone) it's noise.
4. **Lazy-load fixes the footgun without losing the default.**
   Turn 330's `beginFrame` auto-call eliminates the silent-
   failure mode that Simon hit.  Plus the new
   `warned_text_no_font` one-shot warning surfaces future
   regressions immediately.

## The case for removing the default (Simon's position)

1. **Implicit-default-bad.**  Every other zimr resource
   (textures, audio, shaders, meshes) requires explicit
   loading.  Text being the lone exception is inconsistent.
   The footgun this turn is symptomatic — implicit defaults
   hide what the user actually depends on.
2. **Explicit is better than implicit.**  zimr's audience is
   game developers and tool builders, not "I want a button on
   a web page" users.  They have opinions about typography.
   The "I just want text to work" optimization mistargets the
   audience.
3. **License + binary weight.**  The Atkinson TTF (OFL) is
   fine, but it's *another* third-party asset entangled with
   the core library — extra files, extra license footnote,
   extra reason to vet on every release.  Removing it makes
   the core leaner.
4. **The lazy-load is a hack.**  It papers over a missing
   user-side init by silently doing work in `beginFrame`.
   That's a category we usually avoid — beginFrame is
   "consume the user's setup," not "complete the user's
   setup."
5. **Hello-world friction is one line.**  `try
   z.loadFontFromTtfData(gpa, &s.font_cache,
   z.fonts.atkinson_mono, 32, &.{...});`  Or, if we keep
   `loadFontDefault` as an *explicit* opt-in convenience, the
   line is just `try z.loadFontDefault(gpa, &s.font_cache);`.
   Either way: one line.

## Direction (turn 330 commit, locked turn 331)

Going with **Option A**, maximal removal — no default font, no
named-asset convenience, no embedded TTF in the core library.
Simon's reasoning, in his words: *"There is no default
texture, mesh, sound.  Font is the same.  Zimr value
proposition is extreme explicitness and verbosity."*

This is consistent: every other resource in zimr requires the
user to bring their own bytes (whether via `@embedFile`, a
runtime load, or procedural generation).  Text gets the same
treatment.

**Option A — maximal removal (chosen):**
  - Delete `loadFontDefault` from `drawing.zig`.
  - Delete `getFontDefault` (or reduce it to "return
    `state.font` unconditionally" if any caller still needs
    it).
  - Delete the embedded `atkinson_mono_ttf` constant and the
    `DEFAULT_FONT_CODEPOINTS` constant.
  - Revert the lazy-load in `beginFrame`.  Restore the
    `*const FontCache` parameter (mutability is no longer
    needed).
  - Every example does its OWN `@embedFile` of a TTF and
    calls `loadFontFromTtfData(...)` in `initState`.  No two
    examples need to share an asset; the redundancy is the
    point.
  - The `warned_text_no_font` one-shot warning STAYS — its job
    is loud failure when a user forgets the font load.

**Option B and the "named asset" middle ground are rejected.**
Both keep the library entangled with a specific font and a
specific opt-in API.  The clean version is: zimr is a
graphics + UI runtime, not a typography vendor.

## Plan to execute (when scheduled)

Estimated cost: **1-2 turns**.  Larger than the earlier estimate
because we're also touching the asset-bring-your-own surface.

  P1.  Revert the lazy-load in `UiContext.beginFrame`.  Restore
       the `font_cache: *const drawing.text.FontCache`
       parameter type.
  P2.  Delete `loadFontDefault`, `atkinson_mono_ttf`, and
       `DEFAULT_FONT_CODEPOINTS` from `drawing.zig`.  Audit
       callers: `getFontDefault` may need to stay (callers
       use it as "read the bound font," not "load default").
  P3.  Sweep every example.  Most options:
       - **Embed approach**: each example does
         `const atkinson_mono = @embedFile("../assets/fonts/atkinson_mono.ttf");`
         then `try z.loadFontFromTtfData(gpa, atkinson_mono, 32, &codepoints, 1);`
       - **Same TTF, no shared module**: ship the .ttf file
         under `assets/fonts/` so examples can `@embedFile`
         it via a relative path.  Library doesn't depend on
         it — it's example-local content.
  P4.  Sweep host screenshot tests.  These can't render text
       on native regardless (wasm-only loader), but the
       `font_dummy: FontCache = .{}` setup should be retained
       and documented as "intentionally no text in host
       PNGs."
  P5.  Update `claude.md` and `getting-started.md` with the
       explicit-font-load idiom + a one-line rationale ("zimr
       does not bundle a default font; pick one and embed it
       like any other asset").

## Deferred concerns

- **Native screenshot tests rendering text.**  Independent of
  the default-font decision.  `loadFontDefault` is wasm-only
  by design (the TTF baker uses GPU upload paths only
  available there).  For host PNGs to show text, we'd need
  either:
    (a) a software glyph rasterizer in `rlsw` that consumes
        baked atlases, or
    (b) a native code path in `loadFontFromTtfData` that
        produces a CPU-side bitmap atlas usable by rlsw,
    plus rlsw consulting it during text draw.  Substantial
  work, separate plan.

## What to tell Simon (recorded turn 331)

Locked-in choice: Option A.  Won't do the sweep this turn —
keeps docking momentum — but slot it after 5.5k (persistence)
and before 5.5l (demos polish), so the demos are polished
only AFTER the explicit-load idiom is in place.
