# raylib-ui-integration.md — integrating zimr's two halves

**Status:** brainstorm + audit + recommendations.  No code yet.
**Sister docs:** `ui-design.md` (the original ImGui port plan),
`architecture.md` (three-layer overview).

---

## Why this doc exists

zimr has grown two halves: the raylib-style imperative API (`z.shapes`,
`z.text`, `z.textures`, `z.models`, etc.) and the ImGui-style
immediate-mode UI (`f.ui.window`, `f.ui.button`, etc.).  They share a
backend (rlgl + WebGL2) and most types (Color, Vector2, Rectangle), but
they were built at different times under different mental models.

This doc audits the seams and proposes ways to make the two feel like
one library, not two libraries duct-taped together.

---

## Audit: today's seams

### Seam 1 — Drawing primitives are duplicated

| `ui.zig` internal       | `drawing.zig` public          | Operation                                                |
|-------------------------|-------------------------------|----------------------------------------------------------|
| `drawRectFilled`        | `shapes.drawRectangle`        | Filled axis-aligned rect via `rlBegin(RL_TRIANGLES)`     |
| `drawRect`              | `shapes.drawRectangleLines`   | Hollow rect (4 strips)                                   |
| `drawTextAt`            | `text.draw`                   | (already bridged ✓)                                      |
| `drawTexturedQuad`      | (none direct)                 | Textured rectangle for `image` widget                    |
| `drawTriangleIndicator` | (none direct)                 | Pixelly triangle from horizontal strips                  |

Both rectangle paths emit `rlBegin/rlVertex2f/rlEnd` against the same
rlgl batch.  One is f32, one is i32.  The duplication is real.

### Seam 2 — Color types are shared but underused

Both systems use `z.types.Color`.  `Style.dark_default` ships hardcoded
byte values (`{ .r = 66, .g = 150, .b = 250, .a = 102 }`) instead of
referencing the `z.colors.*` palette.  No friction, just unrealized
potential — see Idea 7 below.

### Seam 3 — Input has two parallel paths

```zig
// Path A — direct (raylib-style)
if (z.input.isKeyPressed(z.enums.KEY_SPACE)) state.jump();

// Path B — via UI snapshot (widget interactions)
if (f.ui.button("Jump", .{})) state.jump();
```

InputSnapshot is *built from* `runtime.input` — same source, two
channels.  The user has to learn "for game logic, A; for UI, B."

**Subtle bug:** when a UI inputText captures Backspace, `z.input.isKeyPressed(KEY_BACKSPACE)`
**also** fires.  An "undo on Backspace" handler triggers while the
user types in the field.  ImGui solves this with `io.WantCaptureKeyboard`.

### Seam 4 — Camera vs UI: latent bug

```zig
z.camera.beginMode2D(state.cam);
z.shapes.drawRectangle(...);   // world space ✓
f.ui.button("Pause", .{});     // ALSO world space — bug!
z.camera.endMode2D();
```

The button inherits the camera's matrix from rlgl.  Currently nobody
hits this because demos call UI outside camera scope, but **it's a
footgun**.

### Seam 5 — Texture references aren't bridged

```zig
const tex = try z.textures.loadTexture("smiley.png");
f.ui.image(tex.id, .{ .x = @floatFromInt(tex.width), .y = @floatFromInt(tex.height) });
//          ^^^^^                         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
//          extract id                    manual size cast
```

Three pieces of friction in one call: `tex.id`, `@floatFromInt`,
manual size.  rlImGui solves this with `rlImGuiImage(const Texture* image)`.

### Seam 6 — Fonts are locked

`Style` doesn't reference a font.  `drawing.text.draw` always uses the
default 10px bitmap.  Even though we ship Roboto Mono in `assets/`,
the UI can't use it.

ImGui has `PushFont/PopFont` and per-context font atlases.  Equivalent
for us would be `Style.font: ?*Font = null` (null = default).

### Seam 7 — Frame lifecycle is implicit

