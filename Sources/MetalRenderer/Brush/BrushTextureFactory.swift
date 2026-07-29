import Foundation
import Metal
import PatternEngine

public enum BrushTextureKind: UInt8, Equatable, Hashable, Sendable {
    case shape
    case grain
}

public enum BrushTextureIdentity:
    String, CaseIterable, Equatable, Hashable, Sendable
{
    case hardRoundShape = "builtin.shape.hard-round"
    case softRoundShape = "builtin.shape.soft-round"
    case chiselShape = "builtin.shape.chisel"
    case opaqueGrain = "builtin.grain.opaque"
    case paperGrain = "builtin.grain.paper"
    case noiseGrain = "builtin.grain.noise"
    case technicalNibShape = "builtin.shape.technical-nib"
    case graphiteTipShape = "builtin.shape.graphite-tip"
    case charcoalTipShape = "builtin.shape.charcoal-tip"
    case markerChiselShape = "builtin.shape.marker-chisel"
    case graphiteGrain = "builtin.grain.graphite"
    case charcoalGrain = "builtin.grain.charcoal"

    public var kind: BrushTextureKind {
        switch self {
        case .hardRoundShape, .softRoundShape, .chiselShape,
             .technicalNibShape, .graphiteTipShape, .charcoalTipShape,
             .markerChiselShape:
            .shape
        case .opaqueGrain, .paperGrain, .noiseGrain, .graphiteGrain,
             .charcoalGrain:
            .grain
        }
    }

    public var sourceDimension: Int {
        switch self {
        case .hardRoundShape, .softRoundShape, .chiselShape, .opaqueGrain,
             .paperGrain, .noiseGrain:
            64
        case .technicalNibShape, .graphiteTipShape, .charcoalTipShape,
             .markerChiselShape:
            128
        case .graphiteGrain, .charcoalGrain:
            256
        }
    }
}

public enum BrushTextureFactoryError: Error, Equatable, Sendable {
    case textureAllocationFailed(BrushTextureIdentity)
}

/// Builds the small deterministic Slice 4 validation pack entirely in memory.
/// Every mip is generated on the CPU with defined integer rounding, so asset
/// bytes do not depend on a GPU mip generator or command-buffer completion.
public struct BrushTextureFactory {
    public static let textureSize = 64
    public static let mipmappedTextureByteCount = 5_461
    public static let validationPackByteCount = 294_908
    static let cpuPyramidContentVersion = "builtin-r8-cpu-pyramid-v1"

    private let device: any MTLDevice

    public init(device: any MTLDevice) {
        self.device = device
    }

    /// CPU-only compiler seam. The new compiler uploads this deterministic
    /// pyramid through its private-texture path; it never reuses the legacy
    /// `.shared` allocation below.
    static func makeCPUPyramid(
        identity: BrushTextureIdentity,
        resourceID: String? = nil,
        maximumDimension: Int = .max
    ) -> DecodedBrushTexture {
        precondition(maximumDimension > 0)
        let sourceDimension = identity.sourceDimension
        let workingDimension = min(sourceDimension, maximumDimension)
        var width = workingDimension
        var height = workingDimension
        var level = baseLevel(identity: identity)
        if workingDimension != sourceDimension {
            level = areaAverage(
                level,
                width: sourceDimension,
                height: sourceDimension,
                outputWidth: workingDimension,
                outputHeight: workingDimension
            )
        }
        var mipLevels: [Data] = []
        while true {
            mipLevels.append(Data(level))
            guard width > 1 || height > 1 else { break }
            level = boxAverage(level, width: width, height: height)
            width = max(1, width / 2)
            height = max(1, height / 2)
        }
        return DecodedBrushTexture(
            resourceID: resourceID ?? identity.rawValue,
            kind: identity.kind == .shape ? .shape : .grain,
            sourceWidth: sourceDimension,
            sourceHeight: sourceDimension,
            workingWidth: workingDimension,
            workingHeight: workingDimension,
            mipLevels: mipLevels,
            residentByteCount: mipLevels.reduce(0) { $0 + $1.count },
            wasResampled: workingDimension != sourceDimension
        )
    }

