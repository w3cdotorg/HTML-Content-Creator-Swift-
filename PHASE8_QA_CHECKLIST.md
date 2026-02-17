# Phase 8 QA Checklist

## Automated checks
- [x] Unit tests for markdown codec:
  - capture log parsing
  - notes parsing/serialization
  - order parsing/serialization
- [x] Unit tests for project name sanitation and path mapping.
- [x] Unit tests for `.counter` behavior:
  - uses counter when present
  - falls back to scanning PNG files when counter is invalid
  - supports per-project counters
- [x] Integration test on `old/` fixtures (copied into temp workspace):
  - reads `captures.md`, `order/default.md`, `notes/default/notes.md`
  - generates `captures_default.html`
  - validates toolbar markers and ordered captures
- [x] Workflow integration test (temp workspace):
  - project creation + metadata
  - history, editor state save, HTML generation, deletion consistency
  - markdown rendering for notes (`*bold*`, list)
- [x] HTML title resolution tests:
  - requested title persists to metadata
  - fallback to stored metadata title
  - fallback to default `Captures - <project>`
- [x] Editor state and deletion tests:
  - `saveEditorState` round-trip for order + notes
  - `deleteCapture` also removes markdown capture block

Note: automated PDF export testing is not run in this CLI sandbox because macOS print pipeline calls are restricted/intermittent here; keep PDF validation in manual checks below.

## Manual non-regression checks
- [ ] Launch app in Xcode and confirm startup uses:
  - `~/Library/Application Support/HTML Content Creator`
- [ ] Capture one URL in `default` project.
- [ ] Create a new project and capture one URL.
- [ ] Confirm history list and preview are correct for both projects.
- [ ] Delete one capture and confirm history + editor refresh.
- [ ] Reorder captures and edit notes, save, reload editor to confirm persistence.
- [ ] Generate HTML and inspect in browser:
  - links open
  - notes render markdown (`*bold*`, `_italic_`, `- item`)
  - order matches editor
- [ ] Export PDF and verify:
  - output file `captures_<project>.pdf` exists in Application Support
  - title slide present
  - landscape pages
  - one capture per page with notes
- [ ] Re-open existing generated HTML and PDF from app buttons.

## Command used for automated suite
```bash
xcodebuild -project HTMLContentCreator.xcodeproj \
  -scheme HTMLContentCreator \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/HTMLContentCreatorDerivedData \
  test
```
