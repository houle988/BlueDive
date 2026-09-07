#!/usr/bin/env python3
"""Fast, safe editing of Xcode String Catalogs (.xcstrings) without reading the whole file.

Usage:
  Scripts/xcstrings.py missing                      # list keys lacking fr-CA / de / nl
  Scripts/xcstrings.py show "Key text"              # print one key's entry
  Scripts/xcstrings.py set "Key text" --fr-CA "..." --de "..." --nl "..."   [--en "..."]
  Scripts/xcstrings.py set-json entries.json        # batch: {"Key": {"fr-CA": "...", "de": "...", "nl": "..."}, ...}
                                                    # plural keys: {"fr-CA": {"one": "...", "other": "..."}, ...}
  Scripts/xcstrings.py check                        # exit 1 if any translatable key is missing a language

  Target the widget catalog by putting --file AFTER the subcommand, e.g.
  Scripts/xcstrings.py check --file BlueDiveWidgetExtension/Localizable.xcstrings

Options: --file PATH (default BlueDive/Localizable.xcstrings)
Rules baked in (from CLAUDE.md): de and nl are always written with state "needs_review";
fr-CA is "translated". Output format is byte-identical to Xcode's own (2-space indent, " : ").
"""
import argparse, json, sys, pathlib

LANGS = ["fr-CA", "de", "nl"]
ALLOWED = {"en"} | set(LANGS)          # every language code the script may write
REVIEW = {"de", "nl"}
PLURAL_ORDER = ["zero", "one", "two", "few", "many", "other"]  # CLDR order Xcode stores
DEFAULT = pathlib.Path(__file__).resolve().parent.parent / "BlueDive" / "Localizable.xcstrings"

def load(p):
    return json.loads(p.read_text(encoding="utf-8"))

def save(p, d):
    # Preserve the file's existing trailing-newline state so the diff stays minimal.
    # Xcode writes the main catalog without a trailing newline and the widget catalog with one.
    trailing = "\n" if p.exists() and p.read_bytes().endswith(b"\n") else ""
    body = json.dumps(d, indent=2, separators=(",", " : "), ensure_ascii=False)
    # Write to a sibling temp file then atomically rename, so an interrupted or crashed
    # write can never leave the 1 MB catalog truncated or half-written.
    tmp = p.parent / (p.name + ".tmp")
    tmp.write_text(body + trailing, encoding="utf-8")
    tmp.replace(p)

def translatable(k, v):
    return k.strip() != "" and v.get("shouldTranslate", True)

def has_value(unit):
    """True if a localization has a plain value or plural/device variations."""
    if not unit:
        return False
    if unit.get("stringUnit", {}).get("value"):
        return True
    return bool(unit.get("variations"))

def missing(d):
    out = {}
    for k, v in d["strings"].items():
        if not translatable(k, v):
            continue
        loc = v.get("localizations", {})
        m = [l for l in LANGS if not has_value(loc.get(l))]
        if m:
            out[k] = m
    return out

def unit(text, state):
    return {"stringUnit": {"state": state, "value": text}}

def build_localization(key, lang, text, state):
    """text is a str, or a dict of CLDR plural categories {"one": "...", "other": "..."}."""
    if isinstance(text, dict):
        bad = [c for c in text if c not in PLURAL_ORDER]
        if bad:
            sys.exit(f'ERROR: {key!r} [{lang}]: unknown plural category {bad}; '
                     f'valid CLDR categories are {PLURAL_ORDER}. '
                     '(Device variations are not supported — edit those in Xcode.)')
        for c, t in text.items():
            if not isinstance(t, str):
                sys.exit(f'ERROR: {key!r} [{lang}][{c}]: value must be a string.')
        # Emit categories in CLDR order so the diff matches Xcode's own ordering.
        cats = {c: unit(text[c], state) for c in PLURAL_ORDER if c in text}
        return {"variations": {"plural": cats}}
    if not isinstance(text, str):
        sys.exit(f'ERROR: {key!r} [{lang}]: value must be a string, or a plural dict.')
    return unit(text, state)

