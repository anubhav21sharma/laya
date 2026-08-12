import Foundation

public enum BrushTipSupportError: Error, Equatable, Sendable {
    case nonfiniteBounds
    case unorderedBounds
    case emptyBounds
    case boundsOutOfRange
    case nonfiniteLayerTransform
    case emptyLayers
    case nonfiniteTangent
    case nonunitTangent
    case invalidSupportWidth
    case arithmeticOverflow
    case emptyContour
    case nonfiniteContour
    case contourOutOfRange
    case invalidPadding
    case invalidMipSelection
}

public struct BrushTipNormalizedBounds: Equatable, Sendable {
    public let minX: Float
    public let maxX: Float
    public let minY: Float
    public let maxY: Float

    public init(
        minX: Float,
        maxX: Float,
        minY: Float,
        maxY: Float
    ) throws {
        guard minX.isFinite, maxX.isFinite,
              minY.isFinite, maxY.isFinite
        else {
            throw BrushTipSupportError.nonfiniteBounds
        }
        guard minX <= maxX, minY <= maxY else {
            throw BrushTipSupportError.unorderedBounds
        }
        guard minX < maxX, minY < maxY else {
            throw BrushTipSupportError.emptyBounds
        }
        guard minX >= -1, maxX <= 1, minY >= -1, maxY <= 1 else {
            throw BrushTipSupportError.boundsOutOfRange
        }
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
    }
}

/// Device-independent logical support for one normalized brush-tip shape.
public struct BrushTipSupportDefinition: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case analyticEllipse
        case analyticRectangle
        case normalizedBounds
    }

    public static let analyticEllipse = BrushTipSupportDefinition(
        kind: .analyticEllipse,
        bounds: nil
    )
    public static let analyticRectangle = BrushTipSupportDefinition(
        kind: .analyticRectangle,
        bounds: nil
    )

    public let kind: Kind
    public let bounds: BrushTipNormalizedBounds?

    private init(kind: Kind, bounds: BrushTipNormalizedBounds?) {
        self.kind = kind
        self.bounds = bounds
    }

    public static func normalizedBounds(
        minX: Float,
        maxX: Float,
        minY: Float,
        maxY: Float
    ) throws -> BrushTipSupportDefinition {
        return BrushTipSupportDefinition(
            kind: .normalizedBounds,
            bounds: try BrushTipNormalizedBounds(
                minX: minX,
                maxX: maxX,
                minY: minY,
                maxY: maxY
            )
        )
    }
}

/// Asset-specific expansion around normalized source coordinates. Zero is the
/// default: padding is never inferred globally or added to every tip.
public struct BrushTipPadding: Equatable, Sendable {
    public let left: Float
    public let right: Float
    public let top: Float
    public let bottom: Float

    public static let zero = BrushTipPadding(
        validatedLeft: 0,
        right: 0,
        top: 0,
        bottom: 0
    )

    public init(
        left: Float,
        right: Float,
        top: Float,
        bottom: Float
    ) throws {
        let values = [left, right, top, bottom]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
            throw BrushTipSupportError.invalidPadding
        }
        self.init(
            validatedLeft: left,
            right: right,
            top: top,
            bottom: bottom
        )
    }

    private init(
        validatedLeft left: Float,
        right: Float,
        top: Float,
        bottom: Float
    ) {
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
    }
}

/// Device-independent metadata compiled from the lossless base coverage of a
/// textured tip. The contour is a deterministic conservative envelope used by
/// later cursor code; rendering continues to sample the original mip pyramid.
public struct BrushTipAssetSupport: Equatable, Sendable {
    public let bounds: BrushTipNormalizedBounds
    public let contour: [SIMD2<Float>]
    public let padding: BrushTipPadding

    public init(
        bounds: BrushTipNormalizedBounds,
        contour: [SIMD2<Float>],
        padding: BrushTipPadding
    ) throws {
        guard contour.count >= 3 else {
            throw BrushTipSupportError.emptyContour
        }
        guard contour.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw BrushTipSupportError.nonfiniteContour
        }
        guard contour.allSatisfy({
            (-1...1).contains($0.x) && (-1...1).contains($0.y)
        }) else {
            throw BrushTipSupportError.contourOutOfRange
        }
        self.bounds = bounds
        self.contour = contour
        self.padding = padding
    }
}

/// Mirrors the GPU's derivative-based mip choice for validation and cursor
/// planning. It returns a fractional LOD suitable for trilinear sampling.
public enum BrushTipMipSelector {
    public static func levelOfDetail(
        sourceWidth: Int,
        sourceHeight: Int,
        projectedWidth: Float,
        projectedHeight: Float,
        mipLevelCount: Int
    ) throws -> Float {
        guard sourceWidth > 0, sourceHeight > 0, mipLevelCount > 0,
              projectedWidth.isFinite, projectedHeight.isFinite,
              projectedWidth > 0, projectedHeight > 0
        else {
            throw BrushTipSupportError.invalidMipSelection
        }
        let scale = max(
            Float(sourceWidth) / projectedWidth,
            Float(sourceHeight) / projectedHeight
        )
        guard scale.isFinite, scale > 0 else {
            throw BrushTipSupportError.invalidMipSelection
        }
        return min(
            Float(mipLevelCount - 1),
            max(0, log2(scale))
        )
    }
}

/// One fully evaluated pre-projection affine shape layer.
public struct BrushTipSupportLayer: Equatable, Sendable {
    public let definition: BrushTipSupportDefinition
    public let xAxis: SIMD2<Float>
    public let yAxis: SIMD2<Float>
    public let offset: SIMD2<Float>

