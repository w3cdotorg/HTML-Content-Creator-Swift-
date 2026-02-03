# Screencapture Site

A small web app + Node.js service that captures website screenshots at **1920×1080** and saves them locally in `screenshots/` with the filename pattern `id_domain_YYYYMMDD_HHMM.png`.

## Features
- Web UI to submit a URL and preview/download the capture
- Saves PNG screenshots at 1920×1080 viewport size (no full-page)
- Filename format: `id_domain_YYYYMMDD_HHMM.png` (drops `www.`)
- Auto-incrementing ID starting at `001` (continues even if files are deleted)
- History view to browse previous captures and delete them
- Attempts to dismiss common cookie banners automatically
- Writes/updates a `screenshots/captures.md` log for each capture
  - URL, full timestamp, and a link to the PNG

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
