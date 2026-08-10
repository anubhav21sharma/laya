import Foundation
import PatternEngine

struct DocumentPaintEncodedBGRA8PlaneInput: Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: Data

    init(width: Int, height: Int, bytesPerRow: Int, bytes: Data) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.bytes = Data(bytes)
    }
}

struct DocumentPaintEncodedBGRA8RadialPageInput: Sendable {
    let coordinate: RadialPageCoordinate
    let plane: DocumentPaintEncodedBGRA8PlaneInput
}

enum DocumentPaintEncodedImportInput: Sendable {
    case singleRaster(DocumentPaintEncodedBGRA8PlaneInput)
    case radialPages([DocumentPaintEncodedBGRA8RadialPageInput])
}

enum DocumentPaintEncodedImportError: Error, Equatable, Sendable {
    case invalidDimensions(width: Int, height: Int)
    case invalidRowStride(minimum: Int, actual: Int)
    case invalidByteCount(expected: Int, actual: Int)
    case byteCountOverflow
    case geometryMismatch(expected: PixelSize, actual: PixelSize)
    case singleRasterRequiresAffineStorage
    case radialPagesRequireRadialStorage
    case invalidRadialPageSize(expected: PixelSize, actual: PixelSize)
    case duplicateRadialPage(RadialPageCoordinate)
    case radialPageOutsideLayout(RadialPageCoordinate)
    case uploadBudgetExceeded(required: Int, maximum: Int)
}

private struct DocumentPaintEncodedImportPlane: Sendable {
    let coordinate: PaintTileCoordinate
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: Data
}

struct DocumentPaintSurfaceEncodedImportPlaneBinding:
    @unchecked Sendable
{
    fileprivate let plane: DocumentPaintEncodedImportPlane
    let destination: DocumentPaintSurfaceMutationDestination

    var coordinate: PaintTileCoordinate { plane.coordinate }
    var width: Int { plane.width }
    var height: Int { plane.height }
    var bytesPerRow: Int { plane.bytesPerRow }
    var bytes: Data { plane.bytes }
}

struct DocumentPaintSurfaceEncodedImportBackendPayload:
    @unchecked Sendable
{
    let candidateGeometry: DocumentPaintGeometry
    let planeBindings: [DocumentPaintSurfaceEncodedImportPlaneBinding]

    fileprivate init(
        candidateGeometry: DocumentPaintGeometry,
        sourcePlanes: [DocumentPaintEncodedImportPlane],
        destinations: [DocumentPaintSurfaceMutationDestination]
    ) {
        precondition(sourcePlanes.count == destinations.count)
        precondition(zip(sourcePlanes, destinations).allSatisfy {
            $0.coordinate == $1.coordinate
        })
        self.candidateGeometry = candidateGeometry
        planeBindings = zip(sourcePlanes, destinations).map {
            DocumentPaintSurfaceEncodedImportPlaneBinding(
                plane: $0,
                destination: $1
            )
        }
    }

    var destinations: [DocumentPaintSurfaceMutationDestination] {
        planeBindings.map(\.destination)
    }
}

/// A validated, tightly packed encoded-interchange import. Its initializer and
/// source planes stay in this file so raw byte geometry cannot re-enter the
/// transaction or Metal layers after this trust boundary.
struct DocumentPaintSurfaceEncodedImportRequest: Sendable {
    let layerID: UUID
    let candidateGeometry: DocumentPaintGeometry
    fileprivate let sourcePlanes: [DocumentPaintEncodedImportPlane]
    fileprivate let dirtyCoordinates: [PaintTileCoordinate]
    fileprivate let totalEncodedByteCount: Int

    private init(
        layerID: UUID,
        candidateGeometry: DocumentPaintGeometry,
        sourcePlanes: [DocumentPaintEncodedImportPlane],
        totalEncodedByteCount: Int
    ) {
        self.layerID = layerID
        self.candidateGeometry = candidateGeometry
        self.sourcePlanes = sourcePlanes
        dirtyCoordinates = sourcePlanes.map(\.coordinate)
        self.totalEncodedByteCount = totalEncodedByteCount
    }

