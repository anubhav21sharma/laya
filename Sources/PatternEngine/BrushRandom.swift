public struct BrushRandomValues: Equatable, Sendable {
    public let spacing: Float
    public let scatterX: Float
    public let scatterY: Float
    public let rotation: Float
    public let grainX: Float
    public let grainY: Float
    public let materialVariation: Float

    public init(
        spacing: Float,
        scatterX: Float,
        scatterY: Float,
        rotation: Float,
        grainX: Float,
        grainY: Float,
        materialVariation: Float
    ) {
        let values = [
            spacing,
            scatterX,
            scatterY,
            rotation,
            grainX,
            grainY,
            materialVariation,
        ]
        precondition(
            values.allSatisfy { $0.isFinite && $0 >= 0 && $0 < 1 },
            "Brush random values must be finite values in [0, 1)"
        )
        self.spacing = spacing
        self.scatterX = scatterX
        self.scatterY = scatterY
        self.rotation = rotation
        self.grainX = grainX
        self.grainY = grainY
        self.materialVariation = materialVariation
    }

    public static let centered = BrushRandomValues(
        spacing: 0.5,
        scatterX: 0.5,
        scatterY: 0.5,
        rotation: 0.5,
        grainX: 0.5,
        grainY: 0.5,
        materialVariation: 0.5
    )
}

/// Specified SplitMix64 cursor for one authoritative stroke.
///
/// Every dab consumes exactly seven words in the declaration order used by
/// `BrushRandomValues`, whether or not its recipe enables those channels.
public struct BrushRandom: Equatable, Sendable {
    private static let increment: UInt64 = 0x9e37_79b9_7f4a_7c15
    private var state: UInt64

    public init(seed: UInt64) {
        precondition(seed != 0, "Brush stroke seed must be nonzero")
        state = seed
    }

    public mutating func nextWord() -> UInt64 {
        state &+= Self.increment
        var word = state
        word = (word ^ (word >> 30)) &* 0xbf58_476d_1ce4_e5b9
        word = (word ^ (word >> 27)) &* 0x94d0_49bb_1331_11eb
        return word ^ (word >> 31)
    }

    /// Converts the upper 24 bits exactly into a `Float` in `[0, 1)`.
    public static func unitFloat(from word: UInt64) -> Float {
        let upper24 = UInt32(truncatingIfNeeded: word >> 40)
        return Float(upper24) * (1 / Float(1 << 24))
    }

    public mutating func nextValues() -> BrushRandomValues {
        BrushRandomValues(
            spacing: Self.unitFloat(from: nextWord()),
            scatterX: Self.unitFloat(from: nextWord()),
            scatterY: Self.unitFloat(from: nextWord()),
            rotation: Self.unitFloat(from: nextWord()),
            grainX: Self.unitFloat(from: nextWord()),
            grainY: Self.unitFloat(from: nextWord()),
            materialVariation: Self.unitFloat(from: nextWord())
        )
    }

    /// Evaluates one predicted dab from a copy, preserving this cursor.
    public func predictedValues() -> BrushRandomValues {
        var copy = self
        return copy.nextValues()
    }
}
