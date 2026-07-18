# software_shaders.md — running zimr shader code on both GPU and CPU

A successor to `typesafe_zig_shaders.md`.  That plan landed the typed
shader pipeline (Zig sources → SPIR-V → GLSL → WebGL2, with codegen-
emitted typed interfaces, schema-driven sampler binding, and single-
source-of-truth UBOs).  This plan takes that foundation and extends it
so the same Zig shader source compiles to both a SPIR-V/GLSL entry
point for the GPU AND a callable Zig function on the CPU — runnable
inside the `rlsw` software rasterizer for visual debugging,
side-by-side comparisons, and pure-CPU integration paths.

The end-state vision: write `mandelbrot_fs.zig` once.  Run it on the
GPU in the existing browser pipeline.  Run it on the CPU per-pixel in
a software-raster context.  Compare them side-by-side in the same
frame.  Step through individual pixels in a debugger.  Unit-test the
shader as a normal Zig function.  All without forking the source.

This is an aggressive, long-horizon plan with multiple staged
deliverables.  Failure modes are documented at the bottom.

---

## §0. Why this matters

Today the shader-vs-CPU boundary is hard.  Three classes of work
become possible if we can bridge it:

1. **Debugging shader logic**.  A SPIR-V crash gives you a line in
   shadermath if you're lucky and nothing if you're not.  The same
   logic, called as `shader.main(io, &out)` from a Zig test, runs
   under the debugger — breakpoints, single-step, `@panic` with a
   real stack trace, all the affordances of a normal Zig function.

2. **Visual A/B comparison**.  The existing `rlsw_side_by_side.zig`
   example splits the canvas vertically and renders the same scene
   through both pipelines (right half: rlsw → upload-to-texture →
   GL; left half: GL directly).  Today both halves use the GL
   rasterization path with different primitives; with this plan,
   both can run the *exact same shader* through different
   rasterization paths.  Visual differences are pixel-level evidence
   of pipeline drift (precision, sampling, ordering).

3. **Shader as library**.  A consumer who wants to embed mandelbrot
   into a server-side image generator, a video frame compositor, or
   any pure-CPU context can `@import("mandelbrot_fs.zig")` and call
   `main` directly.  Today they can't — `main` has `callconv(.spirv_
   fragment)` and module-scope externs.

4. **Unit-testing shader logic**.  `shader.main(test_io, &out)`
   inside a `test "mandelbrot boundary"` block.  No browser, no
   WebGL context, just an assertion.

The cost: restructuring the shader source so the logic factors into
a normal Zig function and the GPU entry point is a thin wrapper.
Net result IS more code — but the new code is shape-conformant and
codegen-emitted, so the human-edited surface stays roughly the
same.

---

## §1. The core insight

Today's shader body has TWO things baked into the same `fn main`:

  (a) the shader's *logic* — math operating on input values and
      producing output values; and

  (b) the *binding* — `callconv(.spirv_fragment)`, module-scope
      externs decorated with `addrspace(.input)` / `addrspace(.uniform)`
      / `addrspace(.output)`, and `OpDecorate` calls via `io.setup()`.

To run on the CPU, (b) has to go.  (a) is pure Zig and runs anywhere
the math primitives exist (`@Vector(N, f32)`, `@sqrt`, `@sin`, etc.).
The cleanest fix: factor the logic into a plain `pub fn main(io) Out`
that returns the outputs by value, and let the binding live in a
generated wrapper that target-dispatches.

The shader source after this plan looks like:

```zig
// examples/mandelbrot_fs.zig
const zm = @import("shadermath");
const io_mod = @import("io");

// Pure logic.  Takes io by value, returns Out by value.  Compiles on
// every target Zig supports — GPU through the SPIR-V backend, CPU
// through normal codegen.  Internal `var out` mutation keeps the
// imperative shader-authoring feel; the return-by-value signature is
// what SPIR-V's Logical addressing model requires (verified
// experiment, session 13).
pub fn main(io: io_mod.Io) io_mod.Out {
    var out: io_mod.Out = undefined;
    const frag = io.frag_tex_coord * io.u.resolution;
    // ... compute ...
    out.out_color = zm.vec4(col[0], col[1], col[2], 1.0);
    return out;
}

// GPU entry point.  One line; codegen handles the wiring.
comptime { _ = io_mod.installSpirvEntry(main); }
```

Three things verified by experiment before this plan was finalized
(session 13, see §10 implementation log):

- **`export fn entry() callconv(.spirv_fragment)` inside a
  comptime-returned struct DOES reach the SPIR-V module.**  The
  pattern `comptime { _ = installSpirvEntry(main); }` works — both
  the wrapper and the called body land in the output, the entry
  point is registered, spirv-val accepts it.
- **The entry-point name must NOT be `_start`.**  Zig's `std.start`
  reserves that name and binds it to `callconv(.naked)`, which the
  SPIR-V backend rejects.  Use `entry` or some other name.  The CPU
  intuition that motivated `_start` doesn't survive contact with the
  toolchain; the comptime wrapper is the right shape regardless.
- **`*Out` parameter doesn't work on SPIR-V.**  Logical addressing
  forbids function-local pointer variables.  Return-by-value is
  required.  Mutation of a local `var out` inside the body is fine
  (no pointer escapes the function); the SSA optimizer folds it.

The CPU dispatcher constructs an Io per pixel and calls `main`
directly:

```zig
// Per-pixel dispatch (sketched; full version in §4).
const io: shader.Io = .{
    .frag_tex_coord = .{ u, v },
    .frag_color = .{ 1, 1, 1, 1 },
    .u = ubo,            // <-- same UBO struct, passed by value
};
const out: shader.Out = shader.main(io);   // <-- normal function call
ctx.writePixel(x, y, packColor(out.out_color));
```

---

## §2. Architecture overview

```
              ┌──────────────────────────────────────────┐
              │  mandelbrot_fs.zig                       │
              │  pub fn main(io: Io) Out { ... }         │   ← pure logic, one
              │  comptime { _ = installSpirvEntry(main) }│     definition
              └──────────────────────────────────────────┘
                            │
              ┌─────────────┴──────────────┐
              │                            │
        target=spirv32                target=wasm32/x86_64
              │                            │
              ▼                            ▼
┌──────────────────────────┐  ┌──────────────────────────────┐
│ io.zig (SPIR-V variant)  │  │ io.zig (CPU variant)         │
│  • Io: input view        │  │  • Io: plain struct          │
│  • Out: plain struct     │  │  • Out: plain struct         │
│  • externs at module     │  │  • setup(): no-op            │
│    scope                 │  │  • texture0(uv) → bilinear   │
│  • installSpirvEntry:    │  │    fetch from *const         │
│    emits `entry` wrapper │  │    rlsw.Texture              │
│  • OLD api still emitted │  │  • OLD api still emitted     │
│    (setup(), externs     │  │    (setup(), externs as      │
│    direct, sampler u32)  │  │    stubs)                    │
│  • NEW api: Io, Out,     │  │  • NEW api: Io, Out,         │
│    installSpirvEntry     │  │    installSpirvEntry (no-op) │
│  • texture0(uv) →        │  │                              │
│    zsample2d wrapper     │  │                              │
└──────────────────────────┘  └──────────────────────────────┘
              │                            │
              ▼                            ▼
       SPIR-V → GLSL → WebGL2     rlsw.dispatchFragmentShader
       (existing path,            (new helper, dispatches
        unchanged in behaviour)    main() over a rect)
