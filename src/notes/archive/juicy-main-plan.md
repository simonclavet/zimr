# Plan: migrate to "juicy main" (`pub fn main(init: std.process.Init) !void`)

**Scheduled**: immediately after the imgui-parity arc closes (Step 6.x of plan v5 — docking + capstone). Triggered by reaching the "v1.0 freeze" state.

**Scope**: switch every example, every test, every host tool to take `std.process.Init` as the entry-point parameter. `z.run` adapts. Tests use it. Host scripts use it.

**Status**: planned, not started. Investigation done turn 317 (`src/notes/io-investigation.md`).

**Estimated effort**: 5-6 turns.

## Why

Zig 0.16's `std.process.Init` parameter gives `main` four batteries for free:

- `gpa: Allocator` — default-selected (DebugAllocator on Debug, c_allocator/wasm_allocator on release).
- `io: Io` — a working `std.Io.Threaded` already constructed.
- `arena: *ArenaAllocator` — process-lifetime arena.
- `environ_map` + `preopens` — env vars and WASI capability handles.

The deliverable: zimr examples become as ergonomic as `zig init` examples. Every host tool gets `io` without 3 lines of `Threaded.init` boilerplate. Cleaner story for new users.

The cost: every example file changes shape. Roughly 148 .zig files. Production wasm games gain nothing — they never use `io` — but they don't lose anything either.

## Why we're doing this even though wasm doesn't benefit

Three reasons that aren't "it's useful":

1. **Consistency**. New Zig idiom; new users expect to see it; old code reads "weird".
2. **Discoverability of host tooling**. Whenever zimr grows a host script (asset baker, screenshot worker, regression captures), it should naturally have `gpa` + `io` available. Not "remember to construct Threaded.init manually" — that's a tripping hazard.
3. **It's small enough to not regret**. Mostly mechanical. The risk is low; the reward is "the API looks the way Zig expects".

## Sub-phases (5-6 turns total)

### Phase JM-1 — Investigation (1 turn)

**Goal**: verify the wasm-wasi reactor path tolerates `pub fn main(init: std.process.Init) !void`.

Today every example does `pub export fn main() void`. The `export` makes WebAssembly emit a symbol that `runtime.js` calls explicitly. Switching to `pub fn main(init)` means the symbol becomes whatever Zig's `start.zig` emits (`_start` for command, varies for reactor).

Tasks:
- Write a one-file probe: `examples/_probe_init.zig` with `pub fn main(init: std.process.Init) !void { _ = init; }`. Compile to wasm32-wasi. Inspect the `.wasm` exports with `wasm-objdump`. Confirm whether `main` is exported, or `_start`, or something else.
- Update `src/web/runtime.js` (or equivalent JS bridge) to call whichever symbol is emitted. Verify a smoke run still produces pixels.
- Check that `std.Io.Threaded.init(gpa, .{})` in `single_threaded` mode (wasm-wasi default) doesn't pull in thread imports. If it does, the wasm binary will refuse to instantiate.
- Verify `DebugAllocator` works on wasm32-wasi (the start.zig path enables it conditionally).
- Confirm `std.process.Args.Vector` doesn't fail on wasm-wasi (since there are no real argv).

Acceptance: a single example renders pixels in the browser using `pub fn main(init)`. Smoke=1/1 for that one example.

**Owner notes**:
- The wasm reactor entry shape in `start.zig` is `startWasi()` which calls `callMain({}, environ.global)`. `callMain` then dispatches based on `main`'s signature. The dispatch already works at language level; the question is purely whether the resulting wasm binary still works with runtime.js.

### Phase JM-2 — `z.host` helpers (1 turn)

**Goal**: add a `z.host` namespace with the most-needed host-only file helpers, so the rest of zimr doesn't need to construct `Threaded.init` inline.

Tasks:
- Create `src/host.zig` gated on `!is_wasm`:

  ```zig
  pub fn writeFile(gpa: Allocator, path: []const u8, bytes: []const u8) !void;
  pub fn readFileAlloc(gpa: Allocator, path: []const u8, max_size: usize) ![]u8;
  pub fn writeBytesIfChanged(gpa: Allocator, path: []const u8, bytes: []const u8) !bool;
  ```

- Re-export as `z.host` in `src/zimr.zig`.
- Migrate `src/ui_screenshot.zig`'s `renderToPng` to use `z.host.writeFile`.
- Migrate every `std.Io.Threaded.init` site in tests + scripts to use the helper.

Acceptance: zero `std.Io.Threaded.init` callsites outside `src/host.zig` itself. 1465+ tests still pass. Helper has its own test suite (write/read round-trip, atomic-replace behavior).

**Note**: this turn ships value INDEPENDENT of the entry-point migration. Even if JM-3+ never happens, host scripts get the helpers. This is the "trinket separable from yak shave" turn.

### Phase JM-3 — POC migration (1 turn)

