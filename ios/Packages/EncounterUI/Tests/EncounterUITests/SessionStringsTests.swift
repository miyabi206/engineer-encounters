import XCTest
@testable import EncounterUI

final class SessionStringsTests: XCTestCase {
    func testBothLanguagesDefineEveryKeyWithoutUntrackedKeys() throws {
        let expected = Set(SessionString.allCases.map(\.rawValue))
        for language in ["ja", "en"] {
            let table = try SessionStrings.table(language: language)
            XCTAssertEqual(Set(table.keys), expected, language)
            for key in SessionString.allCases {
                XCTAssertFalse(try XCTUnwrap(table[key.rawValue]).isEmpty)
                XCTAssertEqual(SessionStrings.localized(key, language: language), table[key.rawValue])
            }
            let format = try XCTUnwrap(table["remainingFormat"])
            XCTAssertEqual(String(format: format, "label", "1:59:00"), "label: 1:59:00")
        }
    }

    func testVerbatimS08AndS09WordingInBothLanguages() {
        let wording: [(SessionString, String, String)] = [
            (.session, "セッション", "Session"),
            (.active, "セッション中", "Session active"),
            (.timeRemaining, "残り時間", "Time remaining"),
            (.twoHours, "最大2時間", "Lasts up to 2 hours"),
            (.bothInSession, "2人ともセッション中なら、確認後すぐに表示されます。", "When both people are in a session, encounters appear immediately after confirmation."),
            (.oneInSession, "片方だけがセッション中の場合は、2分以上のすれちがいが毎日のレポートで届きます。", "If only one person is in a session, encounters require 2 minutes and appear in the daily report."),
            (.stop, "セッションを停止", "Stop session"),
            (.noEncounters, "まだセッションでのすれちがいはありません", "No session encounters yet"),
            (.ended, "セッションが終了しました", "Session ended"),
            (.startOffline, "セッションを開始するにはネット接続が必要です", "Connect to start a session"),
            (.stopPending, "セッションは停止しました。接続が戻ると停止を送信します", "Session stopped. The stop will sync when connected"),
            (.done, "完了", "Done"),
            (.qrExchange, "QR交換", "QR exchange"),
            (.showCode, "コードを表示", "Show code"),
            (.scanCode, "コードを読み取る", "Scan code"),
            (.refreshCode, "コードを更新", "Refresh code"),
            (.allowCamera, "カメラを許可", "Allow camera"),
            (.confirming, "確認中…", "Confirming…"),
            (.expired, "コードの有効期限が切れました", "This code has expired"),
            (.alreadyUsed, "このコードは使用済みです", "This code has already been used"),
            (.validity, "コードは2分間有効です", "This code is valid for 2 minutes"),
            (.invalidatesPrevious, "更新すると前のコードは使えなくなります", "Refreshing invalidates the previous code"),
            (.selfScan, "自分のコードは読み取れません", "You cannot scan your own code"),
            (.qrNetwork, "QR交換にはネット接続が必要です", "Connect to exchange QR codes"),
            (.unreadable, "コードを読み取れませんでした", "Could not read this code"),
            (.confirmed, "確認後、すぐに表示されます", "Confirmed exchanges appear immediately"),
            (.openSettings, "iOSの設定を開く", "Open iOS Settings")
        ]
        for (key, ja, en) in wording {
            XCTAssertEqual(SessionStrings.localized(key, language: "ja"), ja)
            XCTAssertEqual(SessionStrings.localized(key, language: "en"), en)
        }
    }
}
