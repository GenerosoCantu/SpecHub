#!/usr/bin/env python3
"""Lineup check behind scripts/models.sh. See that script's header for the CLI.

Reads Anthropic's pricing page (a markdown table) and compares it with metrics/prices.tsv and the
tier pins in spechub.conf. It reports; it changes nothing unless `upgrade --apply` is given, and then
it writes prices only through `metrics.sh price`, so prices.tsv keeps a single writer.
"""
import sys, os, re, time, subprocess, urllib.request

HUB        = os.environ.get('HUB_DIR') or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PRICES     = os.path.join(HUB, 'metrics', 'prices.tsv')
CONF       = os.path.join(HUB, 'spechub.conf')
EXAMPLE    = os.path.join(HUB, 'spechub.conf.example')
AGENTS_DIR = os.path.join(HUB, '.claude', 'agents')
CHEATSHEET = os.path.join(HUB, 'WORKFLOW-CHEATSHEET.md')
STAMP      = os.path.join(HUB, '.run', 'models-check.stamp')
URL        = 'https://platform.claude.com/docs/en/about-claude/pricing.md'
HOOK_EVERY = 7 * 86400

TIERS    = [('Light', 'MODEL_LIGHT', 'haiku'), ('Standard', 'MODEL_STANDARD', 'sonnet'),
            ('Advanced', 'MODEL_ADVANCED', 'opus')]
FAMILIES = ('fable', 'mythos', 'opus', 'sonnet', 'haiku')


class PageError(Exception):
    pass


def fetch_page():
    req = urllib.request.Request(URL, headers={'User-Agent': 'spechub-models-check'})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read().decode('utf-8', 'replace')


def money(cell):
    m = re.search(r'\$\s*([\d.]+)', cell)
    return float(m.group(1)) if m else None


def parse_page(text):
    """{model_id: {'name', 'family', 'version', 'in', 'out', 'cread', 'retired'}} from the first
    table under '## Model pricing'. Haiku 5.5's long-prompt card (over 100K tokens) is skipped:
    prices.tsv holds one row per model, the short-prompt card."""
    at = text.find('## Model pricing')
    if at < 0:
        raise PageError("no '## Model pricing' section")
    models, started = {}, False
    for ln in text[at:].splitlines()[1:]:
        if not ln.startswith('|'):
            if started:
                break
            continue
        started = True
        cells = [c.strip() for c in ln.strip().strip('|').split('|')]
        if len(cells) < 6 or not cells[0].startswith('Claude'):
            continue
        raw = cells[0]
        if re.search(r'over [\d,]+ tokens', raw):
            continue
        retired = 'retired' in raw.lower()
        name = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', raw)
        name = re.sub(r'\s*\([^)]*\)', '', name).strip()
        m = re.match(r'^Claude (\w+) ([\d.]+)$', name)
        if not m or m.group(1).lower() not in FAMILIES:
            continue
        fam, ver = m.group(1).lower(), m.group(2)
        pin, hit, pout = money(cells[1]), money(cells[4]), money(cells[5])
        if not (pin and pout and hit is not None):
            continue
        mid = 'claude-%s-%s' % (fam, ver.replace('.', '-'))
        models[mid] = {'name': name, 'family': fam, 'version': tuple(int(x) for x in ver.split('.')),
                       'in': pin, 'out': pout, 'cread': round(hit / pin, 4), 'retired': retired}
    current = {v['family'] for v in models.values() if not v['retired']}
    if len(models) < 5 or not {'opus', 'sonnet', 'haiku'} <= current:
        raise PageError('pricing table not recognised (%d models parsed) — the page layout changed' % len(models))
    return models


def read_prices():
    rows = {}
    for ln in open(PRICES, encoding='utf-8'):
        if ln.startswith('#') or not ln.strip():
            continue
        f = ln.rstrip('\n').split('\t')
        if len(f) >= 4:
            rows[f[0]] = {'in': float(f[1]), 'out': float(f[2]), 'cread': float(f[3])}
    return rows


