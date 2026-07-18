# Two renderers, one API — the `gl: anytype` strategy

**You have working code that calls `drawing.shapes.drawRectangleRec(gl, ...)`. Today `gl` is `*rlgl.GlState` (the WebGL2 backend). Tomorrow you want the same code to run against `*rlsw.Context` (the CPU software rasterizer) so you can take PNG screenshots in a host test, or compare GPU vs CPU output side-by-side, or run UI tests without a browser.**

This tutorial shows how that works in zimr today (turn 317+) and what your code looks like when you switch.

> **TL;DR**: drawing functions take `gl: anytype`. Both `*rlgl.GlState` and `*rlsw.Context` expose the same methods (`begin`, `vertex2f`, `color4ub`, …). The compiler monomorphizes per call site — zero runtime cost, zero adapter wrappers needed.

---

## The core idea

A drawing function in zimr looks like this:

```zig
pub fn drawCircle(gl: anytype, cx: f32, cy: f32, r: f32, color: Color) void {
    z.assertIsGlContext(gl);                    // comptime trait check
    gl.color4ub(color.r, color.g, color.b, color.a);
    gl.begin(.triangles);
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        // … vertex2f calls …
    }
    gl.end();
}
```

That `gl: anytype` is Zig's way of saying "any type that responds to the methods I call". The compiler builds one specialised copy of `drawCircle` per concrete type passed in — fully inlined, no vtable.

Two types are useful today:

| Type | Where it lives | Output goes to |
|---|---|---|
| `*rlgl.GlState` | `src/rlgl.zig` | WebGL2 (on `wasm32-wasi`) / no-op (on host) |
| `*rlsw.Context` | `src/rlsw.zig` | a CPU-allocated `[w*h*4]u8` framebuffer |

Both expose the same method surface:

```
begin(mode)        end()
vertex2f(x, y)     vertex3f(x, y, z)
color4ub(r,g,b,a)  color3f(r, g, b)
texCoord2f(u, v)   normal3f(x, y, z)
setTexture(id)     scissor(x, y, w, h)
matrixMode(.modelview)   loadIdentity()
pushMatrix()       popMatrix()
translate(x,y,z)   rotate(angle_deg, x, y, z)   scale(x, y, z)
multMatrix(&m)
ortho(l,r,b,t,n,f) frustum(l,r,b,t,n,f)
enable(.depth_test)   disable(.scissor_test)
clearColor(c)      clear(.{ .color = true })
```

That's the trait. Anything implementing it can be passed to any drawing function.

---

## Example 1 — drawing the same rectangle on both backends

A side-by-side host program that draws a red rectangle into both renderers and dumps the rlsw result as a PNG:

```zig
const std = @import("std");
const z = @import("zimr");

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // ---- Backend 1: rlgl (WebGL2) ------------------------------------
    var gl: z.rlgl.GlState = .{};
    // On host (non-wasm), rlgl ops are no-ops — no GL context exists.
    // The same exact source compiles to wasm where they hit WebGL.
    var batch: z.rlgl.VertexBuffer = undefined;
    z.rlgl._testInit(&gl, &batch);

    z.drawing.shapes.drawRectangleRec(
        &gl,
        &(z.ShapesTextureState{}),                 // 1x1 white texture
        .{ .x = 10, .y = 10, .width = 100, .height = 50 },
        .{ .r = 220, .g = 60, .b = 80, .a = 255 },
    );

    // ---- Backend 2: rlsw (CPU rasterizer) ----------------------------
    var sw = try z.rlsw.Context.init(gpa, 200, 100);
    defer sw.deinit(gpa);

    // Set up an ortho projection: pixel coords map directly to NDC,
    // y-down (top-left origin) to match the screen-pixel convention.
    sw.matrixMode(.projection);
    sw.loadIdentity();
    sw.ortho(0, 200, 100, 0, -1, 1);    // l, r, BOTTOM, TOP, n, f — y flipped
    sw.matrixMode(.modelview);
    sw.loadIdentity();
    sw.clearColor(.{ .r = 15, .g = 23, .b = 42, .a = 255 });
    sw.clear(.{ .color = true });

    // SAME function call, different backend.
    z.drawing.shapes.drawRectangleRec(
        &sw,
        &(z.ShapesTextureState{}),
        .{ .x = 10, .y = 10, .width = 100, .height = 50 },
        .{ .r = 220, .g = 60, .b = 80, .a = 255 },
    );

    // Pull the pixels out and write a PNG.
    const pixels = sw.colorBufferBytes();
    const png_bytes = try z.png.encode(gpa, pixels, 200, 100);
    defer gpa.free(png_bytes);

    // (Use Zig 0.16's Io.Threaded — see the section below.)
    var io_threaded = std.Io.Threaded.init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();
    var f = try std.Io.Dir.cwd().createFile(io, "rect.png", .{});
    defer f.close(io);
    try f.writeStreamingAll(io, png_bytes);
}
```

