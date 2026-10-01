#!/bin/zsh
# capture_pair.sh — ONE screencapture invocation for both displays + composite + sidecar log.
#
# usage: capture_pair.sh OUT_DIR TAG [composite options…]   e.g.
#        capture_pair.sh evidence/c4-accuracy t1 --lg-crop 1800,900,2040,1260 --caption "AM Memory tab vs panel"
#
# Produces OUT_DIR/TAG_lg.png (main display, first file), OUT_DIR/TAG_wokyis.png (second file),
# OUT_DIR/TAG_composite.png and appends one line to OUT_DIR/capture_log.tsv:
#   tag  start_iso  end_iso  duration_ms  lg_WxH  wokyis_WxH
# start/end bracket the whole screencapture call, so any skew between the two displays is <= duration_ms.
set -euo pipefail
here=${0:A:h}
out=${1:?out dir}; tag=${2:?tag}; shift 2
mkdir -p "$out"
lg="$out/${tag}_lg.png"; wk="$out/${tag}_wokyis.png"
now_ms() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time' ; }
iso() { perl -MPOSIX=strftime -e 'my $t=shift; printf "%s.%03d%s\n", strftime("%Y-%m-%dT%H:%M:%S",localtime($t)), ($t-int($t))*1000, strftime("%z",localtime($t))' "$1"; }
t0=$(now_ms)
/usr/sbin/screencapture -x "$lg" "$wk"
t1=$(now_ms)
dur=$(perl -e "printf '%d', ($t1-$t0)*1000")
lgsz=$(sips -g pixelWidth -g pixelHeight "$lg" | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w"x"h}')
wksz=$(sips -g pixelWidth -g pixelHeight "$wk" | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w"x"h}')
[[ -f "$out/capture_log.tsv" ]] || print -r -- $'tag\tstart\tend\tduration_ms\tlg_px\twokyis_px' > "$out/capture_log.tsv"
print -r -- "$tag"$'\t'"$(iso $t0)"$'\t'"$(iso $t1)"$'\t'"$dur"$'\t'"$lgsz"$'\t'"$wksz" >> "$out/capture_log.tsv"
if [[ "$wksz" != "1280x720" ]]; then echo "capture_pair: second file is $wksz, expected Wokyis 1280x720" >&2; exit 3; fi
"$here/bin/composite" "$lg" "$wk" --out "$out/${tag}_composite.png" --time "$(iso $t0) … $(iso $t1) (${dur} ms)" "$@"