    static func validate(
        layerID: UUID,
        candidateGeometry: DocumentPaintGeometry,
        input: DocumentPaintEncodedImportInput,
        maximumUploadBytes: Int
    ) throws -> Self {
        guard maximumUploadBytes >= 0 else {
            throw DocumentPaintEncodedImportError.uploadBudgetExceeded(
                required: 0,
                maximum: maximumUploadBytes
            )
        }
        switch input {
        case let .singleRaster(inputPlane):
            guard candidateGeometry.radialLayout == nil else {
                throw DocumentPaintEncodedImportError
                    .singleRasterRequiresAffineStorage
            }
            try validateRawPlane(inputPlane)
            let actual = PixelSize(
                width: inputPlane.width,
                height: inputPlane.height
            )
            guard actual == candidateGeometry.storagePixelSize else {
                throw DocumentPaintEncodedImportError.geometryMismatch(
                    expected: candidateGeometry.storagePixelSize,
                    actual: actual
                )
            }
            let planes = try tileSingleRaster(
                inputPlane,
                storageSize: candidateGeometry.storagePixelSize,
                maximumUploadBytes: maximumUploadBytes
            )
            let total = planes.reduce(0) { $0 + $1.bytes.count }
            return Self(
                layerID: layerID,
                candidateGeometry: candidateGeometry,
                sourcePlanes: planes,
                totalEncodedByteCount: total
            )

        case let .radialPages(inputs):
            guard let layout = candidateGeometry.radialLayout else {
                throw DocumentPaintEncodedImportError
                    .radialPagesRequireRadialStorage
            }
            let pageSize = PixelSize(
                width: RadialSectorLayout.pageSide,
                height: RadialSectorLayout.pageSide
            )
            var seen: Set<RadialPageCoordinate> = []
            var planes: [DocumentPaintEncodedImportPlane] = []
            var totalEncodedByteCount = 0
            planes.reserveCapacity(inputs.count)
            for input in inputs {
                guard seen.insert(input.coordinate).inserted else {
                    throw DocumentPaintEncodedImportError
                        .duplicateRadialPage(input.coordinate)
                }
                guard let resident = residentPage(
                    at: input.coordinate,
                    in: layout
                ) else {
                    throw DocumentPaintEncodedImportError
                        .radialPageOutsideLayout(input.coordinate)
                }
                try validateRawPlane(input.plane)
                let actual = PixelSize(
                    width: input.plane.width,
                    height: input.plane.height
                )
                guard actual == pageSize else {
                    throw DocumentPaintEncodedImportError
                        .invalidRadialPageSize(
                            expected: pageSize,
                            actual: actual
                        )
                }
                let coordinate = PaintTileCoordinate(
                    x: resident.atlasSlot % layout.atlasColumns,
                    y: resident.atlasSlot / layout.atlasColumns
                )
                if let packed = try pack(
                    input.plane,
                    sourceX: 0,
                    sourceY: 0,
                    width: pageSize.width,
                    height: pageSize.height,
                    coordinate: coordinate,
                    acceptedByteCount: totalEncodedByteCount,
                    maximumUploadBytes: maximumUploadBytes
                ) {
                    planes.append(packed)
                    totalEncodedByteCount += packed.bytes.count
                }
            }
            planes.sort { $0.coordinate < $1.coordinate }
            return Self(
                layerID: layerID,
                candidateGeometry: candidateGeometry,
                sourcePlanes: planes,
                totalEncodedByteCount: totalEncodedByteCount
            )
        }
    }

    var importDirtyCoordinates: [PaintTileCoordinate] {
        dirtyCoordinates
    }

    var importTotalEncodedByteCount: Int {
        totalEncodedByteCount
    }

    func makeBackendPayload(
        destinations: [DocumentPaintSurfaceMutationDestination]
    ) -> DocumentPaintSurfaceEncodedImportBackendPayload {
        DocumentPaintSurfaceEncodedImportBackendPayload(
            candidateGeometry: candidateGeometry,
            sourcePlanes: sourcePlanes,
            destinations: destinations
        )
    }

    private static func validateRawPlane(
        _ plane: DocumentPaintEncodedBGRA8PlaneInput
    ) throws {
        guard plane.width > 0, plane.height > 0 else {
            throw DocumentPaintEncodedImportError.invalidDimensions(
                width: plane.width,
                height: plane.height
            )
        }
        let (minimumStride, strideOverflow) = plane.width
            .multipliedReportingOverflow(by: 4)
        guard !strideOverflow else {
            throw DocumentPaintEncodedImportError.byteCountOverflow
        }
        guard plane.bytesPerRow >= minimumStride else {
            throw DocumentPaintEncodedImportError.invalidRowStride(
                minimum: minimumStride,
                actual: plane.bytesPerRow
            )
        }
        let (expected, byteOverflow) = plane.bytesPerRow
            .multipliedReportingOverflow(by: plane.height)
        guard !byteOverflow else {
            throw DocumentPaintEncodedImportError.byteCountOverflow
        }
        guard plane.bytes.count == expected else {
            throw DocumentPaintEncodedImportError.invalidByteCount(
                expected: expected,
                actual: plane.bytes.count
            )
        }
    }

