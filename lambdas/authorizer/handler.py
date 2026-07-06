"""Lambda authorizer for HTTP API v2 — validates X-Origin-Secret header."""
import hmac
import logging
import os
import time

import boto3

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

_ssm = None
_cached_secret: str | None = None
_cache_expires: float = 0.0
_CACHE_TTL = 300  # seconds — refreshes on warm Lambda invocations


def _ssm_client():
    global _ssm
    if _ssm is None:
        _ssm = boto3.client("ssm", region_name=os.environ["AWS_REGION"])
    return _ssm


def _get_expected_secret() -> str:
    global _cached_secret, _cache_expires
    now = time.monotonic()
    if _cached_secret and now < _cache_expires:
        return _cached_secret
    param = _ssm_client().get_parameter(
        Name=os.environ["ORIGIN_SECRET_SSM_PATH"],
        WithDecryption=True,
    )
    _cached_secret = param["Parameter"]["Value"]
    _cache_expires = now + _CACHE_TTL
    return _cached_secret


def handler(event: dict, _context: object) -> dict:
    headers: dict = event.get("headers") or {}
    # Header names are lowercased by API Gateway v2
    token: str | None = headers.get("x-origin-secret")
    if not token:
        logger.info("Request missing X-Origin-Secret header — denied")
        return {"isAuthorized": False}
    try:
        expected = _get_expected_secret()
    except Exception:
        logger.exception("Failed to retrieve origin secret from SSM — denied")
        return {"isAuthorized": False}
    # Constant-time compare — same as the site Lambda; a plain != leaks
    # match-prefix length through response timing.
    if not hmac.compare_digest(token, expected):
        logger.info("X-Origin-Secret mismatch — denied")
        return {"isAuthorized": False}
    return {"isAuthorized": True}
