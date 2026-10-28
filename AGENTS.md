# Mailingo Contributor Instructions

These instructions apply to this repository. Read `README.md` and the relevant
implementation before editing; preserve unrelated changes.

## Language and Release Notes

- Keep `CHANGELOG.md` and GitHub Release notes entirely in English. A Chinese
  conversation or review draft does not change the language of published notes.
- Use conventional changelog sections (`Added`, `Changed`, `Fixed`) and retain
  the established Release format: What's Changed, categorized changes,
  Installation, Quick Install via Terminal, Checksums, and Full Changelog when a
  previous version exists. Omit change categories that have no entries.
- Use `Scripts/release-notes.py` to generate Release notes from the matching
  changelog entry. Do not hard-code a particular version's changes in the workflow.
- Add user-facing changes to `Unreleased` during development. At release time,
  move them into the dated version entry. Preserve the meaning and dates of
  historical entries when editing their presentation.
- When correcting published notes, update the generator or source entry as well
  as the Release body. Preserve the published assets and their actual checksums;
  local builds may have different checksums.

## Versioning and Publishing

- Follow the release procedure in `README.md` and `.github/workflows/release.yml`.
  Keep the tag, `MARKETING_VERSION`, changelog version, and actual app and extension
  versions consistent; increment `CURRENT_PROJECT_VERSION` for a new build.
- Both generated Info.plist files must use `$(MARKETING_VERSION)` and
  `$(CURRENT_PROJECT_VERSION)`. Changing build settings alone does not guarantee
  the packaged app has the intended version.
- Validate the built app and extension with `Scripts/release-notes.py --app`
  before packaging. The release workflow also performs this check.
- Pushing a version tag triggers a public Release. Do this when
  publishing is authorized; a routine fix or documentation change does not itself
  require a new release. Do not move an already published version tag.
- After publishing, verify workflow success, the public notes, and the uploaded
  DMG, ZIP, and checksums. Do not report success merely because a tag was pushed.

## Email Layout Changes

- Preserve the sender's column proportions, image sizes, alignment, and responsive
  media queries. Avoid global width or float overrides that repair one template
  while breaking another. Support narrow windows without hiding clipped content.
- Apply rendering adaptations only to the WebView copy, preserving source MIME,
  cached HTML, and the translation pipeline's fidelity guarantees.
- For layout changes, run `make test` and `make check-responsive-layout` with real
  WebKit. Cover wide and narrow windows, image translation badges, newsletter
  columns, registration tickets, footers, and affected signature layouts.
- Keep regression fixtures free of personal data, ticket tokens, and live remote
  requests. Distinguish structural rendering checks with local replacement images
  from verification of the original remote image content.

## Git Delivery

- Before committing or pushing, verify the worktree, branch, and remote. After a
  completed local commit for user-authorized work, push it to the verified remote;
  do not stop at a local commit. Preserve unrelated work and never force-push.
- If permissions or automatic approval block delivery, report the exact remaining
  action and reason. Do not describe an unpushed commit or unpublished release as
  remotely delivered.
