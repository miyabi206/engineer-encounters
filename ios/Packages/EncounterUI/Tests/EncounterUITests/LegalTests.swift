import XCTest
@testable import EncounterUI

final class LegalTests: XCTestCase {
    func testAbsentLegalLinksAndBlankContactAreOmittedWithoutInventedDefaults() throws {
        let empty = LegalData()
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertNil(empty.contact)
        XCTAssertNil(empty.version)
        let terms = try XCTUnwrap(URL(string: "https://example.com/terms"))
        let support = try XCTUnwrap(URL(string: "https://example.com/support"))
        let data = LegalData(terms: terms, support: support, moderationContact: " \n ")
        XCTAssertEqual(data.entries, [.terms, .support])
        XCTAssertEqual(data.url(for: .terms), terms)
        XCTAssertNil(data.url(for: .privacy))
        XCTAssertNil(data.contact)
    }

    @MainActor
    func testMissingEntriesNeverInvokeExternalActions() async {
        var calls = 0
        let model = LegalModel(data: .init(), actions: .init(open: { _ in calls += 1 },
            contact: { _ in calls += 1 }, copy: { _ in calls += 1 }), navigation: .init(back: {}))
        for entry in LegalEntry.allCases { await model.open(entry) }
        await model.contact(); await model.copy(); await model.retry()
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testEachFailedExternalOperationPreservesExactTargetForRetry() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/privacy"))
        let address = "support@example.com"
        for operation in [LegalOperation.open(url), .contact(address), .copy(address)] {
            var fails = true
            var received: [LegalOperation] = []
            let model = LegalModel(data: .init(privacy: url, moderationContact: address), actions: .init(open: {
                received.append(.open($0))
                if fails { throw ProfileActionError(code: .unavailable) }
            }, contact: {
                received.append(.contact($0))
                if fails { throw ProfileActionError(code: .unavailable) }
            }, copy: {
                received.append(.copy($0))
                if fails { throw ProfileActionError(code: .unavailable) }
            }), navigation: .init(back: {}))
            switch operation {
            case .open: await model.open(.privacy)
            case .contact: await model.contact()
            case .copy: await model.copy()
            }
            XCTAssertEqual(model.failedOperation, operation)
            fails = false
            await model.retry()
            XCTAssertEqual(received, [operation, operation])
            XCTAssertNil(model.failedOperation)
            XCTAssertFalse(model.isBusy)
        }
    }

    @MainActor
    func testPendingExternalActionDisablesRepeatedActionsAndBack() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/terms"))
        var calls: [String] = []
        var duringOpen: (@MainActor () async -> Void)?
        let model = LegalModel(data: .init(terms: url, moderationContact: "support@example.com"), actions: .init(open: { _ in
            calls.append("open"); await duringOpen?()
        }, contact: { _ in calls.append("contact") }, copy: { _ in calls.append("copy") }),
        navigation: .init(back: { calls.append("back") }))
        duringOpen = {
            XCTAssertTrue(model.isBusy)
            await model.open(.terms); await model.contact(); await model.copy(); model.back()
        }
        await model.open(.terms)
        XCTAssertEqual(calls, ["open"])
        model.back()
        XCTAssertEqual(calls, ["open", "back"])
    }
}

final class LegalStringsTests: XCTestCase {
    func testBothLanguagesDefineEveryKey() throws {
        for language in ["ja", "en"] {
            let table = try LegalStrings.table(language: language)
            XCTAssertEqual(Set(table.keys), Set(LegalString.allCases.map(\.rawValue)))
            for key in LegalString.allCases {
                let value = try XCTUnwrap(table[key.rawValue])
                XCTAssertFalse(value.isEmpty)
                XCTAssertEqual(LegalStrings.localized(key.rawValue, language: language), value)
            }
        }
        XCTAssertEqual(LegalStrings.localized("moderationContact", language: "ja"), "通報に関するお問い合わせ")
    }
}
