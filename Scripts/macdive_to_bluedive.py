#!/usr/bin/env python3
"""
macdive_to_bluedive.py
Convert a MacDive SQLite database to BlueDive XML files.

Usage:
    python3 macdive_to_bluedive.py <input.sqlite> <output.xml> --export <type> [options]
    python3 macdive_to_bluedive.py <input.sqlite> --schema

Export types:
    dives           Dive log with associated gear and profile samples  (default)
    gears           All gear items, gear groups, and service history
    certifications  All certifications

Required flags by export type:
    dives           --weight-unit  --macdive-xml
    gears           --weight-unit
    certifications  (none)

Flags:
    --schema
        Print every table and column in the SQLite database (plus service-record and
        certification table diagnostics) and exit.  No output file is written.

    --weight-unit {kg,lbs}
        Default weight unit.  The SQLite database stores whatever unit the user entered,
        so it cannot be detected automatically.  When an individual weight field embeds
        its own unit token (e.g. "9 kg", "48 lbs"), that embedded unit takes priority
        for that record only.  The value is never converted — only the unit label
        follows the embedded token.

    --macdive-xml PATH
        Path to a MacDive XML export (MacDive → File → Export → XML).  Required for
        --export dives.  The SQLite database and the XML export must come from the same
        MacDive library.

        Distance, temperature, pressure, and volume units are auto-detected from the
        XML's <units> tag:
            Metric   → metres, °C, bar, litres
            Canadian → feet,   °C, PSI, cubic feet
            Imperial → feet,   °F, PSI, cubic feet

        The XML supplies profile samples, tank start/end pressures (from <gases>), and
        air/high/low temperatures, all already in the display unit.  XML gases are paired
        with SQLite tanks by O₂/He mix; pairing falls back to position when the mix is
        absent or shared by several tanks.

        The SQLite fallback is applied per field, whenever the XML value is missing
        (dive not matched, no paired gas, or empty element):
            - Start pressure: magnitude heuristic (> 400 = PSI, ≤ 400 = bar).
            - End pressure: assumed to share the start pressure's unit (the XML start
              when present, otherwise the SQLite start).
            - Temperature: assumed °C; omitted for Imperial exports when the dive has no
              XML match, because the unit cannot be verified.

        Tank working pressure and volume always come from SQLite (MacDive does not
        convert them when the unit setting changes):
            - Working pressure: magnitude heuristic (> 400 = PSI, ≤ 400 = bar).
            - Volume: unit inferred from working pressure (PSI → cuft, bar → L);
              omitted when working pressure is unknown.

Profile-to-dive matching:
    SQLite CoreData timestamps (UTC) are matched to the XML <date> strings (local time
    of the exporting Mac), so the script can run on any machine regardless of timezone.

    1. Consensus offset — the single UTC hour offset that gives the most unambiguous
       matches is detected and tried ±1 h (DST / travel), with a ±2 s clock tolerance.
       With fewer than 2 unambiguous hits, the full -12..+12 h sweep is used instead.
       If the window finds no candidates, a UTC+0 fallback (XML local time == UTC)
       covers devices left in UTC.
    2. Diver filter — names are compared case-, accent-, and whitespace-insensitively,
       with a fallback that accepts a SQLite name containing the XML name (separates
       family members who dive together).  If neither matches, all candidates are
       kept and a warning is printed.
    3. Tiebreaks — max depth (±2 m), then duration (±30 s; the closest wins when it is
       more than 15 s better than the runner-up).
    4. Plausibility gate — a match is rejected when profile max depth differs by more
       than 5 m or the sample span by more than 2 min from the SQLite dive.  The span
       check is skipped when the XML <duration> equals the SQLite duration (±2 s), since
       many computers log several minutes of surface samples after the dive ends.
    5. Best-match assignment — when several XML dives claim the same SQLite dive, the
       one with the smallest duration/depth delta wins.
    6. Retry — dives skipped as no_match are retried against the full -12..+12 h
       sweep (multi-timezone trips), with the same guards and best-match assignment.
       Skipped when step 1 already used the full sweep.

    A match summary and skip breakdown (bad_date, no_match, ambiguous, depth_mismatch,
    span_mismatch, outscored) are printed at the end.

Raw dive computer data (ZRAWDATA, decoded with libdivecomputer):
    On the first dive with raw data, the script checks the libdivecomputer folder of the
    BlueDive LibDCSwift fork (https://github.com/houle988/libdc-swift/tree/main/libdivecomputer).
    When there is no cached copy, or the folder has a newer commit, it downloads the folder
    and compiles it with the Xcode command-line tools (xcode-select --install) into
    ~/Library/Caches/BlueDive/macdive_to_bluedive/.  Offline, the cached copy is used;
    without one, raw data is not decoded.  libdivecomputer runs in a separate worker
    process: a dive on which it crashes or takes more than 60 s is logged as not decodable,
    and after two such failures on one computer model that model is skipped.

    Raw data is used for a dive only when it agrees with MacDive: max depth within 0.5 m of
    MacDive's XML profile (or of the dive record when there is none) and a profile not more
    than 60 s shorter.  Pressure and PPO₂ readings of 0 mean no data and are ignored.

Data priority (first available source wins; "Raw" = agreeing raw data, see above):
    Date/time, number, rating, diver, buddies, computer,      SQLite
      site, notes, tags, types, conditions, operator, boat,
      weight, gear, average depth, surface interval, CNS,
      deco model, tank mix / size / working pressure
    Units (distance, temperature, pressure, volume)            XML <units>
    Air / high / low temperature (dive)                        XML → SQLite
    Duration                                                   Raw (computer dive time, if not longer than its
                                                               profile + 60 s and within 10 min or 20 % of
                                                               MacDive's) → SQLite
    Max depth                                                  Raw (computer value, if within 0.5 m of its
                                                               deepest sample) → SQLite
    Decompression-dive flag                                    Raw (the app's Bluetooth rule: a deco-stop
                                                               sample or event; NDL only = no) → SQLite
    Deco stops (Gas tab, metres)                               Raw only
    Tank start / end pressure                                  Raw (a transmitter whose begin pressure and
                                                               pressure at MacDive's end time match the tank
                                                               within 1 bar, same mix, unambiguous; or the only
                                                               transmitter of a one-tank dive MacDive has no
                                                               pressures for) → XML (gas matched by mix,
                                                               else position) → SQLite
    Marine life                                                SQLite (dive-linked critters + photo-tagged
                                                               critters, count = photos tagged)
    Profile samples (time, depth, temperature, NDL, PPO₂,      Raw → XML.  PPO₂ only as the computer reports it
      per-cell PPO₂, ceiling, remaining stop time)             (BlueDive calculates it otherwise).
    Sample tank pressure                                       Raw (mapped transmitters, same mapping as the
                                                               tank values) → when the raw samples have no
                                                               main-tank pressure at all: MacDive's main-tank
                                                               pressure on the raw samples recorded at the same
                                                               moment (±2 s, only when ≥ 90 % of MacDive's
                                                               readings line up; nothing copied onto other
                                                               samples) → XML samples (when they don't line up)
    Gas switches + active tank                                 Raw (when the computer reports its gas) →
                                                               MacDive events (tank set when one tank has the mix)
    Other events (ascent, deep stop, PPO₂, ceiling,            Raw + MacDive events (MacDive's dropped when raw
      bookmark, safety stop, deco stop)                        has the same event within 30 s)
    Not imported                                               Set point switches (counted in the log)

    Every value raw data changes is logged per dive as "raw values : … (MacDive → raw
    data)", and each dive's profile source on its "profile :" line.

Output:
    dives  → <output.xml> plus <output.log>, a per-dive log of tank pressures,
             working pressure, volume, depths, and temperatures (source, original
             unit, and output unit), plus notes on gas-to-tank pairing.  Useful
             for auditing unit conversions.

    Note: run this script on the same Mac where you will import into BlueDive.  All
    date strings in the output are written in the local timezone of the machine
    running the script, which is what the BlueDive XML parser expects.

Examples:
    python3 macdive_to_bluedive.py MacDive.sqlite dives.xml --export dives \\
        --weight-unit kg --macdive-xml MacDive-Export.xml

    python3 macdive_to_bluedive.py MacDive.sqlite gear.xml --export gears \\
        --weight-unit kg

    python3 macdive_to_bluedive.py MacDive.sqlite certs.xml --export certifications

    python3 macdive_to_bluedive.py MacDive.sqlite --schema

Requirements: Python 3.8+  (no third-party packages needed)
"""

import argparse
import base64
import bisect
import json
import os
import re
import sqlite3
import struct
import sys
import textwrap
import unicodedata
import uuid as _uuid_mod
import xml.etree.ElementTree as ET
from datetime import datetime, timezone, timedelta
from pathlib import Path

# ---------------------------------------------------------------------------
# CoreData epoch: 2001-01-01 00:00:00 UTC
# ---------------------------------------------------------------------------
COREDATA_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)


def coredata_to_str(ts):
    """Convert a CoreData timestamp (float seconds) to 'YYYY-MM-DD HH:MM:SS' local time."""
    if ts is None or ts == 0:
        return ""
    dt = COREDATA_EPOCH + timedelta(seconds=float(ts))
    return dt.astimezone().strftime("%Y-%m-%d %H:%M:%S")


def fmt_double(v):
    """Format like BlueDive's formatDouble: 4 dp, trailing zeros stripped."""
    if v is None or v == "":
        return ""
    try:
        s = f"{float(v):.4f}".rstrip("0").rstrip(".")
        return s if s not in ("", "-", "-0") else "0"
    except (ValueError, TypeError):
        pass
    # Freeform strings like "4,5 kg" — extract leading numeric part and re-format.
    m = re.match(r'^\s*(-?[\d.,]+)', str(v))
    if m:
        try:
            s = f"{float(m.group(1).replace(',', '.')):.4f}".rstrip("0").rstrip(".")
            return s if s not in ("", "-", "-0") else "0"
        except (ValueError, TypeError):
            pass
    return ""


# XML 1.0 forbids control characters outside tab/LF/CR; strip them before escaping.
_XML_ILLEGAL = re.compile(r'[\x00-\x08\x0b\x0c\x0e-\x1f]')

# Junction table keyword hints used to identify gear associations (module-level so
# export_dives warning and fetch_dive_gear matching always use the same set).
_GEAR_HINTS = ("GEAR", "ITEM", "EQUIPMENT")

# Recognized weight unit tokens in MacDive freeform weight strings.
_WEIGHT_UNIT_ALIASES = {
    "kg": "kg", "kgs": "kg", "kilogram": "kg", "kilograms": "kg",
    "lb": "lbs", "lbs": "lbs", "pound": "lbs", "pounds": "lbs",
}


def parse_weight(raw, default_unit):
    """Return (numeric_str, unit) from a raw MacDive weight value.

    If the stored value contains a recognized unit token (e.g. '9 kg', '48 lbs'),
    that unit takes priority over default_unit.  Plain numbers fall back to
    default_unit.  Returns ('', default_unit) when raw is absent (None), an empty
    string, or unparseable — an empty <weight> tag means "unrecorded", never a
    fabricated 0.
    """
    if raw is None or raw == "":
        return ("", default_unit)
    s = str(raw)
    m = re.match(r'^\s*(-?[\d.,]+)\s*([a-zA-Z]*)', s)
    if m:
        embedded = m.group(2).strip().lower()
        canonical = _WEIGHT_UNIT_ALIASES.get(embedded) if embedded else None
        unit = canonical if canonical else default_unit
        if canonical and canonical != default_unit:
            print(
                f"  Note: weight '{raw}' has embedded unit '{embedded}'"
                f" → using '{unit}' instead of --weight-unit={default_unit}",
                file=sys.stderr,
            )
        try:
            numeric = f"{float(m.group(1).replace(',', '.')):.4f}".rstrip("0").rstrip(".")
            numeric = numeric if numeric not in ("", "-", "-0") else "0"
            return (numeric, unit)
        except (ValueError, TypeError):
            pass
    try:
        numeric = f"{float(s):.4f}".rstrip("0").rstrip(".")
        numeric = numeric if numeric not in ("", "-", "-0") else "0"
        return (numeric, default_unit)
    except (ValueError, TypeError):
        return ("", default_unit)


def xml_escape(s):
    if s is None:
        return ""
    s = _XML_ILLEGAL.sub('', str(s))
    return (s
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace('"', "&quot;")
            .replace("'", "&apos;"))


def xtag(name, value, indent=4):
    pad = " " * indent
    return f"{pad}<{name}>{xml_escape(value)}</{name}>"


def base64_block(name, data, indent=4):
    """Emit a base64-encoded binary element with 76-char MIME line wrapping."""
    if isinstance(data, memoryview):
        data = bytes(data)
    elif not isinstance(data, (bytes, bytearray)):
        return []  # skip non-binary data (TEXT-affinity ZRAWDATA on schema variants)
    pad = " " * indent
    inner = " " * (indent + 2)
    b64 = base64.b64encode(data).decode("ascii")
    chunks = textwrap.wrap(b64, 76)
    lines = [f"{pad}<{name} encoding=\"base64\">"]
    lines += [f"{inner}{c}" for c in chunks]
    lines.append(f"{pad}</{name}>")
    return lines


# ---------------------------------------------------------------------------
# Schema helpers
# ---------------------------------------------------------------------------

_table_exists_cache: dict = {}


def table_exists(cur, name):
    if name not in _table_exists_cache:
        cur.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,))
        _table_exists_cache[name] = cur.fetchone() is not None
    return _table_exists_cache[name]


_columns_cache: dict = {}


def columns(cur, table):
    """Return a set of upper-cased column names for table (cached per process invocation)."""
    if table not in _columns_cache:
        cur.execute(f"PRAGMA table_info(\"{table}\")")
        _columns_cache[table] = {row[1].upper() for row in cur.fetchall()}
    return _columns_cache[table]


def _reset_schema_caches():
    """Clear schema caches. Call at the start of each export when the database changes."""
    _table_exists_cache.clear()
    _columns_cache.clear()


def col_or_null(col_set, *candidates):
    """Return the first candidate found in col_set, else 'NULL'.

    The sentinel string 'NULL' must be interpolated *unquoted* into SQL so it
    becomes the SQL NULL keyword (not a quoted string literal). Always use bare
    f-string interpolation: f'SELECT {col}, ...' — never f'SELECT "{col}"'.
    """
    for c in candidates:
        if c.upper() in col_set:
            return c
    return "NULL"


def discover_junctions(cur):
    """
    Find all 2-column Z_* tables — MacDive's CoreData junction tables.
    Returns list of (table_name, col0, col1).
    """
    cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Z_%'")
    result = []
    for (tbl,) in cur.fetchall():
        cur.execute(f"PRAGMA table_info(\"{tbl}\")")
        rows = cur.fetchall()
        if len(rows) == 2:
            result.append((tbl, rows[0][1], rows[1][1]))
    return result


def find_junction(junctions, *hints):
    """Find the first junction matching the given hints.

    Single hint  → try table-name suffix match first (precise, backward-compatible),
                   then fall back to searching (table+col0+col1) as a substring.
    Multiple hints → search (table+col0+col1) for ALL hints simultaneously.
                     Use this when the relevant keyword appears only in a column name,
                     not the table name (e.g. MacDive's buddy/tag junctions).
    """
    if len(hints) == 1:
        suffix = hints[0].upper()
        for tbl, c0, c1 in junctions:
            if tbl.upper().endswith(suffix):
                return (tbl, c0, c1)
    for tbl, c0, c1 in junctions:
        key = (tbl + c0 + c1).upper()
        if all(h.upper() in key for h in hints):
            return (tbl, c0, c1)
    return None


def junction_lookup(cur, dive_pk, junction, lookup):
    """Return names from lookup[] for all related entities of dive_pk via junction."""
    if junction is None:
        return []
    tbl, c0, c1 = junction
    c0u, c1u = c0.upper(), c1.upper()
    # Primary: explicit TODIVE marker in column name.
    # Secondary: column ends with DIVE/DIVES — CoreData sometimes omits the TO prefix
    # (e.g. Z_5RELATIONSHIPDIVES for the dive FK in the tag junction).
    if "TODIVE" in c1u:
        entity_col, dive_col = c0, c1
    elif "TODIVE" in c0u:
        entity_col, dive_col = c1, c0
    elif c1u.endswith("DIVE") or c1u.endswith("DIVES"):
        entity_col, dive_col = c0, c1
    elif c0u.endswith("DIVE") or c0u.endswith("DIVES"):
        entity_col, dive_col = c1, c0
    else:
        entity_col, dive_col = c0, c1  # best guess
    try:
        cur.execute(f'SELECT "{entity_col}" FROM "{tbl}" WHERE "{dive_col}" = ?', (dive_pk,))
        return [lookup[pk] for (pk,) in cur.fetchall() if pk in lookup]
    except Exception:
        return []


# ---------------------------------------------------------------------------
# Lookup-table builders
# ---------------------------------------------------------------------------

def load_name_pairs(cur, table, first_col, last_col):
    """Build {pk: 'First Last'} from a table that may have separate first/last columns."""
    tc = columns(cur, table)
    first = col_or_null(tc, first_col, "ZNAME")
    last  = col_or_null(tc, last_col)
    cur.execute(f'SELECT Z_PK, {first}, {last} FROM "{table}"')
    result = {}
    for pk, f, l in cur.fetchall():
        parts = [p for p in (f or "", l or "") if p.strip()]
        result[pk] = " ".join(parts)
    return result


def load_divers(cur):
    if not table_exists(cur, "ZDIVER"):
        return {}
    return load_name_pairs(cur, "ZDIVER", "ZFIRSTNAME", "ZLASTNAME")


def load_buddies(cur):
    if not table_exists(cur, "ZBUDDY"):
        return {}
    return load_name_pairs(cur, "ZBUDDY", "ZFIRSTNAME", "ZLASTNAME")


def load_simple(cur, table, name_col="ZNAME"):
    """Build {pk: name} for simple single-name-column tables."""
    if not table_exists(cur, table):
        return {}
    tc = columns(cur, table)
    nc = col_or_null(tc, name_col, "ZTITLE", "ZTEXT")
    if nc == "NULL":
        return {}
    cur.execute(f'SELECT Z_PK, "{nc}" FROM "{table}"')
    return {pk: (name or "") for pk, name in cur.fetchall()}


def load_computers(cur):
    """Return {pk: (name, serial)} from ZCOMPUTER or ZDIVECOMPUTER."""
    for tbl in ("ZCOMPUTER", "ZDIVECOMPUTER"):
        if table_exists(cur, tbl):
            tc = columns(cur, tbl)
            name_col   = col_or_null(tc, "ZNAME", "ZMODEL")
            serial_col = col_or_null(tc, "ZSERIAL", "ZCOMPUTERSERIAL")
            cur.execute(f'SELECT Z_PK, {name_col}, {serial_col} FROM "{tbl}"')
            return {pk: (n or "", s or "") for pk, n, s in cur.fetchall()}
    return {}


def load_sites(cur):
    """Return {pk: dict} from ZDIVESITE."""
    if not table_exists(cur, "ZDIVESITE"):
        return {}
    sc = columns(cur, "ZDIVESITE")
    lat = col_or_null(sc, "ZGPSLAT",  "ZLATITUDE",  "ZLAT")
    lon = col_or_null(sc, "ZGPSLON",  "ZLONGITUDE", "ZLON")
    sql = f"""
        SELECT Z_PK,
               {col_or_null(sc, 'ZNAME')},
               {col_or_null(sc, 'ZLOCATION')},
               {col_or_null(sc, 'ZCOUNTRY')},
               {col_or_null(sc, 'ZBODYOFWATER')},
               {col_or_null(sc, 'ZWATERTYPE')},
               {col_or_null(sc, 'ZDIFFICULTY')},
               {col_or_null(sc, 'ZALTITUDE')},
               {lat}, {lon}
        FROM ZDIVESITE
    """
    cur.execute(sql)
    result = {}
    for row in cur.fetchall():
        result[row[0]] = {
            "name": row[1], "location": row[2], "country": row[3],
            "body_of_water": row[4], "water_type": row[5], "difficulty": row[6],
            "altitude": row[7], "lat": row[8], "lon": row[9],
        }
    return result


# ---------------------------------------------------------------------------
# Per-dive helpers
# ---------------------------------------------------------------------------

def fetch_tanks(cur, dive_pk):
    """
    Return list of tank dicts via ZTANKANDGAS JOIN ZTANK JOIN ZGAS.
    Mirrors MacDiveSQLiteParser.fetchTanks.
    """
    if not table_exists(cur, "ZTANKANDGAS"):
        return []
    tc  = columns(cur, "ZTANK")  if table_exists(cur, "ZTANK") else set()
    gc  = columns(cur, "ZGAS")   if table_exists(cur, "ZGAS")  else set()
    tgc = columns(cur, "ZTANKANDGAS")

    order_col = "tg.ZORDER" if "ZORDER" in tgc else "tg.Z_PK"

    size_col = "t.ZSIZE"            if "ZSIZE"            in tc else "NULL"
    wp_col   = "t.ZWORKINGPRESSURE" if "ZWORKINGPRESSURE" in tc else "NULL"
    mat_col  = "t.ZMATERIAL"        if "ZMATERIAL"        in tc else "NULL"
    o2_col   = "g.ZOXYGEN"          if "ZOXYGEN"          in gc else "NULL"
    he_col   = "g.ZHELIUM"          if "ZHELIUM"          in gc else "NULL"
    type_col = "t.ZTANKTYPE"        if "ZTANKTYPE"        in tc else "NULL"

    sql = f"""
        SELECT tg.ZAIRSTART, tg.ZAIREND,
               {size_col}, {wp_col}, {mat_col},
               {o2_col}, {he_col}, {type_col}
        FROM ZTANKANDGAS tg
        LEFT JOIN ZTANK t ON tg.ZRELATIONSHIPTANK = t.Z_PK
        LEFT JOIN ZGAS  g ON tg.ZRELATIONSHIPGAS  = g.Z_PK
        WHERE tg.ZRELATIONSHIPDIVE = ?
        ORDER BY {order_col} ASC
    """
    try:
        cur.execute(sql, (dive_pk,))
        rows = cur.fetchall()
    except Exception:
        return []
    tanks = []
    for row in rows:
        air_start, air_end, size, wp, mat, o2raw, he_raw, tank_type = row
        # O2/He stored as fractions (0.21) or percentages (21). Exactly 1.0 means
        # 100% O2 (pure oxygen, a valid deco gas) — not 1%.
        # o2raw == 0 is treated as absent (same as None) — a stored 0 means "not recorded",
        # not "no oxygen", which would be physically impossible.
        if o2raw is not None and float(o2raw) > 0 and float(o2raw) <= 1.0:
            o2_pct = round(float(o2raw) * 100)
        elif o2raw is not None and float(o2raw) > 0:
            o2_pct = round(float(o2raw))
        else:
            o2_pct = 21  # absent or 0 = air default
        if he_raw is not None and float(he_raw) <= 1.0:
            he_pct = round(float(he_raw) * 100)
        else:
            he_pct = round(float(he_raw)) if he_raw is not None else 0
        tanks.append({
            "start": air_start, "end": air_end,
            "vol": size, "wp": wp, "mat": mat,
            "o2": o2_pct, "he": he_pct,
            "type": tank_type,
        })
    return tanks


