import PatternEngine

public struct ProfessionalBrushEntry: Equatable, Sendable {
    public let displayName: String
    public let definition: BrushDefinition
    public let program: BrushProgram

    public init(displayName: String, definition: BrushDefinition) {
        do {
            self.displayName = displayName
            self.definition = definition
            program = try BrushProgramCompiler.compile(definition)
        } catch {
            preconditionFailure("Invalid professional brush program: \(error)")
        }
    }

    public var id: BrushRecipeID { definition.id }
}

/// Ordered professional preset catalog. Entries are appended only in their
/// approved family order so persisted identities retain a stable position.
public enum ProfessionalBrushCatalog {
    public static let technicalInk = ProfessionalBrushEntry(
        displayName: "Technical Ink",
        definition: ProfessionalBrushDefinitions.technicalInk
    )

    public static let graphitePencil = ProfessionalBrushEntry(
        displayName: "Graphite Pencil",
        definition: ProfessionalBrushDefinitions.graphitePencil
    )

    public static let naturalCharcoal = ProfessionalBrushEntry(
        displayName: "Natural Charcoal",
        definition: ProfessionalBrushDefinitions.naturalCharcoal
    )

    public static let chiselMarker = ProfessionalBrushEntry(
        displayName: "Chisel Marker",
        definition: ProfessionalBrushDefinitions.chiselMarker
    )

    public static let all = [technicalInk, graphitePencil, naturalCharcoal, chiselMarker]

    public static func entry(for id: BrushRecipeID) -> ProfessionalBrushEntry? {
        all.first { $0.id == id }
    }
}
