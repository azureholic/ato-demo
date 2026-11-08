"""Exchange a GitHub App key for a short-lived repository runner token."""
import base64
import json
import os
import time
import urllib.error
import urllib.request

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding


def encode(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def app_jwt(key_pem, app_id, now):
    header = encode(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    payload = encode(json.dumps({"iat": now - 60, "exp": now + 540, "iss": app_id}).encode())
    message = f"{header}.{payload}".encode()
    key = serialization.load_pem_private_key(key_pem.encode(), password=None)
    signature = key.sign(message, padding.PKCS1v15(), hashes.SHA256())
    return f"{header}.{payload}.{encode(signature)}"


def post(path, token, body=None):
    request = urllib.request.Request(
        f"https://api.github.com{path}",
        data=json.dumps(body or {}).encode(),
        method="POST",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"GitHub request failed with HTTP {error.code}.") from None


def register():
    repository = os.environ["GITHUB_REPOSITORY"]
    owner, name = repository.split("/")
    jwt = app_jwt(os.environ["GITHUB_APP_PRIVATE_KEY"], os.environ["GITHUB_APP_ID"], int(time.time()))
    installation = post(f"/app/installations/{os.environ['GITHUB_INSTALLATION_ID']}/access_tokens",
                        jwt, {"repositories": [name], "permissions": {"administration": "write"}})
    result = post(f"/repos/{owner}/{name}/actions/runners/registration-token", installation["token"])
    token = result.get("token")
    if not isinstance(token, str) or not token:
        raise RuntimeError("GitHub returned no runner registration token.")
    print(token)


if __name__ == "__main__":
    register()
