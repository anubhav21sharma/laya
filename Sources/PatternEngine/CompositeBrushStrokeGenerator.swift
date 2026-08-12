import Foundation

/// Deterministic fixed-capacity coordinator for one or two brush components.
public struct BrushStrokeGenerator: Equatable, Sendable {
    public let program: BrushProgram
    public let nominalDiameter: Float
    public let color: InkColor
    public let seed: UInt64

    public private(set) var currentSpacing: Float
    public private(set) var emittedDabCount: UInt64

    private var primaryGenerator: BrushComponentStrokeGenerator
    private var secondaryGenerator: BrushComponentStrokeGenerator?

    public init(
        program: BrushProgram,
        nominalDiameter: Float,
        color: InkColor,
        seed: UInt64
    ) {
        self.init(
            program: program,
            nominalDiameter: nominalDiameter,
            color: color,
            seed: seed,
            componentRandomNamespaceMode: .isolated
        )
    }

    package init(
        program: BrushProgram,
        nominalDiameter: Float,
        color: InkColor,
        seed: UInt64,
        componentRandomNamespaceMode: BrushComponentRandomNamespaceMode
    ) {
        let effectiveSeed: UInt64 = switch program.definition.seedPolicy {
        case .perStroke: seed
        case let .fixed(value): value
        }
        let primary = BrushComponentStrokeGenerator(
            program: program,
            component: program.primaryComponent,
            nominalDiameter: nominalDiameter,
            color: color,
            seed: seed,
            randomNamespaceOrdinal: componentRandomNamespaceMode.ordinal(
                for: program.primaryComponent.definition.ordinal
            )
        )
        self.program = program
        self.nominalDiameter = nominalDiameter
        self.color = color
        self.seed = effectiveSeed
        currentSpacing = primary.currentSpacing
        emittedDabCount = 0
        primaryGenerator = primary
        if let secondary = program.secondaryComponent {
            secondaryGenerator = BrushComponentStrokeGenerator(
                program: program,
                component: secondary,
                nominalDiameter: nominalDiameter,
                color: color,
                seed: seed,
                randomNamespaceOrdinal: componentRandomNamespaceMode.ordinal(
                    for: secondary.definition.ordinal
                )
            )
        } else {
            secondaryGenerator = nil
        }
    }

    fileprivate init(
        program: BrushProgram,
        nominalDiameter: Float,
        color: InkColor,
        seed: UInt64,
        emittedDabCount: UInt64,
        primaryGenerator: BrushComponentStrokeGenerator,
        secondaryGenerator: BrushComponentStrokeGenerator?
    ) {
        self.program = program
        self.nominalDiameter = nominalDiameter
        self.color = color
        self.seed = seed
        currentSpacing = primaryGenerator.currentSpacing
        self.emittedDabCount = emittedDabCount
        self.primaryGenerator = primaryGenerator
        self.secondaryGenerator = secondaryGenerator
    }

    public static func == (
        lhs: borrowing BrushStrokeGenerator,
        rhs: borrowing BrushStrokeGenerator
    ) -> Bool {
        lhs.program == rhs.program
            && lhs.nominalDiameter == rhs.nominalDiameter
            && lhs.color == rhs.color
            && lhs.seed == rhs.seed
            && lhs.currentSpacing == rhs.currentSpacing
            && lhs.emittedDabCount == rhs.emittedDabCount
            && lhs.primaryGenerator == rhs.primaryGenerator
            && lhs.secondaryGenerator == rhs.secondaryGenerator
    }

    public mutating func cancel() {
        primaryGenerator.cancel()
        secondaryGenerator?.cancel()
        currentSpacing = primaryGenerator.currentSpacing
        emittedDabCount = 0
    }

    static func preflightLogicalIdentity(
        emittedDabCount: UInt64
    ) throws {
        try BrushComponentStrokeGenerator.preflightLogicalIdentity(
            emittedDabCount: emittedDabCount
        )
    }

    static func canonicalKey(
        _ value: Double,
        scale: Double
    ) throws -> Int64 {
        try BrushComponentStrokeGenerator.canonicalKey(value, scale: scale)
    }
}

