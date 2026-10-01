#!/bin/bash
# injectdemo.sh — criterion #8 (a failing source shows "—", the rest keeps updating, no crash), spec §15 #8.
#
# usage: tools/injectdemo.sh [--out DIR=evidence/c8] [--airpods] [--only ID] [--plan]
#        tools/injectdemo.sh real [--out DIR]      # real (non-injected) failures: restarts the panel twice (see below)
#
# Injected sequence (scripts/sim.sh, run/control.json; expiry --for 300 so nothing can stay injected by accident):
#   mem.swap, mem.vm, mem.level, bat.hid, [--airpods: bat.iops + bat.sp together], hang bat.sp, garbage bat.sp
# Per step:  <id>-before.png → inject → wait for the matching ERR line in the panel log (proof the injected read
#            failed: mem.* ≤ 15 s, bat.hid / bat.iops ≤ 45 s, bat.sp ≤ 45 s, hang → err=timeout ≤ 60 s,
#            garbage → err=parse ≤ 60 s) → wait until the DISPLAY shows the failure (mem.*: the same sample, so the
#            ERR line suffices; battery: a DEV line of the affected rows — bat.hid `to=failed why=hid_failed`,
#            bat.iops+bat.sp AirPods `to=failed|stale`, hang / garbage bat.sp `to=stale why=sp_stale` once the last
#            successful sp is > 45 s old; ≤ 90 s after the injection) → <id>-during-1.png, 2 s, <id>-during-2.png
#            (other fields move, clock advances) → sim.sh clear → recovery wait (mem 3 s; battery: every row that
#            failed has a later DEV `to=connected|offline`, ≤ 60 s) → <id>-after.png
#            <id>.log = every log line written during the step; pid must be unchanged after every step.
#            A step FAILS without its ERR line, without the display evidence, with a changed pid or a crash report.
# pid_and_crash_check.txt: pid per step + ~/Library/Logs/DiagnosticReports/WokyisPanel* before vs after.
# `real`: scripts/stop.sh → scripts/start.sh --bg -- --break-mib vm.swapusage → 15 s → real-break-mib.png + log;
#         stop → start --bg -- --sp-path /nonexistent/system_profiler → 50 s → real-sp-path.log (+ .png);
#         stop → start --bg (normal). The Wokyis falls back to the desktop Space while the panel is stopped.
# Captures are Wokyis-only (tools/wokyis_shot.sh). --plan prints the steps without doing anything.
# Test hooks (env): SIM=… SHOT=… PANEL_LOG=… PIDFILE=… DIAG_DIR=… WAIT_SCALE=… (used by the tools self-test).
# Exit: 0 every step saw its ERR line and its display evidence and the pid never changed; 1 otherwise; 2 usage /
#       panel not running.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/.." && pwd)
SIM=${SIM:-$root/scripts/sim.sh}
SHOT=${SHOT:-$here/wokyis_shot.sh}
PANEL_LOG=${PANEL_LOG:-$root/logs/current.log}
PIDFILE=${PIDFILE:-$root/run/panel.pid}
DIAG_DIR=${DIAG_DIR:-$HOME/Library/Logs/DiagnosticReports}
WAIT_SCALE=${WAIT_SCALE:-1}
out="$root/evidence/c8"; airpods=0; only=""; plan=0; mode=inject
if [ "${1:-}" = real ]; then mode=real; shift; fi
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out=$2; shift 2;; --airpods) airpods=1; shift;; --only) only=$2; shift 2;; --plan) plan=1; shift;;
    -h|--help) sed -n '2,24p' "$0"; exit 0;;
    *) echo "unknown argument $1" >&2; exit 2;;
  esac
done

# step table: name | sim.sh arguments | ERR pattern | wait s | recovery kind | display evidence (ERE on new log
# lines; "-" = the ERR line itself: memory fields fail in the same sample) | display wait s (from the injection)
steps="mem.swap|fail mem.swap|ERR src=mem.swap |15|mem|-|0
mem.vm|fail mem.vm|ERR src=mem.vm |15|mem|-|0
mem.level|fail mem.level|ERR src=mem.level |15|mem|-|0
bat.hid|fail bat.hid|ERR src=bat.hid |45|bat| DEV dev=.* to=failed why=hid_failed|60"
[ "$airpods" -eq 1 ] && steps="$steps
bat.iops+bat.sp|fail bat.iops bat.sp|ERR src=bat.iops |45|bat| DEV dev=.* kind=airpods .*to=(failed|stale) |90"
steps="$steps
hang-bat.sp|hang bat.sp|ERR src=bat.sp err=timeout|60|bat| DEV dev=.* to=stale why=sp_stale|90
garbage-bat.sp|garbage bat.sp|ERR src=bat.sp err=parse|60|bat| DEV dev=.* to=stale why=sp_stale|90"

