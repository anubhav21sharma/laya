import EditorCore
import Metal
import MetalRenderer
import PatternEngine
import SwiftUI

struct ContentView: View {
    private let state: CanvasState
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
            let renderer = try GridRenderer(
                device: device,
                drawableSize: PatternSize(width: 1, height: 1),
                configuration: configuration
            )
            state = .ready(
                EditorSessionController(renderer: renderer)
            )
        } catch {
            state = .unavailable(error.localizedDescription)
        }
    }

    var body: some View {
        Group {
            switch state {
            case let .ready(controller):
                ZStack {
                    MetalCanvas(
                        controller: controller,
                        renderer: controller.renderer
                    )
                    ToolRail(controller: controller)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .leading
                        )
                        .padding(12)
                    EditorTopBar(controller: controller)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .top
                        )
                        .padding(12)
                    tilingPicker(controller: controller)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topTrailing
                        )
                        .padding(12)
                }
                    .onAppear {
                        controller.onError = {
                            runtimeError = $0
                        }
                        controller.renderer.onError = {
                            runtimeError = $0
                        }
                    }
                    .onDisappear {
                        controller.onError = nil
                        controller.renderer.onError = nil
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

    private func tilingPicker(
        controller: EditorSessionController
    ) -> some View {
        Picker(
            "Tiling",
            selection: Binding(
                get: { controller.model.tiling },
                set: { candidate in
                    runtimeError = nil
                    controller.handleTiling(candidate)
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
        .disabled(controller.model.isBusy)
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
        case ready(EditorSessionController)
        case unavailable(String)
    }
}
