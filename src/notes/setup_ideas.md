# Setup / workflow improvement ideas

Running notes on what would make the zimr dev loop (phone-driven, agentic, screenshot-reviewed) faster and safer. Newest observations first.

## Resuming after a context reset (verify, don't trust the summary)
- **A handed-over summary can be stale; the working tree is the only source of truth.** This session the compaction summary said the `gctx` removal was "in progress, tree currently BROKEN" with a green fallback to restore — but on disk the refactor was already **complete, committed, and green**. Acting on the summary nearly meant re-doing a ~500-line refactor from scratch (and would have re-broken a working tree).
- **Cheap first move on resume: a 30-second state probe before any edit.** `git status -s` (clean tree ⇒ matches last commit), then grep for the thing the summary claims is unfinished (e.g. `grep -c 'var gctx\|fn plotCtx' src/plot3d.zig` → 0 means already done), then a *compile-only* `zig test --test-no-exec` (0 errors ⇒ not broken). Only after that, trust-but-verify the summary's "next steps."
- **`--test-no-exec` is necessary but not sufficient as a green check** — it only analyzes test-reachable code, so it misses an unreachable internal fn with a bad call. The authoritative green is the full `zig build` (lint's `refAllDecls` forces analysis of every decl). On resume, run the full build once to confirm before believing "green."
- **Worth adding: a committed `STATE.md` (or a one-line stamp in plot3d.md) updated by `checkpoint.sh`** recording the last *verified-green* commit + what's actually done. A durable, in-repo marker survives context resets better than a chat summary and can't drift from the code as easily (especially if the checkpoint script only writes it after a green build).

## Iteration speed
- **Builds are the tax.** The full `zig build wgpu-plot3d-demo` re-lints all 288 files and links the demo (~60–290 s on the sandbox's 1 slow core). For compile-checking during a refactor, prefer a *compile-only* path: `zig test … --test-no-exec` (type-checks the whole module graph, runs nothing) or a tiny `build-exe -target wasm32-wasi-none` harness. Reserve the full `zig build` for the final green + standalone.
- **Don't `rm -rf .zig-cache`.** It throws away all incremental state and makes the next build a cold ~full rebuild. Only prune the cache when actually corrupt.
- A `scripts/checkpoint.sh` would remove per-turn toil: `zig fmt` touched files → full build → copy standalone to outputs → build the zip with the exact exclusion globs → copy the plan. Right now this is hand-run every checkpoint and is easy to get subtly wrong (e.g. the `*/zig-out/*` glob also catching `tools/zig-out`).

## Verifiability (the big one)
- **GPU output is only checkable via Simon's screenshots.** The RTT/tiling investigation burned ~4 screenshots converging on "mid-frame swapchain pass-switch corrupts this tile-based GPU." Two structural fixes would cut that loop hard:
  1. A **headless golden-image / smoke harness** that renders a frame to a render-texture and hashes/compares it (even a desktop or software path), so visual regressions are caught in CI-style runs without a human.
  2. More **on-screen diagnostics** (numbers/rects drawn into the UI) so a single screenshot carries the values I'd otherwise need a console for. `std.log.err` → browser console is hard to read on mobile.
- De-risk everything that *is* checkable: keep pushing pure logic behind unit tests (the matrix + `hoveredAxis` tests paid off — they isolated "math right, plumbing wrong" instantly).

## Architecture / debt
- **Globals → atomic-refactor pain.** `gctx` being a module global meant removing it was a single ~400–600-line atomic change (94 public fns, 59 internal, ~205 call sites). It's now **done**: plot3d.zig has zero module-level mutables and zero `lint:off module-var` escape hatches. Lesson reinforced: thread context from day one. Keep the `module-var` lint hatch-free so globals can't creep back — the next time one is tempting, put the state on `Context` (or on the relevant struct) instead.
- **The `im` shim is duplicated** between `implot.zig` and `plot3d.zig` (each ~550 lines, deliberately self-contained). That's a real maintenance cost — a bug fixed in one must be mirrored. Worth considering a single shared `implot_shim.zig` once both are stable.
- **The plot3d engine pass model can't render a *dynamic* offscreen pass before the main swapchain pass** from inside `update` (root cause of the GPU-surface dead-end). If GPU-composited plot fills are ever wanted, the engine needs a pre-`beginDrawing` offscreen-pass hook (render all RTs first, then one uninterrupted on-screen pass) — this is the "right" RTT fix and benefits any dynamic RTT use, not just plots.

## Notes hygiene
- `src/notes/plot3d.md`'s STATUS block is now a long stack of dated UPDATE entries. It's the source of truth but is getting heavy; periodically condense the resolved ones into a short "history" tail and keep only the live state + open decisions at the top.
