"""Builds the prompt-agent definition."""

from __future__ import annotations

from azure.ai.projects.models import MCPTool, PromptAgentDefinition, Reasoning

from .config import AgentConfig


def build_tool(config: AgentConfig) -> MCPTool:
    return MCPTool(
        server_label=config.web_iq_server_label,
        server_url=config.web_iq_server_url,
        project_connection_id=config.web_iq_connection,
        allowed_tools=list(config.web_iq_allowed_tools),
        require_approval=config.require_approval,
    )


def build_definition(config: AgentConfig) -> PromptAgentDefinition:
    # gpt-6 models reject function tools on Chat Completions while reasoning is enabled; the Hub
    # connection uses Chat Completions, so reasoning effort is configurable (default 'none').
    return PromptAgentDefinition(
        model=config.model_deployment,
        instructions=config.instructions_path.read_text(encoding="utf-8"),
        tools=[build_tool(config)],
        reasoning=Reasoning(effort=config.reasoning_effort),
    )
