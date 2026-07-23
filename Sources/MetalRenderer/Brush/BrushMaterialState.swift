import CShaderTypes
import PatternEngine
import simd

/// Immutable per-stroke material values shared by live display and commit.
public struct BrushMaterialState: Equatable, Sendable {
    public let family: BrushMaterialFamily
    public let grainCoordinateMode: BrushGrainCoordinateMode
    public let strokeOpacity: Float
    public let strength: Float
    public let wetness: Float
    public let bleedRadius: Float
    public let softenPasses: UInt32
    public let accumulationLimit: Float
    public let grainRotation: Float
    public let shape: BrushShapeDescriptor
    public let grain: BrushGrainDescriptor

    public init(recipe: BrushRecipe) {
        family = recipe.material.family
        grainCoordinateMode = recipe.grainCoordinateMode
        strokeOpacity = recipe.strokeOpacity
        strength = recipe.material.strength
        wetness = recipe.material.wetness
        bleedRadius = recipe.material.bleedRadius
        softenPasses = UInt32(recipe.material.softenPasses)
        accumulationLimit = recipe.material.accumulationLimit
        grainRotation = recipe.grainTransform.rotation
        shape = recipe.shape
        grain = recipe.grain
    }

    public var uniforms: PatternBrushMaterialUniforms {
        PatternBrushMaterialUniforms(
            materialFamily: materialFamilyWireValue,
            grainCoordinateMode: grainCoordinateWireValue,
            strokeOpacity: strokeOpacity,
            materialStrength: strength,
            wetness: wetness,
            bleedRadius: bleedRadius,
            softenPasses: softenPasses,
            accumulationLimit: accumulationLimit,
            shapeKind: shapeWireValue,
            grainKind: grainWireValue,
            grainRotation: grainRotation,
            padding1: 0
        )
    }

    public var materialFamilyWireValue: UInt32 {
        switch family {
        case .ink: PatternMaterialWireInk
        case .dry: PatternMaterialWireDry
        case .glaze: PatternMaterialWireGlaze
        case .boundedWash: PatternMaterialWireBoundedWash
        }
    }

    public var grainCoordinateWireValue: UInt32 {
        switch grainCoordinateMode {
        case .canonical: PatternGrainCoordinateWireCanonical
        case .brushLocal: PatternGrainCoordinateWireBrushLocal
        }
    }

    public var shapeWireValue: UInt32 {
        switch shape {
        case .hardRound: PatternShapeWireHardRound
        case .softRound: PatternShapeWireSoftRound
        case .chisel: PatternShapeWireChisel
        case let .asset(identity):
            identity == BrushTextureIdentity.softRoundShape.rawValue
                ? PatternShapeWireSoftRound
                : identity == BrushTextureIdentity.chiselShape.rawValue
                    ? PatternShapeWireChisel
                    : PatternShapeWireHardRound
        }
    }

    public var grainWireValue: UInt32 {
        switch grain {
        case .opaque: PatternGrainWireOpaque
        case .paper: PatternGrainWirePaper
        case .noise: PatternGrainWireNoise
        case let .asset(identity):
            identity == BrushTextureIdentity.paperGrain.rawValue
                ? PatternGrainWirePaper
                : identity == BrushTextureIdentity.noiseGrain.rawValue
                    ? PatternGrainWireNoise
                    : PatternGrainWireOpaque
        }
    }
}

extension BrushRecipe {
    var footprintCoverageSymmetry: FootprintCoverageSymmetry {
        let shapeIsInvariant: Bool
        switch shape {
        case .hardRound, .softRound:
            shapeIsInvariant = true
        case .chisel:
            shapeIsInvariant = false
        case let .asset(identity):
            shapeIsInvariant =
                identity != BrushTextureIdentity.chiselShape.rawValue
        }
        guard shapeIsInvariant else {
            return .oriented
        }

        guard grainCoordinateMode == .brushLocal else {
            return .halfTurnInvariant
        }
        switch grain {
        case .opaque:
            return .halfTurnInvariant
        case .paper, .noise:
            return .oriented
        case let .asset(identity):
            return identity == BrushTextureIdentity.opaqueGrain.rawValue
                ? .halfTurnInvariant
                : .oriented
        }
    }
}

