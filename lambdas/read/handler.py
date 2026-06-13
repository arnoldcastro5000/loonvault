"""Read Lambda — serves Series Observations from RDS via the public API."""
import json
import logging
import os
from decimal import Decimal

import boto3
import psycopg2

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

_rds = None
_db_conn = None

DB_HOST = os.environ["DB_HOST"]
DB_NAME = os.environ["DB_NAME"]
DB_USER = os.environ["DB_USER"]
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_SSL_CERT = os.environ.get("DB_SSL_CERT", "/opt/rds-ca-bundle.pem")
DEFAULT_LIMIT = 90
MAX_LIMIT = 365


def _rds_client():
    global _rds
    if _rds is None:
        _rds = boto3.client("rds")
    return _rds


def _get_db_conn():
    global _db_conn
    if _db_conn and not _db_conn.closed:
        return _db_conn
    # RDS IAM auth: token is signed locally (SigV4) from the execution-role credentials —
    # no Secrets Manager call, no network round-trip. Valid 15 min; only needed at connect.
    token = _rds_client().generate_db_auth_token(
        DBHostname=DB_HOST,
        Port=DB_PORT,
        DBUsername=DB_USER,
    )
    _db_conn = psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=token,
        sslmode="verify-full",
        sslrootcert=DB_SSL_CERT,
    )
    return _db_conn


def _json_default(obj: object) -> str:
    if isinstance(obj, Decimal):
        return str(obj)
    raise TypeError(f"Object of type {type(obj)} is not JSON serializable")


def handler(event: dict, _context: object) -> dict:
    params = event.get("pathParameters") or {}
    series_code = params.get("code")
    if not series_code:
        return _response(400, {"error": "Missing series code"})

    query_params = event.get("queryStringParameters") or {}
    try:
        limit = min(int(query_params.get("limit", DEFAULT_LIMIT)), MAX_LIMIT)
    except ValueError:
        return _response(400, {"error": "Invalid limit parameter"})

    try:
        indicator = _get_indicator(series_code)
        if not indicator:
            return _response(404, {"error": "Series not found"})
        observations = _get_observations(series_code, limit)
    except Exception:
        # G-06: return opaque error — internal detail logged, never returned to caller
        logger.exception("Database error for series %s", series_code)
        return _response(500, {"error": "Internal server error"})

    return _response(200, {
        "code": indicator["code"],
        "kind": indicator["kind"],
        "label": indicator["label"],
        "observations": observations,
    })


def _get_indicator(series_code: str) -> dict | None:
    conn = _get_db_conn()
    with conn.cursor() as cur:
        cur.execute(
            "SELECT code, kind, label FROM indicators WHERE code = %s",
            (series_code,),
        )
        row = cur.fetchone()
    if not row:
        return None
    return {"code": row[0], "kind": row[1], "label": row[2]}


def _get_observations(series_code: str, limit: int) -> list[dict]:
    conn = _get_db_conn()
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT observed_on, value
            FROM series_observations
            WHERE series_code = %s
            ORDER BY observed_on DESC
            LIMIT %s
            """,
            (series_code, limit),
        )
        rows = cur.fetchall()
    return [{"date": str(row[0]), "value": str(row[1])} for row in rows]


def _response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, default=_json_default),
    }
