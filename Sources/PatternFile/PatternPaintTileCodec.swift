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
    public let rasterRevision: UInt64
    public let tiles: [PatternPaintTileRecord]

    public init(
        layerID: UUID,
        pixelSize: PixelSize,
        rasterRevision: UInt64,
        tiles: [PatternPaintTileRecord]
    ) {
        self.layerID = layerID
        self.pixelSize = pixelSize
        self.rasterRevision = rasterRevision
        self.tiles = tiles
    }
}

public enum PatternPaintTileError: Error, Equatable, Sendable {
    case invalidManifest
    case manifestByteLimitExceeded(actual: Int, maximum: Int)
    case layerCountOutOfRange(Int)
    case duplicateLayerID(UUID)
    case duplicateTileID(UUID)
    case duplicateCoordinate(PatternPaintTileCoordinate)
    case tileCountOutOfRange(actual: Int, maximum: Int)
    case rasterRevisionMismatch(
        tileID: UUID,
        expected: UInt64,
        actual: UInt64
    )
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
    public static let maximumPhysicalDimension =
        RadialSectorLayout.maximumAtlasDimension

    public static func makeRecord(
        layerID: UUID,
        id: UUID,
        coordinate: PatternPaintTileCoordinate,
        logicalBounds: PatternPaintTileBounds,
        pixelSize: PixelSize,
        rasterRevision: UInt64,
        file: String,
        payload: Data,
        validatingComponents: Bool = true
    ) throws -> PatternPaintTileRecord {
        guard checkedPixelSize(
            width: pixelSize.width,
            height: pixelSize.height
        ) == pixelSize else {
            throw PatternPaintTileError.invalidPixelSize
        }
        try validatePath(file)
        guard expectedBounds(
            coordinate: coordinate,
            pixelSize: pixelSize
        ) == logicalBounds else {
            throw PatternPaintTileError.invalidLogicalBounds(id)
        }
        guard payload.count == bytesPerTile else {
            throw PatternPaintTileError.payloadByteCountMismatch(
                tileID: id,
                expected: bytesPerTile,
                actual: payload.count
            )
        }
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
        try validateMetadata([
            PatternPaintTileSurface(
                layerID: layerID,
                pixelSize: pixelSize,
                rasterRevision: rasterRevision,
                tiles: [provisional]
            ),
        ])
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
        try validateMetadata([surface])
        return try encodeManifestOfValidatedSurface(
            surface,
            maximumByteCount: maximumManifestBytes
        )
    }

    static func encodeManifest(
        _ surface: PatternPaintTileSurface,
        maximumByteCount: Int
    ) throws -> Data {
        try validateMetadata([surface])
        return try encodeManifestOfValidatedSurface(
            surface,
            maximumByteCount: maximumByteCount
        )
    }

    static func encodeManifestOfValidatedSurface(
        _ surface: PatternPaintTileSurface,
        maximumByteCount: Int = maximumManifestBytes
    ) throws -> Data {
        let wire = SurfaceWire(surface)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        let encoded: Data
        do {
            encoded = try encoder.encode(wire)
        } catch {
            throw PatternPaintTileError.invalidManifest
        }
        guard encoded.count <= maximumByteCount else {
            throw PatternPaintTileError.manifestByteLimitExceeded(
                actual: encoded.count,
                maximum: maximumByteCount
            )
        }
        return encoded
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
            rasterRevision: wire.rasterRevision,
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
        _ data: Data,
        maximumDecodedBytes: Int = maximumDecodedBytes
    ) throws -> PatternPaintTileSurface {
        let surface = try decodeManifestMetadataStructure(data)
        try validateMetadata(
            [surface],
            maximumDecodedBytes: maximumDecodedBytes
        )
        return surface
    }

    static func decodeManifestMetadataStructure(
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
        return PatternPaintTileSurface(
            layerID: wire.layerID,
            pixelSize: pixelSize,
            rasterRevision: wire.rasterRevision,
            tiles: wire.tiles
        )
    }