/// CPU reference used by projection/material tests and harness negative controls.
public enum BrushCoverageOracle {
    public static func shapeCoverage(
        _ shape: BrushShapeDescriptor,
        brushLocal: SIMD2<Float>,
        hardness: Float,
        radius: Float,
        resolvedTextureIdentity: BrushTextureIdentity? = nil
    ) -> Float {
        precondition(
            brushLocal.x.isFinite && brushLocal.y.isFinite,
            "Brush-local oracle coordinates must be finite"
        )
        precondition(
            radius.isFinite && radius > 0,
            "Oracle radius must be finite and positive"
        )
        let clampedHardness = clamp01(hardness)
        switch shapeKind(for: shape) {
        case .hardRound:
            let distance = simd_length(brushLocal)
            if clampedHardness >= 0.9999 {
                return clamp01(radius + 0.5 - distance * radius)
            }
            let softness = max(
                1 / radius,
                (1 - clampedHardness) * 0.5
            )
            return 1 - smoothstep(
                edge0: 1 - softness,
                edge1: 1 + 0.5 / radius,
                value: distance
            )

        case let .texture(defaultIdentity):
            let identity = resolvedTextureIdentity.flatMap {
                $0.kind == .shape ? $0 : nil
            } ?? defaultIdentity
            let raw = sampleShapeTexture(
                identity: identity,
                coordinate: brushLocal * 0.5 + 0.5
            )
            return clamp01(
                (raw - (1 - clampedHardness))
                    / max(clampedHardness, 1 / 255)
            )
        }
    }

    public static func grainCoverage(
        _ grain: BrushGrainDescriptor,
        coordinate: SIMD2<Float>,
        resolvedTextureIdentity: BrushTextureIdentity? = nil
    ) -> Float {
        precondition(
            coordinate.x.isFinite && coordinate.y.isFinite,
            "Grain oracle coordinates must be finite"
        )
        let defaultIdentity = grainIdentity(for: grain)
        let identity = resolvedTextureIdentity.flatMap {
            $0.kind == .grain ? $0 : nil
        } ?? defaultIdentity
        guard identity != .opaqueGrain else { return 1 }
        return sampleRepeatingTexture(identity: identity, coordinate: coordinate)
    }

    public static func coverage(
        recipe: BrushRecipe,
        brushLocal: SIMD2<Float>,
        canonical: SIMD2<Float>,
        hardness: Float,
        radius: Float,
        grainScale: Float,
        grainOffset: SIMD2<Float>,
        resolvedShapeIdentity: BrushTextureIdentity? = nil,
        resolvedGrainIdentity: BrushTextureIdentity? = nil
    ) -> Float {
        var shape = shapeCoverage(
            recipe.shape,
            brushLocal: brushLocal,
            hardness: hardness,
            radius: radius,
            resolvedTextureIdentity: resolvedShapeIdentity
        )
        let baseGrainCoordinate: SIMD2<Float>
        switch recipe.grainCoordinateMode {
        case .canonical:
            baseGrainCoordinate = canonical
                / Float(BrushTextureFactory.textureSize)
        case .brushLocal:
            baseGrainCoordinate = brushLocal * 0.5 + 0.5
        }
        let cosine = cos(recipe.grainTransform.rotation)
        let sine = sin(recipe.grainTransform.rotation)
        let grainCoordinate = SIMD2<Float>(
            cosine * baseGrainCoordinate.x - sine * baseGrainCoordinate.y,
            sine * baseGrainCoordinate.x + cosine * baseGrainCoordinate.y
        ) * grainScale + grainOffset
        var grain = grainCoverage(
            recipe.grain,
            coordinate: grainCoordinate,
            resolvedTextureIdentity: resolvedGrainIdentity
        )
        if recipe.material.family == .boundedWash {
            shape = pow(clamp01(shape), 0.72)
            grain = mix(
                from: grain,
                to: 1,
                fraction: clamp01(recipe.material.wetness) * 0.45
            )
        }
        return shape * grain
    }

    private enum ShapeKind {
        case hardRound
        case texture(BrushTextureIdentity)
    }

    private static func shapeKind(
        for descriptor: BrushShapeDescriptor
    ) -> ShapeKind {
        switch descriptor {
        case .hardRound:
            .hardRound
        case .softRound:
            .texture(.softRoundShape)
        case .chisel:
            .texture(.chiselShape)
        case let .asset(rawIdentity):
            switch BrushTextureIdentity(rawValue: rawIdentity) {
            case .softRoundShape:
                .texture(.softRoundShape)
            case .chiselShape:
                .texture(.chiselShape)
            default:
                .hardRound
            }
        }
    }

