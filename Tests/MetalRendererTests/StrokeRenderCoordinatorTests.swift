import Foundation
import PatternEngine
@testable import MetalRenderer
import Testing

@Suite("Append-only authoritative stroke coordinator")
struct StrokeRenderCoordinatorTests {
    @Test(arguments: [1, 10, 1_000, 100_000])
    func everyOrdinalIsReturnedAndSubmittedExactlyOnce(
        eventCount: Int
    ) throws {
        let coordinator = try makeCoordinator(
            capacity: eventCount == 100_000 ? 12_288 : 64
        )
        var submittedOrdinals: [UInt64] = []
        submittedOrdinals.reserveCapacity(eventCount + 2)

        let began = try commitBegin(
            [sample(index: 0, phase: .began)],
            coordinator: coordinator
        )
        try submitAll(
            began,
            coordinator: coordinator,
            ordinals: &submittedOrdinals
        )
        if eventCount > 1 {
            for index in 1..<eventCount {
                let emitted = try commitAppend(
                    [sample(index: index, phase: .moved)],
                    coordinator: coordinator
                )
                #expect(emitted.work.count <= 4)
                try submitAll(
                    emitted,
                    coordinator: coordinator,
                    ordinals: &submittedOrdinals
                )
            }
        }

        #expect(
            submittedOrdinals
                == Array(0..<UInt64(submittedOrdinals.count))
        )
        #expect(Set(submittedOrdinals).count == submittedOrdinals.count)
        #expect(coordinator.snapshot.authoritativeQueueDepth == 0)
        #expect(
            coordinator.snapshot.authoritativeSubmittedDabCount
                == UInt64(submittedOrdinals.count)
        )
        #expect(coordinator.snapshot.maximumReturnedDabCount <= 4)
        #expect(coordinator.snapshot.retainedCompletedDabCount == 0)
        #expect(coordinator.snapshot.authoritativeQueueHighWater <= 4)
    }

    @Test
    func capacityFailureIsTransactionalAndHighWaterIsBounded() throws {
        let coordinator = try makeCoordinator(capacity: 1)
        let first = try commitBegin(
            [sample(index: 0, phase: .began)],
            coordinator: coordinator
        )
        let before = coordinator.snapshot

        #expect(throws: AuthoritativeStrokeQueueError.self) {
            _ = try coordinator.prepareAppend(
                actualSamples: [sample(index: 3, phase: .moved)]
            )
        }

        #expect(coordinator.snapshot == before)
        var ordinals: [UInt64] = []
        try submitAll(
            first,
            coordinator: coordinator,
            ordinals: &ordinals
        )
        #expect(coordinator.snapshot.authoritativeQueueHighWater == 1)
    }

    @Test
    func abandonedPreparedAppendLeavesExactStateAndRetryIsIdentical() throws {
        let coordinator = try makeCoordinator(capacity: 8)
        let began = try coordinator.prepareBegin(
            actualSamples: [sample(index: 0, phase: .began)]
        )
        try coordinator.commit(began)
        var ordinals: [UInt64] = []
        try submitAll(
            began.emission,
            coordinator: coordinator,
            ordinals: &ordinals
        )
        let before = coordinator.snapshot

        let prepared = try coordinator.prepareAppend(
            actualSamples: [sample(index: 3, phase: .moved)]
        )
        try coordinator.abandon(prepared)
        #expect(coordinator.snapshot == before)

        let retry = try coordinator.prepareAppend(
            actualSamples: [sample(index: 3, phase: .moved)]
        )
        #expect(retry.work == prepared.work)
        try coordinator.commit(retry)
        try submitAll(
            retry.emission,
            coordinator: coordinator,
            ordinals: &ordinals
        )
        #expect(coordinator.snapshot.commitMetadata.inputSampleCount == 2)
    }

    @Test
    func abandonedAndEmptyTransactionsAreConsumedExactlyOnce() throws {
        let coordinator = try makeCoordinator(capacity: 8)
        let began = try coordinator.prepareBegin(
            actualSamples: [sample(index: 0, phase: .began)]
        )
        try coordinator.commit(began)
        var ordinals: [UInt64] = []
        try submitAll(
            began.emission,
            coordinator: coordinator,
            ordinals: &ordinals
        )

        let beforeAbandon = coordinator.snapshot
        let abandoned = try coordinator.prepareAppend(
            actualSamples: [sample(index: 3, phase: .moved)]
        )
        #expect(throws: StrokeRenderCoordinatorError.self) {
            _ = try coordinator.prepareAppend(
                actualSamples: [sample(index: 4, phase: .moved)]
            )
        }
        try coordinator.abandon(abandoned)
        #expect(coordinator.snapshot == beforeAbandon)
        #expect(throws: StrokeRenderCoordinatorError.self) {
            try coordinator.commit(abandoned)
        }
        #expect(throws: StrokeRenderCoordinatorError.self) {
            try coordinator.abandon(abandoned)
        }
        #expect(coordinator.snapshot == beforeAbandon)

        let empty = try coordinator.prepareAppend(actualSamples: [])
        try coordinator.commit(empty)
        let afterEmptyCommit = coordinator.snapshot
        #expect(throws: StrokeRenderCoordinatorError.self) {
            try coordinator.commit(empty)
        }
        #expect(afterEmptyCommit == coordinator.snapshot)
    }

    @Test
    func preparedTransactionCannotCrossCoordinatorOrigin() throws {
        let source = try makeCoordinator(capacity: 8)
        let foreign = try makeCoordinator(capacity: 8)
        let prepared = try source.prepareBegin(
            actualSamples: [sample(index: 0, phase: .began)]
        )
        let foreignBefore = foreign.snapshot

        #expect(throws: StrokeRenderCoordinatorError.self) {
            try foreign.commit(prepared)
        }
        #expect(throws: StrokeRenderCoordinatorError.self) {
            try foreign.abandon(prepared)
        }
        #expect(foreign.snapshot == foreignBefore)
        try source.abandon(prepared)
    }

    @Test
    func copiedPreparedCoordinatorCannotConsumeTransactionTwice() throws {
        let coordinator = try makeCoordinator(capacity: 8)
        let prepared = try coordinator.prepareBegin(
            actualSamples: [sample(index: 0, phase: .began)]
        )
        let commitAlias = coordinator
        let abandonAlias = coordinator

        try coordinator.commit(prepared)
        let committed = coordinator.snapshot
        #expect(throws: StrokeRenderCoordinatorError.self) {
            try commitAlias.commit(prepared)
        }
        #expect(throws: StrokeRenderCoordinatorError.self) {
            try abandonAlias.abandon(prepared)
        }
        #expect(commitAlias.snapshot == committed)
        #expect(abandonAlias.snapshot == committed)
    }

    @Test
    func submissionInterleavingInvalidatesPreparedTransactionWithoutCountLoss()
        throws
    {
        let coordinator = try makeCoordinator(capacity: 8)
        let began = try coordinator.prepareBegin(
            actualSamples: [sample(index: 0, phase: .began)]
        )
        try coordinator.commit(began)
        let candidate = try coordinator.prepareAppend(
            actualSamples: [sample(index: 3, phase: .moved)]
        )
        let frame = try #require(
            try coordinator.prepareAuthoritativeFrame(maximumDabs: 8)
        )
        try coordinator.markAuthoritativeFrameSubmitted(frame)
        let afterSubmission = coordinator.snapshot

        #expect(throws: StrokeRenderCoordinatorError.self) {
            try coordinator.commit(candidate)
        }
        #expect(coordinator.snapshot == afterSubmission)
        #expect(afterSubmission.authoritativeSubmittedDabCount == 1)
        #expect(afterSubmission.commitMetadata.submittedDabCount == 1)
        #expect(afterSubmission.authoritativeQueueDepth == 0)
    }

    @Test
    func queueWrapsAfterPartialRetireWithoutDrainingToEmpty() throws {
        var queue = try AuthoritativeStrokeQueue(capacity: 5)
        try queue.append(queueWork(0..<4))
        let first = try #require(try queue.prepare(maximumCount: 2))
        #expect(first.work.map(\.ordinal) == [0, 1])
        try queue.retire(first)

        try queue.append(queueWork(4..<7))
        #expect(queue.count == 5)
        let wrapped = try #require(try queue.prepare(maximumCount: 3))
        #expect(wrapped.work.map(\.ordinal) == [2, 3, 4])
        try queue.retire(wrapped)
        #expect(queue.count == 2)

        try queue.append(queueWork(7..<9))
        let remainder = try #require(try queue.prepare(maximumCount: 5))
        #expect(remainder.work.map(\.ordinal) == [5, 6, 7, 8])
        try queue.retire(remainder)
        #expect(queue.submittedCount == 9)
        #expect(queue.isEmpty)
    }

    @Test
    func replaceableActualInputIsRejectedTransactionally() throws {
        let coordinator = try makeCoordinator(capacity: 8)
        let began = try commitBegin(
            [sample(index: 0, phase: .began)],
            coordinator: coordinator
        )
        var ordinals: [UInt64] = []
        try submitAll(
            began,
            coordinator: coordinator,
            ordinals: &ordinals
        )
        let before = coordinator.snapshot
        let replaceable = StrokeSample(
            position: ScreenPoint(x: 1, y: 256),
            pressure: 0.5,
            timestamp: 1.0 / 240,
            phase: .moved,
            source: .pencil,
            kind: .actual,
            capabilities: [.pressure],
            estimationUpdateIndex: 1,
            estimatedProperties: [.pressure],
            estimatedPropertiesExpectingUpdates: [.pressure]
        )

        #expect(throws: StrokeRenderCoordinatorError.invalidAuthoritativeSample) {
            _ = try coordinator.prepareAppend(actualSamples: [replaceable])
        }
        #expect(coordinator.snapshot == before)
    }

    @Test
    func preparedWorkRetiresOnlyAfterSuccessfulSubmission() throws {
        let coordinator = try makeCoordinator(capacity: 8)
        _ = try commitBegin(
            [sample(index: 0, phase: .began)],
            coordinator: coordinator
        )
        let preparedCandidate = try coordinator
            .prepareAuthoritativeFrame(maximumDabs: 8)
        let prepared = try #require(preparedCandidate)

        #expect(throws: AuthoritativeStrokeQueueError.self) {
            _ = try coordinator.prepareAuthoritativeFrame(maximumDabs: 8)
        }
        coordinator.abandonAuthoritativeFrame(prepared)
        let retryCandidate = try coordinator
            .prepareAuthoritativeFrame(maximumDabs: 8)
        let retry = try #require(retryCandidate)
        #expect(retry.work == prepared.work)
        try coordinator.markAuthoritativeFrameSubmitted(retry)
        let exhausted = try coordinator.prepareAuthoritativeFrame(
            maximumDabs: 8
        )
        #expect(exhausted == nil)
        #expect(coordinator.snapshot.authoritativeQueueDepth == 0)
    }

    @Test
    func batchingPartitionsProduceIdenticalDabsAndCanonicalPixels() throws {
        let samples = (0..<128).map {
            sample(index: $0, phase: $0 == 0 ? .began : .moved)
        }
        let single = try makeCoordinator(capacity: 1_024)
        let partitioned = try makeCoordinator(capacity: 1_024)

        var singleWork = try commitBegin(
            [samples[0]],
            coordinator: single
        ).work
        singleWork += try commitAppend(
            Array(samples.dropFirst()),
            coordinator: single
        ).work

        var partitionedWork = try commitBegin(
            [samples[0]],
            coordinator: partitioned
        ).work
        let widths = [1, 7, 3, 19, 2, 31, 5, 11]
        var cursor = 1
        var widthIndex = 0
        while cursor < samples.count {
            let end = min(samples.count, cursor + widths[widthIndex % widths.count])
            partitionedWork += try commitAppend(
                Array(samples[cursor..<end]),
                coordinator: partitioned
            ).work
            cursor = end
            widthIndex += 1
        }

        #expect(partitionedWork == singleWork)
        #expect(
            canonicalCoverage(for: partitionedWork)
                == canonicalCoverage(for: singleWork)
        )
    }

    @Test
    func completedBodyIsReducedToCompactCommitMetadata() throws {
        let coordinator = try makeCoordinator(capacity: 32)
        var ordinals: [UInt64] = []
        let began = try commitBegin(
            [sample(index: 0, phase: .began)],
            coordinator: coordinator
        )
        try submitAll(began, coordinator: coordinator, ordinals: &ordinals)
        for index in 1..<1_000 {
            let emitted = try commitAppend(
                [sample(index: index, phase: .moved)],
                coordinator: coordinator
            )
            try submitAll(
                emitted,
                coordinator: coordinator,
                ordinals: &ordinals
            )
        }

        let snapshot = coordinator.snapshot
        #expect(snapshot.authoritativeQueueDepth == 0)
        #expect(snapshot.retainedCompletedDabCount == 0)
        #expect(snapshot.commitMetadata.inputSampleCount == 1_000)
        #expect(
            snapshot.commitMetadata.emittedDabCount
                == UInt64(ordinals.count)
        )
        #expect(snapshot.commitMetadata.lastEmittedOrdinal == ordinals.last)
    }
}

