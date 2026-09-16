#!/usr/bin/env python3
"""Ledger + views behind scripts/metrics.sh. See that script's header for the CLI.

One append-only JSONL ledger (metrics/ledger.jsonl) is the only state. Every view — the terminal
report, METRICS.md — is a pure function of it, so deleting a view and regenerating it is a no-op.

Cost provenance is tracked, never guessed: dispatch runs carry the cost the CLI reported; hub
sessions carry a cost derived from token counts and metrics/prices.tsv. `selftest` proves the
derivation reproduces reported costs to the cent. A model with no price row yields None, not a
guess.
"""
import sys, os, json, re, glob, datetime, collections

HUB    = os.environ.get('HUB_DIR') or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LEDGER = os.path.join(HUB, 'metrics', 'ledger.jsonl')
PRICES = os.path.join(HUB, 'metrics', 'prices.tsv')
CONF   = os.path.join(HUB, 'spechub.conf')
SCHEMA = 1

# Which WORKFLOW step a skill belongs to, and the tier policy that step is supposed to run on.
STEP_OF = {'bootstrap-specs': 0, 'cascade-and-prompt': 2, 'dispatch-prompts': 3, 'close-loop': 4}
STEP_NAME = {0: 'bootstrap', 1: 'design', 2: 'cascade & prompt', 3: 'dispatch', 4: 'close-loop'}
POLICY_TIER = {0: 'Standard', 1: 'Advanced', 2: 'Standard', 3: 'Standard', 4: 'Standard'}
TOKEN_KEYS = ('in', 'out', 'cache_read', 'cache_write_5m', 'cache_write_1h', 'thinking')


def warn(m): print('[metrics] %s' % m, file=sys.stderr)
def die(m):  warn('ERROR: ' + m); sys.exit(1)
def now_iso(): return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


# --------------------------------------------------------------------------- prices & cost
def load_prices():
    out = {}
    if not os.path.exists(PRICES):
        warn('metrics/prices.tsv missing — hub-session costs will read n/a.')
        return out
    for ln in open(PRICES, encoding='utf-8'):
        ln = ln.rstrip('\n')
        if not ln.strip() or ln.lstrip().startswith('#'):
            continue
        p = ln.split('\t')
        if len(p) < 3:
            continue
        try:
            out[p[0].strip()] = (float(p[1]), float(p[2]),
                                 float(p[3]) if len(p) > 3 and p[3].strip() else 0.1,
                                 p[4].strip() if len(p) > 4 else '')
        except ValueError:
            continue
    return out


PRICE = load_prices()
_unpriced = set()


ALIASES = {'haiku', 'sonnet', 'opus', 'light', 'standard', 'advanced', 'small', 'medium', 'large'}


def norm_model(m):
    """claude-haiku-4-5-20251001 -> claude-haiku-4-5. Price rows are kept undated."""
    return re.sub(r'-\d{8}$', '', m or '')


def is_alias(m):
    """True for a bare tier alias ('sonnet') logged before dispatch.sh recorded model ids. The
    exact model behind it is not recoverable, so it is shown marked rather than guessed into one."""
    return (m or '').strip().lower() in ALIASES


def show_model(m):
    return ('%s*' % m) if is_alias(m) else norm_model(m)


def cost_of(model, tk):
    """Exact derivation; None when the model has no price row (never an estimate).

    cost = (in*Pin + out*Pout + cache_read*Pin*m + w5*Pin*1.25 + w1*Pin*2.0) / 1e6
    """
    p = PRICE.get(norm_model(model))
    if not p:
        if model and model not in _unpriced:
            _unpriced.add(model)
            warn('no price row for %r — tokens kept, cost is n/a. Add it to metrics/prices.tsv.' % model)
        return None
    pin, pout, crm, _ = p
    return (tk.get('in', 0) * pin
            + tk.get('out', 0) * pout
            + tk.get('cache_read', 0) * pin * crm
            + tk.get('cache_write_5m', 0) * pin * 1.25
            + tk.get('cache_write_1h', 0) * pin * 2.0) / 1e6


# Lineup-wide ratios, used when a model has no price row. Verified across every row of
# prices.tsv: output is 5.00x input for every current model, cache read 0.1x (0.025x on
# Claude Fable 5.1). These RATIOS are far more stable than the absolute prices.
DEFAULT_OUT_RATIO = 5.0
DEFAULT_CREAD_MULT = 0.1


def ite(model, tk):
    """Input-Token Equivalents — usage in a unit that no price change can move.

    ITE = in + (Pout/Pin)*out + cread_mult*cache_read + 1.25*write_5m + 2.0*write_1h

    It is the cost formula divided by the input price, so within one model it is exactly
    proportional to cost: dollars = ITE * Pin / 1e6. Re-pricing the table re-derives every
    dollar figure in history and leaves ITE untouched, which is the point.

    It depends on the price RATIOS, not their level. Falls back to the lineup-wide ratios for an
    unpriced model rather than returning nothing — unlike dollars, a usage figure is still
    meaningful without a price row.
    """
    p = PRICE.get(norm_model(model))
    out_ratio = (p[1] / p[0]) if p and p[0] else DEFAULT_OUT_RATIO
    crm = p[2] if p else DEFAULT_CREAD_MULT
    return (tk.get('in', 0)
            + out_ratio * tk.get('out', 0)
            + crm * tk.get('cache_read', 0)
            + 1.25 * tk.get('cache_write_5m', 0)
            + 2.0 * tk.get('cache_write_1h', 0))


def ite_of_models(models):
    return sum(ite(m, tk) for m, tk in (models or {}).items())


def raw_tokens(models):
    """Unweighted token count — the rawest usage figure there is. Comparable within one vendor's
    tokenizer only; see the cross-agent caveat in the board."""
    t = {}
    for _m, tk in (models or {}).items():
        add_tk(t, tk)
    return sum(t.get(k, 0) for k in TOKEN_KEYS if k != 'thinking')


def add_tk(a, b):
    for k in TOKEN_KEYS:
        a[k] = a.get(k, 0) + b.get(k, 0)
    return a


def sum_models(models):
    """Total cost across a {model: tokens} map. None if ANY model is unpriced — a partial
    total presented as a whole is worse than an honest n/a."""
    tot, ok = 0.0, True
    for m, tk in (models or {}).items():
        c = cost_of(m, tk)
        if c is None: ok = False
        else: tot += c
    return tot if ok else None


def usage_tokens(u):
    """Token block from a Claude `usage` object, splitting cache writes by TTL.

    The split matters: a 5-minute write bills at 1.25x input, a 1-hour write at 2.0x. When the
    breakdown is absent we attribute to 5m, the API default, rather than inventing the dearer one.
    """
    cc = u.get('cache_creation') or {}
    total_w = u.get('cache_creation_input_tokens', 0) or 0
    if cc:
        w5 = cc.get('ephemeral_5m_input_tokens', 0) or 0
        w1 = cc.get('ephemeral_1h_input_tokens', 0) or 0
    else:
        w5, w1 = total_w, 0
    return {'in': u.get('input_tokens', 0) or 0,
            'out': u.get('output_tokens', 0) or 0,
            'cache_read': u.get('cache_read_input_tokens', 0) or 0,
            'cache_write_5m': w5, 'cache_write_1h': w1,
            'thinking': (u.get('output_tokens_details') or {}).get('thinking_tokens', 0) or 0}


# --------------------------------------------------------------------------- hub facts
def services():
    if not os.path.exists(CONF):
        return []
    m = re.search(r'SERVICES="(.*?)"', open(CONF, encoding='utf-8').read(), re.S)
    return [ln.split('|')[0] for ln in m.group(1).strip().splitlines() if ln.strip()] if m else []


SERVICES = services()


def feature_of(name):
    """PROMPT-{service}-{feature}[.md] / FEATURE-{feature}.md -> the feature slug.

    Strips the LONGEST matching service name, mirroring dispatch.sh prompt_service() so the two
    always agree on where the service ends and the feature begins.
    """
    b = re.sub(r'\.md$', '', os.path.basename(name or ''))
    if b.startswith('FEATURE-'):
        return b[len('FEATURE-'):] or None
    b = re.sub(r'^PROMPT-', '', b)
    best = ''
    for s in SERVICES:
        if b.startswith(s + '-') and len(s) > len(best):
            best = s
    return (b[len(best) + 1:] if best else b) or None


def service_of(name):
    b = re.sub(r'\.md$', '', os.path.basename(name or ''))
    b = re.sub(r'^PROMPT-', '', b)
    best = ''
    for s in SERVICES:
        if b.startswith(s + '-') and len(s) > len(best):
            best = s
    return best or None


def known_features():
    """Every feature slug the hub has a file for — the vocabulary a skill's arguments are
    matched against. Longest-first so 'section-latest-news-block' beats 'section-latest'."""
    out = set()
    for pat in ('Prompts/PROMPT-*.md', 'Prompts/Implemented/PROMPT-*.md',
                'Features/FEATURE-*.md', 'Features/Implemented/FEATURE-*.md',
                'Features/Staled/FEATURE-*.md'):
        for f in glob.glob(os.path.join(HUB, pat)):
            fe = feature_of(f)
            if fe:
                out.add(fe)
    return sorted(out, key=len, reverse=True)


KNOWN_FEATURES = known_features()

# Matches Prompts/PROMPT-x.md, PROMPT-x, FEATURE-x.md — with or without directory or extension.
FEATURE_REF = re.compile(r'(?:FEATURE|PROMPT)-([A-Za-z0-9\-]+?)(?:\.md)?(?=[\s"\',;:)\]]|$)')


