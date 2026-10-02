#!/bin/bash
# c7_measure.sh — criterion #7 (panel + all its children: 5-min average CPU < 2 % of one core, memory < 150 MB).
#
# usage: tools/c7_measure.sh PID [SECONDS=300] [--out DIR=evidence/c7/visible] [--settle 60] [--interval 2] [--no-top]
#        tools/c7_measure.sh launch [SECONDS=300] [--view memory|cpu|network] [--binary PATH] [--panel-arg ARG]…
#                           [--sim "pressure red 92"] [same options as above]
#
#  launch mode (v2, spec §11.4): refuses when a panel is already running (scripts/stop.sh first); starts --binary
#     (default build/WokyisPanel.app/Contents/MacOS/WokyisPanel; e.g. build/WokyisPanel-v1 for the v1 A/B side) with
#     --log-dir logs --run-dir run [--view V] [--panel-arg …] (CLI only: nothing is written to the saved settings),
#     waits for run/panel.pid, optionally applies scripts/sim.sh ARGS --for (settle + SECONDS + 60, ≤ 900), measures, then
#     clears the simulation and stops the panel (SIGTERM). It never restarts the user's panel: scripts/start.sh --bg.
#     --view is a v2 flag; leave it out for the v1 binary (v1 shows the memory view).
#  1. settle (default 60 s) so start-up work is not measured
#  2. ps before: the process group and every descendant of PID  (ps -o pid,ppid,pgid,time,rss,%cpu,comm)
#  3. tools/bin/procstat --pid PID --duration SECONDS --interval 2 --csv procstat.csv  (CPU from proc_pid_rusage of the
#     whole tree incl. reaped children such as system_profiler; phys_footprint + RSS)
#     in parallel (unless --no-top): top -l N -s 2 -pid PID -stats pid,command,cpu,mem  → top.txt (cross-check)
#     NOTE: top calls host statistics; never run this while a criterion-#4 run or a memory gate is in progress.
#  4. ps after; verdict.txt: avg_cpu_pct_1core < 2 and footprint max < 150 MB (phys_footprint is the primary memory
#     figure = Activity Monitor's "Memory" column; RSS reported alongside). MB = 2^20 bytes.
#  5. from the panel's own log (logs/panel-*.log whose START has pid=PID; HEALTH every 60 s; health.tsv):
#     health_max5_cpu_pct = max over HEALTH pairs ≈ 300 s apart (≥ 295 s) inside the measured window of
#     Δcpu_s / Δt (panel process + its reaped children such as system_profiler, proc_pid_rusage ri_child_*; "-" when
#     the window is < 5 min), passes_per_s, draw_ms_avg,
#     mem_hz, sys_dur_us_p99, view. Reported in verdict.txt; they do not change the verdict (tools/c7_ab.sh uses them).
# Exit: 0 PASS, 1 FAIL, 2 usage / process gone. bash 3.2 compatible.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/.." && pwd)
pid=${1:-}; [ -n "$pid" ] || { sed -n '2,29p' "$0"; exit 2; }
shift
launch=0; [ "$pid" = launch ] && { launch=1; pid=""; }
secs=300
if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then secs=$1; shift; fi
out="$root/evidence/c7/visible"; settle=60; interval=2; notop=0
view=""; binary="$root/build/WokyisPanel.app/Contents/MacOS/WokyisPanel"; binary_set=0; panel_args=(); simargs=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out=$2; shift 2;; --settle) settle=$2; shift 2;; --interval) interval=$2; shift 2;; --no-top) notop=1; shift;;
    --view) view=$2; shift 2;; --binary) binary=$2; binary_set=1; shift 2;;
    --panel-arg) panel_args+=("$2"); shift 2;; --sim) simargs=$2; shift 2;;
    *) echo "unknown argument $1" >&2; exit 2;;
  esac
done
case "$view" in ""|memory|cpu|network) ;; *) echo "--view memory|cpu|network (got '$view')" >&2; exit 2;; esac
if [ "$launch" -eq 0 ] && { [ -n "$view" ] || [ "$binary_set" -eq 1 ] || [ "${#panel_args[@]}" -gt 0 ] || [ -n "$simargs" ]; }; then
  echo "--view / --binary / --panel-arg / --sim start their own panel: use 'tools/c7_measure.sh launch …'" >&2; exit 2
