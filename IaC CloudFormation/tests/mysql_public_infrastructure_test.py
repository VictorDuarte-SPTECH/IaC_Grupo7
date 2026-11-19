"""Offline checks for the standalone MySQL test stack."""

import base64
import json
import os
import subprocess
import unittest

from swarm_configuration_test import load_template, Renderer


class PublicMysqlInfrastructureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.template = load_template("cloudformation-mysql-publico.yaml")
        cls.resources = cls.template["Resources"]
        encoded = Renderer(cls.template).render(
            cls.resources["DatabaseInstance"]["Properties"]["UserData"])
        cls.script = base64.b64decode(encoded).decode("utf-8")
        cls.bash = (["wsl", "-d", "Ubuntu", "--exec", "bash"] if os.name == "nt"
                    else ["bash"])

    def test_public_tcp_load_balancer_routes_to_single_database(self):
        resources = self.resources
        self.assertEqual(sum(r["Type"] == "AWS::EC2::Instance" for r in resources.values()), 1)
        balancer = resources["NetworkLoadBalancer"]["Properties"]
        self.assertEqual((balancer["Type"], balancer["Scheme"]), ("network", "internet-facing"))
        self.assertEqual(balancer["Subnets"], [{"Ref": "PublicSubnetAz1"}, {"Ref": "PublicSubnetAz2"}])
        self.assertIn({"Key": "load_balancing.cross_zone.enabled", "Value": "true"},
                      balancer["LoadBalancerAttributes"])
        target = resources["MysqlTargetGroup"]["Properties"]
        self.assertEqual((target["Protocol"], target["Port"], target["HealthCheckProtocol"]),
                         ("TCP", 3306, "TCP"))
        self.assertEqual(target["Targets"], [{"Id": {"Ref": "DatabaseInstance"}, "Port": 3306}])
        listener = resources["MysqlListener"]["Properties"]
        self.assertEqual((listener["Protocol"], listener["Port"]), ("TCP", 3306))
        self.assertEqual(listener["DefaultActions"][0]["TargetGroupArn"], {"Ref": "MysqlTargetGroup"})
        for group, ports in (("DatabaseSecurityGroup", {22, 3306}),
                             ("LoadBalancerSecurityGroup", {3306})):
            rules = resources[group]["Properties"]["SecurityGroupIngress"]
            self.assertEqual({rule["FromPort"] for rule in rules if
                              rule["IpProtocol"] == "tcp" and
                              rule["CidrIp"] == "0.0.0.0/0" and
                              rule["FromPort"] == rule["ToPort"]}, ports)

    def test_bootstrap_syntax_and_failure_signal(self):
        syntax = subprocess.run(self.bash + ["-n"], input=self.script.encode("utf-8"),
                                capture_output=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr.decode("utf-8"))
        start = self.script.index("stage=initialization")
        end = self.script.index("exec > >(tee")
        traps = self.script[start:end]
        for command, exit_code in (("false", 1), ("true", 0)):
            script = ("set -Eeuo pipefail\ncurl() { printf '%s\\n' \"$@\"; }\n" + traps
                      + "stage=import-database\n" + command + "\n")
            run = subprocess.run(self.bash + ["-s"], input=script.encode("utf-8"),
                                 capture_output=True)
            self.assertEqual(run.returncode, exit_code, run.stderr.decode("utf-8"))
            signal = next(json.loads(line) for line in run.stdout.decode("utf-8").splitlines()
                          if line.startswith('{"Status":'))
            self.assertEqual(signal["Status"], "FAILURE" if exit_code else "SUCCESS")
            if exit_code:
                self.assertIn("etapa=import-database", signal["Reason"])
                self.assertIn("codigo=1", signal["Reason"])
                self.assertRegex(signal["Reason"], r"linha=\d+")
            self.assertNotIn("test-DatabasePassword", json.dumps(signal))

    def test_import_and_remote_mysql_user_are_configured(self):
        self.assertIn("SCRIPT-Lamar-AutoPecas.sql", self.script)
        self.assertIn("bind-address = 0.0.0.0", self.script)
        self.assertIn("CREATE USER IF NOT EXISTS 'lamar'@'%'", self.script)
        self.assertIn("GRANT ALL PRIVILEGES ON `lamar`.* TO 'lamar'@'%'", self.script)
        self.assertIn("WHERE email = 'admin@teste.com' AND ativo = 1", self.script)
        self.assertEqual(self.resources["BootstrapWaitCondition"]["Properties"]["Count"], 1)


if __name__ == "__main__":
    unittest.main()