def hdr(path, key):
    try:
        s = open(path, encoding='utf-8', errors='replace').read()
    except OSError:
        return ''
    m = re.search(r'^>\s*\*\*%s:\*\*\s*(.+?)\s*$' % re.escape(key), s, re.M)
    return m.group(1).strip() if m else ''


# --------------------------------------------------------------------------- ledger
def read_ledger(path=LEDGER):
    out = []
    if not os.path.exists(path):
        return out
    for ln in open(path, encoding='utf-8'):
        ln = ln.strip()
        if not ln:
            continue
        try:
            e = json.loads(ln)
        except json.JSONDecodeError:
            continue
        if e.get('schema', 1) > SCHEMA:
            die('ledger holds schema v%s; this script speaks v%s. Upgrade scripts/metrics.py.'
                % (e['schema'], SCHEMA))
        out.append(e)
    return out


def append(ev):
    os.makedirs(os.path.dirname(LEDGER), exist_ok=True)
    with open(LEDGER, 'a', encoding='utf-8') as f:
        f.write(json.dumps(ev, sort_keys=True) + '\n')


def rewrite(evs):
    tmp = LEDGER + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        for e in evs:
            f.write(json.dumps(e, sort_keys=True) + '\n')
    os.replace(tmp, LEDGER)


def flags(argv):
    out, i = {}, 0
    while i < len(argv):
        a = argv[i]
        if a.startswith('--'):
            k = a[2:].replace('-', '_')
            if i + 1 < len(argv) and not argv[i + 1].startswith('--'):
                out[k] = argv[i + 1]; i += 2
            else:
                out[k] = '1'; i += 1
        else:
            i += 1
    return out


def as_int(v, d=None):
    try: return int(float(v))
    except (TypeError, ValueError): return d


def as_float(v, d=None):
    try: return float(v)
    except (TypeError, ValueError): return d


# --------------------------------------------------------------------------- emit
def parse_run_json(path, agent):
    """Session id, turns, tokens, per-model split and reported cost from an agent's run log.

    Per-agent dialects live here, next to dispatch.sh summarize_run()'s equivalent case block.
    Anything the agent does not report comes back None and is rendered n/a — never inferred.
    """
    out = {'session_id': None, 'turns': None, 'cost_usd': None, 'cost_basis': None,
           'tokens': None, 'models': None, 'duration_ms': None, 'api_ms': None}
    if not path or not os.path.exists(path) or os.path.getsize(path) == 0:
        return out
    if agent == 'claude':
        try:
            d = json.load(open(path, encoding='utf-8'))
        except (json.JSONDecodeError, OSError):
            return out
        u = d.get('usage') or {}
        out['session_id'] = d.get('session_id')
        out['turns'] = d.get('num_turns')
        out['cost_usd'] = d.get('total_cost_usd')
        out['cost_basis'] = 'reported' if out['cost_usd'] is not None else None
        out['duration_ms'] = d.get('duration_ms')
        out['api_ms'] = d.get('duration_api_ms')
        out['tokens'] = usage_tokens(u)
        mu, models = d.get('modelUsage') or {}, {}
        # modelUsage has no per-model TTL split; attribute writes by the session-wide ratio.
        tot_w = (out['tokens']['cache_write_5m'] + out['tokens']['cache_write_1h']) or 1
        r1h = out['tokens']['cache_write_1h'] / tot_w
        for m, v in mu.items():
            w = v.get('cacheCreationInputTokens', 0) or 0
            models[m] = {'in': v.get('inputTokens', 0) or 0,
                         'out': v.get('outputTokens', 0) or 0,
                         'cache_read': v.get('cacheReadInputTokens', 0) or 0,
                         'cache_write_1h': int(round(w * r1h)),
                         'cache_write_5m': w - int(round(w * r1h)),
                         'thinking': v.get('thinkingTokens', 0) or 0}
        out['models'] = models or None
    elif agent == 'codex':
        txt = open(path, encoding='utf-8', errors='replace').read()
        m = re.search(r'"thread_id":"([^"]+)"', txt)
        out['session_id'] = m.group(1) if m else None
        n = len(re.findall(r'"turn\.completed"', txt))
        out['turns'] = n or None
        # Best effort, and UNVERIFIED against a real Codex log — this hub runs claude. Codex
        # reports usage on turn.completed; key names are accepted in several spellings because
        # the exact ones could not be confirmed here. Anything unmatched stays 0 rather than
        # being invented, and a run with no usage simply reports no tokens.
        tk = {'in': 0, 'out': 0, 'cache_read': 0, 'cache_write_5m': 0, 'cache_write_1h': 0}
        found = False
        for ln in txt.splitlines():
            if '"turn.completed"' not in ln:
                continue
            try:
                u = (json.loads(ln).get('usage') or {})
            except json.JSONDecodeError:
                continue
            if not u:
                continue
            found = True
            tk['in'] += u.get('input_tokens', u.get('prompt_tokens', 0)) or 0
            tk['out'] += u.get('output_tokens', u.get('completion_tokens', 0)) or 0
            tk['cache_read'] += (u.get('cached_input_tokens')
                                 or u.get('cache_read_input_tokens') or 0)
        if found:
            out['tokens'] = tk
            # Cross-vendor note: these are OpenAI-tokeniser tokens. The board never sums them
            # with Anthropic tokens; see the "Usage by agent" section.
    elif agent == 'copilot':
        txt = open(path, encoding='utf-8', errors='replace').read()
        m = re.search(r'session[^0-9a-f]{0,20}([0-9a-f-]{36})', txt, re.I)
        out['session_id'] = m.group(1) if m else None
    return out


def cmd_emit(argv):
    if not argv:
        die('usage: metrics.sh emit <event> [flags]')
    event, f = argv[0], flags(argv[1:])
    if event not in ('dispatch_run', 'dispatch_resume', 'verify', 'merge'):
        die('unknown event %r' % event)

    prompt_path = f.get('prompt', '')
    prompt = re.sub(r'\.md$', '', os.path.basename(prompt_path)) if prompt_path else None
    prior = read_ledger()
    ev = {'schema': SCHEMA, 'ts': now_iso(), 'event': event,
          'feature': f.get('feature') or feature_of(prompt_path),
          'prompt': prompt,
          'service': f.get('service') or service_of(prompt_path)}

    if event in ('dispatch_run', 'dispatch_resume'):
        agent = f.get('agent', 'claude')
        r = parse_run_json(f.get('json'), agent)
        ev.update({
            'step': 3,
            'repo': os.path.basename(f.get('repo', '') or '') or None,
            'branch': f.get('branch') or None,
            'agent': agent,
            'tier': f.get('tier') or None,
            'model': f.get('model') or None,
            'run_id': f.get('run_id') or None,
            'session_id': f.get('session_id') or r['session_id'],
            'result': f.get('result', 'ok'),
            'turns': as_int(f.get('turns'), r['turns']),
            'wall_ms': as_int(f.get('wall_ms')),
            'duration_ms': r['duration_ms'],
            'api_ms': r['api_ms'],
            'tokens': r['tokens'],
            'models': r['models'],
            'cost_usd': as_float(f.get('cost_usd'), r['cost_usd']),
            'cost_basis': r['cost_basis'] or ('reported' if f.get('cost_usd') else None),
            'commits': as_int(f.get('commits')),
            'diagnosis': f.get('diagnosis') or None,
            'attempt': 1 + sum(1 for e in prior if e.get('prompt') == prompt
                               and e.get('event') in ('dispatch_run', 'dispatch_resume')),
        })
    elif event == 'verify':
        res = f.get('result', 'pass')
        ev.update({'step': 3, 'result': res, 'by': f.get('by') or None,
                   'reason': f.get('reason') if res == 'fail' else None,
                   'attempt': 1 + sum(1 for e in prior
                                      if e.get('prompt') == prompt and e.get('event') == 'verify')})
    elif event == 'merge':
        firsts = [e['ts'] for e in prior
                  if e.get('prompt') == prompt and e.get('event') == 'dispatch_run' and e.get('ts')]
        lead = None
        if firsts:
            try:
                t0 = datetime.datetime.strptime(min(firsts), '%Y-%m-%dT%H:%M:%SZ')
                t1 = datetime.datetime.strptime(ev['ts'], '%Y-%m-%dT%H:%M:%SZ')
                lead = int((t1 - t0).total_seconds() * 1000)
            except ValueError:
                lead = None
        ev.update({'step': 4, 'base': f.get('base') or None,
                   'merge_sha': f.get('merge_sha') or None,
                   'impl_shas': [s for s in (f.get('impl_shas') or '').split() if s] or None,
                   'pushed': f.get('pushed') in ('1', 'yes', 'true'),
                   'lead_time_ms': lead})
    append(ev)
    return 0


# --------------------------------------------------------------------------- hub sessions
def transcript_dir():
    return os.path.join(os.path.expanduser('~'), '.claude', 'projects',
                        re.sub(r'[^A-Za-z0-9]', '-', HUB))


def transcript_files(path):
    """The main transcript plus every subagent transcript Claude Code wrote for that session.

    A forked skill (`context: fork` into hub-ops), an Agent-tool subagent or a spec-writer runs as a
    sidechain that Claude Code stores in <dir>/<session-id>/subagents/agent-*.jsonl, not inline.
    Its tokens are most of a dispatch or close-out session's spend and its tool calls are the writes
    that name the feature — the main file alone under-counts the cost and mis-tiers the model.
    """
    sid = os.path.basename(path)[:-6] if path.endswith('.jsonl') else os.path.basename(path)
    subs = sorted(glob.glob(os.path.join(os.path.dirname(path), sid, 'subagents', '*.jsonl')))
    return [path] + subs


def transcript_bytes(path):
    return sum(os.path.getsize(p) for p in transcript_files(path) if os.path.exists(p))


