"""Offline dashboard contracts; resource schemas are checked with cfn-lint."""

import json
from pathlib import Path
import re
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ObservabilityTests(unittest.TestCase):
    def test_dashboard_bodies_are_json_with_declared_substitutions(self):
        source = (ROOT / "observabilidade-ti.yaml").read_text(encoding="utf-8")
        parameters = source.split("Parameters:\n", 1)[1].split("\nRules:", 1)[0]
        declared = set(re.findall(r"^  (\w+):", parameters, re.M)) | {"AWS::Region"}
        bodies = re.findall(
            r"(?ms)^      DashboardBody: !Sub \|\n(.*?)(?=^  \w+:|\Z)", source
        )
        self.assertEqual(len(bodies), 2)
        for body in bodies:
            with self.subTest(dashboard=body[:80]):
                dashboard = json.loads(textwrap.dedent(body))
                self.assertGreater(len(dashboard["widgets"]), 0)
                self.assertTrue(set(re.findall(r"\$\{([^}]+)\}", body)) <= declared)
                for widget in dashboard["widgets"]:
                    self.assertLessEqual(widget["x"] + widget["width"], 24)

    def test_data_lake_outputs_cover_monitoring_inputs(self):
        lake = (ROOT / "buckets+lambda.yml").read_text(encoding="utf-8")
        outputs = lake.split("\nOutputs:\n", 1)[1]
        for name in [
            "IpeaIngestionFunctionName", "UploadFunctionName", "GlueStarterFunctionName",
            "ScriptPublisherFunctionName", "BucketCleanupFunctionName",
            "IpeaMonthlyRuleName", "BronzeBucketName", "SilverBucketName", "GoldBucketName",
            "BronzeToSilverJobName",
        ]:
            with self.subTest(output=name):
                self.assertIn(f"  {name}:", outputs)

    def test_telemetry_never_creates_iam_roles(self):
        for filename in ["observabilidade-ti.yaml", "buckets+lambda.yml"]:
            with self.subTest(template=filename):
                source = (ROOT / filename).read_text(encoding="utf-8")
                self.assertNotIn("Type: AWS::IAM::", source)


if __name__ == "__main__":
    unittest.main()
