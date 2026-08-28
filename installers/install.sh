#!/usr/bin/env bash
# Install VPN tunnel MTU monitoring (WireGuard/AmneziaWG, ZeroTier, OpenVPN incl Access Server) on a
# node. Idempotent. Installs every collector; each self-gates where its tech is absent. No tunnel changes.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCR=/etc/zabbix/scripts; CONF=/etc/zabbix/zabbix_agent2.d/wireguard.conf
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
command -v python3 >/dev/null 2>&1 \
  || echo "WARN: python3 missing — ZeroTier discovery/liveness and OpenVPN liveness/Access Server discovery are unavailable."
command -v socat >/dev/null 2>&1 \
  || echo "note: socat missing — OpenVPN management-socket status is unavailable (status files and sacli still work)."
install -d "$SCR"
# Back up the prior script SET before overwriting, so a broken re-install rolls back fast.
# (The shim resolves siblings by dirname; a half-updated set breaks every wg.pmtu item.)
if ls "$SCR"/vpn_pmtu.sh >/dev/null 2>&1; then
  BK="$SCR/.backup-$(date +%Y%m%d-%H%M%S)"; install -d "$BK"
  cp -p "$SCR"/wg_pmtu.sh "$SCR"/vpn_pmtu.sh "$SCR"/gate_wireguard.sh "$SCR"/gate_zerotier.sh "$SCR"/gate_openvpn.sh "$SCR"/wg_discovery.sh "$SCR"/zerotier_discovery.sh "$SCR"/openvpn_discovery.sh "$SCR"/vpn_posture.sh "$BK"/ 2>/dev/null || true
  echo "backup: prior scripts -> $BK   (rollback: cp $BK/*.sh $SCR/ && systemctl reload zabbix-agent2)"
fi
VER=$(cd "$REPO" && git rev-parse --short HEAD 2>/dev/null || echo unknown)
install -m 0755 "$REPO/lib/wg_pmtu.sh" "$SCR/wg_pmtu.sh"            # compat shim -> vpn_pmtu.sh
install -m 0755 "$REPO/lib/vpn_pmtu.sh" "$SCR/vpn_pmtu.sh"          # shared probe + gate dispatch
install -m 0755 "$REPO/lib/gate_wireguard.sh" "$SCR/gate_wireguard.sh"  # wg/awg liveness gate
install -m 0755 "$REPO/collectors/wireguard/wg_discovery.sh" "$SCR/wg_discovery.sh"
install -m 0644 "$REPO/collectors/wireguard/wireguard.conf" "$CONF"
# Posture collector (config-plane MTU/clamp lint; WireGuard only, self-gates empty elsewhere).
install -m 0755 "$REPO/collectors/posture/vpn_posture.sh" "$SCR/vpn_posture.sh"
install -m 0644 "$REPO/collectors/posture/posture.conf" /etc/zabbix/zabbix_agent2.d/posture.conf
# ZeroTier collector (always installed; self-gates to empty discovery on non-ZT hosts so the
# template's zerotier.discovery LLD stays SUPPORTED everywhere instead of erroring).
install -m 0755 "$REPO/lib/gate_zerotier.sh" "$SCR/gate_zerotier.sh"
install -m 0755 "$REPO/collectors/zerotier/zerotier_discovery.sh" "$SCR/zerotier_discovery.sh"
install -m 0644 "$REPO/collectors/zerotier/zerotier.conf" /etc/zabbix/zabbix_agent2.d/zerotier.conf
# OpenVPN collector (community + Access Server; self-gates empty where no OpenVPN/sacli).
install -m 0755 "$REPO/lib/gate_openvpn.sh" "$SCR/gate_openvpn.sh"
install -m 0755 "$REPO/collectors/openvpn/openvpn_discovery.sh" "$SCR/openvpn_discovery.sh"
install -m 0644 "$REPO/collectors/openvpn/openvpn.conf" /etc/zabbix/zabbix_agent2.d/openvpn.conf
printf '%s\n' "$VER" > "$SCR/.vpn_pmtu.version"                     # deploy stamp: `cat` it to see what's live
echo "deployed probe version: $VER"
# 1) ping must carry cap_net_raw (probe is unprivileged) — validate, remediate if missing
PING=$(command -v ping)
if ! getcap "$PING" 2>/dev/null | grep -q cap_net_raw; then
  echo "ping lacks cap_net_raw -> setting it"; setcap cap_net_raw+ep "$PING"
  getcap "$PING" | grep -q cap_net_raw || { echo "FATAL: cannot grant cap_net_raw to ping"; exit 1; }
