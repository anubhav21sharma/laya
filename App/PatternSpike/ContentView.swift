import Metal
import MetalRenderer
import PatternEngine
import SwiftUI

struct ContentView: View {
    private let state: CanvasState
    @State private var runtimeError: String?

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            state = .unavailable("Pattern requires a Metal-capable Apple device.")
            return
        }

        do {
            state = .ready(
                try GridRenderer(
                    device: device,
                    drawableSize: PatternSize(width: 1, height: 1)
                )
            )
        } catch {
            state = .unavailable(error.localizedDescription)
        }
    }

    var body: some View {
        Group {
            switch state {
            case let .ready(renderer):
                MetalCanvas(renderer: renderer)
                    .onAppear {
                        renderer.onError = {
                            runtimeError = $0.localizedDescription
                        }
                    }
                    .overlay(alignment: .top) {
                        if let runtimeError {
                            Text(runtimeError)
                                .font(.caption)
                                .padding(8)
                                .background(
                                    .regularMaterial,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .padding()
                        }
                    }
            case let .unavailable(message):
                ContentUnavailableView(
                    "Renderer Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private enum CanvasState {
        case ready(GridRenderer)
        case unavailable(String)
    }
}