That's the whole pattern. Notice three things:

1. `drawRectangleRec` doesn't know or care which backend `gl` is. Same source.
2. The rlgl path produces zero pixels on host (no GL context); the rlsw path produces real pixels in a `[]u8`.
3. The rlsw setup needs an ortho projection + a clear, because rlsw has no implicit window or default clear color. rlgl gets those from the runtime (`zimr.beginDrawing` / `zimr.clearBackground`).

---

## Example 2 — PNG screenshot of UI for testing

This is the use case that motivated the whole refactor. You have a ui scene, you want to assert "the button rendered at this pixel position". Today: run a real browser session and screenshot manually. With rlsw: run as a host test.

```zig
const std = @import("std");
const z = @import("zimr");
const ui = z.ui;

test "screenshot: tab bar layout" {
    const gpa = std.testing.allocator;

    // --- 1. Build a UI frame ---
    var ctx: ui.UiContext = .{
        .gpa = gpa,
        .frame_arena = std.heap.ArenaAllocator.init(gpa),
        .canvas_w = 480,
        .canvas_h = 360,
    };
    defer ctx.deinit();

    // beginFrameRaw is the test-friendly form (skips the Frame plumbing).
    var gl_dummy: z.rlgl.GlState = .{};
    const shapes_dummy: z.drawing.shapes.ShapesTextureState = .{};
    const font_dummy: z.drawing.text.FontCache = .{};
    const u = ctx.beginFrameRaw(.{}, null, 480, 360, &gl_dummy, &shapes_dummy, &font_dummy);

    if (u.window("My window", .{ .initial_size = .{ 460, 340 } })) |w| {
        defer w.close();
        if (u.beginTabBar("bar", .{})) {
            defer u.endTabBar();
            var open: bool = true;
            if (u.beginTabItem("Alpha", &open, .{})) {
                defer u.endTabItem();
                _ = u.button("Click me", .{});
            }
        }
    }

    // --- 2. Replay the frame's DrawLists into rlsw ---
    var sw = try z.rlsw.Context.init(gpa, 480, 360);
    defer sw.deinit(gpa);
    sw.matrixMode(.projection);
    sw.loadIdentity();
    sw.ortho(0, 480, 360, 0, -1, 1);
    sw.matrixMode(.modelview);
    sw.loadIdentity();
    sw.clearColor(.{ .r = 15, .g = 23, .b = 42, .a = 255 });
    sw.clear(.{ .color = true });
    sw.enable(.blend);
    sw.blendFunc(.src_alpha, .one_minus_src_alpha);

    var it = ctx.windows.iterator();
    while (it.next()) |entry| {
        const win = entry.value_ptr.*;
        if (win.last_frame_active != ctx.frame_count) continue;
        // ↓↓↓ The whole reason this works: DrawList.render is gl: anytype. ↓↓↓
        win.draw_list.render(&sw, /* window state shim */, &shapes_dummy, &font_dummy);
    }

    // --- 3. Encode + write PNG ---
    const pixels = sw.colorBufferBytes();
    const png_bytes = try z.png.encode(gpa, pixels, 480, 360);
    defer gpa.free(png_bytes);

    var io_threaded = std.Io.Threaded.init(gpa, .{});
    defer io_threaded.deinit();
    var f = try std.Io.Dir.cwd().createFile(io_threaded.io(), "tabbar.png", .{});
    defer f.close(io_threaded.io());
    try f.writeStreamingAll(io_threaded.io(), png_bytes);

    // --- 4. Or skip the file — sample specific pixels for assertions ---
    // Pixel at (50, 50) in RGBA layout: pixels[(50*480 + 50)*4 + 0..3]
    const px_idx = (50 * 480 + 50) * 4;
    try std.testing.expectEqual(@as(u8, 30), pixels[px_idx + 0]); // R
}
```

