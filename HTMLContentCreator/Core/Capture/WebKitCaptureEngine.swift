import AppKit
import Foundation
import WebKit

enum WebKitCaptureEngine {
    static let viewport = CGSize(width: 1920, height: 1080)

    @MainActor
    static func capture(url: URL) async throws -> Data {
        let session = WebKitCaptureSession(viewport: viewport)
        return try await session.capture(url: url)
    }
}

@MainActor
private final class WebKitCaptureSession: NSObject, WKNavigationDelegate {
    private let viewport: CGSize
    private let webView: WKWebView
    private let window: NSWindow

    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var loadTimeoutTask: Task<Void, Never>?

    private static let cookieAcceptTexts: [String] = [
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
    ]

    init(viewport: CGSize) {
        self.viewport = viewport

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

    func capture(url: URL) async throws -> Data {
        defer {
            cleanup()
        }

        try await loadPage(url: url, timeoutSeconds: 60)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try await dismissCookieBanners()
        try await Task.sleep(nanoseconds: 300_000_000)

        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: viewport)
        config.afterScreenUpdates = true

        let image = try await webView.takeSnapshotAsync(configuration: config)
        guard let pngData = image.pngData else {
            throw AppError.captureFailed("Unable to convert snapshot to PNG.")
        }
        return pngData
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
        resolveLoad(.failure(AppError.captureFailed("Web content process terminated during capture.")))
    }

    private func loadPage(url: URL, timeoutSeconds: UInt64) async throws {
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation

            loadTimeoutTask?.cancel()
            loadTimeoutTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                guard self.loadContinuation != nil else { return }
                self.webView.stopLoading()
                self.resolveLoad(.failure(AppError.captureFailed("Navigation timeout after \(timeoutSeconds)s.")))
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

        guard let continuation = loadContinuation else { return }
        loadContinuation = nil

        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func dismissCookieBanners() async throws {
        for _ in 0..<10 {
            let clicked = (try? await webView.evaluateJavaScriptAsync(Self.cookieDismissScript)) as? Bool ?? false
            if clicked {
                return
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
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

    private static var cookieDismissScript: String {
        let terms = cookieAcceptTexts
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
            .joined(separator: ", ")

        return """
        (() => {
          const terms = [\(terms)];
          const normalize = (value) => (value || "").trim().toLowerCase();
          const docs = [document];
          const iframes = Array.from(document.querySelectorAll("iframe"));
          for (const iframe of iframes) {
            try {
              if (iframe.contentDocument) docs.push(iframe.contentDocument);
            } catch (err) {}
          }

          for (const doc of docs) {
            const candidates = Array.from(doc.querySelectorAll("button, [role='button'], input[type='button'], input[type='submit'], a"));
            for (const el of candidates) {
              const text = normalize(el.innerText || el.value || el.getAttribute("aria-label") || "");
              if (!text) continue;
              if (terms.includes(text)) {
                el.click();
                return true;
              }
            }
          }
          return false;
        })();
        """
    }
}
