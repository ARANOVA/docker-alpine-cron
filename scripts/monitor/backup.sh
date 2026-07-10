#!/bin/bash
set -eo pipefail

# =============================================================================
# Backup Monitor Script
# =============================================================================
# Checks CronJob backup status in a Kubernetes cluster:
#   0. PostgreSQL DB coverage audit (finds databases missing from backup config)
#   1. CronJob last-schedule / last-success age checks
#   2. Recent Job failure counts
#   3. S3 file freshness (today's backups present)
#
# Designed to run inside the docker-alpine-cron image (has aws-cli, jq, bash).
# All configuration is driven by environment variables — see functions.
# =============================================================================

. /monitor/functions

# ── Read all config from environment or *_FILE secrets ─────────────────────
file_env "MONITOR_NAMESPACE"          "backup"
file_env "MONITOR_API_URL"            "https://kubernetes.default.svc.cluster.local"
file_env "MONITOR_CA"                 "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
file_env "MONITOR_TOKEN_FILE"         "/var/run/secrets/kubernetes.io/serviceaccount/token"
file_env "MONITOR_TOKEN"              ""
file_env "MONITOR_TIMEZONE"           "Europe/Madrid"
file_env "MONITOR_S3_BASE"            "s3://backup.aranova.es/docker"
file_env "MONITOR_S3_MAPPING"         ""
file_env "MONITOR_S3_MAPPING_FILE"    ""
file_env "MONITOR_S3_CHECK"           "true"
file_env "MONITOR_PG_AUDIT"           "true"
file_env "MONITOR_PG_CJ_NAME"         "admin-postgresql-backup"
file_env "MONITOR_PG_SERVER"          ""
file_env "MONITOR_PG_USER"            "postgres"
file_env "MONITOR_DAILY_MAX_HOURS"    "30"
file_env "MONITOR_DAILY_WARN_HOURS"   "26"
file_env "MONITOR_WEEKLY_MAX_HOURS"   "192"
file_env "MONITOR_EXCLUDE"            ""

# Ensure jq is available
if ! command -v jq &>/dev/null; then
  apk add -q jq 2>/dev/null || true
fi