def parse_transcript(path):
    """Per-model tokens, skill, feature and wall time from one Claude Code transcript.

    Two attribution rules are load-bearing, and both were wrong in the obvious implementation:

    * The SKILL comes from `Skill` tool_use blocks parsed as JSON — never a grep for the skill
      name. A grep is contaminated by tool OUTPUT: any session that prints a skill name (as any
      session inspecting this hub does) would tag itself with that skill.
    * The FEATURE comes from every tool input including `Bash` commands, not just Write/Edit
      file_path. Hub sessions create these files with heredocs and sed, so a Write/Edit-only
      scan finds nothing at all.
    * Subagent transcripts (see transcript_files) are read as part of the session. Without them a
      forked close-out recorded a dozen Opus messages from the main thread and none of the seventy
      Sonnet messages that did the work — wrong cost, wrong model, and no feature to bill.
    """
    per = collections.defaultdict(dict)
    msgs = side = 0
    first = last = None
    skills, touched, touched_any = set(), collections.Counter(), collections.Counter()
    sid = None
    wrote_feature_file = False
    seen = set()

    def lines():
        for i, fpath in enumerate(transcript_files(path)):
            for ln in open(fpath, encoding='utf-8', errors='replace'):
                yield i > 0, ln

    for in_subagent, line in lines():
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        uid = d.get('uuid')
        if uid:
            if uid in seen:
                continue
            seen.add(uid)
        if not in_subagent:
            sid = sid or d.get('sessionId')
        ts = d.get('timestamp')
        if ts:
            first = first or ts
            last = ts
        typ = d.get('type')
        msg = d.get('message') or {}
        content = msg.get('content')

        if typ == 'assistant':
            model = msg.get('model')
            if model and msg.get('usage'):
                add_tk(per[model], usage_tokens(msg['usage']))
                per[model]['messages'] = per[model].get('messages', 0) + 1
                msgs += 1
                if in_subagent or d.get('isSidechain'):
                    side += 1
            for b in content if isinstance(content, list) else []:
                if not isinstance(b, dict) or b.get('type') != 'tool_use':
                    continue
                name, inp = b.get('name'), b.get('input') or {}
                if name == 'Skill' and inp.get('skill'):
                    skills.add(inp['skill'])
                    # A skill is invoked with the feature as its argument — the single most
                    # direct statement of what the session is for. Match the args against the
                    # hub's own feature vocabulary rather than re-deriving a slug from prose.
                    args = str(inp.get('args', ''))
                    for fe in KNOWN_FEATURES:
                        if fe in args:
                            touched[fe] += 3
                            touched_any[fe] += 3
                            break
                blob = ' '.join(str(v) for v in inp.values() if isinstance(v, str))
                # Only a WRITE claims a feature. Reading a prompt file (grep, cat, sed -n) is what
                # any session inspecting the hub does — including this metrics work — so counting
                # reads would bill unrelated sessions to whichever feature they happened to look at.
                if name in ('Write', 'Edit', 'NotebookEdit'):
                    writes = True
                elif name == 'Bash':
                    cmd = str(inp.get('command', ''))
                    writes = bool(re.search(r'(?<![0-9<])>{1,2}(?!&)|\bsed\s+-i|\btee\b|\bmv\b|'
                                            r'\bcp\b|\bgit\s+mv\b', cmd))
                else:
                    writes = False
                for m in FEATURE_REF.finditer(blob):
                    fe = feature_of(m.group(0))
                    if not fe:
                        continue
                    touched_any[fe] += 1
                    if writes:
                        touched[fe] += 1
                        if m.group(0).startswith('FEATURE-') and fe in KNOWN_FEATURES:
                            wrote_feature_file = True

        # Slash-command markers live in plain user text. tool_result blocks are also type "user",
        # so restrict to string/text content or a session that merely echoed the marker self-tags.
        if typ == 'user':
            txt = content if isinstance(content, str) else ' '.join(
                b.get('text', '') for b in (content if isinstance(content, list) else [])
                if isinstance(b, dict) and b.get('type') == 'text')
            for m in re.finditer(r'<command-name>/([a-z0-9\-]+)</command-name>', txt or ''):
                if m.group(1) in STEP_OF:
                    skills.add(m.group(1))

    skill = sorted(skills & set(STEP_OF))[0] if (skills & set(STEP_OF)) else None
    step = STEP_OF.get(skill)
    # A skill-bearing session is a workflow step for exactly one feature by construction, so a
    # mere reference is enough to own it — a dispatch or close-out session drives scripts and may
    # never write the prompt file itself. Without a skill, require a WRITE: any session poking
    # around the hub reads these files, and reads must not bill it to whatever it looked at.
    pool = (touched_any or touched) if skill else touched
    feature = pool.most_common(1)[0][0] if pool else None
    # Step 1 design is the one step with no skill, so it can only be recognised by what it does:
    # write the feature file itself. Merely mentioning a feature is not enough — this workspace's
    # own framework sessions quote prompt and feature paths constantly, and inferring "design"
    # from a mention billed an unrelated session to a feature during development of this script.
    if step is None:
        if wrote_feature_file:
            step = 1
        else:
            feature = None
    wall = None
    if first and last:
        try:
            fmt = '%Y-%m-%dT%H:%M:%S'
            t0 = datetime.datetime.strptime(first[:19], fmt)
            t1 = datetime.datetime.strptime(last[:19], fmt)
            wall = int((t1 - t0).total_seconds() * 1000)
        except ValueError:
            wall = None
    return {'session_id': sid, 'models': dict(per), 'assistant_messages': msgs,
            'subagent_messages': side, 'skill': skill, 'step': step, 'feature': feature,
            'started': first, 'wall_ms': wall}


def session_event(path, backfilled=False):
    r = parse_transcript(path)
    if not r['models']:
        return None
    models = {}
    for m, tk in r['models'].items():
        models[m] = {k: tk.get(k, 0) for k in TOKEN_KEYS}
        models[m]['messages'] = tk.get('messages', 0)
    ev = {'schema': SCHEMA, 'ts': r['started'] or now_iso(), 'event': 'hub_session',
          'agent': 'claude',   # transcripts in ~/.claude/projects are Claude Code's, by definition
          'step': r['step'], 'feature': r['feature'], 'skill': r['skill'],
          'session_id': r['session_id'] or os.path.basename(path)[:36],
          'models': models, 'assistant_messages': r['assistant_messages'],
          'subagent_messages': r['subagent_messages'], 'wall_ms': r['wall_ms'],
          'transcript_bytes': transcript_bytes(path),
          'cost_usd': sum_models(models), 'cost_basis': 'derived'}
    if backfilled:
        ev['backfilled'] = True
    return ev


def stale_transcripts(evs, extra=()):
    """Transcripts with no hub_session row, or one recorded from fewer bytes than are on disk.

    A transcript only grows — a resumed session, a forked subagent finishing late — so the byte
    count over main + subagent files is the change detector, and re-recording is idempotent.
    """
    have = {e.get('session_id'): e for e in evs if e.get('event') == 'hub_session'}
    paths = sorted(set(glob.glob(os.path.join(transcript_dir(), '*.jsonl')))
                   | {p for p in extra if p and os.path.exists(p)})
    out = []
    for p in paths:
        old = have.get(os.path.basename(p)[:36])
        if old and old.get('transcript_bytes') == transcript_bytes(p):
            continue
        out.append((p, old))
    return out


def sync_transcripts(extra=(), quiet=False, backfilled=False):
    """Bring the ledger up to date with every transcript on disk.

    The SessionEnd hook is the intended recorder, but it does not fire when the IDE window is
    closed or the process is killed, and a session resumed after it fired keeps spending. So
    recording is not an event but a reconciliation: the hooks, `sync`, `report` and `render` all
    call this, and whichever runs next records what the others missed.
    """
    evs = read_ledger()
    fresh, drop = {}, set()
    for p, old in stale_transcripts(evs, extra):
        ev = session_event(p, backfilled=backfilled or bool(old and old.get('backfilled')))
        if ev:
            fresh[ev['session_id']] = ev
            drop |= {ev['session_id'], os.path.basename(p)[:36]}
    if not fresh:
        return 0
    evs = [e for e in evs if not (e.get('event') == 'hub_session' and e.get('session_id') in drop)]
    evs.extend(fresh.values())
    evs.sort(key=lambda e: e.get('ts') or '')
    rewrite(evs)
    if not quiet:
        for ev in sorted(fresh.values(), key=lambda e: e['ts']):
            c = ev['cost_usd']
            warn('hub session %s recorded — step %s, %s, %s, %d+%d msgs, %s' % (
                ev['session_id'][:8], '?' if ev['step'] is None else ev['step'],
                ev['skill'] or 'no skill', ev['feature'] or 'no feature',
                ev['assistant_messages'] - ev['subagent_messages'], ev['subagent_messages'],
                ('$%.2f' % c) if c is not None else 'cost n/a'))
    return len(fresh)


def cmd_session(argv):
    f = flags(argv)
    path = f.get('transcript')
    if not path and not sys.stdin.isatty():
        try:
            payload = json.loads(sys.stdin.read() or '{}')
            path = payload.get('transcript_path') or path
        except (json.JSONDecodeError, OSError):
            pass
    # The hook's own transcript is merely the likeliest to have changed; everything else on disk is
    # checked too, so a session that ended without its hook is recorded by the next session's.
    sync_transcripts(extra=[path] if path else (), quiet=f.get('quiet') == '1')
    return 0


def cmd_sync(argv):
    f = flags(argv)
    n = sync_transcripts(quiet=f.get('quiet') == '1')
    if f.get('quiet') != '1':
        print('[metrics] %d hub session(s) recorded or updated.' % n)
    return 0