    private static func residentPage(
        at coordinate: RadialPageCoordinate,
        in layout: RadialSectorLayout
    ) -> RadialResidentPage? {
        let (x, xOverflow) = coordinate.x.subtractingReportingOverflow(
            layout.pageOrigin.x
        )
        let (y, yOverflow) = coordinate.y.subtractingReportingOverflow(
            layout.pageOrigin.y
        )
        guard !xOverflow, !yOverflow,
              x >= 0, y >= 0,
              x < layout.pageTableSize.width,
              y < layout.pageTableSize.height
        else { return nil }
        let slot = layout.pageTable[y * layout.pageTableSize.width + x]
        guard slot >= 0 else { return nil }
        return RadialResidentPage(
            coordinate: coordinate,
            atlasSlot: Int(slot)
        )
    }

    private static func tileSingleRaster(
        _ input: DocumentPaintEncodedBGRA8PlaneInput,
        storageSize: PixelSize,
        maximumUploadBytes: Int
    ) throws -> [DocumentPaintEncodedImportPlane] {
        let maximumX = (storageSize.width - 1) / PaintTileDescriptor.side
        let maximumY = (storageSize.height - 1) / PaintTileDescriptor.side
        var planes: [DocumentPaintEncodedImportPlane] = []
        var totalEncodedByteCount = 0
        planes.reserveCapacity((maximumX + 1) * (maximumY + 1))
        for y in 0...maximumY {
            for x in 0...maximumX {
                let coordinate = PaintTileCoordinate(x: x, y: y)
                let descriptor = try PaintTileDescriptor(
                    coordinate: coordinate,
                    logicalPixelSize: storageSize
                )
                if let packed = try pack(
                    input,
                    sourceX: descriptor.logicalBounds.minX,
                    sourceY: descriptor.logicalBounds.minY,
                    width: descriptor.logicalBounds.width,
                    height: descriptor.logicalBounds.height,
                    coordinate: coordinate,
                    acceptedByteCount: totalEncodedByteCount,
                    maximumUploadBytes: maximumUploadBytes
                ) {
                    planes.append(packed)
                    totalEncodedByteCount += packed.bytes.count
                }
            }
        }
        return planes
    }

    private static func pack(
        _ input: DocumentPaintEncodedBGRA8PlaneInput,
        sourceX: Int,
        sourceY: Int,
        width: Int,
        height: Int,
        coordinate: PaintTileCoordinate,
        acceptedByteCount: Int,
        maximumUploadBytes: Int
    ) throws -> DocumentPaintEncodedImportPlane? {
        let (bytesPerRow, rowOverflow) = width
            .multipliedReportingOverflow(by: 4)
        let (byteCount, byteOverflow) = bytesPerRow
            .multipliedReportingOverflow(by: height)
        guard !rowOverflow, !byteOverflow else {
            throw DocumentPaintEncodedImportError.byteCountOverflow
        }
        let containsContent = input.bytes.withUnsafeBytes { sourceRaw in
            let source = sourceRaw.bindMemory(to: UInt8.self)
            for row in 0..<height {
                let sourceRow = (sourceY + row) * input.bytesPerRow
                    + sourceX * 4
                for column in 0..<width
                where source[sourceRow + column * 4 + 3] != 0 {
                    return true
                }
            }
            return false
        }
        guard containsContent else { return nil }
        let (requiredByteCount, aggregateOverflow) = acceptedByteCount
            .addingReportingOverflow(byteCount)
        guard !aggregateOverflow else {
            throw DocumentPaintEncodedImportError.byteCountOverflow
        }
        guard requiredByteCount <= maximumUploadBytes else {
            throw DocumentPaintEncodedImportError.uploadBudgetExceeded(
                required: requiredByteCount,
                maximum: maximumUploadBytes
            )
        }
        var packed = Data(repeating: 0, count: byteCount)
        input.bytes.withUnsafeBytes { sourceRaw in
            packed.withUnsafeMutableBytes { destinationRaw in
                let source = sourceRaw.bindMemory(to: UInt8.self)
                let destination = destinationRaw.bindMemory(to: UInt8.self)
                for row in 0..<height {
                    let sourceRow = (sourceY + row) * input.bytesPerRow
                        + sourceX * 4
                    let destinationRow = row * bytesPerRow
                    for column in 0..<width {
                        let sourceOffset = sourceRow + column * 4
                        let destinationOffset = destinationRow + column * 4
                        let alpha = source[sourceOffset + 3]
                        guard alpha != 0 else { continue }
                        destination[destinationOffset] = source[sourceOffset]
                        destination[destinationOffset + 1] = source[sourceOffset + 1]
                        destination[destinationOffset + 2] = source[sourceOffset + 2]
                        destination[destinationOffset + 3] = alpha
                    }
                }
            }
        }
        return DocumentPaintEncodedImportPlane(
            coordinate: coordinate,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bytes: packed
        )
    }

}