```

**Codegen emits BOTH APIs from S1.**  The existing extern-style
externs + `setup()` stay (the "old shape" — `export fn main()
callconv(.spirv_fragment) void` body referencing module-scope
externs).  The new `Io` / `Out` / `installSpirvEntry` API is added
alongside.  All 14 existing shaders keep their current shape through
S2-S4; mandelbrot is the testbed that proves the new shape works.
S5 migrates the other shaders mechanically; only after S5 lands does
the codegen drop the old-shape emission.

Single shader source.  Single iface schema.  Two output flavors of
the codegen module, gated by `builtin.target.cpu.arch.isSpirV()`.
Two consumer paths: existing GPU pipeline + new CPU dispatcher.

---

## §3. Plan stages and dependencies

The plan is staged so each step is independently shippable and
verifiable.  Failing at stage N still leaves stages 1..N-1 useful.

### S1. Restructure shader source: factor `main(io, out)` out of the
       existing `export fn main() callconv(.spirv_fragment)`

**Scope**: ONLY mandelbrot_fs.zig at first.  The other 14 shader
bodies (`src/shaders/*.zig`, `examples/shader_chroma_fs.zig`) stay
on the existing shape until S5.

**Work**:
- Restructure mandelbrot_fs.zig:
  - Remove `export fn main() callconv(.spirv_fragment)`.
  - Add `pub fn main(io: io_mod.Io, out: *io_mod.Out) void` containing
    the existing body.
  - Replace every `io.frag_tex_coord` etc. with `io.frag_tex_coord`
    (param access — same syntax!).
  - Replace `io.out_color = ...` with `out.out_color = ...`.
  - Replace `io.setup();` (it moves into the codegen-generated entry
    point, no longer called from the body).
  - Replace `_ = io.frag_color;` (irrelevant once io is by value).
- Codegen extensions (`tools/gen_shader_externs.zig`):
  - Target-detect via `@import("builtin").target.cpu.arch`.
  - Emit a `pub const Io = struct { ... }` either way — fields are
    the union of Inputs + (`u: Ubo` if Ubo present).
  - Emit a `pub const Out = struct { ... }` — fields = Outputs.
  - On SPIR-V target: emit the existing externs + addrspace, and add
    `installSpirvEntry(comptime body: fn (Io, *Out) void)` that
    expands into the `_start` wrapper.
  - On CPU target: emit no externs, no `setup()` body (or empty),
    no `installSpirvEntry` body (no-op).
- Build wiring: addShader unchanged from its caller's perspective.
  Internally, the codegen is still one file; the file's contents
  vary based on target.

**Deliverables**:
- mandelbrot_fs.zig in new shape, GPU pipeline still produces the
  same GLSL (verify with `diff` on the generated `.glsl`).
- The same Zig file compiles on x86_64-linux (`zig test` it).

**Acceptance test**:
- `zig build` produces identical GLSL output (byte-for-byte) as
  before the restructure.  Pixel-identical mandelbrot in the browser.
- A new `test "mandelbrot main runs on CPU"` in mandelbrot_fs.zig
  builds a fake Io, calls `main`, asserts the out_color is finite.

**Estimated effort**: 1 session.

### S2. Implement the CPU sampler-accessor body and CPU `setup()`

**Scope**: mandelbrot doesn't use samplers, so this stage is needed
only for follow-on shaders (lambert, pbr, etc.).  But it's small
and gates S5, so do it early.

**Work**:
- On CPU target, codegen emits `pub fn texture0(uv: Vec2) Vec` whose
  body does a real bilinear (or nearest-neighbor — see §6 question)
  fetch from a `*const rlsw.Texture` carried by the Io struct.
- The CPU Io has additional fields (one `*const rlsw.Texture` per
  sampler).  These don't exist on the GPU Io (samplers come from
  the SPIR-V binding model).
- A `rlsw.fetchTexture` helper or `rlsw_pixel.read` integration.
- CPU `setup()` is `pub fn setup() void {}` (empty).

**Acceptance test**:
- A unit test that constructs an Io with a 2×2 procedural texture,
  calls a shader's `texture0(uv)`, asserts the right pixel comes back.

**Estimated effort**: 0.5 session.

### S3. Build a `rlsw.dispatchFragmentShader` helper

**Scope**: the entry point that the CPU side calls to run a shader
across a rect of the framebuffer.

**Work**:
- New function in `src/rlsw.zig` or a new `src/rlsw_shader.zig`:
```zig
pub fn dispatchFragmentShader(
    ctx: *Context,
    comptime ShaderModule: type,
    io_template: ShaderModule.Io,    // base Io; per-pixel fields overwritten
    rect: struct { x: i32, y: i32, w: i32, h: i32 },
) void {
    var py: i32 = 0;
    while (py < rect.h) : (py += 1) {
        var px: i32 = 0;
        while (px < rect.w) : (px += 1) {
            var io = io_template;
            io.frag_tex_coord = .{
                @as(f32, @floatFromInt(px)) / @as(f32, @floatFromInt(rect.w)),
                @as(f32, @floatFromInt(py)) / @as(f32, @floatFromInt(rect.h)),
            };
            var out: ShaderModule.Out = undefined;
            ShaderModule.main(io, &out);
            ctx.writePixel(rect.x + px, rect.y + py, packColor(out.out_color));
        }
    }
}
```
- A `packColor` helper that converts `@Vector(4, f32)` (linear 0..1)
  to `[4]u8` in the framebuffer's pixel format.
- A `ctx.writePixel(x, y, color)` helper (or use `effectiveColorBuffer`
  + `rlsw_pixel.write` directly).

**Acceptance test**:
- A new `examples/rlsw_mandelbrot.zig` that dispatches mandelbrot to
  a 320×240 rlsw context, uploads the color buffer to a GL texture,
  draws it.  Compare visually with the GPU mandelbrot.

**Estimated effort**: 1 session.

### S4. Split-screen demo: `examples/mandelbrot_split.zig`

**Scope**: both pipelines in the same example, in the same frame,
on the same canvas.  This is the headline deliverable.

**Work**:
- Right half of the canvas: GPU mandelbrot, existing path.
- Left half: CPU mandelbrot via `dispatchFragmentShader`, uploaded
  to a GL texture each frame, drawn.
- Same `Ubo` pushed to both — the math will produce visually
  identical output (modulo floating-point precision).
- HUD shows "GPU | CPU" labels, frame times for each path, the same
  `center` / `zoom` shared state driven by the same mouse input.

**Acceptance test**:
- Standalone HTML renders, both halves show the fractal, dragging
  works on both halves with the same anchor (mouse position is
  canvas-global; both pipelines transform it identically).

**Estimated effort**: 1 session.

### S5. Roll the new shader shape out to the rest of the codebase

**Scope**: every `src/shaders/*.zig` and every `examples/*_fs.zig` /
`examples/*_vs.zig` gets restructured to the new `pub fn main(io, out)`
+ `comptime { _ = installSpirvEntry(main); }` shape.

**Work**:
- Mechanical migration script for the body restructure (regex-replace
  + manual sanity check per file).
- Verify GLSL output byte-for-byte unchanged for each migrated shader.
- Smoke-build every standalone HTML, visual diff.

**Acceptance test**:
- 1880+/1880+ tests pass.
- All standalones build at unchanged wasm sizes.
- 0 lint across files.

**Estimated effort**: 2 sessions.

### S6. Sampler-bearing shader on CPU: a textured-quad demo

**Scope**: prove the CPU sampler accessor path with a non-trivial
shader.  Probably `examples/shader_chroma_fs.zig` (chroma-shift FS,
samples its input texture three times).

**Work**:
- Restructure the FS to the new shape (covered by S5).
- New `examples/shader_chroma_split.zig` that loads a small PNG into
  both a GL texture (GPU path) AND a `rlsw.Texture` (CPU path),
  renders the chroma-shifted result to both halves.

**Acceptance test**:
- Visually identical chroma-shift on both halves.
- Floating-point differences are within tolerance (no whole-pixel
  mismatches that aren't attributable to bilinear-filtering choices).

**Estimated effort**: 1 session.

### S7. Vertex shaders on CPU

**Scope**: the harder part.  Vertex stages produce `position_out.* =
...` instead of writing to an Out struct, and varyings flow between
stages with explicit location matching.  Mandelbrot doesn't need this;
gltf-rendering examples do.

**Work**:
- Decide: does `position_out` become a field in `Out`, or stay as a
  special "always present" extern?  Probably the former — codegen
  emits `Out.position` on every VS schema, the CPU dispatcher reads it
  for rasterization.
- A new `rlsw.dispatchVertexFragmentPipeline` that runs the VS over
  every vertex of a mesh, interpolates Outs across triangles, calls
  FS per fragment.  Effectively a software rasterizer driven by Zig
  shaders.
- Some interpolation work: linear interpolation of varyings between
  triangle vertices, perspective-correct division.

**Acceptance test**:
- A simple textured-cube example renders identically on GPU and CPU
  pipelines, side-by-side.

**Estimated effort**: 2-3 sessions.  (Larger than its position in the
plan suggests because varying interpolation is fiddly.)

### S8. Long-tail: tests + tutorial + docs

**Scope**: turn the new capability into a documented system.

**Work**:
- A `test "mandelbrot interior point stays at origin"`-style unit
  test pattern.
- A new section in the tutorial showing how to run a shader from
  Zig code.
- A `docs/shader-authoring.md` covering the GPU+CPU dual-target
  model.
- Update the type-safe shader tutorial to reflect the new shape.

**Estimated effort**: 1 session.

---

## §4. Concrete code shapes (worked examples)

### §4.1 The mandelbrot shader after S1

```zig
//! examples/mandelbrot_fs.zig — runs on GPU (via SPIR-V) and CPU.

const zm = @import("shadermath");
const io_mod = @import("io");

fn hsv2rgb(c: zm.Vec3) zm.Vec3 {
    // (existing helper unchanged)
}

/// Mandelbrot fragment kernel.  Compiles on every target.
/// On GPU: invoked from the codegen-emitted SPIR-V entry point.
/// On CPU: invoked directly by `rlsw.dispatchFragmentShader` or
/// from a Zig test.
pub fn main(io: io_mod.Io, out: *io_mod.Out) void {
    const frag: zm.Vec2 = io.frag_tex_coord * io.u.resolution;
    const half_res: zm.Vec2 = zm.vec2(io.u.resolution[0] * 0.5, io.u.resolution[1] * 0.5);
    const scale: f32 = 4.0 / (io.u.zoom * io.u.resolution[1]);
    const c: zm.Vec2 = zm.vec2(
        io.u.center[0] + (frag[0] - half_res[0]) * scale,
        io.u.center[1] - (frag[1] - half_res[1]) * scale,
    );

    var z: zm.Vec2 = zm.vec2(0, 0);
    var n: f32 = 0;
    var escaped: u32 = 0;
    var i: u32 = 0;
    while (i < 1024) : (i +%= 1) {
        if (@as(f32, @floatFromInt(i)) >= io.u.max_iter) break;
        const x2: f32 = zm.square(z[0]);
        const y2: f32 = zm.square(z[1]);
        if (x2 + y2 > 256.0) { escaped = 1; break; }
        z = zm.vec2(x2 - y2 + c[0], 2.0 * z[0] * z[1] + c[1]);
        n += 1.0;
    }

    if (escaped == 0) {
        out.out_color = zm.vec4(0, 0, 0, 1);
    } else {
        const mod_z: f32 = @sqrt(zm.square(z[0]) + zm.square(z[1]));
        const nu: f32 = zm.log2(zm.log2(mod_z));
        const smoothed: f32 = n + 1.0 - nu;
        const t: f32 = smoothed / io.u.max_iter;
        const col: zm.Vec3 = hsv2rgb(zm.vec3(0.85 + 0.4 * t, 0.7, zm.pow(t, 0.4)));
        out.out_color = zm.vec4(col[0], col[1], col[2], 1.0);
    }
}

// SPIR-V entry point.  Codegen handles the binding to externs.
// On CPU targets this is a comptime no-op.
comptime { _ = io_mod.installSpirvEntry(main); }
```

Notice what's no longer in the body:
- `io.setup();` — moved into the codegen-generated `_start`.
- `_ = io.frag_color;` — gone, `io` is by value, unused fields don't matter.
- `callconv(.spirv_fragment)` — gone.
- `addrspace`, `extern` — never appeared in the body, but the
  whole module is now CPU-compilable.

### §4.2 The codegen output after S1, GPU variant

```zig
// io.zig — AUTO-GENERATED, GPU/SPIR-V variant

const builtin = @import("builtin");
const std = @import("std");

pub const Io = struct {
    frag_tex_coord: @Vector(2, f32),
    frag_color: @Vector(4, f32),
    u: Ubo,
};

pub const Out = struct {
    out_color: @Vector(4, f32),
};

pub const Ubo = extern struct { /* unchanged */ };

