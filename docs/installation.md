# Installation

[← Back to README](../README.md)

## Requirements

Install Ultimate Updater as root on one supported Proxmox VE host. Release
5.1 is validated on Proxmox VE 8.4 (Debian 12) and 9.x (Debian 13); the Web UI
uses the Python 3 interpreter that ships with the host. A cluster uses one
central installation; a standalone node can run it by itself. Do not install
a separate administrative instance on every cluster node.

For cluster operation, nodes must resolve each other by the names and
addresses used by Proxmox and have working SSH fingerprints. VMs included in
checks or updates need either a working QEMU Guest Agent with `guest-exec` or
configured key-based SSH; see [SSH and VM access](ssh.md) for the detailed
guest requirements. Keep current backups before enabling mutating updates.

## Install

Stable `master`:

```bash
installer=$(mktemp)
curl -4 -fSL --retry 0 https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh -o "$installer" && \
  bash -n "$installer" && bash "$installer"
rm -f "$installer"
```

The installer validates its inputs and keeps the existing configuration.

### Installing from a fork

The installer and every self-update download from the upstream
`BassT23/Proxmox` repository by default. To run a fork instead, set
`UU_REPOSITORY` to the fork's GitHub `owner/name` when running its installer:

```bash
installer=$(mktemp)
curl -4 -fSL --retry 0 https://raw.githubusercontent.com/OWNER/Proxmox/master/install.sh -o "$installer" && \
  bash -n "$installer" && UU_REPOSITORY=OWNER/Proxmox bash "$installer"
rm -f "$installer"
```

The repository is recorded in `/etc/ultimate-updater/build-metadata`, so
`update -up` keeps updating from the fork. The `master` channel installs the
fork's latest GitHub release, or its `master` branch when the fork publishes
no releases. To switch back, run `UU_REPOSITORY=BassT23/Proxmox update master -up`.

## First steps

1. Review `/etc/ultimate-updater/update.conf`.
2. Prepare VM access if VMs are included; see [SSH and VM access](ssh.md).
3. Add external systems only when needed; see [External systems](external-systems.md).
4. Confirm `ultimate-updater-web.service` is active.
5. Open `https://<proxmox-node>:8765/` and run a check before an update.

To inspect help from the host, run `update -h` or `ultimate-updater --help`.

## Removing or repairing an installation

Use the installer from the same branch with the `uninstall` action only after
reviewing what is installed. Keep `/etc/ultimate-updater/update.conf` and
backups if you plan to reinstall.

Related: [Upgrading](upgrading.md), [Configuration](configuration.md).
