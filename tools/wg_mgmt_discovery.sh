#!/usr/bin/env bash
# Read-only: how is WireGuard iface $1 brought up? No changes.
W=$1
echo "===== systemd units mentioning wg/wireguard ====="
systemctl list-unit-files 2>/dev/null | grep -iE 'wg|wireguard'
systemctl list-units --all --type=service 2>/dev/null | grep -iE 'wg|wireguard'
echo "===== systemd-networkd .netdev/.network ====="
ls -1 /etc/systemd/network/ 2>/dev/null | grep -iE 'wg|wire|netdev' || echo "  (none)"
grep -rilE "$W|wireguard" /etc/systemd/network/ 2>/dev/null
echo "===== /etc/wireguard ====="
ls -la /etc/wireguard/ 2>/dev/null
echo "===== custom scripts/units referencing $W (excluding /etc/wireguard) ====="
grep -rslE "$W" /etc/ /usr/local/ /opt/ /root/ 2>/dev/null | grep -vE '/etc/wireguard/|nf_conntrack' | head
echo "===== cron referencing wg ====="
( crontab -l 2>/dev/null; cat /etc/cron.d/* /etc/crontab 2>/dev/null ) | grep -iE 'wg|wire' | grep -v '^#' | head
echo "===== NetworkManager devices ====="
command -v nmcli >/dev/null 2>&1 && nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | grep -iE 'wire|wg' || echo "  (no nmcli / none)"
echo "===== running wg-related processes ====="
ps -eo pid,ppid,comm,args 2>/dev/null | grep -iE 'wg|wireguard|wgmgr|netmaker|innernet|firezone' | grep -v grep | head
echo "===== docker (is wg created inside a container?) ====="
docker ps --format '{{.Names}}: {{.Image}}' 2>/dev/null | head || echo "  (no docker access)"
echo "===== END ====="
