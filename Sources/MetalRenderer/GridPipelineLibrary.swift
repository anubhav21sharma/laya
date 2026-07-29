import CShaderTypes
import Metal

@MainActor
public struct GridPipelineLibrary {
    public static let colorPixelFormat: MTLPixelFormat = .bgra8Unorm
    public static let sampleCount = 1

    public let display: any MTLRenderPipelineState
    public let triangularDisplay: any MTLRenderPipelineState
    public let radialDisplay: any MTLRenderPipelineState
    public let radialResizeCopy: any MTLComputePipelineState
    public let commit: any MTLRenderPipelineState
    public let replayClear: any MTLRenderPipelineState

    public init(device: any MTLDevice, library: any MTLLibrary) throws {
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
        replayClear = try Self.makePipeline(
            device: device,
            library: library,
            label: "Replay Tail Regional Clear",
            vertex: "patternFullscreenVertex",
            fragment: "patternClearFragment",
            configure: { $0.isBlendingEnabled = false }
        )
    }

    static func makeHarnessDiagnosticPipeline(
        device: any MTLDevice,
        library: any MTLLibrary
    ) throws -> any MTLRenderPipelineState {
        let constants = harnessDiagnosticFunctionConstants()
        return try makePipeline(
            device: device,
            library: library,
            label: "Harness Diagnostic Projected Footprint",
            vertex: "patternProjectedDepositionVertex",
            fragment: "patternDiagnosticFootprintFragment",
            constants: constants,
            configure: { attachment in
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
        )
    }

    private static func harnessDiagnosticFunctionConstants()
        -> MTLFunctionConstantValues
    {
        let constants = MTLFunctionConstantValues()
        var disabled = false
        constants.setConstantValue(
            &disabled,
            type: .bool,
            index: Int(PatternDepositionFunctionConstantSecondaryShape)
        )
        constants.setConstantValue(
            &disabled,
            type: .bool,
            index: Int(PatternDepositionFunctionConstantPrimaryGrain)
        )
        constants.setConstantValue(
            &disabled,
            type: .bool,
            index: Int(PatternDepositionFunctionConstantSecondaryGrain)
        )
        var accumulation = PatternDepositionAccumulationOpaque
        constants.setConstantValue(
            &accumulation,
            type: .uint,
            index: Int(PatternDepositionFunctionConstantAccumulation)
        )
        var edge = PatternDepositionEdgeNone
        constants.setConstantValue(
            &edge,
            type: .uint,
            index: Int(PatternDepositionFunctionConstantEdgeTreatment)
        )
        return constants
    }

    private static func makePipeline(
        device: any MTLDevice,
        library: any MTLLibrary,
        label: String,
        vertex: String,
        fragment: String,
        constants: MTLFunctionConstantValues? = nil,
        pixelFormat: MTLPixelFormat = GridPipelineLibrary.colorPixelFormat,
        configure: (MTLRenderPipelineColorAttachmentDescriptor) -> Void
    ) throws -> any MTLRenderPipelineState {
        let vertexFunction: any MTLFunction
        let fragmentFunction: any MTLFunction
        if let constants {
            do {
                vertexFunction = try library.makeFunction(
                    name: vertex,
                    constantValues: constants
                )
                fragmentFunction = try library.makeFunction(
                    name: fragment,
                    constantValues: constants
                )
            } catch {
                throw MetalRendererError.pipelineCreationFailed(
                    error.localizedDescription
                )
            }
        } else {
            guard let vertex = library.makeFunction(name: vertex) else {
                throw MetalRendererError.shaderFunctionUnavailable(vertex)
            }
            guard let fragment = library.makeFunction(name: fragment) else {
                throw MetalRendererError.shaderFunctionUnavailable(fragment)
            }
            vertexFunction = vertex
            fragmentFunction = fragment
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
