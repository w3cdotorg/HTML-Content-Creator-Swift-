import AppKit
import Foundation
import PDFKit
import WebKit

enum WebKitCaptureEngine {
    static let viewport = CGSize(width: 1920, height: 1080)

    @MainActor
    static func capture(url: URL, contentBlockingEnabled: Bool = true) async throws -> Data {
        let session = WebKitCaptureSession(
            viewport: viewport,
            contentBlockingEnabled: contentBlockingEnabled
        )
        return try await session.capture(url: url)
    }
}

private final class CaptureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class WebKitCaptureSession: NSObject, WKNavigationDelegate {
    private struct DOMSnapshotState {
        let ready: Bool
        let nodes: Int
        let textLength: Int
        let interactiveCount: Int
        let mediaCount: Int
        let headingCount: Int

        var isMeaningful: Bool {
            guard ready else { return false }
            if nodes >= 60 { return true }
            if textLength >= 180 { return true }
            if interactiveCount >= 10 { return true }
            if mediaCount >= 6 { return true }
            if headingCount >= 1 && textLength >= 40 { return true }
            return false
        }
    }

    private let viewport: CGSize
    private let webView: WKWebView
    private let window: CaptureWindow
    private let contentBlockingEnabled: Bool

    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var loadTimeoutTask: Task<Void, Never>?
    private var loadDOMReadyFallbackTask: Task<Void, Never>?
    private var navigationDidStart = false
    private var navigationDidCommit = false
    private var contentRuleListInstalled = false

    init(viewport: CGSize, contentBlockingEnabled: Bool) {
        self.viewport = viewport
        self.contentBlockingEnabled = contentBlockingEnabled

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.suppressesIncrementalRendering = false

        self.webView = WKWebView(frame: CGRect(origin: .zero, size: viewport), configuration: config)
        self.webView.customUserAgent = Self.desktopSafariUserAgent
        self.window = CaptureWindow(
            contentRect: CGRect(origin: .zero, size: viewport),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init()

        webView.navigationDelegate = self

        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.contentView = webView
        window.setFrameOrigin(NSPoint(x: 24, y: 24))
        window.makeKeyAndOrderFront(nil)
    }

    deinit {
        loadTimeoutTask?.cancel()
        loadDOMReadyFallbackTask?.cancel()
    }

    func capture(url: URL) async throws -> Data {
        defer {
            cleanup()
        }

        await prepareContentBlocking()

        let strictMode = shouldUseStrictCapturePath(for: url)
        webView.customUserAgent = strictMode ? nil : Self.desktopSafariUserAgent
        try await loadPage(
            url: url,
            timeoutSeconds: strictMode ? 70 : 90,
            allowCommitFallback: strictMode,
            commitFallbackDelaySeconds: strictMode ? 22 : 8
        )

        if strictMode {
            AppLogger.capture.debug("Using strict capture mode for host: \(url.host ?? "<unknown>")")
            try await Task.sleep(nanoseconds: 3_000_000_000)
            await dismissCookieBannersForStrictHost(url: url, maxAttempts: 2, pauseNanoseconds: 500_000_000)
            await waitForHostSpecificReadiness(url: url, timeoutSeconds: 8)

            var image = try await captureSnapshot(strictMode: true)
            if isLikelyBlankCapture(image) {
                AppLogger.capture.debug("Strict mode produced a blank snapshot, retrying after visible render pass.")
                await dismissCookieBannersForStrictHost(url: url, maxAttempts: 1, pauseNanoseconds: 350_000_000)
                try await forceVisibleRenderPass()
                image = try await captureSnapshot(strictMode: true)
            }

            guard let pngData = image.pngData else {
                throw AppError.captureFailed("Unable to convert snapshot to PNG.")
            }
            return pngData
        }

        try await Task.sleep(nanoseconds: 2_000_000_000)
        await dismissCookieBanners(maxAttempts: 10, pauseNanoseconds: 280_000_000)
        await dismissWordPressCookieBanners(url: url, maxAttempts: 5, pauseNanoseconds: 320_000_000)
        await dismissLeMondeAdSlots(url: url, maxAttempts: 4, pauseNanoseconds: 280_000_000)
        try await Task.sleep(nanoseconds: 300_000_000)
        await ensureDocumentVisibilitySignals()
        await kickDynamicRendering(aggressive: false)
        if shouldUseAggressiveHydrationKick(for: url) {
            await kickDynamicRendering(aggressive: true)
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        await waitForMeaningfulDOMContent(timeoutSeconds: 6)

        var domState = await readDOMSnapshotState()
        AppLogger.capture.debug(
            "DOM before snapshot (nodes=\(domState.nodes), text=\(domState.textLength), interactive=\(domState.interactiveCount), media=\(domState.mediaCount), headings=\(domState.headingCount))."
        )
        if !domState.isMeaningful {
            AppLogger.capture.debug(
                "DOM still sparse before snapshot (nodes=\(domState.nodes), text=\(domState.textLength)); forcing visible render pass."
            )
            try await forceVisibleRenderPass()
            await ensureDocumentVisibilitySignals()
            await kickDynamicRendering(aggressive: true)
            await waitForMeaningfulDOMContent(timeoutSeconds: 6)
            domState = await readDOMSnapshotState()
            AppLogger.capture.debug(
                "DOM after visible pass (nodes=\(domState.nodes), text=\(domState.textLength), interactive=\(domState.interactiveCount))."
            )
        }

        await dismissCookieBanners(maxAttempts: 4, pauseNanoseconds: 220_000_000)
        await dismissWordPressCookieBanners(url: url, maxAttempts: 2, pauseNanoseconds: 260_000_000)
        await dismissLeMondeAdSlots(url: url, maxAttempts: 2, pauseNanoseconds: 220_000_000)

        var image = try await captureSnapshot()

        // Some GPU-heavy sites can render a black/transparent frame when snapshotted
        // while the backing window is hidden. Retry once with an explicit visible pass.
        if isLikelyBlankCapture(image) {
            AppLogger.capture.debug("Detected likely blank snapshot, retrying with forced visible render pass.")
            try await forceVisibleRenderPass()
            image = try await captureSnapshot()
        }

        guard let pngData = image.pngData else {
            throw AppError.captureFailed("Unable to convert snapshot to PNG.")
        }
        return pngData
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        AppLogger.capture.debug("Navigation didFinish for: \(webView.url?.absoluteString ?? "<unknown>")")
        resolveLoad(.success(()))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationDidStart = true
        AppLogger.capture.debug("Navigation didStartProvisional for: \(webView.url?.absoluteString ?? "<unknown>")")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        AppLogger.capture.debug("Navigation didCommit for: \(webView.url?.absoluteString ?? "<unknown>")")
        navigationDidCommit = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if isBenignNavigationError(error) {
            AppLogger.capture.debug("Navigation didFail ignored: \(error.localizedDescription)")
            return
        }
        AppLogger.capture.error("Navigation didFail: \(error.localizedDescription)")
        resolveLoad(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if isBenignNavigationError(error) {
            AppLogger.capture.debug("Navigation didFailProvisional ignored: \(error.localizedDescription)")
            return
        }
        AppLogger.capture.error("Navigation didFailProvisional: \(error.localizedDescription)")
        resolveLoad(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        AppLogger.capture.error("Web content process terminated during navigation.")
        resolveLoad(.failure(AppError.captureFailed("Web content process terminated during capture.")))
    }

    private func isBenignNavigationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }
        return false
    }

    private func loadPage(
        url: URL,
        timeoutSeconds: UInt64,
        allowCommitFallback: Bool,
        commitFallbackDelaySeconds: TimeInterval
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            navigationDidStart = false
            navigationDidCommit = false
            loadContinuation = continuation

            loadTimeoutTask?.cancel()
            loadTimeoutTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                guard self.loadContinuation != nil else { return }
                let readyForFallback = await self.isReadyForCaptureFallback()
                let hasDOM = await self.hasAnyDOMContent()
                let hasCommittedNavigation = self.navigationDidCommit || self.navigationDidStart || self.webView.url != nil
                if hasCommittedNavigation || readyForFallback || hasDOM || self.webView.estimatedProgress > 0.55 {
                    AppLogger.capture.debug(
                        "Navigation timeout reached after \(timeoutSeconds)s, but navigation has progressed; continuing capture."
                    )
                    self.webView.stopLoading()
                    self.resolveLoad(.success(()))
                    return
                }
                self.webView.stopLoading()
                self.resolveLoad(.failure(AppError.captureFailed("Navigation timeout after \(timeoutSeconds)s.")))
            }

            loadDOMReadyFallbackTask?.cancel()
            loadDOMReadyFallbackTask = Task { [weak self] in
                guard let self else { return }
                let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
                let fallbackStartDate = Date()

                // Wait for initial redirects and app bootstrapping.
                try? await Task.sleep(nanoseconds: 4_000_000_000)

                while !Task.isCancelled, Date() < deadline {
                    guard self.loadContinuation != nil else { return }
                    let hasNavigationSignal =
                        self.navigationDidStart ||
                        self.navigationDidCommit ||
                        self.webView.url != nil ||
                        self.webView.estimatedProgress > 0.01
                    guard hasNavigationSignal else {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        continue
                    }

                    if allowCommitFallback, self.navigationDidCommit {
                        let elapsed = Date().timeIntervalSince(fallbackStartDate)
                        if elapsed >= commitFallbackDelaySeconds {
                            AppLogger.capture.debug("Proceeding with commit fallback before didFinish.")
                            self.resolveLoad(.success(()))
                            return
                        }
                    }

                    if await self.isReadyForCaptureFallback() {
                        AppLogger.capture.debug("Proceeding with DOM-ready fallback before didFinish.")
                        self.resolveLoad(.success(()))
                        return
                    }

                    try? await Task.sleep(nanoseconds: 450_000_000)
                }
            }

            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = TimeInterval(timeoutSeconds)
            webView.load(request)
        }
    }

