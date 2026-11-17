# Debian backup and recovery with Proxmox Backup Server

This guide covers the Debian 13 self-hosted deployment. It integrates with the
school's existing Proxmox VE and PBS VM backup workflow. It creates no
SignuDoc backup repository, backup schedule, backup credentials, or retention
policy. The Vercel Blob procedure in
[`docs/backup-and-restore.md`](../../docs/backup-and-restore.md) applies only
to hosted Blob installations.

This repository contains a guest-agent hook and recovery checks, but it has
not been tested against the school's Proxmox environment. Before signer
access, verify the configured VM backup and complete a restore drill in an
isolated environment.

## Recommended architecture

Use an existing Proxmox VM backup in snapshot mode, with QEMU Guest Agent
enabled and the SignuDoc hook configured inside Debian. Proxmox calls the
guest agent before its VM snapshot and after filesystems are thawed. The hook
quiesces the services that can change SignuDoc's database and document state:

1. Stops the SignuDoc retention timer and waits for any active retention run
   to finish successfully. Retention may delete document files and update
   database rows. A timeout or failed retention result aborts the freeze.
2. Stops `signudoc.service` so requests cannot create or replace documents.
3. Cleanly stops active Debian PostgreSQL services. This lets PostgreSQL flush
   and close the database before its data files are captured.
4. Returns success so QEMU Guest Agent can sync and freeze guest filesystems.
   Proxmox then starts its VM backup snapshot.
5. When Proxmox thaws the guest filesystems, the hook starts only the
   PostgreSQL services, SignuDoc service, and retention timer that were active
   before the freeze.

Stopping both the application and database makes the database and local
document tree stable even when they are on separate virtual disks. The
filesystem freeze alone is not a PostgreSQL logical backup. A `pg_dump`
captured at one time and live document files captured later would also not
establish one application-consistent recovery point. No dump or app-level
archive is needed for a full VM backup when all required disks are included.

This uses Proxmox's guest-agent freeze/thaw cycle together with brief
application quiescing. The expected outage is around the snapshot start: the
app and database are stopped for the short period between the hook and thaw,
not for the full PBS data transfer. Measure this in a test backup before
setting school expectations. If the guest-agent hook fails, QEMU returns an
error for the freeze request. Inspect the Proxmox task log and Debian guest
journal; treat any skipped, failed, or unpaired freeze/thaw event as an
application-consistency failure even if data transfer appears to complete.

## Strategy comparison

| Approach | Advantages | Limitations | Decision |
| --- | --- | --- | --- |
| QEMU Guest Agent filesystem freeze alone | Native Proxmox integration; briefly syncs and freezes guest filesystems | Does not stop application writes or guarantee database and document-level consistency on its own | Use the native cycle with the hook below |
| PostgreSQL dump before PBS captures live files | Portable logical database export; can be useful for database-only recovery | A dump and a later live document capture can represent different points; needs additional coordination and uses duplicate in-VM storage | Not needed for full VM recovery |
| Stop/quiesce the application | Prevents new SignuDoc document operations | Does not stop PostgreSQL or the separate retention worker by itself | Included in the hook, along with PostgreSQL shutdown and retention drain |

The hook relies on standard Debian `postgresql.service` and
`postgresql@<version>-<cluster>.service` units. If PostgreSQL is managed by a
custom service or cluster command, adapt and test the hook before relying on
it. Keep the database and `/var/lib/signudoc/documents` on local filesystems
backed by included VM disks. A separate virtual disk is fine if it is included
in the same VM backup. Network mounts and storage excluded from Proxmox backup
are not protected by this design.

## Configure the Debian guest and Proxmox VM

The prerequisites script installs `qemu-guest-agent` and Python 3. It does not
change the Proxmox VM settings or configure the hook.

1. Install the hook from a trusted checkout on the Debian VM:

   ```sh
   sudo install -o root -g root -m 0750 \
     selfhosted/pbs/signudoc-fsfreeze-hook.sh \
     /usr/local/sbin/signudoc-pbs-fsfreeze-hook
   ```