def _critter_junction_cols(jt):
    """Return (critter_col, other_col) for a critter junction table."""
    _, c0, c1 = jt
    if c0.upper().endswith(("TOCRITTER", "TOCRITTERS")):
        return c0, c1
    if c1.upper().endswith(("TOCRITTER", "TOCRITTERS")):
        return c1, c0
    return c0, c1


def fetch_critters(cur, dive_pk, critter_jt, critter_image_jt=None):
    """
    Return [{name, count}] for marine life sightings.

    MacDive links critters to a dive directly (critter ↔ dive junction) and/or through the
    dive's photos (critter ↔ dive-image junction). Both are combined, one entry per name.
    A critter tagged on photos gets count = number of the dive's photos tagged with it;
    a critter linked only to the dive keeps its dive-link count.
    """
    if not table_exists(cur, "ZCRITTER"):
        return []
    counts: dict = {}
    if critter_jt is not None:
        tbl = critter_jt[0]
        critter_col, dive_col = _critter_junction_cols(critter_jt)
        try:
            cur.execute(f"""
                SELECT c.ZNAME, COUNT(*) AS cnt
                FROM "{tbl}" j
                JOIN ZCRITTER c ON j."{critter_col}" = c.Z_PK
                WHERE j."{dive_col}" = ?
                GROUP BY c.ZNAME
            """, (dive_pk,))
            for name, cnt in cur.fetchall():
                if name:
                    counts[name] = cnt
        except Exception:
            pass
    if critter_image_jt is not None and table_exists(cur, "ZDIVEIMAGE"):
        img_dive_col = col_or_null(columns(cur, "ZDIVEIMAGE"),
                                   "ZRELATIONSHIPDIVE", "ZRELATIONSHIPDIVEIMAGETODIVE")
        if img_dive_col != "NULL":
            tbl = critter_image_jt[0]
            critter_col, image_col = _critter_junction_cols(critter_image_jt)
            try:
                cur.execute(f"""
                    SELECT c.ZNAME, COUNT(DISTINCT i.Z_PK) AS cnt
                    FROM "{tbl}" j
                    JOIN ZDIVEIMAGE i ON j."{image_col}" = i.Z_PK
                    JOIN ZCRITTER c ON j."{critter_col}" = c.Z_PK
                    WHERE i."{img_dive_col}" = ?
                    GROUP BY c.ZNAME
                """, (dive_pk,))
                for name, cnt in cur.fetchall():
                    if name:
                        counts[name] = cnt   # photo count supersedes the dive-link count
            except Exception:
                pass
    return [{"name": name, "count": counts[name]} for name in sorted(counts)]


# MacDive ZEVENT.ZTYPE → BlueDive sample event. Only types whose meaning is unambiguous in
# MacDive data are mapped; others (set points, CNS, tissue, alarms, photo markers, and
# types MacDive reuses for different events, e.g. 12 = safety stop or deep stop broken)
# are not imported because BlueDive has no matching event.
_MACDIVE_EVENT_MAP = {
    2:  "ascent",    # Ascent Rate Warning
    7:  "deepStop",  # Deep Stop
    10: "gasChange", # Switched to gas: … / Gas Change
    19: "po2",       # PPO2
    20: "po2",       # PPO2 High
    22: "ceiling",   # Safety Stop Ceiling Broken
    23: "ceiling",   # Safety Stop Ceiling Error
    28: "bookmark",  # User Bookmark
}


def _nearest_index(times, t):
    """Index of the value in sorted `times` nearest to t (the earlier one on a tie)."""
    i = bisect.bisect_left(times, t)
    if i == len(times) or (i > 0 and t - times[i - 1] <= times[i] - t):
        i = max(i - 1, 0)
    return i


def _tank_for_mix(mix, tanks):
    """Index of the only tank with this (o2, he) mix, else None."""
    if mix is None:
        return None
    hits = [i for i, t in enumerate(tanks) if (t["o2"], t["he"]) == tuple(mix)]
    return hits[0] if len(hits) == 1 else None


def _gas_switch_mix(detail):
    """Parse a MacDive gas-switch detail ('Switched to gas: EAN32' / 'Air' / 'Tx 21/35')
    into (o2_pct, he_pct), or None when the detail names no mix."""
    m = re.search(r"Switched to gas:\s*(.+)$", detail or "")
    if not m:
        return None
    gas = m.group(1).strip()
    if gas.lower() == "air":
        return (21, 0)
    m = re.fullmatch(r"(?i)EAN\s*(\d+)", gas)
    if m:
        return (int(m.group(1)), 0)
    m = re.fullmatch(r"(?i)(?:Tx|Trimix)\s*(\d+)\s*/\s*(\d+)", gas)
    if m:
        return (int(m.group(1)), int(m.group(2)))
    return None


def fetch_events(cur, dive_pk, tanks):
    """
    Return [(time_secs, event, tank_index | None)] for the dive's mappable MacDive events.
    For a gas switch, tank_index is the position in `tanks` of the only tank with the named
    mix; it stays None when the mix is unnamed or matches zero or several tanks.
    """
    if not table_exists(cur, "ZEVENT"):
        return []
    ec = columns(cur, "ZEVENT")
    if not {"ZTYPE", "ZTIME", "ZRELATIONSHIPEVENTTODIVE"} <= ec:
        return []
    detail_col = "ZDETAIL" if "ZDETAIL" in ec else "NULL"
    try:
        cur.execute(f"""
            SELECT ZTYPE, ZTIME, {detail_col} FROM ZEVENT
            WHERE ZRELATIONSHIPEVENTTODIVE = ? AND ZTIME IS NOT NULL
            ORDER BY ZTIME
        """, (dive_pk,))
        rows = cur.fetchall()
    except Exception:
        return []
    events = []
    for etype, etime, detail in rows:
        kind = _MACDIVE_EVENT_MAP.get(int(etype)) if etype is not None else None
        if kind is None:
            continue
        tank_idx = None
        if kind == "gasChange":
            tank_idx = _tank_for_mix(_gas_switch_mix(detail), tanks)
        events.append((float(etime), kind, tank_idx))
    return events


def attach_events_to_samples(samples, events):
    """
    Return a copy of samples with each event added to the sample nearest its time.
    A gas switch also sets current_gas on that sample when its tank was identified.
    """
    if not samples or not events:
        return samples
    out = [dict(s) for s in samples]
    times = [s["time"] for s in out]
    for etime, kind, tank_idx in events:
        i = _nearest_index(times, etime)
        if kind is not None:
            evs = out[i].setdefault("events", [])
            if kind not in evs:
                evs.append(kind)
        # kind None = the computer's initial gas: sets the active tank without an event.
        if (kind == "gasChange" or kind is None) and tank_idx is not None:
            out[i]["current_gas"] = tank_idx
    return out


# ---------------------------------------------------------------------------
# libdivecomputer — decodes MacDive's ZRAWDATA (raw dive computer download)
# ---------------------------------------------------------------------------
#
# The library is the copy vendored in the BlueDive LibDCSwift fork, so migrated dives are
# decoded by the same parser as the app's Bluetooth import. It is downloaded from GitHub and
# compiled with the Xcode command-line tools (cc) into a per-user cache on each run when the
# fork's libdivecomputer folder has a newer commit than the cached build.

LIBDC_REPO     = "houle988/libdc-swift"
LIBDC_BRANCH   = "main"
LIBDC_FOLDER   = "libdivecomputer"
LIBDC_CACHE    = Path.home() / "Library" / "Caches" / "BlueDive" / "macdive_to_bluedive"
_HTTP_TIMEOUT  = 10
_LIBDC_DECODE_TIMEOUT = 60   # seconds per dive before the decoding worker is stopped

# libdivecomputer SAMPLE_EVENT_* → BlueDive sample event, the same mapping as the app's
# Bluetooth import (LibDCSwift GenericParser + BluetoothScannerView.convertDiveEvent).
_LIBDC_EVENT_MAP = {
    1:  "decoStop",      # SAMPLE_EVENT_DECOSTOP
    3:  "ascent",        # SAMPLE_EVENT_ASCENT
    4:  "ceiling",       # SAMPLE_EVENT_CEILING
    7:  "violation",     # SAMPLE_EVENT_VIOLATION
    8:  "bookmark",      # SAMPLE_EVENT_BOOKMARK
    10: "safetyStop:0",  # SAMPLE_EVENT_SAFETYSTOP
    13: "safetyStop:1",  # SAMPLE_EVENT_SAFETYSTOP_MANDATORY
    14: "deepStop",      # SAMPLE_EVENT_DEEPSTOP
    20: "po2",           # SAMPLE_EVENT_PO2
}
# Gas switches come from DC_SAMPLE_GASMIX; SAMPLE_EVENT_GASCHANGE/GASCHANGE2 are deprecated.

_DC_SAMPLE_TIME, _DC_SAMPLE_DEPTH, _DC_SAMPLE_PRESSURE, _DC_SAMPLE_TEMPERATURE = 0, 1, 2, 3
_DC_SAMPLE_EVENT, _DC_SAMPLE_SETPOINT, _DC_SAMPLE_PPO2 = 4, 9, 10
_DC_SAMPLE_DECO, _DC_SAMPLE_GASMIX = 12, 13
_DC_FIELD_DIVETIME, _DC_FIELD_MAXDEPTH = 0, 1
_DC_FIELD_GASMIX_COUNT, _DC_FIELD_GASMIX, _DC_FIELD_DIVEMODE = 3, 4, 12
_DC_FIELD_TANK_COUNT, _DC_FIELD_TANK = 10, 11
_DC_DECO_NDL, _DC_DECO_DECOSTOP = 0, 2
_DC_SENSOR_NONE = 0xFFFFFFFF
_DC_GASMIX_UNKNOWN = 0xFFFFFFFF   # e.g. Shearwater, for a tank without a transmitter
_DC_DIVEMODES = {0: "freedive", 1: "gauge", 2: "OC", 3: "CCR", 4: "SCR"}


def _http_get(url, accept=None):
    import urllib.request
    req = urllib.request.Request(url, headers={"User-Agent": "macdive_to_bluedive",
                                                **({"Accept": accept} if accept else {})})
    with urllib.request.urlopen(req, timeout=_HTTP_TIMEOUT) as resp:
        return resp.read()


def _libdc_latest_commit():
    """Return (sha, iso_date) of the newest fork commit that touched the libdivecomputer folder."""
    url = (f"https://api.github.com/repos/{LIBDC_REPO}/commits"
           f"?sha={LIBDC_BRANCH}&path={LIBDC_FOLDER}&per_page=1")
    data = json.loads(_http_get(url, accept="application/vnd.github+json"))
    if not data:
        raise RuntimeError(f"no commits found for {LIBDC_REPO}/{LIBDC_FOLDER}")
    return data[0]["sha"], data[0]["commit"]["committer"]["date"]


class _LibDCBuildError(RuntimeError):
    """The downloaded sources did not compile (remembered so the same commit is not rebuilt)."""


def _host_arch():
    import platform
    return "arm64" if platform.machine() in ("arm64", "aarch64") else "x86_64"


def _libdc_download_and_build(sha, log):
    """Download the fork at `sha`, keep its libdivecomputer folder, and compile it."""
    import io, shutil, subprocess, tempfile, zipfile
    url = f"https://codeload.github.com/{LIBDC_REPO}/zip/{sha}"
    log(f"  Downloading {LIBDC_REPO}@{sha[:10]} ({LIBDC_FOLDER}/) …")
    archive = zipfile.ZipFile(io.BytesIO(_http_get(url)))
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        prefix = None
        for name in archive.namelist():
            parts = name.split("/", 2)
            if len(parts) >= 2 and parts[1] == LIBDC_FOLDER:
                prefix = parts[0] + "/" + LIBDC_FOLDER + "/"
                break
        if prefix is None:
            raise RuntimeError(f"{LIBDC_FOLDER}/ not found in the downloaded archive")
        src_root = tmp / LIBDC_FOLDER
        for name in archive.namelist():
            if name.startswith(prefix) and not name.endswith("/"):
                dest = src_root / name[len(prefix):]
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(archive.read(name))
        if not (src_root / "include" / "libdivecomputer" / "version.h").exists():
            raise RuntimeError("include/libdivecomputer/version.h missing from the fork")

        cc = shutil.which("cc")
        if cc is None:
            raise RuntimeError("no C compiler found — install the Xcode command-line tools "
                               "with: xcode-select --install")
        sources = sorted(str(p) for p in (src_root / "src").glob("*.c")
                         if not p.name.endswith("_win32.c"))
        dylib_tmp = tmp / "libdivecomputer.dylib"
        # Same defines as the fork's Package.swift; built for the running Python's architecture.
        cmd = [cc, "-O2", "-w", "-dynamiclib", "-arch", _host_arch(),
               "-DHAVE_PTHREAD_H", "-DENABLE_LOGGING",
               "-I", str(src_root / "include"), "-I", str(src_root / "include" / "libdivecomputer"),
               "-I", str(src_root / "src"), *sources,
               "-install_name", "@rpath/libdivecomputer.dylib", "-o", str(dylib_tmp)]
        log(f"  Compiling {len(sources)} libdivecomputer source files with {cc} …")
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            raise _LibDCBuildError("compilation failed:\n" + (proc.stderr or proc.stdout)[-2000:])

        LIBDC_CACHE.mkdir(parents=True, exist_ok=True)
        cached_src = LIBDC_CACHE / LIBDC_FOLDER
        if cached_src.exists():
            shutil.rmtree(cached_src)
        shutil.copytree(src_root, cached_src)
        # Replace the cached library with a new file (never rewrite it in place: macOS can
        # reject a signed library whose file was modified after it was first loaded).
        staged = LIBDC_CACHE / "libdivecomputer.dylib.new"
        shutil.copy2(dylib_tmp, staged)
        os.replace(staged, LIBDC_CACHE / "libdivecomputer.dylib")


def setup_libdivecomputer(log):
    """
    Return a LibDCWorker decoder, or None when the library cannot be obtained (raw data is
    then not decoded and the export behaves as without it). Downloads and builds the fork's
    libdivecomputer folder when there is no cached build for this architecture or the fork
    has a newer commit. A commit whose sources failed to compile is not retried.
    """
    meta_path   = LIBDC_CACHE / "libdivecomputer.json"
    failed_path = LIBDC_CACHE / "libdivecomputer-failed.json"
    dylib       = LIBDC_CACHE / "libdivecomputer.dylib"
    arch        = _host_arch()
    cached = None
    if meta_path.exists() and dylib.exists():
        try:
            cached = json.loads(meta_path.read_text())
        except Exception:
            cached = None
    if not (isinstance(cached, dict) and isinstance(cached.get("sha"), str)
            and isinstance(cached.get("date"), str)):
        cached = None   # missing or malformed notes: treated as no cached copy
    if cached and cached.get("arch") != arch:
        cached = None   # built for another architecture (or by an older script version)
    log(f"libdivecomputer (raw dive computer data decoder) — source: "
        f"https://github.com/{LIBDC_REPO}/tree/{LIBDC_BRANCH}/{LIBDC_FOLDER}")
    if cached:
        log(f"  Cached copy   : {cached['sha'][:10]}  ({cached['date']}, {arch})  in {LIBDC_CACHE}")
    else:
        log(f"  Cached copy   : none for {arch}")

    try:
        sha, date = _libdc_latest_commit()
        log(f"  Online version: {sha[:10]}  ({date})")
        failed = None
        if failed_path.exists():
            try:
                failed = json.loads(failed_path.read_text())
            except Exception:
                failed = None
            if not isinstance(failed, dict):
                failed = None
        if cached and cached["sha"] == sha:
            log("  Cached copy is up to date.")
        elif failed and failed.get("sha") == sha and failed.get("arch") == arch:
            raise RuntimeError(f"commit {sha[:10]} failed to compile on a previous run "
                               f"(delete {failed_path} to retry)")
        else:
            log("  Online version is newer — downloading." if cached else "  Downloading.")
            try:
                _libdc_download_and_build(sha, log)
            except _LibDCBuildError:
                LIBDC_CACHE.mkdir(parents=True, exist_ok=True)
                failed_path.write_text(json.dumps({"sha": sha, "arch": arch}))
                raise
            meta_path.write_text(json.dumps({"sha": sha, "date": date, "arch": arch,
                                             "built": datetime.now().astimezone().isoformat()}))
            if failed_path.exists():
                failed_path.unlink()
            cached = {"sha": sha, "date": date}
            log(f"  Built {dylib}")
    except Exception as exc:
        if cached:
            log(f"  Warning: could not check or update the online version ({exc}) — "
                f"using the cached copy {cached['sha'][:10]}.")
        else:
            log(f"  Warning: libdivecomputer unavailable ({exc}) — raw dive computer data "
                f"will not be decoded; profiles come from the MacDive XML only.")
            return None

    try:
        worker = LibDCWorker(str(dylib))
    except Exception as exc:
        log(f"  Warning: could not load {dylib} ({exc}) — raw dive computer data will not be decoded.")
        return None
    log(f"  Loaded libdivecomputer {worker.version}  ({worker.descriptor_count} dive computer models; "
        f"decoding runs in a separate process)")
    return worker


class LazyLibDC:
    """
    Sets libdivecomputer up (online check, download/build, worker start) only when the first
    dive with raw data is decoded, so a logbook without raw data never touches the network.
    """

    def __init__(self, log):
        self.log = log
        self.worker = None
        self.started = False

    def decode(self, raw, computer, rawdate, check=None):
        if raw and not isinstance(raw, (bytes, bytearray, memoryview)):
            return None, "raw data stored as text (TEXT affinity) — not decodable"
        if not self.started:
            self.started = True
            self.worker = setup_libdivecomputer(self.log)
        if self.worker is None:
            return None, "libdivecomputer unavailable"
        return self.worker.decode(raw, computer, rawdate, check)


def _shearwater_decompress(data):
    """Undo Shearwater's download compression (9-bit LRE + 32-byte XOR), as libdivecomputer's
    shearwater_common download does before parsing. MacDive stores the compressed stream."""
    buf = bytes(data) + b"\x00\x00"
    nbits = (len(buf) - 2) * 8
    offset, out = 0, bytearray()
    while offset + 9 <= nbits:
        byte, bit = offset // 8, offset % 8
        value = ((buf[byte] << 8 | buf[byte + 1]) >> (16 - (bit + 9))) & 0x1FF
        if value & 0x100:
            out.append(value & 0xFF)
        elif value == 0:
            break
        else:
            out += bytes(value)
        offset += 9
    for i in range(32, len(out)):
        out[i] ^= out[i - 32]
    return bytes(out)


def _merge_depthless_records(samples):
    """
    Fold records without a depth (event-only records some computers send at their own time,
    e.g. Suunto EON Steel, or data reported before the first time sample) into the record with
    a depth nearest in time (the earlier one on a tie), so the gas, events, deco, pressures and
    PPO₂ they carry are kept. Gas and deco state: the latest report wins. Other values: the
    target record's own values win.
    """
    out = [r for r in samples if "depth" in r]
    if not out:
        return out
    times = [r["time"] for r in out]
    # Gas and deco state: the latest report wins (as the app's Bluetooth import keeps the
    # last gas of a group), so a switch arriving just after a sample is not lost. Each group
    # keeps its own report time and is always taken whole from one record.
    # NDL and a deco stop are one deco state in libdivecomputer: a later report of either
    # replaces the other.
    groups = {"gasmix": ("gasmix",), "deco": ("ndl_secs", "deco_depth", "deco_time")}
    key_group = {k: g for g, keys in groups.items() for k in keys}
    def fold(target, rec):
        times_by_group = target.setdefault("_state_times", {})
        for g, keys in groups.items():
            if not any(k in rec for k in keys):
                continue
            owner = times_by_group.get(g, target["time"] if any(k in target for k in keys) else None)
            if owner is None or rec["time"] >= owner:
                for k in keys:
                    if k in rec:
                        target[k] = rec[k]
                    else:
                        target.pop(k, None)
                times_by_group[g] = rec["time"]
        for k, v in rec.items():
            if k == "events":
                target["events"].extend(e for e in v if e not in target["events"])
            elif k in ("pressures", "sensors"):
                merged = dict(v)
                merged.update(target.get(k) or {})
                target[k] = merged
            elif k != "time" and k not in key_group and k not in target:
                target[k] = v
    for rec in samples:
        if "depth" in rec:
            continue
        fold(out[_nearest_index(times, rec["time"])], rec)
    for r in out:
        r.pop("_state_times", None)
    return out


def _norm_model(s):
    s = re.sub(r"[^a-z0-9]+", " ", (s or "").lower()).strip()
    return re.sub(r"\bii\b", "2", re.sub(r"\biii\b", "3", s))


