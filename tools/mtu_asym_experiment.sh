#!/usr/bin/env bash
# Controlled reproduction of the pf03 asymmetric-MTU / unclamped-TCP black hole, in netns.
# Topology (mirrors incident):
#   SRV --1500-- A(wgA, forwards) ==underlay(frag-drop)== EX(wgB 1420) --1500-- CLI
# Large flow SRV->CLI: end-to-end MSS 1460 (neither tunnel end clamps); A forwards full-size
# into wgA. When wgA MTU=1500, outer=1560 > underlay 1500 -> fragments dropped -> SILENT black hole.
# Runs every candidate detector across 3 variants. Isolated; no production impact. Needs root.
set -u
N(){ ip netns exec "$@"; }
WWW=/tmp/mtuexp_www
cleanup(){
  for ns in a rtr ex srv cli; do ip netns del $ns 2>/dev/null; done
  rm -rf "$WWW" 2>/dev/null
}
trap cleanup EXIT; cleanup 2>/dev/null

for ns in a rtr ex srv cli; do ip netns add $ns; N $ns ip link set lo up; done
N a   sysctl -qw net.ipv4.ip_forward=1
N rtr sysctl -qw net.ipv4.ip_forward=1
N ex  sysctl -qw net.ipv4.ip_forward=1

mkveth(){ # name1 ns1 ip1   name2 ns2 ip2   mtu
  ip link add "$1" netns "$2" type veth peer name "$4" netns "$5"
  N "$2" ip addr add "$3" dev "$1"; N "$2" ip link set "$1" mtu "$7" up
  N "$5" ip addr add "$6" dev "$4"; N "$5" ip link set "$4" mtu "$7" up
}
# SRV(10.50.0.2) -- A(10.50.0.1)
mkveth srv0 srv 10.50.0.2/24   a_srv a 10.50.0.1/24   1500
# A(10.213.1.1) -- RTR(10.213.1.2)
mkveth a_rt a 10.213.1.1/24    rt_a rtr 10.213.1.2/24  1500
# RTR(10.213.2.1) -- EX(10.213.2.2)
mkveth rt_ex rtr 10.213.2.1/24 ex_rt ex 10.213.2.2/24  1500
# EX(10.60.0.1) -- CLI(10.60.0.2)
mkveth ex_c ex 10.60.0.1/24    cli0 cli 10.60.0.2/24   1500

# underlay: RTR silently drops forwarded fragments (the DPI/cloud-SG black hole)
N rtr iptables -A FORWARD -f -j DROP

# routes
N srv ip route add default via 10.50.0.1
N cli ip route add default via 10.60.0.1
N a   ip route add 10.213.2.0/24 via 10.213.1.2
N ex  ip route add 10.213.1.0/24 via 10.213.2.1

# WireGuard A <-> EX (underlay traverses RTR)
Af=$(mktemp); Bf=$(mktemp); wg genkey >"$Af"; wg genkey >"$Bf"
Apub=$(wg pubkey<"$Af"); Bpub=$(wg pubkey<"$Bf")
N a ip link add wgA type wireguard
N a wg set wgA private-key "$Af" listen-port 51899 peer "$Bpub" allowed-ips 10.99.99.2/32,10.60.0.0/24 endpoint 10.213.2.2:51900 persistent-keepalive 5
N a ip addr add 10.99.99.1/24 dev wgA; N a ip link set wgA mtu 1420 up
N ex ip link add wgB type wireguard
N ex wg set wgB private-key "$Bf" listen-port 51900 peer "$Apub" allowed-ips 10.99.99.1/32,10.50.0.0/24 endpoint 10.213.1.1:51899 persistent-keepalive 5
N ex ip addr add 10.99.99.2/24 dev wgB; N ex ip link set wgB mtu 1420 up
rm -f "$Af" "$Bf"
# A reaches CLI-subnet via tunnel; EX reaches SRV-subnet via tunnel
N a  ip route add 10.60.0.0/24 dev wgA
N ex ip route add 10.50.0.0/24 dev wgB
sleep 3; N a ping -c1 -W2 10.99.99.2 >/dev/null 2>&1; sleep 1

# big file + server behind A
mkdir -p "$WWW"; head -c 524288 /dev/urandom > "$WWW/big"
N srv bash -c "cd $WWW && python3 -m http.server 8000 --bind 10.50.0.2 >/dev/null 2>&1 &"
sleep 1

