# Migrating from raylib (C) to zimr

If you know raylib's C API, most of zimr will feel familiar — the
function names map 1:1, the struct layouts are bit-compatible, and
the rendering model is the same.  This document calls out the
**deltas** so you know what to change.

## Naming

zimr uses Zig conventions: **camelCase** functions, **PascalCase**
types, **SCREAMING_SNAKE** for `c_int` enum constants.

| raylib (C) | zimr (Zig) |
|---|---|
| `DrawRectangle(x, y, w, h, c)` | `z.shapes.drawRectangle(x, y, w, h, c)` |
| `LoadTexture(path)` | `z.textures.loadTexture(path)` (deferred — see below) |
| `BeginMode3D(cam)` | `z.camera.beginMode3D(cam)` |
| `Vector3Add(a, b)` | `z.raymath.vector3Add(a, b)` *or* `a.add(b)` |
| `Image`, `Texture2D`, `Color` | `z.types.Image`, `z.types.Texture2D`, `z.types.Color` (or via `z.types.*`) |
| `KEY_SPACE` | `z.enums.KEY_SPACE` |
| `RAYWHITE` | `z.colors.white` (Tailwind palette is the new default) |

Helper namespacing: math operations are reachable both as **free
functions** (`vector3Add(a, b)`) and **method-style** (`a.add(b)`)
where the receiver makes sense.  Use whichever reads better.

## Module surface

raylib is one giant header.  zimr breaks it up:

| zimr module | raylib equivalent |
|---|---|
| `z.core` | `rcore` (frame timer, log, FPS) |
| `z.input` | input section of `rcore` |
| `z.shapes` | `rshapes` (2D primitives) |
| `z.textures` | `rtextures` (Image + Texture) |
| `z.text` | `rtext` (font loading + drawText) |
| `z.models` | `rmodels` (Mesh + Model + 3D primitives) |
| `z.camera` | camera helpers from `rcore` |
| `z.shaders` | shader helpers from `rcore`/`rlgl` |
| `z.raymath` | `raymath.h` |
| `z.rlgl` | `rlgl.h` (low-level GL state) |
| `z.colors` | the named Color constants |

## What stays the same

- **Struct layout.**  `Image`, `Texture2D`, `Color`, `Vector3`,
  `Matrix`, `Camera3D`, `Mesh`, `Material`, `Model` — all
  `extern struct` with the same field order/types as raylib 6.0.
  You can pass a wasm-side `Image` through the C ABI without
  surprise.
- **Frame model.**  `update(frame)` runs once per browser RAF.
  Inside it, you draw via `z.shapes.*` / `z.text.*` / `z.textures.*`
  / `z.models.*`.  No `BeginDrawing` / `EndDrawing` — the runtime
  brackets each frame for you.
- **rlgl.**  `rlPushMatrix`/`rlPopMatrix`/`rlLoadIdentity`/
  `rlMultMatrixf`, `rlBegin`/`rlEnd` immediate mode, the whole
  matrix stack — exact API match.
- **Default font.**  `z.text.draw("hello", x, y, size, color)`
  works identically.  The 9px embedded font ships with zimr.

## What changes

### File I/O is async, not sync

raylib's `LoadTexture("file.png")` blocks on disk.  In a browser
there is no synchronous disk.  zimr provides:

```zig
// Embed at compile time (recommended for small fixed assets):
const img = z.png.decode(@embedFile("smiley.png"));

// Or fetch async at runtime:
var handle = z.fetch.start("https://example.com/img.png");
// In your update loop:
switch (z.fetch.poll(handle)) {
    .pending => return,
    .complete => |bytes| { /* decode + upload */ },
    .error_ => return,
}
```

`examples/png_demo.zig` shows the embed path.
`examples/load_image_demo.zig` shows the async path.

### Errors are explicit, not `id == 0`

raylib indicates failure by returning a struct with `id == 0`.
zimr migrating that pattern over to `error` unions:

```zig
// raylib (C):
Texture2D tex = LoadTexture("foo.png");
if (tex.id == 0) { /* failed */ }

// zimr (Zig):
const tex = z.textures.loadTexture("foo.png") catch |err| {
    std.debug.print("Failed: {s}\n", .{@errorName(err)});
    return;
};
```

Migration is gradual — many functions still return
`id-zero-on-failure` for raylib parity.  The roadmap §5 closes
this out.

### Allocator-explicit (work-in-progress)

raylib hides allocations.  zimr is moving to **explicit allocator
parameters** for any function that allocates.  Today the picture
is mixed:

- Some functions take an explicit `Allocator` (newer code,
  e.g. `exportMeshAsObj(gpa, mesh, name)`).
- Some go through `libc.malloc` (raylib parity, returns null on
  host so host tests cover defensive paths only).
- Some use the per-frame arena (`f.frame`) — caller doesn't see
  the allocator at all.

Roadmap §5 (Steps 49-55) finishes the migration so every
heap-allocating function takes an explicit `Allocator`.

### No audio yet (mostly)

`z.audio` exists but is a proof-of-binding shape, not a full
engine.  Phase 9 (Steps 81-88) adds proper sample playback,
mixing, streaming.  For now: sine-wave tones via Web Audio,
nothing else.

### No file system

`isFileNameValid` exists for compatibility, but there's no
`SaveFileText`, `LoadFileText`, `LoadDirectoryFiles`, etc.
The browser sandbox does not give us a writable filesystem.
Workarounds:

- **Save**: build a `[]u8` in memory, then `URL.createObjectURL`
  + anchor click on the JS side.  (`exportMeshAsObj` returns
  bytes ready for this.)
- **Load**: `<input type="file">` → `Blob.arrayBuffer()` → wasm
  via fetch-style polling.  Plumbing this through zimr's API is
  on the roadmap.

### Window / cursor differences

- **No fullscreen toggle.**  Browsers control fullscreen via the
  Fullscreen API; we don't expose it.  Smoke-test compatibility
  reasons mostly.
- **Pointer-lock requires a user gesture.**  `disableCursor()`
  silently no-ops until the user has clicked.  Examples
  document this.
- **No window decorations / move / resize from code.**  The
  canvas is the window; the browser owns the chrome.

## What's missing (still)

Roughly:
- Audio (Phase 9).
- TTF font loading (Step 60).
- More image formats — JPEG, BMP, TGA, QOI, GIF (Phase 7,
  zigimg adoption).
- glTF / OBJ model loading (Phase 8).
- File-dialog APIs.
- Some `getRayCollision*` variants.

See [`ROADMAP.md`](../ROADMAP.md) for the full picture.

## Quick reference: 30-second cheat sheet

```zig
// Init
state.app = try z.init(.{ .window = .{ .title = "x", .width = w, .height = h } });

// Each frame:
fn update(f: *z.Frame) void {
    f.clear(z.colors.black);

    // 2D
    z.shapes.drawRectangle(x, y, w, h, color);
    z.text.draw("hi", x, y, size, color);

    // 3D
    z.camera.beginMode3D(cam);
    z.models.drawCube(pos, w, h, d, color);
    z.camera.endMode3D();

    // Input
    if (z.input.isKeyDown(z.enums.KEY_SPACE)) ...
    const m = z.input.getMousePosition();

    // Per-frame arena
    const s = std.fmt.allocPrint(f.frame, "fps {d}", .{60}) catch return;
    z.text.draw(s, 12, 12, 16, z.colors.white);
}
```

That's the whole API in one screen.
