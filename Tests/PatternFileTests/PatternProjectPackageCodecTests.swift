import Foundation
import PatternEngine
import PatternFile
import Testing

@Suite("Pattern project package codec")
struct PatternProjectPackageCodecTests {
    @Test
    func nativePackageStreamsDeterministicallyAndPreservesEmptyRevision()
        throws
    {
        let fixture = try nativePackageFixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.patternproj")
        let secondURL = directory.appendingPathComponent("second.patternproj")
        let firstProvider = TileProvider(payloads: fixture.payloads)
        let secondProvider = TileProvider(payloads: fixture.payloads)

        try PatternProjectPackageCodec.save(
            metadata: fixture.metadata,
            tilePayloadProvider: firstProvider,
            projectPaletteJSON: Data(#"{"name":"Native"}"#.utf8),
            to: firstURL
        )
        try PatternProjectPackageCodec.save(
            metadata: fixture.metadata,
            tilePayloadProvider: secondProvider,
            projectPaletteJSON: Data(#"{"name":"Native"}"#.utf8),
            to: secondURL
        )

        #expect(try Data(contentsOf: firstURL) == Data(contentsOf: secondURL))
        #expect(firstProvider.closeCount == 1)
        #expect(firstProvider.maximumObservedChunkByteCount
            <= PatternProjectPackageCodec.tileChunkByteCount)
        let decoded = try PatternProjectPackageCodec.open(at: firstURL)
        #expect(decoded.metadata.metadata == fixture.metadata)
        #expect(decoded.projectPaletteJSON == Data(#"{"name":"Native"}"#.utf8))
        let empty = try #require(decoded.metadata.metadata.layers.last)
        let emptySurface = empty.surface
        #expect(emptySurface.tiles.isEmpty)
        #expect(emptySurface.rasterRevision == 11)

        let consumer = TileConsumer()
        try decoded.consumeTilePayloads(
            maximumChunkByteCount: 8_193,
            consumer: consumer
        )
        #expect(consumer.closeCount == 1)
        #expect(consumer.maximumObservedChunkByteCount <= 8_193)
        #expect(consumer.payloads == fixture.payloads)
    }

    @Test
    func providerAndConsumerCloseExactlyOnceWhenStreamingThrows() throws {
        let fixture = try nativePackageFixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("project.patternproj")
        let failingProvider = TileProvider(
            payloads: fixture.payloads,
            failure: .provider
        )
        #expect(throws: StreamFixtureError.provider) {
            try PatternProjectPackageCodec.save(
                metadata: fixture.metadata,
                tilePayloadProvider: failingProvider,
                to: destination
            )
        }
        #expect(failingProvider.closeCount == 1)
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        let provider = TileProvider(payloads: fixture.payloads)
        try PatternProjectPackageCodec.save(
            metadata: fixture.metadata,
            tilePayloadProvider: provider,
            to: destination
        )
        let decoded = try PatternProjectPackageCodec.open(at: destination)
        let failingConsumer = TileConsumer(failure: .consumer)
        #expect(throws: StreamFixtureError.consumer) {
            try decoded.consumeTilePayloads(
                maximumChunkByteCount: 4_097,
                consumer: failingConsumer
            )
        }
        #expect(failingConsumer.closeCount == 1)
    }

    @Test
    func invalidMetadataPreflightClosesProviderWithoutCreatingDestination()
        throws
    {
        let fixture = try nativePackageFixture()
        let invalid = PatternProjectMetadata(
            documentID: fixture.metadata.documentID,
            title: fixture.metadata.title,
            appVersion: fixture.metadata.appVersion,
            createdAt: fixture.metadata.createdAt,
            modifiedAt: fixture.metadata.modifiedAt,
            canvasSize: fixture.metadata.canvasSize,
            viewport: fixture.metadata.viewport,
            documentConfiguration: fixture.metadata.documentConfiguration,
            documentDomainLocked: fixture.metadata.documentDomainLocked,
            radialGeometryLocked: fixture.metadata.radialGeometryLocked,
            activeLayerID: fixture.metadata.activeLayerID,
            layers: []
        )
        let provider = TileProvider(payloads: fixture.payloads)
        let destination = temporaryFileURL()
        #expect(throws: PatternProjectFileError.metadata(
            .layerCountOutOfRange(0)
        )) {
            try PatternProjectPackageCodec.save(
                metadata: invalid,
                tilePayloadProvider: provider,
                to: destination
            )
        }
        #expect(provider.closeCount == 1)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test
    func unsupportedNativeSchemasWinBeforePayloadLookup() throws {
        for version in [1, 2, 3, 5] {
            let archive = try PatternProjectArchiveCodec.encode(entries: [
                PatternProjectFormat.manifestPath: Data(
                    "{\"schemaVersion\":\(version)}".utf8
                ),
            ])
            #expect(throws: PatternProjectFileError.metadata(
                .unsupportedSchema(version)
            )) {
                try PatternProjectPackageCodec.open(archive)
            }
        }
    }

    @Test
    func missingAndUnexpectedTileEntriesFailClosed() throws {
        let fixture = try nativePackageFixture()
        let encoded = try savedArchive(fixture)
        let archive = try PatternProjectArchiveCodec.open(encoded)
        var entries = try archiveEntries(archive)
        let path = try #require(fixture.payloads.keys.first)
        entries.removeValue(forKey: path)
        #expect(throws: PatternProjectFileError.missingTilePayload(path)) {
            try PatternProjectPackageCodec.open(
                PatternProjectArchiveCodec.encode(entries: entries)
            )
        }

        entries = try archiveEntries(archive)
        entries["tiles/stale.rgba16f"] = Data()
        #expect(throws: PatternProjectFileError.unexpectedArchiveEntry(
            "tiles/stale.rgba16f"
        )) {
            try PatternProjectPackageCodec.open(
                PatternProjectArchiveCodec.encode(entries: entries)
            )
        }
    }

    @Test
    func wrongTileHashAndByteCountFailWithTileIdentity() throws {
        let fixture = try nativePackageFixture()
        let encoded = try savedArchive(fixture)
        let archive = try PatternProjectArchiveCodec.open(encoded)
        let record = try #require(fixture.record)
        var entries = try archiveEntries(archive)
        var changed = try #require(entries[record.file])
        changed[6] = 0
        changed[7] = 0x3c
        entries[record.file] = changed
        #expect(throws: PatternProjectFileError.paintTile(
            .semanticHashMismatch(record.id)
        )) {
            try PatternProjectPackageCodec.open(
                PatternProjectArchiveCodec.encode(entries: entries)
            )
        }

        entries = try archiveEntries(archive)
        var short = try #require(entries[record.file])
        short.removeLast()
        entries[record.file] = short
        #expect(throws: PatternProjectFileError.paintTile(
            .payloadByteCountMismatch(
                tileID: record.id,
                expected: PatternPaintTileCodec.bytesPerTile,
                actual: PatternPaintTileCodec.bytesPerTile - 1
            )
        )) {
            try PatternProjectPackageCodec.open(
                PatternProjectArchiveCodec.encode(entries: entries)
            )
        }
    }

}

