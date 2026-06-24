#!/usr/bin/env bash
# shellcheck shell=bash

if [[ -n "${SEND_INVOICE_PHASE4_COMMON_SH_LOADED:-}" ]]; then
  return 0
fi
SEND_INVOICE_PHASE4_COMMON_SH_LOADED=1

phase4_root_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

phase4_worker_sidecar_dir() {
  printf '%s\n' "${WORKER_SIDECAR_DIR:-$(phase4_root_dir)/worker_sidecar}"
}

phase4_app_database_path() {
  printf '%s\n' "${DATABASE_PATH:-$(phase4_root_dir)/ruby_app/db/send_invoice.sqlite3}"
}

phase4_app_url() {
  printf '%s\n' "${APP_URL:-http://127.0.0.1:3000}"
}

phase4_queue_db_adapter() {
  case "${SEND_INVOICE_QUEUE_DB_ADAPTER:-sqlite3}" in
    postgresql|postgres|pg)
      printf 'postgresql\n'
      ;;
    ""|sqlite|sqlite3)
      printf 'sqlite3\n'
      ;;
    *)
      printf '%s\n' "$SEND_INVOICE_QUEUE_DB_ADAPTER"
      ;;
  esac
}

phase4_queue_database_path() {
  printf '%s\n' "${SEND_INVOICE_QUEUE_DATABASE_PATH:-$(phase4_worker_sidecar_dir)/storage/development_queue.sqlite3}"
}

phase4_queue_freshness_seconds() {
  printf '%s\n' "${QUEUE_HEALTH_FRESHNESS_SECONDS:-30}"
}

phase4_postgres_queue_database_url() {
  if [[ -n "${SEND_INVOICE_QUEUE_DATABASE_URL:-}" ]]; then
    printf '%s\n' "$SEND_INVOICE_QUEUE_DATABASE_URL"
    return 0
  fi

  local user password host port dbname params auth
  user="${SEND_INVOICE_QUEUE_DB_USER:-}"
  password="${SEND_INVOICE_QUEUE_DB_PASSWORD:-}"
  host="${SEND_INVOICE_QUEUE_DB_HOST:-127.0.0.1}"
  port="${SEND_INVOICE_QUEUE_DB_PORT:-5432}"
  dbname="${SEND_INVOICE_QUEUE_DB_NAME:-}"
  params="${SEND_INVOICE_QUEUE_DB_PARAMS:-}"

  if [[ -z "$dbname" ]]; then
    return 1
  fi

  auth="$user"
  if [[ -n "$password" ]]; then
    auth="${auth}:${password}"
  fi
  if [[ -n "$auth" ]]; then
    auth="${auth}@"
  fi

  printf 'postgresql://%s%s:%s/%s' "$auth" "$host" "$port" "$dbname"
  if [[ -n "$params" ]]; then
    printf '?%s' "$params"
  fi
  printf '\n'
}

phase4_require_commands() {
  local command_name
  for command_name in "$@"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "Required command not found: $command_name"
      return 1
    fi
  done
}

phase4_assert_app_database_exists() {
  local database_path
  database_path="$(phase4_app_database_path)"
  if [[ ! -f "$database_path" ]]; then
    PHASE4_HEALTH_ERROR="app DB unavailable: database not found at $database_path"
    echo "Database not found: $database_path"
    return 1
  fi
}

phase4_assert_queue_db_available() {
  local adapter queue_path
  adapter="$(phase4_queue_db_adapter)"

  case "$adapter" in
    sqlite3)
      queue_path="$(phase4_queue_database_path)"
      if [[ ! -f "$queue_path" ]]; then
        PHASE4_HEALTH_ERROR="queue DB unavailable: database not found at $queue_path"
        echo "Queue database not found: $queue_path"
        return 1
      fi
      ;;
    postgresql)
      if ! phase4_postgres_queue_database_url >/dev/null 2>&1; then
        PHASE4_HEALTH_ERROR="queue DB unavailable: Postgres env incomplete"
        echo "Queue database env incomplete for adapter=postgresql"
        echo "Set SEND_INVOICE_QUEUE_DATABASE_URL or SEND_INVOICE_QUEUE_DB_NAME with SEND_INVOICE_QUEUE_DB_HOST/PORT/USER/PASSWORD as needed"
        return 1
      fi
      ;;
    *)
      PHASE4_HEALTH_ERROR="queue DB unavailable: unsupported adapter $adapter"
      echo "Unsupported SEND_INVOICE_QUEUE_DB_ADAPTER: $adapter"
      return 1
      ;;
  esac
}

