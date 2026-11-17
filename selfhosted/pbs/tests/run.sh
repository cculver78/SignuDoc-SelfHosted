#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/signudoc-pbs-tests.XXXXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

failures=0
passes=0
report_pass() { printf 'PASS %s\n' "$1"; passes=$((passes + 1)); }
report_fail() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

setup_fixture() {
  local name="$1"
  TEST_CASE="$TEST_ROOT/$name"
  mkdir -p "$TEST_CASE/state" "$TEST_CASE/run-state"
  : >"$TEST_CASE/log"
  : >"$TEST_CASE/state/active-units"
  export SIGNUDOC_PBS_TESTING=1
  export SIGNUDOC_PBS_STATE_DIR="$TEST_CASE/run-state"
  export SIGNUDOC_PBS_SYSTEMCTL="$SCRIPT_DIR/tests/fake-systemctl"
  export SIGNUDOC_PBS_FAKE_STATE="$TEST_CASE/state"
  export SIGNUDOC_PBS_FAKE_LOG="$TEST_CASE/log"
  export SIGNUDOC_PBS_RETENTION_WAIT_SECONDS=2
  unset SIGNUDOC_PBS_RETENTION_FINISH_AFTER_CHECKS SIGNUDOC_PBS_FAIL_ACTION \
    SIGNUDOC_PBS_FAKE_RETENTION_RESULT || true
}

set_active_units() {
  printf '%s\n' "$@" >"$SIGNUDOC_PBS_FAKE_STATE/active-units"
  if printf '%s\n' "$@" | grep -Fxq signudoc-retention.service; then
    printf '42\n' >"$SIGNUDOC_PBS_FAKE_STATE/retention-start"
  fi
}

unit_active() {
  grep -Fxq "$1" "$SIGNUDOC_PBS_FAKE_STATE/active-units"
}

setup_fixture all-active
set_active_units signudoc.service signudoc-retention.timer postgresql.service postgresql@17-main.service
if "$SCRIPT_DIR/signudoc-fsfreeze-hook.sh" freeze >"$TEST_CASE/freeze.log" 2>&1 &&
  [[ ! -s "$SIGNUDOC_PBS_FAKE_STATE/active-units" ]] &&
  [[ -f "$SIGNUDOC_PBS_STATE_DIR/state" ]] &&
  "$SCRIPT_DIR/signudoc-fsfreeze-hook.sh" thaw >>"$TEST_CASE/freeze.log" 2>&1 &&
  unit_active signudoc.service && unit_active signudoc-retention.timer &&
  unit_active postgresql.service && unit_active postgresql@17-main.service &&
  [[ ! -e "$SIGNUDOC_PBS_STATE_DIR/state" ]]; then
  report_pass 'freeze quiesces active services and thaw restores exactly the saved state'
else
  report_fail 'freeze quiesces active services and thaw restores exactly the saved state'
  cat "$TEST_CASE/freeze.log" >&2
fi

setup_fixture initially-inactive
if "$SCRIPT_DIR/signudoc-fsfreeze-hook.sh" freeze >"$TEST_CASE/run.log" 2>&1 &&
  [[ ! -s "$SIGNUDOC_PBS_FAKE_STATE/active-units" ]] &&
  "$SCRIPT_DIR/signudoc-fsfreeze-hook.sh" thaw >>"$TEST_CASE/run.log" 2>&1 &&
  [[ ! -s "$SIGNUDOC_PBS_FAKE_STATE/active-units" ]]; then
  report_pass 'services that were inactive stay inactive after thaw'
else
  report_fail 'services that were inactive stay inactive after thaw'
fi

setup_fixture retention-in-progress
set_active_units signudoc.service signudoc-retention.service signudoc-retention.timer postgresql.service
export SIGNUDOC_PBS_RETENTION_FINISH_AFTER_CHECKS=1
if "$SCRIPT_DIR/signudoc-fsfreeze-hook.sh" freeze >"$TEST_CASE/run.log" 2>&1 &&
  ! unit_active signudoc-retention.service &&
  [[ "$(grep -n '^stop signudoc.service$' "$TEST_CASE/log" | cut -d: -f1)" -gt \
     "$(grep -n '^is-active signudoc-retention.service$' "$TEST_CASE/log" | tail -n1 | cut -d: -f1)" ]] &&
  "$SCRIPT_DIR/signudoc-fsfreeze-hook.sh" thaw >>"$TEST_CASE/run.log" 2>&1; then
  report_pass 'freeze waits for an active retention job before stopping the app'
