import EditorCore
import SwiftUI

struct ToolRail: View {
    let controller: EditorSessionController

    var body: some View {
        VStack(spacing: 6) {
            toolButton(
                .draw,
                label: "Draw",
                systemImage: "pencil.tip"
            )
            toolButton(
                .erase,
                label: "Erase",
                systemImage: "eraser"
            )
        }
        .padding(8)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .disabled(controller.model.isBusy)
    }

    private func toolButton(
        _ tool: EditorTool,
        label: String,
        systemImage: String
    ) -> some View {
        Button {
            controller.handleTool(tool)
        } label: {
            Label(label, systemImage: systemImage)
                .frame(minWidth: 72, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .background(
            controller.model.tool == tool
                ? Color.accentColor.opacity(0.2)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .accessibilityAddTraits(
            controller.model.tool == tool ? .isSelected : []
        )
    }
}