# --------------------------------------------------------------------------- selftest
def cmd_selftest(argv):
    """Recompute every reported cost from tokens. A price row that drifts fails here rather
    than turning into silently wrong dollars on the board."""
    runs = sorted(glob.glob(os.path.join(HUB, '.dispatch', 'runs', '*.json')))
    checked = bad = 0
    worst = 0.0
    for path in runs:
        try:
            d = json.load(open(path, encoding='utf-8'))
        except (json.JSONDecodeError, OSError):
            continue
        u = d.get('usage') or {}
        cc = u.get('cache_creation') or {}
        tot_w = (cc.get('ephemeral_5m_input_tokens', 0) + cc.get('ephemeral_1h_input_tokens', 0)) or 1
        r1h = cc.get('ephemeral_1h_input_tokens', 0) / tot_w
        for m, v in (d.get('modelUsage') or {}).items():
            reported = v.get('costUSD')
            if reported is None:
                continue
            w = v.get('cacheCreationInputTokens', 0) or 0
            w1 = int(round(w * r1h))
            tk = {'in': v.get('inputTokens', 0), 'out': v.get('outputTokens', 0),
                  'cache_read': v.get('cacheReadInputTokens', 0),
                  'cache_write_1h': w1, 'cache_write_5m': w - w1}
            derived = cost_of(m, tk)
            if derived is None:
                print('  SKIP  %-30s no price row' % m)
                continue
            delta = abs(derived - reported)
            worst = max(worst, delta)
            checked += 1
            flag = 'ok  ' if delta <= 1e-4 else 'FAIL'
            if delta > 1e-4:
                bad += 1
            print('  %s  %-30s derived $%.6f  reported $%.6f  delta $%.8f'
                  % (flag, m, derived, reported, delta))
    # ITE and cost are computed by separate functions; if they ever disagree, the price-free
    # unit has stopped being proportional to cost and every usage figure becomes untrustworthy.
    ite_bad = 0
    for m, (pin, _po, _cm, _v) in PRICE.items():
        probe = {'in': 1234, 'out': 567, 'cache_read': 890123, 'cache_write_5m': 4321,
                 'cache_write_1h': 8765}
        c, u = cost_of(m, probe), ite(m, probe) * pin / 1e6
        if abs(c - u) > 1e-9:
            ite_bad += 1
            print('  FAIL  %-30s ITE*Pin $%.9f != cost $%.9f' % (m, u, c))
    print('  ok    ITE x input price == cost for all %d priced model(s)' % len(PRICE)
          if not ite_bad else '  %d model(s) FAILED the ITE proportionality check' % ite_bad)

    if not checked:
        warn('no .dispatch/runs/*.json with a reported cost on this machine — cost derivation unchecked.')
        return 1 if ite_bad else 0
    print('\n%d model-run(s) checked, %d failed, worst delta $%.8f' % (checked, bad, worst))
    bad += ite_bad
    if bad:
        warn('metrics/prices.tsv disagrees with the costs the CLI reported — fix the price rows.')
        return 1
    print('Derived cost formula reproduces every reported cost. Hub-session costs are exact.')
    return 0


# --------------------------------------------------------------------------- backfill
RUN_HEADS = re.compile(r'^### (Run|Resume|Verified|Merged) — (.+)$', re.M)


def report_entries(path):
    """Every '### Kind — when' block of a prompt's Dispatch Run Report, as (kind, when, rows)."""
    try:
        s = open(path, encoding='utf-8', errors='replace').read()
    except OSError:
        return []
    heads = list(RUN_HEADS.finditer(s))
    out = []
    for i, m in enumerate(heads):
        body = s[m.end():heads[i + 1].start() if i + 1 < len(heads) else len(s)]
        rows = {}
        for r in re.finditer(r'^\|\s*([^|]+?)\s*\|\s*(.*?)\s*\|$', body, re.M):
            k = r.group(1).strip()
            if k and k != 'Field' and not set(k) <= set('-: '):
                rows[k] = r.group(2).strip()
        out.append((m.group(1), m.group(2).strip(), rows))
    return out


def ts_of(when):
    """A report-table time is LOCAL (dispatch.sh now() uses `date` with no -u); the ledger is UTC.

    Stamping the local string with a 'Z' put every backfilled event hours before the hub session
    that produced it, so runs sorted ahead of the dispatch that launched them. Convert properly.
    """
    for fmt in ('%Y-%m-%d %H:%M', '%Y-%m-%d'):
        try:
            naive = datetime.datetime.strptime(when, fmt)
        except ValueError:
            continue
        return (naive.astimezone()              # attach the machine's local zone
                .astimezone(datetime.timezone.utc)
                .strftime('%Y-%m-%dT%H:%M:%SZ'))
    return None


def cmd_backfill(argv):
    f = flags(argv)
    dry = f.get('dry_run') == '1'
    have_runs = {e.get('run_id') for e in read_ledger()}
    have_keys = {(e.get('prompt'), e.get('event'), e.get('ts')) for e in read_ledger()}
    new = []

    prompts = sorted(glob.glob(os.path.join(HUB, 'Prompts', 'PROMPT-*.md'))
                     + glob.glob(os.path.join(HUB, 'Prompts', 'Implemented', 'PROMPT-*.md')))
    for path in prompts:
        name = re.sub(r'\.md$', '', os.path.basename(path))
        feature, service = feature_of(path), service_of(path)
        branch = (hdr(path, 'Branch') or '').split()[0] if hdr(path, 'Branch') else None
        for kind, when, rows in report_entries(path):
            ts = ts_of(when) or now_iso()
            if kind in ('Run', 'Resume'):
                log = re.sub(r'^`|`$', '', rows.get('Log', ''))
                run_id = re.sub(r'\.json$', '', os.path.basename(log)) if log else None
                if run_id and run_id in have_runs:
                    continue
                # Two generations of report table: "Agent / model" today, bare "Model" before it.
                agent_model = rows.get('Agent / model', '')
                if agent_model:
                    agent = agent_model.split('/')[0].strip() or 'claude'
                    model = agent_model.split('/')[-1].strip()
                else:
                    agent, model = 'claude', (rows.get('Model') or '').strip() or None
                r = parse_run_json(os.path.join(HUB, log) if log else None, agent)
                tc = rows.get('Turns / cost', '')
                turns = as_int(tc.split('/')[0].strip()) if '/' in tc else None
                cost = as_float(tc.split('$')[-1].strip()) if '$' in tc else None
                res = rows.get('Result', 'ok')
                result = 'ok' if res.startswith('ok') else ('aborted' if 'ABORT' in res else 'error')
                ev = {'schema': SCHEMA, 'ts': ts,
                      'event': 'dispatch_run' if kind == 'Run' else 'dispatch_resume',
                      'step': 3, 'feature': feature, 'prompt': name, 'service': service,
                      'branch': branch, 'agent': agent, 'tier': None,
                      'model': model, 'run_id': run_id,
                      'session_id': r['session_id'] or re.sub(r'^`|`$', '', rows.get('Session ID', '')) or None,
                      'result': result, 'turns': r['turns'] if r['turns'] is not None else turns,
                      'wall_ms': None, 'duration_ms': r['duration_ms'], 'api_ms': r['api_ms'],
                      'tokens': r['tokens'], 'models': r['models'],
                      'cost_usd': r['cost_usd'] if r['cost_usd'] is not None else cost,
                      'cost_basis': 'reported' if (r['cost_usd'] is not None or cost is not None) else None,
                      'commits': None, 'diagnosis': rows.get('Diagnosis') or None,
                      'attempt': None, 'backfilled': True}
                # The table stores a tier alias ("sonnet"); the run JSON has the real model id.
                # Prefer the id, picking the costliest when a run used several.
                if r['models']:
                    ev['model'] = max(r['models'], key=lambda m: cost_of(m, r['models'][m]) or 0)
                new.append(ev)
            elif kind == 'Verified':
                if (name, 'verify', ts) in have_keys:
                    continue
                new.append({'schema': SCHEMA, 'ts': ts, 'event': 'verify', 'step': 3,
                            'feature': feature, 'prompt': name, 'service': service,
                            'result': 'pass', 'by': rows.get('Verified by') or None,
                            'reason': None, 'attempt': None, 'backfilled': True})
            elif kind == 'Merged':
                if (name, 'merge', ts) in have_keys:
                    continue
                into = rows.get('Into', '')
                new.append({'schema': SCHEMA, 'ts': ts, 'event': 'merge', 'step': 4,
                            'feature': feature, 'prompt': name, 'service': service,
                            'base': (re.findall(r'`([^`]+)`', into) or [None])[0],
                            'merge_sha': (re.findall(r'`([^`@]+)`', into) or [None, None])[-1],
                            'impl_shas': re.findall(r'`([0-9a-f]{6,40})`',
                                                    rows.get('Implementing commits', '')) or None,
                            'pushed': rows.get('Pushed', '').lower().startswith(('yes', 'true')),
                            'lead_time_ms': None, 'backfilled': True})

    # Hub sessions: the transcripts are on disk, so the framework's larger half is recoverable too.
    hub_new = stale_transcripts(read_ledger())

    if dry:
        print('DRY RUN — would add %d dispatch/verify/merge event(s) and %d hub session(s).'
              % (len(new), len(hub_new)))
        for e in new:
            print('  %s  %-14s %s' % (e['ts'], e['event'], e.get('prompt')))
        for p, old in hub_new:
            print('  %-20s hub_session    %s%s' % ('', os.path.basename(p)[:8],
                                                  ' (update)' if old else ''))
        return 0

    evs = read_ledger() + new
    # Lead time needs both ends, so it can only be filled once every backfilled run exists.
    firsts = {}
    for e in evs:
        if e.get('event') == 'dispatch_run' and e.get('ts'):
            k = e.get('prompt')
            firsts[k] = min(firsts.get(k, e['ts']), e['ts'])
    for e in evs:
        if e.get('event') == 'merge' and e.get('lead_time_ms') is None and e.get('prompt') in firsts:
            try:
                t0 = datetime.datetime.strptime(firsts[e['prompt']], '%Y-%m-%dT%H:%M:%SZ')
                t1 = datetime.datetime.strptime(e['ts'], '%Y-%m-%dT%H:%M:%SZ')
                e['lead_time_ms'] = max(0, int((t1 - t0).total_seconds() * 1000))
            except (ValueError, KeyError):
                pass
    evs.sort(key=lambda e: e.get('ts') or '')
    rewrite(evs)
    n = sync_transcripts(quiet=True, backfilled=True)
    print('[metrics] backfilled %d run/verify/merge event(s) and %d hub session(s).' % (len(new), n))
    return 0


