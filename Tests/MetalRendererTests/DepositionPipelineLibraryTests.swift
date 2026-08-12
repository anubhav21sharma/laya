import CShaderTypes
import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Deposition pipeline library", .serialized)
@MainActor
struct DepositionPipelineLibraryTests {
    @Test
    func semanticPipelineDimensionsArePartOfTheStableKey() {
        let baseline = key()
        let variants = [
            key(abiVersion: DepositionABI.version + 1),
            key(pixelFormat: .bgra8Unorm),
            key(sampleCount: 4),
            key(accumulation: .uniformGlaze),
            key(edgeTreatment: .dryBreakup),
            key(usesSecondaryShape: true),
            key(usesPrimaryGrain: true),
            key(usesSecondaryGrain: true),
        ]

        #expect(key() == baseline)
        #expect(Set([baseline] + variants).count == variants.count + 1)
    }

    @Test
    func repeatedAndConcurrentPreparationPublishesOneStateIdentity() async throws {
        guard let context = try makeContext() else { return }
        let requested = key(
            accumulation: .intenseGlaze,
            edgeTreatment: .markerOverlap,
            usesSecondaryShape: true,
            usesPrimaryGrain: true,
            usesSecondaryGrain: true
        )

        async let first = context.pipelines.prepare(for: requested)
        async let second = context.pipelines.prepare(for: requested)
        let (firstBinding, secondBinding) = try await (first, second)
        let repeated = try await context.pipelines.prepare(for: requested)

        #expect(firstBinding === secondBinding)
        #expect(firstBinding === repeated)
        #expect(firstBinding.state === repeated.state)
        #expect(context.pipelines.debugPrepareCallCount == 3)
        #expect(context.pipelines.debugPreparedPipelineCount == 1)
        #expect(
            try context.pipelines.preparedBinding(for: requested)
                === firstBinding
        )
    }

    @Test
    func failedPreparationDoesNotReplaceAnExistingReadyBinding() async throws {
        guard let context = try makeContext() else { return }
        let readyKey = key()
        let ready = try await context.pipelines.prepare(for: readyKey)
        let invalid = key(abiVersion: DepositionABI.version + 1)

        await #expect(
            throws: DepositionPipelineLibraryError.unsupportedABI(
                DepositionABI.version + 1
            )
        ) {
            _ = try await context.pipelines.prepare(for: invalid)
        }

        #expect(
            try context.pipelines.preparedBinding(for: readyKey) === ready
        )
        #expect(
            throws: DepositionPipelineLibraryError.notPrepared(invalid)
        ) {
            _ = try context.pipelines.preparedBinding(for: invalid)
        }
    }

    @Test
    func preparedLookupNeverCreatesAState() throws {
        guard let context = try makeContext() else { return }
        let requested = key()

        #expect(
            throws: DepositionPipelineLibraryError.notPrepared(requested)
        ) {
            _ = try context.pipelines.preparedBinding(for: requested)
        }
        #expect(context.pipelines.debugPreparedPipelineCount == 0)
    }

    @Test
    func bgraRejectionCannotChangePreparedCacheOrStartCompilation() async throws {
        guard let context = try makeContext() else { return }
        let working = key()
        let ready = try await context.pipelines.prepare(for: working)
        let prepareCount = context.pipelines.debugPrepareCallCount
        let invalid = key(pixelFormat: .bgra8Unorm)

        await #expect(
            throws: DepositionPipelineLibraryError.invalidPixelFormat(
                MTLPixelFormat.bgra8Unorm.rawValue
            )
        ) {
            _ = try await context.pipelines.prepare(for: invalid)
        }

        #expect(context.pipelines.debugPreparedPipelineCount == 1)
        #expect(context.pipelines.debugPrepareCallCount == prepareCount)
        #expect(try context.pipelines.preparedBinding(for: working) === ready)
        #expect(throws: DepositionPipelineLibraryError.notPrepared(invalid)) {
            _ = try context.pipelines.preparedBinding(for: invalid)
        }
    }

    private func key(
        abiVersion: UInt16 = DepositionABI.version,
        pixelFormat: MTLPixelFormat = .rgba16Float,
        sampleCount: Int = 1,
        accumulation: BrushAccumulationMode = .flow,
        edgeTreatment: BrushEdgeTreatment = .none,
        usesSecondaryShape: Bool = false,
        usesPrimaryGrain: Bool = false,
        usesSecondaryGrain: Bool = false
    ) -> DepositionPipelineKey {
        DepositionPipelineKey(
            brush: BrushPipelineKey(
                backend: .deposition,
                accumulation: accumulation,
                edgeTreatment: edgeTreatment,
                functionConstants: BrushFunctionConstants(
                    usesSecondaryShape: usesSecondaryShape,
                    usesGrain: usesPrimaryGrain,
                    usesSecondaryGrain: usesSecondaryGrain
                )
            ),
            abiVersion: abiVersion,
            colorPixelFormatRawValue: pixelFormat.rawValue,
            sampleCount: sampleCount
        )
    }

    private func makeContext() throws -> (
        device: any MTLDevice,
        pipelines: DepositionPipelineLibrary
    )? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let library = try makeDepositionLibrary(device: device)
        return (
            device,
            DepositionPipelineLibrary(device: device, library: library)
        )
    }

    private func makeDepositionLibrary(
        device: any MTLDevice
    ) throws -> any MTLLibrary {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
}
