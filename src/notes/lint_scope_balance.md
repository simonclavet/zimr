# Adding the `scope-balance` lint rule (begin*/end* pairing check)

Goal: a `zimrlint` rule that flags, per function, any `begin{X}` scope-open
without a matching `end{X}` in the same function. Catches "forgot end" (e.g. an
`update()` that opens `beginDrawing` but never `endDrawing` — the helmet_sw class),
statically, regardless of whether the example uses `defer` or a manual `end()`.

## zimrlint.zig framework facts (verified this session)

- **Rules** are `fn runX(ctx: Ctx) !void` functions, registered by adding
  `try runX(ctx);` inside `fn runChecks(ctx)` (~line 3674–3692; `runChecks` is
  called at ~4191). Model on `runDeclOrder` / `runUnusedPrivateGlobals`.
- **AST**: `const Ast = std.zig.Ast; const Index = Ast.Node.Index;`.
- **fn_decl**: iterate `0..ast.nodes.len`; `ast.nodeTag(node) == .fn_decl`.
  `var buf: [1]Index = undefined; ast.fullFnProto(&buf, node)` → `Ast.full.FnProto`
  with `.name_token` (optional u32).
- **Call nodes**: tags `.call, .call_comma` → fn_expr = `ast.nodeData(node).node_and_extra[0]`;
  `.call_one, .call_one_comma` → fn_expr = `ast.nodeData(node).node_and_opt_node[0]`.
- **Callee name**: if `ast.nodeTag(fn_expr) == .field_access` → name token =
  `ast.nodeData(fn_expr).node_and_token[1]` (the LAST field, e.g. `beginDrawing`
  in `z.beginDrawing` or `f.ui.beginChild`); if `.identifier` →
  `ast.nodeMainToken(fn_expr)`. Then `ast.tokenSlice(tok)`.
- **Token positions**: `ast.firstToken(node)`, `ast.lastToken(node)`,
  `ast.nodeMainToken(node)` — all return u32 token indices.
- **Emit**: `try ctx.emitAt(tok, "scope-balance", 0, "msg {s}", .{args});`
  — ARG ORDER is `(token, tag_string, rule_number, fmt, args)`. Use `0` for the
  rule number (bonus check). There is also an optional RuleDoc `.tag=` struct
  (title/body, ~lines 486–728) for the `--explain` text; add one for
  `scope-balance` if desired, but it's not required to emit.
- **Allocator**: `ctx.alloc`. `std.ArrayListUnmanaged(T){}` + `.append(alloc, x)`
  + `.deinit(alloc)`. For a per-fn 2D count buffer: `try alloc.alloc([G][2]u32, n)`
  then `@memset`.
- **DO NOT use `childNodes()` for the body walk** — it's best-effort and does NOT
  descend into blocks/statements (only expression wrappers + call args), so it
  would miss the calls inside a function body. Use the **token-range approach**
  instead (below).
- **CRITICAL BUILD NOTE**: this dev Zig miscompiles `zimrlint` under
  `ReleaseFast` → SIGILL on every input. build.zig now compiles it `.ReleaseSafe`
  (fixed). To test the rule standalone:
  `tools/zig-.../zig build-exe tools/zimrlint.zig -O ReleaseSafe -femit-bin=/tmp/lint_safe`
  then `/tmp/lint_safe <file.zig>`. (The cached `.zig-cache/o/*/zimrlint` may be
  a stale ReleaseFast crasher — don't trust it; build fresh ReleaseSafe.)

## Algorithm (token-range, avoids the childNodes gap)

1. Pass 1: iterate all nodes; for each `.fn_decl`, record
   `{ start = ast.firstToken(node), end = ast.lastToken(node), name_tok }`.
2. Pass 2: iterate all nodes; for each call node, get callee name; if it matches
   a group's begin or end, find the **innermost** fn whose `[start,end]` token
   range contains the call's `nodeMainToken` (smallest span wins — handles nested
   fns), and increment `counts[fi][group][begin?0:1]`.
3. Pass 3: for each fn × group, if `begins != ends`, emit at the fn's `name_tok`:
   e.g. `"scope 'Mode3D' unbalanced in this fn: {d} begins, {d} ends (each begin{s} needs a matching end{s})"`.

Per-function COUNT balance is correct for both patterns:
`beginDrawing(); ...; endDrawing();` = 1+1, and the imgui form
`if (u.beginChild(...)) { defer u.endChild(); ... }` = 1+1. A forgotten end = N≠M.

## Curated scope groups (begins → ends; handles irregular multi-begin)

Render/frame (the ones that bit us — do these first):
- Drawing: [beginDrawing] → [endDrawing]
- Mode2D: [beginMode2D] → [endMode2D]
- Mode3D: [beginMode3D, beginMode3DMatrix] → [endMode3D]   (irregular: shared end)
- TextureMode: [beginTextureMode] → [endTextureMode]
- TextureModeRaw: [beginTextureModeRaw] → [endTextureModeRaw]
- ScissorMode: [beginScissorMode] → [endScissorMode]

UI / imgui (add after the render ones verify clean):
- Child, Canvas, Disabled, TabBar, TabItem, Table, Combo, ListBox, MenuBar,
  MainMenuBar, Menu, Group, DragDropSource, DragDropTarget, Plot, Subplots,
  MultiSelect — each `begin{Name}` → `end{Name}`.
- Popup: [beginPopup, beginPopupModal, beginPopupContextItem] → [endPopup]
- Tooltip variants are UNCERTAIN (beginItemTooltip vs endTooltip/endItemTooltip)
  — leave OUT until confirmed against actual usage, to avoid false positives.

## Rollout (small turns)

1. Turn A: add `runScopeBalance` with ONLY the render/frame groups + register it;
   build fresh ReleaseSafe lint; run `/tmp/lint_safe` over `examples/` + `src/` and
   confirm ZERO false positives (any hit = a real bug OR a wrong pairing — fix the
   bug or drop the pair). Then TEST it catches an intentional imbalance (temporarily
   delete an `endDrawing` in a scratch file and confirm it flags).
2. Turn B: add the UI groups; re-run for false positives; drop any group the
   codebase proves has a different pairing.
3. Turn C: wire it into the real build gate (it's already in `runChecks`, so once
   the build's lint step runs it's live — just confirm a full `zig build` passes).

## Related work in flight (context)

- #2 (consolidate `frame_phase` into `enterFrame2D`/`leaveFrame2D`) is DONE.
- #3 (smoke assert-gate: fail a headless `wgpu_smoke` run on any `assert failed`
  log line + add RTT/3D examples to the focus set; needs the Zig harness AND its
  TS mirror in `webtests/`) is still TODO.
- RTT frame-lifecycle migration: 10 of 26 examples done (see claude.md). `defer`
  is left to each example's discretion; this lint keeps either style honest.
