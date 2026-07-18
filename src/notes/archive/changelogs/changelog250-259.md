# CHANGELOG — turns 250-259

Per-turn journal for turns 250-259.  **FROZEN** — turn 260 opened a
fresh `changelog260-269.md`.  Do not edit existing entries.

Earlier turns: see the sibling files in this directory
(`changelog240-249.md`, `changelog230-239.md`, `changelog220-229.md`,
`changelog210-219.md`, `changelog200-209.md`, `changelog093-199.md`,
`changelog001-092.md`).

---

### Turn 259 — WIP disclaimer on README + main page

Simon: "Prebuilt is the correct folder.  At the top of the readme
and the main page, add a clear work in progress disclaimer: the
port is not complete and full of bugs."

Two-place edit.

**1. `README.md`.**  Added a blockquote-styled disclaimer right
under the `# zimr` title, before the link to the published page:

    > **⚠ Work in progress.** The port is incomplete and full of bugs.
    > Not ready for production use; not stable across days.

Stays a 9-line README total.

**2. `src/web/readme.html`.**  Added a `.wip-warning` CSS block
matching the brutalist palette — 4px terracotta border, deep
block background (`--bg-block`), 6px-6px hard shadow — and
inserted the warning div between the subtitle and the top nav
strip.  Reads:

    ⚠ WORK IN PROGRESS
    The port is incomplete and full of bugs.  Many raylib features
    are missing or partially implemented; many that are present
    have rough edges.  Not ready for production use; not stable
    across days.

The "WORK IN PROGRESS" line uses uppercase + letter-spacing +
the terracotta accent color in the header font (Georgia) to
distinguish it from the body text inside the warning box.
Positioned ABOVE the nav strip so it's the first thing visible
after the title and subtitle — readers can't miss it.

**Pipeline.**
- `zig build install`: refreshed `zig-out/web/readme.html`.
  Cached, ~3s.
- `zig build dist`: copied to `prebuilt/readme.html`,
  byte-identical to source.

**Audit.**
- `zig build test`: 104/104 steps, 1373/1373 PASS ✅.

**Files touched** (2):
- `README.md` — 4 lines added (the blockquote disclaimer).
- `src/web/readme.html` — `.wip-warning` CSS rule + a 4-line
  div in the body.

---

### Turn 258 — README → HTML on Codeberg pages

Simon's request: take the README content, convert it to a styled
HTML page in the Codeberg-pages-published folder, shrink
`README.md` itself to just a link.  Provided a dark-warm-brutalist
HTML template to use as the style anchor (deep espresso brown
background, terracotta accent, Courier body + Georgia headers,
harsh box-shadows).

**1. Created `src/web/readme.html` (~640 lines).**  Full README
content converted to HTML using the brutalist template's CSS
palette and structure, with code-readable adaptations:

- Bumped `max-width` from the template's 480px to 760px so
  80-char Zig code lines fit without aggressive horizontal
  scrolling.
- Added `<pre>` and inline `<code>` styling matching the
  brutalist palette: dark code block background, terracotta
  left border, harsh box-shadow.
- Added `<table>` styling (the template didn't have one, and
  the README has two — the bundle-size table and the license
  attribution table).
- Added a top nav strip below the subtitle with three buttons:
  example gallery (`index.html`), API docs
  (`docs/index.html`), source on Codeberg.
- Wrapped the human-use disclaimer in a highlighted box at the
  bottom (`.disclaimer` class) so it visually separates from the
  license prose above it.
- All twelve code examples preserved verbatim from the README,
  HTML-escaped where Zig syntax collides with HTML (`&gt;` in
  switch arms `.ok =>`, `<` in `while (i < count)`).

**2. `build.zig` install rule.**  Added `src/web/readme.html → readme.html`
to the inline tuple list at line ~419 so the file gets copied to
`zig-out/web/readme.html` by `zig build install` and from there
into `prebuilt/readme.html` by `zig build dist` — landing in
Simon's existing Codeberg-pages publish pipeline without
introducing any new infrastructure.

**3. `README.md` shrunk.**  Was ~600 lines after the turn 257
rewrite; now 7 lines.  Just a title, a link to the published
HTML page, and a fallback source link.  The original prose is
archived at `src/notes/readme-old-text.md` for reference (since
git history has it too, but a working-copy artifact is faster to
grep).

**Pipeline test.**
- `zig build install`: lands `readme.html` (38881 bytes) in
  `zig-out/web/`.  Cached, 4s.
- `zig build dist`: copies into `prebuilt/readme.html`,
  byte-identical to source (`diff` returns clean).

**Audit.**
- `zig build test`: 104/104 steps, 1373/1373 PASS ✅
- No smoke this turn — adding a static HTML file changes
  nothing for wasm output, and the install ran cached.

**Files touched** (4):
- `src/web/readme.html` — new file, ~640 lines.
- `build.zig` — one entry added to the static-files install
  tuple.
- `README.md` — replaced (~600 lines → 7 lines).
- `src/notes/readme-old-text.md` — new archive (copy of the
  pre-shrink README content).

**One uncertainty Simon should confirm:**
- The published URL in the README.  Guessed
  `https://simonclavet.codeberg.page/Zimr/readme.html` from the
  Codeberg-pages user/project convention, but the exact URL
  depends on how Simon's pages are configured (could be
  lowercase `zimr`, could be a different domain).  README needs
  to point at the real URL — currently a best guess.

---

### Turn 257 — README rewrite, LICENSE updates, human-use disclaimer

Three docs items, no production code change.

**1. `README.md` fully rewritten.**  The old README was carrying
several layers of staleness from earlier project phases — API
names that predated the flat-export arc, references to deleted
files (`zimrmath.zig`, `colors.zig`, `text.zig`, etc.), test
counts from turn ~120, an example count from when there were 51
demos, and no mention of zmath or zphys.  Rewritten end-to-end:

- Tone: factual, non-enthusiastic.  No "the smallest demo!" / no
  marketing-speak.  States what zimr is, what it doesn't try to
  be, what's covered, what isn't.
- New "Sister modules" section names zmath / zphys / mr_ecs /
  rlsw with their upstreams and what each contributes.
- All twelve worked examples updated to current API:
  - `z.beginDrawing(f.gl)` / `z.clearBackground(f.gl, color)` /
    `z.endDrawing(f.gl)` (flat exports; old README had
    `z.gl.beginDrawing` etc.).
  - `initState` signature is `fn (gpa, _: *Frame, *State) !void`
    with the state pointer as an out-param (old was returning
    `!State`).
  - `Vector2` is `@Vector(2, f32)`; indexed as `m[0]` / `m[1]`.
  - `Camera3D` is a plain struct with `zm.Vec` fields, built via
    `zm.vec3(x, y, z)`.
  - GPU resources go through `Entities(GpuTexture)` /
    `TextureHandle`; old README still used the raw `Texture2D`
    + manual upload pattern.
  - Touch input uses `z.getTouchPointCount` / `z.getTouchPosition`
    (no `z.input.` prefix).
