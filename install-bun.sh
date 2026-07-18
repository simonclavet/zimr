#!/usr/bin/env sh
# install-bun.sh - install bun via the official installer.
# Bun is required for `zig build serve` (dev hot-reload) and the
# smoke tests.  Static viewing of prebuilt/ via serve.sh does NOT
# need bun -- only Python.

if command -v bun >/dev/null 2>&1; then
    echo "bun already installed:"
    bun --version
    exit 0
fi

echo "bun not found.  Installing from https://bun.sh/install ..."
echo

if ! command -v curl >/dev/null 2>&1; then
    echo "curl not found.  Install curl, or follow https://bun.sh/docs/installation"
    exit 1
fi

curl -fsSL https://bun.sh/install | bash

echo
echo "bun installed.  You may need to open a new shell for PATH to update."
