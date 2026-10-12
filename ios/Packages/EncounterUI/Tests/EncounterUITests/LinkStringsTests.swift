import Foundation
import XCTest
@testable import EncounterUI

final class LinkStringsTests: XCTestCase {
    func testBothLanguagesDefineEveryKeyWithNoUntrackedKeys() throws {
        let expected = Set(LinkString.allCases.map(\.rawValue))
        for language in ["ja", "en"] {
            let table = try LinkStrings.table(language: language)
            XCTAssertEqual(Set(table.keys), expected, language)
            for key in expected {
                XCTAssertFalse(try XCTUnwrap(table[key], "\(language): \(key)").isEmpty)
                XCTAssertEqual(LinkStrings.localized(key, language: language), table[key])
            }
        }
    }
    func testRetryLabelsNameEveryNonDestructiveOperation() throws {
        let repository = GitHubRepositoryChoice(repositoryID: "123", repositoryName: "repo", title: "Repo",
                                                url: URL(string: "https://github.com/owner/repo")!)
        let operations: [LinkOperation] = [.loadLinks, .loadConnection, .connect, .repositories(2),
                                           .preview(repository), .save, .reorder(["one"]), .refresh]
        let labels = operations.map(LinkStrings.retryLabel)
        XCTAssertEqual(Set(labels).count, operations.count)
        for label in labels { XCTAssertFalse(label.isEmpty); XCTAssertNotEqual(label, LinkStrings.text(.retry)) }
        for language in ["en", "ja"] {
            let table = try LinkStrings.table(language: language)
            XCTAssertNotEqual(table["readerFailure"], table["notAvailable"])
            XCTAssertNotNil(table["connectedWithoutHandle"])
        }
    }
    func testVerbatimWordingAndEveryLimitCounter() throws {
        XCTAssertEqual(LinkStrings.localized("identityWarning", language: "ja"), "ニックネームでも、外部リンクから個人が特定されることがあります")
        XCTAssertEqual(LinkStrings.localized("identityWarning", language: "en"), "External links may reveal your identity, even with a nickname.")
        XCTAssertEqual(LinkStrings.localized("chooseVisibility", language: "ja"), "公開範囲を選んでください")
        XCTAssertEqual(LinkStrings.localized("replaceEdits", language: "en"), "Replace your edits?")
        XCTAssertEqual(LinkStrings.localized("deleteExplanation", language: "en"), "The original page and copied URLs are not removed")
        for language in ["ja", "en"] {
            let table = try LinkStrings.table(language: language)
            for limit in [10, 30, 100, 200] {
                XCTAssertEqual(String(format: try XCTUnwrap(table["counter"]), limit, limit), "\(limit)/\(limit)")
                XCTAssertTrue(String(format: try XCTUnwrap(table["tooLong"]), limit).contains("\(limit)"))
            }
        }
    }
}
