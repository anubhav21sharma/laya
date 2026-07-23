import EditorCore
import MetalRenderer
import PatternEngine
import SwiftUI

struct TilingInspector: View {
    let controller: EditorSessionController
    @Binding var runtimeError: MetalRendererError?
    let focusTarget: FocusState<EditorFocusTarget?>.Binding
    let requestEditorFocus: @MainActor () -> Void
    @State private var widthDraft: String
    @State private var heightDraft: String
    @State private var squareRepeatSizeDraft: String
    @State private var squareOrientationDraft: String

    init(
        controller: EditorSessionController,
        runtimeError: Binding<MetalRendererError?>,
        focusTarget: FocusState<EditorFocusTarget?>.Binding,
        requestEditorFocus: @escaping @MainActor () -> Void
    ) {
        self.controller = controller
        _runtimeError = runtimeError
        self.focusTarget = focusTarget
        self.requestEditorFocus = requestEditorFocus
        _widthDraft = State(initialValue: String(controller.model.pixelSize.width))
        _heightDraft = State(initialValue: String(controller.model.pixelSize.height))
        _squareRepeatSizeDraft = State(
            initialValue: Self.repeatSizeDraft(
                controller.model.periodicConfiguration
            )
        )
        _squareOrientationDraft = State(
            initialValue: Self.orientationDraft(
                controller.model.periodicConfiguration
            )
        )
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
                        .focused(focusTarget, equals: .tileWidth)
                        .accessibilityIdentifier("Tile Width")
                        .onSubmit { requestEditorFocus() }
                }
                GridRow {
                    Text("Height")
                    TextField("Height", text: $heightDraft)
                        .multilineTextAlignment(.trailing)
                        .frame(minHeight: editorControlExtent)
                        .focused(focusTarget, equals: .tileHeight)
                        .accessibilityIdentifier("Tile Height")
                        .onSubmit { requestEditorFocus() }
                }
            }
            .textFieldStyle(.roundedBorder)

            Button("Apply Size") {
                applyDraftSize()
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: editorControlExtent)
            .frame(maxWidth: .infinity, alignment: .trailing)

            if controller.model.tiling.isSquare {
                Divider()

                Text("Square Repeat")
                    .font(.headline)

                Grid(
                    alignment: .leading,
                    horizontalSpacing: 8,
                    verticalSpacing: 8
                ) {
                    GridRow {
                        Text("Spacing")
                        TextField(
                            "Spacing",
                            text: $squareRepeatSizeDraft
                        )
                        .multilineTextAlignment(.trailing)
                        .frame(minHeight: editorControlExtent)
                        .focused(
                            focusTarget,
                            equals: .squareRepeatSize
                        )
                        .accessibilityIdentifier("Square Repeat Size")
                        .onSubmit { applyDraftSquareConfiguration() }
                    }
                    GridRow {
                        Text("Angle °")
                        TextField(
                            "Angle",
                            text: $squareOrientationDraft
                        )
                        .multilineTextAlignment(.trailing)
                        .frame(minHeight: editorControlExtent)
                        .focused(
                            focusTarget,
                            equals: .squareOrientation
                        )
                        .accessibilityIdentifier("Square Orientation")
                        .onSubmit { applyDraftSquareConfiguration() }
                    }
                }
                .textFieldStyle(.roundedBorder)

                Button("Apply Repeat") {
                    applyDraftSquareConfiguration()
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: editorControlExtent)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
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
        .onChange(of: controller.model.periodicConfiguration) {
            resetDraftsToCommittedConfiguration()
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
                requestEditorFocus()
            }
        )
    }

    private var gridBinding: Binding<Bool> {
        Binding(
            get: { controller.model.showGrid },
            set: { visible in
                runtimeError = nil
                controller.handleGridVisibility(visible)
                requestEditorFocus()
            }
        )
    }

    private func applyDraftSize() {
        defer { requestEditorFocus() }
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

    private func applyDraftSquareConfiguration() {
        defer { requestEditorFocus() }
        guard let configuration = Self.periodicConfiguration(
            repeatDraft: squareRepeatSizeDraft,
            orientationDraft: squareOrientationDraft,
            committed: controller.model.periodicConfiguration,
            presetID: controller.model.tiling
        ) else {
            runtimeError = .invalidPeriodicConfiguration(
                "Repeat spacing must be positive and finite; angle must be finite."
            )
            resetDraftsToCommittedConfiguration()
            return
        }

        runtimeError = nil
        controller.handlePeriodicConfiguration(configuration)
    }

    private func resetDraftsToCommittedConfiguration() {
        squareRepeatSizeDraft = Self.repeatSizeDraft(
            controller.model.periodicConfiguration
        )
        squareOrientationDraft = Self.orientationDraft(
            controller.model.periodicConfiguration
        )
    }

    static func repeatSizeDraft(
        _ configuration: PeriodicSymmetryConfiguration
    ) -> String {
        let value = configuration.repeatSize.width
        let rounded = value.rounded()
        return rounded == value
            ? String(format: "%.0f", Double(rounded))
            : String(value)
    }

    static func orientationDraft(
        _ configuration: PeriodicSymmetryConfiguration
    ) -> String {
        let degrees = configuration.orientationRadians * 180 / .pi
        let rounded = degrees.rounded()
        return rounded == degrees
            ? String(format: "%.0f", Double(rounded))
            : String(degrees)
    }

    static func periodicConfiguration(
        repeatDraft repeatDraftText: String,
        orientationDraft orientationDraftText: String,
        committed: PeriodicSymmetryConfiguration,
        presetID: SymmetryPresetID
    ) -> PeriodicSymmetryConfiguration? {
        let repeatText = repeatDraftText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let angleText = orientationDraftText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            let parsedRepeat = Float(repeatText),
            parsedRepeat.isFinite,
            parsedRepeat > 0,
            let parsedAngleDegrees = Float(angleText),
            parsedAngleDegrees.isFinite
        else {
            return nil
        }
        let repeatSize = repeatText == repeatSizeDraft(committed)
            ? committed.repeatSize.width
            : parsedRepeat
        let orientationRadians =
            angleText == orientationDraft(committed)
            ? committed.orientationRadians
            : parsedAngleDegrees * .pi / 180
        return PeriodicSymmetryConfiguration(
            presetID: presetID,
            repeatSize: PatternSize(
                width: repeatSize,
                height: repeatSize
            ),
            orientationRadians: orientationRadians
        )
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
        case .squareRotation:
            "Square Rotation"
        case .squareKaleidoscope:
            "Square Kaleidoscope"
        }
    }
}
