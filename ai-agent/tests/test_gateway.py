import importlib.util
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import httpx2 as httpx

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import govhub

spec = importlib.util.spec_from_file_location("patcher", ROOT / "Patch-AiAgent.py")
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)


def settings(**overrides):
    values = {
        "model": "gpt-6-astra",
        "gateway_endpoint": "https://apim-jmj2kuossnei2.azure-api.net/openai/",
        "gateway_api_version": "2025-04-01-preview",
        "gateway_secret_uri": "https://kv-agent-9fd780c4-ita.vault.azure.net/secrets/govhub-agent-api-key",
        "gateway_private_prefix": "10.170.0.0/24",
        "vault_uri": "https://kv-agent-9fd780c4-ita.vault.azure.net/",
        "project_endpoint": "https://own-project.services.ai.azure.com/api/projects/agent",
    }
    return SimpleNamespace(**(values | overrides))


@patch.object(govhub.socket, "getaddrinfo", return_value=[(2, 1, 6, "", ("10.170.0.82", 443))])
class GatewayTests(unittest.IsolatedAsyncioTestCase):
    async def test_real_sdk_sends_responses_to_product_gateway_without_bearer(self, _dns):
        captured = []

        async def send(_client, request, **kwargs):
            captured.append(request)
            return httpx.Response(200, request=request, json={
                "id": "resp_test", "object": "response", "created_at": 1,
                "model": "gpt-6-astra", "status": "completed",
                "output": [{
                    "id": "msg_test", "type": "message", "role": "assistant",
                    "status": "completed",
                    "content": [{"type": "output_text", "text": "OK", "annotations": []}],
                }],
                "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2},
            })

        configured = settings()
        with patch.object(govhub, "SecretClient") as vault, patch.object(
            httpx.AsyncClient, "send", autospec=True, side_effect=send,
        ):
            vault.return_value.__enter__.return_value.get_secret.return_value.value = "synthetic-test-key"
            client = govhub.create_model_client(configured, object())
            try:
                response = await client.get_response("Hi")
            finally:
                await client.client.close()
        self.assertEqual(len(captured), 1)
        self.assertEqual(
            str(captured[0].url),
            "https://apim-jmj2kuossnei2.azure-api.net/openai/responses?api-version=2025-04-01-preview",
        )
        self.assertEqual(captured[0].headers["api-key"], "synthetic-test-key")
        self.assertNotIn("authorization", captured[0].headers)
        self.assertEqual(json.loads(captured[0].content)["model"], "gpt-6-astra")
        self.assertEqual(response.text, "OK")
        self.assertEqual(configured.project_endpoint, "https://own-project.services.ai.azure.com/api/projects/agent")

    def test_missing_gateway_never_reads_a_secret_or_falls_back(self, _dns):
        for overrides in (
            {"gateway_endpoint": ""}, {"gateway_api_version": ""},
            {"gateway_secret_uri": ""}, {"vault_uri": ""},
            {"gateway_endpoint": "https://own-project.services.ai.azure.com/openai/"},
        ):
            with self.subTest(overrides=overrides), patch.object(govhub, "SecretClient") as vault:
                with self.assertRaises(ValueError):
                    govhub.create_model_client(settings(**overrides), object())
                vault.assert_not_called()

    def test_rejects_external_or_credential_bearing_secret_references(self, _dns):
        for reference in (
            "https://other.vault.azure.net/secrets/key",
            "https://kv-agent-9fd780c4-ita.vault.azure.net.evil.example/secrets/key",
            "https://user:password@kv-agent-9fd780c4-ita.vault.azure.net/secrets/key",
            "https://kv-agent-9fd780c4-ita.vault.azure.net/secrets/key?sig=wrong",
            "https://kv-agent-9fd780c4-ita.vault.azure.net/secrets/key#wrong",
            "http://kv-agent-9fd780c4-ita.vault.azure.net/secrets/key",
        ):
            with self.subTest(reference=reference):
                with self.assertRaises(ValueError):
                    govhub.secret_coordinates(settings(gateway_secret_uri=reference))

    def test_empty_vault_secret_has_no_inference_fallback(self, _dns):
        with patch.object(govhub, "SecretClient") as vault:
            vault.return_value.__enter__.return_value.get_secret.return_value.value = ""
            with self.assertRaisesRegex(ValueError, "direct inference is prohibited"):
                govhub.create_model_client(settings(), object())

    def test_checked_patch_rejects_missing_or_duplicate_anchors(self, _dns):
        for source in ("drift", "anchor anchor"):
            with self.subTest(source=source):
                with self.assertRaises(ValueError):
                    patcher.replace_once(source, "anchor", "replacement")

    def test_image_fingerprint_changes_with_runtime_adapter(self, _dns):
        before = patcher.fingerprint()
        original = Path.read_bytes

        def modified(path):
            value = original(path)
            return value + b"\nchanged" if path.name == "govhub.py" else value

        with patch.object(Path, "read_bytes", modified):
            self.assertNotEqual(before, patcher.fingerprint())

    def test_empty_model_list_cannot_trigger_upstream_local_model_fallback(self, _dns):
        source = (
            "    aiFoundryConfiguration: retained\n"
            "    aiModelDeployments: !empty(modelDeploymentList)\n"
            "      ? modelDeploymentList\n"
            "      : [\n"
            "          { model: { name: 'gpt-5-nano' } }\n"
            "        ]\n"
            "    aiSearchConfiguration: retained\n"
        )
        result = patcher.disable_default_models(source)
        self.assertNotIn("gpt-5-nano", result)
        self.assertIn("    aiModelDeployments: modelDeploymentList\n", result)
        self.assertIn("aiFoundryConfiguration: retained", result)
        self.assertIn("aiSearchConfiguration: retained", result)
        with self.assertRaises(ValueError):
            patcher.disable_default_models("changed upstream shape")

    def test_public_gateway_dns_never_reads_key_or_falls_back(self, dns):
        dns.return_value = [(2, 1, 6, "", ("20.1.2.3", 443))]
        with patch.object(govhub, "SecretClient") as vault:
            with self.assertRaisesRegex(ValueError, "public inference is prohibited"):
                govhub.create_model_client(settings(), object())
            vault.assert_not_called()


if __name__ == "__main__":
    unittest.main()
