import express from "express";
import path from "path";
import { fileURLToPath } from "url";
import { mkdir, writeFile, readdir, stat, readFile, unlink } from "fs/promises";
import { chromium } from "playwright";
import { execFile } from "child_process";
import { promisify } from "util";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
const PORT = process.env.PORT || 3000;

const SCREENSHOTS_DIR = path.join(__dirname, "screenshots");
const ORDER_DIR = path.join(__dirname, "order");
const NOTES_DIR = path.join(__dirname, "notes");
const DEFAULT_PROJECT = "default";
const HTML_GENERATOR = path.join(__dirname, "generate_captures_html.py");
const execFileAsync = promisify(execFile);

app.use(express.json({ limit: "1mb" }));
app.use(express.static(path.join(__dirname, "public")));
app.use("/screenshots", express.static(SCREENSHOTS_DIR));

function formatDateYYYYMMDD(date) {
  const yyyy = date.getFullYear();
  const mm = String(date.getMonth() + 1).padStart(2, "0");
  const dd = String(date.getDate()).padStart(2, "0");
  return `${yyyy}${mm}${dd}`;
}

function formatTimeHHMM(date) {
  const hh = String(date.getHours()).padStart(2, "0");
  const mm = String(date.getMinutes()).padStart(2, "0");
  return `${hh}${mm}`;
}

function formatDateTimeFull(date) {
  const yyyy = date.getFullYear();
  const mm = String(date.getMonth() + 1).padStart(2, "0");
  const dd = String(date.getDate()).padStart(2, "0");
  const hh = String(date.getHours()).padStart(2, "0");
  const min = String(date.getMinutes()).padStart(2, "0");
  const ss = String(date.getSeconds()).padStart(2, "0");
  return `${yyyy}-${mm}-${dd} ${hh}:${min}:${ss}`;
}

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function sanitizeProjectName(input) {
  if (!input || typeof input !== "string") return DEFAULT_PROJECT;
  const normalized = input.trim().toLowerCase().replace(/\s+/g, "-");
  const safe = normalized.replace(/[^a-z0-9._-]/g, "");
  return safe || DEFAULT_PROJECT;
}

function getProjectDir(projectName) {
  if (projectName === DEFAULT_PROJECT) return SCREENSHOTS_DIR;
  return path.join(SCREENSHOTS_DIR, projectName);
}

function getProjectMarkdown(projectName) {
  return path.join(getProjectDir(projectName), "captures.md");
}

function getProjectCounterFile(projectName) {
  return path.join(getProjectDir(projectName), ".counter");
}

function getProjectMetaFile(projectName) {
  return path.join(getProjectDir(projectName), ".project.json");
}

function getProjectOrderFile(projectName) {
  return path.join(ORDER_DIR, `${projectName}.md`);
}

function getProjectNotesFile(projectName) {
  return path.join(NOTES_DIR, projectName, "notes.md");
}

function buildScreenshotUrl(projectName, filename) {
  if (projectName === DEFAULT_PROJECT) return `/screenshots/${filename}`;
  return `/screenshots/${projectName}/${filename}`;
}

function getGeneratedHtmlFilename(projectName) {
  return `captures_${projectName}.html`;
}

function getGeneratedHtmlPath(projectName) {
  return path.join(__dirname, getGeneratedHtmlFilename(projectName));
}

function getGeneratedPdfFilename(projectName) {
  return `captures_${projectName}.pdf`;
}

function getGeneratedPdfPath(projectName) {
  return path.join(__dirname, getGeneratedPdfFilename(projectName));
}

async function fileExists(filePath) {
  try {
    await stat(filePath);
    return true;
  } catch {
    return false;
  }
}

async function ensureProject(projectName) {
  const projectDir = getProjectDir(projectName);
  await mkdir(projectDir, { recursive: true });
  return projectDir;
}

