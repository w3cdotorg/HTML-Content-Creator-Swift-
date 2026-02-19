import Foundation
import XCTest
@testable import HTMLContentCreator

final class CaptureContentRuleListProviderTests: XCTestCase {
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
}
