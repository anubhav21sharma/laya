import PatternEngine

/// A selectable editor preset. This composed catalog intentionally leaves the
/// Stage 4 anchor catalog untouched for its diagnostic and evidence consumers.
public struct EditorBrushEntry: Equatable, Sendable {
    public let displayName: String
    public let definition: BrushDefinition
    public let program: BrushProgram

    public init(displayName: String, definition: BrushDefinition) {
        do {
            self.displayName = displayName
            self.definition = definition
            program = try BrushProgramCompiler.compile(definition)
        } catch {
            preconditionFailure("Invalid editor brush program: \(error)")
        }
    }

    public var id: BrushRecipeID { definition.id }
}

/// The user-facing Stage 5 editor catalog. Stage 4 anchors remain available
/// through `AnchorBrushCatalog` for evidence and diagnostic-only paths.
public enum EditorBrushCatalog {
    public static let technicalInk = EditorBrushEntry(
        displayName: ProfessionalBrushCatalog.technicalInk.displayName,
        definition: ProfessionalBrushCatalog.technicalInk.definition
    )
    public static let graphitePencil = EditorBrushEntry(
        displayName: ProfessionalBrushCatalog.graphitePencil.displayName,
        definition: ProfessionalBrushCatalog.graphitePencil.definition
    )
    public static let naturalCharcoal = EditorBrushEntry(
        displayName: ProfessionalBrushCatalog.naturalCharcoal.displayName,
        definition: ProfessionalBrushCatalog.naturalCharcoal.definition
    )
    public static let chiselMarker = EditorBrushEntry(
        displayName: ProfessionalBrushCatalog.chiselMarker.displayName,
        definition: ProfessionalBrushCatalog.chiselMarker.definition
    )
    public static let nativeGlaze = EditorBrushEntry(
        displayName: AnchorBrushCatalog.glaze.displayName,
        definition: AnchorBrushCatalog.glaze.definition
    )
    public static let nativeAirbrush = EditorBrushEntry(
        displayName: AnchorBrushCatalog.airbrush.displayName,
        definition: AnchorBrushCatalog.airbrush.definition
    )

    public static let drawEntries = [
        technicalInk,
        graphitePencil,
        naturalCharcoal,
        chiselMarker,
        nativeGlaze,
        nativeAirbrush,
    ]
    public static let defaultDraw = technicalInk
    public static let eraser = AnchorBrushCatalog.eraser

    public static func drawEntry(for id: BrushRecipeID) -> EditorBrushEntry? {
        drawEntries.first { $0.id == id }
    }

    /// Resolves current editor IDs and the precise legacy IDs accepted by the
    /// Stage 5 migration contract. All other IDs are deliberately rejected.
    public static func resolveSelection(_ id: BrushRecipeID) -> BrushRecipeID? {
        switch id.rawValue {
        case technicalInk.id.rawValue,
             graphitePencil.id.rawValue,
             naturalCharcoal.id.rawValue,
             chiselMarker.id.rawValue,
             nativeGlaze.id.rawValue,
             nativeAirbrush.id.rawValue:
            id
        case "builtin.native-ink", "builtin.technical-ink":
            technicalInk.id
        case "builtin.native-dry-media", "builtin.dry-pencil":
            graphitePencil.id
        case "builtin.native-marker", "builtin.glaze-marker":
            chiselMarker.id
        case "builtin.native-glaze":
            nativeGlaze.id
        case "builtin.native-airbrush":
            nativeAirbrush.id
        default:
            nil
        }
    }
}
