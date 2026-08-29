# Runbook — VPN Tunnel MTU monitoring (Zabbix template 14009)

Probe value (`vpn.pmtu` / `wg.pmtu`): **-2** offline (data-only) · **-1** live but no ICMP reply (data-only) · **0** healthy · **>0** MTU black-hole gap in bytes — **the only tunnel-state value that pages**. Missing probe data is reported separately as monitoring health, never as an MTU or reachability fault.

## Alerts → response

### `… MTU black hole (gap N B)` — HIGH, pages
A live tunnel delivers small packets but drops at-MTU packets (silent black hole). `N` = configured iface MTU − largest deliverable.
1. The trigger name has `{#VPN_IFACE}` + `{#VPN_TARGET}`. On the host, reproduce + bisect:
   `m=$(cat /sys/class/net/<iface>/mtu); ping -M do -s $((m-28)) -c2 <target>` then step the size down.
2. Usual causes / fixes:
   - **Tunnel MTU too high for the underlay** → set iface MTU to (path − overhead): WireGuard ≈ 1420 over a 1500 path, ZeroTier ≈ 2800, OpenVPN per `tun-mtu`/`mssfix`.
   - **A transit hop drops fragments or filters ICMP "fragmentation needed"** → fix the path/firewall (allow ICMP **type 3 / code 4**).
   - Confirm **MSS clamping** on the gateway: `iptables-save | grep clamp-mss-to-pmtu` (protects forwarded TCP).
3. Verify: the item returns to `0`.

### `monitoring blind on <host>` — HIGH, pages
No `wg.count` for 30m **while the agent is still delivering** → this template's scripts / UserParameters are broken (NOT a tunnel issue, and not a dead agent — that case is suppressed, see below).
`zabbix_agent2 -t wg.count`; check `/etc/zabbix/scripts/`; re-run `installers/install.sh`.

### `host agent silent on <host>` — NOT CLASSIFIED, never paged
The whole active-check channel is quiet: the built-in `agent.variant` heartbeat produced nothing for `{$VPN.AGENT.WINDOW}` (default 15m). Its only job is to open **before** the 30m watchdog and suppress it, so a dead agent pages once — from the host's own agent-availability trigger — instead of twice. Zabbix dependencies never suppress an already-open event, hence the 15m/30m split; raise both together or not at all.
If this is open and *nothing else* alerted, the host has no agent-availability owner: link the stock **Zabbix agent active** template to it (see [`DEPLOY-POSTURE.md`](DEPLOY-POSTURE.md)). Otherwise respond to the agent alert: `systemctl status zabbix-agent2`, confirm `ServerActive=`, check the proxy.
Two cases where you still get both alerts, both deliberate and both self-healing: an event already open when the anchor opens stays open (Zabbix never suppresses retroactively), and a host that has never delivered a single `agent.variant` value leaves the anchor UNKNOWN rather than PROBLEM — it starts suppressing after the first collected value. Failing this way round is the point: a lost anchor costs one duplicate page, never silence.

### `probe broken on <host>` — HIGH, pages
`wg.probe.ok=0`, or no canary value while `wg.count` remains fresh → a shared PMTU runner/UserParameter is missing or invalid, or `ping` lost `cap_net_raw` and cannot set DF.
`setcap cap_net_raw+ep "$(command -v ping)"` or re-run `installers/install.sh`.

### `… PMTU data missing` — WARNING
This one target has produced no `wg.pmtu`/`vpn.pmtu` value for `{$VPN.PROBE.NODATA}` (default 45m), while shared Agent2 delivery and the common probe canary are healthy. Inline health checks close this event if either shared path fails later; Zabbix trigger dependencies alone would freeze an already-open child. Offline and ICMP-dark targets continue to return `-2`/`-1`, so neither state opens this event. Check the item state/error and run its exact key with `zabbix_agent2 -t`; re-run `installers/install.sh` if the UserParameter or script is missing. A vanished LLD target is disabled immediately and does not open this event.

### `… probe target unreachable` (=-1) — DISABLED, data-only
Not paged. A live tunnel whose target stops answering ICMP. Common for **OpenVPN-AS clients** (host firewall) and **pfSense peers** lacking an ICMP pass rule on the tunnel iface (`pass in quick on tun_wgN inet proto icmp`). MTU is unmeasurable to a dark peer — expected, not a fault.

