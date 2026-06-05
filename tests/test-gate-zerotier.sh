#!/usr/bin/env bash
# shellcheck disable=SC2016  # single quotes are intentional: we emit a stub script verbatim
# Fixture test for lib/gate_zerotier.sh — stubs zerotier-cli on PATH; no ZeroTier/kernel needed.
# Asserts the network-status -> epoch/0/empty mapping that vpn_pmtu.sh's contract relies on.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
GATE="$REPO/lib/gate_zerotier.sh"
fail(){ echo "FAIL: $*"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

mkstub(){ # $1 = stdout the stub emits for `zerotier-cli -j listnetworks`
  { echo '#!/usr/bin/env bash'
    echo 'if [ "${1:-}" = "-j" ] && [ "${2:-}" = "listnetworks" ]; then'
    printf 'cat <<'\''JSON'\''\n%s\nJSON\n' "$1"
    echo 'fi'
  } > "$TMP/zerotier-cli"
  chmod +x "$TMP/zerotier-cli"
}
run(){ PATH="$TMP:$PATH" bash "$GATE" ztTEST 10.0.0.1; }

# 1) network OK -> a recent unix epoch (live)
mkstub '[{"portDeviceName":"ztTEST","status":"OK","id":"abc","mtu":2800}]'
v=$(run); case "$v" in ''|*[!0-9]*) fail "OK must print a numeric epoch, got [$v]";; esac
now=$(date +%s); { [ "$v" -ge $((now-5)) ] && [ "$v" -le $((now+5)) ]; } || fail "OK epoch not ~now (got $v, now $now)"

# 2) present but not OK -> 0 (=> -2 offline)
mkstub '[{"portDeviceName":"ztTEST","status":"REQUESTING_CONFIGURATION"}]'
[ "$(run)" = "0" ] || fail "not-OK must print 0"

# 3) zero networks joined -> 0
mkstub '[]'
[ "$(run)" = "0" ] || fail "empty network list must print 0"

# 4) iface not among joined networks -> 0
mkstub '[{"portDeviceName":"ztOTHER","status":"OK"}]'
[ "$(run)" = "0" ] || fail "iface-not-found must print 0"

# 5) unparseable output (service-down message) -> nothing (fail-safe)
mkstub 'Error connecting to the ZeroTier service: connection failed'
[ -z "$(run)" ] || fail "unparseable must print nothing (fail-safe)"

# 6) empty CLI output (ran but produced nothing) -> nothing (fail-safe)
mkstub ''
[ -z "$(run)" ] || fail "empty CLI output must print nothing (fail-safe)"

echo "PASS: gate_zerotier OK=epoch, not-OK/empty/absent=0, unparseable/empty=nothing"
