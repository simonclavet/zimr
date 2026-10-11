#!/bin/sh
# Native-oracle differential tester.
#
# For each Zig program (which must export `run_test() i32`), compute the result
# two ways and compare:
#   (1) NATIVE  — compile the program + a tiny main to a native binary, run it.
#                 This is ground truth: real Zig semantics on real hardware.
#   (2) JS      — Zig -> C (-ofmt=c) -> transpiler -> JS, run in node.
#   (3) WORKLET — the same JS as an audio worklet loads it: strict mode, and no
#                 atob, TextDecoder or TextEncoder (run_as_worklet.js), so that
#                 the prelude's own base64 and UTF-8 are used.
# A mismatch means the transpiler produced JavaScript that does not do what the
# Zig says. Expected values are NEVER hand-written; the oracle is the compiler.
# After the cases, the prelude's base64 and UTF-8 are tested against the
# built-ins themselves (prelude_fallbacks_test.js).
#
# Then the JS-only cases (js_cases/): programs reaching JavaScript itself
# through the kernel, which have no native program to compare with. Each runs
# against its fixture (<name>.fixture.js) and checks itself - run_test()
# returns 0 - both as a page runs it and as an audio worklet loads it.
#
# Usage: differential.sh <zig> <c_to_js> <oracle_main.zig> <tmp> file1.zig ...
# ALLOW_SKIP (env): space-separated basenames permitted to fail the native build
#   (no native oracle — e.g. JS-interop cases). Any OTHER native-build failure is
#   a hard error (a case that should build but regressed must not silently drop).
set -e
Z="$1"; C2="$2"; ORACLE="$3"; TMP="$4"; shift 4
ALLOW_SKIP="${ALLOW_SKIP:-}"
# KNOWN_FAIL (env): space-separated basenames that currently FAIL due to a known
# upstream cause (e.g. a Zig C-backend lowering change c2js has not caught up to).
# They are reported as XFAIL and do NOT fail the gate; a NEW failure still does.
# If a KNOWN_FAIL case starts passing, it is reported XPASS — remove it from the list.
KNOWN_FAIL="${KNOWN_FAIL:-}"
xfail=0; xpass=0
mkdir -p "$TMP"
fail=0; pass=0; skip=0; js_pass=0
first_js=""
for src in "$@"; do
    name=$(basename "$src" .zig)
    # (1) native oracle
    cat "$src" "$ORACLE" > "$TMP/$name.native.zig"
    if ! "$Z" build-exe "$TMP/$name.native.zig" -femit-bin="$TMP/$name.native" 2>"$TMP/$name.nerr"; then
        allowed=0; for a in $ALLOW_SKIP; do [ "$name" = "$a" ] && allowed=1; done
        if [ "$allowed" -eq 1 ]; then
            printf '  SKIP  %-22s (no native oracle)\n' "$name"; skip=$((skip+1)); continue
        fi
        printf '  FAIL  %-22s native build failed (unexpected — see %s)\n' "$name" "$TMP/$name.nerr"
        fail=$((fail+1)); continue
    fi
    native=$("$TMP/$name.native")
    # (2) transpiled JS
    # A C build that fails, or C that c2js refuses - it reports what it does not model rather than guess - fails this
    # case with the reason, and the run goes on to the next case.
    if ! "$Z" build-obj "$src" -ofmt=c -OReleaseSmall -target wasm32-freestanding -femit-bin="$TMP/$name.c" 2>"$TMP/$name.cerr"; then
        printf '  FAIL  %-22s the C build failed (see %s)\n' "$name" "$TMP/$name.cerr"
        fail=$((fail+1)); continue
    fi
    if ! "$C2" < "$TMP/$name.c" > "$TMP/$name.js" 2>"$TMP/$name.c2err"; then
        printf '  FAIL  %-22s c2js refused the C:\n' "$name"
        sed -n '1,8p' "$TMP/$name.c2err" | sed 's/^/          /'
        fail=$((fail+1)); continue
    fi
    markers=$(grep -cE '/\*TODO|/\*\?' "$TMP/$name.js" || true)
    js=$(node -e "try{const f=new Function(require('fs').readFileSync('$TMP/$name.js','utf8')+'\nreturn run_test;')();console.log(f())}catch(e){console.log('JS_ERROR:'+e.message.split(String.fromCharCode(10))[0])}")
    # A marker means an unhandled/uncertain lowering reached the output: fail even
    # if this input's answer happens to match (it may be wrong for other inputs).
    worklet=$(node tools/c2js_cases/run_as_worklet.js "$TMP/$name.js")
    if [ "$markers" != "0" ]; then
        ok=0; detail="$markers unhandled-C marker(s)  native=$native js=$js"
    elif [ "$native" = "$js" ] && [ "$native" = "$worklet" ]; then
        ok=1
    else
        ok=0; detail="native=$native  js=$js  worklet=$worklet  markers=0"
    fi
    if [ -z "$first_js" ]; then first_js="$TMP/$name.js"; fi
    known=0; for k in $KNOWN_FAIL; do [ "$name" = "$k" ] && known=1; done
    if [ "$ok" -eq 1 ]; then
        if [ "$known" -eq 1 ]; then
            printf '  XPASS %-22s known-fail now PASSES — remove from KNOWN_FAIL\n' "$name"; xpass=$((xpass+1))
        else
            printf '  ok    %-22s native=%s js=%s worklet=%s markers=0\n' "$name" "$native" "$js" "$worklet"
            pass=$((pass+1))
        fi
    else
        if [ "$known" -eq 1 ]; then
            printf '  XFAIL %-22s (known drift) %s\n' "$name" "$detail"; xfail=$((xfail+1))
        else
            printf '  FAIL  %-22s %s\n' "$name" "$detail"; fail=$((fail+1))
        fi
    fi
    # reclaim space: the native binary is large; keep only tiny artifacts.
    rm -f "$TMP/$name.native" "$TMP/$name.native.zig" "$TMP/$name.c"
