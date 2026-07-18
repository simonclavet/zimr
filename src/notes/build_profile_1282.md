# Cold-cache build profile — launcher standalone, DEBUG, Zig 0.17.0-dev.1282

Measured end-to-end on the 1-core / ~3.9 GB sandbox, starting from a genuinely cold tree:
no `.zig-cache`, no `zig-out`, no toolchain in `tools/`. Every number below is measured,
not inferred.

**Toolchain:** `0.17.0-dev.1282+c0f9b51d8` (previous gate was 1245). 410 MB, extracts in 11s.
**Result: 1282 is a NO-OP BUMP for zimr — zero source changes.** Lint 0 issues, all 23 flagship
standalones green, launcher 332/332 steps, import gate PASS (96/96).

## Timeline (cold → launcher standalone, everything at `-Dmode=debug`)

| # | step | wall | cache after | Δ cache |
|---|---|---|---|---|
| S0 | **build runner** (`zig build -h`: compiling `build.zig` into an exe) | **104s** | 22 M | +22 M |
| S1 | **lint** (compile `lint_zimr` 42s @ MaxRSS 682M + run over ~450 files 3s) | **47s** | 43 M | +21 M |
| S2 | **cold tool chain** — driven by one cheap example (`input-mouse-standalone`): spv2wgsl → zspv → gen_externs ×45 → c2js → 45 shader transpiles → engine wasm | **~850s** (4 rounds) | 509 M | +466 M |
| S3 | **warm the launcher's 23 flagship modules** (each as its own debug standalone) | **281s** | ~1039 M | +530 M |
| S4 | **`launcher-standalone -Dmode=debug`** | **48s** | 1127 M | +75 M |
| | **TOTAL** | **~22 min** | **1.2 G** | |

Disk consumed overall: ~1.8 GB (cache 1.2 G + `zig-out` 191 M + toolchain 410 M).

S2 needed 4 rounds of a ~250s window. Each round made real forward progress
(+121 M, +123 M, +66 M of cache) — the **idempotent retry loop is confirmed**; never
`rm -rf .zig-cache` to "fix" a timeout.

## Tool binaries (native)

| binary | mode | size |
|---|---|---|
| `configurer` (the compiled build runner) | — | **26.3 MB** |
| `lint_zimr` | ReleaseSafe | 8.4 MB |
| `c2js` | ReleaseFast | 6.1 MB |
| `spv2wgsl` | ReleaseFast | 5.5 MB |
| `zspv` | ReleaseFast | 4.1 MB |
| `gen_externs` | ReleaseFast | 3.9 MB **× 45 copies = 173 MB** |

## ★ FINDING: `gen_externs` is compiled once PER SHADER SCHEMA

45 shaders → 45 separate `compile exe gen_externs` artifacts, ~3.9 MB each, **173 MB = 34% of
the cache** at the end of S2. The exe is identical every time; only the generated
`gen_externs_bootstrap.zig` that gets baked into it differs. If the bootstrap were passed as a
runtime *argument* (a file path) instead of being compiled in, we would build ONE gen_externs
and reclaim ~170 MB plus a real slice of the cold-build time (each is a full native
ReleaseFast link). This is the single biggest cheap win in the cold chain.

## Debug artifacts

| artifact | wasm | standalone HTML |
|---|---|---|
| `input_mouse` (no UI, the cheap probe) | 2.4 MB | 4.07 MB |
| **`launcher` (23 flagships + engine + UI)** | **19.43 MB** | **26.61 MB** |

HTML ≈ 1.37 × wasm (base64 inflation of the embedded module).
Flagship standalones in debug ranged 3.34 MB (`mandel_julia`) → 10.79 MB (`decals`).

## ★ FINDING: the launcher does NOT OOM in debug — but the headroom is thin

`compile exe launcher Debug wasm32-wasi-none success 45s MaxRSS:2G`

**2.0 GB peak RSS against ~3.5 GB available.** With every constituent module warm, the launcher
is a 45s compile that just links + packages — exactly what claude.md predicts. But 2.0 GB in a
single compilation unit means the warm-first rule is not optional bookkeeping, it is what keeps
this build inside the memory envelope. Any parallelism (`-j2`) or a cold aggregate compile
would spend the remaining 1.5 GB immediately.

## Per-flagship warm-build cost (debug)

