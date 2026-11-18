#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -un)" != signudoc-deploy ]]; then
  printf 'Run as signudoc-deploy, for example: sudo -u signudoc-deploy bash selfhosted/scripts/pull-updates.sh\n' >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
if [[ -n "$(git -C "$repo_root" status --porcelain)" ]]; then
  printf 'The checkout has uncommitted changes; resolve them before pulling.\n' >&2
  exit 1
fi

git -C "$repo_root" pull --ff-only
printf 'Checkout updated. Run deploy.sh separately to build and activate the update.\n'
