import Foundation
import PatternEngine
import Testing

@Suite("BrushCornerEmitter")
struct BrushCornerEmitterTests {
    @Test
    func equalityAtMaximumAngularStepDoesNotEmit() throws {
        let step = degreesForCorner(30)
        let emitter = try BrushCornerEmitter(maximumAngularStep: step)
        var output = StrokeEmissionCandidateBuffer()
        var nextSequence: UInt64 = 11

        try emitter.emit(
            from: 0,
            signedTurn: step,
            vertex: cornerVertex(
                x: 4,
                y: 5,
                timeKey: 90,
                distanceKey: 120
            ),
            into: &output,
            nextCornerSequence: &nextSequence
        )

        #expect(output.isEmpty)
        #expect(nextSequence == 11)
    }

    @Test
    func turnJustAboveMaximumStepEmitsOneInteriorCandidate() throws {
        let step = Float.pi / 4
        let signedTurn = step.nextUp
        let emitter = try BrushCornerEmitter(maximumAngularStep: step)
        var output = StrokeEmissionCandidateBuffer()
        var nextSequence: UInt64 = 7

        try emitter.emit(
            from: 0,
            signedTurn: signedTurn,
            vertex: cornerVertex(x: 2, y: 3),
            into: &output,
            nextCornerSequence: &nextSequence
        )

        #expect(output.count == 1)
        expectCornerAngle(output[0].direction, equals: signedTurn / 2)
        #expect(output[0].cornerSequence == 7)
        #expect(nextSequence == 8)
    }

