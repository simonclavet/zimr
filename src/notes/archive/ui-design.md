# ui-design.md — porting Dear ImGui to zimr

**Status:** design / planning. No code yet.
**Audience:** ourselves, in future turns when implementation begins.
**Sister docs:** `architecture.md` (the three layers), `effects-design.md`
(no-globals patterns we'll reuse), `multiapp-design.md` (sub-app
isolation we'll need for tests).

---

## Executive summary

We're porting [Dear ImGui](https://github.com/ocornut/imgui) into zimr
under the namespace `z.ui`.  Goal: every widget feels exactly like
ImGui (`if (ui.button("OK"))` returns true on click, `Begin/End`
windows that auto-resize and remember position, the ID stack, in-place
data mutation via pointer parameters), but the architecture follows
zimr's principles: no globals, explicit allocators, errors propagated.

**Delivery:** ~6-8 turns of work, ~5-7K LOC of Zig including inline
tests.  Smaller than the C++ original (67K LOC) because we drop
tables, docking, multi-viewport, and unify ImGui's overload zoo into a
handful of `anytype` generics.

**End state:** `examples/imgui_demo.zig` reproduces the canonical
ImGui demo window with ~25 widgets, plus a Zig-only superpower —
`ui.editStruct(*T)` that auto-generates a UI from any struct's fields.

---

## References

We have four reference points, each used differently:

| Source       | Role                                                              | Lines |
|--------------|-------------------------------------------------------------------|-------|
| **dear imgui** (`imgui.cpp` etc.) | Source-of-truth for behavior + look + feel | 67K   |
| **cimgui**   | The C ABI shape — useful for translating C++ into flat Zig fns    | 12K   |
| **rlImGui**  | Reference renderer using rlgl — *exactly* our backend             | 935   |
| **imgui-js** | Existence proof: ImGui works in WebGL via Emscripten              | n/a   |

**rlImGui is the most valuable.**  Its `ImGui_ImplRaylib_RenderDrawData`
is 30 lines that walk command lists, set scissor, emit triangles via
`rlBegin(RL_TRIANGLES)`/`rlVertex2f`/`rlSetTexture`/`rlEnd`.  This
maps 1:1 onto zimr's existing rlgl wrappers.  We are NOT porting the
70K-line C++ codebase — we're porting the API and re-implementing the
internals in idiomatic Zig.

**imgui-js shows us a workaround we don't need.**  Without C++ pointer
parameters, JS uses an access-function trick: `(_ = show) => show = _`
to mimic `&show`.  Zig has `*T` natively — `ui.checkbox("show", &show)`
just works.  We get the C++ ergonomic without the C++ memory unsafety.

---

## The soul of ImGui

Five things make ImGui feel like ImGui.  All five must survive the
port or it's not ImGui anymore.

1. **One call per widget; returns the interaction.**
   `if (ui.button("OK")) { ... }` — runs once when pressed this frame.
   No callbacks, no event listeners, no state machine.
2. **State held by the library, addressed by string.**
   `ui.begin("Stats")` finds-or-creates the persistent window state by
   hashing the title.  Position, size, scroll, collapsed-ness — all
   library-owned, retrieved by ID, never declared by the caller.
3. **The ID stack disambiguates duplicates.**
   Two `ui.button("apply")` calls in different windows MUST have
   different identities.  The library hashes (parent_id ++ label)
   recursively up the stack, producing a stable u32 per call site.
   `pushId(i)` lets you disambiguate a loop.
4. **Layout is an implicit cursor.**
   Widgets advance a `cursor_pos` inside the current window.
   `sameLine()` keeps the next widget on the row.  No flexbox, no
   constraint solver — just rectangles laid out left-to-right,
   top-to-bottom, by the cursor.
5. **The user mutates their own data in place.**
   `ui.checkbox("foo", &my_bool)` reads and writes the user's bool.
   No event-translation step, no observer pattern.

If we sacrifice any of these for "purity" we've lost the plot.

---

## The central tension: globals vs feel

ImGui's API ergonomics depend on a global `ImGuiContext`.  Every call
(`Button`, `Text`, `SliderFloat`) reaches into it via
`GetCurrentContext()`.  Removing this without verbosifying every call
is the central design problem.

### Three options considered

```zig
// (A) Explicit context every call. Verbose, kills the feel.
ui.button(ctx, "OK");
ui.text(ctx, "FPS: {d}", .{fps});

// (B) Method calls on a Ui handle, Frame field.  Best.
if (f.ui.button("OK")) state.counter += 1;
f.ui.text("FPS: {d}", .{f.clock.fps()});

// (C) Local alias — same as B, slightly cleaner reading.
const ui = f.ui;
if (ui.button("OK")) state.counter += 1;
ui.text("FPS: {d}", .{f.clock.fps()});
```

### Decision: B/C

The `Ui` is a 16-byte handle sitting at `Frame.ui`, exactly mirroring
how `f.clock.fps()` and `f.rng.float()` work today.  The
`Context` itself lives in App (long-lived, App.gpa-backed).  The
handle is stamped fresh each frame in `beginFrame()`.

**This isn't a workaround — it's the same orthogonality principle as
`Frame` itself.**  Frame holds 5 effects (clock, rng, log, loader,
scratch).  Ui becomes the 6th.

```zig
// Conceptual layout
pub const Ui = struct {
    ctx: *UiContext,  // pointer into App.ui_context
};

pub const UiContext = struct {
    // ALL the global state from ImGuiContext lives here:
    gpa: std.mem.Allocator,
    frame_arena: *std.heap.ArenaAllocator,  // resets each frame, scratch use
    
    // Window store — string ID → persistent state
    windows: std.AutoHashMapUnmanaged(u32, *Window),
    
    // Per-frame transient
    current_window: ?*Window,
    cursor_pos: Vec2,
    id_stack: std.BoundedArray(u32, 32),
    style_color_stack: std.ArrayListUnmanaged(StyleColorEntry),
    style_var_stack: std.ArrayListUnmanaged(StyleVarEntry),
    
    // Active item / hover tracking
    active_id: u32 = 0,
    hovered_id: u32 = 0,
    active_id_was_just_activated: bool = false,
    
    // Input state (mirror of Frame.input but ImGui-formatted)
    mouse_pos: Vec2,
    mouse_down: [3]bool,
    mouse_clicked: [3]bool,
    
    // Style + theme
    style: Style,
    
    // Font atlas (shared with text.zig — same baked atlas)
    font: *const text.Font,
    
    // Draw command buffer for this frame
    draw_cmds: std.ArrayListUnmanaged(DrawCmd),
    
    // ... approx 40-60 fields total
};
```

### Why this works in practice

- **App owns the Context** — exists for the whole program lifetime,
  textures and fonts persist across frames.
- **Frame.ui is stamped fresh** in `core.beginFrame()`.  Cheap: 8
  bytes copied.  All real state lives in `*UiContext`.
- **The handle is callable** — `f.ui.button(...)` works because
  `Ui.button` is a method that dereferences `self.ctx`.
- **From the call site, identical to ImGui.**  Every call is one
  line, one underscore-free name, no setup.

---

## API shape

The driving constraint: a zimr ImGui example should be readable
side-by-side with a C++ ImGui example, and equally short.

### Hello world

```zig
fn update(_: *z.App, f: *z.Frame, state: *State) void {
    f.clear(z.colors.slate_950);
    
    // Begin/End matched pair — same as ImGui.
    if (f.ui.begin("Hello, world!", .{})) {
        defer f.ui.end();
        
        f.ui.text("This is some useful text.", .{});
        _ = f.ui.checkbox("Demo Window", &state.show_demo);
        _ = f.ui.checkbox("Another Window", &state.show_another);
        _ = f.ui.slider("float", &state.f, .{ .min = 0.0, .max = 1.0 });
        _ = f.ui.colorEdit("clear color", &state.clear_color, .{});
        
        if (f.ui.button("Button", .{})) state.counter += 1;
        f.ui.sameLine(.{});
        f.ui.text("counter = {d}", .{state.counter});
    }
}
```

Compare to the C++ original (~12 lines for the body).  Lines are
within 1-2 of each other.  Idioms read identically.

### Key API differences from ImGui (Zig idioms)

1. **`begin` returns `bool`, paired with `defer end()`.**  Caller
   patterns:
   ```zig
   if (ui.begin("Stats", .{})) {
       defer ui.end();
       // ...
   }
   ```
   This is closer to ImGui's `if (Begin(...)) { ... End(); }` than the
   defer approach but with Zig's defer doing the cleanup safely even
   on `return`.
2. **Options structs replace overload zoo.**  `ui.button(label, .{})`
   accepts an optional struct: `.{ .size = .{ .x = 100, .y = 30 } }`.
   ImGui has 4-5 overloads of `Button` — we have one.
3. **`anytype` for sliders/drags/inputs.**  `ui.slider(label, value,
   opts)` works with `*f32`, `*i32`, `*[3]f32`, `*Vec3`, etc.
4. **Comptime-formatted text.**  `ui.text("FPS: {d:.1}", .{fps})`
   uses `std.fmt`.  Type-safe at the call site.
5. **`*T` for in-place mutation.**  No JS-style getter/setter
   closures.  Pure Zig idiom.

### The Zig-only superpower: `editStruct`

```zig
// User defines a struct.
const Settings = struct {
    volume: f32 = 0.5,
    enable_music: bool = true,
    quality: enum { low, medium, high } = .medium,
    name: [32]u8 = undefined,
    color: [3]f32 = .{ 1, 1, 1 },
};

// One line generates a complete editor UI.
ui.editStruct(&state.settings);
```

The implementation walks `@typeInfo(T).Struct.fields` at comptime and
dispatches each field type to the appropriate widget:

| Zig type            | Widget           |
|---------------------|------------------|
| `bool`              | checkbox         |
| `f32` / `f64`       | slider or drag   |
| `i8..i64`/`u8..u64` | slider or drag   |
| `[N]f32`            | sliderN          |
| `[N]u8`             | inputText        |
| `enum`              | combo            |
| `struct`            | tree node + recurse |
| `?T`                | checkbox + nested|
| `[]T` / `ArrayList` | list editor      |

ImGui can't do this — no reflection.  This is our flagship
demonstration that Zig + ImGui-style is a strict superset.

---

## Internal architecture

### Module layout

We add **two files** to `src/`:

```
src/ui.zig           # ~3000-5000 LOC including inline tests
src/ui/
  rlgl_renderer.zig  # ~400 LOC — the rlgl backend, isolated
```

Or possibly a single `src/ui.zig` if we keep the renderer inline (it's
small enough that namespacing it as a section header is fine).
**Decision deferred to Phase 1.**

`zimr.zig` gets one new line: `pub const ui = @import("ui.zig");`

`Frame` (in `runtime.zig`) gets one new field: `ui: Ui`.

### Core data structures

#### `UiContext`

The "global" of ImGui, made explicit.  Lives in App for the program's
lifetime.  All persistent state.  Approximately:

```zig
pub const UiContext = struct {
    // Allocators
    gpa: std.mem.Allocator,         // long-lived data (window store, fonts)
    frame_arena: ArenaAllocator,    // resets each frame, scratch
    
    // Persistent window store
    windows: std.AutoHashMapUnmanaged(u32, *Window),
    
    // Per-frame transient state (cleared in beginFrame)
    current_window: ?*Window = null,
    window_stack: std.BoundedArray(*Window, 16) = .{},
    id_stack: std.BoundedArray(u32, 32) = .{},
    
    // Active item / hover
    active_id: u32 = 0,
    active_id_window: ?*Window = null,
    active_id_just_activated: bool = false,
    hovered_id: u32 = 0,
    hovered_id_prev_frame: u32 = 0,
    hovered_window: ?*Window = null,
    
    // Style stacks (push/pop)
    style_color_stack: std.ArrayListUnmanaged(StyleColorEntry) = .empty,
    style_var_stack: std.ArrayListUnmanaged(StyleVarEntry) = .empty,
    
    // Style values (live; mutated by push/pop)
    style: Style = .dark_default,
    
    // Input mirror (translated from Frame.input each frame)
    input: InputSnapshot = .{},
    
    // Font + atlas
    font: *const Font,  // baked once at startup
    
    // Draw output
    draw_lists: std.ArrayListUnmanaged(DrawList) = .empty,
    
    // Frame-counter / timing
    frame_count: u64 = 0,
    delta_time: f32 = 0,
    
    // Open popups (a tiny stack)
    open_popups: std.BoundedArray(PopupRef, 8) = .{},
    
    // Drag-and-drop payload (Phase 5+)
    // dnd_payload: ?DragDropPayload = null,
};
```

#### `Window` (persistent, one per `Begin` ID)

```zig
pub const Window = struct {
    id: u32,                    // hashed title
    name: []u8,                 // owned, gpa-allocated
    pos: Vec2,
    size: Vec2,
    content_size: Vec2,         // computed each frame from cursor_max - pos
    scroll: Vec2,
    collapsed: bool = false,
    flags: WindowFlags = .{},
    
    // Per-frame appended-to state
    cursor_pos: Vec2,           // current widget anchor
    cursor_max: Vec2,           // bottom-right of last widget — for content size
    line_height: f32,           // current line's max widget height
    same_line_pending: bool = false,
    
    // Item tracking for IsItemHovered et al.
    last_item_id: u32 = 0,
    last_item_rect: Rect = .{},
    last_item_active: bool = false,
    last_item_hovered: bool = false,
    
    // Draw list — written by widgets, consumed at endFrame
    draw_list: DrawList,
    
    // Z order (focus / window stacking)
    appearing: bool = true,     // first frame of life
    last_frame_active: u64 = 0, // GC: drop windows not seen in N frames
};
```

#### `Style`

Plain struct with reasonable defaults (the imgui dark theme).
Mutated by `pushStyleColor`/`popStyleColor`/`pushStyleVar`/etc.  Or
directly by the user before `beginFrame`.

```zig
pub const Style = struct {
    // Colors (40+ named slots in ImGui)
    text: Color,
    text_disabled: Color,
    window_bg: Color,
    child_bg: Color,
    popup_bg: Color,
    border: Color,
    button: Color,
    button_hovered: Color,
    button_active: Color,
    frame_bg: Color,
    // ... etc, ~40 entries
    
    // Sizes
    window_padding: Vec2 = .{ .x = 8, .y = 8 },
    frame_padding: Vec2 = .{ .x = 4, .y = 3 },
    item_spacing: Vec2 = .{ .x = 8, .y = 4 },
    indent_spacing: f32 = 21,
    scrollbar_size: f32 = 14,
    grab_min_size: f32 = 12,
    
    // Rounding
    window_rounding: f32 = 0,
    frame_rounding: f32 = 0,
    grab_rounding: f32 = 0,
    
    pub const dark_default: Style = .{ /* values from ImGui::StyleColorsDark */ };
    pub const light_default: Style = .{ /* values from ImGui::StyleColorsLight */ };
};
```

#### `DrawList`

A queue of textured triangles + clip rects.  Append-only during the
frame; consumed by the renderer.

```zig
pub const DrawList = struct {
    cmds: std.ArrayListUnmanaged(DrawCmd) = .empty,
    
    // Per-vertex data
    vertices: std.ArrayListUnmanaged(DrawVert) = .empty,
    indices: std.ArrayListUnmanaged(u16) = .empty,
    
    // Currently active clip rect
    clip_stack: std.BoundedArray(Rect, 8) = .{},
    
    // Currently active texture (font atlas, white pixel, user texture)
    texture_stack: std.BoundedArray(u32, 4) = .{},
    
    // Path builder for stroked/filled polylines (lines, bezier curves)
    path: std.ArrayListUnmanaged(Vec2) = .empty,
};

pub const DrawCmd = struct {
    clip_rect: Rect,
    texture_id: u32,
    vtx_offset: u32,
    idx_offset: u32,
    elem_count: u32,
};

pub const DrawVert = extern struct {
    pos: Vec2,
    uv: Vec2,
    col: u32,  // packed RGBA
};
```

Note: this MIRRORS the C++ `ImDrawList` exactly.  We keep the same
shape because the rlgl renderer (next section) wants exactly this
input.  No compelling reason to invent our own layout.

### The renderer

This is the smallest, simplest, most well-defined piece.  Direct port
of rlImGui's render loop.

```zig
fn render(ctx: *UiContext) void {
    // Walk merged draw list across all windows in z-order.
    const merged = ctx.flushDrawLists();
    defer ctx.frame_arena.allocator().free(merged.cmds);
    
    // We're a 2D overlay — disable depth test, disable cull face.
    rl.fwd.rlDisableBackfaceCulling();
    rl.fwd.rlDisableDepthTest();
    
    for (merged.cmds) |cmd| {
        // Set scissor for this command's clip rect
        rl.fwd.rlEnableScissorTest();
        rl.fwd.rlScissor(
            @intFromFloat(cmd.clip_rect.x),
            @intFromFloat(cmd.clip_rect.y),
            @intFromFloat(cmd.clip_rect.w),
            @intFromFloat(cmd.clip_rect.h),
        );
        
        // Bind texture (font atlas or user texture)
        rl.fwd.rlSetTexture(cmd.texture_id);
        
        // Emit triangles via rlBegin/rlVertex2f
        rl.fwd.rlBegin(rl.RL_TRIANGLES);
        var i: usize = 0;
        while (i < cmd.elem_count) : (i += 3) {
            inline for (0..3) |k| {
                const idx = merged.indices[cmd.idx_offset + i + k];
                const v = merged.vertices[cmd.vtx_offset + idx];
                rl.fwd.rlColor4ub(
                    @intCast((v.col >>  0) & 0xFF),
                    @intCast((v.col >>  8) & 0xFF),
                    @intCast((v.col >> 16) & 0xFF),
                    @intCast((v.col >> 24) & 0xFF),
                );
                rl.fwd.rlTexCoord2f(v.uv.x, v.uv.y);
                rl.fwd.rlVertex2f(v.pos.x, v.pos.y);
            }
        }
        rl.fwd.rlEnd();
        rl.fwd.rlDrawRenderBatchActive();  // flush
    }
    
    // Restore state
    rl.fwd.rlDisableScissorTest();
    rl.fwd.rlEnableDepthTest();
    rl.fwd.rlEnableBackfaceCulling();
    rl.fwd.rlSetTexture(0);
}
```

This is **~50 lines including comments**.  rlImGui's version (which
this is a direct port of) is ~30 lines of C++.

