# zimr

A Zig port of a subset of raylib and imgui.  Targets `wasm32-wasi`
with WebGL2.  No emscripten, no C dependencies.  Output is a wasm
binary plus a small JS runtime; deployment is a static directory.

zimr is not a wrapper around an upstream C library.  Every line is
Zig, compiled with the standard Zig toolchain, linked into a single
wasm module per example.  The public API is shaped to follow raylib
where the semantics carry over, and shaped around browser
constraints where they don't.

Status: covers most of raylib's in-scope public API — shapes, text,
textures, models, shaders, render textures, audio, input, gestures,
camera modes, mesh generation, animation.  Window-management
functions that don't map to a browser canvas (multi-monitor,
borderless modes, file dialogs, clipboard outside the page) are not
ported and won't be.  See `cheatsheet.html` for the full surface,
`docs.html` for the project notes, and the changelog files in
`src/notes/changelogs/` for per-turn history.

## Sister modules in the same source tree

`math.zig` is a hard fork of [zmath](https://github.com/zig-gamedev/zmath)
by Michal Ziulek, vendored at version 0.11.0-dev and then edited
freely.  Provides the row-major SIMD `Vec` / `Mat` / `Quat` types,
matrix builders, and quaternion operations the rest of zimr is
built on.  Exposed as `z.math` (typically aliased `const zm =
z.math;` in example code).

`physics.zig` is a single-file 3D rigid-body engine.  Algorithms
(GJK / EPA collision detection, sequential-impulse solver with
warm-start cache, Baumgarte position correction) are direct ports
of [zphys](https://github.com/AxelMathieuMahias/zphys) by Axel
Mathieu-Mahias, adapted to zimr's ECS layout and math API.
Sphere and box colliders; static and dynamic bodies; gravity,
friction, restitution.

`entities.zig` is a single-file archetype-based ECS adapted from
[Games-by-Mason/mr_ecs](https://codeberg.org/Games-by-Mason/mr_ecs),
stripped for single-threaded WASM (no Tracy, no async, no
threading).  Provides `Entities(T)` (pool-anchored with a primary
component, used for GPU resource worlds) and `World` (generic
archetype container).  Both share `CmdBuf` for deferred mutation
and `Tag` for classification.  Sits as a peer of `zimr` in the
dependency graph; examples may use both.

`rlsw.zig` is a from-scratch port of raylib's experimental
software-renderer header.  Renders into a CPU-resident RGBA8
framebuffer; immediate-mode API mirrors `rlgl`'s shape so scene
code ports nearly line-for-line.  Paired with `renderer_trait.zig`,
which adds a comptime trait and adapter pair so a single
`gl: anytype` function drives both rlgl and rlsw.
`examples/rlsw_side_by_side.zig` runs both pipelines on the same
scene with a cursor-driven divider, a live perf bar, and a
one-click pixel-diff overlay.

## Twelve small examples

Each example is a snippet, not a full program.  Wrap any of them
in the skeleton

```zig
pub export fn main() void {
    z.run(.{ .window = .{ .title = "demo", .width = 800, .height = 450 } },
          State, initState, update) catch |err| {
        std.debug.print("run failed: {s}\n", .{@errorName(err)});
    };
}
```

See `examples/basic.zig` for the smallest complete demo.

The contract: `Frame` is a 5-field pure-data struct
(`gl`, `input`, `window`, `time`, `audio_device`).  Anything
stateful that an app needs — fonts, scratch arenas, gestures,
loggers, the shapes-quad texture — lives on the user's `State`.
This makes effects explicit: when you look at an `initState` or
`update` signature, you see exactly what the function touches.
`initState` takes the state pointer as an out-parameter
(`fn (gpa, *Frame, *State) !void`) so freshly-allocated state
doesn't have to round-trip through a stack copy.

### 1. Clear the screen

```zig
fn update(f: *z.Frame, _: *State) void {
    z.beginDrawing(f.gl);
    z.clearBackground(f.gl, z.colors.slate_900);
    z.endDrawing(f.gl);
}
```

### 2. Draw a circle that follows the mouse

```zig
const State = struct {
    shapes_texture: z.ShapesTextureState = .{},
};

fn update(f: *z.Frame, state: *State) void {
    z.beginDrawing(f.gl);
    z.clearBackground(f.gl, z.colors.slate_950);
    const m: z.Vector2 = z.getMousePosition(f.input);
    z.drawCircleV(f.gl, &state.shapes_texture, m, 24, z.colors.amber_400);
    z.endDrawing(f.gl);
}
```

`Vector2` is `@Vector(2, f32)`; index components as `m[0]` / `m[1]`
or use vector arithmetic directly (`m + .{ 1, 2 }`).

### 3. Move a square with WASD

```zig
const State = struct {
    shapes_texture: z.ShapesTextureState = .{},
    x: f32 = 100,
    y: f32 = 100,
};

fn update(f: *z.Frame, state: *State) void {
    const dt: f32 = @floatCast(f.time.delta_time);
    if (z.isKeyDown(f.input, .a)) state.x -= 240 * dt;
    if (z.isKeyDown(f.input, .d)) state.x += 240 * dt;
    if (z.isKeyDown(f.input, .w)) state.y -= 240 * dt;
    if (z.isKeyDown(f.input, .s)) state.y += 240 * dt;
    z.beginDrawing(f.gl);
    z.clearBackground(f.gl, z.colors.slate_900);
    z.drawRectangle(
        f.gl,
        &state.shapes_texture,
        @intFromFloat(state.x),
        @intFromFloat(state.y),
        32,
        32,
        z.colors.sky_400,
    );
    z.endDrawing(f.gl);
}
```

### 4. Print FPS each frame

```zig
const State = struct {
    font_cache: z.FontCache = .{},
    scratch: std.heap.ArenaAllocator,
};

fn initState(gpa: std.mem.Allocator, _: *z.Frame, s: *State) !void {
    s.* = .{ .scratch = std.heap.ArenaAllocator.init(gpa) };
    try z.loadFontDefault(gpa, &s.font_cache);
}

fn update(f: *z.Frame, state: *State) void {
    _ = state.scratch.reset(.retain_capacity);
    const fps_int: i32 = @intFromFloat(1.0 / f.time.delta_time);
    const txt = std.fmt.allocPrint(
        state.scratch.allocator(),
        "fps: {d}",
        .{fps_int},
    ) catch return;
    z.beginDrawing(f.gl);
    z.clearBackground(f.gl, z.colors.black);
    z.drawText(f.gl, &state.font_cache, 2, txt, 12, 12, 20, z.colors.green_400);
    z.endDrawing(f.gl);
}
```

The `2` argument to `drawText` is the font id inside `font_cache`;
the default font loaded by `loadFontDefault` lives at id 2.

### 5. Load a PNG and draw it

```zig
const State = struct {
    textures: z.Entities(z.gpu.GpuTexture),
    smiley: z.gpu.TextureHandle,
};

fn initState(gpa: std.mem.Allocator, f: *z.Frame, s: *State) !void {
    var textures: z.Entities(z.gpu.GpuTexture) = try .init(
        gpa,
        .{ .capacity = 8 },
    );
    errdefer textures.deinit(gpa);
    const png_bytes = @embedFile("smiley_png");
    const smiley = try z.gpu.loadTextureFromMemory(
        f.gl,
        gpa,
        &textures,
        png_bytes,
    );
    s.* = .{ .textures = textures, .smiley = smiley };
}

fn update(f: *z.Frame, state: *State) void {
    z.beginDrawing(f.gl);
    z.clearBackground(f.gl, z.colors.slate_900);
    z.gpu.drawTexture(f.gl, &state.textures, state.smiley, 100, 100, z.colors.white);
    z.endDrawing(f.gl);
}
```

GPU resources are entities in a user-owned ECS world; `gpu.Texture`
/ `gpu.Mesh` / `gpu.Shader` / `gpu.Material` are phantom-typed
references (`Ref(T)`) that dereference through the world.  Stale
refs return `null` rather than UB.

### 6. 3D cube under a perspective camera

```zig
const zm = z.math;

fn update(f: *z.Frame, _: *State) void {
    const cam: z.Camera3D = .{
        .position = zm.vec3(4, 4, 4),
        .target = zm.vec3(0, 0, 0),
        .up = zm.vec3(0, 1, 0),
        .fovy = 60,
        .projection = 0, // 0 = perspective, 1 = orthographic
    };
    z.beginDrawing(f.gl);
    z.clearBackground(f.gl, z.colors.slate_950);
    z.beginMode3D(f.gl, cam);
    z.drawCubeV(f.gl, zm.vec3(0, 0, 0), zm.vec3(1, 1, 1), z.colors.red);
    z.drawGrid(f.gl, 10, 1.0);
    z.endMode3D(f.gl);
    z.endDrawing(f.gl);
}
```

`Camera3D` is a plain struct (not `extern`).  Its `position` /
`target` / `up` fields are `zm.Vec` (4-wide SIMD); construct via
`zm.vec3` and read components as `cam.position[0]` etc.

### 7. Render to a 256×256 offscreen target

```zig
const State = struct {
    shapes_texture: z.ShapesTextureState = .{},
    rt: z.RenderTexture2D,
};

fn initState(_: std.mem.Allocator, _: *z.Frame, s: *State) !void {
    s.* = .{ .rt = try z.loadRenderTexture(256, 256) };
}

fn update(f: *z.Frame, state: *State) void {
    z.beginDrawing(f.gl);

    z.beginTextureMode(f.gl, state.rt);
    z.clearBackground(f.gl, z.colors.violet_700);
    z.drawCircle(f.gl, &state.shapes_texture, 128, 128, 64, z.colors.amber_300);
    z.endTextureMode(f.gl, f.window);

    z.clearBackground(f.gl, z.colors.slate_900);
    z.drawTexture(f.gl, state.rt.texture, 50, 50, z.colors.white);
    z.endDrawing(f.gl);
}
```

### 8. Custom fragment shader

```zig
const fs_source =
    \\#version 300 es
    \\precision mediump float;
    \\in vec2 fragTexCoord;
    \\in vec4 fragColor;
    \\out vec4 finalColor;
    \\uniform float uTime;
    \\void main() {
    \\    float v = 0.5 + 0.5 * sin(uTime + fragTexCoord.x * 10.0);
    \\    finalColor = fragColor * vec4(v, v, 1.0, 1.0);
    \\}
;

const State = struct {
    shapes_texture: z.ShapesTextureState = .{},
    shader: z.Shader,
    loc_time: i32,
};

fn initState(gpa: std.mem.Allocator, f: *z.Frame, s: *State) !void {
    const shader = try z.loadShaderFromMemory(f.gl, gpa, "", fs_source);
    s.* = .{
        .shader = shader,
        .loc_time = z.getShaderLocation(shader, "uTime"),
    };
}

fn update(f: *z.Frame, state: *State) void {
    var t: f32 = @floatCast(f.time.current);
    z.setShaderValue(state.shader, state.loc_time, &t, .float);
    z.beginDrawing(f.gl);
    z.clearBackground(f.gl, z.colors.slate_900);
    z.beginShaderMode(f.gl, state.shader);
    z.drawRectangle(f.gl, &state.shapes_texture, 0, 0, 800, 450, z.colors.white);
    z.endShaderMode(f.gl);
    z.endDrawing(f.gl);
}
```

`setShaderValue` copies through a pointer; the value must outlive
the call.  Use a `var` local, not a `const`-promoted temporary.

### 9. Async fetch a file

```zig
const State = struct {
    loader_browser: z.runtime.effects.loader.Browser = .{},
    loader: z.Loader = undefined,
    handle: z.loader.Handle = 0,
};

fn initState(_: std.mem.Allocator, _: *z.Frame, s: *State) !void {
    s.* = .{};
    s.loader = s.loader_browser.loader();
}

fn update(f: *z.Frame, state: *State) void {
    if (state.handle == 0) {
        state.handle = state.loader.loadFileData("data.bin");
    }
    switch (state.loader.pollFileData(state.handle)) {
        .pending => {},
        .ok => |bytes| {
            _ = bytes; // use the []const u8
        },
        .not_found, .network_failed => {},
    }
    z.beginDrawing(f.gl);
    z.clearBackground(f.gl, z.colors.slate_900);
    z.endDrawing(f.gl);
}
```

The `Browser` / `Loader` pair is zimr's effect-injection pattern:
production uses the browser-backed implementation; tests bind a
mock that serves bytes from an in-memory table.

### 10. Touch / multi-finger paint

```zig
const State = struct {
    shapes_texture: z.ShapesTextureState = .{},
};

fn update(f: *z.Frame, state: *State) void {
    z.beginDrawing(f.gl);
    z.clearBackground(f.gl, z.colors.slate_950);
    const count: i32 = z.getTouchPointCount(f.input);
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const p: z.Vector2 = z.getTouchPosition(f.input, i);
        z.drawCircleV(f.gl, &state.shapes_texture, p, 32, z.colors.rose_400);
    }
    z.endDrawing(f.gl);
}
```

### 11. ECS — spawn entities, iterate, defer destroy

```zig
const ent = z.entities;
const Pos = struct { x: f32, y: f32 };
const Vel = struct { x: f32, y: f32 };

const State = struct {
    shapes_texture: z.ShapesTextureState = .{},
    gpa: std.mem.Allocator,
    es: ent.World,
    cb: ent.CmdBuf,
};

fn initState(gpa: std.mem.Allocator, _: *z.Frame, s: *State) !void {
    var es: ent.World = try .init(.{
        .gpa = gpa,
        .cap = .{ .entities = 256, .arches = 8, .chunks = 16, .chunk = 4096 },
    });
    const cb: ent.CmdBuf = try .init(.{
        .name = "demo",
        .gpa = gpa,
        .es = &es,
        .cap = .{ .cmds = 256 },
    });
    s.* = .{ .gpa = gpa, .es = es, .cb = cb };
}

fn update(f: *z.Frame, s: *State) void {
    z.beginDrawing(f.gl);
    z.clearBackground(f.gl, z.colors.slate_950);
    const dt: f32 = @floatCast(f.time.delta_time);

    const m = z.getMousePosition(f.input);
    const e = ent.Entity.reserve(&s.cb);
    _ = e.add(&s.cb, Pos, .{ .x = m[0], .y = m[1] });
    _ = e.add(&s.cb, Vel, .{ .x = 0, .y = 60 });

    s.es.forEach(struct {
        fn run(
            ctx: struct { dt: f32, cb: *ent.CmdBuf },
            entity: ent.Entity,
            p: *Pos,
            v: *const Vel,
        ) void {
            p.y += v.y * ctx.dt;
            if (p.y > 600) entity.destroy(ctx.cb);
        }
    }.run, .{ .dt = dt, .cb = &s.cb });
    ent.CmdBuf.Exec.immediate(&s.es, s.gpa, &s.cb);

    const RenderCtx = struct {
        gl: *z.rlgl.GlState,
        tex: *const z.ShapesTextureState,
    };
    s.es.forEach(struct {
        fn run(ctx: RenderCtx, p: *const Pos) void {
            z.drawCircle(
                ctx.gl,
                ctx.tex,
                @intFromFloat(p.x),
                @intFromFloat(p.y),
                3,
                z.colors.amber_300,
            );
        }
    }.run, RenderCtx{ .gl = f.gl, .tex = &s.shapes_texture });
    z.endDrawing(f.gl);
}
```

`World` is the raw archetype container — suitable for the "every
component is a secondary" pattern shown here.  `Entities(T)` is
the pool-anchored variant used when one component (a GPU
resource, typically) is primary; see the `gpu` module.

### 12. Software rasterizer + dual pipeline

```zig
const State = struct {
    sw: z.rlsw.Context,
    sw_view: z.Texture2D,
};

fn initState(gpa: std.mem.Allocator, _: *z.Frame, s: *State) !void {
    var sw = try z.rlsw.Context.init(gpa, 400, 225);
    errdefer sw.deinit(gpa);
    const seed = try z.genImageColor(gpa, 400, 225, z.colors.slate_900);
    defer z.unloadImage(gpa, seed);
    s.* = .{ .sw = sw, .sw_view = try z.loadTextureFromImage(seed) };
}

// One scene function, two backends.  `assertIsGlContext` is a
// comptime trait check — if the adapter is missing a method, the
// compile error names it.
fn drawScene(gl: anytype, t: f32) void {
    z.assertIsGlContext(gl);
    gl.clearColor(.{ .r = 30, .g = 60, .b = 100, .a = 255 });
    gl.clear(.{ .color = true, .depth = true });
    gl.matrixMode(.modelview);
    gl.loadIdentity();
    gl.begin(.triangles);
    gl.color4ub(255, 0, 0, 255);
    gl.vertex2f(@cos(t), @sin(t) * 0.5);
    gl.color4ub(0, 255, 0, 255);
    gl.vertex2f(@cos(t + 2.094), @sin(t + 2.094) * 0.5);
    gl.color4ub(0, 0, 255, 255);
    gl.vertex2f(@cos(t + 4.188), @sin(t + 4.188) * 0.5);
    gl.end();
}

fn update(f: *z.Frame, s: *State) void {
    const t: f32 = @floatCast(f.time.current);
    z.beginDrawing(f.gl);
    z.clearBackground(f.gl, z.colors.slate_950);

    var sw_adapter: z.SwAdapter = .init(&s.sw);
    drawScene(&sw_adapter, t);
    z.updateTexture(s.sw_view, s.sw.colorBufferBytes().ptr);
    z.drawTexture(f.gl, s.sw_view, 0, 0, z.colors.white);
    z.endDrawing(f.gl);
}
```

For the full dual-pipeline demo (cursor-driven divider, perf bar,
pixel-diff overlay), see `examples/rlsw_side_by_side.zig`.

## Build commands

```sh
zig build                       # production install — ReleaseSmall wasm to zig-out/web/
zig build -Doptimize=Debug      # debug install (slower wasm, full safety checks)
zig build test                  # 1373 host unit tests + typecheck every example
zig build smoke-test            # 100 wasm smoke tests in a headless browser harness
zig build smoke-install         # build smoke artifacts only, no run
zig build serve                 # Bun dev server on :8000 over zig-out/web/
zig build run-<name>            # build + serve + open one example
                                #   e.g. zig build run-basic
zig build math-test             # vendored zmath's own test suite
zig build docs                  # Zig autodoc → zig-out/web/docs/
zig build dist                  # refresh prebuilt/ from zig-out/web/
```

`zig build` produces a complete site rooted at `zig-out/web/`:
one wasm per example, the bundled JS runtime, and assets.  Open
`http://localhost:8000/` after `zig build serve` to browse them.

Pass `--release=small` to `zig build smoke-test` (or set
`-Dsmoke-optimize=ReleaseSmall`) to run smoke against the
production-mode wasm.  The default keeps smoke artifacts in Debug
so a crash inside the harness gives precise traces.

The release-zip workflow:

```sh
zig build
zig build dist
zip -r zimr.zip . -x "zig-out/*" ".zig-cache/*" ".git/*"
```

## Standalone HTML bundles

Any example can be assembled into a single self-contained HTML
file — the JS runtime and the wasm payload both inlined, no
server or sibling files needed.  Useful for sharing a demo via
email, dragging it into a chat, or embedding it in an iframe.

```sh
python3 scripts/build_standalone.py basic        # → prebuilt/standalone/basic.html
python3 scripts/build_standalone.py imgui_demo --title "Dear ImGui"
python3 scripts/build_standalone.py rlsw_side_by_side --no-build
```

`build_standalone.py` runs `zig build install --release=small`
itself before reading the wasm.  Pass `--no-build` to skip the
pre-build step when a fresh ReleaseSmall wasm already exists in
`zig-out/web/`.

Typical bundle sizes for ReleaseSmall builds:

| Example              | Bundle |
|----------------------|--------|
| `basic`              | ~280 KB |
| `cube3d`             | ~240 KB |
| `rlsw_side_by_side`  | ~360 KB |
| `imgui_demo`         | ~920 KB |

The bundle uses `URL.createObjectURL` to feed the wasm bytes back
into the runtime's existing fetch-based instantiation path, so it
works inside sandboxed iframe contexts where the surrounding page
restricts cross-origin fetches.

The canvas is sized to fill the viewport by default (host CSS:
`canvas { width: 100vw; height: 100vh }`); a JS resize listener
updates the drawing buffer on window resize or phone rotation.
Examples that opt into `WindowConfig.scale = .responsive` get a
per-frame `rlOrtho` reset so their draw coordinates track the
current CSS-pixel space.  The default `.stretch` mode keeps the
init-time logical box and lets GL stretch content to fit.

Limitations:
- Examples that fetch external assets at runtime
  (`load_image_demo`, `gltf_*`, `music_streaming`) fail in
  standalone bundles because the fetch URLs resolve to `null`.
  Standalone suits examples whose assets are either
  `@embedFile`-d into the wasm or generated procedurally.

## Toolchain

- **Zig 0.16.0** — pinned; new releases change source-level API.
  Download from https://ziglang.org/download/.
- **Bun ≥ 1.3** — used by `zig build smoke-test` and
  `zig build serve`.  Install: `curl -fsSL https://bun.sh/install | bash`.
- **Python 3** — only for `scripts/build_standalone.py`,
  `scripts/build_cheatsheet.py`, and `scripts/build_docs.py`.
  Ships with every Python install.

`zig build test` is pure-Zig; works without Bun or Python.

## File organization

```
zimr/
├── build.zig
├── build.zig.zon
├── LICENSE                     # zlib/libpng + third-party attribution
├── README.md                   # this file
├── cheatsheet.html             # generated API reference (build_cheatsheet.py)
├── docs.html                   # generated kitchen-sink notes (build_docs.py)
├── src/
│   ├── zimr.zig                # public surface (App, Frame, run, flat re-exports)
│   ├── types.zig               # public data types — leaf, std-only
│   ├── errors.zig              # composed error sets (LoadError, …)
│   ├── assert.zig              # Bun-style assert / assertf
│   ├── web.zig                 # extern bindings: dom, gl, fetch, audio
│   ├── gl.zig                  # WebGL2 wrapper
│   ├── codecs.zig              # png, gltf, truetype, rectpack, code_point
│   ├── math.zig                # vendored zmath fork + zimr-additions
│   ├── easings.zig             # raylib's easing functions
│   ├── rlgl.zig                # rlgl matrix stack + GPU batch + default shaders
│   ├── rlsw.zig                # software renderer (rlsw.h port, pure-Zig)
│   ├── rlsw_pixel.zig          # pixel-format codecs for rlsw
│   ├── renderer_trait.zig            # `gl: anytype` trait + GlAdapter / SwAdapter
│   ├── entities.zig            # Entities(T), World, CmdBuf, Tag, Node
│   ├── gpu.zig                 # ref-based GPU resources (textures, meshes, …)
│   ├── scene.zig               # scene components, RenderList, compile()
│   ├── render.zig              # PBR renderer + shadow pass + skybox
│   ├── physics.zig             # 3D rigid-body engine (zphys port)
│   ├── sound.zig               # audio device + Wave/Sound/Music
│   ├── runtime.zig             # core, input, gestures, time, fps, log, rng
│   ├── drawing.zig             # textures, text, models, shapes, shaders
│   ├── ui.zig                  # immediate-mode UI (imgui-inspired)
│   ├── runtime_assembly.zig    # Runtime aggregate + JS-bridge shims
│   ├── tests.zig               # test aggregator
│   ├── tests/                  # integration tests (leak, errors, scene, multiapp)
│   ├── notes/                  # plans, design docs, changelogs, CHEATSHEET.md
│   └── web/                    # JS/TS runtime + index.html
├── examples/                   # 103 self-contained .zig demos
├── webtests/                   # Bun-driven smoke + dev server
├── scripts/                    # build/audit/codegen tooling
└── assets/                     # smiley.png + RobotoMono-Regular.ttf + sample.ogg
```

The dependency graph is a strict DAG validated by
`scripts/check_dag.py`.  `types.zig` is `std`-only (no sibling
imports); every other module's edges point downward.  One
allowlisted cycle: `ui ↔ zimr` (the two files form a logical
module split across files).  `scripts/count_globals.py`
separately verifies no module-level `var` lives outside the two
documented C-ABI seams.

## Resources + renderer

The 3D rendering path is built around explicit user-owned
resources.  `gpu.Resources` is an aggregation of ECS worlds for
meshes, textures, shaders, render-textures, fonts, and materials.
Every GPU resource is an entity — load returns a phantom-typed
`Ref(T)` (the user-facing handles are `gpu.Mesh`,
`gpu.Texture2D`, `gpu.Shader`, `gpu.Material`).  Refs survive
entity destruction (`deref` returns `null` rather than UB).

The renderer takes a `RenderDefaults` bundle from
`render.createDefaultMaterialsAndShaders(gpa, &resources, gl)`
— also user-owned — and submits draws via a `RenderList`
compiled from `Transform` / `MeshDraw` components on ECS
entities.  Materials are spawned upfront via
`gpu.spawnLitMaterial` / `spawnUnlitMaterial` / etc.; their refs
go into `MeshDraw.material`.  See `examples/pbr_demo.zig` and
`examples/split_screen.zig` for end-to-end uses.

## Licenses

zimr is licensed under the **zlib/libpng** license to match raylib
upstream.  The full text — plus per-upstream attribution and
reproduced license notices — is in `LICENSE`.

The choice of zlib was driven by raylib.  zimr is, in volume,
mostly a port of raylib, and raylib's zlib license is mildly viral
in the sense that derivative ports inherit clauses 1-3: no
misrepresentation, mark altered versions, preserve the notice.
MIT and zlib are roughly equivalent in spirit; we picked zlib
because that's what raylib uses.

`entities.zig` is adapted from `mr_ecs`, MIT-licensed.
`physics.zig` is adapted from `zphys`, MIT-licensed.  `math.zig`
is a hard fork of `zmath`, MIT-licensed.  The MIT notice for
each travels with the file's header comment in addition to being
reproduced in `LICENSE`.  Both licenses are permissive; `LICENSE`
at the project root preserves every upstream's notice.

Summary of upstreams adapted into zimr's source tree:

| Upstream                                          | License             | Used for                                                          |
| ------------------------------------------------- | ------------------- | ----------------------------------------------------------------- |
| **raylib** — Ramon Santamaria (`@raysan5`)        | zlib/libpng         | the bulk of zimr — API shape, data layouts, algorithms            |
| **rlgl** — bundled with raylib                    | zlib/libpng         | matrix stack + GPU batch + default shaders                        |
| **rlsw** — experimental, bundled with raylib      | zlib/libpng         | `src/rlsw.zig` + `src/rlsw_pixel.zig`, software renderer port     |
| **Dear ImGui** — Omar Cornut (`@ocornut`)         | MIT                 | `src/ui.zig` — API shape and behavioural conventions              |
| **zmath** — Michal Ziulek (zig-gamedev)           | MIT                 | `src/math.zig` — vendored hard fork at 0.11.0-dev                 |
| **zphys** — Axel Mathieu-Mahias                   | MIT                 | `src/physics.zig` — GJK/EPA collision + sequential-impulse solver |
| **mr_ecs** — Mason Remaley (Games-by-Mason)       | MIT                 | `src/entities.zig` — archetype ECS adapted for single-thread WASM |
| **stb_truetype** — Sean Barrett (`nothings`)      | MIT / public domain | TTF parsing + glyph rasterization (via andrewrk/TrueType)         |
| **andrewrk/TrueType** — Andrew Kelley             | MIT                 | pure-Zig port of stb_truetype that `src/codecs.zig` adapts        |
| **zg / code_point.zig** — Sam Atman               | MIT                 | UTF-8 decoder vendored at `src/_vendor/zg/code_point.zig`         |
| **ziglyph** — José Colón (`jecolon`)              | MIT                 | predecessor of zg; lineage acknowledged                           |
| **UTF-8 DFA** — Björn Höhrmann                    | MIT                 | decode tables inside `code_point.zig`                             |
| **Tailwind CSS palette** — Tailwind Labs          | MIT                 | named color values in `src/drawing.zig`                           |
| **Roboto Mono** — Christian Robertson (Google)    | Apache 2.0          | `assets/RobotoMono-Regular.ttf`                                   |
| **raylib-zig** — Nikolas Wipper (`Not-Nik`)       | MIT                 | inspiration for the two-tier API split (no code copied)           |

If you ship a binary that bundles zimr, you don't owe anyone
anything beyond preserving these notices.  If you ship source that
includes adapted zimr files, the source-form notice must travel
with the file (zlib clause 3, MIT permission notice, etc.).
`LICENSE` is the single file that satisfies every upstream's
notice-preservation clause; ship it next to your binary.

If you're using zimr, the people whose work you're standing on
include `raysan5` (raylib), `ocornut` (Dear ImGui), Michal Ziulek
(zmath), Axel Mathieu-Mahias (zphys), Mason Remaley (mr_ecs),
`nothings` (stb), `andrewrk` (TrueType / Zig), Sam Atman (zg),
`jecolon` (ziglyph), Björn Höhrmann (UTF-8 DFA), Tailwind Labs,
the Google Fonts team, and `Not-Nik` (raylib-zig).  Most of
zimr's value comes from their work.

## Human use disclaimer

zimr was developed over approximately three weeks of subway
commutes by Simon Clavet, working from his phone.

Simon had the idea, gave the direction, designed the
architecture, decided what was in scope and what wasn't, wrote
the style guide, picked the conventions, read the diffs, ran the
demos, found the bugs, verified the fixes, and decided when a
turn was done.  Claude wrote text into a chat box on a phone
screen.

The project would not exist without him.  It would not have
started, would not have stayed coherent across hundreds of turns,
would not have shipped, would not have been correct, and would
not have a finger-aligned divider.  The non-trivial decisions
are his.

If you have feelings about AI-assisted software, this paragraph
is not trying to change them.  It just records what happened:
one human, with a clear plan, on his phone, on a train, every
weekday for three weeks.
