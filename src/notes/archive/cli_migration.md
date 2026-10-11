# cli_migration.md - every tool's command line through std's cli (Simon, Sep 27)

## FINISHED (Sep 28)

Every tool zimr supports reads its command line through std's cli (the front door `src/command_line.zig`, which
also names the argument a bad line got wrong). The last pass converted the eight that read none at all -
dag_png, doc_sync, docfmt, files_html, gen_files_md, render_server (which gained `--port`, like signal_server),
zimrnum_parity, zimrnum_ref - so each now has `--help` and refuses an argument it used to ignore; their outputs
were compared with the ones captured before (11 of 12 styled pages identical - the 12th's source changed; the
parity report identical; the atlas differs only by line counts).

Deliberate exceptions, each for a reason a struct cannot get around:
- `zbuild` and `measure` forward someone else's command line (`zig build`'s, any command's) - no declared struct
  can describe it, like `env` or `time`.
- the per-shader bootstrap `src/shader_codegen.zig` generates: called only by the build, in two fixed shapes,
  compiled once per shader - a module there would cost every shader's compile for nobody's benefit.
- `physics_audit`, `plot_svg_demo`: kept but unsupported (Simon, Sep 28) - untouched.

Found on the way, beyond command lines: two stale tutorials (the mocap one's `Replay` fold - now checked in `check`;
the zimrnum reference table, missing the scratch allocator's two functions), a dead `-Dwalker` chain, the
cheatsheet's frozen twin, a hand-restyled page its generator kept undoing, and `dag_png` OOM-killed at ~3.85 GB in
a 4 GB sandbox in either mode (open, in tools_audit.md).

std's command-line parser, Zig PR 36930 ("std: introduce cli module"), is vendored in `src/cli.zig` + `src/cli/`
(verbatim but for the imports; lint-exempt; its 12 tests run as `zn-cli` in `test-fast`) behind zimr's front door
`src/command_line.zig`, the build module `cli`. A tool declares its command line as a struct and calls
`cli.args(&init, Args, config)`: typed values, `--help` (exit 0) and usage errors (exit 1) for free. When std merges
the PR: `cli.args(&init, ...)` -> `init.args(...)`, `cli.Config` -> `std.cli.Config`, and the vendored files go.

Each conversion's known answer: the tool does exactly what it did - the same outputs from the same inputs, every
`build.zig` call site unchanged (a build-invoked tool's argv is an interface) - and `--help` lists what it takes.

## Status (24 tools hand-rolled their argv loop on Sep 27)

DONE: `src/robot_st_bench.zig` (22 options; the old parser's CSV and the new one's agree, configuration included).

DONE, batch 1a (Sep 28) - each through its own build step, the interface unchanged:
- `urdf_import`: `zig build urdf-import` regenerates `kuka_iiwa.zig` byte-identical to the committed fixture.
- `example_source`: its JSON byte-identical to the OLD source's on the same arguments (run in place, 7 533 bytes);
  `example-sources` wrote all 314 gallery files; an odd file list still exits 2.
- `bvh_trim`: `zig build bvh-trim -- walk1 out 10 50 Thumb` -> 50 frames, every Thumb joint dropped.
- `verify_imports` (inside the smoke: PASS), `doc_gate` (13 pages), `dag_check` (green).
A bad command line now exits 1 with the generated usage (std's cli) where a tool had its own code (2) - no call
site passes one.

DONE, batch 1b (Sep 28):
- `mesh_bake`: the OLD source and the new, compiled by hand with the same modules, write byte-identical proxies on
  the build's own arguments (bunny.obj at grid 10: 45 659 bytes; grid 14: 93 203); grid 99 still refused; a
  non-number grid is now refused by the parser, with the usage.
- `spv2wgsl_check`: inside `check`, the same verdict as the old tool's run - 57 ok, 0 failed.
- `lafan_db`: `zig build lafan-db -- --help` prints the generated usage; a missing database fails at the file read
  (Holden's `database.bin` is not in the sandbox, so the conversion itself could not be rerun).

DONE, batch 1c (Sep 28) - five tools nothing built, now steps (`zig build <name> -- <args>`, forwarded by
`addPassthruArgs`, run from the repository root): `decl-deps`, `rename-local`, `rename-pub-fn`, `zm-namedimports`,
`zbuild`. All five still compiled unconverted on 2307, so each OLD binary was the known answer, on identical inputs:
rename_local / rename_pub_fn / zm_namedimports rewrite byte-identically (scoping kept: the other function's `count`
untouched); decl_deps prints the same 10 declarations for measure.zig; zbuild distills the saved failing log the
same, and reads stdin when given nothing. Two PRE-EXISTING leaks the first build in a long while exposed, fixed:
decl_deps took `init.gpa` and freed 2 of 8 allocations (12 reports at every exit) - now the process arena;
zm_namedimports duped the import block into an edit that nothing freed - the edit now points at the block, which
lives past the edits' application. Each needs a build step first - `run.addPassthruArgs()` forwards
`zig build <step> -- <args>` - and may have rotted against 2307, since nothing compiles them.

DONE, batch 2 so far: `cheatsheet` (rewritten - positionals `src` and `output`, the build passes both). `doc_folds`: `--fix`, with `--check` as its CLEAR (the PR's reset-to-default option: one switch, the last
written wins, `--help` shows the pair); on a drifted copy `--check` fails, `--fix --check` checks, `--fix` restores
it byte for byte. Converting it found a REAL stale fold (the mocap tutorial still quoted `Replay` from before
`episode_steps`): the fold check ran only in `gate`, so it is now in `check` too - read-only, always run - and a
planted stale fold turns `check` red (`zbuild` names doc_folds).

DONE (Sep 28): `serve` - a bad port (`--port 80a`) and a misspelt option (`--prot`) are refused with the usage
where the hand parser served on 8080 without a word; `--open`, which nothing passed and which swallowed the next
argument, is gone. `gen_vscode` is `gen_editor_configs` (step `editor-configs`, `generate_editor_configs.bat`):
the name says what it always did - VS Code AND Zed - and its four files come out byte-identical; no arguments, but
the parser gives it `--help` and refuses a stray one.

DONE (Sep 28): `buildaux`. std's cli has no subcommands, so the command is the first positional, an ENUM whose
tags are the commands as typed (`@"dist-copy"`) - a misspelt one is refused, and `--help` lists the three by
itself - with the one argument two of them take as a second, optional positional that each command checks
(`usageError`: say which, print the generated usage, exit 1 - the parser's convention). Known answers against the
old binary: identical exit codes from check-wgsl-clean (clean / dirty / empty), identical prebuilt/ trees from
dist-copy (docs/ skipped, .nojekyll written), and the same published tree hash from publish-pages into a local
bare remote (main untouched).

DONE (Sep 28): `spv2wgsl` - batch 2 is COMPLETE. Options in any order now (the hand parser took `--check` /
`--strict` only first); `--check` with an output, or a translation without one, is a usage error (exit 1, the
parser's code; it was 2). Its `--walker=` flag went, and with it the whole dead chain behind it: the `-Dwalker`
build option chose between two CFG walkers after F5 had deleted one - it selected nothing, and its help promised
a fallback that did not exist - plus `ShaderPipeline.wgsl_walker` and both `addArg`s in shader_codegen.zig. Known
answer, old binary vs new (both ReleaseSafe, as the build ships it) over all 247 SPIR-V modules in the tree and
cache: strict, plain and --check runs all identical (exit code and bytes), and every entry of every multi-kernel
module (80 runs) identical; `check`'s transpiler corpus still 57 ok, 0 failed.

DONE (Sep 28): `c2js` (batch 3, first). It already refused unknown flags; what the parser adds: a value option
with no value (`--title` last on the line built an untitled page, exit 0) is a usage error, and the usage can no
longer fall behind - the hand text had lost `--fullscreen-landscape`, `--kernel-wasm-embed` and
`--worker-js-embed`. main keeps its local names (bound from the parsed struct), so its 400 lines after parsing
are untouched. Known answer, old vs new ReleaseSafe, every shape the build uses plus the options it does not
(`--min`, `--safe`, a basename + its .js.map): plain filter on 4 real C inputs, the phase-1 and bridge pages, the
gallery's streamed and standalone pages without kernels AND with a real kernel wasm (worker_png's, built by the
build for the test) - identical bytes and exit codes everywhere (up to 3.7 MB). A first pass printed "same" for
runs where both binaries were missing (exit 127, 0 bytes): the comparison reports exit code and size so that
cannot pass for agreement.

DONE (Sep 28): `zimrlint`. Parsed with `cli.parse`, not `cli.args`: the front door exits 1 on a bad command line,
and for zimrlint 1 means FINDINGS - a bad command line stays 2, `--help` 0. `--enable` is an accumulating option
(repeatable), each list still checked by `enableRules` (its "not a rule" / "always on" messages kept word for
word); `--cache-dir` defaults to the stamp directory in the cli struct, so `--help` shows it; a bare `--baseline`,
which silently ran with no baseline, is refused. `addLint` (the linter for projects that depend on zimr) now gives
it the `cli` module from the dependency. Known answer, old vs new ReleaseSafe with fresh stamp dirs each: the whole
tree as check lints it (718 files), without the baseline, `--decl-order-only` (1144 lines of findings), `--fix
--dry-run`, `--list-rules`, a planted violation (34 lines), `--write-baseline` - identical output and exit codes;
the external project's `zig build lint` (the consumer path) builds and passes. The comparison caught a 121-column
line in the new config: both binaries reported it identically.

FOUND, for every converted tool: `cli.parse` returns a bare `IncorrectUsage`, and the front door prints only the
usage - `serve --prot 8081` no longer says WHICH argument was wrong (most hand parsers did). The fix belongs in
the front door (`src/command_line.zig`), not the vendored parser: before the usage, name the first argument that
matches no field. DONE (Sep 28): `cli.args` tries `cli.parse` itself and, on IncorrectUsage, prints `<binary>:
<why>` - then std's own `Init.args` (vendored, untouched) prints the usage and exits as always. `misfit` walks the
line by the parser's rules and speaks only when sure: unknown option (with a `--help` hint for `-h`), a value
missing / refused (an enum lists its choices) / given to a flag, an extra or missing positional; a short-option
cluster in a tool that declares shorts gets silence. Its tests pair each message with the PARSER's refusal of the
same line, plus one line using every accepted form that must get silence - the explanation cannot drift from the
parser unseen. zimrlint (on `cli.parse` for its exit codes) prints it too.

Batch 3 - left: `shader_codegen` (the build.zig interface - careful).

Batch 3 - many flags, invoked by `build.zig` (their argv is an interface: every call site must keep working):
`c2js` (11), `zimrlint` (10), `shader_codegen` (18).

Special: `measure <label> <command...>` forwards the rest of its argv as a command, whose own `-j1` or `-Dx` the
parser would read as options - it needs the tokenizer's `--` (everything after is positional), which changes how
it is called. Decide with Simon before converting.
