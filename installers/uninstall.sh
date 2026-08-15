#!/usr/bin/env bash
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
rm -f /etc/zabbix/scripts/wg_pmtu.sh /etc/zabbix/scripts/vpn_pmtu.sh /etc/zabbix/scripts/gate_wireguard.sh \
      /etc/zabbix/scripts/gate_zerotier.sh /etc/zabbix/scripts/gate_openvpn.sh \
      /etc/zabbix/scripts/wg_discovery.sh /etc/zabbix/scripts/zerotier_discovery.sh \
      /etc/zabbix/scripts/openvpn_discovery.sh /etc/zabbix/scripts/vpn_posture.sh \
      /etc/zabbix/scripts/.vpn_pmtu.version \
      /etc/zabbix/zabbix_agent2.d/wireguard.conf /etc/zabbix/zabbix_agent2.d/zerotier.conf \
      /etc/zabbix/zabbix_agent2.d/openvpn.conf /etc/zabbix/zabbix_agent2.d/posture.conf \
      /etc/zabbix/zabbix_agent2.d/zz-vpn-probe-timeout.conf
# note: timestamped /etc/zabbix/scripts/.backup-* dirs are left in place for rollback history
# Every sudoers file install.sh can write — leaving one behind would keep a standing
# NOPASSWD root grant on a host the operator believes is clean.
rm -f /etc/sudoers.d/zabbix-wg /etc/sudoers.d/zabbix-zerotier /etc/sudoers.d/zabbix-openvpn-as \
      /etc/sudoers.d/zabbix-posture
# An install interrupted between staging and commit_sudoers leaves a *.tmp behind. sudo ignores
# include-dir filenames containing a dot, so it was never live — but it is still grant text.
rm -f /etc/sudoers.d/zabbix-*.tmp
systemctl reload zabbix-agent2 2>/dev/null || systemctl restart zabbix-agent2
echo "UNINSTALL OK (cap_net_raw on ping and /etc/hosts left as-is)"
