import Metal
import MetalRenderer
import SwiftUI

struct ContentView: View {
    private let state: CanvasState

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            state = .unavailable("Pattern requires a Metal-capable Apple device.")
            return
        }

        do {
            state = .ready(try BlankRenderer(device: device))
        } catch {
            state = .unavailable(error.localizedDescription)
        }
    }

    var body: some View {
        Group {
            switch state {
            case let .ready(renderer):
                MetalCanvas(renderer: renderer)
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
        case ready(BlankRenderer)
        case unavailable(String)
    }
}
