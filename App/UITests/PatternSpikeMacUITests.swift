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

    func testEveryAnchorDrawsAndEraserNeverPaints() {
        let app = XCUIApplication()
        app.launch()

        let canvas = app.descendants(matching: .any)["Pattern Canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let anchor = app.popUpButtons["Brush Anchor"]
        XCTAssertTrue(anchor.waitForExistence(timeout: 2))

        let names = [
            "Technical Ink",
            "Dry Pencil",
            "Glaze Marker",
            "Bounded Wash",
        ]
        for (index, name) in names.enumerated() {
            select(name, in: anchor, app: app)
            XCTAssertEqual(anchor.value as? String, name)

            let y = CGFloat(0.3) + CGFloat(index) * 0.13
            drag(
                canvas,
                from: CGVector(dx: 0.35, dy: y),
                to: CGVector(dx: 0.58, dy: y)
            )
            XCTAssertTrue(waitUntilEnabled(app.buttons["Undo"]))

            let erase = app.buttons["Erase"]
            erase.click()
            XCTAssertTrue(erase.isSelected)
            drag(
                canvas,
                from: CGVector(dx: 0.52, dy: y),
                to: CGVector(dx: 0.43, dy: y)
            )
            XCTAssertTrue(waitUntilEnabled(app.buttons["Undo"]))

            let draw = app.buttons["Draw"]
            draw.click()
            XCTAssertTrue(draw.isSelected)
            XCTAssertEqual(anchor.value as? String, name)
        }
    }

    func testCursorShortcutsFocusUndoRedoAndDebugHUD() {
        let app = XCUIApplication()
        app.launch()

        let canvas = app.descendants(matching: .any)["Pattern Canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let hoverPoint = canvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        hoverPoint.hover()

        let cursor = app.images["Brush Cursor"]
        XCTAssertTrue(cursor.waitForExistence(timeout: 2))
        XCTAssertEqual(cursor.value as? String, "20 px")
        XCTAssertEqual(cursor.frame.midX, hoverPoint.screenPoint.x, accuracy: 2)
        XCTAssertEqual(cursor.frame.midY, hoverPoint.screenPoint.y, accuracy: 2)
        XCTAssertEqual(cursor.frame.width, 20, accuracy: 2)
        XCTAssertEqual(cursor.frame.height, 20, accuracy: 2)

        app.buttons["Increase Brush Size"].click()
        hoverPoint.hover()
        XCTAssertEqual(cursor.value as? String, "25 px")
        XCTAssertEqual(cursor.frame.width, 25, accuracy: 2)

        app.typeKey("~", modifierFlags: [])
        let hud = app.descendants(matching: .any)["Debug Performance HUD"]
        XCTAssertTrue(hud.waitForExistence(timeout: 2))
        app.typeKey("~", modifierFlags: [])
        XCTAssertTrue(hud.waitForNonExistence(timeout: 2))

        app.typeKey("g", modifierFlags: [])
        let showGrid = app.descendants(matching: .any)["Show Grid"]
        XCTAssertEqual(showGrid.value as? String, "1")
        app.typeKey("7", modifierFlags: [])
        XCTAssertEqual(app.popUpButtons["Tiling"].value as? String, "Rotational")

        drag(
            canvas,
            from: CGVector(dx: 0.42, dy: 0.48),
            to: CGVector(dx: 0.58, dy: 0.52)
        )
        let undo = app.buttons["Undo"]
        let redo = app.buttons["Redo"]
        XCTAssertTrue(waitUntilEnabled(undo))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitUntilEnabled(redo))
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntilEnabled(undo))
    }

    private func select(
        _ name: String,
        in picker: XCUIElement,
        app: XCUIApplication
    ) {
        picker.click()
        let item = app.menuItems[name]
        XCTAssertTrue(item.waitForExistence(timeout: 2))
        item.click()
    }

    private func drag(
        _ canvas: XCUIElement,
        from start: CGVector,
        to end: CGVector
    ) {
        canvas.coordinate(withNormalizedOffset: start).press(
            forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: end)
        )
    }

    private func waitUntilEnabled(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }
}