### `… MTU too high (N > {$VPN.MTU.MAX})` — WARNING, pages (posture, config-plane)
A WireGuard iface MTU exceeds the safe ceiling (default 1420) → it will silently black-hole large/forwarded traffic. This is a **config lint** (reads the iface MTU, no probing), so it does not flap and is unaffected by connection state.
1. On the host: `cat /sys/class/net/<iface>/mtu` (Linux) / `ifconfig <iface>` (FreeBSD).
2. Fix: lower the iface MTU to (path − overhead), ~1420 for WG over a 1500 internet path; add an MSS clamp. On pfSense: lower `tun_wgN` MTU + a `scrub … max-mss` rule. Override `{$VPN.MTU.MAX}` per host if a tunnel legitimately needs a different ceiling (e.g. 1340).
3. Verify: the item returns ≤ ceiling; the problem clears.

### `… forwards transit without MSS clamp` — INFORMATION, not paged (posture)
Defense-in-depth note: a gateway forwards TCP through this tunnel with no MSS clamp. Harmless while the MTU is correct (PMTUD covers it); becomes a silent black hole if the MTU is ever too high or PMTUD breaks (asymmetric routing). **Suppressed** when the MTU-too-high warning fires on the same iface. Add a clamp: Linux `iptables -t mangle -A FORWARD -o <iface> -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu`; pfSense `scrub … max-mss`.

**Posture on FreeBSD/pfSense:** collector at `/root/scripts/vpn_posture.sh`; UserParameters live in the **Zabbix Agent LTS GUI → User Parameters** (a direct conf edit is wiped on GUI save). The active-probe items (`wg.probe.ok`, `wg.discovery`, `openvpn.discovery`, `zerotier.discovery`) are disabled per-host there (Linux-only). See [`DEPLOY-POSTURE.md`](DEPLOY-POSTURE.md).

## Good to know
- **Alerts need agreement across `{$VPN.HYST.WINDOW}` (default 25m), not just one bad read.** Every sample in that window must agree before a trigger pages, so expect up to ~25m from "went bad" to "paged" (posture and black-hole alike; the probe-capability canary too). Tunable per host — but if you raise `{$VPN.PROBE.INTERVAL}` somewhere, raise `{$VPN.HYST.WINDOW}` on the same host to ≥2x it, or the window holds a single sample and the hysteresis silently stops working. It is time-based rather than count-based (`#N`) precisely because proxy-group / dual-`ServerActive` hosts write two samples per poll, which made `#2` cover one poll instead of two.
- **Per-target freshness uses `{$VPN.PROBE.NODATA}` (default 45m).** Keep it longer than `{$VPN.WATCHDOG.WINDOW}+{$VPN.PROBE.INTERVAL}` so a host-wide collection loss produces only the shared event and never a fan-out of per-target ones — the monitoring-blind watchdog when the agent still delivers, the host's own agent-availability alert when it does not. The MTU-gap expressions stop trusting stale history after `{$VPN.HYST.WINDOW}`; this closes an old gap before the missing-data event can open.
- The probe is **bisection-bounded** (≤~30s at any MTU); the agent **`Timeout` must be ≥30** (`install.sh` sets it).
- **`tcp_mtu_probing=1`** (set fleet-wide) lets TCP self-heal through ICMP black holes (PLPMTUD) — complements the probe.
- The active ICMP-DF probe is the **only** endpoint detector for a *silent* black hole; passive counters and socket-TCP are blind.
- **Roll back a bad deploy:** `cp /etc/zabbix/scripts/.backup-<ts>/*.sh /etc/zabbix/scripts/ && systemctl reload zabbix-agent2`.
- **Sudo / host-security posture:** the agent runs a few **read-only NOPASSWD** commands as root (`wg show all {allowed-ips,latest-handshakes}`, `iptables-save`/`nft list ruleset`, `zerotier-cli -j listnetworks`, `sacli VPNStatus`) — installed by `install.sh` into `/etc/sudoers.d/zabbix-*`. The wg rule names `all` literally on purpose: a per-interface rule needs a `*`, and sudo matches `*` with fnmatch, which spans whitespace — `wg show * allowed-ips` also permits `wg show all dump allowed-ips`, and `dump` exposes the interface private key. The collectors filter by interface themselves. Do not "tighten" it back to a wildcard. By design the collectors **only ever `sudo -n` a command that exists and is granted** — interface *enumeration* (`wg show interfaces`) is unprivileged and never sudo'd, and ungranted tools (`cat`/`socat`/absent binaries) are never sudo'd. So a **"command not allowed" / "a password is required" from the `zabbix` user is a real signal**, not normal noise: it means a sudoers rule is missing or a host is running an *older* collector — re-run `installers/install.sh` to refresh both scripts and sudoers. Probe sudo volume is throttled by `{$VPN.PROBE.INTERVAL}` (default 10m). If your security tooling alerts on service-account sudo, whitelist these specific NOPASSWD reads.
