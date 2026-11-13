"""Settings come from environment variables set by the Container App / job definition in Bicep.

Nothing here is a secret: the app authenticates with its managed identity, so there are no passwords or connection
strings to protect. AZURE_CLIENT_ID selects which user-assigned identity to use.
"""
import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    sql_server: str          # e.g. sql-lark-xxxx.database.windows.net
    sql_database: str        # sqldb-lark-tracking
    key_vault_uri: str       # https://kv-lark-xxxx.vault.azure.net/
    client_id: str           # client ID of this workload's user-assigned managed identity
    carrier_secret_name: str = "carrier-api-key"


def load_settings() -> Settings:
    """Read settings at call time (not import time) so tests can import the app without Azure configuration."""
    missing = [name for name in ("SQL_SERVER", "SQL_DATABASE", "KEY_VAULT_URI", "AZURE_CLIENT_ID") if not os.environ.get(name)]
    if missing:
        raise RuntimeError(f"Missing required environment variables: {', '.join(missing)}")
    return Settings(
        sql_server=os.environ["SQL_SERVER"],
        sql_database=os.environ["SQL_DATABASE"],
        key_vault_uri=os.environ["KEY_VAULT_URI"],
        client_id=os.environ["AZURE_CLIENT_ID"],
        carrier_secret_name=os.environ.get("CARRIER_SECRET_NAME", "carrier-api-key"),
    )
