#!/usr/bin/env python3

import re
from collections import Counter
from copy import deepcopy
from pathlib import Path
from uuid import RFC_4122, UUID

import yaml

DIRECTORY = Path(__file__).resolve().parent
SOURCE = DIRECTORY.parent / "vpn-tunnel-mtu.yaml"
CATALOG = DIRECTORY / "ru.yaml"
OUTPUT = DIRECTORY.parent / "vpn-tunnel-mtu.ru.yaml"
DISPLAY_FIELDS = {"name", "description", "opdata", "newvalue"}
PLACEHOLDERS = re.compile(r"\{(?:[^{}]|\{[^{}]*\})*\}")


def build(source, catalog):
    """Localize display fields and references; reject incomplete or stale catalogs."""
    result = deepcopy(source)
    templates = result["zabbix_export"]["templates"]
    if len(templates) != 1:
        raise ValueError("Expected one source template")
    english_name = templates[0]["template"]
    russian_name = english_name + " RU"
    strings = catalog["strings"]
    uuids = catalog["uuids"]
    used_strings = set()
    used_uuids = set()

    def localize(node):
        if isinstance(node, list):
            return [localize(value) for value in node]
        if not isinstance(node, dict):
            return node
        translated = {}
        for key, value in node.items():
            if key in {"vendor", "groups"}:
                translated[key] = value
            elif key == "uuid":
                if value not in uuids:
                    raise ValueError(f"Missing Russian UUID for {value}")
                translated[key] = uuids[value]
                used_uuids.add(value)
            elif key == "template":
                translated[key] = russian_name
            elif key in {"expression", "recovery_expression"}:
                translated[key] = value.replace(f"/{english_name}/", f"/{russian_name}/")
            elif key in DISPLAY_FIELDS:
                if value not in strings:
                    raise ValueError(f"Missing Russian translation: {value[:100]!r}")
                text = strings[value]
                if not isinstance(text, str) or not text.strip():
                    raise ValueError(f"Empty Russian translation: {value[:100]!r}")
                if Counter(PLACEHOLDERS.findall(value)) != Counter(PLACEHOLDERS.findall(text)):
                    raise ValueError(f"Changed placeholders: {value[:100]!r}")
                translated[key] = text
                used_strings.add(value)
            else:
                translated[key] = localize(value)
        return translated

    templates[0] = localize(templates[0])
    if used_strings != set(strings) or used_uuids != set(uuids):
        raise ValueError("Unused catalog entries; update translations and UUID mappings")
    russian_uuids = list(uuids.values())
    for value in russian_uuids:
        parsed = UUID(value)
        if parsed.version != 4 or parsed.variant != RFC_4122 or parsed.hex != value:
            raise ValueError(f"Expected a lowercase UUIDv4 without hyphens: {value}")
    original_uuids = used_uuids | {
        group["uuid"] for group in source["zabbix_export"]["template_groups"]
    }
    if len(set(russian_uuids)) != len(russian_uuids) or original_uuids.intersection(russian_uuids):
        raise ValueError("Russian UUIDs must be unique and distinct from the English export")
    return result


def render(document):
    return yaml.safe_dump(document, allow_unicode=True, sort_keys=False, width=100)


if __name__ == "__main__":
    source = yaml.safe_load(SOURCE.read_text(encoding="utf-8"))
    catalog = yaml.safe_load(CATALOG.read_text(encoding="utf-8"))
    OUTPUT.write_text(render(build(source, catalog)), encoding="utf-8")
