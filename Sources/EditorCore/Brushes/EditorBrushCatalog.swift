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

public enum EditorBrushSelectionResolution: Equatable, Sendable {
    case product(EditorBrushEntry)
    case laboratoryOnly(ProfessionalBrushEntry)
}

/// The user-facing editor catalog. Professional definitions remain isolated in
/// Brush Lab while their corrective rebuild is pending.
public enum EditorBrushCatalog {
    public static let nativeInk = EditorBrushEntry(
        displayName: AnchorBrushCatalog.ink.displayName,
        definition: AnchorBrushCatalog.ink.definition
    )
    public static let nativeDryMedia = EditorBrushEntry(
        displayName: AnchorBrushCatalog.dryMedia.displayName,
        definition: AnchorBrushCatalog.dryMedia.definition
    )
    public static let nativeMarker = EditorBrushEntry(
        displayName: AnchorBrushCatalog.marker.displayName,
        definition: AnchorBrushCatalog.marker.definition
    )
    public static let nativeGlaze = EditorBrushEntry(
        displayName: AnchorBrushCatalog.glaze.displayName,
        definition: AnchorBrushCatalog.glaze.definition
    )
    public static let nativeAirbrush = EditorBrushEntry(
        displayName: AnchorBrushCatalog.airbrush.displayName,
        definition: AnchorBrushCatalog.airbrush.definition
    )

    /// Source-compatible names for the former product picker entries. These
    /// resolve to the vetted native anchors; professional definitions live only
    /// in `ProfessionalBrushCatalog` for Brush Lab.
    public static var technicalInk: EditorBrushEntry { nativeInk }
    public static var graphitePencil: EditorBrushEntry { nativeDryMedia }
    public static var naturalCharcoal: EditorBrushEntry { nativeDryMedia }
    public static var chiselMarker: EditorBrushEntry { nativeMarker }

    public static let drawEntries = [
        nativeInk,
        nativeDryMedia,
        nativeMarker,
        nativeGlaze,
        nativeAirbrush,
    ]
    public static let defaultDraw = nativeInk
    public static let eraser = AnchorBrushCatalog.eraser

    public static func drawEntry(for id: BrushRecipeID) -> EditorBrushEntry? {
        drawEntries.first { $0.id == id }
    }

    /// Resolves current editor IDs and their retained legacy aliases. The
    /// professional IDs deliberately remain unresolved for product selection.
    public static func resolveSelection(_ id: BrushRecipeID) -> BrushRecipeID? {
        switch id.rawValue {
        case nativeInk.id.rawValue,
             nativeDryMedia.id.rawValue,
             nativeMarker.id.rawValue,
             nativeGlaze.id.rawValue,
             nativeAirbrush.id.rawValue:
            id
        case "builtin.native-ink", "builtin.technical-ink":
            nativeInk.id
        case "builtin.native-dry-media", "builtin.dry-pencil":
            nativeDryMedia.id
        case "builtin.native-marker", "builtin.glaze-marker":
            nativeMarker.id
        case "builtin.native-glaze":
            nativeGlaze.id
        case "builtin.native-airbrush":
            nativeAirbrush.id
        default:
            nil
        }
    }

    /// Keeps persisted professional IDs explicit: they resolve only to their
    /// Brush Lab definition and status, never to a substitute product brush.
    public static func resolvePersistedSelection(
        _ id: BrushRecipeID
    ) -> EditorBrushSelectionResolution? {
        if let professional = ProfessionalBrushCatalog.entry(for: id) {
            return .laboratoryOnly(professional)
        }
        guard let productID = resolveSelection(id),
              let product = drawEntry(for: productID)
        else {
            return nil
        }
        return .product(product)
    }
}
