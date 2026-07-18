# imgui-arc-tutorial-turn-384.md — where we are, what shipped, what's next

A narrative snapshot of the imgui port arc as of turn 384.
Audience: Simon, and any future Claude session that picks this
up.  Written like a tutorial — the goal isn't just to inventory
what happened, but to make the *reasoning* legible so the next
person can extend the work without re-discovering the
constraints.

---

## 1. Where the arc is, in one paragraph

zimr is a pure-Zig port of Dear ImGui targeting wasm32-wasi +
WebGL2.  The imgui parity arc has been running for 80+ turns,
with a 47-turn detour through a lint cleanup that wrapped at
turn 381.  As of turn 384, we're back on the imgui plan, now
called **v7** (drafted turn 383), executing the **Prelude** and
beginning P1 (the reflection inspector).  Tests are at 1559
green; lint exits non-zero on any rule hit; the codebase is
healthier than it's ever been.

---

## 2. Turn 382 — Linter simplification (recap)

Simon asked: "Do we really need linter arguments?  We don't
need to skip or do only one rule…  simple, like zig, no
warnings."

What got stripped from `tools/lint_zimr.zig`:

- `--quiet` flag — gone.  Either the file passes or it doesn't.
- `--only=tag,tag` — gone.  No per-rule filtering.
- `--skip=tag,tag` — gone.  Same reason.
- `--fix=branch-braces` — gone.  The whole Autofix section (~130
  LOC: `Edit`, `EditsCollector`, `addBraceEditForBody`,
  `applyEdits`) deleted.
- `--no-cache` — gone.  The mtime cache is unconditional now.

Knock-on simplifications in the `Ctx` struct:

```zig
// BEFORE:
const Ctx = struct {
    alloc: std.mem.Allocator,
    path: []const u8,
    source: [:0]const u8,
    ast: *const Ast,
    issues: *std.ArrayList(Issue),
    skip: *const std.StringHashMap(void),
    only: *const std.StringHashMap(void),
    is_ffi_seam: bool,
    edits_collector: ?*EditsCollector = null,

    fn enabled(self: Ctx, tag: []const u8) bool { ... }
    fn emit(...) !void {
        if (!self.enabled(tag)) return;
        ...
    }
};

// AFTER:
const Ctx = struct {
    alloc: std.mem.Allocator,
    path: []const u8,
    source: [:0]const u8,
    ast: *const Ast,
    issues: *std.ArrayList(Issue),
    is_ffi_seam: bool,

    fn emit(...) !void {
        // No filter — always emit.
        ...
    }
};
```

The mtime cache was already implemented in an earlier turn —
each lint-clean file gets a stamp at
`tools/.zig-cache/lint-stamps/<wyhash64>.stamp` containing the
source's mtime and the lint binary's mtime.  After turn 382's
simplification, `zig build lint-check` warm is 0.24s no-change,
0.25s after a single-file edit — fast enough that
compile → lint → fmt-check sequencing is viable (the next
unfinished item is wiring this into the install step).

---

## 3. Turn 383 — Plan v7 + Prelude

Simon: "Study the already existing plan mentioned in plan.md
about imgui completion.  Rewrite the plan to your liking and
attack."

### 3.1 Plan v7 — the three structural changes

**(a) D-before-B reorder.**  v6 had the reflection inspector
(Phase D) after dev tools (Phase B), with the rationale "grow
eyes before experimenting."  v7 promotes the inspector to **P1**
because most of Phase O's `show*` widgets collapse to one-liners
once the inspector exists:

```zig
// What `showStyleEditor` was going to be (v6 plan, hand-written):
pub fn showStyleEditor() void {
    u.sliderFloat("FontSizeBase", &ctx.style.font_size_base, ...);
    u.sliderFloat("FontScaleMain", &ctx.style.font_scale_main, ...);
    u.sliderFloat2("WindowPadding", &ctx.style.window_padding, ...);
    // ... 100+ more lines, matches imgui_demo.cpp:8558-9100 ...
}

// What `showStyleEditor` is, after inspector lands (v7):
pub fn showStyleEditor() void {
    _ = u.inspect("Style", &ctx.style);
}
```

