import Foundation
import Metal
import PatternEngine

public struct FlattenedSceneExport: Equatable, Sendable {
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

public enum FlattenedSceneExportError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case invalidDimensions(width: Int, height: Int)
    case byteCountOverflow

    public var errorDescription: String? {
        switch self {
        case let .invalidDimensions(width, height):
            "Scene dimensions \(width)x\(height) are outside 64...4096."
        case .byteCountOverflow:
            "Flattened-scene storage size overflowed."
        }
    }
}

@MainActor
public extension GridRenderer {
    /// Flattens the current committed preview viewport without guides, live
    /// pixels, or replay pixels.
    func exportFlattenedScene(
        pixelSize: PixelSize,
        transparentBackground: Bool = false
    ) throws -> FlattenedSceneExport {
        guard (64...4_096).contains(pixelSize.width),
              (64...4_096).contains(pixelSize.height)
        else {
            throw FlattenedSceneExportError.invalidDimensions(
                width: pixelSize.width,
                height: pixelSize.height
            )
        }
        let bytesPerRow = pixelSize.width * 4
        let (byteCount, overflow) = bytesPerRow
            .multipliedReportingOverflow(by: pixelSize.height)
        guard !overflow else {
            throw FlattenedSceneExportError.byteCountOverflow
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: pixelSize.width,
            height: pixelSize.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let target = device.makeTexture(descriptor: descriptor) else {
            throw MetalRendererError.textureAllocationFailed
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRendererError.commandBufferUnavailable
        }
        try encodeDisplay(
            into: target,
            commandBuffer: commandBuffer,
            showGridLines: false,
            liveVisible: false,
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
        return FlattenedSceneExport(
            pixelSize: pixelSize,
            bytesPerRow: bytesPerRow,
            bgra8Bytes: bytes,
            hasTransparentBackground: transparentBackground
        )
    }
}
