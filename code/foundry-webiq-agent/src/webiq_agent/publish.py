"""Publishes a new version of the prompt agent. Never creates or overwrites shared connections."""

from __future__ import annotations

import argparse
import sys

from azure.ai.projects import AIProjectClient
from azure.core.exceptions import HttpResponseError, ResourceNotFoundError
from azure.identity import DefaultAzureCredential

from .config import DEFAULT_CONFIG, ConfigError, load_config, project_endpoint
from .definition import build_definition


def _require_connection(project: AIProjectClient, name: str, purpose: str) -> None:
    try:
        project.connections.get(name)
    except ResourceNotFoundError as exc:
        raise ConfigError(
            f"Project connection {name!r} ({purpose}) does not exist; deploy it first."
        ) from exc


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=str(DEFAULT_CONFIG))
    parser.add_argument("--endpoint", help="Foundry project endpoint; defaults to FOUNDRY_PROJECT_ENDPOINT.")
    args = parser.parse_args(argv)

    try:
        config = load_config(args.config)
        endpoint = project_endpoint(args.endpoint)
        definition = build_definition(config)
        with AIProjectClient(endpoint=endpoint, credential=DefaultAzureCredential(), allow_preview=True) as project:
            _require_connection(project, config.model_connection, "Governance Hub model gateway")
            _require_connection(project, config.web_iq_connection, "Web IQ MCP")
            agent = project.agents.create_version(
                agent_name=config.agent_name,
                definition=definition,
                description=config.description,
            )
    except (ConfigError, HttpResponseError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    print(f"Published agent {agent.name} version {agent.version} using {config.model_deployment}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
