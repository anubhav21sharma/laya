import Foundation
import Metal
import PatternEngine

public struct CommittedRadialPagePixels: Equatable, Sendable {
    public let coordinate: RadialPageCoordinate
    public let bgra8PremultipliedBytes: [UInt8]

    public init(
        coordinate: RadialPageCoordinate,
        bgra8PremultipliedBytes: [UInt8]
    ) {
        self.coordinate = coordinate
        self.bgra8PremultipliedBytes = bgra8PremultipliedBytes
    }
}

public enum CommittedRasterStorage: Equatable, Sendable {
    case singleRaster(bgra8PremultipliedBytes: [UInt8])
    case radialPages([CommittedRadialPagePixels])
}

public struct CommittedDocumentSnapshot: Equatable, Sendable {
    public let canvasSize: PixelSize
    public let documentConfiguration: SymmetryDocumentConfiguration
    public let radialGeometryLocked: Bool
    public let storage: CommittedRasterStorage

    public init(
        canvasSize: PixelSize,
        documentConfiguration: SymmetryDocumentConfiguration,
        radialGeometryLocked: Bool,
        storage: CommittedRasterStorage
    ) {
        self.canvasSize = canvasSize
        self.documentConfiguration = documentConfiguration
        self.radialGeometryLocked = radialGeometryLocked
        self.storage = storage
    }
}

@MainActor
public extension GridRenderer {
    convenience init(
        device: any MTLDevice,
        drawableSize: PatternSize,
        committedSnapshot: CommittedDocumentSnapshot
    ) throws {
        guard let library = device.makeDefaultLibrary() else {
            throw MetalRendererError.defaultLibraryUnavailable
        }
        try self.init(
            device: device,
            library: library,
            drawableSize: drawableSize,
            committedSnapshot: committedSnapshot
        )
    }

    convenience init(
        device: any MTLDevice,
        library: any MTLLibrary,
        drawableSize: PatternSize,
        committedSnapshot: CommittedDocumentSnapshot
    ) throws {
        let configuration = try TilingCanvasConfiguration(
            pixelSize: committedSnapshot.canvasSize,
            documentConfiguration:
                committedSnapshot.documentConfiguration
        )
        try self.init(
            device: device,
            library: library,
            drawableSize: drawableSize,
            configuration: configuration
        )
        try installCommittedSnapshot(committedSnapshot)
    }

    /// Captures committed canonical storage only. An active uncommitted
    /// stroke is deliberately excluded.
    func captureCommittedDocument() throws -> CommittedDocumentSnapshot {
        guard pendingRasterOperation == nil,
              activeStroke?.isCommitSubmitted != true
        else {
            throw MetalRendererError.committedSnapshotUnavailable
        }
        let bytes = try copyCommittedCanonicalBytes()
        let storage: CommittedRasterStorage
        if let layout = tilingStrategy.compiledSymmetry.domain.finite?
            .radial.layout
        {
            let pageByteCount =
                RadialSectorLayout.pageSide
                * RadialSectorLayout.pageSide
                * 4
            var pages: [CommittedRadialPagePixels] = []
            pages.reserveCapacity(layout.residentPages.count)
            for page in layout.residentPages {
                let pageBytes = extractPage(
                    page,
                    layout: layout,
                    atlasBytes: bytes
                )
                precondition(pageBytes.count == pageByteCount)
                if pageBytes.contains(where: { $0 != 0 }) {
                    pages.append(CommittedRadialPagePixels(
                        coordinate: page.coordinate,
                        bgra8PremultipliedBytes: pageBytes
                    ))
                }
            }
            storage = .radialPages(pages)
        } else {
            storage = .singleRaster(
                bgra8PremultipliedBytes: bytes
            )
        }
        return CommittedDocumentSnapshot(
            canvasSize: pixelSize,
            documentConfiguration: documentConfiguration,
            radialGeometryLocked: radialGeometryLocked,
            storage: storage
        )
    }
}

@MainActor
private extension GridRenderer {
    func installCommittedSnapshot(
        _ snapshot: CommittedDocumentSnapshot
    ) throws {
        guard snapshot.canvasSize == pixelSize,
              snapshot.documentConfiguration == documentConfiguration
        else {
            throw MetalRendererError.committedSnapshotIncompatible
        }
        let bytes: [UInt8]
        switch snapshot.storage {
        case let .singleRaster(single):
            guard tilingStrategy.compiledSymmetry.domain.finite?
                    .radial.layout == nil,
                  single.count
                    == storagePixelSize.width
                        * storagePixelSize.height
                        * 4
            else {
                throw MetalRendererError.committedSnapshotIncompatible
            }
            bytes = single
        case let .radialPages(pages):
            guard let layout = tilingStrategy.compiledSymmetry.domain
                .finite?.radial.layout
            else {
                throw MetalRendererError.committedSnapshotIncompatible
            }
            let pageByteCount =
                RadialSectorLayout.pageSide
                * RadialSectorLayout.pageSide
                * 4
            let allowed = Set(layout.residentPages.map(\.coordinate))
            var coordinates = Set<RadialPageCoordinate>()
            var atlas = [UInt8](
                repeating: 0,
                count: storagePixelSize.width
                    * storagePixelSize.height
                    * 4
            )
            for page in pages {
                guard page.bgra8PremultipliedBytes.count
                        == pageByteCount,
                      coordinates.insert(page.coordinate).inserted,
                      allowed.contains(page.coordinate),
                      let resident = layout.residentPage(
                          at: page.coordinate
                      )
                else {
                    throw MetalRendererError
                        .committedSnapshotIncompatible
                }
                insertPage(
                    page.bgra8PremultipliedBytes,
                    resident: resident,
                    layout: layout,
                    atlasBytes: &atlas
                )
            }
            if !snapshot.radialGeometryLocked,
               atlas.contains(where: { $0 != 0 })
            {
                throw MetalRendererError.committedSnapshotIncompatible
            }
            bytes = atlas
        }
        if snapshot.radialGeometryLocked,
           tilingStrategy.compiledSymmetry.domain.finite?
            .radial.layout == nil
        {
            throw MetalRendererError.committedSnapshotIncompatible
        }
        try uploadCommittedCanonicalBytes(bytes)
        radialGeometryLocked = snapshot.radialGeometryLocked
        documentDomainLocked =
            snapshot.radialGeometryLocked
            || bytes.contains(where: { $0 != 0 })
    }

