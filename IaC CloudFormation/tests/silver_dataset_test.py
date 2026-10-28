"""Offline schema, quality, lineage and catalog tests for the embedded Glue job."""

from datetime import date
from decimal import Decimal
import hashlib
import io
import json
from pathlib import Path
import re
import sys
import textwrap
import types
import unittest
from unittest.mock import Mock, patch


TEMPLATE = Path(__file__).resolve().parents[1] / "buckets+lambda.yml"


def load_job():
    source = re.search(
        r"(?ms)^      Script: \|\n(.*?)(?=^  SilverDatabase:)",
        TEMPLATE.read_text(encoding="utf-8"),
    ).group(1)
    s3, glue, spark = Mock(), Mock(), Mock()
    class EntityNotFound(Exception):
        pass
    glue.exceptions.EntityNotFoundException = EntityNotFound
    modules = {
        "boto3": types.SimpleNamespace(client=lambda service: s3 if service == "s3" else glue),
        "awsglue": types.ModuleType("awsglue"),
        "awsglue.utils": types.SimpleNamespace(getResolvedOptions=Mock()),
        "pyspark": types.ModuleType("pyspark"),
        "pyspark.sql": types.SimpleNamespace(
            SparkSession=types.SimpleNamespace(builder=types.SimpleNamespace(getOrCreate=lambda: spark))),
        "pyspark.sql.types": types.SimpleNamespace(
            StructType=lambda fields: fields, StructField=lambda name, kind, nullable: (name, kind),
            StringType=lambda: "string", IntegerType=lambda: "int", DateType=lambda: "date",
            DecimalType=lambda precision, scale: (precision, scale)),
    }
    job = types.ModuleType("silver_dataset")
    with patch.dict(sys.modules, modules):
        exec(compile(textwrap.dedent(source), "<GlueScript>", "exec"), job.__dict__)
    return job, s3, glue, spark


def ipea(**changes):
    return {
        "SERCODIGO": "BM_ERV", "VALDATA": "2025-01-01T00:00:00-03:00",
        "VALVALOR": "5.5879", "NIVNOME": "", "TERCODIGO": "", **changes,
    }


def comex(**changes):
    return {
        "year": "2026", "monthNumber": "09", "coNcm": "01234567", "ncm": "Pecas",
        "country": "China", "state": "Santa Catarina", "metricFOB": "12345678901234567890.123456",
        "metricKG": "10.25", "metricStatistic": "3", **changes,
    }


