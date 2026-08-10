import CShaderTypes
import EditorCore
import Metal

enum LayerBlendPipelineError: Error, Equatable, Sendable {
    case unsupportedABI(UInt16)
    case shaderLibraryUnavailable
    case shaderFunctionUnavailable
    case pipelineCreationFailed
    case invalidTexture
    case targetSourceAlias
    case deviceMismatch
    case commandEncoderUnavailable
}

enum LayerBlendABI {
    static let version: UInt16 = 1
}

final class LayerBlendPipelineBinding: @unchecked Sendable {
    private let blendState: any MTLComputePipelineState
    private let interchangePackState: any MTLComputePipelineState
    private let affineDisplayState: any MTLRenderPipelineState
    private let radialDisplayState: any MTLRenderPipelineState
    private let displayPixelFormat: MTLPixelFormat
    private let deviceRegistryID: UInt64

    fileprivate init(
        blendState: any MTLComputePipelineState,
        interchangePackState: any MTLComputePipelineState,
        affineDisplayState: any MTLRenderPipelineState,
        radialDisplayState: any MTLRenderPipelineState,
        displayPixelFormat: MTLPixelFormat,
        deviceRegistryID: UInt64
    ) {
        self.blendState = blendState
        self.interchangePackState = interchangePackState
        self.affineDisplayState = affineDisplayState
        self.radialDisplayState = radialDisplayState
        self.displayPixelFormat = displayPixelFormat
        self.deviceRegistryID = deviceRegistryID
    }

    func encode(
        source: any MTLTexture,
        backdrop: any MTLTexture,
        target: any MTLTexture,
        opacity: Float,
        mode: LayerBlendMode,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        precondition(opacity.isFinite && (0...1).contains(opacity))
        guard source !== target, backdrop !== target else {
            throw LayerBlendPipelineError.targetSourceAlias
        }
        guard source.device.registryID == deviceRegistryID,
              backdrop.device.registryID == deviceRegistryID,
              target.device.registryID == deviceRegistryID,
              commandBuffer.commandQueue.device.registryID == deviceRegistryID
        else {
            throw LayerBlendPipelineError.deviceMismatch
        }
        guard source.pixelFormat == .rgba16Float,
              backdrop.pixelFormat == .rgba16Float,
              target.pixelFormat == .rgba16Float,
              source.textureType == .type2D,
              backdrop.textureType == .type2D,
              target.textureType == .type2D,
              source.width == backdrop.width,
              source.height == backdrop.height,
              source.width == target.width,
              source.height == target.height,
              source.depth == 1,
              backdrop.depth == 1,
              target.depth == 1,
              source.usage.contains(.shaderRead),
              backdrop.usage.contains(.shaderRead),
              target.usage.contains(.shaderWrite)
        else {
            throw LayerBlendPipelineError.invalidTexture
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            throw LayerBlendPipelineError.commandEncoderUnavailable
        }
        encoder.label = "Bounded Linear Layer Blend"
        encoder.setComputePipelineState(blendState)
        encoder.setTexture(
            backdrop,
            index: Int(PatternTextureIndexLayerBlendBackdrop)
        )
        encoder.setTexture(
            source,
            index: Int(PatternTextureIndexLayerBlendSource)
        )
        encoder.setTexture(
            target,
            index: Int(PatternTextureIndexLayerBlendDestination)
        )
        var uniforms = PatternCompositeUniforms()
        uniforms.parameters = SIMD4(
            opacity,
            Float(mode.layerBlendWireValue),
            0,
            0
        )
        encoder.setBytes(
            &uniforms,
            length: MemoryLayout<PatternCompositeUniforms>.stride,
            index: Int(PatternBufferIndexLayerBlendUniforms)
        )
        let width = blendState.threadExecutionWidth
        let height = max(
            1,
            blendState.maxTotalThreadsPerThreadgroup / width
        )
        encoder.dispatchThreads(
            MTLSize(width: target.width, height: target.height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: width,
                height: height,
                depth: 1
            )
        )
        encoder.endEncoding()
    }

