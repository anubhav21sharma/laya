import Foundation
import PatternEngine
@testable import PatternFile
import Testing

@Suite("Pattern paint tile codec")
struct PatternPaintTileCodecTests {
    @Test
    func nativeSurfaceAcceptsMaximumPhysicalGeometryAndRetainsEmptyRevision()
        throws
    {
        for pixelSize in [
            PixelSize(width: 16_384, height: 1),
            PixelSize(width: 1, height: 16_384),
            PixelSize(width: 16_384, height: 16_384),
        ] {
            let surface = PatternPaintTileSurface(
                layerID: UUID(),
                pixelSize: pixelSize,
                rasterRevision: 41,
                tiles: []
            )

            let encoded = try PatternPaintTileCodec.encodeManifest(surface)
            let decoded = try PatternPaintTileCodec.decodeManifest(
                encoded,
                payloadsByPath: [:]
            )

            #expect(decoded == surface)
            #expect(decoded.rasterRevision == 41)
        }

        let valid = try PatternPaintTileCodec.encodeManifest(
            PatternPaintTileSurface(
                layerID: UUID(),
                pixelSize: PixelSize(width: 256, height: 256),
                rasterRevision: 5,
                tiles: []
            )
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: valid) as? [String: Any]
        )
        object.removeValue(forKey: "rasterRevision")
        let missingRevision = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        #expect(throws: PatternPaintTileError.invalidManifest) {
            try PatternPaintTileCodec.decodeManifest(
                missingRevision,
                payloadsByPath: [:]
            )
        }
    }

    @Test
    func nativeSurfaceRejectsDimensionsOutsidePhysicalGeometryBound() throws {
        for pixelSize in [
            PixelSize(width: 16_385, height: 1),
            PixelSize(width: 1, height: 16_385),
        ] {
            #expect(throws: PatternPaintTileError.invalidPixelSize) {
                try PatternPaintTileCodec.validateMetadata([
                    PatternPaintTileSurface(
                        layerID: UUID(),
                        pixelSize: pixelSize,
                        rasterRevision: 1,
                        tiles: []
                    ),
                ])
            }
        }

        let valid = try PatternPaintTileCodec.encodeManifest(
            PatternPaintTileSurface(
                layerID: UUID(),
                pixelSize: PixelSize(width: 1, height: 1),
                rasterRevision: 1,
                tiles: []
            )
        )
        for key in ["pixelWidth", "pixelHeight"] {
            var object = try #require(
                JSONSerialization.jsonObject(with: valid) as? [String: Any]
            )
            object[key] = 0
            let malformed = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            #expect(throws: PatternPaintTileError.invalidPixelSize) {
                try PatternPaintTileCodec.decodeManifest(
                    malformed,
                    payloadsByPath: [:]
                )
            }
        }
    }

    @Test
    func maximumCoordinateIsAcceptedAndNextCoordinateIsRejected() throws {
        let layerID = UUID()
        let valid = metadataRecord(
            coordinate: PatternPaintTileCoordinate(x: 63, y: 63),
            bounds: PatternPaintTileBounds(
                minX: 16_128,
                minY: 16_128,
                width: 255,
                height: 255
            ),
            rasterRevision: 3,
            ordinal: 0
        )
        let surface = PatternPaintTileSurface(
            layerID: layerID,
            pixelSize: PixelSize(width: 16_383, height: 16_383),
            rasterRevision: 3,
            tiles: [valid]
        )
        try PatternPaintTileCodec.validateMetadata([surface])

        let invalid = metadataRecord(
            coordinate: PatternPaintTileCoordinate(x: 64, y: 0),
            bounds: PatternPaintTileBounds(
                minX: 16_384,
                minY: 0,
                width: 1,
                height: 256
            ),
            rasterRevision: 3,
            ordinal: 1
        )
        #expect(throws: PatternPaintTileError.invalidLogicalBounds(invalid.id)) {
            try PatternPaintTileCodec.validateMetadata([
                PatternPaintTileSurface(
                    layerID: layerID,
                    pixelSize: surface.pixelSize,
                    rasterRevision: 3,
                    tiles: [invalid]
                ),
            ])
        }
    }

    @Test
    func metadataPreflightsAggregateTileCountWithoutPayloadMaterialization()
        throws
    {
        let records = (0..<1_025).map { ordinal in
            let x = ordinal % 64
            let y = ordinal / 64
            return metadataRecord(
                coordinate: PatternPaintTileCoordinate(x: x, y: y),
                bounds: PatternPaintTileBounds(
                    minX: x * 256,
                    minY: y * 256,
                    width: 256,
                    height: 256
                ),
                rasterRevision: 9,
                ordinal: ordinal
            )
        }
        let surface = PatternPaintTileSurface(
            layerID: UUID(),
            pixelSize: PixelSize(width: 16_384, height: 16_384),
            rasterRevision: 9,
            tiles: Array(records.prefix(1_024))
        )
        try PatternPaintTileCodec.validateMetadata([surface])

        #expect(throws: PatternPaintTileError.tileCountOutOfRange(
            actual: 1_025,
            maximum: 1_024
        )) {
            try PatternPaintTileCodec.validateMetadata([
                PatternPaintTileSurface(
                    layerID: surface.layerID,
                    pixelSize: surface.pixelSize,
                    rasterRevision: surface.rasterRevision,
                    tiles: records
                ),
            ])
        }

        #expect(throws: PatternPaintTileError.tileCountOutOfRange(
            actual: 2,
            maximum: 1
        )) {
            try PatternPaintTileCodec.validateMetadata([
                PatternPaintTileSurface(
                    layerID: surface.layerID,
                    pixelSize: surface.pixelSize,
                    rasterRevision: surface.rasterRevision,
                    tiles: Array(records.prefix(2))
                ),
            ], maximumDecodedBytes: PatternPaintTileCodec.bytesPerTile)
        }
    }

    @Test
    func surfaceRejectsTileFromAnotherRasterRevision() {
        let record = metadataRecord(
            coordinate: PatternPaintTileCoordinate(x: 0, y: 0),
            bounds: PatternPaintTileBounds(
                minX: 0,
                minY: 0,
                width: 256,
                height: 256
            ),
            rasterRevision: 12,
            ordinal: 0
        )
        #expect(throws: PatternPaintTileError.rasterRevisionMismatch(
            tileID: record.id,
            expected: 11,
            actual: 12
        )) {
            try PatternPaintTileCodec.validateMetadata([
                PatternPaintTileSurface(
                    layerID: UUID(),
                    pixelSize: PixelSize(width: 256, height: 256),
                    rasterRevision: 11,
                    tiles: [record]
                ),
            ])
        }
    }

    @Test
    func recordCreationRejectsUnsafePathAndNonclippedBoundsBeforeHashing()
        throws
    {
        let layerID = UUID(
            uuidString: "11111111-2222-3333-4444-555555555555"
        )!
        let tileID = UUID(
            uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )!
        let pixelSize = PixelSize(width: 300, height: 256)
        let payload = halfPayload([0.25, 0.125, 0, 0.5])

        #expect(throws: PatternPaintTileError.unsafePath("../tile")) {
            try PatternPaintTileCodec.makeRecord(
                layerID: layerID,
                id: tileID,
                coordinate: PatternPaintTileCoordinate(x: 0, y: 0),
                logicalBounds: PatternPaintTileBounds(
                    minX: 0,
                    minY: 0,
                    width: 256,
                    height: 256
                ),
                pixelSize: pixelSize,
                rasterRevision: 1,
                file: "../tile",
                payload: payload
            )
        }
        #expect(throws: PatternPaintTileError.invalidLogicalBounds(tileID)) {
            try PatternPaintTileCodec.makeRecord(
                layerID: layerID,
                id: tileID,
                coordinate: PatternPaintTileCoordinate(x: 1, y: 0),
                logicalBounds: PatternPaintTileBounds(
                    minX: 256,
                    minY: 0,
                    width: 45,
                    height: 256
                ),
                pixelSize: pixelSize,
                rasterRevision: 1,
                file: "tiles/edge.rgba16f",
                payload: payload
            )
        }
    }

    @Test
    func manifestEncodingRejectsMetadataItsDecoderWouldRejectAndSizeLimit()
        throws
    {
        let fixture = try tileFixture()
        let unsafe = PatternPaintTileRecord(
            id: fixture.record.id,
            coordinate: fixture.record.coordinate,
            logicalBounds: fixture.record.logicalBounds,
            pixelFormat: fixture.record.pixelFormat,
            byteOrder: fixture.record.byteOrder,
            byteCount: fixture.record.byteCount,
            semanticSHA256: fixture.record.semanticSHA256,
            rasterRevision: fixture.record.rasterRevision,
            file: "../unsafe"
        )
        #expect(throws: PatternPaintTileError.unsafePath("../unsafe")) {
            try PatternPaintTileCodec.encodeManifest(
                PatternPaintTileSurface(
                    layerID: fixture.surface.layerID,
                    pixelSize: fixture.surface.pixelSize,
                    rasterRevision: fixture.surface.rasterRevision,
                    tiles: [unsafe]
                )
            )
        }

        let encoded = try PatternPaintTileCodec.encodeManifest(
            fixture.surface
        )
        #expect(throws: PatternPaintTileError.manifestByteLimitExceeded(
            actual: encoded.count,
            maximum: encoded.count - 1
        )) {
            try PatternPaintTileCodec.encodeManifest(
                fixture.surface,
                maximumByteCount: encoded.count - 1
            )
        }
    }

    @Test
    func nativeRGBA16FPayloadRoundTripsDeterministically() throws {
        let fixture = try tileFixture()
        let first = try PatternPaintTileCodec.encodeManifest(fixture.surface)
        let second = try PatternPaintTileCodec.encodeManifest(fixture.surface)
        #expect(first == second)
        #expect(!first.starts(with: Data([0x89, 0x50, 0x4E, 0x47])))

        let decoded = try PatternPaintTileCodec.decodeManifest(
            first,
            payloadsByPath: [fixture.record.file: fixture.payload]
        )
        #expect(decoded == fixture.surface)
        #expect(decoded.tiles[0].byteCount == 524_288)
        #expect(decoded.tiles[0].pixelFormat == .rgba16Float)
        #expect(decoded.tiles[0].byteOrder == .littleEndian)
    }

    @Test
    func semanticHashBindsMetadataAndPayloadRatherThanPayloadAlone() throws {
        let fixture = try tileFixture()
        let rebound = PatternPaintTileRecord(
            id: fixture.record.id,
            coordinate: fixture.record.coordinate,
            logicalBounds: fixture.record.logicalBounds,
            pixelFormat: fixture.record.pixelFormat,
            byteOrder: fixture.record.byteOrder,
            byteCount: fixture.record.byteCount,
            semanticSHA256: fixture.record.semanticSHA256,
            rasterRevision: fixture.record.rasterRevision + 1,
            file: fixture.record.file
        )
        let surface = PatternPaintTileSurface(
            layerID: fixture.surface.layerID,
            pixelSize: fixture.surface.pixelSize,
            rasterRevision: rebound.rasterRevision,
            tiles: [rebound]
        )

        #expect(throws: PatternPaintTileError.semanticHashMismatch(
            fixture.record.id
        )) {
            try PatternPaintTileCodec.validate(
                [surface],
                payloadsByPath: [rebound.file: fixture.payload]
            )
        }

        var changedPayload = fixture.payload
        changedPayload[0] ^= 1
        #expect(throws: PatternPaintTileError.semanticHashMismatch(
            fixture.record.id
        )) {
            try PatternPaintTileCodec.validate(
                [fixture.surface],
                payloadsByPath: [fixture.record.file: changedPayload]
            )
        }
    }

    @Test
    func payloadValidationRejectsByteCountNonfiniteAndUnpremultipliedValues()
        throws
    {
        let fixture = try tileFixture()
        #expect(throws: PatternPaintTileError.payloadByteCountMismatch(
            tileID: fixture.record.id,
            expected: 524_288,
            actual: 524_287
        )) {
            try PatternPaintTileCodec.validate(
                [fixture.surface],
                payloadsByPath: [
                    fixture.record.file: fixture.payload.dropLast(),
                ]
            )
        }

        for (channels, expected) in [
            ([Float16.nan, 0, 0, 1], PatternPaintTileError.nonfiniteComponent(
                fixture.record.id
            )),
            ([0.75, 0, 0, 0.5], PatternPaintTileError.unpremultipliedComponent(
                fixture.record.id
            )),
            ([-0.25, 0, 0, 0.5], PatternPaintTileError.componentOutOfRange(
                fixture.record.id
            )),
        ] {
            let payload = halfPayload(channels)
            let record = try PatternPaintTileCodec.makeRecord(
                layerID: fixture.surface.layerID,
                id: fixture.record.id,
                coordinate: fixture.record.coordinate,
                logicalBounds: fixture.record.logicalBounds,
                pixelSize: fixture.surface.pixelSize,
                rasterRevision: fixture.record.rasterRevision,
                file: fixture.record.file,
                payload: payload,
                validatingComponents: false
            )
            let surface = PatternPaintTileSurface(
                layerID: fixture.surface.layerID,
                pixelSize: fixture.surface.pixelSize,
                rasterRevision: fixture.surface.rasterRevision,
                tiles: [record]
            )
            #expect(throws: expected) {
                try PatternPaintTileCodec.validate(
                    [surface],
                    payloadsByPath: [record.file: payload]
                )
            }
        }
    }

    @Test
    func identityCoordinateBoundsAndPathCollisionsFailClosed() throws {
        let fixture = try tileFixture()
        let secondID = UUID(
            uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
        )!
        let duplicateCoordinate = try PatternPaintTileCodec.makeRecord(
            layerID: fixture.surface.layerID,
            id: secondID,
            coordinate: fixture.record.coordinate,
            logicalBounds: fixture.record.logicalBounds,
            pixelSize: fixture.surface.pixelSize,
            rasterRevision: 2,
            file: "tiles/second.rgba16f",
            payload: fixture.payload
        )
        let coordinateSurface = PatternPaintTileSurface(
            layerID: fixture.surface.layerID,
            pixelSize: fixture.surface.pixelSize,
            rasterRevision: fixture.surface.rasterRevision,
            tiles: [fixture.record, duplicateCoordinate]
        )
        #expect(throws: PatternPaintTileError.duplicateCoordinate(
            fixture.record.coordinate
        )) {
            try PatternPaintTileCodec.validate(
                [coordinateSurface],
                payloadsByPath: [
                    fixture.record.file: fixture.payload,
                    duplicateCoordinate.file: fixture.payload,
                ]
            )
        }

        let duplicateID = PatternPaintTileRecord(
            id: fixture.record.id,
            coordinate: PatternPaintTileCoordinate(x: 1, y: 0),
            logicalBounds: PatternPaintTileBounds(
                minX: 256,
                minY: 0,
                width: 44,
                height: 256
            ),
            pixelFormat: .rgba16Float,
            byteOrder: .littleEndian,
            byteCount: fixture.record.byteCount,
            semanticSHA256: fixture.record.semanticSHA256,
            rasterRevision: 1,
            file: fixture.record.file
        )
        #expect(throws: PatternPaintTileError.duplicateTileID(
            fixture.record.id
        )) {
            try PatternPaintTileCodec.validate(
                [PatternPaintTileSurface(
                    layerID: fixture.surface.layerID,
                    pixelSize: fixture.surface.pixelSize,
                    rasterRevision: fixture.surface.rasterRevision,
                    tiles: [fixture.record, duplicateID]
                )],
                payloadsByPath: [fixture.record.file: fixture.payload]
            )
        }

        let invalidBounds = PatternPaintTileRecord(
            id: fixture.record.id,
            coordinate: fixture.record.coordinate,
            logicalBounds: PatternPaintTileBounds(
                minX: 0,
                minY: 0,
                width: 255,
                height: 256
            ),
            pixelFormat: .rgba16Float,
            byteOrder: .littleEndian,
            byteCount: fixture.record.byteCount,
            semanticSHA256: fixture.record.semanticSHA256,
            rasterRevision: 1,
            file: fixture.record.file
        )
        #expect(throws: PatternPaintTileError.invalidLogicalBounds(
            fixture.record.id
        )) {
            try PatternPaintTileCodec.validate(
                [PatternPaintTileSurface(
                    layerID: fixture.surface.layerID,
                    pixelSize: fixture.surface.pixelSize,
                    rasterRevision: fixture.surface.rasterRevision,
                    tiles: [invalidBounds]
                )],
                payloadsByPath: [fixture.record.file: fixture.payload]
            )
        }

        let sharedPath = try PatternPaintTileCodec.makeRecord(
            layerID: fixture.surface.layerID,
            id: secondID,
            coordinate: PatternPaintTileCoordinate(x: 1, y: 0),
            logicalBounds: PatternPaintTileBounds(
                minX: 256,
                minY: 0,
                width: 44,
                height: 256
            ),
            pixelSize: fixture.surface.pixelSize,
            rasterRevision: 2,
            file: fixture.record.file,
            payload: fixture.payload
        )
        #expect(throws: PatternPaintTileError.duplicatePath(
            fixture.record.file
        )) {
            try PatternPaintTileCodec.validate(
                [PatternPaintTileSurface(
                    layerID: fixture.surface.layerID,
                    pixelSize: fixture.surface.pixelSize,
                    rasterRevision: fixture.surface.rasterRevision,
                    tiles: [fixture.record, sharedPath]
                )],
                payloadsByPath: [fixture.record.file: fixture.payload]
            )
        }
    }

    @Test
    func layerAndAggregateLimitsAreCheckedBeforePayloadAcceptance() throws {
        let fixture = try tileFixture()
        let layers = (0..<9).map { index in
            PatternPaintTileSurface(
                layerID: UUID(uuidString: String(
                    format: "00000000-0000-0000-0000-%012d",
                    index + 1
                ))!,
                pixelSize: PixelSize(width: 300, height: 256),
                rasterRevision: 1,
                tiles: []
            )
        }
        #expect(throws: PatternPaintTileError.layerCountOutOfRange(9)) {
            try PatternPaintTileCodec.validate(layers, payloadsByPath: [:])
        }
        #expect(throws: PatternPaintTileError.tileCountOutOfRange(
            actual: 1,
            maximum: 0
        )) {
            try PatternPaintTileCodec.validate(
                [fixture.surface],
                payloadsByPath: [fixture.record.file: fixture.payload],
                maximumDecodedBytes: 524_287
            )
        }
    }
}

