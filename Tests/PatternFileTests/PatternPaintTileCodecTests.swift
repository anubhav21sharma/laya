import Foundation
import PatternEngine
@testable import PatternFile
import Testing

@Suite("Pattern paint tile codec")
struct PatternPaintTileCodecTests {
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
                tiles: []
            )
        }
        #expect(throws: PatternPaintTileError.layerCountOutOfRange(9)) {
            try PatternPaintTileCodec.validate(layers, payloadsByPath: [:])
        }
        #expect(throws: PatternPaintTileError.decodedByteLimitExceeded(
            actual: 524_288,
            maximum: 524_287
        )) {
            try PatternPaintTileCodec.validate(
                [fixture.surface],
                payloadsByPath: [fixture.record.file: fixture.payload],
                maximumDecodedBytes: 524_287
            )
        }
    }
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
