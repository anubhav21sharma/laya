import BrushFormat
import Darwin
import Foundation
import Metal
import MetalRenderer
import PatternEngine

private struct AllocatorProbe {
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

private enum ProbeHarnessError: Error, CustomStringConvertible {
    case invalidArguments
    case metalUnavailable
    case probeUnavailable
    case selfTestMissedAllocation
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
            "expected --self-test or --production and a repository root"
        case .metalUnavailable:
            "the production allocation route requires a Metal device"
        case .probeUnavailable:
            "allocator probe symbols are unavailable"
        case .selfTestMissedAllocation:
            "allocator probe missed the deliberate Array allocation"
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
            try renderer.appendStroke(
                token: token,
                sample: sample(
                    .moved,
                    x: Float(index % 96) * 0.5
                )
            )
            if index.isMultiple(of: 16) {
                try renderer.appendStroke(
                    token: token,
                    sample: predictedSample(
                        x: Float((index + 1) % 96) * 0.5
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
            let authoritativeSample = sample(
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

            if index.isMultiple(of: 16) {
                let predicted = predictedSample(
                    x: Float((index + 1) % 96) * 0.5
                )
                probe.arm()
                do {
                    try renderer.appendStroke(
                        token: token,
                        sample: predicted
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
        print(
            "ALLOCATOR PROBE PRODUCTION PASS allocations=\(allocationCount)"
        )
    }

    @MainActor
    private static func makeRendererSetup(root: URL) async throws
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
            id: BrushRecipeID("brush.allocator-probe"),
            replayMode: .replayTail,
            replayLimits: BrushRecipePolicy.replayTailLimits
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
}