Today's order in `zimr.zig::zimr_frame`:

1. `app.ui_context.beginFrame(input_snapshot)` — Ui handle stamped
2. User's `update(app, frame, state)` runs
3. `rlgl.rlDrawRenderBatchActive()` — flushes everything
4. `app.ui_context.endFrame()` — renders pending tooltips

Footguns the user can hit:
- `f.clear` AFTER UI submission → clears UI just drawn
- 3D camera active during UI → matrix state busted
- `beginScissorMode` without `endScissorMode` → UI clipped weirdly

No enforcement, no diagnostics, no documentation about ordering.

---

## Brainstorm: ideas, ranked

### Tier A — high leverage, low cost (1-turn fixes)

#### Idea 1 — Drop the duplicate rect drawing

`ui.drawRectFilled(rect, col_u32)` becomes a one-liner that calls
`shapes.drawRectangle(@intFromFloat(...))` after unpacking the color.
~30 LOC removed.  Functionally identical.  **One way to draw a rect.**

Caveat: rounding differences if widgets used sub-pixel positioning.
Audit shows we already use whole-pixel positions everywhere (FONT_SIZE
is integer; cursor positions are derived from text measurement which
is integer).  Safe.

#### Idea 2 — `image()` accepts `Texture2D` directly

```zig
pub fn image(self: Ui, tex: anytype, size: ?Vector2) void {
    const T = @TypeOf(tex);
    const tex_id: u32 = switch (T) {
        u32, c_uint => @intCast(tex),
        Texture2D, *const Texture2D => tex.id,
        else => @compileError("ui.image: pass u32 GL ID or Texture2D, got " ++ @typeName(T)),
    };
    const sz = size orelse switch (T) {
        Texture2D, *const Texture2D => Vector2{
            .x = @floatFromInt(tex.width),
            .y = @floatFromInt(tex.height),
        },
        else => Vector2{ .x = 64, .y = 64 }, // sensible fallback
    };
    imageImpl(self.ctx, tex_id, sz);
}
```

Now `f.ui.image(my_texture, null)` works with raylib's natural type
and infers size.  ~20 LOC.  **Pure win.**

#### Idea 3 — Expose `style()` on Ui

Currently mutating style requires `f.ui.ctx.style.button = ...`,
leaking the internal `ctx` field.  Add:

```zig
pub fn style(self: Ui) *Style {
    return &self.ctx.style;
}
```

Now: `f.ui.style().button = z.colors.amber_500;`.  Trivial.

#### Idea 4 — `WantCaptureKeyboard` / `WantCaptureMouse`

The standard ImGui pattern, brought over.  Two booleans on the Ui
handle, set when an input has focus / a window is hovered.  User reads
them to gate game-input handling:

```zig
if (!f.ui.wantCaptureKeyboard() and z.input.isKeyPressed(KEY_SPACE)) {
    state.jump();
}
```

```zig
pub fn wantCaptureKeyboard(self: Ui) bool {
    return self.ctx.active_id != 0 or self.ctx.input_text_focused != 0;
}
pub fn wantCaptureMouse(self: Ui) bool {
    return self.ctx.hovered_window != null or self.ctx.active_id != 0;
}
```

~15 LOC.  **Massively reduces input ambiguity** between game and UI.
The single most-felt friction in current ImGui ports without it.

### Tier B — medium leverage, medium cost (1-2 turn projects)

#### Idea 5 — UI rendering bypasses camera matrix

Cleanest fix: at the start of `Ui.beginFrame`, save the rlgl matrix
state; force ortho-screen identity.  At `endFrame`, restore.  All UI
rendering happens in screen space regardless of what the user did
with cameras.  Catches the latent bug.

