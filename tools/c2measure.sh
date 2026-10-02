#!/bin/bash
# c2measure.sh — criterion #2 (font heights) on the REAL Wokyis output (spec §15 #2).
#
# usage: tools/c2measure.sh [--out DIR=evidence/c2] [--tag wokyis] [--pid PID] [--run-dir run] [--tries 3]
#        tools/c2measure.sh --offline PANEL.png [--out DIR] [--tag T]   # no signal / capture / gate: measure an offscreen render
#                                                                        # (PANEL.rects.tsv/.perglyph.tsv/.boxes.tsv/.state.json next to it)
#        tools/c2measure.sh --render VIEW LANG yes|no [--out DIR] [--tag T]   # v2: render the fixture offscreen with
#                           build/WokyisPanel.app (--snapshot --dump-rects --view VIEW --lang LANG --battery yes|no), then
#                           measure it like --offline (VIEW memory|cpu|network, LANG zh|en|system)
# v2: the live and --from-capture gates compare the 7 MEMORY values, so they apply to the memory view only; a snapshot
# whose state.json says another view is refused (exit 2) — measure CPU / network with --render (or --offline) for now.
# The panelocr crops are the v1 layout (繁體中文, battery column shown), so a memory snapshot with "lang": "en" or
# "battery_visible": false is refused too (exit 2, naming the status-menu setting) — measure those with --render.
#        tools/c2measure.sh --from-capture CAP.png --snapshot PREFIX [--from-capture CAP2.png --snapshot PREFIX2]… [--out DIR]
#                           [--tag T] [--tries N]   # no signal / capture: gate + measurement on existing files, one try per pair
#                                                   # (PREFIX = run/snapshot-<ts>; PREFIX.{png,rects.tsv,perglyph.tsv,boxes.tsv,state.json})
# Live mode, per try (≤ --tries, every try kept):
#   1. SIGUSR1 → the panel writes run/snapshot-<ts>.{png,rects.tsv,perglyph.tsv,boxes.tsv,state.json} (state it last drew)
#   2. immediately tools/wokyis_shot.sh → the Wokyis capture (the LG image of the same call is discarded)
#   3. gate = amcompare panelocr --ref snapshot.png: every gated element of the capture must be LAYOUT-EQUIVALENT to the
#      snapshot — key = the existing OCR normalisation (spaces unified, digitfix, whitespace removed, upper case, dash /
#      empty → "—") with every ASCII digit → "9" on both sides ('.', ',', ':', '%', letters kept). Gated: 7 memory values,
#      pressure %, clock vs state.json; battery value column (lines with a digit or %) vs the same OCR of the snapshot PNG
#      (same line count, centre y ±30 px). Monospaced digits ⇒ equal keys = same glyph positions ⇒ the snapshot rects
#      stay valid. A different key ("9.99 GB" vs "10.00 GB", "—" vs a number, a battery row appearing / disappearing /
#      moving) → next try. Exact equality is recorded too (tries.tsv exact_match, panelocr "ALL MATCH" / "LAYOUT MATCH").
# On the accepted try:
#   glyph.tsv     glyphheight on the snapshot's binding class rects (digits ≥64 / ≥40, labels ≥32 per class; units informational)
#   perglyph.tsv  glyphheight on the per-glyph label rects (informational)
#   element.tsv   glyphheight --lines on every label.* element ink box of boxes.tsv, padded 5 px (independent of the
#                 renderer's class split), minimum 32
#   annotated.png / perglyph_annotated.png / element_annotated.png, method.md (method, gate rule + result, per-class minima)
# Exit: 0 all binding PASS, 1 a binding measurement FAILED, 2 no accepted capture / usage. bash 3.2 compatible.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/.." && pwd)
out="$root/evidence/c2"; tag=wokyis; pid=""; rundir="$root/run"; tries=3; offline=""; render=(); render_note=""
caps=(); snaps=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out=$2; shift 2;; --tag) tag=$2; shift 2;; --pid) pid=$2; shift 2;;
    --run-dir) rundir=$2; shift 2;; --tries) tries=$2; shift 2;; --offline) offline=$2; shift 2;;
    --from-capture) caps+=("$2"); shift 2;; --snapshot) snaps+=("$2"); shift 2;;
    --render) [ $# -ge 4 ] || { echo "--render needs VIEW LANG yes|no" >&2; exit 2; }; render=("$2" "$3" "$4"); shift 4;;
    -h|--help) awk 'NR > 1 && /^set -euo/ { exit } NR > 1' "$0"; exit 0;;
    *) echo "unknown argument $1" >&2; exit 2;;
  esac
