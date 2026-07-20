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
    view.colorPixelFormat = .bgra8Unorm
    view.clearColor = MTLClearColor(
        red: 242.0 / 255.0,
        green: 244.0 / 255.0,
        blue: 241.0 / 255.0,
        alpha: 1
    )
    view.framebufferOnly = true
    view.isPaused = false
    view.enableSetNeedsDisplay = false
    view.preferredFramesPerSecond = 60
}

#if os(macOS)
import AppKit

struct MetalCanvas: NSViewRepresentable {
    let controller: EditorSessionController
    let renderer: GridRenderer
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
        return view
    }

    func updateNSView(_ view: InteractiveMetalView, context: Context) {
        view.applyPointerCancellation(
            generation: pointerCancellationGeneration
        )
    }
}
#else
import UIKit

struct MetalCanvas: UIViewRepresentable {
    let controller: EditorSessionController
    let renderer: GridRenderer
    let requestEditorFocus: @MainActor () -> Void
    let pointerCancellationGeneration: UInt

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        configure(view, renderer: renderer)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}
}
#endif
