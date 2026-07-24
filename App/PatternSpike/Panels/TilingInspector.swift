import EditorCore
import MetalRenderer
import PatternEngine
import SwiftUI

struct TilingInspector: View {
    enum DocumentMode: Hashable {
        case seamlessPattern
        case radial
        case plainCanvas
    }

    let controller: EditorSessionController
    @Binding var runtimeError: MetalRendererError?
    let focusTarget: FocusState<EditorFocusTarget?>.Binding
    let requestEditorFocus: @MainActor () -> Void
    @State private var widthDraft: String
    @State private var heightDraft: String
    @State private var latticeRepeatSizeDraft: String
    @State private var latticeOrientationDraft: String
    @State private var radialRayCountDraft: String
    @State private var radialCenterXDraft: String
    @State private var radialCenterYDraft: String
    @State private var radialReferenceAngleDraft: String

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
        _latticeRepeatSizeDraft = State(
            initialValue: Self.repeatSizeDraft(
                controller.model.periodicConfiguration
            )
        )
        _latticeOrientationDraft = State(
            initialValue: Self.orientationDraft(
                controller.model.periodicConfiguration
            )
        )
        let radial = controller.model.radialConfiguration
            ?? Self.defaultRadialConfiguration(
                pixelSize: controller.model.pixelSize
            )
        _radialRayCountDraft = State(initialValue: String(radial.rayCount))
        _radialCenterXDraft = State(
            initialValue: Self.numberDraft(radial.center.x)
        )
        _radialCenterYDraft = State(
            initialValue: Self.numberDraft(radial.center.y)
        )
        _radialReferenceAngleDraft = State(
            initialValue: Self.numberDraft(
                radial.referenceAngleRadians * 180 / .pi
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Canvas")
                    .font(.headline)

                Picker("Mode", selection: documentModeBinding) {
                    Text("Seamless Pattern")
                        .tag(DocumentMode.seamlessPattern)
                    Text("Radial / Mandala")
                        .tag(DocumentMode.radial)
                    Text("Plain Canvas")
                        .tag(DocumentMode.plainCanvas)
                }
                .pickerStyle(.menu)
                .frame(minHeight: editorControlExtent)
                .disabled(controller.model.documentDomainLocked)

                if documentMode == .seamlessPattern {
                    periodicControls
                } else if documentMode == .radial {
                    radialControls
                }

                Toggle("Show Grid", isOn: gridBinding)
                    .frame(minHeight: editorControlExtent)

                sizeControls
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
        .onChange(of: controller.model.finiteConfiguration) {
            resetDraftsToCommittedRadialConfiguration()
        }
        .onChange(of: runtimeError) {
            if runtimeError != nil {
                resetDraftsToCommittedSize()
            }
        }
    }

    @ViewBuilder
    private var periodicControls: some View {
        Picker("Tiling", selection: tilingBinding) {
            ForEach(TilingKind.periodicCases, id: \.self) { tiling in
                Text(label(for: tiling)).tag(tiling)
            }
        }
        .pickerStyle(.menu)
        .frame(minHeight: editorControlExtent)

        if controller.model.tiling.supportsSpacingAndOrientation {
            Divider()
            Text("Lattice Repeat")
                .font(.headline)
            Grid(
                alignment: .leading,
                horizontalSpacing: 8,
                verticalSpacing: 8
            ) {
                GridRow {
                    Text("Spacing")
                    TextField("Spacing", text: $latticeRepeatSizeDraft)
                        .multilineTextAlignment(.trailing)
                        .frame(minHeight: editorControlExtent)
                        .focused(focusTarget, equals: .latticeRepeatSize)
                        .accessibilityIdentifier("Lattice Repeat Size")
                        .onSubmit { applyDraftLatticeConfiguration() }
                }
                GridRow {
                    Text("Angle °")
                    TextField("Angle", text: $latticeOrientationDraft)
                        .multilineTextAlignment(.trailing)
                        .frame(minHeight: editorControlExtent)
                        .focused(focusTarget, equals: .latticeOrientation)
                        .accessibilityIdentifier("Lattice Orientation")
                        .onSubmit { applyDraftLatticeConfiguration() }
                }
            }
            .textFieldStyle(.roundedBorder)

            Button("Apply Repeat") {
                applyDraftLatticeConfiguration()
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: editorControlExtent)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var radialControls: some View {
        Divider()
        HStack {
            Text("Radial Geometry")
                .font(.headline)
            Spacer()
            if controller.model.radialGeometryLocked {
                Label("Locked", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            Picker("Symmetry", selection: radialKindBinding) {
                Text("Mirror").tag(RadialSymmetryKind.mirror)
                Text("Rotation").tag(RadialSymmetryKind.rotation)
                Text("Mandala").tag(RadialSymmetryKind.mandala)
            }
            .pickerStyle(.menu)
            .frame(minHeight: editorControlExtent)

            if radialKind != .mirror {
                Grid(
                    alignment: .leading,
                    horizontalSpacing: 8,
                    verticalSpacing: 8
                ) {
                    GridRow {
                        Text("Rays")
                        TextField("Rays", text: $radialRayCountDraft)
                            .multilineTextAlignment(.trailing)
                            .frame(minHeight: editorControlExtent)
                            .focused(focusTarget, equals: .radialRayCount)
                            .accessibilityIdentifier("Radial Ray Count")
                            .onSubmit { applyDraftRadialConfiguration() }
                    }
                }
                .textFieldStyle(.roundedBorder)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                    ],
                    spacing: 5
                ) {
                    ForEach([4, 6, 8, 12, 16], id: \.self) { rays in
                        Button(String(rays)) {
                            radialRayCountDraft = String(rays)
                            applyDraftRadialConfiguration()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .accessibilityIdentifier("Radial Ray Presets")
            }

            Grid(
                alignment: .leading,
                horizontalSpacing: 8,
                verticalSpacing: 8
            ) {
                GridRow {
                    Text("Center X")
                    TextField("Center X", text: $radialCenterXDraft)
                        .multilineTextAlignment(.trailing)
                        .focused(focusTarget, equals: .radialCenterX)
                        .accessibilityIdentifier("Radial Center X")
                }
                GridRow {
                    Text("Center Y")
                    TextField("Center Y", text: $radialCenterYDraft)
                        .multilineTextAlignment(.trailing)
                        .focused(focusTarget, equals: .radialCenterY)
                        .accessibilityIdentifier("Radial Center Y")
                }
                GridRow {
                    Text("Angle °")
                    TextField("Angle", text: $radialReferenceAngleDraft)
                        .multilineTextAlignment(.trailing)
                        .focused(
                            focusTarget,
                            equals: .radialReferenceAngle
                        )
                        .accessibilityIdentifier("Radial Reference Angle")
                        .onSubmit { applyDraftRadialConfiguration() }
                }
            }
            .textFieldStyle(.roundedBorder)

            Button("Apply Geometry") {
                applyDraftRadialConfiguration()
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: editorControlExtent)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .disabled(controller.model.radialGeometryLocked)
    }

    @ViewBuilder
    private var sizeControls: some View {
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
    }

    private var documentMode: DocumentMode {
        switch controller.model.documentConfiguration {
        case .periodic:
            .seamlessPattern
        case .finite(.plain):
            .plainCanvas
        case .finite(.radial):
            .radial
        }
    }

    private var documentModeBinding: Binding<DocumentMode> {
        Binding(
            get: { documentMode },
            set: { mode in
                runtimeError = nil
                switch mode {
                case .seamlessPattern:
                    controller.handlePeriodicConfiguration(
                        controller.model.periodicConfiguration
                    )
                case .plainCanvas:
                    controller.handleFiniteConfiguration(.plain)
                case .radial:
                    controller.handleFiniteConfiguration(
                        .radial(
                            controller.model.radialConfiguration
                                ?? Self.defaultRadialConfiguration(
                                    pixelSize: controller.model.pixelSize
                                )
                        )
                    )
                }
                requestEditorFocus()
            }
        )
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

    private var radialKind: RadialSymmetryKind {
        controller.model.radialConfiguration?.kind ?? .mandala
    }

    private var radialKindBinding: Binding<RadialSymmetryKind> {
        Binding(
            get: { radialKind },
            set: { kind in
                if kind == .mirror {
                    radialRayCountDraft = "1"
                } else if (Int(radialRayCountDraft) ?? 0) < 2 {
                    radialRayCountDraft = "8"
                }
                applyDraftRadialConfiguration(kind: kind)
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

    private func applyDraftLatticeConfiguration() {
        defer { requestEditorFocus() }
        guard let configuration = Self.periodicConfiguration(
            repeatDraft: latticeRepeatSizeDraft,
            orientationDraft: latticeOrientationDraft,
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
        latticeRepeatSizeDraft = Self.repeatSizeDraft(
            controller.model.periodicConfiguration
        )
        latticeOrientationDraft = Self.orientationDraft(
            controller.model.periodicConfiguration
        )
    }

    private func applyDraftRadialConfiguration(
        kind explicitKind: RadialSymmetryKind? = nil
    ) {
        defer { requestEditorFocus() }
        let kind = explicitKind ?? radialKind
        guard let configuration = Self.radialConfiguration(
            kind: kind,
            rayDraft: radialRayCountDraft,
            centerXDraft: radialCenterXDraft,
            centerYDraft: radialCenterYDraft,
            referenceAngleDraft: radialReferenceAngleDraft,
            pixelSize: controller.model.pixelSize
        ) else {
            runtimeError = .invalidSymmetryConfiguration(
                "Rays must be 2...32 (Mirror uses 1), the center must be "
                    + "inside the canvas, and all geometry must be finite."
            )
            resetDraftsToCommittedRadialConfiguration()
            return
        }

        runtimeError = nil
        controller.handleFiniteConfiguration(.radial(configuration))
    }

    private func resetDraftsToCommittedRadialConfiguration() {
        guard let radial = controller.model.radialConfiguration else {
            return
        }
        radialRayCountDraft = String(radial.rayCount)
        radialCenterXDraft = Self.numberDraft(radial.center.x)
        radialCenterYDraft = Self.numberDraft(radial.center.y)
        radialReferenceAngleDraft = Self.numberDraft(
            radial.referenceAngleRadians * 180 / .pi
        )
    }

    static func defaultRadialConfiguration(
        pixelSize: PixelSize
    ) -> RadialSymmetryConfiguration {
        RadialSymmetryConfiguration(
            kind: .mandala,
            rayCount: 8,
            center: WorldPoint(
                x: Float(pixelSize.width) * 0.5,
                y: Float(pixelSize.height) * 0.5
            )
        )
    }

    static func radialConfiguration(
        kind: RadialSymmetryKind,
        rayDraft: String,
        centerXDraft: String,
        centerYDraft: String,
        referenceAngleDraft: String,
        pixelSize: PixelSize
    ) -> RadialSymmetryConfiguration? {
        let rayCount: Int
        if kind == .mirror {
            rayCount = 1
        } else {
            guard let parsed = Int(
                rayDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            ), (2...SymmetryDescriptorCompiler.maximumRadialRayCount)
                .contains(parsed)
            else {
                return nil
            }
            rayCount = parsed
        }
        guard
            let centerX = Float(
                centerXDraft.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            ),
            let centerY = Float(
                centerYDraft.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            ),
            let angleDegrees = Float(
                referenceAngleDraft.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            ),
            centerX.isFinite,
            centerY.isFinite,
            angleDegrees.isFinite,
            centerX >= 0,
            centerY >= 0,
            centerX < Float(pixelSize.width),
            centerY < Float(pixelSize.height)
        else {
            return nil
        }
        return RadialSymmetryConfiguration(
            kind: kind,
            rayCount: rayCount,
            center: WorldPoint(x: centerX, y: centerY),
            referenceAngleRadians: angleDegrees * .pi / 180
        )
    }

    static func numberDraft(_ value: Float) -> String {
        let rounded = value.rounded()
        return rounded == value
            ? String(format: "%.0f", Double(rounded))
            : String(value)
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
        case .hexagons:
            "Hexagons"
        case .rotation3:
            "Rotation 3"
        case .rotation6:
            "Rotation 6"
        case .kaleidoscope60:
            "Kaleidoscope 60°"
        case .kaleidoscope30:
            "Kaleidoscope 30°"
        case .plainCanvas:
            "Plain Canvas"
        case .radialMirror:
            "Mirror"
        case .radialRotation:
            "Rotation"
        case .radialMandala:
            "Mandala"
        }
    }
}
