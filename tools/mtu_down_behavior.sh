#!/usr/bin/env bash
# How the proposed detectors behave when the CHANNEL goes down (vs a real black hole).
# A(root, wgA 1500) <-> underlay(drops big outer fragments) <-> B(ns, wgB 1420).
# Reverse probe runs FROM the 1500 end (A). Tests 4 states. Isolated netns. Needs root.
set -u
N(){ ip netns exec "$@"; }
cleanup(){ ip netns del bns 2>/dev/null; ip link del wgA 2>/dev/null; ip link del u0 2>/dev/null; }
trap cleanup EXIT; cleanup 2>/dev/null

ip netns add bns; N bns ip link set lo up
ip link add u0 type veth peer name u1 netns bns
ip addr add 10.213.9.1/24 dev u0;        ip link set u0 mtu 1500 up
N bns ip addr add 10.213.9.2/24 dev u1;  N bns ip link set u1 mtu 1500 up
N bns iptables -t raw -A PREROUTING -f -j DROP   # drop wire fragments BEFORE conntrack defrag -> real black hole for A's 1500

Af=$(mktemp); Bf=$(mktemp); wg genkey >"$Af"; wg genkey >"$Bf"
Apub=$(wg pubkey<"$Af"); Bpub=$(wg pubkey<"$Bf")
ip link add wgA type wireguard
wg set wgA private-key "$Af" listen-port 51899 peer "$Bpub" allowed-ips 10.99.0.2/32 endpoint 10.213.9.2:51900 persistent-keepalive 5
ip addr add 10.99.0.1/24 dev wgA; ip link set wgA mtu 1500 up
N bns ip link add wgB type wireguard
N bns wg set wgB private-key "$Bf" listen-port 51900 peer "$Apub" allowed-ips 10.99.0.1/32 endpoint 10.213.9.1:51899 persistent-keepalive 5
N bns ip addr add 10.99.0.2/24 dev wgB; N bns ip link set wgB mtu 1420 up
rm -f "$Af" "$Bf"; sleep 3; ping -c1 -W2 10.99.0.2 >/dev/null 2>&1; sleep 1

pingok(){ ping -c2 -W2 -M do -s "$1" 10.99.0.2 >/dev/null 2>&1 && echo OK || echo FAIL; }   # from A (root)

# Reverse-probe verdict using the production ladder: small-first, then at-MTU.
probe_verdict(){
  if ! ip link show wgA >/dev/null 2>&1; then echo "nodata (iface gone -> LLD drops item)"; return; fi
  [ "$(cat /sys/class/net/wgA/operstate 2>/dev/null)" = down ] && { echo "-1/err (iface admin-down)"; return; }
  local s b; s=$(pingok 56)
  if [ "$s" = FAIL ]; then echo "-1 (unreachable; small fails too)"; return; fi
  b=$(pingok $((1500-28)))
  [ "$b" = FAIL ] && echo ">0 (BLACK HOLE)" || echo "0 (healthy)"
}
mtu_read(){ # what the config-compare collector sees for wgA
  if [ -e /sys/class/net/wgA/mtu ]; then cat /sys/class/net/wgA/mtu; else echo "ERR(no-iface)"; fi
}
cfg_verdict(){
  local ma mb; ma=$(mtu_read); mb=$(N bns cat /sys/class/net/wgB/mtu 2>/dev/null)
  case "$ma" in ERR*) echo "nodata (no MTU -> NOT a mismatch; LLD drops)"; return;; esac
  [ -z "$mb" ] && { echo "peer nodata -> 'unpaired/unknown' (NOT mismatch)"; return; }
  [ "$ma" = "$mb" ] && echo "match($ma=$mb)" || echo "MISMATCH($ma!=$mb)"
}

row(){ printf "%-30s | reverse-probe: %-34s | config-compare: %s\n" "$1" "$(probe_verdict)" "$(cfg_verdict)"; }

echo "================ CHANNEL-DOWN BEHAVIOUR ================"
row "0 UP (asym 1500/1420, real BH)"

# State 1: peer dead — underlay disappears (remote host/endpoint down)
N bns ip link set u1 down; sleep 6
row "1 peer DOWN (underlay gone)"
N bns ip link set u1 up; sleep 6; ping -c1 -W2 10.99.0.2 >/dev/null 2>&1

# State 2: local wg iface admin-down (service stop / link down)
ip link set wgA down; sleep 1
row "2 iface ADMIN-DOWN"
ip link set wgA up; sleep 5; ping -c1 -W2 10.99.0.2 >/dev/null 2>&1

# State 3: wg iface removed (tunnel torn down / reconfigured)
ip link del wgA; sleep 1
row "3 iface REMOVED"
echo
echo "Key: a dead channel must read -1/nodata/unreachable, NEVER '>0 black hole' or a false MTU mismatch."