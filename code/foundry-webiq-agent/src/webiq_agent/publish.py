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


def _connection_exists(project: AIProjectClient, name: str) -> bool:
    try:
        project.connections.get(name)
    except ResourceNotFoundError:
        return False
    return True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=str(DEFAULT_CONFIG))
    parser.add_argument("--endpoint", help="Foundry project endpoint; defaults to FOUNDRY_PROJECT_ENDPOINT.")
    args = parser.parse_args(argv)

    try:
        config = load_config(args.config)
        endpoint = project_endpoint(args.endpoint)
        with AIProjectClient(endpoint=endpoint, credential=DefaultAzureCredential(), allow_preview=True) as project:
            _require_connection(project, config.model_connection, "Governance Hub model gateway")
            use_web_iq = _connection_exists(project, config.web_iq_connection)
            if not use_web_iq:
                if not config.web_search_fallback:
                    raise ConfigError(
                        f"Project connection {config.web_iq_connection!r} (Web IQ MCP) does not exist; deploy it first."
                    )
                print(
                    f"WARNING: Web IQ connection {config.web_iq_connection!r} not found; "
                    "publishing with the built-in web search tool instead.",
                    file=sys.stderr,
                )
            agent = project.agents.create_version(
                agent_name=config.agent_name,
                definition=build_definition(config, use_web_iq),
                description=config.description,
            )
    except (ConfigError, HttpResponseError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    tool_name = "Web IQ" if use_web_iq else "built-in web search"
    print(f"Published agent {agent.name} version {agent.version} using {config.model_deployment} with {tool_name}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
