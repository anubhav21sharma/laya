import Foundation
import Metal
import PatternEngine

public struct FiniteCanvasExport: Equatable, Sendable {
    public let pixelSize: PixelSize
    public let bytesPerRow: Int
    public let bgra8Bytes: [UInt8]
    public let hasTransparentBackground: Bool

    public init(
        pixelSize: PixelSize,
        bytesPerRow: Int,
        bgra8Bytes: [UInt8],
        hasTransparentBackground: Bool
    ) {
        precondition(bytesPerRow == pixelSize.width * 4)
        precondition(bgra8Bytes.count == bytesPerRow * pixelSize.height)
        self.pixelSize = pixelSize
        self.bytesPerRow = bytesPerRow
        self.bgra8Bytes = bgra8Bytes
        self.hasTransparentBackground = hasTransparentBackground
    }
}

public enum FiniteCanvasExportError: Error, Equatable, LocalizedError, Sendable {
    case periodicDocument
    case byteCountOverflow

    public var errorDescription: String? {
        switch self {
        case .periodicDocument:
            "Full-canvas finite export requires a finite document."
        case .byteCountOverflow:
            "Finite export storage size overflowed."
        }
    }
}

enum FiniteCanvasExportInjectedFailure: Equatable {
    case none
    case textureAllocation
    case commandBuffer
    case renderEncoder
}

@MainActor
public extension GridRenderer {
    /// Resolves the committed finite document at exactly its canvas dimensions.
    /// Live/replay pixels, viewport pan/zoom, and grid guides are excluded.
    func exportFiniteCanvas(
        transparentBackground: Bool = false
    ) throws -> FiniteCanvasExport {
        try exportFiniteCanvas(
            transparentBackground: transparentBackground,
            injecting: .none
        )
    }
}

@MainActor
extension GridRenderer {
    func exportFiniteCanvas(
        transparentBackground: Bool,
        injecting failure: FiniteCanvasExportInjectedFailure
    ) throws -> FiniteCanvasExport {
        guard case .finite = documentConfiguration else {
            throw FiniteCanvasExportError.periodicDocument
        }
        let (bytesPerRow, rowOverflow) = pixelSize.width
            .multipliedReportingOverflow(by: 4)
        let (byteCount, imageOverflow) = bytesPerRow
            .multipliedReportingOverflow(by: pixelSize.height)
        guard !rowOverflow, !imageOverflow else {
            throw FiniteCanvasExportError.byteCountOverflow
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: pixelSize.width,
            height: pixelSize.height,
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
        if failure == .renderEncoder {
            throw MetalRendererError.renderEncoderUnavailable
        }
        try encodeDisplay(
            into: target,
            commandBuffer: commandBuffer,
            showGridLines: false,
            liveVisible: false,
            documentPixelMapping: true,
            transparentBackground: transparentBackground
        )
        commandBuffer.commit()
        try waitForHarnessCommand(commandBuffer)

        var bytes = [UInt8](repeating: 0, count: byteCount)
        bytes.withUnsafeMutableBytes { storage in
            target.getBytes(
                storage.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(
                    0,
                    0,
                    pixelSize.width,
                    pixelSize.height
                ),
                mipmapLevel: 0
            )
        }
        return FiniteCanvasExport(
            pixelSize: pixelSize,
            bytesPerRow: bytesPerRow,
            bgra8Bytes: bytes,
            hasTransparentBackground: transparentBackground
        )
    }
}
