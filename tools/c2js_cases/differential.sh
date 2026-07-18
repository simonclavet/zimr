#!/bin/sh
# Native-oracle differential tester.
#
# For each Zig program (which must export `run_test() i32`), compute the result
# two ways and compare:
#   (1) NATIVE  — compile the program + a tiny main to a native binary, run it.
#                 This is ground truth: real Zig semantics on real hardware.
#   (2) JS      — Zig -> C (-ofmt=c) -> transpiler -> JS, run in node.
# A mismatch means the transpiler produced JavaScript that does not do what the
# Zig says. Expected values are NEVER hand-written; the oracle is the compiler.
#
# Usage: differential.sh <zig> <c_to_js> <oracle_main.zig> <tmp> file1.zig ...
# ALLOW_SKIP (env): space-separated basenames permitted to fail the native build
#   (no native oracle — e.g. JS-interop cases). Any OTHER native-build failure is
#   a hard error (a case that should build but regressed must not silently drop).
set -e
Z="$1"; C2="$2"; ORACLE="$3"; TMP="$4"; shift 4
ALLOW_SKIP="${ALLOW_SKIP:-interop}"
# KNOWN_FAIL (env): space-separated basenames that currently FAIL due to a known
# upstream cause (e.g. a Zig C-backend lowering change c2js has not caught up to).
# They are reported as XFAIL and do NOT fail the gate; a NEW failure still does.
# If a KNOWN_FAIL case starts passing, it is reported XPASS — remove it from the list.
KNOWN_FAIL="${KNOWN_FAIL:-}"
xfail=0; xpass=0
mkdir -p "$TMP"
fail=0; pass=0; skip=0
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
    "$Z" build-obj "$src" -ofmt=c -OReleaseSmall -target wasm32-freestanding -femit-bin="$TMP/$name.c" 2>/dev/null
    "$C2" < "$TMP/$name.c" > "$TMP/$name.js" 2>/dev/null
    markers=$(grep -cE '/\*TODO|/\*\?' "$TMP/$name.js" || true)
    js=$(node -e "try{const f=new Function(require('fs').readFileSync('$TMP/$name.js','utf8')+'\nreturn run_test;')();console.log(f())}catch(e){console.log('JS_ERROR:'+e.message.split(String.fromCharCode(10))[0])}")
    # A marker means an unhandled/uncertain lowering reached the output: fail even
    # if this input's answer happens to match (it may be wrong for other inputs).
    if [ "$markers" != "0" ]; then
        ok=0; detail="$markers unhandled-C marker(s)  native=$native js=$js"
    elif [ "$native" = "$js" ]; then
        ok=1
    else
        ok=0; detail="native=$native  js=$js  markers=0"
    fi
    known=0; for k in $KNOWN_FAIL; do [ "$name" = "$k" ] && known=1; done
    if [ "$ok" -eq 1 ]; then
        if [ "$known" -eq 1 ]; then
            printf '  XPASS %-22s known-fail now PASSES — remove from KNOWN_FAIL\n' "$name"; xpass=$((xpass+1))
        else
            printf '  ok    %-22s native=%s js=%s markers=0\n' "$name" "$native" "$js"; pass=$((pass+1))
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
echo ""
if [ "$fail" -eq 0 ]; then echo "DIFFERENTIAL: $pass agree with native ($xfail known-fail, $xpass unexpected-pass, $skip skipped)"; else echo "DIFFERENTIAL: $fail FAILURE(s), $pass agree, $xfail known-fail, $skip skipped"; exit 1; fi