```zig
pub fn beginFrame(self: *UiContext, input: InputSnapshot) Ui {
    // Snapshot whatever matrix mode the user had
    self.saved_matrix_mode = rlgl.rlGetMatrixMode();
    // Force screen-space ortho
    rlgl.rlMatrixMode(rlgl.RL_PROJECTION);
    rlgl.rlPushMatrix();
    rlgl.rlLoadIdentity();
    rlgl.rlOrtho(0, screen_w, screen_h, 0, -1, 1);
    rlgl.rlMatrixMode(rlgl.RL_MODELVIEW);
    rlgl.rlPushMatrix();
    rlgl.rlLoadIdentity();
    // ... rest as before
}
```

Cost: ~30 LOC.

Subtle: we'd want to do this *lazily* — only push the matrix on the
first widget submission, restore on Ui shutdown — to avoid penalty
when the user submits no widgets.

#### Idea 6 — Frame.input as a unified handle

Hoist `z.input.isKeyPressed` to `f.input.isKeyPressed`, etc.  Make
Frame.input the canonical input access.  The Ui's snapshot and the
user's queries draw from the same handle:

```zig
pub const Frame = struct {
    scratch: Allocator,
    loader: Loader,
    clock: Clock,
    rng: Rng,
    log: Logger,
    ui: Ui,
    input: Input,    // NEW
};

pub const Input = struct {
    pub fn isKeyPressed(self: Input, key: c_int) bool { ... }
    pub fn isMouseButtonDown(self: Input, btn: c_int) bool { ... }
    pub fn getMousePosition(self: Input) Vector2 { ... }
    // ...
};
```

Cost: ~80 LOC of method wrappers.  Backwards-compat: keep `z.input.X`
free functions working unchanged.  **Coherence win** — every effect
the user might want is on Frame.

#### Idea 7 — Style from a single accent color

```zig
pub const Style = struct {
    accent: Color = z.colors.sky_500,
    text:   Color = z.colors.slate_50,
    bg:     Color = z.colors.slate_900,
    // ... derived values:
    button: Color,
    button_hovered: Color,
    button_active: Color,
    frame_bg: Color,
    // ...

    /// Recompute derived colors from `accent`, `text`, `bg`.  Call
    /// after mutating any source color (or use `applyTailwind` for
    /// preset).
    pub fn refreshDerived(self: *Style) void {
        self.button         = self.accent.alpha(0x66);
        self.button_hovered = self.accent;
        self.button_active  = self.accent.lighten(0.1);
        self.frame_bg       = self.accent.alpha(0x80).lerp(self.bg, 0.5);
        // ...
    }

    pub fn applyTailwind(self: *Style, hue: TailwindHue) void {
        self.accent = z.colors.tailwindHue(hue, 500);
        self.refreshDerived();
    }
};
```

User can re-theme by changing one color.  Or pick a preset:
```zig
f.ui.style().applyTailwind(.amber);
```

Cost: ~80 LOC including the `Color.lighten/darken/alpha/lerp` helpers
(which are also useful outside Style).

#### Idea 8 — Style exposes `font: ?*Font`

```zig
pub const Style = struct {
    // ...
    font: ?*const Font = null, // null = default bitmap
    font_size: i32 = 10,
};
```

Every widget that emits text (`drawTextAt`) reads `ctx.style.font`
and either uses it or falls back to default.  Same with measurement.

Cost: ~50 LOC of plumbing through ~8 text-emitting call sites.

User pattern:
```zig
const roboto = try z.text.loadFont(@embedFile("RobotoMono-Regular.ttf"), 14);
defer z.text.unloadFont(roboto);
f.ui.style().font = &roboto;
f.ui.style().font_size = 14;
// All UI text now in Roboto Mono 14pt.
```

### Tier C — high leverage, high cost (long-term)

#### Idea 9 — Deferred UI rendering with a real draw list

The BIG architectural change.  Today, every widget eagerly emits
rlBegin/rlVertex/rlEnd.  Camera state, scissor state, depth test
state are inherited from whatever the user set.

Future: every widget appends to a per-frame draw list (vertex buffer
+ index buffer + draw commands with clip rect + texture per cmd).
At endFrame, the renderer plays back the draw list with **its own**
GL state (identity matrix, ortho projection, no depth, no cull,
scissor enabled).

