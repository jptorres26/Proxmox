# Contributing

Thanks for helping to improve Ultimate Updater. It runs as root on Proxmox VE
hosts and changes production systems, so every change needs to be reviewable,
tested, and conservative about side effects.

## Requirements

- Bash 5.2 or newer (Proxmox VE 8 and 9 both ship 5.2).
- Python 3.11 or newer. The Web UI must stay standard-library only and run on
  Python 3.11 (Proxmox VE 8 / Debian 12) and 3.13 (Proxmox VE 9 / Debian 13).
- `ss` (from `iproute2`) and `timeout` for the regression tests.

Install the pinned lint tools (ShellCheck, Ruff, actionlint), preferably in a
virtual environment:

```bash
python3 -m venv .venv && . .venv/bin/activate
python3 -m pip install -r requirements-dev.txt
```

## Checks

CI runs exactly these commands:

```bash
tests/lint.sh          # ShellCheck, Ruff, actionlint
tests/run-all.sh       # every regression test in tests/
sudo env "PATH=$PATH" tests/run-all.sh   # root-only fixtures as well
```

`tests/run-all.sh` accepts name filters, for example `tests/run-all.sh qga web`.
The regression tests use temporary fixtures and command stubs; they never
touch a real Proxmox installation. Live validation on dedicated test nodes
is described in [TESTING.md](TESTING.md) and
[tests/HARDCORE_TEST.md](tests/HARDCORE_TEST.md). Never run write tests
against production systems.

## Conventions

- Shell: two-space indentation, `[[ ... ]]` tests, quoted expansions, and
  arrays instead of word splitting. Command strings executed inside guests or
  External systems must stay POSIX `sh` compatible (Alpine and FreeBSD have
  no Bash by default).
- Keep ShellCheck clean. Prefer a targeted, commented
  `# shellcheck disable=SCxxxx` on a single line over a file-wide directive.
- Python: follow `ruff.toml`; no third-party runtime dependencies.
- Web UI: the page is the `PAGE` template in `web-ui/server.py`. Edit the
  template directly; `tests/test-web-page-structure.py` checks that its
  markup stays balanced and that element IDs are unique.
- Add or update a regression test with every behavior change.
- Commit messages follow the existing `type: summary` style (`fix:`, `test:`,
  `ci:`, `docs:`, `refactor:`, `release:`).
