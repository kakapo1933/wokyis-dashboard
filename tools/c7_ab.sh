#!/bin/bash
# c7_ab.sh — v1 / v2 CPU-budget A/B matrix (spec §11.4, criterion #7). Runs tools/c7_measure.sh launch once per
# (round, cell, binary, view), alternating v1 and v2 inside every round, and summarises the max 5-minute windows.
#
# usage: tools/c7_ab.sh [--rounds 3] [--seconds 300] [--settle 60] [--cells C1,C2,C3,C4,C5] [--views memory,cpu,network]
#                       [--v1 build/WokyisPanel-v1] [--out evidence/c7/ab-<ts>] [--dry-run]
#        tools/c7_ab.sh --summarize DIR      # re-write DIR/summary.md from DIR/results.tsv (no measurement)
#
# Cells (every cell is run for every --views view on v2; v1 = memory view only, and only where v1 has the setting):
#   C1 default (summary log level, no simulation, battery column, zh)     v2 + v1
#   C2 simulated pressure red: scripts/sim.sh pressure red 92              v2 + v1
#   C3 --log-level sample                                                 v2 + v1
#   C4 battery column off: --battery no                                   v2
#   C5 English: --lang en                                                 v2
# v2 runs pass --view / --battery / --lang on the command line only (never saved; the user's settings stay as they are).
# The v1 side needs a kept v1 build at --v1 (default build/WokyisPanel-v1); when it is missing the v1 rows are skipped
# and the summary says so (no v2 − v1 delta).
# Prerequisites: no panel running (scripts/stop.sh), the Wokyis connected, Activity Monitor and other heavy apps closed.
# Each run is settle + seconds (default 6 min); the full default matrix (5 cells × 4 targets × 3 rounds) is ≈ 6 h.
# The panel is NOT restarted afterwards: scripts/start.sh --bg.
# Output: DIR/results.tsv (one row per run), DIR/<run>/ (c7_measure output incl. verdict.txt, health.tsv),
#         DIR/summary.md (per cell / binary / view: rounds, mean 5-min average, max of the max 5-min windows, pass/s,
#         v2 − v1 on the memory view, PASS = every v2 max 5-min window < 2.0 %, design target C1 ≤ 1.8 %, and the §11.4
#         decision ladder step that applies).
# Exit: 0 every v2 window < 2.0 %, 1 some ≥ 2.0 % (or a run without a 5-min window), 2 usage / a run could not start.
# bash 3.2 compatible.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/.." && pwd)
rounds=3; secs=300; settle=60; cells="C1,C2,C3,C4,C5"; views="memory,cpu,network"; v1="$root/build/WokyisPanel-v1"
out="$root/evidence/c7/ab-$(date +%Y%m%d-%H%M%S)"; dry=0; summarize=""
v2="$root/build/WokyisPanel.app/Contents/MacOS/WokyisPanel"
while [ $# -gt 0 ]; do
  case "$1" in
    --rounds) rounds=$2; shift 2;; --seconds) secs=$2; shift 2;; --settle) settle=$2; shift 2;;
    --cells) cells=$2; shift 2;; --views) views=$2; shift 2;; --v1) v1=$2; shift 2;; --out) out=$2; shift 2;;
    --dry-run) dry=1; shift;; --summarize) summarize=$2; shift 2;;
    -h|--help) sed -n '2,29p' "$0"; exit 0;;
    *) echo "unknown argument $1" >&2; exit 2;;
  esac
done

cell_args() {   # CELL → c7_measure options (one per line) for the panel / simulation
  case "$1" in
    C1) ;;
    C2) printf '%s\n' --sim "pressure red 92";;
    C3) printf '%s\n' --panel-arg --log-level --panel-arg sample;;
    C4) printf '%s\n' --panel-arg --battery --panel-arg no;;
    C5) printf '%s\n' --panel-arg --lang --panel-arg en;;
    *) return 1;;
  esac
}
cell_has_v1() { case "$1" in C1|C2|C3) return 0;; *) return 1;; esac; }
cell_about() {
  case "$1" in
    C1) echo "default (summary, no simulation, battery column, zh)";; C2) echo "sim.sh pressure red 92";;
    C3) echo "--log-level sample";; C4) echo "--battery no";; C5) echo "--lang en";;
  esac
}