    @Test
    func turnJustAboveThirtyThreeGapsFailsCapacityAtomically() throws {
        let step = Float.pi / 36
        let signedTurn = (step * 33).nextUp
        let emitter = try BrushCornerEmitter(maximumAngularStep: step)
        var output = StrokeEmissionCandidateBuffer()
        var nextSequence: UInt64 = 17
        let outputBefore = output

        #expect(throws: BrushCornerEmitterError.capacityExceeded(
            requiredCandidateCount: 33,
            maximumCandidateCount: 32
        )) {
            try emitter.emit(
                from: 0,
                signedTurn: signedTurn,
                vertex: cornerVertex(x: 4, y: 5),
                into: &output,
                nextCornerSequence: &nextSequence
            )
        }

        #expect(output == outputBefore)
        #expect(nextSequence == 17)
    }

    @Test
    func fanExcludesEndpointsAndUsesMinimumEvenlySpacedOrientations() throws {
        let emitter = try BrushCornerEmitter(
            maximumAngularStep: degreesForCorner(30)
        )
        var output = StrokeEmissionCandidateBuffer()
        var nextSequence: UInt64 = 40
        let vertex = cornerVertex(
            x: 4,
            y: 5,
            pressure: 0.73,
            relativeStrokeTime: 1.25,
            sourceDistance: 7_000.000_001,
            provenance: .prediction,
            timeKey: -9,
            distanceKey: 7_000_000_001
        )

        try emitter.emit(
            from: 0,
            signedTurn: degreesForCorner(100),
            vertex: vertex,
            into: &output,
            nextCornerSequence: &nextSequence
        )

        #expect(output.count == 3)
        expectCornerAngle(output[0].direction, equals: degreesForCorner(25))
        expectCornerAngle(output[1].direction, equals: degreesForCorner(50))
        expectCornerAngle(output[2].direction, equals: degreesForCorner(75))
        #expect(output[0].direction != 0)
        #expect(output[2].direction != degreesForCorner(100))
        #expect(output[0].position == cornerPoint(4, 5))
        #expect(output[1].position == cornerPoint(4, 5))
        #expect(output[2].position == cornerPoint(4, 5))
        for index in 0..<output.count {
            #expect(output[index].sample == vertex.sample)
        }
        #expect(output[0].provenance == .prediction)
        #expect(output[1].relativeStrokeTime == 1.25)
        #expect(output[2].sourceDistance == 7_000.000_001)
        #expect(output[1].timeKey == -9)
        #expect(output[2].distanceKey == 7_000_000_001)
        #expect(output[0].kind == .corner)
        #expect(output[0].cornerSequence == 40)
        #expect(output[1].cornerSequence == 41)
        #expect(output[2].cornerSequence == 42)
        #expect(nextSequence == 43)
    }

    @Test
    func negativeTurnProducesMonotonicallyDecreasingOrientations() throws {
        let emitter = try BrushCornerEmitter(
            maximumAngularStep: degreesForCorner(30)
        )
        var output = StrokeEmissionCandidateBuffer()
        var nextSequence: UInt64 = 0

        try emitter.emit(
            from: degreesForCorner(10),
            signedTurn: degreesForCorner(-100),
            vertex: cornerVertex(x: 0, y: 0),
            into: &output,
            nextCornerSequence: &nextSequence
        )

        #expect(output.count == 3)
        expectCornerAngle(output[0].direction, equals: degreesForCorner(-15))
        expectCornerAngle(output[1].direction, equals: degreesForCorner(-40))
        expectCornerAngle(output[2].direction, equals: degreesForCorner(-65))
    }

    @Test
    func exactReversalUsesTrackerSignAndExcludesBothEndpoints() throws {
        let emitter = try BrushCornerEmitter(
            maximumAngularStep: .pi / 2
        )
        var positiveOutput = StrokeEmissionCandidateBuffer()
        var positiveSequence: UInt64 = 0
        try emitter.emit(
            from: 0,
            signedTurn: .pi,
            vertex: cornerVertex(x: 1, y: 2, timeKey: 3, distanceKey: 4),
            into: &positiveOutput,
            nextCornerSequence: &positiveSequence
        )

        var negativeOutput = StrokeEmissionCandidateBuffer()
        var negativeSequence: UInt64 = 0
        try emitter.emit(
            from: 0,
            signedTurn: -.pi,
            vertex: cornerVertex(x: 1, y: 2, timeKey: 3, distanceKey: 4),
            into: &negativeOutput,
            nextCornerSequence: &negativeSequence
        )

        #expect(positiveOutput.count == 1)
        expectCornerAngle(positiveOutput[0].direction, equals: .pi / 2)
        #expect(negativeOutput.count == 1)
        expectCornerAngle(negativeOutput[0].direction, equals: -.pi / 2)
    }

    @Test
    func oneCornerMayEmitExactlyThirtyTwoCandidates() throws {
        let step = Float.pi / 36
        let emitter = try BrushCornerEmitter(maximumAngularStep: step)
        var output = StrokeEmissionCandidateBuffer()
        var nextSequence: UInt64 = 100

        try emitter.emit(
            from: -1,
            signedTurn: step * 33,
            vertex: cornerVertex(x: 2, y: 3, timeKey: 5, distanceKey: 6),
            into: &output,
            nextCornerSequence: &nextSequence
        )

        #expect(output.count == StrokeEmissionCandidateBuffer.maximumCount)
        #expect(output[0].cornerSequence == 100)
        #expect(output[31].cornerSequence == 131)
        #expect(nextSequence == 132)
    }

    @Test
    func oversizedFanFailsWithoutPartiallyMutatingOutputOrSequence() throws {
        let step = Float.pi / 36
        let emitter = try BrushCornerEmitter(maximumAngularStep: step)
        var output = StrokeEmissionCandidateBuffer()
        var nextSequence: UInt64 = 17
        let outputBefore = output

        #expect(throws: BrushCornerEmitterError.capacityExceeded(
            requiredCandidateCount: 33,
            maximumCandidateCount: 32
        )) {
            try emitter.emit(
                from: 0,
                signedTurn: step * 34,
                vertex: cornerVertex(
                    x: 8,
                    y: 9,
                    timeKey: 10,
                    distanceKey: 11
                ),
                into: &output,
                nextCornerSequence: &nextSequence
            )
        }

        #expect(output == outputBefore)
        #expect(nextSequence == 17)
    }

    @Test
    func validatedStepDomainIsOneDegreeThroughPi() throws {
        _ = try BrushCornerEmitter(maximumAngularStep: degreesForCorner(1))
        _ = try BrushCornerEmitter(maximumAngularStep: .pi)

        #expect(throws: BrushCornerEmitterError.invalidMaximumAngularStep) {
            _ = try BrushCornerEmitter(
                maximumAngularStep: degreesForCorner(1).nextDown
            )
        }
        #expect(throws: BrushCornerEmitterError.invalidMaximumAngularStep) {
            _ = try BrushCornerEmitter(maximumAngularStep: .pi.nextUp)
        }
        #expect(throws: BrushCornerEmitterError.invalidMaximumAngularStep) {
            _ = try BrushCornerEmitter(maximumAngularStep: .nan)
        }
    }

    @Test
    func turnOutsideTrackerDomainFailsTypedWithoutMutatingCallerState() throws {
        let emitter = try BrushCornerEmitter(maximumAngularStep: .pi / 2)
        var output = StrokeEmissionCandidateBuffer()
        var nextSequence: UInt64 = 23
        let outputBefore = output

        #expect(throws: BrushCornerEmitterError.invalidSignedTurn) {
            try emitter.emit(
                from: 0,
                signedTurn: .greatestFiniteMagnitude,
                vertex: cornerVertex(x: 1, y: 2),
                into: &output,
                nextCornerSequence: &nextSequence
            )
        }

        #expect(output == outputBefore)
        #expect(nextSequence == 23)
    }

    @Test
    func invalidStartingDirectionFailsTypedWithoutMutatingCallerState() throws {
        let emitter = try BrushCornerEmitter(maximumAngularStep: .pi / 2)
        var output = StrokeEmissionCandidateBuffer()
        var nextSequence: UInt64 = 29
        let outputBefore = output

        #expect(throws: BrushCornerEmitterError.invalidStartingDirection) {
            try emitter.emit(
                from: .infinity,
                signedTurn: .pi,
                vertex: cornerVertex(x: 1, y: 2),
                into: &output,
                nextCornerSequence: &nextSequence
            )
        }

        #expect(output == outputBefore)
        #expect(nextSequence == 29)
    }

    @Test
    func candidateOutputCopiesIndependentlyAndResetClearsLogicalContents() throws {
        let emitter = try BrushCornerEmitter(
            maximumAngularStep: degreesForCorner(30)
        )
        var original = StrokeEmissionCandidateBuffer()
        var sequence: UInt64 = 5
        try emitter.emit(
            from: 0,
            signedTurn: degreesForCorner(90),
            vertex: cornerVertex(x: 1, y: 1, timeKey: 2, distanceKey: 3),
            into: &original,
            nextCornerSequence: &sequence
        )
        var copy = original

        copy.reset()

        #expect(original.count == 3)
        #expect(original[0].cornerSequence == 5)
        #expect(copy.isEmpty)
    }

    @Test
    func repeatedResetAndReuseRemainWithinFixedCandidateCapacity() throws {
        let emitter = try BrushCornerEmitter(maximumAngularStep: .pi / 2)
        var output = StrokeEmissionCandidateBuffer()
        var nextSequence: UInt64 = 0

        for _ in 0..<100_000 {
            try emitter.emit(
                from: 0,
                signedTurn: .pi,
                vertex: cornerVertex(x: 0, y: 0),
                into: &output,
                nextCornerSequence: &nextSequence
            )
            #expect(output.count == 1)
            output.reset()
        }

        #expect(output.isEmpty)
        #expect(nextSequence == 100_000)
    }
}

