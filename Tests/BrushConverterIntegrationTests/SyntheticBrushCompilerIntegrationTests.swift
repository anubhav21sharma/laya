import BrushConverter
import BrushFormat
import Metal
import MetalRenderer
import Testing

@Suite("Synthetic converter Metal integration", .serialized)
@MainActor
struct SyntheticBrushCompilerIntegrationTests {
    @Test
    func dryPackageRoundTripsDecodesUploadsAndActivates() async throws {
        guard let compiler = try makeCompiler() else { return }
        let package = try mappedPackage(includeWet: false)
        let reopened = try BrushPackageCodec.decode(
            BrushPackageCodec.encode(package)
        )

        let compiled = try await compiler.compileAndActivate(
            package: reopened
        )
        let resources = Dictionary(
            uniqueKeysWithValues: reopened.manifest.resources.map {
                ($0.id, $0)
            }
        )

        #expect(compiler.activeBrush === compiled)
        #expect(compiled.pipelineKey.backend == .deposition)
        #expect(compiled.program.compatibilityRecipe == nil)
        #expect(
            compiled.textures.keys.sorted()
                == ["grain.synthetic", "shape.synthetic"]
        )
        for id in ["grain.synthetic", "shape.synthetic"] {
            let resource = try #require(resources[id])
            let texture = try #require(compiled.textures[id])
            #expect(texture.width == resource.pixelWidth)
            #expect(texture.height == resource.pixelHeight)
            #expect(texture.pixelFormat == .r8Unorm)
            #expect(texture.storageMode == .private)
        }
        #expect(
            compiler.debugCounters
                == BrushCompilerCounters(
                    packageDecodeCount: 1,
                    imageDecodeCount: 2,
                    textureUploadCount: 2,
                    cacheHitCount: 0,
                    activationCount: 1
                )
        )
    }

    @Test
    func wetPackageFailsBeforeDecodeAndPreservesDryActivation() async throws {
        guard let compiler = try makeCompiler() else { return }
        let dry = try await compiler.compileAndActivate(
            package: try mappedPackage(includeWet: false)
        )
        let before = compiler.debugCounters
        let wet = try BrushPackageCodec.decode(
            BrushPackageCodec.encode(
                try mappedPackage(includeWet: true)
            )
        )

        let failure = try await compilationFailure {
            _ = try await compiler.compileAndActivate(package: wet)
        }
        let after = compiler.debugCounters

        #expect(failure.stage == .pipelineSelection)
        #expect(failure.reason == "unsupportedRequiredSemantic")
        #expect(failure.backend == .canvasInteraction)
        #expect(compiler.activeBrush === dry)
        #expect(after.packageDecodeCount == before.packageDecodeCount + 1)
        #expect(after.imageDecodeCount == before.imageDecodeCount)
        #expect(after.textureUploadCount == before.textureUploadCount)
        #expect(after.cacheHitCount == before.cacheHitCount)
        #expect(after.activationCount == before.activationCount)
    }

    private func mappedPackage(includeWet: Bool) throws -> BrushPackage {
        let source = try SyntheticV1DiagnosticFixture.source(
            includeWet: includeWet
        )
        let parser = SyntheticV1BrushParser()
        guard try parser.probe(source) else {
            throw SyntheticIntegrationError.probeFailed
        }
        let documents = try parser.parse(source)
        guard documents.count == 1, let document = documents.first else {
            throw SyntheticIntegrationError.invalidDocumentCount(
                documents.count
            )
        }
        return try SyntheticV1BrushMapper().map(document).package
    }

    private func makeCompiler() throws -> BrushCompiler? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else {
            return nil
        }
        return BrushCompiler(
            device: device,
            commandQueue: queue,
            profile: try BrushDeviceProfile(
                registryID: device.registryID,
                recommendedWorkingSetBytes: 1_024 * 1_024 * 1_024,
                maximumWorkingTextureDimension: 4_096,
                brushCacheBudgetBytes: 128 * 1_024 * 1_024,
                targetFramesPerSecond: 120
            )
        )
    }

    private func compilationFailure(
        _ operation: @MainActor () async throws -> Void
    ) async throws -> BrushCompilationFailure {
        do {
            try await operation()
            throw SyntheticIntegrationError.expectedFailure
        } catch let failure as BrushCompilationFailure {
            return failure
        }
    }
}

private enum SyntheticIntegrationError: Error {
    case probeFailed
    case invalidDocumentCount(Int)
    case expectedFailure
}
