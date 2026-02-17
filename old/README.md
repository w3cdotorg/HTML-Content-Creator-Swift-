# HTML Content Creator

Web app + Node.js service to capture websites (1920x1080), organize them by project, generate HTML presentation pages, and export to PDF.

## Features
- URL capture with Playwright in PNG, viewport `1920x1080` (not full-page)
- Filename format: `id_domain_YYYYMMDD_HHMM.png`
- Per-project incremental IDs (`001`, `002`, ...) that do not reset after deletion
- Project management in UI:
  - select existing project
  - create new project
- Per-project storage:
  - `default`: files under `screenshots/`
  - other projects: files under `screenshots/<project>/`
- Capture history per project with delete action
- Automatic attempt to dismiss common cookie banners before capture
- Capture log per project in markdown:
  - `screenshots/captures.md` for `default`
  - `screenshots/<project>/captures.md` for other projects
- HTML generation per project (`captures_<project>.html`) from capture logs
- Top actions in main UI when generated HTML exists:
  - `Explorer les captures`
  - `Export PDF`
- PDF export from generated HTML:
  - title slide from the optional HTML title
  - landscape slides style
  - one capture per page
  - background preserved
  - links and notes preserved
- Generated HTML toolbar includes:
  - `Mode edition`
  - `Export PDF`
- Edit mode supports:
  - reorder captures
  - `Ajout note` per capture with markdown textarea
  - markdown syntax in notes: `*gras*` and `_italique_`
  - save order + notes in one action

## Project Data Layout
- Screenshots:
  - `screenshots/*.png` (`default` project)
  - `screenshots/<project>/*.png`
- Capture logs:
  - `screenshots/captures.md`
  - `screenshots/<project>/captures.md`
- Order files:
  - `order/<project>.md`
- Notes (single file per project):
  - `notes/<project>/notes.md`
- Generated outputs:
  - `captures_<project>.html`
  - `captures_<project>.pdf`

## Installation (Bun)
1. Install dependencies:
```bash
bun install
bunx playwright install chromium
```
2. Start the server:
```bash
bun run dev
```
3. Open:
- [http://localhost:3000](http://localhost:3000)

## API (main endpoints)
- `POST /api/screenshot`
- `GET /api/history?project=<name>`
- `DELETE /api/history/:filename?project=<name>`
- `GET /api/projects`
- `POST /api/projects`
- `GET /api/projects/:project/html`
- `POST /api/projects/:project/generate-html`
- `POST /api/projects/:project/export-pdf`
- `POST /api/projects/:project/order`
- `POST /api/projects/:project/editor-state`
- `GET /generated/:filename`
- `GET /generated-pdf/:filename`

## HTML Generation Script
Script location:
- `/Users/willow/Sites/HTML Content Creator/generate_captures_html.py`

Usage:
```bash
python3 generate_captures_html.py --project default
python3 generate_captures_html.py --project projet-test
python3 generate_captures_html.py --all-projects
python3 generate_captures_html.py --project default --title "Mon titre"
```

## Notes
- The generated HTML edit mode saves order and notes to the server.
- If server save fails, order download fallback is used.
- Vercel/serverless deployment requires extra Playwright/Chromium runtime setup.