| example | time | Δcache | html |
|---|---|---|---|
| helmet_sw | 33s | +41 M | 10.28 MB |
| shadowmap_sw | 11s | +23 M | 7.80 MB |
| decals | 10s | +31 M | 10.79 MB |
| deferred_render | 8s | +21 M | 7.09 MB |
| cel_shading | 8s | +30 M | 10.37 MB |
| fog_rendering | 7s | +21 M | 7.10 MB |
| hybrid_render | 8s | +21 M | 7.08 MB |
| textures_background_scrolling | 5s | +12 M | 3.46 MB |
| ui_full_showcase | 9s | +23 M | 7.79 MB |
| zimrphysics_demo | 13s | +29 M | 10.00 MB |
| zimrphysics2d_demo | 10s | +29 M | 9.57 MB |
| mandel_sidebyside | 42s | +39 M | 7.29 MB |
| rt_sidebyside | 30s | +31 M | 7.37 MB |
| plot_demo | 8s | +23 M | 7.56 MB |
| plot3d_demo | 9s | +22 M | 7.45 MB |
| sph_fluid_2d | 7s | +21 M | 7.00 MB |
| ecs_boids | 5s | +14 M | 4.44 MB |
| fluid_sort | 10s | +26 M | 7.56 MB |
| skinned_mesh | 6s | +15 M | 4.84 MB |
| mandel_julia | 26s | +20 M | 3.34 MB |
| kaleidoscope | 6s | +13 M | 3.91 MB |
| waving_cubes | 5s | +13 M | 4.15 MB |
| gallery_all | 5s | +12 M | 3.50 MB |

The three slow ones (helmet_sw 33s, mandel_sidebyside 42s, rt_sidebyside 30s) are the
CPU|GPU|comptime side-by-sides — they pay for comptime evaluation, not for more code.

## ★ FINDING: `--summary all` is useless on a cold build

It only prints on COMPLETION. A cold chain that needs 4 timeout rounds never prints a summary
at all, so the per-step costs of the *first* compile of every tool are unrecoverable after the
fact. **Measure a cold chain by cache delta per round** (as above), and read `--summary all`
only once the graph is warm — at which point every line says "cached" and the timings you
wanted are gone. To profile a specific tool's cold compile, build it into a scratch
`--cache-dir` in isolation.

---

# Follow-up: is the comptime bake actually the cost? (NO)

## The premise was wrong, and a bad measurement caused it

The cold flagship numbers (mandel_sidebyside 42s, helmet_sw 33s, rt_sidebyside 30s) looked like
comptime cost. They are not. Measured, at ORIGINAL quality:

| example | rebuild after a source change | its wasm compile | comptime share |
|---|---|---|---|
| mandel_sidebyside (64x40 corner) | **11s** | 7s @ MaxRSS 801M | **~2s** |
| rt_sidebyside (40x24 x4 samples) | 15s | — | ~6s |
| helmet_sw (48x48 corner) | 11s | 4s @ MaxRSS 606M | ~4s |

Isolated by collapsing each corner to a few pixels: mandel 8x5 rebuilds in 8s vs 11s at full
64x40. **The full-quality comptime bake costs about 2 seconds.** Halving it saves ~1s and buys a
visibly chunkier corner. Not worth it — the quality reductions were reverted.

The three examples were slow *the first time* because of their COLD per-example shader/asset
steps (SPIR-V -> spv2wgsl -> a fresh ~4 MB native `gen_externs` link per shader, plus
`mesh_bake` for helmet), not because of comptime. That is the same finding as the 45-copies /
173 MB `gen_externs` issue above — it is the real lever.

## ★ MEASUREMENT DISCIPLINE: one timing is not a measurement

The first rebuild I timed said **36s**. Three repeats of the identical build said **10s, 11s,
11s**. The 36s was an artifact of being the first build after the launcher's 2 GB compile (cold
page cache / memory pressure), and I started cutting quality on the strength of it.

**Rule: time a build 2-3x before acting on the number — especially the first build after a
memory-heavy one.** A single sample right after a 2 GB compile can be 3x the true cost.

# Launcher rebuild after changing ONE example (debug)

| what changed | rebuild |
|---|---|
| one line in `mandel_sidebyside` -> rebuild **that example's standalone** | **11s** |
| one line in `mandel_sidebyside` -> rebuild the **launcher standalone** | **61s** (wasm compile 56s @ MaxRSS 2G) |

**There is no incrementality across the launcher.** It is ONE compilation unit that imports all
23 flagship modules plus the engine and UI, so a one-line edit in any single flagship recompiles
the entire 19.4 MB debug wasm — 332/332 steps, 56s of compile, 2 GB peak.