# --------------------------------------------------------------------------- stats helpers
def pct(n, d): return (100.0 * n / d) if d else 0.0


def median(xs):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0


def p90(xs):
    xs = sorted(x for x in xs if x is not None)
    return xs[min(len(xs) - 1, int(round(0.9 * (len(xs) - 1))))] if xs else None


def dur(ms):
    if ms is None:
        return 'n/a'
    s = ms / 1000.0
    if s < 90:
        return '%.0fs' % s
    m = s / 60.0
    if m < 90:
        return '%dm %02ds' % (int(m), int(s - 60 * int(m)))
    h = m / 60.0
    return '%dh %02dm' % (int(h), int(m - 60 * int(h)))


def money(v): return 'n/a' if v is None else '$%.2f' % v

def kt(n):
    """Compact token count: 1_727_035 -> 1.73M."""
    if n is None:
        return 'n/a'
    if n >= 1e6:
        return '%.2fM' % (n / 1e6)
    if n >= 1e3:
        return '%.0fK' % (n / 1e3)
    return str(int(n))



class Stats:
    """Everything both views need, computed once from the ledger."""

    def __init__(self, evs):
        self.evs = evs
        self.runs = [e for e in evs if e.get('event') in ('dispatch_run', 'dispatch_resume')]
        self.first_runs = [e for e in evs if e.get('event') == 'dispatch_run']
        self.resumes = [e for e in evs if e.get('event') == 'dispatch_resume']
        self.verifies = [e for e in evs if e.get('event') == 'verify']
        self.merges = [e for e in evs if e.get('event') == 'merge']
        self.hub = [e for e in evs if e.get('event') == 'hub_session']
        ts = [e['ts'] for e in evs if e.get('ts')]
        self.window = (min(ts)[:10], max(ts)[:10]) if ts else ('—', '—')
        self.features = sorted({e['feature'] for e in evs if e.get('feature')})

    # -- health
    def run_failure_rate(self):
        bad = [e for e in self.runs if e.get('result') in ('error', 'aborted')]
        return pct(len(bad), len(self.runs)), len(bad), len(self.runs)

    def verify_pass_rate(self):
        firsts = {}
        for e in sorted(self.verifies, key=lambda e: e.get('ts') or ''):
            firsts.setdefault(e.get('prompt'), e)
        ok = [e for e in firsts.values() if e.get('result') == 'pass']
        return pct(len(ok), len(firsts)), len(ok), len(firsts)

    def first_pass(self):
        """Prompts dispatched once, never resumed, and verified on the first look."""
        prompts = {e['prompt'] for e in self.first_runs if e.get('prompt')}
        good = 0
        for p in prompts:
            runs = [e for e in self.runs if e.get('prompt') == p]
            if len(runs) != 1 or runs[0].get('result') != 'ok':
                continue
            vs = [e for e in self.verifies if e.get('prompt') == p]
            if vs and sorted(vs, key=lambda e: e['ts'])[0].get('result') != 'pass':
                continue
            good += 1
        return pct(good, len(prompts)), good, len(prompts)

    def resumes_per_feature(self):
        c = collections.Counter()
        for f in self.features:
            c[f] = sum(1 for e in self.resumes if e.get('feature') == f)
        return list(c.values())

    # -- cost
    def feature_cost(self, feature):
        hub = [e for e in self.hub if e.get('feature') == feature]
        run = [e for e in self.runs if e.get('feature') == feature]
        h = sum(e['cost_usd'] for e in hub if e.get('cost_usd') is not None)
        d = sum(e['cost_usd'] for e in run if e.get('cost_usd') is not None)
        # No sessions at all is unknown, not zero. A feature whose hub sessions predate the
        # ledger must not be reported as having cost nothing to design.
        h_na = not hub or any(e.get('cost_usd') is None for e in hub)
        d_na = not run or any(e.get('cost_usd') is None for e in run)
        return {'hub': None if h_na else h, 'dispatch': None if d_na else d,
                # A partial total is worse than an honest one: keep it when either half is known,
                # but flag it so the view can mark it incomplete rather than pretending.
                'total': None if (h_na and d_na) else (h + d),
                'partial': h_na or d_na,
                'runs': len(run), 'resumes': sum(1 for e in run if e['event'] == 'dispatch_resume'),
                'sessions': len(hub),
                'verify_attempts': len([e for e in self.verifies if e.get('feature') == feature])}

    def totals(self):
        h = sum(e['cost_usd'] for e in self.hub if e.get('cost_usd') is not None)
        d = sum(e['cost_usd'] for e in self.runs if e.get('cost_usd') is not None)
        return h, d

    def by_step(self):
        out = collections.defaultdict(lambda: {'n': 0, 'runs': 0, 'models': collections.Counter(), 'cost': 0.0})
        for e in self.hub:
            s = e.get('step')
            r = out[s]
            r['n'] += 1
            r['runs'] = r.get('runs', 0)
            r['cost'] += e.get('cost_usd') or 0.0
            for m in (e.get('models') or {}):
                r['models'][m] += 1
        for e in self.first_runs + self.resumes:
            r = out[3]
            r['models'][e.get('model') or 'unknown'] += 1
            r['runs'] = r.get('runs', 0) + 1
        return out

    # -- per-step breakdown
    BUCKETS = [('1', '1 design'), ('2', '2 cascade & prompt'), ('3h', '3 dispatch (hub)'),
               ('3r', '3 headless runs'), ('4', '4 close-loop'), ('?', 'unattributed')]

    @staticmethod
    def bucket_of(e):
        """Which step bucket an event belongs to. Step 3 splits in two: the hub session that
        drives the dispatcher, and the headless runs it launches — they are different money."""
        if e.get('event') in ('dispatch_run', 'dispatch_resume'):
            return '3r'
        if e.get('event') != 'hub_session':
            return None
        st = e.get('step')
        if st == 3:
            return '3h'
        return str(st) if st in (0, 1, 2, 4) else '?'

    def step_totals(self):
        """bucket -> {cost, tokens, n, durations} across everything in scope."""
        out = collections.defaultdict(
            lambda: {'cost': 0.0, 'n': 0, 'tokens': {}, 'dur': [], 'unpriced': False,
                     'tok_n': 0, 'models': collections.Counter()})
        for e in self.hub + self.runs:
            b = self.bucket_of(e)
            if b is None:
                continue
            r = out[b]
            r['n'] += 1
            if e.get('cost_usd') is None:
                r['unpriced'] = True
            else:
                r['cost'] += e['cost_usd']
            r['dur'].append(e.get('wall_ms') or e.get('duration_ms'))
            for m, tk in (e.get('models') or {}).items():
                add_tk(r['tokens'], tk)
                r['models'][m] += 1
            if not e.get('models') and e.get('tokens'):
                add_tk(r['tokens'], e['tokens'])
            if e.get('models') or e.get('tokens'):
                r['tok_n'] += 1
        return out

    def step_matrix(self):
        """feature -> bucket -> cost. The 'for each step, for each feature' view."""
        m = collections.defaultdict(lambda: collections.defaultdict(lambda: None))
        for e in self.hub + self.runs:
            b = self.bucket_of(e)
            fe = e.get('feature')
            if b is None or not fe or e.get('cost_usd') is None:
                continue
            cur = m[fe][b]
            m[fe][b] = (cur or 0.0) + e['cost_usd']
        return m

    def usage_by(self, keyfn):
        """Usage grouped by any key, in price-free units. No dollars anywhere in here."""
        out = collections.defaultdict(lambda: {'n': 0, 'ite': 0.0, 'raw': 0, 'tokens': {},
                                               'tok_n': 0, 'agents': set(), 'models': collections.Counter()})
        for e in self.hub + self.runs:
            k = keyfn(e)
            if k is None:
                continue
            r = out[k]
            r['n'] += 1
            r['agents'].add(e.get('agent') or 'claude')
            models = e.get('models') or ({'?': e['tokens']} if e.get('tokens') else {})
            if models:
                r['tok_n'] += 1
            for m, tk in models.items():
                add_tk(r['tokens'], tk)
                r['models'][m] += 1
            r['ite'] += ite_of_models(models)
            r['raw'] += raw_tokens(models)
        return out

    def repriced(self):
        """(billed, repriced) — what the CLI reported vs what the same tokens cost at today's
        table. A gap means prices moved since the run, not that anything is wrong."""
        billed = repriced = 0.0
        for e in self.runs:
            if e.get('cost_usd') is None or not e.get('models'):
                continue
            rp = sum_models(e['models'])
            if rp is None:
                continue
            billed += e['cost_usd']
            repriced += rp
        return billed, repriced

    def failure_patterns(self):
        c = collections.Counter()
        last = {}
        for e in self.runs:
            if e.get('result') in ('error', 'aborted') and e.get('diagnosis'):
                key = re.split(r'[—:(]', e['diagnosis'])[0].strip()[:60]
                c[key] += 1
                last[key] = max(last.get(key, ''), e.get('ts', ''))
        return [(k, n, last.get(k, '')[:10]) for k, n in c.most_common()]