- File-organization tree reflects the post-flatten layout: no
  more `zimrmath.zig`, `shapes.zig`, `textures.zig`, etc.;
  `drawing.zig` and `runtime.zig` are the merged surfaces.
  Added `math.zig`, `easings.zig`, `physics.zig`, `assert.zig`
  to the tree.  Example count corrected: 51 → 103.
- Build commands reflect current build.zig: `-Doptimize=Debug`
  instead of the long-gone `-Drelease=true`; mentions
  `smoke-install`, `math-test`, `dist` steps that exist now.
- Test counts updated: 1192 → 1373 host tests, 68 → 100 wasm
  smoke tests.
- Removed the broken link to `src/notes/raylib-coverage-gaps.md`
  (file deleted in an earlier cleanup); points at
  `cheatsheet.html` + `src/notes/changelogs/` instead.

**2. `LICENSE` updates.**  The old file had three issues:

- Three upstreams were missing — Dear ImGui, zmath, zphys.
  zimr's ui module is shaped by ImGui, the math module is a
  hard fork of zmath, the physics module is a port of zphys.
  All three are MIT.  Added full sections for each with the
  verbatim MIT text (per the upstream license's
  notice-preservation clause).
- `mr_ecs` section referenced `src/ecs.zig` (file was renamed to
  `entities.zig` during the flat-export arc) and `raymath.zig`
  (file was deleted in the wave-6 cleanup, math is now in
  `math.zig`).  Fixed both.
- Duplicate `Roboto Mono` section (two slightly different
  versions of the same entry, ~50 lines).  Consolidated to one.
- Tailwind palette section pointed at the deleted `src/colors.zig`;
  the palette now lives in `src/types.zig`.  Fixed.
- The raylib-file table listed many deleted files (`rlgl_gpu.zig`,
  `raymath.zig`, `shapes.zig`, `textures.zig`, `text.zig`,
  `font_default.zig`, `models.zig`, `camera.zig`, `shaders.zig`,
  `core.zig`, `input.zig`, `colors.zig`).  Rewrote to current
  layout — `drawing.zig` covers shapes/textures/text/models;
  `runtime.zig` covers core/input.

**3. Human-use disclaimer** appended at the end of `README.md`.
Simon's request: sober, deadpan, but somehow funny — even for
those who hate AI.  Records the actual workflow (Simon operating
Claude from his phone during subway commutes over three weeks),
credits Simon for every non-trivial decision, and notes that
Claude's role was "writing text into a chat box."  Roughly
twenty lines.

**Audit.**
- `zig build test`: 104/104 steps, 1373/1373 PASS ✅
- No smoke this turn — docs-only changes don't affect wasm
  output.

**Files touched** (2):
- `README.md` — full rewrite (was 637 lines, now ~570 lines).
- `LICENSE` — three new upstream sections added (Dear ImGui,
  zmath, zphys), mr_ecs / Tailwind / raylib file-table updates,
  duplicate Roboto Mono section removed.

**Next turn — Simon's open list:**
- Cheatsheet refresh (defer until a sub-API is touched, since
  the generator runs from source — but check for staleness in
  the meanwhile).
- Decide on the proposed claude.md improvements (now 7+
  candidates banked across turns 255 / 256).
- Either ship a focused `**`-to-`@splat` sweep (3 sites in
  `src/codecs.zig` + `src/sound.zig`) or leave them for the
  "touching a function = up to spec" rule to catch.

---

### Turn 256 — `GlAdapter.disable(.texture_2d)` was a no-op (Gouraud darkness bug)

**Simon reported**: in the rlsw_side_by_side standalone, the
Gouraud-shaded triangle is "much darker on WebGL" — i.e. the
left (rlgl) half renders it muddy while the right (rlsw) half
shows the vibrant primary-color gradient as intended.  Confirmed
visually in the screenshot Simon shared.  Also confirmed: the
turn-255 divider-alignment fix works (finger and divider line up).

**Root cause** in `src/renderer_trait.zig`:

```zig
pub fn disable(self: *GlAdapter, cap: rlsw.Capability) void {
    _ = self;
    switch (cap) {
        .depth_test => rlgl.fwd.rlDisableDepthTest(),
        else => {},                  // <-- .texture_2d falls here
    }
}
```

The example's `drawScene` calls `gl.disable(.texture_2d)` between
the textured-cube phase and the 2D-overlay phase (which includes
the Gouraud triangle).  On the rlsw path, `SwAdapter.disable`
forwards to `self.ctx.disable(cap)` which clears rlsw's
`.texture_2d` capability flag — the rasterizer then skips texture
sampling and outputs vertex colors directly.