private func metadataRecord(
    coordinate: PatternPaintTileCoordinate,
    bounds: PatternPaintTileBounds,
    rasterRevision: UInt64,
    ordinal: Int
) -> PatternPaintTileRecord {
    PatternPaintTileRecord(
        id: UUID(uuidString: String(
            format: "00000000-0000-4000-8000-%012x",
            ordinal + 1
        ))!,
        coordinate: coordinate,
        logicalBounds: bounds,
        pixelFormat: .rgba16Float,
        byteOrder: .littleEndian,
        byteCount: PatternPaintTileCodec.bytesPerTile,
        semanticSHA256: String(repeating: "0", count: 64),
        rasterRevision: rasterRevision,
        file: "tiles/\(ordinal).rgba16f"
    )
}

private func tileFixture() throws -> (
    surface: PatternPaintTileSurface,
    record: PatternPaintTileRecord,
    payload: Data
) {
    let layerID = UUID(
        uuidString: "11111111-2222-3333-4444-555555555555"
    )!
    let tileID = UUID(
        uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    )!
    let payload = halfPayload([0.25, 0.125, 0, 0.5])
    let record = try PatternPaintTileCodec.makeRecord(
        layerID: layerID,
        id: tileID,
        coordinate: PatternPaintTileCoordinate(x: 0, y: 0),
        logicalBounds: PatternPaintTileBounds(
            minX: 0,
            minY: 0,
            width: 256,
            height: 256
        ),
        pixelSize: PixelSize(width: 300, height: 256),
        rasterRevision: 1,
        file: "tiles/primary.rgba16f",
        payload: payload
    )
    return (
        PatternPaintTileSurface(
            layerID: layerID,
            pixelSize: PixelSize(width: 300, height: 256),
            rasterRevision: 1,
            tiles: [record]
        ),
        record,
        payload
    )
}

private func halfPayload(_ channels: [Float16]) -> Data {
    precondition(channels.count == 4)
    var pixel = Data()
    for channel in channels {
        let bits = channel.bitPattern
        pixel.append(UInt8(truncatingIfNeeded: bits))
        pixel.append(UInt8(truncatingIfNeeded: bits >> 8))
    }
    var payload = Data(capacity: 524_288)
    for _ in 0..<(256 * 256) { payload.append(pixel) }
    return payload
}
