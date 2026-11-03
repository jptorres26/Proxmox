#!/usr/bin/env python3
"""Top bar, flat KPI strip and the Settings save bar are in the page."""

import importlib.util
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("server", ROOT / "web-ui" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
page = server.PAGE

# A visible heading and the icon replace the wide banner image.
assert '<h1 class="brand-name">Ultimate Updater</h1>' in page
assert 'class="brand-mark" src="/assets/ultimate-updater-icon.png"' in page
assert "brand-header-art\" src=" not in page

# Desktop: the page links are tabs in the bar; the hamburger is phone-only.
assert "body .dashboard-meta .nav-toggle{display:none!important}" in page
assert "body .dashboard-meta .page-nav{pointer-events:auto!important;position:static!important" in page

# A missing figure is a dash with an explanation, never the long word.
render = re.search(r"render=function\(data\)\{renderWithSplitSummary.*?\};", page, re.S).group(0)
assert "'Unknown'" not in render
assert "normal===null?'—':normal" in render and "security===null?'—':security" in render
assert "Not checked yet" in render
assert ".dashboard-kpis .metric strong{font-size:1.6rem;line-height:1.1;white-space:nowrap" in page

# Settings: unsaved-change count with Discard and Save in a sticky bar.
assert 'id="config-dirty" class="config-dirty" role="status" aria-live="polite"' in page
assert '<button type="button" id="config-close">Discard changes</button>' in page
assert "#settings-page #config-form .config-actions{position:sticky;bottom:12px" in page
assert "function configDirtyState(form)" in page and "function updateConfigDirty(form)" in page

print("web top bar and save bar: PASS")