    func copyCommittedCanonicalBytes() throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: storagePixelSize.width,
            height: storagePixelSize.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let staging = device.makeTexture(descriptor: descriptor) else {
            throw MetalRendererError.textureAllocationFailed
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRendererError.commandBufferUnavailable
        }
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw MetalRendererError.commandFailed(
                "Committed snapshot blit encoder creation failed."
            )
        }
        encoder.label = "Capture Committed Document"
        encoder.copy(
            from: canonical.front,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width: storagePixelSize.width,
                height: storagePixelSize.height,
                depth: 1
            ),
            to: staging,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        try waitForHarnessCommand(commandBuffer)

        let bytesPerRow = storagePixelSize.width * 4
        var bytes = [UInt8](
            repeating: 0,
            count: bytesPerRow * storagePixelSize.height
        )
        bytes.withUnsafeMutableBytes { storage in
            staging.getBytes(
                storage.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(
                    0,
                    0,
                    storagePixelSize.width,
                    storagePixelSize.height
                ),
                mipmapLevel: 0
            )
        }
        return bytes
    }

    func uploadCommittedCanonicalBytes(
        _ bytes: [UInt8]
    ) throws {
        let bytesPerRow = storagePixelSize.width * 4
        guard bytes.count == bytesPerRow * storagePixelSize.height else {
            throw MetalRendererError.committedSnapshotIncompatible
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: storagePixelSize.width,
            height: storagePixelSize.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let staging = device.makeTexture(descriptor: descriptor) else {
            throw MetalRendererError.textureAllocationFailed
        }
        bytes.withUnsafeBytes { storage in
            staging.replace(
                region: MTLRegionMake2D(
                    0,
                    0,
                    storagePixelSize.width,
                    storagePixelSize.height
                ),
                mipmapLevel: 0,
                withBytes: storage.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRendererError.commandBufferUnavailable
        }
        try encodeResizeIntersectionCopy(
            from: staging,
            oldPixelSize: storagePixelSize,
            to: canonical.front,
            newPixelSize: storagePixelSize,
            on: commandBuffer
        )
        commandBuffer.commit()
        try waitForHarnessCommand(commandBuffer)
    }

    func extractPage(
        _ page: RadialResidentPage,
        layout: RadialSectorLayout,
        atlasBytes: [UInt8]
    ) -> [UInt8] {
        let side = RadialSectorLayout.pageSide
        let atlasX = page.atlasSlot % layout.atlasColumns
        let atlasY = page.atlasSlot / layout.atlasColumns
        let atlasBytesPerRow = layout.atlasPixelSize.width * 4
        let pageBytesPerRow = side * 4
        var result = [UInt8](
            repeating: 0,
            count: pageBytesPerRow * side
        )
        for row in 0..<side {
            let source =
                (atlasY * side + row) * atlasBytesPerRow
                + atlasX * pageBytesPerRow
            let destination = row * pageBytesPerRow
            result.replaceSubrange(
                destination..<(destination + pageBytesPerRow),
                with: atlasBytes[source..<(source + pageBytesPerRow)]
            )
        }
        return result
    }

    func insertPage(
        _ pageBytes: [UInt8],
        resident: RadialResidentPage,
        layout: RadialSectorLayout,
        atlasBytes: inout [UInt8]
    ) {
        let side = RadialSectorLayout.pageSide
        let atlasX = resident.atlasSlot % layout.atlasColumns
        let atlasY = resident.atlasSlot / layout.atlasColumns
        let atlasBytesPerRow = layout.atlasPixelSize.width * 4
        let pageBytesPerRow = side * 4
        for row in 0..<side {
            let source = row * pageBytesPerRow
            let destination =
                (atlasY * side + row) * atlasBytesPerRow
                + atlasX * pageBytesPerRow
            atlasBytes.replaceSubrange(
                destination..<(destination + pageBytesPerRow),
                with: pageBytes[source..<(source + pageBytesPerRow)]
            )
        }
    }
}
