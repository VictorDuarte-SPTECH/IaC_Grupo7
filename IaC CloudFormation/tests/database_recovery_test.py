"""Offline contracts for the RecoveryAgent Python embedded in CloudFormation.

Run: python -m unittest discover -s "IaC_Grupo7\\IaC CloudFormation\\tests" -p database_recovery_test.py
"""

from contextlib import ExitStack
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import types
import unittest
from unittest import mock


TEST_DIR = Path(__file__).resolve().parent
TEMPLATE = TEST_DIR.parent / "cloudformationCodeTracker.yaml"


def load_agent():
    template = TEMPLATE.read_text(encoding="utf-8")
    resource = re.search(
        r"(?ms)^  DatabaseStandbyInstance:\s*\n(.*?)(?=^  [A-Za-z0-9]+:|\Z)",
        template,
    )
    if resource is None:
        raise AssertionError("DatabaseStandbyInstance resource not found")
    body = resource.group(1)
    marker = re.search(r"(?m)^( +)RecoveryAgent: \|\s*$", body)
    if marker is None:
        raise AssertionError("DatabaseStandbyInstance.Metadata.RecoveryAgent not found")
    lines = []
    for line in body[marker.end():].splitlines():
        if line.strip() and len(line) - len(line.lstrip()) <= len(marker.group(1)):
            break
        lines.append(line)
    source = textwrap.dedent("\n".join(lines))
    module = types.ModuleType("embedded_database_recovery")
    with ExitStack() as stack:
        if os.name == "nt":
            fcntl = types.ModuleType("fcntl")
            fcntl.LOCK_EX, fcntl.LOCK_NB = 2, 4
            fcntl.flock = mock.Mock()
            stack.enter_context(mock.patch.dict(sys.modules, {"fcntl": fcntl}))
        exec(compile(source, str(TEMPLATE) + ":RecoveryAgent", "exec"), module.__dict__)
    return module, body


