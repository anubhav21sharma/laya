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
    public private(set) var finiteConfiguration: FiniteSymmetryConfiguration?
    public private(set) var radialGeometryLocked = false
    public private(set) var documentDomainLocked = false
    public private(set) var canUndo = false
    public private(set) var canRedo = false
    public private(set) var isBusy = false

    public var selectedRecipe: BrushRecipe {
        AnchorBrushCatalog.drawEntry(for: selectedRecipeID)?.recipe
            ?? AnchorBrushCatalog.defaultDraw.recipe
    }

    public var tiling: TilingKind {
        switch finiteConfiguration {
        case nil:
            periodicConfiguration.presetID
        case .plain:
            .plainCanvas
        case let .radial(configuration):
            switch configuration.kind {
            case .mirror:
                .radialMirror
            case .rotation:
                .radialRotation
            case .mandala:
                .radialMandala
            }
        }
    }

    public var documentConfiguration: SymmetryDocumentConfiguration {
        finiteConfiguration.map(SymmetryDocumentConfiguration.finite)
            ?? .periodic(periodicConfiguration)
    }

    public var radialConfiguration: RadialSymmetryConfiguration? {
        guard case let .radial(configuration) = finiteConfiguration else {
            return nil
        }
        return configuration
    }

    public init(tiling: TilingKind = .grid) {
        precondition(
            tiling.isPeriodic,
            "EditorModel tiling initializer requires a periodic preset"
        )
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
        guard tiling.isPeriodic else { return }
        periodicConfiguration = .defaultConfiguration(
            presetID: tiling,
            canonicalRasterSize: pixelSize
        )
    }

    public func confirmPeriodicConfiguration(
        _ configuration: PeriodicSymmetryConfiguration
    ) {
        periodicConfiguration = configuration
        finiteConfiguration = nil
    }

    public func confirmFiniteConfiguration(
        _ configuration: FiniteSymmetryConfiguration
    ) {
        finiteConfiguration = configuration
    }

    public func confirmDocumentConfiguration(
        _ configuration: SymmetryDocumentConfiguration
    ) {
        switch configuration {
        case let .periodic(periodic):
            confirmPeriodicConfiguration(periodic)
        case let .finite(finite):
            confirmFiniteConfiguration(finite)
        }
    }

    public func confirmGeometryLocks(
        documentDomainLocked: Bool,
        radialGeometryLocked: Bool
    ) {
        self.documentDomainLocked = documentDomainLocked
        self.radialGeometryLocked = radialGeometryLocked
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
