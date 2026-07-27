import Foundation
@preconcurrency import Metal

enum BrushTextureUploadPhase:
    String, CaseIterable, Equatable, Sendable
{
    case beforeTextureAllocation
    case beforeStagingAllocation
    case beforeCommandBufferCreation
    case beforeEncoderCreation
    case afterCompletion
}

enum BrushTextureUploadError: Error, Equatable, Sendable {
    case invalidDimensions(resourceID: String, width: Int, height: Int)
    case invalidAlignment(resourceID: String, alignment: Int)
    case invalidMipCount(resourceID: String, expected: Int, actual: Int)
    case invalidMipByteCount(
        resourceID: String,
        level: Int,
        expected: Int,
        actual: Int
    )
    case residentByteCountMismatch(
        resourceID: String,
        expected: Int,
        actual: Int
    )
    case storageOverflow(resourceID: String)
    case textureAllocationFailed(resourceID: String)
    case stagingAllocationFailed(resourceID: String, requestedBytes: Int)
    case commandBufferCreationFailed(resourceID: String)
    case blitEncoderCreationFailed(resourceID: String)
    case commandBufferFailed(
        resourceID: String,
        status: Int,
        errorCode: Int?
    )
    case injectedFailure(
        resourceID: String,
        phase: BrushTextureUploadPhase
    )
}

struct BrushTextureUploadLayout: Equatable, Sendable {
    struct Slice: Equatable, Sendable {
        let level: Int
        let width: Int
        let height: Int
        let bufferOffset: Int
        let bytesPerRow: Int
        let bytesPerImage: Int
    }

    let slices: [Slice]
    let stagingByteCount: Int

    static func make(
        resourceID: String = "resource",
        width: Int,
        height: Int,
        mipLevelByteCounts: [Int],
        alignment: Int
    ) throws -> Self {
        guard width > 0, height > 0 else {
            throw BrushTextureUploadError.invalidDimensions(
                resourceID: resourceID,
                width: width,
                height: height
            )
        }
        guard alignment > 0 else {
            throw BrushTextureUploadError.invalidAlignment(
                resourceID: resourceID,
                alignment: alignment
            )
        }

        var dimensions: [(width: Int, height: Int)] = []
        var mipWidth = width
        var mipHeight = height
        while true {
            dimensions.append((mipWidth, mipHeight))
            guard mipWidth > 1 || mipHeight > 1 else { break }
            mipWidth = max(1, mipWidth / 2)
            mipHeight = max(1, mipHeight / 2)
        }
        guard dimensions.count == mipLevelByteCounts.count else {
            throw BrushTextureUploadError.invalidMipCount(
                resourceID: resourceID,
                expected: dimensions.count,
                actual: mipLevelByteCounts.count
            )
        }

        var slices: [Slice] = []
        slices.reserveCapacity(dimensions.count)
        var offset = 0
        for (level, dimension) in dimensions.enumerated() {
            let (expectedBytes, pixelOverflow) =
                dimension.width.multipliedReportingOverflow(
                    by: dimension.height
                )
            guard !pixelOverflow else {
                throw BrushTextureUploadError.storageOverflow(
                    resourceID: resourceID
                )
            }
            let actualBytes = mipLevelByteCounts[level]
            guard actualBytes == expectedBytes else {
                throw BrushTextureUploadError.invalidMipByteCount(
                    resourceID: resourceID,
                    level: level,
                    expected: expectedBytes,
                    actual: actualBytes
                )
            }

            let alignedOffset = try checkedAlign(
                offset,
                alignment: alignment,
                resourceID: resourceID
            )
            let bytesPerRow = try checkedAlign(
                dimension.width,
                alignment: alignment,
                resourceID: resourceID
            )
            let (bytesPerImage, imageOverflow) =
                bytesPerRow.multipliedReportingOverflow(by: dimension.height)
            guard !imageOverflow else {
                throw BrushTextureUploadError.storageOverflow(
                    resourceID: resourceID
                )
            }
            let (nextOffset, offsetOverflow) =
                alignedOffset.addingReportingOverflow(bytesPerImage)
            guard !offsetOverflow else {
                throw BrushTextureUploadError.storageOverflow(
                    resourceID: resourceID
                )
            }
            slices.append(
                Slice(
                    level: level,
                    width: dimension.width,
                    height: dimension.height,
                    bufferOffset: alignedOffset,
                    bytesPerRow: bytesPerRow,
                    bytesPerImage: bytesPerImage
                )
            )
            offset = nextOffset
        }
        return Self(slices: slices, stagingByteCount: offset)
    }

    private static func checkedAlign(
        _ value: Int,
        alignment: Int,
        resourceID: String
    ) throws -> Int {
        let (biased, overflow) = value.addingReportingOverflow(alignment - 1)
        guard !overflow else {
            throw BrushTextureUploadError.storageOverflow(
                resourceID: resourceID
            )
        }
        let quotient = biased / alignment
        let (aligned, multiplyOverflow) =
            quotient.multipliedReportingOverflow(by: alignment)
        guard !multiplyOverflow else {
            throw BrushTextureUploadError.storageOverflow(
                resourceID: resourceID
            )
        }
        return aligned
    }
}

