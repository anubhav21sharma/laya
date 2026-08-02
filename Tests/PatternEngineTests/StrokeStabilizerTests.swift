import Foundation
import PatternEngine
import Testing

private let stabilizerViewport = ViewportTransform(
    drawableSize: PatternSize(width: 2, height: 2),
    worldCenter: WorldPoint(x: 0, y: 0)
)

private func worldSample(
    x: Float,
    y: Float = 0,
    pressure: Float = 0.5,
    timestamp: TimeInterval,
    phase: StrokePhase,
    source: StrokeSource = .pencil,
    kind: StrokeSampleKind = .actual,
    capabilities: StrokeInputCapabilities = [.pressure],
    altitude: Float? = nil,
    azimuth: Float? = nil,
    roll: Float? = nil,
    tangentialPressure: Float? = nil,
    deviceIdentifier: UInt64? = nil,
    estimationUpdateIndex: Int? = nil,
    estimatedProperties: StrokeEstimatedProperties = [],
    estimatedPropertiesExpectingUpdates: StrokeEstimatedProperties = []
) -> WorldStrokeSample {
    let sample = StrokeSample(
        position: ScreenPoint(x: x + 1, y: y + 1),
        pressure: pressure,
        timestamp: timestamp,
        phase: phase,
        source: source,
        kind: kind,
        capabilities: capabilities,
        altitude: altitude,
        azimuth: azimuth,
        roll: roll,
        tangentialPressure: tangentialPressure,
        deviceIdentifier: deviceIdentifier,
        estimationUpdateIndex: estimationUpdateIndex,
        estimatedProperties: estimatedProperties,
        estimatedPropertiesExpectingUpdates:
            estimatedPropertiesExpectingUpdates
    )
    var deriver = BrushInputDeriver()
    return deriver.derive(sample, viewport: stabilizerViewport)
}

