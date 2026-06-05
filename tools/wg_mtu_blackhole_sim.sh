#!/usr/bin/env bash
# Faithful WG MTU black hole: A --(1300)-- Router --(1500)-- B, router DROPS transit fragments.
# All in netns; zero production impact.
set -u
cleanup(){ ip netns del rtr 2>/dev/null; ip netns del right 2>/dev/null; ip link del wgA 2>/dev/null; ip link del a0 2>/dev/null; }
trap cleanup EXIT; cleanup 2>/dev/null

maxpass(){ for z in 1420 1400 1340 1300 1280 1240 1200 1100 1000; do b=$((z-28)); fping -M -b $b -c1 -t1200 "$1" >/dev/null 2>&1 && { echo "$z"; return; }; done; echo 0; }

# namespaces
ip netns add rtr; ip netns add right
# A(root) <-> R
ip link add a0 type veth peer name a1; ip link set a1 netns rtr
ip addr add 10.213.1.1/24 dev a0; ip link set a0 mtu 1300 up
ip netns exec rtr ip addr add 10.213.1.2/24 dev a1; ip netns exec rtr ip link set a1 mtu 1300 up
# R <-> B
ip netns exec rtr ip link add b0 type veth peer name b1; ip netns exec rtr ip link set b1 netns right
ip netns exec rtr ip addr add 10.213.2.1/24 dev b0; ip netns exec rtr ip link set b0 mtu 1500 up
ip netns exec right ip addr add 10.213.2.2/24 dev b1; ip netns exec right ip link set b1 mtu 1500 up
ip netns exec rtr ip link set lo up; ip netns exec right ip link set lo up
# routing + forwarding + FRAGMENT DROP on router forward path
ip netns exec rtr sysctl -qw net.ipv4.ip_forward=1
ip netns exec rtr iptables -A FORWARD -i a1 -f -j DROP            # drop transit fragments from A side
ip route add 10.213.2.0/24 via 10.213.1.2
ip netns exec right ip route add 10.213.1.0/24 via 10.213.2.1
# wireguard A(root) <-> B(right ns), underlay traverses the router
Af=$(mktemp); Bf=$(mktemp); wg genkey >$Af; wg genkey >$Bf; Apub=$(wg pubkey<$Af); Bpub=$(wg pubkey<$Bf)
ip link add wgA type wireguard
wg set wgA private-key $Af listen-port 51899 peer $Bpub allowed-ips 10.99.99.2/32 endpoint 10.213.2.2:51900 persistent-keepalive 5
ip addr add 10.99.99.1/24 dev wgA; ip link set wgA mtu 1200 up
ip netns exec right ip link add wgB type wireguard
ip netns exec right wg set wgB private-key $Bf listen-port 51900 peer $Apub allowed-ips 10.99.99.1/32 endpoint 10.213.1.1:51899 persistent-keepalive 5
ip netns exec right ip addr add 10.99.99.2/24 dev wgB; ip netns exec right ip link set wgB mtu 1200 up
rm -f $Af $Bf; sleep 3; ping -c1 -W2 10.99.99.2 >/dev/null 2>&1; sleep 1

echo "### BASELINE: A-link MTU=1300, wg MTU=1200 (correct), router drops transit fragments ###"
echo "  handshake=$([ \"$(wg show wgA latest-handshakes|awk '{print $2}')\" != 0 ]&&echo up||echo none)   max-deliverable IP=$(maxpass 10.99.99.2)   ping1200=$(ping -c2 -W2 -M do -s 1172 10.99.99.2 >/dev/null 2>&1 && echo OK || echo FAIL)"

echo
echo "### ACTION: raise wg MTU 1200 -> 1420 (outer now fragments on 1300 A-link; router drops the fragments) ###"
ip link set wgA mtu 1420; sleep 1
ping -c2 -W2 -s 100 10.99.99.2 >/dev/null 2>&1 && echo "  small ping 128B: OK   handshake age=$(( $(date +%s) - $(wg show wgA latest-handshakes|awk '{print $2}') ))s  -> tunnel still 'UP' (green!)"
echo "  large ping 1420B(=new MTU): $(ping -c3 -W2 -M do -s 1392 10.99.99.2 >/dev/null 2>&1 && echo OK || echo 'FAIL  <== SILENT BLACK HOLE')"

echo
echo "### DETECTORS ###"
mp=$(maxpass 10.99.99.2)
echo "  [probe]     configured MTU=1420  max-deliverable=$mp  DELTA=$((1420-mp))   ( >0 AND handshake up  =>  MTU BLACK HOLE )"
echo "  [tracepath]"; timeout 8 tracepath -n 10.99.99.2 2>&1 | tail -3 | sed 's/^/              /'
echo "  [eBPF] router fragment drops (NETFILTER_DROP=reason 8) during 60-ping burst:"
bpftrace -e 'tracepoint:skb:kfree_skb /args->reason==8/ {@netfilter_drop=count();} interval:s:6{exit();}' >/tmp/sbt 2>/dev/null &
bt=$!; sleep 1; ping -c60 -i0.05 -M do -s 1392 10.99.99.2 >/dev/null 2>&1; wait $bt
grep '@' /tmp/sbt | sed 's/^/              /'; rm -f /tmp/sbt
echo
echo "### teardown (auto) ###"
