# zimr: a raylib-shaped graphics library in Zig, compiled to WebAssembly

This is a writeup of a hobby project. It's a graphics library written in Zig
that targets the browser — `wasm32` plus WebGPU (and, for now, a WebGL2 path
that's on its way out). The API is shaped after raylib, because raylib's API is
pleasant and I didn't have a better idea. None of this is novel. The interesting
parts, to the extent there are any, are in the seams: how one piece of scene
code drives three different renderers, and how shaders get written in Zig and
compiled down to both GLSL and WGSL through a SPIR-V pipeline.

I'll describe the architecture, show real examples, and point out the parts I'd
do differently. I've tried to keep the tone flat. If you came here to be sold
something, this isn't that.

## What it looks like to use

The smallest useful program draws some shapes:

```zig
const z = @import("zimr_wgpu");

pub var zimr_app: z.App = .{};

pub fn main() !void {
    try zimr_app.run(.{ .window = .{ .title = "shapes", .width = 800, .height = 600, .depth_format = null } },
        State, initState, update);
}

fn update(f: *z.Frame, s: *State) void {
    z.beginDrawing(f.gl);
    z.clearBackground(f.gl, .{ .r = 18, .g = 18, .b = 26, .a = 255 });
    z.drawRectangle(f.gl, 60, 80, 100, 100, .{ .r = 200, .g = 80, .b = 160, .a = 255 });
    z.drawCircle(f.gl, 400, 300, 45, .{ .r = 80, .g = 200, .b = 220, .a = 255 }, 32);
    z.endDrawing(f.gl);
}
```

If you've used raylib this is familiar. The two things that differ from a normal
raylib binding: there are no globals (every call takes `f.gl` or some other
explicit handle), and the whole thing compiles to a `.wasm` reactor module that
a small JS file instantiates and drives via `requestAnimationFrame`.

There's no global `GetMouseX()`. State you'd expect to be ambient — input, the
frame clock, the drawing context, the window size — arrives on a `Frame` struct
passed to your `update`:

```zig
pub const Frame = struct {
    gpu: *GpuFrame,      // the GPU per-frame container (device/queue/surface/caches/depth)
    gl: *WgpuGl,         // the immediate-mode 2D drawing context
    time: TimeState,     // delta_time, elapsed, frame_count
    window: WindowState, // live backing-pixel dimensions
};
```

I'll be honest about the motivation: the no-globals rule started as taste and
became load-bearing only later, when it turned out to be the thing that let the
same code run on multiple backends without a rewrite. If you don't share the
taste, it reads as ceremony. More on that below.

## The shape of the codebase

Rough numbers, because people always ask:

- ~115 Zig files in `src/`, the bulk of which is two big files: a software
  rasterizer (`rlsw.zig`, ~7.2k lines) and an entity/ECS system (`entities.zig`,
  ~7.5k lines). Neither is required to draw a triangle; they're there because
  the examples use them.
- 173 example programs. Most are ports of raylib examples.
- Two JS bridges: `zimr.ts` (~2.9k lines, WebGL2) and `zimr_wgpu.ts` (~960
  lines, WebGPU). These are the only hand-written JavaScript.
- A SPIR-V → WGSL translator, `src/spv2wgsl/`, ~6k lines of Zig.

The "two big files" thing deserves a comment, since it's the first thing a
skeptic notices. `rlsw.zig` and `entities.zig` are large because they're ports
of large C things (a software GL, an archetype ECS) and I kept them as single
translation units rather than splitting for the sake of splitting. Zig's lazy
analysis means an example that never touches the ECS doesn't pull it into its
wasm. Whether a 7k-line file is acceptable is a matter of taste; I find one file
I can grep easier than fifteen I have to navigate. You may disagree.

## Three renderers, one piece of scene code

Here's the part I think is actually worth describing.

raylib draws through an immediate-mode layer: `rlBegin(RL_TRIANGLES)`,
`rlVertex2f`, `rlColor4ub`, `rlEnd`. Three things in this project implement that
surface:

1. **rlgl** — a thin shim over WebGL2. The historical path.
2. **rlsw** — a pure-Zig software rasterizer. Runs on the CPU, no GPU at all.
3. **WgpuGl** — an adapter that accumulates immediate-mode calls into a batch and
   submits them through WebGPU.

The trick (such as it is) is a compile-time interface in `renderer_trait.zig`. It's
not a vtable and not `dyn`; it's a `comptime` function that asserts a type has
the right methods:

```zig
pub fn assertIsGlContext(gl: anytype) void {
    const T = @TypeOf(gl.*);
    inline for (required_methods) |name| {
        if (!@hasDecl(T, name)) @compileError(...);
    }
}
```

So scene code is written once, generic over the renderer:

```zig
fn drawTriangle(gl: anytype) void {
    gl.begin(.triangles);
    gl.color4ub(255, 0, 0, 255);
    gl.vertex2f(0, 0);
    gl.vertex2f(1, 0);
    gl.vertex2f(0, 1);
    gl.end();
}
```

`drawTriangle` compiles three times — once per renderer — with no dispatch
overhead, because the type is known at each call site. The library comment in
`renderer_trait.zig` says "adding a third renderer is a third adapter struct," and
that turned out to be literally true: WgpuGl was the third one, and it slotted
in without touching the other two or the scene code that drives them.

The intended payoff is a side-by-side demo: run the same fragment shader on the
CPU (rlsw) and the GPU (WebGPU) in the same frame, split by a draggable divider,
and use any pixel difference as a correctness check on the GPU path. That demo
exists on the WebGL pairing today and is being ported to the WebGPU pairing.

**The honest objection** an HN reader will raise here: "this is just an
interface, you've reinvented a trait and given it a fancy name." Correct. The
only thing `comptime` buys over a runtime interface is that the dispatch is free
and the error is a compile error instead of a crash. That's worth something in a
hot per-vertex path and nothing in most other places. I'm not claiming more than
that.

A second objection: monomorphizing scene code three ways is code bloat. Also
true — each backend gets its own specialized copy. For a graphics library where
exactly one backend is live in a given binary, this doesn't matter (DCE drops the
other two). For a library where all three were live at once, it would.

