> **SUPERSEDED (turn 809).**  This note recommended AGAINST porting
> miniray, on two grounds that NO LONGER HOLD for the current version
> (miniray v0.3.1) and the current sandbox:
>   1. "miniray's parser fails on `continuing`" — FALSE for v0.3.1.
>      Verified t809: the published wasm parses our real fractal WGSL
>      (which contains `continuing`) AND a minimal `continuing` block
>      with no error.
>   2. "miniray panics on `select`" — FALSE for v0.3.1.  Verified t809:
>      parses `select(...)` and our 4-`select` fractal cleanly.
>   3. "miniray only validates syntax" — FALSE.  Its `validateAssignStmt`
>      emits literally `cannot assign '%s' to '%s'` — the EXACT error
>      Simon's phone showed for our t808 bug.  It has a real type
>      checker (checkExpr / CanConvertTo / type-construction rules).
> ALSO: the note's preferred alternative (wire `tint-wasm`) is NOT
> viable in THIS sandbox — no cmake/gn/ninja/emscripten, Dawn needs
> depot_tools.  And naga is dead (no rust, rustup 403, naga-wasm npm
> has zero usable versions).
> Simon has chosen the long path explicitly ("use zig, go the long
> way, we have all year, be sure our code is perfect").
> The live decision + plan is in `spv2wgsl_validator_port.md`.
> Original reasoning preserved below for the record.

---

# On porting miniray to Zig

The user asked: should we port miniray to Zig and plug it into the end
of our SPIR-V → WGSL translator as a built-in validator?

Honest answer: **no, but here's a better path that gets the same value**.

## Why not miniray

**Miniray itself is buggy.**  We've confirmed two real bugs running
against our corpus:

1. **`continuing {` parser failure** — miniray's WGSL parser doesn't
   recognize the `continuing` block syntax that's part of the WGSL
   spec.  Reports `expected expression` / `expected ;, got {`.  Real
   Chrome accepts the syntax (we verified this with the working demo).

2. **`select(...)` panics** — miniray's runtime crashes with a nil
   pointer dereference on shaders that use the `select` builtin.  We
   have 12+ shaders in our corpus that trigger this.

Porting buggy code to Zig produces buggy Zig code.  The energy is
better spent elsewhere.

**Miniray only validates syntax.**  Real WGSL validation includes:

- Type compatibility (vec3 + vec2, mat × scalar shape rules)
- Binding layout matching against the pipeline's bind group
- Vertex attribute format compatibility
- Storage class permissions
- Builtin parameter validation
- Address space + access mode rules
- Resource handle aliasing
- Control flow termination (the exact bug we just fixed)

Miniray catches lexer + parser errors only.  Chrome catches everything.
If our goal is "what runs in Chrome works in our translator", miniray
is a weak proxy.

**Porting cost vs. value.**  Miniray is ~2-3k lines of Go runtime +
parser.  At a careful pace, that's 1-2 weeks of work.  The resulting
Zig validator would catch fewer bugs than Chrome and have the same
known parser limitations.

## What I'd do instead

We already have `tint-wasm-main.zip` in the project — Tint as a
compiled wasm static library with a C++ entry point in
`tint_wasm.cpp`.  Tint IS the reference WGSL implementation.  It's
what Chrome itself uses (Dawn = Chrome's WebGPU implementation =
Tint as its WGSL frontend).

Wiring `tint-wasm` into the build as our validator is straightforward:

1. Use the existing static library + `tint_wasm.cpp` shim
2. Build a small C++ wrapper that exposes "parse this WGSL string,
   return errors if any" as a single function
3. Compile to wasm (Emscripten or similar)
4. Call it from `build.zig` after spv2wgsl emits a shader — same
   shell-out pattern we already use for miniray

This is maybe a day of work, and gives us:
- The exact same validator Chrome uses internally
- Full coverage (types, bindings, control flow, everything)
- Zero ongoing maintenance — Tint is maintained upstream by Google

The shell-out is the same shape miniray uses.  We get the value of
"validator at the end of the translator" without writing or maintaining
the validator ourselves.

## What if we want a zig-native validator?

If the goal is specifically "no external binary dependencies, all
Zig, in-tree", then the better path is to write a **small targeted
validator from scratch** that catches the things we actually care
about for our shader corpus:

- Block structure balance (open/close braces)
- Statement-level syntax (terminators, keyword grammar)
- Loop exit provability (the bug we just fixed)
- Phi-var assignment hygiene
- Bind group layout matching our shader_introspect output

This would be ~500-1000 lines of Zig, written specifically against
the patterns spv2wgsl emits.  No external code porting, no inherited
bugs.  It would be incomplete (Chrome would catch more), but it
would catch ALL the bug classes we've actually seen in spv2wgsl
output to date.

I'd estimate 2-3 days for the first useful version.  Each new bug
class we discover in spv2wgsl output would prompt adding a check.

## Recommendation

In order of value-per-day:

1. **Validate that mandelbrot works in Chrome with the fix that just
   landed.**  If yes, the urgency on any validator goes way down —
   the system is working.  Cost: 1 minute.

2. **Wire tint-wasm into the build** as the runtime validator.
   Quick, comprehensive, zero maintenance.  Cost: ~1 day.

3. If we still want a Zig-native validator after that, **write one
   from scratch** targeted at our output shape.  Don't port miniray.
   Cost: ~2-3 days for a useful first version.

The miniray port is a non-starter for me — it would consume 1-2 weeks
to produce a tool weaker than what we'd get in 1 day from tint-wasm.

## What the user actually wants

Re-reading the request: "port miniray to zig, so we have a good wgsl
validator written in zig as part of our translator".

The underlying want is "good wgsl validator written in zig as part of
our translator".  Miniray is the suggested implementation path; it's
not the goal.

Option 3 above (write a focused validator from scratch in Zig) hits
the underlying want without the porting penalty.  I'd lean toward
doing option 1, then option 2, then evaluating whether option 3 is
still worth doing — by that point we'll have a much clearer picture
of what bugs the existing tooling misses.
