#!/usr/bin/env python3
"""Structural checks for the single-page Web UI template.

The template is one large hand-edited string, so guard against unbalanced
elements and duplicate element IDs (getElementById would silently pick the
first match).
"""

import importlib.util
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ultimate_updater_web", root / "web-ui" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

# HTML void elements plus the SVG shapes the icons write as <path .../>.
VOID = {
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr",
    "circle", "line", "path", "polygon", "polyline", "rect", "use",
}


class StructureParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.errors = []
        self.ids = Counter()

    def record_id(self, attrs):
        for name, value in attrs:
            if name == "id":
                self.ids[value] += 1

    def handle_starttag(self, tag, attrs):
        self.record_id(attrs)
        if tag not in VOID:
            self.stack.append((tag, self.getpos()))

    def handle_startendtag(self, tag, attrs):
        self.record_id(attrs)

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if self.stack and self.stack[-1][0] == tag:
            self.stack.pop()
            return
        open_tag = self.stack[-1] if self.stack else None
        self.errors.append(f"</{tag}> at line {self.getpos()[0]} does not close {open_tag}")


parser = StructureParser()
parser.feed(server.PAGE)
parser.close()

assert server.PAGE.startswith("<!doctype html>")
assert server.PAGE.rstrip().endswith("</html>")
assert not parser.errors, parser.errors
assert not parser.stack, f"unclosed elements: {parser.stack}"
duplicates = {element_id: count for element_id, count in parser.ids.items() if count > 1}
assert not duplicates, f"duplicate element IDs: {duplicates}"
assert server.PAGE.count("<main") == server.PAGE.count("</main>") == 1

print("web page structure: PASS")
