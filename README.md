# Screencapture Site

A small web app + Node.js service that captures website screenshots at **1920×1080** and saves them locally in `screenshots/` with the filename pattern `id_domain_YYYYMMDD_HHMM.png`.

## Features
- Web UI to submit a URL and preview/download the capture
- Saves PNG screenshots at 1920×1080 viewport size (no full-page)
- Filename format: `id_domain_YYYYMMDD_HHMM.png` (drops `www.`)
- Auto-incrementing ID starting at `001` (continues even if files are deleted)
- Project management in the UI (select existing project or create a new one)
- Captures and history separated by project (`default` in `screenshots/`, others in `screenshots/<project>/`)
- History view to browse previous captures and delete them
- Attempts to dismiss common cookie banners automatically
- Writes/updates a `captures.md` log for each project (`screenshots/captures.md` for `default`, else `screenshots/<project>/captures.md`)
- Each entry includes the original URL, full timestamp, and a link to the PNG
- Project panel can generate a static HTML page directly from the selected project
- A top-page `Explorer les captures` button appears automatically when `captures_<project>.html` already exists
- A top-page `Export PDF` button exports the current project HTML to `captures_<project>.pdf` (links and notes preserved)
- In generated HTML, `Mode edition` now saves both capture order and notes directly to the project (no mandatory order file download)

## Installation

### Local (recommended)
1. Install dependencies:
   ```bash
   npm install
   npx playwright install chromium
   ```
2. Start the server:
   ```bash
   npm run dev
   ```
3. Open the app:
   - Visit `http://localhost:3000` in your browser

### Deploying (notes)
This app relies on Playwright/Chromium to render screenshots. Serverless platforms like Vercel require extra setup to bundle browser binaries. If you want to deploy to Vercel, plan for a custom build step and Playwright-compatible runtime. If you'd like, I can add a Vercel-friendly configuration.

## HTML Generation (per project)

The repository now includes `/Users/willow/Sites/screencapturesite/generate_captures_html.py` to build static HTML pages from capture logs.

- Default project input: `screenshots/captures.md`
- Named project input: `screenshots/<project>/captures.md`
- Output file: `captures_<project>.html`
- Project notes: `notes/<project>/notes.md` (single file per project)
- Project order file: `order/<project>.md`

### Usage

Generate for one project:
```bash
python3 generate_captures_html.py --project default
python3 generate_captures_html.py --project client-a
```

Generate for all projects:
```bash
python3 generate_captures_html.py --all-projects
```
