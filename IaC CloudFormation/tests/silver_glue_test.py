from datetime import date, datetime, timezone
from decimal import Decimal
import hashlib
import io
import json
from pathlib import Path
import types
import unittest
from unittest.mock import Mock, patch

import pyarrow.parquet as pq
import yaml


ROOT = Path(__file__).resolve().parents[1]


class TemplateLoader(yaml.SafeLoader):
    pass


TemplateLoader.add_multi_constructor(
    "!", lambda loader, tag, node: loader.construct_scalar(node)
    if isinstance(node, yaml.ScalarNode) else loader.construct_sequence(node)
)
DOCUMENT = yaml.load((ROOT / "buckets+lambda.yml").read_text(encoding="utf-8"), Loader=TemplateLoader)
JOB = types.ModuleType("silver_job")
exec(compile(DOCUMENT["Mappings"]["GlueScript"]["Silver"]["Code"], "<silver_glue>", "exec"), JOB.__dict__)


def ipea(**changes):
    return dict({
        "SERCODIGO": "BM_ERV", "VALDATA": "2025-01-01T00:00:00-03:00",
        "VALVALOR": Decimal("5.5879"), "NIVNOME": "", "TERCODIGO": "",
    }, **changes)


def comex(**changes):
    return dict({
        "year": "2026", "monthNumber": "09", "coNcm": "01234567",
        "ncm": "Descricao", "country": "China", "state": "Santa Catarina",
        "metricFOB": "12345678901234567890.123456",
        "metricKG": "10.25", "metricStatistic": "3",
    }, **changes)


