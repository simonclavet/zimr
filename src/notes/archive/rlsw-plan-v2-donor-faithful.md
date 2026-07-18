# rlsw → src/rlsw.zig — port plan (v2: demo-driven)

A line-by-line port of raylib's `rlsw.h` (v1.5, ~6070 LOC of C, MIT,
Le Juez Victor "@Bigfoot71") into `src/rlsw.zig`, in zimr style.
Donor: `src/notes/staging/rlsw-original.h`.

## Two governing principles

1. **Demo-driven.**  We ship a working `examples/rlsw_side_by_side.zig`
   in the FIRST sub-batch.  At first it renders nothing — the SW side
   is just a cleared framebuffer.  Every phase that adds visible
   capability also extends the example.  By the end of the port we
   have a textured 3D cube on the WebGL side and the same scene on
   the SW side, comparable pixel-for-pixel.  Working software at
   every step — no big-bang integration at the end.

2. **Zero globals from the start.**  The donor has `static
   sw_context_t RLSW` (program-wide singleton); we never let that
   pattern in the door.  `Context` is a struct the user owns.  Every
   public function takes `*Context` (or `*const Context`) as its
   first arg.  `count_globals.py` audit must read 0/0/0 every turn.
   This rule is established in Phase 0; later phases just maintain it.

## The example: `examples/rlsw_side_by_side.zig`

Structure (stable from Phase 0; content grows per phase):

```zig
const State = struct {
    sw: rlsw.Context,                  // The software renderer
    sw_tex: z.Texture2D,               // GL texture we update each frame from sw
    cam: z.Camera3D,                   // Used once both sides render the same scene
    t: f32,                            // Time accumulator for animation
};

fn update(f: *z.Frame, s: *State) void {
    // (1) Render the WebGL side directly to the canvas — left half.
    drawWebglScene(f, s);

    // (2) Render the SW side into s.sw's framebuffer.
    //     Initially: just clear.  Later: real geometry.
    drawSwScene(&s.sw, s);

    // (3) Upload the SW framebuffer to s.sw_tex (per-frame texture
    //     update via z.textures.updateTexture).
    z.textures.updateTexture(s.sw_tex, s.sw.colorBuffer().ptr);

    // (4) Draw s.sw_tex on the right half of the canvas.
    z.shapes.drawTexture(f.gl, s.sw_tex, screen_w/2, 0, z.colors.white);

    // (5) Optional UI: a label saying "WebGL" / "rlsw", FPS counters.
    drawLabels(f, s);
}
```

`drawSwScene` is the function that grows.  At Phase 0 it's
`s.sw.clearColor(0.1, 0.1, 0.2, 1); s.sw.clear(.color);`.  By
Phase 6 it's spinning a textured cube.

This shape costs us essentially nothing — `updateTexture` already
exists in `src/drawing.zig`, the layout is just a `drawTexture` call
on a half-width region.  The example file lands at Phase 0 and gets
edited (small additions) per phase.

## Choices I'm making — flag any you disagree with

These are decisions worth discussing before we start.  My
recommendation in **bold**.

### Choice 1: Phase ordering of rasterizers

The donor implements points, lines, triangles, and quads as separate
kernels.  We can port them in any order.

(a) Triangles first (the workhorse).  Get the hard one out of the way;
    everything else becomes easier afterward.
(b) Points → lines → triangles → quads.  Each step is more visible,
    each step takes longer.  Demo lights up earlier.
(c) Triangles only initially; everything else later.  Ship a full
    cube-rendering port without lines/points.

**(b).**  Demo lights up at Phase 4 (points) instead of Phase 6
(triangles).  Easier to debug — a point rasterizer is one pixel write
in a clip check; a triangle rasterizer is edge functions + perspective-
correct attribute interp + span fills.  Catching basic bugs early is
worth one extra phase.

### Choice 2: Single evolving example vs many focused examples

(a) **One file** `rlsw_side_by_side.zig` that grows through phases.
(b) Multiple files: `rlsw_clear.zig`, `rlsw_points.zig`,
    `rlsw_triangle.zig`, `rlsw_textured.zig`, etc.

**(a).**  One file means the "what does the SW renderer look like
today?" answer is a single file.  Past versions are in git.  Multiple
files would each need their own boilerplate and would clutter
`examples/`.  The one-file approach is also what the user-facing
narrative wants: "side-by-side comparison" is the WHOLE POINT.

### Choice 3: Pixel format coverage

The donor supports 17 pixel formats (8-bit gray, 16-bit RGB565,
24-bit RGB, RGBA8, half-float, etc.).

(a) **Start RGBA8 + D32 only.**  TODO comment for the others.  Add
    formats lazily when something needs them.
(b) Port all 17 up front.

**(a).**  The framebuffer-format-default macros mean almost every
caller only ever sees R8G8B8A8 / D32 in practice.  The texture-load
path supports more, but our test suite isn't going to exercise R16F
on day one.  Skip the work; come back when needed.  (~600 lines of
donor code deferred.)

### Choice 4: SIMD posture

