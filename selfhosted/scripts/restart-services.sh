#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID != 0 )); then
  printf 'Run as root, for example: sudo bash selfhosted/scripts/restart-services.sh\n' >&2
  exit 1
fi
if [[ -e /var/lib/signudoc/deployment-incomplete ]]; then
  printf 'A deployment is marked incomplete; review it before restarting services.\n' >&2
  exit 1
fi
if systemctl is-active --quiet signudoc-retention.service; then
  printf 'The SignuDoc retention job is running; wait for it to finish before restarting.\n' >&2
  exit 1
fi

systemctl restart signudoc.service
/opt/signudoc/current/selfhosted/scripts/healthcheck.sh
systemctl restart apache2.service
printf 'SignuDoc and Apache restarted.\n'
