"""Unit tests that run in CI without Azure: validation rules and the routes that don't touch the database."""
from fastapi.testclient import TestClient

from larkspur.db import _token_struct
from larkspur.main import app
from larkspur.validation import is_valid_tracking_number

client = TestClient(app)


def test_valid_tracking_numbers():
    assert is_valid_tracking_number("LRK100001")
    assert is_valid_tracking_number("LRK999999")


def test_invalid_tracking_numbers():
    for value in ["", "LRK10000", "LRK1000011", "lrk100001", "ABC100001", "LRK10000A", "LRK100001; DROP TABLE x"]:
        assert not is_valid_tracking_number(value), value


def test_healthz():
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_bad_tracking_number_is_rejected_before_any_database_call():
    # No SQL settings exist in CI, so reaching the database code would raise; a 400 proves validation runs first.
    response = client.get("/shipments/not-a-number")
    assert response.status_code == 400


def test_token_struct_is_length_prefixed_utf16():
    packed = _token_struct("abc")
    assert packed[:4] == (6).to_bytes(4, "little")
    assert packed[4:] == "abc".encode("utf-16-le")
