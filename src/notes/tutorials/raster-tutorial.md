# How the software renderer works — a tour

This document is what you read first if you want to understand what
`src/raster.zig` does, why it does it that way, and how the parts fit
together.  No code yet — that's the porting work, tracked in
`raster-plan.md`.  This tutorial is the mental model.

## 0.  What's a software renderer for?

A GPU runs the same instructions across thousands of pixels in
parallel.  A CPU runs them one (or 4, or 8 with SIMD) at a time.  So
why would you ever rasterize triangles on the CPU?

A few honest reasons:

- **No GPU available.**  Embedded devices, headless servers, sandboxed
  test environments.  raster was written so raylib could run on
  GPU-less hardware.
- **Determinism.**  Every CPU produces bit-identical output for the
  same inputs.  GPUs vary (driver version, vendor, even temperature
  for some operations).  When you want golden-image tests that don't
  flake, the CPU is your friend.
- **Reference / debugging.**  When the GPU output looks wrong, having
  a CPU implementation of the same pipeline lets you compare side by
  side.  "Is this a my-shader bug or a my-math bug?" gets answered
  instantly.
- **Education.**  A software renderer is the only way to actually
  *see* the work.  No black boxes, no driver, no shader compiler.
  Every transformation, every clip, every interpolation step is in
  source code you can step through.

For zimr specifically, **all four** of these matter.  We're a wasm
target, so the GPU story is "whatever WebGL2 the browser ships" — we
have variability there.  We have a smoke-test pipeline that wants
deterministic image diffs.  We have raylib code that we want to
verify renders correctly.  And it's a fun and useful project to have.

## 1.  Mental model: OpenGL 1.1 fixed-function

If your last graphics work was Vulkan or modern OpenGL, the API raster
exposes will feel like a museum.  raster implements **OpenGL 1.1's
fixed-function pipeline**: no shaders, no programmable stages, just
matrices and state.

The good news is the pipeline is *stable*.  It hasn't changed since
1997.  Every step is well-documented in the OpenGL spec and decades
of textbooks.  Porting it to Zig is mechanical; we don't have to
invent anything.

Here's the entire fixed-function world in one paragraph.  You set up
some state (current color, texture, projection matrix, depth test
on/off, blend mode).  You issue a `glBegin(GL_TRIANGLES)` and submit
three vertices via `glVertex3f`.  Each vertex picks up the current
color and texture coordinates implicitly.  When you hit the third
vertex (or call `glEnd`), the renderer transforms those three points
into screen space, clips them to the visible region, and fills every
pixel they cover, blending with what's already there.  Repeat.

