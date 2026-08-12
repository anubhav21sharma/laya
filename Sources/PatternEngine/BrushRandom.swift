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

public enum BrushComponentRandomNamespace {
    public static func seed(
        strokeSeed: UInt64,
        componentOrdinal: UInt8
    ) -> UInt64 {
        precondition(strokeSeed != 0, "Brush stroke seed must be nonzero")
        guard componentOrdinal != 0 else { return strokeSeed }
        var word = strokeSeed
            ^ (UInt64(componentOrdinal) &* 0xd1b5_4a32_d192_ed03)
            ^ 0x6a09_e667_f3bc_c909
        word = (word ^ (word >> 30)) &* 0xbf58_476d_1ce4_e5b9
        word = (word ^ (word >> 27)) &* 0x94d0_49bb_1331_11eb
        let mixed = word ^ (word >> 31)
        return mixed == 0 ? 0x9e37_79b9_7f4a_7c15 : mixed
    }
}

/// Package-scoped fault-injection policy used by production-path evidence.
/// Product callers always use isolated component ordinals; the shared-primary
/// case lets the harness prove that an actual generator regression is caught.
package enum BrushComponentRandomNamespaceMode: Equatable, Sendable {
    case isolated
    case sharedPrimary

    func ordinal(for authoredOrdinal: UInt8) -> UInt8 {
        switch self {
        case .isolated: authoredOrdinal
        case .sharedPrimary: 0
        }
    }
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

    /// Deterministic extension randomness that does not mutate the seven-word
    /// compatibility cursor. Each output channel has an independent counter
    /// namespace.
    public static func extensionUnitFloat(
        strokeSeed: UInt64,
        logicalDabOrdinal: UInt64,
        outputChannel: BrushProgramRandomChannel
    ) -> Float {
        var word = strokeSeed
            &+ logicalDabOrdinal &* 0xd2b7_4407_b1ce_6e93
            &+ outputChannel.rawValue &* 0xca5a_8263_9512_1157
        word = (word ^ (word >> 30)) &* 0xbf58_476d_1ce4_e5b9
        word = (word ^ (word >> 27)) &* 0x94d0_49bb_1331_11eb
        return unitFloat(from: word ^ (word >> 31))
    }

    /// Schema-v2 counter randomness. Each output owns four permanently
    /// reserved term slots, so adding or reordering another output cannot
    /// perturb this term or any later logical dab.
    static func sensorTermUnitFloat(
        strokeSeed: UInt64,
        logicalDabOrdinal: UInt64,
        output: BrushDynamicOutput,
        termIndex: UInt64
    ) -> Float {
        precondition(termIndex < 4)
        let counter = output.stageCRandomID &* 4 &+ termIndex
        var word = strokeSeed
            &+ logicalDabOrdinal &* 0xd2b7_4407_b1ce_6e93
            &+ counter &* 0xca5a_8263_9512_1157
        word = (word ^ (word >> 30)) &* 0xbf58_476d_1ce4_e5b9
        word = (word ^ (word >> 27)) &* 0x94d0_49bb_1331_11eb
        return unitFloat(from: word ^ (word >> 31))
    }
}