    func encodeInterchange(
        source: any MTLTexture,
        target: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        guard source.device.registryID == deviceRegistryID,
              target.device.registryID == deviceRegistryID,
              commandBuffer.commandQueue.device.registryID == deviceRegistryID
        else { throw LayerBlendPipelineError.deviceMismatch }
        guard source.pixelFormat == .rgba16Float,
              target.pixelFormat
                == DocumentColorPipeline.interchangePixelFormat,
              source.textureType == .type2D,
              target.textureType == .type2D,
              source.width == target.width,
              source.height == target.height,
              source.depth == 1,
              target.depth == 1,
              source.usage.contains(.shaderRead),
              target.usage.contains(.shaderWrite)
        else { throw LayerBlendPipelineError.invalidTexture }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw LayerBlendPipelineError.commandEncoderUnavailable
        }
        encoder.label = "Linear Layer Composite Interchange Pack"
        encoder.setComputePipelineState(interchangePackState)
        encoder.setTexture(
            source,
            index: Int(PatternTextureIndexLayerBlendSource)
        )
        encoder.setTexture(
            target,
            index: Int(PatternTextureIndexLayerBlendDestination)
        )
        let width = interchangePackState.threadExecutionWidth
        let height = max(
            1,
            interchangePackState.maxTotalThreadsPerThreadgroup / width
        )
        encoder.dispatchThreads(
            MTLSize(width: target.width, height: target.height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: width,
                height: height,
                depth: 1
            )
        )
        encoder.endEncoding()
    }

    func encodeDisplay(
        source: any MTLTexture,
        target: any MTLTexture,
        outputRegion: SparseTileOutputRegion,
        parameters: SparseTileSamplingEncodeParameters,
        commandBuffer: any MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor
    ) throws {
        guard source.device.registryID == deviceRegistryID,
              target.device.registryID == deviceRegistryID,
              commandBuffer.commandQueue.device.registryID == deviceRegistryID
        else { throw LayerBlendPipelineError.deviceMismatch }
        guard source.pixelFormat == .rgba16Float,
              source.textureType == .type2D,
              source.width == outputRegion.width,
              source.height == outputRegion.height,
              source.depth == 1,
              source.usage.contains(.shaderRead),
              target.pixelFormat == displayPixelFormat,
              target.textureType == .type2D,
              target.width == outputRegion.width,
              target.height == outputRegion.height,
              target.depth == 1,
              target.sampleCount == 1,
              target.usage.contains(.renderTarget),
              let attachment = renderPassDescriptor.colorAttachments[0],
              attachment.texture === target,
              attachment.loadAction == .clear,
              attachment.storeAction == .store,
              attachment.clearColor.red.isFinite,
              attachment.clearColor.green.isFinite,
              attachment.clearColor.blue.isFinite,
              (0...1).contains(attachment.clearColor.red),
              (0...1).contains(attachment.clearColor.green),
              (0...1).contains(attachment.clearColor.blue),
              attachment.clearColor.alpha == 1
        else { throw LayerBlendPipelineError.invalidTexture }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor
        ) else { throw LayerBlendPipelineError.commandEncoderUnavailable }
        encoder.label = "Bounded Linear Layer Display"
        encoder.setRenderPipelineState(
            parameters.outputMapping.kind == .finiteRadial
                ? radialDisplayState : affineDisplayState
        )
        guard let width = UInt32(exactly: outputRegion.width),
              let height = UInt32(exactly: outputRegion.height)
        else { throw LayerBlendPipelineError.invalidTexture }
        var vertexUniforms = PatternSparseSamplingUniforms()
        vertexUniforms.outputSize = SIMD2(width, height)
        encoder.setVertexBytes(
            &vertexUniforms,
            length: MemoryLayout<PatternSparseSamplingUniforms>.stride,
            index: Int(PatternBufferIndexSparseSamplingUniforms)
        )
        encoder.setFragmentTexture(
            source,
            index: Int(PatternTextureIndexLayerBlendSource)
        )
        if case let .finiteRadial(mapping) = parameters.outputMapping {
            var frames = try SparseTileSamplingRadialFrames.make(
                mapping: mapping,
                outputOrigin: SIMD2(outputRegion.minX, outputRegion.minY),
                outputSize: SIMD2(outputRegion.width, outputRegion.height),
                parameters: parameters
            )
            encoder.setFragmentBytes(
                &frames.grid,
                length: MemoryLayout<PatternGridFrameUniforms>.stride,
                index: Int(PatternBufferIndexGridFrameUniforms)
            )
            encoder.setFragmentBytes(
                &frames.radial,
                length: MemoryLayout<PatternRadialFrameUniforms>.stride,
                index: Int(PatternBufferIndexRadialFrameUniforms)
            )
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}

enum LayerBlendPipeline {
    @MainActor
    static func prepare(
        device: any MTLDevice,
        library: (any MTLLibrary)?,
        abiVersion: UInt16
    ) throws -> LayerBlendPipelineBinding {
        guard abiVersion == LayerBlendABI.version,
              UInt32(abiVersion) == PatternLayerBlendABIVersion
        else {
            throw LayerBlendPipelineError.unsupportedABI(abiVersion)
        }
        guard let library else {
            throw LayerBlendPipelineError.shaderLibraryUnavailable
        }
        guard let blendFunction = library.makeFunction(
            name: "patternLayerBlendKernel"
        ), let interchangePackFunction = library.makeFunction(
            name: "patternLayerInterchangePackKernel"
        ), let displayVertex = library.makeFunction(
            name: "patternSparseSamplingVertex"
        ), let affineDisplayFragment = library.makeFunction(
            name: "patternLayerCompositeDisplayFragment"
        ), let radialDisplayFragment = library.makeFunction(
            name: "patternLayerCompositeRadialDisplayFragment"
        ) else {
            throw LayerBlendPipelineError.shaderFunctionUnavailable
        }
        let blendState: any MTLComputePipelineState
        let interchangePackState: any MTLComputePipelineState
        let affineDisplayState: any MTLRenderPipelineState
        let radialDisplayState: any MTLRenderPipelineState
        do {
            blendState = try device.makeComputePipelineState(
                function: blendFunction
            )
            interchangePackState = try device.makeComputePipelineState(
                function: interchangePackFunction
            )
            func makeDisplayState(
                _ fragment: any MTLFunction
            ) throws -> any MTLRenderPipelineState {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = displayVertex
                descriptor.fragmentFunction = fragment
                descriptor.rasterSampleCount = 1
                let attachment = descriptor.colorAttachments[0]!
                attachment.pixelFormat = DocumentColorPipeline.displayPixelFormat
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: descriptor)
            }
            affineDisplayState = try makeDisplayState(affineDisplayFragment)
            radialDisplayState = try makeDisplayState(radialDisplayFragment)
        } catch {
            throw LayerBlendPipelineError.pipelineCreationFailed
        }
        return LayerBlendPipelineBinding(
            blendState: blendState,
            interchangePackState: interchangePackState,
            affineDisplayState: affineDisplayState,
            radialDisplayState: radialDisplayState,
            displayPixelFormat: DocumentColorPipeline.displayPixelFormat,
            deviceRegistryID: device.registryID
        )
    }
}

private extension LayerBlendMode {
    var layerBlendWireValue: UInt32 {
        switch self {
        case .normal: PatternLayerBlendWireNormal
        case .multiply: PatternLayerBlendWireMultiply
        case .screen: PatternLayerBlendWireScreen
        }
    }
}
