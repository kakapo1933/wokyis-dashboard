#!/bin/bash
# start.sh [--bg] [-- PANEL ARGS…] — start the Wokyis panel (spec §10). Single instance (run/panel.pid).
#   foreground (default): exec the panel; stdout = SUM line every --summary-seconds + events; Ctrl+C stops it
#                         (a second Ctrl+C exits at once with 130). In Claude Code: Bash with run_in_background: true.
#   --bg:                 nohup in the background, stdout → logs/stdout-<ts>.log; prints the pid; stop with scripts/stop.sh.
# The panel writes its own log (logs/current.log); nothing is tee'd. Extra args go to WokyisPanel (e.g. --log-level sample).
set -euo pipefail
. "$(dirname "$0")/_common.sh"
bg=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bg) bg=1; shift ;;
    --) shift; break ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) break ;;
  esac
done
[ -x "$BIN" ] || { echo "start.sh: $BIN missing — run scripts/build.sh first" >&2; exit 1; }
p=$(panel_pid)
if [ -n "$p" ]; then echo "start.sh: panel already running (pid $p) — scripts/stop.sh first" >&2; exit 1; fi
mkdir -p "$LOG_DIR" "$RUN_DIR"
cd "$ROOT"
if [ "$bg" = 1 ]; then
  out="$LOG_DIR/stdout-$(date +%Y%m%d-%H%M%S).log"
  nohup "$BIN" --log-dir "$LOG_DIR" --run-dir "$RUN_DIR" "$@" > "$out" 2>&1 < /dev/null &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$PIDFILE" ] && [ "$(tr -cd '0-9' < "$PIDFILE")" = "$pid" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.3
  done
  if ! kill -0 "$pid" 2>/dev/null; then echo "start.sh: panel exited at once; see $out" >&2; tail -5 "$out" >&2; exit 1; fi
  echo "panel started in background: pid $pid"
  echo "  stdout: $out"
  echo "  log:    $LOG_DIR/current.log   (scripts/logs.sh to follow, scripts/status.sh, scripts/stop.sh to stop)"
else
  exec "$BIN" --log-dir "$LOG_DIR" --run-dir "$RUN_DIR" "$@"
fi
