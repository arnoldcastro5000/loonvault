"""Origin-protected static-site server (ADR-0013).

Sits behind a Lambda Function URL, behind Cloudflare. Cloudflare injects the shared
origin secret (X-Origin-Secret); this validates it (cached from SSM SecureString),
serves the requested object from the PRIVATE site bucket, and returns it with a strict
set of HTTP security headers. No third-party deps (boto3 ships in the runtime).
"""
import base64
import hmac
import os
import re
import secrets

import boto3

# Strict allowlist for resolved object keys — defeats path traversal / unexpected
# input before it ever reaches S3 (only safe static-asset key characters).
_SAFE_KEY = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._/-]*\Z")

# CSP fallback (Terraform normally supplies the CSP env). The "__NONCE__" slot is replaced
# per request on HTML responses with a fresh nonce; Cloudflare parses the nonce from this
# response header and stamps its injected JS-detection/bot script with it, so that edge
# feature runs without 'unsafe-inline' (ADR-0013, per Cloudflare's CSP guidance).
_DEFAULT_CSP = (
    "default-src 'self'; script-src 'self' 'nonce-__NONCE__'; "
    "object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
)

_s3 = None
_ssm = None
_secret = None

# Text content types are returned as UTF-8; everything else is base64-encoded.
_CONTENT_TYPES = {
    "html": "text/html; charset=utf-8",
    "css": "text/css; charset=utf-8",
    "js": "text/javascript; charset=utf-8",
    "json": "application/json; charset=utf-8",
    "md": "text/markdown; charset=utf-8",
    "txt": "text/plain; charset=utf-8",
    "svg": "image/svg+xml",
    "woff2": "font/woff2",
    "png": "image/png",
    "ico": "image/x-icon",
    "webp": "image/webp",
}
_TEXT = {"html", "css", "js", "json", "md", "txt", "svg"}


def _s3_client():
    global _s3
    if _s3 is None:
        _s3 = boto3.client("s3", region_name=os.environ["AWS_REGION"])
    return _s3


def _origin_secret():
    global _secret
    if _secret is None:
        global _ssm
        if _ssm is None:
            _ssm = boto3.client("ssm", region_name=os.environ["AWS_REGION"])
        _secret = _ssm.get_parameter(
            Name=os.environ["ORIGIN_SECRET_SSM_PATH"], WithDecryption=True
        )["Parameter"]["Value"]
    return _secret


def _security_headers(content_type, cache_control, csp):
    return {
        "content-type": content_type,
        "cache-control": cache_control,
        "content-security-policy": csp,
        "strict-transport-security": "max-age=63072000; includeSubDomains; preload",
        "x-content-type-options": "nosniff",
        "x-frame-options": "DENY",
        "referrer-policy": "no-referrer",
        "permissions-policy": "geolocation=(), camera=(), microphone=()",
        "cross-origin-opener-policy": "same-origin",
    }


def _resp(status, body, headers=None, b64=False):
    return {
        "statusCode": status,
        "headers": headers or {"content-type": "text/plain; charset=utf-8"},
        "body": body,
        "isBase64Encoded": b64,
    }


def _key_for(path):
    key = path.lstrip("/")
    if key == "" or key.endswith("/"):
        key += "index.html"
    return key


def handler(event, _context):
    headers = event.get("headers") or {}
    provided = headers.get("x-origin-secret", "")
    try:
        expected = _origin_secret()
    except Exception:
        return _resp(503, "origin secret unavailable")
    # Constant-time compare; reject if missing/wrong (blocks non-Cloudflare access).
    if not provided or not hmac.compare_digest(provided, expected):
        return _resp(403, "forbidden")

    path = event.get("rawPath", "/")
    key = _key_for(path)
    if ".." in key or not _SAFE_KEY.match(key):
        return _resp(400, "bad request")
    ext = key.rsplit(".", 1)[-1].lower() if "." in key else ""
    content_type = _CONTENT_TYPES.get(ext, "application/octet-stream")

    try:
        obj = _s3_client().get_object(Bucket=os.environ["SITE_BUCKET"], Key=key)
    except Exception:
        return _resp(404, "not found")

    # HTML carries a fresh per-request CSP nonce and must NOT be cached (a cached nonce
    # would be reused); assets cache hard and bear no scripts, so the nonce slot is dropped.
    csp = os.environ.get("CSP", _DEFAULT_CSP)
    if ext == "html":
        csp = csp.replace("__NONCE__", secrets.token_urlsafe(16))
        cache_control = "no-store"
    else:
        csp = csp.replace(" 'nonce-__NONCE__'", "")
        cache_control = "public, max-age=86400"

    data = obj["Body"].read()
    sec = _security_headers(content_type, cache_control, csp)
    if ext in _TEXT:
        return _resp(200, data.decode("utf-8"), sec, b64=False)
    return _resp(200, base64.b64encode(data).decode("ascii"), sec, b64=True)
