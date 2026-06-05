#!/usr/bin/env bash
# Read-only auto PMTU probe comparison. Targets derived from wg. No config changes.
hr(){ echo; echo "######## $* ########"; }
ping_mtu(){ for z in 1500 1492 1480 1452 1420 1400 1380 1360 1340 1300 1280; do s=$((z-28)); ping -M do -s $s -c3 -W2 "$1" >/dev/null 2>&1 && { echo "$z"; return; }; done; echo 0; }
fping_mtu(){ for z in 1500 1492 1480 1452 1420 1400 1380 1360 1340 1300 1280; do b=$((z-28)); fping -M -b $b -c1 -t2000 "$1" >/dev/null 2>&1 && { echo "$z"; return; }; done; echo 0; }
nping_icmp(){ d=$(($1-28)); r=$(nping --icmp --df --data-length $d -c2 -N "$2" 2>/dev/null | grep -oE "Rcvd: [0-9]+" | grep -oE "[0-9]+"); echo "${r:-0}"; }

eps=$(wg show all dump 2>/dev/null | awk 'NF==9{split($4,a,":");print a[1]}' | grep -vE '^\(none\)|^127\.|^$' | sort -u)
tips=$(wg show all dump 2>/dev/null | awk 'NF==9{n=split($5,a,",");for(i=1;i<=n;i++)if(a[i]~/\/32$/){sub(/\/32/,"",a[i]);print a[i]}}' | sort -u)

hr "ICMP TOOL COMPARISON (max-passing IP MTU)  [underlay eps + tunnel ips + 1.1.1.1]"
printf "  %-16s %-8s %-8s %-14s\n" TARGET ping fping "nping@1500/1400"
for t in $eps $tips 1.1.1.1; do
  printf "  %-16s %-8s %-8s %s/%s\n" "$t" "$(ping_mtu $t)" "$(fping_mtu $t)" "$(nping_icmp 1500 $t)" "$(nping_icmp 1400 $t)"
done

hr "TCP FUNCTIONAL PROBE to underlay endpoints (small vs 1493B SYN, DF)"
for host in $eps; do
  for port in 443 22; do
    s=$(nping --tcp -p $port --df --data-length 0    -c2 -N "$host" 2>/dev/null | grep -oE "Rcvd: [0-9]+" | grep -oE "[0-9]+")
    b=$(nping --tcp -p $port --df --data-length 1453 -c2 -N "$host" 2>/dev/null | grep -oE "Rcvd: [0-9]+" | grep -oE "[0-9]+")
    printf "  %-16s tcp/%-3s small=%s big1493=%s\n" "$host" "$port" "${s:-0}" "${b:-0}"
  done
done

hr "TRACEPATH PMTU (tunnel peer ips)"
for t in $tips; do echo "  [$t]"; tracepath -n "$t" 2>&1 | tail -2 | sed 's/^/    /'; done
echo; echo "######## END ########"
