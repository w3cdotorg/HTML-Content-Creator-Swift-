import Foundation

struct HTMLDeckGenerator {
    private let paths: WorkspacePaths
    private let store: LegacyFileStore
    private let fileManager: FileManager

    init(paths: WorkspacePaths, store: LegacyFileStore, fileManager: FileManager = .default) {
        self.paths = paths
        self.store = store
        self.fileManager = fileManager
    }

    func generate(projectName rawProjectName: String, requestedTitle: String?) async throws -> HTMLGenerationOutput {
        let projectName = WorkspacePaths.sanitizeProjectName(rawProjectName)
        let title = try await resolveTitle(projectName: projectName, requestedTitle: requestedTitle)

        let captures = await store.readCaptureLog(projectName: projectName)
        let order = await store.readOrder(projectName: projectName)
        let notes = await store.readNotes(projectName: projectName)
        let orderedCaptures = applySavedOrder(captures: captures, order: order)

        let html = renderHTML(
            captures: orderedCaptures,
            projectName: projectName,
            title: title,
            notesByCapture: notes
        )

        let outputURL = paths.generatedHTMLFile(projectName: projectName)
        do {
            try fileManager.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try html.write(to: outputURL, atomically: true, encoding: .utf8)
        } catch {
            throw AppError.fileSystemOperationFailed(
                operation: "write",
                path: outputURL,
                underlying: error
            )
        }

        return HTMLGenerationOutput(
            projectName: projectName,
            fileURL: outputURL,
            title: title
        )
    }

    private func resolveTitle(projectName: String, requestedTitle: String?) async throws -> String {
        if let requestedTitle {
            let trimmed = requestedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                _ = try await store.writeProjectMetadata(
                    projectName: projectName,
                    metadata: ProjectMetadata(htmlTitle: trimmed)
                )
                return trimmed
            }
        }

