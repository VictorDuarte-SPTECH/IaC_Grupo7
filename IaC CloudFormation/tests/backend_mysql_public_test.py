"""Offline checks for the single-instance backend and MySQL stack."""

import base64
import json
import os
import subprocess
import unittest

from swarm_configuration_test import load_template, Renderer


class BackendMysqlPublicTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.template = load_template("cloudformation-backend-mysql-publico.yaml")
        cls.resources = cls.template["Resources"]
        encoded = Renderer(cls.template).render(
            cls.resources["ApplicationInstance"]["Properties"]["UserData"])
        cls.script = base64.b64decode(encoded).decode("utf-8")
        cls.bash = (["wsl", "-d", "Ubuntu", "--exec", "bash"] if os.name == "nt"
                    else ["bash"])

    def test_public_nlb_routes_both_ports_to_same_instance(self):
        resources = self.resources
        self.assertEqual(sum(r["Type"] == "AWS::EC2::Instance" for r in resources.values()), 1)
        nlb = resources["NetworkLoadBalancer"]["Properties"]
        self.assertEqual((nlb["Type"], nlb["Scheme"]), ("network", "internet-facing"))
        self.assertEqual(len(nlb["Subnets"]), 2)
        self.assertIn({"Key": "load_balancing.cross_zone.enabled", "Value": "true"},
                      nlb["LoadBalancerAttributes"])
        for name, port in (("Backend", 8080), ("Mysql", 3306)):
            listener = resources[name + "Listener"]["Properties"]
            target = resources[name + "TargetGroup"]["Properties"]
            self.assertEqual((listener["Protocol"], listener["Port"]), ("TCP", port))
            self.assertEqual(listener["DefaultActions"][0]["TargetGroupArn"],
                             {"Ref": name + "TargetGroup"})
            self.assertEqual((target["Protocol"], target["Port"], target["HealthCheckProtocol"]),
                             ("TCP", port, "TCP"))
            self.assertEqual(target["Targets"], [{"Id": {"Ref": "ApplicationInstance"}, "Port": port}])
        for group, ports in (("InstanceSecurityGroup", {22, 3306, 8080}),
                             ("LoadBalancerSecurityGroup", {3306, 8080})):
            rules = resources[group]["Properties"]["SecurityGroupIngress"]
            self.assertEqual({rule["FromPort"] for rule in rules if
                              rule["IpProtocol"] == "tcp" and
                              rule["CidrIp"] == "0.0.0.0/0" and
                              rule["FromPort"] == rule["ToPort"]}, ports)

    def test_backend_uses_local_mysql_and_no_rabbitmq(self):
        self.assertIn("SCRIPT-Lamar-AutoPecas.sql", self.script)
        self.assertIn("CREATE USER IF NOT EXISTS 'lamar'@'%'", self.script)
        self.assertIn("GRANT ALL PRIVILEGES ON `lamar`.* TO 'lamar'@'%'", self.script)
        self.assertIn("--network host", self.script)
        self.assertIn("--env DB_HOST=127.0.0.1", self.script)
        self.assertIn("target=/run/secrets,readonly", self.script)
        self.assertIn("--env SPRING_CONFIG_IMPORT=configtree:/run/secrets/", self.script)
        self.assertIn("http://127.0.0.1:8080/v3/api-docs", self.script)
        self.assertNotIn("rabbitmq:", self.script.lower())
        self.assertEqual(self.resources["BootstrapWaitCondition"]["Properties"]["Count"], 1)

    def test_bootstrap_syntax_and_signaling(self):
        syntax = subprocess.run(self.bash + ["-n"], input=self.script.encode("utf-8"),
                                capture_output=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr.decode("utf-8"))
        traps = self.script[self.script.index("stage=initialization"):
                            self.script.index("exec > >(tee")]
        for command, exit_code in (("false", 1), ("true", 0)):
            script = ("set -Eeuo pipefail\ncurl() { printf '%s\\n' \"$@\"; }\n" + traps
                      + "stage=check-backend\n" + command + "\n")
            run = subprocess.run(self.bash + ["-s"], input=script.encode("utf-8"),
                                 capture_output=True)
            self.assertEqual(run.returncode, exit_code, run.stderr.decode("utf-8"))
            signal = next(json.loads(line) for line in run.stdout.decode("utf-8").splitlines()
                          if line.startswith('{"Status":'))
            self.assertEqual(signal["Status"], "FAILURE" if exit_code else "SUCCESS")
            if exit_code:
                self.assertIn("etapa=check-backend", signal["Reason"])
                self.assertRegex(signal["Reason"], r"linha=\d+")
            self.assertNotIn("test-DatabasePassword", json.dumps(signal))
            self.assertNotIn("test-JwtSecret", json.dumps(signal))

    def test_smtp_configuration_is_passed_without_interpreting_password(self):
        password = "smtp ' $(must-not-execute)"
        encoded = Renderer(self.template, MailUsername="test@example.com",
                           MailPassword=password).render(
            self.resources["ApplicationInstance"]["Properties"]["UserData"])
        script = base64.b64decode(encoded).decode("utf-8")
        self.assertIn("--env MAIL_USERNAME='test@example.com'", script)
        self.assertIn(base64.b64encode(password.encode()).decode(), script)
        self.assertNotIn(password, script)
        self.assertIn("base64 --decode > /opt/codetracker/secrets/MAIL_PASSWORD", script)
        self.assertIn("target=/run/secrets,readonly", script)
        syntax = subprocess.run(self.bash + ["-n"], input=script.encode(),
                                capture_output=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr.decode())


if __name__ == "__main__":
    unittest.main()
