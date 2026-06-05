#!/usr/bin/env bash
# Read-only MTU/PMTU posture audit for a VPN gateway. No changes.
# Run:  ssh <host> 'bash -s' < tools/vpn_mtu_audit.sh
# Reports the mitigations + monitoring prerequisites that the active probe does NOT itself enforce.
echo "host: $(hostname)  | $(uname -s) $(uname -r)"

w(){ printf "  %-26s %s\n" "$1" "$2"; }

w "tcp_mtu_probing (PLPMTUD)" "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null)   [want >=1: TCP self-heals through ICMP black holes]"
w "ip_no_pmtu_disc"           "$(sysctl -n net.ipv4.ip_no_pmtu_disc 2>/dev/null)   [want 0]"

if { iptables-save 2>/dev/null; nft list ruleset 2>/dev/null; } | grep -qiE 'clamp-mss-to-pmtu|TCPMSS|set [^ ]*tcp[^ ]* maxseg'; then
  w "MSS clamping (forward)" "present  [protects forwarded TCP]"
else
  w "MSS clamping (forward)" "ABSENT   [a gateway that forwards TCP through tunnels should clamp]"
fi

if getcap "$(command -v ping)" 2>/dev/null | grep -q cap_net_raw; then
  w "ping cap_net_raw" "yes"
else
  w "ping cap_net_raw" "NO   [the probe cannot set DF -> wg.probe.ok=0]"
fi

to=$(grep -hoE '^[[:space:]]*Timeout=[0-9]+' /etc/zabbix/zabbix_agent2.conf /etc/zabbix/zabbix_agent2.d/*.conf 2>/dev/null | grep -oE '[0-9]+' | sort -rn | head -1)
w "zabbix agent Timeout" "${to:-3}s   [want >=30: the probe can run ~30s on a deep black hole]"
w "deployed probe version" "$(cat /etc/zabbix/scripts/.vpn_pmtu.version 2>/dev/null || echo '(not installed)')"

echo "  tunnel interface MTUs:"
for i in $(ip -o link 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -iE 'wg|awg|tun|as0t|^zt|ovpns' | sort -u); do
  printf "    %-16s mtu=%s\n" "$i" "$(cat "/sys/class/net/$i/mtu" 2>/dev/null)"
done
