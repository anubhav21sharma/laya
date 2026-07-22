import Metal
import PatternEngine

public enum BoundedWashWorkingTexture: Int, CaseIterable, Sendable {
    case deposit
    case scratch
}

public enum BoundedWashSurfaceError: Error, Equatable, Sendable {
    case invalidBleedRadius
    case softenPassLimitExceeded(Int)
    case textureAllocationFailed(BoundedWashWorkingTexture)
    case regionBufferAllocationFailed
    case regionCountExceeded(Int)
}

/// Pixel work performed by one bounded-wash update.
///
/// Deposition touches only the newly dirty pixels. Local soften passes and the
/// final resolve touch the dirty pixels plus the validated material halo. The
/// metric intentionally has no settled-stroke input, so old stroke length
/// cannot increase the work reported for a new update.
public struct BoundedWashWorkPlan: Equatable, Sendable {
    public let depositionRegions: PixelRegionSet
    public let processingRegions: PixelRegionSet
    public let haloPixels: Int
    public let softenPasses: Int
    public let usedFullTileRegionDegradation: Bool
    public let depositionPixelCount: Int
    public let localPassPixelCount: Int
    public let resolvePixelCount: Int

    public var processedPixelCount: Int {
        depositionPixelCount + localPassPixelCount + resolvePixelCount
    }

    init(
        depositionRegions: PixelRegionSet,
        processingRegions: PixelRegionSet,
        haloPixels: Int,
        softenPasses: Int,
        usedFullTileRegionDegradation: Bool
    ) {
        self.depositionRegions = depositionRegions
        self.processingRegions = processingRegions
        self.haloPixels = haloPixels
        self.softenPasses = softenPasses
        self.usedFullTileRegionDegradation = usedFullTileRegionDegradation
        depositionPixelCount = Self.area(of: depositionRegions)
        let processingPixelCount = Self.area(of: processingRegions)
        localPassPixelCount = processingPixelCount * softenPasses
        resolvePixelCount = processingPixelCount
    }

    private static func area(of regions: PixelRegionSet) -> Int {
        regions.rectangles.reduce(into: 0) { total, rectangle in
            total += rectangle.width * rectangle.height
        }
    }
}

/// Work for wash passes that were actually encoded for the active stroke.
/// Keeping the stages separate prevents evidence from substituting a static
/// texture-size estimate for the local GPU work that was submitted.
public struct BoundedWashEncodedWork: Equatable, Sendable {
    public private(set) var updateCount = 0
    public private(set) var depositionPixelCount = 0
    public private(set) var localPassPixelCount = 0
    public private(set) var resolvePixelCount = 0

    public init() {}

    public var processedPixelCount: Int {
        depositionPixelCount + localPassPixelCount + resolvePixelCount
    }

    mutating func record(_ plan: BoundedWashWorkPlan) {
        updateCount += 1
        depositionPixelCount += plan.depositionPixelCount
        localPassPixelCount += plan.localPassPixelCount
        resolvePixelCount += plan.resolvePixelCount
    }
}

/// Per-stroke history coverage for wash halos. This mirrors LiveStroke's
/// metadata cap and falls back to one full-tile rectangle rather than growing
/// with stroke length.
struct BoundedWashHistoryAccumulator: Equatable, Sendable {
    static let maximumRetainedRectangleCount = 256

    private(set) var rectangles: [PixelRect] = []
    private(set) var usesFullTile = false

    mutating func record(_ regions: PixelRegionSet, pixelSize: PixelSize) {
        guard !usesFullTile else { return }
        let combined = PixelRegionSet(
            rectangles + regions.rectangles,
            clippedTo: pixelSize
        )
        if combined.rectangles.count > Self.maximumRetainedRectangleCount {
            rectangles.removeAll(keepingCapacity: true)
            usesFullTile = true
        } else {
            rectangles = combined.rectangles
        }
    }

