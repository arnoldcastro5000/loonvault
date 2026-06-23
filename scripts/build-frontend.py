#!/usr/bin/env python3
"""Assemble the LoonVault static site into frontend/dist/.

The site renders docs LIVE in the browser (first-party renderer, same-origin fetch),
so this build does not produce HTML from Markdown. It just:
  1. copies the static site (index.html, docs.html, assets/) into dist/;
  2. copies the curated set of repo docs into dist/content/<key>.md (so they are
     served same-origin from the site bucket);
  3. writes dist/content/manifest.json (key, title, group, path) for the viewer.
Stdlib only (no pip). See ADR-0012. Run via `just build-frontend`.
"""
import json
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FRONTEND = ROOT / "frontend"
DIST = FRONTEND / "dist"

# Curated docs to publish, in display order. (file, group)
DOCS = [
    ("CONTEXT.md", "Overview"),
    ("docs/threat-model.md", "Security"),
    ("policies/COMPLIANCE.md", "Security"),
    ("docs/runbook.md", "Operations"),
    ("docs/devcontainer.md", "Operations"),
]
DOCS += [(str(p.relative_to(ROOT)), "Decision records (ADRs)") for p in sorted((ROOT / "docs/adr").glob("*.md"))]

STATIC_FILES = ["index.html", "docs.html"]


def title_of(text: str, fallback: str) -> str:
    m = re.search(r"^#\s+(.*)$", text, re.M)
    return m.group(1).strip() if m else fallback


def main() -> None:
    if DIST.exists():
        shutil.rmtree(DIST)
    DIST.mkdir(parents=True)
    shutil.copytree(FRONTEND / "assets", DIST / "assets")
    for f in STATIC_FILES:
        shutil.copy(FRONTEND / f, DIST / f)
    content_dir = DIST / "content"
    content_dir.mkdir()

    manifest = []
    print("frontend build:")
    for rel, group in DOCS:
        src = ROOT / rel
        if not src.exists():
            print(f"  WARN missing doc, skipped: {rel}")
            continue
        text = src.read_text()
        key = src.stem
        (content_dir / f"{key}.md").write_text(text)
        manifest.append({
            "key": key,
            "title": title_of(text, key),
            "group": group,
            "path": f"content/{key}.md",
        })
    (content_dir / "manifest.json").write_text(json.dumps({"docs": manifest}, indent=2))
    print(f"  copied {len(STATIC_FILES)} pages + assets/ -> {DIST.relative_to(ROOT)}")
    print(f"  published {len(manifest)} docs -> {(content_dir).relative_to(ROOT)}/")
    print(f"done -> {DIST.relative_to(ROOT)}/")


if __name__ == "__main__":
    main()
