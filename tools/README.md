# tools/ — diagnostics from the WireGuard MTU investigation (2026-05-20)

Run any of these against a node over SSH: `ssh <host> 'bash -s' < tools/<script>.sh`
(the eBPF/sim ones need root on the target). **Read-only unless noted.**

| Script | Purpose | Changes host? |
|---|---|---|
| `wg_diag.sh` | Full read-only sweep: iface MTUs, `wg` handshake ages + tx_errors, routing, sysctls, conntrack, passive black-hole counters, auto-targeted PMTU sweep. | No |
| `wg_probe.sh` / `wg_probe_auto.sh` | PMTU tool comparison — native `ping -M do` vs `fping -M` vs `nping`, TCP probe, `tracepath`, `mtr`. `_auto` derives targets from `wg`. | No |
| `probe_privilege_test.sh` | Proves the probe runs as the `zabbix` user (cap_net_raw, DF honored) and that `wg show` needs sudo. | No |
| `wg_mgmt_discovery.sh` | How is a wg iface brought up? (wg-quick unit / netdev / scripts / cron / docker). | No |
| `wg_ebpf_trace.bt` | bpftrace: `__icmp_send` (frag-needed type/code), `icmp6_send`, `kfree_skb` drop reasons, `tcp_retransmit_skb`. Run: `bpftrace wg_ebpf_trace.bt`. | No (observes) |
| `mtu_asym_experiment.sh` | **Ground-truth rig for the posture check:** netns SRV→pf-like-router→VPS with an *asymmetric* WG MTU + forwarded TCP, ± MSS clamp, ± PTB filtering. Shows the one-ended ICMP probe reads healthy while large forwarded TCP black-holes, and that config-compare/reverse-probe catch it. | **Isolated netns** |
| `mtu_down_behavior.sh` | **Proves no connection-driven noise:** runs the detectors across tunnel-up / peer-down / iface-admin-down / iface-removed; a dead channel reads `-1`/nodata, never a false `>0` or MTU mismatch. | **Isolated netns** |
| `wg_mtu_blackhole_sim.sh` | **Faithful, isolated** repro: netns A→router→B, raise wg MTU over a fragment-dropping path → real silent black hole; runs every detector. Self-cleans (netns/veth/iptables). | **Creates+destroys isolated netns** (no prod impact) |
| `wg_mtu_frag_sim.sh` | Earlier iteration showing plain WG/UDP *fragments* (soft mode) rather than black-holing. | Isolated netns |
| `mtu_detector_matrix.sh` | **Detector face-off (2026-05-21):** induces a known netns black hole, then runs *every* candidate at healthy vs black-hole MTU — production ICMP-DF probe, passive `IP_MTU`/`ip route get`, socket TCP-MTU, frag/drop counters, eBPF. Proves which detect and which are blind. | **Isolated netns** |
| `vps_detector_compare.sh` | Real-tunnel detector comparison. Args: `iface,target` pairs. Runs prod probe + ICMP-DF + `IP_MTU` + TCP port-scan/big-send + tracepath + fping against live peers. | No |
| `vpn_mtu_audit.sh` | Per-host MTU posture audit: `tcp_mtu_probing`, MSS clamping, `ping` cap_net_raw, agent `Timeout`, deployed probe version, tunnel iface MTUs. The mitigations the probe detects but doesn't enforce. | No |
| `zbx_speed_override.sh` | **Runs locally, not over SSH.** Re-applies the LLD override that stops the stock Linux templates' `Interface {#IFNAME}: Speed` item from being discovered on virtual ifaces (wg/zt/tun/tap/vmbr/fw*) — kills the fleet-wide "speed is not supported" agent-log spam while keeping traffic/error items. Idempotent; re-run after any vendor-template re-import. Reads URL/token from `/opt/zabbix-mcp/config.toml`. | **Changes Zabbix server config** |

These are diagnostic/validation aids. The production probe lives in `lib/vpn_pmtu.sh` (+ `lib/gate_<tech>.sh`); `lib/wg_pmtu.sh` is the WireGuard compat shim.

**Empirical verdict (2026-05-21, see `mtu_detector_matrix.sh`):** against a *silent* black hole the active ICMP-DF probe is the **only** endpoint-runnable detector that catches it. Passive `IP_MTU`/`ip route get`/counters are **blind** (no PTB to learn from); a socket TCP probe is **blind** (MSS auto-clamps to the peer); eBPF works only on the node doing the dropping. Fully ICMP-dark peers (no ICMP *and* no open TCP) are unmonitorable from one end — `-1` data-only is correct.
