#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  printf 'Usage: %s --database NAME --storage DIR\n' "$0" >&2
  exit 2
}

database=''
storage=''
while (( $# )); do
  case "$1" in
    --database) (( $# >= 2 )) || usage; database="$2"; shift 2 ;;
    --storage) (( $# >= 2 )) || usage; storage="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$database" =~ ^[A-Za-z0-9_]+$ && -n "$storage" && -d "$storage" ]] || usage
for command_name in runuser psql python3; do
  command -v "$command_name" >/dev/null || { printf 'Required command not found: %s\n' "$command_name" >&2; exit 1; }
done

ledger_exists="$(runuser -u postgres -- psql --no-psqlrc --set=ON_ERROR_STOP=1 --tuples-only --no-align \
  --dbname="$database" --command="SELECT to_regclass('public.signudoc_migrations') IS NOT NULL")" || {
  printf 'Restored database cannot be queried.\n' >&2
  exit 1
}
if [[ "$ledger_exists" == t ]]; then
  migration_count="$(runuser -u postgres -- psql --no-psqlrc --set=ON_ERROR_STOP=1 \
    --tuples-only --no-align --dbname="$database" \
    --command='SELECT count(*) FROM public.signudoc_migrations')"
else
  migration_count=0
fi
if [[ "$migration_count" == 0 ]]; then
  public_table_count="$(runuser -u postgres -- psql --no-psqlrc --set=ON_ERROR_STOP=1 \
    --tuples-only --no-align --dbname="$database" \
    --command="SELECT count(*) FROM pg_tables WHERE schemaname = 'public'")"
  expected_tables=0
  [[ "$ledger_exists" == t ]] && expected_tables=1
  [[ "$public_table_count" == "$expected_tables" ]] || {
    printf 'Restored database has application tables but no applied migration records.\n' >&2
    exit 1
  }
  printf 'Validated pre-migration empty database archive (no application tables or migration records).\n'
  exit 0
fi
[[ "$migration_count" =~ ^[1-9][0-9]*$ ]] || {
  printf 'Restored database migration ledger is invalid.\n' >&2
  exit 1
}

counts="$(runuser -u postgres -- psql --no-psqlrc --set=ON_ERROR_STOP=1 --tuples-only --no-align \
  --field-separator=$'\t' --dbname="$database" --command='
    SELECT
      (SELECT count(*) FROM public."user"),
      (SELECT count(*) FROM public.envelopes),
      (SELECT count(*) FROM public.templates),
      (SELECT count(*) FROM public.audit_events),
      (SELECT count(*) FROM public.system_audit_events),
      (SELECT count(*) FROM public.seal_keys);
  ')" || {
  printf 'Required SignuDoc tables are missing or unreadable.\n' >&2
  exit 1
}

references_file="$(mktemp "${TMPDIR:-/tmp}/signudoc-references.XXXXXXXX")"
trap 'rm -f -- "$references_file"' EXIT
runuser -u postgres -- psql --no-psqlrc --set=ON_ERROR_STOP=1 --tuples-only --no-align \
  --field-separator=$'\t' --dbname="$database" >"$references_file" <<'SQL'
SELECT object_key, expected_hash FROM (
  SELECT source_pdf_key AS object_key, source_pdf_hash AS expected_hash FROM public.envelopes
  UNION ALL SELECT signed_pdf_key, signed_pdf_sha256 FROM public.envelopes WHERE signed_pdf_key IS NOT NULL
  UNION ALL SELECT evidence_key, evidence_sha256 FROM public.envelopes WHERE evidence_key IS NOT NULL
  UNION ALL SELECT
    CASE
      WHEN right(evidence_key, 13) = '/internal.pdf' THEN left(evidence_key, length(evidence_key) - 13) || 'recipient.pdf'
      WHEN right(evidence_key, 14) = '/internal.json' THEN left(evidence_key, length(evidence_key) - 14) || 'recipient.json'
    END,
    recipient_evidence_sha256
    FROM public.envelopes
    WHERE evidence_key IS NOT NULL AND recipient_evidence_sha256 IS NOT NULL
  UNION ALL SELECT revision_key, revision_sha256 FROM public.envelopes WHERE revision_key IS NOT NULL
  UNION ALL SELECT image_key, NULL::text FROM public.fields WHERE image_key IS NOT NULL
  UNION ALL SELECT revision_key, NULL::text FROM public.provider_signing_sessions WHERE revision_key IS NOT NULL
  UNION ALL SELECT source_pdf_key, NULL::text FROM public.templates
) files
WHERE object_key IS NOT NULL AND object_key <> '';
SQL

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
python3 "$script_dir/check-file-references.py" \
  --storage "$storage" --references "$references_file" --require-sidecars
printf 'Post-restore database check passed (%s migrations). Counts (users, envelopes, templates, document audit events, system audit events, seal keys): %s\n' \
  "$migration_count" "$counts"
