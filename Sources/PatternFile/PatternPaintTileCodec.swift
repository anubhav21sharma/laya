import CryptoKit
import Foundation
import PatternEngine

public struct PatternPaintTileCoordinate:
    Codable,
    Comparable,
    Equatable,
    Hashable,
    Sendable
{
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    public static func < (
        lhs: PatternPaintTileCoordinate,
        rhs: PatternPaintTileCoordinate
    ) -> Bool {
        lhs.y == rhs.y ? lhs.x < rhs.x : lhs.y < rhs.y
    }
}

public struct PatternPaintTileBounds: Codable, Equatable, Sendable {
    public let minX: Int
    public let minY: Int
    public let width: Int
    public let height: Int

    public init(minX: Int, minY: Int, width: Int, height: Int) {
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
    }
}

public enum PatternPaintTilePixelFormat: String, Codable, Sendable {
    case rgba16Float
}

public enum PatternPaintTileByteOrder: String, Codable, Sendable {
    case littleEndian
}

public struct PatternPaintTileRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let coordinate: PatternPaintTileCoordinate
    public let logicalBounds: PatternPaintTileBounds
    public let pixelFormat: PatternPaintTilePixelFormat
    public let byteOrder: PatternPaintTileByteOrder
    public let byteCount: Int
    public let semanticSHA256: String
    public let rasterRevision: UInt64
    public let file: String

    public init(
        id: UUID,
        coordinate: PatternPaintTileCoordinate,
        logicalBounds: PatternPaintTileBounds,
        pixelFormat: PatternPaintTilePixelFormat,
        byteOrder: PatternPaintTileByteOrder,
        byteCount: Int,
        semanticSHA256: String,
        rasterRevision: UInt64,
        file: String
    ) {
        self.id = id
        self.coordinate = coordinate
        self.logicalBounds = logicalBounds
        self.pixelFormat = pixelFormat
        self.byteOrder = byteOrder
        self.byteCount = byteCount
        self.semanticSHA256 = semanticSHA256
        self.rasterRevision = rasterRevision
        self.file = file
    }
}

public struct PatternPaintTileSurface: Equatable, Sendable {
    public let layerID: UUID
    public let pixelSize: PixelSize
    public let tiles: [PatternPaintTileRecord]

    public init(
        layerID: UUID,
        pixelSize: PixelSize,
        tiles: [PatternPaintTileRecord]
    ) {
        self.layerID = layerID
        self.pixelSize = pixelSize
        self.tiles = tiles
    }
}

public enum PatternPaintTileError: Error, Equatable, Sendable {
    case invalidManifest
    case layerCountOutOfRange(Int)
    case duplicateLayerID(UUID)
    case duplicateTileID(UUID)
    case duplicateCoordinate(PatternPaintTileCoordinate)
    case invalidLogicalBounds(UUID)
    case invalidPixelSize
    case unsafePath(String)
    case duplicatePath(String)
    case missingPayload(String)
    case unexpectedPayload(String)
    case unsupportedByteCount(tileID: UUID, byteCount: Int)
    case payloadByteCountMismatch(tileID: UUID, expected: Int, actual: Int)
    case decodedByteLimitExceeded(actual: Int, maximum: Int)
    case invalidSemanticHash(UUID)
    case semanticHashMismatch(UUID)
    case nonfiniteComponent(UUID)
    case componentOutOfRange(UUID)
    case unpremultipliedComponent(UUID)
}

public enum PatternPaintTileCodec {
    public static let tileSide = 256
    public static let bytesPerPixel = 8
    public static let bytesPerTile = 524_288
    public static let maximumLayerCount = 8
    public static let maximumDecodedBytes = 512 * 1_024 * 1_024
    public static let maximumManifestBytes = 1_048_576

