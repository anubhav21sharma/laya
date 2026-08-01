import Foundation
import PatternEngine

public struct PixelBounds: Codable, Equatable, Sendable {
    public let minimumX: Int
    public let minimumY: Int
    public let maximumX: Int
    public let maximumY: Int

    public init(
        minimumX: Int,
        minimumY: Int,
        maximumX: Int,
        maximumY: Int
    ) {
        self.minimumX = minimumX
        self.minimumY = minimumY
        self.maximumX = maximumX
        self.maximumY = maximumY
    }
}

public struct BrushFunctionalMeasurement: Codable, Equatable, Sendable {
    public let changedPixelCount: Int
    public let alphaSupportBounds: PixelBounds?
    public let centerlineWidthP50: Float
    public let centerlineWidthP95: Float
    public let alphaP50: Float
    public let alphaP90: Float
    public let endpointRetreatPixels: Float
    public let turnProtrusionPixels: Float
    public let isolatedComponentCount: Int

    public init(
        changedPixelCount: Int,
        alphaSupportBounds: PixelBounds?,
        centerlineWidthP50: Float,
        centerlineWidthP95: Float,
        alphaP50: Float,
        alphaP90: Float,
        endpointRetreatPixels: Float,
        turnProtrusionPixels: Float,
        isolatedComponentCount: Int
    ) {
        self.changedPixelCount = changedPixelCount
        self.alphaSupportBounds = alphaSupportBounds
        self.centerlineWidthP50 = centerlineWidthP50
        self.centerlineWidthP95 = centerlineWidthP95
        self.alphaP50 = alphaP50
        self.alphaP90 = alphaP90
        self.endpointRetreatPixels = endpointRetreatPixels
        self.turnProtrusionPixels = turnProtrusionPixels
        self.isolatedComponentCount = isolatedComponentCount
    }
}

public enum BrushFunctionalMetricsError: Error, Equatable {
    case invalidDimensions(width: Int, height: Int)
    case invalidByteCount(expected: Int, actual: Int)
    case invalidNominalDiameter(Float)
    case insufficientCenterline
}

/// Independent scalar CPU measurements over BGRA8 readback pixels.
///
/// This oracle deliberately depends only on pixel bytes and authored geometry;
/// it does not call brush dynamics, compiled-brush, deposition, or shader
/// helpers to derive expected values.
public enum BrushFunctionalMetrics {
    public static func measure(
        bgra8: [UInt8],
        width: Int,
        height: Int,
        centerline: [ScreenPoint],
        nominalDiameter: Float,
        alphaThreshold: UInt8 = 1
    ) throws -> BrushFunctionalMeasurement {
        guard width > 0, height > 0 else {
            throw BrushFunctionalMetricsError.invalidDimensions(
                width: width,
                height: height
            )
        }
        let expectedCount = width * height * 4
        guard bgra8.count == expectedCount else {
            throw BrushFunctionalMetricsError.invalidByteCount(
                expected: expectedCount,
                actual: bgra8.count
            )
        }
        guard nominalDiameter.isFinite, nominalDiameter > 0 else {
            throw BrushFunctionalMetricsError.invalidNominalDiameter(
                nominalDiameter
            )
        }
        guard centerline.count >= 2,
              centerline.allSatisfy({
                  $0.x.isFinite && $0.y.isFinite
              })
        else {
            throw BrushFunctionalMetricsError.insufficientCenterline
        }

        let active = activePixels(
            bgra8: bgra8,
            width: width,
            height: height,
            alphaThreshold: alphaThreshold
        )
        let bounds = supportBounds(active, width: width, height: height)
        let alphas = active.indices.compactMap { index -> Float? in
            guard active[index] else { return nil }
            return Float(bgra8[index * 4 + 3]) / 255
        }
        let widths = centerlineWidths(
            active: active,
            width: width,
            height: height,
            centerline: centerline
        )
        let centerlineWidthP50 = percentile(widths, fraction: 0.50)
        let centerlineWidthP95 = percentile(widths, fraction: 0.95)

        return BrushFunctionalMeasurement(
            changedPixelCount: alphas.count,
            alphaSupportBounds: bounds,
            centerlineWidthP50: centerlineWidthP50,
            centerlineWidthP95: centerlineWidthP95,
            alphaP50: percentile(alphas, fraction: 0.50),
            alphaP90: percentile(alphas, fraction: 0.90),
            endpointRetreatPixels: endpointRetreat(
                active: active,
                width: width,
                height: height,
                centerline: centerline
            ),
            turnProtrusionPixels: turnProtrusion(
                active: active,
                width: width,
                height: height,
                centerline: centerline,
                principalSupportRadius: min(
                    nominalDiameter * 0.5,
                    max(centerlineWidthP50 * 0.5, 0.5)
                )
            ),
            isolatedComponentCount: isolatedComponents(
                active: active,
                width: width,
                height: height
            )
        )
    }

    private static func activePixels(
        bgra8: [UInt8],
        width: Int,
        height: Int,
        alphaThreshold: UInt8
    ) -> [Bool] {
        let visibleThreshold = max(alphaThreshold, 1)
        return (0..<(width * height)).map {
            bgra8[$0 * 4 + 3] >= visibleThreshold
        }
    }

