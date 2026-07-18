# zimr profiler â design & status (ACTIVE PLAN)

An integrated, in-process, pure-Zig profiler that uses zimr's own graphics
(ui.zig / plot.zig) to profile zimr apps. Tracy-inspired feature set, adapted
to single-process wasm/browser. Studied references live in `/home/claude/ref/`
(SimpleImGuiFlameGraph + tracy-master) during the design session.

## Core adaptation vs Tracy
Tracy is out-of-process (client streams to a separate GUI over a socket). We go
**in-process**: the profiler UI is a zimr overlay built from ui.zig/plot.zig,
profiling the same app. No network, no server. Costs: profiler shares the frame,
we render with zimr, wasm/browser timing rules apply.

## Locked design decisions (brainstormed one-at-a-time w/ Simon)
1. **Model = HYBRID**, live-first. One set of ring buffers always recording;
   "freeze" merely stops them advancing and unlocks deep-analysis views.
2. **Timing = ~5Âµs via cross-origin isolation** (COOP/COEP headers). Plus a
   dedicated DIRECT `now` import (thin `()=>performance.now()` extern, bypassing
   the reflection bridge â the current `nowMs()` does globalâgetâcall = 3 JS
   crossings per timestamp). Profiler self-reports the actual resolution at
   startup and degrades gracefully (label 5Âµs vs 100Âµs, widen merge thresholds
   when coarse).
3. **Zone identity = static @src()** (so stats/flamegraph aggregate by call
   site) + OPTIONAL per-call `.text()/.value()/.setColor()` annotations shown in
   the detail view. NOT fully-dynamic names.
4. **Instrumentation depth = LAYERED**: ship coarse phase zones (frame + ~8 top
   phases) in v1; the zone API is a one-liner so subsystems get deepened
   on-demand where slow.
5. **Gating = by BUILD MODE**, always-recording. Profiler compiled in for every
   non-shipping mode; stripped in `ship`. Ring holds a rolling ~2-SECOND window;
   profiler continuously tracks the LONGEST frame in that window; every view
   DEFAULTS to that worst frame; manual freeze snapshots the window + locks
   focus on the worst frame. (Auto-freeze-on-spike = trivial later add.)
6. **Build mode rename**: `release-no-zimr-asserts` â `ship`. Trio is now
   `debug` / `release` / `ship`. Gating rule: profiler in unless `mode == ship`.
7. **GPU timing = CPU-only v1**, GPU next. When added: whole-frame GPU time
   (CPU-vs-GPU on the strip) BEFORE per-pass GPU zones. Needs new wgpu/bridge
   timestamp-query plumbing (createQuerySet/writeTimestamp/resolveQuerySet +
   async readback; results for frame N arrive a frame or two later).
8. **v1 cut = flamegraph + frame strip + statistics table.** Counters/plots,
   messages log, find-zone histogram = clean P2 adds.

## Data model (src/profiler.zig)
- `SourceLoc{name,file,line,color}` interned once from @src() (linear-scan
  registry keyed by file ptr + line; call sites are few).
- `ZoneEvent{src, t0, t1, depth, color, value, has_value, text[31]}` â inline
  annotation text, no arena for v1.
- `Frame{index, t0, t1, dur, zone_first, zone_count}`.
- Storage = static fixed arrays (no allocator, BSS): frames[256], zones[65536],
  srcs[1024]. When disabled the caps collapse to 0 (storage stripped). Zone ring
  is shared across frames; a frame's zones map seqâslot (zone_seq % zone_cap); a
  frame is valid while its zones haven't been overwritten (>=2s retained).
- Clock is pluggable (`setClock`): wasm installs performance.now(), native tests
  install a deterministic fake clock. Default fallback returns 0 (harmless).

## API (Zig idiom â no RAII)
```zig
const z = prof.zone(@src());            defer z.end();   // auto-named from fn
const z = prof.zoneNamed(@src(), "X");  defer z.end();
z.text("damaged_helmet.glb");  z.value(bytes);  z.setColor(c);
prof.frameMark();          // once per rendered frame
prof.freeze() / unfreeze() / isFrozen() / reset() / worstFrame() / frameCount()
```
All `pub inline`, folded to nothing when `!enabled` (impl fns touching `store`
live only inside `if (enabled)` comptime-dead branches â never analyzed in ship).

## Phasing
- **P1 (MVP)**: timing + zones + frame marks + per-frame flamegraph + frame strip.
- **P2**: stats table + aggregation + counters/plots + messages.
- **P3**: timeline + find-zone histogram + zone info + memory.
- **P4**: GPU zones + export (chrome://tracing / Tracy) + multithread.

## Build order for v1
(a) â rename mode â ship + wire `profile_enabled` gating (mode != ship).
(b) fast `now` direct import in bridge + resolution probe + COOP/COEP on the
    server; `profiler.setClock` wired from engine startup.
(c) â src/profiler.zig â data model, depth stack, 2s ring, worst-frame tracker,
    zone API, frameMark. (headless tests pass; lint clean; L0 leaf.)
(d) ✅ coarse phase zones in the wgpu_app frame loop: frameMark per tick +
    frame > update > {beginDrawing, endDrawing} + input.endFrame; clock installed
    at App.run via profilerClock (wgpu.nowMs for now). More phases on demand
    (UiHost.render, Launcher.tick are easy next adds).
(e) overlay: toggle key, frame-time strip (worst-frame highlight), per-frame
    flamegraph (DrawList icicle, hover tooltip, click-to-zoom), freeze button.
(f) statistics table (ui.zig Table) aggregating the 2s window by srcloc.

## STATUS (this session)
DONE: design locked (above); build mode renamed to `ship` (build.zig only â
no other caller referenced the old name); `profile_enabled` build option added
to both build_opts and build_opts_wgpu (defensive `@hasDecl` in profiler so any
stale options module just compiles it out); **src/profiler.zig collection
backbone built + verified** (2 headless tests pass both enabled & disabled;
wgpu build compiles it in at `debug`, strips it at `ship`; dag-check acyclic,
profiler at L0; lint clean). Exported as `z.profiler`. Graph label added.

NEXT: (b) the fast `now` import + setClock wiring + COOP/COEP (device-verify),
then (d) coarse phase zones in wgpu_app, then (e)/(f) the overlay views.