    public static func validateMetadata(
        _ surfaces: [PatternPaintTileSurface],
        maximumDecodedBytes: Int = maximumDecodedBytes
    ) throws {
        guard (1...maximumLayerCount).contains(surfaces.count) else {
            throw PatternPaintTileError.layerCountOutOfRange(surfaces.count)
        }
        guard maximumDecodedBytes >= 0 else {
            throw PatternPaintTileError.decodedByteLimitExceeded(
                actual: 0,
                maximum: maximumDecodedBytes
            )
        }
        let maximumTileCount = maximumDecodedBytes / bytesPerTile
        var totalTileCount = 0
        for surface in surfaces {
            let (sum, overflow) = totalTileCount.addingReportingOverflow(
                surface.tiles.count
            )
            let actual = overflow ? Int.max : sum
            guard !overflow, actual <= maximumTileCount else {
                throw PatternPaintTileError.tileCountOutOfRange(
                    actual: actual,
                    maximum: maximumTileCount
                )
            }
            totalTileCount = sum
        }
        var layerIDs = Set<UUID>()
        var tileIDs = Set<UUID>()
        var paths = Set<String>()
        var declaredBytes = 0
        for surface in surfaces {
            guard layerIDs.insert(surface.layerID).inserted else {
                throw PatternPaintTileError.duplicateLayerID(surface.layerID)
            }
            guard checkedPixelSize(
                width: surface.pixelSize.width,
                height: surface.pixelSize.height
            ) == surface.pixelSize else {
                throw PatternPaintTileError.invalidPixelSize
            }
            let addressableTileCount = try checkedAddressableTileCount(
                for: surface.pixelSize
            )
            guard surface.tiles.count <= addressableTileCount else {
                throw PatternPaintTileError.tileCountOutOfRange(
                    actual: surface.tiles.count,
                    maximum: addressableTileCount
                )
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
                guard record.rasterRevision == surface.rasterRevision else {
                    throw PatternPaintTileError.rasterRevisionMismatch(
                        tileID: record.id,
                        expected: surface.rasterRevision,
                        actual: record.rasterRevision
                    )
                }
                let (sum, overflow) = declaredBytes.addingReportingOverflow(
                    record.byteCount
                )
                let actual = overflow ? Int.max : sum
                guard !overflow, actual <= maximumDecodedBytes else {
                    throw PatternPaintTileError.decodedByteLimitExceeded(
                        actual: actual,
                        maximum: maximumDecodedBytes
                    )
                }
                declaredBytes = sum
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
        try validateMetadata(
            surfaces,
            maximumDecodedBytes: maximumDecodedBytes
        )
        var expectedPaths = Set<String>()
        var decodedBytes = 0

        for surface in surfaces {
            for record in surface.tiles {
                expectedPaths.insert(record.file)
                guard let payload = payloadsByPath[record.file] else {
                    throw PatternPaintTileError.missingPayload(record.file)
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
                try validatePayload(
                    payload,
                    for: record,
                    layerID: surface.layerID
                )
            }
        }
        if let unexpected = payloadsByPath.keys.sorted().first(where: {
            !expectedPaths.contains($0)
        }) {
            throw PatternPaintTileError.unexpectedPayload(unexpected)
        }
    }

    public static func validatePayload(
        _ payload: Data,
        for record: PatternPaintTileRecord,
        layerID: UUID
    ) throws {
        guard payload.count == record.byteCount else {
            throw PatternPaintTileError.payloadByteCountMismatch(
                tileID: record.id,
                expected: record.byteCount,
                actual: payload.count
            )
        }
        try validateComponents(payload, tileID: record.id)
        guard semanticHash(
            layerID: layerID,
            record: record,
            payload: payload
        ) == record.semanticSHA256 else {
            throw PatternPaintTileError.semanticHashMismatch(record.id)
        }
    }
}

private extension PatternPaintTileCodec {
    struct SurfaceWire: Codable {
        let layoutVersion: Int
        let layerID: UUID
        let pixelWidth: Int
        let pixelHeight: Int
        let rasterRevision: UInt64
        let tiles: [PatternPaintTileRecord]

        init(_ surface: PatternPaintTileSurface) {
            layoutVersion = 1
            layerID = surface.layerID
            pixelWidth = surface.pixelSize.width
            pixelHeight = surface.pixelSize.height
            rasterRevision = surface.rasterRevision
            tiles = surface.tiles.sorted {
                if $0.coordinate == $1.coordinate {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.coordinate < $1.coordinate
            }
        }
    }

    static func checkedPixelSize(width: Int, height: Int) -> PixelSize? {
        guard (1...maximumPhysicalDimension).contains(width),
              (1...maximumPhysicalDimension).contains(height)
        else { return nil }
        return PixelSize(width: width, height: height)
    }

    static func checkedAddressableTileCount(
        for pixelSize: PixelSize
    ) throws -> Int {
        let columns = pixelSize.width / tileSide
            + (pixelSize.width % tileSide == 0 ? 0 : 1)
        let rows = pixelSize.height / tileSide
            + (pixelSize.height % tileSide == 0 ? 0 : 1)
        let (count, overflow) = columns.multipliedReportingOverflow(by: rows)
        guard !overflow else {
            throw PatternPaintTileError.tileCountOutOfRange(
                actual: Int.max,
                maximum: maximumDecodedBytes / bytesPerTile
            )
        }
        return count
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