if [ "$plan" -eq 1 ]; then
  echo "# injectdemo plan (mode=$mode, out=$out)"
  if [ "$mode" = real ]; then
    echo "scripts/stop.sh; scripts/start.sh --bg -- --break-mib vm.swapusage; sleep 15; shot real-break-mib.png"
    echo "scripts/stop.sh; scripts/start.sh --bg -- --sp-path /nonexistent/system_profiler; sleep 50; shot real-sp-path.png; log → real-sp-path.log"
    echo "scripts/stop.sh; scripts/start.sh --bg"
    exit 0
  fi
  echo "$steps" | while IFS='|' read -r name args pat wait rec disp dwait; do
    [ -n "$only" ] && [ "$only" != "$name" ] && continue
    echo "$name: shot before; $SIM $args --for 300; wait ≤${wait}s for '$pat'; display evidence '$disp' (≤${dwait}s); shot during-1; sleep 2; shot during-2; $SIM clear; recover($rec); shot after"
  done
  exit 0
fi

mkdir -p "$out"
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
lines() { if [ -f "$PANEL_LOG" ]; then wc -l < "$PANEL_LOG" | tr -d ' '; else echo 0; fi; }
new_since() { tail -n +"$(( $1 + 1 ))" "$PANEL_LOG" 2>/dev/null || true; }
wait_for() {  # wait_for START_LINE PATTERN TIMEOUT → 0 found
  local start=$1 pat=$2 t=$3 end
  end=$(perl -e "printf '%.3f', $(now) + $t * $WAIT_SCALE")
  while perl -e "exit !($(now) < $end)"; do
    if new_since "$start" | grep -F -q -- "$pat"; then return 0; fi
    sleep 0.25
  done
  return 1
}
wait_for_re() {  # wait_for_re START_LINE ERE DEADLINE(epoch) → 0 found (first match on stdout)
  local start=$1 re=$2 end=$3 m
  while :; do
    m=$(new_since "$start" | grep -E -m1 -- "$re" || true)
    if [ -n "$m" ]; then echo "$m"; return 0; fi
    perl -e "exit !($(now) < $end)" || return 1
    sleep 0.5
  done
}
dev_of() { sed -E 's/.* DEV dev=(.*) kind=[a-z]+ .*/\1/'; }   # AirPods keys contain spaces
pid_now() { cat "$PIDFILE" 2>/dev/null | tr -d ' \n'; }
diag() { ls "$DIAG_DIR" 2>/dev/null | grep '^WokyisPanel' || true; }
shot() { "$SHOT" "$out/$1" > /dev/null; }

check="$out/pid_and_crash_check.txt"

if [ "$mode" = real ]; then
  [ -x "$root/scripts/stop.sh" ] && [ -x "$root/scripts/start.sh" ] || { echo "scripts/start.sh / stop.sh missing" >&2; exit 2; }
  echo "# real failures $(date '+%Y-%m-%dT%H:%M:%S%z')" > "$out/real-failures.txt"
  "$root/scripts/stop.sh" >> "$out/real-failures.txt" 2>&1 || true
  "$root/scripts/start.sh" --bg -- --break-mib vm.swapusage >> "$out/real-failures.txt" 2>&1
  sleep 15; shot real-break-mib.png
  grep -E 'START|ERR src=mem.swap' "$PANEL_LOG" | tail -5 > "$out/real-break-mib.log" || true
  "$root/scripts/stop.sh" >> "$out/real-failures.txt" 2>&1 || true
  "$root/scripts/start.sh" --bg -- --sp-path /nonexistent/system_profiler >> "$out/real-failures.txt" 2>&1
  sleep 50; shot real-sp-path.png
  grep -E 'START|ERR src=bat.sp|SP ' "$PANEL_LOG" | tail -10 > "$out/real-sp-path.log" || true
  "$root/scripts/stop.sh" >> "$out/real-failures.txt" 2>&1 || true
  "$root/scripts/start.sh" --bg >> "$out/real-failures.txt" 2>&1
  echo "real failures done → $out (panel restarted normally; pid $(pid_now))"
  exit 0
