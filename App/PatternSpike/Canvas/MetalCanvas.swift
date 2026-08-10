import MetalKit
import MetalRenderer
import SwiftUI

@MainActor
private func configure(
    _ view: MTKView,
    renderer: GridRenderer
) {
    view.device = renderer.device
    view.delegate = renderer
    view.colorPixelFormat = DocumentColorPipeline.displayPixelFormat
    view.clearColor = GridCanvasContract.paperClearColor
    view.framebufferOnly = true
    view.isPaused = true
    view.enableSetNeedsDisplay = true
    #if os(macOS)
    view.needsDisplay = true
    #else
    view.setNeedsDisplay()
    #endif
}

#if os(macOS)
import AppKit

struct MetalCanvas: NSViewRepresentable {
    let controller: EditorSessionController
    let renderer: GridRenderer
    let brushDiameter: Float
    let requestEditorFocus: @MainActor () -> Void
    let pointerCancellationGeneration: UInt

    func makeNSView(context: Context) -> InteractiveMetalView {
        let view = InteractiveMetalView(
            frame: .zero,
            controller: controller,
            renderer: renderer,
            requestEditorFocus: requestEditorFocus,
            pointerCancellationGeneration: pointerCancellationGeneration
        )
        configure(view, renderer: renderer)
        view.updateBrushCursor(diameter: brushDiameter)
        return view
    }

    func updateNSView(_ view: InteractiveMetalView, context: Context) {
        #if DEBUG
        precondition(
            view.controller === controller,
            "MetalCanvas reused a view with a different editor controller."
        )
        precondition(
            view.gridRenderer === renderer,
            "MetalCanvas reused a view with a different renderer."
        )
        #endif
        view.updateBrushCursor(diameter: brushDiameter)
        view.applyPointerCancellation(
            generation: pointerCancellationGeneration
        )
        view.requestDraw()
    }
}
#else
import UIKit

struct MetalCanvas: UIViewRepresentable {
    let controller: EditorSessionController
    let renderer: GridRenderer
    let brushDiameter: Float
    let requestEditorFocus: @MainActor () -> Void
    let pointerCancellationGeneration: UInt

    func makeUIView(context: Context) -> InteractiveMetalView {
        let view = InteractiveMetalView(
            frame: .zero,
            controller: controller,
            renderer: renderer,
            requestEditorFocus: requestEditorFocus,
            pointerCancellationGeneration: pointerCancellationGeneration
        )
        configure(view, renderer: renderer)
        return view
    }

    func updateUIView(_ view: InteractiveMetalView, context: Context) {
        #if DEBUG
        precondition(
            view.controller === controller,
            "MetalCanvas reused a view with a different editor controller."
        )
        precondition(
            view.gridRenderer === renderer,
            "MetalCanvas reused a view with a different renderer."
        )
        #endif
        view.applyPointerCancellation(
            generation: pointerCancellationGeneration
        )
        view.requestDraw()
    }
}
#endif
