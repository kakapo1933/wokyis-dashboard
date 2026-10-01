#!/bin/bash
# selftest.sh [--dry-run [OUT_DIR]] — self-tests of the verification tools (no screen capture, no AM access, no panel).
#   quick (default, ~2 s): edgecheck --selftest, winlist --selftest (reads the live display list only),
#                          logstats --selftest, amcompare unittest, linkcheck on a synthetic README
#   --dry-run: additionally `amcompare dry-run --scenario all` (whole criterion-#4 harness on synthetic inputs; needs
#              build/WokyisPanel.app for the offscreen render; ~1–2 min; output in OUT_DIR or $TMPDIR)
# Exit 0 when everything passed. bash 3.2 compatible.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
fail=0
run() { local name=$1; shift; if "$@" > "${TMPDIR:-/tmp}/tools-selftest-$name.txt" 2>&1; then echo "selftest $name: ok"; else echo "selftest $name: FAILED (see ${TMPDIR:-/tmp}/tools-selftest-$name.txt)"; fail=1; fi; }
run edgecheck "$here/bin/edgecheck" --selftest
run winlist "$here/bin/winlist" --selftest
run logstats "$here/bin/logstats" --selftest
run amcompare "$here/bin/amcompare" unittest
lc=$(mktemp -d "${TMPDIR:-/tmp}/linkcheck.XXXXXX")
touch "$lc/present.png"
printf '[a](present.png) [b](https://example.com) [c](#x)\n' > "$lc/ok.md"
printf '[a](present.png) [m](missing.png)\n' > "$lc/bad.md"
if "$here/linkcheck.sh" "$lc/ok.md" > /dev/null && ! "$here/linkcheck.sh" "$lc/bad.md" > /dev/null; then echo "selftest linkcheck: ok"; else echo "selftest linkcheck: FAILED"; fail=1; fi
rm -f "$lc/present.png" "$lc/ok.md" "$lc/bad.md"; rmdir "$lc"
if [ "${1:-}" = --dry-run ]; then
  out=${2:-${TMPDIR:-/tmp}/amcompare-dryrun-$(date +%Y%m%d-%H%M%S)}
  run amcompare-dryrun "$here/bin/amcompare" dry-run --scenario all --out "$out"
  echo "dry-run output: $out"
fi
exit $fail