# --------------------------------------------------------------------------- views
def coverage_note(st):
    agents = {e.get('agent') for e in st.runs if e.get('agent')}
    n = len(st.hub)
    note = '%d hub session(s)' % n
    if n:
        note += ' (claude transcripts, forked subagents included)'
    if agents - {'claude'}:
        note += '; token/cost detail is unavailable for %s runs' % ', '.join(sorted(agents - {'claude'}))
    return note


def sync_quietly():
    """A view first reconciles the transcripts, but a transcript it cannot parse must not cost
    the view: the ledger it already has is still worth showing."""
    try:
        sync_transcripts(quiet=True)
    except Exception as exc:                                       # noqa: BLE001
        warn('transcript sync failed (%s: %s) — showing the ledger as is.' % (type(exc).__name__, exc))


def cmd_report(argv):
    f = flags(argv)
    sync_quietly()
    evs = read_ledger()
    if f.get('feature'):
        evs = [e for e in evs if e.get('feature') == f['feature']]
    if f.get('days'):
        cut = (datetime.datetime.now(datetime.timezone.utc)
               - datetime.timedelta(days=as_int(f['days'], 30))).strftime('%Y-%m-%dT%H:%M:%SZ')
        evs = [e for e in evs if (e.get('ts') or '') >= cut]
    if not evs:
        print('[metrics] ledger is empty — run: scripts/metrics.sh backfill')
        return 0
    st = Stats(evs)
    h, d = st.totals()

    print('SpecHub metrics — %s to %s' % st.window)
    print('%d feature(s) · %d dispatch run(s) · %s' % (len(st.features), len(st.runs), coverage_note(st)))
    print('Dollar figures are API-list value (tokens x list prices), not an invoice — the plan is flat-fee.\n')

    print('HEALTH')
    r, a, b = st.first_pass();      print('  first-pass success (run once, verified first look)  %5.0f%%  %d/%d' % (r, a, b))
    r, a, b = st.run_failure_rate();print('  dispatch run failure rate (error or aborted)        %5.0f%%  %d/%d' % (r, a, b))
    r, a, b = st.verify_pass_rate();print('  human verification pass rate (first look)           %5.0f%%  %d/%d' % (r, a, b))
    rs = st.resumes_per_feature()
    print('  resumes per feature                                 %5s   p90 %s'
          % (median(rs) if rs else 'n/a', p90(rs) if rs else 'n/a'))
    lt = [e.get('lead_time_ms') for e in st.merges]
    print('  dispatch → merge lead time (median)                 %5s   p90 %s' % (dur(median(lt)), dur(p90(lt))))
    wl = [e.get('wall_ms') or e.get('duration_ms') for e in st.runs]
    print('  headless session duration (median)                  %5s   p90 %s' % (dur(median(wl)), dur(p90(wl))))

    print('\nAPI-LIST VALUE')
    tot = h + d
    print('  hub sessions      %10s   %4.1f%%   (derived)' % (money(h), pct(h, tot)))
    print('  dispatched runs   %10s   %4.1f%%   (reported)' % (money(d), pct(d, tot)))
    print('  total             %10s' % money(tot))
    billed, rp = st.repriced()
    if billed and abs(billed - rp) > 0.005:
        print('  reprice check     %10s reported vs %s at today\'s table — prices moved %+.1f%%'
              % (money(billed), money(rp), pct(rp - billed, billed)))
    cr = 0.0
    for e in st.hub + st.runs:
        for m, tk in (e.get('models') or {}).items():
            p = PRICE.get(norm_model(m))
            if p:
                cr += tk.get('cache_read', 0) * p[0] * p[2] / 1e6
    if tot:
        print('  of which context re-read %6s   %4.1f%% of everything' % (money(cr), pct(cr, tot)))

    ub = st.usage_by(lambda e: e.get('agent') or 'claude')
    if len(ub) > 1 or f.get('units') == 'tokens':
        print('\nUSAGE BY AGENT (price-free — never summed across agents)')
        print('  %-12s %5s %12s %12s  %s' % ('agent', 'n', 'raw tokens', 'ITE', 'models'))
        for k in sorted(ub):
            r = ub[k]
            print('  %-12s %5d %12s %12s  %s'
                  % (k, r['n'], kt(r['raw']), kt(r['ite']),
                     ', '.join(show_model(m) for m in sorted(r['models']))[:40]))
        print('  Tokenisers differ between vendors, so these columns are NOT a common currency.')
        print('  Compare agents on outcomes (first-pass rate, resumes, duration) and API-list value.')

    us = st.usage_by(Stats.bucket_of)
    if us:
        print('\nUSAGE BY STEP (price-free)')
        print('  %-20s %5s %8s %8s %10s %9s %11s %11s'
              % ('step', 'n', 'in', 'out', 'cache rd', 'cache wr', 'raw tokens', 'ITE'))
        tot_ite = sum(r['ite'] for r in us.values()) or 1
        for key, label in Stats.BUCKETS:
            if key not in us:
                continue
            r = us[key]
            tk = r['tokens']
            print('  %-20s %5d %8s %8s %10s %9s %11s %11s %5.1f%%'
                  % (label, r['n'], kt(tk.get('in')), kt(tk.get('out')), kt(tk.get('cache_read')),
                     kt(tk.get('cache_write_5m', 0) + tk.get('cache_write_1h', 0)),
                     kt(r['raw']), kt(r['ite']), pct(r['ite'], tot_ite)))
        print('  ITE = input-token equivalents: in + 5xout + 0.1xcache_read + 1.25xwrite_5m + 2xwrite_1h.')
        print('  Proportional to API-list value within a model, and unchanged by any price change.')

    sts = st.step_totals()
    if sts:
        print('\nAPI-LIST VALUE BY STEP')
        print('  %-20s %5s %9s %6s  %8s %8s %10s %9s  %s'
              % ('step', 'n', 'value', 'share', 'in', 'out', 'cache rd', 'cache wr', 'median dur'))
        for key, label in Stats.BUCKETS:
            if key not in sts:
                continue
            r = sts[key]
            tk = r['tokens']
            mark = '' if r['tok_n'] >= r['n'] else '*'
            print('  %-20s %5d %9s %5.1f%%  %8s %8s %9s%1s %9s  %s'
                  % (label, r['n'], money(None if r['unpriced'] and not r['cost'] else r['cost']),
                     pct(r['cost'], tot), kt(tk.get('in')), kt(tk.get('out')),
                     kt(tk.get('cache_read')), mark,
                     kt(tk.get('cache_write_5m', 0) + tk.get('cache_write_1h', 0)),
                     dur(median(r['dur']))))
        if any(v['tok_n'] < v['n'] for v in sts.values()):
            print('  * token totals cover only the runs whose JSON log still exists; value is complete.')

    if f.get('feature'):
        print('\nSESSIONS AND RUNS FOR %s' % f['feature'])
        print('  %-18s %-10s %-22s %9s %10s %9s  %s'
              % ('step', 'id', 'model', 'value', 'tokens', 'duration', 'detail'))
        for e in sorted(st.hub + st.runs, key=lambda e: e.get('ts') or ''):
            b = Stats.bucket_of(e)
            label = dict(Stats.BUCKETS).get(b, '?')
            models = e.get('models') or {}
            mname = ', '.join(show_model(m) for m in sorted(models)) or show_model(e.get('model'))
            tks = {}
            for _m, _tk in models.items():
                add_tk(tks, _tk)
            if not models and e.get('tokens'):
                tks = e['tokens']
            detail = e.get('skill') or e.get('prompt') or ''
            print('  %-18s %-10s %-22s %9s %10s %9s  %s'
                  % (label, (e.get('session_id') or '')[:8], mname[:22], money(e.get('cost_usd')),
                     kt(sum(tks.get(k, 0) for k in TOKEN_KEYS if k != 'thinking') or None),
                     dur(e.get('wall_ms') or e.get('duration_ms')), detail[:40]))

    rows = [(fe, st.feature_cost(fe)) for fe in st.features]
    rows = [r for r in rows if r[1]['total'] is not None]
    if rows:
        rows.sort(key=lambda r: -(r[1]['total'] or 0))
        print('\nAPI-LIST VALUE PER FEATURE')
        print('  %-34s %9s %9s %9s  %s' % ('feature', 'hub', 'dispatch', 'total', 'runs/res/ver'))
        for fe, c in rows[:12]:
            print('  %-34s %9s %9s %9s  %d/%d/%d'
                  % (fe[:34], money(c['hub']), money(c['dispatch']), money(c['total']),
                     c['runs'], c['resumes'], c['verify_attempts']))
        tl = [c['total'] for _, c in rows]
        print('  %-34s %9s %9s %9s' % ('median', money(median([c['hub'] for _, c in rows])),
                                       money(median([c['dispatch'] for _, c in rows])), money(median(tl))))

    bs = st.by_step()
    if bs:
        print('\nMODEL USE BY STEP (policy conformance)')
        print('  %-22s %-10s %5s  %-40s %s' % ('step', 'policy', 'units', 'actual', 'off-policy'))
        for s in sorted(bs, key=lambda x: (x is None, x)):
            r = bs[s]
            name = STEP_NAME.get(s, 'unattributed')
            pol = POLICY_TIER.get(s, '—') if s is not None else '—'
            actual = ', '.join('%s (%d)' % (show_model(m), n) for m, n in r['models'].most_common(3))
            off = off_policy(s, r['models'])
            print('  %-22s %-10s %5d  %-40s %s'
                  % ('%s %s' % (s if s is not None else '?', name), pol,
                     r['runs'] if s == 3 else r['n'], actual[:40], off if off else '0'))

    fp = st.failure_patterns()
    if fp:
        print('\nFAILURE PATTERNS')
        for k, n, when in fp:
            print('  %-58s %3d   last %s' % (k[:58], n, when or '—'))
    return 0


