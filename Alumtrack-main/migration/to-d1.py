"""
Converts a Convex snapshot export into D1-ready SQL.

Reads the .zip produced by `npx convex export` and emits INSERT statements
for the thirteen tables the Workers backend uses. Tables left over from
earlier versions of the app (gpsPings, buses, students, auth*) are ignored
rather than guessed at — they have no counterpart in the current schema.

Two conversions matter:
  * Convex's `_id` becomes the explicit TEXT primary key, so ids already
    baked into flashed devices, stored sessions and client state stay valid.
  * Booleans become 0/1 and `roadPolyline` is re-serialised as a JSON
    string, matching the SQLite column types in schema.sql.

Usage:
    python to-d1.py convex-snapshot-YYYYMMDD.zip > import.sql
"""

import json
import sys
import zipfile

# Column order per table, matching schema.sql. Anything not listed is
# dropped deliberately: Convex's _creationTime is redundant once createdAt
# is carried across, and system fields have no column.
TABLES = {
    "routes": ["id", "number", "name", "active", "scheduledArrival",
               "roadPolyline", "roadPolylineFetchedAt", "createdAt"],
    "stops": ["id", "routeId", "seq", "name", "lat", "lng", "scheduledAt", "createdAt"],
    "devices": ["id", "deviceId", "routeId", "label", "tokenHash", "revoked",
                "lastSeen", "firmware", "rssi", "createdAt"],
    "positions": ["id", "routeId", "lat", "lng", "speedKph", "headingDeg",
                  "accuracyM", "satellites", "recordedAt", "source",
                  "deviceId", "riderId", "createdAt"],
    "liveState": ["id", "routeId", "lat", "lng", "speedKph", "headingDeg",
                  "progress", "nextStopSeq", "etaSeconds", "delaySeconds",
                  "updatedAt", "source", "accuracyM"],
    "riderShares": ["id", "routeId", "riderId", "startedAt", "lastSeen", "active"],
    "alerts": ["id", "routeId", "routeNumber", "kind", "message", "createdAt", "stopSeq"],
    "users": ["id", "subject", "email", "name", "pictureUrl", "isGuest",
              "passwordHash", "linkedRouteId", "linkedStopId",
              "notifyLeadMinutes", "createdAt", "lastSeenAt"],
    "alertReads": ["id", "subject", "readThrough"],
    "admins": ["id", "email", "passwordHash", "name", "role", "active",
               "createdAt", "lastLoginAt"],
    "feedback": ["id", "routeId", "subject", "rating", "comment",
                 "tripEndedAt", "createdAt"],
    "sessions": ["id", "tokenHash", "subject", "createdAt", "expiresAt"],
}

# Foreign-key columns the schema declares NOT NULL. A dangling reference in
# one of these cannot be repaired by nulling it, so the import stops instead.
NOT_NULL_FKS = {
    "stops": ("routeId",),
    "devices": ("routeId",),
    "positions": ("routeId",),
    "liveState": ("routeId",),
    "riderShares": ("routeId",),
    "feedback": ("routeId",),
}

# Columns the schema declares NOT NULL but Convex documents may omit,
# because the field was added after those rows were written.
DEFAULTS = {
    ("routes", "active"): 1,
    ("routes", "createdAt"): 0,
    ("stops", "createdAt"): 0,
    ("devices", "revoked"): 0,
    ("devices", "createdAt"): 0,
    ("positions", "createdAt"): 0,
    ("riderShares", "active"): 1,
    ("users", "isGuest"): 0,
    ("users", "notifyLeadMinutes"): 5,
    ("users", "createdAt"): 0,
    ("users", "lastSeenAt"): 0,
    ("admins", "active"): 1,
    ("admins", "createdAt"): 0,
}


def sql_literal(value):
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, (dict, list)):
        # roadPolyline and anything else structured: store as JSON text.
        return "'" + json.dumps(value, separators=(",", ":")).replace("'", "''") + "'"
    return "'" + str(value).replace("'", "''") + "'"