private func makeCoordinator(
    capacity: Int
) throws -> StrokeRenderCoordinator {
    let definition = try coordinatorInkDefinition()
    let program = try BrushProgramCompiler.compile(definition)
    return try StrokeRenderCoordinator(
        program: program,
        nominalDiameter: 10,
        color: .black,
        seed: 7,
        viewport: ViewportTransform(
            drawableSize: PatternSize(width: 512, height: 512),
            worldCenter: WorldPoint(x: 256, y: 256)
        ),
        authoritativeCapacity: capacity
    )
}

private func coordinatorInkDefinition() throws -> BrushDefinition {
    let one = BrushMappingDefinition(
        input: .pressure,
        response: .constant(1),
        scale: 1,
        offset: 0,
        lowerClamp: 1,
        upperClamp: 1,
        inverted: false,
        jitter: 0,
        missingInputValue: 1
    )
    let zero = BrushMappingDefinition(
        input: .pressure,
        response: .constant(0),
        scale: 1,
        offset: 0,
        lowerClamp: 0,
        upperClamp: 0,
        inverted: false,
        jitter: 0,
        missingInputValue: 0
    )
    return try BrushDefinition(
        id: BrushRecipeID("test.coordinator-ink"),
        metadata: BrushMetadata(displayName: "Coordinator Ink"),
        capabilities: [],
        resources: [],
        coverage: BrushCoverageDefinition(
            shapes: [
                BrushShapeLayerDefinition(
                    shape: .hardRound,
                    combination: .replace,
                    scale: 1,
                    rotation: 0,
                    offset: .zero
                ),
            ],
            grains: [],
            baseHardness: 1,
            aspectRatio: 1,
            tipThreshold: 0.01,
            antialiasing: true
        ),
        placement: BrushPlacementDefinition(
            baseSpacingFraction: 0.1,
            maximumSpacingFraction: 0.1,
            baseFlow: 1,
            strokeOpacity: 1,
            baseScatterFraction: 0,
            baseRotation: 0,
            baseJitterFraction: 0,
            baseOffset: .zero
        ),
        dynamics: BrushDynamicsDefinition(
            size: one,
            flow: one,
            opacity: one,
            spacing: one,
            rotation: zero,
            scatter: one,
            hardness: one,
            grain: one,
            offsetX: zero,
            offsetY: zero,
            hue: zero,
            saturation: zero,
            brightness: zero,
            secondaryColorMix: zero,
            noPressureNeutral: 1,
            randomization: .none
        ),
        color: BrushColorBehaviorDefinition(
            baseAdjustment: .identity,
            perStampJitter: BrushColorJitter(
                hue: 0,
                saturation: 0,
                brightness: 0,
                secondaryColorMix: 0
            ),
            perStrokeJitter: BrushColorJitter(
                hue: 0,
                saturation: 0,
                brightness: 0,
                secondaryColorMix: 0
            )
        ),
        material: BrushMaterialDefinition(
            accumulation: .flow,
            interaction: .none,
            edgeTreatment: .none,
            strength: 1,
            wetness: 0,
            bleedRadius: 0,
            softenPasses: 0,
            accumulationLimit: 1,
            interactionParameters: nil
        ),
        stabilization: 0,
        taper: .none,
        replayMode: .appendOnly,
        replayLimits: nil,
        seedPolicy: .fixed(7),
        limits: BrushDefinitionLimits(
            minimumDiameter: 1,
            maximumDiameter: 1_024,
            maximumOpacity: 1,
            maximumSpacingFraction: 1,
            maximumResourceDimension: 4_096,
            maximumResidentBytes: 64 * 1_024 * 1_024
        ),
        performanceIntent: .realtime120,
        compatibility: BrushCompatibilityMetadata(
            nativeFeatureVersion: 1,
            sourceSettingKeys: [],
            requiredSemanticKeys: []
        )
    )
}

