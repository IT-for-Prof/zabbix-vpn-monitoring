#!/usr/bin/env bash
# Static contract test for templates/vpn-tunnel-mtu.yaml. No Zabbix, no network, no root.
# Guards three failure classes that are invisible until they hit production:
#   1. count-based hysteresis (,#N) — collapses to a single poll on hosts that write
#      duplicate samples per poll (proxy-group / dual-ServerActive), silently disabling it.
#   2. a trigger dependency whose name+expression does not match any defined trigger —
#      Zabbix rejects the whole import with "trigger dependency not found".
#   3. {$VPN.HYST.WINDOW} not wide enough to hold 2 polls of every item it guards.
# Needs PyYAML (apt install python3-yaml / pip install pyyaml) — the only test here that is not
# pure stdlib. Fails loudly rather than skipping: a silently-skipped check is the exact failure
# mode this test exists to catch.
set -u
YAML=$(cd "$(dirname "$0")/.." && pwd)/templates/vpn-tunnel-mtu.yaml
python3 -c 'import yaml' 2>/dev/null \
  || { echo "FAIL: PyYAML missing — install it (apt install python3-yaml / pip install pyyaml)"; exit 1; }
python3 - "$YAML" <<'EOF'
import re, sys, yaml

T = yaml.safe_load(open(sys.argv[1]))['zabbix_export']['templates'][0]
UNIT = {'': 1, 's': 1, 'm': 60, 'h': 3600, 'd': 86400}
macros = {m['macro']: m.get('value') for m in T.get('macros') or []}

def dur(v):                       # '25m' / '{$MACRO}' -> seconds, or None
    v = macros.get(str(v).strip(), v)
    m = re.fullmatch(r'(\d+)([smhd]?)', str(v).strip())
    return int(m.group(1)) * UNIT[m.group(2)] if m else None

triggers, deps, items = set(), [], []      # items: (key, delay)
def take(trs):
    for t in trs or []:
        # recovery_expression is a second place a count spec can hide; absent on these triggers
        # today, but a future edit adding one would otherwise slip past check 1 unseen.
        for key in ('expression', 'recovery_expression'):
            if t.get(key):
                triggers.add((t['name'], t[key]))
        for d in t.get('dependencies') or []:
            deps.append((t['name'], d['name'], d['expression']))

take(T.get('triggers'))
for it in T.get('items') or []:
    items.append((it['key'], it.get('delay')));  take(it.get('triggers'))
for lld in T.get('discovery_rules') or []:
    take(lld.get('trigger_prototypes'))
    for p in lld.get('item_prototypes') or []:
        items.append((p['key'], p.get('delay')));  take(p.get('trigger_prototypes'))

p = f = 0
def ck(label, ok, detail=''):
    global p, f
    if ok: p += 1; print(f'  ok   {label}')
    else:  f += 1; print(f'  FAIL {label}{": " + detail if detail else ""}')

print(f'== {len(triggers)} triggers, {len(deps)} dependencies, {len(items)} items ==')

print('== 1. no count-based hysteresis ==')
# match the count parameter itself, not just a closing paren: ',#2:now-1h)' and ',#3,"eq"'
# are equally count-based and would sail past a r',#\d+\)' pattern.
bad = [f'{n} -> {e}' for n, e in triggers if re.search(r',\s*#\d+\s*[,:)]', e)]
ck('every trigger uses a time window, not ,#N', not bad, '; '.join(bad))

print('== 2. every dependency resolves to a defined trigger ==')
for owner, dn, de in deps:
    ck(f'{owner[:44]!r} -> {dn[:44]!r}', (dn, de) in triggers,
       'no trigger with this exact name+expression (import would be rejected)')

print('== 3. hysteresis window holds 2 polls of every guarded item ==')
win = dur('{$VPN.HYST.WINDOW}')
ck('{$VPN.HYST.WINDOW} parses', win is not None, str(macros.get('{$VPN.HYST.WINDOW}')))
                                       # anchor on the delimiter that always follows a key reference,
                                       # else a future 'wg.pmtu.raw' would match inside 'wg.pmtu' too
guarded = {k for k, _ in items if any(re.search(re.escape('/' + k.split('[')[0]) + r'[\[,)]', e)
                                      for _, e in triggers if '{$VPN.HYST.WINDOW}' in e)}
for key, delay in items:
    if key not in guarded:
        continue
    d = dur(delay)
    ck(f'{key} (delay {delay}) fits 2x in {macros["{$VPN.HYST.WINDOW}"]}',
       d is not None and win >= 2 * d, f'needs >= {2 * d}s, window is {win}s' if d else 'unparsable delay')

print('== 4. every windowed trigger carries a count(...)>1 floor ==')
# A window bounds a time span, not a sample count. After a collection gap longer than the
# window, exactly one fresh sample sits in it and min()/max() fires on that single reading —
# so the floor is what actually delivers the hysteresis, and losing it is silent.
for n, e in sorted(triggers):
    if '{$VPN.HYST.WINDOW}' not in e or e.startswith('nodata('):
        continue
    ck(f'{n[:52]!r} has a count floor',
       re.search(r'count\([^)]*\{\$VPN\.HYST\.WINDOW\}\)\s*>\s*1', e) is not None,
       'windowed but no count(...,{$VPN.HYST.WINDOW})>1 — a lone post-gap sample can fire it')

print(f'\nTOTAL: {p} passed, {f} failed')
sys.exit(1 if f else 0)
EOF