Benefits, all from one change:

- **Camera-vs-UI bug solved** by construction
- **Z-order works** — popups, tooltips actually float on top of
  widgets submitted before them
- **Scissor/clipping per-widget** for free (clipped to window/child
  rect)
- **Custom shaders per-cmd** possible (e.g., a UI element rendered
  with a blur shader, animated transition, etc.)
- **Snapshot testing trivial** — hash the draw list, compare frames

Cost: ~500-800 LOC.  Refactor of every existing widget's render path.
~2-3 turns of focused work.

This is essentially porting `ImDrawList` proper.  Worth it eventually.
Not urgent.

#### Idea 10 — Persistent UI state through the loader

```zig
// Save layout to localStorage or wherever the user wants:
const json = try f.ui.saveLayout(f.scratch);
try z.dom.localStorage.set("zimr_ui", json);

// Load on startup:
if (z.dom.localStorage.get("zimr_ui")) |json| {
    try f.ui.loadLayout(json);
}
```

Window positions, sizes, tree open states — all persistable.  Round-
trips through `std.json`.  Schema versioned so old saves don't crash
new code.

Cost: ~150 LOC.  Comes naturally with Phase 6 polish.

#### Idea 11 — Custom shaders per UI element

Once draw lists exist (Idea 9), a UI rect can be tagged with a shader.
The renderer routes it through that program instead of the default
ortho-textured one.  Lets people make UI elements with rim lighting,
glassy blur, custom transitions.  Niche but distinctive — no other
ImGui port has this.

### Tier D — considered and rejected

#### Reject: collapse `z.shapes.drawRectangle` and `f.ui.drawRect` into a single function

Tempting, but they have different conventions:

- `shapes.drawRectangle(x: i32, y: i32, w: i32, h: i32, color: Color)` — int coords, raylib API contract
- `ui.drawRectFilled(rect: Rectangle, color_u32: u32)` — f32 Rectangle, packed color

The conventions are baked in at the surface.  Better: keep two thin
wrappers around a shared inner function (`primitives.drawRectFilled(rect, color_u32)`)
than force one signature on both audiences.

#### Reject: single namespace for everything (`f.draw.X` for both raylib and UI)

- raylib has 200+ public functions; the API surface would be enormous
- UI widgets are higher-level (have IDs, state machines, return interaction); they don't fit "draw" semantics
- The conceptual split (raylib = imperative drawing, UI = retained-but-immediate widgets) is real and useful

Better: keep namespaces separate, make them feel coherent through
shared primitives, types, input, asset abstractions, lifecycle.

#### Reject: mount the UI as a sub-app

zimr has multiapp.  The UI could conceptually be "another sub-app."
Considered and rejected: the UI needs to draw OVER everything else,
not in a sub-rect.  Different conceptual layer than a sub-app.

#### Reject: optional UI lifecycle (`Ui.enabled = false` to skip overhead)

Current overhead is essentially zero when no widgets are submitted (ID
stack stays empty, draw_lists empty, renderTooltip no-ops on null).
**Already optimal.**

---

## Recommended near-term plan

Three small focused turns, in this order:

### Turn N+1 — Drop the duplication (Tier A bundle)

- Replace `ui.drawRectFilled` / `ui.drawRect` with calls into
  `shapes.drawRectangle` / `shapes.drawRectangleLines` (Idea 1)
- Add `ui.image(anytype, ?Vector2)` overload that accepts `Texture2D`
  (Idea 2)
- Expose `Ui.style()` for direct mutation (Idea 3)
- Add `Ui.wantCaptureKeyboard()` / `wantCaptureMouse()` (Idea 4)

Total: ~100 LOC net (mostly removals + ~30 LOC of new bridges).
Single turn.

### Turn N+2 — UI is screen-space always

- Implement Idea 5: matrix push/pop in beginFrame/endFrame
- Document the contract: "UI renders in screen space; submit it
  outside any active camera mode"
