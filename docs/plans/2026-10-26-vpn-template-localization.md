---
title: English and Russian VPN monitoring templates
type: feat
product_contract_source: ce-plan-bootstrap
---

# English and Russian VPN monitoring templates

Publish two Zabbix 7.0 templates with identical monitoring behavior and English or Russian operator text. Both may exist on one server; each host uses one language. Existing English installations retain their template identity and file path.

## Agreed scope

- Keep `templates/vpn-tunnel-mtu.yaml` as the English source of monitoring logic.
- Add the importable `templates/vpn-tunnel-mtu.ru.yaml`, generated from the English source and a Russian translation catalog.
- Preserve the five HIGH-to-AVERAGE changes already made in this session.
- Translate template, item, discovery and trigger names, descriptions, operational data, macro descriptions, value-map names and mapped labels. Preserve attribution, code, commands, URLs and macro placeholders within prose.
- Keep collectors, UserParameters, item keys, tags, macro identifiers and values, thresholds, intervals, trigger status and dependencies functionally identical.
- Do not deploy, commit, push, migrate existing hosts or add other languages in this change.

## Implementation

1. Add `templates/localization/ru.yaml` with exact English-to-Russian text mappings and a persistent English-to-Russian UUID mapping. Generate Russian UUIDv4 values once; never regenerate them on rebuild. Reuse the existing template-group name and UUID. The current export has 31 template-owned UUIDs and one shared group UUID.
2. Add a small Python builder at `templates/localization/build_ru.py`. Use PyYAML, already used by the repository's tests. Keep the current English file untouched except for the approved severity changes. Set Russian technical name to `VPN Tunnel MTU by Zabbix agent RU`; use a Russian visible name.
3. Translate only known display fields in the template subtree, excluding vendor identity. Rewrite template paths in trigger/dependency expressions and translate dependency and value-map reference names consistently. Preserve macro placeholders exactly. Reject missing translations and UUID mappings before replacing the generated output. Save YAML as UTF-8 with deterministic serialization.
4. Add focused tests for shared monitoring behavior, distinct stable UUIDv4 identities, resolved dependencies and value-map references, placeholder preservation, missing catalog entries and reproducible output. Run the existing OpenVPN template contract against both YAML files.
5. Update README with language selection, generation prerequisites/command, and checks. Explain that matching item keys prevent linking both variants to one host. Document that switching existing hosts is a separate migration, and Actions matching event names require review after translation.

## Verification and requested review order

- Review this plan through ponytail and ce-doc-review before implementation; make authorized corrections needed to deliver the agreed scope.
- After implementation, apply ce-noslop and an anti-slop review to new or changed English and Russian prose. Reviewers report findings; the implementation owner applies accepted edits and regenerates RU.
- Then run ce-simplify-code, ponytail and ce-code-review on the final change. Correct actionable findings and rerun affected checks.
- Parse both exports, run localization and existing collector tests, and run `git diff --check`. No live Zabbix import is claimed without a test instance.

## Acceptance

- Importable EN and RU YAML files are present, and rebuilding RU produces the checked-in artifact.
- Only translated display text, Russian object identities and Russian template references differ after normalization.
- Every current HIGH-to-AVERAGE change appears in both languages.
- No monitoring agent installation needs a generator or translation dependency.
- Review outcomes and any unverified live-import behavior are reported before deployment.
