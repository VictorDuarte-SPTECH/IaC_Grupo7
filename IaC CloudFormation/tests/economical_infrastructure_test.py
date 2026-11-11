"""Offline contracts for the single-host stack and scheduled cost comparison."""

import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch, Mock

import yaml

from swarm_configuration_test import load_template, Renderer


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("cost_estimator", ROOT / "estimar-custos.py")
COSTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COSTS)


class EconomicalInfrastructureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.template = load_template("cloudformationCodeTracker-economica.yaml")
        encoded = Renderer(cls.template, MailPassword="pass ' $(not-a-command)").render(
            cls.template["Resources"]["ApplicationInstance"]["Properties"]["UserData"])
        import base64
        cls.script = base64.b64decode(encoded).decode()
        cls.compose = yaml.safe_load(
            re.search(r"cat > compose.yaml <<'COMPOSE'\n(.*?)\nCOMPOSE", cls.script, re.S)[1])

    def test_one_host_and_no_high_availability_resources(self):
        kinds = [resource["Type"] for resource in self.template["Resources"].values()]
        self.assertEqual(kinds.count("AWS::EC2::Instance"), 1)
        self.assertEqual(kinds.count("AWS::EC2::Subnet"), 1)
        for kind in ("AWS::EC2::NatGateway", "AWS::EC2::EIP",
                     "AWS::ElasticLoadBalancingV2::LoadBalancer", "AWS::Route53::HostedZone"):
            self.assertNotIn(kind, kinds)
        props = self.template["Resources"]["ApplicationInstance"]["Properties"]
        self.assertEqual(props["CreditSpecification"]["CPUCredits"], "standard")
        self.assertTrue(props["NetworkInterfaces"][0]["AssociatePublicIpAddress"])
        self.assertEqual(props["BlockDeviceMappings"][0]["Ebs"]["VolumeSize"], 20)
        self.assertNotIn("CreationPolicy", self.template["Resources"]["ApplicationInstance"])

    def test_all_services_persist_and_only_frontend_is_public(self):
        services = self.compose["services"]
        self.assertEqual(set(services), {"mysql", "rabbitmq", "backend", "etiquetas", "frontend"})
        for name, service in services.items():
            self.assertEqual(service["restart"], "unless-stopped")
            if name != "frontend":
                self.assertNotIn("ports", service)
        self.assertEqual(services["frontend"]["ports"], ["80:80"])
        self.assertIn("mysql_data:/var/lib/mysql", services["mysql"]["volumes"])
        self.assertEqual(services["rabbitmq"]["hostname"], "rabbitmq")
        self.assertIn("rabbitmq_data:/var/lib/rabbitmq", services["rabbitmq"]["volumes"])
        self.assertEqual(services["backend"]["depends_on"]["mysql"]["condition"], "service_healthy")
        self.assertIn("DB_PASSWORD", services["backend"]["secrets"])
        self.assertIn("spring.rabbitmq.password", services["etiquetas"]["secrets"])
        self.assertIn("base64 --decode", self.script)
        self.assertNotIn("pass ' $(not-a-command)", self.script)
        self.assertIn("UPDATE usuario SET senha", self.script)
        self.assertIn("chmod 0755 init", self.script)
        self.assertIn("chmod 0444 secrets/DB_PASSWORD", self.script)
        self.assertIn("swapon /swapfile", self.script)

    def test_bootstrap_bash_syntax(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / "bootstrap.sh"
            path.write_text(self.script, encoding="utf-8", newline="\n")
            compose_path = path.with_name("compose.yaml")
            compose_path.write_text(yaml.safe_dump(self.compose), encoding="utf-8")
            # Use WSL when tests run on Windows; no bootstrap commands are executed.
            if os.name == "nt":
                linux_path = subprocess.run(["wsl", "-d", "Ubuntu", "--exec", "wslpath", "-u", str(path)],
                                            check=True, capture_output=True, text=True).stdout.strip()
                command = ["wsl", "-d", "Ubuntu", "--exec", "bash", "-n", linux_path]
                compose_command = ["wsl", "-d", "Ubuntu", "--exec", "docker", "compose", "-f",
                                   str(Path(linux_path).parent / "compose.yaml").replace("\\", "/"),
                                   "config", "--format", "json"]
            else:
                command = ["bash", "-n", str(path)]
                compose_command = ["docker", "compose", "-f", str(compose_path),
                                   "config", "--format", "json"]
            syntax = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(syntax.returncode, 0, syntax.stderr)
            rendered = subprocess.run(compose_command, capture_output=True, text=True)
            self.assertEqual(rendered.returncode, 0, rendered.stderr)
            services = json.loads(rendered.stdout)["services"]
            self.assertIn("$(cat /run/secrets/spring.rabbitmq.password)",
                          services["rabbitmq"]["command"][0])

    def test_daily_schedule_matches_brasilia(self):
        resources = self.template["Resources"]
        self.assertEqual(resources["StartRule"]["Properties"]["ScheduleExpression"], "cron(0 9 * * ? *)")
        self.assertEqual(resources["StopRule"]["Properties"]["ScheduleExpression"], "cron(0 1 * * ? *)")
        self.assertEqual(self.template["Parameters"]["ScheduleState"]["Default"], "ENABLED")
        for rule, action in (("StartRule", "start"), ("StopRule", "stop")):
            target = resources[rule]["Properties"]["Targets"][0]
            self.assertEqual(json.loads(target["Input"]), {"action": action})
            permission = resources[rule.replace("Rule", "Permission")]["Properties"]
            self.assertEqual(permission["SourceArn"], {"Fn::GetAtt": rule + ".Arn"})

    def test_scheduler_uses_exact_instance_and_surfaces_errors(self):
        code = self.template["Resources"]["ScheduleFunction"]["Properties"]["Code"]["ZipFile"]
        ec2 = Mock()
        boto3 = types.SimpleNamespace(client=Mock(return_value=ec2))
        namespace = {}
        with patch.dict(sys.modules, {"boto3": boto3}), patch.dict(os.environ, {"INSTANCE_ID": "i-test"}):
            exec(compile(code, "<schedule>", "exec"), namespace)
            namespace["handler"]({"action": "start"}, None)
            namespace["handler"]({"action": "stop"}, None)
            ec2.start_instances.assert_called_once_with(InstanceIds=["i-test"])
            ec2.stop_instances.assert_called_once_with(InstanceIds=["i-test"])
            with self.assertRaises(ValueError):
                namespace["handler"]({"action": "delete"}, None)
            ec2.start_instances.side_effect = RuntimeError("AccessDenied")
            with self.assertRaisesRegex(RuntimeError, "AccessDenied"):
                namespace["handler"]({"action": "start"}, None)


class ScheduledCostTests(unittest.TestCase):
    def scenario(self, name, days=30):
        raw = json.loads((ROOT / "custos-economica" / (name + "-c3x.json")).read_text(encoding="utf-8"))
        filename = "cloudformationCodeTracker" + ("-economica" if name == "economica" else "") + ".yaml"
        template = COSTS.load_template(ROOT / filename)
        return COSTS.scheduled_costs(raw, template, days, 8, COSTS.D("0.08"), COSTS.D("0.005"))

    def test_current_fixed_services_are_not_discounted_to_16_hours(self):
        result = self.scenario("atual")
        for row in result["rows"]:
            if row["dimension"] == "compute_hours":
                self.assertEqual(COSTS.D(row["quantity"]), 480)
            elif row["dimension"] in ("gateway_hours", "lb_hours", "ip_hours"):
                self.assertEqual(COSTS.D(row["quantity"]), 720)
        roots = [r for r in result["rows"] if r["dimension"] == "assumed_root_gp3_gb"]
        self.assertEqual(len(roots), 8)
        self.assertEqual(COSTS.D(result["groups"]["Route53"]), COSTS.D("0.50"))
        self.assertEqual(COSTS.D(result["groups"]["IPv4"]), 18)
        self.assertEqual(COSTS.D(result["groups"]["EBS"]), COSTS.D("8.32"))

    def test_economical_storage_full_month_and_ip_only_while_running(self):
        result = self.scenario("economica")
        root = next(r for r in result["rows"] if r["dimension"] == "root_volume")
        self.assertEqual(root["group"], "EBS")
        self.assertEqual(COSTS.D(root["quantity"]), 20)
        self.assertEqual(COSTS.D(result["groups"]["IPv4"]), COSTS.D("2.4"))
        self.assertLess(COSTS.D(result["groups"]["Lambda"]), COSTS.D("0.01"))
        for days in (28, 29, 30, 31):
            scenario = self.scenario("economica", days)
            self.assertEqual(scenario["groups"]["EBS"], result["groups"]["EBS"])
            compute = next(r for r in scenario["rows"] if r["dimension"] == "compute_hours")
            self.assertEqual(COSTS.D(compute["quantity"]), days * 16)

    def test_totals_use_unrounded_line_items(self):
        for name in ("atual", "economica"):
            result = self.scenario(name)
            self.assertEqual(COSTS.D(result["total"]),
                             sum(COSTS.D(row["cost"]) for row in result["rows"]))

    def test_missing_prices_are_not_treated_as_free(self):
        with self.assertRaisesRegex(ValueError, "Tarifa ausente"):
            COSTS.one_rate({"costs": []}, "aws_ebs_volume", "storage")


if __name__ == "__main__":
    unittest.main()
