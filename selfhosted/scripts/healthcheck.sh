#!/usr/bin/env bash
set -Eeuo pipefail

readonly url=http://127.0.0.1:3000/login
attempt=1

while (( attempt <= 30 )); do
  if curl --silent --fail --output /dev/null --connect-timeout 2 --max-time 5 "$url"; then
    printf 'SignuDoc answered %s\n' "$url"
    exit 0
  fi

  sleep 2
  ((attempt += 1))
done

printf 'SignuDoc did not answer %s after 30 checks.\n' "$url" >&2
exit 1
