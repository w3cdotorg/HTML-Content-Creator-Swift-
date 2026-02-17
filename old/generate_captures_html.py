#!/usr/bin/env python3
from __future__ import annotations

import argparse
import html
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SCREENSHOTS_ROOT = ROOT / "screenshots"
NOTES_ROOT = ROOT / "notes"
ORDER_ROOT = ROOT / "order"
DEFAULT_PROJECT = "default"

CAPTURE_RE = re.compile(r"^<!--\s*CAPTURE:\s*(.+?)\s*-->\s*$")
FIELD_RE = re.compile(r"^-\s*(Fichier|URL|Date):\s*(.+?)\s*$")
NOTE_START_RE = re.compile(r"^<!--\s*NOTE:\s*(.+?)\s*-->\s*$")
NOTE_END_RE = re.compile(r"^<!--\s*END NOTE\s*-->\s*$")
PROJECT_RE = re.compile(r"[^a-z0-9._-]+")


def sanitize_project(value: str) -> str:
    name = (value or "").strip().lower().replace(" ", "-")
    name = PROJECT_RE.sub("", name)
    return name or DEFAULT_PROJECT


def project_dir(project: str) -> Path:
    if project == DEFAULT_PROJECT:
        return SCREENSHOTS_ROOT
    return SCREENSHOTS_ROOT / project


def captures_file(project: str) -> Path:
    return project_dir(project) / "captures.md"


def output_file(project: str) -> Path:
    return ROOT / f"captures_{project}.html"


def notes_file(project: str) -> Path:
    return NOTES_ROOT / project / "notes.md"


def order_file(project: str) -> Path:
    return ORDER_ROOT / f"{project}.md"


def image_src(project: str, filename: str) -> str:
    if project == DEFAULT_PROJECT:
        return f"/screenshots/{filename}"
    return f"/screenshots/{project}/{filename}"


def parse_captures(text: str):
    captures = []
    current = None

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue

        cap_match = CAPTURE_RE.match(line)
        if cap_match:
            if current:
                captures.append(current)
            current = {"id": cap_match.group(1)}
            continue

        field_match = FIELD_RE.match(line)
        if field_match and current is not None:
            key, value = field_match.groups()
            value = value.strip()
            if key == "Fichier":
                value = value.strip("`")
            current[key.lower()] = value

    if current:
        captures.append(current)

    return captures


def parse_notes_markdown(text: str) -> dict[str, str]:
    notes: dict[str, str] = {}
    current_name: str | None = None
    buf: list[str] = []

    def flush_current() -> None:
        nonlocal current_name, buf
        if current_name is None:
            return
        notes[current_name] = "\n".join(buf).strip()
        current_name = None
        buf = []

    for raw_line in text.splitlines():
        start_match = NOTE_START_RE.match(raw_line.strip())
        if start_match:
            flush_current()
            current_name = start_match.group(1).strip()
            buf = []
            continue

        if NOTE_END_RE.match(raw_line.strip()):
            flush_current()
            continue

        if current_name is not None:
            buf.append(raw_line)

    flush_current()
    return notes


def load_notes(project: str) -> dict[str, str]:
    path = notes_file(project)
    if not path.exists():
        return {}
    return parse_notes_markdown(path.read_text(encoding="utf-8"))


def markdown_to_html(text: str) -> str:
    def inline(value: str) -> str:
        escaped = html.escape(value)
        escaped = re.sub(r"\*(.+?)\*", r"<strong>\1</strong>", escaped)
        escaped = re.sub(r"_(.+?)_", r"<em>\1</em>", escaped)
        return escaped

    lines = text.splitlines()
    parts = []
    para = []
    in_list = False

    def flush_para():
        nonlocal para
        if para:
            parts.append(f"<p>{inline(' '.join(para))}</p>")
            para = []

    def close_list():
        nonlocal in_list
        if in_list:
            parts.append("</ul>")
            in_list = False

    for raw_line in lines:
        line = raw_line.strip()
        if not line:
            flush_para()
            close_list()
            continue

        if line.startswith("- "):
            flush_para()
            if not in_list:
                parts.append("<ul>")
                in_list = True
            parts.append(f"<li>{inline(line[2:])}</li>")
            continue

        close_list()
        para.append(line)

    flush_para()
    close_list()

    return "".join(parts)


