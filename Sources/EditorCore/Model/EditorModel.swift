import Observation
import PatternEngine

@MainActor
@Observable
public final class EditorModel {
    public private(set) var tool: EditorTool = .draw
    public private(set) var inkColor: InkColor = .black
    public private(set) var brushDiameter: Float = 20
    public private(set) var eraserStrength: Float = 1
    public private(set) var showGrid = false
    public private(set) var tiling: TilingKind = .grid
    public private(set) var pixelSize = PixelSize(width: 256, height: 256)
    public private(set) var canUndo = false
    public private(set) var canRedo = false
    public private(set) var isBusy = false

    public init(tiling: TilingKind = .grid) {
        self.tiling = tiling
    }

    public func confirmTool(_ tool: EditorTool) {
        self.tool = tool
    }

    public func confirmInkColor(_ inkColor: InkColor) {
        self.inkColor = inkColor
    }

    public func confirmBrushDiameter(_ brushDiameter: Float) {
        guard EditorConfiguration.isValidBrushDiameter(
            brushDiameter,
            pixelSize: pixelSize
        ) else {
            return
        }
        self.brushDiameter = brushDiameter
    }

    public func confirmGridVisibility(_ showGrid: Bool) {
        self.showGrid = showGrid
    }

    public func confirmTiling(_ tiling: TilingKind) {
        self.tiling = tiling
    }

    public func confirmPixelSize(_ pixelSize: PixelSize) {
        guard EditorConfiguration.isValidTileSize(pixelSize) else {
            return
        }
        self.pixelSize = pixelSize
        brushDiameter = min(
            brushDiameter,
            EditorConfiguration.brushMaximum(for: pixelSize)
        )
    }

    public func confirmHistoryAvailability(
        canUndo: Bool,
        canRedo: Bool
    ) {
        self.canUndo = canUndo
        self.canRedo = canRedo
    }

    public func confirmBusy(_ isBusy: Bool) {
        self.isBusy = isBusy
    }
}