def tier_of_model(model):
    """Map a concrete model back to a tier, for policy conformance. Reads spechub.conf when it
    pins models per tier; otherwise falls back to the model family."""
    m = norm_model(model or '')
    if not m:
        return None
    conf = open(CONF, encoding='utf-8').read() if os.path.exists(CONF) else ''
    for tier, var in (('Light', 'MODEL_LIGHT'), ('Standard', 'MODEL_STANDARD'), ('Advanced', 'MODEL_ADVANCED')):
        hit = re.search(r'^%s="([^"]+)"' % var, conf, re.M)
        if hit and norm_model(hit.group(1)) == m:
            return tier
    if 'haiku' in m: return 'Light'
    if 'sonnet' in m: return 'Standard'
    if 'opus' in m or 'fable' in m: return 'Advanced'
    return None


def off_policy(step, models):
    """Hub sessions that ran a model above the step's policy tier. Step 3 dispatch is excluded:
    each prompt names its own tier, so there is no single policy to violate."""
    if step is None or step == 3:
        return 0
    want = POLICY_TIER.get(step)
    if not want:
        return 0
    rank = {'Light': 0, 'Standard': 1, 'Advanced': 2}
    return sum(n for m, n in models.items()
               if rank.get(tier_of_model(m), 1) > rank.get(want, 1))


# --------------------------------------------------------------------------- render
def feature_numbers():
    """slug -> STATUS.md feature number, resolved once at render time so no emitter ever has to
    parse STATUS.md. Matching is by the archived feature file's title words, loosely."""
    path = os.path.join(HUB, 'STATUS.md')
    if not os.path.exists(path):
        return {}
    out = {}
    for m in re.finditer(r'^\|\s*(\d+)\s*\|\s*([^|]+?)\s*\|', open(path, encoding='utf-8').read(), re.M):
        slug = re.sub(r'[^a-z0-9]+', '-', m.group(2).lower()).strip('-')
        out[slug] = int(m.group(1))
    return out


def num_for(slug, numbers):
    if slug in numbers:
        return numbers[slug]
    words = set(slug.split('-'))
    best, score = None, 0
    for k, v in numbers.items():
        s = len(words & set(k.split('-')))
        if s > score:
            best, score = v, s
    return best if score >= 2 else None


