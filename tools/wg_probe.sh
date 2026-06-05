#!/usr/bin/env bash
# Read-only PMTU probe tool comparison. No config changes.
hr(){ echo; echo "######## $* ########"; }

# max-passing IP size (descending; first OK = path MTU est). -c3 tolerates 2 loss.
ping_mtu(){ for z in 1500 1492 1480 1452 1420 1400 1380 1360 1340 1300 1280; do s=$((z-28)); ping -M do -s $s -c3 -W2 "$1" >/dev/null 2>&1 && { echo "$z"; return; }; done; echo 0; }
fping_mtu(){ for z in 1500 1492 1480 1452 1420 1400 1380 1360 1340 1300 1280; do b=$((z-28)); fping -M -b $b -c1 -t2000 "$1" >/dev/null 2>&1 && { echo "$z"; return; }; done; echo 0; }
nping_icmp(){ z=$1; host=$2; d=$((z-28)); r=$(nping --icmp --df --data-length $d -c2 -N "$host" 2>/dev/null | grep -oE "Rcvd: [0-9]+" | grep -oE "[0-9]+"); echo "${r:-0}"; }

TARGETS_UNDERLAY="203.0.113.65 203.0.113.21 203.0.113.78"
TARGETS_TUNNEL="192.0.2.3 172.20.255.1"

hr "ICMP TOOL COMPARISON (max-passing IP MTU per tool)"
printf "  %-16s %-10s %-10s %-14s\n" TARGET ping fping "nping@1500/1400"
for t in $TARGETS_UNDERLAY $TARGETS_TUNNEL 1.1.1.1; do
  printf "  %-16s %-10s %-10s %s/%s\n" "$t" "$(ping_mtu $t)" "$(fping_mtu $t)" "$(nping_icmp 1500 $t)" "$(nping_icmp 1400 $t)"
done

hr "TCP FUNCTIONAL PROBE (does TCP get through where ICMP is blind?)"
# small SYN vs large SYN (+payload, DF). Rcvd>0 = packet of that size arrived.
for host in 203.0.113.78 203.0.113.65 203.0.113.21; do
  for port in 443 22 80; do
    small=$(nping --tcp -p $port --df --data-length 0    -c2 -N "$host" 2>/dev/null | grep -oE "Rcvd: [0-9]+" | grep -oE "[0-9]+")
    big=$(  nping --tcp -p $port --df --data-length 1453 -c2 -N "$host" 2>/dev/null | grep -oE "Rcvd: [0-9]+" | grep -oE "[0-9]+")
    printf "  %-16s tcp/%-3s  small_SYN_rcvd=%s  big_SYN(1493B)_rcvd=%s\n" "$host" "$port" "${small:-0}" "${big:-0}"
  done
done

hr "TRACEPATH (kernel PMTU discovery, underlay)"
for t in 203.0.113.21 203.0.113.65 1.1.1.1; do echo "  [$t]"; tracepath -n "$t" 2>&1 | tail -3 | sed 's/^/    /'; done

hr "TRACEPATH (through tunnels)"
for t in 192.0.2.3 172.20.255.1; do echo "  [$t]"; tracepath -n "$t" 2>&1 | tail -3 | sed 's/^/    /'; done

hr "MTR loss/latency to exit peers (10 cycles)"
for t in 203.0.113.65 203.0.113.78; do echo "  [$t]"; mtr -n -r -c 10 "$t" 2>&1 | tail -4 | sed 's/^/    /'; done
echo; echo "######## END ########"
