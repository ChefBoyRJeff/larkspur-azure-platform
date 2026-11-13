"""Passwordless Azure SQL connections using a managed identity token.

The identity gets an Entra access token for Azure SQL and hands it to the ODBC driver (SQL_COPT_SS_ACCESS_TOKEN). There
is no username or password anywhere. Heavy imports happen inside the function so unit tests don't need the ODBC driver.
"""
import logging
import struct
import time

log = logging.getLogger("larkspur.db")

SQL_COPT_SS_ACCESS_TOKEN = 1256  # ODBC connection attribute for an Entra access token
SQL_TOKEN_SCOPE = "https://database.windows.net/.default"


def _token_struct(token: str) -> bytes:
    """The ODBC driver expects the token as UTF-16-LE bytes prefixed with their length."""
    raw = token.encode("utf-16-le")
    return struct.pack(f"<I{len(raw)}s", len(raw), raw)


def connect(server: str, database: str, client_id: str, attempts: int = 4, wait_seconds: int = 20):
    """Open a connection as the given user-assigned identity.

    Retries cover the free-tier database resuming from auto-pause: the first connection after a pause can fail with
    error 40613 ("database not currently available") while it wakes up, which takes up to about a minute.
    """
    import pyodbc
    from azure.identity import ManagedIdentityCredential

    credential = ManagedIdentityCredential(client_id=client_id)
    conn_str = (
        "Driver={ODBC Driver 18 for SQL Server};"
        f"Server=tcp:{server},1433;Database={database};"
        "Encrypt=yes;TrustServerCertificate=no;Connection Timeout=60"
    )
    last_error = None
    for attempt in range(1, attempts + 1):
        try:
            token = credential.get_token(SQL_TOKEN_SCOPE).token
            return pyodbc.connect(conn_str, attrs_before={SQL_COPT_SS_ACCESS_TOKEN: _token_struct(token)})
        except pyodbc.Error as exc:  # resume-from-pause and transient network errors
            last_error = exc
            log.warning("SQL connect attempt %s/%s failed: %s", attempt, attempts, exc)
            if attempt < attempts:
                time.sleep(wait_seconds)
    raise last_error
