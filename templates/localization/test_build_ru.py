import re
from collections import Counter
from copy import deepcopy

import pytest
import yaml

from build_ru import CATALOG, DISPLAY_FIELDS, OUTPUT, SOURCE, build, render


@pytest.fixture
def documents():
    return (
        yaml.safe_load(SOURCE.read_text(encoding="utf-8")),
        yaml.safe_load(CATALOG.read_text(encoding="utf-8")),
        yaml.safe_load(OUTPUT.read_text(encoding="utf-8")),
    )


def objects(node):
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from objects(value)
    elif isinstance(node, list):
        for value in node:
            yield from objects(value)


def test_russian_export_is_reproducible(documents):
    source, catalog, russian = documents
    assert build(source, catalog) == russian
    assert render(build(source, catalog)) == OUTPUT.read_text(encoding="utf-8")
    assert build(source, catalog) == build(deepcopy(source), deepcopy(catalog))


def test_languages_have_the_same_monitoring_contract(documents):
    source, _, russian = documents
    english = source["zabbix_export"]["templates"][0]
    translated = russian["zabbix_export"]["templates"][0]
    assert translated["vendor"] == english["vendor"]
    assert translated["groups"] == english["groups"]
    assert russian["zabbix_export"]["template_groups"] == source["zabbix_export"]["template_groups"]

    # Equal after dropping display text: same UUIDs, technical name and expressions, so RU replaces EN.
    def normalize(node):
        if isinstance(node, list):
            return [normalize(value) for value in node]
        if isinstance(node, dict):
            return {key: normalize(value) for key, value in node.items() if key not in DISPLAY_FIELDS}
        return node

    assert normalize(english) == normalize(translated)
    assert all(node.get("priority") != "HIGH" for node in objects(russian))


def test_russian_references_resolve_within_the_russian_template(documents):
    _, _, russian = documents
    template = russian["zabbix_export"]["templates"][0]
    triggers = {
        (node["name"], node["expression"])
        for node in objects(template)
        if "priority" in node
    }
    maps = {node["name"] for node in template["valuemaps"]}
    for node in objects(template):
        for dependency in node.get("dependencies", []):
            assert (dependency["name"], dependency["expression"]) in triggers
        if "valuemap" in node:
            assert node["valuemap"]["name"] in maps


def test_translations_preserve_macro_tokens(documents):
    _, catalog, _ = documents
    for english, russian in catalog["strings"].items():
        assert Counter(re.findall(r"\{[$#A-Z][^}]*\}", english)) == Counter(
            re.findall(r"\{[$#A-Z][^}]*\}", russian)
        ), english


def test_missing_or_stale_translation_fails(documents):
    source, catalog, _ = documents
    changed = deepcopy(source)
    changed["zabbix_export"]["templates"][0]["description"] += " New requirement."
    with pytest.raises(ValueError, match="Missing Russian translation"):
        build(changed, catalog)
    stale = deepcopy(catalog)
    stale["strings"]["Removed source text"] = "Удалённый исходный текст"
    with pytest.raises(ValueError, match="Unused catalog entries"):
        build(source, stale)


def test_removed_placeholder_fails(documents):
    source, catalog, _ = documents
    catalog["strings"]["gap {ITEM.LASTVALUE} B"] = "Разница в байтах"
    with pytest.raises(ValueError, match="Changed placeholders"):
        build(source, catalog)