The `ctx.beginFrameRaw` form is for tests — it skips the framework's input/clock plumbing and takes the inputs directly. Production code uses `ctx.beginFrame(frame, &shapes, &font_cache)`.

---

## Example 3 — A/B comparison (the `rlsw_side_by_side` demo)

The existing `rlsw_side_by_side` demo runs both renderers each frame at full canvas resolution and composites them on screen. The 3D cube draw is one function:

```zig
fn drawScene(gl: anytype, aim_x: f32, aim_y: f32, t: f32, clear_color: z.Color) void {
    z.assertIsGlContext(gl);

    gl.clearColor(clear_color);
    gl.clear(.{ .color = true, .depth = true });

    gl.matrixMode(.projection);
    gl.loadIdentity();
    gl.frustum(-1.78, 1.78, -1, 1, 1, 10);

    gl.matrixMode(.modelview);
    gl.loadIdentity();
    gl.translate(0, 0, -3.5);
    gl.rotate(aim_x * 1.2 * 180.0 / 3.14159, 0, 1, 0);

    gl.enable(.depth_test);
    gl.enable(.texture_2d);
    for (cube_faces) |face| {
        gl.color4ub(face.color[0], face.color[1], face.color[2], face.color[3]);
        gl.begin(.quads);
        for (face.corners, face.uvs) |corner, uv| {
            gl.texCoord2f(uv[0], uv[1]);
            gl.vertex3f(corner[0], corner[1], corner[2]);
        }
        gl.end();
    }
    gl.disable(.texture_2d);
    gl.disable(.depth_test);
}

// Caller:
drawScene(&state.gl_state, x, y, t, color);  // → WebGL
drawScene(&state.sw_ctx, x, y, t, color);   // → CPU framebuffer
```

That's the entire payoff: **one function, both backends, identical output (up to rasterizer rounding)**.

---

## How the trick works under the hood

When the compiler sees `gl: anytype`, it doesn't generate one function — it generates *one per type passed in*. Inside the function, calls like `gl.begin(.quads)` resolve at compile time:

- If `gl` is `*rlgl.GlState`, `gl.begin(.quads)` calls `rlgl.GlState.begin(self, mode)` (a 1-line forward to `rlgl.rlBegin(self, RL_QUADS)`).
- If `gl` is `*rlsw.Context`, `gl.begin(.quads)` calls `rlsw.Context.begin(self, mode)` (the rlsw native implementation).

There's no dynamic dispatch, no vtable, no boxing. The optimizer can fully inline both versions. The cost of "polymorphism" here is exactly zero at runtime — it's the compile-time monomorphisation pattern from C++/Rust generics, but with Zig's structural-typing twist.

The `assertIsGlContext(gl)` helper is also pure comptime — it walks the type at compile time and emits a clear `@compileError` if a required method is missing:

```zig
const Bad = struct { /* no methods */ };
var b: Bad = .{};
drawCircle(&b, 100, 100, 50, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
// → error: type 'main.Bad' is missing required gl-context method 'begin'.
//          See src/renderer_trait.zig for the full required-method list.
```

Better than the buried "no field named X" you'd get without the assert.

---

## Limitations and gotchas

### 1. Textures don't bridge between renderers (yet)

`*rlgl.GlState` uses `u32` for texture IDs (a GL handle). `*rlsw.Context` uses `Handle(Texture)` (a slot index into its own texture pool). They're not interchangeable. Today:

