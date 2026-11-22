# test-everything and build-everything: two commands for all of it (PLAN v10, FINAL Nov 22, D5 revised that day)

Status (Nov 22, 16:21): **being implemented - S1 to S4 written, S5 next; what remains is the journal's last entry,
"WHAT REMAINS".** FINAL Nov 22 (Simon: "Agreed, all of it"); D5 revised and D8 dropped the same day (section 7).

build.zig is being edited while this plan is written (it changed at 12:14 on Nov 22), so the plan names what it
cites - a function, a variable, a step, a comment's words - rather than a line number that moves.

Simon's ask: one command that tests everything there is to test, one that builds everything there is to build, and
ideas for making the setup simpler to understand. `zig build test-everything` may take a long time.

## 1. What exists today (read from build.zig, Nov 22)

build.zig is 10,576 lines and declares about 1,150 top-level steps. Roughly 900 are per-app (`<app>`, `run-<app>`,
`<app>-headless`), about 45 are `test-<stem>` roots, and ~115 are tools, checks, generators and aggregates
(appendix A lists every one). 98 of the `b.step` calls are in `build()` itself, the rest in `buildTools`,
`buildNativeExamples`, `gateEveryTool`, `addHeadlessRunOf`, `addCompileCheck` and `addVorbisReferenceStep` - plus
ten in the consumer `Project` API (`pub const Project`), which is out of scope (section 4h).

### 1a. The aggregates, and what each one actually reaches

| step | what it runs | notes |
|---|---|---|
| `lint` / `lint-check` | linter, every rule; `lint-check` adds the template's layout | two names for nearly one thing |
| `lint-coverage`, `lint-test` | linter's walk coverage; zimrlint/zbuild/doc_folds own tests | both only in `gate` |
| `tripwires` | wgsl corpus, wgpu smoke, editor configs, zm-gpu, zn-rl-gpu, doc-gate, spv binding check, fixture WGSL, pointer-kernel check, doc-folds --check, `tools-test`, `lint-check` | **no unit tests** |
| `test-fast` | every `fast_test_roots` entry (zimrnum, zimrmath, robot family, codecs, ...) | |
| `test` | `src/tests.zig` + mesh test + `test-fast` + fixture WGSL + pointer kernels + **11 tier-A wasm builds** | never gated on style |
| `gate` | lint-check, lint-coverage, lint-test, **test-fast** (not `test`), tripwires, audio-worklet-test, audio-page-test, c2js-diff, platforms-check, external-check, template-check, doc-folds --check, doc-sync, `tools` | "the full per-turn gate" |
| `check` | compile-only twins: every test, every tool, focused examples, robotgpu-wgsl | what ZLS runs on save |
| `tier-a-check` | dag-check, test, smoke, wgpu-smoke, corpus | needs `-Dfocus=tier-a` typed by hand |
| `test-all-examples` | `test` + every example wasm | |
| `all-examples` | every example for `-Dplatform` | |
| `platforms-check` | the launcher for web, Windows, Linux (+ glibc floor), macOS/Android objects | |
| `tools` | compiles every exe under `tools/` that some step builds | |

