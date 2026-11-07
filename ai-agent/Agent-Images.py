"""Transfer same-run image artifacts without sending GitHub credentials to storage."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import urllib.error
import urllib.request
from urllib.parse import urlsplit
import zipfile

PINS = {
    "agent-app-orchestrator": "666d39862590cfb165097ee55737a1ef66fd2afc",
    "agent-app-ui": "8a45595aa321d8841e7a4555d542b890beebf1b0",
}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def github_json(path: str, token: str):
    request = urllib.request.Request(
        f"https://api.github.com/repos/{path}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def artifact_destination(repository: str, run_id: str, revision: str, token: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid artifact repository.")
    if not run_id.isdecimal() or not re.fullmatch(r"[a-f0-9]{40}", revision):
        raise ValueError("Artifacts require an exact workflow run and revision.")
    run = github_json(f"{repository}/actions/runs/{run_id}", token)
    if run["head_sha"] != revision or run["event"] != "workflow_dispatch":
        raise ValueError("Artifact run does not match the approved deployment revision.")
    data = github_json(f"{repository}/actions/runs/{run_id}/artifacts?per_page=100", token)
    artifacts = [
        item for item in data["artifacts"]
        if item["name"] == f"ai-agent-images-{revision}" and not item["expired"]
    ]
    if len(artifacts) != 1:
        raise ValueError("Expected one unexpired image artifact from this deployment run.")
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repository}/actions/artifacts/{artifacts[0]['id']}/zip",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        urllib.request.build_opener(NoRedirect()).open(request, timeout=60)
    except urllib.error.HTTPError as error:
        if error.code not in (302, 307):
            raise RuntimeError(f"Artifact lookup failed: HTTP {error.code}.") from None
        destination = error.headers["Location"]
    else:
        raise ValueError("GitHub artifact endpoint did not provide a storage redirect.")
    parsed = urlsplit(destination)
    if parsed.scheme != "https" or parsed.username or parsed.password or parsed.port not in (None, 443):
        raise ValueError("Artifact storage redirect is not trusted HTTPS.")
    if not re.fullmatch(
        r"(?:productionresultssa[0-9]+|pipelinesghub[a-z0-9]+)\.blob\.core\.windows\.net",
        parsed.hostname or "",
    ):
        raise ValueError(f"Unexpected GitHub artifact storage hostname: {parsed.hostname}")
    return destination


def extract_images(archive: Path, directory: Path) -> None:
    allowed = {"manifest.json", *(f"{name}.tar" for name in PINS)}
    with zipfile.ZipFile(archive) as bundle:
        names = bundle.namelist()
        if len(names) != len(allowed) or set(names) != allowed:
            raise ValueError("Image artifact has unexpected, duplicate or unsafe paths.")
        bundle.extractall(directory)


def verify_images(directory: Path, revision: str, configuration_hash: str) -> dict:
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8-sig"))
    if (
        manifest["schemaVersion"] != 1 or manifest["revision"] != revision
        or manifest["configurationHash"] != configuration_hash
    ):
        raise ValueError("Image artifacts do not match this revision and GovHub configuration.")
    components = manifest["components"]
    if len(components) != len(PINS) or {item["name"] for item in components} != set(PINS):
        raise ValueError("Image artifact component selection changed.")
    for component in components:
        name = component["name"]
        if component["sourceCommit"] != PINS[name] or component["file"] != f"{name}.tar":
            raise ValueError("Image source or archive name does not match the immutable manifest.")
        if not re.fullmatch(r"ato-[a-f0-9]{12}-[a-f0-9]{16}", component["tag"]):
            raise ValueError("Image tag is not source/configuration-specific.")
        with (directory / component["file"]).open("rb") as archive:
            digest = hashlib.file_digest(archive, "sha256").hexdigest()
        if digest != component["sha256"]:
            raise ValueError(f"Image artifact checksum mismatch: {name}")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("destination", "download", "verify"))
    parser.add_argument("--repository", default=os.environ.get("ATO_REPOSITORY"))
    parser.add_argument("--run-id", default=os.environ.get("ATO_GITHUB_RUN_ID"))
    parser.add_argument("--revision", default=os.environ.get("ATO_REVISION"))
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--configuration-hash")
    args = parser.parse_args()
    if args.action == "verify":
        print(json.dumps(verify_images(args.directory, args.revision, args.configuration_hash)))
    else:
        destination = artifact_destination(
            args.repository, args.run_id, args.revision, os.environ["GH_TOKEN"]
        )
        if args.action == "destination":
            print(urlsplit(destination).hostname)
        else:
            args.directory.mkdir(parents=True, exist_ok=True)
            archive = args.directory / "images.zip"
            try:
                # The signed storage URL is deliberately requested without GitHub headers.
                with urllib.request.urlopen(destination, timeout=120) as source, archive.open("wb") as target:
                    shutil.copyfileobj(source, target)
                extract_images(archive, args.directory)
            finally:
                archive.unlink(missing_ok=True)
