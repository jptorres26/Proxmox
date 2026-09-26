# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 5.1.x   | :white_check_mark: |
| < 5.1   | :x:                |

Please upgrade to the current release with `update master -up` and confirm
that the problem still exists before reporting it.

## Reporting a Vulnerability

Please report vulnerabilities privately instead of opening a public issue:
use GitHub's private vulnerability reporting (**Security → Report a
vulnerability**) on the [project repository](https://github.com/BassT23/Proxmox)
if it is available there, or contact the maintainer directly on
[Discord](https://discord.gg/nVpUg6BKn8).

Include the installed version (`update status`), the Proxmox VE version
(`pveversion`), the affected component (for example the Web UI, installer,
or External SSH helper), and the steps needed to reproduce the problem.
Never include passwords, private keys, API tokens, or other production
credentials in a report.

Ultimate Updater runs as root on Proxmox VE hosts. Until a fix is available,
keep the Web UI on a trusted management network and do not expose it to the
internet.
