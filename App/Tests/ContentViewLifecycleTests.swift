#if os(macOS)
import AppKit
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
func hostedInkColorWellUpdatesTheEditorController() async throws {
    guard let renderer = try makeControllerRenderer() else { return }
    let controller = EditorSessionController(renderer: renderer)
    var focusRequestCount = 0
    let host = NSHostingView(
        rootView: EditorTopBar(
            controller: controller,
            requestEditorFocus: { focusRequestCount += 1 }
        )
    )
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
#endif
