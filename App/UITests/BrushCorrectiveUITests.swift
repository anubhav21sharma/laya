import XCTest

@MainActor
final class BrushCorrectiveUITests: XCTestCase {
    func testEveryProfessionalCandidateRunsThroughProductionBrushLab()
        throws
    {
        let app = XCUIApplication()
        app.launch()

        app.typeKey("l", modifierFlags: [.command, .option])
        let canvas = app.descendants(matching: .any)["Brush Lab Canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))

        let professionalMatrix = app.buttons["Stage 5 Professional"]
        XCTAssertTrue(professionalMatrix.waitForExistence(timeout: 3))
        professionalMatrix.click()

        let representativeCards = [
            "builtin.professional-technical-ink.review.slowLine.standard",
            "builtin.professional-graphite-pencil.review.pressureRamp.standard",
            "builtin.professional-natural-charcoal.review.tiltSweep.standard",
            "builtin.professional-chisel-marker.review.sharpCorner.standard",
            "builtin.professional-technical-ink.review.eraserRetrace.standard",
            "builtin.professional-graphite-pencil.review.periodicSeamCrossing.standard",
            "builtin.professional-natural-charcoal.review.radialRotation.standard",
            "builtin.professional-chisel-marker.review.radialReflection.standard",
        ]

        for cardID in representativeCards {
            selectCard(cardID, app: app)
            let replay = app.buttons["Brush Lab Replay All Passes"]
            XCTAssertTrue(waitUntilEnabled(replay, timeout: 10))
            replay.click()
            XCTAssertTrue(waitUntilEnabled(replay, timeout: 20))
            XCTAssertTrue(
                app.staticTexts["Assessment pending user input"].exists
            )
        }

        for size in ["minimum": "2 px", "nominal": "20 px", "maximum": "2000 px"] {
            selectCard(
                "builtin.professional-technical-ink.review.tap.\(size.key)",
                app: app
            )
            XCTAssertTrue(app.staticTexts[size.value].waitForExistence(timeout: 5))
            let replay = app.buttons["Brush Lab Replay All Passes"]
            XCTAssertTrue(waitUntilEnabled(replay, timeout: 10))
            replay.click()
            XCTAssertTrue(waitUntilEnabled(replay, timeout: 20))
        }

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "professional-brush-lab-candidates"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func selectCard(_ cardID: String, app: XCUIApplication) {
        let menu = app.menuButtons["Brush Lab Review Card Menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        let item = app.menuItems["Brush Lab Card \(cardID)"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), cardID)
        item.click()
        XCTAssertTrue(app.staticTexts[cardID].waitForExistence(timeout: 10))
    }

    private func waitUntilEnabled(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND enabled == true")
        return XCTWaiter.wait(
            for: [expectation(for: predicate, evaluatedWith: element)],
            timeout: timeout
        ) == .completed
    }
}
