import Metal

@MainActor
public struct GridPipelineLibrary {
    public let stamp: any MTLRenderPipelineState
    public let display: any MTLRenderPipelineState
    public let triangularDisplay: any MTLRenderPipelineState
    public let radialDisplay: any MTLRenderPipelineState
    public let radialResizeCopy: any MTLComputePipelineState
    public let commit: any MTLRenderPipelineState
    public let washDeposit: any MTLRenderPipelineState
    public let replayClear: any MTLRenderPipelineState
    public let washClear: any MTLRenderPipelineState
    public let washSoften: any MTLRenderPipelineState
    public let washResolve: any MTLRenderPipelineState

    public init(device: any MTLDevice, library: any MTLLibrary) throws {
        stamp = try Self.makePipeline(
            device: device,
            library: library,
            label: "Projected Brush Stamp",
            vertex: "patternProjectedStampVertex",
            fragment: "patternBrushStampFragment",
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
        triangularDisplay = try Self.makePipeline(
            device: device,
            library: library,
            label: "Triangular Grid Display",
            vertex: "patternFullscreenVertex",
            fragment: "patternTriangularGridFragment",
            configure: { attachment in
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
        )
        radialDisplay = try Self.makePipeline(
            device: device,
            library: library,
            label: "Radial Finite Display",
            vertex: "patternFullscreenVertex",
            fragment: "patternRadialGridFragment",
            configure: { attachment in
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
        )
        guard let radialResizeFunction = library.makeFunction(
            name: "patternRadialResizeCopy"
        ) else {
            throw MetalRendererError.shaderFunctionUnavailable(
                "patternRadialResizeCopy"
            )
        }
        do {
            radialResizeCopy = try device.makeComputePipelineState(
                function: radialResizeFunction
            )
        } catch {
            throw MetalRendererError.pipelineCreationFailed(
                error.localizedDescription
            )
        }
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
        washDeposit = try Self.makePipeline(
            device: device,
            library: library,
            label: "Bounded Wash Deposit",
            vertex: "patternProjectedStampVertex",
            fragment: "patternBrushStampFragment",
            pixelFormat: BoundedWashSurface.pixelFormat,
            configure: Self.configureStraightSourceOver
        )
        replayClear = try Self.makePipeline(
            device: device,
            library: library,
            label: "Replay Tail Regional Clear",
            vertex: "patternFullscreenVertex",
            fragment: "patternWashClearFragment",
            configure: { $0.isBlendingEnabled = false }
        )
        washClear = try Self.makePipeline(
            device: device,
            library: library,
            label: "Bounded Wash Regional Clear",
            vertex: "patternFullscreenVertex",
            fragment: "patternWashClearFragment",
            pixelFormat: BoundedWashSurface.pixelFormat,
            configure: { $0.isBlendingEnabled = false }
        )
        washSoften = try Self.makePipeline(
            device: device,
            library: library,
            label: "Bounded Wash Local Soften",
            vertex: "patternFullscreenVertex",
            fragment: "patternWashSoftenFragment",
            pixelFormat: BoundedWashSurface.pixelFormat,
            configure: { $0.isBlendingEnabled = false }
        )
        washResolve = try Self.makePipeline(
            device: device,
            library: library,
            label: "Bounded Wash Premultiplied Resolve",
            vertex: "patternFullscreenVertex",
            fragment: "patternWashResolveFragment",
            configure: Self.configurePremultipliedSourceOver
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

    static func makeHarnessBrushPipeline(
        device: any MTLDevice,
        library: any MTLLibrary
    ) throws -> any MTLRenderPipelineState {
        try makePipeline(
            device: device,
            library: library,
            label: "Harness Recipe Brush Footprint",
            vertex: "patternProjectedStampVertex",
            fragment: "patternBrushStampFragment",
            configure: configureStraightSourceOver
        )
    }

    private static func makePipeline(
        device: any MTLDevice,
        library: any MTLLibrary,
        label: String,
        vertex: String,
        fragment: String,
        pixelFormat: MTLPixelFormat = .bgra8Unorm,
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
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        configure(descriptor.colorAttachments[0])

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalRendererError.pipelineCreationFailed(
                error.localizedDescription
            )
        }
    }

    private static func configureStraightSourceOver(
        _ attachment: MTLRenderPipelineColorAttachmentDescriptor
    ) {
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    private static func configurePremultipliedSourceOver(
        _ attachment: MTLRenderPipelineColorAttachmentDescriptor
    ) {
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }
}
