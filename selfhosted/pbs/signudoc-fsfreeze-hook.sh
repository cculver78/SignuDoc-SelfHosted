#!/usr/bin/env bash
set -Eeuo pipefail

readonly APP_UNIT=signudoc.service
readonly RETENTION_UNIT=signudoc-retention.service
readonly RETENTION_TIMER=signudoc-retention.timer
readonly POSTGRES_UNIT=postgresql.service

if [[ "${SIGNUDOC_PBS_TESTING:-}" == 1 ]]; then
  : "${SIGNUDOC_PBS_STATE_DIR:?test state directory is required}"
  : "${SIGNUDOC_PBS_SYSTEMCTL:?test systemctl path is required}"
  readonly STATE_DIR="$SIGNUDOC_PBS_STATE_DIR"
  readonly SYSTEMCTL="$SIGNUDOC_PBS_SYSTEMCTL"
  readonly RETENTION_WAIT_SECONDS="${SIGNUDOC_PBS_RETENTION_WAIT_SECONDS:-300}"
else
  readonly STATE_DIR=/run/signudoc-pbs
  readonly SYSTEMCTL=/usr/bin/systemctl
  readonly RETENTION_WAIT_SECONDS=300
  if (( EUID != 0 )); then
    printf 'SignuDoc PBS hook must run as root.\n' >&2
    exit 1
  fi
  install -d -o root -g root -m 0700 "$STATE_DIR"
  if [[ -L "$STATE_DIR" || "$(stat -c '%u:%a' "$STATE_DIR")" != 0:700 ]]; then
    printf 'SignuDoc PBS hook state directory must be a root-owned directory with mode 0700.\n' >&2
    exit 1
  fi
fi

readonly STATE_FILE="$STATE_DIR/state"

log_message() {
  printf 'signudoc-pbs-hook: %s\n' "$*" >&2
  if command -v logger >/dev/null 2>&1; then
    logger -t signudoc-pbs-hook -- "$*" || true
  fi
}

is_active() {
  "$SYSTEMCTL" is-active --quiet "$1"
}

read_state() {
  local key value
  local format_seen=0
  app_active=0
  retention_timer_active=0
  postgres_active=0
  postgres_clusters=()

  [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      format)
        [[ "$value" == 1 && "$format_seen" == 0 ]] || return 1
        format_seen=1
        ;;
      app_active|retention_timer_active|postgres_active)
        [[ "$value" == 0 || "$value" == 1 ]] || return 1
        case "$key" in
          app_active) app_active="$value" ;;
          retention_timer_active) retention_timer_active="$value" ;;
          postgres_active) postgres_active="$value" ;;
        esac
        ;;
      postgres_cluster)
        [[ "$value" =~ ^postgresql@[A-Za-z0-9_.-]+\.service$ ]] || return 1
        postgres_clusters+=("$value")
        ;;
      *) return 1 ;;
    esac
  done <"$STATE_FILE"
  (( format_seen == 1 ))
}

remove_state() {
  rm -f -- "$STATE_FILE"
}

start_previous_services() {
  local failed=0 unit

  if (( postgres_active )); then
    if ! "$SYSTEMCTL" start "$POSTGRES_UNIT"; then
      log_message "could not start $POSTGRES_UNIT; application and retention remain stopped"
      return 1
    fi
  fi
  for unit in "${postgres_clusters[@]}"; do
    if ! "$SYSTEMCTL" start "$unit"; then
      log_message "could not start $unit; application and retention remain stopped"
      return 1
    fi
  done
  if (( app_active )) && ! "$SYSTEMCTL" start "$APP_UNIT"; then
    log_message "could not start $APP_UNIT; retention remains stopped"
    failed=1
  fi
  if (( failed == 0 && retention_timer_active )) && ! "$SYSTEMCTL" start "$RETENTION_TIMER"; then
    log_message "could not start $RETENTION_TIMER"
    failed=1
  fi
  return "$failed"
}

