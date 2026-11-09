"""Configuration for the Web IQ prompt agent. config/deployment.json is the single source of truth."""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONFIG = PROJECT_ROOT / "config" / "deployment.json"

_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$")
_ENDPOINT = re.compile(r"^https://[a-z0-9-]+\.services\.ai\.azure\.com/api/projects/[A-Za-z0-9_-]+/?$")
_APPROVAL_MODES = {"always"}


class ConfigError(ValueError):
    pass


@dataclass(frozen=True)
class AgentConfig:
    agent_name: str
    description: str
    instructions_path: Path
    require_approval: str
    model_connection: str
    model_name: str
    web_iq_connection: str
    web_iq_server_url: str
    web_iq_server_label: str
    web_iq_allowed_tools: tuple[str, ...]

    @property
    def model_deployment(self) -> str:
        """Foundry addresses connected models as '<connection-name>/<model-name>'."""
        return f"{self.model_connection}/{self.model_name}"


def load_config(path: Path | str = DEFAULT_CONFIG) -> AgentConfig:
    path = Path(path)
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ConfigError(f"Cannot read configuration {path}: {exc}") from exc

    try:
        agent = raw["agent"]
        contract = raw["accessContract"]
        model = raw["model"]
        web_iq = raw["webIq"]
        tools = tuple(web_iq["allowedTools"])
        config = AgentConfig(
            agent_name=agent["name"],
            description=agent["description"],
            instructions_path=(path.parent.parent / agent["instructionsFile"]).resolve(),
            require_approval=agent["requireApproval"],
            # Mirrors the connection name the Citadel contract creates: '<prefix>-<service code>'.
            model_connection=f"{contract['connectionNamePrefix']}-LLM",
            model_name=model["name"],
            web_iq_connection=web_iq["connectionName"],
            web_iq_server_url=web_iq["serverUrl"],
            web_iq_server_label=web_iq["serverLabel"],
            web_iq_allowed_tools=tools,
        )
    except KeyError as exc:
        raise ConfigError(f"Missing configuration key {exc} in {path}.") from exc

    _validate(config)
    return config


def _validate(config: AgentConfig) -> None:
    for label, value in (
        ("agent.name", config.agent_name),
        ("model connection", config.model_connection),
        ("webIq.connectionName", config.web_iq_connection),
        ("webIq.serverLabel", config.web_iq_server_label),
    ):
        if not _NAME.match(value):
            raise ConfigError(f"{label} {value!r} is not a valid Foundry name.")
    if config.require_approval not in _APPROVAL_MODES:
        raise ConfigError("agent.requireApproval must be 'always'; relax it only after review.")
    if not config.web_iq_server_url.startswith("https://"):
        raise ConfigError("webIq.serverUrl must use https.")
    if not config.web_iq_allowed_tools or not all(isinstance(t, str) and t for t in config.web_iq_allowed_tools):
        raise ConfigError("webIq.allowedTools must list at least one tool; an empty list would allow every tool.")
    if not config.instructions_path.is_file():
        raise ConfigError(f"Instructions file not found: {config.instructions_path}")


def project_endpoint(explicit: str | None = None) -> str:
    endpoint = explicit or os.environ.get("FOUNDRY_PROJECT_ENDPOINT", "")
    if not _ENDPOINT.match(endpoint):
        raise ConfigError(
            "Set FOUNDRY_PROJECT_ENDPOINT (or --endpoint) to "
            "https://<account>.services.ai.azure.com/api/projects/<project>."
        )
    return endpoint.rstrip("/")
