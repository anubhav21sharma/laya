import Foundation
import Metal
import PatternEngine

public enum PeriodicBakedRepeatExportError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case finiteDocument
    case byteCountOverflow
    case inconsistentPeriodicPreset

    public var errorDescription: String? {
        switch self {
        case .finiteDocument:
            "A baked repeat is available only for periodic documents."
        case .byteCountOverflow:
            "Baked-repeat storage size overflowed."
        case .inconsistentPeriodicPreset:
            "The compiled periodic preset has inconsistent export capabilities."
        }
    }
}

@MainActor
public extension GridRenderer {
    /// Resolves one natural-density rectangular repeat unit from committed
    /// pixels for every periodic preset.
    func exportBakedPeriodicRepeat() throws -> PeriodicRepeatExport {
        guard case .periodic = documentConfiguration else {
            throw PeriodicBakedRepeatExportError.finiteDocument
        }
        if tiling.supportsMetricRepeatExport {
            return try exportPeriodicRepeat(
                density: storagePixelSize.width
            )
        }

        let multiplier: (width: Int, height: Int)
        switch tiling {
        case .halfDrop, .mirrorX:
            multiplier = (2, 1)
        case .brick, .mirrorY:
            multiplier = (1, 2)
        case .mirrorXY:
            multiplier = (2, 2)
        case .grid, .rotational:
            multiplier = (1, 1)
        case .squareRotation, .squareKaleidoscope, .hexagons,
             .rotation3, .rotation6, .kaleidoscope60,
             .kaleidoscope30:
            throw PeriodicBakedRepeatExportError.inconsistentPeriodicPreset
        case .plainCanvas, .radialMirror, .radialRotation,
             .radialMandala:
            throw PeriodicBakedRepeatExportError.finiteDocument
        }
        let (width, widthOverflow) = storagePixelSize.width
            .multipliedReportingOverflow(by: multiplier.width)
        let (height, heightOverflow) = storagePixelSize.height
            .multipliedReportingOverflow(by: multiplier.height)
        guard !widthOverflow, !heightOverflow else {
            throw PeriodicBakedRepeatExportError.byteCountOverflow
        }
        let exportSize = PixelSize(width: width, height: height)
        let bytesPerRow = width * 4
        let (byteCount, byteOverflow) = bytesPerRow
            .multipliedReportingOverflow(by: height)
        guard !byteOverflow else {
            throw PeriodicBakedRepeatExportError.byteCountOverflow
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
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
            transparentBackground: true,
            worldCenterOverride: SIMD2(
                Float(width) * 0.5,
                Float(height) * 0.5
            ),
            zoomOverride: 1
        )
        commandBuffer.commit()
        try waitForHarnessCommand(commandBuffer)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        bytes.withUnsafeMutableBytes { storage in
            target.getBytes(
                storage.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        return PeriodicRepeatExport(
            pixelSize: exportSize,
            bytesPerRow: bytesPerRow,
            bgra8Bytes: bytes
        )
    }
}