summarize() {   # DIR → DIR/summary.md; exit status 0 all < 2.0 %, 1 otherwise
  local dir=$1 res="$1/results.tsv"
  [ -f "$res" ] || { echo "missing $res" >&2; return 2; }
  awk -F'\t' -v now="$(date '+%Y-%m-%dT%H:%M:%S%z')" -v v1note="$(cat "$dir/v1.txt" 2>/dev/null || echo '?')" '
    NR == 1 { next }
    { k = $2 "\t" $3 "\t" $4; if (!(k in n)) { order[++nk] = k }
      n[k]++
      if ($5 != "-" && $5 != "") { avg[k] += $5; na[k]++ }
      if ($6 == "-" || $6 == "") { nowin[k]++ } else if (!(k in mx) || $6 + 0 > mx[k]) mx[k] = $6 + 0
      if ($7 != "-" && $7 != "") { ps[k] += $7; np[k]++ }
      if ($3 == "v2" && $6 != "-" && $6 != "" && $6 + 0 >= 2.0) bad++          # the pass condition is on v2 only
      if ($3 == "v2" && ($6 == "-" || $6 == "")) missing++
      if ($3 == "v2" && $2 == "C1" && $6 != "-" && $6 + 0 >= 1.8) c1hi[$4] = 1
      if ($3 != "v1" && $6 != "-" && $6 + 0 >= 1.8 && ($4 == "cpu" || $4 == "network")) sysHi = 1 }
    END {
      print "# c7 A/B — CPU budget (spec §11.4) — " now
      print ""
      print "v1 binary: " v1note
      print ""
      print "| cell | binary | view | runs | mean 5-min avg % (procstat, tree) | max 5-min window % (HEALTH) | pass/s | v2 − v1 (max window) |"
      print "|---|---|---|---|---|---|---|---|"
      for (i = 1; i <= nk; i++) {
        k = order[i]; split(k, f, "\t")
        d = "-"
        if (f[2] == "v2" && f[3] == "memory") { kv = f[1] "\tv1\tmemory"; if ((kv in mx) && (k in mx)) d = sprintf("%+.3f", mx[k] - mx[kv]) }
        printf "| %s | %s | %s | %d | %s | %s%s | %s | %s |\n", f[1], f[2], f[3], n[k],
          (na[k] ? sprintf("%.3f", avg[k] / na[k]) : "-"), ((k in mx) ? sprintf("%.3f", mx[k]) : "-"),
          (nowin[k] ? " (" nowin[k] " run(s) without a 5-min window)" : ""), (np[k] ? sprintf("%.2f", ps[k] / np[k]) : "-"), d
      }
      print ""
      verdict = (bad || missing) ? "FAIL" : "PASS"
      print "Pass condition (v2): every max 5-min window < 2.0 % → **" verdict "**" (bad ? " (" bad " run(s) ≥ 2.0 %)" : "") (missing ? " (" missing " run(s) without a 5-min window)" : "")
      hi = ""; for (v in c1hi) hi = hi (hi == "" ? "" : ",") v
      print "Design target C1 ≤ 1.8 %: " (hi == "" ? "met" : "missed on " hi)
      print ""
      if (bad || hi != "") step = "1 — make L3 the default (memDisplayHz = 2), re-run the affected cells and amcompare (#4); then step 2 (L5) if still ≥ 1.8 %"
      else step = "none — keep L1 + L2 + L4 (L3 / L5 / L6 stay off)"
      if (sysHi) step = step "; step 3 — CPU / network ≥ 1.8 %: L6 Instruments analysis + NET interface-index cache"
      print "Decision ladder (§11.4): " step
      exit (bad || missing) ? 1 : 0
    }' "$res" > "$dir/summary.md"
}

if [ -n "$summarize" ]; then
  set +e; summarize "$summarize"; rc=$?; set -e
  cat "$summarize/summary.md"; exit $rc
fi

