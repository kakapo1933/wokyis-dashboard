#!/bin/bash
# stop.sh — stop the panel (spec §10): SIGTERM, wait up to 6 s (0.2 s steps), SIGKILL only if still alive (said so),
# then check that no WokyisPanel and no system_profiler child of it remain. Never deletes any file.
# Children are tracked while waiting (pgrep -P every step, again right before SIGKILL), because a child that outlives
# the panel is re-parented to launchd (ppid 1) and can no longer be found by its ppid. The final check therefore also
# reports any system_profiler running the panel's exact command line (-json -timeout 10 SPBluetoothDataType) with
# ppid 1 (an orphan of a panel) or ppid = the panel.
set -uo pipefail
. "$(dirname "$0")/_common.sh"
SP_ARGS='-json -timeout 10 SPBluetoothDataType'
track() { kids="$kids $(pgrep -P "$1" 2>/dev/null | tr '\n' ' ')"; }
p=$(panel_pid)
kids=""
if [ -z "$p" ]; then
  echo "stop.sh: no running panel in $PIDFILE"
else
  track "$p"
  kill -TERM "$p"
  i=0
  while kill -0 "$p" 2>/dev/null && [ $i -lt 30 ]; do track "$p"; sleep 0.2; i=$((i + 1)); done
  if kill -0 "$p" 2>/dev/null; then
    track "$p"
    echo "stop.sh: pid $p still alive after 6 s — sending SIGKILL"
    kill -KILL "$p" 2>/dev/null || true
    sleep 0.3
  else
    echo "stop.sh: pid $p exited after SIGTERM (within $((i * 200 + 200)) ms)"
  fi
  for k in $(echo "$kids" | tr ' ' '\n' | sed '/^$/d' | sort -u); do
    c=$(ps -o comm= -p "$k" 2>/dev/null | sed 's#.*/##'); kp=$(ps -o ppid= -p "$k" 2>/dev/null | tr -d ' ')
    # only a child that is still ours (ppid = panel, or re-parented to launchd) — never a reused pid
    if { [ "$c" = "system_profiler" ] || [ "$c" = "sleep" ]; } && { [ "$kp" = "$p" ] || [ "$kp" = 1 ]; }; then   # sleep = `hang bat.sp` stand-in
      echo "stop.sh: leftover child $c $k of pid $p — killing"; kill -KILL "$k" 2>/dev/null || true
    fi
  done
  sleep 0.1
fi
left=$(pgrep -x WokyisPanel | tr '\n' ' ')
orph=""
for sp in $(pgrep -x system_profiler 2>/dev/null); do
  pp=$(ps -o ppid= -p "$sp" | tr -d ' ')
  args=$(ps -o args= -p "$sp" 2>/dev/null)
  if { [ -n "$p" ] && [ "$pp" = "$p" ]; } || { [ "$pp" = 1 ] && [ "${args#*"$SP_ARGS"}" != "$args" ]; }; then orph="$orph $sp(ppid=$pp)"; fi
done
for k in $(echo "$kids" | tr ' ' '\n' | sed '/^$/d' | sort -u); do
  kp=$(ps -o ppid= -p "$k" 2>/dev/null | tr -d ' ')
  if [ -n "$kp" ] && { [ "$kp" = "${p:-x}" ] || [ "$kp" = 1 ]; }; then orph="$orph $k($(ps -o comm= -p "$k" | sed 's#.*/##'))"; fi
done
tracked=$(echo "$kids" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')
echo "check: WokyisPanel processes: ${left:-none}; children seen while stopping: ${tracked:-none}; leftover panel system_profiler / children (ppid ${p:-?} or orphaned to 1): ${orph:-none}"
if [ -e "$LOG_DIR/current.log" ]; then echo "--- last log lines ($LOG_DIR/current.log)"; tail -3 "$LOG_DIR/current.log"; fi
echo "The Wokyis now shows its desktop Space: move the pointer onto the Wokyis and press Ctrl+→, or click Music in the Dock."
[ -z "$left" ] && [ -z "$orph" ]
