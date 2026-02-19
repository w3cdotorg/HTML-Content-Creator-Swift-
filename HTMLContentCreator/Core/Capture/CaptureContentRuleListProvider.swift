import Foundation
import WebKit

@MainActor
enum CaptureContentRuleListProvider {
    nonisolated static var encodedRulesJSON: String {
        CaptureContentBlockingRules.encodedRuleList
    }

    nonisolated static var ruleCount: Int {
        CaptureContentBlockingRules.rules.count
    }

    private static let store = WKContentRuleListStore.default()
    private static var cachedRuleList: WKContentRuleList?
    private static var compilationTask: Task<WKContentRuleList?, Never>?

    static func loadRuleList() async -> WKContentRuleList? {
        if let cachedRuleList {
            return cachedRuleList
        }
        if let compilationTask {
            return await compilationTask.value
        }

        let task = Task<WKContentRuleList?, Never> {
            do {
                if let existing = try await lookupRuleList(
                    identifier: CaptureContentBlockingRules.identifier
                ) {
                    return existing
                }
                return try await compileRuleList(
                    identifier: CaptureContentBlockingRules.identifier,
                    encodedRules: CaptureContentBlockingRules.encodedRuleList
                )
            } catch {
                AppLogger.capture.error(
                    "Failed to prepare WKContentRuleList: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }

        compilationTask = task
        let result = await task.value
        compilationTask = nil
        cachedRuleList = result
        return result
    }

    private static func lookupRuleList(identifier: String) async throws -> WKContentRuleList? {
        guard let store else {
            throw AppError.captureFailed("WKContentRuleListStore is unavailable.")
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WKContentRuleList?, Error>) in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: list)
            }
        }
    }

    private static func compileRuleList(identifier: String, encodedRules: String) async throws -> WKContentRuleList {
        guard let store else {
            throw AppError.captureFailed("WKContentRuleListStore is unavailable.")
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WKContentRuleList, Error>) in
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: encodedRules
            ) { list, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let list else {
                    continuation.resume(
                        throwing: AppError.captureFailed("WKContentRuleList compilation returned no result.")
                    )
                    return
                }
                continuation.resume(returning: list)
            }
        }
    }
}

private enum CaptureContentBlockingRules {
    static let identifier = "com.swiftgpt.htmlcontentcreator.capture.contentblocking.v2"

