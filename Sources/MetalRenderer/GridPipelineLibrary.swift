import Metal

@MainActor
public struct GridPipelineLibrary {
    public let stamp: any MTLRenderPipelineState
    public let display: any MTLRenderPipelineState
    public let commit: any MTLRenderPipelineState

    public init(device: any MTLDevice, library: any MTLLibrary) throws {
        stamp = try Self.makePipeline(
            device: device,
            library: library,
            label: "Projected Hard Round Stamp",
            vertex: "patternProjectedStampVertex",
            fragment: "patternHardRoundStampFragment",
            configure: { attachment in
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
        )
        display = try Self.makePipeline(
            device: device,
            library: library,
            label: "Grid Display",
            vertex: "patternFullscreenVertex",
            fragment: "patternGridFragment",
            configure: { attachment in
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
        )
        commit = try Self.makePipeline(
            device: device,
            library: library,
            label: "Canonical Commit",
            vertex: "patternFullscreenVertex",
            fragment: "patternCommitFragment",
            configure: { attachment in
                attachment.isBlendingEnabled = false
            }
        )
    }

    static func makeHarnessDiagnosticPipeline(
        device: any MTLDevice,
        library: any MTLLibrary
    ) throws -> any MTLRenderPipelineState {
        try makePipeline(
            device: device,
            library: library,
            label: "Harness Diagnostic Projected Footprint",
            vertex: "patternProjectedStampVertex",
            fragment: "patternDiagnosticFootprintFragment",
            configure: { attachment in
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
        )
    }

    private static func makePipeline(
        device: any MTLDevice,
        library: any MTLLibrary,
        label: String,
        vertex: String,
        fragment: String,
        configure: (MTLRenderPipelineColorAttachmentDescriptor) -> Void
    ) throws -> any MTLRenderPipelineState {
        guard let vertexFunction = library.makeFunction(name: vertex) else {
            throw MetalRendererError.shaderFunctionUnavailable(vertex)
        }
        guard let fragmentFunction = library.makeFunction(name: fragment) else {
            throw MetalRendererError.shaderFunctionUnavailable(fragment)
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        configure(descriptor.colorAttachments[0])

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalRendererError.pipelineCreationFailed(
                error.localizedDescription
            )
        }
    }
}