async function readProjectMeta(projectName) {
  const metaFile = getProjectMetaFile(projectName);
  try {
    const raw = await readFile(metaFile, "utf8");
    const parsed = JSON.parse(raw);
    return typeof parsed === "object" && parsed ? parsed : {};
  } catch {
    return {};
  }
}

async function writeProjectMeta(projectName, patch) {
  await ensureProject(projectName);
  const current = await readProjectMeta(projectName);
  const next = { ...current, ...patch };
  const metaFile = getProjectMetaFile(projectName);
  await writeFile(metaFile, JSON.stringify(next, null, 2));
  return next;
}

function serializeNotesMarkdown(notesByCapture) {
  const entries = Object.entries(notesByCapture || {}).filter(([name, note]) => {
    return /^[a-zA-Z0-9._-]+\.png$/.test(name) && typeof note === "string" && note.trim();
  });
  if (!entries.length) {
    return "# Notes\n\n";
  }
  entries.sort((a, b) => a[0].localeCompare(b[0]));
  const blocks = entries.map(([filename, note]) => {
    return [`<!-- NOTE: ${filename} -->`, note.trim(), "<!-- END NOTE -->", ""].join("\n");
  });
  return `# Notes\n\n${blocks.join("\n")}\n`;
}

async function appendCaptureMarkdown({ projectName, filename, url, dateTime }) {
  const markdownPath = getProjectMarkdown(projectName);
  await ensureProject(projectName);
  let content = "";
  try {
    content = await readFile(markdownPath, "utf8");
  } catch {
    content = "# Captures\n\n";
  }

  const block = [
    `<!-- CAPTURE: ${filename} -->`,
    `- Fichier: \`${filename}\``,
    `- URL: ${url}`,
    `- Date: ${dateTime}`,
    `- Capture: [${filename}](./${filename})`,
    "",
    ""
  ].join("\n");

  await writeFile(markdownPath, content + block);
}

async function removeCaptureMarkdown(projectName, filename) {
  const markdownPath = getProjectMarkdown(projectName);
  try {
    const content = await readFile(markdownPath, "utf8");
    const pattern = new RegExp(
      `<!-- CAPTURE: ${escapeRegex(filename)} -->[\\s\\S]*?(\\n\\n|$)`,
      "g"
    );
    const updated = content.replace(pattern, "");
    await writeFile(markdownPath, updated);
  } catch {
    // ignore if missing
  }
}
function extractDomain(rawUrl) {
  const url = new URL(rawUrl);
  let host = url.hostname.toLowerCase();
  if (host.startsWith("www.")) host = host.slice(4);
  return host;
}

async function computeNextFromProjectFiles(projectName) {
  const projectDir = getProjectDir(projectName);
  const files = await readdir(projectDir);
  let maxId = 0;
  for (const file of files) {
    if (!file.toLowerCase().endsWith(".png")) continue;
    const match = file.match(/^(\d+)_/);
    if (!match) continue;
    const id = Number.parseInt(match[1], 10);
    if (Number.isFinite(id) && id > maxId) maxId = id;
  }
  return maxId + 1;
}

async function getNextId(projectName) {
  await ensureProject(projectName);
  const counterFile = getProjectCounterFile(projectName);
  try {
    const raw = await readFile(counterFile, "utf8");
    const current = Number.parseInt(raw.trim(), 10);
    if (!Number.isFinite(current) || current < 1) throw new Error("invalid");
    const next = current + 1;
    await writeFile(counterFile, String(next));
    return String(current).padStart(3, "0");
  } catch {
    const next = await computeNextFromProjectFiles(projectName);
    await writeFile(counterFile, String(next + 1));
    return String(next).padStart(3, "0");
  }
}

const COOKIE_ACCEPT_TEXTS = [
  "accept",
  "accept all",
  "allow all",
  "agree",
  "i agree",
  "j'accepte",
  "tout accepter",
  "accepter",
  "autoriser",
  "ok",
  "d'accord",
  "got it"
];