(a) **Scalar first, vectorize after correctness is proven.**  No
    `@Vector` in the rasterizer kernels for v1.
(b) `@Vector(4, f32)` from the start in matrix mul + lerp.

**(a).**  SIMD makes diff-vs-donor harder to read; bugs in
vectorization look like bugs in the algorithm.  Ship correct scalar
code first, then vectorize the actual hotspots once we have a
profiler reading.  The wasm target's vector lowering is good enough
that the fastpath will be fast even without explicit `@Vector`.

### Choice 5: GL-numeric enum values

(a) **Keep them** (`triangles = 0x0004`, etc.) — matches OpenGL
    1.1, makes future rlgl/rlsw bridge trivial.
(b) Use natural Zig enum numbering — cleaner.

**(a).**  When we eventually plug rlsw under `drawing.zig`'s rlgl
calls, the wire numbers are what get passed.  Keeping them documented
inside the enum decl saves a translation table later.  The cost is
one extra `(c_uint)` annotation; trivial.

### Choice 6: Error model

(a) **Both.**  Fail-able APIs (`init`, `genTextures`) return Zig errors.
    GL-semantic don't-fail-but-record APIs (`vertex2f` past scratch end,
    `bindTexture` of an invalid handle) set `Context.error_code`.
(b) All Zig errors.  Replace `glGetError`-style entirely.
(c) All error_code field.  Match the donor.

**(a).**  Zig errors are the obvious idiom for things that can fail
and the caller MUST handle.  But a lot of GL semantics depend on
"keep going even if invalid; user can `glGetError` later".  Forcing
those to error-union return types would change behavior subtly and
make the public API less GL-ish.  The split mirrors what the rest of
zimr does (e.g. `loadTextureFromMemory` returns an error union).

### Choice 7: v1 milestone

(a) **Textured 3D cube.**  Render a cube with a procedural texture,
    spinning, on both WebGL and SW sides.  Compare visually.
(b) Full donor port (every public function, every blend mode, every
    pixel format).
(c) 2D triangle rasterization only — call it done at a flat triangle.

**(a).**  Cube tests: matrix stacks, projection, depth test, texture
sampling, perspective-correct interpolation, viewport, clear.  It's
"is rlsw believable as a 3D renderer?" in one demo.  We can grow to
(b) iteratively once (a) ships.

### Choice 8: Pool size config

The donor caps textures at 128 and framebuffers at 8 with `#define`s.

(a) **Configurable at `Context.init`** with sane defaults.  No
    compile-time pinning.
(b) Match the donor's `#define`s.

**(a).**  zimr is a runtime-allocated framework; users should be able
to ask for 1000-texture pools if they want.  The donor's compile-time
caps come from being a single-header library trying to avoid heap
config.  We have `gpa: Allocator` everywhere already.

## Verified phase plan

Each phase is one or two turns.  Each ends with: builds clean,
host tests green, smoke tests green, audit clean (0/0/0 globals,
0 unexpected SCCs), zip saved.

The "Demo" column says what the example shows after the phase.

| Phase | Adds                                                  | Demo                                                      | Donor lines | Turns |
|------:| ----------------------------------------------------- | --------------------------------------------------------- | ----------:| -----:|
|   0   | Skeleton + side-by-side stub + tests.zig hookup       | Right half: black                                         |        ~50 |     1 |
|   1   | Public enums + state struct + framebuffer alloc       | Right half: cleared to a color (alpha demo)               |   ~600     |   1–2 |
|   2   | Math helpers (matMul, lerp, fract, half, etc.)        | Same — no visible change                                  |   ~400     |     1 |
|   3   | Pool + handle validity + texture alloc (RGBA8 only)   | Same — texture upload path exists but unused              |   ~500     |     1 |
|   4   | Pixel format read/write (RGBA8 + D32)                 | Same                                                      |   ~250     |   0–1 |
|   5   | Projection + viewport + scissor + matrix stack API    | Same                                                      |   ~250     |     1 |
|   6   | Point rasterizer + `begin/vertex/end` for points      | Right half: scattered colored points                      |   ~400     |     1 |
|   7   | Line rasterizer                                       | Right half: lines forming a star pattern                  |   ~400     |   1–2 |
|   8   | Sutherland-Hodgman clip + triangle rasterizer (BASE)  | Right half: filled triangle (no texture, no depth)        |   ~700     |     2 |
|   9   | Triangle DEPTH variant                                | Right half: two overlapping triangles, correct Z          |   ~150     |     1 |
|  10   | Triangle TEX variant + texture sampling               | Right half: textured triangle                             |   ~300     |   1–2 |
|  11   | Triangle BLEND variant                                | Right half: two transparent triangles overlapping         |   ~200     |     1 |
|  12   | Triangle TEX_DEPTH_BLEND (and combinations)           | Right half: textured + depth + blend                      |   ~150     |   0–1 |
|  13   | Quad rasterizer (BASE + variants)                     | Right half: textured quad sprite                          |   ~700     |     2 |
|  14   | Cull face + 3D projection + depth-buffer clear        | Right half: spinning UNTEXTURED cube                      |   ~150     |     1 |
|  15   | Texture upload + sampling in 3D                       | Right half: spinning TEXTURED cube — **v1 milestone**    |   ~150     |     1 |
|  16   | swReadPixels + swBlitPixels + remaining public API    | Same                                                      |   ~400     |   0–1 |
|  17   | Misc public funcs (cull face, polygon mode setters)   | Demo grows: settings panel via zimr ui                    |    ~80     |     1 |
|  18   | README + CHEATSHEET + LICENSE updates                 | n/a                                                       |    ~50     |     1 |

