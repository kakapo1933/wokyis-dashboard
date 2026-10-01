#!/bin/zsh
# mockup_measure.sh [DIR]  (copied from phase2/final/measure.sh; GH now defaults to tools/bin/glyphheight)
# measure.sh [DIR] — glyphheight on every DIR/mockup_*.png with the renderer's own rect manifest.
#   class rects (binding, with min px)  → DIR/data/<state>.glyph.tsv + DIR/annotated/<state>.png
#   per-glyph label rects (informational) → DIR/data/<state>.perglyph.tsv
set -uo pipefail
here=${0:A:h}
dir=${${1:-.}:A}   # resolve DIR against the caller's cwd BEFORE cd (a relative DIR used to match 0 files)
cd $here
GH=${GH:-$here/bin/glyphheight}
mkdir -p $dir/annotated $dir/data
fails=0
pngs=($dir/mockup_*.png(N))
if (( ${#pngs} == 0 )); then echo "mockup_measure: no mockup_*.png in $dir" >&2; exit 2; fi
for png in $pngs; do
  st=${png:t:r}
  tsv=$dir/data/$st.rects.tsv
  [[ -f $tsv ]] || continue
  args=(); gargs=()
  while IFS=$'\t' read -r label rect minpx cls; do
    [[ $label == label ]] && continue
    lab="${label//@/_}/$cls"
    if [[ $label == glyph:* ]]; then gargs+=(--rect "$rect:$lab"); continue; fi
    if (( minpx > 0 )); then args+=(--rect "$rect:$lab@$minpx"); else args+=(--rect "$rect:$lab"); fi
  done < $tsv
  $GH $png "${args[@]}" --out $dir/annotated/$st.png > $dir/data/$st.glyph.tsv
  rc=$?
  $GH $png "${gargs[@]}" > $dir/data/$st.perglyph.tsv 2>/dev/null
  n=$(grep -c $'\tPASS$' $dir/data/$st.glyph.tsv); f=$(grep -cE $'\t(FAIL|NO_INK)$' $dir/data/$st.glyph.tsv)
  echo "$st: PASS=$n FAIL=$f rc=$rc"
  (( fails += f ))
  if (( rc > 1 || n == 0 )); then echo "  ! glyphheight error rc=$rc or no PASS rows" >&2; (( fails += 1 )); fi
done
echo "total FAIL=$fails"
exit $(( fails > 0 ))