private struct NativePackageFixture {
    let metadata: PatternProjectMetadata
    let payloads: [String: Data]
    let record: PatternPaintTileRecord?
}

private func nativePackageFixture() throws -> NativePackageFixture {
    let documentID = UUID(
        uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    )!
    let firstLayerID = UUID(
        uuidString: "11111111-2222-3333-4444-555555555555"
    )!
    let secondLayerID = UUID(
        uuidString: "66666666-7777-8888-9999-aaaaaaaaaaaa"
    )!
    let tileID = UUID(
        uuidString: "01234567-89ab-cdef-0123-456789abcdef"
    )!
    let pixelSize = PixelSize(width: 256, height: 256)
    let payload = Data(count: PatternPaintTileCodec.bytesPerTile)
    let path = "tiles/\(firstLayerID.uuidString.lowercased())/"
        + "\(tileID.uuidString.lowercased()).rgba16f"
    let record = try PatternPaintTileCodec.makeRecord(
        layerID: firstLayerID,
        id: tileID,
        coordinate: PatternPaintTileCoordinate(x: 0, y: 0),
        logicalBounds: PatternPaintTileBounds(
            minX: 0,
            minY: 0,
            width: 256,
            height: 256
        ),
        pixelSize: pixelSize,
        rasterRevision: 7,
        file: path,
        payload: payload,
        validatingComponents: false
    )
    let firstSurfacePath = "surfaces/"
        + "\(firstLayerID.uuidString.lowercased()).tiles.json"
    let secondSurfacePath = "surfaces/"
        + "\(secondLayerID.uuidString.lowercased()).tiles.json"
    let metadata = PatternProjectMetadata(
        documentID: documentID,
        title: "Native",
        appVersion: "0.1.0",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
        canvasSize: pixelSize,
        viewport: PatternProjectViewport(scale: 1, offsetX: 0, offsetY: 0),
        documentConfiguration: .periodic(.legacy(
            presetID: .grid,
            tileSize: PatternSize(width: 256, height: 256)
        )),
        documentDomainLocked: true,
        radialGeometryLocked: false,
        activeLayerID: firstLayerID,
        layers: [
            PatternProjectLayer(
                id: firstLayerID,
                name: "Paint",
                order: 0,
                surface: PatternProjectPaintTileSurface(
                    manifestFile: firstSurfacePath,
                    pixelSize: pixelSize,
                    rasterRevision: 7,
                    tiles: [record]
                )
            ),
            PatternProjectLayer(
                id: secondLayerID,
                name: "Empty",
                order: 1,
                opacity: 0.5,
                blendMode: .multiply,
                surface: PatternProjectPaintTileSurface(
                    manifestFile: secondSurfacePath,
                    pixelSize: pixelSize,
                    rasterRevision: 11,
                    tiles: []
                )
            ),
        ]
    )
    return NativePackageFixture(
        metadata: metadata,
        payloads: [path: payload],
        record: record
    )
}