    public static func makeRecord(
        layerID: UUID,
        id: UUID,
        coordinate: PatternPaintTileCoordinate,
        logicalBounds: PatternPaintTileBounds,
        rasterRevision: UInt64,
        file: String,
        payload: Data,
        validatingComponents: Bool = true
    ) throws -> PatternPaintTileRecord {
        let provisional = PatternPaintTileRecord(
            id: id,
            coordinate: coordinate,
            logicalBounds: logicalBounds,
            pixelFormat: .rgba16Float,
            byteOrder: .littleEndian,
            byteCount: payload.count,
            semanticSHA256: String(repeating: "0", count: 64),
            rasterRevision: rasterRevision,
            file: file
        )
        guard payload.count == bytesPerTile else {
            throw PatternPaintTileError.payloadByteCountMismatch(
                tileID: id,
                expected: bytesPerTile,
                actual: payload.count
            )
        }
        if validatingComponents {
            try validateComponents(payload, tileID: id)
        }
        return PatternPaintTileRecord(
            id: id,
            coordinate: coordinate,
            logicalBounds: logicalBounds,
            pixelFormat: .rgba16Float,
            byteOrder: .littleEndian,
            byteCount: payload.count,
            semanticSHA256: semanticHash(
                layerID: layerID,
                record: provisional,
                payload: payload
            ),
            rasterRevision: rasterRevision,
            file: file
        )
    }

    public static func encodeManifest(
        _ surface: PatternPaintTileSurface
    ) throws -> Data {
        let wire = SurfaceWire(surface)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        do {
            return try encoder.encode(wire)
        } catch {
            throw PatternPaintTileError.invalidManifest
        }
    }

    public static func decodeManifest(
        _ data: Data,
        payloadsByPath: [String: Data],
        maximumDecodedBytes: Int = maximumDecodedBytes
    ) throws -> PatternPaintTileSurface {
        guard data.count <= maximumManifestBytes else {
            throw PatternPaintTileError.invalidManifest
        }
        let wire: SurfaceWire
        do {
            wire = try JSONDecoder().decode(SurfaceWire.self, from: data)
        } catch {
            throw PatternPaintTileError.invalidManifest
        }
        guard wire.layoutVersion == 1 else {
            throw PatternPaintTileError.invalidManifest
        }
        guard let pixelSize = checkedPixelSize(
            width: wire.pixelWidth,
            height: wire.pixelHeight
        ) else {
            throw PatternPaintTileError.invalidPixelSize
        }
        let surface = PatternPaintTileSurface(
            layerID: wire.layerID,
            pixelSize: pixelSize,
            tiles: wire.tiles
        )
        try validate(
            [surface],
            payloadsByPath: payloadsByPath,
            maximumDecodedBytes: maximumDecodedBytes
        )
        return surface
    }

    public static func decodeManifestMetadata(
        _ data: Data
    ) throws -> PatternPaintTileSurface {
        guard data.count <= maximumManifestBytes else {
            throw PatternPaintTileError.invalidManifest
        }
        let wire: SurfaceWire
        do {
            wire = try JSONDecoder().decode(SurfaceWire.self, from: data)
        } catch {
            throw PatternPaintTileError.invalidManifest
        }
        guard wire.layoutVersion == 1,
              let pixelSize = checkedPixelSize(
                  width: wire.pixelWidth,
                  height: wire.pixelHeight
              )
        else {
            throw PatternPaintTileError.invalidManifest
        }
        let surface = PatternPaintTileSurface(
            layerID: wire.layerID,
            pixelSize: pixelSize,
            tiles: wire.tiles
        )
        try validateMetadata([surface])
        return surface
    }

    public static func validateMetadata(
        _ surfaces: [PatternPaintTileSurface]
    ) throws {
        guard (1...maximumLayerCount).contains(surfaces.count) else {
            throw PatternPaintTileError.layerCountOutOfRange(surfaces.count)
        }
        var layerIDs = Set<UUID>()
        var tileIDs = Set<UUID>()
        var paths = Set<String>()
        for surface in surfaces {
            guard layerIDs.insert(surface.layerID).inserted else {
                throw PatternPaintTileError.duplicateLayerID(surface.layerID)
            }
            guard surface.pixelSize.width > 0,
                  surface.pixelSize.height > 0,
                  surface.pixelSize.width <= 4_096,
                  surface.pixelSize.height <= 4_096
            else {
                throw PatternPaintTileError.invalidPixelSize
            }
            var coordinates = Set<PatternPaintTileCoordinate>()
            for record in surface.tiles {
                guard tileIDs.insert(record.id).inserted else {
                    throw PatternPaintTileError.duplicateTileID(record.id)
                }
                guard coordinates.insert(record.coordinate).inserted else {
                    throw PatternPaintTileError.duplicateCoordinate(
                        record.coordinate
                    )
                }
                try validatePath(record.file)
                guard paths.insert(record.file).inserted else {
                    throw PatternPaintTileError.duplicatePath(record.file)
                }
                guard expectedBounds(
                    coordinate: record.coordinate,
                    pixelSize: surface.pixelSize
                ) == record.logicalBounds else {
                    throw PatternPaintTileError.invalidLogicalBounds(record.id)
                }
                guard record.pixelFormat == .rgba16Float,
                      record.byteOrder == .littleEndian,
                      record.byteCount == bytesPerTile
                else {
                    throw PatternPaintTileError.unsupportedByteCount(
                        tileID: record.id,
                        byteCount: record.byteCount
                    )
                }
                guard isCanonicalSHA256(record.semanticSHA256) else {
                    throw PatternPaintTileError.invalidSemanticHash(record.id)
                }
            }
        }
    }

