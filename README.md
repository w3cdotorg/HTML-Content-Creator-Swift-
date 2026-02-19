# HTML Content Creator (SwiftUI, macOS)

_I was getting fed up with presentation software, so I used ChatGPT Codex to capture specific websites and build an HTML deck with PDF export._

Native macOS app to capture web pages (`1920x1080`), organize captures by project, edit ordering/notes, generate HTML decks, and export PDF slides.

This Swift rewrite preserves legacy file compatibility while moving the full workflow to SwiftUI + WebKit.

## Features

- 100% native macOS app (`SwiftUI` + `AppKit` integration where needed).
- Native capture engine with `WKWebView` at fixed viewport `1920x1080`.
- Capture reliability strategy:
  - primary WebKit snapshot,
  - fallback snapshot modes,
  - bitmap/PDF fallback paths for difficult pages.
- Optional capture-side content blocking switch:
  - `WKContentRuleList` (MVP),
  - JavaScript fallback cleanup for cookie banners/overlays.
- Host-specific hardening for problematic pages (for example strict path for NYTimes, additional cleanup for WordPress and Le Monde cases).
- Project workflow:
  - create/select project,
  - persistent active project,
  - project title used in HTML/PDF.
- Explore & Edit:
  - project capture list,
  - drag and drop reorder,
  - per-slide notes editing,
  - capture deletion.
- Share workflow:
  - preflight summary (captures count, title, last HTML/PDF generation, latest errors),
  - generate/open HTML,
  - generate/open PDF,
  - native macOS share action.
- HTML output:
  - Space Grotesk typography,
  - image + source URL links,
  - notes rendering,
  - in-page `Export PDF` action.
- PDF output:
  - title page,
  - one landscape slide per page,
  - notes page support,
  - links preserved.

## UI Overview

Sidebar sections:

- `Projects`
- `Capture`
- `Explore and Edit`
- `Share`

Toolbar actions:

- camera: uses clipboard URL (`http/https`) when available, otherwise opens `Capture`
- PDF: direct PDF export
- Share: share latest generated artifact

Window title always shows the active project:

- `HTML Content Creator - <project>`

The sidebar displays green status pills for generated outputs:

- `HTML`
- `PDF`

## Storage

All user data is stored in:

`~/Library/Application Support/HTML Content Creator`

Main layout:

- `screenshots/*.png` (default project)
- `screenshots/<project>/*.png`
- `screenshots/captures.md`
- `screenshots/<project>/captures.md`
- `screenshots/.counter`
- `screenshots/<project>/.counter`
- `screenshots/.project.json`
- `screenshots/<project>/.project.json`
- `order/<project>.md`
- `notes/<project>/notes.md`
- `captures_<project>.html`
- `captures_<project>.pdf`

## Legacy Compatibility

Legacy-compatible formats are preserved for:

- captures log
- order files
- notes files
- project metadata

## Tech Stack

- Swift 5
- SwiftUI
- AppKit
- WebKit (`WKWebView`)
- XcodeGen (`project.yml`)
- XCTest

## Project Structure

- `HTMLContentCreator/App/` app bootstrap, environment, state
- `HTMLContentCreator/Features/` SwiftUI screens (`Projects`, `Capture`, `Explore and Edit`, `Share`)
- `HTMLContentCreator/Core/` capture, persistence, HTML/PDF generation, logging, utilities
- `HTMLContentCreator/Domain/Models/` domain models
- `HTMLContentCreator/Resources/` bundled fonts and branding assets
- `HTMLContentCreatorTests/` unit/integration tests
- `project.yml` XcodeGen spec

## Build and Run

### Prerequisites

- macOS
- Xcode + Command Line Tools
- optional: `xcodegen` (recommended after project spec changes)

### Open in Xcode

```bash
open HTMLContentCreator.xcodeproj
```

### Regenerate project (optional)

```bash
xcodegen generate
```

### Build (CLI)

```bash
xcodebuild -project HTMLContentCreator.xcodeproj \
  -scheme HTMLContentCreator \
  -configuration Debug \
  build
```

### Test (CLI)

```bash
xcodebuild -project HTMLContentCreator.xcodeproj \
  -scheme HTMLContentCreator \
  -configuration Debug \
  test
```

## HTML/PDF Notes

- Native PDF export is generated from WebKit and written directly under Application Support.
- Generated HTML contains an in-page `Export PDF` button (`window.print`) with print-specific CSS.
- HTML edit mode supports local fallback downloads for:
  - `order_<project>.md`
  - `notes_<project>.md`

## Logging Notes

- Capture logs are intentionally quieter at app level (`debug` for verbose navigation/cleanup traces).
- Some `WebContent[...]` logs in Xcode come from system WebKit processes and are often benign.
- Typical non-blocking noise:
  - tracking/query-parameter filtering warnings,
  - cancelled subframe loads (`NSURLErrorDomain -999`),
  - sandbox/entitlement warnings in debug contexts.

If the final PNG/PDF output is correct, these logs usually do not require action.

## App Icon and Branding

Icon set:

- `HTMLContentCreator/Assets.xcassets/AppIcon.appiconset`

Master source:

- `HTMLContentCreator/Resources/Branding/LogoMaster-1024.png`
