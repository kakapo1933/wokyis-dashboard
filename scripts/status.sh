#!/bin/bash
# status.sh — pid, elapsed time, CPU / RSS / CPU time, last MEM / BAT / SP / DSP / CPU / NET / UI lines, free mode,
# current view / language / battery column (START line + later UI events of the same run), control state.
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
  for k in START MEM DSP CPU NET BAT SP AUD UI ERR WIN; do
    line=$(grep " $k " "$L" | tail -1)
    [ -n "$line" ] && echo "  last $k: $(echo "$line" | cut -c1-160)"
  done
  m=$(grep -o ' mode=[a-z]*' "$L" | tail -1); echo "  free${m:- mode=?}"
  # v2 UI state: START view= battery= lang= lang_resolved=, then UI event=view|battery|lang to= (via menu / hotkey)
  awk '
    function tok(k,   i, a) { for (i = 3; i <= NF; i++) { if (index($i, k "=") == 1) { split($i, a, "="); return a[2] } } return "" }
    $2 == "START" { v = tok("view"); b = tok("battery"); l = tok("lang"); r = tok("lang_resolved"); n = 0 }
    $2 == "UI" && tok("via") != "start" {
      e = tok("event"); t = tok("to")
      if (e == "view") { v = t; n++ } else if (e == "battery") { b = t; n++ } else if (e == "lang") { l = t; r = tok("resolved"); n++ }
      else if (e == "mem_hz") { hz = t }
    }
    END { if (v != "") printf "  ui: view=%s battery=%s lang=%s (resolved %s) changes_since_start=%d%s\n", v, b, l, r, n, (hz != "" ? " mem_hz=" hz : "") }
  ' "$L"
fi
if [ -s "$RUN_DIR/control.json" ]; then echo "control.json: $(tr -d '\n' < "$RUN_DIR/control.json")"; else echo "control.json: empty/none"; fi
