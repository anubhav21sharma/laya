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
    case directionCornerAllocations(total: UInt64)
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
        case let .directionCornerAllocations(total):
            "direction/corner path allocated \(total) times after warm-up"
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
            case "--direction-corner":
                try runDirectionCornerProbe(probe: probe)
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

    private static func runDirectionCornerProbe(
        probe: AllocatorProbe
    ) throws {
        var tracker = BrushDirectionTracker()
        var position = WorldPoint(x: 0, y: 0)
        tracker.begin(at: position)
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

            let update = tracker.update(to: position)
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
        let recipe = try BrushRecipe(
            id: BrushRecipeID(
                usesOffMainNativeInk
                    ? "builtin.native-ink"
                    : "brush.allocator-probe"
            ),
            replayMode: usesOffMainNativeInk ? .appendOnly : .replayTail,
            replayLimits: usesOffMainNativeInk
                ? nil
                : BrushRecipePolicy.replayTailLimits
        )
        let definition = try LegacyBrushRecipeAdapter.definition(
            from: recipe,
            displayName: recipe.id.rawValue
        )
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