That's the whole API.  raster implements about 70 functions in that
shape.  Most of them are tiny ("set the current color"; "push the
matrix stack"); the work happens in a handful of internal functions
that handle clipping, rasterization, and blending.

## 2.  Pipeline at 30,000 feet

```
   user code
   ─────────
       │
       │  swBegin(triangles)
       │  swVertex3f(x, y, z)        ┐
       │  swVertex3f(x, y, z)        │  immediate-mode submission
       │  swVertex3f(x, y, z)        ┘
       │  swEnd()
       ▼
   ┌────────────────────┐
   │  Vertex transform  │  multiply by MVP matrix → clip space
   └────────────────────┘
       │
       ▼
   ┌────────────────────┐
   │     Clip           │  Sutherland-Hodgman against 6 frustum +
   └────────────────────┘  4 scissor planes; produces 0–14 verts
       │
       ▼
   ┌────────────────────┐
   │ Perspective divide │  divide xyz by w → NDC; retain 1/w
   └────────────────────┘
       │
       ▼
   ┌────────────────────┐
   │   Screen space     │  NDC × viewport → pixel coords
   └────────────────────┘
       │
       ▼
   ┌────────────────────┐
   │   Rasterize        │  walk edges, fill spans, interpolate attrs
   └────────────────────┘
       │
       ▼
   ┌────────────────────┐
   │   Fragment ops     │  depth test, texture sample, blend
   └────────────────────┘
       │
       ▼
     framebuffer
```

The vertex transform happens once per vertex.  The fragment ops
happen once per pixel covered.  Most of a renderer's runtime, by
far, is spent in the rasterize → fragment-ops loop.  That's why
raster's hot path is so heavily specialized.

## 3.  Pipeline at 1,000 feet

Each stage in slightly more detail.

### 3.1  Submission

The user calls `swBegin(.triangles)` to start a primitive batch, then
submits vertices one at a time:

```
swColor4ub(255, 0, 0, 255);
swTexCoord2f(0, 0);
swVertex3f(-0.5, -0.5, 0);    // implicitly carries the current color and texcoord

swColor4ub(0, 255, 0, 255);
swTexCoord2f(1, 0);
swVertex3f( 0.5, -0.5, 0);

swColor4ub(0, 0, 255, 255);
swTexCoord2f(0.5, 0.5);
swVertex3f( 0,   0.5, 0);

swEnd();
```

`swColor4ub` and `swTexCoord2f` set fields on the *current* vertex
state.  `swVertex3f` actually emits a vertex — it snapshots the
current color and texcoord, attaches them to (x, y, z), and pushes
the result into a small per-primitive scratch buffer.

When the buffer has enough vertices for one primitive (3 for a
triangle, 4 for a quad, 2 for a line, 1 for a point), the rest of
the pipeline runs and the buffer is reset.  Submission of the next
primitive starts with a fresh buffer.

This is what "immediate mode" means: vertices are processed as soon
as they arrive, not deferred to a later draw call.  It's slower than
modern vertex-buffer-based rendering but easier to reason about.

### 3.2  Vertex transform

Each emitted vertex is multiplied by the current model-view-projection
(MVP) matrix to land in *clip space*:

```
v_clip = MVP × v
```

MVP is the product of three 4×4 matrices: model (object → world),
view (world → camera), projection (camera → clip).  The user
manipulates the modelview and projection stacks separately;
raster multiplies them together internally and caches the result
(re-deriving it when either stack is touched, the `isDirtyMVP` flag
on the context).

Why "clip space"?  In clip space, points outside the visible volume
have known signs in their components (e.g. x < -w means "off the
left edge").  This makes clipping fast — the next stage can decide
in/out per plane with one comparison per vertex per plane.

### 3.3  Clipping

If a primitive is entirely outside the visible region, drop it.  If
it's entirely inside, pass it through.  If it straddles a plane —
the interesting case — split it: keep the inside portion, throw away
the outside portion, and add new vertices at the intersection points.

raster uses **Sutherland-Hodgman** clipping, the classic O(n) algorithm
for clipping a convex polygon against a half-plane:

```
walk edges (v0, v1) of the polygon:
    if v0 inside and v1 inside:    output v1
    if v0 inside and v1 outside:   output intersection
    if v0 outside and v1 inside:   output intersection, then v1
    if v0 outside and v1 outside:  output nothing
```

Repeat for each of the 6 frustum planes (left, right, bottom, top,
near, far) and 4 scissor planes (the user-set scissor rect).  The
output of one plane's clip is the input to the next.

A triangle (3 verts) clipped against 10 planes can in principle
produce a 13-gon, but each plane adds at most one vertex (because
clipping a convex polygon against a plane keeps it convex).  Donor
caps the scratch at 14 vertices — that's 4 (start with quad) + 6
(frustum) + 4 (scissor).

Attributes (color, texcoord, depth) interpolate at the intersection
points: if the cut happens at parameter `t ∈ [0, 1]` along an edge
from `v0` to `v1`, the new vertex's color is `lerp(v0.color, v1.color,
t)` and similarly for the other attributes.

### 3.4  Perspective divide

After clipping, divide each vertex's `xyz` by its `w`:

```
ndc.x = clip.x / clip.w
ndc.y = clip.y / clip.w
ndc.z = clip.z / clip.w
```

After this, vertices live in **normalized device coordinates** (NDC):
x and y in [-1, 1], z in [0, 1] or [-1, 1] depending on convention.
Anything outside this cube was already clipped in the previous stage,
so we should be safe.

Why retain `1/w`?  Because we'll need it for **perspective-correct
attribute interpolation** in the rasterizer.  If you linearly
interpolate texcoords across a triangle in screen space, perspective
gets it wrong (textures appear to "skate" on near surfaces).  The
fix is to divide each attribute by `w` at vertex time, interpolate
those `attr/w` values linearly across the triangle, and multiply
back by interpolated `1/w` at each pixel.  raster stores `1/w` in
the position's `w` component for exactly this reason — note the
comment in the donor:

```c
float position[4]; // Clip space (x,y,z,w) → NDC (after /w) → screen space (x,y,z,1/w)
```

The same `w` slot wears different hats at different stages.  Keep
that in mind when reading the rasterizer code.

### 3.5  Screen-space transformation

NDC → pixels:

```
screen.x = (ndc.x + 1) × (vp_width  / 2) + vp_x_offset
screen.y = (ndc.y + 1) × (vp_height / 2) + vp_y_offset
screen.z = ndc.z   (kept for depth test, NOT premultiplied)
```

After this, `screen.x` and `screen.y` are pixel coordinates inside
the framebuffer.  raster stores `vp_center` and `vp_half` precomputed
(viewport center and half-extents) so this becomes one madd per
component.

### 3.6  Rasterization

Now we have a triangle in screen space with attributes attached to
each vertex.  The rasterizer walks every pixel inside the triangle,
interpolates the attributes, and emits a fragment.

Two algorithms are common: **edge functions** (Pineda's algorithm)
and **scanline** rasterization.  raster uses scanline.

Scanline: sort the three vertices by Y, find the top one.  Walk
downward one row at a time.  For each row, find where the two
"active" edges intersect that row (linear interpolation along Y),
giving the left and right X bounds of the span.  Fill that span,
left to right, interpolating attributes along X.  When you cross a
vertex, switch active edges.

In code:

```
sort vertices so that v0.y ≤ v1.y ≤ v2.y
top half: edges (v0→v1) and (v0→v2)     ← y ranges [v0.y, v1.y]
bottom half: edges (v1→v2) and (v0→v2)  ← y ranges [v1.y, v2.y]

for each y from v0.y to v2.y:
    xl, attrs_l = walk left edge to row y
    xr, attrs_r = walk right edge to row y
    fill_span(y, xl, xr, attrs_l, attrs_r)
```

The span fill is the inner loop of the inner loop.  For each pixel:

1. Compute pixel address in framebuffer
2. (If depth test) read the depth, compare to interpolated z, skip if fail
3. (If textured) sample the texture at interpolated u/v
4. (If blending) read destination color, mix with computed color
5. Write the result

This loop runs **once per pixel covered**.  A 1080p frame fully
covered is ~2 million iterations.  Performance lives or dies here.

### 3.7  Fragment ops

The "(if depth test) … (if textured) … (if blending) …" pattern in
the span fill is the heart of why dispatch tables exist.

Imagine the inner loop literally has this shape:

```
for x from xl to xr:
    if (depth_test_enabled) {
        if (z[x] >= depth_buffer[y][x]) { ... continue; }
        depth_buffer[y][x] = z[x];
    }
    color = (texture_enabled) ? sample(texture, u, v) * vertex_color : vertex_color;
    if (blend_enabled) {
        color = blend(color, framebuffer[y][x]);
    }
    framebuffer[y][x] = color;
```

Each `if` is a state-bit branch that **doesn't change** during this
draw call (state is only mutated between draws).  Branching on it
inside a 2-million-iteration loop is wasted work — even if the
branch predictor is right 100% of the time, the compiler can't
inline-optimize across it.

The fix: emit **specialized variants** of the inner loop with each
branch resolved at compile time.  No texture, no depth, no blend?
Tightest loop possible.  Texture and blend but no depth?  Different
specialization, still no branches inside.  Eight specializations
total (2³ = textured?, depth?, blend?), and you pick one at draw
time based on the current state.

Donor does this with `#include __FILE__` macro tricks; we'll do it
with comptime function generation.  The runtime cost is one indirect
call (or a switch) at draw time, not 2 million branches inside the
loop.  This is the single most important performance trick in raster.

## 4.  The state struct

Everything the renderer remembers between calls lives in one struct.
The donor calls it `sw_context_t` and stores it as a single
program-wide static variable.  We'll make it a struct the user
owns, like every other zimr subsystem.

The fields fall into a few clusters:

**Output target**:
- `framebuffer` — the color and depth buffers we're writing to
- `vp*` (viewport) — what region of the framebuffer we're targeting
- `sc*` (scissor) — clip rect inside the viewport
- `clearColor`, `clearDepth` — what to fill on `swClear`

**Per-primitive scratch**:
- `primitive.buffer` — up to 14 vertices (post-clip max)
- `primitive.vertexCount` — how many we've collected
- `primitive.color`, `primitive.texcoord` — current vertex state for the next push
- `primitive.hasColorAlpha` — fast path flag for "no transparency this primitive"

**Vertex array pointers** (used by `swDrawArrays`/`swDrawElements`):
- `array.positions`, `array.texcoords`, `array.colors`

**Drawing parameters**:
- `drawMode` — points, lines, triangles, quads
- `polyMode` — fill, line, point (controls whether triangles fill or just outline)
- `pointRadius`, `lineWidth`

**Matrix stacks**:
- `stackProjection`, `stackModelview`, `stackTexture` — fixed-size arrays
- `stackXxxCounter` — how deep each stack is
- `currentMatrixMode` — which stack `swPushMatrix` etc. operate on
- `currentMatrix` — pointer into the active stack
- `matMVP` — cached product of modelview × projection
- `isDirtyMVP` — flag set when either stack changes

**Resource pools**:
- `framebufferPool` — handle pool for off-screen render targets
- `texturePool` — handle pool for textures
- `boundFramebufferId`, `boundTexture` — currently-bound handles
- `colorBuffer`, `depthBuffer` — currently-active color/depth attachments

**Pipeline state**:
- `srcFactor`, `dstFactor`, `blendFunc`, `blendFlags` — blending
- `cullFace` — front/back face culling
- `errCode` — last error
- `userState` — bitmask of enabled features (texture, depth, blend, ...)
- `rasterState` — cleaned `userState` used to index the rasterizer
  dispatch table (only the bits that matter for kernel selection)

That's about 60 fields total.  Most are simple; a few (the matrix
stacks, the pools) are the meaty bits.