    private static func grainIdentity(
        for descriptor: BrushGrainDescriptor
    ) -> BrushTextureIdentity {
        switch descriptor {
        case .opaque:
            .opaqueGrain
        case .paper:
            .paperGrain
        case .noise:
            .noiseGrain
        case let .asset(rawIdentity):
            switch BrushTextureIdentity(rawValue: rawIdentity) {
            case .paperGrain:
                .paperGrain
            case .noiseGrain:
                .noiseGrain
            default:
                .opaqueGrain
            }
        }
    }

    private static func sampleShapeTexture(
        identity: BrushTextureIdentity,
        coordinate: SIMD2<Float>
    ) -> Float {
        let size = BrushTextureFactory.textureSize
        let limit = 0.5 / Float(size)
        guard coordinate.x > -limit,
              coordinate.x < 1 + limit,
              coordinate.y > -limit,
              coordinate.y < 1 + limit
        else { return 0 }

        return bilinearSample(
            identity: identity,
            coordinate: coordinate,
            address: { index in
                (0..<size).contains(index) ? index : nil
            }
        )
    }

    private static func sampleRepeatingTexture(
        identity: BrushTextureIdentity,
        coordinate: SIMD2<Float>
    ) -> Float {
        let wrapped = SIMD2<Float>(
            coordinate.x - floor(coordinate.x),
            coordinate.y - floor(coordinate.y)
        )
        let size = BrushTextureFactory.textureSize
        return bilinearSample(
            identity: identity,
            coordinate: wrapped,
            address: { index in
                let remainder = index % size
                return remainder >= 0 ? remainder : remainder + size
            }
        )
    }

    private static func bilinearSample(
        identity: BrushTextureIdentity,
        coordinate: SIMD2<Float>,
        address: (Int) -> Int?
    ) -> Float {
        let size = BrushTextureFactory.textureSize
        let position = coordinate * Float(size) - 0.5
        let x0 = Int(floor(position.x))
        let y0 = Int(floor(position.y))
        let fraction = SIMD2<Float>(
            position.x - Float(x0),
            position.y - Float(y0)
        )

        func texel(_ x: Int, _ y: Int) -> Float {
            guard let addressedX = address(x), let addressedY = address(y) else {
                return 0
            }
            return Float(BrushTextureFactory.referenceTexel(
                identity: identity,
                x: addressedX,
                y: addressedY
            )) / 255
        }

        let top = mix(
            from: texel(x0, y0),
            to: texel(x0 + 1, y0),
            fraction: fraction.x
        )
        let bottom = mix(
            from: texel(x0, y0 + 1),
            to: texel(x0 + 1, y0 + 1),
            fraction: fraction.x
        )
        return mix(from: top, to: bottom, fraction: fraction.y)
    }

    private static func smoothstep(
        edge0: Float,
        edge1: Float,
        value: Float
    ) -> Float {
        let fraction = clamp01((value - edge0) / (edge1 - edge0))
        return fraction * fraction * (3 - 2 * fraction)
    }

    private static func mix(
        from start: Float,
        to end: Float,
        fraction: Float
    ) -> Float {
        start + (end - start) * fraction
    }

    private static func clamp01(_ value: Float) -> Float {
        min(1, max(0, value))
    }
}

public enum BrushLayerCompositor {
    public static func sourceOver(
        _ source: SIMD4<Float>,
        _ destination: SIMD4<Float>
    ) -> SIMD4<Float> {
        source + destination * (1 - source.w)
    }

    public static func composite(
        livePremultiplied: SIMD4<Float>,
        canonicalPremultiplied: SIMD4<Float>,
        strokeOpacity: Float,
        compositeMode: StrokeCompositeMode,
        accumulationLimit: Float = 1,
        eraserStrength: Float = 1
    ) -> SIMD4<Float> {
        let opacity = min(1, max(0, strokeOpacity))
        let limitedLive = limitingPremultipliedAlpha(
            livePremultiplied,
            to: accumulationLimit
        )
        switch compositeMode {
        case .draw:
            let scaledLive = limitedLive * opacity
            return sourceOver(scaledLive, canonicalPremultiplied)
        case .erase:
            let strength = min(1, max(0, eraserStrength))
            return canonicalPremultiplied * (1 - limitedLive.w * strength)
        }
    }

    public static func limitingPremultipliedAlpha(
        _ value: SIMD4<Float>,
        to limit: Float
    ) -> SIMD4<Float> {
        let alpha = min(1, max(0, value.w))
        let limitedAlpha = min(alpha, min(1, max(0, limit)))
        guard alpha > 0 else { return .zero }
        return SIMD4(
            max(value.x, 0),
            max(value.y, 0),
            max(value.z, 0),
            alpha
        ) * (limitedAlpha / alpha)
    }
}