    public static func validate(
        _ surfaces: [PatternPaintTileSurface],
        payloadsByPath: [String: Data],
        maximumDecodedBytes: Int = maximumDecodedBytes
    ) throws {
        try validateMetadata(surfaces)
        guard maximumDecodedBytes >= 0 else {
            throw PatternPaintTileError.decodedByteLimitExceeded(
                actual: 0,
                maximum: maximumDecodedBytes
            )
        }

        var layerIDs = Set<UUID>()
        var tileIDs = Set<UUID>()
        var paths = Set<String>()
        var expectedPaths = Set<String>()
        var decodedBytes = 0

        for surface in surfaces {
            guard layerIDs.insert(surface.layerID).inserted else {
                throw PatternPaintTileError.duplicateLayerID(surface.layerID)
            }
            guard surface.pixelSize.width > 0,
                  surface.pixelSize.height > 0,
                  surface.pixelSize.width <= 4_096,
                  surface.pixelSize.height <= 4_096
            else {
                throw PatternPaintTileError.invalidPixelSize
            }
            var coordinates = Set<PatternPaintTileCoordinate>()
            for record in surface.tiles {
                guard tileIDs.insert(record.id).inserted else {
                    throw PatternPaintTileError.duplicateTileID(record.id)
                }
                guard coordinates.insert(record.coordinate).inserted else {
                    throw PatternPaintTileError.duplicateCoordinate(
                        record.coordinate
                    )
                }
                try validatePath(record.file)
                guard paths.insert(record.file).inserted else {
                    throw PatternPaintTileError.duplicatePath(record.file)
                }
                expectedPaths.insert(record.file)
                guard expectedBounds(
                    coordinate: record.coordinate,
                    pixelSize: surface.pixelSize
                ) == record.logicalBounds else {
                    throw PatternPaintTileError.invalidLogicalBounds(record.id)
                }
                guard record.byteCount == bytesPerTile else {
                    throw PatternPaintTileError.unsupportedByteCount(
                        tileID: record.id,
                        byteCount: record.byteCount
                    )
                }
                guard isCanonicalSHA256(record.semanticSHA256) else {
                    throw PatternPaintTileError.invalidSemanticHash(record.id)
                }
                guard let payload = payloadsByPath[record.file] else {
                    throw PatternPaintTileError.missingPayload(record.file)
                }
                guard payload.count == record.byteCount else {
                    throw PatternPaintTileError.payloadByteCountMismatch(
                        tileID: record.id,
                        expected: record.byteCount,
                        actual: payload.count
                    )
                }
                let (sum, overflow) = decodedBytes.addingReportingOverflow(
                    payload.count
                )
                let actual = overflow ? Int.max : sum
                guard !overflow, actual <= maximumDecodedBytes else {
                    throw PatternPaintTileError.decodedByteLimitExceeded(
                        actual: actual,
                        maximum: maximumDecodedBytes
                    )
                }
                decodedBytes = sum
                try validateComponents(payload, tileID: record.id)
                guard semanticHash(
                    layerID: surface.layerID,
                    record: record,
                    payload: payload
                ) == record.semanticSHA256 else {
                    throw PatternPaintTileError.semanticHashMismatch(record.id)
                }
            }
        }
        if let unexpected = payloadsByPath.keys.sorted().first(where: {
            !expectedPaths.contains($0)
        }) {
            throw PatternPaintTileError.unexpectedPayload(unexpected)
        }
    }
}

