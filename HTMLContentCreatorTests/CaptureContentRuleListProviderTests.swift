import Foundation
import XCTest
@testable import HTMLContentCreator

final class CaptureContentRuleListProviderTests: XCTestCase {
    func testBlocklistIncludesRequestedBlockListProjectCategories() {
        let expected: Set<String> = [
            "abuse",
            "ads",
            "crypto",
            "drugs",
            "facebook",
            "fraud",
            "gambling",
            "malware",
            "phishing",
            "porn",
            "ransomware",
            "redirect",
            "scam",
            "tracking"
        ]

        XCTAssertEqual(Set(CaptureBlocklistProjectDomains.includedCategories), expected)
        for name in expected {
            XCTAssertGreaterThan(
                CaptureBlocklistProjectDomains.categoryDomainCountByName[name] ?? 0,
                0,
                "Expected non-empty category: \(name)"
            )
        }
    }

    func testBlocklistDoesNotContainTikTokTorrentOrTwitterDomains() {
        let forbiddenTerms = ["tiktok", "torrent", "twitter"]

        let matches = CaptureBlocklistProjectDomains.allDomains.filter { domain in
            forbiddenTerms.contains { domain.contains($0) }
        }
        let preview = Array(matches.prefix(5)).joined(separator: ", ")

        XCTAssertTrue(
            matches.isEmpty,
            "Found forbidden domains in blocklist: \(preview)"
        )
    }

    func testEncodedRulesJSONIsAValidArray() throws {
        let payload = CaptureContentRuleListProvider.encodedRulesJSON
        let data = try XCTUnwrap(payload.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        let array = try XCTUnwrap(object as? [[String: Any]])

        XCTAssertEqual(array.count, CaptureContentRuleListProvider.ruleCount)
        XCTAssertGreaterThan(array.count, 0)
    }

    func testEncodedRulesContainBlockAndHideActions() throws {
        let payload = CaptureContentRuleListProvider.encodedRulesJSON
        let data = try XCTUnwrap(payload.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        let array = try XCTUnwrap(object as? [[String: Any]])

        let actionTypes: Set<String> = Set(
            array.compactMap { rule in
                (rule["action"] as? [String: Any])?["type"] as? String
            }
        )

        XCTAssertTrue(actionTypes.contains("block"))
        XCTAssertTrue(actionTypes.contains("css-display-none"))
    }

    func testEncodedRulesContainLeMondeSpecificRules() throws {
        let payload = CaptureContentRuleListProvider.encodedRulesJSON
        let data = try XCTUnwrap(payload.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        let array = try XCTUnwrap(object as? [[String: Any]])

        let hasLeMondeScopedRule = array.contains { rule in
            guard
                let trigger = rule["trigger"] as? [String: Any],
                let domains = trigger["if-domain"] as? [String]
            else {
                return false
            }
            return domains.contains("lemonde.fr") || domains.contains("www.lemonde.fr")
        }

        XCTAssertTrue(hasLeMondeScopedRule)
    }

    func testEncodedRulesContainExpandedBlocklistDomains() throws {
        XCTAssertGreaterThan(CaptureContentRuleListProvider.blocklistDomainCount, 10_000)

        let payload = CaptureContentRuleListProvider.encodedRulesJSON
        let data = try XCTUnwrap(payload.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        let array = try XCTUnwrap(object as? [[String: Any]])

        let urlFilters: [String] = array.compactMap { rule in
            guard let trigger = rule["trigger"] as? [String: Any] else { return nil }
            return trigger["url-filter"] as? String
        }

        XCTAssertTrue(urlFilters.contains(where: { $0.contains("doubleclick") }))
        XCTAssertTrue(urlFilters.contains(where: { $0.contains("googlesyndication") }))
        XCTAssertTrue(urlFilters.contains(where: { $0.contains("sourcepoint") }))
    }
}
