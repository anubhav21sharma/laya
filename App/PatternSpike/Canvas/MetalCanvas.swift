import MetalKit
import MetalRenderer
import SwiftUI

@MainActor
private func configure(
    _ view: MTKView,
    renderer: BlankRenderer
) {
    view.device = renderer.device
    view.delegate = renderer
    view.colorPixelFormat = .bgra8Unorm
    view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    view.framebufferOnly = true
    view.isPaused = false
    view.enableSetNeedsDisplay = false
    view.preferredFramesPerSecond = 60
}

#if os(macOS)
import AppKit

struct MetalCanvas: NSViewRepresentable {
    let renderer: BlankRenderer

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        configure(view, renderer: renderer)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}
}
#else
import UIKit

struct MetalCanvas: UIViewRepresentable {
    let renderer: BlankRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        configure(view, renderer: renderer)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}
}
#endif