@Suite("StrokeStabilizer")
struct StrokeStabilizerTests {
    @Test
    func v2DistanceModesAcceptOnlyFiniteInclusiveContractBounds() throws {
        _ = try StrokeStabilizer(
            mode: .weightedWindow(distance: Float(1) / 1_024)
        )
        _ = try StrokeStabilizer(mode: .delayed(distance: 4_096))

        let invalidDistances: [Float] = [
            0,
            -1,
            Float(1) / 1_025,
            4_096.001,
            .infinity,
            .nan,
        ]
        for distance in invalidDistances {
            #expect(throws: StrokeStabilizerError.invalidDistance) {
                _ = try StrokeStabilizer(
                    mode: .weightedWindow(distance: distance)
                )
            }
            #expect(throws: StrokeStabilizerError.invalidDistance) {
                _ = try StrokeStabilizer(
                    mode: .delayed(distance: distance)
                )
            }
        }
    }

    @Test
    func noneModeIsTheOnlyV2IdentitySpelling() throws {
        var stabilizer = try StrokeStabilizer(mode: .none)
        let samples = [
            worldSample(x: -3, pressure: 0.2, timestamp: 1, phase: .began),
            worldSample(
                x: 7,
                y: 4,
                pressure: 0.9,
                timestamp: 2,
                phase: .moved,
                kind: .coalesced,
                capabilities: [.pressure, .altitude, .azimuth, .roll],
                altitude: 0.7,
                azimuth: 1.2,
                roll: -0.4
            ),
            worldSample(x: 9, timestamp: 3, phase: .ended),
        ]

        let output = samples.map { stabilizer.processV2($0) }

        #expect(output == samples.map(Optional.some))
        #expect(stabilizer.declaredEndpointLag == nil)
    }

    @Test
    func delayedModeHoldsUntilAuthoredLagAndDoesNotFlushMovingFinish()
        throws
    {
        var stabilizer = try StrokeStabilizer(mode: .delayed(distance: 1))
        #expect(stabilizer.declaredEndpointLag == 1)

        #expect(stabilizer.processV2(
            worldSample(x: 2, timestamp: 0, phase: .began)
        ) == nil)
        #expect(stabilizer.processV2(
            worldSample(x: 2.5, timestamp: 1, phase: .moved)
        ) == nil)
        #expect(stabilizer.processV2(
            worldSample(x: 3, timestamp: 2, phase: .moved)
        )?.position == WorldPoint(x: 2, y: 0))
        #expect(stabilizer.processV2(
            worldSample(x: 4, timestamp: 3, phase: .ended)
        )?.position == WorldPoint(x: 3, y: 0))
    }

    @Test
    func delayedModeProducesOneVisibleExactTapAtFinish() throws {
        var stabilizer = try StrokeStabilizer(mode: .delayed(distance: 1))

        #expect(stabilizer.processV2(
            worldSample(x: 4, timestamp: 0, phase: .began)
        ) == nil)
        let tap = worldSample(x: 4, timestamp: 1, phase: .ended)
        #expect(stabilizer.processV2(tap) == tap)
    }

    @Test
    func weightedModeIntegratesCausalPrefixWithTriangularArcWeight()
        throws
    {
        var stabilizer = try StrokeStabilizer(
            mode: .weightedWindow(distance: 2)
        )
        let began = worldSample(x: 0, timestamp: 0, phase: .began)

        #expect(stabilizer.processV2(began) == began)
        let prefixOutput = stabilizer.processV2(
            worldSample(x: 1, timestamp: 1, phase: .moved)
        )
        let prefix = try #require(prefixOutput)
        #expect(abs(prefix.position.x - Float(8) / 15) < 0.000_01)
        #expect(prefix.position.y == 0)

        let fullWindowOutput = stabilizer.processV2(
            worldSample(x: 2, timestamp: 2, phase: .moved)
        )
        let fullWindow = try #require(fullWindowOutput)
        #expect(abs(fullWindow.position.x - Float(10) / 9) < 0.000_01)
        #expect(fullWindow.position.y == 0)
    }

    @Test
    func weightedModeClipsOldBoundaryAndFinishesWithOneEndpointCorrection()
        throws
    {
        var stabilizer = try StrokeStabilizer(
            mode: .weightedWindow(distance: 2)
        )
        _ = stabilizer.processV2(
            worldSample(x: 0, timestamp: 0, phase: .began)
        )
        _ = stabilizer.processV2(
            worldSample(x: 1, timestamp: 1, phase: .moved)
        )

        let clippedOutput = stabilizer.processV2(
            worldSample(x: 1, y: 2, timestamp: 2, phase: .moved)
        )
        let clipped = try #require(clippedOutput)
        #expect(abs(clipped.position.x - 1) < 0.000_01)
        #expect(abs(clipped.position.y - Float(10) / 9) < 0.000_01)

        let endpoint = WorldPoint(x: 1, y: 2)
        let correctionOutput = stabilizer.processV2(
            worldSample(x: endpoint.x, y: endpoint.y, timestamp: 3, phase: .ended)
        )
        let correction = try #require(correctionOutput)
        #expect(hypot(
            correction.position.x - endpoint.x,
            correction.position.y - endpoint.y
        ) <= 1)
    }

    @Test
    func delayedModeInterpolatesBehindHeadAcrossCurvedAuthoredArc() throws {
        var stabilizer = try StrokeStabilizer(mode: .delayed(distance: 1))
        _ = stabilizer.processV2(
            worldSample(x: 0, timestamp: 0, phase: .began)
        )
        _ = stabilizer.processV2(
            worldSample(x: 1, timestamp: 1, phase: .moved)
        )

        let output = stabilizer.processV2(
            worldSample(x: 1, y: 0.5, timestamp: 2, phase: .moved)
        )

        #expect(output?.position == WorldPoint(x: 0.5, y: 0))
    }

    @Test
    func weightedAndDelayedGeometryIsInvariantToCollinearEventPartitions()
        throws
    {
        let modes: [StrokeStabilizerMode] = [
            .weightedWindow(distance: 64),
            .delayed(distance: 64),
        ]
        for mode in modes {
            var longSegment = try StrokeStabilizer(mode: mode)
            _ = longSegment.processV2(
                worldSample(x: 0, timestamp: 0, phase: .began)
            )
            let longOutput = longSegment.processV2(
                worldSample(x: 130, timestamp: 1, phase: .moved)
            )

            var partitioned = try StrokeStabilizer(mode: mode)
            _ = partitioned.processV2(
                worldSample(x: 0, timestamp: 0, phase: .began)
            )
            let partitions: [Float] = [0.25, 7.75, 41.5, 64, 99.125, 130]
            var partitionedOutput: WorldStrokeSample?
            for (index, x) in partitions.enumerated() {
                partitionedOutput = partitioned.processV2(
                    worldSample(
                        x: x,
                        timestamp: TimeInterval(index + 1),
                        phase: .moved
                    )
                )
            }

            let unpartitionedSample = try #require(longOutput)
            let partitionedSample = try #require(partitionedOutput)
            #expect(abs(
                unpartitionedSample.position.x - partitionedSample.position.x
            ) < 0.000_01)
            #expect(abs(
                unpartitionedSample.position.y - partitionedSample.position.y
            ) < 0.000_01)
        }
    }

    @Test
    func longSegmentRetainsOnlyFixedCapacityArcPointsAndSeparateExactHead()
        throws
    {
        var stabilizer = try StrokeStabilizer(
            mode: .weightedWindow(distance: 64)
        )
        _ = stabilizer.processV2(
            worldSample(x: 0, timestamp: 0, phase: .began)
        )
        _ = stabilizer.processV2(
            worldSample(x: 1_000_000.25, timestamp: 1, phase: .moved)
        )

        #expect(stabilizer.snapshot.retainedPointCount == 65)
        #expect(stabilizer.snapshot.pointCapacity == 65)
        #expect(
            stabilizer.snapshot.exactHeadPosition
                == WorldPoint(x: 1_000_000.25, y: 0)
        )
    }

    @Test
    func v2ModesChangeOnlyPositionAndStationaryHeadsKeepCurrentProvenance()
        throws
    {
        let modes: [StrokeStabilizerMode] = [
            .weightedWindow(distance: 1),
            .delayed(distance: 1),
        ]
        for mode in modes {
            var stabilizer = try StrokeStabilizer(mode: mode)
            _ = stabilizer.processV2(
                worldSample(x: 0, timestamp: 0, phase: .began)
            )
            _ = stabilizer.processV2(
                worldSample(x: 2, timestamp: 1, phase: .moved)
            )
            let retainedCount = stabilizer.snapshot.retainedPointCount
            let currentHead = worldSample(
                x: 2,
                pressure: 0.85,
                timestamp: 2,
                phase: .moved,
                source: .tablet,
                kind: .predicted,
                capabilities: [
                    .pressure, .altitude, .azimuth, .roll,
                    .tangentialPressure,
                ],
                altitude: 0.4,
                azimuth: -0.8,
                roll: 1.1,
                tangentialPressure: -0.6,
                deviceIdentifier: 99,
                estimatedProperties: [.pressure, .roll],
                estimatedPropertiesExpectingUpdates: [.roll]
            )

            let currentOutput = stabilizer.processV2(currentHead)
            let output = try #require(currentOutput)

            #expect(output.pressure == currentHead.pressure)
            #expect(output.timestamp == currentHead.timestamp)
            #expect(output.altitude == currentHead.altitude)
            #expect(output.azimuth == currentHead.azimuth)
            #expect(output.roll == currentHead.roll)
            #expect(
                output.tangentialPressure == currentHead.tangentialPressure
            )
            #expect(output.deviceIdentifier == currentHead.deviceIdentifier)
            #expect(
                output.estimationUpdateIndex
                    == currentHead.estimationUpdateIndex
            )
            #expect(output.estimatedProperties == currentHead.estimatedProperties)
            #expect(
                output.estimatedPropertiesExpectingUpdates
                    == currentHead.estimatedPropertiesExpectingUpdates
            )
            #expect(output.velocity == currentHead.velocity)
            #expect(output.phase == currentHead.phase)
            #expect(output.source == currentHead.source)
            #expect(output.kind == currentHead.kind)
            #expect(output.capabilities == currentHead.capabilities)
            #expect(stabilizer.snapshot.retainedPointCount == retainedCount)
            #expect(stabilizer.snapshot.exactHeadPosition == currentHead.position)
            #expect(stabilizer.snapshot.exactHead == currentHead)
        }
    }

    @Test
    func v2CancelEmitsNothingAndClearsEveryModeState() throws {
        let modes: [StrokeStabilizerMode] = [
            .none,
            .weightedWindow(distance: 1),
            .delayed(distance: 1),
        ]
        for mode in modes {
            var stabilizer = try StrokeStabilizer(mode: mode)
            _ = stabilizer.processV2(
                worldSample(x: 0, timestamp: 0, phase: .began)
            )
            _ = stabilizer.processV2(
                worldSample(x: 2, timestamp: 1, phase: .moved)
            )

            let cancelled = stabilizer.processV2(
                worldSample(x: 3, timestamp: 2, phase: .cancelled)
            )

            #expect(cancelled == nil)
            #expect(stabilizer.snapshot.retainedPointCount == 0)
            #expect(stabilizer.snapshot.exactHeadPosition == nil)
        }
    }

    @Test
    func copiedV2StateEvaluatesPredictionWithoutAdvancingAuthoritativeArc()
        throws
    {
        var authoritative = try StrokeStabilizer(
            mode: .weightedWindow(distance: 2)
        )
        _ = authoritative.processV2(
            worldSample(x: 0, timestamp: 0, phase: .began)
        )
        _ = authoritative.processV2(
            worldSample(x: 1, timestamp: 1, phase: .moved)
        )
        let authoritativeCheckpoint = authoritative

        var prediction = authoritative
        let predicted = prediction.processV2(
            worldSample(
                x: 2,
                timestamp: 2,
                phase: .moved,
                kind: .predicted
            )
        )
        #expect(authoritative == authoritativeCheckpoint)

        let actual = authoritative.processV2(
            worldSample(x: 1.5, timestamp: 2, phase: .moved)
        )

        #expect(abs(
            try #require(predicted).position.x - Float(10) / 9
        ) < 0.000_01)
        #expect(try #require(predicted).kind == .predicted)
        #expect(abs(
            try #require(actual).position.x - Float(9) / 11
        ) < 0.000_01)
        #expect(prediction != authoritative)
    }

    @Test
    func resetFinishTapAndRapidReuseStartFromEmptyV2State() throws {
        var stabilizer = try StrokeStabilizer(
            mode: .weightedWindow(distance: 2)
        )
        _ = stabilizer.processV2(
            worldSample(x: 0, timestamp: 0, phase: .began)
        )
        _ = stabilizer.processV2(
            worldSample(x: 2, timestamp: 1, phase: .moved)
        )

        stabilizer.reset()
        #expect(stabilizer.snapshot.retainedPointCount == 0)
        #expect(stabilizer.snapshot.exactHeadPosition == nil)

        let secondBegin = worldSample(
            x: 10,
            timestamp: 2,
            phase: .began
        )
        #expect(stabilizer.processV2(secondBegin) == secondBegin)
        let secondMove = stabilizer.processV2(
            worldSample(x: 11, timestamp: 3, phase: .moved)
        )
        #expect(abs(
            try #require(secondMove).position.x
                - (10 + Float(8) / 15)
        ) < 0.000_01)

        let secondEnd = worldSample(
            x: 11,
            timestamp: 4,
            phase: .ended
        )
        #expect(stabilizer.processV2(secondEnd) == secondEnd)
        #expect(stabilizer.snapshot.retainedPointCount == 0)

        let tapBegin = worldSample(
            x: -5,
            timestamp: 5,
            phase: .began
        )
        let tapEnd = worldSample(
            x: -5,
            timestamp: 6,
            phase: .ended
        )
        #expect(stabilizer.processV2(tapBegin) == tapBegin)
        #expect(stabilizer.processV2(tapEnd) == tapEnd)
        #expect(stabilizer.snapshot.exactHeadPosition == nil)
    }

    @Test
    func zeroStrengthIsBitForBitIdentity() {
        var stabilizer = StrokeStabilizer(strength: 0)
        let samples = [
            worldSample(x: -3, pressure: 0.2, timestamp: 1, phase: .began),
            worldSample(
                x: 7,
                y: 4,
                pressure: 0.9,
                timestamp: 2,
                phase: .moved,
                kind: .coalesced,
                capabilities: [.pressure, .altitude, .azimuth, .roll],
                altitude: 0.7,
                azimuth: 1.2,
                roll: -0.4
            ),
            worldSample(x: 9, timestamp: 3, phase: .ended),
        ]

        let output = samples.map { stabilizer.process($0) }

        #expect(output == samples)
    }

    @Test
    func deterministicCarryUsesBoundedState() {
        var stabilizer = StrokeStabilizer(strength: 0.5)

        let positions = [
            stabilizer.process(
                worldSample(x: 0, timestamp: 0, phase: .began)
            ).position,
            stabilizer.process(
                worldSample(x: 10, timestamp: 1, phase: .moved)
            ).position,
            stabilizer.process(
                worldSample(x: 10, timestamp: 2, phase: .moved)
            ).position,
        ]

        #expect(positions == [
            WorldPoint(x: 0, y: 0),
            WorldPoint(x: 5, y: 0),
            WorldPoint(x: 7.5, y: 0),
        ])
    }

    @Test
    func changesOnlyPositionAndPreservesAttributeOrder() {
        var stabilizer = StrokeStabilizer(strength: 0.75)
        let first = worldSample(
            x: 0,
            pressure: 0.15,
            timestamp: 10,
            phase: .began,
            source: .tablet,
            kind: .actual,
            capabilities: [.pressure, .azimuth],
            azimuth: -2
        )
        let second = worldSample(
            x: 8,
            pressure: 0.85,
            timestamp: 11,
            phase: .moved,
            source: .pencil,
            kind: .coalesced,
            capabilities: [.pressure, .altitude, .roll],
            altitude: 0.4,
            roll: 1.1
        )

        _ = stabilizer.process(first)
        let output = stabilizer.process(second)

        #expect(output.position == WorldPoint(x: 2, y: 0))
        #expect(output.pressure == second.pressure)
        #expect(output.timestamp == second.timestamp)
        #expect(output.altitude == second.altitude)
        #expect(output.azimuth == second.azimuth)
        #expect(output.roll == second.roll)
        #expect(output.velocity == second.velocity)
        #expect(output.phase == second.phase)
        #expect(output.source == second.source)
        #expect(output.kind == second.kind)
        #expect(output.capabilities == second.capabilities)
    }

    @Test
    func cancelDropsCarry() {
        var stabilizer = StrokeStabilizer(strength: 0.5)
        _ = stabilizer.process(
            worldSample(x: 0, timestamp: 0, phase: .began)
        )
        _ = stabilizer.process(
            worldSample(x: 10, timestamp: 1, phase: .moved)
        )
        let cancelled = worldSample(
            x: 20,
            timestamp: 2,
            phase: .cancelled
        )

        #expect(stabilizer.process(cancelled) == cancelled)
        let restarted = stabilizer.process(
            worldSample(x: 40, timestamp: 3, phase: .moved)
        )
        #expect(restarted.position == WorldPoint(x: 40, y: 0))
    }

    @Test
    func copiedStateCanEvaluatePredictionWithoutAdvancingActualCarry() {
        var actual = StrokeStabilizer(strength: 0.5)
        _ = actual.process(
            worldSample(x: 0, timestamp: 0, phase: .began)
        )
        _ = actual.process(
            worldSample(x: 10, timestamp: 1, phase: .moved)
        )

        var predicted = actual
        let predictedOutput = predicted.process(
            worldSample(
                x: 20,
                timestamp: 2,
                phase: .moved,
                kind: .predicted
            )
        )
        let actualOutput = actual.process(
            worldSample(x: 12, timestamp: 2, phase: .moved)
        )

        #expect(predictedOutput.position == WorldPoint(x: 12.5, y: 0))
        #expect(actualOutput.position == WorldPoint(x: 8.5, y: 0))
    }
}
