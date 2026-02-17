import AppKit
import Foundation
import WebKit

enum WebKitPDFExportEngine {
    static let viewport = CGSize(width: 1920, height: 1080)

    @MainActor
    static func export(
        htmlFileURL: URL,
        readAccessURL: URL,
        outputPDFURL: URL,
        title: String
    ) async throws {
        let session = WebKitPDFExportSession(viewport: viewport)
        try await session.export(
            htmlFileURL: htmlFileURL,
            readAccessURL: readAccessURL,
            outputPDFURL: outputPDFURL,
            title: title
        )
    }
}

@MainActor
private final class WebKitPDFExportSession: NSObject, WKNavigationDelegate {
    private static let a4PortraitPaperSize = NSSize(width: 595.0, height: 842.0)
    private static let a4LandscapePageRect = CGRect(
        origin: .zero,
        size: CGSize(width: a4PortraitPaperSize.height, height: a4PortraitPaperSize.width)
    )
    private static let highQualitySnapshotScale: CGFloat = 4.0

    private struct SlideLink {
        let url: URL
        let rect: CGRect
    }

    private struct SlideFrame {
        let rect: CGRect
        let links: [SlideLink]
    }

    private struct SlidePageData {
        let image: CGImage
        let sourceSize: CGSize
        let links: [SlideLink]
    }

    private let viewport: CGSize
    private let webView: WKWebView
    private let window: NSWindow
    private let fileManager: FileManager

    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var loadTimeoutTask: Task<Void, Never>?

    init(viewport: CGSize, fileManager: FileManager = .default) {
        self.viewport = viewport
        self.fileManager = fileManager

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.suppressesIncrementalRendering = false

        self.webView = WKWebView(frame: CGRect(origin: .zero, size: viewport), configuration: config)
        self.window = NSWindow(
            contentRect: CGRect(origin: .zero, size: viewport),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        super.init()

        webView.navigationDelegate = self
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.isOpaque = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = webView
        window.orderOut(nil)
    }

    deinit {
        loadTimeoutTask?.cancel()
    }

    func export(
        htmlFileURL: URL,
        readAccessURL: URL,
        outputPDFURL: URL,
        title: String
    ) async throws {
        defer {
            cleanup()
        }

        guard fileManager.fileExists(atPath: htmlFileURL.path) else {
            throw AppError.invalidInput("Generated HTML is missing for PDF export.")
        }

        if fileManager.fileExists(atPath: outputPDFURL.path) {
            do {
                try fileManager.removeItem(at: outputPDFURL)
            } catch {
                throw AppError.fileSystemOperationFailed(
                    operation: "removeItem",
                    path: outputPDFURL,
                    underlying: error
                )
            }
        }

        try await loadPage(
            htmlFileURL: htmlFileURL,
            readAccessURL: readAccessURL,
            timeoutSeconds: 45
        )
        try await Task.sleep(nanoseconds: 400_000_000)
        try await waitUntilImagesLoaded()
        try await injectPDFPresentation(title: title)
        try await Task.sleep(nanoseconds: 200_000_000)
        try await exportPDF(outputPDFURL: outputPDFURL)

        guard fileManager.fileExists(atPath: outputPDFURL.path) else {
            throw AppError.captureFailed("PDF export finished without an output file.")
        }

        AppLogger.deck.info("PDF exported: \(outputPDFURL.path, privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resolveLoad(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resolveLoad(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resolveLoad(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        resolveLoad(.failure(AppError.captureFailed("Web content process terminated during PDF export.")))
    }

    private func loadPage(
        htmlFileURL: URL,
        readAccessURL: URL,
        timeoutSeconds: UInt64
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation

            loadTimeoutTask?.cancel()
            loadTimeoutTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                guard self.loadContinuation != nil else { return }
                self.webView.stopLoading()
                self.resolveLoad(.failure(AppError.captureFailed("PDF load timeout after \(timeoutSeconds)s.")))
            }

            webView.loadFileURL(htmlFileURL, allowingReadAccessTo: readAccessURL)
        }
    }

