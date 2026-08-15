#!/usr/bin/env bash
# Ground-truth integration test for vpn_posture.sh against a real WireGuard iface in a netns.
# Builds the unsafe state (MTU>ceiling, no clamp, forwarding), asserts the collector flags it,
# then fixes each fact and asserts it clears. Needs root. Self-cleaning. No production impact.
# requires: root
# Self-gate on every precondition so a missing one degrades to SKIP, not an assertion failure.
set -u
[ "$(id -u)" = 0 ] || { echo "SKIP: needs root (network namespaces)"; exit 0; }
command -v wg >/dev/null 2>&1 || { echo "SKIP: wireguard-tools (wg) not installed"; exit 0; }
modinfo wireguard >/dev/null 2>&1 || { echo "SKIP: wireguard kernel module not available"; exit 0; }
[ "${ZVM_ALLOW_NETNS:-}" = 1 ] || { echo "SKIP: creates network namespaces — set ZVM_ALLOW_NETNS=1 to run"; exit 0; }
NS=posturetest
COL=$(cd "$(dirname "$0")/.." && pwd)/collectors/posture/vpn_posture.sh
cleanup(){ ip netns del $NS 2>/dev/null; }
trap cleanup EXIT; cleanup 2>/dev/null

N(){ ip netns exec $NS "$@"; }
ip netns add $NS
N ip link set lo up
N sysctl -qw net.ipv4.ip_forward=1
kf=$(mktemp); wg genkey >"$kf"; peerpub=$(wg genkey | wg pubkey)
N ip link add wgt type wireguard
N wg set wgt private-key "$kf"; rm -f "$kf"
N wg set wgt peer "$peerpub" allowed-ips 10.77.0.0/24       # routed subnet -> carrier
N ip addr add 10.77.0.1/24 dev wgt
N ip link set wgt mtu 1500 up

pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
      else fail=$((fail+1)); printf '  FAIL %s : exp[%s] got[%s]\n' "$1" "$2" "$3"; fi; }
run(){ N sh "$COL" "$@"; }

echo "== UNSAFE: mtu 1500, no clamp, forwards =="
ck "discover lists wgt"                 1    "$(run discover | grep -c '"wgt"')"
ck "mtu = 1500"                         1500 "$(run mtu wgt)"
ck "fwd = 1 (subnet allowed-ips + ip_forward)" 1 "$(run fwd wgt)"
ck "clamp = 0 (no rule)"                0    "$(run clamp wgt)"

echo "== add MSS clamp on wgt =="
N iptables -t mangle -A FORWARD -o wgt -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
  || N nft -f - <<<'table ip mtest { chain c { type filter hook forward priority 0; oifname "wgt" tcp flags syn tcp option maxseg size set rt mtu } }'
ck "clamp = 1 after rule"               1    "$(run clamp wgt)"

echo "== fix MTU to 1420 =="
N ip link set wgt mtu 1420
ck "mtu = 1420 after fix"               1420 "$(run mtu wgt)"

echo "== host-only allowed-ips -> not a carrier =="
N wg set wgt peer "$peerpub" allowed-ips 10.77.0.9/32
ck "fwd = 0 (only /32 route)"           0    "$(run fwd wgt)"

echo "== iface removed -> mtu empty (LLD drops item, never 0) =="
N ip link del wgt
ck "mtu empty after iface gone"         ""   "$(run mtu wgt)"

echo
echo "TOTAL: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
