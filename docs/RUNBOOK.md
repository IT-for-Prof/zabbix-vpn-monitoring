# Runbook — VPN Tunnel MTU monitoring (Zabbix template 14009)

Probe value (`vpn.pmtu` / `wg.pmtu`): **-2** offline (data-only) · **-1** live but no ICMP reply (data-only) · **0** healthy · **>0** MTU black-hole gap in bytes — **the only thing that pages**.

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
No `wg.count` for 30m → agent / scripts / active-checks broken (NOT a tunnel issue).
`systemctl status zabbix-agent2`; confirm `ServerActive=`; `zabbix_agent2 -t wg.count`; check `/etc/zabbix/scripts/`.

### `probe broken on <host>` — HIGH, pages
`wg.probe.ok=0` → `ping` lost `cap_net_raw`, so it can't set DF (every peer would falsely read unreachable).
`setcap cap_net_raw+ep "$(command -v ping)"` or re-run `installers/install.sh`.

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
- The probe is **bisection-bounded** (≤~30s at any MTU); the agent **`Timeout` must be ≥30** (`install.sh` sets it).
- **`tcp_mtu_probing=1`** (set fleet-wide) lets TCP self-heal through ICMP black holes (PLPMTUD) — complements the probe.
- The active ICMP-DF probe is the **only** endpoint detector for a *silent* black hole; passive counters and socket-TCP are blind (`tools/mtu_detector_matrix.sh` proves this).
- **Roll back a bad deploy:** `cp /etc/zabbix/scripts/.backup-<ts>/*.sh /etc/zabbix/scripts/ && systemctl reload zabbix-agent2`.
- **Audit a host's MTU posture:** `ssh <host> 'bash -s' < tools/vpn_mtu_audit.sh`.
- **Sudo / host-security posture:** the agent runs a few **read-only NOPASSWD** commands as root (`wg show <if> {allowed-ips,latest-handshakes}`, `iptables-save`/`nft list ruleset`, `zerotier-cli -j listnetworks`, `sacli VPNStatus`) — installed by `install.sh` into `/etc/sudoers.d/zabbix-*`. By design the collectors **only ever `sudo -n` a command that exists and is granted** — interface *enumeration* (`wg show interfaces`) is unprivileged and never sudo'd, and ungranted tools (`cat`/`socat`/absent binaries) are never sudo'd. So a **"command not allowed" / "a password is required" from the `zabbix` user is a real signal**, not normal noise: it means a sudoers rule is missing or a host is running an *older* collector — re-run `installers/install.sh` to refresh both scripts and sudoers. Probe sudo volume is throttled by `{$VPN.PROBE.INTERVAL}` (default 10m). If your security tooling alerts on service-account sudo, whitelist these specific NOPASSWD reads.
