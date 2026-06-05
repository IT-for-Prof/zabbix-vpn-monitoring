#!/usr/bin/env bash
# shellcheck disable=SC1010,SC2086  # ping -M do: "do" is ping's DF arg; diagnostic globbing is fine
# Real-tunnel detector comparison. Args: one or more "iface,target" pairs. Read-only.
PROBE=/etc/zabbix/scripts/wg_pmtu.sh
icmp_df_max(){ for z in 1420 1400 1380 1360 1340 1300 1280 1240 1200; do ping -M do -s $((z-28)) -c2 -W2 "$1" >/dev/null 2>&1 && { echo "$z"; return; }; done; echo 0; }
for pair in "$@"; do
  case "$pair" in *,*) ;; *) echo "skip (need iface,target): $pair"; continue;; esac
  ifc=${pair%%,*}; tgt=${pair##*,}
  echo "==== $ifc -> $tgt  (cfg MTU=$(cat /sys/class/net/$ifc/mtu 2>/dev/null)) ===="
  echo "  prod probe         : $([ -x "$PROBE" ] && "$PROBE" "$ifc" "$tgt" || echo 'n/a')"
  echo "  ICMP small (100B)  : $(ping -c2 -W2 -s 100 "$tgt" >/dev/null 2>&1 && echo reachable || echo 'no echo (ICMP-dark?)')"
  echo "  ICMP-DF max-deliv  : $(icmp_df_max "$tgt")"
  echo "  ip route get PMTU  : $(ip route get "$tgt" 2>/dev/null | tr '\n' ' ' | grep -oE 'mtu [0-9]+' || echo 'no exception')"
  python3 - "$tgt" <<'PY'
import socket,sys
t=sys.argv[1]
# IP_MTU (UDP)
u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); u.setsockopt(socket.IPPROTO_IP,10,2)
try:
    u.connect((t,9)); [u.send(b'x'*1391) for _ in range(3)]; mtu=u.getsockopt(socket.IPPROTO_IP,14)
except Exception as e: mtu='err:%s'%type(e).__name__
print("  IP_MTU (getsockopt): %s"%mtu)
# TCP port reachability (SYN connect) on common ports
openp=[]
for p in (443,22,80,53,179,8443):
    s=socket.socket(); s.settimeout(2)
    try:
        if s.connect_ex((t,p))==0: openp.append(p)
    except Exception: pass
    finally: s.close()
print("  TCP open ports     : %s"%(openp or "none reachable"))
# TCP-MTU big-send on first open port
if openp:
    p=openp[0]; s=socket.socket(); s.setsockopt(socket.IPPROTO_IP,10,2); s.settimeout(5)
    try:
        s.connect((t,p)); s.sendall(b'G'*8192); r="OK (8KB pushed)"
    except Exception as e: r="STALL(%s)"%type(e).__name__
    finally: s.close()
    print("  TCP-MTU big-send   : port %d -> %s"%(p,r))
PY
  echo "  tracepath          : $(timeout 8 tracepath -n "$tgt" 2>&1 | tail -1)"
  command -v fping >/dev/null 2>&1 && echo "  fping              : $(fping -c2 -t1000 "$tgt" 2>&1 | tail -1)"
done
