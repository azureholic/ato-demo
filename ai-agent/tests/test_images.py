import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


images = load("images", "Agent-Images.py")
patcher = load("patcher", "Patch-AiAgent.py")


class ImageArtifactTests(unittest.TestCase):
    def test_checksums_and_approved_revision_are_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            components = []
            for name, commit in images.PINS.items():
                payload = name.encode()
                (directory / f"{name}.tar").write_bytes(payload)
                components.append({"name": name, "sourceCommit": commit, "file": f"{name}.tar",
                                   "tag": f"ato-{commit[:12]}-{'b' * 16}",
                                   "sha256": hashlib.sha256(payload).hexdigest()})
            manifest = {"schemaVersion": 1, "revision": "a" * 40, "configurationHash": "b" * 16,
                        "components": components}
            (directory / "manifest.json").write_text(json.dumps(manifest))
            self.assertEqual(images.verify_images(directory, "a" * 40, "b" * 16), manifest)
            with self.assertRaisesRegex(ValueError, "revision"):
                images.verify_images(directory, "c" * 40, "b" * 16)
            (directory / components[0]["file"]).write_bytes(b"changed image")
            with self.assertRaisesRegex(ValueError, "checksum"):
                images.verify_images(directory, "a" * 40, "b" * 16)

    def test_archive_cannot_escape_image_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            archive = directory / "images.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("../outside", "untrusted")
            with self.assertRaisesRegex(ValueError, "unsafe paths"):
                images.extract_images(archive, directory / "output")
            self.assertFalse((directory / "outside").exists())

    def test_ui_deploy_accepts_only_immutable_provisioned_registry_image(self):
        original = """$values = @{CONTAINER_REGISTRY_LOGIN_SERVER='private123.azurecr.io'}
function Write-Green { param($Text) }
function Write-Blue { param($Text) }
if ($buildMode -eq 'local') {
    Write-Blue ("Logging into ACR")
    throw 'The private job must not build with Docker.'
}
Write-Blue 'Updating container app registry...'
Write-Output "updated:$fullImageName"
"""
        source = patcher.artifact_ui_deploy(original)
        digest = "sha256:" + "a" * 64
        for image, accepted in (
            (f"private123.azurecr.io/agent-app-ui@{digest}", True),
            ("private123.azurecr.io/agent-app-ui:latest", False),
            (f"other123.azurecr.io/agent-app-ui@{digest}", False),
        ):
            with self.subTest(image=image):
                result = subprocess.run(
                    ["pwsh", "-NoProfile", "-Command", source],
                    env={**os.environ, "ATO_UI_IMAGE": image}, capture_output=True, text=True,
                )
                self.assertEqual(result.returncode == 0, accepted, result.stderr)
                if accepted:
                    self.assertIn(f"updated:{image}", result.stdout)


if __name__ == "__main__":
    unittest.main()