That's the leverage.  Build the inspector first, then a bunch of
later phases shrink.

**(b) Phase A dropped.**  v6's Phase A was three loose-ends (dock
persistence demo, showcase Docking tab, archive plan v5).  v7
folds these into the **Prelude** (single turn) and P18 (final
archive).  No semantic loss — they were never a "phase," just a
small batch.

**(c) Layout linting scope-down.**  v6 spec'd a new
`src/ui_lint.zig` module with a 64-bit warning bitset and a
registered `Lint` enum.  v7 demotes this to "five named asserts
at sites that catch real bugs":

| Lint | Site |
|---|---|
| `dragRange.min >= max` | `dragImpl` entry |
| `slider.min >= max` | `sliderImpl` entry |
| `tableColumn.width == 0` after layout | `endTable` |
| `openPopup(id)` called twice in one frame | `openPopup` |
| `content_overflow` | `endWindow` |

Each is a four-line `std.log.warn` block.  If a sixth case
emerges, we'll factor.  YAGNI applies hard here — 380 turns and
the existing `warned_text_no_font` flag has been enough.

### 3.2 Prelude — dock_persistence demo

The dock persistence wiring shipped turns 319-334 — a window's
position/size and the dock tree both serialize to `.zon`, get
written to localStorage every 60 frames, and graft back on the
next page load.  The Prelude exercises this end-to-end with
a demo.

The new demo, `examples/ui_dock_persistence.zig`, has the
minimum interesting surface:

```zig
const State = struct {
    ui_ctx: ui.UiContext,
    font_cache: z.FontCache = .{},
    shapes_texture: z.ShapesTextureState = .{},

    counter: i32 = 0,
    layout_built: bool = false,
    root: ui.Id = 0,

    clear_status_buf: [128]u8 = .{0} ** 128,
    clear_status_len: usize = 0,
};

fn initState(gpa: std.mem.Allocator, _: *z.Frame, s: *State) !void {
    s.* = .{ .ui_ctx = ui.UiContext.init(gpa) };
    // ... font load ...

    // THIS is the line that opts the demo into persistence.
    // localStorage key becomes "zimr_dock_persistence_demo"
    // (JS layer adds the "zimr_" prefix).
    s.ui_ctx.persistence_key = "dock_persistence_demo";
}
```

The lifecycle, end-to-end:

1. **First load**: `tryAutoLoad(ctx)` runs in the first
   `beginFrameRaw`.  Calls `web.persistence_load(ctx.gpa,
   "dock_persistence_demo")` which goes through three externs:
   `js_persistence_size` (returns byte length), `js_persistence_read`
   (copies into a caller-allocated buffer), then `apply` parses
   the .zon payload and populates `ctx.pending_persistence` +
   `ctx.pending_dock_tree`.
2. **DockBuilder runs once**: the `if (!s.layout_built)` branch
   carves the default 3-pane layout via
   `dockBuilderSplitNode(.left, 0.30)` and again `(.right, 0.40)`.
   `dockBuilderDockWindow("Tools", ...)`, `("Viewport", ...)`,
   `("Notes", ...)` anchor windows into the leaves.
   `dockBuilderSetCentralNode` marks the Viewport leaf as the
   one that absorbs free space.
3. **First save**: 60 frames later, `endFrame` calls
   `tryAutoSave(ctx)` which serializes the live tree via
   `serialize(gpa, ctx)` → .zon bytes → `js_persistence_save`.
4. **F5 refresh**: back to step 1, but now the .zon payload
   exists.  `tryAutoLoad` populates `pending_dock_tree`.  The
   first `dockSpace("MainDock", ...)` call detects the pending
   tree and calls `tryRestoreDockTree`, which walks the flat
   `PersistedDockNode[]` and rebuilds nodes by id.
5. **"Clear layout and restart" button**: calls a new extern
   `z.dom.persistence_remove(key)` which routes to
   `localStorage.removeItem("zimr_" + key)`.  Also tears down the
   in-memory tree via `dockBuilderRemoveNode(s.root)` and flips
   `layout_built = false` so the next frame rebuilds defaults.