    private func resolveLoad(_ result: Result<Void, Error>) {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        loadDOMReadyFallbackTask?.cancel()
        loadDOMReadyFallbackTask = nil

        guard let continuation = loadContinuation else { return }
        loadContinuation = nil

        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func isReadyForCaptureFallback() async -> Bool {
        let state = await readDOMSnapshotState()
        if state.isMeaningful {
            return true
        }

        if !state.ready {
            return false
        }

        if state.nodes >= 8 {
            return true
        }
        if state.textLength >= 20 {
            return true
        }
        if state.mediaCount >= 1 {
            return true
        }
        if state.headingCount >= 1 {
            return true
        }
        if webView.estimatedProgress >= 0.92 {
            return true
        }
        return false
    }

    private func hasAnyDOMContent() async -> Bool {
        let state = await readDOMSnapshotState()
        return state.ready && (state.nodes > 0 || state.textLength > 0 || state.mediaCount > 0 || state.headingCount > 0)
    }

    private func dismissCookieBanners(maxAttempts: Int, pauseNanoseconds: UInt64) async {
        guard maxAttempts > 0 else { return }

        var totalClicked = 0
        var totalSuppressed = 0
        var consecutiveFailures = 0
        for _ in 0..<maxAttempts {
            let result = (try? await webView.evaluateJavaScriptAsync(
                Self.cookieDismissScript,
                timeoutNanoseconds: 2_000_000_000
            )) as? [String: Any]
            if let result {
                consecutiveFailures = 0
                let clicked = intValue(result, "clicked")
                let suppressed = intValue(result, "suppressed")
                totalClicked += clicked
                totalSuppressed += suppressed
            } else {
                consecutiveFailures += 1
                if consecutiveFailures >= 2 {
                    AppLogger.capture.debug("Cookie cleanup stopped early after repeated JS evaluation failures.")
                    break
                }
            }
            try? await Task.sleep(nanoseconds: pauseNanoseconds)
        }

        if totalClicked > 0 || totalSuppressed > 0 {
            AppLogger.capture.debug("Cookie cleanup: clicked=\(totalClicked), suppressed=\(totalSuppressed)")
        }
    }

    private func captureSnapshot(strictMode: Bool = false) async throws -> NSImage {
        if strictMode {
            let strict = WKSnapshotConfiguration()
            strict.rect = CGRect(origin: .zero, size: viewport)
            strict.afterScreenUpdates = false

            var candidates: [NSImage] = []

            do {
                let snapshot = try await webView.takeSnapshotAsync(
                    configuration: strict,
                    timeoutNanoseconds: 10_000_000_000
                )
                if !isLikelyLowDetailCapture(snapshot) {
                    AppLogger.capture.debug("Strict mode snapshot capture succeeded.")
                    return snapshot
                }
                AppLogger.capture.debug("Strict mode snapshot is low-detail; trying fallbacks.")
                candidates.append(snapshot)
            } catch {
                AppLogger.capture.debug("Strict snapshot failed (\(error.localizedDescription)). Trying PDF-first fallback.")
            }

            if let bitmapFallback = await captureBitmapFallbackAfterVisiblePass(), !isLikelyBlankCapture(bitmapFallback) {
                if !isLikelyLowDetailCapture(bitmapFallback) {
                    AppLogger.capture.debug("Strict mode bitmap fallback capture succeeded.")
                    return bitmapFallback
                }
                AppLogger.capture.debug("Strict mode bitmap fallback is low-detail.")
                candidates.append(bitmapFallback)
            }

            if let pdfFallback = await capturePDFFallbackImage(timeoutNanoseconds: 24_000_000_000) {
                if !isLikelyLowDetailCapture(pdfFallback) {
                    AppLogger.capture.debug("Strict mode PDF fallback capture succeeded.")
                    return pdfFallback
                }
                AppLogger.capture.debug("Strict mode PDF fallback is low-detail.")
                candidates.append(pdfFallback)
            }

            if let best = candidates.max(by: { detailScore(for: $0) < detailScore(for: $1) }) {
                AppLogger.capture.debug("Strict mode returned best available low-detail candidate.")
                return best
            }

            throw AppError.captureFailed("Snapshot timed out.")
        }

        let primary = WKSnapshotConfiguration()
        primary.rect = CGRect(origin: .zero, size: viewport)
        primary.afterScreenUpdates = true

        do {
            return try await webView.takeSnapshotAsync(
                configuration: primary,
                timeoutNanoseconds: 10_000_000_000
            )
        } catch {
            AppLogger.capture.debug("Primary snapshot failed (\(error.localizedDescription)). Retrying without screen-update wait.")
        }

        let secondary = WKSnapshotConfiguration()
        secondary.rect = CGRect(origin: .zero, size: viewport)
        secondary.afterScreenUpdates = false

        do {
            return try await webView.takeSnapshotAsync(
                configuration: secondary,
                timeoutNanoseconds: 8_000_000_000
            )
        } catch {
            AppLogger.capture.debug("Secondary snapshot failed (\(error.localizedDescription)). Falling back to bitmap capture.")
        }

        if let fallback = await captureBitmapFallbackAfterVisiblePass() {
            AppLogger.capture.debug("Bitmap fallback capture succeeded.")
            return fallback
        }

        if let pdfFallback = await capturePDFFallbackImage() {
            AppLogger.capture.debug("PDF fallback capture succeeded.")
            return pdfFallback
        }

        throw AppError.captureFailed("Snapshot timed out.")
    }

    private func forceVisibleRenderPass() async throws {
        window.isOpaque = true
        window.alphaValue = 0.3
        window.backgroundColor = .white
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        webView.layoutSubtreeIfNeeded()
        webView.displayIfNeeded()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        window.alphaValue = 0.01
        window.isOpaque = false
        window.backgroundColor = .clear
    }

    private func captureBitmapFallbackAfterVisiblePass() async -> NSImage? {
        window.isOpaque = true
        window.alphaValue = 0.35
        window.backgroundColor = .white
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        webView.layoutSubtreeIfNeeded()
        webView.displayIfNeeded()
        try? await Task.sleep(nanoseconds: 1_100_000_000)

        let windowImage = captureWindowBitmap()
        let viewImage = captureViewBitmap()

        window.alphaValue = 0.01
        window.isOpaque = false
        window.backgroundColor = .clear

        if let viewImage, !isLikelyBlankCapture(viewImage) {
            return viewImage
        }
        if let windowImage, !isLikelyBlankCapture(windowImage) {
            return windowImage
        }

        return viewImage ?? windowImage
    }

    private func captureWindowBitmap() -> NSImage? {
        let windowID = CGWindowID(window.windowNumber)
        guard windowID != 0 else { return nil }
        guard
            let cgImage = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                windowID,
                [.boundsIgnoreFraming, .bestResolution]
            )
        else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: viewport)
    }

    private func captureViewBitmap() -> NSImage? {
        let bounds = webView.bounds.integral
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        webView.layoutSubtreeIfNeeded()
        webView.displayIfNeeded()
        guard let rep = webView.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        webView.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private func capturePDFFallbackImage(timeoutNanoseconds: UInt64 = 18_000_000_000) async -> NSImage? {
        let pdfConfig = WKPDFConfiguration()
        pdfConfig.rect = CGRect(origin: .zero, size: viewport)

        guard
            let pdfData = try? await webView.createPDFAsync(
                configuration: pdfConfig,
                timeoutNanoseconds: timeoutNanoseconds
            ),
            let document = PDFDocument(data: pdfData),
            let page = document.page(at: 0)
        else {
            return nil
        }

        let mediaBounds = page.bounds(for: .mediaBox)
        guard mediaBounds.width > 1, mediaBounds.height > 1 else { return nil }

        let image = NSImage(size: viewport)
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else { return nil }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: viewport))

        let scale = min(viewport.width / mediaBounds.width, viewport.height / mediaBounds.height)
        let drawWidth = mediaBounds.width * scale
        let drawHeight = mediaBounds.height * scale
        let offsetX = (viewport.width - drawWidth) / 2
        let offsetY = (viewport.height - drawHeight) / 2

        context.saveGState()
        context.translateBy(x: offsetX, y: offsetY)
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        if isLikelyBlankCapture(image) {
            return nil
        }
        return image
    }

    private func waitForMeaningfulDOMContent(timeoutSeconds: UInt64) async {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            let state = await readDOMSnapshotState()
            if state.isMeaningful {
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private func readDOMSnapshotState() async -> DOMSnapshotState {
        guard
            let raw = (try? await webView.evaluateJavaScriptAsync(
                Self.domSnapshotStateScript,
                timeoutNanoseconds: 1_800_000_000
            )) as? [String: Any]
        else {
            return DOMSnapshotState(
                ready: false,
                nodes: 0,
                textLength: 0,
                interactiveCount: 0,
                mediaCount: 0,
                headingCount: 0
            )
        }

        return DOMSnapshotState(
            ready: boolValue(raw, "ready"),
            nodes: intValue(raw, "nodes"),
            textLength: intValue(raw, "text"),
            interactiveCount: intValue(raw, "interactive"),
            mediaCount: intValue(raw, "media"),
            headingCount: intValue(raw, "heading")
        )
    }

    private func ensureDocumentVisibilitySignals() async {
        _ = try? await webView.evaluateJavaScriptAsync(Self.forceDocumentVisibleScript)
    }

    private func kickDynamicRendering(aggressive: Bool) async {
        _ = try? await webView.evaluateJavaScriptAsync(Self.dynamicRenderingKickScript)
        guard aggressive else { return }
        _ = try? await webView.evaluateJavaScriptAsync(Self.aggressiveRevealScript)
    }

    private func shouldUseAggressiveHydrationKick(for url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "openclaw.ai" || host.hasSuffix(".openclaw.ai")
    }

    private func shouldUseStrictCapturePath(for url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "nytimes.com" || host.hasSuffix(".nytimes.com")
    }

    private func shouldUseWordPressCookieCleanup(for url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "wordpress.com" || host.hasSuffix(".wordpress.com")
    }

    private func shouldUseLeMondeAdCleanup(for url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "lemonde.fr" || host.hasSuffix(".lemonde.fr")
    }

    private func dismissWordPressCookieBanners(url: URL, maxAttempts: Int, pauseNanoseconds: UInt64) async {
        guard shouldUseWordPressCookieCleanup(for: url), maxAttempts > 0 else { return }
        var clicked = 0
        var suppressed = 0
        for _ in 0..<maxAttempts {
            let result = (try? await webView.evaluateJavaScriptAsync(
                Self.wordPressCookieDismissScript,
                timeoutNanoseconds: 1_600_000_000
            )) as? [String: Any]
            clicked += intValue(result ?? [:], "clicked")
            suppressed += intValue(result ?? [:], "suppressed")
            try? await Task.sleep(nanoseconds: pauseNanoseconds)
        }
        AppLogger.capture.debug("WordPress cookie cleanup: clicked=\(clicked), suppressed=\(suppressed)")
    }

    private func dismissLeMondeAdSlots(url: URL, maxAttempts: Int, pauseNanoseconds: UInt64) async {
        guard shouldUseLeMondeAdCleanup(for: url), maxAttempts > 0 else { return }
        var suppressed = 0
        for _ in 0..<maxAttempts {
            let result = (try? await webView.evaluateJavaScriptAsync(
                Self.leMondeAdCleanupScript,
                timeoutNanoseconds: 1_500_000_000
            )) as? [String: Any]
            suppressed += intValue(result ?? [:], "suppressed")
            try? await Task.sleep(nanoseconds: pauseNanoseconds)
        }
        AppLogger.capture.debug("LeMonde ad cleanup: suppressed=\(suppressed)")
    }

    private func dismissCookieBannersForStrictHost(url: URL, maxAttempts: Int, pauseNanoseconds: UInt64) async {
        guard shouldUseStrictCapturePath(for: url), maxAttempts > 0 else { return }
        var dismissed = 0
        for _ in 0..<maxAttempts {
            let result = (try? await webView.evaluateJavaScriptAsync(
                Self.nyTimesLightweightCleanupScript,
                timeoutNanoseconds: 1_200_000_000
            )) as? [String: Any]
            dismissed += intValue(result ?? [:], "dismissed")
            try? await Task.sleep(nanoseconds: pauseNanoseconds)
        }
        if dismissed > 0 {
            AppLogger.capture.debug("Strict host cleanup: dismissed=\(dismissed)")
        }
    }

    private func waitForHostSpecificReadiness(url: URL, timeoutSeconds: UInt64) async {
        guard shouldUseStrictCapturePath(for: url) else { return }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            let result = (try? await webView.evaluateJavaScriptAsync(
                Self.nyTimesReadinessScript,
                timeoutNanoseconds: 1_200_000_000
            )) as? [String: Any]

            let ready = boolValue(result ?? [:], "ready")
            let text = intValue(result ?? [:], "text")
            let articleLike = intValue(result ?? [:], "articleLike")
            let articleText = intValue(result ?? [:], "articleText")
            let cookieLike = intValue(result ?? [:], "cookieLike")
            let gatewayLike = intValue(result ?? [:], "gatewayLike")

            if ready && articleLike >= 1 && articleText >= 220 && cookieLike == 0 {
                return
            }
            if ready && text >= 1200 && gatewayLike == 0 && cookieLike == 0 {
                return
            }

            try? await Task.sleep(nanoseconds: 350_000_000)
        }
    }

    private func intValue(_ dictionary: [String: Any], _ key: String) -> Int {
        if let value = dictionary[key] as? Int {
            return value
        }
        if let value = dictionary[key] as? NSNumber {
            return value.intValue
        }
        return 0
    }

    private func boolValue(_ dictionary: [String: Any], _ key: String) -> Bool {
        if let value = dictionary[key] as? Bool {
            return value
        }
        if let value = dictionary[key] as? NSNumber {
            return value.boolValue
        }
        return false
    }

    private func isLikelyBlankCapture(_ image: NSImage) -> Bool {
        guard let metrics = imageMetrics(for: image) else { return false }
        if metrics.sampleCount == 0 {
            return false
        }
        if metrics.opaqueRatio < 0.02 {
            return true
        }
        return metrics.maxLuminance < 0.04 && metrics.brightRatio < 0.002
    }

    private func isLikelyLowDetailCapture(_ image: NSImage) -> Bool {
        guard let metrics = imageMetrics(for: image), metrics.sampleCount > 0 else { return false }

        if metrics.opaqueRatio < 0.02 {
            return true
        }

        // Very flat frames (all-white / all-gray / all-black) are typically failed captures.
        if metrics.luminanceVariance < 0.00035 {
            return true
        }

        if metrics.brightRatio > 0.99 && metrics.luminanceVariance < 0.0015 {
            return true
        }

        if metrics.darkRatio > 0.99 && metrics.luminanceVariance < 0.0015 {
            return true
        }

        return false
    }

    private func detailScore(for image: NSImage) -> CGFloat {
        guard let metrics = imageMetrics(for: image), metrics.sampleCount > 0 else { return -1 }
        return (metrics.luminanceVariance * 1000) + (metrics.midToneRatio * 0.25)
    }

    private struct ImageMetrics {
        let sampleCount: Int
        let opaqueRatio: CGFloat
        let brightRatio: CGFloat
        let darkRatio: CGFloat
        let midToneRatio: CGFloat
        let maxLuminance: CGFloat
        let luminanceVariance: CGFloat
    }

    private func imageMetrics(for image: NSImage) -> ImageMetrics? {
        guard
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0 else {
            return ImageMetrics(
                sampleCount: 0,
                opaqueRatio: 0,
                brightRatio: 0,
                darkRatio: 0,
                midToneRatio: 0,
                maxLuminance: 0,
                luminanceVariance: 0
            )
        }

        let sampleStep = max(1, min(width, height) / 120)
        var sampleCount = 0
        var opaqueCount = 0
        var brightCount = 0
        var darkCount = 0
        var midToneCount = 0
        var maxLuminance: CGFloat = 0
        var sum: CGFloat = 0
        var sumSquares: CGFloat = 0

        for y in stride(from: 0, to: height, by: sampleStep) {
            for x in stride(from: 0, to: width, by: sampleStep) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }

                sampleCount += 1
                if color.alphaComponent > 0.02 {
                    opaqueCount += 1
                }

                let luminance =
                    (0.2126 * color.redComponent) +
                    (0.7152 * color.greenComponent) +
                    (0.0722 * color.blueComponent)
                sum += luminance
                sumSquares += luminance * luminance
                maxLuminance = max(maxLuminance, luminance)
                if luminance > 0.08 {
                    brightCount += 1
                }
                if luminance < 0.06 {
                    darkCount += 1
                }
                if luminance > 0.20 && luminance < 0.85 {
                    midToneCount += 1
                }
            }
        }

        guard sampleCount > 0 else {
            return ImageMetrics(
                sampleCount: 0,
                opaqueRatio: 0,
                brightRatio: 0,
                darkRatio: 0,
                midToneRatio: 0,
                maxLuminance: 0,
                luminanceVariance: 0
            )
        }

        let opaqueRatio = CGFloat(opaqueCount) / CGFloat(sampleCount)
        let brightRatio = CGFloat(brightCount) / CGFloat(sampleCount)
        let darkRatio = CGFloat(darkCount) / CGFloat(sampleCount)
        let midToneRatio = CGFloat(midToneCount) / CGFloat(sampleCount)
        let mean = sum / CGFloat(sampleCount)
        let variance = max(0, (sumSquares / CGFloat(sampleCount)) - (mean * mean))

        return ImageMetrics(
            sampleCount: sampleCount,
            opaqueRatio: opaqueRatio,
            brightRatio: brightRatio,
            darkRatio: darkRatio,
            midToneRatio: midToneRatio,
            maxLuminance: maxLuminance,
            luminanceVariance: variance
        )
    }

    private func installContentRuleListIfNeeded() async {
        guard !contentRuleListInstalled else { return }
        contentRuleListInstalled = true

        guard let ruleList = await CaptureContentRuleListProvider.loadRuleList() else {
            AppLogger.capture.debug("WKContentRuleList unavailable; continuing with JS-only cleanup.")
            return
        }

        webView.configuration.userContentController.add(ruleList)
        AppLogger.capture.debug("WKContentRuleList enabled (rules=\(CaptureContentRuleListProvider.ruleCount)).")
    }

    private func prepareContentBlocking() async {
        guard contentBlockingEnabled else {
            AppLogger.capture.debug("WKContentRuleList disabled for this capture.")
            return
        }
        await installContentRuleListIfNeeded()
    }

    private func cleanup() {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        loadDOMReadyFallbackTask?.cancel()
        loadDOMReadyFallbackTask = nil
        loadContinuation = nil
        webView.navigationDelegate = nil
        window.contentView = nil
        window.orderOut(nil)
        window.close()
    }

    private static let cookieDismissScript = """
    (() => {
      const ACCEPT_TERMS = [
        "accept", "accept all", "accept cookies", "allow all", "allow cookies", "agree", "i agree",
        "accept and close", "accept all cookies", "allow and close", "i accept cookies", "yes, i agree",
        "ok", "got it", "continue",
        "accepter", "tout accepter", "j'accepte", "autoriser", "continuer", "d'accord"
      ];
      const REJECT_TERMS = [
        "reject", "refuse", "decline", "deny", "disagree", "no thanks",
        "reject all", "refuser", "tout refuser", "je refuse",
        "reject non-essential",
        "settings", "manage", "preferences", "customize", "parametres", "préférences", "personnaliser"
      ];
      const KNOWN_ACCEPT_SELECTORS = [
        "#onetrust-accept-btn-handler",
        "button#onetrust-accept-btn-handler",
        "#didomi-notice-agree-button",
        "button#didomi-notice-agree-button",
        "#didomi-notice-disagree-button",
        "button#didomi-notice-disagree-button",
        "button.sp_choice_type_11",
        "button[title*='Accept all']",
        "button[title*='Tout accepter']",
        "button[title*='Accept']",
        "button[aria-label*='Accept']",
        "button[aria-label*='accept']",
        "button[aria-label*='Accepter']",
        "button[aria-label*='Tout accepter']",
        "button[aria-label*='Tout refuser']",
        "[data-testid*='accept']",
        "[id*='accept' i][role='button']",
        ".qc-cmp2-summary-buttons button[mode='primary']",
        "#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll",
        "#cn-accept-cookie",
        ".cn-set-cookie",
        ".cookie-notice-accept",
        "#cookie_action_close_header",
        "[data-action*='accept']",
        "#truste-consent-button",
        "#eu-cookie-law .accept",
        "#eu-cookie-law button",
        ".widget_eu_cookie_law_widget .accept",
        ".widget_eu_cookie_law_widget button",
        ".cli-bar-btn_container .cli_action_button",
        ".cli-bar-btn_container .cli_accept_all_button",
        ".cky-btn-accept",
        "#cky-btn-accept",
        ".cmplz-btn.cmplz-accept",
        ".moove-gdpr-infobar-allow-all"
      ];
      const KNOWN_BANNER_SELECTORS = [
        "#onetrust-banner-sdk",
        ".onetrust-pc-dark-filter",
        ".onetrust-pc-sdk",
        "#didomi-host",
        ".didomi-popup-container",
        ".didomi-popup-backdrop",
        ".didomi-components-container",
        "[id^='sp_message_container_']",
        "[id^='sp_message_iframe_']",
        "iframe[src*='sourcepoint']",
        ".sp_message_container",
        "[id^='sp_veil_']",
        ".sp_veil",
        ".qc-cmp2-container",
        ".qc-cmp2-ui",
        "#cookie-notice",
        ".cookie-notice-container",
        "#cookies-banner",
        "#cookie-law-info-bar",
        ".cn-overlay",
        ".cn-cookie-bar",
        ".cookiebanner",
        ".fc-consent-root",
        "#eu-cookie-law",
        ".widget_eu_cookie_law_widget",
        ".cli-modal-backdrop",
        ".cli-bar-container",
        ".cky-consent-container",
        ".cky-banner-element",
        ".cmplz-cookiebanner-container",
        ".cmplz-cookiebanner",
        ".moove-gdpr-cookie-notice"
      ];
      const COOKIE_CONTEXT_TERMS = [
        "cookie",
        "cookies",
        "consent",
        "consentement",
        "privacy",
        "confidentialite",
        "confidentialité",
        "rgpd",
        "gdpr",
        "tcf",
        "cookie policy",
        "cookies and similar",
        "we use cookies",
        "manage privacy preferences"
      ];

      let clicked = 0;
      let suppressed = 0;

      const normalize = (value) => (value || "")
        .toLowerCase()
        .replace(/\\u00a0/g, " ")
        .replace(/[!"#$%&'()*+,\\-./:;<=>?@[\\\\\\]^_`{|}~]/g, " ")
        .replace(/\\s+/g, " ")
        .trim();

      const isVisible = (el) => {
        if (!(el instanceof Element)) return false;
        const style = getComputedStyle(el);
        if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity || "1") < 0.05) return false;
        const rect = el.getBoundingClientRect();
        return rect.width > 2 && rect.height > 2;
      };

      const isDisabled = (el) => {
        if (!(el instanceof HTMLElement)) return false;
        return !!el.getAttribute("disabled") || el.getAttribute("aria-disabled") === "true";
      };

      const clickElement = (el) => {
        if (!(el instanceof HTMLElement)) return false;
        if (!isVisible(el) || isDisabled(el)) return false;
        try {
          el.click();
          el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, view: window }));
          return true;
        } catch (err) {
          return false;
        }
      };

      const readLabel = (el) => normalize(
        el.innerText ||
        el.textContent ||
        el.getAttribute("aria-label") ||
        el.getAttribute("title") ||
        el.getAttribute("value") ||
        ""
      );

      const hasAny = (text, values) => values.some((value) => text === value || text.startsWith(value + " ") || text.endsWith(" " + value) || text.includes(" " + value + " "));
      const looksAccept = (text) => hasAny(text, ACCEPT_TERMS) || text.includes("accept all") || text.includes("tout accepter");
      const looksReject = (text) => hasAny(text, REJECT_TERMS);
      const hasCookieContext = (text) => COOKIE_CONTEXT_TERMS.some((term) => text.includes(term));
      const getOverlayText = (el) => normalize(
        (el instanceof HTMLElement ? (el.innerText || el.textContent || "") : "") +
        " " +
        (el instanceof Element ? (el.getAttribute("id") || "") : "") +
        " " +
        (el instanceof Element ? (el.getAttribute("class") || "") : "") +
        " " +
        (el instanceof Element ? (el.getAttribute("aria-label") || "") : "")
      );

      const docs = new Set([document]);
      const roots = new Set([document]);
      const docStack = [document];
      while (docStack.length) {
        const currentDoc = docStack.pop();
        const rootStack = [currentDoc];
        while (rootStack.length) {
          const root = rootStack.pop();
          roots.add(root);
          let allElements = [];
          try {
            allElements = Array.from(root.querySelectorAll("*"));
          } catch (err) {}
          for (const el of allElements) {
            if (!(el instanceof Element)) continue;
            const anyEl = el;
            if (anyEl.shadowRoot && !roots.has(anyEl.shadowRoot)) {
              roots.add(anyEl.shadowRoot);
              rootStack.push(anyEl.shadowRoot);
            }
            if (el.tagName === "IFRAME") {
              try {
                if (el.contentDocument && !docs.has(el.contentDocument)) {
                  docs.add(el.contentDocument);
                  docStack.push(el.contentDocument);
                  if (!roots.has(el.contentDocument)) {
                    roots.add(el.contentDocument);
                  }
                }
              } catch (err) {}
            }
          }
        }
      }

      for (const root of roots) {
        for (const selector of KNOWN_ACCEPT_SELECTORS) {
          let nodes = [];
          try { nodes = Array.from(root.querySelectorAll(selector)); } catch (err) {}
          for (const node of nodes) {
            if (clickElement(node)) clicked++;
          }
        }
      }

      for (const root of roots) {
        let candidates = [];
        try {
          candidates = Array.from(root.querySelectorAll("button, [role='button'], input[type='button'], input[type='submit'], a, span[role='button'], div[role='button']"));
        } catch (err) {}
        for (const el of candidates) {
          const label = readLabel(el);
          if (!label) continue;
          if (!looksAccept(label) || looksReject(label)) continue;
          if (clickElement(el)) clicked++;
        }
      }

      const hideNode = (node) => {
        if (!(node instanceof HTMLElement)) return false;
        try {
          node.style.setProperty("display", "none", "important");
          node.style.setProperty("visibility", "hidden", "important");
          node.style.setProperty("opacity", "0", "important");
          node.style.setProperty("pointer-events", "none", "important");
          if (node.parentElement) {
            node.remove();
          }
          return true;
        } catch (err) {
          return false;
        }
      };

      for (const root of roots) {
        for (const selector of KNOWN_BANNER_SELECTORS) {
          let nodes = [];
          try { nodes = Array.from(root.querySelectorAll(selector)); } catch (err) {}
          for (const node of nodes) {
            if (hideNode(node)) suppressed++;
          }
        }

        let genericNodes = [];
        try {
          genericNodes = Array.from(
            root.querySelectorAll(
              "[id*='cookie' i], [class*='cookie' i], [id*='consent' i], [class*='consent' i], [id*='didomi' i], [class*='didomi' i], [id*='onetrust' i], [class*='onetrust' i], [id*='sp_message' i], [class*='sp_message' i], [id*='qc-cmp' i], [class*='qc-cmp' i]"
            )
          );
        } catch (err) {}

        for (const node of genericNodes) {
          if (!(node instanceof HTMLElement)) continue;
          const style = getComputedStyle(node);
          const rect = node.getBoundingClientRect();
          const overlayLike =
            (style.position === "fixed" || style.position === "sticky" || style.zIndex === "2147483647") &&
            rect.width * rect.height > window.innerWidth * window.innerHeight * 0.05;
          if (!overlayLike) continue;
          if (hideNode(node)) suppressed++;
        }
      }

      for (const root of roots) {
        let allContainers = [];
        try {
          allContainers = Array.from(root.querySelectorAll("div,section,aside,dialog,footer"));
        } catch (err) {}
        for (const node of allContainers) {
          if (!(node instanceof HTMLElement)) continue;
          if (!isVisible(node)) continue;
          const style = getComputedStyle(node);
          if (style.position !== "fixed" && style.position !== "sticky") continue;
          const rect = node.getBoundingClientRect();
          if (rect.width * rect.height < window.innerWidth * window.innerHeight * 0.04) continue;
          const text = getOverlayText(node);
          if (!hasCookieContext(text)) continue;
          if (hideNode(node)) suppressed++;
        }
      }

      const iframeHints = ["consent", "cookie", "onetrust", "didomi", "sp_message", "sourcepoint", "quantcast", "trustarc", "cookiebot", "cmp"];
      const iframeMatchesHint = (iframe) => {
        const text = normalize(
          iframe.id + " " +
          iframe.className + " " +
          (iframe.getAttribute("title") || "") + " " +
          (iframe.getAttribute("name") || "") + " " +
          (iframe.getAttribute("src") || "")
        );
        return iframeHints.some((hint) => text.includes(hint));
      };

      let iframes = [];
      try { iframes = Array.from(document.querySelectorAll("iframe")); } catch (err) {}
      for (const iframe of iframes) {
        if (!iframeMatchesHint(iframe)) continue;
        const rect = iframe.getBoundingClientRect();
        if (rect.width * rect.height < 1000) continue;
        if (hideNode(iframe)) suppressed++;
      }

      const unlockScroll = (node) => {
        if (!(node instanceof HTMLElement)) return;
        node.style.removeProperty("overflow");
        node.style.removeProperty("position");
        node.style.removeProperty("inset");
        node.style.removeProperty("height");
        node.style.removeProperty("touch-action");
        node.classList.remove(
          "didomi-popup-open",
          "sp-message-open",
          "onetrust-consent-sdk",
          "no-scroll",
          "overflow-hidden",
          "modal-open"
        );
      };

      unlockScroll(document.documentElement);
      unlockScroll(document.body);
      try {
        document.querySelectorAll("[style*='overflow: hidden']").forEach((node) => {
          if (node instanceof HTMLElement) node.style.setProperty("overflow", "visible", "important");
        });
      } catch (err) {}

      return { clicked, suppressed };
    })();
    """

    private static let domSnapshotStateScript = """
    (() => {
      const body = document.body;
      if (!body) {
        return { ready: document.readyState !== 'loading', nodes: 0, text: 0, interactive: 0, media: 0, heading: 0 };
      }

      const nodes = body.querySelectorAll('*').length;
      const text = (body.innerText || '').replace(/\\s+/g, ' ').trim().length;
      const interactive = body.querySelectorAll(\"a,button,input,textarea,select,[role='button']\").length;
      const media = body.querySelectorAll('img,svg,canvas,video,picture').length;
      const heading = body.querySelectorAll('h1,h2,h3').length;

      return {
        ready: document.readyState !== 'loading',
        nodes,
        text,
        interactive,
        media,
        heading
      };
    })();
    """

    private static let forceDocumentVisibleScript = """
    (() => {
      try {
        const define = (obj, key, getter) => {
          const descriptor = Object.getOwnPropertyDescriptor(obj, key);
          if (!descriptor || descriptor.configurable) {
            Object.defineProperty(obj, key, { configurable: true, get: getter });
          }
        };
        define(Document.prototype, 'hidden', () => false);
        define(Document.prototype, 'visibilityState', () => 'visible');
        document.dispatchEvent(new Event('visibilitychange'));
      } catch (err) {}
      return true;
    })();
    """

    private static let dynamicRenderingKickScript = """
    (() => {
      try {
        window.dispatchEvent(new Event('focus'));
        window.dispatchEvent(new Event('resize'));
        window.scrollBy(0, 1);
        window.scrollBy(0, -1);
        window.dispatchEvent(new Event('scroll'));
        document.dispatchEvent(new Event('visibilitychange'));
        document.dispatchEvent(new Event('readystatechange'));
      } catch (err) {}
      return true;
    })();
    """

    private static let aggressiveRevealScript = """
    (() => {
      try {
        const candidates = document.querySelectorAll(
          "[style*='opacity: 0'], .opacity-0, .invisible, [data-aos], [data-animate], [data-motion]"
        );
        for (const el of candidates) {
          if (!(el instanceof HTMLElement)) continue;
          el.style.setProperty('opacity', '1', 'important');
          el.style.setProperty('visibility', 'visible', 'important');
          if (el.style.transform) {
            el.style.setProperty('transform', 'none', 'important');
          }
          el.classList.remove('opacity-0', 'invisible', 'hidden');
        }
      } catch (err) {}
      return true;
    })();
    """

    private static let desktopSafariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

    private static let nyTimesReadinessScript = """
    (() => {
      const body = document.body;
      if (!body) return { ready: document.readyState === "complete", text: 0, articleLike: 0, articleText: 0, cookieLike: 0, gatewayLike: 0 };
      const text = (body.innerText || "").replace(/\\s+/g, " ").trim().length;
      const articleLike = document.querySelectorAll("article, main article, section[name='articleBody'], [data-testid*='article']").length;
      const articleText = Array.from(document.querySelectorAll("article p, main article p, [data-testid*='article'] p"))
        .map((node) => (node.textContent || "").trim().length)
        .reduce((acc, value) => acc + value, 0);
      const pageText = (body.innerText || "").toLowerCase();
      const cookieLike =
        (pageText.includes("manage privacy preferences") || pageText.includes("accept all") || pageText.includes("reject all")) ? 1 : 0;
      const gatewayLike =
        (pageText.includes("you have free access to this story") || pageText.includes("continue reading with a times account")) ? 1 : 0;
      return {
        ready: document.readyState === "complete" || document.readyState === "interactive",
        text,
        articleLike,
        articleText,
        cookieLike,
        gatewayLike
      };
    })();
    """

    private static let nyTimesLightweightCleanupScript = """
    (() => {
      let dismissed = 0;
      const normalize = (value) => (value || "").toLowerCase().replace(/\\s+/g, " ").trim();
      const viewportArea = Math.max(window.innerWidth * window.innerHeight, 1);

      const clickByText = (texts) => {
        const nodes = Array.from(document.querySelectorAll("button, [role='button'], a"));
        for (const node of nodes) {
          const label = normalize(node.innerText || node.textContent || node.getAttribute("aria-label") || node.getAttribute("title"));
          if (!label) continue;
          if (!texts.some((text) => label === text || label.includes(text))) continue;
          if (!(node instanceof HTMLElement)) continue;
          try {
            node.click();
            node.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, view: window }));
            dismissed += 1;
          } catch (err) {}
        }
      };

      // Prefer reject when available to avoid consent overlays persisting.
      clickByText(["reject all", "refuser", "tout refuser"]);
      clickByText(["accept all", "accepter", "tout accepter"]);
      clickByText(["continue without subscribing", "close", "dismiss", "not now", "skip"]);

      const hideNode = (node) => {
        if (!(node instanceof HTMLElement)) return false;
        if (node === document.body || node === document.documentElement) return false;
        try {
          node.style.setProperty("display", "none", "important");
          node.style.setProperty("visibility", "hidden", "important");
          node.style.setProperty("opacity", "0", "important");
          node.style.setProperty("pointer-events", "none", "important");
          dismissed += 1;
          return true;
        } catch (err) {
          return false;
        }
      };

      const isOverlayLike = (node) => {
        if (!(node instanceof HTMLElement)) return false;
        const style = getComputedStyle(node);
        const rect = node.getBoundingClientRect();
        if (rect.width < 40 || rect.height < 40) return false;
        const area = rect.width * rect.height;
        const byPosition = style.position === "fixed" || style.position === "sticky";
        const byZ = Number(style.zIndex || "0") >= 999;
        const byRole = node.matches("[role='dialog'], dialog, [aria-modal='true']");
        return (byPosition || byZ || byRole) && area >= viewportArea * 0.04;
      };

      const isConsentLike = (node) => {
        if (!(node instanceof HTMLElement)) return false;
        const text = normalize(
          (node.innerText || node.textContent || "") +
          " " +
          (node.id || "") +
          " " +
          (node.className || "") +
          " " +
          (node.getAttribute("aria-label") || "")
        );
        return (
          text.includes("cookie") ||
          text.includes("privacy preferences") ||
          text.includes("manage preferences") ||
          text.includes("accept all") ||
          text.includes("reject all") ||
          text.includes("consent") ||
          text.includes("gdpr")
        );
      };

      const consentSelectors = [
        "#bottom-wrapper",
        "[data-testid*='consent']",
        "[id*='consent']",
        "[class*='consent']",
        "[id*='cookie']",
        "[class*='cookie']",
        "[aria-label*='privacy' i]",
        "iframe[src*='consent' i]",
        "iframe[src*='sourcepoint' i]",
        "iframe[src*='privacy' i]",
        "iframe[title*='consent' i]"
      ];

      for (const selector of consentSelectors) {
        const nodes = Array.from(document.querySelectorAll(selector));
        for (const node of nodes) {
          if (node instanceof HTMLIFrameElement) {
            const rect = node.getBoundingClientRect();
            if (rect.width * rect.height >= viewportArea * 0.03) {
              hideNode(node);
            }
            continue;
          }
          if (!(node instanceof HTMLElement)) continue;
          if (isConsentLike(node) && isOverlayLike(node)) {
            hideNode(node);
          }
        }
      }

      if (document.documentElement instanceof HTMLElement) {
        document.documentElement.style.setProperty("overflow", "visible", "important");
        document.documentElement.style.removeProperty("position");
      }
      if (document.body instanceof HTMLElement) {
        document.body.style.setProperty("overflow", "visible", "important");
        document.body.style.removeProperty("position");
      }

      return { dismissed };
    })();
    """

    private static let wordPressCookieDismissScript = """
    (() => {
      let clicked = 0;
      let suppressed = 0;
      const normalize = (value) => (value || "")
        .toLowerCase()
        .replace(/[!"#$%&'()*+,\\-./:;<=>?@[\\\\\\]^_`{|}~]/g, " ")
        .replace(/\\s+/g, " ")
        .trim();
      const viewportArea = Math.max(window.innerWidth * window.innerHeight, 1);
      const ACCEPT_TERMS = [
        "accept", "accept all", "accept all cookies", "accept and close", "allow all",
        "agree", "i agree", "ok", "got it", "continue", "yes, i agree",
        "accept and continue", "allow and continue"
      ];
      const IFRAME_HINTS = ["cookie", "consent", "cmp", "privacy", "didomi", "onetrust", "sourcepoint", "quantcast"];

      const isVisible = (el) => {
        if (!(el instanceof Element)) return false;
        const style = getComputedStyle(el);
        if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity || "1") < 0.05) return false;
        const rect = el.getBoundingClientRect();
        return rect.width > 2 && rect.height > 2;
      };

      const readLabel = (node) => normalize(
        node.innerText ||
        node.textContent ||
        node.getAttribute("aria-label") ||
        node.getAttribute("title") ||
        node.getAttribute("value")
      );
      const matchesAccept = (label) => ACCEPT_TERMS.some((term) => label === term || label.includes(term));

      const roots = new Set([document]);
      const docs = new Set([document]);
      const docStack = [document];

      while (docStack.length) {
        const currentDoc = docStack.pop();
        const rootStack = [currentDoc];
        while (rootStack.length) {
          const root = rootStack.pop();
          roots.add(root);
          let elements = [];
          try { elements = Array.from(root.querySelectorAll("*")); } catch (err) {}
          for (const el of elements) {
            if (!(el instanceof Element)) continue;

            if (el.shadowRoot && !roots.has(el.shadowRoot)) {
              roots.add(el.shadowRoot);
              rootStack.push(el.shadowRoot);
            }

            if (el.tagName === "IFRAME") {
              const frame = el;
              const frameText = normalize(
                (frame.id || "") + " " +
                (frame.className || "") + " " +
                (frame.getAttribute("title") || "") + " " +
                (frame.getAttribute("name") || "") + " " +
                (frame.getAttribute("src") || "")
              );

              if (IFRAME_HINTS.some((hint) => frameText.includes(hint))) {
                const rect = frame.getBoundingClientRect();
                if (rect.width * rect.height > viewportArea * 0.02) {
                  try {
                    frame.style.setProperty("display", "none", "important");
                    frame.style.setProperty("visibility", "hidden", "important");
                    frame.style.setProperty("opacity", "0", "important");
                    frame.style.setProperty("pointer-events", "none", "important");
                    suppressed += 1;
                  } catch (err) {}
                }
              }

              try {
                if (frame.contentDocument && !docs.has(frame.contentDocument)) {
                  docs.add(frame.contentDocument);
                  docStack.push(frame.contentDocument);
                  roots.add(frame.contentDocument);
                }
              } catch (err) {}
            }
          }
        }
      }

      const clickElement = (el) => {
        if (!(el instanceof HTMLElement)) return false;
        if (!isVisible(el)) return false;
        try {
          el.click();
          el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, view: window }));
          clicked += 1;
          return true;
        } catch (err) {
          return false;
        }
      };

      const acceptSelectors = [
        "#eu-cookie-law .accept",
        "#eu-cookie-law button",
        ".widget_eu_cookie_law_widget .accept",
        ".widget_eu_cookie_law_widget button",
        ".cn-button.wp-default",
        ".cn-set-cookie",
        "#cn-accept-cookie",
        ".cookie-notice-accept",
        "#cookie_action_close_header",
        ".cky-btn-accept",
        "#cky-btn-accept",
        ".cli-bar-btn_container .cli_action_button",
        ".cli-bar-btn_container .cli_accept_all_button",
        ".cmplz-btn.cmplz-accept",
        ".moove-gdpr-infobar-allow-all"
      ];

      for (const root of roots) {
        for (const selector of acceptSelectors) {
          let nodes = [];
          try { nodes = Array.from(root.querySelectorAll(selector)); } catch (err) {}
          for (const node of nodes) {
            clickElement(node);
          }
        }
      }

      for (const root of roots) {
        let candidates = [];
        try {
          candidates = Array.from(root.querySelectorAll("button, [role='button'], a, input[type='button'], input[type='submit']"));
        } catch (err) {}
        for (const node of candidates) {
          const label = readLabel(node);
          if (!label) continue;
          if (!matchesAccept(label)) continue;
          clickElement(node);
        }
      }

      const findAndHandlePrivacyCookiesBanner = () => {
        let containers = [];
        try {
          containers = Array.from(document.querySelectorAll("div,section,aside,footer,form,article"));
        } catch (err) {}
        for (const node of containers) {
          if (!(node instanceof HTMLElement)) continue;
          if (!isVisible(node)) continue;
          const text = normalize(
            (node.innerText || node.textContent || "") + " " +
            (node.id || "") + " " +
            (node.className || "") + " " +
            (node.getAttribute("aria-label") || "")
          );
          const privacyCookiesLike =
            text.includes("privacy cookies") ||
            text.includes("privacy and cookies") ||
            text.includes("privacy cookies") ||
            text.includes("wordpress com network") ||
            text.includes("learn more") && text.includes("i agree");
          if (!privacyCookiesLike) continue;

          let actions = [];
          try {
            actions = Array.from(node.querySelectorAll("button, [role='button'], a, input[type='button'], input[type='submit']"));
          } catch (err) {}
          for (const action of actions) {
            const label = readLabel(action);
            if (!label || !matchesAccept(label)) continue;
            clickElement(action);
          }

          const rect = node.getBoundingClientRect();
          const nearBottom = rect.top >= window.innerHeight * 0.45 || rect.bottom >= window.innerHeight - 2;
          const mediumHeight = rect.height <= window.innerHeight * 0.55;
          if (nearBottom && mediumHeight) {
            hideNode(node);
          }
        }
      };

      const hideNode = (node) => {
        if (!(node instanceof HTMLElement)) return false;
        const style = getComputedStyle(node);
        const rect = node.getBoundingClientRect();
        const overlayLike =
          (style.position === "fixed" || style.position === "sticky" || Number(style.zIndex || "0") >= 999) &&
          rect.width * rect.height > window.innerWidth * window.innerHeight * 0.03;
        const text = normalize(
          (node.innerText || node.textContent || "") + " " +
          (node.id || "") + " " +
          (node.className || "") + " " +
          (node.getAttribute("aria-label") || "")
        );
        const cookieLike =
          text.includes("cookie") ||
          text.includes("privacy preferences") ||
          text.includes("gdpr") ||
          text.includes("consent");
        if (!overlayLike || !cookieLike) return false;
        try {
          node.style.setProperty("display", "none", "important");
          node.style.setProperty("visibility", "hidden", "important");
          node.style.setProperty("opacity", "0", "important");
          node.style.setProperty("pointer-events", "none", "important");
          if (node.parentElement) node.remove();
          suppressed += 1;
          return true;
        } catch (err) {
          return false;
        }
      };

      const bannerSelectors = [
        ".a8c-cookie-banner",
        ".a8c-cookie-banner__container",
        "#eu-cookie-law",
        ".widget_eu_cookie_law_widget",
        "#cookie-law-info-bar",
        ".cookie-notice-container",
        ".cn-cookie-bar",
        ".cookiebanner",
        ".cli-bar-container",
        ".cli-modal-backdrop",
        ".cky-consent-container",
        ".cky-banner-element",
        ".cmplz-cookiebanner-container",
        ".cmplz-cookiebanner",
        ".moove-gdpr-cookie-notice"
      ];

      for (const root of roots) {
        for (const selector of bannerSelectors) {
          let nodes = [];
          try { nodes = Array.from(root.querySelectorAll(selector)); } catch (err) {}
          for (const node of nodes) {
            hideNode(node);
          }
        }
      }

      for (const root of roots) {
        let genericNodes = [];
        try {
          genericNodes = Array.from(root.querySelectorAll("[id*='cookie' i], [class*='cookie' i], [id*='consent' i], [class*='consent' i], [id*='gdpr' i], [class*='gdpr' i], [id*='privacy' i], [class*='privacy' i]"));
        } catch (err) {}
        for (const node of genericNodes) {
          hideNode(node);
        }
      }

      findAndHandlePrivacyCookiesBanner();

      if (document.documentElement instanceof HTMLElement) {
        document.documentElement.style.setProperty("overflow", "visible", "important");
      }
      if (document.body instanceof HTMLElement) {
        document.body.style.setProperty("overflow", "visible", "important");
      }

      return { clicked, suppressed };
    })();
    """

    private static let leMondeAdCleanupScript = """
    (() => {
      let suppressed = 0;
      const pageHost = (window.location.hostname || "").toLowerCase().replace(/^www\\./, "");
      const normalize = (value) => (value || "")
        .toLowerCase()
        .replace(/[!"#$%&'()*+,\\-./:;<=>?@[\\\\\\]^_`{|}~]/g, " ")
        .replace(/\\s+/g, " ")
        .trim();

      const toHost = (value) => {
        try {
          return new URL(value, window.location.href).hostname.toLowerCase().replace(/^www\\./, "");
        } catch (err) {
          return "";
        }
      };

      const isExternalHref = (value) => {
        const host = toHost(value);
        if (!host || !pageHost) return false;
        return host !== pageHost && !host.endsWith("." + pageHost);
      };

      const viewportArea = Math.max(window.innerWidth * window.innerHeight, 1);
      const adHints = [
        "doubleclick",
        "googlesyndication",
        "googleadservices",
        "adservice",
        "teads",
        "smartadserver",
        "taboola",
        "outbrain",
        "adnxs",
        "criteo",
        "pubmatic",
        "adsystem",
        "renault",
        "publicite",
        "advertisement",
        "adchoices",
        "sponsor",
        "tead",
        "smartad",
        "dfp"
      ];

      const adLikeMarker = (node) => normalize(
        (node.id || "") + " " +
        (node.className || "") + " " +
        (node.getAttribute("data-testid") || "") + " " +
        (node.getAttribute("data-slot") || "") + " " +
        (node.getAttribute("data-ad") || "") + " " +
        (node.getAttribute("data-ad-unit") || "") + " " +
        (node.getAttribute("aria-label") || "") + " " +
        (node.getAttribute("role") || "")
      );

      const hideElement = (node) => {
        if (!(node instanceof HTMLElement)) return false;
        const rect = node.getBoundingClientRect();
        if (rect.width < 4 || rect.height < 4) return false;
        try {
          node.style.setProperty("display", "none", "important");
          node.style.setProperty("visibility", "hidden", "important");
          node.style.setProperty("opacity", "0", "important");
          node.style.setProperty("pointer-events", "none", "important");
          suppressed += 1;
          return true;
        } catch (err) {
          return false;
        }
      };

      const hideWithParents = (node, maxDepth = 3) => {
        if (!(node instanceof HTMLElement)) return false;
        let changed = false;
        if (hideElement(node)) changed = true;
        let parent = node.parentElement;
        let depth = 0;
        while (parent && depth < maxDepth) {
          const rect = parent.getBoundingClientRect();
          const area = rect.width * rect.height;
          if (
            area >= viewportArea * 0.01 &&
            area <= viewportArea * 0.65 &&
            rect.top <= window.innerHeight * 0.80
          ) {
            if (hideElement(parent)) changed = true;
          } else {
            break;
          }
          parent = parent.parentElement;
          depth += 1;
        }
        return changed;
      };

      const probablyAdContainer = (node, marker = null) => {
        if (!(node instanceof HTMLElement)) return false;
        const rect = node.getBoundingClientRect();
        const area = rect.width * rect.height;
        if (area < viewportArea * 0.012) return false;
        if (area > viewportArea * 0.70) return false;
        if (rect.top > window.innerHeight * 0.78) return false;

        const localMarker = marker || adLikeMarker(node);

        const keywordLike =
          localMarker.includes("ad") ||
          localMarker.includes("ads") ||
          localMarker.includes("adslot") ||
          localMarker.includes("advert") ||
          localMarker.includes("publicite") ||
          localMarker.includes("sponsor") ||
          localMarker.includes("teads") ||
          localMarker.includes("outbrain") ||
          localMarker.includes("taboola") ||
          localMarker.includes("smartad") ||
          localMarker.includes("dfp");
        if (!keywordLike) return false;

        const bannerShape = rect.width >= window.innerWidth * 0.34 && rect.height >= 90 && rect.height <= 420;
        const nearTop = rect.top <= window.innerHeight * 0.62;
        return bannerShape || nearTop;
      };

      const looksLikeLargePromo = (node) => {
        if (!(node instanceof HTMLElement)) return false;
        const rect = node.getBoundingClientRect();
        if (rect.width < window.innerWidth * 0.33) return false;
        if (rect.height < 90 || rect.height > 430) return false;
        if (rect.top > window.innerHeight * 0.72) return false;
        const area = rect.width * rect.height;
        if (area < viewportArea * 0.014 || area > viewportArea * 0.62) return false;

        let mediaCount = 0;
        let headingCount = 0;
        let paragraphCount = 0;
        let linkCount = 0;
        let externalLinkCount = 0;
        try { mediaCount = node.querySelectorAll("img,picture,video,iframe").length; } catch (err) {}
        try { headingCount = node.querySelectorAll("h1,h2,h3,h4").length; } catch (err) {}
        try { paragraphCount = node.querySelectorAll("p").length; } catch (err) {}
        let links = [];
        try { links = Array.from(node.querySelectorAll("a[href]")); } catch (err) {}
        for (const link of links) {
          if (!(link instanceof HTMLAnchorElement)) continue;
          linkCount += 1;
          if (isExternalHref(link.href)) {
            externalLinkCount += 1;
          }
          if (externalLinkCount >= 2) break;
        }

        const textLength = normalize(node.innerText || node.textContent || "").length;
        const marker = adLikeMarker(node);
        const markerHasHint = adHints.some((hint) => marker.includes(hint));
        const bannerShape = rect.width >= window.innerWidth * 0.42 && rect.height >= 100 && rect.height <= 360;
        const sparseText = textLength <= 220;

        if (!bannerShape || mediaCount < 1) return false;
        if (markerHasHint) return true;
        if (externalLinkCount > 0 && sparseText && headingCount <= 1) return true;
        if (linkCount <= 2 && paragraphCount <= 1 && sparseText && headingCount === 0) return true;
        return false;
      };

      const iframeNodes = Array.from(document.querySelectorAll("iframe"));
      for (const frame of iframeNodes) {
        const rect = frame.getBoundingClientRect();
        const area = rect.width * rect.height;
        if (area < viewportArea * 0.01) continue;

        const marker = normalize(
          (frame.id || "") + " " +
          (frame.className || "") + " " +
          (frame.getAttribute("name") || "") + " " +
          (frame.getAttribute("title") || "") + " " +
          (frame.getAttribute("src") || "")
        );
        const frameHost = toHost(frame.getAttribute("src") || "");
        const externalFrame = frameHost && frameHost !== pageHost && !frameHost.endsWith("." + pageHost);
        const bannerLikeFrame =
          rect.width >= window.innerWidth * 0.34 &&
          rect.height >= 90 &&
          rect.height <= 420 &&
          rect.top <= window.innerHeight * 0.68;
        const markerHasHint = adHints.some((hint) => marker.includes(hint));
        if (!markerHasHint && !(bannerLikeFrame && externalFrame)) continue;

        hideWithParents(frame, 3);
      }

      const adSelectors = [
        "[id*='google_ads_iframe' i]",
        "[id*='adslot' i]",
        "[class*='adslot' i]",
        "[id*='ad-slot' i]",
        "[class*='ad-slot' i]",
        "[id*='adunit' i]",
        "[class*='adunit' i]",
        "[id*='publicite' i]",
        "[class*='publicite' i]",
        "[id*='teads' i]",
        "[class*='teads' i]",
        "[id*='taboola' i]",
        "[class*='taboola' i]",
        "[id*='outbrain' i]",
        "[class*='outbrain' i]",
        "[id*='smartad' i]",
        "[class*='smartad' i]",
        "[aria-label*='advertisement' i]",
        "[aria-label*='publicite' i]",
        "[data-ad]",
        "[data-ad-container]",
        "[data-ad-unit]",
        "[data-slot*='ad' i]",
        "[data-testid*='ad' i]",
        "[id*='dfp' i]",
        "[class*='dfp' i]",
        "[id*='sponsor' i]",
        "[class*='sponsor' i]",
        "ins.adsbygoogle"
      ];

      for (const selector of adSelectors) {
        let nodes = [];
        try { nodes = Array.from(document.querySelectorAll(selector)); } catch (err) {}
        for (const node of nodes) {
          if (!(node instanceof HTMLElement)) continue;
          const marker = adLikeMarker(node);
          const markerHasHint = adHints.some((hint) => marker.includes(hint));
          if (markerHasHint || probablyAdContainer(node, marker) || looksLikeLargePromo(node)) {
            hideWithParents(node, 2);
          }
        }
      }

      const wideImages = Array.from(document.querySelectorAll("img"));
      for (const image of wideImages) {
        if (!(image instanceof HTMLElement)) continue;
        const rect = image.getBoundingClientRect();
        const area = rect.width * rect.height;
        if (rect.width < window.innerWidth * 0.33 || rect.height < 90 || rect.height > 420) continue;
        if (area < viewportArea * 0.018 || rect.top > window.innerHeight * 0.62) continue;

        const marker = normalize(
          (image.getAttribute("alt") || "") + " " +
          (image.getAttribute("src") || "") + " " +
          (image.currentSrc || "")
        );
        const anchor = image.closest("a[href]");
        const anchorHref = anchor instanceof HTMLAnchorElement ? anchor.href : "";
        const externalClick = anchorHref ? isExternalHref(anchorHref) : false;
        const markerHasHint =
          adHints.some((hint) => marker.includes(hint)) ||
          adHints.some((hint) => normalize(anchorHref).includes(hint));
        if (!markerHasHint && !externalClick) continue;

        const parent = image.closest("a, figure, div, section, aside");
        if (parent instanceof HTMLElement) {
          hideWithParents(parent, 2);
        } else {
          hideWithParents(image, 1);
        }
      }

      const wrapperNodes = Array.from(document.querySelectorAll("main section, main div, [role='main'] section, [role='main'] div, section, aside"));
      for (const node of wrapperNodes) {
        if (!(node instanceof HTMLElement)) continue;
        if (!looksLikeLargePromo(node)) continue;
        const marker = adLikeMarker(node);
        const markerHasHint = adHints.some((hint) => marker.includes(hint));
        let externalLinkCount = 0;
        let containsIframe = false;
        let links = [];
        try { links = Array.from(node.querySelectorAll("a[href]")); } catch (err) {}
        for (const link of links) {
          if (!(link instanceof HTMLAnchorElement)) continue;
          if (isExternalHref(link.href)) {
            externalLinkCount += 1;
          }
          if (externalLinkCount >= 2) break;
        }
        try { containsIframe = node.querySelector("iframe") !== null; } catch (err) {}
        if (markerHasHint || externalLinkCount > 0 || containsIframe) {
          hideWithParents(node, 2);
        }
      }

      return { suppressed };
    })();
    """
}
