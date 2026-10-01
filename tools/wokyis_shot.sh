#!/bin/bash
# wokyis_shot.sh OUT.png — capture ONLY the Wokyis (1280x720) with one `screencapture -x lg wk` call.
# The main-display (LG) image is written to a private mktemp dir and deleted immediately, so no picture of the
# user's other windows is kept. Prints "t0 t1 ms" (epoch seconds with ms). Exit 3 if the 2nd image is not 1280x720.
# bash 3.2 compatible.
set -euo pipefail
out=${1:?usage: wokyis_shot.sh OUT.png}
mkdir -p "$(dirname "$out")"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/wokyis_shot.XXXXXX")
trap 'rm -f "$tmp/lg.png" "$tmp/wk.png"; rmdir "$tmp" 2>/dev/null || true' EXIT
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
t0=$(now)
/usr/sbin/screencapture -x "$tmp/lg.png" "$tmp/wk.png"
t1=$(now)
rm -f "$tmp/lg.png"
sz=$(sips -g pixelWidth -g pixelHeight "$tmp/wk.png" 2>/dev/null | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w"x"h}')
if [ "$sz" != "1280x720" ]; then echo "wokyis_shot: second image is $sz, expected 1280x720" >&2; exit 3; fi
mv "$tmp/wk.png" "$out"
echo "$t0 $t1 $(perl -e "printf '%d', ($t1-$t0)*1000")"