class SilverTransformTests(unittest.TestCase):
    def test_ipea_date_nulls_and_historical_precision(self):
        row = JOB.normalize("ipeadata", ipea(VALVALOR=Decimal("7.27272727272727E-16")))
        self.assertEqual(row["data_referencia"], date(2025, 1, 1))
        self.assertEqual(row["taxa_cambio"], Decimal("0.000000000000000727272727272727"))
        self.assertIsNone(row["nivel"])
        self.assertIsNone(JOB.normalize("ipeadata", ipea(VALVALOR=None))["taxa_cambio"])
        missing = ipea()
        del missing["VALVALOR"]
        with self.assertRaisesRegex(ValueError, "ausente"):
            JOB.normalize("ipeadata", missing)

    def test_comex_code_and_financial_precision(self):
        row = JOB.normalize("comexstat", comex())
        self.assertEqual(row["ncm_codigo"], "01234567")
        self.assertEqual(row["data_referencia"], date(2026, 9, 1))
        self.assertEqual(row["valor_fob_usd"], Decimal("12345678901234567890.123456"))
        self.assertEqual(row["quantidade_estatistica"], Decimal("3.000000"))

    def test_invalid_records_are_quarantined_not_silently_dropped(self):
        invalid = [
            comex(monthNumber="13"), comex(coNcm=1234567), comex(metricKG="-1"),
            comex(metricFOB="NaN"), comex(metricStatistic="0.0000001"),
            comex(country=""), comex(metricFOB="1,20"), None,
        ]
        valid, rejected, duplicates = JOB.normalize_records(
            "comexstat", [(row, "bronze.json") for row in invalid] + [(comex(), "valid.json")]
        )
        self.assertEqual((len(valid), len(rejected), duplicates), (1, len(invalid), 0))
        self.assertTrue(all(item["reason"] and item["bronze_key"] for item in rejected))

    def test_exact_duplicates_are_counted_and_conflicts_all_rejected(self):
        records = [
            (ipea(), "page1.json"), (ipea(), "page2.json"),
            (ipea(VALVALOR=Decimal("5.7")), "page3.json"), (ipea(), "page4.json"),
        ]
        valid, rejected, duplicates = JOB.normalize_records("ipeadata", records)
        self.assertEqual((len(valid), len(rejected), duplicates), (0, 3, 1))

    def test_real_parquet_has_explicit_types_and_exact_values(self):
        for source, original in [("ipeadata", ipea()), ("comexstat", comex())]:
            with self.subTest(source=source):
                row = dict(
                    JOB.normalize(source, original), bronze_key="original.json",
                    bronze_run_id="run-1", data_ingestao=date(2026, 10, 22),
                )
                raw = JOB.parquet_bytes(source, [row])
                self.assertTrue(raw.startswith(b"PAR1") and raw.endswith(b"PAR1"))
                table = pq.read_table(io.BytesIO(raw))
                self.assertEqual(table.schema, JOB.arrow_schema(source))
                self.assertEqual(table.to_pylist()[0], row)
                self.assertTrue(pq.ParquetFile(io.BytesIO(raw)).metadata.row_group(0).column(0).compression == "SNAPPY")

    def test_manifest_only_selects_latest_completed_run(self):
        s3 = Mock()
        older = "_metadata/ipeadata/ingestion_date=2026-10-21/run_id=old/manifest.json"
        latest = "_metadata/ipeadata/ingestion_date=2026-10-22/run_id=new/manifest.json"
        s3.get_paginator.return_value.paginate.return_value = [
            {"Contents": [{"Key": older, "LastModified": datetime(2026, 10, 21, tzinfo=timezone.utc)}]},
            {"Contents": [
                {"Key": latest, "LastModified": datetime(2026, 10, 22, tzinfo=timezone.utc)},
                {"Key": "_metadata/ipeadata/unfinished.json", "LastModified": datetime.now(timezone.utc)},
            ]},
        ]
        data_key = "ipeadata/serie=BM_ERV/ingestion_date=2026-10-22/run_id=new/page-0001.json"
        manifest = {"status": "COMPLETE", "source": "ipeadata", "keys": [data_key]}
        with patch.object(JOB, "load_json", return_value=manifest):
            selected = JOB.latest_manifest(s3, "bronze", "ipeadata")
        self.assertEqual(selected, (latest, [data_key], date(2026, 10, 22), "new"))
        for bad_keys in [[data_key.replace("run_id=new", "run_id=other")], [data_key, data_key], [{}]]:
            with self.subTest(keys=bad_keys):
                manifest["keys"] = bad_keys
                with patch.object(JOB, "load_json", return_value=manifest):
                    with self.assertRaises(ValueError):
                        JOB.latest_manifest(s3, "bronze", "ipeadata")

    def test_no_manifest_is_explicit_failure(self):
        s3 = Mock()
        s3.get_paginator.return_value.paginate.return_value = [{}]
        with self.assertRaisesRegex(ValueError, "Nenhum manifesto"):
            JOB.latest_manifest(s3, "bronze", "comexstat")

    def test_explicit_manifest_pins_bootstrap_to_its_own_collection(self):
        s3 = Mock()
        manifest_key = "_metadata/ipeadata/ingestion_date=2026-10-22/run_id=initial/manifest.json"
        data_key = "ipeadata/serie=BM_ERV/ingestion_date=2026-10-22/run_id=initial/page-0001.json"
        manifest = {"status": "COMPLETE", "source": "ipeadata", "keys": [data_key]}
        with patch.object(JOB, "load_json", return_value=manifest):
            selected = JOB.latest_manifest(s3, "bronze", "ipeadata", manifest_key)
        self.assertEqual(selected[0], manifest_key)
        s3.get_paginator.assert_not_called()
        with self.assertRaisesRegex(ValueError, "fora do prefixo"):
            JOB.latest_manifest(s3, "bronze", "ipeadata", manifest_key.replace("/ipeadata/", "/comexstat/"))

    def test_hash_mismatch_fails_before_transformation(self):
        raw = b'{"value":[{}]}'
        metadata = {"key": "data.json", "bytes": len(raw), "sha256": "wrong"}
        with patch.object(JOB, "get_bytes", return_value=raw), patch.object(JOB, "load_json", return_value=metadata):
            with self.assertRaisesRegex(ValueError, "Integridade"):
                list(JOB.read_records(Mock(), "bronze", "ipeadata", ["data.json"]))
        metadata["sha256"] = hashlib.sha256(raw).hexdigest()
        with patch.object(JOB, "get_bytes", return_value=raw), patch.object(JOB, "load_json", return_value=metadata):
            self.assertEqual(list(JOB.read_records(Mock(), "bronze", "ipeadata", ["data.json"])), [({}, "data.json")])

    def test_publish_creates_then_updates_catalog_location(self):
        class NotFound(Exception):
            pass
        glue = Mock()
        glue.exceptions.EntityNotFoundException = NotFound
        glue.get_table.side_effect = NotFound()
        JOB.publish_table(glue, "silver_db", "ipeadata", "s3://silver/first/", "manifest1")
        table = glue.create_table.call_args.kwargs["TableInput"]
        self.assertEqual(table["StorageDescriptor"]["Location"], "s3://silver/first/")
        self.assertEqual(table["StorageDescriptor"]["Columns"][3]["Type"], "decimal(38,30)")
        glue.get_table.side_effect = None
        JOB.publish_table(glue, "silver_db", "ipeadata", "s3://silver/second/", "manifest2")
        self.assertEqual(
            glue.update_table.call_args.kwargs["TableInput"]["StorageDescriptor"]["Location"], "s3://silver/second/"
        )

    def test_write_failure_does_not_change_catalog(self):
        s3, glue = Mock(), Mock()
        s3.put_object.side_effect = RuntimeError("S3 failed")
        with patch.object(JOB, "latest_manifest", return_value=("manifest", ["key"], date(2026, 10, 22), "run-1")):
            with patch.object(JOB, "read_records", return_value=iter([(ipea(), "key")])):
                with self.assertRaisesRegex(RuntimeError, "S3 failed"):
                    JOB.process_source(s3, glue, "bronze", "silver", "db", "ipeadata")
        glue.create_table.assert_not_called()
        glue.update_table.assert_not_called()

    def test_all_invalid_preserves_previous_table_and_records_rejection(self):
        s3, glue = Mock(), Mock()
        with patch.object(JOB, "latest_manifest", return_value=("manifest", ["key"], date(2026, 10, 22), "run-1")):
            with patch.object(JOB, "read_records", return_value=iter([(comex(monthNumber="13"), "key")])):
                with self.assertRaisesRegex(ValueError, "Nenhum registro valido"):
                    JOB.process_source(s3, glue, "bronze", "silver", "db", "comexstat")
        keys = [call.kwargs["Key"] for call in s3.put_object.call_args_list]
        self.assertTrue(any(key.startswith("_rejected/comexstat/") for key in keys))
        glue.create_table.assert_not_called()
        glue.update_table.assert_not_called()

    def test_complete_pipeline_writes_data_before_catalog_and_reports_counts(self):
        operations = []
        s3, glue = Mock(), Mock()
        s3.put_object.side_effect = lambda **kwargs: operations.append(kwargs)
        with patch.object(JOB, "latest_manifest", return_value=("manifest", ["key"], date(2026, 10, 22), "run-1")):
            records = [(comex(), "key"), (comex(), "key"), (comex(monthNumber="13"), "key")]
            with patch.object(JOB, "read_records", return_value=iter(records)):
                with patch.object(JOB, "publish_table", side_effect=lambda *args: operations.append("catalog")):
                    JOB.process_source(s3, glue, "bronze", "silver", "db", "comexstat")
        data_index = next(i for i, item in enumerate(operations) if isinstance(item, dict) and item["Key"].endswith(".parquet"))
        self.assertLess(data_index, operations.index("catalog"))
        report = json.loads(operations[-1]["Body"])
        self.assertEqual(report["status"], "PUBLISHED")
        self.assertEqual((report["accepted"], report["rejected"], report["duplicates_removed"]), (1, 1, 1))

    def test_template_keeps_cost_and_execution_bounded(self):
        document = DOCUMENT
        job = document["Resources"]["BronzeToSilverJob"]["Properties"]
        self.assertEqual(job["Command"]["Name"], "pythonshell")
        self.assertEqual(job["Command"]["PythonVersion"], "3.9")
        self.assertEqual(job["MaxCapacity"], 0.0625)
        self.assertEqual(job["MaxRetries"], 0)
        self.assertEqual(job["ExecutionProperty"]["MaxConcurrentRuns"], 1)
        self.assertFalse(any(resource["Type"] == "AWS::Glue::Trigger" for resource in document["Resources"].values()))


if __name__ == "__main__":
    unittest.main()
