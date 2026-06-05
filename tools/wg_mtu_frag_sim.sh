#!/usr/bin/env bash
# REAL isolated WG MTU black-hole sim v2: underlay DROPS FRAGMENTS (cloud-SG/DPI-style). No prod impact.
set -u
NS=mtutest
cleanup(){
  iptables -D OUTPUT -o vsim0 -f -j DROP 2>/dev/null
  ip netns del $NS 2>/dev/null; ip link del wgsimA 2>/dev/null; ip link del vsim0 2>/dev/null
}
trap cleanup EXIT; cleanup 2>/dev/null

maxpass(){ for z in 1420 1400 1340 1300 1280 1240 1200 1100 1000; do b=$((z-28)); fping -M -b $b -c1 -t1200 "$1" >/dev/null 2>&1 && { echo "$z"; return; }; done; echo 0; }
ipctr(){ awk -v k="$1" 'NR==1{for(i=1;i<=NF;i++)h[i]=$i}NR==2{for(i=1;i<=NF;i++)v[h[i]]=$i}END{print v[k]+0}' <(grep "^Ip:" /proc/net/snmp); }

ip netns add $NS
ip link add vsim0 type veth peer name vsim1; ip link set vsim1 netns $NS
ip addr add 10.213.213.1/24 dev vsim0; ip link set vsim0 mtu 1300 up
ip netns exec $NS ip addr add 10.213.213.2/24 dev vsim1; ip netns exec $NS ip link set vsim1 mtu 1300 up
ip netns exec $NS ip link set lo up
Af=$(mktemp); Bf=$(mktemp); wg genkey >$Af; wg genkey >$Bf; Apub=$(wg pubkey<$Af); Bpub=$(wg pubkey<$Bf)
ip link add wgsimA type wireguard
wg set wgsimA private-key $Af listen-port 51899 peer $Bpub allowed-ips 10.99.99.2/32 endpoint 10.213.213.2:51900 persistent-keepalive 5
ip addr add 10.99.99.1/24 dev wgsimA; ip link set wgsimA mtu 1240 up
ip netns exec $NS ip link add wgsimB type wireguard
ip netns exec $NS wg set wgsimB private-key $Bf listen-port 51900 peer $Apub allowed-ips 10.99.99.1/32 endpoint 10.213.213.1:51899 persistent-keepalive 5
ip netns exec $NS ip addr add 10.99.99.2/24 dev wgsimB; ip netns exec $NS ip link set wgsimB mtu 1240 up
rm -f $Af $Bf; sleep 3; ping -c1 -W2 10.99.99.2 >/dev/null 2>&1; sleep 1

echo "### BASELINE underlay=1300 (drops fragments), wg MTU=1240 (correct) ###"
echo "  max-deliverable IP=$(maxpass 10.99.99.2)   ping1240=$(ping -c2 -W2 -M do -s 1212 10.99.99.2 >/dev/null 2>&1 && echo OK || echo FAIL)   handshake=$([ "$(wg show wgsimA latest-handshakes|awk '{print $2}')" != 0 ]&&echo up||echo none)"

echo
echo "### ACTION: raise wg MTU 1240 -> 1420 (path can't carry it; fragments dropped) ###"
ip link set wgsimA mtu 1420
iptables -A OUTPUT -o vsim0 -f -j DROP
sleep 1
ping -c2 -W2 -s 100 10.99.99.2 >/dev/null 2>&1 && echo "  small ping 128B: OK   handshake age=$(( $(date +%s) - $(wg show wgsimA latest-handshakes|awk '{print $2}') ))s  -> tunnel still 'UP'"
echo "  large ping 1420B: $(ping -c3 -W2 -M do -s 1392 10.99.99.2 >/dev/null 2>&1 && echo OK || echo 'FAIL  <== SILENT BLACK HOLE')"

echo
echo "### DETECTORS ###"
mp=$(maxpass 10.99.99.2)
echo "  [probe]      configured MTU=1420  max-deliverable=$mp  DELTA=$((1420-mp))  (>0 => black hole DETECTED)"
echo "  [tracepath]"; tracepath -n 10.99.99.2 2>&1 | tail -2 | sed 's/^/               /'
fc1=$(ipctr FragCreates); ff1=$(ipctr FragFails)
ping -c20 -i0.1 -M do -s 1392 10.99.99.2 >/dev/null 2>&1
fc2=$(ipctr FragCreates); ff2=$(ipctr FragFails)
echo "  [counter]    FragCreates delta=$((fc2-fc1)) (outer pkt fragmented)   FragFails delta=$((ff2-ff1))"
echo "  [eBPF]       NETFILTER_DROP(reason 8) = dropped fragments during 60-ping burst:"
bpftrace -e 'tracepoint:skb:kfree_skb{@drop[args->reason]=count();} interval:s:6{exit();}' >/tmp/sbt 2>/dev/null &
bt=$!; sleep 1; ping -c60 -i0.05 -M do -s 1392 10.99.99.2 >/dev/null 2>&1; wait $bt
grep '@drop\[8\]\|@drop\[2\]\|@drop\[3\]' /tmp/sbt | sed 's/^/               /'; rm -f /tmp/sbt
echo
echo "### teardown (auto) ###"