    static let rules: [ContentRule] = [
        ContentRule(
            trigger: Trigger(
                urlFilter: #"https?://([a-z0-9-]+\.)?(doubleclick\.net|googlesyndication\.com|adservice\.google\.com|amazon-adsystem\.com|adsrvr\.org|criteo\.com|taboola\.com|outbrain\.com|quantserve\.com|scorecardresearch\.com|teads\.tv|teads\.com|smartadserver\.com|adnxs\.com|pubmatic\.com|rubiconproject\.com|openx\.net|adform\.net|2mdn\.net)/.*"#,
                resourceType: [.script, .image, .styleSheet, .raw, .media, .svgDocument],
                loadType: [.thirdParty]
            ),
            action: Action(type: .block)
        ),
        ContentRule(
            trigger: Trigger(
                urlFilter: #"https?://.*/(ads?|advert(isement)?|publicite|teads|smartad|adserver|sponsor|doubleclick|outbrain|taboola|prebid)[^?]*"#,
                resourceType: [.script, .image, .raw, .media, .svgDocument, .document],
                ifDomain: ["lemonde.fr", "www.lemonde.fr"]
            ),
            action: Action(type: .block)
        ),
        ContentRule(
            trigger: Trigger(
                urlFilter: #"https?://([a-z0-9-]+\.)?(google-analytics\.com|googletagmanager\.com|connect\.facebook\.net|analytics\.twitter\.com|hotjar\.com|newrelic\.com|segment\.com|mixpanel\.com)/.*"#,
                resourceType: [.script, .raw, .image],
                loadType: [.thirdParty]
            ),
            action: Action(type: .block)
        ),
        ContentRule(
            trigger: Trigger(
                urlFilter: #"https?://([a-z0-9-]+\.)?(cookielaw\.org|didomi\.io|sourcepoint\.com|privacy-mgmt\.com|quantcast\.com|trustarc\.com|cookiebot\.com)/.*"#,
                resourceType: [.script, .raw, .document],
                loadType: [.thirdParty]
            ),
            action: Action(type: .block)
        ),
        ContentRule(
            trigger: Trigger(urlFilter: ".*"),
            action: Action(
                type: .cssDisplayNone,
                selector: #"#onetrust-banner-sdk, .onetrust-pc-dark-filter, .onetrust-pc-lightbox, #didomi-host, #didomi-popup, .didomi-popup-backdrop, .fc-consent-root, #qc-cmp2-container, #qc-cmp2-ui, [id^='sp_message_container'], .sp_veil, .cc-window, .cc-banner, #cookie-notice, .cookie-notice-container, #cookie-law-info-bar, .a8c-cookie-banner, .a8c-cookie-banner__container, .cky-consent-container, .cky-banner-element, .cmplz-cookiebanner-container, .cmplz-cookiebanner, .moove-gdpr-cookie-notice"#
            )
        ),
        ContentRule(
            trigger: Trigger(urlFilter: ".*"),
            action: Action(
                type: .cssDisplayNone,
                selector: #".advertisement, .ad-container, .ad-wrapper, .ad-slot, [id^='google_ads_iframe'], [id*='google_ads_iframe'], [class*='ad-slot'], [id*='ad-slot'], [data-ad], [data-ad-container], [data-testid*='ad'], .sponsored-content, .sponsor-content, .promoted-content, .taboola, .OUTBRAIN, #taboola-below-article-thumbnails, [aria-label*='advertisement' i], [class*='sponsored' i]"#
            )
        ),
        ContentRule(
            trigger: Trigger(urlFilter: ".*"),
            action: Action(
                type: .cssDisplayNone,
                selector: #"[id*='cookie-banner' i], [class*='cookie-banner' i], [id*='cookie-consent' i], [class*='cookie-consent' i], [id*='consent-banner' i], [class*='consent-banner' i], [id*='gdpr' i][class*='banner' i], [class*='privacy-banner' i]"#
            )
        ),
        ContentRule(
            trigger: Trigger(
                urlFilter: ".*",
                ifDomain: ["lemonde.fr", "www.lemonde.fr"]
            ),
            action: Action(
                type: .cssDisplayNone,
                selector: #"[id*='dfp' i], [class*='dfp' i], [id*='publicite' i], [class*='publicite' i], [id*='advert' i], [class*='advert' i], [id*='sponsor' i], [class*='sponsor' i], [id*='teads' i], [class*='teads' i], [id*='smartad' i], [class*='smartad' i], [data-slot*='ad' i], [data-testid*='ad' i], [data-google-query-id], ins.adsbygoogle"#
            )
        )
    ]

    static let encodedRuleList: String = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard
            let data = try? encoder.encode(rules),
            let value = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return value
    }()
}

private struct ContentRule: Encodable {
    let trigger: Trigger
    let action: Action
}

private struct Trigger: Encodable {
    let urlFilter: String
    let resourceType: [ResourceType]?
    let loadType: [LoadType]?
    let ifDomain: [String]?
    let unlessDomain: [String]?

    init(
        urlFilter: String,
        resourceType: [ResourceType]? = nil,
        loadType: [LoadType]? = nil,
        ifDomain: [String]? = nil,
        unlessDomain: [String]? = nil
    ) {
        self.urlFilter = urlFilter
        self.resourceType = resourceType
        self.loadType = loadType
        self.ifDomain = ifDomain
        self.unlessDomain = unlessDomain
    }

    enum CodingKeys: String, CodingKey {
        case urlFilter = "url-filter"
        case resourceType = "resource-type"
        case loadType = "load-type"
        case ifDomain = "if-domain"
        case unlessDomain = "unless-domain"
    }
}

private struct Action: Encodable {
    let type: ActionType
    let selector: String?

    init(type: ActionType, selector: String? = nil) {
        self.type = type
        self.selector = selector
    }
}

private enum ActionType: String, Encodable {
    case block
    case cssDisplayNone = "css-display-none"
}

private enum ResourceType: String, Encodable {
    case document
    case image
    case styleSheet = "style-sheet"
    case script
    case font
    case media
    case raw
    case svgDocument = "svg-document"
    case popup
}

private enum LoadType: String, Encodable {
    case firstParty = "first-party"
    case thirdParty = "third-party"
}
