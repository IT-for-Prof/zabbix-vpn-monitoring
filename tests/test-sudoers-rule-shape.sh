#!/usr/bin/env bash
# Static contract test for the sudoers rules installers/ generates. No root, nothing installed.
# test-installer-symmetry.sh guards which sudoers FILES exist; this guards what the RULES say.
#
# One rule: a NOPASSWD entry must bound its arguments. Ways it silently fails to:
#   * no argument list at all -> sudoers permits ANY argument. This shipped: a bare
#     `NOPASSWD: <iptables-save>` grant looked read-only but allowed `-M <path>` (exec'd as
#     root) and `-f <path>` (written as root). It was live on the fleet for 71 days.
#   * an fnmatch metacharacter (`*`, `?`, `[...]`) -> sudo matches with fnmatch, and `*` SPANS
#     WHITESPACE, so `show * allowed-ips` also permitted `show all dump allowed-ips` — the
#     key-exposing subcommand smuggled in ahead of the permitted one (confirmed with `sudo -l`).
#   * `''` -> looks like the zero-argument token but is not; sudoers spells that `""`.
#   * an unexpanded `%s` in the argument list -> the real arguments are decided at runtime and
#     this static check cannot see them.
# visudo accepts every one of those shapes, so nothing else catches them.
#
# Counting is per OCCURRENCE, not per line, and keyed on the shape-independent `NOPASSWD:`
# token — a floor that shares the extractor's own pattern shrinks together with it, which is
# the silent-coverage-loss mode these guards exist to stop.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
SOURCES="$REPO/installers/install.sh $REPO/docs/DEPLOY-POSTURE.md"

# The argument part of every generated `NOPASSWD: <cmd><args>` rule, one per line.
# Two shapes are recognised: `%s` (command path interpolated by printf) and a literal `/path`.
# `_` marks an empty argument list so word-splitting cannot silently drop it.
# Each match runs to the format string's literal `\n` terminator. `(\\"|[^\\])*` lets an
# ESCAPED quote through, which the pinned zero-argument form needs: install.sh writes `%s ""`
# and DEPLOY-POSTURE.md writes `%s \"\"` — same rule, different quoting of the printf format.
rule_args() {
  { grep -oE 'NOPASSWD: %s(\\"|[^\\])*\\n' "$1" | sed 's/^NOPASSWD: %s//'
    grep -oE 'NOPASSWD: /(\\"|[^\\])*\\n' "$1" | sed 's|^NOPASSWD: /[^ ]*||'
  } | sed -e 's/\\n$//' -e 's/\\"/"/g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^$/_/'
}

classify() {  # <args> -> prints verdict, returns 1 if the rule is unbounded
  case $1 in
    '_')          echo "UNBOUNDED: no argument list -> any arguments permitted"; return 1 ;;
    '""')         echo "ok: arguments pinned to none" ;;
    "''")         echo "UNBOUNDED: '' is a literal argument, not sudoers' zero-arg token (\"\")"; return 1 ;;
    *'%s'*)       echo "UNBOUNDED: argument list contains a runtime placeholder"; return 1 ;;
    *[*?[]*)      echo "UNBOUNDED: fnmatch metacharacter -> matches more than it reads" ; return 1 ;;
    *)            echo "ok: literal arguments" ;;
  esac
  return 0
}

# --- negative self-test: the classifier must reject every shape that has actually shipped ----
st=0
for bad in '_' 'show * allowed-ips' "''" '%s' 'show ? allowed-ips' 'show [a-z]0 allowed-ips'; do
  classify "$bad" >/dev/null && { echo "SELFTEST FAIL: accepted unbounded shape [$bad]"; st=1; }
done
for good in '""' 'list ruleset' '-j listnetworks' 'show all allowed-ips'; do
  classify "$good" >/dev/null || { echo "SELFTEST FAIL: rejected bounded shape [$good]"; st=1; }
done
# The extractor must survive two grants sharing one source line — a line-counted floor did not.
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
printf '%s\n' 'printf "x NOPASSWD: %s list ruleset\n" "$A"; printf "y NOPASSWD: %s\n" "$B"' > "$tmp"
[ "$(rule_args "$tmp" | grep -c .)" = 2 ] || { echo "SELFTEST FAIL: two grants on one line not both extracted"; st=1; }
[ $st -eq 0 ] || { echo "FAIL: the classifier or extractor is broken"; exit 1; }
echo "selftest: rejects bare/wildcard/''/%s shapes, accepts \"\" and literals, splits one-line pairs"

# --- the contract ---------------------------------------------------------------------------
rc=0; n=0
for f in $SOURCES; do
  [ -f "$f" ] || { echo "FAIL: missing source $f"; exit 1; }
  # Coverage floor on the shape-independent token, counted per occurrence. A grant written in
  # a shape rule_args() does not recognise must fail loudly, not go unclassified.
  want=$(grep -o 'NOPASSWD:' "$f" | grep -c .)
  got=$(rule_args "$f" | grep -c .)
  [ "$want" = "$got" ] || {
    echo "FAIL: $f has $want 'NOPASSWD:' occurrences but only $got were parsed —"
    echo "      the extractor is blind to some grants; fix it before trusting this result"
    exit 1
  }
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    n=$((n + 1))
    v=$(classify "$a") || rc=1
    printf '  %-34s %s\n' "$(printf '%s' "$a" | cut -c1-32)" "$v"
  done < <(rule_args "$f")
done
[ "$n" -gt 0 ] || { echo "FAIL: no rules found — the extractor drifted, not the installer"; exit 1; }
echo "TOTAL: $n rules checked"
[ $rc -eq 0 ] || { echo "FAIL: some grants do not bound their arguments"; exit 1; }

# --- the grant must match how the collectors actually invoke it -------------------------
# Bounding a grant is only half the contract; the other half is that it still permits what the
# code runs. Narrowing `show * allowed-ips` to the literal `show all allowed-ips` revoked a form
# collectors/posture/vpn_posture.sh was still using (`show <iface> allowed-ips`), so its sudo
# call started being DENIED and vpn.posture.fwd silently read 0 on every unprivileged host.
# Nothing caught it: the netns rigs run as root, so priv()'s direct call always succeeds there
# and the sudo path — the only one production uses — is never exercised.
# The invariant: a privileged `{wg,awg} show` asks for `all` and filters in the consumer,
# because `all` is the only interface argument the wildcard-free grant permits.
bad=$(grep -nE '(sudo -n|priv )[^|)]*[[:space:]]show[[:space:]]' "$REPO"/lib/*.sh "$REPO"/collectors/*/*.sh 2>/dev/null |
      grep -vE '[[:space:]]show[[:space:]]+all[[:space:]]' || true)
if [ -n "$bad" ]; then
  echo "FAIL: a privileged 'show' call site does not use the granted literal 'all':"
  printf '  %s\n' "$bad"
  echo "      the grant permits only 'show all <sub>'; filter by interface in the consumer"
  exit 1
fi
echo "grant/usage: every privileged {wg,awg} show asks for 'all' (the only granted form)"
echo "PASS: every NOPASSWD grant bounds its arguments and matches its call sites"
