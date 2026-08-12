import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest

@MainActor
final class StageDAppRouteUITests: XCTestCase {
    func testProductionControlsShortcutsAndPersistenceWriteEvidence() throws {
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "StageDAppRouteArtifacts",
                isDirectory: true
            )
        try? FileManager.default.removeItem(at: artifactDirectory)
        try FileManager.default.createDirectory(
            at: artifactDirectory,
            withIntermediateDirectories: true
        )
        let manifestURL = artifactDirectory
            .appendingPathComponent("app-route-manifest.json")
        let projectURL = artifactDirectory
            .appendingPathComponent("route.patternproj")
        let exportURL = artifactDirectory
            .appendingPathComponent("route.png")
        let requestURL = artifactDirectory
            .appendingPathComponent("route-request.json")
        let commit = try acceptanceCommit()

        let app = XCUIApplication()
        app.launchEnvironment = [
            "STAGE_D_ACCEPTANCE_MANIFEST": manifestURL.path,
            "STAGE_D_ACCEPTANCE_PROJECT": projectURL.path,
            "STAGE_D_ACCEPTANCE_EXPORT": exportURL.path,
            "STAGE_D_ACCEPTANCE_COMMIT": commit,
            "STAGE_D_ACCEPTANCE_DATE": "2026-08-10T12:00:00Z",
            "STAGE_D_ACCEPTANCE_REQUEST": requestURL.path,
        ]
        app.launch()

        let canvas = app.descendants(matching: .any)["Pattern Canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        record(
            scenario: "stage-d.app.controls",
            route: "controls.initial",
            requestURL: requestURL,
            manifestURL: manifestURL
        )

        app.buttons["Increase Brush Size"].click()
        XCTAssertTrue(app.staticTexts["25 px"].waitForExistence(timeout: 2))
        record(
            scenario: "stage-d.app.controls",
            route: "controls.brush-size",
            requestURL: requestURL,
            manifestURL: manifestURL
        )
        let anchor = app.popUpButtons["Brush Anchor"]
        select("Native Dry Media", in: anchor, app: app)
        XCTAssertEqual(anchor.value as? String, "Native Dry Media")
        record(
            scenario: "stage-d.app.controls",
            route: "controls.brush-selection",
            requestURL: requestURL,
            manifestURL: manifestURL
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
            route: "controls.ink-color",
            requestURL: requestURL,
            manifestURL: manifestURL
        )

        drag(
            canvas,
            from: CGVector(dx: 0.42, dy: 0.46),
            to: CGVector(dx: 0.58, dy: 0.54)
        )
        XCTAssertTrue(waitUntilEnabled(app.buttons["Undo"]))
        record(
            scenario: "stage-d.app.controls",
            route: "controls.draw",
            requestURL: requestURL,
            manifestURL: manifestURL
        )
        let drawn = try attributes(
            for: "stage-d.app.controls",
            in: manifestURL
        )
        XCTAssertGreaterThan(integer(drawn, "paintedPixelCount"), 0)
        XCTAssertGreaterThan(integer(drawn, "normalizedInputCount"), 0)
        app.buttons["Erase"].click()
        XCTAssertTrue(app.buttons["Erase"].isSelected)
        record(
            scenario: "stage-d.app.controls",
            route: "controls.erase-tool",
            requestURL: requestURL,
            manifestURL: manifestURL
        )
        drag(
            canvas,
            from: CGVector(dx: 0.54, dy: 0.5),
            to: CGVector(dx: 0.48, dy: 0.5)
        )
        XCTAssertTrue(waitUntilEnabled(app.buttons["Undo"]))
        record(
            scenario: "stage-d.app.controls",
            route: "controls.erase",
            requestURL: requestURL,
            manifestURL: manifestURL
        )

        app.buttons["Undo"].click()
        XCTAssertTrue(waitUntilEnabled(app.buttons["Redo"]))
        record(
            scenario: "stage-d.app.controls",
            route: "controls.undo-erase",
            requestURL: requestURL,
            manifestURL: manifestURL
        )
        app.buttons["Redo"].click()
        XCTAssertTrue(waitUntilEnabled(app.buttons["Undo"]))
        record(
            scenario: "stage-d.app.controls",
            route: "controls.redo-erase",
            requestURL: requestURL,
            manifestURL: manifestURL
        )
        app.buttons["Add Layer"].click()
        XCTAssertEqual(app.popUpButtons["Active Layer"].value as? String, "Layer 2")
        record(
            scenario: "stage-d.app.controls",
            route: "controls.layer-add",
            requestURL: requestURL,
            manifestURL: manifestURL
        )
        app.buttons["Lock Layer"].click()
        XCTAssertTrue(app.buttons["Unlock Layer"].waitForExistence(timeout: 2))
        record(
            scenario: "stage-d.app.controls",
            route: "controls.layer-lock",
            requestURL: requestURL,
            manifestURL: manifestURL
        )
        app.buttons["Unlock Layer"].click()
        XCTAssertTrue(app.buttons["Lock Layer"].waitForExistence(timeout: 2))
        record(
            scenario: "stage-d.app.controls",
            route: "controls.layer-unlock",
            requestURL: requestURL,
            manifestURL: manifestURL
        )
        app.buttons["Hide Layer"].click()
        XCTAssertTrue(app.buttons["Show Layer"].waitForExistence(timeout: 2))
        record(
            scenario: "stage-d.app.controls",
            route: "controls.layer-hide",
            requestURL: requestURL,
            manifestURL: manifestURL
        )
        app.buttons["Show Layer"].click()
        XCTAssertTrue(app.buttons["Hide Layer"].waitForExistence(timeout: 2))
        record(
            scenario: "stage-d.app.controls",
            route: "controls.layer-show",
            requestURL: requestURL,
            manifestURL: manifestURL
        )
        select(
            "Layer 1",
            in: app.popUpButtons["Active Layer"],
            app: app
        )
        record(
            scenario: "stage-d.app.controls",
            route: "controls.layer-select-painted",
            requestURL: requestURL,
            manifestURL: manifestURL
        )

