import EditorCore
import SwiftUI

struct ToolRail: View {
    let controller: EditorSessionController
    let requestEditorFocus: @MainActor () -> Void

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
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(width: editorControlExtent + 12)
        .background(.bar)
        .disabled(controller.model.isBusy)
    }

    private func toolButton(
        _ tool: EditorTool,
        label: String,
        systemImage: String
    ) -> some View {
        Button {
            controller.handleTool(tool)
            requestEditorFocus()
        } label: {
            Image(systemName: systemImage)
                .frame(
                    width: editorControlExtent,
                    height: editorControlExtent
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            controller.model.tool == tool ? Color.accentColor : Color.primary
        )
        .background(
            controller.model.tool == tool
                ? Color.accentColor.opacity(0.18)
                : Color.clear
        )
        .accessibilityLabel(label)
        .accessibilityAddTraits(
            controller.model.tool == tool ? .isSelected : []
        )
        .help(label)
    }
}
