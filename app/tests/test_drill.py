"""Unit tests for the recovery drill commands that run without Azure: argument rules and safety guards."""
import argparse

import pytest

from larkspur import drill


def test_database_names_are_limited_to_larkspur_tracking_databases():
    assert drill.validate_database("sqldb-lark-tracking") == "sqldb-lark-tracking"
    assert drill.validate_database("sqldb-lark-tracking-restore") == "sqldb-lark-tracking-restore"
    for bad in ["", "master", "sqldb-other", "sqldb-lark-tracking;DROP", "SQLDB-LARK-TRACKING", "sqldb-lark-tracking x"]:
        with pytest.raises(argparse.ArgumentTypeError):
            drill.validate_database(bad)


def test_compare_and_repair_require_a_named_copy():
    parser = drill.build_parser()
    with pytest.raises(SystemExit):
        parser.parse_args(["compare"])
    with pytest.raises(SystemExit):
        parser.parse_args(["repair"])
    args = parser.parse_args(["repair", "--source", "sqldb-lark-tracking-restore", "--confirm"])
    assert args.source == "sqldb-lark-tracking-restore" and args.confirm


def test_mark_limits():
    parser = drill.build_parser()
    assert parser.parse_args(["mark", "--count", "10", "--interval", "30"]).count == 10
    with pytest.raises(SystemExit):
        parser.parse_args(["mark", "--count", "0"])
    with pytest.raises(SystemExit):
        parser.parse_args(["mark", "--interval", "999"])


@pytest.mark.parametrize("command", ["corrupt", "secret-delete"])
def test_destructive_commands_refuse_without_confirm(command, capsys):
    args = drill.build_parser().parse_args([command])
    env = {"server": "unused", "database": "sqldb-lark-tracking", "client_id": "unused",
           "vault_uri": "https://unused", "secret_name": "carrier-api-key"}
    assert drill.COMMANDS[command](env, args) == 2
    assert "refusing" in capsys.readouterr().out


def test_repair_refuses_the_live_database_as_its_source(capsys):
    args = drill.build_parser().parse_args(["repair", "--source", "sqldb-lark-tracking", "--confirm"])
    env = {"server": "unused", "database": "sqldb-lark-tracking", "client_id": "unused",
           "vault_uri": "https://unused", "secret_name": "carrier-api-key"}
    assert drill.cmd_repair(env, args) == 2
    assert "restored copy" in capsys.readouterr().out


def test_value_fingerprint_is_short_and_stable():
    assert drill.value_fingerprint("abc") == drill.value_fingerprint("abc")
    assert len(drill.value_fingerprint("abc")) == 12
    assert drill.value_fingerprint("abc") != drill.value_fingerprint("abd")
