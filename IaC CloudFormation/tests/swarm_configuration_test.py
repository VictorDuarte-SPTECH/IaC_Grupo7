"""Offline contracts for backend/RabbitMQ consolidation (requires PyYAML)."""

import collections
from pathlib import Path
import re
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]


class CloudFormationLoader(yaml.SafeLoader):
    pass


def intrinsic(loader, tag, node):
    if isinstance(node, yaml.ScalarNode):
        value = loader.construct_scalar(node)
    elif isinstance(node, yaml.SequenceNode):
        value = loader.construct_sequence(node)
    else:
        value = loader.construct_mapping(node)
    return {tag if tag in ("Ref", "Condition") else "Fn::" + tag: value}


CloudFormationLoader.add_multi_constructor("!", intrinsic)


def load_template(filename):
    return yaml.load((ROOT / filename).read_text(encoding="utf-8"), Loader=CloudFormationLoader)


class Renderer:
    """Evaluate only the intrinsic functions used by these offline contracts."""

    def __init__(self, template, **parameters):
        self.template = template
        self.parameters = {
            name: definition.get("Default", "test-" + name)
            for name, definition in template.get("Parameters", {}).items()
        }
        self.parameters.update({"AWS::Region": "us-east-1", "AWS::StackId": "test-stack"})
        self.parameters.update(parameters)

    def condition(self, name):
        return self.render(self.template["Conditions"][name])

    def render(self, value):
        if isinstance(value, list):
            return [self.render(item) for item in value]
        if not isinstance(value, dict):
            return value
        if len(value) != 1:
            return {key: self.render(item) for key, item in value.items()}
        key, argument = next(iter(value.items()))
        if key == "Ref":
            return self.parameters.get(argument, argument)
        if key == "Condition":
            return self.condition(argument)
        if key == "Fn::If":
            name, yes, no = argument
            return self.render(yes if self.condition(name) else no)
        if key == "Fn::Equals":
            left, right = self.render(argument)
            return left == right
        if key == "Fn::Not":
            return not self.render(argument[0])
        if key == "Fn::And":
            return all(self.render(item) for item in argument)
        if key == "Fn::Or":
            return any(self.render(item) for item in argument)
        if key == "Fn::GetAtt":
            resource, attribute = argument.split(".", 1) if isinstance(argument, str) else argument
            definition = self.template["Resources"][resource]
            if "Condition" in definition and not self.condition(definition["Condition"]):
                raise AssertionError("Reference to disabled resource: " + resource)
            if resource == "BackendInstanceAz2" and attribute == "PrivateIp":
                return "10.0.0.116"
            return resource.lower() + ".example" if attribute == "DNSName" else "10.0.0.100"
        if key == "Fn::FindInMap":
            mapping, first, second = self.render(argument)
            return self.template["Mappings"][mapping][first][second]
        if key == "Fn::Sub":
            source, variables = (argument, {}) if isinstance(argument, str) else argument

            def substitute(match):
                name = match.group(1)
                if name.startswith("!"):
                    return "${" + name[1:] + "}"
                if name in variables:
                    return str(self.render(variables[name]))
                return str(self.render({"Fn::GetAtt" if "." in name else "Ref": name}))

            return re.sub(r"\$\{([^}]+)\}", substitute, source)
        if key.startswith("Fn::"):
            raise AssertionError("Unsupported test intrinsic: " + key)
        return {key: self.render(argument)}


class SwarmConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.template = load_template("cloudformationCodeTracker.yaml")
        self.renderer = Renderer(self.template)

    def script(self, resource):
        return self.renderer.render(self.template["Resources"][resource]["Properties"]["UserData"]["Fn::Base64"])

    def test_eight_instances_with_two_medium_backends(self):
        instances = {
            name: resource for name, resource in self.template["Resources"].items()
            if resource["Type"] == "AWS::EC2::Instance"
        }
        self.assertEqual(len(instances), 8)
        self.assertEqual(self.template["Resources"]["BootstrapWaitCondition"]["Properties"]["Count"], 8)
        types = collections.Counter(self.renderer.render(instance["Properties"]["InstanceType"]) for instance in instances.values())
        self.assertEqual(types, {"t3.micro": 4, "t3.small": 2, "t3.medium": 2})
        for name in ("BackendInstanceAz1", "BackendInstanceAz2"):
            self.assertEqual(instances[name]["Properties"]["InstanceType"], {"Ref": "BackendInstanceType"})
        self.assertNotIn("RabbitMqInstance", self.template["Resources"])
        self.assertNotIn("RabbitMqInstanceAz2", self.template["Resources"])
        self.assertNotIn("EnableRabbitMq", self.template["Parameters"])

    def test_compose_uses_backend_brokers_and_keeps_replicas(self):
        script = self.script("SwarmManagerInstance")
        compose = yaml.safe_load(script.split("<<'STACK'\n", 1)[1].split("\nSTACK", 1)[0])
        services = compose["services"]
        self.assertEqual(services["backend"]["deploy"]["replicas"], 4)
        self.assertEqual(services["backend"]["deploy"]["placement"]["max_replicas_per_node"], 2)
        etiquetas = services["etiquetas"]["deploy"]
        self.assertEqual(etiquetas["replicas"], 2)
        self.assertEqual(etiquetas["placement"]["max_replicas_per_node"], 1)
        self.assertEqual(etiquetas["placement"]["constraints"], ["node.labels.tier == backend"])
        self.assertEqual(services["backend"]["environment"]["SPRING_RABBITMQ_ADDRESSES"], "10.0.0.100:5672,10.0.0.116:5672")
        self.assertIn("rabbitmq_password", compose["secrets"])
        self.assertIn("rabbitmq_password", {mount["source"] for mount in services["backend"]["secrets"]})
        workers = script.split("<<'NODES'\n", 1)[1].split("\nNODES", 1)[0].splitlines()
        self.assertEqual(len([line for line in workers if line.strip()]), 4)

    def test_only_backends_start_persistent_brokers_before_joining(self):
        for name, resource in self.template["Resources"].items():
            if resource["Type"] != "AWS::EC2::Instance":
                continue
            script = self.script(name)
            if name not in ("BackendInstanceAz1", "BackendInstanceAz2"):
                self.assertNotIn("BOOTSTRAP_STAGE=rabbitmq-start", script)
                continue
            with self.subTest(backend=name):
                self.assertLess(script.index("BOOTSTRAP_STAGE=rabbitmq-start"), script.index("BOOTSTRAP_STAGE=swarm-worker-join"))
                self.assertIn("docker volume create rabbitmq-data", script)
                self.assertIn("--volume rabbitmq-data:/var/lib/rabbitmq", script)
                self.assertIn("--restart unless-stopped", script)
                self.assertIn("--health-cmd 'rabbitmq-diagnostics -q ping'", script)
                self.assertIn("RabbitMQ no backend", script)
                health = script.index(".State.Health.Status")
                self.assertLess(health, script.index("BOOTSTRAP_STAGE=swarm-worker-join"))

    def test_broker_network_and_management_are_restricted(self):
        for name in ("BackendInstanceAz1", "BackendInstanceAz2"):
            interface = self.template["Resources"][name]["Properties"]["NetworkInterfaces"][0]
            self.assertIn({"Ref": "RabbitMqSecurityGroup"}, interface["GroupSet"])
            self.assertFalse(interface["AssociatePublicIpAddress"])
            script = self.script(name)
            self.assertIn("--publish 5672:5672", script)
            self.assertIn("--publish 127.0.0.1:15672:15672", script)
            self.assertNotIn("--publish 15672:15672", script)
        ingress = self.template["Resources"]["RabbitMqSecurityGroup"]["Properties"]["SecurityGroupIngress"]
        self.assertEqual(len(ingress), 1)
        self.assertEqual(ingress[0]["FromPort"], 5672)
        self.assertEqual(ingress[0]["SourceSecurityGroupId"], {"Ref": "BackendSecurityGroup"})

    def test_broker_outputs_use_backend_ips_without_conditions(self):
        for name, output in self.template["Outputs"].items():
            if name.startswith("RabbitMq"):
                with self.subTest(output=name):
                    self.assertNotIn("Condition", output)
                    self.assertNotIn("RabbitMqInstance", str(output))
        self.assertEqual(self.template["Outputs"]["RabbitMqPrivateIp"]["Value"], {"Fn::GetAtt": "BackendInstanceAz1.PrivateIp"})
        self.assertEqual(self.template["Outputs"]["RabbitMqAz2PrivateIp"]["Value"], {"Fn::GetAtt": "BackendInstanceAz2.PrivateIp"})
        self.assertEqual(self.renderer.render(self.template["Outputs"]["RabbitMqAddresses"]["Value"]), "10.0.0.100:5672,10.0.0.116:5672")

    def test_broker_password_is_required(self):
        password = self.template["Parameters"]["RabbitMqPassword"]
        self.assertNotIn("Default", password)
        self.assertEqual(password["MinLength"], 12)
        self.assertTrue(password["NoEcho"])

    def test_broker_memory_limit_leaves_headroom_on_medium(self):
        for name in ("BackendInstanceAz1", "BackendInstanceAz2"):
            script = self.script(name)
            self.assertIn("--memory 1g", script)
            self.assertIn("vm_memory_high_watermark {absolute,536870912}", script)
        script = self.script("SwarmManagerInstance")
        services = yaml.safe_load(script.split("<<'STACK'\n", 1)[1].split("\nSTACK", 1)[0])["services"]
        backend = services["backend"]["deploy"]
        etiquetas = services["etiquetas"]["deploy"]
        backend_mib = int(backend["resources"]["limits"]["memory"].removesuffix("M"))
        etiquetas_mib = int(etiquetas["resources"]["limits"]["memory"].removesuffix("M"))
        total_mib = backend["placement"]["max_replicas_per_node"] * backend_mib + etiquetas_mib + 1024
        self.assertLess(total_mib, 4096)


if __name__ == "__main__":
    unittest.main()


