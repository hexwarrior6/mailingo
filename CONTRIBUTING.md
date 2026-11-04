# Contributing to Mailingo

Open an issue for a reproducible bug or a feature proposal. For rendering bugs, include your macOS and Mailingo versions, the expected and actual layout, and the window widths where it reproduces. Use synthetic email examples and redact screenshots. Diagnostic logs and raw MIME can contain message bodies, addresses and links.

## Local development

Use macOS 15 or later with Xcode 16 or later.

```sh
make test
make bootstrap
make gen
```

The package tests need no signing certificate. For a local app build with your own Apple Development certificate, pass your team ID to Xcode. Keep personal signing settings out of commits.

```sh
xcodebuild -project Mailingo.xcodeproj -scheme Mailingo \
  -destination 'platform=macOS' -configuration Debug \
  -derivedDataPath "$PWD/.build/DerivedData" \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID build
```

With the project's configured signing identity, `make install-app` builds and replaces the copy in Applications. To test an app signed with a different team, copy that build into Applications and follow the [extension setup steps](README.md#install-and-translate). Edit `project.yml` when changing build settings or targets. XcodeGen recreates the ignored Xcode project.

## Verify a change

| Command | Coverage |
| --- | --- |
| `make test` | MIME parsing, HTML fidelity, translation engines, cache and Mail selection |
| `make check-message-store` | Storage, message version selection and cleanup |
| `make check-responsive-layout` | Newsletter and ticket rendering at wide and narrow widths in WebKit |
| `make check-reply-quotes` | Quote folding and reload state in WebKit |

For rendering changes, run the package tests and the responsive layout check. Exercise the affected message layout at multiple widths, including signatures or inline image controls when relevant. A fixture with replacement images verifies layout only.

Keep synthetic fixtures in [EmailCoreTests/Fixtures](Packages/MailingoKit/Tests/EmailCoreTests/Fixtures). Preserve the MIME encoding or structure that triggers the regression. Use example domains and synthetic identifiers. Keep live image requests and private email exports out of tests.

## Maintainer release checklist

1. Record user-facing changes under `Unreleased` in [CHANGELOG.md](CHANGELOG.md). Move them into a dated version entry when releasing.
2. Set `MARKETING_VERSION` and increment `CURRENT_PROJECT_VERSION` in `project.yml`.
3. Build the Release app and preview its notes and bundle versions. For example, with the version set to 0.1.3:

   ```sh
   python3 Scripts/release-notes.py v0.1.3 .build/release-notes.md \
     --app .build/DerivedData/Build/Products/Release/Mailingo.app
   ```

4. Push the release commit, then push its matching `v*` tag. The [release workflow](.github/workflows/release.yml) runs tests, builds and validates both bundles, and publishes the DMG, ZIP and SHA-256 checksums.
5. Verify the workflow, public notes and all three assets on GitHub.

Keep changelog entries and release notes in English. To correct an existing release's notes, update their source and the published body while retaining the published files and checksums.
