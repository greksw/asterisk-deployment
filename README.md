# Asterisk source deployment for AlmaLinux 9

A small Bash deployment utility for building and installing a pinned Asterisk release from source on AlmaLinux 9.

The project started as a one-off installation script. The current version keeps that practical scope but adds reproducible source verification, safer defaults, explicit service activation, and CI validation.

## What it does

`auto_install_asterisk.sh`:

- validates that the target is AlmaLinux 9;
- installs the required bootstrap/build packages;
- downloads a pinned Asterisk source archive over HTTPS;
- verifies the archive with a pinned SHA-256 digest before extraction;
- builds with bundled `pjproject`;
- installs Asterisk binaries and logrotate configuration;
- creates a dedicated `asterisk` system account when needed;
- creates runtime/data directories with restricted permissions;
- installs a systemd unit using the actual installed Asterisk binary path;
- optionally installs upstream sample configuration on a **fresh** `/etc/asterisk` only;
- optionally enables or starts the service.

The script does **not** configure SIP trunks, extensions, dial plans, firewall rules, NAT, TLS certificates, fail2ban, CDR storage, backups, monitoring, or production security policy.

## Default release

The repository currently pins:

- Asterisk `22.11.0` LTS;
- SHA-256 `3bd5ee040509a3d3cd9b1ba9520c18e6ec0a7e7981ca68c457dcd36ba3c54d94`.

The version and digest must be updated together. If `--version` is changed, the script refuses to continue unless a matching `--sha256` is supplied explicitly.

## Safety model

The old script downloaded source over plain HTTP and immediately built it. The current implementation uses HTTPS and verifies the downloaded tarball before executing any source-tree helper or build step.

Service activation is intentionally opt-in. A successful source installation does not automatically mean the PBX is correctly or securely configured.

`make samples` is also opt-in. `--install-samples` refuses to run when `/etc/asterisk` already contains `*.conf` files, preventing accidental replacement of an existing configuration.

## Preview the deployment

No root privileges are required to print the resolved plan:

```bash
./auto_install_asterisk.sh --print-plan
```

Example with an explicit build parallelism limit:

```bash
./auto_install_asterisk.sh --jobs 4 --print-plan
```

## Build and install

Run on a disposable or freshly prepared AlmaLinux 9 host first:

```bash
sudo ./auto_install_asterisk.sh --jobs 4
```

This installs the software and systemd unit but does not enable or start Asterisk.

Review the resulting configuration and unit before activation:

```bash
sudo systemd-analyze verify /etc/systemd/system/asterisk.service
sudo /usr/sbin/asterisk -V 2>/dev/null || command -v asterisk
```

The exact Asterisk binary path depends on the upstream build/install result; the generated unit uses the path detected by `command -v asterisk`.

## Lab installation with sample configuration

For a fresh lab VM only:

```bash
sudo ./auto_install_asterisk.sh \
  --install-samples \
  --enable-service
```

To also start the service after installation:

```bash
sudo ./auto_install_asterisk.sh \
  --install-samples \
  --start
```

`--start` implies `--enable-service`.

## Upstream prerequisite helper

The script installs a deterministic base set of build dependencies itself. If an Asterisk release needs additional distribution packages, the verified source tree can run the upstream prerequisite helper explicitly:

```bash
sudo ./auto_install_asterisk.sh --upstream-prereqs
```

This is not the default because `contrib/scripts/install_prereq` may change system packages beyond the repository's explicit dependency list. It is executed only **after** SHA-256 verification of the source archive.

## Installing a different Asterisk release

First obtain the release digest from the official Asterisk download site and verify it independently. Then supply both values:

```bash
sudo ./auto_install_asterisk.sh \
  --version 22.x.y \
  --sha256 '<64-character-sha256>'
```

Changing only `--version` is rejected.

## Files and directories

Default paths:

- build/download workspace: `/usr/local/src/asterisk-deployment`;
- deployment logs: `/var/log/asterisk-deployment`;
- Asterisk configuration: `/etc/asterisk`;
- runtime state: `/run/asterisk`;
- application state: `/var/lib/asterisk`;
- spool: `/var/spool/asterisk`;
- Asterisk logs: `/var/log/asterisk`.

The source workspace is deliberately retained after a successful build for troubleshooting and provenance. A rerun refuses to reuse an existing extracted build directory.

## Operational considerations

Before production use, at minimum review:

- SIP/PJSIP endpoint authentication and ACLs;
- TLS/SRTP requirements;
- firewall/NAT exposure;
- dial-plan authorization and toll-fraud controls;
- AMI/ARI exposure;
- log rotation and retention;
- monitoring and alerting;
- configuration backup and restore procedure;
- SELinux policy for the final deployment;
- upgrade and rollback procedure.

This repository is a source build/deployment helper, not a complete hardened PBX distribution.

## Validation

GitHub Actions checks:

- Bash syntax;
- ShellCheck warnings/errors;
- the default `--print-plan` output;
- version/checksum override guardrails.

A real source compilation is intentionally not performed in CI because the production target is AlmaLinux 9 and the complete build is comparatively expensive. Before adopting a new pinned release, perform an end-to-end build/start test on a disposable AlmaLinux 9 VM.

## Repository history

The repository preserves the original installation-script history. The v2 refactor removes insecure download behavior and unsafe implicit activation rather than replacing the project with an unrelated demo.

No license has been selected for this repository yet.
