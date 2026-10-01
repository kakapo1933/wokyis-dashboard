# _common.sh — shared helpers for scripts/*.sh (sourced, bash 3.2). Owner: app agent.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN="$ROOT/build/WokyisPanel.app/Contents/MacOS/WokyisPanel"
RUN_DIR="$ROOT/run"
LOG_DIR="$ROOT/logs"
PIDFILE="$RUN_DIR/panel.pid"

# Prints the pid of the running panel (from run/panel.pid) or nothing.
panel_pid() {
  local p
  [ -f "$PIDFILE" ] || return 0
  p=$(tr -cd '0-9' < "$PIDFILE")
  [ -n "$p" ] || return 0
  if kill -0 "$p" 2>/dev/null && [ "$(ps -o comm= -p "$p" 2>/dev/null | sed 's#.*/##')" = "WokyisPanel" ]; then
    echo "$p"
  fi
}