async function dismissCookieBanners(page) {
  const timeoutMs = 3000;

  async function tryClickInScope(scope) {
    for (const text of COOKIE_ACCEPT_TEXTS) {
      const locator = scope.getByRole("button", { name: new RegExp(`^${text}$`, "i") });
      const count = await locator.count();
      if (count > 0) {
        try {
          await locator.first().click({ timeout: 500, force: true });
          return true;
        } catch {
          // try next match
        }
      }
    }
    return false;
  }

  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const clicked = await tryClickInScope(page);
    if (clicked) return;

    for (const frame of page.frames()) {
      if (frame === page.mainFrame()) continue;
      try {
        const clickedInFrame = await tryClickInScope(frame);
        if (clickedInFrame) return;
      } catch {
        // ignore frame errors
      }
    }

    await page.waitForTimeout(300);
  }
}

async function runHtmlGeneration(projectName, title) {
  const args = [HTML_GENERATOR, "--project", projectName];
  if (typeof title === "string" && title.trim()) {
    args.push("--title", title.trim());
  }
  await execFileAsync("python3", args, {
    cwd: __dirname,
    timeout: 120000
  });
}

async function resolveProjectTitle(projectName, requestedTitle) {
  if (typeof requestedTitle === "string" && requestedTitle.trim()) {
    const title = requestedTitle.trim();
    await writeProjectMeta(projectName, { htmlTitle: title });
    return title;
  }
  const meta = await readProjectMeta(projectName);
  return typeof meta.htmlTitle === "string" && meta.htmlTitle.trim() ? meta.htmlTitle.trim() : undefined;
}

app.post("/api/screenshot", async (req, res) => {
  const { url, project } = req.body || {};
  if (!url || typeof url !== "string") {
    return res.status(400).json({ error: "URL manquante." });
  }
  const projectName = sanitizeProjectName(project);

  let parsedUrl;
  try {
    parsedUrl = new URL(url);
  } catch {
    return res.status(400).json({ error: "URL invalide." });
  }

  if (!["http:", "https:"].includes(parsedUrl.protocol)) {
    return res.status(400).json({ error: "Seuls http/https sont acceptés." });
  }

  const domain = extractDomain(parsedUrl.toString());
  const now = new Date();
  const dateStr = formatDateYYYYMMDD(now);
  const timeStr = formatTimeHHMM(now);
  const dateTimeFull = formatDateTimeFull(now);
  const id = await getNextId(projectName);
  const filename = `${id}_${domain}_${dateStr}_${timeStr}.png`;
  const projectDir = await ensureProject(projectName);
  const filepath = path.join(projectDir, filename);

  let browser;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });

    await page.goto(parsedUrl.toString(), {
      waitUntil: "domcontentloaded",
      timeout: 60000
    });

    // Give dynamic sites a moment to render without waiting for perpetual network activity.
    await page.waitForTimeout(2000);

    await dismissCookieBanners(page);

    const buffer = await page.screenshot({
      type: "png",
      fullPage: false
    });

    await writeFile(filepath, buffer);
    await appendCaptureMarkdown({
      projectName,
      filename,
      url: parsedUrl.toString(),
      dateTime: dateTimeFull
    });

    return res.json({
      project: projectName,
      filename,
      url: buildScreenshotUrl(projectName, filename)
    });
  } catch (err) {
    return res.status(500).json({ error: `Erreur capture: ${err.message}` });
  } finally {
    if (browser) await browser.close();
  }
});

app.get("/api/history", async (req, res) => {
  try {
    const projectName = sanitizeProjectName(req.query.project);
    const projectDir = await ensureProject(projectName);
    const files = await readdir(projectDir);
    const pngFiles = files.filter((file) => file.toLowerCase().endsWith(".png"));

    const entries = await Promise.all(
      pngFiles.map(async (file) => {
        const filePath = path.join(projectDir, file);
        const stats = await stat(filePath);
        return {
          filename: file,
          url: buildScreenshotUrl(projectName, file),
          mtime: stats.mtimeMs
        };
      })
    );

    entries.sort((a, b) => b.mtime - a.mtime);

    return res.json({ project: projectName, items: entries });
  } catch (err) {
    return res.status(500).json({ error: `Erreur historique: ${err.message}` });
  }
});

