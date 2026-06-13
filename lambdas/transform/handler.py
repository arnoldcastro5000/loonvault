"""Transform Lambda — reads raw BoC Valet JSON from S3, writes to RDS and S3 snapshots."""
import json
import logging
import os
from datetime import date
from decimal import Decimal

import boto3
import psycopg2
import psycopg2.extras

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

_s3 = None
_secrets = None
_db_conn = None

RAW_BUCKET = os.environ["RAW_BUCKET"]
SNAPSHOTS_BUCKET = os.environ["SNAPSHOTS_BUCKET"]
DB_HOST = os.environ["DB_HOST"]
DB_NAME = os.environ["DB_NAME"]
DB_SECRET_ARN = os.environ["DB_SECRET_ARN"]
DB_SSL_CERT = os.environ.get("DB_SSL_CERT", "/opt/rds-ca-bundle.pem")
SNAPSHOT_LIMIT = 90


def _s3_client():
    global _s3
    if _s3 is None:
        _s3 = boto3.client("s3")
    return _s3


def _secrets_client():
    global _secrets
    if _secrets is None:
        _secrets = boto3.client("secretsmanager")
    return _secrets


def _get_db_conn():
    global _db_conn
    if _db_conn and not _db_conn.closed:
        return _db_conn
    secret = json.loads(
        _secrets_client().get_secret_value(SecretId=DB_SECRET_ARN)["SecretString"]
    )
    _db_conn = psycopg2.connect(
        host=DB_HOST,
        port=5432,
        dbname=DB_NAME,
        user=secret["writer_username"],
        password=secret["writer_password"],
        sslmode="verify-full",
        sslrootcert=DB_SSL_CERT,
    )
    return _db_conn


def handler(event: dict, _context: object) -> dict:
    processed = []
    for record in event.get("Records", []):
        body = json.loads(record["body"])
        for s3_record in body.get("Records", []):
            bucket = s3_record["s3"]["bucket"]["name"]
            key = s3_record["s3"]["object"]["key"]
            _process_object(bucket, key)
            processed.append(key)
    return {"processed": processed}


def _process_object(bucket: str, key: str) -> None:
    obj = _s3_client().get_object(Bucket=bucket, Key=key)
    raw = json.loads(obj["Body"].read())

    series_code = _extract_series_code(key)
    observations = _parse_observations(raw, series_code)
    if not observations:
        logger.warning("No observations found in %s", key)
        return

    conn = _get_db_conn()
    with conn.cursor() as cur:
        _upsert_indicator(cur, series_code)
        _upsert_observations(cur, series_code, observations)
    conn.commit()

    _write_snapshot(series_code, observations)
    logger.info("Processed %d observations for %s from %s", len(observations), series_code, key)


def _extract_series_code(key: str) -> str:
    # key format: raw/{series_code}/{year}/{month}/{day}.json
    return key.split("/")[1]


def _parse_observations(raw: dict, series_code: str) -> list[dict]:
    observations = []
    for obs in raw.get("observations", []):
        value = obs.get(series_code, {}).get("v")
        if value is None:
            continue
        observations.append({"date": obs["d"], "value": Decimal(str(value))})
    return observations


def _upsert_indicator(cur: psycopg2.extensions.cursor, series_code: str) -> None:
    cur.execute(
        """
        INSERT INTO indicators (code, kind, label)
        VALUES (%s, 'series', %s)
        ON CONFLICT (code) DO NOTHING
        """,
        (series_code, series_code),
    )


def _upsert_observations(
    cur: psycopg2.extensions.cursor,
    series_code: str,
    observations: list[dict],
) -> None:
    psycopg2.extras.execute_values(
        cur,
        """
        INSERT INTO series_observations (series_code, observed_on, value)
        VALUES %s
        ON CONFLICT (series_code, observed_on) DO UPDATE SET value = EXCLUDED.value
        """,
        [(series_code, obs["date"], obs["value"]) for obs in observations],
    )


def _write_snapshot(series_code: str, observations: list[dict]) -> None:
    recent = sorted(observations, key=lambda x: x["date"], reverse=True)[:SNAPSHOT_LIMIT]
    snapshot = {
        "code": series_code,
        "kind": "series",
        "observations": [
            {"date": obs["date"], "value": str(obs["value"])} for obs in recent
        ],
        "snapshot_at": date.today().isoformat(),
    }
    key = f"snapshots/series/{series_code}.json"
    _s3_client().put_object(
        Bucket=SNAPSHOTS_BUCKET,
        Key=key,
        Body=json.dumps(snapshot),
        ContentType="application/json",
    )
