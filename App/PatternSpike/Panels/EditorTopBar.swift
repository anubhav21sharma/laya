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

    var body: some View {
        HStack(spacing: 8) {
            Button {
                controller.stepBrush(larger: false)
            } label: {
                Image(systemName: "minus")
            }
            .accessibilityLabel("Decrease Brush Size")

            Text("\(Int(controller.model.brushDiameter.rounded())) px")
                .monospacedDigit()
                .frame(minWidth: 48)

            Button {
                controller.stepBrush(larger: true)
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Increase Brush Size")

            ColorPicker(
                "Ink Color",
                selection: inkColorBinding,
                supportsOpacity: true
            )
            .labelsHidden()

            Divider()
                .frame(height: 20)

            Button {
                controller.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .accessibilityLabel("Undo")
            .disabled(!controller.model.canUndo)

            Button {
                controller.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .accessibilityLabel("Redo")
            .disabled(!controller.model.canRedo)

            Button(role: .destructive) {
                controller.clear()
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Clear Canvas")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(8)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .disabled(controller.model.isBusy)
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
