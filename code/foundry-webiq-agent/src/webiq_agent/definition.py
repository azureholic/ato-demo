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
    # gpt-6-astra accepts only low/medium/high reasoning effort and rejects function tools on Chat
    # Completions while reasoning is on, so tool calling needs Responses routing (see README).
    return PromptAgentDefinition(
        model=config.model_deployment,
        instructions=config.instructions_path.read_text(encoding="utf-8"),
        tools=[build_tool(config)],
        reasoning=Reasoning(effort=config.reasoning_effort),
    )
