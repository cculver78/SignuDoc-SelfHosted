# Changelog

- Ignore the generated active-release symlink so later deployments pass the
  checkout cleanliness check.
- Integrated upstream SignuDoc v0.4.0 while preserving the self-hosted SMTP,
  deployment, local storage, retention, and PBS behavior; documented the
  repeatable upstream upgrade and review process.
- Fixed release directory listing and checkout ownership for Debian builds.
- Ignore generated production release directories in the checkout.
- Restricted PDF font tracing to the required assets.
- Fixed build account traversal of the deployment release directories.
- Added Proxmox Backup Server VM backup integration, guest-agent quiescing, and
  Debian restore validation guidance.
- Added Debian self-hosting deployment examples and safe operator-gated upgrades.
- Added IPv4-only SMTP email delivery with TLS, optional authentication, sender overrides, and admin test-send support.
