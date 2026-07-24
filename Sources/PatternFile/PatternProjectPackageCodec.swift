import Foundation
import PatternEngine

public struct DecodedPatternProject: Equatable, Sendable {
    public let metadata: ValidatedPatternProjectMetadata
    public let rastersByPath: [String: PatternRasterImage]
    public let thumbnail: PatternRasterImage?
    public let projectPaletteJSON: Data?

    public init(
        metadata: ValidatedPatternProjectMetadata,
        rastersByPath: [String: PatternRasterImage],
        thumbnail: PatternRasterImage? = nil,
        projectPaletteJSON: Data? = nil
    ) {
        self.metadata = metadata
        self.rastersByPath = rastersByPath
        self.thumbnail = thumbnail
        self.projectPaletteJSON = projectPaletteJSON
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
    case missingRaster(String)
    case unexpectedRaster(String)
    case duplicateArchivePath(String)
    case unexpectedArchiveEntry(String)
    case rasterBudgetExceeded(actual: UInt64, maximum: UInt64)
    case raster(path: String, error: PatternRasterImageError)
    case invalidThumbnail
    case invalidPalette

    public var errorDescription: String? {
        switch self {
        case let .archive(error):
            error.localizedDescription
        case let .metadata(error):
            error.localizedDescription
        case let .missingRaster(path):
            "Required project raster \(path) is missing."
        case let .unexpectedRaster(path):
            "Raster payload \(path) is not referenced by the project."
        case let .duplicateArchivePath(path):
            "Project resources collide at \(path)."
        case let .unexpectedArchiveEntry(path):
            "Project archive entry \(path) is not declared."
        case let .rasterBudgetExceeded(actual, maximum):
            "Decoded raster cost \(actual) bytes exceeds \(maximum)."
        case let .raster(path, error):
            "Raster \(path) failed: \(error.localizedDescription)"
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
    public static let maximumDecodedRasterBytes: UInt64 =
        512 * 1_024 * 1_024

    public static func encode(
        metadata: PatternProjectMetadata,
        rastersByPath: [String: PatternRasterImage],
        thumbnail: PatternRasterImage? = nil,
        projectPaletteJSON: Data? = nil
    ) throws -> Data {
        try PatternProjectArchiveCodec.encode(entries: makeEntries(
            metadata: metadata,
            rastersByPath: rastersByPath,
            thumbnail: thumbnail,
            projectPaletteJSON: projectPaletteJSON
        ))
    }

    public static func save(
        metadata: PatternProjectMetadata,
        rastersByPath: [String: PatternRasterImage],
        thumbnail: PatternRasterImage? = nil,
        projectPaletteJSON: Data? = nil,
        to destination: URL
    ) throws {
        let entries = try makeEntries(
            metadata: metadata,
            rastersByPath: rastersByPath,
            thumbnail: thumbnail,
            projectPaletteJSON: projectPaletteJSON
        )
        do {
            try PatternProjectArchiveIO.save(
                entries: entries,
                to: destination
            )
        } catch let error as PatternProjectArchiveError {
            throw PatternProjectFileError.archive(error)
        }
    }

    public static func open(
        _ data: Data
    ) throws -> DecodedPatternProject {
        let archive: PatternProjectArchive
        do {
            archive = try PatternProjectArchiveCodec.open(data)
        } catch let error as PatternProjectArchiveError {
            throw PatternProjectFileError.archive(error)
        }
        return try open(archive)
    }

    public static func open(
        at url: URL
    ) throws -> DecodedPatternProject {
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
    static func makeEntries(
        metadata: PatternProjectMetadata,
        rastersByPath: [String: PatternRasterImage],
        thumbnail: PatternRasterImage?,
        projectPaletteJSON: Data?
    ) throws -> [String: Data] {
        let metadataFiles: PatternProjectMetadataFiles
        do {
            metadataFiles = try PatternProjectMetadataCodec.encode(metadata)
        } catch let error as PatternProjectLoadError {
            throw PatternProjectFileError.metadata(error)
        }
        let expected = expectedRasters(in: metadata)
        for path in expected.keys.sorted()
            where rastersByPath[path] == nil
        {
            throw PatternProjectFileError.missingRaster(path)
        }
        for path in rastersByPath.keys.sorted()
            where expected[path] == nil
        {
            throw PatternProjectFileError.unexpectedRaster(path)
        }
        try validateRasterBudget(expected)

        var entries: [String: Data] = [
            PatternProjectFormat.manifestPath: metadataFiles.manifest,
            PatternProjectFormat.symmetryPath: metadataFiles.symmetry,
        ]
        try add(metadataFiles.layersByPath, to: &entries)
        try add(metadataFiles.surfacesByPath, to: &entries)
        for path in expected.keys.sorted() {
            let image = rastersByPath[path]!
            let expectedSize = expected[path]!
            guard entries[path] == nil,
                  path != thumbnailPath,
                  path != palettePath
            else {
                throw PatternProjectFileError.duplicateArchivePath(path)
            }
            guard image.pixelSize == expectedSize else {
                throw PatternProjectFileError.raster(
                    path: path,
                    error: .unexpectedDimensions(
                        expected: expectedSize,
                        actualWidth: image.pixelSize.width,
                        actualHeight: image.pixelSize.height
                    )
                )
            }
            do {
                entries[path] = try PatternRasterPNGCodec.encode(image)
            } catch let error as PatternRasterImageError {
                throw PatternProjectFileError.raster(
                    path: path,
                    error: error
                )
            }
        }
        if let thumbnail {
            guard entries[thumbnailPath] == nil else {
                throw PatternProjectFileError.duplicateArchivePath(
                    thumbnailPath
                )
            }
            guard thumbnail.pixelSize.width <= 512,
                  thumbnail.pixelSize.height <= 512
            else {
                throw PatternProjectFileError.invalidThumbnail
            }
            do {
                entries[thumbnailPath] =
                    try PatternRasterPNGCodec.encode(thumbnail)
            } catch let error as PatternRasterImageError {
                throw PatternProjectFileError.raster(
                    path: thumbnailPath,
                    error: error
                )
            }
        }
        if let projectPaletteJSON {
            guard entries[palettePath] == nil else {
                throw PatternProjectFileError.duplicateArchivePath(
                    palettePath
                )
            }
            guard projectPaletteJSON.count
                    <= PatternProjectMetadataCodec
                        .maximumMetadataBytesPerFile,
                  (try? JSONSerialization.jsonObject(
                      with: projectPaletteJSON
                  )) != nil
            else {
                throw PatternProjectFileError.invalidPalette
            }
            entries[palettePath] = projectPaletteJSON
        }
        return entries
    }

    static func open(
        _ archive: PatternProjectArchive
    ) throws -> DecodedPatternProject {
        let metadataFiles: PatternProjectMetadataFiles
        let validated: ValidatedPatternProjectMetadata
        do {
            metadataFiles =
                try PatternProjectMetadataCodec.extractedMetadataFiles(
                    from: archive
                )
            validated = try PatternProjectMetadataCodec.decode(metadataFiles)
        } catch let error as PatternProjectLoadError {
            throw PatternProjectFileError.metadata(error)
        } catch let error as PatternProjectArchiveError {
            throw PatternProjectFileError.archive(error)
        }
        let expected = expectedRasters(in: validated.metadata)
        try validateRasterBudget(expected)
        var allowed = Set([
            PatternProjectFormat.manifestPath,
            PatternProjectFormat.symmetryPath,
        ])
        allowed.formUnion(metadataFiles.layersByPath.keys)
        allowed.formUnion(metadataFiles.surfacesByPath.keys)
        allowed.formUnion(expected.keys)
        allowed.insert(thumbnailPath)
        allowed.insert(palettePath)
        if let unexpected = archive.paths.first(where: {
            !allowed.contains($0)
        }) {
            throw PatternProjectFileError.unexpectedArchiveEntry(unexpected)
        }

        var rasters: [String: PatternRasterImage] = [:]
        rasters.reserveCapacity(expected.count)
        for path in expected.keys.sorted() {
            let encoded: Data
            do {
                encoded = try archive.data(for: path)
            } catch PatternProjectArchiveError.missingEntry {
                throw PatternProjectFileError.missingRaster(path)
            } catch let error as PatternProjectArchiveError {
                throw PatternProjectFileError.archive(error)
            }
            do {
                rasters[path] = try PatternRasterPNGCodec.decode(
                    encoded,
                    expectedPixelSize: expected[path]!
                )
            } catch let error as PatternRasterImageError {
                throw PatternProjectFileError.raster(
                    path: path,
                    error: error
                )
            }
        }
        let thumbnail: PatternRasterImage?
        if archive.paths.contains(thumbnailPath),
           let encoded = try? archive.data(for: thumbnailPath),
           let decoded = try? PatternRasterPNGCodec.decode(encoded),
           decoded.pixelSize.width <= 512,
           decoded.pixelSize.height <= 512
        {
            thumbnail = decoded
        } else {
            thumbnail = nil
        }
        let palette: Data?
        if archive.paths.contains(palettePath) {
            let encoded: Data
            do {
                encoded = try archive.data(for: palettePath)
            } catch let error as PatternProjectArchiveError {
                throw PatternProjectFileError.archive(error)
            }
            guard encoded.count
                    <= PatternProjectMetadataCodec
                        .maximumMetadataBytesPerFile,
                  (try? JSONSerialization.jsonObject(with: encoded)) != nil
            else {
                throw PatternProjectFileError.invalidPalette
            }
            palette = encoded
        } else {
            palette = nil
        }
        return DecodedPatternProject(
            metadata: validated,
            rastersByPath: rasters,
            thumbnail: thumbnail,
            projectPaletteJSON: palette
        )
    }

    static func expectedRasters(
        in metadata: PatternProjectMetadata
    ) -> [String: PixelSize] {
        var expected: [String: PixelSize] = [:]
        for layer in metadata.layers {
            switch layer.surface {
            case let .singleRaster(raster):
                expected[raster.file] = raster.pixelSize
            case let .radialPages(surface):
                let pageSize = PixelSize(
                    width: surface.pageSide,
                    height: surface.pageSide
                )
                for page in surface.pages {
                    expected[page.file] = pageSize
                }
            }
        }
        return expected
    }

    static func validateRasterBudget(
        _ rasters: [String: PixelSize]
    ) throws {
        var total: UInt64 = 0
        for size in rasters.values {
            let bytes = UInt64(size.width)
                * UInt64(size.height)
                * 4
            let (next, overflow) = total.addingReportingOverflow(bytes)
            guard !overflow, next <= maximumDecodedRasterBytes else {
                throw PatternProjectFileError.rasterBudgetExceeded(
                    actual: overflow ? UInt64.max : next,
                    maximum: maximumDecodedRasterBytes
                )
            }
            total = next
        }
    }

    static func add(
        _ additions: [String: Data],
        to entries: inout [String: Data]
    ) throws {
        for (path, data) in additions {
            guard entries[path] == nil else {
                throw PatternProjectFileError.duplicateArchivePath(path)
            }
            entries[path] = data
        }
    }
}
