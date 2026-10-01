#!/bin/bash
# snapshot.sh — SIGUSR1 → the panel renders the state on screen to run/snapshot-<ts>.{png,rects.tsv,perglyph.tsv,boxes.tsv,state.json}.
set -euo pipefail
. "$(dirname "$0")/_common.sh"
p=$(panel_pid); [ -n "$p" ] || { echo "snapshot.sh: panel not running" >&2; exit 1; }
marker=$(mktemp "${TMPDIR:-/tmp}/wokyis_snap.XXXXXX"); trap 'rm -f "$marker"' EXIT
sleep 0.05
kill -USR1 "$p"
for _ in $(seq 1 50); do
  f=$(find "$RUN_DIR" -maxdepth 1 -name 'snapshot-*.state.json' -newer "$marker" 2>/dev/null | sort | tail -1)
  if [ -n "$f" ]; then b=${f%.state.json}; ls -1 "$b".*; exit 0; fi
  sleep 0.1
done
echo "snapshot.sh: no snapshot within 5 s" >&2; exit 1
