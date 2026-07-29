import BrushConverter
import BrushFormat
import Metal
@testable import MetalRenderer
import PatternEngine
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
        #expect(compiled.program.definition == reopened.definition)
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
        #expect(failure.reason == "unsupportedInteraction")
        #expect(failure.backend == .canvasInteraction)
        #expect(compiler.activeBrush === dry)
        #expect(after.packageDecodeCount == before.packageDecodeCount)
        #expect(after.imageDecodeCount == before.imageDecodeCount)
        #expect(after.textureUploadCount == before.textureUploadCount)
        #expect(after.cacheHitCount == before.cacheHitCount)
        #expect(after.activationCount == before.activationCount)
    }

    @Test
    func wetConcentrationFailsWithTypedDepositionRejection() async throws {
        guard let compiler = try makeCompiler() else { return }
        let dry = try await compiler.compileAndActivate(
            package: try mappedPackage(includeWet: false)
        )
        let before = compiler.debugCounters
        let wetEdge = try wetConcentrationPackage()

        let failure = try await compilationFailure {
            _ = try await compiler.compileAndActivate(package: wetEdge)
        }
        let after = compiler.debugCounters

        #expect(failure.stage == .pipelineSelection)
        #expect(failure.reason == "unsupportedWetConcentration")
        #expect(failure.backend == .deposition)
        #expect(compiler.activeBrush === dry)
        #expect(after == before)
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

    private func wetConcentrationPackage() throws -> BrushPackage {
        let dry = try mappedPackage(includeWet: false)
        let definition = dry.definition
        let material = definition.material
        let wetDefinition = try BrushDefinition(
            id: definition.id,
            schemaVersion: definition.schemaVersion,
            metadata: definition.metadata,
            capabilities: definition.capabilities,
            resources: definition.resources,
            coverage: definition.coverage,
            placement: definition.placement,
            dynamics: definition.dynamics,
            color: definition.color,
            material: BrushMaterialDefinition(
                accumulation: material.accumulation,
                interaction: .none,
                edgeTreatment: .wetConcentration,
                strength: material.strength,
                wetness: material.wetness,
                bleedRadius: material.bleedRadius,
                softenPasses: material.softenPasses,
                accumulationLimit: material.accumulationLimit,
                interactionParameters: nil
            ),
            stabilization: definition.stabilization,
            taper: definition.taper,
            replayMode: definition.replayMode,
            replayLimits: definition.replayLimits,
            seedPolicy: definition.seedPolicy,
            limits: definition.limits,
            performanceIntent: definition.performanceIntent,
            compatibility: definition.compatibility
        )
        let manifest = try BrushPackageManifest(
            schemaVersion: dry.manifest.schemaVersion,
            resources: dry.manifest.resources,
            provenance: dry.manifest.provenance
        )
        return try BrushPackage(
            manifest: manifest,
            definition: wetDefinition,
            resourceData: dry.resourceData
        )
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
            ),
            pipelinePreparing: try SyntheticTestPipelinePreparer(
                device: device
            ),
            testHooks: .none
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

@MainActor
private final class SyntheticTestPipelinePreparer:
    DepositionPipelinePreparing
{
    private let state: any MTLRenderPipelineState
    private var bindings:
        [DepositionPipelineKey: DepositionPipelineBinding] = [:]

    init(device: any MTLDevice) throws {
        state = try makeSyntheticTestPipelineState(device: device)
    }

    func prepare(
        for key: DepositionPipelineKey
    ) async throws -> DepositionPipelineBinding {
        if let binding = bindings[key] {
            return binding
        }
        let binding = DepositionPipelineBinding(key: key, state: state)
        bindings[key] = binding
        return binding
    }
}

@MainActor
private func makeSyntheticTestPipelineState(
    device: any MTLDevice
) throws -> any MTLRenderPipelineState {
    let source = """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 syntheticCompilerVertex(uint id [[vertex_id]]) {
            const float2 points[3] = {
                float2(-1, -1), float2(3, -1), float2(-1, 3)
            };
            return float4(points[id], 0, 1);
        }
        fragment float4 syntheticCompilerFragment() {
            return float4(0);
        }
        """
    let library = try device.makeLibrary(source: source, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(
        name: "syntheticCompilerVertex"
    )
    descriptor.fragmentFunction = library.makeFunction(
        name: "syntheticCompilerFragment"
    )
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    return try device.makeRenderPipelineState(descriptor: descriptor)
}

private enum SyntheticIntegrationError: Error {
    case probeFailed
    case invalidDocumentCount(Int)
    case expectedFailure
}
