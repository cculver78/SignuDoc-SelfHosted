# Debian self-hosting

This directory contains deployment examples for a single Debian 13 VM: Next.js
under Node.js, PostgreSQL, local document files, Phase 1 SMTP, Apache, and
systemd. It does not require Vercel, Neon, Blob, Resend, Docker, or hosted
application services. It does not configure a school server by itself.

This is deployment preparation, not a production approval. **Do not expose an
installation to signers until a PBS backup has been verified and a restore
drill has been completed.**
The scripts here have not been run against a server. Replace every example with
values for the intended VM before use.

## Starting point and support window

- Use Debian 13 (Trixie), currently Debian stable. Debian lists full support
  through 9 August 2028 and LTS through 30 June 2030: [Debian 13 release
  information](https://www.debian.org/releases/trixie/).
- The repository requires Node.js `24.x`; Node 24 is LTS and receives updates
  through the end of April 2028. The prerequisite script currently pins
  `24.22.3` and verifies its archive against the SHA-256 manifest from
  `nodejs.org` ([release](https://nodejs.org/en/blog/release/v24.22.3)). Review
  the latest supported 24.x patch before future installs: [Node.js release
  schedule](https://nodejs.org/en/about/previous-releases) and [Node 24 LTS
  notice](https://nodejs.org/en/blog/release/v24.11.0).
- Next.js 16 requires Node 20.9 or newer; this repository narrows that to
  Node 24.x in `package.json`: [Next.js installation requirements](https://nextjs.org/docs/app/getting-started/installation).
- An unbenchmarked initial VM estimate is 2 vCPUs and 4 GiB RAM. Size the
  persistent disk from expected PDF volume and retention, then monitor disk,
  memory, and PostgreSQL use under real workload.

The examples support Debian `amd64` and `arm64`. They target a single VM where
Apache is the Internet-facing proxy. A second reverse proxy or CDN changes the
client-IP trust boundary and needs a separate review.

## Install packages and accounts

Create the `signudoc-deploy` user and its matching group for the checkout
before running the prerequisites. Review `scripts/install-prerequisites.sh`,
then run it only on a new Debian 13 VM:

```sh
sudo bash selfhosted/scripts/install-prerequisites.sh
```

It installs Apache, PostgreSQL, Certbot, system tools, and the pinned Node.js
24 release, Python 3, and QEMU Guest Agent; creates the `signudoc` runtime user, separate `signudoc-build`
user, and isolated `signudoc-retention` user; and creates the storage, cache,
and release directories. These accounts have `/usr/sbin/nologin`. It does not
create a database, Apache site, environment file, certificate, or systemd
service. Debian package installation may start Apache/PostgreSQL; inspect
service state on a new VM before proceeding.

The runtime account can write documents only in
`/var/lib/signudoc/documents` and Next.js cache only in `/var/cache/signudoc`.
The release code is root-owned and readable by the runtime group. The
environment file is root-owned mode `0600`, and systemd reads it before
starting the service. No Apache alias exposes document storage.

## PostgreSQL

Keep PostgreSQL on the VM. Do not open port 5432 to the Internet. Debian's
default cluster should listen on loopback; verify `listen_addresses` and
`pg_hba.conf` use local access and SCRAM password authentication before use.
Create an application-owned database and role without cluster-wide privileges:

```sh
sudo -u postgres psql
```

At the `psql` prompt:

```sql
CREATE ROLE signudoc LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE DATABASE signudoc OWNER signudoc ENCODING 'UTF8';
\password signudoc
```

Use the password entered at the secure prompt in `DATABASE_URL` below. A
32-byte hex password from `openssl rand -hex 32` is convenient in a URI because
it needs no URL escaping. The app role owns only its database, which lets the
existing migration tool create and alter SignuDoc tables without granting
`SUPERUSER`, `CREATEDB`, or `CREATEROLE`.

Set the connection string in `/etc/signudoc/signudoc.env` (replace the
placeholder with the password entered at `\password`):

```dotenv
DATABASE_URL=postgresql://signudoc:replace-with-64-hex-db-password@127.0.0.1:5432/signudoc?sslmode=disable
```

Confirm `postgresql.conf` listens on loopback only and `pg_hba.conf` has a
`host` rule for `127.0.0.1/32` using `scram-sha-256`; do not add a public
interface or broad `0.0.0.0/0` rule.

The existing migration command is `npm run db:migrate`. It records applied SQL
files and skips them on later runs. Never use `npm run db:reset` on a deployed
database. A failed sequence can leave earlier migration files applied; do not
assume that reverting application code reverses database changes.

## Environment file

Create the file from the example and protect it before adding values:

```sh
sudo install -o root -g root -m 0600 /dev/null /etc/signudoc/signudoc.env
sudoedit /etc/signudoc/signudoc.env
sudo install -o root -g root -m 0600 /dev/null /etc/signudoc/retention.env
sudoedit /etc/signudoc/retention.env
```

Use `config/signudoc.env.example` for the app and
`config/retention.env.example` for the timer. Set both public URLs to the same
HTTPS origin. Use distinct random values for the authentication, setup, and
retention secrets:

```sh
openssl rand -hex 32
```

Copy each output directly into the intended field using `sudoedit`; do not put
secrets in shell history, source control, or command-line arguments. Confirm
permissions with `sudo stat -c '%U:%a %n' /etc/signudoc/signudoc.env /etc/signudoc/retention.env`
(expected `root:600` for both).

These are systemd `EnvironmentFile` files, not shell scripts: use plain
`NAME=value` lines without `export` or shell substitutions. The generated
secrets and database password above use hex to avoid quoting characters. If an
SMTP provider password contains whitespace, quotes, or backslashes, encode it
using systemd's environment-file quoting rules rather than shell quoting.

Relevant settings and actual supported names:

| Purpose | Setting |
| --- | --- |
| Public links and auth origin | `APP_URL`, `BETTER_AUTH_URL` |
| Session/auth encryption key | `BETTER_AUTH_SECRET` (at least 32 characters in production) |
| Local DB | `DATABASE_URL` |
| Next listen port | `PORT=3000`; the service binds `127.0.0.1` with the supported `next start --hostname` option |
| Files outside releases | `STORAGE_DRIVER=local`, `STORAGE_LOCAL_DIR=/var/lib/signudoc/documents` |
| SMTP | `EMAIL_DRIVER=smtp`, `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURE`, `SMTP_REQUIRE_TLS`, optional paired `SMTP_USER` / `SMTP_PASSWORD`, and `SMTP_FROM_EMAIL` |
| Default support/reply-to address | `SUPPORT_EMAIL` |
| Scheduled job authentication | `RETENTION_JOB_SECRET` in `/etc/signudoc/retention.env` |
| First administrator setup | `SETUP_TOKEN` |
| Password breach check | Enabled by default in production; `PASSWORD_BREACH_CHECK=off` opts out |

The web service loads `retention.env` because the retention endpoint must
verify the bearer token. The timer runs as its own `signudoc-retention` account
and reads that same file; it does not inherit the app's other credentials.

The example uses SMTP on port 587 with STARTTLS (`SMTP_SECURE=false`,
`SMTP_REQUIRE_TLS=true`). For implicit TLS on port 465, set
`SMTP_SECURE=true` and `SMTP_REQUIRE_TLS=false`. Configure both SMTP auth
variables or leave both unset. The SMTP implementation resolves the mail host
using IPv4 only and rejects IPv6-only hosts. The sender can also be set under
Settings, Organization, or with `EMAIL_FROM_ADDRESS`; the organization's
reply-to setting remains available in the UI. `RESEND_API_KEY` is not needed.

Keep `BETTER_AUTH_SECRET` for the lifetime of this installation and include it
in protected recovery material: the app uses it for session signing and to
decrypt some stored security data. If the application-managed document sealing
certificate is used, its encrypted private key is in PostgreSQL and also
depends on this secret. If a customer-supplied P12 certificate is configured,
protect its `SEAL_P12_BASE64` and `SEAL_P12_PASSWORD` values separately.

Production password sign-up checks Have I Been Pwned over outbound HTTPS and
fails closed if the service cannot be reached. Keep that outbound access unless
the school intentionally accepts the tradeoff of disabling it.

## Build and deploy

For Debian, use the existing Proxmox Backup Server VM backup workflow. Review
the [PBS backup and recovery guide](pbs/README.md) before exposing the service.
PBS owns the schedule, verification, retention, and restore-point management;
SignuDoc does not add a second backup repository, timer, or retention policy.

Install the application and retention systemd files, install the guest-agent
hook, and reload systemd before running the deployment script. The hook is
called directly by QEMU Guest Agent, so inspect `/etc/qemu/qemu-ga.conf` and
preserve any existing freeze hook when adding it. On the checkout:

```sh
sudo install -o root -g root -m 0644 selfhosted/systemd/signudoc.service /etc/systemd/system/
sudo install -o root -g root -m 0644 selfhosted/systemd/signudoc-retention.service /etc/systemd/system/
sudo install -o root -g root -m 0644 selfhosted/systemd/signudoc-retention.timer /etc/systemd/system/
sudo install -o root -g root -m 0750 selfhosted/pbs/signudoc-fsfreeze-hook.sh /usr/local/sbin/signudoc-pbs-fsfreeze-hook
sudo install -o root -g root -m 0644 selfhosted/apache/signudoc-bootstrap.conf /etc/apache2/sites-available/signudoc.conf
sudoedit /etc/apache2/sites-available/signudoc.conf
sudo systemctl daemon-reload
```

In `/etc/qemu/qemu-ga.conf`, add this setting in the existing `[general]`
section (create the section if it is absent):

```ini
[general]
fsfreeze-hook=/usr/local/sbin/signudoc-pbs-fsfreeze-hook
```

Do not overwrite another configured hook without preserving its behavior.
Enable the QEMU Guest Agent option for this VM in Proxmox, then restart and
check `qemu-guest-agent` in Debian. In a maintenance window, test a freeze/thaw
cycle from the Proxmox host and inspect `journalctl -t signudoc-pbs-hook` in the
guest. Do not use a backup as the first test of the hook.

Replace `signudoc.example.com` in the installed bootstrap vhost before
deployment. It serves only the ACME challenge directory and is not enabled by
these commands.

`scripts/deploy.sh` requires a clean, committed Git checkout, Node 24.x, the
protected environment file, and the accounts/directories from the prerequisite
script. It archives `HEAD`, installs from `package-lock.json`, and builds as
`signudoc-build`, not root. It keeps releases under `/opt/signudoc/releases`
with listing and traversal access for the build account; completed releases
remain restricted to root and the `signudoc` group. Deployment repairs the
two parent directory permissions from older installations before building.
`/opt/signudoc` belongs to `signudoc-deploy:signudoc-deploy`; its owner can
replace entries in that directory, including the `current` symlink and
`releases` directory. Treat that account as trusted for deployments and limit
access to it. The releases directory itself belongs to root, so the build
account cannot create or replace releases. The script switches
`/opt/signudoc/current` only after a controlled database migration.

Run it from the repository root:

```sh
sudo bash selfhosted/scripts/deploy.sh
```

After the build, the script asks for the reference and UTC creation time of a
recent successful PBS VM backup or other verified application-consistent
recovery point. Check the Proxmox task log for successful freeze/thaw handling,
confirm the required VM disks were included, check PBS verification status,
and compare the point's age with the school's approved recovery-point
objective. The script displays the age and requires the exact phrase
`PBS-VERIFIED <reference> <UTC-time>`; a yes/no answer is not accepted. It
cannot inspect or modify Proxmox jobs. Run deployments outside a PBS backup
window and confirm no backup is in progress or will overlap the migration.
Declining the checkpoint runs no migrations and does not pause services.

After confirmation, the script stops the retention timer, waits up to six
minutes for an active retention job, writes a root-owned deployment marker,
and stops the app. It does not pause or start PBS jobs. If stopping retention
or the app fails, no migration runs; on later failures the marker remains for
manual review.

The existing migration command then runs as `signudoc` in a
temporary systemd unit using the protected environment file. The script never
runs `db:reset`. If migration fails, it leaves the app and timer stopped and
the marker in place; some earlier migration files may already have committed.
After migration succeeds it switches the release, starts the app, checks
`http://127.0.0.1:3000/login`, then enables and starts the app and retention
timer. A start or health-check failure leaves the marker in place and stops
the app. No database or code rollback is attempted automatically. Review the
journal, migration table, current symlink, confirmed recovery point, and
retained releases before manual recovery.

## Apache and HTTPS

Allow only inbound TCP 80 and 443 plus SSH restricted to the administrators'
management network. Keep ports 3000 and 5432 unreachable externally. Permit
outbound package downloads, HTTPS for Certbot, the password breach check, and
the configured SMTP destination. The build also fetches the application's
Google font from `fonts.googleapis.com` and `fonts.gstatic.com`; an offline or
restricted build needs a separate local-font preparation before deployment.
SMTP uses IPv4-only address resolution.

Replace `signudoc.example.com` in the Apache files and environment example with
the school's public DNS name. Point its DNS A record to the VM's public IPv4
address. Only publish an AAAA record if IPv6 routing and the host firewall are
deliberately configured; this app's SMTP transport itself never tries IPv6.
Do not put private network addresses or real school names in the checked-in
examples.

Before the first deployment, install the bootstrap vhost as described in Build
and deploy. After the application deployment and public DNS are ready, enable
the required Apache modules and HTTP challenge vhost:

```sh
sudo a2enmod proxy proxy_http headers ssl rewrite
sudo install -d -o root -g root -m 0755 /var/lib/letsencrypt/.well-known/acme-challenge
sudo a2ensite signudoc.conf
sudo apachectl configtest
sudo systemctl reload apache2
```

After public DNS resolves and inbound port 80 is allowed, request the
certificate on the VM (not from this repository workflow):

```sh
sudo certbot certonly --webroot -w /var/lib/letsencrypt \
  -d signudoc.example.com --email replace-with-ops@example.com --agree-tos
```

Replace the email and hostname first. Once Certbot has created the certificate,
install the final `selfhosted/apache/signudoc.conf` over
`/etc/apache2/sites-available/signudoc.conf`, run `sudo apachectl configtest`,
then reload Apache. Keep the ACME challenge alias available for renewal.
Confirm Certbot's renewal timer is enabled and test renewal only on the VM.
Because the final vhost and certificate were added after the pre-deployment
checkpoint, schedule a consistent backup after this setup (and after later
secret, Apache, systemd, or certificate changes) so the recovery snapshot
contains the current host configuration.

The TLS vhost proxies to `127.0.0.1:3000`, preserves the validated Host,
sets the forwarded scheme to HTTPS, and uses a 300-second proxy timeout. It
allows 22 MiB of request body to leave room for multipart overhead around the
application's 20 MiB PDF file limit. Production Next.js does not have a
WebSocket route, so the example does not enable WebSocket tunneling. The app
already sets its Content-Security-Policy, HSTS, frame, content-type, and
referrer headers; the vhost avoids overriding those headers and breaking
signing/preview pages.

For client IP protection, the TLS vhost removes incoming `Forwarded`,
`X-Forwarded-*`, `X-Real-IP`, Cloudflare, Vercel, and common client-IP headers
early, then lets `mod_proxy` add the address of the TCP peer Apache observed
([`ProxyAddHeaders`](https://httpd.apache.org/docs/2.4/mod/mod_proxy.html#proxyaddheaders),
[`RequestHeader`](https://httpd.apache.org/docs/2.4/mod/mod_headers.html#requestheader)).
This matches SignuDoc's use of the first `X-Forwarded-For` address for rate
limits and audit events. Do not enable `mod_remoteip` or place an untrusted
proxy/CDN in front of this vhost. If another trusted proxy is introduced,
revisit the chain and trust configuration; otherwise Apache can only identify
that proxy as the client.

## systemd operations

The deployment script enables `signudoc.service` and
`signudoc-retention.timer` after a successful first deployment. Common checks:

```sh
sudo systemctl status signudoc.service
sudo systemctl status signudoc-retention.timer
sudo systemctl list-timers signudoc-retention.timer
sudo journalctl -u signudoc.service -n 100 --no-pager
sudo journalctl -u signudoc-retention.service -n 100 --no-pager
sudo systemctl restart signudoc.service
```

The health check is a basic local HTTP check of `/login`; this repository does
not define a dedicated health endpoint. It does not prove database writes,
SMTP delivery, or signer workflow end-to-end. From the admin UI, verify the
email status and send an administrative test email after SMTP configuration.
Then complete first-time organization setup with `SETUP_TOKEN`, create the
first administrator, remove the one-time setup token from the environment file,
and restart the app. The first deployment script refuses to proceed unless
that token is a non-placeholder 64-character hex value. `BETTER_AUTH_URL` and
`APP_URL` must remain the public HTTPS origin so cookies and generated links
use HTTPS. The app's setup policy defaults to restricting accounts to the
administrator's email domain;
invite external signers through the document signing workflow rather than
opening public account registration.

For a settings change, edit the protected env file, then restart the app:

```sh
sudoedit /etc/signudoc/signudoc.env
sudo systemctl restart signudoc.service
```

If `RETENTION_JOB_SECRET` changes, edit `/etc/signudoc/retention.env` and
restart the app so the endpoint accepts the same value the next timer run will
send.

The retention timer runs daily near 08:15 UTC, staggered by up to five minutes.
It calls the existing `GET /api/internal/retention` endpoint on loopback with
`Authorization: Bearer <RETENTION_JOB_SECRET>`. The secret is read from its
separate protected `retention.env` file and supplied to curl over stdin, never as a
command-line value or log message. A non-2xx response or timeout fails the
oneshot unit and is visible in journald. It does not retry immediately: a
timed-out request could have completed its work, and the next scheduled run is
the safe retry. `Persistent=true` causes a missed timer run to start after the
VM returns. The existing endpoint and database lock own all retention,
reminder, and expiration logic.

## Upgrades and troubleshooting

Commit the desired version, update the checkout on the VM through the school's
approved source-control process, confirm it is clean, and run the same
`deploy.sh`. Review the migration files in that release and complete the
backup checkpoint when prompted. Old release directories are retained for
manual review; do not point `current` at an older release after a schema change
without checking compatibility. Database migrations may not be reversible.

Common checks:

- **App fails at start:** inspect `journalctl -u signudoc.service`; check that
  `DATABASE_URL`, `BETTER_AUTH_SECRET`, `APP_URL`, `BETTER_AUTH_URL`, `PORT`,
  and the current release are correct.
- **Login/cookies or generated links use HTTP:** verify both public URL values
  use the same `https://` origin and the HTTPS vhost sets
  `X-Forwarded-Proto: https`.
- **Client IPs are missing or all show a proxy:** ensure the Apache vhost is
  the first public proxy or review the upstream proxy trust boundary. Never
  restore raw visitor-supplied forwarding headers.
- **Upload returns 413:** check Apache's 22 MiB `LimitRequestBody` and the
  application's own 20 MiB PDF limit.
- **SMTP status is incomplete:** verify the `EMAIL_DRIVER`, `SMTP_HOST`, TLS
  mode, sender and optional paired credentials; DNS must provide an IPv4
  address. Check outbound firewall policy and then use the admin test-send.
- **Retention returns 401:** ensure the protected file contains the same
  `RETENTION_JOB_SECRET` loaded by systemd, then inspect the oneshot journal.
- **A deployment marker exists:** the previous deploy failed after pausing
  services or attempting migration. Do not delete it or restart units until an
  administrator has reviewed the DB migration table, current release, logs,
  and confirmed PBS recovery point.
- **Sign-up fails on a password check:** allow outbound HTTPS to
  `api.pwnedpasswords.com`, or intentionally set `PASSWORD_BREACH_CHECK=off`
  after considering that password screening will be disabled.

## Backup and restore

See the [Debian PBS backup and recovery guide](pbs/README.md) for the
application-consistent VM backup, verification, restore, and recovery
checklist. The Vercel Blob procedure in
[`docs/backup-and-restore.md`](../docs/backup-and-restore.md) applies only to
hosted Blob installations.

The QEMU Guest Agent hook stops retention and SignuDoc, cleanly stops
PostgreSQL, and then allows Proxmox to freeze the guest filesystems while it
starts the VM snapshot. The Debian OS, PostgreSQL data and migration state,
local document tree and sidecars, releases, protected settings and secrets,
Apache/systemd configuration, certificates, and every included VM disk are
protected by PBS together. PBS encryption keys, if used, must also be escrowed
outside the VM.

No extra SignuDoc backup schedules remain; its daily retention timer is
separate from PBS. This repository work is preparation, not proof of the
school's actual backup or restore. Before signer access, verify the existing
Proxmox job includes every required disk, check a successful application
consistent task, and complete a restore drill on an isolated VM.