**Workflow consequence: iterate on the example's own standalone (11s), and build the launcher
only to verify the aggregate.** Editing an example and rebuilding the launcher to see the change
costs 5.5x more for the same information.

---

# ReleaseFast vs ReleaseSafe for the native tools (measured)

Each tool compiled BOTH ways outside the build system and benchmarked on its real workload,
5 reps, `min` reported (least contaminated by scheduler noise; spreads were tight).
Lint stamps (`tools/.zig-cache/lint-stamps/`) deleted before every lint run to force the full
543-file pass.

## Run performance — ReleaseSafe is 16-20% slower on the CPU-bound tools

| tool | workload | ReleaseFast | ReleaseSafe | Δ |
|---|---|---|---|---|
| `lint_zimr` | 543 files + build.zig | **3138 ms** | **3650 ms** | **+16.3%** |
| `c2js` | bridge.c (1.3 MB) -> 710 KB js | **2138 ms** | **2345 ms** | **+9.7%** |
| `spv2wgsl` | 45 shaders | 59 ms | 71 ms | +20.3% |
| `zspv` | 45 shaders (`--check`) | 18 ms | 17 ms | -5.6% (I/O bound, free) |

**Verdict against the 10% bar: FAILS.** The CPU-bound tools lose 16-20%. `c2js` sits right on
the line (+9.7%); `zspv` is I/O bound and pays nothing.

Absolute cost is small, though: ~0.5s (lint) + ~0.2s (c2js) + 12ms (spv2wgsl) per build.

## The compensation: ReleaseSafe builds FASTER and SMALLER

| tool | compile RFast | compile RSafe | binary RFast | binary RSafe |
|---|---|---|---|---|
| `lint_zimr` | 44s | **40s** | 9.9 MB | **8.4 MB** |
| `c2js` | 32s | **27s** | 6.1 MB | **5.3 MB** |
| `spv2wgsl` | 26s | **24s** | 5.5 MB | **4.9 MB** |
| `zspv` | 18s | 18s | 4.1 MB | 4.0 MB |

~11s faster cold tool-compile and ~13% smaller binaries. If the metric were *total* cold build
time rather than tool run time, ReleaseSafe would come out AHEAD.

## ★ THE REAL FINDING: the ReleaseFast miscompile of lint_zimr is FIXED in 1282

build.zig pins `lint_zimr` to ReleaseSafe with this note:

> ReleaseSafe, NOT ReleaseFast: this dev Zig miscompiles lint_zimr under ReleaseFast
> (SIGILL on every input). Debug + ReleaseSafe both run clean; ReleaseSafe keeps it fast.
> Revisit on Zig upgrade.

**This is the Zig upgrade.** A ReleaseFast `lint_zimr` built with 1282:
- ran **10/10 times clean** over the full roster — no SIGILL,
- produced output **byte-identical** to the ReleaseSafe binary (46 lines, same 18 findings).

lint gates EVERY compile, so moving it back to ReleaseFast saves **~510 ms on every single
build** — more than the entire cost of the ReleaseSafe question in the other direction.
Recommend flipping `lint_zimr` to ReleaseFast (one line, build.zig ~L709 region) and keeping
the other tools as they are.

Caveat worth stating: 10 clean runs + identical output is strong evidence, not proof. The old
failure was a hard SIGILL (loud), not silent corruption, which makes a latent regression less
likely — but if the linter ever starts behaving oddly, this is the first thing to un-flip.

---

# gen_externs: the duplication is NOT the bug — the optimize mode is

## Why 45 copies exist (and why that's correct)

`shader_codegen.zig` builds a bootstrap exe per shader that calls
`gen.emit(shader_io, writer)` — passing the schema MODULE and reflecting over its types at
COMPTIME. So the schema must be statically linked into the exe: one exe per schema, necessarily.
Each exe also carries exactly ONE `shader_io` to sidestep Zig's "a file can live in only one
module" rule (two schemas sharing a `_common_io.zig` would collide). Merging them into one exe
that imports all 45 schemas would hit exactly that rule.

**So don't dedupe it. The duplication is comptime reflection doing its job.**

## The actual bug: paying LLVM to optimize a program that runs for 1 ms

Marginal cost per shader (shared cache, so `compiler_rt`/libc are paid once — the number that
multiplies by 45):

| mode | compile / shader | binary | run |
|---|---|---|---|
| ReleaseFast (was) | **17.6s** | 3.8 MB | 1 ms |
| ReleaseSafe | 17.2s | 3.7 MB | 1 ms |
| Debug | 0.95s | 12.1 MB | 1 ms |
| **Debug + strip (now)** | **0.46s** | **3.2 MB** | 1 ms |

