#!/usr/bin/env bash
# Static contract test for installers/. No root, no network, nothing installed.
# Guards one failure class: install.sh writes a path that uninstall.sh does not remove.
# That asymmetry is invisible — uninstall exits 0 and the operator believes the host is clean —
# and it already shipped once, leaving /etc/sudoers.d/zabbix-posture (a NOPASSWD root grant)
# on every host the posture collector touched.
#
# This guard is itself a silent-pass risk: if its extractor stops seeing an install target, it
# reports PASS on a smaller set instead of failing. Three defences, all load-bearing:
#   1. Variable references are RESOLVED from install.sh's own assignments, and anything still
#      unresolved is a hard FAIL — never quietly filtered out of the target list.
#   2. Structural counts (install/commit_sudoers call sites) are asserted against what the
#      extractor actually parsed, so coverage loss fails loudly instead of shrinking TOTAL.
#   3. A negative self-test at the bottom mutates copies and asserts this guard FAILS on them.
#      Without it, "the test passes" says nothing about whether the test can fail.
# Removal matching uses uninstall.sh's real `rm -f` argument tokens — comments are stripped and
# comparison is exact-string, so a path named only in a comment cannot satisfy the check.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)/installers

# Paths install.sh creates and deliberately does NOT remove. Each needs a reason.
is_left_behind() {
  case $1 in
    /etc/zabbix/scripts) return 0 ;;          # the script dir itself; other packages may use it
    /etc/zabbix/scripts/.backup-*) return 0 ;; # timestamped rollback history (uninstall.sh documents this)
    /etc/hosts) return 0 ;;                   # install.sh only APPENDS a self-hostname line;
                                              # uninstall.sh says so ("/etc/hosts left as-is")
  esac
  return 1
}

# Strip shell comments before parsing real tokens. Both extractors below need this, and they
# used to carry their own copy — which had already drifted (`[[:space:]]#` vs `[[:space:]]*#`),
# so a full-line `# install -m ... "$SCR/x"` was left intact for one of them and counted as a
# live install target. One definition, used by both.
strip_comments() { sed 's/[[:space:]]*#.*$//'; }