- Text rendering against rlsw: glyph quads emit with no texture bound. The sampler reads white. So the glyph quads come out as **solid colored rectangles** (vertex_color × white = vertex_color). That's actually a useful "placeholder text" rendering for layout debugging.
- If you genuinely want glyphs rasterized into the rlsw framebuffer, you'd need to upload the font atlas to rlsw via `sw.texImage2D(...)`, then set both texture handles on the `Font` struct.

This is filed for follow-up (turn 317+). For now: ui screenshots are great for **layout** debugging, OK for **color/contrast** debugging, not for verifying text legibility.

### 2. `*rlgl.GlState` does nothing on host

The whole rlgl backend is wasm-only. On host, every `rlBegin` / `rlVertex2f` / etc. is a no-op. The state struct exists (so tests can construct it), but no pixels appear. This is why the screenshot path uses rlsw on host — you can't screenshot rlgl on host because rlgl on host doesn't render.

### 3. `assertIsGlContext` requires `pub` methods

If you define your own renderer, make sure the methods are `pub fn` — the comptime trait check uses `@hasDecl` which only sees public declarations.

### 4. rlsw is single-pass; rlgl batches

`rlgl.rlBegin(gl, RL_QUADS)` accumulates vertices in a per-frame batch that's flushed at frame end (`endDrawing`). `rlsw.Context.begin(.quads)` rasterizes immediately. If you call `setTexture` while inside a `begin`/`end` pair, rlgl handles it via a batch break + new batch; rlsw treats it as an error and ignores. Don't switch textures mid-primitive on either.

---

## Common patterns

### Pattern: render to both, compare

```zig
// One scene description, both renderers, byte-level diff.
drawScene(&state.gl_state, ...);
drawScene(&state.sw_ctx, ...);

const gl_pixels = state.gl_target.readPixels(gpa);
defer gpa.free(gl_pixels);
const sw_pixels = state.sw_ctx.colorBufferBytes();

var diff_count: u32 = 0;
for (gl_pixels, sw_pixels) |a, b| {
    if (@abs(@as(i16, a) - @as(i16, b)) > 2) diff_count += 1;
}
const match_pct: f32 = 100.0 * (1.0 - @as(f32, @floatFromInt(diff_count)) / @as(f32, @floatFromInt(gl_pixels.len)));
```

The `rlsw_side_by_side` demo does exactly this and shows the heatmap as a tappable overlay.

### Pattern: gate rlgl-only debug counters in polymorphic code

Some `drawing.zig` functions do bookkeeping that only makes sense on rlgl (scope counters, batch flushes). Comptime-detect via `@hasDecl`:

```zig
pub fn beginScissorMode(gl: anytype, window: *const WindowState, x: i32, ...) void {
    const Gl = @TypeOf(gl);
    const Inner = if (@typeInfo(Gl) == .pointer) @typeInfo(Gl).pointer.child else Gl;
    if (comptime @hasField(Inner, "userTextureId")) {
        // rlgl-specific bookkeeping
        rlgl.scopePush(gl, "scissor_mode");
        rlgl.fwd.rlDrawRenderBatchActive(gl);
    }
    // Polymorphic bit — works on both
    gl.enable(.scissor_test);
    gl.scissor(x, y, ...);
}
```

`@hasField(Inner, "userTextureId")` is a cheap way to say "is this an rlgl context?" Pick any field unique to one backend.

### Pattern: dual-mode app

```zig
const State = struct {
    gl: z.rlgl.GlState,        // for the on-screen render
    sw: z.rlsw.Context,        // for screenshots / regression captures
    sw_view: z.Texture,        // composite the sw output back into rlgl
};

fn renderUiTwice(s: *State, ctx: *ui.UiContext, window: *const WindowState) !void {
    // Live to screen
    var it = ctx.windows.iterator();
    while (it.next()) |e| e.value_ptr.*.draw_list.render(&s.gl, window, ..., ...);

    // Same UI, also to CPU framebuffer for the screenshot worker
    it = ctx.windows.iterator();
    while (it.next()) |e| e.value_ptr.*.draw_list.render(&s.sw, window, ..., ...);
}
```

