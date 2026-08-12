import PatternEngine

public struct ProfessionalBrushStatus: Equatable, Sendable {
    public let engineIntegrated: Bool
    public let softwarePerformancePassed: Bool
    public let manualQualityPassed: Bool
    public let physicalProfilePassed: Bool
    public let productAccepted: Bool

    public init(
        engineIntegrated: Bool,
        softwarePerformancePassed: Bool,
        manualQualityPassed: Bool,
        physicalProfilePassed: Bool,
        productAccepted: Bool
    ) {
        precondition(
            !productAccepted || (
                engineIntegrated
                    && softwarePerformancePassed
                    && manualQualityPassed
                    && physicalProfilePassed
            ),
            "Product acceptance requires every prerequisite state"
        )
        self.engineIntegrated = engineIntegrated
        self.softwarePerformancePassed = softwarePerformancePassed
        self.manualQualityPassed = manualQualityPassed
        self.physicalProfilePassed = physicalProfilePassed
        self.productAccepted = productAccepted
    }

    public var laboratoryOnlyMessage: String {
        if productAccepted {
            return "Product accepted."
        }
        return "Available only in Brush Lab while manual quality and physical profile validation are pending."
    }
}

public struct ProfessionalBrushEntry: Equatable, Sendable {
    public let displayName: String
    public let definition: BrushDefinition
    public let program: BrushProgram
    public let status: ProfessionalBrushStatus

    public init(
        displayName: String,
        definition: BrushDefinition,
        status: ProfessionalBrushStatus
    ) {
        do {
            self.displayName = displayName
            self.definition = definition
            self.status = status
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
    private static let candidateStatus = ProfessionalBrushStatus(
        engineIntegrated: true,
        softwarePerformancePassed: true,
        manualQualityPassed: false,
        physicalProfilePassed: false,
        productAccepted: false
    )

    public static let technicalInk = ProfessionalBrushEntry(
        displayName: "Technical Ink",
        definition: ProfessionalBrushDefinitions.technicalInk,
        status: candidateStatus
    )

    public static let graphitePencil = ProfessionalBrushEntry(
        displayName: "Graphite Pencil",
        definition: ProfessionalBrushDefinitions.graphitePencil,
        status: candidateStatus
    )

    public static let naturalCharcoal = ProfessionalBrushEntry(
        displayName: "Natural Charcoal",
        definition: ProfessionalBrushDefinitions.naturalCharcoal,
        status: candidateStatus
    )

    public static let chiselMarker = ProfessionalBrushEntry(
        displayName: "Chisel Marker",
        definition: ProfessionalBrushDefinitions.chiselMarker,
        status: candidateStatus
    )

    public static let all = [technicalInk, graphitePencil, naturalCharcoal, chiselMarker]

    public static func entry(for id: BrushRecipeID) -> ProfessionalBrushEntry? {
        all.first { $0.id == id }
    }
}
