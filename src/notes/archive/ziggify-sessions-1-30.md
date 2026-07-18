### Vector2/Vector3/Vector4: extern struct → namespaced methods

Currently `types.Vector2` is `extern struct { x: f32, y: f32 }`
matching raylib's C ABI exactly — this is non-negotiable for the
port phase, because user-supplied `pub export fn` consumers see
the same memory layout.

For the zig API we want methods on Vector2 directly:
```zig
const v = z.Vector2{ .x = 1, .y = 2 };
const u = v.add(other).scale(2).normalize();
```

Implementation sketch: keep `extern struct`, add methods.  Methods
are zero-cost — they don't change the layout.  raymath.zig already
provides the free functions; we'd add thin method wrappers:
```zig
pub fn add(self: Vector2, b: Vector2) Vector2 {
    return raymath.vector2Add(self, b);
}
```

Estimate: ~150 method wrappers across Vector2/3/4/Matrix.  Pure
mechanical.

### Color: extern struct → builder + named constants

raylib has `RAYWHITE`, `RED`, etc. as `Color`-typed `#define`s.
We have them in `colors.zig` already.  Phase 12 wants:
```zig
const c = z.Color.rgba(255, 200, 100, 255);
const tinted = c.fade(0.5);
const hex = c.toHex(); // 0xFFC864FF
```

### Rectangle: position + size accessors

```zig
const r = z.Rectangle{ .x = 10, .y = 20, .width = 100, .height = 50 };
const tl = r.topLeft();      // Vector2{10, 20}
const center = r.center();   // Vector2{60, 45}
const right = r.right();     // 110
```

---

## Error-handling opportunities

raylib uses sentinel returns (`0` for "failed to load", `-1` for
"location not found", `false` for "operation failed").  Phase 12
should wrap with `!T` error unions:

| C function                  | Zig API target                                  |
|-----------------------------|-------------------------------------------------|
| `LoadTexture` returns id=0  | `loadTexture(gpa, path) !Texture2D`             |
| `LoadShader`  returns id=0  | `loadShader(gpa, vs, fs) !Shader`               |
| `LoadFont`    returns id=0  | `loadFont(gpa, path) !Font`                     |
| `rlGetLocationUniform = -1` | `getUniformLoc(prog, name) !UniformLocation`    |
| `rlFramebufferComplete=false` | `framebufferComplete(fb) !void`               |

Common error set:
```zig
pub const LoadError = error{
    FileNotFound,
    InvalidFormat,
    OutOfMemory,
    GpuOom,
    UnsupportedFormat,
    CompileFailed,
    LinkFailed,
};
```

---

## Allocator-explicit APIs

raylib's `LoadXxx` family allocates internally with `RL_MALLOC`
and pairs with `UnloadXxx`.  Zig idiom is allocator-explicit:

```zig
// raylib style:
const tex = LoadTexture("path.png");
defer UnloadTexture(tex);

// zig style:
const tex = try z.loadTexture(allocator, "path.png");
defer tex.deinit(allocator);
```

Functions that allocate and need this:
- `LoadImage*` family
- `LoadTexture*`, `LoadFont*`, `LoadShader*`, `LoadModel*`,
  `LoadSound*`, `LoadMusicStream*`
- `LoadFileData`, `LoadFileText`
- `ImageCopy`, `ImageFromImage`, etc. (allocator versions)
- `LoadImageColors`, `LoadImagePalette`

Phase 6 cleanup target: the texture/image loaders should be the
first allocator-explicit functions.

---

## Slice over pointer+length

Every place we have `[*c]const u8 + usize` should become `[]const u8`
in the zig API.  ABI export keeps the pair, zig wrapper passes
slice:

```zig
// ABI:
pub export fn rlGetLocationUniform(id: c_uint, name_ptr: [*c]const u8, name_len: usize) callconv(.c) c_int

// Zig:
pub fn getLocationUniform(id: u32, name: []const u8) i32 {
    return rlGetLocationUniform(id, name.ptr, name.len);
}
```

Same pattern for: `LoadShaderCode`, `TraceLog` text, `SetWindowTitle`,
`LoadImageFromMemory`, etc.

---

## State-singleton-elimination opportunities

Several modules carry `var X: State = .{}` file-scope singletons
because raylib's C uses globals:
- `rlgl.zig` → RLGL state (matrices, batch, etc.)
- `input.zig` → STATE (keyboard/mouse arrays)
- `core.zig` → TIME, FPS, WINDOW, TRACELOG
- `shapes.zig` → tex_shapes, tex_shapes_rec

For the zig API these should live on a `Context` struct.  Done well,
each module exposes a `Context` field and methods take `*Context`
or `*const Context`.  ABI-compatible exports forward to a default
`global_context` for backward compat.