## 5.  Clipping in slightly more detail

The donor uses Sutherland-Hodgman against each plane, in sequence.
The clipping helper looks roughly like:

```
for each clip plane:
    output = []
    for each edge (v0, v1) in input polygon:
        d0 = signed_distance(v0, plane)
        d1 = signed_distance(v1, plane)
        if d0 >= 0 (inside):
            output.append(v0)
        if (d0 >= 0) != (d1 >= 0):  // edge crosses plane
            t = d0 / (d0 - d1)
            output.append(lerp_vertex(v0, v1, t))
    input = output
```

The `lerp_vertex` interpolates ALL vertex attributes — position,
color, texcoord — at parameter `t`.

For clip-space frustum culling, the planes are:
- `x ≥ -w` (left)
- `x ≤  w` (right)
- `y ≥ -w` (bottom)
- `y ≤  w` (top)
- `z ≥ -w` (near; some conventions use 0)
- `z ≤  w` (far)

The signed distance is just the dot product against the plane's
normal — for the left plane, `d = x + w`.

Scissor planes operate on screen space (after the perspective divide
and viewport transform).  Same algorithm, different coordinate
space.

## 6.  Texture sampling

Once we know we want to sample a texture at `(u, v)`:

**Wrap** — what to do for u or v outside [0, 1]:
- `repeat`: `u = u - floor(u)` (texture tiles)
- `clamp`: `u = clamp(u, 0, 1)` (edge color extends)

