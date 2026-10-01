#!/bin/bash
# c7_measure.sh — criterion #7 (panel + all its children: 5-min average CPU < 2 % of one core, memory < 150 MB).
#
# usage: tools/c7_measure.sh PID [SECONDS=300] [--out DIR=evidence/c7/visible] [--settle 60] [--interval 2] [--no-top]
#
#  1. settle (default 60 s) so start-up work is not measured
#  2. ps before: the process group and every descendant of PID  (ps -o pid,ppid,pgid,time,rss,%cpu,comm)
#  3. tools/bin/procstat --pid PID --duration SECONDS --interval 2 --csv procstat.csv  (CPU from proc_pid_rusage of the
#     whole tree incl. reaped children such as system_profiler; phys_footprint + RSS)
#     in parallel (unless --no-top): top -l N -s 2 -pid PID -stats pid,command,cpu,mem  → top.txt (cross-check)
#     NOTE: top calls host statistics; never run this while a criterion-#4 run or a memory gate is in progress.
#  4. ps after; verdict.txt: avg_cpu_pct_1core < 2 and footprint max < 150 MB (phys_footprint is the primary memory
#     figure = Activity Monitor's "Memory" column; RSS reported alongside). MB = 2^20 bytes.
# Exit: 0 PASS, 1 FAIL, 2 usage / process gone. bash 3.2 compatible.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/.." && pwd)
pid=${1:-}; [ -n "$pid" ] || { sed -n '2,16p' "$0"; exit 2; }
shift
secs=300
if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then secs=$1; shift; fi
out="$root/evidence/c7/visible"; settle=60; interval=2; notop=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out=$2; shift 2;; --settle) settle=$2; shift 2;; --interval) interval=$2; shift 2;; --no-top) notop=1; shift;;
    *) echo "unknown argument $1" >&2; exit 2;;
  esac
done
kill -0 "$pid" 2>/dev/null || { echo "process $pid not running" >&2; exit 2; }
mkdir -p "$out"
PS="$here/bin/procstat"; [ -x "$PS" ] || { echo "missing $PS — run tools/build.sh" >&2; exit 2; }

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
verdict	$verdict
EOF
cat "$out/verdict.txt"
[ "$verdict" = PASS ] && exit 0 || exit 1
