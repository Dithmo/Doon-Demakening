#!/usr/bin/env bash
# Launch a local session: one headless server plus N clients.
#
# Solo play is a one-client session against a local server -- there is no
# separate offline path, so this is how you run the game at every scale.
#
#   tools/run_session.sh          # server + 1 client
#   tools/run_session.sh 3        # server + 3 clients
#   tools/run_session.sh 2 --auto # server + 2 bot clients (no window)
#
# Ctrl-C tears the whole session down.
set -euo pipefail

CLIENTS="${1:-1}"
shift || true
EXTRA=("$@")

GODOT="${GODOT:-/opt/godot/godot}"
PORT="${DOON_PORT:-27015}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -x "$GODOT" ]]; then
  echo "No Godot binary at $GODOT (set \$GODOT)" >&2
  exit 1
fi

# A new class_name script is invisible to headless runs until the project is
# rescanned, so make sure the global class cache exists before launching.
if [[ ! -f "$ROOT/.godot/global_script_class_cache.cfg" ]]; then
  echo "[run] first-time import..."
  "$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
fi

PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "[run] server on :$PORT"
"$GODOT" --headless --path "$ROOT" -- --server --port "$PORT" "${EXTRA[@]}" &
PIDS+=($!)
sleep 2

for i in $(seq 1 "$CLIENTS"); do
  echo "[run] client $i"
  "$GODOT" --path "$ROOT" -- --client --port "$PORT" \
      --identity "player$i" "${EXTRA[@]}" &
  PIDS+=($!)
  sleep 0.5
done

wait
