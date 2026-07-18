#!/bin/sh
# Bootstrap helper: stage the prebuilt SPIRV tool binaries into
# tools/zig-out/bin/ so we don't pay the ~12-min cold-build cost
# on a fresh Linux sandbox.  See
# tools/spirv-prebuilt-linux-x86_64/README.md for provenance.
#
# Run from the project root:
#   ./tools/use-prebuilt-spirv.sh
#
# After this, `spirv-opt --version` from tools/zig-out/bin/ works
# and `zig build --build-file tools/build.zig` becomes a near-instant
# no-op for the spirv-tools targets (the installFile step still runs).

set -e

# Resolve paths relative to this script so it works from any CWD.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/spirv-prebuilt-linux-x86_64"
DEST="$SCRIPT_DIR/zig-out/bin"

if [ ! -d "$SRC" ]; then
    echo "ERROR: $SRC missing — nothing to stage." >&2
    exit 1
fi

mkdir -p "$DEST"
for bin in spirv-opt spirv-val spirv-cross; do
    if [ ! -f "$SRC/$bin" ]; then
        echo "ERROR: $SRC/$bin missing — partial prebuilt dir." >&2
        exit 1
    fi
    cp "$SRC/$bin" "$DEST/$bin"
    chmod +x "$DEST/$bin"
done

echo "Staged 3 prebuilt SPIRV binaries to $DEST/:"
ls -la "$DEST"/spirv-opt "$DEST"/spirv-val "$DEST"/spirv-cross
echo
echo "Smoke check:"
"$DEST/spirv-opt" --version
