import express from "express";
import path from "path";
import { fileURLToPath } from "url";
import { mkdir, writeFile, readdir, stat, readFile, unlink } from "fs/promises";
import { chromium } from "playwright";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
const PORT = process.env.PORT || 3000;

const SCREENSHOTS_DIR = path.join(__dirname, "screenshots");
const COUNTER_FILE = path.join(SCREENSHOTS_DIR, ".counter");
const MARKDOWN_LOG = path.join(SCREENSHOTS_DIR, "captures.md");

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

async function appendCaptureMarkdown({ filename, url, dateTime }) {
  await mkdir(SCREENSHOTS_DIR, { recursive: true });
  let content = "";
  try {
    content = await readFile(MARKDOWN_LOG, "utf8");
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

  await writeFile(MARKDOWN_LOG, content + block);
}

async function removeCaptureMarkdown(filename) {
  try {
    const content = await readFile(MARKDOWN_LOG, "utf8");
    const pattern = new RegExp(
      `<!-- CAPTURE: ${escapeRegex(filename)} -->[\\s\\S]*?(\\n\\n|$)`,
      "g"
    );
    const updated = content.replace(pattern, "");
    await writeFile(MARKDOWN_LOG, updated);
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

async function getNextId() {
  await mkdir(SCREENSHOTS_DIR, { recursive: true });
  try {
    const raw = await readFile(COUNTER_FILE, "utf8");
    const current = Number.parseInt(raw.trim(), 10);
    if (!Number.isFinite(current) || current < 1) throw new Error("invalid");
    const next = current + 1;
    await writeFile(COUNTER_FILE, String(next));
    return String(current).padStart(3, "0");
  } catch {
    await writeFile(COUNTER_FILE, "2");
    return "001";
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

app.post("/api/screenshot", async (req, res) => {
  const { url } = req.body || {};
  if (!url || typeof url !== "string") {
    return res.status(400).json({ error: "URL manquante." });
  }

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
  const id = await getNextId();
  const filename = `${id}_${domain}_${dateStr}_${timeStr}.png`;
  const filepath = path.join(SCREENSHOTS_DIR, filename);

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
      filename,
      url: parsedUrl.toString(),
      dateTime: dateTimeFull
    });

    return res.json({
      filename,
      url: `/screenshots/${filename}`
    });
  } catch (err) {
    return res.status(500).json({ error: `Erreur capture: ${err.message}` });
  } finally {
    if (browser) await browser.close();
  }
});

app.get("/api/history", async (_req, res) => {
  try {
    await mkdir(SCREENSHOTS_DIR, { recursive: true });
    const files = await readdir(SCREENSHOTS_DIR);
    const pngFiles = files.filter((file) => file.toLowerCase().endsWith(".png"));

    const entries = await Promise.all(
      pngFiles.map(async (file) => {
        const filePath = path.join(SCREENSHOTS_DIR, file);
        const stats = await stat(filePath);
        return {
          filename: file,
          url: `/screenshots/${file}`,
          mtime: stats.mtimeMs
        };
      })
    );

    entries.sort((a, b) => b.mtime - a.mtime);

    return res.json({ items: entries });
  } catch (err) {
    return res.status(500).json({ error: `Erreur historique: ${err.message}` });
  }
});

app.delete("/api/history/:filename", async (req, res) => {
  try {
    const { filename } = req.params;
    if (!filename || filename !== path.basename(filename)) {
      return res.status(400).json({ error: "Nom de fichier invalide." });
    }
    if (!filename.toLowerCase().endsWith(".png")) {
      return res.status(400).json({ error: "Seuls les PNG sont acceptés." });
    }

    const filePath = path.join(SCREENSHOTS_DIR, filename);
    await unlink(filePath);
    await removeCaptureMarkdown(filename);
    return res.json({ ok: true });
  } catch (err) {
    return res.status(500).json({ error: `Erreur suppression: ${err.message}` });
  }
});

app.listen(PORT, () => {
  console.log(`Server running on http://localhost:${PORT}`);
});