def set_key(d, key, values, create=False, force=False):
    if not isinstance(values, dict):
        sys.exit(f'ERROR: {key!r}: value must be an object mapping language → text, '
                 f'got {type(values).__name__}.')
    strings = d["strings"]
    if key not in strings:
        if not create:
            sys.exit(f'ERROR: key not found: {key!r}\n'
                     'Build the project first so Xcode inserts the key, or pass --create.')
        strings[key] = {}
    entry = strings[key]
    if entry.get("shouldTranslate") is False and not force:
        sys.exit(f'ERROR: {key!r} is marked shouldTranslate:false and should not be '
                 'translated. Pass --force to override.')
    loc = entry.setdefault("localizations", {})
    for lang, text in values.items():
        if text is None:
            continue
        if lang not in ALLOWED:
            sys.exit(f'ERROR: {key!r}: unknown language {lang!r}; '
                     f'valid languages are {sorted(ALLOWED)}.')
        if "variations" in loc.get(lang, {}) and not isinstance(text, dict) and not force:
            sys.exit(f'ERROR: {key!r} [{lang}] uses plural variations; pass a dict '
                     '{"one": ..., "other": ...} in set-json, or --force to replace.')
        state = "needs_review" if lang in REVIEW else "translated"
        loc[lang] = build_localization(key, lang, text, state)
    # Keep Xcode's alphabetical ordering of both language keys and entry-level keys
    # (comment, extractionState, isCommentAutoGenerated, localizations, shouldTranslate).
    entry["localizations"] = dict(sorted(loc.items()))
    strings[key] = dict(sorted(entry.items()))
    return strings[key]

def main():
    parent = argparse.ArgumentParser(add_help=False)
    parent.add_argument("--file", type=pathlib.Path, default=DEFAULT)
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("missing", parents=[parent]); sub.add_parser("check", parents=[parent])
    s = sub.add_parser("show", parents=[parent]); s.add_argument("key")
    st = sub.add_parser("set", parents=[parent]); st.add_argument("key")
    for l in ["en"] + LANGS: st.add_argument(f"--{l}")
    st.add_argument("--create", action="store_true"); st.add_argument("--force", action="store_true")
    sj = sub.add_parser("set-json", parents=[parent]); sj.add_argument("json_file", type=pathlib.Path); sj.add_argument("--create", action="store_true"); sj.add_argument("--force", action="store_true")
    a = ap.parse_args()
    d = load(a.file)

    if a.cmd in ("missing", "check"):
        m = missing(d)
        for k, langs in m.items():
            print(f"{k!r}: missing {', '.join(langs)}")
        if a.cmd == "check" and m:
            sys.exit(1)
        if not m:
            print("All translatable keys have fr-CA, de and nl.")
    elif a.cmd == "show":
        e = d["strings"].get(a.key)
        # Use the catalog's own separators so show output can be copied verbatim into set-json.
        print(json.dumps(e, indent=2, separators=(",", " : "), ensure_ascii=False) if e is not None else f"not found: {a.key!r}")
    elif a.cmd == "set":
        vals = {l: getattr(a, l.replace("-", "_")) for l in ["en"] + LANGS}
        if not any(vals.values()):
            sys.exit("nothing to set")
        e = set_key(d, a.key, vals, a.create, a.force)
        save(a.file, d)
        print(f"updated {a.key!r}: " + ", ".join(l for l, v in vals.items() if v))
    elif a.cmd == "set-json":
        batch = json.loads(a.json_file.read_text(encoding="utf-8"))
        for k, vals in batch.items():
            set_key(d, k, vals, a.create, a.force)
        save(a.file, d)
        print(f"updated {len(batch)} key(s)")

if __name__ == "__main__":
    main()