private final class TileProvider:
    PatternProjectTilePayloadProvider,
    @unchecked Sendable
{
    let payloads: [String: Data]
    let failure: StreamFixtureError?
    private(set) var closeCount = 0
    private(set) var requestCount = 0
    private(set) var maximumObservedChunkByteCount = 0

    init(
        payloads: [String: Data],
        failure: StreamFixtureError? = nil
    ) {
        self.payloads = payloads
        self.failure = failure
    }

    func providePayloadChunks(
        for record: PatternPaintTileRecord,
        layerID: UUID,
        maximumChunkByteCount: Int,
        consume: (Data) throws -> Void
    ) throws {
        requestCount += 1
        if failure == .provider { throw StreamFixtureError.provider }
        guard let payload = payloads[record.file] else {
            throw StreamFixtureError.missingPayload
        }
        var offset = 0
        while offset < payload.count {
            let end = min(payload.count, offset + maximumChunkByteCount)
            let chunk = payload.subdata(in: offset..<end)
            maximumObservedChunkByteCount = max(
                maximumObservedChunkByteCount,
                chunk.count
            )
            try consume(chunk)
            offset = end
        }
    }

    func close() { closeCount += 1 }
}

private final class TileConsumer:
    PatternProjectTilePayloadConsumer,
    @unchecked Sendable
{
    let failure: StreamFixtureError?
    private var activePath: String?
    private var activePayload = Data()
    private(set) var payloads: [String: Data] = [:]
    private(set) var closeCount = 0
    private(set) var maximumObservedChunkByteCount = 0

    init(failure: StreamFixtureError? = nil) {
        self.failure = failure
    }

    func beginTile(
        _ record: PatternPaintTileRecord,
        layerID: UUID
    ) throws {
        activePath = record.file
        activePayload.removeAll(keepingCapacity: true)
    }

    func consumeTileChunk(
        _ chunk: Data,
        record: PatternPaintTileRecord,
        layerID: UUID
    ) throws {
        if failure == .consumer { throw StreamFixtureError.consumer }
        maximumObservedChunkByteCount = max(
            maximumObservedChunkByteCount,
            chunk.count
        )
        activePayload.append(chunk)
    }

    func finishTile(
        _ record: PatternPaintTileRecord,
        layerID: UUID
    ) throws {
        payloads[try #require(activePath)] = activePayload
        activePath = nil
    }

    func close() { closeCount += 1 }
}

private enum StreamFixtureError: Error, Equatable {
    case provider
    case consumer
    case missingPayload
}

private func savedArchive(_ fixture: NativePackageFixture) throws -> Data {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("project.patternproj")
    try PatternProjectPackageCodec.save(
        metadata: fixture.metadata,
        tilePayloadProvider: TileProvider(payloads: fixture.payloads),
        to: destination
    )
    return try Data(contentsOf: destination)
}

private func archiveEntries(
    _ archive: PatternProjectArchive
) throws -> [String: Data] {
    try Dictionary(uniqueKeysWithValues: archive.paths.map {
        ($0, try archive.data(for: $0))
    })
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false
    )
    return url
}

private func temporaryFileURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).patternproj")
}

private func replacingLayers(
    in metadata: PatternProjectMetadata,
    with layers: [PatternProjectLayer]
) -> PatternProjectMetadata {
    PatternProjectMetadata(
        documentID: metadata.documentID,
        title: metadata.title,
        appVersion: metadata.appVersion,
        createdAt: metadata.createdAt,
        modifiedAt: metadata.modifiedAt,
        canvasSize: metadata.canvasSize,
        viewport: metadata.viewport,
        documentConfiguration: metadata.documentConfiguration,
        documentDomainLocked: metadata.documentDomainLocked,
        radialGeometryLocked: metadata.radialGeometryLocked,
        activeLayerID: metadata.activeLayerID,
        layers: layers
    )
}
