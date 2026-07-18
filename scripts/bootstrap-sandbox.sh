#!/usr/bin/env bash
# bootstrap-sandbox.sh — bring a cold Linux sandbox up to a working,
# verified zimr build.  PURE ZIG: no C++ SPIR-V tools are built.
# Run from the repo root:  ./scripts/bootstrap-sandbox.sh
#
# Expects uploads in /mnt/user-data/uploads (Simon provides these; the
# exact filenames vary per upload, so we glob):
#   zig-*-linux-*0.17*.tar.xz   Zig 0.17 toolchain            (required)
#   bun-linux-x64*.zip          Bun                            (required)
#   wgpu-trunk*.zip             naga (Rust naga-cli) source    (optional)
#
# The Rust toolchain (for building naga) is staged separately; if `cargo`
# is on PATH and wgpu-trunk is available, this script also builds + stages
# the naga WGSL validator.  naga is a BUILD-TIME verifier only — it is
# never shipped in the wasm.
#
# Timing (single-core sandbox, cold): tools ~30s + compute-smoke
# standalone ~170s; naga adds ~190s.  No C++ libspirv compile.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UP="${ZIMR_UPLOADS:-/mnt/user-data/uploads}"
cd "$ROOT"
echo "== zimr bootstrap (root=$ROOT, uploads=$UP) =="

# ---- 1. Zig 0.17 -----------------------------------------------------
if ! ls tools/zig-*linux*/zig >/dev/null 2>&1; then
  zxz="$(ls "$UP"/zig-*linux*0.17*tar* 2>/dev/null | head -1 || true)"
  [ -n "$zxz" ] || { echo "ERROR: no Zig 0.17 tarball in $UP" >&2; exit 1; }
  echo "extracting Zig: $(basename "$zxz")"
  tar -xf "$zxz" -C tools
fi
ZIGDIR="$(ls -d tools/zig-*linux*/ | head -1)"; ZIGDIR="${ZIGDIR%/}"
chmod +x "$ZIGDIR/zig"

# ---- 2. Bun ----------------------------------------------------------
if [ ! -x tools/bun-linux-x64/bun ]; then
  bz="$(ls "$UP"/bun-linux-x64*.zip 2>/dev/null | head -1 || true)"
  [ -n "$bz" ] || { echo "ERROR: no Bun zip in $UP" >&2; exit 1; }
  echo "extracting Bun: $(basename "$bz")"
  ( cd tools && unzip -q -o "$bz" )
fi
chmod +x tools/bun-linux-x64/bun

# ---- 3. PATH ---------------------------------------------------------
export PATH="$ROOT/tools/bun-linux-x64:$ROOT/$ZIGDIR:$ROOT/tools/zig-out/bin:$PATH"
echo "zig: $(zig version) | bun: $(bun --version)"

# ---- 4. Zig tools (lint_zimr, spv2wgsl, zspv, zglsl, spv2wgsl_check) --
# The obsolete C++ SPIR-V tools (spirv-opt/val/cross) are OFF by default
# in tools/build.zig; pass -Dspirv-tools=true only for the dying GLSL path.
echo "building Zig tools (tools/build.zig)..."
zig build --build-file tools/build.zig
echo "tools: $(ls tools/zig-out/bin 2>/dev/null | tr '\n' ' ')"

# ---- 5. pipeline proof: the compute-smoke standalone -----------------
echo "building compute-smoke standalone (pure-Zig pipeline proof)..."
zig build wgpu-compute-smoke-standalone
html="prebuilt/standalone/wgpu_compute_smoke.html"
[ -f "$html" ] && echo "standalone OK: $(wc -c < "$html") bytes -> $html"

# ---- 6. naga WGSL validator (optional; build-time only) --------------
NAGA="$ROOT/tools/naga-prebuilt-linux-x86_64/naga"
if [ -x "$NAGA" ]; then
  echo "naga: already staged ($("$NAGA" --version 2>&1))"
elif command -v cargo >/dev/null 2>&1; then
  wt="$ROOT/../wgpu-trunk"
  if [ ! -d "$wt" ]; then
    wz="$(ls "$UP"/wgpu-trunk*.zip 2>/dev/null | head -1 || true)"
    [ -n "$wz" ] && { echo "extracting wgpu-trunk..."; ( cd "$ROOT/.." && unzip -q -o "$wz" ); }
  fi
  if [ -d "$wt" ]; then
    echo "building naga (cargo build --release -p naga-cli)..."
    ( cd "$wt" && cargo build --release -p naga-cli )
    mkdir -p "$(dirname "$NAGA")"
    cp "$wt/target/release/naga" "$NAGA"; chmod +x "$NAGA"
    echo "naga staged: $("$NAGA" --version 2>&1)"
  else
    echo "naga: skipped (no wgpu-trunk source in $UP)"
  fi
else
  echo "naga: skipped (cargo not on PATH; needed only for the validation gates)"
fi

echo ""
echo "== bootstrap done =="
echo "verify shaders:  ./scripts/naga-validate-corpus.sh"
echo "lint:            zig build lint"
echo "eval PATH into your shell:"
echo "  export PATH=\"$ROOT/tools/bun-linux-x64:$ROOT/$ZIGDIR:$ROOT/tools/zig-out/bin:\$PATH\""
