#!/usr/bin/env bash
set -Eeuo pipefail

readonly APP_ROOT=/opt/signudoc
readonly RELEASES_DIR="$APP_ROOT/releases"
readonly CURRENT_LINK="$APP_ROOT/current"
readonly NODE_BIN=/usr/local/bin/node
readonly NPM_BIN=/usr/local/bin/npm
readonly ENV_FILE=/etc/signudoc/signudoc.env
readonly RETENTION_ENV_FILE=/etc/signudoc/retention.env
readonly INCOMPLETE_MARKER=/var/lib/signudoc/deployment-incomplete

fail() {
  printf 'deploy: %s\n' "$1" >&2
  exit 1
}

incomplete() {
  printf 'deploy: %s\n' "$1" >&2
  printf 'The deployment marker is in place and the retention timer remains stopped. Review service, database, and release state before manual recovery; do not remove the marker until that review is complete.\n' >&2
  exit 1
}

if (( EUID != 0 )); then
  fail 'run as root (for example, sudo selfhosted/scripts/deploy.sh).'
fi

if [[ -e "$INCOMPLETE_MARKER" ]]; then
  fail 'a prior deployment is marked incomplete; review it before starting another deployment.'
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || fail 'run from a SignuDoc Git checkout.'
if [[ -n "$(git -C "$repo_root" status --porcelain)" ]]; then
  fail 'the checkout must be clean and committed; no uncommitted files will be deployed.'
fi

[[ -x "$NODE_BIN" && -x "$NPM_BIN" ]] || fail 'the pinned Node.js and npm commands under /usr/local/bin are missing.'
node_version="$("$NODE_BIN" --version)"
if [[ "$node_version" != v24.* ]]; then
  fail "Node.js 24.x is required; found $node_version."
fi
for command_name in runuser systemctl systemd-run tar; do
  command -v "$command_name" >/dev/null || fail "required command not found: $command_name."