private func cornerPoint(_ x: Float, _ y: Float) -> WorldPoint {
    WorldPoint(x: x, y: y)
}

private func cornerVertex(
    x: Float,
    y: Float,
    pressure: Float = 0.5,
    relativeStrokeTime: TimeInterval = 0,
    sourceDistance: Double = 0,
    provenance: StrokeEmissionProvenance = .authoritative,
    timeKey: Int64 = 0,
    distanceKey: Int64 = 0
) -> StrokeEmissionCandidate {
    let sample = InterpolatedStrokeSample(
        position: cornerPoint(x, y),
        pressure: pressure,
        timestamp: 10 + relativeStrokeTime,
        altitude: 0.4,
        azimuth: -0.7,
        roll: 0.9,
        velocity: 12,
        phase: .moved,
        source: .pencil,
        kind: provenance == .prediction ? .predicted : .actual,
        capabilities: [
            .pressure,
            .altitude,
            .azimuth,
            .roll,
            .tangentialPressure,
        ],
        tangentialPressure: -0.25,
        deviceIdentifier: 77,
        estimationUpdateIndex: 3,
        estimatedProperties: [.pressure, .roll],
        estimatedPropertiesExpectingUpdates: [.azimuth]
    )
    return StrokeEmissionCandidate(
        sample: sample,
        relativeStrokeTime: relativeStrokeTime,
        sourceDistance: sourceDistance,
        direction: -123,
        provenance: provenance,
        timeKey: timeKey,
        distanceKey: distanceKey,
        kind: .distance,
        cornerSequence: 999
    )
}

private func degreesForCorner(_ value: Float) -> Float {
    value * .pi / 180
}

private func expectCornerAngle(
    _ actual: Float,
    equals expected: Float,
    tolerance: Float = 0.000_01
) {
    #expect(abs(actual - expected) <= tolerance)
}
