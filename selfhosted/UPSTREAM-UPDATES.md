# Upstream release upgrades

Use this procedure to integrate a tagged SignuDoc release while keeping the
self-hosted deployment, SMTP, local storage, retention, and PBS changes in this
fork. Integrate release tags deliberately; do not merge upstream `main` as a
release substitute.

## Compare and integrate a release

Start from a clean checkout and note the fork commit that is currently deployed
and the upstream release tag being considered. Configure the remote once, then
fetch tags:

```sh
git remote get-url upstream || git remote add upstream https://github.com/NYLLON-SOFTWARE/SignuDoc.git
git fetch upstream --tags
git tag --list 'v*' --sort=-version:refname | head
```

Compare the tag with the previous upstream release and the fork's current
branch. Review the full file list as well as code changes:

Replace `vPREVIOUS`, `vNEXT`, and `BASE` below with the actual tags and fork
commit before running the commands.

```sh
git diff --stat vPREVIOUS..vNEXT
git diff --name-status vPREVIOUS..vNEXT
git log --oneline vPREVIOUS..vNEXT
git diff --stat vPREVIOUS..HEAD
git diff --name-status vPREVIOUS..HEAD
```

Create an isolated branch or worktree from the intended fork baseline. Preserve
history with a normal merge of the release tag:

```sh
git worktree add -b integration/upstream-vNEXT ../signudoc-upstream-vNEXT BASE
cd ../signudoc-upstream-vNEXT
git merge --no-ff vNEXT
```

Resolve each conflict after comparing the fork side, release side, and common
base. Do not choose an entire side for overlapping files without review. Keep
the fork's provider and storage behavior, then apply upstream fixes around it.
Check the merged files for conflict markers, inspect `git diff --check`, and
review the final merge diff before committing. Reconcile `package.json` with
the lockfile using the repository's Node.js 24.x and npm workflow; do not edit
lockfile integrity values by hand.

Files that need deliberate review on most upgrades:

- `src/lib/services/email.ts`, `src/lib/services/smtp-email.ts`, email status,
  admin email testing, and email-related tests.
- `src/lib/services/pdf-fonts.ts` and its tests, including static font tracing,
  subsetter paths, release working directories, and signature rendering.
- `package.json` and `package-lock.json`.
- `next.config.ts`, `.env.example`, `src/lib/utils/env.ts`, storage provider
  selection, and local document-reference behavior.
- `db/migrations/`, database migration code, retention logic, and related tests.
- `selfhosted/`, `docs/self-hosting.md`, deployment scripts, service units,
  Apache configuration, and PBS procedures.
- Both `CHANGELOG.md` and `General/CHANGELOG.md`.

## Review and test database migrations

Read every new migration and the application changes that depend on it. Check
the SQL dialect, constraints, indexes, locking behavior, whether existing rows
need transformation, and whether older application code can read the migrated
data. This project currently uses PostgreSQL through `pg`; its migration
runner is not a SQL Server or SQLite migration runner.

Use a disposable PostgreSQL 17 instance and database. Create test-only
credentials and a test-only document directory; never copy production
credentials or point tests at an installation database. Verify the database
name and host before migrating. Run the migration from the candidate release,
check its ledger and resulting schema, and exercise both existing and new data.
The migration runner wraps each migration file in a transaction, but a series
of migrations can stop after earlier files committed. Treat migrations as
non-automatically reversible unless a reviewed reverse migration is provided.
If no isolated PostgreSQL 17 environment is available, record the migration
test as blocked and do not claim production readiness.

## Run checks and build

Use Node.js 24.x, matching `package.json` and the deployment scripts. Point
test storage at a temporary directory and make email capture explicit. Keep
database tests on the disposable PostgreSQL database only:

```sh
npm ci --no-audit --no-fund
export EMAIL_DRIVER=capture
export EMAIL_CAPTURE_DIR=/tmp/signudoc-test/outbox
export STORAGE_DRIVER=local
export STORAGE_LOCAL_DIR=/tmp/signudoc-test/documents
export APP_URL=http://127.0.0.1:3000
export BETTER_AUTH_URL=http://127.0.0.1:3000
# Set DATABASE_URL only to the disposable test database.
npm run typecheck
npm run lint
npm test
npm run test:db
npm run test:e2e
npm run build
```

