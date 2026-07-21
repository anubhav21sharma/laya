import Foundation
import Testing

@Suite("Editor shell ownership")
struct EditorShellStructuralTests {
    @Test
    func nativeMetalViewOwnsPointersButNoSemanticKeys() throws {
        let source = try source("App/PatternSpike/Canvas/InteractiveMetalView.swift")

        #expect(source.contains("override var acceptsFirstResponder: Bool { false }"))
        #expect(source.contains("if controller.isSpaceDown"))
        #expect(!source.contains("override func keyDown"))
        #expect(!source.contains("override func keyUp"))
        #expect(!source.contains("override func cancelOperation"))
        #expect(!source.contains("makeFirstResponder"))
    }

    @Test
    func swiftUIShellIsTheSingleSemanticKeyOwner() throws {
        let content = try source("App/PatternSpike/ContentView.swift")
        let commands = try source(
            "App/PatternSpike/Commands/EditorFocusedCommands.swift"
        )
        let native = try source(
            "App/PatternSpike/Canvas/InteractiveMetalView.swift"
        )
        let canvas = try source("App/PatternSpike/Canvas/MetalCanvas.swift")

        #expect(content.contains(".onKeyPress(phases: .all)"))
        #expect(content.contains("EditorKeymap.resolve("))
        #expect(content.contains("editorKey(from: press)"))
        #expect(content.contains("case .escape:"))
        #expect(content.contains("case .space:"))
        #expect(content.contains("case .return:"))
        #expect(content.contains("handleEditorShortcut("))
        #expect(content.contains(".onChange(of: editorFocused)"))
        #expect(content.contains("return .ignored"))
        #expect(keyPressOwnerCount(in: [content, native, canvas]) == 1)
        #expect(!commands.contains(".keyboardShortcut("))
        #expect(
            keyPressOwnerCount(in: [content, commands, native, canvas]) == 1
        )
    }

    @Test
    func escapeUsesTheSharedAppCancellationBridge() throws {
        let content = try source("App/PatternSpike/ContentView.swift")
        let controller = try source(
            "App/PatternSpike/EditorSessionController.swift"
        )

        #expect(content.contains("handleEditorShortcut("))
        #expect(controller.contains("case .cancel:"))
        #expect(controller.contains("controller.handleFocusLoss()"))
        #expect(controller.contains("pointerCancellationGeneration &+= 1"))
        #expect(
            !controller.contains("func cancelEditorInteraction(")
        )
    }

    @Test
    func controlsAndCanvasExplicitlyReturnFocusToTheKeyOwner() throws {
        let content = try source("App/PatternSpike/ContentView.swift")
        let canvas = try source("App/PatternSpike/Canvas/MetalCanvas.swift")
        let native = try source(
            "App/PatternSpike/Canvas/InteractiveMetalView.swift"
        )
        let rail = try source("App/PatternSpike/Panels/ToolRail.swift")
        let topBar = try source("App/PatternSpike/Panels/EditorTopBar.swift")
        let inspector = try source(
            "App/PatternSpike/Panels/TilingInspector.swift"
        )

        #expect(content.contains("requestEditorFocus"))
        #expect(content.contains("editorFocused = true"))
        #expect(canvas.contains("requestEditorFocus"))
        #expect(native.contains("requestEditorFocus()"))
        #expect(rail.contains("requestEditorFocus()"))
        #expect(topBar.contains("requestEditorFocus()"))
        #expect(inspector.contains("requestEditorFocus()"))
    }

    @Test
    func focusCancellationBridgesIntoNativePointerState() throws {
        let content = try source("App/PatternSpike/ContentView.swift")
        let canvas = try source("App/PatternSpike/Canvas/MetalCanvas.swift")
        let native = try source(
            "App/PatternSpike/Canvas/InteractiveMetalView.swift"
        )

        #expect(content.contains("pointerCancellationGeneration"))
        #expect(content.contains("cancelCurrentInteraction"))
        #expect(!content.contains("private func cancelEditorInteraction"))
        #expect(canvas.contains("applyPointerCancellation("))
        #expect(native.contains("lastPointerCancellationGeneration"))
        #expect(native.contains("dragMode = nil"))
    }

    @Test
    func nativeViewTracksTheWindowScreenRefreshRate() throws {
        let native = try source(
            "App/PatternSpike/Canvas/InteractiveMetalView.swift"
        )

        #expect(native.contains("override func viewDidMoveToWindow()"))
        #expect(native.contains("NSWindow.didChangeScreenNotification"))
        #expect(native.contains("maximumFramesPerSecond"))
        #expect(!native.contains("makeFirstResponder"))
    }

    @Test
    func macMenusUseFocusedControllerClosures() throws {
        let commands = try source(
            "App/PatternSpike/Commands/EditorFocusedCommands.swift"
        )
        let app = try source("App/PatternSpike/PatternSpikeApp.swift")

        #expect(commands.contains("FocusedValueKey"))
        #expect(commands.contains("@FocusedValue"))
        #expect(commands.contains("actions?.undo()"))
        #expect(commands.contains("actions?.redo()"))
        #expect(commands.contains("actions?.clear()"))
        #expect(commands.contains("actions?.selectDraw()"))
        #expect(commands.contains("actions?.selectErase()"))
        #expect(!commands.contains(".keyboardShortcut("))
        #expect(!commands.contains("GridRenderer"))
        #expect(app.contains(".commands { EditorFocusedCommands() }"))
    }

    @Test
    func interactiveFramesUseTheControllerSuppliedGridSetting() throws {
        let renderer = try source("Sources/MetalRenderer/GridRenderer.swift")
        let shader = try source("Sources/MetalRenderer/Shaders.metal")

        #expect(renderer.contains("public private(set) var interactiveGridVisibility"))
        #expect(renderer.contains("showGridLines: interactiveGridVisibility"))
        #expect(shader.contains("if (frame.showGridLines != 0)"))
        #expect(shader.contains("patternGridOverlay"))
    }

    @Test
    func shellUsesStableRegionsAndPlatformSizedControls() throws {
        let content = try source("App/PatternSpike/ContentView.swift")
        let rail = try source("App/PatternSpike/Panels/ToolRail.swift")
        let topBar = try source("App/PatternSpike/Panels/EditorTopBar.swift")
        let inspector = try source(
            "App/PatternSpike/Panels/TilingInspector.swift"
        )

        #expect(content.contains("VStack(spacing: 0)"))
        #expect(content.contains("HStack(spacing: 0)"))
        #expect(content.contains("MetalCanvas("))
        #expect(content.contains("ErrorBanner(error:"))
        #expect(rail.contains("editorControlExtent"))
        #expect(rail.contains(".buttonStyle(.plain)"))
        #expect(topBar.contains("editorControlExtent"))
        #expect(inspector.contains("editorControlExtent"))
        #expect(!rail.contains("RoundedRectangle"))
        #expect(!topBar.contains("RoundedRectangle"))
        #expect(!inspector.contains("RoundedRectangle"))
    }

    private func keyPressOwnerCount(in sources: [String]) -> Int {
        sources.reduce(0) {
            $0 + $1.components(separatedBy: ".onKeyPress(").count - 1
        }
    }

    private func source(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        ).replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
    }
}
