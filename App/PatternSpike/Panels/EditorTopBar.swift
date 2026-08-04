import CoreGraphics
import EditorCore
import PatternEngine
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct EditorTopBar: View {
    let controller: EditorSessionController
    let requestEditorFocus: @MainActor () -> Void
    let openProject: @MainActor () -> Void
    let saveProject: @MainActor () -> Void
    let fileOperationsEnabled: Bool

    init(
        controller: EditorSessionController,
        requestEditorFocus: @escaping @MainActor () -> Void,
        openProject: @escaping @MainActor () -> Void = {},
        saveProject: @escaping @MainActor () -> Void = {},
        fileOperationsEnabled: Bool = false
    ) {
        self.controller = controller
        self.requestEditorFocus = requestEditorFocus
        self.openProject = openProject
        self.saveProject = saveProject
        self.fileOperationsEnabled = fileOperationsEnabled
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: openProject) {
                Image(systemName: "folder")
            }
            .frame(width: editorControlExtent, height: editorControlExtent)
            .accessibilityLabel("Open Project")
            .disabled(!fileOperationsEnabled)

            Button(action: saveProject) {
                Image(systemName: "square.and.arrow.down")
            }
            .frame(width: editorControlExtent, height: editorControlExtent)
            .accessibilityLabel("Save Project")
            .disabled(!fileOperationsEnabled)

            Divider()
                .frame(height: 20)

            Picker("Brush", selection: editorRecipeBinding) {
                ForEach(EditorBrushCatalog.drawEntries, id: \.id) { entry in
                    Text(entry.displayName)
                        .tag(entry.id)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 128, maxWidth: 160)
            .accessibilityIdentifier("Brush Anchor")

            Divider()
                .frame(height: 20)

            Button {
                controller.stepBrush(larger: false)
                requestEditorFocus()
            } label: {
                Image(systemName: "minus")
            }
            .frame(width: editorControlExtent, height: editorControlExtent)
            .accessibilityLabel("Decrease Brush Size")

            Text("\(Int(controller.model.brushDiameter.rounded())) px")
                .monospacedDigit()
                .frame(minWidth: 48)

            Button {
                controller.stepBrush(larger: true)
                requestEditorFocus()
            } label: {
                Image(systemName: "plus")
            }
            .frame(width: editorControlExtent, height: editorControlExtent)
            .accessibilityLabel("Increase Brush Size")

            #if os(macOS)
            EditorInkColorWell(selection: inkColorBinding)
                .frame(
                    width: editorControlExtent,
                    height: editorControlExtent
                )
            #else
            ColorPicker(
                "Ink Color",
                selection: inkColorBinding,
                supportsOpacity: true
            )
            .labelsHidden()
            .frame(width: editorControlExtent, height: editorControlExtent)
            #endif

            Divider()
                .frame(height: 20)

            Button {
                controller.undo()
                requestEditorFocus()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .frame(width: editorControlExtent, height: editorControlExtent)
            .accessibilityLabel("Undo")
            .disabled(!controller.model.canUndo)

            Button {
                controller.redo()
                requestEditorFocus()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .frame(width: editorControlExtent, height: editorControlExtent)
            .accessibilityLabel("Redo")
            .disabled(!controller.model.canRedo)

            Button(role: .destructive) {
                controller.clear()
                requestEditorFocus()
            } label: {
                Image(systemName: "trash")
            }
            .frame(width: editorControlExtent, height: editorControlExtent)
            .accessibilityLabel("Clear Canvas")
        }
        .buttonStyle(.bordered)
        #if os(macOS)
        .controlSize(.small)
        #else
        .controlSize(.regular)
        #endif
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(.bar)
        // Selection compilation is deliberately not model-busy, so it never
        // captures unrelated text input or shortcuts. Transaction busy state
        // retains the existing history-safe control behavior.
        .disabled(controller.model.isBusy)
    }

    var editorRecipeBinding: Binding<BrushRecipeID> {
        Binding(
            get: { controller.model.selectedRecipeID },
            set: { recipeID in
                Task { @MainActor in
                    await controller.selectBrush(recipeID)
                    requestEditorFocus()
                }
            }
        )
    }

    // Kept for focused Stage 4 UI tests; production rendering uses the
    // professional editor catalog through `editorRecipeBinding`.
    var anchorRecipeBinding: Binding<BrushRecipeID> { editorRecipeBinding }

    private var inkColorBinding: Binding<Color> {
        Binding(
            get: {
                let color = controller.model.inkColor
                return Color(
                    .sRGB,
                    red: Double(color.red),
                    green: Double(color.green),
                    blue: Double(color.blue),
                    opacity: Double(color.alpha)
                )
            },
            set: { color in
                guard let encoded = Self.encodedSRGBColor(from: color) else {
                    return
                }
                controller.handleInkColor(encoded.inkColor)
            }
        )
    }

    static func encodedSRGBColor(from color: Color) -> EncodedSRGBColor? {
        #if os(macOS)
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else {
            return nil
        }
        return boundedEncodedSRGBColor(
            red: converted.redComponent,
            green: converted.greenComponent,
            blue: converted.blueComponent,
            alpha: converted.alphaComponent
        )
        #else
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let converted = UIColor(color).cgColor.converted(
                to: colorSpace,
                intent: .defaultIntent,
                options: nil
            ),
            let components = converted.components,
            components.count >= 4
        else {
            return nil
        }
        return boundedEncodedSRGBColor(
            red: components[0],
            green: components[1],
            blue: components[2],
            alpha: converted.alpha
        )
        #endif
    }

    private static func boundedEncodedSRGBColor(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        alpha: CGFloat
    ) -> EncodedSRGBColor? {
        let components = [red, green, blue, alpha]
        guard components.allSatisfy(\.isFinite) else { return nil }
        return EncodedSRGBColor(
            red: Float(min(1, max(0, red))),
            green: Float(min(1, max(0, green))),
            blue: Float(min(1, max(0, blue))),
            alpha: Float(min(1, max(0, alpha)))
        )
    }
}

#if os(macOS)
private struct EditorInkColorWell: NSViewRepresentable {
    @Binding var selection: Color

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> EditorNSColorWell {
        let colorWell = EditorNSColorWell(frame: .zero)
        colorWell.isBordered = true
        colorWell.isContinuous = true
        colorWell.target = context.coordinator
        colorWell.action = #selector(Coordinator.colorChanged(_:))
        colorWell.setAccessibilityLabel("Ink Color")
        colorWell.setAccessibilityIdentifier("Ink Color")
        return colorWell
    }

    func updateNSView(
        _ colorWell: EditorNSColorWell,
        context: Context
    ) {
        context.coordinator.selection = $selection
        colorWell.color = NSColor(selection)
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<Color>

        init(selection: Binding<Color>) {
            self.selection = selection
        }

        @objc
        func colorChanged(_ sender: NSColorWell) {
            selection.wrappedValue = Color(sender.color)
        }
    }
}

@MainActor
private final class EditorNSColorWell: NSColorWell {
    override func mouseDown(with event: NSEvent) {
        showColorPanel()
    }

    override func accessibilityPerformPress() -> Bool {
        showColorPanel()
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        showColorPanel()
        return true
    }

    private func showColorPanel() {
        activate(true)
        NSColorPanel.shared.makeKeyAndOrderFront(nil)
    }
}
#endif
