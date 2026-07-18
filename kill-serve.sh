#!/usr/bin/env sh
# kill-serve.sh - kill whatever is holding the bun dev server port.
# Use when `zig build serve` reports "Is port 8000 in use?".

PORT=${PORT:-8000}

PIDS=$(lsof -ti :"$PORT" 2>/dev/null || true)
if [ -z "$PIDS" ]; then
    echo "No process listening on port $PORT."
    exit 0
fi

for PID in $PIDS; do
    echo "Killing PID $PID on port $PORT..."
    kill -9 "$PID"
done