def read_pins():
    pins = {}
    for ln in open(CONF, encoding='utf-8'):
        m = re.match(r'^(MODEL_LIGHT|MODEL_STANDARD|MODEL_ADVANCED|AGENT_CLI)="([^"]*)"', ln)
        if m:
            pins[m.group(1)] = m.group(2)
    return pins


def newest(page, family):
    cands = [(v['version'], k) for k, v in page.items() if v['family'] == family and not v['retired']]
    return max(cands)[1] if cands else None


def plan(page):
    """(price_changes, new_models, tier_moves) — everything check reports and upgrade applies."""
    have = read_prices()
    # A model is "new" only when it is newer than every priced model of its family. An older model
    # nobody used stays unpriced; `metrics.sh prices` asks for it the day the ledger records it.
    priced_top = {}
    for mid in have:
        if mid in page:
            f = page[mid]['family']
            priced_top[f] = max(priced_top.get(f, ()), page[mid]['version'])
    changes, new = [], []
    for mid, p in sorted(page.items()):
        if mid in have:
            h = have[mid]
            if any(abs(h[k] - p[k]) > 1e-9 for k in ('in', 'out', 'cread')):
                changes.append((mid, h, p))
        elif not p['retired'] and p['version'] > priced_top.get(p['family'], ()):
            new.append((mid, p))
    # Only a pinned Claude tier can fall behind: an unpinned one runs the CLI's alias, which already
    # follows the newest model, and codex/copilot tiers use ids this page does not list.
    pins, moves = read_pins(), []
    for tier, var, fam in TIERS:
        cur, top = pins.get(var), newest(page, fam)
        if pins.get('AGENT_CLI', 'claude') != 'claude' or not (cur or '').startswith('claude-'):
            continue
        if not top or cur == top:
            continue
        cur_v = page.get(cur, {}).get('version')
        if cur_v is None or page[top]['version'] > cur_v:
            moves.append((tier, var, cur, top))
    return changes, new, moves


def fmt_row(p):
    return '$%g in / $%g out, cache read %gx' % (p['in'], p['out'], p['cread'])


def describe(page, changes, new, moves):
    out = []
    for mid, h, p in changes:
        out.append('price changed  %s: %s -> %s' % (mid, fmt_row(h), fmt_row(p)))
    for mid, p in new:
        out.append('new model      %s (%s): %s' % (mid, p['name'], fmt_row(p)))
    for tier, var, cur, top in moves:
        out.append('newer model    %s is pinned to %s; newest %s is %s'
                   % (tier, cur or '(unpinned)', page[top]['family'].capitalize(), top))
    return out


def write_stamp():
    os.makedirs(os.path.dirname(STAMP), exist_ok=True)
    open(STAMP, 'w').write(time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))


def cmd_check(argv):
    hook = '--hook' in argv
    if hook and os.path.exists(STAMP) and time.time() - os.path.getmtime(STAMP) < HOOK_EVERY:
        return 0
    try:
        page = parse_page(fetch_page())
    except PageError as e:
        print('[models] %s. Check %s by hand and update scripts/models.py.' % (e, URL))
        return 0 if hook else 2
    except Exception as e:  # offline, timeout, DNS: never block a session
        if hook:
            return 0
        print('[models] could not fetch %s: %s' % (URL, e), file=sys.stderr)
        return 2
    write_stamp()
    lines = describe(page, *plan(page))
    if not lines:
        if not hook:
            print('[models] prices.tsv and the tier pins match the pricing page (%d models).' % len(page))
        return 0
    if hook:
        print('[models] The Anthropic model lineup changed since the hub was last updated:')
    for ln in lines:
        print(('  ' if hook else '') + ln)
    if hook:
        print('[models] Tell the user, and that `scripts/models.sh upgrade` shows the plan '
              '(`--apply` carries it out). Do not apply it unasked.')
        return 0
    print('\nRun `scripts/models.sh upgrade` for the plan, `upgrade --apply` to carry it out.')
    return 1


