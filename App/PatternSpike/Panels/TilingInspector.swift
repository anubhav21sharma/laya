import EditorCore
import MetalRenderer
import PatternEngine
import SwiftUI

struct TilingInspector: View {
    let controller: EditorSessionController
    @Binding var runtimeError: MetalRendererError?
    @State private var widthDraft: String
    @State private var heightDraft: String

    init(
        controller: EditorSessionController,
        runtimeError: Binding<MetalRendererError?>
    ) {
        self.controller = controller
        _runtimeError = runtimeError
        _widthDraft = State(initialValue: String(controller.model.pixelSize.width))
        _heightDraft = State(initialValue: String(controller.model.pixelSize.height))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Canvas")
                .font(.headline)

            Picker("Tiling", selection: tilingBinding) {
                ForEach(TilingKind.allCases, id: \.self) { tiling in
                    Text(label(for: tiling)).tag(tiling)
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: editorControlExtent)

            Toggle("Show Grid", isOn: gridBinding)
                .frame(minHeight: editorControlExtent)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Width")
                    TextField("Width", text: $widthDraft)
                        .multilineTextAlignment(.trailing)
                        .frame(minHeight: editorControlExtent)
                }
                GridRow {
                    Text("Height")
                    TextField("Height", text: $heightDraft)
                        .multilineTextAlignment(.trailing)
                        .frame(minHeight: editorControlExtent)
                }
            }
            .textFieldStyle(.roundedBorder)

            Button("Apply Size") {
                applyDraftSize()
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: editorControlExtent)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        #if os(macOS)
        .controlSize(.small)
        #else
        .controlSize(.regular)
        #endif
        .padding(10)
        .frame(width: editorInspectorWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.bar)
        .disabled(controller.model.isBusy)
        .onChange(of: controller.model.pixelSize) {
            resetDraftsToCommittedSize()
        }
        .onChange(of: runtimeError) {
            if runtimeError != nil {
                resetDraftsToCommittedSize()
            }
        }
    }

    private var tilingBinding: Binding<TilingKind> {
        Binding(
            get: { controller.model.tiling },
            set: { tiling in
                runtimeError = nil
                controller.handleTiling(tiling)
            }
        )
    }

    private var gridBinding: Binding<Bool> {
        Binding(
            get: { controller.model.showGrid },
            set: { visible in
                runtimeError = nil
                controller.handleGridVisibility(visible)
            }
        )
    }

    private func applyDraftSize() {
        let width = Int(widthDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        let height = Int(heightDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        guard
            let width,
            let height,
            EditorConfiguration.isValidTileSize(
                PixelSize(width: width, height: height)
            )
        else {
            runtimeError = .invalidTileDimensions(
                width: width ?? 0,
                height: height ?? 0
            )
            resetDraftsToCommittedSize()
            return
        }

        runtimeError = nil
        controller.handleTileSize(PixelSize(width: width, height: height))
    }

    private func resetDraftsToCommittedSize() {
        widthDraft = String(controller.model.pixelSize.width)
        heightDraft = String(controller.model.pixelSize.height)
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
}