def apply_order(captures, order_path: Path):
    if not order_path.exists():
        return captures

    order = []
    for raw_line in order_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        order.append(line)

    by_name = {item.get("fichier"): item for item in captures if item.get("fichier")}
    ordered = [by_name[name] for name in order if name in by_name]
    remaining = [item for item in captures if item.get("fichier") not in order]
    return ordered + remaining


def render_html(captures, *, project: str, title: str, notes_by_capture: dict[str, str]):
    cards = []
    notes_for_js: dict[str, str] = {}

    for item in captures:
        raw_filename = item.get("fichier", "")
        filename = html.escape(raw_filename)
        url = html.escape(item.get("url", ""))
        date = html.escape(item.get("date", ""))
        img = image_src(project, raw_filename) if raw_filename else ""
        img_src = html.escape(img)

        note_text = notes_by_capture.get(raw_filename, "").strip()
        if note_text:
            notes_for_js[raw_filename] = note_text
        note_html = markdown_to_html(note_text) if note_text else ""
        note_block = f"<aside class=\"note\">{note_html}</aside>" if note_text else ""

        cards.append(
            f"""
      <div class=\"capture-row\">
        <article class=\"card\" data-capture=\"{filename}\">
          <div class=\"shot-block\">
            <a class=\"shot-link\" href=\"{url}\" target=\"_blank\" rel=\"noopener\">
              <img class=\"shot\" src=\"{img_src}\" alt=\"Capture de l'article\" loading=\"lazy\" />
            </a>
            <a class=\"link\" href=\"{url}\" target=\"_blank\" rel=\"noopener\">{url}</a>
            <span class=\"date\">{date}</span>
          </div>
        </article>
        {note_block}
      </div>"""
        )

    cards_html = "\n".join(cards) if cards else "<p>Aucune capture trouvee.</p>"
    h1 = html.escape(title)
    order_download_name = html.escape(f"order_{project}.md")

    return f"""<!doctype html>
<html lang=\"fr\">
<head>
  <meta charset=\"utf-8\" />
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
  <title>{h1}</title>
  <link rel=\"preconnect\" href=\"https://fonts.googleapis.com\">
  <link rel=\"preconnect\" href=\"https://fonts.gstatic.com\" crossorigin>
  <link href=\"https://fonts.googleapis.com/css2?family=Source+Serif+4:wght@400;500;600&family=Space+Grotesk:wght@500;600&display=swap\" rel=\"stylesheet\">
  <style>
    :root{{
      --bg: #f6f3ee;
      --ink: #1f2328;
      --muted: #5f6b76;
      --card: #fffdf9;
      --line: #e5dfd6;
      --accent: #0f5bd6;
    }}

    * {{ box-sizing: border-box; }}

    body{{
      margin: 0;
      background: var(--bg);
      color: var(--ink);
      font-family: \"Source Serif 4\", \"Georgia\", serif;
    }}

    .page{{
      max-width: 920px;
      margin: 48px auto 80px;
      padding: 0 24px;
    }}

    h1{{
      font-family: \"Space Grotesk\", \"Helvetica Neue\", sans-serif;
      letter-spacing: -0.02em;
      font-weight: 600;
      font-size: 36px;
      text-align: center;
      margin: 0 0 24px;
    }}

    .toolbar{{
      display: flex;
      gap: 10px;
      justify-content: flex-end;
      margin: -8px 0 18px;
    }}

    .edit-toggle{{
      font-family: \"Space Grotesk\", \"Helvetica Neue\", sans-serif;
      font-size: 14px;
      font-weight: 600;
      letter-spacing: 0.01em;
      background: var(--ink);
      color: var(--bg);
      border: none;
      padding: 10px 14px;
      border-radius: 999px;
      cursor: pointer;
    }}

    .export-pdf{{
      font-family: \"Space Grotesk\", \"Helvetica Neue\", sans-serif;
      font-size: 14px;
      font-weight: 600;
      letter-spacing: 0.01em;
      background: #6b4c2a;
      color: var(--bg);
      border: none;
      padding: 10px 14px;
      border-radius: 999px;
      cursor: pointer;
    }}

    .card{{
      background: var(--card);
      border: 1px solid var(--line);
      border-radius: 18px;
      padding: 24px;
      margin: 20px 0;
      box-shadow: 0 6px 18px rgba(20, 30, 45, 0.06);
      width: 100%;
      position: relative;
    }}

    .capture-row{{
      position: relative;
    }}

    .shot-block{{
      display: inline-block;
      width: fit-content;
      max-width: 100%;
      text-align: left;
    }}

    .shot-link{{
      display: block;
      width: fit-content;
      max-width: 100%;
      margin: 0 auto 18px;
    }}

    .shot{{
      display: block;
      max-width: 100%;
      height: auto;
      border-radius: 12px;
      border: 1px solid var(--line);
    }}

    .link{{
      display: inline-block;
      font-family: \"Space Grotesk\", \"Helvetica Neue\", sans-serif;
      font-size: 20px;
      font-weight: 600;
      color: var(--accent);
      text-decoration: none;
      word-break: break-word;
      width: 100%;
    }}

    .link:hover{{ text-decoration: underline; }}

    .date{{
      display: block;
      margin-top: 6px;
      font-size: 14px;
      color: var(--muted);
    }}

    .note{{
      font-size: 16px;
      color: var(--muted);
      background: #f2ede5;
      border: 1px solid var(--line);
      padding: 12px 14px;
      border-radius: 12px;
      position: absolute;
      top: 24px;
      right: -260px;
      width: 240px;
    }}

    .note p{{ margin: 0 0 8px; }}
    .note p:last-child{{ margin-bottom: 0; }}
    .note ul{{ margin: 0; padding-left: 18px; }}

    .note-editor{{
      display: none;
      margin-top: 10px;
    }}

    .note-editor textarea{{
      width: 100%;
      min-height: 90px;
      border: 1px solid var(--line);
      border-radius: 10px;
      background: #fff;
      padding: 10px;
      resize: vertical;
      font-family: \"Source Serif 4\", \"Georgia\", serif;
      font-size: 14px;
    }}

    .note-hint{{
      margin-top: 6px;
      color: var(--muted);
      font-size: 12px;
    }}

    @media (max-width: 1200px){{
      .note{{
        position: static;
        width: auto;
        margin-top: 12px;
      }}
    }}

    .edit-controls{{
      display: none;
      position: absolute;
      top: 28px;
      right: 12px;
      gap: 6px;
      z-index: 2;
    }}

    .edit-mode .edit-controls{{ display: flex; }}

    .edit-button{{
      height: 30px;
      border-radius: 8px;
      border: 1px solid var(--line);
      background: #fff;
      cursor: pointer;
      font-size: 14px;
      line-height: 1;
      padding: 0 8px;
      min-width: 30px;
    }}
  </style>
</head>
<body>
  <main class=\"page\">
    <div class=\"toolbar\">
      <button class=\"export-pdf\" id=\"exportPdf\">Export PDF</button>
      <button class=\"edit-toggle\" id=\"editToggle\">Mode edition</button>
    </div>
    <h1>{h1}</h1>
{cards_html}
  </main>
  <script>
    const root = document.documentElement;
    const toggle = document.getElementById('editToggle');
    const exportPdf = document.getElementById('exportPdf');
    const projectName = {json.dumps(project)};
    const pageTitle = {json.dumps(title)};
    const initialNotes = {json.dumps(notes_for_js, ensure_ascii=False)};

    function ensureControls() {{
      document.querySelectorAll('.card').forEach((card) => {{
        if (card.querySelector('.edit-controls')) return;
        const controls = document.createElement('div');
        controls.className = 'edit-controls';
        controls.innerHTML = `
          <button class="edit-button move-up" title="Monter">↑</button>
          <button class="edit-button move-down" title="Descendre">↓</button>
          <button class="edit-button note-toggle" title="Ajouter une note">Ajout note</button>
        `;
        card.appendChild(controls);
        ensureNoteEditor(card);
      }});
    }}

    function ensureNoteEditor(card) {{
      if (card.querySelector('.note-editor')) return;
      const filename = card.getAttribute('data-capture');
      const note = initialNotes[filename] || '';
      const editor = document.createElement('div');
      editor.className = 'note-editor';
      editor.innerHTML = `
        <textarea data-note-for="${{filename}}" placeholder="Note markdown...">${{escapeHtml(note)}}</textarea>
        <div class="note-hint">Markdown simple: *gras*, _italique_, listes avec - item.</div>
      `;
      card.appendChild(editor);
    }}

    function escapeHtml(value) {{
      return String(value)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
    }}

    function markdownToHtml(raw) {{
      const lines = String(raw || '').split(/\\r?\\n/);
      const parts = [];
      let para = [];
      let inList = false;

      const inline = (text) => {{
        let escaped = escapeHtml(text);
        escaped = escaped.replace(/\*(.+?)\*/g, '<strong>$1</strong>');
        escaped = escaped.replace(/_(.+?)_/g, '<em>$1</em>');
        return escaped;
      }};

      const flushPara = () => {{
        if (!para.length) return;
        parts.push(`<p>${{inline(para.join(' '))}}</p>`);
        para = [];
      }};

      const closeList = () => {{
        if (!inList) return;
        parts.push('</ul>');
        inList = false;
      }};

      for (const rawLine of lines) {{
        const line = rawLine.trim();
        if (!line) {{
          flushPara();
          closeList();
          continue;
        }}
        if (line.startsWith('- ')) {{
          flushPara();
          if (!inList) {{
            parts.push('<ul>');
            inList = true;
          }}
          parts.push(`<li>${{inline(line.slice(2))}}</li>`);
          continue;
        }}
        closeList();
        para.push(line);
      }}

      flushPara();
      closeList();
      return parts.join('');
    }}

    function moveCard(card, direction) {{
      const row = card.closest('.capture-row') || card;
      const parent = row.parentElement;
      if (!parent) return;
      if (direction === 'up') {{
        const prev = row.previousElementSibling;
        if (prev) parent.insertBefore(row, prev);
      }} else {{
        const next = row.nextElementSibling;
        if (next) parent.insertBefore(next, row);
      }}
    }}

    function toggleNoteEditor(card) {{
      const editor = card.querySelector('.note-editor');
      if (!editor) return;
      const shown = editor.style.display === 'block';
      editor.style.display = shown ? 'none' : 'block';
    }}

    function upsertNoteAside(card) {{
      const row = card.closest('.capture-row');
      if (!row) return;
      const textarea = card.querySelector('.note-editor textarea');
      if (!textarea) return;

      const markdown = textarea.value.trim();
      const existing = row.querySelector('.note');
      if (!markdown) {{
        if (existing) existing.remove();
        return;
      }}

      const rendered = markdownToHtml(markdown);
      if (existing) {{
        existing.innerHTML = rendered;
      }} else {{
        const aside = document.createElement('aside');
        aside.className = 'note';
        aside.innerHTML = rendered;
        row.appendChild(aside);
      }}
    }}

    document.addEventListener('click', (event) => {{
      if (!root.classList.contains('edit-mode')) return;
      const up = event.target.closest('.move-up');
      const down = event.target.closest('.move-down');
      const noteToggle = event.target.closest('.note-toggle');
      if (!up && !down && !noteToggle) return;
      const card = event.target.closest('.card');
      if (!card) return;
      if (up || down) {{
        moveCard(card, up ? 'up' : 'down');
      }} else if (noteToggle) {{
        toggleNoteEditor(card);
      }}
    }});

    document.addEventListener('input', (event) => {{
      if (!root.classList.contains('edit-mode')) return;
      const textarea = event.target.closest('.note-editor textarea');
      if (!textarea) return;
      const card = textarea.closest('.card');
      if (!card) return;
      upsertNoteAside(card);
    }});

    function buildOrder() {{
      const items = [];
      document.querySelectorAll('.card').forEach((card) => {{
        const name = card.getAttribute('data-capture');
        if (name) items.push(name);
      }});
      return items.join('\\n') + '\\n';
    }}

    function buildNotes() {{
      const notes = {{}};
      document.querySelectorAll('.card').forEach((card) => {{
        const filename = card.getAttribute('data-capture');
        const textarea = card.querySelector('.note-editor textarea');
        if (!filename || !textarea) return;
        const value = textarea.value.trim();
        if (value) notes[filename] = value;
      }});
      return notes;
    }}

    function downloadOrder() {{
      const content = buildOrder();
      const blob = new Blob([content], {{ type: 'text/markdown;charset=utf-8' }});
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = '{order_download_name}';
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
    }}

    async function saveEditorState() {{
      const response = await fetch(`/api/projects/${{encodeURIComponent(projectName)}}/editor-state`, {{
        method: 'POST',
        headers: {{ 'Content-Type': 'application/json' }},
        body: JSON.stringify({{ order: buildOrder(), notes: buildNotes() }})
      }});
      const data = await response.json();
      if (!response.ok) {{
        throw new Error(data.error || 'Erreur sauvegarde edition.');
      }}
    }}

    toggle.addEventListener('click', async () => {{
      const editing = root.classList.toggle('edit-mode');
      if (editing) {{
        ensureControls();
        toggle.textContent = 'Sauvegarder';
      }} else {{
        try {{
          await saveEditorState();
        }} catch (error) {{
          alert(error.message + " Telechargement local de l'ordre en secours.");
          downloadOrder();
        }}
        toggle.textContent = 'Mode edition';
      }}
    }});

    exportPdf.addEventListener('click', async () => {{
      const originalText = exportPdf.textContent;
      exportPdf.disabled = true;
      exportPdf.textContent = 'Export PDF...';
      try {{
        const response = await fetch(`/api/projects/${{encodeURIComponent(projectName)}}/export-pdf`, {{
          method: 'POST',
          headers: {{ 'Content-Type': 'application/json' }},
          body: JSON.stringify({{ title: pageTitle }})
        }});
        const data = await response.json();
        if (!response.ok) {{
          throw new Error(data.error || 'Erreur export PDF.');
        }}
        window.open(data.url, '_blank', 'noopener');
      }} catch (error) {{
        alert(error.message);
      }} finally {{
        exportPdf.disabled = false;
        exportPdf.textContent = originalText;
      }}
    }});
  </script>
</body>
</html>
"""


