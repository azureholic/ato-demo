import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from webiq_agent.config import DEFAULT_CONFIG, ConfigError, load_config, project_endpoint
from webiq_agent.definition import build_definition
from webiq_agent.invoke import ask_agent, collect_citations, decide_approval


@pytest.fixture
def config():
    return load_config()


def _write_config(tmp_path: Path, mutate) -> Path:
    raw = json.loads(DEFAULT_CONFIG.read_text(encoding="utf-8"))
    mutate(raw)
    folder = tmp_path / "config"
    folder.mkdir()
    path = folder / "deployment.json"
    path.write_text(json.dumps(raw), encoding="utf-8")
    instructions = tmp_path / "agent"
    instructions.mkdir()
    (instructions / "instructions.md").write_text("x", encoding="utf-8")
    return path


def test_model_uses_governance_hub_connection(config):
    assert config.model_deployment == "govhub-web-research-LLM/gpt-6-astra"


def test_definition_attaches_only_allowed_web_iq_tools_with_approval(config):
    definition = build_definition(config)
    tool = definition.tools[0]
    assert definition.reasoning.effort == "low"
    assert tool.server_url == "https://api.microsoft.ai/v3/mcp"
    assert tool.project_connection_id == "web-iq-mcp"
    assert tool.allowed_tools == ["web", "browse"]
    assert tool.require_approval == "always"


def test_definition_without_web_iq_uses_the_builtin_web_search_tool(config):
    definition = build_definition(config, use_web_iq=False)
    assert config.web_search_fallback
    assert [t.type for t in definition.tools] == ["web_search"]
    assert definition.model == "govhub-web-research-LLM/gpt-6-astra"


def test_empty_allowed_tools_is_rejected(tmp_path):
    path = _write_config(tmp_path, lambda raw: raw["webIq"].update(allowedTools=[]))
    with pytest.raises(ConfigError, match="allowedTools"):
        load_config(path)


def test_approval_never_relaxed_by_configuration(tmp_path):
    path = _write_config(tmp_path, lambda raw: raw["agent"].update(requireApproval="never"))
    with pytest.raises(ConfigError, match="requireApproval"):
        load_config(path)


@pytest.mark.parametrize("endpoint", ["", "http://x.services.ai.azure.com/api/projects/p", "https://evil.example/api/projects/p"])
def test_project_endpoint_must_be_a_foundry_project_url(endpoint):
    with pytest.raises(ConfigError):
        project_endpoint(endpoint)


def _request(server, name, id_="req-1"):
    return SimpleNamespace(type="mcp_approval_request", id=id_, server_label=server, name=name, arguments="{}")


def test_auto_approval_is_limited_to_configured_server_and_tools(config):
    deny = lambda prompt: pytest.fail("must not prompt")  # noqa: E731
    assert decide_approval(_request("web_iq", "web"), config, True, deny)
    assert not decide_approval(_request("web_iq", "images"), config, True, deny)
    assert not decide_approval(_request("other", "web"), config, True, deny)


def test_interactive_approval_defers_to_the_user(config):
    assert decide_approval(_request("web_iq", "images"), config, False, lambda prompt: True)
    assert not decide_approval(_request("web_iq", "web"), config, False, lambda prompt: False)


def test_citations_are_deduplicated_url_citations():
    annotations = [
        SimpleNamespace(type="url_citation", url="https://a.example"),
        SimpleNamespace(type="url_citation", url="https://a.example"),
        SimpleNamespace(type="file_citation", url="https://ignored.example"),
        SimpleNamespace(type="url_citation", url="https://b.example"),
    ]
    response = SimpleNamespace(
        output=[SimpleNamespace(type="message", content=[SimpleNamespace(annotations=annotations)])]
    )
    assert collect_citations(response) == ["https://a.example", "https://b.example"]


class FakeOpenAI:
    def __init__(self, responses):
        self.responses_queue = list(responses)
        self.inputs = []
        self.deleted = []
        self.conversations = SimpleNamespace(
            create=lambda: SimpleNamespace(id="conv-1"),
            delete=lambda conversation_id: self.deleted.append(conversation_id),
        )
        self.responses = SimpleNamespace(create=self._create)

    def _create(self, conversation, input):
        self.inputs.append(input)
        return self.responses_queue.pop(0)


def _response(output, status="completed"):
    return SimpleNamespace(output=output, status=status, output_text="answer", error=None)


def test_approval_continues_in_the_same_conversation_and_denies_unlisted_tools(config):
    fake = FakeOpenAI([
        _response([_request("web_iq", "web", "a"), _request("web_iq", "images", "b")]),
        _response([]),
    ])
    result = ask_agent(fake, "question", config, True, lambda prompt: pytest.fail("must not prompt"))
    assert result.output_text == "answer"
    decisions = {d["approval_request_id"]: d["approve"] for d in fake.inputs[1]}
    assert decisions == {"a": True, "b": False}
    assert fake.deleted == ["conv-1"]


def test_failed_response_is_reported_and_conversation_cleaned_up(config):
    fake = FakeOpenAI([_response([], status="failed")])
    with pytest.raises(RuntimeError, match="failed"):
        ask_agent(fake, "question", config, True, lambda prompt: False)
    assert fake.deleted == ["conv-1"]


def _model_check_fake(outputs):
    fake = FakeOpenAI(outputs)
    return fake


def _text_response(text, output=()):
    return SimpleNamespace(output=list(output), output_text=text, status="completed", error=None)


def test_model_check_passes_when_completion_and_function_call_work():
    from webiq_agent.model_check import CHECK_VALUE, run_checks

    call = SimpleNamespace(type="function_call", call_id="c1", name="get_check_value", arguments="{}")
    fake = _model_check_fake([
        _text_response("ready"),
        _text_response("", [call]),
        _text_response(f"The value is {CHECK_VALUE}"),
    ])
    assert run_checks(fake) == []
    assert fake.inputs[2][0]["call_id"] == "c1"
    assert fake.deleted == ["conv-1"]


def test_model_check_reports_a_model_that_ignores_the_tool():
    from webiq_agent.model_check import run_checks

    fake = _model_check_fake([_text_response("ready"), _text_response("no tool")])
    failures = run_checks(fake)
    assert len(failures) == 1 and "function tool" in failures[0]
