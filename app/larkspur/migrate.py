"""Database migration and secret seeding, run as a Container Apps job (python -m larkspur.migrate).

Runs as the MIGRATOR identity (a member of the lark-sql-admins group), from inside the VNet, because the database
and Key Vault accept no public connections. Every step is idempotent, so the job can run every session.

  1. Create dbo.Shipments if it doesn't exist.
  2. Seed synthetic shipments if the table is empty.
  3. Create a contained database user for the APP identity and grant it SELECT on dbo.Shipments only.
     The user is created WITH SID = <client ID>, TYPE = E, which needs no Microsoft Graph lookup, so the SQL server
     doesn't need directory-read permissions. If the app identity was ever recreated (new client ID), the stale user
     is dropped and recreated.
  4. Create the synthetic carrier API key in Key Vault if it doesn't exist (value generated here, never printed).

Output lines start with LARK-MIGRATE so they're easy to find in Log Analytics.
"""
import os
import secrets
import sys

from .db import connect

SCHEMA_SQL = """
IF OBJECT_ID(N'dbo.Shipments', N'U') IS NULL
CREATE TABLE dbo.Shipments (
    TrackingNumber  char(9)       NOT NULL CONSTRAINT PK_Shipments PRIMARY KEY,
    Origin          nvarchar(64)  NOT NULL,
    Destination     nvarchar(64)  NOT NULL,
    Status          nvarchar(32)  NOT NULL,
    LastUpdatedUtc  datetime2(0)  NOT NULL
);
"""

# Synthetic data for a fictional company.
SEED_ROWS = [
    ("LRK100001", "Larkspur HQ", "North Depot", "Delivered"),
    ("LRK100002", "North Depot", "East Depot", "In transit"),
    ("LRK100003", "East Depot", "South Depot", "Out for delivery"),
    ("LRK100004", "South Depot", "Larkspur HQ", "Label created"),
    ("LRK100005", "Larkspur HQ", "West Depot", "Delayed: weather"),
]

APP_USER_SQL = """
DECLARE @name sysname = ?, @cid uniqueidentifier = ?;
DECLARE @sid varbinary(16) = CAST(@cid AS varbinary(16));
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @name AND sid <> @sid)
BEGIN
    DECLARE @drop nvarchar(max) = N'DROP USER ' + QUOTENAME(@name) + N';';
    EXEC (@drop);
    PRINT 'stale user dropped';
END
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @name)
BEGIN
    DECLARE @create nvarchar(max) = N'CREATE USER ' + QUOTENAME(@name)
        + N' WITH SID = ' + CONVERT(nvarchar(64), @sid, 1) + N', TYPE = E;';
    EXEC (@create);
END
DECLARE @grant nvarchar(max) = N'GRANT SELECT ON dbo.Shipments TO ' + QUOTENAME(@name) + N';';
EXEC (@grant);
"""


def say(message: str) -> None:
    print(f"LARK-MIGRATE {message}", flush=True)


def main() -> int:
    server = os.environ["SQL_SERVER"]
    database = os.environ["SQL_DATABASE"]
    migrator_client_id = os.environ["AZURE_CLIENT_ID"]
    app_identity_name = os.environ["APP_IDENTITY_NAME"]
    app_identity_client_id = os.environ["APP_IDENTITY_CLIENT_ID"]
    vault_uri = os.environ["KEY_VAULT_URI"]
    secret_name = os.environ.get("CARRIER_SECRET_NAME", "carrier-api-key")

    with connect(server, database, migrator_client_id) as conn:
        cursor = conn.cursor()
        cursor.execute(SCHEMA_SQL)
        conn.commit()
        say("schema ok: dbo.Shipments")

        count = cursor.execute("SELECT COUNT(*) FROM dbo.Shipments").fetchone()[0]
        if count == 0:
            cursor.executemany(
                "INSERT INTO dbo.Shipments (TrackingNumber, Origin, Destination, Status, LastUpdatedUtc) "
                "VALUES (?, ?, ?, ?, SYSUTCDATETIME())",
                SEED_ROWS,
            )
            conn.commit()
            say(f"seeded {len(SEED_ROWS)} shipments")
        else:
            say(f"seed skipped: {count} shipments already present")

        cursor.execute(APP_USER_SQL, app_identity_name, app_identity_client_id)
        conn.commit()
        perms = cursor.execute(
            "SELECT p.permission_name, OBJECT_NAME(p.major_id) FROM sys.database_permissions p "
            "JOIN sys.database_principals u ON u.principal_id = p.grantee_principal_id "
            "WHERE u.name = ? AND p.class = 1",
            app_identity_name,
        ).fetchall()
        say(f"app user {app_identity_name}: " + ", ".join(f"{p[0]} on {p[1]}" for p in perms))

    from azure.core.exceptions import ResourceNotFoundError
    from azure.identity import ManagedIdentityCredential
    from azure.keyvault.secrets import SecretClient

    client = SecretClient(vault_uri, ManagedIdentityCredential(client_id=migrator_client_id))
    try:
        client.get_secret(secret_name)
        say(f"secret {secret_name}: already exists")
    except ResourceNotFoundError:
        client.set_secret(secret_name, secrets.token_urlsafe(32), content_type="synthetic carrier API key")
        say(f"secret {secret_name}: created (value generated, not printed)")

    say("completed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
