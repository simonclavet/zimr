# decl-order plan - get the rule passing on zimr, then gate it

Status: **PLANNED, not started** (Sep 27). Nothing below is implemented yet.

`decl-order` flags a file-scope `fn`/`const`/`var` used above its declaration. It is an
opt-in zimrlint rule (`--enable=decl-order`) and the one opt-in rule zimr does NOT enable
(`zimr_lint_rules` in build.zig). The goal is to enable it.

## 1. Where it stands (measured Sep 27)

- **1121 violations in 148 files.** The rule reports ONE issue per decl, at its earliest
  forward use - so this is "names used before declared", not references.
- An earlier sweep got it to 50 (all in ui.zig). It regressed because nothing gated it, and
  because the per-file lint stamps did not hash the enabled rules, so every `--decl-order`
  run after the sweep skipped stamped-clean files and printed nothing (fixed Sep 26: stamps
  now hash the enabled set).
- Container-level decl order has no semantic effect in Zig, so the repair is almost
  entirely a mechanical reorder. What a reorder cannot fix is a genuine cycle: at least one
  decl per cycle keeps a forward reference and needs a `// lint:off decl-order: <why>`.

## 2. What the simulation found

Method: ran `tools/decl_deps.zig` + `tools/decl_reorder.py` on scratch copies of all 148
files, re-linted with `--decl-order-only`, `zig ast-check`ed the output, and counted the
lines that must physically move (total block lines minus the heaviest subsequence of blocks
that keeps its original order - `git diff --numstat` inflates this ~2x).

- **Reordering almost solves it.** Break each cycle at a greedy feedback set, order the rest
  dependency-first: 1121 -> **25 required `lint:off`s tree-wide** (22 exist today, several
  on the same cycles).
- **Strategy decides the churn:**
  - `topo` (decl_reorder.py: Kahn over the SCC condensation, smallest original index first)
    moves **50.8k** lines;
  - `hoist` (move each forward-referenced decl to just above its first user; big users stay
    put, small helpers move) moves **38.0k** - and far less in some files: codecs.zig
    1315 -> 42, zimrphysics.zig 812 -> 12, text2d.zig 1256 -> 127, wgpu_app.zig 1595 -> 212;
  - best of the two per file: **38.5k**.
- **136 of 148 files need <=500 lines moved** (10.1k lines total). The churn is in 12 files:

| file | lines moved | lint:off needed |
|---|---|---|
| src/ui.zig | 10,398 / 43k | 3 (`UiContext`, `Ui`, `editFieldDispatch`) |
| src/zimrnum.zig | 6,186 | 1 (`divideBy`) |
| src/robot.zig | 3,784 | 0 |
| build.zig | 1,872 | 1 (`App`) |
| examples/geno_dance/geno_dance.zig | 1,355 | 0 |
| src/bridge.zig | 1,033 | 4 (`Element`, `Value`, `g`, `tupleToH`) |
| zimrphysics2d, mjcf, zimrphysics2d_demo/scenes, zimrmath, shader_runtime_wgpu, robot_mjcf | 500-820 each | 1 (`computeCosSin2` in zimrmath) |

- **ui.zig's 177-decl cycle is two types.** `UiContext` is referenced by 171 of its members:
  free functions take `*UiContext`, and its methods call those functions. Breaking it takes
  3 suppressions, not the 34 `topo` leaves (topo keeps a cycle's members in original order).
  The cheap break puts the TYPE after the functions that take it.
- **The existing tools have bugs that would break code:**
  - `decl_deps.zig` ends a decl whose value is a multiline string (`\\...`) at the last
    string line, leaving the `;` behind; the `;` then travels with the NEXT decl and the file
    no longer parses (docfmt.zig, files_html.zig "passed" as broken code).
  - `decl_reorder.py` reads/writes in the platform text encoding: crashed on codecs.zig
    (cp1252 decode) and would write CRLF on Windows. (And claude.md says no Python.)
  - Leading comments ride with the NEXT decl, so the `//!` file header and section banners
    (`// ===== X =====`) would move with whatever decl follows them.

## 3. The plan

**Phase 0 - decisions** (section 4).

**Phase 1 - a reorder tool that can be trusted.** A `zimrlint --reorder-decls <file>` mode
(the lint plan keeps everything in zimrlint.zig), replacing decl_deps.zig + decl_reorder.py.
- Blocks from the AST, including the terminating `;`. A block = the decl plus attached
  `///` and `//` lines with no blank line between. The `//!` header is pinned to the top;
  blank-line-separated comment paragraphs (banners) stay in place.
- Per file: break cycles at a greedy feedback set, try hoist and topo, keep the one that
  moves fewer lines.
- Insert a leading `// lint:off decl-order: cycle with <names>` at each remaining forward use.
- Guards: the multiset of lines is unchanged (only order moves), the result passes AstGen
  (`compilesClean`), plus the existing parse guard. Fires/clean tests in the zimrlint harness
  (multiline-string decl, pinned header, banner, a 2-cycle).

**Phase 2 - stop the bleeding.** Add `.decl_order` to `zimr_lint_rules` together with a
`tools/lint_baseline.tsv` holding today's per-file counts (the existing ratchet): any NEW
violation fails immediately, the backlog shrinks file by file.

**Phase 3 - the 136 small files**, batched (examples/, tools/, small src/), one moves-only
commit per batch. Per batch: `zig fmt --check`, lint with every rule, `test-fast` /
`zn-<stem>` for src modules, smoke for examples; delete the batch's baseline rows.

**Phase 4 - the big files, one commit each**, when no other session is editing them. A
reorder conflicts with any concurrent edit of the same file: never hand-merge one - discard
it, merge the other work, re-run the tool (deterministic, seconds). Order: robot.zig (0
lint:off), zimrnum.zig, geno_dance, zimrphysics2d, mjcf, zimrmath, bridge, build.zig last.

**Phase 5 - ui.zig** per decision 1.

**Phase 6 - cleanup.** Empty the baseline; delete decl_deps.zig and decl_reorder.py; drop
`decl-order` suppressions that no longer suppress anything; update claude.md's decl-order
bullet; list every reorder commit in `.git-blame-ignore-revs` so blame skips the moves.

## 4. Decisions (open)

1. **ui.zig.** Simon's standing decision is FEATURE order. Passing means either ~10.4k lines
   moved (with `UiContext` placed after the functions that take it), or a file-level
   `//! lint:off decl-order: feature order` exemption. Recommendation: the exemption - one
   honest line against 10k lines of churn and an arguably worse reading order.
2. **build.zig.** `pub fn build` would move to the bottom, below its helpers. Accept, or
   exempt build.zig too?
3. **The Phase 2 baseline.** claude.md: a non-empty baseline means a backlog accepted on
   purpose. This would be exactly that, for the length of the migration.

## 5. Risks

- Test order: `topo` may move `test` blocks, changing run order - matters only if tests share
  mutable state (module-var should prevent that). `hoist` never moves tests.
- The greedy feedback set is an upper bound on the minimum; the choice of WHICH decl stays
  forward-referenced is a readability call (type before or after its functions) - review
  each of the 25.
- Churn in actively-developed files (zimrnum, build.zig): schedule, don't race.
