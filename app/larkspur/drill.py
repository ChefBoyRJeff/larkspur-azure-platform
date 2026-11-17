"""Recovery drills (M7), run as the Container Apps job job-lark-drill (python -m larkspur.drill <command>).

Runs as the MIGRATOR identity (lark-sql-admins, Key Vault Secrets Officer) from inside the VNet, because the database
and Key Vault accept no public connections. The point-in-time restore itself is a control-plane operation and runs from
my PC; this module does the data-plane parts: generate activity, cause the damage, verify the restored copy, repair.

Commands
  mark --count N --interval S     write N timestamped rows to dbo.DrillMarkers, S seconds apart (simulated activity;
                                  the restored copy's newest marker measures the real RPO)
  corrupt --confirm               the simulated incident: overwrite every shipment's Status
  snapshot [--database NAME]      row count, checksum, status breakdown and newest marker of one database
  compare --target NAME           snapshot of the live database next to the restored copy
  repair --source NAME --confirm  copy Status and LastUpdatedUtc back from the restored copy where they differ
  secret-delete --confirm         delete the carrier API secret (it goes to Key Vault soft delete)
  secret-recover                  recover it from soft delete
  secret-check                    show whether it exists, its version and a short hash of its value (never the value)

Every output line starts with LARK-DRILL so it's easy to find in ContainerAppConsoleLogs. Times are UTC.
"""
import argparse
import hashlib
import os
import re
import sys
import time
from datetime import datetime, timezone

PROD_DATABASE_ENV = "SQL_DATABASE"
DATABASE_NAME = re.compile(r"^sqldb-lark-tracking[a-z0-9-]{0,40}$")
CORRUPT_STATUS = "LOST: drill"

MARKER_SCHEMA_SQL = """
IF OBJECT_ID(N'dbo.DrillMarkers', N'U') IS NULL
CREATE TABLE dbo.DrillMarkers (
    Id          int IDENTITY(1,1) NOT NULL CONSTRAINT PK_DrillMarkers PRIMARY KEY,
    WrittenUtc  datetime2(3)      NOT NULL CONSTRAINT DF_DrillMarkers_WrittenUtc DEFAULT SYSUTCDATETIME(),
    Note        nvarchar(64)      NOT NULL
);
"""

SNAPSHOT_SQL = (
    "SELECT COUNT(*), CHECKSUM_AGG(BINARY_CHECKSUM(TrackingNumber, Origin, Destination, Status, LastUpdatedUtc)) "
    "FROM dbo.Shipments"
)
STATUS_SQL = "SELECT Status, COUNT(*) FROM dbo.Shipments GROUP BY Status ORDER BY Status"
NEWEST_MARKER_SQL = (
    "IF OBJECT_ID(N'dbo.DrillMarkers', N'U') IS NULL SELECT CAST(0 AS int), CAST(NULL AS datetime2(3)) "
    "ELSE SELECT COUNT(*), MAX(WrittenUtc) FROM dbo.DrillMarkers"
)


def say(message: str) -> None:
    print(f"LARK-DRILL {message}", flush=True)


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def validate_database(name: str) -> str:
    """Only Larkspur tracking databases (the live one or a restored copy) can be targeted."""
    if not DATABASE_NAME.match(name or ""):
        raise argparse.ArgumentTypeError(f"not a Larkspur tracking database name: {name!r}")
    return name


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="larkspur.drill", description="Larkspur recovery drills (M7)")
    sub = parser.add_subparsers(dest="command", required=True)

    mark = sub.add_parser("mark", help="write timestamped marker rows (simulated activity)")
    mark.add_argument("--count", type=int, default=10, choices=range(1, 61), metavar="1-60")
    mark.add_argument("--interval", type=int, default=30, choices=range(1, 301), metavar="1-300")

    corrupt = sub.add_parser("corrupt", help="the simulated incident: overwrite every shipment's Status")
    corrupt.add_argument("--confirm", action="store_true")

    snapshot = sub.add_parser("snapshot", help="summarize one database")
    snapshot.add_argument("--database", type=validate_database)

    compare = sub.add_parser("compare", help="live database next to a restored copy")
    compare.add_argument("--target", type=validate_database, required=True)

    repair = sub.add_parser("repair", help="copy Status back from a restored copy")
    repair.add_argument("--source", type=validate_database, required=True)
    repair.add_argument("--confirm", action="store_true")

    secret_delete = sub.add_parser("secret-delete", help="delete the carrier secret (soft delete)")
    secret_delete.add_argument("--confirm", action="store_true")
    sub.add_parser("secret-recover", help="recover the carrier secret from soft delete")
    sub.add_parser("secret-check", help="show whether the carrier secret exists (never its value)")
    return parser


def _env():
    return {
        "server": os.environ["SQL_SERVER"],
        "database": os.environ[PROD_DATABASE_ENV],
        "client_id": os.environ["AZURE_CLIENT_ID"],
        "vault_uri": os.environ["KEY_VAULT_URI"],
        "secret_name": os.environ.get("CARRIER_SECRET_NAME", "carrier-api-key"),
    }


def _connect(env, database):
    from .db import connect

    return connect(env["server"], database, env["client_id"])


def summarize(cursor):
    count, checksum = cursor.execute(SNAPSHOT_SQL).fetchone()
    statuses = {row[0]: row[1] for row in cursor.execute(STATUS_SQL).fetchall()}
    markers, newest = cursor.execute(NEWEST_MARKER_SQL).fetchone()
    return {
        "shipments": count,
        "checksum": checksum,
        "statuses": statuses,
        "markers": markers,
        "newest_marker_utc": newest.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z" if newest else None,
    }