Release* routes through LLVM, which spends ~17s optimizing `std` — to make a 1 ms reflection
script 0 ms faster. Debug uses the self-hosted x86 backend and skips LLVM entirely.

**45 shaders x 17.1s saved = ~13 minutes off every cold build**, plus a SMALLER binary (3.2 vs
3.8 MB) and strictly STRONGER safety checks. Generated externs verified **byte-identical**.
Confirmed in-build: `compile exe gen_externs Debug native success 434-521ms` each.

This also explains the cold-build mystery: S2 measured ~850s, and 45 x 17.6s = 792s of it.
**The gen_externs compiles WERE the cold build.**

**RULE: match a build tool's optimize mode to its actual RUNTIME, not to a blanket policy.**
`lint_zimr` (3.1s/build) and `c2js` (2.1s/build) earn their optimization. A 1 ms reflection
script compiled 45 times does not.

# ★ The ReleaseSafe flip caught a REAL double free in spv2wgsl

Flipping the tools to ReleaseSafe immediately aborted the build:

    thread panic: double free of [addr: ..., len: 21]
    failed command: spv2wgsl --walker=ir --strict shader.rewritten.spv shader.wgsl

`tools/spv2wgsl.zig` filtered its flags by compacting the array that OWNS the argv strings:

```zig
pos = args_list.items[1..];
pos[0] = args[0];        // writes argv[0]'s pointer INTO slot 1
```

That aliases one allocation into two slots (and leaks the string slot 1 held); the cleanup
`for (args_list.items) |a| gpa.free(a);` then frees it twice. The `--entry=` compaction
(`pos[w] = pos[r]`) shuffled owned pointers the same way. **The build passes `--walker=ir` on
every shader transpile, so this corrupted the heap on every single shader, silently, under
ReleaseFast.**

FIX: parse over a separate BORROWED view; never mutate the owning array. Verified across all 45
shaders: no crash, WGSL **byte-identical** to the pre-fix output (45/45).

**RULE: never reorder, overwrite or compact an array whose elements are owned allocations freed
by index. Build a borrowed view.**

The ReleaseSafe flip paid for itself before it finished its first build.

---

# Debug vs ReleaseSmall: should we develop in debug? NO.

Same edit, same machine, all constituents warm. `-Dmode=release` = ReleaseSmall + zimr asserts.

## The launcher

| | rebuild after a 1-example edit | wasm compile | peak RSS | HTML |
|---|---|---|---|---|
| debug | **48s** | 44s | **2 GB** | **26.61 MB** |
| release (ReleaseSmall) | **51s** | 47s | **1 GB** | **12.02 MB** |

Debug buys **3 seconds (+6%)** and costs **14.6 MB** of HTML — plus it doubles peak compile
memory (2 GB against ~3.5 GB available, which is the thin-headroom problem from the cold-build
profile; ReleaseSmall halves it).

Fresh (not incremental) ReleaseSmall launcher build: 87s total, wasm compile 51s @ 1 GB.

## A single example (the actual dev loop)

| example | debug | release | HTML debug -> release |
|---|---|---|---|
| mandel_sidebyside | 10s | 15s | 7.29 -> **1.90 MB** |
| decals | 9s | 13s | 10.79 -> **5.14 MB** |
| ui_full_showcase | 9s | 14s | 7.79 -> **1.86 MB** |

Debug saves ~4-5s (+50% relative, but small in absolute terms) and inflates the artifact 2-4x.

## Verdict

**Keep shipping `-Dmode=release`.** Four seconds of build time never beats 5-15 MB of transfer
to a phone. Debug's only real use is crash stacktraces.

Also: do NOT "compile-check in debug, ship in release". ReleaseSmall has its own failure modes
(the old UiHost ReleaseSmall hang), so a debug check can pass while the shipped build breaks.
Build the mode you ship.

## Harness lesson (my bug, not the project's)

Two launcher rebuilds "failed in 1s" and I wrote them off as a transient `zig fmt` blip. They
were not. The sandbox shell is **dash**, where `$RANDOM` expands to EMPTY — so my cache-busting
`echo "// probe $RANDOM"` appended `// probe ` with a **trailing space**, which `zig fmt --check`
correctly rejects. The gate was right and my tooling was wrong.

**Never file a reproducible failure as "transient" without reproducing it.** Twice-seen is not
transient; it's a signal.
