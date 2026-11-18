#!/usr/bin/env python3

import re
from collections import Counter
from copy import deepcopy
from pathlib import Path

import yaml

DIRECTORY = Path(__file__).resolve().parent
SOURCE = DIRECTORY.parent / "vpn-tunnel-mtu.yaml"
CATALOG = DIRECTORY / "ru.yaml"
OUTPUT = DIRECTORY.parent / "vpn-tunnel-mtu.ru.yaml"
DISPLAY_FIELDS = {"name", "description", "opdata", "newvalue"}
PLACEHOLDERS = re.compile(r"\{(?:[^{}]|\{[^{}]*\})*\}")


def build(source, catalog):
    """Translate display fields only; identities stay English, so importing RU updates EN in place."""
    result = deepcopy(source)
    templates = result["zabbix_export"]["templates"]
    if len(templates) != 1:
        raise ValueError("Expected one source template")
    strings = catalog["strings"]
    used_strings = set()

    def localize(node):
        if isinstance(node, list):
            return [localize(value) for value in node]
        if not isinstance(node, dict):
            return node
        translated = {}
        for key, value in node.items():
            if key in {"vendor", "groups"}:
                translated[key] = value
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
    if used_strings != set(strings):
        raise ValueError("Unused catalog entries; update translations")
    return result


def render(document):
    return yaml.safe_dump(document, allow_unicode=True, sort_keys=False, width=100)


if __name__ == "__main__":
    source = yaml.safe_load(SOURCE.read_text(encoding="utf-8"))
    catalog = yaml.safe_load(CATALOG.read_text(encoding="utf-8"))
    OUTPUT.write_text(render(build(source, catalog)), encoding="utf-8")
