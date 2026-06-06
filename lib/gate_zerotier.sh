#!/usr/bin/env bash
# Liveness gate for ZeroTier. ZT liveness is per-NETWORK (there is no managed-IP->peer mapping in
# any zerotier-cli output), so this reports on the network that owns <iface>:
#   status "OK"                              -> prints `date +%s` (live; vpn_pmtu then measures PMTU)
#   present-but-not-OK / iface absent / 0 nets -> prints `0`      (vpn_pmtu maps to -2 offline, data-only)
#   zerotier-cli unrunnable or unparseable   -> prints NOTHING    (fail-safe: vpn_pmtu probes ungated)
# Usage: gate_zerotier.sh <iface> [target]   (target unused — ZT liveness is not per-peer)
# Read-only: `zerotier-cli -j listnetworks` (direct, then sudo -n). Never reads the authtoken directly.
# NOTE: ZT liveness is binary — an OK network always stamps "now", so VPN_LIVE_FRESH never trips for ZT.
set -u
ifc=${1:?usage: gate_zerotier.sh <iface> [target]}
raw=$( zerotier-cli -j listnetworks 2>/dev/null || { command -v zerotier-cli >/dev/null 2>&1 && sudo -n zerotier-cli -j listnetworks 2>/dev/null; } )
[ -n "$raw" ] || exit 0                          # CLI missing/failed/empty -> fail-safe (probe ungated). sudo -n ONLY if zerotier-cli exists (else no failed-sudo on non-ZT hosts)
st=$(printf '%s' "$raw" | python3 -c '
import json,sys
try:
    nets=json.load(sys.stdin)
except Exception:
    print("__PARSEFAIL__"); sys.exit(0)
ifc=sys.argv[1]; out="NONE"
for n in (nets or []):
    if isinstance(n, dict) and n.get("portDeviceName")==ifc:
        out=n.get("status") or "UNKNOWN"; break
print(out)
' "$ifc" 2>/dev/null) || exit 0                  # python missing/crash -> fail-safe
case "$st" in
  OK)               date +%s ;;                  # network up -> live (vpn_pmtu measures PMTU)
  __PARSEFAIL__|'') exit 0 ;;                     # unparseable -> fail-safe
  *)                echo 0 ;;                     # not-OK / iface-not-found / 0 networks -> offline (-2)
esac
