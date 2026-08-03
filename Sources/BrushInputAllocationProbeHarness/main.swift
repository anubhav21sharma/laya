import BrushFormat
import Darwin
import Foundation
import Metal
import MetalRenderer
import PatternEngine

private struct AllocatorProbe: @unchecked Sendable {
    typealias ArmFunction = @convention(c) () -> Void
    typealias DisarmFunction = @convention(c) () -> UInt64

    let arm: ArmFunction
    let disarm: DisarmFunction

    init() throws {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        guard
            let armSymbol = dlsym(
                defaultHandle,
                "laya_allocation_probe_arm"
            ),
            let disarmSymbol = dlsym(
                defaultHandle,
                "laya_allocation_probe_disarm"
            )
        else {
            throw ProbeHarnessError.probeUnavailable
        }
        arm = unsafeBitCast(armSymbol, to: ArmFunction.self)
        disarm = unsafeBitCast(disarmSymbol, to: DisarmFunction.self)
    }
}

private final class ActorAllocationMeasurements: @unchecked Sendable {
    struct Snapshot {
        let eventCount: Int
        let allocationCount: UInt64
        let maximumSingleEventCount: UInt64
        let firstHalfAllocationCount: UInt64
        let lastHalfAllocationCount: UInt64
    }

    private let lock = NSLock()
    private var authoritativeCPU: [UInt64] = []
    private var predictionCPU: [UInt64] = []
    private var estimatedCPU: [UInt64] = []
    private var batchPackaging: [UInt64] = []
    private var privateSurfaceEncoding: [UInt64] = []

    init() {
        authoritativeCPU.reserveCapacity(256)
        predictionCPU.reserveCapacity(256)
        estimatedCPU.reserveCapacity(256)
        batchPackaging.reserveCapacity(512)
        privateSurfaceEncoding.reserveCapacity(512)
    }

    func record(
        _ stage: StrokePreparationAllocationProbeStage,
        count: UInt64
    ) {
        lock.lock()
        switch stage {
        case .authoritativeCPU:
            authoritativeCPU.append(count)
        case .predictionCPU:
            predictionCPU.append(count)
        case .estimatedCPU:
            estimatedCPU.append(count)
        case .batchPackaging:
            batchPackaging.append(count)
        case .privateSurfaceEncoding:
            privateSurfaceEncoding.append(count)
        }
        lock.unlock()
    }

    func snapshot(
        for stage: StrokePreparationAllocationProbeStage
    ) -> Snapshot {
        lock.lock()
        let counts = switch stage {
        case .authoritativeCPU: authoritativeCPU
        case .predictionCPU: predictionCPU
        case .estimatedCPU: estimatedCPU
        case .batchPackaging: batchPackaging
        case .privateSurfaceEncoding: privateSurfaceEncoding
        }
        let result = Snapshot(
            eventCount: counts.count,
            allocationCount: counts.reduce(0, +),
            maximumSingleEventCount: counts.max() ?? 0,
            firstHalfAllocationCount:
                counts.prefix(counts.count / 2).reduce(0, +),
            lastHalfAllocationCount:
                counts.suffix(counts.count / 2).reduce(0, +)
        )
        lock.unlock()
        return result
    }

