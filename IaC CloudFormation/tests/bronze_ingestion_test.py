import io
import json
import os
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import Mock, patch
import urllib.error

import yaml


class TemplateLoader(yaml.SafeLoader):
    pass


TemplateLoader.add_multi_constructor(
    "!", lambda loader, tag, node: loader.construct_scalar(node)
    if isinstance(node, yaml.ScalarNode)
    else loader.construct_sequence(node)
)
TEMPLATE = Path(__file__).resolve().parents[1] / "buckets+lambda.yml"
DOCUMENT = yaml.load(TEMPLATE.read_text(encoding="utf-8"), Loader=TemplateLoader)
CODE = DOCUMENT["Resources"]["BronzeIngestionFunction"]["Properties"]["Code"]["ZipFile"]


class BronzeIngestionTests(unittest.TestCase):
    def setUp(self):
        self.s3 = Mock()
        boto3 = types.ModuleType("boto3")
        boto3.client = Mock(return_value=self.s3)
        self.namespace = {}
        self.environment = patch.dict(os.environ, {
            "BUCKET_NAME": "test-bronze",
            "COMEX_YEARS": "25",
            "COMEX_NCM_CODES": "84271011,84272010,84271019,84279000,84312011,84312019",
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)
        with patch.dict(sys.modules, {"boto3": boto3}):
            exec(compile(CODE, "<bronze_lambda>", "exec"), self.namespace)
        self.context = Mock(aws_request_id="test-run")
        self.context.get_remaining_time_in_millis.return_value = 300000

    def test_comex_25_year_window_and_original_bytes(self):
        raw = b'{ "success": true, "data": {"list": [{"metricFOB":"123.45"}]} }\n'
        fetch = Mock(side_effect=[
            (b"{}", {"success": True, "data": {"year": "2026", "monthNumber": "09"}}),
            (raw, json.loads(raw)),
        ])
        self.namespace["fetch_json"] = fetch
        result = self.namespace["lambda_handler"]({"source": "comexstat"}, self.context)
        payload = fetch.call_args.args[2]
        self.assertEqual(payload["period"], {"from": "2002-01", "to": "2026-09"})
        self.assertEqual(payload["flow"], "import")
        self.assertEqual(len(payload["filters"][0]["values"]), 6)
        self.assertEqual(payload["details"], ["ncm", "country", "state"])
        self.assertEqual(payload["metrics"], ["metricFOB", "metricKG", "metricStatistic"])
        stored = self.s3.put_object.call_args_list
        self.assertEqual(stored[0].kwargs["Body"], raw)
        self.assertTrue(result["keys"][0].startswith("comexstat/consulta=162584/flow=import/"))
        self.assertTrue(stored[1].kwargs["Key"].startswith("_metadata/comexstat/"))
        self.assertEqual(json.loads(stored[1].kwargs["Body"])["request"], payload)
        self.assertEqual(stored[-1].kwargs["Key"], result["manifest"])
        self.assertEqual(json.loads(stored[-1].kwargs["Body"])["status"], "COMPLETE")

    def test_window_rolls_with_available_year(self):
        os.environ["COMEX_YEARS"] = "2"
        fetch = Mock(side_effect=[
            (b"{}", {"success": True, "data": {"year": "2025", "monthNumber": "12"}}),
            (b"{}", {"success": True, "data": {"list": [{}]}}),
        ])
        self.namespace["fetch_json"] = fetch
        self.namespace["lambda_handler"]({"source": "comexstat"}, self.context)
        self.assertEqual(fetch.call_args.args[2]["period"], {"from": "2024-01", "to": "2025-12"})

    def test_ipeadata_preserves_pages_and_separates_source(self):
        raw = b'{ "value": [{"VALVALOR": null}], "@odata.nextLink": "?page=2" }'
        self.namespace["fetch_json"] = Mock(side_effect=[
            (raw, json.loads(raw)), (b'{"value":[{}]}', {"value": [{}]}),
        ])
        result = self.namespace["lambda_handler"]({"source": "ipeadata"}, self.context)
        self.assertEqual(len(result["keys"]), 2)
        self.assertTrue(all(key.startswith("ipeadata/serie=BM_ERV/") for key in result["keys"]))
        self.assertEqual(self.s3.put_object.call_args_list[0].kwargs["Body"], raw)

    def test_untrusted_pagination_fails(self):
        self.namespace["fetch_json"] = Mock(return_value=(
            b"{}", {"value": [{}], "@odata.nextLink": "https://example.invalid/data"},
        ))
        with self.assertRaisesRegex(ValueError, "nao permitido"):
            self.namespace["lambda_handler"]({"source": "ipeadata"}, self.context)
        self.assertEqual(self.namespace["fetch_json"].call_count, 1)
        self.assertFalse(any(call.kwargs["Key"].endswith("/manifest.json")
                             for call in self.s3.put_object.call_args_list))

    def test_invalid_source_does_not_write(self):
        with self.assertRaises(ValueError):
            self.namespace["lambda_handler"]({"source": "unknown"}, self.context)
        self.s3.put_object.assert_not_called()

    def test_source_error_or_empty_dataset_does_not_write(self):
        for response in [{"success": False}, {"success": True, "data": {"list": []}}]:
            with self.subTest(response=response):
                self.namespace["fetch_json"] = Mock(side_effect=[
                    (b"{}", {"success": True, "data": {"year": "2026", "monthNumber": "09"}}),
                    (b"{}", response),
                ])
                with self.assertRaises(ValueError):
                    self.namespace["lambda_handler"]({"source": "comexstat"}, self.context)
                self.s3.put_object.assert_not_called()

    def test_s3_error_is_propagated(self):
        self.namespace["fetch_json"] = Mock(return_value=(b'{"value":[{}]}', {"value": [{}]}))
        self.s3.put_object.side_effect = RuntimeError("S3 access denied")
        with self.assertRaisesRegex(RuntimeError, "S3 access denied"):
            self.namespace["lambda_handler"]({"source": "ipeadata"}, self.context)
        self.assertFalse(any(call.kwargs["Key"].endswith("/manifest.json")
                             for call in self.s3.put_object.call_args_list))

    def test_429_retry_after_then_success(self):
        error = urllib.error.HTTPError("https://example.invalid", 429, "rate limit", {"Retry-After": "15"}, None)
        with patch("urllib.request.urlopen", side_effect=[error, io.BytesIO(b'{"value":[]}')]) as request:
            with patch("time.sleep") as sleep:
                raw, data = self.namespace["fetch_json"]("https://example.invalid", self.context)
        self.assertEqual(request.call_count, 2)
        sleep.assert_called_once_with(15)
        self.assertEqual(raw, b'{"value":[]}')
        self.assertEqual(data, {"value": []})

    def test_429_exhaustion_is_not_success(self):
        error = urllib.error.HTTPError("https://example.invalid", 429, "rate limit", {}, None)
        with patch("urllib.request.urlopen", side_effect=error) as request, patch("time.sleep"):
            with self.assertRaises(urllib.error.HTTPError):
                self.namespace["fetch_json"]("https://example.invalid", self.context)
        self.assertEqual(request.call_count, 3)

    def test_long_retry_after_fails_without_sleeping(self):
        error = urllib.error.HTTPError("https://example.invalid", 429, "rate limit", {"Retry-After": "120"}, None)
        with patch("urllib.request.urlopen", side_effect=error), patch("time.sleep") as sleep:
            with self.assertRaisesRegex(RuntimeError, "espera longa"):
                self.namespace["fetch_json"]("https://example.invalid", self.context)
        sleep.assert_not_called()

    def test_non_transient_http_error_is_not_retried(self):
        error = urllib.error.HTTPError("https://example.invalid", 400, "invalid query", {}, None)
        with patch("urllib.request.urlopen", side_effect=error) as request:
            with self.assertRaises(urllib.error.HTTPError):
                self.namespace["fetch_json"]("https://example.invalid", self.context)
        request.assert_called_once()

    def test_html_or_oversized_response_is_rejected(self):
        for raw, limit in [(b"<html>Error</html>", 100), (b"x" * 11, 10)]:
            with self.subTest(raw=raw):
                self.namespace["MAX_BYTES"] = limit
                with patch("urllib.request.urlopen", return_value=io.BytesIO(raw)):
                    with self.assertRaises(ValueError):
                        self.namespace["fetch_json"]("https://example.invalid", self.context)

    def test_short_remaining_time_fails_before_request(self):
        self.context.get_remaining_time_in_millis.return_value = 19000
        with patch("urllib.request.urlopen") as request:
            with self.assertRaises(TimeoutError):
                self.namespace["fetch_json"]("https://example.invalid", self.context)
        request.assert_not_called()

    def test_schedule_disabled_and_no_public_url(self):
        self.assertEqual(DOCUMENT["Parameters"]["ScheduleState"]["Default"], "DISABLED")
        resources = DOCUMENT["Resources"]
        self.assertFalse(any(resource["Type"] == "AWS::Lambda::Url" for resource in resources.values()))
        self.assertEqual(resources["BronzeIngestionFunction"]["Properties"]["MemorySize"], 512)
        targets = resources["IngestionSchedule"]["Properties"]["Targets"]
        self.assertEqual({json.loads(t["Input"])["source"] for t in targets}, {"ipeadata", "comexstat"})


if __name__ == "__main__":
    unittest.main()
