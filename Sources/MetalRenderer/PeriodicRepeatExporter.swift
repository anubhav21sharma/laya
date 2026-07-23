import CShaderTypes
import Foundation
import Metal
import PatternEngine

public struct PeriodicRepeatExport: Equatable, Sendable {
    public let pixelSize: PixelSize
    public let bytesPerRow: Int
    public let bgra8Bytes: [UInt8]

    public init(
        pixelSize: PixelSize,
        bytesPerRow: Int,
        bgra8Bytes: [UInt8]
    ) {
        let (expectedBytesPerRow, rowOverflow) = pixelSize.width
            .multipliedReportingOverflow(by: 4)
        let (expectedByteCount, imageOverflow) = expectedBytesPerRow
            .multipliedReportingOverflow(by: pixelSize.height)
        precondition(
            !rowOverflow && !imageOverflow
                && bytesPerRow == expectedBytesPerRow
                && bgra8Bytes.count == expectedByteCount,
            "PeriodicRepeatExport bytes must be tightly packed BGRA8"
        )
        self.pixelSize = pixelSize
        self.bytesPerRow = bytesPerRow
        self.bgra8Bytes = bgra8Bytes
    }
}

public enum PeriodicRepeatExportError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case unsupportedPreset(SymmetryPresetID)
    case invalidDensity(Int)
    case byteCountOverflow

    public var errorDescription: String? {
        switch self {
        case let .unsupportedPreset(preset):
            "Preset \(preset.rawValue) does not expose a square repeat export."
        case let .invalidDensity(density):
            "Repeat-export density \(density) is outside 64...4096."
        case .byteCountOverflow:
            "Repeat-export storage size overflowed."
        }
    }
}

enum PeriodicRepeatExportInjectedFailure: Equatable {
    case none
    case textureAllocation
    case commandBuffer
    case renderEncoder
}

@MainActor
public extension GridRenderer {
    /// Resolves one half-open square repeat from the committed canonical
    /// raster. Live/replay pixels are deliberately excluded.
    func exportPeriodicRepeat(
        density: Int
    ) throws -> PeriodicRepeatExport {
        try exportPeriodicRepeat(
            density: density,
            injecting: .none
        )
    }
}

@MainActor
extension GridRenderer {
    func exportPeriodicRepeat(
        density: Int,
        injecting failure: PeriodicRepeatExportInjectedFailure
    ) throws -> PeriodicRepeatExport {
        guard periodicConfiguration.presetID.isSquare else {
            throw PeriodicRepeatExportError.unsupportedPreset(tiling)
        }
        guard (64...4_096).contains(density) else {
            throw PeriodicRepeatExportError.invalidDensity(density)
        }

        let (bytesPerRow, rowOverflow) = density.multipliedReportingOverflow(
            by: 4
        )
        let (byteCount, imageOverflow) = bytesPerRow
            .multipliedReportingOverflow(by: density)
        guard !rowOverflow, !imageOverflow else {
            throw PeriodicRepeatExportError.byteCountOverflow
        }

        let pipeline = try makePeriodicRepeatExportPipeline()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: density,
            height: density,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        if failure == .textureAllocation {
            throw MetalRendererError.textureAllocationFailed
        }
        guard let target = device.makeTexture(descriptor: descriptor) else {
            throw MetalRendererError.textureAllocationFailed
        }
        if failure == .commandBuffer {
            throw MetalRendererError.commandBufferUnavailable
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRendererError.commandBufferUnavailable
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        if failure == .renderEncoder {
            throw MetalRendererError.renderEncoderUnavailable
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: pass
        ) else {
            throw MetalRendererError.renderEncoderUnavailable
        }
        encoder.label = "Periodic Square Repeat Export"
        encoder.setRenderPipelineState(pipeline)
        var uniforms = frameUniforms(
            drawableSize: PatternSize(
                width: Float(density),
                height: Float(density)
            ),
            showGridLines: false,
            liveVisible: false
        )
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<PatternGridFrameUniforms>.stride,
            index: Int(PatternBufferIndexGridFrameUniforms)
        )
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<PatternGridFrameUniforms>.stride,
            index: Int(PatternBufferIndexGridFrameUniforms)
        )
        encoder.setFragmentTexture(
            canonical.front,
            index: Int(PatternTextureIndexCanonical)
        )
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 3
        )
        encoder.endEncoding()

        commandBuffer.commit()
        try waitForHarnessCommand(commandBuffer)

        var bytes = [UInt8](repeating: 0, count: byteCount)
        bytes.withUnsafeMutableBytes { storage in
            target.getBytes(
                storage.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, density, density),
                mipmapLevel: 0
            )
        }
        return PeriodicRepeatExport(
            pixelSize: PixelSize(width: density, height: density),
            bytesPerRow: bytesPerRow,
            bgra8Bytes: bytes
        )
    }

    private func makePeriodicRepeatExportPipeline()
        throws -> any MTLRenderPipelineState
    {
        let vertexName = "patternFullscreenVertex"
        let fragmentName = "patternPeriodicRepeatExportFragment"
        guard let vertex = library.makeFunction(name: vertexName) else {
            throw MetalRendererError.shaderFunctionUnavailable(vertexName)
        }
        guard let fragment = library.makeFunction(name: fragmentName) else {
            throw MetalRendererError.shaderFunctionUnavailable(fragmentName)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Periodic Square Repeat Export"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = false
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalRendererError.pipelineCreationFailed(
                error.localizedDescription
            )
        }
    }
}