Trade-off: this is a lot of plumbing.  The port phase locks in the
"raylib uses globals" mental model; Phase 12 needs to rewire it
to thread a context through.  The win is that running multiple
zimr instances in one process becomes possible (currently
impossible because rlgl's matrix stack is shared).

---

## Methods vs free fns: pick a side per type

raymath: every fn takes the type as first arg → trivially convert
to method.  Vector2.add, Vector2.length, etc.

rlgl: stays as-is.  These are GL-side imperative state mutations,
not really object-oriented operations.

shapes: free fns are fine; raylib convention is `DrawCircle` not
`Circle.draw`.

input: most are queries (`IsKeyDown(key)`).  Maybe namespace
under `z.input.isKeyDown(key)` — what we already have.  No need
for methods.

core: `GetTime()` etc. — namespace, not methods.

textures (Phase 6): `Image.load`, `Image.crop`, `Image.resize`
make a lot of sense here.  Texture also has natural method form.

---

## Naming: snake_case for zig functions

Currently every `pub export fn` uses raylib's PascalCase
(`IsKeyDown`, `GetMousePosition`, etc.) because that's the C ABI
contract.  The zig wrapper gets snake_case:

```zig
// Stays as ABI (C consumers see this):
pub export fn IsKeyDown(key: c_int) callconv(.c) bool

// Zig wrapper (zimr consumers see this):
pub fn isKeyDown(key: KeyboardKey) bool {
    return IsKeyDown(@intFromEnum(key));
}
```

The wrappers also tighten types: `c_int` → enum, `c_uint` → u32,
`bool` → `bool` (already same).

---

## Enum tightening

Currently keyboard keys are `pub const KEY_A: c_int = 65` etc. in
`enums.zig` matching raylib's `#define`.  Phase 12 wants:

```zig
pub const KeyboardKey = enum(c_int) {
    a = 65,
    b = 66,
    // ...
    space = 32,
    enter = 257,
    // ...
};
```

Then `isKeyDown(key: KeyboardKey)` is type-safe — can't pass a
mouse button by accident.  Same treatment for `MouseButton`,
`GamepadButton`, `KeyboardKey`, `PixelFormat`,
`TextureFilter`, `TextureWrap`, `BlendMode`, `ShaderUniformDataType`,
`TraceLogLevel`.

---

## Defer-friendly handles

Currently:
```zig
const tex = z.rlgl_gpu.rlLoadTexture(...);
defer z.rlgl_gpu.rlUnloadTexture(tex);
```

Phase 12 wants the Texture struct itself to support deinit:
```zig
const tex = try Texture2D.load(gpa, "logo.png");
defer tex.deinit();
```

This means Texture2D needs a method-style API and an internal
`gpa` reference (or accept gpa in deinit).  Slight tension with
the C ABI since raylib's `Texture2D` is just `{id, width, height,
mipmaps, format}` — no allocator.  The zig wrapper might be a
distinct type:

```zig
pub const Texture = struct {
    raw: types.Texture2D,
    // No gpa — Texture2D's GPU memory is freed via rlUnloadTexture,
    // which doesn't need an allocator.

    pub fn load(gpa: Allocator, path: []const u8) !Texture {
        // gpa needed for the IMAGE buffer during load,
        // but freed before return.  Texture itself owns no CPU mem.
        ...
    }
    pub fn deinit(self: Texture) void {
        rlgl_gpu.rlUnloadTexture(self.raw.id);
    }
};
```

---

## Frame-arena adoption

Current `Frame` already has `frame: Allocator` (per-frame arena)
and `scratch: Allocator` (per-update arena).  Most ported raylib
code never uses these because the C convention is "allocate with
LoadXxx, free with UnloadXxx".  Phase 12 should encourage
arena-allocated transients:

```zig
fn update(f: *z.Frame) void {
    // Format a string for one frame — arena-allocated, no free.
    const score_text = std.fmt.allocPrint(f.frame, "Score: {d}", .{score}) catch return;
    z.text.drawText(score_text, 10, 10, 20, z.colors.white);
}
```

---

## Logged opportunities (per-session)

### Session N (Phase 5 / shapes lift)
- `shapes.zig`: 69 fns all use raylib's PascalCase (`DrawCircle`,
  `CheckCollisionPointRec`).  Phase 12 wrappers:
  `z.shapes.drawCircle` → snake_case + slice ABI for any
  point-array params (`drawTriangleStrip(points: []const Vector2,
  color: Color)` instead of `[*]const Vector2 + c_int`).
- The `tex_shapes` 1×1 white-pixel texture state singleton lives
  inside `shapes.zig`.  In a Context-threaded API this would move
  to `Context.shapes_state`.
- Spline-point fns are stateless — perfect for Vector2 methods:
  `Vector2.bezierCubic(start, c1, c2, end, t)`.

### Session N (current — rtextures planning)
- Image manipulation in raylib mutates `Image *image` in-place.
  Zig idiom would prefer `image.cropped(rect)` returning a new
  Image, so the original isn't aliased.  But that doubles
  allocations.  Phase 12 should expose BOTH: in-place
  `image.crop(rect)` AND immutable `image.cropped(rect)` that
  copies first.
- `LoadImageColors(image)` returns a `[*c]Color` requiring
  `UnloadImageColors`.  Zig API: returns a slice owned by an
  allocator, freed by `gpa.free(colors)` — no special cleanup
  function needed.

### Session N+1 (textures lift)
- `textures.zig` lifted from zray includes both pure-CPU color
  fns AND heavy image-manipulation fns sharing the same module.
  Wasm DCE strips the function code but keeps the **import
  declarations** for `malloc`/`calloc`/`free`/`getRandomValue`
  (ABI surface persists even when no one calls it).  This
  inflated `keys.wasm` from 98→117 KB just by adding a single
  `colorLerp` call.  **Phase 12 fix**: split textures into
  `textures_color.zig` (pure, no externs) and `textures_image.zig`
  (allocator-driven).  Examples that only need `Fade`/`Tint`/
  `Lerp` etc. pay nothing for the image surface.
- The `extern fn malloc/calloc/free` declarations in textures.zig
  exist for raylib parity but sit awkwardly with Zig's
  allocator philosophy.  Phase 12 target: rewire image fns to
  take `Allocator` as first arg, drop the libc externs entirely.
  This cleans up the `runtime.js` `env: { malloc: ... }` stubs
  too.
- `getRandomValue` is referenced by textures' noise generators
  but isn't in our zimr-side `core.zig` yet — currently stubbed
  in JS.  Should be a 4-line LCG in `core.zig` as a quick add.

### Session N+2 (text.zig lift)
- **The lifted `text.zig` already implements the dual-API
  pattern from this notes file**: top half is Zig-native
  (allocator-aware, slice-based, error-returning); bottom half
  is the C-ABI compatibility shim (raylib-compatible, static
  buffers).  This is exactly the Phase 12 target — text.zig
  serves as the canonical example.  Other modules (textures,
  shapes) should follow this pattern in Phase 12: add a
  Zig-native top half above the existing C-ABI exports.
- `nextCodepoint` returning `{codepoint=0x3F, bytes=1}` on empty
  input is a raylib convention to keep callers loop-safe.  In
  the Zig API, this should be `?DecodedCodepoint` returning null
  on empty input — eliminates the magic sentinel.
- `getCodepointNext` (C-ABI shim) takes a `[*:0]const u8`
  null-terminated string and writes byte count via an out-param
  pointer.  Zig API uses `[]const u8` slice + struct return
  with explicit fields — strictly better.  Already done in this
  file's Zig top half.
- The string utilities lifted (upper/lower/snake/camel/replace/
  split/join/find/parse) all take an explicit `Allocator` and
  return error unions — already idiomatic Zig.  **No
  ziggification work needed for Phase 12** beyond making them
  the default API surface.
- `pascal()`/`camel()` only split on `_`, not whitespace.  This
  matches the way these functions are typically used (converting
  identifiers between conventions, not natural language).  Kept
  the lifted behavior; documented in tests.

### Session N+3 (default font + Zig wasm-linker discovery)
- **Major discovery:** Zig's wasm linker treats undecorated
  `extern fn foo()` declarations as `env.foo` *imports* (env
  namespace) and treats `pub export fn foo()` as *exports*
  (wasm exports table).  These two tables don't unify — even
  if both definitions are linked into the same wasm, the
  extern-fn callsite generates an env import while the export
  fn generates an export entry, and at instantiation the env
  import has no JS-side binding so the wasm fails to load.

  Diagnosed when `text.zig`'s `extern fn getFontDefault` failed
  to resolve against `font_default.zig`'s
  `pub export fn getFontDefault`.  Fix: replace `extern fn`
  with a direct Zig-level `@import` of the providing module.

  **Phase 12 implication:** the lifted-from-zray modules
  (textures.zig, text.zig, shapes.zig, models.zig) all use
  `extern fn` declarations to reach into other modules' exports.
  This pattern is wrong for our pure-Zig setup.  Phase 12
  cleanup: audit all `extern fn` declarations across the
  codebase and convert internal cross-module calls to `@import`.
  Keep `extern fn` only for genuine JS imports
  (`extern "dom" fn`, `extern "webgl" fn`) and libc-style
  allocators that we plan to keep as ABI surface.

- **Host-test side effect:** converting `extern fn unloadTexture`
  in text.zig to `@import("rlgl_gpu.zig")` pulls rlgl_gpu's
  transitive `web/dom.zig` + `web/gl.zig` into the host-test
  build, which fail to compile (they declare
  `extern "dom" fn ...` and `extern "webgl" fn ...` requiring
  PIC).  Workaround: comptime-gate the import using
  `builtin.target.cpu.arch.isWasm()`, with host tests linking
  against test-binary-defined stubs via custom-named externs
  like `_zimr_test_getFontDefault`.

  Phase 12 cleaner solution: make the wasm-only modules
  (web/dom, web/gl) use `comptime` checks at the top to
  fall back to no-op stubs on non-wasm targets, so transitive
  imports just compile away.  Removes the need for per-test
  comptime gates everywhere.

- **Default font init pattern:** `font_default.zig` allocates
  its 64 KB scratch atlas in BSS rather than via an allocator.
  Phase 12 should accept an `Allocator` parameter and free the
  scratch buffer after upload (it's only needed during init).
  Saves 64 KB of permanent memory per zimr instance.

- **Lazy-init pattern works well:** `getFontDefault` checks a
  `loaded` flag and inits on first call.  Compatible with DCE
  (the whole module is stripped if no text drawing happens) AND
  zero-cost for examples that don't use text.  Phase 12 should
  preserve this pattern.

### Session N+4 (models lift + cube3d example)
- **The env-import problem is now systemic.**  Lifting models.zig
  surfaced 13 more `extern fn` declarations: rlgl GPU helpers
  (`rlGetShaderIdDefault`, `rlUnloadVertexArray`, etc.), libc
  allocators (`malloc`/`calloc`/`free`), and cross-module helpers
  (`uploadMesh`, `loadImageColors`, `unloadShader`).  All of these
  emit `env.<name>` imports in the wasm even when DCE strips the
  function bodies.

  Triaged into three handling categories:
  1. **rlgl externs** — lives in rlgl/rlgl_gpu.  In wasm, ideally
     converted to `@import` calls; in host tests, gated.  For now
     stubbed in JS env table (cube3d's draw paths don't actually
     trigger them).
  2. **libc allocators** — KEEP as `extern fn`.  These are real
     env imports we'll always need until we wire a wasm-side
     allocator.  JS stubs warn-and-return-null.
  3. **cross-module helpers** (`unloadShader`, `loadImageColors`,
     etc.) — should be converted to `@import` calls in Phase 12.
     For now, JS env stubs.

  The runtime.js + smoke.ts env tables now have ~12 stubs;
  Phase 12 audit should reduce that to ~4 (the libc fns + maybe
  `getRandomValue` until we add an LCG to core.zig).

- **`models.zig` cleanup partial:** I replaced the
  `const rl = struct { extern fn ... }` block with direct
  `@import("rlgl.zig")` calls (227 call-site rewrites).  The
  remaining 13 standalone extern fn decls scattered through the
  file weren't worth the per-call rewrite this session — Phase
  12 will batch them.

- **DCE works really well:** adding models.zig (1440 LOC) +
  font_default.zig (256 LOC) to the codebase changes basic/rtt/
  shader wasm sizes by 0 bytes.  Each example pays only for what
  it actually references.  This is a big endorsement of the
  module-per-file structure — Phase 12 should preserve it.

- **3D demo just works:** `examples/cube3d.zig` is 115 LOC.
  Sets up a perspective + look-at view manually (no `Camera3D`
  wrapper yet — Phase 11 cleanup), draws a 20×20 grid, a
  spinning textured cube + wireframe overlay, a reference
  sphere, and a HUD `angle: NN.N°` text line.  Smoke verifies
  3050 GL calls/60 frames flow through the full rmodels →
  rlgl → WebGL2 chain.  This is meaningful end-to-end coverage
  of the whole stack we've built.

### Session N+5 (Phase-12-prep extern fn audit)
- **Codebase-wide audit completed.**  44 `extern fn` declarations
  identified across shapes/text/textures/models.  24 eliminated
  (55% reduction); remaining 20 fall into clean categories:
    - 6 libc allocators (KEEP — until wasm allocator wired)
    - 2 not-yet-implemented Zig (uploadMesh, unloadShader)
    - 5 rlgl_gpu wrappers (need comptime-gate, Phase 12 proper)
    - 2 image-color helpers (DCE-strippable; only consumer is
      genMeshHeightmap which no example uses)
    - 1 getRandomValue (4-line LCG TODO in core.zig)
    - 1 host-test indirection (`_zimr_test_getFontDefault`)
    - 3 misc kept-for-DCE-safety

- **Easy wins worked exactly as predicted.**  Replacing
  `const rl = struct { extern fn ... }` blocks with
  `const rl = @import("rlgl.zig")` removed 16 declarations from
  shapes.zig (8) + textures.zig (7+1) + text.zig (4) plus 4
  test-stub blocks (shapes_test, text_test, textures_test,
  models_test partial).  rlgl.zig is pure-CPU so this works
  on both host and wasm targets without comptime gating.

- **Wasm import table didn't shrink.**  A surprise — the env
  imports in cube3d.wasm (12) and keys.wasm (4) are the same
  before and after.  The conversions removed declarations that
  Zig was already resolving correctly through normal linkage;
  they hadn't been leaking to the env table.  The remaining
  env imports (libc + rlgl_gpu wrappers + uploadMesh etc.) are
  the *real* unresolved externs, untouched by this session.
  Phase 12 cleanup of those needs the comptime-gate trick we
  developed for `getFontDefault`.

- **The cleanup pays compounding dividends.**  Future lifted
  modules (raudio, the rest of rmodels) won't add to the env
  stub list as long as they follow the new pattern of
  `@import("rlgl.zig")` for cross-module rlgl calls.  This is
  the prophylactic value of doing the audit before more lifts.

- **Test-stub burden dropped substantially.**  Each test file
  used to manually re-export ~10 rlgl pub-fn stubs to satisfy
  the linker.  After audit: shapes_test, text_test, textures_test,
  models_test all dropped these blocks — 50+ lines of test
  boilerplate gone, and any test bug caused by stub-vs-real
  divergence is now impossible (because the test links against
  the real rlgl.zig directly).

### Session N+6 (rlgl tail + comptime-gate cleanup)
- **rlgl tail: 21 state setters added to rlgl_gpu.zig.**
  Includes the high-value ones cube3d wanted (`rlEnableDepthTest`
  / `rlDisableDepthTest`), full back-face culling control
  (`rlEnableBackfaceCulling`/`rlDisableBackfaceCulling`/
  `rlSetCullFace`), depth-mask control, color-blend toggling,
  scissor (`rlEnableScissorTest`/`rlScissor`), line width.
  Plus stubs for `rlEnableWireMode` etc. which require
  `glPolygonMode` (desktop GL only — no-op on WebGL2 with a
  doc note).  Each setter is a 1-3 line GL wrapper.

- **Default-resource accessors implemented for real.**
  `rlGetTextureIdDefault` / `rlGetShaderIdDefault` /
  `rlGetShaderLocsDefault` were `extern fn` placeholders;
  this session ported them as proper `pub export fn` that
  read rlgl module state.  Same for `rlUnloadVertexArray` /
  `rlUnloadVertexBuffer` (2-line `gl.deleteVertexArray` /
  `gl.deleteBuffer` wrappers).

- **Comptime-gate pattern formalized.**  The 6 default-resource
  accessors and unload helpers in models.zig were the cleanest
  candidates for the comptime-gate cleanup pattern from text.zig.
  Pattern:
  ```zig
  const builtin = @import("builtin");
  const is_wasm = builtin.target.cpu.arch.isWasm();
  fn rlGetShaderIdDefault() c_uint {
      if (comptime is_wasm)
          return @import("rlgl_gpu.zig").rlGetShaderIdDefault();
      return _zimr_test_rlGetShaderIdDefault();
  }
  extern fn _zimr_test_rlGetShaderIdDefault() callconv(.c) c_uint;
  ```
  Host tests provide `_zimr_test_*` exports; wasm uses direct
  Zig linkage.  Verbose but type-safe and DCE-correct.

- **Wasm env imports actually shrank this time.**  cube3d went
  from 12 → 7 env imports.  The 5 eliminated are exactly the
  rlgl_gpu functions converted via comptime gate.  Remaining 7
  are: libc malloc/calloc/free, not-yet-Zig getRandomValue +
  uploadMesh + unloadShader + loadImageColors.

- **JS env stub table simplified to 8 entries.**  Down from 16
  at the start of Session N+5.  All remaining stubs are
  legitimately needed (libc + not-yet-Zig fns).  This is the
  cleanest the env table has looked.

- **DCE behavior unchanged.**  basic/rtt/shader still 0 env
  imports; the new state-setters didn't bloat them.  Wasm sizes
  grew ~1 KB across the board — the rlgl_gpu module body
  (which now has the default-resource accessors) gets pulled
  in by cube3d's loadMaterialDefault path.  Tiny price for a
  much cleaner architecture.

- **Pattern is repeatable.**  The same comptime-gate trick
  applies to the remaining 4 stubs (getRandomValue, uploadMesh,
  unloadShader, loadImageColors) once we have Zig-side
  implementations — Phase 11 work.

### Session N+7 (Camera3D wrapper — beginMode3D / endMode3D)
- **Phase 8 nudged forward.**  Created `src/camera.zig` (220 LOC,
  10 fns) implementing raylib's `BeginMode3D`/`EndMode3D` pattern
  plus 2D camera mode plus screen↔world projection helpers.
  Composed entirely from existing rlgl + raymath primitives —
  no new GL state, no new extern fns.  The 6-step BeginMode3D
  contract (flush batch → push projection → set perspective/
  ortho → switch to modelview → multiply by look-at → enable
  depth) is mirrored exactly so any raylib code Just Works.

- **cube3d.zig dropped 28 LOC of boilerplate.**  115 → 87 LOC.
  The manual perspective + matrix-stack setup was the textbook
  "first thing every 3D example needs" — now it's a 4-line
  Camera3D struct + `beginMode3D(cam)` + `endMode3D()`.  Same
  exact GL call count (3170/60 frames) confirms the wrapper
  does identical work.  Future 3D examples won't need to know
  the rlgl matrix internals at all.

- **Comptime-gate pattern reused for the third time.**  camera.zig
  needs to call rlgl_gpu's `rlEnableDepthTest` etc., which would
  pull in web/dom + web/gl on host tests.  Same fix as text.zig
  (Session N+3) and models.zig (Session N+6): three local
  wrapper fns that comptime-gate the @import("rlgl_gpu.zig").
  Pattern is becoming routine — should be extracted into a
  helper module in Phase 12.

  Sketch for Phase 12:
  ```zig
  // src/rlgl_gpu_fwd.zig — gateway to rlgl_gpu, no-op on host.
  const builtin = @import("builtin");
  const is_wasm = builtin.target.cpu.arch.isWasm();
  pub fn rlEnableDepthTest() void {
      if (comptime is_wasm) @import("rlgl_gpu.zig").rlEnableDepthTest();
  }
  // ... etc for every rlgl_gpu fn we use cross-module
  ```
  Then consumers do `const gpu = @import("rlgl_gpu_fwd.zig");
  gpu.rlEnableDepthTest();` instead of writing the comptime
  gate inline.  Removes ~50 LOC of repetition.

- **Camera2D round-trips correctly.**  Tests verify
  `getScreenToWorld2D(getWorldToScreen2D(p, cam), cam) ≈ p`
  for identity, zoom+offset, and rotated camera configurations.
  This is the kind of test that would catch a sign-flip or
  matrix-order bug instantly — and we got the math right on
  first try.  Credit goes to lifting from raylib's reference
  implementation rather than reinventing.

- **No new env imports.**  cube3d's import table is still
  exactly 7 entries (libc + 4 not-yet-Zig fns).  The wrapper
  is pure transitive composition.

- **DCE behaviour holds.**  basic/rtt/shader/keys wasm sizes
  unchanged to the byte despite adding 220 LOC of new module
  code.  cube3d grew by 5 KB (the wrapper body that's actually
  reachable).  This is the cleanest possible kind of feature
  addition: zero cost where unused.

- **getCameraMatrix (3D look-at) tests are interesting.**  The
  view matrix structure is hard to predict without computing
  it by hand — the column-major OpenGL convention plus the
  -Z-forward + Y-up convention plus the look-at construction
  means even "camera at origin looking forward" doesn't give
  pure identity.  Tests focus on structural properties (the
  3×3 rotation block being an isometry, the translation column
  being non-zero for off-origin cameras) rather than exact
  matrix values.  Phase 12 should consider whether to test the
  underlying `matrixLookAt` more thoroughly in raymath_test.zig
  instead of testing it indirectly via getCameraMatrix.

### Session N+8 (PNG decoder — `loadImage` keystone)
- **Pure-Zig PNG decoder, end-to-end.**  ~280 LOC in `src/png.zig`.
  Targets 8-bit grayscale / grayscale+alpha / RGB / RGBA (color
  types 0, 2, 4, 6), all 5 PNG filter types (None, Sub, Up,
  Average, Paeth), no Adam7 interlace.  Output is normalized to
  RGBA8 regardless of source format so the default GL shader
  Just Works.

- **`std.compress.flate` is excellent.**  PNG IDAT data is zlib-
  framed DEFLATE; the new (Zig 0.16) `std.compress.flate.Decompress`
  with the `.zlib` container handles it in 5 lines:
  ```zig
  var reader = std.Io.Reader.fixed(input);
  var writer = std.Io.Writer.fixed(output);
  var d: std.compress.flate.Decompress = .init(&reader, .zlib, &.{});
  _ = d.reader.streamRemaining(&writer) catch ...;
  ```
  Zero allocations beyond the writer's output buffer.

- **9 host tests in png_test.zig** with three hand-crafted PNGs
  (4×4 RGBA, 2×2 grayscale, 2×2 RGB) generated via Python
  zlib + struct (no PIL dependency).  Total embedded test
  data: 226 bytes.

- **`examples/png_demo.zig` (6th example).**  Embeds a 32×32
  smiley PNG via `@embedFile`, decodes it, uploads to GPU,
  draws 4 tiled copies at 4× zoom with different tints
  (white / sky / amber / pink).  Smoke captures
  `[2] PNG: decoded 32x32, GPU tex id 5`.

- **`@embedFile` requires module exposure.**  Zig 0.16 doesn't
  let `@embedFile` reach paths outside the package's source
  directory.  Workaround in build.zig:
  ```zig
  exe_mod.addAnonymousImport("smiley_png", .{
      .root_source_file = b.path("assets/smiley.png"),
  });
  ```
  Then `@embedFile("smiley_png")` works.

- **DCE is *still* perfect.**  Adding 280 LOC of PNG decoder +
  pulling in `std.compress.flate` (which is substantial)
  changed basic/rtt/shader/keys/cube3d sizes by exactly zero
  bytes.  png_demo is 127 KB.

- **Allocator question for Phase 12.**  png.decode takes an
  Allocator and returns `Image{ pixels: []u8, ... }` with a
  `deinit` method.  This is the canonical zig-idiomatic shape
  — much better than raylib's malloc/free behind the scenes.

### Session N+9 (`loadImage(path)` from disk via async fetch)
- **Asset loading from URL works end-to-end.**  Three new pieces:
  `src/web/fetch.zig` (~110 LOC), `js_fetch_*` handlers in
  `dom.js` (~70 LOC), and `png.loadAsync`/`pollLoad`/`releaseLoad`
  on top.  `examples/load_image_demo.zig` (155 LOC) demos a
  per-frame state machine that fetches `assets/smiley.png`,
  decodes it once bytes arrive, uploads to GPU, then renders.

- **The big design choice was sync vs. async.**  raylib's
  `LoadImage(path)` is synchronous — it blocks until the file
  is read.  In single-threaded wasm this is impossible: once
  Zig is running, the browser's network stack is starved.
  The honest, web-native API is async-only:
  ```zig
  const handle = png.loadAsync(allocator, "foo.png");
  // poll handle each frame until .ok or .failed
  ```
  No `loadSync` even as a convenience.

- **Wasm-side allocation hooks are the key plumbing.**  Two
  new `pub export fn`s in zimr.zig:
  ```zig
  export fn zimr_fetch_alloc(size: usize) usize { ... }
  export fn zimr_fetch_free(ptr: usize, size: usize) void { ... }
  ```
  JS calls these when a fetch resolves; the bytes are written
  directly into wasm linear memory.  Total size cost:
  ~350 bytes added to every wasm's export table.

- **HTTP-served path = WASI alternative for free.**  Going via
  `fetch()` rather than WASI `fd_open`/`fd_read` means assets
  are reachable from the same dev server that serves the wasm
  itself.

### Session N+10 (Phase 12 cleanup — extract `wasm_fwd.zig`)
- **The comptime-gate pattern is now extracted.**  4 modules
  (text.zig, models.zig, camera.zig, font_default access) used
  to inline `if (comptime is_wasm) @import("rlgl_gpu.zig").foo()
  else _zimr_test_foo()` blocks.  Now centralized in a single
  `src/wasm_fwd.zig` (95 LOC) that handles all cross-module
  calls into wasm-only modules (rlgl_gpu + font_default).

- **Inline gates: 4 modules → 0.**  Pre-cleanup, inline
  comptime-gate blocks appeared 14 times.  Post-cleanup:
  every callsite goes through `const gpu = @import("wasm_fwd.zig")`.

- **`_zimr_test_*` externs eliminated.**  models.zig had 3;
  text.zig had 1.  All gone — wasm_fwd.zig provides default
  no-op / zero-init host fallbacks inline.  Tests don't need
  to provide stubs anymore.

- **Wasm sizes unchanged to the byte.**  Pure refactor, no DCE
  perturbation.  243/243 host tests + 7/7 smoke still green.

- **Module-name choice.**  Started as `rlgl_gpu_fwd.zig`,
  realized `font_default.zig` has the same wasm-only
  constraint.  Renamed to `wasm_fwd.zig` for honesty.

### Session N+11 (Conway's Game of Life — multi-subsystem demo)
- **8th example: `examples/life.zig`** (175 LOC).  Conway's
  Game of Life on an 80×45 grid running at 60 fps with a
  user-tunable simulation step rate (1-9 keys = geometric
  speed control from 0.5s/gen to ~2ms/gen).  Mouse drag paints
  cells; space pauses; c clears; r randomizes.  Seeded with
  the classic glider pattern at startup.

- **Why this matters: integration test.**  Most prior examples
  exercise one subsystem at a time.  Life touches shapes +
  input + text + frame timing + a sizable BSS state struct
  (7 KB for two grids) all at once.  Smoke verified the whole
  stack composed without surprises: 1550 GL calls/60 frames.

- **rlgl's immediate-mode batching scales.**  At max alive
  density this draws ~3600 `drawRectangle` calls per frame;
  rlgl collapses these into a handful of GL drawArrays calls
  per batch.  First example to stress-test the batching, and
  it works exactly as designed.

- **DCE held: every other wasm size unchanged.**  life.wasm
  is 141 KB — slightly larger than the other shape-using
  examples because of its mouse-paint + speed-control input
  handling code.

### Session N+12 (Wasm-side libc allocator — Phase 12 task #14)
- **`src/allocator.zig` (~115 LOC) + `src/libc.zig` (10-line shim).**
  Real libc-shape `malloc/calloc/realloc/free` backed by
  `std.heap.wasm_allocator`.  Header-prefix size tracking
  (16-byte header keeping the user pointer 16-byte aligned).
  Each `pub export fn` comptime-gates: returns null/no-op on
  host since `std.heap.wasm_allocator` is wasm-only.

- **The wasm-linker dance again.**  Adding `pub export fn malloc`
  to allocator.zig wasn't enough — the `extern fn malloc` decls
  in models/textures/text still got resolved as env imports.
  Fix: `src/libc.zig` shim re-exports as `pub const malloc =
  allocator_mod.malloc;`.  Consumers do `const libc =
  @import("libc.zig"); libc.malloc(n)`.  Calls resolve at the
  Zig level, no env-import detour.

- **3 modules converted, 7 extern declarations eliminated.**
  models.zig (3), textures.zig (3), text.zig (1).  Test stubs
  also gone: ~36 lines across models_test.zig, text_test.zig,
  textures_test.zig.

- **JS env stubs gone.**  runtime.js and smoke.ts both had
  4-line libc-stub blocks.  Both deleted.

- **Phase 12 task list:** task 14 ✅ → task 13 (extern-fn audit)
  now genuinely 100%.  Ready for the actual ziggification
  API design pass.

### Session N+13 (Phase 12.0 — C-ABI decoration removal)
- **The big "remove the C scaffolding" pass.**  386 fn declarations
  across 14 source files lost `pub export fn` → `pub fn` and
  dropped `callconv(.c)`.  Allowlist of preserved exports:
  exactly 11 fns (zimr_frame/init, zimr_fetch_alloc/free, the
  7 input_push_*, plus per-example main + auto _initialize).

- **Wasm size impact: huge.**  Before vs after:
  ```
  basic           75914 → 63705   −16%
  cube3d         138173 → 75341   −45%  (−63 KB)
  keys           137303 → 69123   −50%
  life           141886 → 67588   −52%
  png_demo       127907 → 79272   −38%
  ```
  Removing the export decorations let DCE actually strip unused
  fns; before, the ~300 PascalCase exports were keeping their
  bodies live regardless of reachability.

- **Env imports → 0 across all 8 examples.**  Before: cube3d
  had 4 (uploadMesh, unloadShader, loadImageColors,
  getRandomValue), others had 1 (getRandomValue).  Now: zero.
  The extern declarations are still in the source as latent
  code; 12.7 will port them.  Dropped the corresponding JS
  env stubs in runtime.js + smoke.ts.

- **Wasm export tables: ~300 → 14 entries per binary.**

- **243/243 + 8/8 still green.**  Pure scaffolding-removal —
  identical GL call counts.

- **PHASE_12_PLAN.md rewritten** to reflect "go full Zig"
  approach.  9 sub-phases (12.0–12.8) with explicit
  deliverables for each.  C-ABI is being deleted, not preserved
  as a parallel layer.

### Session N+14 (Phase 12.1 — Vector2/3/4 + Color + Rectangle + Matrix functions)
- **Type-namespaced functions across all 6 math types** in a
  single pass: Vector2 (18 fns), Vector3 (19 fns), Vector4 (11
  fns), Matrix (13 fns), Color (10 fns), Rectangle (10 fns).
  78 fns total, ~480 LOC of method bodies.

- **Style decision: pragmatic, not OOP.**  Mid-session, the
  user pushed back on framing this as "method APIs".  Resolved
  to: Zig supports both call styles from the same declaration
  (`Vector2.add(a, b)` and `a.add(b)` produce identical
  compiled code).  Don't pick a winner.  PHASE_12_PLAN.md got
  a new "Style guide" section codifying:
  - **Symmetric ops** → namespaced reads more honestly
  - **Receiver-feel ops** → method syntax matches Zig stdlib
  - **Examples won't be uniform** — both styles can appear
    in the same file
  No code change needed; only framing/docs.

- **Notable design choices:**
  - `Vector{2,3,4}.normalize()` of zero returns zero, not NaN
  - `Vector3.cross` is right-handed (anti-commutativity tested)
  - `Matrix` math fns delegate to `raymath.zig` via lazy
    `@import("raymath.zig")` inside fn bodies — avoids the
    types↔raymath circular import
  - `Matrix.translate(m, x, y, z)` left-multiplies: matches
    "the new translation happens first in the chain"

- **`src/types_test.zig` (~330 LOC, 38 tests)** with explicit
  regression test that both call styles work:
  ```zig
  test "method-style calls produce same result as namespaced calls" {
      try expectEqual(Vector2.add(a, b), a.add(b));
  }
  ```

- **One example migrated:** `png_demo.zig` uses
  `Rectangle.init(...)` and `Vector2.zero()`.  Same GL call
  count.

- **281/281 + 8/8 still green.**  +38 type tests on top of the
  243 baseline.

### Session N+15 (Phase 12.2 — Resource type APIs)
- **8 resource types gain `isValid` + `deinit` + per-type fns.**
  Image (deinit, isValid, flip×2, rotate×2, crop), Texture
  (deinit, isValid, draw + 4 draw variants), RenderTexture
  (isValid, deinit cascading to attachments), Font (isValid
  inline check, deinit), Mesh (deinit, boundingBox), Shader
  (deinit), Material (isValid, deinit, setTexture), Model
  (isValid, deinit, boundingBox).  ~25 fns, ~220 LOC.

- **Method-style preferred per the Style guide.**  Receiver-feel
  ops (`tex.deinit()`, `tex.draw(x, y, tint)`) match Zig stdlib
  idioms (`file.close()`, `list.append(item)`).  The namespaced
  form (`Texture.deinit(tex)`) still works.

- **wasm_fwd.zig forwarders added.**  `rlUnloadFramebuffer` and
  `rlUnloadShaderProgram` now have comptime-gated forwarders so
  RenderTexture/Shader `deinit` fns compile cleanly on host.
  Same shape as the existing `rlUnloadTexture` forwarder.

- **`Image.toTexture()` deferred.**  Would need a Zig-side
  `loadTextureFromImage` wrapping rlgl_gpu upload with format
  handling.  Phase 12.7 will surface it; for now examples
  upload directly via `rlgl_gpu.rlLoadTexture`.

- **9 new lifecycle/predicate tests** in types_test.zig:
  zero-init isValid contracts, zero-id deinit no-ops.  Tests
  that need GPU/file I/O are covered by smoke instead of host.

- **One example migrated:** `load_image_demo.zig` now uses
  `tex.drawPro(src, dst, ...)` method-style + `Rectangle.init()`
  + `Vector2.zero()`.  Same GL count, +52 bytes wasm.

- **290/290 + 8/8 still green.**

### Session N+16 (Phase 12.3 — Error unions)
- **`src/errors.zig` (~30 LOC) — unified `LoadError` set.**
  Composes `png.Error || fetch.Error || error{ GpuUploadFailed,
  OutOfMemory }`.  Per-module sets stay defined in their own
  files (`png.Error`, `fetch.Error`) for in-module use; this
  file re-exports the union plus aliases for narrower handling.

- **Tightened `png.LoadStatus.failed: anyerror → LoadError`.**
  Was a TODO from the original png.zig.  Type-compatible because
  both png.Error and fetch.Error flow into LoadError.

- **`zimr.zig` exports synchronous loaders for embedded data:**
  `loadImageFromMemory(gpa, bytes) LoadError!Image` and
  `loadTextureFromMemory(gpa, bytes) LoadError!Texture2D`.
  The latter does decode + upload + intermediate-buffer cleanup
  in one call.  Both work in any context — wasm and host tests.

- **No synchronous URL-based loader.**  Wasm can't block on
  I/O.  The two-phase png.loadAsync + pollLoad API stays as
  the URL path.

- **`src/errors_test.zig` (~110 LOC, 7 tests):** LoadError set
  composition; loadImageFromMemory happy path; bad signature
  → InvalidSignature; truncated → InvalidIHDR; empty →
  UnexpectedEnd; try-composition through outer fn.

- **One example migrated:** `png_demo.zig` — 28 lines of
  decode-then-upload-then-store-pixel-buffer boilerplate
  collapsed to one `try z.loadTextureFromMemory(...)` call.
  +122 bytes wasm.

- **297/297 + 8/8 still green.**

### Session N+17 (Phase 12.5 research — `std.Io` adoption plan)
- **No code changes this session.**  Pure research + plan revision.
  User asked: "Study Zig's new IO philosophy in the context of
  async loading and wasm.  Make a plan for passing an io object
  to any fn that touches filesystem or nondeterministic things.
  Brainstorm, find the most clever idea."

- **What I found.**  Zig 0.16 introduces `std.Io` — Andrew
  Kelley's capability handle for *all* nondeterministic ops.
  Vtable: async/await/concurrent/cancel, group ops, futexWait/
  Wake, now/clockResolution/sleep, random/randomSecure, dir/
  file ops, generic operate dispatch.  Verified directly in
  `/opt/zig/lib/std/Io.zig`.

- **Stdlib ships:** Io.Threaded, Io.Evented (fiber-based,
  io_uring/kqueue/Dispatch backends).  **No Io.Wasm or browser
  implementation.**  Per LWN: "A third kind of Io, one that is
  compatible with WebAssembly, is planned (although...
  implementing it depends on some other new language features)."

- **The function-signature rule:**
  - Pure fn → no Io, no Allocator
  - Allocates → takes Allocator
  - Touches time/IO/RNG/async → takes *Io
  - Function signatures = audit trail

- **The clever idea I landed on: Frame IS an Io.**  Most engines
  have Frame and Io as separate things → awkward two-arg
  signatures.  zimr's design fuses them.  Frame implements the
  std.Io vtable but with frame-scoped semantics:
  - `frame.now()` returns frame-start timestamp (deterministic
    per-tick regardless of update fn duration)
  - `frame.arena` per-tick allocator
  - `frame.input` immutable input snapshot for the frame
  - `frame.app_io` reaches App-scoped Io for ops outliving
    the frame

  Most update fns become `fn update(f: *Frame, state: *S)` —
  one arg covers time + I/O + RNG + memory.  Function
  signatures self-document.

- **`BrowserIo`** vtable mapping designed:
  ```
  now(clock)        → performance.now() / Date.now()
  sleep(timeout)    → setTimeout + per-frame yield
  random(buffer)    → crypto.getRandomValues()
  async(fn, args)   → sync execution at first; future Promise glue
  concurrent(...)   → ConcurrentError.Unsupported
  dirOpenDir/Stat   → maps to fetch (read-only "filesystem")
  futexWait/Wake    → no-op (single-threaded)
  ```
  Existing fetch.zig two-phase API is already Io.Evented-shaped
  — we have most of the infrastructure.

- **Three Io flavors planned:**
  - BrowserIo — production, browser APIs
  - MockIo — unit tests, deterministic time/RNG, in-memory assets
  - LoggingIo — wraps any Io, logs every call

- **PHASE_12_PLAN.md revised:** sub-phase 12.5 reframed from
  "Frame + Input redesign" to "Capability passing".  ~150 lines
  of new plan covering std.Io background, the Frame-IS-an-Io
  idea, BrowserIo design, three Io flavors, function-signature
  audit pass.  12.6 updated with resolved std.process.Init
  question (doesn't exist; we define InitArgs).

- **Possible upstream contribution.**  zimr's BrowserIo could
  be a useful proof-of-concept for stdlib's planned Io.Wasm
  once language features land.  Worth raising on ziggit once
  solid.

### Session N+18 (Phase 12.4 — PascalCase → camelCase rename)
- **Anticlimactic.**  Audit revealed only 33 PascalCase fns
  out of 625.  We've been mostly camelCase since the original
  raylib port phases.  Holdouts in core.zig (window/timing,
  14 fns) and input.zig (keyboard/mouse, 19 fns).

- **Mechanical pass via Python script.**  Explicit symbol map
  of 33 entries, whole-word replacement across src/ and
  examples/.  257 replacements across 13 files.

- **One naming collision.**  core.zig's `traceLog(level,
  comptime fmt, args)` formatter collided with the renamed
  `TraceLog(level, msg_ptr, msg_len)` ptr/len form.  Resolved
  by renaming the raw form to `traceLogRaw`.  Two test sites
  manually updated.

- **Zero codegen impact.**  Wasm sizes bit-identical pre/post-
  rename across all 8 examples.  Pure cosmetic.

- **297/297 + 8/8 still green.**

### Session N+19 (Port-completeness audit, no code)
- Mechanical comparison: 274/600 raylib RLAPI fns ported = 45%.
  Excluding 178 out-of-scope (audio/file-I/O/window/touch/automation/
  VR), in-scope = 274/422 = 65%.
- Audit appended as section 9 of PORTING_PLAN.md with 3-tier
  sequencing (Tier A: Random/Cursor/GetKeyName/Camera ; Tier B:
  Shader/Mesh/DrawModel ; Tier C: Image manip / Drawing modes / TTF).

### Session N+20–22 (Tier A + Shader API)
- **Random** lifted from zray's xorshift32 implementation into
  `core.zig`: `setRandomSeed`/`getRandomValue`/`loadRandomSequence`/
  `unloadRandomSequence`.  Retired the `getRandomValue` env import.
- **Cursor** show/hide/enable/disable lifted from zray's
  `platform_web.zig`, ported `emscripten_run_script` calls to direct
  dom.js handlers (`js_set_cursor_style`/`js_request_pointer_lock`/
  etc).  4 new JS handlers, 4 new Zig externs in dom.zig, 6 new fns
  in input.zig.
- **Camera helpers + drivers** ported from zray's camera.zig: 11
  fns including `updateCamera`/`updateCameraPro` plus
  `getCameraForward`/`Up`/`Right` and the rotation primitives
  (`cameraYaw`/`Pitch`/`Roll`).  ~210 LOC.
- **Shader API** lifted from zray's shaders.zig: 10 fns
  (`loadShaderFromMemory`/`unloadShader`/`getShaderLocation`/
  `setShaderValue*`/`isShaderValid`).  Retargeted the rlgl externs
  through wasm_fwd.zig forwarders.  ~200 LOC.

### Session N+23 (uploadMesh + rlVertex* primitives)
- **13 rlVertex* primitives** added to rlgl_gpu.zig:
  `rlLoadVertexBuffer`/`rlLoadVertexArray`/`rlEnableVertexBuffer`/
  `rlSetVertexAttribute`/`rlEnableVertexAttribute`/
  `rlDrawVertexArray`/`rlDrawVertexArrayElements` etc.  Each is a
  thin wrapper over WebGL2.
- **`uploadMesh` ported** from raylib's C `UploadMesh` (~120 LOC).
  Allocates VAO + per-attribute VBOs, sets up `glVertexAttribPointer`
  for the default shader's attribute layout, stores GL ids back
  into mesh.vaoId / mesh.vboId.
- Retired the `uploadMesh` env import.

### Session N+24 (Last externs + parametric mesh gens + drawMesh + drawModel)
- **`loadImageColors`/`unloadImageColors`** ported — covers 7
  pixel formats (GRAYSCALE, GRAY_ALPHA, R5G5B5A1, R5G6B5, R4G4B4A4,
  R8G8B8, R8G8B8A8).  Retired both externs.
- **`rlTextureParameters`** (last extern!) — discovered we already
  had it in rlgl_gpu.zig (~line 599), just wasn't in wasm_fwd.
  Added forwarder, retired the textures.zig extern.
- **🎯 ZERO non-platform externs.**  `grep -E "^extern fn " src/*.zig`
  returns empty.  Every C-shaped placeholder is now Zig.
- **Parametric mesh generators** (Sphere, HemiSphere, Cylinder,
  Cone, Torus, Knot) — ~600 LOC of trefoil parametric surfaces with
  flat per-face normals.  Replaces `par_shapes.h` dep entirely.
- **`drawMesh`/`drawModel`/`drawModelEx`/`loadModelFromMesh`**
  ported from rmodels.c — ~250 + 7 + 30 + 40 LOC.  Full MVP-
  matrix-driven shader pipeline with diffuse color uniform, texture
  binding, optional indexed draw.
- **297/297 host + 8/8 smoke still green** throughout.

### Session N+25 (Pure-Zig dependency survey, no code changes)
- User dropped 8 candidate ziggified replacements for raylib's C
  deps with the instruction "we will eventually convert 100%
  including the dependencies."  Cloned + audited all reachable
  ones (Codeberg blocked — used web_fetch instead).

- **Bonus discovery: `zigimg/zigimg`** — pure-Zig 18-format image
  library (PNG/JPEG/BMP/TGA/QOI/GIF/PCX/etc) with own DEFLATE.
  Could replace our hand-rolled `src/png.zig` and add 17 more
  formats.

- **Pivotal finding: tier-3 verdict for audio.**  Both `zaudio`
  and `prime31/zig-miniaudio` are **Zig wrappers around C
  miniaudio** — they pull in `miniaudio.c` as a C TU.  Violates
  the no-C goal.  Wrote them off.

- **Replacement strategy for audio: Web Audio API directly.**
  Browsers already have full mixing/panning/filters/decoding via
  `decodeAudioData`.  zimr just needs ~200 LOC of bindings, NOT a
  port of miniaudio.

- **Tier-1 picks:** andrewrk/TrueType, zigimg, bgourlie/zrectpack,
  mgord9518/perlin-zig, kooparse/zgltf — all pure-Zig, all mature
  enough to adopt.

- **DEPENDENCIES_PLAN.md (~300 LOC) created** with per-dep
  verdicts, license + wasm32-wasi todos, phase mapping (13.0
  TTF, 13.1 atlas, 13.2 zigimg, 13.3 perlin, 13.4 zgltf, 14.0
  audio, 14.1 embedded decode).

- **Adoption pattern decided:** `b.dependency` pinning in
  `build.zig.zon` over vendoring; thin `src/<name>.zig` shim
  wraps each dep so swapping doesn't churn the codebase.

- **No code changes this session.**  297/297 + 8/8 unchanged.

### Session N+26 (100-step roadmap)
- **User asked for the best 100-step plan** for the rest of the
  work, with dependency adoption interleaved — "we can decide to
  port dependencies immediately as we port the binding part."
  Also: "we don't need to make it perfectly ziggified just yet,
  unless it is easy and not risky."

- **Wrote `ROADMAP.md` (~600 LOC)** structuring the next ~100 steps
  into 12 sections:
  - §1 (1–20): Coverage holes — close in-scope from 65% → ~92%.
    Easy wins first (getKeyName, drawCapsule, codepoints), then
    image manipulation gaps, drawing modes, gamepad mappings.
  - §2 (21–32): Examples + smoke tests — exercise everything
    Phase 12 added (drawMesh, shaders, RNG, cursor, camera).
    Move to `examples/raylib_ports/` + `examples/zimr/` split.
  - §3 (33–38): Documentation — README rewrite for outsiders,
    getting-started, architecture doc, migration-from-raylib.
  - §4 (39–48): std.Io adoption — the design call I deferred in
    Phase 12.5.  Spike both Path A (Frame and Io separate) and
    Path B (Frame IS an Io), pick winner from the call sites.
  - §5 (49–55): Allocator-explicit pass — `z.init(.{ .gpa, .io,
    .window })`, kill module-level state.
  - §6 (56–63): TrueType + atlas — first dep adoption
    (`andrewrk/TrueType`, `bgourlie/zrectpack`).  ~300 LOC for
    `loadFontEx`.
  - §7 (64–70): zigimg adoption — JPEG/BMP/TGA/QOI/GIF support.
    Decide whether to keep our `src/png.zig` after the bench.
  - §8 (71–80): glTF + 3D models — `kooparse/zgltf` adoption,
    skinning + animations.  The big 3D content unlock.
  - §9 (81–88): Audio via Web Audio API — explicitly NOT miniaudio
    (rejected per the no-C goal).  ~200 LOC of WebAudio bindings
    let the browser handle decoding/mixing.  Optional pure-Zig
    `zig-wav` + `zig-mp3` for embedded clips.
  - §10 (89–92): Perlin + procedural textures — `mgord9518/
    perlin-zig` adoption.
  - §11 (93–100): Hardening + first release — context loss handling,
    touch input, perf pass, CI, v0.1 ship + Ziggit/Reddit announce.
  - §12 (post-v0.1): WebGPU migration, native target, mobile,
    physics, networking — long-horizon vista, no commitment.

- **Cross-cut structure:**
  - Each step has difficulty marker (🟢/🟡/🔴) and `[L]` for ones
    targeting >400 LOC (sub-split candidates).
  - Section-end milestones every ~10 steps to validate progress.
  - Risk register with specific mitigations for the seven biggest
    risks (zigimg size, TTF quality, zgltf gaps, std.Io blast
    radius, audio timing, MP3 perf, mobile input).
  - Re-evaluation checkpoints at steps 50, 80, 100 — explicitly
    asks "is this still fun, are users adopting, did stdlib's Io.
    Wasm land?"

- **Working principles formalized:**
  1. No step left half-done (tests + smoke green at end).
  2. Docs-as-you-go.
  3. Ship over polish (v0.1 = "useful and honest" not "perfect").
  4. Dep adoption checklist (license, wasm32-wasi build, shim
     wrapper, DEPENDENCIES_PLAN entry).
  5. Allocator passing is non-negotiable.
  6. The 100-step number is aspirational, not contractual.

- **Updated PHASE_12_PLAN.md closure** — sub-phases 12.0-12.4 now
  marked ✅ done, 12.5/12.6 deferred to ROADMAP.md §4.  Cross-
  references DEPENDENCIES_PLAN.md and ROADMAP.md.

- **Recommended starting point: Step 1 (`getKeyName`).**  30 LOC,
  builds momentum, immediate visible payoff (keys example can show
  human-readable names in its overlay).

- **No code changes this session.**  297/297 tests + 8/8 smoke
  unchanged.  Project state is the same as end of N+25.
- **User dropped a curated list of 8 ziggified replacements for
  raylib's C deps** and asked me to clone, study, and write a meaty
  plan.  Goal: "we will eventually convert 100% including the
  dependencies, I am not kidding about the no C goal."

- **Cloned + audited.**  Ran `git clone --depth=1` against each
  GitHub source.  Codeberg blocked by the env's network allowlist —
  used `web_fetch` and `web_search` instead for codeberg-hosted
  ones (`andrewrk/TrueType`, `~asibahi/tatfi`, `logo/zaudio`).
  Bonus discovery: `zigimg/zigimg` — pure-Zig 18-format image
  library (PNG/JPEG/BMP/TGA/QOI/GIF/PCX/etc) with its own pure-Zig
  DEFLATE.

- **The big finding: tier-3 verdict for audio.**  The user-listed
  "zaudio" and "prime31/zig-miniaudio" are **both** Zig wrappers
  around C miniaudio — they pull in `miniaudio.c` as a C TU.  This
  violates the no-C goal we just confirmed.  Wrote them off in the
  plan as ❌ Reject.

- **Replacement strategy for audio: Web Audio API directly.**
  Browsers already have full mixing, panning, filters, format
  decoding via `decodeAudioData`.  zimr just needs:
  - `audio_context.zig` — bindings
  - `audio_buffer.zig` — buffer creation + play
  - Optional pure-Zig `zig-wav` + `coolirisme/zig-mp3` for *embedded*
    decode where browser's async API is awkward.

- **Tier-1 picks for adoption:**
  - `andrewrk/TrueType` — single-file stb_truetype port, by Zig's
    BDFL.  Codepoint→glyph + rasterization + kerning.  Drop-in.
    Confirmed via web_fetch of the README.
  - `zigimg` — could replace our `src/png.zig` + add 17 other
    formats.  Heavyweight (~10K LOC) but maintained by Mach team.
  - `bgourlie/zrectpack` — 2× faster than stb_rect_pack (per their
    benchmarks), ~250 LOC.  For TTF atlas baking.
  - `mgord9518/perlin-zig` — 200 LOC, comptime permutation table.
    For `genImagePerlinNoise`.
  - `kooparse/zgltf` — full glTF 2.0 + GLB parser (verified the GLB
    magic-number check).  ~2400 LOC.

- **Tier-2 picks (caveats):**
  - `tatfi` (sourcehut, MPL 2.0) — ttf-parser port, parsing only,
    no rasterizer.  Worse fit than andrewrk/TrueType for our
    "parse + rasterize" need.
  - `coolirisme/zig-mp3` — pure-Zig MP3 decoder, but **reportedly
    slow**.  Use cautiously, profile before committing.
  - `veloscillator/zig-wav` — small WAV decoder.  Fine.
  - `ikskuh/zig-qoi` — already absorbed by zigimg per zigimg's
    README, so we'd skip in favor of zigimg.

- **DEPENDENCIES_PLAN.md (NEW, ~300 LOC) created** with full per-
  dep verdicts, license check todos, wasm32-wasi compatibility
  todos, and a phase mapping showing when each adoption unlocks
  what:
  - Phase 13.0 → andrewrk/TrueType for custom fonts
  - Phase 13.1 → zrectpack for TTF atlas baking
  - Phase 13.2 → zigimg for JPEG/BMP/TGA/GIF/QOI
  - Phase 13.3 → perlin-zig for noise gen
  - Phase 13.4 → zgltf for model loading
  - Phase 14.0 → Web Audio bindings
  - Phase 14.1 → zig-wav + zig-mp3 for embedded decode

- **PORTING_PLAN.md Tier C item 10 updated** to recommend
  andrewrk/TrueType adoption instead of "vendor stb_truetype.h or
  skip."  Cross-references the new DEPENDENCIES_PLAN.md.

- **The pivotal architecture decision documented:** for adopted
  deps, prefer `b.dependency()` pinning in `build.zig.zon` over
  vendoring, but keep vendoring as the fallback if upstream goes
  dormant.  Always wrap each dep in a thin `src/<name>.zig` shim
  that re-exports just the surface zimr uses, so swapping
  implementations doesn't churn the rest of the codebase.

- **Re-examined our own hand-rolled `src/png.zig`** in light of
  zigimg's existence.  Verdict: keep it for now.  It's tightly
  integrated with our two-phase async fetch path, and zigimg is
  fundamentally synchronous-stream-based.  Migration when we want
  JPEG/etc.  The migration path: add zigimg as a build dep
  alongside our png.zig, with zigimg handling non-PNG paths only.

- **Open questions logged:**
  - License audit for every adopted dep before pinning.
  - Wasm32-wasi compatibility verification for each dep.
  - Whether to maintain a `vendor/` directory or just zon-pin.

- **No code changes this session.**  297/297 tests + 8/8 smoke
  unchanged.
- **User asked: what's left to port?**  They want to delay the
  Io migration (12.5) until they're more confident "Frame is an
  Io" is the right design.  Reasonable — the easier "finish
  the port" work is good filler in the meantime.

- **Mechanical comparison: every `RLAPI` decl in
  `raylib_src/raylib.h` vs every `pub fn` in `src/`.**  raylib
  uses PascalCase, we use camelCase — matched by lowering the
  first letter.  Python-script audit categorized each fn by
  raylib's section comment headers.

- **Headline: 274 of 600 raylib fns ported = 45%.**  But that's
  misleading because ~178 are explicitly out-of-scope:
  - 66 audio (Phase 9, user-deferred)
  - 47 file I/O misc (desktop-shaped — `FileExists`, etc.)
  - 42 window-state queries (mostly N/A in browser)
  - 13 touch/gestures (phone-specific)
  - 8 automation events
  - 2 VR

  **Excluding the 178 out-of-scope: 274 of 422 in-scope = 65%.**

- **Sections fully ported:** Collision3D, Shapes draw, Shapes
  collide, Text draw, Text info, Texture draw.

- **Sections 80%+ done with minor gaps:** 3D shapes (DrawCapsule
  missing), Keyboard (GetKeyName missing), Material (LoadMaterials
  missing), Image draw (ImageDraw + 3 text variants missing),
  Codepoints (LoadCodepoints + LoadUTF8 missing).

- **Significant gaps:**
  - Shader API (0/10) — `LoadShader`, `SetShaderValue`*, etc.
    rlgl_gpu has the GL infra; we just need the public layer.
  - Mesh upload + GenMesh family — `uploadMesh` is still env-
    imported; `GenMeshCone/Cylinder/Sphere/Knot` not yet ported.
  - DrawModel / DrawMesh — depends on the above.
  - Cursor (0/6) — show/hide cursor.
  - Random (0/4) — `getRandomValue` is env-imported.
  - Texture/Image load — most file-based loaders missing
    (deliberate: in wasm we use `loadXxxFromMemory` instead).

- **Audit appended to PORTING_PLAN.md as section 9** — full
  per-section breakdown plus a 3-tier sequencing recommendation:
  - Tier A (~200 LOC, 1 session): Random, Cursor, GetKeyName,
    Camera update.  Easy wins.
  - Tier B (~600 LOC, 2-3 sessions): Shader API, Mesh upload +
    GenMesh family, DrawModel/DrawMesh.  Real game features.
  - Tier C (~400 LOC, 1-2 sessions): Image manipulation gaps,
    Drawing modes, optional TTF parser for custom fonts.

- **Six `extern fn` declarations remain in source** (currently
  DCE'd in all examples): `uploadMesh`, `unloadShader`,
  `loadImageColors`, `unloadImageColors` (in models.zig);
  `rlTextureParameters`, `getRandomValue` (in textures.zig).
  Tier A + Tier B retire 5 of these; the 6th
  (`unloadImageColors`) is a 1-line wrapper around libc.free.
  After that, `grep -E "^extern fn" src/*.zig` returns nothing.

- **No code changes this session.**  Pure audit + planning
  appendix.  297/297 tests + 8/8 smoke unchanged.

- **Recommended start: Tier A.**  Random + Cursor + GetKeyName
  + Camera update is ~200 LOC, all four would land cleanly in
  one session, takes the Phase 12.5 work-pressure off without
  forcing a design decision on Frame-as-Io.
- **Anticlimactic.**  When I audited the codebase before
  starting, only 33 `pub fn` decls remained PascalCase out of
  625.  We've been mostly camelCase since the original raylib
  port phases — the holdouts were concentrated in core.zig
  (window/timing API, 14 fns) and input.zig (keyboard/mouse
  query API, 19 fns).

- **Mechanical pass via Python script** (`/tmp/rename_pascal.py`).
  Explicit symbol map of 33 entries, whole-word replacement
  across `src/` and `examples/`.  Whole-word matching (negative
  lookahead/behind for `[A-Za-z0-9_]`) prevented false positives
  on type names that share prefixes.

- **257 replacements across 13 files.**  Biggest delta in
  `input_test.zig` (94 calls) and `core_test.zig` (54 calls).
  Examples touched: keys (21), life (8), load_image_demo (2),
  png_demo (2), cube3d (1).

- **One naming collision.**  `core.zig` already had a Zig-style
  `traceLog(level, comptime fmt, args)` formatter wrapper.
  Renaming `TraceLog(level, msg_ptr, msg_len)` (raylib-shape
  ptr/len) to `traceLog` collided with it.  Resolved by
  renaming the raw form to `traceLogRaw` — its only consumer
  is potential future JS-driven errors (currently unused).
  Two test call sites manually updated to use `traceLogRaw`.

- **Zero codegen impact.**  Wasm sizes bit-identical
  pre/post-rename across all 8 examples (basic 63705, cube3d
  75341, etc. — all unchanged to the byte).  This is the
  cleanest possible refactor: pure rename, no behavior change,
  no size delta.

- **297/297 host + 8/8 smoke still green.**

- **Phase 12.4 done.**  The codebase is now uniformly Zig-
  idiomatic in naming.  Ready for the big 12.5 capability-
  passing migration without naming drift complications.
- **No code changes this session.**  Pure research + plan revision.
  User asked: "Study Zig's new IO philosophy in the context of
  async loading and wasm.  Make a plan for passing an io object
  to any fn that touches filesystem or nondeterministic things.
  Brainstorm, find the most clever idea."

- **What I found.**  Zig 0.16 (the version we're on) introduces
  `std.Io` — Andrew Kelley's capability handle for *all*
  nondeterministic ops.  Vtable includes:
  - `async`, `await`, `concurrent`, `cancel` — async dispatch
  - `groupAsync/Await/Cancel` — task groups
  - `now(clock)`, `clockResolution`, `sleep(timeout)` — time
  - `random(buffer)`, `randomSecure(buffer)` — randomness
  - `futexWait/Wake` — synchronization
  - `dirOpenDir/Stat/...` — filesystem
  - `operate(op)` — generic syscall dispatch
  Verified the shape directly in `/opt/zig/lib/std/Io.zig`.

- **Stdlib ships these implementations:**
  `Io.Threaded` (sync ops + threadpool for async),
  `Io.Evented` (fiber-based, with Uring/Kqueue/Dispatch backends).
  **No `Io.Wasm` or browser implementation in stdlib.**  Per LWN's
  coverage of Kelley's design: "A third kind of Io, one that is
  compatible with WebAssembly, is planned (although... implementing
  it depends on some other new language features)."

- **The function-signature rule that emerges:**
  - **Pure fn** — no special params
  - **Allocates** — takes `Allocator`
  - **Touches time / I/O / RNG / async** — takes `*Io`
  - Function signatures = audit trail.  Scanning `pub fn` decls
    tells you precisely which code paths are nondeterministic
    without reading the bodies.  Same idea as Haskell's
    `IO` monad type but at the value level, not the type level.

- **The clever idea I landed on.**  Game engines normally have
  Frame (per-tick state) and Io (capability) as two separate
  things, leading to awkward two-arg signatures
  (`fn update(f: *Frame, io: *Io, state: *S)`).  zimr's design
  fuses them: **Frame IS an Io**.  Same vtable, but scoped to
  one tick:
  - `frame.now()` → returns the *frame's start timestamp*, not
    real wall-clock.  Per-frame animations are deterministic
    regardless of how long the update fn takes.
  - `frame.arena` → per-tick allocator, auto-cleared at end-
    of-tick.
  - `frame.input` → input snapshot, immutable for the frame.
  - `frame.app_io` → reference to the App-scoped Io for ops
    that outlive the frame (long async asset loads, audio).

  In the 99% case, `fn update(f: *Frame, state: *S)` is enough
  for everything.  Only long-lived async ops (asset loading
  spanning many frames) reach to `f.app_io`.  Function
  signature becomes self-documenting:
  `fn render(f: *Frame, ...)` says "I might draw, read time,
  RNG, allocate temporarily."  `fn add(a: Vec2, b: Vec2) Vec2`
  says "pure math."  No comment needed.

- **`BrowserIo` — zimr's wasm-targeting Io provider.**  The
  vtable maps to browser primitives:
  ```
  std.Io slot       BrowserIo mapping
  ─────────────────────────────────────────────────────────────
  now(clock)        performance.now() / Date.now()
  sleep(timeout)    setTimeout + per-frame yield token
  random(buffer)    crypto.getRandomValues(buffer)
  randomSecure      same — browser RNG is cryptographic
  async(fn, args)   sync execution at first; future Promise glue
  concurrent(...)   ConcurrentError.Unsupported (no threads)
  dirOpenDir/Stat   maps to fetch (read-only "filesystem")
  futexWait/Wake    no-op (single-threaded)
  ```

  Critically, our existing `fetch.zig` two-phase API
  (`fetch.start(url)` → `fetch.poll(handle)`) is fundamentally
  Io.Evented-shaped — non-blocking start, poll for completion.
  We have most of the infrastructure already; 12.5 wires it
  through the std.Io vtable.

- **Three Io flavors planned for testing:**
  - **`BrowserIo`** (production) — backed by browser APIs
  - **`MockIo`** (unit tests) — deterministic time advances by
    explicit `mock.advance(seconds)`; deterministic RNG seed;
    in-memory "fetched" assets keyed by URL.  Makes game logic
    unit-testable without a browser.
  - **`LoggingIo`** (debug) — wraps any Io and logs every call.
    Combined with deterministic replay against MockIo, enables
    bug-reproduction workflows.

- **PHASE_12_PLAN.md revised:** sub-phase 12.5 reframed from
  "Frame + Input redesign" to "Capability passing: `Io` and
  `Frame` redesign".  ~150 lines of new plan content covering:
  - `std.Io` background + the function-signature rule
  - Status of stdlib's wasm Io (planned but not yet there)
  - The Frame-IS-an-Io clever idea
  - BrowserIo vtable mapping table
  - Three Io flavors for testing
  - Function signature audit (mechanical pass categorizing
    every existing pub fn)
  - Strategy + LOC + risks
  - 12.6 (App entry) updated to reflect resolved std.process.Init
    question (it doesn't exist; user constructs InitArgs locally).

- **One open question added to the list:** whether to upstream
  `BrowserIo` to stdlib eventually.  Worth raising on ziggit
  once it's solid — could be a useful proof-of-concept for
  stdlib's planned `Io.Wasm` once the language features land.

- **Why this matters.**  The Io adoption is the linchpin for
  proper testability and for the project being Zig-idiomatic.
  Without it, zimr's API would be a Zig-syntax wrapper around
  a raylib mental model.  With it, zimr is genuinely Zig-shaped
  software that happens to run in browsers, with a real story
  for unit testing, deterministic replay, and eventual
  upstream contribution.

- **Next session: Phase 12.4 (PascalCase rename) recommended
  before tackling 12.5.**  12.5 is the biggest design piece in
  the project and benefits from the codebase being in its
  final naming form before the migration.
- **`src/errors.zig` (~30 LOC) — unified `LoadError` set.**
  Composes `png_mod.Error || fetch_mod.Error || error{
  GpuUploadFailed, OutOfMemory }` into a single set callers can
  `try` against.  Per-module sets stay defined in their own
  files (`png.Error`, `fetch.Error`) for in-module use; this
  file re-exports the union plus `errors.PngError` and
  `errors.FetchError` aliases for code that wants narrower
  handling.

- **Tightened `png.LoadStatus.failed: anyerror` →
  `LoadError`.**  Was a TODO from the original png.zig design.
  Type-compatible because both `png.Error` and `fetch.Error`
  flow into `LoadError`, so existing call sites keep working
  without changes.  Now caller code can pattern-match the
  failure variant against the typed error set instead of
  switching on `anyerror`.

- **`zimr.zig` exports two synchronous loaders for embedded
  data:**
  - `loadImageFromMemory(gpa, bytes) LoadError!Image` —
    PNG bytes → CPU `Image`.  Caller releases pixels via
    `image.deinit()`.
  - `loadTextureFromMemory(gpa, bytes) LoadError!Texture2D`
    — PNG bytes → GPU texture.  Frees the intermediate CPU
    pixel buffer before returning, so caller only needs to
    `tex.deinit()`.  On host targets returns
    `LoadError.GpuUploadFailed` since the wasm GPU upload
    path isn't reachable.

- **No synchronous URL-based loader.**  The plan called for a
  blocking `z.loadTexture(allocator, path)`, but wasm can't
  block on I/O.  The two-phase `png.loadAsync(allocator, url)
  → png.pollLoad(handle)` API stays as the URL path.  The
  embedded-data loaders cover the `@embedFile("smiley.png")`
  pattern that most game assets follow anyway.

- **`src/errors_test.zig` (NEW, ~110 LOC, 7 tests).**
  - LoadError set composition (PngError variants assignable
    into LoadError; GpuUploadFailed + OutOfMemory present)
  - loadImageFromMemory happy path (4×4 RGBA test PNG)
  - Bad signature → `InvalidSignature`
  - Truncated PNG → `InvalidIHDR` (refines what error fires
    at which truncation point — UnexpectedEnd needs a
    truncation mid-chunk-header)
  - Empty input → `UnexpectedEnd`
  - `try` composition: error from inner load propagates
    through outer fn cleanly

- **One example migrated:** `png_demo.zig`.  Was 28 lines of
  decode-then-upload-then-store-pixel-buffer boilerplate.
  Replaced with one `try z.loadTextureFromMemory(allocator,
  bytes)` call.  AppState lost an unused `smiley_pixels: []u8`
  field along the way (the texture upload no longer needs CPU
  buffer to outlive it because `loadTextureFromMemory` frees
  the buffer internally before returning).

- **png_demo wasm size: +122 bytes.**  Slight cost from the
  new `loadTextureFromMemory` having a few extra checks vs.
  the manual hot path.  Worth it for the much cleaner caller
  code.

- **297/297 host + 8/8 smoke green.**  +7 new error tests on
  top of the 290 baseline.  Same exact GL call counts on every
  example.

- **What this session did NOT do (vs the plan):**
  - The plan called for "every loader updated to error union
    form" — but most existing loaders are NOT URL-aware syn-
    chronous things; they're the GPU-side path (`rlLoadTexture`
    etc.) which doesn't fail except for OOM / bad params.  The
    sentinel-returning fns there (id=0 on failure) are actually
    a fine convention for the wasm-linker-facing layer.  The
    high-level entry points are what need error unions, and
    those are the new `loadXxxFromMemory` fns added here.
  - `LoadError` doesn't include `FileNotFound` because there's
    no "file" abstraction in wasm — disk access goes through
    fetch which already has `NotFound`.

- **Phase 12.3 done.**  Top-level loaders now return error
  unions.  The error set is tight enough to handle in app code
  (`catch |err| switch (err) { ... }`).  Ready for 12.4
  (PascalCase → camelCase rename) or 12.5 (Frame redesign).
- **Type-namespaced functions for the 8 resource types.**
  Image, Texture (alias Texture2D), RenderTexture, Font, Mesh,
  Shader, Material, Model.  Each gains `isValid` (predicate),
  `deinit` (lifecycle), and where applicable: drawing fns
  (Texture), in-place mutators (Image), or accessors (Mesh/
  Model bounding box).

- **Texture (~70 LOC, 7 fns).**  `deinit` (no-op on zero-id;
  routes through wasm_fwd.rlUnloadTexture so host tests
  compile).  `isValid`.  Five drawing fns: `draw(x, y, tint)`
  (integer coords), `drawAt(pos, tint)` (Vector2), `drawEx(pos,
  rotation, scale, tint)`, `drawRec(source, pos, tint)`,
  `drawPro(source, dest, origin, rotation, tint)` — the
  most general form.  All thin wrappers over existing free
  fns in textures.zig.  Both call styles compile identically
  (`tex.draw(x, y, tint)` and `Texture.draw(tex, x, y, tint)`).

- **Image (~50 LOC, 7 fns).**  `deinit` (frees CPU pixel
  buffer via libc.free, routes through textures.unloadImage).
  `isValid`.  Mutators: `flipVertical`, `flipHorizontal`,
  `rotateCW`, `rotateCCW`, `crop` — all take `*Image` and
  modify in place.  `toTexture()` deliberately deferred (would
  need a Zig-side `loadTextureFromImage` wrapping the rlgl_gpu
  upload path; currently examples do this manually with
  `rlgl_gpu.rlLoadTexture(pixels, w, h, format, mipmaps)`).
  Phase 12.7 will surface this properly.

- **RenderTexture (~25 LOC, 2 fns).**  `isValid`, `deinit`.
  The `deinit` routes through `wasm_fwd.rlUnloadFramebuffer`
  (newly added — same comptime-gating pattern as the existing
  `rlUnloadTexture` forwarder), then cascades to
  `target.texture.deinit()` and `target.depth.deinit()` to
  release the color/depth attachments.

- **Font (~20 LOC, 2 fns).**  `isValid` is an inline check
  (`glyphCount > 0 and texture.id != 0`), no need to round-
  trip through text.zig.  `deinit` calls
  `text.zig.unloadFont`.

- **Mesh (~10 LOC, 2 fns).**  `deinit` routes through
  `models.unloadMesh` (frees CPU vertex arrays + GPU VAO/VBOs).
  `boundingBox` returns the AABB of the vertex data.

- **Shader (~15 LOC, 1 fn).**  `deinit` routes through
  `wasm_fwd.rlUnloadShaderProgram` (also newly added) plus
  `libc.free(shader.locs)` for the per-shader locations array.
  Skipped a `setUniform` family because raylib's surface there
  is a maze of size-suffix overloads; that's a future
  refactor.

- **Material (~15 LOC, 3 fns).**  `isValid`, `deinit`,
  `setTexture(map_type, texture)` for setting individual
  material map slots (uses the `MaterialMapIndex` enum values).

- **Model (~15 LOC, 3 fns).**  `isValid`, `deinit`,
  `boundingBox` (returns AABB across all meshes — does NOT
  apply the model's transform; that's caller responsibility).

- **wasm_fwd.zig forwarders added (Session N+10's pattern).**
  `rlUnloadFramebuffer` and `rlUnloadShaderProgram` now have
  comptime-gated forwarders.  Same shape as the existing
  `rlUnloadTexture`: they delegate to rlgl_gpu on wasm and
  no-op on host.  The Texture/RenderTexture/Shader `deinit`
  fns route through these so types_test.zig compiles cleanly
  on the host target where rlgl_gpu pulls in web/dom +
  web/gl.

- **Tests added (9 new in types_test.zig):**
  - `Texture.isValid: zero-init is invalid`
  - `Texture.deinit: zero-id is no-op (doesn't crash)`
  - `Texture2D is an alias for Texture`
  - `Image.isValid: zero-init is invalid`
  - `Image.deinit: null data is no-op`
  - `RenderTexture.isValid: zero-init is invalid`
  - `RenderTexture.deinit: zero-id is no-op`
  - `Font.isValid: zero-init is invalid` (also tests:
    glyphCount>0 alone isn't enough, texture.id must be set too)
  - `Material.isValid: zero-init is invalid`
  - Mesh.deinit on zero-init NOT tested on host because
    unloadMesh→rlgl_gpu pulls in webgl externs.  Smoke
    covers the wasm path.

- **One example migrated as proof:** `load_image_demo.zig`
  had a 7-line texture struct + 6-line Rectangle struct +
  `drawTexturePro(tex, src, dst, .{ .x = 0, .y = 0 }, ...)`
  call.  Replaced with `Rectangle.init(...)` × 2,
  `Vector2.zero()`, and the method-style
  `tex.drawPro(src, dst, ...)`.  Same exact GL call count
  (1439/60 frames).  +52 bytes wasm size — codegen artifact
  of the slightly different IR shape, not a real cost.

- **Design choice — method-style preferred for these.**  Per
  the Style guide added in N+14: receiver-feel ops favor
  method syntax.  `tex.deinit()` reads like
  `defer file.close()` (Zig stdlib idiom).  `tex.draw(x, y,
  tint)` mirrors `list.append(item)`.  The namespaced form
  (`Texture.deinit(tex)`) is still a no-syntax-error legal
  call — just less idiomatic for these.

- **290/290 host tests + 8/8 smoke green.**  +9 new types
  tests on top of the 281 baseline.  Wasm sizes unchanged
  ±60 bytes per binary.

- **Phase 12.2 effectively done.**  Resource types have the
  lifecycle + drawing API needed for examples to drop the
  free-fn forms when they're rewritten in Phase 12.8.  Could
  add more (texture update from CPU pixels, image scaling
  variants, shader uniform setters) but those are
  incremental — better to move to 12.3 (error unions) which
  blocks 12.8.
- **First slice of the type-namespaced function API.**  Per the
  plan's recommendation to ship 12.1 incrementally per-type, this
  session covered all 6 math types in a single pass: Vector2,
  Vector3, Vector4, Matrix, Color, Rectangle.  The implementations
  are short enough (most fns are 1-3 lines wrapping existing
  raymath free fns or trivial inline math) that splitting across
  multiple sessions wasn't worth it.

- **Style decision: pragmatic, not OOP.**  Mid-session, the user
  pushed back on framing this as "method APIs":
  > "I dont have anything against doing Vec2.add(a, b) instead of
  > a.add(b). I dont need object orientation and methods. Those
  > are overrated."
  Then later:
  > "Hum, it is true that methods look nice on frame... you know
  > what, i am not sure anymore. Free functions are awesome, but
  > now we need to be pragmatic"
  Resolved to: **Zig supports both call styles from the same
  declaration**.  Don't pick a winner.  Use whichever reads better
  per call site.  PHASE_12_PLAN.md got a new "Style guide"
  section codifying:
  - **Symmetric ops** (`Vector2.add(a, b)`, `lerp`, `intersection`)
    → namespaced reads more honestly
  - **Receiver-feel ops** (`tex.deinit()`, `f.clear(color)`,
    `list.append(item)`) → method syntax matches Zig stdlib idioms
  - **Examples won't be uniform** — both styles can appear in the
    same file
  Code didn't need to change: `pub fn add(a: T, b: T) T` declared
  inside a struct works both ways.  Only the framing/docs.

- **Vector2 (~80 LOC, 18 fns).**  Constructors: `init`, `zero`, `one`.
  Arithmetic: `add`, `sub`, `mul`, `div`, `scale`, `negate`.
  Geometry: `dot`, `lengthSq`, `length`, `distanceSq`, `distance`,
  `normalize`, `lerp`, `rotate`, `reflect`, `min`, `max`, `clamp`.

- **Vector3 (~110 LOC, 19 fns).**  Same constructors + arithmetic
  + geometry as Vector2.  Adds `cross` (right-handed),
  `project` (project onto another vector), `transform` (4×4
  matrix transform with implicit w=1).

- **Vector4 (~50 LOC, 11 fns).**  Constructors + arithmetic +
  `dot/lengthSq/length/normalize/lerp/transform`.  No reflect/
  cross/project — those don't have clean meanings for the full
  homogeneous case.

- **Matrix (~110 LOC, 13 fns).**  Constructors: `identity`,
  `translation`, `scaling`, `rotation`, `lookAt`, `perspective`,
  `ortho`.  Operations: `mul` (column-major: `a.mul(b) * v ==
  a * (b * v)`), `invert`, `transpose`, `determinant`, plus
  three convenience chainers (`translate`, `scale`, `rotate`)
  that left-multiply onto an existing matrix.  The functions
  delegate to `raymath.zig` via lazy `@import("raymath.zig")`
  inside the function body — avoids the types↔raymath circular
  import problem.

- **Color (~60 LOC, 10 fns).**  Constructors: `init`, `rgb`
  (alpha=255 shortcut), `hex` (0xRRGGBBAA).  Predicates:
  `equals`.  Conversion: `toInt` (round-trips with `hex`),
  `toFloats` ([4]f32 in 0..1).  Manipulation: `lerp`, `fade`
  (alpha-only), `brightness`.  HSV deferred.

- **Rectangle (~70 LOC, 10 fns).**  Constructors: `init`,
  `fromCorners` (top-left + size).  Accessors: `topLeft`,
  `topRight`, `bottomLeft`, `bottomRight`, `center`, `size`.
  Tests: `contains` (half-open inclusion — top-left
  inclusive, bottom-right exclusive), `overlaps` (commutative,
  touching ≠ overlap), `intersection` (returns null on
  disjoint).

- **Notable design choices:**
  - `Vector{2,3,4}.normalize()` of zero returns zero, not NaN.
    Safer for game code that often normalizes direction vectors
    that happen to be zero on a given frame.  Tests verify.
  - `Vector3.cross` is right-handed: `init(1,0,0).cross(.init(0,1,0))
    == .init(0,0,1)`.  Anti-commutativity also tested.
  - `Matrix.translate(m, x, y, z)` is *left*-multiply onto m,
    matching the convention "the new translation happens first
    in the chain."  i.e. `m.translate(x, y, z) =
    Matrix.translation(x, y, z).mul(m)`.

- **`src/types_test.zig` (NEW, ~330 LOC, 38 tests).**
  Constructor round-trips, arithmetic identities, geometric
  edge cases (normalize-of-zero, rotate-by-360, cross
  anti-commutativity), hex/toInt round-trip, lerp endpoint
  preservation, half-open containment convention, intersection
  nulls, identity-matrix invariants, transform composition.
  Plus 1 explicit regression test that **both call styles
  produce the same result**:
  ```zig
  test "method-style calls produce same result as namespaced calls" {
      const a = Vector2.init(3, 4);
      const b = Vector2.init(1, 2);
      try expectEqual(Vector2.add(a, b), a.add(b));
      try expectEqual(Vector2.length(a), a.length());
      try expectEqual(Vector2.dot(a, b), a.dot(b));
  }
  ```

- **One example migrated as proof:** `png_demo.zig` had two
  inline `Rectangle = .{ .x = 0, .y = 0, ... }` constructions
  that became `Rectangle.init(...)` calls, plus a
  `.{ .x = 0, .y = 0 }` that became `Vector2.zero()`.  Same
  exact GL call count (1439/60 frames) — pure ergonomics.

- **281/281 tests pass + 8/8 smoke unchanged.**  +38 new
  type-tests join the 243 baseline.  Wasm sizes unchanged
  (additive code, all DCE-stripped on examples that don't
  reference the new fns).

- **What's left for 12.1.**  Color HSV (currently free fns
  in textures.zig), Quaternion-specific ops (raymath has them).
  Both can wait until a real example needs them — Phase 12.2
  is the higher-priority next step.

- **Phase 12.1 effectively done.**  Could ship more methods
  later but the math foundation is solid enough for 12.2 to
  build on.
- **The big "remove the C scaffolding" pass.**  386 fn declarations
  across 14 source files lost their `pub export fn` →`pub fn`
  + dropped `callconv(.c)`.  The rationale: those decorations
  were inherited from the raylib-port phases when we mirrored
  the C ABI exactly.  But there's no actual C consumer — every
  one of those fns is called only from Zig (the examples or
  cross-module).

- **Allowlist of preserved exports — exactly 11 fns.**
  - Lifecycle: `zimr_frame`, `zimr_init`
  - Asset bridge: `zimr_fetch_alloc`, `zimr_fetch_free`
  - Input injectors: `input_push_char`, `input_push_key_down`,
    `input_push_key_up`, `input_push_mouse_button_down`,
    `input_push_mouse_button_up`, `input_push_mouse_move`,
    `input_push_mouse_wheel`
  - Plus per-example `main` (8 examples) and the auto-generated
    `_initialize`.
  - Total wasm export entries per binary: **14**.  Down from
    ~300 before this session.

- **Wasm size impact: huge.**  Before vs after release sizes:
  ```
  basic           75914 → 63705   −16%
  rtt             76445 → 65499   −14%
  shader          77274 → 66916   −13%
  cube3d         138173 → 75341   −45%  (−63 KB!)
  keys           137303 → 69123   −50%
  life           141886 → 67588   −52%
  png_demo       127907 → 79272   −38%
  load_image_demo 128874 → 80310  −38%
  ```
  The DCE behavior was correct before, but the export *declarations*
  themselves were forcing every PascalCase fn into the binary.
  Once they became `pub fn`, DCE could actually strip unused fns.
  This is bigger than the 5-10% I estimated in PHASE_12_PLAN.md
  — closer to 40-50% on shape/text/textures-using examples.

- **Env imports went to ZERO.**  Before:
  ```
  cube3d              4 (uploadMesh, unloadShader, loadImageColors, getRandomValue)
  keys/life/png_demo  1 (getRandomValue)
  load_image_demo     1
  basic/rtt/shader    0
  ```
  After: all 8 examples have 0 env imports.  Same DCE mechanism:
  the `extern fn uploadMesh` in models.zig was producing an env
  import only because the function it called transitively (via
  the C-ABI export chain) was being kept alive by export pressure.
  With that pressure gone, DCE strips the calling code paths
  before they reach the extern.  The extern declarations are
  still in the source as latent code — Phase 12.7 will port them
  to real Zig impls.

- **Dropped JS-side env stubs entirely.**  `runtime.js` and
  `tests/smoke.ts` both had ~12 lines of getRandomValue +
  uploadMesh + unloadShader + loadImageColors stubs.  All gone.
  If a future code path needs those externs, the wasm linker
  will surface a clean "import not satisfied" instantiation
  error — much better signal than runtime "[zimr] called — not
  wired" logs.

- **Zero semantic changes.**  243/243 host tests + 8/8 smoke
  still green.  Exact same GL call counts (1430/3170/1790/1550/
  1439/1439/3062/3184).  This is a pure scaffolding-removal
  refactor.

- **The ~45% size drop is the sleeper headline of the project.**
  The cube3d binary went from 138 KB to 75 KB.  Before this
  session, the C-ABI exports were carrying their full function
  bodies into every binary regardless of whether the example
  used them.  Even in release builds with ReleaseSmall.  Removing
  the export decorations made the linker free to delete what
  isn't reachable from `main` + the JS-callable allowlist.

- **Phase 12.0 done.  Ready for 12.1 (type method APIs).**
  Updated PHASE_12_PLAN.md to reflect the revised "go full Zig"
  approach — the C-ABI is being deleted, not preserved as a
  parallel layer.  Plan now has 9 sub-phases (12.0 through 12.8)
  with explicit deliverables for each.

- **Mechanical refactor tooling: Python script over sed.**  The
  conversion required matching `pub export fn FOO` and checking
  if FOO is in the allowlist before transforming.  That's not a
  pure regex job — needs a small bit of state.  Used a 60-line
  Python script.  Worth keeping for future similar passes
  (e.g. the PascalCase → camelCase rename in 12.4).
- **`src/allocator.zig` (~115 LOC) + `src/libc.zig` (10-line shim).**
  Real libc-shape `malloc/calloc/realloc/free` backed by
  `std.heap.wasm_allocator`.  Header-prefix size tracking
  (16-byte header keeping the user pointer 16-byte aligned —
  covers f64, f128, simd, struct layouts).  Each `pub export
  fn` comptime-gates: returns null/no-op on host (since
  `std.heap.wasm_allocator` is wasm-only).

- **The wasm-linker dance again.**  Just adding `pub export fn
  malloc` to a module imported by zimr.zig wasn't enough —
  the existing `extern fn malloc/calloc/free` declarations in
  models.zig, textures.zig, text.zig still got resolved by
  the wasm linker as env imports, defeating the wasm-side
  implementation.  Same systemic issue as the rlgl_gpu
  cross-module calls in Sessions N+3 / N+5 / N+10.

- **Fix: `src/libc.zig` shim.**  Tiny re-export module:
  ```zig
  const allocator_mod = @import("allocator.zig");
  pub const malloc = allocator_mod.malloc;
  pub const calloc = allocator_mod.calloc;
  pub const realloc = allocator_mod.realloc;
  pub const free = allocator_mod.free;
  ```
  Consumers do `const libc = @import("libc.zig"); libc.malloc(n)`.
  Calls resolve to the `pub export fn` definitions directly,
  no env-import detour.  This is the same pattern that fixed
  the rlgl extern problem in Session N+5 — generalized into a
  proper shim module since malloc/calloc/free have stable
  cross-module names.

- **Conversion: 3 modules, 7 extern declarations eliminated.**
  - `models.zig`: 3 externs (calloc, malloc, free) → libc import
  - `textures.zig`: 3 externs (malloc, free, calloc) → libc import
  - `text.zig`: 1 extern (free) → libc import
  - All call sites prefixed with `libc.` via sed pattern that
    excludes function definitions and `.foo()` patterns.

- **JS env stubs: gone.**  `runtime.js` and `tests/smoke.ts`
  both had 4-line libc-stub blocks (malloc/calloc/realloc/
  free).  Both deleted.  The runtime's env table is now
  precisely 4 entries (getRandomValue + uploadMesh +
  unloadShader + loadImageColors) — the not-yet-Zig
  raylib-parity functions, all DCE-stripped at the body level.

- **Env import audit (release wasm):**
  ```
  basic            0    (no change)
  rtt              0    (no change)
  shader           0    (no change)
  keys             4 → 1   (libc gone, getRandomValue remains)
  life             4 → 1
  png_demo         4 → 1
  load_image_demo  4 → 1
  cube3d           7 → 4   (libc gone; uploadMesh / unloadShader /
                            loadImageColors / getRandomValue remain)
  ```

- **Test stubs eliminated.**  models_test.zig, textures_test.zig,
  text_test.zig each had ~12 lines of `export fn malloc/calloc/
  free` stubs.  All gone — allocator.zig's `pub export fn`s
  with comptime-gated host fallback resolve at link time.
  Total ~36 lines of test-stub boilerplate removed across the
  three files.

- **Wasm size delta: small but real.**  +250-650 bytes for
  examples that transitively use libc (textures-using examples).
  basic/rtt/shader unchanged (no libc reference).  Trade is
  worth it: allocations now actually work where they used to
  return null, unblocking image generators, mesh generators,
  and any future code that expects malloc to be functional.

- **243/243 host + 8/8 smoke still green.**  Refactor
  preserved every existing test.  `genMesh*` paths now have
  real backing memory if anything ever calls them; smoke tests
  don't currently exercise this path.

- **Phase 12 task list update:**
  - Task 14 (wasm-side allocator): ☐ → ✅
  - Task 13 (extern-fn audit): now genuinely 100% — every
    cross-module extern between modules is gone except for
    the not-yet-Zig raylib-parity fns.
  - Remaining major Phase 12 prep work: nothing.  Ready for
    the actual ziggification API design pass.

- **The header layout, in case future me forgets:**
  ```
  |-- 16 bytes header --|------- user data -------|
  ^                     ^
  underlying ptr        returned ptr (16-byte aligned)
  ```
  Size stored in the LAST `usize` of the header (offset 12 on
  wasm32 since usize=u32, offset 8 on wasm64).  `free(p)` reads
  `p - sizeof(usize)`, computes the full slice as `(p - 16)
  [0 .. size + 16]`, and passes that to `wasm_allocator.free`.
  Realloc is malloc-then-memcpy-then-free — simpler than libc's
  in-place-grow semantics, and any caller that depends on
  in-place-grow is incorrect anyway.
- **8th example: `examples/life.zig`** (175 LOC).  Conway's
  Game of Life on an 80×45 grid running at 60 fps with a
  user-tunable simulation step rate (1-9 keys = geometric
  speed control from 0.5s/gen to ~2ms/gen).  Mouse drag paints
  cells; space pauses; c clears; r randomizes.  Seeded with
  the classic glider pattern at startup.

- **Why this matters: integration test.**  Most prior examples
  exercise one subsystem at a time (cube3d = 3D, png_demo =
  textures, keys = input).  Life touches shapes + input +
  text + frame timing + a sizable BSS-allocated state struct
  (7,200 bytes for two grids) all at once.  Smoke verified
  the whole stack composed without surprises: 1550 GL calls/
  60 frames, no traps, log lines came through normally.

- **Pattern: BSS state struct via `var state: AppState`.**
  Same shape as cube3d.zig and load_image_demo.zig.  The
  example takes ownership of its own state without going
  through any allocator.  Phase 12 will offer
  `init.gpa.create(AppState)` as the more zig-idiomatic
  alternative; for now the static-singleton pattern works
  well for examples where there's exactly one scene.

- **Throttled simulation, full-rate render.**  The simulation
  step runs at user-tunable rate (default 10 Hz); the render
  loop runs every frame at 60 Hz.  This is a clean general
  pattern that I'd extract into the docs for Phase 11
  (`step_interval` + `last_step_time` + `if (t -
  last_step_time >= step_interval)` is essentially a
  fixed-timestep loop).  Phase 12 might offer a `Frame.fixedStep`
  helper.

- **Direct grid manipulation without an allocator.**  The
  two grids (cur/next) are arrays in the AppState struct.
  No allocator needed.  Each frame iterates 80×45 = 3600 cells
  with a 9-cell neighbor scan = 32,400 array reads per step.
  Easily hits 60 Hz step rate in release.  Phase 12 might
  refactor into `Grid(W, H, T)` generic, but the explicit
  shape reads cleanly here.

- **Shapes API gets a real test.**  At max alive density,
  this draws ~3600 `drawRectangle` calls per frame.  rlgl's
  immediate-mode batching collapses these into ~6 GL
  drawArrays calls (one per ~600 quads given our 32K vertex
  budget).  Smoke at 1550 GL calls/60 frames = 26 GL calls
  per frame — most of those are the HUD text glyphs, not
  rectangles.  This is excellent behavior; previous examples
  hadn't stress-tested the batching.

- **DCE behavior held.**  Adding 175 LOC of new example +
  the `[GRID_W * GRID_H * 2]u8 = 7200 bytes` BSS allocation
  changed every other wasm size by 0 bytes.  life.wasm itself
  is 141 KB — slightly larger than the other examples
  because of the shapes-heavy code path + the BSS grids.

- **Cross-subsystem catch.**  No bugs found this session,
  but the integration showed our APIs work cohesively without
  awkward boundary issues.  Each subsystem (shapes/text/
  input/timing) integrated naturally with the others, which
  validates the per-module-export style we've been using.

- **Seedable RNG opportunity.**  The example uses a simple
  inline LCG in `nextRand`.  We've now seen this pattern
  twice (textures.genImageWhiteNoise stubs an LCG via the
  `getRandomValue` env import; this example inlines its own).
  Phase 12 should add `core.random` with proper Zig std
  Random integration — `std.Random.DefaultPrng` is in the
  stdlib already.
- **The comptime-gate pattern is now extracted.**  4 modules
  (text.zig, models.zig, camera.zig, font_default access) used
  to inline `if (comptime is_wasm) @import("rlgl_gpu.zig").foo()
  else _zimr_test_foo()` blocks.  Now centralized in a single
  `src/wasm_fwd.zig` (95 LOC) that handles all cross-module
  calls into wasm-only modules (rlgl_gpu + font_default).

- **Inline gates: 4 modules → 0.**  Pre-cleanup, inline
  comptime-gate blocks appeared 14 times across text.zig (1),
  models.zig (3 default-resource accessors + 3 unload helpers
  = 6), camera.zig (3 batch/depth helpers).  Post-cleanup:
  every callsite goes through `const gpu = @import("wasm_fwd.zig")`
  or `const wasm_fwd = @import("wasm_fwd.zig")`.

- **`_zimr_test_*` externs eliminated.**  models.zig had 3
  (`_zimr_test_rlGetShaderIdDefault` etc.); text.zig had 1
  (`_zimr_test_getFontDefault`).  All gone — wasm_fwd.zig
  provides default no-op / zero-init host fallbacks inline:
  ```zig
  pub fn rlGetShaderIdDefault() c_uint {
      if (comptime is_wasm) return @import("rlgl_gpu.zig").rlGetShaderIdDefault();
      return 0;  // host fallback inlined here
  }
  ```
  Tests don't need to provide stubs — the forwarder is
  authoritative.  Tests that legitimately want to inject
  custom values can still do so by linking against override
  symbols, but no current test needs that.

- **Test-stub burden dropped further.**  models_test.zig and
  text_test.zig each lost ~10 lines of `export fn _zimr_test_*`
  boilerplate.  The host-side test contract is now
  "provide stubs for libc + DOM imports, period" — no
  per-test rlgl_gpu stubs.

- **Module name choice.**  Started as `rlgl_gpu_fwd.zig`, then
  realized `font_default.zig` has the same problem (it's
  transitively wasm-only because it uploads textures at init).
  Renamed to `wasm_fwd.zig` for honesty.  The forwarder isn't
  rlgl-specific; it's a general "things that only exist on
  wasm" gateway.

- **Wasm sizes unchanged to the byte.**  basic 75914, cube3d
  137518, keys 136838, png_demo 127441, load_image_demo
  128408, rtt 76092, shader 77274.  Same as Session N+9.
  Cleanup-only refactor: no semantic change, no DCE
  perturbation.  This is exactly the kind of cleanup
  Phase 12 is supposed to be — bytes-neutral, code-quality-positive.

- **243/243 + 7/7 still green.**  No test changes needed.  The
  refactor preserved every existing behavior; the only
  observable difference is that the codebase is smaller and
  cleaner.

- **Phase 12 task #15 ("comptime-gate web/dom + web/gl") is
  partially addressed.**  The full version of that task wants
  `web/dom.zig` and `web/gl.zig` to no-op on host directly.
  This session does that for *consumers* of those modules
  (every cross-module call goes through wasm_fwd) without
  modifying web/dom or web/gl themselves.  The remaining
  cleanup — making web/dom + web/gl directly host-compilable
  — is still pending but no longer blocks anything.

- **Pattern available to future modules.**  Any new module
  that needs to call into rlgl_gpu / font_default / other
  wasm-only modules should:
  1. `const wasm_fwd = @import("wasm_fwd.zig");`
  2. Call `wasm_fwd.someFunction(...)` — the gate is invisible
  3. Add new forwarders to wasm_fwd.zig if the function isn't
     already there.  Each addition is 3 lines.
  No need to set up local comptime gates ever again.
- **Asset loading from URL works end-to-end.**  Three new pieces:
  `src/web/fetch.zig` (~110 LOC), `js_fetch_*` handlers in
  `dom.js` (~70 LOC), and `png.loadAsync`/`pollLoad`/`releaseLoad`
  on top.  `examples/load_image_demo.zig` (155 LOC) demos a
  per-frame state machine that fetches `assets/smiley.png`,
  decodes it once bytes arrive, uploads to GPU, then renders.
  Smoke proves the pipeline: frame #1 kicks off, frame #2 logs
  `load: PNG ready 32x32 → tex id 5`, frame #3+ render normally.

- **The big design choice was sync vs. async.**  raylib's
  `LoadImage(path)` is synchronous — it blocks until the file
  is read.  In single-threaded wasm this is impossible: once
  Zig is running, the browser's network stack is starved.
  The honest, web-native API is async-only:
  ```zig
  const handle = png.loadAsync(allocator, "foo.png");
  // poll handle each frame until .ok or .failed
  ```
  No `loadSync` even as a convenience.  Phase 12 should keep
  this discipline — exposing a synchronous wrapper would be
  a footgun (would either block infinitely or always fail).

- **Wasm-side allocation hooks are the key plumbing.**  Two
  new `pub export fn`s in zimr.zig:
  ```zig
  export fn zimr_fetch_alloc(size: usize) usize { ... }
  export fn zimr_fetch_free(ptr: usize, size: usize) void { ... }
  ```
  JS calls these when a fetch resolves; the bytes are written
  directly into wasm linear memory so Zig can reference them
  as a normal slice without a cross-language copy.  Backed by
  `std.heap.wasm_allocator` (which uses wasm-page-grow under
  the hood).  Total size cost: ~350 bytes added to every
  wasm's export table since these live in zimr.zig.

- **DCE still pristine for the leaf modules.**  Adding fetch +
  loadAsync + the load_image_demo grew basic/rtt/shader/keys/
  cube3d by ~350 bytes each (the new exports), but the actual
  fetch logic + png loadAsync state machine is fully stripped
  unless the example references it.

- **State-machine pattern for loaders.**  The `LoadState` union
  in load_image_demo.zig is a clean idiomatic example of how
  to structure async-driven examples in zimr:
  ```zig
  const LoadState = union(enum) {
      idle,
      loading: png.LoadHandle,
      ready: struct { tex_id: c_uint, ... },
      failed: anyerror,
  };
  ```
  Each frame's `update` does a single switch on the state and
  advances at most one transition.  Phase 12 might package this
  as a generic `Loader(T)` in zimr — but the explicit state
  machine reads better than a callback or future-based API for
  the canonical example.

- **Smoke required JS-side mocks.**  `tests/smoke.ts` had no
  fetch surface; added 50 LOC of `js_fetch_*` handlers backed
  by `node:fs.readFileSync`.  Synchronous-load works for tests
  because the smoke fake doesn't actually need to be
  async-correct — the browser's real `fetch()` does.

- **Sizes audit: every wasm grew by ~350 bytes.**  Not great:
  basic/rtt/shader pay this cost without ever using fetch.
  Phase 12 candidate: gate the fetch-allocation exports behind
  a comptime config flag, OR extract them into an opt-in
  module that examples explicitly `@import`.  Right now the
  unconditional `pub export fn zimr_fetch_alloc` in zimr.zig
  ensures the export-table entry survives DCE.  Acceptable for
  now; fix in Phase 12 cleanup.

- **HTTP-served path = WASI alternative for free.**  Going via
  `fetch()` rather than WASI `fd_open`/`fd_read` means assets
  are reachable from the same dev server that serves the wasm
  itself.  No filesystem path translation, no preopen
  configuration, no runtime FS shim.  This is the right
  decision for a browser-first port — WASI file I/O would
  add server-side dependencies and complicate `zig build serve`.
  If desktop-Zig support ever happens (it won't for this
  project but Phase 12 should leave the door open), `fetch.zig`
  could be comptime-gated to fall back to `std.fs.cwd().readFile`
  on non-wasm targets.
- **Pure-Zig PNG decoder, end-to-end.**  ~280 LOC in `src/png.zig`.
  Targets 8-bit grayscale / grayscale+alpha / RGB / RGBA (color
  types 0, 2, 4, 6), all 5 PNG filter types (None, Sub, Up,
  Average, Paeth), no Adam7 interlace.  Output is normalized to
  RGBA8 regardless of source format so the default GL shader
  Just Works.

- **`std.compress.flate` is excellent.**  PNG IDAT data is zlib-
  framed DEFLATE; the new (Zig 0.16) `std.compress.flate.Decompress`
  with the `.zlib` container handles it in 5 lines:
  ```zig
  var reader = std.Io.Reader.fixed(input);
  var writer = std.Io.Writer.fixed(output);
  var d: std.compress.flate.Decompress = .init(&reader, .zlib, &.{});
  _ = d.reader.streamRemaining(&writer) catch ...;
  ```
  Zero allocations beyond the writer's output buffer.  Phase 12
  should preserve this pattern when adding more decoders (JPEG
  doesn't use DEFLATE, but TGA/BMP/QOI all benefit from the
  std.Io.Reader/Writer fixed-buffer pattern).

- **9 host tests in png_test.zig.**  Three hand-crafted PNGs
  (4×4 RGBA, 2×2 grayscale, 2×2 RGB) generated via Python
  zlib + struct (no PIL dependency).  Tests cover header
  parsing, signature rejection, truncation rejection, and
  per-pixel value verification across all three color-type
  expansions to RGBA8.  Total embedded test data: 226 bytes.

- **`examples/png_demo.zig` (new, 6th example).**  Embeds a
  32×32 smiley PNG via `@embedFile`, decodes it, uploads to
  GPU, draws 4 tiled copies at 4× zoom with different tints
  (white / sky / amber / pink).  Smoke captures the
  `[2] PNG: decoded 32x32, GPU tex id 5` log line — the proof
  that the entire pipeline (PNG bytes → inflate → unfilter →
  RGBA8 → rlLoadTexture → drawTexturePro → fragment shader)
  works without a single C dependency.

- **`@embedFile` requires module exposure.**  Zig 0.16 doesn't
  let `@embedFile` reach paths outside the package's source
  directory.  Workaround in build.zig:
  ```zig
  exe_mod.addAnonymousImport("smiley_png", .{
      .root_source_file = b.path("assets/smiley.png"),
  });
  ```
  Then `@embedFile("smiley_png")` works.  Slightly clunky but
  the right Zig idiom — the module name becomes a contract
  the example uses.  Phase 12 might offer a simpler asset-
  loading API that wraps this.

- **DCE is *still* perfect.**  Adding 280 LOC of PNG decoder +
  pulling in `std.compress.flate` (which is substantial)
  changed basic/rtt/shader/keys/cube3d sizes by exactly zero
  bytes.  png_demo is 127 KB — the std.compress.flate inflate
  state machine + decoder + texture path + font atlas all
  pulling their weight only when actually used.  This is the
  single best argument for module-per-file architecture I've
  seen across this whole port.

- **Zero new env imports.**  png_demo has 4 env imports — the
  same 4 as keys (libc + getRandomValue).  No new contamination.
  This was a real win: the inflate code uses `std.Io.Reader`/
  `Writer` fixed-buffer adapters which are pure Zig with no
  syscalls.

- **Phase 6 nudged forward.**  rtextures now has its keystone
  asset loader.  Hooking up `loadImage(filename)` for actual
  files needs WASI file I/O wiring — deferred.  But
  `loadImageFromMemory(bytes, ".png")` is now trivially
  implementable: the underlying decoder is here.

  Phase 12 ziggify target: a `Texture.fromPng(allocator,
  bytes)` static method that wraps decode + upload + handle
  return in one call, with `defer tex.deinit()` cleanup.

- **Allocator question for Phase 12.**  png.decode takes an
  Allocator and returns `Image{ pixels: []u8, ... }` with a
  `deinit` method.  This is the canonical zig-idiomatic shape
  — much better than raylib's malloc/free behind the scenes.
  When Phase 12 wraps the C-ABI `loadImage`/`unloadImage`
  pair, png.decode is the model to imitate.

---

## Phase 12 task list (running)

1. ☐ Allocator-explicit `loadXxx` family
2. ☐ Error unions for all `Load*` / `rlGetLocation*` / sentinel-return APIs
3. ☐ Snake_case zig wrappers over PascalCase ABI exports
4. ☐ Enum tightening (KeyboardKey, MouseButton, PixelFormat, etc.)
5. ☐ Vector2/3/4/Matrix method API (over the free fns in raymath)
6. ☐ Color builder + manipulation methods
7. ☐ Rectangle accessor methods (topLeft, center, contains, ...)
8. ☐ Slice ABI for all `ptr+len` parameter pairs
9. ☐ Texture/Image/Shader/Font deinit methods
10. ☐ Per-frame arena adoption guidance in docs/examples
11. ☐ Context-threading (defer to last — biggest re-plumb)
12. ☐ Re-author all examples in zig-idiomatic style (current
       examples use ABI-shape calls)
13. ✅ **Extern-fn audit** (Session N+5) — 24/44 done initially;
       Session N+6 closed 5 more via comptime-gate; Session N+10
       closed all remaining cross-module externs by extracting
       the forwarder.  Done.
14. ✅ **Wasm-side allocator** (Session N+12) — `src/allocator.zig`
       implements `malloc/calloc/realloc/free` backed by
       `std.heap.wasm_allocator` with 16-byte aligned header-
       prefix size tracking.  `src/libc.zig` shim makes the
       symbols reachable cross-module without env-import
       contamination.  All libc env stubs in runtime.js +
       smoke.ts dropped; test-stub boilerplate removed across
       3 test files.
15. 🟡 comptime-gate web/dom + web/gl modules so they fall back
       to no-op stubs on non-wasm targets.  Session N+10 addressed
       this for *consumers* via `wasm_fwd.zig`; full version still
       wants the web/ modules themselves to be host-compilable.
16. ☐ Gate `zimr_fetch_alloc`/`zimr_fetch_free` exports so
       examples that don't use fetch don't pay the ~350 byte tax.

### Session N+27 (Roadmap execution: Steps 1–7)

**Charted ground.**  100-step roadmap from the previous session calls
for executing Steps 1–7 first (coverage holes section §1: getKeyName
through Drawing modes).  Hit them all this session.

#### Step 1 ✅ `getKeyName(key) ?[]const u8` (input.zig)

Lookup table over all 110 KEY_* codes.  **Naming convention: W3C
`KeyboardEvent.code`** (`"BracketLeft"`, `"ArrowRight"`, `"NumpadEnter"`,
`"ShiftLeft"`/`"ShiftRight"`) instead of glfw's terse names — natural
choice in a browser runtime since that's what `keydown` events carry.
Letters/digits return character form (`"A"`, `"5"`) for ergonomic
display in keybinding overlays.  KEY_NULL → null distinctly from
unknown key.  9 tests, all pass.  ~110 LOC.

#### Step 2 ✅ `drawCapsule` + `drawCapsuleWires` (models.zig)

Direct port from raylib's C `DrawCapsule` (~250 LOC each).  Builds a
local orthonormal frame (`b0` along axis from `vector3Normalize`;
`b1`, `b2` perpendicular via `vector3Perpendicular` + cross product) so
caps face outward regardless of orientation.  Edge cases: zero-length
endpoints → sphere; slices < 3 → clamped to 3.  Two compile fixes
during the port:
- `i0`/`i1` shadow Zig primitives (the two-bit integer types) —
  renamed to `if0`/`if1` inside the capsule block via a localized
  Python regex pass.
- `z.raymath` wasn't a member of the file-local `z` struct (only
  available inside compiled-for-wasm gates).  Moved the `math =
  @import("raymath.zig")` line from the bottom of the file to the
  top, then `sed`-replaced all `z.raymath.*` → `math.*` in the file,
  including pre-existing `drawMesh`/`drawModel` call sites that had
  the same gating-only pattern.  3 capsule tests added (sphere case,
  slices<3 clamp, tilted axis).  Total Step 2 delta: ~510 LOC.

#### Step 3 ✅ `loadCodepoints` + `loadUTF8` (text.zig)

UTF-8 decode/encode using existing `getCodepointNext`.  Invalid
codepoints (>0x10FFFF or U+D800..U+DFFF surrogate range) emit
0xFFFD.  Bug found and fixed during testing: my early-return path
when malloc failed didn't set `count.*`, so callers got "0
codepoints" instead of "N codepoints needed but couldn't allocate".
Fixed: `count.*` is now set BEFORE the malloc attempt.  Tests
adapted for host-test compat — `libc.malloc` returns null on host
because the wasm-allocator backing path isn't viable on native, so
full roundtrip tests can't run on host.  Test what works (empty
input, count validation), rely on smoke tests for full behavior.
**This is a recurring tax**: any function using `libc.malloc` needs
host tests to be defensive.  Section 5 (allocator-explicit pass) of
the roadmap will fix this systemically.  3 host tests added.

#### Step 5 ✅ `imageDraw` + `getImageColor` (textures.zig)

Done before Step 4 because Step 4 (`imageDrawTextEx`) depends on it.
- `getImageColor(image, x, y) Color`: read pixel-from-Image with
  format dispatch over GRAYSCALE/GRAY_ALPHA/R8G8B8/R8G8B8A8.
  Out-of-bounds → transparent black `{0,0,0,0}`.
- `imageDraw(dst, src, src_rec, dst_rec, tint)`: composite Image-onto-
  Image with optional tint.  Source/dest rectangle clipping; same-size
  paths are pixel-exact (used by text rendering); different-size uses
  nearest-neighbor.  Documented in the function's doc comment that
  Step 12 will upgrade to bilinear via `imageResize` and that change
  will retroactively improve `imageDraw` automatically.  Calls
  `colorAlphaBlend` per pixel.

Hit a regrettable str_replace bug: the `pub fn imageClearBackground`
header was lost when I inserted my new code, because str_replace
requires unique anchor text and my inserted block ended near the
function header.  Fixed by re-anchoring the str_replace to include
the full function header in both old_str and new_str.  6 tests
added covering the four pixel formats + bounds clipping + alpha
blend.

#### Step 4 ✅ `imageDrawText` + `imageDrawTextEx` (text.zig)

The big design choice: how to make `imageDrawTextEx` work for our
embedded default font, when `font.glyphs[i].image` was unpopulated
(atlas-only)?  Three options enumerated last session:
- (a) Extract per-glyph CPU-readable images during `loadFontDefault`.
- (b) Only support TTF-loaded fonts.
- (c) Warn-and-noop for default font.

Picked (a).  Modified `font_default.zig`:
- Added a tightly-packed `glyph_pixels` BSS buffer sized at
  comptime via `sum(chars_width) * 10 * 4 = 37,440 bytes`.
- During the rect-layout loop, `@memcpy` each glyph's RGBA rectangle
  out of `atlas_pixels` into its slot in `glyph_pixels`, then point
  `glyphs_buf[k].image.data` at the slot.

This is a one-time 37 KB BSS cost in exchange for fully-working
CPU-side text drawing on the default font.  Worth it.

`imageDrawTextEx`: walks codepoints with `getCodepointNext`, looks
up each via `getGlyphIndexZ`, composites the per-glyph image onto
`dst` via `imageDraw`.  '\n' triggers 1.5× line-height jump (matches
raylib).  '\t' and ' ' get advanced but not drawn.  Documented limit:
fontSize < baseSize is clamped (no shrink-rasterization yet).
`imageDrawText`: convenience wrapper picking the default font with
`spacing = fontSize/10`.  2 host tests for defensive paths
(null-data dst, zero-glyph font).

#### Step 6 ✅ `imageDrawTriangleEx` (textures.zig)

Barycentric Gouraud-shaded triangle rasterizer.  Uses the same edge-
function pattern as `imageDrawTriangle` (flat-color), then converts
the edge functions to normalized barycentrics via `inv_denom = 1 /
(twice signed area)`, blends three vertex colors per channel.
Degenerate triangle (zero area) → silent no-op.  3 tests:
- Solid fill (all same color)
- Vertex-color blend with separate red/green/blue corners — verified
  by sampling near each vertex and checking which channel dominates.
- Degenerate (colinear) triangle leaves dst untouched.

#### Step 7 ✅ Drawing modes (shaders.zig)

Six begin/end fns:
- `beginShaderMode(shader)` / `endShaderMode()` — switches the
  current shader; ends restores the rlgl default.
- `beginBlendMode(mode)` / `endBlendMode()` — switches the GL blend
  function/equation; ends resets to BLEND_ALPHA (0).
- `beginScissorMode(x, y, w, h)` / `endScissorMode()` — wraps
  `rlEnableScissorTest` + `rlScissor` with Y-flip (raylib defines
  scissor with origin at upper-left, GL wants bottom-left).  Both
  begin and end call `rlDrawRenderBatchActive()` first to flush the
  active render batch and avoid scissor leaking back to prior draws.

5 new wasm_fwd forwarders (rlSetShader, rlSetBlendMode,
rlEnableScissorTest, rlDisableScissorTest, rlScissor).  Created
`src/shaders_test.zig` with 4 host-safe tests verifying every
begin/end is callable without crash, then wired it into
`build.zig`'s `test_files` list.

#### Endpoint

327/327 host tests + 8/8 smoke tests, all green.  Coverage of
roadmap section §1 (Coverage holes): 7 of 20 done.

Next session: continue with Step 8 (Image alpha ops:
`imageAlphaMask`/`imageAlphaClear`/`imageAlphaCrop`/
`imageAlphaPremultiply`) through the rest of section §1.

#### awesome-zig list — additional candidate libraries logged

User pointed at https://raw.githubusercontent.com/zigcc/awesome-zig/
README.md; absorbed it for cross-references against
DEPENDENCIES_PLAN.md.  Notable additions to consider:

- **`kooparse/zalgebra`** — linear algebra by the same author as
  `zgltf`; potential alternative to our hand-rolled raymath if we
  ever want SIMD-aware math.  Not pressing.
- **`fabioarnold/nanovg-zig`** — pure-Zig anti-aliased vector
  graphics.  Could be an interesting layer for high-quality 2D once
  the basics are in place.
- **`hexops/mach-sysaudio`** — cross-platform low-level audio IO.
  For native target (post-v0.1) this would be the equivalent of
  Web Audio for desktop.  Deferred but tracked.
- **`bfactory-ai/zignal`** — image processing in Zig.  Could
  augment zigimg for filters/blur/dither.  Worth a look when
  we tackle Step 9.
- **`ryupold/zecsi`** and **`Jack-Ji/jok`** — Zig game frameworks
  built on raylib; useful for studying how others wrap raylib in
  Zig (idiom comparisons).
- **`MasterQ32/zero-graphics`** — OpenGL ES 2.0 app framework that
  runs on web/desktop/Android.  Closer to zimr's value prop than
  I'd realized; worth studying for cross-platform patterns.
- **`atman/zg`** — Unicode text processing.  Will need this once
  we go beyond ASCII-and-some-emoji in TTF text.
- **`mitchellh/zig-js`**, **`ringtailsoftware/zig-wasm-audio-
  framebuffer`** — wasm + JS interop patterns.  Worth comparing
  against our current `dom.zig` + `runtime.js` design.

None adopted this session.  Logged in DEPENDENCIES_PLAN.md as
"second-wave candidates" for re-evaluation at the post-Step-50
checkpoint.

### Session N+28 (Step 12 finish + TrueType vendor + zg decoder vendor)

- **Step 12 finished** (had been left half-done with the str_replace
  anchor confirmed but body not pasted).  Added `imageResize`
  (bilinear) and `imageResizeNN` (nearest-neighbor) before
  `imageResizeCanvas`.  ~150 LOC.  Both reallocate via libc.malloc and
  free old buffer.  `imageResize` does bilinear resampling — quality
  appropriate for photographic content, no extra dep needed.
  `imageResizeNN` uses raylib's fixed-point `<<16` trick (one integer
  divide per dimension instead of float).  Compile fix: `c_long`
  division required `@divTrunc`.  5 host tests added.  352/352
  + 8/8.

- **TrueType.zig vendored.**  User uploaded the source as a text
  file (Codeberg blocked from container).  Placed verbatim at
  `src/_vendor/truetype/TrueType.zig` (2380 LOC).  One patch
  applied: replaced `@import("build_options")` + `debug_todo =
  build_options.debug_todo or builtin.is_test` with
  `debug_todo = builtin.is_test` so we don't need to wire
  build_options through the build system for it.  Documented the
  delta in `src/_vendor/truetype/README.md` so future updates can
  re-apply it.

- **`src/truetype.zig` shim** (~80 LOC) re-exports the surface
  zimr needs: `load`, `scaleForPixelHeight`, `codepointGlyphIndex`,
  `glyphHMetrics`, `glyphKernAdvance`, `verticalMetrics`,
  `glyphBitmapBox`, `glyphBitmap`.  Plus `truetype.upstream.*`
  escape hatch for callers needing the wider API (CFF, GPOS
  details, etc).  `pub const Font = upstream;` makes Font an alias
  rather than a wrapper struct (no API divergence).

- **Verified compiles for both host and wasm32-wasi.**  Standalone
  test (`zig test src/_vendor/truetype/TrueType.zig`) ran zero
  internal tests but didn't crash on compile.  wasm32-wasi
  build-obj also succeeded.

- **`src/truetype_test.zig`** with 3 sanity tests:
  - `GlyphIndex.notdef` is zero (convention check).
  - upstream re-export accessible (escape hatch wired).
  - `Font` is an alias not a wrapper.
  Wired into build.zig's test_files list.

- **What I LEARNED writing the test:** upstream documents
  "Untrusted font files are not supported" — `load()` will panic
  on truncated input rather than returning an error.  Removed my
  initial "rejects too-short bytes" test because it triggered the
  panic.  This means any caller of `truetype.load` MUST pass a
  byte slice from a trusted source (or ones that have been
  validated upstream — e.g., zigimg's eventual TTF path).
  Documented in the shim's doc comment.  This is a notable Phase
  9 risk — Web Audio loaders that accept arbitrary user-uploaded
  fonts will need their own validation pass first.

- **`Step 60 (TTF font support) is unblocked.**  Path forward:
  loadFontEx(gpa, ttf_bytes, base_size, codepoints) does:
  1. `truetype.load(ttf_bytes)`
  2. `truetype.scaleForPixelHeight(font, base_size)`
  3. for each codepoint: rasterize → record bitmap dims +
     advance + kerning
  4. pack rectangles into atlas (uses bgourlie/zrectpack — Step 56)
  5. upload atlas to GPU
  6. populate Font.glyphs[] and Font.recs[]

- **zg/code_point.zig vendored.**  524 LOC pure-Zig DFA-based
  UTF-8 decoder.  Implements the **Maximal Subparts** error-
  recovery algorithm (Unicode-recommended) — when bytes can't be
  decoded, the decoder advances by exactly the number of valid
  bytes consumed and emits U+FFFD per maximal subpart, rather
  than greedily consuming subsequent malformed bytes (which is
  what our hand-rolled `nextCodepoint` does).

- One patch applied: `pub const uoffset = if (@import("config")
  .fat_offset) u64 else u32;` → just `pub const uoffset = u32;`
  (4 GB strings are plenty for our wasm32 target).  Documented
  in `src/_vendor/zg/README.md`.

- All 7 of zg's internal tests pass on our toolchain (`zig test
  src/_vendor/zg/code_point.zig` runs them automatically).

- **NOT YET wired into text.zig.**  The migration is queued for
  next session: replace `nextCodepoint`/`countCodepoints` body
  with calls into `code_point.decodeAtCursor` / a count loop.
  Estimated ~80 LOC delete + 30 LOC delegate.

- **zero-graphics studied** but no code adopted.  Read through
  `src/main/wasm.zig` (868 LOC) and `www/zero-graphics.js` (1346
  LOC).  Notable patterns:
  - Their JS resource arrays start with `null` to ensure id 0 is
    never returned.  We should adopt this in `gl.js` — currently
    we use 0 as a real id which conflicts with raylib's
    "id 0 == invalid" convention.
  - Per-glyph individual textures with `AutoHashMap(u24, Glyph)`.
    **Wrong choice for us** — atlas-baking will be better given
    raylib's font model.
  - `meta_getScreenW`/`meta_getScreenH` exposed via `webgl`
    import group — same idea as our `meta_*` exports.
  - Three import groups conceptually similar to ours
    (`zerog` / `webgl` / module-defined extras).

- **TODO from the zero-graphics study:** verify our `gl.js`
  actually rejects id=0 in resource lookups, OR add a sentinel
  push so id=0 means "no resource".  If our current behavior is
  inconsistent, fix in a future hardening pass.

- **TrueType.zig + zg/code_point.zig together are ~2900 LOC of
  vendored pure-Zig dependencies.**  Both license-checked-todo
  (need to confirm before public release).  Both compile clean
  for our wasm32-wasi target.  Both have their own test suites
  that pass.  This is **major progress** on the no-C-deps goal —
  Steps 60-63 (TTF font support) are now de-risked.

- **355/355 host + 8/8 smoke green.**  Test count went 347 → 352
  (+5 from imageResize tests) → 355 (+3 from truetype tests).

- **Owed maintenance not yet done THIS session:** ROADMAP marks for
  steps 8-12, STATUS update, this ZIGGIFY entry, zip refresh.

### Session N+29 (this turn — closing N+28's loose ends + continuing)

- **Owed maintenance landed.**  ROADMAP marks 8-12 ✅.  STATUS
  updated.  ZIGGIFY notes for both N+27 closer and N+28.  Zip
  refresh.


### Session N+30 (Steps 19-23 + section §2 underway)

- **Step 19 finished** — fixed the `[*c]f32` issue from N+29.  `[*c]`
  is C-pointer-or-null: null-checkable but NOT via `.?` (that's for
  `?T` optionals).  Removed `.?` from texcoord/normal/index
  dereferences.  Also two ArrayListUnmanaged API tweaks for Zig
  0.16:
    - `var buf: ArrayListUnmanaged(u8) = .empty;` (not `.{}`).
    - Use `buf.print(gpa, fmt, args)` directly — no `.writer(gpa)`
      indirection in 0.16.

- **Step 20 — primitive AABB helpers** in models.zig: 4 one-liners
  for sphere/cube/capsule/cylinder, plus a bonus `drawBoundingBox`
  wireframe helper (raylib's `DrawBoundingBox` port).  Compose
  cleanly: `drawBoundingBox(getSphereBoundingBox(c, r), color)`
  is a one-liner.  5 host tests covering negative-radius
  normalization, half-extents, capsule union, tapered cylinder.

- **End-of-section milestone for §1 reached: 18/20 done.**  Steps
  13 (exportImage) and 16 (loadMaterials) deferred to dep adoption.
  Coverage is now ~92% of raylib's exposed surface.

- **Step 21 — `models3d` example** (~110 LOC).  Five primitives in
  a row at x=-4..+4: sphere, cube, cylinder, capsule, cone.  Camera
  orbits at 20°/sec.  Bounding boxes drawn around each shape using
  the new Step 20 helpers — visually verifies the AABB math.  Hit
  a colors-palette gap: example used rose/violet/emerald shades not
  yet in colors.zig.  Extended the palette by 10 shades.  This is
  a recurring friction point — should pre-populate the full
  Tailwind palette in a future cleanup.

- **Step 22 — `shader_uniforms` example** (~120 LOC).  Companion
  to `shader.zig` (which uses rlgl raw API); this one uses the
  high-level `shaders.loadShaderFromMemory` / `getShaderLocation`
  / `setShaderValue` / `beginShaderMode`/`endShaderMode` end-to-end.
  HSV-spiral fragment shader following the mouse, with three
  custom uniforms (uMouse, uResolution, uTime).  Validates the
  GLSL ES 3.0 path with `#version 300 es`.

- **Step 23 — `particles` example** (~140 LOC).  2D point-sprite
  particle system with 512-slot ring buffer.  Spawns 8 particles
  per frame from the mouse position; each has random velocity
  (xorshift32 RNG via `getRandomValue`), random life, random
  radius, random color from a 5-shade curated palette.  Simple
  physics (gravity pull + drag) and alpha-fade as particles age.
  `setRandomSeed(0xC0FFEE42)` for repro stability — same seed →
  same particle layout, useful for visual regression tests later.

- **Auxiliary additions made along the way:**
  - `getScreenToWorldRay` + `getScreenToWorldRayEx` (camera.zig).
  - `isGamepadButtonReleased`/`isGamepadButtonUp`/
    `getGamepadButtonPressed`/`getGamepadAxisCount`/`getGamepadName`
    (input.zig).
  - `isFileNameValid` (core.zig).
  - `drawBoundingBox` (models.zig).
  - 10 new Tailwind shades (colors.zig).
  - **zg's UTF-8 DFA decoder fully wired into text.zig.**  Replaced
    `nextCodepoint` and `countCodepoints` to delegate to
    `code_point.decodeAtCursor` / `Iterator`.  Translates U+FFFD →
    '?' at the public boundary so raylib API compatibility is
    preserved.  +8 regression tests for ASCII / 2-byte Cyrillic /
    3-byte CJK / 4-byte emoji / orphan continuation byte / truncated
    3-byte sequence (Maximal Subparts behavior).  Test count went
    355 → 362 (zg internal tests joined) → 370.

- **Final counts:** 389/389 host + 11/11 smoke.  Section §1 of
  ROADMAP: 18/20 done.  Section §2: 3/12 done.

- **What I'd do differently in retrospect:**
  - Should have audited the colors palette before starting examples
    so I wasn't pausing to add shades mid-write.
  - Should have set up a "smoke after every example" tight loop
    earlier — caught issues fast in N+30 once I did.
  - The `[*c]` vs `?[*]` distinction tripped me up during the
    Step 19 fix in N+29.  Worth a Zig idioms note here for future
    me: `?T` uses `.?` (optional unwrap, panic on null), `[*c]T`
    uses null-check via `== null` (C-style; null is a valid value).


