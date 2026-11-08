import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch
import urllib.error

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

spec = importlib.util.spec_from_file_location("register", Path(__file__).parents[1] / "image" / "register.py")
register = importlib.util.module_from_spec(spec)
spec.loader.exec_module(register)


class RegistrationTests(unittest.TestCase):
    def test_app_jwt_is_signed_and_short_lived(self):
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                serialization.NoEncryption()).decode()
        header, payload, signature = register.app_jwt(pem, "123", 1000).split(".")
        claims = json.loads(base64.urlsafe_b64decode(payload + "==="))
        self.assertEqual(claims, {"iat": 940, "exp": 1540, "iss": "123"})
        key.public_key().verify(base64.urlsafe_b64decode(signature + "==="),
                                f"{header}.{payload}".encode(), padding.PKCS1v15(), hashes.SHA256())

    def test_registration_limits_installation_token_to_repository(self):
        environment = {"GITHUB_REPOSITORY": "owner/scenario", "GITHUB_APP_ID": "123",
                       "GITHUB_INSTALLATION_ID": "456", "GITHUB_APP_PRIVATE_KEY": "private-key"}
        with patch.dict(os.environ, environment), patch.object(register, "app_jwt", return_value="jwt"), \
                patch.object(register, "post", side_effect=[{"token": "installation"}, {"token": "registration"}]) as post:
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                register.register()
        self.assertEqual(output.getvalue(), "registration\n")
        self.assertEqual(post.call_args_list[0].args,
                         ("/app/installations/456/access_tokens", "jwt",
                          {"repositories": ["scenario"], "permissions": {"administration": "write"}}))
        self.assertEqual(post.call_args_list[1].args,
                         ("/repos/owner/scenario/actions/runners/registration-token", "installation"))

    def test_http_failure_does_not_expose_credentials_or_response(self):
        error = urllib.error.HTTPError("https://api.github.com", 403, "secret-response", {}, None)
        with patch.object(register.urllib.request, "urlopen", side_effect=error):
            with self.assertRaisesRegex(RuntimeError, "^GitHub request failed with HTTP 403\\.$"):
                register.post("/request", "secret-token")


if __name__ == "__main__":
    unittest.main()