    func regions(pixelSize: PixelSize) -> PixelRegionSet {
        if usesFullTile {
            return PixelRegionSet(
                [
                    PixelRect(
                        minX: 0,
                        minY: 0,
                        maxX: pixelSize.width,
                        maxY: pixelSize.height
                    )!,
                ],
                clippedTo: pixelSize
            )
        }
        return PixelRegionSet(rectangles, clippedTo: pixelSize)
    }
}

/// Fixed working state for the bounded-wash material.
///
/// Exactly two private RGBA16Float textures are allocated with canonical-tile
/// dimensions and reused for the surface lifetime. Work planning is CPU-only
/// and performs no allocation of Metal resources.
@MainActor
public final class BoundedWashSurface {
    public static let pixelFormat: MTLPixelFormat = .rgba16Float
    public static let maximumSoftenPasses = 2
    public static let maximumHaloPixels = 32
    public static let workingTextureCount = 2
    public static let bytesPerPixel = 8
    /// One retained live stroke can contribute at most 256 dirty rectangles;
    /// wrapping across both axes can split each into four canonical regions.
    static let maximumProcessingRegionCount = 1_024

    public let pixelSize: PixelSize
    public let depositTexture: any MTLTexture
    public let scratchTexture: any MTLTexture
    private let processingRegionBuffers: [any MTLBuffer]

    public var workingByteCount: Int {
        pixelSize.width * pixelSize.height
            * Self.bytesPerPixel * Self.workingTextureCount
    }

    /// `injectedAllocationFailure` is a deterministic diagnostic hook. It is
    /// also used by renderer failure tests to verify that setup failure occurs
    /// before any canonical or history state can be mutated.
    public init(
        device: any MTLDevice,
        pixelSize: PixelSize,
        injectedAllocationFailure: BoundedWashWorkingTexture? = nil
    ) throws {
        self.pixelSize = pixelSize

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat,
            width: pixelSize.width,
            height: pixelSize.height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]

        depositTexture = try Self.allocate(
            .deposit,
            device: device,
            descriptor: descriptor,
            injectedFailure: injectedAllocationFailure
        )
        depositTexture.label = "Bounded Wash Deposit"

        scratchTexture = try Self.allocate(
            .scratch,
            device: device,
            descriptor: descriptor,
            injectedFailure: injectedAllocationFailure
        )
        scratchTexture.label = "Bounded Wash Scratch"

