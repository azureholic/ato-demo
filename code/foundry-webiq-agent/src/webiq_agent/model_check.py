"""Checks the Governance Hub model path without Web IQ: plain completion, then a function tool call.

Publishes a separate agent named '<agent>-model-check' with no MCP tools, so it works before the
Web IQ connection exists and never touches the real agent.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import FunctionTool, PromptAgentDefinition
from azure.core.exceptions import HttpResponseError
from azure.identity import DefaultAzureCredential

from .config import DEFAULT_CONFIG, AgentConfig, ConfigError, load_config, project_endpoint
from .publish import _require_connection

CHECK_VALUE = "7413"
INSTRUCTIONS = (
    "You are a connectivity check. Follow the user's instruction exactly and keep answers to one short line."
)


def check_tool() -> FunctionTool:
    return FunctionTool(
        name="get_check_value",
        description="Returns the check value that the user asks for.",
        parameters={"type": "object", "properties": {}, "required": [], "additionalProperties": False},
        strict=True,
    )


def _text(response: Any) -> str:
    return (getattr(response, "output_text", "") or "").strip()


def run_checks(openai: Any) -> list[str]:
    """Returns a list of failure descriptions; empty means every check passed."""
    failures: list[str] = []
    conversation = openai.conversations.create()
    try:
        plain = openai.responses.create(conversation=conversation.id, input="Reply with exactly the word: ready")
        if "ready" not in _text(plain).lower():
            failures.append(f"Plain completion did not return 'ready': {_text(plain)!r}")

        response = openai.responses.create(
            conversation=conversation.id,
            input="Call get_check_value, then tell me the value it returned.",
        )
        calls = [i for i in getattr(response, "output", []) or [] if getattr(i, "type", "") == "function_call"]
        if not calls:
            failures.append(f"Model did not call the function tool: {_text(response)!r}")
        else:
            outputs = [
                {"type": "function_call_output", "call_id": c.call_id, "output": json.dumps({"value": CHECK_VALUE})}
                for c in calls
            ]
            response = openai.responses.create(conversation=conversation.id, input=outputs)
            if CHECK_VALUE not in _text(response):
                failures.append(f"Tool result was not used in the answer: {_text(response)!r}")
    finally:
        openai.conversations.delete(conversation_id=conversation.id)
    return failures


def check_agent_name(config: AgentConfig) -> str:
    return f"{config.agent_name}-model-check"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=str(DEFAULT_CONFIG))
    parser.add_argument("--endpoint", help="Foundry project endpoint; defaults to FOUNDRY_PROJECT_ENDPOINT.")
    args = parser.parse_args(argv)

    try:
        config = load_config(args.config)
        endpoint = project_endpoint(args.endpoint)
        name = check_agent_name(config)
        with AIProjectClient(endpoint=endpoint, credential=DefaultAzureCredential(), allow_preview=True) as project:
            _require_connection(project, config.model_connection, "Governance Hub model gateway")
            agent = project.agents.create_version(
                agent_name=name,
                definition=PromptAgentDefinition(
                    model=config.model_deployment, instructions=INSTRUCTIONS, tools=[check_tool()]
                ),
                description="Model-path connectivity check; safe to ignore.",
            )
            print(f"Published {agent.name} version {agent.version} using {config.model_deployment}.")
            with project.get_openai_client(agent_name=name) as openai:
                failures = run_checks(openai)
    except (ConfigError, HttpResponseError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    for failure in failures:
        print(f"FAILED: {failure}", file=sys.stderr)
    if not failures:
        print("Model path OK: completion and function tool calling work through the Governance Hub.")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
