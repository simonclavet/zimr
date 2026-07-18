#!/usr/bin/env bash
# validate_wgsl.sh — fast WGSL sanity check using naga (a DEV ACCELERATOR, not a
# test dependency: the real correctness tests stay pure-Zig + CPU-oracle +
# on-device). naga catches type errors, undeclared identifiers, bad bindings,
# and many other WGSL mistakes in milliseconds — far faster than a device round
# trip. (Note: naga does NOT flag workgroupBarrier-in-non-uniform-control-flow;
# spv2wgsl itself rejects that at transpile time — see checkBarrierUniformity.)
#
# Build naga once (needs the provided Rust toolchain + wgpu source):
#   cargo build --release -p naga-cli   # in the wgpu checkout
#   cp target/release/naga zimr/tools/naga
#
# Usage:
#   tools/validate_wgsl.sh                 # validate every generated compute.wgsl in .zig-cache
#   tools/validate_wgsl.sh a.wgsl b.wgsl   # validate specific files
set -u
NAGA="$(dirname "$0")/naga"
if [ ! -x "$NAGA" ]; then
  echo "naga not found at $NAGA — build it (see header) to use this check." >&2
  exit 0  # absence is not a failure: this is an optional dev aid
fi

files=("$@")
if [ ${#files[@]} -eq 0 ]; then
  mapfile -t files < <(find .zig-cache -name 'compute.wgsl' 2>/dev/null)
fi
if [ ${#files[@]} -eq 0 ]; then
  echo "no .wgsl files to validate."
  exit 0
fi

fail=0
for f in "${files[@]}"; do
  out="$("$NAGA" --shader-stage compute --stdin-file-path "$(basename "$f")" < "$f" 2>&1)"
  if echo "$out" | grep -q "Validation successful"; then
    echo "PASS  $f"
  else
    echo "FAIL  $f"
    echo "$out" | sed 's/^/      /'
    fail=1
  fi
done
exit $fail
