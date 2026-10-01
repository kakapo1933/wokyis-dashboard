#!/bin/bash
# fullscreen.sh — SIGUSR2 → the panel (re)enters full screen on the Wokyis (after you left full screen, or after a
# display change closed its window). After you left full screen the panel never does this by itself; after a display
# change it re-creates the window by itself once the Wokyis is back and stable (--auto-recover, ≤ 3 per 10 min) —
# this script is the manual path when that is off, limited, or not applicable (fs_failed ×3, user-windowed).
set -euo pipefail
. "$(dirname "$0")/_common.sh"
p=$(panel_pid); [ -n "$p" ] || { echo "fullscreen.sh: panel not running" >&2; exit 1; }
kill -USR2 "$p"; echo "sent SIGUSR2 to $p"