def replace_in(path, old, new, count_hint):
    s = open(path, encoding='utf-8').read()
    if old not in s:
        print('  [warn] %s: %r not found — update it by hand' % (os.path.relpath(path, HUB), old))
        return
    open(path, 'w', encoding='utf-8').write(s.replace(old, new))
    print('  %s: %s -> %s' % (os.path.relpath(path, HUB), old, new) + (' (%s)' % count_hint if count_hint else ''))


def move_tier(page, tier, var, cur, top):
    s = open(CONF, encoding='utf-8').read()
    s2, n = re.subn(r'^#?\s*%s="[^"]*"' % var, '%s="%s"' % (var, top), s, flags=re.M)
    if not n:
        s2 = s.rstrip('\n') + '\n%s="%s"\n' % (var, top)
    open(CONF, 'w', encoding='utf-8').write(s2)
    print('  spechub.conf: %s="%s"' % (var, top))
    # bootstrap.sh init copies its pins from the example, so a new hub starts on the current lineup.
    if os.path.exists(EXAMPLE):
        s = open(EXAMPLE, encoding='utf-8').read()
        s2, n = re.subn(r'^%s="claude-[^"]*"' % var, '%s="%s"' % (var, top), s, flags=re.M)
        if n:
            open(EXAMPLE, 'w', encoding='utf-8').write(s2)
            print('  spechub.conf.example: %s="%s"' % (var, top))
    if tier == 'Standard':
        for f in sorted(os.listdir(AGENTS_DIR)):
            p = os.path.join(AGENTS_DIR, f)
            s = open(p, encoding='utf-8').read()
            s2 = re.sub(r'^(model:\s*)(%s|sonnet)(?=\s|$)' % re.escape(cur or 'sonnet'), r'\g<1>' + top, s, flags=re.M)
            if s2 != s:
                open(p, 'w', encoding='utf-8').write(s2)
                print('  .claude/agents/%s: model: %s' % (f, top))
    if cur and cur in page:
        replace_in(CHEATSHEET, '| %s |' % page[cur]['name'], '| %s |' % page[top]['name'], tier)
        s = open(CHEATSHEET, encoding='utf-8').read()
        if '`%s`' % cur in s:
            open(CHEATSHEET, 'w', encoding='utf-8').write(s.replace('`%s`' % cur, '`%s`' % top))


def cmd_upgrade(argv):
    apply = '--apply' in argv
    try:
        page = parse_page(fetch_page())
    except Exception as e:
        print('[models] cannot build a plan: %s' % e, file=sys.stderr)
        return 2
    write_stamp()
    changes, new, moves = plan(page)
    lines = describe(page, changes, new, moves)
    if not lines:
        print('[models] nothing to do: prices.tsv and the tier pins match the pricing page.')
        return 0
    print('[models] plan:' if not apply else '[models] applying:')
    for ln in lines:
        print('  ' + ln)
    if not apply:
        print('\nPrices re-price all of history on the next render (hub sessions and dispatch runs alike).'
              '\nA tier move changes the model of every later run. Re-run with --apply to carry it out.')
        return 0
    metrics = os.path.join(HUB, 'scripts', 'metrics.sh')
    sys.stdout.flush()
    for mid, p in [(m, p) for m, _h, p in changes] + new:
        subprocess.run([metrics, 'price', mid, '%.2f' % p['in'], '%.2f' % p['out'], '%g' % p['cread']], check=True)
    for tier, var, cur, top in moves:
        move_tier(page, tier, var, cur, top)
    print('\n[models] done. Review with `git diff`, then commit. `scripts/metrics.sh render` re-prices the board.')
    return 0


def main(argv):
    cmd = argv[0] if argv else ''
    if cmd == 'check':
        return cmd_check(argv[1:])
    if cmd == 'upgrade':
        return cmd_upgrade(argv[1:])
    print('usage: models.sh check [--hook] | upgrade [--apply]', file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
