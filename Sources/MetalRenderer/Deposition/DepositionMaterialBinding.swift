import CShaderTypes
import Metal
import PatternEngine

public enum DepositionTextureSlot:
    Int,
    CaseIterable,
    Comparable,
    Sendable
{
    case primaryShape = 0
    case secondaryShape = 1
    case primaryGrain = 2
    case secondaryGrain = 3

    public static func < (
        lhs: DepositionTextureSlot,
        rhs: DepositionTextureSlot
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

@MainActor
public struct DepositionTextureBindings {
    public var boundSlots: [DepositionTextureSlot] {
        storage.keys.sorted()
    }

    private let storage: [DepositionTextureSlot: any MTLTexture]

    init(_ storage: [DepositionTextureSlot: any MTLTexture]) {
        self.storage = storage
    }

    public subscript(
        slot: DepositionTextureSlot
    ) -> (any MTLTexture)? {
        storage[slot]
    }
}

@MainActor
public struct DepositionMaterialBinding {
    public let uniforms: PatternDepositionMaterialUniforms
    public let textures: DepositionTextureBindings

    public init(compiledBrush: CompiledBrush) throws {
        try self.init(
            uniformTemplate: compiledBrush.uniformTemplate,
            textures: compiledBrush.textures
        )
    }

    static var harnessOpaque: Self {
        Self(
            uniforms: PatternDepositionMaterialUniforms(
                coverageParameters: SIMD4(0, 0, 0, 1),
                secondaryShapeTransform: SIMD4(1, 0, 0, 0),
                edgeParameters: SIMD4(1, 0, 0, 0),
                options: SIMD4(
                    PatternDepositionShapeCombinationReplace,
                    1,
                    PatternDepositionShapeKindHardRound,
                    PatternDepositionShapeKindHardRound
                )
            ),
            textures: DepositionTextureBindings([:])
        )
    }

    private init(
        uniforms: PatternDepositionMaterialUniforms,
        textures: DepositionTextureBindings
    ) {
        self.uniforms = uniforms
        self.textures = textures
    }

    init(
        uniformTemplate: BrushUniformTemplate,
        textures: [String: any MTLTexture]
    ) throws {
        let coverage = uniformTemplate.coverage
        let material = uniformTemplate.material
        let primaryShape = coverage.shapes[0]
        let secondaryShape = coverage.shapes.count > 1
            ? coverage.shapes[1]
            : nil
        let primaryGrain = coverage.grains.first
        let secondaryGrain = coverage.grains.count > 1
            ? coverage.grains[1]
            : nil

        var slots: [DepositionTextureSlot: any MTLTexture] = [:]
        try Self.bind(
            shape: primaryShape.shape,
            to: .primaryShape,
            textures: textures,
            slots: &slots
        )
        if let secondaryShape {
            try Self.bind(
                shape: secondaryShape.shape,
                to: .secondaryShape,
                textures: textures,
                slots: &slots
            )
        }
        if let primaryGrain {
            try Self.bind(
                grain: primaryGrain.grain,
                to: .primaryGrain,
                textures: textures,
                slots: &slots
            )
        }
        if let secondaryGrain {
            try Self.bind(
                grain: secondaryGrain.grain,
                to: .secondaryGrain,
                textures: textures,
                slots: &slots
            )
        }

        uniforms = PatternDepositionMaterialUniforms(
            coverageParameters: SIMD4(
                primaryGrain?.strength ?? 0,
                secondaryGrain?.strength ?? 0,
                coverage.tipThreshold,
                material.accumulationLimit
            ),
            secondaryShapeTransform: SIMD4(
                secondaryShape?.scale ?? 1,
                secondaryShape?.rotation ?? 0,
                secondaryShape?.offset.x ?? 0,
                secondaryShape?.offset.y ?? 0
            ),
            edgeParameters: SIMD4(material.strength, 0, 0, 0),
            options: SIMD4(
                Self.combinationWire(
                    secondaryShape?.combination ?? .replace
                ),
                coverage.antialiasing ? 1 : 0,
                Self.shapeKind(primaryShape.shape),
                Self.shapeKind(secondaryShape?.shape ?? .hardRound)
            )
        )
        self.textures = DepositionTextureBindings(slots)
    }

    private static func bind(
        shape: BrushShapeDescriptor,
        to slot: DepositionTextureSlot,
        textures: [String: any MTLTexture],
        slots: inout [DepositionTextureSlot: any MTLTexture]
    ) throws {
        guard let resourceID = shapeResourceID(shape) else { return }
        guard let texture = textures[resourceID] else {
            throw DepositionPreparationError.missingRequiredResource(
                resourceID
            )
        }
        slots[slot] = texture
    }

    private static func bind(
        grain: BrushGrainDescriptor,
        to slot: DepositionTextureSlot,
        textures: [String: any MTLTexture],
        slots: inout [DepositionTextureSlot: any MTLTexture]
    ) throws {
        let resourceID = grainResourceID(grain)
        guard let texture = textures[resourceID] else {
            throw DepositionPreparationError.missingRequiredResource(
                resourceID
            )
        }
        slots[slot] = texture
    }

    private static func shapeResourceID(
        _ shape: BrushShapeDescriptor
    ) -> String? {
        switch shape {
        case .hardRound:
            nil
        case .softRound:
            BrushTextureIdentity.softRoundShape.rawValue
        case .chisel:
            BrushTextureIdentity.chiselShape.rawValue
        case let .asset(resourceID):
            resourceID
        }
    }

    private static func grainResourceID(
        _ grain: BrushGrainDescriptor
    ) -> String {
        switch grain {
        case .opaque:
            BrushTextureIdentity.opaqueGrain.rawValue
        case .paper:
            BrushTextureIdentity.paperGrain.rawValue
        case .noise:
            BrushTextureIdentity.noiseGrain.rawValue
        case let .asset(resourceID):
            resourceID
        }
    }

    private static func shapeKind(
        _ shape: BrushShapeDescriptor
    ) -> UInt32 {
        switch shape {
        case .hardRound:
            PatternDepositionShapeKindHardRound
        case .softRound, .chisel, .asset:
            PatternDepositionShapeKindTexture
        }
    }

    private static func combinationWire(
        _ combination: BrushShapeCombinationMode
    ) -> UInt32 {
        switch combination {
        case .replace:
            PatternDepositionShapeCombinationReplace
        case .multiply:
            PatternDepositionShapeCombinationMultiply
        case .minimum:
            PatternDepositionShapeCombinationMinimum
        case .maximum:
            PatternDepositionShapeCombinationMaximum
        }
    }
}
