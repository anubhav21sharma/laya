import Foundation
import PatternEngine
import SafeArchive

public protocol PatternProjectTilePayloadProvider: AnyObject, Sendable {
    func providePayloadChunks(
        for record: PatternPaintTileRecord,
        layerID: UUID,
        maximumChunkByteCount: Int,
        consume: (Data) throws -> Void
    ) throws
    func close()
}

public protocol PatternProjectTilePayloadConsumer: AnyObject, Sendable {
    func beginTile(
        _ record: PatternPaintTileRecord,
        layerID: UUID
    ) throws
    func consumeTileChunk(
        _ chunk: Data,
        record: PatternPaintTileRecord,
        layerID: UUID
    ) throws
    func finishTile(
        _ record: PatternPaintTileRecord,
        layerID: UUID
    ) throws
    func close()
}

public struct DecodedPatternProject: Sendable {
    public let metadata: ValidatedPatternProjectMetadata
    public let thumbnail: PatternRasterImage?
    public let projectPaletteJSON: Data?
    private let archive: PatternProjectArchive

    init(
        metadata: ValidatedPatternProjectMetadata,
        thumbnail: PatternRasterImage?,
        projectPaletteJSON: Data?,
        archive: PatternProjectArchive
    ) {
        self.metadata = metadata
        self.thumbnail = thumbnail
        self.projectPaletteJSON = projectPaletteJSON
        self.archive = archive
    }

    public func consumeTilePayloads(
        maximumChunkByteCount: Int,
        consumer: any PatternProjectTilePayloadConsumer
    ) throws {
        defer { consumer.close() }
        guard maximumChunkByteCount > 0 else {
            throw PatternProjectFileError.archive(
                .invalidChunkByteCount(maximumChunkByteCount)
            )
        }
        for layer in metadata.metadata.layers.sorted(by: {
            $0.order < $1.order
        }) {
            let surface = layer.surface
            for record in surface.tiles.sorted(by: {
                if $0.coordinate != $1.coordinate {
                    return $0.coordinate < $1.coordinate
                }
                return $0.id.uuidString < $1.id.uuidString
            }) {
                try consumer.beginTile(record, layerID: layer.id)
                do {
                    try archive.consumeEntry(
                        at: record.file,
                        maximumChunkByteCount: maximumChunkByteCount
                    ) { chunk in
                        try consumer.consumeTileChunk(
                            chunk,
                            record: record,
                            layerID: layer.id
                        )
                    }
                } catch PatternProjectArchiveError.missingEntry {
                    throw PatternProjectFileError.missingTilePayload(
                        record.file
                    )
                } catch let error as PatternProjectArchiveError {
                    throw PatternProjectFileError.archive(error)
                }
                try consumer.finishTile(record, layerID: layer.id)
            }
        }
    }
}

public enum PatternProjectFileError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case archive(PatternProjectArchiveError)
    case metadata(PatternProjectLoadError)
    case paintTile(PatternPaintTileError)
    case missingTilePayload(String)
    case duplicateArchivePath(String)
    case unexpectedArchiveEntry(String)
    case invalidThumbnail
    case invalidPalette

    public var errorDescription: String? {
        switch self {
        case let .archive(error): error.localizedDescription
        case let .metadata(error): error.localizedDescription
        case let .paintTile(error): String(describing: error)
        case let .missingTilePayload(path):
            "Required native tile payload \(path) is missing."
        case let .duplicateArchivePath(path):
            "Project resources collide at \(path)."
        case let .unexpectedArchiveEntry(path):
            "Project archive entry \(path) is not declared."
        case .invalidThumbnail:
            "Project thumbnail must not exceed 512x512."
        case .invalidPalette:
            "Project palette metadata is invalid."
        }
    }
}

public enum PatternProjectPackageCodec {
    public static let thumbnailPath = "thumbnail.png"
    public static let palettePath = "palettes/project_palette.json"
    public static let tileChunkByteCount = 64 * 1_024

    public static func save(
        metadata: PatternProjectMetadata,
        tilePayloadProvider: any PatternProjectTilePayloadProvider,
        thumbnail: PatternRasterImage? = nil,
        projectPaletteJSON: Data? = nil,
        to destination: URL
    ) throws {
        let prepared: PreparedEntries
        do {
            prepared = try preparedEntries(
                metadata: metadata,
                thumbnail: thumbnail,
                projectPaletteJSON: projectPaletteJSON
            )
        } catch {
            tilePayloadProvider.close()
            throw error
        }
        let provider = NativeArchiveEntryProvider(
            staticEntries: prepared.staticEntries,
            tiles: prepared.tiles,
            payloadProvider: tilePayloadProvider
        )
        do {
            try SafeArchiveIO.save(
                provider: provider,
                to: destination,
                limits: PatternProjectArchiveCodec.limits,
                maximumChunkByteCount: tileChunkByteCount
            )
        } catch let error as PatternProjectArchiveError {
            throw PatternProjectFileError.archive(error)
        } catch let error as SafeArchiveError {
            throw PatternProjectFileError.archive(
                PatternProjectArchiveError(error)
            )
        } catch let error as PatternPaintTileError {
            throw PatternProjectFileError.paintTile(error)
        }
    }

