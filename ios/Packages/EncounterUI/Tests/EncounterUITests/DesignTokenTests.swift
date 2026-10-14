import XCTest
import UIKit
@testable import EncounterUI

final class DesignTokenTests: XCTestCase {
    func testTextTokensMeetWCAGContrastInBothAppearances() {
        let pairs: [(String, UIColor, UIColor)] = [
            ("ink/background", EncounterPalette.inkUIColor, EncounterPalette.backgroundUIColor),
            ("ink/surface", EncounterPalette.inkUIColor, EncounterPalette.surfaceUIColor),
            ("inkSecondary/background", EncounterPalette.inkSecondaryUIColor, EncounterPalette.backgroundUIColor),
            ("inkSecondary/surface", EncounterPalette.inkSecondaryUIColor, EncounterPalette.surfaceUIColor),
            ("accent/background", EncounterPalette.accentUIColor, EncounterPalette.backgroundUIColor),
            ("accent/surface", EncounterPalette.accentUIColor, EncounterPalette.surfaceUIColor),
            ("onAccent/accent", EncounterPalette.onAccentUIColor, EncounterPalette.accentUIColor),
            ("accent/accentSoft", EncounterPalette.accentUIColor, EncounterPalette.accentSoftUIColor),
            ("ambient badge", EncounterPalette.ambientTextUIColor, EncounterPalette.ambientFillUIColor),
            ("session badge", EncounterPalette.sessionTextUIColor, EncounterPalette.sessionFillUIColor),
            ("QR badge", EncounterPalette.accentUIColor, EncounterPalette.accentSoftUIColor),
            ("verified badge", EncounterPalette.accentUIColor, EncounterPalette.accentSoftUIColor),
            ("unverified badge", EncounterPalette.inkUIColor, EncounterPalette.neutralFillUIColor),
            ("visibility badge", EncounterPalette.accentUIColor, EncounterPalette.accentSoftUIColor),
            ("ink/accentSoft", EncounterPalette.inkUIColor, EncounterPalette.accentSoftUIColor),
            ("ink/warningFill", EncounterPalette.inkUIColor, EncounterPalette.warningFillUIColor)
        ]
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let canvas = rgba(EncounterPalette.backgroundUIColor, traits: traits)
            for (name, foreground, background) in pairs {
                // System fills and secondary labels can have alpha; measure their displayed colour.
                let fill = composite(rgba(background, traits: traits), over: canvas)
                let text = composite(rgba(foreground, traits: traits), over: fill)
                let a = luminance(text)
                let b = luminance(fill)
                let ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name), \(style): \(ratio):1")
            }
        }
    }

    private struct RGBA {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }

    private func rgba(_ color: UIColor, traits: UITraitCollection) -> RGBA {
        let resolved = color.resolvedColor(with: traits)
        var red: CGFloat = 0; var green: CGFloat = 0; var blue: CGFloat = 0; var alpha: CGFloat = 0
        XCTAssertTrue(resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha), "Token must resolve to RGB")
        return RGBA(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
    }

    private func composite(_ foreground: RGBA, over background: RGBA) -> RGBA {
        RGBA(red: foreground.red * foreground.alpha + background.red * (1 - foreground.alpha),
             green: foreground.green * foreground.alpha + background.green * (1 - foreground.alpha),
             blue: foreground.blue * foreground.alpha + background.blue * (1 - foreground.alpha), alpha: 1)
    }

    private func luminance(_ color: RGBA) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }
}