**Filter** — how to handle non-integer texel coords:
- `nearest`: round to nearest texel, fetch one pixel
- `linear` (bilinear): fetch 4 surrounding texels, weighted average
  by fractional offsets

**Format** — every texture has a format (RGBA8, R5G6B5, etc.).  Each
format has its own reader function: "given byte offset, give me a
[4]f32 RGBA".  Donor stores function pointers on the texture struct
and uses indirect calls.  We'll do the same — the dispatch space is
big (15+ formats), set rarely, read often.

## 7.  Blending

Blending combines the new pixel (`src`) with the existing one (`dst`)
in the framebuffer.  The recipe is:

```
result = src × srcFactor + dst × dstFactor
```

`srcFactor` and `dstFactor` are each one of about 11 values:
`zero`, `one`, `src_color`, `one_minus_src_color`, `src_alpha`,
`one_minus_src_alpha`, etc.  The most common combo is alpha blending:
`(srcFactor=src_alpha, dstFactor=one_minus_src_alpha)`, which gives
"draw new pixel with its alpha, fade old pixel by one minus".

There are 11 × 11 = 121 possible factor combinations, but in practice
you'll see a handful.  Donor implements all 121 via a 2D table of
function pointers; we'll do the same with comptime-built dispatch.

## 8.  Pools

Textures and framebuffers are addressed by handle (a `u32`).  The
pool allocates handles, validates them, and protects against
use-after-free with a generation byte:

```
each handle = (gen << 24) | (slot_index)

slot:
    gen     — 8-bit generation, high bit = "live"
    payload — the actual texture/framebuffer data
    next    — index of next free slot in free list
```

`gen` increments every time a slot is freed.  When you get a handle
back, the renderer checks the generation matches before using the
slot.  If it doesn't (slot was freed and reused), the handle is
invalid — return null.  Standard ABA-protection.

Free slots form a linked-list stack via the `next` field, so alloc
and free are O(1).

## 9.  Putting it together

A complete `swEnd` for triangles, in pseudocode:

```
function swEnd():
    if (drawMode == triangles && primitive.vertexCount == 3):
        clipped = clip_polygon(primitive.buffer[0..3])
        if clipped.count < 3: return  // fully off-screen
        for each tri in fan(clipped):
            transform_to_screen(tri)
            cull_test(tri)            // skip if back-facing and culling enabled
            dispatch_table[rasterState](tri)
    primitive.vertexCount = 0
```

The `dispatch_table[rasterState]` lookup picks one of 8 specialized
rasterizers based on `texture? depth? blend?`.  That rasterizer does
the work — sorts the verts by y, walks the edges, fills the spans,
runs the fragment ops.

## 10.  What raster is NOT

To set expectations:

- **No shaders.**  Fixed function only.  If you want programmable
  shading you're in the wrong renderer.
- **No mipmaps.**  Donor v1.5 doesn't support them.  We won't either.
- **No anisotropic filtering.**  Same.
- **No MSAA.**  Single-sample.
- **No instancing.**  One triangle at a time.
- **Single-threaded.**  No work parallelism.
- **No GPU acceleration.**  Pure CPU.  The "G" in OpenGL is doing a
  lot of work in the donor's name.
- **Limited texture formats.**  ~15 formats supported (the common
  ones); some donor enums map to internal formats that are *parsed
  but not implemented*.
- **No shader-based effects.**  No fragment shaders → no PBR, no
  bloom, no SSAO, none of that.

What it IS:

- A correct, tested, deterministic implementation of OpenGL 1.1
  triangle rendering.
- A tool for testing other renderers against.
- An educational artifact you can step through.
- Fast enough for low-resolution rendering on mid-range CPUs.

## 11.  The API in 30 seconds

Once the port is done, using raster will look like:

```zig
const raster = @import("raster.zig");

var ctx: raster.Context = try .init(gpa, .{ .width = 800, .height = 600 });
defer ctx.deinit(gpa);

ctx.matrixMode(.projection);
ctx.loadIdentity();
ctx.ortho(-1, 1, -1, 1, -1, 1);

ctx.matrixMode(.modelview);
ctx.loadIdentity();

ctx.clearColor(0, 0, 0, 1);
ctx.clear(.color_buffer_bit | .depth_buffer_bit);

ctx.begin(.triangles);
ctx.color3ub(255, 0, 0);
ctx.vertex2f(-0.5, -0.5);
ctx.color3ub(0, 255, 0);
ctx.vertex2f( 0.5, -0.5);
ctx.color3ub(0, 0, 255);
ctx.vertex2f( 0.0,  0.5);
ctx.end();

const pixels = ctx.colorBufferBytes();  // []u8 backing the canvas
// ... display pixels somewhere (upload as a GL texture, write to file, etc.)
```

The `colorBufferBytes` slice is the pixel output.  You can hand it
to a PNG encoder, upload it as a GL texture for live display, or
diff it against a reference image.

## 12.  Reading the porting plan

Now that you have the model, `raster-plan.md` should make sense.
Phases map to the subsystems above:

| Phase | Subsystem                              |
|-------|----------------------------------------|
| 0     | Skeleton                               |
| 1     | Public enums + constants               |
| 2     | Math helpers (matMul, lerp, fract)     |
| 3     | Internal types + Context               |
| 4     | Object pool                            |
| 5     | Pixel format read/write                |
| 6     | Texture + framebuffer                  |
| 7     | Blending                               |
| 8     | Projection + clipping                  |
| 9     | Rasterizer kernels (the big one)       |
| 10    | Per-primitive pipelines + immediate    |
| 11    | Public API                             |
| 12    | Cleanup + integration prep             |

Each phase ends with the audit gates and a save zip.  Each phase
ships something meaningful (math you can use; clipping you can
test; etc.) even before the renderer is functional end-to-end.

That's the tour.  Read `raster-plan.md` next for the execution
plan.
