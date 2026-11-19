"""Offline tests for the GPG/S3 archive installed by the main stack."""

import os
import contextlib
import io
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import types

from swarm_configuration_test import Renderer, load_template


TEMPLATE = load_template("cloudformationCodeTracker.yaml")
INSTALLER = TEMPLATE["Resources"]["BootstrapSignalHandle"]["Metadata"]["BackupInstaller"]
RUNNER = INSTALLER.split("<<'ARCHIVE'\n", 1)[1].split("\nARCHIVE\n", 1)[0]
GENERATOR = TEMPLATE["Resources"]["BootstrapSignalHandle"]["Metadata"]["BackupKeyGenerator"]
BASH = (
    r"C:\Program Files\Git\bin\bash.exe"
    if os.name == "nt" else shutil.which("bash")
)


def bash_path(path):
    value = Path(path).as_posix()
    if os.name == "nt":
        value = "/" + value[0].lower() + value[2:]
    return value


class ArchiveContracts(unittest.TestCase):
    def test_embedded_shell_and_enabled_userdata_fit_ec2(self):
        self.assertIsNotNone(BASH)
        renderer = Renderer(TEMPLATE, EnableBackupArchive="true")
        scripts = [INSTALLER, RUNNER]
        for resource in TEMPLATE["Resources"].values():
            if resource["Type"] == "AWS::EC2::Instance":
                script = renderer.render(resource["Properties"]["UserData"]["Fn::Base64"])
                self.assertLessEqual(len(script.encode("utf-8")), 16384)
                scripts.append(script)
        for script in scripts:
            result = subprocess.run(
                [BASH, "-n"], input=script, text=True, capture_output=True,
                encoding="utf-8",
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_archive_is_opt_in_and_resources_are_deleted_with_stack(self):
        self.assertFalse(Renderer(TEMPLATE).condition("BackupArchiveEnabled"))
        bucket = TEMPLATE["Resources"]["BackupArchiveBucket"]
        self.assertEqual(bucket["DeletionPolicy"], "Delete")
        self.assertEqual(bucket["UpdateReplacePolicy"], "Delete")
        props = bucket["Properties"]
        self.assertTrue(all(props["PublicAccessBlockConfiguration"].values()))
        self.assertEqual(props["VersioningConfiguration"]["Status"], "Enabled")
        self.assertNotIn("BackupPublicKeyS3Uri", TEMPLATE["Parameters"])
        self.assertNotIn("BackupGpgFingerprint", TEMPLATE["Parameters"])
        secret = TEMPLATE["Resources"]["BackupGpgSecret"]
        self.assertEqual(secret["DeletionPolicy"], "Delete")
        self.assertEqual(secret["UpdateReplacePolicy"], "Delete")
        self.assertNotIn("ExpirationInDays", str(props))

    def test_producers_are_deleted_before_cleanup_and_bucket(self):
        cleanup = TEMPLATE["Resources"]["BackupArchiveCleanup"]
        self.assertEqual(cleanup["Properties"]["Bucket"], {"Ref": "BackupArchiveBucket"})
        self.assertEqual(cleanup["DependsOn"], "BackupArchiveBucketPolicy")
        for name in ("BastionInstance", "SwarmManagerInstance", "DatabaseInstance", "DatabaseStandbyInstance"):
            script, variables = TEMPLATE["Resources"][name]["Properties"]["UserData"]["Fn::Base64"]["Fn::Sub"]
            self.assertIn("${ArchiveCleanup}", script)
            self.assertEqual(variables["ArchiveCleanup"], {
                "Fn::If": ["BackupArchiveEnabled", {"Ref": "BackupArchiveCleanup"}, "disabled"],
            })
        function = TEMPLATE["Resources"]["BackupCleanupFunction"]
        self.assertEqual(function["Properties"]["LoggingConfig"]["LogGroup"], {"Ref": "BackupCleanupLogGroup"})
        self.assertEqual(TEMPLATE["Resources"]["BackupCleanupLogGroup"]["DeletionPolicy"], "Delete")

    def test_initial_archives_precede_readiness_and_preserve_existing_timers(self):
        renderer = Renderer(TEMPLATE)
        manager = renderer.render(
            TEMPLATE["Resources"]["SwarmManagerInstance"]["Properties"]["UserData"]["Fn::Base64"]
        )
        self.assertLess(
            manager.rindex("install_backup_archive "),
            manager.index("systemctl start --no-block label-swarm-workers.service"),
        )
        primary = renderer.render(
            TEMPLATE["Resources"]["DatabaseInstance"]["Properties"]["UserData"]["Fn::Base64"]
        )
        self.assertLess(primary.rindex("install_backup_archive "), primary.index("aws ssm put-parameter"))
        standby = renderer.render(
            TEMPLATE["Resources"]["DatabaseStandbyInstance"]["Properties"]["UserData"]["Fn::Base64"]
        )
        self.assertIn("OnCalendar=*-*-* 00,12:00:00 UTC", standby)
        self.assertIn("OnUnitInactiveSec=30s", standby)
        self.assertIn("' banco", standby)

    def test_public_key_is_validated_before_import(self):
        prefix = INSTALLER.split("cat > /usr/local/sbin/", 1)[0]
        for scenario, expected in (("matching", 0), ("different", 1), ("private", 1)):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as directory:
                root = bash_path(directory)
                script = prefix.replace("/etc/codetracker-backup", root + "/config").replace(
                    "/bckp", root + "/bckp"
                )
                mocks = r'''
set -- us-east-1 fixture-bucket app
install() {
  if [[ "$1" == -d ]]; then shift 3; command mkdir -p "$@"; else return 99; fi
}
aws() {
  if [[ "$3" == */fingerprint.txt ]]; then
    printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' > "$4"
  else
    printf 'fixture key\n' > "$4"
  fi
}
gpg() {
  if [[ "$*" == *--list-packets* ]]; then
    if [[ "$SCENARIO" == private ]]; then printf ':secret key packet:\n'
    else printf ':public key packet:\n'; fi
  elif [[ "$*" == *show-only* ]]; then
    printf 'pub:::::::::\n'
    if [[ "$SCENARIO" == different ]]; then
      printf 'fpr:::::::::BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB:\n'
    else
      printf 'fpr:::::::::AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:\n'
    fi
  else
    printf 'imported\n' > "$FIXTURE/imported"
  fi
}
'''
                env = os.environ.copy()
                env.update(SCENARIO=scenario, FIXTURE=root)
                result = subprocess.run(
                    [BASH], input=mocks + script, text=True, capture_output=True,
                    env=env, encoding="utf-8", timeout=10,
                )
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual((Path(directory) / "imported").exists(), expected == 0)

class BucketCleanupTests(unittest.TestCase):
    def setUp(self):
        self.s3 = mock.Mock()
        boto3 = types.ModuleType("boto3")
        boto3.client = mock.Mock(return_value=self.s3)
        self.response = types.ModuleType("cfnresponse")
        self.response.SUCCESS, self.response.FAILED = "SUCCESS", "FAILED"
        self.response.send = mock.Mock()
        exceptions = types.ModuleType("botocore.exceptions")

        class ClientError(Exception):
            def __init__(self, response):
                self.response = response

        exceptions.ClientError = ClientError
        self.client_error = ClientError
        source = TEMPLATE["Resources"]["BackupCleanupFunction"]["Properties"]["Code"]["ZipFile"]
        self.module = types.ModuleType("embedded_bucket_cleanup")
        with mock.patch.dict(sys.modules, {
            "boto3": boto3, "cfnresponse": self.response,
            "botocore": types.ModuleType("botocore"), "botocore.exceptions": exceptions,
        }):
            exec(compile(source, "<BackupCleanup>", "exec"), self.module.__dict__)
        self.context = mock.Mock()
        self.context.get_remaining_time_in_millis.return_value = 900000
        self.event = {
            "RequestType": "Delete", "LogicalResourceId": "Cleanup",
            "PhysicalResourceId": "physical", "ResourceProperties": {"Bucket": "fixture-backup"},
        }
        self.s3.list_object_versions.return_value = {}
        self.s3.list_objects_v2.return_value = {}
        self.s3.list_multipart_uploads.return_value = {}
        self.s3.delete_objects.return_value = {}

    def test_deletes_all_versions_delete_markers_objects_and_uploads(self):
        self.s3.list_object_versions.side_effect = [
            {"Versions": [{"Key": "backup", "VersionId": "v1"}],
             "DeleteMarkers": [{"Key": "backup", "VersionId": "d1"}]},
            {"Versions": [{"Key": "key", "VersionId": "v2"}]}, {},
        ]
        self.s3.list_objects_v2.side_effect = [{"Contents": [{"Key": "unversioned"}]}, {}]
        self.s3.list_multipart_uploads.side_effect = [
            {"Uploads": [{"Key": "pending", "UploadId": "u1"}]}, {},
        ]
        self.module.lambda_handler(self.event, self.context)
        self.assertEqual(self.s3.delete_objects.call_count, 3)
        self.assertEqual(self.s3.delete_objects.call_args_list[0].kwargs["Delete"]["Objects"], [
            {"Key": "backup", "VersionId": "v1"}, {"Key": "backup", "VersionId": "d1"},
        ])
        self.s3.abort_multipart_upload.assert_called_once_with(
            Bucket="fixture-backup", Key="pending", UploadId="u1",
        )
        self.assertEqual(self.response.send.call_args.args[2], "SUCCESS")

    def test_create_and_same_bucket_update_never_delete_data(self):
        for request in ("Create", "Update"):
            self.event["RequestType"] = request
            self.event["OldResourceProperties"] = {"Bucket": "fixture-backup"}
            self.module.lambda_handler(self.event, self.context)
        self.s3.list_object_versions.assert_not_called()
        self.s3.delete_objects.assert_not_called()

    def test_replacement_empties_only_old_bucket(self):
        self.event["RequestType"] = "Update"
        self.event["OldResourceProperties"] = {"Bucket": "old-backup"}
        self.module.lambda_handler(self.event, self.context)
        self.s3.list_object_versions.assert_called_once_with(Bucket="old-backup", MaxKeys=1000)

    def test_partial_delete_error_is_failed_not_success(self):
        self.s3.list_object_versions.return_value = {"Versions": [{"Key": "backup", "VersionId": "v1"}]}
        self.s3.delete_objects.return_value = {"Errors": [{"Code": "AccessDenied", "Key": "backup"}]}
        with self.assertLogs(level="ERROR"):
            self.module.lambda_handler(self.event, self.context)
        self.assertEqual(self.response.send.call_args.args[2], "FAILED")

    def test_absent_bucket_is_idempotent_but_access_denied_is_not_ignored(self):
        for code, expected in (("NoSuchBucket", "SUCCESS"), ("AccessDenied", "FAILED")):
            with self.subTest(code=code):
                self.s3.list_object_versions.side_effect = self.client_error({"Error": {"Code": code}})
                with mock.patch.object(self.module.logger, "exception"):
                    self.module.lambda_handler(self.event, self.context)
                self.assertEqual(self.response.send.call_args.args[2], expected)

    def test_timeout_returns_failed_before_lambda_expiration(self):
        self.context.get_remaining_time_in_millis.return_value = 10000
        with self.assertLogs(level="ERROR"):
            self.module.lambda_handler(self.event, self.context)
        self.assertEqual(self.response.send.call_args.args[2], "FAILED")
        self.s3.list_object_versions.assert_not_called()


class KeyProvisioning(unittest.TestCase):
    def setUp(self):
        self.module = types.ModuleType("embedded_backup_key")
        exec(compile(GENERATOR, "<BackupKeyGenerator>", "exec"), self.module.__dict__)
        self.secret = {"passphrase": "fixture-password"}
        self.calls = []
        self.uploaded = {}
        self.fail_publish = False
        self.original_tempdir = tempfile.TemporaryDirectory

    def command(self, args, *, data=None):
        self.calls.append(args)
        if "get-secret-value" in args:
            return json.dumps({"SecretString": json.dumps(self.secret)})
        if "put-secret-value" in args:
            self.secret = json.loads(Path(args[-1].removeprefix("file://")).read_text(encoding="utf-8"))
            return "{}"
        if args[0] == "gpgconf":
            return ""
        if args[0] == "gpg":
            if "--quick-generate-key" in args or "--quick-add-key" in args:
                self.assertEqual(data, "fixture-password\n")
                self.assertNotIn("fixture-password", args)
                return ""
            if "--export-secret-keys" in args:
                self.assertEqual(data, "fixture-password\n")
                return "-----BEGIN PGP PRIVATE KEY BLOCK-----\nfixture\n"
            if "--export" in args:
                return "-----BEGIN PGP PUBLIC KEY BLOCK-----\nfixture\n"
            if "show-only" in args:
                return "pub:::::::::\nfpr:::::::::" + "A" * 40 + ":\n"
        if "s3" in args and "cp" in args:
            if self.fail_publish:
                raise RuntimeError("fixture S3 error")
            self.uploaded[args[-2]] = Path(args[-3]).read_text(encoding="utf-8")
            return ""
        raise AssertionError("Unexpected command: " + repr(args))

    def provision(self):
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(self.module, "run", side_effect=self.command))
            stack.enter_context(mock.patch.object(
                self.module.tempfile, "TemporaryDirectory",
                side_effect=lambda **kwargs: self.original_tempdir(prefix=kwargs["prefix"]),
            ))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            # os.umask e global: preserve o estado do runner de testes.
            previous = os.umask(0o077)
            stack.callback(os.umask, previous)
            self.module.provision("us-east-1", "fixture-bucket", "fixture-secret")

    def test_generate_once_persist_private_before_publishing_public(self):
        self.provision()
        self.assertIn("private_key", self.secret)
        self.assertEqual(self.secret["fingerprint"], "A" * 40)
        self.assertTrue(all("PRIVATE KEY" not in value for value in self.uploaded.values()))
        persist = next(i for i, args in enumerate(self.calls) if "put-secret-value" in args)
        publish = next(i for i, args in enumerate(self.calls) if "s3" in args)
        self.assertLess(persist, publish)
        self.assertEqual(self.calls[-1][0], "gpgconf")
        self.calls.clear()
        self.provision()
        self.assertFalse(any("--quick-generate-key" in args for args in self.calls))
        self.assertFalse(any("put-secret-value" in args for args in self.calls))

    def test_failed_publication_reuses_custodied_key_on_retry(self):
        self.fail_publish = True
        with self.assertRaisesRegex(RuntimeError, "fixture S3 error"):
            self.provision()
        self.assertIn("private_key", self.secret)
        self.assertEqual(self.calls[-1][0], "gpgconf")
        self.fail_publish = False
        self.calls.clear()
        self.provision()
        self.assertFalse(any("--quick-generate-key" in args for args in self.calls))

    def test_partial_or_mismatched_custody_is_never_replaced(self):
        for secret in (
            {"passphrase": "fixture-password", "private_key": "incomplete"},
            {
                "passphrase": "fixture-password", "private_key": "BEGIN PGP PRIVATE KEY BLOCK",
                "public_key": "BEGIN PGP PUBLIC KEY BLOCK", "fingerprint": "B" * 40,
            },
        ):
            with self.subTest(secret_fields=set(secret)):
                self.secret = secret
                self.calls.clear()
                with self.assertRaises(ValueError):
                    self.provision()
                self.assertFalse(any("--quick-generate-key" in args for args in self.calls))
                self.assertFalse(any("put-secret-value" in args for args in self.calls))
                self.assertFalse(self.uploaded)


