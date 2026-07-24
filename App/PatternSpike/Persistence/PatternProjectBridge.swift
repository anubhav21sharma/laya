import Foundation
import Metal
import MetalRenderer
import PatternEngine
import PatternFile

struct PatternProjectIdentity: Equatable, Sendable {
    let documentID: UUID
    let layerID: UUID
    var title: String
    let createdAt: Date

    static func new(title: String = "Untitled Pattern") -> Self {
        Self(
            documentID: UUID(),
            layerID: UUID(),
            title: title,
            createdAt: Date()
        )
    }
}

struct CapturedPatternProject: Equatable, Sendable {
    let metadata: PatternProjectMetadata
    let rastersByPath: [String: PatternRasterImage]
}

enum PatternProjectBridgeError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case unsupportedLayerModel
    case missingRaster(String)
    case incompatibleSurface

    var errorDescription: String? {
        switch self {
        case .unsupportedLayerModel:
            "This build can open only its current single pattern-layer model."
        case let .missingRaster(path):
            "The decoded project is missing raster \(path)."
        case .incompatibleSurface:
            "The decoded raster surface does not match document symmetry."
        }
    }
}

@MainActor
enum PatternProjectBridge {
    static func capture(
        renderer: GridRenderer,
        identity: PatternProjectIdentity,
        appVersion: String,
        modifiedAt: Date = Date()
    ) throws -> CapturedPatternProject {
        let snapshot = try renderer.captureCommittedDocument()
        let layerPathStem =
            "rasters/\(identity.layerID.uuidString.lowercased())"
        let surface: PatternProjectLayerSurface
        var rasters: [String: PatternRasterImage] = [:]
        switch snapshot.storage {
        case let .singleRaster(bytes):
            let path = "\(layerPathStem).png"
            let image = try PatternRasterImage(
                pixelSize: snapshot.canvasSize,
                bgra8PremultipliedBytes: bytes
            )
            surface = .singleRaster(PatternProjectRasterReference(
                file: path,
                pixelSize: snapshot.canvasSize
            ))
            rasters[path] = image
        case let .radialPages(pages):
            let pageSize = PixelSize(
                width: RadialSectorLayout.pageSide,
                height: RadialSectorLayout.pageSide
            )
            var references: [PatternProjectRadialPage] = []
            references.reserveCapacity(pages.count)
            for page in pages.sorted(by: {
                $0.coordinate < $1.coordinate
            }) {
                let path = "\(layerPathStem)/page-\(page.coordinate.x)-\(page.coordinate.y).png"
                references.append(PatternProjectRadialPage(
                    coordinate: page.coordinate,
                    file: path
                ))
                rasters[path] = try PatternRasterImage(
                    pixelSize: pageSize,
                    bgra8PremultipliedBytes:
                        page.bgra8PremultipliedBytes
                )
            }
            surface = .radialPages(PatternProjectRadialSurface(
                manifestFile: "\(layerPathStem)/surface.json",
                pages: references
            ))
        }
        let viewport = renderer.viewport
        let metadata = PatternProjectMetadata(
            documentID: identity.documentID,
            title: identity.title,
            appVersion: appVersion,
            createdAt: identity.createdAt,
            modifiedAt: max(modifiedAt, identity.createdAt),
            canvasSize: snapshot.canvasSize,
            viewport: PatternProjectViewport(
                scale: viewport.zoom,
                offsetX: viewport.worldCenter.x,
                offsetY: viewport.worldCenter.y
            ),
            documentConfiguration: snapshot.documentConfiguration,
            radialGeometryLocked: snapshot.radialGeometryLocked,
            activeLayerID: identity.layerID,
            layers: [
                PatternProjectLayer(
                    id: identity.layerID,
                    name: "Layer 1",
                    order: 0,
                    surface: surface
                ),
            ]
        )
        return CapturedPatternProject(
            metadata: metadata,
            rastersByPath: rasters
        )
    }

    static func identity(
        from project: DecodedPatternProject
    ) throws -> PatternProjectIdentity {
        let metadata = project.metadata.metadata
        guard metadata.layers.count == 1,
              let layer = metadata.layers.first,
              layer.id == metadata.activeLayerID,
              layer.kind == .pattern,
              layer.order == 0,
              layer.opacity == 1,
              layer.blendMode == .normal,
              layer.isVisible,
              !layer.isLocked,
              layer.origin == nil
        else {
            throw PatternProjectBridgeError.unsupportedLayerModel
        }
        return PatternProjectIdentity(
            documentID: metadata.documentID,
            layerID: layer.id,
            title: metadata.title,
            createdAt: metadata.createdAt
        )
    }

    static func committedSnapshot(
        from project: DecodedPatternProject
    ) throws -> CommittedDocumentSnapshot {
        let metadata = project.metadata.metadata
        _ = try identity(from: project)
        let layer = metadata.layers[0]
        let storage: CommittedRasterStorage
        switch layer.surface {
        case let .singleRaster(reference):
            guard let image = project.rastersByPath[reference.file],
                  image.pixelSize == reference.pixelSize
            else {
                throw PatternProjectBridgeError.missingRaster(
                    reference.file
                )
            }
            storage = .singleRaster(
                bgra8PremultipliedBytes:
                    image.bgra8PremultipliedBytes
            )
        case let .radialPages(surface):
            var pages: [CommittedRadialPagePixels] = []
            pages.reserveCapacity(surface.pages.count)
            for reference in surface.pages {
                guard let image =
                    project.rastersByPath[reference.file]
                else {
                    throw PatternProjectBridgeError.missingRaster(
                        reference.file
                    )
                }
                pages.append(CommittedRadialPagePixels(
                    coordinate: reference.coordinate,
                    bgra8PremultipliedBytes:
                        image.bgra8PremultipliedBytes
                ))
            }
            storage = .radialPages(pages)
        }
        return CommittedDocumentSnapshot(
            canvasSize: metadata.canvasSize,
            documentConfiguration: metadata.documentConfiguration,
            radialGeometryLocked: metadata.radialGeometryLocked,
            storage: storage
        )
    }

    static func makeRenderer(
        from project: DecodedPatternProject,
        device: any MTLDevice,
        drawableSize: PatternSize
    ) throws -> GridRenderer {
        let renderer = try GridRenderer(
            device: device,
            drawableSize: drawableSize,
            committedSnapshot: committedSnapshot(from: project)
        )
        let viewport = project.metadata.metadata.viewport
        renderer.restoreSavedViewport(
            worldCenter: WorldPoint(
                x: viewport.offsetX,
                y: viewport.offsetY
            ),
            zoom: viewport.scale
        )
        return renderer
    }
}
