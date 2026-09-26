//! lint:off std-math: c2js is a standalone host-only transpiler - Zig-emitted C in,
//! JavaScript out. It never reaches a shader, so the GPU-portability reason for the
//! std.math ban does not apply, and it should stay extractable from zimr without
//! dragging zimrmath along for a single NaN constant.
//! c_to_js.zig — a single-file C -> JavaScript transpiler, written in Zig.
//!
//! ===========================================================================
//! BIG PICTURE
//! ===========================================================================
//!
//! This program turns C into JavaScript. It exists to be the last stage of a
//! larger toolchain:
//!
//!     your.zig  --(zig build-obj -ofmt=c)-->  your.c  --(this tool)-->  your.js
//!
//! Zig's own C backend emits the middle artifact; this tool finishes the job.
//! The intended use is to author browser code (a game's host/bridge, or an
//! entire program) in Zig and run it as JavaScript without hand-writing any JS,
//! either instead of or alongside a wasm build of the same Zig.
//!
//! It is NOT a general C compiler. It targets exactly the dialect Zig's C
//! backend produces: a heavily-lowered, SSA-like C with a known, narrow shape
//! (see "INPUT DIALECT" below). Fed arbitrary hand-written C, it will mis-parse
//! or silently emit wrong output. Fed Zig-C-backend output, it is faithful.
//!
//! The generated JavaScript is intentionally unreadable: temporaries keep their
//! C names (t0, t1, ...), control flow is a state machine, and memory is a typed
//! array. Readability of the output is a non-goal — it is meant to be run, and
//! debugged via a JS->C source map (emitted on request; see "SOURCE MAPS").
//!
//! I/O contract:
//!   * Reads C from stdin, writes JS to stdout.
//!   * `c_to_js            < in.c > out.js`     plain filter, no map.
//!   * `c_to_js <basename> < in.c > out.js`     also writes "<basename>.js.map"
//!                                              and appends a sourceMappingURL.
//!   * Uses std.Io (File/Dir via init.io) for all I/O, so it builds and runs on
//!     Linux and Windows alike. main takes `std.process.Init` (Zig master).
//!   * All allocation is from one ArenaAllocator freed at exit: the transpiler
//!     never frees individually and never needs to.
//!
//! ===========================================================================
//! THE FOUR-STAGE PIPELINE (top to bottom in this file)
//! ===========================================================================
//!
//!   preprocess  ->  lex  ->  parse (recursive descent)  ->  lower + emit
//!
//! (1) PREPROCESS (`preprocess`)
//!     The C-backend output contains only object-like `#define`s (for renaming
//!     mangled symbols to friendly names) and one `#include`. We do NOT run a
//!     real C preprocessor. We:
//!       - capture single-token object-like `#define NAME REPL` into a map
//!         (function-like macros, i.e. `NAME(...)`, are ignored), and
//!       - delete every `#`-directive line (replacing it with a blank line so
//!         source-line numbers are preserved for the source map).
//!     The captured defines are applied later as identifier renames
//!     (`applyDefine`): a mangled function symbol like `zimr_run__384` carries a
//!     `#define zimr_run__384 zimr_run`, so call sites can use the friendly name.
//!     GLOBALS get no such define and are referred to by their mangled name.
//!
//! (2) LEX (`Lexer`)
//!     A hand-written tokenizer producing `Token{ kind, text, line }`. Token
//!     kinds: ident, number, str, punct, eof. Notable rules:
//!       - Punctuators are longest-match from a fixed table (so `<<=` beats `<<`
//!         beats `<`).
//!       - Numbers consume digits, hex (0x...), '.', identifier-chars (suffixes
//!         like u/U/l/L and hex letters), AND a sign immediately following an
//!         exponent marker e/E/p/P (so `1.0e-14` and `0x1p+3` stay one token).
//!       - String/char literal bodies are captured WITHOUT surrounding quotes,
//!         with escapes left raw for `decodeCString` to interpret later.
//!       - `line` is the 1-based line in the PREPROCESSED C (computed in the
//!         tokenize loop in main by counting newlines up to each token's start).
//!         It is the sole input to the source map.
//!
//! (3) PARSE (`Transpiler`, recursive descent over the token slice)
//!     There is no separate AST type for the whole program; parsing is
//!     interleaved with code generation. The unit of work is the function. For
//!     each function the parser builds a small statement tree (`Stmt`) for the
//!     body, then that tree is lowered (stage 4). Expressions are NOT kept as a
//!     tree: they are translated directly to JavaScript strings during parsing
//!     by a precedence-climbing expression parser. So "parsing an expression"
//!     and "emitting that expression's JS" are the same step, and most of the
//!     translation logic lives in the expression layer.
//!
//!     Two prepasses run once over ALL tokens before any function is emitted:
//!       - `prescanData`: finds initialized string-literal statics
//!         (`name = { "..." }`) and lays their decoded bytes into the data
//!         image; records name -> heap offset in `globals`.
//!       - `prescanScalarGlobals`: finds `static <scalar> name = <init>;` and
//!         fixed-array globals (the `arr_..._...` wrapper structs) and gives each
//!         a heap slot (scalars seeded little-endian with the parsed initial
//!         value; arrays zeroed). Also recorded in `globals`.
//!     Struct/union definitions encountered at top level are parsed by
//!     `parseStructDef` into `structs` (tag -> {size, fields[]}); each field has
//!     a byte offset and scalar type. Everything else at top level that isn't a
//!     function definition (typedefs, prototypes, dead `builtin_*` data, etc.)
//!     is skipped tolerantly (`skipDecl` / brace-matching in `parseTopLevel`).
//!
//! (4) LOWER + EMIT
//!     a. CONTROL-FLOW LOWERING (`flatten`): the `Stmt` tree is flattened into a
//!        linear list of `FlowOp` (line | ret | label | goto | cgoto). if/while/for/
//!        switch/break/continue are all rewritten into conditional gotos against
//!        fresh labels. break/continue resolve against `brk_stack`/`cont_stack`.
//!        This is what lets us accept the C backend's own goto-heavy output AND
//!        normalize our own structured statements into the same currency.
//!     b. CODEGEN (`emitBody`): if a function's op list has no labels/gotos, it
//!        is emitted as straight-line statements. Otherwise it is emitted as a
//!        TRAMPOLINE: ops are split into basic blocks at labels, and the body
//!        becomes `let __s = 0; __loop: while (true) { switch (__s) { case i: ...
//!        __s = j; break; ... default: break __loop; } }`. Every goto becomes
//!        "__s = <block index>; break;"; every cgoto becomes a guarded version;
//!        fallthrough between adjacent blocks is inserted explicitly. This single
//!        mechanism expresses arbitrary gotos, loops, and switches uniformly.
//!
//! ===========================================================================
//! INPUT DIALECT — the exact C shapes this tool recognizes
//! ===========================================================================
//! Everything below is what Zig's C backend actually emits; the parser keys off
//! these shapes. If a shape changes upstream, the corresponding handler must.
//!
//!   * Functions: friendly name via `#define mangled friendly`; SSA temporaries
//!     `t0..tN` declared at the top of the body; one statement per line.
//!   * Integer wrapping arithmetic via helpers, NOT raw operators:
//!         a +% b   -> zig_addw_u32(a, b, 32)     (also subw/mulw, i-variants)
//!         mul      -> ...mulw...: Math.imul for <=32-bit; BigInt * for 64/128-bit
//!         x << n   -> zig_shlw_u32(x, n, 32)      (32-bit: <<; 64/128-bit: BigInt <<)
//!         x >> n   -> zig_shr_u32(x, n)           (32-bit: >>>/>>; 64/128-bit: BigInt >>)
//!         mask/ext -> zig_wrap_u32(x, bits) / zig_wrap_i32(x, bits)
//!     Plain `/` and `%` are emitted directly (and mapped directly).
//!   * Float arithmetic also via helpers: zig_add_f32/f64, zig_sub_*, zig_mul_*,
//!     zig_div_* — mapped to JS +,-,*,/ . f64 ops are plain; f32 ops (plus the
//!     f32 math intrinsics and f64->f32 narrowing) are wrapped in Math.fround so
//!     single-precision results are bit-exact with native.
//!   * Float literals: `zig_make_f64(<hexfloat>, <u64 bits>)` /
//!     `zig_make_f32(...)`. Decimal float literals are NEVER emitted by the
//!     backend (so the hexfloat path is the real one).
//!   * Int<->float conversions are runtime-helper calls treated as identity or
//!     Math.trunc (e.g. zig_floatunsidf/floatsidf -> identity; zig_fixdfsi ->
//!     Math.trunc; zig_extendsfdf (f32->f64 widen) -> identity; zig_truncdfsf
//!     (f64->f32 narrow) -> Math.fround). See `tryBuiltinCall`.
//!   * Integer literal wrappers: `UINT32_C(0x...)`, `-INT64_C(1)`, `NULL`.
//!   * Control flow: EVERY loop/branch/ternary is lowered by the backend to
//!     goto + labels; we re-flatten and trampoline it (above).
//!   * Memory shapes (see next section): globals via cast-pointer deref
//!     `(*((T*)&name))`; fixed arrays wrapped as `struct arr_<N>_<elem>_<id>
//!     { T array[N]; }`; struct fields via pointer-into-struct `&p->field` /
//!     `&local.field` then `*`. Nested/optional/union payload stores arrive as
//!     `*(&LVALUE)` (e.g. `*(&(&opt->payload)->v) = x`); a small recursive lvalue
//!     resolver (`parseLValueAddr`) walks the cast/`&`/`.`/`->`/`[]` chain to one
//!     address + element type, so the read/store hits the correct heap view.
//!     Static global initializers are honoured, including out-of-order designated
//!     ones (`{ .is_null = true, .payload = {...} }`), so a `?T = null` / `bool`
//!     global keeps its initial value; `bool` is a one-byte (byte-addressed) type.
//!   * extern functions with no library name (`extern fn js_get(...)`) become
//!     bare `js_get(...)` call sites; a non-`zig_*` callee is emitted verbatim,
//!     so it only needs to EXIST at runtime — which the kernel and the program's
//!     own definitions provide. (Unrecognized `zig_*` helpers are handled or
//!     marked by `tryBuiltinCall`, never emitted as a bare undefined call.)
//!
//! ===========================================================================
//! THE MEMORY MODEL — one flat heap, typed-array views
//! ===========================================================================
//! Anything with an address lives in a single 16 MB ArrayBuffer `__MEM`, viewed
//! through `__HEAP8/U8/16/U16/32/U32/F32/F64`. There is no malloc: all storage
//! is statically laid out at transpile time.
//!
//!   * DATA IMAGE: `data` (a byte buffer) is filled by the prepasses starting at
//!     `data_base` (1024, leaving low addresses and 0=null clear). It is emitted
//!     as one base64 blob splatted into the heap at startup. `globals` maps each
//!     static name to its byte offset.
//!   * SCALAR LOAD/STORE: the backend reads/writes a scalar pointer `P` as
//!     `(*P)` and a global as `(*((T*)&name))`. Both are recognized
//!     (`tryDerefCast` / `tryDerefCastStore`) and become a typed-array access
//!     `__HEAP{view}[(addr) >> shift]`, choosing the view+shift from the element
//!     width/signedness/floatness.
//!   * POINTER ARITHMETIC: `(T*)<base> + <index>` scales the index by
//!     sizeof(T): `(base) + (index) * stride`. Handled inside the deref-cast
//!     paths so indexed array/element access works.
//!   * FIXED ARRAYS: `[N]T` is the wrapper struct `arr_<N>_<elem>_<id>`. The tag
//!     is parsed (`parseArrTag`) for N and element type. Element addresses
//!     (`&((arr_T*)&g)->array[i]`, or `name.array[i]`) resolve to
//!     `offset + i*elemsize` and route to the right heap view.
//!   * SLICES `[]T`: the backend lowers a slice to `struct slice_T { T *ptr;
//!     uintptr_t len; }` (ptr@0, len@4). `a.ptr[i]` is a heap load through the
//!     pointer field (`Field.ptr_elem` records the pointee so `arraySubscriptAddr`
//!     can scale by element size), `a.len` is the second word, and a slice range
//!     `arr[lo..hi]` is pointer arithmetic `(T*)&arr + lo` (scaled). A const array
//!     GLOBAL behind a slice has its initializer WRITTEN into the data image
//!     (`writeConstStruct`), not just zeroed. A local slice iterated IN PLACE is
//!     emitted by the backend not as a {ptr,len} struct but as a direct
//!     array-wrapper-pointer access `((arr_N_T*)((T*)&base + k))->array[i]`; the
//!     pointer cast records the wrapper tag so `->array[i]` (and `&...->array[i]`,
//!     which must yield an ADDRESS, not a load) resolve against it.
//!   * SCALAR @bitCast: `@bitCast` between same-size scalars (i32<->u32,
//!     f32<->u32, ...) is lowered by the backend to `memcpy(&dst, &src, N)` — a
//!     byte reinterpretation through the addresses of two LOCALS. Local scalars
//!     are JS variables, not heap-backed, so a literal heap memcpy is meaningless;
//!     `tryBuiltinCall` intercepts this exact shape and stages the bits through a
//!     shared typed-view scratch slot (`bitcast_slot`): store `src` via its own
//!     view, load `dst` via dst's view. Exact for int<->int AND float<->int.
//!   * LOCAL ARRAYS / LOCAL STRUCTS: a `[N]T` or struct local has its address
//!     taken, so it needs real backing memory; it is given a static scratch slot
//!     in the data image and registered like a global. Because slots are static,
//!     the function names are PURGED after each function (the per-function names
//!     in `local_array_names` are removed from `globals`/`array_elems`/etc.) so
//!     a later function's `t0` can't collide with an earlier one's. This is safe
//!     only because execution is single-threaded and non-reentrant through those
//!     buffers (see LIMITATIONS).
//!   * STRUCT BY VALUE: a struct value is represented AS a heap offset.
//!       - struct locals/globals -> scratch slot (`struct_vars`: name -> tag);
//!       - struct-pointer locals and struct-value PARAMS -> the value is the
//!         offset (`struct_ptrs`: name -> pointee tag);
//!       - `&v.field` / `&p->field` -> off + fieldOffset;
//!       - field read/write -> typed-array load/store at that address
//!         (`fieldLoad`/`fieldStore`);
//!       - whole-struct copy (`t = a;`, struct-value assignment) -> `__copy(dst,
//!         src, size)` (a heap byte copy).
//!     NOTE: Zig forbids `export fn` from taking/returning an auto-layout struct
//!     by value (the C ABI has no guaranteed layout for it). So struct-by-value
//!     only appears through NON-exported functions and/or `extern struct`
//!     (C-layout) types. Boundary functions (what JS calls) must be scalar- or
//!     handle-typed; internal compute may use structs freely.
//!
//! ===========================================================================
//! INTEGER SEMANTICS — masking on store ("wrap")
//! ===========================================================================
//! C assignment truncates to the destination width; JS numbers don't. `wrap`
//! coerces an expression to a type's store semantics:
//!     u32      -> (x) >>> 0
//!     i32      -> (x) | 0
//!     uN (<32) -> (x) & ((1<<N)-1)
//!     iN (<32) -> ((x) << (32-N)) >> (32-N)        (sign-extend)
//!     64-bit   -> BigInt.as{U,I}ntN(64, x)         (BigInt, exact)
//! Genuine 64-bit integers (u64/i64) are BigInts in the emitted JS, so they are
//! EXACT past 2^53. The wrapping ARITHMETIC the C backend routes through zig_*_u64
//! helpers (and 128-bit through zig_*_u128) is lowered to BigInt by bigIntWide();
//! BITWISE and COMPARISON on 64-bit operands are native BigInt ops; literals come
//! in as UINT64_C/INT64_C (and the UINT64_MAX/INT64_MAX/INT64_MIN limit macros) and
//! become BigInt literals. A lightweight per-expression width tracker (last_w) lets
//! a cast convert at a BigInt<->Number boundary (widen `BigInt(x)`, narrow
//! `Number(asIntN/asUintN(...))`). Crucially, wasm32 pointers/sizes/indices are
//! 32-bit (size_t/uintptr_t), so they stay fast Numbers — BigInt appears ONLY for
//! values that are genuinely 64/128-bit, and the hot path is unchanged.
//! Float/bool/ptr/other are unwrapped.
//!
//! ===========================================================================
//! EXPRESSIONS
//! ===========================================================================
//! `parseBinary` is precedence-climbing over a fixed table `levels` (low->high:
//! || && | ^ & ==/!= relational shift +/- * / %). `opAtLevel` refuses to grab a
//! compound-assign op (e.g. it won't read `<<` out of `<<=`). Assignments
//! (`parseAssign`) handle simple `name op= rhs`, pointer stores `(*P) = rhs`,
//! cast-pointer stores, and the struct field/copy stores described above; `=`
//! applies `wrap` to the rhs for the lvalue's type. `parseUnary` handles casts
//! (stripped to identity — pointers/offsets are just integers), address-of (the
//! many `&...` shapes that resolve to heap offsets), and the C-backend's
//! `*(&x)` round-trips (collapsed to identity). `tryBuiltinCall` intercepts the
//! whole `zig_*` helper family: arithmetic, shifts, wraps, conversions, float
//! makers, `@abs`, the bit builtins (clz/ctz/popcount/byteSwap/bitReverse), and
//! saturating + with-overflow ops. A `zig_*` helper it does NOT recognize is
//! consumed and replaced with a visible `/*?unhandled-helper*/` marker rather
//! than a bare (undefined) call. Any non-`zig_*` callee is emitted verbatim.
//!
//! ===========================================================================
//! THE JS INTEROP KERNEL — the only hand-written JavaScript
//! ===========================================================================
//! A small block of JS is baked into the output preamble. It is the sole irreducible
//! piece of hand-written JS; everything else is generated. It provides the bridge
//! between heap-resident Zig values and live JS objects:
//!   * HANDLE TABLE `__H`: JS objects that can't live in linear memory (DOM
//!     nodes, functions, strings, promises) are kept in an array; a "handle" is
//!     an index. `__href(o)` interns and returns an index; index 1 is globalThis.
//!     A free-list reclaims freed indices (`js_free`), and `js_mark`/`js_reset`
//!     bracket a scope so all handles interned within it are released at once —
//!     wz.Site uses this per frame, so the table stays bounded in a render loop.
//!   * PRIMITIVES: js_global, js_get/get_num/get_index/set/set_num/set_index,
//!     js_call0..6 plus js_call0v..5v (void variants that return no result handle)
//!     and js_calln1..6 / js_calln1v..6v (numeric fast paths that pass f64 args
//!     directly), js_new0..3, js_str/num/to_num/is_null/free, js_obj, js_read_into
//!     (bulk-copy a heap region so a typed read crosses the boundary once),
//!     js_func / js_func_ctx (wrap a Zig fn pointer as a JS callback; js_func_ctx
//!     threads one extra context argument; args are interned), js_fn_raw (raw fn
//!     value, e.g. for wasm imports), js_string_into (encode a JS string into the
//!     heap).
//!   * PROMISES / "await": there is no synchronous await. `js_promise_register`
//!     attaches .then to a promise and stashes the settled result/handle in a
//!     completion table `__P`; `js_promise_status`/`js_promise_take` are polled
//!     (naturally, once per frame in a game loop). Chained async (fetch ->
//!     arrayBuffer) is orchestrated in Zig across frames as register/poll/take.
//!   * GENERALITY LAYER (so a Zig program can do anything JS can):
//!         js_array/js_push/js_len           build/inspect arrays
//!         js_apply/js_call_n/js_construct    calls/new for more than six arguments —
//!                                            args are a heap u32-array of handles
//!         js_typeof/js_instanceof/js_truthy/js_strict_eq   reflection/control
//!         js_try_call                        call that may throw; writes a
//!                                            success flag to *okp and returns the
//!                                            result-or-caught-exception handle
//!         js_undefined                       the undefined value
//!   * `__copy` (heap byte copy, for struct-by-value) also lives in the preamble.
//!   To use any of these from Zig you declare them `extern fn`. Most call sites emit
//!   verbatim as calls to these definitions. The exception is a property or method
//!   access whose name is a comptime literal — js_get/get_num, js_set/set_num, and
//!   the js_call* family — which is emitted as a direct `__H[recv].name(...)` access;
//!   the kernel form is the general fallback when the name is not a literal.
//!
//! ===========================================================================
//! SOURCE MAPS (debugging)
//! ===========================================================================
//! When given a basename argument, the tool emits a Source Map v3 file mapping
//! generated JS lines back to C lines, and appends `//# sourceMappingURL=`.
//! Mechanism: each Token carries its C line; each statement (`Stmt.raw`/`.ret`,
//! and the lowered `FlowOp.line`/`.ret`) carries that line as `src`; `emit` records
//! a (generatedLine -> cLine) pair whenever a new output line begins; at the end
//! `buildSourceMap` VLQ-encodes the pairs (`vlqEncode`) and embeds the
//! PREPROCESSED C as `sourcesContent` (so line numbers line up exactly and no
//! .c file is needed at debug time).
//!   IMPORTANT LIMIT: the map only reaches the C, NOT the original .zig. Zig's C
//!   backend emits no `#line` directives, so JS->Zig mapping is impossible by
//!   this route. The C does preserve mangled-but-recognizable function/global
//!   names, so a breakpoint lands in the right function; locals are gone (they
//!   are the SSA temps t0..tN).
//!
//! ===========================================================================
//! TESTING & SOUNDNESS — how output is checked against real Zig
//! ===========================================================================
//! The failure mode that matters most for a transpiler is SILENT wrong output:
//! JS that runs without error but computes the wrong thing. Three layers guard
//! against it (all under tests/, driven by `zig build test` plus scripts):
//!
//!   * UNIT HARNESS (`tests/harness.mjs`): each tests/cases/*.zig is compiled
//!     Zig -> C -> JS and its `run_test()` must return 0 (the case asserts its
//!     own expected values internally) AND the generated JS must contain ZERO
//!     markers. Plus a DOM scenario over demo/webdemo2.zig.
//!   * NATIVE-ORACLE DIFFERENTIAL (`tests/differential.sh` + `oracle_main.zig`):
//!     for a program exporting `run_test() i32`, the result is computed two ways
//!     — compiled to a NATIVE binary and run (ground truth: real Zig on real
//!     hardware), and Zig -> C -> JS run in node — and the two are diffed. The
//!     expected value is never hand-written; the compiler is the oracle. This is
//!     the layer that catches author blind spots, because the cases a human
//!     writes are the population least likely to contain the human's blind spots.
//!   * FUZZER (`tests/fuzz.mjs`): generates random Zig programs whose result is
//!     DETERMINISTIC and EXACT (unsigned wrapping arithmetic masked well under
//!     2^53, in-bounds indices, no /0, no f32, no recursion) so any native-vs-JS
//!     mismatch is a real bug, not a known-precision artifact. Covers structs
//!     (incl. nested), fixed arrays, slices, loops/branches, and non-recursive
//!     calls with scalar and struct-by-value parameters. Seeded (reproducible).
//!     This fuzzer is what surfaced the scalar-@bitCast, in-place-slice, and
//!     address-of-array-wrapper bugs the hand-written cases never hit.
//!
//! MARKER CONVENTION: when the transpiler meets a shape it cannot lower
//! faithfully, it emits a marker comment (`/*TODO ...*/` or `/*?...*/`) inline
//! rather than guessing. Markers make an unsupported/uncertain lowering VISIBLE:
//! the harness fails on any nonzero count, and the differential prints it. The
//! design rule throughout is loud-over-silent — a marker (or a hard mismatch) is
//! always preferable to JS that quietly returns the wrong number.
//!
//! ===========================================================================
//! LIMITATIONS (read before trusting the output)
//! ===========================================================================
//! Dialect / scope:
//!   * Accepts ONLY Zig-C-backend C. Arbitrary or hand-written C will mis-parse.
//!     Recognition is shape-based; if upstream Zig changes a shape, the matching
//!     handler silently stops applying.
//!   * No real preprocessor: only single-token object-like #defines are honored;
//!     function-like macros and multi-token replacements are ignored; #includes
//!     are dropped (the kernel + the program's own code supply all runtime).
//!
//! Numeric:
//!   * 64-bit integers (u64/i64) ARE BigInts — exact past 2^53. Wrapping ARITHMETIC
//!     goes through zig_*_u64 helpers lowered by bigIntWide; BITWISE & | ^ ~ and
//!     COMPARISON are native BigInt ops; literals arrive as UINT64_C/INT64_C (and
//!     the 64-bit limit macros) -> BigInt literals; casts convert at a BigInt<->
//!     Number boundary using the last_w width tracker. wasm32 pointers/sizes/indices
//!     are 32-bit (size_t/uintptr_t) and stay fast Numbers, so the hot path keeps
//!     the numbers-only shape — BigInt appears only for genuinely 64-bit values.
//!     DEFERRED: a 64-bit @bitCast lowered as `memcpy(&a,&b,8)` between scalar
//!     locals still round-trips through a 32-bit scratch slot (keeps only the low
//!     32 bits — a pre-existing limitation, now LOUD via a BigInt-store throw rather
//!     than silent); and the bridge<->wasm i64 ABI (no example uses it).
//!   * 128-bit integers (u128/i128) ARE lowered to BigInt — the C backend routes
//!     every 128-bit op through opaque zig_*_{u,i}128 helpers, so the value only
//!     flows between those calls (now shared with the 64-bit BigInt path; see
//!     bigIntWide). Construction, +,-,*, the wrapping shifts, and & | ^ ~ are exact;
//!     `lo`/`hi` extract a 64-bit word as a Number (lossy beyond 2^53, so the usual
//!     `@intCast(x & mask)` is exact, but a wide `@truncate` is not). Comparison,
//!     division/remainder, and 128-bit values in the HEAP (struct/array/global; they
//!     need 16-byte word-split storage) are NOT modeled yet and emit a loud marker.
//!   * f32 arithmetic (+,-,*,/), the f32 math intrinsics, and f64->f32 narrowing
//!     are wrapped in Math.fround, so they are bit-exact with native f32. Only
//!     the transcendental f32 intrinsics (sin/cos/exp/log/pow/...) are not
//!     guaranteed bit-identical: they compute in f64 then round once (near-exact,
//!     but the last bit can differ from a native f32 libm, which itself varies).
//!   * Wrapping/masking assumes the operands the backend hands to `>>`/`>>>` are
//!     already appropriately masked (it relies on that being true upstream).
//!
//! Memory / aliasing:
//!   * One fixed 16 MB heap. No allocator, no growth, no bounds checks: an
//!     out-of-range offset reads/writes wild heap or silently misbehaves.
//!   * Local arrays/structs (and address-taken scalars) live in linear memory.
//!     A NON-recursive function gives each one a fixed STATIC scratch slot (fast,
//!     reused, valid because execution is single-threaded and the slot is never
//!     live across a re-entry of the same function). A RECURSIVE function would
//!     clobber an outer call's slot, so there each address-taken local instead gets
//!     a frame-relative offset and the function runs a SHADOW-STACK prologue/epilogue:
//!     `prescanRecursion` builds the call graph and computes (via transitive closure,
//!     so MUTUAL recursion counts too) the set of functions in a cycle; emitFunction
//!     bumps a global `__SP` down by the frame size on entry, exposes the frame base
//!     as `__fp` (each local resolves to `__fp + offset` via `scratchBase`), and
//!     restores `__SP` on every exit through a `finally`. The stack grows down from
//!     the top of __MEM; static data grows up from low addresses, so they never meet.
//!     Plain recursion with no address-taken local needs no frame and is untouched.
//!   * Struct layout is computed from scalar field widths with natural
//!     alignment; NESTED struct-typed fields are sized/aligned by the inner
//!     struct's layout (the backend defines inner structs first) and copied
//!     whole on field assignment. 64-bit (i64/u64) struct fields, array elements,
//!     and through-pointer accesses round-trip within 2^53 (8-byte element stride
//!     + __ld/st64). Taking the address of a local SCALAR (`&w` for a plain
//!     `var w` — the out-parameter idiom `f(&w)`) is also handled: the local is
//!     heap-backed like an aggregate, so `&w` is a real address and reads load /
//!     writes store through its slot (so 64-bit out-params work too). The one
//!     deliberate exception is `&x` inside the bitcast/copy idioms
//!     (`memcpy(&a,&b,n)` etc.), which the transpiler lowers specially — those
//!     temps stay SSA values and get no slot. An address-taken scalar follows the
//!     same static-slot / shadow-stack-frame split as aggregates above.
//!     Storing through the ADDRESS of a struct field whose type is a function
//!     pointer (`o.f = &g`, which the C backend lowers as `t = &o.f; *t = &g`) is
//!     handled via the function-dispatch table: `&g` lowers to a 1-based __FTABLE
//!     index, the field stores that index, and an indirect call dispatches
//!     `__FTABLE[idx](args)` — see cases/fnptr_field_reassign. Reading a struct's
//!     array field by a RUNTIME index (`g.vals[i]`), calling a fn-ptr field on a
//!     const struct, and the by-value struct returns exercised in cases/ all work.
//!
//! Interop:
//!   * The handle table reclaims freed slots via a free-list, and js_mark/
//!     js_reset bracket a scope so transient handles are released en masse;
//!     wz.Site brackets every frame, so a render loop's table stays bounded.
//!     Mint-heavy code outside such a scope should still js_free what it makes.
//!   * Exceptions only cross the boundary if a call goes through `js_try_call`;
//!     a plain js_call that throws will propagate as a JS exception and is not
//!     translated into a Zig-visible error.
//!   * No threads: SharedArrayBuffer/Workers/atomics are out of scope. Programs
//!     must be single-threaded.
//!
//! Output:
//!   * The generated JS is deliberately unreadable and is not meant to be edited.
//!   * It uses `>>>`, `| 0`, `Math.imul`, `Math.trunc`, typed arrays, and a
//!     `while/switch` trampoline; it assumes a modern JS engine ("use strict").
//!
//! Coverage gaps that surface as you exercise more Zig (each a small, local
//! addition in the same style as the existing handlers): the still-rarer zig.h
//! helpers beyond the set tryBuiltinCall now covers (an unrecognized one surfaces
//! as a `/*?unhandled-helper*/` marker, not a silent undefined call), typed
//! array element widths beyond what `elemFromName` lists, multi-dimensional
//! arrays (`[N][M]T`) and array-typed struct fields, and arrays-of-structs
//! indexed by a runtime variable. Nested scalar-field structs, slices, and
//! non-recursive by-value calls ARE exercised by the fuzzer against the native
//! oracle. Recursion with address-taken locals is now handled by the shadow stack
//! (see above); 64-bit BITWISE via bare operators (& | ^ ~) remains a known numeric
//! item above — left for the reasons given, not a mere gap. f32 rounding, 64-bit
//! arithmetic, and <=32-bit packed structs are also handled (a packed struct wider
//! than 32 bits is flagged with a loud marker: a field above bit 32 would need a
//! true 64-bit heap load/store).
//!
//! ---- THE TWO GATES, and why BOTH are needed ------------------------------
//! c2js translates names the Zig COMPILER generates, so every toolchain bump can
//! silently change what it is reading. Two independent gates cover the two halves
//! of that; neither covers the other's.
//!
//!  1. The `/*?...*/` MARKER GATE, at the bottom of main(). Catches C that c2js
//!     KNOWS it cannot model. Every such construct lowers to a constant, so a
//!     miss is a silently wrong VALUE, not a crash — any marker is fatal.
//!     This gate exists because 0.17.0-dev.1676 renamed zig.h's integer casts to
//!     `zig_<dst>_<op>_<src>`; c2js knew only the older `zig_wrap_uN` spelling,
//!     and 99 call sites per bundle became the literal `0`. It shipped green
//!     through build, lint, fmt and verify_imports, and the only symptom was one
//!     device-only `GPUTextureFormat: undefined` — the other 98 corrupted data
//!     quietly. The marker had been emitted for YEARS with a comment saying its
//!     purpose was to "make the gap loud, not silent". Nothing ever read it.
//!     A marker nothing reads is not a gate.
//!
//!  2. `zig build c2js-canary` (webtests/c2js_canary.zig). Catches C that c2js
//!     models WRONGLY — the half a marker can never flag. A battery of integer
//!     casts, wrapping arithmetic and 64/128-bit ops is transpiled normally and
//!     compared against the SAME computation folded by Zig's comptime evaluator,
//!     which never passes through c2js. The seed is a runtime PARAMETER so the
//!     optimizer cannot fold the runtime path back into the constant and make the
//!     test a tautology; the runner asserts that too. It earned its keep on its
//!     first run, catching a Number/BigInt domain crossing in the widening-cast
//!     path. Atomics and >64-bit heap traffic cannot be comptime-evaluated, so
//!     they stay gate 1's job.
//!
//! WHEN A COMPILER BUMP BREAKS THINGS: read the semantics from the toolchain ON
//! DISK (`lib/zig.h` ships in the release), never from the helper's name.
//! `zig_u32_truncate_u32` looks like identity; it takes a `bits` argument and
//! masks to it, so a packed u9 living in a u32 is a different value.

const std = @import("std");
/// The jobs ABI, from the ONE file every side of the system reads. c2js checks that a kernel
/// wasm actually exports a kernel, and it must ask about the same name `jobs.zig` exports.
const jobs_abi = @import("jobs_abi");

// ---- Frequently-used std declarations, aliased for brevity ---------------
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const endsWith = std.mem.endsWith;
const indexOf = std.mem.indexOf;
const indexOfPos = std.mem.indexOfPos;
const splitScalar = std.mem.splitScalar;
const trimStart = std.mem.trimStart;
const trim = std.mem.trim;
const alignForward = std.mem.alignForward;
const allocPrint = std.fmt.allocPrint;
const parseInt = std.fmt.parseInt;
const File = std.Io.File;
const Dir = std.Io.Dir;
/// NaN is the only value unequal to itself — no std.math needed, and the
/// transpiler stays dependency-free on the engine's math vocabulary.
fn isNan(x: anytype) bool {
    return x != x;
}
const HashGetOrPut = StringHashMap([]const u8).GetOrPutResult;
// --------------------------------------------------------------------------

// One hex digit -> its 0..15 value (0 on anything non-hex). Tiny helper for
// decodeCString's \xNN escapes.
fn hexVal(c: u8) u16 {
    if (c >= '0' and c <= '9') {
        return c - '0';
    }
    if (c >= 'a' and c <= 'f') {
        return c - 'a' + 10;
    }
    if (c >= 'A' and c <= 'F') {
        return c - 'A' + 10;
    }
    return 0;
}

/// Decode a C string literal body (without quotes) into raw bytes, handling the
/// escapes Zig's C backend emits: \n \t \r \\ \" \' \0 and octal \NNN.
fn decodeCString(gpa: Allocator, s: []const u8) ![]u8 {
    var out: ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '\\') {
            try out.append(gpa, s[i]);
            i += 1;
            continue;
        }
        i += 1; // backslash
        if (i >= s.len) {
            break;
        }
        const c: u8 = s[i];
        switch (c) {
            'n' => {
                try out.append(gpa, '\n');
                i += 1;
            },
            't' => {
                try out.append(gpa, '\t');
                i += 1;
            },
            'r' => {
                try out.append(gpa, '\r');
                i += 1;
            },
            '\\' => {
                try out.append(gpa, '\\');
                i += 1;
            },
            '"' => {
                try out.append(gpa, '"');
                i += 1;
            },
            '\'' => {
                try out.append(gpa, '\'');
                i += 1;
            },
            'a' => {
                try out.append(gpa, 0x07);
                i += 1;
            },
            'b' => {
                try out.append(gpa, 0x08);
                i += 1;
            },
            'f' => {
                try out.append(gpa, 0x0c);
                i += 1;
            },
            'v' => {
                try out.append(gpa, 0x0b);
                i += 1;
            },
            '0'...'7' => {
                // octal escape, up to 3 digits
                var val: u16 = 0;
                var k: usize = 0;
                while (k < 3 and i < s.len and s[i] >= '0' and s[i] <= '7') : (k += 1) {
                    val = val * 8 + (s[i] - '0');
                    i += 1;
                }
                try out.append(gpa, @intCast(val & 0xff));
            },
            'x' => {
                i += 1;
                var val: u16 = 0;
                while (i < s.len and std.ascii.isHex(s[i])) {
                    val = val * 16 + hexVal(s[i]);
                    i += 1;
                }
                try out.append(gpa, @intCast(val & 0xff));
            },
            else => {
                try out.append(gpa, c);
                i += 1;
            },
        }
    }
    return out.toOwnedSlice(gpa);
}

// Plain base64. Used to fold the program's initialized-data image (all the
// string/array statics, laid out in `data`) into the emitted JS as a single
// string literal that the runtime base64-decodes straight into __MEM at boot.
/// Return the name of the FIRST import a wasm module declares, or null if it declares
/// none. Used to enforce that a job kernel is pure: a kernel that imports anything
/// cannot be instantiated inside a Web Worker (which has no DOM and no WebGPU), so we
/// fail the build instead of shipping a page whose workers die on startup.
///
/// A minimal section walk — we only need section 2 (imports) and only its first entry.
fn firstWasmImport(gpa: Allocator, bytes: []const u8) !?[]const u8 {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..4], "\x00asm")) {
        return null; // not a wasm we understand; leave it alone
    }
    var i: usize = 8;
    while (i < bytes.len) {
        const section_id: u8 = bytes[i];
        i += 1;
        const section_len: u32 = readLeb(bytes, &i) orelse return null;
        const section_end: usize = i + section_len;
        if (section_end > bytes.len) {
            return null;
        }
        if (section_id == 2) { // the import section
            const count: u32 = readLeb(bytes, &i) orelse return null;
            if (count == 0) {
                return null;
            }
            const mod_len: u32 = readLeb(bytes, &i) orelse return null;
            const mod: []const u8 = bytes[i .. i + mod_len];
            i += mod_len;
            const nm_len: u32 = readLeb(bytes, &i) orelse return null;
            const nm: []const u8 = bytes[i .. i + nm_len];
            return try allocPrint(gpa, "{s}.{s}", .{ mod, nm });
        }
        i = section_end;
    }
    return null;
}

/// Does this wasm export `want`? Used to catch a kernel wasm that compiled fine but
/// contains no kernels — a root that forgot `exportWorkerEntry()`. Such a wasm imports
/// nothing (there is nothing in it TO import), so the purity check alone would wave it
/// through and the failure would surface as a runtime NoSuchKernel inside a worker.
fn wasmExports(bytes: []const u8, want: []const u8) bool {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..4], "\x00asm")) {
        return false;
    }
    var i: usize = 8;
    while (i < bytes.len) {
        const section_id: u8 = bytes[i];
        i += 1;
        const section_len: u32 = readLeb(bytes, &i) orelse return false;
        const section_end: usize = i + section_len;
        if (section_end > bytes.len) {
            return false;
        }
        if (section_id == 7) { // the export section
            const count: u32 = readLeb(bytes, &i) orelse return false;
            var n: u32 = 0;
            while (n < count) : (n += 1) {
                const name_len: u32 = readLeb(bytes, &i) orelse return false;
                if (i + name_len > bytes.len) {
                    return false;
                }
                const name: []const u8 = bytes[i .. i + name_len];
                i += name_len;
                if (std.mem.eql(u8, name, want)) {
                    return true;
                }
                i += 1; // kind
                _ = readLeb(bytes, &i) orelse return false; // index
            }
            return false;
        }
        i = section_end;
    }
    return false;
}

/// One unsigned LEB128, advancing `i`.
fn readLeb(bytes: []const u8, i: *usize) ?u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (i.* < bytes.len) {
        const byte: u8 = bytes[i.*];
        i.* += 1;
        result |= @as(u32, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) {
            return result;
        }
        if (shift >= 28) {
            return null;
        }
        shift += 7;
    }
    return null;
}

fn base64Encode(gpa: Allocator, bytes: []const u8) ![]u8 {
    const tbl: []const u8 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    var out: ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i + 3 <= bytes.len) : (i += 3) {
        const n = (@as(u32, bytes[i]) << 16) | (@as(u32, bytes[i + 1]) << 8) | bytes[i + 2];
        try out.append(gpa, tbl[(n >> 18) & 63]);
        try out.append(gpa, tbl[(n >> 12) & 63]);
        try out.append(gpa, tbl[(n >> 6) & 63]);
        try out.append(gpa, tbl[n & 63]);
    }
    const rem: usize = bytes.len - i;
    if (rem == 1) {
        const n = @as(u32, bytes[i]) << 16;
        try out.append(gpa, tbl[(n >> 18) & 63]);
        try out.append(gpa, tbl[(n >> 12) & 63]);
        try out.append(gpa, '=');
        try out.append(gpa, '=');
    } else if (rem == 2) {
        const n = (@as(u32, bytes[i]) << 16) | (@as(u32, bytes[i + 1]) << 8);
        try out.append(gpa, tbl[(n >> 18) & 63]);
        try out.append(gpa, tbl[(n >> 12) & 63]);
        try out.append(gpa, tbl[(n >> 6) & 63]);
        try out.append(gpa, '=');
    }
    return out.toOwnedSlice(gpa);
}

// ----------------------------------------------------------------------------
// Optional output minifier (--min). The generated JS is dominated by long,
// compiler-mangled function names (e.g. `js_helper_Value_call__anon_1985__1050`)
// repeated at every definition and call site, plus indentation. This pass:
//   * renames every *generated* identifier to a short `$`-prefixed token,
//   * strips leading indentation, blank lines, and collapses space runs.
// It is string-aware (the base64 data blob and any other string literal is
// copied verbatim) and conservative with newlines (kept, so no ASI surprises).
// Exported entry points (`start`, `onAdd`, …) and kernel names (`js_get`,
// `__HEAPU32`, `__copy`, …) are NOT generated names, so they are preserved.
// ----------------------------------------------------------------------------
fn minIdStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}
fn minIdCont(c: u8) bool {
    return minIdStart(c) or (c >= '0' and c <= '9');
}

/// A "generated" identifier is one the Zig C-backend mangled: it contains
/// `__anon_` or a `__` immediately followed by a digit (the trailing numeric id).
/// Kernel names like `__HEAPU32`/`__copy` have `__` followed by a letter, so they
/// are excluded; exports have no `__<digit>` at all.
fn isGeneratedName(name: []const u8) bool {
    if (indexOf(u8, name, "__anon_") != null) {
        return true;
    }
    var i: usize = 0;
    while (i + 2 < name.len) : (i += 1) {
        if (name[i] == '_' and name[i + 1] == '_' and
            name[i + 2] >= '0' and name[i + 2] <= '9')
        {
            return true;
        }
    }
    return false;
}

/// `$` + base36(n): short, collision-free (the codegen never emits `$`), and
/// never a JS keyword.
fn shortName(gpa: Allocator, n: usize) ![]u8 {
    const digits: []const u8 = "0123456789abcdefghijklmnopqrstuvwxyz";
    var tmp: [16]u8 = undefined;
    var k: usize = 0;
    var v: usize = n;
    while (true) {
        tmp[k] = digits[v % 36];
        k += 1;
        v /= 36;
        if (v == 0) {
            break;
        }
    }
    var res = try gpa.alloc(u8, k + 1);
    res[0] = '$';
    var j: usize = 0;
    while (j < k) : (j += 1) {
        res[1 + j] = tmp[k - 1 - j];
    }
    return res;
}

// The minifier's actual pass (the block comment above covers what it strips and
// why): walk the JS once, rename generated identifiers via `map`, squeeze
// whitespace, and copy string literals through verbatim.
fn minify(gpa: Allocator, src: []const u8) ![]u8 {
    var out: ArrayList(u8) = .empty;
    var map = StringHashMap([]const u8).init(gpa);
    var counter: usize = 0;
    var i: usize = 0;
    var at_line_start: bool = true;
    while (i < src.len) {
        const c: u8 = src[i];
        // string literal: copy verbatim (handles escapes), don't rename inside.
        if (c == '"' or c == '\'' or c == '`') {
            at_line_start = false;
            const q: u8 = c;
            try out.append(gpa, c);
            i += 1;
            while (i < src.len) {
                const d: u8 = src[i];
                try out.append(gpa, d);
                i += 1;
                if (d == '\\' and i < src.len) {
                    try out.append(gpa, src[i]);
                    i += 1;
                    continue;
                }
                if (d == q) {
                    break;
                }
            }
            continue;
        }
        // comments: the generated JS never emits `//`/`/*` except as comments
        // (division is always a lone `/`), so these are safe to drop.
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            i += 2;
            while (i < src.len and src[i] != '\n') {
                i += 1;
            }
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            i += 2;
            while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) {
                i += 1;
            }
            i += 2;
            continue;
        }
        // newline: keep one, drop blank lines.
        if (c == '\n') {
            if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
                try out.append(
                    gpa,
                    '\n',
                );
            }
            i += 1;
            at_line_start = true;
            continue;
        }
        // leading indentation: drop.
        if (at_line_start and (c == ' ' or c == '\t' or c == '\r')) {
            i += 1;
            continue;
        }
        at_line_start = false;
        // a run of spaces/tabs: keep a single space ONLY if needed to keep two
        // tokens apart (two word-chars, or `++`/`--`); otherwise drop entirely.
        if (c == ' ' or c == '\t' or c == '\r') {
            i += 1;
            while (i < src.len and (src[i] == ' ' or src[i] == '\t' or src[i] == '\r')) {
                i += 1;
            }
            const prev: u8 = if (out.items.len > 0) out.items[out.items.len - 1] else 0;
            const next: u8 = if (i < src.len) src[i] else 0;
            const need: bool = (minIdCont(prev) and minIdCont(next)) or
                (prev == '+' and next == '+') or
                (prev == '-' and next == '-');
            if (need) {
                try out.append(gpa, ' ');
            }
            continue;
        }
        // identifier: rename if generated.
        if (minIdStart(c)) {
            const start: usize = i;
            i += 1;
            while (i < src.len and minIdCont(src[i])) {
                i += 1;
            }
            const name: []const u8 = src[start..i];
            if (isGeneratedName(name)) {
                const gop: HashGetOrPut = try map.getOrPut(name);
                if (!gop.found_existing) {
                    gop.value_ptr.* = try shortName(gpa, counter);
                    counter += 1;
                }
                try out.appendSlice(gpa, gop.value_ptr.*);
            } else {
                try out.appendSlice(gpa, name);
            }
            continue;
        }
        try out.append(gpa, c);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

// ----------------------------------------------------------------------------
// Tokenizer
// ----------------------------------------------------------------------------

const TokenKind = enum { ident, number, punct, str, eof };

const Token = struct {
    kind: TokenKind,
    text: []const u8,
    line: u32 = 0, // 1-based line in the (preprocessed) C source
};

/// One source-map entry: generated JS line -> originating C line (1-based).
const LineMap = struct { gen: u32, src: u32 };

/// Longest-match punctuators (order matters: longer first).
const puncts = [_][]const u8{
    "<<=", ">>=", "...",
    "<<",  ">>",  "<=",
    ">=",  "==",  "!=",
    "&&",  "||",  "++",
    "--",  "+=",  "-=",
    "*=",  "/=",  "%=",
    "&=",  "|=",  "^=",
    "->",  "(",   ")",
    "{",   "}",   "[",
    "]",   ";",   ",",
    "+",   "-",   "*",
    "/",   "%",   "<",
    ">",   "=",   "&",
    "|",   "^",   "~",
    "!",   "?",   ":",
    ".",
};

// Character-class predicates used by the lexer (and mirrored, with `$`, in the
// minifier above).
fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}
fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

// The hand-written tokenizer. Walks the preprocessed C byte-by-byte and hands
// out one Token at a time; `main` drives it in a loop to build the flat token
// slice the parser then walks. No buffering, no lookahead beyond the current
// char — the parser does its own peeking over the finished slice.
const Lexer = struct {
    src: []const u8,
    i: usize = 0,
    last_start: usize = 0, // byte offset where the most recent token began

    // Skip whitespace and // line + /* block */ comments, leaving self.i parked on
    // the next real character. Called at the top of every `next`.
    fn skipTrivia(self: *Lexer) void {
        while (self.i < self.src.len) {
            const c: u8 = self.src[self.i];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.i += 1;
            } else if (c == '/' and self.i + 1 < self.src.len and self.src[self.i + 1] == '/') {
                while (self.i < self.src.len and self.src[self.i] != '\n') {
                    self.i += 1;
                }
            } else if (c == '/' and self.i + 1 < self.src.len and self.src[self.i + 1] == '*') {
                self.i += 2;
                while (self.i + 1 < self.src.len) {
                    if (self.src[self.i] == '*' and self.src[self.i + 1] == '/') {
                        break;
                    }
                    self.i += 1;
                }
                self.i += 2;
            } else {
                break;
            }
        }
    }

    // Produce the next token — this is essentially the entire lexer. In order it
    // tries: identifier/keyword, string-or-char literal (quotes stripped, escapes
    // left raw for decodeCString later), number (digits/hex/suffixes and a signed
    // exponent kept attached), then a longest-match punctuator. An unknown byte is
    // emitted as a 1-char punct so we can never spin in place.
    fn nextToken(self: *Lexer) Token {
        self.skipTrivia();
        self.last_start = self.i;
        if (self.i >= self.src.len) {
            return .{ .kind = .eof, .text = "" };
        }
        const c: u8 = self.src[self.i];
        const start: usize = self.i;

        if (isIdentStart(c)) {
            while (self.i < self.src.len and isIdentChar(self.src[self.i])) {
                self.i += 1;
            }
            return .{ .kind = .ident, .text = self.src[start..self.i] };
        }
        // string / char literal (text excludes the surrounding quotes; escapes kept raw)
        if (c == '"' or c == '\'') {
            const quote: u8 = c;
            self.i += 1;
            const body_start: usize = self.i;
            while (self.i < self.src.len and self.src[self.i] != quote) {
                if (self.src[self.i] == '\\' and self.i + 1 < self.src.len) {
                    self.i += 1;
                }
                self.i += 1;
            }
            const body: []const u8 = self.src[body_start..self.i];
            if (self.i < self.src.len) {
                self.i += 1;
            } // closing quote
            return .{ .kind = .str, .text = body };
        }
        if (isDigit(c) or
            (c == '.' and self.i + 1 < self.src.len and isDigit(self.src[self.i + 1])))
        {
            // number: digits, hex, '.', signed exponents, and integer/float suffixes
            const consumeNum = struct {
                fn run(lx: *Lexer) void {
                    while (lx.i < lx.src.len) {
                        const ch: u8 = lx.src[lx.i];
                        if (isIdentChar(ch) or ch == '.') {
                            lx.i += 1;
                            // a sign immediately after an exponent marker is part of
                            // the number (e.g. 1.0e-14, 0x1p+3), not a separate op.
                            if ((ch == 'e' or ch == 'E' or ch == 'p' or ch == 'P') and
                                lx.i < lx.src.len and (lx.src[lx.i] == '+' or lx.src[lx.i] == '-'))
                            {
                                lx.i += 1;
                            }
                            continue;
                        }
                        break;
                    }
                }
            }.run;
            if (c == '0' and self.i + 1 < self.src.len and
                (self.src[self.i + 1] == 'x' or self.src[self.i + 1] == 'X'))
            {
                self.i += 2;
                consumeNum(self);
            } else {
                consumeNum(self);
            }
            return .{ .kind = .number, .text = self.src[start..self.i] };
        }
        // punctuator: longest match
        for (puncts) |p| {
            if (startsWith(u8, self.src[self.i..], p)) {
                self.i += p.len;
                return .{ .kind = .punct, .text = p };
            }
        }
        // unknown byte: emit as a 1-char punct so we don't loop forever
        self.i += 1;
        return .{ .kind = .punct, .text = self.src[start..self.i] };
    }
};

// ----------------------------------------------------------------------------
// Preprocess: strip `#`-directive lines, capture object-like `#define A B`
// ----------------------------------------------------------------------------

const Preprocessed = struct {
    src: []u8,
    defines: StringHashMap([]const u8),
};

// STAGE 1 of the pipeline. We are NOT a real C preprocessor: the C-backend's
// output only carries object-like `#define`s (mangled symbol -> friendly name)
// plus one `#include`. So we just harvest each single-token `#define NAME REPL`
// into a map (skipping function-like `NAME(...)` macros) and blank out every
// `#`-line. Blanking instead of deleting keeps C line numbers intact for the
// source map. Those collected defines are applied later as identifier renames
// (applyDefine), which is how call sites can say `zimr_run` instead of the
// mangled `zimr_run__384`.
fn preprocess(gpa: Allocator, input: []const u8) !Preprocessed {
    var out: ArrayList(u8) = .empty;
    var defines = StringHashMap([]const u8).init(gpa);

    var it = splitScalar(u8, input, '\n');
    while (it.next()) |line| {
        const trimmed = trimStart(u8, line, " \t");
        if (trimmed.len > 0 and trimmed[0] == '#') {
            // capture: #define NAME REPLACEMENT  (object-like only, single replacement token)
            const after_hash = trimStart(u8, trimmed[1..], " \t");
            if (startsWith(u8, after_hash, "define")) {
                const rest = trimStart(u8, after_hash["define".len..], " \t");
                // NAME = leading identifier
                var n: usize = 0;
                if (rest.len > 0 and isIdentStart(rest[0])) {
                    while (n < rest.len and isIdentChar(rest[n])) {
                        n += 1;
                    }
                    const name: []const u8 = rest[0..n];
                    // function-like macro if immediately followed by '(': ignore
                    // those. End-of-line (n == rest.len) is a valueless object-like
                    // macro: nothing to record (no replacement), but don't treat the
                    // boundary as "function-like".
                    if (n >= rest.len or rest[n] != '(') {
                        const repl = trim(u8, rest[n..], " \t\r");
                        // single-token replacement only
                        if (repl.len > 0 and std.mem.indexOfAny(u8, repl, " \t") == null) {
                            try defines.put(name, repl);
                        }
                    }
                }
            }
            // drop the directive line entirely (replace with blank line for sanity)
            try out.append(gpa, '\n');
            continue;
        }
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    return .{ .src = try out.toOwnedSlice(gpa), .defines = defines };
}

// ----------------------------------------------------------------------------
// Types (just enough to know integer width & signedness for masking)
// ----------------------------------------------------------------------------

const CTypeKind = enum { int, float, ptr, boolean, void_, strct, other };

/// What a pointer points at (enough to pick a heap view + element size).
const Elem = struct { bits: u16, signed: bool, float: bool, struct_tag: ?[]const u8 = null };

const CType = struct {
    kind: CTypeKind = .int,
    bits: u16 = 32,
    signed: bool = true,
    elem: ?Elem = null, // set when kind == .ptr
    struct_tag: ?[]const u8 = null, // set when this names a struct/union type
};

const Field = struct {
    name: []const u8,
    offset: u32,
    bits: u16,
    signed: bool,
    float: bool,
    struct_tag: ?[]const u8 = null,
    size: u32 = 0,
    ptr_elem: ?Elem = null,
};
const StructLayout = struct { size: u32, fields: []const Field, align_: u32 = 4 };

/// A deferred pointer relocation: write the heap offset of global `target` (a
/// 4-byte pointer in our model) into the data image at byte address `addr`,
/// once all globals have offsets. `width` is the slot size (4 for a pointer).
const Reloc = struct { addr: u32, target: []const u8, width: u8 };

const ArrayInfo = struct { count: u32, elem_size: u32, elem: Elem };

/// Map a Zig primitive element name ("u8","i32","f32",...) to an Elem.
fn elemFromName(name: []const u8) ?Elem {
    if (eql(u8, name, "u8")) {
        return .{ .bits = 8, .signed = false, .float = false };
    }
    if (eql(u8, name, "i8")) {
        return .{ .bits = 8, .signed = true, .float = false };
    }
    if (eql(u8, name, "u16")) {
        return .{ .bits = 16, .signed = false, .float = false };
    }
    if (eql(u8, name, "i16")) {
        return .{ .bits = 16, .signed = true, .float = false };
    }
    if (eql(u8, name, "u32")) {
        return .{ .bits = 32, .signed = false, .float = false };
    }
    if (eql(u8, name, "i32")) {
        return .{ .bits = 32, .signed = true, .float = false };
    }
    if (eql(u8, name, "u64")) {
        return .{ .bits = 64, .signed = false, .float = false };
    }
    if (eql(u8, name, "i64")) {
        return .{ .bits = 64, .signed = true, .float = false };
    }
    if (eql(u8, name, "f32")) {
        return .{ .bits = 32, .signed = false, .float = true };
    }
    if (eql(u8, name, "f64")) {
        return .{ .bits = 64, .signed = false, .float = true };
    }
    // Arbitrary-width integers: u40, i48, u33, i7, … (the C backend stores a 33-63
    // bit element in 64-bit cells, an 8-31 bit one in its next-power-of-2 cell —
    // the heap view picks the cell from .bits). Without this, an odd-width element
    // type returned null, so e.g. arr_6_u40 was misread as an array-of-struct and
    // its element store silently lowered to a load (dropping the write).
    if ((name[0] == 'u' or name[0] == 'i') and name.len > 1) {
        if (parseInt(u16, name[1..], 10)) |bits| {
            if (bits >= 1 and bits <= 128) {
                return .{ .bits = bits, .signed = name[0] == 'i', .float = false };
            }
        } else |_| {}
    }
    return null;
}

/// True if `e` is a single fully-parenthesized expression whose outermost
/// operation produces exactly `suffix` (e.g. " | 0", " >>> 0", " & 255"). Lets
/// `wrap` be idempotent — re-wrapping an already-canonical value is skipped,
/// which removes the pervasive double coercions (`((x | 0) | 0)` -> `(x | 0)`).
fn outerWrapIs(e: []const u8, suffix: []const u8) bool {
    if (e.len < suffix.len + 2) {
        return false;
    }
    if (e[0] != '(' or e[e.len - 1] != ')') {
        return false;
    }
    var depth: usize = 0;
    for (e, 0..) |c, idx| {
        if (c == '(') {
            depth += 1;
        } else if (c == ')') {
            depth -= 1;
            // the leading '(' must close only at the very end — i.e. the parens
            // span the whole expression, so `suffix` really is the outermost op.
            if (depth == 0 and idx != e.len - 1) {
                return false;
            }
        }
    }
    return endsWith(u8, e[1 .. e.len - 1], suffix);
}

/// True if `e` is exactly one call `fn_name(...)` spanning the whole expression
/// (so e.g. `Math.trunc(Math.trunc(x))` collapses to a single trunc in `wrap`).
/// Parse a bare decimal integer (a resolved static-data offset / a literal length).
/// Tolerates surrounding spaces/parens; returns null for anything non-numeric, so the
/// monomorphic resolver only fires when the name pointer reduced to a constant offset.
fn parseDecimalLit(s: []const u8) ?usize {
    const t = std.mem.trim(u8, s, " ()");
    if (t.len == 0) {
        return null;
    }
    var v: usize = 0;
    for (t) |c| {
        if (c < '0' or c > '9') {
            return null;
        }
        v = v * 10 + (c - '0');
    }
    return v;
}

/// True if `s` is a plain JS identifier (safe to emit as `obj.s`). Method/property
/// names are identifiers; anything else (a dash, empty, leading digit) falls back.
fn isJsIdent(s: []const u8) bool {
    if (s.len == 0) {
        return false;
    }
    for (s, 0..) |c, i| {
        const alpha: bool = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
        const digit: bool = c >= '0' and c <= '9';
        if (!(alpha or (i > 0 and digit))) {
            return false;
        }
    }
    return true;
}

fn outerCallIs(e: []const u8, fn_name: []const u8) bool {
    if (!startsWith(u8, e, fn_name)) {
        return false;
    }
    if (e.len <= fn_name.len or e[fn_name.len] != '(') {
        return false;
    }
    if (e[e.len - 1] != ')') {
        return false;
    }
    var depth: usize = 0;
    for (e, 0..) |c, idx| {
        if (c == '(') {
            depth += 1;
        } else if (c == ')') {
            depth -= 1;
            if (depth == 0 and idx != e.len - 1) {
                return false;
            }
        }
    }
    return true;
}
/// `arr_<count>_<elem>_<id>` (e.g. `arr_4096_u8_2372`, `arr_8_u32_2568`).
/// Returns the element count and element type, or null if `tag` isn't one.
/// True if `tag` is one of the C backend's synthetic fixed-array wrapper structs
/// — `arr_<count>_<elem>...` (and the sentinel form `arr_<count>s<sentinel>_<elem>`),
/// i.e. `arr_` immediately followed by a DIGIT (the element count). A USER struct
/// or module whose mangled name merely begins with `arr_<letter>` (e.g.
/// `arr_of_arr_struct_P`) is NOT a wrapper and must not be diverted by the
/// wrapper-detection sites — doing so drops it from struct-pointer/value tracking
/// and silently lowers `p->field` to a bogus JS property access.
fn looksLikeArrayWrapper(tag: []const u8) bool {
    return startsWith(u8, tag, "arr_") and tag.len > "arr_".len and isDigit(tag["arr_".len]);
}

fn parseArrTag(tag: []const u8) ?ArrayInfo {
    if (!startsWith(u8, tag, "arr_")) {
        return null;
    }
    var it = splitScalar(u8, tag["arr_".len..], '_');
    const count_s_raw: []const u8 = it.next() orelse return null;
    const elem_s: []const u8 = it.next() orelse return null;
    // A sentinel-terminated array encodes its count as `<N>s<sentinelTypeId>`
    // (e.g. `arr_4s177_u32` for `[4:0]u32`); take the digits before `s` as the
    // count so a non-string sentinel array is still recognized as an array wrapper
    // (otherwise structTagOf diverts it and `t.array[i]` becomes a literal JS
    // property access on a heap offset -> a runtime crash). The actual element
    // count incl. the sentinel comes from the struct's own layout, not this.
    var count_s: []const u8 = count_s_raw;
    if (indexOf(u8, count_s_raw, "s")) |si| {
        count_s = count_s_raw[0..si];
    }
    const count = parseInt(u32, count_s, 10) catch return null;
    // An array of pointers (`arr_N_ptr_<pointee>_<id>`): in our model a pointer
    // is a 4-byte heap offset, so the element is a 32-bit unsigned slot. (The C
    // ABI sizes pointers at 8, but the transpiler models them as 4 everywhere;
    // matching that here is what lets `&tbl->array[i]` for a mutable global
    // pointer array stride correctly instead of falling back to a spurious load.)
    const e: Elem = if (eql(u8, elem_s, "ptr"))
        .{ .bits = 32, .signed = false, .float = false }
    else
        elemFromName(elem_s) orelse return null;
    // elem_size is the ABI STORAGE CELL size (the array stride), NOT the byte
    // width: a 33-63 bit element (u40/u48) lives in an 8-byte cell, so `(bits+7)/8`
    // (=5/6) would under-reserve the backing buffer and let a later scratch slot
    // (e.g. bitcast_slot) alias one element of a whole-array copy. elemSize matches
    // the stride the store/read already use (`__ld64`/`__st64` for 33-64 bit).
    return .{ .count = count, .elem_size = @intCast(elemSize(e)), .elem = e };
}

/// True if `tag` is an array wrapper whose ELEMENT is a struct, i.e.
/// `arr_<int>_<non-primitive>` (e.g. `arr_3_aos_P`, `arr_4_vec_4_f32`,
/// `arr_3_arr_3_i32`). Distinguishes arrays-of-structs from primitive arrays
/// (`arr_4_i32`, where the element parses as a primitive) and from sentinel
/// string wrappers (`arr_26s115_u8`, where the count fails to parse as an int).
fn isStructElemArrayTag(tag: []const u8) bool {
    if (!startsWith(u8, tag, "arr_")) {
        return false;
    }
    var it = splitScalar(u8, tag["arr_".len..], '_');
    const count_s_raw: []const u8 = it.next() orelse return false;
    const elem_s: []const u8 = it.next() orelse return false;
    // A sentinel array encodes its count as `<N>s<sentinelTypeId>` (e.g.
    // `arr_3s181_<enumTag>`); take the digits before `s`. A sentinel array whose
    // element is a NON-primitive (an enum-tag/struct typedef) is still an
    // array-of-aggregates and must be treated as a struct value — not diverted to
    // the scalar/string path (which read its first bytes as one number). A sentinel
    // u8/u32 array keeps a primitive element here, so it still returns false.
    var count_s: []const u8 = count_s_raw;
    if (indexOf(u8, count_s_raw, "s")) |si| {
        count_s = count_s_raw[0..si];
    }
    _ = parseInt(u32, count_s, 10) catch return false; // not an array wrapper count
    return elemFromName(elem_s) == null; // non-primitive element -> array of structs
}

/// Parse a C integer literal token (`1u`, `0x10`, `-3`, `42UL`) to its value,
/// stripping integer suffixes. Used for enum constant values.
fn parseCIntLiteral(text: []const u8) ?i64 {
    var s: []const u8 = text;
    while (s.len > 0) {
        const last: u8 = s[s.len - 1];
        if (last == 'u' or last == 'U' or last == 'l' or last == 'L') {
            s = s[0 .. s.len - 1];
        } else {
            break;
        }
    }
    if (s.len == 0) {
        return null;
    }
    return parseInt(i64, s, 0) catch null;
}

/// If `specs` name a fixed-array wrapper struct (`struct arr_..._...`), return
/// its array info. Used to size array globals and decode element accesses.
fn arrayStructInfo(specs: []const Token) ?ArrayInfo {
    for (specs) |t| {
        if (t.kind == .ident and startsWith(u8, t.text, "arr_")) {
            if (parseArrTag(t.text)) |info| {
                return info;
            }
        }
    }
    return null;
}

/// If `specs` is `struct <tag> ... *` (a pointer to a struct), return the tag.
// structPtrTagOf and structTagOf operate on *Transpiler, while Transpiler's own methods
// call them back (3 call sites) - a Transpiler<->helpers mutual recursion. Helpers-first
// costs one forward edge (this *Transpiler reference); the reverse order would cost two.
// lint:off decl-order: Transpiler<->structPtrTagOf/structTagOf mutual recursion
fn structPtrTagOf(self: *Transpiler, specs: []const Token) ?[]const u8 {
    var saw_struct: bool = false;
    var saw_star: bool = false;
    var tag: ?[]const u8 = null;
    for (specs) |t| {
        if (eql(u8, t.text, "*")) {
            saw_star = true;
        }
        if (eql(u8, t.text, "struct") or eql(u8, t.text, "union")) {
            saw_struct = true;
            continue;
        }
        if (t.kind == .ident and tag == null) {
            // A struct typedef alias (e.g. the C backend's `aligned__N_X`) implies a
            // struct even without the `struct` keyword — resolve it to the real tag.
            if (self.struct_aliases.get(t.text)) |real| {
                tag = real;
                continue;
            }
            if (saw_struct) {
                // Track pointers to clean primitive-array wrappers (`arr_4_i32 *` —
                // the inner row of a `[N][M]`), to STRUCT-element array wrappers
                // (`arr_2_aos_P *` — the inner row of a `[N][M]struct`, detected via
                // isStructElemArrayTag), and to non-array structs (named structs,
                // `vec_*`). Leave sentinel string wrappers (`arr_26s115_u8`,
                // parseArrTag-fail AND not a struct-elem array) to their string path.
                if (looksLikeArrayWrapper(t.text) and parseArrTag(t.text) == null and !isStructElemArrayTag(t.text)) {
                    return null;
                }
                tag = t.text;
            }
        }
    }
    return if (saw_star) tag else null;
}

/// Pointer depth: the number of `*` tokens in a type-specifier list. Used to
/// tell a single-star struct pointer (`struct X *`, deref = identity) from a
/// double-star one (`struct X **`, deref = a u32 pointer load).
fn countStars(specs: []const Token) usize {
    var n: usize = 0;
    for (specs) |t| {
        if (eql(u8, t.text, "*")) {
            n += 1;
        }
    }
    return n;
}

/// If `specs` is `struct <tag>` (no pointer), return the tag. Used to detect
/// struct-value locals/params. Skips the `arr_` wrapper structs (handled
/// separately) and anything with a '*' (those are pointers, not values).
fn structTagOf(self: *Transpiler, specs: []const Token) ?[]const u8 {
    var saw_struct: bool = false;
    var tag: ?[]const u8 = null;
    for (specs) |t| {
        if (eql(u8, t.text, "*")) {
            return null;
        } // pointer, not a value
        if (eql(u8, t.text, "struct") or eql(u8, t.text, "union")) {
            saw_struct = true;
            continue;
        }
        if (t.kind == .ident and tag == null) {
            // A struct typedef alias used as a VALUE (e.g. `aligned__N_X foo`)
            // resolves to the real struct tag.
            if (self.struct_aliases.get(t.text)) |real| {
                tag = real;
                continue;
            }
            if (saw_struct) {
                // Divert primitive-array wrappers (`arr_4_i32`, handled by
                // arrayStructInfo) AND sentinel string wrappers (`arr_26s115_u8`,
                // handled as data). Only an array whose element is itself a struct
                // (`arr_3_aos_P`, `arr_4_vec_4_f32`, `arr_3_arr_3_i32`) is treated as
                // a struct value here, so its `array` field indexes element structs.
                if (looksLikeArrayWrapper(t.text) and !isStructElemArrayTag(t.text)) {
                    return null;
                }
                tag = t.text;
            }
        }
    }
    return tag;
}

/// The struct/union tag of a by-value type, INCLUDING array wrappers
/// (`arr_N_T`). Unlike structTagOf this does not divert primitive-array
/// wrappers, because for nested struct-FIELD layout an `arr_N_T` member is a
/// real nested struct that must be sized by its layout (so `[N][M]T` and
/// `[N]Vec` fields get the element-struct stride). Returns null for pointers.
fn structTypeNameOf(specs: []const Token) ?[]const u8 {
    var saw_struct: bool = false;
    for (specs) |t| {
        if (eql(u8, t.text, "*")) {
            return null;
        } // pointer, not a value
        if (eql(u8, t.text, "struct") or eql(u8, t.text, "union")) {
            saw_struct = true;
            continue;
        }
        if (t.kind == .ident and saw_struct) {
            return t.text;
        }
    }
    return null;
}

// elem* — the bridge from a C element/field type (Elem) to how it's physically
// touched in the emitted JS. elemShift = log2 of the byte stride, elemSize =
// that stride in bytes, elemView = the typed-array view to index through
// (__HEAPU8 / __HEAP16 / __HEAPF64 / ...), and fieldElem just lifts a struct
// Field into the Elem those three expect. Codegen leans on these constantly to
// turn `*p` / `s.field` into the right `__MEM` view and index.
fn elemShift(e: Elem) u3 {
    return switch (e.bits) {
        8 => 0,
        16 => 1,
        // 64-bit floats use the 8-byte HEAPF64 view (shift 3). 64-bit ints keep
        // shift 2 because the scalar @bitCast/scratch idiom views them through the
        // 32-bit (low-word) array; their array/pointer STRIDE is 8 (see elemSize)
        // and real loads/stores go through __ld/st64, so values round-trip within
        // 2^53. (Only >2^53 magnitudes remain lossy — a JS Number limit.)
        64 => if (e.float) 3 else 2,
        else => 2, // 32-bit ints and f32
    };
}
fn elemSize(e: Elem) usize {
    // 64-bit ints/floats occupy 8 bytes — the array/pointer STRIDE — even though
    // 64-bit ints are viewed through the 32-bit (low-word) typed array. Keeping
    // stride and view-shift separate is what makes `&arr[i]` for i64/u64 land on
    // the right 8-byte element (the load/store itself reads two words via __ld64).
    if (e.bits > 32 and e.bits <= 64) {
        return 8;
    }
    return @as(usize, 1) << elemShift(e);
}

/// Byte size of a C primitive type name, used to resolve `sizeof(T)` and the
/// underlying width of a packed-struct (`bitpack__...`) typedef.
fn primSizeOf(name: []const u8) ?u32 {
    if (eql(u8, name, "uint8_t") or eql(u8, name, "int8_t") or eql(u8, name, "bool")) {
        return 1;
    }
    if (eql(u8, name, "uint16_t") or eql(u8, name, "int16_t")) {
        return 2;
    }
    if (eql(u8, name, "uint32_t") or eql(u8, name, "int32_t") or eql(u8, name, "float")) {
        return 4;
    }
    if (eql(u8, name, "uint64_t") or eql(u8, name, "int64_t") or eql(u8, name, "double")) {
        return 8;
    }
    return null;
}

fn fieldElem(f: Field) Elem {
    return .{ .bits = f.bits, .signed = f.signed, .float = f.float };
}

fn elemView(e: Elem) []const u8 {
    if (e.float) {
        return if (e.bits == 64) "__HEAPF64" else "__HEAPF32";
    }
    return switch (e.bits) {
        8 => if (e.signed) "__HEAP8" else "__HEAPU8",
        16 => if (e.signed) "__HEAP16" else "__HEAPU16",
        // 64-bit int loads/stores go through heapLoad/heapStore -> __ldi64/__ldu64/
        // __st64 (two 32-bit words), so this branch is reached only by the scalar
        // @bitCast/scratch idiom, which reads the low word — hence the 32-bit U32 view.
        64 => if (e.signed) "__HEAP32" else "__HEAPU32",
        else => if (e.signed) "__HEAP32" else "__HEAPU32",
    };
}

/// Build the heap-view Elem for a scalar CType (used to reinterpret a scalar
/// @bitCast through a typed view). bool occupies one byte.
fn elemOfTy(ty: CType) Elem {
    return switch (ty.kind) {
        .float => .{ .bits = ty.bits, .signed = false, .float = true },
        .boolean => .{ .bits = 8, .signed = false, .float = false },
        else => .{ .bits = if (ty.bits == 0) 32 else ty.bits, .signed = ty.signed, .float = false },
    };
}

/// Resolve a base C type keyword to width/signedness. Covers exactly what
/// Zig's C backend emits, plus the common builtin spellings.
fn baseType(name: []const u8) ?CType {
    if (eql(u8, name, "void")) {
        return .{ .kind = .void_ };
    }
    if (eql(u8, name, "bool") or eql(u8, name, "_Bool")) {
        return .{
            .kind = .boolean,
            .bits = 8,
            .signed = false,
        };
    }
    if (eql(u8, name, "float") or eql(u8, name, "zig_f32")) {
        return .{
            .kind = .float,
            .bits = 32,
            .signed = true,
        };
    }
    if (eql(u8, name, "double") or eql(u8, name, "zig_f64")) {
        return .{
            .kind = .float,
            .bits = 64,
            .signed = true,
        };
    }
    if (eql(u8, name, "uint8_t")) {
        return .{ .bits = 8, .signed = false };
    }
    if (eql(u8, name, "uint16_t")) {
        return .{ .bits = 16, .signed = false };
    }
    if (eql(u8, name, "uint32_t")) {
        return .{ .bits = 32, .signed = false };
    }
    if (eql(u8, name, "uint64_t")) {
        return .{ .bits = 64, .signed = false };
    }
    if (eql(u8, name, "int8_t")) {
        return .{ .bits = 8, .signed = true };
    }
    if (eql(u8, name, "int16_t")) {
        return .{ .bits = 16, .signed = true };
    }
    if (eql(u8, name, "int32_t")) {
        return .{ .bits = 32, .signed = true };
    }
    if (eql(u8, name, "int64_t")) {
        return .{ .bits = 64, .signed = true };
    }
    // 128-bit (the C backend's typedefs). Represented as BigInt in the emitted JS;
    // see bigInt128 and wrap()'s bits==128 case (no Number coercion).
    if (eql(u8, name, "zig_u128")) {
        return .{ .bits = 128, .signed = false };
    }
    if (eql(u8, name, "zig_i128")) {
        return .{ .bits = 128, .signed = true };
    }
    // wasm32 ABI: pointer-sized integers are 32-bit
    if (eql(u8, name, "size_t") or eql(u8, name, "uintptr_t")) {
        return .{
            .bits = 32,
            .signed = false,
        };
    }
    if (eql(u8, name, "ssize_t") or eql(u8, name, "ptrdiff_t") or
        eql(u8, name, "intptr_t"))
    {
        return .{
            .bits = 32,
            .signed = true,
        };
    }
    return null;
}

// Is this identifier a C type keyword/qualifier — something a declaration could
// start with? Covers the standard set plus the backend's `zig_*` specifiers,
// but NOT `zig_e_*` (how the backend escapes a real name that collides with a C
// keyword). Feeds looksLikeDecl and cast detection.
fn isTypeQualifierOrSpecifier(name: []const u8) bool {
    const kws = [_][]const u8{
        "const",  "volatile", "static",   "register", "inline",  "zig_extern",
        "extern", "signed",   "unsigned", "short",    "long",    "int",
        "char",   "struct",   "union",    "enum",     "_Atomic", "restrict",
    };
    for (kws) |k| {
        if (eql(u8, name, k)) {
            return true;
        }
    }
    // zig_ backend attributes (zig_nonstring, zig_align, ...) and types
    // (zig_f32, ...) are specifiers; but `zig_e_<name>` is how the backend
    // escapes an identifier that collides with a C keyword (a field/var named
    // `int`, `float`, ...), so those are real names, not specifiers. The noreturn
    // trap primitives (zig_unreachable/zig_trap) are FUNCTIONS, not types — exclude
    // them so a bare `zig_unreachable();` statement is parsed as a call (→ __panic)
    // instead of being mistaken for a declaration and dropped. The atomic helpers
    // (zig_atomic_store/_load, zig_atomicrmw_*, zig_cmpxchg_*, zig_fence) are FUNCTIONS
    // too and must be excluded for the same reason — but `zig_atomic` (no trailing
    // `_`) is the type macro used in casts `(zig_atomic(T) *)`, so it stays a specifier.
    if (startsWith(u8, name, "zig_") and !startsWith(u8, name, "zig_e_") and
        !eql(u8, name, "zig_unreachable") and !eql(u8, name, "zig_trap") and
        !startsWith(u8, name, "zig_atomic_") and !startsWith(u8, name, "zig_atomicrmw") and
        !startsWith(u8, name, "zig_cmpxchg") and !startsWith(u8, name, "zig_fence"))
    {
        return true;
    }
    return baseType(name) != null;
}

/// Compute a CType from a run of declaration-specifier tokens (e.g. `uint32_t const`,
/// `unsigned int`, `void`, or a pointer `... *`).
fn tyFromSpecifiers(toks: []const Token) CType {
    var base: CType = .{ .kind = .int, .bits = 32, .signed = true };
    var saw_base: bool = false;
    var saw_unsigned: bool = false;
    var saw_signed: bool = false;
    var long_count: u8 = 0;
    var saw_short: bool = false;
    var saw_int: bool = false;
    var saw_char: bool = false;
    var stars: u8 = 0;
    var saw_struct: bool = false;
    var struct_tag: ?[]const u8 = null;
    for (toks) |t| {
        if (eql(u8, t.text, "*")) {
            stars += 1;
            continue;
        }
        if (eql(u8, t.text, "struct") or eql(u8, t.text, "union")) {
            saw_struct = true;
            continue;
        }
        if (t.kind != .ident) {
            continue;
        }
        if (saw_struct and struct_tag == null) {
            // the identifier right after `struct`/`union` is the type tag
            struct_tag = t.text;
            continue;
        }
        if (baseType(t.text)) |b| {
            base = b;
            saw_base = true;
            continue;
        }
        if (eql(u8, t.text, "unsigned")) {
            saw_unsigned = true;
        }
        if (eql(u8, t.text, "signed")) {
            saw_signed = true;
        }
        if (eql(u8, t.text, "long")) {
            long_count += 1;
        }
        if (eql(u8, t.text, "short")) {
            saw_short = true;
        }
        if (eql(u8, t.text, "int")) {
            saw_int = true;
        }
        if (eql(u8, t.text, "char")) {
            saw_char = true;
        }
    }
    if (!saw_base and
        (saw_unsigned or saw_signed or saw_short or saw_int or saw_char or long_count > 0))
    {
        base = .{ .kind = .int, .bits = 32, .signed = !saw_unsigned };
        if (saw_char) {
            base.bits = 8;
        }
        if (saw_short) {
            base.bits = 16;
        }
        // wasm32 / ILP32 C ABI: `long` is 32-bit; only `long long` is 64-bit.
        if (long_count >= 2) {
            base.bits = 64;
        }
        if (saw_unsigned) {
            base.signed = false;
        }
        if (saw_signed) {
            base.signed = true;
        }
    }
    if (stars > 0) {
        const elem: Elem = .{
            .bits = if (base.kind == .void_) 8 else base.bits,
            .signed = base.signed,
            .float = base.kind == .float,
            // a single pointer to a struct carries the pointee tag, so element
            // strides/accesses (e.g. `slice.ptr[i].field`) size by the struct.
            .struct_tag = if (stars == 1) struct_tag else null,
        };
        return .{
            .kind = .ptr,
            .bits = 32,
            .signed = false,
            .elem = if (stars == 1) elem else null,
        };
    }
    return base;
}

// ----------------------------------------------------------------------------
// Statement AST + lowered control-flow ops
// ----------------------------------------------------------------------------

// Recursive statement AST: `Stmt` (below) is a union over these kinds, and each
// kind embeds `[]const Stmt` for its nested body. The reference cycle between
// `Stmt` and its kinds is irreducible — neither side can be fully declared before
// the other — so the forward reference to `Stmt` here is opted in deliberately.
// lint:off decl-order: Stmt<->statement-kind structs form a recursive AST cycle
const IfStmt = struct { cond: []const u8, then: []const Stmt, els: ?[]const Stmt };
const WhileStmt = struct { cond: []const u8, body: []const Stmt };
const ForStmt = struct { init: ?[]const u8, cond: ?[]const u8, step: ?[]const u8, body: []const Stmt };
const Case = struct { value: ?[]const u8, body: []const Stmt }; // value null => default
const SwitchStmt = struct { expr: []const u8, cases: []const Case };

const Stmt = union(enum) {
    raw: struct { text: []const u8, src: u32 = 0 }, // a JS expr/assignment, emitted as `<text>;`
    ret: struct { val: ?[]const u8, src: u32 = 0 }, // already-wrapped return expr
    label: []const u8,
    goto: []const u8,
    brk,
    cont,
    block: []const Stmt,
    if_: IfStmt,
    while_: WhileStmt,
    for_: ForStmt,
    switch_: SwitchStmt,
    empty,
};

/// Lowered, flat control-flow op (no nesting except inside `line`/`cgoto` text).
const FlowOp = union(enum) {
    line: struct { text: []const u8, src: u32 = 0 }, // emit `<text>;`, from C line `src`
    ret: struct { val: ?[]const u8, src: u32 = 0 },
    label: []const u8, // a state boundary
    goto: []const u8,
    cgoto: struct { cond: []const u8, target: []const u8 }, // if(cond) goto target
};

const Local = struct { name: []const u8, dflt: []const u8 };

// ----------------------------------------------------------------------------
// Transpiler
// ----------------------------------------------------------------------------

const VarInfo = struct { ty: CType };

// The parser AND code generator in one object. One Transpiler is built per
// program (init); `run` drives the whole show. It walks the token slice `toks`
// with a cursor `p` and appends finished JavaScript to `out` as it goes — there
// is no whole-program AST, so parsing an expression and emitting its JS are the
// same step. The pile of StringHashMaps below are the symbol tables: the
// prescans fill some (globals/structs/typedefs/enums/recursion), the rest
// accumulate while functions are parsed. The block after `ret_ty` is
// per-function scratch, reset for each new body.
const Transpiler = struct {
    gpa: Allocator, // arena: all allocations come from here, freed together at exit
    toks: []const Token, // the whole program as one flat token slice (from the lexer)
    p: usize = 0, // parse cursor: index of the next unconsumed token in `toks`
    out: ArrayList(u8) = .empty, // the JavaScript being built up as we parse + lower
    diags: ArrayList([]const u8) = .empty, // places we had to GUESS; reported with the markers
    diag_count: usize = 0, // same, but alloc-free so the gate can never be lost to OOM
    // source-map state: as tokens are consumed, `cur_src_line` follows the C
    // line of the current token. `emit` records (generated-line -> cur_src_line)
    // whenever it starts a new output line, building a JS->C line map.
    cur_src_line: u32 = 0,
    gen_line: u32 = 1, // 1-based current line in `out`
    at_line_start: bool = true,
    line_map: ArrayList(LineMap) = .empty,
    defines: StringHashMap([]const u8),
    vars: StringHashMap(VarInfo),
    structs: StringHashMap(StructLayout),
    globals: StringHashMap(u32), // static data name -> heap offset
    array_elems: StringHashMap(Elem), // array global/local name -> element type
    struct_vars: StringHashMap([]const u8), // struct local/global name -> struct tag
    struct_ptrs: StringHashMap([]const u8), // struct-pointer temp name -> pointee struct tag
    // Pointer-to-pointer struct pointers (`struct X **`). A SINGLE-star struct
    // pointer holds a struct's heap offset, so `*p` is identity (the offset
    // itself). A DOUBLE-star one is the address of a slot that holds a struct
    // pointer, so `*pp` must LOAD the stored pointer (a 4-byte offset) — EXCEPT
    // the Zig C-backend's address-of-local round-trip (`pp = &localStructPtr;
    // *pp`), where `&` collapsed a bare (non-heap-backed) local and `*` must
    // hand it straight back. `pp_load` records the temps whose `*` LOADS;
    // membership is decided at the assignment via `addr_local_collapse`, which
    // separates a heap `&ptr->field`/`&var.field`/param address (load) from the
    // bare-`&local` collapse (identity). Struct-pointer locals are never heap-
    // backed (they short-circuit at `structPtrTagOf`), so their `&` always
    // collapses and the round-trip is always identity; a pp param, by contrast,
    // arrives holding a real heap address, so it defaults to load.
    pp_struct_ptrs: StringHashMap(void), // double-star struct-pointer names
    pp_load: StringHashMap(void), // pp struct pointers whose `*` LOADS (vs identity)
    typedefs: StringHashMap(void), // names introduced by `typedef ... NAME;` (e.g. enum tag types)
    // simple `typedef <prim> NAME;` (e.g. enum tag `typedef uint8_t enum__...;`)
    // -> underlying scalar CType, so casts/derefs use the real width
    type_aliases: StringHashMap(CType),
    // `typedef struct TAG NAME;` (e.g. the C backend's `aligned__N_X`) -> real
    // struct TAG; alignment is irrelevant in the heap-offset model
    struct_aliases: StringHashMap([]const u8),
    bitpack_sizes: StringHashMap(u32), // packed-struct typedef name (`bitpack__...`) -> byte size
    recursive_fns: StringHashMap(void), // function names in a call-graph cycle (direct or mutual)
    // SHADOW STACK (recursive functions only). Address-taken locals normally get a
    // fixed static scratch slot (fast, reused — but NOT reentrant). In a recursive
    // function that would clobber a live frame across calls, so there each such local
    // instead gets a frame-relative offset here and the function bumps __SP on entry /
    // restores it on exit (the standard wasm/LLVM shadow stack). Non-recursive
    // functions are untouched, so the common path keeps the zero-overhead static slot.
    frame_off: StringHashMap(u32), // per-fn (recursive only): local name -> offset within its stack frame
    frame_size: u32 = 0, // per-fn: total bytes the current recursive function's frame needs
    fn_index: StringHashMap(u32), // every defined function name -> 1-based __FTABLE index (0 = null fn-ptr)
    fn_table: ArrayList([]const u8), // function names in index order (for emitting __FTABLE)
    // per-fn: locals declared `RET (*name)(...)` — calling one dispatches via __FTABLE
    fn_ptr_vars: StringHashMap(void),
    uses_fn_ptr: bool, // some `&<function>` appears as a value -> emit the dispatch table
    // SAFE_HEAP debug mode: route every heap access through __idx()
    // bounds/alignment/null checks (opt-in; release output is unchanged)
    safe: bool = false,
    cur_fn: []const u8 = "", // name of the function currently being lowered
    // Width of the most recently parsed expression, in bits: 64 or 128 means it is a
    // BigInt in the emitted JS, anything else (0/8/16/32) is a Number. Set by the
    // expression leaves (parsePrimary) and propagated by parseUnary/parsePostfix/
    // parseBinary, so a cast/assignment can tell whether to convert BigInt<->Number at a
    // width boundary. Best-effort: an unrecognized leaf leaves it 0 (treated as Number).
    last_w: u16 = 0,
    bitcast_slot: ?u32 = null, // shared 8-byte scratch for scalar @bitCast (memcpy idiom)
    pending_struct_tag: ?[]const u8 = null, // tag of the struct a just-parsed primary yielded
    // scalar pointee of a just-parsed pointer-cast primary (`(T*)x`), for a following `[i]`
    pending_ptr_elem: ?Elem = null,
    //   (e.g. a compound literal), so a following `.array[i]` postfix can resolve it
    data: ArrayList(u8) = .empty, // initialized bytes, laid out from data_base
    data_base: u32 = 1024, // keep low addresses (and 0 = null) clear
    // Deferred pointer relocations: a MUTABLE global's static initializer may
    // contain `&otherGlobal` (a pointer/slice field, or an element of a global
    // pointer array). The pointee's heap offset isn't known until every global
    // has been laid out (forward references), so the `&global` write is recorded
    // here and patched into the data image at the end of prescanScalarGlobals.
    // (A const global's pointer derefs are value-propagated by the C backend, so
    // they never read the data image; a `var` one does — hence this is needed.)
    pending_relocs: ArrayList(Reloc) = .empty,
    heap_top: u32 = 1024, // next free heap offset; set past `data` after prescan,
    // then bumped for local/global scratch WITHOUT growing the emitted image.
    ret_ty: CType = .{}, // return type of the function being lowered (for return coercions)

    // per-function lowering state
    locals: ArrayList(Local) = .empty, // current function's declared locals; reset per fn
    local_array_names: ArrayList([]const u8) = .empty, // local-array scratch names to purge per fn
    addr_taken: StringHashMap(void) = undefined, // per-fn: local names whose bare address is taken (`&x`)
    scalar_slots: StringHashMap(u32) = undefined, // per-fn: address-taken SCALAR local -> heap slot offset
    brk_stack: ArrayList([]const u8) = .empty,
    cont_stack: ArrayList([]const u8) = .empty,
    lbl_counter: usize = 0, // monotonic; mints unique __L<n> goto labels
    tmp_counter: usize = 0, // monotonic; mints unique scratch temp names
    // Transient: set true when the `&` handler collapses a bare (non-heap-backed)
    // local to a value passthrough (`&t0` -> `(t0)`), i.e. the address-of-local
    // round-trip. Read right after an assignment RHS to decide whether a pp
    // struct-pointer temp aliases a local (identity deref) or holds a heap
    // address (load deref). Reset before each tracked `=` assignment RHS.
    addr_local_collapse: bool = false,

    // Build a fresh Transpiler over the lexed tokens + the #define map from
    // preprocess. The hashmaps the prescans and parser fill start out empty here.
    fn init(
        gpa: Allocator,
        toks: []const Token,
        defines: StringHashMap([]const u8),
        safe: bool,
    ) Transpiler {
        return .{
            .gpa = gpa,
            .toks = toks,
            .defines = defines,
            .vars = StringHashMap(VarInfo).init(gpa),
            .structs = StringHashMap(StructLayout).init(gpa),
            .globals = StringHashMap(u32).init(gpa),
            .array_elems = StringHashMap(Elem).init(gpa),
            .struct_vars = StringHashMap([]const u8).init(gpa),
            .struct_ptrs = StringHashMap([]const u8).init(gpa),
            .pp_struct_ptrs = StringHashMap(void).init(gpa),
            .pp_load = StringHashMap(void).init(gpa),
            .typedefs = StringHashMap(void).init(gpa),
            .type_aliases = StringHashMap(CType).init(gpa),
            .struct_aliases = StringHashMap([]const u8).init(gpa),
            .bitpack_sizes = StringHashMap(u32).init(gpa),
            .addr_taken = StringHashMap(void).init(gpa),
            .scalar_slots = StringHashMap(u32).init(gpa),
            .recursive_fns = StringHashMap(void).init(gpa),
            .frame_off = StringHashMap(u32).init(gpa),
            .fn_index = StringHashMap(u32).init(gpa),
            .fn_table = .empty,
            .fn_ptr_vars = StringHashMap(void).init(gpa),
            .uses_fn_ptr = false,
            .safe = safe,
        };
    }

    // --- token helpers ---
    // The recursive-descent primitives, used everywhere below: peek/peekAt look
    // without consuming, is/eat test (and eat consumes) the current token's text,
    // and expect consumes the expected text or — to keep limping forward on input
    // we didn't model — just skips one token.
    // --- parser cursor primitives (operate on `toks` at position `p`) ---
    // current()      : the token under the cursor (eof past the end)
    // lookahead(n)   : the token n positions ahead, without moving
    // atText(s)      : does the current token's text equal s?
    // consume(s)     : if atText(s), advance past it and return true; else false
    // expect(s)      : consume(s), but tolerantly skip one token if it's missing
    fn current(self: *Transpiler) Token {
        return if (self.p < self.toks.len) self.toks[self.p] else .{ .kind = .eof, .text = "" };
    }
    fn lookahead(self: *Transpiler, off: usize) Token {
        const idx: usize = self.p + off;
        return if (idx < self.toks.len) self.toks[idx] else .{ .kind = .eof, .text = "" };
    }
    fn atText(self: *Transpiler, text: []const u8) bool {
        return eql(u8, self.current().text, text);
    }
    fn consume(self: *Transpiler, text: []const u8) bool {
        if (self.atText(text)) {
            self.p += 1;
            return true;
        }
        return false;
    }
    fn expect(self: *Transpiler, text: []const u8) void {
        if (!self.consume(text)) {
            // tolerant: skip a token to make progress
            self.p += 1;
        }
    }

    // --- emit helpers ---
    // emit appends raw text and, on the first character of each new output line,
    // logs a (generated-line -> current-C-line) pair — that running log IS the
    // source map (see buildSourceMap). print is the printf-style cousin but writes
    // straight to `out` WITHOUT touching the line counters, so only use it for
    // fragments within a line.
    fn emit(self: *Transpiler, s: []const u8) !void {
        for (s) |ch| {
            // At the first character of each generated line, record which C line
            // it corresponds to (line-granular source map).
            if (self.at_line_start and ch != '\n' and self.cur_src_line != 0) {
                try self.line_map.append(
                    self.gpa,
                    .{ .gen = self.gen_line, .src = self.cur_src_line },
                );
                self.at_line_start = false;
            }
            try self.out.append(self.gpa, ch);
            if (ch == '\n') {
                self.gen_line += 1;
                self.at_line_start = true;
            }
        }
    }
    fn print(
        self: *Transpiler,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const s: []u8 = try allocPrint(self.gpa, fmt, args);
        try self.out.appendSlice(self.gpa, s);
    }

    // Resolve an identifier through the #define renames (mangled -> friendly name),
    // with NULL/nullptr folded to "0" since a null pointer is heap offset 0 here.
    fn applyDefine(self: *Transpiler, name: []const u8) []const u8 {
        if (self.defines.get(name)) |v| {
            return v;
        }
        // NULL / nullptr come from system headers we don't include; a null
        // pointer is heap offset 0 in this model (used by optional pointers
        // `?*T = null` and their `p != NULL` checks).
        if (eql(u8, name, "NULL") or eql(u8, name, "nullptr")) {
            return "0";
        }
        return name;
    }

    // Is the current token the identifier `text`? (Stricter than `is`: requires an
    // ident, so a punctuator can't masquerade as a keyword.)
    fn isKw(self: *Transpiler, text: []const u8) bool {
        const t: Token = self.current();
        return t.kind == .ident and eql(u8, t.text, text);
    }
    // Mint a unique `__L<n>` label for goto-style lowering (see flatten/emitBody).
    fn freshLabel(self: *Transpiler) ![]const u8 {
        const s: []u8 = try allocPrint(self.gpa, "__L{d}", .{self.lbl_counter});
        self.lbl_counter += 1;
        return s;
    }

    // ------------------------------------------------------------------------
    // Top level
    // ------------------------------------------------------------------------
    fn run(self: *Transpiler) !void {
        // record enum constants and typedefs FIRST: struct layouts (computed inside
        // prescanData) size their fields via tyFromSpecifiers, which resolves typedef
        // element types (e.g. a packed-struct `bitpack__...` -> u64, or an enum tag
        // `enum__...` -> u8) through type_aliases/bitpack_sizes. If those run after the
        // layouts, a typedef'd element silently defaults to a 32-bit int — so an array
        // of an 8-byte packed struct strided by 4 and the elements overlapped.
        try self.prescanEnums();
        try self.prescanTypedefs();
        // pre-pass: assign heap offsets to initialized string-data statics (also
        // computes struct layouts + lays out scalar/aggregate globals)
        try self.prescanData();
        // record recursive functions (to flag non-reentrant local-aggregate scratch)
        try self.prescanRecursion();
        // Everything past the initialized image is free scratch space. Scratch for
        // locals/globals is bump-allocated from here at parse time and is NOT added
        // to the emitted image (the ArrayBuffer is zero-initialized, and scratch is
        // always written before read), so the data blob stays minimal.
        self.heap_top = self.data_base + @as(u32, @intCast(self.data.items.len));

        try self.emit(
            \\// Generated by c_to_js.zig. Unreadable on purpose.
            \\"use strict";
            \\// --- linear memory runtime ---
            \\const __MEM = new ArrayBuffer(16 * 1024 * 1024, { maxByteLength: 256 * 1024 * 1024 });
            \\const __HEAP8 = new Int8Array(__MEM), __HEAPU8 = new Uint8Array(__MEM);
            \\const __HEAP16 = new Int16Array(__MEM), __HEAPU16 = new Uint16Array(__MEM);
            \\const __HEAP32 = new Int32Array(__MEM), __HEAPU32 = new Uint32Array(__MEM);
            \\const __HEAPF32 = new Float32Array(__MEM), __HEAPF64 = new Float64Array(__MEM);
            \\const __HEAPU64 = new BigUint64Array(__MEM), __HEAP64 = new BigInt64Array(__MEM);
            \\// @wasmMemorySize/@wasmMemoryGrow: pages are 64 KiB. __MEM is resizable
            \\// (initial 16 MB, growable above), and the typed views over it are
            \\// length-tracking, so they keep working after a resize. grow returns the
            \\// OLD page count (or -1 if it can't extend), matching wasm semantics.
            \\function __wmsize() { return (__MEM.byteLength / 65536) | 0; }
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function __wmgrow(delta) { const old = (__MEM.byteLength / 65536) | 0; delta = delta | 0; if (delta < 0) return -1; try { __MEM.resize((old + delta) * 65536); } catch (e) { return -1; } return old; }
            \\// Shadow stack for address-taken locals of recursive functions. Grows DOWN
            \\// from the top of the INITIAL 16 MB (grown pages extend above it, as in the
            \\// wasm/LLVM layout); static data grows up from low addresses.
            \\let __SP = 16 * 1024 * 1024;
            \\
        );
        if (self.safe) {
            // SAFE_HEAP (opt-in via --safe): every typed-view access is wrapped in
            // __idx(addr,size), the byte-copy / 64-bit helpers range-check, and the
            // program-supplied pointers that reach kernel helpers (call-argument arrays
            // via __ckargs, the js_try_call out-pointer via __cku32) are bounds-checked
            // too, so a miscompiled offset/stride or a wild user pointer faults LOUDLY at
            // the exact address instead of silently reading or clobbering the wrong cell.
            // Release builds reduce __ckargs/__cku32 to inlined no-ops, so the hot paths
            // keep the same shape and cost.
            try self.emit(
                \\// --- SAFE_HEAP (debug): bounds / alignment / null checks on every access ---
                // lint:off line-length: emitted-JS template — one source line is one output line
                \\function __fault(a, sz, why) { throw new RangeError("wz SAFE_HEAP: " + why + " " + sz + "-byte access at address " + a); }
                // lint:off line-length: emitted-JS template — one source line is one output line
                \\function __idx(a, sz) { if ((a | 0) !== a) __fault(a, sz, "non-integer"); if (a <= 0) __fault(a, sz, "null/negative"); if (a + sz > __MEM.byteLength) __fault(a, sz, "out-of-bounds"); if (a & (sz - 1)) __fault(a, sz, "misaligned"); return a; }
                // lint:off line-length: emitted-JS template — one source line is one output line
                \\function __idx64(a) { if ((a | 0) !== a) __fault(a, 8, "non-integer"); if (a <= 0) __fault(a, 8, "null/negative"); if (a + 8 > __MEM.byteLength) __fault(a, 8, "out-of-bounds"); return a; }
                // lint:off line-length: emitted-JS template — one source line is one output line
                \\function __ckrange(a, n, what) { if ((a | 0) !== a || a < 0 || a + n > __MEM.byteLength) __fault(a, n, what); }
                // lint:off line-length: emitted-JS template — one source line is one output line
                \\function __copy(dst, src, n) { __ckrange(dst, n, "copy-dst"); __ckrange(src, n, "copy-src"); __HEAPU8.copyWithin(dst, src, src + n); return dst; }
                // lint:off line-length: emitted-JS template — one source line is one output line
                \\function memcpy(d, s, n) { __ckrange(d, n, "memcpy-dst"); __ckrange(s, n, "memcpy-src"); __HEAPU8.copyWithin(d, s, s + n); return d; }
                // lint:off line-length: emitted-JS template — one source line is one output line
                \\function memmove(d, s, n) { __ckrange(d, n, "memmove-dst"); __ckrange(s, n, "memmove-src"); __HEAPU8.copyWithin(d, s, s + n); return d; }
                \\function memset(d, v, n) { __ckrange(d, n, "memset"); __HEAPU8.fill(v & 255, d, d + n); return d; }
                \\// program-supplied pointers reaching kernel helpers (arg arrays, out-params)
                // lint:off line-length: emitted-JS template — one source line is one output line
                \\function __ckargs(argp, n) { if (n === 0) return; if ((argp & 3) !== 0) __fault(argp, 4, "call-args misaligned"); __ckrange(argp, n * 4, "call-args"); }
                \\function __cku32(p) { __idx(p, 4); }
                \\
            );
        } else {
            try self.emit(
                \\// copy `n` bytes within the heap (struct-by-value copies); returns dst.
                \\function __copy(dst, src, n) { __HEAPU8.copyWithin(dst, src, src + n); return dst; }
                \\// libc primitives the C backend sometimes emits (e.g. 64-bit moves).
                \\function memcpy(d, s, n) { __HEAPU8.copyWithin(d, s, s + n); return d; }
                \\function memmove(d, s, n) { __HEAPU8.copyWithin(d, s, s + n); return d; }
                \\function memset(d, v, n) { __HEAPU8.fill(v & 255, d, d + n); return d; }
                \\function __ckargs() {}
                \\function __cku32() {}
                \\
            );
        }
        try self.emit(
            \\// panic / trap: a reached `unreachable`, an @trap(), or the tail of a safety
            \\// panic (integer overflow, bounds, etc.). Throwing halts loudly instead of
            \\// silently falling through (which would wrap and return a wrong value).
            \\function __panic(m) { throw new Error("panic: " + (m || "reached unreachable code")); }
            \\// bit builtins (width-aware): @clz/@ctz/@popCount/@byteSwap/@bitReverse.
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function __clz(x, n) { if (n <= 32) return Math.clz32(x >>> 0) - (32 - n); var h = Number((x >> 32n) & 0xFFFFFFFFn), l = Number(x & 0xFFFFFFFFn); var c = h !== 0 ? Math.clz32(h) : 32 + Math.clz32(l); return c - (64 - n); }
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function __ctz(x, n) { if (n <= 32) { if (x === 0) return n; var l = x >>> 0; return 31 - Math.clz32(l & -l); } if (x === 0n) return n; var lo = Number(x & 0xFFFFFFFFn); if (lo !== 0) return 31 - Math.clz32(lo & -lo); var hi = Number((x >> 32n) & 0xFFFFFFFFn); return 32 + (31 - Math.clz32(hi & -hi)); }
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function __popcnt32(x) { x = x >>> 0; x = x - ((x >>> 1) & 0x55555555); x = (x & 0x33333333) + ((x >>> 2) & 0x33333333); return (((x + (x >>> 4)) & 0x0f0f0f0f) * 0x01010101) >>> 24; }
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function __popcount(x, n) { return n <= 32 ? __popcnt32(x) : __popcnt32(Number(x & 0xFFFFFFFFn)) + __popcnt32(Number((x >> 32n) & 0xFFFFFFFFn)); }
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function __byteswap(x, n) { if (n > 32) { var rb = 0n, j = 0; for (; j < n / 8; j++) { rb = (rb << 8n) | (x & 0xFFn); x >>= 8n; } return rb; } var b = n / 8, r = 0, k = 0; for (; k < b; k++) r = r * 256 + (Math.floor(x / Math.pow(256, k)) & 255); return r; }
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function __bitreverse(x, n) { if (n > 32) { var rb = 0n, j = 0; for (; j < n; j++) { rb = (rb << 1n) | (x & 1n); x >>= 1n; } return rb; } var r = 0, k = 0; for (; k < n; k++) r = r * 2 + (Math.floor(x / Math.pow(2, k)) % 2); return r; }
            \\// 64-bit bitwise via hi/lo 32-bit halves (helper-form ops only; correct within 2^53).
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function __band64(a, b) { var hi = (Math.floor(a / 4294967296) & Math.floor(b / 4294967296)) >>> 0; var lo = ((a >>> 0) & (b >>> 0)) >>> 0; return hi * 4294967296 + lo; }
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function __bor64(a, b) { var hi = (Math.floor(a / 4294967296) | Math.floor(b / 4294967296)) >>> 0; var lo = ((a >>> 0) | (b >>> 0)) >>> 0; return hi * 4294967296 + lo; }
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function __bxor64(a, b) { var hi = (Math.floor(a / 4294967296) ^ Math.floor(b / 4294967296)) >>> 0; var lo = ((a >>> 0) ^ (b >>> 0)) >>> 0; return hi * 4294967296 + lo; }
            \\// 64-bit integer heap load/store: two 32-bit words, little-endian, exact within 2^53.
            \\
        );
        if (self.safe) {
            try self.emit(
                // lint:off line-length: emitted-JS template — one source line is one output line
                \\function __ldu64(a) { __idx64(a); return (a & 7) === 0 ? __HEAPU64[a >> 3] : (BigInt(__HEAPU32[a >> 2] >>> 0) | (BigInt(__HEAPU32[(a >> 2) + 1] >>> 0) << 32n)); }
                // lint:off line-length: emitted-JS template — one source line is one output line
                \\function __ldi64(a) { __idx64(a); return (a & 7) === 0 ? __HEAP64[a >> 3] : BigInt.asIntN(64, BigInt(__HEAPU32[a >> 2] >>> 0) | (BigInt(__HEAPU32[(a >> 2) + 1] >>> 0) << 32n)); }
                // lint:off line-length: emitted-JS template — one source line is one output line
                \\function __st64(a, v) { __idx64(a); if ((a & 7) === 0) { __HEAPU64[a >> 3] = v; } else { var i = a >> 2; __HEAPU32[i] = Number(v & 0xFFFFFFFFn); __HEAPU32[i + 1] = Number((v >> 32n) & 0xFFFFFFFFn); } return v; }
                \\
            );
        } else {
            try self.emit(
                // lint:off line-length: emitted-JS template — one source line is one output line
                \\function __ldu64(a) { return (a & 7) === 0 ? __HEAPU64[a >> 3] : (BigInt(__HEAPU32[a >> 2] >>> 0) | (BigInt(__HEAPU32[(a >> 2) + 1] >>> 0) << 32n)); }
                // lint:off line-length: emitted-JS template — one source line is one output line
                \\function __ldi64(a) { return (a & 7) === 0 ? __HEAP64[a >> 3] : BigInt.asIntN(64, BigInt(__HEAPU32[a >> 2] >>> 0) | (BigInt(__HEAPU32[(a >> 2) + 1] >>> 0) << 32n)); }
                // lint:off line-length: emitted-JS template — one source line is one output line
                \\function __st64(a, v) { if ((a & 7) === 0) { __HEAPU64[a >> 3] = v; } else { var i = a >> 2; __HEAPU32[i] = Number(v & 0xFFFFFFFFn); __HEAPU32[i + 1] = Number((v >> 32n) & 0xFFFFFFFFn); } return v; }
                \\
            );
        }
        try self.emit(
            \\// saturating-arithmetic clamps (unsigned / signed) to an N-bit range.
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function __clampu(v, n) { if (typeof v === 'bigint') { var hb = (1n << BigInt(n)) - 1n; return v < 0n ? 0n : (v > hb ? hb : v); } var hi = n >= 53 ? 9007199254740991 : Math.pow(2, n) - 1; return v < 0 ? 0 : (v > hi ? hi : v); }
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function __clampi(v, n) { if (typeof v === 'bigint') { var hb = (1n << BigInt(n - 1)) - 1n, lb = -(1n << BigInt(n - 1)); return v < lb ? lb : (v > hb ? hb : v); } var hi = Math.pow(2, n - 1) - 1, lo = -Math.pow(2, n - 1); return v < lo ? lo : (v > hi ? hi : v); }
            \\function __fmin(a, b) { return a !== a ? b : (b !== b ? a : Math.min(a, b)); }
            \\function __fmax(a, b) { return a !== a ? b : (b !== b ? a : Math.max(a, b)); }
            \\
        );
        // emit the data section as one base64 blob splat into the heap
        if (self.data.items.len > 0) {
            const b64: []u8 = try base64Encode(self.gpa, self.data.items);
            try self.print(
                "__HEAPU8.set(Uint8Array.from(atob(\"{s}\"), c => c.charCodeAt(0)), {d});\n",
                .{ b64, self.data_base },
            );
        }
        // --- JS interop kernel (the only hand-written JS; lives here, never edited) ---
        try self.emit(
            \\const __dec = new TextDecoder("utf-8"), __enc = new TextEncoder();
            \\const __nc = new Map(); // memo: comptime method/property name addr -> decoded string
            \\const __H = [null, (typeof globalThis !== "undefined" ? globalThis : this)];
            \\let __Hf = [];
            \\function __href(o) { const i = __Hf.length ? __Hf.pop() : __H.length; __H[i] = o; return i; }
            \\const __SCR = new Uint8Array(65536);
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function __cp(p, l) { if (l > 65536) return __HEAPU8.slice(p, p + l); __SCR.set(__HEAPU8.subarray(p, p + l)); return __SCR.subarray(0, l); }
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function __jstr(p, l) { let s = __nc.get(p); if (s === undefined) { s = __dec.decode(l < 256 ? __HEAPU8.slice(p, p + l) : __cp(p, l)); __nc.set(p, s); } return s; }
            \\function js_global() { return 1; }
            \\function js_get(o, p, l) { return __href(__H[o][__jstr(p, l)]); }
            \\function js_get_num(o, p, l) { return +__H[o][__jstr(p, l)]; }
            \\function js_get_index(o, i) { return __href(__H[o][i]); }
            \\function js_set(o, p, l, v) { __H[o][__jstr(p, l)] = __H[v]; }
            \\function js_set_num(o, p, l, x) { __H[o][__jstr(p, l)] = x; }
            \\function js_call0(o, p, l) { const f = __H[o][__jstr(p, l)]; return __href(f.call(__H[o])); }
            \\function js_call1(o, p, l, a) { const f = __H[o][__jstr(p, l)]; return __href(f.call(__H[o], __H[a])); }
            \\function js_call0v(o,p,l){__H[o][__jstr(p,l)].call(__H[o]);}
            \\function js_call1v(o,p,l,a){__H[o][__jstr(p,l)].call(__H[o],__H[a]);}
            \\function js_call2v(o,p,l,a,b){__H[o][__jstr(p,l)].call(__H[o],__H[a],__H[b]);}
            \\function js_call3v(o,p,l,a,b,c){__H[o][__jstr(p,l)].call(__H[o],__H[a],__H[b],__H[c]);}
            \\function js_call4v(o,p,l,a,b,c,d){__H[o][__jstr(p,l)].call(__H[o],__H[a],__H[b],__H[c],__H[d]);}
            \\function js_call5v(o,p,l,a,b,c,d,e){__H[o][__jstr(p,l)].call(__H[o],__H[a],__H[b],__H[c],__H[d],__H[e]);}
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function js_read_into(dst,srcMem,srcOff,len){new Uint8Array(__MEM,dst,len).set(new Uint8Array(__H[srcMem].buffer,srcOff,len));}
            \\function js_calln1(o,p,l,a){return __href(__H[o][__jstr(p,l)].call(__H[o],a));}
            \\function js_calln2(o,p,l,a,b){return __href(__H[o][__jstr(p,l)].call(__H[o],a,b));}
            \\function js_calln3(o,p,l,a,b,c){return __href(__H[o][__jstr(p,l)].call(__H[o],a,b,c));}
            \\function js_calln4(o,p,l,a,b,c,d){return __href(__H[o][__jstr(p,l)].call(__H[o],a,b,c,d));}
            \\function js_calln5(o,p,l,a,b,c,d,e){return __href(__H[o][__jstr(p,l)].call(__H[o],a,b,c,d,e));}
            \\function js_calln6(o,p,l,a,b,c,d,e,g){return __href(__H[o][__jstr(p,l)].call(__H[o],a,b,c,d,e,g));}
            \\function js_calln1v(o,p,l,a){__H[o][__jstr(p,l)].call(__H[o],a);}
            \\function js_calln2v(o,p,l,a,b){__H[o][__jstr(p,l)].call(__H[o],a,b);}
            \\function js_calln3v(o,p,l,a,b,c){__H[o][__jstr(p,l)].call(__H[o],a,b,c);}
            \\function js_calln4v(o,p,l,a,b,c,d){__H[o][__jstr(p,l)].call(__H[o],a,b,c,d);}
            \\function js_calln5v(o,p,l,a,b,c,d,e){__H[o][__jstr(p,l)].call(__H[o],a,b,c,d,e);}
            \\function js_calln6v(o,p,l,a,b,c,d,e,g){__H[o][__jstr(p,l)].call(__H[o],a,b,c,d,e,g);}
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function js_call2(o, p, l, a, b) { const f = __H[o][__jstr(p, l)]; return __href(f.call(__H[o], __H[a], __H[b])); }
            \\function js_new0(c) { return __href(new (__H[c])()); }
            \\function js_str(p, l) { return __href(__dec.decode(l < 256 ? __HEAPU8.slice(p, p + l) : __cp(p, l))); }
            \\function js_num(x) { return __href(x); }
            \\function js_to_num(v) { return +__H[v]; }
            \\function js_is_null(v) { return (__H[v] == null) ? 1 : 0; }
            \\function js_free(v) { if (v > 1 && __H[v] !== undefined) { __H[v] = undefined; __Hf.push(v); } }
            \\function js_mark() { return __H.length; }
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function js_reset(m) { while (__H.length > m) __H.pop(); if (__Hf.length) __Hf = __Hf.filter(function (i) { return i < m; }); }
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function js_func(f) { return __href(function(...args) { const hs = args.map(__href); const r = __FTABLE[f](...hs); for (let i = 0; i < hs.length; i++) js_free(hs[i]); return r; }); }
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function js_func_ctx(f,ctx) { return __href(function(...args) { const hs = args.map(__href); const r = __FTABLE[f](ctx, ...hs); for (let i = 0; i < hs.length; i++) js_free(hs[i]); return r; }); }
            \\function js_obj() { return __href({}); }
            \\function js_fn_raw(f) { return __href(function(...args) { return __FTABLE[f](...args); }); }
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function js_fn_num(f) { return __href(function(...a) { return __FTABLE[f](...a.map(x => typeof x === "bigint" ? Number(x) : x)); }); }
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function js_call3(o,p,l,a,b,c){const f=__H[o][__jstr(p,l)];return __href(f.call(__H[o],__H[a],__H[b],__H[c]));}
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function js_call4(o,p,l,a,b,c,d){const f=__H[o][__jstr(p,l)];return __href(f.call(__H[o],__H[a],__H[b],__H[c],__H[d]));}
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function js_call5(o,p,l,a,b,c,d,e){const f=__H[o][__jstr(p,l)];return __href(f.call(__H[o],__H[a],__H[b],__H[c],__H[d],__H[e]));}
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function js_call6(o,p,l,a,b,c,d,e,g){const f=__H[o][__jstr(p,l)];return __href(f.call(__H[o],__H[a],__H[b],__H[c],__H[d],__H[e],__H[g]));}
            \\function js_new1(c,a){return __href(new (__H[c])(__H[a]));}
            \\// Like js_new1, but a constructor that THROWS yields the null handle (0)
            \\// instead of blowing the exception through the wasm boundary. Needed because
            \\// `new Worker(blobUrl)` legitimately throws in a sandboxed iframe (opaque
            \\// origin), and zimr must survive that and fall back to the main thread.
            \\function js_try_new1(c,a){try{return __href(new (__H[c])(__H[a]));}catch(e){return 0;}}
            \\function js_new2(c,a,b){return __href(new (__H[c])(__H[a],__H[b]));}
            \\function js_new3(c,a,b,d){return __href(new (__H[c])(__H[a],__H[b],__H[d]));}
            \\function js_set_index(o,i,v){__H[o][i]=__H[v];}
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function js_string_into(h,p,max){const m=Math.min(max,65536);const r=__enc.encodeInto(String(__H[h]),__SCR.subarray(0,m));__HEAPU8.set(__SCR.subarray(0,r.written),p);return r.written;}
            \\function js_bytes(p,l){return __href(new Uint8Array(__MEM.slice(p,p+l)));}
            \\const __P = [null];
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function js_promise_register(ph){const id=__P.length;__P.push({s:0,v:0});Promise.resolve(__H[ph]).then(v=>{if(__P[id])__P[id]={s:1,v:__href(v)};},e=>{if(__P[id])__P[id]={s:2,v:__href(e)};});return id;}
            \\function js_promise_status(id){return __P[id]?__P[id].s:2;}
            \\function js_promise_take(id){const r=__P[id]?__P[id].v:0;__P[id]=null;return r;}
            \\// fetch(url) then unwrap the body: resolves DIRECTLY to parsed JSON / text,
            \\// folding the `r => r.json()` step JS-side (Zig has no inline closures).
            \\function js_fetch_json(u){return __href(fetch(__H[u]).then(function(r){return r.json();}));}
            \\function js_fetch_text(u){return __href(fetch(__H[u]).then(function(r){return r.text();}));}
            \\// --- generality layer: lets transpiled Zig reach anything JS offers ---
            \\function js_undefined(){return __href(undefined);}
            \\function js_array(){return __href([]);}
            \\function js_push(arr,v){__H[arr].push(__H[v]);return arr;}
            \\function js_len(v){return (__H[v] && __H[v].length|0)||0;}
            \\// arbitrary-arity call/construct: args are a heap array of handles,
            \\// read `n` of them starting at byte `argp` (u32 each). Removes the
            \\// js_callN 6-argument ceiling.
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function __args(argp,n){__ckargs(argp,n);const a=new Array(n);for(let i=0;i<n;i++)a[i]=__H[__HEAPU32[(argp>>2)+i]];return a;}
            \\function js_apply(fn,thisv,argp,n){return __href(__H[fn].apply(__H[thisv],__args(argp,n)));}
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function js_call_n(o,p,l,argp,n){const f=__H[o][__jstr(p,l)];return __href(f.apply(__H[o],__args(argp,n)));}
            \\function js_construct(c,argp,n){return __href(new (__H[c])(...__args(argp,n)));}
            \\// reflection / control: typeof, instanceof, truthiness, equality
            \\function js_typeof(v){return __href(typeof __H[v]);}
            \\function js_instanceof(v,c){return __H[v] instanceof __H[c] ? 1 : 0;}
            \\function js_truthy(v){return __H[v] ? 1 : 0;}
            \\function js_strict_eq(a,b){return __H[a]===__H[b] ? 1 : 0;}
            \\// call that may throw: writes 1 to *okp (heap u32) on success else 0,
            \\// and returns the result handle (or the caught exception handle).
            // lint:off line-length: emitted-JS template — one source line is one output line
            \\function js_try_call(o,p,l,argp,n,okp){try{const f=__H[o][__jstr(p,l)];const r=f.apply(__H[o],__args(argp,n));__cku32(okp);__HEAPU32[okp>>2]=1;return __href(r);}catch(e){__cku32(okp);__HEAPU32[okp>>2]=0;return __href(e);}}
            \\
            \\const __f64dv = new DataView(new ArrayBuffer(8));
            \\function __f64bits(bi){ __f64dv.setBigUint64(0, BigInt(bi)); return __f64dv.getFloat64(0); }
            \\function __f32bits(b){ __f64dv.setUint32(0, b >>> 0); return __f64dv.getFloat32(0); }
            \\// the inverse: @bitCast a float to its integer repr. u64 is a BigInt in
            \\// this model and u32 a Number, so the two return different domains.
            \\function __bitsf64(v){ __f64dv.setFloat64(0, v); return __f64dv.getBigUint64(0); }
            \\function __bitsf32(v){ __f64dv.setFloat32(0, v); return __f64dv.getUint32(0); }
            \\
        );
        try self.emit("\n");

        // Function-pointer dispatch table: `&fn` lowers to its 1-based index and an
        // indirect call to `__FTABLE[idx](args)`. JS function declarations hoist, so
        // this const may reference functions defined textually below it. Emitted only
        // when some function's address is actually taken, so a program that never uses
        // a function pointer gets no dispatch table at all.
        if (self.uses_fn_ptr) {
            try self.emit("const __FTABLE = [null");
            for (self.fn_table.items) |nm| {
                try self.print(", {s}", .{self.applyDefine(nm)});
            }
            try self.emit("];\n");
        }

        while (self.current().kind != .eof) {
            try self.parseTopLevel();
        }
    }

    /// Parse all struct/union layouts up front, before prescanScalarGlobals needs
    /// them to size struct-typed globals. The main parse loop re-encounters these
    /// definitions and re-records identical layouts (harmless). The C backend
    /// defines inner structs before outer ones, so one forward pass resolves
    /// nested field sizes.
    /// Scan `enum { NAME = VALUE, NAME, ... }` declarations (Zig lowers error
    /// sets and enums to these) and record each constant in `defines` so uses
    /// like `zig_error_Bad` resolve to their integer value. Honors C auto-
    /// increment (a member with no `= value` is previous + 1, starting at 0).
    /// Record names introduced by simple `typedef <type...> NAME;` declarations
    /// (the Zig C-backend emits these for enum tag types, e.g.
    /// `typedef uint8_t enum___...;`). Recording the name lets `looksLikeDecl`
    /// and the declaration parser treat `NAME x;` as a scalar declaration rather
    /// than leaking the type name as a bare statement. Skips function-pointer and
    /// aggregate typedefs (which contain `(`/`{`).
    /// Build the call graph and record which functions are in a cycle (directly
    /// self-recursive or mutually recursive). Local structs/arrays are given a
    /// STATIC scratch slot — a fixed heap address — which is not reentrant, so a
    /// recursive function with such a local would have its inner call clobber the
    /// outer frame's data (a silent wrong result). Knowing the recursive set lets
    /// the decl path flag that case loudly (a marker) instead of miscompiling it.
    fn prescanRecursion(self: *Transpiler) error{OutOfMemory}!void {
        // Collect function definitions (`IDENT ( ... ) {`) with their body range.
        var names: ArrayList([]const u8) = .empty;
        var body_lo: ArrayList(usize) = .empty;
        var body_hi: ArrayList(usize) = .empty;
        const nt: usize = self.toks.len;
        var i: usize = 0;
        while (i < nt) : (i += 1) {
            if (self.toks[i].kind == .ident and i + 1 < nt and
                eql(u8, self.toks[i + 1].text, "("))
            {
                const lp: usize = i + 1;
                const rp: usize = self.matching(lp, "(", ")");
                if (rp + 1 < nt and eql(u8, self.toks[rp + 1].text, "{")) {
                    const bs: usize = rp + 1;
                    const be: usize = self.matching(bs, "{", "}");
                    try names.append(self.gpa, self.toks[i].text);
                    try body_lo.append(self.gpa, bs);
                    try body_hi.append(self.gpa, be);
                    i = be; // skip the body (C has no nested function definitions)
                }
            }
        }
        const n: usize = names.items.len;
        // Function-pointer dispatch table: a function whose ADDRESS is taken (`&fn`
        // used as a value) gets a 1-based __FTABLE index (0 reserved for a null
        // fn-ptr). `&fn` lowers to that index; an indirect call dispatches through
        // `__FTABLE[idx](args)`. Only address-taken functions are listed — the
        // entry point (whose address is never taken, and whose export `#define`
        // rename would otherwise dangle the table) stays out, and fn-ptr-free
        // programs collect nothing and emit no table at all.
        {
            var k: usize = 0;
            while (k + 1 < nt) : (k += 1) {
                if (!eql(u8, self.toks[k].text, "&")) {
                    continue;
                }
                if (self.toks[k + 1].kind != .ident) {
                    continue;
                }
                const fnm: []const u8 = self.toks[k + 1].text;
                if (self.fn_index.contains(fnm)) {
                    continue;
                }
                var is_fn: bool = false;
                for (names.items) |nm| {
                    if (eql(u8, nm, fnm)) {
                        is_fn = true;
                        break;
                    }
                }
                if (!is_fn) {
                    continue;
                }
                try self.fn_index.put(fnm, @intCast(self.fn_table.items.len + 1));
                try self.fn_table.append(self.gpa, fnm);
                self.uses_fn_ptr = true;
            }
        }
        if (n == 0) {
            return;
        }
        // Direct-call adjacency: adj[f*n+g] = function f calls function g.
        const adj = try self.gpa.alloc(bool, n * n);
        @memset(adj, false);
        var f: usize = 0;
        while (f < n) : (f += 1) {
            var k: usize = body_lo.items[f] + 1;
            const end: usize = body_hi.items[f];
            while (k < end) : (k += 1) {
                if (self.toks[k].kind == .ident and k + 1 < nt and
                    eql(u8, self.toks[k + 1].text, "("))
                {
                    var g: usize = 0;
                    while (g < n) : (g += 1) {
                        if (eql(u8, names.items[g], self.toks[k].text)) {
                            adj[f * n + g] = true;
                            break;
                        }
                    }
                }
            }
        }
        // Transitive closure (Floyd–Warshall): f is recursive iff f reaches f.
        var kk: usize = 0;
        while (kk < n) : (kk += 1) {
            var a: usize = 0;
            while (a < n) : (a += 1) {
                if (!adj[a * n + kk]) {
                    continue;
                }
                var b: usize = 0;
                while (b < n) : (b += 1) {
                    if (adj[kk * n + b]) {
                        adj[a * n + b] = true;
                    }
                }
            }
        }
        f = 0;
        while (f < n) : (f += 1) {
            if (adj[f * n + f]) {
                try self.recursive_fns.put(names.items[f], {});
            }
        }
    }

    // Prepass: record every name introduced by `typedef ... NAME;` (the trailing
    // identifier; fn-pointer / struct-body typedefs containing '(' or '{' are
    // skipped). The parser consults `typedefs` so a later `NAME x;` reads as a
    // declaration rather than two stray identifiers.
    fn prescanTypedefs(self: *Transpiler) error{OutOfMemory}!void {
        const n: usize = self.toks.len;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (!(self.toks[i].kind == .ident and eql(u8, self.toks[i].text, "typedef"))) {
                continue;
            }
            // find the terminating ';' for this typedef
            var j: usize = i + 1;
            var has_paren_or_brace: bool = false;
            while (j < n and !eql(u8, self.toks[j].text, ";")) : (j += 1) {
                const tx: []const u8 = self.toks[j].text;
                if (eql(u8, tx, "(") or eql(u8, tx, "{")) {
                    has_paren_or_brace = true;
                }
            }
            // the introduced name is the last identifier before ';'
            if (!has_paren_or_brace and j <= n and j > i + 1) {
                var k: usize = j;
                while (k > i + 1) {
                    k -= 1;
                    if (self.toks[k].kind == .ident and !eql(u8, self.toks[k].text, "typedef")) {
                        try self.typedefs.put(self.toks[k].text, {});
                        // packed structs lower to `typedef <uintN_t> bitpack__...;`;
                        // record the byte width so the local gets a heap slot and
                        // `sizeof(bitpack__...)` resolves.
                        if (startsWith(u8, self.toks[k].text, "bitpack_") and i + 1 < n) {
                            if (primSizeOf(self.toks[i + 1].text)) |z| {
                                try self.bitpack_sizes.put(self.toks[k].text, z);
                            }
                        }
                        // A simple `typedef <prim> NAME;` — the enum tag typedefs
                        // `typedef uint8_t enum__...;` are the important case; record
                        // NAME -> the underlying scalar CType so a cast `(enum__... *)`,
                        // a deref through such a pointer, and that-typed struct
                        // fields all use the REAL width instead of a 32-bit default
                        // (a 32-bit store through an 8-bit enum pointer would clobber
                        // adjacent bytes). The base type sits right after `typedef`.
                        if (i + 1 < n and !eql(u8, self.toks[i + 1].text, self.toks[k].text)) {
                            if (baseType(self.toks[i + 1].text)) |bt| {
                                if (bt.kind == .int or bt.kind == .float) {
                                    try self.type_aliases.put(self.toks[k].text, bt);
                                }
                            }
                        }
                        // A struct/union typedef alias: `typedef struct TAG NAME;`
                        // (the C backend emits these for over-aligned nested struct
                        // access, e.g. `typedef struct X aligned__4_X;`). Record
                        // NAME -> TAG so casts/decls through the alias resolve to the
                        // real struct (alignment is meaningless in the heap model).
                        if (i + 3 < n and k == i + 3 and
                            (eql(u8, self.toks[i + 1].text, "struct") or eql(u8, self.toks[i + 1].text, "union")) and
                            self.toks[i + 2].kind == .ident)
                        {
                            try self.struct_aliases.put(self.toks[k].text, self.toks[i + 2].text);
                        }
                        break;
                    }
                }
            }
            i = j;
        }
    }

    // Prepass: flatten `enum [tag] { A, B = 5, C }` into the #define map so each
    // constant resolves to its integer value, following C's rules (start at 0, +1
    // each step, honor explicit `= n`). Afterwards enum names just emit as numbers.
    fn prescanEnums(self: *Transpiler) error{OutOfMemory}!void {
        const n: usize = self.toks.len;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (!(self.toks[i].kind == .ident and eql(u8, self.toks[i].text, "enum"))) {
                continue;
            }
            var j: usize = i + 1;
            if (j < n and self.toks[j].kind == .ident) {
                j += 1;
            } // optional tag
            if (j >= n or !eql(u8, self.toks[j].text, "{")) {
                continue;
            }
            j += 1; // past '{'
            var next_val: i64 = 0;
            while (j < n and !eql(u8, self.toks[j].text, "}")) {
                if (self.toks[j].kind == .ident) {
                    const name: []const u8 = self.toks[j].text;
                    j += 1;
                    var val: i64 = next_val;
                    if (j < n and eql(u8, self.toks[j].text, "=")) {
                        j += 1;
                        if (j < n and self.toks[j].kind == .number) {
                            if (parseCIntLiteral(self.toks[j].text)) |v| {
                                val = v;
                            }
                            j += 1;
                        }
                    }
                    if (!self.defines.contains(name)) {
                        try self.defines.put(name, try allocPrint(self.gpa, "{d}", .{val}));
                    }
                    next_val = val + 1;
                }
                while (j < n and !eql(u8, self.toks[j].text, ",") and
                    !eql(u8, self.toks[j].text, "}"))
                {
                    j += 1;
                }
                if (j < n and eql(u8, self.toks[j].text, ",")) {
                    j += 1;
                }
            }
            i = j;
        }
    }

    // Prepass (the first thing prescanData does): walk every token and, at each
    // `struct|union NAME { ... }`, hand off to parseStructDef to record the layout
    // — total size plus each field's byte offset and type — into `structs`. Borrows
    // the parse cursor `p` and puts it back, so the real parse later starts clean.
    fn prescanStructLayouts(self: *Transpiler) error{OutOfMemory}!void {
        const saved: usize = self.p;
        self.p = 0;
        while (self.p < self.toks.len) {
            if ((self.isKw("struct") or self.isKw("union")) and
                self.lookahead(1).kind == .ident and
                eql(u8, self.lookahead(2).text, "{"))
            {
                try self.parseStructDef();
            } else {
                self.p += 1;
            }
        }
        self.p = saved;
    }

    /// Scan all tokens for `... <name> ... = { "<cstring>" }` statics, decode the
    /// C string bytes, and assign each <name> a heap offset. Only handles the
    /// initialized char-array form the backend uses for string literals.
    fn prescanData(self: *Transpiler) error{OutOfMemory}!void {
        // resolve struct/union layouts first so struct-typed globals size correctly
        try self.prescanStructLayouts();
        var i: usize = 0;
        const n: usize = self.toks.len;
        while (i < n) : (i += 1) {
            // pattern: IDENT '=' '{' STRING '}'
            if (self.toks[i].kind == .ident and
                i + 4 < n and
                eql(u8, self.toks[i + 1].text, "=") and
                eql(u8, self.toks[i + 2].text, "{") and
                self.toks[i + 3].kind == .str and
                eql(u8, self.toks[i + 4].text, "}"))
            {
                const name: []const u8 = self.toks[i].text;
                if (self.globals.contains(name)) {
                    continue;
                }
                const bytes: []u8 = try decodeCString(self.gpa, self.toks[i + 3].text);
                // 8-align this global's start: an f64/i64 member is read via a
                // shift-by-3 typed view and needs 8-byte alignment (the data image
                // otherwise only 4-aligns, silently mis-reading the 8 bytes).
                while (self.data.items.len % 8 != 0) {
                    try self.data.append(self.gpa, 0);
                }
                const off = self.data_base + @as(u32, @intCast(self.data.items.len));
                try self.data.appendSlice(self.gpa, bytes);
                try self.data.append(self.gpa, 0); // NUL-terminate (harmless, matches C)
                // align next entry to 4
                while (self.data.items.len % 4 != 0) {
                    try self.data.append(self.gpa, 0);
                }
                try self.globals.put(name, off);
            }
        }
        // second pass: mutable scalar globals. The C backend accesses every global
        // as `(*((T*)&name))`, so giving each a heap slot makes the existing pointer
        // load/store machinery handle reads and writes for free.
        try self.prescanScalarGlobals();
    }

    /// Detect `static <scalar-type> <name> = <init> ;` definitions (int/uint of any
    /// width, or pointer) and assign each a zero-initialized heap slot holding its
    /// initial value, recorded in `globals` (name -> offset). Skips struct/array
    /// globals (the dead builtin_* data) and the string-data globals handled above.
    fn prescanScalarGlobals(self: *Transpiler) error{OutOfMemory}!void {
        var i: usize = 0;
        const n: usize = self.toks.len;
        while (i < n) : (i += 1) {
            if (!eql(u8, self.toks[i].text, "static")) {
                continue;
            }
            // gather specifier tokens until the name (last ident before '=' / ';' / '[')
            var j: usize = i + 1;
            var name_idx: ?usize = null;
            var saw_brace: bool = false;
            var saw_lparen: bool = false;
            var eq_idx: ?usize = null;
            while (j < n) : (j += 1) {
                const tx: []const u8 = self.toks[j].text;
                if (eql(u8, tx, ";")) {
                    break;
                }
                if (eql(u8, tx, "{")) {
                    saw_brace = true;
                    break;
                }
                if (eql(u8, tx, "(")) {
                    saw_lparen = true;
                    break;
                }
                if (eql(u8, tx, "[")) {
                    break;
                } // array global -> skip
                if (eql(u8, tx, "=")) {
                    eq_idx = j;
                    break;
                }
                if (self.toks[j].kind == .ident and !isTypeQualifierOrSpecifier(tx)) {
                    name_idx = j;
                }
            }
            // require: a name, an initializer, no struct/array/function shape
            if (saw_brace or saw_lparen) {
                continue;
            }
            const ni: usize = name_idx orelse continue;
            const ei: usize = eq_idx orelse continue;
            if (ni + 1 != ei) {
                continue;
            } // name must be immediately before '='
            const name: []const u8 = self.toks[ni].text;
            if (self.globals.contains(name)) {
                continue;
            }
            const specs: []const Token = self.toks[i + 1 .. ni];
            // Fixed-array global? The Zig C backend wraps `[N]T` as a struct
            // `arr_<N>_<elem>_<id> { T array[N]; }`. Detect that tag and give the
            // global its full N*sizeof(elem) bytes (zeroed; the contents are
            // either `undefined` or set at runtime). Element accesses are routed
            // to the heap view by the array-wrapper handling in the parser.
            if (arrayStructInfo(specs)) |info| {
                // Prefer the wrapper's own parsed layout size: a sentinel-terminated
                // array (`[N:0]T` -> `arr_Ns<id>_T { T array[N+1]; }`) has N+1 slots,
                // but parseArrTag's count is the logical N — so count*elem_size would
                // under-allocate by the sentinel slot, letting the NEXT global overlap
                // arr[N] (read back as that global's value). The struct layout has the
                // true byte size (incl. the sentinel); fall back to N*elem_size only
                // when the tag isn't a known struct.
                var wrap_tag: ?[]const u8 = null;
                for (specs) |t| {
                    if (t.kind == .ident and startsWith(u8, t.text, "arr_")) {
                        wrap_tag = t.text;
                        break;
                    }
                }
                const bytes: u32 = if (wrap_tag != null and self.structs.get(wrap_tag.?) != null)
                    self.structs.get(wrap_tag.?).?.size
                else
                    info.count * info.elem_size;
                // 8-align this global's start: an f64/i64 member is read via a
                // shift-by-3 typed view and needs 8-byte alignment (the data image
                // otherwise only 4-aligns, silently mis-reading the 8 bytes).
                while (self.data.items.len % 8 != 0) {
                    try self.data.append(self.gpa, 0);
                }
                const off = self.data_base + @as(u32, @intCast(self.data.items.len));
                var z: u32 = 0;
                while (z < bytes) : (z += 1) {
                    try self.data.append(self.gpa, 0);
                }
                while (self.data.items.len % 4 != 0) {
                    try self.data.append(self.gpa, 0);
                }
                try self.globals.put(name, off);
                // Const array with a literal initializer (`= {{e0, e1, ...}}`):
                // the wrapper is `struct arr_N_T { T array[N]; }`, so its layout
                // (parsed in prescanStructLayouts) has a single array field —
                // writeConstStruct walks the `{{...}}` and writes each element
                // into the image. Without this the data reads back as zeros.
                if (ei + 1 < n and eql(u8, self.toks[ei + 1].text, "{")) {
                    if (structTypeNameOf(specs)) |atag| {
                        if (self.structs.get(atag)) |alayout| {
                            _ = try self.writeConstStruct(off, alayout, ei + 1);
                        }
                    }
                }
                continue;
            }
            // Struct-typed global (`static struct Tag g = {...};`). Allocate the
            // struct's full size (zeroed), then write any constant initializer
            // values into the image (so `const v: Vec = .{1,0}` keeps its data
            // rather than reading back zero). Records the tag so field accesses
            // resolve. Sizing the full struct also prevents adjacent struct
            // globals from overlapping (a struct write clobbering its neighbour).
            if (structTagOf(self, specs)) |tag| {
                if (self.structs.get(tag)) |layout| {
                    // 8-align this global's start: an f64/i64 member is read via a
                    // shift-by-3 typed view and needs 8-byte alignment (the data image
                    // otherwise only 4-aligns, silently mis-reading the 8 bytes).
                    while (self.data.items.len % 8 != 0) {
                        try self.data.append(self.gpa, 0);
                    }
                    const off = self.data_base + @as(u32, @intCast(self.data.items.len));
                    var z: u32 = 0;
                    while (z < layout.size) : (z += 1) {
                        try self.data.append(self.gpa, 0);
                    }
                    while (self.data.items.len % 4 != 0) {
                        try self.data.append(self.gpa, 0);
                    }
                    try self.globals.put(name, off);
                    try self.struct_vars.put(name, tag);
                    // initializer is `= { ... }` at ei+1 (the opening brace)
                    if (ei + 1 < n and eql(u8, self.toks[ei + 1].text, "{")) {
                        _ = try self.writeConstStruct(off, layout, ei + 1);
                    }
                    continue;
                }
            }
            // type must be scalar: pointer, a known int base, or a float.
            const ty: CType = tyFromSpecifiers(specs);
            const is_scalar: bool =
                ty.kind == .ptr or ty.kind == .int or ty.kind == .float or ty.kind == .boolean;
            if (!is_scalar) {
                continue;
            }
            // width in bytes for the slot
            const width: u32 = switch (ty.kind) {
                .ptr => 4,
                .float => if (ty.bits == 64) 8 else 4,
                else => (@as(u32, ty.bits) + 7) / 8,
            };
            // parse the initializer value. For floats the C backend emits
            // zig_make_fNN(<hexfloat>, <bit pattern>); we store the bit pattern
            // directly so the heap holds the correct IEEE bytes.
            // 8-align this global's start: an f64/i64 member is read via a
            // shift-by-3 typed view and needs 8-byte alignment (the data image
            // otherwise only 4-aligns, silently mis-reading the 8 bytes).
            while (self.data.items.len % 8 != 0) {
                try self.data.append(self.gpa, 0);
            }
            const off = self.data_base + @as(u32, @intCast(self.data.items.len));
            // A bare pointer global initialized with `&otherGlobal` is a deferred
            // relocation (the pointee offset may not be assigned yet); record it
            // and leave the slot zeroed for now.
            var val: u64 = 0;
            if (ty.kind == .ptr) {
                if (self.addrOfGlobalAt(ei + 1, n)) |gname| {
                    try self.pending_relocs.append(self.gpa, .{ .addr = off, .target = gname, .width = 4 });
                } else {
                    val = self.parseScalarInit(ei + 1, n);
                }
            } else {
                val = self.parseScalarInit(ei + 1, n);
            }
            // little-endian store of the initial value into the slot. `val` is a
            // u64, so a wider global (u80/u96/u128) gets only its low 8 bytes from
            // val; the rest are zero — writing them via `val >> (b*8)` would
            // overflow the shift-amount cast (b*8 >= 64) and panic.
            var b: u32 = 0;
            while (b < width) : (b += 1) {
                const byte: u8 = if (b < 8) @intCast((val >> @intCast(b * 8)) & 0xff) else 0;
                try self.data.append(self.gpa, byte);
            }
            while (self.data.items.len % 4 != 0) {
                try self.data.append(self.gpa, 0);
            } // align
            try self.globals.put(name, off);
        }
        // All globals now have offsets: patch every recorded `&global` pointer
        // write with its pointee's heap offset. A target that never resolved to a
        // laid-out global is skipped (the slot keeps its zero = current behavior),
        // so a stray detection cannot corrupt the image.
        for (self.pending_relocs.items) |r| {
            if (self.globals.get(r.target)) |toff| {
                self.writeBytesAt(r.addr, toff, r.width);
            }
        }
        self.pending_relocs.clearRetainingCapacity();
    }

    /// Bump-allocate a 4-byte-aligned scratch slot of `bytes` from the heap,
    /// above the emitted data image. Does not grow `self.data`: the slot's initial
    /// contents are the ArrayBuffer's zeros, and scratch is always written before
    /// read (single-threaded, non-reentrant through these static slots).
    fn allocScratch(self: *Transpiler, bytes: u32) u32 {
        // 8-align the slot so any 64-bit member (an f64/i64/u64, read or written
        // via __HEAPF64 / __ld*64 / __st64 — all of which shift the byte address
        // by 3 and therefore require 8-byte alignment) lands aligned. A slot that
        // is only 4-aligned silently reads/writes the wrong 8 bytes. Scratch is
        // bump-allocated working memory, so over-aligning costs at most 7 bytes
        // per slot. (allocFrame already 8-aligns for the same reason.)
        const off: u32 = (self.heap_top + 7) & ~@as(u32, 7);
        self.heap_top = off + ((bytes + 7) & ~@as(u32, 7));
        return off;
    }

    /// Reserve `bytes` in the CURRENT function's stack frame (recursive functions
    /// only) and return the frame-relative offset. 8-byte aligned so 64-bit fields
    /// land aligned once added to the (8-aligned) frame base __fp.
    fn allocFrame(self: *Transpiler, bytes: u32) u32 {
        const off: u32 = self.frame_size;
        self.frame_size += (bytes + 7) & ~@as(u32, 7);
        return off;
    }

    /// The base-address EXPRESSION for an address-taken local: frame-relative
    /// "(__fp + N)" when this local lives on the shadow stack (recursive function),
    /// otherwise the absolute static offset "N". Callers splice this in place of the
    /// raw offset, so the same call site works for both reentrant and static locals.
    fn scratchBase(self: *Transpiler, name: []const u8, abs_off: u32) ![]const u8 {
        if (self.frame_off.get(name)) |rel| {
            return allocPrint(self.gpa, "(__fp + {d})", .{rel});
        }
        return allocPrint(self.gpa, "{d}", .{abs_off});
    }

    /// Emit a heap LOAD of element `e` at byte-address expression `byte_addr`.
    /// 64-bit ints can't be read through a single typed view (the value spans two
    /// 32-bit words), so they go through __ldi64/__ldu64; everything else (incl.
    /// f64 via HEAPF64) reads through its typed view. Centralizing here is what
    /// makes 64-bit values in structs/arrays/through-pointers round-trip.
    fn heapLoad(self: *Transpiler, e: Elem, byte_addr: []const u8) ![]const u8 {
        if (e.bits == 128) {
            // A 128-bit value needs 16 bytes (word-split); not supported in the heap yet.
            // Loud rather than truncating to 32 bits (which then mixes BigInt with Number).
            return allocPrint(
                self.gpa,
                "/*?int128-heap-load-unsupported: 128-bit values in the heap " ++
                    "(struct/array/global) need word-split storage*/ 0n",
                .{},
            );
        }
        if (e.bits > 32 and e.bits <= 64 and !e.float) {
            const f: []const u8 = if (e.signed) "__ldi64" else "__ldu64";
            self.last_w = 64; // the loaded value is a BigInt
            // 33-63 bit ints share the 8-byte cell but must be re-narrowed to the
            // type width (sign-extended from the type's sign bit, not bit 63).
            if (e.bits < 64) {
                const m: []const u8 = if (e.signed) "asIntN" else "asUintN";
                return allocPrint(self.gpa, "BigInt.{s}({d},{s}({s}))", .{ m, e.bits, f, byte_addr });
            }
            return allocPrint(self.gpa, "{s}({s})", .{ f, byte_addr });
        }
        if (self.safe) {
            if (e.bits == 64) { // f64 (i64/u64 took the branch above): bounds+null, no natural-align
                return allocPrint(self.gpa, "{s}[__idx64(({s})) >> {d}]", .{ elemView(e), byte_addr, elemShift(e) });
            }
            return allocPrint(
                self.gpa,
                "{s}[__idx(({s}), {d}) >> {d}]",
                .{ elemView(e), byte_addr, elemSize(e), elemShift(e) },
            );
        }
        return allocPrint(self.gpa, "{s}[({s}) >> {d}]", .{ elemView(e), byte_addr, elemShift(e) });
    }

    /// Emit a heap STORE of `val` (already store-wrapped) to element `e` at
    /// `byte_addr`. The mirror of `heapLoad`; 64-bit ints write two words via
    /// __st64 (which returns `val`, so the store is usable in expression position).
    fn heapStore(
        self: *Transpiler,
        e: Elem,
        byte_addr: []const u8,
        val: []const u8,
    ) ![]const u8 {
        if (e.bits == 128) {
            return allocPrint(
                self.gpa,
                "/*?int128-heap-store-unsupported: 128-bit values in the heap " ++
                    "(struct/array/global) need word-split storage*/ 0n",
                .{},
            );
        }
        if (e.bits > 32 and e.bits <= 64 and !e.float) {
            // 33-63 bit ints share the 8-byte cell; mask the value to the type width
            // and coerce to BigInt (a literal / Number-domain value like 0 must
            // become 0n before __st64, which does BigInt bit-ops on it).
            if (e.bits < 64) {
                const m: []const u8 = if (e.signed) "asIntN" else "asUintN";
                return allocPrint(self.gpa, "__st64({s}, BigInt.{s}({d},BigInt({s})))", .{ byte_addr, m, e.bits, val });
            }
            return allocPrint(self.gpa, "__st64({s}, {s})", .{ byte_addr, val });
        }
        if (self.safe) {
            if (e.bits == 64) { // f64 (i64/u64 took the branch above): bounds+null, no natural-align
                return allocPrint(
                    self.gpa,
                    "{s}[__idx64(({s})) >> {d}] = {s}",
                    .{ elemView(e), byte_addr, elemShift(e), val },
                );
            }
            return allocPrint(
                self.gpa,
                "{s}[__idx(({s}), {d}) >> {d}] = {s}",
                .{ elemView(e), byte_addr, elemSize(e), elemShift(e), val },
            );
        }
        return allocPrint(self.gpa, "{s}[({s}) >> {d}] = {s}", .{ elemView(e), byte_addr, elemShift(e), val });
    }

    /// A bare u32 heap load (a stored pointer / slice `.ptr`), checked in
    /// SAFE_HEAP mode like heapLoad. Used by the few sites that read a pointer
    /// value directly rather than through heapLoad.
    fn u32LoadExpr(self: *Transpiler, addr: []const u8) ![]const u8 {
        if (self.safe) {
            return allocPrint(self.gpa, "__HEAPU32[__idx(({s}), 4) >> 2]", .{addr});
        }
        return allocPrint(self.gpa, "__HEAPU32[({s}) >> 2]", .{addr});
    }

    /// If the initializer element starting at token `start` is an address-of-
    /// global — `&name`, possibly wrapped in pointer casts like
    /// `((uint32_t *)&name)` — return that global's name; else null. The `&`
    /// must sit in a unary position (preceded by `(`/`)`/`,`/`{`/`=`) so a
    /// binary `a & MASK` is not mistaken for an address-of. The caller records a
    /// relocation; the apply step gates on `globals.get`, so a stray match that
    /// names a non-global is a harmless no-op.
    fn addrOfGlobalAt(self: *Transpiler, start: usize, n: usize) ?[]const u8 {
        var k: usize = start;
        var depth: i32 = 0;
        while (k < n) : (k += 1) {
            const tx: []const u8 = self.toks[k].text;
            if (eql(u8, tx, "(") or eql(u8, tx, "{")) {
                depth += 1;
            } else if (eql(u8, tx, ")") or eql(u8, tx, "}")) {
                if (depth == 0) {
                    return null;
                }
                depth -= 1;
            } else if (depth == 0 and (eql(u8, tx, ",") or eql(u8, tx, ";"))) {
                return null; // end of this initializer element, no address-of found
            } else if (eql(u8, tx, "&")) {
                const prev: []const u8 = if (k > 0) self.toks[k - 1].text else "(";
                const unary = eql(u8, prev, "(") or eql(u8, prev, ")") or
                    eql(u8, prev, ",") or eql(u8, prev, "{") or eql(u8, prev, "=");
                if (unary and k + 1 < n and self.toks[k + 1].kind == .ident) {
                    return self.toks[k + 1].text;
                }
                return null; // a binary `&`, or `&` not followed by an identifier
            }
        }
        return null;
    }

    /// Parse a scalar global initializer starting at token index `start`, e.g.
    /// `UINT32_C(0)`, `-INT32_C(1)`, `0`, `-5`, `NULL`. Returns the value as a u64
    /// bit pattern (negatives via two's complement); best-effort, defaults to 0.
    fn parseScalarInit(
        self: *Transpiler,
        start: usize,
        n: usize,
    ) u64 {
        var k: usize = start;
        var neg: bool = false;
        while (k < n and eql(u8, self.toks[k].text, "-")) {
            neg = !neg;
            k += 1;
        }
        if (k >= n) {
            return 0;
        }
        var tok: []const u8 = self.toks[k].text;
        // non-finite float constant: zig_make_special_fNN / zig_init_special_fNN
        // (sign, name, arg, repr). The 4th field `repr` is the IEEE bit pattern;
        // recurse on it so the data slot holds the correct inf/nan bytes (without
        // this a const inf/nan global silently reads back as 0).
        const is_special = startsWith(u8, tok, "zig_make_special_f") or
            startsWith(u8, tok, "zig_init_special_f");
        if (self.toks[k].kind == .ident and is_special and
            k + 1 < n and eql(u8, self.toks[k + 1].text, "("))
        {
            var j: usize = k + 2;
            var depth: usize = 1;
            var repr_start: usize = j;
            while (j < n and depth > 0) : (j += 1) {
                const tx: []const u8 = self.toks[j].text;
                if (eql(u8, tx, "(")) {
                    depth += 1;
                } else if (eql(u8, tx, ")")) {
                    depth -= 1;
                    if (depth == 0) {
                        break;
                    }
                } else if (depth == 1 and eql(u8, tx, ",")) {
                    repr_start = j + 1; // last field seen so far = repr
                }
            }
            return self.parseScalarInit(repr_start, n); // repr is a UINTxx_C(...) / hex
        }
        // float literal: zig_make_fNN(<hexfloat>, <bitpattern>) -> the bit pattern
        // (the 2nd arg), so the slot holds the correct IEEE bytes.
        if (self.toks[k].kind == .ident and
            (eql(u8, tok, "zig_make_f32") or eql(u8, tok, "zig_make_f64")) and
            k + 1 < n and eql(u8, self.toks[k + 1].text, "("))
        {
            // find the comma at paren depth 1, then read the bit-pattern token
            var j: usize = k + 2;
            var depth: usize = 1;
            while (j < n and depth > 0) : (j += 1) {
                const tx: []const u8 = self.toks[j].text;
                if (eql(u8, tx, "(")) {
                    depth += 1;
                }
                if (eql(u8, tx, ")")) {
                    depth -= 1;
                }
                if (depth == 1 and eql(u8, tx, ",")) {
                    var bt: []const u8 = self.toks[j + 1].text;
                    // unwrap UINTxx_C( ... )
                    if (self.toks[j + 1].kind == .ident and endsWith(u8, bt, "_C") and
                        eql(u8, self.toks[j + 2].text, "("))
                    {
                        bt = self.toks[j + 3].text;
                    }
                    return parseInt(u64, bt, 0) catch 0;
                }
            }
            return 0;
        }
        // unwrap UINTxx_C( / INTxx_C( macro: take the inner number
        if (self.toks[k].kind == .ident and
            endsWith(u8, tok, "_C") and
            k + 1 < n and eql(u8, self.toks[k + 1].text, "("))
        {
            tok = self.toks[k + 2].text;
        }
        if (eql(u8, tok, "NULL")) {
            return 0;
        }
        if (eql(u8, tok, "true")) {
            return 1;
        }
        if (eql(u8, tok, "false")) {
            return 0;
        }
        // The C backend emits type-limit constants as bare macros (UINT64_MAX,
        // INT64_MIN, …), which parseInt can't read — without this they would
        // silently become 0.
        if (limitMacroValue(tok)) |v| {
            return if (neg) 0 -% v else v;
        }
        // Strip any integer suffix (u/U/l/L) the backend may attach; parseInt
        // rejects trailing non-digits, and the `catch 0` would silently zero it.
        var tend: usize = tok.len;
        while (tend > 0) {
            const sc: u8 = tok[tend - 1];
            if (sc == 'u' or sc == 'U' or sc == 'l' or sc == 'L') {
                tend -= 1;
            } else {
                break;
            }
        }
        const mag = parseInt(u64, tok[0..tend], 0) catch 0;
        // Wrapping negation computes the two's-complement directly, avoiding an
        // i64 cast that would panic for INT64_MIN's magnitude (2^63) in safe builds.
        return if (neg) 0 -% mag else mag;
    }

    /// Overwrite `width` bytes of the data image at heap address `addr` with the
    /// little-endian bytes of `val` (the bytes must already be allocated).
    fn writeBytesAt(
        self: *Transpiler,
        addr: u32,
        val: u64,
        width: u32,
    ) void {
        const idx: u32 = addr - self.data_base;
        var b: u32 = 0;
        while (b < width) : (b += 1) {
            if (idx + b < self.data.items.len) {
                // a u64 source has only 8 meaningful bytes; any wider field (e.g.
                // a raw `u8 array[N]` inside an array wrapper reached as a scalar)
                // gets its remaining bytes left as zero rather than overflowing the
                // shift amount.
                const byte: u8 = if (b < 8) @intCast((val >> @intCast(b * 8)) & 0xff) else 0;
                self.data.items[idx + b] = byte;
            }
        }
    }

    /// Advance past one brace-initializer element starting at token `idx`,
    /// tracking nested (){}[] so a top-level `,` or the enclosing `}` ends it.
    /// Returns the index of that following `,` / `}`.
    fn skipInitElement(self: *Transpiler, idx: usize) usize {
        var k: usize = idx;
        var depth: i32 = 0;
        while (k < self.toks.len) : (k += 1) {
            const t: []const u8 = self.toks[k].text;
            if (eql(u8, t, "(") or eql(u8, t, "{") or eql(u8, t, "[")) {
                depth += 1;
            } else if (eql(u8, t, ")") or eql(u8, t, "]")) {
                depth -= 1;
            } else if (eql(u8, t, "}")) {
                if (depth == 0) {
                    break;
                }
                depth -= 1;
            } else if (eql(u8, t, ",") and depth == 0) {
                break;
            }
        }
        return k;
    }

    /// Write the constant brace initializer for struct `layout` into the data
    /// image at heap byte `base`. Token `idx` is at the opening `{`. Returns the
    /// token index just past the matching `}`. Handles scalar fields, array-typed
    /// fields (the `{e0, e1, ...}` inner brace that SIMD vectors lower to), and
    /// nested struct fields (recursively). Constant leaves are evaluated by
    /// parseScalarInit (so `zig_make_f32(hexfloat, bits)` stores the exact IEEE
    /// bytes). Struct-element arrays aren't unrolled (left zeroed) — rare and not
    /// reached by the vector/matrix-of-scalars constants this targets.
    fn writeConstStruct(
        self: *Transpiler,
        base: u32,
        layout: StructLayout,
        idx: usize,
    ) error{OutOfMemory}!usize {
        var k: usize = idx + 1; // past '{'
        var fi: usize = 0;
        while (k < self.toks.len and !eql(u8, self.toks[k].text, "}")) {
            // Pick the target field: a designated initializer `.name = value`
            // (optionals/error-unions emit these in non-declaration order) routes
            // by name; otherwise positional.
            var f: Field = undefined;
            if (eql(u8, self.toks[k].text, ".") and self.toks[k + 1].kind == .ident) {
                const fname: []const u8 = self.toks[k + 1].text;
                k += 2; // '.' name
                if (k < self.toks.len and eql(u8, self.toks[k].text, "=")) {
                    k += 1;
                }
                var found: bool = false;
                for (layout.fields) |lf| {
                    if (eql(u8, lf.name, fname)) {
                        f = lf;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    k = self.skipInitElement(k);
                    if (k < self.toks.len and eql(u8, self.toks[k].text, ",")) {
                        k += 1;
                    }
                    continue;
                }
            } else if (fi < layout.fields.len) {
                f = layout.fields[fi];
            } else {
                break;
            }
            if (f.struct_tag) |ntag| {
                if (self.structs.get(ntag)) |nl| {
                    // Array of structs (`sos_Pt array[N]` -> field struct_tag is
                    // the element struct, size = N*elem). The initializer is a
                    // nested brace of struct literals `{{...},{...}}`; write each
                    // element at its stride. (A single nested struct has
                    // size == nl.size and takes the simple path below.)
                    if (f.size > nl.size and eql(u8, self.toks[k].text, "{")) {
                        k += 1; // past the array's '{'
                        var j: u32 = 0;
                        while (k < self.toks.len and !eql(u8, self.toks[k].text, "}")) {
                            if (eql(u8, self.toks[k].text, "{")) {
                                k = try self.writeConstStruct(base + f.offset + j * nl.size, nl, k);
                            } else {
                                k = self.skipInitElement(k);
                            }
                            j += 1;
                            if (k < self.toks.len and eql(u8, self.toks[k].text, ",")) {
                                k += 1;
                            }
                        }
                        if (k < self.toks.len) {
                            k += 1;
                        } // past the array's '}'
                    } else if (eql(u8, self.toks[k].text, "{")) {
                        k = try self.writeConstStruct(base + f.offset, nl, k);
                    } else {
                        k = self.skipInitElement(k);
                    }
                } else {
                    k = self.skipInitElement(k);
                }
            } else {
                const esize: u32 = @intCast(elemSize(fieldElem(f)));
                const is_array: bool = f.size > esize;
                if (is_array and eql(u8, self.toks[k].text, "{")) {
                    k += 1; // past inner '{'
                    var j: u32 = 0;
                    while (k < self.toks.len and !eql(u8, self.toks[k].text, "}")) {
                        if (self.addrOfGlobalAt(k, self.toks.len)) |gname| {
                            try self.pending_relocs.append(self.gpa, .{
                                .addr = base + f.offset + j * esize,
                                .target = gname,
                                .width = @intCast(esize),
                            });
                        } else {
                            self.writeBytesAt(
                                base + f.offset + j * esize,
                                self.parseScalarInit(k, self.toks.len),
                                esize,
                            );
                        }
                        k = self.skipInitElement(k);
                        j += 1;
                        if (k < self.toks.len and eql(u8, self.toks[k].text, ",")) {
                            k += 1;
                        }
                    }
                    if (k < self.toks.len) {
                        k += 1;
                    } // past inner '}'
                } else {
                    if (self.addrOfGlobalAt(k, self.toks.len)) |gname| {
                        try self.pending_relocs.append(self.gpa, .{
                            .addr = base + f.offset,
                            .target = gname,
                            .width = @intCast(f.size),
                        });
                    } else {
                        self.writeBytesAt(
                            base + f.offset,
                            self.parseScalarInit(k, self.toks.len),
                            f.size,
                        );
                    }
                    k = self.skipInitElement(k);
                }
            }
            fi += 1;
            if (k < self.toks.len and eql(u8, self.toks[k].text, ",")) {
                k += 1;
            }
        }
        while (k < self.toks.len and !eql(u8, self.toks[k].text, "}")) {
            k += 1;
        }
        return k + 1; // past '}'
    }

    /// Value of a C type-limit macro (the backend emits these as bare names in
    /// initializers). MIN values are returned as their two's-complement u64; the
    /// data writer truncates to the slot width.
    fn limitMacroValue(name: []const u8) ?u64 {
        const Limit = struct { macro: []const u8, value: u64 };
        const table = [_]Limit{
            .{ .macro = "UINT8_MAX", .value = 0xff },
            .{ .macro = "UINT16_MAX", .value = 0xffff },
            .{ .macro = "UINT32_MAX", .value = 0xffffffff },
            .{ .macro = "UINT64_MAX", .value = 0xffffffffffffffff },
            .{ .macro = "SIZE_MAX", .value = 0xffffffff }, // wasm32: size_t is 32-bit
            .{ .macro = "UINTPTR_MAX", .value = 0xffffffff }, // wasm32: uintptr_t is 32-bit
            .{ .macro = "INT8_MAX", .value = 0x7f },
            .{ .macro = "INT16_MAX", .value = 0x7fff },
            .{ .macro = "INT32_MAX", .value = 0x7fffffff },
            .{ .macro = "INT64_MAX", .value = 0x7fffffffffffffff },
            .{ .macro = "INT8_MIN", .value = 0xffffffffffffff80 },
            .{ .macro = "INT16_MIN", .value = 0xffffffffffff8000 },
            .{ .macro = "INT32_MIN", .value = 0xffffffff80000000 },
            .{ .macro = "INT64_MIN", .value = 0x8000000000000000 },
        };
        for (table) |entry| {
            if (eql(u8, name, entry.macro)) {
                return entry.value;
            }
        }
        return null;
    }

    // Bracket-matcher: given an opening bracket at index `lp` (text `open`), return
    // the index of its matching `close`, respecting nesting. The prepasses use it
    // to leap over a balanced (...) or {...} span in one move.
    fn matching(
        self: *Transpiler,
        open_idx: usize,
        open: []const u8,
        close: []const u8,
    ) usize {
        var depth: usize = 0;
        var i: usize = open_idx;
        while (i < self.toks.len) : (i += 1) {
            if (eql(u8, self.toks[i].text, open)) {
                depth += 1;
            }
            if (eql(u8, self.toks[i].text, close)) {
                depth -= 1;
                if (depth == 0) {
                    return i;
                }
            }
        }
        return self.toks.len;
    }

    /// Name of the call whose argument list directly encloses token `i`, or null
    /// if `i` isn't inside a `name(...)` arg list. Scans left balancing parens.
    /// Used by the address-of pre-scan to skip `&x` inside the bitcast/copy idioms
    /// (`memcpy(&a,&b,n)` etc.) — those temps are SSA values, not real out-params.
    fn enclosingCallName(self: *Transpiler, i: usize) ?[]const u8 {
        var depth: i32 = 0;
        var j: usize = i;
        while (j > 0) {
            j -= 1;
            const tx: []const u8 = self.toks[j].text;
            if (eql(u8, tx, ")")) {
                depth += 1;
            } else if (eql(u8, tx, "(")) {
                if (depth == 0) {
                    if (j > 0 and self.toks[j - 1].kind == .ident) {
                        return self.toks[j - 1].text;
                    }
                    return null;
                }
                depth -= 1;
            }
        }
        return null;
    }

    const FuncSig = struct { name_idx: usize, lparen: usize, rparen: usize };

    /// Scan (without consuming) for a function declarator `IDENT ( ... )` at
    /// top declarator level starting at self.p. Returns null if the item is a
    /// non-function declaration (typedef / struct / global).
    fn findFuncSig(self: *Transpiler) ?FuncSig {
        var i: usize = self.p;
        while (i < self.toks.len) : (i += 1) {
            const t: Token = self.toks[i];
            if (eql(u8, t.text, ";")) {
                return null;
            } // decl ended, no func
            if (eql(u8, t.text, "{")) {
                return null;
            } // struct/enum body before any IDENT(
            if (eql(u8, t.text, "=")) {
                return null;
            } // initializer => global
            if (t.kind == .ident and i + 1 < self.toks.len and
                eql(u8, self.toks[i + 1].text, "("))
            {
                const lp: usize = i + 1;
                const rp: usize = self.matching(lp, "(", ")");
                return .{ .name_idx = i, .lparen = lp, .rparen = rp };
            }
        }
        return null;
    }

    /// Skip a non-function declaration: consume through the next `;` at depth 0,
    /// swallowing balanced `{...}` blocks (struct bodies / array initializers).
    fn skipDecl(self: *Transpiler) void {
        var depth: usize = 0;
        while (self.p < self.toks.len) {
            const t: Token = self.toks[self.p];
            self.p += 1;
            if (eql(u8, t.text, "{") or eql(u8, t.text, "(") or eql(u8, t.text, "[")) {
                depth += 1;
            }
            if (eql(u8, t.text, "}") or eql(u8, t.text, ")") or eql(u8, t.text, "]")) {
                if (depth > 0) {
                    depth -= 1;
                }
            }
            if (eql(u8, t.text, ";") and depth == 0) {
                return;
            }
        }
    }

    /// Capture `struct <tag> { <type> <field>; ... }` layout (offsets from
    /// field order, wasm32 ABI alignment). Leaves self.p positioned to let
    /// skipDecl() consume the rest of the declaration.
    /// Byte offset of field `field` within struct `tag`, or null if unknown.
    fn fieldOffsetOf(
        self: *Transpiler,
        tag: []const u8,
        field: []const u8,
    ) ?u32 {
        const layout: StructLayout = self.structs.get(tag) orelse return null;
        for (layout.fields) |f| {
            if (eql(u8, f.name, field)) {
                return f.offset;
            }
        }
        return null;
    }

    /// Field metadata (offset + scalar type) of `field` within struct `tag`.
    fn fieldOf(
        self: *Transpiler,
        tag: []const u8,
        field: []const u8,
    ) ?Field {
        const layout: StructLayout = self.structs.get(tag) orelse return null;
        for (layout.fields) |f| {
            if (eql(u8, f.name, field)) {
                return f;
            }
        }
        return null;
    }

    /// Given the byte address (a JS expr string) of struct field `field`, consume
    /// an optional `[i]` array subscript and return the element address
    /// `(base + i * elem_size)`. SIMD vectors lower to `struct { f32 array[N]; }`,
    /// so `&v.array[i]` reaches here; without this the index is dropped and every
    /// lane aliases. With no subscript, returns the base unchanged.
    fn arraySubscriptAddr(
        self: *Transpiler,
        base: []const u8,
        tag: []const u8,
        field: []const u8,
    ) error{OutOfMemory}![]const u8 {
        if (!self.atText("[")) {
            // No subscript here: the result is the field's own address. If that
            // field is an array-wrapper struct (an `arr_N_T` with an `array`
            // member), record its tag so a trailing `->array[i]` / `.array[i]` on
            // the returned pointer resolves to a strided element address. Without
            // this the chain breaks and the `.array` lands on a number (crash).
            // Gated on the struct actually having an `array` field, so ordinary
            // nested-struct field addresses are unaffected.
            if (self.fieldOf(tag, field)) |f| {
                if (f.struct_tag) |st| {
                    if (self.fieldOf(st, "array") != null) {
                        self.pending_struct_tag = st;
                    }
                }
            }
            return self.gpa.dupe(u8, base);
        }
        self.p += 1;
        const idx: []const u8 = try self.parseExpr();
        self.expect("]");
        if (self.fieldOf(tag, field)) |f| {
            // Array of structs (`[N]T` with T a struct, e.g. the rows of a
            // `[N][M]` or a `[4]Vec`): the element stride is the element
            // struct's whole size, and the result is that element's address
            // (a struct pointer — the temp it lands in is tagged at its decl).
            if (f.struct_tag) |etag| {
                if (self.structs.get(etag)) |el| {
                    return allocPrint(self.gpa, "(({s}) + ({s}) * {d})", .{ base, idx, el.size });
                }
            }
            // Pointer field (`slice.ptr`): `base` is the address WHERE the
            // pointer is stored, so the element address is the LOADED pointer
            // value plus the index scaled by the pointee size — not base + i*sz.
            // BUT an inline ARRAY of pointers (`T *field[N]`, f.size > 4) is laid
            // out in place: element i lives at base + i*4 and the stored pointer
            // is read by the caller's later deref. Only a genuine single pointer
            // field (a decayed slice `.ptr`, f.size == 4) takes the load path.
            if (f.ptr_elem) |pe| {
                if (f.size <= 4) {
                    // pointee may itself be a struct (`[]const Pt` -> `ptr` is
                    // `struct Pt *`): stride by the struct size, result is the
                    // element's address.
                    if (pe.struct_tag) |etag| {
                        if (self.structs.get(etag)) |el| {
                            const ld: []const u8 = try self.u32LoadExpr(base);
                            return allocPrint(
                                self.gpa,
                                "(({s}) + ({s}) * {d})",
                                .{ ld, idx, el.size },
                            );
                        }
                    }
                    const ld: []const u8 = try self.u32LoadExpr(base);
                    return allocPrint(
                        self.gpa,
                        "(({s}) + ({s}) * {d})",
                        .{ ld, idx, elemSize(pe) },
                    );
                }
                // inline array of pointers: element address = base + i*4 (the slot
                // that holds the pointer). The element value (the pointer) is read
                // by whatever derefs the result.
                return allocPrint(
                    self.gpa,
                    "(({s}) + ({s}) * 4)",
                    .{ base, idx },
                );
            }
            return allocPrint(
                self.gpa,
                "(({s}) + ({s}) * {d})",
                .{ base, idx, elemSize(fieldElem(f)) },
            );
        }
        return allocPrint(self.gpa, "(({s}) + ({s}) * {d})", .{ base, idx, @as(usize, 4) });
    }

    /// Emit a store of `rhs` into a struct field at byte address `addr` (a JS
    /// expression string). Scalar fields become a typed-array store; a nested
    /// struct-typed field becomes a byte copy of the field's size (`rhs` is the
    /// source struct's heap offset).
    fn fieldStore(
        self: *Transpiler,
        addr: []const u8,
        f: Field,
        rhs: []const u8,
    ) ![]const u8 {
        if (f.struct_tag != null) {
            return allocPrint(self.gpa, "__copy({s}, {s}, {d})", .{ addr, rhs, f.size });
        }
        const e = Elem{ .bits = f.bits, .signed = f.signed, .float = f.float };
        const ety = CType{ .kind = if (f.float) .float else .int, .bits = f.bits, .signed = f.signed };
        return allocPrint(self.gpa, "({s})", .{try self.heapStore(e, addr, try self.wrap(rhs, ety))});
    }

    /// Emit a load of a struct field at byte address `addr`. A scalar field is a
    /// typed-array load; a nested struct-typed field evaluates to its address
    /// (struct values ARE heap offsets in this model).
    fn fieldLoad(
        self: *Transpiler,
        addr: []const u8,
        f: Field,
    ) ![]const u8 {
        if (f.struct_tag != null) {
            return allocPrint(self.gpa, "({s})", .{addr});
        }
        const e = Elem{ .bits = f.bits, .signed = f.signed, .float = f.float };
        return self.heapLoad(e, addr);
    }

    /// Parse a C compound-literal body `{ e0, e1, ... }` (positional, in field
    /// order) for struct `layout`. self.p is at '{'. Allocates a scratch slot,
    /// stores each initializer into its field, and yields the struct's heap
    /// offset via a comma expression `(store0, store1, ..., off)`. Nested struct
    /// fields recurse: their initializer is itself a compound literal yielding an
    /// offset, which fieldStore copies in by value.
    fn parseCompoundLiteral(self: *Transpiler, layout: StructLayout) error{OutOfMemory}![]const u8 {
        const off: u32 = self.allocScratch(layout.size);
        self.expect("{");
        var parts: ArrayList(u8) = .empty;
        try parts.append(self.gpa, '(');
        var fi: usize = 0;
        while (!self.atText("}")) {
            // Choose the target field: a designated initializer `.name = value`
            // (used by optionals/error-unions: `{ .is_null = false, .payload = 42 }`,
            // whose field order differs from the declaration) routes by name;
            // otherwise fall back to positional order.
            var maybe_f: ?Field = null;
            if (self.atText(".") and self.lookahead(1).kind == .ident) {
                const fname: []const u8 = self.lookahead(1).text;
                self.p += 2; // '.' name
                _ = self.consume("="); // designator '='
                for (layout.fields) |lf| {
                    if (eql(u8, lf.name, fname)) {
                        maybe_f = lf;
                        break;
                    }
                }
            } else if (fi < layout.fields.len) {
                maybe_f = layout.fields[fi];
            }
            if (maybe_f) |f| {
                const esize: u32 = @intCast(elemSize(fieldElem(f)));
                const is_array: bool = f.struct_tag == null and f.size > esize;
                // an array whose ELEMENTS are structs records struct_tag = the
                // element struct and size = N * elemSize (so size exceeds one
                // element). Distinguish it from a single nested struct field.
                const is_struct_array: bool = f.struct_tag != null and blk: {
                    const sl: StructLayout = self.structs.get(f.struct_tag.?) orelse break :blk false;
                    break :blk sl.size > 0 and f.size > sl.size;
                };
                if (is_array and self.current().kind == .str) {
                    // array-typed field initialized from a C string literal
                    // (`(struct { u8 array[N]; }){"\005\006..."}`) — the form Zig's
                    // C backend uses for a runtime [N]u8 value. Decode the bytes and
                    // store each at field_offset + j (element size is 1 for u8).
                    const bytes: []u8 = try decodeCString(self.gpa, self.current().text);
                    self.p += 1; // consume the string token
                    const elemField = Field{
                        .name = "",
                        .offset = 0,
                        .bits = f.bits,
                        .signed = f.signed,
                        .float = f.float,
                        .size = esize,
                    };
                    var j: u32 = 0;
                    while (j < bytes.len and (j + 1) * esize <= f.size) : (j += 1) {
                        const addr: []u8 = try allocPrint(self.gpa, "{d}", .{off + f.offset + j * esize});
                        const bexpr: []u8 = try allocPrint(self.gpa, "{d}", .{bytes[j]});
                        const store: []const u8 = try self.fieldStore(addr, elemField, bexpr);
                        try parts.appendSlice(self.gpa, store);
                        try parts.appendSlice(self.gpa, ", ");
                    }
                } else if (is_array and self.atText("{")) {
                    // array-typed field initialized with a nested brace `{e0, e1, ...}`
                    // (SIMD vectors: `(struct {f32 array[N];}){{...}}`). Store each
                    // element at field_offset + j*element_size.
                    self.expect("{");
                    const elemField = Field{
                        .name = "",
                        .offset = 0,
                        .bits = f.bits,
                        .signed = f.signed,
                        .float = f.float,
                        .size = esize,
                    };
                    var j: u32 = 0;
                    while (!self.atText("}")) {
                        const e: []const u8 = try self.parseAssign();
                        const addr: []u8 = try allocPrint(
                            self.gpa,
                            "{d}",
                            .{off + f.offset + j * esize},
                        );
                        const store: []const u8 = try self.fieldStore(addr, elemField, e);
                        try parts.appendSlice(self.gpa, store);
                        try parts.appendSlice(self.gpa, ", ");
                        j += 1;
                        if (self.atText(",")) {
                            self.p += 1;
                        } else {
                            break;
                        }
                    }
                    self.expect("}");
                } else if (is_struct_array and self.atText("{")) {
                    // array of STRUCTS (`(struct { P array[N]; }){{ {..}, ... }}`):
                    // iterate the N nested struct literals, building each at its
                    // own scratch then copying it into element slot j.
                    const nl: StructLayout = self.structs.get(f.struct_tag.?).?;
                    const es: u32 = nl.size;
                    self.expect("{");
                    var j: u32 = 0;
                    while (!self.atText("}")) {
                        const nested: []const u8 = try self.parseCompoundLiteral(nl);
                        const cp: []u8 = try allocPrint(
                            self.gpa,
                            "__copy({d}, {s}, {d})",
                            .{ off + f.offset + j * es, nested, es },
                        );
                        try parts.appendSlice(self.gpa, cp);
                        try parts.appendSlice(self.gpa, ", ");
                        j += 1;
                        if (self.atText(",")) {
                            self.p += 1;
                        } else {
                            break;
                        }
                    }
                    self.expect("}");
                } else if (f.struct_tag != null and self.atText("{")) {
                    // struct/union-typed field initialized with a nested brace
                    // (`.payload = { .circle = val }`): build the nested aggregate
                    // at its own scratch slot, then copy it into this field.
                    if (self.structs.get(f.struct_tag.?)) |nl| {
                        const nested: []const u8 = try self.parseCompoundLiteral(nl);
                        const addr: []u8 = try allocPrint(self.gpa, "{d}", .{off + f.offset});
                        const store: []const u8 = try self.fieldStore(addr, f, nested);
                        try parts.appendSlice(self.gpa, store);
                        try parts.appendSlice(self.gpa, ", ");
                    } else {
                        _ = try self.parseAssign();
                    }
                } else {
                    const expr: []const u8 = try self.parseAssign();
                    const addr: []u8 = try allocPrint(self.gpa, "{d}", .{off + f.offset});
                    const store: []const u8 = try self.fieldStore(addr, f, expr);
                    try parts.appendSlice(self.gpa, store);
                    try parts.appendSlice(self.gpa, ", ");
                }
            } else {
                _ = try self.parseAssign(); // extra initializer: parse and ignore
            }
            fi += 1;
            if (self.atText(",")) {
                self.p += 1;
            } else {
                break;
            }
        }
        self.expect("}");
        const tail: []u8 = try allocPrint(self.gpa, "{d})", .{off});
        try parts.appendSlice(self.gpa, tail);
        return parts.items;
    }

    // Parse a `struct|union NAME { ... }` and record its layout in `structs`: each
    // field's byte offset and scalar/struct/array element type, plus the total
    // size. Nested anonymous aggregates (the union payload + tag that tagged unions
    // lower to) get synthetic sub-layouts keyed `<outer>__<field>`. Called from
    // prescanStructLayouts so every layout is known before any body is emitted.
    fn parseStructDef(self: *Transpiler) error{OutOfMemory}!void {
        // at: struct|union <tag> {
        const is_top_union: bool = eql(u8, self.current().text, "union");
        self.p += 1; // 'struct' (or union)
        const tag: []const u8 = self.current().text;
        self.p += 1; // tag
        const brace: usize = self.p; // '{'
        const close: usize = self.matching(brace, "{", "}");
        var i: usize = brace + 1;
        var fields: ArrayList(Field) = .empty;
        var off: u32 = 0;
        var max_sz: u32 = 0; // for a top-level union: largest member size (all at offset 0)
        var struct_align: u32 = 1; // max field alignment → the struct's own alignment
        while (i < close) {
            // Nested anonymous aggregate field: `union { ... } name;` (tagged
            // unions lower to `struct { union { ... } payload; <tag> tag; }`) or
            // `struct { ... } name;`. The simple `;`-scan below can't handle the
            // members' internal `;`, so consume the whole aggregate here: build a
            // synthetic layout for it (union members all at offset 0; struct
            // members sequential) keyed by `<outer>__<field>`, and add one field
            // pointing at it.
            if ((eql(u8, self.toks[i].text, "union") or eql(u8, self.toks[i].text, "struct")) and
                i + 1 < close and eql(u8, self.toks[i + 1].text, "{"))
            {
                const is_union: bool = eql(u8, self.toks[i].text, "union");
                const abrace: usize = i + 1;
                const aclose: usize = self.matching(abrace, "{", "}");
                var subs: ArrayList(Field) = .empty;
                var sub_off: u32 = 0;
                var sub_max: u32 = 0;
                var agg_align: u32 = 1; // max member alignment → the aggregate's alignment
                var m: usize = abrace + 1;
                while (m < aclose) {
                    const ms: usize = m;
                    while (m < aclose and !eql(u8, self.toks[m].text, ";")) {
                        m += 1;
                    }
                    const mseg: []const Token = self.toks[ms..m];
                    m += 1;
                    if (mseg.len < 2) {
                        continue;
                    }
                    var snk: ?usize = null;
                    var sk: usize = mseg.len;
                    while (sk > 0) {
                        sk -= 1;
                        if (mseg[sk].kind == .ident and
                            !isTypeQualifierOrSpecifier(mseg[sk].text))
                        {
                            snk = sk;
                            break;
                        }
                    }
                    const mk: usize = snk orelse continue;
                    const mty: CType = tyFromSpecifiers(mseg[0..mk]);
                    const mnested: ?[]const u8 =
                        if (mty.kind != .ptr) structTypeNameOf(mseg[0..mk]) else null;
                    const msize: u32 = blk: {
                        if (mnested) |nt| {
                            if (self.structs.get(nt)) |nl| {
                                break :blk nl.size;
                            }
                        }
                        break :blk switch (mty.kind) {
                            .ptr => 4,
                            .float => if (mty.bits == 64) 8 else 4,
                            .boolean => 1,
                            .int => @intCast(@max(1, mty.bits / 8)),
                            else => 4,
                        };
                    };
                    const malign: u32 = if (mnested) |nt|
                        (if (self.structs.get(nt)) |nl| nl.align_ else 4)
                    else
                        msize;
                    agg_align = @max(agg_align, malign);
                    const soff: u32 = if (is_union) 0 else alignForward(u32, sub_off, malign);
                    try subs.append(self.gpa, .{
                        .name = mseg[mk].text,
                        .offset = soff,
                        .bits = if (mty.kind == .ptr) 32 else mty.bits,
                        .signed = mty.signed,
                        .float = mty.kind == .float,
                        .struct_tag = mnested,
                        .size = msize,
                    });
                    if (is_union) {
                        sub_max = @max(sub_max, msize);
                    } else {
                        sub_off = soff + msize;
                    }
                }
                const agg_size: u32 = alignForward(u32, if (is_union) sub_max else sub_off, agg_align);
                // the field name follows the closing brace: `} name ;`
                i = aclose + 1;
                if (i < close and self.toks[i].kind == .ident) {
                    const fname: []const u8 = self.toks[i].text;
                    i += 1;
                    while (i < close and !eql(u8, self.toks[i].text, ";")) {
                        i += 1;
                    }
                    i += 1; // past ';'
                    const stag: []u8 = try allocPrint(self.gpa, "{s}__{s}", .{ tag, fname });
                    try self.structs.put(
                        stag,
                        .{ .size = agg_size, .fields = try subs.toOwnedSlice(self.gpa), .align_ = agg_align },
                    );
                    struct_align = @max(struct_align, agg_align);
                    const foff: u32 = if (is_top_union) 0 else alignForward(u32, off, agg_align);
                    try fields.append(
                        self.gpa,
                        .{
                            .name = fname,
                            .offset = foff,
                            .bits = 0,
                            .signed = false,
                            .float = false,
                            .struct_tag = stag,
                            .size = agg_size,
                        },
                    );
                    if (is_top_union) {
                        max_sz = @max(max_sz, agg_size);
                    } else {
                        off = foff + agg_size;
                    }
                }
                continue;
            }
            // one member: <specifiers/*> <name> ;   (skip bitfields/arrays/nested)
            const seg_start: usize = i;
            while (i < close and !eql(u8, self.toks[i].text, ";")) {
                i += 1;
            }
            const seg: []const Token = self.toks[seg_start..i];
            i += 1; // past ';'
            if (seg.len < 2) {
                continue;
            }
            // name = last ident; type = the rest
            var name_k: ?usize = null;
            var k: usize = seg.len;
            while (k > 0) {
                k -= 1;
                if (seg[k].kind == .ident and !isTypeQualifierOrSpecifier(seg[k].text)) {
                    name_k = k;
                    break;
                }
            }
            const nk: usize = name_k orelse continue;
            var fty: CType = tyFromSpecifiers(seg[0..nk]);
            // Resolve a packed-struct `bitpack__...` element to its real byte width.
            // A packed struct is modelled as one uN word and accessed via __ld*64/
            // __st64 (an 8-byte op for the u64 case), so the field — and the stride
            // of any array of it — MUST match that width. tyFromSpecifiers is a free
            // fn and can't see the alias tables, so it would default it to a 32-bit
            // int and an array of an 8-byte packed struct would stride by 4, its
            // elements overlapping. (Enum-tag aliases are intentionally NOT resolved
            // here: their field access goes through the 4-byte cast-pointer store
            // path, so a 4-byte slot stays self-consistent.)
            for (seg[0..nk]) |st| {
                if (st.kind == .ident) {
                    if (self.bitpack_sizes.get(st.text)) |bsz| {
                        fty = .{ .kind = .int, .bits = @intCast(bsz * 8), .signed = false };
                        break;
                    }
                }
            }
            // For an ARRAY WRAPPER (`arr_N_<enumTag>`), an enum-tag alias element
            // MUST be sized at its REAL width. The element store strides by that
            // width (the global's array_elems resolves the alias), so sizing it at
            // the default 4 here makes the whole-array struct copy + read use a
            // 4-byte stride that disagrees with the 1-byte store — an `enum(u8)`
            // array reads back garbage and a `switch` on it hits `unreachable`.
            // (A USER struct's scalar enum field keeps the 4-byte slot, which its
            // cast-pointer field access relies on — see the note above; hence this
            // is gated on the synthetic array-wrapper tag only.)
            if (looksLikeArrayWrapper(tag)) {
                for (seg[0..nk]) |st| {
                    if (st.kind == .ident) {
                        if (self.type_aliases.get(st.text)) |aty| {
                            fty = aty;
                            break;
                        }
                    }
                }
            }
            // A POINTER/slice field whose pointee is an enum-tag alias (`[]enum(u8)`
            // -> a `{ enumTag* ptr; usize len; }`): its pointee element MUST be sized
            // at the enum's real width. tyFromSpecifiers can't see the alias tables,
            // so it leaves the pointee a default 4-byte int; a `slice.ptr[i]` read
            // would then stride by 4 over 1-byte-packed enum storage (the slice ptr
            // itself is built with the correct 1-byte stride), reading wrong elements.
            // Resolve fty.elem here so ptr_elem (set below) matches the storage.
            if (fty.kind == .ptr) {
                for (seg[0..nk]) |st| {
                    if (st.kind == .ident) {
                        if (self.bitpack_sizes.contains(st.text)) {
                            break; // packed struct: own handling
                        }
                        if (self.type_aliases.get(st.text)) |aty| {
                            if (aty.kind == .int or aty.kind == .float or aty.kind == .boolean) {
                                fty.elem = .{ .bits = aty.bits, .signed = aty.signed, .float = aty.kind == .float };
                            }
                            break;
                        }
                    }
                }
            }
            // A struct-typed (nested) field: size and align by the nested
            // struct's already-parsed layout. The C backend defines inner
            // structs before outer ones, so the tag is in `structs` by now.
            // For the synthetic array wrappers (`arr_N_...`) a member that is
            // itself a wrapper (`arr_M_T`, `vec_M_T`) is a real nested struct and
            // must be sized as one, so `[N][M]` / `[N]Vec` get the right element
            // stride. For user structs we keep the original behavior (a `[N]T`
            // member stays a flat array field) to avoid disturbing their layout.
            const wrapper: bool = looksLikeArrayWrapper(tag);
            const nested_tag: ?[]const u8 = blk: {
                if (fty.kind == .ptr) {
                    break :blk null;
                }
                // Members of a synthetic array wrapper (a `[N][M]` / `[N]Vec`
                // row) are real nested structs.
                if (wrapper) {
                    break :blk structTypeNameOf(seg[0..nk]);
                }
                // arr-of-struct wrappers and plain nested structs.
                if (structTagOf(self, seg[0..nk])) |t| {
                    break :blk t;
                }
                // A USER struct's `[N]scalar` member is, in the C backend, also a
                // nested array-wrapper struct accessed as `s.field.array[i]` — so
                // it must be sized and tagged as a nested struct (otherwise it is
                // mis-sized, the following field's offset is wrong, and a
                // runtime-indexed `s.field[i]` crashes). Gate on the type really
                // being a wrapper: a registered struct with an `array` member.
                const tn: []const u8 = structTypeNameOf(seg[0..nk]) orelse break :blk null;
                if (self.structs.get(tn)) |layout2| {
                    for (layout2.fields) |lf| {
                        if (eql(u8, lf.name, "array")) {
                            break :blk tn;
                        }
                    }
                }
                break :blk null;
            };
            const fsize: u32 = blk: {
                if (nested_tag) |ntag| {
                    if (self.structs.get(ntag)) |nl| {
                        break :blk nl.size;
                    }
                }
                break :blk switch (fty.kind) {
                    .ptr => 4,
                    .float => if (fty.bits == 64) 8 else 4,
                    .boolean => 1,
                    .int => @intCast(@max(1, fty.bits / 8)),
                    else => 4,
                };
            };
            // Field alignment: a scalar aligns to its size (1/2/4/8 → so an f64 /
            // i64 field forces 8); a nested struct aligns to its OWN computed
            // alignment (an inner struct containing an f64 needs 8, not 4). An
            // array field aligns to its element (fsize is the single-element size
            // here; arr_count is multiplied into .size only). Getting this wrong
            // silently mis-offsets the field AND (via the struct's max alignment)
            // mis-strides arrays of the struct.
            const al: u32 = if (nested_tag) |nt|
                (if (self.structs.get(nt)) |nl| nl.align_ else 4)
            else
                fsize;
            struct_align = @max(struct_align, al);
            const foff: u32 = if (is_top_union) 0 else alignForward(u32, off, al);
            // Array field: `<type> <name> [ N ]` (SIMD vectors lower to
            // `struct { f32 array[N]; }`). The element keeps fty's bits/float so
            // element addresses can be computed at `&v.field[i]`; the field's
            // total size is element_size * N.
            var arr_count: u32 = 1;
            if (nk + 2 < seg.len and eql(u8, seg[nk + 1].text, "[") and
                seg[nk + 2].kind == .number)
            {
                arr_count = parseInt(u32, seg[nk + 2].text, 10) catch 1;
            }
            try fields.append(self.gpa, .{
                .name = seg[nk].text,
                .offset = foff,
                .bits = if (fty.kind == .ptr) 32 else fty.bits,
                .signed = fty.signed,
                .float = fty.kind == .float,
                .struct_tag = nested_tag,
                .size = fsize * arr_count,
                .ptr_elem = if (fty.kind == .ptr) fty.elem else null,
            });
            if (is_top_union) {
                max_sz = @max(max_sz, fsize * arr_count);
            } else {
                off = foff + fsize * arr_count;
            }
        }
        // A struct's size is a multiple of its alignment (Zig/C _Alignof), so an
        // array of it strides by the padded size — not the unpadded field span.
        const total: u32 = alignForward(u32, if (is_top_union) max_sz else off, struct_align);
        try self.structs.put(
            tag,
            .{ .size = total, .fields = try fields.toOwnedSlice(self.gpa), .align_ = struct_align },
        );
    }

    // STAGE 3 dispatcher, one call per top-level construct (run loops on it). A
    // `struct|union NAME {` definition is recorded then skipped; a real function
    // definition (signature followed by `{`) goes to emitFunction; everything else
    // — prototypes, typedefs, dead builtin_* data — is skipped tolerantly via
    // skipDecl. The C backend never nests definitions, so this stays flat.
    fn parseTopLevel(self: *Transpiler) error{OutOfMemory}!void {
        while (self.consume(";")) {}
        if (self.current().kind == .eof) {
            return;
        }

        // struct/union <tag> { ... }  -> record layout, then skip the decl
        if ((self.isKw("struct") or self.isKw("union")) and
            self.lookahead(1).kind == .ident and
            eql(u8, self.lookahead(2).text, "{"))
        {
            try self.parseStructDef();
            self.skipDecl();
            return;
        }

        if (self.findFuncSig()) |sig| {
            const after_rparen: Token = if (sig.rparen + 1 < self.toks.len)
                self.toks[sig.rparen + 1]
            else
                .{ .kind = .eof, .text = "" };
            if (eql(u8, after_rparen.text, "{")) {
                try self.emitFunction(sig);
                return;
            }
        }
        self.skipDecl();
    }

    // Turn ONE C function into ONE JS function — the per-function heart of stages
    // 3+4. Steps: clear last function's scratch; register params (a struct-VALUE
    // param arrives as a heap offset, so it's tracked as a struct var); parse the
    // body into a Stmt tree; lower that to a flat FlowOp list (flatten); then render it
    // with emitBody (straight-line, or the trampoline if it has gotos/labels). C
    // temp names (t0,t1,...) get one `let` apiece up front since JS scoping differs.
    fn emitFunction(self: *Transpiler, sig: FuncSig) error{OutOfMemory}!void {
        self.vars.clearRetainingCapacity();
        self.fn_ptr_vars.clearRetainingCapacity();
        self.locals.clearRetainingCapacity();
        self.brk_stack.clearRetainingCapacity();
        self.cont_stack.clearRetainingCapacity();
        self.addr_local_collapse = false;
        // Drop the previous function's local-array/struct scratch registrations
        // so their temp names (t0, t1, ...) don't leak into this function's
        // namespace (a later t1 must not inherit an earlier t1's struct-ness).
        for (self.local_array_names.items) |nm| {
            _ = self.globals.remove(nm);
            _ = self.array_elems.remove(nm);
            _ = self.struct_vars.remove(nm);
            _ = self.struct_ptrs.remove(nm);
            _ = self.pp_struct_ptrs.remove(nm);
            _ = self.pp_load.remove(nm);
            _ = self.fn_ptr_vars.remove(nm);
        }
        self.local_array_names.clearRetainingCapacity();
        self.addr_taken.clearRetainingCapacity();
        self.scalar_slots.clearRetainingCapacity();
        self.frame_off.clearRetainingCapacity();
        self.frame_size = 0;

        self.ret_ty = tyFromSpecifiers(self.toks[self.p..sig.name_idx]);
        const name: []const u8 = self.applyDefine(self.toks[sig.name_idx].text);
        self.cur_fn = self.toks[sig.name_idx].text;

        // params
        var pnames: ArrayList([]const u8) = .empty;
        {
            var i: usize = sig.lparen + 1;
            const end: usize = sig.rparen;
            while (i < end) {
                const seg_start: usize = i;
                var depth: usize = 0;
                while (i < end) : (i += 1) {
                    const tx: []const u8 = self.toks[i].text;
                    if (eql(u8, tx, "(") or eql(u8, tx, "[")) {
                        depth += 1;
                    }
                    if (eql(u8, tx, ")") or eql(u8, tx, "]")) {
                        depth -= 1;
                    }
                    if (eql(u8, tx, ",") and depth == 0) {
                        break;
                    }
                }
                const seg: []const Token = self.toks[seg_start..i];
                i += 1; // step past ',' or end
                if (seg.len == 0) {
                    continue;
                }
                if (seg.len == 1 and eql(u8, seg[0].text, "void")) {
                    continue;
                }
                var name_k: ?usize = null;
                var k: usize = seg.len;
                while (k > 0) {
                    k -= 1;
                    if (seg[k].kind == .ident and !isTypeQualifierOrSpecifier(seg[k].text)) {
                        name_k = k;
                        break;
                    }
                }
                const pname: []const u8 = if (name_k) |nk| seg[nk].text else "a";
                const pspecs: []const Token = if (name_k) |nk| seg[0..nk] else seg;
                const pty: CType = tyFromSpecifiers(pspecs);
                try self.vars.put(pname, .{ .ty = pty });
                // Function-pointer parameter: `RET (*name)(params)` (a callback).
                // `name` holds a __FTABLE index, so calling it inside the body
                // dispatches through the table like any other fn-ptr value.
                {
                    var j: usize = 0;
                    while (j + 1 < seg.len) : (j += 1) {
                        if (eql(u8, seg[j].text, "(") and eql(u8, seg[j + 1].text, "*")) {
                            var stars: usize = 0;
                            var q: usize = j + 1;
                            while (q < seg.len and eql(u8, seg[q].text, "*")) : (q += 1) {
                                stars += 1;
                            }
                            if (stars == 1) {
                                try self.fn_ptr_vars.put(pname, {});
                            }
                            break;
                        }
                    }
                }
                // A struct-value param arrives as a heap offset (caller passed a
                // pointer-by-value); track it so &p.field and p.field resolve.
                if (structPtrTagOf(self, pspecs)) |tag| {
                    try self.struct_ptrs.put(pname, tag);
                    if (countStars(pspecs) >= 2) {
                        try self.pp_struct_ptrs.put(pname, {});
                        try self.pp_load.put(pname, {}); // a pp param holds a real heap address
                    }
                    try self.local_array_names.append(self.gpa, pname);
                } else if (structTagOf(self, pspecs)) |tag| {
                    try self.struct_ptrs.put(pname, tag); // value-as-offset behaves like a ptr
                    // Also a struct var: the param's JS value is its heap offset, so
                    // direct `p.field` / `p.array[i]` access resolves with the
                    // variable as the base address (it isn't in `globals`).
                    try self.struct_vars.put(pname, tag);
                    try self.local_array_names.append(self.gpa, pname);
                }
                try pnames.append(self.gpa, pname);
            }
        }

        // parse body into AST (populates self.locals + self.vars), then lower
        self.p = sig.rparen + 1; // points at `{`
        // Pre-scan the body for bare `&IDENT` (address-of a local) so the decl
        // handler can heap-back address-taken SCALAR locals — the same backing
        // aggregates already get. Conservative to avoid false positives: only a
        // UNARY `&` (preceded by `(` `,` `=` `return`, never an operand, so binary
        // `a & b` is excluded) and only when IDENT is NOT followed by `.`/`[`/`->`
        // (those are `&x.f`/`&x[i]`/`&x->f`, resolved by their own paths). Over-
        // collection is harmless: the decl filter heap-backs only scalar locals.
        {
            const bstart: usize = sig.rparen + 1;
            const bend: usize = self.matching(bstart, "{", "}");
            var i: usize = bstart + 1;
            while (i + 1 < bend) : (i += 1) {
                if (!eql(u8, self.toks[i].text, "&")) {
                    continue;
                }
                const prev: []const u8 = self.toks[i - 1].text;
                const unary: bool = eql(u8, prev, "(") or eql(u8, prev, ",") or
                    eql(u8, prev, "=") or eql(u8, prev, "return") or
                    // a pointer-cast close: `(T *)&x` — the C backend's form for
                    // address-of with a cast (`@ptrCast(&x)`, `&union.field`, a
                    // `[*]`/`*anyopaque` pointer). `*)` before `&` is unambiguous:
                    // a binary `(expr) & y` never has `*` immediately before `)`.
                    (eql(u8, prev, ")") and i >= 2 and eql(u8, self.toks[i - 2].text, "*"));
                if (!unary) {
                    continue;
                }
                if (self.toks[i + 1].kind != .ident) {
                    continue;
                }
                const after: []const u8 = if (i + 2 < bend) self.toks[i + 2].text else ";";
                if (eql(u8, after, ".") or eql(u8, after, "[") or eql(u8, after, "->")) {
                    continue;
                }
                // Skip `&x` inside the bitcast/copy idioms — `memcpy(&a,&b,n)`,
                // `memmove`, `memset(&a,...)` — which the transpiler already lowers
                // specially; those temps are plain SSA values, not out-parameters.
                if (self.enclosingCallName(i)) |cn| {
                    if (eql(u8, cn, "memcpy") or eql(u8, cn, "memmove") or eql(u8, cn, "memset")) {
                        continue;
                    }
                }
                try self.addr_taken.put(self.toks[i + 1].text, {});
            }
        }
        const body: []const Stmt = try self.parseBlock();
        var ops: ArrayList(FlowOp) = .empty;
        try self.flatten(body, &ops);

        // emit
        try self.print("function {s}(", .{name});
        for (pnames.items, 0..) |pn, idx| {
            if (idx != 0) {
                try self.emit(", ");
            }
            try self.emit(pn);
        }
        try self.emit(") {\n");

        if (self.locals.items.len > 0) {
            // The C backend reuses temp names (t0, t2, ...) across disjoint blocks,
            // sometimes with different C types. JS `let` is function-scoped, so emit
            // each unique name once (all temps are zero/false-initialized before
            // use, so a single declaration is safe regardless of original type).
            var seen: StringHashMap(void) = .init(self.gpa);
            var first: bool = true;
            for (self.locals.items) |lc| {
                if (seen.contains(lc.name)) {
                    continue;
                }
                try seen.put(lc.name, {});
                if (first) {
                    try self.emit("  let ");
                    first = false;
                } else {
                    try self.emit(", ");
                }
                try self.print("{s} = {s}", .{ lc.name, lc.dflt });
            }
            if (!first) {
                try self.emit(";\n");
            }
        }

        // Shadow-stack prologue/epilogue: only for a recursive function that has
        // address-taken locals (frame_size > 0). Bump __SP down by the frame, expose
        // the frame base as __fp (locals resolve to __fp + offset), and restore __SP
        // on every exit via `finally` — so recursion gets a fresh frame per call while
        // non-recursive functions keep the zero-overhead static slots untouched.
        const has_frame: bool = self.frame_size > 0 and self.recursive_fns.contains(self.cur_fn);
        if (has_frame) {
            try self.print("  __SP -= {d}; const __fp = __SP;\n  try {{\n", .{self.frame_size});
        }
        try self.emitBody(ops.items);
        if (has_frame) {
            try self.print("  }} finally {{ __SP += {d}; }}\n", .{self.frame_size});
        }
        try self.emit("}\n\n");
    }

    // ------------------------------------------------------------------------
    // Statement parsing -> AST
    // ------------------------------------------------------------------------
    fn parseBlock(self: *Transpiler) error{OutOfMemory}![]const Stmt {
        self.expect("{");
        var list: ArrayList(Stmt) = .empty;
        while (self.current().kind != .eof and !self.atText("}")) {
            try list.append(self.gpa, try self.parseStmt());
        }
        self.expect("}");
        return list.toOwnedSlice(self.gpa);
    }

    // Parse either a `{...}` block or a single statement, always handing back a Stmt
    // slice — lets if/while/for bodies be treated uniformly whether braced or not.
    fn parseStmtAsBlock(self: *Transpiler) error{OutOfMemory}![]const Stmt {
        if (self.atText("{")) {
            return self.parseBlock();
        }
        var list: ArrayList(Stmt) = .empty;
        try list.append(self.gpa, try self.parseStmt());
        return list.toOwnedSlice(self.gpa);
    }

    // Quick lookahead: does the current token start a declaration? True for a type
    // keyword/qualifier or a known typedef name. Disambiguates `TYPE x;` from an
    // ordinary expression statement.
    fn looksLikeDecl(self: *Transpiler) bool {
        const t: Token = self.current();
        if (t.kind != .ident) {
            return false;
        }
        return isTypeQualifierOrSpecifier(t.text) or self.typedefs.contains(t.text);
    }

    // Parse ONE C statement into a Stmt node — the recursive-descent core of stage
    // 3. Handles blocks, declarations, labels, if/while/for/switch/do, break/
    // continue/goto/return, and otherwise falls back to an expression statement.
    // The Stmt tree it grows is what flatten lowers next; every node stashes its C
    // source line so the map survives lowering.
    fn parseStmt(self: *Transpiler) error{OutOfMemory}!Stmt {
        const t: Token = self.current();
        const sline: u32 = t.line; // C source line for this statement (for the source map)

        if (self.atText("{")) {
            return .{ .block = try self.parseBlock() };
        }
        if (self.consume(";")) {
            return .empty;
        }

        // label:  IDENT ':'  (case/default only occur inside switch)
        if (t.kind == .ident and
            !eql(u8, t.text, "default") and
            !eql(u8, t.text, "case") and
            eql(u8, self.lookahead(1).text, ":"))
        {
            self.p += 2;
            return .{ .label = self.applyDefine(t.text) };
        }

        if (self.isKw("return")) {
            self.p += 1;
            if (self.consume(";")) {
                return .{ .ret = .{ .val = null, .src = sline } };
            }
            const e: []const u8 = try self.parseExpr();
            self.expect(";");
            return .{ .ret = .{ .val = try self.wrap(e, self.ret_ty), .src = sline } };
        }
        if (self.isKw("goto")) {
            self.p += 1;
            const target: []const u8 = self.applyDefine(self.current().text);
            self.p += 1;
            self.expect(";");
            return .{ .goto = target };
        }
        if (self.isKw("break")) {
            self.p += 1;
            self.expect(";");
            return .brk;
        }
        if (self.isKw("continue")) {
            self.p += 1;
            self.expect(";");
            return .cont;
        }
        if (self.isKw("if")) {
            self.p += 1;
            self.expect("(");
            const c: []const u8 = try self.parseExpr();
            self.expect(")");
            const then: []const Stmt = try self.parseStmtAsBlock();
            var els: ?[]const Stmt = null;
            if (self.isKw("else")) {
                self.p += 1;
                els = try self.parseStmtAsBlock();
            }
            return .{ .if_ = .{ .cond = c, .then = then, .els = els } };
        }
        if (self.isKw("while")) {
            self.p += 1;
            self.expect("(");
            const c: []const u8 = try self.parseExpr();
            self.expect(")");
            const body: []const Stmt = try self.parseStmtAsBlock();
            return .{ .while_ = .{ .cond = c, .body = body } };
        }
        if (self.isKw("for")) {
            self.p += 1;
            self.expect("(");
            var init_s: ?[]const u8 = null;
            if (!self.atText(";")) {
                if (self.looksLikeDecl()) {
                    if (try self.parseDeclInner()) |asg| {
                        init_s = asg;
                    }
                } else {
                    init_s = try self.parseExpr();
                }
            }
            self.expect(";");
            var cond_s: ?[]const u8 = null;
            if (!self.atText(";")) {
                cond_s = try self.parseExpr();
            }
            self.expect(";");
            var step_s: ?[]const u8 = null;
            if (!self.atText(")")) {
                step_s = try self.parseExpr();
            }
            self.expect(")");
            const body: []const Stmt = try self.parseStmtAsBlock();
            return .{ .for_ = .{ .init = init_s, .cond = cond_s, .step = step_s, .body = body } };
        }
        if (self.isKw("switch")) {
            self.p += 1;
            self.expect("(");
            const e: []const u8 = try self.parseExpr();
            self.expect(")");
            self.expect("{");
            var cases: ArrayList(Case) = .empty;
            while (self.current().kind != .eof and !self.atText("}")) {
                var value: ?[]const u8 = null;
                if (self.consume("case")) {
                    value = try self.parseExpr();
                    self.expect(":");
                } else if (self.consume("default")) {
                    self.expect(":");
                    value = null;
                } else {
                    self.p += 1;
                    continue;
                }
                var cbody: ArrayList(Stmt) = .empty;
                while (self.current().kind != .eof and !self.atText("}") and
                    !self.atText("case") and !self.atText("default"))
                {
                    try cbody.append(self.gpa, try self.parseStmt());
                }
                try cases.append(
                    self.gpa,
                    .{ .value = value, .body = try cbody.toOwnedSlice(self.gpa) },
                );
            }
            self.expect("}");
            return .{ .switch_ = .{ .expr = e, .cases = try cases.toOwnedSlice(self.gpa) } };
        }
        if (self.looksLikeDecl()) {
            if (try self.parseDeclInner()) |asg| {
                return .{ .raw = .{ .text = asg, .src = sline } };
            }
            return .empty;
        }
        const e: []const u8 = try self.parseExpr();
        self.expect(";");
        return .{ .raw = .{ .text = e, .src = sline } };
    }

    /// Parse a declaration; register the var + hoist it. Returns an assignment
    /// string if there was an initializer, else null (hoist only).
    fn parseDeclInner(self: *Transpiler) error{OutOfMemory}!?[]const u8 {
        const start: usize = self.p;
        while (true) {
            const tk: Token = self.current();
            if (eql(u8, tk.text, "*")) {
                self.p += 1;
                continue;
            }
            if (tk.kind == .ident and isTypeQualifierOrSpecifier(tk.text)) {
                self.p += 1;
                const kw = eql(u8, tk.text, "struct") or eql(u8, tk.text, "union") or
                    eql(u8, tk.text, "enum");
                if (kw and self.current().kind == .ident) {
                    self.p += 1; // struct/union/enum tag
                }
                continue;
            }
            // a typedef name in type position (e.g. an enum tag type) — consume it
            // as the type, leaving the following identifier as the variable name.
            // Accept a following `*` too: `TYPEDEF *name;` is a pointer declaration
            // (C reads `alias * name;` as declaring `name`, not a multiply), and
            // without this the typedef name was mistaken for the variable.
            if (tk.kind == .ident and self.typedefs.contains(tk.text) and
                (self.lookahead(1).kind == .ident or eql(u8, self.lookahead(1).text, "*")))
            {
                self.p += 1;
                continue;
            }
            break;
        }
        const specs: []const Token = self.toks[start..self.p];
        var ty: CType = tyFromSpecifiers(specs);
        // Resolve an enum-tag alias pointee to its real width: a deref (`*p`) or
        // index (`p[i]`) of an enum POINTER local must load/stride at the enum's
        // true size (1/2 bytes), not tyFromSpecifiers' default 4-byte int (which
        // would read 4 bytes of a 1-byte enum — e.g. an `*enum(u8)` from a slice).
        // The address math already strides correctly; this fixes the load width.
        if (ty.kind == .ptr) {
            for (specs) |st| {
                if (st.kind == .ident) {
                    if (self.bitpack_sizes.contains(st.text)) {
                        break; // packed struct: own handling
                    }
                    if (self.type_aliases.get(st.text)) |aty| {
                        if (aty.kind == .int or aty.kind == .float or aty.kind == .boolean) {
                            ty.elem = .{ .bits = aty.bits, .signed = aty.signed, .float = aty.kind == .float };
                        }
                        break;
                    }
                }
            }
        }

        // Function-pointer declarator: `RET (*name)(args);` or `RET (**name)(args);`.
        // The C backend emits these for fn-ptr locals (e.g. a struct fn-ptr field
        // loaded into a temp). Declare `name` as a plain numeric local — a single-
        // star fn-ptr holds a __FTABLE index (calling it dispatches through the
        // table; tracked in fn_ptr_vars), a double-star holds the heap ADDRESS of
        // such a slot (deref'd with the ordinary 4-byte pointer load/store). Without
        // this the declarator's `(` was mistaken for "no name", leaving `name`
        // undeclared (an implicit global) and the fn-ptr unusable.
        if (self.atText("(") and eql(u8, self.lookahead(1).text, "*")) {
            var stars: usize = 0;
            var q: usize = self.p + 1; // first token after '('
            while (q < self.toks.len and eql(u8, self.toks[q].text, "*")) : (q += 1) {
                stars += 1;
            }
            if (q < self.toks.len and self.toks[q].kind == .ident and
                q + 1 < self.toks.len and eql(u8, self.toks[q + 1].text, ")"))
            {
                const fname: []const u8 = self.toks[q].text;
                self.p = q + 2; // consume up to and including ')'
                if (self.atText("(")) { // the parameter list
                    const rp: usize = self.matching(self.p, "(", ")");
                    self.p = rp + 1;
                }
                while (self.current().kind != .eof and !self.atText(";")) {
                    self.p += 1;
                }
                _ = self.consume(";");
                try self.locals.append(self.gpa, .{ .name = fname, .dflt = "0" });
                // pointee is a 4-byte fn-ptr slot (a __FTABLE index), so `(*name)`
                // and `(*name) = idx` use the ordinary 32-bit heap load/store.
                try self.vars.put(fname, .{ .ty = .{
                    .kind = .ptr,
                    .elem = .{ .bits = 32, .signed = false, .float = false },
                } });
                try self.local_array_names.append(self.gpa, fname); // purge per-fn
                if (stars == 1) {
                    try self.fn_ptr_vars.put(fname, {});
                }
                return null;
            }
        }

        const name_tok: Token = self.current();
        if (name_tok.kind != .ident) {
            while (self.current().kind != .eof and !self.atText(";")) {
                self.p += 1;
            }
            _ = self.consume(";");
            return null;
        }
        self.p += 1;
        const name: []const u8 = name_tok.text;

        // Local packed-struct value: the C backend lowers a packed struct to a
        // single integer typedef (`typedef uint8_t bitpack__...;`), then takes its
        // address and read-modify-writes through the pointer (`&t0`, `(*p) = ...`).
        // So the local needs real backing memory — give it a heap scratch slot and
        // map name -> offset. `&t0` then resolves to the slot (the `&ident` ->
        // globals fallthrough) and the existing pointer-deref + bit-op helpers
        // (zig_shr_u8 / zig_and_u8 / bare `<<`,`|`) do the field packing. The
        // packing was never the issue — only the address-taken scalar local was.
        // A POINTER to a packed struct (`bitpack__... const *p`) is NOT a packed-struct
        // value — it's a 32-bit address — so it must fall through to the pointer/struct-
        // pointer handling, not be heap-backed as the backing integer.
        for (specs) |sp| {
            if (sp.kind == .ident and countStars(specs) == 0) {
                if (self.bitpack_sizes.get(sp.text)) |sz| {
                    if (sz <= 8) {
                        // <=64-bit packed struct: the whole value fits one heap slot and
                        // the field packing the backend emits (`*(&p)` RMW with bare
                        // `<<`,`&`,`|`, plus whole-value `@bitCast` via heapLoad/heapStore)
                        // is exact. For sz>4 the backing is a u64, so it rides the 64-bit
                        // BigInt path: __ldu64/__st64 (two 32-bit words) and BigInt bit-ops
                        // (parseBinary lifts the un-cast shift amount). Treat it like an
                        // address-taken scalar local: one slot that `&p`/the RMW and a
                        // whole-value read or store all reach. A single home is required —
                        // if the read and the store resolved to different locations, a
                        // store could write a JS variable the read never sees, miscompiling
                        // @bitCast of/to a packed struct.
                        const off: u32 = self.allocScratch(sz);
                        try self.scalar_slots.put(name, off);
                        try self.addr_taken.put(name, {});
                        try self.vars.put(name, .{ .ty = .{
                            .kind = .int,
                            .bits = @intCast(sz * 8),
                            .signed = false,
                        } });
                        try self.local_array_names.append(self.gpa, name); // purge per-fn
                        _ = self.consume(";");
                        return null;
                    }
                    // >64-bit packed struct (u65..u128 backing): needs 128-bit word-split
                    // heap storage (heapLoad/heapStore only model up to 64-bit). Flag it
                    // loudly instead of miscompiling silently.
                    try self.vars.put(name, .{ .ty = .{ .kind = .other } });
                    try self.locals.append(self.gpa, .{ .name = name, .dflt = "0" });
                    _ = self.consume(";");
                    return try allocPrint(
                        self.gpa,
                        "/*?packed-struct>64bit: {s} needs 128-bit word-split heap storage*/ 0",
                        .{name},
                    );
                }
            }
        }

        // Struct-pointer local (`struct Tag const *t1;`): track the pointee tag
        // so `&t1->field` resolves to t1 + fieldOffset. The temp itself holds a
        // heap offset (a "pointer" in our model), declared as a normal JS local.
        if (structPtrTagOf(self, specs)) |tag| {
            try self.struct_ptrs.put(name, tag);
            const stars: usize = countStars(specs);
            if (stars >= 2) {
                try self.pp_struct_ptrs.put(name, {});
            }
            try self.local_array_names.append(self.gpa, name); // purge per-fn
            try self.vars.put(name, .{ .ty = .{ .kind = .ptr, .struct_tag = tag } });
            try self.locals.append(self.gpa, .{ .name = name, .dflt = "0" });
            // Address-taken single-star struct pointer (`&t4` ESCAPES — e.g. passed
            // to a helper as `Node **`, or stored where it is loaded back): the
            // pointer VARIABLE itself needs real backing memory so `&t4` is a true
            // slot address and the callee's `*a0` loads the stored pointer. Give it a
            // 4-byte scalar slot (still kept in struct_ptrs so `t4->field` resolves
            // the tag; the chain below loads the pointer value from the slot). Without
            // this `&t4` collapses to t4's value and the callee dereferences garbage.
            // Gated on stars==1: a double-star address-taken local would conflict with
            // the pp_load provenance machinery (rare; left to the xfail ledger).
            if (stars == 1 and self.addr_taken.contains(name)) {
                const off: u32 = self.allocScratch(4);
                try self.scalar_slots.put(name, off);
                if (self.recursive_fns.contains(self.cur_fn)) {
                    try self.frame_off.put(name, self.allocFrame(4));
                }
                const pe: Elem = .{ .bits = 32, .signed = false, .float = false };
                const addrs: []const u8 = try self.scratchBase(name, off);
                if (self.atText("=")) {
                    self.p += 1;
                    self.addr_local_collapse = false;
                    const rhs: []const u8 = try self.parseAssign();
                    _ = self.consume(";");
                    return try allocPrint(self.gpa, "({s})", .{try self.heapStore(pe, addrs, rhs)});
                }
                _ = self.consume(";");
                return null;
            }
            if (self.atText("=")) {
                self.p += 1;
                self.addr_local_collapse = false;
                const rhs: []const u8 = try self.parseAssign();
                try self.notePpProvenance(name);
                _ = self.consume(";");
                return try allocPrint(self.gpa, "({s} = {s})", .{ name, rhs });
            }
            _ = self.consume(";");
            return null;
        }

        // Local fixed-array (`struct arr_N_T t0;`)? It has its address taken
        // (passed to js_string_into, etc.), so it needs real backing memory.
        // Give it a static scratch slot in the heap and record name -> offset so
        // `&t0` and `t0.array[i]` resolve to heap accesses. Single-threaded and
        // non-reentrant through these buffers, so a static slot is safe.
        if (arrayStructInfo(specs)) |info| {
            const off: u32 = self.allocScratch(info.count * info.elem_size);
            try self.globals.put(name, off);
            // Recursive function: also give this array a frame slot so its address is
            // per-call (the consumption sites read frame_off via scratchBase).
            if (self.recursive_fns.contains(self.cur_fn)) {
                try self.frame_off.put(name, self.allocFrame(info.count * info.elem_size));
            }
            try self.array_elems.put(name, info.elem);
            try self.local_array_names.append(self.gpa, name);
            // Also record the wrapper struct tag (the `arr_N_T` struct is in
            // `self.structs`). This lets a struct-value assignment to the whole
            // array — `t0 = (arr_4_i32){{...}}` — go through the byte-copy path
            // in parseAssign and land in this slot, so `&t0` (and a slice built
            // from it) point at the data. Element access `t0.array[i]` still
            // resolves via array_elems, which parsePostfix checks first.
            if (structTypeNameOf(specs)) |atag| {
                if (self.structs.contains(atag)) {
                    try self.struct_vars.put(name, atag);
                }
            }
            // still hoist a (harmless, unused) JS local for the name
            try self.vars.put(name, .{ .ty = .{ .kind = .other } });
            try self.locals.append(self.gpa, .{ .name = name, .dflt = "0" });
            _ = self.consume(";");
            return null;
        }

        // Local struct value (`struct Tag t0;`). Like arrays, its address is
        // taken (`&t0.field`, `&t0` passed by value to helpers), so it needs
        // real backing memory. Give it a heap scratch slot and record the tag so
        // `&t0.field` and struct copies resolve to heap accesses.
        if (structTagOf(self, specs)) |tag| {
            if (self.structs.get(tag)) |layout| {
                const off: u32 = self.allocScratch(layout.size);
                try self.globals.put(name, off);
                // Recursive function: give this struct a per-call frame slot.
                if (self.recursive_fns.contains(self.cur_fn)) {
                    try self.frame_off.put(name, self.allocFrame(layout.size));
                }
                try self.struct_vars.put(name, tag);
                try self.local_array_names.append(self.gpa, name); // purged per-fn like arrays
                try self.vars.put(name, .{ .ty = .{ .kind = .strct, .struct_tag = tag } });
                try self.locals.append(self.gpa, .{ .name = name, .dflt = "0" });
                // optional initializer: `struct Tag t0 = <expr>;` -> struct copy
                if (self.atText("=")) {
                    self.p += 1;
                    const rhs: []const u8 = try self.parseAssign();
                    _ = self.consume(";");
                    // copy `layout.size` bytes from rhs offset to this struct's slot
                    return try allocPrint(
                        self.gpa,
                        "__copy({s}, {s}, {d})",
                        .{ try self.scratchBase(name, off), rhs, layout.size },
                    );
                }
                _ = self.consume(";");
                return null;
            }
        }

        if (self.atText("[") or self.atText("(")) { // arrays / fn-ptr -> milestone 3
            while (self.current().kind != .eof and !self.atText(";")) {
                self.p += 1;
            }
            _ = self.consume(";");
            ty.kind = .other;
            try self.vars.put(name, .{ .ty = ty });
            return null;
        }

        // Address-taken scalar local: `&w` was seen for this name and it's a plain
        // int/float scalar (aggregates handled above). Like an aggregate it needs
        // real backing memory, so `&w` is a true address — reads load and writes
        // store through the heap (heapLoad/heapStore, so 64-bit works too). Only
        // triggers when the pre-scan flagged the name, so functions without any
        // address-taken scalar are completely unaffected.
        if ((ty.kind == .int or ty.kind == .float or ty.kind == .ptr) and self.addr_taken.contains(name)) {
            const e: Elem = .{
                .bits = if (ty.bits == 0) 32 else ty.bits,
                .signed = ty.signed,
                .float = ty.kind == .float,
            };
            const off: u32 = self.allocScratch(@intCast(elemSize(e)));
            try self.scalar_slots.put(name, off);
            // Recursive function: give this address-taken scalar a per-call frame slot.
            if (self.recursive_fns.contains(self.cur_fn)) {
                try self.frame_off.put(name, self.allocFrame(@intCast(elemSize(e))));
            }
            try self.vars.put(name, .{ .ty = ty });
            try self.local_array_names.append(self.gpa, name); // purge per-fn
            const addrs: []const u8 = try self.scratchBase(name, off);
            const init_js: ?[]const u8 = if (self.consume("=")) blk: {
                const init_e: []const u8 = try self.parseExpr();
                break :blk try self.heapStore(e, addrs, try self.wrap(init_e, ty));
            } else null;
            self.expect(";");
            return init_js;
        }

        try self.vars.put(name, .{ .ty = ty });
        const is_bigint: bool = ty.bits == 64 or ty.bits == 128;
        const dflt: []const u8 = if (ty.kind == .boolean) "false" else if (is_bigint) "0n" else "0";
        try self.locals.append(self.gpa, .{ .name = name, .dflt = dflt });

        if (self.consume("=")) {
            const init_e: []const u8 = try self.parseExpr();
            self.expect(";");
            return try allocPrint(self.gpa, "{s} = {s}", .{ name, try self.wrap(init_e, ty) });
        }
        self.expect(";");
        return null;
    }

    // ------------------------------------------------------------------------
    // Lowering: AST -> flat ops (all control flow -> conditional gotos)
    // ------------------------------------------------------------------------
    // STAGE 4a — control-flow lowering. Walk the Stmt tree and append a flat list
    // of Ops (line | ret | label | goto | cgoto). Every if/while/for/switch and
    // every break/continue is rewritten into conditional gotos against fresh labels
    // (break/continue resolve through brk_stack/cont_stack). This collapses our
    // structured statements into the SAME goto currency the C backend already emits
    // — so emitBody downstream has just one shape to render.
    fn flatten(
        self: *Transpiler,
        stmts: []const Stmt,
        out: *ArrayList(FlowOp),
    ) error{OutOfMemory}!void {
        for (stmts) |s| {
            switch (s) {
                .raw => |x| try out.append(
                    self.gpa,
                    .{ .line = .{ .text = x.text, .src = x.src } },
                ),
                .ret => |e| try out.append(self.gpa, .{ .ret = .{ .val = e.val, .src = e.src } }),
                .label => |l| try out.append(self.gpa, .{ .label = l }),
                .goto => |g| try out.append(self.gpa, .{ .goto = g }),
                .empty => {},
                .block => |b| try self.flatten(b, out),
                .brk => try out.append(
                    self.gpa,
                    .{ .goto = self.brk_stack.items[self.brk_stack.items.len - 1] },
                ),
                .cont => try out.append(
                    self.gpa,
                    .{ .goto = self.cont_stack.items[self.cont_stack.items.len - 1] },
                ),
                .if_ => |f| {
                    const ncond: []u8 = try allocPrint(self.gpa, "!({s})", .{f.cond});
                    if (f.els) |els| {
                        const l_else: []const u8 = try self.freshLabel();
                        const l_end: []const u8 = try self.freshLabel();
                        try out.append(
                            self.gpa,
                            .{ .cgoto = .{ .cond = ncond, .target = l_else } },
                        );
                        try self.flatten(f.then, out);
                        try out.append(self.gpa, .{ .goto = l_end });
                        try out.append(self.gpa, .{ .label = l_else });
                        try self.flatten(els, out);
                        try out.append(self.gpa, .{ .label = l_end });
                    } else {
                        const l_end: []const u8 = try self.freshLabel();
                        try out.append(self.gpa, .{ .cgoto = .{ .cond = ncond, .target = l_end } });
                        try self.flatten(f.then, out);
                        try out.append(self.gpa, .{ .label = l_end });
                    }
                },
                .while_ => |w| {
                    const l_top: []const u8 = try self.freshLabel();
                    const l_end: []const u8 = try self.freshLabel();
                    const ncond: []u8 = try allocPrint(self.gpa, "!({s})", .{w.cond});
                    try out.append(self.gpa, .{ .label = l_top });
                    try out.append(self.gpa, .{ .cgoto = .{ .cond = ncond, .target = l_end } });
                    try self.brk_stack.append(self.gpa, l_end);
                    try self.cont_stack.append(self.gpa, l_top);
                    try self.flatten(w.body, out);
                    self.brk_stack.items.len -= 1;
                    self.cont_stack.items.len -= 1;
                    try out.append(self.gpa, .{ .goto = l_top });
                    try out.append(self.gpa, .{ .label = l_end });
                },
                .for_ => |f| {
                    if (f.init) |x| {
                        try out.append(self.gpa, .{ .line = .{ .text = x } });
                    }
                    const l_top: []const u8 = try self.freshLabel();
                    const l_cont: []const u8 = try self.freshLabel();
                    const l_end: []const u8 = try self.freshLabel();
                    try out.append(self.gpa, .{ .label = l_top });
                    if (f.cond) |c| {
                        const ncond: []u8 = try allocPrint(self.gpa, "!({s})", .{c});
                        try out.append(self.gpa, .{ .cgoto = .{ .cond = ncond, .target = l_end } });
                    }
                    try self.brk_stack.append(self.gpa, l_end);
                    try self.cont_stack.append(self.gpa, l_cont);
                    try self.flatten(f.body, out);
                    self.brk_stack.items.len -= 1;
                    self.cont_stack.items.len -= 1;
                    try out.append(self.gpa, .{ .label = l_cont });
                    if (f.step) |x| {
                        try out.append(self.gpa, .{ .line = .{ .text = x } });
                    }
                    try out.append(self.gpa, .{ .goto = l_top });
                    try out.append(self.gpa, .{ .label = l_end });
                },
                .switch_ => |sw| {
                    const l_end: []const u8 = try self.freshLabel();
                    const tmp: []u8 = try allocPrint(self.gpa, "__sw{d}", .{self.tmp_counter});
                    self.tmp_counter += 1;
                    var labels: ArrayList([]const u8) = .empty;
                    for (sw.cases) |_| {
                        try labels.append(self.gpa, try self.freshLabel());
                    }
                    const decl_txt: []u8 = try allocPrint(self.gpa, "let {s} = ({s})", .{ tmp, sw.expr });
                    try out.append(
                        self.gpa,
                        .{ .line = .{ .text = decl_txt } },
                    );
                    try self.brk_stack.append(self.gpa, l_end);
                    var default_label: ?[]const u8 = null;
                    for (sw.cases, 0..) |c, i| {
                        if (c.value) |v| {
                            const cond: []u8 = try allocPrint(
                                self.gpa,
                                "{s} === ({s})",
                                .{ tmp, v },
                            );
                            try out.append(
                                self.gpa,
                                .{ .cgoto = .{ .cond = cond, .target = labels.items[i] } },
                            );
                        } else {
                            default_label = labels.items[i];
                        }
                    }
                    try out.append(self.gpa, .{ .goto = default_label orelse l_end });
                    for (sw.cases, 0..) |c, i| {
                        try out.append(self.gpa, .{ .label = labels.items[i] });
                        try self.flatten(c.body, out);
                    }
                    self.brk_stack.items.len -= 1;
                    try out.append(self.gpa, .{ .label = l_end });
                },
            }
        }
    }

    // ------------------------------------------------------------------------
    // Codegen: flat ops -> JS (straight-line, or trampoline if control flow)
    // ------------------------------------------------------------------------
    fn emitBody(self: *Transpiler, ops: []const FlowOp) error{OutOfMemory}!void {
        var has_cf: bool = false;
        for (ops) |op| {
            switch (op) {
                .label, .goto, .cgoto => has_cf = true,
                else => {},
            }
        }

        if (!has_cf) {
            for (ops) |op| {
                switch (op) {
                    .line => |s| {
                        if (s.src != 0) {
                            self.cur_src_line = s.src;
                        }
                        try self.print("  {s};\n", .{s.text});
                    },
                    .ret => |e| {
                        if (e.src != 0) {
                            self.cur_src_line = e.src;
                        }
                        if (e.val) |x| {
                            try self.print("  return {s};\n", .{x});
                        } else {
                            try self.emit("  return;\n");
                        }
                    },
                    else => {},
                }
            }
            return;
        }

        // Split ops into basic blocks at labels; block i == switch state i.
        var blocks: ArrayList(ArrayList(FlowOp)) = .empty;
        {
            const b0: ArrayList(FlowOp) = .empty;
            try blocks.append(self.gpa, b0);
        }
        var label_state = StringHashMap(usize).init(self.gpa);
        for (ops) |op| {
            switch (op) {
                .label => |nm| {
                    const nb: ArrayList(FlowOp) = .empty;
                    try blocks.append(self.gpa, nb);
                    try label_state.put(nm, blocks.items.len - 1);
                },
                else => try blocks.items[blocks.items.len - 1].append(self.gpa, op),
            }
        }
        const num: usize = blocks.items.len;

        // Jump threading. A "trampoline" block — one whose only effect is a single
        // unconditional jump (no statements, no return, no conditional branch) —
        // arises constantly from the C backend's nested `zig_block_N:` labels that
        // just chain gotos. `thread[i]` is the FINAL real block reached by following
        // such pure jumps from i, so every goto / fallthrough / the initial state
        // can target it directly. This removes the redundant switch re-dispatches a
        // trampoline forces (a loop back-edge went body -> trampoline -> header, two
        // dispatches per iteration; threaded it is one — ~2x on tight loops).
        const thread: []usize = try self.gpa.alloc(usize, num + 1);
        for (0..num + 1) |i| {
            thread[i] = i;
        }
        for (0..num) |start| {
            var cur: usize = start;
            var steps: usize = 0;
            while (steps <= num) : (steps += 1) {
                if (cur >= num) {
                    break;
                }
                var tgt: ?usize = null;
                var pure: bool = true;
                for (blocks.items[cur].items) |op| switch (op) {
                    .label => {},
                    .goto => |t| {
                        if (tgt != null) {
                            pure = false; // more than one jump
                        }
                        tgt = label_state.get(t) orelse num;
                    },
                    else => pure = false, // .line / .ret / .cgoto -> a real block
                };
                if (!pure) {
                    break;
                }
                const nxt: usize = tgt orelse (cur + 1); // empty block falls through
                if (nxt == cur) {
                    break; // self-loop (`while (true) {}`): keep it
                }
                cur = nxt;
            }
            thread[start] = cur;
        }

        try self.print("  let __s = {d};\n  __loop: while (true) {{\n    switch (__s) {{\n", .{thread[0]});
        for (blocks.items, 0..) |blk, i| {
            try self.print("      case {d}: {{\n", .{i});
            // A block whose final op is an unconditional jump back to ITSELF — the
            // back-edge of a counting/`while` loop after threading — is emitted as a
            // real `while (true)` so V8 optimizes the hot loop instead of paying a
            // switch re-dispatch every iteration (~3x on tight loops). Mid-block
            // cgotos break the inner while; the case's trailing `break` re-dispatches
            // to the chosen state. Reaching the end loops naturally (the dropped
            // back-edge). Everything else is emitted exactly as before.
            const n_ops: usize = blk.items.len;
            const self_loop: bool = n_ops > 0 and switch (blk.items[n_ops - 1]) {
                .goto => |t| thread[label_state.get(t) orelse num] == i,
                else => false,
            };
            const body_end: usize = if (self_loop) n_ops - 1 else n_ops; // drop the back-edge
            const ind: []const u8 = if (self_loop) "  " else "";
            if (self_loop) {
                try self.emit("        while (true) {\n");
            }
            for (blk.items[0..body_end]) |op| {
                switch (op) {
                    .line => |s| {
                        if (s.src != 0) {
                            self.cur_src_line = s.src;
                        }
                        try self.print("        {s}{s};\n", .{ ind, s.text });
                    },
                    .ret => |e| {
                        if (e.src != 0) {
                            self.cur_src_line = e.src;
                        }
                        if (e.val) |x| {
                            try self.print("        {s}return {s};\n", .{ ind, x });
                        } else {
                            try self.print("        {s}return;\n", .{ind});
                        }
                    },
                    .goto => |target| try self.print(
                        "        {s}__s = {d}; break;\n",
                        .{ ind, thread[label_state.get(target) orelse num] },
                    ),
                    .cgoto => |cg| try self.print(
                        "        {s}if ({s}) {{ __s = {d}; break; }}\n",
                        .{ ind, cg.cond, thread[label_state.get(cg.target) orelse num] },
                    ),
                    .label => {},
                }
            }
            if (self_loop) {
                try self.emit("        }\n        break;\n");
            } else {
                const fallthrough: bool = n_ops == 0 or switch (blk.items[n_ops - 1]) {
                    .goto, .ret => false,
                    else => true,
                };
                if (fallthrough) {
                    try self.print("        __s = {d}; break;\n", .{thread[i + 1]});
                }
            }
            try self.emit("      }\n");
        }
        try self.emit("      default: break __loop;\n    }\n  }\n");
    }

    // ------------------------------------------------------------------------
    // Expressions (precedence climbing) -> JS string
    // ------------------------------------------------------------------------

    /// Mask/coerce a JS expression string to C store semantics for `ty`.
    fn wrap(
        self: *Transpiler,
        e_in: []const u8,
        ty: CType,
    ) ![]const u8 {
        // A lo/hi wide extract lowers to `Number(BigInt.asUintN(64, X))` — a Number
        // by design (for index / Number contexts). But when it feeds a >32-bit
        // destination (a BigInt u64/wide local, e.g. a __st64 store), re-wrapping a
        // Number in asUintN throws "cannot convert to a BigInt". Recover the inner
        // BigInt by stripping the Number() so the wide destination receives a BigInt.
        var e: []const u8 = e_in;
        if (ty.kind == .int and ty.bits > 32 and outerCallIs(e, "Number")) {
            const inner: []const u8 = e["Number(".len .. e.len - 1];
            if (startsWith(u8, inner, "BigInt.")) {
                e = inner;
            }
        }
        switch (ty.kind) {
            .int => {
                if (ty.bits == 128) {
                    // 128-bit values are BigInts already masked to width by the
                    // bigInt128 helpers; a Number coercion (| 0 / & mask) would throw
                    // ("cannot mix BigInt and other types"). Leave the expression as-is.
                    return e;
                }
                if (ty.bits == 64) {
                    // 64-bit values are now BigInts (exact past 2^53). Wrapping
                    // arithmetic already masks via the zig_*_u64 helpers; a plain
                    // assignment/coercion just needs the value re-narrowed to 64 bits
                    // so a non-wrapping `+`/`*` that overran stays in range. asIntN/
                    // asUintN are no-ops on an already-in-range BigInt. (Number ops
                    // like `| 0` would throw "cannot mix BigInt".)
                    if (ty.signed) {
                        if (outerCallIs(e, "BigInt.asIntN")) {
                            return e;
                        }
                        return allocPrint(self.gpa, "BigInt.asIntN(64,{s})", .{e});
                    }
                    if (outerCallIs(e, "BigInt.asUintN")) {
                        return e;
                    }
                    return allocPrint(self.gpa, "BigInt.asUintN(64,{s})", .{e});
                }
                if (ty.bits > 32 and ty.bits <= 64) {
                    // 33-64 bit integers live in int64_t/uint64_t C storage and are
                    // BigInts in this model (exact past 2^53). Mask/sign-extend to the
                    // REAL width with asUintN/asIntN(bits, …) — a plain `& mask` here
                    // used a Number mask literal and threw "cannot mix BigInt and other
                    // types" against the BigInt value (e.g. a `@bitCast` to u40 that
                    // spilled through __ldu64). asUintN/asIntN are no-ops on an
                    // already-in-range BigInt, so the outerCallIs guard avoids a
                    // redundant re-wrap.
                    if (ty.signed) {
                        if (outerCallIs(e, "BigInt.asIntN")) {
                            return e;
                        }
                        return allocPrint(self.gpa, "BigInt.asIntN({d},{s})", .{ ty.bits, e });
                    }
                    if (outerCallIs(e, "BigInt.asUintN")) {
                        return e;
                    }
                    return allocPrint(self.gpa, "BigInt.asUintN({d},{s})", .{ ty.bits, e });
                }
                if (!ty.signed) {
                    if (ty.bits == 32) {
                        if (outerWrapIs(e, " >>> 0")) {
                            return e; // already u32-canonical
                        }
                        return allocPrint(self.gpa, "(({s}) >>> 0)", .{e});
                    }
                    const mask = (@as(u64, 1) << @intCast(ty.bits)) - 1;
                    const suffix: []u8 = try allocPrint(self.gpa, " & {d}", .{mask});
                    if (outerWrapIs(e, suffix)) {
                        return e; // already masked to this width
                    }
                    return allocPrint(self.gpa, "(({s}) & {d})", .{ e, mask });
                } else {
                    if (ty.bits == 32) {
                        if (outerWrapIs(e, " | 0")) {
                            return e; // already i32-canonical
                        }
                        return allocPrint(self.gpa, "(({s}) | 0)", .{e});
                    }
                    const sh: u6 = @intCast(32 - ty.bits);
                    return allocPrint(self.gpa, "((({s}) << {d}) >> {d})", .{ e, sh, sh });
                }
            },
            // float (no int mask; fround for f32 is a later refinement), bool, ptr, void, other
            else => return e,
        }
    }

    // The expression layer's front door. There is NO expression AST: every parse*
    // below RETURNS the finished JavaScript for its sub-expression as a string, so
    // parsing and emitting an expression are the same act. The chain climbs
    // precedence: parseExpr -> parseAssign -> parseBinary(0..N) -> parseUnary ->
    // parsePostfix -> parsePrimary. parseExpr itself is just the entry (lowest
    // precedence, i.e. assignment).
    fn parseExpr(self: *Transpiler) error{OutOfMemory}![]const u8 {
        return self.parseAssign();
    }

    const assign_ops = [_][]const u8{
        "=",
        "+=",
        "-=",
        "*=",
        "/=",
        "%=",
        "&=",
        "|=",
        "^=",
        "<<=",
        ">>=",
    };

    // Assignment level (loosest binding) and the home of struct-by-value STORES.
    // Before the generic `lhs OP= rhs`, it special-cases destinations that must
    // become __MEM writes rather than JS variable assignments: `structVar.field =`,
    // `structVar.array[i] =` (SIMD lanes), `*ptr =`, and friends. Non-assignments
    // fall straight through to parseBinary.
    /// After assigning an RHS to `name`, if `name` is a double-star struct
    /// pointer (`pp_struct_ptrs`), record whether `*name` must LOAD (it holds a
    /// heap address — a `&ptr->field` / `&var.field` / param slot) or stay
    /// identity (it aliases a bare local via the `&local` round-trip). The
    /// distinction is the `addr_local_collapse` flag, set by the `&` handler's
    /// bare-local passthrough; any heap address leaves it false. Only call this
    /// for a plain `=` (an `op=` does not re-seat the pointer's provenance).
    fn notePpProvenance(self: *Transpiler, name: []const u8) error{OutOfMemory}!void {
        if (!self.pp_struct_ptrs.contains(name)) {
            return;
        }
        if (self.addr_local_collapse) {
            _ = self.pp_load.remove(name); // aliases a local -> deref is identity
        } else {
            try self.pp_load.put(name, {}); // holds a heap address -> deref loads
        }
    }

    fn parseAssign(self: *Transpiler) error{OutOfMemory}![]const u8 {
        // --- struct field/copy stores (struct-by-value support) ---
        const head_tok: Token = self.current();
        if (head_tok.kind == .ident) {
            // structVar.field = rhs   ->   heap store at structOff + fieldOff
            if (self.struct_vars.get(head_tok.text)) |tag| {
                // structVar.array[idx] = rhs  -> typed-array element store (SIMD
                // vector lanes; the field is itself an array). Confirm a `=`
                // follows the `]` before committing so rvalue uses fall through.
                if (eql(u8, self.lookahead(1).text, ".") and self.lookahead(2).kind == .ident and
                    eql(u8, self.lookahead(3).text, "["))
                {
                    const fname: []const u8 = self.lookahead(2).text;
                    if (self.fieldOf(tag, fname)) |f| {
                        const close: usize = self.matching(self.p + 3, "[", "]");
                        if (close + 1 < self.toks.len and eql(u8, self.toks[close + 1].text, "=")) {
                            self.p += 4; // name . field [
                            const idx: []const u8 = try self.parseExpr();
                            self.expect("]");
                            self.expect("=");
                            const rhs: []const u8 = try self.parseAssign();
                            const elem = Elem{
                                .bits = f.bits,
                                .signed = f.signed,
                                .float = f.float,
                            };
                            const base: []u8 = if (self.globals.get(head_tok.text)) |off|
                                try allocPrint(
                                    self.gpa,
                                    "({s} + {d})",
                                    .{ try self.scratchBase(head_tok.text, off), f.offset },
                                )
                            else
                                try allocPrint(self.gpa, "(({s}) + {d})", .{ head_tok.text, f.offset });
                            const ety = CType{
                                .kind = if (f.float) .float else .int,
                                .bits = f.bits,
                                .signed = f.signed,
                            };
                            // A struct element (`f.struct_tag`) strides by the
                            // WHOLE struct size and the store is a byte COPY of the
                            // source struct (rhs is its heap offset) — NOT a scalar
                            // store of the offset at stride 4, which silently
                            // miscompiled storing a struct into an array-wrapper
                            // element (e.g. @memset of a struct array, whose fill
                            // loop is `t.array[i] = (struct P){...}`).
                            if (f.struct_tag) |st| {
                                if (self.structs.get(st)) |layout| {
                                    const saddr: []const u8 = try allocPrint(
                                        self.gpa,
                                        "(({s}) + ({s}) * {d})",
                                        .{ base, idx, layout.size },
                                    );
                                    return allocPrint(self.gpa, "__copy({s}, {s}, {d})", .{ saddr, rhs, layout.size });
                                }
                            }
                            return allocPrint(self.gpa, "({s})", .{try self.heapStore(
                                elem,
                                try allocPrint(self.gpa, "(({s}) + ({s}) * {d})", .{ base, idx, elemSize(elem) }),
                                try self.wrap(rhs, ety),
                            )});
                        }
                    }
                }
                // structVar . f1 . f2 = rhs  ->  store at f1.offset + f2.offset.
                // The Zig C backend emits this DIRECT two-level form for a UNION
                // payload field (e.g. `t1.payload.big = t0`); a nested STRUCT field
                // is instead written through a pointer (handled elsewhere). This branch
                // is what carries the u64/f64 payload store to memory — without it the
                // store would lower as a LOAD and the value would never be written. f1
                // carries the inner struct/union tag (struct_tag), within which f2
                // resolves — same as the read path.
                if (eql(u8, self.lookahead(1).text, ".") and self.lookahead(2).kind == .ident and
                    eql(u8, self.lookahead(3).text, ".") and self.lookahead(4).kind == .ident and
                    eql(u8, self.lookahead(5).text, "=") and self.globals.get(head_tok.text) != null)
                {
                    if (self.fieldOf(tag, self.lookahead(2).text)) |f1| {
                        if (f1.struct_tag) |itag| {
                            if (self.fieldOf(itag, self.lookahead(4).text)) |f2| {
                                const off: u32 = self.globals.get(head_tok.text).?;
                                self.p += 6; // name . f1 . f2 =
                                const rhs: []const u8 = try self.parseAssign();
                                const base: []const u8 = try self.scratchBase(head_tok.text, off);
                                const addr: []u8 = try allocPrint(
                                    self.gpa,
                                    "(({s}) + {d})",
                                    .{ base, f1.offset + f2.offset },
                                );
                                return try self.fieldStore(addr, f2, rhs);
                            }
                        }
                    }
                }
                if (eql(u8, self.lookahead(1).text, ".") and self.lookahead(2).kind == .ident) {
                    if (self.fieldOf(tag, self.lookahead(2).text)) |f| {
                        if (eql(u8, self.lookahead(3).text, "=") and
                            self.globals.get(head_tok.text) != null)
                        {
                            const off: u32 = self.globals.get(head_tok.text).?;
                            self.p += 4; // name . field =
                            const rhs: []const u8 = try self.parseAssign();
                            // Frame-aware base (recursive locals live at __fp+N, not the
                            // static slot) — see the whole-struct-copy note below.
                            const base: []const u8 = try self.scratchBase(head_tok.text, off);
                            const addr: []u8 = try allocPrint(self.gpa, "(({s}) + {d})", .{ base, f.offset });
                            return try self.fieldStore(addr, f, rhs);
                        }
                    }
                }
                // structVar = rhs  ->  copy bytes (struct value assignment)
                if (eql(u8, self.lookahead(1).text, "=") and self.globals.get(head_tok.text) != null) {
                    if (self.structs.get(tag)) |layout| {
                        const off: u32 = self.globals.get(head_tok.text).?;
                        self.p += 2; // name =
                        const rhs: []const u8 = try self.parseAssign();
                        // Destination must be the local's REAL backing address: in a
                        // recursive function an address-taken struct local lives on the
                        // shadow-stack frame (__fp + N), not its static slot. scratchBase
                        // resolves to whichever applies, so the stored value and a later
                        // `&t0` agree (using the raw static `off` here wrote the value to
                        // the static slot while `&t0` read the frame — silently losing it).
                        const dst: []const u8 = try self.scratchBase(head_tok.text, off);
                        return try allocPrint(
                            self.gpa,
                            "__copy({s}, {s}, {d})",
                            .{ dst, rhs, layout.size },
                        );
                    }
                }
            }
            // ptr->field[idx] = rhs : element store through a struct/wrapper
            // pointer. The Zig C backend emits this for a `[N][M]T` row fill —
            // `t4->array[i] = v` where `t4 : arr_M_T*` (the inner row pointer, e.g.
            // from `@memset(row, v)` over `for (&grid) |*row|`). The single-field
            // `ptr->field =` handler below doesn't cover the `[idx]` element form,
            // so without this the per-element store was dropped (orphaned load).
            if (self.struct_ptrs.get(head_tok.text)) |tag| {
                if (eql(u8, self.lookahead(1).text, "->") and self.lookahead(2).kind == .ident and
                    eql(u8, self.lookahead(3).text, "["))
                {
                    if (self.fieldOf(tag, self.lookahead(2).text)) |f| {
                        const close: usize = self.matching(self.p + 3, "[", "]");
                        if (close + 1 < self.toks.len and eql(u8, self.toks[close + 1].text, "=") and
                            !eql(u8, self.toks[close + 2].text, "="))
                        {
                            const ptr: []const u8 = head_tok.text;
                            self.p += 4; // ptr -> field [
                            const idx: []const u8 = try self.parseExpr();
                            self.expect("]");
                            self.expect("=");
                            const rhs: []const u8 = try self.parseAssign();
                            // A struct element strides by the whole struct size and is
                            // stored as a byte copy; a scalar element strides by its size.
                            if (f.struct_tag) |st| {
                                if (self.structs.get(st)) |layout| {
                                    const saddr: []const u8 = try allocPrint(
                                        self.gpa,
                                        "(({s}) + {d} + ({s}) * {d})",
                                        .{ ptr, f.offset, idx, layout.size },
                                    );
                                    return allocPrint(self.gpa, "__copy({s}, {s}, {d})", .{ saddr, rhs, layout.size });
                                }
                            }
                            const elem = Elem{ .bits = f.bits, .signed = f.signed, .float = f.float };
                            const ety = CType{
                                .kind = if (f.float) .float else .int,
                                .bits = f.bits,
                                .signed = f.signed,
                            };
                            const addr: []const u8 = try allocPrint(
                                self.gpa,
                                "(({s}) + {d} + ({s}) * {d})",
                                .{ ptr, f.offset, idx, elemSize(elem) },
                            );
                            return allocPrint(
                                self.gpa,
                                "({s})",
                                .{try self.heapStore(elem, addr, try self.wrap(rhs, ety))},
                            );
                        }
                    }
                }
            }
            // ptr->field = rhs   ->   heap store at ptrValue + fieldOff
            if (self.struct_ptrs.get(head_tok.text)) |tag| {
                if (eql(u8, self.lookahead(1).text, "->") and self.lookahead(2).kind == .ident) {
                    if (self.fieldOf(tag, self.lookahead(2).text)) |f| {
                        if (eql(u8, self.lookahead(3).text, "=")) {
                            const ptr: []const u8 = head_tok.text;
                            self.p += 4; // ptr -> field =
                            const rhs: []const u8 = try self.parseAssign();
                            const addr: []u8 = try allocPrint(
                                self.gpa,
                                "(({s}) + {d})",
                                .{ ptr, f.offset },
                            );
                            return try self.fieldStore(addr, f, rhs);
                        }
                    }
                }
            }
        }
        // store through a pointer:  (*P) = rhs   (the store shape the backend emits)
        if (self.atText("(") and eql(u8, self.lookahead(1).text, "*") and
            self.lookahead(2).kind == .ident and eql(u8, self.lookahead(3).text, ")") and
            eql(u8, self.lookahead(4).text, "="))
        {
            const nm: []const u8 = self.lookahead(2).text;
            // (*pp) = ptrValue : a DOUBLE-star struct pointer (`struct X **`). The
            // store target is a pointer SLOT, so this writes a 4-byte offset — NOT
            // a struct byte-copy. Must be checked before the single-star struct-copy
            // branch below (which would otherwise __copy layout.size bytes and, for
            // a 4-byte struct, silently dereference the rhs offset). Mirrors the
            // read side, where pp_load/pp_struct_ptrs is consulted before
            // struct_ptrs. `nm` holds the destination address directly (it is a
            // `&slot` heap address, hence in pp_load), so store at `nm` as u32.
            if (self.pp_struct_ptrs.contains(nm)) {
                self.p += 5; // ( * ident ) =
                const rhs: []const u8 = try self.parseAssign();
                const stored: []u8 = if (self.safe)
                    try allocPrint(self.gpa, "__HEAPU32[__idx(({s}), 4) >> 2] = (({s}) >>> 0)", .{ nm, rhs })
                else
                    try allocPrint(self.gpa, "__HEAPU32[({s}) >> 2] = (({s}) >>> 0)", .{ nm, rhs });
                return allocPrint(self.gpa, "({s})", .{stored});
            }
            // (*structPtr) = structValue : copy the whole struct (rhs is an offset).
            if (self.struct_ptrs.get(nm)) |tag| {
                if (self.structs.get(tag)) |layout| {
                    self.p += 5; // ( * ident ) =
                    const rhs: []const u8 = try self.parseAssign();
                    return allocPrint(self.gpa, "__copy({s}, {s}, {d})", .{ nm, rhs, layout.size });
                }
            }
            if (self.vars.get(nm)) |vi| {
                if (vi.ty.kind == .ptr) {
                    if (vi.ty.elem) |e| {
                        self.p += 5; // ( * ident ) =
                        const rhs: []const u8 = try self.parseAssign();
                        const ety = CType{
                            .kind = if (e.float) .float else .int,
                            .bits = e.bits,
                            .signed = e.signed,
                        };
                        return allocPrint(self.gpa, "({s})", .{try self.heapStore(e, nm, try self.wrap(rhs, ety))});
                    }
                }
            }
        }
        // store through a cast pointer:  *((T*)<addr>) = rhs  (global write shape)
        if (self.atText("(") and eql(u8, self.lookahead(1).text, "*")) {
            if (try self.tryDerefCastStore()) |stored| {
                return stored;
            }
        }
        // store through a bare pointer subscript:  ptr[idx] = rhs. The Zig C
        // backend emits this for a vector-literal store into a `[N]@Vector`
        // element — `t = (elemT *)&arr.array[i]; t[k] = zig_make_fNN(...)` — where
        // `t` is a plain pointer local with a known element type. None of the
        // handlers above match (`t` is neither a struct_var/ptr nor a deref), so it
        // fell through to the rvalue path: the subscript lowered to a LOAD and the
        // `= rhs` was silently dropped (the vector stayed zero). Mirror the `(*ptr)`
        // pointer-store branch, adding the `idx * elemSize` element offset.
        if (self.current().kind == .ident and eql(u8, self.lookahead(1).text, "[")) {
            const pname: []const u8 = self.current().text;
            if (self.vars.get(pname)) |vi| {
                if (vi.ty.kind == .ptr) {
                    if (vi.ty.elem) |e| {
                        const close: usize = self.matching(self.p + 1, "[", "]");
                        if (close + 1 < self.toks.len and eql(u8, self.toks[close + 1].text, "=") and
                            !eql(u8, self.toks[close + 2].text, "="))
                        {
                            self.p += 2; // ident [
                            const idx: []const u8 = try self.parseExpr();
                            self.expect("]");
                            self.expect("=");
                            const rhs: []const u8 = try self.parseAssign();
                            const ety = CType{
                                .kind = if (e.float) .float else .int,
                                .bits = e.bits,
                                .signed = e.signed,
                            };
                            const addr: []const u8 = try allocPrint(
                                self.gpa,
                                "(({s}) + ({s}) * {d})",
                                .{ pname, idx, elemSize(e) },
                            );
                            const wrapped: []const u8 = try self.wrap(rhs, ety);
                            const stored: []const u8 = try self.heapStore(e, addr, wrapped);
                            return allocPrint(self.gpa, "({s})", .{stored});
                        }
                    }
                }
            }
        }
        // store to a (possibly nested) field:  *(&LVALUE) = rhs  (the shape the
        // backend emits for optional/union payloads and nested struct fields).
        if (try self.tryDerefAddrOfStore()) |stored| {
            return stored;
        }
        // General lvalue store:  LVALUE = rhs, resolving casts / `->` / `.` / `[i]`
        // to a heap address. Catches shapes the specific handlers above miss —
        // notably the array-wrapper element store `((arr_N_T*)&g)->array[i] = v`
        // that the Zig C backend emits for the fill/copy loop of `@memset` /
        // `@memcpy` on a 64-bit-element array. Previously this fell through and the
        // u64 store was dropped (the LHS lowered to an orphaned `__ldu64` and the
        // RHS to a bare value). Only commit when a plain `=` follows; otherwise
        // restore and let the rvalue path handle it.
        // Direct element store into a primitive-element array wrapper:
        // `((arr_N_T*)&g)->array[i] = rhs` — the shape the Zig C backend emits for
        // the @memset/@memcpy fill/copy loop of a 64-bit-element array (and any
        // direct global-array element store that isn't first hoisted to a `&...`
        // temp). structTagOf diverts these wrappers, so the generic field-store
        // paths miss it and the store was dropped. Handle it narrowly here (a broad
        // parseLValueAddr fallback would mis-handle other aggregate stores).
        if (try self.tryArrayWrapperStore()) |stored| {
            return stored;
        }
        // simple-identifier lvalue assignment (covers Zig C-backend output)
        const t: Token = self.current();
        if (t.kind == .ident and !isTypeQualifierOrSpecifier(t.text)) {
            const nxt: Token = self.lookahead(1);
            var matched: ?[]const u8 = null;
            for (assign_ops) |op| {
                if (eql(u8, nxt.text, op)) {
                    matched = op;
                    break;
                }
            }
            if (matched) |op| {
                const lname: []const u8 = t.text; // the variable name (lvalue)
                self.p += 2; // consume IDENT and the assign op
                if (eql(u8, op, "=")) {
                    self.addr_local_collapse = false;
                }
                const rhs: []const u8 = try self.parseAssign();
                if (eql(u8, op, "=")) {
                    try self.notePpProvenance(lname);
                }
                const vinfo: ?VarInfo = self.vars.get(lname);
                const ty: CType = if (vinfo) |v| v.ty else .{ .kind = .other };
                // address-taken scalar local: store through its heap slot
                // (load+combine+store for `op=`), mirroring the read in parsePrimary.
                if (self.scalar_slots.get(lname)) |off| {
                    const e: Elem = .{
                        .bits = if (ty.bits == 0) 32 else ty.bits,
                        .signed = ty.signed,
                        .float = ty.kind == .float,
                    };
                    const addrs: []const u8 = try self.scratchBase(lname, off);
                    if (eql(u8, op, "=")) {
                        return allocPrint(self.gpa, "({s})", .{try self.heapStore(e, addrs, try self.wrap(rhs, ty))});
                    }
                    const bin_op: []const u8 = op[0 .. op.len - 1];
                    const cur: []const u8 = try self.heapLoad(e, addrs);
                    const combined: []const u8 = try allocPrint(self.gpa, "{s} {s} {s}", .{ cur, bin_op, rhs });
                    return allocPrint(self.gpa, "({s})", .{try self.heapStore(e, addrs, try self.wrap(combined, ty))});
                }
                if (eql(u8, op, "=")) {
                    const wrapped: []const u8 = try self.wrap(rhs, ty);
                    return allocPrint(self.gpa, "({s} = {s})", .{ lname, wrapped });
                } else {
                    // x op= y  ->  x = wrap(x op y)
                    const bin_op: []const u8 = op[0 .. op.len - 1]; // strip '='
                    const combined: []u8 = try allocPrint(
                        self.gpa,
                        "{s} {s} {s}",
                        .{ lname, bin_op, rhs },
                    );
                    const wrapped: []const u8 = try self.wrap(combined, ty);
                    return allocPrint(self.gpa, "({s} = {s})", .{ lname, wrapped });
                }
            }
        }
        // C ternary `cond ? a : b`. The backend lowers most branches to gotos,
        // but emits an INLINE ternary for a few builtins — `@min`/`@max` become
        // `(x < y) ? x : y`. Without this, the `?`/`:` were unparsed: the condition
        // leaked through as the value and the arms were dropped (an orphaned `a;`),
        // silently miscompiling every `@min`/`@max`. Right-associative: the else
        // arm recurses through parseAssign so `a ? b : c ? d : e` nests correctly.
        const cond: []const u8 = try self.parseBinary(0);
        if (self.atText("?")) {
            self.p += 1; // ?
            const then_e: []const u8 = try self.parseAssign();
            self.expect(":");
            const else_e: []const u8 = try self.parseAssign();
            return allocPrint(self.gpa, "(({s}) ? ({s}) : ({s}))", .{ cond, then_e, else_e });
        }
        return cond;
    }

    // Binary precedence table (low -> high). Each level lists its operators.
    const levels = [_][]const []const u8{
        &.{"||"},
        &.{"&&"},
        &.{"|"},
        &.{"^"},
        &.{"&"},
        &.{ "==", "!=" },
        &.{ "<", ">", "<=", ">=" },
        &.{ "<<", ">>" },
        &.{ "+", "-" },
        &.{ "*", "/", "%" },
    };

    // Climber helper: if the current token is a binary operator at precedence
    // `level`, return it, else null. Won't mistake the `<<`/`>>` of a `<<=`/`>>=`
    // compound assignment for a shift.
    fn opAtLevel(self: *Transpiler, level: usize) ?[]const u8 {
        const t: Token = self.current();
        if (t.kind != .punct) {
            return null;
        }
        for (levels[level]) |op| {
            if (eql(u8, t.text, op)) {
                // avoid grabbing assignment compound ops like "<<=" as "<<"
                const nxt: Token = self.lookahead(1);
                if (eql(u8, nxt.text, "=") and
                    (eql(u8, op, "<<") or eql(u8, op, ">>")))
                {
                    return null;
                }
                return op;
            }
        }
        return null;
    }

    // One rung of the precedence ladder. Parse a tighter-binding operand, then fold
    // in any same-level operators left-to-right (each maps directly to its JS
    // spelling, parenthesized). Past the last level it drops to parseUnary. The
    // `levels` table above lists operators loosest-binding first.
    fn parseBinary(self: *Transpiler, level: usize) error{OutOfMemory}![]const u8 {
        if (level >= levels.len) {
            return self.parseUnary();
        }
        var left: []const u8 = try self.parseBinary(level + 1);
        var lw: u16 = self.last_w;
        while (self.opAtLevel(level)) |op| {
            self.p += 1;
            const right: []const u8 = try self.parseBinary(level + 1);
            const rw: u16 = self.last_w;
            const is_cmp = eql(u8, op, "==") or eql(u8, op, "!=") or eql(u8, op, "<") or
                eql(u8, op, ">") or eql(u8, op, "<=") or eql(u8, op, ">=") or
                eql(u8, op, "&&") or eql(u8, op, "||");
            // BigInt<->Number mixing throws on arithmetic/bitwise/shift (NOT on
            // comparisons, which JS coerces). The C backend casts mixed-WIDTH operands
            // to a common width, but NOT shift amounts (`u64 << UINT8_C(n)`) or the odd
            // un-cast literal — so when exactly one side is a 64/128-bit BigInt, lift the
            // Number side with BigInt(...). asUintN/asIntN at the enclosing assignment
            // re-narrows, so an over-wide intermediate is fine.
            var l: []const u8 = left;
            var r: []const u8 = right;
            if (!is_cmp) {
                const bigL: bool = lw >= 64;
                const bigR: bool = rw >= 64;
                if (bigL and !bigR) {
                    r = try allocPrint(self.gpa, "BigInt({s})", .{right});
                } else if (bigR and !bigL) {
                    l = try allocPrint(self.gpa, "BigInt({s})", .{left});
                }
            }
            // JS `>>` is signed-32; `>>>` is unsigned. C-backend output mostly
            // uses these on already-masked operands, so plain mapping is fine here.
            left = try allocPrint(self.gpa, "({s} {s} {s})", .{ l, op, r });
            // Result width: a comparison/logical op yields a JS boolean (Number); any
            // other op keeps the wider operand's width (64/128 => BigInt).
            lw = if (is_cmp) 0 else @max(lw, rw);
            self.last_w = lw;
        }
        self.last_w = lw;
        return left;
    }

    // Prefix level: -, +, !, ~, and the interesting one — `*ptr` loads, which read
    // through the correct heap view for the pointee (`*structPtr` is identity,
    // since a struct value just IS its heap offset). Non-prefix tokens fall through
    // to parsePostfix.
    fn parseUnary(self: *Transpiler) error{OutOfMemory}![]const u8 {
        const t: Token = self.current();
        if (t.kind == .punct) {
            // pre-increment/decrement `++x` / `--x`. The C backend emits these in
            // compact for-loop steps (e.g. an element-wise @memset fill loop). JS
            // `x += 1` evaluates to the NEW value (prefix semantics) and works on
            // both a local var and a heap-view slot (`__HEAP32[a] += 1`). Without
            // this the `++`/`--` token hit the unknown-punct marker and the loop
            // step (and the body after it) were silently mis-parsed.
            if (eql(u8, t.text, "++") or eql(u8, t.text, "--")) {
                const dec: bool = eql(u8, t.text, "--");
                self.p += 1;
                const e: []const u8 = try self.parseUnary();
                return allocPrint(self.gpa, "({s} {s} 1)", .{ e, if (dec) "-=" else "+=" });
            }
            if (eql(u8, t.text, "-")) {
                self.p += 1;
                const e: []const u8 = try self.parseUnary();
                return allocPrint(self.gpa, "(-{s})", .{e});
            }
            if (eql(u8, t.text, "+")) {
                self.p += 1;
                return self.parseUnary();
            }
            if (eql(u8, t.text, "!")) {
                self.p += 1;
                const e: []const u8 = try self.parseUnary();
                return allocPrint(self.gpa, "(!{s})", .{e});
            }
            if (eql(u8, t.text, "~")) {
                self.p += 1;
                const e: []const u8 = try self.parseUnary();
                return allocPrint(self.gpa, "(~{s})", .{e});
            }
            // (*P) load through the pointee view, when P is a known pointer var
            if (eql(u8, t.text, "*")) {
                const nx: Token = self.lookahead(1);
                // `*(&X)` == `X`: a deref of an address-of cancels. The C backend
                // emits this for constant-indexed aggregate field reads, e.g.
                // `*(&((T*)&base + k)->field)`. Resolve the inner lvalue with the
                // tag-tracking address walker FIRST so a nested `&field->member`
                // chain (`*(&(&S->inner)->a)`) and a global cast-pointer + member
                // fold the trailing `->field` into a heap *load*. Only if that
                // can't model the shape do we fall back to the postfix parse —
                // which, for a nested member, leaks the intermediate address as a
                // JS property access (`(addr).a` -> undefined -> 0), the silent
                // read miscompile this ordering fixes. (A bare `*(&ident)` is
                // handled by the ident branch below.)
                if (nx.kind == .punct and eql(u8, nx.text, "(") and
                    self.lookahead(2).kind == .punct and eql(u8, self.lookahead(2).text, "&"))
                {
                    if (try self.tryDerefAddrOf()) |loaded| {
                        return loaded;
                    }
                    const save: usize = self.p;
                    self.p += 3; // '*' '(' '&'
                    const inner: []const u8 = try self.parsePostfix();
                    if (self.atText(")")) {
                        self.p += 1; // ')'
                        return inner;
                    }
                    self.p = save; // not this shape; fall through
                }
                if (nx.kind == .ident) {
                    // *pp where pp is a pointer-to-pointer struct pointer holding
                    // a HEAP address (a `&ptr->field` / `&var.field` slot, or a pp
                    // param): load the stored pointer (a 4-byte offset). The
                    // address-of-local round-trip (`pp = &localStructPtr`) is NOT
                    // in pp_load, so it stays identity via the struct_ptrs branch
                    // below. Must be checked before that branch.
                    if (self.pp_load.contains(nx.text)) {
                        self.p += 2; // '*' and the ident
                        return self.u32LoadExpr(nx.text);
                    }
                    // *structPtr : a struct value IS its heap offset, so the
                    // dereference is identity (the offset itself). Must be checked
                    // before the generic pointer cases below.
                    if (self.struct_ptrs.contains(nx.text)) {
                        self.p += 2; // '*' and the ident
                        return self.gpa.dupe(u8, nx.text);
                    }
                    if (self.vars.get(nx.text)) |vi| {
                        if (vi.ty.kind == .ptr) {
                            if (vi.ty.elem) |e| {
                                self.p += 2; // '*' and the ident
                                return self.heapLoad(e, nx.text);
                            } else {
                                // pointer-to-pointer (T**): the loaded value is a
                                // pointer, i.e. a 4-byte offset. Load it as u32.
                                self.p += 2; // '*' and the ident
                                return self.u32LoadExpr(nx.text);
                            }
                        }
                    }
                }
                // general: *( (T *) <addr> )  — infer the view from the cast type.
                if (eql(u8, nx.text, "(")) {
                    if (try self.tryDerefCast()) |loaded| {
                        return loaded;
                    }
                    if (try self.tryDerefAddrOf()) |loaded| {
                        return loaded;
                    } // *(&lvalue)
                }
                // *ident where ident isn't a tracked pointer: this is the Zig
                // C-backend's address-of-local round-trip (`t1 = &t0; *t1`), which
                // our address-of already collapsed to identity. Mirror it: the
                // deref is identity too. (Emitting a marker here would be noise.)
                if (nx.kind == .ident) {
                    self.p += 1; // '*'
                    const inner: []const u8 = try self.parseUnary();
                    return inner;
                }
                // Any other `*expr`: pass the operand through, with a visible marker.
                // For an aggregate (struct/array) the value IS its address, so identity
                // is the correct lowering; for a scalar pointer it would not be, so the
                // marker keeps the uncertain case visible in the output.
                self.p += 1;
                return allocPrint(
                    self.gpa,
                    "(/*?deref: operand is not a tracked pointer or &lvalue; emitted as identity*/ {s})",
                    .{try self.parseUnary()},
                );
            }
            // address-of
            if (eql(u8, t.text, "&")) {
                self.p += 1; // &
                // &<function> used as a VALUE -> its 1-based __FTABLE index. An
                // indirect call later does __FTABLE[idx](args). A direct call
                // `fn(args)` never reaches here (it parses as a plain call), and the
                // working const-fn-ptr case is fully resolved by the C backend to
                // direct calls, so it never emits `&fn` — only mutable fn-ptr
                // stores do, which is exactly what this enables.
                if (self.current().kind == .ident) {
                    if (self.fn_index.get(self.current().text)) |idx| {
                        self.p += 1; // the function name
                        return allocPrint(self.gpa, "{d}", .{idx});
                    }
                }
                // &((arr_T*)&global)->array[idx]  ->  globalOffset + idx*elemsize
                // (the Zig C-backend's fixed-array element address form)
                if (try self.tryArrayWrapperAddr()) |addr| {
                    return addr;
                }
                const op: Token = self.current();
                // &P[i]  ->  P + i*sizeof(elem)
                if (op.kind == .ident and eql(u8, self.lookahead(1).text, "[")) {
                    const nm: []const u8 = op.text;
                    const vi: ?VarInfo = self.vars.get(nm);
                    self.p += 2; // ident '['
                    const idx: []const u8 = try self.parseExpr();
                    self.expect("]");
                    // pointee size: a struct pointer (`[*]S` / `*S`) strides by
                    // the WHOLE struct size — which is recorded as ty.struct_tag,
                    // NOT ty.elem (struct-pointer locals are registered with a tag
                    // but no elem), so consulting only ty.elem here struck a stride
                    // of 1 and silently miscompiled `&p[i]` (and thus `p[i].field`
                    // read/store) for `[*]Struct`. A scalar pointee uses elemSize.
                    const size: usize = blk: {
                        if (vi) |v| {
                            if (v.ty.kind == .ptr) {
                                if (v.ty.struct_tag) |st| {
                                    if (self.structs.get(st)) |sl| {
                                        break :blk sl.size;
                                    }
                                }
                                if (v.ty.elem) |e| {
                                    break :blk elemSize(e);
                                }
                            }
                        }
                        break :blk 1;
                    };
                    return allocPrint(self.gpa, "(({s}) + ({s}) * {d})", .{ nm, idx, size });
                }
                // &global (static data) -> its heap offset
                if (op.kind == .ident) {
                    // &structVar.field[.field...][i] -> base address + summed
                    // field offsets (+ [i]*elem). Walks nested aggregates so a
                    // tagged union's `&v.payload.member` resolves. The base is a
                    // local/global's slot offset, or — for a struct value-param,
                    // which holds its heap offset at runtime — the param value.
                    if (self.struct_vars.get(op.text)) |tag0| {
                        const base0: ?[]const u8 = if (self.globals.get(op.text)) |off0|
                            try self.scratchBase(op.text, off0)
                        else if (self.struct_ptrs.contains(op.text))
                            try allocPrint(self.gpa, "({s})", .{op.text})
                        else
                            null;
                        if (base0) |b0| {
                            if (eql(u8, self.lookahead(1).text, ".")) {
                                var cur_tag: []const u8 = tag0;
                                var addr: []const u8 = b0;
                                self.p += 1; // consume name; now at first '.'
                                while (self.atText(".")) {
                                    const fname: []const u8 = self.lookahead(1).text;
                                    const f: Field = self.fieldOf(cur_tag, fname) orelse break;
                                    const deeper: bool = eql(u8, self.lookahead(2).text, ".");
                                    if (f.struct_tag != null and deeper) {
                                        addr = try allocPrint(
                                            self.gpa,
                                            "(({s}) + {d})",
                                            .{ addr, f.offset },
                                        );
                                        cur_tag = f.struct_tag.?;
                                        self.p += 2; // '.' field
                                        continue;
                                    }
                                    self.p += 2; // '.' field (final)
                                    const base: []u8 = try allocPrint(
                                        self.gpa,
                                        "(({s}) + {d})",
                                        .{ addr, f.offset },
                                    );
                                    return self.arraySubscriptAddr(base, cur_tag, fname);
                                }
                            }
                        }
                    }
                    // &ptr->field(.member)*([i])? where ptr is a struct-pointer
                    // temp holding an address. Walk the WHOLE chain (mirroring the
                    // &v.field.member case above): a tagged union's payload member
                    // accessed through a pointer (`&ptr->payload.rect`) needs the
                    // nested walk, otherwise only `->payload` was consumed and the
                    // trailing `.rect` leaked onto the (cast) result as a JS property
                    // access — `(addr).rect` -> undefined -> a read at address ~0,
                    // silently zeroing the captured payload.
                    if (self.struct_ptrs.get(op.text)) |tag| {
                        if (eql(u8, self.lookahead(1).text, "->") and
                            self.fieldOf(tag, self.lookahead(2).text) != null)
                        {
                            var cur_tag: []const u8 = tag;
                            var addr: []const u8 = try allocPrint(self.gpa, "({s})", .{op.text});
                            self.p += 1; // consume ptr name; now at '->'
                            while (self.atText("->") or self.atText(".")) {
                                const fname: []const u8 = self.lookahead(1).text;
                                const f: Field = self.fieldOf(cur_tag, fname) orelse break;
                                const deeper: bool = eql(u8, self.lookahead(2).text, ".") or
                                    eql(u8, self.lookahead(2).text, "->");
                                if (f.struct_tag != null and deeper) {
                                    addr = try allocPrint(self.gpa, "(({s}) + {d})", .{ addr, f.offset });
                                    cur_tag = f.struct_tag.?;
                                    self.p += 2; // op + field
                                    continue;
                                }
                                self.p += 2; // op + field (final)
                                const base: []u8 = try allocPrint(self.gpa, "(({s}) + {d})", .{ addr, f.offset });
                                return self.arraySubscriptAddr(base, cur_tag, fname);
                            }
                        }
                    }
                    // &arrayName.array[idx] -> offset + idx*elemsize
                    if (self.array_elems.get(op.text)) |elem| {
                        if (self.globals.get(op.text)) |off| {
                            if (eql(u8, self.lookahead(1).text, ".") and
                                eql(u8, self.lookahead(2).text, "array") and
                                eql(u8, self.lookahead(3).text, "["))
                            {
                                self.p += 4; // name . array [
                                const idx: []const u8 = try self.parseExpr();
                                self.expect("]");
                                return allocPrint(
                                    self.gpa,
                                    "(({s}) + ({s}) * {d})",
                                    .{ try self.scratchBase(op.text, off), idx, elemSize(elem) },
                                );
                            }
                        }
                    }
                    if (self.scalar_slots.get(op.text)) |off| {
                        self.p += 1;
                        return self.scratchBase(op.text, off);
                    }
                    if (self.globals.get(op.text)) |off| {
                        self.p += 1;
                        return self.scratchBase(op.text, off);
                    }
                    // &fn  (operand is not a known var) -> the JS function value (its name)
                    if (self.vars.get(op.text) == null and eql(u8, self.lookahead(1).text, ")")) {
                        self.p += 1;
                        return self.gpa.dupe(u8, self.applyDefine(op.text));
                    }
                }
                // &<primary that yields a struct>(.|->)field[idx]  -> element
                // address. Covers `&((arr_N_T*)<ptr>)->array[i]` (an in-place
                // slice over a local array) and similar: the primary records a
                // struct tag, the field offset is added, and a trailing `[i]`
                // scales by the element size. Without this the field access would
                // produce a heap *load*, and the surrounding `&`/deref would then
                // read from that value-as-address (garbage).
                {
                    const save: usize = self.p;
                    const base: []const u8 = try self.parsePrimary();
                    const ptag: ?[]const u8 = self.pending_struct_tag;
                    const pelem: ?Elem = self.pending_ptr_elem;
                    self.pending_struct_tag = null;
                    self.pending_ptr_elem = null;
                    // &((ELEM*)X)[i] : the ADDRESS of the i-th element of a cast
                    // pointer (X + i*size) — NOT a heap load. The Zig C backend emits
                    // this for `p[i] = v` and `p[i].field` through a `[*]T`/`[*:0]T`
                    // pointer that it folds to a known base. Without it the primary's
                    // value path turns `((ELEM*)X)[i]` into a heap *load* and the
                    // surrounding `&` then reads from that value-as-address (the store
                    // lands at offset 0; a struct field read is garbage). Stride is the
                    // whole struct size for a struct pointee, else the scalar elem size.
                    if ((ptag != null or pelem != null) and self.atText("[")) {
                        self.p += 1; // [
                        const idx: []const u8 = try self.parseExpr();
                        self.expect("]");
                        const stride: usize = if (ptag) |tg|
                            (if (self.structs.get(tg)) |sl| sl.size else 1)
                        else
                            elemSize(pelem.?);
                        return try allocPrint(self.gpa, "(({s}) + ({s}) * {d})", .{ base, idx, stride });
                    }
                    if (ptag) |tg| {
                        if ((self.atText(".") or self.atText("->")) and self.lookahead(1).kind == .ident) {
                            const fld: []const u8 = self.lookahead(1).text;
                            if (self.fieldOf(tg, fld)) |f| {
                                self.p += 2; // '.'/'->' field
                                const baseaddr: []u8 = try allocPrint(
                                    self.gpa,
                                    "(({s}) + {d})",
                                    .{ base, f.offset },
                                );
                                return self.arraySubscriptAddr(baseaddr, tg, fld);
                            }
                        }
                    }
                    self.p = save; // not this shape
                    // LAST RESORT before the value path can leak a property
                    // access: the general tag-tracking lvalue walker. The C
                    // backend nests member addresses as
                    // `&(&(&((T*)&g))->a)->b)->array[i]` — e.g. a fixed array
                    // inside a struct inside a GLOBAL struct, exactly the shape a
                    // single consolidated `var g` produces. The specialized
                    // handlers above own their proven shapes (incl. relocated
                    // globals via scratchBase); anything that reaches here would
                    // otherwise emit `(addr).field` -> undefined. Found on-device
                    // when the bridge's event ring moved into the one global
                    // (t1178); guarded by tests/cases/global_struct_array_member.
                    if (try self.parseLValueAddrMode(.prefix)) |lv| {
                        return try allocPrint(self.gpa, "({s})", .{lv.addr});
                    }
                    self.p = save;
                }
                // &P (no-op pointer pattern) / &P->field (struct layout: next step):
                // fall back to value passthrough so the *(&x) no-op chain resolves.
                // A bare `&<local>` (no trailing member/index access) reaching here
                // is the Zig C-backend's address-of-local round-trip: the local is
                // not heap-backed, so `&` collapses to the value and a later `*pp`
                // must mirror that (identity, not a heap load). Flag it so
                // notePpProvenance keeps such a pp temp out of pp_load.
                if (op.kind == .ident and
                    !eql(u8, self.lookahead(1).text, "->") and
                    !eql(u8, self.lookahead(1).text, ".") and
                    !eql(u8, self.lookahead(1).text, "["))
                {
                    self.addr_local_collapse = true;
                }
                return allocPrint(self.gpa, "({s})", .{try self.parseUnary()});
            }
        }
        return self.parsePostfix();
    }

    // Postfix level: calls `f(...)`, member chains `a.b->c`, and indexing `[i]`,
    // applied left-to-right on top of parsePrimary. This is where struct/pointer
    // member access becomes heap-offset arithmetic: it carries a running
    // chain_tag/chain_addr so `a.b.c` (and struct value-param field reads) resolve
    // to the right address and element view.
    fn parsePostfix(self: *Transpiler) error{OutOfMemory}![]const u8 {
        // Remember the leading identifier (if any) so `name.array[i]` on an
        // array global/local can be recognized below.
        const base_name: []const u8 = if (self.current().kind == .ident) self.current().text else "";
        var e: []const u8 = try self.parsePrimary();
        // A struct-yielding primary (e.g. a compound literal `(struct T){...}`)
        // records its tag here; capture it so a following `.array[i]` resolves,
        // then clear it so it doesn't leak to the next postfix.
        const prim_tag: ?[]const u8 = self.pending_struct_tag;
        self.pending_struct_tag = null;
        // A pointer-cast primary (`(ELEM*)x`) records its scalar pointee here so a
        // following subscript `[i]` becomes a heap load (see the `[` postfix below).
        var prim_elem: ?Elem = self.pending_ptr_elem;
        self.pending_ptr_elem = null;
        const postfix_start: usize = self.p; // to detect a transparent (paren-wrap) postfix
        // Track the current struct context as `.`/`->` chains are walked, so
        // `a.b.c` (and struct value-param field access `a0.tag`) resolve. The
        // base is a struct var (heap offset), a struct pointer/value-param
        // (runtime value), or a compound-literal result (its offset in `e`).
        var chain_tag: ?[]const u8 = null;
        var chain_addr: []const u8 = "";
        if (self.struct_vars.get(base_name)) |tg| {
            if (self.globals.get(base_name)) |off| {
                chain_tag = tg;
                chain_addr = try allocPrint(self.gpa, "{d}", .{off});
            }
        }
        if (chain_tag == null) {
            if (self.struct_ptrs.get(base_name)) |tg| {
                chain_tag = tg;
                // An address-taken struct pointer lives in a heap slot: its VALUE
                // (the pointee address) is LOADED from the slot, not read as a JS
                // variable. (scalar_slots membership is only set for the address-
                // taken case, so the common non-escaping pointer is unaffected.)
                if (self.scalar_slots.get(base_name)) |off| {
                    chain_addr = try self.u32LoadExpr(try self.scratchBase(base_name, off));
                } else {
                    chain_addr = try allocPrint(self.gpa, "({s})", .{base_name});
                }
            } else if (prim_tag) |tg| {
                chain_tag = tg;
                chain_addr = e;
            }
        }
        while (true) {
            if (self.atText("(")) {
                // call
                self.p += 1;
                var args: ArrayList(u8) = .empty;
                var first: bool = true;
                while (self.current().kind != .eof and !self.atText(")")) {
                    if (!first) {
                        try args.appendSlice(self.gpa, ", ");
                    }
                    first = false;
                    const a: []const u8 = try self.parseAssign();
                    try args.appendSlice(self.gpa, a);
                    if (!self.consume(",")) {
                        break;
                    }
                }
                self.expect(")");
                // Indirect call: when the callee is a local declared as a function
                // pointer (`RET (*e)(...)`), it holds a __FTABLE index, so dispatch
                // through the table. Direct calls (a function name) and runtime
                // helpers (memcpy, Math.imul, ...) are NOT in fn_ptr_vars and stay
                // as plain `e(args)`.
                if (self.fn_ptr_vars.contains(e)) {
                    e = try allocPrint(self.gpa, "__FTABLE[({s})]({s})", .{ e, args.items });
                } else {
                    e = try allocPrint(self.gpa, "{s}({s})", .{ e, args.items });
                }
            } else if (self.atText("[")) {
                // array index -> milestone 3 (linear memory); pass through textually
                self.p += 1;
                const idx: []const u8 = try self.parseExpr();
                self.expect("]");
                // A pointer-cast primary (`(ELEM*)base`) makes `[idx]` a heap load
                // `*(base + idx)`, not a JS subscript on a heap offset. Consume the
                // recorded pointee on the FIRST subscript only (the result is then a
                // scalar value, so a further `[i]` would be a genuine error).
                if (prim_elem) |pe| {
                    prim_elem = null;
                    e = try self.heapLoad(
                        pe,
                        try allocPrint(self.gpa, "(({s}) + ({s}) * {d})", .{ e, idx, elemSize(pe) }),
                    );
                } else {
                    e = try allocPrint(self.gpa, "{s}[/*idx*/ {s}]", .{ e, idx });
                }
            } else if (self.atText(".") or self.atText("->")) {
                self.p += 1;
                const field: []const u8 = self.current().text;
                self.p += 1;
                // <arrayName>.array[idx] -> heap element access at its offset.
                if (eql(u8, field, "array") and self.atText("[")) {
                    if (self.array_elems.get(base_name)) |elem| {
                        if (self.globals.get(base_name)) |off| {
                            self.p += 1; // [
                            const idx: []const u8 = try self.parseExpr();
                            self.expect("]");
                            e = try self.heapLoad(
                                elem,
                                try allocPrint(self.gpa, "(({s}) + ({s}) * {d})", .{
                                    try self.scratchBase(base_name, off),
                                    idx,
                                    elemSize(elem),
                                }),
                            );
                            continue;
                        }
                    }
                    // <structVar>.array[idx] where the struct's field is itself an
                    // array (SIMD vectors lower to `struct { f32 array[N]; }`). The
                    // base address is the global's offset if known, otherwise the
                    // variable's own runtime value (struct params/by-value locals
                    // hold their heap offset). Works as both rvalue and lvalue: the
                    // assignment path writes through the returned typed-array slot.
                    if (self.struct_vars.get(base_name)) |tag| {
                        if (self.fieldOf(tag, field)) |f| {
                            const base: []u8 = if (self.globals.get(base_name)) |off|
                                try allocPrint(
                                    self.gpa,
                                    "({s} + {d})",
                                    .{ try self.scratchBase(base_name, off), f.offset },
                                )
                            else
                                try allocPrint(self.gpa, "(({s}) + {d})", .{ base_name, f.offset });
                            self.p += 1; // [
                            const idx: []const u8 = try self.parseExpr();
                            self.expect("]");
                            // array of STRUCTS: stride by the element struct size and
                            // yield the element's ADDRESS (recording its tag).
                            if (f.struct_tag) |etag| {
                                if (self.structs.get(etag)) |el| {
                                    self.pending_struct_tag = etag;
                                    e = try allocPrint(self.gpa, "(({s}) + ({s}) * {d})", .{ base, idx, el.size });
                                    continue;
                                }
                            }
                            const elem = Elem{
                                .bits = f.bits,
                                .signed = f.signed,
                                .float = f.float,
                            };
                            e = try self.heapLoad(
                                elem,
                                try allocPrint(self.gpa, "(({s}) + ({s}) * {d})", .{ base, idx, elemSize(elem) }),
                            );
                            continue;
                        }
                    }
                    // <compound-literal>.array[idx]: the primary `e` evaluated to a
                    // struct offset (its tag was recorded in prim_tag). Index into it
                    // the same way; `e`'s side effects (the field stores) run once as
                    // the base address is computed.
                    if (prim_tag) |tag| {
                        if (self.fieldOf(tag, field)) |f| {
                            self.p += 1; // [
                            const idx: []const u8 = try self.parseExpr();
                            self.expect("]");
                            // array of STRUCTS: stride by the element struct's whole
                            // size and yield the element's ADDRESS (a struct pointer),
                            // recording its tag — NOT a scalar load with the int stride.
                            if (f.struct_tag) |etag| {
                                if (self.structs.get(etag)) |el| {
                                    self.pending_struct_tag = etag;
                                    e = try allocPrint(
                                        self.gpa,
                                        "((({s}) + {d}) + ({s}) * {d})",
                                        .{ e, f.offset, idx, el.size },
                                    );
                                    continue;
                                }
                            }
                            const elem = Elem{
                                .bits = f.bits,
                                .signed = f.signed,
                                .float = f.float,
                            };
                            e = try self.heapLoad(
                                elem,
                                try allocPrint(self.gpa, "((({s}) + {d}) + ({s}) * {d})", .{
                                    e,
                                    f.offset,
                                    idx,
                                    elemSize(elem),
                                }),
                            );
                            continue;
                        }
                    }
                    // <ptr>->array[idx] where the pointer's pointee is itself an
                    // array wrapper — e.g. a 2D array `[N][M]T`: the C backend reads
                    // an inner row via `(&outer.array[i])->array[j]`. chain_tag/
                    // chain_addr already resolve a struct pointer (struct_ptrs) to
                    // its base address; stride into its `array` field instead of
                    // doing an (undefined) object property access.
                    if (chain_tag) |tag| {
                        if (self.fieldOf(tag, field)) |f| {
                            self.p += 1; // [
                            const idx: []const u8 = try self.parseExpr();
                            self.expect("]");
                            if (f.struct_tag) |etag| {
                                if (self.structs.get(etag)) |el| {
                                    self.pending_struct_tag = etag;
                                    e = try allocPrint(
                                        self.gpa,
                                        "((({s}) + {d}) + ({s}) * {d})",
                                        .{ chain_addr, f.offset, idx, el.size },
                                    );
                                    continue;
                                }
                            }
                            const elem = Elem{ .bits = f.bits, .signed = f.signed, .float = f.float };
                            e = try self.heapLoad(
                                elem,
                                try allocPrint(self.gpa, "((({s}) + {d}) + ({s}) * {d})", .{
                                    chain_addr,
                                    f.offset,
                                    idx,
                                    elemSize(elem),
                                }),
                            );
                            continue;
                        }
                    }
                }
                // Field access via the tracked struct chain (handles struct
                // value-params accessed with `.`, struct pointers with `->`, and
                // nested `a.b.c` — including a tagged union's `s.payload.member`).
                if (chain_tag) |tg| {
                    if (self.fieldOf(tg, field)) |f| {
                        const addr: []u8 = try allocPrint(
                            self.gpa,
                            "(({s}) + {d})",
                            .{ chain_addr, f.offset },
                        );
                        // `<arrayWrapper>.array` with no following subscript: the
                        // array decays to its base ADDRESS (C array-to-pointer),
                        // it is not a scalar value. This is what @memcpy / @bitCast
                        // / array-by-value operands need; without it the field is
                        // wrongly scalar-loaded (its first element used as the
                        // pointer), silently miscompiling the copy. `.array[i]` is
                        // handled earlier, so reaching here with no `[` is decay.
                        if (eql(u8, field, "array") and !self.atText("[") and parseArrTag(tg) != null) {
                            e = addr;
                            chain_tag = null;
                            continue;
                        }
                        if (f.struct_tag) |st| {
                            // intermediate aggregate: advance the chain; a struct
                            // value IS its address.
                            chain_tag = st;
                            chain_addr = addr;
                            e = addr;
                        } else if (f.ptr_elem != null and self.atText("[")) {
                            // pointer field immediately subscripted (`slice.ptr[i]`):
                            // load the pointer value, then index into linear memory
                            // scaled by the pointee size.
                            const elem: Elem = f.ptr_elem.?;
                            const ptrval: []const u8 = try self.fieldLoad(addr, f);
                            self.p += 1; // [
                            const idx: []const u8 = try self.parseExpr();
                            self.expect("]");
                            if (elem.struct_tag) |etag| {
                                // pointee is a struct (`[]const Pt`): the element is
                                // a struct VALUE — yield its address and advance the
                                // chain so a following `.field` (or a struct copy)
                                // resolves against it.
                                if (self.structs.get(etag)) |el| {
                                    e = try allocPrint(
                                        self.gpa,
                                        "(({s}) + ({s}) * {d})",
                                        .{ ptrval, idx, el.size },
                                    );
                                    chain_tag = etag;
                                    chain_addr = e;
                                    continue;
                                }
                            }
                            // scalar pointee: a heap load, not a JS array index.
                            e = try self.heapLoad(
                                elem,
                                try allocPrint(self.gpa, "(({s}) + ({s}) * {d})", .{ ptrval, idx, elemSize(elem) }),
                            );
                            chain_tag = null;
                        } else {
                            e = try self.fieldLoad(addr, f);
                            chain_tag = null;
                        }
                        continue;
                    }
                }
                e = try allocPrint(self.gpa, "{s}.{s}", .{ e, field });
            } else {
                break;
            }
        }
        // postfix `x++` / `x--`. JS native postfix gives the correct old-value
        // semantics; the operand is an lvalue (a local var or a heap-view slot),
        // both of which JS `++`/`--` accept. The backend favours prefix in
        // for-steps, but may emit postfix elsewhere; without this it would hit the
        // unknown-punct marker and mis-parse the rest of the statement.
        if (self.atText("++") or self.atText("--")) {
            const opp: []const u8 = self.current().text;
            self.p += 1;
            e = try allocPrint(self.gpa, "(({s}){s})", .{ e, opp });
        }
        // If no postfix operator was applied, this call was transparent (e.g. a
        // parenthesized struct-yielding cast); propagate the primary's struct tag
        // so an enclosing `(...)->array[i]` / `(...).field` can still resolve it.
        if (self.p == postfix_start and prim_tag != null) {
            self.pending_struct_tag = prim_tag;
        }
        // Likewise propagate a pointer-cast pointee through a transparent paren wrap
        // (`((ELEM*)x)`) so an enclosing `[i]` still lowers to a heap load.
        if (self.p == postfix_start and prim_elem != null) {
            self.pending_ptr_elem = prim_elem;
        }
        return e;
    }

    // Numeric literal -> JS: strip C integer suffixes (u/U/l/L). Hex and float text
    // is already valid JavaScript as-is.
    fn emitNumber(self: *Transpiler, text: []const u8) ![]const u8 {
        // strip integer suffixes u/U/l/L
        var end: usize = text.len;
        while (end > 0) {
            const c: u8 = text[end - 1];
            if (c == 'u' or c == 'U' or c == 'l' or c == 'L') {
                end -= 1;
            } else {
                break;
            }
        }
        return self.gpa.dupe(u8, text[0..end]);
    }

    /// Parse the element type of a leading pointer cast `( T * )` at self.p and
    /// return its Elem (bits/signed/float). Leaves self.p just past the cast's
    /// close paren. Returns null (without consuming) if no such cast is present.
    fn parseCastElem(self: *Transpiler) ?Elem {
        if (!self.atText("(")) {
            return null;
        }
        const save: usize = self.p;
        self.p += 1; // (
        const spec_start: usize = self.p;
        var star: bool = false;
        var star_idx: ?usize = null;
        while (self.current().kind != .eof) {
            const tx: []const u8 = self.current().text;
            if (eql(u8, tx, "*")) {
                if (star_idx == null) {
                    star_idx = self.p;
                } // first '*' ends the base type
                star = true;
                self.p += 1;
                continue;
            }
            if (eql(u8, tx, ")")) {
                break;
            }
            if (self.current().kind == .ident) {
                // accept type tokens (base types, qualifiers, struct/union/enum tags)
                self.p += 1;
                continue;
            }
            break;
        }
        if (!star or !self.atText(")")) {
            self.p = save;
            return null;
        }
        // The element type is the base BEFORE the pointer star; including the
        // '*' would make tyFromSpecifiers report a pointer and lose float-ness.
        const specs: []const Token = self.toks[spec_start .. star_idx orelse self.p];
        self.p += 1; // )
        // A struct-typed cast (`(struct Tag *)…`) — record the tag so the
        // deref load/store copies the whole struct instead of a scalar.
        if (structTagOf(self, specs)) |tag| {
            if (self.structs.contains(tag)) {
                return .{ .bits = 32, .signed = false, .float = false, .struct_tag = tag };
            }
        }
        // A type-alias base (an enum tag typedef `enum__...` = uint8_t, etc.):
        // resolve to its real width so a deref/store through this pointer touches
        // the right number of bytes (a 32-bit store through an 8-bit pointer would
        // clobber the adjacent fields).
        for (specs) |sp| {
            if (self.type_aliases.get(sp.text)) |ty| {
                return .{ .bits = ty.bits, .signed = ty.signed, .float = ty.kind == .float, .struct_tag = null };
            }
        }
        const ty: CType = tyFromSpecifiers(specs);
        return .{
            .bits = ty.bits,
            .signed = ty.signed,
            .float = ty.kind == .float,
            .struct_tag = null,
        };
    }

    /// Load shape `*( ... (T*) <addr> ... )` where self.p points at the leading '*'.
    /// Tolerates arbitrary nested parens around the cast. Returns the heap-view
    /// load, or null (without consuming) if shape mismatches.
    fn tryDerefCast(self: *Transpiler) error{OutOfMemory}!?[]const u8 {
        const save: usize = self.p;
        self.p += 1; // '*'
        var opens: usize = 0;
        while (self.atText("(") and !self.isCastAhead()) {
            opens += 1;
            self.p += 1;
        }
        const cast_start: usize = self.p;
        const e: Elem = self.parseCastElem() orelse {
            self.p = save;
            return null;
        };
        const cast_end: usize = self.p;
        var addr: []const u8 = try self.parseUnary(); // &global / address expression
        // optional pointer arithmetic: (T*)<base> + <index>  -> base + index*sizeof(T).
        // For a struct pointee the stride is the whole struct size, not the
        // scalar elemSize of the (default 32-bit) element record — otherwise a
        // `*((Pt*)&arr + i)` whole-struct copy strides by 4 and reads mid-struct.
        if (self.atText("+")) {
            self.p += 1;
            const idx: []const u8 = try self.parseBinary(0);
            const stride: usize = blk: {
                if (e.struct_tag) |st| {
                    if (self.structs.get(st)) |sl| {
                        break :blk sl.size;
                    }
                }
                break :blk elemSize(e);
            };
            addr = try allocPrint(self.gpa, "({s}) + ({s}) * {d}", .{ addr, idx, stride });
        }
        while (opens > 0) : (opens -= 1) {
            self.expect(")");
        }
        // A whole-struct load (*(struct Tag*)addr) evaluates to the struct's
        // address — struct values ARE heap offsets in this model.
        if (e.struct_tag != null) {
            return try allocPrint(self.gpa, "({s})", .{addr});
        }
        // PRIMITIVE-element array wrappers (`arr_N_u64`, ...) are diverted by
        // structTagOf (parseCastElem yields a scalar), so without this branch a
        // whole-array value load `*(arr_N_T*)&g` would lower to a 32-bit heapLoad —
        // reading arr[0]'s low word and using it as a (garbage) copy SOURCE address.
        // Like a struct, a whole-array value IS its heap offset: recover the wrapper
        // from the cast tokens and return the address.
        {
            var k: usize = cast_start;
            while (k < cast_end) : (k += 1) {
                const tk: []const u8 = self.toks[k].text;
                if (startsWith(u8, tk, "arr_") and parseArrTag(tk) != null and self.structs.contains(tk)) {
                    return try allocPrint(self.gpa, "({s})", .{addr});
                }
            }
        }
        return try self.heapLoad(e, addr);
    }

    /// True if the parens immediately ahead begin a pointer cast `( T * )`.
    fn isCastAhead(self: *Transpiler) bool {
        if (!self.atText("(")) {
            return false;
        }
        var i: usize = self.p + 1;
        var star: bool = false;
        while (i < self.toks.len) : (i += 1) {
            const tx: []const u8 = self.toks[i].text;
            if (eql(u8, tx, "*")) {
                star = true;
                continue;
            }
            if (eql(u8, tx, ")")) {
                return star;
            }
            if (eql(u8, tx, "(")) {
                return false;
            } // nested paren first => not a direct cast
            if (self.toks[i].kind == .ident) {
                continue;
            }
            return false;
        }
        return false;
    }

    /// Store shape `*( ... (T*) <addr> ... ) = rhs`. self.p points at the leading '('.
    /// Returns the heap-view store, or null (without consuming) if shape mismatches.
    fn tryDerefCastStore(self: *Transpiler) error{OutOfMemory}!?[]const u8 {
        const save: usize = self.p;
        if (!self.atText("(")) {
            return null;
        }
        self.p += 1; // outer (
        if (!self.atText("*")) {
            self.p = save;
            return null;
        }
        self.p += 1; // *
        var opens: usize = 0;
        while (self.atText("(") and !self.isCastAhead()) {
            opens += 1;
            self.p += 1;
        }
        const e: Elem = self.parseCastElem() orelse {
            self.p = save;
            return null;
        };
        var addr: []const u8 = try self.parseUnary();
        // optional pointer arithmetic: (T*)<base> + <index> (struct stride = size)
        if (self.atText("+")) {
            self.p += 1;
            const idx: []const u8 = try self.parseBinary(0);
            const stride: usize = blk: {
                if (e.struct_tag) |st| {
                    if (self.structs.get(st)) |sl| {
                        break :blk sl.size;
                    }
                }
                break :blk elemSize(e);
            };
            addr = try allocPrint(self.gpa, "({s}) + ({s}) * {d}", .{ addr, idx, stride });
        }
        while (opens > 0) : (opens -= 1) {
            if (!self.atText(")")) {
                self.p = save;
                return null;
            }
            self.p += 1;
        }
        if (!self.atText(")")) {
            self.p = save;
            return null;
        } // close outer (
        self.p += 1;
        if (!self.atText("=")) {
            self.p = save;
            return null;
        }
        self.p += 1; // =
        const rhs: []const u8 = try self.parseAssign();
        // Whole-struct store: copy the struct's bytes (rhs is its offset).
        if (e.struct_tag) |tag| {
            const sz: u32 = if (self.structs.get(tag)) |layout| layout.size else 4;
            return try allocPrint(self.gpa, "__copy({s}, {s}, {d})", .{ addr, rhs, sz });
        }
        const ety = CType{ .kind = if (e.float) .float else .int, .bits = e.bits, .signed = e.signed };
        return try allocPrint(self.gpa, "({s})", .{try self.heapStore(e, addr, try self.wrap(rhs, ety))});
    }

    // The address + element type of an lvalue. A struct lvalue's "value" is its
    // heap offset, so `tag != null` means addr already IS the struct.
    const LValue = struct {
        addr: []const u8,
        tag: ?[]const u8 = null,
        elem: Elem = .{ .bits = 32, .signed = false, .float = false },
    };

    /// Resolve a C lvalue expression to its heap address and element type,
    /// walking casts, address-of, member (`.`/`->`) and index (`[]`) chains.
    /// This is what makes `*(&X)` (the backend's field-store/-load shape) work
    /// for arbitrarily nested struct/optional/union fields. Returns null
    /// (without consuming) if the shape isn't a resolvable lvalue.
    fn parseLValueBase(self: *Transpiler) error{OutOfMemory}!?LValue {
        // &LVALUE : the address of an lvalue is the lvalue's address (a struct
        // value already is its offset), so tag/elem carry through unchanged.
        if (self.atText("&")) {
            self.p += 1;
            return try self.parseLValueAddr();
        }
        if (self.atText("(")) {
            // (T *) ADDR : a pointer cast — base address from ADDR, type from T.
            if (self.isCastAhead()) {
                const e: Elem = self.parseCastElem() orelse return null; // consumes "( T * )"
                const addr: []const u8 = try self.parseUnary(); // &global / pointer expression
                if (e.struct_tag) |st| {
                    return LValue{ .addr = addr, .tag = st };
                }
                return LValue{ .addr = addr, .tag = null, .elem = e };
            }
            // grouped lvalue
            self.p += 1; // (
            const inner: LValue = (try self.parseLValueAddr()) orelse return null;
            if (!self.atText(")")) {
                return null;
            }
            self.p += 1; // )
            return inner;
        }
        const t: Token = self.current();
        if (t.kind == .ident) {
            if (self.struct_vars.get(t.text)) |tag| {
                self.p += 1;
                if (self.globals.get(t.text)) |off| {
                    return LValue{ .addr = try allocPrint(self.gpa, "{d}", .{off}), .tag = tag };
                }
                // a struct value-param / by-value local holds its heap offset
                return LValue{ .addr = try allocPrint(self.gpa, "({s})", .{t.text}), .tag = tag };
            }
            if (self.struct_ptrs.get(t.text)) |tag| {
                self.p += 1;
                return LValue{ .addr = try allocPrint(self.gpa, "({s})", .{t.text}), .tag = tag };
            }
        }
        return null;
    }

    // Compute the ADDRESS of an lvalue (not its value). From a base
    // (parseLValueBase) it walks `.`/`->` fields and `[i]` indices, building a
    // heap-offset expression in `.addr` while tracking the current element type /
    // struct tag. The &-of and store paths use this so `&a.b[i]` and `a.b[i] = x`
    // know exactly where in __MEM they land. Returns null if it can't model it.
    fn parseLValueAddr(self: *Transpiler) error{OutOfMemory}!?LValue {
        return self.parseLValueAddrMode(.full);
    }

    const LValueWalkMode = enum { full, prefix };

    fn parseLValueAddrMode(
        self: *Transpiler,
        mode: LValueWalkMode,
    ) error{OutOfMemory}!?LValue {
        var cur: LValue = (try self.parseLValueBase()) orelse return null;
        while (true) {
            if (self.atText("->") or self.atText(".")) {
                const tag: []const u8 = cur.tag orelse return null; // can't member-access a scalar
                const fld: Token = self.lookahead(1);
                if (fld.kind != .ident) {
                    return null;
                }
                const f: Field = self.fieldOf(tag, fld.text) orelse return null;
                self.p += 2; // op + field
                cur.addr = try allocPrint(self.gpa, "(({s}) + {d})", .{ cur.addr, f.offset });
                if (f.struct_tag) |st| {
                    cur.tag = st;
                } else {
                    cur.tag = null;
                    cur.elem = fieldElem(f);
                }
            } else if (self.atText("[")) {
                self.p += 1;
                const idx: []const u8 = try self.parseExpr();
                if (!self.atText("]")) {
                    return null;
                }
                self.p += 1;
                // a struct-typed pointer (cur.tag) strides by the WHOLE struct
                // size, not the scalar elem size.
                const stride: usize = if (cur.tag) |tg|
                    (if (self.structs.get(tg)) |layout| layout.size else 1)
                else
                    elemSize(cur.elem);
                cur.addr = try allocPrint(
                    self.gpa,
                    "(({s}) + ({s}) * {d})",
                    .{ cur.addr, idx, stride },
                );
            } else if (mode == .full and (self.atText("+") or self.atText("-"))) {
                // pointer arithmetic on a cast/element pointer: `(T*)base + n`.
                // The C backend inlines exactly this for a global array-of-structs
                // element store (`G[i].field = v`, no temp). Without striding it
                // here the `*(&(...)->field)` LHS fails to resolve, tryDerefAddrOf-
                // Store bails, and the whole assignment is silently dropped (the
                // LHS lowers to an orphaned heap read and the RHS to a bare value).
                const minus: bool = self.atText("-");
                self.p += 1; // + / -
                const idx: []const u8 = try self.parseExpr();
                const stride: usize = if (cur.tag) |tg|
                    (if (self.structs.get(tg)) |layout| layout.size else 1)
                else
                    elemSize(cur.elem);
                cur.addr = try allocPrint(
                    self.gpa,
                    "(({s}) {s} ({s}) * {d})",
                    .{ cur.addr, if (minus) "-" else "+", idx, stride },
                );
            } else {
                break;
            }
        }
        return cur;
    }

    /// Read `*(&LVALUE)` — identity with LVALUE, loaded through the right heap
    /// view. self.p at the leading '*'. Returns null (restoring) on mismatch.
    fn tryDerefAddrOf(self: *Transpiler) error{OutOfMemory}!?[]const u8 {
        const save: usize = self.p;
        if (!self.atText("*")) {
            return null;
        }
        self.p += 1; // *
        if (!self.atText("(")) {
            self.p = save;
            return null;
        }
        self.p += 1; // (
        if (!self.atText("&")) {
            self.p = save;
            return null;
        }
        self.p += 1; // &
        const lv: LValue = (try self.parseLValueAddr()) orelse {
            self.p = save;
            return null;
        };
        if (!self.atText(")")) {
            self.p = save;
            return null;
        }
        self.p += 1; // )
        // struct value = offset
        if (lv.tag != null) {
            return try allocPrint(self.gpa, "({s})", .{lv.addr});
        }
        return try self.heapLoad(lv.elem, lv.addr);
    }

    /// Store `*(&LVALUE) = rhs` (with an optional outer paren). self.p at the
    /// leading '(' or '*'. Returns null (restoring) on mismatch.
    fn tryDerefAddrOfStore(self: *Transpiler) error{OutOfMemory}!?[]const u8 {
        const save: usize = self.p;
        var outer: bool = false;
        if (self.atText("(") and eql(u8, self.lookahead(1).text, "*")) {
            self.p += 1; // outer (
            outer = true;
        }
        if (!self.atText("*")) {
            self.p = save;
            return null;
        }
        self.p += 1; // *
        if (!self.atText("(")) {
            self.p = save;
            return null;
        }
        self.p += 1; // (
        if (!self.atText("&")) {
            self.p = save;
            return null;
        }
        self.p += 1; // &
        const lv: LValue = (try self.parseLValueAddr()) orelse {
            self.p = save;
            return null;
        };
        if (!self.atText(")")) {
            self.p = save;
            return null;
        }
        self.p += 1; // close inner (
        if (outer) {
            if (!self.atText(")")) {
                self.p = save;
                return null;
            }
            self.p += 1; // close outer (
        }
        if (!self.atText("=")) {
            self.p = save;
            return null;
        }
        self.p += 1; // =
        const rhs: []const u8 = try self.parseAssign();
        if (lv.tag) |tag| { // whole-struct store: copy bytes
            const sz: u32 = if (self.structs.get(tag)) |layout| layout.size else 4;
            return try allocPrint(self.gpa, "__copy({s}, {s}, {d})", .{ lv.addr, rhs, sz });
        }
        const ety = CType{
            .kind = if (lv.elem.float) .float else .int,
            .bits = lv.elem.bits,
            .signed = lv.elem.signed,
        };
        return try allocPrint(self.gpa, "({s})", .{try self.heapStore(lv.elem, lv.addr, try self.wrap(rhs, ety))});
    }

    /// Parse `( ... (arr_T *) & global ... ) -> array [ idx ]` at self.p (just
    /// after a consumed '&') and return `globalOffset + idx*elemsize`, the
    /// address of a fixed-array global's element. Returns null (without
    /// consuming) if the shape doesn't match.
    fn tryArrayWrapperAddr(self: *Transpiler) error{OutOfMemory}!?[]const u8 {
        const save: usize = self.p;
        if (!self.atText("(")) {
            return null;
        }
        // Scan within the outer parens for the `arr_*` cast tag and the global name.
        // Shape: ( ( ( (struct arr_T *) & global ) ) ) -> array [ idx ]
        var elem: ?Elem = null;
        // skip leading '('s
        while (self.atText("(")) {
            self.p += 1;
        }
        // optional 'struct'
        if (self.atText("struct")) {
            self.p += 1;
        }
        // the arr_ tag ident
        if (self.current().kind == .ident) {
            if (parseArrTag(self.current().text)) |info| {
                elem = info.elem;
            }
        }
        if (elem == null) {
            self.p = save;
            return null;
        }
        self.p += 1; // arr tag
        if (!self.atText("*")) {
            self.p = save;
            return null;
        }
        self.p += 1; // *
        while (self.atText(")")) {
            self.p += 1;
        } // close cast parens
        if (!self.atText("&")) {
            self.p = save;
            return null;
        }
        self.p += 1; // &
        if (self.current().kind != .ident) {
            self.p = save;
            return null;
        }
        const gname: []const u8 = self.current().text;
        const off: u32 = self.globals.get(gname) orelse {
            self.p = save;
            return null;
        };
        self.p += 1; // global name
        while (self.atText(")")) {
            self.p += 1;
        } // close remaining wrapper parens
        // -> array [ idx ]
        if (!self.atText("->")) {
            self.p = save;
            return null;
        }
        self.p += 1; // ->
        if (!(self.current().kind == .ident and eql(u8, self.current().text, "array"))) {
            self.p = save;
            return null;
        }
        self.p += 1; // array
        if (!self.atText("[")) {
            self.p = save;
            return null;
        }
        self.p += 1; // [
        const idx: []const u8 = try self.parseExpr();
        self.expect("]");
        const e: Elem = elem.?;
        const size: usize = elemSize(e);
        return try allocPrint(self.gpa, "(({d}) + ({s}) * {d})", .{ off, idx, size });
    }

    /// Store form of the array-wrapper element address:
    /// `((arr_N_T*)&global)->array[idx] = rhs`  ->  heapStore at off + idx*size.
    /// Mirrors tryArrayWrapperAddr but consumes the `= rhs` and emits the store
    /// (routing a 64-bit element through __st64). Returns null (without consuming)
    /// if the shape — including the trailing `=` — doesn't match.
    fn tryArrayWrapperStore(self: *Transpiler) error{OutOfMemory}!?[]const u8 {
        const save: usize = self.p;
        if (!self.atText("(")) {
            return null;
        }
        var elem: ?Elem = null;
        var elem_struct: ?[]const u8 = null; // set for a STRUCT-element wrapper
        while (self.atText("(")) {
            self.p += 1;
        } // leading '('s
        if (self.atText("struct")) {
            self.p += 1;
        }
        if (self.current().kind == .ident) {
            const wt: []const u8 = self.current().text;
            if (parseArrTag(wt)) |info| {
                elem = info.elem; // primitive-element wrapper
            } else if (startsWith(u8, wt, "arr_") and self.structs.contains(wt)) {
                // STRUCT-element wrapper (`arr_N_<struct>`): the `array` field carries
                // the element struct in its struct_tag; the element store is a byte copy.
                if (self.fieldOf(wt, "array")) |af| {
                    if (af.struct_tag) |est| {
                        if (self.structs.contains(est)) {
                            elem_struct = est;
                        }
                    }
                }
            }
        }
        if (elem == null and elem_struct == null) {
            self.p = save;
            return null;
        }
        self.p += 1; // arr tag
        if (!self.atText("*")) {
            self.p = save;
            return null;
        }
        self.p += 1; // *
        while (self.atText(")")) {
            self.p += 1;
        } // close cast parens
        if (!self.atText("&")) {
            self.p = save;
            return null;
        }
        self.p += 1; // &
        if (self.current().kind != .ident) {
            self.p = save;
            return null;
        }
        const gname: []const u8 = self.current().text;
        const off: u32 = self.globals.get(gname) orelse {
            self.p = save;
            return null;
        };
        self.p += 1; // global name
        while (self.atText(")")) {
            self.p += 1;
        } // remaining wrapper parens
        if (!self.atText("->")) {
            self.p = save;
            return null;
        }
        self.p += 1; // ->
        if (!(self.current().kind == .ident and eql(u8, self.current().text, "array"))) {
            self.p = save;
            return null;
        }
        self.p += 1; // array
        if (!self.atText("[")) {
            self.p = save;
            return null;
        }
        self.p += 1; // [
        const idx: []const u8 = try self.parseExpr();
        self.expect("]");
        if (!self.atText("=") or eql(u8, self.lookahead(1).text, "=")) {
            self.p = save; // not a plain assignment — let the rvalue path handle it
            return null;
        }
        self.p += 1; // =
        const rhs: []const u8 = try self.parseAssign();
        // STRUCT-element wrapper: byte-copy the element struct (rhs is its offset).
        if (elem_struct) |est| {
            const sz: u32 = if (self.structs.get(est)) |layout| layout.size else 4;
            const addr: []const u8 = try allocPrint(self.gpa, "(({d}) + ({s}) * {d})", .{ off, idx, sz });
            return try allocPrint(self.gpa, "__copy({s}, {s}, {d})", .{ addr, rhs, sz });
        }
        const e: Elem = elem.?;
        const ety = CType{ .kind = if (e.float) .float else .int, .bits = e.bits, .signed = e.signed };
        const addr: []const u8 = try allocPrint(self.gpa, "(({d}) + ({s}) * {d})", .{ off, idx, elemSize(e) });
        return try allocPrint(self.gpa, "({s})", .{try self.heapStore(e, addr, try self.wrap(rhs, ety))});
    }

    /// Render `arg` (already-emitted JS for a u64 word) as a BigInt-valued expression.
    /// A bare integer literal is turned into a BigInt LITERAL (`123n`) so values above
    /// 2^53 keep full precision — `BigInt(18446744072709551609)` would first round the
    /// Number literal and lose the low bits. Non-literal expressions use `BigInt(...)`.
    fn bigLit(self: *Transpiler, arg: []const u8) error{OutOfMemory}![]const u8 {
        var s: []const u8 = arg;
        if (s.len >= 2 and s[0] == '(' and s[s.len - 1] == ')') {
            s = s[1 .. s.len - 1]; // one paren layer
        }
        var neg: []const u8 = "";
        if (s.len > 0 and s[0] == '-') {
            neg = "-";
            s = s[1..];
        }
        const is_int: bool = blk: {
            if (s.len == 0) {
                break :blk false;
            }
            if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
                for (s[2..]) |ch| {
                    if (!std.ascii.isHex(ch)) {
                        break :blk false;
                    }
                }
                break :blk true;
            }
            for (s) |ch| {
                if (ch < '0' or ch > '9') {
                    break :blk false;
                }
            }
            break :blk true;
        };
        if (is_int) {
            return allocPrint(self.gpa, "{s}{s}n", .{ neg, s });
        }
        return allocPrint(self.gpa, "BigInt({s})", .{arg});
    }

    /// Lower a 128-bit C-backend helper call `zig_<op>_<u|i>128(args...)` to a BigInt
    /// expression. Returns null for ops we don't model yet (caller emits a loud marker).
    /// A u128/i128 value is represented as a BigInt; `lo`/`hi` convert a 64-bit word to a
    /// Number at the boundary (lossy beyond 2^53 — the same limit as the 64-bit ABI).
    /// True if `name` is a wide-integer arithmetic helper `zig_<op>_<u|i><64|128>` for
    /// an op bigIntWide lowers — so it can be intercepted BEFORE its args are consumed,
    /// while clz/ctz/popcount/overflow helpers (same _u64 tail) fall through.
    fn isWideArith(self: *Transpiler, name: []const u8) bool {
        _ = self;
        if (!startsWith(u8, name, "zig_")) {
            return false;
        }
        var i: usize = name.len;
        while (i > 0 and name[i - 1] >= '0' and name[i - 1] <= '9') {
            i -= 1;
        }
        const w: []const u8 = name[i..];
        if (!(eql(u8, w, "64") or eql(u8, w, "128"))) {
            return false;
        }
        if (i < 6 or name[i - 2] != '_' or (name[i - 1] != 'u' and name[i - 1] != 'i')) {
            return false;
        }
        const op: []const u8 = name[4 .. i - 2];
        // Both spellings of the renamed ops (1857: div_trunc -> divTrunc), for
        // the reason given at the narrow div/mod block: c2js transpiles C, and
        // the C it is handed may come from either toolchain.
        const ops = [_][]const u8{
            "make", "lo",   "hi",  "addw",      "subw",     "mulw", "shlw",
            "shl",  "shrw", "shr", "and",       "or",       "xor",  "not",
            "add",  "sub",  "mul", "div_trunc", "divTrunc", "rem",  "cmp",
        };
        for (ops) |o| {
            if (eql(u8, op, o)) {
                return true;
            }
        }
        return false;
    }

    /// Record a place where c2js had to GUESS rather than model. Reported at the
    /// end of the run alongside the `/*?...*/` markers: a guessed width silently
    /// drops a mask or a sign-extension, which is the same silently-wrong-value
    /// class as a marker, just without a visible trace in the emitted JS.
    fn noteDiag(self: *Transpiler, msg: []const u8) void {
        // The COUNT is what the gate tests and it cannot fail; storing the text
        // is a nicety. So an allocation failure here costs us a message, never a
        // silently green build.
        self.diag_count += 1;
        // lint:off catch-suppression: count already recorded above; text is best-effort
        self.diags.append(self.gpa, msg) catch {};
    }

    /// Parse zig.h's trailing `bits` argument (arrives as `UINT8_C(N)`, already
    /// unwrapped to `N` by the literal handler). On failure keep going with
    /// `dflt` so the transpile still reports everything at once, but RECORD it —
    /// a wrong width means a dropped mask on every sub-width integer downstream.
    fn bitsArg(self: *Transpiler, e: []const u8, dflt: u16) u16 {
        const text: []const u8 = trim(u8, e, "() ");
        return parseInt(u16, text, 10) catch {
            const msg: []const u8 = allocPrint(
                self.gpa,
                "could not parse a cast width from '{s}'; guessed {d} (mask/sign-extend may be wrong)",
                .{ text, dflt },
            ) catch return dflt;
            self.noteDiag(msg);
            return dflt;
        };
    }

    /// A C-backend integer cast helper, matched by name.
    const CastHelper = struct {
        dst_bits: u16,
        dst_signed: bool,
        has_bits_arg: bool,
    };

    /// Match `zig_<u|i><dw>_<op>_<u|i><sw>` (op = intCast | truncate | bitCast),
    /// the spelling Zig's C backend uses for integer casts. Returns the
    /// DESTINATION width and signedness, plus whether the call carries zig.h's
    /// trailing `bits` argument. Returns null for any other name.
    fn castHelper(self: *Transpiler, name: []const u8) ?CastHelper {
        _ = self;
        if (!startsWith(u8, name, "zig_")) {
            return null;
        }
        var i: usize = "zig_".len;
        if (i >= name.len or (name[i] != 'u' and name[i] != 'i')) {
            return null;
        }
        const dst_signed: bool = name[i] == 'i';
        i += 1;
        const dw_start: usize = i;
        while (i < name.len and name[i] >= '0' and name[i] <= '9') {
            i += 1;
        }
        if (i == dw_start or i >= name.len or name[i] != '_') {
            return null;
        }
        const dst_bits: u16 = parseInt(u16, name[dw_start..i], 10) catch return null;
        const rest: []const u8 = name[i + 1 ..];
        const Op = struct { tag: []const u8, bits_arg: bool };
        // zig.h: intCast is value-preserving and takes no `bits`; truncate and
        // bitCast both take one (bitCast forwards straight to truncate).
        const ops = [_]Op{
            .{ .tag = "intCast_", .bits_arg = false },
            .{ .tag = "truncate_", .bits_arg = true },
            .{ .tag = "bitCast_", .bits_arg = true },
        };
        for (ops) |o| {
            if (!startsWith(u8, rest, o.tag)) {
                continue;
            }
            const src: []const u8 = rest[o.tag.len..];
            if (src.len < 2 or (src[0] != 'u' and src[0] != 'i')) {
                return null;
            }
            return .{ .dst_bits = dst_bits, .dst_signed = dst_signed, .has_bits_arg = o.bits_arg };
        }
        return null;
    }

    /// Lower a wide-integer C-backend helper call `zig_<op>_<u|i><width>(args...)` to a
    /// BigInt expression, for width 64 or 128. Returns null for ops we don't model yet
    /// (caller emits a loud marker). The value is a BigInt; `lo`/`hi` (128-bit only)
    /// convert a 64-bit word to a Number (lossy beyond 2^53, same as a wide @truncate).
    fn bigIntWide(
        self: *Transpiler,
        name: []const u8,
        args: []const []const u8,
    ) error{OutOfMemory}!?[]const u8 {
        if (!startsWith(u8, name, "zig_")) {
            return null;
        }
        // Parse the trailing width digits, then the `_u`/`_i` before them.
        var i: usize = name.len;
        while (i > 0 and name[i - 1] >= '0' and name[i - 1] <= '9') {
            i -= 1;
        }
        const width_str: []const u8 = name[i..]; // "64" / "128"
        if (!(eql(u8, width_str, "64") or eql(u8, width_str, "128"))) {
            return null;
        }
        if (i < 6 or name[i - 2] != '_' or (name[i - 1] != 'u' and name[i - 1] != 'i')) {
            return null;
        }
        const signed: bool = name[i - 1] == 'i';
        const op: []const u8 = name[4 .. i - 2]; // between "zig_" and "_{u,i}<width>"
        const mask: []const u8 = if (signed) "asIntN" else "asUintN";
        // Result is a BigInt of `width` bits, EXCEPT lo/hi which extract a u64 as a Number.
        const is_u64_extract: bool = eql(u8, op, "lo") or eql(u8, op, "hi");
        const wide_bits: u16 = if (eql(u8, width_str, "128")) 128 else 64;
        self.last_w = if (is_u64_extract) 0 else wide_bits;
        const a: []const u8 = if (args.len > 0) args[0] else "0";
        const b: []const u8 = if (args.len > 1) args[1] else "0";
        // wrapping ops carry the result bit-width as their last arg; default to width_str.
        const bits: []const u8 = if (args.len > 2) args[2] else width_str;
        if (eql(u8, op, "make")) {
            // combine two u64 words (hi, lo) into a 128-bit BigInt (128-bit only)
            const comb: []const u8 = try allocPrint(
                self.gpa,
                "((BigInt.asUintN(64,{s})<<64n)|BigInt.asUintN(64,{s}))",
                .{ try self.bigLit(a), try self.bigLit(b) },
            );
            return if (signed) try allocPrint(self.gpa, "BigInt.asIntN({s},{s})", .{ width_str, comb }) else comb;
        }
        if (eql(u8, op, "lo")) {
            return try allocPrint(self.gpa, "Number(BigInt.asUintN(64,{s}))", .{a});
        }
        if (eql(u8, op, "hi")) {
            return try allocPrint(self.gpa, "Number(BigInt.asUintN(64,({s})>>64n))", .{a});
        }
        if (eql(u8, op, "addw")) {
            return try allocPrint(self.gpa, "BigInt.{s}({s},({s})+({s}))", .{ mask, bits, a, b });
        }
        if (eql(u8, op, "subw")) {
            return try allocPrint(self.gpa, "BigInt.{s}({s},({s})-({s}))", .{ mask, bits, a, b });
        }
        if (eql(u8, op, "mulw")) {
            return try allocPrint(self.gpa, "BigInt.{s}({s},({s})*({s}))", .{ mask, bits, a, b });
        }
        if (eql(u8, op, "shlw") or eql(u8, op, "shl")) {
            return try allocPrint(self.gpa, "BigInt.{s}({s},({s})<<BigInt({s}))", .{ mask, bits, a, b });
        }
        if (eql(u8, op, "shr") or eql(u8, op, "shrw")) {
            // BigInt >> is arithmetic; for unsigned the value is non-negative so it matches
            // a logical shift, and re-narrowing keeps a signed result in range.
            return if (signed)
                try allocPrint(self.gpa, "BigInt.asIntN({s},({s})>>BigInt({s}))", .{ width_str, a, b })
            else
                try allocPrint(self.gpa, "(({s})>>BigInt({s}))", .{ a, b });
        }
        if (eql(u8, op, "and")) {
            return try allocPrint(self.gpa, "(({s})&({s}))", .{ a, b });
        }
        if (eql(u8, op, "or")) {
            return try allocPrint(self.gpa, "(({s})|({s}))", .{ a, b });
        }
        if (eql(u8, op, "xor")) {
            return try allocPrint(self.gpa, "(({s})^({s}))", .{ a, b });
        }
        if (eql(u8, op, "not")) {
            // `not` carries its width as the SECOND arg, not the third: the
            // generic `bits` above is for the three-arg wrapping ops (a, b, bits),
            // and `zig_not_uN(x, bits)` has only two. A u48 arrives as
            // `zig_not_u64(x, 48)` and must mask at 48 — masking at the uint64_t
            // STORAGE width leaves all 16 bits above the declared width set, so
            // `~x` compared against `x ^ maxInt(48)` disagreed. (Signed is
            // indifferent: `~x` of a sign-extended iN is already in range at
            // either width, matching zig.h, which ignores `bits` for the i form.)
            const not_bits: []const u8 = if (args.len > 1) args[1] else width_str;
            return try allocPrint(self.gpa, "BigInt.{s}({s},~({s}))", .{ mask, not_bits, a });
        }
        // Non-wrapping-named arithmetic (current C backend emits `zig_add_u128`,
        // `zig_mul_u128`, ... without the trailing `w` and with no explicit bits
        // arg). For u128/i128 the operation still wraps mod 2^width, so mask to the
        // full width. div_trunc/rem truncate toward zero (BigInt `/` and `%` already
        // do, matching Zig's div_trunc for both signs); their result is within the
        // operand range so the mask is a safety no-op.
        if (eql(u8, op, "add")) {
            return try allocPrint(self.gpa, "BigInt.{s}({s},({s})+({s}))", .{ mask, width_str, a, b });
        }
        if (eql(u8, op, "sub")) {
            return try allocPrint(self.gpa, "BigInt.{s}({s},({s})-({s}))", .{ mask, width_str, a, b });
        }
        if (eql(u8, op, "mul")) {
            return try allocPrint(self.gpa, "BigInt.{s}({s},({s})*({s}))", .{ mask, width_str, a, b });
        }
        if (eql(u8, op, "div_trunc") or eql(u8, op, "divTrunc")) {
            return try allocPrint(self.gpa, "BigInt.{s}({s},({s})/({s}))", .{ mask, width_str, a, b });
        }
        if (eql(u8, op, "rem")) {
            return try allocPrint(self.gpa, "BigInt.{s}({s},({s})%({s}))", .{ mask, width_str, a, b });
        }
        if (eql(u8, op, "cmp")) {
            // zig_cmp_<T>(a, b) -> i32 in {-1, 0, 1}. The result is a small Number,
            // not a wide BigInt, so reset the width tracker accordingly.
            self.last_w = 0;
            return try allocPrint(self.gpa, "(({s})<({s})?-1:({s})>({s})?1:0)", .{ a, b, a, b });
        }
        return null; // anything still unmodeled — caller emits a loud marker
    }

    /// Monomorphic call emission. A facade call (`Value.call`/`callVoid`) carries a
    /// comptime-literal method name, which Zig lowers to a (ptr,len) into a static
    /// data constant. Resolving that constant back to the name at emit time lets us
    /// emit a direct `__H[recv].name(args)` rather than the generic
    /// `__H[o][__jstr(p,l)].call(__H[o], …)`. A direct, inline-cacheable method call
    /// avoids decoding the name and the dynamic `obj[key]` lookup on every call.
    /// Conservative: a name that does not resolve to a plain identifier at a known
    /// data offset falls back to the exact generic kernel call, so output stays correct.
    fn tryMonoCall(self: *Transpiler, name: []const u8) error{OutOfMemory}!?[]const u8 {
        var numeric: bool = false;
        var suffix: []const u8 = undefined;
        if (startsWith(u8, name, "js_calln")) {
            numeric = true;
            suffix = name["js_calln".len..];
        } else if (startsWith(u8, name, "js_call")) {
            numeric = false;
            suffix = name["js_call".len..];
        } else {
            return null;
        }
        var void_call: bool = false;
        var ds: []const u8 = suffix;
        if (ds.len > 0 and ds[ds.len - 1] == 'v') {
            void_call = true;
            ds = ds[0 .. ds.len - 1];
        }
        if (ds.len != 1 or ds[0] < '0' or ds[0] > '6') {
            return null; // not js_callN / excludes js_call_n
        }
        const arity: usize = ds[0] - '0';

        if (!self.atText("(")) {
            return null;
        }
        self.p += 1;
        var args: ArrayList([]const u8) = .empty;
        while (self.current().kind != .eof and !self.atText(")")) {
            try args.append(self.gpa, try self.parseAssign());
            if (!self.consume(",")) {
                break;
            }
        }
        self.expect(")");
        // every js_call*(o, p, l, …arity args). Anything off-shape -> exact rebuild.
        if (args.items.len != 3 + arity) {
            return try self.rebuildCall(name, args.items);
        }
        const recv: []const u8 = args.items[0];
        const off: usize = parseDecimalLit(args.items[1]) orelse return try self.rebuildCall(name, args.items);
        const len: usize = parseDecimalLit(args.items[2]) orelse return try self.rebuildCall(name, args.items);
        if (off < self.data_base) {
            return try self.rebuildCall(name, args.items);
        }
        const di: usize = off - self.data_base;
        if (di + len > self.data.items.len) {
            return try self.rebuildCall(name, args.items);
        }
        const nm: []const u8 = self.data.items[di .. di + len];
        if (!isJsIdent(nm)) {
            return try self.rebuildCall(name, args.items); // dashes/empty -> fall back
        }

        var ca: ArrayList(u8) = .empty;
        for (args.items[3..], 0..) |a, i| {
            if (i > 0) {
                try ca.appendSlice(self.gpa, ", ");
            }
            if (numeric) {
                try ca.appendSlice(self.gpa, a); // raw number, no handle
            } else {
                try ca.appendSlice(self.gpa, "__H[");
                try ca.appendSlice(self.gpa, a);
                try ca.append(self.gpa, ']');
            }
        }
        const body: []const u8 = try allocPrint(self.gpa, "__H[{s}].{s}({s})", .{ recv, nm, ca.items });
        if (void_call) {
            return body;
        }
        return try allocPrint(self.gpa, "__href({s})", .{body});
    }

    /// Re-emit the exact normal kernel call from already-parsed args (the safe fallback
    /// when a name can't be resolved). Identical to what the ordinary path would emit.
    fn rebuildCall(
        self: *Transpiler,
        name: []const u8,
        args: [][]const u8,
    ) error{OutOfMemory}![]const u8 {
        var b: ArrayList(u8) = .empty;
        try b.appendSlice(self.gpa, name);
        try b.append(self.gpa, '(');
        for (args, 0..) |a, i| {
            if (i > 0) {
                try b.appendSlice(self.gpa, ", ");
            }
            try b.appendSlice(self.gpa, a);
        }
        try b.append(self.gpa, ')');
        return b.items;
    }

    /// Monomorphic property access — the get/set analogue of tryMonoCall. A facade
    /// `.get`/`.set`/`.getNum`/`.set`(numeric) also carries a comptime-literal property
    /// name; resolve it and emit `__H[o].name` / `__H[o].name = …` directly instead of
    /// the dynamic `__H[o][__jstr(p,l)]`. Same conservative fallback to the exact kernel.
    fn tryMonoProp(self: *Transpiler, name: []const u8) error{OutOfMemory}!?[]const u8 {
        const is_get = eql(u8, name, "js_get");
        const is_getn = eql(u8, name, "js_get_num");
        const is_set = eql(u8, name, "js_set");
        const is_setn = eql(u8, name, "js_set_num");
        if (!(is_get or is_getn or is_set or is_setn)) {
            return null;
        }
        const nargs: usize = if (is_set or is_setn) 4 else 3;

        if (!self.atText("(")) {
            return null;
        }
        self.p += 1;
        var args: ArrayList([]const u8) = .empty;
        while (self.current().kind != .eof and !self.atText(")")) {
            try args.append(self.gpa, try self.parseAssign());
            if (!self.consume(",")) {
                break;
            }
        }
        self.expect(")");
        if (args.items.len != nargs) {
            return try self.rebuildCall(name, args.items);
        }
        const recv: []const u8 = args.items[0];
        const off: usize = parseDecimalLit(args.items[1]) orelse return try self.rebuildCall(name, args.items);
        const len: usize = parseDecimalLit(args.items[2]) orelse return try self.rebuildCall(name, args.items);
        if (off < self.data_base) {
            return try self.rebuildCall(name, args.items);
        }
        const di: usize = off - self.data_base;
        if (di + len > self.data.items.len) {
            return try self.rebuildCall(name, args.items);
        }
        const nm: []const u8 = self.data.items[di .. di + len];
        if (!isJsIdent(nm)) {
            return try self.rebuildCall(name, args.items);
        }

        if (is_get) {
            return try allocPrint(self.gpa, "__href(__H[{s}].{s})", .{ recv, nm });
        }
        if (is_getn) {
            return try allocPrint(self.gpa, "(+__H[{s}].{s})", .{ recv, nm });
        }
        if (is_setn) {
            return try allocPrint(self.gpa, "__H[{s}].{s} = {s}", .{ recv, nm, args.items[3] });
        }
        return try allocPrint(self.gpa, "__H[{s}].{s} = __H[{s}]", .{ recv, nm, args.items[3] }); // is_set
    }

    /// Recognized function-like builtins from zig.h / stdint.h.
    /// Returns null if `name` is not such a builtin (=> ordinary call/identifier).
    fn tryBuiltinCall(self: *Transpiler, name: []const u8) error{OutOfMemory}!?[]const u8 {
        if (try self.tryMonoCall(name)) |m| {
            return m;
        }
        if (try self.tryMonoProp(name)) |m| {
            return m;
        }
        // Noreturn trap primitives: a reached `unreachable`, an explicit @trap(), or the
        // tail of a panic chain (a safety check that failed). These MUST halt — emit a
        // throw so integer-overflow / bounds / reached-unreachable panics in Debug &
        // ReleaseSafe builds are loud, instead of being dropped (zig.h lowers them as
        // function-like macros, which the preprocessor otherwise ignores → the panic
        // would silently fall through and the wrapped value would be returned).
        if (eql(u8, name, "zig_unreachable") or eql(u8, name, "zig_trap")) {
            if (self.atText("(")) {
                const close: usize = self.matching(self.p, "(", ")");
                self.p = close + 1;
            }
            return try self.gpa.dupe(u8, "__panic('reached unreachable code')");
        }
        // Atomics. Single-threaded wasm: lower to a plain load / store / read-modify-
        // write (memory ordering is a no-op). The C backend emits these as function-
        // like macros the preprocessor ignores, so without this they were SILENTLY
        // DROPPED — an atomic store / RMW vanished and an atomic load left a stale
        // temp. Shapes (the result of a load/RMW is written to the FIRST arg, a local):
        //   zig_atomic_store(ptr, val, order, T, CT)        -> *ptr = val
        //   zig_atomic_load(res, ptr, order, T, CT)         -> res = *ptr
        //   zig_atomicrmw_OP(res, ptr, val, order, T, CT)   -> res = *ptr; *ptr = res OP val
        if (startsWith(u8, name, "zig_atomic_store") or
            startsWith(u8, name, "zig_atomic_load") or
            startsWith(u8, name, "zig_atomicrmw_"))
        {
            if (self.atText("(")) {
                self.p += 1;
                var args: ArrayList([]const u8) = .empty;
                while (self.current().kind != .eof and !self.atText(")")) {
                    try args.append(self.gpa, try self.parseAssign());
                    if (!self.consume(",")) {
                        break;
                    }
                }
                self.expect(")");
                // Element type = the Zig width token (u8/i32/u64/u40/…) among the args.
                var elem: Elem = .{ .bits = 32, .signed = false, .float = false };
                for (args.items) |a| {
                    if (elemFromName(a)) |e2| {
                        elem = e2;
                        break;
                    }
                }
                const ity: CType = .{ .kind = .int, .bits = elem.bits, .signed = elem.signed };
                if (startsWith(u8, name, "zig_atomic_store")) {
                    if (args.items.len >= 2) {
                        const v: []const u8 = try self.wrap(args.items[1], ity);
                        return try self.heapStore(elem, args.items[0], v);
                    }
                } else if (startsWith(u8, name, "zig_atomic_load")) {
                    if (args.items.len >= 2) {
                        const ld: []const u8 = try self.heapLoad(elem, args.items[1]);
                        return try allocPrint(self.gpa, "{s} = {s}", .{ args.items[0], ld });
                    }
                } else {
                    const op_s: []const u8 = name["zig_atomicrmw_".len..];
                    if (args.items.len >= 3) {
                        const res: []const u8 = args.items[0];
                        const ptr: []const u8 = args.items[1];
                        const val: []const u8 = args.items[2];
                        const ld: []const u8 = try self.heapLoad(elem, ptr);
                        const newv: ?[]const u8 = if (eql(u8, op_s, "add"))
                            try allocPrint(self.gpa, "{s} + {s}", .{ res, val })
                        else if (eql(u8, op_s, "sub"))
                            try allocPrint(self.gpa, "{s} - {s}", .{ res, val })
                        else if (eql(u8, op_s, "xchg"))
                            try self.gpa.dupe(u8, val)
                        else if (eql(u8, op_s, "and"))
                            try allocPrint(self.gpa, "{s} & {s}", .{ res, val })
                        else if (eql(u8, op_s, "or"))
                            try allocPrint(self.gpa, "{s} | {s}", .{ res, val })
                        else if (eql(u8, op_s, "xor"))
                            try allocPrint(self.gpa, "{s} ^ {s}", .{ res, val })
                        else if (eql(u8, op_s, "nand"))
                            try allocPrint(self.gpa, "~({s} & {s})", .{ res, val })
                        else
                            null;
                        if (newv) |nv| {
                            const wrapped: []const u8 = try self.wrap(nv, ity);
                            const st: []const u8 = try self.heapStore(elem, ptr, wrapped);
                            return try allocPrint(self.gpa, "({s} = {s}, {s})", .{ res, ld, st });
                        }
                    }
                }
                return try allocPrint(self.gpa, "/*?unhandled-atomic:{s}*/ 0", .{name});
            }
        }
        // @wasmMemorySize(idx) / @wasmMemoryGrow(idx, delta). The memory index is
        // always 0 in wasm32; size returns the current page count, grow extends the
        // (resizable) linear memory and returns the OLD page count or -1.
        if (eql(u8, name, "zig_wasm_memory_size") or eql(u8, name, "zig_wasm_memory_grow")) {
            if (self.atText("(")) {
                self.p += 1;
                var args: ArrayList([]const u8) = .empty;
                while (self.current().kind != .eof and !self.atText(")")) {
                    try args.append(self.gpa, try self.parseAssign());
                    if (!self.consume(",")) {
                        break;
                    }
                }
                self.expect(")");
                self.last_w = 0; // a page count is a plain 32-bit Number
                if (eql(u8, name, "zig_wasm_memory_size")) {
                    return try self.gpa.dupe(u8, "__wmsize()");
                }
                const delta: []const u8 = if (args.items.len >= 2) args.items[1] else "0";
                return try allocPrint(self.gpa, "__wmgrow({s})", .{delta});
            }
        }
        // Wide-integer (64/128) arithmetic via BigInt. JS Number is exact only to
        // 2^53, so genuine u64/i64 and all u128/i128 are BigInts. The C backend routes
        // WRAPPING add/sub/mul/shift (and 128-bit bitwise) through zig_<op>_<u|i><width>
        // helpers; we lower those to BigInt. clz/ctz/popcount/overflow helpers also end
        // in _u64 but have their own handlers below, so isWideArith() matches only the
        // recognized arithmetic ops (checked BEFORE consuming args, so the rest fall
        // through). A recognized-but-unmodeled wide op (e.g. 128-bit div) stays loud.
        if (self.isWideArith(name)) {
            if (self.atText("(")) {
                self.p += 1;
                var args: ArrayList([]const u8) = .empty;
                while (self.current().kind != .eof and !self.atText(")")) {
                    try args.append(self.gpa, try self.parseAssign());
                    if (!self.consume(",")) {
                        break;
                    }
                }
                self.expect(")");
                if (try self.bigIntWide(name, args.items)) |js| {
                    return js;
                }
            }
            return try self.gpa.dupe(
                u8,
                "/*?wideint-helper-unmodeled: this 64/128-bit op isn't lowered to BigInt yet*/ 0n",
            );
        }
        // @returnAddress() / zig_return_address(): the caller's code address. There
        // are no code addresses in the transpiled JS, and the value is only ever used
        // for diagnostics (panic traces, allocator bookkeeping) that don't apply here,
        // so lower it to 0 instead of surfacing an unhandled-helper marker. (Appears
        // in Debug/ReleaseSafe builds, inside the panic machinery.)
        if (eql(u8, name, "zig_return_address")) {
            if (self.atText("(")) {
                const close: usize = self.matching(self.p, "(", ")");
                self.p = close + 1;
            }
            return try self.gpa.dupe(u8, "0");
        }

        // scalars as `memcpy(&dst, &src, N)` — a byte reinterpretation through the
        // addresses of two locals. Local scalars aren't heap-backed (they're JS
        // variables), so a literal heap memcpy is meaningless here. Reinterpret
        // the bits correctly by staging through a typed-view scratch slot: store
        // src via its own view (its bit pattern), load dst via dst's view. This is
        // exact for int<->int (e.g. i32<->u32) AND float<->int (e.g. f32<->u32).
        if (eql(u8, name, "memcpy") or eql(u8, name, "memmove")) {
            if (self.atText("(") and eql(u8, self.lookahead(1).text, "&") and
                self.lookahead(2).kind == .ident and
                eql(u8, self.lookahead(3).text, ",") and eql(u8, self.lookahead(4).text, "&") and
                self.lookahead(5).kind == .ident)
            {
                const a_name: []const u8 = self.lookahead(2).text; // dst (&a)
                const b_name: []const u8 = self.lookahead(5).text; // src (&b)
                const scalar = struct {
                    fn isScalar(k: CTypeKind) bool {
                        return k == .int or k == .float or k == .boolean;
                    }
                };
                // Each side is either a local scalar (a JS variable, NOT heap-
                // backed) or a global (heap-backed at a known offset). A common
                // case is `local = @bitCast(CONST)`, where the constant is a global
                // (heap-backed at a known offset); it is resolved here because the
                // normal path would treat the local's *value* as an address.
                // A packed-struct (or other address-taken) local is heap-backed at
                // a scratch slot with NO plain JS variable — its canonical location
                // is the slot, exactly like a global. Fold it into the global path so
                // the byte-reinterpret reads/writes the slot instead of a bare name
                // (which was never declared: `t7 is not defined`).
                const a_glob: ?u32 = self.globals.get(a_name) orelse self.scalar_slots.get(a_name);
                const b_glob: ?u32 = self.globals.get(b_name) orelse self.scalar_slots.get(b_name);
                const a_local: ?VarInfo = if (a_glob == null) self.vars.get(a_name) else null;
                const b_local: ?VarInfo = if (b_glob == null) self.vars.get(b_name) else null;
                const a_ok: bool = a_glob != null or (a_local != null and scalar.isScalar(a_local.?.ty.kind));
                const b_ok: bool = b_glob != null or (b_local != null and scalar.isScalar(b_local.?.ty.kind));
                // At least one side must be a local scalar; if BOTH are globals
                // they are heap-backed and the normal memcpy path is correct.
                if (a_ok and b_ok and !(a_glob != null and b_glob != null)) {
                    const close: usize = self.matching(self.p, "(", ")");
                    self.p = close + 1; // consume the whole memcpy(...) call
                    if (self.bitcast_slot == null) {
                        self.bitcast_slot = self.allocScratch(8);
                    }
                    const slot: u32 = self.bitcast_slot.?;
                    if (a_local != null and b_local != null) {
                        // both local: stage src's bits in the slot via src's view,
                        // read back through dst's view (the reinterpretation). A 64-bit
                        // INT uses __st64/__ld[u/i]64 (two 32-bit words, a BigInt) rather
                        // than elemView's __HEAP32 (which holds 4 bytes and can't take a
                        // BigInt); f32/f64 still go through __HEAPF32/F64.
                        const ea: Elem = elemOfTy(a_local.?.ty);
                        const eb: Elem = elemOfTy(b_local.?.ty);
                        const store_expr: []const u8 = if (eb.bits == 64 and !eb.float)
                            try allocPrint(self.gpa, "__st64({d}, ({s}))", .{ slot, b_name })
                        else
                            try allocPrint(
                                self.gpa,
                                "{s}[({d}) >> {d}] = ({s})",
                                .{ elemView(eb), slot, elemShift(eb), b_name },
                            );
                        const load_expr: []const u8 = if (ea.bits == 64 and !ea.float)
                            try allocPrint(self.gpa, "{s}({d})", .{ if (ea.signed) "__ldi64" else "__ldu64", slot })
                        else
                            try allocPrint(self.gpa, "{s}[({d}) >> {d}]", .{ elemView(ea), slot, elemShift(ea) });
                        self.last_w = if (ea.bits == 64 and !ea.float) 64 else 0;
                        return try allocPrint(self.gpa, "({s}, ({s}) = {s})", .{ store_expr, a_name, load_expr });
                    } else if (b_glob) |b_off| {
                        // dst local, src global (`local = @bitCast(CONST)`):
                        // reinterpret the global's bytes as dst's type, in place.
                        // A 64-bit INT dst is a BigInt — read it with __ld[u/i]64
                        // (two words), not a 32-bit typed-view load.
                        const ea: Elem = elemOfTy(a_local.?.ty);
                        const rd: []const u8 = if (ea.bits == 64 and !ea.float)
                            try allocPrint(self.gpa, "{s}({d})", .{ if (ea.signed) "__ldi64" else "__ldu64", b_off })
                        else
                            try allocPrint(self.gpa, "{s}[({d}) >> {d}]", .{ elemView(ea), b_off, elemShift(ea) });
                        self.last_w = if (ea.bits == 64 and !ea.float) 64 else 0;
                        return try allocPrint(self.gpa, "(({s}) = {s})", .{ a_name, rd });
                    } else {
                        // dst global, src local: stage src's bits in the slot via
                        // src's view, then byte-copy them into the global's heap
                        // bytes (reinterpretation-preserving; needs no dst type).
                        const a_off: u32 = a_glob.?;
                        const eb: Elem = elemOfTy(b_local.?.ty);
                        const n: u32 = (@as(u32, eb.bits) + 7) / 8;
                        // A 64-bit src is a BigInt — it must be staged with __st64
                        // (two 32-bit words); a typed-view store (`__HEAPU32[..] =
                        // bigint`) throws "Cannot convert a BigInt value to a number".
                        const stage: []const u8 = if (eb.bits == 64 and !eb.float)
                            try allocPrint(self.gpa, "__st64({d}, ({s}))", .{ slot, b_name })
                        else
                            try allocPrint(
                                self.gpa,
                                "{s}[({d}) >> {d}] = ({s})",
                                .{ elemView(eb), slot, elemShift(eb), b_name },
                            );
                        return try allocPrint(
                            self.gpa,
                            "({s}, __HEAPU8.copyWithin({d}, {d}, {d}))",
                            .{ stage, a_off, slot, slot + n },
                        );
                    }
                }
            }
            // not the scalar idiom -> let the normal call path emit heap memcpy
            return null;
        }
        // non-finite float constants: zig_make_special_fNN(sign, name, arg, repr)
        // where `name` is `inf` or `nan` and `sign` is an optional leading `-`
        // (e.g. `(-, inf, , 0xff800000)`). JS Numbers are f64, so map directly to
        // Infinity / -Infinity / NaN. Must be checked before zig_make_fNN.
        if (startsWith(u8, name, "zig_make_special_f")) {
            self.expect("(");
            var sign_neg: bool = false;
            if (self.atText("-")) {
                sign_neg = true;
                self.p += 1;
            }
            self.expect(","); // comma after the (possibly empty) sign field
            const kind: []const u8 = self.current().text; // "inf" or "nan"
            self.p += 1;
            // consume the remaining fields up to and including the matching ')'
            var depth: usize = 1;
            while (self.current().kind != .eof) {
                const tx: []const u8 = self.current().text;
                self.p += 1;
                if (eql(u8, tx, "(")) {
                    depth += 1;
                } else if (eql(u8, tx, ")")) {
                    depth -= 1;
                    if (depth == 0) {
                        break;
                    }
                }
            }
            if (eql(u8, kind, "nan")) {
                return try self.gpa.dupe(u8, "NaN");
            }
            return try self.gpa.dupe(u8, if (sign_neg) "(-Infinity)" else "Infinity");
        }

        // float literals: zig_make_f64(<hexfloat>, <u64 bits>) / zig_make_f32(...)
        // JS has no hex-float literal, so parse arg0 to decimal. Fall back to
        // reconstructing from the IEEE bits (arg1) if arg0 doesn't parse.
        if (eql(u8, name, "zig_make_f64") or eql(u8, name, "zig_make_f32")) {
            const is_f32: bool = eql(u8, name, "zig_make_f32");
            self.expect("(");
            // A negative hex-float literal is tokenized with a separate leading
            // `-` (so arg0 would be just "-"); consume the sign(s) first and apply
            // them to the parsed magnitude.
            var neg: bool = false;
            while (self.atText("-")) {
                neg = !neg;
                self.p += 1;
            }
            const a0: []const u8 = self.current().text;
            var v = std.fmt.parseFloat(f64, a0) catch blk: {
                // skip arg0, use the bits in arg1
                while (self.current().kind != .eof and !self.atText(",")) {
                    self.p += 1;
                }
                break :blk std.math.nan(f64);
            };
            if (!isNan(v)) {
                if (neg) {
                    v = -v;
                }
                self.p += 1; // consume arg0 token
                while (self.current().kind != .eof and !self.atText(",")) {
                    self.p += 1;
                } // to comma
            }
            self.expect(",");
            // the UINTxx_C(...) bits, already unwrapped
            const bits: []const u8 = try self.parseExpr();
            self.expect(")");
            if (!isNan(v)) {
                return try allocPrint(self.gpa, "{d}", .{v});
            }
            // reconstruct from the IEEE bits at the correct width (the f32 pattern
            // must NOT be read as f64 bits, or it decodes to a tiny denormal).
            return try allocPrint(
                self.gpa,
                "{s}({s})",
                .{ if (is_f32) "__f32bits" else "__f64bits", bits },
            );
        }
        // numeric-conversion builtins. JS numbers are f64, so <=32-bit int<->float
        // casts are identity / Math.trunc. But i64/u64 are BigInt in our model, so
        // a 64-bit source/destination needs an explicit Number()/BigInt() bridge.
        // The 64-bit forms carry the "di" int code (i128 "ti" stays unhandled).
        if (startsWith(u8, name, "zig_float")) { // int -> float
            self.expect("(");
            const inner: []const u8 = try self.parseExpr();
            self.expect(")");
            if (indexOf(u8, name, "di") != null) {
                return try allocPrint(self.gpa, "Number({s})", .{inner});
            }
            return inner;
        }
        if (eql(u8, name, "zig_extendsfdf") or eql(u8, name, "zig_truncdfsf")) {
            // f32<->f64 width changes: JS has only f64, so identity.
            self.expect("(");
            const inner: []const u8 = try self.parseExpr();
            self.expect(")");
            return inner;
        }
        if (startsWith(u8, name, "zig_fix")) { // float -> int (truncates toward zero)
            self.expect("(");
            const inner: []const u8 = try self.parseExpr();
            self.expect(")");
            if (endsWith(u8, name, "di")) {
                return try allocPrint(self.gpa, "BigInt(Math.trunc({s}))", .{inner});
            }
            return try allocPrint(self.gpa, "Math.trunc({s})", .{inner});
        }
        // @bitCast(float) -> integer repr: `zig_u32_bitCast_f32(x)`,
        // `zig_u64_bitCast_f64(x)` and their signed forms. ONE argument and no
        // width, so castHelper() below does NOT match these — its pattern wants
        // an integer SOURCE (`zig_<u|i>N_<op>_<u|i>M`), and here the source is a
        // float. They reached the marker and lowered to 0, which is the silent
        // kind of wrong: a float printer reading bits it never got.
        //
        // The inverse direction (int bits -> float) is __f32bits/__f64bits above.
        // f16 and f80 are deliberately NOT modelled — DataView has no portable
        // f16/f80 accessor, and a wrong answer there is worse than a loud marker.
        if (indexOf(u8, name, "_bitCast_f") != null and
            (endsWith(u8, name, "_f32") or endsWith(u8, name, "_f64")))
        {
            const is_f32: bool = endsWith(u8, name, "_f32");
            const signed: bool = name["zig_".len] == 'i';
            self.expect("(");
            const inner: []const u8 = try self.parseExpr();
            self.expect(")");
            // f64 bits are 64 wide, so they land in the BigInt domain; f32 bits
            // stay a Number. Tell the rest of the expression layer which.
            self.last_w = if (is_f32) 32 else 64;
            const call: []const u8 = try allocPrint(
                self.gpa,
                "{s}({s})",
                .{ if (is_f32) "__bitsf32" else "__bitsf64", inner },
            );
            if (!signed) {
                return call;
            }
            if (is_f32) {
                return try allocPrint(self.gpa, "(({s}) | 0)", .{call});
            }
            return try allocPrint(self.gpa, "BigInt.asIntN(64,{s})", .{call});
        }
        // Integer casts under the `zig_<dst>_<op>_<src>` spelling, e.g.
        // `zig_u32_truncate_u32(x, bits)`. zig.h defines intCast/truncate/bitCast
        // all in terms of the same mask (unsigned dest) or sign-extend (signed
        // dest) at the DESTINATION width, so they lower through the very same
        // wrap() as `zig_wrap_uN` below. Note these are NOT identity even when
        // src and dst widths match: `bits` can be narrower (a packed u9 in a u32).
        // Falling through to the unhandled-helper marker emitted a literal 0 —
        // silently wrong data rather than a crash.
        if (self.castHelper(name)) |ch| {
            self.expect("(");
            var inner: []const u8 = try self.parseExpr();
            // The ARGUMENT's domain, captured before parsing the width clobbers it.
            const src_w: u16 = self.last_w;
            var bits: u16 = ch.dst_bits;
            if (ch.has_bits_arg) {
                self.expect(",");
                // Parse the transpiled expression, not the raw token: the width
                // arrives wrapped as `UINT8_C(N)` (same reason as zig_wrap_ below).
                const bits_e: []const u8 = try self.parseExpr();
                bits = self.bitsArg(bits_e, ch.dst_bits);
            }
            self.expect(")");
            // A cast is the one place that legitimately CROSSES c2js's value
            // domains: <=32-bit values are Numbers, 33+ bit values are BigInts.
            // asUintN throws on a Number ("Cannot convert 19 to a BigInt"), and
            // a Number mask on a BigInt throws too, so coerce explicitly here
            // rather than letting either reach the browser. Narrowing masks in
            // the BigInt domain FIRST: a bare Number(bigint) loses the low bits
            // past 2^53, which are exactly the ones a narrowing cast keeps.
            if (bits > 32 and src_w <= 32) {
                inner = try allocPrint(self.gpa, "BigInt({s})", .{inner});
            } else if (bits <= 32 and src_w > 32) {
                inner = try allocPrint(self.gpa, "Number(BigInt.asUintN({d},{s}))", .{ bits, inner });
            }
            return try self.wrap(inner, .{ .kind = .int, .bits = bits, .signed = ch.dst_signed });
        }
        // zig_wrap_uN(x, bits) / zig_wrap_iN(x, bits): mask/sign-extend to width.
        // Reuse the same masking wrap() helper used for store-narrowing.
        if (startsWith(u8, name, "zig_wrap_u") or startsWith(u8, name, "zig_wrap_i")) {
            const signed: bool = (name["zig_wrap_".len] == 'i');
            self.expect("(");
            const inner: []const u8 = try self.parseExpr();
            self.expect(",");
            // The width is the SECOND arg, emitted as `UINTxx_C(N)`; parse the
            // transpiled expression (the `_C` wrapper handler unwraps it to `N`)
            // rather than the raw leading token (`UINTxx_C`), which would fail to
            // parse and silently default to 32 — dropping the mask / the
            // sign-extension for any sub-32-bit field (e.g. a packed `i7`).
            const bits_e: []const u8 = try self.parseExpr();
            self.expect(")");
            const bits: u16 = self.bitsArg(bits_e, 32);
            return try self.wrap(inner, .{ .kind = .int, .bits = bits, .signed = signed });
        }
        // literal wrappers: UINTxx_C(x) / INTxx_C(x) -> x
        if (endsWith(u8, name, "_C") and
            (startsWith(u8, name, "UINT") or startsWith(u8, name, "INT")))
        {
            self.expect("(");
            const inner: []const u8 = try self.parseExpr();
            self.expect(")");
            // A 64-bit literal becomes a BigInt literal (full precision past 2^53), so it
            // composes with BigInt 64-bit arithmetic instead of throwing on a mix.
            if (startsWith(u8, name, "UINT64_C") or startsWith(u8, name, "INT64_C")) {
                self.last_w = 64;
                return try self.bigLit(inner);
            }
            return inner;
        }
        // wrapping arithmetic: zig_addw_uN / zig_subw_uN / zig_mulw_uN (and i variants)
        const WrappingOp = enum { add, sub, mul };
        var wrap_op: ?WrappingOp = null;
        var is_signed: bool = false;
        if (startsWith(u8, name, "zig_addw_")) {
            wrap_op = .add;
        }
        if (startsWith(u8, name, "zig_subw_")) {
            wrap_op = .sub;
        }
        if (startsWith(u8, name, "zig_mulw_")) {
            wrap_op = .mul;
        }
        if (wrap_op) |wo| {
            if (indexOf(u8, name, "_i") != null) {
                is_signed = true;
            }
            self.expect("(");
            const a: []const u8 = try self.parseExpr();
            self.expect(",");
            const b: []const u8 = try self.parseExpr();
            self.expect(",");
            const bits_e: []const u8 = try self.parseExpr();
            self.expect(")");
            // parse the bits literal if it's a plain integer; default 32
            const bits: u16 = self.bitsArg(bits_e, 32);
            const ty = CType{ .kind = .int, .bits = bits, .signed = is_signed };
            const inner: []const u8 = switch (wo) {
                .add => try allocPrint(self.gpa, "{s} + {s}", .{ a, b }),
                .sub => try allocPrint(self.gpa, "{s} - {s}", .{ a, b }),
                .mul => if (bits <= 32)
                    try allocPrint(self.gpa, "Math.imul({s}, {s})", .{ a, b })
                else
                    // 64-bit: Math.imul truncates to 32 bits; a Number multiply is
                    // exact within 2^53 (the documented 64-bit working range).
                    try allocPrint(self.gpa, "({s}) * ({s})", .{ a, b }),
            };
            return try self.wrap(inner, ty);
        }
        // float arithmetic: zig_add_f32/f64, zig_sub_*, zig_mul_*, zig_div_*.
        // The C backend routes f32/f64 ops through these for IEEE semantics; in
        // JS all numbers are f64, so plain operators are correct (f32 rounding
        // is the one acknowledged imprecision). Returns are not integer-wrapped.
        {
            const FloatOp = enum { add, sub, mul, div };
            var fop: ?FloatOp = null;
            if (eql(u8, name, "zig_add_f32") or eql(u8, name, "zig_add_f64")) {
                fop = .add;
            }
            if (eql(u8, name, "zig_sub_f32") or eql(u8, name, "zig_sub_f64")) {
                fop = .sub;
            }
            if (eql(u8, name, "zig_mul_f32") or eql(u8, name, "zig_mul_f64")) {
                fop = .mul;
            }
            if (eql(u8, name, "zig_div_f32") or eql(u8, name, "zig_div_f64")) {
                fop = .div;
            }
            // also: zig_neg_f32/f64 (unary), zig_sqrt_*, etc. handled minimally below
            if (fop) |fo| {
                self.expect("(");
                const a: []const u8 = try self.parseExpr();
                self.expect(",");
                const b: []const u8 = try self.parseExpr();
                self.expect(")");
                const sym: []const u8 = switch (fo) {
                    .add => "+",
                    .sub => "-",
                    .mul => "*",
                    .div => "/",
                };
                // f32: round each result to single precision so f32 math matches
                // native bit-for-bit (f64 has the headroom to compute the exact
                // result of one f32 op, then Math.fround rounds it once).
                if (endsWith(u8, name, "_f32")) {
                    return try allocPrint(self.gpa, "Math.fround({s} {s} {s})", .{ a, sym, b });
                }
                return try allocPrint(self.gpa, "({s} {s} {s})", .{ a, sym, b });
            }
        }

        // float comparisons: zig_lt/gt/le/ge/eq/ne_f32/f64. These are libc-style
        // 3-way compares: they return an ORDERING (negative / zero / positive),
        // and the C backend wraps the result in `... < 0` / `> 0` / `== 0` to get
        // the actual boolean. So map them to a 3-way compare expression, NOT to a
        // single boolean operator (doing the latter makes `(a<b) < 0` always false).
        {
            const is_cmp: bool = startsWith(u8, name, "zig_lt_f") or
                startsWith(u8, name, "zig_gt_f") or
                startsWith(u8, name, "zig_le_f") or
                startsWith(u8, name, "zig_ge_f") or
                startsWith(u8, name, "zig_eq_f") or
                startsWith(u8, name, "zig_ne_f") or
                startsWith(u8, name, "zig_cmp_f");
            if (is_cmp) {
                self.expect("(");
                const a: []const u8 = try self.parseExpr();
                self.expect(",");
                const b: []const u8 = try self.parseExpr();
                self.expect(")");
                // The Zig C backend wraps each comparison as `helper(a,b) <op> 0`
                // (lt:`<0`, le:`<=0`, gt:`>0`, ge:`>=0`, eq:`==0`, ne:`!=0`). A single
                // spaceship returns 0 for an unordered (NaN) compare, which is correct
                // only for lt/gt but WRONG for le/ge/eq/ne (`0<=0`, `0>=0`, `0==0` are
                // true; `0!=0` is false) — so `NaN <= x` / `NaN == NaN` came out true
                // and `NaN != NaN` false. Emit a per-operator value that, under that
                // wrap, equals the IEEE result (NaN unordered: all false except !=).
                if (startsWith(u8, name, "zig_lt_f")) {
                    return try allocPrint(self.gpa, "(({s}) < ({s}) ? -1 : 0)", .{ a, b });
                }
                if (startsWith(u8, name, "zig_gt_f")) {
                    return try allocPrint(self.gpa, "(({s}) > ({s}) ? 1 : 0)", .{ a, b });
                }
                if (startsWith(u8, name, "zig_le_f")) {
                    return try allocPrint(self.gpa, "(({s}) <= ({s}) ? -1 : 1)", .{ a, b });
                }
                if (startsWith(u8, name, "zig_ge_f")) {
                    return try allocPrint(self.gpa, "(({s}) >= ({s}) ? 1 : -1)", .{ a, b });
                }
                if (startsWith(u8, name, "zig_eq_f")) {
                    return try allocPrint(self.gpa, "(({s}) === ({s}) ? 0 : 1)", .{ a, b });
                }
                if (startsWith(u8, name, "zig_ne_f")) {
                    return try allocPrint(self.gpa, "(({s}) !== ({s}) ? 1 : 0)", .{ a, b });
                }
                // zig_cmp_f: a total-order spaceship (-1/0/1). NaN -> 0 (the documented
                // "good enough"); used where an ordering is assumed (e.g. sorting).
                return try allocPrint(
                    self.gpa,
                    "(({s}) < ({s}) ? -1 : (({s}) > ({s}) ? 1 : 0))",
                    .{ a, b, a, b },
                );
            }
        }

        // float unary negate: zig_neg_f32/f64(x) -> -(x).
        if (eql(u8, name, "zig_neg_f32") or eql(u8, name, "zig_neg_f64")) {
            self.expect("(");
            const a: []const u8 = try self.parseExpr();
            self.expect(")");
            return try allocPrint(self.gpa, "(-({s}))", .{a});
        }

        // float math intrinsics: zig_<fn>_f32/f64 -> JS Math.*. The C backend
        // lowers @floor/@sqrt/@sin/@exp/... and the floored @mod through these
        // libm shims. JS Numbers are f64, so these map directly (f32 rounding is
        // the one acknowledged imprecision). @mod is floored (sign of divisor),
        // @round is half-away-from-zero, @fmod (zig_fmod) is C truncated mod.
        if (startsWith(u8, name, "zig_") and
            (endsWith(u8, name, "_f32") or endsWith(u8, name, "_f64")))
        {
            const stem: []const u8 = name["zig_".len .. name.len - "_f32".len];
            const MathFn = struct { zig: []const u8, js: []const u8 };
            const math_fns = [_]MathFn{
                .{ .zig = "floor", .js = "Math.floor" }, .{ .zig = "ceil", .js = "Math.ceil" },
                .{ .zig = "trunc", .js = "Math.trunc" }, .{ .zig = "sqrt", .js = "Math.sqrt" },
                .{ .zig = "sin", .js = "Math.sin" },     .{ .zig = "cos", .js = "Math.cos" },
                .{ .zig = "tan", .js = "Math.tan" },     .{ .zig = "asin", .js = "Math.asin" },
                .{ .zig = "acos", .js = "Math.acos" },   .{ .zig = "atan", .js = "Math.atan" },
                .{ .zig = "sinh", .js = "Math.sinh" },   .{ .zig = "cosh", .js = "Math.cosh" },
                .{ .zig = "tanh", .js = "Math.tanh" },   .{ .zig = "exp", .js = "Math.exp" },
                .{ .zig = "log", .js = "Math.log" },     .{ .zig = "log2", .js = "Math.log2" },
                .{ .zig = "log10", .js = "Math.log10" }, .{ .zig = "abs", .js = "Math.abs" },
            };
            for (math_fns) |math_fn| {
                if (eql(u8, stem, math_fn.zig)) {
                    self.expect("(");
                    const a: []const u8 = try self.parseExpr();
                    self.expect(")");
                    // f32 variant: round the result to single precision.
                    if (endsWith(u8, name, "_f32")) {
                        return try allocPrint(self.gpa, "Math.fround({s}({s}))", .{ math_fn.js, a });
                    }
                    return try allocPrint(self.gpa, "{s}({s})", .{ math_fn.js, a });
                }
            }
            if (eql(u8, stem, "round")) { // half away from zero
                self.expect("(");
                const a: []const u8 = try self.parseExpr();
                self.expect(")");
                return try allocPrint(
                    self.gpa,
                    "(Math.sign({s}) * Math.round(Math.abs({s})))",
                    .{ a, a },
                );
            }
            if (eql(u8, stem, "exp2")) { // no Math.exp2
                self.expect("(");
                const a: []const u8 = try self.parseExpr();
                self.expect(")");
                return try allocPrint(self.gpa, "Math.pow(2, {s})", .{a});
            }
            const binary = [_][]const u8{
                "max",
                "min",
                "pow",
                "atan2",
                "hypot",
                "fmod",
                "mod",
                "copysign",
            };
            for (binary) |bs| {
                if (eql(u8, stem, bs)) {
                    self.expect("(");
                    const a: []const u8 = try self.parseExpr();
                    self.expect(",");
                    const b: []const u8 = try self.parseExpr();
                    self.expect(")");
                    if (eql(u8, bs, "max")) {
                        // Zig @max ignores NaN (returns the non-NaN operand), unlike
                        // JS Math.max which yields NaN if either arg is NaN.
                        return try allocPrint(
                            self.gpa,
                            "__fmax({s}, {s})",
                            .{ a, b },
                        );
                    }
                    if (eql(u8, bs, "min")) {
                        return try allocPrint(
                            self.gpa,
                            "__fmin({s}, {s})",
                            .{ a, b },
                        );
                    }
                    if (eql(u8, bs, "pow")) {
                        return try allocPrint(
                            self.gpa,
                            "Math.pow({s}, {s})",
                            .{ a, b },
                        );
                    }
                    if (eql(u8, bs, "atan2")) {
                        return try allocPrint(
                            self.gpa,
                            "Math.atan2({s}, {s})",
                            .{ a, b },
                        );
                    }
                    if (eql(u8, bs, "hypot")) {
                        return try allocPrint(
                            self.gpa,
                            "Math.hypot({s}, {s})",
                            .{ a, b },
                        );
                    }
                    // C truncated mod
                    if (eql(u8, bs, "fmod")) {
                        return try allocPrint(self.gpa, "({s} % {s})", .{ a, b });
                    }
                    if (eql(u8, bs, "copysign")) {
                        return try allocPrint(
                            self.gpa,
                            "(Math.abs({s}) * (({s}) < 0 ? -1 : 1))",
                            .{ a, b },
                        );
                    }
                    // floored mod (sign of divisor): x - floor(x/y)*y
                    return try allocPrint(
                        self.gpa,
                        "({s} - Math.floor({s} / {s}) * {s})",
                        .{ a, a, b, b },
                    );
                }
            }
            // The FLOAT forms were renamed too (zig_div_trunc_f32 ->
            // zig_divTrunc_f32); both spellings accepted, as everywhere else.
            const is_div_trunc: bool = eql(u8, stem, "div_trunc") or eql(u8, stem, "divTrunc");
            const is_div_floor: bool = eql(u8, stem, "div_floor") or eql(u8, stem, "divFloor");
            if (is_div_trunc or is_div_floor) {
                self.expect("(");
                const a: []const u8 = try self.parseExpr();
                self.expect(",");
                const b: []const u8 = try self.parseExpr();
                self.expect(")");
                const f: []const u8 = if (is_div_trunc) "Math.trunc" else "Math.floor";
                return try allocPrint(self.gpa, "{s}({s} / {s})", .{ f, a, b });
            }
            if (eql(u8, stem, "fma")) { // fused multiply-add: x*y+z
                self.expect("(");
                const a: []const u8 = try self.parseExpr();
                self.expect(",");
                const b: []const u8 = try self.parseExpr();
                self.expect(",");
                const c: []const u8 = try self.parseExpr();
                self.expect(")");
                return try allocPrint(self.gpa, "(({s}) * ({s}) + ({s}))", .{ a, b, c });
            }
        }

        // float<->int and float-width conversions (compiler-rt soft-float):
        //   zig_fix...    float -> int   (truncates toward zero; the surrounding
        //                                 code masks to the target int width)
        //   zig_float...  int   -> float (the int is already a JS Number: identity)
        //   zig_extend.../zig_trunc...    f32<->f64 widen/narrow (identity; f32
        //                                 rounding is the acknowledged imprecision)
        // Math intrinsics with a _f32/_f64 suffix were handled above and never
        // reach here, so these prefix matches are unambiguous.
        // 64-bit int conversions are handled earlier (Number()/BigInt() bridge).
        {
            const conv: ?[]const u8 = blk: {
                if (startsWith(u8, name, "zig_fix")) {
                    break :blk "Math.trunc";
                }
                if (startsWith(u8, name, "zig_float")) {
                    break :blk "";
                }
                if (startsWith(u8, name, "zig_extend")) {
                    break :blk "";
                }
                // f64 -> f32 narrowing rounds to single precision (NOT identity).
                if (eql(u8, name, "zig_truncdfsf")) {
                    break :blk "Math.fround";
                }
                if (startsWith(u8, name, "zig_trunc")) {
                    break :blk "";
                }
                break :blk null;
            };
            if (conv) |jsfn| {
                self.expect("(");
                const a: []const u8 = try self.parseExpr();
                self.expect(")");
                if (jsfn.len == 0) {
                    return try allocPrint(self.gpa, "({s})", .{a});
                }
                return try allocPrint(self.gpa, "{s}({s})", .{ jsfn, a });
            }
        }

        // wrapping shift-left: zig_shlw_<ty>(x, n, bits) -> (x << n) masked to ty.
        if (startsWith(u8, name, "zig_shlw_")) {
            self.expect("(");
            const x: []const u8 = try self.parseExpr();
            self.expect(",");
            const n: []const u8 = try self.parseExpr();
            self.expect(",");
            const bits_e: []const u8 = try self.parseExpr();
            self.expect(")");
            const signed: bool = indexOf(u8, name, "_i") != null;
            const bits: u16 = self.bitsArg(bits_e, 32);
            const ty = CType{ .kind = .int, .bits = bits, .signed = signed };
            // 64-bit: JS `<<` truncates to 32 bits; `x * 2^n` is exact within 2^53.
            const inner: []const u8 = if (bits <= 32)
                try allocPrint(self.gpa, "{s} << {s}", .{ x, n })
            else
                try allocPrint(self.gpa, "({s}) * Math.pow(2, {s})", .{ x, n });
            return try self.wrap(inner, ty);
        }
        // logical/arith shift-right: zig_shr_<ty>(x, n). Unsigned -> >>>, signed -> >>.
        if (startsWith(u8, name, "zig_shr_")) {
            self.expect("(");
            const x: []const u8 = try self.parseExpr();
            self.expect(",");
            const n: []const u8 = try self.parseExpr();
            self.expect(")");
            const signed: bool = indexOf(u8, name, "_i") != null;
            // 64-bit: JS shifts truncate to 32 bits; floor(x / 2^n) matches both
            // logical (unsigned) and arithmetic (signed) shr within 2^53.
            if (endsWith(u8, name, "64")) {
                return try allocPrint(self.gpa, "Math.floor(({s}) / Math.pow(2, {s}))", .{ x, n });
            }
            const sym: []const u8 = if (signed) ">>" else ">>>";
            return try allocPrint(self.gpa, "(({s}) {s} ({s}))", .{ x, sym, n });
        }

        // integer division / modulo helpers. The C backend distinguishes Zig's
        // FLOORED div/mod (sign follows the divisor) from C-style TRUNCATED
        // div/rem. JS `/` is float and JS `%` is truncated, so:
        //   floored mod  -> ((a % b) + b) % b      (result takes b's sign)
        //   floored div  -> Math.floor(a / b)
        //   trunc div    -> Math.trunc(a / b)
        //   rem (trunc)  -> a % b
        //   unsigned     -> plain % and Math.trunc(/) (operands are non-negative)
        // The result is then masked to the operand width via `wrap`.
        //
        // BOTH SPELLINGS, for the reason given at the bit-builtin table below:
        // 1857 renamed div_floor -> divFloor and div_trunc -> divTrunc, and c2js
        // transpiles C from whichever toolchain produced it. `mod` and `rem` were
        // not renamed.
        {
            const DivOp = enum { mod_floor, div_floor, div_trunc, rem };
            var dop: ?DivOp = null;
            if (startsWith(u8, name, "zig_mod_")) {
                dop = .mod_floor;
            }
            if (startsWith(u8, name, "zig_divFloor_") or startsWith(u8, name, "zig_div_floor_")) {
                dop = .div_floor;
            }
            if (startsWith(u8, name, "zig_divTrunc_") or startsWith(u8, name, "zig_div_trunc_")) {
                dop = .div_trunc;
            }
            if (startsWith(u8, name, "zig_rem_")) {
                dop = .rem;
            }
            if (dop) |op| {
                self.expect("(");
                const a: []const u8 = try self.parseExpr();
                self.expect(",");
                const b: []const u8 = try self.parseExpr();
                self.expect(")");
                const signed: bool = indexOf(u8, name, "_i") != null;
                // width: trailing digits of the type suffix (e.g. ..._i32 -> 32)
                var bits: u16 = 32;
                {
                    var k: usize = name.len;
                    while (k > 0 and name[k - 1] >= '0' and name[k - 1] <= '9') {
                        k -= 1;
                    }
                    if (k < name.len) {
                        bits = parseInt(u16, name[k..], 10) catch 32;
                    }
                }
                const ty = CType{ .kind = .int, .bits = bits, .signed = signed };
                const expr: []const u8 = switch (op) {
                    .mod_floor => if (signed)
                        try allocPrint(
                            self.gpa,
                            "((({s}) % ({s})) + ({s})) % ({s})",
                            .{ a, b, b, b },
                        )
                    else
                        try allocPrint(self.gpa, "({s}) % ({s})", .{ a, b }),
                    .div_floor => if (bits > 32)
                        (if (signed)
                            // BigInt has no floor-division: `/` truncates toward
                            // zero, so adjust down by one when the signs differ and
                            // the division leaves a remainder.
                            try allocPrint(
                                self.gpa,
                                "(({s}) / ({s}) - ((({s}) % ({s})) !== 0n && " ++
                                    "((({s}) < 0n) !== (({s}) < 0n)) ? 1n : 0n))",
                                .{ a, b, a, b, a, b },
                            )
                        else
                            // unsigned: operands are non-negative, so trunc == floor.
                            try allocPrint(self.gpa, "(({s}) / ({s}))", .{ a, b }))
                    else
                        (if (signed)
                            try allocPrint(self.gpa, "Math.floor(({s}) / ({s}))", .{ a, b })
                        else
                            try allocPrint(self.gpa, "Math.trunc(({s}) / ({s}))", .{ a, b })),
                    .div_trunc => if (bits > 32)
                        // BigInt `/` already truncates toward zero.
                        try allocPrint(self.gpa, "(({s}) / ({s}))", .{ a, b })
                    else
                        try allocPrint(self.gpa, "Math.trunc(({s}) / ({s}))", .{ a, b }),
                    .rem => try allocPrint(self.gpa, "({s}) % ({s})", .{ a, b }),
                };
                return try self.wrap(expr, ty);
            }
        }

        // sizeof(TYPE): the backend emits this for packed-struct zero-init
        // (`memset(&t0, 0, sizeof(bitpack__T))`). Resolve to the type's byte size.
        if (eql(u8, name, "sizeof")) {
            self.expect("(");
            var sz: u32 = 1;
            while (!self.atText(")") and self.current().kind != .eof) {
                const tnm: []const u8 = self.current().text;
                if (self.bitpack_sizes.get(tnm)) |z| {
                    sz = z;
                } else if (self.structs.get(tnm)) |layout| {
                    sz = @intCast(layout.size);
                } else if (primSizeOf(tnm)) |z| {
                    sz = z;
                }
                self.p += 1;
            }
            self.expect(")");
            return try allocPrint(self.gpa, "{d}", .{sz});
        }

        // offsetof(struct TAG, FIELD) : the C stddef macro, emitted by the backend
        // for `@fieldParentPtr` (parent = field_ptr - offsetof(Parent, field)).
        // Resolve to the field's byte offset in OUR layout; the subtraction then
        // lands on the parent struct's base offset. Tolerates the struct/union
        // keyword and a struct-typedef alias for the tag.
        if (eql(u8, name, "offsetof")) {
            self.expect("(");
            if (self.atText("struct") or self.atText("union")) {
                self.p += 1;
            }
            const tag_raw: []const u8 = self.current().text;
            self.p += 1;
            const tag: []const u8 = self.struct_aliases.get(tag_raw) orelse tag_raw;
            self.expect(",");
            const field: []const u8 = self.current().text;
            self.p += 1;
            self.expect(")");
            const off: u32 = self.fieldOffsetOf(tag, field) orelse 0;
            return try allocPrint(self.gpa, "{d}", .{off});
        }

        // bitwise and/or/xor helpers: zig_and/or/xor_TN(a, b). The backend emits
        // these (rather than bare operators) for e.g. packed-struct field reads.
        // For <=32-bit, JS &|^ are exact. For 64-bit, JS bitwise truncates to 32
        // bits, so split into hi/lo halves (correct within 2^53). (Bare-operator
        // 64-bit bitwise stays a type-light gap — see EXPRESSIONS — but these
        // width-carrying helper forms we can do right.)
        {
            const BitwiseOp = enum { band, bor, bxor };
            var bitwise_op: ?BitwiseOp = null;
            if (startsWith(u8, name, "zig_and_")) {
                bitwise_op = .band;
            }
            if (startsWith(u8, name, "zig_or_")) {
                bitwise_op = .bor;
            }
            if (startsWith(u8, name, "zig_xor_")) {
                bitwise_op = .bxor;
            }
            if (bitwise_op) |op| {
                self.expect("(");
                const lhs: []const u8 = try self.parseExpr();
                self.expect(",");
                const rhs: []const u8 = try self.parseExpr();
                self.expect(")");
                if (endsWith(u8, name, "64")) {
                    const helper64: []const u8 = switch (op) {
                        .band => "__band64",
                        .bor => "__bor64",
                        .bxor => "__bxor64",
                    };
                    return try allocPrint(self.gpa, "{s}({s}, {s})", .{ helper64, lhs, rhs });
                }
                const js_op: []const u8 = switch (op) {
                    .band => "&",
                    .bor => "|",
                    .bxor => "^",
                };
                return try allocPrint(self.gpa, "(({s}) {s} ({s}))", .{ lhs, js_op, rhs });
            }
        }

        // ---- @abs, bit builtins, saturating + overflow arithmetic ----
        // These zig.h helpers are lowered here; emitted verbatim they would be
        // undefined at runtime ("X is not defined"). The float-suffixed math
        // intrinsics are handled above, so only the integer-suffixed forms reach here.
        // The result is assigned to a typed temp, so it gets store-wrapped to its width.
        const SuffixWidth = struct {
            // width N from a trailing _u<N> / _i<N> suffix (8/16/32/64)
            fn parse(helper_name: []const u8) ?u16 {
                var j: usize = helper_name.len;
                while (j > 0 and helper_name[j - 1] >= '0' and helper_name[j - 1] <= '9') {
                    j -= 1;
                }
                if (j == helper_name.len or j == 0) {
                    return null;
                }
                const c: u8 = helper_name[j - 1];
                if (c != 'u' and c != 'i') {
                    return null;
                }
                return parseInt(u16, helper_name[j..], 10) catch null;
            }
        };

        // @abs(integer): zig_abs_iN/uN(x) -> Math.abs(x) for <=32-bit; for 64-bit
        // the operand is a BigInt, which Math.abs rejects, so branch on sign.
        if (startsWith(u8, name, "zig_abs_")) {
            const width: u16 = SuffixWidth.parse(name) orelse 32;
            self.expect("(");
            const a: []const u8 = try self.parseExpr();
            self.expect(")");
            if (width > 32) {
                return try allocPrint(self.gpa, "(({s}) < 0n ? -({s}) : ({s}))", .{ a, a, a });
            }
            return try allocPrint(self.gpa, "Math.abs({s})", .{a});
        }

        // ~x: zig_not_uN(x, bits) / zig_not_iN(x, bits), for N of 8/16/32. The
        // 1857 compiler routes every integer `~` through these instead of
        // emitting the C operator, so before this handler a narrow bitwise NOT
        // reached the unhandled-helper marker and lowered to 0 — which took MD5
        // and math.rotl with it. (The _u64/_i64/_u128/_i128 spellings never get
        // here: isWideArith intercepts them for the BigInt path above.)
        //
        // zig.h spells these `arg ^ maxInt_u(N, bits)` (unsigned) and `~arg`
        // (signed, bits unused) — both are `~x` narrowed to the DECLARED width,
        // which is exactly what wrap() does: `>>> 0` at u32, `& mask` below it,
        // and a shift pair to sign-extend the signed forms.
        //
        // The `bits` ARG is the real width; the name suffix is only the C STORAGE
        // type, and they differ constantly. math.rotl emits
        // `zig_not_u8(t1, UINT8_C(5))` for a 5-bit shift amount, where trusting
        // the u8 suffix would mask with 255 and hand every downstream shift a
        // value eight times too large. So read bitsArg, never SuffixWidth.
        if (startsWith(u8, name, "zig_not_u") or startsWith(u8, name, "zig_not_i")) {
            const signed: bool = (name["zig_not_".len] == 'i');
            self.expect("(");
            const a: []const u8 = try self.parseExpr();
            var bits: u16 = SuffixWidth.parse(name) orelse 32;
            if (self.atText(",")) {
                self.p += 1;
                const bits_e: []const u8 = try self.parseExpr();
                bits = self.bitsArg(bits_e, bits);
            }
            self.expect(")");
            const negated: []const u8 = try allocPrint(self.gpa, "(~({s}))", .{a});
            return try self.wrap(negated, .{ .kind = .int, .bits = bits, .signed = signed });
        }

        // single-arg bit builtins -> width-aware kernel helpers.
        //
        // BOTH SPELLINGS ARE LIVE. Compiler 1857 renamed three of these five in
        // zig.h to camelCase — popcount -> popCount, byte_swap -> byteSwap,
        // bit_reverse -> bitReverse — while clz and ctz kept their snake form.
        // c2js consumes C, not a compiler, so a C file emitted by either
        // toolchain must transpile; the old prefixes stay. A missing spelling is
        // NOT a compile error here, it is a silent lowering to 0, so this table
        // is only ever appended to. `tools/c2js_cases/cases/builtins.zig` is what
        // catches the next rename.
        const BitBuiltin = struct { prefix: []const u8, helper: []const u8 };
        for ([_]BitBuiltin{
            .{ .prefix = "zig_clz_", .helper = "__clz" },
            .{ .prefix = "zig_ctz_", .helper = "__ctz" },
            .{ .prefix = "zig_popCount_", .helper = "__popcount" },
            .{ .prefix = "zig_popcount_", .helper = "__popcount" },
            .{ .prefix = "zig_byteSwap_", .helper = "__byteswap" },
            .{ .prefix = "zig_byte_swap_", .helper = "__byteswap" },
            .{ .prefix = "zig_bitReverse_", .helper = "__bitreverse" },
            .{ .prefix = "zig_bit_reverse_", .helper = "__bitreverse" },
        }) |entry| {
            if (startsWith(u8, name, entry.prefix)) {
                self.expect("(");
                const a: []const u8 = try self.parseExpr();
                // The ACTUAL type width is the SECOND C arg (e.g. zig_clz_u64(x, 48)
                // for a u48 — the `u64` suffix is just the storage type). @clz, @ctz's
                // zero case, @byteSwap and @bitReverse all depend on the real width, so
                // a u40/u48 computed leading zeros / swapped bytes over 64 bits.
                // Prefer the second arg; fall back to the name suffix when absent.
                var width: u16 = SuffixWidth.parse(name) orelse 32;
                if (self.atText(",")) {
                    self.p += 1;
                    const w_e: []const u8 = try self.parseExpr();
                    width = parseInt(u16, trim(u8, w_e, "() "), 10) catch width;
                }
                self.expect(")");
                return try allocPrint(self.gpa, "{s}({s}, {d})", .{ entry.helper, a, width });
            }
        }

        // saturating arithmetic: zig_adds/subs/muls_TN(a, b, bits) -> clamp(a OP b).
        {
            const SaturateOp = enum { add, sub, mul };
            var sat_op: ?SaturateOp = null;
            if (startsWith(u8, name, "zig_adds_")) {
                sat_op = .add;
            }
            if (startsWith(u8, name, "zig_subs_")) {
                sat_op = .sub;
            }
            if (startsWith(u8, name, "zig_muls_")) {
                sat_op = .mul;
            }
            if (sat_op) |kind| {
                const signed: bool = indexOf(u8, name, "_i") != null;
                self.expect("(");
                const a: []const u8 = try self.parseExpr();
                self.expect(",");
                const b: []const u8 = try self.parseExpr();
                self.expect(",");
                const bits_e: []const u8 = try self.parseExpr();
                self.expect(")");
                const wn: u16 = self.bitsArg(bits_e, 32);
                const op: []const u8 = switch (kind) {
                    .add => "+",
                    .sub => "-",
                    .mul => "*",
                };
                const clamp_fn: []const u8 = if (signed) "__clampi" else "__clampu";
                return try allocPrint(self.gpa, "{s}(({s}) {s} ({s}), {d})", .{ clamp_fn, a, op, b, wn });
            }
        }

        // saturating left shift: zig_shls_TN(a, b, bits) -> clamp(a << b). Since
        // `a << b` == `a * 2^b` mathematically, this is clamp(a * 2^b) to the
        // N-bit range — the same clamp the saturating add/sub/mul use. The float
        // product is exact below 2^53 (the no-overflow case for <=32-bit types)
        // and far above the range otherwise, so the saturation decision is
        // reliable. Without this, `<<|` hit the unhandled-helper marker and
        // returned 0.
        if (startsWith(u8, name, "zig_shls_")) {
            const signed: bool = indexOf(u8, name, "_i") != null;
            self.expect("(");
            const a: []const u8 = try self.parseExpr();
            self.expect(",");
            const b: []const u8 = try self.parseExpr();
            self.expect(",");
            const bits_e: []const u8 = try self.parseExpr();
            self.expect(")");
            const wn: u16 = self.bitsArg(bits_e, 32);
            const cf: []const u8 = if (signed) "__clampi" else "__clampu";
            // 64-bit operands are BigInt: `a * Math.pow(2, b)` would mix BigInt and
            // Number, so shift in BigInt (exact, arbitrary precision) before clamping.
            if (wn > 32) {
                return try allocPrint(self.gpa, "{s}(({s}) << BigInt({s}), {d})", .{ cf, a, b, wn });
            }
            return try allocPrint(self.gpa, "{s}(({s}) * Math.pow(2, ({s})), {d})", .{ cf, a, b, wn });
        }

        // shift-with-overflow: T.f1 = zig_shlo_TN(&dst, a, b, bits). Like the
        // add/sub/mul overflow ops below: stores the wrapped (a << b) through dst
        // and returns whether any 1-bits were shifted out past the width. Without
        // this, `@shlWithOverflow` hit the unhandled-helper marker.
        if (startsWith(u8, name, "zig_shlo_")) {
            const save: usize = self.p;
            self.expect("(");
            if (self.consume("&")) {
                if (try self.parseLValueAddr()) |dst| {
                    self.expect(",");
                    const a: []const u8 = try self.parseExpr();
                    self.expect(",");
                    const b: []const u8 = try self.parseExpr();
                    self.expect(",");
                    const bits_e: []const u8 = try self.parseExpr();
                    self.expect(")");
                    const wn: u16 = self.bitsArg(bits_e, 32);
                    const signed: bool = indexOf(u8, name, "_i") != null;
                    if (wn > 32) {
                        // BigInt: exact shift; mask the stored result to the width
                        // (a 33-63 bit field is stored via __st64 with no implicit
                        // truncation), and any bit at or above the width => overflow.
                        const wrapped: []const u8 = try allocPrint(self.gpa, "(({s}) << BigInt({s}))", .{ a, b });
                        const wrapped_to_width: []const u8 = try self.wrap(
                            wrapped,
                            .{ .kind = .int, .bits = wn, .signed = signed },
                        );
                        const store: []const u8 = try self.heapStore(dst.elem, dst.addr, wrapped_to_width);
                        const ovf: []const u8 = if (signed)
                            try allocPrint(
                                self.gpa,
                                "((({s}) << BigInt({s})) < -(1n << BigInt({d})) || " ++
                                    "(({s}) << BigInt({s})) >= (1n << BigInt({d}))) ? 1 : 0",
                                .{ a, b, wn - 1, a, b, wn - 1 },
                            )
                        else
                            try allocPrint(
                                self.gpa,
                                "(((({s}) << BigInt({s})) >> BigInt({d})) !== 0n) ? 1 : 0",
                                .{ a, b, wn },
                            );
                        return try allocPrint(self.gpa, "({s}, {s})", .{ store, ovf });
                    }
                    // <=32-bit (Number): `a << b` is an exact 32-bit shift for the
                    // stored low bits; the overflow test compares the full magnitude.
                    const wrapped: []const u8 = try allocPrint(self.gpa, "(({s}) << ({s}))", .{ a, b });
                    const store: []const u8 = try self.heapStore(dst.elem, dst.addr, wrapped);
                    const real: []const u8 = try allocPrint(self.gpa, "(({s}) * Math.pow(2, ({s})))", .{ a, b });
                    const ovf: []const u8 = if (signed)
                        try allocPrint(
                            self.gpa,
                            "(({s}) < -Math.pow(2, {d}) || ({s}) >= Math.pow(2, {d})) ? 1 : 0",
                            .{ real, wn - 1, real, wn - 1 },
                        )
                    else
                        try allocPrint(
                            self.gpa,
                            "(({s}) < 0 || ({s}) >= Math.pow(2, {d})) ? 1 : 0",
                            .{ real, real, wn },
                        );
                    return try allocPrint(self.gpa, "({s}, {s})", .{ store, ovf });
                }
            }
            self.p = save; // couldn't model the destination; fall through to the marker
        }

        // overflow arithmetic: T.f1 = zig_addo/subo/mulo_TN(&dst, a, b, bits).
        // Stores the wrapped result through the dest pointer (a heap address in
        // our model; the typed-view store truncates to the field width) and
        // returns the overflow bit, as a comma expression `(store, overflowed)`.
        {
            const OverflowOp = enum { add, sub, mul };
            var ovf_op: ?OverflowOp = null;
            if (startsWith(u8, name, "zig_addo_")) {
                ovf_op = .add;
            }
            if (startsWith(u8, name, "zig_subo_")) {
                ovf_op = .sub;
            }
            if (startsWith(u8, name, "zig_mulo_")) {
                ovf_op = .mul;
            }
            if (ovf_op) |kind| {
                const save: usize = self.p;
                self.expect("(");
                if (self.consume("&")) {
                    if (try self.parseLValueAddr()) |dst| {
                        self.expect(",");
                        const a: []const u8 = try self.parseExpr();
                        self.expect(",");
                        const b: []const u8 = try self.parseExpr();
                        self.expect(",");
                        const bits_e: []const u8 = try self.parseExpr();
                        self.expect(")");
                        const wn: u16 = self.bitsArg(bits_e, 32);
                        const signed: bool = indexOf(u8, name, "_i") != null;
                        const op: []const u8 = switch (kind) {
                            .add => "+",
                            .sub => "-",
                            .mul => "*",
                        };
                        // The real-number result, used for the overflow TEST. A
                        // plain operator is exact for add/sub of <=32-bit values
                        // (< 2^53), and for a multiply it preserves the product's
                        // MAGNITUDE, so the `>= 2^wn` comparison is reliable even
                        // when the low bits are lost.
                        const real: []const u8 = try allocPrint(self.gpa, "(({s}) {s} ({s}))", .{ a, op, b });
                        // The stored (wrapped) result. A 32-bit multiply's low
                        // bits are lost by a float multiply once the product
                        // exceeds 2^53, so use Math.imul (exact mod 2^32; the
                        // typed-view store then truncates to the field width).
                        // Math.imul truncates to 32 bits, so it is NOT used for a
                        // 64-bit multiply — that stays a Number multiply, bounded
                        // by the 2^53 int64 ABI like the rest of 64-bit math.
                        const wrapped: []const u8 = if (kind == .mul and wn <= 32)
                            try allocPrint(self.gpa, "Math.imul({s}, {s})", .{ a, b })
                        else
                            real;
                        // Mask/sign-extend the stored result to the REAL width. A
                        // <=32-bit field is truncated by its typed view, but a 33-63
                        // bit field is stored through __st64 (64-bit) with NO implicit
                        // truncation, so an unwrapped sum/product (e.g. u40 max + 1 =
                        // 2^40) would persist past the width. wrap() masks via
                        // asUintN/asIntN(wn) for the BigInt domain (no-op for <=32).
                        const wrapped_to_width: []const u8 = try self.wrap(
                            wrapped,
                            .{ .kind = .int, .bits = wn, .signed = signed },
                        );
                        const store: []const u8 = try self.heapStore(dst.elem, dst.addr, wrapped_to_width);
                        const ovf: []const u8 = if (signed)
                            try allocPrint(
                                self.gpa,
                                "(({s}) < -Math.pow(2, {d}) || ({s}) >= Math.pow(2, {d})) ? 1 : 0",
                                .{ real, wn - 1, real, wn - 1 },
                            )
                        else
                            try allocPrint(
                                self.gpa,
                                "(({s}) < 0 || ({s}) >= Math.pow(2, {d})) ? 1 : 0",
                                .{ real, real, wn },
                            );
                        return try allocPrint(self.gpa, "({s}, {s})", .{ store, ovf });
                    }
                }
                self.p = save; // couldn't model the destination; fall to the marker
            }
        }

        // Safety net: any OTHER zig.h runtime helper we don't model. Emitting it
        // verbatim would call an undefined function and throw at runtime with no
        // warning; instead consume the call and leave a visible marker (same
        // philosophy as the recursion marker — make the gap loud, not silent).
        if (startsWith(u8, name, "zig_") and self.atText("(")) {
            const close: usize = self.matching(self.p, "(", ")");
            self.p = close + 1;
            return try allocPrint(self.gpa, "/*?unhandled-helper:{s}*/ 0", .{name});
        }

        return null;
    }

    // Bottom of the expression ladder: parenthesized exprs, casts and compound
    // literals `(struct T){...}`, pointer-cast arithmetic `(T*)base + n`,
    // identifiers (resolved via #defines + symbol tables), numbers, strings, and
    // builtin/helper calls. Everything above eventually bottoms out here.
    fn parsePrimary(self: *Transpiler) error{OutOfMemory}![]const u8 {
        self.last_w = 0; // default: Number; overridden below for known-width leaves
        const t: Token = self.current();
        if (self.atText("(")) {
            // cast?  ( <type> ) operand  -> identity (pointers/offsets are ints)
            const nx: Token = self.lookahead(1);
            if (nx.kind == .ident and (isTypeQualifierOrSpecifier(nx.text) or
                self.type_aliases.contains(nx.text) or
                self.struct_aliases.contains(nx.text)))
            {
                const close: usize = self.matching(self.p, "(", ")");
                // compound literal: ( struct Tag ) { f0, f1, ... }
                if (close + 1 < self.toks.len and eql(u8, self.toks[close + 1].text, "{")) {
                    // structTypeNameOf (not structTagOf) so a primitive-array
                    // wrapper like `(arr_4_i32){{1,2,3,4}}` — a local array's
                    // initializer — is materialized in scratch rather than
                    // discarded; parseCompoundLiteral lays out its element bytes.
                    const tag: ?[]const u8 = structTypeNameOf(self.toks[self.p + 1 .. close]);
                    self.p = close + 1; // move to '{'
                    if (tag) |tg| {
                        if (self.structs.get(tg)) |layout| {
                            const r: []const u8 = try self.parseCompoundLiteral(layout);
                            self.pending_struct_tag = tg; // for a following `.array[i]`
                            return r;
                        }
                    }
                    // unknown struct: skip the brace body, yield 0
                    const ce: usize = self.matching(self.p, "{", "}");
                    self.p = ce + 1;
                    return self.gpa.dupe(u8, "0");
                }
                // Pointer cast in value context: `(T*)<base> + <n>` is C pointer
                // arithmetic — the offset scales by the pointee size. (A plain
                // identity cast with no trailing +/- falls through unchanged.)
                var cast_ty: CType = tyFromSpecifiers(self.toks[self.p + 1 .. close]);
                // A type-alias base (enum tag typedef): when the specs are a
                // pointer cast `(enum__... *)`, override the pointee with the
                // alias's real width so pointer arithmetic strides correctly.
                if (cast_ty.kind == .ptr) {
                    for (self.toks[self.p + 1 .. close]) |sp| {
                        if (self.type_aliases.get(sp.text)) |ty| {
                            cast_ty.elem = .{ .bits = ty.bits, .signed = ty.signed, .float = ty.kind == .float };
                        }
                    }
                }
                self.p = close + 1; // skip the whole ( ...type... )
                const looks_value: bool = self.atText("(") or self.atText("&") or
                    self.current().kind == .ident or self.current().kind == .number;
                if (cast_ty.kind == .ptr and cast_ty.elem != null and looks_value) {
                    const base: []const u8 = try self.parseUnary();
                    const pe: Elem = cast_ty.elem.?;
                    if (self.atText("+") or self.atText("-")) {
                        const neg: bool = self.atText("-");
                        self.p += 1;
                        const idx: []const u8 = try self.parseBinary(0);
                        const stride: usize = blk: {
                            if (pe.struct_tag) |st| {
                                if (self.structs.get(st)) |sl| {
                                    break :blk sl.size;
                                }
                            }
                            break :blk elemSize(pe);
                        };
                        const sign: []const u8 = if (neg) "-" else "+";
                        // result is a pointer to the pointee; if that's a struct,
                        // record its tag so a following `->field` / `->array[i]`
                        // resolves against it.
                        if (pe.struct_tag) |st| {
                            self.pending_struct_tag = st;
                        }
                        return allocPrint(
                            self.gpa,
                            "(({s}) {s} ({s}) * {d})",
                            .{ base, sign, idx, stride },
                        );
                    }
                    // bare pointer-to-struct cast (`(arr_N_T*)<ptr>`): record the
                    // pointee tag so `<that>->array[i]` (an in-place slice over a
                    // local array) indexes the heap instead of hitting `.array`
                    // on a number. A SCALAR pointee instead records its element for a
                    // following `[i]` (see below). The two are mutually exclusive:
                    // an OUTER cast must clear the INNER cast's pending field, else a
                    // `(ELEM*)((wrapper*)&g)[i]` strides by the wrapper struct size
                    // (the inner tag) instead of the element size.
                    if (pe.struct_tag) |st| {
                        self.pending_struct_tag = st;
                        self.pending_ptr_elem = null;
                    } else {
                        // `(ELEM*)base [idx]` for a SCALAR pointee is `*(p + idx)`, a
                        // heap load — not a JS subscript (the generic postfix `[idx]`
                        // handler would emit `(base)[idx]` on a heap offset ->
                        // `undefined` -> 0). The Zig C backend emits this when it folds
                        // a slice/`[*:0]` pointer to a known base (e.g. a sentinel
                        // slice's `s.ptr[i]` -> `((u32*)&arr)[i]`), usually wrapped in
                        // parens, so the `[idx]` lands at postfix level — record the
                        // pointee element and let parsePostfix turn the subscript into
                        // a heap load (and the `&`-handler into an element address).
                        self.pending_ptr_elem = pe;
                        self.pending_struct_tag = null;
                    }
                    return base;
                }
                // Scalar (non-pointer) cast. Convert at a BigInt<->Number boundary using
                // the operand's tracked width (last_w >= 64 => BigInt). Same-domain casts
                // stay identity (the assignment-wrap masks Number widths as before).
                const cx: []const u8 = try self.parseUnary();
                const ow: u16 = self.last_w;
                const cm: []const u8 = if (cast_ty.signed) "asIntN" else "asUintN";
                if (cast_ty.kind == .int and (cast_ty.bits == 64 or cast_ty.bits == 128)) {
                    self.last_w = cast_ty.bits;
                    // widen a Number to a wide BigInt, or reinterpret a BigInt's sign/width
                    if (ow >= 64) {
                        return allocPrint(self.gpa, "BigInt.{s}({d},{s})", .{ cm, cast_ty.bits, cx });
                    }
                    return allocPrint(self.gpa, "BigInt.{s}({d},BigInt({s}))", .{ cm, cast_ty.bits, cx });
                }
                if (cast_ty.kind == .int and cast_ty.bits != 0 and cast_ty.bits < 64 and ow >= 64) {
                    // narrow a BigInt to a Number of the target width
                    self.last_w = cast_ty.bits;
                    return allocPrint(self.gpa, "Number(BigInt.{s}({d},{s}))", .{ cm, cast_ty.bits, cx });
                }
                if (cast_ty.kind == .float and ow >= 64) {
                    // BigInt -> floating Number
                    self.last_w = cast_ty.bits;
                    return allocPrint(self.gpa, "Number({s})", .{cx});
                }
                // same domain: keep the operand; remember its (Number) width
                self.last_w = if (cast_ty.bits != 0) cast_ty.bits else ow;
                return cx;
            }
            // non-cast parenthesized expression: ( expr )
            self.p += 1;
            const e: []const u8 = try self.parseExpr();
            self.expect(")");
            return allocPrint(self.gpa, "({s})", .{e});
        }
        if (t.kind == .number) {
            self.p += 1;
            self.last_w = 32; // numeric literals are Numbers (64-bit literals arrive as UINT64_C)
            return self.emitNumber(t.text);
        }
        if (t.kind == .ident) {
            self.p += 1;
            // function-like builtin?
            if (self.atText("(")) {
                if (try self.tryBuiltinCall(t.text)) |built| {
                    return built;
                }
            }
            // address-taken scalar local: a read is a heap load from its slot.
            if (self.scalar_slots.get(t.text)) |off| {
                const ty: CType = if (self.vars.get(t.text)) |v| v.ty else .{ .kind = .int, .bits = 32 };
                const e: Elem = .{
                    .bits = if (ty.bits == 0) 32 else ty.bits,
                    .signed = ty.signed,
                    .float = ty.kind == .float,
                };
                self.last_w = if (!e.float and (e.bits == 64 or e.bits == 128)) e.bits else 0;
                return self.heapLoad(e, try self.scratchBase(t.text, off));
            }
            // type-limit macro used in an expression (e.g. `x = UINT32_MAX`): emit
            // its value. (parseScalarInit handles the same names in global inits.)
            if (limitMacroValue(t.text)) |v| {
                // 64-bit limits are BigInts (a Number would lose precision past 2^53).
                if (eql(u8, t.text, "UINT64_MAX") or eql(u8, t.text, "INT64_MAX")) {
                    self.last_w = 64;
                    return allocPrint(self.gpa, "{d}n", .{v});
                }
                if (eql(u8, t.text, "INT64_MIN")) {
                    self.last_w = 64;
                    return self.gpa.dupe(u8, "(-9223372036854775808n)");
                }
                // limitMacroValue stores the MIN macros as their two's-complement
                // u64 because its other caller is the data-image writer, which
                // truncates to the slot width. An EXPRESSION has no slot to
                // truncate against, so printing that u64 verbatim made INT8_MIN
                // read as 18446744073709551488 — and `x != INT8_MIN` is then
                // ALWAYS true. Silent: no marker, no error, just a comparison
                // that can never hold. Emit the signed value here.
                if (endsWith(u8, t.text, "_MIN")) {
                    const signed_v: i64 = @bitCast(v);
                    return allocPrint(self.gpa, "({d})", .{signed_v});
                }
                return allocPrint(self.gpa, "{d}", .{v});
            }
            // static data referenced directly -> its heap offset
            if (self.globals.get(t.text)) |off| {
                return self.scratchBase(t.text, off);
            }
            // a plain variable: a 64/128-bit INTEGER is a BigInt (an f64 is a Number)
            self.last_w = if (self.vars.get(t.text)) |v|
                (if (v.ty.kind == .int and (v.ty.bits == 64 or v.ty.bits == 128)) v.ty.bits else 0)
            else
                0;
            return self.gpa.dupe(u8, self.applyDefine(t.text));
        }
        // unknown — consume and emit a marker so we can see it in output
        self.p += 1;
        return allocPrint(self.gpa, "/*?{s}*/ 0", .{t.text});
    }
};

// ----------------------------------------------------------------------------
// I/O (use std.posix to avoid the new std.Io abstraction churn)
// ----------------------------------------------------------------------------

fn readAllStdin(gpa: Allocator, io: std.Io) ![]u8 {
    var list: ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    const in: File = File.stdin();
    while (true) {
        var iov = [_][]u8{&buf};
        const n: usize = in.readStreaming(io, &iov) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) {
            break;
        }
        try list.appendSlice(gpa, buf[0..n]);
    }
    return list.toOwnedSlice(gpa);
}

// Write all bytes to stdout (cross-platform via std.Io) — the plain-filter output.
fn writeAllStdout(io: std.Io, bytes: []const u8) !void {
    try File.stdout().writeStreamingAll(io, bytes);
}

// Write all bytes to stderr (usage / errors — keeps stdout a clean JS stream).
fn writeAllStderr(io: std.Io, bytes: []const u8) !void {
    try File.stderr().writeStreamingAll(io, bytes);
}

/// Write `bytes` to `path` (create/truncate). Cross-platform via Dir,
/// so the same native pipeline builds on Linux and Windows.
fn writeFile(
    io: std.Io,
    path: []const u8,
    bytes: []const u8,
) !void {
    const file: File = try Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

/// Read a whole file into memory (used by `--wasm-embed` to inline a .wasm).
fn readFileAlloc(io: std.Io, gpa: Allocator, path: []const u8) ![]u8 {
    const file: File = try Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var list: ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        var iov = [_][]u8{&buf};
        const n: usize = file.readStreaming(io, &iov) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) {
            break;
        }
        try list.appendSlice(gpa, buf[0..n]);
    }
    return list.toOwnedSlice(gpa);
}

/// Base64 alphabet used by Source Map v3 VLQ encoding.
const vlq_b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Append the base64-VLQ encoding of a signed integer to `out`.
fn vlqEncode(
    gpa: Allocator,
    out: *ArrayList(u8),
    value: i64,
) !void {
    // sign in LSB, magnitude above it
    var v: u64 = if (value < 0)
        (@as(u64, @intCast(-value)) << 1) | 1
    else
        @as(u64, @intCast(value)) << 1;
    while (true) {
        var digit: u6 = @intCast(v & 0x1f);
        v >>= 5;
        if (v != 0) {
            digit |= 0x20;
        } // continuation bit
        try out.append(gpa, vlq_b64[digit]);
        if (v == 0) {
            break;
        }
    }
}

/// Minimal JSON string escaping for embedding the C source.
fn jsonEscapeInto(
    gpa: Allocator,
    out: *ArrayList(u8),
    s: []const u8,
) !void {
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            0...8, 11, 12, 14...31 => {
                const hex: []const u8 = "0123456789abcdef";
                try out.appendSlice(gpa, "\\u00");
                try out.append(gpa, hex[(c >> 4) & 0xf]);
                try out.append(gpa, hex[c & 0xf]);
            },
            else => try out.append(gpa, c),
        }
    }
}

/// Build a Source Map v3 JSON document mapping the generated JS back to the C
/// (line granularity). `sources`/`sourcesContent` embed the C so a debugger can
/// show it. We map JS->C because Zig's C backend emits no line info to reach the
/// original .zig; the C still carries the (mangled) Zig identifier names.
fn buildSourceMap(
    gpa: Allocator,
    map_name: []const u8,
    source_name: []const u8,
    c_source: []const u8,
    entries: []const LineMap,
) ![]const u8 {
    var mappings: ArrayList(u8) = .empty;
    // entries are recorded in generated-line order. We emit one segment per
    // generated line that has a mapping: [genCol=0, srcIdx, srcLineDelta, srcCol=0].
    var prev_gen: u32 = 1;
    var prev_src: i64 = 0;
    var first: bool = true;
    for (entries) |e| {
        // advance to e.gen with ';' for each generated line
        while (prev_gen < e.gen) : (prev_gen += 1) {
            try mappings.append(gpa, ';');
        }
        if (!first and mappings.items.len > 0 and mappings.items[mappings.items.len - 1] != ';') {
            try mappings.append(gpa, ',');
        } // (shouldn't happen: one seg per line)
        // segment: genColumn=0, sourceIndex=0, sourceLine delta, sourceColumn=0
        try vlqEncode(gpa, &mappings, 0); // generated column 0
        try vlqEncode(gpa, &mappings, 0); // source index 0 (single source)
        try vlqEncode(gpa, &mappings, @as(i64, e.src - 1) - prev_src); // 0-based source line, delta
        try vlqEncode(gpa, &mappings, 0); // source column 0
        prev_src = @as(i64, e.src - 1);
        first = false;
    }
    _ = map_name;

    // assemble JSON with JSON-escaped sourcesContent
    var json: ArrayList(u8) = .empty;
    try json.appendSlice(gpa, "{\"version\":3,\"file\":\"");
    try jsonEscapeInto(gpa, &json, source_name); // not used as file, harmless
    try json.appendSlice(gpa, "\",\"sources\":[\"");
    try jsonEscapeInto(gpa, &json, source_name);
    try json.appendSlice(gpa, "\"],\"sourcesContent\":[\"");
    try jsonEscapeInto(gpa, &json, c_source);
    try json.appendSlice(gpa, "\"],\"names\":[],\"mappings\":\"");
    try json.appendSlice(gpa, mappings.items);
    try json.appendSlice(gpa, "\"}\n");
    return json.toOwnedSlice(gpa);
}

// Program entry — wires the whole pipeline together. Arena-allocate everything,
// read C from stdin, preprocess, tokenize (tagging each token with its C line
// for the source map), then build a Transpiler and run it. Afterwards write the
// JS to stdout, and if a basename arg was passed, also write "<name>.js.map" and
// append a //# sourceMappingURL.
pub fn main(init: std.process.Init) !void {
    // Use an arena for all transpiler allocations: it frees everything at once on
    // deinit, so we don't fight the (leak-checking) default gpa over the fact that
    // this tool intentionally never frees individual allocations.
    var arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const gpa: Allocator = arena.allocator();

    // If a base name is given as argv[1], also emit a source map:
    //   <base>.js.map  (JS -> preprocessed-C, line granularity)
    // and append a sourceMappingURL comment to the JS so debuggers find it.
    // Without an arg, behave as a plain stdin->stdout filter (tests rely on this).
    // initAllocator works on every OS (Windows/WASI need the allocation; POSIX
    // tolerates it), unlike the bare .init which compile-errors on Windows.
    var arg_it: std.process.Args.Iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    _ = arg_it.next(); // exe name
    var base_opt: ?[]const u8 = null;
    var minify_out: bool = false;
    var safe_heap: bool = false;
    var html_out: bool = false;
    var fullscreen_landscape: bool = false;
    var title_opt: ?[]const u8 = null;
    var wasm_url_opt: ?[]const u8 = null;
    var wasm_embed_opt: ?[]const u8 = null;
    var kernel_wasm_opt: ?[]const u8 = null;
    // The WORKER's program, itself produced by this very tool from src/jobs_worker.zig.
    // Injected as window.ZIMR_WORKER_JS for the same reason the kernel wasm is: the bridge is
    // compiled in six places, and threading a module import through all of them to carry one
    // string would be worse than reading a global.
    var worker_js_opt: ?[]const u8 = null;
    var external_js_opt: ?[]const u8 = null;
    const usage_text: []const u8 =
        \\wz_c2js — transpile the Zig C-backend's output (C on stdin) to JavaScript on stdout.
        \\
        \\Usage: wz_c2js [options] [basename] < input.c > output.js
        \\
        \\Options:
        \\  --min                minify the JS output
        \\  --safe               SAFE_HEAP: bounds/alignment/null-check every heap access (debug)
        \\  --html               wrap the JS in a minimal HTML page (emitted to stdout)
        \\  --title <text>       page <title> (with --html)
        \\  --wasm-url <url>     set window.WASM_URL so the page fetches a sibling .wasm
        \\  --wasm-embed <file>  base64-inline the .wasm into the page (self-contained)
        \\  --external-js <url>  reference a shared runtime JS via <script src> instead of
        \\                       inlining it (the gallery: one cached zimr.js, tiny pages)
        \\  -h, --help           show this help and exit
        \\
        \\If [basename] is given, also writes "<basename>.js.map" and appends a
        \\sourceMappingURL comment to the JS. With no arguments, acts as a plain
        \\stdin->stdout filter.
        \\
    ;
    while (arg_it.next()) |a| {
        if (eql(u8, a, "--min")) {
            minify_out = true;
        } else if (eql(u8, a, "--safe")) {
            safe_heap = true;
        } else if (eql(u8, a, "--html")) {
            html_out = true;
        } else if (eql(u8, a, "--title")) {
            title_opt = if (arg_it.next()) |v| try gpa.dupe(u8, v) else null;
        } else if (eql(u8, a, "--fullscreen-landscape")) {
            fullscreen_landscape = true;
        } else if (eql(u8, a, "--wasm-url")) {
            wasm_url_opt = if (arg_it.next()) |v| try gpa.dupe(u8, v) else null;
        } else if (eql(u8, a, "--kernel-wasm-embed")) {
            kernel_wasm_opt = if (arg_it.next()) |v| try gpa.dupe(u8, v) else null;
        } else if (eql(u8, a, "--worker-js-embed")) {
            worker_js_opt = if (arg_it.next()) |v| try gpa.dupe(u8, v) else null;
        } else if (eql(u8, a, "--wasm-embed")) {
            wasm_embed_opt = if (arg_it.next()) |v| try gpa.dupe(u8, v) else null;
        } else if (eql(u8, a, "--external-js")) {
            external_js_opt = if (arg_it.next()) |v| try gpa.dupe(u8, v) else null;
        } else if (eql(u8, a, "--help") or eql(u8, a, "-h")) {
            try writeAllStdout(init.io, usage_text);
            return;
        } else if (a.len > 0 and a[0] == '-') {
            // Unknown flag: fail loudly. Previously this fell through to the
            // basename catch-all, so a typo like `--htlm` silently became the
            // output basename (emitting a stray .js.map and no HTML).
            try writeAllStderr(init.io, "wz_c2js: unknown option '");
            try writeAllStderr(init.io, a);
            try writeAllStderr(init.io, "'\n\n");
            try writeAllStderr(init.io, usage_text);
            std.process.exit(2);
        } else if (base_opt == null) {
            base_opt = try gpa.dupe(u8, a);
        } else {
            try writeAllStderr(init.io, "wz_c2js: unexpected extra argument '");
            try writeAllStderr(init.io, a);
            try writeAllStderr(init.io, "' (only one basename is used)\n\n");
            try writeAllStderr(init.io, usage_text);
            std.process.exit(2);
        }
    }

    // Args are parsed (so --help / bad-flag errors never blocked on a stdin
    // read). Now read the C and transpile it.
    const input: []u8 = try readAllStdin(gpa, init.io);
    const pp: Preprocessed = try preprocess(gpa, input);

    // tokenize, tagging each token with its 1-based line in the C source so the
    // source map can point JS positions back at the (mangled but identifier-
    // preserving) C — the closest debuggable source, since Zig's C backend emits
    // no #line info to reach the original .zig.
    var lex = Lexer{ .src = pp.src };
    var toks: ArrayList(Token) = .empty;
    var line: u32 = 1;
    var scan: usize = 0;
    while (true) {
        var tk: Token = lex.nextToken();
        // advance the line counter to the token's start offset
        while (scan < lex.last_start and scan < pp.src.len) : (scan += 1) {
            if (pp.src[scan] == '\n') {
                line += 1;
            }
        }
        tk.line = line;
        try toks.append(gpa, tk);
        if (tk.kind == .eof) {
            break;
        }
    }

    var t = Transpiler.init(gpa, toks.items, pp.defines, safe_heap);
    try t.run();

    // GATE: c2js emits a `/*?...*/ 0` marker wherever it meets C it cannot
    // model — an unmodeled zig.h helper, an atomic, a >64-bit packed field, or
    // just an unknown token. The marker was always written to be "visible", but
    // nothing ever LOOKED at it, so a compiler bump that renamed zig.h's cast
    // helpers turned 99 call sites into a literal 0 and shipped green through
    // lint, fmt and verify_imports. EVERY marker is a silently wrong VALUE
    // rather than a crash — the worst failure mode there is — so ANY marker, of
    // ANY kind, is fatal here, not just the one that happened to bite us.
    // Guessed cast widths (bitsArg) are the same class with no trace in the
    // emitted JS, so they ride along in the same report.
    {
        const open: []const u8 = "/*?";
        var count: usize = 0;
        var at_from: usize = 0;
        while (indexOfPos(u8, t.out.items, at_from, open)) |at| {
            const body_at: usize = at + open.len;
            const close: usize = indexOfPos(u8, t.out.items, body_at, "*/") orelse t.out.items.len;
            try writeAllStderr(init.io, try allocPrint(
                gpa,
                "c2js: FATAL: unmodeled C construct '{s}' lowered to a constant\n",
                .{t.out.items[body_at..close]},
            ));
            count += 1;
            at_from = close;
        }
        for (t.diags.items) |d| {
            try writeAllStderr(init.io, try allocPrint(gpa, "c2js: FATAL: {s}\n", .{d}));
        }
        count += t.diag_count;
        if (count > 0) {
            try writeAllStderr(init.io, try allocPrint(
                gpa,
                "c2js: {d} unmodeled construct(s) — teach c2js these before shipping\n",
                .{count},
            ));
            std.process.exit(2);
        }
    }

    if (base_opt) |base| {
        const map_name: []u8 = try allocPrint(gpa, "{s}.js.map", .{base});
        // The source we map back to is the *preprocessed* C (line numbers match
        // what the lexer counted). Embed it so the debugger can display it.
        const src_name: []u8 = try allocPrint(gpa, "{s}.c", .{base});
        const map: []const u8 = try buildSourceMap(
            gpa,
            map_name,
            src_name,
            pp.src,
            t.line_map.items,
        );
        try writeFile(init.io, map_name, map);
        // append the sourceMappingURL comment (basename of the map path)
        var bn: []const u8 = map_name;
        if (std.mem.lastIndexOfScalar(u8, map_name, '/')) |slash| {
            bn = map_name[slash + 1 ..];
        }
        const tail: []u8 = try allocPrint(gpa, "\n//# sourceMappingURL={s}\n", .{bn});
        try t.emit(tail);
    }

    const js_out: []u8 = if (minify_out) try minify(gpa, t.out.items) else t.out.items;
    if (html_out) {
        // Minimal page: the document body is built by the Zig program itself (DOM
        // construction), so the skeleton just hosts the script and boots it via
        // `start()` once the DOM is ready. Optionally it wires up a WASM module:
        //   --wasm-url <u>    -> window.WASM_URL  (the page fetches a sibling .wasm)
        //   --wasm-embed <f>  -> window.WASM_BYTES (the .wasm is base64-inlined; the
        //                        page is then fully self-contained, no separate file)
        const title_text: []const u8 = title_opt orelse "Zig &rarr; C &rarr; JS";
        const wasm_setup: []const u8 = if (wasm_embed_opt) |wpath| blk: {
            const wbytes: []u8 = try readFileAlloc(init.io, gpa, wpath);
            const enc: std.base64.Base64Encoder = std.base64.standard.Encoder;
            const b64: []u8 = try gpa.alloc(u8, enc.calcSize(wbytes.len));
            _ = enc.encode(b64, wbytes);
            // ── ★★★ THE BASE64 IS WRAPPED, AND THAT IS NOT COSMETIC ──
            //
            // Emitted as one string, the wasm becomes a SINGLE LINE as long as the encoding:
            // measured at **1 048 385 characters** for `zimrnum_field` — just under 2^20 — where
            // `hello_world` sat at 747 949 and had always opened fine. That page was the first
            // to cross a megabyte on one line, and the first that Claude's Android viewer refused
            // to open while Chrome opened it happily. A per-line buffer limit is the obvious
            // suspect and this is the cheap way to stop provoking it.
            //
            // ★★ SPLIT INTO JS STRING CONCATENATION, not by putting newlines inside the literal.
            // `atob` tolerating whitespace is implementation behaviour, not something the spec
            // promises, and a page that decodes on one engine and not another is worse than a
            // long line. `"a" + "b"` is unambiguous everywhere.
            //
            // ★ 64 KB per chunk: comfortably under any plausible line limit, and few enough
            // concatenations that no parser is troubled by the expression depth.
            const chunk: usize = 64 * 1024;
            var js: std.ArrayList(u8) = .empty;
            defer js.deinit(gpa);
            try js.appendSlice(gpa, "<script>window.WASM_BYTES = Uint8Array.from(atob(\n");
            var at: usize = 0;
            while (at < b64.len) : (at += chunk) {
                const end: usize = @min(at + chunk, b64.len);
                if (at > 0) {
                    try js.appendSlice(gpa, " +\n");
                }
                try js.append(gpa, '"');
                try js.appendSlice(gpa, b64[at..end]);
                try js.append(gpa, '"');
            }
            try js.appendSlice(
                gpa,
                "\n), function (c) { return c.charCodeAt(0); });</script>\n",
            );
            break :blk try js.toOwnedSlice(gpa);
        } else if (wasm_url_opt) |url|
            try allocPrint(gpa, "<script>window.WASM_URL = \"{s}\";</script>\n", .{url})
        else
            "";

        // --kernel-wasm-embed <f> -> window.ZIMR_KERNEL_WASM
        //
        // The job kernels, compiled separately for wasm32-freestanding. Each Web Worker
        // instantiates a private copy of this; the app's own wasm is far too big (31 MB
        // of linear memory) and needs 96 imports a worker cannot provide (WebGPU, DOM).
        //
        // THE PURITY GATE LIVES HERE. A kernel must be a pure function of its bytes, so
        // its wasm must import NOTHING — that is exactly what lets a worker instantiate
        // it with `{}`. If a kernel reaches for the DOM or WebGPU, the linker records an
        // import, and we refuse to build rather than ship a page whose workers die on
        // instantiation. The failure is a build error naming the offending import, not a
        // silent runtime break in a thread nobody is watching.
        // --worker-js-embed <f> -> window.ZIMR_WORKER_JS
        //
        // The Web Worker's program, which is itself c2js output (from src/jobs_worker.zig).
        // Base64, not raw text: the program is ~46 KB of JavaScript and dropping it into an
        // HTML <script> unescaped would break on the first quote, backslash, or the literal
        // sequence "</script>" appearing inside a string.
        const worker_setup: []const u8 = if (worker_js_opt) |wpath| blk: {
            const wbytes: []u8 = try readFileAlloc(init.io, gpa, wpath);

            // The worker MUST NOT contain `await`. An async onmessage yields, and a job
            // arriving during instantiation re-enters the handler with the kernel exports
            // still unset — it throws inside the worker and is never heard from again. There
            // is no `await` in Zig to reach for, so this can only fire if someone reintroduces
            // hand-written JS. Catch it HERE, where the message can say what went wrong.
            if (std.mem.indexOf(u8, wbytes, "await") != null) {
                std.log.err(
                    "worker JS '{s}' contains `await`.\n" ++
                        "  An async message handler YIELDS, so a job that arrives while the " ++
                        "kernel wasm is still\n" ++
                        "  instantiating re-enters the handler with the exports unset. It " ++
                        "throws inside the worker\n" ++
                        "  and vanishes: no error, no result. Instantiate synchronously " ++
                        "(WebAssembly.Module + Instance).",
                    .{wpath},
                );
                return error.WorkerProgramYields;
            }

            const enc: std.base64.Base64Encoder = std.base64.standard.Encoder;
            const b64: []u8 = try gpa.alloc(u8, enc.calcSize(wbytes.len));
            _ = enc.encode(b64, wbytes);
            break :blk try allocPrint(
                gpa,
                "<script>window.ZIMR_WORKER_JS = atob(\"{s}\");</script>\n",
                .{b64},
            );
        } else "";

        const kernel_setup: []const u8 = if (kernel_wasm_opt) |kpath| blk: {
            const kbytes: []u8 = try readFileAlloc(init.io, gpa, kpath);

            // A kernel wasm with no `zimr_job_alloc` export has no kernels in it — the
            // root forgot to call `registry.exportWorkerEntry()`. That would sail through
            // the purity check below (nothing imported, because nothing is there) and
            // then fail at RUNTIME as a NoSuchKernel, in a worker, on a phone. Catch the
            // empty case here, where the message can say what actually went wrong.
            if (!wasmExports(kbytes, jobs_abi.alloc)) {
                std.log.err(
                    "kernel wasm '{s}' exports no kernels.\n" ++
                        "  Its root must call `registry.exportWorkerEntry()` — build.zig generates\n" ++
                        "  a root that does. Without it every `submit` fails as NoSuchKernel at\n" ++
                        "  runtime, inside a worker, where you cannot see it.",
                    .{kpath},
                );
                return error.EmptyKernelWasm;
            }

            const impure: ?[]const u8 = try firstWasmImport(gpa, kbytes);
            if (impure) |name| {
                std.log.err(
                    "kernel wasm '{s}' imports '{s}' — a job kernel must be PURE.\n" ++
                        "  It runs in a Web Worker, which has no DOM, no canvas and no WebGPU,\n" ++
                        "  so an import there cannot be satisfied and the worker would die on\n" ++
                        "  instantiation. Keep kernels to codecs/zm/jobs and pure Zig.",
                    .{ kpath, name },
                );
                return error.ImpureKernel;
            }
            const enc: std.base64.Base64Encoder = std.base64.standard.Encoder;
            const b64: []u8 = try gpa.alloc(u8, enc.calcSize(kbytes.len));
            _ = enc.encode(b64, kbytes);
            break :blk try allocPrint(
                gpa,
                "<script>window.ZIMR_KERNEL_WASM = Uint8Array.from(atob(\"{s}\"), " ++
                    "function (c) {{ return c.charCodeAt(0); }});</script>\n",
                .{b64},
            );
        } else "";
        const fs_js: []const u8 = if (fullscreen_landscape)
            \\<style>
            \\  html,body{margin:0;height:100%;background:#000;overflow:hidden}
            \\  #fsbtn{position:fixed;right:10px;bottom:10px;z-index:99998;
            \\    width:52px;height:52px;border:none;border-radius:10px;
            \\    background:#1e2a44;color:#cfe0ff;font:24px/52px monospace;
            \\    text-align:center;opacity:0.85}
            \\</style>
            \\<button id="fsbtn" title="fullscreen">[ ]</button>
            \\<script>
            \\(function(){
            \\  var b=document.getElementById("fsbtn");
            \\  function fsEl(){ return document.fullscreenElement || document.webkitFullscreenElement; }
            \\  async function go(){
            \\    // Toggle fullscreen in WHATEVER orientation the user is in — no
            \\    // orientation lock, so portrait works exactly like landscape.
            \\    try{
            \\      if(fsEl()){
            \\        if(document.exitFullscreen) await document.exitFullscreen();
            \\        else if(document.webkitExitFullscreen) document.webkitExitFullscreen();
            \\      }else{
            \\        var el=document.documentElement;
            \\        if(el.requestFullscreen) await el.requestFullscreen();
            \\        else if(el.webkitRequestFullscreen) el.webkitRequestFullscreen();
            \\      }
            \\    }catch(e){}
            \\  }
            \\  b.addEventListener("click", go);
            \\})();
            \\</script>
        else
            "";
        // On-page log overlay: mirrors console.{log,warn,error} to a bounded
        // bottom panel so logs are visible without devtools (e.g. on a phone).
        // PLAIN JS + a fixed-size line array (MAX lines, no wasm handles), so it
        // cannot grow unbounded the way the earlier wasm-side log panel did (that
        // leaked JS handles per call and bricked the device). Not an allocPrint
        // format string, so its braces need no escaping.
        const log_overlay_js: []const u8 =
            \\<script>
            \\(function () {
            \\  var MAX = 200, lines = [], panel = null;
            \\  function ensure() {
            \\    if (panel) return panel;
            \\    panel = document.createElement("pre");
            \\    panel.style.cssText = "position:fixed;left:0;bottom:0;max-height:40%;width:100%;" +
            \\      "margin:0;padding:6px 8px;background:rgba(0,0,0,0.72);color:#cfe;" +
            \\      "font:11px/1.35 monospace;white-space:pre-wrap;z-index:99997;overflow:auto;" +
            \\      "pointer-events:none";
            \\    (document.body || document.documentElement).appendChild(panel);
            \\    return panel;
            \\  }
            \\  function add(prefix, args) {
            \\    var parts = [];
            \\    for (var i = 0; i < args.length; i++) {
            \\      var a = args[i];
            \\      parts.push(typeof a === "string" ? a : String(a));
            \\    }
            \\    lines.push(prefix + parts.join(" "));
            \\    if (lines.length > MAX) lines.splice(0, lines.length - MAX);
            \\    var p = ensure();
            \\    p.textContent = lines.join("\n");
            \\    p.scrollTop = p.scrollHeight;
            \\  }
            \\  ["log", "warn", "error"].forEach(function (m) {
            \\    var orig = console[m].bind(console);
            \\    console[m] = function () {
            \\      try { add(m === "log" ? "" : "[" + m + "] ", arguments); } catch (e) {}
            \\      return orig.apply(console, arguments);
            \\    };
            \\  });
            \\})();
            \\</script>
        ;
        // The JS section: either INLINE the transpiled runtime, or (for the
        // gallery's served pages, --external-js) reference a shared zimr.js via
        // <script src> so the ~500KB runtime is fetched + cached ONCE instead of
        // per example. The wasm_setup (WASM_URL / WASM_BYTES global) precedes both.
        const js_section: []const u8 = if (external_js_opt) |ext|
            try allocPrint(
                gpa,
                "{s}{s}{s}<script src=\"{s}\"></script>",
                .{ wasm_setup, kernel_setup, worker_setup, ext },
            )
        else
            try allocPrint(
                gpa,
                "{s}{s}{s}<script>\n{s}\n</script>",
                .{ wasm_setup, kernel_setup, worker_setup, js_out },
            );
        const html: []u8 = try allocPrint(gpa,
            \\<!doctype html>
            \\<meta charset="utf-8">
            \\<meta name="viewport" content="width=device-width, initial-scale=1">
            \\<title>{s}</title>
            \\{s}
            \\<script>
            \\// zimr: self-reporting page — any uncaught error (including a top-level
            \\// throw during the runtime preamble) paints full-screen instead of a
            \\// silent white page. Installed BEFORE the generated script on purpose.
            \\// ONE panel, APPENDED to - not a new element per call.
            \\//
            \\// Each call used to create its own `position:fixed;inset:0` <pre>, so the LAST
            \\// error painted over every earlier one. That hid the message that mattered: a
            \\// WGSL compile diagnostic arrives in a promise microtask and can land BEFORE the
            \\// pipeline-creation cascade it explains, whereupon the cascade covered it and the
            \\// page showed only "invalid due to a previous error".
            \\window.__wzFail = function (msg) {{
            \\  var d = document.getElementById("__wzfail");
            \\  if (!d) {{
            \\    d = document.createElement("pre");
            \\    d.id = "__wzfail";
            \\    d.style.cssText = "position:fixed;inset:0;margin:0;padding:16px;background:#2a0000;" +
            \\      "color:#fdd;font:14px/1.5 monospace;white-space:pre-wrap;z-index:99999;overflow:auto";
            \\    d.textContent = "BRIDGE PAGE ERROR";
            \\    (document.body || document.documentElement).appendChild(d);
            \\  }}
            \\  d.textContent += "\n\n" + msg;
            \\}};
            \\window.addEventListener("error", function (e) {{
            \\  window.__wzFail((e.message || "error") + "\n" + (e.filename || "") + ":" + (e.lineno || 0) +
            \\    (e.error && e.error.stack ? "\n\n" + e.error.stack : ""));
            \\}});
            \\window.addEventListener("unhandledrejection", function (e) {{
            \\  window.__wzFail("unhandled rejection: " + (e.reason && e.reason.stack ? e.reason.stack : e.reason));
            \\}});
            \\</script>
            \\{s}
            \\{s}
            \\<script>
            \\window.addEventListener("DOMContentLoaded", function () {{
            \\  if (typeof start !== "function") {{
            \\    window.__wzFail("start() is not defined — the main script failed to evaluate " +
            \\      "(its top-level threw before finishing; see any error above).");
            \\    return;
            \\  }}
            \\  try {{ start(); }} catch (err) {{ window.__wzFail("start() threw:\n" + (err.stack || err)); }}
            \\}});
            \\</script>
            \\
        , .{ title_text, fs_js, log_overlay_js, js_section });
        try writeAllStdout(init.io, html);
    } else {
        try writeAllStdout(init.io, js_out);
    }
}
