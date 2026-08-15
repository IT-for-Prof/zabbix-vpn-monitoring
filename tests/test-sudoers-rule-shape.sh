#!/usr/bin/env bash
# Static contract test for the sudoers rules installers/ generates. No root, nothing installed.
# The symmetry test guards which sudoers FILES exist; this one guards what the RULES say.
#
# One rule: a NOPASSWD entry must bound its arguments. Two ways it silently fails to:
#   * no argument list at all -> sudoers permits ANY arguments. This shipped: a bare
#     `NOPASSWD: <iptables-save>` grant looked read-only but allowed `-M <path>` (exec'd as
#     root) and `-f <path>` (written as root). It was live on the fleet for 71 days.
#   * a `*` wildcard -> sudo matches it with fnmatch, which SPANS WHITESPACE, so `show *
#     allowed-ips` also permits `show all dump allowed-ips` — the key-exposing subcommand
#     smuggled in ahead of the permitted one (confirmed with `sudo -l`: PERMITTED). Only wg's
#     own argument-count check stopped it, i.e. a third-party binary standing in for policy.
# Neither shape is visible in a path-level check, and neither fails loudly at install time —
# visudo accepts both. Hence this test.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
SOURCES="$REPO/installers/install.sh $REPO/docs/DEPLOY-POSTURE.md"

# The argument part of every generated `NOPASSWD: <cmd><args>` rule, one per line.
# `%s` is the command path; everything between it and the trailing \n is the argument list.
# `_` marks an empty list so word-splitting cannot silently drop it.
rule_args() {
  sed -n 's/.*NOPASSWD: %s\(.*\)\\n.*/\1/p' "$1" |
    sed -e 's/\\"/"/g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^$/_/'
}

classify() {  # <args> -> prints verdict, returns 1 if the rule is unbounded
  case $1 in
    '_')     echo "НЕОГРАНИЧЕН: нет списка аргументов -> разрешены любые"; return 1 ;;
    '""')    echo "ok: аргументы запрещены" ;;
    *'*'*)   echo "НЕОГРАНИЧЕН: '*' покрывает пробелы -> пропускает лишние слова"; return 1 ;;
    *)       echo "ok: литеральные аргументы" ;;
  esac
  return 0
}

# --- negative self-test: the classifier must reject the shapes that actually shipped --------
st=0
classify '_'                    >/dev/null && { echo "SELFTEST FAIL: голая команда принята"; st=1; }
classify 'show * allowed-ips'   >/dev/null && { echo "SELFTEST FAIL: wildcard принят"; st=1; }
classify '""'                   >/dev/null || { echo "SELFTEST FAIL: пустой список отвергнут"; st=1; }
classify 'list ruleset'         >/dev/null || { echo "SELFTEST FAIL: литеральные аргументы отвергнуты"; st=1; }
[ $st -eq 0 ] || { echo "FAIL: сам классификатор сломан"; exit 1; }
echo "selftest: классификатор отвергает голую команду и wildcard, принимает \"\" и литералы"

# --- the contract ---------------------------------------------------------------------------
rc=0; n=0
for f in $SOURCES; do
  [ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    n=$((n + 1))
    v=$(classify "$a") || rc=1
    printf '  %-34s %s\n' "$(printf '%s' "$a" | cut -c1-32)" "$v"
  done < <(rule_args "$f")
done
[ "$n" -gt 0 ] || { echo "FAIL: не найдено ни одного правила — экстрактор дрейфанул, а не инсталлятор"; exit 1; }
echo "ВСЕГО: $n правил проверено"
[ $rc -eq 0 ] || { echo "FAIL: есть гранты, не ограничивающие аргументы"; exit 1; }
echo "PASS: каждый NOPASSWD-грант ограничивает свои аргументы"
