# Investigating: should zimr's `main` take `std.process.Init`?

**Verdict: not worth shaving today. Filed for revisit when zimr ships v1.0 or when we add host-side tooling that needs more than ad-hoc `Threaded.init()`.**

This note documents the investigation done at turn 317 — what changed in Zig 0.16 since the Phase 12 notes said "Init doesn't exist", what we'd gain by adopting the new shape, and what blocks it.

## What changed: Zig 0.16 has `std.process.Init`

The Phase 12 plan (archived) said:

> The original sketch said `pub fn main(init: std.process.Init) !void`. Verified during 12.5 research: `std.process.Init` does NOT exist in stdlib. Define our own `InitArgs`…

That's now stale. Zig 0.16 added `std.process.Init` and reworked `start.zig` to detect main's signature at comptime and route accordingly:

```zig
// std/start.zig:696
inline fn callMain(args: ..., environ: ...) u8 {
    const fn_info = @typeInfo(@TypeOf(root.main)).@"fn";
    if (fn_info.params.len == 0) return wrapMain(root.main());
    if (fn_info.params[0].type.? == std.process.Init.Minimal) return wrapMain(root.main(.{
        .args = .{ .vector = args },
        .environ = .{ .block = environ },
    }));
    // ↓ Otherwise the full Init path: build gpa + arena + Io + environ_map + preopens.
    ...
    return wrapMain(root.main(.{
        .minimal = .{ .args = ..., .environ = ... },
        .arena = &arena_allocator,
        .gpa = gpa,
        .io = threaded.io(),
        .environ_map = &environ_map,
        .preopens = preopens,
    }));
}
```

`std.process.Init` looks like this (`std/process.zig:30`):

```zig
pub const Init = struct {
    minimal: Minimal,         // env + argv
    arena: *std.heap.ArenaAllocator,   // process-lifetime arena
    gpa: Allocator,                    // default-selected gpa
    io: Io,                            // Io.Threaded.io() handle
    environ_map: *Environ.Map,
    preopens: Preopens,
};
```

So today, if a Zig program writes:

```zig
pub fn main(init: std.process.Init) !void {
    var sw = try z.rlsw.Context.init(init.gpa, 800, 600);
    defer sw.deinit(init.gpa);

    // ... draw stuff ...

    var f = try std.Io.Dir.cwd().createFile(init.io, "out.png", .{});
    defer f.close(init.io);
    try f.writeStreamingAll(init.io, png_bytes);
}
```

…it gets `gpa` + `io` for free from the language. No `var gpa_state: DebugAllocator(.{}) = .init; const gpa = gpa_state.allocator(); var threaded = std.Io.Threaded.init(gpa, .{});` boilerplate per main.

## What zimr does today

Every example follows this pattern:

```zig
pub export fn main() void {
    z.run(.{
        .window = .{ .title = "demo", .width = 800, .height = 450 },
    }, State, initState, update) catch |err| {
        std.debug.print("zimr run failed: {s}\n", .{@errorName(err)});
    };
}
```

`pub export fn main()` (not `pub fn main`) because `runtime.js` calls a specific WebAssembly export symbol. `z.run`'s `Config.gpa` defaults to `std.heap.wasm_allocator`. No `io` plumbed through.

When tests OR host scripts need `io`, they construct it locally:

```zig
var io_threaded = std.Io.Threaded.init(gpa, .{});
defer io_threaded.deinit();
const io = io_threaded.io();
// ... use io ...
```

That's 3 lines, deduplicable into a helper if it ever became annoying.

## The case for switching

**Pros**:
1. Standard Zig 0.16 entry shape — new users coming from `zig init` find the same `pub fn main(init)` everywhere.
2. Free `io` for host tools — tests, the screenshot driver, any future asset-pipeline scripts.
3. Free `gpa` selection — Debug builds get `DebugAllocator` (leak-checked); release gets `c_allocator` or `wasm_allocator` automatically.
4. Free process arena — for things that need a "lives for the whole program" allocation budget without managing it yourself.

**Cons**:
1. **Breaking change for every example** (~148 files). Each `pub export fn main()` becomes `pub fn main(init: std.process.Init) !void`.
2. **The `export` matters for wasm-wasi reactor mode** — runtime.js calls the export. Removing `export` may break the JS-side entry; needs verification.
3. **`io` is useless inside wasm games** — wasm browser games don't do file I/O. Input comes from JS event listeners, output goes to canvas pixels. The single user of `io` in zimr (the screenshot test) constructs it locally and that's fine.
4. **The migration is orthogonal to the docking arc** that's currently in flight. Doing it now means a context switch that doesn't move us closer to docking.

## What blocks adoption

The wasm reactor entry is the unknown. Today zimr's `runtime.js` looks for a specific exported symbol when the WebAssembly instance loads. Let me check:

```sh
$ grep -rE "exports\.main|imports.main|wasmInstance.exports" src/web/
```