private extension PatternPaintTileCodec {
    struct SurfaceWire: Codable {
        let layoutVersion: Int
        let layerID: UUID
        let pixelWidth: Int
        let pixelHeight: Int
        let tiles: [PatternPaintTileRecord]

        init(_ surface: PatternPaintTileSurface) {
            layoutVersion = 1
            layerID = surface.layerID
            pixelWidth = surface.pixelSize.width
            pixelHeight = surface.pixelSize.height
            tiles = surface.tiles.sorted {
                if $0.coordinate == $1.coordinate {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.coordinate < $1.coordinate
            }
        }
    }

    static func checkedPixelSize(width: Int, height: Int) -> PixelSize? {
        guard (1...4_096).contains(width), (1...4_096).contains(height)
        else { return nil }
        return PixelSize(width: width, height: height)
    }

    static func expectedBounds(
        coordinate: PatternPaintTileCoordinate,
        pixelSize: PixelSize
    ) -> PatternPaintTileBounds? {
        guard coordinate.x >= 0, coordinate.y >= 0 else { return nil }
        let (minX, overflowX) = coordinate.x.multipliedReportingOverflow(
            by: tileSide
        )
        let (minY, overflowY) = coordinate.y.multipliedReportingOverflow(
            by: tileSide
        )
        guard !overflowX, !overflowY,
              minX < pixelSize.width,
              minY < pixelSize.height
        else { return nil }
        return PatternPaintTileBounds(
            minX: minX,
            minY: minY,
            width: min(tileSide, pixelSize.width - minX),
            height: min(tileSide, pixelSize.height - minY)
        )
    }

    static func validatePath(_ path: String) throws {
        guard !path.isEmpty,
              path.utf8.count <= 512,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0")
        else { throw PatternPaintTileError.unsafePath(path) }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".."
        }) else {
            throw PatternPaintTileError.unsafePath(path)
        }
    }

    static func validateComponents(_ payload: Data, tileID: UUID) throws {
        guard payload.count == bytesPerTile else {
            throw PatternPaintTileError.payloadByteCountMismatch(
                tileID: tileID,
                expected: bytesPerTile,
                actual: payload.count
            )
        }
        var offset = 0
        while offset < payload.count {
            let red = component(payload, offset: offset)
            let green = component(payload, offset: offset + 2)
            let blue = component(payload, offset: offset + 4)
            let alpha = component(payload, offset: offset + 6)
            let components = [red, green, blue, alpha]
            guard components.allSatisfy(\.isFinite) else {
                throw PatternPaintTileError.nonfiniteComponent(tileID)
            }
            guard components.allSatisfy({ (0...1).contains($0) }) else {
                throw PatternPaintTileError.componentOutOfRange(tileID)
            }
            guard red <= alpha, green <= alpha, blue <= alpha else {
                throw PatternPaintTileError.unpremultipliedComponent(tileID)
            }
            offset += bytesPerPixel
        }
    }

    static func component(_ payload: Data, offset: Int) -> Float {
        let bits = UInt16(payload[offset])
            | UInt16(payload[offset + 1]) << 8
        return Float(Float16(bitPattern: bits))
    }

    static func semanticHash(
        layerID: UUID,
        record: PatternPaintTileRecord,
        payload: Data
    ) -> String {
        var canonical = Data("laya.paint-tile.semantic.v1\0".utf8)
        append(layerID, to: &canonical)
        append(record.id, to: &canonical)
        append(record.coordinate.x, to: &canonical)
        append(record.coordinate.y, to: &canonical)
        append(record.logicalBounds.minX, to: &canonical)
        append(record.logicalBounds.minY, to: &canonical)
        append(record.logicalBounds.width, to: &canonical)
        append(record.logicalBounds.height, to: &canonical)
        append(record.pixelFormat.rawValue, to: &canonical)
        append(record.byteOrder.rawValue, to: &canonical)
        append(record.rasterRevision, to: &canonical)
        append(record.byteCount, to: &canonical)
        append(record.file, to: &canonical)
        canonical.append(payload)
        return SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func append(_ value: UUID, to data: inout Data) {
        append(value.uuidString.lowercased(), to: &data)
    }

    static func append(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        append(bytes.count, to: &data)
        data.append(bytes)
    }

    static func append(_ value: Int, to data: inout Data) {
        append(UInt64(bitPattern: Int64(value)), to: &data)
    }

    static func append(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 0, through: 56, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}