@MainActor
struct BrushTextureUploader {
    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let injectedFailure: BrushTextureUploadPhase?

    init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        injectedFailure: BrushTextureUploadPhase? = nil
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.injectedFailure = injectedFailure
    }

    func upload(
        _ decoded: DecodedBrushTexture
    ) async throws -> any MTLTexture {
        let alignment = device.minimumTextureBufferAlignment(for: .r8Unorm)
        let layout = try BrushTextureUploadLayout.make(
            resourceID: decoded.resourceID,
            width: decoded.workingWidth,
            height: decoded.workingHeight,
            mipLevelByteCounts: decoded.mipLevels.map(\.count),
            alignment: alignment
        )
        let mipByteCount = try checkedMipByteCount(decoded)
        guard decoded.residentByteCount == mipByteCount else {
            throw BrushTextureUploadError.residentByteCountMismatch(
                resourceID: decoded.resourceID,
                expected: mipByteCount,
                actual: decoded.residentByteCount
            )
        }

        try Task.checkCancellation()
        try failIfInjected(.beforeTextureAllocation, id: decoded.resourceID)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: decoded.workingWidth,
            height: decoded.workingHeight,
            mipmapped: true
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw BrushTextureUploadError.textureAllocationFailed(
                resourceID: decoded.resourceID
            )
        }
        texture.label = "Compiled brush \(decoded.resourceID)"

        try Task.checkCancellation()
        try failIfInjected(.beforeStagingAllocation, id: decoded.resourceID)
        guard let staging = device.makeBuffer(
            length: layout.stagingByteCount,
            options: .storageModeShared
        ) else {
            throw BrushTextureUploadError.stagingAllocationFailed(
                resourceID: decoded.resourceID,
                requestedBytes: layout.stagingByteCount
            )
        }
        staging.label = "Brush upload \(decoded.resourceID)"
        copy(decoded.mipLevels, layout: layout, into: staging)

        try Task.checkCancellation()
        try failIfInjected(.beforeCommandBufferCreation, id: decoded.resourceID)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw BrushTextureUploadError.commandBufferCreationFailed(
                resourceID: decoded.resourceID
            )
        }
        commandBuffer.label = "Upload brush \(decoded.resourceID)"
        try failIfInjected(.beforeEncoderCreation, id: decoded.resourceID)
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw BrushTextureUploadError.blitEncoderCreationFailed(
                resourceID: decoded.resourceID
            )
        }
        encoder.label = "Upload brush mips"
        for slice in layout.slices {
            encoder.copy(
                from: staging,
                sourceOffset: slice.bufferOffset,
                sourceBytesPerRow: slice.bytesPerRow,
                sourceBytesPerImage: slice.bytesPerImage,
                sourceSize: MTLSize(
                    width: slice.width,
                    height: slice.height,
                    depth: 1
                ),
                to: texture,
                destinationSlice: 0,
                destinationLevel: slice.level,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
        }
        encoder.endEncoding()
        try Task.checkCancellation()
        try await completion(
            commandBuffer,
            retaining: texture,
            staging: staging,
            resourceID: decoded.resourceID
        )
        try failIfInjected(.afterCompletion, id: decoded.resourceID)
        try Task.checkCancellation()
        return texture
    }

    private func checkedMipByteCount(
        _ decoded: DecodedBrushTexture
    ) throws -> Int {
        var total = 0
        for level in decoded.mipLevels {
            let (next, overflow) = total.addingReportingOverflow(level.count)
            guard !overflow else {
                throw BrushTextureUploadError.storageOverflow(
                    resourceID: decoded.resourceID
                )
            }
            total = next
        }
        return total
    }

    private func failIfInjected(
        _ phase: BrushTextureUploadPhase,
        id: String
    ) throws {
        guard injectedFailure == phase else { return }
        throw BrushTextureUploadError.injectedFailure(
            resourceID: id,
            phase: phase
        )
    }

    private func copy(
        _ mipLevels: [Data],
        layout: BrushTextureUploadLayout,
        into buffer: any MTLBuffer
    ) {
        let destination = buffer.contents()
            .assumingMemoryBound(to: UInt8.self)
        for (data, slice) in zip(mipLevels, layout.slices) {
            data.withUnsafeBytes { bytes in
                guard let source = bytes.baseAddress?
                    .assumingMemoryBound(to: UInt8.self)
                else { return }
                for row in 0..<slice.height {
                    destination
                        .advanced(
                            by: slice.bufferOffset + row * slice.bytesPerRow
                        )
                        .update(
                            from: source.advanced(by: row * slice.width),
                            count: slice.width
                        )
                }
            }
        }
    }

    private func completion(
        _ commandBuffer: any MTLCommandBuffer,
        retaining texture: any MTLTexture,
        staging: any MTLBuffer,
        resourceID: String
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            commandBuffer.addCompletedHandler { completed in
                // Explicitly retain every submitted resource until Metal has
                // finished consuming the owned staging allocation.
                _ = texture
                _ = staging
                if completed.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: BrushTextureUploadError.commandBufferFailed(
                            resourceID: resourceID,
                            status: Int(completed.status.rawValue),
                            errorCode: (completed.error as NSError?)?.code
                        )
                    )
                }
            }
            commandBuffer.commit()
        }
    }
}
