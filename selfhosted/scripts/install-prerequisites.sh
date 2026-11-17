#!/usr/bin/env bash
set -Eeuo pipefail

readonly NODE_VERSION="${NODE_VERSION:-24.22.3}"

fail() {
  printf 'install-prerequisites: %s\n' "$1" >&2
  exit 1
}

if (( EUID != 0 )); then
  fail 'run as root on a new Debian 13 VM.'
fi

if [[ ! -r /etc/os-release ]]; then
  fail 'cannot identify operating system.'
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != debian || "${VERSION_ID:-}" != 13 ]]; then
  fail 'this example is limited to Debian 13 (Trixie).'
fi

if [[ ! "$NODE_VERSION" =~ ^24\.[0-9]+\.[0-9]+$ ]]; then
  fail 'NODE_VERSION must be a Node.js 24.x patch release.'
fi

case "$(dpkg --print-architecture)" in
  amd64) node_arch=x64 ;;
  arm64) node_arch=arm64 ;;
  *) fail 'supported Debian architectures are amd64 and arm64.' ;;
esac

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  apache2 \
  ca-certificates \
  certbot \
  curl \
  git \
  openssl \
  postgresql \
  postgresql-client \
  python3-certbot-apache \
  sudo \
  util-linux \
  xz-utils

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

archive="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"
release_url="https://nodejs.org/dist/v${NODE_VERSION}"
curl --fail --location --silent --show-error "$release_url/SHASUMS256.txt" -o "$tmp_dir/SHASUMS256.txt"
curl --fail --location --silent --show-error "$release_url/$archive" -o "$tmp_dir/$archive"

expected_sha="$(awk -v file="$archive" '$2 == file { print $1 }' "$tmp_dir/SHASUMS256.txt")"
if [[ ! "$expected_sha" =~ ^[[:xdigit:]]{64}$ ]]; then
  fail "the official checksum list did not contain $archive."
fi
printf '%s  %s\n' "$expected_sha" "$tmp_dir/$archive" | sha256sum --check --status ||
  fail "SHA-256 verification failed for $archive."

install -d -o root -g root -m 0755 /opt/nodejs
tar -xJf "$tmp_dir/$archive" --no-same-owner -C /opt/nodejs
ln -sfn "/opt/nodejs/node-v${NODE_VERSION}-linux-${node_arch}" /opt/nodejs/current
ln -sfn /opt/nodejs/current/bin/node /usr/local/bin/node
ln -sfn /opt/nodejs/current/bin/npm /usr/local/bin/npm
ln -sfn /opt/nodejs/current/bin/npx /usr/local/bin/npx

if [[ "$(/usr/local/bin/node --version)" != "v${NODE_VERSION}" ]]; then
  fail 'the installed Node.js version did not match the pinned release.'
fi
/usr/local/bin/npm --version >/dev/null || fail 'the bundled npm command did not start with the installed Node.js runtime.'

getent group signudoc >/dev/null || groupadd --system signudoc
if ! getent passwd signudoc >/dev/null; then
  useradd --system --gid signudoc --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin signudoc
fi

getent group signudoc-build >/dev/null || groupadd --system signudoc-build
if ! getent passwd signudoc-build >/dev/null; then
  useradd --system --gid signudoc-build --home-dir /var/cache/signudoc-build --create-home --shell /usr/sbin/nologin signudoc-build
fi
if ! getent passwd signudoc-retention >/dev/null; then
  useradd --system --gid signudoc --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin signudoc-retention
fi

install -d -o root -g root -m 0700 /etc/signudoc
install -d -o root -g signudoc -m 0750 /opt/signudoc /opt/signudoc/releases
install -d -o root -g signudoc -m 0750 /var/lib/signudoc
install -d -o signudoc -g signudoc -m 0750 /var/lib/signudoc/documents
install -d -o signudoc -g signudoc -m 0750 /var/cache/signudoc
install -d -o signudoc-build -g signudoc-build -m 0750 /var/cache/signudoc-build /var/cache/signudoc-build/npm

printf 'Prerequisites installed. No Apache site, database, environment file, or service was configured.\n'