done
id signudoc >/dev/null 2>&1 || fail 'the signudoc service account is missing; run install-prerequisites.sh first.'
id signudoc-build >/dev/null 2>&1 || fail 'the signudoc-build account is missing; run install-prerequisites.sh first.'
id signudoc-retention >/dev/null 2>&1 || fail 'the signudoc-retention account is missing; run install-prerequisites.sh first.'
[[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || fail "$ENV_FILE is missing or is a symlink."
[[ "$(stat -c '%U:%a' "$ENV_FILE")" == root:600 ]] || fail "$ENV_FILE must be owned by root with mode 0600."
[[ -f "$RETENTION_ENV_FILE" && ! -L "$RETENTION_ENV_FILE" ]] || fail "$RETENTION_ENV_FILE is missing or is a symlink."
[[ "$(stat -c '%U:%a' "$RETENTION_ENV_FILE")" == root:600 ]] || fail "$RETENTION_ENV_FILE must be owned by root with mode 0600."
[[ -f /etc/systemd/system/signudoc.service || -f /lib/systemd/system/signudoc.service ]] || fail 'install the SignuDoc systemd units before deployment.'
[[ -f /etc/systemd/system/signudoc-retention.timer || -f /lib/systemd/system/signudoc-retention.timer ]] || fail 'install the SignuDoc retention timer before deployment.'

if [[ ! -L "$CURRENT_LINK" ]]; then
  setup_token="$(awk -F= '$1 == "SETUP_TOKEN" { print substr($0, index($0, "=") + 1) }' "$ENV_FILE")"
  if [[ ! "$setup_token" =~ ^[[:xdigit:]]{64,}$ ]]; then
    fail 'first deployment requires a 64-character or longer hex SETUP_TOKEN in the protected environment file.'
  fi
  unset setup_token
fi

mkdir -p "$RELEASES_DIR"
build_dir="$(mktemp -d "$RELEASES_DIR/.build.XXXXXX")"
cleanup_build() {
  if [[ -n "${build_dir:-}" && -d "$build_dir" ]]; then
    rm -rf "$build_dir"
  fi
}
trap cleanup_build EXIT

chown signudoc-build:signudoc-build "$build_dir"
git -C "$repo_root" archive --format=tar HEAD | tar -xf - -C "$build_dir"
chown -R signudoc-build:signudoc-build "$build_dir"

printf 'Installing lockfile dependencies and building as signudoc-build...\n'
runuser -u signudoc-build -- env \
  -i \
  HOME=/var/cache/signudoc-build \
  PATH=/usr/local/bin:/usr/bin:/bin \
  npm_config_cache=/var/cache/signudoc-build/npm \
  NEXT_TELEMETRY_DISABLED=1 \
  bash -c 'cd "$1" && npm ci --no-audit --no-fund && npm run build' _ "$build_dir"

release_id="$(git -C "$repo_root" rev-parse --short=12 HEAD)-$(date -u +%Y%m%dT%H%M%SZ)"
release_dir="$RELEASES_DIR/$release_id"
[[ ! -e "$release_dir" ]] || fail "release path already exists: $release_dir"
mkdir -p /var/cache/signudoc
chown signudoc:signudoc /var/cache/signudoc
chmod 0750 /var/cache/signudoc
rm -rf "$build_dir/.next/cache"
ln -s /var/cache/signudoc "$build_dir/.next/cache"
chmod -R go-w "$build_dir"
find "$build_dir" -type d -exec chmod 0750 {} +
chmod 0750 "$build_dir/selfhosted/scripts/healthcheck.sh" "$build_dir/selfhosted/scripts/run-retention.sh"
chown -R root:signudoc "$build_dir"
mv "$build_dir" "$release_dir"
build_dir=

if [[ ! -t 0 ]]; then
  fail 'an interactive terminal is required for the PBS recovery-point checkpoint.'
fi
if ! "$repo_root/selfhosted/pbs/confirm-checkpoint.sh"; then
  fail 'PBS recovery point was not confirmed; no database migration was run and services were not changed.'
fi

app_was_active=0
timer_was_active=0
systemctl is-active --quiet signudoc.service && app_was_active=1 || true
systemctl is-active --quiet signudoc-retention.timer && timer_was_active=1 || true

restore_previous_timer() {
  if (( timer_was_active )) && ! systemctl start signudoc-retention.timer; then
    install -o root -g root -m 0600 /dev/null "$INCOMPLETE_MARKER"
    fail 'could not restore the retention timer; the deployment marker remains in place.'
  fi
}

printf '\nPausing the SignuDoc retention schedule and waiting for any active retention job...\n'
if ! systemctl stop signudoc-retention.timer; then
  restore_previous_timer
  fail 'could not stop the retention timer; the current release is unchanged.'
fi
if ! install -o root -g root -m 0600 /dev/null "$INCOMPLETE_MARKER"; then
  restore_previous_timer
  fail 'could not create the deployment marker; no database migration was run.'
fi
printf 'pre-migration PBS recovery point confirmed\n' >"$INCOMPLETE_MARKER"

for ((attempt = 0; attempt < 360; attempt += 1)); do
  if ! systemctl is-active --quiet signudoc-retention.service; then
    break
  fi
  sleep 1
done
if systemctl is-active --quiet signudoc-retention.service; then
  incomplete 'retention did not finish within six minutes; review its journal before continuing.'
fi

systemctl stop signudoc.service || incomplete 'could not stop the application before the database migration.'

printf 'Applying pending database migrations as signudoc...\n'
migration_unit="signudoc-migrate-$(date -u +%Y%m%d%H%M%S)"
if ! systemd-run --quiet --wait --pipe --collect \
  --unit="$migration_unit" \
  --property=Type=oneshot \
  --property=User=signudoc \
  --property=Group=signudoc \
  --property="WorkingDirectory=$release_dir" \
  --property="EnvironmentFile=$ENV_FILE" \
  --property=ProtectSystem=strict \
  --property=ProtectHome=true \
  --property=PrivateTmp=true \
  --property=NoNewPrivileges=true \
  --setenv=HOME=/tmp \
  --setenv=npm_config_cache=/tmp/npm-cache \
  /usr/local/bin/npm run db:migrate; then
  incomplete 'database migration failed. It may have applied earlier files; the database and code need operator review.'
fi

previous_release=''
if [[ -L "$CURRENT_LINK" ]]; then
  previous_release="$(readlink -f "$CURRENT_LINK")"
fi
rm -f "$APP_ROOT/current.next"
ln -s "$release_dir" "$APP_ROOT/current.next"
mv -Tf "$APP_ROOT/current.next" "$CURRENT_LINK"
rm -f "$INCOMPLETE_MARKER"

restore_incomplete_state() {
  install -o root -g root -m 0600 /dev/null "$INCOMPLETE_MARKER"
  systemctl stop signudoc.service >/dev/null 2>&1 || true
  incomplete "$1 Previous release: ${previous_release:-none}. New release: $release_dir. Database migrations are not automatically rolled back."
}

if ! systemctl start signudoc.service; then
  restore_incomplete_state 'the new application service failed to start.'
fi
if ! "$release_dir/selfhosted/scripts/healthcheck.sh"; then
  restore_incomplete_state 'the new application failed the local HTTP health check.'
fi
if ! systemctl enable signudoc.service signudoc-retention.timer; then
  restore_incomplete_state 'systemd could not enable the application and retention timer.'
fi
if ! systemctl start signudoc-retention.timer; then
  restore_incomplete_state 'the retention timer could not be started.'
fi

printf 'Deployment completed. Active release: %s\n' "$release_dir"
if [[ -n "$previous_release" ]]; then
  printf 'Previous release retained for manual review: %s\n' "$previous_release"
fi