phase4_sql_escape() {
  local value
  value="${1//\'/\'\'}"
  printf "%s" "$value"
}

phase4_append_health_warning() {
  local message
  message="$1"
  [[ -z "$message" ]] && return 0

  if [[ -n "${PHASE4_HEALTH_WARNING:-}" ]]; then
    PHASE4_HEALTH_WARNING="${PHASE4_HEALTH_WARNING}; $message"
  else
    PHASE4_HEALTH_WARNING="$message"
  fi
}

phase4_app_health_ok() {
  local response_file app_url curl_status
  response_file="$(mktemp)"
  app_url="$(phase4_app_url)"

  if ! curl -fsS -o "$response_file" "$app_url/health"; then
    rm -f "$response_file"
    PHASE4_HEALTH_ERROR="app unavailable: GET $app_url/health failed"
    return 1
  fi

  if ! /usr/bin/ruby -rjson -e '
    payload = JSON.parse(File.read(ARGV[0]))
    abort("unexpected health payload: #{payload.inspect}") unless payload["status"] == "ok"
  ' "$response_file" >/dev/null 2>&1; then
    curl_status="$(tr '\n' ' ' <"$response_file")"
    rm -f "$response_file"
    PHASE4_HEALTH_ERROR="app unavailable: GET $app_url/health returned unexpected payload ${curl_status:-<empty>}"
    return 1
  fi

  rm -f "$response_file"
}

phase4_queue_metrics_sqlite() {
  local queue_path freshness_seconds
  queue_path="$(phase4_queue_database_path)"
  freshness_seconds="$(phase4_queue_freshness_seconds)"

  sqlite3 -readonly -noheader -separator '|' "$queue_path" <<SQL
WITH process_metrics AS (
  SELECT
    CASE
      WHEN kind LIKE 'Supervisor%' THEN 'Supervisor'
      ELSE kind
    END AS normalized_kind,
    CASE
      WHEN CAST(strftime('%s', 'now') - strftime('%s', last_heartbeat_at) AS INTEGER) < 0 THEN 0
      ELSE CAST(strftime('%s', 'now') - strftime('%s', last_heartbeat_at) AS INTEGER)
    END AS heartbeat_age_seconds
  FROM solid_queue_processes
),
queue_failure_metrics AS (
  SELECT
    COUNT(*) AS failed_execution_count,
    SUM(CASE WHEN LOWER(COALESCE(error, '')) LIKE '%database is locked%' THEN 1 ELSE 0 END) AS lock_failure_count
  FROM solid_queue_failed_executions
)
SELECT
  COALESCE(SUM(CASE WHEN normalized_kind = 'Supervisor' THEN 1 ELSE 0 END), 0),
  COALESCE(SUM(CASE WHEN normalized_kind = 'Worker' THEN 1 ELSE 0 END), 0),
  COALESCE(SUM(CASE WHEN normalized_kind = 'Scheduler' THEN 1 ELSE 0 END), 0),
  COALESCE(SUM(CASE WHEN normalized_kind = 'Supervisor' AND heartbeat_age_seconds <= ${freshness_seconds} THEN 1 ELSE 0 END), 0),
  COALESCE(SUM(CASE WHEN normalized_kind = 'Worker' AND heartbeat_age_seconds <= ${freshness_seconds} THEN 1 ELSE 0 END), 0),
  COALESCE(SUM(CASE WHEN normalized_kind = 'Scheduler' AND heartbeat_age_seconds <= ${freshness_seconds} THEN 1 ELSE 0 END), 0),
  COALESCE(MAX(CASE WHEN normalized_kind = 'Supervisor' THEN heartbeat_age_seconds END), -1),
  COALESCE(MAX(CASE WHEN normalized_kind = 'Worker' THEN heartbeat_age_seconds END), -1),
  COALESCE(MAX(CASE WHEN normalized_kind = 'Scheduler' THEN heartbeat_age_seconds END), -1),
  COALESCE((SELECT failed_execution_count FROM queue_failure_metrics), 0),
  COALESCE((SELECT lock_failure_count FROM queue_failure_metrics), 0)
FROM process_metrics;
SQL
}

