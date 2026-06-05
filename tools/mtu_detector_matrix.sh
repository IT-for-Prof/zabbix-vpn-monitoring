#!/usr/bin/env bash
# shellcheck disable=SC1010,SC2086  # ping -M do: "do" is ping's DF arg; diagnostic globbing is fine
# Controlled ground-truth experiment: induce a REAL silent WG MTU black hole in netns,
# then run EVERY candidate detector at (a) healthy MTU and (b) black-hole MTU.
# Ground truth is known: at black-hole state, large packets are silently dropped at the
# transit router (fragments DROPPED, no ICMP PTB) -> the classic undetectable-by-passive case.
# No production impact (isolated netns). Needs root.
set -u
REPO=/opt/zabbix-vpn-monitoring
HTTP_PID=""
cleanup(){ [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null; ip netns del rtr 2>/dev/null; ip netns del right 2>/dev/null; ip link del wgA 2>/dev/null; ip link del a0 2>/dev/null; }
trap cleanup EXIT; cleanup 2>/dev/null

# ---- topology: A(root) --1300-- Router --1500-- B(right); router drops transit fragments ----
ip netns add rtr; ip netns add right
ip link add a0 type veth peer name a1; ip link set a1 netns rtr
ip addr add 10.213.1.1/24 dev a0; ip link set a0 mtu 1300 up
ip netns exec rtr ip addr add 10.213.1.2/24 dev a1; ip netns exec rtr ip link set a1 mtu 1300 up
ip netns exec rtr ip link add b0 type veth peer name b1; ip netns exec rtr ip link set b1 netns right
ip netns exec rtr ip addr add 10.213.2.1/24 dev b0; ip netns exec rtr ip link set b0 mtu 1500 up
ip netns exec right ip addr add 10.213.2.2/24 dev b1; ip netns exec right ip link set b1 mtu 1500 up
ip netns exec rtr ip link set lo up; ip netns exec right ip link set lo up
ip netns exec rtr sysctl -qw net.ipv4.ip_forward=1
ip netns exec rtr iptables -A FORWARD -i a1 -f -j DROP        # silently drop transit fragments
ip route add 10.213.2.0/24 via 10.213.1.2
ip netns exec right ip route add 10.213.1.0/24 via 10.213.2.1
Af=$(mktemp); Bf=$(mktemp); wg genkey >"$Af"; wg genkey >"$Bf"; Apub=$(wg pubkey<"$Af"); Bpub=$(wg pubkey<"$Bf")
ip link add wgA type wireguard
wg set wgA private-key "$Af" listen-port 51899 peer "$Bpub" allowed-ips 10.99.99.2/32 endpoint 10.213.2.2:51900 persistent-keepalive 5
ip addr add 10.99.99.1/24 dev wgA; ip link set wgA mtu 1200 up
ip netns exec right ip link add wgB type wireguard
ip netns exec right wg set wgB private-key "$Bf" listen-port 51900 peer "$Apub" allowed-ips 10.99.99.1/32 endpoint 10.213.1.1:51899 persistent-keepalive 5
ip netns exec right ip addr add 10.99.99.2/24 dev wgB; ip netns exec right ip link set wgB mtu 1200 up
rm -f "$Af" "$Bf"; sleep 3; ping -c1 -W2 10.99.99.2 >/dev/null 2>&1; sleep 1
# TCP listener on the peer so the TCP-MTU probe has a port (ICMP-independent target)
ip netns exec right python3 -m http.server 8443 --bind 10.99.99.2 >/dev/null 2>&1 &
HTTP_PID=$!; sleep 1

TGT=10.99.99.2

# ---------- detectors ----------
det_icmp_small(){ ping -c2 -W2 -s 100 "$TGT" >/dev/null 2>&1 && echo "OK (tunnel reachable)" || echo "FAIL"; }
det_prod_probe(){ bash "$REPO/lib/wg_pmtu.sh" wgA "$TGT"; }    # the real production probe
det_icmp_df_max(){ for z in 1420 1400 1380 1360 1340 1320 1300 1280 1240 1200; do ping -M do -s $((z-28)) -c2 -W2 "$TGT" >/dev/null 2>&1 && { echo "$z"; return; }; done; echo 0; }
det_ip_mtu_udp(){ python3 - "$TGT" <<'PY'
import socket,sys
t=sys.argv[1]; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.setsockopt(socket.IPPROTO_IP,10,2)        # IP_MTU_DISCOVER = IP_PMTUDISC_DO
s.connect((t,9))
for _ in range(3):
    try: s.send(b'x'*1391)                  # inner < wg MTU -> enters tunnel, no local EMSGSIZE
    except OSError: pass
print(s.getsockopt(socket.IPPROTO_IP,14))   # IP_MTU = kernel's path MTU for dest
PY
}
det_route_get(){ ip route get "$TGT" 2>/dev/null | tr '\n' ' ' | grep -oE 'mtu [0-9]+' || echo "(no PMTU exception -> link MTU)"; }
det_tcp_mtu(){ python3 - "$TGT" 8443 <<'PY'
import socket,sys
t,port=sys.argv[1],int(sys.argv[2])
def trial(n):
    s=socket.socket(); s.setsockopt(socket.IPPROTO_IP,10,2); s.settimeout(4)
    try:
        s.connect((t,port)); s.sendall(b'G'*n); return "OK"
    except Exception as e: return "STALL(%s)"%type(e).__name__
    finally: s.close()
print("connect+small(64B)=%s   large(8KB,forces full segments)=%s" % (trial(64), trial(8192)))
PY
}
snap(){ ip netns exec "$1" cat /proc/net/snmp 2>/dev/null || cat /proc/net/snmp; }
ipfield(){ echo "$1" | awk '/^Ip:/{h=$0; getline v} END{n=split(h,H);split(v,V); for(i=1;i<=n;i++) if(H[i]=="'"$2"'") print V[i]}'; }
icmpfield(){ echo "$1" | awk '/^Icmp:/{h=$0; getline v} END{n=split(h,H);split(v,V); for(i=1;i<=n;i++) if(H[i]=="'"$2"'") print V[i]}'; }

run_all(){
  echo "  D1 ICMP small-ping liveness : $(det_icmp_small)"
  echo "  D2 PRODUCTION probe (gap)   : $(det_prod_probe)        ( -2 off | -1 no-ICMP | 0 ok | >0 gap )"
  echo "  D3 ICMP-DF max-deliverable  : $(det_icmp_df_max)  (configured wg MTU shown in header)"
  echo "  D4 passive IP_MTU (getsockopt UDP) : $(det_ip_mtu_udp)"
  echo "  D5 passive ip route get PMTU       : $(det_route_get)"
  echo "  D6 TCP-MTU probe (ICMP-independent): $(det_tcp_mtu)"
  # D7 passive counters: delta over a 40x big-DF-ping burst, on endpoint(A) and router
  a0=$(snap ""); r0=$(snap rtr)
  ping -c40 -i0.03 -M do -s 1392 "$TGT" >/dev/null 2>&1
  a1=$(snap ""); r1=$(snap rtr)
  echo "  D7 passive counters over 40x big-DF burst:"
  echo "       endpoint A: FragFails dlt=$(( $(ipfield "$a1" FragFails) - $(ipfield "$a0" FragFails) ))  ICMP OutDestUnreachs dlt=$(( $(icmpfield "$a1" OutDestUnreachs) - $(icmpfield "$a0" OutDestUnreachs) ))  wgA tx_dropped=$(cat /sys/class/net/wgA/statistics/tx_dropped)"
  echo "       router    : FragFails dlt=$(( $(ipfield "$r1" FragFails) - $(ipfield "$r0" FragFails) ))  ICMP OutDestUnreachs dlt=$(( $(icmpfield "$r1" OutDestUnreachs) - $(icmpfield "$r0" OutDestUnreachs) ))"
  # D8 eBPF: kfree_skb NETFILTER_DROP (reason 8) during a burst — only visible where the drop happens
  bt_out=$(mktemp)
  bpftrace -e 'tracepoint:skb:kfree_skb /args->reason==8/ {@netfilter_drop=count();} interval:s:5{exit();}' >"$bt_out" 2>/dev/null &
  btp=$!; sleep 1; ping -c60 -i0.03 -M do -s 1392 "$TGT" >/dev/null 2>&1; wait $btp 2>/dev/null
  echo "  D8 eBPF kfree_skb(NETFILTER_DROP) during burst: $(grep -oE '@netfilter_drop: [0-9]+' "$bt_out" || echo 'none')"; rm -f "$bt_out"
}

echo "============================================================"
echo " PHASE 1 — HEALTHY  (wgA MTU 1200, correct for the 1300 path)"
echo "============================================================"
run_all

echo
echo "============================================================"
echo " PHASE 2 — BLACK HOLE (raise wgA MTU 1200 -> 1420; outer now"
echo "           fragments on the 1300 underlay; router DROPS them)"
echo "============================================================"
ip link set wgA mtu 1420; sleep 1
run_all
echo
echo "### done (auto teardown) ###"
