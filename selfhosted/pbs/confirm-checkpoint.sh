#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  printf 'PBS checkpoint: %s\n' "$1" >&2
  exit 1
}

if [[ ! -t 0 && "${SIGNUDOC_PBS_TESTING:-}" != 1 ]]; then
  fail 'an interactive terminal is required.'
fi

printf '%s\n' \
  'Before continuing, verify the recovery point in Proxmox/PBS and compare its age with the school-approved RPO.' \
  'Confirm the VM backup task succeeded, all required VM disks were included, and the app-consistency freeze/thaw succeeded (or confirm a different verified application-consistent recovery point).' \
  'Ensure no Proxmox backup is running or scheduled to overlap this deployment. The deploy script cannot inspect or change Proxmox jobs.'

IFS= read -r -p 'Recovery-point reference: ' snapshot_ref || fail 'no recovery-point reference was entered.'
[[ "$snapshot_ref" =~ ^[A-Za-z0-9._:/@+-]+$ ]] || fail 'reference must be one token using letters, digits, and . _ : / @ + -.'

IFS= read -r -p 'Recovery-point creation time (UTC, YYYY-MM-DDTHH:MM:SSZ): ' created_at ||
  fail 'no UTC creation time was entered.'
[[ "$created_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
  fail 'creation time must use YYYY-MM-DDTHH:MM:SSZ.'
created_epoch="$(date -u -d "$created_at" +%s 2>/dev/null)" || fail 'creation time is not a valid UTC date.'
canonical_time="$(date -u -d "@$created_epoch" +%Y-%m-%dT%H:%M:%SZ)"
[[ "$canonical_time" == "$created_at" ]] || fail 'creation time is not a valid UTC date.'
now_epoch="$(date -u +%s)"
(( created_epoch <= now_epoch )) || fail 'creation time is in the future.'
age_seconds=$((now_epoch - created_epoch))
age_days=$((age_seconds / 86400))
age_hours=$(((age_seconds % 86400) / 3600))
printf 'Recovery-point age: %s day(s), %s hour(s). Compare this with the approved recovery-point objective.\n' "$age_days" "$age_hours"

expected="PBS-VERIFIED $snapshot_ref $created_at"
printf 'Type exactly "%s" to authorize database migrations: ' "$expected"
IFS= read -r confirmation || fail 'confirmation was not entered.'
[[ "$confirmation" == "$expected" ]] || fail 'recovery point was not confirmed; migrations must not run.'
printf 'Recovery point confirmed: %s at %s.\n' "$snapshot_ref" "$created_at"