The new extern was the only `src/ui.zig`-adjacent code shipped
in the Prelude:

```zig
// src/web.zig — declaration
extern "dom" fn js_persistence_remove(key_ptr: [*]const u8, key_len: usize) i32;

pub fn persistence_remove(key: []const u8) i32 {
    return js_persistence_remove(key.ptr, key.len);
}

// src/web/zimr.ts — implementation
js_persistence_remove(key_ptr: number, key_len: number): number {
    try {
        if (typeof localStorage === "undefined") return 2;
        const key = "zimr_" + readString(state, key_ptr, key_len);
        localStorage.removeItem(key);
        return 0;
    } catch {
        return 2;
    }
},
```

Status codes: `0 = success` (key removed or absent — either
way), `2 = localStorage unavailable` (host build, private mode).
No "key didn't exist" failure — `removeItem` is idempotent.

The showcase tab is intentionally a **description panel**, not
an embedded dockspace.  Reason: a dockspace hosts top-level
windows, and those don't disappear when the user switches tabs.
Embedding a live dockspace in a tab is doable but creates UX
oddities (the docked windows linger across tab switches, the
dockspace fights for layout with the tab content).  The
standalone `ui_dock_basic` and `ui_dock_persistence` demos are
the deep-dive surface; the showcase tab points at them.

---

## 4. Turn 384 — P1 discovery + P1.3 mutable strings

This is what just shipped.  Three things happened:

### 4.1 Process directive → claude.md

Simon: "Always take note of what you are doing in the middle of
turns in the changelog.  Start turns by reading the end of
changelog.  Aim for finishing turns when you are at 80% of the
tool budget."

Three rules went into `claude.md`:

- **Step 0 of per-turn rhythm**: read the changelog tail first.
  When a turn restarts or compacts, the previous turn's mid-stream
  notes are the recovery trail.
- **Step 4 sub-bullet**: take notes *during* the turn — three
  updates is the target (stub at start, mid-turn checkpoint,
  audit close).  Not just an end-of-turn flush.
- **New "Tool-budget discipline" section**: aim to finish a turn
  at ~80% of tool budget, not 100%.  The last 20% is for audit
  gate + close-out; pushing close to 100% means those get
  skipped or rushed, which compounds into rollback debt.

### 4.2 Discovery: P1.1 and P1.2 already shipped

Started turn 384 planning to build the reflection inspector from
scratch.  Discovered while skimming `src/ui.zig` that it was
already there, sitting under a "Phase 5A" banner.

Surface area, all public on `Ui`:

```zig
// Bare inspector — no header, just iterate fields:
pub fn editStruct(self: Ui, value_ptr: anytype) bool;

// Same, with per-field opts struct:
pub fn editStructOpts(
    self: Ui,
    value_ptr: anytype,
    opts: anytype,
) bool;

// Labeled (treeNode-wrapped) variants:
pub fn inspect(self: Ui, label: []const u8, value_ptr: anytype) bool;
pub fn inspectWithAttrs(
    self: Ui,
    label: []const u8,
    value_ptr: anytype,
    opts: anytype,
) bool;

// Style editor — one liner over inspector:
pub fn styleEditor(self: Ui) bool {
    return editStructImpl(self.ctx, self.style(), .{});
}

// Bonus: dynamic-list editor with add/remove buttons:
pub fn editArrayList(
    self: Ui,
    label: []const u8,
    list_ptr: anytype,
) bool;

pub fn editArrayListOpts(
    self: Ui,
    label: []const u8,
    list_ptr: anytype,
    opts: anytype,
) bool;
```

The per-field opts struct is the AM-8 "attrs" pattern from the
plan:

```zig
const Settings = struct {
    speed: f32 = 1.0,
    iterations: i32 = 100,
    name: []const u8 = "default",
    enabled: bool = true,
    mode: enum { fast, careful } = .fast,
};

// Per-field opts, by field name.  Each entry is itself a struct
// with optional members.  Unknown opts entries are silently
// ignored — so a struct can grow without breaking existing
// callsites.
u.inspectWithAttrs("Settings", &state.settings, .{
    .speed = .{ .min = 0.0, .max = 5.0, .fmt = "{d:.2}" },
    .iterations = .{ .min = 1, .max = 1000 },
    // No entry for `name`, `enabled`, `mode` → defaults.
});
```

The dispatcher (`editFieldDispatch`) handles every reasonable
`@typeInfo` tag:

```zig
fn editFieldDispatch(
    ctx: *UiContext,
    label: []const u8,
    comptime FieldT: type,
    field_ptr: anytype,
    field_opts: anytype,
) bool {
    const ui: Ui = .{ .ctx = ctx };
    switch (@typeInfo(FieldT)) {
        .bool => return ui.checkbox(label, field_ptr),
        .float => return editFloatField(ctx, label, FieldT, field_ptr, field_opts),
        .int   => return editIntField  (ctx, label, FieldT, field_ptr, field_opts),
        .@"enum" => return editEnumField(ctx, label, FieldT, field_ptr),
        .@"struct" => {
            if (FieldT == Color) return editColorField(ctx, label, field_ptr);
            if (FieldT == zm.Vec2) return editVector2Field(ctx, label, field_ptr);
            if (comptime @hasDecl(FieldT, "__is_bounded_string")) {
                return editBoundedStringField(ctx, label, field_ptr);
            }
            if (ui.treeNode(label, .{})) {
                defer ui.treePop();
                return editStructImpl(ctx, field_ptr, .{});
            }
            return false;
        },
        .array => |arr| return editArrayField(ctx, label, FieldT, arr, field_ptr, field_opts),
        .pointer => |p| {
            // []const u8 → display-only.
            const is_const_byte_slice: bool =
                p.size == .slice and p.child == u8 and p.is_const;
            if (is_const_byte_slice) {
                ui.text("{s}: {s}", .{ label, field_ptr.* });
                return false;
            }
            ui.text("{s}: <unsupported pointer type {s}>", .{ label, @typeName(FieldT) });
            return false;
        },
        .optional => |opt| {
            // Checkbox toggle.  When toggling from null → set,
            // initialize via std.mem.zeroes(opt.child).  That
            // works for most types but @compileError's for
            // optionals wrapping non-allowzero pointers (Style.font
            // is `?*const Font`).  Gate the toggle path on a
            // canZeroInit comptime check; fall back to
            // display-only-when-null + recurse-when-set otherwise.
            if (comptime canZeroInit(opt.child)) {
                var present: bool = field_ptr.* != null;
                if (ui.checkbox(label, &present)) {
                    if (present) {
                        field_ptr.* = std.mem.zeroes(opt.child);
                    } else {
                        field_ptr.* = null;
                    }
                    return true;
                }
                if (field_ptr.*) |*inner| {
                    ui.indent();
                    defer ui.unindent();
                    return editFieldDispatch(ctx, label, opt.child, inner, field_opts);
                }
                return false;
            } else {
                if (field_ptr.*) |*inner| {
                    ui.text("{s}: <set>", .{label});
                    ui.indent();
                    defer ui.unindent();
                    return editFieldDispatch(ctx, label, opt.child, inner, field_opts);
                }
                ui.text("{s}: null", .{label});
                return false;
            }
        },
        .@"union" => |un| {
            // Tagged union: combo over tags + recurse on active variant.
            const TagT: type = un.tag_type orelse {
                ui.text("{s}: <untagged union>", .{label});
                return false;
            };
            const current: TagT = std.meta.activeTag(field_ptr.*);
            var any_changed: bool = false;

            if (ui.beginCombo(label, @tagName(current), .{})) {
                defer ui.endCombo();
                inline for (un.fields) |uf| {
                    const tag_val: TagT = @field(TagT, uf.name);
                    const selected: bool = (tag_val == current);
                    if (comptime canZeroInit(uf.type)) {
                        if (ui.selectable(uf.name, selected, .{}) and !selected) {
                            field_ptr.* = @unionInit(FieldT, uf.name, std.mem.zeroes(uf.type));
                            any_changed = true;
                        }
                    } else {
                        ui.textDisabled("{s}", .{uf.name});
                    }
                }
            }

            ui.indent();
            defer ui.unindent();
            inline for (un.fields) |uf| {
                if (uf.type != void) {
                    const tag_val: TagT = @field(TagT, uf.name);
                    if (tag_val == current) {
                        const payload_ptr: *uf.type = &@field(field_ptr.*, uf.name);
                        if (editFieldDispatch(ctx, uf.name, uf.type, payload_ptr, .{})) {
                            any_changed = true;
                        }
                    }
                }
            }
            return any_changed;
        },
        else => {
            ui.text("{s}: <unsupported type {s}>", .{ label, @typeName(FieldT) });
            return false;
        },
    }
}
```

