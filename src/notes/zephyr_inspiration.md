# Zephyr inspiration → zimr — BRAINSTORM + PLAN

> Goal (Simon): study Zephyr (a Zig ECS/scene/editor engine), find how to
> improve zimr, brainstorm wildly, plan, then align one question at a time.

## What Zephyr is
A content-driven Zig engine (glfw + OpenGL 4.6) split into a **runtime** and a
**visual editor**, built on two of its own libs: `zcs` (an ECS registry) and
`zimp` (scene / schema / id value types + an editor protocol). The pieces:
- **Components** are plain structs (`TransformComponent{ position, rotation,
  scale }`) that declare `pub const schema_meta` — a stable UUID, a reverse-DNS
  name, a version, and per-field metadata (`.number` for wire-stable
  serialization à la protobuf, `.display_name`, `.kind_override = .asset_ref`,
  `.default_override`).
- **`derive_schema`** turns a component's fields + `schema_meta` into, at
  comptime, a serialization codec AND an editor schema. This is the linchpin.
- **Scenes** are DATA — entities + serialized components — saved/loaded.
- **Assets**: source files (`.obj`, `.glb`, `.jpg`, `.vert/.frag`, declarative
  `.zamat` materials) each with a `.zmeta` UUID sidecar, **cooked** by the
  editor into runtime blobs. Materials are data (shader + textures + params),
  not code.
- **Editor**: viewport + inspector (auto-UI from schemas) + console + scene
  hierarchy; cooks assets, edits scenes; a `.proj` project file.

## The contrast with zimr
zimr is **code-driven, immediate-mode, web-first** (wasm/WebGPU), pure-Zig,
with a Dear ImGui port + docking + render-to-texture — and NO ECS, scene
format, asset pipeline, serialization, or editor. Assets ride inside the wasm
via `@embedFile`. Zephyr shows the data-driven path; zimr already owns the
hardest editor prerequisites (an immediate-mode UI that runs in the browser).

## The linchpin insight
Zephyr's power comes from ONE idea: **comptime reflection over plain structs**
generating serialization + editor UI. zimr can adopt exactly this, and it lands
even harder here because zimr already has the ImGui port to render the
inspectors AND runs in the browser (so the editor could too).

## Brainstorm — tiers, wildest first
**The moonshot vision:** zimr becomes a *web-native game engine you can also
edit in the browser* — pure Zig → wasm, where a reflection layer connects your
plain-Zig game structs to auto-inspectors, save/load, an optional ECS + data
scenes, and a visual editor that runs on the same WebGPU canvas. The
immediate-mode/code-first path stays; the data-driven layer is opt-in on top.

Broken into buildable tiers:

**Tier 1 — Reflection / schema layer (the foundation, self-contained).**
`z.reflect` / `z.schema`: from any plain Zig struct, comptime-derive
- **auto-inspector** — editable ImGui UI (drag f32, vec2/3/4 + color pickers,
  bool checkbox, int drag, enum combo, nested structs, slices) via zimr's
  existing UI. `z.inspect("Tweak", &my_state)` → instant live-tweak panel.
- **auto-serialize** — struct ⇄ ZON (Zig-native) or a Value union: save/load
  any struct, config, save-games.
- optional per-field hints (min/max for sliders, display name, asset-ref kind)
  via a light `schema_meta`-style decl or doc-comment attributes — with sane
  defaults so a bare struct just works.
Delivers value on day one to EVERY zimr app (debug/tuning UIs), disrupts
nothing, and is the base every later tier reuses.

**Tier 2 — ECS + data scenes (opt-in).**
A lightweight ECS (sparse-set or archetype), components = plain structs (which
already get Tier-1 reflection). A **scene** = entities+components serialized via
Tier 1 → save/load levels as ZON. Retained/data-driven, alongside (not
replacing) immediate mode.

**Tier 3 — Asset pipeline (light).**
Asset UUIDs + `.meta` sidecars for stable identity; a declarative material
format (shader + textures + params as data) hooking into zimr's shader-schema
system. Keep `@embedFile` as the delivery mechanism (web-friendly); add an
optional cooking pass (meshoptimizer, texture compression, shader precompile)
for size/speed.