fi
mkdir -p "$out"
PS="$here/bin/procstat"; [ -x "$PS" ] || { echo "missing $PS — run tools/build.sh" >&2; exit 2; }
logdir="$root/logs"; rundir="$root/run"

launched=""
cleanup() {
  [ -n "$launched" ] || return 0
  [ -n "$simargs" ] && "$root/scripts/sim.sh" clear > /dev/null 2>&1 || true
  if kill -0 "$launched" 2>/dev/null; then
    kill -TERM "$launched" 2>/dev/null || true
    for _ in $(seq 1 50); do kill -0 "$launched" 2>/dev/null || break; sleep 0.3; done
  fi
  launched=""
}
if [ "$launch" -eq 1 ]; then
  [ -x "$binary" ] || { echo "missing binary $binary" >&2; exit 2; }
  if pgrep -x WokyisPanel > /dev/null; then
    echo "a WokyisPanel is already running (pid $(pgrep -x WokyisPanel | tr '\n' ' ')) — scripts/stop.sh first; launch mode measures its own panel" >&2
    exit 2
  fi
  mkdir -p "$logdir" "$rundir"
  args=(--log-dir "$logdir" --run-dir "$rundir")
  [ -n "$view" ] && args+=(--view "$view")
  [ "${#panel_args[@]}" -gt 0 ] && args+=("${panel_args[@]}")
  trap cleanup EXIT
  trap 'exit 130' INT TERM
  ( cd "$root" && exec nohup "$binary" "${args[@]}" > "$out/stdout.log" 2>&1 < /dev/null ) &
  launched=$!; pid=$launched
  for _ in $(seq 1 34); do
    [ -f "$rundir/panel.pid" ] && [ "$(tr -cd '0-9' < "$rundir/panel.pid")" = "$pid" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.3
  done
  kill -0 "$pid" 2>/dev/null || { echo "launched panel exited at once; see $out/stdout.log" >&2; tail -5 "$out/stdout.log" >&2; launched=""; exit 2; }
  echo "c7_measure: launched $binary ${args[*]} → pid $pid"
  if [ -n "$simargs" ]; then
    simfor=$(( settle + secs + 60 )); [ "$simfor" -gt 900 ] && simfor=900
    # shellcheck disable=SC2086
    "$root/scripts/sim.sh" $simargs --for "$simfor" > "$out/sim.txt" 2>&1 || { echo "sim.sh $simargs failed (see $out/sim.txt)" >&2; exit 2; }
  fi
fi
kill -0 "$pid" 2>/dev/null || { echo "process $pid not running" >&2; exit 2; }

tree_ps() {   # header + the process group of $pid + all descendants of $pid
  local pgid; pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
  echo "# $(date '+%Y-%m-%dT%H:%M:%S%z') $1 — pgid $pgid"
  ps -A -o pid=,ppid=,pgid=,time=,rss=,%cpu=,comm= | awk -v root="$pid" -v pg="$pgid" '
    { pid[NR]=$1; ppid[NR]=$2; pgid[NR]=$3; line[NR]=$0; kid[$2]=kid[$2] " " $1 }
    END { want[root]=1; changed=1
          while (changed) { changed=0; for (i=1;i<=NR;i++) if (!want[pid[i]] && want[ppid[i]]) { want[pid[i]]=1; changed=1 } }
          printf "%7s %7s %7s %12s %8s %5s %s\n", "PID", "PPID", "PGID", "TIME", "RSS_KB", "%CPU", "COMM"
          for (i=1;i<=NR;i++) if (want[pid[i]] || pgid[i]==pg) print line[i] }'
}

echo "c7_measure: pid $pid, settle ${settle}s, measure ${secs}s every ${interval}s → $out"
[ "$settle" -gt 0 ] && sleep "$settle"
kill -0 "$pid" 2>/dev/null || { echo "process $pid exited during settle" >&2; exit 2; }
mstart=$(date '+%Y-%m-%dT%H:%M:%S')   # local wall clock, same basis as the log timestamps (offset ignored)
{ tree_ps "before"; } > "$out/ps-before-after.txt"
toppid=""
if [ "$notop" -eq 0 ]; then
  n=$(( secs / 2 + 1 ))
  top -l "$n" -s 2 -pid "$pid" -stats pid,command,cpu,mem > "$out/top.txt" 2>&1 &
  toppid=$!
fi
set +e
"$PS" --pid "$pid" --duration "$secs" --interval "$interval" --csv "$out/procstat.csv" --quiet > "$out/procstat_summary.txt"
prc=$?
set -e
[ -n "$toppid" ] && wait "$toppid" 2>/dev/null || true
{ echo; tree_ps "after"; } >> "$out/ps-before-after.txt"
mend=$(date '+%Y-%m-%dT%H:%M:%S')
cleanup   # launch mode: clear the simulation, stop the panel we started (the log is complete after STOP)

# HEALTH statistics from the panel's own log (all rotations of the file whose START line has pid=$pid)
plog=$(grep -l -E " START .*pid=$pid( |$)" "$logdir"/panel-*.log 2>/dev/null | tail -1 || true)
hstats="-	-	-	-	-	-	-"
if [ -n "$plog" ]; then
  base=${plog%.log}; segs=("$plog")
  for f in "$base"-[0-9][0-9][0-9].log; do [ -f "$f" ] && segs+=("$f"); done   # rotations (no match → literal, skipped)
  hstats=$(cat "${segs[@]}" | "$here/c7_health.pl" "$mstart" "$mend" "$out/health.tsv") || hstats="-	-	-	-	-	-	-"
fi
IFS='	' read -r hmax5 hpass hdraw hmemhz hsysp99 hview hn <<< "$hstats"

cpu=$(awk -F'[= ]' '/^avg_cpu_pct_1core=/{print $2}' "$out/procstat_summary.txt")
fp=$(awk '/^footprint_mb /{split($2,a,"="); print a[2]}' "$out/procstat_summary.txt")
rss=$(awk '/^footprint_mb /{for(i=1;i<=NF;i++) if ($i=="rss_mb") {split($(i+1),a,"="); print a[2]}}' "$out/procstat_summary.txt")
wall=$(awk -F'[= ]' '/^wall_s=/{print $2}' "$out/procstat_summary.txt")
ok_cpu=$(awk -v c="${cpu:-999}" 'BEGIN{print (c<2)?"PASS":"FAIL"}')
ok_fp=$(awk -v m="${fp:-999999}" 'BEGIN{print (m<150)?"PASS":"FAIL"}')
verdict=PASS; { [ "$ok_cpu" = PASS ] && [ "$ok_fp" = PASS ] && [ "$prc" -eq 0 ]; } || verdict=FAIL
cat > "$out/verdict.txt" <<EOF
# criterion #7 — $(date '+%Y-%m-%dT%H:%M:%S%z') pid $pid (tree incl. children), settle ${settle}s, window ${wall:-?}s, interval ${interval}s
avg_cpu_pct_1core	${cpu:-?}	< 2	$ok_cpu
footprint_mb_max	${fp:-?}	< 150	$ok_fp
rss_mb_max	${rss:-?}	(reported, not the criterion's primary figure)
procstat_rc	$prc	$( [ "$prc" -eq 4 ] && echo "ROOT EXITED EARLY" || echo ok )
top_crosscheck	$( [ "$notop" -eq 1 ] && echo "skipped (--no-top)" || echo "top.txt" )
health_max5_cpu_pct	${hmax5}	(HEALTH cpu_s, max 5-min sliding window, panel + reaped children; reported)
passes_per_s	${hpass}
draw_ms_avg	${hdraw}
mem_hz	${hmemhz}
sys_dur_us_p99	${hsysp99}
view	${hview}
health_points	${hn}	${plog:-no panel log with START pid=$pid}
binary	$( [ "$launch" -eq 1 ] && echo "$binary" || ps -o comm= -p "$pid" 2>/dev/null || echo "?" )	$( [ "$launch" -eq 1 ] && echo "launch ${view:+--view $view }${panel_args[*]:-}${simargs:+ sim: $simargs}" || echo "pid $pid" )
verdict	$verdict
EOF
cat "$out/verdict.txt"
[ "$verdict" = PASS ] && exit 0 || exit 1
