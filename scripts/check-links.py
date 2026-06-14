#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 nadav.com.cn
"""Local link-integrity checker for DeepFinder markdown docs.

Runs before CI (lychee) to catch broken internal links early. Checks:
  - internal file links resolve (e.g. [x](../foo.md), [x](./bar.md#sec))
  - same-file and cross-file #anchors exist in the target's headers

Skips:
  - external URLs (http/https/mailto/ftp) — lychee covers those in CI
  - GitHub-relative web paths (e.g. ../../security/advisories/new) that
    resolve outside the repo root — valid on github.com, not file paths
  - .build, .git, node_modules, .swiftpm, .claude (worktrees)

Anchor slugs approximate github-slugger (each space -> one hyphen,
punctuation dropped, consecutive hyphens NOT collapsed) — accurate for the
common cases; exotic headers (emoji, nested formatting) may need CI's lychee.

Usage:
    python3 scripts/check-links.py        # exit 0 = clean, 1 = broken links
"""
import os, re, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
EXCLUDE_DIRS = {".build", ".git", "node_modules", ".swiftpm", ".claude"}

md_files = []
for dirpath, dirs, files in os.walk(ROOT):
    dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]
    for f in files:
        if f.endswith(".md"):
            md_files.append(os.path.join(dirpath, f))

def strip_code(text):
    """Remove fenced code blocks and inline code spans so links inside code aren't parsed."""
    text = re.sub(r"```.*?```", "", text, flags=re.DOTALL)
    text = re.sub(r"`[^`]*`", "", text)
    return text

def slug(text):
    """Approximate GitHub header anchor slug (github-slugger: each space -> one
    hyphen, punctuation dropped, consecutive hyphens NOT collapsed)."""
    s = text.strip().lower()
    s = re.sub(r"`+", "", s)
    s = re.sub(r"[^\w\s一-鿿-]", "", s, flags=re.UNICODE)
    s = re.sub(r"\s", "-", s)
    return s

def headers_of(path):
    slugs = set()
    try:
        for line in open(path, encoding="utf-8"):
            m = re.match(r"^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$", line)
            if m:
                slugs.add(slug(m.group(1)))
    except Exception:
        pass
    return slugs

_hdr_cache = {}
def file_headers(path):
    if path not in _hdr_cache:
        _hdr_cache[path] = headers_of(path)
    return _hdr_cache[path]

inline_re = re.compile(r"\[(?:[^\]\[]+)\]\(([^)]+)\)")
refdef_re = re.compile(r"^\s*\[([^\]]+)\]:\s*(\S+)", re.MULTILINE)

total_links = 0
broken = []

for md in sorted(md_files):
    rel = os.path.relpath(md, ROOT)
    text = strip_code(open(md, encoding="utf-8").read())
    refs = {k.lower(): v for k, v in refdef_re.findall(text)}

    targets = set(inline_re.findall(text))
    for ref_id in re.findall(r"\]\[([^\]]+)\]", text):
        if ref_id.lower() in refs:
            targets.add(refs[ref_id.lower()])

    for url in sorted(targets):
        url = url.split()[0] if url.split() else url
        total_links += 1
        if url.startswith(("http://", "https://", "mailto:", "ftp://")):
            continue
        if url.startswith("#"):
            if url[1:] not in file_headers(md):
                broken.append((rel, url, "anchor-missing (same file)"))
            continue
        anchor = None
        pathpart = url
        if "#" in url:
            pathpart, anchor = url.split("#", 1)
        target = os.path.normpath(os.path.join(os.path.dirname(md), pathpart)) if pathpart else md
        if not os.path.abspath(target).startswith(ROOT + os.sep) and os.path.abspath(target) != ROOT:
            continue  # GitHub-relative web path, valid on github.com
        if not os.path.exists(target):
            broken.append((rel, url, f"file-missing -> {os.path.relpath(target, ROOT)}"))
            continue
        if anchor:
            tgt = target if pathpart else md
            if anchor not in file_headers(tgt):
                broken.append((rel, url, f"anchor-missing in {os.path.relpath(tgt, ROOT)}"))

print(f"Checked {len(md_files)} .md files, {total_links} internal links.\n")
if broken:
    print(f"❌ {len(broken)} broken internal link(s):\n")
    for rel, url, why in broken:
        print(f"  {rel}\n      {url}  -- {why}")
    sys.exit(1)
print("✅ All internal links resolve.")
