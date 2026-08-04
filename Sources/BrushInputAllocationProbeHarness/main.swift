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
        let firstAllocationEventIndex: Int?
        let lastAllocationEventIndex: Int?
    }

    private let lock = NSLock()
    private var authoritativeCPU: [UInt64] = []
    private var predictionCPU: [UInt64] = []
    private var estimatedCPU: [UInt64] = []
    private var batchPackaging: [UInt64] = []
    private var surfaceRecordPacking: [UInt64] = []
    private var surfaceMetalSubmission: [UInt64] = []
    private var surfaceTilePartition: [UInt64] = []
    private var surfaceTileLease: [UInt64] = []
    private var sparseSamplingAcquire: [UInt64] = []
    private var sparseSamplingPreflight: [UInt64] = []
    private var sparseSamplingMetalSubmission: [UInt64] = []
    private var sparseSamplingCompletion: [UInt64] = []
    private var sparseSamplingCompletionWait: [UInt64] = []
    private var strokeLifecycleCPU: [UInt64] = []

    init() {
        authoritativeCPU.reserveCapacity(256)
        predictionCPU.reserveCapacity(256)
        estimatedCPU.reserveCapacity(256)
        batchPackaging.reserveCapacity(512)
        surfaceRecordPacking.reserveCapacity(512)
        surfaceMetalSubmission.reserveCapacity(512)
        surfaceTilePartition.reserveCapacity(512)
        surfaceTileLease.reserveCapacity(512)
        sparseSamplingAcquire.reserveCapacity(1_024)
        sparseSamplingPreflight.reserveCapacity(1_024)
        sparseSamplingMetalSubmission.reserveCapacity(1_024)
        sparseSamplingCompletion.reserveCapacity(1_024)
        sparseSamplingCompletionWait.reserveCapacity(1_024)
        strokeLifecycleCPU.reserveCapacity(64)
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
        case .surfaceRecordPacking:
            surfaceRecordPacking.append(count)
        case .surfaceMetalSubmission:
            surfaceMetalSubmission.append(count)
        case .surfaceTilePartition:
            surfaceTilePartition.append(count)
        case .surfaceTileLease:
            surfaceTileLease.append(count)
        case .sparseSamplingAcquire:
            sparseSamplingAcquire.append(count)
        case .sparseSamplingPreflight:
            sparseSamplingPreflight.append(count)
        case .sparseSamplingMetalSubmission:
            sparseSamplingMetalSubmission.append(count)
        case .sparseSamplingCompletion:
            sparseSamplingCompletion.append(count)
        case .sparseSamplingCompletionWait:
            sparseSamplingCompletionWait.append(count)
        case .strokeLifecycleCPU:
            strokeLifecycleCPU.append(count)
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
        case .surfaceRecordPacking: surfaceRecordPacking
        case .surfaceMetalSubmission: surfaceMetalSubmission
        case .surfaceTilePartition: surfaceTilePartition
        case .surfaceTileLease: surfaceTileLease
        case .sparseSamplingAcquire: sparseSamplingAcquire
        case .sparseSamplingPreflight: sparseSamplingPreflight
        case .sparseSamplingMetalSubmission: sparseSamplingMetalSubmission
        case .sparseSamplingCompletion: sparseSamplingCompletion
        case .sparseSamplingCompletionWait: sparseSamplingCompletionWait
        case .strokeLifecycleCPU: strokeLifecycleCPU
        }
        let result = Snapshot(
            eventCount: counts.count,
            allocationCount: counts.reduce(0, +),
            maximumSingleEventCount: counts.max() ?? 0,
            firstHalfAllocationCount:
                counts.prefix(counts.count / 2).reduce(0, +),
            lastHalfAllocationCount:
                counts.suffix(counts.count / 2).reduce(0, +),
            firstAllocationEventIndex:
                counts.firstIndex(where: { $0 > 0 }),
            lastAllocationEventIndex:
                counts.lastIndex(where: { $0 > 0 })
        )
        lock.unlock()
        return result
    }

    func counts(
        for stage: StrokePreparationAllocationProbeStage
    ) -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return switch stage {
        case .authoritativeCPU: authoritativeCPU
        case .predictionCPU: predictionCPU
        case .estimatedCPU: estimatedCPU
        case .batchPackaging: batchPackaging
        case .surfaceRecordPacking: surfaceRecordPacking
        case .surfaceMetalSubmission: surfaceMetalSubmission
        case .surfaceTilePartition: surfaceTilePartition
        case .surfaceTileLease: surfaceTileLease
        case .sparseSamplingAcquire: sparseSamplingAcquire
        case .sparseSamplingPreflight: sparseSamplingPreflight
        case .sparseSamplingMetalSubmission: sparseSamplingMetalSubmission
        case .sparseSamplingCompletion: sparseSamplingCompletion
        case .sparseSamplingCompletionWait: sparseSamplingCompletionWait
        case .strokeLifecycleCPU: strokeLifecycleCPU
        }
    }

    func reset() {
        lock.lock()
        authoritativeCPU.removeAll(keepingCapacity: true)
        predictionCPU.removeAll(keepingCapacity: true)
        estimatedCPU.removeAll(keepingCapacity: true)
        batchPackaging.removeAll(keepingCapacity: true)
        surfaceRecordPacking.removeAll(keepingCapacity: true)
        surfaceMetalSubmission.removeAll(keepingCapacity: true)
        surfaceTilePartition.removeAll(keepingCapacity: true)
        surfaceTileLease.removeAll(keepingCapacity: true)
        sparseSamplingAcquire.removeAll(keepingCapacity: true)
        sparseSamplingPreflight.removeAll(keepingCapacity: true)
        sparseSamplingMetalSubmission.removeAll(keepingCapacity: true)
        sparseSamplingCompletion.removeAll(keepingCapacity: true)
        sparseSamplingCompletionWait.removeAll(keepingCapacity: true)
        strokeLifecycleCPU.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

private final class TenMinuteTraceAllocationMeasurements:
    @unchecked Sendable
{
    struct Snapshot {
        let firstHotEventCount: Int
        let firstHotAllocationCount: UInt64
        let lastHotEventCount: Int
        let lastHotAllocationCount: UInt64
        let firstLifecycleAllocationCount: UInt64
        let lastLifecycleAllocationCount: UInt64
        let maximumLifecycleEventCount: UInt64
    }

    private enum Window {
        case first
        case middle
        case last
    }

    private let lock = NSLock()
    private var window: Window = .middle
    private var firstHotEventCount = 0
    private var firstHotAllocationCount: UInt64 = 0
    private var lastHotEventCount = 0
    private var lastHotAllocationCount: UInt64 = 0
    private var firstLifecycleAllocationCount: UInt64 = 0
    private var lastLifecycleAllocationCount: UInt64 = 0
    private var maximumLifecycleEventCount: UInt64 = 0

    func selectWindow(
        batchStart: Int,
        batchEnd: Int,
        totalSampleCount: Int
    ) {
        let decileCount = totalSampleCount / 10
        lock.lock()
        if batchEnd <= decileCount {
            window = .first
        } else if batchStart >= totalSampleCount - decileCount {
            window = .last
        } else {
            window = .middle
        }
        lock.unlock()
    }

    func record(
        _ stage: StrokePreparationAllocationProbeStage,
        count: UInt64
    ) {
        lock.lock()
        defer { lock.unlock() }
        switch stage {
        case .surfaceMetalSubmission, .sparseSamplingMetalSubmission:
            // Driver allocator timing is diagnostic, not application work.
            return
        case .strokeLifecycleCPU:
            maximumLifecycleEventCount = max(
                maximumLifecycleEventCount,
                count
            )
            switch window {
            case .first:
                firstLifecycleAllocationCount &+= count
            case .last:
                lastLifecycleAllocationCount &+= count
            case .middle:
                break
            }
        case .authoritativeCPU, .predictionCPU, .estimatedCPU,
             .batchPackaging, .surfaceRecordPacking,
             .surfaceTilePartition, .surfaceTileLease,
             .sparseSamplingAcquire, .sparseSamplingPreflight,
             .sparseSamplingCompletion, .sparseSamplingCompletionWait:
            switch window {
            case .first:
                firstHotEventCount += 1
                firstHotAllocationCount &+= count
            case .last:
                lastHotEventCount += 1
                lastHotAllocationCount &+= count
            case .middle:
                break
            }
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let result = Snapshot(
            firstHotEventCount: firstHotEventCount,
            firstHotAllocationCount: firstHotAllocationCount,
            lastHotEventCount: lastHotEventCount,
            lastHotAllocationCount: lastHotAllocationCount,
            firstLifecycleAllocationCount: firstLifecycleAllocationCount,
            lastLifecycleAllocationCount: lastLifecycleAllocationCount,
            maximumLifecycleEventCount: maximumLifecycleEventCount
        )
        lock.unlock()
        return result
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
    case stageCEmissionCursorAllocations(total: UInt64)
    case stageCEmissionCursorIncomplete
    case stageCEmissionPageMismatch(
        firstCount: Int,
        firstHasMore: Bool,
        secondCount: Int,
        secondHasMore: Bool
    )
    case timedEmitterAllocations(normal: UInt64, hugeGap: UInt64)
    case timedEmitterMissingCursor
    case tipSupportSpacingAllocations(total: UInt64)
    case sensorProgramAllocations(total: UInt64)
    case offMainEstimatedAllocations(total: UInt64, maximum: UInt64)
    case offMainAllocationRegression(String)
    case sparseSamplingAllocationRegression(String)
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
        case let .stageCEmissionCursorAllocations(total):
            "paged Stage C emission allocated \(total) times after warm-up"
        case .stageCEmissionCursorIncomplete:
            "paged Stage C emission did not complete the bounded probe input"
        case let .stageCEmissionPageMismatch(
            firstCount,
            firstHasMore,
            secondCount,
            secondHasMore
        ):
            "paged Stage C boundary mismatch first=\(firstCount)/"
                + "\(firstHasMore) second=\(secondCount)/\(secondHasMore)"
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
        case let .sparseSamplingAllocationRegression(detail):
            "sparse sampling allocation regression: \(detail)"
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
            case "--stage-c-emission":
                try runStageCEmissionCursorProbe(probe: probe)
            case "--timed-emitter":
                try runTimedEmitterProbe(probe: probe)
            case "--tip-support-spacing":
                try runTipSupportSpacingProbe(probe: probe)
            case "--sensor-program":
                try runSensorProgramProbe(probe: probe)
            case "--stage-d-tiles":
                try await runStageDTileSurfaceProbe(
                    probe: probe,
                    root: root
                )
            case "--stage-d-sampling":
                try await runStageDSamplingProbe(
                    probe: probe,
                    root: root
                )
            case "--production":
                try await runProduction(probe: probe, root: root)
            case "--ten-minute-trace":
                try await runTenMinuteProductionTraceProbe(
                    probe: probe,
                    root: root
                )
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

    @MainActor
    private static func runStageDTileSurfaceProbe(
        probe: AllocatorProbe,
        root: URL
    ) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ProbeHarnessError.metalUnavailable
        }
        let measurements = ActorAllocationMeasurements()
        try await StrokeTileAllocationProbeHarness.run(
            device: device,
            library: rendererLibrary(device: device, root: root),
            probe: StrokePreparationAllocationProbe(
                identity: 0xD5,
                arm: { probe.arm() },
                disarm: { probe.disarm() },
                record: { stage, count in
                    measurements.record(stage, count: count)
                }
            )
        )
        let partition = measurements.snapshot(for: .surfaceTilePartition)
        let lease = measurements.snapshot(for: .surfaceTileLease)
        let metal = measurements.snapshot(for: .surfaceMetalSubmission)
        guard partition.eventCount >= 5,
              lease.eventCount >= 10,
              partition.allocationCount == 0,
              lease.allocationCount == 0
        else {
            throw ProbeHarnessError.offMainAllocationRegression(
                "Stage D tile partition=\(partition.eventCount)/"
                    + "\(partition.allocationCount) lease="
                    + "\(lease.eventCount)/\(lease.allocationCount) "
                    + "partition_series="
                    + "\(measurements.counts(for: .surfaceTilePartition)) "
                    + "lease_series="
                    + "\(measurements.counts(for: .surfaceTileLease))"
            )
        }
        print(
            "ALLOCATOR PROBE STAGE D TILES PASS partition="
                + "\(partition.eventCount)/0 lease="
                + "\(lease.eventCount)/0 metal_driver="
                + "\(metal.eventCount)/\(metal.allocationCount)"
        )
    }

    @MainActor
    private static func runStageDSamplingProbe(
        probe: AllocatorProbe,
        root: URL
    ) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ProbeHarnessError.metalUnavailable
        }
        let measurements = ActorAllocationMeasurements()
        let results = try await SparseTileSamplingAllocationProbeHarness.run(
            device: device,
            library: rendererLibrary(device: device, root: root),
            probe: StrokePreparationAllocationProbe(
                identity: 0xD6,
                arm: { probe.arm() },
                disarm: { probe.disarm() },
                record: { stage, count in
                    measurements.record(stage, count: count)
                }
            )
        )
        let acquire = measurements.snapshot(for: .sparseSamplingAcquire)
        let preflight = measurements.snapshot(for: .sparseSamplingPreflight)
        let submission = measurements.snapshot(
            for: .sparseSamplingMetalSubmission
        )
        let completion = measurements.snapshot(
            for: .sparseSamplingCompletion
        )
        let completionWait = measurements.snapshot(
            for: .sparseSamplingCompletionWait
        )
        let expectedEvents = results.reduce(0) {
            $0 + $1.measuredIterationCount
        }
        let exactEvents = acquire.eventCount == expectedEvents
            && preflight.eventCount == expectedEvents
            && submission.eventCount == expectedEvents
            && completion.eventCount == expectedEvents
            && completionWait.eventCount == expectedEvents
        let boundedApplicationAllocations =
            SparseTileSamplingAllocationCap.acquire.accepts(
                maximumObserved: acquire.maximumSingleEventCount,
                firstHalf: acquire.firstHalfAllocationCount,
                lastHalf: acquire.lastHalfAllocationCount
            )
            && SparseTileSamplingAllocationCap.preflight.accepts(
                maximumObserved: preflight.maximumSingleEventCount,
                firstHalf: preflight.firstHalfAllocationCount,
                lastHalf: preflight.lastHalfAllocationCount
            )
            && SparseTileSamplingAllocationCap.submission.accepts(
                maximumObserved: submission.maximumSingleEventCount,
                firstHalf: submission.firstHalfAllocationCount,
                lastHalf: submission.lastHalfAllocationCount
            )
            && SparseTileSamplingAllocationCap.completion.accepts(
                maximumObserved: completion.maximumSingleEventCount,
                firstHalf: completion.firstHalfAllocationCount,
                lastHalf: completion.lastHalfAllocationCount
            )
            && SparseTileSamplingAllocationCap.completionWait.accepts(
                maximumObserved: completionWait.maximumSingleEventCount,
                firstHalf: completionWait.firstHalfAllocationCount,
                lastHalf: completionWait.lastHalfAllocationCount
            )
        let resourcesAreStable = results.allSatisfy {
            $0.sourceTileCount == 17
                && ($0.backend == "directFallback" ? $0.drawCount > 1 : true)
                && $0.warmedPlanMetalBufferAllocationCount > 0
                && $0.warmedPlanMetalBufferAllocationCount
                    == $0.finalPlanMetalBufferAllocationCount
                && $0.warmedPlanMetalBufferAllocationBytes
                    == $0.finalPlanMetalBufferAllocationBytes
                && $0.warmedCachedPlanMetalBufferBytes
                    == $0.finalCachedPlanMetalBufferBytes
                && $0.warmedUploadMetalBufferAllocationCount > 0
                && $0.warmedUploadMetalBufferAllocationCount
                    == $0.finalUploadMetalBufferAllocationCount
                && $0.warmedUploadMetalBufferBytes
                    == $0.finalUploadMetalBufferBytes
                && $0.uploadCapacity == 3
                && $0.uploadHighWaterSlotCount == 3
                && $0.finalActiveUploadSlotCount == 0
                && $0.terminalCommandCount
                    == UInt64($0.measuredIterationCount)
                && $0.commandFailureCount == 0
                && $0.planCompletionFailureCount == 0
                && $0.pendingCompletionCount == 0
                && $0.finalSourceActiveLeaseCount == 0
        }
        guard !results.isEmpty,
              exactEvents,
              boundedApplicationAllocations,
              resourcesAreStable
        else {
            throw ProbeHarnessError.sparseSamplingAllocationRegression(
                "backends=\(results.map(\.backend)) expected=\(expectedEvents) "
                    + "checks=\(exactEvents)/"
                    + "\(boundedApplicationAllocations)/\(resourcesAreStable) "
                    + summary("acquire", acquire)
                    + summary("preflight", preflight)
                    + summary("submission", submission)
                    + summary("completion", completion)
                    + summary("wait", completionWait)
                    + "resources=\(results)"
            )
        }
        print(
            "ALLOCATOR PROBE STAGE D SAMPLING PASS backends="
                + "\(results.map(\.backend).joined(separator: ",")) "
                + "events=\(expectedEvents) app_acquire="
                + "\(acquire.allocationCount)/max"
                + "\(acquire.maximumSingleEventCount) app_preflight="
                + "\(preflight.allocationCount)/max"
                + "\(preflight.maximumSingleEventCount) app_completion="
                + "\(completion.allocationCount)/max"
                + "\(completion.maximumSingleEventCount) app_wait="
                + "\(completionWait.allocationCount)/max"
                + "\(completionWait.maximumSingleEventCount) metal_submission="
                + "\(submission.allocationCount)/max"
                + "\(submission.maximumSingleEventCount)"
                + " plan_bytes=\(results.map(\.finalCachedPlanMetalBufferBytes))"
                + " upload_bytes=\(results.map(\.finalUploadMetalBufferBytes))"
                + " draws=\(results.map(\.drawCount))"
        )
    }

    private static func summary(
        _ name: String,
        _ snapshot: ActorAllocationMeasurements.Snapshot
    ) -> String {
        "\(name)=\(snapshot.eventCount)/max"
            + "\(snapshot.maximumSingleEventCount)/halves"
            + "\(snapshot.firstHalfAllocationCount)-"
            + "\(snapshot.lastHalfAllocationCount) "
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
        footprint: StageCProbeFootprint = .ellipse,
        usesDirectionOutput: Bool = true,
        emission: BrushEmissionDefinition = BrushEmissionDefinition(
            mode: .distance,
            timeInterval: nil
        )
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
        if usesDirectionOutput {
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
        }
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
            emission: emission,
            tipSupports: tipSupports
        )
    }

    private static func runStageCEmissionCursorProbe(
        probe: AllocatorProbe
    ) throws {
        let unionProgram = try BrushProgramCompiler.compile(
            makeStageCProbeDefinition(
                id: "probe.stage-c.emission.union",
                stabilization: .none,
                maximumAngularStep: .pi / 8,
                emission: BrushEmissionDefinition(
                    mode: .distanceAndTime,
                    timeInterval: 0.25
                )
            )
        )
        let timedProgram = try BrushProgramCompiler.compile(
            makeStageCProbeDefinition(
                id: "probe.stage-c.emission.time",
                stabilization: .none,
                maximumAngularStep: .pi / 8,
                usesDirectionOutput: false,
                emission: BrushEmissionDefinition(
                    mode: .time,
                    timeInterval: 1.0 / 240
                )
            )
        )
        let samples = makeStageCEmissionProbeSamples()
        _ = try runStageCEmissionCursorScenarios(
            unionProgram: unionProgram,
            timedProgram: timedProgram,
            samples: samples
        )

        probe.arm()
        let checksum: UInt64
        do {
            checksum = try runStageCEmissionCursorScenarios(
                unionProgram: unionProgram,
                timedProgram: timedProgram,
                samples: samples
            )
        } catch {
            _ = probe.disarm()
            throw error
        }
        let allocations = probe.disarm()
        guard allocations == 0 else {
            throw ProbeHarnessError.stageCEmissionCursorAllocations(
                total: allocations
            )
        }
        print(
            "ALLOCATOR PROBE STAGE C EMISSION PASS allocations=0 "
                + "checksum=\(checksum)"
        )
    }

    @inline(never)
    private static func runStageCEmissionCursorScenarios(
        unionProgram: BrushProgram,
        timedProgram: BrushProgram,
        samples: StageCEmissionProbeSamples
    ) throws -> UInt64 {
        var checksum: UInt64 = 0
        var union = BrushStrokeGenerator(
            program: unionProgram,
            nominalDiameter: 20,
            color: .black,
            seed: 0xC1_11_A1
        )
        try drainStageCEmissionInput(
            generator: &union,
            sample: samples.began,
            checksum: &checksum
        )
        try drainStageCEmissionInput(
            generator: &union,
            sample: samples.right,
            checksum: &checksum
        )
        try drainStageCEmissionInput(
            generator: &union,
            sample: samples.up,
            checksum: &checksum
        )
        try drainStageCEmissionInput(
            generator: &union,
            sample: samples.ended,
            checksum: &checksum
        )

        var boundary = BrushStrokeGenerator(
            program: timedProgram,
            nominalDiameter: 20,
            color: .black,
            seed: 0xC1_11_A2
        )
        var begin = try boundary.emissionCursor(
            for: samples.began,
            maximumPathSubdivisionCount: 4_096
        )
        _ = try begin.emitNextPage { checksum &+= $0.ordinal }
        guard let boundaryContinuation = begin.completedGenerator else {
            throw ProbeHarnessError.stageCEmissionCursorIncomplete
        }
        boundary = boundaryContinuation
        var pageCursor = try boundary.emissionCursor(
            for: samples.boundaryEnded,
            maximumPathSubdivisionCount: 4_096
        )
        let first = try pageCursor.emitNextPage { checksum &+= $0.ordinal }
        let second = try pageCursor.emitNextPage { checksum &+= $0.ordinal }
        guard first.emittedCount == 512,
              first.hasMore,
              second.emittedCount == 1,
              !second.hasMore
        else {
            throw ProbeHarnessError.stageCEmissionPageMismatch(
                firstCount: first.emittedCount,
                firstHasMore: first.hasMore,
                secondCount: second.emittedCount,
                secondHasMore: second.hasMore
            )
        }

        var huge = BrushStrokeGenerator(
            program: timedProgram,
            nominalDiameter: 20,
            color: .black,
            seed: 0xC1_11_A3
        )
        var hugeBegin = try huge.emissionCursor(
            for: samples.began,
            maximumPathSubdivisionCount: 4_096
        )
        _ = try hugeBegin.emitNextPage { checksum &+= $0.ordinal }
        guard let hugeContinuation = hugeBegin.completedGenerator else {
            throw ProbeHarnessError.stageCEmissionCursorIncomplete
        }
        huge = hugeContinuation
        var hugeCursor = try huge.emissionCursor(
            for: samples.hugeEnded,
            maximumPathSubdivisionCount: 4_096
        )
        let hugePage = try hugeCursor.emitNextPage {
            checksum &+= $0.ordinal
        }
        guard hugePage.emittedCount == 512, hugePage.hasMore else {
            throw ProbeHarnessError.stageCEmissionPageMismatch(
                firstCount: hugePage.emittedCount,
                firstHasMore: hugePage.hasMore,
                secondCount: 0,
                secondHasMore: false
            )
        }
        return checksum
    }

    @inline(__always)
    private static func drainStageCEmissionInput(
        generator: inout BrushStrokeGenerator,
        sample: WorldStrokeSample,
        checksum: inout UInt64
    ) throws {
        var cursor = try generator.emissionCursor(
            for: sample,
            maximumPathSubdivisionCount: 4_096
        )
        repeat {
            _ = try cursor.emitNextPage { dab in
                checksum &+= dab.ordinal
                checksum &+= UInt64(dab.rotation.bitPattern)
            }
        } while !cursor.isComplete
        guard let continuation = cursor.completedGenerator else {
            throw ProbeHarnessError.stageCEmissionCursorIncomplete
        }
        generator = continuation
    }

    private static func makeStageCEmissionProbeSamples()
        -> StageCEmissionProbeSamples
    {
        let viewport = ViewportTransform(
            drawableSize: PatternSize(width: 256, height: 256),
            worldCenter: WorldPoint(x: 128, y: 128)
        )
        func sample(
            x: Float,
            y: Float,
            timestamp: TimeInterval,
            phase: StrokePhase
        ) -> WorldStrokeSample {
            var deriver = BrushInputDeriver()
            return deriver.derive(
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
        return StageCEmissionProbeSamples(
            began: sample(x: 64, y: 64, timestamp: 0, phase: .began),
            right: sample(x: 112, y: 64, timestamp: 0.5, phase: .moved),
            up: sample(x: 112, y: 16, timestamp: 1, phase: .moved),
            ended: sample(x: 64, y: 16, timestamp: 1.5, phase: .ended),
            boundaryEnded: sample(
                x: 64,
                y: 64,
                timestamp: 513.0 / 240,
                phase: .ended
            ),
            hugeEnded: sample(
                x: 64,
                y: 64,
                timestamp: 1_000_000,
                phase: .ended
            )
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
        try await runTenMinuteProductionTraceProbe(
            probe: probe,
            root: root
        )
        print(
            "ALLOCATOR PROBE PRODUCTION PASS allocations=\(allocationCount)"
        )
    }

    @MainActor
    private static func runTenMinuteProductionTraceProbe(
        probe: AllocatorProbe,
        root: URL
    ) async throws {
        let totalSampleCount = 36_000
        let batchSize = 60
        let maximumZeroWorkLeaseCount =
            (totalSampleCount + batchSize - 1) / batchSize + 1
        let setup = try await makeRendererSetup(
            root: root,
            usesOffMainNativeInk: true
        )
        let measurements = TenMinuteTraceAllocationMeasurements()
        let allocationProbe = StrokePreparationAllocationProbe(
            identity: 3,
            arm: { probe.arm() },
            disarm: { probe.disarm() },
            record: { stage, count in
                measurements.record(stage, count: count)
            }
        )
        let trace = try await setup.renderer
            .runOffMainProductionTraceForTesting(
                compiledBrush: setup.brush,
                totalSampleCount: totalSampleCount,
                batchSize: batchSize,
                allocationProbe: allocationProbe,
                batchWillSubmit: { batchStart, batchEnd in
                    measurements.selectWindow(
                        batchStart: batchStart,
                        batchEnd: batchEnd,
                        totalSampleCount: totalSampleCount
                    )
                }
            )
        let allocations = measurements.snapshot()
        guard allocations.firstHotEventCount > 0,
              allocations.lastHotEventCount > 0,
              allocations.firstHotAllocationCount <= 64,
              allocations.lastHotAllocationCount
                <= allocations.firstHotAllocationCount,
              allocations.maximumLifecycleEventCount <= 64,
              allocations.lastLifecycleAllocationCount
                <= allocations.firstLifecycleAllocationCount + 8
        else {
            throw ProbeHarnessError.offMainAllocationRegression(
                "ten-minute trace allocations hot="
                    + "\(allocations.firstHotAllocationCount)/"
                    + "\(allocations.lastHotAllocationCount) events="
                    + "\(allocations.firstHotEventCount)/"
                    + "\(allocations.lastHotEventCount) lifecycle="
                    + "\(allocations.firstLifecycleAllocationCount)/"
                    + "\(allocations.lastLifecycleAllocationCount) max="
                    + "\(allocations.maximumLifecycleEventCount)/64"
            )
        }
        guard trace.inputSampleCount == totalSampleCount,
              trace.logicalDurationNanoseconds == 599_999_976_000,
              trace.authoritativeInputHighWater <= 60,
              trace.authoritativeInputCapacity == 12_288,
              trace.authoritativeInputStorageCapacity
                == trace.authoritativeInputInitialStorageCapacity,
              trace.predictionInputCapacity == 64,
              trace.predictionInputStorageCapacity
                == trace.predictionInputInitialStorageCapacity,
              trace.resultHighWater == 1,
              trace.resultCapacity == 1,
              trace.resultStorageCapacity
                == trace.resultInitialStorageCapacity,
              trace.workspaceInstallationCount
                == trace.workspaceInitialInstallationCount,
              trace.workspaceIdentityStayedStable,
              trace.maximumPreparedPayloadBytes > 0,
              trace.surface.surfaceCount == 2,
              trace.surface.surfaceLeaseHighWater == 1,
              trace.surface.encodedFrameCount > 0,
              trace.surface.encodedInstanceCount > 0,
              trace.zeroWorkLeaseCount <= maximumZeroWorkLeaseCount,
              trace.missedLogicalFrameCount == 0,
              trace.allPreparationAndEncodingOffMain,
              trace.lastDecileNanosecondsPerEvent
                <= max(
                    trace.firstDecileNanosecondsPerEvent * 2,
                    trace.firstDecileNanosecondsPerEvent + 100_000
                )
        else {
            throw ProbeHarnessError.offMainAllocationRegression(
                "ten-minute production trace invariant failed "
                    + "samples=\(trace.inputSampleCount)/\(totalSampleCount) "
                    + "logical=\(trace.logicalDurationNanoseconds) "
                    + "authoritative=\(trace.authoritativeInputHighWater)/"
                    + "\(trace.authoritativeInputCapacity) storage="
                    + "\(trace.authoritativeInputInitialStorageCapacity)/"
                    + "\(trace.authoritativeInputStorageCapacity) prediction="
                    + "\(trace.predictionInputCapacity) storage="
                    + "\(trace.predictionInputInitialStorageCapacity)/"
                    + "\(trace.predictionInputStorageCapacity) result="
                    + "\(trace.resultHighWater)/\(trace.resultCapacity) storage="
                    + "\(trace.resultInitialStorageCapacity)/"
                    + "\(trace.resultStorageCapacity) workspace="
                    + "\(trace.workspaceInitialInstallationCount)/"
                    + "\(trace.workspaceInstallationCount)/"
                    + "\(trace.workspaceIdentityStayedStable) payload="
                    + "\(trace.maximumPreparedPayloadBytes) surface="
                    + "\(trace.surface.surfaceCount)/"
                    + "\(trace.surface.surfaceLeaseHighWater)/"
                    + "\(trace.surface.encodedFrameCount)/"
                    + "\(trace.surface.encodedInstanceCount) zero="
                    + "\(trace.zeroWorkLeaseCount) missed="
                    + "\(trace.missedLogicalFrameCount) offMain="
                    + "\(trace.allPreparationAndEncodingOffMain) cpu="
                    + "\(trace.firstDecileNanosecondsPerEvent)/"
                    + "\(trace.lastDecileNanosecondsPerEvent)"
            )
        }
        let hotSummary = "\(allocations.firstHotAllocationCount)/"
            + "\(allocations.lastHotAllocationCount)"
        let lifecycleSummary =
            "\(allocations.firstLifecycleAllocationCount)/"
                + "\(allocations.lastLifecycleAllocationCount)"
        let cpuSummary = "\(trace.firstDecileNanosecondsPerEvent)/"
            + "\(trace.lastDecileNanosecondsPerEvent)"
        print(
            "ALLOCATOR PROBE TEN-MINUTE TRACE PASS "
                + "samples=\(trace.inputSampleCount) "
                + "hot_allocations=\(hotSummary) "
                + "lifecycle=\(lifecycleSummary) cpu_ns=\(cpuSummary) "
                + "missed=\(trace.missedLogicalFrameCount) "
                + "zero_work=\(trace.zeroWorkLeaseCount)/"
                + "\(maximumZeroWorkLeaseCount) "
                + "deferred=\(trace.deferredDrainCount)"
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
        let surfacePacking = measurements.snapshot(for: .surfaceRecordPacking)
        let surfaceMetal = measurements.snapshot(for: .surfaceMetalSubmission)
        let surfaceTilePartition = measurements.snapshot(
            for: .surfaceTilePartition
        )
        let surfaceTileLease = measurements.snapshot(for: .surfaceTileLease)
        let stageCMetrics = await renderer
            .offMainStageCContinuationMetricsForAllocationHarness()
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
                + "surface_pack=\(surfacePacking.allocationCount)/"
                + "\(surfacePacking.maximumSingleEventCount) "
                + "surface_metal=\(surfaceMetal.allocationCount)/"
                + "\(surfaceMetal.firstHalfAllocationCount)/"
                + "\(surfaceMetal.lastHalfAllocationCount)/"
                + "\(surfaceMetal.maximumSingleEventCount) "
                + "tile_partition=\(surfaceTilePartition.eventCount)/"
                + "\(surfaceTilePartition.allocationCount) "
                + "tile_lease=\(surfaceTileLease.eventCount)/"
                + "\(surfaceTileLease.allocationCount)"
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
            guard snapshot.eventCount >= expectedCount,
                  snapshot.allocationCount == 0
            else {
                throw ProbeHarnessError.offMainAllocationRegression(
                    "\(name) events=\(snapshot.eventCount)/\(expectedCount) "
                        + "first=\(snapshot.firstHalfAllocationCount) "
                        + "last=\(snapshot.lastHalfAllocationCount) "
                        + "max=\(snapshot.maximumSingleEventCount) "
                        + "firstEvent="
                        + "\(String(describing: snapshot.firstAllocationEventIndex)) "
                        + "lastEvent="
                        + "\(String(describing: snapshot.lastAllocationEventIndex)) "
                        + Self.allocationIncidentSummary(stageCMetrics)
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
        guard surfacePacking.eventCount >= measuredEventCount
                + measuredPredictionEventCount,
              surfacePacking.allocationCount == 0
        else {
            throw ProbeHarnessError.offMainAllocationRegression(
                "surface packing events=\(surfacePacking.eventCount) "
                    + "allocations=\(surfacePacking.allocationCount) "
                    + "max=\(surfacePacking.maximumSingleEventCount)"
            )
        }
        guard surfaceMetal.eventCount >= measuredEventCount
                + measuredPredictionEventCount,
              surfaceMetal.lastHalfAllocationCount
                <= surfaceMetal.firstHalfAllocationCount,
              surfaceMetal.maximumSingleEventCount <= 64
        else {
            throw ProbeHarnessError.offMainAllocationRegression(
                "surface Metal events=\(surfaceMetal.eventCount) "
                    + "first=\(surfaceMetal.firstHalfAllocationCount) "
                    + "last=\(surfaceMetal.lastHalfAllocationCount) "
                    + "max=\(surfaceMetal.maximumSingleEventCount)/64"
            )
        }
        let tiledExpectedEventCount = measuredEventCount
            + measuredPredictionEventCount
        guard (surfaceTilePartition.eventCount == 0
                && surfaceTileLease.eventCount == 0)
                || (surfaceTilePartition.eventCount >= tiledExpectedEventCount
                    && surfaceTileLease.eventCount >= tiledExpectedEventCount
                    && surfaceTilePartition.allocationCount == 0
                    && surfaceTileLease.allocationCount == 0)
        else {
            throw ProbeHarnessError.offMainAllocationRegression(
                "tiled surface partition="
                    + "\(surfaceTilePartition.eventCount)/"
                    + "\(surfaceTilePartition.allocationCount) lease="
                    + "\(surfaceTileLease.eventCount)/"
                    + "\(surfaceTileLease.allocationCount)"
            )
        }
        print(
            "ALLOCATOR PROBE OFF-MAIN PASS application=0 workspace=0 "
                + "main=0 "
                + "authoritative=\(authoritative.allocationCount) "
                + "estimated=\(estimated.allocationCount) "
                + "prediction=\(prediction.allocationCount) "
                + "packaging=\(packaging.allocationCount) "
                + "surface_pack=0 "
                + "surface_metal_mallocs=\(surfaceMetal.allocationCount) "
                + "tile_partition=\(surfaceTilePartition.allocationCount) "
                + "tile_lease=\(surfaceTileLease.allocationCount)"
        )
        try await runOffMainStageCContinuationProbe(
            probe: probe,
            root: root
        )
    }

    @MainActor
    private static func runOffMainStageCContinuationProbe(
        probe: AllocatorProbe,
        root: URL
    ) async throws {
        try await runOffMainStageCContinuationFixture(
            probe: probe,
            root: root,
            label: "periodic",
            finiteConfiguration: nil,
            projectionMultiplicity: 4,
            minimumEmittedDabCount: 512
        )
        try await runOffMainStageCContinuationFixture(
            probe: probe,
            root: root,
            label: "radial-32",
            finiteConfiguration: .radial(
                RadialSymmetryConfiguration(
                    kind: .mandala,
                    rayCount: 32,
                    center: WorldPoint(x: 32, y: 32)
                )
            ),
            projectionMultiplicity: 32,
            minimumEmittedDabCount: 128
        )
    }

    @MainActor
    private static func runOffMainStageCContinuationFixture(
        probe: AllocatorProbe,
        root: URL,
        label: String,
        finiteConfiguration: FiniteSymmetryConfiguration?,
        projectionMultiplicity: UInt64,
        minimumEmittedDabCount: UInt64
    ) async throws {
        let setup = try await makeRendererSetup(
            root: root,
            usesOffMainNativeInk: true,
            finiteConfiguration: finiteConfiguration
        )
        let renderer = setup.renderer
        let measurements = ActorAllocationMeasurements()
        renderer.setStrokePreparationAllocationProbeForHarness(
            StrokePreparationAllocationProbe(
                identity: 2,
                arm: { probe.arm() },
                disarm: { probe.disarm() },
                record: { stage, count in
                    measurements.record(stage, count: count)
                }
            )
        )
        let style = StrokeRenderStyle(
            color: .black,
            diameter: 20,
            compositeMode: .draw,
            eraserStrength: 1,
            program: setup.brush.program,
            renderIdentity: setup.brush.renderIdentity,
            seed: 0xC1_20
        )
        // Cross both the logical-dab and projected-instance replay-tail
        // limits so the production settled-prefix transfer performs work.
        let continuationTraceDistance: Float = 2_560

        // Exercise every continuation phase once before measuring so arena,
        // queue, projection and private-surface storage are all at steady
        // capacity. The second trace uses the same distance and route.
        let warmToken = RendererOperationToken(rawValue: 3)
        try renderer.beginStroke(
            token: warmToken,
            sample: sample(.began, x: 0),
            style: style
        )
        try await drainToQuiescence(renderer: renderer)
        try renderer.appendStroke(
            token: warmToken,
            sample: sample(.moved, x: continuationTraceDistance)
        )
        try await drainToQuiescence(renderer: renderer)
        try renderer.finishStrokeTransient(
            token: warmToken,
            sample: sample(.ended, x: continuationTraceDistance)
        )
        try await drainToQuiescence(renderer: renderer)
        try renderer.cancelStroke(token: warmToken)
        try await drainToQuiescence(renderer: renderer)

        // Multiple identical measured strokes ensure warm-up did not merely
        // move an allocation into the first post-warm lifecycle.
        let measuredLifecycleCount = 8
        var mainLifecycleSeries: [UInt64] = []
        var actorLifecycleSeries: [UInt64] = []
        mainLifecycleSeries.reserveCapacity(measuredLifecycleCount)
        actorLifecycleSeries.reserveCapacity(measuredLifecycleCount)
        for iteration in 0..<measuredLifecycleCount {
        let measuredToken = RendererOperationToken(
            rawValue: UInt64(4 + iteration)
        )
        measurements.reset()
        var mainLifecycleAllocations: UInt64 = 0
        probe.arm()
        do {
            try renderer.beginStroke(
                token: measuredToken,
                sample: sample(.began, x: 0),
                style: style
            )
        } catch {
            _ = probe.disarm()
            throw error
        }
        mainLifecycleAllocations += probe.disarm()
        try await drainToQuiescence(renderer: renderer)
        let metricsBefore = await renderer
            .offMainStageCContinuationMetricsForAllocationHarness()
        let authoritativeBefore = measurements.snapshot(for: .authoritativeCPU)
        probe.arm()
        do {
            try renderer.appendStroke(
                token: measuredToken,
                sample: sample(.moved, x: continuationTraceDistance)
            )
        } catch {
            _ = probe.disarm()
            throw error
        }
        let mainHotEnqueueAllocations = probe.disarm()
        try await drainToQuiescence(renderer: renderer)
        let metricsAfter = await renderer
            .offMainStageCContinuationMetricsForAllocationHarness()
        let authoritativeAfter = measurements.snapshot(for: .authoritativeCPU)
        probe.arm()
        do {
            try renderer.finishStrokeTransient(
                token: measuredToken,
                sample: sample(.ended, x: continuationTraceDistance)
            )
        } catch {
            _ = probe.disarm()
            throw error
        }
        mainLifecycleAllocations += probe.disarm()
        try await drainToQuiescence(renderer: renderer)
        let metricsAfterFinish = await renderer
            .offMainStageCContinuationMetricsForAllocationHarness()
        let emittedDabDelta = metricsAfter.emittedAuthoritativeDabCount
            - metricsBefore.emittedAuthoritativeDabCount
        let pageDelta = metricsAfter.pageCount - metricsBefore.pageCount
        let resumeDelta = metricsAfter.resumeCount - metricsBefore.resumeCount
        let settledTransferWork =
            metricsAfter.settledTransferWorkUnitCount
                - metricsBefore.settledTransferWorkUnitCount
        let authoritativeEventDelta = authoritativeAfter.eventCount
            - authoritativeBefore.eventCount
        let logicalWorkPages =
            (emittedDabDelta + UInt64(LogicalDabBatch.maximumDabCount - 1))
                / UInt64(LogicalDabBatch.maximumDabCount)
        let projectedWork = emittedDabDelta * projectionMultiplicity
        let projectionWorkPages =
            (projectedWork + 4_095) / 4_096
        // Candidate emission, transient storage and arena commit can each
        // consume one 512-work page; projection has its own 4,096-instance
        // ceiling. Sixteen bounds the fixed phase transitions and final ACK.
        let maximumContinuationEventCount =
            logicalWorkPages * 3 + projectionWorkPages + 16

        probe.arm()
        do {
            try renderer.cancelStroke(token: measuredToken)
        } catch {
            _ = probe.disarm()
            throw error
        }
        mainLifecycleAllocations += probe.disarm()
        try await drainToQuiescence(renderer: renderer)
        let authoritative = measurements.snapshot(for: .authoritativeCPU)
        let packaging = measurements.snapshot(for: .batchPackaging)
        let surfacePacking = measurements.snapshot(for: .surfaceRecordPacking)
        let surfaceMetal = measurements.snapshot(for: .surfaceMetalSubmission)
        let surfaceTilePartition = measurements.snapshot(
            for: .surfaceTilePartition
        )
        let surfaceTileLease = measurements.snapshot(for: .surfaceTileLease)
        let lifecycle = measurements.snapshot(for: .strokeLifecycleCPU)

        guard mainHotEnqueueAllocations == 0,
              authoritative.eventCount > 1,
              authoritative.allocationCount == 0,
              UInt64(authoritative.eventCount)
                <= maximumContinuationEventCount
        else {
            throw ProbeHarnessError.offMainAllocationRegression(
                "Stage C continuation authoritative events="
                    + "\(authoritative.eventCount) allocations="
                    + "\(authoritative.allocationCount) max="
                    + "\(authoritative.maximumSingleEventCount) firstEvent="
                    + "\(String(describing: authoritative.firstAllocationEventIndex)) "
                    + "lastEvent="
                    + "\(String(describing: authoritative.lastAllocationEventIndex)) "
                    + "mainHot=\(mainHotEnqueueAllocations) "
                    + "ceiling=\(maximumContinuationEventCount) "
                    + Self.allocationIncidentSummary(metricsAfter)
            )
        }
        guard metricsAfter.pageCount > metricsBefore.pageCount + 1,
              metricsAfter.resumeCount > metricsBefore.resumeCount + 1,
              metricsAfter.logicalPageHighWater > 0,
              metricsAfter.logicalPageHighWater
                <= LogicalDabBatch.maximumDabCount,
              emittedDabDelta > minimumEmittedDabCount,
              pageDelta == resumeDelta,
              pageDelta == UInt64(authoritativeEventDelta),
              pageDelta <= maximumContinuationEventCount,
              resumeDelta <= maximumContinuationEventCount,
              settledTransferWork > 0,
              metricsAfterFinish.phaseHits.isSuperset(of: .fullLifecycle)
        else {
            let pageSummary = "\(metricsBefore.pageCount)->"
                + "\(metricsAfter.pageCount)"
            let resumeSummary = "\(metricsBefore.resumeCount)->"
                + "\(metricsAfter.resumeCount)"
            let dabSummary =
                "\(metricsBefore.emittedAuthoritativeDabCount)->"
                    + "\(metricsAfter.emittedAuthoritativeDabCount)"
            throw ProbeHarnessError.offMainAllocationRegression(
                "Stage C fixture did not exceed its candidate threshold: pages="
                    + pageSummary + " label=" + label + " resumes="
                    + resumeSummary
                    + " logicalHighWater="
                    + "\(metricsAfter.logicalPageHighWater) dabs="
                    + dabSummary + " eventCeiling="
                    + "\(maximumContinuationEventCount) phases=0x"
                    + String(metricsAfterFinish.phaseHits.rawValue, radix: 16)
                    + " settledWork=\(settledTransferWork) "
                    + "authoritativeEventDelta=\(authoritativeEventDelta)"
            )
        }
        guard packaging.eventCount >= authoritative.eventCount,
              packaging.allocationCount == 0
        else {
            throw ProbeHarnessError.offMainAllocationRegression(
                "Stage C continuation packaging events="
                    + "\(packaging.eventCount)/\(authoritative.eventCount) "
                    + "allocations=\(packaging.allocationCount)"
            )
        }
        guard surfacePacking.eventCount > 0,
              surfacePacking.eventCount <= packaging.eventCount,
              surfacePacking.allocationCount == 0
        else {
            throw ProbeHarnessError.offMainAllocationRegression(
                "Stage C continuation surface packing events="
                    + "\(surfacePacking.eventCount)/"
                    + "\(authoritative.eventCount) allocations="
                    + "\(surfacePacking.allocationCount) max="
                    + "\(surfacePacking.maximumSingleEventCount)"
            )
        }
        guard surfaceMetal.eventCount > 0,
              surfaceMetal.eventCount <= packaging.eventCount,
              surfaceMetal.lastHalfAllocationCount
                <= surfaceMetal.firstHalfAllocationCount,
              surfaceMetal.maximumSingleEventCount <= 64
        else {
            throw ProbeHarnessError.offMainAllocationRegression(
                "Stage C continuation surface Metal events="
                    + "\(surfaceMetal.eventCount)/"
                    + "\(authoritative.eventCount) first="
                    + "\(surfaceMetal.firstHalfAllocationCount) last="
                    + "\(surfaceMetal.lastHalfAllocationCount) max="
                    + "\(surfaceMetal.maximumSingleEventCount)/64"
            )
        }
        guard (surfaceTilePartition.eventCount == 0
                && surfaceTileLease.eventCount == 0)
                || (surfaceTilePartition.eventCount > 0
                    && surfaceTilePartition.eventCount
                        <= packaging.eventCount
                    && surfaceTileLease.eventCount > 0
                    && surfaceTileLease.eventCount <= packaging.eventCount
                    && surfaceTilePartition.allocationCount == 0
                    && surfaceTileLease.allocationCount == 0)
        else {
            throw ProbeHarnessError.offMainAllocationRegression(
                "Stage D tiled continuation partition="
                    + "\(surfaceTilePartition.eventCount)/"
                    + "\(surfaceTilePartition.allocationCount) lease="
                    + "\(surfaceTileLease.eventCount)/"
                    + "\(surfaceTileLease.allocationCount)"
            )
        }
        guard lifecycle.eventCount == 2,
              lifecycle.maximumSingleEventCount <= 64,
              mainLifecycleAllocations <= 512,
              renderer.offMainStrokeWorkspaceIsAvailableForAllocationHarness
        else {
            throw ProbeHarnessError.offMainAllocationRegression(
                "Stage C lifecycle events=\(lifecycle.eventCount)/2 "
                    + "actorTotal=\(lifecycle.allocationCount) actorMax="
                    + "\(lifecycle.maximumSingleEventCount)/64 mainTotal="
                    + "\(mainLifecycleAllocations)/512 workspaceAvailable="
                    + "\(renderer.offMainStrokeWorkspaceIsAvailableForAllocationHarness)"
            )
        }
        mainLifecycleSeries.append(mainLifecycleAllocations)
        actorLifecycleSeries.append(lifecycle.allocationCount)
        print(
            "ALLOCATOR PROBE STAGE C CONTINUATION PASS events="
                + "\(authoritative.eventCount) label=\(label) "
                + "authoritative=0 packaging=0 "
                + "main_hot=0 main_lifecycle="
                + "\(mainLifecycleAllocations) actor_lifecycle="
                + "\(lifecycle.allocationCount)/"
                + "\(lifecycle.maximumSingleEventCount) "
                + "surface_pack=0 surface_metal_mallocs="
                + "\(surfaceMetal.allocationCount) tile_partition="
                + "\(surfaceTilePartition.allocationCount) tile_lease="
                + "\(surfaceTileLease.allocationCount)"
        )
        }
        let mainFirstHalf = mainLifecycleSeries
            .prefix(measuredLifecycleCount / 2).reduce(0, +)
        let mainLastHalf = mainLifecycleSeries
            .suffix(measuredLifecycleCount / 2).reduce(0, +)
        let actorFirstHalf = actorLifecycleSeries
            .prefix(measuredLifecycleCount / 2).reduce(0, +)
        let actorLastHalf = actorLifecycleSeries
            .suffix(measuredLifecycleCount / 2).reduce(0, +)
        guard mainLastHalf <= mainFirstHalf + 8,
              actorLastHalf <= actorFirstHalf + 8
        else {
            throw ProbeHarnessError.offMainAllocationRegression(
                "Stage C lifecycle allocation growth label=\(label) main="
                    + "\(mainFirstHalf)->\(mainLastHalf) actor="
                    + "\(actorFirstHalf)->\(actorLastHalf)"
            )
        }
        print(
            "ALLOCATOR PROBE STAGE C LIFECYCLE STABLE label=\(label) "
                + "runs=\(measuredLifecycleCount) main="
                + "\(mainFirstHalf)/\(mainLastHalf) actor="
                + "\(actorFirstHalf)/\(actorLastHalf)"
        )
    }

    @MainActor
    private static func drainToQuiescence(
        renderer: GridRenderer
    ) async throws {
        for _ in 0..<20_000 {
            if renderer.strokePreparationIsQuiescentForAllocationHarness {
                return
            }
            try renderer.advanceStrokePreparationForAllocationHarness()
            await Task.yield()
        }
        throw ProbeHarnessError.offMainAllocationRegression(
            "Stage C continuation failed to reach quiescence"
        )
    }

    private static func allocationIncidentSummary(
        _ metrics: StrokeStageCContinuationMetrics
    ) -> String {
        func describe(
            _ incident: StrokeStageCAuthoritativeAllocationIncident?
        ) -> String {
            guard let incident else { return "none" }
            return "event=\(incident.eventOrdinal),count="
                + "\(incident.allocationCount),phase="
                + "\(String(describing: incident.phase)),sample="
                + "\(String(describing: incident.sampleIndex)),page="
                + "\(String(describing: incident.pageIndex)),work="
                + "\(String(describing: incident.workUnits))"
        }
        return "stageCIncidents[first=\(describe(metrics.firstAllocationIncident));"
            + "last=\(describe(metrics.lastAllocationIncident))]"
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
        usesOffMainNativeInk: Bool = false,
        finiteConfiguration: FiniteSymmetryConfiguration? = nil
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
        if let finiteConfiguration {
            try renderer.applyFiniteConfiguration(finiteConfiguration)
        } else {
            try renderer.applyTiling(.squareRotation)
        }
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

private struct StageCEmissionProbeSamples {
    let began: WorldStrokeSample
    let right: WorldStrokeSample
    let up: WorldStrokeSample
    let ended: WorldStrokeSample
    let boundaryEnded: WorldStrokeSample
    let hugeEnded: WorldStrokeSample
}

private enum StageCProbeFootprint {
    case ellipse
    case chisel
    case translatedBounds
    case dualEllipse
}