def format_summary(name: str, s: dict) -> str:
    statuses = ", ".join(f"{k}={v}" for k, v in s["statuses"].items())
    return (f"{name}: shipments={s['shipments']} checksum={s['checksum']} markers={s['markers']} "
            f"newest_marker={s['newest_marker_utc']} statuses[{statuses}]")


def cmd_mark(env, args) -> int:
    with _connect(env, env["database"]) as conn:
        cursor = conn.cursor()
        cursor.execute(MARKER_SCHEMA_SQL)
        conn.commit()
        for i in range(1, args.count + 1):
            cursor.execute("INSERT INTO dbo.DrillMarkers (Note) VALUES (?)", f"marker {i} of {args.count}")
            conn.commit()
            say(f"marker {i}/{args.count} written at {utc_now()}")
            if i < args.count:
                time.sleep(args.interval)
    return 0


def cmd_corrupt(env, args) -> int:
    if not args.confirm:
        say("refusing to corrupt without --confirm")
        return 2
    with _connect(env, env["database"]) as conn:
        cursor = conn.cursor()
        say(f"before: {format_summary(env['database'], summarize(cursor))}")
        cursor.execute("UPDATE dbo.Shipments SET Status = ?", CORRUPT_STATUS)
        changed = cursor.rowcount
        conn.commit()
        say(f"INCIDENT at {utc_now()}: overwrote Status on {changed} shipments with '{CORRUPT_STATUS}'")
        say(f"after: {format_summary(env['database'], summarize(cursor))}")
    return 0


def cmd_snapshot(env, args) -> int:
    database = args.database or env["database"]
    with _connect(env, database) as conn:
        say(format_summary(database, summarize(conn.cursor())))
    return 0


def cmd_compare(env, args) -> int:
    with _connect(env, env["database"]) as live, _connect(env, args.target) as copy:
        a, b = summarize(live.cursor()), summarize(copy.cursor())
    say(format_summary(f"live {env['database']}", a))
    say(format_summary(f"copy {args.target}", b))
    say(f"shipments match={a['shipments'] == b['shipments']} checksum match={a['checksum'] == b['checksum']}")
    return 0


def cmd_repair(env, args) -> int:
    if not args.confirm:
        say("refusing to repair without --confirm")
        return 2
    if args.source == env["database"]:
        say("source must be the restored copy, not the live database")
        return 2
    with _connect(env, args.source) as copy:
        good = copy.cursor().execute(
            "SELECT TrackingNumber, Status, LastUpdatedUtc FROM dbo.Shipments").fetchall()
    with _connect(env, env["database"]) as live:
        cursor = live.cursor()
        repaired = 0
        for tracking_number, status, updated in good:
            cursor.execute(
                "UPDATE dbo.Shipments SET Status = ?, LastUpdatedUtc = ? "
                "WHERE TrackingNumber = ? AND (Status <> ? OR LastUpdatedUtc <> ?)",
                status, updated, tracking_number, status, updated)
            repaired += cursor.rowcount
        live.commit()
        say(f"repaired {repaired} of {len(good)} shipments from {args.source} at {utc_now()}")
        say(f"after: {format_summary(env['database'], summarize(cursor))}")
    return 0


def _secret_client(env):
    from azure.identity import ManagedIdentityCredential
    from azure.keyvault.secrets import SecretClient

    return SecretClient(env["vault_uri"], ManagedIdentityCredential(client_id=env["client_id"]))


def value_fingerprint(value: str) -> str:
    """First 12 hex characters of SHA-256: enough to prove the same value came back, useless for recovering it."""
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]


def cmd_secret_check(env, args) -> int:
    from azure.core.exceptions import ResourceNotFoundError

    client = _secret_client(env)
    try:
        secret = client.get_secret(env["secret_name"])
        say(f"secret {env['secret_name']}: present version={secret.properties.version[:8]}... "
            f"fingerprint={value_fingerprint(secret.value)}")
    except ResourceNotFoundError:
        say(f"secret {env['secret_name']}: NOT FOUND")
        try:
            deleted = client.get_deleted_secret(env["secret_name"])
            say(f"  soft-deleted at {deleted.deleted_date.isoformat()}; scheduled purge {deleted.scheduled_purge_date.isoformat()}")
        except ResourceNotFoundError:
            say("  not in soft delete either")
    return 0


def cmd_secret_delete(env, args) -> int:
    if not args.confirm:
        say("refusing to delete without --confirm")
        return 2
    cmd_secret_check(env, args)
    client = _secret_client(env)
    client.begin_delete_secret(env["secret_name"]).wait()
    say(f"secret {env['secret_name']} DELETED at {utc_now()}")
    cmd_secret_check(env, args)
    return 0


def cmd_secret_recover(env, args) -> int:
    client = _secret_client(env)
    client.begin_recover_deleted_secret(env["secret_name"]).wait()
    say(f"secret {env['secret_name']} RECOVERED at {utc_now()}")
    cmd_secret_check(env, args)
    return 0


COMMANDS = {
    "mark": cmd_mark,
    "corrupt": cmd_corrupt,
    "snapshot": cmd_snapshot,
    "compare": cmd_compare,
    "repair": cmd_repair,
    "secret-check": cmd_secret_check,
    "secret-delete": cmd_secret_delete,
    "secret-recover": cmd_secret_recover,
}


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    say(f"start {args.command} at {utc_now()}")
    code = COMMANDS[args.command](_env(), args)
    say(f"end {args.command} exit={code}")
    return code


if __name__ == "__main__":
    sys.exit(main())