    public func makeTexture(
        identity: BrushTextureIdentity
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: identity.sourceDimension,
            height: identity.sourceDimension,
            mipmapped: true
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw BrushTextureFactoryError.textureAllocationFailed(identity)
        }
        texture.label = identity.rawValue

        var width = identity.sourceDimension
        var height = identity.sourceDimension
        var levelBytes = Self.baseLevel(identity: identity)

        for level in 0..<texture.mipmapLevelCount {
            levelBytes.withUnsafeBytes { buffer in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: level,
                    withBytes: buffer.baseAddress!,
                    bytesPerRow: width
                )
            }
            guard level + 1 < texture.mipmapLevelCount else { break }
            levelBytes = Self.boxAverage(
                levelBytes,
                width: width,
                height: height
            )
            width = max(1, width / 2)
            height = max(1, height / 2)
        }
        return texture
    }

    private static func baseLevel(
        identity: BrushTextureIdentity
    ) -> [UInt8] {
        var bytes = [UInt8](
            repeating: 0,
            count: identity.sourceDimension * identity.sourceDimension
        )
        for y in 0..<identity.sourceDimension {
            for x in 0..<identity.sourceDimension {
                bytes[y * identity.sourceDimension + x] = referenceTexel(
                    identity: identity,
                    x: x,
                    y: y
                )
            }
        }
        return bytes
    }

    static func referenceTexel(
        identity: BrushTextureIdentity,
        x: Int,
        y: Int
    ) -> UInt8 {
        switch identity {
        case .hardRoundShape:
            let point = normalizedPoint(x: x, y: y, dimension: 64)
            return point.x * point.x + point.y * point.y <= 1 ? 255 : 0

        case .softRoundShape:
            let point = normalizedPoint(x: x, y: y, dimension: 64)
            let radius = sqrt(point.x * point.x + point.y * point.y)
            return quantize(1 - radius)

        case .chiselShape:
            let point = normalizedPoint(x: x, y: y, dimension: 64)
            let inverseRootTwo: Float = 0.70710677
            let along = (point.x + point.y) * inverseRootTwo
            let across = (-point.x + point.y) * inverseRootTwo
            let normalizedAlong = min(1, max(0, (along + 0.95) / 1.9))
            let halfWidth = 0.16 + 0.22 * (1 - normalizedAlong)
            let alongEdge = 0.95 - abs(along)
            let acrossEdge = halfWidth - abs(across)
            let edge = min(alongEdge, acrossEdge)
            return quantize(edge * 48)

        case .opaqueGrain:
            return 255

        case .paperGrain:
            let diagonalFiber = (x * 13 + y * 7 + x * y * 3) % 31
            let horizontalFiber = (y * 11 + x / 3) % 23
            let tooth = (diagonalFiber * 5 + horizontalFiber * 3) % 96
            let groove = (x + y * 5) % 17 == 0 ? 28 : 0
            return UInt8(max(96, 255 - tooth - groove))

        case .noiseGrain:
            let value = texelHash(x: x, y: y, salt: 0)
            return UInt8(96 + value % 160)

        case .technicalNibShape:
            return ellipseCoverage(
                x: x, y: y, dimension: 128,
                horizontalRadius: 91, verticalRadius: 102, softness: 16
            )

        case .graphiteTipShape:
            let coverage = ellipseCoverage(
                x: x, y: y, dimension: 128,
                horizontalRadius: 43, verticalRadius: 102, softness: 16
            )
            let tooth = Int(texelHash(x: x, y: y, salt: 0x41) % 37)
            return UInt8(max(0, Int(coverage) - tooth))

        case .charcoalTipShape:
            let coverage = ellipseCoverage(
                x: x, y: y, dimension: 128,
                horizontalRadius: 88, verticalRadius: 94, softness: 9
            )
            let pore = Int(texelHash(x: x / 3, y: y / 3, salt: 0x77) % 78)
            let fleck = (x * 17 + y * 29) % 23 == 0 ? 48 : 0
            return UInt8(max(0, Int(coverage) - pore - fleck))

        case .markerChiselShape:
            let dx = 2 * x + 1 - 128
            let dy = 2 * y + 1 - 128
            let along = abs(dx + dy)
            let across = abs(dy - dx)
            let edge = min(186 - along, 62 - across)
            return UInt8(min(255, max(0, edge * 20)))

        case .graphiteGrain:
            let fine = Int(texelHash(x: x, y: y, salt: 0x51) % 54)
            let fiber = (x * 5 + y * 19 + x / 7) % 29 < 4 ? 24 : 0
            let ridge = (y + x / 11) % 17 == 0 ? 18 : 0
            return UInt8(max(96, 248 - fine - fiber - ridge))

        case .charcoalGrain:
            let cluster = Int(
                texelHash(x: x / 9, y: y / 9, salt: 0xA3) % 104
            )
            let tooth = Int(texelHash(x: x, y: y, salt: 0xC7) % 38)
            let crack = (x * 7 + y * 13 + x * y) % 47 < 3 ? 56 : 0
            return UInt8(max(48, 240 - cluster - tooth - crack))
        }
    }

    private static func normalizedPoint(
        x: Int,
        y: Int,
        dimension: Int
    ) -> (x: Float, y: Float) {
        let scale = 2 / Float(dimension)
        return (
            (Float(x) + 0.5) * scale - 1,
            (Float(y) + 0.5) * scale - 1
        )
    }

    private static func texelHash(x: Int, y: Int, salt: UInt32) -> UInt32 {
        var value = UInt32(truncatingIfNeeded: x) &* 0x9E37_79B9
        value ^= UInt32(truncatingIfNeeded: y) &* 0x85EB_CA6B
        value ^= salt &* 0x27D4_EB2D
        value ^= value >> 16
        value &*= 0x7FEB_352D
        value ^= value >> 15
        value &*= 0x846C_A68B
        value ^= value >> 16
        return value
    }

    private static func ellipseCoverage(
        x: Int,
        y: Int,
        dimension: Int,
        horizontalRadius: Int,
        verticalRadius: Int,
        softness: Int
    ) -> UInt8 {
        let dx = Int64(2 * x + 1 - dimension)
        let dy = Int64(2 * y + 1 - dimension)
        let horizontal = Int64(horizontalRadius)
        let vertical = Int64(verticalRadius)
        let limit = horizontal * horizontal * vertical * vertical
        let metric = dx * dx * vertical * vertical
            + dy * dy * horizontal * horizontal
        let delta = limit - metric
        guard delta > 0 else { return 0 }
        let edge = max(Int64(1), limit / Int64(softness))
        guard delta < edge else { return 255 }
        return UInt8(delta * 255 / edge)
    }

    private static func quantize(_ value: Float) -> UInt8 {
        let normalized = min(1, max(0, value))
        return UInt8((normalized * 255).rounded())
    }

    private static func boxAverage(
        _ input: [UInt8],
        width: Int,
        height: Int
    ) -> [UInt8] {
        let outputWidth = max(1, width / 2)
        let outputHeight = max(1, height / 2)
        return areaAverage(
            input,
            width: width,
            height: height,
            outputWidth: outputWidth,
            outputHeight: outputHeight
        )
    }

    private static func areaAverage(
        _ input: [UInt8],
        width: Int,
        height: Int,
        outputWidth: Int,
        outputHeight: Int
    ) -> [UInt8] {
        var output = [UInt8](
            repeating: 0,
            count: outputWidth * outputHeight
        )

        for y in 0..<outputHeight {
            let y0 = y * height / outputHeight
            let y1 = (y + 1) * height / outputHeight
            for x in 0..<outputWidth {
                let x0 = x * width / outputWidth
                let x1 = (x + 1) * width / outputWidth
                var sum = 0
                var count = 0
                for sourceY in y0..<y1 {
                    for sourceX in x0..<x1 {
                        sum += Int(input[sourceY * width + sourceX])
                        count += 1
                    }
                }
                output[y * outputWidth + x] = UInt8(
                    (sum + count / 2) / count
                )
            }
        }
        return output
    }
}