    public init(
        definition: BrushTipSupportDefinition,
        xAxis: SIMD2<Float>,
        yAxis: SIMD2<Float>,
        offset: SIMD2<Float>
    ) throws {
        guard Self.isFinite(xAxis),
              Self.isFinite(yAxis),
              Self.isFinite(offset)
        else {
            throw BrushTipSupportError.nonfiniteLayerTransform
        }
        self.definition = definition
        self.xAxis = xAxis
        self.yAxis = yAxis
        self.offset = offset
    }

    private static func isFinite(_ value: SIMD2<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite
    }
}

public struct BrushTipProjectionInterval: Equatable, Sendable {
    public let minimumProjection: Double
    public let maximumProjection: Double
    public let width: Double

    fileprivate init(
        minimumProjection: Double,
        maximumProjection: Double,
        width: Double
    ) {
        self.minimumProjection = minimumProjection
        self.maximumProjection = maximumProjection
        self.width = width
    }
}

public enum BrushTipSupport {
    private static let unitLengthTolerance = 0.000_01

    /// Projects caller-owned evaluated layers without allocating or mutating
    /// caller state.
    public static func projectionInterval(
        layers: [BrushTipSupportLayer],
        tangent: SIMD2<Float>
    ) throws -> BrushTipProjectionInterval {
        guard !layers.isEmpty else {
            throw BrushTipSupportError.emptyLayers
        }
        var accumulator = try ProjectionAccumulator(tangent: tangent)
        for layer in layers {
            try accumulator.include(layer)
        }
        return try accumulator.interval()
    }

    /// Fixed-arity production overload for the schema-v2 one/two-layer hot
    /// path. It avoids constructing a transient Array for every logical dab.
    public static func projectionInterval(
        primary: BrushTipSupportLayer,
        secondary: BrushTipSupportLayer?,
        tangent: SIMD2<Float>
    ) throws -> BrushTipProjectionInterval {
        var accumulator = try ProjectionAccumulator(tangent: tangent)
        try accumulator.include(primary)
        if let secondary {
            try accumulator.include(secondary)
        }
        return try accumulator.interval()
    }

    private struct ProjectionAccumulator {
        let tangentX: Double
        let tangentY: Double
        var unionMinimum = Double.infinity
        var unionMaximum = -Double.infinity

        init(tangent: SIMD2<Float>) throws {
            guard tangent.x.isFinite, tangent.y.isFinite else {
                throw BrushTipSupportError.nonfiniteTangent
            }
            tangentX = Double(tangent.x)
            tangentY = Double(tangent.y)
            let lengthSquared = tangentX * tangentX + tangentY * tangentY
            guard abs(lengthSquared - 1)
                    <= BrushTipSupport.unitLengthTolerance
            else {
                throw BrushTipSupportError.nonunitTangent
            }
        }

        mutating func include(_ layer: BrushTipSupportLayer) throws {
            let centerProjection = BrushTipSupport.dot(
                layer.offset, tangentX, tangentY
            )
            let xProjection = BrushTipSupport.dot(
                layer.xAxis, tangentX, tangentY
            )
            let yProjection = BrushTipSupport.dot(
                layer.yAxis, tangentX, tangentY
            )
            let projected: (minimum: Double, maximum: Double)
            switch layer.definition.kind {
            case .analyticEllipse:
                let radius = sqrt(
                    xProjection * xProjection
                        + yProjection * yProjection
                )
                projected = (
                    centerProjection - radius,
                    centerProjection + radius
                )
            case .analyticRectangle:
                let radius = abs(xProjection) + abs(yProjection)
                projected = (
                    centerProjection - radius,
                    centerProjection + radius
                )
            case .normalizedBounds:
                guard let bounds = layer.definition.bounds else {
                    throw BrushTipSupportError.invalidSupportWidth
                }
                projected = BrushTipSupport.boundsInterval(
                    bounds,
                    centerProjection: centerProjection,
                    xProjection: xProjection,
                    yProjection: yProjection
                )
            }
            guard projected.minimum.isFinite,
                  projected.maximum.isFinite
            else {
                throw BrushTipSupportError.arithmeticOverflow
            }
            unionMinimum = min(unionMinimum, projected.minimum)
            unionMaximum = max(unionMaximum, projected.maximum)
        }

        func interval() throws -> BrushTipProjectionInterval {
            let width = unionMaximum - unionMinimum
            guard width.isFinite, width > 0 else {
                throw BrushTipSupportError.invalidSupportWidth
            }
            return BrushTipProjectionInterval(
                minimumProjection: unionMinimum,
                maximumProjection: unionMaximum,
                width: width
            )
        }
    }

    private static func dot(
        _ value: SIMD2<Float>,
        _ tangentX: Double,
        _ tangentY: Double
    ) -> Double {
        Double(value.x) * tangentX + Double(value.y) * tangentY
    }

    private static func boundsInterval(
        _ bounds: BrushTipNormalizedBounds,
        centerProjection: Double,
        xProjection: Double,
        yProjection: Double
    ) -> (minimum: Double, maximum: Double) {
        let corner00 = centerProjection
            + Double(bounds.minX) * xProjection
            + Double(bounds.minY) * yProjection
        let corner01 = centerProjection
            + Double(bounds.minX) * xProjection
            + Double(bounds.maxY) * yProjection
        let corner10 = centerProjection
            + Double(bounds.maxX) * xProjection
            + Double(bounds.minY) * yProjection
        let corner11 = centerProjection
            + Double(bounds.maxX) * xProjection
            + Double(bounds.maxY) * yProjection
        return (
            min(corner00, corner01, corner10, corner11),
            max(corner00, corner01, corner10, corner11)
        )
    }
}
