#!/usr/bin/env bash
# Read-only WireGuard/MTU/router diagnostic. No state changes.
now=$(date +%s)
hr(){ echo "======== $* ========"; }

hr "HOST"
hostname; echo "kernel: $(uname -r)  cpus: $(nproc)  uptime:$(uptime -p 2>/dev/null)"

hr "INTERFACES + MTU"
for i in /sys/class/net/*/mtu; do d=$(echo "$i"|cut -d/ -f5); printf "  %-16s mtu=%s state=%s\n" "$d" "$(cat "$i")" "$(cat /sys/class/net/$d/operstate 2>/dev/null)"; done

if command -v wg >/dev/null 2>&1; then
  hr "WIREGUARD handshake age + transfer (dump)"
  wg show all dump 2>/dev/null | awk -v now="$now" 'NF==9{
    age=now-$6; ks=$9;
    ah=(age<0)?"never":age"s";
    printf "  if=%-12s peer=%.10s... endpoint=%-22s allowed=%-20s hs_age=%-9s keepalive=%-4s rx=%s tx=%s\n",$1,$2,$4,$5,ah,ks,$7,$8
  }'
  hr "WIREGUARD tx errors/drops per iface (sysfs)"
  for w in $(wg show interfaces 2>/dev/null); do
    printf "  %-14s tx_errors=%s tx_dropped=%s rx_errors=%s\n" "$w" \
      "$(cat /sys/class/net/$w/statistics/tx_errors 2>/dev/null)" \
      "$(cat /sys/class/net/$w/statistics/tx_dropped 2>/dev/null)" \
      "$(cat /sys/class/net/$w/statistics/rx_errors 2>/dev/null)"
  done
else
  hr "WIREGUARD"; echo "  (wg not installed / no interfaces)"
fi

hr "ROUTING default + PMTU cache"
ip route show default
echo "  cached pmtu entries: $(ip route show cached 2>/dev/null | grep -c mtu)"

hr "SYSCTLS (mtu/forwarding/pmtud)"
sysctl -n net.ipv4.ip_forward 2>/dev/null | sed 's/^/  ip_forward=/'
sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null | sed 's/^/  tcp_mtu_probing=/'
sysctl -n net.ipv4.tcp_base_mss 2>/dev/null | sed 's/^/  tcp_base_mss=/'
sysctl -n net.ipv4.ip_no_pmtu_disc 2>/dev/null | sed 's/^/  ip_no_pmtu_disc=/'

hr "CONNTRACK"
cc=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
cm=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
[ -n "$cc" ] && echo "  count=$cc max=$cm ($(awk "BEGIN{if($cm>0)printf \"%.1f\",100*$cc/$cm}")%)" || echo "  (conntrack not loaded)"

hr "PASSIVE BLACKHOLE COUNTERS"
awk 'NR==1{for(i=1;i<=NF;i++)h[i]=$i} NR==2{for(i=1;i<=NF;i++)v[h[i]]=$i} END{printf "  TCP RetransSegs=%s OutSegs=%s (%.3f%%)\n",v["RetransSegs"],v["OutSegs"],(v["OutSegs"]>0?100*v["RetransSegs"]/v["OutSegs"]:0)}' <(grep "^Tcp:" /proc/net/snmp)
awk 'NR==1{for(i=1;i<=NF;i++)h[i]=$i} NR==2{for(i=1;i<=NF;i++)v[h[i]]=$i} END{printf "  IP FragFails=%s FragCreates=%s ReasmFails=%s\n",v["FragFails"],v["FragCreates"],v["ReasmFails"]}' <(grep "^Ip:" /proc/net/snmp)
echo "  ICMP6 InPktTooBig=$(awk '/Icmp6InPktTooBigs/{print $2}' /proc/net/snmp6 2>/dev/null) OutPktTooBig=$(awk '/Icmp6OutPktTooBigs/{print $2}' /proc/net/snmp6 2>/dev/null)"
drp=$(awk '{c=$2;n=0;for(i=1;i<=length(c);i++){d=index("0123456789abcdef",substr(c,i,1))-1;n=n*16+d}sum+=n}END{print sum}' /proc/net/softnet_stat)
sqz=$(awk '{c=$3;n=0;for(i=1;i<=length(c);i++){d=index("0123456789abcdef",substr(c,i,1))-1;n=n*16+d}sum+=n}END{print sum}' /proc/net/softnet_stat)
echo "  softnet dropped=$drp time_squeeze=$sqz"
echo "  sockets w/ retrans now: $(ss -ti state established 2>/dev/null | grep -c retrans) / est $(ss -tH state established 2>/dev/null | wc -l)"

# ---- Active PMTU sweep, targets auto-derived from wg ----
sweep(){ host=$1; for ipsz in 1500 1492 1452 1420 1400 1380 1340 1280; do s=$((ipsz-28)); if ping -M do -s $s -c3 -W2 "$host" >/dev/null 2>&1; then printf "    %-16s IP=%-4s OK\n" "$host" "$ipsz"; else printf "    %-16s IP=%-4s FAIL\n" "$host" "$ipsz"; fi; done; }
if command -v wg >/dev/null 2>&1; then
  hr "PMTU SWEEP - underlay endpoints (+1.1.1.1 control)"
  eps=$(wg show all dump 2>/dev/null | awk 'NF==9{split($4,a,":");print a[1]}' | grep -vE '^\(none\)|^127\.|^$' | sort -u)
  for ep in $eps 1.1.1.1; do echo "  [$ep]"; sweep "$ep"; done
  hr "PMTU SWEEP - tunnel peer IPs (/32 allowed-ips)"
  tips=$(wg show all dump 2>/dev/null | awk 'NF==9{n=split($5,a,",");for(i=1;i<=n;i++)if(a[i]~/\/32$/){sub(/\/32/,"",a[i]);print a[i]}}' | sort -u)
  for tip in $tips; do echo "  [$tip]"; sweep "$tip"; done
fi
echo "======== END ========"
