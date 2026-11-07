"""Private deployment-host protocol smoke test; never outputs subscription keys."""

import argparse
import ipaddress
import json
import socket
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

from azure.identity import AzureCliCredential
from azure.keyvault.secrets import SecretClient


def verify(config, governance):
    endpoint = config["governance"]["endpoint"]
    answers = socket.getaddrinfo(urlsplit(endpoint).hostname, 443, type=socket.SOCK_STREAM)
    expected = ipaddress.ip_network(governance["vnetAddressPrefix"])
    if not answers or any(ipaddress.ip_address(row[4][0]) not in expected for row in answers):
        raise ValueError("GovHub must resolve only to its configured private spoke, not a public fallback.")
    with SecretClient(
        vault_url=f'https://{config["keyVaultName"]}.vault.azure.net/',
        credential=AzureCliCredential(), logging_enable=False,
    ) as vault:
        key = vault.get_secret(config["governance"]["secretName"]).value
    if not key:
        raise ValueError("The Agent product subscription key is empty.")
    request = Request(
        endpoint + "responses?api-version=" + governance["model"]["apiVersion"],
        data=json.dumps({
            "model": governance["model"]["name"],
            "input": "Reply briefly with GOVHUB_AGENT_OK.",
            "max_output_tokens": 256,
        }).encode(),
        headers={"api-key": key, "Content-Type": "application/json"},
    )
    try:
        with urlopen(request, timeout=120) as response:
            result = json.load(response)
    except HTTPError as error:
        raise RuntimeError(f"Private GovHub product invocation failed with HTTP {error.code}.") from None
    if not result.get("id") or result.get("status") != "completed" or not result.get("output"):
        raise ValueError("GovHub did not return a completed, nonempty Responses result.")
    print(json.dumps({"gateway": endpoint, "model": result.get("model"), "status": result["status"]}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--governance-config", required=True)
    args = parser.parse_args()
    with open(args.config, encoding="utf-8-sig") as file:
        config = json.load(file)
    with open(args.governance_config, encoding="utf-8-sig") as file:
        governance = json.load(file)
    verify(config, governance)
