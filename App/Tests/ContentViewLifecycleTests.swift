#if os(macOS)
import AppKit
import EditorCore
import PatternEngine
import SwiftUI
import Testing

@MainActor
private final class HostedSessionDriver: ObservableObject {
    @Published var controller: EditorSessionController

    init(controller: EditorSessionController) {
        self.controller = controller
    }
}

private struct HostedContentView: View {
    @ObservedObject var driver: HostedSessionDriver

    var body: some View {
        ContentView(controller: driver.controller)
    }
}

#if DEBUG
@Test func debugHUDToggleAcceptsPhysicalGraveAndShiftedTilde() {
    #expect(isDebugHUDToggleCharacter("`"))
    #expect(isDebugHUDToggleCharacter("~"))
    #expect(!isDebugHUDToggleCharacter("1"))
    #expect(!isDebugHUDToggleCharacter(""))
}

@Test
@MainActor
func debugHUDHasACompactIntrinsicSize() {
    let host = NSHostingView(
        rootView: DebugPerformanceHUD(snapshot: DebugPerformanceSnapshot())
    )
    host.layoutSubtreeIfNeeded()

    #expect(host.fittingSize.width < 130)
    #expect(host.fittingSize.height < 70)
}

@Test
@MainActor
func hostedDebugHUDSamplesOnlyWhileVisible() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let host = NSHostingView(rootView: ContentView(controller: controller))
    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 1_024, height: 768),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }

    await settle(host)
    #expect(renderer.onInteractiveFramePresented == nil)

    sendKey("`", keyCode: 50, to: window)
    await settle(host)
    #expect(renderer.onInteractiveFramePresented != nil)

    sendKey("`", keyCode: 50, to: window)
    await settle(host)
    #expect(renderer.onInteractiveFramePresented == nil)

    sendKey("`", keyCode: 50, modifiers: .command, to: window)
    await settle(host)
    #expect(renderer.onInteractiveFramePresented == nil)
}
#endif

@Test
func defaultContentViewInitializerDoesNotAllocateRenderer() throws {
    let source = try contentViewInitializerSource()

    #expect(!source.contains("MTLCreateSystemDefaultDevice"))
    #expect(!source.contains("GridRenderer("))
}

@Test
@MainActor
func hostedContentViewRetainsOneEditorSessionAcrossUpdates() async throws {
    guard let initialRenderer = try makeControllerRenderer(),
          let replacementRenderer = try makeControllerRenderer()
    else { return }

    let initialController = EditorSessionController(renderer: initialRenderer)
    let replacementController = EditorSessionController(
        renderer: replacementRenderer
    )
    let driver = HostedSessionDriver(controller: initialController)
    let host = NSHostingView(rootView: HostedContentView(driver: driver))
    host.frame = CGRect(x: 0, y: 0, width: 1_024, height: 768)

    await settle(host)
    let initialCanvas = try #require(findCanvas(in: host))
    #expect(initialCanvas.controller === initialController)
    #expect(initialCanvas.gridRenderer === initialRenderer)
    #expect(initialCanvas.brushDiameterForTesting == 20)

    initialController.stepBrush(larger: true)
    initialController.handleTool(.erase)
    initialController.handleGridVisibility(true)
    initialController.handleTiling(.halfDrop)
    await settle(host)

    #expect(initialCanvas.brushDiameterForTesting == 25)
    #expect(initialController.model.tool == .erase)
    #expect(initialRenderer.interactiveGridVisibility)
    #expect(initialRenderer.tiling == .halfDrop)

    driver.controller = replacementController
    await settle(host)

    let updatedCanvas = try #require(findCanvas(in: host))
    #expect(updatedCanvas === initialCanvas)
    #expect(updatedCanvas.controller === initialController)
    #expect(updatedCanvas.gridRenderer === initialRenderer)
    #expect(updatedCanvas.brushDiameterForTesting == 25)
    #expect(replacementController.model.brushDiameter == 20)
}

