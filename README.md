# HTML Content Creator (SwiftUI, macOS)

Native macOS app to capture web pages (1920x1080), organize them by project, edit ordering and notes, generate HTML decks, and export PDF slides.

This rewrite keeps legacy data compatibility while moving the full UX to SwiftUI + WebKit.

## Key Features

- 100% native macOS UI (SwiftUI).
- Native WebKit capture engine (`WKWebView`) with fixed viewport: `1920x1080`.
- Project management: select active project, create new project, and set project title for HTML/PDF.
- Capture history and deletion per project.
- Explore & edit workflow: reorder captures, edit notes (simple markdown), save order + notes.
- HTML deck generation: title handling, Space Grotesk typography, links/notes rendering, in-page `Export PDF`.
- Native PDF export from the app: A4 landscape, title page, one slide per page, notes, link preservation.
- Share workflow from UI (`ShareLink`) for generated outputs.

## Current UI Structure

Sidebar sections:

- `Projects`
- `Capture`
- `Explore and Edit`
- `Share`

Global toolbar actions:

- camera: capture from clipboard URL when available (`http/https`), otherwise opens Capture section
- PDF: generate PDF
- Share: share latest generated output

## Storage Location

User data is stored in:

`~/Library/Application Support/HTML Content Creator`

Main layout:

- `screenshots/*.png` (default project)
- `screenshots/<project>/*.png` (other projects)
- `screenshots/captures.md`
- `screenshots/<project>/captures.md`
- `screenshots/.counter` and `screenshots/<project>/.counter`
- `screenshots/.project.json` and `screenshots/<project>/.project.json`
- `order/<project>.md`
- `notes/<project>/notes.md`
- `captures_<project>.html`
- `captures_<project>.pdf`

## Legacy Compatibility

The `old/` folder is kept as read-only reference and is not modified by the app code.  
This rewrite preserves legacy-compatible file formats for captures/order/notes so existing data can be reused.

Reference files:

- `old/README.md`
- `old/server.js`
- `old/generate_captures_html.py`

## Tech Stack

- Swift 5
- SwiftUI (macOS app)
- AppKit (window/pasteboard/printing integration)
- WebKit (`WKWebView`) for capture and rendering
- XcodeGen for project generation (`project.yml`)
- XCTest for unit/integration tests

## Project Structure

- `HTMLContentCreator/App/` app entrypoint, environment, app state
- `HTMLContentCreator/Features/` SwiftUI screens
- `HTMLContentCreator/Core/` capture, persistence, deck generation/export, paths, errors, logging
- `HTMLContentCreator/Domain/Models/` domain models
- `HTMLContentCreator/Resources/` bundled resources (including Space Grotesk and branding)
- `HTMLContentCreatorTests/` unit + integration tests
- `project.yml` XcodeGen spec
- `old/` legacy reference implementation and fixtures

## Build & Run

### Prerequisites

- macOS
- Xcode (with Command Line Tools)
- Optional: `xcodegen` (recommended when files/config change)

### Open in Xcode

```bash
open HTMLContentCreator.xcodeproj
```

### Regenerate project (if needed)

```bash
xcodegen generate
```

### Build from CLI

```bash
xcodebuild -project HTMLContentCreator.xcodeproj \
  -scheme HTMLContentCreator \
  -configuration Debug \
  build
```

### Run tests

```bash
xcodebuild -project HTMLContentCreator.xcodeproj \
  -scheme HTMLContentCreator \
  -configuration Debug \
  test
```

Current automated suite: 18 tests (unit + integration).

## Notes on HTML/PDF Export

- App-side PDF export uses a native WebKit pipeline and writes directly to Application Support.
- Generated HTML also includes an `Export PDF` action (`window.print`) with print-specific styling.
- HTML edit mode supports order/notes editing and downloads fallback files (`order_<project>.md`, `notes_<project>.md`).

## Known Limitations

- Web rendering can differ by website (dynamic content, anti-bot flows, CSP, lazy loading).
- Cookie banner dismissal is heuristic-based.
- In sandboxed/test contexts, WebKit may log entitlement warnings that do not necessarily indicate functional failure.

## App Icon

The app icon set is included in:

`HTMLContentCreator/Assets.xcassets/AppIcon.appiconset`

Master branding source:

`HTMLContentCreator/Resources/Branding/LogoMaster-1024.png`
