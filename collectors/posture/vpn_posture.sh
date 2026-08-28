#!/bin/sh
# VPN tunnel MTU posture collector -> Zabbix. Config-plane only (NO probing).
# POSIX sh (runs under Linux dash/bash and FreeBSD /bin/sh on pfSense; no bashisms).
# Reports raw facts; the template decides policy (mtu > {$VPN.MTU.MAX}, fwd&&!clamp).
#
# Subcommands:
#   discover         -> Zabbix LLD JSON, one row per VPN tunnel interface
#   mtu   <iface>    -> integer MTU                  (empty if the iface is gone -> LLD drops it)
#   fwd   <iface>    -> 1 if this host forwards transit through <iface>, else 0
#   clamp <iface>    -> 1 if an MSS clamp covers <iface>, else 0
#
# Cross-platform: Linux (sysfs/ip/iptables/nft) and FreeBSD/pfSense (ifconfig/pfctl).
# Privileged reads (iptables-save/nft/pfctl) try a direct call then `sudo -n`; on failure
# clamp reports 0 (a missing-clamp note is Information-only, never a page).
set -u

OS=$(uname -s 2>/dev/null || echo unknown)

# ===================== pure parsers (text in -> verdict out; unit-tested) =====================

# 1 if any token is a non-host prefix (default / 0.0.0.0/0 / a /N with N<32) -> the iface carries
# transit, not just its own /32 peer. Fed wg allowed-ips OR `ip route show dev <iface>`.
parse_has_routed_prefix() {  # stdin: allowed-ips or route lines
  awk '
    { gsub(/,/, " ")                                 # wg allowed-ips may be comma-packed
      for (i=1;i<=NF;i++) {
        if ($i=="default" || $i=="0.0.0.0/0") r=1
        else if ($i ~ /\/[0-9]+$/ && $i !~ /\/32$/ && $i !~ /\/128$/) r=1
    } }
    END { print r+0 }'
}

# Linux: 1 if an MSS clamp covers <iface>. Fed `iptables-save` + `nft list ruleset`.
# A generic clamp-mss-to-pmtu (no oif) is treated as covering; a --set-mss / maxseg must name the iface.
parse_clamp_linux() {  # $1=iface ; stdin=ruleset text
  awk -v ifc="$1" '
    { low=tolower($0)
      if (low ~ /clamp-mss-to-pmtu/) {
        out_seen=out_match=0
        for (i=1;i<NF;i++) if ($i=="-o" || $i=="--out-interface") {
          out_seen=1; sel=$(i+1); sel_match=(sel==ifc)
          if (sel ~ /\+$/) sel_match=(index(ifc, substr(sel, 1, length(sel)-1))==1)
          if ((i>1 && $(i-1)=="!") ? !sel_match : sel_match) out_match=1
        }
        if (!out_seen || out_match) f=1
        next
      }
      # iface bounded by start/space/quote on the left and end/space/quote on the right
      # (^ and $ are real anchors here; inside [] a $ would be a literal dollar).
      if (low ~ /tcpmss|maxseg/ && $0 ~ ("(^|[ \"])" ifc "($|[ \"])")) f=1
    }
    END { print f+0 }'
}

# FreeBSD: 1 if a pf scrub rule on <iface> sets max-mss. Fed `pfctl -sr`.
# Matches an optional direction keyword: "scrub on", "scrub in on", "scrub out on".
parse_clamp_freebsd() {  # $1=iface ; stdin=pfctl -sr text
  awk -v ifc="$1" '
    $0 ~ ("scrub( (in|out))? on " ifc " ") && /max-mss/ { f=1 }
    END { print f+0 }'
}

# FreeBSD: extract MTU from `ifconfig <iface>` output.
parse_mtu_freebsd() {  # stdin: ifconfig <iface>
  awk '{ for (i=1;i<=NF;i++) if ($i=="mtu") { print $(i+1); exit } }'
}

# ===================== command gatherers (call the live tools) =====================