On the rlgl path, `GlAdapter.disable(.texture_2d)` was an
unhandled case in the switch.  The checker texture stayed bound;
the rlgl fragment shader continued sampling it; vertices with
no `texCoord2f` calls (the Gouraud triangle's three vertices)
inherited whatever UV the LAST vertex of the previous cube draw
emitted, which sampled some particular cell of the checker.  Final
color = `vertex_color * checker_sample` — when the sample landed
on a dark cell, the triangle came out muddy.

(raylib/rlgl's convention: "no texture" = bind a 1×1 white
texture, so the `× texture` factor is identity.  `rlSetTexture(
state, 0)` does exactly that — see `src/rlgl.zig:1411`, the early-
return branch.)

**Fix** — handle `.texture_2d` in `GlAdapter.enable` / `.disable`:

```zig
pub fn enable(self: *GlAdapter, cap: rlsw.Capability) void {
    switch (cap) {
        .depth_test => rlgl.fwd.rlEnableDepthTest(),
        // rlgl has no "texturing enabled" flag — caller binds via
        // rlSetTexture.  No-op for parity with rlsw's flag.
        .texture_2d => {},
        else => {},
    }
    _ = self;
}

pub fn disable(self: *GlAdapter, cap: rlsw.Capability) void {
    switch (cap) {
        .depth_test => rlgl.fwd.rlDisableDepthTest(),
        // Bind default 1×1 white so vertex_color × texture = identity.
        .texture_2d => rlgl.rlSetTexture(self.state, 0),
        else => {},
    }
}
```

**Why this was a single-line trap.**  The bug surface depends on
how the example chains state: a textured draw, then a vertex-color
draw with no texture change.  On rlsw the flag-based abstraction
correctly diverges; on rlgl, the binding-based abstraction needs
an explicit unbind to match.  The `gl_iface` was hiding the
difference behind a single `.disable(.texture_2d)` call, but only
one side actually implemented it.  Any example using BOTH paths
that wants "now I'm drawing without a texture" will hit this; the
rlsw_side_by_side demo is currently the only such example, hence
why it took until now to surface.

**Audit gate.**
- `zig build test`: **1373/1373 PASS** ✅
- `zig build smoke-test --release=small -Dfocus=rlsw_side_by_side`:
  **1/1 PASS**, 6046 gl calls.  Smoke can't visually verify color
  output, but it confirms the example boots and runs the full
  6046-call sequence without crashing.
- `zig build install --release=small`: 235 KB rlsw wasm
  (was 235 KB before; +36 bytes from the slightly longer code path)

**Visual verification pending**: Simon to confirm the Gouraud
triangle now reads as bright red/green/blue gradient on the rlgl
half too.

**Files touched** (3):
- `src/renderer_trait.zig` — added `.texture_2d` cases to GlAdapter
  enable/disable (~20 lines including comments)
- `prebuilt/standalone/rlsw_side_by_side.html` — rebuilt with the
  fix, copied to `/mnt/user-data/outputs/`

**Open items rolling forward to next turn:**
- README + cheatsheet refresh
- Physics engine attribution
- Decide which of the 4 proposed claude.md improvements (turn 255)
  to bank.

**Addendum (same turn, after Simon re-confirmed the bug from a
fresh phone screenshot):** the fix landed in `renderer_trait.zig`
correctly per the analysis above, but the standalone build never
made it into the user's hands — likely the prior turn's "rebuilt
the standalone" claim ran the script BEFORE the install step
freshened `zig-out/web/rlsw_side_by_side.wasm` against the new
gl_iface, so the bundled wasm was stale.  Rebuild sequence this
turn:

```sh
zig build install --release=small
python3 scripts/build_standalone.py rlsw_side_by_side --no-build \
    --title "rlsw side-by-side"
cp prebuilt/standalone/rlsw_side_by_side.html /mnt/user-data/outputs/
```

Result: `rlsw_side_by_side.wasm` md5 `5bc70da2b94b6c31a16904dc445e38be`
(new bytes; was different before), bundle 360633 bytes (was 360585
in turn 255 = +48 bytes, matching the longer disable branch).
Shipped via `present_files`.  Process pitfall logged for
`claude.md`: **after touching shared rendering code, the standalone
shipping sequence is install-then-build-standalone-then-copy-then-
present_files; skipping the install step ships stale wasm**.

Also: spent ~10 tool calls this turn re-investigating the same bug
from scratch (analyzing `colDiffuse`, vertex attribute encoding,
texture-binding flow, blend state) before finding the existing
turn-256 changelog entry that already documented the diagnosis +
fix.  This is the exact "Read claude.md before reinventing
tooling" failure mode flagged in turn 255's proposed claude.md
additions (item 1 from the list above) — except scaled to
"changelogs," not just claude.md.  Lesson: **on any "user
reports an existing bug" turn, the FIRST step is to grep the
recent changelog for that bug**.  The diagnostic-build
detour (a temporary `DIAG_GOURAUD_ONLY` const) was unnecessary
and was reverted before saving the zip.  Banking this for next
turn's claude.md improvements.

**Second addendum (same turn) — `enable(.texture_2d)` was the
other half of the bug.**  Simon's next phone screenshot showed the
gouraud now renders correctly on both halves ✅, but the
**textured triangle and the sprite quad render solid white on the
WebGL half** while rlsw shows the checker pattern correctly.

Trace: `disable(.texture_2d)` now binds the 1×1 white texture
(turn-256 fix above).  `enable(.texture_2d)` is still a no-op on
the `GlAdapter`.  After `drawTexturedTriangle`'s
`gl.disable(.texture_2d)`, white is bound.  `drawSpriteQuad`'s
`gl.enable(.texture_2d)` does nothing.  White stays bound.  Quad
samples white × (255,255,255) = white.

Architectural mismatch: rlsw has two slots — "which texture is
bound" (persistent) and "is texturing on" (toggleable).  rlgl had
only one slot (`currentTextureId`), so binding white for "off"
loses the user's texture.

Fix — add a second slot to `GlState`:

```zig
/// The last user-bound texture (anything bound via
/// `rlSetTexture(state, id != 0)`).  Tracked separately so
/// `enable(.texture_2d)` can restore it after `disable` swaps
/// in white.  Mirrors rlsw's separate slots.
userTextureId: u32 = 0,
```

- `rlSetTexture(state, id)` for `id != 0`: writes both
  `currentTextureId = id` AND `userTextureId = id`.  Non-zero is
  the "user explicitly binds X" path.
- `rlSetTexture(state, 0)` for `id == 0`: writes only
  `currentTextureId = defaultTextureId`.  `userTextureId`
  intentionally NOT cleared — `id == 0` is the "temporarily
  unbind for untextured drawing" path used by
  `GlAdapter.disable(.texture_2d)`, and the user's pick survives
  for the matching `enable` to restore.
- `GlAdapter.enable(.texture_2d)`: if `userTextureId != 0`, calls
  `rlSetTexture(state, userTextureId)` — the non-zero path
  reopens a draw call with the restored texture.  If the user
  never bound anything (`userTextureId == 0`), this stays a
  no-op.

Now the full flow works as the example intends:
1. `rlSetTexture(checker)` before drawScene → both `current` and
   `user` = checker.
2. Phase A: cube draws with checker.
3. End Phase A: `disable(.texture_2d)` → `current` = white,
   `user` still = checker.
4. drawTexturedTriangle: `enable(.texture_2d)` → restores `current`
   = checker.  Triangle draws with checker ✓
5. drawTexturedTriangle: `disable(.texture_2d)` → `current` =
   white, `user` still = checker.
6. drawBlendOverlay: no texture work; `current` stays white.
7. drawSpriteQuad: `enable(.texture_2d)` → restores `current` =
   checker.  Quad draws with checker ✓

Cache had to be cleared mid-turn (`.zig-cache/` was 5.4 GB, disk
hit 90% full, `zig build install` failed silently with exit 1).
Per claude.md's note: "Bloated caches cause No space left on
device errors."  `rm -rf .zig-cache` reclaimed 5 GB, cold rebuild
took 225s (matches the documented cold timing).

Files touched (3):
- `src/rlgl.zig` — added `userTextureId` field to `GlState`,
  one-line update to `rlSetTexture` non-zero path.
- `src/renderer_trait.zig` — `GlAdapter.enable(.texture_2d)` now
  restores from `userTextureId`.
- `prebuilt/standalone/rlsw_side_by_side.html` — rebuilt with
  both fixes; bundle 360781 bytes (was 360633 = +148 bytes).
  Wasm md5 `0d1e0e5d97d4de582bc8edbff00b2fbf`.

Audit: `zig build test` 104/104 steps, 1373/1373 PASS ✅.

**Third addendum (same turn) — sprite quad still white; the
`rlSetTexture` early-out was the cause.**  After the
`enable(.texture_2d)` restore landed, Simon's next screenshot
showed:
- Gouraud triangle: bright on both sides ✅
- Textured triangle: checker on both sides ✅
- **Sprite quad (top-right rectangle): white on WebGL ❌**, checker on rlsw

Trace through the example's actual draw sequence revealed an
asymmetry in `rlSetTexture` that my `userTextureId` work
inadvertently exposed.

`rlSetTexture(state, 0)` (the disable path) mutates only
`currentTextureId = defaultTextureId`.  It does NOT touch the
open draw call's `textureId` (which still holds the user's
texture from before).  After this, `currentTextureId` and the
draw call diverge: draw has checker, currentTextureId has white.

