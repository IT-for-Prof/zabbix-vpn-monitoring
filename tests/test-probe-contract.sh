#!/usr/bin/env bash
# Asserts lib/wg_pmtu.sh contract: offline(no/stale handshake)=-2, healthy=0, black-hole>0.
# Needs root (netns) + the wireguard module. Self-cleans. Do NOT run on a node whose real
# WireGuard listens on 51899 (port clash) — this is a lab/CI check.
set -uo pipefail
P="${1:-$(cd "$(dirname "$0")/.." && pwd)/lib/wg_pmtu.sh}"
fail(){ echo "FAIL: $*"; exit 1; }
cleanup(){ ip netns del rtr 2>/dev/null; ip netns del right 2>/dev/null; ip link del wgA 2>/dev/null; ip link del a0 2>/dev/null; }
trap cleanup EXIT; cleanup 2>/dev/null
ip netns add rtr; ip netns add right
ip link add a0 type veth peer name a1; ip link set a1 netns rtr
ip addr add 10.213.1.1/24 dev a0; ip link set a0 mtu 1300 up
ip netns exec rtr ip addr add 10.213.1.2/24 dev a1; ip netns exec rtr ip link set a1 mtu 1300 up
ip netns exec rtr ip link add b0 type veth peer name b1; ip netns exec rtr ip link set b1 netns right
ip netns exec rtr ip addr add 10.213.2.1/24 dev b0; ip netns exec rtr ip link set b0 mtu 1500 up
ip netns exec right ip addr add 10.213.2.2/24 dev b1; ip netns exec right ip link set b1 mtu 1500 up
ip netns exec rtr ip link set lo up; ip netns exec right ip link set lo up
ip netns exec rtr sysctl -qw net.ipv4.ip_forward=1
ip netns exec rtr iptables -A FORWARD -i a1 -f -j DROP
ip route add 10.213.2.0/24 via 10.213.1.2
ip netns exec right ip route add 10.213.1.0/24 via 10.213.2.1
Af=$(mktemp); Bf=$(mktemp); Cf=$(mktemp)
wg genkey >"$Af"; wg genkey >"$Bf"; wg genkey >"$Cf"
Apub=$(wg pubkey <"$Af"); Bpub=$(wg pubkey <"$Bf"); Cpub=$(wg pubkey <"$Cf")
ip link add wgA type wireguard
wg set wgA private-key "$Af" listen-port 51899 peer "$Bpub" allowed-ips 10.99.99.2/32 endpoint 10.213.2.2:51900 persistent-keepalive 5
# a second peer that is configured but never connects -> handshake epoch 0
wg set wgA peer "$Cpub" allowed-ips 10.99.99.3/32
ip addr add 10.99.99.1/24 dev wgA; ip link set wgA mtu 1200 up
ip netns exec right ip link add wgB type wireguard
ip netns exec right wg set wgB private-key "$Bf" listen-port 51900 peer "$Apub" allowed-ips 10.99.99.1/32 endpoint 10.213.1.1:51899 persistent-keepalive 5
ip netns exec right ip addr add 10.99.99.2/24 dev wgB; ip netns exec right ip link set wgB mtu 1200 up
rm -f "$Af" "$Bf" "$Cf"; sleep 3; ping -c1 -W2 10.99.99.2 >/dev/null 2>&1; sleep 1

# never-handshaked peer (epoch 0) -> offline, gated before any ping
v=$(bash "$P" wgA 10.99.99.3);            [ "$v" = "-2" ] || fail "never-handshaked expected -2 got $v"
# fresh handshake, MTU matches path -> healthy
v=$(bash "$P" wgA 10.99.99.2);            [ "$v" = "0" ]  || fail "healthy expected 0 got $v"
# fresh handshake, oversize tunnel MTU over a fragment-dropping path -> black hole
ip link set wgA mtu 1420
v=$(bash "$P" wgA 10.99.99.2);            [ "$v" -gt 0 ] 2>/dev/null || fail "black hole expected >0 got $v"
# peer goes away; force the handshake to read as stale -> offline (not -1)
ip netns exec right ip link set wgB down
export VPN_LIVE_FRESH=1; sleep 2
v=$(bash "$P" wgA 10.99.99.2);            [ "$v" = "-2" ] || fail "offline(stale hs) expected -2 got $v"
unset VPN_LIVE_FRESH
echo "PASS: never-hs=-2, healthy=0, black-hole>0, stale-hs=-2"
