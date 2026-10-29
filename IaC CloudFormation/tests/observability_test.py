"""Offline dashboard contracts; resource schemas are checked with cfn-lint."""

import json
from pathlib import Path
import re
import unittest

from swarm_configuration_test import Renderer, load_template


ROOT = Path(__file__).resolve().parents[1]


class ObservabilityTests(unittest.TestCase):
    def test_dashboard_bodies_are_json_with_declared_substitutions(self):
        template = load_template("observabilidade-ti.yaml")
        declared = set(template["Parameters"]) | {"AWS::Region"}
        bodies = [
            resource["Properties"]["DashboardBody"]
            for resource in template["Resources"].values()
            if resource["Type"] == "AWS::CloudWatch::Dashboard"
        ]
        self.assertEqual(len(bodies), 2)
        for body in bodies:
            value = body["Fn::Sub"]
            text, variables = (value, {}) if isinstance(value, str) else value
            self.assertTrue(set(re.findall(r"\$\{([^}]+)\}", text)) <= declared | set(variables))
            with self.subTest(dashboard=text[:80]):
                dashboard = json.loads(Renderer(template).render(body))
                self.assertGreater(len(dashboard["widgets"]), 0)
                for widget in dashboard["widgets"]:
                    self.assertLessEqual(widget["x"] + widget["width"], 24)

    def test_single_manager_has_metrics_alarm_and_no_second_manager(self):
        source = (ROOT / "observabilidade-ti.yaml").read_text(encoding="utf-8")
        template = load_template("observabilidade-ti.yaml")
        body = template["Resources"]["OperationsDashboard"]["Properties"]["DashboardBody"]
        dashboard = json.loads(Renderer(template, SwarmManagerInstanceId="i-manager").render(body))
        covered = {
            metric[1]
            for widget in dashboard["widgets"]
            for metric in widget["properties"].get("metrics", [])
            if metric[0] == "AWS/EC2" and metric[3] == "i-manager"
        }
        self.assertEqual(covered, {"CPUUtilization", "StatusCheckFailed", "CPUCreditBalance"})
        alarm = source.split("  ApplicationInstancesStatusAlarm:\n", 1)[1].split(
            "  BastionStatusAlarm:\n", 1
        )[0]
        self.assertIn("MAX([manager,web1,web2,backend1,backend2])", alarm)
        self.assertIn("Value: !Ref SwarmManagerInstanceId", alarm)
        self.assertNotIn("SwarmManagerAz2InstanceId", source)
        self.assertNotIn("manager2", alarm)
        main = (ROOT / "cloudformationCodeTracker.yaml").read_text(encoding="utf-8")
        outputs = main.split("\nOutputs:\n", 1)[1]
        self.assertIn("  SwarmManagerPrivateIp:", outputs)
        self.assertIn("Value: !GetAtt SwarmManagerInstance.PrivateIp", outputs)
        self.assertNotIn("SwarmManagerInstanceAz2", main)

    def test_shared_backends_are_monitored_once_without_rabbitmq_instance_ids(self):
        template = load_template("observabilidade-ti.yaml")
        self.assertNotIn("RabbitMqInstanceId", template["Parameters"])
        self.assertNotIn("RabbitMqInstanceAz2Id", template["Parameters"])
        body = template["Resources"]["OperationsDashboard"]["Properties"]["DashboardBody"]
        renderer = Renderer(template, BackendAz1InstanceId="i-backend1", BackendAz2InstanceId="i-backend2")
        dashboard = json.loads(renderer.render(body))
        ec2 = [metric for widget in dashboard["widgets"] for metric in widget["properties"].get("metrics", []) if metric[0] == "AWS/EC2"]
        for metric_name in ("CPUUtilization", "StatusCheckFailed", "CPUCreditBalance"):
            metrics = [metric for metric in ec2 if metric[1] == metric_name]
            ids = [metric[3] for metric in metrics]
            self.assertEqual(len(ids), 7)
            self.assertEqual(len(ids), len(set(ids)))
            self.assertIn("i-backend1", ids)
            self.assertIn("i-backend2", ids)
            for metric in metrics:
                if metric[3] in ("i-backend1", "i-backend2"):
                    self.assertIn("RabbitMQ", metric[-1]["label"])
        for name in ["RabbitMqStatusAlarm", "RabbitMqAz2StatusAlarm"]:
            self.assertNotIn(name, template["Resources"])

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
