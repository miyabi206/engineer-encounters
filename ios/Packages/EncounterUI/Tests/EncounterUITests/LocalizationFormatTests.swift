import Foundation
import XCTest
@testable import EncounterUI

final class LocalizationFormatTests: XCTestCase {
    func testFormatSpecifiersMatchForEveryJapaneseAndEnglishKey() throws {
        for tables in [
            (try OnboardingStrings.table(language: "ja"), try OnboardingStrings.table(language: "en")),
            (try SettingsStrings.table(language: "ja"), try SettingsStrings.table(language: "en")),
            (try LinkStrings.table(language: "ja"), try LinkStrings.table(language: "en")),
            (try DiscoverStrings.table(language: "ja"), try DiscoverStrings.table(language: "en")),
            (try SessionStrings.table(language: "ja"), try SessionStrings.table(language: "en")),
            (try MyCardStrings.table(language: "ja"), try MyCardStrings.table(language: "en")),
            (try ReportSettingsStrings.table(language: "ja"), try ReportSettingsStrings.table(language: "en")),
            (try SafetyStrings.table(language: "ja"), try SafetyStrings.table(language: "en")),
            (try AccountSettingsStrings.table(language: "ja"), try AccountSettingsStrings.table(language: "en")),
            (try LegalStrings.table(language: "ja"), try LegalStrings.table(language: "en")),
            (try MyCardStrings.table(language: "ja", name: "Localizable"),
             try MyCardStrings.table(language: "en", name: "Localizable")),
            (try interestTable(language: "ja"), try interestTable(language: "en"))
        ] {
            XCTAssertEqual(Set(tables.0.keys), Set(tables.1.keys))
            for key in tables.0.keys {
                XCTAssertEqual(try specifiers(XCTUnwrap(tables.0[key])),
                               try specifiers(XCTUnwrap(tables.1[key])), key)
            }
        }
        for key in ["welcome.title", "welcome.introduction"] {
            XCTAssertEqual(try specifiers(XCTUnwrap(WelcomeStrings.localized(key, language: "ja"))),
                           try specifiers(XCTUnwrap(WelcomeStrings.localized(key, language: "en"))), key)
        }
    }

    private func interestTable(language: String) throws -> [String: String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Interests", withExtension: "strings",
                                                  subdirectory: nil, localization: language))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
            as? [String: String])
    }

    func testLocalizedSeparatorsLimitsAndDeniedBluetoothWording() throws {
        for language in ["ja", "en"] {
            let onboarding = try OnboardingStrings.table(language: language)
            let settings = try SettingsStrings.table(language: language)
            for table in [onboarding, settings] {
                XCTAssertEqual(try specifiers(XCTUnwrap(table["interestLimit"])), ["%ld"])
                XCTAssertTrue(String(format: try XCTUnwrap(table["interestLimit"]), 7).contains("7"))
                XCTAssertEqual(String(format: try XCTUnwrap(table["labelStatus"]), "Name", "Status"), "Name · Status")
                XCTAssertTrue(String(format: try XCTUnwrap(table["fieldMessage"]), "Name", "Error").contains("Error"))
                XCTAssertFalse(table.keys.contains("interestIOS"))
            }
        }
        XCTAssertEqual(OnboardingStrings.localized("bluetoothDenied", language: "en"), "Bluetooth permission is denied")
        XCTAssertEqual(SettingsStrings.localized("bluetoothDenied", language: "en"), "Bluetooth permission is denied")
        XCTAssertEqual(InterimProfileInterests.Label.allCases.count, 6)
        for option in InterimProfileInterests.options {
            XCTAssertFalse(option.labelJapanese.hasPrefix("interest"))
            XCTAssertFalse(option.labelEnglish.hasPrefix("interest"))
        }
    }

    private func specifiers(_ value: String) throws -> [String] {
        let pattern = #"%(?:[0-9]+\$)?[-+ #0]*(?:[0-9]+|\*)?(?:\.(?:[0-9]+|\*))?(?:hh|ll|[hlLzjt])?[@diuoxXfFeEgGaAcCsSp%]"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap {
            guard let range = Range($0.range, in: value) else { return nil }
            let token = String(value[range])
            return token == "%%" ? nil : token
        }
    }
}