done
if [ "${#caps[@]}" -ne "${#snaps[@]}" ]; then echo "--from-capture and --snapshot must come in pairs (${#caps[@]} vs ${#snaps[@]})" >&2; exit 2; fi
if [ -n "$offline" ] && [ "${#caps[@]}" -gt 0 ]; then echo "--offline and --from-capture exclude each other" >&2; exit 2; fi
if [ "${#render[@]}" -gt 0 ]; then
  if [ -n "$offline" ] || [ "${#caps[@]}" -gt 0 ]; then echo "--render excludes --offline / --from-capture" >&2; exit 2; fi
  app="$root/build/WokyisPanel.app/Contents/MacOS/WokyisPanel"
  [ -x "$app" ] || { echo "missing $app — run scripts/build.sh" >&2; exit 2; }
  mkdir -p "$out"
  offline="$out/$tag-render.png"
  "$app" --snapshot "$offline" --dump-rects --view "${render[0]}" --lang "${render[1]}" --battery "${render[2]}" > "$out/$tag-render.txt" \
    || { echo "offscreen render failed (see $out/$tag-render.txt)" >&2; exit 2; }
  render_note=" Rendered by this run: \`--snapshot --dump-rects --view ${render[0]} --lang ${render[1]} --battery ${render[2]}\`."
fi
GH="$here/bin/glyphheight"; AMC="$here/bin/amcompare"
for b in "$GH" "$AMC"; do [ -x "$b" ] || { echo "missing $b — run tools/build.sh" >&2; exit 2; }; done
mkdir -p "$out"
log="$out/$tag-tries.tsv"
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
header='try\tt_signal\tsnapshot\tcapture\tcapture_ms\tlayout_match\texact_match\n'

# gate_try N T_SIGNAL SNAPBASE CAPTURE CAPTURE_MS — layout-equivalence gate (see header); logs one row; returns 0 on accept
gate_try() {
  local n=$1 ts=$2 base=$3 cap=$4 ms=$5 ocr="$out/$tag-try$1-ocr.tsv" rc=0 lm em
  if grep -Eq '"view" *: *"(cpu|network)"' "$base.state.json"; then
    echo "the snapshot shows the $(grep -Eo '"view" *: *"[a-z]+"' "$base.state.json" | grep -Eo '[a-z]+"$' | tr -d '"') view: the live gate covers the memory view only — use --render VIEW LANG yes|no" >&2
    exit 2
  fi
  # the panelocr crops (PanelRegions.columns, clock / battery crops) are the v1 zh + battery layout (OPS-1)
  if grep -Eq '"lang" *: *"en"' "$base.state.json"; then
    echo "the snapshot shows lang=en: the live gate crops the 繁體中文 layout only — set 語言 ▸ 繁體中文 in the status menu (persisted ui.language), or use --render memory en yes|no" >&2
    exit 2
  fi
  if grep -Eq '"battery_visible" *: *false' "$base.state.json"; then
    echo "the snapshot shows battery_visible=false: the live gate crops the battery-column layout only — turn 顯示藍牙電量 on (⌃⌥⌘B; persisted ui.batteryVisible), or use --render memory LANG no" >&2
    exit 2
  fi
  "$AMC" panelocr "$cap" --rects "$base.rects.tsv" --state "$base.state.json" --ref "$base.png" > "$ocr" || rc=$?
  case "$rc" in 0) lm=yes;; 1) lm=NO;; *) lm="error rc=$rc";; esac
  case "$(tail -1 "$ocr")" in *"ALL MATCH"*) em=yes;; *"LAYOUT MATCH"*|*MISMATCH*) em=no;; *) em=-;; esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$ts" "$base" "$cap" "$ms" "$lm" "$em" >> "$log"
  if [ "$lm" = yes ]; then accepted=$n; snapbase=$base; exact=$em; cp "$cap" "$out/$tag.png"; return 0; fi
  return 1
}

