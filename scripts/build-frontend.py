#!/usr/bin/env python3
"""Build the LoonVault static site from Markdown content + the repo's canonical docs.

Stdlib only (no pip). For each frontend/content/*.md it:
  1. resolves `<!-- include FILE [§ HEADING] -->` directives by pulling that section
     (or the whole file) from the repo, so pages are single-source-of-truth from the
     docs and can't drift;
  2. renders a focused Markdown subset (headings, paragraphs, lists, GFM pipe tables,
     fenced code, blockquotes, hr, inline bold/italic/code/links) to HTML;
  3. wraps it in frontend/template.html and writes frontend/dist/<name>.html.
The hand-written landing page (frontend/index.html) and frontend/assets/ are copied
verbatim into dist/.
See ADR-0012. Run via `just build-frontend`.
"""
import html
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FRONTEND = ROOT / "frontend"
CONTENT = FRONTEND / "content"
DIST = FRONTEND / "dist"
TEMPLATE = (FRONTEND / "template.html").read_text()

INCLUDE_RE = re.compile(r"^<!--\s*include\s+(\S+?)(?:\s+§\s+\"(.+?)\")?\s*-->\s*$")


def extract_section(text: str, heading: str) -> str:
    """Return the body under the heading whose text == `heading` (excluding the
    heading line itself), up to the next heading of the same or higher level."""
    lines = text.splitlines()
    out, level, capture = [], None, False
    for line in lines:
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            h_level, h_text = len(m.group(1)), m.group(2).strip()
            if not capture and h_text == heading:
                level, capture = h_level, True
                continue
            if capture and h_level <= level:
                break
        if capture:
            out.append(line)
    if not capture:
        sys.exit(f"build-frontend: section not found: '{heading}'")
    return "\n".join(out).strip("\n")


def strip_leading_h1(text: str) -> str:
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.strip():
            if re.match(r"^#\s+", line):
                return "\n".join(lines[i + 1:]).strip("\n")
            break
    return text


def resolve_includes(md: str) -> str:
    out = []
    for line in md.splitlines():
        m = INCLUDE_RE.match(line)
        if not m:
            out.append(line)
            continue
        target, heading = ROOT / m.group(1), m.group(2)
        if not target.exists():
            sys.exit(f"build-frontend: include target missing: {m.group(1)}")
        body = target.read_text()
        out.append(extract_section(body, heading) if heading else strip_leading_h1(body))
    return "\n".join(out)


def inline(text: str) -> str:
    # Escape first, then re-introduce a tiny, fixed set of inline markup.
    text = html.escape(text, quote=False)
    # code spans (protect from further processing via placeholders)
    spans = []

    def _stash(m):
        spans.append(m.group(1))
        return f"\x00{len(spans) - 1}\x00"

    text = re.sub(r"`([^`]+)`", _stash, text)
    text = re.sub(r"\[(.+?)\]\((.+?)\)", r'<a href="\2">\1</a>', text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<em>\1</em>", text)
    text = re.sub(r"\x00(\d+)\x00", lambda m: f"<code>{spans[int(m.group(1))]}</code>", text)
    return text


def render(md: str) -> str:
    lines = md.splitlines()
    out, i = [], 0
    n = len(lines)
    while i < n:
        line = lines[i]
        # fenced code
        if line.strip().startswith("```"):
            i += 1
            buf = []
            while i < n and not lines[i].strip().startswith("```"):
                buf.append(html.escape(lines[i]))
                i += 1
            i += 1
            out.append("<pre><code>" + "\n".join(buf) + "</code></pre>")
            continue
        # blank
        if not line.strip():
            i += 1
            continue
        # heading
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            lvl = len(m.group(1))
            out.append(f"<h{lvl}>{inline(m.group(2).strip())}</h{lvl}>")
            i += 1
            continue
        # hr
        if re.match(r"^(-{3,}|\*{3,})\s*$", line):
            out.append("<hr>")
            i += 1
            continue
        # table: header row of pipes followed by a |---| separator
        if "|" in line and i + 1 < n and re.match(r"^\s*\|?[\s:|-]+\|[\s:|-]*$", lines[i + 1]):
            headers = [c.strip() for c in line.strip().strip("|").split("|")]
            i += 2
            rows = []
            while i < n and "|" in lines[i] and lines[i].strip():
                rows.append([c.strip() for c in lines[i].strip().strip("|").split("|")])
                i += 1
            thead = "".join(f"<th>{inline(h)}</th>" for h in headers)
            tbody = "".join(
                "<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>" for r in rows
            )
            out.append(f"<table><thead><tr>{thead}</tr></thead><tbody>{tbody}</tbody></table>")
            continue
        # blockquote
        if line.lstrip().startswith(">"):
            buf = []
            while i < n and lines[i].lstrip().startswith(">"):
                buf.append(lines[i].lstrip()[1:].lstrip())
                i += 1
            out.append("<blockquote>" + inline(" ".join(buf)) + "</blockquote>")
            continue
        # lists
        if re.match(r"^\s*([-*]|\d+\.)\s+", line):
            ordered = bool(re.match(r"^\s*\d+\.\s+", line))
            tag = "ol" if ordered else "ul"
            items = []
            while i < n and re.match(r"^\s*([-*]|\d+\.)\s+", lines[i]):
                items.append(re.sub(r"^\s*([-*]|\d+\.)\s+", "", lines[i]))
                i += 1
            out.append(f"<{tag}>" + "".join(f"<li>{inline(it)}</li>" for it in items) + f"</{tag}>")
            continue
        # paragraph
        buf = []
        while i < n and lines[i].strip() and not re.match(r"^(#{1,6}\s|>|\s*([-*]|\d+\.)\s|```)", lines[i]):
            buf.append(lines[i])
            i += 1
        out.append("<p>" + inline(" ".join(buf)) + "</p>")
    return "\n".join(out)


def build_page(md_path: Path) -> None:
    raw = md_path.read_text()
    title_m = re.search(r"^#\s+(.*)$", raw, re.M)
    title = title_m.group(1).strip() if title_m else md_path.stem.title()
    body = render(resolve_includes(raw))
    page = TEMPLATE.replace("{{TITLE}}", html.escape(title)).replace("{{CONTENT}}", body)
    out_path = DIST / (md_path.stem + ".html")
    out_path.write_text(page)
    print(f"  built {out_path.relative_to(ROOT)}")


def main() -> None:
    if DIST.exists():
        shutil.rmtree(DIST)
    DIST.mkdir(parents=True)
    shutil.copytree(FRONTEND / "assets", DIST / "assets")
    shutil.copy(FRONTEND / "index.html", DIST / "index.html")
    print("frontend build:")
    print(f"  copied index.html + assets/ -> {DIST.relative_to(ROOT)}")
    for md_path in sorted(CONTENT.glob("*.md")):
        build_page(md_path)
    print(f"done -> {DIST.relative_to(ROOT)}/")


if __name__ == "__main__":
    main()
