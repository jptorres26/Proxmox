# Web UI

[← Back to README](../README.md)

The Web UI is served by `ultimate-updater-web.service` and listens on port
`8765` by default:

```text
https://<proxmox-node>:8765/
```

It uses the Proxmox-managed certificate when available, accepts TLS 1.2 or
newer, and can use an explicitly configured certificate pair. If automatic
HTTPS has no usable certificate, the documented transition fallback is HTTP;
set `WEB_UI_HTTPS=true` when HTTPS must be required. Use the trusted
management network; this is an action-enabled administrator interface.

## Main areas

- **Dashboard:** nodes, LXC/VM guests, external targets, reachability, update
  state, reboot indicators, and warnings.
- **Target details:** OS, transport, normal/security or total-only update
  information, last check, and errors.
- **Jobs and logs:** persistent server-side job state and retained output.
- **Settings:** typed controls for checks, filters, lifecycle, snapshots,
  backups, notifications, and DEBUG.
- **Internal SSH Connections:** resolved sources and explicit overrides for
  nodes and VMs.
- **Version information:** installed version, branch, commit, exact tag when
  available, and available version.

### Dashboard

The dashboard combines the system overview, node and guest status, external
targets, and server-side jobs in one view.

![Ultimate Updater dashboard](images/web-ui/dashboard.png)

### Navigation

Use the compact menu button in the header to open the current navigation. It
contains the three available areas: Dashboard, Settings, and Scheduler.

![Web UI navigation menu](images/web-ui/navigation.png)

### Settings

Settings are grouped into connection management, target selection, update
behavior, backup and safety, extra updates, and notifications.

Saving writes only the settings you changed, as `KEY="value"` lines that the
scripts read back unchanged; comments and unrelated lines are kept. Values
are checked per setting: quotes, backslashes, control characters, shell
metacharacters where a value reaches a command line, and a leading `-` are
rejected with a message that names the setting. The editor shows what the
scripts actually use, so an indented or unquoted assignment that the
scripts ignore appears empty until it is saved from the UI. **Cancel**
discards unsaved changes.

![Web UI settings](images/web-ui/settings.png)

### Jobs and logs

Jobs run server-side and remain available after the browser session ends. The
Jobs view shows the action, target, start time, result, exit code, and a link
to the retained log.

![Web UI jobs and logs](images/web-ui/jobs.png)

### Scheduler

The Scheduler uses the existing job runner and safety rules. It supports
enabled schedules, selected weekdays, next and last run information, and the
actions Edit, Run now, Disable, and Delete. The last run shown for a schedule
is the latest job started by that schedule (by its timer or **Run now**);
schedule units created by older releases are updated when the Web UI
service starts.

![Web UI scheduler](images/web-ui/scheduler.png)

The UI does not expose a general shell, arbitrary commands, private keys, or
password storage. Configuration writes preserve unrelated settings and are
validated atomically. Updates require browser confirmation.

## Authentication and service control

Normal Proxmox installations authenticate the local administrator through PAM.
The service is root-owned because the existing CLI and job runner need local
permissions.

- Only `root` can sign in, with the host's PAM `login` service. Proxmox
  two-factor authentication (TOTP/WebAuthn realms) is **not** applied to this
  login; restrict access to the management network accordingly.
- Each client may fail five logins per minute; login results are logged to
  the service journal (`journalctl -u ultimate-updater-web`), for example for
  fail2ban.
- Sessions expire after 8 hours without activity and at the latest 12 hours
  after sign-in. The session cookie is `HttpOnly`, `SameSite=Strict`, and
  `Secure` when HTTPS is active.
- Responses carry a Content Security Policy that allows only the page's own
  inline scripts (by hash), deny framing, and disable MIME sniffing and
  referrers. A reverse proxy in front of the Web UI must pass these headers
  through unchanged.

Useful service commands are:

```bash
systemctl status ultimate-updater-web
systemctl restart ultimate-updater-web
journalctl -u ultimate-updater-web
```

The interface is responsive on narrow displays. The dashboard can also show
an expanded external-system section when target details are needed.

![Dashboard with expanded external systems](images/web-ui/dashboard-expanded.png)

The optional login welcome screen is separate from the Web UI. It can show
cached update information at login and uses the local check configuration;
the cache is refreshed by the regular update check. It does not wait for a
live GitHub version request during login.

Related: [Configuration](configuration.md), [SSH and VM access](ssh.md),
[Troubleshooting](troubleshooting.md).