private func sample(index: Int, phase: StrokePhase) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: Float(index), y: 256),
        pressure: 1,
        timestamp: TimeInterval(index) / 240,
        phase: phase,
        source: .mouse,
        kind: index.isMultiple(of: 3) ? .coalesced : .actual
    )
}

private func queueWork(_ ordinals: Range<Int>) -> [AuthoritativeStrokeWork] {
    ordinals.map { ordinal in
        AuthoritativeStrokeWork(
            dab: LogicalDab(
                position: WorldPoint(x: Float(ordinal), y: 0),
                brushToWorld: .identity,
                radius: 1,
                diameter: 2,
                spacing: 1,
                flow: 1,
                strokeOpacity: 1,
                rotation: 0,
                scatter: .zero,
                hardness: 1,
                grainOffset: .zero,
                grainScale: 1,
                grainRotation: 0,
                color: .black,
                colorAdjustment: .identity,
                materialFamily: .ink,
                materialContribution: 1,
                sourceDistance: Float(ordinal),
                ordinal: UInt64(ordinal),
                isPredicted: false
            )
        )
    }
}

private func submitAll(
    _ emission: StrokeCoordinatorEmission,
    coordinator: StrokeRenderCoordinator,
    ordinals: inout [UInt64]
) throws {
    #expect(emission.work.map(\.ordinal) == emission.work.map(\.dab.ordinal))
    while let frame = try coordinator.prepareAuthoritativeFrame(
        maximumDabs: 16
    ) {
        ordinals.append(contentsOf: frame.work.map(\.ordinal))
        try coordinator.markAuthoritativeFrameSubmitted(frame)
    }
}

private func commitBegin(
    _ samples: [StrokeSample],
    coordinator: StrokeRenderCoordinator
) throws -> StrokeCoordinatorEmission {
    let prepared = try coordinator.prepareBegin(actualSamples: samples)
    try coordinator.commit(prepared)
    return prepared.emission
}

private func commitAppend(
    _ samples: [StrokeSample],
    coordinator: StrokeRenderCoordinator
) throws -> StrokeCoordinatorEmission {
    let prepared = try coordinator.prepareAppend(actualSamples: samples)
    try coordinator.commit(prepared)
    return prepared.emission
}

private func canonicalCoverage(
    for work: [AuthoritativeStrokeWork]
) -> [UInt16] {
    var pixels = [UInt16](repeating: 0, count: 512)
    for item in work {
        let center = Int(item.dab.position.x.rounded())
        let radius = max(1, Int(item.dab.radius.rounded(.up)))
        for x in max(0, center - radius)...min(511, center + radius) {
            pixels[x] &+= 1
        }
    }
    return pixels
}
