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

    public var kind: BrushTextureKind {
        switch self {
        case .hardRoundShape, .softRoundShape, .chiselShape:
            .shape
        case .opaqueGrain, .paperGrain, .noiseGrain:
            .grain
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
    public static let validationPackByteCount =
        mipmappedTextureByteCount * BrushTextureIdentity.allCases.count
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
        maximumDimension: Int = textureSize
    ) -> DecodedBrushTexture {
        precondition(maximumDimension > 0)
        let workingDimension = min(textureSize, maximumDimension)
        var width = workingDimension
        var height = workingDimension
        var level = baseLevel(identity: identity)
        if workingDimension != textureSize {
            level = areaAverage(
                level,
                width: textureSize,
                height: textureSize,
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
            sourceWidth: textureSize,
            sourceHeight: textureSize,
            workingWidth: workingDimension,
            workingHeight: workingDimension,
            mipLevels: mipLevels,
            residentByteCount: mipLevels.reduce(0) { $0 + $1.count },
            wasResampled: workingDimension != textureSize
        )
    }

    public func makeTexture(
        identity: BrushTextureIdentity
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: Self.textureSize,
            height: Self.textureSize,
            mipmapped: true
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw BrushTextureFactoryError.textureAllocationFailed(identity)
        }
        texture.label = identity.rawValue

        var width = Self.textureSize
        var height = Self.textureSize
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
            count: textureSize * textureSize
        )
        for y in 0..<textureSize {
            for x in 0..<textureSize {
                bytes[y * textureSize + x] = referenceTexel(
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
            let point = normalizedPoint(x: x, y: y)
            return point.x * point.x + point.y * point.y <= 1 ? 255 : 0

        case .softRoundShape:
            let point = normalizedPoint(x: x, y: y)
            let radius = sqrt(point.x * point.x + point.y * point.y)
            return quantize(1 - radius)

        case .chiselShape:
            let point = normalizedPoint(x: x, y: y)
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
            var value = UInt32(truncatingIfNeeded: x)
                &* 0x9E37_79B9
            value ^= UInt32(truncatingIfNeeded: y) &* 0x85EB_CA6B
            value ^= value >> 16
            value &*= 0x7FEB_352D
            value ^= value >> 15
            value &*= 0x846C_A68B
            value ^= value >> 16
            return UInt8(96 + value % 160)
        }
    }

    private static func normalizedPoint(
        x: Int,
        y: Int
    ) -> (x: Float, y: Float) {
        let scale = 2 / Float(textureSize)
        return (
            (Float(x) + 0.5) * scale - 1,
            (Float(y) + 0.5) * scale - 1
        )
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
