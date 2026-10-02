#!/bin/bash
# sim.sh — fault / simulation injection through run/control.json (spec §11). Every write goes to a temp file + mv (atomic).
#   sim.sh fail ID… [--for S]            IDs: mem.physical mem.vm mem.swap mem.level mem.pressure mem.audit bat.hid bat.iops
#                                              bat.sp cpu.load cpu.tasks net.if, or mem.mib:<sysctl name>
#   sim.sh hang bat.sp [--for S]         system_profiler replaced by /bin/sleep 3600, killed by the real 12 s watchdog
#   sim.sh garbage ID [--for S]          bat.sp|bat.iops: "{not json" / a CFString to the real parser; cpu.load: ticks go
#                                        backwards → dropped, baseline reset; cpu.tasks: threads=0 → implausible → "—";
#                                        net.if: byte counters go backwards → rate 0 + WARN
#   sim.sh pressure green|yellow|red [PCT] [--for S]   pressure override (default PCT 30 / 71 / 92)
#   sim.sh clear                          writes {} (nothing injected)
#   sim.sh status                         prints control.json and the panel's last CTL line
# Each command REPLACES the whole control file (one scenario at a time). --for defaults to 600 s, max 900 s (the panel
# also clamps). While anything is active the panel shows a 6 px magenta frame + a named badge and logs sim=1.
# When a panel is running, sim.sh waits up to 3 s for the panel's CTL line and prints it; `CTL invalid` → exit 1.
set -euo pipefail
. "$(dirname "$0")/_common.sh"
CTL="$RUN_DIR/control.json"
mkdir -p "$RUN_DIR"
usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 64; }
[ $# -ge 1 ] || usage
cmd=$1; shift
secs=600; args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --for) [ $# -ge 2 ] || usage; secs=$2; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
case "$secs" in ''|*[!0-9]*) echo "sim.sh: --for needs whole seconds" >&2; exit 64 ;; esac
secs=$((10#$secs))
[ "$secs" -ge 1 ] || { echo "sim.sh: --for must be ≥ 1" >&2; exit 64; }
[ "$secs" -le 900 ] || { echo "sim.sh: --for $secs > 900, using 900" >&2; secs=900; }
expires=$(date -u -v+"${secs}"S +%Y-%m-%dT%H:%M:%SZ)

LOG="$LOG_DIR/current.log"
log0=0; [ -f "$LOG" ] && log0=$(wc -l < "$LOG" | tr -d ' ')
write() {   # atomic replace
  local tmp
  tmp=$(mktemp "$RUN_DIR/.control.XXXXXX")
  printf '%s\n' "$1" > "$tmp"
  mv -f "$tmp" "$CTL"
  echo "control.json ← $1"
}
jlist() { local out="" x; for x in "$@"; do out="$out${out:+,}\"$x\""; done; echo "[$out]"; }
valid_id() {
  case "$1" in
    mem.physical|mem.vm|mem.swap|mem.level|mem.pressure|mem.audit|bat.hid|bat.iops|bat.sp) return 0 ;;
    cpu.load|cpu.tasks|net.if) return 0 ;;
    mem.mib:?*) return 0 ;;
    *) return 1 ;;
  esac
}

case "$cmd" in
  fail)
    [ ${#args[@]} -ge 1 ] || usage
    for a in "${args[@]}"; do valid_id "$a" || { echo "sim.sh: unknown source id $a" >&2; exit 64; }; done
    write "{\"version\":1,\"expires\":\"$expires\",\"fail\":$(jlist "${args[@]}")}" ;;
  hang)
    [ "${args[*]:-}" = "bat.sp" ] || { echo "sim.sh: hang only supports bat.sp" >&2; exit 64; }
    write "{\"version\":1,\"expires\":\"$expires\",\"hang\":[\"bat.sp\"]}" ;;
  garbage)
    [ ${#args[@]} -eq 1 ] && case "${args[0]}" in bat.sp|bat.iops|cpu.load|cpu.tasks|net.if) true ;; *) false ;; esac \
      || { echo "sim.sh: garbage takes one of bat.sp bat.iops cpu.load cpu.tasks net.if" >&2; exit 64; }
    write "{\"version\":1,\"expires\":\"$expires\",\"garbage\":[\"${args[0]}\"]}" ;;
  pressure)
    [ ${#args[@]} -ge 1 ] || usage
    case "${args[0]}" in green) lvl=1; pct=30 ;; yellow) lvl=2; pct=71 ;; red) lvl=4; pct=92 ;; *) usage ;; esac
    if [ ${#args[@]} -ge 2 ]; then pct=${args[1]}; fi
    case "$pct" in ''|*[!0-9]*) echo "sim.sh: PCT must be 0…100" >&2; exit 64 ;; esac
    pct=$((10#$pct))   # "071" → 71: a JSON number must not have a leading zero
    [ "$pct" -le 100 ] || { echo "sim.sh: PCT must be 0…100" >&2; exit 64; }
    write "{\"version\":1,\"expires\":\"$expires\",\"pressure\":{\"level\":$lvl,\"percent\":$pct}}" ;;
  clear)
    write "{}" ;;
  status)
    if [ -s "$CTL" ]; then echo "control.json: $(tr -d '\n' < "$CTL")"; else echo "control.json: none"; fi
    [ -e "$LOG_DIR/current.log" ] && { grep ' CTL ' "$LOG_DIR/current.log" | tail -1 || true; }
    exit 0 ;;
  *) usage ;;
esac
[ "$cmd" = clear ] || echo "expires $expires (in ${secs} s)"
# confirm with the running panel (it polls control.json every 1 s)
if [ -n "$(panel_pid)" ] && [ -f "$LOG" ]; then
  ctl=""
  for _ in $(seq 1 15); do
    ctl=$(tail -n +"$((log0 + 1))" "$LOG" 2>/dev/null | grep ' CTL ' | tail -1 || true)
    [ -n "$ctl" ] && break
    sleep 0.2
  done
  if [ -z "$ctl" ]; then echo "sim.sh: no CTL line from the panel within 3 s (unchanged state, or panel not polling) — check scripts/sim.sh status" >&2
  else
    echo "panel: $ctl"
    case "$ctl" in *" CTL invalid "*) echo "sim.sh: the panel REJECTED control.json — nothing is injected" >&2; exit 1 ;; esac
  fi
fi