### Font atlas

We already have everything:
- `codecs.truetype` (Andrew Kelley's stb_truetype port) ✓
- `codecs.rectpack` (rect packing) ✓
- `text.bakeFontAtlas` (already builds an atlas for `drawTextEx`) ✓

**We reuse the same atlas.**  The atlas built by zimr text rendering
(used in `text_layout.zig` example) is also the atlas used by
ImGui-style widgets.  One bake at `App` startup; same `Texture2D`
referenced everywhere.

The character set is bigger than ImGui's default (we already include
Latin-1 + box-drawing for borders).  Glyph atlas is ~512×512 RGBA8 or
similar — small.

The white pixel for solid rectangle fill: reserve one texel in the
atlas (top-left corner), record its UV, and every rect uses
`{ uv = white_uv, col = some_color }`.  Same trick ImGui uses.

---

## Phase plan

Each phase = one focused turn.  Each ends with green tests + a
demoable example.

### Phase 1 — Foundation (1-2 turns, ~1500 LOC)

**Goal:** build a button.  When this turn's example shows two windows
with their own clickable button, the architecture is proven.

**Deliverables:**

1. `src/ui.zig` — new file with:
   - `UiContext`, `Ui`, `Window`, `DrawList`, `DrawCmd`, `DrawVert`,
     `Style`, `Vec2`, `Rect`, `Color` (or alias to existing types)
   - `pub fn beginFrame(ctx: *UiContext, frame: *Frame) Ui`
   - `pub fn endFrame(ctx: *UiContext) void`
   - `pub fn render(ctx: *UiContext) void` (rlgl-based)
   - ID stack: `hashId(seed: u32, str: []const u8) u32` (FNV-1a),
     `pushId`, `popId`, `getId`
   - Layout cursor: `advanceCursor`, `sameLine`, `newLine`, `dummy`
   - Hit-test: `itemHoverable(rect: Rect, id: u32) bool`
   - Active item: `setActiveId`, `clearActiveId`
   - Draw primitives: `drawRectFilled`, `drawRect`, `drawText`,
     `drawTriangleStripFilled`
   - **One** widget: `pub fn button(self: Ui, label: []const u8, opts: ButtonOpts) bool`
   - Default dark theme as `Style.dark_default`