    private static func supportBounds(
        _ active: [Bool],
        width: Int,
        height: Int
    ) -> PixelBounds? {
        var minimumX = width
        var minimumY = height
        var maximumX = -1
        var maximumY = -1
        for y in 0..<height {
            for x in 0..<width where active[y * width + x] {
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
            }
        }
        guard maximumX >= 0 else { return nil }
        return PixelBounds(
            minimumX: minimumX,
            minimumY: minimumY,
            maximumX: maximumX,
            maximumY: maximumY
        )
    }

    private static func centerlineWidths(
        active: [Bool],
        width: Int,
        height: Int,
        centerline: [ScreenPoint]
    ) -> [Float] {
        var result: [Float] = []
        let maximumOffset = max(width, height)
        for segmentIndex in 0..<(centerline.count - 1) {
            let start = centerline[segmentIndex]
            let end = centerline[segmentIndex + 1]
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = hypot(dx, dy)
            guard length > 0 else { continue }
            let normalX = -dy / length
            let normalY = dx / length
            let stepCount = max(1, Int(ceil(length)))
            for step in 0...stepCount {
                if segmentIndex > 0, step == 0 { continue }
                let fraction = Float(step) / Float(stepCount)
                let baseX = start.x + dx * fraction
                let baseY = start.y + dy * fraction
                var minimumOffset: Int?
                var maximumActiveOffset: Int?
                for offset in -maximumOffset...maximumOffset {
                    let x = Int(round(baseX + normalX * Float(offset)))
                    let y = Int(round(baseY + normalY * Float(offset)))
                    guard x >= 0, x < width, y >= 0, y < height,
                          active[y * width + x]
                    else { continue }
                    minimumOffset = min(minimumOffset ?? offset, offset)
                    maximumActiveOffset = max(
                        maximumActiveOffset ?? offset,
                        offset
                    )
                }
                if let minimumOffset, let maximumActiveOffset {
                    result.append(Float(maximumActiveOffset - minimumOffset + 1))
                } else {
                    result.append(0)
                }
            }
        }
        return result
    }

    private static func endpointRetreat(
        active: [Bool],
        width: Int,
        height: Int,
        centerline: [ScreenPoint]
    ) -> Float {
        let endpoint = centerline[centerline.count - 1]
        guard let previous = centerline.dropLast().last(where: {
            $0 != endpoint
        }) else { return 0 }
        let dx = endpoint.x - previous.x
        let dy = endpoint.y - previous.y
        let length = hypot(dx, dy)
        guard length > 0 else { return 0 }
        let directionX = dx / length
        let directionY = dy / length
        let endpointProjection = endpoint.x * directionX
            + endpoint.y * directionY
        var maximumProjection: Float?
        for y in 0..<height {
            for x in 0..<width where active[y * width + x] {
                let projection = Float(x) * directionX
                    + Float(y) * directionY
                maximumProjection = max(
                    maximumProjection ?? projection,
                    projection
                )
            }
        }
        guard let maximumProjection else { return length }
        return max(0, endpointProjection - maximumProjection)
    }

    private static func turnProtrusion(
        active: [Bool],
        width: Int,
        height: Int,
        centerline: [ScreenPoint],
        principalSupportRadius: Float
    ) -> Float {
        var maximumDistance: Float = 0
        for y in 0..<height {
            for x in 0..<width where active[y * width + x] {
                let point = ScreenPoint(x: Float(x), y: Float(y))
                var nearest = Float.greatestFiniteMagnitude
                for index in 0..<(centerline.count - 1) {
                    nearest = min(
                        nearest,
                        distance(
                            point,
                            toSegmentFrom: centerline[index],
                            to: centerline[index + 1]
                        )
                    )
                }
                maximumDistance = max(maximumDistance, nearest)
            }
        }
        return max(0, maximumDistance - principalSupportRadius)
    }

    private static func distance(
        _ point: ScreenPoint,
        toSegmentFrom start: ScreenPoint,
        to end: ScreenPoint
    ) -> Float {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let projection = max(
            0,
            min(
                1,
                ((point.x - start.x) * dx + (point.y - start.y) * dy)
                    / lengthSquared
            )
        )
        return hypot(
            point.x - (start.x + projection * dx),
            point.y - (start.y + projection * dy)
        )
    }

    private static func isolatedComponents(
        active: [Bool],
        width: Int,
        height: Int
    ) -> Int {
        var visited = [Bool](repeating: false, count: active.count)
        var componentCount = 0
        let neighbors = [
            (-1, -1), (0, -1), (1, -1),
            (-1, 0), (1, 0),
            (-1, 1), (0, 1), (1, 1),
        ]
        for start in active.indices where active[start] && !visited[start] {
            componentCount += 1
            visited[start] = true
            var queue = [start]
            var cursor = 0
            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                let x = index % width
                let y = index / width
                for (offsetX, offsetY) in neighbors {
                    let neighborX = x + offsetX
                    let neighborY = y + offsetY
                    guard neighborX >= 0, neighborX < width,
                          neighborY >= 0, neighborY < height
                    else { continue }
                    let neighbor = neighborY * width + neighborX
                    guard active[neighbor], !visited[neighbor] else {
                        continue
                    }
                    visited[neighbor] = true
                    queue.append(neighbor)
                }
            }
        }
        return max(0, componentCount - 1)
    }

    private static func percentile(
        _ values: [Float],
        fraction: Float
    ) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = max(
            0,
            min(
                sorted.count - 1,
                Int(ceil(Float(sorted.count) * fraction)) - 1
            )
        )
        return sorted[rank]
    }
}