# Direct call first; fall back to `sudo -n` ONLY if the binary exists. Never sudo an absent
# command — that logs a failed-sudo ("a password is required" / "command not allowed") every poll,
# which trips host security monitoring. The granted sudoers cover exactly the privileged reads below.
priv() { "$@" 2>/dev/null && return 0; command -v "$1" >/dev/null 2>&1 && sudo -n "$@" 2>/dev/null; }

# WireGuard/AmneziaWG only. `wg show interfaces` is authoritative on both Linux and FreeBSD
# (pfSense WG ifaces are tun_wgN and answer wg(8)). awg mirrors wg's CLI. OpenVPN/ZeroTier are
# excluded: their MTU model differs (mssfix/fragment, ~2800), so a 1420 ceiling + clamp check
# would false-positive. Enumeration is UNPRIVILEGED — `wg show interfaces` lists names for any user,
# so we NEVER sudo it (doing so logged a failed-sudo every discovery poll). On Linux also union the
# kernel link list. Only the per-iface allowed-ips/clamp reads below need (granted) privilege.
list_ifaces() {
  { wg show interfaces 2>/dev/null; awg show interfaces 2>/dev/null
    [ "$OS" != FreeBSD ] && ip -o link show type wireguard 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//'
  } | tr ' ' '\n' | grep -v '^$' | sort -u
}

get_mtu() {  # <iface>
  if [ "$OS" = FreeBSD ]; then ifconfig "$1" 2>/dev/null | parse_mtu_freebsd
  else cat "/sys/class/net/$1/mtu" 2>/dev/null; fi
}

get_ipforward() {
  if [ "$OS" = FreeBSD ]; then sysctl -n net.inet.ip.forwarding 2>/dev/null
  else sysctl -n net.ipv4.ip_forward 2>/dev/null; fi
}

get_carrier_text() {  # <iface>: wg/awg allowed-ips (a prefix broader than /32 => carries transit, not just its own peer)
  # `show all` + filter here, NOT `show <iface>`. The sudoers grant is literal
  # (`wg show all allowed-ips`) because the per-interface form needs a `*` wildcard, and sudo's
  # `*` spans whitespace — that rule also permitted `wg show all dump allowed-ips`, which leaks
  # the interface private key. Asking for `all` keeps the grant wildcard-free. `show all`
  # prepends <iface> and <pubkey> columns; strip both so the parser sees the same token stream
  # the per-interface form produced.
  for b in wg awg; do                                 # don't guess the binary by name; try wg then awg
    command -v "$b" >/dev/null 2>&1 || continue
    out=$(priv "$b" show all allowed-ips | awk -v i="$1" '$1==i { $1=""; $2=""; print }')
    [ -n "$out" ] && { printf '%s\n' "$out"; return; }
  done
}

get_clamp() {  # <iface>
  if [ "$OS" = FreeBSD ]; then priv pfctl -sr | parse_clamp_freebsd "$1"
  else { priv iptables-save; priv nft list ruleset; } | parse_clamp_linux "$1"; fi
}

get_fwd() {  # <iface>: forwarding enabled AND the iface carries transit
  [ "$(get_ipforward)" = 1 ] || { echo 0; return; }
  get_carrier_text "$1" | parse_has_routed_prefix
}

discover() {
  sep=""
  printf '{"data":['
  for ifc in $(list_ifaces); do
    printf '%s{"{#VPN_IFACE}":"%s"}' "$sep" "$ifc"; sep=","
  done
  printf ']}\n'
}

# ===================== dispatch (set VPN_POSTURE_LIB=1 to source parsers for unit tests) =====================
if [ "${VPN_POSTURE_LIB:-0}" != 1 ]; then
  cmd=${1:-discover}
  case "$cmd" in
    discover) discover ;;
    mtu)      get_mtu   "${2:?usage: vpn_posture.sh mtu <iface>}" ;;
    fwd)      get_fwd   "${2:?usage: vpn_posture.sh fwd <iface>}" ;;
    clamp)    get_clamp "${2:?usage: vpn_posture.sh clamp <iface>}" ;;
    *) echo "usage: vpn_posture.sh {discover|mtu|fwd|clamp} [iface]" >&2; exit 2 ;;
  esac
fi