When `enable(.texture_2d)` calls
`rlSetTexture(state, userTextureId)`, the function compared
`draws[N].textureId != id`.  But in the sprite quad's case, the
draw call N had already inherited `textureId = checker` from the
prior textured-triangle restore (and was reused by the blend
overlay since blend uses `.triangles` mode too — same draw call).
So `draws[N].textureId (checker) != checker` is FALSE — the
early-out fires, `currentTextureId` stays stale at white.

Then `rlBegin(.quads)` for the sprite quad opens a new draw slot
and stamps `textureId = currentTextureId = WHITE`.  The quad
renders white.

Fix: always update `state.currentTextureId = id` in
`rlSetTexture`'s non-zero path, outside the
`draws[N].textureId != id` guard:

```zig
if (state.draws[draw_counter - 1].textureId != id) {
    // close current, advance, stamp new textureId
    ...
}
// Always sync currentTextureId, even when the draw already has
// the texture — the two slots can diverge through the
// `rlSetTexture(state, 0)` path, which writes currentTextureId
// without touching the draw.
state.currentTextureId = id;
state.userTextureId = id;
```

This is a one-line move (`state.currentTextureId = id;` from
inside the if-block to outside).  Idempotent in every case where
the slots were already in sync; corrects the divergence case
exposed by the disable→enable→same-texture re-enable pattern.

Cache cleared mid-turn again (5.4 GB → 12 GB free); cold rebuild
225s.  Wasm md5: `b9256aa93ef43e774caab0286a92cda5` (was
`0d1e0e5d97d4de582bc8edbff00b2fbf`).  Bundle 360781 bytes, md5
`b6c09fc766cf43e3e6eebee2ce7948b1` (was `52d47918b2b680f8ca8afc2c1e39dbca`).

Audit: `zig build test` 104/104 steps, 1373/1373 PASS ✅.

### Turn 256, separate item — style guide correction

Simon: "In claude and claude summary, there is a mistake.  Splat
is mandatory without exception.  `**` has been removed from
language."

Rule 5 in both `src/notes/claude.md` and
`src/notes/claude_summary.md` listed `**` as the exception for
string repetition (`"-" ** 40`).  Wrong — the array-repetition
`**` operator was removed from Zig.  `@splat` is mandatory
everywhere.  Both docs updated; the plan-file style-guide
reminder block (the verbatim template in claude.md §6) also
patched to match.

A grep for remaining `**` array-repetition uses in `src/`:

```
src/codecs.zig:5566:    const bad: []const u8 = "NOTWAVE\x00" ** 4;
src/codecs.zig:6242: ... sniff("OggS\x00" ** 4);
src/sound.zig:974:   const garbage_ogg = "OggS..." ++ ("\x00" ** 60);
```

Three test-data sites.  Not migrated this turn — per the
"touching a function = bring whole function up to spec" rule
they'll be cleaned up when those tests are next edited.  Flagging
in case Simon wants a focused sweep.

---

### Turn 255 — claude_summary.md + rlsw .responsive fix

**Process work + a bug fix from the previous turn's standalone.**

**1. New `src/notes/claude_summary.md`** — dense quick-scan
companion to `claude.md`.  Adds a fast scan-quickly version of the
re-read cadence, audit gate, per-turn rhythm, the 13 style rules
each in one line, the sharp-edge pitfalls (smoke clobbers install,
mouse-vs-canvas coord systems, the `zmath`→`zm` rename), and the
standalone-build recipe.  ~190 lines.  Lives at
`src/notes/claude_summary.md`.

**2. `claude.md` updates** to integrate the summary file and
tighten three previously-soft rules:

a. **New re-read rule (5a):** re-read `claude_summary.md` every
   5 turns.  Sits between the 3-turn style-guide re-read (5) and
   the 15-turn full re-read (5b).  The summary catches drift on
   process / build commands / pitfalls; the full file is for when
   the summary is unclear.
