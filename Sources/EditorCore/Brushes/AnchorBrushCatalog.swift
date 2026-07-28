import PatternEngine

public enum AnchorBrushRole: UInt8, Equatable, Sendable { case draw, erase }

public struct AnchorBrushEntry: Equatable, Sendable {
    public let displayName: String
    public let role: AnchorBrushRole
    public let definition: BrushDefinition
    public let program: BrushProgram

    public init(displayName: String, role: AnchorBrushRole, definition: BrushDefinition) {
        do {
            self.displayName = displayName
            self.role = role
            self.definition = definition
            program = try BrushProgramCompiler.compile(definition)
        } catch {
            preconditionFailure("Invalid native anchor program: \(error)")
        }
    }

    public var id: BrushRecipeID { definition.id }

    /// Legacy characterization tooling remains source-compatible while native
    /// activation always uses `definition` and `program` above.
    @available(*, deprecated, message: "Native anchors have no compatibility program.")
    public var compatibilityRecipe: BrushRecipe {
        do {
            return try BrushRecipe(id: id)
        } catch {
            preconditionFailure("Invalid compatibility diagnostic recipe: \(error)")
        }
    }

    @available(*, deprecated, renamed: "compatibilityRecipe")
    public var recipe: BrushRecipe { compatibilityRecipe }
}

/// Fixed native Stage 4 anchors, intentionally not a user-editable library.
public enum AnchorBrushCatalog {
    public static let ink = entry("Native Ink", .draw, StageFourAnchorDefinitions.ink)
    public static let dryMedia = entry("Native Dry Media", .draw, StageFourAnchorDefinitions.dryMedia)
    public static let glaze = entry("Native Glaze", .draw, StageFourAnchorDefinitions.glaze)
    public static let marker = entry("Native Marker", .draw, StageFourAnchorDefinitions.marker)
    public static let airbrush = entry("Native Airbrush", .draw, StageFourAnchorDefinitions.airbrush)
    public static let eraser = entry("Native Eraser", .erase, StageFourAnchorDefinitions.eraser)
    public static let drawAnchors = [ink, dryMedia, glaze, marker, airbrush]
    public static let all = drawAnchors + [eraser]
    public static let defaultDraw = ink

    @available(*, deprecated, renamed: "ink") public static let technicalInk = ink
    @available(*, deprecated, renamed: "dryMedia") public static let dryPencil = dryMedia
    @available(*, deprecated, renamed: "marker") public static let glazeMarker = marker
    @available(*, deprecated, renamed: "glaze") public static let boundedWash = glaze
    @available(*, deprecated, renamed: "eraser") public static let hardRoundEraser = eraser

    public static func entry(for id: BrushRecipeID) -> AnchorBrushEntry? {
        all.first { $0.id == id }
    }

    public static func drawEntry(for id: BrushRecipeID) -> AnchorBrushEntry? {
        drawAnchors.first { $0.id == id }
    }

    @available(*, deprecated, message: "Native activation uses entry(for:).")
    public static func recipe(for id: BrushRecipeID) -> BrushRecipe? {
        entry(for: id)?.compatibilityRecipe
    }

    private static func entry(
        _ name: String, _ role: AnchorBrushRole, _ definition: BrushDefinition
    ) -> AnchorBrushEntry {
        AnchorBrushEntry(displayName: name, role: role, definition: definition)
    }
}