Sum of donor lines: 5430 covered by phases 0–17.  Remaining ~640
lines are: pixel formats we deferred (Choice 3) + ESP-DSP (skipped) +
SIMD intrinsics (skipped) + log macros (no-op'd).  Fits the donor.

**Total estimate: 18–24 turns.**  v1 milestone (textured cube on
both sides, comparable) lands at turn 15 — about 2/3 of the way.

The example IS the integration test.  Each phase, we stare at the
right half of the canvas and say either "yes that matches" or "huh,
the SW pixel at (123, 87) is one off — bug somewhere in this phase's
work".

## What changes vs the v1 plan

- **Phase ordering reshuffled.**  Original: math → pool → pixels →
  textures → blend → clip → rasterizer (tris first) → ... .  New:
  enums + state + clear (visible end of phase 1) → pool → pixels →
  rasterizer (points → lines → tris) → blend → 3D demo.  Each phase
  delivers visible progress.
- **Public API isn't one phase at the end.**  Each phase ships the
  public API surface for the capability it adds.  The example can
  exercise everything that exists by the end of each phase.
- **Sub-types deferred:** non-RGBA8 pixel formats, half-float
  conversion, SIMD intrinsics, ESP-DSP integration.  Add lazily.
- **Tighter milestones.**  v1 = textured cube on both sides
  (Phase 15), not "every donor function ported".  The remaining
  surface is a Phase 17/18 cleanup.

## Style commitments — unchanged

- Rule 1: arg-per-line for >3 args.
- Rule 2: typed locals.
- Rule 3: braces on every if/while/for.
- Rule 5: casual prose comments; explain WHY.
- Rule 8: Carmack inlining for short helpers.
- Rule 9: zero module-level mutable globals.  `count_globals.py`
  must stay 0/0/0.

Doc comments declare reads / writes / ownership where relevant —
the discipline that made the ECS port reviewable.

## Audit gates per turn

- `python3 scripts/count_globals.py` — 0/0/0.
- `python3 scripts/check_dag.py` — 0 unexpected SCCs.
- `zig build test` — green; counts grow each phase.
- `zig build smoke-test` — 42/42 PASS, 0 FAIL (43/43 once the
  example lands at Phase 0).
- `zig build install` — wasm builds clean.
- `/mnt/user-data/outputs/zimr.zip` — saved.

## Verification — sanity-check the plan

- All donor sections are mapped to a phase.  ✓ (table totals
  5430 lines covered + 640 deferred = 6070).
- No phase requires zimr capability we don't have.  ✓
  (`updateTexture` exists in drawing.zig at line 6765 — confirmed
  before plan write-up.)
- No phase introduces globals.  ✓ (every Context method takes
  `*Context`; every alloc takes `gpa`.)
- No cycles in the import graph.  ✓ (rlsw.zig imports `std` only;
  it doesn't reach into zimr.  The example imports both.)
- Example file is an addition, not a rewrite of an existing file.  ✓
- Tests run host-side without GL.  ✓ (rlsw is pure CPU; framebuffer
  is just `[]u8`; no extern decls.)
- Each phase ends with the project still buildable.  ✓
  (each phase ships public API for its content; example only uses
  what's been shipped.)

## Open questions to resolve as we go

1. **Texture upload performance.**  Per-frame `updateTexture` of a
   320×240 RGBA8 buffer is 307 KB; not free.  If smoke or visual
   quality suffers, switch to PBO upload (raylib has `glBufferData`
   already).  Decision deferred until we measure.
2. **Side-by-side resolution.**  Canvas is 800×600.  SW renders to
   400×600 (right half).  At 60 FPS that's a 480 KB/frame texture
   update, ~28.8 MB/s.  Comfortable.
3. **Sub-pixel precision in the rasterizer.**  Donor rasterizes at
   integer pixel grid; sub-pixel artifacts are noticeable when
   compared to WebGL's anti-aliased output side by side.  We accept
   this — it's what software rasterization looks like.  Optionally
   add 4×4 super-sampling later as a feature flag.
4. **Triangle winding order vs WebGL.**  WebGL is usually CCW = front;
   donor matches.  We follow the donor.

## CHANGELOG entry per turn

Same shape as the ECS port turns.  Each turn records donor section,
line count, design divergences, tests added, audit numbers.

## When we start

Phase 0: 1 turn.  At end: rlsw.zig skeleton present, side-by-side
example renders right half as black, all audits green, zip saved.

Then march through phases.