…and trace what symbol the JS expects. If it's literally `main` (no decoration), then `pub fn main(init: std.process.Init)` MAY still produce that export under the right name when start.zig wraps it. Or it may produce `_start` instead (the wasi reactor entry). Either way, runtime.js's import side needs to match. Testing required.

There's also the question of single-threaded `std.Io.Threaded` on wasm. The source has a `builtin.single_threaded` fast path that returns a thread-free struct, so the API surface is fine — but I haven't verified the produced wasm has no thread imports.

## Recommendation

**Not now.** Defer to a dedicated "modernize entry point" turn after the docking arc closes. At that point:

1. Verify the wasm-wasi reactor entry survives `pub fn main(init: std.process.Init) !void` (or determine the gating issue).
2. Migrate one example (`basic.zig`) as a proof of concept.
3. Update `z.run` to accept `init: std.process.Init` instead of allocating internally.
4. Mass-migrate the remaining examples with a Python sweep — same shape as the `drawing.zig` migration on turn 317.

In the interim:
- Tests construct `std.Io.Threaded` locally (3 lines each, ~3 usages so far). Trivial.
- The `ui_screenshot.renderToPng` helper hides the boilerplate behind a single fn call. Production code never sees the io plumbing.
- `Config.gpa` is a good-enough escape hatch for users who want custom allocators.

## What would change if we DID migrate

A representative `examples/basic.zig` would look like this:

```zig
const std = @import("std");
const z = @import("zimr");

const State = struct { /* … */ };

pub fn main(init: std.process.Init) !void {
    try z.run(init, .{
        .window = .{ .title = "zimr — basic", .width = 800, .height = 450 },
    }, State, initState, update);
}

fn initState(init: std.process.Init, _: *z.Frame, s: *State) !void {
    // s.tex = try z.loadTexture(init.gpa, "checker.png");
    // s.log_file = try std.Io.Dir.cwd().createFile(init.io, "session.log", .{});
}

fn update(f: *z.Frame, s: *State) void {
    // unchanged
}
```

And `z.run` would change shape:

```zig
pub fn run(
    init: std.process.Init,            // ← new first arg
    cfg: Config,                       // window/title/canvas (no gpa anymore)
    comptime State: type,
    comptime init_fn: fn (std.process.Init, *Frame, *State) anyerror!void,
    comptime update_fn: fn (*Frame, *State) void,
) !void {
    const app = try init_app(init.gpa, cfg);   // gpa from Init
    // ... rest unchanged ...
}
```

The win: no boilerplate. The cost: every example file changes signature.

## Bonus: when `io` IS useful in zimr

Even without the Init migration, here are the places `io` belongs:

1. **`ui_screenshot.renderToPng(gpa, ctx, w, h, path)`** — file write inside the helper. Already takes `gpa`; could take `io` too, OR construct `Threaded` internally (it does today).
2. **A future `logger` that writes to a file** — host-only debug builds. Today loggers print to stderr.
3. **Asset baking pipelines** (`scripts/bake_atlas.zig` etc.) — load source images, write packed atlas. Today these are scripts that construct their own runtime.
4. **PNG/WAV exporters** — same pattern.

None of these are hot paths. None block docking. All work fine with local `Threaded` construction.

## The actual yak fence

**The reason we keep wandering toward this yak**: every time we need to write a file from a test or tool, the Zig 0.16 IO API is unfamiliar (`std.Io.Threaded.init` → `.io()` → `Dir.cwd().createFile(io, ...)` → `File.writeStreamingAll(io, ...)`). The boilerplate is small but easy to forget.

**The fix that ISN'T a yak shave**: add a `z.host` namespace with small helpers:

```zig
// src/host.zig (host-only, gated on !is_wasm)
pub fn writeFile(gpa: Allocator, path: []const u8, bytes: []const u8) !void {
    var t = std.Io.Threaded.init(gpa, .{});
    defer t.deinit();
    var f = try std.Io.Dir.cwd().createFile(t.io(), path, .{});
    defer f.close(t.io());
    try f.writeStreamingAll(t.io(), bytes);
}
```

Then `ui_screenshot.renderToPng` becomes:

```zig
const png_bytes = try z.png.encode(gpa, pixels, w, h);
defer gpa.free(png_bytes);
try z.host.writeFile(gpa, out_path, png_bytes);
```

That's the actual ergonomic problem solved. The full Init migration is a separate decision: ship it as a clean break alongside other v1.0 API stabilizations, or skip it because nobody on the wasm side ever notices.

**Filed**: `tools-2` follow-up — write the `z.host` helpers. Maybe 1 turn. Real ergonomic win, zero migration cost.

**Filed**: `entry-modernize` follow-up — full `pub fn main(init)` migration. Big sweep, real-but-modest payoff. Wait until after docking lands and we're considering a v1.0 cut.
