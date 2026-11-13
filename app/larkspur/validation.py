"""Input validation, kept free of Azure dependencies so it can be unit-tested anywhere."""
import re

# Larkspur tracking numbers: "LRK" followed by 6 digits, e.g. LRK100001.
TRACKING_NUMBER = re.compile(r"^LRK\d{6}$")


def is_valid_tracking_number(value: str) -> bool:
    """True only for well-formed tracking numbers. Queries are parameterized anyway; this rejects junk early with a
    clear 400 instead of a database round trip."""
    return bool(TRACKING_NUMBER.fullmatch(value or ""))
