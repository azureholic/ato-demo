"""Model inference through the scenario's GovHub product, never project inference."""

import re
import ipaddress
import socket
from typing import Protocol
from urllib.parse import urlsplit

from agent_framework_openai import OpenAIChatClient
from azure.core.credentials import TokenCredential
from azure.keyvault.secrets import SecretClient
from openai import AsyncAzureOpenAI


class GatewaySettings(Protocol):
    model: str
    gateway_endpoint: str
    gateway_api_version: str
    gateway_secret_uri: str
    gateway_private_prefix: str
    vault_uri: str


def secret_coordinates(settings: GatewaySettings) -> tuple[str, str, str | None]:
    gateway = urlsplit(settings.gateway_endpoint)
    if (
        gateway.scheme != "https"
        or not re.fullmatch(r"[a-z0-9-]+\.azure-api\.net", gateway.hostname or "")
        or gateway.path != "/openai/"
        or gateway.port not in (None, 443)
        or gateway.username or gateway.password or gateway.query or gateway.fragment
    ):
        raise ValueError("GOVHUB_ENDPOINT must be the configured HTTPS /openai/ gateway.")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}(?:-preview)?", settings.gateway_api_version):
        raise ValueError("GOVHUB_API_VERSION is required.")
    vault, secret = urlsplit(settings.vault_uri), urlsplit(settings.gateway_secret_uri)
    if (
        vault.scheme != "https"
        or not re.fullmatch(r"[a-z0-9-]{3,24}\.vault\.azure\.net", vault.hostname or "")
        or vault.path not in ("", "/")
        or vault.port not in (None, 443)
        or vault.username or vault.password or vault.query or vault.fragment
        or secret.scheme != "https" or secret.hostname != vault.hostname
        or secret.port not in (None, 443)
        or secret.username or secret.password or secret.query or secret.fragment
    ):
        raise ValueError("GovHub subscription reference must bind the provisioned private vault.")
    match = re.fullmatch(r"/secrets/([A-Za-z0-9-]{1,127})(?:/([a-fA-F0-9]{32}))?", secret.path)
    if not match:
        raise ValueError("GOVHUB_SUBSCRIPTION_SECRET_URI must be an Azure Key Vault secret URI.")
    return f"https://{vault.hostname}/", match[1], match[2]


def create_model_client(settings: GatewaySettings, credential: TokenCredential) -> OpenAIChatClient:
    vault_uri, name, version = secret_coordinates(settings)
    network = ipaddress.ip_network(settings.gateway_private_prefix)
    addresses = socket.getaddrinfo(urlsplit(settings.gateway_endpoint).hostname, 443, type=socket.SOCK_STREAM)
    if not network.is_private or not addresses or any(
        ipaddress.ip_address(row[4][0]) not in network for row in addresses
    ):
        raise ValueError("GovHub must resolve inside its private spoke; public inference is prohibited.")
    with SecretClient(vault_url=vault_uri, credential=credential, logging_enable=False) as vault:
        key = vault.get_secret(name, version).value
    if not key:
        raise ValueError("GovHub subscription secret is empty; direct inference is prohibited.")
    return OpenAIChatClient(
        model=settings.model,
        async_client=AsyncAzureOpenAI(
            base_url=settings.gateway_endpoint,
            api_version=settings.gateway_api_version,
            api_key=key,
            timeout=60,
        ),
    )