**Goal**: migrate `examples/basic.zig` to `pub fn main(init: std.process.Init) !void`. Smoke runs 1/1.

Tasks:
- Update `examples/basic.zig`:

  ```zig
  pub fn main(init: std.process.Init) !void {
      try z.run(init, .{
          .window = .{ .title = "zimr — basic", .width = 800, .height = 450 },
      }, State, initState, update);
  }
  ```

- Add a temporary parallel `z.run` shape that takes `init: std.process.Init` as first arg, alongside the existing `z.run(cfg, …)`. Both shapes work during the migration.
- Verify `basic.wasm` runs in the browser (real WebGL output).
- Verify `basic-check` (host typecheck) compiles.

Acceptance: 1/107 example uses the new entry shape. Smoke still 107/107. Browser-side `basic` demo renders.

**Risk gate**: if browser instantiation fails (because runtime.js needs the old export symbol), pause and figure out the JS bridge change BEFORE migrating more examples.

### Phase JM-4 — `z.run` lift (1 turn)

**Goal**: the canonical `z.run` takes `init: std.process.Init` as the first arg. Old shape becomes a deprecated wrapper.

Tasks:
- Refactor `z.run` to accept `init` first. Internal: `App` builds from `init.gpa`. `z.run` returns to user once the app shuts down.
- Old `z.run(cfg, State, init_fn, update_fn)` becomes a thin wrapper that constructs a fake `Init` (with `wasm_allocator` + a synthetic `Threaded`) and forwards.
- Update `init_fn` signature option: takes `init: std.process.Init` (preferred) OR `gpa: Allocator` (legacy).

Acceptance: both call shapes work. `basic.zig` uses the new shape. The other 147 examples still compile via the legacy wrapper.

### Phase JM-5 — Mass migration (1-2 turns)

**Goal**: sweep all 148+ examples + host tools onto the new shape.

Tasks:
- Python regex sweep:
  - `pub export fn main() void {` → `pub fn main(init: std.process.Init) !void {`
  - `z.run(.{` → `try z.run(init, .{`
  - `fn initState(_: std.mem.Allocator,` → `fn initState(init: std.process.Init,`
  - `fn initState(gpa: std.mem.Allocator,` → `fn initState(init: std.process.Init,` (preserve binding by post-processing: `const gpa = init.gpa;` injected at top)
  - drop the `catch |err| std.debug.print` boilerplate — the language reports errors automatically.
- Hand-fix examples that have unusual `main` shapes (probably `ui_code_editor.zig` which has nested code blocks, anything that does its own gpa selection).
- Verify smoke 148+/148+.

Acceptance: zero `pub export fn main()` in `examples/`. Zero `pub export fn main()` in `src/tests/` either if any have it.

### Phase JM-6 — Cleanup + docs (1 turn)

Tasks:
- Delete the legacy `z.run` wrapper (Phase JM-4). One-shape API.
- Update the cheatsheet entry "Your first zimr program" with the new shape.
- Update HTML README ("zimr is a Zig library, your `main` looks like…").
- Update `src/notes/architecture-tutorial.md` if it shows `main`.
- Migrate the `ui_screenshot.renderToPng` test to use `init.io` from its own `main` (becomes a `zig build screenshot-tool` standalone, not a test).
- Run full smoke + tests + standalone build for one example. Snapshot.

Acceptance: documentation matches reality. Zero `Threaded.init` callsites in user-facing code.

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Wasm reactor entry breaks under `pub fn main(init)` | medium | Phase JM-1 is purely investigative; halt before mass migration if broken |
| `Threaded.init` pulls thread imports on wasm-wasi | low | Verify in JM-1; if true, use a custom Io impl |
| Existing browser-side runtime.js breaks | medium | One-example POC (JM-3) catches this |
| Some example has unusual gpa setup (custom allocator) | low | Hand-fix during JM-5; sweep tracks exceptions |
| Mass migration introduces a syntax bug | low | Sweep + immediate smoke; revert if any wasm fails to load |

## Order vs other arcs

This migration is BLOCKED on imgui-parity arc completion (current focus). Why:

1. The imgui arc touches ui internals, callsite migrations, and lots of demos. Doing both at once is asking for merge headaches.
2. The juicy-main migration is "polish" — it makes zimr look more like idiomatic Zig but doesn't unblock any feature. Docking is the milestone; this is post-milestone polish.
3. The Phase JM-2 (`z.host` helpers) is SAFE to do anytime — it's purely additive. May land before imgui-parity closes if a host-side need motivates it.

## When to do it

After Step 5.5 DOCKING ships AND Step 6.x capstone arc closes. Plan v5's "Phase 6 capstone" is the last imgui milestone; juicy-main slots in immediately after as the "API stabilization" pass before any v1.0 cut.

Specifically: when the imgui parity arc's TODO list collapses to zero AND there's no docking-blocker work pending, the next turn opens Phase JM-1.