**Tier 4 — The browser editor (moonshot).**
A zimr-native editor running on the WebGPU canvas: viewport (render-to-texture
scene view we already have) + inspector (Tier 1) + scene hierarchy + asset
browser + console — all from the ImGui port. A web-native engine WITH a
web-native editor is a genuine differentiator.

## Other sparks (smaller, independent)
- **Wire-stable serialization** (protobuf-style field numbers) for
  forward/backward-compatible save-games.
- **Reflection beyond scenes**: auto debug HUDs, config files, even network
  replication, from structs.
- **Declarative materials** independent of the rest (data materials for the
  existing renderer).
- **Component `schema_meta` convention** (UUID + versioned fields) even without
  a full ECS — just for save/load stability.

## Recommended starting point
**Tier 1, the reflection/auto-inspector layer.** Highest leverage, lowest
disruption, plays directly to zimr's comptime + ImGui strengths, useful
immediately, and the foundation the ECS / scenes / editor all stand on.

## Open questions (align one at a time — see chat)
Ambition (extract patterns vs pursue the editor vision) · start with the
reflection layer? · inspector-first vs serialization-first · ECS: build vs
skip · editor: in-browser moonshot vs desktop vs none · serialization format
(ZON vs custom) · how much to keep immediate-mode-first.

## DECISIONS (settled with Simon) + PROGRESS
- **Frame:** reflection layer FIRST (not the editor yet). Focus: serialization → asset pipeline → big-world chunk loading. Editor later.
- **Serialization:** PORT zoto's approach into zimr (not depend); VERSIONED protobuf-style wire (field numbers → schema evolution); FREE FUNCTIONS on plain structs (not wrapped Message(T) types); slice-based (wasm-friendly). Philosophy: flat files, no useless abstraction, programmer-centric.
- ✅ **DONE — `src/serialize.zig`** (the serializer core, std-only, standalone-testable). Free fns: `encode(value, buf)`, `encodedSize(value)`, `encodeAlloc(value, gpa)`, `decode(T, bytes, gpa)`, `freeDecoded(T, value, gpa)`. Handles ints (varint), floats (fixed 32/64), bool, enums, `[]const u8`, nested structs (recursive), optionals, repeated slices. Field numbers in declaration order; optional `pub const _fields` for wire-stable overrides. Unknown fields skipped (schema evolution). Wire bytes are protobuf-compatible. Re-exported as `z.serialize`. 3 roundtrip tests pass (`zig test src/serialize.zig`); lint 0.
- Gotcha: this Zig (0.17-dev) uses `@typeInfo(T).@"struct".field_names` + `.field_types[i]` (NOT `.fields`).

## STILL OPEN (align next)
Decode non-u8 slices (alloc arrays) · zm.Vec/Color as first-class field types · a wasm demo (browser save/load) · then: which next — asset pipeline or chunk loading · async via zimr's existing web-workers vs porting zob.

## ✅ zimr899 — demo: save example state to browser storage
- NEW `examples/state_persistence`: a `SavedState` struct (colour, spin speed, cube scale, save_count) is serialized with `z.serialize.encodeAlloc` and written to localStorage via `z.web.dom.persistence_save`; on init it's read back (`persistence_size` → alloc → `persistence_read` → `z.serialize.decode`) and restored. ImGui panel (colorEdit/sliders/Save/Clear) + a spinning cube coloured/scaled by the state. Tweak → Save → reload page → tweaks + save count come back. First real wasm exercise of the serializer.
- Gotchas: persistence API is under `z.web.dom.*` (not `z.web.*`); `u.text` fmt string is a comptime param (runtime string must be an arg: `u.text("{s}", .{cond ? ...})`); `Frame` has no `gpa` field → captured the allocator in State; font `atkinson_mono_ttf` is globally available to any example (no build wiring).
- Serializer proven end-to-end in the browser. NEXT (still open): array/vec support in the serializer, then asset pipeline vs chunk loading.

