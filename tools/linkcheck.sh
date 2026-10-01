#!/bin/bash
# linkcheck.sh [README.md] — criterion #10: every RELATIVE link in a Markdown file points to an existing file/dir.
#   Checked: [text](target), ![alt](target), <img src="target">, <a href="target">, reference definitions "[id]: target".
#   Skipped: http(s):, mailto:, other URL schemes, pure #anchors. "#fragment" and "?query" are stripped, %XX decoded,
#   targets resolve relative to the Markdown file's directory; links inside ``` fenced code blocks are ignored.
#   Output: one line per link  "OK|MISSING <line> <target>"  + summary. Exit 0 all present, 1 missing, 2 usage.
set -euo pipefail
md=${1:-README.md}
[ -f "$md" ] || { echo "linkcheck: $md not found" >&2; exit 2; }
dir=$(cd "$(dirname "$md")" && pwd)
/usr/bin/python3 - "$md" "$dir" <<'PY'
import re, sys, os, urllib.parse
md, base = sys.argv[1], sys.argv[2]
pat = [re.compile(r'!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)'),
       re.compile(r'<(?:img|a)\b[^>]*?\b(?:src|href)\s*=\s*"([^"]+)"', re.I),
       re.compile(r'^\s{0,3}\[[^\]]+\]:\s*<?(\S+?)>?(?:\s+.*)?$')]
ok = miss = skip = 0
fence = False
for n, line in enumerate(open(md, encoding='utf-8'), 1):
    if line.lstrip().startswith('```'):
        fence = not fence; continue
    if fence: continue
    for p in pat:
        for m in p.finditer(line):
            t = m.group(1)
            if re.match(r'^[a-zA-Z][a-zA-Z0-9+.-]*:', t) or t.startswith('#'):
                skip += 1; continue
            path = urllib.parse.unquote(t.split('#', 1)[0].split('?', 1)[0])
            if not path: skip += 1; continue
            full = path if path.startswith('/') else os.path.normpath(os.path.join(base, path))
            if os.path.exists(full): ok += 1; print(f"OK\t{n}\t{t}")
            else: miss += 1; print(f"MISSING\t{n}\t{t}\t→ {full}")
print(f"# linkcheck {md}: {ok} ok, {miss} missing, {skip} skipped (external / anchors)")
sys.exit(1 if miss else 0)
PY
