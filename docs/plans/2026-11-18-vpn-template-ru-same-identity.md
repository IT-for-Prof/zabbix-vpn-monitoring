---
title: Russian VPN template replaces the English one instead of living beside it
type: fix
supersedes: docs/plans/2026-10-26-vpn-template-localization.md (identity part only)
---

# Russian VPN template replaces the English one

## Why

`vpn-tunnel-mtu.ru.yaml` is a separate template: technical name `VPN Tunnel MTU by Zabbix agent RU`
and 31 own UUIDv4s from `localization/ru.yaml`. The other repos ship the opposite and newer model:
`zabbix-webservices`, `zabbix-victorialogs-delivery` (`8ad7c7a`, 2026-11-02) and
`zabbix-windows-exhaustion` give both language files the same UUIDs and technical name. Importing
the other file with "Update existing" renames objects in place; history, host links and macro
overrides survive; one server runs one language.

Production state (2026-11-18): the EN template is linked to the fleet; the RU template is linked to
**no hosts**. Switching costs no migration.

## Changes

1. **`templates/localization/build_ru.py`** — delete the `uuid`, `template` and
   `expression`/`recovery_expression` branches of `localize`, the `uuids` catalog handling and the
   UUIDv4 validation. UUIDs, technical name and expressions then pass through unchanged; display
   fields are translated as before.
2. **`templates/localization/ru.yaml`** — delete the `uuids:` section.
3. **`templates/localization/test_build_ru.py`**
   - `test_languages_have_the_same_monitoring_contract`: assert equal `template`; normalize only
     the display fields (`name`, `description`, `opdata`, `newvalue`), so equal UUIDs, technical
     name and expressions are asserted by the same comparison.
   - Delete `test_russian_object_identities_are_separate_and_valid` and
     `test_invalid_identity_mapping_fails`.
   - Keep the reference, placeholder, stale-catalog and reproducibility tests.
4. **Rebuild** `templates/vpn-tunnel-mtu.ru.yaml`.
5. **`README.md`, "Template language"** — same UUIDs and technical name; switch language by
   importing the other file over the installed template with "Update existing"; one language per
   server; keep the existing warning about Actions that match event names. The old RU file is
   public (PR #5): tell its users to Unlink and delete `… RU` before importing the new file, since
   Zabbix 7.0 rejects a duplicate visible name (`CHostGeneral::checkDuplicates`).
6. **House standard** (private ops repository, not under git — edits are live):
   `docs/runbooks/zabbix-template-authoring-standard.md` "Language variants" (lines ~57–71) and the
   matching UUID bullets in `AGENTS.md` and `CLAUDE.md` (lines 64–65 / 69–70); back the three
   files up first. A language edition keeps the source template's UUIDs and technical name;
   distinct UUIDs only for an intentional fork. Point the reference implementation at
   `zabbix-webservices` or this repo.

## Server (only after explicit confirmation)

7. Delete the installed RU template. It must go before any RU import: its visible name equals the new RU
   file's visible name, and Zabbix requires unique visible names.
8. Do **not** import the RU file onto production in this change: it would rename the template on
   every linked host. Choosing the production language is a separate decision.

## Verification

- `python3 templates/localization/build_ru.py` then
  `python3 -m pytest -q templates/localization/test_build_ru.py collectors/openvpn/test_openvpn_discovery.py`
- `git diff --check`
- Read-only `configuration.importcompare` of the RU file against production: it must report updates
  to the existing template, no new template. (importcompare is lenient, so this is a sanity check,
  not proof of a clean import.)

## Out of scope

Template version bump, other languages, changing production language, CI.