    public static func open(_ data: Data) throws -> DecodedPatternProject {
        let archive: PatternProjectArchive
        do {
            archive = try PatternProjectArchiveCodec.open(data)
        } catch let error as PatternProjectArchiveError {
            throw PatternProjectFileError.archive(error)
        }
        return try open(archive)
    }

    public static func open(at url: URL) throws -> DecodedPatternProject {
        let archive: PatternProjectArchive
        do {
            archive = try PatternProjectArchiveCodec.open(at: url)
        } catch let error as PatternProjectArchiveError {
            throw PatternProjectFileError.archive(error)
        }
        return try open(archive)
    }
}

private extension PatternProjectPackageCodec {
    struct TileEntry {
        let layerID: UUID
        let record: PatternPaintTileRecord
    }

    struct PreparedEntries {
        let staticEntries: [String: Data]
        let tiles: [String: TileEntry]
    }

    static func preparedEntries(
        metadata: PatternProjectMetadata,
        thumbnail: PatternRasterImage?,
        projectPaletteJSON: Data?
    ) throws -> PreparedEntries {
        let metadataFiles: PatternProjectMetadataFiles
        do {
            metadataFiles = try PatternProjectMetadataCodec.encode(metadata)
        } catch let error as PatternProjectLoadError {
            throw PatternProjectFileError.metadata(error)
        }
        var entries: [String: Data] = [
            PatternProjectFormat.manifestPath: metadataFiles.manifest,
            PatternProjectFormat.symmetryPath: metadataFiles.symmetry,
        ]
        try add(metadataFiles.layersByPath, to: &entries)
        try add(metadataFiles.surfacesByPath, to: &entries)

        var tiles: [String: TileEntry] = [:]
        for layer in metadata.layers {
            let surface = layer.surface
            for record in surface.tiles {
                guard entries[record.file] == nil,
                      tiles[record.file] == nil,
                      record.file != thumbnailPath,
                      record.file != palettePath
                else {
                    throw PatternProjectFileError.duplicateArchivePath(
                        record.file
                    )
                }
                tiles[record.file] = TileEntry(
                    layerID: layer.id,
                    record: record
                )
            }
        }
        if let thumbnail {
            guard entries[thumbnailPath] == nil,
                  tiles[thumbnailPath] == nil,
                  thumbnail.pixelSize.width <= 512,
                  thumbnail.pixelSize.height <= 512
            else { throw PatternProjectFileError.invalidThumbnail }
            do {
                entries[thumbnailPath] = try PatternRasterPNGCodec.encode(
                    thumbnail
                )
            } catch {
                throw PatternProjectFileError.invalidThumbnail
            }
        }
        if let projectPaletteJSON {
            guard entries[palettePath] == nil,
                  tiles[palettePath] == nil,
                  projectPaletteJSON.count
                    <= PatternProjectMetadataCodec
                        .maximumMetadataBytesPerFile,
                  (try? JSONSerialization.jsonObject(
                    with: projectPaletteJSON
                  )) != nil
            else { throw PatternProjectFileError.invalidPalette }
            entries[palettePath] = projectPaletteJSON
        }
        return PreparedEntries(staticEntries: entries, tiles: tiles)
    }