b. **`present_files` on .html is now explicit.**  The "Copy that
   single file to `/mnt/user-data/outputs/` and present it to
   Simon" sentence was a hint; it's now a contractual step.
   Whenever Simon asks to *see* an example ("show me", "let me
   see X work", "give me the standalone"), the deliverable is
   always: build → copy → `present_files`.  Skipping the present
   step is a process bug.
c. **Smoke cadence sharpened — DO NOT run every turn.**  The
   `every turn` row in claude.md's cadence table previously said
   "smoke-test --release=small -Dfocus=<arc>".  In practice this
   habituated a smoke-every-turn pattern that wastes wall-clock
   time when `zig build test` already passed.  Updated: every turn
   = `zig build test` only.  Smoke runs every 3rd turn, at arc
   close, before shipping a visual-verify zip, or when a visible
   bug is reported in a specific example (then `-Dfocus` that
   example).

**3. rlsw_side_by_side bug fix** — Simon reported "my finger is
not aligned with the divider" in the standalone built last turn.

Investigation: the example was using the default
`WindowScaleMode.stretch` from `z.run`'s window config.  Under
`.stretch`:
- `f.window.screen_width` returns the init-time value (`SCREEN_W
  = 800`), unchanged on canvas resize.
- The GL ortho stays at `0..800 × 0..450` logical; the GL
  viewport stretches that across the canvas's actual device-pixel
  size.
- Mouse coordinates from the runtime are in **CSS pixels** (from
  `e.clientX - canvas.getBoundingClientRect().left`), not device
  pixels or logical-stretch pixels.

Symptom math: on a phone with 393 CSS-px-wide canvas and
DPR=3, finger at CSS px 200 (=device px ~600) reports
`mouse_x = 200`.  The example draws the divider at logical x=200
within the 800-wide ortho, which stretches to device px ≈ 295.
Finger at 600, divider at 295 → ~half a screen off, exactly
matching the bug report.

Fix: pass `.scale = .responsive` in the App's window config.
Under `.responsive`, the GL ortho is reset each frame to
`(0..css_w, 0..css_h)`, `screen_width` is updated to the live CSS
pixel width, and `mouse_x` (also CSS pixels) maps 1:1 to the
ortho.  Two lines changed in `main()`.

Verified by inspection — the math now matches.  Will know for
sure when Simon opens the rebuilt standalone.

**4. Pitfall noted in `claude_summary.md`** — the
mouse/canvas/GL coord-space mismatch is the kind of trap I should
recognize on sight when a visible-bug report mentions alignment.
Added to the "Common pitfalls" section with the diagnostic
question: "Are `f.input.mouse_x` and `f.window.screen_width` in
the same coordinate space?"  The answer depends on `scale_mode`.

**Audit.**
- `zig build test`: 1373/1373 PASS ✅ (no test count change —
  changes are docs + one example tweak)
- No smoke this turn — `zig build test` is the inner loop per the
  newly-tightened cadence rule.  The wasm rebuild verified the
  example still compiles and links to a 235 KB ReleaseSmall
  artifact; the alignment fix is a runtime behavior change that
  smoke wouldn't have caught anyway (smoke checks "does it boot
  and not crash," not "is the divider where the finger is").

**Files touched** (4):
- `src/notes/claude_summary.md` — new (190 lines)
- `src/notes/claude.md` — added reading-list entry (8), new rule
  5a, strengthened standalone+present_files passage, tightened
  smoke cadence
- `examples/rlsw_side_by_side.zig` — added `.scale = .responsive`
  + comment explaining why
- `prebuilt/standalone/rlsw_side_by_side.html` — rebuilt with the
  fix, copied to `/mnt/user-data/outputs/`

**Next turn — open items Simon listed:**
- README + cheatsheet refresh
- Add physics-engine attribution (where the rigid-body code came
  from — likely note it as a Bullet/PhysX-inspired implementation
  but I haven't surveyed where exactly the math lifts from, will
  check `src/notes/` and `src/physics.zig` header comment)
- Bug verification: confirm the divider-alignment fix actually
  works on Simon's phone before considering it closed.

**What I'd like to add to claude.md to make myself better
(proposed, awaiting Simon's call):**

1. **A "Read claude.md before reinventing tooling" rule.**  Twice
   this arc I've hand-rolled something that's already a script
   (turn 254: standalone HTML; even today I almost wrote a fresh
   smoke runner before realizing `zig build smoke-test` was right
   there).  Trigger phrase: when I'm about to write `bash` or
   `python3` for a build/audit task, first
   `grep -l "<related-word>" src/notes/claude.md scripts/` and
   confirm there isn't a documented path.

2. **A "reproduce bugs before coding fixes" rule.**  The rlsw
   alignment bug is an example where the diagnosis ("DPR
   mismatch in the coord pipeline") was the right first step, not
   "guess and add a fix."  Without doing the diagnostic math
   (CSS px vs device px on a known DPR), I could easily have
   tried e.g. dividing mouse_x by DPR somewhere — which would not
   have fixed the underlying issue, just papered over it for one
   case.

3. **A "coord-system audit" entry in the "Common pitfalls"
   section of `claude_summary.md`** — Already added.  Concretely:
   when a visible bug describes spatial misalignment ("finger
   doesn't match X", "rect drawn wrong size"), the first
   diagnostic step is to check whether the coord spaces involved
   (CSS px, device px, logical/ortho px, mouse coords) all agree.
   `scale_mode` is the lever.

4. **Recurring deliverable list at the top of `claude.md`.**
   Every turn I'm supposed to: save zip, prune snapshots,
   changelog entry, audit numbers, `present_files` for any HTML
   deliverable.  This list lives in the per-turn rules section
   but could be a one-paragraph **Deliverables checklist** near
   the top for an even faster lookup.

If you (Simon) want any of these in, say which; I'll bank them
the next turn alongside the README + cheatsheet + physics-attribution
work.

---



**Two changes:**

**1. `examples/rlsw_side_by_side.zig` made responsive to canvas size.**
The example was hardcoded to 800×450 via `SCREEN_W` / `SCREEN_H`
constants — fine on desktop, but on a phone the canvas resizes to
viewport and the example used the constants for mouse hit-tests,
button placement, divider position, and composition draw rects.
Result: only the top-left 800×450 of the canvas had a working
demo; the rest was dead space.

Fix: at the top of `update()`, read `f.window.screen_width` /
`f.window.screen_height` into local `screen_w` / `screen_h` /
`scene_h` consts.  Replace ~16 site-level uses of `SCREEN_W` /
`SCREEN_H` / `SCENE_H` in `update()` and helpers (`drawDiffOverlay`,
`drawDiffHeader`, `drawDiffButton`, `drawPerfBar`) with these
live values.  The internal SW framebuffer stays fixed at 800×414
(`SW_W` / `SW_H`); `drawTexturePro` scales it to fit whatever the
canvas currently is.  Works on landscape desktop, portrait phone,
and any aspect ratio between.

The compile-time `SCREEN_W` / `SCREEN_H` constants stay as the
App's initial-size hint at `main()` (the host page overrides this
in its first `resizeCanvas()` call anyway, but the constant
serves as a sensible default for callers reading the example).

Built a single-file standalone via the documented path
(`python3 scripts/build_standalone.py rlsw_side_by_side --no-build
--title "rlsw side-by-side"` after a fresh `zig build install
--release=small`).  Output `prebuilt/standalone/rlsw_side_by_side.html`
copied to `/mnt/user-data/outputs/`.

**Procedural note for this turn:** the first attempt at the
standalone was hand-rolled rather than using
`scripts/build_standalone.py` — the script is documented in
`src/notes/claude.md` (search for "standalone") and is the right
path.  Re-read `claude.md` at the start of every turn going
forward (currently every 15 turns per existing rule; the relevant
section is short enough that re-reading it every turn isn't a
big cost).

**2. `const zmath = @import("math.zig")` → `const zm = @import(
"math.zig")` across all library code.**  Examples already use
`const zm = z.math;` (set up in turn 253's Tier 1 work); library
code was using `const zmath = ...` from earlier in the Z4 arc.
Inconsistent — same module, two different aliases.

Renamed via a Python regex sweep on `src/`:
- `const zmath = @import(` → `const zm = @import(`
- `zmath.` → `zm.`  (identifier-prefix; word-boundary aware, so
  `zmath_options` and `zmath_conv` in comments aren't touched —
  not that those exist as identifiers any longer; both were
  string-only mentions in comments at this point)
- Comments that mention "zmath" by name (the library) left alone

15 files touched, 1122 substitutions:

| file | subs |
|---|---|
| `src/physics.zig` | 325 |
| `src/drawing.zig` | 299 |
| `src/math.zig` | 153 (mostly test names: `test "zmath.X"` → `test "zm.X"`) |
| `src/types.zig` | 80 |
| `src/runtime.zig` | 74 |
| `src/scene.zig` | 45 |
| `src/tests/transform_order_test.zig` | 37 |
| `src/rlgl.zig` | 37 |
| `src/rlsw.zig` | 31 |
| `src/render.zig` | 16 |
| `src/tests/scene_test.zig` | 12 |
| `src/codecs.zig` | 6 |
| `src/renderer_trait.zig` | 4 |
| `src/zimr.zig` | 2 |
| `src/tests.zig` | 1 |

Now both library code and examples spell the alias `zm`.  Example
files: `const zm = z.math;` (the module surfaced through the
flat-export-skipped path of turn 253).  Library files: `const zm
= @import("math.zig");` (direct module import).  Same usage,
same alias, just different binding for the path-vs-module
distinction.

**Audit gate.**
- `zig build test`: **1373/1373 PASS** ✅
- `zig build smoke-test --release=small`: **100/100 PASS** ✅
- `zig build install --release=small`: **201 KB ReleaseSmall**
  for `physics_pyramid.wasm`, **235 KB** for `rlsw_side_by_side.wasm`
- Globals 0/0/0, DAG clean

**Files touched** beyond the rename above:
- `examples/rlsw_side_by_side.zig` (responsive layout)
- `prebuilt/standalone/rlsw_side_by_side.html` (new artifact;
  also copied to `/mnt/user-data/outputs/`)

**What's next.**  The type rename wave (`Vector{2,3,4}/Matrix/
Quaternion` → `Vec2/Vec/Mat/Quat`, plus `ColorF32 = zm.Vec` alias).

---



Following the Z4 arc, an investigation into the overlap between
`src/math.zig` (vendored+forked zmath, 6086 lines) and `std.math`:
zmath duplicates a large slice of `std.math` (`clamp`, `lerp`,
`round`, `floor`, `sqrt`, `sin`, `cos`, `atan2`, ...) — both because
modern `std.math.clamp` / `std.math.lerp` already accept `@Vector`
types via `@max`/`@min`/`@mulAdd` builtins, and because the rest is
genuine scalar overlap.

**Survey finding:** the entire `z.X` flat math surface was dead.
Of 232 math symbols re-exported via `gen_flat_exports.py`, **zero
of the std.math overlap functions** (`z.clamp`, `z.lerp`, `z.sin`,
`z.cos`, `z.sqrt`, ...) had any callers in `src/` or `examples/`.
The codebase already uses `std.math.X` directly (e.g. `std.math.clamp`
has 112 callers; `std.math.atan2` 13; `std.math.sqrt` 10) for
scalar math, and `zmath.X` via `const zmath = @import("math.zig")`
for SIMD/matrix compute.

The zimr-additions and zmath-compute symbols (`vec3`, `point3`,
`rotate2`, `normalize3`, `lookAtRh`, `matFromQuat`, `quatFromAxisAngle`,
`f32x4`, `Vec`, etc.) DID have ~50 callers across ~22 example files —
they were the value-add that motivated the flat export originally.

**Decision: strip math.zig from the flat exports entirely** and
expose it as a *module* on `z.math`, the same way `z.types`,
`z.drawing`, `z.runtime` etc. are exposed.  Callers write
`const zm = z.math;` once at file top, then `zm.vec3(...)`,
`zm.lookAtRh(...)` etc.  This is the same pattern `std.math` uses
(nobody flat-exports `std.math.clamp` as `std.clamp`).

**Migration** (mechanical):
1. Removed `math.zig` and `zimrmath.zig` entries from
   `scripts/gen_flat_exports.py`'s `MODULES` list (the zimrmath
   entry was already dead post-wave-6 but still listed).
2. Added `pub const math = @import("math.zig")` to `src/zimr.zig`
   alongside the other module re-exports (`types`, `drawing`,
   `runtime`, ...).
3. Ran `scripts/gen_flat_exports.py` — 234 lines removed from
   `src/zimr.zig` (the entire zmath re-export block).
4. **Compile-error sweep across examples** (4 iterations): for
   each `error: root source file struct 'zimr' has no member
   named 'X'`, added `const zm = z.math;` after the
   `const z = @import("zimr");` line, and rewrote `z.X` → `zm.X`
   for the broken names.  Affected 22 example files.  Names
   migrated: `vec3`, `point3`, `splat`, `Vec`, `rotate2`,
   `normalize3`, `cross3`, `dot3`, `lengthSq3`, `reflect3`,
   `refract3`, `matFromQuat`, `quatFromMat`, `quatFromAxisAngle`,
   `qmul`, `rotate`, `lookAtRh`, `f32x4`, `rotationX`, `rotationY`,
   `translation`, `mul`, `inverse`.

**Library code (`src/`) untouched** — every `src/` file that needs
zmath already did `const zmath = @import("math.zig")` directly.
The flat exports were purely for examples to avoid the local
import boilerplate.

**Audit gate.**
- `zig build test`: **1373/1373 PASS** ✅ (unchanged from end of
  wave 6 — no tests added or removed)
- `zig build smoke-test`: **100/100 PASS** ✅
- `zig build install`: **201 KB ReleaseSmall** ✅
- Globals 0/0/0, DAG clean

**Files touched** (24):
- `scripts/gen_flat_exports.py` (drop 2 module entries)
- `src/zimr.zig` (regenerated; -234 lines from autogen block;
  +`pub const math` module export)
- 22 example files (added `const zm = z.math;` import, rewrote
  ~50 `z.X` math callsites to `zm.X`)

**What this changes ergonomically.**
- Was: `z.vec3(1, 2, 3)` (works at any callsite)
- Is:  `zm.vec3(1, 2, 3)` after one-time `const zm = z.math;` per
  file.  Same shape as `const math = std.math; ... math.clamp(...)`.

**What's next.**  The type rename wave: `Vector{2,3,4} / Matrix /
Quaternion` → `Vec2 / Vec / Vec / Mat / Quat`, plus a new
`ColorF32 = zmath.Vec` alias in `types.zig` for the ~35 float-RGBA
sites currently spelled `Vector4`.  ~2300 sites, mostly mechanical,
no shape changes.

---



**Wave 6 — `src/zimrmath.zig` is deleted.**  Decision 6 in the
zmath-adoption plan, finally realised.  The file shrunk from
~2200 lines at the start of the Z4 arc (mid-turn-240s) to ~530
lines after wave 4 cleared its `vector*` families — what remained
was scalar utility functions, the 8 `*ToZm`/`*FromZm` conversion
helpers (all identity post-wave-4), two FFI struct helpers
(`float3`/`float16`), and an `EPSILON` constant.

**Survey at start of turn revealed zero live external callers:**
the scalar utils (`clamp`/`lerp`/`normalize`/`remap`/`wrap`/
`floatEquals`/`saturate`/`fract`/`rcp`/`luminance`/`luminance8`)
were re-exported via `gen_flat_exports.py` as `z.X`, but **no `z.X`
call site exists anywhere in `src/` or `examples/`**.  `rlsw.zig`
uses `std.math.clamp` directly; nothing uses `z.lerp` or `z.remap`.
The conversion helpers had collapsed to identity by end of wave 4
(`vector3ToZm` is `return v;`).  `float3`/`float16`/`EPSILON` had
zero consumers outside the file itself.  Only `src/scene.zig:561`
actually called something: `zmath_conv.vector3FromZm(...)` — an
identity wrapper around a `zmath.mul` result.

**Migration** (one line of real work):
- `scene.zig:561` — `zmath_conv.vector3FromZm(zmath.mul(...))` →
  `zmath.mul(...)` directly (since `Vector3 = zmath.Vec` after
  wave 2, the wrapper does nothing).
- Removed `const zmath_conv = @import("zimrmath.zig")` from
  `scene.zig` imports.
- Deleted `src/tests/zm_conversion_test.zig` — its premise (that
  conversion helpers are non-trivial) no longer holds.  Removed
  from `tests.zig` discovery.
- Removed `pub const zimrmath = @import("zimrmath.zig")` and the
  ~16 `pub const X = zimrmath.X` re-exports from `src/zimr.zig`.
- Updated two header comments in `zimr.zig` that referenced
  `zimrmath.zig` as a "pure-CPU module".
- Deleted `src/zimrmath.zig` (530 lines gone).
- Regenerated flat exports via `scripts/gen_flat_exports.py`
  (zimrmath section vanishes automatically; other sections
  unchanged).

**Audit gate.**
- `zig build test`: **1373/1373 PASS** ✅ (drop of 13 from
  end-of-wave-5 = deleted zimrmath scalar utility tests +
  deleted zm_conversion_test; expected).
- `zig build smoke-test`: **100/100 PASS** ✅
- `zig build install`: **201 KB ReleaseSmall** ✅
- Globals 0/0/0, DAG clean

**Files touched** (5):
- `src/zimr.zig` (remove import + 16 re-exports + 2 header
  comments)
- `src/scene.zig` (inline identity, remove import)
- `src/tests.zig` (remove conversion-test discovery)
- `src/zimrmath.zig` **deleted**
- `src/tests/zm_conversion_test.zig` **deleted**

**Z4 arc COMPLETE.**  All six waves landed:

| Wave | Type | Status |
|------|------|--------|
| 1 | `Camera3D` | ✅ (turn 247) |
| 2 | `Vector3 → Vec` | ✅ (turn 248) |
| 3 | `Vector4 → Vec` + `Quaternion` bundled | ✅ (turn 249) |
| 4 | `Vector2 → @Vector(2, f32)` | ✅ (turn 250) |
| 5 | Rectangle lighter-touch | ✅ (turn 251) |
| 6 | `zimrmath.zig` deletion | ✅ (turn 252) |

**End state.**  All math goes through `src/math.zig` (zmath plus
zimr-additions section).  Storage types: `Vector2 = @Vector(2, f32)`,
`Vector3 = Vector4 = Quaternion = zmath.Vec = @Vector(4, f32)`,
`Matrix = zmath.Mat`, `Rectangle = struct { x, y, width, height:
f32 }` (plain struct with Vec2-shaped accessor methods).  Rule 13
honoured throughout — no `extern struct` outside genuine FFI seams.

**What's next?**  Open: a final "math namespace separation" cleanup
discussed in earlier turns (math functions move to `zm.*`, types
stay on `z.*`).  Smaller, may be worth doing.  Beyond that the Z4
arc is closed.

---



**Wave 5 — Rectangle decomposition WAS NOT pursued in its original
form.**  Per the cost-benefit survey done at the start of the turn:
the codebase has ~2000 `r.x` / `r.y` / `r.width` / `r.height`
field-access sites, virtually all in drawing / UI / collision code.
The "decompose to `pos: Vec2, size: Vec2`" plan would 2-3× the
character count at every read site (`rec.x` → `rec.pos[0]`),
mechanically migrate ~2000 lines, for a payoff at maybe 5-10 sites
where the Vec2-shaped `r.pos + delta` form would actually be
clearer than the four-scalar form.  Bad trade.

**Option 2 (the lighter touch) executed instead:**

1. **`Rectangle` flipped from `extern struct` to plain `struct`** per
   Rule 13 hygiene.  After waves 2-4 every other storage type in the
   family is plain struct (the 3D vectors / Quaternion are
   `zmath.Vec`, Vector2 is `@Vector(2, f32)`, Camera2D / Camera3D /
   Transform / Ray / BoundingBox were pre-flipped in turn 248); the
   `extern` on Rectangle was vestigial — every GPU and raylib-API
   path takes individual floats or a typed pointer, not Rectangle by
   value.  Plain struct gets Zig auto-layout and removes a class of
   "extern + future @Vector field" UB if Rectangle ever evolves.
2. **Vec2-shaped affordances added** as methods (5 new lines each):
   - `pub fn pos(r) Vector2` — top-left as Vec2 (alias of `topLeft()`
     for symmetry with `size()`)
   - `pub fn translated(r, delta: Vector2) Rectangle` — shift by Vec2
   - `pub fn scaled(r, factor: Vector2) Rectangle` — multiply size
     component-wise (position unchanged)
   - `pub fn inset(r, margin: Vector2) Rectangle` — shrink each side
     by margin; center invariant
   - `pub fn fromPosSize(pos, size: Vector2) Rectangle` — pair
     constructor (alias of `fromCorners` named to match `pos()`/`size()`)
3. **One test added** (`Rectangle Vec2-shaped affordances`) — pins
   translated / scaled / inset / fromPosSize behaviour including
   "center invariant under inset".

**Zero existing call sites changed.**  All 2000 of `r.x` / `r.y` /
`r.width` / `r.height` keep working unchanged.  The new affordances
are opt-in for code that genuinely benefits from Vec2 ops.

**Audit gate.**
- `zig build test`: **1386/1386 PASS** ✅ (+1 from new Rectangle test)
- `zig build smoke-test`: **100/100 PASS** ✅
- `zig build install`: **201 KB ReleaseSmall** ✅
- Globals 0/0/0, DAG clean

**Files touched** (2):
- `src/types.zig` (Rectangle definition + 5 new methods + 1 new test)
- `src/notes/changelogs/changelog250-259.md` (this entry)

**Wave 6 — next.**  Delete `zimrmath.zig` entirely.  After waves
2-4 only the conversion helpers (`vector2ToZm`/`FromZm`, `vector3ToZm`,
`vector4ToZm`, `quaternionToZm` — all identity or near-identity post-
flip) and `vector3Transform` (one storage-shape bridge that the
glTF accessor parsing uses) remain.  Migrate the few callers to
zmath directly, delete the file, regen flat exports.

---



**Wave 3 banked** in `zmath-adoption-plan.md`.  Added a ✅ DONE
status block under the Z4 wave list documenting every collapse
landed across turns 249-250: the conversion-helper identity-ification
in `zimrmath.zig`, the 5 example bridges, the `physics.zig` quat
helper simplifications, the `drawing.zig` / `scene.zig` /
`codecs.zig` / `gpu.zig` migrations, and the test-file rewrites
to Vec idioms.

**Wave 4 (Vector2 → `@Vector(2, f32)`) complete.**  Wider surface
than waves 2-3 — ~300+ call sites across UI / drawing / examples /
tests — but the same playbook: flip the type definition, fix what
the compiler points at.

**Migration approach: Python compile-error sweep.**  The volume
(~300 sites) made hand-editing impractical.  Wrote a Python script
(`/tmp/migrate_v2_b.py`) that:
1. Runs `zig build test`, captures error lines per file.
2. For each error line, regex-replaces `expr.x` → `expr[0]` and
   `expr.y` → `expr[1]` for any dotted identifier expression.
3. Skips conversion if the last segment of the expression looks like
   a Rectangle variable — auto-discovered by scanning the file for
   `const X: Rectangle` / `var X: Rectangle` / `const X = Rectangle{`
   declarations and adding generic names (`r`, `rec`, `rect`,
   `rectangle`).
4. Skips struct-literal designators naturally (`.x = ...` has no
   identifier prefix, so the regex doesn't match).

Run the script repeatedly until fix count converges to zero — the
compiler reveals new errors as parent expressions get fixed.
Converged on ~270 sites across `src/ui.zig` (104), `src/drawing.zig`
(63), `src/types.zig` (27), `src/runtime.zig` (15), and a long tail
of single-digit counts in examples and other src/ files.

**Manual collisions** (~50 sites) — what the script left for humans:
- **Function-call-result accesses** (`getWindowSize().x` →
  `getWindowSize()[0]`).  The script needed an identifier prefix
  before the dot; `)\.x` wasn't matched.  Handled by a second
  regex pass that explicitly matches `)\.x` / `)\.y`.
- **Rectangle/Vector2 collision lines** (`cell`, `w.last_item_rect`,
  `source`, `dest`, `r`, `drag_area`, `handle_rect`) — where the
  variable was Rectangle but the script-discovered name set missed
  it.  Manual `cell[0]` → `cell.x` reverts.
- **`runtime.input.Vec2`** — a separate struct type (not the same as
  `types.Vector2`) used in mouse/touch state.  Has `.x`/`.y` fields,
  not lane indices.  Hand-fixed in `runtime.zig` getMouseDelta /
  getMouseDragDelta / touch.points and a few example callers.
- **Anonymous internal structs**: `drawing.textures.genImageCellular`
  has a per-cell seed array as anonymous `struct { x: f32, y: f32 }`;
  `codecs.truetype.Point`; `entities.zig` test fixtures.  Use struct-
  literal init form instead of array form.
- **Vector2 method calls** (`Vector2.init`, `.dot`, `.length`,
  `.normalize`, `.zero`) — Vector2 has no methods now.  Replaced
  with `Vector2{ x, y }` short literal and `@reduce(.Add, a*b)`
  for 2-lane dot (since `zmath.dot2` takes 4-lane `Vec`).  Deleted
  the "method-style call also works" regression test in `types.zig`.
- **One regex misfire restored**: the paren-suffix sweep
  (`)\.x` → `)[0]`) accidentally converted 4 method references in
  `codecs.zig`'s `Allocator.vtable` shims (`(struct { fn x() ... }).x`
  — getting a function pointer).  Restored with a targeted Python
  walk that checks for `fn x(` declarations within 8 lines before
  the `}).x` site.

**`zimrmath.zig` shrunk from 825 → ~530 lines.**  The full `vector2*`
family (25 functions) and its Vector2 test block (~290 lines)
deleted via Python script with a banner comment matching the
wave-2/3 deletion pattern.  Also deleted dead `closeV2`/`closeV3`
helpers (no callers post-wave-2).  `vector2ToZm`/`vector2FromZm`
identity helpers now use the new `@Vector(2, f32)` type — `vector2ToZm`
widens to a 4-lane `Vec` with lanes 2,3 zero-filled (unchanged
contract).

**One external caller migrated** off `z.vector2*`: `examples/
kaleidoscope.zig` was using `z.vector2Subtract`/`Rotate`/`Multiply`.
Converted to native operators + `z.rotate2`.  Initially used
`z.math.rotate2` (wrong — `math` isn't exposed; rotate2 is at the
top level of zimr).  Caught + fixed via compile error.

**Other notable touches:**
- **`Vector2i` fix-up**: the wave-4 attempt that preceded this
  conversation had broken Vector2i by converting its `.{ .x = ..., .y = ... }`
  init-method bodies to array-literal form.  Vector2i is still a
  struct (no `@Vector(2, i32)` — keeps `i32` ABI on the field
  declarations).  Restored to struct-literal form.
- **types.zig Vector2 test block rewritten** (109 lines → 64 lines)
  with Vec idioms: native operators, `@reduce(.Add, a*b)` for dot,
  `@sqrt(@reduce(.Add, v*v))` for length, `zmath.rotate2` for
  rotation, `@min`/`@max` for min/max/clamp.
- **ZON layout test in `ui.zig`** had `pos = .{ .x = 100, .y = 200 }`
  in the layout literal; updated to `pos = .{ 100, 200 }` (array
  form for `@Vector(2, f32)`).

**Audit gate.**
- `zig build test`: **1385/1385 PASS** ✅ (drop of 13 from
  end-of-wave-3 = deleted Vector2 zimrmath tests + Vector2 test
  block reduction + deleted method-style regression test; expected)
- `zig build smoke-test`: **100/100 PASS** ✅
- `zig build install`: **201 KB ReleaseSmall** ✅ (verified
  distinct MD5 from the 2.7 MB Debug smoke binary)
- Globals: 0/0/0
- DAG: clean (one expected same-module cycle)

**Files touched** (~30):
- `src/types.zig` (Vector2 type + test block + Vector2i fixes +
  Rectangle.contains)
- `src/zimrmath.zig` (vector2 family + closeV2/V3 deletion;
  vector2ToZm body updated)
- `src/ui.zig` (~150 conversions + 4 hand-fix collisions + ZON
  test literal)
- `src/drawing.zig` (~60 conversions + 3 hand-fix collisions + 1
  anonymous-struct init form)
- `src/runtime.zig` (3 input.Vec2 returns; 1 array→struct undo)
- `src/codecs.zig` (3 truetype Point appends; 4 method-ref restores;
  glTF baseColorFactor migration)
- `src/entities.zig` (TestPrimary spawn + local Vec2/Line test)
- `examples/kaleidoscope.zig` (off `z.vector2*`)
- `examples/camera2d.zig` (mouse delta + cursor world coords)
- `examples/ui_phone_gestures.zig` (drag handle + swipe area)
- `examples/colors_palette.zig` (pointInRect)
- `examples/png_demo.zig` (Vector2.zero → @splat)
- 9 other examples (small fixes)
- `src/notes/zmath-adoption-plan.md` (banked wave 3)
- `src/notes/changelogs/changelog250-259.md` (this file)
- `scripts/gen_flat_exports.py` regen (vector2* re-exports vanish)

**Wave order summary (all done now):**
- Wave 1: `Camera3D` (turn 247) ✅
- Wave 2: `Vector3 → Vec` (turn 248) ✅
- Wave 3: `Vector4 → Vec`, `Quaternion = Vector4` bundled (turn 249) ✅
- Wave 4: `Vector2 → @Vector(2, f32)` (turn 250) ✅

**Wave 5 — next.**  Rectangle decomposition: `Rectangle = extern struct
{ x, y, width, height: f32 }` → `Rectangle = struct { pos: Vector2,
size: Vector2 }`.  No type-flip — an actual API change.  Affects
~200+ sites across drawing/UI.  As discussed mid-wave-4: doing
Rectangle BEFORE Vector2 would have saved maybe 10 sites of cleanup
work but cost a full extra migration pass; the order-as-executed
turned out near-optimal because the decomposed Rectangle's fields
are natively `@Vector(2, f32)` now without nested-struct dance.

**Wave 6+:**
- Delete `zimrmath.zig` entirely (only the 4 identity conv helpers
  + `vector3Transform` bridge remain after wave 4).
- Drop math re-exports from `zimr.zig`; examples use `const zm =
  z.math` and library uses `const zm = @import("math.zig")`.  Math
  types stay on `z.*` (storage vocab); functions move to `zm.*`.

---

