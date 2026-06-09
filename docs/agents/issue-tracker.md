# Issue tracker: Local markdown

Issues for this repo live as markdown files under `.scratch/`.

## Conventions

- **Create an issue**: write a new file at `.scratch/<feature-slug>/<NNN>-<short-title>.md` with YAML frontmatter.
- **List issues**: `find .scratch -name '*.md' | sort`
- **Read an issue**: read the file directly.
- **Update status / labels**: edit the `status` and `labels` fields in the file's frontmatter.
- **Close**: set `status: closed` in frontmatter (or move to `.scratch/_closed/`).

### Frontmatter schema

```yaml
---
title: "Short title"
status: open          # open | closed
labels: []            # e.g. [needs-triage, ready-for-agent]
created: YYYY-MM-DD
---
```

## When a skill says "publish to the issue tracker"

Write a new markdown file under `.scratch/`.

## When a skill says "fetch the relevant ticket"

Read the markdown file directly.
