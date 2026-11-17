#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ! "${RETENTION_JOB_SECRET:-}" =~ ^[[:xdigit:]]{64,}$ ]]; then
  printf 'RETENTION_JOB_SECRET must be a hex secret generated with openssl rand -hex 32 or longer.\n' >&2
  exit 1
fi
job_secret="$RETENTION_JOB_SECRET"
unset RETENTION_JOB_SECRET

exec 9>/run/signudoc-retention/retention.lock
if ! flock -n 9; then
  printf 'A SignuDoc retention request is already running; skipping this invocation.\n'
  exit 0
fi

if ! printf 'url = "http://127.0.0.1:3000/api/internal/retention"\nheader = "Authorization: Bearer %s"\n' "$job_secret" |
  curl -q --fail --silent --show-error --max-time 240 --config -; then
  unset job_secret
  printf '\nRetention request failed. The endpoint may have completed work before a timeout; it will run again on the next scheduled day.\n' >&2
  exit 1
fi
unset job_secret
