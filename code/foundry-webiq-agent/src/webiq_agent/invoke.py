"""Asks the published agent a question, with explicit MCP tool-approval handling and citations."""

from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Callable
from typing import Any

from azure.ai.projects import AIProjectClient
from azure.core.exceptions import HttpResponseError
from azure.identity import DefaultAzureCredential

from .config import DEFAULT_CONFIG, AgentConfig, ConfigError, load_config, project_endpoint

MAX_APPROVAL_ROUNDS = 8


def decide_approval(item: Any, config: AgentConfig, auto_approve: bool, ask: Callable[[str], bool]) -> bool:
    """Approve one MCP call. Auto-approval is limited to the configured server and allowed tools."""
    server = getattr(item, "server_label", "")
    tool = getattr(item, "name", "")
    if auto_approve:
        return server == config.web_iq_server_label and tool in config.web_iq_allowed_tools
    arguments = json.dumps(getattr(item, "arguments", None), default=str)
    return ask(f"Approve MCP call {server}/{tool} with arguments {arguments}? [y/N] ")


def collect_citations(response: Any) -> list[str]:
    urls: list[str] = []
    for item in getattr(response, "output", []) or []:
        if getattr(item, "type", "") != "message":
            continue
        for part in getattr(item, "content", []) or []:
            for annotation in getattr(part, "annotations", []) or []:
                url = getattr(annotation, "url", None)
                if getattr(annotation, "type", "") == "url_citation" and url and url not in urls:
                    urls.append(url)
    return urls


def pending_approvals(response: Any) -> list[Any]:
    return [i for i in getattr(response, "output", []) or [] if getattr(i, "type", "") == "mcp_approval_request"]


def _approval_response(request_id: str, approve: bool) -> dict[str, Any]:
    return {"type": "mcp_approval_response", "approval_request_id": request_id, "approve": approve}


def _describe(label: str, response: Any) -> None:
    """Prints item types (and MCP errors) so a failing run shows how far the conversation got."""
    items = []
    for item in getattr(response, "output", []) or []:
        kind = getattr(item, "type", "?")
        error = getattr(item, "error", None)
        items.append(f"{kind}({getattr(item, 'name', '')})" + (f" error={error}" if error else ""))
    print(f"[{label}] status={getattr(response, 'status', '?')} items={items}", file=sys.stderr)


def ask_agent(
    openai: Any,
    question: str,
    config: AgentConfig,
    auto_approve: bool,
    ask: Callable[[str], bool],
    follow_ups: tuple[str, ...] = (),
) -> Any:
    conversation = openai.conversations.create()
    try:
        response = None
        for number, turn in enumerate((question, *follow_ups), start=1):
            response = openai.responses.create(conversation=conversation.id, input=turn)
            _describe(f"turn {number}", response)
            for round_number in range(MAX_APPROVAL_ROUNDS):
                requests = pending_approvals(response)
                if not requests:
                    break
                decisions = [
                    _approval_response(r.id, decide_approval(r, config, auto_approve, ask)) for r in requests
                ]
                response = openai.responses.create(conversation=conversation.id, input=decisions)
                _describe(f"turn {number} approval {round_number + 1}", response)
            else:
                raise RuntimeError(f"Agent still requested approvals after {MAX_APPROVAL_ROUNDS} rounds.")
            if getattr(response, "status", "completed") != "completed":
                raise RuntimeError(f"Agent response ended with status {response.status}: {getattr(response, 'error', None)}")
        return response
    finally:
        openai.conversations.delete(conversation_id=conversation.id)


def _interactive_ask(prompt: str) -> bool:
    return input(prompt).strip().lower() == "y"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("question")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG))
    parser.add_argument("--endpoint", help="Foundry project endpoint; defaults to FOUNDRY_PROJECT_ENDPOINT.")
    parser.add_argument(
        "--auto-approve-allowed-tools",
        action="store_true",
        help="Non-interactively approve only the configured Web IQ tools; deny every other request.",
    )
    parser.add_argument(
        "--follow-up",
        action="append",
        default=[],
        help="Additional turn(s) sent in the same conversation; proves multi-turn replay through the Hub.",
    )
    args = parser.parse_args(argv)

    try:
        config = load_config(args.config)
        endpoint = project_endpoint(args.endpoint)
        with AIProjectClient(endpoint=endpoint, credential=DefaultAzureCredential(), allow_preview=True) as project:
            with project.get_openai_client(agent_name=config.agent_name) as openai:
                response = ask_agent(
                    openai, args.question, config, args.auto_approve_allowed_tools, _interactive_ask, tuple(args.follow_up)
                )
    except (ConfigError, HttpResponseError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    print(response.output_text)
    citations = collect_citations(response)
    print("\nSources:" if citations else "\nSources: none returned")
    for url in citations:
        print(f"- {url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
