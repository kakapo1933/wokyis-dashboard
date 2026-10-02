#!/bin/bash
# tools/build.sh — build the evidence tools into tools/bin/ (Apple frameworks only; bash 3.2 compatible).
#   core tools (always):  glyphheight fontcal ocr procstat composite   ← src/Common.swift + src/<Tool>.swift
#                         mockup                                       ← Sources/Render/{PanelModel,PanelRenderer,PanelRenderer+Views,L10n}.swift
#                                                                        + src/Mockup.swift
#   optional tools:       amcompare edgecheck winlist logstats         ← built when src/<Tool>.swift exists:
#                         src/Common.swift + src/<Tool>.swift + every src/<Tool>+*.swift (extra files owned by that tool)
#   afterwards: chmod +x the tool scripts and run the quick tool self-tests (tools/selftest.sh; TOOLS_SELFTEST=0 skips them)
# Owner: core (skeleton step); the last block (scripts + self-tests) was added by the tools agent.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
build() {   # build <bin> <files…>
  local out=$1; shift
  swiftc -O -parse-as-library "$@" -o "bin/$out"
  echo "built tools/bin/$out"
}
for t in glyphheight:GlyphHeight fontcal:FontCal ocr:OCR procstat:ProcStat composite:Composite; do
  bin=${t%%:*}; src=${t##*:}
  build "$bin" src/Common.swift "src/$src.swift"
done
build mockup ../Sources/Render/PanelModel.swift ../Sources/Render/PanelRenderer.swift ../Sources/Render/PanelRenderer+Views.swift \
  ../Sources/Render/L10n.swift src/Mockup.swift
for t in amcompare:AMCompare edgecheck:EdgeCheck winlist:WinList logstats:LogStats; do
  bin=${t%%:*}; src=${t##*:}
  if [ -f "src/$src.swift" ]; then
    files=(src/Common.swift "src/$src.swift")
    for extra in src/"$src"+*.swift; do
      if [ -f "$extra" ]; then files+=("$extra"); fi
    done
    build "$bin" "${files[@]}"
  else
    echo "skip tools/bin/$bin (src/$src.swift not present yet)"
  fi
done
chmod +x ./*.sh
if [ "${TOOLS_SELFTEST:-1}" != 0 ] && [ -x bin/amcompare ] && [ -x bin/edgecheck ] && [ -x bin/winlist ] && [ -x bin/logstats ]; then
  ./selftest.sh
fi