phase4_queue_metrics_postgresql() {
  local freshness_seconds
  freshness_seconds="$(phase4_queue_freshness_seconds)"

  if [[ -n "${SEND_INVOICE_QUEUE_DATABASE_URL:-}" ]]; then
    PGPASSWORD="${SEND_INVOICE_QUEUE_DB_PASSWORD:-}" \
      psql "$SEND_INVOICE_QUEUE_DATABASE_URL" -X -A -t -F '|' -v ON_ERROR_STOP=1 <<SQL
WITH process_metrics AS (
  SELECT
    CASE
      WHEN kind LIKE 'Supervisor%%' THEN 'Supervisor'
      ELSE kind
    END AS normalized_kind,
    GREATEST(CAST(EXTRACT(EPOCH FROM NOW() - last_heartbeat_at) AS INTEGER), 0) AS heartbeat_age_seconds
  FROM solid_queue_processes
),
queue_failure_metrics AS (
  SELECT
    COUNT(*) AS failed_execution_count,
    SUM(CASE WHEN LOWER(COALESCE(error, '')) LIKE '%%database is locked%%' THEN 1 ELSE 0 END) AS lock_failure_count
  FROM solid_queue_failed_executions
)
SELECT
  COALESCE(SUM(CASE WHEN normalized_kind = 'Supervisor' THEN 1 ELSE 0 END), 0),
  COALESCE(SUM(CASE WHEN normalized_kind = 'Worker' THEN 1 ELSE 0 END), 0),
  COALESCE(SUM(CASE WHEN normalized_kind = 'Scheduler' THEN 1 ELSE 0 END), 0),
  COALESCE(SUM(CASE WHEN normalized_kind = 'Supervisor' AND heartbeat_age_seconds <= ${freshness_seconds} THEN 1 ELSE 0 END), 0),
  COALESCE(SUM(CASE WHEN normalized_kind = 'Worker' AND heartbeat_age_seconds <= ${freshness_seconds} THEN 1 ELSE 0 END), 0),
  COALESCE(SUM(CASE WHEN normalized_kind = 'Scheduler' AND heartbeat_age_seconds <= ${freshness_seconds} THEN 1 ELSE 0 END), 0),
  COALESCE(MAX(CASE WHEN normalized_kind = 'Supervisor' THEN heartbeat_age_seconds END), -1),
  COALESCE(MAX(CASE WHEN normalized_kind = 'Worker' THEN heartbeat_age_seconds END), -1),
  COALESCE(MAX(CASE WHEN normalized_kind = 'Scheduler' THEN heartbeat_age_seconds END), -1),
  COALESCE((SELECT failed_execution_count FROM queue_failure_metrics), 0),
  COALESCE((SELECT lock_failure_count FROM queue_failure_metrics), 0)
FROM process_metrics;
SQL
  else
    PGHOST="${SEND_INVOICE_QUEUE_DB_HOST:-127.0.0.1}" \
      PGPORT="${SEND_INVOICE_QUEUE_DB_PORT:-5432}" \
      PGDATABASE="${SEND_INVOICE_QUEUE_DB_NAME}" \
      PGUSER="${SEND_INVOICE_QUEUE_DB_USER:-}" \
      PGPASSWORD="${SEND_INVOICE_QUEUE_DB_PASSWORD:-}" \
      psql -X -A -t -F '|' -v ON_ERROR_STOP=1 <<SQL
WITH process_metrics AS (
  SELECT
    CASE
      WHEN kind LIKE 'Supervisor%%' THEN 'Supervisor'
      ELSE kind
    END AS normalized_kind,
    GREATEST(CAST(EXTRACT(EPOCH FROM NOW() - last_heartbeat_at) AS INTEGER), 0) AS heartbeat_age_seconds
  FROM solid_queue_processes
),
queue_failure_metrics AS (
  SELECT
    COUNT(*) AS failed_execution_count,
    SUM(CASE WHEN LOWER(COALESCE(error, '')) LIKE '%%database is locked%%' THEN 1 ELSE 0 END) AS lock_failure_count
  FROM solid_queue_failed_executions
)
SELECT
  COALESCE(SUM(CASE WHEN normalized_kind = 'Supervisor' THEN 1 ELSE 0 END), 0),
  COALESCE(SUM(CASE WHEN normalized_kind = 'Worker' THEN 1 ELSE 0 END), 0),
  COALESCE(SUM(CASE WHEN normalized_kind = 'Scheduler' THEN 1 ELSE 0 END), 0),
  COALESCE(SUM(CASE WHEN normalized_kind = 'Supervisor' AND heartbeat_age_seconds <= ${freshness_seconds} THEN 1 ELSE 0 END), 0),
  COALESCE(SUM(CASE WHEN normalized_kind = 'Worker' AND heartbeat_age_seconds <= ${freshness_seconds} THEN 1 ELSE 0 END), 0),
  COALESCE(SUM(CASE WHEN normalized_kind = 'Scheduler' AND heartbeat_age_seconds <= ${freshness_seconds} THEN 1 ELSE 0 END), 0),
  COALESCE(MAX(CASE WHEN normalized_kind = 'Supervisor' THEN heartbeat_age_seconds END), -1),
  COALESCE(MAX(CASE WHEN normalized_kind = 'Worker' THEN heartbeat_age_seconds END), -1),
  COALESCE(MAX(CASE WHEN normalized_kind = 'Scheduler' THEN heartbeat_age_seconds END), -1),
  COALESCE((SELECT failed_execution_count FROM queue_failure_metrics), 0),
  COALESCE((SELECT lock_failure_count FROM queue_failure_metrics), 0)
FROM process_metrics;
SQL
  fi
}