done
for src in tools/c2js_cases/js_cases/*.zig; do
    name=$(basename "$src" .zig)
    if ! "$Z" build-obj "$src" -ofmt=c -OReleaseSmall -target wasm32-freestanding -femit-bin="$TMP/js_$name.c" 2>"$TMP/js_$name.cerr"; then
        printf '  FAIL  %-22s the C build failed (see %s)\n' "js:$name" "$TMP/js_$name.cerr"
        fail=$((fail+1)); continue
    fi
    if ! "$C2" < "$TMP/js_$name.c" > "$TMP/js_$name.js" 2>"$TMP/js_$name.c2err"; then
        printf '  FAIL  %-22s c2js refused the C:\n' "js:$name"
        sed -n '1,8p' "$TMP/js_$name.c2err" | sed 's/^/          /'
        fail=$((fail+1)); continue
    fi
    fixture="tools/c2js_cases/js_cases/$name.fixture.js"
    page=$(node tools/c2js_cases/run_js_case.js "$TMP/js_$name.js" "$fixture" page)
    worklet=$(node tools/c2js_cases/run_js_case.js "$TMP/js_$name.js" "$fixture" worklet)
    if [ "$page" = "0" ] && [ "$worklet" = "0" ]; then
        printf '  ok    %-22s page=%s worklet=%s\n' "js:$name" "$page" "$worklet"; js_pass=$((js_pass+1))
    else
        printf '  FAIL  %-22s page=%s worklet=%s (0 is success)\n' "js:$name" "$page" "$worklet"; fail=$((fail+1))
    fi
    rm -f "$TMP/js_$name.c"
done
if [ -n "$first_js" ]; then
    if node tools/c2js_cases/prelude_fallbacks_test.js "$first_js" > "$TMP/fallbacks.out" 2>&1; then
        sed 's/^/  ok    prelude fallbacks: /' "$TMP/fallbacks.out"
    else
        printf '  FAIL  prelude fallbacks differ from the built-ins:\n'
        sed -n '1,12p' "$TMP/fallbacks.out" | sed 's/^/          /'
        fail=$((fail+1))
    fi
fi
echo ""
if [ "$fail" -eq 0 ]; then echo "DIFFERENTIAL: $pass agree with native, $js_pass JS-only cases check out ($xfail known-fail, $xpass unexpected-pass, $skip skipped)"; else echo "DIFFERENTIAL: $fail FAILURE(s), $pass agree, $xfail known-fail, $skip skipped"; exit 1; fi
