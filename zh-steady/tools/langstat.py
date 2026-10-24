# Usage: python3 langstat.py <host-label> [--json]
# Per assistant text block: language, mid-turn vs final, tool calls since last human msg, last tool_result language.
import json, glob, os, re, sys, time
home = os.path.expanduser('~'); cutoff = time.time() - 60*86400
def lang(t):
    t = re.sub(r"```.*?```|`[^`]*`|https?://\S+|\S*/\S+", "", t, flags=re.S)
    lat = len(re.findall(r"[A-Za-z]", t)); cjk = len(re.findall(r"[一-鿿]", t))
    if lat + cjk < 40: return None
    return 'zh' if cjk / (lat/4 + cjk) > 0.3 else 'en'
rows = []
for f in glob.glob(f'{home}/.claude/projects/*/*.jsonl'):
    if os.path.getmtime(f) < cutoff or 'skillgenie' in f or '-tmp-' in f or 'var-folders' in f: continue
    ev = []
    for l in open(f, errors='ignore'):
        try: d = json.loads(l)
        except: continue
        if d.get('isSidechain'): continue
        ev.append(d)
    ntools = 0; trl = None; ulang = None; lastkind = None; textsince = 0
    pending = []
    for i, d in enumerate(ev):
        m = d.get('message') or {}; c = m.get('content')
        if d.get('type') == 'user':
            if isinstance(c, list) and any(isinstance(b, dict) and b.get('type') == 'tool_result' for b in c):
                s = ' '.join(json.dumps(b.get('content'), ensure_ascii=False)[:5000] for b in c if isinstance(b, dict))
                trl = lang(s) or trl; lastkind = 'tool_result'; continue
            txt = c if isinstance(c, str) else ' '.join(b.get('text', '') for b in (c or []) if isinstance(b, dict))
            if '<task-notification>' in txt: lastkind = 'notif'; continue
            if d.get('isMeta') or txt.startswith('<') or 'This session is being continued' in txt:
                lastkind = 'meta'; continue
            # human message closes the turn: last text row before it is final
            if pending: pending[-1]['final'] = 1
            pending = []; ntools = 0; ulang = lang(txt); lastkind = 'user'; textsince = 0
        elif d.get('type') == 'assistant' and isinstance(c, list):
            for b in c:
                if b.get('type') == 'tool_use': ntools += 1
                if b.get('type') == 'text':
                    lg = lang(b.get('text', ''))
                    if lg:
                        r = {'h': sys.argv[1], 'lang': lg, 'final': 0, 'ntools': ntools, 'trl': trl, 'after': lastkind,
                             'ulang': ulang, 'model': m.get('model'), 'ver': d.get('version'), 'ts': (d.get('timestamp') or '')[:10]}
                        rows.append(r); pending.append(r)
            lastkind = 'assistant'
    if pending: pending[-1]['final'] = 1
if '--json' in sys.argv: json.dump(rows, sys.stdout); sys.exit()
# Summary: English rate of mid-turn narration vs final replies, by week (Chinese prompts only).
import collections
g = collections.defaultdict(lambda: [0, 0])
for r in rows:
    if r['ulang'] == 'en' or not (r['model'] or '').startswith('claude'): continue
    k = (r['ts'][:8] + ('01' if r['ts'][8:] < '15' else '15'), 'final' if r['final'] else 'mid')
    g[k][0] += r['lang'] == 'en'; g[k][1] += 1
for k in sorted(g): print(*k, f"{g[k][0]}/{g[k][1]} = {100*g[k][0]/g[k][1]:.0f}%")
