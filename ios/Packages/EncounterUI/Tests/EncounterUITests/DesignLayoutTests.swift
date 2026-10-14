import XCTest
import SwiftUI
@testable import EncounterUI

final class DesignLayoutTests: XCTestCase {
    func testWrapsAtAvailableWidthAndUsesTallestItemInEachRow() {
        let result = EncounterFlowLayout.arrange([
            CGSize(width: 60, height: 20), CGSize(width: 40, height: 30), CGSize(width: 40, height: 10)
        ], proposedWidth: 100)
        XCTAssertEqual(result.origins, [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 28), CGPoint(x: 48, y: 28)])
        XCTAssertEqual(result.size, CGSize(width: 88, height: 58))
    }

    func testExactWidthFitsAndSpacingHasNoTrailingGap() {
        let result = EncounterFlowLayout.arrange([
            CGSize(width: 40, height: 10), CGSize(width: 52, height: 20), CGSize(width: 33, height: 25)
        ], proposedWidth: 100)
        XCTAssertEqual(result.origins, [CGPoint(x: 0, y: 0), CGPoint(x: 48, y: 0), CGPoint(x: 0, y: 28)])
        XCTAssertEqual(result.size, CGSize(width: 100, height: 53))
    }

    func testItemsNeverOverlapAndRespectCustomSpacing() {
        let result = EncounterFlowLayout.arrange([
            CGSize(width: 50, height: 10), CGSize(width: 60, height: 30), CGSize(width: 20, height: 20),
            CGSize(width: 90, height: 15), CGSize(width: 160, height: 40), CGSize(width: 60, height: 25)
        ], proposedWidth: 128, spacing: 10)
        let frames = zip(result.origins, result.sizes).map { CGRect(origin: $0.0, size: $0.1) }
        for index in frames.indices {
            XCTAssertLessThanOrEqual(frames[index].maxX, 128)
            XCTAssertGreaterThanOrEqual(frames[index].minX, 0)
            for next in frames.indices where next > index {
                XCTAssertFalse(frames[index].intersects(frames[next]), "Items \(index) and \(next) overlap")
            }
            if index > 0 {
                let previous = frames[index - 1]
                if previous.minY == frames[index].minY {
                    XCTAssertEqual(frames[index].minX - previous.maxX, 10)
                } else {
                    let previousRow = frames.prefix(index).filter { $0.minY == previous.minY }
                    XCTAssertEqual(frames[index].minY - previousRow.map(\.maxY).max()!, 10)
                }
            }
        }
    }

    func testNilAndInfiniteProposalsUseFiniteNaturalWidth() {
        let sizes = [CGSize(width: 30, height: 10), CGSize(width: 50, height: 20), CGSize(width: 40, height: 15)]
        for proposal in [CGFloat?.none, .some(.infinity)] {
            let result = EncounterFlowLayout.arrange(sizes, proposedWidth: proposal, spacing: 6)
            XCTAssertEqual(result.origins, [CGPoint(x: 0, y: 0), CGPoint(x: 36, y: 0), CGPoint(x: 92, y: 0)])
            XCTAssertEqual(result.size, CGSize(width: 132, height: 20))
            XCTAssertTrue(result.size.width.isFinite)
        }
    }

    func testZeroSubviewsHaveZeroSizeForEveryProposal() {
        for proposal in [CGFloat?.none, .some(.infinity), .some(0), .some(100)] {
            let result = EncounterFlowLayout.arrange([], proposedWidth: proposal)
            XCTAssertEqual(result.size, .zero)
            XCTAssertTrue(result.origins.isEmpty)
            XCTAssertTrue(result.sizes.isEmpty)
        }
    }

    func testAccessibilityPlacesExactlyOneItemPerRow() {
        let result = EncounterFlowLayout.arrange([
            CGSize(width: 20, height: 10), CGSize(width: 30, height: 20), CGSize(width: 40, height: 15)
        ], proposedWidth: 100, spacing: 6, isAccessibilitySize: true)
        XCTAssertEqual(result.origins, [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16), CGPoint(x: 0, y: 42)])
        XCTAssertEqual(result.sizes.map(\.width), [100, 100, 100])
        XCTAssertEqual(result.size, CGSize(width: 100, height: 57))
    }

    func testAccessibilityUnboundedWidthUsesWidestItem() {
        for proposal in [CGFloat?.none, .some(.infinity)] {
            let result = EncounterFlowLayout.arrange([
                CGSize(width: 20, height: 10), CGSize(width: 40, height: 15)
            ], proposedWidth: proposal, isAccessibilitySize: true)
            XCTAssertEqual(result.size, CGSize(width: 40, height: 33))
            XCTAssertEqual(result.origins, [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 18)])
        }
    }

    func testOversizedItemsAreConstrainedAndZeroWidthStaysFinite() {
        let sizes = [CGSize(width: 120, height: 10), CGSize(width: 10, height: 20)]
        let narrow = EncounterFlowLayout.arrange(sizes, proposedWidth: 40)
        XCTAssertEqual(narrow.sizes.map(\.width), [40, 10])
        XCTAssertEqual(narrow.origins, [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 18)])
        let zero = EncounterFlowLayout.arrange(sizes, proposedWidth: 0)
        XCTAssertEqual(zero.size, CGSize(width: 0, height: 38))
        XCTAssertEqual(zero.sizes.map(\.width), [0, 0])
    }
}
