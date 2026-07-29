public enum StrokeCompositeMode: UInt32, Equatable, Sendable {
    case draw = 0
    case erase = 1
}

public enum BrushRenderIdentityError: Error, Equatable, Sendable {
    case emptyDefinitionID
    case invalidSemanticHash
}

public struct BrushRenderIdentity: Equatable, Sendable {
    public let definitionID: BrushRecipeID
    public let semanticHash: String

    public init(
        definitionID: BrushRecipeID,
        semanticHash: String
    ) throws {
        guard !definitionID.rawValue.isEmpty else {
            throw BrushRenderIdentityError.emptyDefinitionID
        }
        let bytes = semanticHash.utf8
        guard bytes.count == 64,
              bytes.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              })
        else {
            throw BrushRenderIdentityError.invalidSemanticHash
        }
        self.definitionID = definitionID
        self.semanticHash = semanticHash
    }
}

public struct StrokeRenderStyle: Equatable, Sendable {
    public let color: InkColor
    public let diameter: Float
    public let compositeMode: StrokeCompositeMode
    public let eraserStrength: Float
    public let program: BrushProgram
    public let renderIdentity: BrushRenderIdentity
    public let seed: UInt64

    public init(
        color: InkColor,
        diameter: Float,
        compositeMode: StrokeCompositeMode,
        eraserStrength: Float,
        program: BrushProgram,
        renderIdentity: BrushRenderIdentity,
        seed: UInt64
    ) {
        precondition(diameter.isFinite && diameter > 0)
        precondition(
            eraserStrength.isFinite && (0...1).contains(eraserStrength)
        )
        precondition(seed != 0, "Stroke seed must be nonzero")
        precondition(
            renderIdentity.definitionID == program.definition.id,
            "Render identity must match the compiled brush program"
        )
        self.color = color
        self.diameter = diameter
        self.compositeMode = compositeMode
        self.eraserStrength = eraserStrength
        self.program = program
        self.renderIdentity = renderIdentity
        self.seed = seed
    }

}