accepted=""; snapbase=""; exact="-"; mode=live
if [ -n "$offline" ]; then
  mode=offline
  snapbase="${offline%.png}"
  cp "$offline" "$out/$tag.png"
  accepted="offline"
  { printf "$header"; printf '0\t-\t%s\t(offline render)\t-\toffline (gate not applied)\t-\n' "$snapbase"; } > "$log"
elif [ "${#caps[@]}" -gt 0 ]; then
  mode=from-capture
  printf "$header" > "$log"
  i=0
  while [ "$i" -lt "${#caps[@]}" ] && [ "$i" -lt "$tries" ]; do
    n=$((i+1)); src=${caps[$i]}; base=${snaps[$i]}; base=${base%.state.json}; base=${base%.png}
    for f in "$src" "$base.png" "$base.rects.tsv" "$base.perglyph.tsv" "$base.boxes.tsv" "$base.state.json"; do
      [ -f "$f" ] || { echo "missing $f" >&2; exit 2; }
    done
    [ "$src" -ef "$out/$tag-try$n.png" ] || cp "$src" "$out/$tag-try$n.png"   # same file name as a live try
    if gate_try "$n" - "$base" "$src" -; then break; fi
    i=$n
  done
else
  [ -n "$pid" ] || pid=$(cat "$rundir/panel.pid" 2>/dev/null || true)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || { echo "panel not running (pid '$pid')" >&2; exit 2; }
  printf "$header" > "$log"
  n=1
  while [ "$n" -le "$tries" ]; do
    marker=$(mktemp "${TMPDIR:-/tmp}/c2marker.XXXXXX")
    ts=$(now)
    kill -USR1 "$pid"
    snap=""
    for _ in $(seq 1 50); do
      snap=$(find "$rundir" -maxdepth 1 -name 'snapshot-*.state.json' -newer "$marker" 2>/dev/null | sort | tail -1)
      [ -n "$snap" ] && break
      sleep 0.1
    done
    rm -f "$marker"
    if [ -z "$snap" ]; then printf '%s\t%s\t-\t-\t-\tno snapshot within 5 s\t-\n' "$n" "$ts" >> "$log"; n=$((n+1)); continue; fi
    base="${snap%.state.json}"
    cap="$out/$tag-try$n.png"
    shot=$("$here/wokyis_shot.sh" "$cap")
    ms=$(echo "$shot" | awk '{print $3}')
    if gate_try "$n" "$ts" "$base" "$cap" "$ms"; then break; fi
    n=$((n+1))
  done
fi
if [ -z "$accepted" ]; then
  echo "no capture was layout-equivalent to its snapshot in $(($(wc -l < "$log") - 1)) tries (see $log)" >&2; exit 2
fi

cp "$snapbase.rects.tsv" "$out/$tag.rects.tsv"
cp "$snapbase.perglyph.tsv" "$out/$tag.perglyph_rects.tsv"
cp "$snapbase.boxes.tsv" "$out/$tag.boxes.tsv"
cp "$snapbase.state.json" "$out/$tag.state.json"
[ -f "$snapbase.png" ] && [ "$snapbase.png" != "$out/$tag.png" ] && cp "$snapbase.png" "$out/$tag.snapshot.png"
img="$out/$tag.png"

# 1. binding class rects
args=()
while IFS=$'\t' read -r label rect minpx cls; do
  [ "$label" = label ] && continue
  if [ "${minpx:-0}" -gt 0 ] 2>/dev/null; then args+=(--rect "$rect:$label@$minpx"); else args+=(--rect "$rect:$label"); fi