def discover_projects() -> list[str]:
    projects = [DEFAULT_PROJECT]
    if not SCREENSHOTS_ROOT.exists():
        return projects

    for child in sorted(SCREENSHOTS_ROOT.iterdir()):
        if child.is_dir():
            name = sanitize_project(child.name)
            if name != DEFAULT_PROJECT and name not in projects:
                projects.append(name)
    return projects


def generate_project(project: str, title: str | None = None) -> bool:
    project = sanitize_project(project)
    md_path = captures_file(project)
    if not md_path.exists():
        return False

    ORDER_ROOT.mkdir(parents=True, exist_ok=True)

    captures = parse_captures(md_path.read_text(encoding="utf-8"))
    captures = apply_order(captures, order_file(project))
    notes_map = load_notes(project)

    page_title = title or f"Captures - {project}"
    html_output = render_html(captures, project=project, title=page_title, notes_by_capture=notes_map)
    output_path = output_file(project)
    output_path.write_text(html_output, encoding="utf-8")
    print(f"Generated: {output_path.name}")
    return True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate HTML pages from project captures.md files.")
    parser.add_argument("--project", default=DEFAULT_PROJECT, help="Project name (default: default)")
    parser.add_argument("--all-projects", action="store_true", help="Generate one HTML file per project")
    parser.add_argument("--title", default=None, help="Page title override")
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if args.all_projects:
        generated = 0
        for project in discover_projects():
            if generate_project(project, title=None):
                generated += 1
        if generated == 0:
            print("No captures.md found in any project.", file=sys.stderr)
            return 1
        return 0

    if generate_project(args.project, title=args.title):
        return 0

    project = sanitize_project(args.project)
    print(f"Missing captures file: {captures_file(project)}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