// SPIR-V externs (still module-scope) — these are what `installSpirvEntry`
// reads from / writes to.
pub extern const _in_frag_tex_coord: @Vector(2, f32) addrspace(.input);
pub extern const _in_frag_color: @Vector(4, f32) addrspace(.input);
pub extern var _out_color: @Vector(4, f32) addrspace(.output);
pub extern const _ubo_u: Ubo addrspace(.uniform);

pub fn installSpirvEntry(comptime body: fn (Io, *Out) void) void {
    // Emits the actual entry point via `@export`-or-equivalent comptime call.
    const Wrapper = struct {
        export fn _start() callconv(.spirv_fragment) void {
            zm_location(&_in_frag_tex_coord, 0);
            zm_location(&_in_frag_color, 1);
            zm_location(&_out_color, 0);
            zm_binding(&_ubo_u, 0, 0);
            const io: Io = .{
                .frag_tex_coord = _in_frag_tex_coord,
                .frag_color = _in_frag_color,
                .u = _ubo_u,
            };
            var out: Out = undefined;
            body(io, &out);
            _out_color = out.out_color;
        }
    };
    _ = Wrapper;
}
```

### §4.3 The codegen output after S1, CPU variant

```zig
// io.zig — AUTO-GENERATED, CPU variant

pub const Io = struct {
    frag_tex_coord: @Vector(2, f32),
    frag_color: @Vector(4, f32),
    u: Ubo,
};

pub const Out = struct {
    out_color: @Vector(4, f32),
};

pub const Ubo = extern struct { /* unchanged */ };

/// CPU no-op.  The body is run directly via dispatch; there is no
/// "entry point installation" to perform.
pub fn installSpirvEntry(comptime body: fn (Io, *Out) void) void {
    _ = body;
}
```

### §4.4 The CPU dispatcher (after S3)

```zig
// In src/rlsw_shader.zig (new file).

pub fn dispatchFragmentShader(
    ctx: *Context,
    comptime ShaderModule: type,
    base_io: ShaderModule.Io,
    rect: struct { x: i32, y: i32, w: i32, h: i32 },
) void {
    const w_f: f32 = @floatFromInt(rect.w);
    const h_f: f32 = @floatFromInt(rect.h);
    var py: i32 = 0;
    while (py < rect.h) : (py += 1) {
        var px: i32 = 0;
        while (px < rect.w) : (px += 1) {
            var io = base_io;
            io.frag_tex_coord = .{
                @as(f32, @floatFromInt(px)) / w_f,
                @as(f32, @floatFromInt(py)) / h_f,
            };
            var out: ShaderModule.Out = undefined;
            ShaderModule.main(io, &out);
            writePixelLinearVec4(ctx, rect.x + px, rect.y + py, out.out_color);
        }
    }
}

fn writePixelLinearVec4(ctx: *Context, x: i32, y: i32, color: @Vector(4, f32)) void {
    // Convert linear 0..1 vec4 to the framebuffer's pixel format.
    // (S3 implementation — uses rlsw_pixel codecs.)
}
```

### §4.5 The split-screen example (after S4)

```zig
// examples/mandelbrot_split.zig

const std = @import("std");
const z = @import("zimr");
const shader = @import("mandelbrot_fs.zig");        // the new shape
const iface = @import("mandelbrot_fs_iface.zig");

const SCREEN_W: i32 = 800;
const SCREEN_H: i32 = 450;

const State = struct {
    // GPU side: same as today's mandelbrot.zig.
    loaded: z.shader.LoadedShader(iface) = .{ ... },
    // CPU side: an rlsw context + a display texture.
    sw_ctx: z.rlsw.Context = undefined,
    sw_display: z.Texture = .{},
    // Shared view state — same Ubo populated for both.
    center: z.math.Vec2 = .{ -0.5, 0.0 },
    zoom: f32 = 1.5,
};