        var regionBuffers: [any MTLBuffer] = []
        regionBuffers.reserveCapacity(GridCanvasContract.inFlightBufferCount)
        for slot in 0..<GridCanvasContract.inFlightBufferCount {
            guard let buffer = device.makeBuffer(
                length: Self.maximumProcessingRegionCount
                    * MemoryLayout<SIMD4<Int32>>.stride,
                options: .storageModeShared
            ) else {
                throw BoundedWashSurfaceError.regionBufferAllocationFailed
            }
            buffer.label = "Bounded Wash Regions \(slot)"
            regionBuffers.append(buffer)
        }
        processingRegionBuffers = regionBuffers
    }

    public func makeWorkPlan(
        dirtyRegions: [PixelRect],
        bleedRadius: Float,
        softenPasses: Int
    ) throws -> BoundedWashWorkPlan {
        guard bleedRadius.isFinite,
              bleedRadius >= 0,
              bleedRadius <= Float(Self.maximumHaloPixels)
        else {
            throw BoundedWashSurfaceError.invalidBleedRadius
        }
        guard (0...Self.maximumSoftenPasses).contains(softenPasses) else {
            throw BoundedWashSurfaceError.softenPassLimitExceeded(
                softenPasses
            )
        }

        let haloPixels = Int(ceil(bleedRadius))
        var depositionRegions = wrapped(
            dirtyRegions,
            expansion: 0
        )
        var processingRegions = wrapped(
            dirtyRegions,
            expansion: haloPixels
        )
        let exceededRegionCap =
            depositionRegions.rectangles.count
                > Self.maximumProcessingRegionCount
            || processingRegions.rectangles.count
                > Self.maximumProcessingRegionCount
        if exceededRegionCap {
            let fullTile = PixelRegionSet(
                [
                    PixelRect(
                        minX: 0,
                        minY: 0,
                        maxX: pixelSize.width,
                        maxY: pixelSize.height
                    )!,
                ],
                clippedTo: pixelSize
            )
            depositionRegions = fullTile
            processingRegions = fullTile
        }
        return BoundedWashWorkPlan(
            depositionRegions: depositionRegions,
            processingRegions: processingRegions,
            haloPixels: haloPixels,
            softenPasses: softenPasses,
            usedFullTileRegionDegradation: exceededRegionCap
        )
    }

    /// Writes the canonical processing mask into the metadata slot paired
    /// with an in-flight dab lease. Pairing the slots prevents a later frame
    /// from changing region membership while the GPU still reads it.
    func prepareProcessingRegions(
        _ regions: PixelRegionSet,
        slot: Int
    ) throws -> (buffer: any MTLBuffer, count: Int) {
        guard regions.rectangles.count <= Self.maximumProcessingRegionCount
        else {
            throw BoundedWashSurfaceError.regionCountExceeded(
                regions.rectangles.count
            )
        }
        precondition(processingRegionBuffers.indices.contains(slot))
        let buffer = processingRegionBuffers[slot]
        let destination = buffer.contents().bindMemory(
            to: SIMD4<Int32>.self,
            capacity: Self.maximumProcessingRegionCount
        )
        for (index, rectangle) in regions.rectangles.enumerated() {
            destination[index] = SIMD4(
                Int32(rectangle.minX),
                Int32(rectangle.minY),
                Int32(rectangle.maxX),
                Int32(rectangle.maxY)
            )
        }
        return (buffer, regions.rectangles.count)
    }

    private static func allocate(
        _ workingTexture: BoundedWashWorkingTexture,
        device: any MTLDevice,
        descriptor: MTLTextureDescriptor,
        injectedFailure: BoundedWashWorkingTexture?
    ) throws -> any MTLTexture {
        guard injectedFailure != workingTexture,
              let texture = device.makeTexture(descriptor: descriptor)
        else {
            throw BoundedWashSurfaceError.textureAllocationFailed(
                workingTexture
            )
        }
        return texture
    }

    private func wrapped(
        _ dirtyRegions: [PixelRect],
        expansion: Int
    ) -> PixelRegionSet {
        let rectangles = dirtyRegions.flatMap { rectangle in
            Self.wrapped(
                rectangle,
                expansion: expansion,
                pixelSize: pixelSize
            )
        }
        return PixelRegionSet(rectangles, clippedTo: pixelSize)
    }

    private static func wrapped(
        _ rectangle: PixelRect,
        expansion: Int,
        pixelSize: PixelSize
    ) -> [PixelRect] {
        let xIntervals = wrappedIntervals(
            minimum: rectangle.minX - expansion,
            maximum: rectangle.maxX + expansion,
            extent: pixelSize.width
        )
        let yIntervals = wrappedIntervals(
            minimum: rectangle.minY - expansion,
            maximum: rectangle.maxY + expansion,
            extent: pixelSize.height
        )

        return xIntervals.flatMap { x in
            yIntervals.compactMap { y in
                PixelRect(
                    minX: x.minimum,
                    minY: y.minimum,
                    maxX: x.maximum,
                    maxY: y.maximum
                )
            }
        }
    }

    private static func wrappedIntervals(
        minimum: Int,
        maximum: Int,
        extent: Int
    ) -> [(minimum: Int, maximum: Int)] {
        let length = maximum - minimum
        guard length < extent else {
            return [(0, extent)]
        }

        let start = positiveModulo(minimum, extent)
        let end = start + length
        if end <= extent {
            return [(start, end)]
        }
        return [(0, end - extent), (start, extent)]
    }

    private static func positiveModulo(_ value: Int, _ divisor: Int) -> Int {
        let remainder = value % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}
