"""Ingest Lambda — fetches Series observations from BoC Valet and writes to S3 raw zone."""
import json
import logging
import os
from datetime import date

import boto3
import requests

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

_s3 = None
RAW_BUCKET = os.environ["RAW_BUCKET"]
BOC_VALET_BASE = "https://www.bankofcanada.ca/valet"
SERIES_CODES = ["FXCADUSD"]
REQUEST_TIMEOUT = 10


def _s3_client():
    global _s3
    if _s3 is None:
        _s3 = boto3.client("s3")
    return _s3


def handler(event: dict, _context: object) -> dict:
    today = date.today()
    ingested = []

    for series_code in SERIES_CODES:
        url = f"{BOC_VALET_BASE}/observations/{series_code}/json"
        response = requests.get(url, timeout=REQUEST_TIMEOUT)
        response.raise_for_status()
        payload = response.json()

        key = (
            f"raw/{series_code}"
            f"/{today.year}/{today.month:02d}/{today.day:02d}.json"
        )
        _s3_client().put_object(
            Bucket=RAW_BUCKET,
            Key=key,
            Body=json.dumps(payload),
            ContentType="application/json",
        )
        logger.info("Ingested %s → s3://%s/%s", series_code, RAW_BUCKET, key)
        ingested.append({"series_code": series_code, "key": key})

    return {"ingested": ingested}
