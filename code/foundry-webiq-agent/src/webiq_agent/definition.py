"""Builds the prompt-agent definition."""

from __future__ import annotations

from azure.ai.projects.models import MCPTool, PromptAgentDefinition, Reasoning, WebSearchTool

from .config import AgentConfig


def build_tool(config: AgentConfig) -> MCPTool:
    return MCPTool(
        server_label=config.web_iq_server_label,
        server_url=config.web_iq_server_url,
        project_connection_id=config.web_iq_connection,
        allowed_tools=list(config.web_iq_allowed_tools),
        require_approval=config.require_approval,
    )


def build_definition(config: AgentConfig, use_web_iq: bool = True) -> PromptAgentDefinition:
    # gpt-6-astra accepts only low/medium/high reasoning effort and rejects function tools on Chat
    # Completions while reasoning is on, so tool calling needs Responses routing (see README).
    # Without a Web IQ connection the agent uses Foundry's built-in web search tool (config webSearchFallback).
    tool = build_tool(config) if use_web_iq else WebSearchTool()
    return PromptAgentDefinition(
        model=config.model_deployment,
        instructions=config.instructions_path.read_text(encoding="utf-8"),
        tools=[tool],
        reasoning=Reasoning(effort=config.reasoning_effort),
    )