    func reset() {
        lock.lock()
        authoritativeCPU.removeAll(keepingCapacity: true)
        predictionCPU.removeAll(keepingCapacity: true)
        estimatedCPU.removeAll(keepingCapacity: true)
        batchPackaging.removeAll(keepingCapacity: true)
        privateSurfaceEncoding.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

private enum ProbeHarnessError: Error, CustomStringConvertible {
    case invalidArguments
    case metalUnavailable
    case probeUnavailable
    case selfTestMissedAllocation
    case velocityFilterAllocations(total: UInt64)
    case inputDerivationAllocations(total: UInt64)
    case directionCornerAllocations(total: UInt64)
    case stabilizerV2Allocations(total: UInt64)
    case stageCGeneratorAllocations(total: UInt64)
    case timedEmitterAllocations(normal: UInt64, hugeGap: UInt64)
    case timedEmitterMissingCursor
    case tipSupportSpacingAllocations(total: UInt64)
    case sensorProgramAllocations(total: UInt64)
    case offMainEstimatedAllocations(total: UInt64, maximum: UInt64)
    case offMainAllocationRegression(String)
    case productionAllocations(
        total: UInt64,
        firstIndex: Int,
        firstWasPredicted: Bool,
        firstCount: UInt64,
        maximumSingleCallCount: UInt64
    )

    var description: String {
        switch self {
        case .invalidArguments:
            "expected a supported probe mode and a repository root"
        case .metalUnavailable:
            "the production allocation route requires a Metal device"
        case .probeUnavailable:
            "allocator probe symbols are unavailable"
        case .selfTestMissedAllocation:
            "allocator probe missed the deliberate Array allocation"
        case let .velocityFilterAllocations(total):
            "velocity filter allocated \(total) times after warm-up"
        case let .inputDerivationAllocations(total):
            "production input derivation allocated \(total) times after warm-up"
        case let .directionCornerAllocations(total):
            "direction/corner path allocated \(total) times after warm-up"
        case let .stabilizerV2Allocations(total):
            "stabilizer v2 path allocated \(total) times after warm-up"
        case let .stageCGeneratorAllocations(total):
            "integrated Stage C generator allocated \(total) times after warm-up"
        case let .timedEmitterAllocations(normal, hugeGap):
            "timed emitter allocated after warm-up; normal=\(normal) "
                + "hugeGap=\(hugeGap)"
        case .timedEmitterMissingCursor:
            "timed emitter did not produce the expected probe cursor"
        case let .tipSupportSpacingAllocations(total):
            "tip support/spacing path allocated \(total) times after warm-up"
        case let .sensorProgramAllocations(total):
            "ordered sensor evaluator allocated \(total) times after warm-up"
        case let .offMainEstimatedAllocations(total, maximum):
            "off-main estimated correction allocated \(total) times; "
                + "maximum single correction=\(maximum)"
        case let .offMainAllocationRegression(detail):
            "off-main allocation regression: \(detail)"
        case let .productionAllocations(
            total,
            firstIndex,
            firstWasPredicted,
            firstCount,
            maximumSingleCallCount
        ):
            "production input/replay route allocated \(total) times; "
                + "first index=\(firstIndex) predicted=\(firstWasPredicted) "
                + "count=\(firstCount) maximum=\(maximumSingleCallCount)"
        }
    }
}

@inline(never)
private func sameSizedArrayChecksum(count: Int) -> UInt64 {
    var values = [UInt64](repeating: 0xA5, count: count)
    values[count - 1] = 0x5A
    return values[0] &+ values[count - 1] &+ UInt64(values.count)
}

@MainActor
private struct RendererSetup {
    let renderer: GridRenderer
    let brush: CompiledBrush
}

@main
private struct BrushInputAllocationProbeHarness {
    @MainActor
    static func main() async {
        do {
            guard CommandLine.arguments.count == 3 else {
                throw ProbeHarnessError.invalidArguments
            }
            let mode = CommandLine.arguments[1]
            let root = URL(
                fileURLWithPath: CommandLine.arguments[2],
                isDirectory: true
            )
            let probe = try AllocatorProbe()
            switch mode {
            case "--self-test":
                try runSelfTest(probe: probe)
            case "--velocity-filter":
                try runVelocityFilterProbe(probe: probe)
            case "--input-derivation":
                try runInputDerivationProbe(probe: probe)
            case "--direction-corner":
                try runDirectionCornerProbe(probe: probe)
            case "--stabilizer-v2":
                try runStabilizerV2Probe(probe: probe)
            case "--stage-c-generator":
                try runStageCGeneratorProbe(probe: probe)
            case "--timed-emitter":
                try runTimedEmitterProbe(probe: probe)
            case "--tip-support-spacing":
                try runTipSupportSpacingProbe(probe: probe)
            case "--sensor-program":
                try runSensorProgramProbe(probe: probe)
            case "--production":
                try await runProduction(probe: probe, root: root)
            default:
                throw ProbeHarnessError.invalidArguments
            }
        } catch {
            FileHandle.standardError.write(
                Data("ALLOCATOR PROBE FAIL: \(error)\n".utf8)
            )
            exit(1)
        }
    }

    private static func runSelfTest(probe: AllocatorProbe) throws {
        let count = Int(
            ProcessInfo.processInfo.environment[
                "LAYA_PROBE_SELF_TEST_ARRAY_COUNT"
            ] ?? ""
        ) ?? 2_048
        _ = sameSizedArrayChecksum(count: count)

        probe.arm()
        let checksum = sameSizedArrayChecksum(count: count)
        let allocations = probe.disarm()

        guard checksum != 0, allocations > 0 else {
            throw ProbeHarnessError.selfTestMissedAllocation
        }
        print(
            "ALLOCATOR PROBE SELF-TEST PASS allocations=\(allocations)"
        )
    }

    private static func runVelocityFilterProbe(
        probe: AllocatorProbe
    ) throws {
        var filter = StrokeVelocityFilter()
        _ = filter.begin(at: WorldPoint(x: 0, y: 0), time: 0)
        _ = runVelocityFilterUpdates(
            filter: &filter,
            startingAt: 1,
            count: 128
        )

        probe.arm()
        let checksum = runVelocityFilterUpdates(
            filter: &filter,
            startingAt: 129,
            count: 1_000_000
        )
        let allocations = probe.disarm()

        guard allocations == 0 else {
            throw ProbeHarnessError.velocityFilterAllocations(
                total: allocations
            )
        }
        print(
            "ALLOCATOR PROBE VELOCITY FILTER PASS allocations=0 "
                + "checksum=\(checksum)"
        )
    }

    private static func runInputDerivationProbe(
        probe: AllocatorProbe
    ) throws {
        let viewport = ViewportTransform(
            drawableSize: PatternSize(width: 2_048, height: 2_048),
            worldCenter: WorldPoint(x: 0, y: 0),
            zoom: 2
        )
        var deriver = BrushInputDeriver()
        _ = deriver.derive(
            StrokeSample(
                position: ScreenPoint(x: 1_024, y: 1_024),
                pressure: 0.5,
                timestamp: 0,
                phase: .began,
                source: .pencil,
                capabilities: [.pressure]
            ),
            viewport: viewport
        )
        _ = runInputDerivationUpdates(
            deriver: &deriver,
            viewport: viewport,
            startingAt: 1,
            count: 128
        )

        probe.arm()
        let checksum = runInputDerivationUpdates(
            deriver: &deriver,
            viewport: viewport,
            startingAt: 129,
            count: 1_000_000
        )
        let allocations = probe.disarm()

        guard allocations == 0 else {
            throw ProbeHarnessError.inputDerivationAllocations(
                total: allocations
            )
        }
        print(
            "ALLOCATOR PROBE INPUT DERIVATION PASS allocations=0 "
                + "derivations=1000000 checksum=\(checksum)"
        )
    }

    private static func runDirectionCornerProbe(
        probe: AllocatorProbe
    ) throws {
        var tracker = BrushDirectionTracker()
        var position = WorldPoint(x: 0, y: 0)
        try tracker.begin(at: position)
        let emitter = try BrushCornerEmitter(maximumAngularStep: .pi / 4)
        var output = StrokeEmissionCandidateBuffer()
        var nextCornerSequence: UInt64 = 0
        _ = try runDirectionCornerUpdates(
            tracker: &tracker,
            emitter: emitter,
            output: &output,
            position: &position,
            nextCornerSequence: &nextCornerSequence,
            startingAt: 0,
            count: 128
        )

        probe.arm()
        let checksum = try runDirectionCornerUpdates(
            tracker: &tracker,
            emitter: emitter,
            output: &output,
            position: &position,
            nextCornerSequence: &nextCornerSequence,
            startingAt: 128,
            count: 1_000_000
        )
        let allocations = probe.disarm()

        guard allocations == 0 else {
            throw ProbeHarnessError.directionCornerAllocations(
                total: allocations
            )
        }
        print(
            "ALLOCATOR PROBE DIRECTION/CORNER PASS allocations=0 "
                + "checksum=\(checksum)"
        )
    }

    private static func runStabilizerV2Probe(
        probe: AllocatorProbe
    ) throws {
        let samples = makeStabilizerProbeSamples()
        var weighted = try StrokeStabilizer(
            mode: .weightedWindow(distance: 4)
        )
        var delayed = try StrokeStabilizer(mode: .delayed(distance: 4))
        _ = try weighted.processV2(samples.began)
        _ = try delayed.processV2(samples.began)
        _ = try runStabilizerV2Updates(
            weighted: &weighted,
            delayed: &delayed,
            samples: samples,
            startingAt: 0,
            count: 128
        )

        probe.arm()
        let checksum: UInt64
        do {
            checksum = try runStabilizerV2Updates(
                weighted: &weighted,
                delayed: &delayed,
                samples: samples,
                startingAt: 128,
                count: 1_000_000
            )
        } catch {
            _ = probe.disarm()
            throw error
        }
        let allocations = probe.disarm()

        guard allocations == 0 else {
            throw ProbeHarnessError.stabilizerV2Allocations(
                total: allocations
            )
        }
        print(
            "ALLOCATOR PROBE STABILIZER V2 PASS allocations=0 "
                + "checksum=\(checksum)"
        )
    }

    private static func runStageCGeneratorProbe(
        probe: AllocatorProbe
    ) throws {
        let weightedProgram = try BrushProgramCompiler.compile(
            makeStageCProbeDefinition(
                id: "probe.stage-c.generator.weighted",
                stabilization: .weightedWindow(distance: 12),
                maximumAngularStep: .pi / 8,
                footprint: .ellipse
            )
        )
        let delayedProgram = try BrushProgramCompiler.compile(
            makeStageCProbeDefinition(
                id: "probe.stage-c.generator.delayed",
                stabilization: .delayed(distance: 12),
                maximumAngularStep: .pi / 8,
                footprint: .chisel
            )
        )
        let texturedProgram = try BrushProgramCompiler.compile(
            makeStageCProbeDefinition(
                id: "probe.stage-c.generator.textured",
                stabilization: .weightedWindow(distance: 12),
                maximumAngularStep: .pi / 8,
                footprint: .translatedBounds
            )
        )
        let dualProgram = try BrushProgramCompiler.compile(
            makeStageCProbeDefinition(
                id: "probe.stage-c.generator.dual",
                stabilization: .delayed(distance: 12),
                maximumAngularStep: .pi / 8,
                footprint: .dualEllipse
            )
        )
        let samples = makeStageCGeneratorProbeSamples()
        var weighted = BrushStrokeGenerator(
            program: weightedProgram,
            nominalDiameter: 20,
            color: .black,
            seed: 0xC9_01
        )
        var delayed = BrushStrokeGenerator(
            program: delayedProgram,
            nominalDiameter: 20,
            color: .black,
            seed: 0xC9_02
        )
        var textured = BrushStrokeGenerator(
            program: texturedProgram,
            nominalDiameter: 20,
            color: .black,
            seed: 0xC9_03
        )
        var dual = BrushStrokeGenerator(
            program: dualProgram,
            nominalDiameter: 20,
            color: .black,
            seed: 0xC9_04
        )
        _ = try runStageCGeneratorCycles(
            weighted: &weighted,
            delayed: &delayed,
            samples: samples,
            count: 128
        )
        _ = try runStageCGeneratorCycles(
            weighted: &textured,
            delayed: &dual,
            samples: samples,
            count: 128
        )

        probe.arm()
        let checksum: UInt64
        do {
            let primaryChecksum = try runStageCGeneratorCycles(
                weighted: &weighted,
                delayed: &delayed,
                samples: samples,
                count: 10_000
            )
            let layeredChecksum = try runStageCGeneratorCycles(
                weighted: &textured,
                delayed: &dual,
                samples: samples,
                count: 10_000
            )
            checksum = primaryChecksum &+ layeredChecksum
        } catch {
            _ = probe.disarm()
            throw error
        }
        let allocations = probe.disarm()

        guard allocations == 0 else {
            throw ProbeHarnessError.stageCGeneratorAllocations(
                total: allocations
            )
        }
        print(
            "ALLOCATOR PROBE STAGE C GENERATOR PASS allocations=0 "
                + "cycles=10000 checksum=\(checksum)"
        )
    }

    @inline(never)
    private static func runStageCGeneratorCycles(
        weighted: inout BrushStrokeGenerator,
        delayed: inout BrushStrokeGenerator,
        samples: StageCGeneratorProbeSamples,
        count: Int
    ) throws -> UInt64 {
        var checksum: UInt64 = 0
        var emittedCount = 0
        for _ in 0..<count {
            weighted.begin(samples.began) { dab in
                emittedCount += 1
                checksum &+= UInt64(dab.rotation.bitPattern)
            }
            delayed.begin(samples.began) { dab in
                emittedCount += 1
                checksum &+= UInt64(dab.position.x.bitPattern)
            }
            try appendStageCGeneratorPair(
                weighted: &weighted,
                delayed: &delayed,
                sample: samples.right,
                checksum: &checksum,
                emittedCount: &emittedCount
            )
            try appendStageCGeneratorPair(
                weighted: &weighted,
                delayed: &delayed,
                sample: samples.up,
                checksum: &checksum,
                emittedCount: &emittedCount
            )
            try appendStageCGeneratorPair(
                weighted: &weighted,
                delayed: &delayed,
                sample: samples.left,
                checksum: &checksum,
                emittedCount: &emittedCount
            )
            let authoritativeBeforePrediction = weighted
            var prediction = weighted
            let predictionOutcome = try prediction.appendPredictionPrefix(
                samples.predicted,
                maximumPathSubdivisionCount: 4_096
            ) { dab in
                emittedCount += 1
                checksum &+= UInt64(dab.rotation.bitPattern)
                checksum &+= dab.ordinal
            }
            precondition(predictionOutcome == .completed)
            precondition(weighted == authoritativeBeforePrediction)
            try weighted.finish(
                samples.ended,
                maximumPathSubdivisionCount: 4_096
            ) { dab in
                emittedCount += 1
                checksum &+= UInt64(dab.rotation.bitPattern)
                checksum &+= dab.ordinal
            }
            try delayed.finish(
                samples.ended,
                maximumPathSubdivisionCount: 4_096
            ) { dab in
                emittedCount += 1
                checksum &+= UInt64(dab.position.x.bitPattern)
                checksum &+= dab.ordinal
            }
        }
        precondition(emittedCount <= count * 512)
        return checksum &+ UInt64(emittedCount)
    }

    @inline(__always)
    private static func appendStageCGeneratorPair(
        weighted: inout BrushStrokeGenerator,
        delayed: inout BrushStrokeGenerator,
        sample: WorldStrokeSample,
        checksum: inout UInt64,
        emittedCount: inout Int
    ) throws {
        try weighted.append(
            sample,
            maximumPathSubdivisionCount: 4_096
        ) { dab in
            emittedCount += 1
            checksum &+= UInt64(dab.rotation.bitPattern)
            checksum &+= dab.ordinal
        }
        try delayed.append(
            sample,
            maximumPathSubdivisionCount: 4_096
        ) { dab in
            emittedCount += 1
            checksum &+= UInt64(dab.position.x.bitPattern)
            checksum &+= dab.ordinal
        }
    }

    private static func makeStageCGeneratorProbeSamples()
        -> StageCGeneratorProbeSamples
    {
        let viewport = ViewportTransform(
            drawableSize: PatternSize(width: 256, height: 256),
            worldCenter: WorldPoint(x: 128, y: 128)
        )
        var deriver = BrushInputDeriver()
        func actual(
            x: Float,
            y: Float,
            timestamp: TimeInterval,
            phase: StrokePhase
        ) -> WorldStrokeSample {
            deriver.derive(
                StrokeSample(
                    position: ScreenPoint(x: x, y: y),
                    pressure: 0.5,
                    timestamp: timestamp,
                    phase: phase,
                    source: .pencil,
                    capabilities: [.pressure]
                ),
                viewport: viewport
            )
        }
        let began = actual(x: 64, y: 64, timestamp: 0, phase: .began)
        let right = actual(x: 112, y: 64, timestamp: 1, phase: .moved)
        let up = actual(x: 112, y: 16, timestamp: 2, phase: .moved)
        let left = actual(x: 64, y: 16, timestamp: 3, phase: .moved)
        var predictionDeriver = deriver
        let predicted = predictionDeriver.derive(
            StrokeSample(
                position: ScreenPoint(x: 112, y: 16),
                pressure: 0.5,
                timestamp: 4,
                phase: .moved,
                source: .pencil,
                kind: .predicted,
                capabilities: [.pressure]
            ),
            viewport: viewport
        )
        let ended = actual(x: 64, y: 64, timestamp: 4, phase: .ended)
        return StageCGeneratorProbeSamples(
            began: began,
            right: right,
            up: up,
            left: left,
            predicted: predicted,
            ended: ended
        )
    }

    private static func makeStageCProbeDefinition(
        id: String,
        stabilization: BrushStabilizationDefinition,
        maximumAngularStep: Float,
        footprint: StageCProbeFootprint = .ellipse
    ) throws -> BrushDefinition {
        let base = try LegacyBrushRecipeAdapter.definition(
            from: .legacyEquivalent,
            displayName: id
        )
        var outputs: [BrushDynamicOutput: BrushOutputProgramDefinition] = [:]
        for output in BrushDynamicOutput.allCases {
            let baseValue: Float = switch output {
            case .size, .flow, .opacity, .spacing, .hardness, .grain: 1
            case .rotation, .scatter, .offsetX, .offsetY, .hue,
                 .saturation, .brightness, .secondaryColorMix: 0
            }
            outputs[output] = BrushOutputProgramDefinition(
                baseValue: baseValue,
                terms: []
            )
        }
        outputs[.rotation] = BrushOutputProgramDefinition(
            baseValue: 0,
            terms: [
                BrushResponseTermDefinition(
                    input: .direction,
                    response: .linear,
                    inputInverted: false,
                    missingInputValue: 0.5,
                    responseScale: 2 * .pi,
                    responseOffset: -.pi,
                    responseLowerClamp: -.pi,
                    responseUpperClamp: .pi,
                    jitter: 0,
                    operation: .replace
                ),
            ]
        )
        let primaryShape = base.coverage.shapes[0]
        let coverage: BrushCoverageDefinition
        let tipSupports: [BrushTipSupportDefinition]
        switch footprint {
        case .ellipse:
            coverage = base.coverage
            tipSupports = [.analyticEllipse]
        case .chisel:
            coverage = BrushCoverageDefinition(
                shapes: [primaryShape],
                grains: base.coverage.grains,
                baseHardness: base.coverage.baseHardness,
                aspectRatio: 0.2,
                tipThreshold: base.coverage.tipThreshold,
                antialiasing: base.coverage.antialiasing
            )
            tipSupports = [.analyticRectangle]
        case .translatedBounds:
            coverage = BrushCoverageDefinition(
                shapes: [BrushShapeLayerDefinition(
                    shape: primaryShape.shape,
                    combination: .replace,
                    scale: 0.75,
                    rotation: .pi / 9,
                    offset: SIMD2(0.6, -0.35)
                )],
                grains: base.coverage.grains,
                baseHardness: base.coverage.baseHardness,
                aspectRatio: 0.6,
                tipThreshold: base.coverage.tipThreshold,
                antialiasing: base.coverage.antialiasing
            )
            tipSupports = [try .normalizedBounds(
                minX: -0.7,
                maxX: 0.85,
                minY: -0.45,
                maxY: 0.65
            )]
        case .dualEllipse:
            coverage = BrushCoverageDefinition(
                shapes: [
                    primaryShape,
                    BrushShapeLayerDefinition(
                        shape: primaryShape.shape,
                        combination: .maximum,
                        scale: 0.5,
                        rotation: -.pi / 7,
                        offset: SIMD2(1.4, 0.3)
                    ),
                ],
                grains: base.coverage.grains,
                baseHardness: base.coverage.baseHardness,
                aspectRatio: 0.7,
                tipThreshold: base.coverage.tipThreshold,
                antialiasing: base.coverage.antialiasing
            )
            tipSupports = [.analyticEllipse, .analyticEllipse]
        }
        var capabilities = base.capabilities
        if coverage.shapes.count == 2 {
            capabilities.append(BrushCapabilityDeclaration(
                identifier: BrushCapability.dualShape.rawValue,
                required: true
            ))
        }
        let replayLimits = BrushRecipePolicy.replayTailLimits
        return try BrushDefinition(
            v2ID: BrushRecipeID(id),
            metadata: base.metadata,
            capabilities: capabilities,
            resources: base.resources,
            coverage: coverage,
            placement: BrushPlacementDefinition(
                baseSpacingFraction: 0.05,
                maximumSpacingFraction: max(
                    0.05,
                    base.placement.maximumSpacingFraction
                ),
                baseFlow: base.placement.baseFlow,
                strokeOpacity: base.placement.strokeOpacity,
                baseScatterFraction: 0,
                baseRotation: 0,
                baseJitterFraction: 0,
                baseOffset: .zero
            ),
            dynamics: base.dynamics,
            color: base.color,
            material: base.material,
            stabilization: base.stabilization,
            taper: .none,
            replayMode: .replayTail,
            replayLimits: replayLimits,
            termination: .boundedCorrection(
                maximumSamples: replayLimits.maximumSamples,
                maximumWorldLength: 4_096,
                maximumDabs: replayLimits.maximumDabs
            ),
            seedPolicy: .perStroke,
            limits: base.limits,
            performanceIntent: base.performanceIntent,
            compatibility: base.compatibility,
            sensorNormalization: BrushSensorNormalizationDefinition(
                fullScaleWorldVelocity: 2_000,
                minimumVelocityDeltaTime: 0.001,
                fullScaleStrokeAge: 4,
                fullScaleStrokeDistanceInDiameters: 32
            ),
            sensorProgram: BrushSensorProgramDefinition(outputs: outputs),
            stabilizationV2: stabilization,
            direction: BrushDirectionDefinition(
                maximumAngularStep: maximumAngularStep,
                stationaryDirection: 0
            ),
            emission: BrushEmissionDefinition(
                mode: .distance,
                timeInterval: nil
            ),
            tipSupports: tipSupports
        )
    }

    private static func runTimedEmitterProbe(
        probe: AllocatorProbe
    ) throws {
        var emitter = try TimedStrokeEmitter(timeInterval: 0.01)
        var begin = try emitter.begin(at: timedEmitterPoint(
            index: 0,
            timestamp: 0,
            sourceDistance: 0
        ))
        _ = try begin.emitNextPage { _ in }
        _ = try runTimedEmitterUpdates(
            emitter: &emitter,
            startingAt: 1,
            count: 128
        )

        probe.arm()
        let normalChecksum: UInt64
        do {
            normalChecksum = try runTimedEmitterUpdates(
                emitter: &emitter,
                startingAt: 129,
                count: 1_000_000
            )
        } catch {
            _ = probe.disarm()
            throw error
        }
        let normalAllocations = probe.disarm()

        var hugeEmitter = try TimedStrokeEmitter(timeInterval: 1.0 / 240)
        var hugeBegin = try hugeEmitter.begin(at: timedEmitterPoint(
            index: 0,
            timestamp: 0,
            sourceDistance: 0
        ))
        _ = try hugeBegin.emitNextPage { _ in }
        var warmPredictionEmitter = hugeEmitter
        guard var warmCursor = try warmPredictionEmitter.prediction(
            to: timedEmitterPoint(
                index: 1,
                timestamp: 10,
                sourceDistance: 1,
                kind: .predicted
            )
        ) else {
            throw ProbeHarnessError.timedEmitterMissingCursor
        }
        _ = try warmCursor.emitNextPage { _ in }

        probe.arm()
        var hugeChecksum: UInt64 = 0
        let remaining: UInt64
        do {
            guard var cursor = try hugeEmitter.advance(
                to: timedEmitterPoint(
                    index: 2,
                    timestamp: 1_000_000,
                    sourceDistance: 2
                )
            ) else {
                throw ProbeHarnessError.timedEmitterMissingCursor
            }
            _ = try cursor.emitNextPage { candidate in
                hugeChecksum &+= UInt64(bitPattern: candidate.timeKey)
                hugeChecksum &+= UInt64(bitPattern: candidate.distanceKey)
            }
            remaining = cursor.remainingCandidateCount
        } catch {
            _ = probe.disarm()
            throw error
        }
        let hugeGapAllocations = probe.disarm()

        guard normalAllocations == 0, hugeGapAllocations == 0 else {
            throw ProbeHarnessError.timedEmitterAllocations(
                normal: normalAllocations,
                hugeGap: hugeGapAllocations
            )
        }
        print(
            "ALLOCATOR PROBE TIMED EMITTER PASS normal=0 huge_gap=0 "
                + "checksum=\(normalChecksum &+ hugeChecksum) "
                + "remaining=\(remaining)"
        )
    }

    private static func runTipSupportSpacingProbe(
        probe: AllocatorProbe
    ) throws {
        let bounds = try BrushTipSupportDefinition.normalizedBounds(
            minX: -0.25,
            maxX: 0.75,
            minY: -0.5,
            maxY: 0.5
        )
        let layers = [
            try BrushTipSupportLayer(
                definition: .analyticEllipse,
                xAxis: SIMD2(3, 1),
                yAxis: SIMD2(-0.5, 1.5),
                offset: SIMD2(-1, 0.25)
            ),
            try BrushTipSupportLayer(
                definition: bounds,
                xAxis: SIMD2(1.5, -0.25),
                yAxis: SIMD2(0.25, 1),
                offset: SIMD2(2, -0.5)
            ),
        ]
        _ = try runTipSupportSpacingUpdates(
            layers: layers,
            startingAt: 0,
            count: 128
        )

        probe.arm()
        let checksum: UInt64
        do {
            checksum = try runTipSupportSpacingUpdates(
                layers: layers,
                startingAt: 128,
                count: 1_000_000
            )
        } catch {
            _ = probe.disarm()
            throw error
        }
        let allocations = probe.disarm()

        guard allocations == 0 else {
            throw ProbeHarnessError.tipSupportSpacingAllocations(
                total: allocations
            )
        }
        print(
            "ALLOCATOR PROBE TIP SUPPORT/SPACING PASS allocations=0 "
                + "checksum=\(checksum)"
        )
    }

    private static func runSensorProgramProbe(
        probe: AllocatorProbe
    ) throws {
        let program = try makeSensorProgramProbe()
        let engine = BrushDynamicsEngine()
        let sample = InterpolatedStrokeSample(
            position: WorldPoint(x: 3, y: 4),
            pressure: 0.25,
            timestamp: 0,
            altitude: 3 * .pi / 8,
            azimuth: -.pi / 2,
            roll: -.pi / 2,
            velocity: 250,
            artisticVelocity: 250,
            phase: .moved,
            source: .pencil,
            kind: .actual,
            capabilities: [.pressure, .altitude, .azimuth, .roll],
            tangentialPressure: -0.5
        )
        _ = runSensorProgramUpdates(
            engine: engine,
            program: program,
            sample: sample,
            startingAt: 0,
            count: 128
        )

        probe.arm()
        let checksum = runSensorProgramUpdates(
            engine: engine,
            program: program,
            sample: sample,
            startingAt: 128,
            count: 1_000_000
        )
        let allocations = probe.disarm()

        guard allocations == 0 else {
            throw ProbeHarnessError.sensorProgramAllocations(
                total: allocations
            )
        }
        print(
            "ALLOCATOR PROBE SENSOR PROGRAM PASS allocations=0 "
                + "checksum=\(checksum)"
        )
    }

    private static func makeSensorProgramProbe() throws -> BrushProgram {
        let base = try LegacyBrushRecipeAdapter.definition(
            from: .legacyEquivalent,
            displayName: "Sensor Program Allocation Probe"
        )
        var outputs: [BrushDynamicOutput: BrushOutputProgramDefinition] = [:]
        for output in BrushDynamicOutput.allCases {
            let operations: [BrushResponseOperation] = switch output {
            case .offsetX, .offsetY:
                [.replace, .add, .minimum, .maximum]
            case .rotation, .hue:
                [.replace, .multiply, .add, .add]
            default:
                [.replace, .multiply, .add, .maximum]
            }
            let inputs: [BrushDynamicsInput] = [
                .pressure, .speed, .tilt, .age,
            ]
            var terms: [BrushResponseTermDefinition] = []
            terms.reserveCapacity(4)
            for index in 0..<4 {
                terms.append(BrushResponseTermDefinition(
                    input: inputs[index],
                    response: index == 2
                        ? .boundedPower(exponent: 2) : .linear,
                    inputInverted: index == 2,
                    missingInputValue: 0.5,
                    responseScale: index == 1 ? 0.5 : 0.25,
                    responseOffset: index == 1 ? 1 : 0.25,
                    responseLowerClamp: -8,
                    responseUpperClamp: 8,
                    jitter: index == 3 ? 0.1 : 0,
                    operation: operations[index]
                ))
            }
            let baseValue: Float = switch output {
            case .size, .flow, .opacity, .spacing, .hardness, .grain: 1
            case .rotation, .scatter, .offsetX, .offsetY, .hue,
                 .saturation, .brightness, .secondaryColorMix: 0
            }
            outputs[output] = BrushOutputProgramDefinition(
                baseValue: baseValue,
                terms: terms
            )
        }
        let definition = try BrushDefinition(
            v2ID: BrushRecipeID("probe.stage-c.sensor-program"),
            metadata: base.metadata,
            capabilities: base.capabilities,
            resources: base.resources,
            coverage: base.coverage,
            placement: base.placement,
            dynamics: base.dynamics,
            color: base.color,
            material: base.material,
            stabilization: base.stabilization,
            taper: .none,
            replayMode: .appendOnly,
            replayLimits: nil,
            termination: .cap,
            seedPolicy: .perStroke,
            limits: base.limits,
            performanceIntent: base.performanceIntent,
            compatibility: base.compatibility,
            sensorNormalization: BrushSensorNormalizationDefinition(
                fullScaleWorldVelocity: 1_000,
                minimumVelocityDeltaTime: 0.001,
                fullScaleStrokeAge: 10,
                fullScaleStrokeDistanceInDiameters: 10
            ),
            sensorProgram: BrushSensorProgramDefinition(outputs: outputs),
            stabilizationV2: .none,
            direction: BrushDirectionDefinition(
                maximumAngularStep: .pi / 6,
                stationaryDirection: 0
            ),
            emission: BrushEmissionDefinition(
                mode: .distance,
                timeInterval: nil
            ),
            tipSupports: [.analyticEllipse]
        )
        return try BrushProgramCompiler.compile(definition)
    }

    @inline(never)
    private static func runSensorProgramUpdates(
        engine: BrushDynamicsEngine,
        program: BrushProgram,
        sample: InterpolatedStrokeSample,
        startingAt start: Int,
        count: Int
    ) -> UInt64 {
        var checksum: UInt64 = 0
        for index in start..<(start + count) {
            let dab = engine.evaluate(
                sample: sample,
                context: BrushStrokeContext(
                    nominalDiameter: 20,
                    color: .black,
                    direction: -.pi / 2,
                    strokeAge: Float(index & 255) / 32,
                    traveledDistance: Float(index & 1_023),
                    ordinal: UInt64(index),
                    isPredicted: false
                ),
                program: program,
                random: .centered,
                strokeSeed: 0x0123_4567_89ab_cdef
            )
            checksum &+= UInt64(dab.diameter.bitPattern)
            checksum &+= UInt64(dab.spacing.bitPattern)
            checksum &+= UInt64(dab.flow.bitPattern)
            checksum &+= UInt64(dab.strokeOpacity.bitPattern)
            checksum &+= UInt64(dab.rotation.bitPattern)
            checksum &+= UInt64(dab.scatter.x.bitPattern)
            checksum &+= UInt64(dab.hardness.bitPattern)
            checksum &+= UInt64(dab.grainScale.bitPattern)
            checksum &+= UInt64(dab.position.x.bitPattern)
            checksum &+= UInt64(dab.position.y.bitPattern)
            checksum &+= UInt64(dab.color.red.bitPattern)
            checksum &+= UInt64(dab.color.green.bitPattern)
            checksum &+= UInt64(dab.color.blue.bitPattern)
            checksum &+= UInt64(dab.secondaryColorMix.bitPattern)
        }
        return checksum
    }

    @inline(never)
    private static func runTipSupportSpacingUpdates(
        layers: [BrushTipSupportLayer],
        startingAt start: Int,
        count: Int
    ) throws -> UInt64 {
        let diagonal = Float(1 / sqrt(2.0))
        var checksum: UInt64 = 0
        for index in start..<(start + count) {
            let tangent: SIMD2<Float> = switch index & 3 {
            case 0: SIMD2(1, 0)
            case 1: SIMD2(repeating: diagonal)
            case 2: SIMD2(0, 1)
            default: SIMD2(-1, 0)
            }
            let interval = try BrushTipSupport.projectionInterval(
                layers: layers,
                tangent: tangent
            )
            let carry = try BrushFootprintSpacing.nextCarry(
                supportWidth: interval.width,
                baseSpacingFraction: 0.1,
                dynamicSpacing: 0.5 + Float(index & 3),
                maximumSpacingFraction: 0.4
            )
            checksum &+= UInt64(interval.minimumProjection.bitPattern)
            checksum &+= UInt64(interval.maximumProjection.bitPattern)
            checksum &+= UInt64(carry.bitPattern)
        }
        return checksum
    }

    @inline(never)
    private static func runTimedEmitterUpdates(
        emitter: inout TimedStrokeEmitter,
        startingAt start: Int,
        count: Int
    ) throws -> UInt64 {
        var checksum: UInt64 = 0
        for index in start..<(start + count) {
            guard var cursor = try emitter.advance(to: timedEmitterPoint(
                index: index,
                timestamp: Double(index) * 0.01,
                sourceDistance: Double(index)
            )) else {
                continue
            }
            _ = try cursor.emitNextPage { candidate in
                checksum &+= UInt64(bitPattern: candidate.timeKey)
                checksum &+= UInt64(bitPattern: candidate.distanceKey)
                checksum &+= UInt64(candidate.sample.position.x.bitPattern)
            }
        }
        return checksum
    }

    private static func timedEmitterPoint(
        index: Int,
        timestamp: TimeInterval,
        sourceDistance: Double,
        kind: StrokeSampleKind = .actual
    ) -> TimedStrokePoint {
        TimedStrokePoint(
            sample: InterpolatedStrokeSample(
                position: WorldPoint(
                    x: Float(index & 1_023),
                    y: Float((index >> 3) & 1_023)
                ),
                pressure: Float(index & 255) / 255,
                timestamp: timestamp,
                altitude: 0.5,
                azimuth: 0.25,
                roll: -0.25,
                velocity: 100,
                artisticVelocity: 100,
                phase: index == 0 ? .began : .moved,
                source: .pencil,
                kind: kind,
                capabilities: [.pressure, .altitude, .azimuth, .roll]
            ),
            sourceDistance: sourceDistance,
            direction: Float(index & 255) * 0.01
        )
    }

    @inline(never)
    private static func runStabilizerV2Updates(
        weighted: inout StrokeStabilizer,
        delayed: inout StrokeStabilizer,
        samples: StabilizerProbeSamples,
        startingAt start: Int,
        count: Int
    ) throws -> UInt64 {
        var checksum: UInt64 = 0
        for index in start..<(start + count) {
            let sample = switch index & 3 {
            case 0: samples.right
            case 1: samples.up
            case 2: samples.left
            default: samples.down
            }
            if let output = try weighted.processV2(sample) {
                checksum &+= UInt64(output.position.x.bitPattern)
                checksum &+= UInt64(output.position.y.bitPattern)
            }
            if let output = try delayed.processV2(sample) {
                checksum &+= UInt64(output.position.x.bitPattern)
                checksum &+= UInt64(output.position.y.bitPattern)
            }
        }
        return checksum
    }

    private static func makeStabilizerProbeSamples()
        -> StabilizerProbeSamples
    {
        let viewport = ViewportTransform(
            drawableSize: PatternSize(width: 2, height: 2),
            worldCenter: WorldPoint(x: 0, y: 0)
        )
        var deriver = BrushInputDeriver()
        func sample(
            x: Float,
            y: Float,
            timestamp: TimeInterval,
            phase: StrokePhase
        ) -> WorldStrokeSample {
            deriver.derive(
                StrokeSample(
                    position: ScreenPoint(x: x + 1, y: y + 1),
                    pressure: 0.5,
                    timestamp: timestamp,
                    phase: phase,
                    source: .pencil,
                    capabilities: [.pressure]
                ),
                viewport: viewport
            )
        }
        return StabilizerProbeSamples(
            began: sample(x: 0, y: 0, timestamp: 0, phase: .began),
            right: sample(x: 1, y: 0, timestamp: 1, phase: .moved),
            up: sample(x: 1, y: 1, timestamp: 2, phase: .moved),
            left: sample(x: 0, y: 1, timestamp: 3, phase: .moved),
            down: sample(x: 0, y: 0, timestamp: 4, phase: .moved)
        )
    }

    @inline(never)
    private static func runInputDerivationUpdates(
        deriver: inout BrushInputDeriver,
        viewport: ViewportTransform,
        startingAt start: Int,
        count: Int
    ) -> UInt64 {
        var checksum: UInt64 = 0
        for index in start..<(start + count) {
            let x = Float((index * 17) & 2_047)
            let y = Float((index * 29) & 2_047)
            let sample = StrokeSample(
                position: ScreenPoint(x: x, y: y),
                pressure: Float(index & 255) / 255,
                timestamp: Double(index) * 0.001,
                phase: .moved,
                source: .pencil,
                kind: index.isMultiple(of: 3) ? .coalesced : .actual,
                capabilities: [.pressure]
            )
            let world = deriver.derive(sample, viewport: viewport)
            checksum &+= UInt64(world.position.x.bitPattern)
            checksum &+= UInt64(world.position.y.bitPattern)
            checksum &+= UInt64(world.velocity.bitPattern)
            checksum &+= UInt64(world.artisticVelocity.bitPattern)
        }
        return checksum
    }

    @inline(never)
    private static func runDirectionCornerUpdates(
        tracker: inout BrushDirectionTracker,
        emitter: BrushCornerEmitter,
        output: inout StrokeEmissionCandidateBuffer,
        position: inout WorldPoint,
        nextCornerSequence: inout UInt64,
        startingAt start: Int,
        count: Int
    ) throws -> UInt64 {
        var checksum: UInt64 = 0
        for index in start..<(start + count) {
            switch index & 3 {
            case 0: position.x += 1
            case 1: position.y += 1
            case 2: position.x -= 1
            default: position.y -= 1
            }

            let update = try tracker.update(to: position)
            guard
                let direction = update.direction,
                let signedTurn = update.signedTurn
            else {
                continue
            }
            let sample = InterpolatedStrokeSample(
                position: position,
                pressure: 0.5,
                timestamp: Double(index) * 0.001,
                altitude: nil,
                azimuth: nil,
                roll: nil,
                velocity: 1_000,
                artisticVelocity: 1_000,
                phase: .moved,
                source: .pencil,
                kind: .actual,
                capabilities: [.pressure]
            )
            let vertex = StrokeEmissionCandidate(
                sample: sample,
                relativeStrokeTime: Double(index) * 0.001,
                sourceDistance: Double(index),
                direction: direction,
                provenance: .authoritative,
                timeKey: Int64(index) * 1_000_000,
                distanceKey: Int64(index) * 1_000_000,
                kind: .distance,
                cornerSequence: 0
            )
            output.reset()
            try emitter.emit(
                from: direction - signedTurn,
                signedTurn: signedTurn,
                vertex: vertex,
                into: &output,
                nextCornerSequence: &nextCornerSequence
            )
            checksum &+= UInt64(direction.bitPattern)
            checksum &+= UInt64(output.count)
            if !output.isEmpty {
                checksum &+= output[0].cornerSequence
            }
        }
        return checksum
    }

    @inline(never)
    private static func runVelocityFilterUpdates(
        filter: inout StrokeVelocityFilter,
        startingAt start: Int,
        count: Int
    ) -> UInt64 {
        var checksum: UInt64 = 0
        for index in start..<(start + count) {
            let time = Double(index) * StrokeVelocityFilter.minimumDeltaTime
            let velocity = filter.update(
                to: WorldPoint(x: Float(index), y: 0),
                time: time
            )
            checksum &+= UInt64(velocity.bitPattern)
        }
        return checksum
    }

    @MainActor
    private static func runProduction(
        probe: AllocatorProbe,
        root: URL
    ) async throws {
        let setup = try await makeRendererSetup(root: root)
        let renderer = setup.renderer
        let token = RendererOperationToken(rawValue: 1)
        try renderer.beginStroke(
            token: token,
            sample: sample(.began, x: 0),
            style: StrokeRenderStyle(
                color: .black,
                diameter: 20,
                compositeMode: .draw,
                eraserStrength: 1,
                program: setup.brush.program,
                renderIdentity: setup.brush.renderIdentity,
                seed: 1
            )
        )

        for index in 1...128 {
            let usesEstimatedUpdate = index.isMultiple(of: 32)
            try renderer.appendStroke(
                token: token,
                sample: usesEstimatedUpdate
                    ? unresolvedEstimatedSample(index: index)
                    : sample(
                        .moved,
                        x: Float(index % 96) * 0.5
                    )
            )
            if usesEstimatedUpdate {
                try renderer.applyEstimatedStrokeUpdate(
                    token: token,
                    sample: estimatedUpdateSample(index: index)
                )
            }
            if index.isMultiple(of: 16) {
                try renderer.appendStrokeBatch(
                    token: token,
                    samples: predictedBatch(
                        after: index,
                        count: index.isMultiple(of: 64) ? 65 : 4
                    )
                )
            }
            _ = try renderer.flushPendingLiveForHarness()
        }

        var allocationCount: UInt64 = 0
        var firstAllocationIndex = 0
        var firstAllocationWasPredicted = false
        var firstAllocationCount: UInt64 = 0
        var maximumSingleCallCount: UInt64 = 0
        for index in 129...640 {
            let usesEstimatedUpdate = index.isMultiple(of: 32)
            let authoritativeSample = usesEstimatedUpdate
                ? unresolvedEstimatedSample(index: index)
                : sample(
                    .moved,
                    x: Float(index % 96) * 0.5
                )
            probe.arm()
            do {
                try renderer.appendStroke(
                    token: token,
                    sample: authoritativeSample
                )
            } catch {
                _ = probe.disarm()
                throw error
            }
            let authoritativeAllocations = probe.disarm()
            allocationCount += authoritativeAllocations
            maximumSingleCallCount = max(
                maximumSingleCallCount,
                authoritativeAllocations
            )
            if authoritativeAllocations > 0, firstAllocationCount == 0 {
                firstAllocationIndex = index
                firstAllocationCount = authoritativeAllocations
            }

            if usesEstimatedUpdate {
                let update = estimatedUpdateSample(index: index)
                probe.arm()
                do {
                    try renderer.applyEstimatedStrokeUpdate(
                        token: token,
                        sample: update
                    )
                } catch {
                    _ = probe.disarm()
                    throw error
                }
                let estimatedUpdateAllocations = probe.disarm()
                allocationCount += estimatedUpdateAllocations
                maximumSingleCallCount = max(
                    maximumSingleCallCount,
                    estimatedUpdateAllocations
                )
                if estimatedUpdateAllocations > 0,
                   firstAllocationCount == 0
                {
                    firstAllocationIndex = index
                    firstAllocationCount = estimatedUpdateAllocations
                }
            }

            if index.isMultiple(of: 16) {
                let predicted = predictedBatch(
                    after: index,
                    count: index.isMultiple(of: 64)
                        ? 65
                        : 2 + (index / 16) % 4
                )
                probe.arm()
                do {
                    try renderer.appendStrokeBatch(
                        token: token,
                        samples: predicted
                    )
                } catch {
                    _ = probe.disarm()
                    throw error
                }
                let predictedAllocations = probe.disarm()
                allocationCount += predictedAllocations
                maximumSingleCallCount = max(
                    maximumSingleCallCount,
                    predictedAllocations
                )
                if predictedAllocations > 0, firstAllocationCount == 0 {
                    firstAllocationIndex = index
                    firstAllocationWasPredicted = true
                    firstAllocationCount = predictedAllocations
                }
            }
            _ = try renderer.flushPendingLiveForHarness()
        }
        try renderer.cancelStroke(token: token)

        guard allocationCount == 0 else {
            throw ProbeHarnessError.productionAllocations(
                total: allocationCount,
                firstIndex: firstAllocationIndex,
                firstWasPredicted: firstAllocationWasPredicted,
                firstCount: firstAllocationCount,
                maximumSingleCallCount: maximumSingleCallCount
            )
        }
        try await runOffMainEstimatedCorrectionProbe(
            probe: probe,
            root: root
        )
        print(
            "ALLOCATOR PROBE PRODUCTION PASS allocations=\(allocationCount)"
        )
    }

    @MainActor
    private static func runOffMainEstimatedCorrectionProbe(
        probe: AllocatorProbe,
        root: URL
    ) async throws {
        let setup = try await makeRendererSetup(
            root: root,
            usesOffMainNativeInk: true
        )
        let renderer = setup.renderer
        let warmedWorkspaceIdentity =
            renderer.offMainStrokeWorkspaceIdentityForTesting
        let warmedWorkspaceInstallationCount = renderer
            .offMainStrokeWorkspaceInstallationCountForTesting
        let measurements = ActorAllocationMeasurements()
        renderer.setStrokePreparationAllocationProbeForHarness(
            StrokePreparationAllocationProbe(
                identity: 1,
                arm: { probe.arm() },
                disarm: { probe.disarm() },
                record: { stage, count in
                    measurements.record(stage, count: count)
                }
            )
        )
        let token = RendererOperationToken(rawValue: 2)
        try renderer.beginStroke(
            token: token,
            sample: sample(.began, x: 0),
            style: StrokeRenderStyle(
                color: .black,
                diameter: 20,
                compositeMode: .draw,
                eraserStrength: 1,
                program: setup.brush.program,
                renderIdentity: setup.brush.renderIdentity,
                seed: 2
            )
        )
        try await drainUntilMeasured(
            renderer: renderer,
            measurements: measurements,
            stage: .authoritativeCPU,
            expectedEventCount: 1
        )

        let warmEventCount = 32
        for index in 1...warmEventCount {
            try renderer.appendStroke(
                token: token,
                sample: unresolvedEstimatedSample(index: index)
            )
            try renderer.applyEstimatedStrokeUpdate(
                token: token,
                sample: estimatedUpdateSample(index: index)
            )
            try await drainUntilMeasured(
                renderer: renderer,
                measurements: measurements,
                stage: .estimatedCPU,
                expectedEventCount: index
            )
        }
        let warmPredictionEventCount = 16
        for offset in 1...warmPredictionEventCount {
            try renderer.appendStrokeBatch(
                token: token,
                samples: predictedBatch(
                    after: warmEventCount + offset,
                    count: 4
                )
            )
            try await drainUntilMeasured(
                renderer: renderer,
                measurements: measurements,
                stage: .predictionCPU,
                expectedEventCount: offset
            )
        }
        measurements.reset()

        let measuredEventCount = 64
        var mainActorEnqueueAllocations: UInt64 = 0
        for offset in 1...measuredEventCount {
            let index = warmEventCount + offset
            let unresolved = unresolvedEstimatedSample(index: index)
            probe.arm()
            do {
                try renderer.appendStroke(token: token, sample: unresolved)
            } catch {
                _ = probe.disarm()
                throw error
            }
            mainActorEnqueueAllocations += probe.disarm()
            let update = estimatedUpdateSample(index: index)
            probe.arm()
            do {
                try renderer.applyEstimatedStrokeUpdate(
                    token: token,
                    sample: update
                )
            } catch {
                _ = probe.disarm()
                throw error
            }
            mainActorEnqueueAllocations += probe.disarm()
            try await drainUntilMeasured(
                renderer: renderer,
                measurements: measurements,
                stage: .estimatedCPU,
                expectedEventCount: offset
            )
        }

        let measuredPredictionEventCount = 32
        for offset in 1...measuredPredictionEventCount {
            let predicted = predictedBatch(
                after: warmEventCount + measuredEventCount + offset,
                count: 4
            )
            probe.arm()
            do {
                try renderer.appendStrokeBatch(
                    token: token,
                    samples: predicted
                )
            } catch {
                _ = probe.disarm()
                throw error
            }
            mainActorEnqueueAllocations += probe.disarm()
            try await drainUntilMeasured(
                renderer: renderer,
                measurements: measurements,
                stage: .predictionCPU,
                expectedEventCount: offset
            )
        }

        let authoritative = measurements.snapshot(for: .authoritativeCPU)
        let estimated = measurements.snapshot(for: .estimatedCPU)
        let prediction = measurements.snapshot(for: .predictionCPU)
        let packaging = measurements.snapshot(for: .batchPackaging)
        let surface = measurements.snapshot(for: .privateSurfaceEncoding)
        let workspaceInstallationDelta = renderer
            .offMainStrokeWorkspaceInstallationCountForTesting
            - warmedWorkspaceInstallationCount
        let workspaceIdentityChanged = renderer
            .offMainStrokeWorkspaceIdentityForTesting
            != warmedWorkspaceIdentity
        try renderer.cancelStroke(token: token)
        print(
            "ALLOCATOR PROBE OFF-MAIN METRICS main="
                + "\(mainActorEnqueueAllocations) "
                + "authoritative=\(authoritative.allocationCount)/"
                + "\(authoritative.firstHalfAllocationCount)/"
                + "\(authoritative.lastHalfAllocationCount)/"
                + "\(authoritative.maximumSingleEventCount) "
                + "estimated=\(estimated.allocationCount)/"
                + "\(estimated.firstHalfAllocationCount)/"
                + "\(estimated.lastHalfAllocationCount)/"
                + "\(estimated.maximumSingleEventCount) "
                + "prediction=\(prediction.allocationCount)/"
                + "\(prediction.firstHalfAllocationCount)/"
                + "\(prediction.lastHalfAllocationCount)/"
                + "\(prediction.maximumSingleEventCount) "
                + "packaging=\(packaging.allocationCount)/"
                + "\(packaging.firstHalfAllocationCount)/"
                + "\(packaging.lastHalfAllocationCount)/"
                + "\(packaging.maximumSingleEventCount) "
                + "workspace=\(workspaceInstallationDelta)/"
                + "\(workspaceIdentityChanged ? 1 : 0) "
                + "surface_driver=\(surface.allocationCount)/"
                + "\(surface.firstHalfAllocationCount)/"
                + "\(surface.lastHalfAllocationCount)/"
                + "\(surface.maximumSingleEventCount)"
        )
        let actorStages: [(
            String,
            ActorAllocationMeasurements.Snapshot,
            Int
        )] = [
            ("authoritative", authoritative, measuredEventCount),
            ("estimated", estimated, measuredEventCount),
            ("prediction", prediction, measuredPredictionEventCount),
        ]
        guard mainActorEnqueueAllocations == 0 else {
            throw ProbeHarnessError.offMainAllocationRegression(
                "MainActor enqueue allocations=\(mainActorEnqueueAllocations)"
            )
        }
        for (name, snapshot, expectedCount) in actorStages {
            guard snapshot.eventCount == expectedCount,
                  snapshot.allocationCount == 0
            else {
                throw ProbeHarnessError.offMainAllocationRegression(
                    "\(name) events=\(snapshot.eventCount)/\(expectedCount) "
                        + "first=\(snapshot.firstHalfAllocationCount) "
                        + "last=\(snapshot.lastHalfAllocationCount) "
                        + "max=\(snapshot.maximumSingleEventCount)"
                )
            }
        }
        guard packaging.eventCount >= measuredEventCount
                + measuredPredictionEventCount,
              packaging.allocationCount == 0
        else {
            throw ProbeHarnessError.offMainAllocationRegression(
                "packaging events=\(packaging.eventCount) "
                    + "allocations=\(packaging.allocationCount) "
                    + "max=\(packaging.maximumSingleEventCount)"
            )
        }
        guard workspaceInstallationDelta == 0,
              !workspaceIdentityChanged
        else {
            throw ProbeHarnessError.offMainAllocationRegression(
                "workspace installations=\(workspaceInstallationDelta) "
                    + "identityChanged=\(workspaceIdentityChanged)"
            )
        }
        guard surface.eventCount >= measuredEventCount
                + measuredPredictionEventCount,
              surface.lastHalfAllocationCount
                <= surface.firstHalfAllocationCount,
              surface.maximumSingleEventCount <= 64
        else {
            throw ProbeHarnessError.offMainAllocationRegression(
                "surface events=\(surface.eventCount) "
                    + "first=\(surface.firstHalfAllocationCount) "
                    + "last=\(surface.lastHalfAllocationCount) "
                    + "max=\(surface.maximumSingleEventCount)/64"
            )
        }
        print(
            "ALLOCATOR PROBE OFF-MAIN PASS application=0 workspace=0 "
                + "main=0 "
                + "authoritative=\(authoritative.allocationCount) "
                + "estimated=\(estimated.allocationCount) "
                + "prediction=\(prediction.allocationCount) "
                + "packaging=\(packaging.allocationCount) "
                + "surface_driver_mallocs=\(surface.allocationCount)"
        )
    }

    @MainActor
    private static func drainUntilMeasured(
        renderer: GridRenderer,
        measurements: ActorAllocationMeasurements,
        stage: StrokePreparationAllocationProbeStage,
        expectedEventCount: Int
    ) async throws {
        for _ in 0..<20_000 {
            if measurements.snapshot(for: stage).eventCount
                >= expectedEventCount,
               renderer.strokePreparationIsQuiescentForAllocationHarness
            {
                return
            }
            try renderer.advanceStrokePreparationForAllocationHarness()
            await Task.yield()
        }
        throw ProbeHarnessError.offMainEstimatedAllocations(
            total: measurements.snapshot(for: stage).allocationCount,
            maximum:
                measurements.snapshot(for: stage).maximumSingleEventCount
        )
    }

    @MainActor
    private static func makeRendererSetup(
        root: URL,
        usesOffMainNativeInk: Bool = false
    ) async throws
        -> RendererSetup
    {
        guard
            let device = MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue()
        else {
            throw ProbeHarnessError.metalUnavailable
        }
        let library = try rendererLibrary(device: device, root: root)
        let renderer = try GridRenderer(
            device: device,
            library: library,
            drawableSize: PatternSize(width: 64, height: 64),
            configuration: TilingCanvasConfiguration(
                pixelSize: PixelSize(width: 64, height: 64),
                tiling: .grid
            )
        )
        let profile = try BrushDeviceProfile(
            registryID: device.registryID,
            recommendedWorkingSetBytes: 1_024 * 1_024 * 1_024,
            maximumWorkingTextureDimension: 4_096,
            brushCacheBudgetBytes: 64 * 1_024 * 1_024,
            targetFramesPerSecond: 120
        )
        let compiler = BrushCompiler(
            device: device,
            commandQueue: queue,
            profile: profile,
            pipelineLibrary: DepositionPipelineLibrary(
                device: device,
                library: library
            )
        )
        let definition: BrushDefinition
        if usesOffMainNativeInk {
            definition = try makeStageCProbeDefinition(
                id: "probe.stage-c.production-weighted",
                stabilization: .weightedWindow(distance: 8),
                maximumAngularStep: .pi / 8
            )
        } else {
            let recipe = try BrushRecipe(
                id: BrushRecipeID("brush.allocator-probe"),
                replayMode: .replayTail,
                replayLimits: BrushRecipePolicy.replayTailLimits
            )
            definition = try LegacyBrushRecipeAdapter.definition(
                from: recipe,
                displayName: recipe.id.rawValue
            )
        }
        let brush = try await compiler.compileAndActivate(
            definition: definition
        )
        try renderer.activateDrawBrush(brush)
        try renderer.applyTiling(.squareRotation)
        return RendererSetup(renderer: renderer, brush: brush)
    }

    private static func rendererLibrary(
        device: any MTLDevice,
        root: URL
    ) throws -> any MTLLibrary {
        let shader = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/MetalRenderer/Shaders.metal"
            ),
            encoding: .utf8
        )
        let header = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/CShaderTypes/include/ShaderTypes.h"
            ),
            encoding: .utf8
        )
        return try device.makeLibrary(
            source: shader.replacingOccurrences(
                of: "#include \"ShaderTypes.h\"",
                with: header
            ),
            options: nil
        )
    }

    private static func sample(
        _ phase: StrokePhase,
        x: Float
    ) -> StrokeSample {
        .mouse(
            position: ScreenPoint(x: x, y: 32),
            timestamp: 0,
            phase: phase
        )
    }

    private static func predictedSample(x: Float) -> StrokeSample {
        StrokeSample(
            position: ScreenPoint(x: x, y: 32),
            pressure: 0.5,
            timestamp: TimeInterval(x),
            phase: .moved,
            source: .mouse,
            kind: .predicted
        )
    }

    private static func predictedBatch(
        after index: Int,
        count: Int
    ) -> [StrokeSample] {
        (1...count).map { offset in
            predictedSample(
                x: Float((index + offset) % 96) * 0.5
            )
        }
    }

    private static func unresolvedEstimatedSample(index: Int) -> StrokeSample {
        StrokeSample(
            position: ScreenPoint(
                x: Float(index % 96) * 0.5,
                y: 32
            ),
            pressure: 0.5,
            timestamp: TimeInterval(index),
            phase: .moved,
            source: .pencil,
            capabilities: [.pressure],
            estimationUpdateIndex: index,
            estimatedProperties: [.pressure],
            estimatedPropertiesExpectingUpdates: [.pressure]
        )
    }

    private static func estimatedUpdateSample(index: Int) -> StrokeSample {
        StrokeSample(
            position: ScreenPoint(
                x: Float(index % 96) * 0.5,
                y: 32
            ),
            pressure: 0.55,
            timestamp: TimeInterval(index),
            phase: .moved,
            source: .pencil,
            kind: .estimatedUpdate,
            capabilities: [.pressure],
            estimationUpdateIndex: index
        )
    }
}

private struct StabilizerProbeSamples {
    let began: WorldStrokeSample
    let right: WorldStrokeSample
    let up: WorldStrokeSample
    let left: WorldStrokeSample
    let down: WorldStrokeSample
}

private struct StageCGeneratorProbeSamples {
    let began: WorldStrokeSample
    let right: WorldStrokeSample
    let up: WorldStrokeSample
    let left: WorldStrokeSample
    let predicted: WorldStrokeSample
    let ended: WorldStrokeSample
}

private enum StageCProbeFootprint {
    case ellipse
    case chisel
    case translatedBounds
    case dualEllipse
}