class SilverTests(unittest.TestCase):
    def setUp(self):
        self.job, self.s3, self.glue, self.spark = load_job()

    def test_historical_ipea_decimal_and_optional_fields(self):
        row = self.job.normalize("ipeadata", ipea(VALVALOR="7.27272727272727E-16"))
        self.assertEqual(row["taxa_cambio"], Decimal("0.000000000000000727272727272727"))
        self.assertEqual(row["data_referencia"], date(2025, 1, 1))
        self.assertIsNone(row["nivel"])
        self.assertIsNone(row["territorio_codigo"])
        self.assertIsNone(self.job.normalize("ipeadata", ipea(VALVALOR=None))["taxa_cambio"])

    def test_comex_schema_preserves_code_and_financial_precision(self):
        row = self.job.normalize("comexstat", comex())
        self.assertEqual(row["ncm_codigo"], "01234567")
        self.assertEqual(row["fluxo"], "import")
        self.assertEqual(row["mes"], 9)
        self.assertEqual(row["data_referencia"], date(2026, 9, 1))
        self.assertEqual(row["valor_fob_usd"], Decimal("12345678901234567890.123456"))
        self.assertEqual(dict(self.job.schema_for("comexstat"))["valor_fob_usd"], (38, 6))
        self.assertEqual(dict(self.job.schema_for("ipeadata"))["taxa_cambio"], (38, 30))

    def test_bad_values_are_rejected_without_rounding_or_code_coercion(self):
        for changes in [
            {"coNcm": 1234567}, {"coNcm": "1234567"}, {"monthNumber": "13"},
            {"year": "1996"}, {"metricFOB": "-1"}, {"metricKG": "NaN"},
            {"metricStatistic": "1.1234567"}, {"country": None},
        ]:
            with self.subTest(changes=changes):
                accepted, rejected, _ = self.job.normalize_records("comexstat", [comex(**changes)])
                self.assertEqual(accepted, [])
                self.assertEqual(len(rejected), 1)

    def test_duplicates_removed_and_conflicting_keys_quarantined(self):
        accepted, rejected, duplicates = self.job.normalize_records(
            "comexstat", [comex(), comex(), comex(metricFOB="1"), comex(metricFOB="2")])
        self.assertEqual(accepted, [])
        self.assertEqual(len(rejected), 3)
        self.assertEqual(duplicates, 1)

    def prepare_snapshot(self, records, source="ipeadata"):
        key = source + "/run_id=abc/data.json"
        document = records if source == "ipeadata" else {"success": True, "data": {"list": records}}
        raw = json.dumps(document).encode()
        manifest = {
            "status": "COMPLETE", "source": source, "key": key, "run_id": "abc",
            "collected_at": "2026-10-28T12:00:00+00:00", "bytes": len(raw),
            "sha256": hashlib.sha256(raw).hexdigest(), "records": len(records),
        }
        self.args = {
            "SOURCE_BUCKET": "bronze", "TARGET_BUCKET": "silver",
            "SOURCE_KEY": key, "CATALOG_DATABASE": "catalog",
        }
        return raw, manifest

    def serve_snapshot(self, raw, manifest):
        self.s3.get_object.side_effect = [
            {"Body": io.BytesIO(json.dumps(manifest).encode())}, {"Body": io.BytesIO(raw)},
        ]

    def test_manifest_integrity_mismatch_blocks_publication(self):
        raw, manifest = self.prepare_snapshot([ipea()])
        for changes in [{"sha256": "wrong"}, {"bytes": 0}, {"records": 999}, {"status": "PARTIAL"}]:
            with self.subTest(changes=changes):
                self.serve_snapshot(raw, dict(manifest, **changes))
                with self.assertRaises(ValueError):
                    self.job.process_dataset(self.spark, self.args)
        self.spark.createDataFrame.assert_not_called()
        self.glue.update_table.assert_not_called()

    def test_dataset_has_lineage_and_published_quality_report(self):
        raw, manifest = self.prepare_snapshot([ipea(), ipea(), ipea(VALDATA="invalid")])
        self.serve_snapshot(raw, manifest)
        self.job.process_dataset(self.spark, self.args)
        rows = self.spark.createDataFrame.call_args.args[0]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["bronze_key"], self.args["SOURCE_KEY"])
        self.assertEqual(rows[0]["bronze_run_id"], "abc")
        self.assertEqual(rows[0]["data_ingestao"], date(2026, 10, 28))
        writes = [call.kwargs for call in self.s3.put_object.call_args_list]
        self.assertTrue(any(item["Key"].startswith("_rejected/") for item in writes))
        report = json.loads(writes[-1]["Body"])
        self.assertEqual(
            (report["status"], report["accepted"], report["rejected"], report["duplicates_removed"]),
            ("PUBLISHED", 1, 1, 1))
        table = self.glue.update_table.call_args.kwargs["TableInput"]
        self.assertEqual(table["Name"], "ipeadata")
        self.assertEqual(table["StorageDescriptor"]["Location"],
                         "s3://silver/" + self.args["SOURCE_KEY"] + ".parquet/")

    def test_no_valid_rows_preserves_previous_catalog(self):
        raw, manifest = self.prepare_snapshot([ipea(VALDATA="invalid")])
        self.serve_snapshot(raw, manifest)
        with self.assertRaisesRegex(ValueError, "Nenhum registro valido"):
            self.job.process_dataset(self.spark, self.args)
        self.glue.update_table.assert_not_called()
        self.glue.create_table.assert_not_called()
        self.spark.createDataFrame.assert_not_called()
        report = json.loads(self.s3.put_object.call_args.kwargs["Body"])
        self.assertEqual(report["status"], "FAILED_NO_VALID_ROWS")

    def test_new_comex_table_created_with_full_schema(self):
        raw, manifest = self.prepare_snapshot([comex()], "comexstat")
        self.serve_snapshot(raw, manifest)
        self.glue.get_table.side_effect = self.glue.exceptions.EntityNotFoundException()
        self.job.process_dataset(self.spark, self.args)
        table = self.glue.create_table.call_args.kwargs["TableInput"]
        self.assertEqual(table["Name"], "comexstat")
        fields = {item["Name"]: item["Type"] for item in table["StorageDescriptor"]["Columns"]}
        self.assertEqual(fields["ncm_codigo"], "string")
        self.assertEqual(fields["valor_fob_usd"], "decimal(38,6)")
        self.assertIn("bronze_run_id", fields)

    def test_catalog_failure_does_not_report_published(self):
        raw, manifest = self.prepare_snapshot([ipea()])
        self.serve_snapshot(raw, manifest)
        self.glue.update_table.side_effect = RuntimeError("AccessDenied")
        with self.assertRaisesRegex(RuntimeError, "AccessDenied"):
            self.job.process_dataset(self.spark, self.args)
        report = json.loads(self.s3.put_object.call_args.kwargs["Body"])
        self.assertEqual(report["status"], "READY_TO_PUBLISH")

    def test_generic_csv_upload_keeps_original_path(self):
        self.job.getResolvedOptions.return_value = {
            "SOURCE_BUCKET": "bronze", "TARGET_BUCKET": "silver",
            "SOURCE_KEY": "manual.csv", "CATALOG_DATABASE": "catalog"}
        frame = self.spark.read.option.return_value.option.return_value.csv.return_value
        frame.columns = ["a", "b"]
        self.job.main()
        frame.na.drop.return_value.dropDuplicates.return_value.write.mode.return_value.parquet.assert_called_once_with(
            "s3://silver/manual.csv.parquet/")


if __name__ == "__main__":
    unittest.main()