AGENT, STANDBY_RESOURCE = load_agent()


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        directory = self.stack.enter_context(tempfile.TemporaryDirectory())
        self.root = Path(directory)
        self.role = self.root / "mysql-role.cnf"
        self.role.write_text("[mysqld]\nread_only=ON\nsuper_read_only=ON\n")
        self.recovery = AGENT.Recovery({
            "region": "us-east-1",
            "primary_id": "i-offline-primary",
            "standby_ip": "10.0.2.25",
            "zone_id": "ZOFFLINE",
            "endpoint": "mysql.internal.example",
            "database": "codetracker",
            "state_dir": str(self.root / "state"),
            "role_config": str(self.role),
        })
        self.run = self.stack.enter_context(mock.patch.object(
            self.recovery, "run", side_effect=AssertionError("Unexpected command")
        ))
        self.aws = self.stack.enter_context(mock.patch.object(
            self.recovery, "aws", side_effect=AssertionError("Unexpected AWS call")
        ))
        self.local = self.stack.enter_context(mock.patch.object(
            self.recovery, "local", return_value="1"
        ))
        self.sleep = self.stack.enter_context(mock.patch.object(AGENT.time, "sleep"))
        self.process = self.stack.enter_context(mock.patch.object(
            AGENT.subprocess, "run", side_effect=AssertionError("Real commands forbidden")
        ))
        if os.name == "nt":
            self.adapt_directory_fsync()

    def adapt_directory_fsync(self):
        # Windows cannot open/fsync a directory. Preserve real file fsync and
        # replacement while emulating only the Linux directory durability step.
        original_open, original_close, original_fsync = os.open, os.close, os.fsync
        directory_fd = -9876
        self.stack.enter_context(mock.patch.object(os, "O_DIRECTORY", 0, create=True))
        self.stack.enter_context(mock.patch.object(os, "fchmod", create=True))

        def open_path(path, flags, *args, **kwargs):
            if Path(path).is_dir():
                return directory_fd
            return original_open(path, flags, *args, **kwargs)

        self.stack.enter_context(mock.patch.object(os, "open", side_effect=open_path))
        self.stack.enter_context(mock.patch.object(
            os, "close",
            side_effect=lambda fd: None if fd == directory_fd else original_close(fd),
        ))
        self.stack.enter_context(mock.patch.object(
            os, "fsync",
            side_effect=lambda fd: None if fd == directory_fd else original_fsync(fd),
        ))

    def snapshot(self, content=b"old valid snapshot"):
        self.recovery.latest.write_bytes(content)
        return self.recovery.latest

    def mock_dump(self, content=b"new valid snapshot", error=None):
        def command(args, *, stdin=None, stdout=subprocess.PIPE, timeout=30):
            self.assertEqual(args[0], "mysqldump")
            self.assertIn("--single-transaction", args)
            self.assertIn(self.recovery.config["database"], args)
            stdout.write(content)
            if error:
                raise error
            return b""
        self.run.side_effect = command

    def prepare_promotion(self):
        self.snapshot()
        fence = self.stack.enter_context(mock.patch.object(self.recovery, "fence"))
        restore = self.stack.enter_context(mock.patch.object(self.recovery, "restore"))
        publish = self.stack.enter_context(mock.patch.object(self.recovery, "publish"))
        return fence, restore, publish

    def test_backup_timer_runs_dump_and_restore_every_twelve_hours(self):
        self.assertRegex(
            STANDBY_RESOURCE,
            r"(?m)^\s*OnCalendar=\*-\*-\* 00,12:00:00 UTC\s*$",
        )
        self.assertIn(
            "ExecStart=/usr/local/sbin/codetracker-database-recovery backup",
            STANDBY_RESOURCE,
        )
        self.mock_dump()
        with mock.patch.object(self.recovery, "restore") as restore:
            self.recovery.backup()
        restore.assert_called_once_with(self.recovery.state / "next.sql")
        self.assertEqual(self.recovery.latest.read_bytes(), b"new valid snapshot")
        self.assertTrue((self.recovery.state / "last-backup").exists())

    def test_backup_validates_before_atomically_replacing_latest(self):
        self.snapshot()
        self.mock_dump()
        original_replace = Path.replace
        replacements = []

        def replace(path, target):
            if Path(target) == self.recovery.latest:
                self.assertEqual(self.recovery.latest.read_bytes(), b"old valid snapshot")
                self.assertEqual(self.local.call_args.args[0],
                                 "SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;")
                replacements.append((path, target))
            return original_replace(path, target)

        def command(args, *, stdin=None, stdout=subprocess.PIPE, timeout=30):
            if args[0] == "mysqldump":
                stdout.write(b"new valid snapshot")
            else:
                self.assertEqual(args[0], "mysql")
                self.assertEqual(stdin.read(), b"new valid snapshot")
                self.assertEqual(self.recovery.latest.read_bytes(), b"old valid snapshot")
            return b""

        self.run.side_effect = command
        with mock.patch.object(Path, "replace", new=replace):
            self.recovery.backup()
        self.assertEqual(len(replacements), 1)
        self.assertTrue(any("information_schema.tables" in call.args[0]
                            for call in self.local.call_args_list))
        self.assertTrue(any("`codetracker`.usuario" in call.args[0]
                            for call in self.local.call_args_list))
        self.assertEqual(self.recovery.latest.read_bytes(), b"new valid snapshot")
        self.assertEqual((self.recovery.state / "previous.sql").read_bytes(),
                         b"old valid snapshot")
        self.assertFalse((self.recovery.state / "next.sql").exists())

    def test_failed_dump_preserves_latest_and_previous(self):
        self.snapshot()
        previous = self.recovery.state / "previous.sql"
        previous.write_bytes(b"older valid snapshot")
        self.mock_dump(b"partial", RuntimeError("dump failed"))
        with mock.patch.object(self.recovery, "restore") as restore:
            with self.assertRaises(RuntimeError):
                self.recovery.backup()
        restore.assert_not_called()
        self.assertEqual(self.recovery.latest.read_bytes(), b"old valid snapshot")
        self.assertEqual(previous.read_bytes(), b"older valid snapshot")
        self.assertFalse((self.recovery.state / "last-backup").exists())

    def test_empty_dump_preserves_latest_without_restore(self):
        self.snapshot()
        self.mock_dump(b"")
        with mock.patch.object(self.recovery, "restore") as restore:
            with self.assertRaises(RuntimeError):
                self.recovery.backup()
        restore.assert_not_called()
        self.assertEqual(self.recovery.latest.read_bytes(), b"old valid snapshot")

    def test_failed_restore_preserves_latest_and_previous(self):
        self.snapshot()
        previous = self.recovery.state / "previous.sql"
        previous.write_bytes(b"older valid snapshot")
        self.mock_dump()
        with mock.patch.object(self.recovery, "restore", side_effect=RuntimeError("import")):
            with self.assertRaises(RuntimeError):
                self.recovery.backup()
        self.assertEqual(self.recovery.latest.read_bytes(), b"old valid snapshot")
        self.assertEqual(previous.read_bytes(), b"older valid snapshot")
        self.assertFalse((self.recovery.state / "last-backup").exists())

    def test_restore_always_reenables_super_read_only(self):
        for error in (RuntimeError("import failed"), subprocess.TimeoutExpired("mysql", 1)):
            with self.subTest(error=type(error).__name__):
                self.local.reset_mock()
                self.run.side_effect = error
                with self.assertRaises(type(error)):
                    self.recovery.restore(self.snapshot())
                self.assertEqual(self.local.call_args.args[0],
                                 "SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;")

    def test_restore_validation_failure_reenables_super_read_only(self):
        self.run.side_effect = None
        self.local.side_effect = ["", "0", ""]
        with self.assertRaises(RuntimeError):
            self.recovery.restore(self.snapshot())
        self.assertEqual(self.local.call_args.args[0],
                         "SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;")

    def test_partial_read_only_disable_failure_still_reenables_protection(self):
        self.local.side_effect = [
            RuntimeError("connection lost after super_read_only=OFF"),
            "",
        ]
        with self.assertRaises(RuntimeError):
            self.recovery.restore(self.snapshot())
        self.assertEqual(self.local.call_args.args[0],
                         "SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;")
        self.run.assert_not_called()

    def test_invalid_restored_dump_preserves_latest_and_last_backup(self):
        self.snapshot()
        stamp = self.recovery.state / "last-backup"
        stamp.write_text("123")

        def command(args, *, stdin=None, stdout=subprocess.PIPE, timeout=30):
            if args[0] == "mysqldump":
                stdout.write(b"dump with no application tables")
            else:
                self.assertEqual(args[0], "mysql")
            return b""

        self.run.side_effect = command
        self.local.side_effect = ["", "0", ""]
        with self.assertRaises(RuntimeError):
            self.recovery.backup()
        self.assertEqual(self.recovery.latest.read_bytes(), b"old valid snapshot")
        self.assertEqual(stamp.read_text(), "123")
        self.assertEqual(self.local.call_args.args[0],
                         "SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;")

    def test_validate_requires_application_table(self):
        self.local.side_effect = ["5", RuntimeError("usuario missing")]
        with self.assertRaises(RuntimeError):
            self.recovery.validate()
        self.assertIn("`codetracker`.usuario", self.local.call_args.args[0])

    def test_three_consecutive_failures_required(self):
        with mock.patch.object(self.recovery, "primary_healthy", return_value=False), \
                mock.patch.object(self.recovery, "promote") as promote:
            for expected in (1, 2):
                self.recovery.check()
                self.assertEqual((self.recovery.state / "failures").read_text(), str(expected))
                promote.assert_not_called()
            self.recovery.check()
        promote.assert_called_once_with()

    def test_successful_health_resets_failure_counter(self):
        with mock.patch.object(self.recovery, "primary_healthy",
                               side_effect=[False, False, True, False, False, False]), \
                mock.patch.object(self.recovery, "promote") as promote:
            for _ in range(3):
                self.recovery.check()
            self.assertEqual((self.recovery.state / "failures").read_text(), "0")
            for _ in range(2):
                self.recovery.check()
            promote.assert_not_called()
            self.recovery.check()
            promote.assert_called_once_with()

    def test_primary_health_checks_result_and_handles_command_errors(self):
        for output, expected in ((b"1\n", True), (b"0\n", False), (b"", False)):
            with self.subTest(output=output):
                self.run.side_effect = None
                self.run.return_value = output
                self.assertEqual(self.recovery.primary_healthy(), expected)
                args = self.run.call_args.args[0]
                self.assertEqual(args[args.index("--execute") + 1],
                                 "SELECT 1 FROM `codetracker`.usuario LIMIT 1;")
        for error in (RuntimeError("connection failed"), subprocess.TimeoutExpired("mysql", 10)):
            with self.subTest(error=type(error).__name__):
                self.run.side_effect = error
                self.assertFalse(self.recovery.primary_healthy())

    def test_no_snapshot_blocks_fencing_and_promotion(self):
        with mock.patch.object(self.recovery, "fence") as fence, \
                mock.patch.object(self.recovery, "publish") as publish:
            with self.assertRaises(RuntimeError):
                self.recovery.promote()
        fence.assert_not_called()
        publish.assert_not_called()
        self.assertFalse(self.recovery.promoted.exists())

    def test_local_standby_unavailable_blocks_fencing(self):
        fence, restore, publish = self.prepare_promotion()
        self.local.side_effect = RuntimeError("local mysql unavailable")
        with self.assertRaises(RuntimeError):
            self.recovery.promote()
        fence.assert_not_called()
        restore.assert_not_called()
        publish.assert_not_called()
        self.assertFalse(self.recovery.promoted.exists())

    def test_primary_state_reads_ec2_response(self):
        self.aws.side_effect = None
        self.aws.return_value = {
            "Reservations": [{"Instances": [{"State": {"Name": "stopped"}}]}]
        }
        self.assertEqual(self.recovery.primary_state(), "stopped")
        self.aws.assert_called_once_with(
            "ec2", "describe-instances", "--instance-ids", "i-offline-primary"
        )

    def test_fence_accepts_only_confirmed_stopped_or_terminated(self):
        for state in ("stopped", "terminated"):
            with self.subTest(state=state), \
                    mock.patch.object(self.recovery, "primary_state", return_value=state):
                self.recovery.fence()
        self.aws.assert_not_called()
        self.sleep.assert_not_called()

    def test_successful_stop_request_does_not_authorize_promotion_while_stopping(self):
        self.snapshot()
        self.aws.side_effect = None
        self.aws.return_value = {"StoppingInstances": []}
        with mock.patch.object(self.recovery, "primary_state",
                               side_effect=["running"] + ["stopping"] * 30), \
                mock.patch.object(self.recovery, "restore") as restore, \
                mock.patch.object(self.recovery, "publish") as publish:
            with self.assertRaises(RuntimeError):
                self.recovery.promote()
        self.aws.assert_called_once_with(
            "ec2", "stop-instances", "--instance-ids", "i-offline-primary"
        )
        restore.assert_not_called()
        publish.assert_not_called()
        self.assertFalse(self.recovery.promoted.exists())

    def test_fence_waits_for_terminal_state(self):
        self.aws.side_effect = None
        with mock.patch.object(self.recovery, "primary_state",
                               side_effect=["running", "stopping", "stopped"]) as state:
            self.recovery.fence()
        self.assertEqual(state.call_count, 3)
        self.sleep.assert_called_once_with(10)

    def test_already_stopping_or_shutting_down_does_not_issue_another_stop(self):
        for state in ("stopping", "shutting-down"):
            with self.subTest(state=state), \
                    mock.patch.object(self.recovery, "primary_state",
                                      side_effect=[state, "terminated"]):
                self.recovery.fence()
        self.aws.assert_not_called()

    def test_aws_access_errors_block_restore_dns_and_promotion(self):
        self.snapshot()
        for operation in ("describe", "stop"):
            with self.subTest(operation=operation), ExitStack() as stack:
                self.aws.reset_mock()
                self.aws.side_effect = RuntimeError("AccessDenied")
                if operation == "stop":
                    stack.enter_context(mock.patch.object(
                        self.recovery, "primary_state", return_value="running"
                    ))
                restore = stack.enter_context(mock.patch.object(self.recovery, "restore"))
                publish = stack.enter_context(mock.patch.object(self.recovery, "publish"))
                with self.assertRaises(RuntimeError):
                    self.recovery.promote()
                restore.assert_not_called()
                publish.assert_not_called()
                self.assertFalse(self.recovery.prepared.exists())
                self.assertFalse(self.recovery.promoted.exists())

    def test_dns_is_published_only_after_fencing_and_restoring(self):
        fence, restore, publish = self.prepare_promotion()
        events = []
        fence.side_effect = lambda: events.append("fence")
        restore.side_effect = lambda snapshot: events.append("restore")

        def publish_dns():
            events.append("publish")
            self.assertTrue(self.recovery.prepared.exists())
            self.assertFalse(self.recovery.promoted.exists())
            self.assertIn("super_read_only=OFF", self.role.read_text())

        publish.side_effect = publish_dns
        self.recovery.promote()
        self.assertEqual(events, ["fence", "restore", "publish"])
        self.assertTrue(self.recovery.promoted.exists())

    def test_failed_promotion_restore_never_publishes_dns(self):
        fence, restore, publish = self.prepare_promotion()
        restore.side_effect = RuntimeError("restore failed")
        with self.assertRaises(RuntimeError):
            self.recovery.promote()
        fence.assert_called_once_with()
        publish.assert_not_called()
        self.assertFalse(self.recovery.prepared.exists())
        self.assertFalse(self.recovery.promoted.exists())
        self.assertIn("super_read_only=ON", self.role.read_text())

    def test_promotion_role_configuration_remains_readable_after_mysql_restart(self):
        self.prepare_promotion()
        with mock.patch.object(self.recovery, "write_state",
                               wraps=self.recovery.write_state) as write_state:
            self.recovery.promote()
        write_state.assert_any_call(
            self.role, "[mysqld]\nread_only=OFF\nsuper_read_only=OFF\n", mode=0o644
        )
        if os.name != "nt":
            self.assertEqual(self.role.stat().st_mode & 0o777, 0o644)

    def test_crash_after_prepared_marker_never_reimports_snapshot(self):
        _, restore, publish = self.prepare_promotion()
        self.recovery.prepared.write_text("already restored before process crash")
        restarted = AGENT.Recovery(dict(self.recovery.config))
        with mock.patch.object(restarted, "local", return_value="1"), \
                mock.patch.object(restarted, "fence"), \
                mock.patch.object(restarted, "restore") as restarted_restore, \
                mock.patch.object(restarted, "publish") as restarted_publish, \
                mock.patch.object(restarted, "primary_healthy") as healthy:
            restarted.check()
        restarted_restore.assert_not_called()
        healthy.assert_not_called()
        restarted_publish.assert_called_once_with()
        restore.assert_not_called()
        publish.assert_not_called()
        self.assertTrue(restarted.promoted.exists())

    def test_publish_failure_retries_prepared_without_overwriting_new_data(self):
        _, restore, publish = self.prepare_promotion()
        publish.side_effect = [RuntimeError("DNS denied"), None]
        with self.assertRaises(RuntimeError):
            self.recovery.promote()
        self.assertTrue(self.recovery.prepared.exists())
        self.assertFalse(self.recovery.promoted.exists())
        with mock.patch.object(self.recovery, "primary_healthy") as healthy:
            self.recovery.check()
        healthy.assert_not_called()
        restore.assert_called_once_with(self.recovery.latest)
        self.assertEqual(publish.call_count, 2)
        self.assertTrue(self.recovery.promoted.exists())

    def test_prepared_and_promoted_standby_never_back_up_from_old_primary(self):
        self.snapshot()
        for marker in (self.recovery.prepared, self.recovery.promoted):
            with self.subTest(marker=marker.name):
                marker.write_text("1")
                self.recovery.backup()
                marker.unlink()
        self.run.assert_not_called()
        self.aws.assert_not_called()
        self.assertEqual(self.recovery.latest.read_bytes(), b"old valid snapshot")

    def test_promoted_standby_never_fails_back_when_primary_recovers(self):
        self.recovery.promoted.write_text("1")
        self.role.write_text("[mysqld]\nread_only=OFF\nsuper_read_only=OFF\n")
        with mock.patch.object(self.recovery, "primary_healthy", return_value=True) as healthy, \
                mock.patch.object(self.recovery, "promote") as promote, \
                mock.patch.object(self.recovery, "backup") as backup:
            self.recovery.check()
        healthy.assert_not_called()
        promote.assert_not_called()
        backup.assert_not_called()
        self.aws.assert_not_called()
        self.run.assert_not_called()
        self.local.assert_called_once_with("SELECT 1;")
        self.assertIn("super_read_only=OFF", self.role.read_text())
        self.assertTrue(self.recovery.promoted.exists())

    def test_publish_updates_only_standby_address_and_waits_for_insync(self):
        self.aws.side_effect = [
            {"ChangeInfo": {"Id": "/change/OFFLINE"}},
            {"ChangeInfo": {"Status": "PENDING"}},
            {"ChangeInfo": {"Status": "INSYNC"}},
        ]
        self.recovery.publish()
        args = self.aws.call_args_list[0].args
        self.assertEqual(args[:2], ("route53", "change-resource-record-sets"))
        self.assertEqual(args[args.index("--hosted-zone-id") + 1], "ZOFFLINE")
        record = json.loads(args[args.index("--change-batch") + 1])["Changes"][0]
        self.assertEqual(record["Action"], "UPSERT")
        self.assertEqual(record["ResourceRecordSet"]["Name"], "mysql.internal.example")
        self.assertEqual(record["ResourceRecordSet"]["Type"], "A")
        self.assertEqual(record["ResourceRecordSet"]["ResourceRecords"],
                         [{"Value": "10.0.2.25"}])
        self.assertEqual(self.aws.call_args_list[-1].args,
                         ("route53", "get-change", "--id", "/change/OFFLINE"))
        self.sleep.assert_called_once_with(5)

    def test_pending_dns_never_marks_promotion_complete(self):
        _, _, publish = self.prepare_promotion()
        # Exercise the real DNS polling implementation inside the promotion.
        publish.side_effect = lambda: AGENT.Recovery.publish(self.recovery)
        self.aws.side_effect = [
            {"ChangeInfo": {"Id": "/change/OFFLINE"}}
        ] + [{"ChangeInfo": {"Status": "PENDING"}}] * 30
        with self.assertRaises(RuntimeError):
            self.recovery.promote()
        self.assertTrue(self.recovery.prepared.exists())
        self.assertFalse(self.recovery.promoted.exists())

    def test_run_checks_exit_status_and_preserves_streams_and_timeout(self):
        self.process.side_effect = None
        self.process.return_value = subprocess.CompletedProcess(["mysql"], 0, b"1\n", b"")
        source, output = object(), object()
        self.assertEqual(
            AGENT.Recovery.run(self.recovery, ["mysql"], stdin=source,
                               stdout=output, timeout=7),
            b"1\n",
        )
        self.process.assert_called_once_with(
            ["mysql"], stdin=source, stdout=output, stderr=subprocess.PIPE, timeout=7
        )
        self.process.return_value = subprocess.CompletedProcess(
            ["mysql"], 1, b"", b"access denied"
        )
        with self.assertRaisesRegex(RuntimeError, "access denied"):
            AGENT.Recovery.run(self.recovery, ["mysql"])

    def test_aws_wrapper_passes_region_and_decodes_json(self):
        self.run.side_effect = None
        self.run.return_value = b'{"Reservations": []}'
        result = AGENT.Recovery.aws(self.recovery, "ec2", "describe-instances")
        self.assertEqual(result, {"Reservations": []})
        args = self.run.call_args.args[0]
        self.assertEqual(args[:4], ["aws", "--region", "us-east-1", "--output"])
        self.assertEqual(args[-2:], ["ec2", "describe-instances"])

    def test_state_write_replaces_complete_value_and_removes_temporary_file(self):
        target = self.recovery.state / "failures"
        target.write_text("old")
        self.recovery.write_state(target, "new")
        self.assertEqual(target.read_text(), "new")
        self.assertFalse(target.with_suffix(".tmp").exists())

    def test_state_write_sets_private_permissions_before_atomic_replacement(self):
        target = self.recovery.state / "failures"
        original_replace = Path.replace
        events = []

        def replace(path, destination):
            events.append("replace")
            self.assertEqual(events[0], "chmod")
            return original_replace(path, destination)

        original_fchmod = os.fchmod

        def chmod(descriptor, mode):
            events.append("chmod")
            self.assertEqual(mode, 0o600)
            return original_fchmod(descriptor, mode)

        with mock.patch.object(os, "fchmod", side_effect=chmod), \
                mock.patch.object(Path, "replace", new=replace):
            self.recovery.write_state(target, "1")
        self.assertEqual(events, ["chmod", "replace"])
        if os.name != "nt":
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