2. `runtime.zig` — `Frame.ui: Ui` field + initialization in
   `beginFrame`.

3. `zimr.zig` — `pub const ui = @import("ui.zig");`

4. `src/tests/ui_test.zig` — tests for ID hashing, layout cursor,
   hit-test rect math.  (Or inline tests next to the functions if
   that's the new convention.)

5. `examples/imgui_phase1.zig` — two windows side by side, each with
   a button + a counter text.  Click button A → its counter
   increments.  Click button B → only B's counter increments.
   Proves ID stack works.

**Acceptance criteria:**
- 487/487 + N new tests pass on host.
- `zig build smoke-test` runs the new example, GL call count > 1000
  (real geometry being rendered).
- Browser load: visual check — two windows render, buttons highlight
  on hover, click registered.

### Phase 2 — The seven essentials (1 turn, ~1500 LOC)

**Goal:** can replicate the canonical "Hello, world!" demo.

Widgets to implement:
- `text(fmt, args)` — formatted via `std.fmt.bufPrint`
- `textColored(color, fmt, args)`
- `textWrapped(fmt, args)`
- `button(label, opts)` (already done in Phase 1; refine)
- `checkbox(label, *bool)`
- `slider(label, *T, opts)` — anytype (covers float, int, vec2/3/4)
- `colorEdit(label, *T, opts)` — anytype (covers `[3]f32`, `[4]f32`,
  `Color`)
- `sameLine(opts)`
- `separator()`
- `spacing()`
- `newLine()`

**Sub-deliverables:**
- Style push/pop machinery (`pushStyleColor`, `popStyleColor`)
- Tooltip via `if (isItemHovered()) ui.beginTooltip(); ...
  ui.endTooltip();`
- `examples/imgui_demo.zig` — reproduces the canonical Hello World

### Phase 3 — The next ten (1-2 turns, ~2000 LOC)

- `inputText(label, buf, opts)` — text entry, **single line first**
- `drag(label, *T, opts)` — drag-to-edit numbers
- `combo(label, *T, items)` — `T` is enum or int
- `treeNode(label)` / `treePop()`
- `collapsingHeader(label)`
- `radioButton(label, *T, value)`
- `selectable(label, *bool, opts)`
- `tooltip(fmt, args)` — wraps `if (isItemHovered())`
- `bullet()`, `bulletText(fmt, args)`
- `image(texture, size, opts)`

### Phase 4 — Containers (1-2 turns, ~1500 LOC)

- `beginChild` / `endChild` (scrollable sub-region)
- Window resize / drag-to-move handles
- `beginPopup` / `endPopup`
- `beginPopupContextItem` (right-click menus)
- `beginMainMenuBar` / `beginMenu` / `menuItem`
- `beginTabBar` / `beginTabItem`

### Phase 5 — Zig superpowers (1 turn, ~600 LOC)

- `editStruct(*T)` — comptime field walker
- `editEnum(*T)` for any enum
- `editArrayList(*ArrayList(T))` — add/remove items
- Snapshot test infrastructure (record GL call sequence, compare)

### Phase 6 — Polish (1 turn, ~400 LOC)

- Style editor window (uses `editStruct(&style)` — meta!)
- Layout persistence: `saveLayout(*UiContext, writer)` /
  `loadLayout(*UiContext, reader)` using std.json
- Keyboard navigation between widgets
- Larger demo: image editor or property inspector

---

## MVP widget catalog

If I had to ship one weekend's worth of widgets and stop, here's the
ranking by "value per LOC".

| Tier | Widget        | LOC est | Why                                          |
|------|---------------|---------|----------------------------------------------|
| 1    | `button`      | 80      | Core interaction. Without it, no UI.         |
| 1    | `text`        | 50      | Used everywhere.                             |
| 1    | `begin/end`   | 300     | Window framing. Drag, resize, collapse.      |
| 1    | `checkbox`    | 60      | Most common state edit.                      |
| 1    | `slider`      | 200     | Anytype. Covers float, int, vec.             |
| 1    | `sameLine`    | 20      | Layout primitive. Composes everything.       |
| 1    | `colorEdit`   | 150     | Universally useful, signature ImGui widget.  |
| 2    | `inputText`   | 400     | Text entry + cursor + selection. Big.        |
| 2    | `combo`       | 150     | Dropdown.                                    |
| 2    | `treeNode`    | 100     | Hierarchical UI.                             |
| 2    | `radioButton` | 60      | Mutually exclusive selection.                |
| 2    | `selectable`  | 80      | List items.                                  |
| 2    | `tooltip`     | 50      | Documentation in-place.                      |
| 2    | `drag`        | 200     | Like slider but unbounded.                   |
| 3    | `beginChild`  | 200     | Scroll regions.                              |
| 3    | `beginPopup`  | 250     | Modals + menus.                              |
| 3    | `menuBar`     | 200     | Top-of-window menus.                         |
| 3    | `tabBar`      | 250     | Tabbed interfaces.                           |
| 3    | `image`       | 80      | Texture display.                             |
| 4    | `editStruct`  | 400     | The Zig superpower.                          |
| 4    | `dragDrop`    | 500     | Move things around. Complex, often-skipped.  |
| 5    | `tables`      | 5000    | Out of MVP scope.                            |
| 5    | `docking`     | 10000   | Out of MVP scope.                            |

Tier 1+2 is everything 80% of users want.  ~1500 LOC of widget code
plus shared infrastructure.

---

## Clever ideas, expanded

### 1. Anytype generics collapse the overload zoo

ImGui has, *for sliders alone*:
- `SliderFloat`, `SliderFloat2`, `SliderFloat3`, `SliderFloat4`
- `SliderAngle`
- `SliderInt`, `SliderInt2`, `SliderInt3`, `SliderInt4`
- `SliderScalar` (with type tag), `SliderScalarN`
- `VSliderFloat`, `VSliderInt`, `VSliderScalar`

That's **13 functions**.  In Zig:

```zig
pub fn slider(self: Ui, label: []const u8, value: anytype, opts: SliderOpts) bool {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    
    return switch (info) {
        .Pointer => |p| switch (@typeInfo(p.child)) {
            .Float, .Int => sliderScalar(self, label, value, opts),
            .Array => sliderArray(self, label, value, opts),
            .Struct => sliderVec(self, label, value, opts),
            else => @compileError("slider: unsupported value type"),
        },
        else => @compileError("slider: pass a pointer (e.g., &my_value)"),
    };
}
```

One function.  `*f32`, `*i32`, `*[3]f32`, `*Vec3` — all dispatched at
comptime.  Zero runtime cost over hand-written variants.

Same trick collapses:
- `DragFloat*`/`DragInt*` → `drag`
- `InputFloat*`/`InputInt*` → `inputNumber`
- `ColorEdit3`/`ColorEdit4`/`ColorPicker3`/`ColorPicker4` → `colorEdit`

**Net: ~30 ImGui functions become ~5 Zig functions.**  Less code,
more compile-time type safety.

### 2. `editStruct(*T)` — flagship feature

```zig
pub fn editStruct(self: Ui, ptr: anytype) void {
    const T = @TypeOf(ptr.*);
    const info = @typeInfo(T);
    if (info != .Struct) @compileError("editStruct: expected struct pointer");
    
    inline for (info.Struct.fields) |field| {
        const field_ptr = &@field(ptr.*, field.name);
        editField(self, field.name, field_ptr);
    }
}

fn editField(self: Ui, name: []const u8, ptr: anytype) void {
    const T = @TypeOf(ptr.*);
    switch (@typeInfo(T)) {
        .Bool => _ = self.checkbox(name, ptr),
        .Float => _ = self.slider(name, ptr, .{ .min = 0, .max = 1 }),
        .Int => _ = self.slider(name, ptr, .{}),
        .Enum => _ = self.combo(name, ptr),
        .Struct => if (self.treeNode(name)) {
            defer self.treePop();
            self.editStruct(ptr);
        },
        .Array => |a| {
            if (a.child == u8) {
                _ = self.inputText(name, ptr, .{});
            } else if (a.len <= 4 and @typeInfo(a.child) == .Float) {
                _ = self.slider(name, ptr, .{});
            }
        },
        // ... etc
    }
}
```

**Demo idea:** `examples/struct_editor.zig` — define a `GameSettings`
struct with 20 fields, call `ui.editStruct(&settings)`, show the
generated UI.  This will make people who've used ImGui in C++ go
"oh."

### 3. Snapshot tests for free

Smoke test infra already runs each example for 3 frames in fakeGL
Proxy.  For ImGui-driven UI, add a hash:

```zig
// Inside a smoke harness assertion
const ui_hash = ui.snapshotHash();  // hashes draw cmd sequence
try std.testing.expectEqual(0xDEADBEEFEXPECTED, ui_hash);
```

Pixel-perfect regression detection.  If we change the slider
implementation and accidentally shift it 1px right, every snapshot
breaks loudly.

### 4. Window-as-defer-block via optional handle

Since the user explicitly said `if (ui.begin(...)) { ui.end(); }`
isn't great, an alternative shape:

```zig
if (ui.window("Stats", .{})) |w| {
    defer w.close();
    ui.text("FPS: {d}", .{fps});
    if (ui.button("Reset", .{})) state.reset();
}
```

Where `w` is a tiny opaque handle (`Window.Handle`, value type).
Cleanup can't be forgotten — dropping the handle without `.close()`
is a compile error if we use a custom drop function.  Or just rely on
defer.

**Decision:** start with the ImGui-style `if (ui.begin(...)) { defer
ui.end(); }` — closer to the original, easier port.  Re-evaluate
shape after Phase 1 has it working.

### 5. Style as data, not commands

In ImGui:
```cpp
ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(8, 4));
ImGui::Button("OK");
ImGui::PopStyleVar();
```

In zimr (option A — same shape):
```zig
ui.pushStyleVar(.frame_padding, .{ .vec2 = .{ 8, 4 } });
defer ui.popStyleVar();
_ = ui.button("OK", .{});
```

But also (option B — per-widget):
```zig
_ = ui.button("OK", .{ .padding = .{ 8, 4 } });
```

**Decision:** support both.  Option B for the common case (passes
through to the widget's `opts` struct).  Option A for blocks of many
widgets sharing styling.  Best of both worlds.

### 6. Scope-bound style changes via builder pattern

```zig
{
    var s = ui.styleScope();
    s.color(.button, .red);
    s.var(.frame_padding, .{ 4, 2 });
    defer s.end();
    
    _ = ui.button("Delete", .{});
    _ = ui.button("Cancel", .{});
}
```

Builder pattern with deferred cleanup.  Multiple style changes, one
end call.

### 7. Tests inline alongside widget impls

When we colocate tests next turn anyway:

```zig
pub fn button(self: Ui, label: []const u8, opts: ButtonOpts) bool {
    // ... impl ...
}

test "button: returns true on click frame" {
    var harness = try TestHarness.init(std.testing.allocator);
    defer harness.deinit();
    
    harness.simulateClick(.{ .x = 100, .y = 100 });
    harness.beginFrame();
    
    // Position the button under the cursor
    harness.ui.setCursorPos(.{ .x = 90, .y = 95 });
    const pressed = harness.ui.button("OK", .{});
    
    try std.testing.expect(pressed);
}

test "button: not pressed on hover only" { ... }
test "button: ID disambiguation across windows" { ... }
```

ImGui's TestEngine is its own ~5K LOC system.  We get equivalent
coverage with `std.testing` + a small `TestHarness` that fakes
input + skips the real renderer.

---

## Open questions for the user

These are decisions we should make before coding starts.

### 1. Naming convention — DECIDED: camelCase

`ui.button`, `ui.sliderFloat`, etc. Matches zimr convention.

### 2. Begin/End shape — DECIDED: optional handle (option B)

```zig
if (ui.window("Stats", .{})) |w| {
    defer w.close();
    ui.text("FPS: {d}", .{fps});
}
```

The `ui.window(...)` returns `?WindowHandle`. `null` means the window
is collapsed or closed — caller's block doesn't execute. Defer pairs
cleanly with `w.close()`.

### 3. Style: imperative push/pop or declarative options struct?

DECIDED: **Both, but keep it ImGui-style for now.**  Per-widget
options structs (`.{ .min = 0, .max = 1 }`) are the primary
mechanism; push/pop style scopes come later.

### 4. Single file or split? — DECIDED: single file

`src/ui.zig` — keep it all together, sectioned with header comments.
Consistent with the recent consolidation pass.

### 5. Theme — DECIDED: dark default

ImGui's StyleColorsDark, hardcoded as `Style.dark_default`.  Light
theme post-MVP.

### 6. Demo coverage — DECIDED: mid-fidelity (40 widgets in one window)

Not the full `imgui_demo.cpp` port (that's 10K LOC of demo code),
just the canonical "what does ImGui look like" feature tour.

### 7. `editStruct` — DECIDED: post-MVP

The Zig superpower idea is great, but we want the normal ImGui flow
first.  Slider bounds via `.{ .min = 0, .max = 1 }`, tooltips via
`if (ui.isItemHovered()) ui.setTooltip(...)`, etc.  `editStruct`
arrives as a Phase 5+ enhancement once the regular path is solid.

---

## Risks

### 1. Text rendering fidelity

ImGui's text rendering uses sub-pixel positioning and alpha-coverage
glyphs.  Zimr's `drawText` does whole-pixel positioning currently.
If our text looks blocky at small sizes, the whole UI looks
amateurish.

**Mitigation:** Phase 1 tests text rendering quality side-by-side
with C++ ImGui.  If unacceptable, we upgrade `text.bakeFontAtlas` to
do sub-pixel.  ~200 LOC change to truetype output.

### 2. Hit-testing depth

ImGui has subtle hit-testing rules: popups eat clicks above their
parent, drag operations capture exclusive mouse, hovered-but-disabled
widgets behave correctly.  Easy to get 90% right and have the last
10% feel "off."

**Mitigation:** copy ImGui's `ButtonBehavior` function as a literal
reference — port its logic line-by-line.  Don't be clever in Phase 1.

### 3. Active-item state machine

The `g.ActiveId` / `g.HoveredId` state machine in ImGui handles a lot
of edge cases (drag-out-of-button, click-and-hold during scroll,
re-entrant focus changes).

**Mitigation:** `imgui_internal.h` has the state machine fully
specified.  Translate it directly.  This isn't a place to innovate.

### 4. Float/integer slider behavior

The way ImGui interpolates a slider's screen position to its value
(and vice versa) handles power scales (sqrt for HDR sliders), wrap,
and clamp behavior subtly.  Easy to get wrong.

**Mitigation:** the function is ~150 LOC in `imgui_widgets.cpp`.
Direct port, with tests for monotonicity + roundtrip stability.

### 5. The temptation to "improve" things mid-port

Every time I see a quirk in ImGui's API, I'll be tempted to "fix it"
in the Zig version.  This is wrong — the user wants ImGui, not
Zig-ImGui-2.0.  Quirks ARE the API.

**Mitigation:** explicit allow-list of departures (the ones in this
doc).  Anything else: port faithfully.

---

## What we are NOT doing

To be unambiguous about scope:

- **No tables.**  `ImGui::BeginTable` is 5K LOC alone.  Maybe Phase 8.
- **No docking.**  10K LOC, requires multi-viewport.  Out of scope.
- **No multi-viewport.**  We're wasm, no native windows to drag into.
- **No DirectX/Vulkan/Metal.**  WebGL2 only.
- **No InputText callbacks.**  Phase 3's `inputText` will be plain
  string editing.  Completion / history / validation can come later.
- **No file dialog.**  Application concern, not the library's.
- **No `LogText` / clipboard pipe to disk.**  Browser doesn't have a
  filesystem.  Clipboard goes through `navigator.clipboard` — we add
  a thin web binding.
- **Faithful `imgui_demo.cpp` port.**  10K LOC of demo code; way too
  much for this project's scope.

---

## Recommended next-turn entry point

**Phase 1, narrow scope:**

1. Create `src/ui.zig` skeleton:
   - All the data types (UiContext, Ui, Window, DrawList, ...)
   - `beginFrame`, `endFrame`, `render` lifecycle
   - ID hashing + ID stack
   - Cursor + layout state
   - Hit testing
   - Active item / hover state machine
   - Internal `drawRectFilled`, `drawText`, `drawRect` primitives
     routed through rlgl
   - Default dark theme `Style`
   - Font loaded at App startup, shared with `text` module
   - **One** widget: `button`

2. Wire `Frame.ui` field, App-owned UiContext.

3. `examples/imgui_phase1.zig` — two windows, button in each, click
   counter.  Visual proof of correctness.

4. Inline tests for ID hashing, layout cursor, hit-test math.

5. `zig build smoke-test` adds the new example, GL-call count
   asserts work.

Time estimate: 1.5 turns to Phase 1 done.  After that, Phase 2 (the
seven essentials) goes fast because the runtime is settled.

---

## Source attribution

When implementing, every file gets a comment header noting:

```
// Adapted from Dear ImGui by Omar Cornut, MIT license.
// Render path adapted from rlImGui by Jeffery Myers, zlib license.
// See THIRD_PARTY_LICENSES.md for full attribution.
```

Even though we're re-implementing in Zig, we're using ImGui's API
verbatim and rlImGui's render strategy verbatim.  Both authors
deserve top-of-file credit.

---

## File / outputs at end of project

```
src/ui.zig                       # ~3000-5000 LOC main file
src/tests/ui_test.zig            # OR inline tests in ui.zig
examples/imgui_demo.zig          # canonical demo
examples/struct_editor.zig       # editStruct showcase
docs/ui-cheatsheet.md            # api quick-ref
docs/ui-design.md                # this file (reference)
THIRD_PARTY_LICENSES.md          # ImGui MIT + rlImGui zlib
```

Public API exposed via `z.ui.*`.

---

*End of design doc.  Write code next turn, not before.*
