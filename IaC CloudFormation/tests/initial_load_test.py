import io
import hashlib
import json
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import Mock, patch

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
RESOURCES = DOCUMENT["Resources"]
CODE = RESOURCES["DataBootstrapFunction"]["Properties"]["Code"]["ZipFile"]
WORKFLOW = RESOURCES["InitialLoadWorkflow"]["Properties"]["Definition"]


class InitialLoadTests(unittest.TestCase):
    def setUp(self):
        self.workflows = Mock()
        self.s3 = Mock()
        self.workflows.start_execution.return_value = {"executionArn": "arn:execution:test"}
        boto3 = types.ModuleType("boto3")
        boto3.client = Mock(side_effect=lambda service: self.workflows if service == "stepfunctions" else self.s3)
        self.namespace = {}
        with patch.dict(sys.modules, {"boto3": boto3}):
            exec(compile(CODE, "<bootstrap_lambda>", "exec"), self.namespace)
        self.event = {
            "RequestType": "Create", "ResponseURL": "https://example.invalid/callback",
            "StackId": "test-stack", "RequestId": "request-1", "LogicalResourceId": "InitialDataLoad",
            "ResourceProperties": {"WorkflowArn": "arn:stateMachine:test"},
        }
        self.handler = self.namespace["lambda_handler"]

    def callback(self, status, data=None):
        event = {"mode": "callback", "request": self.event, "status": status, "data": data or {}}
        with patch("urllib.request.urlopen", return_value=io.BytesIO()) as request:
            self.handler(event, Mock())
        return json.loads(request.call_args.args[0].data)

    def test_create_starts_workflow_without_premature_success(self):
        with patch("urllib.request.urlopen") as callback:
            result = self.handler(self.event, Mock())
        self.assertEqual(result, {"executionArn": "arn:execution:test"})
        callback.assert_not_called()
        call = self.workflows.start_execution.call_args.kwargs
        self.assertEqual(call["name"], self.event["RequestId"])
        self.assertNotIn("ResourceProperties", json.loads(call["input"])["request"])

    def test_update_preserves_physical_resource_id(self):
        self.event.update(RequestType="Update", PhysicalResourceId="existing-resource")
        self.handler(self.event, Mock())
        request = json.loads(self.workflows.start_execution.call_args.kwargs["input"])["request"]
        self.assertEqual(request["PhysicalResourceId"], "existing-resource")
        self.event["PhysicalResourceId"] = request["PhysicalResourceId"]
        self.assertEqual(self.callback("SUCCESS")["PhysicalResourceId"], "existing-resource")

    def test_delete_responds_without_loading_or_deleting_data(self):
        self.event["RequestType"] = "Delete"
        with patch("urllib.request.urlopen", return_value=io.BytesIO()) as request:
            self.handler(self.event, Mock())
        self.assertEqual(json.loads(request.call_args.args[0].data)["Status"], "SUCCESS")
        self.workflows.start_execution.assert_not_called()
        self.s3.put_object.assert_not_called()

    def test_script_is_published_before_glue_creation_without_external_upload(self):
        script = DOCUMENT["Mappings"]["GlueScript"]["Silver"]["Code"]
        self.event["LogicalResourceId"] = "PublishGlueScript"
        self.event["ResourceProperties"] = {
            "Action": "publish_script", "Bucket": "new-stack-artifacts", "ScriptSource": script,
        }
        with patch("urllib.request.urlopen", return_value=io.BytesIO()) as request:
            self.handler(self.event, Mock())
        raw = script.encode("utf-8")
        digest = hashlib.sha256(raw).hexdigest()
        upload = self.s3.put_object.call_args.kwargs
        self.assertEqual(upload["Bucket"], "new-stack-artifacts")
        self.assertEqual(upload["Body"], raw)
        self.assertEqual(upload["Key"], "glue/bronze_to_silver-" + digest + ".py")
        response = json.loads(request.call_args.args[0].data)
        self.assertEqual(response["Status"], "SUCCESS")
        self.assertEqual(response["Data"]["ScriptS3Uri"], "s3://new-stack-artifacts/" + upload["Key"])
        self.workflows.start_execution.assert_not_called()

    def test_script_upload_failure_fails_cloudformation_without_starting_load(self):
        self.event["ResourceProperties"] = {
            "Action": "publish_script", "Bucket": "new-stack-artifacts", "ScriptSource": "print('test')\n",
        }
        self.s3.put_object.side_effect = RuntimeError("AccessDenied")
        with patch("urllib.request.urlopen", return_value=io.BytesIO()) as request:
            with self.assertRaisesRegex(RuntimeError, "AccessDenied"):
                self.handler(self.event, Mock())
        self.assertEqual(json.loads(request.call_args.args[0].data)["Status"], "FAILED")
        self.workflows.start_execution.assert_not_called()

    def test_each_stack_creates_unique_buckets_and_publishes_its_own_script(self):
        for name in ("BronzeBucket", "SilverBucket", "GoldBucket", "ArtifactsBucket"):
            resource = RESOURCES[name]
            self.assertEqual(resource["Type"], "AWS::S3::Bucket")
            self.assertNotIn("BucketName", resource["Properties"])
            self.assertNotIn("Condition", resource)
            self.assertEqual(resource["DeletionPolicy"], "Retain")
            self.assertEqual(resource["UpdateReplacePolicy"], "Retain")
            self.assertTrue(all(resource["Properties"]["PublicAccessBlockConfiguration"].values()))
        for name in ("ExistingBronzeBucketName", "ExistingSilverBucketName", "GlueScriptS3Uri"):
            self.assertNotIn(name, DOCUMENT["Parameters"])
        self.assertEqual(
            RESOURCES["BronzeToSilverJob"]["Properties"]["Command"]["ScriptLocation"],
            "PublishGlueScript.ScriptS3Uri",
        )
        self.assertEqual(
            RESOURCES["PublishGlueScript"]["Properties"]["ScriptSource"], ["GlueScript", "Silver", "Code"]
        )
        self.assertLessEqual(TEMPLATE.stat().st_size, 51200)

    def test_gold_bucket_is_exposed_but_not_used_by_the_pipeline(self):
        self.assertEqual(DOCUMENT["Outputs"]["GoldBucketName"]["Value"], "GoldBucket")
        for name, resource in RESOURCES.items():
            if name != "GoldBucket":
                self.assertNotIn("GoldBucket", json.dumps(resource))

    def test_start_failure_notifies_cloudformation_and_raises(self):
        self.workflows.start_execution.side_effect = RuntimeError("AccessDenied")
        with patch("urllib.request.urlopen", return_value=io.BytesIO()) as request:
            with self.assertRaisesRegex(RuntimeError, "AccessDenied"):
                self.handler(self.event, Mock())
        self.assertEqual(json.loads(request.call_args.args[0].data)["Status"], "FAILED")

    def test_callback_protocol_and_output(self):
        response = self.callback("SUCCESS", {"GlueJobRunId": "jr_test"})
        self.assertEqual(response["Status"], "SUCCESS")
        self.assertEqual(response["Data"]["GlueJobRunId"], "jr_test")
        for field in ("StackId", "RequestId", "LogicalResourceId"):
            self.assertEqual(response[field], self.event[field])
        self.assertNotIn("ResponseURL", response)
        self.assertEqual(self.callback("FAILED")["Status"], "FAILED")

    @staticmethod
    def resolve(parameters, state):
        def get_path(path):
            if path == "$$.Execution.Id":
                return "arn:execution:test"
            value = state
            for part in path[2:].split("."):
                value = value[part]
            return value
        result = {}
        for key, value in parameters.items():
            if key.endswith(".$"):
                result[key[:-2]] = get_path(value)
            elif isinstance(value, dict):
                result[key] = InitialLoadTests.resolve(value, state)
            else:
                result[key] = value
        return result

    def run_workflow(self, failing_task=None):
        current = WORKFLOW["StartAt"]
        state, order, responses = {"request": self.event}, [], []
        while True:
            task = WORKFLOW["States"][current]
            if task["Type"] == "Fail":
                return order, responses
            params = self.resolve(task["Parameters"], state)
            order.append(current)
            if current == failing_task:
                handler = task["Catch"][0]
                state[handler["ResultPath"][2:]] = {"Error": "SourceOrJobFailed"}
                current = handler["Next"]
                continue
            if current.startswith("Collect"):
                result = {"manifest": params["source"] + "/manifest.json"}
            elif current == "ProcessSilver":
                self.assertEqual(params["Arguments"]["--IPEADATA_MANIFEST"], "ipeadata/manifest.json")
                self.assertEqual(params["Arguments"]["--COMEXSTAT_MANIFEST"], "comexstat/manifest.json")
                self.assertEqual(order[:2], ["CollectIpeadata", "CollectComexStat"])
                result = {"JobRunId": "jr_complete"}
            else:
                with patch("urllib.request.urlopen", return_value=io.BytesIO()) as request:
                    self.handler(params, Mock())
                responses.append(json.loads(request.call_args.args[0].data))
                result = {}
            if task.get("ResultPath"):
                state[task["ResultPath"][2:]] = result
            if task.get("End"):
                return order, responses
            current = task["Next"]

    def test_workflow_waits_for_both_sources_and_silver_before_success(self):
        order, responses = self.run_workflow()
        self.assertEqual(order, ["CollectIpeadata", "CollectComexStat", "ProcessSilver", "ReportSuccess"])
        self.assertEqual(responses[0]["Status"], "SUCCESS")
        self.assertEqual(responses[0]["Data"]["GlueJobRunId"], "jr_complete")
        self.assertEqual(responses[0]["Data"]["WorkflowExecutionArn"], "arn:execution:test")
        self.assertTrue(WORKFLOW["States"]["ProcessSilver"]["Resource"].endswith("glue:startJobRun.sync"))

    def test_any_source_or_glue_failure_blocks_stack_success(self):
        for task in ("CollectIpeadata", "CollectComexStat", "ProcessSilver"):
            with self.subTest(task=task):
                order, responses = self.run_workflow(task)
                self.assertNotIn("ReportSuccess", order)
                self.assertEqual([response["Status"] for response in responses], ["FAILED"])
                self.assertIn("arn:execution:test", responses[0]["Reason"])

    def test_callback_failure_is_not_success(self):
        import urllib.error
        with patch("urllib.request.urlopen", side_effect=urllib.error.URLError("offline")):
            with self.assertRaisesRegex(RuntimeError, "Falha ao enviar resposta"):
                self.handler({"mode": "callback", "status": "SUCCESS", "request": self.event}, Mock())
        order, responses = self.run_workflow("ReportSuccess")
        self.assertIn("ReportFailure", order)
        self.assertEqual([response["Status"] for response in responses], ["FAILED"])

    def test_async_workflow_fits_cloudformation_timeout(self):
        gate = RESOURCES["InitialDataLoad"]
        self.assertEqual(gate["Type"], "AWS::CloudFormation::CustomResource")
        self.assertGreater(gate["Properties"]["ServiceTimeout"], WORKFLOW["TimeoutSeconds"])
        self.assertIn("BronzeToSilverJob", gate["DependsOn"])
        self.assertIn("BronzeIngestionFunction", gate["DependsOn"])
        self.assertEqual(RESOURCES["InitialLoadWorkflow"]["Properties"]["StateMachineType"], "STANDARD")
        tasks = WORKFLOW["States"]
        expected_maximum = sum(tasks[name]["TimeoutSeconds"]
                               for name in ("CollectIpeadata", "CollectComexStat", "ProcessSilver"))
        for name in ("ReportSuccess", "ReportFailure"):
            retry = tasks[name]["Retry"][0]
            expected_maximum += tasks[name]["TimeoutSeconds"] * (retry["MaxAttempts"] + 1)
            expected_maximum += retry["IntervalSeconds"] * (1 + retry["BackoffRate"])
        self.assertGreater(WORKFLOW["TimeoutSeconds"], expected_maximum)

    def test_template_has_no_null_values_rejected_by_cloudformation(self):
        def check(value, path):
            self.assertIsNotNone(value, "CloudFormation rejeita null em " + path)
            if isinstance(value, dict):
                for key, child in value.items():
                    check(child, path + "/" + str(key))
            elif isinstance(value, list):
                for index, child in enumerate(value):
                    check(child, path + "/" + str(index))
        check(DOCUMENT, "")
        for name in ("ReportSuccess", "ReportFailure"):
            self.assertEqual(WORKFLOW["States"][name]["ResultPath"], "$.callback")


if __name__ == "__main__":
    unittest.main()
