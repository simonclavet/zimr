# Aggressive ziggification — active plan

This is the rolling plan for the current sweep.  It supersedes the
historical inventory in `ziggification-candidates.md` (which is
now mostly closed).

## State at session start

- 562/562 host tests passing, 60/60 wasm steps green
- Latest verified-clean snapshot: `zimr-turn3-pixelformat-typed.tar.gz`
- Working tree had unverified Turn 4 partial work in
  `examples/recursive_hud.zig` (allocator + while→for) — still
  passing on re-verify

## Reference material

`/home/claude/raylib-ref/raylib-master/` — raylib master at the time
of the most recent zip upload (May 2026).  Use as ground truth when
in doubt about how raylib does something.  Total ~38 KLOC of C.
Public API surface (`RLAPI`-marked symbols in `raylib.h`): 607.

When I'm uncertain about a behaviour or signature, the workflow is:
`grep -n "FunctionName" raylib-ref/raylib-master/src/*.c` to find
the original implementation, read what it does, then port the
*behaviour* but use Zig idioms.

## Constraints I'm respecting

- 155 raylib-style `KEY_*` / `MOUSE_*` / `GAMEPAD_*` aliases stay
  (typed enum-tag aliases since Cat 5).  They're the project's
  value prop.
- ~269 `c_int` in `rlgl.zig` are GL spec values (`0x0200` etc.).
  Required by WebGL JS shim ABI.
- Public `extern struct` field types (`Image.width: c_int`,
  `Texture.id: c_uint`) — raylib ABI hard requirement.
- The single global state pattern in `rlgl.zig` will not be
  *fully* dismantled this sweep (multi-week refactor); just folded
  into one named struct so it's structurally one global blob.

## What's done so far

- **Aggressive sweep Turn 1:** audit + plan + baseline snapshot
- **Aggressive sweep Turn 2:** sentinel-of-failure cleanup
  (`exportMeshAsObj` → `Allocator.Error![]u8`; glyph getters
  `c_int → u21`; rlgl matrix host-stubs zero → identity)
- **Aggressive sweep Turn 3:** `Image.pixelFormat()` typed
  accessor + mass enum-dispatch refactor across `drawing.zig`
  (~150 sites across 14 callers).  Fixed a latent
  `loadImageColors` bug surfaced by previous test additions.
- **Aggressive sweep Turn 4 partial:** `examples/recursive_hud.zig`
  uses `app.gpa` instead of `std.heap.page_allocator`; nested
  c_int while-loops → for-loops.

## Active turn: 4 (continued)

**Goal:** Fold the four small file-scope rlgl globals into the
existing `RLGL: State` struct.

The targets (`grep -n` confirmed):
- `var rlCullDistanceNear: f64` (line 260)
- `var rlCullDistanceFar: f64` (line 261)
- `pub var defaultBatch_depth: f32` (line 898)
- `var isGpuReady: bool` (line 1171)

Excluded from this turn (load-bearing for rlgl_gpu.zig — moving
them needs accessor functions and a wider refactor):
- `pub var defaultBatch: VertexBuffer` (line 247)
- `pub var draws: [...]DrawCall` (line 248)
- `pub var drawCounter: usize = 1` (line 256)

Verification: `zig build test && zig build smoke-test` after the
fold.  Add a behavioral test for `rlSetClipPlanes` / `rlGetCull*`
since those reads/writes touch the moved globals — no current
test exercises them.

## Next turns (planned)

| Turn | Focus | Snapshot due |
|---|---|---|
| 5 | `SCREEN_W` → `screen_w` in examples; `LOG_*` → `LogLevel` enum | turn4-5 |
| 6 | `c_int` → `i32` in internal helpers | — |
| 7 | Fold runtime.zig globals (TIME/FPS/WINDOW/TRACELOG/STATE) | turn6-7 |
| 8 | Cat 3 finale: text-helper deletions; `[*:0]const u8` → slices | — |
| 9 | Remaining `[*]const T` → slices; close out test gaps | turn8-9 |
| 10 | ziggification-candidates.md final update + snapshot | turn10-final |

## Process notes

- Save `/home/claude/snapshots/zimr-turn{N}-{label}.tar.gz` every
  two turns minimum.
- Append to `notes/CHANGELOG.md` per turn — concrete diff
  description, not just "X changed".
- After every batch of edits: `zig build test --summary all` and
  `zig build smoke-test`.  Both must stay green.
- Style guide rule (mandatory braces, one arg per line, etc.)
  applies to every function that gets touched.
- When in doubt about raylib semantics, **grep raylib-ref
  first**, don't guess.
