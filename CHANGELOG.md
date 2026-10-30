# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **Plain-Text URLs and Email Links**: Automatically converted plain-text URLs and email addresses in email bodies into clickable links, matching Apple Mail's data detection behavior without affecting translation cache fidelity.
- **New-Window Link Navigation**: Added `WKUIDelegate` handling so links targeting `_blank` or external windows reliably open in the default browser.

## [0.1.2] - 2026-10-28

### Fixed
- **App Version Metadata**: The app and Mail extension now use the release version and build number instead of XcodeGen's default metadata.
- **Consistent Newsletter Columns**: Preserved image-column proportions across separate event tables, keeping posters equally wide and text consistently aligned.
- **Registration Ticket Layouts**: Retained original container widths, paired tables and mobile layouts so QR codes, logos and wallet buttons keep their intended sizes.
- **Narrow-Window Readability**: Allowed long text to wrap without clipping and multi-column footers to accommodate fixed-size social icons.

### Changed
- **Version-Specific Release Notes**: GitHub Releases now use the matching section of this changelog. Publishing stops if the tag, app version or changelog entry does not match.

## [0.1.1] - 2026-10-23

### Fixed
- **Responsive Text Wrapping**: Fixed body text and marketing email cards getting cut off at the right edge in narrow viewports.
- **Signature & Logo Protection**: Protected signature logo columns from excessive shrinkage and kept multi-icon rows neatly aligned.
- **Eliminated Text Overlap**: Fixed social media icons overlapping with adjacent handle text (e.g. `@caontusg`).
- **Float Clearing for Disclaimers**: Fixed post-signature confidentiality notices and legal disclaimers wrapping awkwardly to the right of shrunk signature tables.
- **Overlay Filtering**: Excluded signature logos and narrow decorative bars from getting intrusive translation badges.

### Added
- **Attachment Images Display**: Standalone attached images without inline CID now render at the end of the email body, matching Apple Mail behavior.

## [0.1.0] - 2026-10-22

### Added
- Initial release of Mailingo for macOS.
- Native Apple Mail translation extension built with MailKit.
- Side-by-side bilingual reading with adjustable pane widths.
- HTML translation that preserves the original email layout.
- CID inline images and remote content controls.
- Image translation badges and OCR integration.
- Reply quote folding and a local translation cache.
