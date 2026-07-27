import PatternEngine

public enum AnchorBrushRole: UInt8, Equatable, Sendable {
    case draw
    case erase
}

public struct AnchorBrushEntry: Equatable, Sendable {
    public let displayName: String
    public let role: AnchorBrushRole
    public let definition: BrushDefinition
    public let program: BrushProgram

    public init(
        displayName: String,
        role: AnchorBrushRole,
        definition: BrushDefinition,
        program: BrushProgram
    ) {
        precondition(
            program.definition == definition,
            "Anchor program must own the catalog definition"
        )
        self.displayName = displayName
        self.role = role
        self.definition = definition
        self.program = program
    }

    fileprivate init(
        displayName: String,
        role: AnchorBrushRole,
        recipe: BrushRecipe
    ) {
        do {
            let definition = try LegacyBrushRecipeAdapter.definition(
                from: recipe,
                displayName: displayName
            )
            let program = try BrushProgramCompiler.compile(definition)
            self.init(
                displayName: displayName,
                role: role,
                definition: definition,
                program: program
            )
        } catch {
            preconditionFailure("Invalid built-in anchor program: \(error)")
        }
    }

    public var id: BrushRecipeID { definition.id }

    public var compatibilityRecipe: BrushRecipe {
        guard let recipe = program.compatibilityRecipe else {
            preconditionFailure(
                "Built-in anchor must remain legacy-compatible"
            )
        }
        return recipe
    }

    @available(
        *,
        deprecated,
        renamed: "compatibilityRecipe"
    )
    public var recipe: BrushRecipe { compatibilityRecipe }
}

/// Slice 4 acceptance fixtures, not a user-editable brush library.
public enum AnchorBrushCatalog {
    private struct Storage {
        let technicalInk: AnchorBrushEntry
        let dryPencil: AnchorBrushEntry
        let glazeMarker: AnchorBrushEntry
        let boundedWash: AnchorBrushEntry
        let hardRoundEraser: AnchorBrushEntry
        let drawAnchors: [AnchorBrushEntry]
        let all: [AnchorBrushEntry]