extension BrushStrokeGenerator {
    public struct EmissionPage: Equatable, Sendable {
        public let emittedCount: Int
        public let workCount: Int
        public let hasMore: Bool

        public init(
            emittedCount: Int,
            workCount: Int = 0,
            hasMore: Bool
        ) {
            self.emittedCount = emittedCount
            self.workCount = workCount
            self.hasMore = hasMore
        }
    }

    public enum EmissionSinkDecision: Equatable, Sendable {
        case accept
        case pause
    }

    public struct EmissionCursor: Equatable, Sendable {
        private enum Phase: Equatable, Sendable {
            case primary
            case secondary
            case complete
        }

        private let program: BrushProgram
        private let nominalDiameter: Float
        private let color: InkColor
        private let seed: UInt64
        private var emittedDabCount: UInt64
        private let sample: WorldStrokeSample
        private let maximumPathSubdivisionCount: Int
        private var phase: Phase
        private var activeCursor:
            BrushComponentStrokeGenerator.EmissionCursor
        /// Secondary before its phase; completed primary during that phase.
        private var inactiveGenerator: BrushComponentStrokeGenerator?

        fileprivate init(
            generator: BrushStrokeGenerator,
            sample: WorldStrokeSample,
            maximumPathSubdivisionCount: Int
        ) throws {
            program = generator.program
            nominalDiameter = generator.nominalDiameter
            color = generator.color
            seed = generator.seed
            emittedDabCount = generator.emittedDabCount
            self.sample = sample
            self.maximumPathSubdivisionCount = maximumPathSubdivisionCount
            phase = .primary
            activeCursor = try generator.primaryGenerator.emissionCursor(
                for: sample,
                maximumPathSubdivisionCount: maximumPathSubdivisionCount
            )
            inactiveGenerator = generator.secondaryGenerator
        }

        public var isComplete: Bool { phase == .complete }

        public var completedGenerator: BrushStrokeGenerator? {
            guard isComplete,
                  let completedActive = activeCursor.completedGenerator
            else { return nil }
            if let completedPrimary = inactiveGenerator {
                return BrushStrokeGenerator(
                    program: program,
                    nominalDiameter: nominalDiameter,
                    color: color,
                    seed: seed,
                    emittedDabCount: emittedDabCount,
                    primaryGenerator: completedPrimary,
                    secondaryGenerator: completedActive
                )
            }
            return BrushStrokeGenerator(
                program: program,
                nominalDiameter: nominalDiameter,
                color: color,
                seed: seed,
                emittedDabCount: emittedDabCount,
                primaryGenerator: completedActive,
                secondaryGenerator: nil
            )
        }

        @discardableResult
        public mutating func emitNextPage(
            _ emit: (DabAttributes) throws -> Void
        ) throws -> EmissionPage {
            try emitNextPageDeciding { dab in
                try emit(dab)
                return .accept
            }
        }

