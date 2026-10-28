#!/usr/bin/env python3
"""Build version-specific GitHub Release notes from CHANGELOG.md (stdlib only)."""
import argparse
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag", help="Release tag, for example v0.1.2")
    parser.add_argument("output", type=Path)
    parser.add_argument("--repo", default="hexwarrior6/mailingo")
    parser.add_argument("--checksums", type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"v\d+\.\d+\.\d+", args.tag):
        parser.error("expected a stable version tag such as v0.1.2")
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", args.repo):
        parser.error("expected an owner/repository name")

    root = Path(__file__).resolve().parent.parent
    version = args.tag[1:]
    project = (root / "project.yml").read_text()
    app_version = re.search(r'^\s*MARKETING_VERSION:\s*"([^\"]+)"', project, re.M)
    if not app_version or app_version[1] != version:
        parser.error("release tag must match MARKETING_VERSION in project.yml")

    changelog = (root / "CHANGELOG.md").read_text()
    entries = list(re.finditer(
        rf"^## \[{re.escape(version)}\] - \d{{4}}-\d{{2}}-\d{{2}}\s*$", changelog, re.M
    ))
    if len(entries) != 1:
        parser.error(f"CHANGELOG.md must contain exactly one dated entry for {version}")
    remaining = changelog[entries[0].end():]
    body = re.split(r"^## ", remaining, maxsplit=1, flags=re.M)[0].strip()
    if not re.search(r"^- \S", body, re.M):
        parser.error(f"changelog entry for {version} has no changes")

    download = f"https://github.com/{args.repo}/releases/download/{args.tag}/Mailingo.dmg"
    notes = f"""## What's Changed in {args.tag}

{body}

## Installation / 安装

1. Download [Mailingo.dmg]({download}) and drag `Mailingo.app` into `/Applications`.
2. If macOS blocks the self-signed app, clear its quarantine attribute:
   ```bash
   xattr -cr /Applications/Mailingo.app
   ```
3. Quit and reopen Mailingo and Apple Mail. Enable **Mailingo** in Apple Mail → **Settings → Extensions** if needed.

下载 DMG 并替换「应用程序」中的 Mailingo，然后退出并重新打开 Mailingo 和 Apple Mail。
"""
    if args.checksums:
        notes += f"\n## Checksums (SHA-256)\n\n```text\n{args.checksums.read_text().strip()}\n```\n"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(notes)
    print(f"Release notes validated for {args.tag}: {args.output}")


if __name__ == "__main__":
    main()
