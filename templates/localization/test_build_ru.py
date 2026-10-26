import re
from collections import Counter
from copy import deepcopy
from uuid import RFC_4122, UUID

import pytest
import yaml

from build_ru import CATALOG, OUTPUT, SOURCE, build, render


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
    assert translated["template"] == english["template"] + " RU"
    assert translated["vendor"] == english["vendor"]
    assert translated["groups"] == english["groups"]
    assert russian["zabbix_export"]["template_groups"] == source["zabbix_export"]["template_groups"]

    def normalize(node, name):
        if isinstance(node, list):
            return [normalize(value, name) for value in node]
        if isinstance(node, dict):
            return {
                key: normalize(value, name)
                for key, value in node.items()
                if key not in {"uuid", "template", "name", "description", "opdata", "newvalue"}
            }
        if isinstance(node, str):
            return node.replace(f"/{name}/", "/TEMPLATE/")
        return node

    assert normalize(english, english["template"]) == normalize(translated, translated["template"])
    assert all(node.get("priority") != "HIGH" for node in objects(russian))


def test_russian_object_identities_are_separate_and_valid(documents):
    source, catalog, russian = documents
    english_ids = {node["uuid"] for node in objects(source) if "uuid" in node}
    russian_ids = [node["uuid"] for node in objects(russian) if "uuid" in node]
    shared_groups = {group["uuid"] for group in source["zabbix_export"]["template_groups"]}
    assert len(russian_ids) == len(set(russian_ids)) == len(english_ids)
    assert english_ids.intersection(russian_ids) == shared_groups
    assert set(catalog["uuids"]) == english_ids - shared_groups
    for value in russian_ids:
        parsed = UUID(value)
        assert parsed.hex == value
        assert parsed.version == 4 and parsed.variant == RFC_4122


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
        if "expression" in node:
            assert f'/{template["template"]}/' in node["expression"]


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


@pytest.mark.parametrize("invalid", ["missing", "duplicate", "english", "uuid5"])
def test_invalid_identity_mapping_fails(documents, invalid):
    source, catalog, _ = documents
    first, second = list(catalog["uuids"])[:2]
    if invalid == "missing":
        del catalog["uuids"][first]
    elif invalid == "duplicate":
        catalog["uuids"][first] = catalog["uuids"][second]
    elif invalid == "english":
        catalog["uuids"][first] = first
    else:
        catalog["uuids"][first] = "00112233445556778899aabbccddeeff"
    with pytest.raises(ValueError):
        build(source, catalog)