class LibDC:
    """ctypes wrapper around the parts of libdivecomputer's parser API used for ZRAWDATA."""

    def __init__(self, path):
        import ctypes as C
        self.C = C
        self._descriptor_cache = {}   # normalised computer name → matching descriptors
        lib = C.CDLL(path)
        self.lib = lib

        class Location(C.Structure):
            _fields_ = [("latitude", C.c_double), ("longitude", C.c_double), ("altitude", C.c_double)]
        class Pressure(C.Structure):
            _fields_ = [("tank", C.c_uint), ("value", C.c_double)]
        class Event(C.Structure):
            _fields_ = [("type", C.c_uint), ("time", C.c_uint), ("flags", C.c_uint), ("value", C.c_uint)]
        class Vendor(C.Structure):
            _fields_ = [("type", C.c_uint), ("size", C.c_uint), ("data", C.c_void_p)]
        class PPO2(C.Structure):
            _fields_ = [("sensor", C.c_uint), ("value", C.c_double)]
        class Deco(C.Structure):
            _fields_ = [("type", C.c_uint), ("time", C.c_uint), ("depth", C.c_double), ("tts", C.c_uint)]
        class SampleValue(C.Union):
            _fields_ = [("time", C.c_uint), ("depth", C.c_double), ("pressure", Pressure),
                        ("temperature", C.c_double), ("event", Event), ("rbt", C.c_uint),
                        ("heartbeat", C.c_uint), ("bearing", C.c_uint), ("vendor", Vendor),
                        ("setpoint", C.c_double), ("ppo2", PPO2), ("cns", C.c_double),
                        ("deco", Deco), ("gasmix", C.c_uint), ("location", Location)]
        class GasMix(C.Structure):
            _fields_ = [("helium", C.c_double), ("oxygen", C.c_double),
                        ("nitrogen", C.c_double), ("usage", C.c_int)]
        class Tank(C.Structure):
            _fields_ = [("gasmix", C.c_uint), ("type", C.c_int), ("volume", C.c_double),
                        ("workpressure", C.c_double), ("beginpressure", C.c_double),
                        ("endpressure", C.c_double), ("usage", C.c_int)]
        self.GasMix = GasMix
        self.Tank = Tank
        self.Callback = C.CFUNCTYPE(None, C.c_int, C.POINTER(SampleValue), C.c_void_p)

        vp = C.c_void_p
        lib.dc_version.restype = C.c_char_p
        lib.dc_context_new.argtypes = [C.POINTER(vp)]
        lib.dc_context_set_loglevel.argtypes = [vp, C.c_int]
        lib.dc_descriptor_iterator_new.argtypes = [C.POINTER(vp), vp]
        lib.dc_iterator_next.argtypes = [vp, vp]
        lib.dc_iterator_free.argtypes = [vp]
        for fn in ("dc_descriptor_get_vendor", "dc_descriptor_get_product"):
            getattr(lib, fn).argtypes = [vp]
            getattr(lib, fn).restype = C.c_char_p
        lib.dc_parser_new2.argtypes = [C.POINTER(vp), vp, vp, C.c_char_p, C.c_size_t]
        lib.dc_parser_get_field.argtypes = [vp, C.c_int, C.c_uint, vp]
        lib.dc_parser_samples_foreach.argtypes = [vp, self.Callback, vp]
        lib.dc_parser_destroy.argtypes = [vp]

        self.version = lib.dc_version(None).decode()
        self.ctx = vp()
        if lib.dc_context_new(C.byref(self.ctx)) != 0:
            raise RuntimeError("dc_context_new failed")
        lib.dc_context_set_loglevel(self.ctx, 0)   # DC_LOGLEVEL_NONE

        # Descriptors are kept for the lifetime of the process (never freed).
        self.descriptors = []   # (vendor, product, pointer)
        it = vp()
        lib.dc_descriptor_iterator_new(C.byref(it), self.ctx)
        while True:
            d = vp()
            if lib.dc_iterator_next(it, C.byref(d)) != 0:
                break
            self.descriptors.append((lib.dc_descriptor_get_vendor(d).decode(),
                                     lib.dc_descriptor_get_product(d).decode(), d))
        lib.dc_iterator_free(it)
        self.descriptor_count = len(self.descriptors)

    def _find(self, vendor, product):
        for v, p, d in self.descriptors:
            if v.lower() == vendor.lower() and p.lower() == product.lower():
                return (v, p, d)
        return None

    def _descriptors_for(self, computer):
        """Descriptors whose name matches MacDive's computer name, best first (cached per name)."""
        name = _norm_model(computer)
        if not name:
            return []
        if name not in self._descriptor_cache:
            self._descriptor_cache[name] = self._match_descriptors(name)
        return self._descriptor_cache[name]

    def _match_descriptors(self, name):
        exact, partial = [], []
        for v, p, d in self.descriptors:
            full, prod = _norm_model(f"{v} {p}"), _norm_model(p)
            if name == full or name == prod:
                exact.append((v, p, d))
            elif name.endswith(" " + prod) and _norm_model(v) in name:
                partial.append((v, p, d))
        found = exact or partial
        # MacDive stores every Shearwater download in the Petrel (PNF) format, including
        # the Predator's, so the Petrel parser is the fallback for any Shearwater name.
        if any(v == "Shearwater" for v, _, _ in found) or name.startswith("shearwater"):
            petrel = self._find("Shearwater", "Petrel")
            if petrel and petrel not in found:
                found.append(petrel)
        return found

    def _parse(self, desc, data):
        C, lib = self.C, self.lib
        parser = C.c_void_p()
        if lib.dc_parser_new2(C.byref(parser), self.ctx, desc, data, len(data)) != 0:
            return None
        try:
            samples, cur = [], {}
            state = {"setpoint": None, "sp_changes": 0}

            def cb(stype, value_p, _ud):
                v = value_p.contents
                nonlocal cur
                if stype == _DC_SAMPLE_TIME:
                    cur = {"time": v.time / 1000.0, "events": []}
                    samples.append(cur)
                    return
                if not samples:
                    cur = {"time": 0.0, "events": []}
                    samples.append(cur)
                if stype == _DC_SAMPLE_DEPTH:
                    cur["depth"] = v.depth
                elif stype == _DC_SAMPLE_TEMPERATURE:
                    cur["temperature"] = v.temperature
                # A pressure or PPO₂ of 0 means no data (no transmitter / sensor), as on the
                # MacDive XML path; it is not recorded.
                elif stype == _DC_SAMPLE_PRESSURE:
                    if v.pressure.value > 0:
                        cur.setdefault("pressures", {})[v.pressure.tank] = v.pressure.value
                elif stype == _DC_SAMPLE_PPO2:
                    if v.ppo2.value <= 0:
                        return                              # 0 = no sensor data
                    if v.ppo2.sensor == _DC_SENSOR_NONE:
                        cur["ppo2"] = v.ppo2.value          # voted / controller value
                    else:
                        cur.setdefault("sensors", {})[v.ppo2.sensor] = v.ppo2.value
                elif stype == _DC_SAMPLE_DECO:
                    # NDL and a mandatory stop are one deco state: the later report replaces
                    # the other, also within one time sample.
                    if v.deco.type == _DC_DECO_NDL:
                        cur["ndl_secs"] = v.deco.time
                        cur.pop("deco_depth", None)
                        cur.pop("deco_time", None)
                    elif v.deco.type == _DC_DECO_DECOSTOP:
                        # Mandatory stop: required stop depth (m) and remaining time there (s).
                        cur["deco_depth"] = v.deco.depth
                        cur["deco_time"] = v.deco.time
                        cur.pop("ndl_secs", None)
                elif stype == _DC_SAMPLE_GASMIX:
                    if v.gasmix != _DC_GASMIX_UNKNOWN:
                        cur["gasmix"] = v.gasmix
                elif stype == _DC_SAMPLE_SETPOINT:
                    if state["setpoint"] is not None and v.setpoint != state["setpoint"]:
                        state["sp_changes"] += 1
                    state["setpoint"] = v.setpoint
                elif stype == _DC_SAMPLE_EVENT:
                    kind = _LIBDC_EVENT_MAP.get(v.event.type)
                    if kind and kind not in cur["events"]:
                        cur["events"].append(kind)

            callback = self.Callback(cb)
            if lib.dc_parser_samples_foreach(parser, callback, None) != 0:
                return None
            samples = _merge_depthless_records(samples)
            depths = [s["depth"] for s in samples]
            if not depths:
                return None
            n_mix = C.c_uint(0)
            lib.dc_parser_get_field(parser, _DC_FIELD_GASMIX_COUNT, 0, C.byref(n_mix))
            gasmixes = []
            for i in range(n_mix.value):
                gm = self.GasMix()
                if lib.dc_parser_get_field(parser, _DC_FIELD_GASMIX, i, C.byref(gm)) == 0:
                    gasmixes.append((round(gm.oxygen * 100), round(gm.helium * 100)))
                else:
                    gasmixes.append(None)
            mode = C.c_int(-1)
            lib.dc_parser_get_field(parser, _DC_FIELD_DIVEMODE, 0, C.byref(mode))
            # Dive-level values the computer recorded (None when the parser has no such field).
            divetime, maxdepth = C.c_uint(0), C.c_double(0)
            has_divetime = lib.dc_parser_get_field(parser, _DC_FIELD_DIVETIME, 0, C.byref(divetime)) == 0
            has_maxdepth = lib.dc_parser_get_field(parser, _DC_FIELD_MAXDEPTH, 0, C.byref(maxdepth)) == 0
            n_tank, raw_tanks = C.c_uint(0), []
            if lib.dc_parser_get_field(parser, _DC_FIELD_TANK_COUNT, 0, C.byref(n_tank)) == 0:
                for i in range(n_tank.value):
                    tk = self.Tank()
                    if lib.dc_parser_get_field(parser, _DC_FIELD_TANK, i, C.byref(tk)) == 0:
                        raw_tanks.append({"gasmix": tk.gasmix, "begin": tk.beginpressure,
                                          "end": tk.endpressure})
            return {
                "divetime":    divetime.value if has_divetime and divetime.value > 0 else None,
                "dc_maxdepth": maxdepth.value if has_maxdepth and maxdepth.value > 0 else None,
                "tanks":       raw_tanks,
                "samples":     samples,
                "gasmixes":    gasmixes,
                "divemode":    _DC_DIVEMODES.get(mode.value, "unknown"),
                "max_depth":   max(depths),
                "span":        max(s["time"] for s in samples),
                "sp_changes":  state["sp_changes"],
            }
        finally:
            lib.dc_parser_destroy(parser)

    def decode(self, raw, computer, rawdate, check=None):
        """
        Decode MacDive ZRAWDATA. Returns (result, None) or (None, reason).
        `result` adds "model" (the libdivecomputer descriptor that decoded it). `check` is
        (reference name, max depth in metres, span in seconds) — see raw_agrees: each
        descriptor/data candidate that parses is checked against it, and the first that
        agrees is returned, so a candidate that parses into the wrong dive does not hide a
        later correct one.
        """
        if not raw:
            return None, "no raw dive computer data"
        raw = bytes(raw)   # TEXT-affinity values are refused by LibDCWorker.decode
        descs = self._descriptors_for(computer)
        if not descs:
            return None, f"computer '{computer or '(none)'}' not supported by libdivecomputer"
        variants = []
        if raw[:4] == b"SBEM":
            # Suunto EON Steel/Core dive file: libdivecomputer's download prepends the
            # dive's 32-bit timestamp before handing the file to the parser.
            ts = int(float(rawdate) + 978307200) if rawdate is not None else 0
            variants.append(struct.pack("<I", ts & 0xFFFFFFFF) + raw)
        if any(v == "Shearwater" for v, _, _ in descs):
            variants.append(_shearwater_decompress(raw))
        variants.append(raw)
        first_rejection = None
        for v, p, d in descs:
            for data in variants:
                res = self._parse(d, data)
                if not res:
                    continue
                if check is not None:
                    ok, why = raw_agrees(res, *check)
                    if not ok:
                        first_rejection = first_rejection or why
                        continue
                res["model"] = f"{v} {p}"
                return res, None
        if first_rejection:
            return None, first_rejection
        return None, f"libdivecomputer could not decode the raw data (tried {', '.join(f'{v} {p}' for v, p, _ in descs)})"


def _libdc_worker_main(dylib_path):
    """
    Decoding worker (run as: macdive_to_bluedive.py --libdc-worker <dylib>). libdivecomputer
    runs here, not in the export process, so a crash in its native code ends only this
    process. Protocol: length-prefixed pickles on stdin/stdout.
    """
    import pickle
    # Replies go through a private copy of stdout; the process's own stdout (fd 1) is sent to
    # /dev/null so output from the native library can never corrupt the reply stream.
    out = os.fdopen(os.dup(1), "wb")
    devnull = os.open(os.devnull, os.O_WRONLY)
    os.dup2(devnull, 1)
    os.close(devnull)
    def send(obj):
        data = pickle.dumps(obj, protocol=pickle.HIGHEST_PROTOCOL)
        out.write(struct.pack("<I", len(data)) + data)
        out.flush()
    try:
        lib = LibDC(dylib_path)
    except Exception as exc:
        send({"error": str(exc)})
        return
    send({"version": lib.version, "descriptors": lib.descriptor_count})
    inp = sys.stdin.buffer
    while True:
        head = inp.read(4)
        if len(head) < 4:
            return
        raw, computer, rawdate, check = pickle.loads(inp.read(struct.unpack("<I", head)[0]))
        try:
            send(lib.decode(raw, computer, rawdate, check))
        except Exception as exc:
            send((None, f"decoding error: {exc}"))


_ACTIVE_WORKERS: set = set()   # LibDCWorker instances still running, closed by export_dives


class LibDCWorker:
    """
    Runs LibDC in a child process. If libdivecomputer crashes (or hangs past
    _LIBDC_DECODE_TIMEOUT) on a dive, that dive is reported as not decodable and a new
    worker is started for the next one.
    """

    _MAX_FAILURES_PER_MODEL = 2   # crashes/hangs on one computer model before it is skipped

    def __init__(self, dylib_path):
        self.dylib_path = dylib_path
        self.proc = None
        self.failures = {}       # computer name → crashes/hangs so far
        self.disabled = None     # reason, once the worker cannot be restarted
        hello = self._start()
        _ACTIVE_WORKERS.add(self)
        self.version = hello["version"]
        self.descriptor_count = hello["descriptors"]

    def _start(self):
        import subprocess
        self.proc = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "--libdc-worker", self.dylib_path],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        hello = self._recv(_LIBDC_DECODE_TIMEOUT)
        if hello is None or "error" in hello:
            self._stop()
            raise RuntimeError(hello["error"] if hello else "decoding worker did not start")
        return hello

    def _stop(self):
        if self.proc is not None:
            try:
                self.proc.kill()
                self.proc.wait(timeout=5)
            except Exception:
                pass
            self.proc = None

    def _recv(self, timeout):
        """Read one length-prefixed pickle; None on EOF or timeout."""
        import pickle, select, time
        fd = self.proc.stdout.fileno()
        deadline = time.monotonic() + timeout
        def read_exact(n):
            buf = b""
            while len(buf) < n:
                left = deadline - time.monotonic()
                if left <= 0 or not select.select([fd], [], [], left)[0]:
                    return None
                chunk = os.read(fd, n - len(buf))
                if not chunk:
                    return None
                buf += chunk
            return buf
        head = read_exact(4)
        if head is None:
            return None
        size = struct.unpack("<I", head)[0]
        if size > 256 * 1024 * 1024:
            self.corrupt_reply = True    # framing out of sync (stray output from the worker)
            return None
        body = read_exact(size)
        if body is None:
            return None
        try:
            return pickle.loads(body)
        except Exception:
            self.corrupt_reply = True    # corrupt reply: handled like a crash on this dive
            return None

    def decode(self, raw, computer, rawdate, check=None):
        import pickle
        if raw and not isinstance(raw, (bytes, bytearray, memoryview)):
            return None, "raw data stored as text (TEXT affinity) — not decodable"
        if self.disabled:
            return None, self.disabled
        if self.failures.get(computer, 0) >= self._MAX_FAILURES_PER_MODEL:
            return None, (f"skipped — libdivecomputer crashed or hung "
                          f"{self._MAX_FAILURES_PER_MODEL} times on '{computer}'")
        if self.proc is None:
            try:
                self._start()
            except Exception as exc:
                self.disabled = f"libdivecomputer worker could not be restarted ({exc}) — raw decoding off"
                return None, self.disabled
        data = pickle.dumps((bytes(raw) if raw else raw, computer, rawdate, check),
                            protocol=pickle.HIGHEST_PROTOCOL)
        self.corrupt_reply = False
        try:
            self.proc.stdin.write(struct.pack("<I", len(data)) + data)
            self.proc.stdin.flush()
            result = self._recv(_LIBDC_DECODE_TIMEOUT)
        except (BrokenPipeError, OSError):
            result = None
        if result is not None:
            return result
        # The worker crashed or hung on this dive: report it and start afresh next time.
        alive = self.proc.poll() is None
        code = self.proc.returncode
        self._stop()
        self.failures[computer] = self.failures.get(computer, 0) + 1
        if self.corrupt_reply:
            return None, "libdivecomputer worker sent a corrupt reply for this dive (restarted)"
        if alive:
            return None, f"libdivecomputer did not finish within {_LIBDC_DECODE_TIMEOUT} s (stopped)"
        return None, (f"libdivecomputer crashed decoding this dive"
                      + (f" (signal {-code})" if code is not None and code < 0 else ""))

    def close(self):
        _ACTIVE_WORKERS.discard(self)
        if self.proc is not None:
            try:
                self.proc.stdin.close()
                self.proc.wait(timeout=5)
            except Exception:
                pass
            self._stop()


def raw_has_gas_data(decoded):
    """True when the computer reported its active gas (DC_SAMPLE_GASMIX) in the raw data."""
    return any(s.get("gasmix") is not None for s in decoded["samples"])


def raw_events(decoded, tanks):
    """
    Events from a decoded raw dive as [(time, event | None, tank_index | None)].
    A gas reported on the first sample is the starting gas: it sets the active tank without
    an event. Every later change of gas — including a first report later in the dive, from
    computers that report the gas only when it changes — is a gasChange.
    """
    events, prev = [], None
    first_time = decoded["samples"][0]["time"] if decoded["samples"] else None
    for s in decoded["samples"]:
        for kind in s["events"]:
            events.append((s["time"], kind, None))
        g = s.get("gasmix")
        if g is not None and g != prev:
            mix = decoded["gasmixes"][g] if g < len(decoded["gasmixes"]) else None
            initial = prev is None and s["time"] == first_time
            events.append((s["time"], None if initial else "gasChange", _tank_for_mix(mix, tanks)))
            prev = g
    return events


def merge_events(raw_evs, macdive_evs, raw_has_gas, window=30):
    """
    Raw events plus MacDive's own events. When the raw data reports the active gas, gas
    switches come from it only; otherwise MacDive's gas switches are kept. Any other MacDive
    event is dropped when the raw data has the same event within `window` seconds (MacDive
    built its list from the same download, and also reports warnings libdivecomputer does not).
    """
    merged = list(raw_evs)
    for t, kind, idx in macdive_evs:
        if kind == "gasChange" and raw_has_gas:
            continue
        if any(rk == kind and abs(rt - t) <= window for rt, rk, _ in raw_evs):
            continue
        merged.append((t, kind, idx))
    return merged


def raw_deco_stops(decoded):
    """
    Mandatory decompression stops from a decoded raw dive as [(depth_m, seconds)], deepest
    first — the same rule as the app's Bluetooth import (extractDecoStops): one stop per
    depth (rounded to the metre), with the longest remaining time the computer reported there.
    """
    stops: dict = {}
    for s in decoded["samples"]:
        depth, secs = s.get("deco_depth"), s.get("deco_time")
        if not depth or not secs or depth <= 0 or secs <= 0:
            continue
        key = round(depth)
        if key not in stops or secs > stops[key][1]:
            stops[key] = (depth, secs)
    return sorted(stops.values(), key=lambda st: -st[0])


def raw_is_deco(decoded):
    """
    The computer's decompression status, by the app's Bluetooth import rule (hadDecoObligation):
    True when it reported a mandatory deco stop (any DC_DECO_DECOSTOP sample, as the app's
    `decoStop != nil`) or a deco-stop event; False when it reported deco status (NDL samples)
    but never an obligation; None when the raw data carries no deco information (MacDive's
    flag is kept).
    """
    samples = decoded["samples"]
    if any("deco_depth" in s or "decoStop" in s["events"] for s in samples):
        return True
    if any("ndl_secs" in s for s in samples):
        return False
    return None


def raw_tank_mix_ok(decoded, raw_i, tank):
    """False only when the computer names a gas for raw tank `raw_i` that differs from the tank's mix."""
    records = decoded.get("tanks") or []
    if raw_i >= len(records):
        return True
    g = records[raw_i]["gasmix"]
    if g == _DC_GASMIX_UNKNOWN or g >= len(decoded["gasmixes"]) or decoded["gasmixes"][g] is None:
        return True
    return tuple(decoded["gasmixes"][g]) == (tank["o2"], tank["he"])


