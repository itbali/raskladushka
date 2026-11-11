"""Маленький клиент App Store Connect API: JWT подписывается через openssl, сторонние пакеты не нужны.

Идентификатор ключа и издателя берутся из переменных окружения ASC_KEY_ID и ASC_ISSUER_ID либо из файла
Tools/appstore/config.env (в git не попадает, образец — config.example.env). Сам ключ лежит вне репозитория:
~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8.
"""
import base64, json, os, subprocess, sys, time, urllib.error, urllib.request


def _config():
    values = {}
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.env")
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip()
    return values


_CONFIG = _config()
KEY_ID = os.environ.get("ASC_KEY_ID") or _CONFIG.get("ASC_KEY_ID")
ISSUER = os.environ.get("ASC_ISSUER_ID") or _CONFIG.get("ASC_ISSUER_ID")
if not KEY_ID or not ISSUER:
    sys.exit("Не заданы ASC_KEY_ID и ASC_ISSUER_ID: см. Tools/appstore/config.example.env")
KEY_PATH = os.path.expanduser(os.environ.get("ASC_KEY_PATH") or f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8")
BASE = "https://api.appstoreconnect.apple.com"


def _b64(b: bytes) -> bytes:
    return base64.urlsafe_b64encode(b).rstrip(b"=")


def token() -> str:
    head = _b64(json.dumps({"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}).encode())
    now = int(time.time())
    body = _b64(json.dumps({"iss": ISSUER, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}).encode())
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", KEY_PATH], input=head + b"." + body,
                         capture_output=True, check=True).stdout
    # DER SEQUENCE { INTEGER r, INTEGER s } -> 32-byte r || 32-byte s
    i = 2 if der[1] < 0x80 else 3
    r = der[i + 2:i + 2 + der[i + 1]]
    j = i + 2 + der[i + 1]
    s = der[j + 2:j + 2 + der[j + 1]]
    sig = r[-32:].rjust(32, b"\0") + s[-32:].rjust(32, b"\0")
    return (head + b"." + body + b"." + _b64(sig)).decode()


class APIError(Exception):
    def __init__(self, code, body):
        super().__init__(f"{code}: {body[:800]}")
        self.code = code


def call(method: str, path: str, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method,
                                 headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise APIError(e.code, e.read().decode())


def get(path):
    return call("GET", path)


def get_all(path):
    """Follows `links.next` and returns every item of `data`."""
    out, url = [], path
    while url:
        page = get(url)
        out += page.get("data", [])
        nxt = page.get("links", {}).get("next")
        url = nxt[len(BASE):] if nxt else None
    return out