## Shaders are written in Zig

This is the part most likely to start an argument, so let me be precise about
what it is and isn't.

Shaders are written as ordinary Zig functions in `*.fs.zig` / `*.vs.zig` files.
A fragment shader is a function `fn shaderMain(io: Io) Out` over a struct of
inputs. There is no GLSL and no WGSL in the source tree. The build:

1. `zig build-obj -target spirv32-vulkan` — Zig's own SPIR-V backend compiles
   the shader function to SPIR-V.
2. `spirv-opt -O --skip-validation` — optimization.
3. For the WebGL path: `spirv-cross --version 300 --es` produces GLSL ES 3.0.
4. For the WebGPU path: a homegrown `spv2wgsl` translator produces WGSL.

Writing shaders in Zig means you get Zig's type system, comptime, and — the
actual reason I did it — you can run the *exact same shader function* on the CPU
through rlsw, which is what makes the side-by-side comparison meaningful. It's
the same source, not a port.

**Now the objections, because there are several good ones.**

*"Zig's SPIR-V backend is experimental."* Yes. This is the single biggest source
of fragility in the project. The backend emits structured control flow that's
fine for real shaders but produces SPIR-V shapes that downstream tools handle
inconsistently. I keep a corpus of 181 hand-written CFG torture fixtures (from
Tint's test suite) precisely to catch the translator choking on shapes the Zig
backend doesn't currently emit but might.

*"You wrote your own SPIR-V → WGSL translator? Why not use Tint/naga?"* Fair.
The short answer is that the official tools are C++/Rust and this is a Zig
project that compiles to wasm, and shelling out to a C++ binary at build time is
exactly what I was trying to avoid for the runtime translation path. The longer
answer is that I underestimated how hard CFG structurization is, and the
translator has been the buggiest component by a wide margin. If I were starting
over I would think harder about this choice. I did end up reading the
SPIRV-Tools `dead_branch_elim` pass closely and porting its algorithm (live-block
marking over the folded CFG, plus the rule that you never fold a loop back-edge
unless it targets the header) to fix a class of bugs my own code had — so the
"don't depend on the C++ tools" position is softer in practice than in
principle. I depend on their *ideas*; I just re-implemented them.

*"A toolchain that's `zig → SPIR-V → opt → cross → GLSL` is a lot of moving
parts to draw a gradient."* True. The build-time shader pipeline is the most
complex thing in the repo and the place most likely to break when the Zig
compiler updates. The mitigating factor is that it's all build-time; the shipped
wasm contains pre-translated WGSL strings and none of the tooling.

## The WebGPU backend

The WebGPU path is a Zig wasm module plus the `zimr_wgpu.ts` bridge. The wasm
declares `extern` functions for the GPU operations it needs
(`js_create_buffer`, `js_surface_get_current_texture`, `js_draw_indexed`, and so
on); the bridge implements them against the browser's `GPUDevice`. There's no
WebGPU-in-Zig binding crate; it's a hand-cut FFI surface, kept deliberately
small (~960 lines of TS).

A few design points that took iterations to get right:

**The frame owns the depth texture.** Early on, each example created its own
depth buffer at a fixed size. WebGPU requires the depth attachment to exactly
match the color attachment's size, so the moment a canvas was a different size
than the hardcoded number, the entire render pass was silently dropped — valid
pipeline, valid draws, blank screen, no error. The fix (lifted from raygpu's
backend) is that the per-frame container owns the depth texture and reallocates
it whenever the surface size changes, checked every frame. This is the kind of
bug that's obvious in retrospect and cost an afternoon in practice.

**DPR is handled at the bridge.** The canvas backing store is sized to
`clientWidth * devicePixelRatio` and re-synced on a `ResizeObserver`; the page's
CSS owns display size. Demos compute their projection aspect from the live
surface size, not a constant, so the image is correct (and crisp) at any
device-pixel-ratio. Getting this wrong is why a lot of wasm graphics demos look
blurry on phones.

**On-page diagnostics.** WebGPU validation errors surface asynchronously and, on
a phone, into a console you can't see. The standalone build mirrors `console.*`
into an on-page panel and wraps initialization and the first frame in explicit
validation error scopes whose results print on the page. This turned a
multi-screenshot guessing loop (the depth bug above) into a one-screenshot
diagnosis: the error text was right there on the canvas.

**The objection:** "hand-cut FFI to a browser API that's still changing is going
to rot." Yes. WebGPU is a moving target and so is the bridge. The bet is that the
surface is small enough (a few dozen functions) to keep current by hand, and
that a build-time smoke test — instantiate the wasm with a stubbed bridge, run
60 frames, assert no traps and no missing imports — catches signature drift
before it reaches a browser. That test has earned its keep.

## The PBR demo

The most substantial example is a glTF PBR renderer — it loads `DamagedHelmet.glb`,
decodes its JPEG textures, builds the metallic-roughness pipeline, and renders it
lit. It runs at ~107fps and lives in a reusable `pbr3d.zig` (~970 lines) that
does the standard metallic-roughness BRDF, normal mapping, and image-based-ish
lighting. The demo program that drives it is about 100 lines.

I'll use this to make an honest point about the project's state rather than to
brag about it: the PBR demo still uses the *old* hand-rolled setup —
manual device/queue/cache construction in `main()` — while the newer 2D and quad
demos use the `z.App.run(...)` entry point that hides all of that. So the
codebase currently has two ways to start a WebGPU program, and the flagship demo
uses the worse one. That's not a deliberate design; it's a migration I haven't
finished. The right state is one entry point, and the PBR demo should be ported
to it. I'm noting it here because a reader cloning the repo would notice the
inconsistency and reasonably wonder which way is "correct." (The `App.run` way.)

## Things I'd change

In the spirit of not overselling:

- **The shader toolchain dependency on Zig's SPIR-V backend** is the riskiest
  bet in the project. A compiler update changed `std` hash-map iteration order
  and silently broke the translator on half the torture corpus — not because the
  translator changed, but because it had an order-dependence I didn't know about.
  The lesson (audit any algorithm that iterates a hash map and assumes an order)
  is generic; the fragility is specific to leaning on an experimental backend.

- **Two backends, one deprecated.** Carrying WebGL2 and WebGPU at once is debt.
  The WebGL path is being removed; until it is, it's a second thing that can
  break. I recently put it behind a build flag (default off) so its rot can't
  fail the build, which is a stopgap, not a solution.

- **The two-entry-point situation** described above.

- **`spv2wgsl` should probably not exist.** The most defensible version of this
  project shells out to Tint at build time and ships the WGSL, the same way it
  shells out to spirv-cross for GLSL. The pure-Zig translator was a "can I?"
  that turned into a maintenance commitment. It works now, and I understand
  every line, which has value — but it's the component I'd most readily delete if
  a dependency were acceptable.

- **Naming.** raylib's `rl*` immediate-mode names leak into a library that isn't
  raylib. It's familiar to the audience and confusing to everyone else.

## What it's good for

Nothing in production. It's a project for learning how the layers fit together —
shader compilation, CFG structurization, the WebGPU surface model, the cost of
abstraction in a hot path. If you want to ship a game in the browser, use one of
the engines that has a team behind it. If you want to read a self-contained
codebase that takes a Zig function and gets it onto a GPU through the browser,
with the seams visible and the warts documented, this might be worth an hour.

The code is plain. The interesting decisions are mostly about what *not* to
abstract. The parts I'm least sure about are flagged above. Make of it what you
will.