else
  report_fail 'freeze waits for an active retention job before stopping the app'
  cat "$TEST_CASE/run.log" >&2
fi

setup_fixture retention-failure
set_active_units signudoc.service signudoc-retention.service signudoc-retention.timer postgresql.service
export SIGNUDOC_PBS_RETENTION_FINISH_AFTER_CHECKS=1 SIGNUDOC_PBS_FAKE_RETENTION_RESULT=failed
if ! "$SCRIPT_DIR/signudoc-fsfreeze-hook.sh" freeze >"$TEST_CASE/run.log" 2>&1 &&
  unit_active signudoc.service && unit_active signudoc-retention.timer &&
  unit_active postgresql.service && [[ ! -e "$SIGNUDOC_PBS_STATE_DIR/state" ]] &&
  grep -q 'did not complete successfully' "$TEST_CASE/run.log"; then
  report_pass 'failed retention run aborts the snapshot and rolls active services back'
else
  report_fail 'failed retention run aborts the snapshot and rolls active services back'
  cat "$TEST_CASE/run.log" >&2
fi

setup_fixture stop-failure
set_active_units signudoc.service signudoc-retention.timer postgresql.service
export SIGNUDOC_PBS_FAIL_ACTION=stop:postgresql.service
if ! "$SCRIPT_DIR/signudoc-fsfreeze-hook.sh" freeze >"$TEST_CASE/run.log" 2>&1 &&
  unit_active signudoc.service && unit_active signudoc-retention.timer &&
  unit_active postgresql.service && [[ ! -e "$SIGNUDOC_PBS_STATE_DIR/state" ]]; then
  report_pass 'stop failure rolls previously active services back and fails the hook'
else
  report_fail 'stop failure rolls previously active services back and fails the hook'
fi

setup_fixture thaw-failure
set_active_units signudoc.service signudoc-retention.timer postgresql.service
if "$SCRIPT_DIR/signudoc-fsfreeze-hook.sh" freeze >"$TEST_CASE/run.log" 2>&1; then
  export SIGNUDOC_PBS_FAIL_ACTION=start:postgresql.service
  if ! "$SCRIPT_DIR/signudoc-fsfreeze-hook.sh" thaw >>"$TEST_CASE/run.log" 2>&1 &&
    [[ -f "$SIGNUDOC_PBS_STATE_DIR/state" ]] &&
    ! unit_active signudoc.service && ! unit_active signudoc-retention.timer; then
    report_pass 'thaw failure retains recovery state and keeps dependent services stopped'
  else
    report_fail 'thaw failure retains recovery state and keeps dependent services stopped'
  fi
else
  report_fail 'thaw failure setup could not freeze the fixture'
fi

setup_fixture invalid-action
if ! "$SCRIPT_DIR/signudoc-fsfreeze-hook.sh" nonsense >/dev/null 2>&1; then
  report_pass 'unknown hook actions are rejected'
else
  report_fail 'unknown hook actions are rejected'
fi

setup_checkpoint() {
  local answers="$1" expected_status="$2" label="$3"
  if printf '%s\n' "$answers" | "$SCRIPT_DIR/confirm-checkpoint.sh" >"$TEST_CASE/checkpoint.log" 2>&1; then
    actual_status=0
  else
    actual_status=1
  fi
  if (( actual_status == expected_status )); then
    report_pass "$label"
  else
    report_fail "$label"
    cat "$TEST_CASE/checkpoint.log" >&2
  fi
}

setup_fixture checkpoint-confirm
current_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
setup_checkpoint $'vm/123/'"$current_time"$'\n'"$current_time"$'\nPBS-VERIFIED vm/123/'"$current_time $current_time" 0 \
  'checkpoint confirmation accepts a referenced UTC recovery point and exact phrase'

setup_fixture checkpoint-reject
current_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
setup_checkpoint $'vm/123/'"$current_time"$'\n'"$current_time"$'\nYES' 1 \
  'checkpoint confirmation rejects a simple yes/no approval'

setup_fixture checkpoint-invalid-time
setup_checkpoint $'vm/123/now\nnot-a-time\nPBS-VERIFIED vm/123/now not-a-time' 1 \
  'checkpoint confirmation rejects missing or invalid timestamps'

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s "$SCRIPT_DIR/tests" -p 'test_*.py'

printf '\nPBS tests passed: %s; failed: %s.\n' "$passes" "$failures"
(( failures == 0 ))
