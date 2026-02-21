import Foundation

struct CaptureSiteProfile {
    enum Identifier: String {
        case `default`
        case nyTimes
        case wordPress
        case leMonde
        case openClaw
    }

    enum DomainCleanupMode {
        case none
        case nyTimesLightweight
        case wordPressCookies
        case leMondeAds
    }

    let identifier: Identifier
    let navigationTimeoutSeconds: UInt64
    let allowCommitFallback: Bool
    let commitFallbackDelaySeconds: TimeInterval
    let strictSnapshotMode: Bool
    let initialPostLoadDelayNanoseconds: UInt64
    let postLoadCleanupPassCount: Int
    let postLoadCleanupPauseNanoseconds: UInt64
    let finalCleanupPassCount: Int
    let finalCleanupPauseNanoseconds: UInt64
    let meaningfulDOMTimeoutSeconds: UInt64
    let domStabilityTimeoutSeconds: UInt64
    let domMutationIdleMilliseconds: Int
    let domStabilitySampleCount: Int
    let aggressiveHydrationKick: Bool
    let domainCleanupMode: DomainCleanupMode
    let hostReadinessTimeoutSeconds: UInt64

    static let `default` = CaptureSiteProfile(
        identifier: .default,
        navigationTimeoutSeconds: 90,
        allowCommitFallback: false,
        commitFallbackDelaySeconds: 8,
        strictSnapshotMode: false,
        initialPostLoadDelayNanoseconds: 2_000_000_000,
        postLoadCleanupPassCount: 3,
        postLoadCleanupPauseNanoseconds: 280_000_000,
        finalCleanupPassCount: 2,
        finalCleanupPauseNanoseconds: 220_000_000,
        meaningfulDOMTimeoutSeconds: 6,
        domStabilityTimeoutSeconds: 7,
        domMutationIdleMilliseconds: 700,
        domStabilitySampleCount: 3,
        aggressiveHydrationKick: false,
        domainCleanupMode: .none,
        hostReadinessTimeoutSeconds: 0
    )

    static let nyTimes = CaptureSiteProfile(
        identifier: .nyTimes,
        navigationTimeoutSeconds: 70,
        allowCommitFallback: true,
        commitFallbackDelaySeconds: 22,
        strictSnapshotMode: true,
        initialPostLoadDelayNanoseconds: 3_000_000_000,
        postLoadCleanupPassCount: 2,
        postLoadCleanupPauseNanoseconds: 500_000_000,
        finalCleanupPassCount: 1,
        finalCleanupPauseNanoseconds: 350_000_000,
        meaningfulDOMTimeoutSeconds: 8,
        domStabilityTimeoutSeconds: 9,
        domMutationIdleMilliseconds: 800,
        domStabilitySampleCount: 2,
        aggressiveHydrationKick: false,
        domainCleanupMode: .nyTimesLightweight,
        hostReadinessTimeoutSeconds: 8
    )

    static let wordPress = CaptureSiteProfile(
        identifier: .wordPress,
        navigationTimeoutSeconds: 90,
        allowCommitFallback: false,
        commitFallbackDelaySeconds: 8,
        strictSnapshotMode: false,
        initialPostLoadDelayNanoseconds: 2_000_000_000,
        postLoadCleanupPassCount: 3,
        postLoadCleanupPauseNanoseconds: 320_000_000,
        finalCleanupPassCount: 2,
        finalCleanupPauseNanoseconds: 260_000_000,
        meaningfulDOMTimeoutSeconds: 6,
        domStabilityTimeoutSeconds: 7,
        domMutationIdleMilliseconds: 700,
        domStabilitySampleCount: 3,
        aggressiveHydrationKick: false,
        domainCleanupMode: .wordPressCookies,
        hostReadinessTimeoutSeconds: 0
    )

    static let leMonde = CaptureSiteProfile(
        identifier: .leMonde,
        navigationTimeoutSeconds: 90,
        allowCommitFallback: false,
        commitFallbackDelaySeconds: 8,
        strictSnapshotMode: false,
        initialPostLoadDelayNanoseconds: 2_000_000_000,
        postLoadCleanupPassCount: 3,
        postLoadCleanupPauseNanoseconds: 300_000_000,
        finalCleanupPassCount: 2,
        finalCleanupPauseNanoseconds: 230_000_000,
        meaningfulDOMTimeoutSeconds: 6,
        domStabilityTimeoutSeconds: 7,
        domMutationIdleMilliseconds: 700,
        domStabilitySampleCount: 3,
        aggressiveHydrationKick: false,
        domainCleanupMode: .leMondeAds,
        hostReadinessTimeoutSeconds: 0
    )

    static let openClaw = CaptureSiteProfile(
        identifier: .openClaw,
        navigationTimeoutSeconds: 90,
        allowCommitFallback: false,
        commitFallbackDelaySeconds: 8,
        strictSnapshotMode: false,
        initialPostLoadDelayNanoseconds: 2_000_000_000,
        postLoadCleanupPassCount: 3,
        postLoadCleanupPauseNanoseconds: 280_000_000,
        finalCleanupPassCount: 2,
        finalCleanupPauseNanoseconds: 220_000_000,
        meaningfulDOMTimeoutSeconds: 7,
        domStabilityTimeoutSeconds: 8,
        domMutationIdleMilliseconds: 750,
        domStabilitySampleCount: 3,
        aggressiveHydrationKick: true,
        domainCleanupMode: .none,
        hostReadinessTimeoutSeconds: 0
    )
}

enum CaptureSiteProfileResolver {
    static func resolve(for url: URL) -> CaptureSiteProfile {
        guard let host = url.host?.lowercased() else {
            return .default
        }

        if matches(host: host, root: "nytimes.com") {
            return .nyTimes
        }

        if matches(host: host, root: "wordpress.com") {
            return .wordPress
        }

        if matches(host: host, root: "lemonde.fr") {
            return .leMonde
        }

        if matches(host: host, root: "openclaw.ai") {
            return .openClaw
        }

        return .default
    }

    private static func matches(host: String, root: String) -> Bool {
        host == root || host.hasSuffix("." + root)
    }
}