done < "$out/$tag.rects.tsv"
set +e
"$GH" "$img" "${args[@]}" --out "$out/$tag.annotated.png" > "$out/$tag.glyph.tsv"; rc_bind=$?
# 2. per-glyph (informational)
args=()
while IFS=$'\t' read -r label rect minpx cls; do [ "$label" = label ] && continue; args+=(--rect "$rect:$label"); done < "$out/$tag.perglyph_rects.tsv"
if [ ${#args[@]} -gt 0 ]; then "$GH" "$img" "${args[@]}" --out "$out/$tag.perglyph_annotated.png" > "$out/$tag.perglyph.tsv"; fi
# 3. whole label elements from boxes.tsv, padded 5 px, --lines, min 32
args=()
while IFS=$'\t' read -r id rect; do
  case "$id" in label.*) ;; *) continue;; esac
  IFS=, read -r x y w h <<< "$rect"
  args+=(--rect "$((x-5)),$((y-5)),$((w+10)),$((h+10)):$id@32")
done < "$out/$tag.boxes.tsv"
rc_el=0
if [ ${#args[@]} -gt 0 ]; then "$GH" "$img" "${args[@]}" --lines --out "$out/$tag.element_annotated.png" > "$out/$tag.element.tsv"; rc_el=$?; fi
set -e

# per-class minima (binding): join glyph.tsv (label → ink_h, result) with rects.tsv (label → class, min)
summary=$(awk -F'\t' 'FNR==NR { if (FNR>1) { cls[$1]=$4; mn[$1]=$3 } next }
  /^#/ || $1=="label" { next }
  { c=cls[$1]; if (c=="") c="?"; if (mn[$1]==0) c=c" (info)"; else c=c" ≥"mn[$1]; n[c]++; if (!(c in lo) || $7<lo[c]) lo[c]=$7; if ($7>hi[c]) hi[c]=$7;
    if ($12=="PASS") p[c]++; else if ($12=="FAIL" || $12=="NO_INK") f[c]++ }
  END { for (c in n) printf "| %s | %d | %d–%d | %d | %d |\n", c, n[c], lo[c], hi[c], p[c]+0, f[c]+0 }' \
  "$out/$tag.rects.tsv" "$out/$tag.glyph.tsv" | sort)
el_sum=$(awk -F'\t' '/^#/ || $1=="label" {next} { n++; if (!(lo) || $7<lo) lo=$7; if ($12=="PASS") p++; else f++ } END { printf "%d lines, min %d px, PASS %d, FAIL %d", n, lo, p+0, f+0 }' "$out/$tag.element.tsv" 2>/dev/null || echo "-")
fails=$(awk -F'\t' '$12=="FAIL" || $12=="NO_INK"' "$out/$tag.glyph.tsv" | wc -l | tr -d ' ')

# gate description + result for method.md
capnote=""; gate_md=""
if [ "$mode" = offline ]; then
  capnote="OFFLINE MODE: the image is the offscreen render \`$offline\`, not a screen capture.$render_note"
  gate_md="- Acceptance gate: not applied (OFFLINE MODE — the measured image is the render the rects were dumped from)."
else
  if [ "$mode" = from-capture ]; then
    capnote="FROM-CAPTURE MODE: the capture of each try was given on the command line (not taken by this run); accepted: \`$(awk -F'\t' -v n="$accepted" '$1==n {print $4}' "$log")\`."
  fi
  ocrf="$out/$tag-try$accepted-ocr.tsv"
  ldiff=$(awk -F'\t' 'NR > 1 && $1 != "panelocr" && $6 == "NO" && $7 == "yes" { printf "%s`%s` \"%s\" (snapshot \"%s\")", sep, $1, $2, $5; sep = "; " }' "$ocrf")
  gate_md="- Acceptance gate (\`tools/bin/amcompare panelocr CAPTURE --rects R --state S --ref SNAPSHOT.png\`, per try
  \`$tag-tryN-ocr.tsv\`): a capture is accepted when every gated text element is LAYOUT-EQUIVALENT to the snapshot.
  Key = the existing OCR normalisation (spaces unified, digitfix O/o→0 and I/l/|→1 in numeric tokens, whitespace removed,
  upper case, every dash / empty reading → \"—\") with every ASCII digit mapped to \"9\" on both sides; '.', ',', ':',
  '%' and letters stay literal. Gated: the 7 memory values, pressure % and the clock vs \`state.json\`; the battery value
  column (x 1040–1272, y 12–648, OCR lines that contain a digit or \"%\") vs the same OCR of the snapshot PNG — same
  number of lines, pairwise equal keys, line centres within ±30 px. The renderer draws numbers in SF Pro Condensed with
  monospaced digits (kMonospacedNumbersSelector), so equal keys mean identical glyph positions and the snapshot rects
  stay valid although digit values changed (memory values are redrawn at 4 Hz). A different key — e.g. \"9.99 GB\" vs
  \"10.00 GB\", \"—\" vs a number, a battery row appearing / disappearing / moving — rejects the try; at most --tries
  tries, every try logged in \`$tag-tries.tsv\` (layout_match, exact_match). Not OCR-gated: label text (static except
  the battery device labels and the pressure word; en-US OCR cannot read CJK and zh-Hant readings of the same label
  differ between capture and render).
- Gate result of accepted try $accepted: layout-equivalent; exact match: **$exact**${ldiff:+ — equal by layout only: $ldiff}."
fi

cat > "$out/$tag.method.md" <<EOF
# Criterion #2 — font heights measured on the real 1280×720 Wokyis output ($tag)

Generated by \`tools/c2measure.sh\` on $(date '+%Y-%m-%dT%H:%M:%S%z'); accepted try: $accepted (all tries: \`$tag-tries.tsv\`).

## Method
- Capture: \`tools/wokyis_shot.sh\` = one \`screencapture -x lg.png wokyis.png\`; the Wokyis file is 1280×720 = 1:1 screen pixels
  (the LG file is discarded). $capnote
- Rects: the panel's own snapshot (SIGUSR1) of the state it drew — \`$tag.rects.tsv\` (binding, by glyph class),
  \`$tag.perglyph_rects.tsv\` (one rect per label glyph, informational), \`$tag.boxes.tsv\` (element ink boxes).
$gate_md
- Measurement: \`tools/bin/glyphheight\` — background = most frequent colour on the rect border; ink = pixel whose max
  channel difference from the background ≥ 50 % of the strongest contrast in the rect (anti-alias edge at ~50 % coverage);
  height = ink rows from top to bottom (inclusive). Verified ±1 px on bars of known fractional height (phase 1).
- Thresholds: main numbers (Memory Used, pressure %, every battery %) ≥ 64 px; labels ≥ 32 px per glyph class (CJK run,
  upper-case Latin run, digits inside labels) — no descender bonus (labels contain no lower case); secondary memory
  numbers and the clock ≥ 40 px (spec target). Units (GB/MB/%/bytes) are not labels and are informational only;
  "—" is never measured.
- Independent cross-check: every \`label.*\` element ink box, padded 5 px, measured as whole text lines (\`--lines\`),
  not split by the renderer's glyph classes → \`$tag.element.tsv\`.

## Results
| class (threshold px) | rects | ink height min–max px | PASS | FAIL |
|---|---|---|---|---|
$summary

- whole-element label lines: $el_sum
- binding failures: $fails → **$( [ "$rc_bind" -eq 0 ] && [ "$fails" = 0 ] && echo PASS || echo FAIL )**
- files: \`$tag.png\` (capture), \`$tag.glyph.tsv\` + \`$tag.annotated.png\` (binding), \`$tag.perglyph.tsv\`,
  \`$tag.element.tsv\` + \`$tag.element_annotated.png\`, \`$tag.state.json\`
EOF
echo "c2measure: accepted try $accepted (exact match: $exact) binding rc=$rc_bind fails=$fails elements rc=$rc_el → $out/$tag.method.md"
[ "$rc_bind" -eq 0 ] && [ "$fails" = 0 ] && exit 0 || exit 1