Run the self-hosted checks as well:

```sh
bash -n selfhosted/scripts/*.sh selfhosted/pbs/*.sh
python3 selfhosted/tests/test-release-permissions.py
selfhosted/pbs/tests/run.sh
```

Inspect test configuration before each suite. Tests must not reach production
databases, document directories, mail servers, or live application endpoints.
For full signing coverage, run a disposable application with disposable data
and captured email. Record anything that could not be executed and why.

## Prepare an operator-approved deployment

Before requesting deployment approval:

1. Commit the integration on its upgrade branch and record the exact commit.
2. Review the release notes, migration SQL, environment changes, dependency
   lockfile, test results, build output, and self-hosted configuration diff.
3. Confirm the configured retention value remains the operator-approved
   `1,825` days and that no new cleanup behavior bypasses it or legal holds.
4. Verify a recent successful PBS recovery point includes PostgreSQL and the
   complete local document filesystem. Check the PBS task log for successful
   freeze and thaw handling, verify the backup, and confirm the recovery point
   meets the approved RPO. Complete an isolated restore check before relying
   on the backup for a schema-changing release.
5. Schedule an operator-approved maintenance window. Confirm no backup is in
   progress, preserve the existing environment files and secrets, and review
   `selfhosted/README.md` and `selfhosted/pbs/README.md`.

Only after explicit operator approval, run the repository deployment script
from the clean committed checkout. It requests confirmation of a verified
recovery point, pauses retention, drains an active retention job, stops the
application, applies migrations, switches the release, starts the service,
and performs its local health check. Do not bypass its checkpoint prompt or
manually change the active release symlink as a shortcut.

After deployment, check the systemd service and journal, local health endpoint,
administrator sign-in, SMTP status and test email, a disposable signing flow,
document retrieval, audit history, and retention timer state. Confirm that the
configured retention period is still `1,825` days. Keep the prior release and
the verified recovery point available until the operator accepts the result.

## Recover from an unsuccessful deployment

The deployment script does not roll back database migrations. On migration,
startup, or health-check failure it leaves an incomplete-deployment marker and
keeps affected services stopped for operator review. Do not remove the marker
or restart the retention timer until the database, service, and release state
have been checked.

First inspect the service journal, migration ledger, active `current` target,
retained releases, and the verified PBS point. If the database migration
succeeded and the previous application is compatible with the migrated data,
an operator may restore the previous release and verify it before enabling
traffic. Keep the marker in place and retention stopped while reviewing. For
an approved code-only rollback after a later smoke-test failure, first stop
the retention timer, wait for any `signudoc-retention.service` run to finish,
and create the incomplete marker if the successful deployment already removed
it. Abort if retention does not finish. Use the exact previous release path
recorded before deployment; replace `PREVIOUS_RELEASE` below with that release
directory's name:

```sh
sudo systemctl stop signudoc.service
sudo ln -s /opt/signudoc/releases/PREVIOUS_RELEASE /opt/signudoc/current.next
sudo mv -Tf /opt/signudoc/current.next /opt/signudoc/current
sudo systemctl start signudoc.service
sudo /opt/signudoc/current/selfhosted/scripts/healthcheck.sh
```

After smoke checks pass, confirm the database and retention state, then
remove the incomplete marker and restore the retention timer to its recorded
intended state. If compatibility is uncertain or data has changed under the new
schema, restore PostgreSQL and documents together from the same verified VM
recovery point; do not combine a database and document tree from different
times. A schema rollback can require restoring that backup and may lose work
written after the recovery point. The `name` field migration in v0.4.0 only
widens a field-type check constraint and transforms no existing rows. A
manual reversal of that constraint is possible only after verifying that no
`name` fields exist; documents created with the new field require the new
application code.

After recovery, repeat the local health and application smoke checks, confirm
the retention timer is in its intended state, and document the migration and
recovery outcome before clearing any incomplete-deployment marker.
