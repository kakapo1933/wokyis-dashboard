import glob, re, os, collections, sys
d = sys.argv[1] if len(sys.argv) > 1 else '.'
def group(label):
    el = label.split('[')[0]; cls = label.split('/')[-1]
    el = re.sub(r'dev\d+(\.\d+)?', 'dev*', el)
    return el, cls
agg = collections.OrderedDict(); total = fails = 0
for f in sorted(glob.glob(f'{d}/data/mockup_*.glyph.tsv')):
    st = os.path.basename(f).replace('.glyph.tsv', '')
    for line in open(f):
        if line.startswith('#') or line.startswith('label\tline'): continue
        p = line.rstrip('\n').split('\t')
        if len(p) < 12: continue
        label, h, minh, res = p[0], int(p[6]), p[10], p[11]
        total += 1; fails += res != 'PASS' and minh not in ('', '-', '0')
        k = group(label)
        a = agg.setdefault(k, {'min': 999, 'max': 0, 'n': 0, 'thr': minh, 'states': set(), 'minlabel': ''})
        if h < a['min']: a['min'] = h; a['minlabel'] = f'{st}:{label}'
        a['max'] = max(a['max'], h); a['n'] += 1; a['states'].add(st)
print(f'total rects={total} fails={fails}')
print('element\tclass\tthreshold\tn\tmin_px\tmax_px\tmin_at')
for (el, cls), a in agg.items():
    print(f"{el}\t{cls}\t{a['thr']}\t{a['n']}\t{a['min']}\t{a['max']}\t{a['minlabel']}")
# per-glyph informational
g = collections.defaultdict(lambda: [999, 0, 0, ''])
for f in sorted(glob.glob(f'{d}/data/mockup_*.perglyph.tsv')):
    st = os.path.basename(f).replace('.perglyph.tsv', '')
    for line in open(f):
        if line.startswith('#') or line.startswith('label\tline'): continue
        p = line.rstrip('\n').split('\t')
        if len(p) < 12: continue
        cls = p[0].split('/')[-1]; h = int(p[6]) if p[6].lstrip('-').isdigit() else -1
        a = g[cls]
        if 0 <= h < a[0]: a[0] = h; a[3] = f'{st}:{p[0]}'
        a[1] = max(a[1], h); a[2] += 1
print('\nper-glyph (informational)\nclass\tn\tmin\tmax\tmin_at')
for cls, a in g.items(): print(f'{cls}\t{a[2]}\t{a[0]}\t{a[1]}\t{a[3]}')
