#!/usr/bin/env python3
"""Korean string table for GameCase.

ko.py sync    write every translation in ko.json into Resources/Localizable.xcstrings
ko.py check   fail when a key has no Korean, a format specifier differs from the English
              string, or a Korean string still contains Chinese characters

ko.json (next to this script) holds the translations this fork adds; keys upstream already
translated stay as they are in the catalog. A key without Korean is shown in another language
at run time, so the build runs `check` first and stops on the first gap.
"""
import json
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "Resources" / "Localizable.xcstrings"
TABLE = Path(__file__).with_name("ko.json")
SPECIFIER = re.compile(r"%(?:\d+\$)?(#@\w+@|@|l{0,2}[du]|s|(?:\.\d+)?f)")
HAN = re.compile(r"[\u4e00-\u9fff]")


def load():
    return json.loads(CATALOG.read_text(encoding="utf-8"))


def strings(localization):
    """Every string of one language of one key: the plain value, plural variants, substitutions."""
    if "stringUnit" in localization:
        yield localization["stringUnit"]["value"]
    for variants in localization.get("variations", {}).values():
        for variant in variants.values():
            yield from strings(variant)
    for substitution in localization.get("substitutions", {}).values():
        yield from strings(substitution)


def specifiers(text):
    return Counter(SPECIFIER.findall(text.replace("%%", "")))


def sync():
    catalog = load()
    table = json.loads(TABLE.read_text(encoding="utf-8"))
    unknown = sorted(table.keys() - catalog["strings"].keys())
    if unknown:
        print("ko.json has keys the catalog does not: " + ", ".join(unknown))
        return 1
    for key, value in table.items():
        catalog["strings"][key]["localizations"]["ko"] = {"stringUnit": {"state": "translated", "value": value}}
    # the catalog's own layout: two-space indent, ": " separator, literal UTF-8, final newline
    text = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", ": ")) + "\n"
    CATALOG.write_text(text, encoding="utf-8")
    print(f"{len(table)} translations written to {CATALOG.relative_to(ROOT)}")
    return 0


def check():
    entries = load()["strings"]
    problems = []
    for key, entry in sorted(entries.items()):
        localizations = entry["localizations"]
        english = list(strings(localizations["en"]))
        if "ko" not in localizations:
            problems.append(f"no Korean: {key}  ({english[0]!r})")
            continue
        allowed = [specifiers(text) for text in english]
        for text in strings(localizations["ko"]):
            if specifiers(text) not in allowed:
                problems.append(f"format specifiers differ: {key}  {english[0]!r} / {text!r}")
            if HAN.search(text):
                problems.append(f"Chinese characters in Korean: {key}  {text!r}")
    if problems:
        print("\n".join(problems))
        print(f"{len(problems)} problems")
        return 1
    print(f"{len(entries)} keys, all have Korean")
    return 0


if __name__ == "__main__":
    commands = {"sync": sync, "check": check}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        sys.exit(__doc__)
    sys.exit(commands[sys.argv[1]]())