    private func resolveLoad(_ result: Result<Void, Error>) {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil

        guard let continuation = loadContinuation else { return }
        loadContinuation = nil

        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func waitUntilImagesLoaded(maxAttempts: Int = 30) async throws {
        let script = "Array.from(document.images || []).every((img) => img.complete)"
        for _ in 0..<maxAttempts {
            let done = (try? await webView.evaluateJavaScriptAsync(script)) as? Bool ?? false
            if done {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func injectPDFPresentation(title: String) async throws {
        let script = """
        (() => {
          const renderedTitle = \(Self.jsStringLiteral(title));
          const printStyles = \(Self.jsStringLiteral(Self.printStylesheet));
          const exportStyles = \(Self.jsStringLiteral(Self.screenExportStylesheet));

          const main = document.querySelector('main.page');
          if (!main) return false;

          const existingSlide = main.querySelector('.pdf-title-slide');
          if (existingSlide) existingSlide.remove();

          const slide = document.createElement('section');
          slide.className = 'pdf-title-slide';
          const heading = document.createElement('h2');
          heading.textContent = renderedTitle;
          slide.appendChild(heading);
          main.insertBefore(slide, main.firstChild);

          let printStyle = document.getElementById('swift-pdf-print-style');
          if (!printStyle) {
            printStyle = document.createElement('style');
            printStyle.id = 'swift-pdf-print-style';
            document.head.appendChild(printStyle);
          }
          printStyle.textContent = printStyles;

          let exportStyle = document.getElementById('swift-pdf-export-style');
          if (!exportStyle) {
            exportStyle = document.createElement('style');
            exportStyle.id = 'swift-pdf-export-style';
            document.head.appendChild(exportStyle);
          }
          exportStyle.textContent = exportStyles;

          document.body.classList.add('swift-pdf-export-mode');

          return true;
        })();
        """

        let injected = try await webView.evaluateJavaScriptAsync(script) as? Bool ?? false
        guard injected else {
            throw AppError.captureFailed("Unable to prepare HTML for PDF export.")
        }
    }

    private func runPrintOperation(outputPDFURL: URL) throws {
        let paperSize = Self.a4PortraitPaperSize
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        printInfo.paperSize = paperSize
        printInfo.orientation = .landscape
        printInfo.topMargin = 0
        printInfo.bottomMargin = 0
        printInfo.leftMargin = 0
        printInfo.rightMargin = 0
        printInfo.horizontalPagination = .automatic
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false

        let dictionary = printInfo.dictionary()
        dictionary[NSPrintInfo.AttributeKey.jobDisposition] = NSPrintInfo.JobDisposition.save
        dictionary[NSPrintInfo.AttributeKey.jobSavingURL] = outputPDFURL

        ensurePrintHierarchyReady(
            minimumContentSize: NSSize(
                width: max(viewport.width, paperSize.height),
                height: max(viewport.height, paperSize.width)
            )
        )

        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false

        guard operation.run() else {
            throw AppError.captureFailed("PDF print operation failed.")
        }
    }

    private func exportPDF(outputPDFURL: URL) async throws {
        preparePrintViewLayout()

        do {
            try await exportUsingCreatePDF(outputPDFURL: outputPDFURL)
            if fileManager.fileExists(atPath: outputPDFURL.path) {
                return
            }
            AppLogger.deck.warning("createPDF finished without output; switching to print fallback.")
        } catch {
            AppLogger.deck.warning("createPDF failed (\(error.localizedDescription, privacy: .public)); switching to print fallback.")
        }

        try runPrintOperation(outputPDFURL: outputPDFURL)
        guard fileManager.fileExists(atPath: outputPDFURL.path) else {
            throw AppError.captureFailed("PDF export finished without an output file.")
        }
    }

    private func exportUsingCreatePDF(outputPDFURL: URL) async throws {
        let originalZoom = webView.pageZoom
        webView.pageZoom = 1.0
        defer {
            webView.pageZoom = originalZoom
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        let stableWidth = max(viewport.width, 1)
        let stableHeight = max(viewport.height, 1)
        ensurePrintHierarchyReady(minimumContentSize: NSSize(width: stableWidth, height: stableHeight))
        let slideCount = await resolveSlideCount()
        guard slideCount > 0 else {
            throw AppError.captureFailed("No printable slides found for PDF export.")
        }

        var slidePageData: [SlidePageData] = []
        slidePageData.reserveCapacity(slideCount)

        for slideIndex in 0..<slideCount {
            guard let frame = await frameForSlide(at: slideIndex) else {
                continue
            }

            let configuration = WKSnapshotConfiguration()
            configuration.rect = frame.rect
            configuration.afterScreenUpdates = true
            configuration.snapshotWidth = NSNumber(value: Double(max(frame.rect.width * Self.highQualitySnapshotScale, 1)))

            let snapshot = try await webView.takeSnapshotAsync(configuration: configuration)
            guard let image = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw AppError.captureFailed("Snapshot returned an unsupported image format.")
            }

            slidePageData.append(
                SlidePageData(
                    image: image,
                    sourceSize: frame.rect.size,
                    links: frame.links
                )
            )
        }

        guard !slidePageData.isEmpty else {
            throw AppError.captureFailed("PDF export produced no pages.")
        }

        try writeA4LandscapePDF(from: slidePageData, outputPDFURL: outputPDFURL)
    }

    private func writeA4LandscapePDF(from pages: [SlidePageData], outputPDFURL: URL) throws {
        var mediaBox = Self.a4LandscapePageRect
        guard let context = CGContext(outputPDFURL as CFURL, mediaBox: &mediaBox, nil) else {
            throw AppError.captureFailed("Unable to create PDF context for export.")
        }

        for pageData in pages {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(mediaBox)
            context.interpolationQuality = .high

            let sourceRect = CGRect(origin: .zero, size: pageData.sourceSize)
            let scale = min(
                mediaBox.width / max(sourceRect.width, 1),
                mediaBox.height / max(sourceRect.height, 1)
            )
            let drawWidth = sourceRect.width * scale
            let drawHeight = sourceRect.height * scale
            let drawX = (mediaBox.width - drawWidth) / 2
            let drawY = (mediaBox.height - drawHeight) / 2
            let targetRect = CGRect(x: drawX, y: drawY, width: drawWidth, height: drawHeight)

            context.draw(pageData.image, in: targetRect)

            for link in pageData.links {
                let linkRect = CGRect(
                    x: drawX + (link.rect.minX * scale),
                    y: drawY + ((sourceRect.height - link.rect.maxY) * scale),
                    width: link.rect.width * scale,
                    height: link.rect.height * scale
                )
                let normalizedLinkRect = linkRect.standardized
                guard normalizedLinkRect.width > 0, normalizedLinkRect.height > 0 else {
                    continue
                }
                context.setURL(link.url as CFURL, for: normalizedLinkRect)
            }

            context.endPDFPage()
        }

        context.closePDF()
    }

    private func resolveSlideCount() async -> Int {
        let script = """
        (() => {
          const candidates = Array.from(document.querySelectorAll('.pdf-title-slide, .capture-row, main.page > .card'));
          const slides = candidates.filter((element) => {
            if (element.classList.contains('pdf-title-slide')) return true;
            if (element.classList.contains('capture-row')) return true;
            if (element.matches('main.page > .card') && !element.closest('.capture-row')) return true;
            return false;
          });

          const ordered = slides.map((element) => {
            const rect = element.getBoundingClientRect();
            return {
              element,
              top: rect.top + window.scrollY,
              left: rect.left + window.scrollX
            };
          }).sort((a, b) => (a.top - b.top) || (a.left - b.left));

          ordered.forEach((item, index) => {
            item.element.setAttribute('data-swift-pdf-slide-order', String(index));
          });

          return ordered.length;
        })();
        """

        guard let value = try? await webView.evaluateJavaScriptAsync(script) else {
            return 0
        }
        return (value as? NSNumber)?.intValue ?? 0
    }

    private func frameForSlide(at index: Int) async -> SlideFrame? {
        let script = """
        (() => {
          const element = document.querySelector('[data-swift-pdf-slide-order="\(index)"]');
          if (!element) return null;

          element.scrollIntoView({ block: 'start', inline: 'nearest' });
          const rect = element.getBoundingClientRect();
          const originX = Math.max(0, rect.left);
          const originY = Math.max(0, rect.top);

          const links = Array.from(element.querySelectorAll('.shot-link[href]')).map((anchor) => {
            const linkRect = anchor.getBoundingClientRect();
            return {
              x: Math.max(0, linkRect.left - originX),
              y: Math.max(0, linkRect.top - originY),
              width: Math.max(1, linkRect.width),
              height: Math.max(1, linkRect.height),
              url: String(anchor.href || '')
            };
          }).filter((link) => !!link.url);

          return {
            x: originX,
            y: originY,
            width: Math.max(1, rect.width),
            height: Math.max(1, rect.height),
            links
          };
        })();
        """

        guard let value = try? await webView.evaluateJavaScriptAsync(script) else {
            return nil
        }
        guard let raw = value as? [String: Any] else {
            return nil
        }

        try? await Task.sleep(nanoseconds: 120_000_000)
        return parseSlideFrame(raw)
    }

    private func parseSlideFrame(_ raw: [String: Any]) -> SlideFrame? {
        guard
            let x = (raw["x"] as? NSNumber)?.doubleValue,
            let y = (raw["y"] as? NSNumber)?.doubleValue,
            let width = (raw["width"] as? NSNumber)?.doubleValue,
            let height = (raw["height"] as? NSNumber)?.doubleValue
        else {
            return nil
        }

        let rect = CGRect(
            x: x,
            y: y,
            width: max(width, 1),
            height: max(height, 1)
        ).integral

        guard rect.width >= 1, rect.height >= 1 else {
            return nil
        }

        let links: [SlideLink]
        if let rawLinks = raw["links"] as? [[String: Any]] {
            links = rawLinks.compactMap { rawLink in
                guard
                    let urlString = rawLink["url"] as? String,
                    let url = URL(string: urlString),
                    let lx = (rawLink["x"] as? NSNumber)?.doubleValue,
                    let ly = (rawLink["y"] as? NSNumber)?.doubleValue,
                    let lwidth = (rawLink["width"] as? NSNumber)?.doubleValue,
                    let lheight = (rawLink["height"] as? NSNumber)?.doubleValue
                else {
                    return nil
                }

                let linkRect = CGRect(
                    x: max(lx, 0),
                    y: max(ly, 0),
                    width: max(lwidth, 1),
                    height: max(lheight, 1)
                ).integral

                guard linkRect.width > 0, linkRect.height > 0 else {
                    return nil
                }
                return SlideLink(url: url, rect: linkRect)
            }
        } else {
            links = []
        }

        return SlideFrame(rect: rect, links: links)
    }

    private func ensurePrintHierarchyReady(minimumContentSize: NSSize) {
        let stableSize = NSSize(
            width: max(minimumContentSize.width, 1),
            height: max(minimumContentSize.height, 1)
        )

        window.setContentSize(stableSize)
        window.orderFront(nil)

        if let contentView = window.contentView {
            contentView.frame = NSRect(origin: .zero, size: stableSize)
            contentView.layoutSubtreeIfNeeded()
            contentView.displayIfNeeded()
        }

        webView.frame = NSRect(origin: .zero, size: stableSize)
        webView.layoutSubtreeIfNeeded()
        webView.displayIfNeeded()
        window.displayIfNeeded()
    }

    private func preparePrintViewLayout() {
        let stableSize = NSSize(
            width: max(viewport.width, 100),
            height: max(viewport.height, 100)
        )

        window.setContentSize(stableSize)
        webView.frame = NSRect(origin: .zero, size: stableSize)
        webView.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func cleanup() {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        loadContinuation = nil
        webView.navigationDelegate = nil
        window.contentView = nil
        window.orderOut(nil)
        window.close()
    }

    private static func jsStringLiteral(_ value: String) -> String {
        guard
            let data = try? JSONEncoder().encode(value),
            let text = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return text
    }

    private static let printStylesheet = """
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
        image-rendering: -webkit-optimize-contrast !important;
      }
      .note {
        position: static !important;
        width: auto !important;
        margin: 0 !important;
      }
    }
    """

    private static let screenExportStylesheet = """
    body.swift-pdf-export-mode {
      margin: 0 !important;
      background: var(--bg) !important;
      color: var(--ink) !important;
    }
    body.swift-pdf-export-mode .toolbar,
    body.swift-pdf-export-mode h1 {
      display: none !important;
    }
    body.swift-pdf-export-mode .page {
      width: 297mm !important;
      max-width: 297mm !important;
      margin: 0 auto !important;
      padding: 0 !important;
    }
    body.swift-pdf-export-mode .pdf-title-slide {
      width: 297mm !important;
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
    body.swift-pdf-export-mode .pdf-title-slide h2 {
      margin: 0 !important;
      font-family: "Space Grotesk", "Helvetica Neue", sans-serif !important;
      font-size: 48px !important;
      line-height: 1.15 !important;
      letter-spacing: -0.02em !important;
      color: #1f2328 !important;
      max-width: 85% !important;
      word-break: break-word !important;
    }
    body.swift-pdf-export-mode .capture-row,
    body.swift-pdf-export-mode .card {
      break-inside: avoid !important;
      page-break-inside: avoid !important;
    }
    body.swift-pdf-export-mode .capture-row {
      width: 297mm !important;
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
    body.swift-pdf-export-mode .card {
      min-height: 0 !important;
      height: auto !important;
      margin: 0 !important;
      padding: 8mm !important;
      width: min(70%, 1350px) !important;
      flex: 0 0 min(70%, 1350px) !important;
      box-shadow: none !important;
    }
    body.swift-pdf-export-mode .capture-row .note {
      flex: 0 0 26% !important;
      max-width: 26% !important;
    }
    body.swift-pdf-export-mode main.page > .card {
      width: 297mm !important;
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
      box-sizing: border-box !important;
      box-shadow: none !important;
    }
    body.swift-pdf-export-mode main.page > .card:last-child,
    body.swift-pdf-export-mode .capture-row:last-child {
      break-after: auto !important;
      page-break-after: auto !important;
    }
    body.swift-pdf-export-mode .shot-block {
      max-width: 100% !important;
      margin: 0 !important;
    }
    body.swift-pdf-export-mode .shot {
      max-height: 56vh !important;
      width: 100% !important;
      object-fit: contain !important;
      image-rendering: -webkit-optimize-contrast !important;
    }
    body.swift-pdf-export-mode .note {
      position: static !important;
      width: auto !important;
      margin: 0 !important;
    }
    """
}