    static func open(
        _ archive: PatternProjectArchive
    ) throws -> DecodedPatternProject {
        let metadataFiles: PatternProjectMetadataFiles
        let validated: ValidatedPatternProjectMetadata
        do {
            let extracted = try PatternProjectMetadataCodec
                .extractedMetadata(from: archive)
            metadataFiles = extracted.files
            validated = extracted.validated
        } catch let error as PatternProjectLoadError {
            throw PatternProjectFileError.metadata(error)
        } catch let error as PatternProjectArchiveError {
            throw PatternProjectFileError.archive(error)
        }

        var allowed = Set([
            PatternProjectFormat.manifestPath,
            PatternProjectFormat.symmetryPath,
        ])
        allowed.formUnion(metadataFiles.layersByPath.keys)
        allowed.formUnion(metadataFiles.surfacesByPath.keys)
        var tileEntries: [TileEntry] = []
        for layer in validated.metadata.layers {
            let surface = layer.surface
            for record in surface.tiles {
                allowed.insert(record.file)
                tileEntries.append(.init(layerID: layer.id, record: record))
            }
        }
        allowed.insert(thumbnailPath)
        allowed.insert(palettePath)
        if let unexpected = archive.paths.first(where: {
            !allowed.contains($0)
        }) {
            throw PatternProjectFileError.unexpectedArchiveEntry(unexpected)
        }

        for entry in tileEntries.sorted(by: {
            if $0.layerID != $1.layerID {
                return $0.layerID.uuidString < $1.layerID.uuidString
            }
            return $0.record.coordinate < $1.record.coordinate
        }) {
            let payload: Data
            do {
                payload = try archive.data(
                    for: entry.record.file,
                    maximumByteCount: UInt64(entry.record.byteCount)
                )
            } catch PatternProjectArchiveError.missingEntry {
                throw PatternProjectFileError.missingTilePayload(
                    entry.record.file
                )
            } catch let error as PatternProjectArchiveError {
                throw PatternProjectFileError.archive(error)
            }
            do {
                try PatternPaintTileCodec.validatePayload(
                    payload,
                    for: entry.record,
                    layerID: entry.layerID
                )
            } catch let error as PatternPaintTileError {
                throw PatternProjectFileError.paintTile(error)
            }
        }

        let thumbnail = try decodeThumbnail(from: archive)
        let palette = try decodePalette(from: archive)
        return DecodedPatternProject(
            metadata: validated,
            thumbnail: thumbnail,
            projectPaletteJSON: palette,
            archive: archive
        )
    }

    static func decodeThumbnail(
        from archive: PatternProjectArchive
    ) throws -> PatternRasterImage? {
        guard archive.paths.contains(thumbnailPath) else { return nil }
        guard let encoded = try? archive.data(for: thumbnailPath),
              let decoded = try? PatternRasterPNGCodec.decode(encoded),
              decoded.pixelSize.width <= 512,
              decoded.pixelSize.height <= 512
        else { throw PatternProjectFileError.invalidThumbnail }
        return decoded
    }

    static func decodePalette(
        from archive: PatternProjectArchive
    ) throws -> Data? {
        guard archive.paths.contains(palettePath) else { return nil }
        let encoded: Data
        do {
            encoded = try archive.data(
                for: palettePath,
                maximumByteCount: UInt64(
                    PatternProjectMetadataCodec.maximumMetadataBytesPerFile
                )
            )
        } catch let error as PatternProjectArchiveError {
            throw PatternProjectFileError.archive(error)
        }
        guard (try? JSONSerialization.jsonObject(with: encoded)) != nil else {
            throw PatternProjectFileError.invalidPalette
        }
        return encoded
    }

    static func add(
        _ source: [String: Data],
        to destination: inout [String: Data]
    ) throws {
        for (path, data) in source {
            guard destination.updateValue(data, forKey: path) == nil else {
                throw PatternProjectFileError.duplicateArchivePath(path)
            }
        }
    }
}

private final class NativeArchiveEntryProvider: SafeArchiveEntryProvider {
    private let staticEntries: [String: Data]
    private let tiles: [String: PatternProjectPackageCodec.TileEntry]
    private let payloadProvider: any PatternProjectTilePayloadProvider
    private let lock = NSLock()
    private var closed = false

    init(
        staticEntries: [String: Data],
        tiles: [String: PatternProjectPackageCodec.TileEntry],
        payloadProvider: any PatternProjectTilePayloadProvider
    ) {
        self.staticEntries = staticEntries
        self.tiles = tiles
        self.payloadProvider = payloadProvider
    }

    func archiveEntries() throws -> [SafeArchiveEntryDescriptor] {
        staticEntries.map {
            .init(path: $0.key, byteCount: UInt64($0.value.count))
        } + tiles.map {
            .init(path: $0.key, byteCount: UInt64($0.value.record.byteCount))
        }
    }

    func provideChunks(
        for path: String,
        maximumChunkByteCount: Int,
        consume: (Data) throws -> Void
    ) throws {
        if let data = staticEntries[path] {
            var offset = 0
            while offset < data.count {
                let end = min(data.count, offset + maximumChunkByteCount)
                try consume(data.subdata(in: offset..<end))
                offset = end
            }
            return
        }
        guard let tile = tiles[path] else {
            throw SafeArchiveError.missingEntry(path)
        }
        var validationPayload = Data()
        validationPayload.reserveCapacity(tile.record.byteCount)
        try payloadProvider.providePayloadChunks(
            for: tile.record,
            layerID: tile.layerID,
            maximumChunkByteCount: maximumChunkByteCount
        ) { chunk in
            validationPayload.append(chunk)
            try consume(chunk)
        }
        try PatternPaintTileCodec.validatePayload(
            validationPayload,
            for: tile.record,
            layerID: tile.layerID
        )
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        payloadProvider.close()
    }
}