        init() {
            technicalInk = AnchorBrushEntry(
                displayName: "Technical Ink",
                role: .draw,
                recipe: AnchorBrushCatalog.builtIn {
                    try BrushRecipe(
                        id: BrushRecipeID("builtin.technical-ink"),
                        shape: .hardRound,
                        grain: .opaque,
                        material: .ink,
                        baseSpacingFraction: 0.08,
                        maximumSpacingFraction: 0.15,
                        sizeMapping: .boundedPower(
                            input: .pressure,
                            output: 0.3...1,
                            exponent: 0.75
                        )
                    )
                }
            )

            dryPencil = AnchorBrushEntry(
                displayName: "Dry Pencil",
                role: .draw,
                recipe: AnchorBrushCatalog.builtIn {
                    try BrushRecipe(
                        id: BrushRecipeID("builtin.dry-pencil"),
                        shape: .hardRound,
                        grain: .paper,
                        grainCoordinateMode: .canonical,
                        grainTransform: BrushGrainTransform(
                            scale: 1.5,
                            rotation: 0,
                            offset: .zero
                        ),
                        material: BrushMaterial(
                            family: .dry,
                            strength: 0.85,
                            wetness: 0,
                            bleedRadius: 0,
                            softenPasses: 0,
                            accumulationLimit: 1
                        ),
                        baseSpacingFraction: 0.1,
                        maximumSpacingFraction: 0.2,
                        baseFlow: 0.7,
                        strokeOpacity: 0.9,
                        baseHardness: 0.75,
                        baseScatterFraction: 0.03,
                        aspectRatio: 0.7,
                        sizeMapping: .boundedPower(
                            input: .pressure,
                            output: 0.3...1,
                            exponent: 1.25
                        ),
                        flowMapping: .linear(
                            input: .pressure,
                            output: 0.35...1
                        ),
                        rotationMapping: .linear(
                            input: .direction,
                            output: -Float.pi...Float.pi
                        ),
                        scatterMapping: .linear(
                            input: .pressure,
                            output: 0.5...1
                        ),
                        randomization: BrushRandomization(
                            spacing: 0.1,
                            scatter: 1,
                            rotation: 0,
                            grain: 0.35,
                            material: 0.15
                        )
                    )
                }
            )

            glazeMarker = AnchorBrushEntry(
                displayName: "Glaze Marker",
                role: .draw,
                recipe: AnchorBrushCatalog.builtIn {
                    try BrushRecipe(
                        id: BrushRecipeID("builtin.glaze-marker"),
                        shape: .chisel,
                        grain: .opaque,
                        material: BrushMaterial(
                            family: .glaze,
                            strength: 0.8,
                            wetness: 0.2,
                            bleedRadius: 0,
                            softenPasses: 0,
                            accumulationLimit: 0.85
                        ),
                        baseSpacingFraction: 0.16,
                        maximumSpacingFraction: 0.3,
                        baseFlow: 0.35,
                        strokeOpacity: 0.75,
                        baseHardness: 0.7,
                        aspectRatio: 0.7,
                        sizeMapping: .linear(
                            input: .pressure,
                            output: 0.6...1
                        ),
                        flowMapping: .linear(
                            input: .pressure,
                            output: 0.5...1
                        ),
                        rotationMapping: .linear(
                            input: .direction,
                            output: -Float.pi...Float.pi
                        )
                    )
                }
            )

            boundedWash = AnchorBrushEntry(
                displayName: "Bounded Wash",
                role: .draw,
                recipe: AnchorBrushCatalog.builtIn {
                    try BrushRecipe(
                        id: BrushRecipeID("builtin.bounded-wash"),
                        shape: .softRound,
                        grain: .paper,
                        grainCoordinateMode: .canonical,
                        grainTransform: BrushGrainTransform(
                            scale: 1.2,
                            rotation: 0,
                            offset: .zero
                        ),
                        material: BrushMaterial(
                            family: .boundedWash,
                            strength: 1,
                            wetness: 0.8,
                            bleedRadius: 12,
                            softenPasses: 2,
                            accumulationLimit: 0.75
                        ),
                        baseSpacingFraction: 0.15,
                        maximumSpacingFraction: 0.3,
                        baseFlow: 0.85,
                        strokeOpacity: 0.85,
                        baseHardness: 0.2,
                        sizeMapping: .linear(
                            input: .pressure,
                            output: 0.6...1
                        ),
                        flowMapping: .linear(
                            input: .pressure,
                            output: 0.5...1
                        ),
                        randomization: BrushRandomization(
                            spacing: 0.05,
                            scatter: 0,
                            rotation: 0,
                            grain: 0.2,
                            material: 0.1
                        ),
                        replayMode: .boundedWholeStroke,
                        replayLimits: BrushReplayLimits(
                            maximumSamples: 4_096,
                            maximumDabs: 4_096,
                            maximumProjectedInstances: 4_096
                        )
                    )
                }
            )

            hardRoundEraser = AnchorBrushEntry(
                displayName: "Hard Round Eraser",
                role: .erase,
                recipe: AnchorBrushCatalog.builtIn {
                    try BrushRecipe(
                        id: BrushRecipeID("builtin.hard-round-eraser"),
                        shape: .hardRound,
                        grain: .opaque,
                        material: .ink
                    )
                }
            )

            drawAnchors = [
                technicalInk,
                dryPencil,
                glazeMarker,
                boundedWash,
            ]
            all = drawAnchors + [hardRoundEraser]
        }
    }

    private static let storage = Storage()

    public static var technicalInk: AnchorBrushEntry {
        storage.technicalInk
    }

    public static var dryPencil: AnchorBrushEntry {
        storage.dryPencil
    }

    public static var glazeMarker: AnchorBrushEntry {
        storage.glazeMarker
    }

    public static var boundedWash: AnchorBrushEntry {
        storage.boundedWash
    }

    public static var hardRoundEraser: AnchorBrushEntry {
        storage.hardRoundEraser
    }

    public static var drawAnchors: [AnchorBrushEntry] {
        storage.drawAnchors
    }

    public static var all: [AnchorBrushEntry] {
        storage.all
    }

    public static var defaultDraw: AnchorBrushEntry {
        storage.technicalInk
    }

    public static func entry(for id: BrushRecipeID) -> AnchorBrushEntry? {
        all.first { $0.id == id }
    }

    public static func compatibilityRecipe(
        for id: BrushRecipeID
    ) -> BrushRecipe? {
        entry(for: id)?.compatibilityRecipe
    }

    @available(
        *,
        deprecated,
        message: "Use entry(for:)?.compatibilityRecipe."
    )
    public static func recipe(for id: BrushRecipeID) -> BrushRecipe? {
        compatibilityRecipe(for: id)
    }

    public static func drawEntry(for id: BrushRecipeID) -> AnchorBrushEntry? {
        drawAnchors.first { $0.id == id }
    }

    private static func builtIn(
        _ makeRecipe: () throws -> BrushRecipe
    ) -> BrushRecipe {
        do {
            return try makeRecipe()
        } catch {
            preconditionFailure("Invalid built-in anchor recipe: \(error)")
        }
    }
}