Cost: rlsw rasterization is ~2-5ms for a typical UI on a midrange laptop. You probably wouldn't do this every frame, but doing it on demand (button press → save PNG) is fine.

---

## What's NOT in the adapter trait

These are renderer-specific by nature and aren't polymorphic:

- **Texture upload**: `rlgl.fwd.rlLoadTexture(...)` vs `rlsw.Context.texImage2D(...)` take totally different args. You write the upload path once per backend.
- **Framebuffer setup**: rlgl uses FBOs (`rlLoadFramebuffer`, `rlFramebufferAttach`); rlsw allocates a CPU buffer in `Context.init`.
- **Reading pixels back**: rlgl: `glReadPixels` via the GL forwarder. rlsw: `colorBufferBytes()` (zero-copy slice) or `readPixels(...)` (sub-rect copy).
- **Shaders**: rlgl has GLSL programs; rlsw has comptime-generated rasterizer kernels. The two can't share shader code.

These all live OUTSIDE `drawing.shapes.*` / `drawing.text.*` / `DrawList.render`. The polymorphic surface is **exactly** the immediate-mode + matrix-stack API needed to rasterize 2D and simple 3D primitives.

---

## How does the cheatsheet need to change?

The cheatsheet currently shows examples like `z.drawing.shapes.drawCircle(gl, ...)` with `gl: *rlgl.GlState` implied. Every example still works — the methods on `GlState` mean `*rlgl.GlState` satisfies the trait — but the cheatsheet should mention:

> **`gl: anytype`**: drawing functions accept any renderer satisfying the gl-context trait. Today: `*rlgl.GlState` (WebGL) and `*rlsw.Context` (CPU). The same code drives both.

A new cheatsheet section "Software rendering" with the rlsw setup boilerplate (init, ortho, clear, render, colorBufferBytes) would help.

The HTML README's section on rendering says rlgl is the renderer. That's no longer the whole truth. New copy:

> zimr ships two renderers: **rlgl** (a WebGL2 backend that runs in the browser) and **rlsw** (a pure-CPU rasterizer that runs anywhere). They share the same immediate-mode API — every `drawCircle`, `drawText`, `DrawList.render` works against either. The same source code that renders your game to WebGL in production can render UI screenshots to PNG in a host test, with no branching.

---

## FAQ

**Q: Why not use a trait/interface like Rust?**
A: Zig doesn't have those. The `anytype` + structural-typing approach gives the same ergonomics with zero ceremony — no `impl Renderer for GlState`, no vtable, no Box<dyn>. The compiler enforces the trait at the call site (via `assertIsGlContext`) instead of the type definition.

**Q: Can I add a third renderer?**
A: Yes. Define a struct with the same method surface (`begin`, `vertex2f`, …), pass `*MyRenderer` anywhere drawing.zig wants a `gl: anytype`. The trait check will verify the surface; if it compiles, it works. Examples of "third renderers" you might add: Vulkan, Metal, a PDF emitter, an SVG emitter, a no-op profiling stub that counts draw calls without drawing.

**Q: What if rlsw is missing a method I need?**
A: Add it to `rlsw.Context` (1-line forward to the existing rasterizer code) and to `rlgl.GlState` (1-line forward to the matching `rlX` free function). Then `drawing.zig` can call `gl.newMethod(...)` polymorphically.

**Q: Does `gl: anytype` slow down release builds?**
A: No. Comptime monomorphisation produces a fully-inlined specialised version per call site. Equivalent to writing two copies by hand, but you only write once.

**Q: What about `*GlAdapter` and `*SwAdapter` in `renderer_trait.zig`?**
A: Legacy. Before the methods landed on `GlState` directly (turn 317), the adapters were the only way to bridge `*rlgl.GlState` into the trait. They still work (the trait check passes for them too), but you don't need them — pass `*rlgl.GlState` directly. They may be deprecated in a future turn.