app.delete("/api/history/:filename", async (req, res) => {
  try {
    const { filename } = req.params;
    const projectName = sanitizeProjectName(req.query.project);
    if (!filename || filename !== path.basename(filename)) {
      return res.status(400).json({ error: "Nom de fichier invalide." });
    }
    if (!filename.toLowerCase().endsWith(".png")) {
      return res.status(400).json({ error: "Seuls les PNG sont acceptés." });
    }

    const projectDir = await ensureProject(projectName);
    const filePath = path.join(projectDir, filename);
    await unlink(filePath);
    await removeCaptureMarkdown(projectName, filename);
    return res.json({ ok: true });
  } catch (err) {
    return res.status(500).json({ error: `Erreur suppression: ${err.message}` });
  }
});

app.get("/api/projects", async (_req, res) => {
  try {
    await mkdir(SCREENSHOTS_DIR, { recursive: true });
    await ensureProject(DEFAULT_PROJECT);

    const entries = await readdir(SCREENSHOTS_DIR, { withFileTypes: true });
    const projects = entries
      .filter((entry) => entry.isDirectory())
      .map((entry) => sanitizeProjectName(entry.name))
      .filter((name) => name !== DEFAULT_PROJECT)
      .filter((name, index, arr) => name && arr.indexOf(name) === index)
      .sort((a, b) => a.localeCompare(b));

    return res.json({ defaultProject: DEFAULT_PROJECT, projects: [DEFAULT_PROJECT, ...projects] });
  } catch (err) {
    return res.status(500).json({ error: `Erreur projets: ${err.message}` });
  }
});

app.post("/api/projects", async (req, res) => {
  try {
    const name = sanitizeProjectName(req.body?.name);
    await ensureProject(name);
    return res.status(201).json({ project: name });
  } catch (err) {
    return res.status(500).json({ error: `Erreur création projet: ${err.message}` });
  }
});

app.get("/api/projects/:project/html", async (req, res) => {
  try {
    const projectName = sanitizeProjectName(req.params.project);
    const filename = getGeneratedHtmlFilename(projectName);
    const htmlPath = getGeneratedHtmlPath(projectName);
    const exists = await fileExists(htmlPath);
    const meta = await readProjectMeta(projectName);
    return res.json({
      project: projectName,
      exists,
      filename,
      url: exists ? `/generated/${filename}` : null,
      title: typeof meta.htmlTitle === "string" ? meta.htmlTitle : ""
    });
  } catch (err) {
    return res.status(500).json({ error: `Erreur page HTML: ${err.message}` });
  }
});

app.post("/api/projects/:project/generate-html", async (req, res) => {
  try {
    const projectName = sanitizeProjectName(req.params.project);
    const title = await resolveProjectTitle(projectName, req.body?.title);
    const deckTitle = title || `Captures - ${projectName}`;
    await runHtmlGeneration(projectName, title);

    const filename = getGeneratedHtmlFilename(projectName);
    return res.json({
      project: projectName,
      filename,
      url: `/generated/${filename}`,
      title: title || ""
    });
  } catch (err) {
    const stderr = typeof err?.stderr === "string" ? err.stderr.trim() : "";
    return res.status(500).json({
      error: stderr ? `Erreur génération HTML: ${stderr}` : `Erreur génération HTML: ${err.message}`
    });
  }
});

