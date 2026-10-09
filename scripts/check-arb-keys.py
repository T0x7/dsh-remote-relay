"""Verify the zh and en ARB files carry an identical key set.

The App's rule is zero hardcoded copy: every user-visible string is an intl
resource, so a key present in one language and missing in the other is a
silent runtime failure in that language, not a compile error.

Run from the repository root: `python3 scripts/check-arb-keys.py`
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1] / "app"
ZH = ROOT / "lib/l10n/app_zh.arb"
EN = ROOT / "lib/l10n/app_en.arb"


def keys(path):
    with path.open(encoding="utf-8") as handle:
        return set(json.load(handle).keys())


zh, en = keys(ZH), keys(EN)
missing_en = sorted(zh - en)
missing_zh = sorted(en - zh)

print(f"zh={len(zh)} en={len(en)}")
if missing_en:
    print("MISSING IN EN:", ", ".join(missing_en))
if missing_zh:
    print("MISSING IN ZH:", ", ".join(missing_zh))

if missing_en or missing_zh:
    sys.exit(1)
print("key sets match")
