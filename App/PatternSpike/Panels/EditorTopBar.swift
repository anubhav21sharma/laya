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

            Picker("Brush", selection: anchorRecipeBinding) {
                ForEach(AnchorBrushCatalog.drawAnchors, id: \.id) { entry in
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

            ColorPicker(
                "Ink Color",
                selection: inkColorBinding,
                supportsOpacity: true
            )
            .labelsHidden()
            .frame(width: editorControlExtent, height: editorControlExtent)

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
        .disabled(controller.model.isBusy)
    }

    var anchorRecipeBinding: Binding<BrushRecipeID> {
        Binding(
            get: { controller.model.selectedRecipeID },
            set: { recipeID in
                controller.handleRecipe(recipeID)
                requestEditorFocus()
            }
        )
    }

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
                defer { requestEditorFocus() }
                guard let inkColor = Self.sRGBInkColor(from: color) else {
                    return
                }
                controller.handleInkColor(inkColor)
            }
        )
    }

    private static func sRGBInkColor(from color: Color) -> InkColor? {
        #if os(macOS)
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else {
            return nil
        }
        return InkColor(
            red: Float(converted.redComponent),
            green: Float(converted.greenComponent),
            blue: Float(converted.blueComponent),
            alpha: Float(converted.alphaComponent)
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
        return InkColor(
            red: Float(components[0]),
            green: Float(components[1]),
            blue: Float(components[2]),
            alpha: Float(components[3])
        )
        #endif
    }
}