@Test
@MainActor
func hostedTileFieldReceivesNumberKeyEventsWithoutEditorShortcuts() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let host = NSHostingView(rootView: ContentView(controller: controller))
    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 1_024, height: 768),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }

    await settle(host)
    let widthField = try #require(
        findSubviews(of: NSTextField.self, in: host).first {
            $0.isEditable && $0.placeholderString == "Width"
        }
    )
    widthField.selectText(nil)
    await Task.yield()

    sendKey("3", keyCode: 20, to: window)
    sendKey("2", keyCode: 19, to: window)
    sendKey("0", keyCode: 29, to: window)
    await settle(host)

    #expect(widthField.stringValue == "320")
    #expect(controller.model.tiling == .grid)
}

@Test
@MainActor
func hostedInkColorWellUpdatesTheEditorController() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    var focusRequestCount = 0
    let topBar = EditorTopBar(
        controller: controller,
        requestEditorFocus: { focusRequestCount += 1 }
    )
    let host = NSHostingView(rootView: topBar)
    host.frame = CGRect(x: 0, y: 0, width: 600, height: 48)

    await settle(host)
    let colorWell: NSColorWell = try #require(findSubview(in: host))
    colorWell.color = NSColor(
        srgbRed: 0.25,
        green: 0.5,
        blue: 0.75,
        alpha: 0.8
    )
    colorWell.sendAction(colorWell.action, to: colorWell.target)
    await settle(host)

    let ink = controller.model.inkColor
    #expect(abs(ink.red - 0.25) < 0.001)
    #expect(abs(ink.green - 0.5) < 0.001)
    #expect(abs(ink.blue - 0.75) < 0.001)
    #expect(abs(ink.alpha - 0.8) < 0.001)
    #expect(focusRequestCount == 1)
}

@Test
@MainActor
func hostedAnchorPickerUsesOnlyDrawAnchorsAndKeepsNominalDiameter() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    var focusRequestCount = 0
    let topBar = EditorTopBar(
        controller: controller,
        requestEditorFocus: { focusRequestCount += 1 }
    )
    do {
        let host = NSHostingView(rootView: topBar)
        host.frame = CGRect(x: 0, y: 0, width: 760, height: 48)

        await settle(host)
        let picker: NSPopUpButton = try #require(findSubview(in: host))
        let expectedNames = AnchorBrushCatalog.drawAnchors.map(\.displayName)
        #expect(expectedNames.allSatisfy { picker.itemTitles.contains($0) })
        #expect(!picker.itemTitles.contains(
            AnchorBrushCatalog.hardRoundEraser.displayName
        ))
    }

    let nominalDiameter = controller.model.brushDiameter
    for entry in AnchorBrushCatalog.drawAnchors.reversed() {
        topBar.anchorRecipeBinding.wrappedValue = entry.id

        #expect(controller.model.selectedRecipeID == entry.id)
        #expect(controller.model.brushDiameter == nominalDiameter)
    }

    #expect(focusRequestCount == AnchorBrushCatalog.drawAnchors.count)
}

@Test
@MainActor
func repeatedRecipeAndToolChangesRemainCoherent() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    let topBar = EditorTopBar(
        controller: controller,
        requestEditorFocus: {}
    )
    for entry in AnchorBrushCatalog.drawAnchors {
        controller.handleTool(.erase)
        topBar.anchorRecipeBinding.wrappedValue = entry.id

        #expect(controller.model.tool == .erase)
        #expect(controller.model.selectedRecipeID == entry.id)

        controller.handleTool(.draw)
        #expect(controller.model.tool == .draw)
        #expect(controller.model.selectedRecipeID == entry.id)
    }
}

@Test
@MainActor
func brushInputAdapterKeepsMouseNeutralAndOrdersValidSamples() throws {
    let adapter = BrushInputAdapter()
    let samples = adapter.orderedSamples([
        .init(
            position: ScreenPoint(x: 30, y: 30),
            pressure: 1,
            timestamp: 3,
            phase: .moved,
            isTablet: false
        ),
        .init(
            position: ScreenPoint(x: .nan, y: 10),
            pressure: 0,
            timestamp: 2,
            phase: .moved,
            isTablet: false
        ),
        .init(
            position: ScreenPoint(x: 10, y: 10),
            pressure: 0,
            timestamp: 1,
            phase: .began,
            isTablet: false
        ),
        .init(
            position: ScreenPoint(x: 20, y: 20),
            pressure: 0,
            timestamp: 3,
            phase: .moved,
            isTablet: false
        ),
    ])

    #expect(samples.map(\.timestamp) == [1, 3, 3])
    #expect(samples.map(\.position.x) == [10, 30, 20])
    #expect(samples.allSatisfy { $0.pressure == 0.5 })
    #expect(samples.allSatisfy { $0.source == .mouse })
    #expect(samples.allSatisfy { $0.kind == .actual })
    #expect(samples.allSatisfy { $0.capabilities.isEmpty })
}

