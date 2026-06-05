#!/usr/bin/env bash
# Asserts the shared probe honours the WireGuard gate for AmneziaWG (awg*) interfaces:
# offline(no/stale handshake)=-2, healthy=0, black-hole>0 — identical contract to
# test-probe-contract.sh but the tunnel is built with `awg`/`type amneziawg`.
# Needs root (netns) + the amneziawg module + the `awg` tool; SKIPS cleanly otherwise.
# Self-cleans. Ports 51901/51902 (distinct from the wg test) so both can run back-to-back.
set -uo pipefail
P="${1:-$(cd "$(dirname "$0")/.." && pwd)/lib/wg_pmtu.sh}"

command -v awg >/dev/null 2>&1 || { echo "SKIP: awg(8) not installed"; exit 0; }
modinfo amneziawg >/dev/null 2>&1 || { echo "SKIP: amneziawg kernel module not available"; exit 0; }

fail(){ echo "FAIL: $*"; exit 1; }
cleanup(){ ip netns del artr 2>/dev/null; ip netns del aright 2>/dev/null; ip link del awgA 2>/dev/null; ip link del aa0 2>/dev/null; }
trap cleanup EXIT; cleanup 2>/dev/null
ip netns add artr; ip netns add aright
ip link add aa0 type veth peer name aa1; ip link set aa1 netns artr
ip addr add 10.214.1.1/24 dev aa0; ip link set aa0 mtu 1300 up
ip netns exec artr ip addr add 10.214.1.2/24 dev aa1; ip netns exec artr ip link set aa1 mtu 1300 up
ip netns exec artr ip link add ab0 type veth peer name ab1; ip netns exec artr ip link set ab1 netns aright
ip netns exec artr ip addr add 10.214.2.1/24 dev ab0; ip netns exec artr ip link set ab0 mtu 1500 up
ip netns exec aright ip addr add 10.214.2.2/24 dev ab1; ip netns exec aright ip link set ab1 mtu 1500 up
ip netns exec artr ip link set lo up; ip netns exec aright ip link set lo up
ip netns exec artr sysctl -qw net.ipv4.ip_forward=1
ip netns exec artr iptables -A FORWARD -i aa1 -f -j DROP
ip route add 10.214.2.0/24 via 10.214.1.2
ip netns exec aright ip route add 10.214.1.0/24 via 10.214.2.1
Af=$(mktemp); Bf=$(mktemp); Cf=$(mktemp)
awg genkey >"$Af"; awg genkey >"$Bf"; awg genkey >"$Cf"
Apub=$(awg pubkey <"$Af"); Bpub=$(awg pubkey <"$Bf"); Cpub=$(awg pubkey <"$Cf")
ip link add awgA type amneziawg
awg set awgA private-key "$Af" listen-port 51901 peer "$Bpub" allowed-ips 10.98.98.2/32 endpoint 10.214.2.2:51902 persistent-keepalive 5
# a second peer that is configured but never connects -> handshake epoch 0
awg set awgA peer "$Cpub" allowed-ips 10.98.98.3/32
ip addr add 10.98.98.1/24 dev awgA; ip link set awgA mtu 1200 up
ip netns exec aright ip link add awgB type amneziawg
ip netns exec aright awg set awgB private-key "$Bf" listen-port 51902 peer "$Apub" allowed-ips 10.98.98.1/32 endpoint 10.214.1.1:51901 persistent-keepalive 5
ip netns exec aright ip addr add 10.98.98.2/24 dev awgB; ip netns exec aright ip link set awgB mtu 1200 up
rm -f "$Af" "$Bf" "$Cf"; sleep 3; ping -c1 -W2 10.98.98.2 >/dev/null 2>&1; sleep 1

# never-handshaked peer (epoch 0) -> offline, gated before any ping
v=$(bash "$P" awgA 10.98.98.3);           [ "$v" = "-2" ] || fail "never-handshaked expected -2 got $v"
# fresh handshake, MTU matches path -> healthy
v=$(bash "$P" awgA 10.98.98.2);           [ "$v" = "0" ]  || fail "healthy expected 0 got $v"
# fresh handshake, oversize tunnel MTU over a fragment-dropping path -> black hole
ip link set awgA mtu 1420
v=$(bash "$P" awgA 10.98.98.2);           [ "$v" -gt 0 ] 2>/dev/null || fail "black hole expected >0 got $v"
# peer goes away; force the handshake to read as stale -> offline (not -1)
ip netns exec aright ip link set awgB down
export VPN_LIVE_FRESH=1; sleep 2
v=$(bash "$P" awgA 10.98.98.2);           [ "$v" = "-2" ] || fail "offline(stale hs) expected -2 got $v"
unset VPN_LIVE_FRESH
echo "PASS: amneziawg never-hs=-2, healthy=0, black-hole>0, stale-hs=-2"