wait_for_retention() {
  local waited=0
  while is_active "$RETENTION_UNIT"; do
    if (( waited >= RETENTION_WAIT_SECONDS )); then
      log_message "$RETENTION_UNIT did not finish within ${RETENTION_WAIT_SECONDS}s"
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

freeze_filesystems() {
  local active_units unit temp_file retention_start_before retention_start_after retention_result
  local app_was_active=0 retention_timer_was_active=0 retention_was_active=0 postgres_was_active=0
  local -a active_clusters=()

  [[ ! -e "$STATE_FILE" ]] || {
    log_message 'a previous freeze state is still present; refusing another freeze'
    return 1
  }

  is_active "$APP_UNIT" && app_was_active=1 || true
  is_active "$RETENTION_TIMER" && retention_timer_was_active=1 || true
  is_active "$RETENTION_UNIT" && retention_was_active=1 || true
  is_active "$POSTGRES_UNIT" && postgres_was_active=1 || true
  if ! retention_start_before="$($SYSTEMCTL show --property=ExecMainStartTimestampMonotonic --value "$RETENTION_UNIT")"; then
    log_message "could not inspect $RETENTION_UNIT execution state"
    return 1
  fi
  if ! active_units="$($SYSTEMCTL list-units --type=service --state=active --no-legend --plain 'postgresql@*.service')"; then
    log_message 'could not inspect active PostgreSQL cluster services'
    return 1
  fi
  while read -r unit _; do
    if [[ "$unit" =~ ^postgresql@[A-Za-z0-9_.-]+\.service$ ]]; then
      active_clusters+=("$unit")
    fi
  done <<<"$active_units"

  umask 077
  temp_file="$(mktemp "$STATE_DIR/state.XXXXXXXX")" || {
    log_message 'could not create freeze state'
    return 1
  }
  {
    printf 'format=1\n'
    printf 'app_active=%s\n' "$app_was_active"
    printf 'retention_timer_active=%s\n' "$retention_timer_was_active"
    printf 'postgres_active=%s\n' "$postgres_was_active"
    for unit in "${active_clusters[@]}"; do
      printf 'postgres_cluster=%s\n' "$unit"
    done
  } >"$temp_file"
  chmod 0600 "$temp_file"
  if ! mv -- "$temp_file" "$STATE_FILE"; then
    rm -f -- "$temp_file"
    log_message 'could not save freeze state'
    return 1
  fi

  if ! "$SYSTEMCTL" stop "$RETENTION_TIMER"; then
    log_message "could not stop $RETENTION_TIMER"
    read_state || return 1
    start_previous_services || return 1
    remove_state
    return 1
  fi
  if ! wait_for_retention; then
    read_state || return 1
    start_previous_services || return 1
    remove_state
    return 1
  fi
  if ! retention_start_after="$($SYSTEMCTL show --property=ExecMainStartTimestampMonotonic --value "$RETENTION_UNIT")"; then
    log_message "could not verify the result of $RETENTION_UNIT"
    read_state || return 1
    start_previous_services || return 1
    remove_state
    return 1
  fi
  if (( retention_was_active )) || [[ "$retention_start_before" != "$retention_start_after" ]]; then
    if ! retention_result="$($SYSTEMCTL show --property=Result --value "$RETENTION_UNIT")" ||
      [[ "$retention_result" != success ]]; then
      log_message "$RETENTION_UNIT did not complete successfully; refusing an application-consistent snapshot"
      read_state || return 1
      start_previous_services || return 1
      remove_state
      return 1
    fi
  fi

  if (( app_was_active )) && ! "$SYSTEMCTL" stop "$APP_UNIT"; then
    log_message "could not stop $APP_UNIT"
    read_state || return 1
    start_previous_services || return 1
    remove_state
    return 1
  fi
  for unit in "${active_clusters[@]}"; do
    if ! "$SYSTEMCTL" stop "$unit"; then
      log_message "could not stop $unit"
      read_state || return 1
      start_previous_services || return 1
      remove_state
      return 1
    fi
  done
  if (( postgres_was_active )) && ! "$SYSTEMCTL" stop "$POSTGRES_UNIT"; then
    log_message "could not stop $POSTGRES_UNIT"
    read_state || return 1
    start_previous_services || return 1
    remove_state
    return 1
  fi

  log_message 'retention, SignuDoc, and active PostgreSQL services are quiesced for the VM snapshot'
}

thaw_filesystems() {
  if [[ ! -e "$STATE_FILE" ]]; then
    log_message 'thaw requested without a saved freeze state; nothing to restore'
    return 0
  fi
  if ! read_state; then
    log_message 'freeze state is invalid; leaving services unchanged for manual recovery'
    return 1
  fi
  if start_previous_services; then
    remove_state
    log_message 'services that were active before the snapshot have been restored'
    return 0
  fi
  log_message 'service restoration is incomplete; saved state remains in /run/signudoc-pbs/state'
  return 1
}

if (( $# != 1 )); then
  log_message 'expected exactly one action: freeze or thaw'
  exit 2
fi

case "$1" in
  freeze) freeze_filesystems ;;
  thaw) thaw_filesystems ;;
  *)
    log_message 'expected exactly one action: freeze or thaw'
    exit 2
    ;;
esac
