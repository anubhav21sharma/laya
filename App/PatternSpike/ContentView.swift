import EditorCore
import Metal
import MetalRenderer
import PatternEngine
import SwiftUI

struct ContentView: View {
    private let state: CanvasState
    @State private var editorModel = EditorModel()
    @State private var rendererIsIdle = true
    @State private var runtimeError: MetalRendererError?

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            state = .unavailable("Pattern requires a Metal-capable Apple device.")
            return
        }

        do {
            let configuration = try TilingCanvasConfiguration(
                pixelSize: GridCanvasContract.defaultPixelSize,
                tiling: .grid
            )
            state = .ready(
                try GridRenderer(
                    device: device,
                    drawableSize: PatternSize(width: 1, height: 1),
                    configuration: configuration
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
                            runtimeError = $0
                        }
                        renderer.onIdleStateChange = {
                            rendererIsIdle = $0
                        }
                        rendererIsIdle = renderer.isIdle
                    }
                    .onDisappear {
                        renderer.onError = nil
                        renderer.onIdleStateChange = nil
                    }
                    .overlay(alignment: .topLeading) {
                        tilingPicker(renderer: renderer)
                    }
                    .overlay(alignment: .top) {
                        if let runtimeError {
                            Text(runtimeError.localizedDescription)
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

    private func tilingPicker(renderer: GridRenderer) -> some View {
        Picker(
            "Tiling",
            selection: Binding(
                get: { editorModel.tiling },
                set: { candidate in
                    do {
                        try renderer.setTiling(candidate)
                        editorModel.confirmTiling(candidate)
                        runtimeError = nil
                    } catch let error as MetalRendererError {
                        runtimeError = error
                    } catch {
                        runtimeError = .commandFailed(
                            error.localizedDescription
                        )
                    }
                }
            )
        ) {
            ForEach(TilingKind.allCases, id: \.self) { tiling in
                Text(label(for: tiling)).tag(tiling)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .disabled(!rendererIsIdle)
        .padding(8)
    }

    private func label(for tiling: TilingKind) -> String {
        switch tiling {
        case .grid:
            "Grid"
        case .halfDrop:
            "Half Drop"
        case .brick:
            "Brick"
        case .mirrorX:
            "Mirror X"
        case .mirrorY:
            "Mirror Y"
        case .mirrorXY:
            "Mirror XY"
        case .rotational:
            "Rotational"
        }
    }

    private enum CanvasState {
        case ready(GridRenderer)
        case unavailable(String)
    }
}
