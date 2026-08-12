import Foundation

enum BrushMaskPrecision: String, Hashable, Sendable {
    case r8Unorm
    case r16Unorm
}

enum BrushMaskCacheKeyError: Error, Equatable, Sendable {
    case emptySemanticTipHash
    case invalidSize
    case invalidAspect
    case invalidRotation
    case invalidHardness
    case invalidSubpixelPhase
    case quantizationOverflow
}

struct BrushMaskCacheKey: Equatable, Hashable, Sendable {
    let semanticTipHash: String
    let sizeBucket: Int
    let aspectBucket: Int
    let rotationBucket: Int
    let hardnessBucket: Int
    let subpixelPhaseXBucket: Int
    let subpixelPhaseYBucket: Int
    let precision: BrushMaskPrecision

    var stableIdentity: String {
        [
            "brush-mask-v1",
            semanticTipHash,
            String(sizeBucket),
            String(aspectBucket),
            String(rotationBucket),
            String(hardnessBucket),
            String(subpixelPhaseXBucket),
            String(subpixelPhaseYBucket),
            precision.rawValue,
        ].joined(separator: ":")
    }

    init(
        semanticTipHash: String,
        size: Float,
        aspect: Float,
        rotation: Float,
        hardness: Float,
        subpixelPhase: SIMD2<Float>,
        precision: BrushMaskPrecision
    ) throws {
        guard !semanticTipHash.isEmpty else {
            throw BrushMaskCacheKeyError.emptySemanticTipHash
        }
        guard size.isFinite, size > 0 else {
            throw BrushMaskCacheKeyError.invalidSize
        }
        guard aspect.isFinite, aspect > 0 else {
            throw BrushMaskCacheKeyError.invalidAspect
        }
        guard rotation.isFinite else {
            throw BrushMaskCacheKeyError.invalidRotation
        }
        guard hardness.isFinite, (0...1).contains(hardness) else {
            throw BrushMaskCacheKeyError.invalidHardness
        }
        guard subpixelPhase.x.isFinite, subpixelPhase.y.isFinite,
              (0...1).contains(subpixelPhase.x),
              (0...1).contains(subpixelPhase.y)
        else {
            throw BrushMaskCacheKeyError.invalidSubpixelPhase
        }

        self.semanticTipHash = semanticTipHash
        sizeBucket = try Self.quantize(size, scale: 64)
        aspectBucket = try Self.quantize(aspect, scale: 1_024)
        let turn = Float.pi * 2
        var normalizedRotation = rotation.truncatingRemainder(dividingBy: turn)
        if normalizedRotation < 0 {
            normalizedRotation += turn
        }
        rotationBucket = try Self.quantize(
            normalizedRotation / turn,
            scale: 1_024
        ) % 1_024
        hardnessBucket = try Self.quantize(hardness, scale: 1_024)
        subpixelPhaseXBucket = try Self.quantize(
            subpixelPhase.x,
            scale: 16
        ) % 16
        subpixelPhaseYBucket = try Self.quantize(
            subpixelPhase.y,
            scale: 16
        ) % 16
        self.precision = precision
    }

    private static func quantize(
        _ value: Float,
        scale: Float
    ) throws -> Int {
        let scaled = (value * scale).rounded()
        guard scaled.isFinite,
              scaled >= Float(Int.min), scaled <= Float(Int.max)
        else {
            throw BrushMaskCacheKeyError.quantizationOverflow
        }
        return Int(scaled)
    }
}

struct BrushMaskCacheMetrics: Equatable, Sendable {
    var hitCount: UInt64
    var missCount: UInt64
    var evictionCount: UInt64

    static let zero = BrushMaskCacheMetrics(
        hitCount: 0,
        missCount: 0,
        evictionCount: 0
    )
}

/// Bounded reuse for expensive generated masks. Current analytic tips and
/// affine-sampled source pyramids intentionally bypass this cache.
struct BrushMaskCache<Value> {
    private var values: [BrushMaskCacheKey: Value] = [:]
    private var keysByStableIdentity: [String: BrushMaskCacheKey] = [:]
    private var residency: BrushResourceResidency
    private(set) var metrics = BrushMaskCacheMetrics.zero

    init(byteBudget: Int) {
        residency = BrushResourceResidency(byteBudget: byteBudget)
    }

    var keys: [BrushMaskCacheKey] {
        values.keys.sorted { $0.stableIdentity < $1.stableIdentity }
    }

    var residentByteCount: Int {
        residency.residentByteCount
    }

    mutating func resolve(
        _ key: BrushMaskCacheKey,
        byteCount: Int,
        pinned: Bool = false,
        create: () throws -> Value
    ) throws -> Value {
        if let value = values[key] {
            _ = try residency.access(
                key: key.stableIdentity,
                byteCount: byteCount,
                pinned: pinned
            )
            metrics.hitCount += 1
            return value
        }

        let candidate = try create()
        let evicted = try residency.access(
            key: key.stableIdentity,
            byteCount: byteCount,
            pinned: pinned
        )
        for identity in evicted {
            guard let victim = keysByStableIdentity.removeValue(
                forKey: identity
            ) else {
                preconditionFailure("Mask residency victim must exist")
            }
            values.removeValue(forKey: victim)
        }
        values[key] = candidate
        keysByStableIdentity[key.stableIdentity] = key
        metrics.missCount += 1
        metrics.evictionCount += UInt64(evicted.count)
        return candidate
    }

    mutating func pin(_ key: BrushMaskCacheKey) {
        residency.pin(key.stableIdentity)
    }

    mutating func unpin(_ key: BrushMaskCacheKey) {
        residency.unpin(key.stableIdentity)
    }
}