phase4_sidecar_health_ok() {
  local adapter metrics query_output exit_code
  adapter="$(phase4_queue_db_adapter)"

  case "$adapter" in
    sqlite3)
      if ! command -v sqlite3 >/dev/null 2>&1; then
        PHASE4_HEALTH_ERROR="queue DB unavailable: sqlite3 is required for adapter=sqlite3"
        return 1
      fi
      query_output="$(phase4_queue_metrics_sqlite 2>&1)" || exit_code=$?
      ;;
    postgresql)
      if ! command -v psql >/dev/null 2>&1; then
        PHASE4_HEALTH_ERROR="queue DB unavailable: psql is required for adapter=postgresql"
        return 1
      fi
      query_output="$(phase4_queue_metrics_postgresql 2>&1)" || exit_code=$?
      ;;
    *)
      PHASE4_HEALTH_ERROR="queue DB unavailable: unsupported SEND_INVOICE_QUEUE_DB_ADAPTER=$adapter"
      return 1
      ;;
  esac

  if [[ "${exit_code:-0}" -ne 0 ]]; then
    PHASE4_HEALTH_ERROR="queue DB unavailable: ${query_output//$'\n'/ }"
    return 1
  fi

  IFS='|' read -r PHASE4_TOTAL_SUPERVISORS PHASE4_TOTAL_WORKERS PHASE4_TOTAL_SCHEDULERS \
    PHASE4_FRESH_SUPERVISORS PHASE4_FRESH_WORKERS PHASE4_FRESH_SCHEDULERS \
    PHASE4_MAX_SUPERVISOR_AGE PHASE4_MAX_WORKER_AGE PHASE4_MAX_SCHEDULER_AGE \
    PHASE4_FAILED_EXECUTION_COUNT PHASE4_LOCK_FAILURE_COUNT <<<"$query_output"

  if [[ "${PHASE4_FRESH_WORKERS:-0}" -lt 1 ]]; then
    PHASE4_HEALTH_ERROR="no fresh worker heartbeat within $(phase4_queue_freshness_seconds)s"
    return 1
  fi

  if [[ "${PHASE4_FRESH_SUPERVISORS:-0}" -lt 1 ]]; then
    PHASE4_HEALTH_ERROR="no fresh supervisor registration within $(phase4_queue_freshness_seconds)s"
    return 1
  fi

  if [[ "${PHASE4_FRESH_SCHEDULERS:-0}" -lt 1 ]]; then
    PHASE4_HEALTH_ERROR="no fresh scheduler registration within $(phase4_queue_freshness_seconds)s"
    return 1
  fi

  PHASE4_HEALTH_WARNING=""
  if [[ "${PHASE4_TOTAL_SUPERVISORS:-0}" -gt "${PHASE4_FRESH_SUPERVISORS:-0}" ]] || \
     [[ "${PHASE4_TOTAL_WORKERS:-0}" -gt "${PHASE4_FRESH_WORKERS:-0}" ]] || \
     [[ "${PHASE4_TOTAL_SCHEDULERS:-0}" -gt "${PHASE4_FRESH_SCHEDULERS:-0}" ]]; then
    phase4_append_health_warning "stale sidecar process rows present, but a fresh live set is registered"
  fi

  if [[ "$adapter" == "sqlite3" ]] && [[ "${PHASE4_FRESH_SUPERVISORS:-0}" -gt 1 ]]; then
    phase4_append_health_warning "multiple fresh supervisors detected for SQLite queue DB; duplicate sidecars are likely"
  fi

  if [[ "${PHASE4_LOCK_FAILURE_COUNT:-0}" -gt 0 ]]; then
    phase4_append_health_warning "queue DB has ${PHASE4_LOCK_FAILURE_COUNT} recorded failed execution(s) matching 'database is locked'"
  fi

  PHASE4_SIDECAR_HEALTH_SUMMARY="sidecar health ok: adapter=$adapter fresh supervisor=${PHASE4_FRESH_SUPERVISORS}/${PHASE4_TOTAL_SUPERVISORS} worker=${PHASE4_FRESH_WORKERS}/${PHASE4_TOTAL_WORKERS} scheduler=${PHASE4_FRESH_SCHEDULERS}/${PHASE4_TOTAL_SCHEDULERS} failed_executions=${PHASE4_FAILED_EXECUTION_COUNT:-0} lock_failures=${PHASE4_LOCK_FAILURE_COUNT:-0} freshness_window=$(phase4_queue_freshness_seconds)s"
}