        let metadata = await store.readProjectMetadata(projectName: projectName)
        if let stored = metadata.htmlTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            return stored
        }

        return "Captures - \(projectName)"
    }

    private func applySavedOrder(captures: [CaptureRecord], order: [String]) -> [CaptureRecord] {
        if order.isEmpty { return captures }

        var byFilename: [String: CaptureRecord] = [:]
        byFilename.reserveCapacity(captures.count)
        for capture in captures {
            byFilename[capture.filename] = capture
        }

        var ordered: [CaptureRecord] = []
        ordered.reserveCapacity(captures.count)
        for filename in order {
            if let capture = byFilename[filename] {
                ordered.append(capture)
            }
        }

        let alreadyIncluded = Set(ordered.map(\.filename))
        for capture in captures where !alreadyIncluded.contains(capture.filename) {
            ordered.append(capture)
        }

        return ordered
    }

    private func renderHTML(
        captures: [CaptureRecord],
        projectName: String,
        title: String,
        notesByCapture: [String: String]
    ) -> String {
        var notesForJS: [String: String] = [:]
        let cardBlocks: [String] = captures.map { capture in
            let rawFilename = capture.filename
            let filename = Self.htmlEscape(rawFilename)
            let sourceURL = capture.url.absoluteString
            let escapedSourceURL = Self.htmlEscape(sourceURL)
            let dateText = capture.capturedAt.map { LegacyDateFormatter.fullDateTimeString(from: $0) } ?? ""
            let escapedDate = Self.htmlEscape(dateText)

            let imagePath = imagePathForCapture(projectName: projectName, filename: rawFilename)
            let escapedImagePath = Self.htmlEscape(imagePath)

            let rawNote = notesByCapture[rawFilename]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !rawNote.isEmpty {
                notesForJS[rawFilename] = rawNote
            }
            let noteBlock: String
            if rawNote.isEmpty {
                noteBlock = ""
            } else {
                noteBlock = "<aside class=\"note\">\(markdownToHTML(rawNote))</aside>"
            }

            return """
              <div class=\"capture-row\">
                <article class=\"card\" data-capture=\"\(filename)\">
                  <div class=\"shot-block\">
                    <a class=\"shot-link\" href=\"\(escapedSourceURL)\" target=\"_blank\" rel=\"noopener\">
                      <img class=\"shot\" src=\"\(escapedImagePath)\" alt=\"Capture\" loading=\"lazy\" />
                    </a>
                    <a class=\"link\" href=\"\(escapedSourceURL)\" target=\"_blank\" rel=\"noopener\">\(escapedSourceURL)</a>
                    <span class=\"date\">\(escapedDate)</span>
                  </div>
                </article>
                \(noteBlock)
              </div>
            """
        }

        let cardsHTML = cardBlocks.isEmpty ? "<p>No captures found.</p>" : cardBlocks.joined(separator: "\n")
        let escapedTitle = Self.htmlEscape(title)
        let notesJSON = Self.jsonString(notesForJS)
        let projectJSON = Self.jsonString(projectName)
        let orderDownloadName = Self.jsonString("order_\(projectName).md")
        let notesDownloadName = Self.jsonString("notes_\(projectName).md")
        let bundledFontFace = Self.spaceGroteskFontFaceCSS()

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <title>\(escapedTitle)</title>
          <style>
            \(bundledFontFace)
            :root{
              --bg: #f6f3ee;
              --ink: #1f2328;
              --muted: #5f6b76;
              --card: #fffdf9;
              --line: #e5dfd6;
              --accent: #0f5bd6;
            }
            * { box-sizing: border-box; }
            body{
              margin: 0;
              background: var(--bg);
              color: var(--ink);
              font-family: "Source Serif 4", "Georgia", serif;
            }
            .page{
              max-width: 920px;
              margin: 48px auto 80px;
              padding: 0 24px;
            }
            h1{
              letter-spacing: -0.02em;
              font-weight: 700;
              font-size: 34px;
              text-align: center;
              margin: 0 0 24px;
              font-family: "Space Grotesk", "Helvetica Neue", sans-serif;
            }
            .toolbar{
              display: flex;
              gap: 10px;
              justify-content: flex-end;
              margin: -8px 0 18px;
            }
            .edit-toggle, .export-pdf{
              font-family: "Space Grotesk", "Helvetica Neue", sans-serif;
              font-size: 14px;
              font-weight: 600;
              letter-spacing: 0.01em;
              color: var(--bg);
              border: none;
              padding: 10px 14px;
              border-radius: 999px;
              cursor: pointer;
            }
            .edit-toggle{ background: var(--ink); }
            .export-pdf{ background: #6b4c2a; }
            .card{
              background: var(--card);
              border: 1px solid var(--line);
              border-radius: 18px;
              padding: 24px;
              margin: 20px 0;
              box-shadow: 0 6px 18px rgba(20, 30, 45, 0.06);
              width: 100%;
              position: relative;
            }
            .capture-row{ position: relative; }
            .shot-block{
              display: inline-block;
              width: fit-content;
              max-width: 100%;
              text-align: left;
            }
            .shot-link{
              display: block;
              width: fit-content;
              max-width: 100%;
              margin: 0 auto 18px;
            }
            .shot{
              display: block;
              max-width: 100%;
              height: auto;
              border-radius: 12px;
              border: 1px solid var(--line);
            }
            .link{
              display: inline-block;
              font-family: "Space Grotesk", "Helvetica Neue", sans-serif;
              font-size: 20px;
              font-weight: 600;
              color: var(--accent);
              text-decoration: none;
              word-break: break-word;
              width: 100%;
            }
            .link:hover{ text-decoration: underline; }
            .date{
              display: block;
              margin-top: 6px;
              font-size: 14px;
              color: var(--muted);
            }
            .note{
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
            }
            .note p{ margin: 0 0 8px; }
            .note p:last-child{ margin-bottom: 0; }
            .note ul{ margin: 0; padding-left: 18px; }
            .note-editor{
              display: none;
              margin-top: 10px;
            }
            .note-editor textarea{
              width: 100%;
              min-height: 90px;
              border: 1px solid var(--line);
              border-radius: 10px;
              background: #fff;
              padding: 10px;
              resize: vertical;
              font-family: Georgia, serif;
              font-size: 14px;
            }
            .note-hint{
              margin-top: 6px;
              color: var(--muted);
              font-size: 12px;
            }
            @media (max-width: 1200px){
              .note{
                position: static;
                width: auto;
                margin-top: 12px;
              }
            }
            .edit-controls{
              display: none;
              position: absolute;
              top: 28px;
              right: 12px;
              gap: 6px;
              z-index: 2;
            }
            .edit-mode .edit-controls{ display: flex; }
            .edit-button{
              height: 30px;
              border-radius: 8px;
              border: 1px solid var(--line);
              background: #fff;
              cursor: pointer;
              font-size: 14px;
              line-height: 1;
              padding: 0 8px;
              min-width: 30px;
            }
          </style>
        </head>
        <body>
          <main class="page">
            <div class="toolbar">
              <button class="export-pdf" id="exportPdf">Export PDF</button>
              <button class="edit-toggle" id="editToggle">Mode edition</button>
            </div>
            <h1>\(escapedTitle)</h1>
        \(cardsHTML)
          </main>
          <script>
            const root = document.documentElement;
            const toggle = document.getElementById('editToggle');
            const exportPdf = document.getElementById('exportPdf');
            const projectName = \(projectJSON);
            const initialNotes = \(notesJSON);
            const orderDownloadName = \(orderDownloadName);
            const notesDownloadName = \(notesDownloadName);

            function ensureControls() {
              document.querySelectorAll('.card').forEach((card) => {
                if (card.querySelector('.edit-controls')) return;
                const controls = document.createElement('div');
                controls.className = 'edit-controls';
                controls.innerHTML =
                  '<button class="edit-button move-up" title="Move up">↑</button>' +
                  '<button class="edit-button move-down" title="Move down">↓</button>' +
                  '<button class="edit-button note-toggle" title="Add note">Note</button>';
                card.appendChild(controls);
                ensureNoteEditor(card);
              });
            }

            function ensureNoteEditor(card) {
              if (card.querySelector('.note-editor')) return;
              const filename = card.getAttribute('data-capture');
              const note = initialNotes[filename] || '';
              const editor = document.createElement('div');
              editor.className = 'note-editor';
              editor.innerHTML =
                '<textarea data-note-for="' + escapeHtml(filename) + '" placeholder="Markdown note...">' +
                escapeHtml(note) +
                '</textarea>' +
                '<div class="note-hint">Simple markdown: *bold*, _italic_, list with - item.</div>';
              card.appendChild(editor);
            }

            function escapeHtml(value) {
              return String(value)
                .replace(/&/g, '&amp;')
                .replace(/</g, '&lt;')
                .replace(/>/g, '&gt;')
                .replace(/"/g, '&quot;')
                .replace(/'/g, '&#39;');
            }

            function markdownToHtml(raw) {
              const lines = String(raw || '').split(/\\r?\\n/);
              const parts = [];
              let para = [];
              let inList = false;

              const inline = (text) => {
                let escaped = escapeHtml(text);
                escaped = escaped.replace(/\\*(.+?)\\*/g, '<strong>$1</strong>');
                escaped = escaped.replace(/_(.+?)_/g, '<em>$1</em>');
                return escaped;
              };

              const flushPara = () => {
                if (!para.length) return;
                parts.push('<p>' + inline(para.join(' ')) + '</p>');
                para = [];
              };

              const closeList = () => {
                if (!inList) return;
                parts.push('</ul>');
                inList = false;
              };

              for (const rawLine of lines) {
                const line = rawLine.trim();
                if (!line) {
                  flushPara();
                  closeList();
                  continue;
                }

                if (line.startsWith('- ')) {
                  flushPara();
                  if (!inList) {
                    parts.push('<ul>');
                    inList = true;
                  }
                  parts.push('<li>' + inline(line.slice(2)) + '</li>');
                  continue;
                }

                closeList();
                para.push(line);
              }

              flushPara();
              closeList();
              return parts.join('');
            }

            function moveCard(card, direction) {
              const row = card.closest('.capture-row') || card;
              const parent = row.parentElement;
              if (!parent) return;
              if (direction === 'up') {
                const prev = row.previousElementSibling;
                if (prev) parent.insertBefore(row, prev);
              } else {
                const next = row.nextElementSibling;
                if (next) parent.insertBefore(next, row);
              }
            }

            function toggleNoteEditor(card) {
              const editor = card.querySelector('.note-editor');
              if (!editor) return;
              const shown = editor.style.display === 'block';
              editor.style.display = shown ? 'none' : 'block';
            }

            function upsertNoteAside(card) {
              const row = card.closest('.capture-row');
              if (!row) return;
              const textarea = card.querySelector('.note-editor textarea');
              if (!textarea) return;

              const markdown = textarea.value.trim();
              const existing = row.querySelector('.note');
              if (!markdown) {
                if (existing) existing.remove();
                return;
              }

              const rendered = markdownToHtml(markdown);
              if (existing) {
                existing.innerHTML = rendered;
              } else {
                const aside = document.createElement('aside');
                aside.className = 'note';
                aside.innerHTML = rendered;
                row.appendChild(aside);
              }
            }

            function buildOrder() {
              const items = [];
              document.querySelectorAll('.card').forEach((card) => {
                const name = card.getAttribute('data-capture');
                if (name) items.push(name);
              });
              return items.join('\\n') + '\\n';
            }

            function buildNotes() {
              const notes = {};
              document.querySelectorAll('.card').forEach((card) => {
                const filename = card.getAttribute('data-capture');
                const textarea = card.querySelector('.note-editor textarea');
                if (!filename || !textarea) return;
                const value = textarea.value.trim();
                if (value) notes[filename] = value;
              });
              return notes;
            }

            function serializeNotesMarkdown(notes) {
              const entries = Object.entries(notes || {})
                .filter(([name, note]) =>
                  /^[a-zA-Z0-9._-]+\\.png$/.test(name) &&
                  typeof note === 'string' &&
                  note.trim()
                )
                .sort((a, b) => a[0].localeCompare(b[0]));

              if (!entries.length) {
                return '# Notes\\n\\n';
              }

              let output = '# Notes\\n\\n';
              for (const [filename, note] of entries) {
                output += '<!-- NOTE: ' + filename + ' -->\\n';
                output += note.trim() + '\\n';
                output += '<!-- END NOTE -->\\n\\n';
              }
              return output;
            }

            function downloadText(filename, content) {
              const blob = new Blob([content], { type: 'text/plain;charset=utf-8' });
              const url = URL.createObjectURL(blob);
              const a = document.createElement('a');
              a.href = url;
              a.download = filename;
              document.body.appendChild(a);
              a.click();
              a.remove();
              URL.revokeObjectURL(url);
            }

            function ensurePrintDeckStyle() {
              let style = document.getElementById('swift-html-print-style');
              if (!style) {
                style = document.createElement('style');
                style.id = 'swift-html-print-style';
                document.head.appendChild(style);
              }

              style.textContent = `
                .pdf-title-slide { display: none; }
                @media print {
                  @page { size: A4 landscape; margin: 0; }
                  html, body {
                    background: var(--bg) !important;
                    -webkit-print-color-adjust: exact !important;
                    print-color-adjust: exact !important;
                  }
                  .toolbar, h1 { display: none !important; }
                  .pdf-title-slide {
                    display: flex !important;
                    height: 210mm !important;
                    min-height: 210mm !important;
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
                    object-fit: contain !important;
                    image-rendering: -webkit-optimize-contrast !important;
                  }
                  .note {
                    position: static !important;
                    width: auto !important;
                    margin: 0 !important;
                  }
                }
              `;
            }

            function createTitleSlideForPrint() {
              const main = document.querySelector('main.page');
              if (!main) return null;

              const existing = main.querySelector('.pdf-title-slide');
              if (existing) existing.remove();

              const titleText = (document.querySelector('main.page > h1')?.textContent || document.title || 'Captures').trim();
              const slide = document.createElement('section');
              slide.className = 'pdf-title-slide';
              const heading = document.createElement('h2');
              heading.textContent = titleText;
              slide.appendChild(heading);
              main.insertBefore(slide, main.firstChild);
              return slide;
            }

            document.addEventListener('click', (event) => {
              if (!root.classList.contains('edit-mode')) return;
              const up = event.target.closest('.move-up');
              const down = event.target.closest('.move-down');
              const noteToggle = event.target.closest('.note-toggle');
              if (!up && !down && !noteToggle) return;
              const card = event.target.closest('.card');
              if (!card) return;
              if (up || down) {
                moveCard(card, up ? 'up' : 'down');
              } else if (noteToggle) {
                toggleNoteEditor(card);
              }
            });

            document.addEventListener('input', (event) => {
              if (!root.classList.contains('edit-mode')) return;
              const textarea = event.target.closest('.note-editor textarea');
              if (!textarea) return;
              const card = textarea.closest('.card');
              if (!card) return;
              upsertNoteAside(card);
            });

            toggle.addEventListener('click', () => {
              const editing = root.classList.toggle('edit-mode');
              if (editing) {
                ensureControls();
                toggle.textContent = 'Save';
              } else {
                const orderContent = buildOrder();
                const notesContent = serializeNotesMarkdown(buildNotes());
                downloadText(orderDownloadName, orderContent);
                downloadText(notesDownloadName, notesContent);
                toggle.textContent = 'Mode edition';
                alert('Order and notes were downloaded. Use the app editor to persist directly.');
              }
            });

            exportPdf.addEventListener('click', () => {
              ensurePrintDeckStyle();
              const titleSlide = createTitleSlideForPrint();

              const cleanup = () => {
                if (titleSlide && titleSlide.isConnected) {
                  titleSlide.remove();
                }
              };

              window.addEventListener('afterprint', cleanup, { once: true });
              window.print();
              setTimeout(cleanup, 2000);
            });
          </script>
        </body>
        </html>
        """
    }

    private func imagePathForCapture(projectName: String, filename: String) -> String {
        if projectName == WorkspacePaths.defaultProjectName {
            return "screenshots/\(filename)"
        }
        return "screenshots/\(projectName)/\(filename)"
    }

    private func markdownToHTML(_ raw: String) -> String {
        let lines = raw.components(separatedBy: .newlines)
        var parts: [String] = []
        var paragraph: [String] = []
        var inList = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: " ")
            parts.append("<p>\(inlineMarkdownToHTML(joined))</p>")
            paragraph.removeAll(keepingCapacity: true)
        }

        func closeList() {
            guard inList else { return }
            parts.append("</ul>")
            inList = false
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                flushParagraph()
                closeList()
                continue
            }

            if line.hasPrefix("- ") {
                flushParagraph()
                if !inList {
                    parts.append("<ul>")
                    inList = true
                }
                let itemText = String(line.dropFirst(2))
                parts.append("<li>\(inlineMarkdownToHTML(itemText))</li>")
                continue
            }

            closeList()
            paragraph.append(line)
        }

        flushParagraph()
        closeList()
        return parts.joined()
    }

    private func inlineMarkdownToHTML(_ raw: String) -> String {
        var escaped = Self.htmlEscape(raw)
        escaped = replacingMatches(in: escaped, pattern: #"\*(.+?)\*"#, template: "<strong>$1</strong>")
        escaped = replacingMatches(in: escaped, pattern: #"_(.+?)_"#, template: "<em>$1</em>")
        return escaped
    }

    private func replacingMatches(in value: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: template)
    }

    private static func htmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) else {
            return "null"
        }
        guard
            let data = try? JSONSerialization.data(withJSONObject: value, options: []),
            let text = String(data: data, encoding: .utf8)
        else {
            return "null"
        }
        return text
    }

    private static func spaceGroteskFontFaceCSS() -> String {
        if let fontData = bundledSpaceGroteskFontData() {
            let encoded = fontData.base64EncodedString()
            return """
            @font-face {
              font-family: "Space Grotesk";
              src: local("Space Grotesk"), url(data:font/ttf;base64,\(encoded)) format("truetype");
              font-weight: 300 700;
              font-style: normal;
              font-display: swap;
            }
            """
        }

        return """
        @font-face {
          font-family: "Space Grotesk";
          src: local("Space Grotesk");
          font-weight: 300 700;
          font-style: normal;
          font-display: swap;
        }
        """
    }

    private static func bundledSpaceGroteskFontData() -> Data? {
        let filename = "SpaceGrotesk-VariableFont_wght"
        let extensionName = "ttf"
        let bundles: [Bundle] = [Bundle.main, Bundle(for: BundleToken.self)] + Bundle.allBundles + Bundle.allFrameworks
        var scannedBundleIDs = Set<String>()

        for bundle in bundles {
            let bundleID = bundle.bundleIdentifier ?? bundle.bundleURL.path
            if scannedBundleIDs.contains(bundleID) {
                continue
            }
            scannedBundleIDs.insert(bundleID)

            let directURL = bundle.url(forResource: filename, withExtension: extensionName)
            let nestedURL = bundle.url(forResource: filename, withExtension: extensionName, subdirectory: "Resources/Fonts")
            if let url = directURL ?? nestedURL, let data = try? Data(contentsOf: url) {
                return data
            }
        }

        return nil
    }

    private final class BundleToken {}
}