A few decisions worth flagging in this dispatcher, because
they're not obvious from reading:

1. **Color and Vec2 are special-cased.**  Without that, a `Color`
   field would recurse into four `inputInt` widgets (r/g/b/a).
   With it, the user sees a single `colorEdit` swatch with the
   right semantics.  Same for `Vec2` → two `inputFloat`s in a row
   rather than a tree-node-of-two-floats.
2. **`canZeroInit` gates the optional toggle and union
   tag-switch paths.**  Some types can't be zero-initialized at
   comptime — e.g., `?*const Font` won't accept
   `std.mem.zeroes(*const Font)` because non-allowzero pointers
   can't be null.  The fallback is "display-only when not set,
   recurse when set" — the inspector loses the ability to toggle
   the optional null/non-null, but keeps the ability to edit the
   wrapped value when it exists.  Style.font hits this path.
3. **The `.@"struct"` branch checks specific types
   BEFORE the generic recurse path.**  Order matters.
   `BoundedString(N)` is a struct; without the early-return
   detection, it'd recurse into a tree-node-of-(buf + len),
   which is worse than useless — you'd get 64 inputInt widgets
   on a 64-byte buffer.

### 4.3 P1.3 — BoundedString(N) (the actual new code)

The dispatcher above already had the `__is_bounded_string`
check, but the type itself didn't exist yet.  Turn 384 ships it:

```zig
/// Inline-buffered string with a fixed byte capacity and a stored
/// length.  The reflection inspector (P1.3) detects fields of this
/// type and routes them through `inputText`, giving the caller
/// mutable text editing without a heap allocator.
pub fn BoundedString(comptime N: usize) type {
    return struct {
        buf: [N]u8 = .{0} ** N,
        len: usize = 0,

        const Self = @This();
        pub const capacity: usize = N;
        /// Marker decl used by `editFieldDispatch` to detect this type.
        pub const __is_bounded_string: usize = N;

        pub fn asSlice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn set(self: *Self, s: []const u8) usize {
            const n: usize = @min(s.len, N);
            @memcpy(self.buf[0..n], s[0..n]);
            self.len = n;
            return n;
        }
    };
}
```

And the dispatch helper:

```zig
fn editBoundedStringField(
    ctx: *UiContext,
    label: []const u8,
    field_ptr: anytype,
) bool {
    const ui: Ui = .{ .ctx = ctx };
    return ui.inputText(label, &field_ptr.buf, &field_ptr.len, .{});
}
```

That's it.  `inputText` already takes a `(buf: []u8, len: *usize)`
contract — same shape BoundedString stores natively.  No copy,
no rescan.

**Why a wrapping struct rather than `[N:0]u8` sentinel arrays?**

The alternative would have been to detect `[N:0]u8` (a byte
array with a null sentinel) and treat them as editable strings.
That's more "Zig-native" in one sense — it's a built-in type,
no new wrapping needed.  But:

- `inputText` works in `(buf, *len)` form.  Sentinel arrays
  don't carry an explicit length — you compute it via
  `std.mem.indexOfScalar(u8, &buf, 0) orelse buf.len`.  Every
  edit frame, that recomputes; every read from outside the
  inspector, also.