fi
# 2) agent2 must run active checks
grep -Eq '^\s*ServerActive=' /etc/zabbix/zabbix_agent2.conf /etc/zabbix/zabbix_agent2.d/*.conf 2>/dev/null \
  || echo "WARN: ServerActive not set — active items will not collect; configure it."
# 2b) the probe is bisection-bounded to ~30s on a deep black hole; agent2's default Timeout=3s
#     would kill the item mid-probe so the >0 gap pager never fires. Ensure Timeout>=30 via a
#     drop-in (agent2 max is 30s; bisection fits). Respects a higher operator-set value.
TO_DROPIN=/etc/zabbix/zabbix_agent2.d/zz-vpn-probe-timeout.conf; NEED_RESTART=
cur=$(grep -hoE '^[[:space:]]*Timeout=[0-9]+' /etc/zabbix/zabbix_agent2.conf /etc/zabbix/zabbix_agent2.d/*.conf 2>/dev/null | grep -oE '[0-9]+' | sort -rn | head -1) || true
if [ "${cur:-3}" -lt 30 ] 2>/dev/null; then
  { echo "# VPN MTU probe (vpn.pmtu) can run ~30s on a deep black hole (bisection-bounded);"
    echo "# agent2 default Timeout=3s kills it mid-probe so the >0 gap pager never fires."
    echo "Timeout=30"; } > "$TO_DROPIN"
  NEED_RESTART=1; echo "agent Timeout: wrote $TO_DROPIN (Timeout=30; was ${cur:-3}s)"
else
  echo "agent Timeout: already ${cur}s (>=30) — left as-is"
fi
# 3) self-hostname must resolve (avoids sudo/lookup stalls; harmless for P1, needed for P2)
hn=$(hostname); getent hosts "$hn" >/dev/null || { echo "127.0.1.1 $hn" >> /etc/hosts; echo "added $hn to /etc/hosts"; }
# Install a staged sudoers file: validate "$1.tmp" with visudo BEFORE it becomes live, so a
# malformed rule can never land in /etc/sudoers.d and lock the host out of sudo entirely.
commit_sudoers() {  # <final-path> <label-for-the-error-message>
  chmod 0440 "${1}.tmp"
  visudo -cf "${1}.tmp" >/dev/null || { echo "FATAL: invalid $2 sudoers"; rm -f "${1}.tmp"; exit 1; }
  mv "${1}.tmp" "$1"
}
# 4) handshake gate (Phase 2) reads handshake age via two KEY-FREE `wg show` subcommands
#    (CAP_NET_ADMIN). Grant the agent a least-privilege sudoers rule scoped to exactly those:
#    `wg show ... dump`/`private-key` are NOT granted, so the agent can never read tunnel keys
#    (`wg show <iface> dump` would print the interface private key in its first field).
#    FULLY LITERAL, no wildcard: an earlier `show * allowed-ips` form looked tighter than it
#    was, because sudo's `*` spans whitespace — it also matched
#    `wg show all dump allowed-ips`, smuggling the key-exposing subcommand in ahead of the
#    permitted one (verified with `sudo -l` on a live host: PERMITTED). Nothing but wg's own
#    "no 4th argument" check stopped it. gate_wireguard.sh therefore asks for `all` and filters
#    by interface itself, which lets this grant name both words outright.
# Only where wg/awg exists (an OpenVPN- or ZeroTier-only host has neither — that's fine).
if command -v wg >/dev/null 2>&1 || command -v awg >/dev/null 2>&1; then
  SUDOERS=/etc/sudoers.d/zabbix-wg
  : > "${SUDOERS}.tmp"
  for B in wg awg; do
    P=$(command -v "$B") || continue
    printf 'zabbix ALL=(root) NOPASSWD: %s show all allowed-ips\n' "$P"
    printf 'zabbix ALL=(root) NOPASSWD: %s show all latest-handshakes\n' "$P"
  done >> "${SUDOERS}.tmp"
  commit_sudoers "$SUDOERS" wg
  echo "sudoers: $SUDOERS installed for '{wg,awg} show all {allowed-ips,latest-handshakes}' (literal, no wildcard; dump/private-key denied)"
else
  echo "note: no wg/awg here — WireGuard collector idle (discovery self-gates empty)"
fi
# 4d) posture clamp read: iptables-save / nft list ruleset need root. Grant the agent a narrow,
#     read-only rule for exactly those. Absent it, clamp degrades to 0 (Information-only, no page).
#     (This installer is Linux-only; on FreeBSD/pfSense deploy vpn_posture.sh by hand and grant
#      the agent `pfctl -sr` — see docs/superpowers/specs/2026-06-05-vpn-mtu-posture-monitoring-design.md.)
PSUDO=/etc/sudoers.d/zabbix-posture
: > "${PSUDO}.tmp"
# The trailing '""' pins the grant to ZERO arguments. Without it sudoers permits ANY argument,
# and iptables-save takes `-M <path>` (execs that path as root when it loads a module) and
# `-f <path>` (writes as root) — i.e. a full root escalation from the zabbix account, not the
# read-only grant this block advertises. vpn_posture.sh calls it bare (`priv iptables-save`),
# so pinning changes nothing at runtime. nft below is already argument-pinned.
IPTS=$(command -v iptables-save 2>/dev/null) && printf 'zabbix ALL=(root) NOPASSWD: %s ""\n' "$IPTS" >> "${PSUDO}.tmp"
NFT=$(command -v nft 2>/dev/null) && printf 'zabbix ALL=(root) NOPASSWD: %s list ruleset\n' "$NFT" >> "${PSUDO}.tmp"
if [ -s "${PSUDO}.tmp" ]; then
  commit_sudoers "$PSUDO" posture
  echo "sudoers: $PSUDO installed for read-only 'iptables-save' / 'nft list ruleset' (clamp posture)"
  # Smoke-check the grant actually works for the agent user (matches the wg/zerotier/openvpn blocks).
  if { [ -n "${IPTS:-}" ] && sudo -u zabbix sudo -n "$IPTS" >/dev/null 2>&1; } \
     || { [ -n "${NFT:-}" ] && sudo -u zabbix sudo -n "$NFT" list ruleset >/dev/null 2>&1; }; then
    echo "verify: zabbix can read the firewall ruleset via sudo (clamp posture live)"
  else
    echo "WARN: zabbix cannot run iptables-save/nft via 'sudo -n' — clamp posture will read 0 (Information only)"
  fi
else
  rm -f "${PSUDO}.tmp"; echo "note: no iptables-save/nft here — clamp posture reports 0 (Information-only)"
fi
# 4b) ZeroTier liveness reads the network list; the authtoken is root-only, so grant the agent a
#     narrow read of exactly `zerotier-cli -j listnetworks` when zerotier-cli is present. On non-ZT
#     hosts no grant is needed — discovery self-gates to empty.
if ZT=$(command -v zerotier-cli 2>/dev/null); then
  ZTSUDO=/etc/sudoers.d/zabbix-zerotier
  printf 'zabbix ALL=(root) NOPASSWD: %s -j listnetworks\n' "$ZT" > "${ZTSUDO}.tmp"
  commit_sudoers "$ZTSUDO" zerotier
  if sudo -u zabbix sudo -n "$ZT" -j listnetworks >/dev/null 2>&1; then
    echo "sudoers: $ZTSUDO installed; zabbix can read 'zerotier-cli -j listnetworks' — OK (authtoken never read directly)"
  else
    echo "WARN: zabbix cannot 'sudo zerotier-cli -j listnetworks' — ZeroTier discovery/gate will fail-safe to empty"
  fi
fi
# 4c) OpenVPN Access Server liveness via `sacli VPNStatus` (root-only) — narrow read where present.
SA=/usr/local/openvpn_as/scripts/sacli; [ -x "$SA" ] || SA=$(command -v sacli 2>/dev/null) || SA=""
if [ -n "$SA" ]; then
  AVSUDO=/etc/sudoers.d/zabbix-openvpn-as
  printf 'zabbix ALL=(root) NOPASSWD: %s VPNStatus\n' "$SA" > "${AVSUDO}.tmp"
  commit_sudoers "$AVSUDO" openvpn-as
  if sudo -u zabbix sudo -n "$SA" VPNStatus >/dev/null 2>&1; then
    echo "sudoers: $AVSUDO installed; zabbix can read 'sacli VPNStatus' — OK (key/cert never read)"
  else
    echo "WARN: zabbix cannot 'sudo sacli VPNStatus' — OpenVPN-AS discovery/gate will fail-safe to empty"
  fi
fi
# Smoke test
echo "== smoke =="
# `|| true`: a non-zero `-t` (e.g. a NOTSUPPORTED key) must not abort under set -e before the reload below.
zabbix_agent2 -t wg.count || true
zabbix_agent2 -t 'wg.discovery[]' || true
zabbix_agent2 -t 'zerotier.discovery[]' || true   # SUPPORTED everywhere; {"data":[]} on non-ZT hosts, populated on ZT hosts
zabbix_agent2 -t 'openvpn.discovery[]' || true    # community + Access Server; empty where no OpenVPN
probe=$(zabbix_agent2 -t wg.probe.ok 2>&1 || true); echo "$probe"
echo "$probe" | grep -q '|1]' || echo "WARN: wg.probe.ok != 1 — ping likely lacks cap_net_raw; the probe-broken trigger will fire"
# P2 smoke (per present binary): the zabbix user must be able to read handshakes via sudo
# (bare `wg`/`awg` mirrors the runtime path), else the gate fail-safes to Phase-1 (offline
# peers read -1 instead of -2). And the key-exposing `dump` must be denied.
for B in wg awg; do
  command -v "$B" >/dev/null 2>&1 || continue
  if sudo -u zabbix sudo -n "$B" show all latest-handshakes >/dev/null 2>&1; then
    echo "handshake gate: zabbix can read '$B show ... latest-handshakes' — OK"
  else
    echo "WARN: zabbix cannot 'sudo $B show ... latest-handshakes' — probe fail-safes to Phase-1 (offline peers read -1, not -2)"
  fi
  # Assert `dump` is NOT granted by INSPECTING the policy (sudo -l), not by executing a denied
  # command — running `sudo -n wg show all dump` would log a failed-sudo and trip host security alerts.
  # Match any dump grant form (`* dump`, `all dump`, ...); and only declare key-safe when the policy
  # was actually readable (it lists the expected reads) — an empty/unreadable -l must NOT read as safe.
  pol=$(sudo -n -l -U zabbix 2>/dev/null)
  if printf '%s\n' "$pol" | grep -qE "/$B( show)? .*dump"; then
    echo "WARN: sudoers permits '$B ... dump' (key exposure) — tighten the rule"
  elif printf '%s\n' "$pol" | grep -qE "/$B show .*(allowed-ips|latest-handshakes)"; then
    echo "least-privilege: '$B show ... dump' not granted (key-safe)"
  else
    echo "note: could not read zabbix sudo policy — manually verify '$B ... dump' is not granted"
  fi
done
if [ -n "$NEED_RESTART" ]; then systemctl restart zabbix-agent2   # Timeout change needs a restart
else systemctl reload zabbix-agent2 2>/dev/null || systemctl restart zabbix-agent2; fi
echo "INSTALL OK"
