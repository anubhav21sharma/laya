import Observation
import PatternEngine

@MainActor
@Observable
public final class EditorModel {
    public private(set) var tool: EditorTool = .draw
    public private(set) var inkColor: InkColor = .black
    public private(set) var brushDiameter: Float = 20
    public private(set) var eraserStrength: Float = 1
    public private(set) var selectedRecipeID = AnchorBrushCatalog.defaultDraw.id
    public private(set) var showGrid = false
    public private(set) var pixelSize = PixelSize(width: 256, height: 256)
    public private(set) var periodicConfiguration =
        PeriodicSymmetryConfiguration.defaultConfiguration(
            presetID: .grid,
            canonicalRasterSize: PixelSize(width: 256, height: 256)
        )
    public private(set) var canUndo = false
    public private(set) var canRedo = false
    public private(set) var isBusy = false

    public var selectedRecipe: BrushRecipe {
        AnchorBrushCatalog.drawEntry(for: selectedRecipeID)?.recipe
            ?? AnchorBrushCatalog.defaultDraw.recipe
    }

    public var tiling: TilingKind {
        periodicConfiguration.presetID
    }

    public init(tiling: TilingKind = .grid) {
        periodicConfiguration = .defaultConfiguration(
            presetID: tiling,
            canonicalRasterSize: pixelSize
        )
    }

    public func confirmTool(_ tool: EditorTool) {
        self.tool = tool
    }

    public func confirmInkColor(_ inkColor: InkColor) {
        self.inkColor = inkColor
    }

    public func confirmRecipe(_ recipeID: BrushRecipeID) {
        guard AnchorBrushCatalog.drawEntry(for: recipeID) != nil else {
            return
        }
        selectedRecipeID = recipeID
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
        periodicConfiguration = .defaultConfiguration(
            presetID: tiling,
            canonicalRasterSize: pixelSize
        )
    }

    public func confirmPeriodicConfiguration(
        _ configuration: PeriodicSymmetryConfiguration
    ) {
        periodicConfiguration = configuration
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