- The marker pattern is intent-bearing.  A user reading
  `player_name: BoundedString(32)` understands instantly.
  Reading `player_name: [32:0]u8 = [_:0]u8{0} ** 32` is less
  clear.

The cost is one public type that's basically a tiny tagged
buffer.  The win is direct wiring into `inputText` and an
intent-bearing marker.

### 4.4 Drive-by fixes

The "touching a fn = bringing the whole fn up to spec" rule
(claude.md §"Style rules") meant a few drive-by fixes while
`editFieldDispatch` was open:

```zig
// BEFORE — pre-existing untyped locals from earlier work:
const TagT = un.tag_type orelse { ... };          // line 10896
const payload_ptr = &@field(field_ptr.*, uf.name);  // line 10932

// AFTER:
const TagT: type = un.tag_type orelse { ... };
const payload_ptr: *uf.type = &@field(field_ptr.*, uf.name);

// And `pub fn inspect(self: Ui, label: []const u8, value_ptr: anytype) bool`
// was 3 params on one line — split per Rule 1.
```

Lint cleanup arc missed these; the rule-2 (untyped-local) and
rule-1 (fn-args-multiline) checks caught them when ui.zig was
re-linted via the mtime cache.

---

## 5. Where we stand at the end of turn 384

| Metric | Value |
|---|---:|
| Host unit tests | **1559 / 1559 PASS** |
| Lint issues | **0 in 141 files** |
| `src/ui.zig` size | ~26,700 lines |
| Examples | 142 |
| New public API since turn 381 | `z.ui.BoundedString(N)`, `z.dom.persistence_remove` |
| Plan progress | Prelude shipped, P1 ~95% done (just P1.4 demo deferred) |

The arc is healthy.  Per-turn rhythm intact.  Audit gate green.
We can ship 25-30 more turns to arc close on the v7 schedule.

---

## 6. Next few turns — the plan

### Turn 385 — P2.1 DebugLog ring buffer

ImGui has `g.DebugLogBuf` (`imgui.cpp` search for
`DEBUG_LOG_EVENT_*`) — an internal ring buffer of events that
answers "why did the wrong thing get hovered/clicked?".  We port
it.

Sketch:

```zig
// In UiContext:
debug_log: std.BoundedArray(DebugEvent, 256) = .{},

pub const DebugEventKind = enum {
    focus_changed,
    popup_opened,
    popup_closed,
    item_activated,
    drag_started,
    drop_accepted,
    dock_request_queued,
    id_collision,
    lint_warning,
    style_changed,
};

pub const DebugEvent = struct {
    frame: u32,
    kind: DebugEventKind,
    message: [128]u8,
    message_len: u8,
};

pub fn debugLogPush(
    ctx: *UiContext,
    kind: DebugEventKind,
    comptime fmt: []const u8,
    args: anytype,
) void {
    var ev: DebugEvent = .{
        .frame = @intCast(ctx.frame_count),
        .kind = kind,
        .message = undefined,
        .message_len = 0,
    };
    const written = std.fmt.bufPrint(&ev.message, fmt, args) catch ev.message[0..0];
    ev.message_len = @intCast(written.len);

    if (ctx.debug_log.len == ctx.debug_log.capacity()) {
        // Ring: drop the oldest event.  BoundedArray doesn't have
        // a pop-front, but we can shift left by one.  256 events,
        // ~80 bytes each — the shift is cheap.
        std.mem.copyForwards(
            DebugEvent,
            ctx.debug_log.slice()[0 .. ctx.debug_log.len - 1],
            ctx.debug_log.slice()[1..],
        );
        ctx.debug_log.len -= 1;
    }
    ctx.debug_log.append(ev) catch {};
}
```

Then wire ~12 strategic call sites:

