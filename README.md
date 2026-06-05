# zabbix-vpn-monitoring

Zabbix monitoring for VPN / overlay tunnels — detection of **silent MTU/PMTU black holes** and
**dead peers** on VPN-exit routers, before users report them.

One **technology-agnostic ICMP-DF MTU probe** (shared `lib/`) plus **per-technology liveness
collectors** (`collectors/`), across **WireGuard/AmneziaWG, ZeroTier, and OpenVPN** (community +
Access Server) — a single Zabbix template (`templates/wireguard-vpn-exit.yaml`), one self-gating LLD
rule per tech (absent tech ⇒ no items). A separate **config-plane MTU-posture** check catches the
misconfiguration the active probe is structurally blind to, and runs on Linux *and* FreeBSD/pfSense.

Proxies (Outline/Shadowsocks, Xray) are a *different* class (no L3 tunnel/handshake) and out of scope.

## How detection works

- **MTU probe (the only per-tunnel pager):** ICMP echo with Don't-Fragment set (`ping -M do`),
  bisection PMTU search, aimed at the **peer's tunnel IP** (never the underlay endpoint — those often
  block ICMP). Returns `-2` offline / `-1` live-but-no-ICMP / `0` healthy / `>0` =
  `configured_MTU − max_deliverable` (black-hole gap, bytes). `>0` only occurs on a live tunnel, so it
  never fires for an offline peer. The agent's `Timeout` must be **≥30s** (a deep black hole can run
  ~30s; `install.sh` warns if it's lower).
- **Per-tech liveness gate (data-only):** before probing, `gate_<tech>.sh` decides if the tunnel is up,
  so an offline/dark peer reads `-2`/`-1` instead of a false black hole — WireGuard/AmneziaWG via the
  **key-free** `wg show … {allowed-ips,latest-handshakes}` (narrow `sudo`; `dump`/private-key never
  granted), ZeroTier via `zerotier-cli -j listnetworks`, OpenVPN via status file / mgmt socket /
  `sacli VPNStatus`. `-2`/`-1` are the **normal** state of a roaming or firewalled peer, so they never
  page; the "probe target unreachable" trigger ships **disabled**.
- **MTU posture (config-plane, no probing):** the active probe is blind to a *far-end-larger* MTU
  asymmetry (the small end can't emit the dangerous size) and to forwarded/unclamped-TCP black holes.
  `collectors/posture/vpn_posture.sh` (WireGuard/AmneziaWG; POSIX sh, Linux + FreeBSD/pfSense) reads
  each tunnel's `mtu` / `fwd` / `clamp`; the template pages **Warning** on `mtu > {$VPN.MTU.MAX}` (default
  1420) and notes **Information** on forward-without-clamp (suppressed under the Warning). It's
  connection-state-independent — a lost handshake or link flap never makes it flap.

## Why the active probe is the right detector

Against a *silent* black hole the active ICMP-DF probe is the only endpoint-runnable detector that
catches it: passive `IP_MTU` / `ip route get` / counters are blind (no PTB to learn from), a socket TCP
probe is blind (MSS auto-clamps to the peer), and eBPF only sees drops on the node doing the dropping.
Fully ICMP-dark peers (no ICMP *and* no open TCP) are unmonitorable from one end — `-1` data-only is the
correct verdict. The netns rigs in `tools/` reproduce these cases as ground truth.

## Install

`installers/install.sh` is idempotent (backs up prior scripts, ensures agent `Timeout≥30`, installs only
collectors whose tech is present, sets the narrow read-only sudoers). Then link the host to the template.
FreeBSD/pfSense is a separate manual step — see [`docs/DEPLOY-POSTURE.md`](docs/DEPLOY-POSTURE.md).

Mitigations the probe **detects but does not enforce** (keep them in config management, not the template):
`net.ipv4.tcp_mtu_probing=1` (PLPMTUD); **MSS clamping** on forwarding gateways
(`TCPMSS --clamp-mss-to-pmtu`); don't block ICMP type-3/code-4; tunnel MTU = path − overhead.

## Layout

```
lib/           shared ICMP-DF probe (vpn_pmtu.sh) + per-tech gate_<tech>.sh (wg_pmtu.sh = compat shim)
collectors/    per-technology discovery + agent2 conf (wireguard/ zerotier/ openvpn/ posture/)
templates/     Zabbix template YAML ("VPN Tunnel MTU by Zabbix agent")
installers/    node installer/uninstaller (cap_net_raw, ServerActive, Timeout>=30, narrow sudoers)
tests/         fixture + netns contract tests (no prod impact)
tools/         read-only diagnostics + netns black-hole/asymmetry ground-truth rigs (see tools/README.md)
docs/          responder runbook + posture deploy guide
```

## License

MIT — see [`LICENSE`](LICENSE).
