import Foundation

@MainActor
protocol EditorBrushSelectionStore: Sendable {
    func readSelectedBrushID() -> String?
    func writeSelectedBrushID(_ id: String)
}

@MainActor
struct UserDefaultsEditorBrushSelectionStore: EditorBrushSelectionStore {
    static let live = UserDefaultsEditorBrushSelectionStore(
        defaults: .standard
    )
    static let selectedBrushIDKey = "editor.selectedDrawBrushID"

    let defaults: UserDefaults

    func readSelectedBrushID() -> String? {
        defaults.string(forKey: Self.selectedBrushIDKey)
    }

    func writeSelectedBrushID(_ id: String) {
        defaults.set(id, forKey: Self.selectedBrushIDKey)
    }
}
