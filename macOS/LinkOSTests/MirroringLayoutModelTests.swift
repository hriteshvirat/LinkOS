import XCTest
import Foundation
@testable import LinkOS

final class MirroringLayoutModelTests: XCTestCase {
    
    func testBottomDockedGeometry() {
        let phoneFrame = NSRect(x: 100, y: 100, width: 300, height: 600)
        let model = MirroringLayoutModel(
            phoneFrame: phoneFrame,
            toolbarEdge: .bottom,
            isFloating: false
        )
        
        let geometry = model.calculate()
        
        // Ensure phoneFrame is unchanged
        XCTAssertEqual(geometry.phoneFrame, phoneFrame)
        
        // Bottom toolbar matches phone frame width and toolbarThickness height
        XCTAssertEqual(geometry.toolbarFrame.width, phoneFrame.width)
        XCTAssertEqual(geometry.toolbarFrame.height, MirroringLayoutModel.toolbarThickness)
        XCTAssertEqual(geometry.toolbarFrame.origin.x, phoneFrame.minX)
    }
    
    func testDockedOffsetRetention() {
        let phoneFrame = NSRect(x: 100, y: 100, width: 400, height: 800)
        let model = MirroringLayoutModel(
            phoneFrame: phoneFrame,
            toolbarEdge: .left,
            isFloating: false,
            relativeY: 0.25
        )
        
        let geometry = model.calculate()
        
        // Left/Right toolbar has fixed height (220) and thickness width (52)
        XCTAssertEqual(geometry.toolbarFrame.width, MirroringLayoutModel.toolbarThickness)
        XCTAssertEqual(geometry.toolbarFrame.height, 220)
        
        // y position should correspond to relativeY = 0.25
        let expectedHeight: CGFloat = 220
        let minYBound = phoneFrame.minY + expectedHeight / 2.0
        let maxYBound = phoneFrame.maxY - expectedHeight / 2.0
        let targetY = phoneFrame.minY + (phoneFrame.height * 0.25)
        let clampedY = max(minYBound, min(maxYBound, targetY))
        let expectedMinY = clampedY - expectedHeight / 2.0
        
        XCTAssertEqual(geometry.toolbarFrame.origin.y, expectedMinY, accuracy: 0.01)
    }
    
    func testInteractionRegionUnion() {
        let phoneFrame = NSRect(x: 100, y: 100, width: 300, height: 600)
        let popupFrame = NSRect(x: 150, y: 60, width: 200, height: 150)
        let model = MirroringLayoutModel(
            phoneFrame: phoneFrame,
            toolbarEdge: .bottom,
            isFloating: false,
            popupFrame: popupFrame
        )
        
        let geometry = model.calculate()
        
        // Verify points within phone frame, toolbar frame, and popup frame return true for intersection
        XCTAssertTrue(geometry.contains(screenPoint: NSPoint(x: 150, y: 200))) // Inside phone window
        XCTAssertTrue(geometry.contains(screenPoint: NSPoint(x: 160, y: 80)))  // Inside popup window / toolbar area
        XCTAssertFalse(geometry.contains(screenPoint: NSPoint(x: 500, y: 500))) // Outside everything
    }
}