@unittest.skipUnless(BASH, "Bash required")
class ArchiveExecution(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        for name in ("bckp/app", "bckp/db", "bckp/logs", "locks", "config", "remote", "app"):
            (self.root / name).mkdir(parents=True)
        (self.root / "app/stack.yml").write_text("services: {}\n", encoding="utf-8")
        (self.root / "config/archive.conf").write_text(
            "REGION=us-east-1\nBUCKET=fixture-bucket\nFPR=fixture\nMODE=banco\n",
            encoding="utf-8",
        )
        self.root_bash = bash_path(self.root)
        self.runner = RUNNER.replace(
            "/etc/codetracker-backup", self.root_bash + "/config"
        ).replace(
            "/bckp", self.root_bash + "/bckp"
        ).replace(
            "/run/lock", self.root_bash + "/locks"
        ).replace(
            "/etc/codetracker/recovery.json", self.root_bash + "/recovery.json"
        ).replace(
            "/var/lib/mysql/.codetracker-recovery/promoted", self.root_bash + "/promoted"
        ).replace(
            "opt/codetracker", "app"
        ).replace(
            "tar -C / -czf", "tar -C " + shlex.quote(self.root_bash) + " -czf"
        )
        self.mocks = r'''
set -Eeuo pipefail
aws() {
  local source=$3 target=$4
  printf '%s -> %s\n' "$source" "$target" >> "$FIXTURE/calls"
  if [[ "$source" == s3://* ]]; then
    cp "$FIXTURE/remote/${source##*/}" "$target"
    if [[ "$CASE" == corrupt && "$source" == *.gpg ]]; then
      printf 'corruption' >> "$target"
    fi
  else
    if [[ "$CASE" == upload-failure && "$target" == */backups/* ]]; then return 7; fi
    if [[ "$CASE" == log-failure && "$target" == */logs/* ]]; then return 9; fi
    cp "$source" "$FIXTURE/remote/${target##*/}"
  fi
}
mysql() {
  if [[ "$*" == *"@@version"* ]]; then printf '8.0.44\n'
  elif [[ "$*" == *information_schema* ]]; then printf '0\n'
  else
    if [[ "$CASE" == role-change ]]; then
      if [[ -f "$FIXTURE/queried" ]]; then printf '0\n'; return; fi
      touch "$FIXTURE/queried"
    fi
    if [[ "$CASE" == readonly ]]; then printf '0\n'; else printf '1\n'; fi
  fi
}
mysqldump() {
  printf 'CREATE DATABASE lamar;\n'
  if [[ "$CASE" == dump-failure ]]; then return 6; fi
}
gpg() {
  local output= source="${@: -1}"
  while (( $# )); do
    if [[ "$1" == --output ]]; then output=$2; break; fi
    shift
  done
  cp "$source" "$output"
}
logger() { printf '%s\n' "$*" >> "$FIXTURE/journal"; }
flock() { :; }
hostname() { printf 'fixture-host\n'; }
# MSYS may not support Linux permission creation flags; not relevant to these tests.
mkdir() {
  if [[ "${1:-}" == -m ]]; then shift 2; fi
  command mkdir "$@"
}
'''

    def run_archive(self, case="success", mode="banco"):
        config = self.root / "config/archive.conf"
        config.write_text(
            config.read_text(encoding="utf-8").replace("MODE=banco", f"MODE={mode}"),
            encoding="utf-8",
        )
        environment = os.environ.copy()
        environment.update(FIXTURE=self.root_bash, CASE=case)
        return subprocess.run(
            [BASH], input=self.mocks + "\n" + self.runner,
            text=True, capture_output=True, encoding="utf-8",
            env=environment, timeout=30,
        )

    def remote_names(self):
        return {file.name for file in (self.root / "remote").iterdir()}

    def test_success_uploads_encrypted_package_manifests_marker_and_log(self):
        result = self.run_archive()
        self.assertEqual(result.returncode, 0, result.stderr)
        names = self.remote_names()
        self.assertTrue({
            "backup.tar.gz.gpg", "original.sha256", "checksum.sha256", "SUCESSO-S3.txt",
        }.issubset(names))
        self.assertFalse(any(name.endswith((".sql", ".asc", ".tar.gz")) for name in names))
        self.assertTrue(any(name.endswith(".log") for name in names))
        self.assertTrue((self.root / "config/ultimo-sucesso.txt").exists())
        self.assertFalse(list((self.root / "bckp/db").glob(".work-*")))
        calls = (self.root / "calls").read_text(encoding="utf-8")
        self.assertLess(calls.index("recebido.gpg"), calls.index("SUCESSO-S3.txt"))

    def test_corrupted_download_is_not_marked_successful(self):
        result = self.run_archive("corrupt")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("SUCESSO-S3.txt", self.remote_names())
        self.assertFalse((self.root / "config/ultimo-sucesso.txt").exists())
        self.assertTrue(any(name.endswith(".log") for name in self.remote_names()))

    def test_dump_failure_keeps_previous_success_and_sends_error_log(self):
        marker = self.root / "config/ultimo-sucesso.txt"
        marker.write_text("previous", encoding="utf-8")
        result = self.run_archive("dump-failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(marker.read_text(encoding="utf-8"), "previous")
        self.assertNotIn("backup.tar.gz.gpg", self.remote_names())
        self.assertTrue(any(name.endswith(".log") for name in self.remote_names()))
        self.assertFalse(list((self.root / "bckp/db").glob(".work-*")))

    def test_role_change_during_dump_blocks_publication(self):
        result = self.run_archive("role-change")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("SUCESSO-S3.txt", self.remote_names())
        self.assertNotIn("backup.tar.gz.gpg", self.remote_names())
        self.assertTrue(any(name.endswith(".log") for name in self.remote_names()))

    def test_upload_and_log_errors_fail_explicitly(self):
        for case in ("upload-failure", "log-failure"):
            with self.subTest(case=case):
                result = self.run_archive(case)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue((self.root / "journal").exists())
                self.assertTrue(list((self.root / "bckp/logs").glob("*.log")))

    def test_unpromoted_standby_never_archives_even_if_temporarily_writable(self):
        (self.root / "recovery.json").write_text("{}", encoding="utf-8")
        result = self.run_archive()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("backup.tar.gz.gpg", self.remote_names())
        log = next((self.root / "bckp/logs").glob("*.log")).read_text(encoding="utf-8")
        self.assertIn("IGNORADO: standby ainda nao promovido.", log)

    def test_promoted_standby_archives_and_readonly_server_skips(self):
        (self.root / "recovery.json").write_text("{}", encoding="utf-8")
        (self.root / "promoted").write_text("promoted", encoding="utf-8")
        result = self.run_archive("readonly")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("backup.tar.gz.gpg", self.remote_names())
        result = self.run_archive()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SUCESSO-S3.txt", self.remote_names())

    def test_application_archive_does_not_call_mysql(self):
        self.mocks += '\nmysql() { echo "unexpected mysql" >&2; return 99; }\n'
        result = self.run_archive(mode="app")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SUCESSO-S3.txt", self.remote_names())
        self.assertFalse(list((self.root / "bckp/app").glob(".work-*")))


if __name__ == "__main__":
    unittest.main()
