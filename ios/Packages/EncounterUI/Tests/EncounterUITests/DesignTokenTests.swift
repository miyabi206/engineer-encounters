import XCTest
import UIKit
@testable import EncounterUI

@MainActor
final class DesignTokenTests: XCTestCase {
    func testTextTokensMeetWCAGContrastInBothAppearancesAndContrastSettings() {
        let background = EncounterPalette.backgroundUIColor
        let surface = EncounterPalette.surfaceUIColor
        // Each distinct colour pair appears once; the final colour is the actual backing surface.
        let pairs: [(String, UIColor, UIColor, UIColor)] = [
            ("ink/background", EncounterPalette.inkUIColor, background, background),
            ("ink/surface", EncounterPalette.inkUIColor, surface, background),
            ("inkSecondary/background", EncounterPalette.inkSecondaryUIColor, background, background),
            ("inkSecondary/surface", EncounterPalette.inkSecondaryUIColor, surface, background),
            ("accent/background", EncounterPalette.accentUIColor, background, background),
            ("accent/surface", EncounterPalette.accentUIColor, surface, background),
            ("onAccent/accent buttons and selected chips", EncounterPalette.onAccentUIColor, EncounterPalette.accentUIColor, surface),
            ("accent/accentSoft tags, QR, verified and visibility badges", EncounterPalette.accentUIColor, EncounterPalette.accentSoftUIColor, surface),
            ("ambient badge", EncounterPalette.ambientTextUIColor, EncounterPalette.ambientFillUIColor, surface),
            ("session badge", EncounterPalette.sessionTextUIColor, EncounterPalette.sessionFillUIColor, surface),
            ("ink/neutralFill chips, segments and unverified badges", EncounterPalette.inkUIColor, EncounterPalette.neutralFillUIColor, surface),
            ("inkSecondary/neutralFill disabled chips and rows", EncounterPalette.inkSecondaryUIColor, EncounterPalette.neutralFillUIColor, surface),
            ("inkSecondary/neutralFill disabled screen buttons", EncounterPalette.inkSecondaryUIColor, EncounterPalette.neutralFillUIColor, background),
            ("ink/accentSoft notices", EncounterPalette.inkUIColor, EncounterPalette.accentSoftUIColor, surface),
            ("ink/warningFill notices", EncounterPalette.inkUIColor, EncounterPalette.warningFillUIColor, surface),
            ("destructive/surface", EncounterPalette.destructiveUIColor, surface, background),
            ("destructive/background", EncounterPalette.destructiveUIColor, background, background),
            ("destructive/accentSoft", EncounterPalette.destructiveUIColor, EncounterPalette.accentSoftUIColor, surface)
        ]
        for traits in traitVariants {
            for (name, foreground, fill, backing) in pairs {
                let ratio = contrast(foreground, on: fill, over: backing, traits: traits)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name), \(traits): \(ratio):1")
            }
        }
    }

    func testFieldBoundaryAndUnselectedIndicatorsHaveThreeToOneContrast() {
        for traits in traitVariants {
            for surroundings in [EncounterPalette.surfaceUIColor, EncounterPalette.backgroundUIColor] {
                let ratio = contrast(EncounterPalette.controlOutlineUIColor, on: surroundings,
                                     over: EncounterPalette.backgroundUIColor, traits: traits)
                XCTAssertGreaterThanOrEqual(ratio, 3, "Field boundary and unselected checkbox/radio, \(traits): \(ratio):1")
            }
        }
    }

    func testIncreasedContrastStrengthensAccentAndControlOutline() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let normal = traits(style: style, contrast: .normal)
            let high = traits(style: style, contrast: .high)
            for token in [EncounterPalette.accentUIColor, EncounterPalette.controlOutlineUIColor] {
                let normalRatio = contrast(token, on: EncounterPalette.surfaceUIColor,
                                           over: EncounterPalette.backgroundUIColor, traits: normal)
                let highRatio = contrast(token, on: EncounterPalette.surfaceUIColor,
                                         over: EncounterPalette.backgroundUIColor, traits: high)
                XCTAssertGreaterThan(highRatio, normalRatio)
            }
        }
    }

    private var traitVariants: [UITraitCollection] {
        [UIUserInterfaceStyle.light, .dark].flatMap { style in
            [UIAccessibilityContrast.normal, .high].map { traits(style: style, contrast: $0) }
        }
    }

    private func traits(style: UIUserInterfaceStyle, contrast: UIAccessibilityContrast) -> UITraitCollection {
        UITraitCollection { mutable in
            mutable.userInterfaceStyle = style
            mutable.accessibilityContrast = contrast
        }
    }

    private func contrast(_ foreground: UIColor, on background: UIColor, over backing: UIColor,
                          traits: UITraitCollection) -> Double {
        let canvas = rgba(EncounterPalette.backgroundUIColor, traits: traits)
        let backingColor = composite(rgba(backing, traits: traits), over: canvas)
        let fill = composite(rgba(background, traits: traits), over: backingColor)
        let text = composite(rgba(foreground, traits: traits), over: fill)
        let a = luminance(text)
        let b = luminance(fill)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
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
