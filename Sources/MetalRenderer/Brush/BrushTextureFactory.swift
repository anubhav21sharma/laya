import Metal

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

    private let device: any MTLDevice

    public init(device: any MTLDevice) {
        self.device = device
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
        var output = [UInt8](
            repeating: 0,
            count: outputWidth * outputHeight
        )

        for y in 0..<outputHeight {
            for x in 0..<outputWidth {
                let x0 = min(width - 1, x * 2)
                let x1 = min(width - 1, x0 + 1)
                let y0 = min(height - 1, y * 2)
                let y1 = min(height - 1, y0 + 1)
                let sum = Int(input[y0 * width + x0])
                    + Int(input[y0 * width + x1])
                    + Int(input[y1 * width + x0])
                    + Int(input[y1 * width + x1])
                output[y * outputWidth + x] = UInt8((sum + 2) / 4)
            }
        }
        return output
    }
}