# ---- detectors ----
pingdf(){ N "$1" ping -c2 -W2 -M do -s "$2" "$3" >/dev/null 2>&1 && echo OK || echo FAIL; }
tcpxfer(){ # CLI downloads big from SRV through the tunnel
  local out
  out=$(N cli timeout 12 python3 -c 'import urllib.request as u
try:
 d=u.urlopen("http://10.50.0.2:8000/big",timeout=10).read();print("OK" if len(d)>=524288 else "SHORT")
except Exception:
 print("FAIL")' 2>/dev/null)
  echo "${out:-TIMEOUT}"
}
clampstate(){ N a iptables -t mangle -S 2>/dev/null | grep -q TCPMSS && echo yes || echo no; }
cfgcmp(){ local ma mb; ma=$(N a cat /sys/class/net/wgA/mtu); mb=$(N ex cat /sys/class/net/wgB/mtu)
  [ "$ma" = "$mb" ] && echo "match($ma=$mb)" || echo "MISMATCH($ma!=$mb)"; }

# ---- WG pubkey join key (Tier-1 auto-pairing primitive) ----
echo "================ WG pubkey join key (auto-pairing) ================"
apub=$(N a wg show wgA public-key); apeer=$(N a wg show wgA peers)
bpub=$(N ex wg show wgB public-key); bpeer=$(N ex wg show wgB peers)
echo "  A: local=${apub:0:12}.. peer=${apeer:0:12}..   EX: local=${bpub:0:12}.. peer=${bpeer:0:12}.."
[ "$apeer" = "$bpub" ] && [ "$bpeer" = "$apub" ] && echo "  -> JOINABLE: A.peer==EX.local && EX.peer==A.local  (no subnet/hardcode needed)" || echo "  -> NOT joinable"

learnedpmtu(){ N srv ip route get 10.60.0.2 2>/dev/null | grep -oE 'mtu [0-9]+' | awk '{print $2}' | head -1; }

run_variant(){ # label   wgA_mtu   clamp(on/off)   ptb(allow/filter)
  local label="$1" mtu="$2" clamp="$3" ptb="$4"
  N a iptables -t mangle -F; N a iptables -F; N srv iptables -F
  N a ip link set wgA mtu "$mtu"
  N srv ip route flush cache; N a ip route flush cache
  if [ "$clamp" = on ]; then
    N a iptables -t mangle -A FORWARD -o wgA -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360
    N a iptables -t mangle -A FORWARD -i wgA -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360
  fi
  if [ "$ptb" = filter ]; then  # model silent black hole: PTB never reaches the sender (asymmetry/DPI)
    N a   iptables -A OUTPUT -o a_srv -p icmp --icmp-type fragmentation-needed -j DROP
    N srv iptables -A INPUT  -p icmp --icmp-type fragmentation-needed -j DROP
  fi
  sleep 1; N a ping -c1 -W2 10.99.99.2 >/dev/null 2>&1
  local xfer ismp isbg pm; ismp=$(pingdf ex $((1420-28)) 10.99.99.1); isbg=$(pingdf a $((mtu-28)) 10.99.99.2)
  xfer=$(tcpxfer); pm=$(learnedpmtu)
  printf "%-32s | %-8s | %-7s | %-8s | %-6s | %-7s | %-9s | %s\n" \
    "$label" "$ismp" "$isbg" "$xfer" "$ptb" "$(clampstate)" "${pm:-none}" "$(cfgcmp)"
}

echo
echo "================ DETECTOR MATRIX ================"
printf "%-32s | %-8s | %-7s | %-8s | %-6s | %-7s | %-9s | %s\n" \
  "variant" "ICMPsml" "ICMPbig" "TCPxfer" "PTB" "clamp" "srvPMTU" "config-compare"
printf '%.0s-' {1..118}; echo
run_variant "1 symmetric (1420)"              1420 off allow
run_variant "2a ASYM noclamp, PTB allowed"    1500 off allow
run_variant "2b ASYM noclamp, PTB FILTERED"   1500 off filter
run_variant "3a ASYM+clamp, PTB allowed"      1500 on  allow
run_variant "3b ASYM+clamp, PTB FILTERED"     1500 on  filter
echo
echo "Legend: ICMPsml=prod probe from 1420 end | ICMPbig=reverse probe from 1500 end |"
echo "  TCPxfer=real large download SRV->CLI | PTB=is ICMP frag-needed allowed back to sender |"
echo "  srvPMTU=PMTU the sender learned (1420=self-healed, none/1500=blind) | 2b == the incident"