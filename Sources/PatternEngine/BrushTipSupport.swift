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
}

public struct BrushTipNormalizedBounds: Equatable, Sendable {
    public let minX: Float
    public let maxX: Float
    public let minY: Float
    public let maxY: Float

    fileprivate init(
        minX: Float,
        maxX: Float,
        minY: Float,
        maxY: Float
    ) {
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
        return BrushTipSupportDefinition(
            kind: .normalizedBounds,
            bounds: BrushTipNormalizedBounds(
                minX: minX,
                maxX: maxX,
                minY: minY,
                maxY: maxY
            )
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
