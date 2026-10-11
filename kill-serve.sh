#!/usr/bin/env sh
# kill-serve.sh - kill whatever is listening on the dev server's port.
# Use when a dev server (`zig build serve` / `serve-only`, tools/serve.zig)
# from an earlier session still holds it. PORT defaults to 8080, the one
# serve.zig listens on. A new serve uses a running one of the same directory
# as it is, so this is for one serving another directory, an older serve that
# does not say what it serves, or any other program on the port.

PORT=${PORT:-8080}

PIDS=$(lsof -ti :"$PORT" 2>/dev/null || true)
if [ -z "$PIDS" ]; then
    echo "No process listening on port $PORT."
    exit 0
fi

for PID in $PIDS; do
    echo "Killing PID $PID on port $PORT..."
    kill -9 "$PID"
done