| Site | Kind | Message |
|---|---|---|
| `activateWidget` | `item_activated` | `"id={x}"` |
| `openPopup` | `popup_opened` | `"id={x}"` |
| `closePopup` | `popup_closed` | `"id={x} reason={s}"` |
| `setFocus` | `focus_changed` | `"window={s}"` |
| `beginDragDropSource` | `drag_started` | `"type={s}"` |
| `acceptDragDropPayload` | `drop_accepted` | `"type={s}"` |
| `dockSpaceImpl` request enqueue | `dock_request_queued` | `"...details..."` |
| existing `warned_text_no_font` path | `lint_warning` | `"text_no_font"` |

No viewer yet — that's P2.4 / P15.  This turn ships writers +
the storage.  Tests verify ring-buffer wrap-around and
format-arg safety.

### Turn 386 — P2.2 Frame metrics

A `UiContext.metrics: Metrics` struct, populated each frame:

```zig
pub const Metrics = struct {
    frame_count: u32 = 0,
    /// Rolling 2-second window at 60Hz.
    frame_time_ms_history: [120]f32 = .{0} ** 120,
    frame_time_ms_history_head: u8 = 0,
    vertex_count: u32 = 0,
    index_count: u32 = 0,
    draw_call_count: u32 = 0,
    windows_active: u32 = 0,
    windows_hovered: u32 = 0,
    last_active_widget_id: Id = 0,
    last_active_widget_label: [64]u8 = .{0} ** 64,
    last_active_widget_label_len: u8 = 0,
};
```

Reset in `beginFrame`, finalized in `endFrame`.  Once this is
in, `showMetricsWindow` is literally one inspector call:

```zig
pub fn showMetricsWindow(self: Ui) void {
    _ = self.inspect("Metrics", &self.ctx.metrics);
    self.plotLines("frame ms", &self.ctx.metrics.frame_time_ms_history, .{
        .height = 60,
    });
}
```

That's the inspector's marquee leverage paying off.

### Turn 387 — P2.3 Five tactical lint asserts + P2.4 dev_tools demo

The five named asserts go in:

```zig
// In dragImpl entry:
if (opts.min >= opts.max and opts.min != opts.max) {
    lintWarnOnce(
        "drag-range",
        "drag '{s}': min ({d}) >= max ({d}) — clamping disabled",
        .{ label, opts.min, opts.max },
    );
}
```

Where `lintWarnOnce(comptime tag, fmt, args)` is the four-line
helper that fires once per (file, line) via a comptime-built
StringHashMap of seen tags.  Also pushes to the DebugLog so the
warning surfaces in the dev-tools viewer.

The dev_tools demo, `examples/ui_dev_tools.zig`, uses the
inspector for both panels:

```zig
if (u.window("Dev Tools", .{})) |w| {
    defer w.close();
    if (u.collapsingHeader("Metrics", .{})) {
        _ = u.inspect("metrics", &state.ui_ctx.metrics);
        u.plotLines("frame ms", &state.ui_ctx.metrics.frame_time_ms_history, .{});
    }
    if (u.collapsingHeader("DebugLog", .{})) {
        for (state.ui_ctx.debug_log.slice()) |ev| {
            u.text("[{d}] {s}: {s}", .{
                ev.frame,
                @tagName(ev.kind),
                ev.message[0..ev.message_len],
            });
        }
    }
}
```

That's the dev-tools demo "eating its own dogfood" via the
inspector.

### Turn 388 — P3 long-press → right-click bridge

Single turn.  Track per-touch start time + position; if still
in `mouse_left_down` and position drift < 6px after 500ms,
synthesize a `mouse_right_pressed` event for next frame and
clear `mouse_left_down`.

```zig
// In runtime/input.zig InputState:
touch_long_press_threshold_ms: u32 = 500,
touch_start_time_ms: ?u32 = null,
touch_start_pos: ?Vec2 = null,

// In the per-frame input update:
if (state.mouse_left_down) {
    const drift_px: f32 = ...;
    const elapsed_ms: u32 = ...;
    if (drift_px < 6 and elapsed_ms > state.touch_long_press_threshold_ms) {
        // Synthesize.
        state.mouse_right_pressed = true;
        state.mouse_left_down = false;
        // Reset trackers so the synthetic release doesn't
        // immediately re-trigger.
        state.touch_start_time_ms = null;
        state.touch_start_pos = null;
    }
}
```

