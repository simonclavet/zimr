# tools_audit.md - are the tools working, used, and easy to call? (Simon, Sep 28)

Measured during the cli migration (`archive/cli_migration.md`). Every tool with a `main`, how it is reached, and what was
found by running it.

## Working, wired, earning their place
Gates and generators the build runs itself: `zimrlint` (lint), `spv2wgsl` + `spv2wgsl_check` (shaders), `c2js`
(the host JS), `docfmt` / `doc_gate` / `doc_sync` / `doc_folds` (docs), `verify_imports` (inside every smoke),
`example_source` (the gallery's code pane), `gen_shader_externs`, `buildaux`, `cheatsheet`, `gen_files_md` /
`files_html`, `dag_check` / `dag_png`, `zimrnum_parity` / `zimrnum_ref`, `urdf_import`, `mesh_bake`, `clip_bake`,
`robot_bench`, `st_bench`, `measure`, `serve`. Hand-run, now steps with `-- <args>`: `bvh_trim`, `lafan_db`,
`rename_local`, `rename_pub_fn`, `decl_deps`, `zm_namedimports` (82 files still call `zm.X(...)` qualified - its
migration is unfinished, not obsolete). `src/shader_codegen.zig` is the build's own API, not a command line.

## DECIDED (Simon, Sep 28): delete nothing yet
The obsolete and rotted ones below are KEPT for a couple of weeks - look again around Oct 12 - but UNSUPPORTED:
not fixed, not wired, left out of `zig build tools` on purpose (it gates what a step builds, and nothing builds
these), so their rot cannot turn a gate red: `physics_audit`, `plot_svg_demo`, `decl_reorder.py`, `geno_fit.py`,
`gl2wgpu_ui.py`.

## Every tool compiled: `zig build tools` (Sep 28)
Walks the build graph from every top-level step and compiles each executable rooted in `tools/` (plus the three
tool roots in `src/`) without running it - so a new tool is gated the moment it is wired. `gate` includes it;
`check`, run every turn, does not. The servers are steps now: `zig build signal-server -- --port=N` (PORT, then
7777, without it) and `zig build render-server` (reads PORT, which its host sets).

## Build time (Simon, Sep 28: "the build is so much longer")
Measured: a ReleaseSafe tool costs 22-53 s and ~400 MB to compile whatever its size; the same tool in Debug, 1-2 s
and ~140 MB, with every safety check kept. So a tool's optimise mode now follows its RUN time: heavy or
run-many-times tools stay optimised (zimrlint, spv2wgsl, spv2wgsl_check, c2js, docfmt, example_source x314 per
gallery build, lafan_db, st_bench / robot_bench / clip_bake), everything that runs for a moment is Debug (18 tools:
10 minutes -> 27 s cold). `zig build tools` gates the 33 executables under `tools/` - no longer the three robot
tools in `src/`, which `test-fast` covers and which every robot change would recompile for minutes.
Blind spot, found here: the gate walks the graph at configure time, and a tool reached ONLY through a generated
module file (`addAnonymousImport` of a run's output) has no edge yet - mesh_bake was invisible until it got its own
step, `zig build mesh-bake -- ...`.

## Two generators (Simon's questions, Sep 28)
- `gen_vscode` ALREADY writes the Zed files too (`.zed/debug.json`, `.zed/tasks.json` beside `.vscode/`), from the
  same `build.zig` table, and its output is current - the name hid it. RENAMED (Sep 28): `gen_editor_configs`, step
  `editor-configs`.
- `cheatsheet`: STALE - regenerated it grows 99 608 -> 169 440 bytes - and THIN: 24 modules, none of zimrmath,
  zimrphysics, codecs, robot_track or the plots. And `src/notes/CHEATSHEET.md` (612 KB) is a second, frozen
  cheatsheet whose generator (`scripts/build_cheatsheet.py`) no longer exists; claude.md still called it the API
  surface. DECIDED (Simon, Sep 28): revive it as a page of the real public surface; delete the markdown; the
  `publish` build makes the HTML, and the readme and gallery link to it. DONE so far: `CHEATSHEET.md` and the
  committed root `cheatsheet.html` are deleted; the page is a BUILD OUTPUT - generated on every build, styled by
  docfmt, checked by the doc gate, installed with the other 12 pages, so `publish` (-> dist -> install) carries it;
  the readme links it (nav + the work-in-progress note), the gallery already did. The generator now emits the
  shared-style marker - it had its own `<style>`, and the committed page had been restyled by HAND, so the first
  regeneration brought the old palette back and the doc gate refused it (2 violations). REVIVED (Sep 28): the
  generator reads `src/zimr.zig` with Zig's parser and follows every export - re-exports through files, containers
  and aliases, renamed to the name `z.` gives them - so the page is `z` (334 entries) plus 83 namespaces: whole
  modules and lowercase containers (a TitleCase container is a type and stays one line). 3 129 declarations, where
  the line scanner it replaced found 296 functions. Each section is a `<code class="zig">` block of doc sentence +
  declaration, highlighted by docfmt with Zig's tokenizer. It runs on std's cli. Debug caught one real bug on the
  way: `fullContainerDecl` returns a small container's members inside the caller's stack buffer.

## Open (Sep 28)
- FIXED (Sep 28): `dag_png` was OOM-killed at ~3.85 GB. The graph had grown to 111 modules and the layout's
  alignment pass let gaps grow unbounded - 15,376 px wide - and a fixed 4x supersample costs 64 bytes per final
  pixel (3.8 GB for one canvas). Now: gaps capped (3,247 px), supersampling chosen to fit 768 MB. Improved at the
  same time: curved edges with ports (no knots at hubs), level labels, and box symbols read from each module's
  source where no curated entry exists (65 of 111 had none).
- `measure` still hands its child ONE file for both streams (the positional-writer overwrite trap); zbuild covers
  the log use, so it waits.
- Look again at the kept-but-unsupported tools around Oct 12.

## Not built by anything - so nothing notices when they break
- `signal_server`, `render_server` (the multiplayer signaling servers the readme documents): compile on 2307.
- `physics_audit` (2 147 lines, a headless zimrphysics probe, referenced nowhere): ROTTED - `World.addBody` is gone.
- `plot_svg_demo` (26 lines, referenced nowhere): renders plot's demo through the SVG sink; untested here.

## Not Zig (against the repo's rule; `scripts/robot_oracle.py`, `robot_bench_mujoco.py` are the documented
exceptions - independent MuJoCo oracles)
`tools/decl_reorder.py` (decl_deps' only consumer), `tools/geno_fit.py` (Geno's geoms), `tools/gl2wgpu_ui.py` (a
one-shot UI migration, applied).

## Ease of use
- FIXED (Sep 28): `--help` named the binary's cache path; every converted tool now sets `cli.Config.prog` to the
  command a person types (`Usage: zig build decl-deps -- [ARGS]`, `tools/zig-out/bin/st_bench_safe`), or the tool's
  bare name where only the build runs it. The three hand tools' headers show their `zig build <step> --` usage.
- FIXED (Sep 28): a direct `zig build` prints a one-line tip about zbuild, ONCE per cache (a stamp in
  `.zig-cache/`); a build started by zbuild (ZIMR_ZBUILD set) never does.
- `zbuild` is now the build wrapper (Simon, option B): `tools/zig-out/bin/zbuild <step> [args]` runs `zig build`
  through pipes and, on failure, ends with the roots - failing leaf steps with their commands included (its test:
  the real lint-check failure; end to end: a planted line, and a real one in build.zig, both named). Before that,
  it added little: on a short failure `zig build` already prints the error first, and on the
  costly one (`check` failing on lint, 330 lines) it recognised nothing. That lint message was never hidden, though:
  `zig build` prints it on stdout, and `> log 2>&1` let stderr overwrite it (see claude.md's sandbox quirks).
- `measure` hands the child ONE file for stdout and stderr, so its `/tmp/b.log` can lose stdout the same way.