@Test
@MainActor
func brushInputAdapterNormalizesTabletPressureTiltAndRotation() throws {
    let adapter = BrushInputAdapter()
    let sample = try #require(adapter.orderedSamples([
        .init(
            position: ScreenPoint(x: 12, y: 34),
            pressure: 1.4,
            timestamp: 5,
            tilt: SIMD2(0.3, 0.4),
            rotationDegrees: 270,
            phase: .moved,
            kind: .coalesced,
            isTablet: true
        ),
    ]).first)

    #expect(sample.source == .tablet)
    #expect(sample.kind == .coalesced)
    #expect(sample.pressure == 1)
    #expect(sample.capabilities == [.pressure, .altitude, .azimuth, .roll])
    #expect(abs(try #require(sample.altitude) - Float.pi / 3) < 0.0001)
    #expect(abs(try #require(sample.azimuth) - atan2(0.4, 0.3)) < 0.0001)
    #expect(abs(try #require(sample.roll) + Float.pi / 2) < 0.0001)
}

@Test
@MainActor
func brushInputAdapterExtractsAnActualNativeMouseEvent() throws {
    let event = try #require(NSEvent.mouseEvent(
        with: .leftMouseDragged,
        location: NSPoint(x: 7, y: 9),
        modifierFlags: [],
        timestamp: 12,
        windowNumber: 0,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
    ))
    let sample = try #require(BrushInputAdapter().orderedSamples(
        for: event,
        phase: .moved,
        position: ScreenPoint(x: 70, y: 90)
    ).first)

    #expect(sample.position == ScreenPoint(x: 70, y: 90))
    #expect(sample.timestamp == 12)
    #expect(sample.phase == .moved)
    #expect(sample.source == .mouse)
    #expect(sample.kind == .actual)
    #expect(sample.pressure == 0.5)
}

@MainActor
private func settle<Content: View>(_ host: NSHostingView<Content>) async {
    host.layoutSubtreeIfNeeded()
    await Task.yield()
    host.layoutSubtreeIfNeeded()
    await Task.yield()
}

@MainActor
private func findCanvas(in view: NSView) -> InteractiveMetalView? {
    if let canvas = view as? InteractiveMetalView {
        return canvas
    }
    for subview in view.subviews {
        if let canvas = findCanvas(in: subview) {
            return canvas
        }
    }
    return nil
}

@MainActor
private func findSubview<Subview: NSView>(in view: NSView) -> Subview? {
    if let subview = view as? Subview {
        return subview
    }
    for child in view.subviews {
        if let subview: Subview = findSubview(in: child) {
            return subview
        }
    }
    return nil
}

@MainActor
private func findSubviews<Subview: NSView>(
    of type: Subview.Type,
    in view: NSView
) -> [Subview] {
    var matches: [Subview] = []
    if let match = view as? Subview {
        matches.append(match)
    }
    for child in view.subviews {
        matches.append(contentsOf: findSubviews(of: type, in: child))
    }
    return matches
}

@MainActor
private func sendKey(
    _ character: String,
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags = [],
    to window: NSWindow
) {
    for type: NSEvent.EventType in [.keyDown, .keyUp] {
        guard let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        ) else { continue }
        window.sendEvent(event)
    }
}

private func contentViewInitializerSource() throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: repositoryRoot.appendingPathComponent(
            "App/PatternSpike/ContentView.swift"
        ),
        encoding: .utf8
    )
    let initializerStart = try #require(source.range(of: "    init() {"))
    let bodyStart = try #require(
        source.range(
            of: "\n    var body:",
            range: initializerStart.upperBound..<source.endIndex
        )
    )
    return String(source[initializerStart.lowerBound..<bodyStart.lowerBound])
}
#endif
