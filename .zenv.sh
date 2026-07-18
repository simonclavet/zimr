# Resolve the Zig toolchain by GLOB, never by a pinned version string: this file
# sat stale for months naming a `0.17.0-dev.704` dir that had long since been
# replaced in tools/, so `source .zenv.sh` silently put no zig on PATH at all.
ZIG_DIR="$(ls -d "$PWD"/tools/zig-x86_64-linux-*/ 2>/dev/null | tail -1)"
export PATH="$PWD/tools/bun-linux-x64:${ZIG_DIR%/}:$PWD/tools/zig-out/bin:$PATH"
