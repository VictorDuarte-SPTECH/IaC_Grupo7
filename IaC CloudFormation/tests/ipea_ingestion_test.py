"""Offline tests for the ingestion code embedded in the data lake template."""

import json
import hashlib
import os
from pathlib import Path
import re
import sys
import textwrap
import types
import unittest
from unittest.mock import Mock, patch
from urllib.error import URLError


TEMPLATE = Path(__file__).resolve().parents[1] / "buckets+lambda.yml"


def load_function(name):
    template = TEMPLATE.read_text(encoding="utf-8")
    resource = re.search(
        rf"(?ms)^  {name}:\n(.*?)(?=^  [A-Za-z0-9]+:|\Z)", template
    ).group(1)
    source = resource.split("        ZipFile: |\n", 1)[1]
    s3, glue, response = Mock(), Mock(), Mock()
    sdk = types.SimpleNamespace(client=lambda name: s3 if name == "s3" else glue)
    module = types.ModuleType(name)
    with patch.dict(sys.modules, {"boto3": sdk, "cfnresponse": response}):
        exec(compile(textwrap.dedent(source), f"<{name}>", "exec"), module.__dict__)
    if hasattr(module, "logger"):
        module.logger = Mock()
    return module, s3, glue, response


class IngestionTests(unittest.TestCase):
    def setUp(self):
        self.module, self.s3, self.glue, self.response = load_function("IpeaIngestionFunction")
        self.context = Mock()
        self.context.function_name = "ipea-ingestion"
        self.context.get_remaining_time_in_millis.return_value = 900000
        self.record = {
            "SERCODIGO": "BM_ERV", "VALDATA": "2025-01-01T00:00:00-03:00",
            "VALVALOR": 5.2, "NIVNOME": None,
        }
        self.environment = patch.dict(os.environ, {
            "BRONZE_BUCKET": "bronze", "SILVER_BUCKET": "silver", "JOB_NAME": "job",
            "COMEX_ENABLED": "true", "COMEX_YEARS": "25",
            "COMEX_NCM_CODES": "84271011,84272010,84271019,84279000,84312011,84312019",
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)
        sleep = patch.object(self.module.time, "sleep")
        sleep.start()
        self.addCleanup(sleep.stop)

    def test_pagination_preserves_raw_records_and_upgrades_https(self):
        with patch.object(self.module, "read_page", side_effect=[
            {"value": [self.record], "@odata.nextLink":
             "http://www.ipeadata.gov.br/api/odata4/ValoresSerie?$skip=1"},
            {"value": [self.record]},
        ]) as read:
            self.assertEqual(self.module.fetch_records(self.context), [self.record] * 2)
            self.assertTrue(read.call_args.args[0].startswith("https://"))

    def test_invalid_source_fails_before_upload(self):
        pages = [
            {"value": []}, {}, {"value": [dict(self.record, SERCODIGO="wrong")]},
            {"value": [dict(self.record, VALVALOR=None)]},
            {"value": [dict(self.record, VALVALOR="invalid")]},
            {"value": [dict(self.record, VALVALOR=float("nan"))]},
            {"value": [self.record], "@odata.nextLink": "https://example.com/data"},
            {"value": [self.record], "@odata.nextLink": self.module.API},
        ]
        for page in pages:
            with self.subTest(page=page), patch.object(
                self.module, "read_page", return_value=page
            ), self.assertRaises((ValueError, KeyError)):
                self.module.ingest(self.context)
        self.s3.put_object.assert_not_called()
        self.glue.start_job_run.assert_not_called()

    def test_http_failure_retries_then_propagates(self):
        with patch.object(self.module.urllib.request, "urlopen", side_effect=URLError("offline")) as http:
            with self.assertRaises(URLError):
                self.module.read_page(self.module.API, self.context)
            self.assertEqual(http.call_count, 3)

    def prepare_ingestion(self, states):
        source = patch.object(self.module, "fetch_records", return_value=[self.record])
        source.start()
        self.addCleanup(source.stop)
        self.glue.start_job_run.return_value = {"JobRunId": "run"}
        self.glue.get_job_run.side_effect = [
            {"JobRun": {"JobRunState": state}} for state in states
        ]
        self.s3.get_paginator.return_value.paginate.return_value = [
            {"Contents": [{"Key": "ipeadata/serie.json.parquet/part-00000.snappy.parquet", "Size": 2900}]}
        ]

    def test_create_waits_for_glue_and_silver_before_success(self):
        self.prepare_ingestion(["WAITING", "RUNNING", "SUCCEEDED"])
        self.module.lambda_handler({"RequestType": "Create"}, self.context)
        upload = self.s3.put_object.call_args_list[0].kwargs
        manifest = json.loads(self.s3.put_object.call_args_list[1].kwargs["Body"])
        self.assertEqual(json.loads(upload["Body"]), [self.record])
        self.assertRegex(upload["Key"], r"^ipeadata/BM_ERV/ingestion_month=\d{4}-\d{2}/run_id=[a-f0-9]{32}/data.json$")
        self.assertEqual(manifest["sha256"], hashlib.sha256(upload["Body"]).hexdigest())
        self.assertEqual(manifest["bytes"], len(upload["Body"]))
        self.assertEqual(manifest["status"], "COMPLETE")
        self.assertEqual(
            self.s3.get_paginator.return_value.paginate.call_args.kwargs,
            {"Bucket": "silver", "Prefix": upload["Key"] + ".parquet/"},
        )
        self.s3.head_object.assert_not_called()
        self.assertEqual(self.glue.get_job_run.call_count, 3)
        self.assertEqual(self.response.send.call_args.args[2], self.response.SUCCESS)

    def test_delete_is_noop(self):
        with patch.object(self.module, "report_ingestion") as report:
            self.module.lambda_handler({"RequestType": "Delete"}, self.context)
            report.assert_not_called()
        self.s3.put_object.assert_not_called()
        self.glue.start_job_run.assert_not_called()
        self.assertEqual(self.response.send.call_args.args[2], self.response.SUCCESS)

    def test_failed_glue_fails_custom_resource(self):
        self.prepare_ingestion(["FAILED"])
        self.module.lambda_handler({"RequestType": "Create"}, self.context)
        self.assertEqual(self.response.send.call_args.args[2], self.response.FAILED)
        self.s3.get_paginator.assert_not_called()

    def test_monthly_failure_is_not_swallowed(self):
        self.prepare_ingestion(["TIMEOUT"])
        with self.assertRaisesRegex(RuntimeError, "TIMEOUT"):
            self.module.lambda_handler({}, self.context)
        self.response.send.assert_not_called()

    def test_monthly_success_does_not_send_cloudformation_response(self):
        self.prepare_ingestion(["SUCCEEDED"])
        result = self.module.lambda_handler({}, self.context)
        self.assertEqual(result["Records"], 1)
        self.assertEqual(result["JobRunId"], "run")
        self.response.send.assert_not_called()

    def test_ingestion_metrics_are_valid_emf(self):
        for success, records in [(True, 137), (False, 0)]:
            with self.subTest(success=success), patch("builtins.print") as output:
                self.module.report_ingestion(self.context, success, records)
                metric = json.loads(output.call_args.args[0])
                self.assertEqual(metric["FunctionName"], "ipea-ingestion")
                self.assertEqual(metric["IngestionSuccess"], int(success))
                self.assertEqual(metric["IngestionFailure"], int(not success))
                self.assertEqual(metric["RecordsIngested"], records)
                definition = metric["_aws"]["CloudWatchMetrics"][0]
                self.assertEqual(definition["Namespace"], "CodeTracker/DataLake")
                self.assertEqual(definition["Dimensions"], [["FunctionName"], ["FunctionName", "Source"]])

    def test_logical_failure_emits_failure_metric(self):
        self.prepare_ingestion(["FAILED"])
        with patch.object(self.module, "report_ingestion") as report:
            self.module.lambda_handler({"RequestType": "Create"}, self.context)
            report.assert_called_once_with(self.context, False, source="ipeadata")

    def test_missing_or_empty_parquet_does_not_report_success(self):
        invalid_pages = [
            [{}],
            [{"Contents": [{"Key": "prefix/_SUCCESS", "Size": 0}]}],
            [{"Contents": [{"Key": "prefix/part.parquet", "Size": 0}]}],
            [{"Contents": [{"Key": "prefix/metadata.json", "Size": 100}]}],
        ]
        for pages in invalid_pages:
            with self.subTest(pages=pages):
                self.prepare_ingestion(["SUCCEEDED"])
                self.s3.get_paginator.return_value.paginate.return_value = pages
                self.module.lambda_handler({"RequestType": "Create"}, self.context)
                self.assertEqual(self.response.send.call_args.args[2], self.response.FAILED)

    def test_parquet_on_later_page_succeeds_without_marker(self):
        self.prepare_ingestion(["SUCCEEDED"])
        self.s3.get_paginator.return_value.paginate.return_value = [
            {"Contents": [{"Key": "prefix/metadata", "Size": 10}]},
            {"Contents": [{"Key": "prefix/part.snappy.parquet", "Size": 2900}]},
        ]
        self.module.lambda_handler({"RequestType": "Create"}, self.context)
        self.assertEqual(self.response.send.call_args.args[2], self.response.SUCCESS)

    def test_silver_listing_error_does_not_report_success(self):
        self.prepare_ingestion(["SUCCEEDED"])
        self.s3.get_paginator.return_value.paginate.side_effect = RuntimeError("AccessDenied")
        self.module.lambda_handler({"RequestType": "Create"}, self.context)
        self.assertEqual(self.response.send.call_args.args[2], self.response.FAILED)

    def test_timeout_requests_job_stop(self):
        self.prepare_ingestion(["RUNNING"])
        self.context.get_remaining_time_in_millis.side_effect = [900000, 900000, 1000]
        with self.assertRaises(TimeoutError):
            self.module.ingest(self.context)
        self.glue.batch_stop_job_run.assert_called_once_with(JobName="job", JobRunIds=["run"])

    def test_starter_ignores_reserved_prefix(self):
        module, _, glue, _ = load_function("GlueStarterFunction")
        glue.start_job_run.return_value = {"JobRunId": "manual-run"}
        module.lambda_handler({"detail": {"object": {"key": "ipeadata/test.json"}}}, self.context)
        glue.start_job_run.assert_not_called()
        module.lambda_handler({
            "detail": {"bucket": {"name": "bronze"}, "object": {"key": "manual.csv"}}
        }, self.context)
        self.assertEqual(glue.start_job_run.call_args.kwargs["Arguments"]["--SOURCE_KEY"], "manual.csv")

    def test_comex_query_preserves_all_filters(self):
        response = {"success": True, "data": {"list": [{"year": "2026"}]}}
        with patch.object(self.module, "read_page", side_effect=[
            {"success": True, "data": {"year": 2026, "monthNumber": 9}}, response,
        ]) as read:
            document, records, url, payload = self.module.collect_comex(self.context)
        self.assertEqual(payload["flow"], "import")
        self.assertEqual(payload["period"], {"from": "2002-01", "to": "2026-09"})
        self.assertTrue(payload["monthDetail"])
        self.assertEqual(payload["details"], ["ncm", "country", "state"])
        self.assertEqual(payload["metrics"], ["metricFOB", "metricKG", "metricStatistic"])
        self.assertEqual(payload["filters"][0]["values"], os.environ["COMEX_NCM_CODES"].split(","))
        self.assertEqual(read.call_args.args, (url, self.context, payload))
        self.assertEqual(document, response)
        self.assertEqual(len(records), 1)

    def test_comex_disabled_fails_before_network(self):
        with patch.dict(os.environ, {"COMEX_ENABLED": "false"}), patch.object(
            self.module, "collect_comex"
        ) as collector, self.assertRaisesRegex(ValueError, "desativada"):
            self.module.ingest(self.context, "comexstat")
        collector.assert_not_called()
        self.s3.put_object.assert_not_called()

    def test_comex_empty_or_unavailable_fails_explicitly(self):
        for result in [
            {"success": False},
            {"success": True, "data": {"list": []}},
        ]:
            with self.subTest(result=result), patch.object(self.module, "read_page", side_effect=[
                {"success": True, "data": {"year": 2026, "monthNumber": 9}}, result,
            ]), self.assertRaises(ValueError):
                self.module.collect_comex(self.context)

    def test_comex_initial_waits_for_silver(self):
        self.prepare_ingestion(["SUCCEEDED"])
        document = {"success": True, "data": {"list": [{"year": "2026"}]}}
        with patch.object(self.module, "collect_comex", return_value=(
            document, document["data"]["list"], "https://api-comexstat.mdic.gov.br/general",
            {"flow": "import"},
        )):
            self.module.lambda_handler({
                "RequestType": "Create", "ResourceProperties": {"Source": "comexstat"}
            }, self.context)
        self.assertEqual(self.response.send.call_args.args[2], self.response.SUCCESS)
        manifest = json.loads(self.s3.put_object.call_args_list[1].kwargs["Body"])
        self.assertEqual(manifest["source"], "comexstat")
        self.assertEqual(manifest["request"], {"flow": "import"})
        self.assertTrue(manifest["key"].startswith("comexstat/consulta=162584/flow=import/"))
        self.s3.get_paginator.assert_called_once()

    def test_metadata_and_comex_do_not_start_duplicate_jobs(self):
        module, _, glue, _ = load_function("GlueStarterFunction")
        for key in ["comexstat/response.json", "_metadata/manifest.json"]:
            module.lambda_handler({"detail": {"object": {"key": key}}}, self.context)
        glue.start_job_run.assert_not_called()

    def test_publisher_versions_script_in_artifacts(self):
        module, s3, _, _ = load_function("ScriptPublisherFunction")
        script = "print('script')\n"
        digest = hashlib.sha256(script.encode()).hexdigest()
        event = {
            "RequestType": "Create", "ResourceProperties": {
                "Bucket": "artifacts", "Key": "_glue/stack/job.py", "Script": script},
            "ResponseURL": "https://example.com/callback", "StackId": "stack",
            "RequestId": "request", "LogicalResourceId": "GlueScript",
        }
        with patch.object(module.urllib.request, "urlopen") as callback:
            module.lambda_handler(event, self.context)
        upload = s3.put_object.call_args.kwargs
        self.assertEqual(upload["Bucket"], "artifacts")
        self.assertEqual(upload["Key"], f"_glue/stack/job-{digest}.py")
        self.assertEqual(upload["Metadata"]["sha256"], digest)
        result = json.loads(callback.call_args.args[0].data)
        self.assertEqual(result["Data"]["ScriptS3Uri"], f"s3://artifacts/_glue/stack/job-{digest}.py")
        self.assertEqual(result["Status"], "SUCCESS")

    def test_publisher_delete_respects_previous_physical_key(self):
        module, s3, _, _ = load_function("ScriptPublisherFunction")
        event = {
            "RequestType": "Delete", "PhysicalResourceId": "silver/_glue/stack/old.py",
            "ResourceProperties": {
                "Bucket": "silver", "Key": "_glue/stack/old.py", "Script": "print('old')"},
            "ResponseURL": "https://example.com/callback", "StackId": "stack",
            "RequestId": "request", "LogicalResourceId": "GlueScript",
        }
        with patch.object(module.urllib.request, "urlopen"):
            module.lambda_handler(event, self.context)
        s3.delete_object.assert_called_once_with(Bucket="silver", Key="_glue/stack/old.py")


if __name__ == "__main__":
    unittest.main()