## ✅ zimr900 — DEEP BUG FIXED: persistence corrupted binary
- ROOT CAUSE: zimr's persistence (`web.dom.persistence_save`/`read`) round-trips through a JS string — save does `TextDecoder('utf-8').decode(bytes)` (bridge.zig modString), read does `TextEncoder.encode`. That's LOSSY for any non-UTF-8 binary: arbitrary bytes (e.g. IEEE-754 float bytes like 9A 99 19 3F) become U+FFFD replacement chars and don't survive. Never surfaced before because the only caller was UI-layout persistence (valid-UTF-8 JSON). The serializer's binary output tripped it.
- FIX: added binary-safe `web.dom.persistence_save_bytes(gpa, key, bytes)` + `persistence_load_bytes(gpa, key)` that base64-encode before the (UTF-8) string hop — base64 is pure ASCII, so it survives losslessly — and base64-decode on read. Uses `std.base64.standard`. Left the text API untouched (still fine for JSON). state_persistence demo switched to the binary-safe pair.
- Verified: new headless test in serialize.zig proves serialize→base64→decode preserves bytes+struct (4/4 tests pass); demo builds green, lint 0, smoke balanced. Should now work on Netlify (real https origin). Simon to confirm on device.

## ✅ zimr901 — serializer learns zm types (Vec / Mat / Color)
- Added `.vector` (zm.Vec/Vec2/Vec3/Quat = @Vector) + `.array` (zm.Mat = [4]Vec) handling to serialize.zig: each aggregate is one length-delimited field, body = elements packed bare (no per-element tags); Mat recurses array->vector->floats. New bareSize/encodeBare/decodeBare helpers. `zm.Color` (extern struct r/g/b/a: u8) rides the existing nested-struct path.
- Also fixed a latent decode bug: the nested-struct case did `dst.* = .{}` before decoding, which fails to compile for non-defaulted structs (like zm.Color) — dropped it so nested structs decode into their parent-provided default instead.
- Tests: new roundtrip covering @Vector(3), @Vector(4), [4]@Vector(4) matrix, and a u8 colour struct — 5/5 pass. Lint 0 (two prefer-vec hits silenced with `// lint:off`: serialize.zig is std-only + standalone-testable, can't import zm).
- Demo: state_persistence gained a persisted `zm.Vec3 position` (3 sliders via a [3]f32 copy, since vector elements aren't addressable; cube drawn there). Added LAST in the struct so older saves still load. Build green, smoke balanced.
- Serializer now covers zimr's core value types end-to-end. STILL OPEN: decode of non-u8 slices (alloc arrays); then asset pipeline vs chunk loading (async likely via zimr's existing web workers).

## ✅ zimr902 — serialization COMPLETE (repeated-slice decode + _fields)
- Implemented decode of repeated (non-u8) slices: decodeMessage now routes a repeated field to `appendDecoded` (grows the slice one element per wire occurrence; static `&.{}` default handled specially). freeDecoded frees element allocations + the backing slice. Encode already worked; decode was a @compileError before.
- Confirmed `_fields` field-number overrides work (pinned/out-of-order numbers for wire stability across renames) with a test. Clarified the remaining decodeField compileError (now only slice-of-slice, genuinely unsupported).
- Tests: 8/8 pass — core types, null optional, schema evolution, base64 round-trip, zm vectors/matrices/colour, repeated slices, empty slice, _fields overrides. Lint 0. Integrates (demo builds green).
- **SERIALIZATION FOUNDATION DONE.** `z.serialize` handles: ints, floats, bool, enums, strings, nested structs, optionals, repeated slices (enc+dec), @Vector/array (zm.Vec/Mat/Quat), u8-struct (zm.Color); versioned (field numbers + _fields overrides); schema-evolving (skips unknown); binary-safe persistence (base64) proven in-browser.
- NEXT: the big fork — asset pipeline vs big-world chunk loading (async likely via zimr's existing web workers).