case "$rounds$secs$settle" in *[!0-9]*) echo "--rounds / --seconds / --settle need whole numbers" >&2; exit 2;; esac
have_v1=1; [ -x "$v1" ] || have_v1=0
plan=()   # "round cell binary view"
r=1
while [ "$r" -le "$rounds" ]; do
  for c in $(echo "$cells" | tr ',' ' '); do
    cell_args "$c" > /dev/null || { echo "unknown cell $c (C1…C5)" >&2; exit 2; }
    t=()
    for v in $(echo "$views" | tr ',' ' '); do
      case "$v" in memory|cpu|network) ;; *) echo "unknown view $v" >&2; exit 2;; esac
      t+=("v2 $v")
      # v1 right after the v2 memory run: v1 and v2 alternate inside every round
      if [ "$v" = memory ] && [ "$have_v1" -eq 1 ] && cell_has_v1 "$c"; then t+=("v1 memory"); fi
    done
    if [ $((r % 2)) -eq 0 ]; then   # even rounds: reversed order (v1 first where it is next to v2 memory)
      i=$(( ${#t[@]} - 1 )); while [ "$i" -ge 0 ]; do plan+=("$r $c ${t[$i]}"); i=$((i - 1)); done
    else
      for x in "${t[@]}"; do plan+=("$r $c $x"); done
    fi
  done
  r=$((r + 1))
done

echo "c7_ab: ${#plan[@]} runs × $((settle + secs)) s ≈ $(( ${#plan[@]} * (settle + secs + 20) / 60 )) min → $out"
[ "$have_v1" -eq 1 ] || echo "c7_ab: no v1 binary at $v1 — v1 rows skipped (no v2 − v1 delta)"
if [ "$dry" -eq 1 ]; then
  for p in "${plan[@]}"; do
    set -- $p
    opts=(); while IFS= read -r a; do opts+=("$a"); done < <(cell_args "$2")
    b=$v2; vo=(--view "$4"); [ "$3" = v1 ] && { b=$v1; vo=(); }
    echo "round $1 $2 $3 $4: tools/c7_measure.sh launch $secs --settle $settle --no-top --binary $b ${vo[*]:-} ${opts[*]:-} --out $out/r$1-$2-$3-$4"
  done
  exit 0
fi
if pgrep -x WokyisPanel > /dev/null; then echo "a WokyisPanel is running — scripts/stop.sh first" >&2; exit 2; fi
mkdir -p "$out"
if [ "$have_v1" -eq 1 ]; then echo "$v1 ($(shasum -a 256 "$v1" | cut -c1-12))" > "$out/v1.txt"; else echo "missing ($v1) — v1 rows skipped" > "$out/v1.txt"; fi
printf 'round\tcell\tbinary\tview\tavg_cpu_pct\tmax5_pct\tpasses_per_s\tdraw_ms_avg\tmem_hz\tsys_dur_us_p99\tfootprint_mb\tverdict\tdir\n' > "$out/results.tsv"
for p in "${plan[@]}"; do
  set -- $p
  opts=(); while IFS= read -r a; do opts+=("$a"); done < <(cell_args "$2")
  b=$v2; vo=(--view "$4"); [ "$3" = v1 ] && { b=$v1; vo=(); }
  d="$out/r$1-$2-$3-$4"
  echo "== round $1 $2 ($(cell_about "$2")) $3 $4"
  set +e
  "$here/c7_measure.sh" launch "$secs" --settle "$settle" --no-top --binary "$b" ${vo[@]+"${vo[@]}"} ${opts[@]+"${opts[@]}"} --out "$d"
  rc=$?
  set -e
  [ "$rc" -le 1 ] || { echo "c7_measure rc=$rc for $d — stopping (see $d)" >&2; summarize "$out" || true; exit 2; }
  val() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$d/verdict.txt"; }
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(val avg_cpu_pct_1core)" "$(val health_max5_cpu_pct)" \
    "$(val passes_per_s)" "$(val draw_ms_avg)" "$(val mem_hz)" "$(val sys_dur_us_p99)" "$(val footprint_mb_max)" "$(val verdict)" "$d" >> "$out/results.tsv"
  sleep 5
done
set +e; summarize "$out"; rc=$?; set -e
cat "$out/summary.md"
echo "c7_ab: done; the panel is stopped — scripts/start.sh --bg to restart it"
exit $rc
