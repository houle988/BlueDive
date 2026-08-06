#!/usr/bin/env python3
"""
macdive_to_bluedive.py
Convert a MacDive SQLite database to BlueDive XML files.

Usage:
    python3 macdive_to_bluedive.py <input.sqlite> <output.xml> --export <type> [options]

Export types:
    dives           Dive log with associated gear  (default)
    gears           All gear items and service history
    certifications  All certifications

Required flags by export type:
    dives           --weight-unit  --macdive-xml
    gears           --weight-unit
    certifications  (none)

Flags:
    --macdive-xml PATH
        Path to a MacDive XML export file (.xml).  Required for --export dives.

        MacDive XML exports are created from MacDive → File → Export → XML.
        The SQLite database and the XML export must come from the same MacDive library.

        Distance, temperature, pressure, and volume units are auto-detected from
        the XML's <units> tag:
            Metric   → metres, °C, bar, litres
            Canadian → metres, °C, bar, litres
            Imperial → feet, °F, PSI, cubic feet

        Weight unit must be specified with --weight-unit because the SQLite database
        stores whatever unit the user entered and this cannot be detected automatically.

        Timezone handling is automatic: the script converts both the SQLite CoreData
        timestamps (UTC) and the XML <date> strings (local time of the exporting Mac)
        to UTC before matching, so the script can be run on any machine regardless of
        its timezone.  Dives are matched by UTC timestamp, then narrowed by diver name
        (to separate family members who dive together) and by duration (±60 s, to resolve
        any remaining same-diver same-minute collisions).

        Note: run this script on the same Mac where you will import into BlueDive so
        that all date strings in the output are written in your local timezone, which is
        what the BlueDive XML parser expects.

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
import json
import re
import sqlite3
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
    # MacDive stores weight as freeform strings like "48 pounds", "9 kg", or "4,5 kg".
    # Extract the leading numeric part (including comma decimals) and re-format it.
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
        if o2raw is not None and float(o2raw) <= 1.0:
            o2_pct = round(float(o2raw) * 100)
        else:
            o2_pct = round(float(o2raw)) if o2raw is not None else 21
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


def fetch_critters(cur, dive_pk, critter_jt):
    """Return [{name, count}] for marine life sightings."""
    if not table_exists(cur, "ZCRITTER"):
        return []
    if critter_jt is None:
        return []
    tbl, c0, c1 = critter_jt
    c0u, c1u = c0.upper(), c1.upper()
    if c0u.endswith("TOCRITTER"):
        critter_col, dive_col = c0, c1
    elif c1u.endswith("TOCRITTER"):
        critter_col, dive_col = c1, c0
    else:
        critter_col, dive_col = c0, c1
    try:
        cur.execute(f"""
            SELECT c.ZNAME, COUNT(*) AS cnt
            FROM "{tbl}" j
            JOIN ZCRITTER c ON j."{critter_col}" = c.Z_PK
            WHERE j."{dive_col}" = ?
            GROUP BY c.ZNAME ORDER BY c.ZNAME
        """, (dive_pk,))
        return [{"name": row[0] or "", "count": row[1]} for row in cur.fetchall() if row[0]]
    except Exception:
        return []


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
            "weight_contribution": fmt_double(weight) if weight is not None else "0.0",
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
    "Canadian": {"distance": "meters", "temp": "C", "pressure": "bar", "volume": "liters", "weight": "kg"},
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
        print(f"Warning: could not parse MacDive XML '{xml_path}': {exc}", file=sys.stderr)
        return "", []

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
                "temperature": temp        if temp is not None and temp != 0.0 else None,
                "pressure":    pressure    if pressure and pressure > 0.0 else None,
                "ppo2":        ppo2        if ppo2     and ppo2     > 0.0 else None,
                "ndt":         int(ndt_raw) if ndt_raw and ndt_raw > 0.0 else None,
            })

        if samples:
            result.append({
                "date_str": date_str,
                "diver":    diver,
                "duration": duration,
                "samples":  samples,
            })

    print(f"  MacDive XML : {len(result)} dives with samples loaded from {xml_path}  (units={xml_units or 'unknown'})")
    return xml_units, result


def _norm_name(n):
    """Casefold, strip accents, collapse whitespace for fuzzy diver-name comparison."""
    n = unicodedata.normalize("NFKD", n or "").encode("ascii", "ignore").decode()
    return " ".join(n.casefold().split())


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
        if hits > best_hits:
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

    # P1 — resolve the timezone offset once for the whole file
    consensus_off, consensus_hits = _detect_consensus_offset(xml_dives, sqlite_utc_index)
    offsets_to_try = sorted({consensus_off - 1, consensus_off, consensus_off + 1})
    print(f"  Consensus UTC offset : {consensus_off:+d}h  ({consensus_hits} unambiguous hits)"
          f"  (trying offsets {offsets_to_try})")

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
        if xml_samples and c[3] is not None:
            xml_max_m = max(s["depth"] for s in xml_samples) * depth_factor
            if abs(xml_max_m - c[3]) > 5.0:
                print(f"  Warning: depth mismatch for {xml_dive['date_str']} "
                      f"(xml_max={xml_max_m:.1f} m  sqlite={c[3]:.1f} m) — rejected",
                      file=sys.stderr)
                unresolved.append((xi, "depth_mismatch", xml_dive["date_str"]))
                continue
        if xml_samples and c[2] is not None:
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
    pk_to_samples: dict = {}
    for xi, pk, dur_delta, depth_delta, samples in candidates_resolved:
        if pk in pk_to_samples:
            unresolved.append((xi, "outscored", xml_dives[xi]["date_str"]))
            continue
        pk_to_samples[pk] = samples

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

    return pk_to_samples


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
        if s.get("ppo2") is not None:
            attrs.append(f'ppo2="{fmt_double(s["ppo2"])}"')
        if s.get("ndt") is not None:
            attrs.append(f'ndl="{s["ndt"]}"')
        attrs.append('events=""')
        lines.append(f'{inner_pad}<sample {" ".join(attrs)}/>')
    lines.append(f'{pad}</profileSamples>')
    return lines


# ---------------------------------------------------------------------------
# Dive export
# ---------------------------------------------------------------------------

def export_dives(input_path, output_path, weight_unit, macdive_xml_path):
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
    print(f"  Units auto-detected: distance={units['distance']}  temp={units['temp']}  "
          f"pressure={units['pressure']}  volume={units['volume']}  weight={units['weight']}")

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
    critter_jt = find_junction(junctions, "CRITTERTODIVE")

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
        diver_join  = "LEFT JOIN ZDIVER dv ON dv.Z_PK = d.ZRELATIONSHIPDIVER" if has_diver_tbl else ""
        diver_expr  = "TRIM(COALESCE(dv.ZFIRSTNAME,'') || ' ' || COALESCE(dv.ZLASTNAME,''))" \
                      if has_diver_tbl else "''"
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

    pk_to_samples = match_samples_to_dives(xml_dives, sqlite_utc_index, xml_depth_in_feet=xml_depth_in_feet) if xml_dives else {}

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
        tanks      = fetch_tanks(cur, pk)

        buddy_names = junction_lookup(cur, pk, buddy_jt, buddies)
        type_names  = junction_lookup(cur, pk, type_jt,  types_lkp)
        tag_names   = junction_lookup(cur, pk, tag_jt,   tags_lkp)
        critters    = fetch_critters(cur, pk, critter_jt)
        gear_items  = fetch_dive_gear(cur, pk, gear_map, gear_jts)

        dur_secs = round(float(duration)) if duration is not None else 0

        lines.append("  <dive>")

        # Units — same value for all dives, set by CLI flags
        lines.append(xtag("distanceFormat",    distance_fmt, indent=4))
        lines.append(xtag("temperatureFormat", temp_fmt,     indent=4))
        lines.append(xtag("pressureFormat",    pressure_fmt, indent=4))
        lines.append(xtag("volumeFormat",      volume_fmt,   indent=4))
        lines.append(xtag("weightFormat",      weight_fmt,   indent=4))
        lines.append(xtag("sourceImport",      "MacDive",    indent=4))

        # Basic info
        lines.append(xtag("date",           coredata_to_str(ts),             indent=4))
        lines.append(xtag("identifier",     str(uuid or ""),                  indent=4))
        lines.append(xtag("diveNumber",     str(round(float(dive_num))) if dive_num is not None else "", indent=4))
        lines.append(xtag("rating",         str(round(float(rating))) if rating is not None else "", indent=4))
        # MacDive stores the dive number in the repetitive sequence (1 = first/solo dive,
        # 2+ = genuinely repetitive). Only flag as repetitive when the number is > 1.
        is_repetitive = repetitive is not None and int(float(repetitive)) > 1
        lines.append(xtag("repetitiveDive", "1" if is_repetitive else "0",  indent=4))
        lines.append(xtag("diver",          diver_name,                       indent=4))
        lines.append(xtag("computer",       comp_name,                        indent=4))
        lines.append(xtag("serial",         comp_serial,                      indent=4))

        # Dive stats — depth: SQLite always stores metres; convert to feet for imperial output.
        lines.append(xtag("maxDepth",        fmt_double(cvt_dist(max_depth)),  indent=4))
        lines.append(xtag("averageDepth",    fmt_double(cvt_dist(avg_depth)),  indent=4))
        lines.append(xtag("duration",        str(dur_secs),          indent=4))
        lines.append(xtag("surfaceInterval", str(round(float(surf_int))) if surf_int is not None else "", indent=4))

        # Decompression
        lines.append(xtag("cns",               fmt_double(cns),                          indent=4))
        lines.append(xtag("decoModel",         str(deco_model or ""),                    indent=4))
        lines.append(xtag("decompressionDive", "1" if is_deco else "0",                  indent=4))

        # Temperatures — SQLite always stores °C; convert to °F for imperial output.
        lines.append(xtag("tempAir",  fmt_double(cvt_temp(temp_air)),  indent=4))
        lines.append(xtag("tempHigh", fmt_double(cvt_temp(temp_high)), indent=4))
        lines.append(xtag("tempLow",  fmt_double(cvt_temp(temp_low)),  indent=4))

        # Conditions
        lines.append(xtag("visibility",        str(visibility  or ""), indent=4))
        lines.append(xtag("weight",            fmt_double(weight),     indent=4))
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
                lines.append(xtag("volume",          fmt_double(t.get("vol")),   indent=8))
                lines.append(xtag("startPressure",   fmt_double(t.get("start")), indent=8))
                lines.append(xtag("endPressure",     fmt_double(t.get("end")),   indent=8))
                lines.append(xtag("workingPressure", fmt_double(t.get("wp")),    indent=8))
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

        # Profile samples from MacDive XML (matched by UTC + diver + duration)
        samples = pk_to_samples.get(pk, [])
        if samples:
            # Convert sample depth from the XML's native unit to the output unit when they differ.
            if xml_depth_in_feet and units["distance"] == "meters":
                samples = [{**s, "depth": s["depth"] * 0.3048} for s in samples]
            elif not xml_depth_in_feet and units["distance"] == "feet":
                samples = [{**s, "depth": s["depth"] / 0.3048} for s in samples]
            # Canadian XML exports pressure in PSI but the output format is bar — convert.
            if xml_pressure_in_psi and units["pressure"] == "bar":
                samples = [{**s, "pressure": s["pressure"] / 14.5038 if s["pressure"] is not None else None} for s in samples]
            lines.append("    <!-- BlueDiveSamplesData -->")
            lines.extend(profile_samples_xml_lines(samples, indent=4))

        # Raw dive computer data (base64)
        if raw_data:
            b64_lines = base64_block("rawDiveComputerData", raw_data, indent=4)
            if b64_lines:
                lines.append("    <!-- Raw dive computer data (Base64-encoded binary) -->")
                lines.extend(b64_lines)

        # MacDive parser type hint — useful for future profile decoding in BlueDive
        if parser_type:
            lines.append(xtag("parserType", str(parser_type), indent=4))

        lines.append("  </dive>")

    lines.append("  </dives>")
    lines.append("</blueDiveExport>")
    con.close()

    Path(output_path).write_text("\n".join(lines), encoding="utf-8")
    print(f"✓ {len(rows)} dives exported to {output_path}")
    print(f"  Gear items  : {len(gear_map)}")
    print(f"  Distance    : {distance_fmt}")
    print(f"  Temperature : {temp_fmt}")
    print(f"  Pressure    : {pressure_fmt}")
    print(f"  Volume      : {volume_fmt}")
    print(f"  Weight      : {weight_fmt}")


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
    weight_fmt  = WEIGHT_FORMAT[weight_unit]

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
        lines.append(xtag("weightContribution",   g["weight_contribution"],    indent=6))
        lines.append(xtag("weightContributionUnit", weight_fmt,                indent=6))
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
    print(f"  Weight unit : {weight_fmt}")


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
                        help="Weight unit stored in the database  [required for dives, gears]")
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
    main()