2. Review `/etc/qemu/qemu-ga.conf`. In its existing `[general]` section, set
   the direct hook path below; create `[general]` if the section is absent:

   ```ini
   [general]
   fsfreeze-hook=/usr/local/sbin/signudoc-pbs-fsfreeze-hook
   ```

   Do not overwrite an existing custom freeze hook without preserving its
   behavior. QEMU accepts one hook path. A distribution hook that dispatches
   child scripts may ignore their failures, so do not place the critical
   SignuDoc hook only in such a child directory.

3. In Proxmox VE, enable **QEMU Guest Agent** for the SignuDoc VM. Ensure the
   VM's backup job uses snapshot mode and does not disable filesystem freeze.
   Restart the guest agent in Debian and check its status:

   ```sh
   sudo systemctl enable --now qemu-guest-agent
   sudo systemctl restart qemu-guest-agent
   sudo systemctl status qemu-guest-agent --no-pager
   ```

4. During a maintenance window, test guest-agent ping and one freeze/thaw
   cycle from the Proxmox host. For example, use the VM's actual ID and run
   these commands one at a time:

   ```sh
   qm guest cmd <VMID> ping
   qm guest cmd <VMID> fsfreeze-freeze
   qm guest cmd <VMID> fsfreeze-thaw
   ```

   Check the guest log:

   ```sh
   sudo journalctl -t signudoc-pbs-hook --since today --no-pager
   ```

   Verify the application, PostgreSQL, and retention timer return to the same
   active/inactive state as before the test. Do not leave filesystems frozen.
   The QEMU Guest Agent documentation describes the hook order and the
   freeze/thaw commands: [QEMU Guest Agent](https://www.qemu.org/docs/master/interop/qemu-ga.html),
   [Guest Agent protocol](https://www.qemu.org/docs/master/interop/qemu-ga-ref.html).

5. Add the SignuDoc VM to the school's existing Proxmox backup job. In its
   disk settings, include every virtual disk that contains any of:
   `/var/lib/postgresql`, `/var/lib/signudoc/documents`, `/opt/signudoc`,
   `/etc/signudoc`, `/etc/apache2`, `/etc/systemd`, `/etc/qemu`, and
   `/etc/letsencrypt`. Do not mark a required disk `backup=0` or otherwise
   exclude it. The VM root disk normally contains most paths; separately
   mounted data disks must also be included. Review the task log's included
   disk list.

Run a successful PBS backup and inspect the Proxmox task log and guest journal
for successful freeze and thaw handling. If any required service fails to
stop or restart, or the freeze/thaw reports an error, reject that point as
application-consistent and correct the hook before relying on another backup.
PBS verification status is managed in Proxmox/PBS; this repository does not
query the PBS API or change the job. See the [Proxmox VE vzdump
documentation](https://github.com/proxmox/pve-docs/blob/master/vzdump.adoc)
for VM backup and QEMU Guest Agent integration details.

## What PBS protects

The full VM backup includes the Debian system and all included VM disks. That
captures:

- PostgreSQL data, cluster configuration, SignuDoc records, signing sessions,
  migration ledger, and audit history.
- Original PDFs, signed PDFs, evidence, certificate and revision files,
  templates, field images, and their local `.meta.json` sidecars under
  `/var/lib/signudoc/documents`.
- `/etc/signudoc/signudoc.env`, including `DATABASE_URL`, SMTP configuration,
  `BETTER_AUTH_SECRET`, and configured P12 signing values; the retention
  environment file; Apache and systemd configuration; the guest-agent hook;
  and local Certbot certificates and private keys when present.
- The deployed application release and local PostgreSQL migration state.

These contents include credentials and private keys. Restrict access to PBS
and the backup task logs. If client-side PBS encryption is enabled, escrow the
matching encryption key and any master recovery key outside the VM in an
approved secure location. Do not put recovery keys only inside the VM backup
they unlock. Preserve `BETTER_AUTH_SECRET` exactly; changing it can make
stored authentication and sealing material unreadable. Protect customer P12
material as sensitive signing credentials.

The database-to-document checker below validates recorded object references,
available database SHA-256 values, and sidecar JSON. It does not verify PDF
signatures or the cryptographic integrity of every PBS chunk; those are
separate checks.

## PBS schedule, verification, and retention

Proxmox/PBS owns the backup schedule, repository verification, snapshot
retention, deduplication, garbage collection, datastore capacity, and VM
restore. Use the school's existing approved policy. An example to discuss is
14 daily, 8 weekly, and 12 monthly restore points; this repository does not
configure or enforce those values. Confirm the VM's task history and PBS
verification status in the Proxmox/PBS interface.

PBS backup retention is separate from SignuDoc's legal and operational
document-retention policy. SignuDoc's own daily retention timer remains for
application document lifecycle work; it is not a backup or a PBS retention
schedule. The freeze hook pauses that timer only while creating the snapshot
point and restarts it if it was active before.

## Deployment checkpoint

Before a deployment that can run migrations, create or select a recent
successful PBS VM backup (or another verified application-consistent recovery
point). Check the Proxmox task log for included disks and successful freeze
and thaw, and check any configured PBS verification result. Compare its UTC
creation time with the school's approved recovery-point objective. Do not
run deployment while a Proxmox VM backup is in progress or could overlap the
migration window. Deployment does not use an API credential, inspect or
change PBS jobs, trigger a backup, or infer success from a local dump.

`selfhosted/scripts/deploy.sh` builds first, then asks the operator to enter a
recovery-point reference and UTC timestamp. It calculates and displays the
age but leaves the approved RPO decision to the operator. It requires the
exact response `PBS-VERIFIED <reference> <UTC-time>` before it pauses
retention, stops the application, and runs migrations. It does not claim
migration rollback support. If the checkpoint is declined or invalid, no
service is stopped and no migration runs.

## Full VM restore drill

Perform a restore drill before production use and periodically after major
infrastructure or secret changes. Use an isolated Proxmox environment and a
new VM ID. Never restore over a running production VM.

1. In Proxmox/PBS, select a completed, verified backup whose task log shows
   all required disks and successful freeze/thaw handling. Record the
   reference and UTC timestamp.
2. Restore the VM as a separate test VM on isolated storage. Restore every
   disk needed for the OS, PostgreSQL, and document storage. Do not attach it
   to the public network or production VLAN; disable or disconnect its
   network adapter initially.
3. Keep Apache and SignuDoc disabled while checking the restored VM. Start the
   normal PostgreSQL cluster and confirm it reaches `active` without recovery
   errors:

   ```sh
   sudo systemctl status postgresql.service --no-pager
   sudo journalctl -u postgresql.service --since boot --no-pager
   ```

4. Confirm `/var/lib/signudoc/documents` and its sidecars are on the restored
   disk. Run the restored database-to-file check from a trusted copy of this
   repository:

   ```sh
   sudo selfhosted/pbs/validate-restored-data.sh \
     --database signudoc \
     --storage /var/lib/signudoc/documents
   ```

   This checks the SignuDoc migration ledger and required tables, enumerates
   database document keys, checks referenced files and recorded hashes, and
   requires valid local sidecar metadata. It uses the local PostgreSQL
   `postgres` account and prints counts, not document contents or secrets.

5. Compare `DATABASE_URL` with the restored cluster and confirm migration
   state. Preserve the original `BETTER_AUTH_SECRET`, SMTP settings, retention
   secret, and any configured P12 values. Never print environment files or
   private keys into a ticket or terminal log.
6. In the isolated environment, enable SignuDoc and Apache only after the
   database and document checks pass. Use a controlled private path to verify
   administrator authentication, a representative original and signed PDF,
   its signature/seal, and representative document and system audit trails.
   Keep public access and production DNS disabled.
7. Record the drill result, elapsed restore time, missing prerequisites, and
   any problems. Shut down the test VM or leave it isolated. Do not change
   production DNS or restore over production as part of the drill.

The full-VM procedure restores database and documents from the same VM backup
point. A partial recovery needs a coordinated restore of PostgreSQL's complete
cluster data and configuration plus the complete document tree and sidecars
from that same point, along with the original secrets and application config.
Do not combine a database from one time with documents from another. Partial
recovery requires an operator to stop the app and carefully restore ownership,
permissions, cluster configuration, and migration state; no partial restore
script is provided here.

## Validation scope

The local tests exercise hook ordering, service-state restoration, retention
draining, failure handling, checkpoint confirmation, and document/hash
validation. They use fake systemd commands. They cannot prove the school's
guest-agent configuration, Proxmox task behavior, PBS retention, encryption-key
recovery, or an actual VM restore. Those require the manual Proxmox setup and a
real isolated restore drill described above.