def cmd_render(argv):
    sync_quietly()
    evs = read_ledger()
    out = os.path.join(HUB, 'METRICS.md')
    if not evs:
        with open(out, 'w', encoding='utf-8') as f:
            f.write('# %s — SpecHub Metrics\n\n> Ledger is empty. Run `scripts/metrics.sh backfill`.\n'
                    % project_name())
        print('[metrics] METRICS.md written (empty ledger).')
        return 0
    st = Stats(evs)
    h, d = st.totals()
    tot = h + d
    numbers = feature_numbers()
    L = []
    A = L.append

    A('# %s — SpecHub Metrics' % project_name())
    A('')
    A('> Generated by `scripts/metrics.sh render` from `metrics/ledger.jsonl`. **Do not edit, and do '
      'not open in a model session** — like `CHANGELOG.md`, this file is written and read by scripts.')
    A('> Window: %s → %s · %d feature(s) · %d dispatch run(s) · %s'
      % (st.window[0], st.window[1], len(st.features), len(st.runs), coverage_note(st)))
    A('')
    A('> **Dollars on this board are API-list value, not an invoice.** They are what this usage would '
      'have cost at list prices (`metrics/prices.tsv`, tokens x price). The workspace runs on a '
      'flat-fee subscription, so nothing here is billed per token. The dollar is kept because it is '
      'the one unit that puts Haiku, Sonnet, Opus and Fable tokens on a single axis — read every '
      'figure as *value used*, and the shares and the price-free tables as the actionable numbers.')
    A('')
    A('## Health')
    A('')
    A('| Metric | Value | |')
    A('|---|---|---|')
    r, a, b = st.first_pass()
    A('| First-pass success (dispatched once, verified first look) | %.0f%% | %d/%d |' % (r, a, b))
    r, a, b = st.run_failure_rate()
    A('| Dispatch run failure rate (error or aborted) | %.0f%% | %d/%d |' % (r, a, b))
    r, a, b = st.verify_pass_rate()
    A('| Human verification pass rate (first look) | %.0f%% | %d/%d |' % (r, a, b))
    rs = st.resumes_per_feature()
    A('| Resumes per feature (median) | %s | p90: %s |'
      % (median(rs) if rs else 'n/a', p90(rs) if rs else 'n/a'))
    lt = [e.get('lead_time_ms') for e in st.merges]
    A('| Dispatch → merge lead time (median) | %s | p90: %s |' % (dur(median(lt)), dur(p90(lt))))
    wl = [e.get('wall_ms') or e.get('duration_ms') for e in st.runs]
    A('| Headless session duration (median) | %s | p90: %s |' % (dur(median(wl)), dur(p90(wl))))
    A('')

    A('## API-list value')
    A('')
    A('| Half of the usage | Value | Share | Basis |')
    A('|---|---:|---:|---|')
    A('| Hub sessions (Steps 0–4, in this workspace) | %s | %.1f%% | derived |' % (money(h), pct(h, tot)))
    A('| Dispatched implementation runs | %s | %.1f%% | reported |' % (money(d), pct(d, tot)))
    A('| **Total** | **%s** | | |' % money(tot))
    A('')
    billed, rp = st.repriced()
    if billed and abs(billed - rp) > 0.005:
        A('> **Prices have moved since these runs.** The CLI valued the dispatch runs at %s; the same '
          'tokens at today\'s `metrics/prices.tsv` come to %s (%+.1f%%). Reported figures are kept as '
          'reported — the token counts are what make the re-pricing possible.'
          % (money(billed), money(rp), pct(rp - billed, billed)))
        A('')
    cr = 0.0
    for e in st.hub + st.runs:
        for m, tk in (e.get('models') or {}).items():
            p = PRICE.get(norm_model(m))
            if p:
                cr += tk.get('cache_read', 0) * p[0] * p[2] / 1e6
    if tot:
        A('Context re-read (cache-read tokens) alone accounts for **%s — %.0f%% of everything used**. '
          'It is the largest single line, and the one the context-budget rules in `WORKFLOW.md` exist '
          'to move.' % (money(cr), pct(cr, tot)))
        A('')

    rows = [(fe, st.feature_cost(fe)) for fe in st.features]
    rows = [r for r in rows if r[1]['total'] is not None]
    if rows:
        rows.sort(key=lambda r: -(r[1]['total'] or 0))
        A('## API-list value per feature')
        A('')
        A('Value never appears without the friction counts beside it: a feature that needed resumes '
          'used more than its headline figure, and the headline alone never says so.')
        A('')
        A('| # | Feature | Hub | Dispatch | Total | Runs | Resumes | Verify attempts |')
        A('|---|---------|---:|---:|---:|---:|---:|---:|')
        any_partial = False
        for fe, c in rows[:15]:
            n = num_for(fe, numbers)
            shown = money(c['total']) + ('+' if c.get('partial') else '')
            any_partial = any_partial or bool(c.get('partial'))
            A('| %s | %s | %s | %s | **%s** | %d | %d | %d |'
              % (n if n else '—', fe, money(c['hub']), money(c['dispatch']), shown,
                 c['runs'], c['resumes'], c['verify_attempts']))
        A('| | **median** | %s | %s | **%s** | | | |'
          % (money(median([c['hub'] for _, c in rows if c['hub'] is not None])),
             money(median([c['dispatch'] for _, c in rows if c['dispatch'] is not None])),
             money(median([c['total'] for _, c in rows]))))
        A('')
        if any_partial:
            A('`n/a` is not zero — it means no session of that kind is in the ledger, so a `+` total '
              'is a **floor, not a figure**. Features closed before hub sessions were recorded show '
              'their dispatch half only, and their true usage is several times what is printed.')
            A('')

    us = st.usage_by(Stats.bucket_of)
    if us:
        A('## Usage by step — price-free')
        A('')
        A('Dollars move when a price list changes; **tokens do not**. This table is the durable '
          'record: re-pricing `metrics/prices.tsv` re-derives every dollar figure on this board '
          'and leaves these numbers untouched.')
        A('')
        A('| Step | n | In | Out | Cache read | Cache write | Raw tokens | ITE | Share of ITE |')
        A('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
        tot_ite = sum(r['ite'] for r in us.values()) or 1
        for key, label in Stats.BUCKETS:
            if key not in us:
                continue
            r = us[key]
            tk = r['tokens']
            A('| %s | %d | %s | %s | %s | %s | %s | %s | %.1f%% |'
              % (label, r['n'], kt(tk.get('in')), kt(tk.get('out')), kt(tk.get('cache_read')),
                 kt(tk.get('cache_write_5m', 0) + tk.get('cache_write_1h', 0)),
                 kt(r['raw']), kt(r['ite']), pct(r['ite'], tot_ite)))
        A('')
        A('**ITE** (input-token equivalents) `= in + 5x out + 0.1x cache_read + 1.25x write_5m + '
          '2x write_1h` — each token class weighted by what it actually consumes relative to one '
          'input token. Those weights are uniform across the whole Claude lineup (output is exactly '
          '5.00x input for every model; cache read 0.1x, except 0.025x on Claude Fable 5.1), so ITE '
          'is proportional to API-list value within a model — `dollars = ITE x input_price / 1e6` — while '
          'depending only on the *ratios*, never the price level. `selftest` asserts that identity.')
        A('')
        A('**Raw tokens** is the unweighted sum. It flatters cache-heavy work: cache reads are the '
          'bulk of every raw figure here but a tenth of the weight, which is why ITE and raw '
          'disagree so sharply. Use ITE to compare effort; use raw only to see volume.')
        A('')

    ub = st.usage_by(lambda e: e.get('agent') or 'claude')
    if len(ub) > 1:
        A('## Usage by agent')
        A('')
        A('| Agent | n | Raw tokens | ITE | Models |')
        A('|---|---:|---:|---:|---|')
        for k in sorted(ub):
            r = ub[k]
            A('| `%s` | %d | %s | %s | %s |'
              % (k, r['n'], kt(r['raw']), kt(r['ite']),
                 ', '.join('`%s`' % show_model(m) for m in sorted(r['models']))))
        A('')
        A('> **These rows must never be summed.** Vendors tokenise differently, so a token is not a '
          'common unit across them, and ITE weights come from one vendor\'s price ratios. To compare '
          'agents, use the outcome rows in **Health** (first-pass success, resumes, verification, '
          'duration) and API-list value — list-price dollars are the only genuinely common denominator '
          'across vendors.')
        A('')

    sts = st.step_totals()
    if sts:
        A('## API-list value by step')
        A('')
        A('Step 3 is split in two, because they are different usage: the **hub session** that drives '
          'the dispatcher, and the **headless runs** it launches. Only the second is implementation.')
        A('')
        A('| Step | n | Value | Share | In | Out | Cache read | Cache write | Median duration |')
        A('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
        for key, label in Stats.BUCKETS:
            if key not in sts:
                continue
            r = sts[key]
            tk = r['tokens']
            mark = '' if r['tok_n'] >= r['n'] else (' †%d/%d' % (r['tok_n'], r['n']))
            A('| %s | %d | %s | %.1f%% | %s | %s | %s%s | %s | %s |'
              % (label, r['n'], money(None if r['unpriced'] and not r['cost'] else r['cost']),
                 pct(r['cost'], tot), kt(tk.get('in')), kt(tk.get('out')), kt(tk.get('cache_read')),
                 mark, kt(tk.get('cache_write_5m', 0) + tk.get('cache_write_1h', 0)),
                 dur(median(r['dur']))))
        if any(v['tok_n'] < v['n'] for v in sts.values()):
            A('')
            A('`†n/m` — token totals cover only the *n* of *m* runs whose JSON log still exists '
              '(older runs were logged under a previous hub). **Value is complete either way**; it '
              'comes from the report tables, which never lose it.')
        A('')

    mx = st.step_matrix()
    full = [fe for fe in st.features if mx.get(fe) and any(
        mx[fe].get(k) is not None for k in ('1', '2', '4'))]
    if full:
        A('## Per-feature step breakdown')
        A('')
        A('Only features whose hub sessions are in the ledger appear here — a feature closed before '
          'hub recording began has no step breakdown to give, and a row of dispatch-only numbers '
          'would read as though the other steps were free.')
        A('')
        A('| # | Feature | 1 design | 2 cascade | 3 dispatch (hub) | 3 runs | 4 close | Total |')
        A('|---|---------|---:|---:|---:|---:|---:|---:|')
        for fe in sorted(full, key=lambda f: -(sum(v for v in mx[f].values() if v) or 0)):
            row, tsum = mx[fe], sum(v for v in mx[fe].values() if v)
            n = num_for(fe, numbers)
            A('| %s | %s | %s | %s | %s | %s | %s | **%s** |'
              % (n if n else '—', fe, money(row.get('1')), money(row.get('2')), money(row.get('3h')),
                 money(row.get('3r')), money(row.get('4')), money(tsum)))
        A('')
        hub_only = sum(v for fe in full for k, v in mx[fe].items() if k != '3r' and v)
        runs_only = sum(v for fe in full for k, v in mx[fe].items() if k == '3r' and v)
        if runs_only:
            A('Across these features the hub uses **%.0fx** the API-list value of the implementation '
              'runs (%s vs %s). A metrics system instrumenting only the dispatcher would measure the '
              '%.0f%% column and call it the usage per feature.'
              % (hub_only / runs_only, money(hub_only), money(runs_only),
                 pct(runs_only, hub_only + runs_only)))
            A('')

    bs = st.by_step()
    if bs:
        A('## Model use by step (policy conformance)')
        A('')
        A('The tier policy in `WORKFLOW.md` is the framework\'s main usage lever. This table is the '
          'only place it is actually checked. Step 3 has no single policy tier — each prompt names '
          'its own — so it is never counted off-policy.')
        A('')
        A('| Step | Policy tier | Sessions (Step 3: runs) | Actual models | Off-policy |')
        A('|---|---|---:|---|---:|')
        for s in sorted(bs, key=lambda x: (x is None, x)):
            r = bs[s]
            actual = ', '.join('`%s` (%d)' % (show_model(m), n) for m, n in r['models'].most_common(4))
            off = off_policy(s, r['models'])
            A('| %s %s | %s | %d | %s | %s |'
              % (s if s is not None else '?', STEP_NAME.get(s, 'unattributed'),
                 POLICY_TIER.get(s, '—') if s is not None else '—',
                 r['runs'] if s == 3 else r['n'], actual or '—',
                 ('**%d**' % off) if off else '0'))
        A('')

    if any(is_alias(m) for _s in bs for m in bs[_s]['models']):
        A('`*` marks a tier alias (`sonnet`) recorded before `dispatch.sh` logged model ids. The exact '
          'model behind it is not recoverable, so it is shown as written rather than guessed into one.')
        A('')

    fails = [e for e in st.verifies if e.get('result') == 'fail']
    if not fails and st.verifies:
        A('> **The 100% verification pass rate is an artefact, not a result.** Every verification in '
          'this ledger predates `dispatch.sh verify --fail`, so nothing could ever record the failure '
          'side. Treat this row as meaningless until it has rejections in it.')
        A('')

    fp = st.failure_patterns()
    if fp:
        A('## Failure patterns')
        A('')
        A('| Diagnosis | Count | Last seen |')
        A('|---|---:|---|')
        for k, n, when in fp:
            A('| %s | %d | %s |' % (k, n, when or '—'))
        A('')

    stale = stale_prices()
    if stale:
        A('> **Price rows to re-check:** %s. `scripts/metrics.sh selftest` can only confirm models '
          'that appear in dispatch runs; hub-only models are unverified by it.' % ', '.join(stale))
        A('')

    with open(out, 'w', encoding='utf-8') as f:
        f.write('\n'.join(L).rstrip() + '\n')
    print('[metrics] METRICS.md written — %d event(s), %s total.' % (len(evs), money(tot)))
    return 0


def project_name():
    if os.path.exists(CONF):
        m = re.search(r'^PROJECT_NAME="([^"]*)"', open(CONF, encoding='utf-8').read(), re.M)
        if m:
            return m.group(1)
    return 'SpecHub'


def stale_prices(days=90):
    out = []
    today = datetime.date.today()
    for m, (_i, _o, _c, v) in PRICE.items():
        try:
            if (today - datetime.date.fromisoformat(v)).days > days:
                out.append('`%s` (%s)' % (m, v))
        except (ValueError, TypeError):
            out.append('`%s` (never verified)' % m)
    return out


# --------------------------------------------------------------------------- archive
def cmd_archive(argv):
    if not argv or not re.match(r'^\d{4}-\d{2}-\d{2}$', argv[0]):
        die('usage: metrics.sh archive <YYYY-MM-DD>')
    before = argv[0]
    evs = read_ledger()
    keep = [e for e in evs if (e.get('ts') or '')[:10] >= before]
    move = [e for e in evs if (e.get('ts') or '')[:10] < before]
    if not move:
        print('[metrics] nothing older than %s.' % before)
        return 0
    arch = os.path.join(HUB, 'archive', 'metrics-ledger-archive.jsonl')
    os.makedirs(os.path.dirname(arch), exist_ok=True)
    with open(arch, 'a', encoding='utf-8') as f:
        for e in move:
            f.write(json.dumps(e, sort_keys=True) + '\n')
    rewrite(keep)
    print('[metrics] kept %d, archived %d (before %s).' % (len(keep), len(move), before))
    return 0


# --------------------------------------------------------------------------- main
def main():
    if len(sys.argv) < 2:
        die('no subcommand')
    cmd, argv = sys.argv[1], sys.argv[2:]
    table = {'emit': cmd_emit, 'session': cmd_session, 'sync': cmd_sync, 'report': cmd_report,
             'render': cmd_render, 'backfill': cmd_backfill, 'selftest': cmd_selftest,
             'archive': cmd_archive}
    fn = table.get(cmd)
    if not fn:
        die('unknown subcommand %r' % cmd)
    # Recording must never break its caller: a dispatch run or a session hook that cannot write
    # the ledger still succeeds. The reading commands are allowed to fail loudly.
    if cmd in ('emit', 'session'):
        try:
            return fn(argv)
        except Exception as exc:                                   # noqa: BLE001
            warn('%s failed (%s: %s) — continuing.' % (cmd, type(exc).__name__, exc))
            return 0
    return fn(argv)


if __name__ == '__main__':
    sys.exit(main() or 0)
