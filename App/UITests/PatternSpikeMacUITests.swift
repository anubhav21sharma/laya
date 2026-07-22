import XCTest

@MainActor
final class PatternSpikeMacUITests: XCTestCase {
    func testBrushChangeKeepsEditorSessionCoherent() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["20 px"].waitForExistence(timeout: 5))

        let increaseBrush = app.buttons["Increase Brush Size"]
        XCTAssertTrue(increaseBrush.isEnabled)
        increaseBrush.click()

        XCTAssertTrue(app.staticTexts["25 px"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Clear Canvas"].isEnabled)

        let canvas = app.descendants(matching: .any)["Pattern Canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 2))
        let strokeStart = canvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)
        )
        let strokeEnd = canvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)
        )
        strokeStart.press(forDuration: 0.05, thenDragTo: strokeEnd)

        let undo = app.buttons["Undo"]
        XCTAssertTrue(waitUntilEnabled(undo))

        let erase = app.buttons["Erase"]
        erase.click()
        XCTAssertTrue(erase.isSelected)
        strokeEnd.press(forDuration: 0.05, thenDragTo: strokeStart)

        let showGrid = app.descendants(matching: .any)["Show Grid"]
        XCTAssertTrue(showGrid.isEnabled)
        showGrid.click()
        XCTAssertEqual(showGrid.value as? String, "1")

        let tiling = app.popUpButtons["Tiling"]
        XCTAssertTrue(tiling.isEnabled)
        tiling.click()
        app.menuItems["Half Drop"].click()
        XCTAssertEqual(tiling.value as? String, "Half Drop")

        XCTAssertTrue(app.staticTexts["25 px"].exists)
        XCTAssertTrue(erase.isSelected)
        let clear = app.buttons["Clear Canvas"]
        XCTAssertTrue(clear.isEnabled)
        clear.click()
        XCTAssertTrue(waitUntilEnabled(clear))
    }

    private func waitUntilEnabled(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }
}