        app.buttons["Clear Canvas"].click()
        XCTAssertTrue(waitUntilEnabled(app.buttons["Clear Canvas"]))
        record(
            scenario: "stage-d.app.controls",
            route: "controls.clear-painted-layer",
            requestURL: requestURL,
            manifestURL: manifestURL
        )
        let cleared = try attributes(
            for: "stage-d.app.controls",
            in: manifestURL
        )
        XCTAssertEqual(integer(cleared, "paintedPixelCount"), 0)
        app.buttons["Undo"].click()
        XCTAssertTrue(waitUntilEnabled(app.buttons["Redo"]))
        record(
            scenario: "stage-d.app.controls",
            route: "controls.undo-clear-restores",
            requestURL: requestURL,
            manifestURL: manifestURL
        )
        let restored = try attributes(
            for: "stage-d.app.controls",
            in: manifestURL
        )
        XCTAssertGreaterThan(integer(restored, "paintedPixelCount"), 0)
        let tiling = app.popUpButtons["Tiling"]
        select("Half Drop", in: tiling, app: app)
        XCTAssertEqual(tiling.value as? String, "Half Drop")
        record(
            scenario: "stage-d.app.controls",
            route: "controls.mode-half-drop",
            requestURL: requestURL,
            manifestURL: manifestURL
        )
        replaceText(in: app.textFields["Tile Width"], with: "320")
        replaceText(in: app.textFields["Tile Height"], with: "192")
        app.buttons["Apply Size"].click()
        XCTAssertTrue(waitForValue(app.textFields["Tile Width"], "320"))
        XCTAssertTrue(waitForValue(app.textFields["Tile Height"], "192"))
        record(
            scenario: "stage-d.app.controls",
            route: "controls.resize",
            requestURL: requestURL,
            manifestURL: manifestURL
        )
        let resized = try attributes(
            for: "stage-d.app.controls",
            in: manifestURL
        )
        XCTAssertGreaterThan(integer(resized, "paintedPixelCount"), 0)