def map_raw_tanks(decoded, tanks, cvt_press, tolerance, end_time=None):
    """
    One mapping {raw tank index: dive tank index}, used for both the tank start/end pressures
    and the per-sample tank pressures (libdivecomputer's sample pressure.tank is the index into
    its tank list). A raw tank matches a dive tank when its begin pressure equals MacDive's start
    pressure and its reading at MacDive's end time (the computer's end pressure when it has no
    readings) equals MacDive's end pressure, each within `tolerance` (output unit), with the same
    mix when the computer names it. A raw tank matching several dive tanks, or a dive tank
    matched by several raw tanks (e.g. sidemount tanks MacDive logged as one), is not mapped.
    `tanks` must hold MacDive's values. Returns (mapping, {raw index: (start, end)}, series).
    """
    series: dict = {}
    for s in decoded["samples"]:
        for t, v in (s.get("pressures") or {}).items():
            series.setdefault(t, []).append((s["time"], v))
    records = decoded.get("tanks") or []
    values = {}   # raw index → (start, end, end at MacDive's end time) in the output unit
    for i in set(series) | set(range(len(records))):
        rec = records[i] if i < len(records) else None
        readings = series.get(i, [])   # 0 readings (no data) are already dropped by LibDC._parse
        begin = rec["begin"] if rec and rec["begin"] > 0 else (readings[0][1] if readings else None)
        end = rec["end"] if rec and rec["end"] > 0 else (readings[-1][1] if readings else None)
        if begin is None or end is None:
            continue
        at_end = (min(readings, key=lambda x: abs(x[0] - end_time))[1]
                  if readings and end_time else end)
        values[i] = (cvt_press(begin), cvt_press(end), cvt_press(at_end))
    hits_by_raw = {}
    for i, (start, _end, at_end) in values.items():
        hits_by_raw[i] = [k for k, tk in enumerate(tanks)
                          if tk.get("start") is not None and abs(tk["start"] - start) <= tolerance
                          and (tk.get("end") is None or abs(tk["end"] - at_end) <= tolerance)
                          and raw_tank_mix_ok(decoded, i, tk)]
    # Every match counts toward ambiguity: a dive tank matched by several raw tanks (even one
    # that also matched another dive tank) is not mapped, nor is a raw tank matching several.
    claimants: dict = {}
    for i, hits in hits_by_raw.items():
        for k in hits:
            claimants.setdefault(k, []).append(i)
    mapping = {i: hits[0] for i, hits in hits_by_raw.items()
               if len(hits) == 1 and len(claimants[hits[0]]) == 1}
    # One tank, one computer tank with pressures, and MacDive has no pressures for it: they are
    # the same tank (with the same mix when the computer names it).
    if (not mapping and len(values) == 1 and len(tanks) == 1
            and tanks[0].get("start") is None and tanks[0].get("end") is None):
        only = next(iter(values))
        if raw_tank_mix_ok(decoded, only, tanks[0]):
            mapping = {only: 0}
    return mapping, {i: (v[0], v[1]) for i, v in values.items()}, series


def raw_agrees(decoded, ref_name, ref_max_m, ref_span):
    """
    (True, None) when the decoded raw profile is the same dive as the reference — MacDive's
    XML profile, or the dive record when there is none: max depth within 0.5 m, and the raw
    profile not more than 60 s shorter (it may run longer, since MacDive trims the surface
    samples logged after the dive). Else (False, reason).
    """
    if ref_max_m is None:
        return False, f"{ref_name} has no max depth to verify the raw profile against"
    if abs(decoded["max_depth"] - float(ref_max_m)) > 0.5:
        return False, (f"raw max depth {decoded['max_depth']:.1f} m ≠ {ref_name} "
                       f"{float(ref_max_m):.1f} m")
    if ref_span and decoded["span"] < float(ref_span) - 60:
        return False, (f"raw profile {decoded['span']:.0f} s shorter than {ref_name} "
                       f"{float(ref_span):.0f} s")
    return True, None


def merge_xml_pressures(raw_samples, xml_samples, window=2.0):
    """
    For raw samples with no main-tank pressure at all: put MacDive's main-tank pressures on
    the raw samples recorded at the same moment (within `window` seconds) — nothing is copied
    onto other samples. The value goes in the main-tank slot (tankPressure, or per-tank entry
    0 when the sample has per-tank pressures, where BlueDive reads the main pressure).
    Applied only when at least 90 % of MacDive's pressure readings within the raw profile find
    their raw sample, so a shifted timeline is never merged. Not used to fill gaps between the
    computer's own main-tank readings: MacDive fills those moments with another transmitter's
    value. Returns (filled, matched, total) — total = MacDive readings within the raw profile.
    """
    xs = [x for x in xml_samples if x.get("pressure") is not None]
    if not xs or not raw_samples:
        return 0, 0, 0
    times = [r["time"] for r in raw_samples]
    lo, hi = times[0] - window, times[-1] + window
    pairs, total = [], 0
    for x in xs:
        if x["time"] < lo or x["time"] > hi:
            continue
        total += 1
        i = _nearest_index(times, x["time"])
        if abs(times[i] - x["time"]) <= window:
            pairs.append((i, abs(times[i] - x["time"]), x["pressure"]))
    if not total or len(pairs) < 0.9 * total:
        return 0, len(pairs), total
    best = {}                              # raw sample → MacDive reading closest to its moment
    for i, dt, pressure in pairs:
        if i not in best or dt < best[i][0]:
            best[i] = (dt, pressure)
    filled = 0
    for i, (_dt, pressure) in best.items():
        r = raw_samples[i]
        if r.get("tank_pressures"):
            r["tank_pressures"] = {0: pressure, **r["tank_pressures"]}
        else:
            r["pressure"] = pressure
        filled += 1
    return filled, len(pairs), total