phase4_health_gate() {
  PHASE4_HEALTH_ERROR=""
  PHASE4_HEALTH_WARNING=""
  PHASE4_SIDECAR_HEALTH_SUMMARY=""

  phase4_assert_app_database_exists || return 1
  phase4_assert_queue_db_available || return 1
  phase4_app_health_ok || return 1
  phase4_sidecar_health_ok || return 1
}

phase4_duplicate_sidecars_detected() {
  [[ "$(phase4_queue_db_adapter)" == "sqlite3" ]] && [[ "${PHASE4_FRESH_SUPERVISORS:-0}" -gt 1 ]]
}

phase4_abort_on_duplicate_sidecars() {
  local context
  context="${1:-Phase 4 command}"

  if ! phase4_duplicate_sidecars_detected; then
    return 0
  fi

  echo "$context aborted before enqueue: multiple fresh supervisors detected for SQLite queue DB"
  echo "$PHASE4_SIDECAR_HEALTH_SUMMARY"
  if [[ -n "${PHASE4_HEALTH_WARNING:-}" ]]; then
    echo "Warning: $PHASE4_HEALTH_WARNING"
  fi
  echo "Stop the extra sidecar and rerun. If this was intentional, restart the extra sidecar only with SEND_INVOICE_ALLOW_DUPLICATE_SIDECARS=1."
  return 1
}
