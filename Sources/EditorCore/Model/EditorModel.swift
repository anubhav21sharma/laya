import Observation
import PatternEngine

@MainActor
@Observable
public final class EditorModel {
    public private(set) var tiling: TilingKind

    public init(tiling: TilingKind = .grid) {
        self.tiling = tiling
    }

    public func confirmTiling(_ tiling: TilingKind) {
        self.tiling = tiling
    }
}
