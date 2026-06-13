-- LoonVault database initialisation
-- Run once after terraform apply, against the RDS master user.
-- This is step 2 of the post-apply runbook — see docs/runbook.md.
--
-- Usage (from developer terminal, inside VPC or via RDS Proxy):
--   psql "host=<rds_endpoint> dbname=loonvault user=loonvault_admin sslmode=verify-full" \
--        -f scripts/db-init.sql
--   (or: just loonvault-db-init "$(terraform -chdir=infra/loonvault output -raw rds_endpoint)")
--
-- Authentication: the application users (lv_reader / lv_writer) use RDS IAM
-- authentication (ADR-0006) — they have no password. The Lambdas generate a short-lived
-- IAM token at connect time. There is no Secrets Manager secret to populate; this script
-- is the only credential-provisioning step.
-- ─────────────────────────────────────────────────────────────────────────────

-- Extensions (pgaudit loaded via parameter group; uuid for future use)
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ── Application roles ─────────────────────────────────────────────────────────
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_reader') THEN
        CREATE ROLE role_reader NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'role_writer') THEN
        CREATE ROLE role_writer NOLOGIN;
    END IF;
END
$$;

-- ── Login users (RDS IAM authentication — no passwords) ───────────────────────
-- lv_reader / lv_writer authenticate with short-lived IAM tokens, not passwords.
-- The rds_iam role grant delegates authentication to AWS IAM (ADR-0006).
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'lv_reader') THEN
        CREATE USER lv_reader WITH LOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'lv_writer') THEN
        CREATE USER lv_writer WITH LOGIN;
    END IF;
END
$$;

-- Delegate authentication to IAM (RDS-managed role; requires IAM auth enabled on the instance)
GRANT rds_iam TO lv_reader;
GRANT rds_iam TO lv_writer;

-- Table privileges still come from the NOLOGIN roles
GRANT role_reader TO lv_reader;
GRANT role_writer TO lv_writer;

-- ── Schema ─────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS indicators (
    code  TEXT PRIMARY KEY,
    kind  TEXT NOT NULL CHECK (kind IN ('series', 'pressure_metric')),
    label TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS series_observations (
    series_code TEXT        NOT NULL REFERENCES indicators(code),
    observed_on DATE        NOT NULL,
    value       NUMERIC(18, 6) NOT NULL,
    PRIMARY KEY (series_code, observed_on)
);

CREATE INDEX IF NOT EXISTS idx_series_observations_code_date
    ON series_observations (series_code, observed_on DESC);

-- ── Grants ────────────────────────────────────────────────────────────────────
-- Revoke default public schema access first
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO role_reader, role_writer;

GRANT SELECT ON indicators, series_observations TO role_reader;
GRANT INSERT, UPDATE ON indicators, series_observations TO role_writer;

-- Future tables inherit these defaults
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT ON TABLES TO role_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT INSERT, UPDATE ON TABLES TO role_writer;

-- ── Seed FXCADUSD indicator row ───────────────────────────────────────────────
INSERT INTO indicators (code, kind, label)
VALUES ('FXCADUSD', 'series', 'CAD/USD Exchange Rate')
ON CONFLICT (code) DO NOTHING;
