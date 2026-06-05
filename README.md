# zabbix-vpn-monitoring

Zabbix monitoring for VPN / overlay tunnels — detection of **silent MTU/PMTU black holes** and
**dead peers** on VPN-exit routers, before users report them.

Umbrella repo: one **technology-agnostic ICMP-DF MTU probe** (shared `lib/`) plus **per-technology
liveness collectors** (`collectors/`). **Live across WireGuard/AmneziaWG, ZeroTier, and OpenVPN
(community + Access Server)** — one template (id 14009), one self-gating LLD rule per tech (absent
tech ⇒ no items). Proxies (Outline/Shadowsocks, Xray) are a *different* class (no L3 tunnel/handshake)
→ a separate proxy-health template, not this MTU family.

**Scope / ops:** the probe measures **IPv4** inner targets (DF-set ICMP echo, bisection PMTU search).
IPv6-only targets are **not yet probed** — discovery should drop them so a healthy v6 tunnel doesn't
read a misleading `-1`; `ping -6` support is backlog. The Zabbix agent's `Timeout` must be **≥30s** (a
deep black hole can run ~30s; `install.sh` warns if it's lower).

## Status

- **Live (2026-06-05):** template 14009 on **11 hosts** — 8 Linux WireGuard + OpenVPN-AS (ET-VPN) +
  both pfSense firewalls (**IFP-VM-PF03**, **ET-VM-PF01**). All probe items healthy or data-only, no false
  alerts. **Pagers:** MTU black hole + monitoring-blind + probe-broken. Liveness (`-1`/`-2`) is **data-only**.
- **MTU posture check (2026-06-05):** a config-plane lint (no probing) that catches the misconfiguration the
  active probe is blind to — a WireGuard iface with **MTU too high** (Warning) or that **forwards transit without
  an MSS clamp** (Information). Runs on Linux *and* FreeBSD/pfSense. Deploy guide: [`docs/DEPLOY-POSTURE.md`](docs/DEPLOY-POSTURE.md);
  design: [`docs/superpowers/specs/2026-06-05-vpn-mtu-posture-monitoring-design.md`](docs/superpowers/specs/2026-06-05-vpn-mtu-posture-monitoring-design.md).
  Still uncovered (no SSH): GP-VPS01/02/03, IFP-VPS16.
- **Continuation plan:** [`docs/2026-05-21-multi-vpn-generalization-plan.md`](docs/2026-05-21-multi-vpn-generalization-plan.md) — Tasks 0/A/B/C done; Task D (autoreg auto-linking) open.
- **Responder runbook:** [`docs/RUNBOOK.md`](docs/RUNBOOK.md)
- **Design rationale:** [`docs/2026-05-20-wireguard-mtu-exit-monitoring-design.md`](docs/2026-05-20-wireguard-mtu-exit-monitoring-design.md) — the original WireGuard design; the probe/trigger model + empirical findings still apply across all techs.

## Operations

Mitigations the probe **detects but does not enforce** (keep them in config management, not the template):
- `net.ipv4.tcp_mtu_probing=1` — PLPMTUD, so TCP self-heals through ICMP black holes.
- **MSS clamping** on gateways that forward TCP (`TCPMSS --clamp-mss-to-pmtu`).
- **Don't block ICMP type-3/code-4** (fragmentation-needed); set tunnel MTU = path − overhead.

`installers/install.sh` is idempotent (backs up prior scripts, ensures agent `Timeout≥30`, installs only
collectors whose tech is present). Audit a host's posture: `ssh <host> 'bash -s' < tools/vpn_mtu_audit.sh`.

## How detection works

- **MTU probe (the only per-tunnel pager):** ICMP echo with Don't-Fragment set (`ping -M do`), bisection
  PMTU search, aimed at the **peer's tunnel IP** (never the underlay endpoint — those often block ICMP).
  Returns `-2` offline / `-1` live-but-no-ICMP / `0` healthy / `>0` = `configured_MTU − max_deliverable`
  (black-hole gap, bytes). `>0` only occurs on a live tunnel, so it never fires for an offline peer.
- **Per-tech liveness gate (data-only):** before probing, a `gate_<tech>.sh` decides if the tunnel is up,
  so an offline/dark peer reads `-2`/`-1` instead of a false black hole — WireGuard/AmneziaWG via the
  **key-free** `wg show … {allowed-ips,latest-handshakes}` (narrow `sudo`; `dump`/private-key never
  granted), ZeroTier via `zerotier-cli -j listnetworks` (network OK), OpenVPN via the status file / mgmt
  socket / `sacli VPNStatus`. `-2` (offline) and `-1` (live but ICMP-dark) are the **normal** state of a
  roaming or firewalled peer, so they never page; the "probe target unreachable" trigger ships **disabled**.
  `VPN_LIVE_FRESH` (default 180s; legacy `WG_HS_FRESH` honored) sets the "tunnel up" window for aged techs
  (ZeroTier and OpenVPN servers are binary: present in the live routing table ⇒ live).
- **MTU posture (config-plane, no probing):** the active probe is structurally blind to a *far-end-larger* MTU
  asymmetry (the small end can't emit the dangerous size) and to forwarded/unclamped-TCP black holes. The posture
  collector (`collectors/posture/vpn_posture.sh`, WireGuard/AmneziaWG only) reads each tunnel's `mtu` / `fwd` /
  `clamp` and the template pages **Warning** on `mtu > {$VPN.MTU.MAX}` (1420) and notes **Information** on
  forward-without-clamp (suppressed under the Warning). Connection-state-independent, so it never flaps.

## Layout

```
docs/          design rationale + RUNBOOK + the live continuation plan
lib/           shared ICMP-DF probe (vpn_pmtu.sh) + per-tech gate_<tech>.sh (wg_pmtu.sh = compat shim)
collectors/    per-technology discovery + agent2 conf (wireguard/ zerotier/ openvpn/)
templates/     Zabbix template YAML ("VPN Tunnel MTU by Zabbix agent", id 14009)
installers/    node installer/uninstaller (cap_net_raw, ServerActive, Timeout>=30, narrow sudoers)
tools/         read-only diagnostics + black-hole simulation + posture audit (see tools/README.md)
```

## Estate context

Runs on the VPN exit/relay routers monitored by the `mon.itforprof.com` Zabbix 7.0 deployment — **11 hosts**
linked to template 14009 (8 Linux WireGuard + OpenVPN-AS ×1 + 2 pfSense firewalls; some multi-tech). Agent2, **active**
items; the installer ensures `ServerActive`. The probe runs unprivileged via `cap_net_raw` on `ping`; only
the liveness reads need a narrow `sudo` (`wg show …`, `zerotier-cli -j listnetworks`, `sacli VPNStatus` —
all read-only and key-free).