        canvas.click()
        app.typeKey("`", modifierFlags: [])
        XCTAssertTrue(app.descendants(matching: .any)[
            "Debug Performance HUD"
        ].waitForExistence(timeout: 2))
        record(
            scenario: "stage-d.app.shortcuts",
            route: "shortcuts.hud-show",
            requestURL: requestURL,
            manifestURL: manifestURL
        )
        app.typeKey("`", modifierFlags: [])
        XCTAssertFalse(app.descendants(matching: .any)[
            "Debug Performance HUD"
        ].exists)
        record(
            scenario: "stage-d.app.shortcuts",
            route: "shortcuts.hud-hide",
            requestURL: requestURL,
            manifestURL: manifestURL
        )
        app.typeKey("g", modifierFlags: [])
        XCTAssertEqual(
            app.descendants(matching: .any)["Show Grid"].value as? String,
            "1"
        )
        record(
            scenario: "stage-d.app.shortcuts",
            route: "shortcuts.grid",
            requestURL: requestURL,
            manifestURL: manifestURL
        )
        app.typeKey("7", modifierFlags: [])
        XCTAssertEqual(tiling.value as? String, "Rotational")
        record(
            scenario: "stage-d.app.shortcuts",
            route: "shortcuts.mode",
            requestURL: requestURL,
            manifestURL: manifestURL
        )
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitUntilEnabled(app.buttons["Redo"]))
        record(
            scenario: "stage-d.app.shortcuts",
            route: "shortcuts.undo",
            requestURL: requestURL,
            manifestURL: manifestURL
        )
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntilEnabled(app.buttons["Undo"]))
        record(
            scenario: "stage-d.app.shortcuts",
            route: "shortcuts.redo",
            requestURL: requestURL,
            manifestURL: manifestURL
        )

        let tilingBeforeFieldInput = tiling.value as? String
        replaceText(in: app.textFields["Tile Width"], with: "321")
        app.typeKey("7", modifierFlags: [])
        XCTAssertEqual(tiling.value as? String, tilingBeforeFieldInput)
        XCTAssertEqual(app.textFields["Tile Width"].value as? String, "3217")
        record(
            scenario: "stage-d.app.shortcuts",
            route: "shortcuts.numeric-field-owns-digit",
            requestURL: requestURL,
            manifestURL: manifestURL
        )

        canvas.click()
        app.buttons["Save Project"].click()
        XCTAssertTrue(waitForFile(projectURL))
        record(
            scenario: "stage-d.app.persistence",
            route: "persistence.save",
            requestURL: requestURL,
            manifestURL: manifestURL
        )
        let saved = try attributes(
            for: "stage-d.app.persistence",
            in: manifestURL
        )
        XCTAssertGreaterThan(integer(saved, "paintedPixelCount"), 0)
        XCTAssertEqual(saved["canUndo"] as? String, "true")
        XCTAssertEqual(saved["canRedo"] as? String, "false")

        replaceText(in: app.textFields["Tile Width"], with: "256")
        replaceText(in: app.textFields["Tile Height"], with: "256")
        app.buttons["Apply Size"].click()
        XCTAssertTrue(waitForValue(app.textFields["Tile Width"], "256"))
        app.buttons["Open Project"].click()
        XCTAssertTrue(waitForValue(app.textFields["Tile Width"], "320"))
        XCTAssertTrue(waitForValue(app.textFields["Tile Height"], "192"))
        record(
            scenario: "stage-d.app.persistence",
            route: "persistence.open-atomic-replacement",
            requestURL: requestURL,
            manifestURL: manifestURL
        )
        let opened = try attributes(
            for: "stage-d.app.persistence",
            in: manifestURL
        )
        assertPersistentState(saved, equals: opened)
        XCTAssertEqual(opened["canUndo"] as? String, "false")
        XCTAssertEqual(opened["canRedo"] as? String, "false")

        app.buttons["Export PNG"].click()
        XCTAssertTrue(waitForFile(exportURL))
        let png = try Data(contentsOf: exportURL)
        XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        record(
            scenario: "stage-d.app.persistence",
            route: "persistence.flattened-png-export",
            requestURL: requestURL,
            manifestURL: manifestURL
        )
        let exported = try attributes(
            for: "stage-d.app.persistence",
            in: manifestURL
        )
        assertPersistentState(opened, equals: exported)
        XCTAssertEqual(
            try decodedBGRA8SHA256(
                exportURL,
                width: 320,
                height: 192
            ),
            exported["flattenedBGRA8SHA256"] as? String
        )

        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertTrue(manifest.contains("stage-d.app.controls"))
        XCTAssertTrue(manifest.contains("stage-d.app.shortcuts"))
        XCTAssertTrue(manifest.contains("stage-d.app.persistence"))
        XCTAssertTrue(manifest.contains("10738cff"))
        XCTAssertFalse(manifest.contains("\"status\" : \"failed\""))
        XCTAssertTrue(app.buttons["Delete Active Layer"].isEnabled)
        let attachment = XCTAttachment(contentsOfFile: manifestURL)
        attachment.name = "app-route-manifest.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func record(
        scenario: String,
        route: String,
        requestURL: URL,
        manifestURL: URL
    ) {
        do {
            let data = try JSONSerialization.data(withJSONObject: [
                "scenarioID": scenario,
                "routeID": route,
                "nonce": UUID().uuidString,
            ])
            try data.write(to: requestURL, options: .atomic)
        } catch {
            XCTFail("could not write route request: \(error)")
            return
        }
        XCTAssertTrue(waitUntil(timeout: 10) {
            guard let data = try? Data(contentsOf: manifestURL),
                  let text = String(data: data, encoding: .utf8)
            else { return false }
            return text.contains(route)
        })
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

    private func attributes(
        for scenarioID: String,
        in manifestURL: URL
    ) throws -> [String: Any] {
        let data = try Data(contentsOf: manifestURL)
        guard let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let rows = root["rows"] as? [[String: Any]],
              let row = rows.first(where: {
                $0["scenarioID"] as? String == scenarioID
              }),
              let attributes = row["attributes"] as? [String: Any]
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

    private func decodedBGRA8SHA256(
        _ url: URL,
        width: Int,
        height: Int
    ) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            XCTFail("exported PNG could not be decoded")
            return ""
        }
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue
            ) else { return false }
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }
        XCTAssertTrue(rendered)
        return SHA256.hash(data: Data(bytes)).map {
            String(format: "%02x", $0)
        }.joined()
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

    private func waitUntilEnabled(_ element: XCUIElement) -> Bool {
        waitUntil { element.isEnabled }
    }

    private func waitForValue(_ element: XCUIElement, _ value: String) -> Bool {
        waitUntil { element.value as? String == value }
    }

    private func waitForFile(_ url: URL) -> Bool {
        waitUntil(timeout: 10) {
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0
                > 0
        }
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
