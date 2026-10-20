#!/bin/zsh
# Checks that Resources/it.lproj/Localizable.strings covers every localizable key in the sources.
# Keys are extracted by the Swift compiler (-emit-localized-strings); SelfTest.swift is excluded.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swift build -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >/dev/null
python3 -I - "$OUT" Resources/it.lproj/Localizable.strings <<'PY'
import glob, json, os, re, sys
out, strings = sys.argv[1], sys.argv[2]
keys = set()
for f in glob.glob(os.path.join(out, "*.stringsdata")):
    if os.path.basename(f).startswith("SelfTest"):
        continue
    for entries in json.load(open(f)).get("tables", {}).values():
        keys.update(e["key"] for e in entries if e["key"].strip())
# .strings "old-style" plist: parse with a regex (keys/values are double-quoted with escapes).
pat = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')
unesc = lambda s: s.encode().decode("unicode_escape").encode("latin-1").decode("utf-8")
table = {unesc(k): unesc(v) for k, v in pat.findall(open(strings, encoding="utf-8").read())}
spec = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?[@dDiuUxXoOfeEgGcCsSaAp]")
missing = sorted(k for k in keys if k not in table)
unused = sorted(k for k in table if k not in keys)
bad = sorted(k for k in keys & table.keys() if sorted(spec.findall(k)) != sorted(spec.findall(table[k])))
for k in missing: print("MISSING:", k)
for k in unused: print("UNUSED: ", k)
for k in bad: print("FORMAT: ", k, "->", table[k])
print(f"{len(keys)} keys, {len(missing)} missing, {len(unused)} unused, {len(bad)} format mismatches")
sys.exit(1 if missing or bad else 0)
PY
