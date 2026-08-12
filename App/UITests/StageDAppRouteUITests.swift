import CoreGraphics
import Foundation
import XCTest

@MainActor
final class StageDAppRouteUITests: XCTestCase {
    private var evidenceApp: XCUIApplication?
    private var recordedRows: [String: [String: Any]] = [:]

    func testProductionControlsShortcutsAndPersistenceWriteEvidence() throws {
        let commit = try acceptanceCommit()
        let manifestPath = try acceptanceArtifactPath(
            "STAGE_D_ACCEPTANCE_MANIFEST"
        )
        let projectPath = try acceptanceArtifactPath(
            "STAGE_D_ACCEPTANCE_PROJECT"
        )
        let exportPath = try acceptanceArtifactPath(
            "STAGE_D_ACCEPTANCE_EXPORT"
        )
        let generatedAt = try acceptanceEnvironmentValue(
            "STAGE_D_ACCEPTANCE_DATE"
        )

        let app = XCUIApplication()
        evidenceApp = app
        recordedRows = [:]
        app.launchEnvironment = [
            "STAGE_D_ACCEPTANCE_MANIFEST":
                manifestPath,
            "STAGE_D_ACCEPTANCE_PROJECT":
                projectPath,
            "STAGE_D_ACCEPTANCE_EXPORT":
                exportPath,
            "STAGE_D_ACCEPTANCE_COMMIT": commit,
            "STAGE_D_ACCEPTANCE_DATE": generatedAt,
        ]
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
        ]
        app.launch()