# =============================================================================
# Step 1: Check each CronJob — status, failures, S3
# =============================================================================
run_cronjob_checks() {
  local cj_json="$1"

  local cj_names
  cj_names=$(echo "$cj_json" | jq -r '.items[]?.metadata.name // empty')

  if [ -z "$cj_names" ]; then
    log_warn "No CronJobs found in namespace '$MONITOR_NAMESPACE'"
    return
  fi

  # Parse exclude list (comma-separated)
  IFS=',' read -ra EXCLUDE <<< "${MONITOR_EXCLUDE:-}"

  while IFS= read -r CJ_NAME; do
    # Skip excluded CronJobs
    for ex in "${EXCLUDE[@]}"; do
      [ -n "$ex" ] && [ "$CJ_NAME" = "$ex" ] && continue 2
    done
    echo "──────────────────────────────────────────────────────"
    echo "  CronJob: $CJ_NAME"

    local cj suspended last_schedule last_success schedule
    cj=$(echo "$cj_json" | jq -r --arg n "$CJ_NAME" \
      '.items[] | select(.metadata.name==$n)')
    suspended=$(echo "$cj" | jq -r '.spec.suspend // false')

    if [ "$suspended" = "true" ]; then
      log_info "SUSPENDED — skipping checks"
      echo ""
      continue
    fi

    last_schedule=$(echo "$cj" | jq -r '.status.lastScheduleTime // ""')
    last_success=$(echo "$cj" | jq -r '.status.lastSuccessfulTime // ""')
    schedule=$(echo "$cj" | jq -r '.spec.schedule // ""')

    echo "  schedule:       $schedule"
    echo "  lastSchedule:   ${last_schedule:-never}"
    echo "  lastSuccess:    ${last_success:-never}"

    # Never executed
    if [ -z "$last_schedule" ]; then
      log_warn "Never scheduled — new or misconfigured CronJob"
      echo ""
      continue
    fi

    # Check if last run failed
    if [ -n "$last_schedule" ] && [ -z "$last_success" ]; then
      log_fail "Last scheduled run NEVER succeeded"
    elif [ -n "$last_success" ]; then
      local ts_sched ts_succ now_ts age_hours
      # Normalize ISO 8601 timestamps for busybox date
      # "2026-07-10T07:38:30Z" → "2026-07-10 07:38:30"
      local last_schedule_clean last_success_clean
      last_schedule_clean=$(echo "$last_schedule" | sed 's/T/ /; s/Z$//')
      last_success_clean=$(echo "$last_success" | sed 's/T/ /; s/Z$//')

      ts_sched=$(date -d "$last_schedule_clean" +%s 2>/dev/null || echo 0)
      ts_succ=$(date -d "$last_success_clean" +%s 2>/dev/null || echo 0)
      now_ts=$(date +%s)

      if [ "$ts_succ" -ge "$ts_sched" ]; then
        log_ok "Last run succeeded ($last_success)"
      else
        log_fail "Last schedule ($last_schedule) > last success ($last_success)"
      fi

      age_hours=$(( (now_ts - ts_succ) / 3600 ))

      # Weekly cronjobs (day-of-week = 0, Sunday only)
      if echo "$schedule" | grep -qE "^[0-9*]+ [0-9*]+ [0-9*]+ [0-9*]+ 0$"; then
        if [ "$age_hours" -gt "$MONITOR_WEEKLY_MAX_HOURS" ]; then
          log_warn "Weekly backup — last success ${age_hours}h ago (> $MONITOR_WEEKLY_MAX_HOURS h)"
        else
          log_ok "Weekly backup — last success within window (${age_hours}h ago)"
        fi
      else
        if [ "$age_hours" -gt "$MONITOR_DAILY_MAX_HOURS" ]; then
          log_fail "Daily backup — last success ${age_hours}h ago (> ${MONITOR_DAILY_MAX_HOURS}h)"
        elif [ "$age_hours" -gt "$MONITOR_DAILY_WARN_HOURS" ]; then
          log_warn "Daily backup — last success ${age_hours}h ago (> ${MONITOR_DAILY_WARN_HOURS}h)"
        else
          log_ok "Last success age: ${age_hours}h (within window)"
        fi
      fi
    fi

    # ── Recent Job failures ──────────────────────────────
    local jobs_json failed_jobs
    jobs_json=$(k8s_api "/apis/batch/v1/namespaces/$MONITOR_NAMESPACE/jobs" \
      -G --data-urlencode "labelSelector=job-name=$CJ_NAME")

    if [ -n "$jobs_json" ]; then
      failed_jobs=$(echo "$jobs_json" | jq -r \
        '[.items[] | select(.status.failed > 0)] | length // 0')
      if [ "$failed_jobs" -gt 0 ]; then
        log_warn "$failed_jobs job(s) with failures in history"
      fi
    fi

    # ── S3 verification ──────────────────────────────────
    if [ "$MONITOR_S3_CHECK" != "true" ]; then
      echo ""
      continue
    fi

    local s3_path="${S3[$CJ_NAME]}"
    if [ -n "$s3_path" ]; then
      echo "  S3 path:        $MONITOR_S3_BASE/$s3_path"

      local s3_output today_files today_count
      s3_output=$(aws s3 ls "$MONITOR_S3_BASE/$s3_path/" --recursive 2>/dev/null || true)

      if [ -z "$s3_output" ]; then
        log_fail "S3 path empty or unreachable: $MONITOR_S3_BASE/$s3_path"
      else
        today_files=$(echo "$s3_output" | grep "$TODAY" || true)
        today_count=$(echo "$today_files" | grep -c . || echo 0)

        if [ "$today_count" -gt 0 ]; then
          log_ok "S3: $today_count file(s) from today"
          echo "$today_files" | head -5 | while read -r line; do
            echo "         $line"
          done
        else
          log_fail "S3: NO files from today ($TODAY)"
          echo "$s3_output" | tail -3 | while read -r line; do
            echo "         $line"
          done
        fi
      fi
    else
      log_info "No S3 target — skipping S3 check"
    fi

    echo ""
  done <<< "$cj_names"
}

# =============================================================================
# Main
# =============================================================================
main() {
  __load_s3_mapping

  # ── Fetch all CronJobs once (shared by Step 0 + Step 1) ──────────────────
  echo "=== Backup Monitor — $TODAY ==="
  echo ""

  local cj_json
  cj_json=$(k8s_api "/apis/batch/v1/namespaces/$MONITOR_NAMESPACE/cronjobs")

  if [ -z "$cj_json" ]; then
    echo "ERROR: Could not fetch CronJobs from Kubernetes API"
    exit 1
  fi

  # Step 0: PostgreSQL DB coverage audit
  if [ "$MONITOR_PG_AUDIT" = "true" ]; then
    __pg_audit_with_cj "$cj_json"
  fi

  # Step 1: CronJob status checks + S3 verification
  run_cronjob_checks "$cj_json"

  # ── Summary ───────────────────────────────────────────────────────────────
  echo "============================================================"
  echo "  SUMMARY — $TODAY"
  echo "  Passed:   $PASSED"
  echo "  Warnings: $WARNINGS"
  echo "  Failures: $FAILURES"
  echo "============================================================"

  if [ "$FAILURES" -gt 0 ]; then
    echo "RESULT: FAILED — $FAILURES check(s) failed"
    exit 1
  else
    echo "RESULT: SUCCESS — all backup checks passed"
    exit 0
  fi
}

main "$@"