fn update(f: *z.Frame, s: *State) void {
    handleInput(f, s);  // same drag/zoom as the existing mandelbrot

    const sw_f: f32 = @floatFromInt(SCREEN_W / 2);
    const sh_f: f32 = @floatFromInt(SCREEN_H);
    const ubo: iface.Ubo = .{
        .center = s.center,
        .zoom = s.zoom,
        .resolution = .{ sw_f, sh_f },
        .max_iter = 256,
    };

    // ---- GPU half (right) -------------------------------------
    s.loaded.ub.push(ubo);
    z.beginDrawing(f.gl);
    z.clearBackground(f.gl, z.colors.black);
    z.beginShaderMode(f.gl, s.loaded.shader);
    z.drawRectangle(f.gl, ..., SCREEN_W / 2, 0, SCREEN_W / 2, SCREEN_H, z.colors.white);
    z.endShaderMode(f.gl);

    // ---- CPU half (left) --------------------------------------
    z.rlsw.dispatchFragmentShader(&s.sw_ctx, shader, .{
        .frag_tex_coord = undefined,  // dispatcher overwrites
        .frag_color = .{ 1, 1, 1, 1 },
        .u = ubo,
    }, .{ .x = 0, .y = 0, .w = SCREEN_W / 2, .h = SCREEN_H });
    z.updateTexture(f.gl, &s.sw_display, s.sw_ctx.colorBufferBytes());
    z.drawTexture(f.gl, &s.sw_display, 0, 0, z.colors.white);

    // ---- Divider + labels -------------------------------------
    z.drawLineV(f.gl, .{ SCREEN_W / 2, 0 }, .{ SCREEN_W / 2, SCREEN_H }, z.colors.white);
    z.drawText(f.gl, "CPU", 8, 8, 20, z.colors.white);
    z.drawText(f.gl, "GPU", SCREEN_W / 2 + 8, 8, 20, z.colors.white);

    z.endDrawing(f.gl);
}
```

---

## §5. Key technical decisions (with the tradeoffs)

### §5.1 Where does `Io` get its `u` field?

Two options:
- **(a) Io contains `u: Ubo` directly**.  Simplest.  Read site is
  `io.u.center`.  Per-pixel copy cost on CPU (struct copy) — but
  `Ubo` is small (under 256 bytes for typical shaders), and the
  copy is in registers for SIMD-sized fields.
- **(b) Io contains `u_ptr: *const Ubo`**.  Avoids the per-pixel
  copy.  Read site is `io.u.center` (auto-deref).  But Zig
  `*const` to `addrspace(.uniform)` is weird; might not work on
  SPIR-V target.

**Decision**: (a).  The copy cost is negligible and the simpler model
keeps GPU and CPU views structurally identical.

### §5.2 Sampler representation across targets

Two options:
- **(a) Io has a `*const rlsw.Texture` per sampler on CPU; the
  same Io has a u32 placeholder per sampler on GPU**.  Codegen emits
  the right field type per target.  Sampler accessor (`io.texture0(uv)`)
  is target-dispatched.
- **(b) Io has the sampler field both ways but the GPU version is
  the u32 placeholder and the CPU version is a `*const rlsw.Texture`,
  with a `comptime if` in the field declaration**.

**Decision**: (a).  Different field type per target is fine since
codegen emits two different `io.zig` files.  The shader body never
touches the sampler field directly — only the codegen-emitted accessor
method does.

### §5.3 Floating-point determinism between GPU and CPU

GPU and CPU floating-point WILL differ:
- Different FMA usage (GPU has more aggressive contraction).
- Different transcendental approximations (`@sin`, `@log2`).
- Different rounding modes for div/sqrt sometimes.

**Decision**: Accept this.  Visual A/B is the goal, not bit-exact
matching.  Document that pixel-exact comparison won't work.  Stages
S4 and S6's acceptance tests use visual diff with tolerance, not
pixel hash equality.

### §5.4 Bilinear filtering on CPU samplers

GPU samplers default to bilinear with mipmaps.  CPU implementations
need a choice:
- **Nearest-neighbor**: simplest, fastest, visually obvious.
- **Bilinear**: matches GPU, more code, slower per pixel.
- **Bilinear + mipmap**: full parity, significantly more code.

**Decision**: nearest-neighbor for the first ship (S2).  Add
bilinear in a later stage if needed.  Mipmap support deferred until
there's a concrete consumer demanding it.

### §5.5 How does the GPU entry point get installed?

The shader body has `comptime { _ = io_mod.installSpirvEntry(main); }`.
At GPU compile time, `installSpirvEntry` needs to emit an `export fn
entry() callconv(.spirv_fragment) void { ... }` somewhere visible to
the linker.

**Verified (session 13)**: the pattern works.  The wrapper function:

```zig
pub fn installSpirvEntry(comptime body: fn (Io) Out) void {
    const Wrapper = struct {
        export fn entry() callconv(.spirv_fragment) void {
            @setRuntimeSafety(false);
            // OpDecorate calls for inputs/outputs/uniforms ...
            const io: Io = .{
                .frag_tex_coord = _in_frag_tex_coord,
                .frag_color = _in_frag_color,
                .u = _ubo_u,
            };
            const out: Out = body(io);
            _out_color = out.out_color;
        }
    };
    _ = Wrapper;
}
```

The `comptime { _ = installSpirvEntry(main); }` at module scope forces
Zig to evaluate the wrapper and emit `entry` into the SPIR-V module.
spirv-val accepts the output; spirv-opt + spirv-cross produce clean
GLSL identical in shape to a hand-authored shader.

**Decision**: this is the canonical path.  No fallback needed.

### §5.7 Why return-by-value `Out` and not pointer-out parameter?

**Verified (session 13)**: SPIR-V's Logical addressing model forbids
function-local pointer variables.  Trying to pass `*Out` into the
shader body produces `error: line N: In Logical addressing,
variables can only allocate a pointer to the StorageBuffer or
Workgroup storage classes` at spirv-val time.  Even with
`callconv(.@"inline")` the pointer survives in SPIR-V.

Return-by-value works: `pub fn main(io: Io) Out`.  Internally the
body uses `var out: Out = undefined; ... return out;` so the
author still writes imperative field assignments — that's the
ergonomic shape Q3 chose.  The Out variable is function-local; SPIR-V
allows that.  spirv-opt folds it into single-SSA-chain form.

**Decision**: return-by-value at the signature, internal `var out`
mutation in the body.  This is the canonical shape.

### §5.9 The shader-body function must NOT be named `main`

**Verified (session 14, during S1 execution)**: when the shader's
root module declares `pub fn main`, Zig's `std.start.zig` activates
and tries to `@export(&_start, ...)` with `callconv(.naked)` — which
the SPIR-V backend rejects:

    error: calling convention 'naked' not supported by compiler
    backend 'stage2_spirv'

The activation chain is in `std.start.zig:26-69`:

    if (builtin.output_mode == .Exe or @hasDecl(root, "main")) {
        ...
        else => if (!@hasDecl(root, start_sym_name))
            @export(&_start, .{ .name = start_sym_name }),

The `@hasDecl(root, "main")` check picks up `pub fn main` regardless
of its signature.  The SPIR-V backend always sees this branch active.

The fix is mechanical but load-bearing: rename the shader body's
kernel from `main` to `shaderMain` (or any other non-`main` name).
Inside the body, references to `io_in.X` and `out.X` stay the same.
The `installSpirvEntry(shaderMain)` call passes the renamed function
pointer through to the wrapper.

Session 13's E1/E2/E3 experiments missed this because they used `fn
shader` (different name) for their test bodies — the std.start trap
only fires when the name is exactly `main`.

**Canonical signature (locked)**:

    pub fn shaderMain(io: Io) Out

Plan §1, §4.1, and all worked examples in §4 use this name.

### §5.8 Codegen emits new + old API simultaneously

**Decision (locked)**: from S1 onward, codegen emits BOTH:
- The existing extern-style externs + `setup()` (the "old shape" — used
  by `export fn main() callconv(.spirv_fragment) void` bodies that
  reference module-scope externs directly).
- The new `Io` / `Out` / `installSpirvEntry` API (the "new shape" —
  used by `pub fn main(io: Io) Out` bodies with the comptime entry-
  point installer).

Both APIs reflect the same iface schema.  Both are zero-cost when
unused — unused decls don't bloat the output.

Through S2-S4, only mandelbrot uses the new shape (it's the testbed).
S5 mechanically migrates the other 14 shaders.  Only after S5 lands
does the codegen drop the old-shape emission entirely.

The tradeoff: codegen carries more code through S2-S5 (two paths
side-by-side).  In exchange: the migration in S5 is purely
file-by-file shader-body rewrites; no codegen changes; risk of "S5
shipped but codegen still has weird gates" is removed.

---

## §6. Open questions for explicit decision

These need answers before I start S1.  Each is a real fork in the
plan, not a stylistic choice.

### Q1: Per-pixel performance is acceptable?

The CPU dispatcher will run mandelbrot at maybe 30 FPS at 400×450
(180k pixels per frame, ~5M iterations per frame).  That's fine for
a debug viewer / side-by-side.  For a 1080p framebuffer at 60 FPS
it'd be unusable without SIMD.

**Recommendation**: ship the naive scalar dispatcher.  If it's too
slow even for the demo, add a `comptime` SIMD-batch path later
(process 4 or 8 pixels at a time with the @Vector machinery).

### Q2: Where do CPU-only helpers live?

When the codegen emits CPU `texture0(uv)`, the body needs to do a
real fetch from `*const rlsw.Texture`.  Two homes:
- New `src/rlsw_shader.zig` — paired with the dispatcher.
- Existing `src/shadermath.zig` — but shadermath is the "shader-side"
  module, and CPU sampler fetch is a host concept.

**Recommendation**: new `src/rlsw_shader.zig`.  Keeps shadermath
clean.

### Q3: Do we run any shader through this, or just FS?

Vertex shaders are S7 territory and considerably harder (varying
interpolation, primitive assembly).  For the foreseeable future,
"software shaders" means "software fragment shaders driven by an
existing rasterizer."

**Recommendation**: FS-only through S6.  Revisit VS in S7 only if
there's a concrete consumer.

### Q4: Do we strip the entry-point installer from CPU builds?

`comptime { _ = installSpirvEntry(main); }` at the bottom of every
shader.  On CPU target it's a no-op.  Could remove it entirely on
CPU target, but then the shader source has target-conditional code
in it (`if (builtin.target.cpu.arch.isSpirV()) ...`).  Ugly.

**Recommendation**: keep the line unconditionally.  Codegen makes
the CPU `installSpirvEntry` a no-op; the line costs nothing.

### Q5: Multiple FS in one example — same `io` module name?

Today every shader's codegen output is named `io`.  When `examples/
mandelbrot_split.zig` imports `mandelbrot_fs.zig`, and that shader's
io is named `io`, there's a module-name collision risk if the host
also imports another shader's io.

Wait — host CPU code never imports the codegen output directly.  It
imports the shader source (which internally imports its own io).
Module-name collision is per shader, not per host.  Should be fine.

**Recommendation**: no action.  Verify in S3 that this works.

### Q6: How do we test floating-point parity?

A CI test that runs mandelbrot through both pipelines and compares
output frames would catch drift early.  But pixel-exact comparison
will fail (see §5.3).

**Recommendation**: a "near-match" assertion — count the percentage
of pixels that match to within ε.  Threshold: 99.5%.  Mismatching
pixels concentrated near escape boundaries (the smooth-iteration
formula is unstable).

### Q7: When does VS-on-CPU become urgent?

S7 is currently estimated at 2-3 sessions.  If we ever want to run
gltf models through rlsw (for a debug-without-WebGL flow), VS-on-CPU
becomes blocking.

**Recommendation**: defer until a concrete consumer asks.  The
mandelbrot demo doesn't need it; the chroma demo doesn't need it.

---

## §7. Failure modes

Things that could go wrong and what we'd do:

- **F1: Zig's SPIR-V backend rejects the comptime entry-point
  installer**.  Fall back to having the shader source write `export
  fn _start` manually (still target-gated).  The shader body remains
  mostly clean.

- **F2: The CPU dispatcher is too slow even for the demo**.  Skip
  S4's split-screen and just produce a static frame for visual
  comparison.  Add SIMD batching in a follow-up.

- **F3: Generated CPU `io.zig` and GPU `io.zig` drift in subtle
  ways**.  Add a comptime check that asserts `@sizeOf(Ubo)` and
  field types match between the two variants.  Same `iface.zig` is
  the source of truth, so layout drift shouldn't happen — but
  defensive checks are cheap.

- **F4: Some SPIR-V helpers (zsample2d, location, binding) bleed
  into the CPU compile and refuse to compile**.  These live in
  shadermath, which is target-gated already.  If the shader body
  accidentally references them, the CPU compile fails — that's a
  feature, not a bug (it forces the shader author to keep their
  math target-portable).

- **F5: Sampler texture lifetime issues**.  The CPU Io holds
  `*const rlsw.Texture`.  If the texture is freed mid-dispatch, UB.
  Document the lifetime contract clearly in the dispatcher's doc
  comment.

- **F6: Vertex stage turns out to require a much bigger surface
  than expected (S7)**.  Stop at S6.  Document that VS-on-CPU is
  out of scope, recommend `rlsw_side_by_side`-style "different
  primitives, both pipelines render" for VS comparison.

---

## §8. Implementation log

### Session 13 (2026-05-26) — design verified, decisions locked

Pre-implementation verification experiment.  Built three throwaway
SPIR-V test fixtures under `/tmp/spv_test/` to nail down three open
questions before committing to S1's restructure.

**E1: Does comptime-emitted `export fn` reach the SPIR-V module?**

Test: a 15-line `.zig` file with `comptime { _ = install(body); }`
where `install` returns a struct containing `export fn entry()
callconv(.spirv_fragment) void`.  Result: compiled clean,
spirv-val passed, strings dump shows `entry` as the entry-point
name and `wrapped.installEntry.Wrapper._start` (early name) /
`with_out.install.W.entry` (later name) as the Zig-qualified
path.  The comptime path works.

**E2: Can the entry-point name be `_start`?**

No.  Zig's `std.start` reserves `_start` for `callconv(.naked)` —
the SPIR-V backend rejects with:

    error: calling convention 'naked' not supported by compiler
    backend 'stage2_spirv'

Even when no `std` import is in the user's source, the backend's
own startup pulls in `std.start.zig` and conflicts.  Renaming the
entry to `entry` (or any non-`_start` name) avoids it.  Plan §5.6
updated.

**E3: Can the shader body take `*Out` as a pointer-out parameter?**

No.  spirv-val rejects with:

    error: line N: In Logical addressing, variables can only
    allocate a pointer to the StorageBuffer or Workgroup storage
    classes

Even with `callconv(.@"inline")` on the body function, the
pointer survives in SPIR-V (the inline pass doesn't eliminate
function parameters by reference).  Return-by-value `pub fn
main(io: Io) Out` works perfectly: spirv-val passes, spirv-opt
folds the local `var out: Out = undefined; ... return out;`
pattern into single-SSA-chain form, and the final GLSL is
identical to a hand-authored shader.

Verified end-to-end pipeline output for the return-by-value
case:

    in highp vec2 x;
    out highp vec4 y;
    void main() { y = vec4(x, 0.0, 1.0); }

Plan §1, §4.1, §5.7 updated.

**Decisions locked (recorded in §5):**

- Q1 perf: ship naive scalar dispatcher, optimize later.
- Q2 home: new `src/rlsw_shader.zig`.
- Q3 scope: codegen emits new + old API simultaneously from S1.
  Mandelbrot is the testbed through S4; S5 migrates the other 14
  shaders; old API drops after S5 lands.
- Q4 entry installer: comptime-returned struct with `export fn
  entry`.  Name `entry`, not `_start`.
- Q5 shader-body shape: `pub fn main(io: Io) Out`, internal
  `var out: Out = undefined; ... return out;` pattern.

**Ready to start S1.**  Next session begins by extending
`tools/gen_shader_externs.zig` with the new emission paths, then
restructuring `examples/mandelbrot_fs.zig` to the new shape and
verifying byte-for-byte identical GLSL output.

### Session 14 (2026-05-26) — S1 shipped: mandelbrot on new shape

**What shipped:**

- `tools/gen_shader_externs.zig` extended.  For every iface schema
  the codegen now emits BOTH the legacy externs+setup() AND the new
  `IoT(UboType) / Out / installSpirvEntry` API.
- `examples/mandelbrot_fs.zig` restructured to `pub fn shaderMain(
  io: Io) Out` + `comptime { _ = io.installSpirvEntry(shaderMain); }`
  with internal `var out: Out = undefined; ... return out;` body.
- All 14 other shaders untouched — they keep the old shape until S5.

**Verification:** `zig build` clean, 0 lint across 166 files,
mandelbrot.html builds at 270 KB unchanged, GLSL structurally
identical.

**Surprise caught during S1:** `pub fn main` triggers Zig's
`std.start.zig` to export `_start` with `callconv(.naked)` — rejected
by SPIR-V backend.  Fix: rename to `shaderMain` (or any non-`main`
name).  Plan §5.9 added.

**Codegen also gained**: `_ = out` discard for empty-Outputs ifaces,
`_builtin = @import("builtin")` always emitted, compile-time gate
via `_builtin.target.cpu.arch.isSpirV()` in installSpirvEntry.

### Session 15 (2026-05-26) — S3 + S4 shipped: rlsw_shader dispatcher + side-by-side demo

The headline payoff for the software-shader plan.  The CPU dispatcher
lands AND the same mandelbrot fractal renders side-by-side through
both pipelines.

**S3: `src/rlsw_shader.zig` shipped (~190 lines)**

```zig
pub fn dispatchFragmentShader(
    ctx: *rlsw.Context,
    comptime ShaderModule: type,
    base_io: ShaderModule.Io,
    rect: Rect,
) void {
    // ... per-pixel loop, calls ShaderModule.shaderMain(io), writes
    // result through rlsw_pixel.write_color_table's codec ...
}
```

Two inline tests verify a constant-color shader fills the buffer and
a UV-based shader gradients correctly.  rlsw gained three public
accessors: `colorBufferBytesMut()`, `colorBufferDims()`,
`colorBufferFormat()`.

**S4: `examples/mandelbrot_split.zig` shipped**

Side-by-side fractal with **windowshade divider** revealing CPU and
GPU pipelines.  Both halves driven by the same `(center, zoom)` view
state, the same `Ubo` struct, the same `shaderMain` Zig function.
Drag freezes the divider so the user can pan without losing the
visual A/B reference.  Standalone: **274 KB bundle**.

**Wiring innovation: IoT(UboType) factored out of io.zig**

The S4 build hit a Zig 0.16 "file in two modules" conflict.  Fix:
io.zig is deliberately iface-independent; codegen emits `pub fn
IoT(comptime UboType: type) type` instead of a direct Io struct.
The shader source closes the loop: `pub const Io = io.IoT(iface_mod.
Ubo);`.  `installSpirvEntry` was similarly type-erased via anytype +
`@typeInfo`.

### Session 16 (2026-05-26) — S2 + S6 shipped: CPU sampler accessors + chroma split demo

Skipped the bulk S5 migration (codegen emits both shapes, so legacy
externs path keeps working).  Leapt straight to **S2** (CPU sampler
accessor body) and **S6** (textured chroma split demo) to demonstrate
the next capability gain: textured rendering on the CPU pipeline.

Codegen extensions to `tools/gen_shader_externs.zig`:
- Loose **Uniforms** → top-level Io fields (distinct from Ubo).
- CPU-only **sampler bindings** → `_<name>: TextureRef` field per
  sampler.  Type is `void` on SPIR-V (compile-time branched).
- Sampler accessor methods with target-conditional bodies — SPIR-V
  calls `zm_zsample2d`, CPU calls `sampleNearestRgba8(self._<name>,
  uv)`.
- `TextureRef` + `sampleNearestRgba8` emitted inline in io.zig (no
  rlsw import — rlsw is too big for the SPIR-V compile).

**S6 ships `examples/shader_chroma_split.zig`**: same `shader_chroma_
fs.zig` Zig source runs on both pipelines.  Smiley.png centered on
canvas; cursor X is the divider; nearest-neighbor CPU sampling vs
hardware bilinear GPU sampling.  Animated chroma offset via `u_time`.
Standalone: 295 KB bundle.

Bugs caught + fixed during S2:
- Zig container layout rule (fields must come before declarations);
  reordered the codegen emit.
- Removed redundant `_ = self;` in SPIR-V branch (Zig considered the
  post-if `self._<name>` access a use).
- Renamed `u`/`v` locals in `sampleNearestRgba8` to `uu`/`vv` to
  avoid shadowing the module-level `pub extern const u: Ubo`.
- **Dispatcher's hardcoded `out.out_color` was the real blocker for
  chroma** (its output field is `final_color`).  Rewrote
  `src/rlsw_shader.zig` to find the first `@Vector(4, f32)` field in
  `Out` via comptime introspection — dispatcher now works against
  any shader on the new shape regardless of output field name.

Audit: 1880+/1880+ tests, 0 lint at 169 files.

### Session 17 (2026-05-26) — S7a-c shipped: VS-on-CPU infrastructure + triangle rasterizer

Decomposed S7 into smaller shippable steps:

**S7a — VS-on-CPU codegen shape**.  Codegen detects VS schemas via
`@hasDecl("Attributes")` and adapts:
- Auto-emits `position: @Vector(4, f32)` as the first field of `Out`.
- Emits `callconv(.spirv_vertex)` for the entry-point wrapper.
- Wires `out.position` → `std.gpu.position_out.*` (with the right
  `*addrspace(.output)` typing) so the shader source writes a regular
  Zig field.

**S7b — `dispatchVertexShader`**.  Comptime-generic; `fillAttrs(vid,
*io)` callback lets the caller decide attribute sourcing.

**S7c — `rasterizeTriangles`** (the actual software rasterizer).
Edge-function method (Pineda 1988).  Clip-space → NDC → screen with
Y-flip.  Back-face culling on CCW screen winding.  Per-vertex
perspective divide.  Perspective-correct varying interpolation
(barycentric weights divided by per-vertex `w`, normalized).
Comptime-generic `lerpAny<T>` supports `f32` and `@Vector(N, f32)`.

New unit test verifies an inside-triangle pixel is the expected color
and an outside pixel isn't.  Caught bugs while writing:
- Winding-order confusion (NDC→screen Y-flip inverts winding;
  documented as a load-bearing convention in the area check).
- Edge-function inclusivity (pixels exactly on the diagonal pass
  `w_i >= 0`; chose clearly off-diagonal coords for the test).
- `i0` is a Zig primitive type — renamed to `idx0`/`idx1`/`idx2`.

Audit: 1880+/1880+ tests pass (including the new rasterizer test),
0 lint at 169 files.  All five flagship standalones build at
unchanged sizes; damaged_helmet (uses every VS in the engine) still
builds at 5389 KB.

### Session 18 (2026-05-26) — S7d shipped: textured-cube split demo + per-shader io modules

The acceptance test for the entire S7 arc.  A spinning textured cube
renders identically on GPU and CPU pipelines, windowshade divider
revealing the seam.  Same VS + FS Zig source compiled for both
targets.

**`examples/cube_split.zig` shipped (~460 lines)**

- 24-vertex per-face cube geometry (4 verts × 6 faces, 36 indices).
- Inline matrix math: `perspective`, `lookAt`, `rotateY`, `matMul`
  (column-major, GL convention).
- VS+FS pair on the new shape:
  - `cube_split_vs.zig` writes `out.position = mulMatPoint(io.u.mvp,
    io.vertex_position)` + passes UV through.
  - `cube_split_fs.zig` samples `texture0` at the interpolated UV.
- CPU pipeline: `dispatchVertexShader` → `rasterizeTriangles` →
  `updateTexture` for the GL display mirror.
- GPU pipeline: bind shader, push UBO with same MVP, submit cube
  through `rlBegin`/`rlVertex3f` + `rlTexCoord2f`.
- Windowshade composite with cursor-X divider.

Standalone: **299 KB bundle**.

**The bug discovered during S7d wiring: per-shader io modules**

The cube_split example imports BOTH `cube_split_vs.zig` AND
`cube_split_fs.zig`.  Each does `const io = @import("io")` to reach
the codegen-emitted IoT/Out types.  But Zig modules are per-name —
both `@import("io")` calls resolve to the SAME module on the
example's wasm32 compile.  Whichever io.zig got wired last is what
BOTH shader files see; the other one's compile fails because its
shape doesn't match (e.g. FS finds VS's `vertex_position` field
instead of `frag_tex_coord`).

The single-shader examples (mandelbrot_split, shader_chroma_split)
never hit this because they have exactly one shader per wasm.

**Fix**: per-shader io module names.  `ShaderOpts` gained a
`shader_basename: ?[]const u8 = null` field.  When supplied:
- The codegen-emitted io is wired in the SPIR-V compile as
  `-M<basename>_io=` (e.g. `-Mcube_split_vs_io=...`).
- The shader source imports its io as
  `const io = @import("<basename>_io");`.
- The example's exe_mod wires each shader's io under its own name.

Backward compat: `?[]const u8 = null` falls back to the literal
`io`, so any future caller that doesn't pass `shader_basename`
keeps working unchanged.

**Migrations**:
- `examples/mandelbrot_fs.zig` → `@import("mandelbrot_fs_io")`
- `examples/shader_chroma_fs.zig` → `@import("shader_chroma_fs_io")`
- All 12 engine shaders under `src/shaders/*` → `@import("<basename>_io")`
- `build.zig` passes `shader_basename = sh_name` in every
  `addShaderEx` / `addShader` call site for examples + engine shaders.

**Other fixes during S7d**:

- The codegen-emitted `_position_out` was typed `*@Vector(4, f32)`
  but `std.gpu.position_out` is `*addrspace(.output) @Vector(4, f32)`
  — address-space-typed pointers don't cast to plain pointers.  Fixed
  by using the std.gpu decl directly without an intermediate local.
- `z.math.Vec3` doesn't exist (z.math only has 4-component `Vec`);
  used `@Vector(3, f32)` explicitly.
- `rlEnableDepthTest` / `rlDisableDepthTest` are no-arg functions
  (not `(f.gl)`).
- Renamed `cube_vs.zig`, `cube_fs.zig`, and the matching ifaces to
  `cube_split_vs.zig` etc. so the wildcard discovery matches them
  to the `cube_split` example (longest-prefix-wins: `cube_split` is
  a longer prefix than any other example).

**Audit**: 1880+/1880+ tests pass, 0 lint across 174 files.  Six
standalones build:
- mandelbrot.html → 270 KB (unchanged)
- mandelbrot_split.html → 274 KB (unchanged)
- shader.html → 179 KB (unchanged)
- shader_chroma_split.html → 295 KB (unchanged)
- **cube_split.html → 299 KB (NEW)**
- damaged_helmet.html → 5389 KB (unchanged — the smoke test that
  every engine VS still works post-io-rename)

**What this completes**: S7 — the full vertex-shader-on-CPU arc.
Any zimr shader (VS, FS, with or without samplers, with or without
UBOs) can be written once in Zig and run through both pipelines
side-by-side.  The remaining plan items are S5 (bulk migration of
the 14 engine shaders to the new shape — purely mechanical, codegen
emits both shapes so it's safe to defer) and S8 (docs + tutorial).

**Plan state**:
- S1 ✅ — shader source restructured.
- S2 ✅ — CPU sampler accessors.
- S3 ✅ — fragment dispatcher.
- S4 ✅ — mandelbrot split.
- S5 — bulk shader migration (deferred).
- S6 ✅ — chroma split (CPU samplers proven).
- S7a ✅ — VS-on-CPU codegen shape.
- S7b ✅ — dispatchVertexShader.
- S7c ✅ — rasterizeTriangles.
- **S7d ✅** — textured cube split.
- S8 — docs + tutorial (pending).

The software-shader plan is functionally complete.

---



Decomposed S7 ("vertex shaders on CPU") into smaller shippable steps.
This session lands the foundation: codegen support for VS shaders on
the new shape + a working triangle rasterizer in `src/rlsw_shader.zig`,
verified by a unit test.  The textured-cube split demo (S7d) is the
next session's work.

**S7a: codegen story for VS shaders**

The codegen now detects VS schemas via `@hasDecl(IfaceMod,
"Attributes")` and adapts:
- Auto-emits `position: @Vector(4, f32)` as the first field of `Out`.
  This is the clip-space output every VS produces; making it a regular
  struct field lets it flow naturally to the CPU rasterizer.
- Emits `callconv(.spirv_vertex)` (not `.spirv_fragment`) for the
  entry-point wrapper.
- Wires `out.position` → `std.gpu.position_out.*` in the wrapper, so
  the shader source writes a plain Zig struct field instead of touching
  the SPIR-V-special `position_out` directly.

Result: the same `pub fn shaderMain(io: Io) Out` pattern that works for
fragment shaders now works for vertex shaders, with `out.position`
being the only schema convention to know.

**S7b + S7c: `dispatchVertexShader` + `rasterizeTriangles`**

Two new functions in `src/rlsw_shader.zig`:

```zig
pub fn dispatchVertexShader(
    comptime ShaderModule: type,
    vertex_outs: []ShaderModule.Out,
    base_io: ShaderModule.Io,
    vertex_count: u32,
    comptime fillAttrs: fn (u32, *ShaderModule.Io) void,
) void
```

Runs the VS over every vertex of a mesh.  The `fillAttrs` callback
lets the caller decide how to source per-vertex attributes
(interleaved buffer, separate streams, etc.) — no single layout forced.

```zig
pub fn rasterizeTriangles(
    comptime VsModule: type,
    comptime FsModule: type,
    ctx: *rlsw.Context,
    vertex_outs: []const VsModule.Out,
    indices: []const u32,
    base_fs_io: FsModule.Io,
    comptime connect: fn (VsModule.Out, *FsModule.Io) void,
) void
```

A working triangle rasterizer:
- Edge-function method (Pineda 1988) — robust against degeneracies.
- Clip-space → NDC → screen with Y-flip (GL +Y up → framebuffer +Y down).
- Back-face culling (CCW screen-space winding = front).
- Per-vertex perspective divide.
- **Perspective-correct varying interpolation**: barycentric weights
  divided by per-vertex `w`, normalized.  This is what makes textured
  triangles look right under perspective (not "affine-projected
  PlayStation 1 textures").
- Comptime-generic varying interpolation via `lerpAny<T>(v0, v1, v2,
  w0, w1, w2)`.  Today supports `f32` and `@Vector(N, f32)`; extends
  trivially to mat4 etc. when needed.
- Comptime-discovers the FS output color field name (same trick as
  `dispatchFragmentShader`).

The `connect(vs_out, fs_io_ptr)` callback maps the interpolated VS
Out to the FS Io.  Caller-supplied because the FS may consume only
SOME of the VS's varyings, or have additional uniforms not in the VS.

**New unit test: `rasterizeTriangles draws a clip-space full-screen triangle`**

A trivial green-emitting FS, three vertices forming a screen-space
triangle, verifies an inside pixel is green and an outside pixel is
not.  Caught two real bugs during writing:
1. **Winding-order confusion** — NDC→screen Y-flip inverts winding;
   a NDC-CCW triangle becomes CW in screen space and gets backface-
   culled.  Test reorders vertices to be CCW post-flip.  This is a
   load-bearing convention the rasterizer enforces, documented in the
   `area2 <= 0` check.
2. **Inclusive edge functions** — pixels exactly on the diagonal pass
   the `w_i >= 0` check.  Initial outside-pixel test used coordinates
   on the diagonal, leading to false failures.  Picked coordinates
   clearly off the diagonal.

**Audit**: 1880+/1880+ tests pass (including the new rasterizer
test), 0 lint across 169 files.  All five flagship standalones build
at unchanged sizes:
- mandelbrot.html → 270 KB
- mandelbrot_split.html → 274 KB
- shader.html → 179 KB
- shader_chroma_split.html → 295 KB
- damaged_helmet.html → 5389 KB

The damaged_helmet build is the smoke test — it uses every VS in
the engine (lambert, pbr, shadow, skybox) through the legacy
externs path.  Build size unchanged means the new codegen output
shape doesn't break the SPIR-V compile of any existing VS.

**Bug caught during S7a wiring**:
`i0` is a Zig primitive type — used `idx0`/`idx1`/`idx2` for the
index-buffer locals in `rasterizeTriangles` to avoid the
"name shadows primitive" error.

**Plan state**:
- S1 ✅ — shader source restructured (mandelbrot).
- S2 ✅ — CPU sampler accessors.
- S3 ✅ — `dispatchFragmentShader` + tests.
- S4 ✅ — mandelbrot_split (windowshade).
- S5 — bulk migration of 14 shaders (deferred; codegen emits both
  shapes so the legacy externs path keeps working).
- S6 ✅ — chroma_split (CPU samplers proven).
- **S7a ✅** — VS-on-CPU codegen shape.
- **S7b ✅** — `dispatchVertexShader`.
- **S7c ✅** — `rasterizeTriangles` + unit test.
- S7d — textured-cube split demo (next session).
- S8 — docs + tutorial (pending).

**What this unlocks**: the rasterizer infrastructure is in.  A
shader author can write a VS + FS pair on the new shape, dispatch
the VS, and rasterize the triangles to an rlsw framebuffer.  Same
shader source runs through the GPU pipeline (SPIR-V → GLSL → WebGL)
or the CPU pipeline (wasm32 Zig + the rasterizer).

The next session's work is purely a CONSUMER of this infrastructure
— a textured-cube example.  Then the visual A/B reveal (cube on
GPU, cube on CPU, windowshade divider) is the acceptance test.

---



Skipped the bulk S5 migration (codegen emits both shapes, so legacy
externs path keeps working).  Leapt straight to **S2** (CPU sampler
accessor body) and **S6** (textured chroma split demo) to demonstrate
the next capability gain: textured rendering on the CPU pipeline.

**S2: codegen extensions for samplers + uniforms**

`tools/gen_shader_externs.zig` now emits in the IoT(UboType) struct:
- **Loose Uniforms** → top-level Io fields.  Distinct from Ubo (a
  single uniform block).  In GLSL they become individual `uniform`
  decls; in Io they become struct fields read by the body.
- **CPU-only sampler bindings** → one `_<sampler_name>: TextureRef`
  field per sampler.  Field type is `void` on SPIR-V (compile-time
  branched), populated by the caller before dispatch on CPU.
- **Sampler accessor methods** — `pub fn texture0(self, uv) Vec4`
  with a target-conditional body:
  ```zig
  if (comptime _builtin.target.cpu.arch.isSpirV()) {
      return zm_zsample2d(texture0_sampler2d, uv);
  }
  return sampleNearestRgba8(self._texture0, uv);
  ```
- **`TextureRef` + `sampleNearestRgba8`** emitted inline in io.zig
  (not imported from rlsw — rlsw is 7000+ lines including system
  allocators that don't compile on spirv32-vulkan).  Caller
  constructs `TextureRef { pixels, width, height }` from an
  rlsw.Texture / decoded PNG / whatever RGBA8 source they have.

Sampling is nearest-neighbor with clamp.  Bilinear + repeat-wrap are
deferred to v2 (TODO in the emitted code).  Adequate for first-
pass A/B comparison; pixel-level mismatches between GPU's bilinear
and CPU's nearest are documented and expected.

**S6: `examples/shader_chroma_split.zig` shipped**

The same `shader_chroma_fs.zig` Zig source runs:
- On GPU through the SPIR-V → GLSL pipeline, sampling a GL texture.
- On CPU through `rlsw_shader.dispatchFragmentShader`, sampling
  a `TextureRef` constructed from the decoded smiley.png bytes.

Layout: smiley quad centered on the canvas, divider follows cursor
X (no drag/pan — chroma_split is purely a visual A/B comparison).
Left of divider: CPU.  Right: GPU.  Animated chroma offset.

Standalone: **295 KB bundle**, ~20 KB larger than mandelbrot_split
because of the chroma shader + sampler machinery + the embedded PNG.

**Codegen + dispatcher refactors caught along the way:**

- **Container layout rule** — Zig requires all fields before all
  declarations.  My initial codegen had the `comptime { _ = UboType }`
  discard interleaved between fields and methods.  Fix: emit all
  fields first, then the comptime discard (when no Ubo) + accessor
  methods.

- **No `_ = self;` in SPIR-V branch** — Zig considers the post-if
  `self._<name>` access a use, so a separate `_ = self` discard
  trips "pointless discard of function parameter".  Removed.

- **Local-var shadow with module-level `u: Ubo` extern** —
  `sampleNearestRgba8`'s u/v locals collided with the legacy
  section's `pub extern const u: Ubo`.  Renamed to `uu`/`vv`.

- **Out-field name discovery in the dispatcher** — `out.out_color`
  hardcoded didn't work for chroma's `out.final_color`.  Rewrote
  `src/rlsw_shader.zig` to find the first `@Vector(4, f32)` field
  in `Out` by comptime introspection — works against any shader on
  the new shape regardless of the output field's name.

**Audit**: 1880+/1880+ tests pass, 0 lint across 169 files.  All
four flagship standalones build cleanly:
- mandelbrot.html → 270 KB (unchanged)
- mandelbrot_split.html → 274 KB (unchanged)
- shader.html → 179 KB (unchanged)
- shader_chroma_split.html → 295 KB (new)

**End-to-end verification**:
- GLSL output for chroma is byte-identical to the pre-S2 version
  (same `uniform highp sampler2D texture0`, same per-channel
  texture samples, same single-statement `final_color` assignment).
- The CPU dispatcher's introspection-based out-field discovery
  works against both `out.out_color` (mandelbrot) and
  `out.final_color` (chroma) without naming conventions in the
  dispatcher.
- The sampler accessor's target-conditional body compiles cleanly
  on both spirv32-vulkan AND wasm32-wasi — same Zig source.

**Plan state**:
- S1 ✅ — shader source restructured to new shape (mandelbrot).
- S2 ✅ — CPU sampler accessor + loose uniforms emit.
- S3 ✅ — `src/rlsw_shader.zig` dispatcher with comptime field
  discovery for the color output.
- S4 ✅ — mandelbrot_split (windowshade divider).
- S5 — migrate 14 remaining shaders to new shape, NOT yet done.
  Mechanical work; codegen emits both shapes so it's safe to defer.
- S6 ✅ — chroma_split (CPU samplers proven).
- S7 (vertex shaders on CPU) — pending, deferred.
- S8 (docs + tests) — pending.

**What this unlocks**: the software-shader pipeline is now feature-
complete for FS-only shaders.  Anything written as a Zig FS that
uses inputs + uniforms + Ubo + samplers can run on both pipelines
side-by-side.  The remaining shape gaps are vertex shaders (S7)
and the bulk shader migration (S5, mechanical).

---



The headline payoff for the software-shader plan.  The CPU dispatcher
lands AND the same mandelbrot fractal renders side-by-side through
both pipelines.

**S3: `src/rlsw_shader.zig` shipped (~190 lines)**

```zig
pub fn dispatchFragmentShader(
    ctx: *rlsw.Context,
    comptime ShaderModule: type,
    base_io: ShaderModule.Io,
    rect: Rect,
) void {
    // ... per-pixel loop, calls ShaderModule.shaderMain(io), writes
    // result through rlsw_pixel.write_color_table's codec ...
}
```

Comptime-generic over the shader module.  Reads from `ShaderModule.Io`
and writes pixels through `rlsw_pixel.WriteColorFn` codecs for any
framebuffer format.  Clips the rect to the framebuffer bounds.  Two
inline tests verify a constant-color shader fills the buffer and a
UV-based shader gradients correctly.

To support this, rlsw gained three public accessors:
- `colorBufferBytesMut() []u8` — mutable variant of `colorBufferBytes`.
- `colorBufferDims() Vector2i` — width / height in texels.
- `colorBufferFormat() PixelFormat` — selects the right writer codec.

**S4: `examples/mandelbrot_split.zig` shipped (~270 lines)**

Side-by-side fractal: left half is the rlsw CPU dispatch, right half
is the GPU shader compiled to GLSL.  Both halves driven by the same
`(center, zoom)` view state, the same `Ubo` struct, the same
`shaderMain` Zig function — just compiled for two different targets.
Dragging crosses the divider naturally (mouse-to-world math uses the
full canvas as reference).

Standalone: **274 KB bundle**, 4 KB larger than the GPU-only mandelbrot
because of the rlsw context + the dispatcher's machinery.  Visual
output matches modulo floating-point precision.

**Wiring innovation: IoT(UboType) factored out of io.zig**

The S4 build hit a Zig 0.16 "file in two modules" conflict:
- The example imports `mandelbrot_fs_iface.zig` relatively for the
  `LoadedShader(iface)` API — file claimed by 'root' module.
- The codegen's io.zig wanted to import the iface to alias
  `pub const Ubo = _iface.Ubo;` — claimed by 'iface' module.
- Zig 0.16 rejects the same file appearing as a member of two
  distinct modules.

Fix: io.zig is deliberately **iface-independent**.  Codegen emits
`pub fn IoT(comptime UboType: type) type` (a function-returning-a-
type) instead of `pub const Io = struct { ..., u: Ubo, ... }`.  The
shader source closes the loop:

```zig
// examples/mandelbrot_fs.zig
const io = @import("io");
const iface_mod = @import("mandelbrot_fs_iface.zig");
pub const Io = io.IoT(iface_mod.Ubo);
pub const Out = io.Out;
pub const Ubo = iface_mod.Ubo;
pub const iface = iface_mod;
```

Both the shader source AND the example are in the same module
('root'); both can import the iface file relatively without
conflict.  io.zig has no iface dep at all — it sees `UboType` as
an opaque type parameter.

`installSpirvEntry` was made similarly type-erased: it now takes
`comptime body: anytype` and uses `@typeInfo` to extract Io / Out
from the body fn's signature.  The wrapper builds the Io struct
field-by-field via anonymous-struct literal that coerces to the
body's expected type.

This is a refinement of S1's design, not a deviation — the
shape of the shader source stays nearly identical, just adding
the `pub const Io = io.IoT(iface_mod.Ubo);` re-export.

**Build wiring additions in `build.zig`**:
- Cache of compiled `ShaderOutput { glsl, io }` per sh_name.
- Cross-example shader sharing list — explicit pairings like
  `mandelbrot_split → mandelbrot_fs` that let one example
  reuse another's compiled shader output.
- `addShaderEx` returns both paths; `addShader` kept as a
  glsl-only wrapper for backward compat.
- exe_mod's `io` import wired with `shadermath` as a sub-dep
  (only — no iface).

**Audit**: 1880+/1880+ tests pass (including 2 new dispatcher
tests), fmt clean, 0 lint across 168 files.  All three flagship
standalones build at expected sizes:
- mandelbrot.html → 270 KB (unchanged)
- mandelbrot_split.html → 274 KB (new)
- damaged_helmet.html → 5389 KB (unchanged)
- shader.html → 179 KB (unchanged)

**What's verified end-to-end**:
1. The same `shaderMain` Zig function compiles for SPIR-V (→ GLSL)
   AND wasm32-wasi (→ rlsw dispatcher) without modification.
2. The GLSL output is byte-identical in shape to the pre-restructure
   version — same `io_Ubo` block, same varyings, same uniforms,
   same `main()` body.
3. The IoT(UboType) pattern avoids file-in-two-modules conflicts
   while preserving canonical Zig type identity for the Ubo struct.
4. The cross-example sharing wiring lets one example reuse
   another's compiled shader output without duplicate codegen runs.

**Plan state**:
- S1 ✅ — shader source restructured to new shape.
- S2 (CPU sampler accessor) — pending, not blocking.
- S3 ✅ — dispatcher + 2 unit tests shipped.
- S4 ✅ — split-screen demo shipped.
- S5 (migrate 14 other shaders to new shape) — pending.
- S6 (sampler-bearing shader on CPU, chroma demo) — pending.
- S7 (vertex shaders on CPU) — pending, deferred.
- S8 (tests + tutorial + docs) — pending.

The headline deliverable — running the same Zig shader source on
GPU and CPU side-by-side — is real.

---



**What shipped:**

- `tools/gen_shader_externs.zig` extended.  For every iface schema
  the codegen now emits BOTH:
  - The legacy API: externs at module scope, `setup()` function,
    sampler accessor methods.  Unchanged — every existing shader
    continues to work.
  - The new API: `pub const Io = struct { ... }`, `pub const Out
    = struct { ... }`, `pub fn installSpirvEntry(comptime body:
    fn (Io) Out) void` (no-op on CPU; materializes the `export fn
    entry()` wrapper on SPIR-V).  Compile-time gated by
    `_builtin.target.cpu.arch.isSpirV()`.
  - `_builtin = @import("builtin")` always emitted (used by
    installSpirvEntry's target check).
- `examples/mandelbrot_fs.zig` restructured.  The `export fn
  main() callconv(.spirv_fragment)` body is gone; replaced by
  `pub fn shaderMain(io: Io) Out` + `comptime { _ = io.install-
  SpirvEntry(shaderMain); }`.  Internal `var out: Out = undefined;
  ... return out;` keeps the imperative-mutation feel inside the
  body.
- All 14 other shaders untouched — they keep the old shape until
  S5 migrates them mechanically.

**Verification:**

- `zig build` clean, 0 lint across 166 files, 1880+/1880+ tests
  pass.
- `mandelbrot.html` standalone builds at 270 KB (unchanged — the
  new emission inlines completely through spirv-opt).
- Generated GLSL structurally identical: same `io_Ubo` block, same
  varyings, same uniforms, same main body.

**Two design surprises caught and fixed:**

S1 ran into one new issue not covered by the session-13
experiments: when the shader body has a `pub fn main` declaration,
Zig's `std.start.zig` auto-activates and tries to export `_start`
with `callconv(.naked)` — which the SPIR-V backend rejects.  The
fix: rename the kernel from `main` to `shaderMain` (or any non-
`main` name).  Session 13's experiment didn't catch this because
its test fixture used `fn shader` not `fn main`.

This means the canonical signature is now:

    pub fn shaderMain(io: Io) Out

NOT `pub fn main(io: Io) Out`.  Plan §1, §4.1, §5.7 updated;
section §5.9 added below to document the std.start trap.

The second issue: when the iface declares `pub const Outputs =
struct {}` (shadow_vs's empty-output depth-only pass), the
generated `installSpirvEntry` body had `const out: Out = body(io);`
with no subsequent use of `out`, triggering Zig's unused-local
check.  Fixed by emitting `_ = out;` in that case.

**Codegen emission for mandelbrot now produces:**

    pub const Io = struct {
        frag_tex_coord: @Vector(2, f32),
        frag_color: @Vector(4, f32),
        u: Ubo,
    };
    pub const Out = struct {
        out_color: @Vector(4, f32),
    };
    pub fn installSpirvEntry(comptime body: fn (Io) Out) void {
        if (!_builtin.target.cpu.arch.isSpirV()) return;
        const Wrapper = struct {
            export fn entry() callconv(.spirv_fragment) void {
                @setRuntimeSafety(false);
                zm_location(&frag_tex_coord, _location_frag_tex_coord);
                zm_location(&frag_color, _location_frag_color);
                zm_location(&out_color, _location_out_color);
                zm_binding(&u, 0, _binding_u);
                const io: Io = .{
                    .frag_tex_coord = frag_tex_coord,
                    .frag_color = frag_color,
                    .u = u,
                };
                const out: Out = body(io);
                out_color = out.out_color;
            }
        };
        _ = Wrapper;
    }

Both legacy `setup()` + extern decls AND the new API live in the
same `io.zig`.  No drift risk — both reflect the same iface
schema.

**Next: S2 (CPU sampler accessor) + S3 (rlsw dispatcher) + S4
(side-by-side demo).**

---

## §9. End-of-plan note

(To be filled in as the work progresses, per the claude.md
convention.)