- Add a debug-build assertion: if camera matrix isn't identity at
  first widget submission, log a warning

Total: ~30 LOC.

### Turn N+3 — Theme + font integration (Tier B bundle)

- Idea 8: `Style.font: ?*Font` plumbed through every text-emitting
  widget
- Idea 7: `Style.applyAccent(base_color)` regenerates derived colors
  from one base; bonus `applyTailwind` preset
- One demo example showing `f.ui.style().font = my_roboto_mono` makes
  the UI use it
- Demo a Tailwind theme switcher: `applyAccent(z.colors.amber_500)` vs
  `.sky_500` vs `.violet_500`

Total: ~150 LOC.

After those three, the foundation is tight.  Resume widget work
(combo + popups, beginChild, etc.) on top.

---

## Recommended long-term direction

When ready for a bigger lift:

**Deferred draw lists for the UI** (Idea 9).  The single change that
solves the most latent problems at once.  Worth ~3 turns of dedicated
work.  Schedule when:

- Current widget set is "good enough" (probably after combo + popups land)
- We hit a concrete ImGui feature that requires it (z-ordering counts)
- We want snapshot tests for visual regression detection

**ImGui's "custom shaders per draw command"** (Idea 11) is a sleeper
power feature.  Once we have draw lists, a UI rect can be tagged with
a shader.  Niche but distinctive — no other ImGui port has this.

---

## What this would feel like from the user's seat

```zig
// Today — raylib + UI feel like two libraries with shared types
z.camera.beginMode2D(state.cam);
z.shapes.drawCircle(100, 100, 50, z.colors.sky_400);
z.camera.endMode2D();

if (f.ui.window("Stats", .{})) |w| {
    defer w.close();
    f.ui.image(state.tex.id, .{
        .x = @floatFromInt(state.tex.width),
        .y = @floatFromInt(state.tex.height),
    });
    if (f.ui.button("Play", .{})) state.play();
}

// Both fire — bug while typing in inputText:
if (z.input.isKeyPressed(z.enums.KEY_SPACE)) state.jump();
```

```zig
// After Tier A+B — one coherent system
z.camera.beginMode2D(state.cam);
z.shapes.drawCircle(100, 100, 50, z.colors.sky_400);
z.camera.endMode2D();

if (f.ui.window("Stats", .{})) |w| {
    defer w.close();
    f.ui.image(state.tex, null);  // Texture2D, infers size
    if (f.ui.button("Play", .{})) state.play();
}

// Won't fire while UI captures keys.
if (!f.ui.wantCaptureKeyboard() and f.input.isKeyPressed(.space)) {
    state.jump();
}
```

The visible delta is small.  That's the goal — fewer footguns, less
ceremony, same idioms.  **Tightness without restructuring the user's
mental model.**

---

## Summary

| Idea | Tier | LOC | Priority |
|------|------|-----|----------|
| 1. Drop duplicate rect drawing                  | A | 30  | Next     |
| 2. `image()` accepts Texture2D                  | A | 20  | Next     |
| 3. Expose `Ui.style()`                          | A | 5   | Next     |
| 4. `WantCaptureKeyboard` / `WantCaptureMouse`   | A | 15  | Next     |
| 5. UI always screen-space                       | B | 30  | Soon     |
| 6. `Frame.input` unified handle                 | B | 80  | Soon     |
| 7. Style from single accent color               | B | 80  | Soon     |
| 8. `Style.font: ?*Font`                         | B | 50  | Soon     |
| 9. Deferred draw lists                          | C | 600 | Eventually |
| 10. Persistent UI state                         | C | 150 | Phase 6  |
| 11. Custom shaders per UI cmd                   | C | 200 | Eventually |

Tier A: pack as one turn, immediate ergonomic improvement.
Tier B: three turns, real coherence win.
Tier C: bigger lifts, schedule when foundation is otherwise solid.

---

*End of memo.  Pick a tier, implement next turn.*