        let brushLabWindow = app.windows["Brush Lab"]
        if brushLabWindow.waitForExistence(timeout: 1) {
            let close = brushLabWindow.buttons[XCUIIdentifierCloseWindow]
            if close.exists { close.click() }
        }
        let mainWindow = app.windows["PatternSpike"]
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 30))
        let canvas = mainWindow.descendants(matching: .any)["Pattern Canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 30))
        record(
            scenario: "stage-d.app.controls",
            route: "controls.initial"
        )

        app.buttons["Increase Brush Size"].click()
        XCTAssertTrue(app.staticTexts["25 px"].waitForExistence(timeout: 2))
        record(
            scenario: "stage-d.app.controls",
            route: "controls.brush-size"
        )
        let anchor = app.popUpButtons["Brush Anchor"]
        select("Native Dry Media", in: anchor, app: app)
        XCTAssertEqual(anchor.value as? String, "Native Dry Media")
        record(
            scenario: "stage-d.app.controls",
            route: "controls.brush-selection"
        )

        let inkPreset = app.menuButtons["Ink Color Preset"]
        XCTAssertTrue(inkPreset.waitForExistence(timeout: 2))
        inkPreset.click()
        let deepTeal = app.menuItems["Deep Teal"]
        XCTAssertTrue(deepTeal.waitForExistence(timeout: 2))
        deepTeal.click()
        XCTAssertEqual(inkPreset.value as? String, "10738cff")
        record(
            scenario: "stage-d.app.controls",
            route: "controls.ink-color"
        )

        drag(
            canvas,
            from: CGVector(dx: 0.42, dy: 0.46),
            to: CGVector(dx: 0.58, dy: 0.54)
        )
        _ = waitUntilEnabled(app.buttons["Undo"])
        record(
            scenario: "stage-d.app.controls",
            route: "controls.draw"
        )
        var drawn = attributes(for: "stage-d.app.controls")
        if integer(drawn, "normalizedInputCount") == 0 {
            drag(
                canvas,
                from: CGVector(dx: 0.42, dy: 0.46),
                to: CGVector(dx: 0.58, dy: 0.54)
            )
            _ = waitUntilEnabled(app.buttons["Undo"])
            rerecord(
                scenario: "stage-d.app.controls",
                route: "controls.draw"
            )
            drawn = attributes(for: "stage-d.app.controls")
        }
        XCTAssertTrue(
            waitUntilEnabled(app.buttons["Undo"]),
            rendererErrorDescription(in: app)
        )
        XCTAssertGreaterThan(integer(drawn, "paintedPixelCount"), 0)
        XCTAssertGreaterThan(integer(drawn, "normalizedInputCount"), 0)
        app.buttons["Erase"].click()
        record(
            scenario: "stage-d.app.controls",
            route: "controls.erase-tool"
        )
        XCTAssertEqual(
            attributes(for: "stage-d.app.controls")["tool"] as? String,
            "erase"
        )
        drag(
            canvas,
            from: CGVector(dx: 0.54, dy: 0.5),
            to: CGVector(dx: 0.48, dy: 0.5)
        )
        record(
            scenario: "stage-d.app.controls",
            route: "controls.erase"
        )
        var erased = attributes(for: "stage-d.app.controls")
        if integer(erased, "normalizedInputCount")
            == integer(drawn, "normalizedInputCount")
        {
            drag(
                canvas,
                from: CGVector(dx: 0.54, dy: 0.5),
                to: CGVector(dx: 0.48, dy: 0.5)
            )
            rerecord(
                scenario: "stage-d.app.controls",
                route: "controls.erase"
            )
            erased = attributes(for: "stage-d.app.controls")
        }
        XCTAssertGreaterThan(
            integer(erased, "normalizedInputCount"),
            integer(drawn, "normalizedInputCount")
        )

        app.buttons["Undo"].click()
        record(
            scenario: "stage-d.app.controls",
            route: "controls.undo-erase"
        )
        XCTAssertTrue(waitUntilEnabled(app.buttons["Redo"]))
        app.buttons["Redo"].click()
        XCTAssertTrue(waitUntilEnabled(app.buttons["Undo"]))
        record(
            scenario: "stage-d.app.controls",
            route: "controls.redo-erase"
        )
        app.buttons["Add Layer"].click()
        XCTAssertEqual(app.popUpButtons["Active Layer"].value as? String, "Layer 2")
        record(
            scenario: "stage-d.app.controls",
            route: "controls.layer-add"
        )
        app.buttons["Lock Layer 2"].click()
        XCTAssertTrue(app.buttons["Unlock Layer 2"].waitForExistence(timeout: 2))
        record(
            scenario: "stage-d.app.controls",
            route: "controls.layer-lock"
        )
        app.buttons["Unlock Layer 2"].click()
        XCTAssertTrue(app.buttons["Lock Layer 2"].waitForExistence(timeout: 2))
        record(
            scenario: "stage-d.app.controls",
            route: "controls.layer-unlock"
        )
        app.buttons["Hide Layer 2"].click()
        XCTAssertTrue(app.buttons["Show Layer 2"].waitForExistence(timeout: 2))
        record(
            scenario: "stage-d.app.controls",
            route: "controls.layer-hide"
        )
        app.buttons["Show Layer 2"].click()
        XCTAssertTrue(app.buttons["Hide Layer 2"].waitForExistence(timeout: 2))
        record(
            scenario: "stage-d.app.controls",
            route: "controls.layer-show"
        )
        select(
            "Layer 1",
            in: app.popUpButtons["Active Layer"],
            app: app
        )
        record(
            scenario: "stage-d.app.controls",
            route: "controls.layer-select-painted"
        )

        app.buttons["Clear Canvas"].click()
        XCTAssertTrue(waitUntilEnabled(app.buttons["Clear Canvas"]))
        record(
            scenario: "stage-d.app.controls",
            route: "controls.clear-painted-layer"
        )
        let cleared = attributes(for: "stage-d.app.controls")
        XCTAssertEqual(integer(cleared, "paintedPixelCount"), 0)
        app.buttons["Undo"].click()
        XCTAssertTrue(waitUntilEnabled(app.buttons["Redo"]))
        record(
            scenario: "stage-d.app.controls",
            route: "controls.undo-clear-restores"
        )
        let restored = attributes(for: "stage-d.app.controls")
        XCTAssertGreaterThan(integer(restored, "paintedPixelCount"), 0)
        let tiling = app.popUpButtons["Tiling"]
        select("Half Drop", in: tiling, app: app)
        XCTAssertEqual(tiling.value as? String, "Half Drop")
        record(
            scenario: "stage-d.app.controls",
            route: "controls.mode-half-drop"
        )
        replaceText(in: app.textFields["Tile Width"], with: "320")
        replaceText(in: app.textFields["Tile Height"], with: "192")
        app.buttons["Apply Size"].click()
        XCTAssertTrue(waitForValue(app.textFields["Tile Width"], "320"))
        XCTAssertTrue(waitForValue(app.textFields["Tile Height"], "192"))
        record(
            scenario: "stage-d.app.controls",
            route: "controls.resize"
        )
        let resized = attributes(for: "stage-d.app.controls")
        XCTAssertGreaterThan(integer(resized, "paintedPixelCount"), 0)

        XCTAssertTrue(toggleHUD(in: app, to: "visible"))
        record(
            scenario: "stage-d.app.shortcuts",
            route: "shortcuts.hud-show"
        )
        XCTAssertTrue(toggleHUD(in: app, to: "hidden"))
        record(
            scenario: "stage-d.app.shortcuts",
            route: "shortcuts.hud-hide"
        )
        app.typeKey("g", modifierFlags: [])
        XCTAssertEqual(
            (app.checkBoxes["Show Grid"].value as? NSNumber)?.intValue,
            1
        )
        record(
            scenario: "stage-d.app.shortcuts",
            route: "shortcuts.grid"
        )
        app.typeKey("7", modifierFlags: [])
        XCTAssertEqual(tiling.value as? String, "Rotational")
        record(
            scenario: "stage-d.app.shortcuts",
            route: "shortcuts.mode"
        )
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitUntilEnabled(app.buttons["Redo"]))
        record(
            scenario: "stage-d.app.shortcuts",
            route: "shortcuts.undo"
        )
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntilEnabled(app.buttons["Undo"]))
        record(
            scenario: "stage-d.app.shortcuts",
            route: "shortcuts.redo"
        )

        let tilingBeforeFieldInput = tiling.value as? String
        replaceText(in: app.textFields["Tile Width"], with: "321")
        app.typeKey("7", modifierFlags: [])
        XCTAssertEqual(tiling.value as? String, tilingBeforeFieldInput)
        XCTAssertEqual(app.textFields["Tile Width"].value as? String, "3217")
        record(
            scenario: "stage-d.app.shortcuts",
            route: "shortcuts.numeric-field-owns-digit"
        )

        let saveGeneration = fileOperationGeneration(in: app)
        app.buttons["Save Project"].click()
        XCTAssertTrue(
            waitForFileOperation(after: saveGeneration, in: app),
            fileErrorDescription(in: app)
        )
        XCTAssertFalse(
            app.staticTexts["File Error"].exists,
            fileErrorDescription(in: app)
        )
        record(
            scenario: "stage-d.app.persistence",
            route: "persistence.save"
        )
        let saved = attributes(for: "stage-d.app.persistence")
        XCTAssertGreaterThan(integer(saved, "paintedPixelCount"), 0)
        XCTAssertGreaterThan(integer(saved, "projectFileBytes"), 0)
        XCTAssertEqual(saved["canUndo"] as? String, "true")
        XCTAssertEqual(saved["canRedo"] as? String, "false")

        replaceText(in: app.textFields["Tile Width"], with: "256")
        replaceText(in: app.textFields["Tile Height"], with: "256")
        app.buttons["Apply Size"].click()
        XCTAssertTrue(waitForValue(app.textFields["Tile Width"], "256"))
        let openGeneration = fileOperationGeneration(in: app)
        app.buttons["Open Project"].click()
        XCTAssertTrue(
            waitForFileOperation(after: openGeneration, in: app),
            fileErrorDescription(in: app)
        )
        XCTAssertFalse(
            app.staticTexts["File Error"].exists,
            fileErrorDescription(in: app)
        )
        XCTAssertTrue(waitForValue(app.textFields["Tile Width"], "320"))
        XCTAssertTrue(waitForValue(app.textFields["Tile Height"], "192"))
        record(
            scenario: "stage-d.app.persistence",
            route: "persistence.open-atomic-replacement"
        )
        let opened = attributes(for: "stage-d.app.persistence")
        assertPersistentState(saved, equals: opened)
        XCTAssertEqual(opened["canUndo"] as? String, "false")
        XCTAssertEqual(opened["canRedo"] as? String, "false")

        let exportGeneration = fileOperationGeneration(in: app)
        app.buttons["Export PNG"].click()
        XCTAssertTrue(
            waitForFileOperation(after: exportGeneration, in: app),
            fileErrorDescription(in: app)
        )
        XCTAssertFalse(
            app.staticTexts["File Error"].exists,
            fileErrorDescription(in: app)
        )
        record(
            scenario: "stage-d.app.persistence",
            route: "persistence.flattened-png-export"
        )
        let exported = attributes(for: "stage-d.app.persistence")
        assertPersistentState(opened, equals: exported)
        XCTAssertGreaterThan(integer(exported, "exportFileBytes"), 0)
        XCTAssertEqual(
            exported["exportFilePrefixHex"] as? String,
            "89504e470d0a1a0a"
        )
        XCTAssertEqual(
            exported["exportedPNGDecodedBGRA8SHA256"] as? String,
            exported["flattenedBGRA8SHA256"] as? String
        )
        XCTAssertEqual(recordedRows.keys.sorted(), [
            "stage-d.app.controls",
            "stage-d.app.persistence",
            "stage-d.app.shortcuts",
        ])
        for row in recordedRows.values {
            XCTAssertEqual(row["status"] as? String, "passed")
        }
        XCTAssertTrue(app.buttons["Delete Active Layer"].isEnabled)
        let summary = try JSONSerialization.data(
            withJSONObject: recordedRows,
            options: [.prettyPrinted, .sortedKeys]
        )
        let attachment = XCTAttachment(data: summary, uniformTypeIdentifier: "public.json")
        attachment.name = "app-route-row-summary.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func record(
        scenario: String,
        route: String
    ) {
        record(
            scenario: scenario,
            route: route,
            buttonIdentifier: "Record Next Stage D Route"
        )
    }

    private func rerecord(
        scenario: String,
        route: String
    ) {
        record(
            scenario: scenario,
            route: route,
            buttonIdentifier: "Rerecord Last Stage D Route"
        )
    }

    private func record(
        scenario: String,
        route: String,
        buttonIdentifier: String
    ) {
        guard let app = evidenceApp else {
            XCTFail("missing evidence application")
            return
        }
        let focusGeneration = editorFocusGeneration(in: app)
        let recordButton = app.buttons[buttonIdentifier]
        guard recordButton.waitForExistence(timeout: 2) else {
            XCTFail("\(buttonIdentifier) button did not appear")
            return
        }
        recordButton.click()
        let response = app.staticTexts["Stage D Evidence Response"]
        var value = ""
        guard waitUntil(timeout: 60, condition: {
            value = response.value as? String ?? ""
            return value.contains("\"lastRouteID\":\"\(route)\"")
                || value.hasPrefix("error:")
        }) else {
            XCTFail("evidence capture stalled at \(value)")
            return
        }
        guard !value.hasPrefix("error:") else {
            XCTFail(value)
            return
        }
        guard waitForEditorFocus(after: focusGeneration, in: app) else {
            XCTFail("Editor keyboard focus was not restored after \(route)")
            return
        }
        guard let data = value.data(using: .utf8),
              let row = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let attributes = row["attributes"] as? [String: Any]
        else {
            XCTFail("invalid evidence response for \(route): \(value)")
            return
        }
        recordedRows[scenario] = row
        recordedRows[scenario]?["attributes"] = attributes
    }

    private func acceptanceCommit() throws -> String {
        let commit = ProcessInfo.processInfo.environment[
            "STAGE_D_ACCEPTANCE_COMMIT"
        ] ?? ""
        let isSHA1 = commit.count == 40 && commit.allSatisfy {
            $0.isHexDigit
        }
        guard isSHA1 else {
            throw NSError(
                domain: "StageDAppRouteUITests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "STAGE_D_ACCEPTANCE_COMMIT must be a 40-digit Git SHA"]
            )
        }
        return commit
    }

    private func acceptanceArtifactPath(_ key: String) throws -> String {
        let path = try acceptanceEnvironmentValue(key)
        guard path.hasPrefix("/") else {
            throw NSError(
                domain: "StageDAppRouteUITests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "\(key) must be an absolute path"]
            )
        }
        return path
    }

    private func acceptanceEnvironmentValue(_ key: String) throws -> String {
        let value = ProcessInfo.processInfo.environment[key] ?? ""
        guard !value.isEmpty else {
            throw NSError(
                domain: "StageDAppRouteUITests",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "\(key) is required"]
            )
        }
        return value
    }

    private func attributes(for scenarioID: String) -> [String: Any] {
        guard let attributes = recordedRows[scenarioID]?["attributes"]
                as? [String: Any]
        else {
            XCTFail("missing acceptance row \(scenarioID)")
            return [:]
        }
        return attributes
    }

    private func integer(
        _ attributes: [String: Any],
        _ key: String
    ) -> Int {
        Int(attributes[key] as? String ?? "") ?? -1
    }

    private func assertPersistentState(
        _ expected: [String: Any],
        equals actual: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for key in [
            "canonicalSHA256",
            "nativeIdentitySHA256",
            "flattenedBGRA8SHA256",
            "paintedPixelCount",
            "activeLayerID",
            "layerIDs",
            "inkColorRGBA8Hex",
        ] {
            XCTAssertEqual(
                expected[key] as? String,
                actual[key] as? String,
                "persistent field changed: \(key)",
                file: file,
                line: line
            )
        }
    }

    private func select(
        _ value: String,
        in picker: XCUIElement,
        app: XCUIApplication
    ) {
        picker.click()
        let item = app.menuItems[value]
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

    private func replaceText(in field: XCUIElement, with value: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
    }

    private func toggleHUD(
        in app: XCUIApplication,
        to expectedValue: String
    ) -> Bool {
        let status = app.staticTexts["Stage D HUD Status"]
        for character in ["`", "§", "~", "±"] {
            app.typeKey(character, modifierFlags: [])
            if waitForValue(status, expectedValue) { return true }
        }
        return false
    }

    private func waitUntilEnabled(_ element: XCUIElement) -> Bool {
        waitUntil { element.isEnabled }
    }

    private func rendererErrorDescription(in app: XCUIApplication) -> String {
        let error = app.staticTexts["Renderer Error"]
        guard error.exists else { return "Undo did not become enabled" }
        if let value = error.value as? String, !value.isEmpty { return value }
        if !error.label.isEmpty { return error.label }
        return "Renderer error did not expose a description"
    }

    private func fileErrorDescription(in app: XCUIApplication) -> String {
        let error = app.staticTexts["File Error"]
        guard error.exists else { return "File operation did not complete" }
        if let value = error.value as? String, !value.isEmpty { return value }
        if !error.label.isEmpty { return error.label }
        return "File error did not expose a description"
    }

    private func fileOperationGeneration(in app: XCUIApplication) -> UInt64 {
        let element = app.staticTexts["Stage D File Operation Generation"]
        guard element.waitForExistence(timeout: 2),
              let value = element.value as? String,
              let generation = UInt64(value)
        else {
            XCTFail("File-operation completion generation is unavailable")
            return 0
        }
        return generation
    }

    private func editorFocusGeneration(in app: XCUIApplication) -> UInt64 {
        let element = app.staticTexts["Stage D Editor Focus Generation"]
        guard element.waitForExistence(timeout: 2),
              let value = element.value as? String,
              let generation = UInt64(value)
        else {
            XCTFail("Editor-focus completion generation is unavailable")
            return 0
        }
        return generation
    }

    private func waitForEditorFocus(
        after generation: UInt64,
        in app: XCUIApplication
    ) -> Bool {
        let element = app.staticTexts["Stage D Editor Focus Generation"]
        return waitUntil(timeout: 5) {
            guard let value = element.value as? String,
                  let current = UInt64(value)
            else { return false }
            return current > generation
        }
    }

    private func waitForFileOperation(
        after generation: UInt64,
        in app: XCUIApplication
    ) -> Bool {
        let element = app.staticTexts["Stage D File Operation Generation"]
        return waitUntil(timeout: 60) {
            guard let value = element.value as? String,
                  let current = UInt64(value)
            else { return false }
            return current > generation
        }
    }

    private func waitForValue(_ element: XCUIElement, _ value: String) -> Bool {
        waitUntil { element.value as? String == value }
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return condition()
    }
}
