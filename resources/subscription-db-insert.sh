#!/usr/bin/env bash
set -euo pipefail

# Distinct error codes
ERR_MISSING_ENV=10
ERR_PSQL_NOT_FOUND=11
ERR_CSV_NOT_FOUND=12
ERR_DB_CONNECT=13
ERR_CREATE_TABLE=14
ERR_IMPORT_CSV=15
ERR_WAIT_FAILED=16
ERR_WAIT_TIMEOUT=17

: "${PGHOST:?Missing PGHOST}" || exit "${ERR_MISSING_ENV}"
: "${PGDATABASE:?Missing PGDATABASE}" || exit "${ERR_MISSING_ENV}"
: "${PGUSER:?Missing PGUSER}" || exit "${ERR_MISSING_ENV}"
: "${PGPASSWORD:?Missing PGPASSWORD}" || exit "${ERR_MISSING_ENV}"
: "${PGPORT:=5432}"
export PGPASSWORD

CSV_PATH="/tmp/data.csv"

DONE_FILE="/tmp/done.txt"
FAIL_FILE="/tmp/fail.txt"

: "${WAIT_INTERVAL_SECONDS:=5}"
: "${WAIT_MAX_SECONDS:=0}"
: "${RETENTION_DAYS:=730}"

if ! command -v psql >/dev/null 2>&1; then
  echo "ERROR: psql not found in PATH" >&2
  exit "${ERR_PSQL_NOT_FOUND}"
fi

echo "INFO: Waiting for ${DONE_FILE} (fail=${FAIL_FILE})"
echo "INFO: Interval=${WAIT_INTERVAL_SECONDS}s Timeout=${WAIT_MAX_SECONDS}s (0=infinite)"

start_epoch="$(date +%s)"

while true; do
  now_epoch="$(date +%s)"
  elapsed="$((now_epoch - start_epoch))"

  echo "WAIT: elapsed=${elapsed}s checking files..."

  if [[ -f "${FAIL_FILE}" ]]; then
    echo "ERROR: Detected fail file: ${FAIL_FILE}"
    exit "${ERR_WAIT_FAILED}"
  fi

  if [[ -f "${DONE_FILE}" ]]; then
    echo "INFO: Detected done file: ${DONE_FILE}"
    break
  fi

  if [[ "${WAIT_MAX_SECONDS}" -gt 0 ]] && [[ "${elapsed}" -ge "${WAIT_MAX_SECONDS}" ]]; then
    echo "ERROR: Timeout after ${WAIT_MAX_SECONDS}s waiting for ${DONE_FILE}"
    exit "${ERR_WAIT_TIMEOUT}"
  fi

  echo "WAIT: sleeping ${WAIT_INTERVAL_SECONDS}s..."
  sleep "${WAIT_INTERVAL_SECONDS}"
done

echo "INFO: Proceeding with database operations..."

if [[ ! -f "${CSV_PATH}" ]]; then
  echo "ERROR: CSV not found: ${CSV_PATH}" >&2
  exit "${ERR_CSV_NOT_FOUND}"
fi

# Remove empty lines from CSV (trailing newlines from cat *.csv can cause COPY errors)
sed -i '/^[[:space:]]*$/d' "${CSV_PATH}"

CSV_LINES="$(wc -l < "${CSV_PATH}" | tr -d ' ')"
echo "INFO: CSV content (${CSV_LINES} lines):"
echo "---"
cat "${CSV_PATH}"
echo "---"

if ! psql -v ON_ERROR_STOP=1 -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -c 'SELECT 1;' >/dev/null 2>&1; then
  echo "ERROR: Cannot connect to ${PGDATABASE} at ${PGHOST}:${PGPORT}" >&2
  exit "${ERR_DB_CONNECT}"
fi

if ! psql -v ON_ERROR_STOP=1 -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" <<'SQL'
BEGIN;

CREATE TABLE IF NOT EXISTS subscription (
  id BIGSERIAL PRIMARY KEY,
  acm VARCHAR,
  cluster VARCHAR,
  clusterid VARCHAR,
  type VARCHAR,
  node VARCHAR,
  cpu INTEGER,
  providerid VARCHAR,
  date TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMIT;
SQL
then
  echo "ERROR: Failed to create table subscription" >&2
  exit "${ERR_CREATE_TABLE}"
fi

if ! psql -v ON_ERROR_STOP=1 -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" <<SQL
BEGIN;

CREATE TEMP TABLE subscription_import (
  acm VARCHAR,
  cluster VARCHAR,
  clusterid VARCHAR,
  type VARCHAR,
  node VARCHAR,
  cpu INTEGER,
  providerid VARCHAR
) ON COMMIT DROP;

\\copy subscription_import(acm,cluster,clusterid,type,node,cpu,providerid) FROM '${CSV_PATH}' WITH (FORMAT csv, HEADER false);

INSERT INTO subscription (acm, cluster, clusterid, type, node, cpu, providerid)
SELECT acm, cluster, clusterid, type, node, cpu, providerid
FROM subscription_import;

COMMIT;
SQL
then
  echo "ERROR: Failed to import CSV into ${PGDATABASE}.subscription" >&2
  exit "${ERR_IMPORT_CSV}"
fi

echo "INFO: Purging records older than ${RETENTION_DAYS} days..."

DELETED_COUNT="$(psql -v ON_ERROR_STOP=1 -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -tA \
  -c "WITH d AS (DELETE FROM subscription WHERE date < NOW() - INTERVAL '${RETENTION_DAYS} days' RETURNING 1) SELECT count(*) FROM d;")"

echo "INFO: Purged ${DELETED_COUNT} record(s) older than ${RETENTION_DAYS} days"

echo "OK: Table created (if needed), CSV imported, and retention applied (${RETENTION_DAYS} days) on ${PGDATABASE}.subscription"