★ **`gate` does not run `zig build test`** (its `gate_step.dependOn` lines name `test_fast_step`, never `test_step`). So
`src/tests.zig` - the engine and render half - is outside the gate described as "run this before shipping". Nothing
says whether that is deliberate. (The launcher's web page IS in the gate, through `platforms-check`: "The launcher's page: the web's part of `platforms-check`".)
**D2 (Nov 22) closes this: the gate runs all of `test`.**

### 1b. Checks that no aggregate reaches (they run only when typed by name)

Checked for each check step: is its run a dependency of anything else? Corrected Nov 22 - two first listed here
are narrower copies of checks that do run:

| step | needs | covered elsewhere? |
|---|---|---|
| `test-goban`, `test-music-theory`, `test-magic-isomorphic-keyboard` | nothing | no |
| `native-input-test`, `platform-contract-test`, `vk-gen-test` | nothing | no |
| `c2js-canary` | nothing | no (it checks c2js against Zig's comptime fold; `c2js-diff` checks 100 cases against native) |
| `dag-check` | nothing | only by `tier-a-check` |
| `vorbis-reference` | nothing (Zig compiles stb_vorbis) | no |
| `geno-trainer-layout` | nothing (CPU) | no |
| `test-windows`, `win32-abi-check` | nothing (compile-only) | no |
| `shadowmap-sw-verify`, `cel-shading-verify`, `shader-effects-verify`, `hybrid-render-verify` | nothing | no - and each asserts (byte-identical bake; tonal populations; each effect works; sky/floor/blob pixels) |
| `audio-scale-star-check`, `magic-isomorphic-keyboard-check` | a headless run (Vulkan) | no |
| `flagships-check` | every flagship headless (Vulkan) | no |
| `vk-shader-probe`, `vk-host-test` | a Vulkan driver + the validation layer | no |
| `vk-abi-check` | `VULKAN_SDK` or `-Dvulkan-headers` | no |
| `smoke-test` (+ `verify-imports`, which sits inside it) | Node; without `-Dfocus` it runs every example's page (the comment above `smoke_step`), whatever the gate's comment says ("NOT the smokes", stale) | no |
| ~300 `<app>-headless` | Vulkan; `-Dscript`, or a second of frames without one | the same programs run in `gallery-shots`, itself in no aggregate |
| slow tests | `-Dslow-tests` (and `-Dtest-report` for the measurement tests) | no |
| `doc-folds-test` | - | **yes**: a Debug build of the test root `lint-test` runs ReleaseSafe |
| `corpus-diff` | - | **yes, by `test`** (a filtered build of `src/tests.zig`) - but not by `gate` |

★ **The four `*-verify` checks write into the working directory** - `cel_verify.png`, `effects_verify.png`,
`hybrid_verify.png`, `corner_lit.png`, `corner_shadowmap.png`, via `Io.Dir.cwd().writeFile` (e.g.
examples/cel_shading/native_verify.zig:158) - and print `wrote ...` when they pass. Run from the repo root, that is
five untracked files and a passing check that prints. Fixed before they join a tier (section 6, S2).

★ **Both ways of running every example already exist** (found Nov 22, for D4):
- **In Node:** `smoke-test` with no `-Dfocus` boots every example's page and runs 60 frames, on the wasm the web
  build made - `addWgpuSmoke` installs the same `Compile` a second time (its call in `finishWgpuApp`), so no extra compile. Not
  own-frame demos (they run their own loop).
- **On Vulkan:** a headless run is a check - unclean (any validation error or warning, a failed script line, an error
  logged, a leak among them: src/wgpu_app.zig:643) exits 1 (src/wgpu_runner.zig:222). And `gallery-shots` runs
  every example's headless program (the same `Compile` as `<app>-headless`: `headless_exe` in the `gallery-shots` loop) through a script
  that captures its thumbnail - so it is already that check for every example but `net_rtc_smoke`.

★ **tier-A is defined twice, and the two disagree.** `matchesFocus` (`tier_a_names`) lists 11 examples; the smoke's
expansion of `-Dfocus=tier-a` (`expanded`, beside `smoke_cmd`) lists 8 - no `plot_demo`, `damaged_helmet` or `launcher` - under a
comment that says to keep them in sync.

### 1c. Steps that write the tree (never inside either ubercommand)

`lint-fix`, `fmt`, `doc-folds`, `corpus-refresh`, `editor-configs`, `files-md`, `files-html`, `dag-png`,
`urdf-import`, `zimrnum-ref`, `clip-bake`, `vk-gen`, `dist`, `publish` (which also pushes to a remote), the
source rewriters `rename-local`, `rename-pub-fn`, `zm-namedimports`, and the demo runs that write PNGs into the
working directory (`sw-mandelbrot`, `julia-gallery-png`, `native-plot-png`, ...).

## 2. Ways to build the two commands (brainstorm; D1 chose C)

**A. Two build steps, wired by hand** like `gate` today. Simple, but the list rots: `gate` already misses `test`, and
section 1b is what a hand-kept list looks like after two months.

**B. Two build steps, wired by a graph walk** like `gateEveryTool`. Nothing rots, but the walk cannot tell a check
from a generator without being told, and "everything a walk found" is hard to read.

**C. Every step declares its kind where it is made** - a registry, from which the aggregates are built at the end
of `build()`, with configure-time rules that make an unwired step an error. **Chosen (D1, Nov 22).**

**D. zbuild runs several `zig build` invocations**, one per option set. Handles any `-D` value, but there would be
no `zig build test-everything`, the runs share no graph, and its list is a second place to keep in step.

**E. A script.** Rejected: the tree moved its scripts into Zig on purpose.

## 3. The ladder (corrected Nov 22)

v1 made every rung a superset of the one below, `tripwires` inside `test`. **That breaks a standing rule: tests are
never gated on style** (Simon, Sep 25 and Oct 18: "Tests and smoke tests neither check nor touch style"), and
`tripwires` holds `lint-check`. So the ladder is two branches that join at `gate`:

    lint-check ──► tripwires ──┐
                               ├──► gate ──► test-everything
    test-fast ───► test ───────┘                  ▲
                                         build-everything      (inside test-everything, D7)

    lint-check        seconds   style: every lint rule, the layout
    tripwires         ~1 min    + cheap invariants (corpus, probes, docs, configs, tools-test) + dag-check
    test              minutes   every quick test (never style): src/tests.zig, every fast root, tier-A wasm,
                                + goban, music theory, keyboard, native input, platform contract, vk-gen tests
    gate              minutes   tripwires + all of test (D2) + consumer builds, platforms-check, c2js-diff,
                                audio tests, doc-sync, tools, + c2js-canary, vorbis-reference,
                                geno-trainer-layout, win32-abi-check
    test-everything   long      gate + slow tests standing in for the quick ones, every example in Node and on
                                Vulkan (D4), flagships, sound checks, test-windows, the four *-verify,
                                vk-abi-check, vk-host-test, vk-shader-probe (the GPU ones behind the probe, D3)
                                - and everything build-everything makes (D7)

Principle for placing: **an existing check keeps the tier it has today**; only the orphans of section 1b are placed,
by cost and by what they need. `build-everything` holds `lint-check`, so it requires a clean tree like every
artifact does (the "ARTIFACTS REQUIRE A CLEAN TREE" rule in build.zig).

**What D2 costs.** The gate now compiles `src/tests.zig` and builds the 11 tier-A examples (the launcher's page it
already built). In the sandbox, where `test` measured ~8 GB of cache cold and outlasted a turn, the gate falls under
the rule `test` is under there: run detached (claude.md, "NEVER the full `zig build test` inside a turn"). The gate's
own description (the `gate_step`'s) and claude.md's "Run `zig build test-fast` before calling something done; it is
the step the gate runs" change with it.

**What `test-everything` runs, and what it leaves out by definition.** Every assertion, at its largest size: the slow
tests, and vk-host-test's long checks (`-Dlong-checks`) - proposed, for the final review: today they print their
timings pass or not (tools/vk_host_test.zig:7485, 9152), so they first need the report gate the robot tests use
(`src/test_report.zig`). Not the parked tests (`-Dparked-tests`: set aside on purpose, to revisit), and not the
measurements (`-Dtest-report`: tests that assert nothing).

**Every example, on both hosts (D4, decided Nov 22).** Each example runs once in Node and once on Vulkan:
- **Node:** the unfocused `smoke-test` - one Run over every example's page, 60 frames each, on the web builds' wasm
  (no compile of its own). Not own-frame demos, which run their own loop.
- **Vulkan:** each example's gallery-shot Run is registered as an `everything` check, behind the probe (D3). It is
  the same program `<app>-headless` runs, and an unclean run exits 1 - so the shot is the check, and each example runs
  headless once. The `gallery-shots` step stays a `build` (its thumbnails, for `build-everything`) over the same Runs.
  `test-everything` takes every example's shot whatever `-Dshots` says; `-Dshots` narrows only `gallery-shots`.
  `<app>-headless` becomes a `part`: one example, with its own script.
- **`-Dfocus` given to `test-everything`** narrows its examples, as it narrows every build's; the run says so, as
  `-Dskip` does: `left out: every example but x (-Dfocus=x)`.
- The smoke is one Node process over ~300 pages and the shots ~300 runs (on lavapipe, CPU-drawn, in the sandbox):
  unmeasured. If the smoke is the long pole, it is split into shards later - measured first.

`build-everything`: every app for `-Dplatform` - what `all-examples` builds: the web's pages, the Windows or Linux
programs, or the APKs (D5, revised) - every tool, every doc page (`readme`,
`doc-pages`, `cheatsheet`, `docs`), `kernels-wgsl`, `robotgpu-wgsl`, `example-sources`, `gallery-shots` (Vulkan),
the trainers, `vk-hello-windows`, `vk-host-test-windows`, `zbuild`, `measure`, `st-bench`. Into zig-out only.

**What each platform's builds are today (for D5).**
- **Windows:** every example, always ("Every example for Windows, and the gallery") - Zig cross-compiles them from any machine.
- **Linux:** every example only under `-Dplatform=linux` ("Linux: every example and the gallery"); the launcher always, for
  `platforms-check`, with its glibc floor checked. Zig alone builds them.
- **Android:** an APK per example only under `-Dplatform=android` (`android_builds.put` in the web apps' loop). Its page is the web build's own
  wasm (`bridgePage` over `finishWgpuApp`'s `Compile`), so per example what is new is the packaging - app id, label,
  icon - by tools/android_apk.zig, which finds the SDK (`ANDROID_HOME`, `ANDROID_SDK_ROOT`, Android Studio's place)
  and a JDK (`JDK_HOME`, `JAVA_HOME`, Android Studio's `jbr`, the PATH) when it runs, and fails naming what to set
  (tools/android_apk.zig:230-247). Each APK carries its page: 7-11 MB in Debug, 2-5 MB in release (claude.md's
  measurements of the pages). **One app sets its own Android id, label and icon - `go_puzzles_hero`
  (its `android_app_id`)**; every other APK's are derived from its name and title (`defaultAndroidAppId`), so ~300 APKs
  take two packaging paths between them: the launcher's (the derived one) and the hero's.
- **macOS, iOS:** no builds yet - `platforms-check` compiles the launcher's objects for macOS.
- For `build-everything` to hold the Linux or Android builds whatever `-Dplatform` says, their steps have to exist in
  every configure, which adds ~600 steps to each `zig build`'s configure (its cost unmeasured).

**DECIDED (D5, Nov 22): web, Windows and Linux for every example, and the two APKs - REVISED the same day, 15:30**
(Simon: "Builds only", after "Test/build everything should only test the specified platform"): **`build-everything`
builds every example for `-Dplatform`**, as `all-examples` does - the web's pages, each Windows or Linux program and
the native gallery, or every APK - and the tests stay as D4 and D8 say: they run on what the machine has (Node, its
Vulkan device) whatever `-Dplatform` says. So no platform's builds join every configure: Linux's examples stay under
`-Dplatform=linux`, and the two APKs and their `android-sdk` probe are gone (`-Dplatform=android` builds every APK,
and tools/android_apk.zig names what is missing). What it gives up: an example outside the launcher's 35 flagships
that breaks only on another platform is seen when that platform is built - `platforms-check`, in the gate, compiles
the launcher for the web, Windows, Linux, macOS and Android every time.

**What D7 adds to `test-everything` (DECIDED Nov 22: all of `build-everything`).** Without it, `test-everything`
would already build every example's page (the smoke's), every
example's headless program (the shots'), the launcher for every platform (`platforms-check`) and every tool
(`tools`). `build-everything` adds:
- every example's **build for `-Dplatform`** (D5, revised): natively ~300 programs, each a compile of its own - the
  windowed host rather than the headless one (`headless_app_ctx` is a copy of `windows_app_ctx` with its own engine
  module) - each Windows one passing the no-WGSL check before it installs (`installWindowsApp`); for the web only the
  pages' installs, their wasm being the smoke's; under `-Dplatform=android` every APK;
- the **doc pages** (`readme`, `doc-pages`, `cheatsheet`, `docs`), `example-sources`, `kernels-wgsl`,
  `robotgpu-wgsl`, the trainers, `vk-hello-windows`, `vk-host-test-windows`, `zbuild`, `measure`, `st-bench`.
So about 300 native compiles (none for the web) and the doc generation - and the checks that run only on a built
output (no WGSL in a Windows program; for each page, its imports - though the web builds already carry that one).

### 3a. One configure, several option values

The build runner configures once, so one invocation cannot use two values of one `-D` option. The three that matter:

- `-Dslow-tests`: a slow binary runs the quick tests too, so `test-everything` builds each test root once, with
  `slow_tests = true`, **in place of** its quick build - never both (section 4e).
- `-Dfocus`: not a problem after all - `smoke-test` without it already runs every page; `-Dfocus` only narrows (D4).
- `-Dmode` (D8). build.zig's own table, above `wasm_optimize`:

                wasm (web)     native (Windows, Linux, headless)   zimr asserts + profiler
      debug     Debug          Debug                               on
      release   ReleaseSmall   ReleaseSafe                         on
      ship      ReleaseSmall   ReleaseFast                         off

  `release` is what `zig build publish` puts on Pages, `ship` "the lean build users get", and the smoke "runs at
  whatever mode the rest of the build is at; in practice that's always debug" (the comments beside the table).
  **The modes differ most on the wasm.** A release page has none of Zig's own safety checks - overflow, bounds,
  `unreachable`; only zimr's asserts survive - and is compiled for size; the UiHost hang was ReleaseSmall's alone
  (claude.md). Natively, release is ReleaseSafe and keeps Zig's safety. Two modes in one run need their own install
  directories: today both would install to zig-out/web/<name>/ and zig-out/wgpu-smoke/web/.

  **DECIDED (D8, Nov 22): every page is smoked twice, as Debug and as release wasm; everything else is built in the
  mode given - DROPPED the same day** (Simon: "Drop it", to finish sooner): every page is smoked once, in the
  `-Dmode` given, and `zig build test-everything -Dmode=release` smokes the release wasm. What was planned: the
  smoke whose mode matches `-Dmode` runs on the web builds' own wasm. The other compiles every
  example's wasm a second time in its own mode - Debug, or ReleaseSmall with zimr's asserts on, as `release` builds
  it - installed only for that smoke, into a directory of its own (zig-out/wgpu-smoke-debug/web/ or
  zig-out/wgpu-smoke-release/web/, its bridge pages beside it), so nothing lands on zig-out/web/. Under `-Dmode=ship`
  neither matches and both are compiled; `ship` itself stays a `-Dmode=ship` run.
- `-Dplatform`: `build-everything` builds every example for the platform it names (D5, revised Nov 22) - by default
  the machine's own, so on Windows every Windows program - and `test-everything`'s tests run on what the machine has,
  whatever it names.

### 3b. Cost

Not measured, and cannot be from here (no compiling in these sessions). The first `test-everything` run is the
measurement, recorded in the journal. Known pieces: the slow robot binary ~240 s in one process before sharding,
c2js-diff ~100 s, `test` from cold ~8 GB of cache on the 1-core sandbox, a full cold rebuild ~17 min there.

## 4. The registry (D1)

### 4a. Every top-level step has a kind

| kind | means | in `test-everything` | in `build-everything` |
|---|---|---|---|
| `check` (tier, need) | asserts something | yes, at its tier | no |
| `part` | a narrower way into checks the ladder runs: one test root, one example's smoke | (already, through its parent) | no |
| `build` (need) | an output in zig-out | yes (D7) | yes |
| `app` | one app for `-Dplatform`, failing for a platform the app lacks (S2d) | no (`all-examples` builds it) | no (`all-examples` builds it) |
| `writes` | rewrites tracked files | **never** | **never** |
| `runs` | runs something for a person: an app, a server, a bench, a tool taking arguments | never | never |

### 4b. Sketch (illustrative, not compiled)

```zig
/// Where a check sits on the ladder (src/notes/test_build_everything_plan.md, section 3).
const CheckTier = enum { style, invariants, quick_tests, gate, everything };

/// What a step needs from the machine beyond Zig: required, proven by a probe, left out only by `-Dskip` (4f).
const Need = enum { nothing, vulkan_device, vulkan_headers };

const StepKind = union(enum) {
    check: struct { tier: CheckTier, need: Need = .nothing },
    part,
    build: Need,
    writes,
    runs,
};

/// Every top-level step's kind, and the aggregates made from them. Owned by `build()` and passed to the helpers
/// that make steps - a module global is out (the `module-var` lint rule).
const StepRegistry = struct {
    b: *std.Build,
    kinds: std.StringArrayHashMapUnmanaged(StepKind) = .empty,
    /// Checks with no top-level step of their own (a bare Run: the binding check, the editor-config check...).
    unnamed_checks: std.EnumArray(CheckTier, std.ArrayList(*Step)),

    /// `b.step` and the step's kind in one call: the one way build.zig makes a top-level step.
    fn step(registry: *StepRegistry, name: []const u8, description: []const u8, kind: StepKind) *Step;
    /// A check that is not a top-level step, at `tier`.
    fn addCheck(registry: *StepRegistry, tier: CheckTier, check: *Step) void;
    /// Last in `build()`: the tier steps and the two ubercommands from the kinds, then the rules of 4d.
    fn finish(registry: *StepRegistry) void;
};
```

A call site:

```zig
const dag_check_step: *Step = steps.step("dag-check", "Verify src/*.zig import graph is a DAG", .{
    .check = .{ .tier = .invariants },
});
```

### 4c. The map: `zig build help-checks`

Printed from the registry: every step, its kind, its tier, what it needs, its description - the ladder as data,
which cannot drift because it is the registry. (This Zig has no step type that prints and succeeds - its step types
are `std/Build/Step/*.zig`: Run, Fail, WriteFile, ... - so it is a Run of `tools/build_note.zig` over a generated
file, the tool `-Dskip`'s note uses too, 4f.)

### 4d. What `finish` enforces at configure time

1. **Every top-level step has a kind** (Zig's own `install` and `uninstall` aside). A step made with a bare `b.step`
   fails configure, naming the step and `StepRegistry.step`. This is what ends section 1b for good.
2. **A `part` is inside `test-everything`**: everything it depends on is in `test-everything`'s graph. A part that
   is a filtered or compile-only copy - `corpus-diff`, `check` - cannot pass that, and says what it copies in a
   sentence that `help-checks` prints.
3. **Neither ubercommand reaches a `writes` or `runs` step.** A generator cannot slip in through a dependency.
4. **Tier steps are made by `finish`, never by hand**: `lint-check`, `tripwires`, `test`, `gate` keep their names
   and gain `test-everything` and `build-everything`.

### 4e. How a tier step is made

Each tier step depends on its own members and on every member of the tiers under it - individually, not through
the lower tier's step. That is what lets `test-everything` put a test root's slow build in place of its quick
build: the quick run is simply not among its members. The tier steps of the old names keep exactly today's members
(section 3's principle), so S1 changes no behaviour.

### 4f. A machine that lacks something: a need (D3)

Four facts decide what can be done (read in dev.753's build runner and the tree, Nov 22):

1. **A check cannot skip itself.** The runner marks a step skipped only for a foreign binary: `error.MakeSkipped`
   comes only from `skip_foreign_checks` and the foreign-executor paths (lib/compiler/Maker/Step/Run.zig).
2. **A skipped test leaves no trace on a green run.** A test can return `error.SkipZigTest`, but the default summary
   is `failures` (lib/compiler/Maker.zig:874), printed only when something failed - and a test binary that prints on
   a pass reads as red (claude.md, "A PASSING TEST BINARY MUST PRINT NOTHING").
3. **The graph is fixed when the build configures.** A check is in the graph or it is not; once the build runs, the
   only thing that stops it is a dependency failing - and then it does not run, and counts as pending, not as failed
   (Maker.zig:2925).
4. **A device probe exists already.** `vk_shader_probe` given no shaders opens the Vulkan loader, the validation
   layer and a device, and exits 0; without the layer it exits 2 and names what to install
   (tools/vk_shader_probe.zig:341-347).

**DECIDED (D3, Nov 22): a need is required, proven by one probe, and left out only when `-Dskip` names it.**

- **The probe.** `vk_shader_probe` in a `--device` mode: it opens the loader, the validation layer and a device with
  the host's features (its `Probe.open`), closes them, and prints nothing when it succeeds. When it cannot, it exits
  2 with what is missing (`NoVulkanLoader`, `NoValidationLayer`, `NoDevice`, `NoQueueFamily`) and the fix: "install
  the Vulkan SDK (Windows), or mesa-vulkan-drivers and vulkan-validationlayers (Linux) - or pass
  `-Dskip=vulkan-device`". The registry owns the one probe run, and every GPU check's own Run depends on it - the
  Run, not its top-level step, so the check really waits. Without a device the probe is the run's single failure and
  the checks behind it do not run (counted as pending, not as failed).
- **`-Dskip=<need>[,<need>]`** (`vulkan-device`, `vulkan-headers`) shapes the ubercommands only: their
  checks and builds with that need are left out, and a note step prints what was left out - `left out: 312 checks
  that need a Vulkan device (-Dskip=vulkan-device): vk-host-test, flagships-check, ...`. A step named directly
  (`zig build vk-host-test`) still runs, and still meets the probe. The note is a Run of `tools/build_note.zig`, a
  tool of a few lines that prints its arguments or a file (there is no step type that prints and succeeds) -
  `help-checks` (4c) prints through it too.
- **`vulkan-headers`**: vk-abi-check already fails alone, with one message, without the headers (its `b.addFail` in build.zig);
  the message gains the `-Dskip` hint.
- **`android-sdk`**: gone with D5's two APKs (revised Nov 22). `-Dplatform=android` is the opt-in, and
  tools/android_apk.zig already names what is missing when it packs (tools/android_apk.zig:230-247).

Not chosen: detecting the validation layer when the build configures (it would copy the loader's search - `VULKAN_SDK`,
`VK_LAYER_PATH`, `VK_ADD_LAYER_PATH`, the `explicit_layer.d` directories - and could be wrong both ways), and GPU checks
only under an opt-in `-Dgpu` (a flag to remember).

The GPU checks: `vk-host-test`, `vk-shader-probe`, `flagships-check`, `audio-scale-star-check`,
`magic-isomorphic-keyboard-check`, every example's gallery shot (D4), and each `<app>-headless` run by name.

### 4g. zbuild

`zbuild` stops at the first finding by default, which would end an hour-long run at its first lint finding. So it
runs `gate`, `test-everything` and `build-everything` as `--complete` without being asked - a three-name list in
tools/zbuild.zig - and ends with what failed, each with its time, and repeats the `left out:` lines of `-Dskip`.

### 4h. Out of scope

The consumer `Project` API (`pub const Project`) makes its own `test`/`check`/`lint`/`lint-fix` steps for template/ and
users' projects. The registry is zimr's own build; a Project's `test-everything` is a later question.

## 5. Making the setup simpler to understand (D6, decided Nov 22: items 1-7, in this order)

Already in the plan through D1: **the registry** ("is X in the gate?" is answered by one line next to X), **no
orphan checks** (rule 1 of 4d), **the generated map** (`help-checks`, 4c), and the build commands in readme.html and
claude.md's "HOW TO RUN TESTS" rewritten around the ladder (S6). The stale text found on the way is corrected
whatever D6 says: the gate's "NOT the smokes" comment, claude.md's advice to run `tier-a-check` (its section on
cross-cutting work), and the `focus` option's description of tier-A.

**Proposed as S7, in this order - cheapest and surest first:**

1. **tier-A defined once.** `tier_a_names` and the smoke's `expanded` list already differ (11 and 8, section 1b):
   one list, which both read.
2. **One run per duplicate.** `doc-folds-test` (Debug) and `lint-test` (ReleaseSafe) compile the same test root;
   `doc-sync` and the gate each make their own doc_sync Run. One each. (`doc-sync`'s half done Nov 22, early.)
3. **Retire `tier-a-check` and `test-all-examples`.** Every member of each is on the ladder now (`dag-check` in
   `tripwires`, the smokes in `test-everything`), and `test-all-examples` is `zig build test all-examples`.
4. **`lint` and `lint-check` as one step, named `lint`**: every rule and the template's layout. The artifacts'
   clean-tree rule depends on it as it depends on `lint-check` today.
5. **Retire the probes of finished migrations**, unless Simon still uses them: `bridge-hello` (a bridge page with no
   module, zig-out/bridge-hello/), `bridge-slice`, `bridge-classic-probe` (ZIG_BRIDGE phases 1-3a), and
   `standalone` (the 2D wgpu demo as one page). Nothing runs them; no editor config names them.
6. **`<app>-headless` as `-Dplatform=headless`.** `zig build run-<app> -Dplatform=headless` runs what
   `<app>-headless` runs (the house rule: a target is a platform value, never new steps), and `zig build --help`
   loses ~300 of its ~1,150 lines. (Corrected Nov 22: v1-v7 said "about 250 lines would remain" - that needed the
   ~600 `<app>` and `run-<app>` lines gone too, which nothing proposes.)
7. **One table for test roots**: `fast_test_roots`, `tests_run_elsewhere`, the `test-<stem>` steps and the
   example-local tests (goban, music theory, keyboard), so a new root is one row.

**Not proposed now:**
- **Renaming `check`** - it is the name ZLS's build-on-save convention looks for; the map says what it does.
- **Renaming `smoke`/`smoke-test` and `corpus`/`corpus-diff`/`corpus-refresh`** - the map shows which check and
  which write; a rename costs every document and habit that names them.
- **Splitting build.zig by concern** (`build/tests.zig`, `build/gates.zig`, `build/apps.zig`, ...) - the biggest
  change of all, and build.zig is being edited beside this plan: its own plan, at a quiet moment, after this one.

## 6. Stages (each ends green, each check seen to fail first)

- **S1 - the registry, behaviour unchanged**, in four sub-steps that each end buildable (a turn's shown code stays
  near 150 lines):
  - S1a: the types (`CheckTier`, `Need`, `StepKind`) and `StepRegistry` (`step`, `declare`, `tierStep`); the four
    tier steps made through `tierStep`.
  - S1b: the 55 steps of `build()` that are not checks, made with the registry's maker of their kind.
  - S1c: the 38 checks of `build()`, each with its tier (and `gallery-shots`, a build that needs a Vulkan device).
  - S1d: the steps the helpers make; the helpers are handed the registry.
  - S1e: `finish` - rules 1, 3 and 4 of 4d.
  - S1f: `help-checks`, printed by `tools/build_note.zig`.
  Moved to S2 (found Nov 22, starting S1): through S1 the tier steps' members stay wired by hand, and rule 2 waits
  for `test-everything`. Today's `gate` holds `test-fast` but not `test`, which no arithmetic of tiers can express
  before D2's change - so composing the tiers in `finish` belongs with D2, in S2.
  Seen to fail: a step made with a bare `b.step` fails every build, naming the step; a tier step that reaches a
  `writes` step fails, naming both. Seen to hold: `help-checks` lists each tier step with exactly the members of
  section 1a, and section 1b's checks as reached by no tier.
- **S2 - the orphans placed, the ubercommands born**, in four sub-steps:
  - S2a: `finish` composes the tiers (`composeTiers`, the ladder in `CheckTier.holds`): each tier's step holds the
    tiers under it and every check of its tier it does not run already - section 1b's checks join their tiers, and
    `gate` holds `test` (D2), its description and claude.md saying so.
  - S2b: the four `*-verify` checks write under zig-out and print nothing when they pass.
  - S2c: `test-everything` - `gate` and the `everything` checks that need nothing (the GPU ones wait for S5) - and
    rule 2, reported in `help-checks` until its list is empty, then enforced.
  - S2d: `build-everything` - every example for `-Dplatform` (`all-examples`, D5 revised) beside every build that is
    no platform's, and every tool - and `test-everything` holding it (D7). (Before D5's revision: every platform's
    builds of every example, Linux's added to every configure and the configure timed.)
- **S3 - slow tests** standing in for the quick ones inside `test-everything` (4e), in two sub-steps:
  - S3a: one fast root's binary and one of its runs made by two functions, `addFastTestCompile` (against the
    options it is given) and `addFastTestRun` - behaviour unchanged, so that a root can be built twice.
  - S3b: the slow twins. Unless `-Dslow-tests` turned them on already, every root `test-fast` runs is built a
    second time against `build_opts` with `slow_tests` on, each of its runs registered as standing in for the
    quick one (`standIn`); `composeTiers` holds `gate` in `test-everything` through its members wherever they lead
    to a run something stands in for (4e), and `isRunBy` counts a stood-in step as run, so `test-fast` and the
    `test-<stem>` parts stay inside. The fast tier only: `src/tests.zig` and `test`'s other roots read no
    `slow_tests` - all 113 gates are in files `src/robot_tests.zig` imports (Nov 22).
- **S4 - every example on both hosts (D4):** the unfocused `smoke-test` and every example's gallery shot registered
  as `everything` checks (`headless-test`); `<app>-headless` a `part`; the `-Dfocus` note (with S5's `-Dskip` note).
  (D8's second smoke, every example's wasm compiled again in the other mode, was dropped.) Seen to fail: a leak or
  a validation warning planted in an example outside tier-A fails `test-everything` at that example's shot.
- **S5 - the needs (D3):** `vk_shader_probe --device`, every GPU check's run behind it, `-Dskip=` and its note
  (`tools/build_note.zig`), the GPU checks joining `test-everything`, and vk-host-test's long checks quiet on a
  pass (the two APKs and `android_apk --check` went with D5's revision). Seen to fail: with the validation layer
  hidden from the loader (its `VK_LOADER_LAYERS_DISABLE` setting, or a machine without the layer), the probe is the
  one failure and no GPU check runs; with `-Dskip=vulkan-device` the run is green and its note lists them.
- **S6 - zbuild** runs the ubercommands complete (4g); readme.html and claude.md rewritten around the ladder; the
  stale text of section 5 corrected.
- **S7 - the simplifications D6 takes**, in section 5's order, each its own green step.
- Then **the first full run**, timed per tier, recorded below.

## 7. Decisions

- **D1 - mechanism: DECIDED Nov 22, the tier registry (option C).**
- **D2 - the gate's test side: DECIDED Nov 22, all of `test`** (src/tests.zig, every fast root, the 11 tier-A
  wasm builds). `test-fast` becomes a narrower way in.
- **D3 - a machine without a Vulkan device: DECIDED Nov 22, required behind one probe** (`vk_shader_probe
  --device`); `-Dskip=vulkan-device` leaves the GPU checks out of the ubercommands, and the run says what it left out
  (4f).
- **D4 - the examples `test-everything` runs: DECIDED Nov 22, every example, each host once** - the unfocused
  smoke in Node, and on Vulkan each example's gallery shot (section 3).
- **D5 - the platforms `build-everything` builds: REVISED Nov 22, 15:30, every example for `-Dplatform`** (Simon:
  "Builds only") - what `all-examples` builds, beside every build that is no platform's; the tests stay as D4 and D8
  say. First decided the same day as web, Windows and Linux for every example and two APKs (the launcher's and
  go-puzzles-hero's) behind an `android-sdk` probe; withdrawn because it built on every platform by default and added
  Linux's ~300 steps to every configure (section 3).
- **D6 - the simplifications: DECIDED Nov 22, all seven of section 5, in its order, as S7**; the three "not proposed
  now" stay out.
- **D7 - `test-everything` and `build-everything`: DECIDED Nov 22, `test-everything` makes everything
  `build-everything` makes** - one command is the whole answer (section 3).
- **D8 - the examples' mode: DROPPED Nov 22 (Simon: "Drop it"), every page smoked once, in the `-Dmode` given.**
  First decided the same day as every page smoked twice, as Debug and as release wasm: a second web module graph,
  every example's wasm compiled twice per run - the biggest piece left, given up to finish sooner (section 3a).

## 8. Final review (Nov 22) - AGREED by Simon, Nov 22: "Agreed, all of it"

**The decisions:**
1. **D1** - the tier registry: every top-level step declares its kind where it is made, and the aggregates are built
   from the kinds.
2. **D2** - the gate runs all of `test`.
3. **D3** - a Vulkan device is required, behind one probe (`vk_shader_probe --device`); `-Dskip=vulkan-device`
   leaves the GPU checks out, and the run says what it left out.
4. **D4** - every example runs once in Node (the unfocused smoke) and once on Vulkan (its gallery shot).
5. **D5** - `build-everything`: web, Windows and Linux for every example, and two APKs (the launcher's and
   go-puzzles-hero's), behind the `android-sdk` probe. Revised the same day: every example for `-Dplatform` (7).
6. **D6** - the seven simplifications of section 5, in its order, as S7.
7. **D7** - `test-everything` makes everything `build-everything` makes.
8. **D8** - every page smoked as Debug and as release wasm; everything else in the `-Dmode` given. Dropped the same
   day: every page smoked once, in the `-Dmode` given (7).

**The plan's own proposals, agreed together with them:**
- a. The five kinds (check, part, build, writes, runs) and the four rules `finish` enforces when the build configures
  (4d): a step made without a kind is a configure error, and neither ubercommand reaches a step that writes the tree.
- b. The ladder: two branches meeting at `gate`, since tests are never gated on style; every existing check keeps its
  tier; the orphans placed as appendix A says - `dag-check` in `tripwires`; the goban, music theory, keyboard, native
  input, platform contract and vk-gen tests in `test`; `c2js-canary`, `vorbis-reference`, `geno-trainer-layout` and
  `win32-abi-check` in `gate`; the rest in `test-everything`.
- c. `test-everything` runs every assertion at its largest size - the slow tests, and vk-host-test's long checks once
  their timings print only under `-Dtest-report`, through the report gate the robot tests use - and leaves out the
  parked tests and the measurements.
- d. The four `*-verify` checks write under zig-out and print nothing when they pass.
- e. `-Dskip` and `-Dfocus` print what they left out, through `tools/build_note.zig`, which also prints
  `help-checks`.
- f. zbuild runs `gate`, `test-everything` and `build-everything` to completion by default.
- g. Linux's per-example builds and the two APKs exist in every configure, the configure's time measured before and
  after (S2). Withdrawn with D5's revision.
- h. The consumer `Project` API stays out of scope.
- i. Stages S1-S7 in order, each ending green with its checks seen to fail first; then the first full run, timed per
  tier and recorded.

Simon agreed to all of the above on Nov 22, so this plan is **FINAL**. That is still not permission to implement: S1
starts only when he says so. Before S1, check that no other session is editing build.zig - it changed under this
plan at 12:14 on Nov 22 - since every stage edits it.

## Appendix A - every step's proposed kind (Nov 22)

Tiers as in section 3; **new** marks a check that no aggregate runs today.

**check, style:** `lint`, `lint-check`.

**check, invariants (`tripwires`):** `corpus`, `smoke`, `doc-gate`, `zm-gpu`, `zn-rl-gpu`, `tools-test`,
**`dag-check` (new)**; unnamed: the spv binding check, fixture WGSL, pointer-kernel check, editor-configs check,
doc-folds `--check`.

**check, quick tests (`test`):** `test-fast`'s roots, `src/tests.zig`, the mesh test, the 11 tier-A wasm builds,
**`test-goban`, `test-music-theory`, `test-magic-isomorphic-keyboard`, `native-input-test`,
`platform-contract-test`, `vk-gen-test` (new)**.

**check, gate:** `lint-coverage`, `lint-test`, `audio-worklet-test`, `audio-page-test`, `c2js-diff`,
`platforms-check`, `external-check`, `template-check`, `doc-sync`, `tools`, **`c2js-canary`, `vorbis-reference`,
`geno-trainer-layout`, `win32-abi-check` (new)**.

**check, everything:** **slow tests, the unfocused `smoke-test` (every page in Node, in the `-Dmode` given: D8
dropped), every example's gallery-shot
Run (Vulkan), `flagships-check` (Vulkan),
`audio-scale-star-check`, `magic-isomorphic-keyboard-check` (Vulkan), `vk-shader-probe`, `vk-host-test` (Vulkan),
`vk-abi-check` (Vulkan headers), `test-windows`, `shadowmap-sw-verify`, `cel-shading-verify`,
`shader-effects-verify`, `hybrid-render-verify` (new)**.

**part:** the ~45 `test-<stem>`, `test-fast` (inside `test`, which the gate runs: D2), every `<app>-headless` (the
program its gallery shot runs, with its own script: D4), `smoke-test -Dfocus=<x>`,
`verify-imports`, `smoke-install`, `smoke-install-safe`, `doc-folds-test`, `corpus-diff` (a filtered copy of
src/tests.zig), `check` (compile-only copies), `tier-a-check` and `test-all-examples` (unless retired).

**app** (S2d): every `<app>` - one app for `-Dplatform`, failing for a platform the app lacks (`appBuildFor`);
`all-examples`, a `build` inside `build-everything`, builds every app the platform has.

**build:** `install`, `all-examples` (every example for `-Dplatform`, D5), `tools`, `zbuild`, `measure`,
`st-bench`, `readme`,
`doc-pages`, `cheatsheet`, `docs`, `example-sources`, `kernels-wgsl`, `robotgpu-wgsl`, `gallery-shots` (Vulkan;
its Runs are also `test-everything`'s checks, D4), `geno-trainer`, `geno-trainer-windows`, `vk-host-test-windows`, `vk-hello-windows`, `wgpu-bringup`, `standalone`,
`bridge-hello`, `bridge-slice`, `bridge-classic-probe`.

**writes:** `lint-fix`, `fmt`, `doc-folds`, `corpus-refresh`, `editor-configs`, `files-md`, `files-html`,
`dag-png`, `urdf-import`, `zimrnum-ref`, `clip-bake`, `vk-gen`, `dist`, `publish`, `rename-local`,
`rename-pub-fn`, `zm-namedimports`, `uninstall`.

**runs:** `run`, every `run-<app>`, `serve`, `serve-only`, `signal-server`, `render-server`, `goban-play`,
`goban-arena`, `goban-problems-convert`, `bmpc-cartpole`, `robot-bench`, `zimrnum-hello`, `mesh-bake`, `bvh-trim`,
`lafan-db`, `decl-deps`, and the PNG demos `sw-mandelbrot`, `comptime-mandelbrot-ascii`, `sw-engine-shader`,
`julia-gallery-png`, `sw-julia`, `comptime-julia-png`, `native-plot-png`.

## Journal

- Nov 22: v1 proposal written from a read of build.zig and src/notes/claude.md. Nothing built or run.
- Nov 22: **D1 decided: the tier registry.** v2: the ladder corrected into two branches meeting at `gate` (tests are
  never gated on style); section 1b corrected (`doc-folds-test` and `corpus-diff` are copies of checks that run;
  the four `*-verify` checks write PNGs into the working directory); the registry designed (section 4); every step
  classified (appendix A); found that this Zig's runner cannot mark a check skipped (4f); stages S1-S7; D7 added.
- Nov 22: **D2 decided: the gate runs all of `test`.** v3: what that costs (section 3; in the sandbox the gate now
  runs detached, like `test`); what `test-everything` leaves out by definition (parked tests, measurements) and the
  long checks proposed in; 4f rewritten from four facts - a green run prints no summary (Maker.zig:874), a failed
  dependency stops its dependents, and `vk_shader_probe` with no shaders is already a device probe - into D3's
  three options.
- Nov 22: **D3 decided: required behind one probe, `-Dskip=` to leave out.** v4: the probe, `-Dskip=`, its note and
  `tools/build_note.zig` designed (4f), `-Drequire-all` dropped. Corrected 1b: `smoke-test` with no `-Dfocus` already
  runs every page (the gate's comment says otherwise and is stale); a headless run exits 1 when unclean, and
  `gallery-shots` already runs every example's headless program. Found tier-A defined twice, 11 vs 8 (5, item 9b).
  D8 added (the examples' mode).
- Nov 22: **D4 decided: every example, each host once.** v5: the unfocused smoke and each example's gallery shot as
  `everything` checks, the shot standing for `<app>-headless` (now a `part`), `-Dshots` and `-Dfocus` handled
  (section 3); S4's seen-to-fail. For D5: what each platform builds today, read from build.zig (Windows always, Linux
  and Android only under their `-Dplatform`; an APK is the web build's wasm plus its packaging).
- Nov 22: **D5 decided: web, Windows and Linux for every example, and two APKs** (the launcher's, go-puzzles-hero's:
  the only app with its own Android id, label and icon). v6: Linux's builds and the two APKs made in every configure,
  the configure's time measured in S2; `android_apk --check` as the `android-sdk` probe (4f, S5).
- Nov 22: **D7 decided: `test-everything` makes everything `build-everything` makes.** v7: build.zig changed under
  this plan (12:14, +72 lines, no step added or removed, the gate's wiring the same), so every citation now names
  what it cites instead of a line. For D8: the mode table and what each mode strips, from build.zig's comments.
- Nov 22: **D8 decided: every page smoked as Debug and as release wasm, the rest in the mode given.** v8: the second
  smoke's own directory (3a), S4's two mode-only seen-to-fails. Section 5 rewritten as D6's proposal - seven items in
  order, three not now - with the `--help` count corrected (~300 lines fewer, not "about 250 remain"); no editor
  config names a step it would retire.
- Nov 22: **D6 decided: all seven simplifications, in order, as S7.** v9: section 8, the final review - the eight
  decisions and the nine proposals made inside the plan, for Simon's agreement.
- Nov 22: **FINAL.** Simon agreed to every decision and proposal ("Agreed, all of it"). Not implemented; S1 waits for
  his go.
- Nov 22, 12:48: **S1 started on Simon's go, then held before any edit**: build.zig was being edited by another
  session at that moment (`hello_world_owned_main` added to the app table at 12:47:17, by the "Hello world owned
  main example" session). Read for S1 and verified in dev.753's std (`StringArrayHashMapUnmanaged`, `EnumArray`,
  `Step.TopLevel`, `Build.step`), nothing written. S1 split into S1a-S1d; the tiers' composition and rule 2 moved to
  S2 (section 6).
- Nov 22, 12:55: **S1a written** (Simon: "do it now. The other one is finished"; build.zig unchanged since 12:47:17
  when it began). `CheckTier`, `Need`, `CheckPlace`, `StepKind` and `StepRegistry` (`init`, `step`, `declare`,
  `tierStep`) above `gateEveryTool`; `var steps` at the top of `build()`; `test`, `tripwires`, `lint-check` and
  `gate` made through `tierStep`, their names and descriptions unchanged. Checked here: `zig fmt --check` and
  `zig ast-check` (dev.753), and the 60 lint rules with the baseline - the linter first seen to fail on a planted copy
  of build.zig; it caught a 121-column line and a four-parameter fn of mine, both fixed. Not compiled: Simon's build
  is its type check. S1b next.
- Nov 22, 13:05: **S1b written** (Simon: "Go on to S1b"). `StepRegistry` gained one maker per kind - `check`,
  `part`, `build` (needing nothing; a build with a need uses `step`), `writes`, `runs` - so a call site reads as what
  the step is for. The 55 steps of `build()` that are not checks are made with them: 9 parts, 21 builds, 11 runs, 14
  writes, matched by name by a script that wrote nothing unless every name matched exactly once; five lines that
  passed 120 columns were split. One kind differs from appendix A: `smoke-install-safe` is a `build`, not a `part` -
  it only installs, and nothing reads what it installs. The sub-steps grow by one: S1c the 38 checks of `build()`
  (`gallery-shots`, a build with a need, among them), S1d the steps the helpers make (`buildTools`,
  `buildNativeExamples`, `gateEveryTool`, `addHeadlessRunOf`, `addCompileCheck`, `addVorbisReferenceStep`), S1e
  `finish` and `help-checks`. Checked as S1a was: fmt, ast-check, the 60 rules (seen to fail on a planted copy
  first).
- Nov 22, 13:15: **S1c written** (Simon: "Go on to S1c"). The 38 checks of `build()` made with
  `steps.check(name, description, place)`, tiers and needs as appendix A has them - 7 `invariants`, 6 `quick_tests`,
  12 `gate`, 6 `everything`, 1 `everything` needing the Vulkan headers (vk-abi-check), 5 `everything` needing a Vulkan
  device - and `gallery-shots` with `steps.step(..., .{ .build = .vulkan_device })`. No `b.step` call is left in
  `build()`. The `zimrnum_fit` session had edited build.zig at 13:07 (zimrnum for the job-kernel wasm, beside
  `addEngineOptionsAndRobot`), away from every step site; the script wrote only after finding the file unchanged since
  its read. Checked as before. S1d next: the steps the helpers make.
- Nov 22, 13:35: **S1d written** (Simon: "Go on to S1d"). The six helpers that make top-level steps - `buildTools`,
  `buildNativeExamples`, `gateEveryTool`, `addHeadlessRunOf` (and `addHeadlessRun`, which calls it),
  `addCompileCheck`, `addVorbisReferenceStep` - take `steps: *StepRegistry` after `b`, and their nine calls pass it.
  Their 16 steps have kinds: `mesh-bake`, `bvh-trim`, `lafan-db`, the two servers and the six picture demos `runs`;
  `zbuild` a `build`; the hand-run tools' table a kind per row (`decl-deps` runs; `rename-local`, `rename-pub-fn` and
  `zm-namedimports` write); `tools` and `vorbis-reference` `gate` checks; every `<app>-headless`, and `check`, parts.
  Outside the consumer `Project` API no `b.step` call is left in build.zig. The `decl-order` rule caught the registry
  declared below its first use once `buildTools` took it; the block moved, whole, above `buildTools`. build.zig had
  changed at 13:18 (the `zimrnum_fit` app row); the edit was written only after finding it unchanged since its read.
  Checked as before. S1e next: `finish` and `help-checks`.
- Nov 22, 13:45: **S1e written** (Simon: "Go on to S1e"): `StepRegistry.finish`, called last in `build()`, and the
  graph walk it uses, `stepsReachedFrom`, above the registry; `CheckTier.isStepName`; an `Allocator` alias. Rule 1
  (every top-level step has a kind - Zig's own two, `install` and `uninstall`, are the only steps dev.753's
  `Build.create` makes, and `init` declares both), rule 4 (a tier's name made by hand) and rule 3 (a tier's step that
  reaches a `writes` or `runs` step) each add a line to one message; a broken rule makes every top-level step depend
  on one `b.addFail` with it. On today's tree every rule should hold, so nothing changes until one breaks. The linter
  caught a qualified `std.mem.Allocator` (`no-qualified-std`) and a 122-column line; both fixed. `help-checks` became
  its own sub-step, S1f, to keep the turn's code near 150 lines.
- Nov 22, 13:55: **S1f written - S1 is complete** (Simon: "Go on to S1f"). `tools/build_note.zig` prints the one
  file it is given. `StepRegistry.addHelpChecks` makes `help-checks` just before `gateEveryTool`, so `tools` compiles
  the printer; `writeHelpChecks`, called by `finish` whether the rules hold or not, writes its text: each tier's step
  and what it depends on directly, each tier's checks - marked "(not run by `<tier step>` yet)" where the tier's step
  runs neither the check's step nor every step it depends on (`isRunBy`) - then the parts, builds, writes and runs.
  readme.html lists no gate or tier step today, so it waits for S6. To expect from Simon's first `zbuild help-checks`:
  the four tier sections as section 1a has them, and "not run yet" on exactly section 1b's checks - `doc-sync` among
  them, its Run not being the gate's (S7, item 2) - and on every `everything` check. Next: S2.
- Nov 22, ~14:00: **S1 built and seen to hold** - Simon ran `zbuild help-checks`: S1 compiles, the rules hold, and
  the map is as predicted. `lint-check` holds its two zimrlint runs; `tripwires` its twelve members and `gate` its
  thirteen, as section 1a lists them; "not run yet" marks exactly `dag-check`, the six example-local and tool test
  roots, `c2js-canary`, `vorbis-reference`, `geno-trainer-layout`, `win32-abi-check`, `doc-sync`, and the twelve
  `everything` checks. The new `zimrnum-fit` app came in through the app loops with its kinds. Not predicted: `test`
  lists each tier-A example's install twice - its web install and the copy `addWgpuSmoke` installs into
  zig-out/wgpu-smoke/web, one compile installed twice. Still to run: S1e's two seen-to-fail checks.
- Nov 22, 14:10: **S1e's seen-to-fail run, first try: the rules fired, but zbuild hid which.** Both mutations in (a
  bare `b.step` for `bvh-trim`, `gate` depending on `lint-fix`, each marked `S1e SEEN-TO-FAIL MUTATION`), Simon's
  `zbuild help-checks` failed at the `fail` step - so a rule broke - and zbuild showed only the message's first line:
  its `classify` (tools/zbuild.zig) takes the indented lines under an unpositioned `error:` for source snippets and
  drops them. Fixed where the message is made: `finish` now adds one Fail step per broken rule, its message one whole
  line. The mutations stay in for the rerun.
- Nov 22, ~14:20: **S1 seen to fail, then reverted - S1 is done.** The rerun failed at two `fail` steps, zbuild
  showing both whole: "`bvh-trim` has no kind: make it with `steps.check`, `steps.runs` or another maker of its kind"
  (rule 1) and "`gate` reaches `lint-fix`, a step that writes the tree: no tier's step may" (rule 3). Seen on the
  way: `help-checks` prints its map even while a rule is broken (its run does not wait on the Fail steps, only its
  top-level step does), and a step with no kind is in none of the map's lists - rule 1 is what names it. Both
  mutations reverted (no marker, no bare `b.step` outside the consumer `Project` API); fmt, ast-check and the 60 rules
  clean. Rule 4 (a tier's name made by hand) was not mutated: `b.step` refuses a second step of a name, so the only
  way to break it - `steps.step` with a tier's name, `tierStep` never called - is left to its one-line check. Next: S2.
- Nov 22, 14:30: **S2a written** (Simon: "Start S2"). `CheckTier.holds` is the ladder as data - `tripwires` holds
  `lint-check`, `gate` holds `tripwires` and `test`, `test-everything` holds `gate`, `test` holds no style tier - and
  `StepRegistry.composeTiers`, first in `finish`, wires it: each tier's step depends on the tier steps it holds that
  it does not depend on yet, then on every check of its own tier it does not run yet (`isRunBy`), lowest tier first.
  The hand wiring stays; this adds what is missing: `gate` -> `test` (D2), `tripwires` -> `dag-check`, `test` -> the
  six example-local and tool test roots, `gate` -> `geno-trainer-layout`, `c2js-canary`, `vorbis-reference`,
  `win32-abi-check` and `doc-sync` (whose own Run joins the gate's `gate_doc_sync`, both running until S7 merges them).
  The gate's description and claude.md (its "test-fast is the step the gate runs", and "NEVER the full `zig build
  test` inside a turn" now naming `gate` too) say so. The placed checks are the ones nothing ran: some may be red.
- Nov 22, 14:45: **S2b written** (Simon: "still running. I guess continue?" - his run of the placed checks had
  passed `dag-check` and `c2js-canary` so far). The four `*-verify` programs take `std.process.Init`, read
  `ZIMR_CAPTURE_DIR` from `init.environ_map` (no libc needed, unlike `native_os.environmentVariable` off Windows),
  make it with `createDirPathOpen` and write their pictures into it; build.zig runs them from the build root with
  `ZIMR_CAPTURE_DIR=zig-out/verify`, as the headless runs use zig-out/headless, and their descriptions say where the
  pictures go. Each prints its measurements only when a check fails, naming where its pictures are. Found by
  Simon's run, not foreseen: `dag-check`, which S2a put in `tripwires`, printed its whole report (~40 lines) on a
  pass. It is silent on a pass now; the report is behind its new `--report` option, run by a `runs` step of its own,
  `dag-report`. `c2js-canary` still prints one line on a pass ("CANARY PASS: ..."), from its Node harness: left as
  it is, a candidate for the same treatment.
- Nov 22, 14:50: **`doc-sync` made fast; the gate's copies of the doc checks gone** (Simon asked whether
  `doc-sync`'s length was normal: it was not). tools/doc_sync.zig scanned every source of a tutorial, line by line,
  for every quoted line - in Debug: 7,684 quoted lines x 87,765 source lines for robots.html and 16,301 x 154,329 for
  the mocap tutorial, some 3.2 billion compares at worst (another session had just added four sources to robots.html's
  list, at 14:32). It now reads a tutorial's sources once into a set of trimmed lines, so each quoted line is one
  lookup; the output is unchanged. Found on the way: `doc-sync`'s own run had no `has_side_effects`, so
  `zig build doc-sync` was cached - a pass that outlived an edit to a page or a quoted source; it always runs now.
  The gate's own copies of `doc-folds --check` and `doc-sync` are gone (S7's item 2, its `doc-sync` half): `tripwires`
  runs the first, and the gate holds `doc-sync` as a check since S2a. The gate's stale "NOT the smokes" comment now
  says the smokes are `test-everything`'s. Open, asked: `geno-trainer-layout`, now in the gate, builds the trainer
  ReleaseSafe through LLVM whenever the robot family or the kit changes - a Debug twin for the check, or `everything`.
- Nov 22, 14:55: **Correction before any edit: the gate already compiled the ReleaseSafe trainer, through `tools`.**
  Simon chose the Debug twin; reading `gateEveryTool` first showed `tools` (in the gate since before this plan) takes
  every exe rooted in tools/ - so the host and Windows trainers, ReleaseSafe through LLVM, were the gate's already.
  `geno-trainer-layout` reuses the host one: S2a added its run, not that compile. A Debug twin alone would add a
  compile. `gateEveryTool`'s own comment leaves the robot tools in src/ out of `tools` for this very cost ("gated,
  every robot change would recompile them for minutes"); the trainer escaped that only by living in tools/. Asked
  again: leave the trainers out of `tools` and give the layout check its Debug twin, or leave both as they are.
- Nov 22, 14:54: **The trainer out of `tools`, the layout check on a Debug twin** (Simon: "Yes, both"). A
  `tools_left_out_of_gate` list beside `gateEveryTool` (the trainer, with the reason) keeps every compile rooted at
  tools/geno_trainer.zig out of `tools`; `night_trainer_optimize` (ReleaseSafe, the reason moved to it) is what
  `addGenoTrainer`'s callers that train pass, now that it takes `optimize`; `geno-trainer-layout` runs a trainer of
  its own in Debug - the buffers it measures are the build's constants, the same in every mode. So the gate compiles
  the trainer once, on Zig's own backend, instead of twice through LLVM in ReleaseSafe; `geno-trainer`,
  `geno-trainer-windows` and (S2d) `build-everything` still build the night's trainers. The risk to watch: the
  trainer has not been compiled in Debug before - if Zig's own backend refuses it, the twin takes `use_llvm`. Also
  checked: tools/dag_check.zig and tools/doc_sync.zig, rewritten on disk at 14:47 by something else (a `lint-fix`?),
  still hold S2b's `--report` and the line index, and pass fmt, ast-check and the 60 rules. Still printing on a pass:
  the layout check itself (`stdio = .inherit`, the trainer's numbers), like `c2js-canary` and `doc-sync`'s summary.
- Nov 22, 14:56: **The Debug twin seen to work**: Simon's `zig build geno-trainer-layout` compiled the trainer in
  Debug on Zig's own backend - no `use_llvm` needed - and the first night's recipe fit every buffer (the fullest:
  parameters 6,044,857 of 8,388,608, `model_f` 21,884,260 of 33,554,432). It printed its eight lines on a pass, as
  noted. Next: S2c. (These two entries were first written as 15:00 and ~15:05: guesses, the clock said otherwise.)
- Nov 22, 15:00: **S2c written** (Simon: "Start S2c"). `finish` makes `test-everything` (`tierStep(.everything)`,
  last, since nothing is wired to it by hand), and `composeTiers` gives it `gate` and the `everything` checks - now
  only those that need nothing: a check with a need waits for its probe (S5) before any tier holds it. So
  `test-everything` holds `gate`, the four `*-verify` checks, `test-windows` and the unfocused `smoke-test` - every
  page in Node, in the `-Dmode` given; S4 adds D8's second mode, and the plan had placed the smoke there, but it
  needs nothing, so it comes in now. Rule 2 cannot hold yet - ~300 `<app>-headless` parts are inside only once the
  gallery shots are (S4-S5), and `test-all-examples` once `build-everything` is (S2d) - so `help-checks` reports it:
  every part `test-everything` does not run, counted, under "rule 2, enforced once this is empty". The copies
  (`corpus-diff`, `check`, `doc-folds-test`) will need their note then.
- Nov 22, ~15:05: **S2a and S2c seen to hold** - Simon's `zig build help-checks`: `tripwires` holds `dag-check`,
  `test` the six test roots, `gate` holds `test` and its five placed checks (the old `run exe doc_sync` copy gone),
  and `test-everything` holds `gate` and the six `everything` checks that need nothing; only the six that need a
  device or the Vulkan headers are "not run yet". Rule 2's list: 360 parts - 332 `<app>-headless` (S4-S5), 
  `test-all-examples` (S2d), the three copies, and, not foreseen, 24 more copies: the robot family members' own
  `test-<stem>` roots, whose tests run in `test-robot_tests`' one binary (`aggregated_elsewhere` keeps their own
  runs out of `test-fast`). So rule 2's copy note is for 27 parts, not 3.
- Nov 22, 15:18: **S2d's first half written** (Simon: "Go on to S2d"). `finish` makes `build-everything` (a `build`
  that needs nothing): every `build` step that needs nothing beyond Zig - `install`, the docs, the trainers, `zbuild`
  and the rest - and the outputs no top-level step names, each registered with `addOutput`: the web's every example
  (`web_examples_step`), each Windows program in `windows_builds`, each Linux program in `linux_builds`, and every
  tool (`tools`, from `gateEveryTool`). `test-everything` holds it (D7), its description saying so; so
  `test-all-examples` (`test` beside the web's examples) is inside `test-everything` now and leaves rule 2's list.
  **A gap in the plan, found writing it: every `<app>` step follows `-Dplatform`, and fails by design for an app that
  platform lacks** (`appBuildFor`: the gallery on the web, each `native_pending` app natively), so with every `build`
  inside it, `build-everything` would have failed under every `-Dplatform`, and `test-everything` with it. Under
  `-Dplatform=android`, `all-examples` and the app steps would also have built every APK, which D5 leaves to
  `zig build all-examples -Dplatform=android`. Section 4a and Appendix A had made both `build`s. They are a sixth kind
  now, `platform_build` (`steps.platformBuild`), which `build-everything` leaves out: it builds every platform's
  instead, so it is the same whatever `-Dplatform` says (section 3a), and `help-checks` lists them on their own. The
  app steps were also where `build-everything` got its clean tree (each depends on `lint-check`), so `finish` makes it
  hold the style tier's step itself. Section 8's "five kinds" is left as agreed; it is six since this entry. Linux's
  examples still exist only under `-Dplatform=linux`: the condition goes once the configure is timed with and
  without them. Checked first, in dev.753's Maker: a configure's result is cached (`.zig-cache/c/<digest>`), which
  would make a second run time nothing - but zimr's configure poisons that cache on every run (the shader and lint
  walks, `collectShaderFiles`), so each `zig build -l` runs `build()` again, then lists and exits. The two timings:
  this machine's platform (Windows) against `-Dplatform=linux`, after a first run that compiles the build script.
- Nov 22, 15:27: **D5 reopened; S2d's second half on hold.** Simon, on the configure timing asked for: "My feeling
  now is that we should maybe try to not build really on every platform by default. Test/build everything should only
  test the specified platform." Asked, one decision: how far `-Dplatform` reaches. (1, recommended) the builds only:
  `build-everything` builds every example for `-Dplatform` - what `all-examples` builds - beside everything that is
  no platform's (tools, docs, trainers, zbuild), and the tests stay as D4 and D8 say, since they run on what this
  machine has (Node, its Vulkan device) whatever `-Dplatform` says. (2) the tests too: `-Dplatform=web` smokes the
  pages, a native platform runs the Vulkan shots - so a default run here no longer smokes the pages, and the shots,
  this machine's own program, cannot follow `-Dplatform=linux` or `android` at all. Either way Linux's examples stay
  under `-Dplatform=linux` alone, so the configure is not timed, and D5's two APKs and the `android-sdk` probe go:
  `-Dplatform=android` builds every APK, and tools/android_apk.zig already names what is missing. What is lost: an
  example outside the launcher's 35 flagships that breaks only on another platform is seen when that platform is
  built; `platforms-check` (in the gate) still compiles the launcher for the web, Windows, Linux, macOS and Android.
  S2d's first half (the three platforms as outputs, `platform_build`) stays in the tree, unbuilt, until the answer.
- Nov 22, 15:39: **D5 revised (Simon: "Builds only"); S2d reworked to it.** `build-everything` holds every `build`
  step that needs nothing beyond Zig - `all-examples` a plain `build` again, every example for `-Dplatform`, which
  also brings `lint-check` (ARTIFACTS REQUIRE A CLEAN TREE), so the explicit dependency on the style tier is gone -
  and `tools`, through `addOutput`, now its only use. The three platforms' outputs are gone from `build()`; Linux's
  examples stay under `-Dplatform=linux`, and the configure was not timed, nothing being added to it. The sixth kind
  is `app` now (`steps.app`), the app steps alone - not `app_build`, which read like `appBuildFor`, the app's build
  for the platform that each such step depends on; `help-checks` lists them under "apps". `Need.android_sdk` went
  with D5's two APKs. Revised to match: D5 (section 7), section 3's `build-everything` and what D7 adds, 3a's
  `-Dplatform`, the sketch's `Need`, 4f's `android-sdk` (a note that it went), S2d, S5, the 4a table and appendix A;
  section 8 marks D5 revised and g withdrawn; the title says v10. Still outside `test-everything`:
  `test-all-examples`, whose `web_examples_step` no tier reaches (the smoke runs on its own directory) - it leaves
  rule 2's list when S7 retires it (D6, item 3), not in S2d as the S2c entry said. Next: Simon's `help-checks`.
- Nov 22, 15:43: **S2d seen to hold** - Simon's `zig build help-checks` (so the build script compiled and `finish`'s
  rules passed): `build-everything` and `all-examples` among the builds; every app's step under "apps", apart;
  `test-everything` depends on `build-everything`, `gate`, the four `*-verify` checks, `smoke-test` and
  `test-windows`; rule 2's list 360, `test-all-examples` on it, as the 15:39 entry said. Not run yet:
  `build-everything` itself (every Windows program, the docs, the tools, the trainers); S2b's four `*-verify`
  checks with `dag-check` and `dag-report`; `doc-sync` since its line index (14:50). Next, on Simon's go: S3.
- Nov 22, 15:56: **S3a written** (Simon: "Start S3"), S3 split in two (section 6). Studied first: `-Dslow-tests` is
  one option of the one `build_opts` every host test compiles against, so a root's quick and slow builds are two
  compiles. The 113 slow gates are all comptime (`comptime @hasDecl(options, "slow_tests") and options.slow_tests`,
  some sizing arrays), so a switch at run time - one binary, run with or without its slow tests - would rewrite
  eighteen robot files other sessions work in: not taken. All 113 are in files `src/robot_tests.zig` imports. S3a
  moves one fast root's compile into `addFastTestCompile` - its module, and the named modules beside it that read
  the options too (codecs, the robot modules, the MJCF importer), built against the `Options` it is given - and
  one run into `addFastTestRun` (shard, timing, filter, skip prefixes, a training chunk's side effects), both above
  `build()`. The loop calls them, the skip prefixes are listed once per root, and `FastTestWiring` sits above the
  loop, being the same for every root. Behaviour unchanged - the same modules, the same arguments in the same
  order, the same names - so `test-fast` after it should rebuild nothing the sources did not change. fmt, ast-check
  and the 60 rules clean. Next, on Simon's go: S3b.
- Nov 22, 16:06: **S3b written** (Simon: "Go on to S3b"). `slow_build_opts` is `build_opts` field for field, in
  the same order, with `slow_tests` on - so under the same `-D` options it should generate the very file
  `-Dslow-tests` does, and `zig build test-fast -Dslow-tests` compile the binaries `test-everything` runs. Every root
  `test-fast` runs gets a twin (`addFastTestCompile` against it) unless `-Dslow-tests` is given, and each of the
  twin's runs (same shard, same arguments) stands in for the quick one (`StepRegistry.standIn`). `composeTiers` makes
  one tier at a time now, lowest first, so `gate` is whole - its own checks placed - before `test-everything` holds
  it, through `holdInPlace`: a step that leads to no stood-in run is held whole (`leadsToStandIn`, memoized), one
  that does is opened, and a stood-in run gives way to its stand-in. So `test-everything` holds `gate`'s members,
  not `gate`: `tripwires` and the gate's checks whole, `test-fast` and `test` opened, the quick fast-root runs
  replaced by their twins (4e, opened only where it matters). `isRunBy`, a method now, counts a step as reached
  when its stand-in is, so `test-fast` and every `test-<stem>` part of a root it runs stay inside: rule 2's list
  should stay at 360. Every fast run is named now - `run test <stem>`, its shard, and ` (slow tests)` when they
  are on - where an unsharded one was `run test` alone. Under `-Dslow-tests` nothing stands in, and
  `test-everything` holds `gate` whole as before. Caught on the way by ast-check: two parameters named `step`
  shadowed the registry's `step`. fmt, ast-check and the 60 rules clean. To see: `help-checks` (`test-everything`'s
  list: the gate's members and `(slow tests)` runs, no `gate`; rule 2 still 360), `test-fast` (S3a), and
  `test-fast -Dslow-tests` for the twins' code. Seen to fail, at the first full run: a slow test made to fail fails
  `test-everything` and not `gate`.
- Nov 22, 16:13: **S4's shots written** (Simon: "Ok lets focus and finish as soon as possible"). `headless-test`,
  an `everything` check that needs a Vulkan device (so it joins `test-everything` with the probe, S5): every
  example's gallery shot - made now for every example, `-Dshots` narrowing `gallery-shots` alone - each after its
  program's install, and the gallery's own headless run, which has no shot. Each shot stands in for its example's
  `<app>-headless` run, and `flagships-check`'s sweep for `launcher-headless`'s, so those parts count as run once
  their checks are inside (S5): rule 2's list should fall from 360 to 28 then. `addHeadlessRunOf` returns a
  `HeadlessRun` (the program, its install, its run). The `-Dfocus` note waits for S5's `-Dskip` note, the same
  machinery. Not written: D8's second smoke mode - every example's wasm compiled again in the other mode, which
  needs a second web module graph (engine, apps, kernels) - asked whether to keep it, to finish sooner. fmt,
  ast-check and the 60 rules clean.
- Nov 22, 16:15: **D8 dropped** (Simon: "Drop it"): every page is smoked once, in the `-Dmode` given;
  `-Dmode=release` smokes the release wasm. Section 3a, S4, D8 (7), section 8's item 8 and appendix A say so. S4 is
  now the shots alone, written at 16:13; its `-Dfocus` note comes with S5's `-Dskip` note. Next: S5.
- Nov 22, 16:21: **WHAT REMAINS** (Simon: "stop. Just note in the plan of what remains").
  Done: S1 (verified), S2a-S2d (verified by `help-checks`), S3a-S3b and S4's shots (written; Simon's
  `zig build test-fast -Dslow-tests` ran the new run names; `zig build help-checks` configured cleanly at 16:20 with
  them - Simon asked to make sure it compiles: `test-everything` holds 90 members, 35 `(slow tests)` runs, no quick
  fast-root run, no `gate`/`test`/`test-fast`; `headless-test` waits for its probe; rule 2's list 360). Fixed then:
  `tier-a-check` (it depends on `test` itself) read as outside once `test-everything` opened `test` - the registry
  now keeps the steps `holdInPlace` opens (`opened`), and `tierReach` counts them as run. Nothing committed.
  Not run yet: S2b's four `*-verify` checks with `dag-check`/`dag-report`; `doc-sync` since 14:50; `test-fast`
  plainly; `build-everything` itself; the end of Simon's `-Dslow-tests` run, whose one failure seen
  (`robotgpu_tests` `expectWorldsIdentical`, `error.WorldsDiffer`) is another session's uncommitted robotgpu work.
  **S5, next, nothing written** - the design, worked out: (1) tools/vk_shader_probe.zig gets `--device`: `Probe.open`
  quiet (the device line in `choosePhysicalDevice` printed only when not probing), exit 0 silently; on failure
  exit 2 with the reason, the fix and "or pass -Dskip=vulkan-device". (2) build.zig: a `--device` Run of the
  probe's exe (`has_side_effects`), the registry's probe for `vulkan_device` (an `EnumArray(Need, ?*Step)`). (3)
  `composeTiers`: a check with a need joins its tier unless `-Dskip` names the need; every direct dependency of it
  that is a Run (`step.tag == .run`) depends on the need's probe; a build with a need (`gallery-shots`) joins
  `build-everything` the same way. `audio-scale-star-check` and `magic-isomorphic-keyboard-check` first depend
  directly on their GPU runs (their direct deps are the sound checks). (4) `-Dskip=<need>[,<need>]`
  (`vulkan-device`, `vulkan-headers`), an unknown name a Fail; a note - a `has_side_effects` Run of build_note (keep
  its exe from `addHelpChecks`) - lists what was left out, and with `-Dfocus` "every page but x's in smoke-test";
  `test-everything` (and `build-everything`, for builds) depend on it. (5) `vk-abi-check`'s Fail message gains "or
  pass -Dskip=vulkan-headers". (6) vk-host-test's long checks: a second `addVulkanHostTest` with `long_checks`
  on (it makes no top-level step), its run standing in for `host_test_run` (`standIn`); its timings, printed under
  `if (test_options.long_checks)` in tools/vk_host_test.zig (~7525, 9358-9721), only under a report option - that
  file is the robotgpu session's (changed 15:53): coordinate. Seen to fail: the validation layer hidden
  (`VK_LOADER_LAYERS_DISABLE`) - the probe the one failure, no GPU check run; `-Dskip=vulkan-device` green, the
  note listing them. Rule 2's list should then fall to 28: the 24 robot `test-<stem>` copies, `corpus-diff` and
  `check` (each needs 4d's one-sentence copy note), `doc-folds-test` (S7, item 2) and `test-all-examples` (S7, item
  3); then rule 2 becomes a Fail of its own in `finish`.
  Then: **S6** - zbuild runs `gate`, `test-everything` and `build-everything` with `--complete` by default (4g);
  readme.html and claude.md rewritten around the ladder; section 5's stale text (claude.md's `tier-a-check` advice,
  the `focus` option's description). **S7** - section 5's seven simplifications, in order, each its own green step.
  **The first full run**, timed per tier, and S3's seen-to-fail there: a slow test made to fail fails
  `test-everything`, not `gate`. Quiet-on-a-pass candidates noted on the way: `c2js-canary`'s line, `doc-sync`'s
  two summary lines, `geno-trainer-layout`'s eight, `vk-shader-probe`'s summary.
