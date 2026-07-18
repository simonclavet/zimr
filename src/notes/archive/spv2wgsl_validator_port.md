# Porting miniray's WGSL validator to Zig (the V-arc)

Decision turn 809.  Supersedes `on-porting-miniray.md` (see its banner).
Simon's call: port a real WGSL validator to Zig and plug it at the END
of the spv2wgsl pipeline, so every shader we emit is type-checked on
CPU at build time — catching the `createShaderModule()` class of error
(e.g. the t808 `cannot assign 'u32' to 'f32'`) BEFORE it reaches a
browser.  Long path, all-Zig, no shipped deps, "be sure our code is
perfect."

## >>> STATUS (read this FIRST) <<<
- V0 (scaffolding + lexer) — NOT STARTED.
- The source of truth is miniray-main (Go, CC0 public domain) at
  `/tmp/miniray/miniray-main/` THIS session; it will not persist across
  sandbox resets — re-extract from the uploaded zip
  `miniray-main__1_.zip` if gone.  Per-package Go sources:
  `internal/{lexer,parser,ast,types,validator,diagnostic}`.
- Golden tests to port live in `testdata/validation/{builtins,
  declarations,errors,expressions,types,uniformity}`.

## Why this is the right target (verified t809, not assumed)
- **License CC0** (public domain) — port freely, no attribution/license
  contamination.
- **Zero external Go deps** (`go.mod` has no `require`) — self-contained.
- **The two old blockers are FIXED in v0.3.1** — verified by running the
  published wasm under Bun against our REAL fractal WGSL:
  `continuing` parses, `select` parses (no panic).
- **It has a REAL type checker, not just a parser** — `validateAssignStmt`
  → `types.CanConvertTo` emits the exact `cannot assign 'X' to 'Y'`
  message that bit us at t808.  Full surface: every stmt
  (return/if/switch/loop/while/for/assign/incr-decr/call/decl), every
  expr (literal/ident/binary/unary/call/index/member), type
  construction, address-space rules, entry-point + builtin-for-stage
  checks, uniformity analysis (WGSL §15).
- **No viable alternative in THIS sandbox**: tint-wasm needs
  cmake/gn/ninja/depot_tools (absent); naga is dead (no rust, rustup
  403, naga-wasm npm empty).  A native Zig validator is the only path
  that actually runs here AND matches the "no deps in the wasm" thesis.

## Architecture: validate the EMITTED WGSL TEXT (not the IR)
The validator is tightly coupled to the AST (118 `ast.*` refs in
validator.go).  And the whole point is to check the actual bytes we
hand the browser — which catches EMISSION bugs (bad grammar, dropped
tokens) on top of semantic ones, and is exactly the artifact Chrome
compiles.  So we port the full front-end, not just the checker:

  WGSL text → [lexer] → tokens → [parser] → AST → [types + validator]
            → diagnostics (valid / list of typed, spec-referenced errors)

Plug point: a new pipeline stage AFTER spv2wgsl emits `shader.wgsl`
(the `--strict` gate already exists; add a `--validate` that runs the
in-tree validator and fails the build on errors).  Also expose it as a
standalone `zig build wgsl-validate` over the corpus, and fold into the
per-turn gate so we never again ship WGSL that a real frontend rejects.

## Port size (measured t809, non-comment/non-blank Go lines)
  lexer ~630 · parser ~1528 · ast ~765 · types ~912 · validator ~1626
  · diagnostic ~281  →  ~5,742 lines of Go to port.
This is the bulk of the V-arc.  Zig is more explicit than Go, so expect
a similar-or-larger Zig line count, but the LOGIC ports 1:1 (no GC
tricks, no goroutines, no reflection in the hot path — it's a
straightforward recursive-descent parser + tree-walking checker).

## Phasing (each phase ends GREEN: builds, its golden tests pass, lint 0)
- **V0 — scaffolding + lexer.**  New dir `src/wgsl/` (or
  `src/spv2wgsl/validate/`).  Port `diagnostic` (error codes + a
  Diagnostic struct: code, severity, line, col, message, spec-url) and
  `lexer` (token kinds + scanner).  Golden: a token-stream test over a
  few testdata shaders.  This is the smallest standalone, lowest-risk
  start (mirrors how we bootstrapped the IR arc with ir.zig first).
- **V1 — AST + parser.**  Port `ast` (node structs) then `parser`
  (recursive descent).  Golden: parse every `testdata/*.wgsl` without
  error; parse the `testdata/validation/errors` cases and confirm the
  expected parse errors.  Round-trip against our OWN spv2wgsl output
  (parse all corpus WGSL — must accept 100%, since real Chrome does).
- **V2 — types.**  Port `types` (Type model: scalars, vec/mat, array,
  struct, ptr, atomic; `CanConvertTo`, `IsInteger`, conversion-rank,
  type construction shape rules).  Golden: port `types_test.go`.
- **V3 — validator core.**  Port `validator.go` decl/stmt/expr checks.
  Golden: port `testdata/validation/{declarations,expressions,types,
  builtins}` + `validator_tests`.  MILESTONE: feed it the t808 broken
  WGSL (the `u32->f32` one) and confirm it reports `cannot assign 'u32'
  to 'f32'` at the right line/col — the bug our phone caught, now
  caught in-tree.
- **V4 — uniformity (optional, last).**  Port `uniformity.go` (WGSL §15
  non-uniform control-flow analysis for derivatives/barriers).  Lower
  priority — our shaders rarely hit it — but completes parity.
- **V5 — wire into the pipeline.**  Add the `--validate` stage to
  `tools/spv2wgsl.zig` + a `zig build wgsl-validate` step; run the whole
  corpus through it; fold into the per-turn gate.  THEN it becomes the
  standing oracle that replaces "wait for Simon's phone" for type/grammar
  validity (phone still proves it RENDERS / is visually correct).

## Interim insurance (cheap, while the big port proceeds)
Before V3 lands, add the H1 IR-level type check from
`spv2wgsl_hardening.md` (port of Tint's `CheckOperandsMatchTarget`):
in `ir_emit.emitPhiAssigns`, assert `typeIdOf(args[i]) ==
results[i].type_id`; mismatch → fall back to legacy.  Small, and closes
the EXACT t808 class immediately.  Also audit the sibling routing funcs
(`attachLoopMergePhis`, `attachSwitchMergePhis`) for the same
positional-desync pattern — `attachLoopMergePhis` looked suspicious at
t809 (routes break-edge phi values by `by_id.get(pred)`; need to
confirm a header/break-edge pred lands on the right exit).

## Guard rails for the port
- Port file-by-file, function-by-function, KEEPING the Go structure so
  diffs against upstream stay legible (we may re-sync if miniray fixes
  bugs).  Cite the Go source file+func in a comment at each Zig unit.
- Port the matching golden tests WITH each unit — never port logic
  without its test.  The `testdata/validation/` corpus is the oracle
  for the port's own correctness.
- It must pass our own linter (it's under `src/`, so in lint scope).
- Watch for Go-isms that don't map: slices→`[]const`/ArrayList, maps→
  AutoHashMap, interfaces→tagged unions or vtable structs, string
  formatting→std.fmt, Go's nil→optionals.  The AST is an interface
  hierarchy in Go → a tagged union (`Node`) in Zig (same shape we use
  in ir.zig).