app.post("/api/projects/:project/export-pdf", async (req, res) => {
  let browser;
  try {
    const projectName = sanitizeProjectName(req.params.project);
    const title = await resolveProjectTitle(projectName, req.body?.title);
    const deckTitle = title || `Captures - ${projectName}`;
    await runHtmlGeneration(projectName, title);

    const htmlFilename = getGeneratedHtmlFilename(projectName);
    const htmlUrl = `http://localhost:${PORT}/generated/${htmlFilename}`;
    const pdfFilename = getGeneratedPdfFilename(projectName);
    const pdfPath = getGeneratedPdfPath(projectName);

    browser = await chromium.launch();
    const page = await browser.newPage({
      viewport: { width: 1920, height: 1080 }
    });

    await page.goto(htmlUrl, { waitUntil: "networkidle", timeout: 60000 });

    await page.evaluate((renderedTitle) => {
      const main = document.querySelector("main.page");
      if (!main) return;
      const existing = main.querySelector(".pdf-title-slide");
      if (existing) existing.remove();
      const slide = document.createElement("section");
      slide.className = "pdf-title-slide";
      slide.innerHTML = `<h2>${renderedTitle}</h2>`;
      main.insertBefore(slide, main.firstChild);
    }, deckTitle);

    await page.addStyleTag({
      content: `
        @media print {
          @page { size: A4 landscape; margin: 0; }
          html, body {
            background: var(--bg) !important;
            -webkit-print-color-adjust: exact !important;
            print-color-adjust: exact !important;
          }
          .toolbar, h1 { display: none !important; }
          .pdf-title-slide {
            height: 210mm !important;
            min-height: 210mm !important;
            display: flex !important;
            align-items: center !important;
            justify-content: center !important;
            text-align: center !important;
            padding: 18mm !important;
            box-sizing: border-box !important;
            break-after: page !important;
            page-break-after: always !important;
          }
          .pdf-title-slide h2 {
            margin: 0 !important;
            font-family: "Space Grotesk", "Helvetica Neue", sans-serif !important;
            font-size: 48px !important;
            line-height: 1.15 !important;
            letter-spacing: -0.02em !important;
            color: #1f2328 !important;
            max-width: 85% !important;
            word-break: break-word !important;
          }
          .page {
            max-width: none !important;
            margin: 0 !important;
            padding: 0 !important;
          }
          .capture-row, .card {
            break-inside: avoid !important;
            page-break-inside: avoid !important;
          }
          .capture-row {
            height: 210mm !important;
            min-height: 210mm !important;
            display: flex !important;
            flex-direction: row !important;
            align-items: center !important;
            justify-content: center !important;
            gap: 8mm !important;
            break-after: page !important;
            page-break-after: always !important;
            padding: 6mm 8mm !important;
            box-sizing: border-box !important;
          }
          .card {
            min-height: 0 !important;
            height: auto !important;
            margin: 0 !important;
            padding: 8mm !important;
            width: min(70%, 1350px) !important;
            flex: 0 0 min(70%, 1350px) !important;
            box-shadow: none !important;
          }
          .capture-row .note {
            flex: 0 0 26% !important;
            max-width: 26% !important;
          }
          main.page > .card {
            height: 210mm !important;
            min-height: 210mm !important;
            display: flex !important;
            flex-direction: column !important;
            align-items: center !important;
            justify-content: center !important;
            break-after: page !important;
            page-break-after: always !important;
            padding: 8mm !important;
            margin: 0 !important;
            width: 100% !important;
            box-sizing: border-box !important;
            box-shadow: none !important;
          }
          main.page > .card:last-child,
          .capture-row:last-child {
            break-after: auto !important;
            page-break-after: auto !important;
          }
          .shot-block {
            max-width: 100% !important;
            margin: 0 !important;
          }
          .shot {
            max-height: 56vh !important;
            width: 100% !important;
            object-fit: contain;
          }
          .note {
            position: static !important;
            width: auto !important;
            margin: 0 !important;
          }
        }
      `
    });
    await page.emulateMedia({ media: "print" });
    await page.pdf({
      path: pdfPath,
      format: "A4",
      landscape: true,
      printBackground: true,
      margin: { top: "0", right: "0", bottom: "0", left: "0" },
      preferCSSPageSize: true
    });

    return res.json({
      project: projectName,
      filename: pdfFilename,
      url: `/generated-pdf/${pdfFilename}`,
      title: title || ""
    });
  } catch (err) {
    return res.status(500).json({
      error: `Erreur export PDF: ${err.message}`
    });
  } finally {
    if (browser) await browser.close();
  }
});

