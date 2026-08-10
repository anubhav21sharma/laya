import BrushFormat
import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Native deposition canonical metamorphic evidence", .serialized)
struct DepositionMetamorphicTests {
    @Test(arguments: [
        MetamorphicScene(
            name: "deposition-prediction",
            invariants: ["predictionOnOffEqual"]
        ),
        MetamorphicScene(
            name: "deposition-kinematics",
            invariants: ["batchPartitionsEqual", "zoomIndependent"]
        ),
        MetamorphicScene(
            name: "deposition-periodic-seams",
            invariants: [
                "symmetryOrderEqual",
                "tilingPeriodTranslationEqual",
            ]
        ),
        MetamorphicScene(
            name: "deposition-erase",
            invariants: ["eraseColorIndependent"]
        ),
        MetamorphicScene(
            name: "deposition-radial-reflection",
            invariants: ["reflectionHandednessCorrect"]
        ),
        MetamorphicScene(
            name: "deposition-preview-commit",
            invariants: ["cancelPreservesCanonical"]
        ),
    ])
    @MainActor
    func canonicalInvariantIsProvenFromNativeBytes(
        _ fixture: MetamorphicScene
    ) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try depositionHarnessTestLibrary(device: device)
        let output = temporaryDirectory(named: fixture.name)
        defer { try? FileManager.default.removeItem(at: output) }

        _ = try await depositionHarnessRunner(
            device: device,
            library: library
        ).run(
            scene: repositoryScene(named: fixture.name),
            outputDirectory: output,
            build: BenchmarkBuild(
                configuration: "Testing",
                gitCommit: String(repeating: "a", count: 40)
            )
        )
        let evidence = try DepositionSceneEvidence.decode(
            Data(
                contentsOf: output.appendingPathComponent(
                    "\(fixture.name).deposition-evidence.json"
                )
            )
        )

        for invariant in fixture.invariants {
            #expect(evidence.invariantResults[invariant] == true)
        }
    }

    @Test
    @MainActor
    func arbitraryPredictionReplacementCadenceLeavesCommittedBytesUnchanged()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try depositionHarnessTestLibrary(device: device)
        let authoritative = predictionCadenceTrace()
        let expected = try await committedPredictionCadenceBytes(
            authoritative,
            device: device,
            library: library
        )

        for cadence in [1, 2, 3, 5] {
            var trace: [StrokeSample] = []
            trace.reserveCapacity(authoritative.count * (cadence + 1))
            for (index, sample) in authoritative.enumerated() {
                if sample.phase != .ended {
                    trace.append(sample)
                }
                guard sample.phase == .moved,
                      index + 1 < authoritative.count
                else {
                    if sample.phase == .ended { trace.append(sample) }
                    continue
                }
                let next = authoritative[index + 1]
                for replacement in 1...cadence {
                    let fraction = Float(replacement) / Float(cadence + 1)
                    trace.append(
                        StrokeSample(
                            position: ScreenPoint(
                                x: sample.position.x
                                    + (next.position.x - sample.position.x)
                                        * fraction,
                                y: sample.position.y
                                    + (next.position.y - sample.position.y)
                                        * fraction
                            ),
                            pressure: sample.pressure,
                            timestamp: sample.timestamp
                                + (next.timestamp - sample.timestamp)
                                    * Double(fraction),
                            phase: .moved,
                            source: .pencil,
                            kind: .predicted
                        )
                    )
                }
            }
            let actual = try await committedPredictionCadenceBytes(
                trace,
                device: device,
                library: library
            )
            #expect(actual == expected, "Prediction cadence \(cadence)")
        }
    }

    @Test
    @MainActor
    func shorterAndLongerBatchedPredictionSuffixesLeaveCommittedBytesUnchanged()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try depositionHarnessTestLibrary(device: device)
        let authoritative = predictionCadenceTrace()
        let expected = try await committedPredictionCadenceBytes(
            authoritative,
            device: device,
            library: library
        )

        for replacementLengths in [[4, 2, 5, 3], [2, 6, 3, 4]] {
            let actual = try await committedBatchedPredictionCadenceBytes(
                authoritative,
                replacementLengths: replacementLengths,
                device: device,
                library: library
            )
            #expect(
                actual == expected,
                "Batched suffix lengths \(replacementLengths)"
            )
        }
    }
}

private func predictionCadenceTrace() -> [StrokeSample] {
    [
        predictionCadenceSample(x: 16, timestamp: 0, phase: .began),
        predictionCadenceSample(x: 25, timestamp: 0.01, phase: .moved),
        predictionCadenceSample(x: 34, timestamp: 0.02, phase: .moved),
        predictionCadenceSample(x: 43, timestamp: 0.03, phase: .moved),
        predictionCadenceSample(x: 52, timestamp: 0.04, phase: .moved),
        predictionCadenceSample(x: 52, timestamp: 0.05, phase: .ended),
    ]
}