fi

[ -x "$SIM" ] || { echo "missing $SIM" >&2; exit 2; }
pid0=$(pid_now)
[ -n "$pid0" ] && kill -0 "$pid0" 2>/dev/null || { echo "panel not running (pid file $PIDFILE: '$pid0')" >&2; exit 2; }
diag0=$(diag)
{ echo "# injectdemo $(date '+%Y-%m-%dT%H:%M:%S%z') panel pid $pid0"; echo "# DiagnosticReports WokyisPanel* before: ${diag0:-none}"
  printf 'step\tpid_after\tsame_pid\terr_seen\terr_wait_s\tdisplay_seen\tdisplay_wait_s\trecovered\tdisplay_evidence\n'; } > "$check"
fail=0
while IFS='|' read -r name args pat wait rec disp dwait; do
  [ -n "$only" ] && [ "$only" != "$name" ] && continue
  echo "== $name ($args)"
  l0=$(lines)
  shot "$name-before.png"
  t0=$(now)
  # shellcheck disable=SC2086
  "$SIM" $args --for 300 > "$out/$name.sim.txt" 2>&1 || echo "sim.sh exit $?" >> "$out/$name.sim.txt"
  if wait_for "$l0" "$pat" "$wait"; then seen=yes; else seen=NO; fail=1; fi
  tw=$(perl -e "printf '%.1f', $(now) - $t0")
  # the display must actually show the failure before the "during" captures (battery rows use sp data ≤ 45 s old)
  if [ "$disp" = "-" ]; then dseen=$seen; dw=$tw; dline="(ERR line: the failing memory fields show — in the same sample)"
  else
    dend=$(perl -e "printf '%.3f', $t0 + $dwait * $WAIT_SCALE")
    if dline=$(wait_for_re "$l0" "$disp" "$dend"); then dseen=yes; else dseen=NO; dline="(no DEV line matching '$disp' within ${dwait}s)"; fail=1; fi
    dw=$(perl -e "printf '%.1f', $(now) - $t0")
  fi
  shot "$name-during-1.png"; sleep 2; shot "$name-during-2.png"
  l1=$(lines)
  "$SIM" clear >> "$out/$name.sim.txt" 2>&1 || echo "sim.sh clear exit $?" >> "$out/$name.sim.txt"
  if [ "$rec" = mem ]; then sleep 3; recovered=yes
  else
    # every row that went failed/stale during the step needs a later DEV to=connected|offline (the display left "—")
    devs=$({ new_since "$l0" | head -n "$((l1 - l0))" | grep -E ' DEV dev=.* to=(failed|stale) ' | dev_of | sort -u; } 2>/dev/null || true)
    recovered=NO
    [ -z "$devs" ] && recovered="NO(no failed rows seen)"
    end=$(perl -e "printf '%.3f', $(now) + 60 * $WAIT_SCALE")
    while [ -n "$devs" ] && perl -e "exit !($(now) < $end)"; do
      pending=""
      while IFS= read -r d; do
        [ -z "$d" ] && continue
        new_since "$l1" | grep -F -- " DEV dev=$d kind=" | grep -q -E 'to=(connected|offline) ' || pending="$pending$d;"
      done <<DEVS
$devs
DEVS
      if [ -z "$pending" ]; then recovered=yes; break; fi
      sleep 0.5
    done
  fi
  shot "$name-after.png"
  new_since "$l0" > "$out/$name.log"
  p=$(pid_now); same=no; [ "$p" = "$pid0" ] && kill -0 "$p" 2>/dev/null && same=yes
  [ "$same" = yes ] || fail=1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$p" "$same" "$seen" "$tw" "$dseen" "$dw" "$recovered" "$(echo "$dline" | tr '\t' ' ')" >> "$check"
  echo "   err_seen=$seen (${tw}s) display_seen=$dseen (${dw}s) same_pid=$same recovered=$recovered"
done <<EOF
$steps
EOF
diag1=$(diag)
newdiag=$(comm -13 <(echo "$diag0") <(echo "$diag1") | sed '/^$/d')
{ echo "# DiagnosticReports WokyisPanel* after: ${diag1:-none}"; echo "# new crash reports: ${newdiag:-none}"; } >> "$check"
[ -n "$newdiag" ] && fail=1
echo "injectdemo: $( [ $fail -eq 0 ] && echo PASS || echo FAIL ) → $check"
exit $fail
