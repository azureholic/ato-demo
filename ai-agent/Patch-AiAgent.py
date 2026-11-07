"""Apply checked scenario adapters only to manifest-pinned runner checkouts."""

import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess

TEMPLATE_COMMIT = "a75485015afeddc8b9221538778ef918718ed51f"
RUNTIME_COMMIT = "666d39862590cfb165097ee55737a1ef66fd2afc"


def original(root: Path, commit: str, relative: str) -> str:
    actual = subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
    ).strip()
    if actual != commit:
        raise ValueError(f"Refusing adapter for unpinned checkout: {actual}")
    return subprocess.check_output(
        ["git", "-C", str(root), "show", f"HEAD:{relative}"], text=True, encoding="utf-8"
    )


def replace_once(source: str, old: str, new: str) -> str:
    if source.count(old) != 1:
        raise ValueError("Pinned source adapter anchor drifted; coordinate upstream before deploying.")
    return source.replace(old, new, 1)


def fingerprint() -> str:
    digest = hashlib.sha256()
    for file in (Path(__file__), Path(__file__).with_name("govhub.py")):
        digest.update(file.read_bytes())
    return digest.hexdigest()[:16]


def disable_default_models(source: str) -> str:
    pattern = (
        r"    aiModelDeployments: !empty\(modelDeploymentList\)\n"
        r"      \? modelDeploymentList\n"
        r"      : \[[\s\S]*?\n        \]\n"
    )
    if len(re.findall(pattern, source)) != 1:
        raise ValueError("Pinned empty-model fallback changed; refusing local model deployment.")
    return re.sub(pattern, "    aiModelDeployments: modelDeploymentList\n", source, count=1)


def patch_runtime(root: Path) -> None:
    relative = "src/native/config.py"
    source = original(root, RUNTIME_COMMIT, relative)
    source = replace_once(
        source, '    "MULTIMODAL_ENABLED",',
        '    "MULTIMODAL_ENABLED",\n'
        '    "GOVHUB_ENDPOINT", "GOVHUB_API_VERSION",\n'
        '    "GOVHUB_SUBSCRIPTION_SECRET_URI", "GOVHUB_PRIVATE_ADDRESS_PREFIX", "KEY_VAULT_URI",',
    )
    source = replace_once(
        source, "    model: str\n",
        "    model: str\n"
        "    gateway_endpoint: str\n"
        "    gateway_api_version: str\n"
        "    gateway_secret_uri: str\n"
        "    gateway_private_prefix: str\n"
        "    vault_uri: str\n",
    )
    source = replace_once(
        source, '            model=str(values.get("CHAT_DEPLOYMENT_NAME") or ""),',
        '            model=str(values.get("CHAT_DEPLOYMENT_NAME") or ""),\n'
        '            gateway_endpoint=str(values.get("GOVHUB_ENDPOINT") or ""),\n'
        '            gateway_api_version=str(values.get("GOVHUB_API_VERSION") or ""),\n'
        '            gateway_secret_uri=str(values.get("GOVHUB_SUBSCRIPTION_SECRET_URI") or ""),\n'
        '            gateway_private_prefix=str(values.get("GOVHUB_PRIVATE_ADDRESS_PREFIX") or ""),\n'
        '            vault_uri=str(values.get("KEY_VAULT_URI") or ""),',
    )
    source = replace_once(
        source, "        return result\n",
        "        from .govhub import secret_coordinates\n"
        "        secret_coordinates(result)\n"
        "        return result\n",
    )
    (root / relative).write_text(source, encoding="utf-8")
    relative = "src/native/agent.py"
    source = original(root, RUNTIME_COMMIT, relative)
    source = replace_once(
        source, "from agent_framework_foundry import FoundryChatClient",
        "from .govhub import create_model_client",
    )
    source = replace_once(
        source,
        "        client=client or FoundryChatClient(\n"
        "            project_endpoint=settings.project_endpoint, model=settings.model,\n"
        "            credential=config.sync_credential, timeout=60,\n"
        "        ),",
        "        client=client or create_model_client(settings, config.sync_credential),",
    )
    (root / relative).write_text(source, encoding="utf-8")
    shutil.copyfile(Path(__file__).with_name("govhub.py"), root / "src/native/govhub.py")


def patch_template(root: Path) -> None:
    relative = "infra/bicep/main.bicep"
    source = original(root, TEMPLATE_COMMIT, relative)
    (root / relative).write_text(disable_default_models(source), encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("template", "runtime", "fingerprint"))
    parser.add_argument("source", type=Path, nargs="?")
    args = parser.parse_args()
    if args.action == "fingerprint":
        print(fingerprint())
    elif args.source is None:
        parser.error("A manifest-pinned checkout is required.")
    elif args.action == "template":
        patch_template(args.source)
    else:
        patch_runtime(args.source)
