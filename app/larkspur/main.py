"""Larkspur shipment-tracking API.

Endpoints
  GET /healthz                      liveness: the process is up (no dependencies, used by the platform probes)
  GET /readyz                       readiness: private DNS, SQL and Key Vault all reachable with the managed identity
  GET /shipments/{tracking_number}  a shipment's current status

Security notes
- The app identity can only SELECT from dbo.Shipments (granted by the migration job), and read secrets.
- Secret values are never returned or logged; /readyz only reports that the secret exists.
"""
import logging
import socket

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse

from .config import load_settings
from .validation import is_valid_tracking_number

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("larkspur.api")

app = FastAPI(title="Larkspur shipment tracking API", version="1.0.0")


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/readyz")
def readyz():
    from azure.identity import ManagedIdentityCredential
    from azure.keyvault.secrets import SecretClient

    from .db import connect

    settings = load_settings()
    checks = {}

    try:
        checks["sql_dns"] = {"ok": True, "address": socket.gethostbyname(settings.sql_server)}
    except OSError as exc:
        checks["sql_dns"] = {"ok": False, "error": str(exc)}

    try:
        with connect(settings.sql_server, settings.sql_database, settings.client_id) as conn:
            count = conn.cursor().execute("SELECT COUNT(*) FROM dbo.Shipments").fetchone()[0]
        checks["sql"] = {"ok": True, "shipments": count}
    except Exception as exc:  # report, don't crash: readiness is a diagnostic
        checks["sql"] = {"ok": False, "error": type(exc).__name__, "detail": str(exc)[:300]}

    try:
        client = SecretClient(settings.key_vault_uri, ManagedIdentityCredential(client_id=settings.client_id))
        secret = client.get_secret(settings.carrier_secret_name)
        checks["key_vault"] = {"ok": True, "secret": settings.carrier_secret_name, "present": bool(secret.value)}
    except Exception as exc:
        checks["key_vault"] = {"ok": False, "error": type(exc).__name__, "detail": str(exc)[:300]}

    ready = all(check["ok"] for check in checks.values())
    log.info("readyz ready=%s %s", ready, {name: check["ok"] for name, check in checks.items()})
    return JSONResponse(status_code=200 if ready else 503, content={"ready": ready, "checks": checks})


@app.get("/shipments/{tracking_number}")
def get_shipment(tracking_number: str):
    if not is_valid_tracking_number(tracking_number):
        raise HTTPException(status_code=400, detail="Tracking numbers look like LRK123456.")

    from .db import connect

    settings = load_settings()
    with connect(settings.sql_server, settings.sql_database, settings.client_id) as conn:
        row = conn.cursor().execute(
            "SELECT TrackingNumber, Origin, Destination, Status, LastUpdatedUtc FROM dbo.Shipments WHERE TrackingNumber = ?",
            tracking_number,
        ).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="Shipment not found.")
    return {
        "trackingNumber": row.TrackingNumber,
        "origin": row.Origin,
        "destination": row.Destination,
        "status": row.Status,
        "lastUpdatedUtc": row.LastUpdatedUtc.isoformat() + "Z",
    }