app.post("/api/projects/:project/order", async (req, res) => {
  try {
    const projectName = sanitizeProjectName(req.params.project);
    const orderRaw = req.body?.order;
    if (typeof orderRaw !== "string") {
      return res.status(400).json({ error: "Champ 'order' invalide." });
    }
    const lines = orderRaw
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean)
      .filter((line) => /^[a-zA-Z0-9._-]+\.png$/.test(line));
    const content = lines.length ? `${lines.join("\n")}\n` : "";
    await mkdir(ORDER_DIR, { recursive: true });
    const orderFile = getProjectOrderFile(projectName);
    await writeFile(orderFile, content, "utf8");
    return res.json({ ok: true, project: projectName, filename: path.basename(orderFile) });
  } catch (err) {
    return res.status(500).json({ error: `Erreur sauvegarde ordre: ${err.message}` });
  }
});

app.post("/api/projects/:project/editor-state", async (req, res) => {
  try {
    const projectName = sanitizeProjectName(req.params.project);
    const orderRaw = req.body?.order;
    const notesRaw = req.body?.notes;

    if (typeof orderRaw !== "string") {
      return res.status(400).json({ error: "Champ 'order' invalide." });
    }
    if (notesRaw !== undefined && (typeof notesRaw !== "object" || notesRaw === null || Array.isArray(notesRaw))) {
      return res.status(400).json({ error: "Champ 'notes' invalide." });
    }

    const lines = orderRaw
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean)
      .filter((line) => /^[a-zA-Z0-9._-]+\.png$/.test(line));
    const orderContent = lines.length ? `${lines.join("\n")}\n` : "";
    await mkdir(ORDER_DIR, { recursive: true });
    const orderFile = getProjectOrderFile(projectName);
    await writeFile(orderFile, orderContent, "utf8");

    const notesContent = serializeNotesMarkdown(notesRaw || {});
    const notesFile = getProjectNotesFile(projectName);
    await mkdir(path.dirname(notesFile), { recursive: true });
    await writeFile(notesFile, notesContent, "utf8");

    return res.json({
      ok: true,
      project: projectName,
      orderFile: path.basename(orderFile),
      notesFile: path.relative(__dirname, notesFile)
    });
  } catch (err) {
    return res.status(500).json({ error: `Erreur sauvegarde edition: ${err.message}` });
  }
});

app.get("/generated/:filename", async (req, res) => {
  try {
    const { filename } = req.params;
    if (!/^captures_[a-z0-9._-]+\.html$/i.test(filename)) {
      return res.status(400).send("Nom de fichier invalide.");
    }
    const filePath = path.join(__dirname, filename);
    const exists = await fileExists(filePath);
    if (!exists) {
      return res.status(404).send("Fichier introuvable.");
    }
    return res.sendFile(filePath);
  } catch (err) {
    return res.status(500).send(`Erreur fichier généré: ${err.message}`);
  }
});

app.get("/generated-pdf/:filename", async (req, res) => {
  try {
    const { filename } = req.params;
    if (!/^captures_[a-z0-9._-]+\.pdf$/i.test(filename)) {
      return res.status(400).send("Nom de fichier invalide.");
    }
    const filePath = path.join(__dirname, filename);
    const exists = await fileExists(filePath);
    if (!exists) {
      return res.status(404).send("Fichier introuvable.");
    }
    return res.sendFile(filePath);
  } catch (err) {
    return res.status(500).send(`Erreur PDF généré: ${err.message}`);
  }
});

app.listen(PORT, () => {
  console.log(`Server running on http://localhost:${PORT}`);
});
