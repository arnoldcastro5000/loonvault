-- LoonVault database initialisation
-- Run once after terraform apply, against the RDS master user.
--
-- Usage (from developer terminal, inside VPC or via RDS Proxy):
--   psql "host=<rds_endpoint> dbname=loonvault user=loonvault_admin sslmode=verify-full" \
--        -f scripts/db-init.sql
--
-- After running:
--   1. Set reader_password and writer_password in Secrets Manager:
--      aws secretsmanager put-secret-value \
--        --secret-id loonvault/db-credentials \
--        --secret-string '{"reader_username":"lv_reader","reader_password":"<gen>",
--                          "writer_username":"lv_writer","writer_password":"<gen>"}'
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

-- ── Login users ───────────────────────────────────────────────────────────────
-- Passwords are placeholders; operator must set real values then update the
-- Secrets Manager secret before any Lambda can connect.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'lv_reader') THEN
        CREATE USER lv_reader WITH PASSWORD 'REPLACE_ME' LOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'lv_writer') THEN
        CREATE USER lv_writer WITH PASSWORD 'REPLACE_ME' LOGIN;
    END IF;
END
$$;

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