        @discardableResult
        public mutating func emitNextPageDeciding(
            maximumWorkCount: Int = LogicalDabBatch.maximumDabCount * 4,
            shouldPauseBeforeWork: () -> Bool = { false },
            _ emit: (DabAttributes) throws -> EmissionSinkDecision
        ) throws -> EmissionPage {
            precondition(maximumWorkCount >= 2)
            var emittedCount = 0
            var workCount = 0
            while phase != .complete {
                guard workCount < maximumWorkCount,
                      workCount == 0 || !shouldPauseBeforeWork()
                else {
                    return EmissionPage(
                        emittedCount: emittedCount,
                        workCount: workCount,
                        hasMore: true
                    )
                }
                switch phase {
                case .primary:
                    let allowEmission = emittedCount
                        < LogicalDabBatch.maximumDabCount
                        && workCount + 1 < maximumWorkCount
                    workCount += 1
                    switch try activeCursor.advanceOne(
                        allowEmission: allowEmission
                    ) {
                    case .prepared:
                        guard allowEmission,
                              let candidate = activeCursor.preparedCandidate
                        else {
                            preconditionFailure(
                                "Prepared primary cursor has no candidate"
                            )
                        }
                        var globalOrdinal = emittedDabCount
                        let wasAccepted = try activeCursor.generator
                            .offerCandidate(candidate) { localDab in
                                try BrushStrokeGenerator
                                    .preflightLogicalIdentity(
                                    emittedDabCount: globalOrdinal
                                )
                                let dab = localDab.assigningIdentity(
                                    ordinal: globalOrdinal,
                                    componentOrdinal: 0,
                                    componentDabOrdinal: localDab.ordinal
                                )
                                guard try emit(dab) == .accept else {
                                    return .pause
                                }
                                globalOrdinal &+= 1
                                return .accept
                            }
                        guard wasAccepted else {
                            return EmissionPage(
                                emittedCount: emittedCount,
                                workCount: workCount,
                                hasMore: true
                            )
                        }
                        activeCursor.commitPreparedCandidate()
                        emittedDabCount = globalOrdinal
                        emittedCount += 1
                        workCount += 1
                        continue
                    case .noDab:
                        if !activeCursor.isComplete { continue }
                    case .blocked:
                        return EmissionPage(
                            emittedCount: emittedCount,
                            workCount: workCount,
                            hasMore: true
                        )
                    }
                    guard let completedPrimary = activeCursor
                        .completedGenerator
                    else {
                        preconditionFailure(
                            "Completed primary cursor has no generator"
                        )
                    }
                    guard let secondary = inactiveGenerator else {
                        completeOperation()
                        continue
                    }
                    inactiveGenerator = completedPrimary
                    activeCursor = try secondary.emissionCursor(
                        for: sample,
                        maximumPathSubdivisionCount:
                            maximumPathSubdivisionCount
                    )
                    phase = .secondary
                case .secondary:
                    let allowEmission = emittedCount
                        < LogicalDabBatch.maximumDabCount
                        && workCount + 1 < maximumWorkCount
                    workCount += 1
                    switch try activeCursor.advanceOne(
                        allowEmission: allowEmission
                    ) {
                    case .prepared:
                        guard allowEmission,
                              let candidate = activeCursor.preparedCandidate
                        else {
                            preconditionFailure(
                                "Prepared secondary cursor has no candidate"
                            )
                        }
                        var globalOrdinal = emittedDabCount
                        let wasAccepted = try activeCursor.generator
                            .offerCandidate(candidate) { localDab in
                                try BrushStrokeGenerator
                                    .preflightLogicalIdentity(
                                    emittedDabCount: globalOrdinal
                                )
                                let dab = localDab.assigningIdentity(
                                    ordinal: globalOrdinal,
                                    componentOrdinal: 1,
                                    componentDabOrdinal: localDab.ordinal
                                )
                                guard try emit(dab) == .accept else {
                                    return .pause
                                }
                                globalOrdinal &+= 1
                                return .accept
                            }
                        guard wasAccepted else {
                            return EmissionPage(
                                emittedCount: emittedCount,
                                workCount: workCount,
                                hasMore: true
                            )
                        }
                        activeCursor.commitPreparedCandidate()
                        emittedDabCount = globalOrdinal
                        emittedCount += 1
                        workCount += 1
                        continue
                    case .noDab:
                        if !activeCursor.isComplete { continue }
                    case .blocked:
                        return EmissionPage(
                            emittedCount: emittedCount,
                            workCount: workCount,
                            hasMore: true
                        )
                    }
                    guard activeCursor.completedGenerator != nil else {
                        preconditionFailure(
                            "Completed secondary cursor has no generator"
                        )
                    }
                    completeOperation()
                case .complete:
                    break
                }
            }
            return EmissionPage(
                emittedCount: emittedCount,
                workCount: workCount,
                hasMore: false
            )
        }

        private mutating func completeOperation() {
            if sample.phase == .ended {
                emittedDabCount = 0
            }
            phase = .complete
        }
    }

    public func emissionCursor(
        for sample: WorldStrokeSample,
        maximumPathSubdivisionCount: Int
    ) throws -> EmissionCursor {
        precondition(maximumPathSubdivisionCount > 0)
        precondition(sample.phase != .cancelled)
        return try EmissionCursor(
            generator: self,
            sample: sample,
            maximumPathSubdivisionCount: maximumPathSubdivisionCount
        )
    }
}
