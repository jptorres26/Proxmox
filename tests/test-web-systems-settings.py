#!/usr/bin/env python3
"""Systems filter, docked Jobs bar and the Settings rail, switches and inline errors are in the page."""

import importlib.util
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("server", ROOT / "web-ui" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
page = server.PAGE

# Systems: search box and filter chips above the list, with counts.
assert '<input id="systems-search" type="search"' in page
assert 'id="systems-chips" class="chips" role="group" aria-label="Filter systems"' in page
for key in ("all", "attention", "updates", "unreachable", "reboot"):
    assert f"['{key}'," in page, key
assert "function renderSystemChips(ts)" in page and "function renderFilteredSystems(list,ts)" in page
assert "chip.setAttribute('aria-pressed'" in page
# The KPI counts use every target; only the list is filtered.
assert "set('total',ts.length)" in page
assert "renderSystemChips(ts);if(!ts.length)" in page
# Filtered text is escaped the same way as everywhere else.
assert "`${esc(label)}<span class=\"chip-count\">" in page

# Jobs stay reachable beside a long list.
assert "#overview-page>#jobs{position:sticky;bottom:12px" in page

# Settings: section rail, switches, units inside the field and inline errors.
assert "function buildSettingsRail(form)" in page and "group.id=configGroupId(groupData)" in page
assert "IntersectionObserver" in page and "prefers-reduced-motion" in page
assert "#config-form .config-field input[type=checkbox]{-webkit-appearance:none;appearance:none" in page
assert "wrap.className='input-unit'" in page
assert "function configFieldProblem(input)" in page and "function showFieldProblem(input,problem)" in page
assert "note.setAttribute('role','alert')" in page
for message in ("Enter a whole number.", "Must be at least 1.", "Must be 0 or more.", "Must be 65535 or less."):
    assert message in page, message
# The range rules match the server's validation.
assert server.validate_config_values({"SSH_PORT": 65535})["SSH_PORT"] == "65535"
for bad in ({"SSH_PORT": 0}, {"SSH_PORT": 65536}, {"KEEP_SNAPSHOTS": 0}, {"LXC_START_DELAY": -1}):
    try:
        server.validate_config_values(bad)
    except ValueError:
        continue
    raise AssertionError(f"{bad} was accepted")

print("web systems filter and settings rail: PASS")
