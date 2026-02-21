import Foundation
import XCTest
@testable import HTMLContentCreator

final class CaptureSiteProfileResolverTests: XCTestCase {
    func testResolveReturnsNyTimesProfileForNyTimesHosts() throws {
        let url = try XCTUnwrap(URL(string: "https://www.nytimes.com/2026/02/21/world/europe/article.html"))
        let profile = CaptureSiteProfileResolver.resolve(for: url)

        XCTAssertEqual(profile.identifier, .nyTimes)
        XCTAssertTrue(profile.strictSnapshotMode)
        XCTAssertEqual(profile.domainCleanupMode, .nyTimesLightweight)
    }

    func testResolveReturnsWordPressProfile() throws {
        let url = try XCTUnwrap(URL(string: "https://foo.wordpress.com/post"))
        let profile = CaptureSiteProfileResolver.resolve(for: url)

        XCTAssertEqual(profile.identifier, .wordPress)
        XCTAssertFalse(profile.strictSnapshotMode)
        XCTAssertEqual(profile.domainCleanupMode, .wordPressCookies)
    }

    func testResolveReturnsLeMondeProfile() throws {
        let url = try XCTUnwrap(URL(string: "https://www.lemonde.fr/economie/article"))
        let profile = CaptureSiteProfileResolver.resolve(for: url)

        XCTAssertEqual(profile.identifier, .leMonde)
        XCTAssertEqual(profile.domainCleanupMode, .leMondeAds)
    }

    func testResolveReturnsOpenClawProfile() throws {
        let url = try XCTUnwrap(URL(string: "https://app.openclaw.ai/demo"))
        let profile = CaptureSiteProfileResolver.resolve(for: url)

        XCTAssertEqual(profile.identifier, .openClaw)
        XCTAssertTrue(profile.aggressiveHydrationKick)
    }

    func testResolveReturnsDefaultProfile() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/page"))
        let profile = CaptureSiteProfileResolver.resolve(for: url)

        XCTAssertEqual(profile.identifier, .default)
        XCTAssertEqual(profile.domainCleanupMode, .none)
    }
}
