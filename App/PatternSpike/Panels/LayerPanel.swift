import EditorCore
import SwiftUI

struct LayerPanel: View {
    let controller: EditorSessionController
    let reportError: @MainActor (Error) -> Void
    let requestEditorFocus: @MainActor () -> Void
    @State private var nameDraft = ""
    @State private var opacityDraft = 1.0

    private var stack: LayerStack { controller.model.layerStack }
    private var active: LayerDescriptor? {
        stack.layer(id: stack.activeLayerID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Layers")
                    .font(.headline)
                Spacer()
                Button {
                    perform(addLayer)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Layer")
                .disabled(stack.layers.count >= LayerStack.maximumLayerCount)

                Button(role: .destructive) {
                    perform { try controller.deleteLayer(stack.activeLayerID) }
                } label: {
                    Image(systemName: "minus")
                }
                .accessibilityLabel("Delete Active Layer")
                .disabled(stack.layers.count == 1)
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(stack.layers.reversed()), id: \.id) { layer in
                        layerRow(layer)
                    }
                }
            }
            .frame(minHeight: 80, maxHeight: 180)

            if let active {
                Divider()
                TextField("Layer Name", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        perform {
                            try controller.renameLayer(
                                active.id,
                                to: nameDraft
                            )
                        }
                    }

                HStack {
                    Text("Opacity")
                    Slider(
                        value: $opacityDraft,
                        in: 0...1,
                        onEditingChanged: { editing in
                            guard !editing else { return }
                            perform {
                                try controller.setLayerOpacity(
                                    active.id,
                                    opacity: Float(opacityDraft)
                                )
                            }
                        }
                    )
                    Text("\(Int((opacityDraft * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }

                Picker("Blend", selection: blendModeBinding(active)) {
                    Text("Normal").tag(LayerBlendMode.normal)
                    Text("Multiply").tag(LayerBlendMode.multiply)
                    Text("Screen").tag(LayerBlendMode.screen)
                }
                .pickerStyle(.menu)

                HStack {
                    Button("Move Down") { perform { try move(active.id, by: -1) } }
                        .disabled(stack.layers.first?.id == active.id)
                    Button("Move Up") { perform { try move(active.id, by: 1) } }
                        .disabled(stack.layers.last?.id == active.id)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(10)
        .frame(width: editorInspectorWidth)
        .background(.bar)
        .disabled(controller.model.isBusy)
        .onAppear { resetDrafts() }
        .onChange(of: stack) { resetDrafts() }
    }

    private func layerRow(_ layer: LayerDescriptor) -> some View {
        HStack(spacing: 4) {
            Button {
                perform { try controller.setActiveLayer(layer.id) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: layer.id == stack.activeLayerID
                        ? "circle.inset.filled" : "circle")
                    Text(layer.name)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Select \(layer.name)")

            Button {
                perform {
                    try controller.setLayerVisibility(
                        layer.id,
                        isVisible: !layer.isVisible
                    )
                }
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(layer.isVisible ? "Hide Layer" : "Show Layer")
            .accessibilityIdentifier(
                "\(layer.isVisible ? "Hide" : "Show") \(layer.name)"
            )

            Button {
                perform {
                    try controller.setLayerLock(
                        layer.id,
                        isLocked: !layer.isLocked
                    )
                }
            } label: {
                Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(layer.isLocked ? "Unlock Layer" : "Lock Layer")
            .accessibilityIdentifier(
                "\(layer.isLocked ? "Unlock" : "Lock") \(layer.name)"
            )
        }
        .padding(.horizontal, 6)
        .frame(minHeight: editorControlExtent)
        .background(
            layer.id == stack.activeLayerID
                ? Color.accentColor.opacity(0.15) : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func blendModeBinding(
        _ layer: LayerDescriptor
    ) -> Binding<LayerBlendMode> {
        Binding(
            get: {
                controller.model.layerStack.layer(id: layer.id)?.blendMode
                    ?? layer.blendMode
            },
            set: { mode in
                perform {
                    try controller.setLayerBlendMode(layer.id, blendMode: mode)
                }
            }
        )
    }

    private func addLayer() throws {
        let activeOrder = stack.layers.firstIndex {
            $0.id == stack.activeLayerID
        } ?? (stack.layers.count - 1)
        let descriptor = try LayerDescriptor(
            id: UUID(),
            name: "Layer \(stack.layers.count + 1)"
        )
        try controller.addLayerAndActivate(
            descriptor,
            at: activeOrder + 1
        )
    }

    private func move(_ id: UUID, by delta: Int) throws {
        guard let order = stack.layers.firstIndex(where: { $0.id == id }) else {
            throw LayerStackError.layerMissing(id)
        }
        try controller.moveLayer(id, to: order + delta)
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            resetDrafts()
            requestEditorFocus()
        } catch {
            reportError(error)
        }
    }

    private func resetDrafts() {
        guard let active else { return }
        nameDraft = active.name
        opacityDraft = Double(active.opacity)
    }
}
