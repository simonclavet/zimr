#!/usr/bin/env sh
# zimr — launch a local web server for the prebuilt examples.
#
# Unix companion to launch.bat.  Requires Python 3.  No build step
# needed — the wasm files and gallery page are already in `prebuilt/`.

PORT=${PORT:-8000}

# Need a prebuilt/ directory to serve.  Generate it via release.sh
# (or `zig build -Drelease=true dist`) if it's missing.
if [ ! -d "$(dirname "$0")/prebuilt" ]; then
    echo
    echo "prebuilt/ not found.  Run ./release.sh first to generate it,"
    echo "or 'zig build -Drelease=true dist' if you don't want to push."
    exit 1
fi

# Pick a Python.  Prefer python3, then python.
if command -v python3 >/dev/null 2>&1; then
    PY=python3
elif command -v python >/dev/null 2>&1; then
    PY=python
else
    echo "Python 3 not found on PATH.  Install python3 and try again."
    exit 1
fi

echo
echo "zimr examples gallery"
echo "---------------------"
echo " Serving prebuilt/ on http://localhost:$PORT/"
echo " Press Ctrl+C to stop."
echo

# Best-effort browser open — silently no-op if no `open`/`xdg-open`.
URL="http://localhost:$PORT/"
if command -v open >/dev/null 2>&1; then
    open "$URL" >/dev/null 2>&1 &
elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$URL" >/dev/null 2>&1 &
fi

cd "$(dirname "$0")/prebuilt"
exec $PY -m http.server "$PORT"