def raw_profile_samples(decoded, cvt_depth, cvt_temp, cvt_press, mapping, series):
    """
    Profile samples from a decoded raw dive, in the output units (libdivecomputer reports
    metres, °C and bar). Transmitters mapped to a dive tank (see map_raw_tanks) are written as
    that tank's pressure: as tankPressure when the first tank is the only one mapped,
    otherwise as per-tank pressures. Unmapped transmitters are left out, so the samples and
    the tank values always come from the same tank mapping.
    """
    mapped = {raw_i: k for raw_i, k in mapping.items() if raw_i in series}
    plain = set(mapped.values()) == {0}
    out = []
    for s in decoded["samples"]:
        pressures = s.get("pressures") or {}
        ndl = s.get("ndl_secs")
        sample = {
            "time":        s["time"],
            "depth":       cvt_depth(s["depth"]),
            "temperature": cvt_temp(s["temperature"]) if "temperature" in s else None,
            "pressure":    None,
            "ppo2":        s.get("ppo2"),
            "sensor_ppo2": s.get("sensors"),
            "ndt":         (ndl // 60 if ndl % 60 == 0 else ndl / 60) if ndl is not None else None,
        }
        # Mandatory deco obligation, as the app's Bluetooth import stores it: ceiling in the
        # output distance unit, remaining stop time in minutes, and a decoStop event. A
        # reported zero ceiling is not an obligation.
        if (s.get("deco_depth") or 0) > 0:
            sample["ceiling_depth"] = cvt_depth(s["deco_depth"])
            if s.get("deco_time") is not None:
                sample["ceiling_time"] = s["deco_time"] / 60.0
            sample["events"] = ["decoStop"]
        per_tank = {mapped[t]: cvt_press(v) for t, v in pressures.items() if t in mapped}
        if plain and 0 in per_tank:
            sample["pressure"] = per_tank[0]
        elif per_tank and not plain:
            sample["tank_pressures"] = per_tank
        out.append(sample)
    return out


# ---------------------------------------------------------------------------
# Gear helpers
# ---------------------------------------------------------------------------

def _service_record_fk_col(cur):
    """
    Return the column name in ZSERVICERECORD that is the FK to ZGEARITEM.
    Tries well-known names first, then falls back to any ZRELATIONSHIP* column
    so schema variations across MacDive versions are handled.
    Returns None if nothing is found.
    """
    sc = columns(cur, "ZSERVICERECORD")
    for candidate in ("ZRELATIONSHIPGEARITEM", "ZGEARITEM",
                      "ZRELATIONSHIPITEM", "ZRELGEARITEM",
                      "ZRELATIONSHIPEQUIPMENTITEM", "ZEQUIPMENTITEM"):
        if candidate in sc:
            return candidate
    rel_cols = sorted(c for c in sc if c.startswith("ZRELATIONSHIP"))
    return rel_cols[0] if rel_cols else None


def fetch_service_records_raw(cur, gear_pk):
    """
    Return [{dt: datetime|None, description: str, cost: float|None}] for a gear item.
    Shared source for both JSON serialisation (dive-embedded gear) and XML emission
    (standalone gear export).
    """
    if not table_exists(cur, "ZSERVICERECORD"):
        return []
    sc = columns(cur, "ZSERVICERECORD")
    cost_col  = col_or_null(sc, "ZCOST")
    date_col  = col_or_null(sc, "ZSERVICEDATE", "ZDATE")
    notes_col = col_or_null(sc, "ZNOTES", "ZDESCRIPTION")
    by_col    = col_or_null(sc, "ZSERVICEDBY", "ZTECHNICIAN")
    order_col = date_col if date_col != "NULL" else "Z_PK"
    fk_col = _service_record_fk_col(cur)
    if not fk_col:
        return []
    try:
        cur.execute(f"""
            SELECT {date_col}, {notes_col}, {by_col}, {cost_col}
            FROM ZSERVICERECORD
            WHERE "{fk_col}" = ?
            ORDER BY {order_col} ASC
        """, (gear_pk,))
        rows = cur.fetchall()
    except Exception:
        return []
    records = []
    for svc_ts, notes, svc_by, cost in rows:
        if svc_ts is not None and float(svc_ts) > 0:
            dt = COREDATA_EPOCH + timedelta(seconds=float(svc_ts))
        else:
            dt = None
        parts = [p.strip() for p in [svc_by, notes] if p and p.strip()]
        desc = " — ".join(parts)
        records.append({
            "dt":          dt,
            "description": desc,
            "cost":        round(float(cost), 2) if cost is not None else None,
        })
    return records


def _compute_last_service_date(records):
    """Return the most recent known service date as a local-time string, or '' if none."""
    last_dt = None
    for r in records:
        if r["dt"] is not None:
            if last_dt is None or r["dt"] > last_dt:
                last_dt = r["dt"]
    # Local time because BlueDive's XML DateFormatter uses TimeZone.current (per CLAUDE.md).
    return last_dt.astimezone().strftime("%Y-%m-%d %H:%M:%S") if last_dt else ""



def service_records_xml_lines(records, indent=6):
    """
    Emit service history XML for a gear item — both the standalone gear export and
    dive-embedded gear use this. When records exist, emits a <serviceRecords> block;
    when empty, emits an empty <serviceHistory> fallback that the parser accepts.
    Each record gets a generated UUID because MacDive has no equivalent id field.
    """
    if not records:
        return [xtag("serviceHistory", "", indent=indent)]
    outer_pad = " " * indent
    inner_pad = " " * (indent + 2)
    lines = [f"{outer_pad}<serviceRecords>"]
    for r in records:
        lines.append(f"{inner_pad}<serviceRecord>")
        rec_id   = str(_uuid_mod.uuid4())
        date_str = (r["dt"].astimezone().strftime("%Y-%m-%d %H:%M:%S")
                    if r["dt"] else "0001-01-01 00:00:00")
        is_legacy = "true" if r["dt"] is None else "false"
        lines.append(xtag("id",          rec_id,            indent=indent + 4))
        lines.append(xtag("date",        date_str,          indent=indent + 4))
        lines.append(xtag("description", r["description"],  indent=indent + 4))
        if r["cost"] is not None:
            lines.append(xtag("cost",    f"{r['cost']:.2f}", indent=indent + 4))
        lines.append(xtag("isLegacy",    is_legacy,         indent=indent + 4))
        lines.append(f"{inner_pad}</serviceRecord>")
    lines.append(f"{outer_pad}</serviceRecords>")
    return lines


def load_gear_map(cur):
    """Return {pk: dict} from ZGEARITEM, including per-item service history."""
    if not table_exists(cur, "ZGEARITEM"):
        return {}
    gc = columns(cur, "ZGEARITEM")
    purch_col    = col_or_null(gc, "ZDATEPURCHASE",    "ZDATEPURCHASED")
    price_col    = col_or_null(gc, "ZPRICE",           "ZPURCHASEPRICE")
    next_svc_col = col_or_null(gc, "ZDATENEXTSERVICE", "ZNEXTSERVICEDUE")
    weight_col   = col_or_null(gc, "ZWEIGHT",          "ZWEIGHTCONTRIBUTION")
    diver_fk_col = col_or_null(gc, "ZRELATIONSHIPDIVER", "ZRELATIONSHIPOWNER", "ZDIVER")
    # ZDISABLED=1 → inactive; ZISACTIVE=0 → inactive
    active_col         = col_or_null(gc, "ZDISABLED", "ZISACTIVE")
    active_is_disabled = "ZDISABLED" in gc and "ZISACTIVE" not in gc

    sql = f"""
        SELECT Z_PK,
               {col_or_null(gc, 'ZUUID')},
               ZNAME,
               {col_or_null(gc, 'ZMANUFACTURER')},
               {col_or_null(gc, 'ZMODEL')},
               {col_or_null(gc, 'ZTYPE')},
               {col_or_null(gc, 'ZSERIAL')},
               {purch_col},
               {price_col},
               {col_or_null(gc, 'ZCURRENCY')},
               {col_or_null(gc, 'ZPURCHASEDFROM')},
               {col_or_null(gc, 'ZNOTES')},
               {next_svc_col},
               {active_col},
               {weight_col},
               {diver_fk_col}
        FROM ZGEARITEM
    """
    cur.execute(sql)
    result = {}
    for row in cur.fetchall():
        (pk, uuid, name, mfr, model, gtype, serial,
         purch_ts, price, currency, from_where, notes,
         next_svc_ts, active, weight, diver_fk) = row

        if active_col == "NULL":
            # No active/inactive column in this schema — default to active
            is_inactive = False
        elif active_is_disabled:
            # ZDISABLED=1 means inactive; NULL value defaults to active (0)
            is_inactive = (int(active) if active is not None else 0) == 1
        else:
            # ZISACTIVE=0 means inactive; NULL value defaults to active (1)
            is_inactive = (int(active) if active is not None else 1) == 0

        mfr_str  = (mfr  or "").strip()
        name_str = (name or "").strip()
        # display_name = combined form used for dive-embedded gear (matches Swift parser)
        display_name = f"{mfr_str} {name_str}".strip() if mfr_str else name_str

        svc_records_list = fetch_service_records_raw(cur, pk)

        result[pk] = {
            "uuid":              uuid or "",
            "raw_name":          name_str,       # item name only — used by gear XML export
            "name":              display_name,   # mfr+name combined — used by dive-embedded gear
            "manufacturer":      mfr_str,
            "model":             (model or "").strip(),
            "type":              (gtype or "").strip(),
            "serial":            str(serial or "").strip(),
            "date_purchased":    coredata_to_str(purch_ts) if purch_ts is not None else "",
            "purchase_price":    fmt_double(price) if price is not None else "",
            "currency":          (currency or "").strip(),
            "purchased_from":    (from_where or "").strip(),
            "notes":             (notes or "").strip(),
            "last_service_date": _compute_last_service_date(svc_records_list),
            "next_service_due":  coredata_to_str(next_svc_ts) if next_svc_ts is not None else "",
            "is_inactive":       "true" if is_inactive else "false",
            "service_records":   svc_records_list,
            "weight_raw":          weight,
            "diver_fk":          int(diver_fk) if diver_fk is not None else None,
        }
    return result


def fetch_dive_gear(cur, dive_pk, gear_map, gear_jts):
    """
    Return ALL gear dicts linked to a dive via keyword-hinted junction tables only.

    CoreData assigns Z_PK independently per entity type, so PK=3 for a buddy and
    PK=3 for a gear item can coexist. A fallback that tries every junction table
    would silently return buddy/tag PKs that coincidentally match gear PKs,
    fabricating gear the diver never logged. gear_jts must already be filtered to
    only junctions whose name/columns contain a gear keyword (GEAR, ITEM, EQUIPMENT);
    the caller pre-computes this list once before the dive loop.

    All gear junctions are queried and results merged — some schemas split dive-gear
    links across more than one junction table.
    """
    gear_pks = set(gear_map.keys())
    if not gear_pks:
        return []

    def _query_pks(tbl, dive_col, item_col):
        try:
            cur.execute(
                f'SELECT "{item_col}" FROM "{tbl}" WHERE "{dive_col}" = ?',
                (dive_pk,),
            )
            return [row[0] for row in cur.fetchall() if row[0] in gear_pks]
        except Exception:
            return []

    seen_pks = set()
    result = []
    for tbl, c0, c1 in gear_jts:
        c0u, c1u = c0.upper(), c1.upper()
        if "TODIVE" in c1u:
            orientations = [(c1, c0)]   # c1 is dive FK
        elif "TODIVE" in c0u:
            orientations = [(c0, c1)]   # c0 is dive FK
        elif c1u.endswith("DIVE") or c1u.endswith("DIVES"):
            orientations = [(c1, c0)]   # c1 is dive FK
        elif c0u.endswith("DIVE") or c0u.endswith("DIVES"):
            orientations = [(c0, c1)]   # c0 is dive FK
        else:
            orientations = [(c0, c1), (c1, c0)]  # ambiguous — try both
        for dive_col, item_col in orientations:
            matched_pks = _query_pks(tbl, dive_col, item_col)
            if matched_pks:
                for pk in matched_pks:
                    if pk not in seen_pks:
                        seen_pks.add(pk)
                        result.append(gear_map[pk])
                break  # correct orientation found; continue to next junction
    return result


# ---------------------------------------------------------------------------
# Unit value maps — what BlueDive XML expects in each format field
# ---------------------------------------------------------------------------

DISTANCE_FORMAT = {
    "meters": "meters",
    "feet":   "feet",
}

TEMP_FORMAT = {
    "C": "°C",
    "F": "°F",
}

PRESSURE_FORMAT = {
    "bar": "bar",
    "PSI": "PSI",
}

VOLUME_FORMAT = {
    "liters": "liters",
    "cuft":   "cuft",
}

WEIGHT_FORMAT = {
    "kg":  "kg",
    "lbs": "lbs",
}

# Unit presets auto-detected from the MacDive XML <units> tag.
# Values must be valid keys in the FORMAT dicts above.
MACDIVE_UNIT_PRESETS = {
    "Metric":   {"distance": "meters", "temp": "C", "pressure": "bar", "volume": "liters", "weight": "kg"},
    "Canadian": {"distance": "feet",   "temp": "C", "pressure": "PSI", "volume": "cuft",   "weight": "kg"},
    "Imperial": {"distance": "feet",   "temp": "F", "pressure": "PSI", "volume": "cuft",   "weight": "lbs"},
}


# ---------------------------------------------------------------------------
# MacDive XML sample import  (optional companion for --export dives)
# ---------------------------------------------------------------------------

def parse_macdive_xml_samples(xml_path):
    """
    Parse a MacDive XML export and return a list of dive dicts for sample matching.

    Each dict:
        date_str  – str  'YYYY-MM-DD HH:MM:SS' as exported (local time of source Mac)
        diver     – str  diver name from <diver> element
        duration  – float | None  dive duration in seconds from <duration>
        samples   – list of sample dicts
        gases     – list of gas dicts (from <gases><gas> blocks); may be empty

    Each sample dict:
        time        – float, seconds into the dive
        depth       – float, in the unit MacDive exported
        temperature – float | None  (None when MacDive emits 0.00 = no sensor)
        pressure    – float | None
        ppo2        – float | None
        ndt         – int   | None
    """
    try:
        tree = ET.parse(xml_path)
    except Exception as exc:
        print(f"Error: could not parse MacDive XML '{xml_path}': {exc}", file=sys.stderr)
        sys.exit(1)

    root = tree.getroot()

    units_el  = root.find("units")
    xml_units = (units_el.text or "").strip() if units_el is not None else ""

    result = []

    for dive in root.findall("dive"):
        date_el    = dive.find("date")
        samples_el = dive.find("samples")
        if date_el is None or samples_el is None:
            continue

        date_str = (date_el.text or "").strip()
        if not date_str:
            continue

        diver_el = dive.find("diver")
        dur_el   = dive.find("duration")
        diver    = (diver_el.text or "").strip() if diver_el is not None else ""
        try:
            duration = float(dur_el.text) if dur_el is not None and dur_el.text else None
        except ValueError:
            duration = None

        def _dive_float(tag):
            el = dive.find(tag)
            if el is None or not el.text:
                # Element absent or empty → MacDive had no sensor data for this field.
                return None
            try:
                return float(el.text.strip())
            except ValueError:
                return None

        xml_temp_high = _dive_float("tempHigh")
        xml_temp_low  = _dive_float("tempLow")
        xml_temp_air  = _dive_float("tempAir")

        samples = []
        for s in samples_el.findall("sample"):
            def _f(tag):
                el = s.find(tag)
                if el is not None and el.text:
                    try:
                        return float(el.text.strip())
                    except ValueError:
                        return None
                return None

            time_val  = _f("time")
            depth_val = _f("depth")
            if time_val is None or depth_val is None:
                continue

            pressure = _f("pressure")
            temp     = _f("temperature")
            ppo2     = _f("ppo2")
            ndt_raw  = _f("ndt")

            samples.append({
                "time":        time_val,
                "depth":       depth_val,
                "temperature": temp,
                "pressure":    pressure    if pressure and pressure > 0.0 else None,
                "ppo2":        ppo2        if ppo2     and ppo2     > 0.0 else None,
                "ndt":         int(ndt_raw) if ndt_raw is not None else None,
            })

        # Parse <gases> blocks.
        # pressureStart/pressureEnd are correctly unit-converted by MacDive to the display unit.
        # workingPressure and tankSize are raw SQLite pass-throughs (no unit conversion by MacDive).
        gases = []
        gases_el = dive.find("gases")
        if gases_el is not None:
            for g in gases_el.findall("gas"):
                def _gf(tag):
                    el = g.find(tag)
                    if el is not None and el.text:
                        try:
                            return float(el.text.strip())
                        except ValueError:
                            return None
                    return None
                name_el   = g.find("tankName")
                supply_el = g.find("supplyType")
                def _pct(v, default=None):
                    # MacDive may export O₂/He as fractions (0.21) or percentages (21).
                    # Normalize to integer percent to match fetch_tanks storage.
                    if v is None:
                        return default
                    return round(v * 100) if v <= 1.0 else round(v)
                gases.append({
                    "start":  _gf("pressureStart"),
                    "end":    _gf("pressureEnd"),
                    "o2":     _pct(_gf("oxygen")),  # None when absent; default applied at output time
                    "he":     _pct(_gf("helium")),  # None when absent; default applied at output time
                    "vol":    _gf("tankSize"),
                    "wp":     _gf("workingPressure"),
                    "name":   (name_el.text   or "").strip() if name_el   is not None else "",
                    "supply": (supply_el.text or "").strip() if supply_el is not None else "",
                })

        if samples:
            result.append({
                "date_str":  date_str,
                "diver":     diver,
                "duration":  duration,
                "samples":   samples,
                "gases":     gases,
                "temp_high": xml_temp_high,
                "temp_low":  xml_temp_low,
                "temp_air":  xml_temp_air,
            })

    print(f"  MacDive XML : {len(result)} dives with samples loaded from {xml_path}  (units={xml_units or 'unknown'})")
    return xml_units, result


def _norm_name(n):
    """Casefold, strip accents, collapse whitespace for fuzzy diver-name comparison."""
    n = unicodedata.normalize("NFKD", n or "").encode("ascii", "ignore").decode()
    return " ".join(n.casefold().split())


def _num(v):
    """float(v), or None when v is missing or not numeric (e.g. a TEXT-affinity value)."""
    try:
        return float(v) if v is not None else None
    except (TypeError, ValueError):
        return None


def _durations_agree(xml_dur, sqlite_dur):
    """
    True when the XML <duration> and the SQLite duration are the same value (±2 s rounding).
    Both come from the same MacDive dive record, so the match is confirmed and the profile
    span check is skipped: many computers (Garmin, Shearwater) keep logging surface samples
    for several minutes after the dive ends, making the profile longer than the duration.
    """
    return xml_dur is not None and sqlite_dur is not None and abs(xml_dur - sqlite_dur) <= 2


def _detect_consensus_offset(xml_dives, sqlite_utc_index):
    """
    Return the UTC hour offset that converts the XML's naive local-time dates to UTC.

    Tries every integer offset -12..+12 and picks the one with the most unambiguous
    single-PK hits against the SQLite index.
    """
    best_off, best_hits = 0, -1
    for off in range(-12, 13):
        hits = 0
        for xd in xml_dives:
            try:
                naive = datetime.strptime(xd["date_str"], "%Y-%m-%d %H:%M:%S")
            except ValueError:
                continue
            key = (naive - timedelta(hours=off)).strftime("%Y-%m-%d %H:%M:%S")
            if len({c[0] for c in sqlite_utc_index.get(key, [])}) == 1:
                hits += 1
        # On a tie prefer the offset closest to 0 (most common timezone); the previous
        # offset wins only if it strictly beat the new one OR ties with a larger |off|.
        if hits > best_hits or (hits == best_hits and (abs(off) < abs(best_off) or
                                                        (abs(off) == abs(best_off) and off > best_off))):
            best_hits, best_off = hits, off
    return best_off, best_hits


def match_samples_to_dives(xml_dives, sqlite_utc_index, xml_depth_in_feet=False):
    """
    Match XML dives to SQLite PKs and return {pk: samples}.

    sqlite_utc_index: {utc_str: [(pk, diver_name, duration_secs, max_depth_metres)]}

    Improvements:
      P1 — Consensus UTC offset: detect the single hour offset shared by all dives in
           the XML file and query only that offset ±1 h (for DST/travel), instead of
           the full -12..+12 sweep that creates false-positive ghost candidates.
      P2 — Best-match assignment: collect all resolved (xml_idx, pk, score) tuples and
           assign greedily by ascending score (duration delta then depth delta) so the
           best-matching XML dive wins a contested PK, not the first one in file order.
      P3 — Depth tiebreak + tighter duration: add a max-depth tiebreak (XML sample
           max depth vs SQLite ZMAXDEPTH) before the duration tiebreak; tighten
           duration tolerance to ±30 s and auto-select the closest when it is clearly
           better than the runner-up (gap > 15 s).
      P4 — Normalised diver names: casefold, strip accents, collapse whitespace before
           comparing; relaxed token-containment fallback before falling back to the
           unfiltered pool; warn when the fallback fires.
      P5 — Plausibility gate: verify that the XML profile's max depth and total span
           agree with the SQLite dive within tolerances (5 m depth, 2 min span) before
           committing an assignment; reject and warn on gross mismatch.
      N4 — UTC+0 fallback: if the consensus window finds no candidates, try offset 0
           (XML local time == UTC).  Covers dives recorded while in a UTC+0 timezone or
           on a device left in UTC.  All P4/P3/P5 guards still apply.
    """
    if not xml_dives:
        return {}

    # P1 — resolve the timezone offset once for the whole file.
    # Require at least 2 unambiguous hits before trusting the consensus; with fewer hits the
    # winning offset could simply be the first one tried (0) with a single coincidental match.
    # When confidence is low, warn loudly and fall back to the full -12..+12 sweep so no dive
    # is silently attached to the wrong profile.
    consensus_off, consensus_hits = _detect_consensus_offset(xml_dives, sqlite_utc_index)
    _MIN_CONSENSUS_HITS = 2
    if consensus_hits >= _MIN_CONSENSUS_HITS:
        offsets_to_try = sorted({consensus_off - 1, consensus_off, consensus_off + 1})
        print(f"  Consensus UTC offset : {consensus_off:+d}h  ({consensus_hits} unambiguous hits)"
              f"  (trying offsets {offsets_to_try})")
    else:
        offsets_to_try = list(range(-12, 13))
        print(f"  Warning: low consensus confidence ({consensus_hits} hit(s)) — "
              f"falling back to full offset sweep {offsets_to_try[0]:+d}..{offsets_to_try[-1]:+d}h  "
              f"(profile-to-dive matching may be less accurate)", file=sys.stderr)

    # Convert XML sample depths to metres for comparison against SQLite (always metres).
    depth_factor = 0.3048 if xml_depth_in_feet else 1.0

    # First pass: resolve each XML dive to a single PK and score the match.
    # Each entry: (xml_idx, pk, dur_delta, depth_delta, samples)
    candidates_resolved = []
    unresolved = []  # (xml_idx, reason, date_str)

    for xi, xml_dive in enumerate(xml_dives):
        xml_diver   = xml_dive["diver"]
        xml_dur     = xml_dive["duration"]
        xml_samples = xml_dive["samples"]

        try:
            naive = datetime.strptime(xml_dive["date_str"], "%Y-%m-%d %H:%M:%S")
        except ValueError:
            unresolved.append((xi, "bad_date", xml_dive["date_str"]))
            continue

        # P1 — query only the consensus offset ±1; ±2 s tolerance for clock drift / rounding
        pool_all = []
        for off in offsets_to_try:
            base_dt = naive - timedelta(hours=off)
            for sec_adj in (-2, -1, 0, 1, 2):
                utc_str = (base_dt + timedelta(seconds=sec_adj)).strftime("%Y-%m-%d %H:%M:%S")
                pool_all.extend(sqlite_utc_index.get(utc_str, []))

        # Dedup by pk: the ±2 s window can insert the same SQLite candidate multiple times,
        # which corrupts the positional dur_pool[0]/[1] auto-select comparison.
        seen_pk: set = set()
        deduped = []
        for c in pool_all:
            if c[0] not in seen_pk:
                seen_pk.add(c[0])
                deduped.append(c)
        pool_all = deduped

        if not pool_all and 0 not in offsets_to_try:
            # N4 — UTC+0 fallback: some dives have ZRAWDATE == XML local time (device
            #      left in UTC, or dive made while in a UTC+0 timezone).  Try offset 0
            #      before giving up; all P4/P3/P5 guards still apply downstream.
            for sec_adj in (-2, -1, 0, 1, 2):
                utc_str = (naive + timedelta(seconds=sec_adj)).strftime("%Y-%m-%d %H:%M:%S")
                pool_all.extend(sqlite_utc_index.get(utc_str, []))
            if pool_all:
                seen_utc0: set = set()
                deduped_fb: list = []
                for c in pool_all:
                    if c[0] not in seen_utc0:
                        seen_utc0.add(c[0])
                        deduped_fb.append(c)
                pool_all = deduped_fb
                print(f"  Note: UTC+0 fallback for {xml_dive['date_str']} ({xml_diver})",
                      file=sys.stderr)

        if not pool_all:
            unresolved.append((xi, "no_match", xml_dive["date_str"]))
            continue

        # P4 — normalised diver filter with relaxed fallback
        norm_xml = _norm_name(xml_diver)
        exact    = [c for c in pool_all if _norm_name(c[1]) == norm_xml]
        relaxed  = exact or [c for c in pool_all
                             if norm_xml and norm_xml in _norm_name(c[1])]
        if not relaxed and xml_diver:
            print(f"  Warning: diver '{xml_diver}' not matched in candidates for "
                  f"{xml_dive['date_str']} — using all {len(pool_all)} candidate(s)",
                  file=sys.stderr)
        pool = exact or relaxed or pool_all

        unique_pks = {c[0] for c in pool}

        # P3 — depth tiebreak (convert XML max depth to metres)
        if len(unique_pks) > 1 and xml_samples:
            xml_max_m  = max(s["depth"] for s in xml_samples) * depth_factor
            depth_pool = [c for c in pool
                          if c[3] is not None and abs(c[3] - xml_max_m) <= 2.0]
            if depth_pool:
                pool       = depth_pool
                unique_pks = {c[0] for c in pool}

        # P3 — duration tiebreak: pick closest within ±30 s; auto-select clear winner
        if len(unique_pks) > 1 and xml_dur is not None:
            dur_pool = [c for c in pool
                        if c[2] is not None and abs(c[2] - xml_dur) <= 30]
            if dur_pool:
                dur_pool.sort(key=lambda c: abs(c[2] - xml_dur))
                best_delta   = abs(dur_pool[0][2] - xml_dur)
                second_delta = abs(dur_pool[1][2] - xml_dur) if len(dur_pool) > 1 else 9999
                if second_delta - best_delta > 15:
                    pool = [dur_pool[0]]
                else:
                    pool = dur_pool
                unique_pks = {c[0] for c in pool}

        if len(unique_pks) != 1:
            unresolved.append((xi, "ambiguous", xml_dive["date_str"]))
            continue

        pk = next(iter(unique_pks))
        c  = next(c for c in pool if c[0] == pk)

        # P5 — plausibility gate: depth and sample span must agree with SQLite values
        if xml_samples and c[3] is None and c[2] is None:
            print(f"  Warning: P5 skipped for {xml_dive['date_str']} — no depth or duration in SQLite to verify match",
                  file=sys.stderr)
        if xml_samples and c[3] is not None:
            xml_max_m = max(s["depth"] for s in xml_samples) * depth_factor
            if abs(xml_max_m - c[3]) > 5.0:
                print(f"  Warning: depth mismatch for {xml_dive['date_str']} "
                      f"(xml_max={xml_max_m:.1f} m  sqlite={c[3]:.1f} m) — rejected",
                      file=sys.stderr)
                unresolved.append((xi, "depth_mismatch", xml_dive["date_str"]))
                continue
        if xml_samples and c[2] is not None and not _durations_agree(xml_dur, c[2]):
            xml_span = max(s["time"] for s in xml_samples)
            if abs(xml_span - c[2]) > 120:
                print(f"  Warning: span mismatch for {xml_dive['date_str']} "
                      f"(xml_span={xml_span:.0f} s  sqlite_dur={c[2]:.0f} s) — rejected",
                      file=sys.stderr)
                unresolved.append((xi, "span_mismatch", xml_dive["date_str"]))
                continue

        # Score: (duration_delta, depth_delta) — lower is better.
        # Both c[2] (SQLite ZTOTALDURATION) and xml_dur (XML <duration>) are in seconds.
        dur_delta   = (abs(c[2] - xml_dur)
                       if c[2] is not None and xml_dur is not None else 9999.0)
        depth_delta = (abs(max(s["depth"] for s in xml_samples) * depth_factor - c[3])
                       if xml_samples and c[3] is not None else 9999.0)
        candidates_resolved.append((xi, pk, dur_delta, depth_delta, xml_samples))

    # P2 — greedy best-match assignment: sort by (dur_delta, depth_delta) ascending
    candidates_resolved.sort(key=lambda a: (a[2], a[3]))
    pk_to_samples:   dict = {}
    pk_to_gases:     dict = {}
    pk_to_xml_temps: dict = {}
    for xi, pk, dur_delta, depth_delta, samples in candidates_resolved:
        if pk in pk_to_samples:
            unresolved.append((xi, "outscored", xml_dives[xi]["date_str"]))
            continue
        xd = xml_dives[xi]
        pk_to_samples[pk]   = samples
        pk_to_gases[pk]     = xd.get("gases", [])
        pk_to_xml_temps[pk] = {
            "temp_high": xd.get("temp_high"),
            "temp_low":  xd.get("temp_low"),
            "temp_air":  xd.get("temp_air"),
        }

    # Second pass — retry no_match dives from the narrow-window pass against the full
    # -12..+12 sweep. This recovers dives from a different timezone than the consensus
    # (e.g. a multi-destination dive trip). P4/P3/P5 guards still apply; only genuine
    # matches survive. Skip this pass if we already tried the full sweep in the first pass.
    no_match_indices = [xi for xi, reason, _ in unresolved if reason == "no_match"]
    if no_match_indices and offsets_to_try != list(range(-12, 13)):
        full_sweep = list(range(-12, 13))
        retry_unresolved: list = []
        # Collect all retry candidates first, then greedy-sort by score (same as primary P2),
        # so the best match wins a contested PK rather than the first-in-list.
        retry_candidates: list = []  # (xi, pk, dur_delta, depth_delta, xml_samples, c)
        for xi in no_match_indices:
            xml_dive    = xml_dives[xi]
            xml_diver   = xml_dive["diver"]
            xml_dur     = xml_dive["duration"]
            xml_samples = xml_dive["samples"]
            try:
                naive = datetime.strptime(xml_dive["date_str"], "%Y-%m-%d %H:%M:%S")
            except ValueError:
                retry_unresolved.append((xi, "bad_date", xml_dive["date_str"]))
                continue
            pool_all = []
            for off in full_sweep:
                base_dt = naive - timedelta(hours=off)
                for sec_adj in (-2, -1, 0, 1, 2):
                    utc_str = (base_dt + timedelta(seconds=sec_adj)).strftime("%Y-%m-%d %H:%M:%S")
                    pool_all.extend(sqlite_utc_index.get(utc_str, []))
            seen_pk2: set = set()
            deduped2: list = []
            for c in pool_all:
                if c[0] not in seen_pk2:
                    seen_pk2.add(c[0])
                    deduped2.append(c)
            pool_all = deduped2
            if not pool_all:
                retry_unresolved.append((xi, "no_match", xml_dive["date_str"]))
                continue
            norm_xml = _norm_name(xml_diver)
            exact    = [c for c in pool_all if _norm_name(c[1]) == norm_xml]
            relaxed  = exact or [c for c in pool_all
                                 if norm_xml and norm_xml in _norm_name(c[1])]
            if not relaxed and xml_diver:
                print(f"  Warning: diver '{xml_diver}' not matched in candidates for "
                      f"{xml_dive['date_str']} — using all {len(pool_all)} candidate(s)",
                      file=sys.stderr)
            pool = exact or relaxed or pool_all
            unique_pks = {c[0] for c in pool}
            if len(unique_pks) > 1 and xml_samples:
                xml_max_m  = max(s["depth"] for s in xml_samples) * depth_factor
                depth_pool = [c for c in pool
                              if c[3] is not None and abs(c[3] - xml_max_m) <= 2.0]
                if depth_pool:
                    pool       = depth_pool
                    unique_pks = {c[0] for c in pool}
            if len(unique_pks) > 1 and xml_dur is not None:
                dur_pool = [c for c in pool
                            if c[2] is not None and abs(c[2] - xml_dur) <= 30]
                if dur_pool:
                    dur_pool.sort(key=lambda c: abs(c[2] - xml_dur))
                    best_delta   = abs(dur_pool[0][2] - xml_dur)
                    second_delta = abs(dur_pool[1][2] - xml_dur) if len(dur_pool) > 1 else 9999
                    pool = [dur_pool[0]] if second_delta - best_delta > 15 else dur_pool
                    unique_pks = {c[0] for c in pool}
            if len(unique_pks) != 1:
                retry_unresolved.append((xi, "ambiguous", xml_dive["date_str"]))
                continue
            pk = next(iter(unique_pks))
            c  = next(c for c in pool if c[0] == pk)
            if xml_samples and c[3] is None and c[2] is None:
                print(f"  Warning: P5 skipped for {xml_dive['date_str']} — no depth or duration in SQLite to verify match",
                      file=sys.stderr)
            if xml_samples and c[3] is not None:
                xml_max_m = max(s["depth"] for s in xml_samples) * depth_factor
                if abs(xml_max_m - c[3]) > 5.0:
                    retry_unresolved.append((xi, "depth_mismatch", xml_dive["date_str"]))
                    continue
            if xml_samples and c[2] is not None and not _durations_agree(xml_dur, c[2]):
                xml_span = max(s["time"] for s in xml_samples)
                if abs(xml_span - c[2]) > 120:
                    retry_unresolved.append((xi, "span_mismatch", xml_dive["date_str"]))
                    continue
            dur_delta   = abs(c[2] - xml_dur) if c[2] is not None and xml_dur is not None else 9999.0
            depth_delta = (abs(max(s["depth"] for s in xml_samples) * depth_factor - c[3])
                           if xml_samples and c[3] is not None else 9999.0)
            retry_candidates.append((xi, pk, dur_delta, depth_delta, xml_samples, c))

        # Greedy best-match assignment — same P2 logic as primary pass.
        retry_candidates.sort(key=lambda a: (a[2], a[3]))
        for xi, pk, dur_delta, depth_delta, xml_samples, c in retry_candidates:
            if pk in pk_to_samples:
                retry_unresolved.append((xi, "outscored", xml_dives[xi]["date_str"]))
                continue
            xd = xml_dives[xi]
            pk_to_samples[pk]   = xml_samples
            pk_to_gases[pk]     = xd.get("gases", [])
            pk_to_xml_temps[pk] = {
                "temp_high": xd.get("temp_high"),
                "temp_low":  xd.get("temp_low"),
                "temp_air":  xd.get("temp_air"),
            }
            print(f"  Note: full-sweep retry matched {xd['date_str']} ({xd['diver']})",
                  file=sys.stderr)
        # Replace no_match entries in unresolved with retry outcomes
        unresolved = [(xi, r, d) for xi, r, d in unresolved if r != "no_match"]
        unresolved.extend(retry_unresolved)

    total   = len(xml_dives)
    matched = len(pk_to_samples)
    skipped = len(unresolved)
    print(f"  Samples matched : {matched}/{total} dives  ({skipped} skipped)")
    if unresolved:
        reason_counts: dict = {}
        for _, reason, _ in unresolved:
            reason_counts[reason] = reason_counts.get(reason, 0) + 1
        print("  Skip breakdown  : "
              + "  ".join(f"{k}={v}" for k, v in sorted(reason_counts.items())))
        for xi, reason, date_str in unresolved:
            diver = xml_dives[xi]["diver"]
            print(f"    {reason:<16}  {date_str}  ({diver})", file=sys.stderr)

    return pk_to_samples, pk_to_gases, pk_to_xml_temps


def profile_samples_xml_lines(samples, indent=4):
    """
    Emit a <profileSamples> block in BlueDive XML attribute format.

    time is passed through in seconds (MacDive XML seconds = BlueDive XML seconds).
    Zero-valued sensor fields (temperature, pressure, ppo2, ndt) are already None
    in the sample dicts produced by parse_macdive_xml_samples.
    """
    pad       = " " * indent
    inner_pad = " " * (indent + 2)
    lines = [f'{pad}<profileSamples count="{len(samples)}">']
    for s in samples:
        attrs = [
            f'time="{fmt_double(s["time"])}"',
            f'depth="{fmt_double(s["depth"])}"',
        ]
        if s.get("temperature") is not None:
            attrs.append(f'temperature="{fmt_double(s["temperature"])}"')
        if s.get("pressure") is not None:
            attrs.append(f'tankPressure="{fmt_double(s["pressure"])}"')
        if s.get("tank_pressures"):
            attrs.append('tankPressures="' + ",".join(
                f'{i}:{fmt_double(v)}' for i, v in sorted(s["tank_pressures"].items())) + '"')
        if s.get("ppo2") is not None:
            attrs.append(f'ppo2="{fmt_double(s["ppo2"])}"')
        if s.get("sensor_ppo2"):
            attrs.append('sensorPPO2="' + ",".join(
                f'{i}:{fmt_double(v)}' for i, v in sorted(s["sensor_ppo2"].items())) + '"')
        if s.get("ndt") is not None:
            attrs.append(f'ndl="{s["ndt"]}"')
        if s.get("ceiling_depth") is not None:
            attrs.append(f'ceilingDepth="{fmt_double(s["ceiling_depth"])}"')
        if s.get("ceiling_time") is not None:
            attrs.append(f'ceilingTime="{fmt_double(s["ceiling_time"])}"')
        if s.get("current_gas") is not None:
            attrs.append(f'currentGas="{s["current_gas"]}"')
        attrs.append(f'events="{",".join(s.get("events", []))}"')
        lines.append(f'{inner_pad}<sample {" ".join(attrs)}/>')
    lines.append(f'{pad}</profileSamples>')
    return lines


# ---------------------------------------------------------------------------
# Dive export
# ---------------------------------------------------------------------------

def export_dives(input_path, output_path, weight_unit, macdive_xml_path):
    """Export dives; the libdivecomputer worker is stopped however the export ends."""
    try:
        return _export_dives(input_path, output_path, weight_unit, macdive_xml_path)
    finally:
        for worker in list(_ACTIVE_WORKERS):
            worker.close()


def _export_dives(input_path, output_path, weight_unit, macdive_xml_path):
    _reset_schema_caches()

    # Parse MacDive XML first — distance/temp/pressure/volume are auto-detected from its <units> tag.
    # Weight comes from --weight-unit (the XML <units> tag reflects display preference only;
    # the SQLite stores whatever unit the user entered, which must be confirmed explicitly).
    xml_units, xml_dives = parse_macdive_xml_samples(macdive_xml_path)
    preset = MACDIVE_UNIT_PRESETS.get(xml_units)
    if preset is None:
        print(f"Error: unrecognised MacDive <units> tag '{xml_units}'. "
              f"Expected one of: {', '.join(MACDIVE_UNIT_PRESETS)}.", file=sys.stderr)
        sys.exit(1)
    units = {**preset, "weight": weight_unit}
    # XML sample unit flags.
    # Depth:    Metric exports metres; Canadian / Imperial export feet.
    # Pressure: Canadian / Imperial export PSI; Metric exports bar.
    # Temperature always matches the output temp unit, so no sample-temp conversion is needed.
    xml_depth_in_feet   = xml_units.lower() != "metric"
    xml_pressure_in_psi = xml_units in ("Canadian", "Imperial")
    # SQLite always stores depth in metres and temperature in °C regardless of user preference.
    # Define converters so dive-level values can be output in the correct unit.
    _to_feet = units["distance"] == "feet"
    _to_fahr = units["temp"] == "F"
    def cvt_dist(v): return v * 3.28084 if (v is not None and _to_feet) else v
    def cvt_temp(v): return v * 9.0 / 5.0 + 32.0 if (v is not None and _to_fahr) else v

    # XML temperature converter.
    # MacDive exports temperature in the display unit (°F for Imperial, °C for Metric/Canadian).
    # SQLite stores temperature in °C, but we do not assume this — prefer XML when available.
    _xml_temp_in_fahr = xml_units == "Imperial"

    def cvt_xml_temp(v):
        if v is None:
            return v
        if _xml_temp_in_fahr and not _to_fahr:
            return (v - 32.0) * 5.0 / 9.0   # °F → °C
        if not _xml_temp_in_fahr and _to_fahr:
            return v * 9.0 / 5.0 + 32.0     # °C → °F
        return v

    # Tank pressure / volume converters.
    # MacDive does NOT convert ZTANK.ZWORKINGPRESSURE or ZTANK.ZSIZE when the user changes
    # the unit setting — only ZAIRSTART/ZAIREND (via the XML export) are reliably converted.
    _press_to_bar  = units["pressure"] == "bar"
    _vol_to_liters = units["volume"]   == "liters"

    def cvt_bar_out(v):
        # libdivecomputer reports pressure in bar; convert to the output unit with its own
        # factor (PSI = 6894.75729 Pa), so a pressure the computer recorded in psi round-trips.
        return v if (v is None or _press_to_bar) else v / 0.0689475729

    def cvt_xml_press(v):
        # XML pressureStart/pressureEnd are correctly unit-converted by MacDive to the display
        # unit (PSI for Canadian/Imperial, bar for Metric). Convert to the output unit.
        # 0 is treated as no-data (physically impossible starting/ending pressure).
        if v is None or v == 0:
            return None
        if xml_pressure_in_psi and _press_to_bar:
            return v / 14.5038
        if not xml_pressure_in_psi and not _press_to_bar:
            return v * 14.5038
        return v

    def cvt_press_auto(v):
        # Fallback for SQLite ZAIRSTART/ZAIREND or ZTANK.ZWORKINGPRESSURE when no XML value
        # is available. MacDive stores the raw entered value; >400 = PSI, <=400 = bar.
        # 0 is treated as no-data (physically impossible starting/ending pressure).
        if v is None or v == 0:
            return None
        if v > 400:
            return v / 14.5038 if _press_to_bar else v
        else:
            return v if _press_to_bar else v * 14.5038

    def cvt_vol(v, wp):
        # ZTANK.ZSIZE unit mirrors ZWORKINGPRESSURE: cuft gas-volume when WP>400 (PSI context),
        # litres water-capacity when WP<=400 (bar context).
        if v is None or v == 0:
            return v
        if wp is not None and wp > 400:                        # WP in PSI → ZSIZE is cuft
            if _vol_to_liters:
                return v * 28.3168 / (wp / 14.696)            # cuft-gas → litres-water-capacity
            return v
        elif wp is not None and wp > 0:                        # WP in bar → ZSIZE is litres
            if _vol_to_liters:
                return v
            return v * (wp * 14.5038 / 14.696) / 28.3168      # litres-water → cuft-gas
        else:
            # WP unknown — cannot determine unit or safely convert; emit raw value
            return v

    print(f"  Units auto-detected: distance={units['distance']}  temp={units['temp']}  "
          f"pressure={units['pressure']}  volume={units['volume']}  weight={units['weight']}")

    # libdivecomputer setup is logged on screen and at the top of the log file.
    _header_logs: list = []
    def _hlog(msg):
        print(f"  {msg}")
        _header_logs.append(msg)
    libdc = LazyLibDC(_hlog)   # set up on the first dive with raw data

    con = sqlite3.connect(input_path)
    cur = con.cursor()

    junctions = discover_junctions(cur)

    distance_fmt = DISTANCE_FORMAT[units["distance"]]
    temp_fmt     = TEMP_FORMAT[units["temp"]]
    pressure_fmt = PRESSURE_FORMAT[units["pressure"]]
    volume_fmt   = VOLUME_FORMAT[units["volume"]]
    weight_fmt   = WEIGHT_FORMAT[units["weight"]]

    divers    = load_divers(cur)
    buddies   = load_buddies(cur)
    computers = load_computers(cur)
    sites     = load_sites(cur)
    types_lkp = load_simple(cur, "ZDIVETYPE")
    tags_lkp  = load_simple(cur, "ZTAG")
    gear_map  = load_gear_map(cur)

    buddy_jt   = find_junction(junctions, "BUDDIES",  "DIVE")
    type_jt    = find_junction(junctions, "DIVETYPE", "DIVE")
    tag_jt     = find_junction(junctions, "TAG",      "DIVE")
    # Critter ↔ dive and critter ↔ dive-photo junctions, by their exact name endings
    # (…CRITTERTODIVE / …CRITTERTODIVEIMAGE), so neither can be taken for the other — the
    # photo junction's name also contains CRITTERTODIVE.
    critter_jt = next((j for j in junctions
                       if j[0].upper().endswith(("CRITTERTODIVE", "CRITTERTODIVES"))), None)
    critter_image_jt = next((j for j in junctions
                             if j[0].upper().endswith(("CRITTERTODIVEIMAGE", "CRITTERTODIVEIMAGES"))), None)
    # Fallback for schemas that name the junction after the other side (…DIVETOCRITTER):
    # a column pointing to critters plus one pointing to dives (or dive photos).
    def _critter_jt_by_columns(want_image):
        ends = ("TODIVEIMAGE", "TODIVEIMAGES") if want_image else ("TODIVE", "TODIVES")
        for j in junctions:
            cols = [c.upper() for c in j[1:]]
            crit = [c for c in cols if c.endswith(("TOCRITTER", "TOCRITTERS"))]
            other = [c for c in cols if c not in crit]
            if len(crit) == 1 and len(other) == 1 and other[0].endswith(ends):
                return j
        return None
    critter_jt = critter_jt or _critter_jt_by_columns(False)
    critter_image_jt = critter_image_jt or _critter_jt_by_columns(True)

    # Pre-resolve gear-hinted junctions once; passed per-dive to avoid re-scanning.
    # Exclude group-gear junctions (column name contains "GROUP") — those map group PKs
    # to item PKs, not dive PKs to item PKs, and would fabricate gear on PK-colliding dives.
    gear_jts = [(tbl, c0, c1) for tbl, c0, c1 in junctions
                if any(h in (tbl + c0 + c1).upper() for h in _GEAR_HINTS)
                and not any("GROUP" in col.upper() for col in (tbl, c0, c1))]
    if gear_map and not gear_jts:
        print("Warning: gear items found but no gear junction table detected — "
              "dive-gear associations will be empty.", file=sys.stderr)

    # --- ZDIVE schema ---
    dc = columns(cur, "ZDIVE")

    ts_col   = col_or_null(dc, "ZRAWDATE", "ZTIMESTAMP", "ZDATE", "ZDATETIME")
    dur_col  = col_or_null(dc, "ZTOTALDURATION", "ZDURATION")
    num_col  = col_or_null(dc, "ZDIVENUMBER", "ZNUMBER")
    site_fk  = col_or_null(dc, "ZRELATIONSHIPDIVESITE", "ZRELATIONSHIPSITE")
    comp_col = col_or_null(dc, "ZCOMPUTER")
    comp_ser = col_or_null(dc, "ZCOMPUTERSERIAL")
    air_col  = col_or_null(dc, "ZAIRTEMP", "ZTEMPAIR", "ZTEMPERATUREAIR")
    rep_col  = col_or_null(dc, "ZREPETITIVEDIVENUMBER", "ZREPETITIVEDIVE", "ZREPETITIVE")
    deco_col = col_or_null(dc, "ZDECOMPRESSION", "ZISDECOMPRESSION")
    skip_col = col_or_null(dc, "ZBOATCAPTAIN", "ZSKIPPER")
    boat_col = col_or_null(dc, "ZBOATNAME", "ZBOAT")
    avg_col  = col_or_null(dc, "ZAVERAGEDEPTH", "ZAVGDEPTH")
    raw_col  = col_or_null(dc, "ZRAWDATA")
    pt_col   = col_or_null(dc, "ZPARSERTYPE")

    # Build SQLite UTC index for sample matching: {utc_str: [(pk, diver_name, duration_secs, max_depth_metres)]}
    sqlite_utc_index: dict = {}
    if ts_col != "NULL":
        has_diver_tbl = table_exists(cur, "ZDIVER")
        has_diver_fk  = "ZRELATIONSHIPDIVER" in dc  # column may be absent in older schemas
        diver_join = ("LEFT JOIN ZDIVER dv ON dv.Z_PK = d.ZRELATIONSHIPDIVER"
                      if has_diver_tbl and has_diver_fk else "")
        diver_expr = ("TRIM(COALESCE(dv.ZFIRSTNAME,'') || ' ' || COALESCE(dv.ZLASTNAME,''))"
                      if has_diver_tbl and has_diver_fk else "''")
        dur_expr    = f"d.{dur_col}" if dur_col != "NULL" else "NULL"
        depth_col_m = col_or_null(dc, "ZMAXDEPTH")
        depth_expr  = f"d.{depth_col_m}" if depth_col_m != "NULL" else "NULL"
        try:
            cur.execute(f"""
                SELECT d.Z_PK, d.{ts_col}, {dur_expr}, {diver_expr}, {depth_expr}
                FROM ZDIVE d {diver_join}
                WHERE d.{ts_col} IS NOT NULL
            """)
            for pk_i, ts_i, dur_i, diver_i, depth_i in cur.fetchall():
                utc_dt  = COREDATA_EPOCH + timedelta(seconds=float(ts_i))
                utc_str = utc_dt.strftime("%Y-%m-%d %H:%M:%S")
                sqlite_utc_index.setdefault(utc_str, []).append(
                    (pk_i, (diver_i or "").strip(),
                     float(dur_i)   if dur_i   is not None else None,
                     float(depth_i) if depth_i is not None else None)
                )
        except Exception as exc:
            print(f"Warning: could not build UTC index for sample matching: {exc}",
                  file=sys.stderr)

    pk_to_samples, pk_to_gases, pk_to_xml_temps = (
        match_samples_to_dives(xml_dives, sqlite_utc_index, xml_depth_in_feet=xml_depth_in_feet)
        if xml_dives else ({}, {}, {})
    )

    order_expr = f'"{ts_col}"' if ts_col != "NULL" else "ROWID"

    sql = f"""
        SELECT Z_PK,
               {col_or_null(dc, 'ZUUID')},
               {ts_col},
               {num_col},
               {col_or_null(dc, 'ZRELATIONSHIPDIVER')},
               {site_fk},
               {comp_col},
               {comp_ser},
               {col_or_null(dc, 'ZMAXDEPTH')},
               {avg_col},
               {dur_col},
               {col_or_null(dc, 'ZSURFACEINTERVAL')},
               {col_or_null(dc, 'ZRATING')},
               {rep_col},
               {col_or_null(dc, 'ZNOTES')},
               {col_or_null(dc, 'ZVISIBILITY')},
               {col_or_null(dc, 'ZWEATHER')},
               {col_or_null(dc, 'ZCURRENT')},
               {col_or_null(dc, 'ZSURFACECONDITIONS')},
               {col_or_null(dc, 'ZENTRYTYPE')},
               {col_or_null(dc, 'ZDIVEMASTER')},
               {col_or_null(dc, 'ZDIVEOPERATOR')},
               {skip_col},
               {boat_col},
               {air_col},
               {col_or_null(dc, 'ZTEMPHIGH')},
               {col_or_null(dc, 'ZTEMPLOW')},
               {col_or_null(dc, 'ZCNS')},
               {deco_col},
               {col_or_null(dc, 'ZDECOMODEL')},
               {col_or_null(dc, 'ZWEIGHT')},
               {raw_col},
               {pt_col}
        FROM ZDIVE
        ORDER BY {order_expr} ASC
    """
    cur.execute(sql)
    rows = cur.fetchall()

    # Calibration counters: track how many values used XML (unit-verified) vs SQLite fallback.
    _n_xml_press  = 0
    _n_auto_press = 0
    _n_xml_temp   = 0
    _n_auto_temp  = 0
    # Profile source counters (summary) and reasons raw data was not used.
    import collections as _collections
    _n_src       = _collections.Counter()
    _raw_reasons = _collections.Counter()
    _n_deco_dives = 0
    _n_raw_vals   = _collections.Counter()   # dive values taken from raw data instead of MacDive
    print("  Profile source per dive:")

    # Per-dive unit log setup.
    log_path       = str(Path(output_path).with_suffix(".log"))
    _all_dive_logs: list = []
    _log_pu = "PSI" if not _press_to_bar  else "bar"    # output pressure unit label
    _log_du = "ft"  if _to_feet           else "m"      # output distance unit label
    _log_tu = "°F"  if _to_fahr           else "°C"     # output temp unit label
    _log_vu = "cuft" if not _vol_to_liters else "L"     # output volume unit label
    _xml_pu = "PSI" if xml_pressure_in_psi else "bar"   # XML input pressure unit label
    _xml_tu = "°F"  if _xml_temp_in_fahr   else "°C"   # XML input temp unit label

    def _fv(v, d=2):
        """Format a numeric value for the log; returns '—' for None."""
        if v is None:
            return "—"
        try:
            return f"{float(v):.{d}f}"
        except (TypeError, ValueError):
            return "—"

    lines = []
    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    lines.append("<blueDiveExport>")
    lines.append("  <metadata>")
    lines.append(xtag("software",   "BlueDive", indent=4))
    lines.append(xtag("version",    "1.0",                    indent=4))
    lines.append(xtag("exportedAt", datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S"), indent=4))
    lines.append(xtag("diveCount",  str(len(rows)),           indent=4))
    lines.append("  </metadata>")
    lines.append("  <dives>")

    for row in rows:
        (pk, uuid, ts, dive_num, diver_fk, site_fk_val,
         comp_val, comp_ser_val, max_depth, avg_depth, duration,
         surf_int, rating, repetitive, notes, visibility, weather,
         current, surf_cond, entry_type, dive_master, dive_op,
         skipper, boat, temp_air, temp_high, temp_low, cns,
         is_deco, deco_model, weight, raw_data, parser_type) = row

        # Resolve computer name & serial
        comp_name, comp_serial = "", ""
        if comp_val is not None:
            try:
                pk_int = int(comp_val)
                if pk_int in computers:
                    comp_name, comp_serial = computers[pk_int]
                # else: unresolvable FK — leave comp_name/comp_serial as ""
            except (ValueError, TypeError):
                comp_name = str(comp_val) if comp_val else ""
        if comp_ser_val and not comp_serial:
            comp_serial = str(comp_ser_val)

        diver_name = divers.get(int(diver_fk) if diver_fk is not None else None, "")
        site       = sites.get(site_fk_val, {}) if site_fk_val is not None else {}
        tanks     = fetch_tanks(cur, pk)
        xml_gases = pk_to_gases.get(pk, [])
        # _dive_log is initialised here — immediately before the tank loop — so tank entries
        # can append to it before depth/temp entries are added further down.
        try:
            _log_dive_num = str(round(float(dive_num))) if dive_num is not None else "?"
            _dive_num_str = str(round(float(dive_num))) if dive_num is not None else ""
        except (ValueError, TypeError):
            _log_dive_num = "?"
            _dive_num_str = ""
        _dive_log = [
            f"Dive #{_log_dive_num}"
            f"  {coredata_to_str(ts)}  {diver_name or '(unknown)'}"
            f"  {'[XML dive matched]' if pk in pk_to_samples else '[no XML match]'}"
        ]
        # For start/end pressure, prefer XML values (correctly unit-converted by MacDive).
        # wp_out and vol_out are pre-computed here so the output block and log share the same value.
        #
        # Match XML gases to SQLite tanks by O₂/He mix key. This prevents cross-assignment when
        # MacDive's XML <gas> order differs from the SQLite ZORDER. Fall back to positional index
        # only when the mix key is absent or ambiguous (e.g. multiple tanks with the same gas mix).
        def _gas_key(entry):
            o2 = entry.get("o2")
            he = entry.get("he")
            if o2 is None and he is None:
                return None
            return (round(o2 or 0, 1), round(he or 0, 1))

        _xml_key_map: dict = {}
        _xml_key_ambiguous: set = set()
        for _xg_idx, _xg_entry in enumerate(xml_gases):
            _k = _gas_key(_xg_entry)
            if _k is not None:
                if _k in _xml_key_map:
                    _xml_key_ambiguous.add(_k)
                else:
                    _xml_key_map[_k] = _xg_idx

        # Also mark a key ambiguous when >1 SQLite tank shares the same O₂/He mix —
        # key matching cannot distinguish which XML gas belongs to which SQLite tank.
        _sqlite_key_counts: dict = {}
        for _st in tanks:
            _stk = _gas_key(_st)
            if _stk is not None:
                _sqlite_key_counts[_stk] = _sqlite_key_counts.get(_stk, 0) + 1
        for _stk, _cnt in _sqlite_key_counts.items():
            if _cnt > 1:
                _xml_key_ambiguous.add(_stk)
                _dive_log.append(f"  [INFO] {_cnt} SQLite tanks share mix {_stk} — key matching disabled for this mix, using positional fallback")

        if len(tanks) != len(xml_gases) and xml_gases:
            _dropped = max(0, len(xml_gases) - len(tanks))
            _warn_msg = (f"  [WARN] tank count ({len(tanks)}) ≠ XML gas count ({len(xml_gases)})"
                         + (f" — {_dropped} XML gas(es) dropped (no matching SQLite tank)" if _dropped else "")
                         + (" — positional fallback may misalign" if len(tanks) > len(xml_gases) else ""))
            _dive_log.append(_warn_msg)

        for _i, _t in enumerate(tanks):
            _tk = _gas_key(_t)
            if _tk is not None and _tk not in _xml_key_ambiguous and _tk in _xml_key_map:
                _xg_resolved_i = _xml_key_map[_tk]
                _xg = xml_gases[_xg_resolved_i]
                _gas_match_verified = True
                if _xg_resolved_i != _i:
                    _dive_log.append(f"  [INFO] tank[{_i + 1}] matched XML gas[{_xg_resolved_i + 1}] by O₂/He ({_tk}) instead of position")
            else:
                _xg = xml_gases[_i] if _i < len(xml_gases) else None
                _gas_match_verified = False  # positional fallback or no XML gas
            _raw_wp  = _t.get("wp")
            _raw_vol = _t.get("vol")

            if _xg is not None and _xg.get("start"):
                _xml_start  = _xg["start"]
                _xml_end    = _xg.get("end")
                _raw_end_sq = _t.get("end") or None   # SQLite end used when XML end is absent; 0 = no data
                _t["start"] = cvt_xml_press(_xml_start)
                if _xml_end:
                    _t["end"] = cvt_xml_press(_xml_end)
                elif _raw_end_sq is not None:
                    # ZAIREND comes from the same computer as ZAIRSTART so it is in the same unit.
                    # Calibrate from XML start magnitude (not the file-wide preset), matching the
                    # SQLite-path start-calibrates-end logic so the two paths stay consistent.
                    _xml_start_is_psi = _xml_start > 400
                    if _xml_start_is_psi:
                        _t["end"] = _raw_end_sq / 14.5038 if _press_to_bar else _raw_end_sq
                    else:
                        # Bar-start: treat end as bar unconditionally (same computer, same unit).
                        # Do NOT re-apply the >400 magnitude heuristic — that would break
                        # start-calibrates-end for any end value that happens to look like PSI.
                        _t["end"] = _raw_end_sq * 14.5038 if not _press_to_bar else _raw_end_sq
                else:
                    _t["end"] = None
                # Count start and end sources independently so the summary is accurate.
                # Only count as XML-verified when the gas was matched by O₂/He key; positional
                # fallback pairings are not guaranteed to be the right gas for this tank.
                if _gas_match_verified:
                    _n_xml_press += 1                      # start from XML, key-verified
                    if _xml_end:
                        _n_xml_press += 1                  # end also from XML, key-verified
                    elif _raw_end_sq is not None:
                        _n_auto_press += 1                 # end fell back to SQLite
                else:
                    _n_auto_press += 1                     # start from XML but positional — not guaranteed
                    if _xml_end:
                        _n_auto_press += 1
                    elif _raw_end_sq is not None:
                        _n_auto_press += 1
                _start_log = f"{_fv(_xml_start)} {_xml_pu} (XML) → {_fv(_t['start'])} {_log_pu}"
                if _xml_end:
                    _end_log = f"{_fv(_xml_end)} {_xml_pu} (XML) → {_fv(_t['end'])} {_log_pu}"
                elif _raw_end_sq is not None:
                    _sq_pu = "PSI" if _xml_start > 400 else "bar"
                    _end_log = (f"{_fv(_raw_end_sq)} SQLite ({_sq_pu}, calibrated from XML start magnitude)"
                                f" → {_fv(_t['end'])} {_log_pu}")
                else:
                    _end_log = "— (no data)"
            else:
                # No XML gas data — magnitude heuristic; calibrate end unit from start.
                start_raw    = _t.get("start")
                end_raw      = _t.get("end")
                _t["start"]  = cvt_press_auto(start_raw)
                start_is_psi = start_raw is not None and start_raw > 400
                if end_raw is None or end_raw == 0:
                    _t["end"] = None
                elif start_is_psi:
                    _t["end"] = end_raw / 14.5038 if _press_to_bar else end_raw
                else:
                    _t["end"] = cvt_press_auto(end_raw)
                _n_auto_press += 1
                _s_ctx     = ">400 → PSI" if (start_raw and start_raw > 400) else "≤400 → bar"
                _start_log = (f"{_fv(start_raw)} (SQLite, {_s_ctx}) → {_fv(_t['start'])} {_log_pu}"
                              if start_raw else "— (no data)")
                if end_raw is None or end_raw == 0:
                    _end_log = "— (no data)"
                elif start_is_psi and end_raw <= 400:
                    _end_log = f"{_fv(end_raw)} (SQLite, ≤400 calibrated PSI from start) → {_fv(_t['end'])} {_log_pu}"
                elif start_is_psi:
                    _end_log = f"{_fv(end_raw)} (SQLite, >400 → PSI) → {_fv(_t['end'])} {_log_pu}"
                else:
                    _e_ctx   = ">400 → PSI" if end_raw > 400 else "≤400 → bar"
                    _end_log = f"{_fv(end_raw)} (SQLite, {_e_ctx}) → {_fv(_t['end'])} {_log_pu}"

            # Pre-compute wp and vol — unconditionally after the XML/auto branch.
            # When WP is unknown, vol_out is set to None (omitted from XML) rather than
            # emitting the raw value under a definite unit label that may be wrong.
            _t["wp_out"]  = cvt_press_auto(_raw_wp)
            _vol_wp_known = _raw_wp is not None and _raw_wp != 0
            _t["vol_out"] = cvt_vol(_raw_vol, _raw_wp) if _vol_wp_known else None

            # WP log
            if _raw_wp is None or _raw_wp == 0:
                _wp_log = "— (no data)"
            else:
                _wp_ctx = ">400 → PSI" if _raw_wp > 400 else "≤400 → bar"
                _wp_log = f"{_fv(_raw_wp)} (SQLite, {_wp_ctx}) → {_fv(_t['wp_out'])} {_log_pu}"

            # Volume log — context derived from raw wp using the same thresholds as cvt_vol.
            if _raw_vol is None or _raw_vol == 0:
                _vol_log = "— (no data)"
            elif _raw_wp is not None and _raw_wp > 400:
                _vol_log = (f"{_fv(_raw_vol)} cuft (SQLite, PSI context, WP={_fv(_raw_wp, 0)} PSI)"
                            f" → {_fv(_t['vol_out'], 4)} {_log_vu}")
            elif _raw_wp is not None and _raw_wp > 0:
                _vol_log = (f"{_fv(_raw_vol)} L (SQLite, bar context, WP={_fv(_raw_wp, 0)} bar)"
                            f" → {_fv(_t['vol_out'], 4)} {_log_vu}")
            else:
                _vol_log = f"{_fv(_raw_vol)} (SQLite, WP unknown) → omitted (unit indeterminate)"

            _dive_log.append(f"  tank[{_i + 1}]")
            _dive_log.append(f"    start  : {_start_log}")
            _dive_log.append(f"    end    : {_end_log}")
            _dive_log.append(f"    wp     : {_wp_log}")
            _dive_log.append(f"    volume : {_vol_log}")

        # Raw dive computer data (ZRAWDATA, decoded by libdivecomputer in a worker process).
        # When it agrees with MacDive's XML profile (or, without one, with the dive record), it
        # has priority for every value it records: profile, events, decompression stops, and
        # the dive time, max depth, decompression flag and tank pressures below.
        xml_samples = pk_to_samples.get(pk, [])
        if xml_samples:
            _check = ("MacDive profile",
                      max(s["depth"] for s in xml_samples) * (0.3048 if xml_depth_in_feet else 1.0),
                      max(s["time"] for s in xml_samples))
        else:
            _check = ("dive", _num(max_depth), _num(duration))
        if raw_data:
            decoded, raw_why = libdc.decode(raw_data, comp_name, ts, _check)
        else:
            decoded, raw_why = None, None
        _macdive_duration = _num(duration)
        _macdive_tanks = [dict(t) for t in tanks]   # MacDive's tank values, before raw overrides
        _deco_stops = raw_deco_stops(decoded) if decoded is not None else []
        _tank_map, _raw_tank_values, _raw_series = {}, {}, {}
        _max_depth_src = "SQLite"
        if decoded is not None:
            _changes = []
            _dur, _md = _macdive_duration, _num(max_depth)
            # The computer's dive time, used only when plausible: not longer than its own
            # profile (+60 s) and within 10 min (or 20 %) of MacDive's duration.
            _dt = decoded["divetime"]
            if _dt is not None and (_dt > decoded["span"] + 60 or
                                    (_dur and abs(_dur - _dt) > max(600, 0.2 * _dur))):
                _dive_log.append(f"  duration   : raw dive time {_dt} s implausible (raw profile "
                                 f"{decoded['span']:.0f} s, MacDive {_fv(duration, 0)} s) — MacDive's kept")
                _dt = None
            if _dt is not None:
                if _dur is None or abs(_dur - _dt) > 0.5:
                    _changes.append(f"duration {_fv(duration, 0)} → {_dt} s")
                    _n_raw_vals["duration"] += 1
                duration = _dt
            # The computer's recorded max depth, used only when it agrees with its deepest
            # sample (which the agreement check compared with MacDive's).
            _hdr_md = decoded["dc_maxdepth"]
            if _hdr_md is not None and abs(_hdr_md - decoded["max_depth"]) > 0.5:
                _dive_log.append(f"  max depth  : raw header {_hdr_md:.2f} m ≠ deepest raw sample "
                                 f"{decoded['max_depth']:.2f} m — MacDive's kept")
                _hdr_md = None
            if _hdr_md is not None:
                if _md is None or abs(_md - _hdr_md) > 0.005:
                    _changes.append(f"max depth {_fv(max_depth)} → {_hdr_md:.2f} m")
                    _n_raw_vals["max depth"] += 1
                max_depth = _hdr_md
                _max_depth_src = "raw data"
            _raw_deco = raw_is_deco(decoded)
            if _raw_deco is not None:
                if _raw_deco != bool(is_deco):
                    _changes.append(f"decompression dive {'yes' if is_deco else 'no'} → "
                                    f"{'yes' if _raw_deco else 'no'}")
                    _n_raw_vals["decompression flag"] += 1
                is_deco = _raw_deco
            # One tank mapping for the tank cards here and the sample pressures below.
            _tank_map, _raw_tank_values, _raw_series = map_raw_tanks(
                decoded, _macdive_tanks, cvt_bar_out, 1.0 if _press_to_bar else 14.5038,
                _macdive_duration)
            for _ri, _ti in sorted(_tank_map.items(), key=lambda kv: kv[1]):
                _t = tanks[_ti]
                _old = (_t.get("start"), _t.get("end"))
                _t["start"], _t["end"] = _raw_tank_values[_ri]
                if _old[0] is None or _old[1] is None or abs(_old[0] - _t["start"]) > 0.005 \
                        or abs(_old[1] - _t["end"]) > 0.005:
                    _changes.append(f"tank[{_ti + 1}] {_fv(_old[0])}/{_fv(_old[1])} → "
                                    f"{_fv(_t['start'])}/{_fv(_t['end'])} {_log_pu}")
                    _n_raw_vals["tank pressures"] += 1
            if _changes:
                _dive_log.append("  raw values : " + "; ".join(_changes) + "  (MacDive → raw data)")

        buddy_names = junction_lookup(cur, pk, buddy_jt, buddies)
        type_names  = junction_lookup(cur, pk, type_jt,  types_lkp)
        tag_names   = junction_lookup(cur, pk, tag_jt,   tags_lkp)
        critters    = fetch_critters(cur, pk, critter_jt, critter_image_jt)
        gear_items  = fetch_dive_gear(cur, pk, gear_map, gear_jts)

        try:
            dur_secs = round(float(duration)) if duration is not None else 0
        except (ValueError, TypeError):
            dur_secs = 0

        lines.append("  <dive>")

        # Per-dive weight: embedded unit token in the raw value takes priority over --weight-unit.
        _weight_str, _weight_unit_dive = parse_weight(weight, weight_unit)

        # Units — distance/temp/pressure/volume are global; weight may be per-dive.
        lines.append(xtag("distanceFormat",    distance_fmt,                          indent=4))
        lines.append(xtag("temperatureFormat", temp_fmt,                              indent=4))
        lines.append(xtag("pressureFormat",    pressure_fmt,                          indent=4))
        lines.append(xtag("volumeFormat",      volume_fmt,                            indent=4))
        lines.append(xtag("weightFormat",      WEIGHT_FORMAT[_weight_unit_dive],      indent=4))
        lines.append(xtag("sourceImport",      "MacDive",                             indent=4))

        # Basic info
        lines.append(xtag("date",           coredata_to_str(ts),             indent=4))
        lines.append(xtag("identifier",     str(uuid or ""),                  indent=4))
        try:
            _rating_str = str(round(float(rating))) if rating is not None else ""
        except (ValueError, TypeError):
            _rating_str = ""
        lines.append(xtag("diveNumber",     _dive_num_str, indent=4))
        lines.append(xtag("rating",         _rating_str,   indent=4))
        # MacDive stores the dive number in the repetitive sequence (1 = first/solo dive,
        # 2+ = genuinely repetitive). Only flag as repetitive when the number is > 1.
        try:
            is_repetitive = repetitive is not None and int(float(repetitive)) > 1
        except (ValueError, TypeError):
            is_repetitive = False
        lines.append(xtag("repetitiveDive", "1" if is_repetitive else "0",  indent=4))
        lines.append(xtag("diver",          diver_name,                       indent=4))
        lines.append(xtag("computer",       comp_name,                        indent=4))
        lines.append(xtag("serial",         comp_serial,                      indent=4))

        # Dive stats — depth: SQLite always stores metres; convert to feet for imperial output.
        lines.append(xtag("maxDepth",        fmt_double(cvt_dist(max_depth)),  indent=4))
        lines.append(xtag("averageDepth",    fmt_double(cvt_dist(avg_depth)),  indent=4))
        lines.append(xtag("duration",        str(dur_secs),          indent=4))
        _dive_log.append(f"  maxDepth   : {_fv(max_depth, 4)} m ({_max_depth_src}) → {_fv(cvt_dist(max_depth), 4)} {_log_du}")
        _dive_log.append(f"  avgDepth   : {_fv(avg_depth, 4)} m (SQLite) → {_fv(cvt_dist(avg_depth), 4)} {_log_du}")
        try:
            _surf_int_str = str(round(float(surf_int))) if surf_int is not None else ""
        except (ValueError, TypeError):
            _surf_int_str = ""
        lines.append(xtag("surfaceInterval", _surf_int_str, indent=4))

        # Decompression
        lines.append(xtag("cns",               fmt_double(cns),                          indent=4))
        lines.append(xtag("decoModel",         str(deco_model or ""),                    indent=4))
        lines.append(xtag("decompressionDive", "1" if is_deco else "0",                  indent=4))

        # Temperatures — prefer XML (correctly unit-converted by MacDive); fall back to SQLite.
        _xt     = pk_to_xml_temps.get(pk, {})
        _t_air  = _xt.get("temp_air")
        _t_high = _xt.get("temp_high")
        _t_low  = _xt.get("temp_low")
        # Must be defined before the counters and _resolve_temp closure below.
        _sqlite_temp_safe = not _to_fahr or pk in pk_to_xml_temps
        if _t_air  is not None:                              _n_xml_temp  += 1
        elif temp_air  is not None and _sqlite_temp_safe:   _n_auto_temp += 1
        if _t_high is not None:                              _n_xml_temp  += 1
        elif temp_high is not None and _sqlite_temp_safe:   _n_auto_temp += 1
        if _t_low  is not None:                              _n_xml_temp  += 1
        elif temp_low  is not None and _sqlite_temp_safe:   _n_auto_temp += 1
        # SQLite always stores temperature in °C. For Metric/Canadian output, cvt_temp converts
        # correctly. For Imperial output, cvt_temp converts °C → °F — but only when the XML
        # matched this dive (XML temps are authoritative). For unmatched Imperial dives the SQLite
        # value is assumed °C; if the user originally entered °F in MacDive the fallback would
        # double-convert to garbage, so suppress the SQLite fallback for Imperial unmatched dives.
        # (_sqlite_temp_safe is defined above, before the counters.)
        def _resolve_temp(xml_val, sqlite_val):
            if xml_val is not None:
                return cvt_xml_temp(xml_val)
            if sqlite_val is not None and _sqlite_temp_safe:
                return cvt_temp(sqlite_val)
            return None

        lines.append(xtag("tempAir",  fmt_double(_resolve_temp(_t_air,  temp_air)),  indent=4))
        lines.append(xtag("tempHigh", fmt_double(_resolve_temp(_t_high, temp_high)), indent=4))
        lines.append(xtag("tempLow",  fmt_double(_resolve_temp(_t_low,  temp_low)),  indent=4))

        def _temp_log_entry(label, xml_val, sqlite_val):
            if xml_val is not None:
                out = cvt_xml_temp(xml_val)
                return f"  {label:<10}: {_fv(xml_val)} {_xml_tu} (XML) → {_fv(out)} {_log_tu}"
            if sqlite_val is not None and _sqlite_temp_safe:
                out = cvt_temp(sqlite_val)
                src = f"{_fv(sqlite_val)} °C (SQLite, assumed)"
                return f"  {label:<10}: {src} → {_fv(out)} {_log_tu}"
            if sqlite_val is not None:
                return f"  {label:<10}: {_fv(sqlite_val)} °C (SQLite) → omitted (Imperial unmatched dive, unit unverified)"
            return f"  {label:<10}: — (no data)"
        _dive_log.append(_temp_log_entry("tempAir",  _t_air,  temp_air))
        _dive_log.append(_temp_log_entry("tempHigh", _t_high, temp_high))
        _dive_log.append(_temp_log_entry("tempLow",  _t_low,  temp_low))

        # Conditions
        lines.append(xtag("visibility",        str(visibility  or ""), indent=4))
        lines.append(xtag("weight",            _weight_str,            indent=4))
        lines.append(xtag("weather",           str(weather     or ""), indent=4))
        lines.append(xtag("current",           str(current     or ""), indent=4))
        lines.append(xtag("surfaceConditions", str(surf_cond   or ""), indent=4))
        lines.append(xtag("entryType",         str(entry_type  or ""), indent=4))

        # Operator
        lines.append(xtag("diveMaster",   str(dive_master or ""), indent=4))
        lines.append(xtag("diveOperator", str(dive_op     or ""), indent=4))
        lines.append(xtag("skipper",      str(skipper     or ""), indent=4))
        lines.append(xtag("boat",         str(boat        or ""), indent=4))

        # Notes & tags
        lines.append(xtag("notes", str(notes or ""),    indent=4))
        lines.append(xtag("tags",  ", ".join(tag_names), indent=4))

        # Types
        lines.append("    <types>")
        for name in type_names:
            lines.append(xtag("type", name, indent=6))
        lines.append("    </types>")

        # Buddies
        lines.append("    <buddies>")
        for name in buddy_names:
            lines.append(xtag("buddy", name, indent=6))
        lines.append("    </buddies>")

        # Site
        lines.append("    <site>")
        site_name = site.get("name") or ""
        site_loc  = site.get("location") or ""
        lines.append(xtag("name",        site_name or site_loc,          indent=6))
        lines.append(xtag("location",    site_loc,                        indent=6))
        lines.append(xtag("country",     site.get("country")      or "",  indent=6))
        lines.append(xtag("bodyOfWater", site.get("body_of_water") or "", indent=6))
        lines.append(xtag("waterType",   site.get("water_type")   or "",  indent=6))
        lines.append(xtag("difficulty",  site.get("difficulty")   or "",  indent=6))
        lines.append(xtag("altitude",    fmt_double(site.get("altitude")), indent=6))
        lat = site.get("lat")
        lon = site.get("lon")
        # MacDive stores 0.0/0.0 for sites without a GPS fix — treat as absent
        lat_f = float(lat) if lat is not None else None
        lon_f = float(lon) if lon is not None else None
        if lat_f == 0.0 and lon_f == 0.0:
            lat_f = lon_f = None
        lines.append(xtag("lat",     f"{lat_f:.7f}" if lat_f is not None else "", indent=6))
        lines.append(xtag("lon",     f"{lon_f:.7f}" if lon_f is not None else "", indent=6))
        lines.append(xtag("exitLat", "",                                  indent=6))
        lines.append(xtag("exitLon", "",                                  indent=6))
        lines.append("    </site>")

        # Tanks
        if tanks:
            lines.append("    <tanks>")
            for t in tanks:
                lines.append("      <tank>")
                lines.append(xtag("id",              "",                         indent=8))
                lines.append(xtag("oxygen",          str(t["o2"]),               indent=8))
                lines.append(xtag("helium",          str(t["he"]),               indent=8))
                lines.append(xtag("volume",          fmt_double(t.get("vol_out")),  indent=8))
                lines.append(xtag("startPressure",   fmt_double(t.get("start")),   indent=8))
                lines.append(xtag("endPressure",     fmt_double(t.get("end")),     indent=8))
                lines.append(xtag("workingPressure", fmt_double(t.get("wp_out")),  indent=8))
                lines.append(xtag("tankMaterial",    str(t.get("mat")  or ""),   indent=8))
                lines.append(xtag("tankType",        str(t.get("type") or ""),   indent=8))
                lines.append(xtag("usageStartTime",  "",                         indent=8))
                lines.append(xtag("usageEndTime",    "",                         indent=8))
                lines.append("      </tank>")
            lines.append("    </tanks>")

        # Marine life
        if critters:
            lines.append("    <marineLifeSeen>")
            for c in critters:
                lines.append("      <marineLife>")
                lines.append(xtag("name",  c["name"],       indent=8))
                lines.append(xtag("count", str(c["count"]), indent=8))
                lines.append("      </marineLife>")
            lines.append("    </marineLifeSeen>")

        # Gear (embedded in dive — uses combined manufacturer+name, structured service records)
        if gear_items:
            lines.append("    <gear>")
            for g in gear_items:
                lines.append("      <item>")
                lines.append(xtag("id",              g["uuid"],             indent=8))
                lines.append(xtag("type",            g["type"],             indent=8))
                lines.append(xtag("manufacturer",    g["manufacturer"],     indent=8))
                lines.append(xtag("model",           g["model"],            indent=8))
                lines.append(xtag("name",            g["name"],             indent=8))
                lines.append(xtag("serial",          g["serial"],           indent=8))
                lines.append(xtag("datePurchased",   g["date_purchased"],   indent=8))
                lines.append(xtag("purchasePrice",   g["purchase_price"],   indent=8))
                lines.append(xtag("currency",        g["currency"],         indent=8))
                lines.append(xtag("purchasedFrom",   g["purchased_from"],    indent=8))
                lines.append(xtag("lastServiceDate", g["last_service_date"], indent=8))
                lines.append(xtag("nextServiceDue",  g["next_service_due"],  indent=8))
                lines.extend(service_records_xml_lines(g["service_records"], indent=8))
                lines.append(xtag("gearNotes",       g["notes"],            indent=8))
                lines.append(xtag("isInactive",      g["is_inactive"],      indent=8))
                lines.append(xtag("diverName",       divers.get(g["diver_fk"], ""), indent=8))
                lines.append("      </item>")
            lines.append("    </gear>")

        # Profile samples: the raw dive computer data (ZRAWDATA, decoded by libdivecomputer)
        # has priority when it agrees with MacDive's XML profile (or, without one, with the
        # dive's max depth and duration); otherwise the MacDive XML samples are used.
        # (decoded / raw_why come from the raw decode done before the dive values are written.)
        samples, dive_events, event_src, _keep_xml = [], [], None, False
        if decoded is not None:
            raw_samples = raw_profile_samples(decoded, cvt_dist, cvt_temp, cvt_bar_out,
                                              _tank_map, _raw_series)
            _n_pt, _n_pt_mapped = len(_raw_series), sum(1 for i in _raw_series if i in _tank_map)
            # No main-tank pressure anywhere in the raw samples (no transmitter, none matching a
            # dive tank — e.g. sidemount tanks MacDive logged as one — or only another tank's)
            # while MacDive's XML samples have it: MacDive's main-tank pressures go onto the raw
            # samples recorded at the same moment (see merge_xml_pressures). If they don't line
            # up, MacDive's XML samples are kept instead.
            _raw_has_main = any(s.get("pressure") is not None or 0 in (s.get("tank_pressures") or {})
                                for s in raw_samples)
            _xml_has_pressure = any(s.get("pressure") is not None for s in xml_samples)
            _pressure_note = None
            if not _raw_has_main and _xml_has_pressure:
                _filled, _matched, _total = merge_xml_pressures(raw_samples, xml_samples)
                if _filled:
                    _pressure_note = (f"MacDive XML main-tank pressures added to {_filled} raw samples "
                                      f"recorded at the same moment ({_matched}/{_total} MacDive readings line up)")
                else:
                    _keep_xml = True
                    _pressure_note = (f"MacDive XML samples kept for their tank pressure (only "
                                      f"{_matched}/{_total} MacDive readings line up with the raw samples)")
            if _n_pt > 1 or _pressure_note:
                _dive_log.append(f"  pressures  : {_n_pt} transmitter tank(s) in raw data, {_n_pt_mapped} matched "
                                 f"to a dive tank by start/end pressure"
                                 + (f" — {_pressure_note}" if _pressure_note
                                    else " (unmatched tanks not imported)"))
            # Gas switches from the raw data (MacDive's when the raw data reports no gas),
            # other events from both sources.
            _raw_evs = raw_events(decoded, tanks)
            dive_events = merge_events(_raw_evs, fetch_events(cur, pk, tanks), raw_has_gas_data(decoded))
            _n_raw_ev = sum(1 for e in _raw_evs if e[1] is not None)
            event_src = (f"raw data ({_n_raw_ev}) + MacDive "
                         f"({sum(1 for e in dive_events if e[1] is not None) - _n_raw_ev})")
        if decoded is not None and not _keep_xml:
            samples = raw_samples
            _profile_src = (f"raw data ({len(samples)} samples, libdivecomputer: {decoded['model']}, "
                            f"{decoded['divemode']})"
                            + (" + MacDive sample pressures" if _pressure_note else "")
                            + ("" if xml_samples else " — no MacDive XML profile"))
            _n_src["raw"] += 1
        elif xml_samples:
            samples = xml_samples
            # Sample depths come from XML in the display unit; convert only if output differs.
            # (All three presets share the same input/output unit system, so these branches
            #  are currently unreachable, but are retained for safety should overrides be added.)
            if xml_depth_in_feet and units["distance"] == "meters":
                samples = [{**s, "depth": s["depth"] * 0.3048} for s in samples]
            elif not xml_depth_in_feet and units["distance"] == "feet":
                samples = [{**s, "depth": s["depth"] / 0.3048} for s in samples]
            # Sample tank pressures come from XML already in the display unit; no conversion needed
            # because the output pressure unit always matches the XML export unit for all presets.
            if decoded is not None:   # _keep_xml: gas switches and events still come from raw data
                _profile_src = (f"MacDive XML samples ({len(samples)}) + gas switches/events from raw data "
                                f"(libdivecomputer: {decoded['model']}, {decoded['divemode']}) — raw samples "
                                f"have no main-tank pressure and don't line up with MacDive's")
                _n_src["xml+raw"] += 1
            else:
                dive_events, event_src = fetch_events(cur, pk, tanks), "MacDive"
                _profile_src = (f"MacDive XML samples ({len(samples)}) + MacDive events"
                                + (f"; raw data not used: {raw_why}" if raw_why else ""))
                _n_src["xml"] += 1
        else:
            _profile_src = "none — no MacDive XML profile" + (f"; raw data not used: {raw_why}" if raw_why else "")
            _n_src["none"] += 1
        if raw_why:
            _raw_reasons[re.sub(r"[\d.]+", "#", raw_why)] += 1
        _dive_log.append(f"  profile    : {_profile_src}")
        print(f"    Dive #{_log_dive_num}: {_profile_src}")
        if decoded is not None and decoded["sp_changes"]:
            _dive_log.append(f"  setpoints  : {decoded['sp_changes']} setpoint switch(es) in raw data — "
                             f"not imported (BlueDive has no setpoint event)")
        # Mandatory decompression stops reported by the computer (Gas tab list). Depth in
        # metres, time in seconds, type 2 = DC_DECO_DECOSTOP.
        if _deco_stops:
            lines.append("    <decoStops>")
            for _sd, _st in _deco_stops:
                # DecoStop.depth is metres in BlueDive's model, whatever the dive's distance unit.
                lines.append(f'      <decoStop depth="{fmt_double(_sd)}" time="{int(_st)}" type="2"/>')
            lines.append("    </decoStops>")
            _dive_log.append("  deco stops : " + ", ".join(
                f"{fmt_double(_sd)} m {int(_st) // 60}:{int(_st) % 60:02d}" for _sd, _st in _deco_stops)
                + " (raw data)")
            _n_deco_dives += 1
        if samples:
            samples = attach_events_to_samples(samples, dive_events)
            _n_ev = sum(1 for e in dive_events if e[1] is not None)
            if _n_ev:
                _n_gas = sum(1 for e in dive_events if e[1] == "gasChange")
                _n_gas_tank = sum(1 for e in dive_events if e[1] == "gasChange" and e[2] is not None)
                _dive_log.append(f"  events     : {_n_ev} imported from {event_src}"
                                 + (f" ({_n_gas} gas switch(es), {_n_gas_tank} matched to a tank)"
                                    if _n_gas else ""))
            lines.append("    <!-- BlueDiveSamplesData -->")
            lines.extend(profile_samples_xml_lines(samples, indent=4))

        # Raw dive computer data (base64)
        if raw_data:
            b64_lines = base64_block("rawDiveComputerData", raw_data, indent=4)
            if b64_lines:
                lines.append("    <!-- Raw dive computer data (Base64-encoded binary) -->")
                lines.extend(b64_lines)
            else:
                print(f"  Note: dive #{_log_dive_num} ZRAWDATA has TEXT affinity — raw dive-computer profile skipped",
                      file=sys.stderr)

        # MacDive parser type hint — useful for future profile decoding in BlueDive
        if parser_type:
            lines.append(xtag("parserType", str(parser_type), indent=4))

        _all_dive_logs.extend(_dive_log)
        _all_dive_logs.append("")
        lines.append("  </dive>")

    lines.append("  </dives>")
    lines.append("</blueDiveExport>")
    con.close()   # the libdivecomputer worker is closed by export_dives

    _src_summary = [
        "Profile source summary:",
        f"  Raw data (libdivecomputer)                       : {_n_src['raw']}",
        f"  MacDive XML samples + raw gas switches/events    : {_n_src['xml+raw']}",
        f"  MacDive XML samples + MacDive events             : {_n_src['xml']}",
        f"  No profile                                       : {_n_src['none']}",
        f"  Dives with deco stops from raw data              : {_n_deco_dives}",
        "  Dive values changed by raw data (MacDive → raw): "
        + (", ".join(f"{k} {v}" for k, v in _n_raw_vals.items()) or "none"),
    ]
    if _raw_reasons:
        _src_summary.append("  Raw data not used (# = number):")
        for _reason, _cnt in _raw_reasons.most_common():
            _src_summary.append(f"    {_cnt:5d}  {_reason}")
    _src_summary.append("")

    if not libdc.started:
        _hlog("libdivecomputer not needed — no dive has raw dive computer data (ZRAWDATA)")
    _header_logs.append("")
    Path(output_path).write_text("\n".join(lines), encoding="utf-8")
    Path(log_path).write_text("\n".join(_header_logs + _src_summary + _all_dive_logs), encoding="utf-8")
    print(f"✓ {len(rows)} dives exported to {output_path}")
    for _line in _src_summary[:-1]:
        print(f"  {_line}")
    print(f"  Log         : {log_path}")
    print(f"  Gear items  : {len(gear_map)}")
    print(f"  Distance    : {distance_fmt}")
    print(f"  Temperature : {temp_fmt}")
    print(f"  Pressure    : {pressure_fmt}")
    print(f"  Volume      : {volume_fmt}")
    print(f"  Weight      : {weight_fmt} default (embedded unit in field value takes priority per dive)")
    if _n_xml_press + _n_auto_press > 0:
        print(f"  Tank start/end pressure source:")
        print(f"    XML (unit-verified)  : {_n_xml_press} field(s)")
        print(f"    SQLite fallback      : {_n_auto_press} field(s)  (magnitude heuristic: >400=PSI, ≤400=bar)")
    if _n_xml_temp + _n_auto_temp > 0:
        print(f"  Temperature source:")
        print(f"    XML (unit-verified)  : {_n_xml_temp} field(s)")
        print(f"    SQLite fallback      : {_n_auto_temp} field(s)  (assumed °C)")


# ---------------------------------------------------------------------------
# Gear export  →  <blueDiveGearExport>
# ---------------------------------------------------------------------------

def load_gear_groups(cur, gear_map, junctions):
    """Return list of {uuid, name, member_uuids} from ZGEARGROUP + its junction table."""
    if not table_exists(cur, "ZGEARGROUP"):
        return []
    gc = columns(cur, "ZGEARGROUP")
    uuid_col = col_or_null(gc, "ZUUID")
    name_col = col_or_null(gc, "ZNAME")
    try:
        cur.execute(f"SELECT Z_PK, {uuid_col}, {name_col} FROM ZGEARGROUP")
        groups_raw = cur.fetchall()
    except Exception:
        return []
    if not groups_raw:
        return []

    # Find the junction: must be gear-hinted (table name) AND have a column named with
    # "GROUP" (group FK side). Requiring the table name to also match _GEAR_HINTS prevents
    # accidentally picking a non-gear group junction (e.g. a dive-group table).
    group_gear_jt = None
    for tbl, c0, c1 in junctions:
        tblu, c0u, c1u = tbl.upper(), c0.upper(), c1.upper()
        if not any(h in tblu for h in _GEAR_HINTS):
            continue
        if "GROUP" in c0u:
            group_gear_jt = (tbl, c0, c1)  # group FK = c0, item FK = c1
            break
        if "GROUP" in c1u:
            group_gear_jt = (tbl, c1, c0)  # group FK = c1, item FK = c0
            break

    groups = []
    for pk, uuid_val, name in groups_raw:
        # Warn when ZUUID is absent from the schema — BlueDive will generate a random UUID
        # on every import, breaking deduplication across re-imports.
        if not uuid_val:
            print(f"Warning: ZGEARGROUP row pk={pk} has no UUID; "
                  "BlueDive will assign a random id on each import.", file=sys.stderr)
        member_uuids = []
        if group_gear_jt:
            tbl, group_col, item_col = group_gear_jt
            try:
                cur.execute(
                    f'SELECT "{item_col}" FROM "{tbl}" WHERE "{group_col}" = ?',
                    (pk,),
                )
                for (item_pk,) in cur.fetchall():
                    if item_pk in gear_map:
                        item_uuid = gear_map[item_pk]["uuid"]
                        if item_uuid:
                            member_uuids.append(item_uuid)
                        else:
                            print(f"Warning: gear item pk={item_pk} has no UUID; "
                                  "excluded from gear group membership (would emit an "
                                  "invalid <gearID> that BlueDive silently discards).",
                                  file=sys.stderr)
            except Exception as exc:
                print(f"Warning: could not resolve members for gear group pk={pk}: {exc}",
                      file=sys.stderr)
        groups.append({
            "uuid": uuid_val or "",
            "name": (name or "").strip(),
            "member_uuids": member_uuids,
        })
    return groups


def gear_group_xml_lines(group, indent=4):
    """Emit a <gearGroup> block for the gear XML export."""
    outer_pad = " " * indent
    inner_pad = " " * (indent + 2)
    lines = [f"{outer_pad}<gearGroup>"]
    lines.append(xtag("id",   group["uuid"], indent=indent + 2))
    lines.append(xtag("name", group["name"], indent=indent + 2))
    lines.append(f"{inner_pad}<gearIDs>")
    for uid in group["member_uuids"]:
        lines.append(xtag("gearID", uid, indent=indent + 4))
    lines.append(f"{inner_pad}</gearIDs>")
    lines.append(f"{outer_pad}</gearGroup>")
    return lines


def export_gears(input_path, output_path, weight_unit):
    _reset_schema_caches()
    con = sqlite3.connect(input_path)
    cur = con.cursor()

    divers      = load_divers(cur)
    gear_map    = load_gear_map(cur)
    junctions   = discover_junctions(cur)
    gear_groups = load_gear_groups(cur, gear_map, junctions)

    lines = []
    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    lines.append("<blueDiveGearExport>")
    lines.append("  <metadata>")
    lines.append(xtag("software",          "BlueDive",  indent=4))
    lines.append(xtag("version",           "1.0",       indent=4))
    lines.append(xtag("exportedAt",        datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S"), indent=4))
    lines.append(xtag("gearCount",         str(len(gear_map)),    indent=4))
    lines.append(xtag("gearGroupCount",    str(len(gear_groups)), indent=4))
    lines.append(xtag("tankTemplateCount", "0",                   indent=4))
    lines.append("  </metadata>")

    lines.append("  <gears>")
    for pk, g in gear_map.items():
        diver_name = divers.get(g["diver_fk"], "")
        # Per-item weight: embedded unit token in the raw value takes priority over --weight-unit.
        _wc_str, _wc_unit = parse_weight(g["weight_raw"], weight_unit)

        lines.append("    <gear>")
        lines.append(xtag("id",                   g["uuid"],                   indent=6))
        lines.append(xtag("name",                 g["raw_name"],               indent=6))
        lines.append(xtag("category",             g["type"],                   indent=6))
        lines.append(xtag("manufacturer",         g["manufacturer"],           indent=6))
        lines.append(xtag("model",                g["model"],                  indent=6))
        lines.append(xtag("serialNumber",         g["serial"],                 indent=6))
        lines.append(xtag("datePurchased",        g["date_purchased"],         indent=6))
        lines.append(xtag("purchasePrice",        g["purchase_price"],         indent=6))
        lines.append(xtag("currency",             g["currency"],               indent=6))
        lines.append(xtag("purchasedFrom",        g["purchased_from"],         indent=6))
        lines.append(xtag("lastServiceDate",      g["last_service_date"],      indent=6))
        lines.append(xtag("nextServiceDue",       g["next_service_due"],       indent=6))
        lines.extend(service_records_xml_lines(g["service_records"], indent=6))
        lines.append(xtag("gearNotes",            g["notes"],                  indent=6))
        lines.append(xtag("weightContribution",   _wc_str,                     indent=6))
        lines.append(xtag("weightContributionUnit", WEIGHT_FORMAT[_wc_unit],   indent=6))
        lines.append(xtag("isInactive",           g["is_inactive"],            indent=6))
        lines.append(xtag("diverName",            diver_name,                  indent=6))
        lines.append("    </gear>")
    lines.append("  </gears>")

    lines.append("  <gearGroups>")
    for grp in gear_groups:
        lines.extend(gear_group_xml_lines(grp, indent=4))
    lines.append("  </gearGroups>")
    lines.append("  <tankTemplates>")
    lines.append("  </tankTemplates>")

    lines.append("</blueDiveGearExport>")
    con.close()

    Path(output_path).write_text("\n".join(lines), encoding="utf-8")
    print(f"✓ {len(gear_map)} gear items, {len(gear_groups)} gear groups exported to {output_path}")
    print(f"  Weight unit : {WEIGHT_FORMAT[weight_unit]} default (embedded unit in field value takes priority per item)")


# ---------------------------------------------------------------------------
# Certification export  →  <blueDiveCertificationExport>
# ---------------------------------------------------------------------------

def load_certifications_list(cur, divers):
    """Return list of cert dicts from ZCERTIFICATION (or variant table names)."""
    cert_table = None
    for name in ("ZCERTIFICATION", "ZCERT", "ZCERTIFICATE"):
        if table_exists(cur, name):
            cert_table = name
            break
    if cert_table is None:
        return []

    cc = columns(cur, cert_table)
    name_col    = col_or_null(cc, "ZNAME",        "ZTITLE")
    org_col     = col_or_null(cc, "ZAGENCY",       "ZORGANIZATION", "ZORG")
    level_col   = col_or_null(cc, "ZLEVEL",        "ZDEGREE")
    num_col     = col_or_null(cc, "ZDIVERNUMBER",  "ZNUMBER", "ZCERTIFICATIONNUMBER", "ZCERTNUMBER", "ZCARDNUMBER")
    date_col    = col_or_null(cc, "ZATTAINED",     "ZDATECERTIFIED", "ZDATE", "ZISSUEDATE", "ZDATEISSUED")
    exp_col     = col_or_null(cc, "ZEXPIRY",       "ZDATEEXPIRATION", "ZEXPIRATIONDATE", "ZDATEEXPIRY")
    inst_col    = col_or_null(cc, "ZINSTRUCTORNAME", "ZINSTRUCTOR")
    instnum_col = col_or_null(cc, "ZINSTRUCTORNUMBER")
    centre_col  = col_or_null(cc, "ZINSTRUCTORSHOP", "ZDIVINGCENTRE", "ZDIVINGCENTER")
    notes_col   = col_or_null(cc, "ZNOTES")
    diver_col   = col_or_null(cc, "ZRELATIONSHIPDIVER", "ZDIVER")
    uuid_col    = col_or_null(cc, "ZUUID")

    sql = f"""
        SELECT Z_PK,
               {uuid_col},
               {name_col},
               {org_col},
               {level_col},
               {num_col},
               {date_col},
               {exp_col},
               {inst_col},
               {instnum_col},
               {centre_col},
               {notes_col},
               {diver_col}
        FROM "{cert_table}"
    """
    cur.execute(sql)
    results = []
    for row in cur.fetchall():
        (pk, uuid, name, org, level, number, date_ts, exp_ts,
         inst_name, inst_num, centre, notes, diver_fk) = row
        diver_name = divers.get(int(diver_fk) if diver_fk is not None else None, "")
        results.append({
            "uuid":             uuid or "",
            "name":             (name      or "").strip(),
            "diver_name":       diver_name,
            "organization":     (org       or "").strip(),
            "level":            (level     or "").strip(),
            "number":           str(number   or "").strip(),
            "issue_date":       coredata_to_str(date_ts) if date_ts is not None else "",
            "expiration_date":  coredata_to_str(exp_ts)  if exp_ts  is not None else "",
            "instructor_name":  (inst_name or "").strip(),
            "instructor_number": str(inst_num or "").strip(),
            "diving_centre":    (centre    or "").strip(),
            "notes":            (notes     or "").strip(),
        })
    return results


def export_certifications(input_path, output_path):
    _reset_schema_caches()
    con = sqlite3.connect(input_path)
    cur = con.cursor()

    divers = load_divers(cur)
    certs  = load_certifications_list(cur, divers)

    lines = []
    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    lines.append("<blueDiveCertificationExport>")
    lines.append("  <metadata>")
    lines.append(xtag("software",           "BlueDive", indent=4))
    lines.append(xtag("version",            "1.0",      indent=4))
    lines.append(xtag("exportedAt",         datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S"), indent=4))
    lines.append(xtag("certificationCount", str(len(certs)), indent=4))
    lines.append("  </metadata>")

    lines.append("  <certifications>")
    for c in certs:
        lines.append("    <certification>")
        lines.append(xtag("id",                  c["uuid"],              indent=6))
        lines.append(xtag("name",                c["name"],              indent=6))
        lines.append(xtag("diverName",           c["diver_name"],        indent=6))
        lines.append(xtag("organization",        c["organization"],      indent=6))
        lines.append(xtag("level",               c["level"],             indent=6))
        lines.append(xtag("certificationNumber", c["number"],            indent=6))
        lines.append(xtag("issueDate",           c["issue_date"],        indent=6))
        lines.append(xtag("expirationDate",      c["expiration_date"],   indent=6))
        lines.append(xtag("instructorName",      c["instructor_name"],   indent=6))
        lines.append(xtag("instructorNumber",    c["instructor_number"], indent=6))
        lines.append(xtag("divingCentre",        c["diving_centre"],     indent=6))
        lines.append(xtag("notes",               c["notes"],             indent=6))
        lines.append("    </certification>")
    lines.append("  </certifications>")
    lines.append("</blueDiveCertificationExport>")
    con.close()

    Path(output_path).write_text("\n".join(lines), encoding="utf-8")
    print(f"✓ {len(certs)} certifications exported to {output_path}")


# ---------------------------------------------------------------------------
# Schema diagnostic
# ---------------------------------------------------------------------------

def cmd_schema(input_path):
    """Print all tables and their columns — useful for diagnosing missing data."""
    _reset_schema_caches()
    con = sqlite3.connect(input_path)
    cur = con.cursor()
    cur.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
    tables = [row[0] for row in cur.fetchall()]
    for tbl in tables:
        cur.execute(f'PRAGMA table_info("{tbl}")')
        cols = [row[1] for row in cur.fetchall()]
        print(f"{tbl}")
        for c in cols:
            print(f"  {c}")
    # Highlight ZSERVICERECORD FK situation
    if "ZSERVICERECORD" in tables:
        fk = _service_record_fk_col(cur)
        print(f"\nZSERVICERECORD FK column detected: {fk or '(none found)'}")
        if fk:
            cur.execute(f'SELECT COUNT(*) FROM ZSERVICERECORD WHERE "{fk}" IS NOT NULL')
            print(f"  Rows with a linked gear item: {cur.fetchone()[0]}")
    else:
        print("\nZSERVICERECORD table: not found")
    # Highlight certification table
    cert_table = next((n for n in ("ZCERTIFICATION", "ZCERT", "ZCERTIFICATE") if n in tables), None)
    if cert_table:
        cur.execute(f'SELECT COUNT(*) FROM "{cert_table}"')
        print(f"\nCertification table: {cert_table} ({cur.fetchone()[0]} rows)")
    else:
        print("\nCertification table: not found")
    con.close()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Convert a MacDive SQLite database to a BlueDive XML file.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Inspect database schema
  python3 macdive_to_bluedive.py MacDive.sqlite --schema

  # Export dive log with profile samples (distance/temp/pressure/volume auto-detected from XML)
  python3 macdive_to_bluedive.py MacDive.sqlite dives.xml --export dives \\
      --weight-unit kg --macdive-xml MacDive-Export.xml

  # Export all gear
  python3 macdive_to_bluedive.py MacDive.sqlite gear.xml --export gears \\
      --weight-unit kg

  # Export all certifications
  python3 macdive_to_bluedive.py MacDive.sqlite certs.xml --export certifications
        """,
    )
    parser.add_argument("input",  help="Path to the MacDive .sqlite file")
    parser.add_argument("output", nargs="?", help="Destination path for the output XML file (omit with --schema)")
    parser.add_argument("--export",
                        choices=["dives", "gears", "certifications"],
                        default="dives",
                        dest="export_type",
                        help="Type of data to export (default: dives)")
    parser.add_argument("--schema", action="store_true",
                        help="Print database schema and exit (no conversion)")
    parser.add_argument("--weight-unit", choices=["kg", "lbs"], dest="weight",
                        help="Default weight unit; an embedded unit token in a weight "
                             "field (e.g. '9 kg') overrides it per record  [required for dives, gears]")
    parser.add_argument("--macdive-xml", dest="macdive_xml", default=None,
                        help="Path to a MacDive XML export — units and profile samples are read from it  [required for dives]")
    args = parser.parse_args()

    if not Path(args.input).exists():
        print(f"Error: file not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    if args.schema:
        cmd_schema(args.input)
        return

    if not args.output:
        parser.error("output path is required")

    if args.export_type == "dives":
        missing = [flag for flag, val in [
            ("--weight-unit", args.weight),
            ("--macdive-xml", args.macdive_xml),
        ] if val is None]
        if missing:
            parser.error(f"--export dives requires: {', '.join(missing)}")
        if not Path(args.macdive_xml).exists():
            parser.error(f"MacDive XML file not found: {args.macdive_xml}")
        export_dives(args.input, args.output, args.weight, macdive_xml_path=args.macdive_xml)

    elif args.export_type == "gears":
        if args.weight is None:
            parser.error("--export gears requires: --weight-unit")
        export_gears(args.input, args.output, args.weight)

    elif args.export_type == "certifications":
        export_certifications(args.input, args.output)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--libdc-worker":
        _libdc_worker_main(sys.argv[2])   # internal: libdivecomputer decoding process
    else:
        main()
