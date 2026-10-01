#!/bin/bash
# status.sh — pid, elapsed time, CPU / RSS / CPU time, last MEM / BAT / SP / DSP times, free mode, control state.
set -uo pipefail
. "$(dirname "$0")/_common.sh"
p=$(panel_pid)
if [ -z "$p" ]; then echo "panel: not running"; else
  echo "panel: pid $p"; ps -o pid=,etime=,%cpu=,rss=,time= -p "$p" | awk '{printf "  etime %s  cpu %s%%  rss %.1f MB  cputime %s\n",$2,$3,$4/1024,$5}'
  kids=$(pgrep -P "$p" | tr '\n' ' '); echo "  children: ${kids:-none}"
fi
L="$LOG_DIR/current.log"
if [ -e "$L" ]; then
  echo "log: $(readlink "$L") ($(du -hL "$L" | cut -f1))"
  for k in START MEM DSP BAT SP AUD ERR WIN; do
    line=$(grep " $k " "$L" | tail -1)
    [ -n "$line" ] && echo "  last $k: $(echo "$line" | cut -c1-160)"
  done
  m=$(grep -o ' mode=[a-z]*' "$L" | tail -1); echo "  free${m:- mode=?}"
fi
if [ -s "$RUN_DIR/control.json" ]; then echo "control.json: $(tr -d '\n' < "$RUN_DIR/control.json")"; else echo "control.json: empty/none"; fi