# The one definition of "what an install/commit call site looks like". Used BOTH to extract
# targets and to compute the coverage floor — two copies would drift apart and shrink together,
# which is precisely the silent-pass mode the floor exists to prevent. `install -m/-d` takes the
# last field (survives extra flags like `-o root`); `commit_sudoers <path> <label>` takes $2.
AWK_SITES='/(^|[[:space:]])install[[:space:]]+-[dm]/ { gsub(/"/,""); print $NF; next }
           $1 == "commit_sudoers"                    { gsub(/"/,""); print $2 }'

# sed script resolving $VAR / ${VAR} for every literal absolute path assigned in the given text.
# Quotes around the value are stripped, so `SCR=/x` and `SCR="/x"` resolve identically — quoting
# that assignment previously cut this guard from 20 targets to 8 while still printing PASS.
# Longest variable name first, so a short name can never match inside a longer one ($P vs $PSUDO).
build_subs() {
  printf '%s\n' "$1" |
    sed -n 's|^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)=["'"'"']\{0,1\}\(/[^ "'"'"']*\).*|\1 \2|p' |
    awk '{ print length($1), $1, $2 }' | sort -rn |
    awk '{ printf "s@[$]{%s}@%s@g;s@[$]%s@%s@g\n", $2, $3, $2, $3 }'
}

# --- every /etc path install.sh creates -------------------------------------------------
# Emits one absolute path per line. Exits 1 loudly if any extracted token still contains an
# unresolved variable reference, rather than dropping it from the checked set.
install_targets() {
  local ins=$1 code flat subs raw resolved unresolved want got
  # Strip comments FIRST. Several install lines carry a trailing explanatory comment, and a
  # last-field extractor would otherwise take the comment's last word as the destination and
  # then drop it for not starting with `/` — silently losing three real targets.
  code=$(strip_comments < "$ins")
  # `;`-separated assignments (install.sh line 6 packs SCR and CONF onto one line) become
  # their own lines so a single assignment scan sees all of them.
  flat=$(printf '%s\n' "$code" | tr ';' '\n')
  # Build a sed script resolving both `$VAR` and `${VAR}` for every literal absolute path the
  # file assigns. Quotes around the value are stripped, so `SCR=/x` and `SCR="/x"` resolve
  # identically — quoting that assignment previously cut this guard from 20 targets to 8
  # while still printing PASS.
  # Two rounds: build the map from literal `/`-valued assignments, resolve the assignment text
  # with it, then rebuild — that second pass catches values chained through another variable
  # (`BK="$SCR/.backup-..."`). Only `/`-valued entries ever enter the map, so a value that is
  # itself a command substitution can never become a bogus substitution.
  subs=$(build_subs "$flat")
  [ -n "$subs" ] || { echo >&2 "FAIL: no path variables resolved from $ins"; return 1; }
  subs=$(build_subs "$(printf '%s\n' "$flat" | sed -f <(printf '%s\n' "$subs"))")

  raw=$(
    # Install/commit call sites, read from $flat (the `;`-split text) — NOT $code. Two call
    # sites packed onto one line with `;` would otherwise contribute one target while the
    # coverage floor counted one line, so both sides shrank together and the guard passed.
    printf '%s\n' "$flat" | awk "$AWK_SITES"
    # Redirect targets, quoted (`> "<path>"`) and bare (`>> /etc/hosts`).
    printf '%s\n' "$code" | sed -n 's|.*>[[:space:]]*"\([^"]*\)".*|\1|p'
    printf '%s\n' "$code" | sed -n 's|.*>[[:space:]]*\(/etc/[^ "'"'"';&|)]*\).*|\1|p'
    # Absolute-path variable assignments (sudoers files, drop-ins).
    printf '%s\n' "$flat" | sed -n 's|^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=["'"'"']\{0,1\}\(/etc/[^ "'"'"']*\).*|\1|p'
  )
  # Resolve, then drop the two transient classes before the unresolved check: `*.tmp` staging
  # files (created and consumed on the same code path, never a live install target) and the
  # timestamped `.backup-*` dir (its name embeds $(date), and uninstall.sh documents keeping it).
  raw=$(printf '%s\n' "$raw" |
    sed -f <(printf '%s\n' "$subs") |
    grep -v '\.tmp$' | grep -v '\.backup-' | awk 'NF' | sort -u)

  unresolved=$(printf '%s\n' "$raw" | grep '[$]' || true)
  if [ -n "$unresolved" ]; then
    echo >&2 "FAIL: extractor could not resolve these install targets (they would go unchecked):"
    printf >&2 '  %s\n' $unresolved
    return 1
  fi
  resolved=$(printf '%s\n' "$raw" | grep '^/' || true)
  [ -n "$resolved" ] || { echo >&2 "FAIL: parsed zero install targets from $ins"; return 1; }

  # Coverage floor: every `install -d/-m` and `commit_sudoers` call site must have been seen by
  # the extractor. A regex that quietly stops matching shrinks TOTAL instead of failing, which
  # is the exact silent-pass mode this guard exists to prevent — so assert the count directly.
  want=$(printf '%s\n' "$flat" | grep -cE '(^|[[:space:]])(install[[:space:]]+-[dm]|commit_sudoers[[:space:]])')
  got=$(printf '%s\n' "$flat" | awk "$AWK_SITES" | sed -f <(printf '%s\n' "$subs") | grep -c '^/')
  [ "$want" = "$got" ] || {
    echo >&2 "FAIL: $want install/commit_sudoers call sites but only $got resolved to a path —"
    echo >&2 "      the extractor is silently missing targets; fix it before trusting this guard."
    return 1
  }

  printf '%s\n' "$resolved"
}

# --- every path uninstall.sh actually removes --------------------------------------------
# Comments are stripped and line continuations joined, so only real `rm -f` arguments count.
removed_paths() {
  strip_comments < "$1" |
    sed -e :a -e '/\\$/N; s/\\\n//; ta' |
    awk '/(^|[[:space:]])rm[[:space:]]+-f/ { for (i = 1; i <= NF; i++) if ($i ~ /^\//) print $i }'
}

# --- the contract ------------------------------------------------------------------------
check_symmetry() {  # <install.sh> <uninstall.sh> [quiet]
  local ins=$1 uni=$2 quiet=${3:-} targets removed rc=0 n=0 p
  targets=$(install_targets "$ins") || return 1
  removed=$(removed_paths "$uni")
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    n=$((n + 1))
    if is_left_behind "$p"; then
      [ -n "$quiet" ] || echo "  skip $p (deliberately left)"
      continue
    fi
    # Exact-string membership against real rm -f arguments — no regex, so no metacharacter
    # escaping to get wrong, and a path inside a comment can never satisfy it.
    if printf '%s\n' "$removed" | grep -qxF -- "$p"; then
      [ -n "$quiet" ] || echo "  ok   $p"
    else
      [ -n "$quiet" ] || echo "  FAIL $p — install.sh creates it, uninstall.sh never removes it"
      rc=1
    fi
  done <<EOF
$targets
EOF
  [ -n "$quiet" ] || echo "TOTAL: $n install targets checked"
  return $rc
}

# --- negative self-test: prove this guard can fail ---------------------------------------
# Every bypass below was a real defect in the first version of this test.
selftest() {
  local t rc=0
  t=$(mktemp -d) || return 1
  trap 'rm -rf "$t"' RETURN
  cp "$DIR/install.sh" "$DIR/uninstall.sh" "$t/"

  # (a) a dropped rm must FAIL
  sed -i 's| /etc/sudoers\.d/zabbix-posture||' "$t/uninstall.sh"
  check_symmetry "$t/install.sh" "$t/uninstall.sh" quiet \
    && { echo "SELFTEST FAIL: dropped rm entry did not fail the guard"; rc=1; }

  # (b) naming the path in a comment must NOT count as removing it
  cp "$DIR/uninstall.sh" "$t/uninstall.sh"
  sed -i -e 's| /etc/sudoers\.d/zabbix-posture||' \
         -e '$a # TODO: /etc/sudoers.d/zabbix-posture handled by config-management' "$t/uninstall.sh"
  check_symmetry "$t/install.sh" "$t/uninstall.sh" quiet \
    && { echo "SELFTEST FAIL: a comment satisfied the removal check"; rc=1; }

  # (c) quoting the SCR/CONF assignment must not silently shrink coverage.
  # Matched by CONTENT, not by line number: an addressed `sed '6s|...|'` is a silent no-op once
  # the assignment moves, so the counts would agree because nothing was mutated and this case
  # would "pass" without ever exercising the regression. Assert the mutation actually landed.
  cp "$DIR/install.sh" "$t/install.sh"; cp "$DIR/uninstall.sh" "$t/uninstall.sh"
  sed -i 's|^SCR=\(/[^;]*\); *CONF=\(/.*\)|SCR="\1"; CONF="\2"|' "$t/install.sh"
  if ! grep -q '^SCR="' "$t/install.sh"; then
    echo "SELFTEST FAIL: could not quote SCR/CONF — the selftest is stale, not the code"; rc=1
  else
    local full quoted
    full=$(install_targets "$DIR/install.sh" | wc -l)
    quoted=$(install_targets "$t/install.sh" | wc -l)
    [ "$full" = "$quoted" ] || { echo "SELFTEST FAIL: quoting SCR/CONF changed coverage $full -> $quoted"; rc=1; }
  fi

  return $rc
}

selftest || { echo "FAIL: the guard itself is broken — it cannot detect the regressions it exists for"; exit 1; }
echo "selftest: guard fails correctly on a dropped rm, a comment-only mention, and quoted assignments"
check_symmetry "$DIR/install.sh" "$DIR/uninstall.sh" \
  || { echo "FAIL: uninstall.sh is not symmetric with install.sh"; exit 1; }
echo "PASS: every path install.sh creates is removed by uninstall.sh"