private func predictionCadenceSample(
    x: Float,
    timestamp: TimeInterval,
    phase: StrokePhase
) -> StrokeSample {
    StrokeSample(
        position: ScreenPoint(x: x, y: 32),
        pressure: 0.65,
        timestamp: timestamp,
        phase: phase,
        source: .pencil,
        capabilities: [.pressure]
    )
}

@MainActor
private func committedPredictionCadenceBytes(
    _ trace: [StrokeSample],
    device: any MTLDevice,
    library: any MTLLibrary
) async throws -> [UInt8] {
    let first = try #require(trace.first)
    let last = try #require(trace.last)
    return try await committedPredictionCadenceBytes(
        first: first,
        last: last,
        events: trace.dropFirst().dropLast().map { .single($0) },
        device: device,
        library: library
    )
}

@MainActor
private func committedBatchedPredictionCadenceBytes(
    _ authoritative: [StrokeSample],
    replacementLengths: [Int],
    device: any MTLDevice,
    library: any MTLLibrary
) async throws -> [UInt8] {
    let first = try #require(authoritative.first)
    let last = try #require(authoritative.last)
    var events: [PredictionCadenceEvent] = []
    for (index, sample) in authoritative.enumerated().dropFirst().dropLast() {
        events.append(.single(sample))
        guard sample.phase == .moved,
              index + 1 < authoritative.count else { continue }
        let next = authoritative[index + 1]
        for replacementLength in replacementLengths {
            precondition(replacementLength > 1)
            events.append(
                .batch(
                    predictionSuffix(
                        from: sample,
                        to: next,
                        count: replacementLength
                    )
                )
            )
        }
    }
    return try await committedPredictionCadenceBytes(
        first: first,
        last: last,
        events: events,
        device: device,
        library: library
    )
}

private enum PredictionCadenceEvent {
    case single(StrokeSample)
    case batch([StrokeSample])
}

private func predictionSuffix(
    from sample: StrokeSample,
    to next: StrokeSample,
    count: Int
) -> [StrokeSample] {
    (1...count).map { offset in
        let fraction = Float(offset) / Float(count + 1)
        return StrokeSample(
            position: ScreenPoint(
                x: sample.position.x
                    + (next.position.x - sample.position.x) * fraction,
                y: sample.position.y
                    + (next.position.y - sample.position.y) * fraction
            ),
            pressure: sample.pressure,
            timestamp: sample.timestamp
                + (next.timestamp - sample.timestamp) * Double(fraction),
            phase: .moved,
            source: .pencil,
            kind: .predicted
        )
    }
}

@MainActor
private func committedPredictionCadenceBytes(
    first: StrokeSample,
    last: StrokeSample,
    events: [PredictionCadenceEvent],
    device: any MTLDevice,
    library: any MTLLibrary
) async throws -> [UInt8] {
    let queue = try #require(device.makeCommandQueue())
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
        pipelinePreparing: DepositionPipelineLibrary(
            device: device,
            library: library
        ),
        testHooks: .none
    )
    let definition = try stageCMetalTestProgram(
        id: "test.metamorphic-ink",
        replayMode: .appendOnly
    ).definition
    let brush = try await compiler.compileAndActivate(
        package: BrushPackage(
            manifest: BrushPackageManifest(resources: []),
            definition: definition,
            resourceData: [:]
        )
    )
    try renderer.activateDrawBrush(brush)
    let token = RendererOperationToken(rawValue: 91)
    try renderer.beginStroke(
        token: token,
        sample: first,
        style: StrokeRenderStyle(
            color: .black,
            diameter: 12,
            compositeMode: .draw,
            eraserStrength: 1,
            program: brush.program,
            renderIdentity: brush.renderIdentity,
            seed: 7
        )
    )
    for event in events {
        switch event {
        case let .single(sample):
            try renderer.appendStroke(token: token, sample: sample)
        case let .batch(samples):
            try renderer.appendStrokeBatch(token: token, samples: samples)
        }
        _ = try await renderer.flushPendingLiveForHarness()
    }
    try renderer.requestStrokeCommit(
        token: token,
        sample: last
    )
    _ = try await renderer.finishCommitForHarness()
    let snapshot = try await renderer.captureCommittedDocument()
    guard case let .singleRaster(bytes) = snapshot.storage else {
        throw MetalRendererError.committedSnapshotIncompatible
    }
    return bytes
}

struct MetamorphicScene: Sendable, CustomTestStringConvertible {
    let name: String
    let invariants: [String]

    var testDescription: String { name }
}
