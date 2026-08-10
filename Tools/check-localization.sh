#!/bin/bash
# Verifies that every localized string the code asks for actually exists, in every
# language, and that the placeholders match.
#
#   ./Tools/check-localization.sh
#
# Why this is a script and not a habit: NSLocalizedString has no compile-time check. A
# missing key silently renders as the key itself, so the app shows "automation.stateOn"
# to the user and nothing fails. Worse, a placeholder mismatch between languages —
# German with two %@ where English has one — is a crash waiting for a language switch,
# because String(format:) reads an argument that was never passed.
#
# Exits non-zero on any problem so it can gate a release.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import re, glob, sys

def keys_in(path):
    text = open(path).read()
    return {m.group(1): m.group(2)
            for m in re.finditer(r'^\s*"([^"]+)"\s*=\s*"(.*)";\s*$', text, re.M)}

def placeholders(value):
    # Order matters for String(format:), so this is a list rather than a set.
    return re.findall(r'%(?:\d+\$)?[@ldfi]+', value)

used = set()
for path in glob.glob("Sources/**/*.swift", recursive=True):
    for m in re.finditer(r'\bL\(\s*"([^"]+)"', open(path).read()):
        used.add(m.group(1))

tables = {}
for path in sorted(glob.glob("Resources/*.lproj/Localizable.strings")):
    lang = path.split("/")[1].replace(".lproj", "")
    tables[lang] = keys_in(path)

if not tables:
    print("FAIL: no Resources/*.lproj/Localizable.strings found")
    sys.exit(1)

problems = 0

# 1. Every key the code uses must exist in every language.
for lang, table in sorted(tables.items()):
    missing = sorted(used - set(table))
    if missing:
        problems += len(missing)
        print(f"FAIL [{lang}]: {len(missing)} key(s) used in code but not defined:")
        for key in missing:
            print(f"    {key}")

# 2. Languages must agree on which keys exist, or a translation silently falls back.
reference = "en" if "en" in tables else sorted(tables)[0]
for lang, table in sorted(tables.items()):
    if lang == reference:
        continue
    only_ref = sorted(set(tables[reference]) - set(table))
    only_other = sorted(set(table) - set(tables[reference]))
    if only_ref:
        problems += len(only_ref)
        print(f"FAIL [{lang}]: missing {len(only_ref)} key(s) present in {reference}:")
        for key in only_ref:
            print(f"    {key}")
    if only_other:
        problems += len(only_other)
        print(f"FAIL [{lang}]: has {len(only_other)} key(s) absent from {reference}:")
        for key in only_other:
            print(f"    {key}")

# 3. Placeholders must match, or String(format:) reads arguments that were never passed.
for lang, table in sorted(tables.items()):
    if lang == reference:
        continue
    for key, value in sorted(table.items()):
        if key not in tables[reference]:
            continue
        expected = placeholders(tables[reference][key])
        actual = placeholders(value)
        if sorted(expected) != sorted(actual):
            problems += 1
            print(f"FAIL [{lang}] {key}: placeholders {actual} do not match "
                  f"{reference} {expected}")

unused = sorted(set(tables[reference]) - used)
if unused:
    # A warning, not a failure: a key may be staged ahead of the code that uses it.
    print(f"\nnote: {len(unused)} key(s) defined but not referenced in code:")
    for key in unused:
        print(f"    {key}")

if problems:
    print(f"\n{problems} localization problem(s)")
    sys.exit(1)

total = len(tables[reference])
print(f"OK: {len(used)} key(s) used, {total} defined, "
      f"{len(tables)} language(s) in agreement, placeholders match")
PY
