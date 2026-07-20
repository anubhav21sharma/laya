import Metal
import MetalRenderer
import PatternEngine
import Testing

@Suite(.serialized)
struct RasterRevisionStoreTests {
    @Test
    func unknownAndStaleReferencesFailWithoutEncoding() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = RasterRevisionStore(device: device)
        let size = PixelSize(width: 64, height: 64)
        let regions = regionSet(size: size)
        let texture = try makeTexture(device: device, size: size)
        let queue = try #require(device.makeCommandQueue())

        let unknown = RasterRevisionReference(
            id: StoredRasterRevisionID(rawValue: 999),
            pixelSize: size,
            regions: regions,
            retainedBytes: 1
        )
        let unknownBuffer = try #require(queue.makeCommandBuffer())
        #expect(throws: MetalRendererError.missingRasterRevision) {
            try store.encodeRestore(unknown, into: texture, on: unknownBuffer)
        }

        let pair = try store.allocatePair(
            beforePixelSize: size,
            beforeRegions: regions,
            afterPixelSize: size,
            afterRegions: regions
        )
        store.discard(pair)
        let staleBuffer = try #require(queue.makeCommandBuffer())
        #expect(throws: MetalRendererError.missingRasterRevision) {
            try store.encodeRestore(pair.before, into: texture, on: staleBuffer)
        }
    }

    @Test
    func textureValidationHappensBeforeCaptureEncoding() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = RasterRevisionStore(device: device)
        let size = PixelSize(width: 64, height: 64)
        let regions = regionSet(size: size)
        let pair = try store.allocatePair(
            beforePixelSize: size,
            beforeRegions: regions,
            afterPixelSize: size,
            afterRegions: regions
        )
        let queue = try #require(device.makeCommandQueue())

        let wrongSize = try makeTexture(
            device: device,
            size: PixelSize(width: 63, height: 64)
        )
        let sizeBuffer = try #require(queue.makeCommandBuffer())
        #expect(
            throws: MetalRendererError.rasterRevisionTextureSizeMismatch(
                expectedWidth: 64,
                expectedHeight: 64,
                actualWidth: 63,
                actualHeight: 64
            )
        ) {
            try store.encodeCapture(pair.before, from: wrongSize, on: sizeBuffer)
        }

        let wrongFormat = try makeTexture(
            device: device,
            size: size,
            pixelFormat: .rgba8Unorm
        )
        let formatBuffer = try #require(queue.makeCommandBuffer())
        #expect(throws: MetalRendererError.invalidRasterRevisionTextureFormat) {
            try store.encodeCapture(
                pair.before,
                from: wrongFormat,
                on: formatBuffer
            )
        }

        store.discard(pair)
    }

    @Test
    func allocationAccountsForEveryAlignedRegionAndNeverReusesIDs() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = RasterRevisionStore(device: device)
        let size = PixelSize(width: 64, height: 64)
        let regions = regionSet(size: size)
        let alignment = device.minimumTextureBufferAlignment(
            for: .bgra8Unorm
        )
        let expected = regions.rectangles.reduce(into: 0) { result, rect in
            result += align(rect.width * 4, to: alignment) * rect.height
        }

        let first = try store.allocatePair(
            beforePixelSize: size,
            beforeRegions: regions,
            afterPixelSize: size,
            afterRegions: regions
        )
        #expect(first.before.retainedBytes == expected)
        #expect(first.after.retainedBytes == expected)
        #expect(first.retainedBytes == expected * 2)
        #expect(store.residentBytes == expected * 2)
        let discardedAfterID = first.after.id.rawValue
        store.discard(first)
        #expect(store.residentBytes == 0)

        let second = try store.allocatePair(
            beforePixelSize: size,
            beforeRegions: regions,
            afterPixelSize: size,
            afterRegions: regions
        )
        #expect(second.before.id.rawValue > discardedAfterID)
        store.discard(second)
    }

    @Test
    func releaseRemovesPublishedIDsAndDefersAnInFlightRevision() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = RasterRevisionStore(device: device)
        let size = PixelSize(width: 64, height: 64)
        let regions = regionSet(size: size)
        let pair = try store.allocatePair(
            beforePixelSize: size,
            beforeRegions: regions,
            afterPixelSize: size,
            afterRegions: regions
        )
        let texture = try makeTexture(device: device, size: size)
        let queue = try #require(device.makeCommandQueue())

        let capture = try #require(queue.makeCommandBuffer())
        try store.encodeCapture(pair.before, from: texture, on: capture)
        try store.encodeCapture(pair.after, from: texture, on: capture)
        capture.commit()
        capture.waitUntilCompleted()
        try requireCompleted(capture)
        store.publish(pair)

        store.release(Set([pair.after.id]))
        #expect(store.residentBytes == pair.before.retainedBytes)
        let missingAfter = try #require(queue.makeCommandBuffer())
        #expect(throws: MetalRendererError.missingRasterRevision) {
            try store.encodeRestore(
                pair.after,
                into: texture,
                on: missingAfter
            )
        }

        let restore = try #require(queue.makeCommandBuffer())
        try store.encodeRestore(pair.before, into: texture, on: restore)
        store.release(Set([pair.before.id]))
        #expect(store.residentBytes == pair.before.retainedBytes)
        let logicallyReleased = try #require(queue.makeCommandBuffer())
        #expect(throws: MetalRendererError.missingRasterRevision) {
            try store.encodeRestore(
                pair.before,
                into: texture,
                on: logicallyReleased
            )
        }
        restore.commit()
        restore.waitUntilCompleted()
        try requireCompleted(restore)
        #expect(store.residentBytes == 0)

        let staleBefore = try #require(queue.makeCommandBuffer())
        #expect(throws: MetalRendererError.missingRasterRevision) {
            try store.encodeRestore(
                pair.before,
                into: texture,
                on: staleBefore
            )
        }
    }

    @Test
    func captureAndRestoreOnlyChangeTheSeparatedRegions() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = RasterRevisionStore(device: device)
        let size = PixelSize(width: 64, height: 64)
        let regions = regionSet(size: size)
        let texture = try makeTexture(device: device, size: size)
        let queue = try #require(device.makeCommandQueue())
        let original = deterministicBytes(size: size)
        let overwritten = [UInt8](
            repeating: 0xA7,
            count: size.width * size.height * 4
        )
        replace(texture: texture, bytes: original, size: size)

        let pair = try store.allocatePair(
            beforePixelSize: size,
            beforeRegions: regions,
            afterPixelSize: size,
            afterRegions: regions
        )
        let capture = try #require(queue.makeCommandBuffer())
        try store.encodeCapture(pair.before, from: texture, on: capture)
        try store.encodeCapture(pair.after, from: texture, on: capture)
        capture.commit()
        capture.waitUntilCompleted()
        try requireCompleted(capture)
        store.publish(pair)

        replace(texture: texture, bytes: overwritten, size: size)
        let restore = try #require(queue.makeCommandBuffer())
        try store.encodeRestore(pair.before, into: texture, on: restore)
        restore.commit()
        restore.waitUntilCompleted()
        try requireCompleted(restore)

        let actual = read(texture: texture, size: size)
        for y in 0..<size.height {
            for x in 0..<size.width {
                let offset = (y * size.width + x) * 4
                let isRestored = regions.rectangles.contains {
                    x >= $0.minX && x < $0.maxX
                        && y >= $0.minY && y < $0.maxY
                }
                let expected = isRestored ? original : overwritten
                #expect(
                    Array(actual[offset..<(offset + 4)])
                        == Array(expected[offset..<(offset + 4)]),
                    "Mismatch at (\(x), \(y))"
                )
            }
        }

        store.release(Set([pair.before.id, pair.after.id]))
    }
}