def main(path):
    z = zipfile.ZipFile(path)
    out = []
    out.append("PRAGMA foreign_keys = OFF;")
    out.append("BEGIN TRANSACTION;")

    # Convex had no referential integrity, so a few rows point at documents
    # that were since deleted — users pinned to a boarding stop on a route
    # whose stops were later replaced, which deletes and recreates stop rows
    # under new ids. Those references are dropped rather than carried over:
    # the SQL schema declares ON DELETE SET NULL for exactly this case, so
    # nulling them is what the database would have done had the constraint
    # existed at the time.
    valid_ids = {}
    for ref_table in ("routes", "stops"):
        entry = f"{ref_table}/documents.jsonl"
        if entry in z.namelist():
            valid_ids[ref_table] = {
                json.loads(l)["_id"]
                for l in z.read(entry).decode("utf-8").splitlines()
                if l.strip()
            }

    # column -> which table it must reference
    FK_COLUMNS = {
        "routeId": "routes",
        "linkedRouteId": "routes",
        "linkedStopId": "stops",
    }

    counts = {}
    dropped_refs = 0
    for table, columns in TABLES.items():
        entry = f"{table}/documents.jsonl"
        if entry not in z.namelist():
            continue

        rows = []
        for line in z.read(entry).decode("utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            doc = json.loads(line)

            values = []
            for col in columns:
                if col == "id":
                    values.append(sql_literal(doc.get("_id")))
                    continue
                raw = doc.get(col)

                # Drop references to rows that no longer exist (see above).
                # Only safe where the column is nullable: a dangling
                # reference in a NOT NULL column means the row itself is
                # unsalvageable, so fail loudly rather than write something
                # the schema will reject or, worse, silently distort.
                ref_table = FK_COLUMNS.get(col)
                if raw is not None and ref_table and ref_table in valid_ids:
                    if raw not in valid_ids[ref_table]:
                        if col in NOT_NULL_FKS.get(table, ()):
                            raise SystemExit(
                                f"{table}.{col} references missing {ref_table} row "
                                f"{raw!r}, but the column is NOT NULL. Resolve this "
                                f"row in the source data before importing."
                            )
                        raw = None
                        dropped_refs += 1

                if raw is None:
                    raw = DEFAULTS.get((table, col))
                    # createdAt defaulted to 0 above is a poor stand-in when
                    # Convex recorded a real creation time; prefer that.
                    if col == "createdAt" and raw == 0 and "_creationTime" in doc:
                        raw = int(doc["_creationTime"])
                values.append(sql_literal(raw))
            rows.append("(" + ", ".join(values) + ")")

        if not rows:
            continue
        counts[table] = len(rows)

        collist = ", ".join(columns)
        # Chunked by *bytes*, not row count: a routes row carries an entire
        # road polyline (hundreds of coordinate pairs), so fifty of them in
        # one statement blows past SQLite's statement limit — SQLITE_TOOBIG
        # — while fifty alert rows are trivial. Budgeting by size handles
        # both without tuning per table.
        MAX_STATEMENT_BYTES = 60_000
        chunk: list[str] = []
        size = 0
        for row in rows:
            if chunk and size + len(row) > MAX_STATEMENT_BYTES:
                out.append(
                    f"INSERT OR REPLACE INTO {table} ({collist}) VALUES\n  "
                    + ",\n  ".join(chunk) + ";"
                )
                chunk, size = [], 0
            chunk.append(row)
            size += len(row)
        if chunk:
            out.append(
                f"INSERT OR REPLACE INTO {table} ({collist}) VALUES\n  "
                + ",\n  ".join(chunk) + ";"
            )

    out.append("COMMIT;")
    out.append("PRAGMA foreign_keys = ON;")

    sys.stderr.write("rows per table:\n")
    for t, n in counts.items():
        sys.stderr.write(f"  {t:14s} {n:>6,}\n")

    print("\n".join(out))


if __name__ == "__main__":
    main(sys.argv[1])
