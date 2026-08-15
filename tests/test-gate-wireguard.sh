#!/usr/bin/env bash
# shellcheck disable=SC2016  # single quotes are intentional: we emit a stub script verbatim
# Fixture test for lib/gate_wireguard.sh — stubs wg(8) on PATH; no root, netns or kernel module.
# The netns rigs (test-probe-contract.sh) cover the same gate end-to-end but need root, so this
# was the one production script with no test that runs unprivileged.
#
# The stub emulates BOTH `wg show <iface> <sub>` and `wg show all <sub>`, whose column counts
# differ (`all` prepends the interface). That is deliberate: the gate may use either form, and
# this test must pin the gate's OUTPUT contract, not its choice of wg invocation.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
GATE="$REPO/lib/gate_wireguard.sh"
fail(){ echo "FAIL: $*"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

K1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA=
K2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbB=
K3=cccccccccccccccccccccccccccccccccccccccccC=

mkstub(){ # stdin: lines "<iface> <pubkey> <comma-separated-allowed-ips> <handshake-epoch>"
  cat > "$TMP/data"
  { echo '#!/usr/bin/env bash'
    echo '[ "${1:-}" = show ] || exit 1'
    echo 'sel=${2:-}; sub=${3:-}'
    echo '[ -n "$sub" ] || exit 1'
    # real wg rejects a 4th argument — keeps the sudoers-wildcard bypass inert here too
    echo '[ $# -le 3 ] || { echo "Usage: wg show ..." >&2; exit 1; }'
    printf 'while read -r ifc pk ips ep; do\n'
    echo '  [ -n "$ifc" ] || continue'
    echo '  { [ "$sel" = all ] || [ "$sel" = "$ifc" ]; } || continue'
    echo '  ipsp=$(printf "%s" "$ips" | tr "," " ")'
    echo '  if [ "$sub" = allowed-ips ]; then'
    echo '    if [ "$sel" = all ]; then printf "%s\t%s\t%s\n" "$ifc" "$pk" "$ipsp"'
    echo '    else printf "%s\t%s\n" "$pk" "$ipsp"; fi'
    echo '  elif [ "$sub" = latest-handshakes ]; then'
    echo '    if [ "$sel" = all ]; then printf "%s\t%s\t%s\n" "$ifc" "$pk" "$ep"'
    echo '    else printf "%s\t%s\n" "$pk" "$ep"; fi'
    echo '  fi'
    printf 'done < %s\n' "$TMP/data"
  } > "$TMP/wg"
  chmod +x "$TMP/wg"
}
run(){ PATH="$TMP:$PATH" bash "$GATE" "$1" "$2"; }

# 1) target is an exact /32 of a peer -> that peer's handshake epoch
mkstub <<EOF
wg0 $K1 10.0.0.2/32 1700000111
wg0 $K2 10.0.0.3/32 1700000222
EOF
[ "$(run wg0 10.0.0.2)" = "1700000111" ] || fail "must print the matching peer's epoch"
[ "$(run wg0 10.0.0.3)" = "1700000222" ] || fail "must pick the right peer among several"

# 2) peer exists but never handshaked -> 0 (vpn_pmtu.sh maps that to -2 offline)
mkstub <<EOF
wg0 $K1 10.0.0.2/32 0
EOF
[ "$(run wg0 10.0.0.2)" = "0" ] || fail "never-handshaked peer must print 0"

# 3) target is not any peer's /32 -> nothing (probe falls through to a plain measurement)
mkstub <<EOF
wg0 $K1 10.0.0.2/32 1700000111
EOF
[ -z "$(run wg0 10.0.0.99)" ] || fail "unknown target must print nothing"

# 4) target matches only as a subnet member, not an exact /32 -> nothing
mkstub <<EOF
wg0 $K1 10.0.0.0/24 1700000111
EOF
[ -z "$(run wg0 10.0.0.2)" ] || fail "a /24 containing the target is not an exact /32 match"

# 5) CROSS-INTERFACE ISOLATION — the case that guards using `wg show all`.
#    Same /32 on two interfaces: the gate must report the epoch of the REQUESTED interface.
mkstub <<EOF
wg0 $K1 10.0.0.2/32 1700000111
wg1 $K2 10.0.0.2/32 1700000999
EOF
[ "$(run wg0 10.0.0.2)" = "1700000111" ] || fail "must not read another interface's peer (wg0)"
[ "$(run wg1 10.0.0.2)" = "1700000999" ] || fail "must not read another interface's peer (wg1)"

# 6) requested interface absent while others exist -> nothing
mkstub <<EOF
wg1 $K3 10.0.0.2/32 1700000999
EOF
[ -z "$(run wg0 10.0.0.2)" ] || fail "absent interface must print nothing, not another iface's data"

# 7) wg unreadable/absent -> nothing (fail-safe to a plain measurement, never a fabricated verdict)
rm -f "$TMP/wg"
[ -z "$(run wg0 10.0.0.2)" ] || fail "missing wg must print nothing (fail-safe)"

echo "PASS: gate_wireguard epoch/0/nothing contract holds, incl. cross-interface isolation"