Existing context-menu popups (which read `mouse_right_pressed`)
work on phone via long-press — the only change a user sees is
that long-holding now opens menus instead of being silently
ignored.  Test: unit test fires synthetic right-click; phone
smoke check on existing demos shows the behavior.

### Turns 389-390 — P4 Style persistence + presets

Extend `.zon` persistence to capture `Style` fields.  Add
`light_default` and `classic_default` const tables matching
imgui's `StyleColorsLight()` and `StyleColorsClassic()`.  A
3-button preset switcher goes into `ui_polish`.

The persistence extension is mostly schema work:

```zig
// In ui_persistence.zig:
pub const PersistedStyle = struct {
    // Mirror Style's Color + numeric fields.  Skip non-user-meaningful
    // fields (font pointers re-bind on load).
    text: [4]u8 = .{ 230, 230, 230, 255 },
    text_disabled: [4]u8 = .{ 128, 128, 128, 255 },
    // ... ~30 more color slots ...
    window_padding: [2]f32 = .{ 8, 8 },
    frame_padding: [2]f32 = .{ 4, 3 },
    // ... numeric fields ...
    font_size: f32 = 10,
};

pub const PersistedState = struct {
    version: u32 = CURRENT_VERSION,
    windows: []const PersistedWindow = &.{},
    dock_nodes: []const PersistedDockNode = &.{},
    style: ?PersistedStyle = null, // optional — apps that don't
                                   // theme persist nothing.
};
```

Then `serialize` populates `state.style` from the live
`ctx.style`, and `apply` writes back.  Schema-version bump
since we're adding a non-additive optional field — actually
no, zon `ignore_unknown_fields = true` lets old payloads parse
cleanly and `style: ?... = null` defaults to null on missing,
so this is forward-compatible without a version bump.

---

## 7. What I learned this turn worth remembering

A few notes for the next Claude that picks this up:

1. **Always grep before drafting.**  P1.1 and P1.2 were already
   shipped under a different banner ("Phase 5A") that didn't
   appear in the plan vocabulary.  47 turns of lint cleanup
   means the plan's "what's done" knowledge gets stale; the
   codebase is the source of truth.  Spent ~10 minutes
   discovering this; saved ~3 turns of redundant work.
2. **Pre-existing untyped locals show up under the mtime cache
   when you edit a file.**  The lint cleanup arc cleared all
   *visible* hits but a few sat in functions nobody had touched
   since the arc started.  Editing the file re-checks it and
   surfaces them.  Just fix them — touch-it-up-to-spec is the
   rule.
3. **The plan can be wrong.**  v6 budgeted ~4 turns for the
   reflection inspector; v7 inherited that estimate.  Reality:
   ~95% was already done.  Future Claudes should treat plan
   estimates as defaults to challenge, not contracts.
4. **Mid-turn changelog notes are real.**  Used them three
   times this turn (stub, mid-turn discovery, audit close).
   Felt natural; should be the standard rhythm.
5. **Tool-budget 80% rule has teeth.**  This turn used the last
   ~15% on changelog + plan-update + audit + zip.  Without that
   reserve, the close-out would have been rushed or skipped.

---

## 8. One-paragraph summary for the next session

We're 80+ turns into the imgui port, on plan v7 (drafted turn
383).  Prelude (dock_persistence demo + showcase Docking tab)
shipped turn 383.  P1 reflection inspector shipped 95% pre-arc
under "Phase 5A"; turn 384 closed the gap with `BoundedString(N)`
for mutable text fields.  Next: P2 foundation dev tools (DebugLog
ring buffer + Frame metrics + 5 tactical lint asserts +
dev_tools demo, ~3 turns).  Then P3 long-press → right-click
(1 turn).  Then P4 style persistence + presets (~2 turns).
Then flag-wave phases P5-P10 (~25 turns).  Then capstone P11-P18
(~12 turns).  ETA arc close: ~25-30 more turns from here.
