#!/usr/bin/env python3
"""Build English release notes in the established GitHub Release format."""
import argparse
from pathlib import Path
import re
import plistlib


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag", help="Release tag, for example v0.1.2")
    parser.add_argument("output", type=Path)
    parser.add_argument("--repo", default="hexwarrior6/mailingo")
    parser.add_argument("--checksums", type=Path)
    parser.add_argument("--app", type=Path, help="Validate built app and extension versions")
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
    if args.app:
        build = re.search(r'^\s*CURRENT_PROJECT_VERSION:\s*"([^\"]+)"', project, re.M)
        for relative in ["Contents/Info.plist", "Contents/PlugIns/MailingoMailExtension.appex/Contents/Info.plist"]:
            with (args.app / relative).open("rb") as file:
                info = plistlib.load(file)
            if info.get("CFBundleShortVersionString") != version or not build or info.get("CFBundleVersion") != build[1]:
                parser.error(f"built version mismatch: {relative}")

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
    headings = {
        "Fixed": "🐛 Bug Fixes & Layout Improvements",
        "Added": "🚀 New Features",
        "Changed": "🛠️ Improvements",
    }
    body = re.sub(r"^### (Fixed|Added|Changed)$", lambda match: "### " + headings[match[1]], body, flags=re.M)

    download = f"https://github.com/{args.repo}/releases/download/{args.tag}/Mailingo.dmg"
    notes = f"""## What's Changed in {args.tag}

{body}

---

## Installation

1. Download [`Mailingo.dmg`]({download}) and drag `Mailingo.app` into `/Applications`.
2. Clear the Gatekeeper quarantine attribute for the self-signed binary:
   ```bash
   xattr -cr /Applications/Mailingo.app
   ```
3. Relaunch Apple Mail, then enable **Mailingo** under **Settings (`⌘,`) → Extensions**.

### Quick Install via Terminal

You can also run the following one-liner to download, install, and configure permissions automatically:
```bash
curl -fsSL https://raw.githubusercontent.com/{args.repo}/main/install.sh | bash
```
"""
    if args.checksums:
        notes += f"\n## Checksums (SHA-256)\n\n```text\n{args.checksums.read_text().strip()}\n```\n"
    older_entries = re.findall(r"^## \[(\d+\.\d+\.\d+)\]", remaining, re.M)
    if older_entries:
        notes += f"\n**Full Changelog**: https://github.com/{args.repo}/compare/v{older_entries[0]}...{args.tag}\n"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(notes)
    print(f"Release notes validated for {args.tag}: {args.output}")


if __name__ == "__main__":
    main()