private func regionSet(size: PixelSize) -> PixelRegionSet {
    PixelRegionSet(
        [
            PixelRect(minX: 3, minY: 5, maxX: 12, maxY: 13)!,
            PixelRect(minX: 31, minY: 27, maxX: 47, maxY: 39)!,
        ],
        clippedTo: size
    )
}

private func align(_ value: Int, to alignment: Int) -> Int {
    ((value + alignment - 1) / alignment) * alignment
}

private func makeTexture(
    device: any MTLDevice,
    size: PixelSize,
    pixelFormat: MTLPixelFormat = .bgra8Unorm
) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: pixelFormat,
        width: size.width,
        height: size.height,
        mipmapped: false
    )
    descriptor.storageMode = .shared
    return try #require(device.makeTexture(descriptor: descriptor))
}

private func deterministicBytes(size: PixelSize) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: size.width * size.height * 4)
    for y in 0..<size.height {
        for x in 0..<size.width {
            let offset = (y * size.width + x) * 4
            bytes[offset] = UInt8(truncatingIfNeeded: x &* 13 &+ y)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: y &* 17 &+ x)
            bytes[offset + 2] = UInt8(truncatingIfNeeded: x ^ y)
            bytes[offset + 3] = 255
        }
    }
    return bytes
}

private func replace(
    texture: any MTLTexture,
    bytes: [UInt8],
    size: PixelSize
) {
    bytes.withUnsafeBytes {
        texture.replace(
            region: MTLRegionMake2D(0, 0, size.width, size.height),
            mipmapLevel: 0,
            withBytes: $0.baseAddress!,
            bytesPerRow: size.width * 4
        )
    }
}

private func read(texture: any MTLTexture, size: PixelSize) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: size.width * size.height * 4)
    bytes.withUnsafeMutableBytes {
        texture.getBytes(
            $0.baseAddress!,
            bytesPerRow: size.width * 4,
            from: MTLRegionMake2D(0, 0, size.width, size.height),
            mipmapLevel: 0
        )
    }
    return bytes
}

private func requireCompleted(_ commandBuffer: any MTLCommandBuffer) throws {
    #expect(commandBuffer.status == .completed)
    if let error = commandBuffer.error {
        Issue.record("Metal command buffer failed: \(error)")
        throw error
    }
}
