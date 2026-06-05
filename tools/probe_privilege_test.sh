#!/usr/bin/env bash
# Read-only: can the zabbix agent user run the probe + dump? Decides privilege model. No changes.
echo "=== zabbix user ==="; id zabbix 2>&1
echo "=== ping_group_range (unprivileged ICMP gids) ==="; sysctl net.ipv4.ping_group_range 2>&1
echo "=== ping/fping presence + caps ==="
for t in ping fping; do p=$(command -v $t); echo "$t: ${p:-MISSING} $( [ -n "$p" ] && getcap "$p" 2>/dev/null)"; done
echo
echo "=== TEST A1: zabbix user, control ping -M do 1400B to clean 1.1.1.1 (expect: works) ==="
sudo -u zabbix ping -c2 -W2 -M do -s 1372 1.1.1.1 2>&1 | tail -2
echo "=== TEST A2: zabbix user, ping -M do 1500B to 217.78.226.2 (PMTU 1492; expect: FAIL if DF honored) ==="
sudo -u zabbix ping -c2 -W2 -M do -s 1472 217.78.226.2 2>&1 | tail -3
echo "=== TEST A3: zabbix user, ping -M do 1492B to 217.78.226.2 (expect: OK) ==="
sudo -u zabbix ping -c2 -W2 -M do -s 1464 217.78.226.2 2>&1 | tail -2
echo
echo "=== TEST B: zabbix user wg show all dump (expect: needs root) ==="
sudo -u zabbix wg show all dump 2>&1 | head -2
echo "=== TEST B2: fping -M as zabbix to 217.78.226.2 @1500 vs @1492 ==="
echo -n "  @1500: "; sudo -u zabbix fping -M -b 1472 -c1 -t1500 217.78.226.2 2>&1 | tail -1
echo -n "  @1492: "; sudo -u zabbix fping -M -b 1464 -c1 -t1500 217.78.226.2 2>&1 | tail -1
echo
echo "=== agent: which agent + UserParameter support ==="
systemctl is-active zabbix-agent2 2>/dev/null; systemctl is-active zabbix-agent 2>/dev/null
echo "=== /sys mtu readable by zabbix? ==="
sudo -u zabbix cat /sys/class/net/wg_sr_relay/mtu 2>&1
echo "=== END ==="
